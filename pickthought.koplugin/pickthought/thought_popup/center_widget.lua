--[[--
Centered thought popup widget (TextViewer style).

Renders the same paginated review content as the bottom popup (shared
PageRenderer) inside a centered, rounded white window with a title bar and an
explicit Previous/Next page button row, mirroring KOReader's TextViewer look
(the style of the original thought dialog on this branch).

Long content — including a single long thought — flows across multiple pages;
there is no scrolling: navigation is page-index based (buttons, horizontal
swipes inside the window, or PgBack/PgFwd). Font sizes, margins and the
height ratio are the same settings the bottom popup uses.
--]]

local BD = require("ui/bidi")
local ButtonDialog = require("ui/widget/buttondialog")
local Blitbuffer = require("ffi/blitbuffer")
local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local CommentsView = require("pickthought.thought_popup.comments_view")
local Config = require("pickthought.config")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local PageRenderer = require("pickthought.thought_popup.pages")
local PageViewport = require("pickthought.thought_popup.page_viewport")
local Size = require("ui/size")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local Screen = Device.screen
local function _(text) return text end
local POPUP_DEFAULTS = Config.THOUGHT_POPUP_DEFAULTS
local POPUP_LIMITS = Config.THOUGHT_POPUP_LIMITS

local PADDING_TOP = Size.padding.large
local PADDING_BOTTOM = Size.padding.large
local BUTTON_PADDING = Size.padding.default

local CenterThoughtPopupWidget = InputContainer:extend{
    items = nil,
    doc_font_name = nil,
    doc_font_size = Screen:scaleBySize(18),
    doc_margins = {
        left = Screen:scaleBySize(20),
        right = Screen:scaleBySize(20),
        top = Screen:scaleBySize(10),
        bottom = Screen:scaleBySize(10),
    },
    height_ratio = POPUP_DEFAULTS.height_ratio,
    width_ratio = POPUP_DEFAULTS.width_ratio,
    contrast = 9,
    -- 配置层默认关闭；只有用户显式开启时才拦截窗口左右点按翻页。
    tap_to_page = false,
    comment_tap_open = false,
    close_callback = nil,
    dialog = nil,
    page_index = 1,
    -- 想法评论入口(main.lua 注入的只读回调,实施文档 §4):
    -- function(item, popup) -> result|nil,nil 表示异步加载中。
    on_view_comments = nil,
    -- 评论视图导航状态(实施文档 §5):_navigation 为想法视图状态栈,
    -- _comment_view 非空表示当前处于评论视图。
    _navigation = nil,
    _comment_view = nil,

    _pages = nil,
    _page_starts = nil,
    _titlebar = nil,
    _button_table = nil,
    _viewport = nil,
    container = nil,
}

function CenterThoughtPopupWidget:init()
    self.height_ratio = math.max(POPUP_LIMITS.min_height_ratio,
        math.min(POPUP_LIMITS.max_height_ratio, self.height_ratio or POPUP_DEFAULTS.height_ratio))
    self.width_ratio = math.max(POPUP_LIMITS.min_width_ratio,
        math.min(POPUP_LIMITS.max_width_ratio, self.width_ratio or POPUP_DEFAULTS.width_ratio))
    self.width = math.floor(Screen:getWidth() * self.width_ratio)
    self.height = math.floor(Screen:getHeight() * self.height_ratio)

    if Device:isTouchDevice() then
        local range = Geom:new{
            x = 0, y = 0,
            w = Screen:getWidth(),
            h = Screen:getHeight(),
        }
        self.ges_events = {
            TapClose = {
                GestureRange:new{
                    ges = "tap",
                    range = range,
                }
            },
            Swipe = {
                GestureRange:new{
                    ges = "swipe",
                    range = range,
                }
            },
            HoldThought = {
                GestureRange:new{
                    ges = "hold",
                    range = range,
                }
            },
        }
    end

    if Device:hasKeys() then
        local group = Device.input.group
        self.key_events = {}
        if group.Back then self.key_events.Close = { { group.Back } } end
        local previous = group.PgBack or group.PageBack or group.PageBackward or group.Left
        local following = group.PgFwd or group.PageForward or group.PageNext or group.Right
        if previous then self.key_events.PageBack = { { previous } } end
        if following then self.key_events.PageFwd = { { following } } end
    end

    self._pages = PageRenderer:new{
        items = self.items,
        doc_font_name = self.doc_font_name,
        doc_font_size = self.doc_font_size,
        doc_margins = self.doc_margins,
        height_ratio = self.height_ratio,
        content_width = self.width,
        contrast = self.contrast,
        skip_quote = true,
    }
    self:_buildLayout()
