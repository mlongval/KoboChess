--[[--
Chess training: puzzles, famous games and openings, on a board of its own.

Opened from the Chess board's Train menu and shown on top of it, so the game
in progress is left exactly as it was and "Back to the game" simply closes
this. It has the same look as the board (title bar with X, a bold status
line, the board, one line under it and one row of buttons with menus at the
ends), and the same e-ink habits: only the squares that changed are
refreshed, as "partial" when pieces moved and "ui" for highlights, with a
full flash every few moves, after menus and dialogs, and on Refresh.

The three parts share the board and the input handling; what differs is
held in `self.mode` ("puzzles", "masters", "openings") and in the button row
built for it. The chess itself is in kobochess/puzzles.lua, masters.lua and
openings.lua, which have no UI and are tested on their own.

@module kobochess.chesstrain
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local ButtonDialog = require("ui/widget/buttondialog")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local Size = require("ui/size")
local TextViewer = require("ui/widget/textviewer")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local logger = require("logger")
local _ = require("gettext")

local Board = require("kobochess.board")
local BoardView = require("boardview")
local HelpDialog = require("chesshelpdialog")
local Masters = require("kobochess.masters")
local Openings = require("kobochess.openings")
local Puzzles = require("kobochess.puzzles")

local Screen = Device.screen

-- Delay before the other side's move is played (opening trainer, guessing),
-- so the learner sees their own move land first.
local REPLY_DELAY = 0.7

local MODE_TITLES = {
    puzzles = _("Chess · Puzzles"),
    masters = _("Chess · Famous games"),
    openings = _("Chess · Openings"),
}

-- The data files are read once per session and kept: they are small, and
-- going back and forth between the board and training should be instant.
local cache = {}

local function sideName(colour)
    return colour == Board.WHITE and _("White") or _("Black")
end

--- A CenterContainer that remembers where it was painted, so a line of text
-- can be refreshed on its own (see the same class in chesswidget.lua).
local TrackedContainer = CenterContainer:extend{}
function TrackedContainer:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    CenterContainer.paintTo(self, bb, x, y)
end

local TrainWidget = InputContainer:extend{
    settings = nil,          -- the plugin's LuaSettings (shared with the board)
    plugin_path = nil,
    piece_dir = nil,
    show_coordinates = true,
    full_refresh_every = 3,
    mode = "puzzles",
    daily = false,           -- open on the puzzle of the day
    on_back = nil,           -- back to the game: called after closing
    on_close_app = nil,      -- X: leave Chess altogether
    explained = nil,         -- explanations already seen this session (shared with the board)
}

--==========================================================================
-- Construction
--==========================================================================

function TrainWidget:init()
    self.screen_w = Screen:getWidth()
    self.screen_h = Screen:getHeight()
    self.covers_fullscreen = true
    self.dimen = Geom:new{ x = 0, y = 0, w = self.screen_w, h = self.screen_h }
    self.explained = self.explained or {}
    self.moves_since_full = 0
    self.busy = false
    self.reply_task = function() self:onReplyDue() end

    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
    end
    local all = Geom:new{ x = 0, y = 0, w = self.screen_w, h = self.screen_h }
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = all } },
        Swipe = { GestureRange:new{ ges = "swipe", range = all } },
        TwoFingerSwipe = { GestureRange:new{ ges = "two_finger_swipe", range = all } },
    }

    self:enterMode(self.mode, true)
end

function TrainWidget:dataPath(name)
    return self.plugin_path .. "/data/" .. name
end

function TrainWidget:puzzleList()
    if not cache.puzzles then cache.puzzles = Puzzles.load(self:dataPath("puzzles.tsv")) end
    return cache.puzzles
end

function TrainWidget:masterGames()
    if not cache.masters then cache.masters = Masters.load(self:dataPath("masters.pgn")) end
    return cache.masters
end

function TrainWidget:openingBook()
    return Openings.shared(self:dataPath("openings.tsv"))
end

--- The training part of the settings, one table per part.
function TrainWidget:store(key)
    local t = self.settings and self.settings:readSetting(key)
    if type(t) ~= "table" then t = {} end
    return t
end

function TrainWidget:save(key, value)
    if not self.settings then return end
    self.settings:saveSetting(key, value)
    self.settings:flush()
end

--- Switch to one of the three parts, building its buttons.
function TrainWidget:enterMode(mode, initial)
    self:cancelReply()
    self.mode = mode
    -- the board to show first, so the layout has something to draw
    if mode == "puzzles" then
        self.stats = Puzzles.stats(self:store("train_puzzles"))
        self:buildLayout()
        if self.daily then self:startDaily(true) else self:startNextPuzzle(true) end
    elseif mode == "masters" then
        self:buildLayout()
        local saved = self:store("train_masters")
        local games = self:masterGames()
        self:openGame(tonumber(saved.game) or 1, tonumber(saved.ply) or 0, true)
        if #games == 0 then self:setStatus(_("No famous games found.")) end
    else
        self:buildLayout()
        local saved = self:store("train_openings")
        local entry = saved.last and self:findOpening(saved.last.id)
        if entry then
            self:startDrill(entry, saved.last.colour == Board.BLACK and Board.BLACK or Board.WHITE, true)
        else
            self:startDrill(self:defaultOpening(), Board.WHITE, true)
        end
    end
    if not initial then self:refreshAll("full") end
end

