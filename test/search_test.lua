--[[--
Search sanity checks: tactics it must find, blunders it must not make, and a
self-play run that proves a whole game can be played without producing an
illegal move or crashing.

Run with:  luajit test/search_test.lua
--]]--

package.path = "kobochess.koplugin/?.lua;" .. package.path

local Board = require("kobochess.board")
local Search = require("kobochess.search")

local failures = 0
local function check(ok, label, detail)
    if ok then
        print(("  ok    %s"):format(label))
    else
        failures = failures + 1
        print(("  FAIL  %s%s"):format(label, detail and ("  -- " .. detail) or ""))
    end
end

--==========================================================================
-- Tactics
--==========================================================================

-- Each case lists the position and the set of acceptable moves in SAN.
local TACTICS = {
    {
        name = "back rank mate in 1",
        fen = "6k1/5ppp/8/8/8/8/8/R3K3 w Q - 0 1",
        depth = 3,
        expect = { "Ra8#" },
    },
    {
        name = "queen mate in 1",
        fen = "k7/7R/1K6/8/8/8/8/8 w - - 0 1",
        depth = 3,
        expect = { "Rh8#" },
    },
    {
        name = "smothered mate",
        -- The king is boxed in by its own rook and pawns, so Nf7 is mate.
        fen = "6rk/6pp/8/6N1/8/8/8/6K1 w - - 0 1",
        depth = 5,
        expect = { "Nf7#" },
    },
    {
        name = "wins a free queen",
        fen = "4k3/8/8/3q4/4P3/8/8/4K3 w - - 0 1",
        depth = 4,
        expect = { "exd5" },
    },
    {
        name = "must recapture, not grab a poisoned pawn",
        fen = "rnbqkbnr/ppp1pppp/8/3p4/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2",
        depth = 5,
        expect = { "exd5", "Nc3", "d4", "Nf3", "e5" },
    },
    {
        name = "avoids stalemate when winning",
        -- White is up a queen; Qg6 would be stalemate and must be rejected.
        fen = "7k/8/8/8/8/5Q2/8/6K1 w - - 0 1",
        depth = 5,
        reject = { "Qg3", "Qf7", "Qf6" },
    },
}

print("=== tactics ===")
for _, t in ipairs(TACTICS) do
    local b = Board.new(t.fen)
    local searcher = Search.new()
    local move, info = searcher:think(b, {
        max_depth = t.depth, max_time = 20, noise = 0,
    })
    if not move then
        check(false, t.name, "no move returned")
    else
        local san = b:moveToSan(move)
        if t.expect then
            local ok = false
            for _, want in ipairs(t.expect) do
                if san == want then ok = true; break end
            end
            check(ok, t.name, ("played %s, wanted one of %s (score %s, d%d)")
                :format(san, table.concat(t.expect, "/"),
                        Search.formatScore(info.score, b.side), info.depth))
        else
            local ok = true
            for _, bad in ipairs(t.reject) do
                if san == bad then ok = false; break end
            end
            check(ok, t.name, ("played %s, which is rejected"):format(san))
        end
        -- Whatever it picked must be legal in the position.
        check(b:findMove(Board.moveFrom(move), Board.moveTo(move),
                         Board.movePromo(move) ~= 0 and Board.movePromo(move) or nil) ~= nil,
              t.name .. " (move is legal)")
        -- The board must come back untouched.
        check(b:getFen() == t.fen, t.name .. " (board unchanged)",
              ("%s vs %s"):format(b:getFen(), t.fen))
    end
end

--==========================================================================
-- Self-play
--==========================================================================