end

function CenterThoughtPopupWidget:onShow()
    UIManager:setDirty(self, function()
        return "partial", self.container.dimen
    end)
end

function CenterThoughtPopupWidget:_reopen(opts)
    local height_before = self.height
    self.items = opts.items or {}
    if opts.doc_font_name then self.doc_font_name = opts.doc_font_name end
    if opts.doc_font_size then self.doc_font_size = opts.doc_font_size end
    if opts.doc_margins then self.doc_margins = opts.doc_margins end
    if opts.height_ratio then self.height_ratio = opts.height_ratio end
    if opts.width_ratio then self.width_ratio = opts.width_ratio end
    if opts.contrast ~= nil then self.contrast = opts.contrast end
    if opts.tap_to_page ~= nil then self.tap_to_page = opts.tap_to_page end
    if opts.dialog then self.dialog = opts.dialog end
    self.close_callback = opts.close_callback
    self.on_view_comments = opts.on_view_comments
    self.on_visible_items_settled = opts.on_visible_items_settled
    if opts.comment_tap_open ~= nil then self.comment_tap_open = opts.comment_tap_open end
    -- 重开弹窗即新的一次会话:丢弃上一轮的评论导航状态(实施文档 §5)。
    self._navigation = nil
    self._comment_view = nil
    self.height_ratio = math.max(POPUP_LIMITS.min_height_ratio,
        math.min(POPUP_LIMITS.max_height_ratio, self.height_ratio or POPUP_DEFAULTS.height_ratio))
    self.width_ratio = math.max(POPUP_LIMITS.min_width_ratio,
        math.min(POPUP_LIMITS.max_width_ratio, self.width_ratio or POPUP_DEFAULTS.width_ratio))
    self.width = math.floor(Screen:getWidth() * self.width_ratio)
    self.height = math.floor(Screen:getHeight() * self.height_ratio)

    self._pages:setContent(self.items, self.doc_font_name, self.doc_font_size,
        self.doc_margins, self.height_ratio, self.width, self.contrast)
    self:_buildLayout()
    -- 换一条划线重开,高度可能不同(残影说明见 _applyContentAndRepaint)
    if self.height ~= height_before then
        UIManager:setDirty("all", "partial")
    end
end

--- Window title: the quoted abstract of the first review item (whitespace
--- collapsed, overflow truncated by TitleBar), or "Thoughts" when absent.
--- 评论视图下显示「想法评论 · N」(实施文档 §5)。
function CenterThoughtPopupWidget:_title()
    -- 评论视图:标题栏(第一层显示原文摘录的位置)显示被长按的想法本身。
    if self._comment_view then
        return self._comment_view.title
    end
    local abstract = self.items and self.items[1] and self.items[1].abstract
    if type(abstract) == "string" and abstract ~= "" then
        return abstract:gsub("%s+", " ")
    end
    return _("想法")
end

--- Previous / page indicator / Next button row.
function CenterThoughtPopupWidget:_buildButtons()
    local popup = self
    return {
        {
            text = "‹ " .. _("上一页"),
            id = "prev_page",
            vsync = true,
            callback = function()
                popup:changePage(-1)
            end,
        },
        {
            text = "1 / 1",
            id = "page_position",
            callback = function() end,
        },
        {
            text = _("下一页") .. " ›",
            id = "next_page",
            vsync = true,
            callback = function()
                popup:changePage(1)
            end,
        },
    }
