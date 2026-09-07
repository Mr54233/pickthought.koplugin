-- menus.lua 菜单结构与开关语义测试(需求 R4:菜单构造器抽离的回归防护)。
-- 关注三点:两菜单项构成与尾项顺序、想法弹窗设置的开关语义、
-- 划线样式单选的保存链路。
package.path = "./?.lua;" .. package.path

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

local prefs = { thoughts = {}, update = {}, sync_keep_awake = true }
local toasts, saved_prefs = {}, {}

local plugin = { version = "test" }
plugin.store = {}

function plugin.store:preferences() return prefs end
function plugin.store:save_preferences(p) saved_prefs[#saved_prefs + 1] = p end
function plugin.store:auth()
    return { api_key = "k", cookies = { wr_skey = "x" }, account = { name = "n", vid = "1" } }
end
function plugin.store:clear_auth() end
function plugin:safe(_label, fn) return fn end
function plugin:logged_in() return true end
function plugin:current_doc_path() return nil end  -- 未绑定书路径:阅读菜单走基础分支
function plugin:toast(text) toasts[#toasts + 1] = text end
function plugin:info(_text) end
function plugin:apply_annotation_style() return true end
function plugin:_thought_popup_preferences() return prefs.thoughts or {} end
function plugin:_save_thought_popup_preferences(update)
    prefs.thoughts = prefs.thoughts or {}
    for key, value in pairs(update or {}) do prefs.thoughts[key] = value end
    return prefs.thoughts
end
-- 以下流程方法在菜单回调闭包内被引用,触发时记录即可。
function plugin:pick_book(_title, _on_pick) end
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
function plugin:_show_active_sync_dialog() end

local Menus = require("pickthought.ui.menus")

local function texts(items)
    local out = {}
    for i, item in ipairs(items) do out[i] = item.text end
    return out
end

local function separator_count(items)
    local count = 0
    for _, item in ipairs(items) do
        if item.separator then count = count + 1 end
    end
    return count
end

T.case("文件管理器菜单:三段式,项构成与尾项顺序", function()
    local items = Menus.home_menu(plugin)
    T.eq(separator_count(items), 2, "选书操作/通用/危险区之间各一条分隔线")
    local names = texts(items)
    T.eq(names[1], "同步划线与想法(选书)", "选书操作段第一项")
    T.eq(names[2], "绑定微信读书(选书)", "选书操作段第二项")
    T.eq(names[3], "更多操作(重注/续拉/还原)", "选书操作段第三项")
    T.eq(names[#names - 1], "重置全部书籍", "危险项固定在倒数第二位")
    T.eq(names[#names], "关于", "关于固定在最后一位")
    T.eq(#items, 11, "文件管理器菜单共 11 个条目(含 2 条分隔线)")
    T.eq(#names - separator_count(items), 9, "有效菜单项 9 项(无进行中同步状态项)")
end)

T.case("阅读器菜单(未绑定书):无划线样式项,想法弹窗设置提级,尾项顺序一致", function()
    local items = Menus.reader_menu(plugin)
    T.eq(separator_count(items), 3, "当前书/界面/全局/危险区之间共三条分隔线")
    local names = texts(items)
    T.eq(names[1], "绑定微信读书", "阅读态首项是绑定入口(未绑定不带重新前缀)")
    T.eq(names[2], "同步划线与想法", "阅读态第二项是同步入口")
    T.ok(table.concat(names, "|"):find("想法弹窗设置", 1, true), "想法弹窗设置提级到阅读态")
    for _, text in ipairs(names) do
        T.ok(not text:find("划线样式", 1, true), "未绑定书不显示划线样式入口")
    end
    T.eq(names[#names - 1], "重置全部书籍", "危险项固定在倒数第二位")
    T.eq(names[#names], "关于", "关于固定在最后一位")
end)

T.case("划线样式菜单:四个单选项,选择后保存并提示", function()
    local rows = Menus.annotation_style_menu(plugin)
    T.eq(#rows, 4, "四个划线样式选项")
    T.eq(rows[1].text, "默认样式", "第一项为默认样式")
    T.ok(rows[1].checked_func(), "无历史偏好时默认样式勾选")
    rows[3].callback()
    T.eq(prefs.annotation_style, "thin_dashed", "选择细虚线后写入偏好")
    T.eq(rows[3].checked_func(), true, "选择后勾选状态跟随偏好")
    T.eq(toasts[#toasts], "划线样式已切换为：细虚线", "切换有提示")
end)

T.case("设置菜单:三项构成与调试模式开关", function()
    local items = texts(Menus.settings_menu(plugin))
    T.eq(items[1], "阅读时自动分批拉取后续章节", "第一项是自动分批拉取")
    T.eq(items[3], "调试模式(记录详细同步日志)", "末项是调试模式")
    local debug_item = Menus.settings_menu(plugin)[3]
    T.ok(not debug_item.checked_func(), "调试模式默认关闭")
    debug_item.callback()
    T.eq(prefs.debug_mode, true, "调试模式开关写入偏好")
end)

T.case("想法弹窗设置:九项构成、三分区开关联动与默认值", function()
    local popup = Menus.thought_popup_menu(plugin)
    T.eq(#popup, 9, "想法弹窗设置共 9 项")
    T.eq(popup[1].text, "位置：居中", "位置默认居中")
    T.eq(popup[5].text, "字体对比度：纯黑（默认）", "对比度默认纯黑")
    T.eq(popup[6].text, "点击左右区域翻页", "第 6 项是左右点按翻页")
    T.ok(not popup[6].checked_func(), "左右点按翻页默认关闭")
    T.ok(not popup[7].enabled_func(), "中间区域开评论在翻页开关关闭时置灰")
    T.eq(popup[8].text:find("评论缓存：", 1, true), 1, "评论缓存入口存在")
    T.ok(popup[9].checked_func(), "评论数获取提示默认开启")

    popup[6].callback()
    T.eq(prefs.thoughts.tap_to_page, true, "左右点按翻页可开启")
    T.ok(popup[7].enabled_func(), "开启翻页后中间区域开评论变为可用")
    popup[7].callback()
    T.eq(prefs.thoughts.comment_tap_open, true, "中间区域开评论可开启")
end)

T.case("更新菜单:四项构成与自动更新开关", function()
    local items = texts(Menus.update_about_menu(plugin))
    T.eq(items[1]:find("检查更新", 1, true), 1, "第一项是检查更新")
    T.eq(items[2], "查看更新日志", "第二项是更新日志")
    local update_menu = Menus.update_about_menu(plugin)
    T.ok(not update_menu[3].checked_func(), "自动更新默认关闭")
    update_menu[3].callback()
    T.eq(prefs.update.auto_update, true, "自动更新开关写入偏好")
end)

T.case("账户菜单:已登录时包含清除账户入口", function()
    local items = texts(Menus.account_menu(plugin))
    T.eq(#items, 4, "已登录账户菜单共 4 项")
    T.eq(items[1], "QR login", "扫码登录入口(测试环境不做翻译)")
    T.eq(items[4], "Clear account data", "已登录时出现清除账号入口")
end)

print("test_menus: 全部用例通过")
