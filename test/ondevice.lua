--[[--
Run the engine on the Kobo itself, using KOReader's own LuaJIT.

Checks that move generation is correct on the device's ARM build (and not just
on the desktop), that a game can be saved and restored there, and how deep each
difficulty level actually reaches in its time budget on that CPU -- which is
the only honest way to set those budgets.

It touches nothing but the engine, so it is safe to run while KOReader is up.

Copy it over and run it:

    scp -P 2222 test/ondevice.lua root@<kobo>:/tmp/
    ssh -p 2222 root@<kobo> \
        'cd /mnt/onboard/.adds/koreader && ./luajit /tmp/ondevice.lua'

The device drops Wi-Fi when it sleeps, so for the longer runs launch it
detached and collect the output afterwards:

    ssh … '… (setsid nohup ./luajit /tmp/ondevice.lua > /tmp/ondevice.out 2>&1 &)'
    ssh … 'cat /tmp/ondevice.out'
--]]--

package.path = "/mnt/onboard/.adds/koreader/plugins/kobochess.koplugin/?.lua;"
    .. package.path

local Board = require("kobochess.board")
local Search = require("kobochess.search")
local Game = require("kobochess.game")

print("jit: " .. (jit and (jit.version .. " " .. jit.arch) or "no jit"))
print("jit enabled: " .. tostring(jit and jit.status()))

local function perft(b, depth)
    local moves = {}
    local n = b:generatePseudoMoves(moves, false)
    local nodes = 0
    for i = 1, n do
        if b:makeMove(moves[i]) then
            nodes = nodes + ((depth == 1) and 1 or perft(b, depth - 1))
            b:unmakeMove(moves[i])
        end
    end
    return nodes
end

-- Correctness on the device, not just on the machine it was written on.
local CASES = {
    { Board.START_FEN, 4, 197281 },
    { "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1", 3, 97862 },
    { "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1", 4, 43238 },
}

local ok = true
for _, case in ipairs(CASES) do
    local fen, depth, expected = case[1], case[2], case[3]
    local b = Board.new(fen)
    local t0 = os.clock()
    local got = perft(b, depth)
    local dt = os.clock() - t0
    local passed = (got == expected)
    ok = ok and passed
    print(("perft d%d: %d %s (%.2fs, %.0f nps)"):format(
        depth, got, passed and "OK" or ("WRONG, want " .. expected),
        dt, dt > 0 and got / dt or 0))
end

-- How deep does each level actually get in its time budget on this CPU?
local bench = Board.new(
    "r1bqkb1r/pppp1ppp/2n2n2/4p3/2B1P3/5N2/PPPP1PPP/RNBQK2R w KQkq - 4 4")
for _, level in ipairs({ 3, 4, 5, 6 }) do
    local searcher = Search.new()
    local t0 = os.clock()
    local move, info = searcher:think(bench, { level = level })
    local dt = os.clock() - t0
    print(("level %d (%-12s): depth %d in %.1fs, %d nodes, %.0f nps -> %s"):format(
        level, Search.LEVELS[level].name, info.depth, dt, info.nodes,
        dt > 0 and info.nodes / dt or 0, bench:moveToSan(move)))
end

-- The save/restore path, on the device's own Lua.
local game = Game.new{ level = 4 }
game:play(game.board:moveFromUci("e2e4"))
game:play(game.board:moveFromUci("e7e5"))
local restored = Game.fromTable(game:toTable())
local restored_ok = restored and restored.board:getFen() == game.board:getFen()
print("save/restore: " .. (restored_ok and "OK" or "FAILED"))

print((ok and restored_ok) and "ENGINE OK ON DEVICE" or "ENGINE FAILED ON DEVICE")
