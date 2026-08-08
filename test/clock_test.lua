--[[--
Tests for the chess clock.

The clock takes "now" as an argument rather than reading it, so time can be
made to pass on demand: every case here is exact, and the suite runs in
milliseconds instead of minutes.

    luajit test/clock_test.lua
--]]--

package.path = "kobochess.koplugin/?.lua;" .. package.path

local Board = require("kobochess.board")
local Clock = require("kobochess.clock")

local WHITE, BLACK = Board.WHITE, Board.BLACK

local failures = 0

local function check(ok, what)
    print(("  %-5s %s"):format(ok and "ok" or "FAIL", what))
    if not ok then failures = failures + 1 end
end

local function near(a, b, what, tolerance)
    check(math.abs(a - b) < (tolerance or 1e-6),
          ("%s (got %.3f, want %.3f)"):format(what, a, b))
end

print("=== counting down ===")
do
    local c = Clock.new{ base = 300, increment = 0 }
    check(not c:isRunning(), "a new clock is stopped")
    near(c:timeLeft(WHITE, 0), 300, "white starts with the full allowance")

    c:start(100)
    near(c:timeLeft(WHITE, 110), 290, "the side to move is charged for the wait")
    near(c:timeLeft(BLACK, 110), 300, "the other side is not")

    -- Reading the clock must not advance it.
    near(c:timeLeft(WHITE, 110), 290, "reading twice gives the same answer")
end

print("\n=== the move presses the clock ===")
do
    local c = Clock.new{ base = 300, increment = 0 }
    c:start(0)
    c:moved(WHITE, 10)
    check(c.side == BLACK, "the other side is now counting down")
    near(c:timeLeft(WHITE, 40), 290, "white's clock stopped when white moved")
    near(c:timeLeft(BLACK, 40), 270, "black has been charged the 30s since")

    c:moved(BLACK, 40)
    near(c:timeLeft(WHITE, 40), 290, "handing back does not disturb white")
    near(c:timeLeft(BLACK, 40), 270, "nor black")
end

print("\n=== increment ===")
do
    local c = Clock.new{ base = 60, increment = 5 }
    c:start(0)
    c:moved(WHITE, 3)
    near(c:timeLeft(WHITE, 3), 62, "white spent 3s and got 5s back")

    c:moved(BLACK, 4)
    near(c:timeLeft(BLACK, 4), 64, "black spent 1s and got 5s back")

    -- The increment must not be credited to a side that has already flagged.
    local d = Clock.new{ base = 10, increment = 5 }
    d:start(0)
    d:moved(WHITE, 30)
    near(d:timeLeft(WHITE, 30), 0, "no increment for a side that ran out")
end

print("\n=== flag fall ===")
do
    local c = Clock.new{ base = 10, increment = 0 }
    c:start(0)
    check(c:flaggedSide() == nil, "not flagged while there is time left")
    c:sync(5)
    check(c:flaggedSide() == nil, "still not flagged at 5 of 10 seconds")
    c:sync(11)
    check(c:flaggedSide() == WHITE, "flagged once the time is gone")
    check(not c:isRunning(), "a flagged clock stops")
    near(c:timeLeft(WHITE, 20), 0, "and does not go negative")
    near(c:timeLeft(BLACK, 20), 10, "the other side keeps its time")

    check(not c:start(30), "a flagged clock will not restart")
end

print("\n=== pausing ===")
do
    local c = Clock.new{ base = 300, increment = 0 }
    c:start(0)
    c:pause(10)
    near(c:timeLeft(WHITE, 600), 290, "a paused clock does not run on")
    c:start(600)
    near(c:timeLeft(WHITE, 605), 285, "and picks up where it left off")
end

print("\n=== undo moves the clock without paying anything back ===")
do
    local c = Clock.new{ base = 300, increment = 10 }
    c:start(0)
    c:moved(WHITE, 20)          -- white: 300 - 20 + 10 = 290
    c:setSide(WHITE, 25)        -- black thought for 5s, then the move was undone
    check(c.side == WHITE, "the clock points at the side to move again")
    near(c:timeLeft(WHITE, 25), 290, "white keeps what it had")
    near(c:timeLeft(BLACK, 25), 295, "black is still charged for its 5 seconds")
end

print("\n=== formatting ===")
do
    check(Clock.format(300) == "5:00", "5:00")
    check(Clock.format(299.5) == "5:00", "rounded up, so a game starts at 5:00")
    check(Clock.format(299) == "4:59", "4:59")
    check(Clock.format(59) == "0:59", "0:59")
    check(Clock.format(0) == "0:00", "0:00")
    check(Clock.format(-5) == "0:00", "never negative")
    check(Clock.format(3600) == "1:00:00", "an hour gains a field")
    check(Clock.format(3725) == "1:02:05", "1:02:05")
end

print("\n=== save and restore ===")
do
    local c = Clock.new{ base = 600, increment = 3 }
    c:start(0)
    c:moved(WHITE, 30)
    local saved = c:toTable(45)

    local d = Clock.fromTable(saved)
    check(d ~= nil, "restores")
    near(d:timeLeft(WHITE, 0), 573, "white's time survives the trip")
    near(d:timeLeft(BLACK, 0), 585, "and black's")
    check(d.side == BLACK, "so does whose turn it is")
    check(d.increment == 3, "and the increment")
    check(not d:isRunning(),
          "a restored clock is stopped, so a night in a drawer costs nothing")

    check(Clock.fromTable(nil) == nil, "rubbish in, nil out")
    check(Clock.fromTable({}) == nil, "an empty table is not a clock")
end

print("")
if failures == 0 then
    print("ALL PASS")
else
    print(("%d FAILURE(S)"):format(failures))
    os.exit(1)
end
