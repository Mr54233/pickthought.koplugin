-- 居中/底部组件交互回归：局部重绘、左右点击、物理按键和视口切页。

local function class(proto)
    proto = proto or {}
    proto.__index = proto
    function proto:extend(fields)
        fields = fields or {}
        fields.__index = fields
        return setmetatable(fields, {__index = self})
    end
    function proto:new(fields)
        local value = setmetatable(fields or {}, self)
        if value.init then value:init() end
        return value
    end
    function proto:clear() self.cleared = true end
    return proto
end

local dirty = {}
package.preload["ui/bidi"] = function()
    return {
        flipIfMirroredUILayout = function(value) return value end,
        flipDirectionIfMirroredUILayout = function(value) return value end,
    }
end
package.preload["ui/widget/buttondialog"] = function() return class() end
package.preload["ffi/blitbuffer"] = function() return {COLOR_WHITE = 255} end
package.preload["ui/widget/buttontable"] = function() return class() end
package.preload["ui/widget/container/centercontainer"] = function() return class() end
package.preload["ui/widget/container/bottomcontainer"] = function() return class() end
package.preload["device"] = function()
    return {
        input = {group = {Back = "Back", PgBack = "PgBack", PgFwd = "PgFwd"}},
        screen = {
            scaleBySize = function(_, value) return value end,
            getWidth = function() return 600 end,
            getHeight = function() return 800 end,
            getSize = function() return {w = 600, h = 800} end,
        },
        isTouchDevice = function() return false end,
        hasKeys = function() return false end,
    }
end
package.preload["ui/widget/container/framecontainer"] = function() return class() end
package.preload["ui/font"] = function() return {getFace = function(_, name, size) return {name = name, size = size} end} end
package.preload["ui/geometry"] = function() return class() end
package.preload["ui/gesturerange"] = function() return class() end
package.preload["ui/widget/container/inputcontainer"] = function() return class() end
package.preload["pickthought.thought_popup.pages"] = function() return {} end
package.preload["pickthought.thought_popup.page_viewport"] = function() return class() end
package.preload["ui/size"] = function()
    return {padding = {large = 8, default = 4}, radius = {window = 6}, line = {thick = 2}}
