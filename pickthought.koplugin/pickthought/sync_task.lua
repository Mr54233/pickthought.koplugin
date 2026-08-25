-- 后台同步任务:改自原撷思 download_task.lua(久经实测的子进程控制器)。
-- 子进程用隔离 Store 跑完整同步(拉取→缓存→映射→注入),经进度/结果/取消三个
-- 文件与父进程通信;父进程轮询、防待机(preventStandby + Kindle T1 重置)、
-- 判活(/proc 权威,waitpid 兜底)、支持 KOReader 重启后 attach 重新接管。
-- 断点续传:每章拉取结果落盘 book_dir/sync-cache/,成功完成才清空;
-- 中断/取消后再次同步自动跳过已拉取章节。
local FFIUtil = require("ffi/util")
local Json = require("pickthought.json")
local U = require("pickthought.util")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")
local PowerInhibit = require("pickthought.power_inhibit")

local SyncTask = {}
SyncTask.__index = SyncTask

-- Kindle 512 MB 机型在可用内存约 100 MB 时，fork reader.lua 子进程会被内核
-- 拒绝。这里留出保守余量，避免把底层 ENOMEM 直接抛给用户。
local MIN_FORK_AVAILABLE_KB = 128 * 1024
local FORK_MEMORY_COOLDOWN_SECONDS = 60
local KEEPALIVE_INTERVAL_SECONDS = 300

local function is_memory_error(value)
    local text = tostring(value or ""):lower()
    return text:find("cannot allocate memory", 1, true) ~= nil
        or text:find("not enough memory", 1, true) ~= nil
        or text:find("out of memory", 1, true) ~= nil
        or text:find("enomem", 1, true) ~= nil
end

local function lower_worker_priority()
    local ok,ffi=pcall(require,"ffi")
    if not ok or not ffi then return end
    pcall(ffi.cdef,"int setpriority(int which, int who, int prio);")
    pcall(function() ffi.C.setpriority(0,0,10) end)
end

local function serializable_copy(value, seen)
    local kind = type(value)
    if kind == "string" or kind == "number" or kind == "boolean" or kind == "nil" then return value end
    if kind ~= "table" then return nil end
    seen = seen or {}
    if seen[value] then return nil end
    seen[value] = true
    local out = {}
    for k, v in pairs(value) do
        if type(k) == "string" or type(k) == "number" then
            local x = serializable_copy(v, seen)
            if x ~= nil then out[k] = x end
        end
    end
    -- 路径级防环:递归返回即解除标记。review_map 与 review_groups 共享同一张
    -- texts 表(annotations.normalize_reviews 直接复用),永久标记会把第二次
    -- 出现的共享表整个丢掉,断点缓存必然写坏。
    seen[value] = nil
    return out
end

function SyncTask:new(store)
    local owner_token = tostring(os.time()) .. "-" .. tostring(math.random(100000,999999))
    local instance = setmetatable({
        store = store,
        job = nil,
        poll_task = nil,
        standby_held = false,
        keep_awake_enabled = true,
        backgrounded = false,
        foreground_poll_interval = 0.40,
        background_poll_interval = 1.50,
        fork_memory_cooldown_until = nil,
        owner_path = store.temp_dir .. "/sync-task-owner.json",
        owner_token = owner_token,
    }, self)
    instance.power_inhibit = PowerInhibit:new{
        marker_path = store.temp_dir .. "/sync-keep-awake.json",
        token = owner_token,
    }
    return instance
end

function SyncTask:set_backgrounded(value)
    self.backgrounded = value == true
end

function SyncTask:set_keep_awake(value)
    self.keep_awake_enabled = value ~= false
    if not self.keep_awake_enabled then self:_release_awake() end
end

function SyncTask:last_state()
    return self.job and self.job.last_progress_state or nil
end

local function read_json(path)
    local raw=U.read_file(path,true)
    if not raw then return nil end
    local ok,value=pcall(Json.decode,raw)
    if ok and type(value)=="table" then return value end
end

local function file_exists(path)
    return tostring(path or "")~="" and lfs.attributes(path)~=nil
end

local function file_mtime(path)
    local attr=lfs.attributes(path)
    return attr and tonumber(attr.modification or attr.change) or nil
end

local function parse_memory_available_kb(raw)
    local values = {}
    for key, value in tostring(raw or ""):gmatch("([%a_]+):%s*(%d+)%s*kB") do
        values[key] = tonumber(value)
    end
    if values.MemAvailable then return values.MemAvailable end
    if values.MemFree then
        return values.MemFree + (values.Buffers or 0) + (values.Cached or 0)
    end
end

local function process_exists(pid)
    pid=tonumber(pid)
    if not pid or pid<=1 then return false end
    local proc="/proc/"..tostring(pid)
    if lfs.attributes("/proc","mode")~="directory" then return nil end
    if lfs.attributes(proc,"mode")~="directory" then return false end
    local status=U.read_file(proc.."/status",true) or ""
    local state=status:match("[\r\n]State:%s*([A-Z])") or status:match("^State:%s*([A-Z])")
    if state=="Z" or state=="X" then return false end
    return true
end

local function diagnostics_enabled(preferences)
    return type(preferences) == "table" and preferences.debug_mode == true
end

local SIGNAL_NAMES = {
    [6] = "SIGABRT", [9] = "SIGKILL", [11] = "SIGSEGV",
    [13] = "SIGPIPE", [15] = "SIGTERM",
}

local function decode_wait_status(raw_status)
    local raw = tonumber(raw_status)
    if not raw then return nil end
    local signal = raw % 128
    if signal == 0 then
        return {
            exited = true,
            raw_status = raw,
            exit_code = math.floor(raw / 256) % 256,
            core_dumped = false,
        }
    end
    return {
        exited = true,
        raw_status = raw,
        signal = signal,
        signal_name = SIGNAL_NAMES[signal] or ("SIG" .. tostring(signal)),
        core_dumped = math.floor(raw / 128) % 2 == 1,
    }