end

function CenterThoughtPopupWidget:_buildLayout()
    self:clear()
    self.page_index = 1

    local renderer = self._pages
    renderer:ensureLayout()

    self._titlebar = TitleBar:new{
        width = self.width,
        align = "left",
        with_bottom_line = true,
        title = self:_title(),
        title_multilines = true,
        title_face = Font:getFace("x_smalltfont", 18),
        close_callback = function()
            -- X 键语义(实施文档 §5):评论视图第一次点 X 返回想法视图,
            -- 想法视图点 X 关闭整个弹窗。
            self:_handleCloseAction()
        end,
        show_parent = self,
    }

    local text_w = renderer.text_w

    self._button_table = ButtonTable:new{
        width = self.width - 2 * BUTTON_PADDING,
        buttons = { self:_buildButtons() },
        zero_sep = true,
        show_parent = self,
    }

    local chrome = self._titlebar:getHeight()
        + self._button_table:getSize().h
        + PADDING_TOP + PADDING_BOTTOM
    local ratio_h = math.floor(Screen:getHeight() * self.height_ratio)
    local blank_tolerance = math.ceil((self.doc_font_size or Screen:scaleBySize(18)) * 1.2)

    local viewport_h
    if renderer.content_h + chrome <= ratio_h - blank_tolerance then
        viewport_h = renderer.content_h
        self.height = renderer.content_h + chrome
    else
        viewport_h = ratio_h - chrome
        self.height = ratio_h
    end
    if viewport_h < 1 then viewport_h = 1 end
    self._viewport_h = viewport_h

    self._page_starts = renderer:computePages(viewport_h)
    local page_count = #self._page_starts
    self.page_index = math.min(self.page_index, page_count)

    self._viewport = PageViewport:new{
        dimen = Geom:new{ w = self.width, h = viewport_h },
        page_index_getter = function()
            return self.page_index
        end,
        margin_left = self.doc_margins.left,
        text_w = text_w,
        page_bb_getter = function(page_idx)
            return renderer:renderPage(page_idx, self._page_starts)
        end,
    }

    local frame = FrameContainer:new{
        radius = Size.radius.window,
        padding = 0,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            self._titlebar,
            VerticalSpan:new{ width = PADDING_TOP },
            self._viewport,
            VerticalSpan:new{ width = PADDING_BOTTOM },
            CenterContainer:new{
                dimen = Geom:new{
                    w = self.width,
                    h = self._button_table:getSize().h,
                },
                self._button_table,
            },
        },
    }
    self.container = frame
    self[1] = CenterContainer:new{
        dimen = Screen:getSize(),
        frame,
    }
    self:_syncButtons()
end

--- Flip to an adjacent page; clamps at the first/last page.
function CenterThoughtPopupWidget:changePage(delta)
    local total = self._page_starts and #self._page_starts or 0
    if total < 1 then return end
    local next_index = math.min(total, math.max(1, self.page_index + delta))
    if next_index == self.page_index then return end
    self.page_index = next_index
    self:_syncButtons()
    UIManager:setDirty(self, "partial", self.container.dimen)
    -- 翻页后可见集合变了:防抖触发"补当前页想法的评论数"。
    self:_onVisibleItemsChanged()
end

--- Keep the Previous/Next enabled states and the N / M indicator current.
function CenterThoughtPopupWidget:_syncButtons()
    local bt = self._button_table
    if not bt or not bt.getButtonById then return end
    local total = self._page_starts and #self._page_starts or 0
    local prev_btn = bt:getButtonById("prev_page")
    local next_btn = bt:getButtonById("next_page")
    local position_btn = bt:getButtonById("page_position")
    if prev_btn and prev_btn.enableDisable then
        prev_btn:enableDisable(self.page_index > 1)
    end
    if next_btn and next_btn.enableDisable then
        next_btn:enableDisable(self.page_index < total)
    end
    if position_btn and position_btn.setText then
        position_btn:setText(
            tostring(self.page_index) .. " / " .. tostring(total),
            position_btn.width)
    end
