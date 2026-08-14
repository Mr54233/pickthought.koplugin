-- 想法弹窗实体翻页键回归测试。

package.preload["device"] = function()
    return {
        screen = {
            getWidth = function() return 600 end,
            getHeight = function() return 800 end,
            scaleBySize = function(_, value) return value end,
        },
        hasKeys = function() return true end,
        input = {group = {PgBack = "PgBack", PgFwd = "PgFwd", Back = "Back"}},
    }
end

package.preload["ui/bidi"] = function()
    return {
        flipIfMirroredUILayout = function(value) return value end,
        flipDirectionIfMirroredUILayout = function(value) return value end,
    }
end

package.preload["ui/font"] = function()
    return {getFace = function(_, _, size) return {size = size} end}
end

package.preload["ui/widget/textboxwidget"] = function()
    local TextBoxWidget = {}
    function TextBoxWidget:new(fields)
        fields = fields or {}
        function fields:getAllLineCount()
            local _, separators = tostring(self.text or ""):gsub("\n\n", "")
            return separators + 1
        end
        function fields:free() end
        return fields
    end
    return TextBoxWidget
end

package.preload["ui/uimanager"] = function()
    local UIManager = {dirty = {}}
    function UIManager:show(widget) self.active = widget end
    function UIManager:close(widget) if self.active == widget then self.active = nil end end
    function UIManager:isWidgetShown(widget) return self.active == widget end
    function UIManager:setDirty(widget, mode, region)
        self.dirty[#self.dirty + 1] = {widget = widget, mode = mode, region = region}
    end
    return UIManager
end

package.preload["ui/widget/textviewer"] = function()
    local TextViewer = {}

    function TextViewer:extend(fields)
        fields = fields or {}
        fields.__index = fields
        return setmetatable(fields, {__index = self})
    end

    function TextViewer:new(fields)
        local instance = setmetatable(fields or {}, self)
        if instance.init then instance:init(false) end
        return instance
    end

    function TextViewer:init()
        self.key_events = {
            Close = {{"Back"}},
            ScrollOrPrev = {{"PgBack"}},
            ScrollOrNext = {{"PgFwd"}},
        }
        self.box_widget = {
            getVisLineCount = function() return 1 end,
            setText = function(widget, text) widget.text = text end,
        }
        self.scroll_widget = {
            text_widget = self.box_widget,
            setTapScrollEnabled = function() end,
            resetScroll = function() end,
            scrollText = function() end,
        }
        self.textw = {dimen = {id = "text"}}
        self.frame = {dimen = {id = "frame"}}
        self.titlebar = {
            setTitle = function(widget)
                widget.set_title_calls = (widget.set_title_calls or 0) + 1
            end,
        }
        self.button_table = nil
    end

    function TextViewer:onKeyPress(key)
        for name, sequence in pairs(self.key_events or {}) do
            if not sequence.is_inactive and sequence[1]
                    and sequence[1][1] == key then
                local event_name = sequence.event or name
                local handler = self["on" .. event_name]
                return handler and handler(self, sequence.args)
            end
        end
    end

    function TextViewer:onTapClose() return true end
    function TextViewer:onSwipe() return true end
    function TextViewer:onCloseWidget() end
    return TextViewer
end

for _, module_name in ipairs({
    "device",
    "ui/bidi",
    "ui/font",
    "ui/widget/textboxwidget",
    "ui/uimanager",
    "ui/widget/textviewer",
    "pickthought.thought_popup",
}) do
    package.loaded[module_name] = nil
end

local Popup = require("pickthought.thought_popup")
local UIManager = require("ui/uimanager")

T.case("想法弹窗绑定实体翻页键", function()
    local popup = Popup.show{items = {
        {author = "甲", content = "第一条"},
        {author = "乙", content = "第二条"},
    }}

    T.ok(popup.key_events.ScrollOrPrev
        and popup.key_events.ScrollOrPrev[1][1] == "PgBack"
        and popup.key_events.ScrollOrPrev.event == "PreviousThought",
        "PgBack 应绑定上一条想法")
    T.ok(popup.key_events.ScrollOrNext
        and popup.key_events.ScrollOrNext[1][1] == "PgFwd"
        and popup.key_events.ScrollOrNext.event == "NextThought",
        "PgFwd 应绑定下一条想法")

    T.eq(popup.page_index, 1, "弹窗从第一条开始")
    T.eq(popup.titlebar.set_title_calls, 1, "顶部摘录只在初始化时设置")
    UIManager.dirty = {}
    T.ok(popup:onKeyPress("PgFwd"), "PgFwd 事件应被消费")
    T.eq(popup.page_index, 2, "PgFwd 切换到下一条")
    T.eq(popup.titlebar.set_title_calls, 1, "按键切换不重新设置顶部摘录")
    local dirty = UIManager.dirty[#UIManager.dirty]
    T.eq(dirty.widget, popup, "正文刷新仍标记弹窗")
    T.eq(dirty.region, popup.textw.dimen, "正文刷新区域使用 textw")
    T.ok(dirty.region ~= popup.frame.dimen, "正文刷新不使用整个弹窗区域")
    T.ok(popup:onKeyPress("PgBack"), "PgBack 事件应被消费")
    T.eq(popup.page_index, 1, "PgBack 切换到上一条")

    T.ok(popup:onKeyPress("PgBack"), "第一页仍应消费 PgBack")
    T.eq(popup.page_index, 1, "第一页不能越界")
    T.ok(popup:onKeyPress("PgFwd"), "最后一页仍应消费 PgFwd")
    T.ok(popup:onKeyPress("PgFwd"), "最后一页重复按键仍应消费")
    T.eq(popup.page_index, 2, "最后一页不能越界")

    T.ok(type(popup.onTapClose) == "function", "触摸点按处理仍存在")
    T.ok(type(popup.onSwipe) == "function", "触摸滑动处理仍存在")
    Popup.close_visible()
end)