print("\n=== self-play (level 3 vs level 3, max 120 moves) ===")
do
    local b = Board.new()
    local white = Search.new()
    local black = Search.new()
    local sans = {}
    local result, winner
    local illegal = false

    for _ = 1, 120 do
        result, winner = b:getGameResult()
        if result then break end
        local searcher = (b.side == Board.WHITE) and white or black
        local move = searcher:think(b, { level = 3, max_time = 2.0 })
        if not move then illegal = true; break end
        if not b:findMove(Board.moveFrom(move), Board.moveTo(move),
                          Board.movePromo(move) ~= 0 and Board.movePromo(move) or nil) then
            illegal = true
            print(("  illegal move %s in %s"):format(b:moveToUci(move), b:getFen()))
            break
        end
        sans[#sans + 1] = b:moveToSan(move)
        b:makeMove(move)
    end

    check(not illegal, "self-play produced only legal moves")
    print(("  %d plies played, result: %s%s")
        :format(#sans, result or "ongoing",
                winner and (" for " .. (winner == Board.WHITE and "White" or "Black")) or ""))
    -- Print the game so it can be eyeballed / pasted into a viewer.
    local out = {}
    for i, san in ipairs(sans) do
        if i % 2 == 1 then out[#out + 1] = tostring((i + 1) / 2) .. "." end
        out[#out + 1] = san
    end
    print("  " .. table.concat(out, " "))
end

--==========================================================================
-- Interruption
--==========================================================================

print("\n=== interruption ===")
do
    local b = Board.new()
    local searcher = Search.new()
    local ticks = 0
    local move, info = searcher:think(b, {
        max_depth = 20,
        max_time = 60,
        on_tick = function()
            ticks = ticks + 1
            -- Abort after a handful of ticks, as a "player tapped cancel".
            return ticks < 5
        end,
    })
    check(move ~= nil, "aborted search still returns a usable move")
    check(info.aborted == true, "abort is reported")
    check(b:getFen() == Board.START_FEN, "board unchanged after abort")
end

--==========================================================================
-- The search must not disturb the game board
--
-- The front end runs the search inside a coroutine that yields to the UI, so
-- anything the search does to the board can be drawn on screen mid-flight.
-- Searching the live board therefore paints hypothetical positions: pieces on
-- strange squares, captured pieces missing. The fix is to search a copy, and
-- this is the test that says so.
--==========================================================================

print("\n=== search isolation ===")
do
    local Game = require("kobochess.game")

    -- Positive control: the search really does mutate the board it is handed,
    -- so the test below is capable of failing. The depth and tick interval
    -- have to be large/small enough that on_tick actually fires -- a search
    -- that finishes inside one tick interval would prove nothing.
    local live = Board.new()
    local fen = live:getFen()
    local seen, mutated = 0, 0
    local control = Search.new()
    control.tick_interval = 256          -- what the front end uses
    control:think(live, {
        max_depth = 6, max_time = 10, noise = 0,
        on_tick = function()
            seen = seen + 1
            if live:getFen() ~= fen then mutated = mutated + 1 end
            return true
        end,
    })
    check(seen > 0, "control: the search yielded at least once")
    check(mutated == seen,
          "control: every yield exposes a mid-search position",
          ("%d of %d yields"):format(mutated, seen))
    check(live:getFen() == fen, "control: the board is restored once the search ends")

    -- The real invariant: with a clone, the game's board never moves.
    local game = Game.new{}
    game:play(game.board:moveFromUci("e2e4"))
    local before = game.board:getFen()
    local search_board = game.board:clone()
    check(search_board:getFen() == before, "clone starts from the same position")

    local disturbed = false
    local ticks = 0
    local searcher = Search.new()
    searcher.tick_interval = 256
    searcher:think(search_board, {
        max_depth = 6, max_time = 10, noise = 0,
        on_tick = function()
            ticks = ticks + 1
            if game.board:getFen() ~= before then disturbed = true end
            return true
        end,
    })
    check(ticks > 0, "the search yielded at least once (otherwise this proves nothing)")
    check(not disturbed, "the game board is untouched throughout a search on a clone")
    check(game.board:getFen() == before, "the game board is untouched after the search")

    -- The clone has to carry the game's history, or the search cannot see
    -- repetitions of positions that occurred before it started.
    local rep = Game.new{}
    for _, uci in ipairs({ "g1f3", "g8f6", "f3g1", "f6g8", "g1f3", "g8f6" }) do
        rep:play(rep.board:moveFromUci(uci))
    end
    local rep_clone = rep.board:clone()
    check(rep_clone.ply == rep.board.ply, "clone keeps the ply count")
    check(rep_clone:isRepetition(2) == rep.board:isRepetition(2),
          "clone sees the same repetitions as the original")
end

--==========================================================================
-- Speed
--==========================================================================

print("\n=== speed (fixed depth from the opening) ===")
do
    local b = Board.new("r1bqkb1r/pppp1ppp/2n2n2/4p3/2B1P3/5N2/PPPP1PPP/RNBQK2R w KQkq - 4 4")
    local searcher = Search.new()
    for _, depth in ipairs({ 4, 6, 8 }) do
        local t0 = os.clock()
        local move, info = searcher:think(b, { max_depth = depth, max_time = 120, noise = 0 })
        local dt = os.clock() - t0
        print(("  d%-2d  %-8s %9d nodes  %6.2fs  %8.0f nps  pv: %s")
            :format(depth, b:moveToSan(move), info.nodes, dt,
                    dt > 0 and info.nodes / dt or 0,
                    table.concat(info.pv, " ", 1, math.min(#info.pv, 6))))
    end
end

print("")
if failures == 0 then
    print("ALL PASS")
else
    print(failures .. " FAILURE(S)")
end
io.stdout:flush()
os.exit(failures == 0 and 0 or 1)
