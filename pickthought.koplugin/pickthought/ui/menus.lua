--[[--
撷思菜单构造器(需求 R4,见 docs/requirement-remediation-2026-09-06.md:
从 main.lua 抽离,main.lua 只保留分发与业务流程)。

所有函数以 plugin 实例为首个参数,只调用 plugin 的公开方法与字段;
菜单项文案、顺序与开关语义与抽离前完全一致。main.lua 侧的对应
Plugin 方法变为一行委托。
--]]--

local ConfirmBox = require("ui/widget/confirmbox")
local UIManager = require("ui/uimanager")
local AnnotationStyle = require("pickthought.annotation_style")
local BatchSync = require("pickthought.batch_sync")
local Binding = require("pickthought.binding")
local PopupConfig = require("pickthought.thought_popup.popup_config")
local PopupDiagnostic = require("pickthought.diagnostic")
local ReviewComments = require("pickthought.review_comments")
local Text = require("pickthought.text")

local _ = Text.tr

local M = {}

-- 划线样式运行时文案(阅读器菜单/文件管理器菜单共用)。
M.ANNOTATION_STYLE_LABELS = {
    default = "默认样式",
    thin_solid = "细实线",
    thin_dashed = "细虚线",
    hidden = "隐藏划线",
}

local function popup_percent(value, fallback)
    return math.floor(((tonumber(value) or fallback) * 100) + .5)
end

M.popup_percent = popup_percent

local function annotation_style_label(plugin)
    local key = AnnotationStyle.normalize_runtime_style(
        plugin.store:preferences().annotation_style)
    return M.ANNOTATION_STYLE_LABELS[key] or M.ANNOTATION_STYLE_LABELS.default
end

M.annotation_style_label = annotation_style_label

local function comment_cache_label(value)
    local ttl = ReviewComments.normalize_ttl(value)
    if ttl == 0 then return "关闭" end
    if ttl < 3600 then return tostring(math.floor(ttl / 60)) .. " 分钟" end
    return "1 小时"
end

--- 同步进行中时置顶的状态入口(无任务时为 nil,不占菜单位)。
function M.sync_status_item(plugin)
    if not (plugin.sync_task and plugin.sync_task:busy()) then return nil end
    return {text = "同步进行中…(点按查看进度)", callback = plugin:safe("sync_status", function()
        plugin:_show_active_sync_dialog()
    end)}
end

function M.annotation_style_item(plugin)
    return {text = "划线样式（" .. annotation_style_label(plugin) .. "）",
        sub_item_table_func = function() return M.annotation_style_menu(plugin) end}
end

