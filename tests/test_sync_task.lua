package.preload["ffi/util"] = function()
    return {
        runInSubProcess = function() return 1 end,
        isSubProcessDone = function() return false end,
        terminateSubProcess = function() end,
    }
end

package.preload["ui/uimanager"] = function()
    return {
        preventStandby = function() end,
        allowStandby = function() end,
        scheduleIn = function() end,
    }
end

package.preload["device"] = function() return {} end

local SyncTask = require("pickthought.sync_task")

T.case("SyncTask 解析 MemAvailable 并兼容旧内核", function()
    T.eq(SyncTask._parse_memory_available_kb([[MemFree: 7000 kB
Buffers: 22000 kB
Cached: 69000 kB
MemAvailable: 98000 kB
]]), 98000, "优先使用 MemAvailable")
    T.eq(SyncTask._parse_memory_available_kb([[MemFree: 7000 kB
Buffers: 22000 kB
Cached: 69000 kB
]]), 98000, "旧内核回退可回收内存")
end)

T.case("SyncTask 识别常见的 fork 内存错误", function()
    for _, message in ipairs({
        "fork failed: Cannot allocate memory",
        "not enough memory",
        "out of memory",
        "ENOMEM",
    }) do
        T.ok(SyncTask._is_memory_error(message), "应识别: " .. message)
    end
    T.ok(not SyncTask._is_memory_error("permission denied"), "普通 fork 错误不误判")
end)

T.case("SyncTask 调试模式默认关闭且只接受显式开启", function()
    T.ok(not SyncTask._diagnostics_enabled(nil), "缺少设置时关闭")
    T.ok(not SyncTask._diagnostics_enabled({}), "默认设置关闭")
    T.ok(not SyncTask._diagnostics_enabled({debug_mode = false}), "显式关闭")
    T.ok(SyncTask._diagnostics_enabled({debug_mode = true}), "显式开启")
end)

T.case("SyncTask fork 前安全线仍为 128MB", function()
    T.eq(SyncTask.MIN_FORK_AVAILABLE_KB, 128 * 1024, "fork 门槛不随 worker 安全线降低")
end)

T.case("取消失败状态保留续传位置", function()
    local state = SyncTask._failure_state({total = 1398, pending = 1198, next_index = 201},
        "cancelled", "已取消", 1234567890)
    T.eq(state.status, "cancelled", "取消状态明确")
    T.eq(state.failed, true, "取消也标记为未完成")
    T.eq(state.total, 1398, "保留章节总数")
    T.eq(state.pending, 1198, "保留待处理数量")
    T.eq(state.next_index, 201, "保留续传位置")
    T.eq(state.error, "已取消", "保留取消原因")
    T.eq(state.updated_at, 1234567890, "使用传入时间")
end)

T.case("SyncTask 描述符保留同步入口来源", function()
    local task = SyncTask:new({temp_dir = "tests"})
    task.job = {
        pid = 123, progress_path = "p", result_path = "r", cancel_path = "c",
        source = "batch_confirm", task_token = "token", mode = "sync",
    }
    T.eq(task:descriptor().source, "batch_confirm", "描述符保留来源")
end)

T.case("SyncTask 接管时拒绝进度 token 不匹配", function()
    local path = "tests/.sync-token-test.json"
    local handle = assert(io.open(path, "wb"))
    handle:write(require("pickthought.json").encode({task_token = "other", updated_at = 1}))
    handle:close()
    local task = SyncTask:new({temp_dir = "tests"})
    task.job = {
        task_token = "expected", progress_path = path, last_progress_raw = nil,
        last_progress_state = nil, last_progress_at = nil, waiting_notified = false,
    }
    T.ok(not task:_read_progress(task.job), "token 不一致的进度不接管")
    T.ok(task.job.token_mismatch, "记录 token 不一致")
    os.remove(path)
end)

