#!/usr/bin/env python3
"""
Claude as a UCI engine, for KoboChess.

The Kobo cannot run a language model, and it does not need to: it already
knows how to talk to an engine over a pipe. This program is a UCI engine that
answers `go` by asking Claude what to play, and it listens on a TCP port so
that the pipe can have a tailnet in the middle of it. On the device, the
"engine" is three lines of shell that hand the pipe to `nc`; everything real
happens here.

    Kobo                       ubuntu-s1
    ----                       ---------
    engine_uci.lua  <-pipe->  engines/claude/engine  <-tailnet->  this
                              (exec nc HOST PORT)

Two things are worth knowing about the design.

**It is stateless per move.** Every `go` is answered from the position as it
stands, and nothing is remembered between connections. That is not laziness;
the Kobo's Wi-Fi drops, and a design that kept state across the connection
would lose a game every time it did. Reconnecting costs nothing.

**Claude's move is checked before it is believed.** A real engine derives its
moves from a board and cannot suggest an illegal one. Claude is reading the
position rather than computing over it, and will occasionally answer with a
move for a piece that has already moved, or one that passes through another
piece, or the right idea in the wrong notation. Every answer is validated
against python-chess's legal move list; a miss is sent back with the list
attached, and a second miss falls back to a legal move so that the board on
the Kobo never sits waiting for a move that is never coming.

Run it:

    claude_engine.py                      # listen on the tailnet, port 9666
    claude_engine.py --stdio              # speak UCI on stdin/stdout, to test
    claude_engine.py --backend api        # use the API instead of the CLI

@see tools/make_claude_engine.sh, which writes the device side.
"""

from __future__ import annotations

import argparse
import os
import random
import re
import socketserver
import subprocess
import sys
import tempfile
import threading
import time

import chess

ENGINE_NAME = "Claude"
ENGINE_AUTHOR = "KoboChess"

# --------------------------------------------------------------------------
# Who Claude is playing as
# --------------------------------------------------------------------------

# The plugin's six levels reach a UCI engine as UCI_Elo values, and the
# sixth -- full strength -- as UCI_LimitStrength false, which arrives here as
# None. Stockfish implements those ratings by playing measurably worse;
# Claude cannot dial its strength that finely, so the levels become opponents
# instead: different in temperament rather than in depth. That is the honest
# version of what an LLM opponent can offer, and the more interesting one.
PERSONAS = {
    1320: (
        "Beginner",
        "You are a friendly beginner. Develop your pieces, castle early, and"
        " take material when it is offered. Do not calculate deeply -- play"
        " the natural move. Blundering a piece occasionally is fine and human.",
    ),
    1500: (
        "Casual",
        "You are a casual club player. Follow opening principles, watch for"
        " one-move threats, and take free material. You miss two-move tactics"
        " fairly often. Play quickly and naturally.",
    ),
    1800: (
        "Club player",
        "You are a solid club player. Check your opponent's threats before"
        " choosing, calculate short forcing lines, and prefer sound developing"
        " moves over speculative attacks.",
    ),
    2200: (
        "Attacker",
        "You are a strong tactical player who enjoys the initiative. Look hard"
        " for forcing moves -- checks, captures, threats -- and prefer the"
        " sharp continuation when it is sound. Do not sacrifice on a hunch.",
    ),
    2600: (
        "Strategist",
        "You are a strong positional player. Improve your worst piece, take"
        " space, fix weaknesses in the opponent's structure, and steer toward"
        " endgames you understand. Calculate carefully before committing.",
    ),
    None: (
        "Full strength",
        "Play the strongest move you can find. Take your time. Check the"
        " candidate moves against your opponent's replies before deciding,"
        " and make sure your move does not hang material or allow a tactic.",
    ),
}


def persona_for(elo):
    """The persona for a UCI_Elo, or the full-strength one if it is unknown."""
    if elo in PERSONAS:
        return PERSONAS[elo]
    if elo is None:
        return PERSONAS[None]
    # An Elo we do not have a persona for: take the nearest one below it.
    known = sorted(e for e in PERSONAS if e is not None)
    pick = known[0]
    for e in known:
        if e <= elo:
            pick = e
    return PERSONAS[pick]


# --------------------------------------------------------------------------
# Asking Claude
# --------------------------------------------------------------------------