function TrainWidget:buildLayout()
    if self.board_view then self.board_view:onCloseWidget() end
    if self.status_widget then self.status_widget:free() end
    if self.info_widget then self.info_widget:free() end

    local margin = Size.padding.large
    self.title_bar = TitleBar:new{
        width = self.screen_w,
        fullscreen = true,
        align = "center",
        title = MODE_TITLES[self.mode],
        with_bottom_line = true,
        close_callback = function() self:onCloseApp() end,
        show_parent = self,
    }
    self.status_widget = TextWidget:new{
        text = "", face = Font:getFace("cfont", 20), bold = true,
        max_width = self.screen_w - 2 * margin,
    }
    self.info_widget = TextWidget:new{
        text = "", face = Font:getFace("smallinfofont", 17),
        max_width = self.screen_w - 2 * margin,
    }

    self.buttons = {}
    local row = self:buildButtonRow(self:buttonSpecs(), margin)

    local span = Size.padding.default
    local fixed_h = self.title_bar:getHeight() + self.status_widget:getSize().h
        + self.info_widget:getSize().h + row:getSize().h + span * 5
    local board_size = math.min(self.screen_w - 2 * margin, self.screen_h - fixed_h)
    board_size = math.max(64, math.floor(board_size / 8) * 8)

    self.board_view = BoardView:new{
        board = Board.new(),
        size = board_size,
        flipped = false,
        piece_dir = self.piece_dir,
        show_coordinates = self.show_coordinates,
    }
    self.snapshot = nil

    self.status_container = TrackedContainer:new{
        dimen = Geom:new{ w = self.screen_w, h = self.status_widget:getSize().h },
        self.status_widget,
    }
    self.info_container = TrackedContainer:new{
        dimen = Geom:new{ w = self.screen_w, h = self.info_widget:getSize().h },
        self.info_widget,
    }
    self[1] = FrameContainer:new{
        width = self.screen_w, height = self.screen_h,
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0, padding = 0, margin = 0,
        VerticalGroup:new{
            align = "center",
            self.title_bar,
            VerticalSpan:new{ width = span },
            self.status_container,
            VerticalSpan:new{ width = span },
            CenterContainer:new{
                dimen = Geom:new{ w = self.screen_w, h = board_size },
                self.board_view,
            },
            VerticalSpan:new{ width = span },
            self.info_container,
            VerticalSpan:new{ width = span },
            row,
        },
    }
end

--- One row of buttons: the part's own menu at the left, Train at the right.
-- Every button explains itself the first time it is used.
function TrainWidget:buttonSpecs()
    local function b(id, text, help, fn)
        return { id = id, text = text, callback = function() self:explain(help, fn) end }
    end
    local refresh = b("refresh", _("Refresh"), "train_refresh", function() self:onForceRefresh() end)
    local train = b("train", _("Train ▾"), "train", function() self:onTrainMenu() end)
    if self.mode == "puzzles" then
        return {
            b("menu", _("Puzzle ▾"), "puzzle_menu", function() self:onPuzzleMenu() end),
            b("hint", _("Hint"), "puzzle_hint", function() self:onPuzzleHint() end),
            b("solution", _("Solution"), "puzzle_solution", function() self:onPuzzleSolution() end),
            b("next", _("Next"), "puzzle_next", function() self:startNextPuzzle() end),
            refresh, train,
        }
    elseif self.mode == "masters" then
        return {
            b("menu", _("Game ▾"), "master_menu", function() self:onMasterMenu() end),
            b("back", "◀", "master_back", function() self:onMasterBack() end),
            b("forward", "▶", "master_forward", function() self:onMasterForward() end),
            b("guess", _("Guess"), "master_guess", function() self:onMasterGuess() end),
            refresh, train,
        }
    end
    return {
        b("menu", _("Opening ▾"), "opening_menu", function() self:onOpeningMenu() end),
        b("hint", _("Hint"), "opening_hint", function() self:onOpeningHint() end),
        b("again", _("Again"), "opening_again", function() self:onOpeningAgain() end),
        b("flip", _("Flip"), "opening_flip", function() self:onFlip() end),
        refresh, train,
    }
end

