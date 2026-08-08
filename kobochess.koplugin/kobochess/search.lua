--[[--
Alpha-beta search with iterative deepening.

The search is written to be interruptible: every few thousand nodes it calls
an `on_tick` hook supplied by the caller. The KOReader front end runs the
whole search inside a coroutine and yields from that hook, which is what keeps
the screen responsive while the engine thinks. The engine itself knows nothing
about coroutines or UI.

@module kobochess.search
--]]--

local bit = require("bit")
local band, rshift = bit.band, bit.rshift

local Board = require("kobochess.board")
local Eval = require("kobochess.eval")

local WHITE, BLACK = Board.WHITE, Board.BLACK
local PAWN, KNIGHT, KING = Board.PAWN, Board.KNIGHT, Board.KING
local QUEEN = Board.QUEEN
local EMPTY = Board.EMPTY
local moveFrom, moveTo = Board.moveFrom, Board.moveTo
local moveCaptured, movePromo, moveFlags =
    Board.moveCaptured, Board.movePromo, Board.moveFlags
local FLAG_EP, FLAG_PROMO = Board.FLAG_EP, Board.FLAG_PROMO

local Search = {}

local MAX_PLY = 64
local MATE_VALUE = 30000
local MATE_THRESHOLD = MATE_VALUE - MAX_PLY
local INFINITY = 100000

Search.MATE_VALUE = MATE_VALUE
Search.MATE_THRESHOLD = MATE_THRESHOLD

-- Transposition table bound flags.
local TT_EXACT, TT_LOWER, TT_UPPER = 1, 2, 3
local TT_BITS = 15
local TT_SIZE = 2 ^ TT_BITS
local TT_MASK = TT_SIZE - 1

--- Difficulty presets.
-- `noise` adds a random centipawn offset to root moves, which makes the weak
-- levels choose imperfectly and vary their play instead of grinding out the
-- same best move every game.
Search.LEVELS = {
    { name = "Beginner",     depth = 1,  time = 0.5, noise = 90 },
    { name = "Easy",         depth = 2,  time = 1.0, noise = 55 },
    { name = "Casual",       depth = 3,  time = 2.0, noise = 30 },
    { name = "Intermediate", depth = 5,  time = 4.0, noise = 12 },
    { name = "Strong",       depth = 8,  time = 10.0, noise = 0 },
    { name = "Maximum",      depth = 20, time = 25.0, noise = 0 },
}

--==========================================================================
-- Searcher object
--==========================================================================

local Searcher = {}
Searcher.__index = Searcher
Search.Searcher = Searcher

function Search.new()
    local s = setmetatable({}, Searcher)

    -- Preallocated per-ply move and score lists. Allocating these once and
    -- reusing them keeps the GC out of the search entirely.
    s.moves, s.scores = {}, {}
    for ply = 0, MAX_PLY do
        s.moves[ply], s.scores[ply] = {}, {}
    end

    -- Killer moves: two quiet moves per ply that recently caused a cutoff.
    s.killer1, s.killer2 = {}, {}
    -- History heuristic, indexed by [piece][to square].
    s.history = {}
    for piece = 0, 15 do
        s.history[piece] = {}
    end

    -- Transposition table as flat arrays; one table of tables would cost far
    -- more memory and a lot more GC pressure.
    s.tt_lo, s.tt_hi = {}, {}
    s.tt_depth, s.tt_score, s.tt_flag, s.tt_move = {}, {}, {}, {}

    s.now = os.clock
    s.tick_interval = 2048
    s:reset()
    return s
end

--- Clear the transposition table and heuristics. Call between games.
function Searcher:reset()
    for i = 0, TT_MASK do
        self.tt_lo[i], self.tt_hi[i] = nil, nil
        self.tt_depth[i], self.tt_score[i] = 0, 0
        self.tt_flag[i], self.tt_move[i] = 0, 0
    end
    self:clearHeuristics()
end

function Searcher:clearHeuristics()
    for ply = 0, MAX_PLY do
        self.killer1[ply], self.killer2[ply] = 0, 0
    end
    for piece = 0, 15 do
        local row = self.history[piece]
        for sq = 0, 127 do row[sq] = 0 end
    end
end

--==========================================================================
-- Transposition table
--==========================================================================

