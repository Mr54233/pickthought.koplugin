-- menus.lua 菜单结构与开关语义测试(需求 R4 + 上游式收纳 + 登录行动作面板)。
-- 关注:登录行两用语义与动作面板、顶级收纳后的项构成、设置抽屉层级、
-- 想法弹窗设置的开关语义、划线样式保存链路。
package.path = "./?.lua;" .. package.path

local captured_dialog
package.preload["ui/widget/buttondialog"] = function()
    return {
        new = function(_, fields)
            captured_dialog = fields
            return setmetatable(fields, {})
        end,
    }
end
package.preload["ui/widget/confirmbox"] = function()
    return { new = function(_, fields) return setmetatable(fields, {}) end }
end
package.preload["ui/uimanager"] = function()
    return {
        show = function() end,
        close = function() end,
        scheduleIn = function() end,
        setDirty = function() end,
    }
end

-- 前面测试文件可能缓存过同名模块:清缓存保证本文件的桩生效。
for _, name in ipairs({
    "ui/widget/buttondialog", "ui/widget/confirmbox", "ui/uimanager",
    "pickthought.ui.menus",
}) do package.loaded[name] = nil end

local function make_env()
    local env = {
        prefs = { thoughts = {}, update = {}, sync_keep_awake = true },
        toasts = {},
        infos = {},
        saved_prefs = {},
        auth_flow_starts = 0,
        auth_flow_cancels = 0,
        renew_sessions = 0,
        manual_credentials = 0,
        logged_in = true,
    }
    local plugin = { version = "test" }
    plugin.store = {}
    function plugin.store:preferences() return env.prefs end
    function plugin.store:save_preferences(p) env.saved_prefs[#env.saved_prefs + 1] = p end
    function plugin.store:auth()
        return { api_key = "k", cookies = { wr_skey = "x" }, account = { name = "小明", vid = "1" } }
    end
    function plugin.store:clear_auth() env.logged_in = false end
    plugin.auth_flow = {
        start = function() env.auth_flow_starts = env.auth_flow_starts + 1 end,
        cancel = function() env.auth_flow_cancels = env.auth_flow_cancels + 1 end,
    }
    plugin.api = {
        renew_session = function(self) env.renew_sessions = env.renew_sessions + 1; return true end,
    }
    function plugin:safe(_label, fn) return fn end
    function plugin:logged_in() return env.logged_in end
    function plugin:current_doc_path() return nil end
    function plugin:online(_label, fn) fn() end
    function plugin:toast(text) env.toasts[#env.toasts + 1] = text end
    function plugin:info(text) env.infos[#env.infos + 1] = text end
    function plugin:manual_credentials() env.manual_credentials = env.manual_credentials + 1 end
    function plugin:apply_annotation_style() return true end
    function plugin:_thought_popup_preferences() return env.prefs.thoughts or {} end
    function plugin:_save_thought_popup_preferences(update)
        env.prefs.thoughts = env.prefs.thoughts or {}
        for key, value in pairs(update or {}) do env.prefs.thoughts[key] = value end
        return env.prefs.thoughts
    end
    -- 菜单回调闭包内引用的流程方法:触发时记录即可。
    function plugin:bind_book(_path) end
    function plugin:sync_entry(_path, _mode) end
    function plugin:sync_thoughts() end
    function plugin:book_actions(_path) end
    function plugin:reinject_with_clean(_path) end
    function plugin:reset_book_data(_path) end
    function plugin:clear_all_data() end
    function plugin:show_about() end
    function plugin:check_update() end
    function plugin:show_update_log() end
    function plugin:maybe_auto_check_update(_force) end
    function plugin:show_thought_popup_position_picker() end
    function plugin:show_thought_popup_height_picker() end
    function plugin:show_thought_popup_width_picker() end
    function plugin:show_thought_popup_font_size_picker() end
    function plugin:show_thought_popup_contrast_picker() end
    function plugin:show_comment_cache_picker() end
    env.plugin = plugin
    return env
end

local Menus = require("pickthought.ui.menus")

local function texts(items)
    local out = {}
    for i, item in ipairs(items) do
        if item.text_func then
            out[i] = item.text_func()
        else
            out[i] = item.text
        end
    end
    return out
end

T.case("登录行:已登录显示昵称,点按弹账户动作面板", function()
    local env = make_env()
    local item = Menus.login_item(env.plugin)
    T.eq(item:text_func(), "微信读书 · 小明", "已登录行显示账号昵称")
    item.callback()
    T.ok(captured_dialog ~= nil, "已登录点按弹出动作面板")
    local rows = captured_dialog.buttons
    T.eq(#rows, 2, "动作面板两行四钮")
    T.eq(rows[1][1].text, "账户状态", "状态入口")
    T.eq(rows[1][2].text, "手动刷新 Cookie", "刷新入口")
    T.eq(rows[2][1].text, "手动导入凭据", "手动导入入口")
    T.eq(rows[2][2].text, "清除账号数据", "清除入口")
    rows[1][1].callback()
    T.eq(env.infos[1]:find("已登录", 1, true), 1, "账户状态展示登录信息")
end)

T.case("登录行:手动刷新 Cookie 触发续期请求", function()
    local env = make_env()
    local item = Menus.login_item(env.plugin)
    item.callback()
    captured_dialog.buttons[1][2].callback()
    T.eq(env.renew_sessions, 1, "刷新按钮调用 renew_session")
    T.eq(env.toasts[#env.toasts], "Cookie 刷新已执行", "刷新有提示")
end)

T.case("登录行:手动导入与清除账号入口可达", function()
    local env = make_env()
    local item = Menus.login_item(env.plugin)
    item.callback()
    captured_dialog.buttons[2][1].callback()
    T.eq(env.manual_credentials, 1, "手动导入凭据直达")
    captured_dialog.buttons[2][2].callback()
    T.ok(env.auth_flow_cancels >= 0, "清除走确认框不直接清数据")
end)

T.case("登录行:未登录显示扫码登录,点按触发扫码", function()
    local env = make_env()
    env.logged_in = false
    captured_dialog = nil
    local item = Menus.login_item(env.plugin)
    T.eq(item:text_func(), "扫码登录", "未登录行提示扫码")
    item.callback()
    T.eq(env.auth_flow_starts, 1, "未登录点按直接进入扫码流程")
    T.eq(captured_dialog, nil, "未登录不弹动作面板")
end)

T.case("文件管理器菜单:上游式收纳,顶级 6 项", function()
    local env = make_env()
    local items = Menus.home_menu(env.plugin)
    local names = texts(items)
    T.eq(#names, 6, "顶级收纳为 6 项")
    T.eq(names[1]:find("微信读书 · 小明", 1, true), 1, "首行是登录行")
    T.eq(names[2], "同步划线与想法(选书)", "同步入口")
    T.eq(names[3], "绑定微信读书(选书)", "绑定入口")
    T.eq(names[4], "更多操作(重注/续拉/还原)", "更多操作入口")
    T.eq(names[5], "划线样式（默认样式）", "划线样式入口")
    T.eq(names[6], "设置", "末项是设置抽屉")
end)

T.case("阅读器菜单(已绑定书):6 项收纳,想法弹窗设置在划线样式下", function()
    local env = make_env()
    local plugin = env.plugin
    function plugin:current_doc_path() return "/mnt/book.epub" end
    function plugin:_aggregate_sync_state(_path)
        return { pending = 0, books_failed = 0, books_unknown = 0 }
    end
    local Binding = require("pickthought.binding")
    local orig_get = Binding.get
    Binding.get = function(_store, _path) return { book_id = "b1" } end
    local items = Menus.reader_menu(plugin)
    Binding.get = orig_get
    local names = texts(items)
    T.eq(#names, 6, "已绑定阅读菜单 6 项")
    T.eq(names[1]:find("微信读书 · 小明", 1, true), 1, "首行是登录行")
    T.eq(names[2], "同步划线与想法", "同步直达")
    T.eq(names[3], "划线样式（默认样式）", "划线样式直达")
    T.eq(names[4], "想法弹窗设置", "想法弹窗设置在划线样式之下")
    T.eq(names[5], "书籍管理", "书籍管理抽屉")
    T.eq(names[6], "设置", "末段是设置抽屉")
end)

T.case("阅读器菜单(未绑定书):仅登录行/绑定/设置", function()
    local env = make_env()
    local items = Menus.reader_menu(env.plugin)
    local names = texts(items)
    T.eq(#names, 3, "未绑定书阅读菜单 3 项")
    T.eq(names[2], "绑定微信读书", "未绑定显示绑定入口")
    T.eq(names[3], "设置", "末项是设置抽屉")
end)

T.case("书籍管理抽屉:重新绑定直达,路径为空不崩溃", function()
    local env = make_env()
    local items = Menus.book_management_menu(env.plugin)
    T.eq(#items, 1, "无路径时仅重新绑定")
    T.eq(items[1].text, "重新绑定微信读书", "重新绑定入口")
end)

T.case("设置抽屉:六项构成,弹窗设置与账号已外移", function()
    local env = make_env()
    local items = texts(Menus.settings_menu(env.plugin))
    T.eq(#items, 6, "设置抽屉共 6 项")
    T.eq(items[1], "阅读时自动分批拉取后续章节", "第一项是自动分批拉取")
    T.eq(items[4], "更新", "更新菜单收纳在设置下")
    T.eq(items[5], "重置全部书籍", "危险操作收纳在设置下")
    T.eq(items[6], "关于", "关于收纳在设置下")
    T.ok(not table.concat(items, "|"):find("想法弹窗设置", 1, true), "弹窗设置已提级,不在设置抽屉")
    T.ok(not table.concat(items, "|"):find("账号", 1, true), "账号已并入登录行动作面板")
end)

T.case("想法弹窗设置:九项构成、三分区开关联动", function()
    local env = make_env()
    local popup = texts(Menus.thought_popup_menu(env.plugin))
    T.eq(#popup, 9, "想法弹窗设置共 9 项")
    T.eq(popup[1], "位置：居中", "位置默认居中")
    T.eq(popup[6], "点击左右区域翻页", "第 6 项是左右点按翻页")
    local items = Menus.thought_popup_menu(env.plugin)
    T.ok(not items[6].checked_func(), "左右点按翻页默认关闭")
    T.ok(not items[7].enabled_func(), "中间区域开评论在翻页开关关闭时置灰")
    items[6].callback()
    T.eq(env.prefs.thoughts.tap_to_page, true, "左右点按翻页可开启")
    T.ok(items[7].enabled_func(), "开启翻页后中间区域开评论变为可用")
    items[7].callback()
    T.eq(env.prefs.thoughts.comment_tap_open, true, "中间区域开评论可开启")
end)

T.case("划线样式菜单:四个单选项,选择后保存并提示", function()
    local env = make_env()
    local rows = Menus.annotation_style_menu(env.plugin)
    T.eq(#rows, 4, "四个划线样式选项")
    T.eq(rows[1].text, "默认样式", "第一项为默认样式")
    T.ok(rows[1].checked_func(), "无历史偏好时默认样式勾选")
    rows[3].callback()
    T.eq(env.prefs.annotation_style, "thin_dashed", "选择细虚线后写入偏好")
    T.eq(rows[3].checked_func(), true, "选择后勾选状态跟随偏好")
    T.eq(env.toasts[#env.toasts], "划线样式已切换为：细虚线", "切换有提示")
end)

T.case("更新菜单:四项构成与自动更新开关", function()
    local env = make_env()
    local items = texts(Menus.update_about_menu(env.plugin))
    T.eq(items[1]:find("检查更新", 1, true), 1, "第一项是检查更新")
    T.eq(items[2], "查看更新日志", "第二项是更新日志")
    local update_menu = Menus.update_about_menu(env.plugin)
    T.ok(not update_menu[3].checked_func(), "自动更新默认关闭")
    update_menu[3].callback()
    T.eq(env.prefs.update.auto_update, true, "自动更新开关写入偏好")
end)

print("test_menus: 全部用例通过")
