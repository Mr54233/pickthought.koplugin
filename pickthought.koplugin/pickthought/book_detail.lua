--[[--
绑定搜索的书籍详情弹窗(Issue #28)。

长按搜索结果时展示书名/作者/译者/出版社/出版时间/分类/格式/简介,
左侧可选封面(cover_path 存在时),并提供「绑定此书」入口。

布局参考上游 weread ui/book_detail_view.lua 的信息行结构(简化版):
FrameContainer 居中 → 标题行 + HorizontalGroup{封面, 文字行} + 按钮行。
纯逻辑(build_rows/intro_excerpt)与 UI 组装(show)分离,便于桌面单测。
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Device = require("device")
local Screen = Device.screen
local U = require("pickthought.util")
local Json = require("pickthought.json")

local M = {}

local function trim(value)
    if type(value) ~= "string" then return "" end
    return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local INTRO_MAX = 120

-- UTF-8 按字符数安全截断:返回前 limit 个字符的字节串。
-- 中文/emoji 均按完整序列计数,不会产生半个字符。
local function utf8_prefix(text, limit)
    local out = {}
    local count, i = 0, 1
    while i <= #text and count < limit do
        local byte = text:byte(i)
        local width = 1
        if byte >= 0xF0 then width = 4
        elseif byte >= 0xE0 then width = 3
        elseif byte >= 0xC0 then width = 2 end
        out[#out + 1] = text:sub(i, i + width - 1)
        i = i + width
        count = count + 1
    end
    return table.concat(out), count
end

--- 简介截断:超过 120 个字符截断并追加省略号;空/纯空白返回 ""。
function M.intro_excerpt(intro)
    local text = trim(intro)
    if text == "" then return text end
    local prefix, count = utf8_prefix(text, INTRO_MAX)
    if count >= INTRO_MAX and #prefix < #text then
        return prefix .. "…"
    end
    return text
end

local function format_label(format)
    if format == "epub" then return "出版" end
    if format == "txt" then return "网络" end
    return nil
end

--- 详情行构建(纯函数):normalize_book_info 的结果 → 展示行对。
--- 缺失值显示「—」;format 未知时不显示该行。
function M.build_rows(info)
    info = type(info) == "table" and info or {}
    local rows = {
        {"书名", trim(info.title) ~= "" and trim(info.title) or "—"},
        {"作者", trim(info.author) ~= "" and trim(info.author) or "—"},
        {"译者", trim(info.translator) ~= "" and trim(info.translator) or "—"},
        {"出版社", trim(info.publisher) ~= "" and trim(info.publisher) or "—"},
        {"出版时间", trim(info.publishTime) ~= "" and trim(info.publishTime) or "—"},
        {"分类", trim(info.categoryName) ~= "" and trim(info.categoryName) or "—"},
    }
    local flabel = format_label(info.format)
    if flabel then rows[#rows + 1] = {"格式", flabel} end
    return rows
end

--- 弹窗主体文字列(封面右侧)。行用 TextBoxWidget 按列宽分配:
--- TextWidget 只占自身文字宽度,无简介时整列会收缩成最长一行的宽,
--- 弹窗随之缩成一小块(真机验收发现的布局缺陷)。
function M._build_text_column(rows, intro, width)
    local column = VerticalGroup:new{align = "left"}
    for _, row in ipairs(rows) do
        column[#column + 1] = TextBoxWidget:new{
            text = row[1] .. ": " .. row[2],
            face = Font:getFace("cfont", 18),
            width = width,
        }
        column[#column + 1] = VerticalSpan:new{width = Size.padding.small}
    end
    local excerpt = M.intro_excerpt(intro)
    if excerpt ~= "" then
        column[#column + 1] = VerticalSpan:new{width = Size.padding.small}
        column[#column + 1] = TextBoxWidget:new{
            text = excerpt,
            face = Font:getFace("cfont", 16),
            width = width,
            -- 墨水屏上灰色前景几乎不可读(真机验收反馈),用默认黑。
        }
    end
    return column
end

local BookDetailDialog = InputContainer:extend{
    row = nil,
    info = nil,
    cover_path = nil,
    on_bind = nil,
    cover_tmp = nil,
}

function BookDetailDialog:init()
    local screen_w = Screen:getWidth()
    local dialog_width = math.floor(screen_w * 0.85)
    -- FrameContainer 的 padding 与边框占据框宽,内容宽度必须从内框算起,
    -- 否则内容=框宽会向右溢出被裁(真机验收:右侧截断)。
    local inner_width = dialog_width - 2 * (Size.padding.large + Size.border.window)
    local cover_width = self.cover_path and math.floor(inner_width * 0.28) or 0
    local text_width = inner_width - cover_width
            - (self.cover_path and 2 * Size.padding.default or 0)

    local rows = M.build_rows(self.info)
    local body
    if self.cover_path then
        body = HorizontalGroup:new{
            ImageWidget:new{
                file = self.cover_path,
                width = cover_width,
                height = math.floor(cover_width * 1.5),
                scale_factor = 0,
                -- 与上游书架缩略图一致:短生命周期的页面内容,不进全局图片缓存。
                file_do_cache = false,
            },
            HorizontalSpan:new{width = 2 * Size.padding.default},
            M._build_text_column(rows, self.info and self.info.intro, text_width),
        }
    else
        body = M._build_text_column(rows, self.info and self.info.intro, text_width)
    end

    local title = TextWidget:new{
        text = "书籍详情",
        face = Font:getFace("cfont", 22),
        bold = true,
    }

    local function close()
        if self.cover_tmp then pcall(os.remove, self.cover_tmp) end
        UIManager:close(self)
        -- 与 show 同因:按钮点按自身会入队小区域刷新,裸 close 的"无人入队
        -- 则全屏兜底"被挤掉,弹窗残屏(真机验收:关闭不刷新)。显式入队。
        UIManager:setDirty(nil, "partial")
    end

    local function make_button(text, callback, enabled)
        return Button:new{
            text = text,
            callback = function()
                if not enabled then return end
                if callback == "close" then
                    close()
                else
                    close()
                    callback()
                end
            end,
            width = math.floor((dialog_width - 6 * Size.padding.default) / 2),
            bordersize = Size.border.button,
            face = Font:getFace("cfont", 18),
        }
    end

    self[1] = CenterContainer:new{
        dimen = Geom:new{w = screen_w, h = Screen:getHeight()},
        FrameContainer:new{
            width = dialog_width,
            background = Blitbuffer.COLOR_WHITE,
            bordersize = Size.border.window,
            radius = Size.radius.window,
            padding = Size.padding.large,
            VerticalGroup:new{
                align = "center",
                title,
                VerticalSpan:new{width = Size.padding.default},
                body,
                VerticalSpan:new{width = Size.padding.large},
                HorizontalGroup:new{
                    make_button("关闭", "close", true),
                    HorizontalSpan:new{width = 2 * Size.padding.default},
                    make_button("绑定此书", self.on_bind, type(self.on_bind) == "function"),
                },
            },
        },
    }
    self.dimen = Geom:new{w = screen_w, h = Screen:getHeight()}
end

--- —— R5 详情缓存 ——
-- 元数据(译者/出版社/年份)不可变,TTL 一个月(用户定案 2026-09-21);
-- 封面为缩放后 PNG 一并落盘。到期读取时自动删除缓存文件,不留残件。
local CACHE_TTL_SECONDS = 30 * 24 * 3600
local CACHE_NAME = "book-info.json"
M.COVER_CACHE_NAME = "book-detail-cover.png"

local function drop_cache_files(dir)
    pcall(os.remove, dir .. "/" .. CACHE_NAME)
    pcall(os.remove, dir .. "/" .. M.COVER_CACHE_NAME)
end

--- 读缓存:命中返回 (info, cover_path|nil);过期(顺带删除缓存文件)/缺失/
--- 损坏/无书名一律按未命中。
function M.load_cache(store, book_id)
    local dir = store:book_dir(book_id)
    local raw = U.read_file(dir .. "/" .. CACHE_NAME)
    if type(raw) ~= "string" or raw == "" then return nil end
    local ok, data = pcall(Json.decode, raw)
    if not ok or type(data) ~= "table" or type(data.info) ~= "table" then
        drop_cache_files(dir)
        return nil
    end
    local fetched = tonumber(data.fetched_at) or 0
    if fetched <= 0 or os.time() - fetched > CACHE_TTL_SECONDS then
        drop_cache_files(dir)
        return nil
    end
    local info = data.info
    if type(info.title) ~= "string" or info.title == "" then return nil end
    local cover
    if data.cover then
        local path = dir .. "/" .. M.COVER_CACHE_NAME
        if U.file_exists(path) then cover = path end
    end
    return info, cover
end

--- 写缓存:info 为归一化结果;cover_path 为落盘的封面 PNG(book_dir 内)或 nil。
--- 任一环节失败静默跳过(缓存是增强,不是依赖)。
function M.save_cache(store, book_id, info, cover_path)
    local ok, err = xpcall(function()
        local dir = store:book_dir(book_id)
        local payload = Json.encode({
            fetched_at = os.time(),
            info = info,
            cover = cover_path ~= nil,
        })
        U.atomic_write(dir .. "/" .. CACHE_NAME, payload)
    end, debug.traceback)
    if not ok then
        require("logger").warn("[撷思][BookDetail] cache save failed", tostring(err))
    end
end

--- 弹出详情。opts: {row=搜索行, info=normalize_book_info 结果,
--- cover_path=缩放后封面 PNG 路径或 nil, cover_tmp=关闭时要删的临时文件,
--- on_bind=绑定回调(function 或 nil, nil 时按钮置灰)}。
function M.show(opts)
    opts = opts or {}
    local dialog = BookDetailDialog:new{
        row = opts.row,
        info = opts.info,
        cover_path = opts.cover_path,
        cover_tmp = opts.cover_tmp,
        on_bind = opts.on_bind,
    }
    UIManager:show(dialog)
    -- 长按路径上 MenuItem 已为"行高亮"入队过一个小区域刷新,裸 show 依赖的
    -- "无人入队则全屏兜底"机制因此不再触发:弹窗画进 framebuffer 却不上屏,
    -- 表现为只闪行高亮那一小块(v2026.03 uimanager 源码核实)。显式入队
    -- 全屏 ui 刷新,不依赖兜底。
    UIManager:setDirty(dialog, "ui")
    return dialog
end

return M