function Searcher:ttProbe(b, depth, alpha, beta, ply)
    local i = band(b.hash_lo, TT_MASK)
    if self.tt_lo[i] ~= b.hash_lo or self.tt_hi[i] ~= b.hash_hi then
        return nil, 0
    end
    local move = self.tt_move[i]
    if self.tt_depth[i] < depth then
        -- Too shallow to trust the score, but the move is still worth trying
        -- first.
        return nil, move
    end

    local score = self.tt_score[i]
    -- Mate scores are stored relative to the node they were found at, so they
    -- have to be re-anchored to the current ply.
    if score > MATE_THRESHOLD then
        score = score - ply
    elseif score < -MATE_THRESHOLD then
        score = score + ply
    end

    local flag = self.tt_flag[i]
    if flag == TT_EXACT then
        return score, move
    elseif flag == TT_LOWER and score >= beta then
        return score, move
    elseif flag == TT_UPPER and score <= alpha then
        return score, move
    end
    return nil, move
end

function Searcher:ttStore(b, depth, score, flag, move, ply)
    local i = band(b.hash_lo, TT_MASK)
    -- Prefer deeper entries, but always overwrite a different position so a
    -- stale deep entry cannot squat on a slot forever.
    if self.tt_lo[i] == b.hash_lo and self.tt_hi[i] == b.hash_hi
       and self.tt_depth[i] > depth then
        return
    end

    if score > MATE_THRESHOLD then
        score = score + ply
    elseif score < -MATE_THRESHOLD then
        score = score - ply
    end

    self.tt_lo[i], self.tt_hi[i] = b.hash_lo, b.hash_hi
    self.tt_depth[i], self.tt_score[i] = depth, score
    self.tt_flag[i], self.tt_move[i] = flag, move
end

--==========================================================================
-- Move ordering
--==========================================================================

-- Most Valuable Victim / Least Valuable Aggressor: capturing a queen with a
-- pawn is tried long before capturing a pawn with a queen.
local MVV = { [0] = 0, 100, 320, 330, 500, 900, 20000 }

local SCORE_TT       = 4000000
local SCORE_PROMO    = 3000000
local SCORE_CAPTURE  = 2000000
local SCORE_KILLER1  = 1900000
local SCORE_KILLER2  = 1800000
local HISTORY_CAP    = 1700000

--- Assign an ordering score to every generated move.
function Searcher:scoreMoves(b, ply, count, tt_move)
    local moves, scores = self.moves[ply], self.scores[ply]
    local k1, k2 = self.killer1[ply], self.killer2[ply]
    local sq = b.sq
    for i = 1, count do
        local m = moves[i]
        local score
        if m == tt_move then
            score = SCORE_TT
        else
            local promo = movePromo(m)
            local captured = moveCaptured(m)
            if promo ~= 0 then
                score = SCORE_PROMO + MVV[promo] + MVV[band(captured, 7)]
            elseif captured ~= 0 or moveFlags(m) == FLAG_EP then
                local victim = MVV[band(captured, 7)]
                local attacker = MVV[band(sq[moveFrom(m)], 7)]
                score = SCORE_CAPTURE + victim * 16 - attacker
            elseif m == k1 then
                score = SCORE_KILLER1
            elseif m == k2 then
                score = SCORE_KILLER2
            else
                local h = self.history[sq[moveFrom(m)]][moveTo(m)]
                score = (h > HISTORY_CAP) and HISTORY_CAP or h
            end
        end
        scores[i] = score
    end
end

--- Selection sort for the next best move.
-- Sorting the whole list up front would be wasted work: alpha-beta usually
-- cuts off after the first few moves, so we only ever pull out what we use.
local function pickMove(moves, scores, index, count)
    local best, best_score = index, scores[index]
    for i = index + 1, count do
        if scores[i] > best_score then
            best, best_score = i, scores[i]
        end
    end
    if best ~= index then
        moves[index], moves[best] = moves[best], moves[index]
        scores[index], scores[best] = scores[best], scores[index]
    end
    return moves[index]
end

--==========================================================================
-- Node budget / interruption
--==========================================================================

--- Returns true when the search should stop right now.
function Searcher:checkStop()
    self.node_check = 0
    if self.aborted then return true end
    if self.on_tick then
        -- The hook may yield (front end) and may request an abort.
        if self.on_tick(self) == false then
            self.aborted = true
            return true
        end
    end
    if self.deadline and self.now() >= self.deadline then
        self.aborted = true
        return true
    end
    return false
end

--==========================================================================
-- Quiescence search
--==========================================================================

