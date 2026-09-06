--[[--
Thought popup widget (bottom position).

Renders review items by shaping each text block with the document font (or a
fallback chain) and paginating once; pages are blitted into a bitmap viewport
that scrolls. Long content scrolls directly, with no button navigation.

Pagination, layout, page and piece caches live in pickthought/thought_popup/
pages.lua (PageRenderer), shared with the centered popup
(center_widget.lua). This module composes the renderer into the bottom bar:
a solid top border, a scrollable page viewport (scroll_container.lua), and
bottom/tap/Back gestures.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local ButtonDialog = require("ui/widget/buttondialog")
local CommentsView = require("pickthought.thought_popup.comments_view")
local Config = require("pickthought.config")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local PageRenderer = require("pickthought.thought_popup.pages")
local ScrollContainer = require("pickthought.thought_popup.scroll_container")
local Size = require("ui/size")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen = Device.screen
local function _(text) return text end
local POPUP_DEFAULTS = Config.THOUGHT_POPUP_DEFAULTS
local POPUP_LIMITS = Config.THOUGHT_POPUP_LIMITS

local TOP_BORDER_SIZE = Size.line.thick
local PADDING_TOP = Size.padding.large
local PADDING_BOTTOM = Size.padding.large

local ThoughtPopupWidget = InputContainer:extend{
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
    contrast = 9,
    tap_to_page = false,
    comment_tap_open = false,
    close_callback = nil,
    dialog = nil,
    -- 想法评论入口(main.lua 注入的只读回调,实施文档 §4)。
    on_view_comments = nil,
    -- 评论视图导航状态(实施文档 §5),与居中组件语义一致。
    _navigation = nil,
    _comment_view = nil,
    -- 返回想法视图时待恢复的滚动偏移,_buildLayout 消费后清零。
    _restore_scroll_offset = nil,

    _pages = nil,
    _scroll_container = nil,

    covers_footer = true,
}

function ThoughtPopupWidget:init()
    self.height_ratio = math.max(POPUP_LIMITS.min_height_ratio,
        math.min(POPUP_LIMITS.max_height_ratio, self.height_ratio or POPUP_DEFAULTS.height_ratio))
    self.width = Screen:getWidth()
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
            SwipeClose = {
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
        local group = Device.input and Device.input.group or {}
        self.key_events = {}
        if group.Back then self.key_events.Close = { { group.Back } } end
    end

    self._pages = PageRenderer:new{
        items = self.items,
        doc_font_name = self.doc_font_name,
        doc_font_size = self.doc_font_size,
        doc_margins = self.doc_margins,
        height_ratio = self.height_ratio,
        contrast = self.contrast,
    }
    self._pages:ensureLayout()
    self:_buildLayout()
end

function ThoughtPopupWidget:onShow()
    UIManager:setDirty(self, function()
        return "partial", self.container.dimen
    end)
end

function ThoughtPopupWidget:_reopen(opts)
    local height_before = self.height
    self.items = opts.items or {}
    if opts.doc_font_name then self.doc_font_name = opts.doc_font_name end
    if opts.doc_font_size then self.doc_font_size = opts.doc_font_size end
    if opts.doc_margins then self.doc_margins = opts.doc_margins end
    if opts.height_ratio then self.height_ratio = opts.height_ratio end
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
    self._restore_scroll_offset = nil
    self.height_ratio = math.max(POPUP_LIMITS.min_height_ratio,
        math.min(POPUP_LIMITS.max_height_ratio, self.height_ratio or POPUP_DEFAULTS.height_ratio))
    self.height = math.floor(Screen:getHeight() * self.height_ratio)

    self._pages:setContent(self.items, self.doc_font_name, self.doc_font_size,
        self.doc_margins, self.height_ratio, nil, self.contrast)
    self:_buildLayout()
    -- 换一条划线重开,高度可能不同(残影说明见 _applyContentAndRepaint)
    if self.height ~= height_before then
        UIManager:setDirty("all", "partial")
    end
end

function ThoughtPopupWidget:_buildLayout()
    self:clear()

    local item_width = math.min(math.ceil(self.doc_margins.right * 2 / 5), Screen:scaleBySize(10))
    local text_w = self._pages.text_w
    local content_h = self._pages.content_h

    local ratio_h = math.floor(Screen:getHeight() * self.height_ratio)
    local chrome = TOP_BORDER_SIZE + PADDING_TOP + PADDING_BOTTOM
    local blank_tolerance = math.ceil((self.doc_font_size or Screen:scaleBySize(18)) * 1.2)

    local viewport_h
    if content_h + chrome <= ratio_h - blank_tolerance then
        viewport_h = content_h
        self.height = content_h + chrome
    else
        viewport_h = ratio_h - chrome
        self.height = ratio_h
    end
    if viewport_h < 1 then viewport_h = 1 end

    local scroll = ScrollContainer:new{
        content_h = content_h,
        viewport_h = viewport_h,
        scroll_offset = self._restore_scroll_offset or 0,
        scrollbar_w = item_width,
        margin_left = self.doc_margins.left,
        text_w = text_w,
        dialog = self,
        tap_to_page = self.tap_to_page,
        boundaries = self._pages.boundaries,
        -- 滚动/翻页后通知宿主:防抖触发"补当前可见想法的评论数"
        on_offset_changed = function()
            self:_onVisibleItemsChanged()
        end,
        -- 三分区的中间 tap 抛给宿主做条目命中(评论数懒加载需求);
        -- 评论视图/未开启时为 nil,容器保持左右二分。
        on_tap_center = (self.comment_tap_open == true and not self._comment_view)
            and function(ges) self:_openCommentsAtGes(ges) end or nil,
        page_bb_getter = function(page_idx)
            local pages = self._scroll_container and self._scroll_container.pages
            return self._pages:renderPage(page_idx, pages)
        end,
    }
    self._restore_scroll_offset = nil
    self._scroll_container = scroll

    local vgroup_children = {
        LineWidget:new{
            dimen = Geom:new{ w = self.width, h = TOP_BORDER_SIZE },
        },
        VerticalSpan:new{ width = PADDING_TOP },
        scroll,
        VerticalSpan:new{ width = PADDING_BOTTOM },
    }

    local vgroup = VerticalGroup:new(vgroup_children)

    self.container = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        margin = 0,
        padding = 0,
        vgroup,
    }

    self[1] = BottomContainer:new{
        dimen = Screen:getSize(),
        self.container
    }
end

function ThoughtPopupWidget:onCloseWidget()
    -- 整个弹窗被关闭:清空导航栈并释放评论视图状态(实施文档 §5)。
    if self._viewport_settle_cb then
        UIManager:unschedule(self._viewport_settle_cb)
        self._viewport_settle_cb = nil
    end
    self._navigation = nil
    self._comment_view = nil
    self._restore_scroll_offset = nil
    UIManager:setDirty(self, function()
        return "partial", self.container.dimen
    end)
    if self.close_callback then
        local callback = self.close_callback
        self.close_callback = nil
        callback(self.height)
    end
end

function ThoughtPopupWidget:onClose()
    -- 底部布局没有 X 按钮,Back 键承担同样的返回语义:
    -- 评论视图第一次 Back 返回想法视图,再次才关闭。
    self:_handleCloseAction()
    return true
end

--- 关闭请求入口:Back 键 / 横向滑动共用(底部布局的 X 等价操作)。
function ThoughtPopupWidget:_handleCloseAction()
    if self._comment_view then
        return self:_backToThoughts()
    end
    UIManager:close(self)
end

function ThoughtPopupWidget:onTapClose(_, ges)
    if ges.pos:notIntersectWith(self.container.dimen) then
        -- 底部布局没有 X 按钮,点击弹窗外承担同样的返回语义:
        -- 评论视图第一次点击返回想法视图,再次才关闭整个弹窗。
        self:_handleCloseAction()
    end
    return true
end

function ThoughtPopupWidget:onSwipeClose(_, ges)
    local BD = require("ui/bidi")
    local direction = BD.flipDirectionIfMirroredUILayout(ges.direction)
    if direction == "west" or direction == "east" then
        -- 评论视图下横向滑动 = 返回想法视图;想法视图 = 关闭整个弹窗
        -- (底部布局用滑动承担居中布局 X 键的返回语义,实施文档 §5)。
        self:_handleCloseAction()
        return true
    end
    if ges.pos:intersectWith(self.container.dimen) then
        return true
    end
    return false
end

function ThoughtPopupWidget:onHoldThought(_, ges)
    local scroll = self._scroll_container
    if scroll and scroll.dimen and ges.pos:intersectWith(scroll.dimen) then
        local content_y = (ges.pos.y - scroll.dimen.y) + (scroll.scroll_offset or 0)
        local item = self:_findItemAtContentY(content_y)
        if item then
            self:_showThoughtActionMenu(item)
        end
    end
    return true
end

function ThoughtPopupWidget:_findItemAtContentY(y)
    local pieces = self._pages and self._pages.layout and self._pages.layout.pieces
    if not pieces then return nil end
    local item_idx = 0
    -- items[1] 不渲染 meta 行时(底部评论视图的引用块),第 k 个 meta 块
    -- 对应 items[k+1]:用偏移修正定位,否则长按评论会错位到前一条。
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

function ThoughtPopupWidget:_showThoughtActionMenu(item)
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
function ThoughtPopupWidget:_openItemComments(item)
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
function ThoughtPopupWidget:_openCommentsAtGes(ges)
    local scroll = self._scroll_container
    if not (scroll and scroll.dimen) then return end
    if not ges.pos:intersectWith(scroll.dimen) then return end
    local content_y = (ges.pos.y - scroll.dimen.y) + (scroll.scroll_offset or 0)
    local item = self:_findItemAtContentY(content_y)
    if item then self:_openItemComments(item) end
end

function ThoughtPopupWidget:_showCommentNotice(message)
    UIManager:show(InfoMessage:new{
        text = tostring(message or ""),
        timeout = 3,
    })
end

--- 进入评论视图(实施文档 §5):压栈想法视图状态,切换渲染内容。
--- @return boolean 是否切换成功(false = 弹窗已关闭/结果为空评论)
function ThoughtPopupWidget:_enterComments(item, result)
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
        scroll_offset = self._scroll_container and self._scroll_container.scroll_offset or 0,
    }
    -- 就地记录评论数:item 与 self.items 里的想法条目是同一张表,
    -- 返回想法列表后 meta 行即可显示"评论 N"(下次点开会刷新)。
    if type(item) == "table" then
        item.comment_count = tonumber(result.total_count)
            or tonumber(item.comment_count) or 0
    end
    self._comment_view = {
        parent_item = item,
        total_count = result.total_count,
    }
    self.items = CommentsView.build_items(item, comments, "bottom")
    -- 同居中组件:弹窗显示中重建布局必须显式请求重绘。
    self:_applyContentAndRepaint()
    return true
end

--- 返回想法视图:弹栈、恢复滚动位置,并释放评论页位图与解析结果。
function ThoughtPopupWidget:_backToThoughts()
    local stack = self._navigation
    if not stack or #stack == 0 then return false end
    local state = table.remove(stack)
    if #stack == 0 then self._navigation = nil end
    self._comment_view = nil
    -- 释放评论页位图/解析结果;想法视图在 setContent 后重新分页。
    self._pages:freeContentCaches()
    self.items = state.items
    self._restore_scroll_offset = tonumber(state.scroll_offset) or 0
    -- 弹窗显示中重建布局必须显式请求重绘,否则墨水屏停留在评论视图
    -- (内部状态已切回),表现为"回不到想法列表"。
    self:_applyContentAndRepaint()
    -- 回到想法视图,可见集合变了:按防抖节奏补一轮可见条目的评论数。
    self:_onVisibleItemsChanged()
    return true
end

--- 高度可能变化的重建后的重绘(进/出评论视图、补数刷新)。
--- 底部弹窗底部锚定、高度随内容变:变矮时旧帧高出新帧的部分不在
--- container.dimen 里,按新区域局部刷新会给 e-ink 留下旧弹窗框的残影
--- (真机:评论视图退回想法视图后旧弹窗残留,多轮切换后多帧重叠)。
--- 高度变化时请求整屏局部刷新,由渲染栈重画整屏,残影连背景一起清掉;
--- 未变化(等高)时维持原来的局部刷新。
function ThoughtPopupWidget:_applyContentAndRepaint()
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

--- 用当前 items 重建分页与布局(进入/返回评论视图共用)。
function ThoughtPopupWidget:_applyContent()
    self._pages:setContent(self.items, self.doc_font_name, self.doc_font_size,
        self.doc_margins, self.height_ratio, nil, self.contrast)
    self:_buildLayout()
end

--- 后台评论数补齐后刷新想法视图(meta 行"评论 N")。
--- 评论视图下不动作(条目是同一张表,返回时自然可见);想法视图下
--- 保留当前滚动位置,只重排重绘。
function ThoughtPopupWidget:refresh_comment_counts()
    if self._comment_view then return end
    local shown = true
    pcall(function() shown = UIManager:isWidgetShown(self) ~= false end)
    if not shown then return end
    local scroll_before = self._scroll_container
        and self._scroll_container.scroll_offset or 0
    self._restore_scroll_offset = scroll_before
    self:_applyContentAndRepaint()
    -- 真机定位日志:评论数补齐后若出现滚动位置跳动,对比前后偏移即可锁定
    logger.info("[撷思][ThoughtPopup] refresh_comment_counts",
        "scroll_before=", tostring(scroll_before),
        "scroll_after=", tostring(self._scroll_container
            and self._scroll_container.scroll_offset or 0))
end

-- 评论数懒加载(需求 2026-09-06):只补当前视口内的想法,翻页/滚动
-- 停下来 COMMENT_VIEWPORT_DEBOUNCE 秒后才触发,连续翻页只保留最后一次。
local COMMENT_VIEWPORT_DEBOUNCE = 0.6

function ThoughtPopupWidget:_onVisibleItemsChanged()
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

--- 当前视口内的想法条目(交宿主按缓存状态决定补哪些)。
function ThoughtPopupWidget:visible_thought_items()
    local pieces = self._pages and self._pages.layout and self._pages.layout.pieces
    local scroll = self._scroll_container
    if not (pieces and scroll) then return {} end
    local top = tonumber(scroll.scroll_offset) or 0
    local viewport_h = tonumber(scroll.viewport_h)
    if not viewport_h or viewport_h < 1 then return {} end
    return CommentsView.items_in_view(self.items, pieces, top, top + viewport_h)
end

function ThoughtPopupWidget:_copyThoughtContent(item)
    local text = tostring(item and item.content or "")
    if text == "" then return end
    if Device.hasClipboard and Device:hasClipboard() then
        Device.input.setClipboardText(text)
    end
end

function ThoughtPopupWidget:_generateQRCode(item)
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

function ThoughtPopupWidget:free(full)
    WidgetContainer.free(self, full)
end

function ThoughtPopupWidget:_freeContentCaches()
    self._pages:freeContentCaches()
end

return ThoughtPopupWidget
