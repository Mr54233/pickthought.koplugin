local logger = require("logger")

local M = {}

local MARKER = "_pickthought_invalid_xpointer_compat"
local READER_ANNOTATION = "apps/reader/modules/readerannotation"

local function check_xpointer(document, pointer)
    if type(pointer) ~= "string" or pointer == "" then
        return false
    end

    local ok_method, checker = pcall(function()
        return document and document.isXPointerInDocument
    end)
    if not ok_method or type(checker) ~= "function" then
        -- 旧 KOReader 没有检查 API 时不要阻断原有注释加载。
        return true
    end

    local ok, valid = pcall(checker, document, pointer)
    return ok and valid == true
end

local function is_valid_annotation(self, bookmark)
    if not self.ui or not self.ui.rolling or not self.document then
        return true
    end

    local valid = check_xpointer(self.document, bookmark and bookmark.page)
    if not valid then
        logger.warn("[撷思][AnnotationCompat] 跳过无效划线起点:",
            tostring(bookmark and bookmark.page))
        return false
    end

    if bookmark.pos1 ~= nil then
        valid = check_xpointer(self.document, bookmark.pos1)
        if not valid then
            logger.warn("[撷思][AnnotationCompat] 跳过无效划线终点:",
                tostring(bookmark.pos1))
            return false
        end
    end
    return true
end

local function patch_annotation_module(annotation_module)
    if type(annotation_module) ~= "table" then
        return false, "readerannotation module is not a table"
    end
    if annotation_module[MARKER] then
        return true
    end

    local build_annotation = annotation_module.buildAnnotation
    if type(build_annotation) ~= "function" then
        return false, "readerannotation.buildAnnotation is unavailable"
    end

    -- 旧版 KOReader 会把无效 bookmark 交给批量加载函数，随后把它生成的
    -- nil 直接插入数组。只过滤输入并调用原函数，保留各版本其他加载行为。
    local get_annotations = annotation_module.getAnnotationsFromBookmarksHighlights
    if type(get_annotations) ~= "function" then
        return false, "readerannotation batch loader is unavailable"
    end

    annotation_module.buildAnnotation = function(self, bookmark, highlights, init)
        if not is_valid_annotation(self, bookmark) then
            return nil
        end
        return build_annotation(self, bookmark, highlights, init)
    end

    annotation_module.getAnnotationsFromBookmarksHighlights = function(
            self, bookmarks, highlights, init)
        if self.ui and self.ui.rolling and self.document then
            local valid_bookmarks = {}
            for _, bookmark in ipairs(bookmarks) do
                if is_valid_annotation(self, bookmark) then
                    valid_bookmarks[#valid_bookmarks + 1] = bookmark
                end
            end
            bookmarks = valid_bookmarks
        end
        return get_annotations(self, bookmarks, highlights, init)
    end

    annotation_module[MARKER] = true
    return true
end

function M.install(annotation_module)
    if annotation_module == nil then
        local ok, loaded = pcall(require, READER_ANNOTATION)
        if not ok then
            logger.warn("[撷思][AnnotationCompat] 无法加载 readerannotation:",
                tostring(loaded))
            return false
        end
        annotation_module = loaded
    end

    local ok, err = patch_annotation_module(annotation_module)
    if not ok then
        logger.warn("[撷思][AnnotationCompat] 未安装兼容补丁:", tostring(err))
        return false
    end
    return true
end

return M