--- 文件管理器态菜单(无"当前书"上下文,选书类入口用文件选择器)。
function M.home_menu(plugin)
    local items = {}
    items[#items + 1] = M.sync_status_item(plugin)
    items[#items + 1] = {text = "选择书籍同步想法", callback = plugin:safe("fm_sync", function()
        plugin:pick_book("选择要同步的 EPUB(长按文件名选中)", function(path) plugin:sync_entry(path) end)
    end)}
    items[#items + 1] = {text = "选择书籍绑定微信读书", callback = plugin:safe("fm_bind", function()
        plugin:pick_book("选择要绑定的 EPUB(长按文件名选中)", function(path) plugin:bind_book(path) end)
    end)}
    items[#items + 1] = {text = "选择书籍更多操作(重注 / 续拉 / 还原)", callback = plugin:safe("fm_actions", function()
        plugin:pick_book("选择 EPUB(长按文件名选中)", function(path) plugin:book_actions(path) end)
    end)}
    items[#items + 1] = M.annotation_style_item(plugin)
    items[#items + 1] = {text = "账户", sub_item_table_func = function() return M.account_menu(plugin) end}
    items[#items + 1] = {text = "设置", sub_item_table_func = function() return M.settings_menu(plugin) end}
    items[#items + 1] = {text = "更新", sub_item_table_func = function() return M.update_about_menu(plugin) end}
    items[#items + 1] = {text = "重置全部书籍", callback = plugin:safe("clear_all", function() plugin:clear_all_data() end)}
    items[#items + 1] = {text = "关于", callback = plugin:safe("about", function() plugin:show_about() end)}
    return items
end

--- 阅读态菜单:围绕当前文档的绑定/同步/重置上下文项。
function M.reader_menu(plugin)
    local items = {}
    items[#items + 1] = M.sync_status_item(plugin)
    items[#items + 1] = {text = "绑定微信读书", callback = plugin:safe("bind", function() plugin:bind_book() end)}
    items[#items + 1] = {text = "同步划线与想法", callback = plugin:safe("sync_thoughts", function() plugin:sync_thoughts() end)}
    local doc_path = plugin:current_doc_path()
    local doc_bound = doc_path and Binding.get(plugin.store, doc_path)
    if doc_bound then
        items[#items + 1] = M.annotation_style_item(plugin)
        -- 多书聚合:任何一本有待同步章节都提供「继续拉取」,不只看第一本(P1#4);
        -- 失败书/剩余未知书同样保留入口,不让聚合 0 吞掉失败态(评审五轮 P1#2)。
        local agg = plugin:_aggregate_sync_state(doc_path)
        if agg.pending > 0 or agg.books_failed > 0 or agg.books_unknown > 0 then
            items[#items + 1] = {text = plugin:_continue_sync_label(agg),
                callback = plugin:safe("continue_sync", function() plugin:sync_entry(doc_path, "sync") end)}
        end
    end
    if doc_path and plugin:_has_reinject_cache(doc_path) then
        items[#items + 1] = {text = "重新注入(用上次数据,离线)", callback = plugin:safe("reinject", function() plugin:reinject_with_clean(doc_path) end)}
    end
    if doc_bound or (doc_path and require("pickthought.util").file_exists(doc_path .. ".orig")) then
        items[#items + 1] = {text = "重置本书(清数据+还原原版)", callback = plugin:safe("reset", function() plugin:reset_book_data(doc_path) end)}
    end
    items[#items + 1] = {text = "账户", sub_item_table_func = function() return M.account_menu(plugin) end}
    items[#items + 1] = {text = "设置", sub_item_table_func = function() return M.settings_menu(plugin) end}
    items[#items + 1] = {text = "更新", sub_item_table_func = function() return M.update_about_menu(plugin) end}
    items[#items + 1] = {text = "重置全部书籍", callback = plugin:safe("clear_all", function() plugin:clear_all_data() end)}
    items[#items + 1] = {text = "关于", callback = plugin:safe("about", function() plugin:show_about() end)}
    return items
end

function M.account_menu(plugin)
    local out = {
        {text = _("QR login"), callback = plugin:safe("login", function() plugin.auth_flow:start() end)},
        {text = _("Manual credentials"), callback = plugin:safe("manual", function() plugin:manual_credentials() end)},
        {text = _("Account status"), callback = function() local a = plugin.store:auth(); plugin:info((plugin:logged_in() and _("Logged in") or _("Not logged in")) .. "\n" .. tostring(a.account.name or "") .. "\nVID: " .. tostring(a.account.vid or "")) end},
    }
    if plugin:logged_in() then out[#out + 1] = {text = _("Clear account data"), callback = function() UIManager:show(ConfirmBox:new{text = "清除当前账户信息？\n\n将退出微信读书账户。", ok_callback = function() plugin.auth_flow:cancel(); plugin.store:clear_auth(); plugin:toast(_("Logout")) end}) end} end
    return out
end

function M.settings_menu(plugin)
    return {
        {text = "想法弹窗设置", sub_item_table_func = function() return M.thought_popup_menu(plugin) end},
        {text = "阅读时自动分批拉取后续章节", checked_func = function()
            return BatchSync.auto_enabled(plugin.store:preferences())
        end, callback = function()
            local p = plugin.store:preferences()
            p.auto_batch_sync_opt_in = not BatchSync.auto_enabled(p)
            plugin.store:save_preferences(p)
        end},
        {text = "同步时保持唤醒(防锁屏中断)", checked_func = function()
            return plugin.store:preferences().sync_keep_awake ~= false
        end, callback = function()
            local p = plugin.store:preferences()
            local enabled = not (p.sync_keep_awake ~= false)
            p.sync_keep_awake = enabled
            plugin.store:save_preferences(p)
            -- 对进行中的任务即时生效,不必等下次同步。
            if plugin.sync_task then plugin.sync_task:set_keep_awake(enabled) end
        end},
        {text = "调试模式(记录详细同步日志)", checked_func = function()
            return plugin.store:preferences().debug_mode == true
        end, callback = function()
            local p = plugin.store:preferences()
            p.debug_mode = not (p.debug_mode == true)
            plugin.store:save_preferences(p)
            PopupDiagnostic.set_enabled(p.debug_mode == true)
            plugin:toast(p.debug_mode and "调试模式已开启,下次同步生效"
                or "调试模式已关闭,下次同步生效")
        end},
    }
end

--- 划线样式运行时切换(单选)。文案与样式键对应 M.ANNOTATION_STYLE_LABELS。
function M.annotation_style_menu(plugin)
    local choices = {
        {"default", M.ANNOTATION_STYLE_LABELS.default},
        {"thin_solid", M.ANNOTATION_STYLE_LABELS.thin_solid},
        {"thin_dashed", M.ANNOTATION_STYLE_LABELS.thin_dashed},
        {"hidden", M.ANNOTATION_STYLE_LABELS.hidden},
    }
    local rows = {}
    for _, choice in ipairs(choices) do
        local key, label = choice[1], choice[2]
        rows[#rows + 1] = {text = label, radio = true, checked_func = function()
            return AnnotationStyle.normalize_runtime_style(
                plugin.store:preferences().annotation_style) == key
        end, callback = function()
            local p = plugin.store:preferences()
            p.annotation_style = key
            plugin.store:save_preferences(p)
            local ok, err = plugin:apply_annotation_style()
            if ok then
                plugin:toast("划线样式已切换为：" .. label)
            elseif plugin.ui and plugin.ui.document then
                plugin:info("划线样式已保存,但当前页面未刷新：\n" .. tostring(err or "未知错误"))
            else
                plugin:toast("划线样式已保存,下次打开书籍时生效")
            end
        end}
    end
    return rows
end

--- 想法弹窗设置(位置/高度/宽度/字号/对比度/三分区点按/评论缓存/提示开关)。
function M.thought_popup_menu(plugin)
    local thoughts = plugin:_thought_popup_preferences()
    local position = thoughts.position == "bottom" and "底部" or "居中"
    local contrast = tonumber(thoughts.contrast) or 9
    local contrast_label = contrast == 9 and "纯黑（默认）" or ((contrast > 0 and "+" or "") .. tostring(contrast))
    local font_label
    if thoughts.font_size ~= nil then
        font_label = "固定 " .. tostring(math.floor(tonumber(thoughts.font_size) or 0))
    else
        local relative = tonumber(thoughts.font_size_relative) or 0
        font_label = relative == 0 and "跟随正文" or ((relative > 0 and "+" or "") .. tostring(relative))
    end
    return {
        {text = "位置：" .. position, callback = plugin:safe("thought_popup_position", function() plugin:show_thought_popup_position_picker() end)},
        {text = "高度：" .. tostring(popup_percent(thoughts.height_ratio, PopupConfig.DEFAULTS.height_ratio)) .. "%", callback = plugin:safe("thought_popup_height", function() plugin:show_thought_popup_height_picker() end)},
        {text = "宽度：" .. tostring(popup_percent(thoughts.width_ratio, PopupConfig.DEFAULTS.width_ratio)) .. "%", enabled_func = function() return plugin:_thought_popup_preferences().position ~= "bottom" end, callback = plugin:safe("thought_popup_width", function() plugin:show_thought_popup_width_picker() end)},
        {text = "字号：" .. font_label, callback = plugin:safe("thought_popup_font", function() plugin:show_thought_popup_font_size_picker() end)},
        {text = "字体对比度：" .. contrast_label, callback = plugin:safe("thought_popup_contrast", function() plugin:show_thought_popup_contrast_picker() end)},
        {text = "点击左右区域翻页", checked_func = function() return plugin:_thought_popup_preferences().tap_to_page == true end, callback = plugin:safe("thought_popup_tap", function()
            local enabled = not (plugin:_thought_popup_preferences().tap_to_page == true)
            plugin:_save_thought_popup_preferences({tap_to_page = enabled})
            plugin:toast(enabled and "想法弹窗左右点击翻页已开启" or "想法弹窗左右点击翻页已关闭")
        end)},
        {text = "点击中间区域打开评论", enabled_func = function() return plugin:_thought_popup_preferences().tap_to_page == true end, checked_func = function() return plugin:_thought_popup_preferences().comment_tap_open == true end, callback = plugin:safe("thought_popup_center_tap", function()
            local enabled = not (plugin:_thought_popup_preferences().comment_tap_open == true)
            plugin:_save_thought_popup_preferences({comment_tap_open = enabled})
            plugin:toast(enabled and "点击中间区域打开评论已开启" or "点击中间区域打开评论已关闭")
        end)},
        {text = "评论缓存：" .. comment_cache_label(thoughts.comment_cache_seconds), callback = plugin:safe("thought_popup_comment_cache", function() plugin:show_comment_cache_picker() end)},
        {text = "评论数获取提示", checked_func = function() return plugin:_thought_popup_preferences().comment_fetch_notice ~= false end, callback = plugin:safe("thought_popup_fetch_notice", function()
            local enabled = not (plugin:_thought_popup_preferences().comment_fetch_notice ~= false)
            plugin:_save_thought_popup_preferences({comment_fetch_notice = enabled})
            plugin:toast(enabled and "评论数获取提示已开启" or "评论数获取提示已关闭")
        end)},
    }
end

function M.update_about_menu(plugin)
    local function update_preference(name)
        return (plugin.store:preferences().update or {})[name] == true
    end
    return {
        {text = "检查更新（当前版本 · " .. tostring(plugin.version) .. "）", callback = plugin:safe("update", function() plugin:check_update() end)},
        {text = "查看更新日志", callback = plugin:safe("update-log", function() plugin:show_update_log() end)},
        {text = "自动更新", checked_func = function() return update_preference("auto_update") end,
            callback = function()
                local p = plugin.store:preferences(); p.update = p.update or {}
                p.update.auto_update = not (p.update.auto_update == true)
                plugin.store:save_preferences(p)
                plugin:toast(p.update.auto_update and "自动更新已开启" or "自动更新已关闭")
                if p.update.auto_update == true or p.update.notify_update == true then
                    UIManager:scheduleIn(0.1, function() plugin:maybe_auto_check_update(true) end)
                end
            end},
        {text = "通知有可用更新", checked_func = function() return update_preference("notify_update") end,
            callback = function()
                local p = plugin.store:preferences(); p.update = p.update or {}
                p.update.notify_update = not (p.update.notify_update == true)
                plugin.store:save_preferences(p)
                plugin:toast(p.update.notify_update and "更新通知已开启" or "更新通知已关闭")
                if p.update.auto_update == true or p.update.notify_update == true then
                    UIManager:scheduleIn(0.1, function() plugin:maybe_auto_check_update(true) end)
                end
        end},
    }
end

return M
