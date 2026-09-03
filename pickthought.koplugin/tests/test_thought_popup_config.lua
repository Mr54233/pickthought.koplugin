-- 想法弹窗配置与偏好迁移测试。

package.preload["device"] = function()
    return {
        screen = {scaleBySize = function(_, value) return value * 2 end},
    }
end
package.loaded["device"] = nil
package.loaded["pickthought.thought_popup.popup_config"] = nil
local PopupConfig = require("pickthought.thought_popup.popup_config")

T.case("想法弹窗配置统一传递正文布局与新版默认值", function()
    local preferences = {
        thoughts = {
            position = "bottom", height_ratio = .70, width_ratio = .80,
            font_size_relative = 2, contrast = 9, tap_to_page = true,
        },
    }
    local plugin = {
        store = {preferences = function() return preferences end},
        ui = {
            document = {
                configurable = {font_size = 20},
                getPageMargins = function() return {left = 11, right = 12, top = 13, bottom = 14} end,
            },
        },
        _thought_font_name = function() return "正文测试字体" end,
        _thought_font_pt = function() return 22 end,
    }
    local pages = {{author = "甲", content = "内容"}}
    local options = PopupConfig.build(plugin, pages, {close_callback = function() end})
    T.eq(options.pages, pages, "统一入口保留 pages")
    T.eq(options.position, "bottom", "读取底部位置")
    T.eq(options.height_ratio, .70, "读取高度")
    T.eq(options.width_ratio, .80, "读取宽度")
    T.eq(options.contrast, 9, "默认最高对比度")
    T.ok(options.tap_to_page, "读取左右点击翻页开关")
    T.eq(options.doc_font_name, "正文测试字体", "读取正文字体")
    T.eq(options.doc_font_size, 46, "相对字号基于缩放后的正文大小")
    T.eq(options.doc_margins.left, 11, "读取正文页边距")

    preferences.thoughts.font_size = 18
    local absolute = PopupConfig.build(plugin, pages)
    T.eq(absolute.doc_font_size, 36, "固定字号优先于相对字号")
end)

T.case("想法弹窗配置对非法偏好做安全回退", function()
    local plugin = {
        store = {preferences = function() return {thoughts = {
            position = "bad", height_ratio = 99, width_ratio = 0,
            font_size_relative = 99, contrast = -99, tap_to_page = "yes",
        }} end},
        ui = {},
    }
    local settings = PopupConfig.settings(plugin)
    T.eq(settings.position, "center", "非法位置回退居中")
    T.eq(settings.height_ratio, .90, "高度限制到最大值")
    T.eq(settings.width_ratio, .60, "宽度限制到最小值")
    T.eq(settings.font_size_relative, 5, "相对字号限制到最大值")
    T.eq(settings.contrast, -3, "对比度限制到最小值")
    T.ok(not settings.tap_to_page, "仅 true 开启左右点击翻页")
end)

-- Store 使用历史 settings 文件的实际形态进行归一化。该模块不依赖真实磁盘，
-- 以独立 LuaSettings fake 验证即使 Config.SCHEMA 未连续更新也会执行迁移。
local backing = {}
local settings_store = {
    readSetting = function(_, key, default)
        local value = backing[key]
        return value == nil and default or value
    end,
    saveSetting = function(_, key, value) backing[key] = value end,
    flush = function() end,
}
package.preload["datastorage"] = function()
    return {getFullDataDir = function() return "/data" end, getSettingsDir = function() return "/settings" end}
end
package.preload["luasettings"] = function()
    return {open = function() return settings_store end}
end
package.preload["libs/libkoreader-lfs"] = function()
    return {attributes = function(_, field) return field and "directory" or {mode = "directory"} end, mkdir = function() return true end}
end
package.preload["pickthought.config"] = function()
    return {
        SCHEMA = 1, DATA_DIR = "pickthought", UPDATE_MANIFEST = "test",
        THOUGHT_POPUP_DEFAULTS = {width_ratio = .90, height_ratio = .80},
        THOUGHT_POPUP_LIMITS = {
            min_width_ratio = .60, max_width_ratio = 1.00,
            min_height_ratio = .50, max_height_ratio = .90, ratio_step = 5,
        },
    }
end
package.preload["pickthought.batch_sync"] = function() return {DEFAULT_AUTO = false} end
package.preload["pickthought.json"] = function() return {} end
-- 前面的前台同步集成测试会为 Store 安装专用假实现；本用例必须加载真实
-- Store，才能验证其启动期归一化逻辑。
package.preload["pickthought.store"] = nil
package.preload["pickthought.util"] = nil
for _, name in ipairs({
    "datastorage", "luasettings", "libs/libkoreader-lfs", "pickthought.config",
    "pickthought.batch_sync", "pickthought.json", "pickthought.util", "pickthought.store",
}) do package.loaded[name] = nil end
local Store = require("pickthought.store")

T.case("旧想法字体偏好迁移到新版相对字号且保留尺寸", function()
    backing = {
        schema = 1,
        preferences = {thoughts = {font = "standard", width_ratio = .91, height_ratio = .60}},
    }
    local store = Store:new{data_dir = "/data/test", settings_path = "/settings/test.lua"}
    local thoughts = store:preferences().thoughts
    T.eq(thoughts.font_size_relative, -3, "旧较小字体映射为相对字号 -3")
    T.eq(thoughts.width_ratio, .91, "用户已有宽度保留")
    T.eq(thoughts.height_ratio, .60, "用户已有高度保留")
    T.eq(thoughts.position, "center", "补齐默认位置")
    T.eq(thoughts.contrast, 9, "补齐默认纯黑对比度")
    T.ok(not thoughts.tap_to_page, "补齐默认关闭的点击翻页")
end)

T.case("新安装偏好直接使用上游最终默认值并可持久化", function()
    backing = {schema = 1}
    local store = Store:new{data_dir = "/data/fresh", settings_path = "/settings/fresh.lua"}
    local thoughts = store:preferences().thoughts
    T.eq(thoughts.height_ratio, .80, "默认高度 80%")
    T.eq(thoughts.width_ratio, .90, "默认宽度 90%")
    T.eq(thoughts.font_size_relative, 0, "默认字号跟随正文")
    T.eq(thoughts.contrast, 9, "默认字体纯黑")
    thoughts.position = "bottom"
    thoughts.tap_to_page = true
    store:save_preferences({thoughts = thoughts})
    local restored = store:preferences().thoughts
    T.eq(restored.position, "bottom", "位置保存后可恢复")
    T.ok(restored.tap_to_page, "点击翻页设置保存后可恢复")
end)
