-- 撷思想法弹窗的统一配置。阅读入口只传入 plugin 和 SQLite 规范化后的 items，
-- 这里负责把当前书籍字体、页面边距和用户偏好收敛成弹窗参数。
local M = {}

local function clamp(value, min_value, max_value, fallback)
    value = tonumber(value)
    if not value then return fallback end
    return math.max(min_value, math.min(max_value, value))
end

local function popupSettings(plugin)
    local preferences = plugin and plugin.store and plugin.store:preferences() or {}
    local settings = preferences.thoughts or {}
    return {
        height_ratio = clamp(settings.height_ratio, 0.20, 0.90, 0.70),
        position = settings.position == "bottom" and "bottom" or "center",
        width_ratio = clamp(settings.width_ratio, 0.40, 1.00, 0.80),
        font_size = tonumber(settings.font_size),
        font_size_relative = clamp(settings.font_size_relative, -10, 5, 0),
        contrast = clamp(settings.contrast, -3, 9, 9),
        tap_to_page = settings.tap_to_page == true,
    }
end

local function layoutParams(plugin, popup_settings)
    local document = plugin and plugin.ui and plugin.ui.document
    if not document then return {} end
    local Screen = require("device").screen

    local font_face
    if type(plugin._thought_font_name) == "function" then
        local ok, value = pcall(plugin._thought_font_name, plugin)
        if ok then font_face = value end
    end

    local font_size = popup_settings.font_size
    local font_size_scaled
    if font_size then
        font_size_scaled = Screen:scaleBySize(font_size)
    else
        local relative = popup_settings.font_size_relative
        local doc_font_size
        if type(plugin._thought_font_pt) == "function" then
            local ok, value = pcall(plugin._thought_font_pt, plugin)
            if ok then doc_font_size = tonumber(value) end
        end
        doc_font_size = doc_font_size
            or tonumber(document.configurable and document.configurable.font_size)
            or 18
        font_size_scaled = Screen:scaleBySize(doc_font_size) + relative
    end

    local ok, margins = pcall(function()
        return document:getPageMargins()
    end)

    return {
        doc_font_name = font_face,
        doc_font_size = font_size_scaled,
        doc_margins = ok and margins or nil,
    }
end

-- Build the complete ThoughtPopup.show options used by the injected-EPUB
-- anchor handler. The returned table deliberately accepts the public `pages`
-- name from upstream while the popup entry also keeps `items` compatibility.
function M.build(plugin, pages, extra)
    local popup_settings = popupSettings(plugin)
    local layout = layoutParams(plugin, popup_settings)
    local opts = {
        pages = pages,
        height_ratio = popup_settings.height_ratio,
        position = popup_settings.position,
        width_ratio = popup_settings.width_ratio,
        contrast = popup_settings.contrast,
        tap_to_page = popup_settings.tap_to_page == true,
        dialog = plugin and plugin.ui or nil,
        doc_font_name = layout.doc_font_name,
        doc_font_size = layout.doc_font_size,
        doc_margins = layout.doc_margins,
    }
    for key, value in pairs(extra or {}) do
        opts[key] = value
    end
    return opts
end

M.settings = popupSettings

return M
