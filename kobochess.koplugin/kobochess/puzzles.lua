--[[--
Tactical puzzles: the bundled collection, checking the solver's moves, and a
personal puzzle rating.

The puzzles come from the Lichess puzzle database (CC0), cut down by
tools/build_puzzles.py. Each one is a position and a list of moves in UCI:
the first move is the opponent's, played for the solver, and the solver must
then find every second move after it, the opponent answering in between.

Nothing here touches the screen, so it is all testable with plain LuaJIT
(test/training_test.lua).

@module kobochess.puzzles
--]]--

local Board = require("kobochess.board")

local Puzzles = {}

Puzzles.START_RATING = 1200
Puzzles.MIN_RATING = 400
Puzzles.MAX_RATING = 3000

--==========================================================================
-- The collection
--==========================================================================

--- One line of the data file as a puzzle table, or nil if it is malformed.
function Puzzles.parseLine(line)
    local id, fen, moves, rating, themes =
        line:match("^([^\t]+)\t([^\t]+)\t([^\t]+)\t(%d+)\t?([^\t]*)")
    if not id then return nil end
    local list = {}
    for m in moves:gmatch("%S+") do list[#list + 1] = m end
    if #list < 2 then return nil end
    local theme_list = {}
    for t in themes:gmatch("%S+") do theme_list[#theme_list + 1] = t end
    return { id = id, fen = fen, moves = list, rating = tonumber(rating),
             themes = theme_list }
end

--- Read the data file. Returns the list (sorted by rating, as written).
function Puzzles.load(path)
    local f = io.open(path, "r")
    if not f then return {} end
    local list = {}
    for line in f:lines() do
        local p = Puzzles.parseLine(line)
        if p then list[#list + 1] = p end
    end
    f:close()
    table.sort(list, function(a, b) return a.rating < b.rating end)
    return list
end

local THEME_WORDS = {
    mateIn1 = "Mate in 1", mateIn2 = "Mate in 2", mateIn3 = "Mate in 3",
    mateIn4 = "Mate in 4", mateIn5 = "Mate in 5",
    crushing = "Winning", advantage = "Advantage", equality = "Equality",
    middlegame = "Middlegame", endgame = "Endgame", opening = "Opening",
    hangingPiece = "Hanging piece", kingsideAttack = "Kingside attack",
    queensideAttack = "Queenside attack", backRankMate = "Back rank mate",
    smotheredMate = "Smothered mate", discoveredAttack = "Discovered attack",
    doubleCheck = "Double check", trappedPiece = "Trapped piece",
    advancedPawn = "Advanced pawn", attackingF2F7 = "Attack on f2/f7",
    exposedKing = "Exposed king", quietMove = "Quiet move",
    defensiveMove = "Defensive move", capturingDefender = "Removing the defender",
    xRayAttack = "X-ray attack", enPassant = "En passant",
}

--- A theme tag in words: "hangingPiece" -> "Hanging piece".
function Puzzles.themeName(tag)
    if THEME_WORDS[tag] then return THEME_WORDS[tag] end
    local words = tag:gsub("(%l)(%u)", "%1 %2"):gsub("(%a)(%d)", "%1 %2"):lower()
    return (words:gsub("^%l", string.upper))
end

--- Themes in words, the length tag ("mate in 2") first.
function Puzzles.themesText(puzzle, max)
    local names = {}
    for _, t in ipairs(puzzle.themes) do
        if t:match("^mateIn") then table.insert(names, 1, Puzzles.themeName(t))
        else names[#names + 1] = Puzzles.themeName(t) end
    end
    if max and #names > max then
        for i = #names, max + 1, -1 do names[i] = nil end
    end
    return table.concat(names, ", ")
end

--==========================================================================
-- Choosing a puzzle
--==========================================================================

--- A puzzle near `rating` that is not in `done` (a set of ids). `rand` is
-- a function(n) -> 1..n, math.random by default. The window widens until
-- something fits; if everything has been done, done puzzles are allowed.
function Puzzles.pick(list, rating, done, rand)
    rand = rand or math.random
    done = done or {}
    if #list == 0 then return nil end
    for _, allow_done in ipairs({ false, true }) do
        for _, window in ipairs({ 75, 150, 300, 600, 5000 }) do
            local candidates = {}
            for i, p in ipairs(list) do
                if math.abs(p.rating - rating) <= window and (allow_done or not done[p.id]) then
                    candidates[#candidates + 1] = i
                end
            end
            if #candidates > 0 then
                return list[candidates[rand(#candidates)]]
            end
        end
    end
    return list[rand(#list)]
end

--- The puzzle of the day: the same for everybody on a given date, a new one
-- each day, and moderate (from the middle of the collection) so it suits
-- most players. `date` is os.date("*t") or a table with year/month/day.
function Puzzles.daily(list, date)
    if #list == 0 then return nil end
    date = date or os.date("*t")
    local days = math.floor(os.time{ year = date.year, month = date.month,
                                     day = date.day, hour = 12 } / 86400)
    -- the middle half of the collection, stepped through by a large prime so
    -- neighbouring days are far apart in rating and theme
    local lo = math.floor(#list * 0.25) + 1
    local span = math.max(1, math.floor(#list * 0.5))
    return list[lo + (days * 7919) % span]
end

function Puzzles.dateKey(date)
    date = date or os.date("*t")
    return ("%04d-%02d-%02d"):format(date.year, date.month, date.day)
end

--==========================================================================
-- The personal rating
--==========================================================================

--- Expected score of a solver rated `rating` against a puzzle rated `pr`.
function Puzzles.expected(rating, pr)
    return 1 / (1 + 10 ^ ((pr - rating) / 400))
end

--- The rating after one puzzle. `solved` is true only for a clean solve (no
-- wrong move, no hint). Moves faster for the first few puzzles, so a new
-- solver finds their level quickly, then settles.
function Puzzles.updateRating(rating, pr, solved, played)
    local k = (played or 0) < 20 and 40 or 20
    local new = rating + k * ((solved and 1 or 0) - Puzzles.expected(rating, pr))
    new = math.floor(new + 0.5)
    return math.max(Puzzles.MIN_RATING, math.min(Puzzles.MAX_RATING, new))
end

--- Fresh stats, or the saved ones with anything missing filled in.
function Puzzles.stats(saved)
    local s = type(saved) == "table" and saved or {}
    s.rating = tonumber(s.rating) or Puzzles.START_RATING
    s.played = tonumber(s.played) or 0
    s.solved = tonumber(s.solved) or 0       -- clean solves
    s.streak = tonumber(s.streak) or 0
    s.best_streak = tonumber(s.best_streak) or 0
    s.done = type(s.done) == "table" and s.done or {}
    return s
end

--- Record a finished puzzle in the stats. Returns the rating change.
function Puzzles.record(stats, puzzle, solved)
    local before = stats.rating
    stats.rating = Puzzles.updateRating(stats.rating, puzzle.rating, solved, stats.played)
    stats.played = stats.played + 1
    if solved then
        stats.solved = stats.solved + 1
        stats.streak = stats.streak + 1
        if stats.streak > stats.best_streak then stats.best_streak = stats.streak end
    else
        stats.streak = 0
    end
    stats.done[puzzle.id] = solved and 1 or 0
    return stats.rating - before
end

--==========================================================================
-- Solving one
--==========================================================================

local Session = {}
Session.__index = Session
Puzzles.Session = Session

--- Set a puzzle up: the position with the opponent's first move played.
-- Returns nil and a reason if the puzzle does not fit the position.
function Puzzles.start(puzzle)
    local self = setmetatable({}, Session)
    self.puzzle = puzzle
    self.board = Board.new(puzzle.fen)
    local first = self.board:moveFromUci(puzzle.moves[1])
    if not first then return nil, "the first move is not legal" end
    self.board:makeMove(first)
    self.played = { first }          -- packed moves made so far
    self.index = 2                   -- next entry of puzzle.moves to find
    self.solver = self.board.side
    self.mistakes = 0
    self.hints = 0
    self.solved = false
    return self
end

function Session:expectedUci()
    return self.puzzle.moves[self.index]
end

function Session:expectedMove()
    local uci = self:expectedUci()
    return uci and self.board:moveFromUci(uci)
end

--- Was this a clean solve (no wrong move, no hint, no solution shown)?
function Session:isClean()
    return self.mistakes == 0 and self.hints == 0
end

--- Try the solver's move (a packed legal move).
--
-- Returns "wrong" (nothing played), "correct" (played; the opponent's reply
-- is returned as a second value, already played on the board) or "solved"
-- (played, the puzzle is over). A move that gives mate is accepted at any
-- point even when the database has another: mate is mate.
function Session:try(move)
    if self.solved then return "solved" end
    local uci = self.board:moveToUci(move)
    local expected = self:expectedUci()
    local ok = (uci == expected)
    if not ok then
        -- a different mate is just as good
        if self.board:makeMove(move) then
            local replies = {}
            ok = self.board:inCheck() and self.board:generateMoves(replies) == 0
            self.board:unmakeMove(move)
        end
        if ok then
            self.board:makeMove(move)
            self.played[#self.played + 1] = move
            self.index = #self.puzzle.moves + 1
            self.solved = true
            return "solved"
        end
        self.mistakes = self.mistakes + 1
        return "wrong"
    end

    self.board:makeMove(move)
    self.played[#self.played + 1] = move
    self.index = self.index + 1
    local reply_uci = self.puzzle.moves[self.index]
    if not reply_uci then
        self.solved = true
        return "solved"
    end
    local reply = self.board:moveFromUci(reply_uci)
    if not reply then
        -- a broken entry; count it as solved rather than leave the solver stuck
        self.solved = true
        return "solved"
    end
    self.board:makeMove(reply)
    self.played[#self.played + 1] = reply
    self.index = self.index + 1
    if not self.puzzle.moves[self.index] then
        self.solved = true
        return "solved", reply
    end
    return "correct", reply
end

--- How many solver moves the puzzle asks for in all.
function Session:solverMoves()
    return math.floor(#self.puzzle.moves / 2)
end

return Puzzles
