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
local Game = require("kobochess.game")
local Search = require("kobochess.search")

local Screen = Device.screen

-- How long the engine may run before handing control back to the UI. Short
-- enough that a tap feels responsive, long enough that the yield overhead
-- stays negligible.
local SEARCH_SLICE = 0.05

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
    self.screen_w = Screen:getWidth()
    self.screen_h = Screen:getHeight()
    self.covers_fullscreen = true

    self.searcher = Search.new()
    -- Check for a yield often; the check itself is cheap and it is what
    -- bounds how quickly Cancel takes effect.
    self.searcher.tick_interval = 256

    self.thinking = false
    self.abort_search = false
    self.search_co = nil
    self.moves_since_full_refresh = 0
    self.status_line = ""
    self.hint_move = nil

    self.full_refresh_every = DEFAULT_FULL_REFRESH_EVERY
    self.show_coordinates = true
    if self.settings then
        local saved = self.settings:readSetting("full_refresh_every")
        if type(saved) == "number" then self.full_refresh_every = saved end
        local coords = self.settings:readSetting("show_coordinates")
        if coords ~= nil then self.show_coordinates = coords end
    end

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

    -- Measure the chrome so the board can claim the rest.
    local span = Size.padding.default
    local fixed_h = self.title_bar:getHeight()
        + self.status_widget:getSize().h
        + self.history_widget:getSize().h
        + row:getSize().h
        + span * 5

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
        CenterContainer:new{
            dimen = Geom:new{ w = self.screen_w, h = board_size },
            self.board_view,
        },
        VerticalSpan:new{ width = span },
        self.history_container,
        VerticalSpan:new{ width = span },
        row,
    }

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
    self.buttons.undo:enableDisable(not self.thinking and self.game:canUndo())
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

    if not self.game:play(move) then
        logger.warn("KoboChess: refused to play an illegal move")
        return
    end

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

function ChessWidget:startEngineTurn()
    if self.thinking then return end
    self.thinking = true
    self.abort_search = false
    self.search_started = nowSeconds()
    self.last_status_update = 0
    self:updateStatus()
    self:refreshStatus()

    local last_yield = nowSeconds()
    local widget = self

    -- Search a copy. The search makes and unmakes moves on the board it is
    -- given, and it yields to the UI every few milliseconds, so searching the
    -- live board means any repaint landing mid-search draws the hypothetical
    -- position the engine is currently standing in: pieces on strange squares,
    -- captured pieces missing.
    local search_board = self.game.board:clone()

    self.search_co = coroutine.create(function()
        return widget.searcher:think(search_board, {
            level = widget.game.level,
            now = nowSeconds,
            on_tick = function()
                if widget.abort_search then return false end
                local now = nowSeconds()
                if now - last_yield >= SEARCH_SLICE then
                    coroutine.yield()
                    last_yield = nowSeconds()
                end
                return true
            end,
            on_depth = function(depth, score, san)
                widget:onSearchProgress(depth, score, san)
            end,
        })
    end)

    UIManager:nextTick(function() self:stepEngine() end)
end

--- Resume the search for one slice, then hand control back to the UI loop.
function ChessWidget:stepEngine()
    local co = self.search_co
    if not co then return end

    local ok, move, info = coroutine.resume(co)
    if not ok then
        -- `move` holds the error message when the coroutine failed.
        logger.err("KoboChess: search failed:", move)
        self.search_co = nil
        self.thinking = false
        self:updateStatus(_("Engine error — your move"))
        self:refreshStatus()
        return
    end

    if coroutine.status(co) == "dead" then
        self.search_co = nil
        self.thinking = false
        self:finishEngineTurn(move, info)
    else
        UIManager:nextTick(function() self:stepEngine() end)
    end
end

function ChessWidget:onSearchProgress(depth, score, san)
    if not self.thinking then return end
    local now = nowSeconds()
    if now - self.last_status_update < STATUS_THROTTLE then return end
    self.last_status_update = now

    local text = ("%s  depth %d  %s"):format(_("Thinking…"), depth,
                                             Search.formatScore(score, self.game.board.side))
    if san then text = text .. "  " .. san end
    self.status_widget:setText(text)
    self:refreshStatus()
end

