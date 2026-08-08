--[[--
Game state: the board plus everything around it that a board alone does not
track -- move history, whose side the player is on, the result, and how to
write all of that to disk and read it back.

Keeping this separate from the board means the UI never manipulates the
position directly, and the save format stays a plain Lua table.

@module kobochess.game
--]]--

local Board = require("kobochess.board")

local Game = {}
Game.__index = Game

--- Start a new game.
-- @param opts  player_colour (Board.WHITE/BLACK), level (1..6), fen,
--              two_player (both sides played by humans, engine idle)
function Game.new(opts)
    opts = opts or {}
    local self = setmetatable({}, Game)
    self.two_player = opts.two_player or false
    self.start_fen = opts.fen or Board.START_FEN
    self.board = Board.new(self.start_fen)
    -- Remembered so move numbers stay correct for games set up from a FEN
    -- that does not begin at move 1 with White to play.
    self.start_fullmove = self.board.fullmove
    self.start_side = self.board.side
    self.moves = {}          -- packed moves, in order
    self.sans = {}           -- the same moves in algebraic notation
    self.player_colour = opts.player_colour or Board.WHITE
    self.level = opts.level or 4
    self.result = nil        -- nil while the game is in progress
    self.result_winner = nil
    self.started_at = opts.started_at or os.time()
    return self
end

--- Whose turn it is.
function Game:sideToMove() return self.board.side end

--- Is a human to move? In a two-player game that is always true.
function Game:isPlayerTurn()
    if self.result ~= nil then return false end
    if self.two_player then return true end
    return self.board.side == self.player_colour
end

function Game:isEngineTurn()
    if self.result ~= nil or self.two_player then return false end
    return self.board.side ~= self.player_colour
end

function Game:isOver() return self.result ~= nil end

