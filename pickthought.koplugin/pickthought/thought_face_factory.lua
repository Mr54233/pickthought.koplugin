-- 想法弹窗字体构建与逐字形回退支持。
-- 优先使用用户选择的阅读字体,然后加 KOReader 内置的符号、CJK 和可选 emoji 回退。
-- 任何失败都回退到 KOReader 正常的 Font:getFace,缺字体不会阻止弹窗。
-- 移植自 miuread thought_face_factory (a201a92),适配撷思日志前缀与路径。

local Font = require("ui/font")
local FontList = require("fontlist")
local Freetype = require("ffi/freetype")
local logger = require("logger")

local FaceFactory = {
    initialized = false,
    emoji_path = nil,
    font_paths_cache = {},
    face_cache = {},
    fallback_cache = {},
}

local function file_exists(path)
    if type(path) ~= "string" or path == "" then return false end
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if ok_lfs and lfs and type(lfs.attributes) == "function" then
        return lfs.attributes(path, "mode") == "file"
    end
    local file = io.open(path, "rb")
    if file then file:close(); return true end
    return false
end

local function realpath(path)
    if not file_exists(path) then return nil end
    local ok, ffiutil = pcall(require, "ffi/util")
    if ok and ffiutil and type(ffiutil.realpath) == "function" then
        return ffiutil.realpath(path) or path
    end
    return path
end

local function resolve_bundled_font(fontname)
    if type(fontname) ~= "string" or fontname == "" then return nil end
    local direct = FontList.fontdir and (FontList.fontdir .. "/" .. fontname) or nil
    if direct and file_exists(direct) then return realpath(direct) end

    local ok, fonts = pcall(FontList.getFontList, FontList)
    if not ok or type(fonts) ~= "table" then return nil end
    for _, path in ipairs(fonts) do
        if type(path) == "string" then
            local basename = path:match("([^/]+)$") or path
            if basename == fontname or path:find(fontname, 1, true) then
                return realpath(path)
            end
        end
    end
    return nil
end

local EMOJI_CANDIDATES = {
    "plugins/pickthought.koplugin/fonts/NotoEmoji-Regular.ttf",
    "plugins/miuread.koplugin/fonts/NotoEmoji-Regular.ttf",
    "plugins/weread.koplugin/fonts/NotoEmoji-Regular.ttf",
    "/mnt/us/fonts/NotoEmoji-Regular.ttf",
    "/usr/share/fonts/truetype/noto/NotoEmoji-Regular.ttf",
}

