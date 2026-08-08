--[[--
Position evaluation, in centipawns, always from White's point of view.

Deliberately modest: material, piece-square tables, pawn structure, bishop
pair and king safety. On a 1 GHz Cortex-A9 the evaluation runs at every leaf,
so anything more elaborate buys less strength than the extra search depth it
would cost.

@module kobochess.eval
--]]--

local bit = require("bit")
local band, rshift = bit.band, bit.rshift

local Board = require("kobochess.board")

local WHITE, BLACK = Board.WHITE, Board.BLACK
local PAWN, KNIGHT, BISHOP = Board.PAWN, Board.KNIGHT, Board.BISHOP
local ROOK, QUEEN, KING = Board.ROOK, Board.QUEEN, Board.KING
local EMPTY = Board.EMPTY

local Eval = {}

--- Material values. The knight/bishop gap is small but real; the bishop pair
-- bonus below carries most of the difference.
local VALUE = {
    [PAWN] = 100, [KNIGHT] = 320, [BISHOP] = 330,
    [ROOK] = 500, [QUEEN] = 900, [KING] = 0,
}
Eval.VALUE = VALUE

-- Value used only for sizing the game phase, so the king is excluded.
local PHASE_WEIGHT = {
    [PAWN] = 0, [KNIGHT] = 1, [BISHOP] = 1,
    [ROOK] = 2, [QUEEN] = 4, [KING] = 0,
}
local PHASE_TOTAL = 24     -- 4 knights + 4 bishops + 4 rooks + 2 queens

-- Piece-square tables, written a8-first so they read like a board.
local PST = {}

PST[PAWN] = {
     0,  0,  0,  0,  0,  0,  0,  0,
    50, 50, 50, 50, 50, 50, 50, 50,
    10, 10, 20, 30, 30, 20, 10, 10,
     5,  5, 10, 25, 25, 10,  5,  5,
     0,  0,  0, 20, 20,  0,  0,  0,
     5, -5,-10,  0,  0,-10, -5,  5,
     5, 10, 10,-20,-20, 10, 10,  5,
     0,  0,  0,  0,  0,  0,  0,  0,
}

PST[KNIGHT] = {
    -50,-40,-30,-30,-30,-30,-40,-50,
    -40,-20,  0,  0,  0,  0,-20,-40,
    -30,  0, 10, 15, 15, 10,  0,-30,
    -30,  5, 15, 20, 20, 15,  5,-30,
    -30,  0, 15, 20, 20, 15,  0,-30,
    -30,  5, 10, 15, 15, 10,  5,-30,
    -40,-20,  0,  5,  5,  0,-20,-40,
    -50,-40,-30,-30,-30,-30,-40,-50,
}

PST[BISHOP] = {
    -20,-10,-10,-10,-10,-10,-10,-20,
    -10,  0,  0,  0,  0,  0,  0,-10,
    -10,  0,  5, 10, 10,  5,  0,-10,
    -10,  5,  5, 10, 10,  5,  5,-10,
    -10,  0, 10, 10, 10, 10,  0,-10,
    -10, 10, 10, 10, 10, 10, 10,-10,
    -10,  5,  0,  0,  0,  0,  5,-10,
    -20,-10,-10,-10,-10,-10,-10,-20,
}

PST[ROOK] = {
      0,  0,  0,  0,  0,  0,  0,  0,
      5, 10, 10, 10, 10, 10, 10,  5,
     -5,  0,  0,  0,  0,  0,  0, -5,
     -5,  0,  0,  0,  0,  0,  0, -5,
     -5,  0,  0,  0,  0,  0,  0, -5,
     -5,  0,  0,  0,  0,  0,  0, -5,
     -5,  0,  0,  0,  0,  0,  0, -5,
      0,  0,  0,  5,  5,  0,  0,  0,
}

PST[QUEEN] = {
    -20,-10,-10, -5, -5,-10,-10,-20,
    -10,  0,  0,  0,  0,  0,  0,-10,
    -10,  0,  5,  5,  5,  5,  0,-10,
     -5,  0,  5,  5,  5,  5,  0, -5,
      0,  0,  5,  5,  5,  5,  0, -5,
    -10,  5,  5,  5,  5,  5,  0,-10,
    -10,  0,  5,  0,  0,  0,  0,-10,
    -20,-10,-10, -5, -5,-10,-10,-20,
}

-- The king wants shelter in the middlegame and the centre in the endgame, so
-- it gets two tables interpolated by game phase.
local KING_MG = {
    -30,-40,-40,-50,-50,-40,-40,-30,
    -30,-40,-40,-50,-50,-40,-40,-30,
    -30,-40,-40,-50,-50,-40,-40,-30,
    -30,-40,-40,-50,-50,-40,-40,-30,
    -20,-30,-30,-40,-40,-30,-30,-20,
    -10,-20,-20,-20,-20,-20,-20,-10,
     20, 20,  0,  0,  0,  0, 20, 20,
     20, 30, 10,  0,  0, 10, 30, 20,
}

local KING_EG = {
    -50,-40,-30,-20,-20,-30,-40,-50,
    -30,-20,-10,  0,  0,-10,-20,-30,
    -30,-10, 20, 30, 30, 20,-10,-30,
    -30,-10, 30, 40, 40, 30,-10,-30,
    -30,-10, 30, 40, 40, 30,-10,-30,
    -30,-10, 20, 30, 30, 20,-10,-30,
    -30,-30,  0,  0,  0,  0,-30,-30,
    -50,-30,-30,-30,-30,-30,-30,-50,
}