--- Search only forcing moves until the position is quiet.
-- Without this the engine happily "wins" a queen at the last ply and never
-- sees the recapture -- the classic horizon effect.
function Searcher:quiesce(b, alpha, beta, ply)
    self.nodes = self.nodes + 1
    self.node_check = self.node_check + 1
    if self.node_check >= self.tick_interval and self:checkStop() then
        return alpha
    end
    if ply >= MAX_PLY - 1 then
        return Eval.evaluateForSideToMove(b)
    end

    local stand_pat = Eval.evaluateForSideToMove(b)
    if stand_pat >= beta then return stand_pat end
    if stand_pat > alpha then alpha = stand_pat end

    local moves = self.moves[ply]
    local count = b:generatePseudoMoves(moves, true)
    self:scoreMoves(b, ply, count, 0)

    local best = stand_pat
    for i = 1, count do
        local m = pickMove(moves, self.scores[ply], i, count)

        -- Delta pruning: if even winning this piece outright cannot get us
        -- near alpha, the whole capture is irrelevant.
        local captured = moveCaptured(m)
        if captured ~= 0 and movePromo(m) == 0 then
            if stand_pat + MVV[band(captured, 7)] + 200 < alpha then
                goto continue
            end
        end

        if b:makeMove(m) then
            local score = -self:quiesce(b, -beta, -alpha, ply + 1)
            b:unmakeMove(m)
            if self.aborted then return alpha end
            if score > best then
                best = score
                if score > alpha then
                    alpha = score
                    if score >= beta then return score end
                end
            end
        end
        ::continue::
    end
    return best
end

--==========================================================================
-- Main search
--==========================================================================

--- Does the side to move have anything other than pawns and a king?
-- Null-move pruning is unsound in king-and-pawn endings, where zugzwang is
-- the whole point of the position.
local function hasNonPawnMaterial(b, colour)
    local sq = b.sq
    for rank = 0, 7 do
        for file = 0, 7 do
            local p = sq[rank * 16 + file]
            if p ~= EMPTY and rshift(p, 3) == colour then
                local t = band(p, 7)
                if t ~= PAWN and t ~= KING then return true end
            end
        end
    end
    return false
end