function ChessWidget:finishEngineTurn(move, info)
    if self.abort_search then
        -- The player cancelled; leave the position alone and hand back the move.
        self:updateStatus()
        self:refreshStatus()
        return
    end
    if not move then
        -- No legal move means the game is already over; let the result stand.
        self.game:updateResult()
        self:updateStatus()
        self:refreshAll("partial")
        if self.game:isOver() then self:announceResult() end
        return
    end

    if info then
        logger.dbg(("KoboChess: depth %d, %d nodes in %.1fs")
            :format(info.depth or 0, info.nodes or 0, info.elapsed or 0))
    end

    -- The move came back from a copy of the board. The position is the same,
    -- so it is valid here too, but re-resolve it against the real board
    -- rather than trust that: playing a move that is not legal in the actual
    -- position would corrupt the game.
    move = self.game.board:findMove(Board.moveFrom(move), Board.moveTo(move),
                                    Board.movePromo(move) ~= 0
                                        and Board.movePromo(move) or nil)
    if not move then
        logger.err("KoboChess: engine move is not legal in the live position")
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
    return true
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
    return self:showMenu(_("Game"), {
        { text = _("New game"), enabled = not self.thinking,
          callback = function() self:onNewGame() end },
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
        { text = ("%s: %s"):format(_("Level"), level and level.name or "?"),
          enabled = not self.thinking,
          callback = function() self:onChooseLevel() end },
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
        self.searcher:reset()
        -- A two-player game is viewed from White's side by default; the
        -- players can turn it round with Flip.
        self.board_view.flipped = (not two_player) and (colour == Board.BLACK) or false
        self.board_view.rotate_far_side = two_player
        self.board_view:freeRotatedWidgets()
        self.moves_since_full_refresh = 0
        self.hint_move = nil
        self:syncBoardToGame()
        self:updateStatus()
        -- A new game is worth a clean, flashing refresh: it clears any
        -- ghosting left by the previous one.
        self:refreshAll("flashui")
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
    self:updateStatus(_("Looking for a move…"))
    self:refreshStatus()

    local last_yield = nowSeconds()
    local widget = self
    -- On a copy, for the same reason as the engine's own turn.
    local search_board = self.game.board:clone()
    -- A hint is a short search: it should feel instant rather than strong.
    self.search_co = coroutine.create(function()
        return widget.searcher:think(search_board, {
            max_depth = 6,
            max_time = 3.0,
            noise = 0,
            now = nowSeconds,
            on_tick = function()
                if widget.abort_search then return false end
                local now = nowSeconds()
                if now - last_yield >= SEARCH_SLICE then
                    coroutine.yield()
                    last_yield = nowSeconds()
                end
                return true
            end,
        })
    end)

    local function step()
        local co = self.search_co
        if not co then return end
        local ok, move = coroutine.resume(co)
        if not ok then
            logger.err("KoboChess: hint search failed:", move)
            self.search_co, self.thinking = nil, false
            self:updateStatus()
            self:refreshStatus()
            return
        end
        if coroutine.status(co) == "dead" then
            self.search_co, self.thinking = nil, false
            if move then
                -- Show the suggestion by selecting the piece and lighting up
                -- just the square it wants to go to.
                local from, to = Board.moveFrom(move), Board.moveTo(move)
                local changed = self.board_view:setSelected(from)
                self.board_view.targets = { [to] = true }
                changed[#changed + 1] = to
                self:updateStatus(("%s %s"):format(_("Try"),
                                                   self.game.board:moveToSan(move)))
                self:refreshSquares(changed, "ui")
                self:refreshStatus()
            else
                self:updateStatus()
                self:refreshStatus()
            end
        else
            UIManager:nextTick(step)
        end
    end
    UIManager:nextTick(step)
    return true
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
    self.settings:flush()
end

--==========================================================================
-- Lifecycle
--==========================================================================

function ChessWidget:onShow()
    -- Night mode may have been toggled since the board was built.
    self.board_view:syncNightMode()
    -- One clean full refresh on entry; the board is a large, high-contrast
    -- image and partial refreshes leave the previous screen showing through.
    UIManager:setDirty(self, "full")
    return true
end

function ChessWidget:onClose()
    self:cancelSearch()
    self.search_co = nil
    self:saveGame()
    UIManager:close(self)
    if self.on_close then self.on_close() end
    return true
end

function ChessWidget:onCloseWidget()
    self.search_co = nil
    self.thinking = false
    if self.board_view then self.board_view:onCloseWidget() end
    if self.status_widget then self.status_widget:free() end
    if self.history_widget then self.history_widget:free() end
    -- The board filled the screen, so leave a clean panel behind.
    UIManager:setDirty(nil, "full")
end

--- Pause a running search when KOReader suspends, so the device can sleep.
function ChessWidget:onSuspend()
    self:cancelSearch()
    self:saveGame()
end

return ChessWidget
