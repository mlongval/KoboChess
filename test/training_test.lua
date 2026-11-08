--[[--
Tests for training: PGN and SAN parsing, puzzle checking and rating, the
opening matcher and trainer, and guess-the-move scoring. Also checks that
every bundled puzzle, opening and master game actually plays on our board.

    luajit test/training_test.lua
--]]--

package.path = "kobochess.koplugin/?.lua;" .. package.path

local Board = require("kobochess.board")
local Masters = require("kobochess.masters")
local Openings = require("kobochess.openings")
local Pgn = require("kobochess.pgn")
local Puzzles = require("kobochess.puzzles")

local WHITE, BLACK = Board.WHITE, Board.BLACK
local DATA = "kobochess.koplugin/data/"

local failures = 0

local function check(ok, what)
    print(("  %-5s %s"):format(ok and "ok" or "FAIL", what))
    if not ok then failures = failures + 1 end
end

local function uciOf(fen, san)
    local b = Board.new(fen)
    local m = Pgn.sanToMove(b, san)
    return m and b:moveToUci(m)
end

print("=== SAN ===")
do
    check(uciOf(nil, "e4") == "e2e4", "a pawn push")
    check(uciOf(nil, "Nf3") == "g1f3", "a knight move")
    check(uciOf(nil, "Ngf3") == "g1f3", "an over-specified move is still understood")
    check(uciOf(nil, "Nf3+!?") == "g1f3", "check marks and annotations are ignored")
    check(uciOf(nil, "Ke2") == nil, "an illegal move is refused")
    check(uciOf(nil, "Bc4") == nil, "a blocked bishop cannot move")

    local castle = "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1"
    check(uciOf(castle, "O-O") == "e1g1", "castling short")
    check(uciOf(castle, "O-O-O") == "e1c1", "castling long")
    check(uciOf(castle, "0-0") == "e1g1", "castling written with zeros")

    local rooks = "4k3/8/8/8/8/8/4K3/R6R w - - 0 1"
    check(uciOf(rooks, "Rd1") == nil, "an ambiguous move is refused")
    check(uciOf(rooks, "Rad1") == "a1d1", "a file disambiguates")
    check(uciOf(rooks, "Rhf1") == "h1f1", "the other rook")
    local stacked = "4k3/8/8/8/R7/8/8/R3K3 w - - 0 1"
    check(uciOf(stacked, "R1a2") == "a1a2", "a rank disambiguates")

    local promo = "8/4P1k1/8/8/8/8/8/4K3 w - - 0 1"
    check(uciOf(promo, "e8=Q") == "e7e8q", "promotion to a queen")
    check(uciOf(promo, "e8N") == "e7e8n", "underpromotion without '='")
    check(uciOf(promo, "e8") == "e7e8q", "promotion with no piece means a queen")

    local ep = "4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 1"
    check(uciOf(ep, "exd6") == "e5d6", "en passant")
    check(uciOf(ep, "ed6") == "e5d6", "a capture without the x")
end