end

-- 必须在 FFIUtil.isSubProcessDone 之前读取状态；后者会调用 waitpid 并丢弃
-- 原始退出码。重启后接管的 worker 不是当前进程的子进程，ECHILD 时回退旧逻辑。
local function wait_process_state(pid)
    if not jit or jit.os ~= "Linux" then return nil, "unsupported" end
    local ok, ffi = pcall(require, "ffi")
    if not ok or not ffi then return nil, "unsupported" end
    pcall(ffi.cdef, "int waitpid(int pid, int *status, int options);")
    local status = ffi.new("int[1]")
    local called, result = pcall(function()
        return tonumber(ffi.C.waitpid(tonumber(pid), status, 1))
    end)
    if not called then return nil, tostring(result) end
    if result == 0 then return {running = true, source = "waitpid"} end
    if result == tonumber(pid) then
        local decoded = decode_wait_status(status[0]) or {}
        decoded.source = "waitpid"
        return decoded
    end
    if result == -1 then
        local errno = tonumber(ffi.errno())
        return nil, errno == 10 and "echild" or ("errno=" .. tostring(errno))
    end
    return nil, "unexpected=" .. tostring(result)
end

-- 可靠终止:FFIUtil.terminateSubProcess 对非亲子进程(重启后 attach 接管)是
-- 静默空操作(waitpid ECHILD 被当作 done 跳过 kill)。杀完必须用 /proc 复核,
-- 仍活着就对进程组直接 SIGKILL;返回「是否确认已死」,杀不死不许收尾。
function SyncTask:_terminate(pid)
    pcall(FFIUtil.terminateSubProcess, pid)
    if process_exists(pid) ~= true then return true end
    local ok, ffi = pcall(require, "ffi")
    if ok and ffi then
        pcall(ffi.cdef, "int kill(int pid, int sig);")
        pcall(function() ffi.C.kill(-tonumber(pid), 9) end)
        pcall(function() ffi.C.kill(tonumber(pid), 9) end)
    end
    return process_exists(pid) ~= true
end

function SyncTask:_claim(pid)
    return U.atomic_write(self.owner_path,Json.encode({
        token=self.owner_token,pid=tonumber(pid),updated_at=os.time(),
    }),true)
end

function SyncTask:_owns_job()
    local owner=read_json(self.owner_path)
    return owner and tostring(owner.token or "")==tostring(self.owner_token)
        and tonumber(owner.pid or 0)==tonumber(self.job and self.job.pid or 0)
end

function SyncTask:descriptor()
    local job=self.job
    if not job then return nil end
    return {
        pid=job.pid,progress_path=job.progress_path,result_path=job.result_path,
        cancel_path=job.cancel_path,worker_settings_path=job.worker_settings_path,
        started_at=job.started_at,owner_token=self.owner_token,task_token=job.task_token,
        mode=job.mode,debug_mode=job.debug_mode,
    }
end

function SyncTask:_reset_device_timeout()
    if not self.keep_awake_enabled then return false end
    return self.power_inhibit:reset_timeout(true)
end

function SyncTask:_memory_available_kb()
    return parse_memory_available_kb(U.read_file("/proc/meminfo", true))
end

function SyncTask:_fork_memory_cooldown_remaining()
    local until_at = tonumber(self.fork_memory_cooldown_until) or 0
    local remaining = until_at - os.time()
    if remaining <= 0 then
        self.fork_memory_cooldown_until = nil
        return 0
    end
    return remaining
end

function SyncTask:_mark_fork_memory_failure(message)
    if not is_memory_error(message) then return false end
    self.fork_memory_cooldown_until = os.time() + FORK_MEMORY_COOLDOWN_SECONDS
    logger.warn("[撷思][SyncTask] fork memory cooldown",
        "seconds=", tostring(FORK_MEMORY_COOLDOWN_SECONDS), "error=", tostring(message))
    return true
end

function SyncTask:_enable_memory_mode()
    if self._memory_mode then return true end
    local ok, mode = pcall(function()
        return require("pickthought.memory_mode"):new(self.store)
    end)
    if not ok then
        logger.warn("[撷思][SyncTask] memory mode unavailable", tostring(mode))
        return nil, tostring(mode)
    end
    local called, enabled, enable_error = pcall(mode.set_enabled, mode, true)
    if not called or not enabled then
        local message = enable_error or enabled
        logger.warn("[撷思][SyncTask] memory mode enable failed", tostring(message))
        return nil, tostring(message)
    end
    self._memory_mode = mode
    return true
end

function SyncTask:_release_memory_mode()
    local mode = self._memory_mode
    self._memory_mode = nil
    if mode then
        local called, restored, restore_error = pcall(mode.set_enabled, mode, false)
        if not called or not restored then
            logger.warn("[撷思][SyncTask] memory mode restore failed",
                tostring(restore_error or restored))
        end
    end
end

function SyncTask:_prepare_worker_memory()
    local before = self:_memory_available_kb()
    self:_enable_memory_mode()
    pcall(function() require("pickthought.thoughts").clear_memory_cache() end)
    collectgarbage("collect")
    local after = self:_memory_available_kb()
    logger.info("[撷思][SyncTask] pre-fork memory",
        "before_kb=", tostring(before), "after_kb=", tostring(after),
        "minimum_kb=", tostring(MIN_FORK_AVAILABLE_KB))
    if after and after < MIN_FORK_AVAILABLE_KB then
        self:_release_memory_mode()
        return nil, string.format(
            "设备可用内存不足(%.0f MB)，未启动同步。请关闭其他书籍或重启 KOReader 后重试。",
            after / 1024)
    end
    return true