--- Play a move that is already known to be legal.
function Game:play(move)
    -- The notation has to be produced before the move is made, because
    -- disambiguation depends on the position it was played in.
    local san = self.board:moveToSan(move)
    if not self.board:makeMove(move) then
        return false
    end
    self.moves[#self.moves + 1] = move
    self.sans[#self.sans + 1] = san
    self:updateResult()
    return true
end

--- Find and play a move given its from/to squares.
function Game:playSquares(from, to, promo)
    local move = self.board:findMove(from, to, promo)
    if not move then return false end
    return self:play(move)
end

function Game:updateResult()
    local result, winner = self.board:getGameResult()
    self.result, self.result_winner = result, winner
    return result
end

--- Take back a single ply.
function Game:undoPly()
    local n = #self.moves
    if n == 0 then return false end
    self.board:unmakeMove(self.moves[n])
    self.moves[n], self.sans[n] = nil, nil
    self.result, self.result_winner = nil, nil
    return true
end

--- Take back far enough that it is the player's turn again.
-- Against the engine that means two plies -- the reply and the move that
-- prompted it. With two humans it means one: the move just played.
function Game:undoMove()
    if #self.moves == 0 then return false end
    if self.two_player then
        return self:undoPly()
    end
    local undone = false
    -- Always take back at least one ply, then keep going until it is the
    -- player's move (or we run out of history).
    repeat
        if not self:undoPly() then break end
        undone = true
    until self.board.side == self.player_colour or #self.moves == 0
    return undone
end

function Game:canUndo() return #self.moves > 0 end

--- The move that was just played, for highlighting it on the board.
function Game:lastMove()
    return self.moves[#self.moves]
end

--- The move number and side for a given ply index (1-based).
function Game:plyNumber(i)
    -- Offset by one half-move when the game started with Black to play, so
    -- that ply 1 is numbered as Black's half of the starting move.
    local offset = (self.start_side == Board.BLACK) and 1 or 0
    local n = i - 1 + offset
    local is_white = (n % 2 == 0)
    return self.start_fullmove + math.floor(n / 2), is_white
end

--- Move history formatted as "1. e4 e5 2. Nf3", most recent last.
-- `max_moves` limits it to the last N full moves, elided with a leading "…".
function Game:historyText(max_moves)
    local out = {}
    local first = 1
    if max_moves then
        first = math.max(1, #self.sans - max_moves * 2 + 1)
        if first > 1 then out[#out + 1] = "…" end
    end
    for i = first, #self.sans do
        local number, is_white = self:plyNumber(i)
        if is_white then
            out[#out + 1] = number .. "."
        elseif i == first then
            -- The window opens mid-move, so show "12..." before Black's reply.
            out[#out + 1] = number .. "..."
        end
        out[#out + 1] = self.sans[i]
    end
    return table.concat(out, " ")
end

--- A one-line description of how the game ended.
function Game:resultText()
    if not self.result then return nil end
    if self.result == "checkmate" then
        local who = (self.result_winner == Board.WHITE) and "White" or "Black"
        if self.two_player then
            return ("Checkmate — %s wins"):format(who)
        end
        local winner_is_player = (self.result_winner == self.player_colour)
        return ("Checkmate — %s wins (%s)"):format(
            who, winner_is_player and "you win" or "engine wins")
    elseif self.result == "stalemate" then
        return "Draw — stalemate"
    elseif self.result == "fifty" then
        return "Draw — fifty-move rule"
    elseif self.result == "repetition" then
        return "Draw — threefold repetition"
    elseif self.result == "insufficient" then
        return "Draw — insufficient material"
    elseif self.result == "resigned" then
        local who = (self.result_winner == Board.WHITE) and "White" or "Black"
        return ("%s wins by resignation"):format(who)
    end
    return self.result
end

--- The PGN result token for the current state.
function Game:resultToken()
    if not self.result then return "*" end
    if self.result == "checkmate" or self.result == "resigned" then
        return (self.result_winner == Board.WHITE) and "1-0" or "0-1"
    end
    return "1/2-1/2"
end

--- Resign. With two humans it is whoever is to move who gives up; against the
-- engine it is always the player, who may well be resigning while the engine
-- is still thinking and therefore nominally "to move".
function Game:resign()
    self.result = "resigned"
    local loser = self.two_player and self.board.side or self.player_colour
    self.result_winner = 1 - loser
end

--==========================================================================
-- Persistence
--==========================================================================

--- Serialise to a plain table suitable for LuaSettings.
-- Moves are stored as UCI strings rather than packed integers: the packing
-- is an internal detail that could change, whereas "e2e4" will always mean
-- what it says.
function Game:toTable()
    -- Replay from the start so each move can be written in the position it
    -- was played in.
    local replay = Board.new(self.start_fen)
    local ucis = {}
    for i = 1, #self.moves do
        ucis[i] = replay:moveToUci(self.moves[i])
        replay:makeMove(self.moves[i])
    end
    return {
        version = 1,
        start_fen = self.start_fen,
        moves = ucis,
        player_colour = self.player_colour,
        two_player = self.two_player,
        level = self.level,
        result = self.result,
        result_winner = self.result_winner,
        started_at = self.started_at,
    }
end

--- Rebuild a game from @{Game:toTable} output. Returns nil if unusable.
function Game.fromTable(data)
    if type(data) ~= "table" or type(data.moves) ~= "table" then return nil end
    local self = Game.new({
        fen = data.start_fen,
        player_colour = data.player_colour,
        two_player = data.two_player,
        level = data.level,
        started_at = data.started_at,
    })
    for _, uci in ipairs(data.moves) do
        local move = self.board:moveFromUci(uci)
        if not move then
            -- A corrupt or truncated save: keep the moves that did replay
            -- rather than throwing the whole game away.
            break
        end
        self:play(move)
    end
    -- A resignation is not derivable from the position, so restore it.
    if data.result == "resigned" then
        self.result, self.result_winner = data.result, data.result_winner
    end
    return self
end

--- Export the game as PGN.
function Game:toPgn(opts)
    opts = opts or {}
    local white, black
    if self.two_player then
        white, black = "Player 1", "Player 2"
    else
        local player_is_white = (self.player_colour == Board.WHITE)
        local engine_name = opts.engine_name or "Kobo Chess"
        local player = opts.player_name or "Player"
        white = player_is_white and player or engine_name
        black = player_is_white and engine_name or player
    end

    local lines = {
        ("[Event \"%s\"]"):format(opts.event or "Casual game"),
        ("[Site \"%s\"]"):format(opts.site or "Kobo"),
        ("[Date \"%s\"]"):format(os.date("%Y.%m.%d", self.started_at)),
        "[Round \"-\"]",
        ("[White \"%s\"]"):format(white),
        ("[Black \"%s\"]"):format(black),
        ("[Result \"%s\"]"):format(self:resultToken()),
    }
    if self.start_fen ~= Board.START_FEN then
        lines[#lines + 1] = "[SetUp \"1\"]"
        lines[#lines + 1] = ("[FEN \"%s\"]"):format(self.start_fen)
    end
    lines[#lines + 1] = ""

    -- Movetext, wrapped at a sensible width.
    local tokens = {}
    for i, san in ipairs(self.sans) do
        local number, is_white = self:plyNumber(i)
        if is_white then
            tokens[#tokens + 1] = number .. "."
        elseif i == 1 then
            tokens[#tokens + 1] = number .. "..."
        end
        tokens[#tokens + 1] = san
    end
    tokens[#tokens + 1] = self:resultToken()

    local line, body = "", {}
    for _, tok in ipairs(tokens) do
        if #line + #tok + 1 > 79 then
            body[#body + 1] = line
            line = tok
        else
            line = (line == "") and tok or (line .. " " .. tok)
        end
    end
    if line ~= "" then body[#body + 1] = line end

    return table.concat(lines, "\n") .. table.concat(body, "\n") .. "\n"
end

return Game
