--[[--
The built-in Lua engine, behind the same interface as an external one.

All this does is wrap `kobochess.search` so the widget can drive either engine
the same way: ask it to think, poll it from the UI tick, get a move back as a
UCI string. The coroutine that keeps the screen alive during a search lives
here rather than in the widget, which is where it used to be.

@module kobochess.engine_lua
--]]--

local Search = require("kobochess.search")

local LuaEngine = {}
LuaEngine.__index = LuaEngine

-- How long the search may run before handing control back to the UI. Short
-- enough that a tap feels responsive, long enough that the yield overhead
-- stays negligible.
local SEARCH_SLICE = 0.05

function LuaEngine.new(opts)
    opts = opts or {}
    local self = setmetatable({}, LuaEngine)
    self.searcher = Search.new()
    -- Check for a yield often; the check itself is cheap and it is what
    -- bounds how quickly Cancel takes effect.
    self.searcher.tick_interval = 256
    self.display_name = opts.name or "Built-in"
    self.now = opts.now or os.clock
    return self
end

function LuaEngine:name() return self.display_name end
function LuaEngine:isThinking() return self.co ~= nil end
function LuaEngine:isDead() return false end
function LuaEngine:start() return true end

function LuaEngine:close()
    self.co = nil
    self.on_done = nil
end

function LuaEngine:reset()
    self.searcher:reset()
end

--- Start a search. See engine_uci.lua for the shared contract.
function LuaEngine:think(opts)
    -- On a copy. The search explores by making and unmaking moves and yields
    -- to the UI as it goes, so searching the live board would let a repaint
    -- land on whatever hypothetical position it happened to be standing in.
    local board = opts.game.board:clone()
    local searcher = self.searcher
    local now = self.now
    local last_yield = now()
    local me = self

    self.board = board
    self.abort = false
    self.on_done = opts.on_done

    self.co = coroutine.create(function()
        return searcher:think(board, {
            level = opts.level,
            max_depth = opts.max_depth,
            max_time = opts.max_time,
            noise = opts.noise,
            now = now,
            on_tick = function()
                if me.abort then return false end
                local t = now()
                if t - last_yield >= SEARCH_SLICE then
                    coroutine.yield()
                    last_yield = now()
                end
                return true
            end,
            on_depth = function(depth, score, san)
                if opts.on_progress then opts.on_progress(depth, score, san) end
            end,
        })
    end)
    return true
end

function LuaEngine:cancel()
    self.abort = true
end

--- Resume the search for one slice, then hand control back to the UI loop.
function LuaEngine:poll()
    local co = self.co
    if not co then return "idle" end

    local ok, move, info = coroutine.resume(co)
    if not ok then
        -- `move` holds the error message when the coroutine failed.
        local on_done = self.on_done
        self.co, self.on_done = nil, nil
        if on_done then on_done(nil, nil, tostring(move)) end
        return "error"
    end

    if coroutine.status(co) ~= "dead" then return "busy" end

    local on_done = self.on_done
    self.co, self.on_done = nil, nil
    if on_done then
        -- As a UCI string, so both engines answer in the same currency and
        -- the caller re-resolves it against the live board either way.
        on_done(move and self.board:moveToUci(move) or nil, info)
    end
    return "idle"
end

return LuaEngine