end

function SyncTask:_hold_awake()
    if not self.keep_awake_enabled then return end
    if not self.standby_held then
        local ok, err = pcall(function() UIManager:preventStandby() end)
        if not ok then
            logger.warn("[撷思][SyncTask] standby lock failed", tostring(err))
            return
        end
        self.standby_held = true
        self:_enable_memory_mode()
    end
    local system_lock = self.power_inhibit:acquire()
    local reset = self:_reset_device_timeout()
    if self.job then self.job.last_keepalive = os.time() end
    logger.info("[撷思][SyncTask] standby lock requested",
        "system_lock=", tostring(system_lock), "t1_reset=", tostring(reset))
end

function SyncTask:_release_awake()
    if self.standby_held then
        self.standby_held = false
        pcall(function() UIManager:allowStandby() end)
    end
    self.power_inhibit:release()
    self:_release_memory_mode()
    logger.info("[撷思][SyncTask] standby lock release requested")
end

function SyncTask:_maintain_awake(now, force)
    local job = self.job
    if not job or not self.keep_awake_enabled then return false end
    now = tonumber(now) or os.time()
    if not force and job.last_keepalive and now - job.last_keepalive < KEEPALIVE_INTERVAL_SECONDS then
        return false
    end
    job.last_keepalive = now
    self.power_inhibit:verify(true)
    self:_reset_device_timeout()
    return true
end

function SyncTask:available()
    return type(FFIUtil.runInSubProcess) == "function"
        and type(FFIUtil.isSubProcessDone) == "function"
end

function SyncTask:busy()
    return self.job ~= nil
end

function SyncTask:_schedule()
    if self.poll_task then return end
    local task
    task = function()
        if self.poll_task ~= task then return end
        self.poll_task = nil
        self:_poll()
    end
    self.poll_task = task
    local interval = self.backgrounded and self.background_poll_interval or self.foreground_poll_interval
    UIManager:scheduleIn(interval, task)
end

function SyncTask:_read_progress(job)
    local raw = U.read_file(job.progress_path, true)
    if not raw or raw == job.last_progress_raw then return false end
    local ok, state = pcall(Json.decode, raw)
    if ok and type(state) == "table" then
        if job.task_token and tostring(state.task_token or "")~=tostring(job.task_token) then
            job.token_mismatch=true
            logger.warn("[撷思][SyncTask] progress task identity mismatch")
            return false
        end
        job.last_progress_raw = raw
        job.last_progress_state = state
        job.last_progress_at = tonumber(state.updated_at) or file_mtime(job.progress_path) or os.time()
        job.waiting_notified = false
        if self.keep_awake_enabled and not self.standby_held then self:_hold_awake() end
        if job.on_progress then job.on_progress(state) end
        return true
    end
    return false
end

function SyncTask:_finish(job, forced_error)
    self:_read_progress(job)
    local raw = U.read_file(job.result_path, true)
    local result
    if forced_error then
        result = {ok = false, error = forced_error}
    elseif not raw then
        result = {ok = false, error = "同步子进程异常退出;已拉取的章节保存在断点缓存,再次同步会继续。"}
    else
        local ok, decoded = pcall(Json.decode, raw)
        result = ok and decoded or {ok = false, error = "同步结果无法解析"}
    end

    os.remove(job.progress_path)
    os.remove(job.result_path)
    os.remove(job.cancel_path)
    if job.worker_settings_path then os.remove(job.worker_settings_path) end
    if self:_owns_job() then os.remove(self.owner_path) end
    self.job = nil
    self:_release_awake()
    if job.on_done then job.on_done(result) end
end