function FaceFactory:findEmojiFont()
    if self.emoji_path and file_exists(self.emoji_path) then return self.emoji_path end

    local candidates = {}
    for _, c in ipairs(EMOJI_CANDIDATES) do candidates[#candidates + 1] = c end
    local ok_ds, DataStorage = pcall(require, "datastorage")
    if ok_ds and DataStorage and type(DataStorage.getDataDir) == "function" then
        local data_dir = DataStorage:getDataDir()
        candidates[#candidates + 1] = data_dir .. "/plugins/pickthought.koplugin/fonts/NotoEmoji-Regular.ttf"
        candidates[#candidates + 1] = data_dir .. "/plugins/miuread.koplugin/fonts/NotoEmoji-Regular.ttf"
        candidates[#candidates + 1] = data_dir .. "/plugins/weread.koplugin/fonts/NotoEmoji-Regular.ttf"
    end

    for _, path in ipairs(candidates) do
        local resolved = realpath(path)
        if resolved then
            self.emoji_path = resolved
            logger.info("[撷思][ThoughtFace] emoji 回退字体:", resolved)
            return resolved
        end
    end
    self.emoji_path = nil
    return nil
end

function FaceFactory:init()
    if self.initialized then return end
    pcall(function()
        local cre = require("document/crereader")
        if cre and type(cre.engineInit) == "function" then cre:engineInit() end
    end)
    self:findEmojiFont()
    self.initialized = true
end

function FaceFactory:getFontPaths(font_name)
    if type(font_name) ~= "string" or font_name == "" then return {} end
    local cached = self.font_paths_cache[font_name]
    if cached then return cached end

    local direct = realpath(font_name)
    if direct then
        local paths = {{path = direct, bold = false, italic = false}}
        self.font_paths_cache[font_name] = paths
        return paths
    end

    local paths, seen = {}, {}
    local ok, cre = pcall(function()
        local module = require("document/credocument")
        return module and type(module.engineInit) == "function" and module:engineInit() or module
    end)
    if ok and cre and type(cre.getFontFaceFilenameAndFaceIndex) == "function" then
        for index = 1, 4 do
            local bold = index >= 3
            local italic = index == 2 or index == 4
            local ok_path, path = pcall(cre.getFontFaceFilenameAndFaceIndex, font_name, bold, italic)
            path = ok_path and realpath(path) or nil
            if path and not seen[path] then
                seen[path] = true
                paths[#paths + 1] = {path = path, bold = bold, italic = italic}
            end
        end
    end
    self.font_paths_cache[font_name] = paths
    return paths
end

function FaceFactory:_buildFace(path, size)
    path = realpath(path)
    size = math.max(8, math.floor(tonumber(size) or 0))
    if not path or size <= 0 then return nil end

    local ok, ftsize = pcall(Freetype.newFaceSize, path, size)
    if not ok or not ftsize then
        logger.warn("[撷思][ThoughtFace] 无法打开回退字体:", tostring(path))
        return nil
    end

    local face = {
        orig_font = path,
        realname = path,
        size = size,
        orig_size = size,
        ftsize = ftsize,
        hash = path .. "|" .. tostring(size),
        is_real_bold = false,
        hb_features = {"+kern", "+liga"},
        fallbacks = {},
    }
    face.getFallbackFont = function(number)
        if not number or number == 0 then return face end
        if face.fallbacks[number] ~= nil then return face.fallbacks[number] end
        return false
    end
    return face
end

function FaceFactory:_getFallbackFace(path, size)
    if not path then return nil end
    local key = path .. "|" .. tostring(size)
    if self.fallback_cache[key] then return self.fallback_cache[key] end
    local face = self:_buildFace(path, size)
    if face then self.fallback_cache[key] = face end
    return face
end

local FALLBACK_FONT_NAMES = {
    "FreeSans.ttf",
    "NotoSansCJKsc-Regular.otf",
    "freefont/FreeSerif.ttf",
    "nerdfonts/symbols.ttf",
    "NotoSansSymbols2-Regular.ttf",
}

function FaceFactory:_addFallbacks(face, size)
    if not face then return end
    local paths, seen = {}, {}
    if face.orig_font then seen[face.orig_font] = true end

    for _, fontname in ipairs(FALLBACK_FONT_NAMES) do
        local path = resolve_bundled_font(fontname)
        if path and not seen[path] then
            seen[path] = true
            paths[#paths + 1] = path
        end
    end
    local emoji = self:findEmojiFont()
    if emoji and not seen[emoji] then paths[#paths + 1] = emoji end

    local fallbacks = {}
    for _, path in ipairs(paths) do
        local fallback = self:_getFallbackFace(path, size)
        if fallback then fallbacks[#fallbacks + 1] = fallback end
    end
    fallbacks[#fallbacks + 1] = false
    face.fallbacks = fallbacks
end

local function legacy_face(font_name, size, fallback_name)
    if type(font_name) == "string" and font_name ~= "" then
        local ok, face = pcall(Font.getFace, Font, font_name, size)
        if ok and face then return face end
    end
    return Font:getFace(fallback_name or "cfont", size)
end

function FaceFactory:getFace(font_name, size, fallback_name)
    self:init()
    size = math.max(8, math.floor(tonumber(size) or 12))
    fallback_name = fallback_name or "cfont"
    local key = table.concat({tostring(font_name or ""), tostring(size), fallback_name, self.emoji_path or ""}, "|")
    if self.face_cache[key] then return self.face_cache[key] end

    local path
    local paths = self:getFontPaths(font_name)
    for _, item in ipairs(paths) do
        if not item.bold and not item.italic then path = item.path; break end
    end
    if not path and paths[1] then path = paths[1].path end

    if not path then
        if fallback_name == "smallinfofont" then
            path = resolve_bundled_font("NotoSans-Regular.ttf")
                or resolve_bundled_font("FreeSans.ttf")
        else
            path = resolve_bundled_font("NotoSansCJKsc-Regular.otf")
                or resolve_bundled_font("NotoSans-Regular.ttf")
        end
    end

    local face = path and self:_buildFace(path, size) or nil
    if face then
        self:_addFallbacks(face, size)
        self.face_cache[key] = face
        return face
    end

    -- KOReader 字体内部结构差异时的兼容回退。
    return legacy_face(font_name, size, fallback_name)
end

function FaceFactory:clearCache()
    self.font_paths_cache = {}
    self.face_cache = {}
    self.fallback_cache = {}
    self.emoji_path = nil
    self.initialized = false
end

return FaceFactory