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
                -- 行长随排版宽度变化，保证宽高矩阵生成不同分页。
                local line_bytes = math.max(12, math.floor(width / 12))
                local finish = math.min(size, offset + line_bytes - 1)
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
                ftsize = {getHeightAndAscender = function() return 30, 20 end},
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

local function assert_piece_ranges_contiguous(renderer, pages, piece)
    local Paginator = require('pickthought.thought_popup.paginator')
    local ranges = {}
    for page_index = 1, #pages do
        local p0 = pages[page_index]
        local p1 = pages[page_index + 1] or renderer.content_h
        local range = Paginator.pieceVisibleRange(piece, p0, p1)
        if range then
            T.ok(range.src_y >= 0, '源起点不为负')
            T.ok(range.src_h > 0, '源高度为正')
            T.ok(range.src_y + range.src_h <= piece.piece_h, '源区间不越过文本位图')
            T.ok(range.dest_y >= 0, '目标起点不为负')
            ranges[#ranges + 1] = range
        end
    end
    T.ok(#ranges > 0, '文本块至少出现在一页')
    T.eq(ranges[1].src_y, 0, '文本块首段从位图起点开始')
    for index = 2, #ranges do
        T.eq(ranges[index - 1].src_y + ranges[index - 1].src_h,
            ranges[index].src_y, '相邻页面文本源区间无重叠且无缺口')
    end
    T.eq(ranges[#ranges].src_y + ranges[#ranges].src_h, piece.piece_h,
        '文本块末段覆盖位图结尾')
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

T.case("分页边界覆盖文本块最后一行的实际位图尾部", function()
    local renderer = PageRenderer:new{
        items = {{abstract = "", author = "甲", content = string.rep("长", 80)}},
        doc_font_size = 18,
        doc_margins = {left = 20, right = 20, top = 10, bottom = 10},
        height_ratio = .60, contrast = 9, skip_quote = true,
    }
    renderer:ensureLayout()
    local content_piece
    for _, piece in ipairs(renderer.layout.pieces) do
        if piece.variant == "content" then content_piece = piece end
    end
    T.ok(content_piece and content_piece.line_bounds, "正文保存视觉行边界")
    local last = content_piece.line_bounds[#content_piece.line_bounds]
    T.eq(last.bottom, content_piece.y + content_piece.piece_h,
        "最后一行边界覆盖实际位图尾部")

    local pages = renderer:computePages(content_piece.line_bounds[#content_piece.line_bounds - 1].bottom)
    T.ok(#pages >= 2, "文本块最后一行尾部需要时进入下一页")
    local previous_end = pages[2]
    local last_slice = require("pickthought.thought_popup.paginator").pieceVisibleRange(
        content_piece, previous_end, content_piece.y + content_piece.piece_h)
    T.eq(last_slice.src_y, content_piece.line_bounds[#content_piece.line_bounds - 1].bottom
        - content_piece.y, "下一页从最后一行起点开始")
    T.eq(last_slice.src_h, content_piece.piece_h
        - (content_piece.line_bounds[#content_piece.line_bounds - 1].bottom - content_piece.y),
        "下一页包含最后一行完整尾部")

    local ranges = {}
    local paginator = require("pickthought.thought_popup.paginator")
    for page_index = 1, #pages do
        local p0 = pages[page_index]
        local p1 = pages[page_index + 1] or renderer.content_h
        local range = paginator.pieceVisibleRange(content_piece, p0, p1)
        if range then ranges[#ranges + 1] = range end
    end
    T.ok(#ranges > 1, "正文实际跨越多个页面")
    T.eq(ranges[1].src_y, 0, "跨页正文源区间从零开始")
    for index = 2, #ranges do
        T.eq(ranges[index - 1].src_y + ranges[index - 1].src_h,
            ranges[index].src_y, "相邻页面正文源区间连续")
    end
    T.eq(ranges[#ranges].src_y + ranges[#ranges].src_h, content_piece.piece_h,
        "跨页正文源区间覆盖到位图末尾")
end)

T.case("全部合法宽高组合均不重复或裁切跨页正文", function()
    for width_percent = 60, 100, 5 do
        for height_percent = 50, 90, 5 do
            local renderer = PageRenderer:new{
                items = items,
                doc_font_size = 18,
                doc_margins = {left = 20, right = 20, top = 10, bottom = 10},
                height_ratio = height_percent / 100,
                content_width = math.floor(600 * width_percent / 100),
                contrast = 9,
                skip_quote = true,
            }
            renderer:ensureLayout()
            local viewport_h = math.max(1, math.floor(800 * height_percent / 100) - 180)
            local pages = renderer:computePages(viewport_h)
            T.ok(#pages > 1, width_percent .. "x" .. height_percent .. " 长内容跨页")
            for index = 2, #pages do
                T.ok(pages[index] > pages[index - 1], "页起点单调递增")
            end
            for page_index = 1, #pages do
                local page_bb = renderer:renderPage(page_index, pages)
                T.ok(page_bb and page_bb.getHeight, "每种宽高组合均生成页面位图")
            end
            for _, piece in ipairs(renderer.layout.pieces) do
                assert_piece_ranges_contiguous(renderer, pages, piece)
            end
        end
    end
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
