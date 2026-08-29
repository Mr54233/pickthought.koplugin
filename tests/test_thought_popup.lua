-- 想法弹窗公共入口、对象池与生命周期回归测试。
-- 直接对应上游 v1.3.0 的 entry/pool 合约，同时覆盖撷思保留的 items 参数。

local created_bottom, created_center = {}, {}
local reopen_log, closed_log, freed_log = {}, {}, {}

local function widget_mock(created)
    return {
        new = function(_, fields)
            local widget = {
                items = fields.items,
                position = fields.position,
                width_ratio = fields.width_ratio,
                contrast = fields.contrast,
                tap_to_page = fields.tap_to_page,
                clear = function() end,
                _freeContentCaches = function(self)
                    freed_log[#freed_log + 1] = self
                end,
                _reopen = function(self, opts)
                    reopen_log[#reopen_log + 1] = {
                        widget = self,
                        items = opts.items,
                        pages = opts.pages,
                        position = opts.position,
                    }
                    self.items = opts.items
                    self.width_ratio = opts.width_ratio
                    self.contrast = opts.contrast
                    self.tap_to_page = opts.tap_to_page
                end,
            }
            created[#created + 1] = widget
            return widget
        end,
    }
end

package.preload["pickthought.thought_popup.face_factory"] = function()
    return { init = function() end }
end
package.preload["pickthought.thought_popup.widget"] = function()
    return widget_mock(created_bottom)
end
package.preload["pickthought.thought_popup.center_widget"] = function()
    return widget_mock(created_center)
end
package.preload["ui/uimanager"] = function()
    return {
        visible = nil,
        show = function(self, widget) self.visible = widget end,
        close = function(self, widget)
            closed_log[#closed_log + 1] = widget
            if self.visible == widget then self.visible = nil end
        end,
        isWidgetShown = function(self, widget) return self.visible == widget end,
    }
end

for _, name in ipairs({
    "pickthought.thought_popup",
    "pickthought.thought_popup.face_factory",
    "pickthought.thought_popup.widget",
    "pickthought.thought_popup.center_widget",
    "ui/uimanager",
}) do
    package.loaded[name] = nil
end

-- test_sync_frontend 会在 package.loaders 中注册一个 KOReader 模块加载器。
-- 直接写入 package.loaded，确保本组测试一定使用这里的精确 mock。
package.loaded["pickthought.thought_popup.face_factory"] = {init = function() end}
package.loaded["pickthought.thought_popup.widget"] = widget_mock(created_bottom)
package.loaded["pickthought.thought_popup.center_widget"] = widget_mock(created_center)
local UIManager = {
    visible = nil,
    show = function(self, widget) self.visible = widget end,
    close = function(self, widget)
        closed_log[#closed_log + 1] = widget
        if self.visible == widget then self.visible = nil end
    end,
    isWidgetShown = function(self, widget) return self.visible == widget end,
}
package.loaded["ui/uimanager"] = UIManager
local Popup = require("pickthought.thought_popup")

local function clear(list)
    for i = #list, 1, -1 do table.remove(list, i) end
end

local function reset()
    Popup.cleanup()
    clear(created_bottom)
    clear(created_center)
    clear(reopen_log)
    clear(closed_log)
    clear(freed_log)
    UIManager.visible = nil
end

local items1 = {{abstract = "引文 A", author = "甲", content = "内容 A", likes_count = 1}}
local items2 = {{abstract = "引文 B", author = "乙", content = "内容 B", likes_count = 2}}

T.case("想法弹窗默认居中并兼容 items 参数", function()
    reset()
    local popup = Popup.show{items = items1, width_ratio = 0.8, contrast = 9}
    T.eq(#created_center, 1, "默认位置创建居中组件")
    T.eq(#created_bottom, 0, "默认位置不创建底部组件")
    T.eq(popup, created_center[1], "返回已显示的居中组件")
    T.eq(popup.items, items1, "items 原样传入组件")
    T.eq(UIManager.visible, popup, "组件已显示")
end)

T.case("想法弹窗同位置复用并支持 pages 参数", function()
    reset()
    local first = Popup.show{pages = items1}
    local second = Popup.show{pages = items2}
    T.eq(first, second, "同一位置复用同一组件")
    T.eq(#created_center, 1, "不会重复创建居中组件")
    T.eq(#reopen_log, 1, "复用时调用 reopen")
    T.eq(reopen_log[1].items, items2, "reopen 收到规范化 items")
    T.eq(reopen_log[1].pages, items2, "保留公开 pages 参数")
end)

T.case("切换位置释放另一侧位图缓存", function()
    reset()
    local center = Popup.show{items = items1}
    local bottom = Popup.show{items = items2, position = "bottom"}
    T.eq(#created_bottom, 1, "显式底部位置创建底部组件")
    T.eq(bottom, created_bottom[1], "返回底部组件")
    T.eq(freed_log[1], center, "切换位置释放居中内容缓存")
    T.eq(Popup.getPoolStats().pool_size, 1, "池中只保留当前显示位置")
end)

T.case("非法或空想法数据不会创建弹窗", function()
    reset()
    local ok = pcall(Popup.show, {items = {}})
    T.ok(not ok, "空 items 被拒绝")
    ok = pcall(Popup.show, {})
    T.ok(not ok, "缺少 items/pages 被拒绝")
    local popup = Popup.show{items = items1, position = "unexpected"}
    T.eq(popup, created_center[1], "非法位置回退居中")
end)

T.case("想法弹窗关闭别名和 cleanup 释放对象池", function()
    reset()
    local popup = Popup.show{items = items1}
    T.ok(Popup.isShowing() and Popup.is_showing(), "两个显示状态接口一致")
    Popup.close_visible()
    T.eq(closed_log[#closed_log], popup, "snake_case 关闭接口关闭当前组件")
    Popup.cleanup()
    local stats = Popup.getPoolStats()
    T.eq(stats.pool_size, 0, "cleanup 清空对象池")
    T.ok(not stats.has_active, "cleanup 后没有活动组件")
end)