end

function CenterThoughtPopupWidget:onCloseWidget()
    -- 整个弹窗被关闭:清空导航栈并释放评论视图状态(实施文档 §5)。
    if self._viewport_settle_cb then
        UIManager:unschedule(self._viewport_settle_cb)
        self._viewport_settle_cb = nil
    end
    self._navigation = nil
    self._comment_view = nil
    UIManager:setDirty(self, function()
        return "partial", self.container.dimen
    end)
    if self.close_callback then
        local callback = self.close_callback
        self.close_callback = nil
        callback(self.height)
    end
end

function CenterThoughtPopupWidget:onClose()
    -- 物理 Back 键:评论视图先返回想法视图,再次才关闭(与 X 键一致)。
    self:_handleCloseAction()
    return true
end

--- 关闭请求入口:X 按钮 / Back 键共用。
function CenterThoughtPopupWidget:_handleCloseAction()
    if self._comment_view then
        return self:_backToThoughts()
    end
    UIManager:close(self)
end

function CenterThoughtPopupWidget:onTapClose(_, ges)
    if ges.pos:notIntersectWith(self.container.dimen) then
        -- 与 X 键/底部弹窗一致(用户拍板 2026-09-06):评论态第一次点击
        -- 返回想法视图,想法态才关闭整个弹窗。
        self:_handleCloseAction()
        return true
    end
    -- Optional tap zones: two halves by default; with the middle-tap feature
    -- on (and outside the comment view), thirds — left prev / middle opens
    -- the tapped thought's comments / right next.
    if self.tap_to_page then
        local dimen = self.container.dimen
        if self.comment_tap_open == true and not self._comment_view then
            local rel = (ges.pos.x - dimen.x) / dimen.w
            if rel < 1 / 3 then
                self:changePage(-1)
                return true
            elseif rel < 2 / 3 then
                self:_openCommentsAtGes(ges)
                return true
            end
        end
        if BD.flipIfMirroredUILayout(ges.pos.x < dimen.x + dimen.w / 2) then
            self:changePage(-1)
        else
            self:changePage(1)
        end
    end
    return true
end

function CenterThoughtPopupWidget:onSwipe(_, ges)
    local direction = BD.flipDirectionIfMirroredUILayout(ges.direction)
    if ges.pos:intersectWith(self.container.dimen) then
        -- Swipe inside the window flips pages (west = next, east = previous).
        if direction == "west" then
            self:changePage(1)
        elseif direction == "east" then
            self:changePage(-1)
        end
        return true
    end
    -- Swipe outside the window: west/east close it (like the bottom popup).
    if direction == "west" or direction == "east" then
        UIManager:close(self)
        return true
    end
    return false
end

function CenterThoughtPopupWidget:onPageBack()
    self:changePage(-1)
    return true
end

function CenterThoughtPopupWidget:onPageFwd()
    self:changePage(1)
    return true
end

function CenterThoughtPopupWidget:onHoldThought(_, ges)
    local viewport = self._viewport
    if viewport and viewport.dimen and ges.pos:intersectWith(viewport.dimen) then
        local content_y = (ges.pos.y - viewport.dimen.y) + (self._page_starts[self.page_index] or 0)
        local item = self:_findItemAtContentY(content_y)
        if item then
            self:_showThoughtActionMenu(item)
        end
    end
    return true
end