function TrainWidget:buildButtonRow(specs, margin)
    local gap = Size.padding.default
    -- the menus at the ends have the longest labels: a little more room for them
    local weights, total = {}, 0
    for i, spec in ipairs(specs) do
        weights[i] = spec.text:find("▾") and 1.15 or 1
        total = total + weights[i]
    end
    local unit = (self.screen_w - 2 * margin - gap * (#specs - 1)) / total
    local group = HorizontalGroup:new{ align = "center" }
    for i, spec in ipairs(specs) do
        -- no `radius`: see the note in chesswidget.lua's buildButtonRow
        local button = Button:new{
            text = spec.text, width = math.floor(unit * weights[i]),
            callback = spec.callback, show_parent = self,
        }
        self.buttons[spec.id] = button
        table.insert(group, button)
        if i < #specs then table.insert(group, HorizontalSpan:new{ width = gap }) end
    end
    return group
end

function TrainWidget:explain(key, fn)
    HelpDialog.explainOnce(self, self.settings, self.explained, key, fn)
end

--==========================================================================
-- Refreshing
--==========================================================================

function TrainWidget:refreshSquares(squares, mode)
    local region
    for _, sq in ipairs(squares or {}) do
        local rect = self.board_view:squareRect(sq)
        region = region and region:combine(rect) or rect
    end
    if region then UIManager:setDirty(self, mode or "ui", region) end
end

function TrainWidget:refreshAll(mode)
    UIManager:setDirty(self, mode or "partial")
end

--- The status line, and everything under the board (info line, buttons).
function TrainWidget:refreshText()
    if self.status_container.dimen.y then
        UIManager:setDirty(self, "ui", self.status_container.dimen:copy())
    end
    local y = self.info_container.dimen.y
    if y and y > 0 then
        UIManager:setDirty(self, "ui", Geom:new{ x = 0, y = y, w = self.screen_w, h = self.screen_h - y })
    end
end

function TrainWidget:setStatus(status, info)
    self.status_widget:setText(status or "")
    if info then self.info_widget:setText(info) end
end

--- Show a position: the board, its last move, and only the squares that
-- changed repainted. Pieces moving use "partial", which lets the panel heal
-- its own ghosts; every few moves the whole screen gets a clean flash.
function TrainWidget:showPosition(board, last_move, fresh)
    local changed = self.board_view:setSelected(nil)
    self.board_view.board = board
    for _, sq in ipairs(self.board_view:setLastMove(last_move)) do changed[#changed + 1] = sq end
    local before = self.snapshot
    local snap = {}
    for rank = 0, 7 do
        for file = 0, 7 do
            local sq = rank * 16 + file
            snap[sq] = board.sq[sq]
            if before and before[sq] ~= snap[sq] then changed[#changed + 1] = sq end
        end
    end
    self.snapshot = snap
    if fresh or not before then
        -- a new position altogether (new puzzle, other game): flash it clean
        self.moves_since_full = 0
        self:refreshAll("full")
        return
    end
    self.moves_since_full = self.moves_since_full + 1
    if self.full_refresh_every > 0 and self.moves_since_full >= self.full_refresh_every then
        self.moves_since_full = 0
        self:refreshAll("full")
    else
        self:refreshSquares(changed, "partial")
        self:refreshText()
    end
end

function TrainWidget:onForceRefresh()
    self.moves_since_full = 0
    self:refreshAll("full")
    return true
end

--==========================================================================
-- Menus
--==========================================================================

--- A one-item-per-row menu. The screen is flashed clean once it is gone.
function TrainWidget:showMenu(title, entries)
    local dialog
    local buttons = {}
    for _, entry in ipairs(entries) do
        buttons[#buttons + 1] = { {
            text = entry.text,
            enabled = entry.enabled ~= false,
            callback = function()
                UIManager:close(dialog)
                UIManager:setDirty(self, "full")
                entry.callback()
            end,
        } }
    end
    dialog = ButtonDialog:new{
        title = title, title_align = "center", buttons = buttons,
        tap_close_callback = function() UIManager:setDirty(self, "full") end,
    }
    UIManager:show(dialog, "ui")
    return true
end

function TrainWidget:message(text, timeout)
    UIManager:show(InfoMessage:new{
        text = text, timeout = timeout,
        dismiss_callback = function() UIManager:setDirty(self, "full") end,
    }, "ui")
end

function TrainWidget:onTrainMenu()
    return self:showMenu(_("Train"), {
        { text = _("Puzzles"), callback = function()
            self.daily = false
            if self.mode == "puzzles" then self:startNextPuzzle() else self:enterMode("puzzles") end
        end },
        { text = _("Puzzle of the day"), callback = function()
            if self.mode == "puzzles" then self:startDaily() else self.daily = true; self:enterMode("puzzles") end
        end },
        { text = _("Famous games"), callback = function() self:enterMode("masters") end },
        { text = _("Openings"), callback = function() self:enterMode("openings") end },
        { text = _("Back to the game"), callback = function() self:onBack() end },
    })
end

--==========================================================================
-- Input
--==========================================================================

function TrainWidget:onSwipe(arg, ges)
    local ok, DeviceMenu = pcall(require, "kobo_devicemenu")
    return ok and DeviceMenu.handleSwipe(ges, {
        title = _("Chess"),
        items = {
            { text = _("Refresh screen"), callback = function() self:onForceRefresh() end },
            { text = _("Back to the game"), callback = function() self:onBack() end },
            { text = _("Show explanations again"), callback = function()
                HelpDialog.resetAll(self.settings)
                for k in pairs(self.explained) do self.explained[k] = nil end
                self:message(_("Each button will explain itself again the next time it is used."), 3)
            end },
        },
        close_app = function() self:onCloseApp() end,
        on_close = function() UIManager:setDirty(self, "full") end,
    }) or false
end

function TrainWidget:onTwoFingerSwipe(arg, ges)
    local ok, DeviceMenu = pcall(require, "kobo_devicemenu")
    return ok and DeviceMenu.lightGesture(ges) or false
end

-- Laid out for portrait like the board: only upright <-> upside down follows.
function TrainWidget:onSetRotationMode(mode)
    local ok, DeviceMenu = pcall(require, "kobo_devicemenu")
    if ok and DeviceMenu.followRotation(mode, true) then
        UIManager:setDirty("all", "full")
    end
    return true
end

--- The side the player moves for right now, or nil when it is not their turn.
function TrainWidget:playerSide()
    if self.busy then return nil end
    if self.mode == "puzzles" then
        local s = self.session
        return s and not s.solved and s.board.side == s.solver and s.solver or nil
    elseif self.mode == "masters" then
        local v = self.viewer
        return v and v:isGuessTurn() and v.board.side or nil
    else
        local d = self.drill
        return d and not d:isDone() and not d:isTrainerTurn() and d.colour or nil
    end
end

function TrainWidget:currentBoard()
    if self.mode == "puzzles" then return self.session and self.session.board
    elseif self.mode == "masters" then return self.viewer and self.viewer.board end
    return self.drill and self.drill.board
end

function TrainWidget:onTap(_, ges)
    local dimen = self.board_view.dimen
    if not dimen or not ges.pos then return true end
    local sq = self.board_view:squareAt(ges.pos.x - dimen.x, ges.pos.y - dimen.y)
    if not sq then return true end
    local side = self:playerSide()
    if not side then
        if self.mode == "masters" and not (self.viewer and self.viewer.guess) then
            -- tapping the board while just watching: the next move
            self:onMasterForward()
        end
        return true
    end
    local board = self:currentBoard()
    local selected = self.board_view.selected
    if selected and self.board_view.targets[sq] then
        self:attemptMove(board, selected, sq)
        return true
    end
    local piece = board.sq[sq]
    if piece ~= Board.EMPTY and math.floor(piece / 8) == side then
        self:refreshSquares(self.board_view:setSelected((selected == sq) and nil or sq), "ui")
    elseif selected then
        self:refreshSquares(self.board_view:setSelected(nil), "ui")
    end
    return true
end

function TrainWidget:attemptMove(board, from, to)
    local moves = {}
    local n = board:generateMoves(moves)
    for i = 1, n do
        local m = moves[i]
        if Board.moveFrom(m) == from and Board.moveTo(m) == to and Board.movePromo(m) ~= 0 then
            return self:askPromotion(board, from, to)
        end
    end
    local move = board:findMove(from, to)
    if move then self:onPlayerMove(move) end
end

function TrainWidget:askPromotion(board, from, to)
    local dialog
    local buttons = {}
    for _, choice in ipairs({ { Board.QUEEN, _("Queen") }, { Board.ROOK, _("Rook") },
                              { Board.BISHOP, _("Bishop") }, { Board.KNIGHT, _("Knight") } }) do
        buttons[#buttons + 1] = { {
            text = choice[2],
            callback = function()
                UIManager:close(dialog)
                local move = board:findMove(from, to, choice[1])
                if move then self:onPlayerMove(move) end
            end,
        } }
    end
    dialog = ButtonDialog:new{ title = _("Promote to"), title_align = "center", buttons = buttons }
    UIManager:show(dialog, "ui")
end

function TrainWidget:onPlayerMove(move)
    if self.mode == "puzzles" then return self:puzzleMove(move)
    elseif self.mode == "masters" then return self:masterGuessMove(move) end
    return self:drillMove(move)
end

--- Show which move is meant: the piece picked up and its square marked.
function TrainWidget:pointAt(move, with_target)
    local from, to = Board.moveFrom(move), Board.moveTo(move)
    local changed = self.board_view:setSelected(from)
    if with_target then
        self.board_view.targets = { [to] = true }
    end
    changed[#changed + 1] = to
    self:refreshSquares(changed, "ui")
end

--- The other side's move, after a moment (see REPLY_DELAY).
function TrainWidget:scheduleReply(fn)
    self.busy = true
    self.reply_fn = fn
    UIManager:scheduleIn(REPLY_DELAY, self.reply_task)
end

function TrainWidget:cancelReply()
    UIManager:unschedule(self.reply_task)
    self.busy = false
    self.reply_fn = nil
end

function TrainWidget:onReplyDue()
    self.busy = false
    local fn = self.reply_fn
    self.reply_fn = nil
    if fn then fn() end
end

--==========================================================================
-- Puzzles
--==========================================================================

function TrainWidget:startPuzzle(puzzle, is_daily, initial)
    -- leaving a puzzle half done after a mistake or a hint counts as a miss
    self:finishPuzzle(false, true)
    local session, err = puzzle and Puzzles.start(puzzle)
    if not session then
        logger.warn("KoboChess: puzzle could not be set up:", puzzle and puzzle.id, err)
        self.session = nil
        self:setStatus(_("No puzzle could be loaded."), "")
        self:refreshAll("full")
        return
    end
    self.session = session
    self.session.daily = is_daily
    self.session.recorded = false
    self.hint_stage = 0
    self.board_view.flipped = (session.solver == Board.BLACK)
    self.board_view:freeRotatedWidgets()
    self:updatePuzzleText()
    self:showPosition(session.board, session.played[#session.played], true)
end

function TrainWidget:startNextPuzzle(initial)
    local list = self:puzzleList()
    self.daily = false
    self:startPuzzle(Puzzles.pick(list, self.stats.rating, self.stats.done), false, initial)
end

function TrainWidget:startDaily(initial)
    self.daily = false
    self:startPuzzle(Puzzles.daily(self:puzzleList()), true, initial)
end

--- Count the puzzle in the stats, once. `solved` is a clean solve.
-- `leaving`: only record if the player had already done something.
function TrainWidget:finishPuzzle(solved, leaving)
    local s = self.session
    if not s or s.recorded then return end
    if leaving and s:isClean() then return end
    s.recorded = true
    s.rating_change = Puzzles.record(self.stats, s.puzzle, solved)
    if s.daily then self.stats.daily_done = Puzzles.dateKey() end
    self:save("train_puzzles", self.stats)
end

function TrainWidget:updatePuzzleText()
    local s = self.session
    if not s then return end
    local status, info
    local label = s.daily and _("Puzzle of the day") or _("Puzzle")
    if s.solved then
        local change = s.rating_change or 0
        status = ("%s  ·  %s %d (%s%d)"):format(
            s:isClean() and _("Solved!") or _("Done"), _("your rating"),
            self.stats.rating, change >= 0 and "+" or "", change)
        info = ("%s %d  ·  %s"):format(_("Puzzle rated"), s.puzzle.rating,
                                      Puzzles.themesText(s.puzzle, 4))
    else
        status = ("%s  ·  %s"):format(label,
            ("%s to play: find the best move"):format(sideName(s.solver)))
        info = ("%s %d  ·  %s %d  ·  %s %d"):format(_("Your rating"), self.stats.rating,
            _("solved"), self.stats.solved, _("streak"), self.stats.streak)
    end
    self:setStatus(status, info)
    self.buttons.hint:enableDisable(not s.solved)
    self.buttons.solution:enableDisable(not s.solved)
end

function TrainWidget:puzzleMove(move)
    local s = self.session
    local san = s.board:moveToSan(move)
    local result, reply = s:try(move)
    if result == "wrong" then
        self.hint_stage = 0
        self:refreshSquares(self.board_view:setSelected(nil), "ui")
        self:setStatus(("%s %s  ·  %s"):format(san, _("is not it"), _("try again, or tap Hint")))
        self:refreshText()
        return
    end
    self.hint_stage = 0
    if result == "solved" then
        self:finishPuzzle(s:isClean())
        self:updatePuzzleText()
        self:showPosition(s.board, s.played[#s.played])
        return
    end
    -- right, and the opponent has answered at once; its move is the one marked
    self:setStatus(("%s %s  ·  %s"):format(san, _("is right!"), _("keep going")))
    self:showPosition(s.board, reply)
end

function TrainWidget:onPuzzleHint()
    local s = self.session
    if not s or s.solved then return end
    local m = s:expectedMove()
    if not m then return end
    s.hints = s.hints + 1
    self.hint_stage = (self.hint_stage or 0) + 1
    self:pointAt(m, self.hint_stage >= 2)
    if self.hint_stage >= 2 then
        self:setStatus(("%s %s"):format(_("Try"), s.board:moveToSan(m)))
    else
        self:setStatus(_("This piece moves. Tap Hint again to see where."))
    end
    self:refreshText()
end

function TrainWidget:onPuzzleSolution()
    local s = self.session
    if not s or s.solved then return end
    local m = s:expectedMove()
    if not m then return end
    s.hints = s.hints + 1
    local san = s.board:moveToSan(m)
    local result, reply = s:try(m)
    if result == "solved" then
        self:finishPuzzle(false)
        self:updatePuzzleText()
        self:showPosition(s.board, s.played[#s.played])
        return
    end
    self:setStatus(("%s %s  ·  %s"):format(_("The move was"), san, _("now find the next one")))
    self:showPosition(s.board, reply)
end

function TrainWidget:onPuzzleMenu()
    local today = Puzzles.dateKey()
    local daily_done = self.stats.daily_done == today
    return self:showMenu(_("Puzzles"), {
        { text = _("Next puzzle"), callback = function() self:startNextPuzzle() end },
        { text = _("Puzzle of the day") .. (daily_done and "  ✓" or ""),
          callback = function() self:startDaily() end },
        { text = _("Try again"), enabled = self.session ~= nil, callback = function()
            local s = self.session
            local p, daily = s.puzzle, s.daily
            s.recorded = true      -- already counted; a retry is practice
            self:startPuzzle(p, daily)
            self.session.recorded = true
        end },
        { text = _("Flip board"), callback = function() self:onFlip() end },
        { text = _("Your puzzle stats"), callback = function() self:showPuzzleStats() end },
        { text = _("Back to the game"), callback = function() self:onBack() end },
    })
end

function TrainWidget:showPuzzleStats()
    local st = self.stats
    local pct = st.played > 0 and math.floor(st.solved * 100 / st.played + 0.5) or 0
    self:message(("%s\n\n%s: %d\n%s: %d\n%s: %d (%d%%)\n%s: %d\n%s: %d\n\n%s"):format(
        _("Your puzzles"),
        _("Puzzle rating"), st.rating,
        _("Puzzles done"), st.played,
        _("Solved cleanly"), st.solved, pct,
        _("Current run"), st.streak,
        _("Best run"), st.best_streak,
        ("%d %s"):format(#self:puzzleList(), _("puzzles on the Kobo, rated about 800 to 2300."))))
end

--==========================================================================
-- Famous games
--==========================================================================

function TrainWidget:openGame(index, ply, initial)
    local games = self:masterGames()
    if #games == 0 then self.viewer = nil; return end
    index = math.max(1, math.min(index, #games))
    self.game_index = index
    self.viewer = Masters.view(games[index])
    local last = self.viewer:goTo(ply or 0)
    self.board_view.flipped = false
    self.board_view:freeRotatedWidgets()
    self:updateMasterText()
    self:showPosition(self.viewer.board, last, true)
    self:saveMasterPlace()
end

function TrainWidget:saveMasterPlace()
    if self.viewer then
        self:save("train_masters", { game = self.game_index, ply = self.viewer.ply })
    end
end

function TrainWidget:updateMasterText(status_override)
    local v = self.viewer
    if not v then return end
    local game = v.game
    local status
    if status_override then
        status = status_override
    elseif v.guess then
        local g = v.guess
        if v:nextMove() == nil then
            status = ("%s  ·  %s %d / %d"):format(_("End of the game"), _("score"), g.score, g.possible)
        elseif v:isGuessTurn() then
            local w, b = Masters.players(game)
            local who = v.board.side == Board.WHITE and w or b
            status = ("%s %s %s?  ·  %s %d / %d"):format(_("Your guess: what did"),
                who, _("play"), _("score"), g.score, g.possible)
        else
            status = ("%s  ·  %s %d / %d"):format(_("Their move…"), _("score"), g.score, g.possible)
        end
    elseif v.ply == 0 then
        status = Masters.shortTitle(game) .. "  ·  " .. _("tap ▶ to start")
    elseif v:nextMove() == nil then
        status = ("%s  ·  %s"):format(Masters.shortTitle(game), game.result)
    else
        status = ("%s  ·  %s %d / %d"):format(Masters.shortTitle(game), _("move"),
            math.floor((v.ply + 1) / 2), math.floor((v:length() + 1) / 2))
    end
    local info = v.ply == 0 and Masters.title(game) or v:recentText(10)
    self:setStatus(status, info)
    self.buttons.back:enableDisable(v.ply > 0 and not v.guess)
    self.buttons.forward:enableDisable(v:nextMove() ~= nil)
end

function TrainWidget:stepTo(ply)
    local v = self.viewer
    if not v then return end
    local last = v:goTo(ply)
    self:updateMasterText()
    self:showPosition(v.board, last)
    self:saveMasterPlace()
end

function TrainWidget:onMasterBack()
    if self.viewer and not self.busy then self:stepTo(self.viewer.ply - 1) end
end

function TrainWidget:onMasterForward()
    local v = self.viewer
    if not v or self.busy then return end
    if v:isGuessTurn() then
        -- giving up on this one
        local san = v.board:moveToSan(v:nextMove())
        local m = v:revealGuess()
        self:afterGuess(("%s %s"):format(_("The master played"), san), m)
        return
    end
    self:stepTo(v.ply + 1)
end

--- After a guess is settled: show the move, then play the other side's.
function TrainWidget:afterGuess(status, move)
    local v = self.viewer
    self:updateMasterText(status)
    self:showPosition(v.board, move)
    self:saveMasterPlace()
    if v.guess and v:nextMove() and not v:isGuessTurn() then
        self:scheduleReply(function()
            local m = v:forward()
            self:updateMasterText()
            self:showPosition(v.board, m)
            self:saveMasterPlace()
        end)
    elseif v.guess and not v:nextMove() then
        self:message(("%s\n\n%s %d / %d"):format(Masters.title(v.game), _("Your score:"),
            v.guess.score, v.guess.possible))
    end
end

function TrainWidget:masterGuessMove(move)
    local v = self.viewer
    local san = v.board:moveToSan(move)
    local before = v.board:clone()
    local result, extra = v:tryGuess(move)
    if result == "right" then
        self:afterGuess(("%s %s!  +%d"):format(_("Yes,"), san, extra), move)
    elseif result == "again" then
        self:refreshSquares(self.board_view:setSelected(nil), "ui")
        self:updateMasterText(("%s %s  ·  %s"):format(san, _("is not it"), _("one more try")))
        self:refreshText()
    elseif result == "shown" then
        self:afterGuess(("%s  ·  %s %s"):format(_("Not that either"), _("the master played"),
            before:moveToSan(extra)), extra)
    end
end

function TrainWidget:onMasterGuess()
    local v = self.viewer
    if not v then return end
    self:cancelReply()
    if v.guess then
        v:stopGuessing()
        self:updateMasterText()
        self:refreshText()
        return
    end
    self:startGuessing(Masters.defaultGuessSide(v.game))
end

function TrainWidget:startGuessing(side)
    local v = self.viewer
    if not v:nextMove() then v:goTo(0) end
    v:startGuessing(side)
    self.board_view.flipped = (side == Board.BLACK)
    self.board_view:freeRotatedWidgets()
    if not v:isGuessTurn() and v:nextMove() then
        -- the other side moves first
        local m = v:forward()
        self:updateMasterText()
        self:showPosition(v.board, m, true)
    else
        self:updateMasterText()
        self:refreshAll("full")
    end
    self:saveMasterPlace()
end

function TrainWidget:onMasterMenu()
    local v = self.viewer
    local entries = {
        { text = _("Choose a game"), callback = function() self:chooseGame() end },
        { text = _("Go to the start"), enabled = v ~= nil, callback = function()
            self:cancelReply()
            if v.guess then v:stopGuessing() end
            self:stepTo(0)
        end },
        { text = _("Go to the end"), enabled = v ~= nil, callback = function()
            self:cancelReply()
            if v.guess then v:stopGuessing() end
            self:stepTo(v:length())
        end },
        { text = _("Move list"), enabled = v ~= nil, callback = function() self:showMoveList() end },
        { text = _("Guess White's moves"), enabled = v ~= nil,
          callback = function() self:cancelReply(); self:startGuessing(Board.WHITE) end },
        { text = _("Guess Black's moves"), enabled = v ~= nil,
          callback = function() self:cancelReply(); self:startGuessing(Board.BLACK) end },
        { text = _("Flip board"), callback = function() self:onFlip() end },
        { text = _("Back to the game"), callback = function() self:onBack() end },
    }
    return self:showMenu(_("Famous games"), entries)
end

function TrainWidget:chooseGame()
    local entries = {}
    for i, game in ipairs(self:masterGames()) do
        entries[#entries + 1] = {
            text = Masters.title(game) .. (i == self.game_index and "  ✓" or ""),
            callback = function() self:cancelReply(); self:openGame(i, 0) end,
        }
    end
    return self:showMenu(_("Choose a game"), entries)
end

function TrainWidget:showMoveList()
    local v = self.viewer
    local game = v.game
    local t = game.tags
    local text = ("%s\n%s\n\n%s\n\n%s"):format(
        Masters.title(game),
        t.Event or "",
        t.Note or "",
        v:moveListText() .. " " .. game.result)
    UIManager:show(TextViewer:new{
        title = ("%s – %s"):format(t.White or "?", t.Black or "?"),
        text = text,
        close_callback = function() UIManager:setDirty(self, "full") end,
    }, "ui")
end

--==========================================================================
-- Openings
--==========================================================================

--- An opening by its id (name and moves) or, failing that, by name.
function TrainWidget:findOpening(id_or_name)
    if not id_or_name then return nil end
    local by_name
    for _, e in ipairs(self:openingBook().list) do
        if e.id == id_or_name then return e end
        if not by_name and e.name == id_or_name then by_name = e end
    end
    return by_name
end

function TrainWidget:defaultOpening()
    local book = self:openingBook()
    return self:findOpening("Italian Game: Giuoco Piano") or self:findOpening("Italian Game")
        or book.list[1]
end

function TrainWidget:progress()
    local saved = self:store("train_openings")
    saved.progress = type(saved.progress) == "table" and saved.progress or {}
    return saved
end

--- Does the line have any move for `colour` to play?
local function hasMovesFor(entry, colour)
    local first = (colour == Board.WHITE) and 1 or 2
    return #entry.moves >= first
end

function TrainWidget:startDrill(entry, colour, initial)
    self:cancelReply()
    if not entry then
        self.drill = nil
        self:setStatus(_("No openings found."), "")
        return
    end
    if not hasMovesFor(entry, colour) then colour = Board.WHITE end
    self.drill = Openings.drill(entry, colour)
    local saved = self:progress()
    saved.last = { id = entry.id, colour = colour }
    self:save("train_openings", saved)
    self.board_view.flipped = (colour == Board.BLACK)
    self.board_view:freeRotatedWidgets()
    self:updateDrillText()
    self:showPosition(self.drill.board, nil, true)
    self:continueDrill()
end

--- Let the trainer play its book move, if it is its turn.
function TrainWidget:continueDrill()
    local d = self.drill
    if d and d:isTrainerTurn() then
        self:updateDrillText()
        self:refreshText()
        self:scheduleReply(function()
            local m = d:playTrainer()
            if d:isDone() then return self:drillFinished(m) end
            self:updateDrillText()
            self:showPosition(d.board, m)
        end)
    elseif d and d:isDone() then
        self:drillFinished(d.played[#d.played])
    end
end

function TrainWidget:openingName()
    local d = self.drill
    if not d or #d.played == 0 then return nil end
    local e = Openings.matchMoves(self:openingBook(), d.played)
    return e and e.name
end

function TrainWidget:updateDrillText(status_override)
    local d = self.drill
    if not d then return end
    local entry = d.entry
    -- The status line names the opening the moves so far make (it changes as
    -- the line goes on); the line under the board, the line being practised.
    local status = status_override
    if not status then
        local now = self:openingName()
        if d:isDone() then
            status = _("Line complete")
        elseif d:isTrainerTurn() then
            status = ("%s  ·  %s"):format(_("The book replies…"), now or entry.name)
        else
            status = ("%s %s"):format(_("Your move as"), sideName(d.colour))
            if now then status = status .. "  ·  " .. now end
        end
    end
    local info = ("%s  %s  ·  %s %d / %d"):format(entry.eco, entry.name, _("move"),
        math.min(d.ply + 1, #entry.moves), #entry.moves)
    self:setStatus(status, info)
    self.buttons.hint:enableDisable(not d:isDone())
end

function TrainWidget:drillMove(move)
    local d = self.drill
    local san = d.board:moveToSan(move)
    local ok, book = d:try(move)
    if not ok then
        self:refreshSquares(self.board_view:setSelected(nil), "ui")
        local book_san = book and d.board:moveToSan(book) or "?"
        self:updateDrillText(("%s %s  ·  %s %s"):format(san, _("is not the book move"),
            _("play"), book_san))
        if book then self:pointAt(book, true) end
        self:refreshText()
        return
    end
    if d:isDone() then return self:drillFinished(move) end
    self:updateDrillText()
    self:showPosition(d.board, move)
    self:continueDrill()
end

function TrainWidget:drillFinished(last_move)
    local d = self.drill
    if d.recorded then return end
    d.recorded = true
    local saved = self:progress()
    local r = Openings.record(saved.progress, d.entry, d.colour, d:isClean())
    self:save("train_openings", saved)
    local status
    if r.learned and d:isClean() then
        status = ("%s  ·  %s"):format(_("Learned!"), _("pick the next line in the menu"))
    elseif d:isClean() then
        local left = Openings.LEARNED_AFTER - r.clean_streak
        status = ("%s  ·  %d %s"):format(_("Clean run"), left, _("more to learn it, tap Again"))
    else
        status = ("%s  ·  %s"):format(_("Done, with a mistake or a hint"), _("tap Again to repeat it"))
    end
    self:updateDrillText(status)
    self:showPosition(d.board, last_move)
end

function TrainWidget:onOpeningHint()
    local d = self.drill
    if not d or d:isDone() or d:isTrainerTurn() or self.busy then return end
    local m = d:bookMove()
    if not m then return end
    d.hints = d.hints + 1
    self:pointAt(m, true)
    self:updateDrillText(("%s %s"):format(_("The book move is"), d.board:moveToSan(m)))
    self:refreshText()
end

function TrainWidget:onOpeningAgain()
    local d = self.drill
    if d then self:startDrill(d.entry, d.colour) end
end

function TrainWidget:onOpeningMenu()
    local d = self.drill
    return self:showMenu(_("Openings"), {
        { text = _("Choose an opening"), callback = function() self:chooseOpening() end },
        { text = _("Play as White") .. ((d and d.colour == Board.WHITE) and "  ✓" or ""),
          enabled = d ~= nil, callback = function() self:startDrill(d.entry, Board.WHITE) end },
        { text = _("Play as Black") .. ((d and d.colour == Board.BLACK) and "  ✓" or ""),
          enabled = d ~= nil and hasMovesFor(d.entry, Board.BLACK),
          callback = function() self:startDrill(d.entry, Board.BLACK) end },
        { text = _("Next line"), enabled = d ~= nil, callback = function() self:nextLine() end },
        { text = _("Your progress"), callback = function() self:showOpeningProgress() end },
        { text = _("Back to the game"), callback = function() self:onBack() end },
    })
end

function TrainWidget:isLearned(entry, colour)
    local r = self:progress().progress[Openings.progressKey(entry, colour)]
    return r and r.learned
end

--- The next line of the same family not learned yet (for the same side).
function TrainWidget:nextLine()
    local d = self.drill
    local fam = self:openingBook().by_family[d.entry.family] or {}
    local start
    for i, e in ipairs(fam) do if e == d.entry then start = i end end
    start = start or 0
    for k = 1, #fam do
        local e = fam[(start + k - 1) % #fam + 1]
        if e ~= d.entry and not self:isLearned(e, d.colour) and hasMovesFor(e, d.colour) then
            return self:startDrill(e, d.colour)
        end
    end
    self:message(_("Every line of this family is learned for this side."), 3)
end

--- Choose by family, then line: a paged list, as there are a few thousand.
function TrainWidget:chooseOpening()
    local Menu = require("ui/widget/menu")
    local book = self:openingBook()
    local colour = self.drill and self.drill.colour or Board.WHITE
    local menu
    local closed = false
    local function close()
        if closed then return end
        closed = true
        UIManager:close(menu)
        UIManager:setDirty(self, "full")
    end
    local families = {}
    for _, family in ipairs(book.families) do
        local entries = book.by_family[family]
        local sub = {}
        local learned = 0
        local seen = {}
        for _, e in ipairs(entries) do seen[e.name] = (seen[e.name] or 0) + 1 end
        for _, e in ipairs(entries) do
            local done = self:isLearned(e, colour)
            if done then learned = learned + 1 end
            local label = e.variation ~= "" and e.variation or e.name
            -- a name used for several lines: say which by its moves
            if seen[e.name] > 1 and e.san and e.san ~= "" then
                label = label .. "  (" .. e.san .. ")"
            end
            sub[#sub + 1] = {
                text = label .. (done and "  ✓" or ""),
                mandatory = e.eco,
                callback = function()
                    UIManager:nextTick(function() self:askColourFor(e) end)
                end,
            }
        end
        families[#families + 1] = {
            text = family,
            mandatory = learned > 0 and ("%d / %d"):format(learned, #entries) or tostring(#entries),
            sub_item_table = sub,
        }
    end
    menu = Menu:new{
        title = _("Choose an opening"),
        item_table = families,
        width = self.screen_w,
        height = self.screen_h,
        is_borderless = true,
        is_popout = false,
        is_enable_shortcut = false,
        covers_fullscreen = true,
        close_callback = close,
    }
    UIManager:show(menu, "full")
end

function TrainWidget:askColourFor(entry)
    local entries = {
        { text = _("Play as White"), callback = function() self:startDrill(entry, Board.WHITE) end },
    }
    if hasMovesFor(entry, Board.BLACK) then
        entries[#entries + 1] = { text = _("Play as Black"),
            callback = function() self:startDrill(entry, Board.BLACK) end }
    end
    return self:showMenu(entry.name, entries)
end

function TrainWidget:showOpeningProgress()
    local saved = self:progress()
    local learned, practising = {}, {}
    for key, r in pairs(saved.progress) do
        local name, colour = Openings.splitProgressKey(key)
        local line = ("%s (%s)"):format(name, sideName(colour))
        if r.learned then learned[#learned + 1] = line
        else practising[#practising + 1] = ("%s: %d %s"):format(line, r.clean_streak, _("clean in a row")) end
    end
    table.sort(learned)
    table.sort(practising)
    local text = ("%s\n\n%s\n\n%s\n\n%s"):format(
        ("%s: %d"):format(_("Learned"), #learned),
        #learned > 0 and table.concat(learned, "\n") or _("None yet."),
        ("%s: %d"):format(_("Practising"), #practising),
        #practising > 0 and table.concat(practising, "\n") or _("None."))
    UIManager:show(TextViewer:new{
        title = _("Your openings"),
        text = text .. "\n\n" .. _("A line is learned after three runs in a row without a mistake or a hint."),
        close_callback = function() UIManager:setDirty(self, "full") end,
    }, "ui")
end

--==========================================================================
-- Shared buttons
--==========================================================================

function TrainWidget:onFlip()
    self.board_view.flipped = not self.board_view.flipped
    self.board_view:freeRotatedWidgets()
    self:refreshAll("partial")
    return true
end

--==========================================================================
-- Lifecycle
--==========================================================================

function TrainWidget:onShow()
    self.board_view:syncNightMode()
    UIManager:setDirty(self, "full")
    return true
end

--- Back to the game underneath.
function TrainWidget:onBack()
    self:finishPuzzle(false, true)
    self:cancelReply()
    UIManager:close(self)
    if self.on_back then self.on_back() end
    return true
end

function TrainWidget:onClose()
    return self:onBack()
end

--- X: leave Chess altogether, back to Home.
function TrainWidget:onCloseApp()
    self:finishPuzzle(false, true)
    self:cancelReply()
    UIManager:close(self)
    if self.on_close_app then self.on_close_app() end
    return true
end

function TrainWidget:onCloseWidget()
    self:cancelReply()
    if self.board_view then self.board_view:onCloseWidget() end
    if self.status_widget then self.status_widget:free() end
    if self.info_widget then self.info_widget:free() end
    UIManager:setDirty(nil, "full")
end

return TrainWidget
