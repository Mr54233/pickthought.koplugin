-- 位图想法弹窗的纯逻辑测试：内容构建、行边界分页和缓存释放。

local function split_to_chars(text)
    local chars, index = {}, 1
    while index <= #text do
        local byte = text:byte(index)
        local width = byte < 0x80 and 1 or (byte < 0xE0 and 2 or (byte < 0xF0 and 3 or 4))
        chars[#chars + 1] = text:sub(index, index + width - 1)
        index = index + width
    end
    return chars
end

local function bsearch_left(values, value)
    local low, high = 1, #values + 1
    while low < high do
        local mid = math.floor((low + high) / 2)
        if values[mid] < value then low = mid + 1 else high = mid end
    end
    return low
end

local function bsearch_right(values, value)
    local low, high = 1, #values + 1
    while low < high do
        local mid = math.floor((low + high) / 2)
        if values[mid] <= value then low = mid + 1 else high = mid end
    end
    return low
end

package.preload["util"] = function()
    return {
        splitToChars = split_to_chars,
        bsearch_left = bsearch_left,
        bsearch_right = bsearch_right,
    }
end

local hard_newline = false
package.preload["libs/libkoreader-xtext"] = function()
    return {
        new = function(text)
            local size = #text
            local xtext = {}
            for i = 1, size do xtext[i] = true end
            xtext.measure = function() end
            xtext.makeLine = function(_, offset, width)
                if offset > size then return nil end
                local next_offset = size + 1
                if hard_newline then next_offset = nil end
                return {
                    offset = offset,
                    end_offset = size,
                    next_start_offset = next_offset,
                    hard_newline_at_eot = hard_newline,
                    width = width,
                    targeted_width = width,
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
        COLOR_BLACK = 0,
        COLOR_GRAY_1 = 1, COLOR_GRAY_2 = 2, COLOR_GRAY_3 = 3,
        COLOR_GRAY_4 = 4, COLOR_GRAY_5 = 5, COLOR_GRAY_6 = 6,
        COLOR_GRAY_7 = 7, COLOR_DARK_GRAY = 8, COLOR_GRAY_9 = 9,
        COLOR_GRAY = 10, COLOR_GRAY_B = 11, COLOR_LIGHT_GRAY = 12,
        COLOR_GRAY_D = 13, COLOR_GRAY_E = 14, COLOR_WHITE = 255,
        isColor8 = function() return true end,
    }
end

for _, name in ipairs({
    "util", "libs/libkoreader-xtext", "ffi/blitbuffer",
    "pickthought.thought_popup.paginator",
    "pickthought.thought_popup.content_builder",
}) do
    package.loaded[name] = nil
end

local Paginator = require("pickthought.thought_popup.paginator")
local ContentBuilder = require("pickthought.thought_popup.content_builder")

local function boundaries(count, height)
    local values = {}
    for index = 1, count do
        values[index] = {top = (index - 1) * height, bottom = index * height}
    end
    return values
end

T.case("想法弹窗分页只在文本行边界切分", function()
    local pages = Paginator.computePages(boundaries(10, 20), 60, 200)
    T.eq(#pages, 4, "十行文本被切为四页")
    T.eq(pages[1], 0, "首页从零开始")
    T.eq(pages[2], 60, "第二页从完整行边界开始")
    T.eq(pages[4], 180, "最后一页保留尾部文本")

    local orphan = {
        {top = 0, bottom = 61}, {top = 61, bottom = 122},
        {top = 122, bottom = 183}, {top = 183, bottom = 244, keep_next = true},
        {top = 244, bottom = 305}, {top = 305, bottom = 366},
    }
    local orphan_pages = Paginator.computePages(orphan, 300, 366)
    T.eq(orphan_pages[2], 183, "作者行不会孤立在页底")

    local with_tail = {
        {top = 0, bottom = 24}, {top = 24, bottom = 48},
        {top = 48, bottom = 54},
    }
    local tail_pages = Paginator.computePages(with_tail, 48, 54)
    T.eq(tail_pages[2], 48, "末行下溢空间不会被错误提前放到下一页")
end)

T.case("超长单条想法跨多页且每页索引到同一文本块", function()
    local pages = Paginator.computePages(boundaries(60, 20), 300, 1200)
    T.eq(#pages, 4, "长内容可跨多页")
    local index = Paginator.buildPagePieceIndex({{y = 0, piece_h = 1200}}, pages, 1200)
    T.eq(#index[1], 1, "第一页包含长文本")
    T.eq(#index[4], 1, "尾页仍包含长文本")
    local slice = Paginator.pieceVisibleRange(
        {y = 20, piece_h = 60, line_h = 20, n_lines = 3}, 0, 60)
    T.eq(slice.src_h, 40, "页面仅绘制可见行")
end)

T.case("想法弹窗内容构建保留引用作者点赞并支持 Unicode 清理", function()
    local blocks = ContentBuilder.build({{
        abstract = string.rep("汉", 60) .. "\n第二段",
        author = "甲", content = "正文\n\226\128\140", likes_count = 3,
    }}, {contrast = 9})
    T.eq(#blocks, 3, "引用、作者和正文各有一个块")
    T.eq(blocks[1].text, "「" .. string.rep("汉", 50) .. "…」", "引用按 rune 截断")
    T.eq(blocks[2].text, "▸ 甲 · ♥ 3", "作者和点赞按上游格式显示")
    T.eq(blocks[3].text, "正文", "末尾不可见 Unicode 空白被清理")
    T.eq(blocks[1].fg, 0, "默认最大对比度为纯黑")

    local centered = ContentBuilder.build({{
        abstract = "不应显示", author = "乙", content = "内容", likes_count = 0,
    }}, {skip_quote = true, contrast = 0})
    T.eq(#centered, 2, "居中标题栏模式不重复渲染引用")
    T.eq(centered[1].fg, 9, "对比度零保留基础灰阶")
end)

T.case("想法弹窗 xtext 缓存可被显式释放", function()
    hard_newline = false
    local page = Paginator.paginateText("hello", {size = 20}, 400)
    T.eq(page.n_lines, 1, "普通文本只有一行")
    local piece = {xtext = page.xtext, lines = page.lines}
    Paginator.freeTextPieces({piece})
    T.eq(piece.xtext, nil, "释放后移除 xtext 引用")
    T.eq(piece.lines, nil, "释放后移除行引用")
    T.ok(page.xtext.freed, "释放时调用 xtext.free")

    hard_newline = true
    T.eq(Paginator.paginateLines("hello\n", {size = 20}, 400), 2,
        "末尾硬换行保留额外空行")
    hard_newline = false
end)

T.case("跨页正文使用连续像素区间,不重复或裁切末行尾部", function()
    local piece = {
        y = 0, line_h = 20, piece_h = 65, n_lines = 3,
    }
    local first = Paginator.pieceVisibleRange(piece, 0, 40)
    local second = Paginator.pieceVisibleRange(piece, 40, 65)
    T.eq(first.src_y, 0, "第一页从正文位图起点裁剪")
    T.eq(first.src_h, 40, "第一页覆盖前两行")
    T.eq(second.src_y, 40, "第二页从第三行起点裁剪")
    T.eq(second.src_h, 25, "第二页覆盖第三行及尾部空间")
    T.eq(first.src_y + first.src_h, second.src_y, "两页源像素区间连续")
end)
