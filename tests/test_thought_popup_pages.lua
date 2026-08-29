-- 位图页面渲染器测试：验证布局缓存、尺寸变化、颜色变化和缓存释放。

local function split_to_chars(text)
    local out, index = {}, 1
    while index <= #text do
        local byte = text:byte(index)
        local width = byte < 0x80 and 1 or (byte < 0xE0 and 2 or (byte < 0xF0 and 3 or 4))
        out[#out + 1] = text:sub(index, index + width - 1)
        index = index + width
    end
    return out
end

local function bsearch_left(values, value)
    local low, high = 1, #values + 1
    while low < high do
        local middle = math.floor((low + high) / 2)
        if values[middle] < value then low = middle + 1 else high = middle end
    end
    return low
end

local function bsearch_right(values, value)
    local low, high = 1, #values + 1
    while low < high do
        local middle = math.floor((low + high) / 2)
        if values[middle] <= value then low = middle + 1 else high = middle end
    end
    return low
end

local function class(proto)
    proto = proto or {}
    proto.__index = proto
    function proto:extend(fields)
        fields = fields or {}
        fields.__index = fields
        return setmetatable(fields, {__index = self})
    end
    function proto:new(fields)
        return setmetatable(fields or {}, self)
    end
    return proto
end

package.preload["util"] = function()
    return {splitToChars = split_to_chars, bsearch_left = bsearch_left, bsearch_right = bsearch_right}
end
package.preload["libs/libkoreader-xtext"] = function()
    return {
        new = function(text)
            local size = #text
            local xtext = {}
            for index = 1, size do xtext[index] = true end
            xtext.measure = function() end
            xtext.makeLine = function(_, offset, width)
                if offset > size then return nil end
                -- 每 24 字节一行，保证长内容形成多个页面。
                local finish = math.min(size, offset + 23)
                return {
                    offset = offset, end_offset = finish,
                    next_start_offset = finish < size and finish + 1 or size + 1,
                    width = width, targeted_width = width,
                }
            end
            xtext.shapeLine = function() return {para_is_rtl = false, width = 0} end
            xtext.free = function(self) self.freed = true end
            return setmetatable(xtext, {__len = function() return size end})
        end,
    }
end
package.preload["ffi/blitbuffer"] = function()
    return {
        COLOR_BLACK = 0, COLOR_GRAY_1 = 1, COLOR_GRAY_2 = 2, COLOR_GRAY_3 = 3,
        COLOR_GRAY_4 = 4, COLOR_GRAY_5 = 5, COLOR_GRAY_6 = 6, COLOR_GRAY_7 = 7,
        COLOR_DARK_GRAY = 8, COLOR_GRAY_9 = 9, COLOR_GRAY = 10, COLOR_GRAY_B = 11,
        COLOR_LIGHT_GRAY = 12, COLOR_GRAY_D = 13, COLOR_GRAY_E = 14, COLOR_WHITE = 255,
        TYPE_BB8 = 8, TYPE_BBRGB32 = 32,
        isColor8 = function() return true end,
        new = function(width, height)
            return {
                width = width, height = height,
                fill = function() end, blitFrom = function() end,
                getWidth = function(self) return self.width end,
                getHeight = function(self) return self.height end,
                free = function(self) self.freed = true end,
            }
        end,
    }
end
package.preload["device"] = function()
    return {
        screen = {
            scaleBySize = function(_, value) return value end,
            getWidth = function() return 600 end,
            getHeight = function() return 800 end,
            isColorEnabled = function() return false end,
        },
    }
end
package.preload["ui/rendertext"] = function()
    return {getGlyphByIndex = function() return nil end}
end
package.preload["cache"] = function()
    return {
        new = function(_, _)
            local values = {}
            return {
                get = function(_, key) return values[key] end,
                insert = function(_, key, value) values[key] = value end,
                clear = function()
                    for _, item in pairs(values) do
                        if item.onFree then item:onFree() end
                    end
                    values = {}
                end,
            }
        end,
    }
end
package.preload["cacheitem"] = function() return class() end
package.preload["pickthought.thought_popup.face_factory"] = function()
    return {
        getFace = function(_, _, variant)
            return {
                variant = variant,
                size = 20,
                ftsize = {getHeightAndAscender = function() return 24, 20 end},
                getFallbackFont = function() return nil end,
            }
        end,
    }
end

for _, name in ipairs({
    "util", "libs/libkoreader-xtext", "ffi/blitbuffer", "device", "ui/rendertext",
    "cache", "cacheitem", "pickthought.thought_popup.face_factory",
    "pickthought.thought_popup.paginator", "pickthought.thought_popup.content_builder",
    "pickthought.thought_popup.pages",
}) do
    package.loaded[name] = nil
end

local PageRenderer = require("pickthought.thought_popup.pages")
local items = {
    {abstract = "很长的引用内容", author = "甲", content = string.rep("长想法内容", 90), likes_count = 3},
    {abstract = "", author = "乙", content = "第二条", likes_count = 0},
}

local function new_renderer()
    return PageRenderer:new{
        items = items, doc_font_size = 18,
        doc_margins = {left = 20, right = 20, top = 10, bottom = 10},
        height_ratio = .70, contrast = 9,
    }
end

T.case("想法页面渲染器公开布局字段和长内容分页", function()
    local renderer = new_renderer()
    renderer:ensureLayout()
    T.ok(renderer.content_h > 0, "布局后有内容高度")
    T.ok(renderer.text_w > 0, "布局后有正文宽度")
    T.ok(renderer.boundaries and #renderer.boundaries > 0, "布局后有文本边界")
    local pages = renderer:computePages(120)
    T.ok(#pages > 1, "长内容生成多个页面")
    local first = renderer:renderPage(1, pages)
    local last = renderer:renderPage(#pages, pages)
    T.ok(first and first.getHeight, "首页生成位图")
    T.ok(last and last.getHeight, "尾页生成位图")
end)

T.case("相同内容复用布局，尺寸或对比度变化会重新布局", function()
    local renderer = new_renderer()
    renderer:ensureLayout()
    local first_layout = renderer.layout
    renderer:setContent(items, nil, 18, {left = 20, right = 20, top = 10, bottom = 10}, .70, nil, 9)
    T.eq(renderer.layout, first_layout, "相同输入保持布局缓存")

    renderer:setContent(items, nil, 18, {left = 20, right = 20, top = 10, bottom = 10}, .70, 400, 9)
    T.ok(renderer.layout ~= first_layout, "居中宽度变化重新布局")
    local narrower_layout = renderer.layout
    renderer:setContent(items, nil, 18, {left = 20, right = 20, top = 10, bottom = 10}, .70, 400, 0)
    T.ok(renderer.layout ~= narrower_layout, "对比度变化重新布局")
end)

T.case("页面与文本缓存关闭时完整释放且可重新布局", function()
    local renderer = new_renderer()
    renderer:ensureLayout()
    local pages = renderer:computePages(120)
    renderer:renderPage(1, pages)
    renderer:freeContentCaches()
    T.eq(renderer.layout, nil, "清理后不保留布局")
    T.eq(renderer.boundaries, nil, "清理后不保留边界")
    renderer:ensureLayout()
    T.ok(renderer.content_h > 0 and renderer.layout, "清理后仍可重新布局")
end)
