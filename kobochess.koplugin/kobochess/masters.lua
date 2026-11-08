--[[--
Famous games: the bundled collection, stepping through a game, and "guess
the move".

The games are in data/masters.pgn (historical games; the moves are facts and
the file is ours, see the README for where they were checked). Stepping
replays the game's moves on a board from the start, which keeps forward and
back trivially correct at the cost of a few dozen move generations, nothing
at this size.

Guess the move: at each of the chosen side's moves the player tries to find
what the master played. Two points for finding it at the first try, one at
the second; after two misses the master's move is shown and played.

@module kobochess.masters
--]]--

local Board = require("kobochess.board")
local Pgn = require("kobochess.pgn")

local Masters = {}

--- Read the collection. Games that did not parse in full are kept (up to
-- the bad move) but flagged with `error`.
function Masters.load(path)
    local f = io.open(path, "r")
    if not f then return {} end
    local text = f:read("*a")
    f:close()
    return Pgn.parse(text)
end

local PARTICLES = { de = true, von = true, van = true, Saint = true }

local function surname(name)
    if not name or name == "" then return "?" end
    -- "Duke Karl of Brunswick and Count Isouard" stays whole; "Paul Morphy" -> "Morphy"
    if name:find(" and ") or name:find(" of ") then return name end
    local words = {}
    for w in name:gmatch("%S+") do words[#words + 1] = w end
    -- "Curt von Bardeleben" -> "von Bardeleben", "Saint Brie" stays whole
    if #words >= 2 and PARTICLES[words[#words - 1]] then
        return words[#words - 1] .. " " .. words[#words]
    end
    return words[#words]
end
Masters.surname = surname

function Masters.year(game)
    return (game.tags.Date or ""):match("^(%d%d%d%d)") or "?"
end

--- The players as shown: a WhiteShort/BlackShort tag if the file has one
-- (for names like "Duke Karl of Brunswick and Count Isouard"), else the surname.
function Masters.players(game)
    local t = game.tags
    return t.WhiteShort or surname(t.White), t.BlackShort or surname(t.Black)
end

--- "Anderssen – Kieseritzky, London 1851"
function Masters.title(game)
    local t = game.tags
    local w, b = Masters.players(game)
    local site = t.Site and t.Site ~= "" and t.Site ~= "?" and (t.Site .. " ") or ""
    return ("%s – %s, %s%s"):format(w, b, site, Masters.year(game))
end

--- The short form for a status line: "Anderssen – Kieseritzky 1851".
function Masters.shortTitle(game)
    local w, b = Masters.players(game)
    return ("%s – %s %s"):format(w, b, Masters.year(game))
end

--- The side whose moves are worth guessing: the winner's, White's in a draw.
function Masters.defaultGuessSide(game)
    if game.result == "0-1" then return Board.BLACK end
    return Board.WHITE
end

--==========================================================================
-- A viewer: a game and a position in it
--==========================================================================

local Viewer = {}
Viewer.__index = Viewer
Masters.Viewer = Viewer

function Masters.view(game)
    local self = setmetatable({}, Viewer)
    self.game = game
    self.board = Board.new(game.start_fen)
    self.ply = 0
    return self
end

function Viewer:length() return #self.game.moves end

--- Go to ply `n` (0 = the start). Returns the move that led there, if any.
function Viewer:goTo(n)
    n = math.max(0, math.min(n, self:length()))
    if n < self.ply then
        self.board = Board.new(self.game.start_fen)
        self.ply = 0
    end
    while self.ply < n do
        self.ply = self.ply + 1
        self.board:makeMove(self.game.moves[self.ply])
    end
    return self.game.moves[self.ply]
end

function Viewer:forward() return self:goTo(self.ply + 1) end
function Viewer:back() return self:goTo(self.ply - 1) end

--- The next move of the game, packed, or nil at the end.
function Viewer:nextMove() return self.game.moves[self.ply + 1] end

--- The move list as "1. e4 e5 2. Nf3 …", with the current move bracketed.
function Viewer:moveListText()
    local parts = {}
    local start_side = Board.new(self.game.start_fen).side
    local start_no = Board.new(self.game.start_fen).fullmove
    for i, san in ipairs(self.game.sans) do
        local n = i - 1 + (start_side == Board.BLACK and 1 or 0)
        local no = start_no + math.floor(n / 2)
        local text = san
        if i == self.ply then text = "[" .. san .. "]" end
        if n % 2 == 0 then
            parts[#parts + 1] = no .. ". " .. text
        elseif i == 1 then
            parts[#parts + 1] = no .. "… " .. text
        else
            parts[#parts + 1] = text
        end
    end
    return table.concat(parts, " ")
end

--- The last few moves up to the current one, for a one-line display.
function Viewer:recentText(max_plies)
    local first = math.max(1, self.ply - (max_plies or 8) + 1)
    local start_side = Board.new(self.game.start_fen).side
    local start_no = Board.new(self.game.start_fen).fullmove
    local parts = {}
    -- "…" before a white move; a black move reads "12… Nf6" on its own
    if first > 1 and (first - 1 + (start_side == Board.BLACK and 1 or 0)) % 2 == 0 then
        parts[1] = "…"
    end
    for i = first, self.ply do
        local n = i - 1 + (start_side == Board.BLACK and 1 or 0)
        local no = start_no + math.floor(n / 2)
        if n % 2 == 0 then
            parts[#parts + 1] = no .. ". " .. self.game.sans[i]
        elseif i == first then
            parts[#parts + 1] = no .. "… " .. self.game.sans[i]
        else
            parts[#parts + 1] = self.game.sans[i]
        end
    end
    return table.concat(parts, " ")
end

--==========================================================================
-- Guess the move
--==========================================================================

--- Start guessing `side`'s moves in the viewer's game, from where it stands.
function Viewer:startGuessing(side)
    self.guess = { side = side, score = 0, possible = 0, tries = 0, found = 0, asked = 0 }
end

function Viewer:stopGuessing() self.guess = nil end

--- Is the next move one the player has to guess?
function Viewer:isGuessTurn()
    return self.guess ~= nil and self:nextMove() ~= nil and self.board.side == self.guess.side
end

--- A guess at the next move (packed, legal). Returns:
--   "right", points   -- it was the master's move; it has been played
--   "again"           -- wrong, one more try
--   "shown", move     -- wrong twice; the master's move has been played
function Viewer:tryGuess(move)
    local g = self.guess
    local master = self:nextMove()
    if not g or not master then return nil end
    if g.tries == 0 then g.possible = g.possible + 2; g.asked = g.asked + 1 end
    if self.board:moveToUci(move) == self.board:moveToUci(master) then
        local points = (g.tries == 0) and 2 or 1
        g.score = g.score + points
        g.found = g.found + 1
        g.tries = 0
        self:forward()
        return "right", points
    end
    g.tries = g.tries + 1
    if g.tries >= 2 then
        g.tries = 0
        self:forward()
        return "shown", master
    end
    return "again"
end

--- Give up on the current guess: the master's move is played, no points.
function Viewer:revealGuess()
    local g = self.guess
    local master = self:nextMove()
    if not g or not master then return nil end
    if g.tries == 0 then g.possible = g.possible + 2; g.asked = g.asked + 1 end
    g.tries = 0
    self:forward()
    return master
end

return Masters