T.case("SyncTask 结果文件先出现时等待子进程回收", function()
    local FFIUtil = require("ffi/util")
    local old_done = FFIUtil.isSubProcessDone
    local path = "tests/.sync-early-result.json"
    local file = assert(io.open(path, "wb"))
    file:write(require("pickthought.json").encode({ok = true}))
    file:close()
    local done = false
    FFIUtil.isSubProcessDone = function() return done end
    local completed = 0
    local task = SyncTask:new({temp_dir = "tests"})
    task._owns_job = function() return true end
    task._read_progress = function() return false end
    task._schedule = function() end
    task.job = {
        pid = 999999, progress_path = "tests/.sync-no-progress", result_path = path,
        cancel_path = "tests/.sync-no-cancel", last_poll_at = os.time(),
        last_progress_at = os.time(), started_at = os.time(),
        on_done = function() completed = completed + 1 end,
    }
    task:_poll()
    T.eq(completed, 0, "结果文件先到时不得提前收尾")
    T.ok(task.job ~= nil, "子进程未回收时任务仍在")
    done = true
    task:_poll()
    T.eq(completed, 1, "子进程回收后才收尾")
    T.eq(task.job, nil, "任务正常清理")
    FFIUtil.isSubProcessDone = old_done
    os.remove(path)
end)

T.case("SyncTask 解码子进程退出码与终止信号", function()
    local normal = SyncTask._decode_wait_status(0)
    T.eq(normal.exit_code, 0, "正常退出码")
    T.eq(normal.signal, nil, "正常退出没有信号")

    local failed = SyncTask._decode_wait_status(256)
    T.eq(failed.exit_code, 1, "非零退出码")

    local killed = SyncTask._decode_wait_status(9)
    T.eq(killed.signal, 9, "SIGKILL 编号")
    T.eq(killed.signal_name, "SIGKILL", "SIGKILL 名称")
    T.eq(killed.core_dumped, false, "SIGKILL 无 core 标志")

    local segfault = SyncTask._decode_wait_status(139)
    T.eq(segfault.signal, 11, "SIGSEGV 编号")
    T.eq(segfault.signal_name, "SIGSEGV", "SIGSEGV 名称")
    T.eq(segfault.core_dumped, true, "识别 core 标志")
end)

T.case("SyncTask 保活周期为五分钟", function()
    local task = SyncTask:new({temp_dir = "tests"})
    local verify_count, t1_count = 0, 0
    task.power_inhibit = {
        verify = function() verify_count = verify_count + 1 return true end,
        reset_timeout = function() t1_count = t1_count + 1 return true end,
    }
    task.job = {last_keepalive = 100}
    T.eq(task:_maintain_awake(399, false), false, "五分钟内不重复保活")
    T.ok(task:_maintain_awake(400, false), "五分钟到期后保活")
    T.eq(verify_count, 1, "系统锁只验证一次")
    T.eq(t1_count, 1, "T1 只重置一次")
    T.eq(SyncTask.KEEPALIVE_INTERVAL_SECONDS, 300, "周期常量")
end)

T.case("SyncTask 轮询延迟与周期到期同轮只保活一次", function()
    local task = SyncTask:new({temp_dir = "tests"})
    local verify_count, t1_count, schedule_count = 0, 0, 0
    task.power_inhibit = {
        verify = function() verify_count = verify_count + 1 return true end,
        reset_timeout = function() t1_count = t1_count + 1 return true end,
    }
    task._owns_job = function() return true end
    task._read_progress = function() return false end
    task._schedule = function() schedule_count = schedule_count + 1 end
    task.job = {
        pid = 999999,
        progress_path = "tests/.missing-progress",
        result_path = "tests/.missing-result",
        cancel_path = "tests/.missing-cancel",
        last_poll_at = os.time() - 31,
        last_keepalive = 0,
        last_progress_at = os.time(),
        started_at = os.time(),
    }
    task:_poll()
    T.eq(verify_count, 1, "延迟恢复不重复验证系统锁")
    T.eq(t1_count, 1, "延迟恢复不重复重置 T1")
    T.eq(schedule_count, 1, "父进程轮询继续调度")
end)

