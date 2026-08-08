--[[--
Kobo Chess — play chess against an engine, inside KOReader.

This module is only the entry point: it registers the menu item and the
gesture action, restores the saved game, and opens the board. Everything of
substance lives in `chesswidget.lua` (the UI) and `kobochess/` (the engine).

@module koplugin.KoboChess
--]]--

local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local LuaSettings = require("luasettings")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("gettext")

local Game = require("kobochess.game")

-- Touching this file and starting KOReader opens straight into the board.
-- That is what the NickelMenu entry does, so Chess can be launched from the
-- Kobo home screen without going through KOReader's menus.
local AUTOSTART_FLAG = "kobochess_autostart"

local KoboChess = WidgetContainer:extend{
    name = "kobochess",
    is_doc_only = false,
}

function KoboChess:onDispatcherRegisterActions()
    Dispatcher:registerAction("kobochess_open", {
        category = "none",
        event = "KoboChessOpen",
        title = _("Chess"),
        general = true,
    })
end

function KoboChess:init()
    self:onDispatcherRegisterActions()
    self.settings_path = DataStorage:getSettingsDir() .. "/kobochess.lua"
    self.ui.menu:registerToMainMenu(self)

    -- Opening the board from inside init() would run before the UI is ready,
    -- so defer it by a tick.
    if self:consumeAutostartFlag() then
        UIManager:nextTick(function() self:openChess() end)
    end
end

function KoboChess:addToMainMenu(menu_items)
    menu_items.kobochess = {
        text = _("Chess"),
        sorting_hint = "more_tools",
        callback = function() self:openChess() end,
    }
end

function KoboChess:onKoboChessOpen()
    self:openChess()
    return true
end

--- Check for, and clear, the autostart flag written by the NickelMenu entry.
function KoboChess:consumeAutostartFlag()
    local flag = DataStorage:getSettingsDir() .. "/" .. AUTOSTART_FLAG
    if lfs.attributes(flag, "mode") ~= "file" then
        return false
    end
    -- Removed immediately so a crash cannot leave the device stuck opening
    -- the board on every launch.
    os.remove(flag)
    return true
end

--- Load the saved game, or start a fresh one if there is nothing usable.
function KoboChess:loadGame(settings)
    local saved = settings:readSetting("game")
    if saved then
        local game = Game.fromTable(saved)
        if game then return game end
        logger.warn("KoboChess: saved game could not be restored, starting a new one")
    end
    return Game.new{ level = settings:readSetting("level") or 4 }
end

function KoboChess:openChess()
    if self.chess_widget then return end

    local settings = LuaSettings:open(self.settings_path)
    local game = self:loadGame(settings)

    -- Required lazily: pulling in the engine and the board view costs time and
    -- memory that a user who never opens Chess should not pay.
    local ChessWidget = require("chesswidget")

    self.chess_widget = ChessWidget:new{
        game = game,
        settings = settings,
        plugin_path = self.path,
        on_close = function()
            self.chess_widget = nil
        end,
    }
    UIManager:show(self.chess_widget)
end

return KoboChess