function CenterThoughtPopupWidget:_findItemAtContentY(y)
    local pieces = self._pages and self._pages.layout and self._pages.layout.pieces
    if not pieces then return nil end
    local item_idx = 0
    -- 首条不渲染 meta 行时(评论视图形状),第 k 个 meta 块对应 items[k+1]:
    -- 用偏移修正定位,否则长按会错位到前一条。
    local meta_base = CommentsView.first_item_has_meta(self.items) and 0 or 1
    for _, piece in ipairs(pieces) do
        if piece.variant == "meta" then
            item_idx = item_idx + 1
        end
        if piece.y and piece.piece_h and piece.y <= y and y < piece.y + piece.piece_h then
            if piece.variant == "quote" then
                return self.items and self.items[1]
            end
            local mapped = item_idx + meta_base
            if item_idx >= 1 and self.items and mapped >= 1 and mapped <= #self.items then
                return self.items[mapped]
            end
            return nil
        end
    end
    return nil
end

function CenterThoughtPopupWidget:_showThoughtActionMenu(item)
    local popup = self
    -- 评论入口可用性(实施文档 §4):需要回调注入且该想法带 review_id;
    -- 不可用时仍显示菜单项但置灰,让用户知道是数据缺少评论 ID。
    local viewable = type(popup.on_view_comments) == "function"
        and type(item) == "table"
        and type(item.review_id) == "string"
        and item.review_id ~= ""
    local action_dialog
    -- 评论视图里没有"评论的评论"(用户拍板 2026-09-06):评论是最后一层,
    -- 菜单不再提供查看评论入口(评论层仍保留复制/二维码)。
    local button_rows = {}
    if not self._comment_view then
        button_rows[#button_rows + 1] = {
            {
                text = _("查看评论"),
                enabled = viewable,
                callback = function()
                    UIManager:close(action_dialog)
                    popup:_openItemComments(item)
                end,
            },
        }
    end
    button_rows[#button_rows + 1] = {
        {
            text = _("复制"),
            callback = function()
                UIManager:close(action_dialog)
                popup:_copyThoughtContent(item)
            end,
        },
        {
            text = _("生成二维码"),
            callback = function()
                UIManager:close(action_dialog)
                popup:_generateQRCode(item)
            end,
        },
    }
    action_dialog = ButtonDialog:new{
        buttons = button_rows,
    }
    UIManager:show(action_dialog)
end

--- 打开某条想法的评论:长按菜单"查看评论"与中间点击共用的链路。
--- 同步路径返回结果形态;nil 表示已进入异步联网等待,由 plugin 侧在
--- 加载完成后回调 popup:_enterComments。真机上回调抛错会被 KOReader
--- 事件循环吞掉,表现为"点击无反应";pcall 后至少给出提示,便于定位。
function CenterThoughtPopupWidget:_openItemComments(item)
    if type(self.on_view_comments) ~= "function" then return end
    if type(item) ~= "table" or type(item.review_id) ~= "string"
        or item.review_id == "" then
        self:_showCommentNotice("这条想法缺少评论 ID")
        return
    end
    logger.info("[撷思][ReviewComments] menu action",
        "review_id=", tostring(item.review_id))
    local call_ok, result = pcall(self.on_view_comments, item, self)
    logger.info("[撷思][ReviewComments] callback done",
        "call_ok=", tostring(call_ok),
        "result=", type(result) == "table" and tostring(result.ok) or tostring(result))
    if not call_ok then
        self:_showCommentNotice("评论加载失败:" .. tostring(result):gsub("%c+", " "))
        return
    end
    if result == nil then return end
    if type(result) == "table" and result.ok then
        self:_enterComments(item, result)
    elseif type(result) == "table" then
        self:_showCommentNotice(result.message or "评论加载失败")
    end
end

--- 中间点击打开评论(需求 2026-09-06):点击位置命中想法 → 走与菜单
--- "查看评论"相同的链路;未命中(条目间隙/空白)不动作。
function CenterThoughtPopupWidget:_openCommentsAtGes(ges)
    local viewport = self._viewport
    if not (viewport and viewport.dimen) then return end
    if not ges.pos:intersectWith(viewport.dimen) then return end
    local content_y = (ges.pos.y - viewport.dimen.y)
        + (self._page_starts and self._page_starts[self.page_index] or 0)
    local item = self:_findItemAtContentY(content_y)
    if item then self:_openItemComments(item) end
end

