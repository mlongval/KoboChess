--[[--
Opening names and the opening trainer's logic.

The names come from the lichess-org/chess-openings lists (CC0), converted by
tools/build_openings.lua into one line per opening: ECO code, name, the main
line in UCI, a key for the position it reaches, and the line in SAN for
showing (some names occur more than once, for different move orders).

Recognising an opening goes by position rather than by move order, so
1. d4 Nf6 2. c4 e6 and 1. c4 e6 2. d4 Nf6 get the same name. The name shown
is that of the last position in the game that has one, so a game keeps its
opening's name after it leaves the book.

Nothing here touches the screen (see test/training_test.lua).

@module kobochess.openings
--]]--

local Board = require("kobochess.board")
local Pgn = require("kobochess.pgn")

local Openings = {}

--- A name split into its family ("Sicilian Defense") and the rest
-- ("Najdorf Variation, English Attack"), which may be empty.
function Openings.splitName(name)
    local family, rest = name:match("^([^:]+):%s*(.+)$")
    if family then return family, rest end
    return name, ""
end

--- Read the data file into a book: `list` (file order), `by_key` (position
-- key -> entry; the shortest line wins when several reach one position) and
-- `families` (sorted names, with the entries of each in `by_family`).
function Openings.load(path)
    local book = { list = {}, by_key = {}, by_family = {}, families = {} }
    local f = io.open(path, "r")
    if not f then return book end
    for line in f:lines() do
        local eco, name, ucis, key, san = line:match("^([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t?([^\t]*)$")
        if eco then
            local moves = {}
            for m in ucis:gmatch("%S+") do moves[#moves + 1] = m end
            local family, variation = Openings.splitName(name)
            local entry = { eco = eco, name = name, family = family,
                            variation = variation, moves = moves, key = key,
                            san = san, id = name .. "|" .. ucis }
            book.list[#book.list + 1] = entry
            local old = book.by_key[key]
            if not old or #moves < #old.moves then book.by_key[key] = entry end
            local fam = book.by_family[family]
            if not fam then
                fam = {}
                book.by_family[family] = fam
                book.families[#book.families + 1] = family
            end
            fam[#fam + 1] = entry
        end
    end
    f:close()
    -- the families with the most lines first: they are the openings that
    -- are played most (Sicilian, French, Queen's Gambit…)
    table.sort(book.families, function(a, b)
        local na, nb = #book.by_family[a], #book.by_family[b]
        if na ~= nb then return na > nb end
        return a < b
    end)
    for _, fam in pairs(book.by_family) do
        -- the plain family entry and short lines first, then by name
        table.sort(fam, function(a, b)
            if (a.variation == "") ~= (b.variation == "") then return a.variation == "" end
            if #a.moves ~= #b.moves then return #a.moves < #b.moves end
            return a.name < b.name
        end)
    end
    return book
end

local shared = {}

--- The book for a path, read once and kept: the board and the trainer
-- both use it, and reading it takes a moment on a slow Kobo.
function Openings.shared(path)
    if not shared[path] then shared[path] = Openings.load(path) end
    return shared[path]
end

--- The opening of a game given as UCI moves from the start (or `fen`):
-- the entry for the last position along the way that has a name, and the
-- ply at which it was reached. nil when nothing matches.
function Openings.match(book, ucis, fen)
    local board = Board.new(fen)
    local found, at
    local e = book.by_key[Pgn.positionKey(board)]
    if e then found, at = e, 0 end
    for i, uci in ipairs(ucis) do
        local m = board:moveFromUci(uci)
        if not m then break end
        board:makeMove(m)
        e = book.by_key[Pgn.positionKey(board)]
        if e then found, at = e, i end
    end
    return found, at
end

--- The same for a live board: walks the game's packed moves. `moves` is
-- the list of packed moves played from `fen`.
function Openings.matchMoves(book, moves, fen)
    local board = Board.new(fen)
    local ucis = {}
    for i, m in ipairs(moves) do
        ucis[i] = board:moveToUci(m)
        board:makeMove(m)
    end
    return Openings.match(book, ucis, fen)
end

--==========================================================================
-- Practising one line
--==========================================================================

-- A line counts as learned after this many clean runs in a row.
Openings.LEARNED_AFTER = 3

local Drill = {}
Drill.__index = Drill
Openings.Drill = Drill

--- Practise `entry` playing `colour`. The trainer plays the other side.
function Openings.drill(entry, colour)
    local self = setmetatable({}, Drill)
    self.entry = entry
    self.colour = colour
    self:restart()
    return self
end

function Drill:restart()
    self.board = Board.new()
    self.ply = 0                 -- book moves played so far
    self.played = {}
    self.mistakes = 0
    self.hints = 0
end

function Drill:isDone()
    return self.ply >= #self.entry.moves
end

--- Is it the trainer's turn to play a book move?
function Drill:isTrainerTurn()
    return not self:isDone() and self.board.side ~= self.colour
end

function Drill:bookUci()
    return self.entry.moves[self.ply + 1]
end

function Drill:bookMove()
    local uci = self:bookUci()
    return uci and self.board:moveFromUci(uci)
end

--- Play the next book move for the trainer. Returns it (packed).
function Drill:playTrainer()
    local m = self:bookMove()
    if not m then return nil end
    self.board:makeMove(m)
    self.played[#self.played + 1] = m
    self.ply = self.ply + 1
    return m
end

--- Try the learner's move. Returns true (played) or false and the book
-- move it should have been (nothing played).
function Drill:try(move)
    local book = self:bookMove()
    if not book then return false end
    if self.board:moveToUci(move) ~= self.board:moveToUci(book) then
        self.mistakes = self.mistakes + 1
        return false, book
    end
    self.board:makeMove(move)
    self.played[#self.played + 1] = move
    self.ply = self.ply + 1
    return true
end

function Drill:isClean()
    return self.mistakes == 0 and self.hints == 0
end

--- The key progress is saved under, one per line and colour. The line's
-- moves are part of it, as a few names occur for more than one line.
function Openings.progressKey(entry, colour)
    return (colour == Board.WHITE and "w:" or "b:") .. entry.id
end

--- The name and the line, from a progress key: "Ruy Lopez", "e2e4 …".
function Openings.splitProgressKey(key)
    local colour = key:sub(1, 1) == "w" and Board.WHITE or Board.BLACK
    local name, ucis = key:sub(3):match("^(.-)|(.*)$")
    return name or key:sub(3), colour, ucis
end

--- Record a finished run in `progress` (a table of key -> record). Returns
-- the record: `runs`, `clean_streak`, `learned`.
function Openings.record(progress, entry, colour, clean)
    local key = Openings.progressKey(entry, colour)
    local r = progress[key] or { runs = 0, clean_streak = 0, learned = false }
    r.runs = r.runs + 1
    r.clean_streak = clean and r.clean_streak + 1 or 0
    if r.clean_streak >= Openings.LEARNED_AFTER then r.learned = true end
    progress[key] = r
    return r
end

return Openings
