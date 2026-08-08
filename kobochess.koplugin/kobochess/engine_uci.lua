--[[--
Talk to an external UCI engine -- Stockfish, or anything else that speaks the
protocol -- over a pipe, without ever blocking KOReader's UI.

The engine is a separate process, so the awkward part is not the protocol but
the reading. A plain `read()` on a pipe blocks until there is something to
read, which in a single-threaded UI means the screen freezes for as long as
the engine is thinking. Instead, every poll asks the kernel how many bytes are
waiting (FIONREAD) and reads exactly that many, which cannot block. The widget
calls `poll()` from its tick loop, the same way it steps the Lua engine's
coroutine, so both engines are driven identically.

The process is started once and kept alive for the session. Modern engines
load a neural network of tens of megabytes at startup, and paying that on
every move would be far more expensive than the search itself.

@module kobochess.engine_uci
--]]--

local ffi = require("ffi")
local ffiutil = require("ffi/util")
local logger = require("logger")
local UIManager = require("ui/uimanager")

local Search = require("kobochess.search")

local C = ffi.C

-- execv rather than KOReader's already-declared execvp. They differ in what
-- they do when the file is not something the kernel can execute -- a binary
-- for the wrong architecture, most likely: execvp hands it to /bin/sh, which
-- tries to read the machine code as a shell script and reports a syntax
-- error. execv simply fails, which is both truthful and easier to explain.
ffi.cdef[[ int execv(const char *, char *const[]); ]]

--- Collect an exited engine, so it does not linger as a zombie.
--
-- The kernel keeps a dead child around until its parent asks for its exit
-- status. KOReader's helper only kills; collecting is the caller's job, and
-- it cannot be done in one go, because the process takes a moment to die
-- after the signal. So: try, and try again shortly, a bounded number of
-- times. Blocking until it is gone would be simpler and would risk hanging
-- the UI on a process wedged in a state a signal cannot interrupt.
local function reap(pid, attempts)
    if ffiutil.isSubProcessDone(pid) then return end
    if attempts <= 0 then
        logger.warn("KoboChess: gave up collecting engine process", pid)
        return
    end
    UIManager:scheduleIn(0.2, function() reap(pid, attempts - 1) end)
end

local UciEngine = {}
UciEngine.__index = UciEngine

-- How the six levels map onto a UCI engine. A modern engine is far too strong
-- to play straight, so the lower levels ask it to play badly on purpose:
-- UCI_Elo is a rating target the engine implements itself, which loses in
-- more human ways than simply searching less deeply would.
--
-- The names match Search.LEVELS, so the Level menu reads the same whichever
-- engine is selected.
local UCI_LEVELS = {
    { elo = 1320, movetime = 300 },
    { elo = 1500, movetime = 500 },
    { elo = 1800, movetime = 800 },
    { elo = 2200, movetime = 1200 },
    { elo = 2600, movetime = 2500 },
    { elo = nil,  movetime = 5000 },   -- nil: full strength
}

-- Give up if the engine has not finished its handshake by then. A binary for
-- the wrong architecture typically dies immediately, and without this the UI
-- would wait for it forever.
local HANDSHAKE_TIMEOUT = 20

-- Deliberately small. The device has a single core and not much memory, and
-- the engine is sharing both with the reader it is running inside.
local DEFAULT_HASH_MB = 16

function UciEngine.new(opts)
    local self = setmetatable({}, UciEngine)
    self.path = opts.path                -- the executable
    self.net = opts.net                  -- an .nnue to point EvalFile at, if any
    self.display_name = opts.name or "UCI engine"
    self.now = opts.now or os.time
    self.hash_mb = opts.hash_mb or DEFAULT_HASH_MB
    self.state = "stopped"               -- stopped|handshake|ready|thinking|dead
    self.buffer = ""
    -- Polling an external process is just checking a pipe, so it must not run
    -- flat out: the engine is on the same single core, and a caller spinning
    -- on nextTick would be taking the CPU away from the thing it is waiting
    -- for. The Lua engine, whose poll does the actual searching, sets none.
    self.poll_interval = 0.05
    return self
end

function UciEngine:name() return self.display_name end
function UciEngine:isThinking() return self.state == "thinking" end
function UciEngine:isDead() return self.state == "dead" end

--==========================================================================
-- The process
--==========================================================================

