--[[--
A short explanation the first time a button is used: title, text, a "Do not
show this again" check box and OK. The texts are in chesshelptext.lua; the
"do not show" choice is kept per button in the plugin's settings
(help_hidden_<key>), and "Show explanations again" in the device menu
clears them all.

(Named chesshelpdialog rather than helpdialog: KOReader plugins share one
module namespace, and another app's helpdialog would otherwise be found
first.)

@module kobochess.chesshelpdialog
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local CheckButton = require("ui/widget/checkbutton")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local InputContainer = require("ui/widget/container/inputcontainer")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("gettext")
local Screen = Device.screen

local HelpDialog = InputContainer:extend{
    title = nil,
    text = nil,
    on_ok = nil, -- function(dont_show_again)
    modal = true,
}

function HelpDialog:init()
    local w = math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * 0.85)
    local pad = Size.padding.large
    local inner = w - 2 * pad - 2 * Size.border.window
    self.check = CheckButton:new{
        text = _("Do not show this again"),
        width = inner,
        parent = self,
        show_parent = self,
    }
    local ok = Button:new{
        text = _("OK"),
        width = math.floor(inner / 2),
        show_parent = self,
        callback = function() self:done() end,
    }
    local big = Size.span.vertical_large * 2
    self.frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.window,
        radius = Size.radius.window,
        padding = pad,
        VerticalGroup:new{
            align = "left",
            TextWidget:new{ text = self.title, face = Font:getFace("tfont"), bold = true, max_width = inner },
            VerticalSpan:new{ width = big },
            TextBoxWidget:new{ text = self.text, face = Font:getFace("infofont"), width = inner },
            VerticalSpan:new{ width = big },
            self.check,
            VerticalSpan:new{ width = big },
            CenterContainer:new{ dimen = Geom:new{ w = inner, h = ok:getSize().h }, ok },
        },
    }
    self[1] = CenterContainer:new{
        dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() },
        self.frame,
    }
end

function HelpDialog:done()
    UIManager:close(self)
    if self.on_ok then self.on_ok(self.check.checked) end
end

function HelpDialog:onClose()
    self:done()
    return true
end

local HELP_PREFIX = "help_hidden_"

--- Run after() at once, or after the button's explanation the first time.
-- `seen` is a table the caller keeps for the session, so an explanation
-- dismissed without the check box is not shown again until next time.
function HelpDialog.explainOnce(owner, settings, seen, key, after)
    local HELP = require("chesshelptext")
    local help = HELP[key]
    if not help or seen[key] or (settings and settings:isTrue(HELP_PREFIX .. key)) then
        return after()
    end
    seen[key] = true
    UIManager:show(HelpDialog:new{
        title = help.title,
        text = help.text,
        on_ok = function(hide)
            if hide and settings then
                settings:saveSetting(HELP_PREFIX .. key, true)
                settings:flush()
            end
            -- the dialog leaves its outline on the panel: clean it off
            UIManager:setDirty(owner, "full")
            after()
        end,
    }, "ui")
end

--- Every explanation shows again.
function HelpDialog.resetAll(settings)
    if not settings then return end
    for key in pairs(settings.data) do
        if type(key) == "string" and key:sub(1, #HELP_PREFIX) == HELP_PREFIX then
            settings:delSetting(key)
        end
    end
    settings:flush()
end

return HelpDialog
