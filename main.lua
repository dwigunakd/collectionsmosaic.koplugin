local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Blitbuffer = require("ffi/blitbuffer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local AlphaContainer = require("ui/widget/container/alphacontainer")
local Screen = require("device").screen
local ffiUtil = require("ffi/util")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local logger = require("logger")
local OverlapGroup = require("ui/widget/overlapgroup")
local RightContainer = require("ui/widget/container/rightcontainer")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local _ = require("gettext")
local BD = require("ui/bidi")
local TopContainer = require("ui/widget/container/topcontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local lfs = require("libs/libkoreader-lfs")

local CollectionsView = WidgetContainer:extend{
    name = "zcollectionsview",
    is_doc_only = false,
}

local patched = false
local SETTINGS_ROOT_LABEL = "zcollectionsview_root_label"
local SETTINGS_LABEL_POSITION = "zcollectionsview_label_position"
local SETTINGS_LABEL_FONT_SIZE = "zcollectionsview_label_font_size"
local SETTINGS_SORT_MODE = "zcollectionsview_sort_mode"
local SETTINGS_FOLDER_SORT_MODE = "zcollectionsview_folder_sort_mode"
local SETTINGS_HIDE_UNDERLINE = "zcollectionsview_hide_underline"

local function getHideUnderlineSetting()
    if not G_reader_settings then
        return true
    end
    local value = G_reader_settings:readSetting(SETTINGS_HIDE_UNDERLINE)
    if value == nil then
        return true
    end
    return value
end

local function installCollectionsViewPlugin()
    if patched then
        return
    end
    patched = true

    local FileChooser = require("ui/widget/filechooser")
    local FileManagerCollection = require("apps/filemanager/filemanagercollection")
    local ReadCollection = require("readcollection")
    local UIManager = require("ui/uimanager")
    local filemanagerutil = require("apps/filemanager/filemanagerutil")
    local util = require("util")
    local BookInfoManager = require("bookinfomanager")
    local T = ffiUtil.template

    local COLLECTIONS_SYMBOL = "\u{272A}"
    local COLLECTIONS_SEGMENT = COLLECTIONS_SYMBOL .. " " .. _("Collections")
    local COVER_OVERRIDE_KEY = "navbar_collections_covers"
    local FOLDER_COVER_NAME = ".cover"
    local FOLDER_COVER_EXTS = { ".jpg", ".jpeg", ".png", ".webp", ".gif" }
    local DIR_COVER_CACHE_MAX = 96
    local IMAGE_DIM_CACHE_MAX = 48
    local SHOW_FAVORITES_COLLECTION = true
    local SIMPLEUI_EDGE_H1 = 0.97
    local SIMPLEUI_EDGE_H2 = 0.94
    local SIMPLEUI_FC_SHOW_NAME = "simpleui_fc_show_name"
    local SIMPLEUI_FC_LABEL_STYLE = "simpleui_fc_label_style"
    local SIMPLEUI_FC_LABEL_POSITION = "simpleui_fc_label_position"
    local SIMPLEUI_FC_LABEL_MODE = "simpleui_fc_label_mode"
    local SIMPLEUI_BASE_COVER_H = math.floor(Screen:scaleBySize(96))
    local SIMPLEUI_BASE_DIR_FS = Screen:scaleBySize(5)
    local SIMPLEUI_EDGE_THICK = math.max(1, Screen:scaleBySize(3))
    local SIMPLEUI_EDGE_MARGIN = math.max(1, Screen:scaleBySize(1))
    local SIMPLEUI_SPINE_W = SIMPLEUI_EDGE_THICK * 2 + SIMPLEUI_EDGE_MARGIN * 2
    local SIMPLEUI_SPINE_COLOR = Blitbuffer.gray(0.70)
    local SIMPLEUI_LATERAL_PAD = Screen:scaleBySize(10)
    local SIMPLEUI_VERTICAL_PAD = Screen:scaleBySize(4)
    local SIMPLEUI_LABEL_ALPHA = 0.75
    local dir_cover_cache = {}
    local dir_cover_cache_order = {}
    local image_dim_cache = {}
    local image_dim_cache_order = {}

    local function getDirPathMtime(dir_path)
        if not dir_path then
            return nil
        end
        local attr = lfs.attributes(dir_path)
        return attr and attr.modification or nil
    end

    local function pruneDirCoverCache()
        while #dir_cover_cache_order > DIR_COVER_CACHE_MAX do
            local oldest = table.remove(dir_cover_cache_order, 1)
            dir_cover_cache[oldest] = nil
        end
    end

    local function storeDirCoverCache(dir_path, mtime, cover_file)
        if not dir_path or not cover_file then
            return cover_file
        end
        if not dir_cover_cache[dir_path] then
            dir_cover_cache_order[#dir_cover_cache_order + 1] = dir_path
        end
        dir_cover_cache[dir_path] = {
            modification = mtime,
            cover_file = cover_file,
        }
        pruneDirCoverCache()
        return cover_file
    end

    local function getCachedDirCover(dir_path)
        local mtime = getDirPathMtime(dir_path)
        local cached = dir_cover_cache[dir_path]
        if cached and cached.modification == mtime then
            return true, cached.cover_file or nil
        end
        return false, mtime
    end

    local function pruneImageDimCache()
        while #image_dim_cache_order > IMAGE_DIM_CACHE_MAX do
            local oldest = table.remove(image_dim_cache_order, 1)
            image_dim_cache[oldest] = nil
        end
    end

    local function getCachedImageDimensions(filepath)
        if not filepath then
            return nil, nil
        end
        local attr = lfs.attributes(filepath)
        local mtime = attr and attr.modification or nil
        local cached = image_dim_cache[filepath]
        if cached and cached.modification == mtime then
            return cached.w, cached.h
        end

        local ok, w, h = pcall(function()
            local probe = ImageWidget:new{
                file = filepath,
                scale_factor = 1,
            }
            probe:_render()
            local orig_w = probe:getOriginalWidth()
            local orig_h = probe:getOriginalHeight()
            probe:free()
            return orig_w, orig_h
        end)
        if not ok or not w or not h or w <= 0 or h <= 0 then
            return nil, nil
        end

        if not image_dim_cache[filepath] then
            image_dim_cache_order[#image_dim_cache_order + 1] = filepath
        end
        image_dim_cache[filepath] = {
            modification = mtime,
            w = w,
            h = h,
        }
        pruneImageDimCache()
        return w, h
    end

    local function escapePattern(str)
        return str:gsub("([^%w])", "%%%1")
    end

    local COLLECTIONS_SEGMENT_PATTERN = escapePattern(COLLECTIONS_SEGMENT)

    local function encodeSegment(name)
        return (name:gsub("/", "\u{FF0F}"))
    end

    local function decodeSegment(segment)
        return (segment:gsub("\u{FF0F}", "/"))
    end

    local function appendPath(base, segment)
        if not base or base == "" then
            return segment
        end
        if base:sub(-1) == "/" then
            return base .. segment
        end
        return base .. "/" .. segment
    end

    local function normalizeVirtualPath(path)
        if not path or path == "" then
            return path
        end
        while path:len() > 1 and path:sub(-1) == "/" do
            path = path:sub(1, -2)
        end
        local leading_slash = path:sub(1, 1) == "/"
        local segments = {}
        for part in path:gmatch("[^/]+") do
            if part == ".." then
                table.remove(segments)
            elseif part ~= "." and part ~= "" then
                table.insert(segments, part)
            end
        end
        local result = table.concat(segments, "/")
        if leading_slash and result ~= "" then
            result = "/" .. result
        elseif leading_slash then
            result = "/"
        end
        return result
    end

    local function getHomeDir()
        return normalizeVirtualPath(
            (G_reader_settings and G_reader_settings:readSetting("home_dir"))
            or filemanagerutil.getDefaultDir()
        )
    end

    local function isHomePath(path)
        if not path then
            return false
        end
        local normalized_path = normalizeVirtualPath(path)
        local home_dir = getHomeDir()
        if normalized_path == home_dir then
            return true
        end
        local real_path = ffiUtil.realpath(path)
        if real_path then
            return normalizeVirtualPath(real_path) == home_dir
        end
        return false
    end

    local function containsCollectionsSegment(path)
        return path and path:find("/" .. COLLECTIONS_SEGMENT_PATTERN, 1, false)
    end

    local function isCollectionsRoot(path)
        return path and path:match("/" .. COLLECTIONS_SEGMENT_PATTERN .. "$")
    end

    local function getCollectionFromPath(path)
        if not path then
            return nil
        end
        local encoded = path:match("/" .. COLLECTIONS_SEGMENT_PATTERN .. "/(.+)$")
        if encoded then
            return decodeSegment(encoded)
        end
        return nil
    end

    local function getCollectionsRootPath(path)
        if not path then
            return nil
        end
        local root = path:match("^(.-/" .. COLLECTIONS_SEGMENT_PATTERN .. ")/.+$")
        if root then
            return root
        end
        if isCollectionsRoot(path) then
            return path
        end
        return nil
    end

    local function getVirtualParentPath(path)
        if not path or not containsCollectionsSegment(path) then
            return nil
        end
        local root = getCollectionsRootPath(path)
        if not root then
            return nil
        end
        if path == root then
            return getHomeDir()
        end
        return root
    end

    local function getEffectivePath(self, path)
        if self and self.name == "filemanager" and self._cb_virtual_path then
            return self._cb_virtual_path
        end
        return path
    end

    local function getCollectionLastAccessTime(collection)
        local max_access = 0
        for _, entry in pairs(collection) do
            if entry.attr and entry.attr.access and entry.attr.access > max_access then
                max_access = entry.attr.access
            end
        end
        return max_access
    end

    local function getCollectionItems(collection_name)
        local collection = ReadCollection.coll[collection_name]
        if not collection then
            return {}
        end

        local ordered = {}
        for _, entry in pairs(collection) do
            table.insert(ordered, entry)
        end

        local sort_mode = G_reader_settings and G_reader_settings:readSetting(SETTINGS_SORT_MODE) or "collection_order"
        local function getDisplay(entry)
            return (entry and (entry.text or (entry.file and entry.file:match("([^/]+)$")) or entry.file) or ""):lower()
        end
        local function getAttr(entry, key)
            return (entry and entry.attr and entry.attr[key]) or 0
        end
        local function compareWithFallback(a, b)
            local ao = type(a.order) == "number" and a.order or 0
            local bo = type(b.order) == "number" and b.order or 0
            if ao ~= bo then
                return ao < bo
            end
            local ad, bd = getDisplay(a), getDisplay(b)
            if ad ~= bd then
                return ad < bd
            end
            return tostring(a.file or "") < tostring(b.file or "")
        end

        table.sort(ordered, function(a, b)
            if sort_mode == "title_desc" then
                local ad, bd = getDisplay(a), getDisplay(b)
                if ad ~= bd then return ad > bd end
                return compareWithFallback(a, b)
            elseif sort_mode == "title_asc" then
                local ad, bd = getDisplay(a), getDisplay(b)
                if ad ~= bd then return ad < bd end
                return compareWithFallback(a, b)
            elseif sort_mode == "access_desc" then
                local aa, ba = getAttr(a, "access"), getAttr(b, "access")
                if aa ~= ba then return aa > ba end
                return compareWithFallback(a, b)
            elseif sort_mode == "access_asc" then
                local aa, ba = getAttr(a, "access"), getAttr(b, "access")
                if aa ~= ba then return aa < ba end
                return compareWithFallback(a, b)
            elseif sort_mode == "modified_desc" then
                local ao = type(a.order) == "number" and a.order or 0
                local bo = type(b.order) == "number" and b.order or 0
                if ao ~= bo then return ao > bo end
                return compareWithFallback(a, b)
            elseif sort_mode == "modified_asc" then
                local ao = type(a.order) == "number" and a.order or 0
                local bo = type(b.order) == "number" and b.order or 0
                if ao ~= bo then return ao < bo end
                return compareWithFallback(a, b)
            end
            return compareWithFallback(a, b)
        end)
        return ordered
    end

    local function trimString(text)
        if type(text) ~= "string" then
            return nil
        end
        local trimmed = text:gsub("^%s+", ""):gsub("%s+$", "")
        if trimmed == "" then
            return nil
        end
        return trimmed
    end

    local function getCollectionsRootLabel()
        return trimString(G_reader_settings and G_reader_settings:readSetting(SETTINGS_ROOT_LABEL))
            or _("Collections")
    end

    local function getCollectionsDisplayText()
        return COLLECTIONS_SYMBOL .. " " .. getCollectionsRootLabel()
    end

    local function getCoverOverrides()
        return G_reader_settings and G_reader_settings:readSetting(COVER_OVERRIDE_KEY) or {}
    end

    local function isImageFilePath(filepath)
        if type(filepath) ~= "string" then
            return false
        end
        local lower_path = filepath:lower()
        for _, ext in ipairs(FOLDER_COVER_EXTS) do
            if lower_path:sub(-#ext) == ext then
                return true
            end
        end
        return false
    end

    local function hasUsableBookCover(filepath)
        if not filepath or not util.fileExists(filepath) then
            return false
        end
        if isImageFilePath(filepath) then
            return true
        end

        local bookinfo = BookInfoManager:getBookInfo(filepath, true)
        if not bookinfo or not bookinfo.cover_fetched or not bookinfo.has_cover or bookinfo.ignore_cover or not bookinfo.cover_bb then
            if bookinfo and bookinfo.cover_bb then
                bookinfo.cover_bb:free()
            end
            return false
        end
        return true
    end

    local function getCollectionCoverFile(collection_name)
        local overrides = getCoverOverrides()
        local override_path = overrides and overrides[collection_name]
        if type(override_path) == "string" and hasUsableBookCover(override_path) then
            return override_path
        end

        for _, entry in ipairs(getCollectionItems(collection_name)) do
            if entry.file and hasUsableBookCover(entry.file) then
                return entry.file
            end
        end
        return nil
    end

    local function getCollectionsRootCoverFile()
        local names = {}
        for name, _ in pairs(ReadCollection.coll) do
            if SHOW_FAVORITES_COLLECTION
                or name:lower() ~= ReadCollection.default_collection_name:lower() then
                table.insert(names, name)
            end
        end
        table.sort(names, function(a, b)
            return a:lower() < b:lower()
        end)

        for _, name in ipairs(names) do
            local cover_file = getCollectionCoverFile(name)
            if cover_file then
                return cover_file
            end
        end
        return nil
    end

    local function getCollectionPlaceholder(label)
        local text = (label or "?"):gsub("^%s+", ""):gsub("%s+$", "")
        if text == "" then
            return "?"
        end
        local initials = {}
        for word in text:gmatch("%S+") do
            table.insert(initials, word:sub(1, 1))
            if #initials == 2 then
                break
            end
        end
        if #initials == 0 then
            return text:sub(1, 2):upper()
        end
        return table.concat(initials, ""):upper()
    end

    local function findFolderCoverFile(dir_path)
        if not dir_path then
            return nil
        end
        local cover_base = appendPath(dir_path, FOLDER_COVER_NAME)
        for _, ext in ipairs(FOLDER_COVER_EXTS) do
            local candidate = cover_base .. ext
            if util.fileExists(candidate) then
                return candidate
            end
        end
        return nil
    end

    local function getDirectoryCoverFile(menu, entry)
        if not entry then
            return nil
        end
        if entry.is_collections_virtual then
            return entry.virtual_cover_file
        end
        if type(entry._zcv_cover_file) == "string" then
            return entry._zcv_cover_file
        end

        local dir_path = entry.path
        if not dir_path or not util.directoryExists(dir_path) then
            return nil
        end

        local cached, cached_value = getCachedDirCover(dir_path)
        if cached then
            entry._zcv_cover_file = cached_value
            return cached_value
        end
        local dir_mtime = cached_value

        local custom_cover = findFolderCoverFile(dir_path)
        if custom_cover then
            entry._zcv_cover_file = custom_cover
            return storeDirCoverCache(dir_path, dir_mtime, custom_cover)
        end

        local iter, dir_obj = lfs.dir(dir_path)
        if not iter then
            return nil
        end

        for name in iter, dir_obj do
            if name ~= "." and name ~= ".." and not name:match("^%.cover%.") then
                local filepath = appendPath(dir_path, name)
                local attr = lfs.attributes(filepath)
                if attr and attr.mode == "file" then
                    local bookinfo = BookInfoManager:getBookInfo(filepath, true)
                    if bookinfo
                        and bookinfo.cover_fetched
                        and bookinfo.has_cover
                        and not bookinfo.ignore_cover
                        and bookinfo.cover_bb
                    then
                        entry._zcv_cover_file = filepath
                        return storeDirCoverCache(dir_path, dir_mtime, filepath)
                    end
                end
            end
        end

        return nil
    end

    local function getVirtualCoverImage(filepath, max_w, max_h)
        if not filepath then
            return nil
        end

        if isImageFilePath(filepath) then
            local orig_w, orig_h = getCachedImageDimensions(filepath)
            if not orig_w or not orig_h then
                return nil
            end
            local ok, image = pcall(function()
                local scale = math.max(max_w / orig_w, max_h / orig_h)
                return ImageWidget:new{
                    file = filepath,
                    scale_factor = scale,
                    width = max_w,
                    height = max_h,
                }
            end)
            if ok then
                image:_render()
                return image
            end
            return nil
        end

        local cover_specs = {
            max_cover_w = max_w,
            max_cover_h = max_h,
        }
        local bookinfo = BookInfoManager:getBookInfo(filepath, true)
        if not bookinfo or not bookinfo.cover_fetched or not bookinfo.has_cover or bookinfo.ignore_cover then
            if bookinfo and bookinfo.cover_bb then
                bookinfo.cover_bb:free()
            end
            return nil
        end
        if BookInfoManager.isCachedCoverInvalid(bookinfo, cover_specs) then
            if bookinfo.cover_bb then
                bookinfo.cover_bb:free()
            end
            return nil
        end

        local image = ImageWidget:new{
            image = bookinfo.cover_bb,
            image_disposable = false,
            width = max_w,
            height = max_h,
        }
        image:_render()
        return image
    end

    local function getSimpleUILabelMode()
        return G_reader_settings:readSetting(SIMPLEUI_FC_LABEL_MODE) or "overlay"
    end

    local function getSimpleUIShowName()
        return G_reader_settings:readSetting(SIMPLEUI_FC_SHOW_NAME) ~= false
    end

    local function getSimpleUILabelStyle()
        return G_reader_settings:readSetting(SIMPLEUI_FC_LABEL_STYLE) or "alpha"
    end

    local function getSimpleUILabelPosition()
        return (G_reader_settings and G_reader_settings:readSetting(SETTINGS_LABEL_POSITION))
            or G_reader_settings:readSetting(SIMPLEUI_FC_LABEL_POSITION)
            or "bottom"
    end

    local function getSimpleUILabelBaseFontSize()
        local configured = G_reader_settings and G_reader_settings:readSetting(SETTINGS_LABEL_FONT_SIZE)
        if type(configured) == "number" then
            return Screen:scaleBySize(configured)
        end
        return SIMPLEUI_BASE_DIR_FS
    end

    local function getTwoByThreeSlot(max_w, max_h)
        local slot_w = math.max(8, math.min(max_w, math.floor(max_h * 2 / 3)))
        local slot_h = math.max(8, math.floor(slot_w * 3 / 2))
        if slot_h > max_h then
            slot_h = max_h
            slot_w = math.max(8, math.floor(slot_h * 2 / 3))
        end
        return slot_w, slot_h
    end

    local function buildSimpleUILabelWidget(label, image_w, image_h, cv_scale)
        local text_width = math.max(20, image_w - SIMPLEUI_LATERAL_PAD * 2)
        local max_fs = math.max(8, math.floor(getSimpleUILabelBaseFontSize() * cv_scale))
        local min_fs = 8
        local fixed_font_size = BookInfoManager:getSetting("fixed_item_font_size")
        local font_size = max_fs
        local display_label = BD.directory(label)
        local max_lines = 3

        local function makeDisplayLabel(text)
            if G_reader_settings:nilOrTrue("use_xtext") then
                return text
                    :gsub("/", "/\u{200B}")
                    :gsub("_", "_\u{200B}")
                    :gsub("%-", "-\u{200B}")
                    :gsub("%.", ".\u{200B}")
            end
            return text
                :gsub("/", "/ ")
                :gsub("_", "_ ")
                :gsub("%-", "- ")
                :gsub("%.", ". ")
        end

        display_label = makeDisplayLabel(display_label)

        while true do
            local directory = TextBoxWidget:new{
                text = display_label,
                face = Font:getFace("cfont", font_size),
                width = text_width,
                alignment = "center",
                bold = true,
            }

            local line_height = directory.line_height_px or directory:getLineHeight()
            local line_count = math.max(1, math.ceil(directory:getSize().h / line_height))
            local fits = line_count <= max_lines and not directory.has_split_inside_word

            if fixed_font_size or font_size <= min_fs or fits then
                return directory
            end

            directory:free(true)
            font_size = font_size - 1
        end
    end

    local function buildSimpleUICollectionTile(tile_w, tile_h, cover_file, label, count)
        local border = Size.border.thin
        local max_img_w = math.max(8, tile_w - SIMPLEUI_SPINE_W - border * 2)
        local max_img_h = math.max(8, tile_h - border * 2)
        local slot_w, slot_h = getTwoByThreeSlot(max_img_w, max_img_h)

        local image = getVirtualCoverImage(cover_file, slot_w, slot_h)
        local cover_widget
        local image_w = slot_w
        local image_h = slot_h
        local has_cover = false
        if image then
            has_cover = true
            cover_widget = FrameContainer:new{
                width = image_w + border * 2,
                height = image_h + border * 2,
                margin = 0,
                padding = 0,
                bordersize = border,
                CenterContainer:new{
                    dimen = Geom:new{ w = image_w, h = image_h },
                    image,
                },
            }
        else
            cover_widget = FrameContainer:new{
                width = image_w + border * 2,
                height = image_h + border * 2,
                margin = 0,
                padding = 0,
                bordersize = border,
                background = Blitbuffer.gray(0.90),
                CenterContainer:new{
                    dimen = Geom:new{ w = image_w, h = image_h },
                    TextWidget:new{
                        text = getCollectionPlaceholder(label),
                        face = Font:getFace("cfont", math.max(14, math.floor(image_h / 4))),
                    },
                },
            }
        end

        local h1 = math.floor(image_h * SIMPLEUI_EDGE_H1)
        local h2 = math.floor(image_h * SIMPLEUI_EDGE_H2)
        local y1 = math.floor((image_h - h1) / 2)
        local y2 = math.floor((image_h - h2) / 2)

        local function edgeLine(h, y_off)
            local line = LineWidget:new{
                dimen = Geom:new{ w = SIMPLEUI_EDGE_THICK, h = h },
                background = SIMPLEUI_SPINE_COLOR,
            }
            line.overlap_offset = { 0, y_off }
            return OverlapGroup:new{
                dimen = Geom:new{ w = SIMPLEUI_EDGE_THICK, h = image_h },
                line,
            }
        end

        local cover_group = HorizontalGroup:new{
            align = "top",
            edgeLine(h2, y2),
            HorizontalSpan:new{ width = SIMPLEUI_EDGE_MARGIN },
            edgeLine(h1, y1),
            HorizontalSpan:new{ width = SIMPLEUI_EDGE_MARGIN },
            cover_widget,
        }
        local cover_w = SIMPLEUI_SPINE_W + image_w + border * 2
        local cover_h = image_h + border * 2
        local cover_dimen = Geom:new{ w = cover_w, h = cover_h }
        local cell_dimen = Geom:new{ w = tile_w, h = tile_h }
        local cv_scale = math.max(0.1, (math.floor((cover_h / SIMPLEUI_BASE_COVER_H) * 10) / 10))

        local overlap = OverlapGroup:new{ dimen = cover_dimen, cover_group }

        if getSimpleUILabelMode() == "overlay" and getSimpleUIShowName() then
            local directory = buildSimpleUILabelWidget(label, image_w, image_h, cv_scale)
            local frame = FrameContainer:new{
                padding = 0,
                padding_top = SIMPLEUI_VERTICAL_PAD,
                padding_bottom = SIMPLEUI_VERTICAL_PAD,
                padding_left = SIMPLEUI_LATERAL_PAD,
                padding_right = SIMPLEUI_LATERAL_PAD,
                bordersize = border,
                background = Blitbuffer.COLOR_WHITE,
                directory,
            }
            local label_inner = getSimpleUILabelStyle() == "alpha"
                and AlphaContainer:new{ alpha = SIMPLEUI_LABEL_ALPHA, frame }
                or frame
            local img_only = Geom:new{ w = image_w, h = image_h }
            local img_dimen = Geom:new{ w = image_w + border * 2, h = image_h + border * 2 }
            local name_og = OverlapGroup:new{ dimen = img_dimen }
            local pos = getSimpleUILabelPosition()
            if pos == "center" then
                name_og[1] = label_inner
                local label_size = label_inner:getSize()
                name_og[1].overlap_offset = {
                    math.floor((img_only.w - label_size.w) / 2),
                    math.floor((img_only.h - label_size.h) / 2),
                }
            elseif pos == "top" then
                name_og[1] = TopContainer:new{
                    dimen = img_dimen,
                    label_inner,
                    overlap_align = "center",
                }
            else
                name_og[1] = BottomContainer:new{
                    dimen = img_dimen,
                    label_inner,
                    overlap_align = "center",
                }
            end
            name_og.overlap_offset = { SIMPLEUI_SPINE_W, 0 }
            overlap[#overlap + 1] = name_og
        end

        local x_center = math.floor((tile_w - cover_w) / 2)
        local y_center = math.floor((tile_h - cover_h) / 2)
        overlap.overlap_offset = { x_center - math.floor(SIMPLEUI_SPINE_W / 2), y_center }

        return OverlapGroup:new{
            dimen = cell_dimen,
            overlap,
        }, has_cover
    end

    local function isDirectoryCoverEntry(entry)
        return entry
            and not entry.is_file
            and not entry.is_go_up
            and not entry.is_go_back
            and (
                entry.is_collections_virtual
                or entry.is_directory
                or (entry.path and util.directoryExists(entry.path))
            )
    end

    local function isVirtualCoverEntry(entry)
        return entry
            and entry.is_collections_virtual
            and not entry.is_file
            and not entry.is_go_up
            and not entry.is_go_back
    end

    local function replaceItemWidget(self, widget)
        if self._underline_container[1] then
            self._underline_container[1]:free()
        end
        self._underline_container[1] = widget
    end

    local function renderDirectoryMosaicItem(self)
        if not self.do_cover_image or not isDirectoryCoverEntry(self.entry) then
            return false
        end

        local dimen = Geom:new{
            w = self.width,
            h = self.height,
        }
        local label = self.entry.collection_label or (self.text and self.text:gsub("/$", "")) or ""
        local widget, has_cover = buildSimpleUICollectionTile(
            dimen.w,
            dimen.h,
            getDirectoryCoverFile(self.menu, self.entry),
            label,
            self.entry.virtual_count
        )

        self.is_directory = true
        self._has_cover_image = has_cover
        if has_cover then
            self.menu._has_cover_images = true
        end
        replaceItemWidget(self, widget)
        return true
    end

    local function paintVirtualCollectionMosaicItem(self, bb, x, y)
        InputContainer.paintTo(self, bb, x, y)

        if self.shortcut_icon then
            local ix
            if BD.mirroredUILayout() then
                ix = self.dimen.w - self.shortcut_icon.dimen.w
            else
                ix = 0
            end
            self.shortcut_icon:paintTo(bb, x + ix, y)
        end
    end

    local function getUpvalue(func, target_name)
        if type(func) ~= "function" then
            return nil
        end
        for i = 1, 32 do
            local name, value = debug.getupvalue(func, i)
            if not name then
                break
            end
            if name == target_name then
                return value
            end
        end
        return nil
    end

    local function patchCoverBrowserVirtualRenderers()
        local ok_mosaic, MosaicMenu = pcall(require, "mosaicmenu")
        if ok_mosaic and MosaicMenu and type(MosaicMenu._updateItemsBuildUI) == "function" then
            local MosaicMenuItem = getUpvalue(MosaicMenu._updateItemsBuildUI, "MosaicMenuItem")
            if MosaicMenuItem and not MosaicMenuItem._collectionsview_virtual_patch then
                MosaicMenuItem._collectionsview_virtual_patch = true
                local orig_update = MosaicMenuItem.update
                local orig_paint = MosaicMenuItem.paintTo
                local orig_onFocus = MosaicMenuItem.onFocus
                function MosaicMenuItem:update()
                    local result = orig_update(self)
                    if renderDirectoryMosaicItem(self) then
                        return result
                    end
                    return result
                end
                function MosaicMenuItem:onFocus(...)
                    local result = true
                    if orig_onFocus then
                        result = orig_onFocus(self, ...)
                    end
                    if self._underline_container then
                        self._underline_container.color = getHideUnderlineSetting()
                            and Blitbuffer.COLOR_WHITE
                            or Blitbuffer.COLOR_BLACK
                    end
                    return result
                end
                function MosaicMenuItem:paintTo(bb, x, y)
                    if isVirtualCoverEntry(self.entry) then
                        return paintVirtualCollectionMosaicItem(self, bb, x, y)
                    end
                    return orig_paint(self, bb, x, y)
                end
            end
        end
    end

    local function isHomescreenActive()
        local top_widget = UIManager:getTopmostVisibleWidget()
        return top_widget and top_widget.name == "homescreen"
    end

    local function countVisibleCollections()
        local count = 0
        for name, _ in pairs(ReadCollection.coll) do
            if SHOW_FAVORITES_COLLECTION
                or name:lower() ~= ReadCollection.default_collection_name:lower() then
                if util.tableSize(ReadCollection.coll[name]) > 0 then
                    count = count + 1
                end
            end
        end
        return count
    end

    local function getAllCollectionsLastAccessTime()
        local max_access = 0
        for name, coll in pairs(ReadCollection.coll) do
            if SHOW_FAVORITES_COLLECTION
                or name:lower() ~= ReadCollection.default_collection_name:lower() then
                if util.tableSize(coll) > 0 then
                    local coll_access = getCollectionLastAccessTime(coll)
                    if coll_access > max_access then
                        max_access = coll_access
                    end
                end
            end
        end
        return max_access
    end

    local function buildCollectionDirItems(self, path)
        local dirs = {}
        local collate = self:getCollate()
        for name, coll in pairs(ReadCollection.coll) do
            if not SHOW_FAVORITES_COLLECTION
                and name:lower() == ReadCollection.default_collection_name:lower() then
                goto continue
            end

            local count = util.tableSize(coll)
            if count == 0 then
                goto continue
            end
            local last_access = getCollectionLastAccessTime(coll)
            local entry = self:getListItem(nil, name, appendPath(path, encodeSegment(name)), {
                mode = "directory",
                size = count,
                modification = 0,
                access = last_access,
            }, collate)
            entry.is_directory = true
            entry.is_collections_virtual = true
            entry.collection_label = name
            entry.virtual_count = count
            entry.virtual_cover_file = getCollectionCoverFile(name)
            entry.mandatory = T("%1 \u{F016}", count)
            table.insert(dirs, entry)

            ::continue::
        end

        local folder_sort_mode = G_reader_settings and G_reader_settings:readSetting(SETTINGS_FOLDER_SORT_MODE) or "collection_order"
        table.sort(dirs, function(a, b)
            local an = (a.collection_label or a.text or ""):lower()
            local bn = (b.collection_label or b.text or ""):lower()
            local aa = (a.attr and a.attr.access) or a.access or 0
            local ba = (b.attr and b.attr.access) or b.access or 0
            local aorder = (ReadCollection.coll_settings[a.collection_label or ""] and ReadCollection.coll_settings[a.collection_label or ""].order) or math.huge
            local border = (ReadCollection.coll_settings[b.collection_label or ""] and ReadCollection.coll_settings[b.collection_label or ""].order) or math.huge

            if folder_sort_mode == "collection_order" and aorder ~= border then
                return aorder < border
            elseif folder_sort_mode == "title_desc" and an ~= bn then
                return an > bn
            elseif folder_sort_mode == "title_asc" and an ~= bn then
                return an < bn
            end

            if an ~= bn then
                return an < bn
            end
            return tostring(a.path or "") < tostring(b.path or "")
        end)
        return dirs
    end

    local function buildCollectionFileItems(self, path, collection_name)
        local files = {}
        local collection = ReadCollection.coll[collection_name]
        if not collection then
            return files
        end

        local collate = self:getCollate()
        for _, entry in ipairs(getCollectionItems(collection_name)) do
            local attributes = entry.attr or { mode = "file" }
            local display = entry.text or entry.file:match("([^/]+)$") or entry.file
            local item = self:getListItem(path, display, entry.file, attributes, collate)
            item.is_file = true
            item.is_collections_virtual = true
            table.insert(files, item)
        end
        return files
    end

    local saved_filemanager_mode = nil
    local currently_in_collections = false
    local active_virtual_display_mode = nil
    local last_virtual_path = nil
    local restoreFileManagerDisplayMode

    local function applyDisplayModeTemporarily(target_mode)
        if not target_mode then
            return
        end

        local FileManager = require("apps/filemanager/filemanager")
        if not FileManager.instance or not FileManager.instance.coverbrowser then
            return
        end

        local coverbrowser = FileManager.instance.coverbrowser
        local original_saved_setting = BookInfoManager:getSetting("filemanager_display_mode")
        coverbrowser:setupFileManagerDisplayMode(target_mode)
        if original_saved_setting then
            BookInfoManager:saveSetting("filemanager_display_mode", original_saved_setting)
        end
    end

    local function ensureCollectionsDisplayContext()
        if currently_in_collections then
            return
        end

        saved_filemanager_mode = BookInfoManager:getSetting("filemanager_display_mode")
        currently_in_collections = true
    end

    local function syncCollectionsDisplayMode(path)
        if not path or not containsCollectionsSegment(path) then
            restoreFileManagerDisplayMode()
            return
        end

        ensureCollectionsDisplayContext()

        local target_mode = saved_filemanager_mode or BookInfoManager:getSetting("filemanager_display_mode")

        if not target_mode or target_mode == active_virtual_display_mode then
            return
        end

        applyDisplayModeTemporarily(target_mode)
        active_virtual_display_mode = target_mode
    end

    restoreFileManagerDisplayMode = function()
        if not currently_in_collections then
            return
        end

        currently_in_collections = false
        active_virtual_display_mode = nil
        if saved_filemanager_mode then
            applyDisplayModeTemporarily(saved_filemanager_mode)
            saved_filemanager_mode = nil
        end
    end

    local orig_genItemTable

    local function composeVirtualItemTable(dirs, files, path)
        local item_table = {}
        if dirs and #dirs > 0 then
            table.move(dirs, 1, #dirs, 1, item_table)
        end
        if files and #files > 0 then
            table.move(files, 1, #files, #item_table + 1, item_table)
        end

        return item_table
    end

    local function buildVirtualItemTable(self, path)
        local effective_path = normalizeVirtualPath(path or self._cb_virtual_path)
        if not effective_path or self.name ~= "filemanager" or not containsCollectionsSegment(effective_path) then
            return nil
        end

        patchCoverBrowserVirtualRenderers()

        if isCollectionsRoot(effective_path) then
            local dirs = buildCollectionDirItems(self, effective_path)
            logger.dbg("CollectionsView plugin: building collections root", effective_path, #dirs)
            if #dirs == 0 then
                local collate = self:getCollate()
                local empty_item = self:getListItem(nil, _("No collections yet"), appendPath(effective_path, "."), {
                    mode = "directory",
                    modification = 0,
                    access = 0,
                }, collate)
                empty_item.dim = true
                dirs = { empty_item }
            end
            return composeVirtualItemTable(dirs, {}, effective_path)
        end

        local collection_name = getCollectionFromPath(effective_path)
        if collection_name then
            local files = buildCollectionFileItems(self, effective_path, collection_name)
            logger.dbg("CollectionsView plugin: building collection", collection_name, #files)
            return composeVirtualItemTable({}, files, effective_path)
        end

        return {}
    end

    local orig_genItemTableFromPath = FileChooser.genItemTableFromPath
    function FileChooser:genItemTableFromPath(path)
        local effective_path = getEffectivePath(self, path) or path

        if self.name ~= "filemanager" then
            return orig_genItemTableFromPath(self, path)
        end

        local entering_collections = containsCollectionsSegment(effective_path)
        if entering_collections then
            syncCollectionsDisplayMode(effective_path)
        elseif currently_in_collections then
            restoreFileManagerDisplayMode()
        end

        if entering_collections then
            return buildVirtualItemTable(self, effective_path)
        end

        return orig_genItemTableFromPath(self, path)
    end

    local function injectCollectionsFolder(self, path, item_table)
        local current_path = getEffectivePath(self, path or self.path)
        if not current_path then
            return item_table
        end
        if isHomescreenActive() then
            return item_table
        end

        local should_inject = self.name == "filemanager"
            and not containsCollectionsSegment(current_path)
            and countVisibleCollections() > 0
            and isHomePath(normalizeVirtualPath(current_path))
        if not should_inject then
            return item_table
        end

        patchCoverBrowserVirtualRenderers()

        local virtual_path = appendPath(current_path, COLLECTIONS_SEGMENT)
        local collate = self:getCollate()
        local display_text = getCollectionsDisplayText()
        local entry = self:getListItem(nil, display_text, virtual_path, {
            mode = "directory",
            size = countVisibleCollections(),
            modification = 0,
            access = getAllCollectionsLastAccessTime(),
        }, collate)
        entry.is_directory = true
        entry.is_collections_virtual = true
        entry.collection_label = getCollectionsRootLabel()
        entry.virtual_count = countVisibleCollections()
        entry.virtual_cover_file = getCollectionsRootCoverFile()
        entry.mandatory = T("%1 \u{F114}", entry.virtual_count)

        local existing_idx
        for i, item in ipairs(item_table) do
            if item.path == virtual_path then
                existing_idx = i
                break
            end
        end
        if existing_idx then
            table.remove(item_table, existing_idx)
        end

        local insert_pos = 1
        if item_table[1] and item_table[1].is_go_up then
            insert_pos = 2
        end
        table.insert(item_table, insert_pos, entry)
        return item_table
    end

    orig_genItemTable = FileChooser.genItemTable
    function FileChooser:genItemTable(dirs, files, path)
        return injectCollectionsFolder(self, path, orig_genItemTable(self, dirs, files, path))
    end

    local function renderVirtualItemTable(self)
        if not self or not self._cb_virtual_path then
            return
        end

        local itemmatch
        if self.focused_path then
            itemmatch = { path = self.focused_path }
            self.focused_path = nil
        end

        local item_table = buildVirtualItemTable(self, self._cb_virtual_path)
        if not item_table then
            logger.warn("CollectionsView plugin: renderVirtualItemTable missing item table", self._cb_virtual_path)
            item_table = {}
        end
        logger.dbg("CollectionsView plugin: renderVirtualItemTable", self._cb_virtual_path, #item_table)

        self.path = self._cb_virtual_path
        self.item_table = item_table
        self.path_items = self.path_items or {}

        local itemnumber = self.path_items[self._cb_virtual_path]
        if type(itemmatch) == "table" then
            local key, value = next(itemmatch)
            for num, item in ipairs(self.item_table) do
                if item[key] == value then
                    itemnumber = num
                    break
                end
            end
        end

        if itemnumber == nil then
            self.page = 1
        elseif itemnumber >= 0 and #self.item_table > 0 then
            itemnumber = math.min(itemnumber, #self.item_table)
            self.page = self:getPageNumber(itemnumber)
            if type(itemmatch) == "table"
                and self.item_table[itemnumber]
                and not self.item_table[itemnumber].is_go_up
                and not self.item_table[itemnumber].is_go_back then
                self.itemnumber = itemnumber
            end
        end

        self:updateItems(1, false)
    end

    local function syncVirtualTitleBar(self)
        if not self or not self.title_bar or not self.title_bar.left_button then
            return
        end

        local left_button = self.title_bar.left_button
        local FileManager = require("apps/filemanager/filemanager")
        local fm = FileManager and FileManager.instance
        local search_button = fm and fm._titlebar_search_btn or nil
        if self._cb_virtual_path then
            if not self._cb_saved_left_button then
                self._cb_saved_left_button = {
                    icon = left_button.icon,
                    callback = left_button.callback,
                    hold_callback = left_button.hold_callback,
                    overlap_align = left_button.overlap_align,
                    overlap_offset = left_button.overlap_offset,
                }
            end
            if search_button and not self._cb_saved_search_button then
                self._cb_saved_search_button = {
                    overlap_align = search_button.overlap_align,
                    overlap_offset = search_button.overlap_offset,
                }
            end
            local back_icon = BD.mirroredUILayout() and "chevron.right" or "chevron.left"
            self.title_bar:setLeftIcon(back_icon)
            left_button.overlap_align = nil
            left_button.overlap_offset = { (fm and fm._simpleui_up_x) or 0, 0 }
            left_button.callback = function()
                self:onLeftButtonTap()
            end
            left_button.hold_callback = function()
                return true
            end
            if search_button then
                search_button.overlap_align = nil
                search_button.overlap_offset = { (fm and fm._simpleui_search_x) or (self._cb_saved_search_button and self._cb_saved_search_button.overlap_offset and self._cb_saved_search_button.overlap_offset[1]) or 0, 0 }
            end
        elseif self._cb_saved_left_button then
            self.title_bar:setLeftIcon(self._cb_saved_left_button.icon)
            left_button.callback = self._cb_saved_left_button.callback
            left_button.hold_callback = self._cb_saved_left_button.hold_callback
            left_button.overlap_align = self._cb_saved_left_button.overlap_align
            left_button.overlap_offset = self._cb_saved_left_button.overlap_offset
            self._cb_saved_left_button = nil
            if search_button and self._cb_saved_search_button then
                search_button.overlap_align = self._cb_saved_search_button.overlap_align
                search_button.overlap_offset = self._cb_saved_search_button.overlap_offset
                self._cb_saved_search_button = nil
            end
        end
    end

    local function getWindowTitle(path)
        local effective_path = normalizeVirtualPath(path or "")
        if isCollectionsRoot(effective_path) then
            return getCollectionsRootLabel()
        end
        local collection_name = getCollectionFromPath(effective_path)
        if collection_name then
            return collection_name
        end
        local _, folder_name = util.splitFilePathName(effective_path)
        return folder_name
    end

    local orig_refreshPath = FileChooser.refreshPath
    function FileChooser:refreshPath()
        if self.name == "filemanager" and self._cb_virtual_path then
            syncCollectionsDisplayMode(self._cb_virtual_path)
            Screen:setWindowTitle(getWindowTitle(self._cb_virtual_path))
            renderVirtualItemTable(self)
            syncVirtualTitleBar(self)
            return
        end
        syncVirtualTitleBar(self)
        return orig_refreshPath(self)
    end

    local function openVirtualPath(self, path, focused_path)
        logger.dbg("CollectionsView plugin: openVirtualPath", path)
        patchCoverBrowserVirtualRenderers()
        self._cb_virtual_path = normalizeVirtualPath(path)
        syncCollectionsDisplayMode(self._cb_virtual_path)
        last_virtual_path = self._cb_virtual_path
        self._cb_ignore_folder_up_once = true
        self.path = self._cb_virtual_path
        if focused_path then
            self.focused_path = focused_path
        end
        renderVirtualItemTable(self)
        syncVirtualTitleBar(self)
        UIManager:nextTick(function()
            if self and self._cb_ignore_folder_up_once then
                self._cb_ignore_folder_up_once = nil
            end
        end)
    end

    local function restoreCapturedFileChooserState(fc, state)
        if not fc or not state then
            return
        end

        logger.dbg(
            "CollectionsView plugin: restore file chooser state",
            state.virtual_path or state.path,
            state.focused_path
        )

        local top_widget = UIManager:getTopmostVisibleWidget()
        if top_widget and top_widget.name == "homescreen" then
            logger.dbg("CollectionsView plugin: closing homescreen before restore")
            UIManager:close(top_widget)
        end

        if state.virtual_path and containsCollectionsSegment(state.virtual_path) then
            openVirtualPath(fc, state.virtual_path, state.focused_path)
            return
        end

        if state.path then
            fc:changeToPath(state.path, state.focused_path)
        end
    end

    local orig_changeToPath = FileChooser.changeToPath
    function FileChooser:changeToPath(path, focused_path)
        if self.name == "filemanager" and containsCollectionsSegment(path) then
            openVirtualPath(self, path, focused_path)
            return
        end
        if self.name == "filemanager" and self._cb_virtual_path then
            self._cb_virtual_path = nil
            self._cb_ignore_folder_up_once = nil
            last_virtual_path = nil
            restoreFileManagerDisplayMode()
            syncVirtualTitleBar(self)
        end
        return orig_changeToPath(self, path, focused_path)
    end

    local orig_onMenuSelect = FileChooser.onMenuSelect
    function FileChooser:onMenuSelect(item)
        if self.name == "filemanager" and self._cb_virtual_path and item then
            if item.is_go_up or item.is_go_back then
                local parent_path = getVirtualParentPath(self._cb_virtual_path)
                logger.dbg("CollectionsView plugin: virtual go up", self._cb_virtual_path, parent_path)
                if parent_path and containsCollectionsSegment(parent_path) then
                    openVirtualPath(self, parent_path)
                else
                    self._cb_virtual_path = nil
                    self._cb_ignore_folder_up_once = nil
                    last_virtual_path = nil
                    restoreFileManagerDisplayMode()
                    orig_changeToPath(self, getHomeDir(), self.path)
                end
                return true
            end
            if item.is_collections_virtual and not item.is_file then
                openVirtualPath(self, item.path)
                return true
            end
        elseif self.name == "filemanager" and item and item.is_collections_virtual and not item.is_file then
            openVirtualPath(self, item.path)
            return true
        end
        return orig_onMenuSelect(self, item)
    end

    function FileChooser:onLeftButtonTap()
        if self.name == "filemanager" and self._cb_virtual_path then
            local parent_path = getVirtualParentPath(self._cb_virtual_path)
            if parent_path and containsCollectionsSegment(parent_path) then
                openVirtualPath(self, parent_path)
            else
                self._cb_virtual_path = nil
                self._cb_ignore_folder_up_once = nil
                last_virtual_path = nil
                restoreFileManagerDisplayMode()
                syncVirtualTitleBar(self)
                orig_changeToPath(self, getHomeDir(), self.path)
            end
            return
        end
    end

    local orig_onFolderUp = FileChooser.onFolderUp
    function FileChooser:onFolderUp()
        if self._cb_ignore_folder_up_once then
            self._cb_ignore_folder_up_once = nil
            return
        end
        if self.name == "filemanager" and self._cb_virtual_path then
            local parent_path = getVirtualParentPath(self._cb_virtual_path)
            if parent_path and containsCollectionsSegment(parent_path) then
                openVirtualPath(self, parent_path)
            else
                self._cb_virtual_path = nil
                last_virtual_path = nil
                restoreFileManagerDisplayMode()
                syncVirtualTitleBar(self)
                orig_changeToPath(self, getHomeDir(), self.path)
            end
            return
        end
        return orig_onFolderUp(self)
    end

    local orig_refreshFileManager = FileManagerCollection.refreshFileManager
    function FileManagerCollection:refreshFileManager()
        if self.files_updated and self.ui and self.ui.file_chooser then
            local fc = self.ui.file_chooser
            local virtual_path = fc._cb_virtual_path or last_virtual_path
            if virtual_path and containsCollectionsSegment(virtual_path) then
                fc._cb_virtual_path = normalizeVirtualPath(virtual_path)
                last_virtual_path = fc._cb_virtual_path
                Screen:setWindowTitle(getWindowTitle(fc._cb_virtual_path))
                renderVirtualItemTable(fc)
                syncVirtualTitleBar(fc)
                self.files_updated = nil
                return
            end
        end
        return orig_refreshFileManager(self)
    end

    local orig_showCollListDialog = FileManagerCollection.showCollListDialog
    function FileManagerCollection:showCollListDialog(caller_callback, no_dialog)
        local fc = self.ui and self.ui.file_chooser or nil
        local restore_state = nil
        if fc and self.selected_collections and caller_callback then
            restore_state = {
                virtual_path = fc._cb_virtual_path,
                path = fc.path,
                focused_path = fc.focused_path,
            }
            logger.dbg(
                "CollectionsView plugin: captured file chooser state",
                restore_state.virtual_path or restore_state.path,
                restore_state.focused_path
            )
        end

        if not restore_state then
            return orig_showCollListDialog(self, caller_callback, no_dialog)
        end

        local wrapped_callback = function(selected_collections)
            caller_callback(selected_collections)
            if self.ui and self.ui.file_chooser then
                UIManager:scheduleIn(0.12, function()
                    restoreCapturedFileChooserState(self.ui.file_chooser, restore_state)
                end)
            end
        end

        return orig_showCollListDialog(self, wrapped_callback, no_dialog)
    end

    patchCoverBrowserVirtualRenderers()
    logger.info("CollectionsView plugin installed")
end

function CollectionsView:init()
    installCollectionsViewPlugin()
    if self.ui and self.ui.menu and self.ui.menu.registerToMainMenu then
        self.ui.menu:registerToMainMenu(self)
    end
end

function CollectionsView:_refreshCollectionsView()
    local FileManager = require("apps/filemanager/filemanager")
    local fm = FileManager and FileManager.instance
    local fc = fm and fm.file_chooser
    if not fc then
        return
    end
    fc:refreshPath()
end

function CollectionsView:addToMainMenu(menu_items)
    local InputDialog = require("ui/widget/inputdialog")
    local InfoMessage = require("ui/widget/infomessage")
    local UIManager = require("ui/uimanager")
    local T = ffiUtil.template

    local function currentRootLabel()
        local value = G_reader_settings and G_reader_settings:readSetting(SETTINGS_ROOT_LABEL)
        if type(value) == "string" and value:gsub("^%s+", ""):gsub("%s+$", "") ~= "" then
            return value:gsub("^%s+", ""):gsub("%s+$", "")
        end
        return _("Collections")
    end

    local function currentLabelPosition()
        return (G_reader_settings and G_reader_settings:readSetting(SETTINGS_LABEL_POSITION))
            or (G_reader_settings and G_reader_settings:readSetting("simpleui_fc_label_position"))
            or "bottom"
    end

    local function currentLabelFontSize()
        local value = G_reader_settings and G_reader_settings:readSetting(SETTINGS_LABEL_FONT_SIZE)
        if type(value) == "number" then
            return value
        end
        return 5
    end

    local function currentSortMode()
        return (G_reader_settings and G_reader_settings:readSetting(SETTINGS_SORT_MODE)) or "collection_order"
    end

    local function currentFolderSortMode()
        return (G_reader_settings and G_reader_settings:readSetting(SETTINGS_FOLDER_SORT_MODE)) or "collection_order"
    end

    local function currentHideUnderline()
        return getHideUnderlineSetting()
    end

    local function saveAndRefresh(key, value)
        G_reader_settings:saveSetting(key, value)
        self:_refreshCollectionsView()
    end

    local function makeLabelPositionItems()
        local positions = {
            { id = "center", text = _("Centered") },
            { id = "top", text = _("Top") },
            { id = "bottom", text = _("Bottom") },
        }
        local items = {}
        for _, pos in ipairs(positions) do
            items[#items + 1] = {
                text = pos.text,
                checked_func = function()
                    return currentLabelPosition() == pos.id
                end,
                callback = function()
                    saveAndRefresh(SETTINGS_LABEL_POSITION, pos.id)
                end,
            }
        end
        return items
    end

    local function makeFileSortModeItems()
        local modes = {
            { id = "collection_order", text = _("Collection order") },
            { id = "title_asc", text = _("Title A-Z") },
            { id = "title_desc", text = _("Title Z-A") },
            { id = "access_desc", text = _("Last opened, newest first") },
            { id = "access_asc", text = _("Last opened, oldest first") },
            { id = "modified_desc", text = _("Date added to collection, newest first") },
            { id = "modified_asc", text = _("Date added to collection, oldest first") },
        }
        local items = {}
        for _, mode in ipairs(modes) do
            items[#items + 1] = {
                text = mode.text,
                checked_func = function()
                    return currentSortMode() == mode.id
                end,
                callback = function()
                    saveAndRefresh(SETTINGS_SORT_MODE, mode.id)
                end,
            }
        end
        return items
    end

    local function makeFolderSortModeItems()
        local modes = {
            { id = "collection_order", text = _("Collection Folder") },
            { id = "title_asc", text = _("Title A-Z") },
            { id = "title_desc", text = _("Title Z-A") },
        }
        local items = {}
        for _, mode in ipairs(modes) do
            items[#items + 1] = {
                text = mode.text,
                checked_func = function()
                    return currentFolderSortMode() == mode.id
                end,
                callback = function()
                    saveAndRefresh(SETTINGS_FOLDER_SORT_MODE, mode.id)
                end,
            }
        end
        return items
    end

    menu_items.collectionsview = {
        sorting_hint = "tools",
        text = _("Collections View"),
        sub_item_table = {
            {
                text_func = function()
                    return T(_("Folder name position: %1"), ({
                        center = _("Centered"),
                        top = _("Top"),
                        bottom = _("Bottom"),
                    })[currentLabelPosition()] or _("Bottom"))
                end,
                sub_item_table_func = makeLabelPositionItems,
            },
            {
                text_func = function()
                    return T(_("Folder label font size: %1"), currentLabelFontSize())
                end,
                callback = function()
                    local SpinWidget = require("ui/widget/spinwidget")
                    UIManager:show(SpinWidget:new{
                        title_text = _("Folder label font size"),
                        value = currentLabelFontSize(),
                        value_min = 3,
                        value_max = 12,
                        default_value = 5,
                        callback = function(spin)
                            G_reader_settings:saveSetting(SETTINGS_LABEL_FONT_SIZE, spin.value)
                            self:_refreshCollectionsView()
                        end,
                    })
                end,
            },
            {
                text_func = function()
                    return T(_("Rename collection root: %1"), currentRootLabel())
                end,
                callback = function()
                    local dialog
                    dialog = InputDialog:new{
                        title = _("Rename Collection Root"),
                        input = currentRootLabel(),
                        input_hint = _("Folder name"),
                        buttons = {{
                            {
                                text = _("Cancel"),
                                callback = function()
                                    UIManager:close(dialog)
                                end,
                            },
                            {
                                text = _("Reset"),
                                callback = function()
                                    UIManager:close(dialog)
                                    G_reader_settings:delSetting(SETTINGS_ROOT_LABEL)
                                    self:_refreshCollectionsView()
                                end,
                            },
                            {
                                text = _("Save"),
                                is_enter_default = true,
                                callback = function()
                                    local value = dialog:getInputText()
                                    local trimmed = type(value) == "string" and value:gsub("^%s+", ""):gsub("%s+$", "") or nil
                                    UIManager:close(dialog)
                                    if not trimmed or trimmed == "" then
                                        UIManager:show(InfoMessage:new{
                                            text = _("Name cannot be empty. Use Reset for the default label."),
                                            timeout = 3,
                                        })
                                        return
                                    end
                                    G_reader_settings:saveSetting(SETTINGS_ROOT_LABEL, trimmed)
                                    self:_refreshCollectionsView()
                                end,
                            },
                        }},
                    }
                    UIManager:show(dialog)
                    pcall(function() dialog:onShowKeyboard() end)
                end,
            },
            {
                text = _("Hide last visited underline"),
                checked_func = function()
                    return currentHideUnderline()
                end,
                callback = function()
                    saveAndRefresh(SETTINGS_HIDE_UNDERLINE, not currentHideUnderline())
                end,
            },
            {
                text_func = function()
                    local labels = {
                        collection_order = _("Collection order"),
                        title_asc = _("Title A-Z"),
                        title_desc = _("Title Z-A"),
                        access_desc = _("Last opened, newest first"),
                        access_asc = _("Last opened, oldest first"),
                        modified_desc = _("Date added to collection, newest first"),
                        modified_asc = _("Date added to collection, oldest first"),
                    }
                    return T(_("Arrange files by: %1"), labels[currentSortMode()] or _("Collection order"))
                end,
                sub_item_table_func = makeFileSortModeItems,
            },
            {
                text_func = function()
                    local labels = {
                        collection_order = _("Collection order"),
                        title_asc = _("Title A-Z"),
                        title_desc = _("Title Z-A"),
                    }
                    return T(_("Arrange collection folders by: %1"), labels[currentFolderSortMode()] or _("Collection order"))
                end,
                sub_item_table_func = makeFolderSortModeItems,
            },
        },
    }
end

return CollectionsView