T.case("SyncTask fork 前内存不足时恢复低内存设置", function()
    local task = SyncTask:new({temp_dir = "tests"})
    local events = {}
    task._memory_available_kb = function() return 100 * 1024 end
    task._enable_memory_mode = function()
        events[#events + 1] = "enable"
        return true
    end
    task._release_memory_mode = function()
        events[#events + 1] = "release"
    end

    local ok, err = task:_prepare_worker_memory()
    T.eq(ok, nil, "低于 fork 余量时不启动子进程")
    T.ok(tostring(err):find("100 MB", 1, true), "提示实际可用内存")
    T.eq(table.concat(events, ","), "enable,release", "失败后恢复低内存设置")
end)

T.case("SyncTask fork 失败时也恢复低内存设置", function()
    local FFIUtil = require("ffi/util")
    local original = FFIUtil.runInSubProcess
    local events = {}
    FFIUtil.runInSubProcess = function()
        events[#events + 1] = "fork"
        return nil, "fork failed: Cannot allocate memory"
    end

    local settings_path = "tests/.tmp_sync_task_settings.lua"
    local handle = assert(io.open(settings_path, "wb"))
    handle:write("return {}\n")
    handle:close()
    local task = SyncTask:new({
        temp_dir = "tests", settings_path = settings_path, data_dir = "tests",
        flush = function() end,
        preferences = function() return {sync_keep_awake = true, sync_batch_limit = 200} end,
    })
    task._prepare_worker_memory = function()
        events[#events + 1] = "prepare"
        return true
    end
    task._release_memory_mode = function()
        events[#events + 1] = "release"
    end

    local ok, err = task:start({doc_path = "book.epub", book_id = "b1"})
    T.eq(ok, false, "fork 失败不创建任务")
    T.ok(tostring(err):find("Cannot allocate memory", 1, true), "保留底层错误供上层分类")
    T.eq(table.concat(events, ","), "prepare,fork,release", "预处理先于 fork 且失败后恢复")
    T.ok(task:_fork_memory_cooldown_remaining() > 0, "内存 fork 失败进入冷却")

    local blocked, blocked_error = task:start({doc_path = "book.epub", book_id = "b1"})
    T.eq(blocked, false, "自动重试在冷却期内阻止")
    T.ok(tostring(blocked_error):find("暂停自动同步", 1, true), "冷却提示明确")
    T.eq(table.concat(events, ","), "prepare,fork,release", "冷却期不再次 fork")

    local manual, manual_error = task:start({
        doc_path = "book.epub", book_id = "b1", allow_memory_retry = true,
    })
    T.eq(manual, false, "手动重试仍返回底层错误")
    T.ok(tostring(manual_error):find("Cannot allocate memory", 1, true), "手动重试重新尝试 fork")
    T.eq(table.concat(events, ","), "prepare,fork,release,prepare,fork,release",
        "手动重试清除冷却并重新测量")
    FFIUtil.runInSubProcess = original
    os.remove(settings_path)
end)

-- 评审七轮(2026-08-21):限速冷却判定——retry_after 未过期的书本轮暂缓网络请求;
-- 已过期/缺失的 retry_after 不冷却(下一轮正常拉取),与「按书隔离」语义一致。
T.case("SyncTask 冷却判定:retry_after 未过期冷却,已过期/缺失不冷却", function()
    local now = 1700000000
    local states = {
        a1 = { retry_after = now + 600 },   -- 未过期 → 冷却
        a2 = { retry_after = now - 10 },    -- 已过期 → 不冷却
        a3 = {},                            -- 无 retry_after → 不冷却
    }
    local cooldown = SyncTask._cooling_books(states, { "a1", "a2", "a3" }, now)
    T.eq(cooldown["a1"], true, "未过期 retry_after → 冷却")
    T.eq(cooldown["a2"], nil, "已过期 retry_after → 不冷却")
    T.eq(cooldown["a3"], nil, "无 retry_after → 不冷却")
    local empty = SyncTask._cooling_books({}, { "x" }, now)
    T.eq(empty["x"], nil, "无上次状态 → 不冷却")
end)