--- Start the engine and begin the UCI handshake.
--
-- The child is forked by KOReader's helper -- which also puts it in its own
-- process group and nices it, both of which we want -- and then replaced by
-- the engine with its stdin and stdout wired to our pipes.
function UciEngine:start()
    if self.pid then return true end
    if self.state == "dead" then return false, "engine failed earlier" end

    local exe = self.path
    local pid, read_fd, write_fd = ffiutil.runInSubProcess(
        function(_pid, child_write_fd, child_read_fd)
            C.dup2(child_read_fd, 0)
            C.dup2(child_write_fd, 1)
            -- The engine's own path is argv[0]; some engines look beside it
            -- for their network file.
            local argv0 = ffi.new("char[?]", #exe + 1, exe)
            local argv = ffi.new("char*[2]")
            argv[0] = argv0
            argv[1] = nil
            C.execv(argv0, argv)
            -- Only reachable if exec failed; the parent will see the pipe
            -- close and give up on the handshake.
            C._exit(127)
        end, "bidi")

    if not pid or pid == false then
        self.state = "dead"
        return false, tostring(read_fd)
    end

    self.pid, self.read_fd, self.write_fd = pid, read_fd, write_fd
    self.state = "handshake"
    self.buffer = ""
    self.handshake_started = self.now()
    self:send("uci")
    return true
end

function UciEngine:close()
    if not self.pid then return end
    -- "quit" lets it exit cleanly and flush; the kill is the backstop for an
    -- engine that is wedged mid-search and not reading its input.
    local pid = self.pid
    pcall(function() self:send("quit") end)
    pcall(function() ffiutil.terminateSubProcess(pid) end)
    if self.read_fd then C.close(self.read_fd) end
    if self.write_fd then C.close(self.write_fd) end
    self.pid, self.read_fd, self.write_fd = nil, nil, nil
    self.state = "stopped"
    reap(pid, 10)
end

--- Tell the engine a new game has started, so it discards what it learned
--- about the last one.
function UciEngine:reset()
    if self.state == "ready" or self.state == "thinking" then
        self:send("ucinewgame")
        self:send("isready")
    end
end

function UciEngine:send(line)
    if not self.write_fd then return false end
    logger.dbg("KoboChess UCI >", line)
    return ffiutil.writeToFD(self.write_fd, line .. "\n")
end

--- Read whatever has arrived, without blocking.
-- FIONREAD reports how many bytes are already buffered in the pipe, so a read
-- of exactly that size is guaranteed not to wait.
function UciEngine:readAvailable()
    if not self.read_fd then return nil end
    local size = ffiutil.getNonBlockingReadSize(self.read_fd)
    if not size or size <= 0 then return nil end
    local buf = ffi.new("char[?]", size)
    local got = tonumber(C.read(self.read_fd, buf, size))
    if not got or got <= 0 then return nil end
    return ffi.string(buf, got)
end

--==========================================================================
-- Protocol
--==========================================================================

function UciEngine:configure()
    self:send("setoption name Threads value 1")
    self:send(("setoption name Hash value %d"):format(self.hash_mb))
    if self.net then
        self:send(("setoption name EvalFile value %s"):format(self.net))
    end
    self:send("isready")
end

--- Apply a level, or lift the restriction for full strength.
function UciEngine:applyLevel(level)
    local limits = UCI_LEVELS[level] or UCI_LEVELS[#UCI_LEVELS]
    if limits.elo then
        self:send("setoption name UCI_LimitStrength value true")
        self:send(("setoption name UCI_Elo value %d"):format(limits.elo))
    else
        self:send("setoption name UCI_LimitStrength value false")
    end
    return limits
end

--- UCI reports scores from the side to move's point of view, in centipawns,
--- which is what the rest of the program uses too. Mates need converting to
--- the internal representation so they format the same way.
local function parseScore(kind, value)
    if kind == "mate" then
        local plies = math.abs(value) * 2 - 1
        local score = Search.MATE_VALUE - plies
        return value >= 0 and score or -score
    end
    return value
end

function UciEngine:handleLine(line)
    logger.dbg("KoboChess UCI <", line)

    if line == "uciok" then
        self:configure()
        return
    end

    if line == "readyok" then
        if self.state == "handshake" then
            self.state = "ready"
            -- A search asked for before the engine was ready has been held
            -- back until now.
            if self.pending then
                local pending = self.pending
                self.pending = nil
                self:think(pending)
            end
        end
        return
    end

    local best = line:match("^bestmove%s+(%S+)")
    if best then
        local on_done = self.on_done
        self.state = "ready"
        self.on_done, self.on_progress = nil, nil
        if on_done then
            -- "(none)" is what an engine returns when the game is already
            -- over in the position it was handed.
            on_done(best ~= "(none)" and best or nil, self.info)
        end
        return
    end

    if line:sub(1, 5) == "info " then
        local depth = tonumber(line:match("%f[%w]depth%s+(%d+)"))
        local kind, value = line:match("score%s+(%a+)%s+(-?%d+)")
        local pv = line:match("%f[%w]pv%s+(%S+)")
        local nodes = tonumber(line:match("%f[%w]nodes%s+(%d+)"))
        if nodes then
            self.info = self.info or {}
            self.info.nodes = nodes
            self.info.depth = depth or self.info.depth
        end
        -- Only lines carrying a principal variation are worth showing: the
        -- others are progress reports about a move being searched.
        if depth and pv and self.on_progress then
            local score = value and parseScore(kind, tonumber(value)) or nil
            self.on_progress(depth, score, pv)
        end
    end
end

--==========================================================================
-- Searching
--==========================================================================

--- Start a search. `opts` matches the Lua engine's:
--   game, level, max_depth, max_time, on_progress(depth, score, uci), on_done(uci, info)
function UciEngine:think(opts)
    if self.state == "stopped" then
        local ok, err = self:start()
        if not ok then return false, err end
    end
    if self.state == "dead" then return false, "engine is not running" end

    if self.state == "handshake" then
        -- Not ready yet; run it as soon as it is. The callbacks are recorded
        -- now as well as held in `pending`, so that an engine which dies
        -- during its handshake still reports back -- otherwise the caller
        -- waits for a move from a process that is already gone.
        self.pending = opts
        self.on_done = opts.on_done
        self.on_progress = opts.on_progress
        return true
    end

    self.on_done = opts.on_done
    self.on_progress = opts.on_progress
    self.info = { nodes = 0, depth = 0 }

    local limits
    if opts.level then
        limits = self:applyLevel(opts.level)
    else
        -- A hint: full strength, briefly.
        self:send("setoption name UCI_LimitStrength value false")
        limits = {}
    end

    self:send("position " .. self:positionCommand(opts.game))

    local go = { "go" }
    local movetime = opts.max_time and (opts.max_time * 1000) or limits.movetime
    if opts.max_depth then
        go[#go + 1] = "depth " .. opts.max_depth
    end
    if movetime then
        go[#go + 1] = "movetime " .. math.floor(movetime)
    end
    self.state = "thinking"
    self:send(table.concat(go, " "))
    return true
end

--- The position, given as its starting point plus the moves played.
--
-- Sent as a move list rather than a bare FEN so the engine can see the
-- repetitions: a FEN alone would let it walk into a threefold draw, or miss
-- one that saves it.
function UciEngine:positionCommand(game)
    local Board = require("kobochess.board")
    local start = game.start_fen
    local head = (start == Board.START_FEN) and "startpos"
                 or ("fen " .. start)
    if #game.moves == 0 then return head end

    local replay = Board.new(start)
    local ucis = {}
    for i = 1, #game.moves do
        ucis[i] = replay:moveToUci(game.moves[i])
        replay:makeMove(game.moves[i])
    end
    return head .. " moves " .. table.concat(ucis, " ")
end

function UciEngine:cancel()
    if self.state == "thinking" then
        -- The engine answers with a bestmove, which poll() will pick up; the
        -- widget throws it away because it asked to stop.
        self:send("stop")
    end
    self.on_progress = nil
end

--==========================================================================
-- Driving it
--==========================================================================

--- Called from the UI tick. Returns "busy" while there is something to wait
-- for, "idle" when there is not, "error" if the engine has gone.
function UciEngine:poll()
    if not self.pid then return "idle" end

    local chunk = self:readAvailable()
    while chunk do
        self.buffer = self.buffer .. chunk
        while true do
            local line, rest = self.buffer:match("^([^\n]*)\n(.*)$")
            if not line then break end
            self.buffer = rest
            self:handleLine((line:gsub("\r$", "")))
        end
        chunk = self:readAvailable()
    end

    -- An engine that has exited -- the wrong architecture, a missing network
    -- file -- would otherwise leave the UI waiting for a move that is never
    -- coming.
    if ffiutil.isSubProcessDone(self.pid) then
        local on_done = self.on_done
        self.state = "dead"
        self.pid = nil
        self.on_done, self.on_progress, self.pending = nil, nil, nil
        logger.warn("KoboChess: UCI engine exited unexpectedly:", self.path)
        if on_done then on_done(nil, nil, "the engine stopped unexpectedly") end
        return "error"
    end

    if self.state == "handshake"
       and self.now() - self.handshake_started > HANDSHAKE_TIMEOUT then
        local on_done = self.on_done
        self:close()
        self.state = "dead"
        self.on_done, self.on_progress, self.pending = nil, nil, nil
        logger.warn("KoboChess: UCI engine did not answer in time:", self.path)
        if on_done then on_done(nil, nil, "the engine did not answer") end
        return "error"
    end

    if self.state == "thinking" or self.state == "handshake" then
        return "busy"
    end
    return "idle"
end

return UciEngine