function CenterThoughtPopupWidget:_showCommentNotice(message)
    UIManager:show(InfoMessage:new{
        text = tostring(message or ""),
        timeout = 3,
    })
end

--- 进入评论视图(实施文档 §5):压栈想法视图状态,切换渲染内容。
--- @return boolean 是否切换成功(false = 弹窗已关闭/结果为空评论)
function CenterThoughtPopupWidget:_enterComments(item, result)
    local ok_shown, shown = pcall(function()
        return UIManager:isWidgetShown(self) ~= false
    end)
    if ok_shown and not shown then
        -- 联网等待期间弹窗已被关闭:丢弃迟到的结果。
        return false
    end
    if type(result) ~= "table" or not result.ok then return false end
    local comments = type(result.items) == "table" and result.items or {}
    if #comments == 0 then
        self:_showCommentNotice("这条想法暂无评论")
        return false
    end
    self._navigation = self._navigation or {}
    self._navigation[#self._navigation + 1] = {
        kind = "thoughts",
        items = self.items,
        page_index = self.page_index,
    }
    -- 就地记录评论数:item 与 self.items 里的想法条目是同一张表,
    -- 翻页回到列表后 meta 行即可显示"评论 N"(下次点开会刷新)。
    if type(item) == "table" then
        item.comment_count = tonumber(result.total_count)
            or tonumber(item.comment_count) or 0
    end
    self._comment_view = {
        parent_item = item,
        title = CommentsView.comment_title(item),
        total_count = result.total_count,
    }
    -- 居中布局:那条想法显示在标题栏(原原文摘录的位置),内容区只有评论。
    self.items = CommentsView.build_items(item, comments, "center")
    -- 关键:弹窗已处于显示状态时,_buildLayout 不会自动触发重绘;
    -- 缺少 setDirty 会导致屏幕停留在旧的想法弹窗,看起来像"没有反应"。
    self:_applyContentAndRepaint()
    return true
end

--- 返回想法视图:弹栈、恢复页码,并释放评论页位图与解析结果。
function CenterThoughtPopupWidget:_backToThoughts()
    local stack = self._navigation
    if not stack or #stack == 0 then return false end
    local state = table.remove(stack)
    if #stack == 0 then self._navigation = nil end
    self._comment_view = nil
    -- 释放评论页位图/解析结果;想法视图在 setContent 后重新分页。
    self._pages:freeContentCaches()
    self.items = state.items
    local restore_index = tonumber(state.page_index) or 1
    self:_applyContentAndRepaint()
    local total = self._page_starts and #self._page_starts or 1
    self.page_index = math.min(math.max(1, restore_index), total)
    self:_syncButtons()
    -- 回到想法视图,可见集合变了:按防抖节奏补一轮当前页的评论数。
    self:_onVisibleItemsChanged()
    return true
end

--- 用当前 items 重建分页与布局(进入/返回评论视图共用)。
function CenterThoughtPopupWidget:_applyContent()
    self._pages:setContent(self.items, self.doc_font_name, self.doc_font_size,
        self.doc_margins, self.height_ratio, nil, self.contrast)
    self:_buildLayout()
end

--- 高度可能变化的重建后的重绘(进/出评论视图、补数刷新)。
--- 居中弹窗内容矮于视口时会缩到内容高度(居中锚定):高度变化时旧帧
--- 超出新帧的部分上下两头都不在 container.dimen 里,按新区域局部刷新
--- 会给 e-ink 留下旧弹窗框的残影(真机:评论视图退回想法视图后旧弹窗
--- "一头一尾"残留,多轮切换多帧重叠)。高度变化时请求整屏局部刷新,
--- 由渲染栈重画整屏,残影连背景一起清掉;未变化时维持原来的局部刷新。
--- 与底部弹窗同款(底部组件同函数),两弹窗行为保持一致。
function CenterThoughtPopupWidget:_applyContentAndRepaint()
    local height_before = self.height
    self:_applyContent()
    -- 定位日志:残影排查期间记录每次重建的前后高度与刷新方式
    logger.info("[撷思][ThoughtPopup] rebuild repaint",
        "height_before=", tostring(height_before),
        "height_after=", tostring(self.height),
        "fullscreen=", tostring(self.height ~= height_before))
    if self.height ~= height_before then
        -- 高度变化:旧帧可能超出新帧,只标弹窗自己脏的话,弹窗把自己画小了,
        -- 底下阅读器不会重画旧帧区域,帧缓冲里残留旧弹窗像素——整屏 refresh
        -- 推到 e-ink 的仍是残影(真机已证)。必须标记全部窗口脏:阅读器把
        -- 书页重画进帧缓冲,残影才被真正覆盖。
        UIManager:setDirty("all", "partial")
    else
        UIManager:setDirty(self, "partial", self.container.dimen)
    end
