--[[--
Chess board representation, move generation and make/unmake.

Uses the classic 0x88 board: 128 squares where a square index is
`rank * 16 + file`, and `sq & 0x88 ~= 0` means "off the board". That makes
off-board detection a single AND, which is what keeps sliding-piece
generation cheap without bitboards.

Moves are packed into a single integer rather than a table. Under LuaJIT a
table per move would put the whole search on the GC's critical path; an
integer move costs nothing to create and nothing to collect.

@module kobochess.board
--]]--

local bit = require("bit")
local band, bor, lshift, rshift, bxor = bit.band, bit.bor, bit.lshift, bit.rshift, bit.bxor

local Board = {}

-- Colours.
local WHITE, BLACK = 0, 1

-- Piece types.
local PAWN, KNIGHT, BISHOP, ROOK, QUEEN, KING = 1, 2, 3, 4, 5, 6

-- A piece on the board is `colour * 8 + type`, so white pieces are 1..6 and
-- black pieces are 9..14. Type is `piece & 7`, colour is `piece >> 3`.
local EMPTY = 0

-- Castling rights bitmask.
local CASTLE_WK, CASTLE_WQ, CASTLE_BK, CASTLE_BQ = 1, 2, 4, 8

-- Move flags.
local FLAG_EP, FLAG_CASTLE, FLAG_DPP, FLAG_PROMO = 1, 2, 4, 8

local NO_SQUARE = -1

-- Frequently used squares.
local A1, E1, H1 = 0, 4, 7
local A8, E8, H8 = 112, 116, 119

Board.WHITE, Board.BLACK = WHITE, BLACK
Board.PAWN, Board.KNIGHT, Board.BISHOP = PAWN, KNIGHT, BISHOP
Board.ROOK, Board.QUEEN, Board.KING = ROOK, QUEEN, KING
Board.EMPTY = EMPTY
Board.CASTLE_WK, Board.CASTLE_WQ = CASTLE_WK, CASTLE_WQ
Board.CASTLE_BK, Board.CASTLE_BQ = CASTLE_BK, CASTLE_BQ
Board.FLAG_EP, Board.FLAG_CASTLE = FLAG_EP, FLAG_CASTLE
Board.FLAG_DPP, Board.FLAG_PROMO = FLAG_DPP, FLAG_PROMO
Board.NO_SQUARE = NO_SQUARE

--==========================================================================
-- Move packing
--==========================================================================

--- Pack a move into an integer.
-- Layout: from(8) | to(8) | captured(4) | promotion(4) | flags(4)
function Board.packMove(from, to, captured, promo, flags)
    return bor(from,
               lshift(to, 8),
               lshift(captured or 0, 16),
               lshift(promo or 0, 20),
               lshift(flags or 0, 24))
end

local packMove = Board.packMove

function Board.moveFrom(m) return band(m, 0xFF) end
function Board.moveTo(m) return band(rshift(m, 8), 0xFF) end
function Board.moveCaptured(m) return band(rshift(m, 16), 0xF) end
function Board.movePromo(m) return band(rshift(m, 20), 0xF) end
function Board.moveFlags(m) return band(rshift(m, 24), 0xF) end

local moveFrom, moveTo = Board.moveFrom, Board.moveTo
local moveCaptured, movePromo, moveFlags =
    Board.moveCaptured, Board.movePromo, Board.moveFlags

--==========================================================================
-- Square helpers
--==========================================================================

function Board.isOnBoard(sq) return band(sq, 0x88) == 0 end
function Board.rankOf(sq) return rshift(sq, 4) end
function Board.fileOf(sq) return band(sq, 7) end

local isOnBoard = Board.isOnBoard
local rankOf, fileOf = Board.rankOf, Board.fileOf

--- Convert a 0x88 square to algebraic notation, e.g. 0 -> "a1".
function Board.squareName(sq)
    if sq == NO_SQUARE or not isOnBoard(sq) then return "-" end
    return string.char(97 + fileOf(sq)) .. tostring(rankOf(sq) + 1)
end

--- Convert algebraic notation to a 0x88 square, or nil if malformed.
function Board.squareFromName(name)
    if type(name) ~= "string" or #name < 2 then return nil end
    local f = string.byte(name, 1) - 97
    local r = string.byte(name, 2) - 49
    if f < 0 or f > 7 or r < 0 or r > 7 then return nil end
    return r * 16 + f
end

--- Convert a 0x88 square to a 0..63 index (a1 = 0, h8 = 63).
function Board.to64(sq) return rankOf(sq) * 8 + fileOf(sq) end