function SyncTask:_poll()
    local job = self.job
    if not job then return end
    if not self:_owns_job() then
        logger.info("[撷思][SyncTask] controller ownership transferred","pid=",tostring(job.pid))
        self.job=nil
        self:_release_awake()
        return
    end

    self:_read_progress(job)
    if job.token_mismatch then
        self:_finish(job,"后台同步任务身份不匹配;断点已保留,请重新开始同步。")
        return
    end
    if file_exists(job.result_path) then self:_finish(job); return end

    local now=os.time()
    -- 挂起豁免:轮询间隔远超调度周期说明设备睡过一觉——挂起期间父子进程都被
    -- 冻结,墙钟静默对子进程不公平;重置活动基线,给它完整的恢复窗口,
    -- 否则唤醒后首轮 poll 会误杀健康的子进程。
    local poll_delayed = job.last_poll_at and now-job.last_poll_at>30
    if poll_delayed then
        logger.info("[撷思][SyncTask] wakeup detected, resetting idle baseline",
            "gap=",tostring(now-job.last_poll_at))
        job.last_progress_at=now
        job.waiting_notified=false
    end
    job.last_poll_at=now
    self:_maintain_awake(now, poll_delayed)

    local wait_state,wait_error
    if job.debug_mode then wait_state,wait_error=wait_process_state(job.pid) end
    local alive=process_exists(job.pid)
    local done_ok,done
    if wait_state and wait_state.running then
        done_ok,done=true,false
    elseif wait_state and wait_state.exited then
        job.exit_status=wait_state
        alive=false
        done_ok,done=true,true
    else
        done_ok,done=pcall(FFIUtil.isSubProcessDone,job.pid,false)
        if job.debug_mode and wait_error and wait_error~="unsupported" and wait_error~="echild"
            and not job.waitpid_error_logged then
            job.waitpid_error_logged=true
            logger.warn("[撷思][SyncTask] waitpid unavailable",tostring(wait_error))
        end
    end
    if not done_ok then
        logger.warn("[撷思][SyncTask] poll failed",tostring(done))
        if alive~=false then self:_schedule(); return end
    end

    -- Android 上重建的 KOReader UI 可能把仍在运行的 worker 误报为 done:
    -- /proc 与结果文件才是权威,waitpid 只作兜底。
    if alive==true or (alive==nil and done_ok and done==false) then
        job.dead_seen_at=nil
        if job.cancel_requested_at and now-job.cancel_requested_at>=8 then
            if self:_terminate(job.pid) then
                self:_finish(job,"同步已取消")
            else
                -- 杀不死(极端情况):保留 cancel 文件让子进程在下个边界自行退出,
                -- 继续轮询,绝不在进程仍活着时谎报「已取消」并删信号文件。
                logger.warn("[撷思][SyncTask] terminate unverified, keep polling","pid=",tostring(job.pid))
                self:_schedule()
            end
            return
        end
        local activity=tonumber(job.last_progress_at or job.started_at) or now
        local idle=math.max(0,now-activity)
        if idle>=120 and not job.waiting_notified then
            job.waiting_notified=true
            local state=U.copy(job.last_progress_state or {})
            -- 停顿提示按阶段说话:只有真会走网络的阶段才提网络;映射/注入是
            -- 纯本地计算,离线重注更是全程零网络,措辞不能撒谎误导排查。
            local stage=tostring(state.stage or "")
            if job.mode~="reinject" and (stage=="chapters" or stage=="fetch") then
                state.waiting_network=true
                state.message="等待网络或服务器响应"
            else
                state.message="仍在处理,进度长时间未更新"
            end
            state.updated_at=now
            if job.on_progress then job.on_progress(state) end
        end
        -- 看门狗:子进程心跳很密(章节/想法批次/注入条目都会发),清醒状态下
        -- 静默 6 分钟远超单次请求最坏重试周期,只能是 DNS 无超时之类的死吊——
        -- 终止并保留断点,把「莫名其妙的卡死」变成有限失败 + 续传。
        -- (挂起时长已被上面的基线重置豁免,不会误杀刚唤醒的子进程。)
        if idle>=360 then
            if self:_terminate(job.pid) then
                self:_finish(job,"同步长时间无响应,已中止;已拉取章节保存在断点缓存,再次同步会继续。")
            else
                logger.warn("[撷思][SyncTask] watchdog terminate unverified, keep polling","pid=",tostring(job.pid))
                U.atomic_write(job.cancel_path,"1",true)
                self:_schedule()
            end
            return
        end
        self:_schedule()
        return
    end

    if job.debug_mode and job.exit_status and not job.exit_status_logged then
        job.exit_status_logged=true
        local state=job.last_progress_state or {}
        logger.warn("[撷思][SyncTask] child exited without result",
            "pid=",tostring(job.pid),"source=",tostring(job.exit_status.source),
            "raw_status=",tostring(job.exit_status.raw_status),
            "exit_code=",tostring(job.exit_status.exit_code),
            "signal=",tostring(job.exit_status.signal),
            "signal_name=",tostring(job.exit_status.signal_name),
            "core_dumped=",tostring(job.exit_status.core_dumped == true),
            "stage=",tostring(state.stage),"current=",tostring(state.current),
            "total=",tostring(state.total),"chapter=",tostring(state.chapter))
    end
    job.dead_seen_at=job.dead_seen_at or now
    if now-job.dead_seen_at<8 then self:_schedule(); return end
    self:_finish(job)
end

function SyncTask:cancel()
    local job = self.job
    if not job or job.cancel_requested_at or not self:_owns_job() then return end
    job.cancel_requested_at = os.time()
    U.atomic_write(job.cancel_path, "1", true)
end

function SyncTask:clear_stale_awake()
    if self.job then return false end
    return self.power_inhibit:clear_stale()
end

function SyncTask:attach(descriptor,on_progress,on_done)
    if self.job then return false,"已有同步任务正在运行" end
    if not self:available() then return false,"当前 KOReader 不支持后台同步" end
    descriptor=type(descriptor)=="table" and descriptor or nil
    local pid=descriptor and tonumber(descriptor.pid)
    if not pid or not descriptor.progress_path or not descriptor.result_path
        or not descriptor.cancel_path then return false,"同步任务记录不完整" end
    self.keep_awake_enabled=self.store:preferences().sync_keep_awake~=false
    if not self.keep_awake_enabled then self.power_inhibit:clear_stale() end
    self.job={
        pid=pid,progress_path=descriptor.progress_path,result_path=descriptor.result_path,
        cancel_path=descriptor.cancel_path,worker_settings_path=descriptor.worker_settings_path,
        on_progress=on_progress,on_done=on_done,last_progress_raw=nil,last_progress_state=nil,
        last_progress_at=nil,last_keepalive=0,started_at=descriptor.started_at,dead_seen_at=nil,waiting_notified=false,
        task_token=descriptor.task_token,mode=descriptor.mode,
        debug_mode=descriptor.debug_mode==true,
    }
    self.backgrounded=true
    self:_read_progress(self.job)
    if self.job.token_mismatch then
        self.job=nil
        return false,"后台同步任务身份不匹配"
    end
    -- 接管宽限:进度文件的时间戳可能很陈旧(设备刚唤醒/KOReader 刚重启),
    -- 以接管时刻为活动基线,别让看门狗上来就杀。
    self.job.last_progress_at=os.time()
    local done_ok,done=pcall(FFIUtil.isSubProcessDone,pid,false)
    local alive=process_exists(pid)
    if not done_ok and alive==nil then
        self.job=nil
        return false,"无法接管后台同步:"..tostring(done)
    end
    self:_claim(pid)
    self:_hold_awake()
    logger.info("[撷思][SyncTask] attached","pid=",tostring(pid),
        "done=",tostring(done_ok and done or "unknown"),"alive=",tostring(alive))
    if file_exists(self.job.result_path) then
        local attached_job=self.job
        UIManager:scheduleIn(0,function()
            if self.job==attached_job and self:_owns_job() then self:_finish(attached_job) end
        end)
    else
        if alive==false and done_ok and done==true then self.job.dead_seen_at=os.time() end
        self:_schedule()
    end
    return true