end

--- 后台评论数补齐后刷新想法视图(meta 行"评论 N")。
--- 评论视图下不动作(条目是同一张表,翻回来自然可见);想法视图下
--- 保留当前页码,只重排重绘。
function CenterThoughtPopupWidget:refresh_comment_counts()
    if self._comment_view then return end
    local shown = true
    pcall(function() shown = UIManager:isWidgetShown(self) ~= false end)
    if not shown then return end
    local page_before = self.page_index
    self:_applyContentAndRepaint()
    local total = self._page_starts and #self._page_starts or 1
    self.page_index = math.min(math.max(1, page_before), total)
    self:_syncButtons()
    -- 真机定位日志:评论数补齐后若出现自动翻页,对比前后页码即可锁定
    logger.info("[撷思][ThoughtPopup] refresh_comment_counts",
        "page_before=", tostring(page_before),
        "page_after=", tostring(self.page_index),
        "pages=", tostring(total))
end

-- 评论数懒加载(需求 2026-09-06):只补当前页的想法,翻页停下来
-- COMMENT_VIEWPORT_DEBOUNCE 秒后才触发,连续翻页只保留最后一次。
local COMMENT_VIEWPORT_DEBOUNCE = 0.6

function CenterThoughtPopupWidget:_onVisibleItemsChanged()
    if type(self.on_visible_items_settled) ~= "function" then return end
    if self._viewport_settle_cb then
        UIManager:unschedule(self._viewport_settle_cb)
    end
    local cb = function()
        self._viewport_settle_cb = nil
        if self._comment_view then return end  -- 评论视图不补
        self.on_visible_items_settled()
    end
    self._viewport_settle_cb = cb
    UIManager:scheduleIn(COMMENT_VIEWPORT_DEBOUNCE, cb)
end

--- 当前页内的想法条目(_page_starts 存内容 y 偏移,与底部同一套
--- "y 窗口 → 可见条目"规则)。
function CenterThoughtPopupWidget:visible_thought_items()
    local pieces = self._pages and self._pages.layout and self._pages.layout.pieces
    if not (pieces and self._viewport_h) then return {} end
    local top = (self._page_starts and self._page_starts[self.page_index]) or 0
    return CommentsView.items_in_view(self.items, pieces, top, top + self._viewport_h)
end

function CenterThoughtPopupWidget:_copyThoughtContent(item)
    local text = tostring(item and item.content or "")
    if text == "" then return end
    if Device.hasClipboard and Device:hasClipboard() then
        Device.input.setClipboardText(text)
    end
end

function CenterThoughtPopupWidget:_generateQRCode(item)
    local text = tostring(item and item.content or "")
    if text == "" then return end
    if Device.hasClipboard and Device:hasClipboard() then
        Device.input.setClipboardText(text)
    end
    local QRMessage = require("ui/widget/qrmessage")
    UIManager:show(QRMessage:new{
        text = text,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
    })
end

function CenterThoughtPopupWidget:free(full)
    WidgetContainer.free(self, full)
end

function CenterThoughtPopupWidget:_freeContentCaches()
    self._pages:freeContentCaches()
end

return CenterThoughtPopupWidget