function Searcher:alphaBeta(b, depth, alpha, beta, ply, allow_null)
    -- Draw detection before anything else: a repetition is worth exactly zero
    -- no matter how good the position looks.
    if ply > 0 then
        if b.halfmove >= 100 or b:isRepetition(2) or b:isInsufficientMaterial() then
            return 0
        end
        -- Mate distance pruning: never look for a slower mate than one we can
        -- already force.
        local mate_alpha = -MATE_VALUE + ply
        local mate_beta = MATE_VALUE - ply - 1
        if mate_alpha > alpha then
            alpha = mate_alpha
            if alpha >= beta then return alpha end
        end
        if mate_beta < beta then
            beta = mate_beta
            if alpha >= beta then return beta end
        end
    end

    if depth <= 0 then
        return self:quiesce(b, alpha, beta, ply)
    end

    self.nodes = self.nodes + 1
    self.node_check = self.node_check + 1
    if self.node_check >= self.tick_interval and self:checkStop() then
        return alpha
    end
    if ply >= MAX_PLY - 1 then
        return Eval.evaluateForSideToMove(b)
    end

    local is_pv = (beta - alpha) > 1
    local tt_score, tt_move = self:ttProbe(b, depth, alpha, beta, ply)
    if tt_score and not is_pv and ply > 0 then
        return tt_score
    end

    local in_check = b:inCheck()

    -- Null-move pruning: give the opponent a free move; if we are still
    -- winning easily, this node is not worth searching properly.
    if allow_null and not is_pv and not in_check and depth >= 3
       and hasNonPawnMaterial(b, b.side) then
        local reduction = 2 + math.floor(depth / 6)
        b:makeNullMove()
        local score = -self:alphaBeta(b, depth - 1 - reduction, -beta, -beta + 1,
                                      ply + 1, false)
        b:unmakeNullMove()
        if self.aborted then return alpha end
        if score >= beta then
            -- Do not return unproven mate scores from a null-move cutoff.
            if score >= MATE_THRESHOLD then score = beta end
            return score
        end
    end

    local moves = self.moves[ply]
    local count = b:generatePseudoMoves(moves, false)
    self:scoreMoves(b, ply, count, tt_move)

    local scores = self.scores[ply]
    local best_score, best_move = -INFINITY, 0
    local legal = 0
    local original_alpha = alpha
    local quiets_tried = 0

    for i = 1, count do
        local m = pickMove(moves, scores, i, count)
        if b:makeMove(m) then
            legal = legal + 1
            local is_quiet = (moveCaptured(m) == 0 and movePromo(m) == 0)
            local gives_check = b:inCheck()

            -- Extend when the move gives check; those lines are forcing and
            -- cheap to search.
            local new_depth = depth - 1
            if gives_check then new_depth = new_depth + 1 end

            local score
            if legal == 1 then
                score = -self:alphaBeta(b, new_depth, -beta, -alpha, ply + 1, true)
            else
                -- Late move reductions: quiet moves ordered late are unlikely
                -- to be best, so search them shallower first and only redo
                -- them at full depth if they surprise us.
                local reduction = 0
                if is_quiet and depth >= 3 and not in_check and not gives_check
                   and quiets_tried >= 3 then
                    reduction = 1
                    if quiets_tried >= 8 and depth >= 5 then reduction = 2 end
                end

                score = -self:alphaBeta(b, new_depth - reduction, -alpha - 1, -alpha,
                                        ply + 1, true)
                if score > alpha and reduction > 0 then
                    score = -self:alphaBeta(b, new_depth, -alpha - 1, -alpha,
                                            ply + 1, true)
                end
                if score > alpha and score < beta then
                    score = -self:alphaBeta(b, new_depth, -beta, -alpha, ply + 1, true)
                end
            end

            b:unmakeMove(m)
            if self.aborted then
                -- Keep whatever we proved before the abort; the caller
                -- discards the incomplete iteration anyway.
                return (best_score > -INFINITY) and best_score or alpha
            end

            if is_quiet then quiets_tried = quiets_tried + 1 end

            if score > best_score then
                best_score, best_move = score, m
                if score > alpha then
                    alpha = score
                    if score >= beta then
                        -- A quiet move that causes a cutoff is worth trying
                        -- early in sibling nodes from now on.
                        if is_quiet then
                            if self.killer1[ply] ~= m then
                                self.killer2[ply] = self.killer1[ply]
                                self.killer1[ply] = m
                            end
                            local piece = b.sq[moveFrom(m)]
                            local h = self.history[piece]
                            local to = moveTo(m)
                            h[to] = h[to] + depth * depth
                        end
                        self:ttStore(b, depth, score, TT_LOWER, m, ply)
                        return score
                    end
                end
            end
        end
    end

    if legal == 0 then
        -- No legal move: mate if in check, otherwise stalemate. Scoring mate
        -- by ply makes the engine prefer the fastest mate.
        return in_check and (-MATE_VALUE + ply) or 0
    end

    local flag = (alpha > original_alpha) and TT_EXACT or TT_UPPER
    self:ttStore(b, depth, best_score, flag, best_move, ply)
    return best_score
end

--==========================================================================
-- Root
--==========================================================================