class CliBackend:
    """Ask through the `claude` CLI in headless mode.

    The default, because it needs no API key: it uses whatever credentials
    Claude Code already has on this machine. It costs a subprocess and a few
    seconds of startup per move, which against an e-ink board nobody notices.
    """

    def __init__(self, binary="claude", model=None):
        self.binary = binary
        self.model = model
        # Run somewhere empty. Started inside the KoboChess checkout, the CLI
        # would read the project's CLAUDE.md and settings and answer a chess
        # question with a repository in mind.
        self.cwd = tempfile.mkdtemp(prefix="kobochess-claude-")

    def describe(self):
        return f"cli:{self.binary}" + (f" model={self.model}" if self.model else "")

    def ask(self, prompt, timeout):
        argv = [self.binary, "-p", prompt]
        if self.model:
            argv += ["--model", self.model]
        # stdin from /dev/null: with a terminal or a pipe it has nothing to
        # say, the CLI waits three seconds for input that is not coming.
        done = subprocess.run(
            argv,
            cwd=self.cwd,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        if done.returncode != 0:
            raise RuntimeError(
                f"claude exited {done.returncode}: {done.stderr.strip()[:400]}"
            )
        return done.stdout


class RehearsalBackend:
    """Answer without asking anybody: a random move off the list in the prompt.

    Not an opponent -- a way to exercise the plumbing. The handshake, the
    position replay, `stop`, a dropped connection and the plugin's own
    handling of all of it can be tested end to end with this, for free and at
    full speed, leaving only the quality of the move untested.
    """

    UCI = re.compile(r"\b([a-h][1-8][a-h][1-8][qrbn]?)\b")

    def describe(self):
        return "rehearsal (random legal moves, no model)"

    def ask(self, prompt, timeout):
        moves = self.UCI.findall(prompt)
        return f"MOVE: {random.choice(moves)}" if moves else "I have no idea."


class ApiBackend:
    """Ask through the Messages API.

    Faster than the CLI by a few seconds, and the only option on a machine
    without Claude Code installed. Needs ANTHROPIC_API_KEY, or credentials
    from `ant auth login`.
    """

    DEFAULT_MODEL = "claude-opus-5"

    def __init__(self, model=None, effort="medium"):
        import anthropic  # imported here so the CLI backend needs no SDK

        self.anthropic = anthropic
        self.client = anthropic.Anthropic()
        self.model = model or self.DEFAULT_MODEL
        self.effort = effort
        # Opus 5 can decline a request outright, and the server-side fallback
        # routes those to another model rather than handing us an empty
        # answer. It is a beta, so an older SDK or a changed flag must not
        # take the engine down with it: the first failure that mentions the
        # beta turns it off for the rest of the session.
        self.use_fallbacks = True

    def describe(self):
        return f"api:{self.model} effort={self.effort}"

    def _create(self, client, prompt, with_fallbacks):
        kwargs = dict(
            model=self.model,
            max_tokens=2000,
            thinking={"type": "adaptive"},
            output_config={"effort": self.effort},
            messages=[{"role": "user", "content": prompt}],
        )
        if with_fallbacks:
            kwargs["betas"] = ["server-side-fallback-2026-07-01"]
            kwargs["fallbacks"] = "default"
            return client.beta.messages.create(**kwargs)
        return client.messages.create(**kwargs)

    def ask(self, prompt, timeout):
        client = self.client.with_options(timeout=timeout)
        try:
            message = self._create(client, prompt, self.use_fallbacks)
        except self.anthropic.BadRequestError as err:
            if not self.use_fallbacks:
                raise
            log(f"API rejected the fallback beta ({err}); continuing without it")
            self.use_fallbacks = False
            message = self._create(client, prompt, False)

        if getattr(message, "stop_reason", None) == "refusal":
            raise RuntimeError("the model declined to answer")
        return "".join(
            block.text for block in message.content if getattr(block, "type", "") == "text"
        )


# --------------------------------------------------------------------------
# The prompt, and reading the answer back
# --------------------------------------------------------------------------


def move_menu(board):
    """Every legal move, as `e2e4 (e4)` -- UCI first, then how it is written.

    Handing over the list is what makes the difference between Claude playing
    from a remembered position and playing from this one. It is also what the
    validation falls back on, so the two are always talking about the same
    set of moves.
    """
    return " ".join(f"{m.uci()} ({board.san(m)})" for m in board.legal_moves)


def history_san(board):
    """The game so far in the notation a player would read it in."""
    replay = chess.Board(board.root().fen())
    out, number = [], replay.fullmove_number
    for move in board.move_stack:
        if replay.turn == chess.WHITE:
            out.append(f"{number}.")
        out.append(replay.san(move))
        if replay.turn == chess.BLACK:
            number += 1
        replay.push(move)
    return " ".join(out) if out else "(no moves yet -- this is the first move)"


def build_prompt(board, persona_text, correction=None):
    colour = "White" if board.turn == chess.WHITE else "Black"
    parts = [
        f"You are playing a game of chess as {colour}. It is your move.",
        "",
        persona_text,
        "",
        f"Position (FEN): {board.fen()}",
        f"Moves so far: {history_san(board)}",
    ]
    if board.is_check():
        parts.append("You are in check.")
    parts += [
        "",
        "Your legal moves, in UCI notation with the algebraic in brackets:",
        move_menu(board),
        "",
    ]
    if correction:
        parts += [
            f"IMPORTANT: you answered {correction!r}, which is not one of those"
            " moves. Look at the list again and pick a move from it.",
            "",
        ]
    parts += [
        "Reply with your reasoning if you want it, but the LAST line of your"
        " reply must be exactly:",
        "MOVE: <uci>",
        "where <uci> is copied from the list above, e.g. MOVE: e2e4",
    ]
    return "\n".join(parts)


MOVE_LINE = re.compile(r"MOVE:\s*([A-Za-z0-9=+#\-]+)")
TOKEN = re.compile(r"[A-Za-z0-9=+#\-]+")


def extract_move(text, board):
    """Find a legal move in Claude's reply, or None.

    Deliberately forgiving. The asked-for `MOVE: e2e4` is tried first, but an
    answer of "Nf3" or a move mentioned in a closing sentence is a move, and
    rejecting it on formatting would spend a whole extra round trip proving a
    point. Anything that parses as legal in this position is accepted; nothing
    else is.
    """
    candidates = MOVE_LINE.findall(text)
    # Last first: if it reasoned aloud, the final answer is the one it meant.
    candidates.reverse()
    if not candidates:
        candidates = list(reversed(TOKEN.findall(text)))

    for token in candidates:
        try:
            move = chess.Move.from_uci(token.lower())
            if move in board.legal_moves:
                return move
        except ValueError:
            pass
        try:
            return board.parse_san(token)
        except ValueError:
            continue
    return None


def fallback_move(board):
    """A legal move, when Claude has not given us one.

    Random, and loudly logged. Something better -- a capture, a check -- would
    disguise the failure as a decision; a random legal move keeps the game
    going and leaves the log as the only place that explains what happened.
    """
    return random.choice(list(board.legal_moves))


class Guard:
    """Ask, check, ask again, and never return an illegal move."""

    def __init__(self, backend, timeout=90.0, retries=1):
        self.backend = backend
        self.timeout = timeout
        self.retries = retries

    def choose(self, board, elo):
        name, persona_text = persona_for(elo)
        correction = None
        for attempt in range(self.retries + 1):
            prompt = build_prompt(board, persona_text, correction)
            started = time.time()
            try:
                reply = self.backend.ask(prompt, self.timeout)
            except subprocess.TimeoutExpired:
                log(f"[{name}] no answer within {self.timeout:.0f}s")
                break
            except Exception as err:  # noqa: BLE001 -- any failure is the same failure
                log(f"[{name}] backend failed: {err}")
                break
            elapsed = time.time() - started

            move = extract_move(reply, board)
            if move:
                log(f"[{name}] {board.san(move)} ({move.uci()}) in {elapsed:.1f}s")
                return move, False
            snippet = " ".join(reply.split())[-120:]
            log(f"[{name}] no legal move in the reply after {elapsed:.1f}s: …{snippet}")
            correction = snippet[-40:]

        move = fallback_move(board)
        log(f"[{name}] FALLING BACK to a random legal move: {board.san(move)}")
        notify("fallback", f"could not get a move from Claude; played {board.san(move)}")
        return move, True


# --------------------------------------------------------------------------
# The UCI side
# --------------------------------------------------------------------------


class Session:
    """One conversation in UCI, over one pair of streams.

    A connection from the Kobo gets one of these, and so does --stdio, which
    is why the transport is a pair of file objects and nothing more.
    """

    def __init__(self, guard, write_line):
        self.guard = guard
        self.write_line = write_line
        self.board = chess.Board()
        self.elo = None                # None means full strength
        self.limit_strength = False
        self.generation = 0            # bumped by `stop`, to orphan a search
        self.searching = False
        self.lock = threading.Lock()

    # -- output ------------------------------------------------------------

    def send(self, line):
        try:
            self.write_line(line)
        except OSError:
            pass  # the Kobo has gone; the reader loop will notice

    # -- input -------------------------------------------------------------

    def handle(self, line):
        """Returns False when the engine should shut this session down."""
        line = line.strip()
        if not line:
            return True
        word, _, rest = line.partition(" ")

        if word == "uci":
            self.send(f"id name {ENGINE_NAME}")
            self.send(f"id author {ENGINE_AUTHOR}")
            # Declared so the plugin's setoption lines have somewhere to land.
            # Threads, Hash and EvalFile mean nothing here, but an engine that
            # does not declare them is an engine the plugin is configuring
            # into thin air, and it costs three lines to be honest about it.
            self.send("option name UCI_LimitStrength type check default false")
            self.send("option name UCI_Elo type spin default 1500 min 1320 max 2850")
            self.send("option name Threads type spin default 1 min 1 max 1")
            self.send("option name Hash type spin default 1 min 1 max 1")
            self.send("uciok")
        elif word == "isready":
            self.send("readyok")
        elif word == "ucinewgame":
            self.board = chess.Board()
        elif word == "setoption":
            self.set_option(rest)
        elif word == "position":
            self.set_position(rest)
        elif word == "go":
            self.start_search()
        elif word == "stop":
            self.stop_search()
        elif word == "quit":
            return False
        return True

    def set_option(self, rest):
        match = re.match(r"name\s+(.+?)\s+value\s+(.+)$", rest.strip())
        if not match:
            return
        name, value = match.group(1).strip(), match.group(2).strip()
        if name == "UCI_LimitStrength":
            self.limit_strength = value.lower() == "true"
            if not self.limit_strength:
                self.elo = None
        elif name == "UCI_Elo":
            try:
                self.elo = int(value)
            except ValueError:
                pass

    def set_position(self, rest):
        """`position startpos|fen <fen> [moves ...]`.

        The plugin sends the whole move list rather than a bare FEN, so that
        an engine can see repetitions. Replaying it here means Claude gets the
        game's actual history to read, which is worth more to it than to
        Stockfish.
        """
        tokens = rest.split()
        if not tokens:
            return
        if tokens[0] == "startpos":
            board = chess.Board()
            rest_tokens = tokens[1:]
        elif tokens[0] == "fen":
            fen = " ".join(tokens[1:7])
            board = chess.Board(fen)
            rest_tokens = tokens[7:]
        else:
            return
        if rest_tokens and rest_tokens[0] == "moves":
            for uci in rest_tokens[1:]:
                try:
                    board.push_uci(uci)
                except ValueError:
                    log(f"cannot replay {uci} -- ignoring the rest of the move list")
                    break
        self.board = board

    # -- searching ---------------------------------------------------------

    def start_search(self):
        """Answer a `go`, on a thread, so `stop` can still be read.

        The go's limits -- depth, movetime -- are read and ignored. Claude
        takes as long as it takes, and pretending to honour a 300ms movetime
        by hurrying would only produce a worse move at the same speed.
        """
        with self.lock:
            self.generation += 1
            generation = self.generation
            self.searching = True
        board = self.board.copy()
        elo = self.elo if self.limit_strength else None

        def work():
            if board.is_game_over():
                self.finish(generation, "bestmove (none)")
                return
            move, was_fallback = self.guard.choose(board, elo)
            if was_fallback:
                self.send("info string fell back to a random legal move")
            self.finish(generation, f"bestmove {move.uci()}")

        threading.Thread(target=work, daemon=True).start()

    def finish(self, generation, line):
        with self.lock:
            if generation != self.generation:
                # A `stop` already answered for this search; the plugin has
                # moved on and a second bestmove would only confuse it.
                log("discarding a move for a search that was stopped")
                return
            self.searching = False
        self.send(line)

    def stop_search(self):
        """UCI says a stopped search still owes a bestmove, and promptly.

        We cannot interrupt a request that is already in flight, so the
        promise is kept with a legal move the plugin is about to throw away
        anyway -- it only sends `stop` when it has stopped caring -- and the
        real answer, when it arrives, is dropped by the generation check.
        """
        with self.lock:
            if not self.searching:
                return
            self.generation += 1
            self.searching = False
            board = self.board
        if board.is_game_over():
            self.send("bestmove (none)")
        else:
            self.send(f"bestmove {fallback_move(board).uci()}")

    # -- driving -----------------------------------------------------------

    def run(self, read_line):
        while True:
            line = read_line()
            if not line:
                return
            log(f"< {line.strip()}")
            if not self.handle(line):
                return


# --------------------------------------------------------------------------
# Transports
# --------------------------------------------------------------------------

LOG_LOCK = threading.Lock()
LOG_FILE = None


def log(message):
    stamp = time.strftime("%H:%M:%S")
    line = f"{stamp} {message}"
    with LOG_LOCK:
        print(line, file=sys.stderr, flush=True)
        if LOG_FILE:
            LOG_FILE.write(line + "\n")
            LOG_FILE.flush()


NOTIFY_COMMAND = None


def notify(event, text):
    """Tell somebody outside this process that something happened.

    The daemon runs unattended, so the two things worth being told about are
    a device connecting -- the game asking for an opponent -- and a move that
    had to fall back, which is the shape a broken backend takes when seen
    from the Kobo: a board that plays on, badly, without explaining itself.

    The hook is a command rather than a built-in notifier so that what it
    does is a matter of editing one small script, and so that a hook which
    hangs or fails cannot hold up a move: it is started and forgotten.
    """
    log(f"! {event}: {text}")
    if not NOTIFY_COMMAND:
        return
    try:
        subprocess.Popen(
            [NOTIFY_COMMAND, event, text],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
    except OSError as err:
        log(f"notify hook failed: {err}")


def serve_stdio(guard):
    def write_line(line):
        log(f"> {line}")
        sys.stdout.write(line + "\n")
        sys.stdout.flush()

    Session(guard, write_line).run(sys.stdin.readline)


def serve_socket(guard, host, port):
    class Handler(socketserver.StreamRequestHandler):
        # A dead Kobo should not hold the engine open forever, but the timeout
        # has to outlast a long think plus a long stare at the board.
        timeout = 3600

        def handle(self):
            peer = self.client_address[0]
            log(f"--- {peer} connected")
            notify("connect", f"a game started from {peer}")

            def write_line(line):
                log(f"> {line}")
                self.wfile.write((line + "\n").encode())
                self.wfile.flush()

            def read_line():
                raw = self.rfile.readline()
                return raw.decode("utf-8", "replace") if raw else ""

            try:
                Session(guard, write_line).run(read_line)
            except (OSError, ConnectionError) as err:
                log(f"--- {peer} dropped: {err}")
            log(f"--- {peer} disconnected")
            notify("disconnect", f"the game from {peer} ended")

    class Server(socketserver.ThreadingTCPServer):
        allow_reuse_address = True
        daemon_threads = True

    with Server((host, port), Handler) as server:
        log(f"listening on {host}:{port} -- backend {guard.backend.describe()}")
        server.serve_forever()


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[1])
    parser.add_argument("--host", default="0.0.0.0",
                        help="address to listen on (default: all)")
    parser.add_argument("--port", type=int, default=9666)
    parser.add_argument("--stdio", action="store_true",
                        help="speak UCI on stdin/stdout instead of listening")
    parser.add_argument("--backend", choices=("cli", "api", "rehearsal"),
                        default="cli",
                        help="ask through the claude CLI (default) or the API;"
                             " 'rehearsal' plays random legal moves, for"
                             " testing the plumbing without a model")
    parser.add_argument("--model", default=None)
    parser.add_argument("--effort", default="medium",
                        choices=("low", "medium", "high", "xhigh", "max"),
                        help="API backend only: how hard to think per move")
    parser.add_argument("--timeout", type=float, default=90.0,
                        help="seconds to wait for a move before falling back")
    parser.add_argument("--claude-binary", default=os.environ.get("CLAUDE_BIN", "claude"))
    parser.add_argument("--log", default=None, help="also append the log here")
    parser.add_argument("--on-event", default=None, metavar="CMD",
                        help="run CMD <event> <text> when a game starts or ends,"
                             " or when a move had to be invented")
    args = parser.parse_args()

    global LOG_FILE, NOTIFY_COMMAND
    NOTIFY_COMMAND = args.on_event
    if args.log:
        LOG_FILE = open(args.log, "a")

    if args.backend == "rehearsal":
        backend = RehearsalBackend()
    elif args.backend == "api":
        backend = ApiBackend(model=args.model, effort=args.effort)
    else:
        backend = CliBackend(binary=args.claude_binary, model=args.model)

    guard = Guard(backend, timeout=args.timeout)

    if args.stdio:
        serve_stdio(guard)
    else:
        serve_socket(guard, args.host, args.port)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
