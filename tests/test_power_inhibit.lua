local PowerInhibit = require("pickthought.power_inhibit")

local function fixture(initial, options)
    options = options or {}
    local marker = options.marker
    local current = initial
    local pause = {pause_auto_suspend = options.pause == true}
    local pending = {}
    local operations = {}
    local now = options.now or 100
    local inhibit = PowerInhibit:new{
        pluginshare = pause,
        marker_path = "memory",
        token = options.token or "owner-a",
        now = function() return now end,
        read_marker = function() return marker end,
        write_marker = function(_, value)
            if options.write_fails then return false end
            marker = value
            return true
        end,
        remove_marker = function() marker = nil end,
        run_async = function(operation, callback)
            if options.runner_fails then return false, "runner failed" end
            operations[#operations + 1] = operation
            pending[#pending + 1] = {operation = operation, callback = callback}
            return true
        end,
    }
    local function complete(result)
        local item = table.remove(pending, 1)
        T.ok(item, "存在待完成 helper")
        result = result or {ok = true}
        if result.ok and (item.operation.kind == "set" or item.operation.kind == "restore") then
            current = item.operation.value
        end
        item.callback(result)
    end
    local function state()
        return current, pause, marker, pending, operations
    end
    local function set_now(value) now = value end
    return inhibit, state, complete, set_now
end

local function acquire(inhibit, complete, previous)
    T.ok(inhibit:acquire(), "接受异步获取")
    complete({ok = true, value = previous})
    complete({ok = true})
end

T.case("PowerInhibit 异步读取原值后设置 Kindle 系统锁", function()
    local inhibit, state, complete = fixture(0)
    T.ok(inhibit:acquire(), "获取立即返回")
    local current, pause, marker, pending = state()
    T.eq(current, 0, "UI 线程没有同步设置 LIPC")
    T.ok(pause.pause_auto_suspend, "立即暂停 KOReader AutoSuspend")
    T.eq(marker, nil, "读取原值前不写不完整 marker")
    T.eq(pending[1].operation.kind, "get", "先异步读取")

    complete({ok = true, value = 0})
    current, pause, marker, pending = state()
    T.eq(marker.system_previous, 0, "保存系统原值")
    T.eq(marker.token, "owner-a", "保存 owner token")
    T.eq(pending[1].operation.kind, "set", "marker 落盘后才设置系统锁")
    complete({ok = true})
    current = state()
    T.eq(current, 1, "preventScreenSaver=1")
end)

T.case("PowerInhibit get 超时不设置系统锁", function()
    local inhibit, state, complete = fixture(0)
    inhibit:acquire()
    complete({ok = false, error = "helper timeout", timeout = true})
    local current, _, marker, pending = state()
    T.eq(current, 0, "系统值不变")
    T.eq(marker.system_previous, nil, "未知原值不伪造")
    T.eq(#pending, 0, "不再排队 set")
    T.ok(inhibit:release(), "仍可释放插件锁")
    local _, pause, cleared = state()
    T.eq(pause.pause_auto_suspend, false, "恢复 AutoSuspend")
    T.eq(cleared, nil, "无系统修改时直接清 marker")
end)

T.case("PowerInhibit 读取原值期间释放会清理待执行保活", function()
    local inhibit, state, complete = fixture(0)
    inhibit:acquire()
    T.ok(inhibit:reset_timeout(true), "T1 已等待 get 完成")
    T.ok(inhibit:release(), "无 marker 时立即释放")
    local _, pause, marker, pending = state()
    T.eq(pause.pause_auto_suspend, false, "立即恢复 AutoSuspend")
    T.eq(marker, nil, "没有伪造 marker")
    T.eq(#pending, 1, "仅保留正在运行的 get")
    complete({ok = true, value = 0})
    local _, _, _, after = state()
    T.eq(#after, 0, "结束后不再执行 T1 或系统 set")
end)

T.case("PowerInhibit 结束时异步恢复原状态", function()
    local inhibit, state, complete = fixture(0)
    acquire(inhibit, complete, 0)
    T.ok(inhibit:release(), "接受异步恢复")
    local current, pause, marker, pending = state()
    T.eq(current, 1, "恢复完成前系统锁仍在")
    T.eq(pause.pause_auto_suspend, false, "AutoSuspend 立即恢复")
    T.ok(marker ~= nil, "恢复成功前保留 marker")
    T.eq(pending[1].operation.kind, "restore", "排队恢复")
    complete({ok = true})
    current, pause, marker = state()
    T.eq(current, 0, "恢复 preventScreenSaver")
    T.eq(marker, nil, "成功后清除 marker")
end)

T.case("PowerInhibit 恢复超时保留 marker", function()
    local inhibit, state, complete = fixture(0)
    acquire(inhibit, complete, 0)
    inhibit:release()
    complete({ok = false, error = "helper timeout", timeout = true})
    local current, _, marker = state()
    T.eq(current, 1, "失败时不声称已恢复")
    T.ok(marker ~= nil, "marker 留待重启清理")
end)

T.case("PowerInhibit 接管后旧 owner 不得释放新锁", function()
    local inhibit, state, complete = fixture(0)
    acquire(inhibit, complete, 0)
    local _, _, marker = state()
    marker.token = "owner-b"
    T.eq(inhibit:release(), false, "旧 owner 不恢复")
    local current, pause, kept, pending = state()
    T.eq(current, 1, "系统锁保持")
    T.ok(pause.pause_auto_suspend, "AutoSuspend 继续暂停")
    T.eq(kept.token, "owner-b", "新 owner 标记保留")
    T.eq(#pending, 0, "没有恢复操作")
end)

T.case("PowerInhibit 清理崩溃遗留锁", function()
    local inhibit, state, complete = fixture(1, {marker = {
        system_previous = 0, pause_previous = false, token = "dead-owner",
    }})
    T.ok(inhibit:clear_stale(), "接受异步清理")
    local _, pause, marker, pending = state()
    T.eq(pause.pause_auto_suspend, false, "恢复插件原值")
    T.ok(marker ~= nil, "恢复前保留标记")
    T.eq(pending[1].operation.kind, "restore", "排队恢复原值")
    complete({ok = true})
    local current, _, cleared = state()
    T.eq(current, 0, "恢复系统原值")
    T.eq(cleared, nil, "清除遗留标记")
end)

T.case("PowerInhibit 同类保活操作不重复排队", function()
    local inhibit, state, complete = fixture(0)
    acquire(inhibit, complete, 0)
    T.ok(inhibit:verify(true), "首次 verify 入队")
    T.eq(inhibit:verify(true), false, "重复 verify 被合并")
    T.ok(inhibit:reset_timeout(true), "首次 T1 入队")
    T.eq(inhibit:reset_timeout(true), false, "重复 T1 被合并")
    local _, _, _, pending, operations = state()
    T.eq(#pending, 1, "同一时刻只运行一个 helper")
    complete({ok = true})
    complete({ok = true})
    T.eq(operations[#operations - 1].kind, "set", "执行一次 verify")
    T.eq(operations[#operations].kind, "t1", "执行一次 T1")
end)

T.case("PowerInhibit 标记写入失败时不得设置系统锁", function()
    local inhibit, state, complete = fixture(0, {write_fails = true})
    inhibit:acquire()
    complete({ok = true, value = 0})
    local current, pause, marker, pending = state()
    T.eq(current, 0, "不得设置系统锁")
    T.eq(pause.pause_auto_suspend, false, "恢复 AutoSuspend 原值")
    T.eq(marker, nil, "不留下无效 marker")
    T.eq(#pending, 0, "不排队 set")
end)

T.case("PowerInhibit 默认 helper 超时后终止进程组", function()
    local now = 100
    local scheduled = {}
    local killed = false
    local done = false
    local result
    local ffi_util = {
        runInSubProcess = function() return 42 end,
        isSubProcessDone = function() return done end,
        terminateSubProcess = function(pid) T.eq(pid, 42, "终止 helper PID") killed = true end,
    }
    local inhibit = PowerInhibit:new{
        marker_path = "memory",
        token = "owner",
        now = function() return now end,
        ffi_util = ffi_util,
        schedule = function(_, callback) scheduled[#scheduled + 1] = callback end,
    }
    T.ok(inhibit:_enqueue({kind = "t1"}, function(value) result = value end), "helper 已启动")
    now = 104
    table.remove(scheduled, 1)()
    T.ok(killed, "3 秒后终止 helper")
    T.ok(result and result.timeout, "回调报告超时")
    T.ok(inhibit.worker ~= nil, "未退出 helper 在后台继续回收")
    T.eq(#scheduled, 1, "回收轮询不阻塞 UI")
    done = true
    table.remove(scheduled, 1)()
    T.eq(inhibit.worker, nil, "超时 helper 已回收")
end)