--- Convert a 0..63 index to a 0x88 square.
function Board.from64(i) return math.floor(i / 8) * 16 + (i % 8) end

--==========================================================================
-- Movement vectors
--==========================================================================

local KNIGHT_DELTAS = { 33, 31, 18, 14, -33, -31, -18, -14 }
local BISHOP_DELTAS = { 17, 15, -17, -15 }
local ROOK_DELTAS   = { 16, -16, 1, -1 }
local KING_DELTAS   = { 17, 16, 15, 1, -1, -17, -16, -15 }

-- Pawn capture directions, indexed by colour.
local PAWN_CAPS = { [WHITE] = { 17, 15 }, [BLACK] = { -17, -15 } }
local PAWN_PUSH = { [WHITE] = 16, [BLACK] = -16 }
-- Rank on which a pawn of this colour starts, and on which it promotes.
local PAWN_START_RANK = { [WHITE] = 1, [BLACK] = 6 }
local PAWN_PROMO_RANK = { [WHITE] = 7, [BLACK] = 0 }

local SLIDER_DELTAS = {
    [BISHOP] = BISHOP_DELTAS,
    [ROOK]   = ROOK_DELTAS,
    [QUEEN]  = KING_DELTAS,
}

--==========================================================================
-- Zobrist hashing
--==========================================================================

-- 64-bit keys held as two 32-bit halves, so we never need the ffi module.
-- Deterministic xorshift32 so hashes are stable across runs and devices.
local zob_piece_lo, zob_piece_hi = {}, {}
local zob_castle_lo, zob_castle_hi = {}, {}
local zob_ep_lo, zob_ep_hi = {}, {}
local zob_side_lo, zob_side_hi

do
    local state = 0x1BADB002
    local function nextRandom()
        state = bxor(state, lshift(state, 13))
        state = bxor(state, rshift(state, 17))
        state = bxor(state, lshift(state, 5))
        return state
    end
    for piece = 0, 15 do
        zob_piece_lo[piece], zob_piece_hi[piece] = {}, {}
        for sq = 0, 127 do
            zob_piece_lo[piece][sq] = nextRandom()
            zob_piece_hi[piece][sq] = nextRandom()
        end
    end
    for c = 0, 15 do
        zob_castle_lo[c], zob_castle_hi[c] = nextRandom(), nextRandom()
    end
    -- Only the file of the en passant square matters for repetition.
    for f = 0, 7 do
        zob_ep_lo[f], zob_ep_hi[f] = nextRandom(), nextRandom()
    end
    zob_side_lo, zob_side_hi = nextRandom(), nextRandom()
end

--==========================================================================
-- Construction
--==========================================================================

local BoardMT = {}
BoardMT.__index = BoardMT
Board.mt = BoardMT

local START_FEN = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
Board.START_FEN = START_FEN

--- Create a new board. Defaults to the standard starting position.
function Board.new(fen)
    local b = setmetatable({}, BoardMT)
    b.sq = {}
    b.kingsq = { [WHITE] = NO_SQUARE, [BLACK] = NO_SQUARE }
    -- Undo stack, kept as parallel arrays indexed by ply.
    b.u_castling, b.u_ep, b.u_halfmove = {}, {}, {}
    b.u_hash_lo, b.u_hash_hi = {}, {}
    -- Position hashes of every position reached, for repetition detection.
    b.hist_lo, b.hist_hi = {}, {}
    b.ply = 0
    b:setFen(fen or START_FEN)
    return b
end

--- Recompute the Zobrist hash from scratch.
function BoardMT:computeHash()
    local lo, hi = 0, 0
    local sq = self.sq
    for r = 0, 7 do
        for f = 0, 7 do
            local s = r * 16 + f
            local p = sq[s]
            if p ~= EMPTY then
                lo = bxor(lo, zob_piece_lo[p][s])
                hi = bxor(hi, zob_piece_hi[p][s])
            end
        end
    end
    lo = bxor(lo, zob_castle_lo[self.castling])
    hi = bxor(hi, zob_castle_hi[self.castling])
    if self.ep ~= NO_SQUARE then
        lo = bxor(lo, zob_ep_lo[fileOf(self.ep)])
        hi = bxor(hi, zob_ep_hi[fileOf(self.ep)])
    end
    if self.side == BLACK then
        lo = bxor(lo, zob_side_lo)
        hi = bxor(hi, zob_side_hi)
    end
    self.hash_lo, self.hash_hi = lo, hi
    return lo, hi
end