end
package.preload["ui/widget/titlebar"] = function() return class() end
package.preload["ui/uimanager"] = function()
    return {
        setDirty = function(_, target, mode, region)
            dirty[#dirty + 1] = {target = target, mode = mode, region = region}
        end,
        close = function(_, widget) widget.closed = true end,
        show = function() end,
    }
end
package.preload["ui/widget/verticalgroup"] = function() return class() end
package.preload["ui/widget/verticalspan"] = function() return class() end
package.preload["ui/widget/container/widgetcontainer"] = function() return {free = function() end} end

for _, name in ipairs({
    "ui/bidi", "ui/widget/buttondialog", "ffi/blitbuffer", "ui/widget/buttontable",
    "ui/widget/container/centercontainer", "device", "ui/widget/container/framecontainer",
    "ui/font", "ui/geometry", "ui/gesturerange", "ui/widget/container/inputcontainer",
    "pickthought.thought_popup.pages", "pickthought.thought_popup.page_viewport", "ui/size",
    "ui/widget/titlebar", "ui/uimanager", "ui/widget/verticalgroup", "ui/widget/verticalspan",
    "ui/widget/container/widgetcontainer", "pickthought.thought_popup.center_widget",
}) do package.loaded[name] = nil end
package.preload["pickthought.thought_popup.center_widget"] = nil
package.preload["pickthought.thought_popup.pages"] = nil
package.preload["pickthought.thought_popup.page_viewport"] = nil

local CenterWidget = require("pickthought.thought_popup.center_widget")

T.case("居中想法弹窗翻页只局部刷新且默认不拦截左右点按", function()
    T.eq(CenterWidget.tap_to_page, false, "居中弹窗默认关闭左右点击翻页")
    local popup = setmetatable({
        page_index = 1,
        _page_starts = {0, 300},
        container = {dimen = {x = 10, y = 20, w = 400, h = 500}},
        _syncButtons = function() end,
    }, {__index = CenterWidget})
    local buttons = popup:_buildButtons()
    T.ok(buttons[1].vsync and buttons[3].vsync, "翻页按钮使用同步刷新")
    dirty = {}
    popup:changePage(1)
    T.eq(popup.page_index, 2, "下一页更新页码")
    T.eq(dirty[#dirty].target, popup, "局部刷新目标是弹窗自身")
    T.eq(dirty[#dirty].region, popup.container.dimen, "局部刷新范围是弹窗区域")

    popup.page_index = 1
    popup.tap_to_page = false
    local point = {x = 350, notIntersectWith = function() return false end}
    popup:onTapClose(nil, {pos = point})
    T.eq(popup.page_index, 1, "关闭左右点击翻页后内容不变化")
    popup.tap_to_page = true
    popup:onTapClose(nil, {pos = point})
    T.eq(popup.page_index, 2, "开启后右半区前进一页")
end)

-- 重新设置与底部滚动组件有关的 mock，避免居中组件模块残留依赖。
package.preload["device"] = function()
    return {
        input = {group = {PgBack = "hardware-back", PgFwd = "hardware-forward"}},
        screen = {getWidth = function() return 600 end, scaleBySize = function(_, value) return value end},
        hasKeys = function() return true end,
        isTouchDevice = function() return false end,
    }
end
package.preload["ui/geometry"] = function() return {new = function(_, value) return value end} end
package.preload["pickthought.thought_popup.paginator"] = function()
    return {computePages = function() return {0, 50, 100} end}
end
package.preload["util"] = function()
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
    return {bsearch_left = bsearch_left, bsearch_right = bsearch_right}
end
package.preload["ui/widget/verticalscrollbar"] = function()
    local ScrollBar = class()
    function ScrollBar:set(low, high) self.low, self.high = low, high end
    return ScrollBar
end
for _, name in ipairs({
    "device", "ui/geometry", "pickthought.thought_popup.paginator", "util",
    "ui/widget/verticalscrollbar", "pickthought.thought_popup.scroll_container",
}) do package.loaded[name] = nil end

local ScrollContainer = require("pickthought.thought_popup.scroll_container")

T.case("底部想法弹窗物理翻页键使用 Input.group 映射", function()
    local scroll = ScrollContainer:new{content_h = 150, viewport_h = 50}
    T.eq(scroll.key_events.ScrollUp[1][1], "hardware-back", "物理上一页键绑定前一页")
    T.eq(scroll.key_events.ScrollDown[1][1], "hardware-forward", "物理下一页键绑定后一页")
    T.eq(scroll.scroll_offset, 0, "初始位于顶部")
    scroll:onScrollDown()
    T.eq(scroll.scroll_offset, 50, "物理下一页按行边界移动")
    scroll:onScrollUp()
    T.eq(scroll.scroll_offset, 0, "物理上一页回到顶部")
end)

package.preload["ui/widget/widget"] = function() return class() end
package.loaded["ui/widget/widget"] = nil
package.loaded["pickthought.thought_popup.page_viewport"] = nil
package.preload["pickthought.thought_popup.page_viewport"] = nil
local PageViewport = require("pickthought.thought_popup.page_viewport")

T.case("居中页面视口每次绘制读取最新页码", function()
    local current = 1
    local requested = {}
    local page1 = {getHeight = function() return 200 end}
    local page2 = {getHeight = function() return 200 end}
    local viewport = PageViewport:new{
        dimen = {w = 100, h = 100}, margin_left = 5, text_w = 80,
        page_index_getter = function() return current end,
        page_bb_getter = function(index)
            requested[#requested + 1] = index
            return index == 1 and page1 or page2
        end,
    }
    local target = {blitFrom = function(self, source) self.source = source end}
    viewport:paintTo(target, 0, 0)
    T.eq(target.source, page1, "初始绘制第一页")
    current = 2
    viewport:paintTo(target, 0, 0)
    T.eq(requested[#requested], 2, "翻页后重新读取页码")
    T.eq(target.source, page2, "翻页后绘制新页面")
end)
