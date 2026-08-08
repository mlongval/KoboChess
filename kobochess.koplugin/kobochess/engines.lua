--[[--
Which engines are available, and how to build one.

The built-in Lua engine is always there. External UCI engines are found the
same way piece sets are: a folder each under `engines/`, so installing one is
a matter of dropping it in rather than changing any code. That also keeps
Stockfish -- which is GPL, and far too large to commit -- out of the
repository while still letting it be installed on a device.

    engines/
      stockfish/
        engine            the executable (any name; the executable bit is
                          what identifies it)
        nn-....nnue       its network, if it needs one

@module kobochess.engines
--]]--

local lfs = require("libs/libkoreader-lfs")

local Engines = {}

--- The identifier of the built-in engine. Stored in settings, so it must not
-- change; an external engine is identified by its folder name, and "lua" is
-- reserved so the two can never collide.
Engines.BUILTIN = "lua"

--- Turn a folder name into something to put on a menu.
local function prettyName(name)
    local text = name:gsub("[-_]", " ")
    return (text:gsub("^%l", string.upper))
end

--- Does this look like something we can execute?
-- A network file sits in the same folder and is much the larger of the two,
-- so the executable bit is what tells them apart.
local function isExecutable(path)
    local mode = lfs.attributes(path, "mode")
    if mode ~= "file" then return false end
    local permissions = lfs.attributes(path, "permissions") or ""
    return permissions:match("x") ~= nil
end

--- Look inside one engine folder. Returns the executable and its network.
local function inspect(dir)
    local exe, net
    local ok, iter, dir_obj = pcall(lfs.dir, dir)
    if not ok then return nil end
    for entry in iter, dir_obj do
        if entry ~= "." and entry ~= ".." then
            local path = dir .. "/" .. entry
            if entry:match("%.nnue$") then
                net = net or path
            elseif not exe and isExecutable(path) then
                exe = path
            end
        end
    end
    return exe, net
end

--- Everything that can be played against, built-in first.
--
-- Each entry is { id, name, kind, path, net }. The list is what the Options
-- menu shows, so an engine that is installed but broken still appears -- it
-- is better to offer it and report the failure than to hide it and leave
-- somebody wondering why the folder they created did nothing.
function Engines.list(root)
    local found = {
        { id = Engines.BUILTIN, name = "Built-in", kind = "lua" },
    }

    local ok, iter, dir_obj = pcall(lfs.dir, root)
    if not ok then return found end

    local names = {}
    for entry in iter, dir_obj do
        if entry ~= "." and entry ~= ".."
           and lfs.attributes(root .. "/" .. entry, "mode") == "directory" then
            names[#names + 1] = entry
        end
    end
    table.sort(names)

    for _, name in ipairs(names) do
        local exe, net = inspect(root .. "/" .. name)
        if exe then
            found[#found + 1] = {
                id = name,
                name = prettyName(name),
                kind = "uci",
                path = exe,
                net = net,
            }
        end
    end
    return found
end

--- The descriptor with this id, or the built-in one if it has gone.
function Engines.find(list, id)
    for _, descriptor in ipairs(list) do
        if descriptor.id == id then return descriptor end
    end
    return list[1]
end

--- Build a live engine from a descriptor.
function Engines.create(descriptor, opts)
    opts = opts or {}
    opts.name = descriptor.name
    if descriptor.kind == "uci" then
        local UciEngine = require("kobochess.engine_uci")
        opts.path = descriptor.path
        opts.net = descriptor.net
        return UciEngine.new(opts)
    end
    local LuaEngine = require("kobochess.engine_lua")
    return LuaEngine.new(opts)
end

return Engines
