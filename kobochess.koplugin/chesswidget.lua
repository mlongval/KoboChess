--[[--
The full-screen Chess UI.

Two things here are worth knowing about before reading the code.

*Engine turns run in a coroutine, on a copy of the board.* KOReader's UI is
single-threaded, so a search that ran to completion inside one event handler
would freeze the screen for as long as it thought. Instead the search yields
every few milliseconds and is resumed from the UI loop, which keeps taps, the
Cancel button and the progress display alive throughout. Because it yields,
the search must never be handed the live board: it explores by making and
unmaking moves, so a repaint arriving mid-search would draw whatever
hypothetical position the engine happened to be standing in.

*Repaints are expensive on e-ink, so they are counted.* Every state change
works out which squares actually changed and refreshes only their bounding
box, and the status line is updated on a throttle rather than on every tick.

@module kobochess.chesswidget
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local Event = require("ui/event")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local time = require("ui/time")
local _ = require("gettext")

local Board = require("kobochess.board")
local BoardView = require("boardview")
local Clock = require("kobochess.clock")
local Engines = require("kobochess.engines")
local Game = require("kobochess.game")
local Search = require("kobochess.search")
local Widget = require("ui/widget/widget")

local Screen = Device.screen

-- Minimum gap between status-line updates while thinking. Each one costs a
-- full repaint, so this is deliberately slow.
local STATUS_THROTTLE = 1.5

-- How often to force a clean, flashing refresh, in moves. E-ink ghosting
-- depends on the panel, the temperature and how much of the board is moving,
-- so this is adjustable rather than a fixed guess; 0 disables it.
-- Three is what actually clears the Elipsa's panel, measured on the device.
local DEFAULT_FULL_REFRESH_EVERY = 3

-- Used when nothing is saved and when a saved set has since been removed.
local DEFAULT_PIECE_SET = "vecteezy"

local REFRESH_CHOICES = {
    { 1, "Every move" },
    { 3, "Every 3 moves" },
    { 6, "Every 6 moves" },
    { 12, "Every 12 moves" },
    { 0, "Never (manual only)" },
}

local ChessWidget = InputContainer:extend{
    game = nil,              -- a kobochess.game instance
    plugin_path = nil,       -- directory the plugin was loaded from
    settings = nil,          -- LuaSettings for persisting preferences
    on_close = nil,          -- called when the widget closes
}

local function nowSeconds()
    return time.to_s(time.now())
end

--- One player's clock, drawn the right way up for the player it belongs to.
--
-- With the device flat on the table the far player reads everything upside
-- down, so their clock is turned over exactly as their pieces are. The
-- rotated bitmap is cached and rebuilt only when the text changes, which
-- matters when the thing repaints once a second.
local ClockLine = Widget:extend{
    text = "",
    face = nil,
    width = nil,
    height = nil,
    rotated = false,
}

function ClockLine:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    self.text_widget = TextWidget:new{ text = self.text, face = self.face, bold = true }
end

--- Returns true if the text actually changed, so the caller can skip a
-- repaint when the displayed second has not moved on.
function ClockLine:setText(text)
    if text == self.text then return false end
    self.text = text
    self.text_widget:setText(text)
    self:freeCache()
    return true
end

function ClockLine:freeCache()
    if self.cached_bb then
        self.cached_bb:free()
        self.cached_bb = nil
    end
end

function ClockLine:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local size = self.text_widget:getSize()
    local ox = math.floor((self.width - size.w) / 2)
    local oy = math.floor((self.height - size.h) / 2)

    if not self.rotated then
        self.text_widget:paintTo(bb, x + ox, y + oy)
        return
    end

    if not self.cached_bb then
        local tmp = Blitbuffer.new(self.width, self.height, bb:getType())
        tmp:fill(Blitbuffer.COLOR_WHITE)
        self.text_widget:paintTo(tmp, ox, oy)
        self.cached_bb = tmp:rotatedCopy(180)
        tmp:free()
    end
    bb:blitFrom(self.cached_bb, x, y, 0, 0, self.width, self.height)
end

function ClockLine:getSize()
    return Geom:new{ w = self.width, h = self.height }
end

function ClockLine:free()
    self:freeCache()
    if self.text_widget then self.text_widget:free() end
end

--- Is a point inside a painted widget's rectangle?
-- Geom describes the rectangle; this is just the test, kept here because the
-- clock lines are the only things outside the board that need to be tapped.
local function contains(dimen, pos)
    if not dimen or not pos or not dimen.y then return false end
    return pos.x >= dimen.x and pos.x < dimen.x + dimen.w
       and pos.y >= dimen.y and pos.y < dimen.y + dimen.h
end

--- The piece sets installed under `pieces/`.
--
-- Sets are folders rather than a list in the code, so adding one is a matter
-- of dropping it in: build a set with the tools, reinstall, and it appears
-- under Options. That also lets a set built from artwork that cannot be
-- redistributed live on a device without living in the repository.
local function findPieceSets(root)
    local sets = {}
    -- lfs.dir throws if the directory is missing, and hands back an iterator
    -- plus the directory object it walks -- both are needed to drive the loop.
    local ok, iter, dir_obj = pcall(lfs.dir, root)
    if not ok then return sets end
    for entry in iter, dir_obj do
        if entry ~= "." and entry ~= ".." then
            local dir = root .. "/" .. entry
            -- One piece is enough to tell a set from a stray folder; a set
            -- missing the rest would show gaps, which is visible immediately.
            if lfs.attributes(dir, "mode") == "directory"
               and lfs.attributes(dir .. "/wk.png", "mode") == "file" then
                sets[#sets + 1] = entry
            end
        end
    end
    table.sort(sets)
    return sets
end

--- Turn a set's folder name into something to put on a menu.
local function prettySetName(name)
    local text = name:gsub("[-_]", " ")
    return (text:gsub("^%l", string.upper))
end

--- A CenterContainer that remembers where it was last painted.
--
-- CenterContainer leaves `dimen.x`/`dimen.y` at whatever they were built with,
-- which is fine for layout but useless for refreshing: asking UIManager to
-- refresh such a dimen updates a rectangle in the top-left corner of the
-- screen rather than the widget. Recording the paint position gives the
-- status and history lines a region that can actually be refreshed on its own,
-- instead of having to repaint the whole board to update one line of text.
local TrackedContainer = CenterContainer:extend{}

function TrackedContainer:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    CenterContainer.paintTo(self, bb, x, y)
end

--==========================================================================
-- Construction and layout
--==========================================================================

function ChessWidget:init()
    -- The board is laid out for portrait. If a book was being read in
    -- landscape, turn the screen upright for the game and put it back on
    -- close (see onCloseWidget); the reader underneath is covered meanwhile.
    self.saved_rotation = Screen:getRotationMode()
    if Screen:getWidth() > Screen:getHeight() then
        Screen:setRotationMode(Screen.DEVICE_ROTATED_UPRIGHT)
        self.forced_portrait = true
    end
    self.screen_w = Screen:getWidth()
    self.screen_h = Screen:getHeight()
    self.covers_fullscreen = true

    self.thinking = false
    self.abort_search = false
    self.search_kind = nil
    self.moves_since_full_refresh = 0
    self.status_line = ""
    self.hint_move = nil

    self.full_refresh_every = DEFAULT_FULL_REFRESH_EVERY
    self.show_coordinates = true
    self.time_control = 1              -- 1 is "Off"
    if self.settings then
        local saved = self.settings:readSetting("full_refresh_every")
        if type(saved) == "number" then self.full_refresh_every = saved end
        local coords = self.settings:readSetting("show_coordinates")
        if coords ~= nil then self.show_coordinates = coords end
        local control = self.settings:readSetting("time_control")
        if type(control) == "number" and Clock.CONTROLS[control] then
            self.time_control = control
        end
    end

    -- One closure each, created once: UIManager:unschedule matches on
    -- identity, so a fresh closure per tick could never be cancelled.
    self.clock_tick = function() self:onClockTick() end
    self.engine_poll = function() self:onEnginePoll() end
    self.clock = self:restoreClock()

    self.engines_root = self.plugin_path .. "/engines"
    self.engine_list = Engines.list(self.engines_root)
    self:selectEngine(self.settings and self.settings:readSetting("engine")
                      or Engines.BUILTIN, true)

    self.pieces_root = self.plugin_path .. "/pieces"
    self.piece_sets = findPieceSets(self.pieces_root)
    self.piece_set = self:chooseInitialPieceSet()

    if Device:hasKeys() then
        self.key_events = {
            Close = { { Device.input.group.Back } },
        }
    end
    self.ges_events = {
        Tap = {
            GestureRange:new{
                ges = "tap",
                range = Geom:new{ x = 0, y = 0, w = self.screen_w, h = self.screen_h },
            },
        },
    }

    self:buildLayout()
    self:syncBoardToGame()
    self:updateStatus()
end

--- The set to open with: the saved one if it is still installed, otherwise the
-- default, otherwise whatever is there.
function ChessWidget:chooseInitialPieceSet()
    local saved = self.settings and self.settings:readSetting("piece_set")
    local have = {}
    for _, name in ipairs(self.piece_sets) do have[name] = true end

    if saved and have[saved] then return saved end
    if have[DEFAULT_PIECE_SET] then return DEFAULT_PIECE_SET end
    -- Nothing recognisable: fall back to the first set found, and to the
    -- default name if there are none at all, so `piece_dir` is never nil and
    -- the board reports missing images rather than crashing.
    return self.piece_sets[1] or DEFAULT_PIECE_SET
end

function ChessWidget:pieceDir()
    return self.pieces_root .. "/" .. self.piece_set
end

--==========================================================================
-- The clock
--==========================================================================

--- A clock only makes sense with two humans. Against the engine the player
-- would be racing something whose thinking time is already fixed by the
-- level, which is a different game and not the one that was asked for.
function ChessWidget:clockEnabled()
    return self.game.two_player and self.time_control > 1
end

function ChessWidget:newClock()
    local control = Clock.CONTROLS[self.time_control]
    return Clock.new{
        base = control.base,
        increment = control.increment,
        side = self.game.board.side,
    }
end

--- The clock belonging to the saved game, or a fresh one.
function ChessWidget:restoreClock()
    if not self:clockEnabled() then return nil end
    local saved = self.settings and self.settings:readSetting("clock")
    -- Tied to the game it was timing: a clock left over from a previous game
    -- would otherwise hand somebody a half-used allowance.
    if type(saved) == "table" and saved.game_started_at == self.game.started_at then
        local clock = Clock.fromTable(saved)
        if clock then return clock end
    end
    return self:newClock()
end

function ChessWidget:scheduleClockTick()
    if not (self.clock and self.clock:isRunning()) then return end
    UIManager:unschedule(self.clock_tick)
    UIManager:scheduleIn(1, self.clock_tick)
end

function ChessWidget:stopClockTick()
    UIManager:unschedule(self.clock_tick)
end

--- Once a second while the clock runs. Only the side that is counting down
-- can have changed, and the text is compared before anything is repainted,
-- so an idle second costs nothing on the panel.
function ChessWidget:onClockTick()
    if not (self.clock and self.clock:isRunning()) then return end
    local now = nowSeconds()
    self.clock:sync(now)

    local flagged = self.clock:flaggedSide()
    if flagged then
        self:onFlagFall(flagged)
        return
    end

    if self:updateClockText() then self:refreshClocks() end
    self:scheduleClockTick()
end

function ChessWidget:clockText(colour, now)
    local name = (colour == Board.WHITE) and _("White") or _("Black")
    local marker = ""
    if self.clock:flaggedSide() == colour then
        marker = "  ✕"
    elseif self.clock.side == colour then
        marker = self.clock:isRunning() and "  ▶" or "  ‖"
    end
    return ("%s   %s%s"):format(name, Clock.format(self.clock:timeLeft(colour, now)),
                                marker)
end

--- Returns true if either line's text changed.
function ChessWidget:updateClockText()
    if not (self.clock and self.clock_far and self.clock_near) then return false end
    local now = nowSeconds()
    local far = self.board_view:farColour()
    -- Two calls, not one `or`: setText must run on both lines, and `or` would
    -- skip the second as soon as the first returned true.
    local far_changed = self.clock_far:setText(self:clockText(far, now))
    local near_changed = self.clock_near:setText(self:clockText(1 - far, now))
    return far_changed or near_changed
end

function ChessWidget:refreshClocks()
    for _, line in ipairs({ self.clock_far, self.clock_near }) do
        if line and line.dimen and line.dimen.y then
            -- "ui", never "partial": this fires every second, and a mode that
            -- counts towards the automatic flashing refresh would have the
            -- screen blinking its way through the game.
            self:refreshRegion(line.dimen:copy(), "ui")
        end
    end
end

--- Start or stop the clock by hand, for an interruption.
function ChessWidget:onToggleClock()
    if not self.clock or self.clock:flaggedSide() or self.game:isOver() then
        return true
    end
    local now = nowSeconds()
    if self.clock:isRunning() then
        self.clock:pause(now)
        self:stopClockTick()
    else
        self.clock:start(now)
        self:scheduleClockTick()
    end
    self:updateClockText()
    self:refreshClocks()
    self:saveGame()
    return true
end

--- Hand the clock over after a move, starting it if this was the first one.
function ChessWidget:clockAfterMove(mover)
    if not self.clock or self.clock:flaggedSide() then return end
    local now = nowSeconds()
    -- The clock is not running before the first move: whoever opens has been
    -- setting up, not thinking on their time.
    if not self.clock:isRunning() then self.clock:start(now) end
    self.clock:moved(mover, now)
    self:updateClockText()
    self:scheduleClockTick()
end

function ChessWidget:onFlagFall(loser)
    self:stopClockTick()
    self.game:loseOnTime(loser)
    self:updateClockText()
    self:updateStatus()
    self:refreshAll("partial")
    self:announceResult()
    self:saveGame()
end

--- Build the widget tree. The board is sized from whatever vertical space is
-- left once the fixed chrome has been measured, so the layout adapts to the
-- screen rather than assuming the Elipsa's dimensions.
function ChessWidget:buildLayout()
    local margin = Size.padding.large

    self.title_bar = TitleBar:new{
        width = self.screen_w,
        fullscreen = true,
        align = "center",
        title = _("Chess"),
        with_bottom_line = true,
        close_callback = function() self:onClose() end,
        show_parent = self,
    }

    self.status_widget = TextWidget:new{
        text = "",
        face = Font:getFace("cfont", 20),
        bold = true,
        max_width = self.screen_w - 2 * margin,
    }
    self.history_widget = TextWidget:new{
        text = "",
        face = Font:getFace("smallinfofont", 17),
        max_width = self.screen_w - 2 * margin,
    }

    -- One row, and everything that is not needed mid-game is behind the two
    -- menus at either end. Every button taken off the row is a button's worth
    -- of height given back to the board, which is the thing worth looking at.
    self.buttons = {}
    local row = self:buildButtonRow({
        { id = "game",  text = _("Game ▾"), callback = function() self:onGameMenu() end },
        { id = "undo",  text = _("Undo"),   callback = function() self:onUndo() end },
        { id = "hint",  text = _("Hint"),   callback = function() self:onHint() end },
        { id = "flip",  text = _("Flip"),   callback = function() self:onFlip() end },
        -- Tap to clear ghosting now, hold to change how often it happens by
        -- itself. Ghosting is the one thing about an e-ink board that a user
        -- can see and the program cannot, so it needs a manual override, and
        -- it stays on the row rather than in a menu because it is the one
        -- thing you reach for while looking at a smeared board.
        { id = "refresh", text = _("Refresh"),
          callback = function() self:onForceRefresh() end,
          hold_callback = function() self:onChooseRefreshInterval() end },
        { id = "options", text = _("Options ▾"), callback = function() self:onOptionsMenu() end },
    }, margin)

    -- The clocks, one at each end of the board, present only when there is a
    -- clock to show: a game with no time control should not pay for it in
    -- board size.
    local clock_h = 0
    if self.clock then
        local face = Font:getFace("cfont", 30)
        clock_h = TextWidget:new{ text = "0:00", face = face, bold = true }
            :getSize().h + Size.padding.default
        self.clock_far = ClockLine:new{
            face = face, width = self.screen_w, height = clock_h,
            -- Upside down, like the far player's pieces.
            rotated = true,
        }
        self.clock_near = ClockLine:new{
            face = face, width = self.screen_w, height = clock_h,
        }
    end

    -- Measure the chrome so the board can claim the rest.
    local span = Size.padding.default
    local fixed_h = self.title_bar:getHeight()
        + self.status_widget:getSize().h
        + self.history_widget:getSize().h
        + row:getSize().h
        + span * 5
        + (self.clock and (clock_h * 2 + span * 2) or 0)

    local avail_h = self.screen_h - fixed_h
    local board_size = math.min(self.screen_w - 2 * margin, avail_h)
    board_size = math.max(64, math.floor(board_size / 8) * 8)

    -- Orientation follows the player's colour unless they have flipped the
    -- board by hand, in which case their choice is remembered.
    local flipped = (self.game.player_colour == Board.BLACK)
    if self.settings then
        local saved = self.settings:readSetting("flipped")
        if saved ~= nil then flipped = saved end
    end

    self.board_view = BoardView:new{
        board = self.game.board,
        size = board_size,
        flipped = flipped,
        -- With two humans across a table, the far player's pieces are drawn
        -- upside down so they read correctly from that side.
        rotate_far_side = self.game.two_player,
        piece_dir = self:pieceDir(),
        show_coordinates = self.show_coordinates,
    }

    -- Fixed-size containers keep the layout from reflowing when the text
    -- inside them changes length, which would otherwise shift the board.
    self.status_container = TrackedContainer:new{
        dimen = Geom:new{ w = self.screen_w, h = self.status_widget:getSize().h },
        self.status_widget,
    }
    self.history_container = TrackedContainer:new{
        dimen = Geom:new{ w = self.screen_w, h = self.history_widget:getSize().h },
        self.history_widget,
    }

    local content = VerticalGroup:new{
        align = "center",
        self.title_bar,
        VerticalSpan:new{ width = span },
        self.status_container,
        VerticalSpan:new{ width = span },
    }
    if self.clock then
        table.insert(content, self.clock_far)
        table.insert(content, VerticalSpan:new{ width = span })
    end
    table.insert(content, CenterContainer:new{
        dimen = Geom:new{ w = self.screen_w, h = board_size },
        self.board_view,
    })
    table.insert(content, VerticalSpan:new{ width = span })
    if self.clock then
        table.insert(content, self.clock_near)
        table.insert(content, VerticalSpan:new{ width = span })
    end
    table.insert(content, self.history_container)
    table.insert(content, VerticalSpan:new{ width = span })
    table.insert(content, row)

    self[1] = FrameContainer:new{
        width = self.screen_w,
        height = self.screen_h,
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = 0,
        margin = 0,
        content,
    }
    self.dimen = Geom:new{ x = 0, y = 0, w = self.screen_w, h = self.screen_h }
end

--- Throw the widget tree away and build it again.
--
-- Needed when the layout changes shape rather than just its contents: turning
-- the clock on adds two rows and takes the height out of the board, and a new
-- game can change which side is at the top. Rebuilding is cheap enough at
-- these moments -- all of them already warrant a full refresh.
function ChessWidget:rebuildLayout()
    self:stopClockTick()
    if self.board_view then self.board_view:onCloseWidget() end
    if self.status_widget then self.status_widget:free() end
    if self.history_widget then self.history_widget:free() end
    if self.clock_far then self.clock_far:free() end
    if self.clock_near then self.clock_near:free() end
    if self.forced_portrait then
        -- Asking, rather than setting the screen directly, lets whatever is
        -- underneath (reader or file browser) re-lay itself out for the
        -- orientation it had before. After this close completes, so that
        -- the repaint it triggers is not painted over by our own.
        local mode = self.saved_rotation
        UIManager:nextTick(function()
            UIManager:broadcastEvent(Event:new("SetRotationMode", mode))
        end)
    end
    self.clock_far, self.clock_near = nil, nil

    self:buildLayout()
    self:syncBoardToGame()
    self:updateStatus()
    if self.clock then
        self:updateClockText()
        self:scheduleClockTick()
    end
    self:refreshAll("full")
end

function ChessWidget:buildButtonRow(specs, margin)
    local gap = Size.padding.default
    local total_gap = gap * (#specs - 1)
    local width = math.floor((self.screen_w - 2 * margin - total_gap) / #specs)

    local group = HorizontalGroup:new{ align = "center" }
    for i, spec in ipairs(specs) do
        -- Deliberately no `radius`. Button uses the literal value
        -- Size.radius.button as a sentinel meaning "I added this rounding for
        -- the tap highlight, take it off again": setting it ourselves makes
        -- the highlight and unhighlight take mismatched branches, which
        -- permanently squares the corners and leaves the label inverted to
        -- white-on-white -- the button looks like it has vanished. Leaving it
        -- nil is what Button expects, and it still rounds the highlight.
        local button = Button:new{
            text = spec.text,
            width = width,
            callback = spec.callback,
            hold_callback = spec.hold_callback,
            show_parent = self,
        }
        self.buttons[spec.id] = button
        table.insert(group, button)
        if i < #specs then
            table.insert(group, HorizontalSpan:new{ width = gap })
        end
    end
    return group
end

--==========================================================================
-- Refreshing
--==========================================================================

--- Refresh the smallest rectangle covering the given 0x88 squares.
--
-- Callers pick the mode by what changed, and the distinction matters on
-- e-ink. A piece appearing or vanishing is a big black-to-white swing that
-- leaves a ghost behind, so those use "partial", which counts towards
-- UIManager's automatic flashing refresh and therefore cleans up after
-- itself. Selection frames and move dots use "ui", which stays crisp and
-- never flashes -- the right trade for something that changes on every tap.
function ChessWidget:refreshSquares(squares, mode)
    if not squares or #squares == 0 then return end
    local region
    for _, sq in ipairs(squares) do
        if sq then
            local rect = self.board_view:squareRect(sq)
            region = region and region:combine(rect) or rect
        end
    end
    if not region then return end
    UIManager:setDirty(self, mode or "ui", region)
end

function ChessWidget:refreshRegion(region, mode)
    if not region then return end
    UIManager:setDirty(self, mode or "ui", region)
end

function ChessWidget:refreshAll(mode)
    UIManager:setDirty(self, mode or "partial")
end

--==========================================================================
-- Status line
--==========================================================================

function ChessWidget:updateStatus(text)
    local status
    if text then
        status = text
    elseif self.game:isOver() then
        status = self.game:resultText()
    elseif self.thinking then
        status = _("Thinking…")
    else
        local to_move = (self.game.board.side == Board.WHITE) and _("White") or _("Black")
        local mode
        if self.game.two_player then
            mode = _("Two players")
        else
            local level = Search.LEVELS[self.game.level]
            mode = level and level.name or "?"
        end
        status = ("%s to move  ·  %s"):format(to_move, mode)
        if self.game.board:inCheck() then
            status = status .. "  ·  " .. _("Check!")
        end
    end

    self.status_line = status
    self.status_widget:setText(status)
    self.history_widget:setText(self.game:historyText(6))

    -- Enable only what makes sense right now. The two menus stay live: what
    -- they hold that would be wrong mid-search is greyed out inside them,
    -- which says why, where disabling the whole menu would not.
    -- Undo stays out once somebody has flagged: the clock cannot give the
    -- time back, so taking the move back would just hand a lost game to a
    -- side with nothing left to think with.
    local flagged = self.clock and self.clock:flaggedSide()
    self.buttons.undo:enableDisable(not self.thinking and self.game:canUndo()
                                    and not flagged)
    self.buttons.hint:enableDisable(not self.thinking and self.game:isPlayerTurn())
end

--- Refresh everything except the board: the status line above it, and the
-- history line and buttons below it.
--
-- Two separate refreshes rather than one combined region: the status line sits
-- above the board and the rest below it, so a single rectangle covering both
-- would drag the whole board along with it.
function ChessWidget:refreshStatus()
    -- Copied rather than passed by reference: the containers rewrite their
    -- dimen on every paint, and UIManager holds the region until it refreshes.
    self:refreshRegion(self.status_container.dimen:copy(), "ui")

    -- The buttons are repainted too, because enabling or disabling one (Undo
    -- and Hint come and go with the state of the game) changes how it looks.
    local history_y = self.history_container.dimen.y
    if history_y and history_y > 0 then
        self:refreshRegion(Geom:new{
            x = 0,
            y = history_y,
            w = self.screen_w,
            h = self.screen_h - history_y,
        }, "ui")
    end
end

--==========================================================================
-- Board <-> game synchronisation
--==========================================================================

function ChessWidget:syncBoardToGame()
    self.board_view.board = self.game.board
    self.board_view:setLastMove(self.game:lastMove())
    self.board_view:setSelected(nil)
end

--==========================================================================
-- Input
--==========================================================================

function ChessWidget:onTap(_, ges)
    -- Either clock is a pause button, reachable from whichever side of the
    -- table you are sitting on.
    if self.clock and ges.pos
       and (contains(self.clock_far and self.clock_far.dimen, ges.pos)
            or contains(self.clock_near and self.clock_near.dimen, ges.pos)) then
        return self:onToggleClock()
    end

    -- Buttons and the title bar are children, so they have already had their
    -- chance at this event; anything arriving here is aimed at the board.
    local board_dimen = self.board_view.dimen
    if not board_dimen or not ges.pos then return true end

    local x = ges.pos.x - board_dimen.x
    local y = ges.pos.y - board_dimen.y
    local sq = self.board_view:squareAt(x, y)
    if not sq then return true end

    self:handleBoardTap(sq)
    return true
end

function ChessWidget:handleBoardTap(sq)
    if self.thinking then
        -- Tapping the board while the engine thinks means "stop waiting".
        return
    end
    if self.game:isOver() then
        return
    end
    if not self.game:isPlayerTurn() then
        return
    end

    -- Clear any hint the moment the player acts on their own.
    if self.hint_move then
        self.hint_move = nil
    end

    local selected = self.board_view.selected

    if selected and self.board_view.targets[sq] then
        self:attemptMove(selected, sq)
        return
    end

    local piece = self.game.board.sq[sq]
    if piece ~= Board.EMPTY
       and math.floor(piece / 8) == self.game.board.side then
        -- Picking up one of our own pieces, or putting it back down.
        local changed = self.board_view:setSelected((selected == sq) and nil or sq)
        self:refreshSquares(changed, "ui")
    elseif selected then
        -- Tapping anywhere else cancels the selection.
        local changed = self.board_view:setSelected(nil)
        self:refreshSquares(changed, "ui")
    end
end

--- Play the player's move, asking which piece to promote to if needed.
function ChessWidget:attemptMove(from, to)
    local board = self.game.board
    local promo_moves = {}
    local moves = {}
    local n = board:generateMoves(moves)
    for i = 1, n do
        local m = moves[i]
        if Board.moveFrom(m) == from and Board.moveTo(m) == to
           and Board.movePromo(m) ~= 0 then
            promo_moves[#promo_moves + 1] = m
        end
    end

    if #promo_moves > 0 then
        self:askPromotion(from, to)
        return
    end

    local move = board:findMove(from, to)
    if move then self:commitPlayerMove(move) end
end

function ChessWidget:askPromotion(from, to)
    local choices = {
        { Board.QUEEN, _("Queen") },
        { Board.ROOK, _("Rook") },
        { Board.BISHOP, _("Bishop") },
        { Board.KNIGHT, _("Knight") },
    }
    local buttons = {}
    for _idx, choice in ipairs(choices) do
        local ptype, label = choice[1], choice[2]
        buttons[#buttons + 1] = { {
            text = label,
            callback = function()
                UIManager:close(self.promo_dialog)
                self.promo_dialog = nil
                local move = self.game.board:findMove(from, to, ptype)
                if move then self:commitPlayerMove(move) end
            end,
        } }
    end
    self.promo_dialog = ButtonDialog:new{
        title = _("Promote to"),
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(self.promo_dialog)
end

function ChessWidget:commitPlayerMove(move)
    -- Squares that need repainting: the selection and its target dots, plus
    -- the previous move's highlight, plus the move itself.
    local changed = self.board_view:setSelected(nil)
    for _, sq in ipairs({ self.board_view.last_from, self.board_view.last_to,
                          self.board_view.check_square }) do
        changed[#changed + 1] = sq
    end

    local mover = self.game.board.side
    if not self.game:play(move) then
        logger.warn("KoboChess: refused to play an illegal move")
        return
    end
    -- Making the move presses the clock; there is no button to forget.
    self:clockAfterMove(mover)

    -- Castling and en passant move a second piece, so repaint the whole rank
    -- rather than trying to enumerate the extra squares.
    for _, sq in ipairs(self.board_view:setLastMove(move)) do
        changed[#changed + 1] = sq
    end
    local flags = Board.moveFlags(move)
    if flags == Board.FLAG_CASTLE or flags == Board.FLAG_EP then
        changed = nil       -- fall back to a full refresh
    end

    self:afterMove(changed)

    if self.game:isEngineTurn() then
        self:startEngineTurn()
    end
end

--- Common bookkeeping after any move by either side.
function ChessWidget:afterMove(changed_squares)
    -- A finished game stops the clock: mate is mate, whatever the flag does
    -- a moment later.
    if self.clock and self.game:isOver() then
        self.clock:pause(nowSeconds())
        self:stopClockTick()
        self:updateClockText()
    end
    self:updateStatus()
    self.moves_since_full_refresh = self.moves_since_full_refresh + 1

    local due = self.full_refresh_every > 0
        and self.moves_since_full_refresh >= self.full_refresh_every
    if not changed_squares or due then
        self.moves_since_full_refresh = 0
        -- A scheduled clean-up flashes; a whole-board repaint for some other
        -- reason (castling, say) does not need to.
        self:refreshAll(due and "full" or "partial")
    else
        -- A move, so pieces have appeared and disappeared: "partial", which
        -- self-heals the ghosting they leave behind.
        self:refreshSquares(changed_squares, "partial")
        self:refreshStatus()
    end

    if self.game:isOver() then
        self:announceResult()
    end
    self:saveGame()
end

function ChessWidget:announceResult()
    UIManager:show(InfoMessage:new{
        text = self.game:resultText(),
        timeout = 5,
    })
end

--==========================================================================
-- Engine turn
--==========================================================================

--- Ask the current engine for a move.
--
-- Both engines are driven the same way: start a search, then poll from the UI
-- loop until it answers. The built-in engine does its thinking inside poll(),
-- resuming a coroutine for a slice at a time; an external engine does its
-- thinking in another process and poll() only drains its pipe. Either way the
-- screen and the buttons stay alive throughout.
function ChessWidget:startEngineTurn()
    if self.thinking then return end
    self.thinking = true
    self.abort_search = false
    self.search_kind = "move"
    self.search_started = nowSeconds()
    self.last_status_update = 0
    self:updateStatus()
    self:refreshStatus()

    local ok, err = self.engine:think{
        game = self.game,
        level = self.game.level,
        on_progress = function(depth, score, move_text)
            self:onSearchProgress(depth, score, move_text)
        end,
        on_done = function(uci, info, failure)
            self:finishEngineTurn(uci, info, failure)
        end,
    }
    if not ok then
        self.thinking = false
        self:onEngineFailure(err)
        return
    end
    self:schedulePoll()
end

function ChessWidget:schedulePoll()
    local interval = self.engine.poll_interval
    if interval and interval > 0 then
        UIManager:scheduleIn(interval, self.engine_poll)
    else
        UIManager:nextTick(self.engine_poll)
    end
end

function ChessWidget:stopPolling()
    UIManager:unschedule(self.engine_poll)
end

function ChessWidget:onEnginePoll()
    if not self.thinking then return end
    local status = self.engine:poll()
    -- "idle" and "error" both mean the engine has already called back, so
    -- there is nothing left to wait for.
    if status == "busy" then self:schedulePoll() end
end

--- Whatever went wrong, the game has to stay playable, so fall back to the
--- engine that cannot fail to start.
function ChessWidget:onEngineFailure(err)
    logger.err("KoboChess: engine failed:", tostring(err))
    self:stopPolling()
    self.thinking = false

    local name = self.engine:name()
    local was_external = (self.engine_descriptor.kind ~= "lua")
    if was_external then
        self:selectEngine(Engines.BUILTIN)
        UIManager:show(InfoMessage:new{
            text = ("%s\n\n%s\n\n%s"):format(
                ("%s could not be started."):format(name),
                tostring(err or "no reason given"),
                _("Switched back to the built-in engine.")),
        })
        -- The move that was being searched for still has to be played, or
        -- the game sits there with the engine to move and nothing to move
        -- it. Only ever retried after a switch, so an engine that fails on
        -- its own behalf cannot loop.
        if self.game:isEngineTurn() then
            UIManager:nextTick(function() self:startEngineTurn() end)
            return
        end
    end
    self:updateStatus()
    self:refreshStatus()
end

function ChessWidget:onSearchProgress(depth, score, move_text)
    if not self.thinking then return end
    local now = nowSeconds()
    if now - self.last_status_update < STATUS_THROTTLE then return end
    self.last_status_update = now

    local text = ("%s  depth %d"):format(_("Thinking…"), depth)
    if score then
        text = text .. "  " .. Search.formatScore(score, self.game.board.side)
    end
    if move_text then
        -- The built-in engine reports its move in algebraic already; an
        -- external one gives UCI, which is worth translating rather than
        -- showing "e2e4" next to a board full of pieces.
        text = text .. "  " .. (self:sanFor(move_text) or move_text)
    end
    self.status_widget:setText(text)
    self:refreshStatus()
end

--- Render a UCI move as algebraic, if that is what it is.
function ChessWidget:sanFor(text)
    if not text:match("^%a%d%a%d%a?$") then return nil end
    local move = self.game.board:moveFromUci(text)
    return move and self.game.board:moveToSan(move) or nil
end

function ChessWidget:finishEngineTurn(uci, info, failure)
    self:stopPolling()
    self.thinking = false
    self.search_kind = nil

    if failure then
        self:onEngineFailure(failure)
        return
    end
    if self.abort_search then
        -- The player cancelled; leave the position alone.
        self:updateStatus()
        self:refreshStatus()
        return
    end
    if not uci then
        -- No legal move means the game is already over; let the result stand.
        self.game:updateResult()
        self:updateStatus()
        self:refreshAll("partial")
        if self.game:isOver() then self:announceResult() end
        return
    end

    if info then
        logger.dbg(("KoboChess: depth %d, %d nodes")
            :format(info.depth or 0, info.nodes or 0))
    end

    -- Re-resolved against the live board rather than trusted: the move was
    -- chosen elsewhere -- in a clone, or in another process entirely -- and
    -- playing something illegal here would corrupt the game.
    local move = self.game.board:moveFromUci(uci)
    if not move then
        logger.err("KoboChess: engine move is not legal in the live position:", uci)
        self:updateStatus(_("Engine error — your move"))
        self:refreshStatus()
        return
    end

    local changed = {}
    for _, sq in ipairs({ self.board_view.last_from, self.board_view.last_to,
                          self.board_view.check_square }) do
        changed[#changed + 1] = sq
    end

    self.game:play(move)

    for _, sq in ipairs(self.board_view:setLastMove(move)) do
        changed[#changed + 1] = sq
    end
    changed[#changed + 1] = Board.moveFrom(move)
    changed[#changed + 1] = Board.moveTo(move)

    local flags = Board.moveFlags(move)
    if flags == Board.FLAG_CASTLE or flags == Board.FLAG_EP then
        changed = nil
    end

    self:afterMove(changed)
end

--- Stop a search in progress, if any. Returns true if one was running.
function ChessWidget:cancelSearch()
    if not self.thinking then return false end
    self.abort_search = true
    self.engine:cancel()
    return true
end

--==========================================================================
-- Choosing an engine
--==========================================================================

--- Switch to the engine with this id, closing whatever was running.
-- `initial` suppresses saving, for the one built during construction.
function ChessWidget:selectEngine(id, initial)
    local descriptor = Engines.find(self.engine_list, id)
    if self.engine then self.engine:close() end

    self.engine_descriptor = descriptor
    self.engine = Engines.create(descriptor, { now = nowSeconds })

    if not initial and self.settings then
        self.settings:saveSetting("engine", descriptor.id)
        self.settings:flush()
    end
end

--==========================================================================
-- Buttons
--==========================================================================

--- Show a one-item-per-row dialog. The dialog is a local rather than a field
-- on the widget, so a callback always closes the dialog it belongs to even if
-- another has been opened since.
function ChessWidget:showMenu(title, entries)
    local dialog
    local buttons = {}
    for _, entry in ipairs(entries) do
        buttons[#buttons + 1] = { {
            text = entry.text,
            enabled = entry.enabled ~= false,
            callback = function()
                UIManager:close(dialog)
                entry.callback()
            end,
        } }
    end
    dialog = ButtonDialog:new{
        title = title,
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(dialog)
    return true
end

--- Everything to do with the game being played.
function ChessWidget:onGameMenu()
    local clock_text = self.clock and self.clock:isRunning()
        and _("Pause clock") or _("Start clock")
    return self:showMenu(_("Game"), {
        { text = _("New game"), enabled = not self.thinking,
          callback = function() self:onNewGame() end },
        { text = clock_text,
          -- Tapping either clock does this too; it is here to be findable.
          enabled = self.clock ~= nil and not self.clock:flaggedSide()
                    and not self.game:isOver(),
          callback = function() self:onToggleClock() end },
        { text = _("Resign"), enabled = not self.game:isOver(),
          callback = function() self:onResign() end },
        { text = _("Export PGN"),
          callback = function() self:onExportPgn() end },
        { text = _("Copy FEN"),
          callback = function() self:onCopyFen() end },
    })
end

--- Everything to do with how the game looks and plays.
function ChessWidget:onOptionsMenu()
    local level = Search.LEVELS[self.game.level]
    return self:showMenu(_("Options"), {
        { text = ("%s: %s"):format(_("Piece set"), prettySetName(self.piece_set)),
          enabled = #self.piece_sets > 1,
          callback = function() self:onChoosePieceSet() end },
        { text = ("%s: %s"):format(_("Engine"), self.engine:name()),
          enabled = not self.thinking and #self.engine_list > 1,
          callback = function() self:onChooseEngine() end },
        { text = ("%s: %s"):format(_("Level"), level and level.name or "?"),
          enabled = not self.thinking,
          callback = function() self:onChooseLevel() end },
        { text = ("%s: %s"):format(_("Clock"),
                                   Clock.CONTROLS[self.time_control].name),
          callback = function() self:onChooseTimeControl() end },
        { text = _("Screen refresh"),
          callback = function() self:onChooseRefreshInterval() end },
        { text = self.show_coordinates and _("Hide coordinates")
                                        or _("Show coordinates"),
          callback = function() self:onToggleCoordinates() end },
    })
end

function ChessWidget:onNewGame()
    if self.thinking then return true end
    local function start(colour, two_player)
        self.game = Game.new{
            player_colour = colour,
            two_player = two_player,
            level = self.game.level,
        }
        if self.engine.reset then self.engine:reset() end
        -- A two-player game is viewed from White's side by default; the
        -- players can turn it round with Flip. Saved before the rebuild,
        -- because that is where the layout reads it back from.
        local flipped = (not two_player) and (colour == Board.BLACK) or false
        if self.settings then
            self.settings:saveSetting("flipped", flipped)
            self.settings:flush()
        end
        self.clock = self:clockEnabled() and self:newClock() or nil
        self.moves_since_full_refresh = 0
        self.hint_move = nil
        -- Rebuilt rather than adjusted in place: the clock may have just
        -- appeared or gone, which changes how much height the board gets.
        -- It ends in a full refresh, which a new game wants anyway.
        self:rebuildLayout()
        self:saveGame()
        if self.game:isEngineTurn() then
            self:startEngineTurn()
        end
    end

    return self:showMenu(_("New game"), {
        { text = _("Play as White"),
          callback = function() start(Board.WHITE, false) end },
        { text = _("Play as Black"),
          callback = function() start(Board.BLACK, false) end },
        { text = _("Two players (no engine)"),
          callback = function() start(Board.WHITE, true) end },
    })
end

function ChessWidget:onUndo()
    if self.thinking then return true end
    if not self.game:undoMove() then return true end
    self.hint_move = nil
    -- The clock follows the side to move but gives nothing back: time spent
    -- is spent, and an undo that refunded it would be a way to play for free.
    if self.clock then
        self.clock:setSide(self.game.board.side, nowSeconds())
        self:updateClockText()
    end
    self:syncBoardToGame()
    self:updateStatus()
    self:refreshAll("partial")
    self:saveGame()
    return true
end

function ChessWidget:onFlip()
    self.board_view.flipped = not self.board_view.flipped
    -- Flipping swaps which player is on the far side, so the upside-down
    -- copies cached for the old far side are no longer the ones we want.
    self.board_view:freeRotatedWidgets()
    if self.settings then
        self.settings:saveSetting("flipped", self.board_view.flipped)
        self.settings:flush()
    end
    self:refreshAll("partial")
    return true
end

--- Wipe the screen clean, for when ghosting has built up.
function ChessWidget:onForceRefresh()
    self.moves_since_full_refresh = 0
    self:refreshAll("full")
    return true
end

--- Choose how often the board cleans itself up.
function ChessWidget:onChooseRefreshInterval()
    local entries = {}
    for _idx, choice in ipairs(REFRESH_CHOICES) do
        local every, label = choice[1], choice[2]
        local marker = (every == self.full_refresh_every) and "  ✓" or ""
        entries[#entries + 1] = {
            text = label .. marker,
            callback = function()
                self.full_refresh_every = every
                self.moves_since_full_refresh = 0
                if self.settings then
                    self.settings:saveSetting("full_refresh_every", every)
                    self.settings:flush()
                end
                self:onForceRefresh()
            end,
        }
    end
    return self:showMenu(_("Clear the screen automatically"), entries)
end

--- Switch to another set of piece images.
function ChessWidget:onChoosePieceSet()
    local entries = {}
    for _, name in ipairs(self.piece_sets) do
        local marker = (name == self.piece_set) and "  ✓" or ""
        entries[#entries + 1] = {
            text = prettySetName(name) .. marker,
            callback = function()
                if name == self.piece_set then return end
                self.piece_set = name
                self.board_view:setPieceDir(self:pieceDir())
                if self.settings then
                    self.settings:saveSetting("piece_set", name)
                    self.settings:flush()
                end
                -- Every piece on the board has just changed shape, which is
                -- exactly the kind of large swing that leaves the old set
                -- ghosting behind it: flash it clean.
                self:refreshAll("full")
            end,
        }
    end
    return self:showMenu(_("Piece set"), entries)
end

--- Choose which engine plays.
function ChessWidget:onChooseEngine()
    if self.thinking then return true end
    local entries = {}
    for _, descriptor in ipairs(self.engine_list) do
        local marker = (descriptor.id == self.engine_descriptor.id) and "  ✓" or ""
        entries[#entries + 1] = {
            text = descriptor.name .. marker,
            callback = function()
                if descriptor.id == self.engine_descriptor.id then return end
                self:selectEngine(descriptor.id)
                self:updateStatus()
                self:refreshStatus()
            end,
        }
    end
    return self:showMenu(_("Engine"), entries)
end

--- Choose the time control, which also resets the clock.
function ChessWidget:onChooseTimeControl()
    local entries = {}
    for i, control in ipairs(Clock.CONTROLS) do
        local marker = (i == self.time_control) and "  ✓" or ""
        local label = control.name
        if control.increment > 0 then
            label = ("%s  (%d min + %ds)"):format(control.name,
                                                  control.base / 60,
                                                  control.increment)
        elseif control.base > 0 then
            label = ("%s  (%d min)"):format(control.name, control.base / 60)
        end
        entries[#entries + 1] = {
            text = label .. marker,
            callback = function()
                if i == self.time_control then return end
                self.time_control = i
                if self.settings then
                    self.settings:saveSetting("time_control", i)
                    self.settings:flush()
                end
                -- Changing the control starts the allowance over: carrying
                -- times across from a different one would be meaningless.
                self.clock = self:clockEnabled() and self:newClock() or nil
                self:saveGame()
                -- The clock coming or going changes the layout's shape.
                self:rebuildLayout()
            end,
        }
    end

    local title = _("Clock")
    if not self.game.two_player then
        -- Setting it is still allowed -- it takes effect for the next
        -- two-player game -- but say why nothing happened.
        title = _("Clock (two-player games only)")
    end
    return self:showMenu(title, entries)
end

--- Show or hide the file letters and rank numbers.
function ChessWidget:onToggleCoordinates()
    self.show_coordinates = not self.show_coordinates
    self.board_view:setShowCoordinates(self.show_coordinates)
    if self.settings then
        self.settings:saveSetting("show_coordinates", self.show_coordinates)
        self.settings:flush()
    end
    self:refreshAll("partial")
    return true
end

--- Put the position on the clipboard, for pasting into an analysis board.
function ChessWidget:onCopyFen()
    local fen = self.game.board:getFen()
    if Device:hasClipboard() then
        Device.input.setClipboardText(fen)
        UIManager:show(InfoMessage:new{
            text = ("%s\n\n%s"):format(_("Position copied:"), fen),
        })
    else
        -- No clipboard to copy to, so show it: on a device with a keyboard
        -- attached, or none at all, reading it off the screen is the fallback.
        UIManager:show(InfoMessage:new{ text = fen })
    end
    return true
end

function ChessWidget:onChooseLevel()
    if self.thinking then return true end
    local entries = {}
    for i, level in ipairs(Search.LEVELS) do
        local marker = (i == self.game.level) and "  ✓" or ""
        entries[#entries + 1] = {
            -- %g so the sub-second levels read "0.5s" rather than "0s".
            text = ("%s (%gs)%s"):format(level.name, level.time, marker),
            callback = function()
                self.game.level = i
                self:updateStatus()
                self:refreshStatus()
                -- The whole game, not just the preference: the level is part
                -- of the saved game, so saving only the preference would let
                -- the restored game put the old level back.
                self:saveGame()
            end,
        }
    end
    return self:showMenu(_("Engine strength"), entries)
end

function ChessWidget:onHint()
    if self.thinking or not self.game:isPlayerTurn() then return true end

    self.thinking = true
    self.abort_search = false
    self.search_kind = "hint"
    self:updateStatus(_("Looking for a move\xe2\x80\xa6"))
    self:refreshStatus()

    -- A hint is a short search: it should feel instant rather than strong,
    -- and it is the same at every level -- somebody asking for help wants the
    -- best answer available, not one handicapped to match the opponent.
    local ok, err = self.engine:think{
        game = self.game,
        max_depth = 6,
        max_time = 3.0,
        noise = 0,
        on_done = function(uci, _info, failure) self:finishHint(uci, failure) end,
    }
    if not ok then
        self.thinking = false
        self:onEngineFailure(err)
        return true
    end
    self:schedulePoll()
    return true
end

function ChessWidget:finishHint(uci, failure)
    self:stopPolling()
    self.thinking = false
    self.search_kind = nil

    if failure then
        self:onEngineFailure(failure)
        return
    end
    local move = (not self.abort_search) and uci and self.game.board:moveFromUci(uci)
    if not move then
        self:updateStatus()
        self:refreshStatus()
        return
    end

    -- Show the suggestion by selecting the piece and lighting up just the
    -- square it wants to go to.
    local from, to = Board.moveFrom(move), Board.moveTo(move)
    local changed = self.board_view:setSelected(from)
    self.board_view.targets = { [to] = true }
    changed[#changed + 1] = to
    self:updateStatus(("%s %s"):format(_("Try"), self.game.board:moveToSan(move)))
    self:refreshSquares(changed, "ui")
    self:refreshStatus()
end

function ChessWidget:onResign()
    if self.game:isOver() then return true end
    -- With two players, say who is giving up: whoever is to move.
    local prompt = _("Resign this game?")
    if self.game.two_player then
        prompt = (self.game.board.side == Board.WHITE)
            and _("White resigns this game?") or _("Black resigns this game?")
    end
    UIManager:show(ConfirmBox:new{
        text = prompt,
        ok_text = _("Resign"),
        ok_callback = function()
            self:cancelSearch()
            self.game:resign()
            self:updateStatus()
            self:refreshAll("partial")
            self:announceResult()
            self:saveGame()
        end,
    })
    return true
end

function ChessWidget:onExportPgn()
    local path = self:pgnPath()
    local pgn = self.game:toPgn{ engine_name = "Kobo Chess" }
    local file, err = io.open(path, "w")
    if not file then
        UIManager:show(InfoMessage:new{
            text = ("%s\n%s"):format(_("Could not save PGN:"), tostring(err)),
        })
        return true
    end
    file:write(pgn)
    file:close()
    UIManager:show(InfoMessage:new{
        text = ("%s\n%s"):format(_("Game saved to:"), path),
    })
    return true
end

--==========================================================================
-- Persistence
--==========================================================================

--- Where to write an exported game.
-- Preference goes to the user's library folder (on a Kobo that is
-- /mnt/onboard, which shows up when the device is plugged into a computer)
-- rather than KOReader's own directory, which is hidden away under .adds.
function ChessWidget:pgnPath()
    local dir = G_reader_settings:readSetting("home_dir")
    if not dir or lfs.attributes(dir, "mode") ~= "directory" then
        local DataStorage = require("datastorage")
        dir = DataStorage:getDataDir()
    end
    return ("%s/kobochess-%s.pgn"):format(dir, os.date("%Y%m%d-%H%M%S"))
end

function ChessWidget:saveGame()
    if not self.settings then return end
    self.settings:saveSetting("game", self.game:toTable())
    self.settings:saveSetting("level", self.game.level)
    self.settings:saveSetting("flipped", self.board_view.flipped)
    if self.clock then
        local saved = self.clock:toTable(nowSeconds())
        -- Stamped with the game it belongs to, so it is never applied to a
        -- different one.
        saved.game_started_at = self.game.started_at
        self.settings:saveSetting("clock", saved)
    else
        self.settings:saveSetting("clock", nil)
    end
    self.settings:flush()
end

--==========================================================================
-- Lifecycle
--==========================================================================

function ChessWidget:onShow()
    -- Night mode may have been toggled since the board was built.
    self.board_view:syncNightMode()
    if self.clock then self:updateClockText() end
    -- One clean full refresh on entry; the board is a large, high-contrast
    -- image and partial refreshes leave the previous screen showing through.
    UIManager:setDirty(self, "full")
    return true
end

function ChessWidget:onClose()
    self:cancelSearch()
    self:stopPolling()
    -- Closing the board stops the clock. Nobody is thinking about the
    -- position while the reader is showing a book.
    if self.clock then self.clock:pause(nowSeconds()) end
    self:stopClockTick()
    self:saveGame()
    UIManager:close(self)
    if self.on_close then self.on_close() end
    return true
end

function ChessWidget:onCloseWidget()
    self.thinking = false
    self:stopPolling()
    self:stopClockTick()
    -- An external engine is a process of its own: it has to be told to go,
    -- or it would sit there holding its network in memory for the rest of
    -- the session.
    if self.engine then self.engine:close() end
    if self.board_view then self.board_view:onCloseWidget() end
    if self.status_widget then self.status_widget:free() end
    if self.history_widget then self.history_widget:free() end
    if self.clock_far then self.clock_far:free() end
    if self.clock_near then self.clock_near:free() end
    if self.forced_portrait then
        -- Asking, rather than setting the screen directly, lets whatever is
        -- underneath (reader or file browser) re-lay itself out for the
        -- orientation it had before. After this close completes, so that
        -- the repaint it triggers is not painted over by our own.
        local mode = self.saved_rotation
        UIManager:nextTick(function()
            UIManager:broadcastEvent(Event:new("SetRotationMode", mode))
        end)
    end
    -- The board filled the screen, so leave a clean panel behind.
    UIManager:setDirty(nil, "full")
end

--- Pause a running search when KOReader suspends, so the device can sleep.
function ChessWidget:onSuspend()
    self:cancelSearch()
    -- And stop the clock, rather than charge somebody for the time the
    -- device spent asleep. It has to be restarted by hand on the way back,
    -- which is the honest thing to do: only the players know when they are
    -- ready to carry on.
    if self.clock then self.clock:pause(nowSeconds()) end
    self:stopClockTick()
    self:saveGame()
end

return ChessWidget
