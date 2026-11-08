--[[--
Reading chess notation: SAN moves and PGN games.

Moves are resolved against the board's own legal move list rather than
trusted, so a game that parses is a game that can be replayed: a typo in a
score shows up as an error on the move where it happens instead of a board
that quietly goes wrong.

SAN is matched by its parts (piece, optional from-file/rank, target square,
promotion) rather than by rebuilding each legal move's notation, which makes
the parser forgiving in the ways real scores need: over-specified moves
("Ngf3" where "Nf3" would do), a missing "x", "0-0" for "O-O", "e8Q" for
"e8=Q", and check marks or annotations ("!", "?!") stuck on the end.

@module kobochess.pgn
--]]--

local Board = require("kobochess.board")

local Pgn = {}

local PIECE_OF = { N = Board.KNIGHT, B = Board.BISHOP, R = Board.ROOK,
                   Q = Board.QUEEN, K = Board.KING }

local function fileIndex(c) return c:byte() - 96 - 1 end   -- "a" -> 0

--- The legal move a SAN string stands for in this position, or nil and why.
function Pgn.sanToMove(board, san)
    if type(san) ~= "string" then return nil, "no move" end
    local s = san:gsub("[+#!?]", "")
    s = s:gsub("^0%-0%-0$", "O-O-O"):gsub("^0%-0$", "O-O")

    local moves = {}
    local n = board:generateMoves(moves)

    if s == "O-O" or s == "O-O-O" then
        for i = 1, n do
            local m = moves[i]
            if Board.moveFlags(m) == Board.FLAG_CASTLE then
                local kingside = Board.moveTo(m) > Board.moveFrom(m)
                if kingside == (s == "O-O") then return m end
            end
        end
        return nil, "castling is not legal here"
    end

    local piece, ffile, frank, to, promo =
        s:match("^([NBRQK]?)([a-h]?)([1-8]?)x?([a-h][1-8])=?([NBRQnbrq]?)$")
    if not to then return nil, "not a move: " .. san end
    local ptype = PIECE_OF[piece] or Board.PAWN
    local target = Board.squareFromName(to)
    local promo_type = promo ~= "" and PIECE_OF[promo:upper()] or nil

    local found
    for i = 1, n do
        local m = moves[i]
        local from = Board.moveFrom(m)
        if Board.moveTo(m) == target
           and Board.moveFlags(m) ~= Board.FLAG_CASTLE
           and board.sq[from] % 8 == ptype
           and (ffile == "" or Board.fileOf(from) == fileIndex(ffile))
           and (frank == "" or Board.rankOf(from) == tonumber(frank) - 1) then
            local p = Board.movePromo(m)
            -- A promotion written without a piece means a queen, which is
            -- what everybody means by it.
            if p == 0 or p == (promo_type or Board.QUEEN) then
                if found then return nil, "ambiguous: " .. san end
                found = m
            end
        end
    end
    if not found then return nil, "illegal here: " .. san end
    return found
end

--- Play a list of SAN moves from a position. Returns the board, the packed
-- moves and their UCI forms, or nil plus the 1-based index and the reason of
-- the first move that would not go.
function Pgn.playSans(sans, fen)
    local board = Board.new(fen)
    local moves, ucis = {}, {}
    for i, san in ipairs(sans) do
        local m, err = Pgn.sanToMove(board, san)
        if not m then return nil, i, err end
        ucis[i] = board:moveToUci(m)
        moves[i] = m
        board:makeMove(m)
    end
    return board, moves, ucis
end

local RESULTS = { ["1-0"] = true, ["0-1"] = true, ["1/2-1/2"] = true, ["*"] = true }

--- Split movetext into SAN tokens, dropping move numbers, comments,
-- variations, NAGs and the result. Returns the moves and the result token.
function Pgn.tokenize(text)
    local sans, result = {}, nil
    -- Comments and variations first. Variations nest, so strip innermost
    -- parentheses until none remain; braces do not nest in PGN.
    text = text:gsub("%b{}", " "):gsub(";[^\n]*", " ")
    local prev
    repeat
        prev = text
        text = text:gsub("%([^()]*%)", " ")
    until text == prev
    for token in text:gmatch("%S+") do
        if RESULTS[token] then
            result = token
        else
            token = token:gsub("^%d+%.+", "")        -- "12." or "12..." glued on
            if token ~= "" and not token:match("^%$%d+$") and not token:match("^%d+%.*$") then
                sans[#sans + 1] = token
            end
        end
    end
    return sans, result
end

--- Parse every game in a PGN text.
--
-- Each game is a table: `tags` (name -> value), `sans`, `ucis`, `moves`
-- (packed), `result`, `start_fen`, and `error` when a move would not play
-- (the moves before it are kept). Games are returned in file order.
function Pgn.parse(text)
    local games = {}
    local cur
    local movetext = {}

    local function finish()
        if not cur then return end
        local sans, result = Pgn.tokenize(table.concat(movetext, "\n"))
        cur.result = cur.tags.Result or result or "*"
        local fen = cur.tags.FEN
        cur.start_fen = fen or Board.START_FEN
        local board, moves, ucis = Pgn.playSans(sans, fen)
        if board then
            cur.sans, cur.moves, cur.ucis = sans, moves, ucis
        else
            local bad, why = moves, ucis
            cur.error = ("move %d (%s): %s"):format(bad, tostring(sans[bad]), why)
            -- keep what did play, so a damaged game can still be shown
            local ok_sans = {}
            for i = 1, bad - 1 do ok_sans[i] = sans[i] end
            local _, m2, u2 = Pgn.playSans(ok_sans, fen)
            cur.sans, cur.moves, cur.ucis = ok_sans, m2, u2
        end
        games[#games + 1] = cur
        cur, movetext = nil, {}
    end

    local in_moves = false
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        line = line:gsub("\r$", "")
        local name, value = line:match('^%s*%[(%w+)%s+"(.-)"%]%s*$')
        if name then
            if in_moves then finish(); in_moves = false end
            cur = cur or { tags = {} }
            cur.tags[name] = value:gsub('\\"', '"')
        elseif line:match("%S") then
            cur = cur or { tags = {} }
            in_moves = true
            movetext[#movetext + 1] = line
        end
    end
    finish()
    return games
end

--- "1. e4 e5 2. Nf3" -> { "e4", "e5", "Nf3" }: the form the openings list uses.
function Pgn.lineToSans(text)
    return (Pgn.tokenize(text))
end

--- A position key that ignores the move counters and the en passant square,
-- so the same position reached by different move orders compares equal.
function Pgn.positionKey(board)
    local fen = board:getFen()
    local placement, side, castling = fen:match("^(%S+) (%S+) (%S+)")
    return placement .. " " .. side .. " " .. castling
end

return Pgn
