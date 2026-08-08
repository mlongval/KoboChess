--[[--
A chess clock: two countdowns, one per side, only one of them running.

There is no time source in here. Every method that needs to know the time
takes it as an argument, the same way the search does, which keeps this
module testable without a device and means the UI decides what "now" means
(a monotonic clock, so that changing the device's time zone mid-game cannot
hand somebody twenty minutes).

The clock is not pressed after a move. Making the move switches it, which is
what a human would do anyway and one less thing to forget; the increment is
credited to the side that just moved, as a Fischer clock does.

@module kobochess.clock
--]]--

local Board = require("kobochess.board")

local Clock = {}
Clock.__index = Clock

--- The time controls offered, as "minutes|increment".
-- The first entry turns the clock off, so this list is also what the menu
-- shows and `1` always means "no clock".
Clock.CONTROLS = {
    { name = "Off",   base = 0,    increment = 0 },
    { name = "3|2",   base = 180,  increment = 2 },
    { name = "5|0",   base = 300,  increment = 0 },
    { name = "10|0",  base = 600,  increment = 0 },
    { name = "15|10", base = 900,  increment = 10 },
    { name = "30|0",  base = 1800, increment = 0 },
}

--- Start a clock. `base` and `increment` are in seconds.
function Clock.new(opts)
    opts = opts or {}
    local self = setmetatable({}, Clock)
    self.base = opts.base or 300
    self.increment = opts.increment or 0
    self.remaining = {
        [Board.WHITE] = opts.white or self.base,
        [Board.BLACK] = opts.black or self.base,
    }
    -- Whose clock is counting down. Kept equal to the side to move, so undo
    -- needs no special handling beyond telling the clock the side changed.
    self.side = opts.side or Board.WHITE
    self.running = false
    -- When `remaining` was last brought up to date. Nil while stopped.
    self.synced_at = nil
    self.flagged = nil          -- the side that ran out, once it has
    return self
end

--- Bring `remaining` up to date and note the time it was done.
-- Every other method goes through this, so elapsed time is only ever counted
-- once no matter how often it is called.
function Clock:sync(now)
    if not self.running or not self.synced_at then
        self.synced_at = now
        return
    end
    local elapsed = now - self.synced_at
    self.synced_at = now
    if elapsed <= 0 then return end

    local left = self.remaining[self.side] - elapsed
    if left <= 0 then
        self.remaining[self.side] = 0
        self.flagged = self.side
        self.running = false
    else
        self.remaining[self.side] = left
    end
end

--- Seconds left for a side, counting the time since the last sync.
-- Reading the clock must not change it, so this does the arithmetic without
-- writing anything back.
function Clock:timeLeft(colour, now)
    local left = self.remaining[colour]
    if self.running and colour == self.side and self.synced_at and now then
        left = left - (now - self.synced_at)
    end
    return math.max(0, left)
end

function Clock:start(now)
    if self.flagged then return false end
    self.running = true
    self.synced_at = now
    return true
end

function Clock:pause(now)
    if not self.running then return false end
    self:sync(now)
    self.running = false
    return true
end

function Clock:isRunning() return self.running end
function Clock:flaggedSide() return self.flagged end

--- `mover` has just played: credit the increment and hand over.
function Clock:moved(mover, now)
    self:sync(now)
    if self.flagged then return end
    if self.increment > 0 then
        self.remaining[mover] = self.remaining[mover] + self.increment
    end
    self.side = 1 - mover
    self.synced_at = now
end

--- Point the clock at whichever side is now to move, without crediting
--- anything. Used after an undo, where no move was completed.
function Clock:setSide(side, now)
    self:sync(now)
    self.side = side
    self.synced_at = now
end

--- "5:00", or "1:05:00" once there is an hour on the clock.
--
-- Rounded up, the way a chess clock reads: a five-minute game starts at 5:00
-- rather than 4:59, and 0:00 appears exactly when the time is gone rather
-- than half a second early.
function Clock.format(seconds)
    seconds = math.max(0, math.ceil(math.max(0, seconds) - 1e-6))
    local hours = math.floor(seconds / 3600)
    local minutes = math.floor((seconds % 3600) / 60)
    local secs = seconds % 60
    if hours > 0 then
        return ("%d:%02d:%02d"):format(hours, minutes, secs)
    end
    return ("%d:%02d"):format(minutes, secs)
end

--==========================================================================
-- Persistence
--==========================================================================

--- Serialise. The sides are named rather than indexed by colour: the colour
-- constants are 0 and 1, and a table with a zero key is the sort of thing a
-- serialiser is entitled to have opinions about.
function Clock:toTable(now)
    self:sync(now)
    return {
        version = 1,
        base = self.base,
        increment = self.increment,
        white = self.remaining[Board.WHITE],
        black = self.remaining[Board.BLACK],
        side = self.side,
        flagged = self.flagged,
    }
end

--- Rebuild from @{Clock:toTable} output. Returns nil if unusable.
--
-- A restored clock is always stopped. The alternative is charging somebody
-- for the time the device spent asleep, or worse, in a drawer.
function Clock.fromTable(data)
    if type(data) ~= "table" or type(data.base) ~= "number" then return nil end
    local self = Clock.new({
        base = data.base,
        increment = data.increment,
        white = data.white,
        black = data.black,
        side = data.side,
    })
    self.flagged = data.flagged
    return self
end

return Clock
