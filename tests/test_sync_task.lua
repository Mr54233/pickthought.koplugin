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
    FFIUtil.runInSubProcess = original
    os.remove(settings_path)
    T.eq(ok, false, "fork 失败不创建任务")
    T.ok(tostring(err):find("Cannot allocate memory", 1, true), "保留底层错误供上层分类")
    T.eq(table.concat(events, ","), "prepare,fork,release", "预处理先于 fork 且失败后恢复")
end)