print("\n=== PGN ===")
do
    local text = [[
[Event "Test"]
[White "A"]
[Black "B"]
[Result "1-0"]

1. e4 {the king's pawn} e5 2. Nf3 (2. f4 exf4 (2... d5) 3. Nf3) Nc6 $1
3. Bb5 a6 1-0

[Event "Second"]
[Result "*"]

1.d4 d5 2.c4 dxc4 3.e3 3...Nf6? *

[Event "Broken"]

1. e4 e5 2. Ke3 Nc6
]]
    local games = Pgn.parse(text)
    check(#games == 3, "three games are found")
    local g = games[1]
    check(g.tags.White == "A" and g.tags.Event == "Test", "tags are read")
    check(#g.sans == 6 and g.sans[3] == "Nf3" and g.sans[4] == "Nc6",
          "comments, variations and NAGs are skipped")
    check(g.ucis[5] == "f1b5", "moves are resolved to UCI")
    check(g.result == "1-0" and not g.error, "the result, and no error")
    check(#games[2].sans == 6 and games[2].sans[6] == "Nf6?" and not games[2].error, "glued move numbers and '...' are handled")
    check(games[3].error ~= nil and #games[3].sans == 2, "an illegal move is reported, the moves before it kept")
    check(games[3].error and games[3].error:find("move 3") ~= nil, "and says which move")

    local sans = Pgn.lineToSans("1. e4 c5 2. Nf3 d6")
    check(#sans == 4 and sans[4] == "d6", "an opening line")
end

print("\n=== the master games ===")
do
    local games = Masters.load(DATA .. "masters.pgn")
    check(#games >= 10, ("the collection holds %d games"):format(#games))
    local all_ok, mates_ok = true, true
    for _, g in ipairs(games) do
        if g.error or #g.moves < 10 then
            all_ok = false
            print("    bad game: " .. Masters.title(g) .. " " .. tostring(g.error))
        end
        local b = Pgn.playSans(g.sans, g.start_fen)
        if g.sans[#g.sans]:find("#") and not (b and b:getGameResult() == "checkmate") then
            mates_ok = false
            print("    not mate: " .. Masters.title(g))
        end
    end
    check(all_ok, "every game plays to the end")
    check(mates_ok, "every game marked as ending in mate does end in mate")

    local immortal
    for _, g in ipairs(games) do
        if g.tags.Black == "Lionel Kieseritzky" then immortal = g end
    end
    check(immortal ~= nil, "the Immortal Game is there")
    local v = Masters.view(immortal)
    v:goTo(5)
    check(v.ply == 5 and v.board.side == BLACK, "go to a move")
    v:back(); v:back()
    check(v.ply == 3, "and back")
    v:forward()
    check(v.ply == 4 and v.board:getFen() == Pgn.playSans({ "e4", "e5", "f4", "exf4" }):getFen(),
          "stepping gives the right position")
    v:goTo(1000)
    check(v.ply == #immortal.moves, "the end is the end")
    check(Masters.title(immortal) == "Anderssen – Kieseritzky, London 1851", "a title")
    check(v:moveListText():sub(1, 13) == "1. e4 e5 2. f", "a move list")

    -- guess the move
    v = Masters.view(immortal)
    v:startGuessing(WHITE)
    check(v:isGuessTurn(), "White's move is to be guessed")
    local r, pts = v:tryGuess(v.board:moveFromUci("e2e4"))
    check(r == "right" and pts == 2 and v.ply == 1, "a right first guess scores 2")
    check(not v:isGuessTurn(), "then it is Black's move, not guessed")
    v:forward()
    r = v:tryGuess(v.board:moveFromUci("g1f3"))
    check(r == "again" and v.ply == 2, "a wrong guess gets another try")
    r, pts = v:tryGuess(v.board:moveFromUci("f2f4"))
    check(r == "right" and pts == 1, "right at the second try scores 1")
    v:forward()
    v:tryGuess(v.board:moveFromUci("a2a3"))
    local r2, shown = v:tryGuess(v.board:moveFromUci("a2a4"))
    check(r2 == "shown" and shown ~= nil and v.ply == 5,
          "two misses show the master's move")
    check(v.guess.score == 3 and v.guess.possible == 6, "score 3 out of 6")
    check(Masters.defaultGuessSide(immortal) == WHITE, "guess the winner's moves")
end

print("\n=== puzzles ===")
do
    local p = Puzzles.parseLine("abc12\t6k1/5ppp/8/8/8/8/5PPP/R5K1 b - - 0 1\th7h6 a1a8\t900\tbackRankMate mateIn1 endgame")
    check(p and p.id == "abc12" and #p.moves == 2 and p.rating == 900, "a data line")
    check(Puzzles.themesText(p) == "Mate in 1, Back rank mate, Endgame", "themes in words")
    check(Puzzles.themeName("hangingPiece") == "Hanging piece" and Puzzles.themeName("someNewTheme") == "Some new theme",
          "theme names, known and unknown")

    local s = Puzzles.start(p)
    check(s and s.solver == WHITE, "the opponent's move is played; the solver is White")
    check(s:try(s.board:moveFromUci("a1a7")) == "wrong" and s.mistakes == 1, "a wrong move is refused")
    check(s.board:getFen():find("^6k1/5pp1/7p/") ~= nil, "and not played")
    check(s:try(s.board:moveFromUci("a1a8")) == "solved", "the right move solves it")
    check(not s:isClean(), "with a mistake on the way, not clean")

    -- a longer one: the opponent replies in between
    local long = { id = "x", rating = 1500, themes = {},
        fen = "r1bqkbnr/pppp1ppp/2n5/4p3/2B1P3/5Q2/PPPP1PPP/RNB1K1NR w KQkq - 0 1",
        moves = { "a2a3", "g8f6", "f3f6", "d8f6" } }
    -- (a contrived line; only the mechanics matter)
    s = Puzzles.start(long)
    local res, reply = s:try(s.board:moveFromUci("g8f6"))
    check(res == "correct" and reply ~= nil, "a right move gets the opponent's answer")
    check(s:try(s.board:moveFromUci("d8f6")) == "solved", "and the last move finishes it")
    check(s:isClean(), "a clean solve")

    -- any mate is accepted at the last move
    local two_mates = { id = "m", rating = 1000, themes = { "mateIn1" },
        fen = "7k/6pp/8/8/8/8/1Q6/R5K1 w - - 0 1", moves = { "g1f1", "a1a8" } }
    -- after Kf1 it is Black's move in this contrived position, so set up
    -- White to move by starting from Black's last move instead
    two_mates.fen = "6k1/6pp/8/8/8/8/1Q6/R5K1 b - - 0 1"
    two_mates.moves = { "g8h8", "a1a8" }
    s = Puzzles.start(two_mates)
    check(s:try(s.board:moveFromUci("b2b8")) == "solved", "a different mate is accepted too")

    -- rating
    check(Puzzles.updateRating(1500, 1500, true, 50) == 1510, "a win against an equal puzzle: +10")
    check(Puzzles.updateRating(1500, 1500, false, 50) == 1490, "a loss: -10")
    check(Puzzles.updateRating(1500, 1500, true, 0) == 1520, "moves faster at first")
    check(Puzzles.updateRating(1200, 2200, true, 50) > 1215, "beating a much harder puzzle pays")
    check(Puzzles.updateRating(450, 1500, false, 50) >= Puzzles.MIN_RATING, "never below the floor")
    local st = Puzzles.stats(nil)
    check(st.rating == Puzzles.START_RATING and st.played == 0, "fresh stats")
    local d = Puzzles.record(st, { id = "q", rating = 1200 }, true)
    check(d == 20 and st.solved == 1 and st.streak == 1 and st.done.q == 1, "a solve is recorded")
    Puzzles.record(st, { id = "r", rating = 1200 }, false)
    check(st.streak == 0 and st.best_streak == 1 and st.played == 2, "a failure ends the streak")

    -- the bundled collection
    local list = Puzzles.load(DATA .. "puzzles.tsv")
    check(#list >= 2000, ("%d puzzles bundled"):format(#list))
    check(list[1].rating <= 900 and list[#list].rating >= 2100, "spread from ~800 to ~2200")
    local bad = 0
    for _, q in ipairs(list) do
        local sess = Puzzles.start(q)
        if not sess then
            bad = bad + 1
        else
            -- play the whole solution
            while not sess.solved do
                local m = sess:expectedMove()
                if not m or sess:try(m) == "wrong" then bad = bad + 1; break end
            end
        end
    end
    check(bad == 0, ("every bundled puzzle plays through (%d bad)"):format(bad))

    local seq = 0
    local function rand(n) seq = seq + 1; return (seq % n) + 1 end
    local near = Puzzles.pick(list, 1500, {}, rand)
    check(math.abs(near.rating - 1500) <= 75, "a puzzle near the rating is picked")
    local done = {}
    for _, q in ipairs(list) do if math.abs(q.rating - 1500) <= 300 then done[q.id] = 1 end end
    local fresh = Puzzles.pick(list, 1500, done, rand)
    check(not done[fresh.id], "puzzles already done are skipped")
    local a = Puzzles.daily(list, { year = 2026, month = 11, day = 8 })
    local b = Puzzles.daily(list, { year = 2026, month = 11, day = 8 })
    local c = Puzzles.daily(list, { year = 2026, month = 11, day = 9 })
    check(a == b and a ~= c, "the puzzle of the day is fixed for a day and changes the next")
    check(Puzzles.dateKey({ year = 2026, month = 1, day = 2 }) == "2026-01-02", "a date key")
end

print("\n=== openings ===")
do
    local book = Openings.load(DATA .. "openings.tsv")
    check(#book.list > 3000, ("%d openings loaded"):format(#book.list))
    check(#book.families > 100, ("%d families"):format(#book.families))
    local fam, var = Openings.splitName("Sicilian Defense: Najdorf Variation, English Attack")
    check(fam == "Sicilian Defense" and var == "Najdorf Variation, English Attack", "a name is split")

    local e = Openings.match(book, { "e2e4", "c7c5" })
    check(e and e.name == "Sicilian Defense", "1. e4 c5 is the Sicilian")
    e = Openings.match(book, { "e2e4", "e7e5", "g1f3", "b8c6", "f1c4" })
    check(e and e.name == "Italian Game", "the Italian Game")
    local a1 = Openings.match(book, { "d2d4", "g8f6", "c2c4", "e7e6", "b1c3", "f8b4" })
    local a2 = Openings.match(book, { "c2c4", "e7e6", "b1c3", "g8f6", "d2d4", "f8b4" })
    check(a1 and a2 and a1.name == a2.name, "a transposition gets the same name (" .. (a1 and a1.name or "?") .. ")")
    local out, at = Openings.match(book, { "e2e4", "c7c5", "a2a3", "h7h6", "h2h3", "a7a6" })
    check(out and at <= 3, "a game out of the book keeps the last name it had (" .. (out and out.name or "?") .. ")")
    check(Openings.match(book, {}) == nil, "no name before the first move")

    -- every line plays
    local broken = 0
    for _, entry in ipairs(book.list) do
        local b = Board.new()
        for _, uci in ipairs(entry.moves) do
            local m = b:moveFromUci(uci)
            if not m then broken = broken + 1; break end
            b:makeMove(m)
        end
    end
    check(broken == 0, "every opening line is legal")

    -- the trainer
    local ruy
    for _, x in ipairs(book.by_family["Ruy Lopez"] or {}) do
        if x.name == "Ruy Lopez" then ruy = x end
    end
    check(ruy ~= nil and #ruy.moves == 5, "the Ruy Lopez main line")
    local dr = Openings.drill(ruy, BLACK)
    check(dr:isTrainerTurn(), "as Black, the trainer starts")
    dr:playTrainer()
    local ok, book_move = dr:try(dr.board:moveFromUci("c7c5"))
    check(not ok and dr.board:moveToUci(book_move) == "e7e5" and dr.mistakes == 1,
          "a wrong move is refused and the book move given")
    check(dr:try(dr.board:moveFromUci("e7e5")) == true, "the book move is accepted")
    dr:playTrainer()
    dr:try(dr.board:moveFromUci("b8c6"))
    dr:playTrainer()
    check(dr:isDone(), "the line is done after the trainer's last move")
    check(not dr:isClean(), "not clean, there was a mistake")

    local progress = {}
    local r = Openings.record(progress, ruy, BLACK, true)
    Openings.record(progress, ruy, BLACK, true)
    check(not r.learned and r.clean_streak == 2, "two clean runs: not learned yet")
    r = Openings.record(progress, ruy, BLACK, true)
    check(r.learned, "three in a row: learned")
    r = Openings.record(progress, ruy, WHITE, false)
    check(r.runs == 1 and r.clean_streak == 0, "White's progress is kept apart")
end

print()
if failures > 0 then
    print(("%d FAILED"):format(failures))
    os.exit(1)
end
print("all passed")