--- Reconstruct the principal variation from the transposition table.
local function extractPv(searcher, b, max_len)
    local pv, applied = {}, {}
    for _ = 1, max_len do
        local i = band(b.hash_lo, TT_MASK)
        if searcher.tt_lo[i] ~= b.hash_lo or searcher.tt_hi[i] ~= b.hash_hi then
            break
        end
        local m = searcher.tt_move[i]
        if m == 0 then break end
        -- The table can hand back a move from a colliding position, so
        -- confirm it is actually legal here.
        local legal = b:findMove(moveFrom(m), moveTo(m), movePromo(m) ~= 0 and movePromo(m) or nil)
        if not legal then break end
        pv[#pv + 1] = b:moveToSan(legal)
        b:makeMove(legal)
        applied[#applied + 1] = legal
    end
    for i = #applied, 1, -1 do
        b:unmakeMove(applied[i])
    end
    return pv
end

--- Search the position and return the move to play.
--
-- @param b        board to search (restored to its original state on return)
-- @param opts     table of options:
--                   level      index into Search.LEVELS (default 4)
--                   max_depth  override the level's depth
--                   max_time   override the level's time budget, in seconds
--                   on_tick    called periodically; return false to abort
--                   now        wall-clock function returning seconds
--                   on_depth   called as (depth, score, move_san, pv) after
--                              each completed iteration
--                   rng        function returning a float in [0,1)
-- @return move, info  where info has score, depth, nodes, pv, elapsed
function Searcher:think(b, opts)
    opts = opts or {}
    local level = Search.LEVELS[opts.level or 4] or Search.LEVELS[4]
    local max_depth = opts.max_depth or level.depth
    local max_time = opts.max_time or level.time
    local noise = opts.noise or level.noise or 0
    local rng = opts.rng or math.random

    self.now = opts.now or os.clock
    self.on_tick = opts.on_tick
    self.aborted = false
    self.nodes = 0
    self.node_check = 0
    local start_time = self.now()
    self.deadline = max_time and (start_time + max_time) or nil

    -- Heuristics carry over between moves, but history scores from ten moves
    -- ago describe a position that no longer exists; decay rather than clear.
    for piece = 0, 15 do
        local row = self.history[piece]
        for sq = 0, 127 do row[sq] = math.floor(row[sq] / 4) end
    end

    local root_moves = {}
    local root_count = b:generateMoves(root_moves)
    if root_count == 0 then
        return nil, { score = 0, depth = 0, nodes = 0, pv = {}, elapsed = 0 }
    end

    local root_scores = {}
    for i = 1, root_count do root_scores[i] = 0 end

    local best_move = root_moves[1]
    local best_score = 0
    local completed_depth = 0
    local pv = {}

    for depth = 1, max_depth do
        local alpha, beta = -INFINITY, INFINITY
        local iter_best, iter_best_score = nil, -INFINITY
        local iter_scores = {}

        for i = 1, root_count do
            local m = root_moves[i]
            b:makeMove(m)
            local score
            if i == 1 then
                score = -self:alphaBeta(b, depth - 1, -beta, -alpha, 1, true)
            else
                score = -self:alphaBeta(b, depth - 1, -alpha - 1, -alpha, 1, true)
                if score > alpha then
                    score = -self:alphaBeta(b, depth - 1, -beta, -alpha, 1, true)
                end
            end
            b:unmakeMove(m)

            if self.aborted then break end

            iter_scores[i] = score
            if score > iter_best_score then
                iter_best_score, iter_best = score, m
            end
            if score > alpha then alpha = score end
        end

        if self.aborted then break end

        -- The iteration finished, so its results supersede the previous one.
        best_move, best_score = iter_best, iter_best_score
        completed_depth = depth
        for i = 1, root_count do root_scores[i] = iter_scores[i] or -INFINITY end

        -- Search the best move first next time round; that is what makes
        -- iterative deepening cheaper than jumping straight to full depth.
        if iter_best and root_moves[1] ~= iter_best then
            for i = 2, root_count do
                if root_moves[i] == iter_best then
                    table.remove(root_moves, i)
                    table.insert(root_moves, 1, iter_best)
                    break
                end
            end
        end

        self:ttStore(b, depth, best_score, TT_EXACT, best_move, 0)
        pv = extractPv(self, b, depth)

        if opts.on_depth then
            opts.on_depth(depth, best_score, pv[1], pv)
        end

        -- A forced mate is found; no deeper search will improve on it.
        if best_score >= MATE_THRESHOLD or best_score <= -MATE_THRESHOLD then
            break
        end
        -- If the next iteration cannot plausibly finish in the time left,
        -- stop now rather than throwing the work away.
        if self.deadline then
            local elapsed = self.now() - start_time
            if elapsed > (self.deadline - start_time) * 0.5 then break end
        end
    end

    -- Weak levels pick imperfectly on purpose, choosing among moves that are
    -- close to best rather than always the best.
    if noise > 0 and completed_depth > 0 then
        local best_noisy, best_noisy_score = best_move, -INFINITY
        for i = 1, root_count do
            local s = root_scores[i]
            if s > -INFINITY then
                local jittered = s + math.floor((rng() * 2 - 1) * noise)
                if jittered > best_noisy_score then
                    best_noisy_score, best_noisy = jittered, root_moves[i]
                end
            end
        end
        -- Never blunder away a forced mate or walk into one for fun.
        if best_score < MATE_THRESHOLD and best_score > -MATE_THRESHOLD then
            best_move = best_noisy
        end
    end

    return best_move, {
        score = best_score,
        depth = completed_depth,
        nodes = self.nodes,
        pv = pv,
        elapsed = self.now() - start_time,
        aborted = self.aborted,
    }
end

--- Format a score for display, from the engine's point of view.
function Search.formatScore(score, side)
    -- Show the score from White's perspective, as scoresheets do.
    local white_score = (side == WHITE) and score or -score
    if score >= MATE_THRESHOLD then
        local moves = math.ceil((MATE_VALUE - score) / 2)
        return ((side == WHITE) and "#" or "#-") .. tostring(moves)
    elseif score <= -MATE_THRESHOLD then
        local moves = math.ceil((MATE_VALUE + score) / 2)
        return ((side == WHITE) and "#-" or "#") .. tostring(moves)
    end
    return string.format("%+.2f", white_score / 100)
end

return Search