-- Map a 0x88 square to the index of the tables above. White reads them as
-- written; Black reads them vertically mirrored.
local PST_IDX = { [WHITE] = {}, [BLACK] = {} }
for rank = 0, 7 do
    for file = 0, 7 do
        local sq = rank * 16 + file
        PST_IDX[WHITE][sq] = (7 - rank) * 8 + file + 1
        PST_IDX[BLACK][sq] = rank * 8 + file + 1
    end
end

local BISHOP_PAIR_BONUS = 30
local DOUBLED_PAWN_PENALTY = -12
local ISOLATED_PAWN_PENALTY = -18
-- Indexed by the rank the pawn has reached from its own side (0..7).
local PASSED_PAWN_BONUS = { [0] = 0, 5, 15, 30, 55, 90, 140, 0 }
local ROOK_OPEN_FILE = 18
local ROOK_HALF_OPEN_FILE = 9
local TEMPO_BONUS = 10

-- Scratch state, reused across calls. Evaluation runs at every leaf of the
-- search, so allocating these tables per call would put the whole search on
-- the garbage collector's critical path.
local pawn_files = { [WHITE] = {}, [BLACK] = {} }
local pawn_ranks = { [WHITE] = {}, [BLACK] = {} }
local rook_files = { [WHITE] = {}, [BLACK] = {} }
local bishops = { [WHITE] = 0, [BLACK] = 0 }
local rook_count = { [WHITE] = 0, [BLACK] = 0 }

--- Evaluate the position from White's perspective, in centipawns.
function Eval.evaluate(b)
    local sq = b.sq
    local mg, eg = 0, 0          -- middlegame and endgame scores
    local phase = 0

    for colour = WHITE, BLACK do
        local pf, pr = pawn_files[colour], pawn_ranks[colour]
        for f = 1, 8 do
            pf[f] = 0
            pr[f] = 0
        end
        bishops[colour] = 0
        rook_count[colour] = 0
    end

    for rank = 0, 7 do
        for file = 0, 7 do
            local s = rank * 16 + file
            local p = sq[s]
            if p ~= EMPTY then
                local colour = rshift(p, 3)
                local ptype = band(p, 7)
                local sign = (colour == WHITE) and 1 or -1
                local idx = PST_IDX[colour][s]

                phase = phase + PHASE_WEIGHT[ptype]

                local base = VALUE[ptype]
                if ptype == KING then
                    mg = mg + sign * (base + KING_MG[idx])
                    eg = eg + sign * (base + KING_EG[idx])
                else
                    local score = base + PST[ptype][idx]
                    mg = mg + sign * score
                    eg = eg + sign * score
                end

                if ptype == PAWN then
                    pawn_files[colour][file + 1] = pawn_files[colour][file + 1] + 1
                    local own_rank = (colour == WHITE) and rank or (7 - rank)
                    if own_rank > pawn_ranks[colour][file + 1] then
                        pawn_ranks[colour][file + 1] = own_rank
                    end
                elseif ptype == BISHOP then
                    bishops[colour] = bishops[colour] + 1
                elseif ptype == ROOK then
                    local n = rook_count[colour] + 1
                    rook_count[colour] = n
                    rook_files[colour][n] = file + 1
                end
            end
        end
    end

    -- Bishop pair.
    if bishops[WHITE] >= 2 then mg = mg + BISHOP_PAIR_BONUS; eg = eg + BISHOP_PAIR_BONUS end
    if bishops[BLACK] >= 2 then mg = mg - BISHOP_PAIR_BONUS; eg = eg - BISHOP_PAIR_BONUS end

    -- Pawn structure.
    for colour = WHITE, BLACK do
        local sign = (colour == WHITE) and 1 or -1
        local mine, theirs = pawn_files[colour], pawn_files[1 - colour]
        for f = 1, 8 do
            local count = mine[f]
            if count > 0 then
                if count > 1 then
                    local pen = DOUBLED_PAWN_PENALTY * (count - 1)
                    mg = mg + sign * pen; eg = eg + sign * pen
                end
                local left = (f > 1) and mine[f - 1] or 0
                local right = (f < 8) and mine[f + 1] or 0
                if left == 0 and right == 0 then
                    mg = mg + sign * ISOLATED_PAWN_PENALTY
                    eg = eg + sign * ISOLATED_PAWN_PENALTY
                end
                -- Approximate passed-pawn test: no enemy pawn on this file or
                -- either neighbour. It ignores whether the blocker is actually
                -- ahead, which costs a little accuracy and saves a lot of time.
                local blocked = theirs[f] > 0
                    or ((f > 1) and theirs[f - 1] > 0)
                    or ((f < 8) and theirs[f + 1] > 0)
                if not blocked then
                    local bonus = PASSED_PAWN_BONUS[pawn_ranks[colour][f]] or 0
                    mg = mg + sign * bonus
                    eg = eg + sign * math.floor(bonus * 1.5)
                end
            end
        end

        -- Rooks like files without their own pawns on them.
        for i = 1, rook_count[colour] do
            local f = rook_files[colour][i]
            if mine[f] == 0 then
                local bonus = (theirs[f] == 0) and ROOK_OPEN_FILE or ROOK_HALF_OPEN_FILE
                mg = mg + sign * bonus
                eg = eg + sign * bonus
            end
        end
    end

    -- Interpolate between the middlegame and endgame scores.
    if phase > PHASE_TOTAL then phase = PHASE_TOTAL end
    local score = math.floor((mg * phase + eg * (PHASE_TOTAL - phase)) / PHASE_TOTAL)

    -- Small bonus for having the move.
    score = score + ((b.side == WHITE) and TEMPO_BONUS or -TEMPO_BONUS)

    return score
end

--- Evaluation from the side to move's point of view, which is what a
-- negamax search wants.
function Eval.evaluateForSideToMove(b)
    local score = Eval.evaluate(b)
    return (b.side == WHITE) and score or -score
end

return Eval