--==========================================================================
-- FEN
--==========================================================================

local FEN_TO_PIECE = {
    P = WHITE * 8 + PAWN,   N = WHITE * 8 + KNIGHT, B = WHITE * 8 + BISHOP,
    R = WHITE * 8 + ROOK,   Q = WHITE * 8 + QUEEN,  K = WHITE * 8 + KING,
    p = BLACK * 8 + PAWN,   n = BLACK * 8 + KNIGHT, b = BLACK * 8 + BISHOP,
    r = BLACK * 8 + ROOK,   q = BLACK * 8 + QUEEN,  k = BLACK * 8 + KING,
}

local PIECE_TO_FEN = {}
for ch, p in pairs(FEN_TO_PIECE) do PIECE_TO_FEN[p] = ch end
Board.PIECE_TO_FEN = PIECE_TO_FEN

--- Load a position from FEN. Returns true, or false plus an error message.
function BoardMT:setFen(fen)
    local placement, side, castling, ep, halfmove, fullmove =
        fen:match("^%s*(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s*(%d*)%s*(%d*)%s*$")
    if not placement then
        return false, "malformed FEN"
    end

    for s = 0, 127 do self.sq[s] = EMPTY end
    self.kingsq[WHITE], self.kingsq[BLACK] = NO_SQUARE, NO_SQUARE

    local rank, file = 7, 0
    for i = 1, #placement do
        local ch = placement:sub(i, i)
        if ch == "/" then
            rank, file = rank - 1, 0
        elseif ch:match("%d") then
            file = file + tonumber(ch)
        else
            local piece = FEN_TO_PIECE[ch]
            if not piece then return false, "bad piece '" .. ch .. "' in FEN" end
            if rank < 0 or file > 7 then return false, "FEN placement overflows board" end
            local s = rank * 16 + file
            self.sq[s] = piece
            if band(piece, 7) == KING then
                self.kingsq[rshift(piece, 3)] = s
            end
            file = file + 1
        end
    end

    self.side = (side == "b") and BLACK or WHITE

    self.castling = 0
    if castling:find("K", 1, true) then self.castling = bor(self.castling, CASTLE_WK) end
    if castling:find("Q", 1, true) then self.castling = bor(self.castling, CASTLE_WQ) end
    if castling:find("k", 1, true) then self.castling = bor(self.castling, CASTLE_BK) end
    if castling:find("q", 1, true) then self.castling = bor(self.castling, CASTLE_BQ) end

    self.ep = Board.squareFromName(ep) or NO_SQUARE
    self.halfmove = tonumber(halfmove) or 0
    self.fullmove = tonumber(fullmove) or 1

    self.ply = 0
    self:computeHash()
    self.hist_lo[0], self.hist_hi[0] = self.hash_lo, self.hash_hi
    return true
end

