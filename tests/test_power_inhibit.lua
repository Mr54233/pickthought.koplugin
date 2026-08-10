local PowerInhibit = require("pickthought.power_inhibit")

local function fixture(initial)
    local marker
    local current = initial
    local pause = {pause_auto_suspend = false}
    local writes = {}
    local handle = {
        get_int_property = function() return current end,
        set_int_property = function(_, _, _, value)
            current = value
            writes[#writes + 1] = value
        end,
    }
    local inhibit = PowerInhibit:new{
        device = {powerd = {lipc_handle = handle}},
        pluginshare = pause,
        marker_path = "memory",
        token = "owner-a",
        now = function() return 100 end,
        read_marker = function() return marker end,
        write_marker = function(_, value)
            marker = value
            return true
        end,
        remove_marker = function() marker = nil end,
    }
    return inhibit, function() return current, pause, marker, writes end
end

T.case("PowerInhibit 设置并回读 Kindle 系统锁", function()
    local inhibit, state = fixture(0)
    T.ok(inhibit:acquire(), "系统锁应验证成功")
    local current, pause, marker, writes = state()
    T.eq(current, 1, "preventScreenSaver=1")
    T.ok(pause.pause_auto_suspend, "KOReader AutoSuspend 同时暂停")
    T.eq(marker.system_previous, 0, "保存系统原值")
    T.eq(marker.token, "owner-a", "保存 owner token")
    T.eq(writes[1], 1, "执行系统设置")
end)

T.case("PowerInhibit 结束时恢复原状态", function()
    local inhibit, state = fixture(0)
    inhibit:acquire()
    T.ok(inhibit:release(), "恢复成功")
    local current, pause, marker = state()
    T.eq(current, 0, "恢复 preventScreenSaver")
    T.eq(pause.pause_auto_suspend, false, "恢复 AutoSuspend")
    T.eq(marker, nil, "清除标记")
end)

T.case("PowerInhibit 接管后旧 owner 不得释放新锁", function()
    local inhibit, state = fixture(0)
    inhibit:acquire()
    local _, _, marker = state()
    marker.token = "owner-b"
    T.eq(inhibit:release(), false, "旧 owner 不恢复")
    local current, pause, kept = state()
    T.eq(current, 1, "系统锁保持")
    T.ok(pause.pause_auto_suspend, "AutoSuspend 继续暂停")
    T.eq(kept.token, "owner-b", "新 owner 标记保留")
end)

T.case("PowerInhibit 清理崩溃遗留锁", function()
    local inhibit, state = fixture(0)
    inhibit:acquire()
    local _, _, marker = state()
    marker.token = "dead-owner"
    T.ok(inhibit:clear_stale(), "遗留锁恢复成功")
    local current, pause, cleared = state()
    T.eq(current, 0, "恢复系统原值")
    T.eq(pause.pause_auto_suspend, false, "恢复插件原值")
    T.eq(cleared, nil, "清除遗留标记")
end)

T.case("PowerInhibit 不支持 LIPC 时仍管理 AutoSuspend", function()
    local marker
    local pause = {pause_auto_suspend = false}
    local inhibit = PowerInhibit:new{
        device = {}, pluginshare = pause, marker_path = "memory", token = "owner",
        read_marker = function() return marker end,
        write_marker = function(_, value) marker = value return true end,
        remove_marker = function() marker = nil end,
    }
    T.eq(inhibit:acquire(), false, "系统锁不可用")
    T.ok(pause.pause_auto_suspend, "仍暂停 KOReader AutoSuspend")
    T.ok(inhibit:release(), "无系统原值也能恢复")
    T.eq(pause.pause_auto_suspend, false, "AutoSuspend 已恢复")
end)

T.case("PowerInhibit 标记写入失败时不得设置系统锁", function()
    local current = 0
    local pause = {pause_auto_suspend = false}
    local inhibit = PowerInhibit:new{
        device = {powerd = {lipc_handle = {
            get_int_property = function() return current end,
            set_int_property = function(_, _, _, value) current = value end,
        }}},
        pluginshare = pause, marker_path = "memory", token = "owner",
        read_marker = function() return nil end,
        write_marker = function() return false end,
    }
    T.eq(inhibit:acquire(), false, "获取失败")
    T.eq(current, 0, "不得留下无法恢复的系统锁")
    T.eq(pause.pause_auto_suspend, false, "恢复 AutoSuspend 原值")
end)