end

-- task = {doc_path=原书路径, book_id=微信 bookId, title=显示标题}
function SyncTask:start(task, on_progress, on_done)
    if self.job then return false, "已有同步任务正在运行" end
    if not self:available() then return false, "当前 KOReader 不支持后台同步" end
    local retry_memory = type(task) == "table" and task.allow_memory_retry == true
    local cooldown = self:_fork_memory_cooldown_remaining()
    if cooldown > 0 and not retry_memory then
        return false, string.format(
            "设备刚刚报告内存不足,已暂停自动同步约 %d 秒;请稍后重试或手动重新启动同步。",
            cooldown)
    end
    if retry_memory then self.fork_memory_cooldown_until = nil end

    local stamp = tostring(os.time()) .. "-" .. tostring(math.random(10000, 99999))
    local progress_path = self.store.temp_dir .. "/sync-progress-" .. stamp .. ".json"
    local result_path = self.store.temp_dir .. "/sync-result-" .. stamp .. ".json"
    local cancel_path = self.store.temp_dir .. "/sync-cancel-" .. stamp
    local worker_settings_path = self.store.temp_dir .. "/sync-settings-" .. stamp .. ".lua"
    self.store:flush()
    local copied, copy_error = U.copy_file(self.store.settings_path, worker_settings_path)
    if not copied then return false, "无法建立同步状态副本:" .. tostring(copy_error or "未知错误") end
    local worker_data_dir = self.store.data_dir
    local task_token = stamp .. "-" .. tostring(math.random(100000,999999))
    local doc_path = tostring(task.doc_path or "")
    local book_id = tostring(task.book_id or "")
    local doc_title = tostring(task.title or "")
    -- mode: "sync"=联网增量同步(复用缓存并按游标续传);"reinject"=纯离线,
    -- 只用上次拉取的数据重跑映射+注入,零网络。
    local mode = tostring(task.mode or "sync")
    -- clean_source:外部干净 .epub 路径,作为注入源绕开脏/缺失的 .orig(逃生舱)。
    -- 仅离线重注(reinject)用到;由 main.lua 选书后透传,空则走旧逻辑。
    local clean_source = task.clean_source and tostring(task.clean_source) or nil
    -- 分批风控:每次同步最多拉这么多个新章节,大书分多次完成。
    local preferences = self.store:preferences()
    local batch_limit = tonumber(preferences.sync_batch_limit) or 200
    local debug_mode = diagnostics_enabled(preferences)
    self.keep_awake_enabled = preferences.sync_keep_awake ~= false
    if not self.keep_awake_enabled then self.power_inhibit:clear_stale() end

    local child = function()
        lower_worker_priority()
        local Store = require("pickthought.store")
        local Http = require("pickthought.http")
        local Api = require("pickthought.api")
        local WebFetch = require("pickthought.web_fetch")
        local Sync = require("pickthought.sync")
        local SyncState = require("pickthought.sync_state")
        local EpubReader = require("pickthought.epub_reader")
        local EpubInject = require("pickthought.epub_inject")
        local Thoughts = require("pickthought.thoughts")
        local JsonChild = require("pickthought.json")
        local UChild = require("pickthought.util")
        local LoggerChild = require("logger")

        local diagnostic_logger = LoggerChild.LvDEBUG or LoggerChild.info
        local function worker_memory()
            local available = parse_memory_available_kb(UChild.read_file("/proc/meminfo", true))
            local status = UChild.read_file("/proc/self/status", true) or ""
            local rss = tonumber(status:match("VmRSS:%s*(%d+)%s*kB"))
            return available, rss, math.floor(collectgarbage("count"))
        end
        local function diagnostic(event, ...)
            if not debug_mode then return end
            local args = {"[撷思][Diag]", "event=", tostring(event)}
            for index = 1, select("#", ...) do
                args[#args + 1] = select(index, ...)
            end
            local available, rss, lua_heap = worker_memory()
            args[#args + 1] = "mem_available_kb="
            args[#args + 1] = tostring(available)
            args[#args + 1] = "rss_kb="
            args[#args + 1] = tostring(rss)
            args[#args + 1] = "lua_heap_kb="
            args[#args + 1] = tostring(lua_heap)
            diagnostic_logger(unpack(args))
        end

        local function emit(state)
            state = state or {}
            state.task_token = task_token
            state.updated_at = os.time()
            local ok, encoded = pcall(JsonChild.encode, state)
            if ok then UChild.atomic_write(progress_path, encoded, true) end
        end
        local function cancelled()
            return UChild.file_exists(cancel_path)
        end

        local ok, value = xpcall(function()
            local store = Store:new{
                settings_path = worker_settings_path,
                data_dir = worker_data_dir,
                isolated = true,
            }
            local http = Http:new(store)
            local api = Api:new(http, store, nil)
            local fetcher = WebFetch:new(api)

            -- 心跳:章节内的想法批次、注入条目都发进度,让父进程看门狗能区分
            -- 「慢但活着」与「真死了」。2 秒节流,避免高频写盘。
            local fetch_now = {i = 0, n = 0, title = ""}
            local heartbeat_at = 0
            local function heartbeat(stage, message, percent)
                local now = os.time()
                if now - heartbeat_at < 2 then return end
                heartbeat_at = now
                emit{stage = stage, current = fetch_now.i, total = fetch_now.n,
                    chapter = fetch_now.title, percent = percent, message = message}
            end

            -- 断点/复用缓存:每章拉取结果落盘。
            -- 成功的同步以 .completed 标记收尾并保留数据(供离线重注);
            -- 全新同步看到标记即清空重拉(同步=拿新的);无标记=中断残留,续传。
            local cache_dir = store:book_dir(book_id) .. "/sync-cache"
            UChild.mkdir(cache_dir)
            local completed_marker = cache_dir .. "/.completed"
            local state_path = cache_dir .. "/state.json"
            local commit_path = cache_dir .. "/commit.json"
            local function write_json(path, value)
                local ok_encode, encoded = pcall(JsonChild.encode, value)
                if not ok_encode then return nil, tostring(encoded) end
                local ok_write, write_error = UChild.atomic_write(path, encoded, true)
                if not ok_write then return nil, tostring(write_error or "写入失败") end
                return true
            end
            local function read_json(path)
                local raw = UChild.read_file(path, true)
                if not raw then return nil end
                local ok_decode, decoded = pcall(JsonChild.decode, raw)
                return ok_decode and type(decoded) == "table" and decoded or nil
            end
            local function write_sync_state(value)
                return write_json(state_path, value)
            end
            local function sync_state_options()
                return {
                    now = os.time(),
                    write_state = write_sync_state,
                    write_marker = function(value)
                        return UChild.atomic_write(completed_marker, value, true)
                    end,
                    marker_exists = function() return UChild.file_exists(completed_marker) end,
                    remove_marker = function() return os.remove(completed_marker) end,
                }
            end
            -- 不再清 .completed 缓存:已缓存的章节 resumed 跳过(免费),失败的(缓存
            -- 损坏/不存在)重拉。用户想全新重拉走「重置本书」。之前清缓存导致用户
            -- 点「同步」补齐失败章节时缓存全没(issue #2 评论)。
            local function cache_path(uid) return cache_dir .. "/" .. UChild.id_name(uid) .. ".json" end
            local chapters_cache_path = cache_dir .. "/chapters.json"
            -- 章节列表也入缓存,离线重注才能完全不碰网络。
            local api_for_sync = {
                chapters = function(_, bid)
                    if mode == "reinject" then
                        local raw = UChild.read_file(chapters_cache_path, true)
                        if not raw then error("没有上次的同步数据,请先完整同步一次") end
                        local ok_decode, decoded = pcall(JsonChild.decode, raw)
                        if not ok_decode or type(decoded) ~= "table" then
                            error("上次同步数据损坏,请重新完整同步")
                        end
                        return decoded
                    end
                    local data = api:chapters(bid)
                    local ok_encode, encoded = pcall(JsonChild.encode, serializable_copy(data))
                    if ok_encode then UChild.atomic_write(chapters_cache_path, encoded, true) end
                    return data
                end,
            }
            local function fetch_percent()
                return 0.03 + (fetch_now.n > 0 and (fetch_now.i - 1) / fetch_now.n or 0) * 0.77
            end
            -- 缓存体检:review_groups 每项必须带 texts 表(防旧版坏缓存),不合格当未命中重拉。
            local function cache_valid(data)
                if type(data) ~= "table" or type(data.underlines) ~= "table" then return false end
                if type(data.review_groups) == "table" then
                    for _, group in ipairs(data.review_groups) do
                        if type(group) ~= "table" or type(group.texts) ~= "table" then return false end
                    end
                end
                return true
            end
            local previous_state = {}
            local state_raw = UChild.read_file(state_path, true)
            if state_raw then
                local state_ok, decoded = pcall(JsonChild.decode, state_raw)
                if state_ok and type(decoded) == "table" then previous_state = decoded end
            end
            local incremental = mode == "sync"
            if incremental then
                -- 上次若在 EPUB 换位后、sidecar 提交前退出,先用提交记录补齐状态。
                local pending_commit = read_json(commit_path)
                if pending_commit and type(pending_commit.report) == "table" then
                    local recovered, recover_error = SyncState.commit(
                        pending_commit.report, sync_state_options())
                    if not recovered then
                        error("上次同步提交未完成:" .. tostring(recover_error))
                    end
                    os.remove(commit_path)
                    if UChild.file_exists(commit_path) then
                        error("上次同步提交记录无法清理")
                    end
                    previous_state = recovered
                end
            end
            local completed = incremental and SyncState.is_complete(previous_state,
                UChild.file_exists(completed_marker)) or false
            local retry_after = tonumber(previous_state.retry_after)
            if retry_after and retry_after > os.time() then
                FFIUtil.usleep((retry_after - os.time()) * 1000000)
            end
            local chapter_start = 1
            if incremental and not completed then
                chapter_start = tonumber(previous_state.next_index)
                    or ((tonumber(previous_state.total) or 0)
                        - (tonumber(previous_state.pending) or 0) + 1)
                chapter_start = math.max(1, chapter_start)
            end
            if incremental then
                local running_ok, running_error = write_sync_state{
                    status = "running", total = previous_state.total,
                    pending = previous_state.pending, next_index = chapter_start,
                    updated_at = os.time(),
                }
                if not running_ok then
                    error("无法记录同步开始状态:" .. tostring(running_error))
                end
            end
            local cached_annotations = {
                fetch_chapter = function(_, bid, uid)
                    local fetch_started = os.time()
                    diagnostic("chapter_begin", "book=", tostring(bid),
                        "chapter=", tostring(uid), "index=", tostring(fetch_now.i))
                    local raw = UChild.read_file(cache_path(uid), true)
                    if raw then
                        local good, data = pcall(JsonChild.decode, raw)
                        if good and cache_valid(data) then
                            data.resumed = true
                            diagnostic("chapter_done", "book=", tostring(bid),
                                "chapter=", tostring(uid), "source=", "cache",
                                "elapsed_s=", tostring(os.time() - fetch_started),
                                "underlines=", tostring(data.underline_count or 0),
                                "thoughts=", tostring(data.thought_entry_count or 0))
                            return data
                        end
                    end
                    if mode == "reinject" then
                        -- 离线重注绝不碰网络。分批场景下缓存本来就可能只覆盖前若干批,
                        -- 缺章按"无数据"处理(resumed 免得占预算/动熔断),照常注入已有部分。
                        return {
                            book_id = tostring(bid), chapter_uid = tostring(uid),
                            underlines = {}, review_map = {}, review_groups = {},
                            underline_count = 0, thought_count = 0, thought_entry_count = 0,
                            errors = {}, underline_request_ok = true, resumed = true,
                        }
                    end
                    local data = fetcher:fetch_chapter(bid, uid, function(stage2, i2, n2, extra)
                        if stage2 == "thoughts" then
                            heartbeat("fetch", "想法批次 " .. tostring(i2) .. "/" .. tostring(n2)
                                .. (extra and extra ~= "" and (" " .. tostring(extra)) or ""), fetch_percent())
                        else
                            heartbeat("fetch", nil, fetch_percent())
                        end
                    end)
                    diagnostic("chapter_done", "book=", tostring(bid),
                        "chapter=", tostring(uid), "source=", "network",
                        "elapsed_s=", tostring(os.time() - fetch_started),
                        "underlines=", tostring(type(data) == "table" and data.underline_count or 0),
                        "thoughts=", tostring(type(data) == "table" and data.thought_entry_count or 0),
                        "errors=", tostring(type(data) == "table" and #(data.errors or {}) or 1))
                    -- 只有整章完整成功才缓存,否则下次重拉。
                    if type(data) == "table" and data.underline_request_ok ~= false
                        and #(data.errors or {}) == 0 then
                        local slim = serializable_copy({
                            underlines = data.underlines, review_map = data.review_map,
                            review_groups = data.review_groups,
                            underline_count = data.underline_count,
                            thought_count = data.thought_count,
                            thought_entry_count = data.thought_entry_count,
                            errors = {}, underline_request_ok = true,
                        })
                        local enc_ok, encoded = pcall(JsonChild.encode, slim)
                        if enc_ok then UChild.atomic_write(cache_path(uid), encoded, true) end
                    end
                    -- 礼貌间隔:章与章之间随机停 200~400ms,请求速率贴近真人翻章。
                    FFIUtil.usleep((200 + math.random(0, 200)) * 1000)
                    return data
                end,
            }

            emit{stage = "prepare", current = 0, total = 1, chapter = doc_title}
            -- 清扫上次被硬杀留下的中间文件(书目录里用户看得见)与缓存孤儿 tmp。
            -- 注意绝不能碰 .orig 原书备份。
            local book_dir_path = doc_path:match("^(.*)/[^/]+$")
            if book_dir_path then
                for _, file in ipairs(UChild.list(book_dir_path)) do
                    if file ~= doc_path and file:find(doc_path, 1, true) == 1
                        and (file:find(".pickthought-new", #doc_path + 1, true)
                            or file:find(".撷思.epub.tmp", #doc_path + 1, true)) then
                        os.remove(file)
                    end
                end
            end
            for _, file in ipairs(UChild.list(cache_dir)) do
                if file:match("%.tmp%-%d+%-%d+$") then os.remove(file) end
            end

            -- 注入前释放拉取阶段的网络缓存/JSON 对象,降内存水位(低内存设备防 OOM)
            collectgarbage("collect")

            local sync_started = os.time()
            local diagnostic_stage, diagnostic_bucket
            diagnostic("sync_begin", "mode=", mode, "chapter_start=", tostring(chapter_start),
                "batch_limit=", tostring(batch_limit))
            local report, sync_err = Sync.run{
                doc_path = doc_path,
                book_id = book_id,
                clean_source = clean_source,
                api = api_for_sync,
                annotations = cached_annotations,
                load_meta = function(p) return EpubReader.load(p) end,
                read_text = function(m, href) return (EpubReader.read(m, href)) end,
                read_spine = function(m, callback) return EpubReader.each_spine(m, callback) end,
                save_thoughts = function(bid, uid, groups) return Thoughts.save(store, bid, uid, groups) end,
                merge_thoughts = function(bid, uid, from, into) return Thoughts.merge(store, bid, uid, from, into) end,
                inject = function(src, bid, mapped, dest, inject_opts)
                    -- 写包按条目回报(2 秒节流):大书注入+压缩要跑几分钟,
                    -- 百分比与文件计数都得动;心跳同时喂饱父进程的停顿检测,
                    -- 免得纯本地打包被误报成「等待网络」。
                    local last_emit = 0
                    return EpubInject.inject_copy(src, bid, mapped, {dest = dest,
                        append = incremental and (completed or chapter_start > 1),
                        meta = inject_opts and inject_opts.meta,
                        progress = function(_, done, total)
                            local now2 = os.time()
                            if now2 - last_emit < 2 then return end
                            last_emit = now2
                            local pct = 0.90
                            if tonumber(done) and tonumber(total) and total > 0 then
                                pct = 0.90 + math.min(done / total, 1) * 0.09
                            end
                            emit{stage = "inject", current = tonumber(done),
                                total = tonumber(total), percent = pct}
                        end})
                end,
                fetch_budget = mode ~= "reinject" and batch_limit or nil,
                chapter_budget = mode ~= "reinject" and batch_limit or nil,
                chapter_start = mode ~= "reinject" and chapter_start or 1,
                skip_resumed = incremental and completed,
                append = incremental and (completed or chapter_start > 1),
                map_cache_path = cache_dir .. "/map.json",
                spine_cache = true,
                progress = function(phase, i, n, text)
                    if cancelled() then return false end
                    if phase == "map" or phase == "inject" then
                        local bucket = tonumber(i) and tonumber(n) and tonumber(n) > 0
                            and math.floor(math.min(tonumber(i) / tonumber(n), 1) * 10) or 0
                        if phase ~= diagnostic_stage or bucket ~= diagnostic_bucket then
                            diagnostic_stage, diagnostic_bucket = phase, bucket
                            diagnostic("stage_progress", "stage=", phase,
                                "current=", tostring(i), "total=", tostring(n),
                                "elapsed_s=", tostring(os.time() - sync_started))
                        end
                    end
                    local percent
                    if phase == "chapters" then percent = 0.02
                    elseif phase == "fetch" then
                        fetch_now.i, fetch_now.n, fetch_now.title = i, n, tostring(text or "")
                        percent = 0.03 + (n > 0 and (i - 1) / n or 0) * 0.77
                    elseif phase == "map" then
                        -- 映射按正文文件推进,占 0.84~0.90 这一段
                        percent = 0.84 + (n and n > 0 and i and i > 0 and (i / n) * 0.06 or 0)
                    elseif phase == "inject" then percent = 0.90 end
                    emit{stage = phase, current = i, total = n, chapter = text, percent = percent}
                    return true
                end,
            }
            diagnostic("sync_end", "ok=", tostring(report ~= nil),
                "elapsed_s=", tostring(os.time() - sync_started),
                "error=", report and "" or tostring(sync_err))
            if not report then
                local failure_status = cancelled() and "cancelled" or "failed"
                local failure_ok, failure_error = write_sync_state{
                    status = failure_status, total = previous_state.total,
                    pending = previous_state.pending, next_index = previous_state.next_index
                        or chapter_start, updated_at = os.time(),
                }
                if not failure_ok then
                    LoggerChild.warn("[撷思][SyncTask] failure state save failed", tostring(failure_error))
                end
                error(sync_err or "同步失败")
            end
            -- 状态落盘:阅读端据此做「继续拉取」菜单与自动分批触发。
            -- 离线重注不写:它不碰网络,pending 恒为 0,写进去会把「还剩 N 章」
            -- 的真实批次状态抹掉(真机翻车:重注后续拉菜单消失)。
            if mode ~= "reinject" then
                local journal_ok, journal_error = write_json(commit_path, {
                    version = 1, report = serializable_copy(report), created_at = os.time(),
                })
                if not journal_ok then
                    error("同步内容已生成,但提交记录保存失败:" .. tostring(journal_error))
                end
                local state, state_error = SyncState.commit(report, sync_state_options())
                if not state then error(state_error) end
                os.remove(commit_path)
                if UChild.file_exists(commit_path) then
                    error("同步状态已提交,但提交记录无法清理")
                end
            end
            return {report = report, auth = store:auth()}
        end, debug.traceback)

        local payload
        if ok then
            emit{stage = "done", current = 1, total = 1, percent = 1, chapter = doc_title}
            payload = {
                ok = true,
                report = serializable_copy(value and value.report),
                auth = serializable_copy(value and value.auth),
            }
        else
            local raw_error = tostring(value)
            LoggerChild.warn("[撷思][SyncTask] child failed", raw_error)
            local display_error = raw_error:match("^(.-)\nstack traceback:") or raw_error
            display_error = display_error:gsub("^.-%.lua:%d+:%s*", "")
            if is_memory_error(raw_error) then
                display_error = "设备内存不足,同步未完成;原书与已有副本未受影响,已拉取章节保存在断点缓存。"
            end
            local was_cancelled = cancelled() or display_error == "已取消"
            emit{stage = was_cancelled and "cancelled" or "error", message = display_error}
            payload = {ok = false, cancelled = was_cancelled or nil, error = display_error}
        end
        local encoded = JsonChild.encode(payload)
        UChild.atomic_write(result_path, encoded, true)
    end

    local prepared, prepare_error = self:_prepare_worker_memory()
    if not prepared then
        os.remove(worker_settings_path)
        return false, prepare_error
    end

    local ok, pid, err = pcall(FFIUtil.runInSubProcess, child, false, false)
    if not ok or not pid then
        os.remove(worker_settings_path)
        self:_release_memory_mode()
        local launch_error = tostring(err or pid or "无法启动同步子进程")
        self:_mark_fork_memory_failure(launch_error)
        return false, launch_error
    end

    self.job = {
        pid = pid,
        progress_path = progress_path,
        result_path = result_path,
        cancel_path = cancel_path,
        worker_settings_path = worker_settings_path,
        on_progress = on_progress,
        on_done = on_done,
        last_progress_raw = nil,
        last_progress_state = nil,
        last_progress_at = nil,
        last_keepalive = 0,
        dead_seen_at = nil,
        waiting_notified = false,
        task_token = task_token,
        mode = mode,
        debug_mode = debug_mode,
        started_at = os.time(),
    }
    self:_claim(pid)
    self.backgrounded = false
    self:_hold_awake()
    logger.info("[撷思][SyncTask] started", "pid=", tostring(pid))
    self:_schedule()
    return true
end

SyncTask.MIN_FORK_AVAILABLE_KB = MIN_FORK_AVAILABLE_KB
SyncTask.FORK_MEMORY_COOLDOWN_SECONDS = FORK_MEMORY_COOLDOWN_SECONDS
SyncTask.KEEPALIVE_INTERVAL_SECONDS = KEEPALIVE_INTERVAL_SECONDS
SyncTask._is_memory_error = is_memory_error
SyncTask._diagnostics_enabled = diagnostics_enabled
SyncTask._parse_memory_available_kb = parse_memory_available_kb
SyncTask._decode_wait_status = decode_wait_status

return SyncTask
