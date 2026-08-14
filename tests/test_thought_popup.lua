-- 想法弹窗切换时只刷新正文区域的回归测试。

package.preload["device"] = function()
    return {
        screen = {
            getWidth = function() return 600 end,
            getHeight = function() return 800 end,
            scaleBySize = function(_, value) return value end,
        },
        hasKeys = function() return false end,
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

local UIManager = require("ui/uimanager")
local Popup = require("pickthought.thought_popup")

T.case("想法弹窗切换不重绘顶部摘录", function()
    local popup = Popup.show{items = {
        {abstract = "原文摘录", author = "甲", content = "第一条"},
        {author = "乙", content = "第二条"},
    }}

    T.eq(popup.titlebar.set_title_calls, 1, "顶部摘录只在初始化时设置")
    UIManager.dirty = {}
    popup:change_page(1)
    T.eq(popup.titlebar.set_title_calls, 1, "切换想法不重新设置顶部摘录")

    local dirty = UIManager.dirty[#UIManager.dirty]
    T.eq(dirty.widget, popup, "正文刷新仍标记弹窗")
    T.eq(dirty.region, popup.textw.dimen, "正文刷新区域使用 textw")
    T.ok(dirty.region ~= popup.frame.dimen, "正文刷新不使用整个弹窗区域")
    Popup.close_visible()
end)
