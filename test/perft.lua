--[[--
Perft: count leaf nodes of the move tree to a fixed depth and compare against
published values. This is the only real proof that move generation is correct
-- an engine with a subtle movegen bug plays plausible-looking illegal chess.

Run with:  luajit test/perft.lua [max_seconds_per_position]
--]]--

package.path = "kobochess.koplugin/?.lua;" .. package.path

local Board = require("kobochess.board")

--- Count leaf nodes at `depth` from the current position.
local function perft(b, depth)
    if depth == 0 then return 1 end
    local moves = {}
    local n = b:generatePseudoMoves(moves)
    local nodes = 0
    for i = 1, n do
        local m = moves[i]
        if b:makeMove(m) then
            if depth == 1 then
                nodes = nodes + 1
            else
                nodes = nodes + perft(b, depth - 1)
            end
            b:unmakeMove(m)
        end
    end
    return nodes
end

--- Per-move breakdown, for locating exactly where a count diverges.
local function divide(b, depth)
    local moves = {}
    local n = b:generatePseudoMoves(moves)
    local out = {}
    for i = 1, n do
        local m = moves[i]
        local uci = b:moveToUci(m)
        if b:makeMove(m) then
            out[#out + 1] = { uci = uci, nodes = perft(b, depth - 1) }
            b:unmakeMove(m)
        end
    end
    table.sort(out, function(x, y) return x.uci < y.uci end)
    return out
end

-- Standard perft suite (Chess Programming Wiki positions 1-6).
local SUITE = {
    {
        name = "startpos",
        fen = Board.START_FEN,
        counts = { 20, 400, 8902, 197281, 4865609, 119060324 },
    },
    {
        name = "kiwipete",
        fen = "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1",
        counts = { 48, 2039, 97862, 4085603, 193690690 },
    },
    {
        name = "position 3 (endgame, ep pins)",
        fen = "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1",
        counts = { 14, 191, 2812, 43238, 674624, 11030083 },
    },
    {
        name = "position 4 (promotions)",
        fen = "r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1",
        counts = { 6, 264, 9467, 422333, 15833292 },
    },
    {
        name = "position 5",
        fen = "rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8",
        counts = { 44, 1486, 62379, 2103487, 89941194 },
    },
    {
        name = "position 6",
        fen = "r4rk1/1pp1qppp/p1np1n2/2b1p1B1/2B1P1b1/P1NP1N2/1PP1QPPP/R4RK1 w - - 0 10",
        counts = { 46, 2079, 89890, 3894594, 164075551 },
    },
}

--- Verify that make/unmake restores the position exactly, including hashes.
local function checkMakeUnmakeSymmetry(b, depth)
    if depth == 0 then return true end
    local before_fen = b:getFen()
    local before_lo, before_hi = b.hash_lo, b.hash_hi
    local moves = {}
    local n = b:generatePseudoMoves(moves)
    for i = 1, n do
        local m = moves[i]
        if b:makeMove(m) then
            -- The incrementally updated hash must match a full recomputation.
            local inc_lo, inc_hi = b.hash_lo, b.hash_hi
            b:computeHash()
            if b.hash_lo ~= inc_lo or b.hash_hi ~= inc_hi then
                return false, ("incremental hash mismatch after %s in %s")
                    :format(b:moveToUci(m), before_fen)
            end
            b.hash_lo, b.hash_hi = inc_lo, inc_hi
            local ok, err = checkMakeUnmakeSymmetry(b, depth - 1)
            if not ok then return false, err end
            b:unmakeMove(m)
            if b:getFen() ~= before_fen then
                return false, ("unmake did not restore position: %s -> %s (move %s)")
                    :format(before_fen, b:getFen(), b:moveToUci(m))
            end
            if b.hash_lo ~= before_lo or b.hash_hi ~= before_hi then
                return false, ("unmake did not restore hash in %s"):format(before_fen)
            end
        end
    end
    return true
end

local budget = tonumber(arg and arg[1]) or 6.0
local failures = 0
local total_nodes, total_time = 0, 0

print("=== make/unmake symmetry ===")
for _, pos in ipairs(SUITE) do
    local b = Board.new(pos.fen)
    local ok, err = checkMakeUnmakeSymmetry(b, 3)
    if ok then
        print(("  ok    %s"):format(pos.name))
    else
        failures = failures + 1
        print(("  FAIL  %s: %s"):format(pos.name, err))
    end
end

print("\n=== perft ===")
for _, pos in ipairs(SUITE) do
    print(("%s\n  %s"):format(pos.name, pos.fen))
    local spent = 0
    for depth, expected in ipairs(pos.counts) do
        if spent > budget then
            print(("  d%d  skipped (time budget)"):format(depth))
            break
        end
        local b = Board.new(pos.fen)
        local t0 = os.clock()
        local got = perft(b, depth)
        local dt = os.clock() - t0
        spent = spent + dt
        total_nodes = total_nodes + got
        total_time = total_time + dt
        if got == expected then
            print(("  d%d  %12d  %7.2fs  %8.0f nps")
                :format(depth, got, dt, dt > 0 and got / dt or 0))
        else
            failures = failures + 1
            print(("  d%d  %12d  EXPECTED %d   *** FAIL ***"):format(depth, got, expected))
            -- Show the breakdown so the bad branch is obvious.
            local bb = Board.new(pos.fen)
            for _, entry in ipairs(divide(bb, depth)) do
                print(("        %s %d"):format(entry.uci, entry.nodes))
            end
            break
        end
    end
end

print(("\n%d nodes in %.2fs (%.0f nps)")
    :format(total_nodes, total_time, total_time > 0 and total_nodes / total_time or 0))
if failures == 0 then
    print("ALL PASS")
    os.exit(0)
else
    print(failures .. " FAILURE(S)")
    os.exit(1)
end
