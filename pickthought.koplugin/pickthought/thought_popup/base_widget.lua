--[[--
想法弹窗公共基类(需求 R3:双实现收敛,见 docs/requirement-remediation-2026-09-06.md)。

只收敛与具体布局无关的方法;几何锚定与交互差异(居中分页 vs 底部滚动、
手势分区、导航栈恢复)仍留在 center_widget.lua 与 widget.lua。本类不定义
任何字段默认值,字段仍由各实现的 extend 原型提供。

方法来源:两条实现逐字节相同或仅注释不同的方法(_findItemAtContentY 与
onClose 的注释已合并);行为必须保持与收敛前完全一致。
--]]--

local ButtonDialog = require("ui/widget/buttondialog")
local CommentsView = require("pickthought.thought_popup.comments_view")
local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local PopupDiagnostic = require("pickthought.diagnostic")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")

local Screen = Device.screen

-- 与两实现一致:撷思用户可见文本即中文,`_` 为恒等占位,便于将来接翻译。
local function _(text) return text end

-- 视窗停稳防抖:连续翻页只保留最后一次(两实现共用同一节奏)。
local COMMENT_VIEWPORT_DEBOUNCE = 0.6

local BaseThoughtPopupWidget = InputContainer:extend{}

--- 内容变化后的重建:换字体/尺寸/条目时整体重排。
function BaseThoughtPopupWidget:_applyContent()
    self._pages:setContent(self.items, self.doc_font_name, self.doc_font_size,
        self.doc_margins, self.height_ratio, nil, self.contrast)
    self:_buildLayout()
end

--- 高度可能变化的重建后的重绘(进/出评论视图、补数刷新)。
--- 高度变化时请求整屏局部刷新,由渲染栈重画整屏清残影;
--- 未变化(等高)时维持原来的局部刷新。
function BaseThoughtPopupWidget:_applyContentAndRepaint()
    local height_before = self.height
    self:_applyContent()
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

function BaseThoughtPopupWidget:_copyThoughtContent(item)
    local text = tostring(item and item.content or "")
    if text == "" then return end
    if Device.hasClipboard and Device:hasClipboard() then
        Device.input.setClipboardText(text)
    end
end

function BaseThoughtPopupWidget:_freeContentCaches()
    self._pages:freeContentCaches()
end

function BaseThoughtPopupWidget:_generateQRCode(item)
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

--- X 键与物理 Back 共用的关闭决策:评论视图先返回想法视图。
function BaseThoughtPopupWidget:_handleCloseAction()
    if self._comment_view then
        return self:_backToThoughts()
    end
    UIManager:close(self)
end

--- 评论数懒加载的视窗停稳防抖:连续翻页只保留最后一次。
function BaseThoughtPopupWidget:_onVisibleItemsChanged()
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

--- 打开某条想法的评论:长按菜单与中间点击共用的链路。
function BaseThoughtPopupWidget:_openItemComments(item)
    if type(self.on_view_comments) ~= "function" then return end
    if type(item) ~= "table" or type(item.review_id) ~= "string"
        or item.review_id == "" then
        self:_showCommentNotice("这条想法缺少评论 ID")
        return
    end
    local diagnostic = PopupDiagnostic.is_enabled()
    if diagnostic then
        logger.info("[撷思][ReviewComments] menu action",
            "review_id=", tostring(item.review_id))
    end
    local call_ok, result = pcall(self.on_view_comments, item, self)
    if diagnostic then
        logger.info("[撷思][ReviewComments] callback done",
            "call_ok=", tostring(call_ok),
            "result=", type(result) == "table" and tostring(result.ok) or tostring(result))
    end
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

function BaseThoughtPopupWidget:_showCommentNotice(message)
    UIManager:show(InfoMessage:new{
        text = tostring(message or ""),
        timeout = 3,
    })
end

--- 长按想法的动作菜单:查看评论(无 review_id 置灰)/复制/生成二维码。
function BaseThoughtPopupWidget:_showThoughtActionMenu(item)
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

function BaseThoughtPopupWidget:free(full)
    WidgetContainer.free(self, full)
end

function BaseThoughtPopupWidget:onShow()
    UIManager:setDirty(self, function()
        return "partial", self.container.dimen
    end)
end

--- 命中点取物:引用块与 meta 行的偏移映射,长按/中间点击共用。
function BaseThoughtPopupWidget:_findItemAtContentY(y)
    local pieces = self._pages and self._pages.layout and self._pages.layout.pieces
    if not pieces then return nil end
    local item_idx = 0
    -- 首条不渲染 meta 行时(评论视图:居中是标题、底部是引用块),第 k 个
    -- meta 块对应 items[k+1]:用偏移修正定位,否则长按会错位到前一条。
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

--- 物理 Back 键:评论视图先返回想法视图,再次才关闭(与 X 键一致;
--- 底部布局没有 X,Back 承担同样的返回语义)。
function BaseThoughtPopupWidget:onClose()
    self:_handleCloseAction()
    return true
end

return BaseThoughtPopupWidget
