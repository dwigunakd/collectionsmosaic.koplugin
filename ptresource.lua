local DataStorage = require("datastorage")
local ffiUtil = require("ffi/util")
local logger = require("logger")
local util = require("util")

local Resource = {}

function Resource.getPluginDir()
    local caller_source = debug.getinfo(2, "S").source
    if caller_source:find("^@") then
        return caller_source:gsub("^@(.*)/[^/]*", "%1")
    end
end

function Resource.installIcons()
    local icons_path = DataStorage:getDataDir() .. "/icons"
    local icons = {
        "favorites",
        "go_up",
        "hero",
        "history",
        "last_document",
        "plus",
    }

    if not util.directoryExists(icons_path) and not util.makePath(icons_path .. "/") then
        return false
    end

    local plugin_dir = Resource.getPluginDir()
    local copied_any = false
    for _, icon in ipairs(icons) do
        local target = icons_path .. "/" .. icon .. ".svg"
        local source = plugin_dir .. "/icons/" .. icon .. ".svg"
        if util.fileExists(source) and not util.fileExists(target) then
            ffiUtil.copyFile(source, target)
            copied_any = true
        end
    end

    if copied_any then
        package.loaded["ui/widget/iconwidget"] = nil
        package.loaded["ui/widget/iconbutton"] = nil
        logger.info("CollectionsView plugin: installed shared icons")
    end
    return true
end

return Resource