--- Serialise the current position to FEN.
function BoardMT:getFen()
    local rows = {}
    for rank = 7, 0, -1 do
        local row, empty = {}, 0
        for file = 0, 7 do
            local p = self.sq[rank * 16 + file]
            if p == EMPTY then
                empty = empty + 1
            else
                if empty > 0 then row[#row + 1] = tostring(empty); empty = 0 end
                row[#row + 1] = PIECE_TO_FEN[p]
            end
        end
        if empty > 0 then row[#row + 1] = tostring(empty) end
        rows[#rows + 1] = table.concat(row)
    end

    local castling = ""
    if band(self.castling, CASTLE_WK) ~= 0 then castling = castling .. "K" end
    if band(self.castling, CASTLE_WQ) ~= 0 then castling = castling .. "Q" end
    if band(self.castling, CASTLE_BK) ~= 0 then castling = castling .. "k" end
    if band(self.castling, CASTLE_BQ) ~= 0 then castling = castling .. "q" end
    if castling == "" then castling = "-" end

    return table.concat(rows, "/") .. " "
        .. (self.side == WHITE and "w" or "b") .. " "
        .. castling .. " "
        .. Board.squareName(self.ep) .. " "
        .. tostring(self.halfmove) .. " "
        .. tostring(self.fullmove)
end

--==========================================================================
-- Attack detection
--==========================================================================

--- Is `sq` attacked by any piece of colour `by`?
function BoardMT:isAttacked(sq, by)
    local board = self.sq
    local base = by * 8

    -- Pawns. We look backwards along the directions that pawn would capture.
    local caps = PAWN_CAPS[by]
    for i = 1, 2 do
        local from = sq - caps[i]
        if band(from, 0x88) == 0 and board[from] == base + PAWN then
            return true
        end
    end

    -- Knights.
    local knight = base + KNIGHT
    for i = 1, 8 do
        local from = sq + KNIGHT_DELTAS[i]
        if band(from, 0x88) == 0 and board[from] == knight then return true end
    end

    -- King.
    local king = base + KING
    for i = 1, 8 do
        local from = sq + KING_DELTAS[i]
        if band(from, 0x88) == 0 and board[from] == king then return true end
    end

    -- Sliding pieces: rook/queen along ranks and files.
    local rook, queen, bishop = base + ROOK, base + QUEEN, base + BISHOP
    for i = 1, 4 do
        local delta = ROOK_DELTAS[i]
        local from = sq + delta
        while band(from, 0x88) == 0 do
            local p = board[from]
            if p ~= EMPTY then
                if p == rook or p == queen then return true end
                break
            end
            from = from + delta
        end
    end

    -- Sliding pieces: bishop/queen along diagonals.
    for i = 1, 4 do
        local delta = BISHOP_DELTAS[i]
        local from = sq + delta
        while band(from, 0x88) == 0 do
            local p = board[from]
            if p ~= EMPTY then
                if p == bishop or p == queen then return true end
                break
            end
            from = from + delta
        end
    end

    return false
end

--- Is the given side's king currently in check?
function BoardMT:inCheck(colour)
    colour = colour or self.side
    local ksq = self.kingsq[colour]
    if ksq == NO_SQUARE then return false end
    return self:isAttacked(ksq, 1 - colour)
end

--==========================================================================
-- Move generation
--==========================================================================

-- Castling descriptors: rights mask, king from/to, rook from/to, and the
-- squares that must be empty and unattacked.
local CASTLES = {
    [WHITE] = {
        { mask = CASTLE_WK, kfrom = E1, kto = E1 + 2, rfrom = H1, rto = E1 + 1,
          empty = { E1 + 1, E1 + 2 }, safe = { E1, E1 + 1, E1 + 2 } },
        { mask = CASTLE_WQ, kfrom = E1, kto = E1 - 2, rfrom = A1, rto = E1 - 1,
          empty = { E1 - 1, E1 - 2, E1 - 3 }, safe = { E1, E1 - 1, E1 - 2 } },
    },
    [BLACK] = {
        { mask = CASTLE_BK, kfrom = E8, kto = E8 + 2, rfrom = H8, rto = E8 + 1,
          empty = { E8 + 1, E8 + 2 }, safe = { E8, E8 + 1, E8 + 2 } },
        { mask = CASTLE_BQ, kfrom = E8, kto = E8 - 2, rfrom = A8, rto = E8 - 1,
          empty = { E8 - 1, E8 - 2, E8 - 3 }, safe = { E8, E8 - 1, E8 - 2 } },
    },
}

local PROMO_PIECES = { QUEEN, ROOK, BISHOP, KNIGHT }

--- Generate pseudo-legal moves into `list`, returning the count.
-- Pseudo-legal means "correct except that the mover may be left in check";
-- @{BoardMT:generateMoves} filters those out.
-- If `captures_only` is true, only captures and promotions are generated,
-- which is what the quiescence search wants.
function BoardMT:generatePseudoMoves(list, captures_only)
    local board = self.sq
    local us = self.side
    local them = 1 - us
    local n = 0

    for rank = 0, 7 do
        for file = 0, 7 do
            local from = rank * 16 + file
            local piece = board[from]
            if piece ~= EMPTY and rshift(piece, 3) == us then
                local ptype = band(piece, 7)

                if ptype == PAWN then
                    local push = PAWN_PUSH[us]
                    local promo_rank = PAWN_PROMO_RANK[us]

                    -- Captures, including promotion captures.
                    local caps = PAWN_CAPS[us]
                    for i = 1, 2 do
                        local to = from + caps[i]
                        if band(to, 0x88) == 0 then
                            local target = board[to]
                            if target ~= EMPTY and rshift(target, 3) == them then
                                if rankOf(to) == promo_rank then
                                    for j = 1, 4 do
                                        n = n + 1
                                        list[n] = packMove(from, to, target,
                                                           PROMO_PIECES[j], FLAG_PROMO)
                                    end
                                else
                                    n = n + 1
                                    list[n] = packMove(from, to, target, 0, 0)
                                end
                            elseif to == self.ep then
                                n = n + 1
                                list[n] = packMove(from, to, them * 8 + PAWN, 0, FLAG_EP)
                            end
                        end
                    end

                    -- Quiet pushes. A promotion is generated even in
                    -- captures-only mode: it changes material outright, so
                    -- quiescence must see it.
                    local to = from + push
                    if band(to, 0x88) == 0 and board[to] == EMPTY then
                        if rankOf(to) == promo_rank then
                            for j = 1, 4 do
                                n = n + 1
                                list[n] = packMove(from, to, 0, PROMO_PIECES[j], FLAG_PROMO)
                            end
                        elseif not captures_only then
                            n = n + 1
                            list[n] = packMove(from, to, 0, 0, 0)
                            -- Double push, only from the starting rank.
                            if rank == PAWN_START_RANK[us] then
                                local to2 = to + push
                                if board[to2] == EMPTY then
                                    n = n + 1
                                    list[n] = packMove(from, to2, 0, 0, FLAG_DPP)
                                end
                            end
                        end
                    end

                elseif ptype == KNIGHT or ptype == KING then
                    local deltas = (ptype == KNIGHT) and KNIGHT_DELTAS or KING_DELTAS
                    for i = 1, 8 do
                        local to = from + deltas[i]
                        if band(to, 0x88) == 0 then
                            local target = board[to]
                            if target == EMPTY then
                                if not captures_only then
                                    n = n + 1
                                    list[n] = packMove(from, to, 0, 0, 0)
                                end
                            elseif rshift(target, 3) == them then
                                n = n + 1
                                list[n] = packMove(from, to, target, 0, 0)
                            end
                        end
                    end

                else -- bishop, rook, queen
                    local deltas = SLIDER_DELTAS[ptype]
                    for i = 1, #deltas do
                        local delta = deltas[i]
                        local to = from + delta
                        while band(to, 0x88) == 0 do
                            local target = board[to]
                            if target == EMPTY then
                                if not captures_only then
                                    n = n + 1
                                    list[n] = packMove(from, to, 0, 0, 0)
                                end
                            else
                                if rshift(target, 3) == them then
                                    n = n + 1
                                    list[n] = packMove(from, to, target, 0, 0)
                                end
                                break
                            end
                            to = to + delta
                        end
                    end
                end
            end
        end
    end

    -- Castling. Never a capture, so quiescence skips it.
    if not captures_only then
        local ksq = self.kingsq[us]
        if ksq ~= NO_SQUARE and not self:isAttacked(ksq, them) then
            local options = CASTLES[us]
            for i = 1, 2 do
                local c = options[i]
                if band(self.castling, c.mask) ~= 0
                   and board[c.kfrom] == us * 8 + KING
                   and board[c.rfrom] == us * 8 + ROOK then
                    local ok = true
                    for j = 1, #c.empty do
                        if board[c.empty[j]] ~= EMPTY then ok = false; break end
                    end
                    if ok then
                        -- The king may not start in, pass through, or land on
                        -- an attacked square.
                        for j = 1, #c.safe do
                            if self:isAttacked(c.safe[j], them) then ok = false; break end
                        end
                    end
                    if ok then
                        n = n + 1
                        list[n] = packMove(c.kfrom, c.kto, 0, 0, FLAG_CASTLE)
                    end
                end
            end
        end
    end

    return n
end

--- Generate fully legal moves into `list`, returning the count.
function BoardMT:generateMoves(list, captures_only)
    local pseudo = {}
    local count = self:generatePseudoMoves(pseudo, captures_only)
    local n = 0
    for i = 1, count do
        local m = pseudo[i]
        if self:makeMove(m) then
            n = n + 1
            list[n] = m
            self:unmakeMove(m)
        end
    end
    return n
end

--==========================================================================
-- Make / unmake
--==========================================================================

-- Any move touching one of these squares invalidates the associated rights,
-- whether it is the king/rook moving out or an enemy piece capturing a rook.
local CASTLE_MASK = {}
do
    for s = 0, 127 do CASTLE_MASK[s] = 0 end
    CASTLE_MASK[E1] = bor(CASTLE_WK, CASTLE_WQ)
    CASTLE_MASK[H1] = CASTLE_WK
    CASTLE_MASK[A1] = CASTLE_WQ
    CASTLE_MASK[E8] = bor(CASTLE_BK, CASTLE_BQ)
    CASTLE_MASK[H8] = CASTLE_BK
    CASTLE_MASK[A8] = CASTLE_BQ
end

--- Apply a move.
-- Returns true if the move was legal. If it left the mover in check the move
-- is taken back before returning false, so the board is always left unchanged
-- on failure.
function BoardMT:makeMove(m)
    local board = self.sq
    local us = self.side
    local them = 1 - us
    local from, to = moveFrom(m), moveTo(m)
    local flags = moveFlags(m)
    local promo = movePromo(m)
    local piece = board[from]
    local ptype = band(piece, 7)

    local ply = self.ply
    self.u_castling[ply] = self.castling
    self.u_ep[ply] = self.ep
    self.u_halfmove[ply] = self.halfmove
    self.u_hash_lo[ply] = self.hash_lo
    self.u_hash_hi[ply] = self.hash_hi

    local lo, hi = self.hash_lo, self.hash_hi

    -- Remove the old en passant square from the hash before we change it.
    if self.ep ~= NO_SQUARE then
        local f = fileOf(self.ep)
        lo = bxor(lo, zob_ep_lo[f]); hi = bxor(hi, zob_ep_hi[f])
    end
    lo = bxor(lo, zob_castle_lo[self.castling])
    hi = bxor(hi, zob_castle_hi[self.castling])

    -- Lift the captured piece. For en passant the victim is not on `to`.
    local captured = moveCaptured(m)
    if flags == FLAG_EP then
        local victim = to - PAWN_PUSH[us]
        lo = bxor(lo, zob_piece_lo[board[victim]][victim])
        hi = bxor(hi, zob_piece_hi[board[victim]][victim])
        board[victim] = EMPTY
    elseif captured ~= 0 then
        lo = bxor(lo, zob_piece_lo[captured][to])
        hi = bxor(hi, zob_piece_hi[captured][to])
    end

    -- Move the piece.
    lo = bxor(lo, zob_piece_lo[piece][from]); hi = bxor(hi, zob_piece_hi[piece][from])
    board[from] = EMPTY
    local landed = piece
    if promo ~= 0 then
        landed = us * 8 + promo
    end
    board[to] = landed
    lo = bxor(lo, zob_piece_lo[landed][to]); hi = bxor(hi, zob_piece_hi[landed][to])

    if ptype == KING then
        self.kingsq[us] = to
    end

    -- Shift the rook when castling.
    if flags == FLAG_CASTLE then
        local rfrom, rto
        if to > from then           -- kingside
            rfrom, rto = from + 3, from + 1
        else                        -- queenside
            rfrom, rto = from - 4, from - 1
        end
        local rook = board[rfrom]
        board[rfrom] = EMPTY
        board[rto] = rook
        lo = bxor(lo, zob_piece_lo[rook][rfrom], zob_piece_lo[rook][rto])
        hi = bxor(hi, zob_piece_hi[rook][rfrom], zob_piece_hi[rook][rto])
    end

    -- Update castling rights and the en passant square.
    self.castling = band(self.castling,
                         bit.bnot(bor(CASTLE_MASK[from], CASTLE_MASK[to])))
    lo = bxor(lo, zob_castle_lo[self.castling])
    hi = bxor(hi, zob_castle_hi[self.castling])

    if flags == FLAG_DPP then
        self.ep = from + PAWN_PUSH[us]
        local f = fileOf(self.ep)
        lo = bxor(lo, zob_ep_lo[f]); hi = bxor(hi, zob_ep_hi[f])
    else
        self.ep = NO_SQUARE
    end

    -- Halfmove clock resets on a pawn move or a capture.
    if ptype == PAWN or captured ~= 0 or flags == FLAG_EP then
        self.halfmove = 0
    else
        self.halfmove = self.halfmove + 1
    end

    if us == BLACK then self.fullmove = self.fullmove + 1 end
    self.side = them
    lo = bxor(lo, zob_side_lo); hi = bxor(hi, zob_side_hi)

    self.hash_lo, self.hash_hi = lo, hi
    self.ply = ply + 1
    self.hist_lo[self.ply], self.hist_hi[self.ply] = lo, hi

    -- Reject the move if it left our own king attacked.
    if self:inCheck(us) then
        self:unmakeMove(m)
        return false
    end
    return true
end

--- Take back a move applied with @{BoardMT:makeMove}.
function BoardMT:unmakeMove(m)
    local board = self.sq
    local ply = self.ply - 1
    self.ply = ply

    local them = self.side          -- side to move *after* the move
    local us = 1 - them             -- side that made the move
    local from, to = moveFrom(m), moveTo(m)
    local flags = moveFlags(m)
    local promo = movePromo(m)

    local piece = board[to]
    if promo ~= 0 then
        piece = us * 8 + PAWN       -- a promoted pawn goes back to being a pawn
    end

    board[from] = piece
    board[to] = EMPTY

    if band(piece, 7) == KING then
        self.kingsq[us] = from
    end

    -- Restore the captured piece.
    local captured = moveCaptured(m)
    if flags == FLAG_EP then
        board[to - PAWN_PUSH[us]] = captured
    elseif captured ~= 0 then
        board[to] = captured
    end

    -- Put the rook back.
    if flags == FLAG_CASTLE then
        local rfrom, rto
        if to > from then
            rfrom, rto = from + 3, from + 1
        else
            rfrom, rto = from - 4, from - 1
        end
        board[rfrom] = board[rto]
        board[rto] = EMPTY
    end

    self.castling = self.u_castling[ply]
    self.ep = self.u_ep[ply]
    self.halfmove = self.u_halfmove[ply]
    self.hash_lo = self.u_hash_lo[ply]
    self.hash_hi = self.u_hash_hi[ply]

    if us == BLACK then self.fullmove = self.fullmove - 1 end
    self.side = us
end

--- Pass the turn without moving, for null-move pruning in the search.
-- Only legal when the side to move is not in check.
function BoardMT:makeNullMove()
    local ply = self.ply
    self.u_castling[ply] = self.castling
    self.u_ep[ply] = self.ep
    self.u_halfmove[ply] = self.halfmove
    self.u_hash_lo[ply] = self.hash_lo
    self.u_hash_hi[ply] = self.hash_hi

    local lo, hi = self.hash_lo, self.hash_hi
    if self.ep ~= NO_SQUARE then
        local f = fileOf(self.ep)
        lo = bxor(lo, zob_ep_lo[f]); hi = bxor(hi, zob_ep_hi[f])
    end
    self.ep = NO_SQUARE
    self.side = 1 - self.side
    lo = bxor(lo, zob_side_lo); hi = bxor(hi, zob_side_hi)

    self.hash_lo, self.hash_hi = lo, hi
    self.ply = ply + 1
    -- A null move is not a real position; mark it so repetition detection
    -- cannot match against it.
    self.hist_lo[self.ply], self.hist_hi[self.ply] = 0, 0
end

function BoardMT:unmakeNullMove()
    local ply = self.ply - 1
    self.ply = ply
    self.castling = self.u_castling[ply]
    self.ep = self.u_ep[ply]
    self.halfmove = self.u_halfmove[ply]
    self.hash_lo = self.u_hash_lo[ply]
    self.hash_hi = self.u_hash_hi[ply]
    self.side = 1 - self.side
end

--==========================================================================
-- Game state
--==========================================================================

--- Has this exact position occurred `count` times (including now)?
function BoardMT:isRepetition(count)
    count = count or 3
    local lo, hi = self.hash_lo, self.hash_hi
    local seen = 1
    -- Only positions since the last irreversible move can repeat, and they
    -- alternate side to move, so step back two plies at a time.
    local limit = math.max(0, self.ply - self.halfmove)
    for i = self.ply - 2, limit, -2 do
        if self.hist_lo[i] == lo and self.hist_hi[i] == hi then
            seen = seen + 1
            if seen >= count then return true end
        end
    end
    return false
end

--- Not enough material on the board for either side to force mate.
function BoardMT:isInsufficientMaterial()
    local minors = 0
    local bishops_on = {}
    for rank = 0, 7 do
        for file = 0, 7 do
            local p = self.sq[rank * 16 + file]
            if p ~= EMPTY then
                local t = band(p, 7)
                if t == PAWN or t == ROOK or t == QUEEN then
                    return false
                elseif t == KNIGHT or t == BISHOP then
                    minors = minors + 1
                    if minors > 2 then return false end
                    if t == BISHOP then
                        bishops_on[#bishops_on + 1] = (rank + file) % 2
                    end
                end
            end
        end
    end
    if minors <= 1 then return true end
    -- Two bishops only draw if they share a square colour.
    if #bishops_on == 2 and bishops_on[1] == bishops_on[2] then return true end
    return false
end

--- Describe how the game has ended, or nil if it is still going.
-- Returns one of "checkmate", "stalemate", "fifty", "repetition",
-- "insufficient"; for checkmate the winning colour is returned as well.
function BoardMT:getGameResult()
    local moves = {}
    local n = self:generateMoves(moves)
    if n == 0 then
        if self:inCheck() then
            return "checkmate", 1 - self.side
        end
        return "stalemate"
    end
    if self.halfmove >= 100 then return "fifty" end
    if self:isRepetition(3) then return "repetition" end
    if self:isInsufficientMaterial() then return "insufficient" end
    return nil
end

--==========================================================================
-- Notation
--==========================================================================

--- Find the legal move matching a from/to square pair, or nil.
-- `promo` selects the promotion piece when the move is a promotion.
function BoardMT:findMove(from, to, promo)
    local moves = {}
    local n = self:generateMoves(moves)
    for i = 1, n do
        local m = moves[i]
        if moveFrom(m) == from and moveTo(m) == to then
            local p = movePromo(m)
            if p == 0 or promo == nil or p == promo then
                return m
            end
        end
    end
    return nil
end

--- Long algebraic notation, e.g. "e2e4" or "e7e8q". Used for save files.
function BoardMT:moveToUci(m)
    local s = Board.squareName(moveFrom(m)) .. Board.squareName(moveTo(m))
    local promo = movePromo(m)
    if promo ~= 0 then
        s = s .. string.lower(PIECE_TO_FEN[WHITE * 8 + promo])
    end
    return s
end

local UCI_PROMO = { q = QUEEN, r = ROOK, b = BISHOP, n = KNIGHT }

--- Parse long algebraic notation into a legal move, or nil.
function BoardMT:moveFromUci(s)
    if type(s) ~= "string" or #s < 4 then return nil end
    local from = Board.squareFromName(s:sub(1, 2))
    local to = Board.squareFromName(s:sub(3, 4))
    if not from or not to then return nil end
    local promo = UCI_PROMO[s:sub(5, 5)]
    return self:findMove(from, to, promo)
end

local PIECE_LETTER = { [KNIGHT] = "N", [BISHOP] = "B", [ROOK] = "R",
                       [QUEEN] = "Q", [KING] = "K" }

--- Standard algebraic notation for a move legal in the current position.
-- Must be called *before* the move is made.
function BoardMT:moveToSan(m)
    local from, to = moveFrom(m), moveTo(m)
    local flags = moveFlags(m)
    local piece = self.sq[from]
    local ptype = band(piece, 7)
    local san

    if flags == FLAG_CASTLE then
        san = (to > from) and "O-O" or "O-O-O"
    else
        local captured = moveCaptured(m)
        local is_capture = captured ~= 0 or flags == FLAG_EP

        if ptype == PAWN then
            san = is_capture
                and (string.char(97 + fileOf(from)) .. "x" .. Board.squareName(to))
                or Board.squareName(to)
            local promo = movePromo(m)
            if promo ~= 0 then
                san = san .. "=" .. PIECE_LETTER[promo]
            end
        else
            -- Disambiguate against other pieces of the same type that could
            -- also legally reach `to`.
            local same_file, same_rank, ambiguous = false, false, false
            local moves = {}
            local n = self:generateMoves(moves)
            for i = 1, n do
                local other = moves[i]
                local ofrom = moveFrom(other)
                if ofrom ~= from and moveTo(other) == to
                   and band(self.sq[ofrom], 7) == ptype then
                    ambiguous = true
                    if fileOf(ofrom) == fileOf(from) then same_file = true end
                    if rankOf(ofrom) == rankOf(from) then same_rank = true end
                end
            end
            local disambig = ""
            if ambiguous then
                if not same_file then
                    disambig = string.char(97 + fileOf(from))
                elseif not same_rank then
                    disambig = tostring(rankOf(from) + 1)
                else
                    disambig = Board.squareName(from)
                end
            end
            san = PIECE_LETTER[ptype] .. disambig
                .. (is_capture and "x" or "") .. Board.squareName(to)
        end
    end

    -- Check and mate suffixes require looking at the resulting position.
    if self:makeMove(m) then
        if self:inCheck() then
            local replies = {}
            san = san .. ((self:generateMoves(replies) == 0) and "#" or "+")
        end
        self:unmakeMove(m)
    end
    return san
end

--- Deep copy of the position, including the history needed to detect
-- repetitions.
--
-- The search mutates the board it is given as it explores, so anything that
-- searches while the UI is live must hand it a copy -- otherwise a repaint
-- that lands mid-search draws whatever hypothetical position the engine
-- happens to be standing in.
function BoardMT:clone()
    local other = Board.new(self:getFen())
    -- Carry over the positions reached earlier in the game. Without these the
    -- search cannot see that a line repeats one of them, and will happily
    -- shuffle into a draw it should be avoiding (or miss one it wants).
    for i = 0, self.ply do
        other.hist_lo[i] = self.hist_lo[i]
        other.hist_hi[i] = self.hist_hi[i]
    end
    other.ply = self.ply
    return other
end

return Board
