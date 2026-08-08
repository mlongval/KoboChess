--[[--
The chessboard itself: an 8x8 grid painted straight into the blitbuffer.

Everything here is drawn rather than composed out of KOReader widgets. Sixty-
four widgets would be a lot of objects to lay out on every repaint, and the
board needs pixel-exact square boundaries so taps map to squares without
rounding drift.

The piece images are the one exception -- they are ImageWidgets, created once
per piece type and painted repeatedly at different positions.

@module kobochess.boardview
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local ImageWidget = require("ui/widget/imagewidget")
local RenderImage = require("ui/renderimage")
local TextWidget = require("ui/widget/textwidget")
local Widget = require("ui/widget/widget")
local logger = require("logger")

local Board = require("kobochess.board")

local Screen = Device.screen

-- Square shades. Light squares are left white and dark squares are a mid grey
-- that stays clearly distinct from both piece colours on a greyscale panel.
--
-- Night mode inverts the whole screen on its way to the panel, so everything
-- the board draws is pre-inverted to survive the trip: a chessboard has to
-- keep its light and dark squares to be a chessboard at all, and inverting it
-- along with the UI chrome would leave both square shades nearly black.
local SQUARES = {
    [false] = {           -- normal
        light = Blitbuffer.COLOR_WHITE,
        dark = Blitbuffer.COLOR_GRAY_B,
        ink = Blitbuffer.COLOR_BLACK,
        mute = Blitbuffer.COLOR_DARK_GRAY,
    },
    [true] = {            -- night mode: the inverse of the above
        light = Blitbuffer.COLOR_BLACK,
        dark = Blitbuffer.COLOR_GRAY_4,
        ink = Blitbuffer.COLOR_WHITE,
        mute = Blitbuffer.COLOR_LIGHT_GRAY,
    },
}

local BoardView = Widget:extend{
    board = nil,             -- the Board being displayed
    size = nil,              -- total edge length in pixels; a multiple of 8
    flipped = false,         -- true to view from Black's side
    piece_dir = nil,         -- directory holding the piece PNGs

    selected = nil,          -- 0x88 square the player has picked up, or nil
    targets = nil,           -- set of 0x88 squares that selection can move to
    -- Two humans sitting across a table from each other: the far player's
    -- pieces are drawn upside down so they read the right way up from where
    -- that player is sitting.
    rotate_far_side = false,
    last_from = nil,         -- previous move, highlighted so it is easy to see
    last_to = nil,
    check_square = nil,      -- king in check, if any
    show_coordinates = true,
}

local PIECE_FILE = {
    [Board.PAWN] = "p", [Board.KNIGHT] = "n", [Board.BISHOP] = "b",
    [Board.ROOK] = "r", [Board.QUEEN] = "q", [Board.KING] = "k",
}

function BoardView:init()
    self.night_mode = Screen.night_mode and true or false
    self.palette = SQUARES[self.night_mode]

    self.square = math.floor(self.size / 8)
    self.size = self.square * 8
    self.dimen = Geom:new{ x = 0, y = 0, w = self.size, h = self.size }
    self.targets = self.targets or {}

    -- Pieces are inset slightly so they do not touch the square edges.
    self.piece_size = math.floor(self.square * 0.90)
    self.piece_inset = math.floor((self.square - self.piece_size) / 2)

    self:loadPieces()

    self:buildCoordinateLabels()
end

--- Build the file and rank labels.
-- Done once rather than per repaint: the text never changes, and rebuilding
-- sixteen TextWidgets each time would re-shape static text sixteen times.
function BoardView:buildCoordinateLabels()
    if not self.show_coordinates then return end
    self:freeCoordinateLabels()
    local face = Font:getFace("xx_smallinfofont",
                              math.max(10, math.floor(self.square / 9)))
    self.file_labels, self.rank_labels = {}, {}
    for i = 0, 7 do
        self.file_labels[i] = TextWidget:new{
            text = string.char(97 + i), face = face, fgcolor = self.palette.ink,
        }
        self.rank_labels[i] = TextWidget:new{
            text = tostring(i + 1), face = face, fgcolor = self.palette.ink,
        }
    end
end

function BoardView:freeCoordinateLabels()
    for _, labels in ipairs({ self.file_labels or {}, self.rank_labels or {} }) do
        for _, label in pairs(labels) do label:free() end
    end
    self.file_labels, self.rank_labels = nil, nil
end

--- Build one ImageWidget per piece, sized to the square.
--
-- The images are loaded by hand rather than by handing ImageWidget a filename,
-- because of how it treats night mode: it inverts the piece's whole bounding
-- rectangle, transparent margins included, which paints a visible inverted box
-- of board around every piece. Inverting the blitbuffer instead sets a flag
-- that the blit honours per pixel, so the transparent parts stay transparent.
function BoardView:loadPieces()
    self.piece_widgets = {}
    self.piece_paths = {}
    for colour = Board.WHITE, Board.BLACK do
        local prefix = (colour == Board.WHITE) and "w" or "b"
        for ptype, letter in pairs(PIECE_FILE) do
            local piece = colour * 8 + ptype
            local path = self.piece_dir .. "/" .. prefix .. letter .. ".png"
            self.piece_paths[piece] = path
            local bb = RenderImage:renderImageFile(path, false,
                                                   self.piece_size, self.piece_size)
            if bb then
                if self.night_mode then bb:invert() end
                self.piece_widgets[piece] = ImageWidget:new{
                    image = bb,
                    image_disposable = true,
                    alpha = true,      -- the PNGs are transparent outside the piece
                    -- Night mode is handled above; ImageWidget must not also
                    -- try, or the box comes back.
                    original_in_nightmode = false,
                }
            else
                logger.warn("KoboChess: could not load piece image", path)
                self.piece_widgets[piece] = ImageWidget:new{
                    file = path,
                    width = self.piece_size,
                    height = self.piece_size,
                    scale_factor = 0,
                    alpha = true,
                    original_in_nightmode = false,
                    file_do_cache = true,
                }
            end
        end
    end
end

--- Which colour is drawn at the top of the screen, and so belongs to the
-- player sitting on the far side.
function BoardView:farColour()
    return self.flipped and Board.WHITE or Board.BLACK
end

--- The widget to draw a piece with, upside down if it belongs to the far
-- player. Rotated copies are made on demand and cached: only one side ever
-- needs them, and building all twelve up front would double the memory the
-- board holds in images for nothing.
function BoardView:widgetFor(piece)
    if not self.rotate_far_side
       or math.floor(piece / 8) ~= self:farColour() then
        return self.piece_widgets[piece]
    end

    self.rotated_widgets = self.rotated_widgets or {}
    local cached = self.rotated_widgets[piece]
    if cached then return cached end

    local path = self.piece_paths and self.piece_paths[piece]
    if not path then return self.piece_widgets[piece] end

    -- Rendered afresh rather than rotating the blitbuffer the upright widget
    -- is using: night mode marks that one with an inversion flag, and copying
    -- through it would bake the inversion in and then invert it a second time.
    local source = RenderImage:renderImageFile(path, false,
                                               self.piece_size, self.piece_size)
    if not source then return self.piece_widgets[piece] end

    local rotated = source:rotatedCopy(180)
    source:free()
    if self.night_mode then rotated:invert() end

    local widget = ImageWidget:new{
        image = rotated,
        image_disposable = true,
        alpha = true,
        original_in_nightmode = false,
    }
    self.rotated_widgets[piece] = widget
    return widget
end

function BoardView:freeRotatedWidgets()
    for _, widget in pairs(self.rotated_widgets or {}) do
        widget:free()
    end
    self.rotated_widgets = nil
end

--- Swap to a different set of piece images.
-- Returns true if anything changed, so the caller knows whether to repaint.
function BoardView:setPieceDir(dir)
    if dir == self.piece_dir then return false end
    self.piece_dir = dir
    self:freePieceWidgets()
    self:loadPieces()
    return true
end

function BoardView:freePieceWidgets()
    for _, widget in pairs(self.piece_widgets or {}) do
        widget:free()
    end
    self.piece_widgets = nil
    self:freeRotatedWidgets()
end

--- Rebuild the coordinate labels after `show_coordinates` has been changed.
function BoardView:setShowCoordinates(show)
    show = show and true or false
    if show == self.show_coordinates then return false end
    self.show_coordinates = show
    if show then
        self:buildCoordinateLabels()
    else
        self:freeCoordinateLabels()
    end
    return true
end

--- Rebuild if night mode has been toggled since the pieces were loaded.
-- Returns true if anything changed.
function BoardView:syncNightMode()
    local night = Screen.night_mode and true or false
    if night == self.night_mode then return false end
    self.night_mode = night
    self.palette = SQUARES[night]
    self:freePieceWidgets()
    self:loadPieces()
    self:buildCoordinateLabels()      -- their colour changes too
    return true
end

function BoardView:getSize()
    return Geom:new{ w = self.size, h = self.size }
end

--==========================================================================
-- Geometry
--==========================================================================

--- Top-left pixel of a 0x88 square, relative to the board's origin.
function BoardView:squareOrigin(sq)
    local file = Board.fileOf(sq)
    local rank = Board.rankOf(sq)
    local col = self.flipped and (7 - file) or file
    -- Rank 8 is drawn at the top when viewing as White.
    local row = self.flipped and rank or (7 - rank)
    return col * self.square, row * self.square
end

--- The 0x88 square at a point relative to the board's origin, or nil.
function BoardView:squareAt(x, y)
    if x < 0 or y < 0 or x >= self.size or y >= self.size then return nil end
    local col = math.floor(x / self.square)
    local row = math.floor(y / self.square)
    local file = self.flipped and (7 - col) or col
    local rank = self.flipped and row or (7 - row)
    return rank * 16 + file
end

--- Screen-space rectangle of a square, for targeted refreshes.
function BoardView:squareRect(sq)
    local ox, oy = self:squareOrigin(sq)
    return Geom:new{
        x = (self.dimen.x or 0) + ox,
        y = (self.dimen.y or 0) + oy,
        w = self.square,
        h = self.square,
    }
end

--==========================================================================
-- Painting
--==========================================================================

function BoardView:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local sqs = self.square

    for rank = 0, 7 do
        for file = 0, 7 do
            local sq = rank * 16 + file
            local ox, oy = self:squareOrigin(sq)
            local px, py = x + ox, y + oy

            -- a1 is dark, so a square is light when file+rank is odd.
            local is_light = ((file + rank) % 2 == 1)
            bb:paintRect(px, py, sqs, sqs,
                         is_light and self.palette.light or self.palette.dark)

            self:paintSquareMarks(bb, px, py, sq, is_light)

            local piece = self.board.sq[sq]
            if piece ~= Board.EMPTY then
                local widget = self:widgetFor(piece)
                if widget then
                    widget:paintTo(bb, px + self.piece_inset, py + self.piece_inset)
                end
            end
        end
    end

    if self.show_coordinates then
        self:paintCoordinates(bb, x, y)
    end

    -- A border around the whole board, so it reads as an object rather than
    -- as a grey pattern running off the page.
    bb:paintBorder(x, y, self.size, self.size, Screen:scaleBySize(2),
                   self.palette.ink)
end

--- Highlights drawn under the piece: selection, legal targets, last move, check.
function BoardView:paintSquareMarks(bb, px, py, sq, is_light)
    local sqs = self.square
    local ink = self.palette.ink

    -- The square the previous move came from and went to. Drawn as a thin
    -- inset frame, which survives an e-ink partial refresh better than a wash
    -- of grey behind the piece.
    if sq == self.last_from or sq == self.last_to then
        local bw = Screen:scaleBySize(3)
        bb:paintBorder(px + bw, py + bw, sqs - 2 * bw, sqs - 2 * bw, bw,
                       self.palette.mute)
    end

    -- The piece the player has picked up: a heavy frame, unmistakable.
    if sq == self.selected then
        local bw = Screen:scaleBySize(5)
        bb:paintBorder(px, py, sqs, sqs, bw, ink)
    end

    -- Where that piece may legally go.
    if self.targets[sq] then
        local occupied = (self.board.sq[sq] ~= Board.EMPTY)
        if occupied then
            -- A capture: ring the square rather than covering the piece.
            local bw = Screen:scaleBySize(4)
            bb:paintBorder(px + bw, py + bw, sqs - 2 * bw, sqs - 2 * bw, bw, ink)
        else
            -- An empty destination: a dot in the middle.
            bb:paintCircle(px + math.floor(sqs / 2), py + math.floor(sqs / 2),
                           math.floor(sqs / 9), ink)
        end
    end

    -- A king in check gets a hatched square, distinguishable from the frames
    -- above without relying on colour.
    if sq == self.check_square then
        local bw = Screen:scaleBySize(5)
        bb:paintBorder(px, py, sqs, sqs, bw, ink)
        bb:paintBorder(px + bw * 2, py + bw * 2, sqs - bw * 4, sqs - bw * 4,
                       Screen:scaleBySize(2), ink)
    end
end

--- File letters along the bottom, rank numbers up the left.
function BoardView:paintCoordinates(bb, x, y)
    local pad = Screen:scaleBySize(4)
    for i = 0, 7 do
        -- `i` walks the board in screen order; which file/rank that is
        -- depends on which way round the board is being viewed.
        local file = self.flipped and (7 - i) or i
        local rank = self.flipped and i or (7 - i)

        local file_label = self.file_labels[file]
        local fs = file_label:getSize()
        file_label:paintTo(bb,
            x + i * self.square + self.square - fs.w - pad,
            y + self.size - fs.h - pad)

        self.rank_labels[rank]:paintTo(bb, x + pad, y + i * self.square + pad)
    end
end

--==========================================================================
-- State changes
--==========================================================================

--- Select a square and compute where its piece may go.
-- Returns the list of squares that changed, so the caller can refresh only
-- those instead of the whole board.
function BoardView:setSelected(sq)
    local changed = {}
    for old in pairs(self.targets) do changed[#changed + 1] = old end
    if self.selected then changed[#changed + 1] = self.selected end

    self.selected = sq
    self.targets = {}

    if sq then
        changed[#changed + 1] = sq
        local moves = {}
        local n = self.board:generateMoves(moves)
        for i = 1, n do
            local m = moves[i]
            if Board.moveFrom(m) == sq then
                local to = Board.moveTo(m)
                self.targets[to] = true
                changed[#changed + 1] = to
            end
        end
    end
    return changed
end

--- Update the last-move and check highlights from the current position.
function BoardView:setLastMove(move)
    local changed = {}
    if self.last_from then changed[#changed + 1] = self.last_from end
    if self.last_to then changed[#changed + 1] = self.last_to end
    if self.check_square then changed[#changed + 1] = self.check_square end

    if move then
        self.last_from, self.last_to = Board.moveFrom(move), Board.moveTo(move)
        changed[#changed + 1] = self.last_from
        changed[#changed + 1] = self.last_to
    else
        self.last_from, self.last_to = nil, nil
    end

    self.check_square = nil
    if self.board:inCheck() then
        self.check_square = self.board.kingsq[self.board.side]
        changed[#changed + 1] = self.check_square
    end
    return changed
end

function BoardView:onCloseWidget()
    self:freePieceWidgets()
    self:freeCoordinateLabels()
end

return BoardView
