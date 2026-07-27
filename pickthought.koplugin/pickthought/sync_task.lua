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
local Device = require("device")
local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")

local SyncTask = {}
SyncTask.__index = SyncTask

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
    return setmetatable({
        store = store,
        job = nil,
        poll_task = nil,
        standby_held = false,
        keep_awake_enabled = true,
        backgrounded = false,
        foreground_poll_interval = 0.40,
        background_poll_interval = 1.50,
        owner_path = store.temp_dir .. "/sync-task-owner.json",
        owner_token = tostring(os.time()) .. "-" .. tostring(math.random(100000,999999)),
    }, self)
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
        mode=job.mode,
    }
end

function SyncTask:_reset_device_timeout()
    if not self.keep_awake_enabled then return false end
    local powerd = Device and Device.powerd
    if powerd and type(powerd.resetT1Timeout) == "function" then
        local ok, err = pcall(powerd.resetT1Timeout, powerd)
        if not ok then logger.warn("[撷思][SyncTask] Kindle T1 reset failed", tostring(err)) end
        return ok
    end
    return false
end

function SyncTask:_hold_awake()
    if not self.keep_awake_enabled or self.standby_held then return end
    local ok, err = pcall(function() UIManager:preventStandby() end)
    if ok then
        self.standby_held = true
        -- T1 重置只管 Kindle 框架的息屏;KOReader 自带的 AutoSuspend 插件是
        -- 另一条独立休眠路径,用 PluginShare.pause_auto_suspend 一并按住
        -- (Kobo 等无 T1 的设备靠的就是这条)。
        pcall(function() require("pluginshare").pause_auto_suspend = true end)
        local reset = self:_reset_device_timeout()
        logger.info("[撷思][SyncTask] standby lock acquired", "t1_reset=", tostring(reset))
    else
        logger.warn("[撷思][SyncTask] standby lock failed", tostring(err))
    end
end

function SyncTask:_release_awake()
    if not self.standby_held then return end
    self.standby_held = false
    pcall(function() UIManager:allowStandby() end)
    pcall(function() require("pluginshare").pause_auto_suspend = false end)
    logger.info("[撷思][SyncTask] standby lock released")
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
    if job.last_poll_at and now-job.last_poll_at>30 then
        logger.info("[撷思][SyncTask] wakeup detected, resetting idle baseline",
            "gap=",tostring(now-job.last_poll_at))
        job.last_progress_at=now
        job.waiting_notified=false
    end
    job.last_poll_at=now
    if not job.last_keepalive or now-job.last_keepalive>=5 then
        job.last_keepalive=now
        self:_reset_device_timeout()
    end

    local alive=process_exists(job.pid)
    local done_ok,done=pcall(FFIUtil.isSubProcessDone,job.pid,false)
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
        if idle>=300 and self.standby_held then
            self:_release_awake()
            logger.info("[撷思][SyncTask] standby lock released while waiting", "pid=", tostring(job.pid))
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

function SyncTask:attach(descriptor,on_progress,on_done)
    if self.job then return false,"已有同步任务正在运行" end
    if not self:available() then return false,"当前 KOReader 不支持后台同步" end
    descriptor=type(descriptor)=="table" and descriptor or nil
    local pid=descriptor and tonumber(descriptor.pid)
    if not pid or not descriptor.progress_path or not descriptor.result_path
        or not descriptor.cancel_path then return false,"同步任务记录不完整" end
    self.keep_awake_enabled=self.store:preferences().sync_keep_awake~=false
    self.job={
        pid=pid,progress_path=descriptor.progress_path,result_path=descriptor.result_path,
        cancel_path=descriptor.cancel_path,worker_settings_path=descriptor.worker_settings_path,
        on_progress=on_progress,on_done=on_done,last_progress_raw=nil,last_progress_state=nil,
        last_progress_at=nil,last_keepalive=0,started_at=descriptor.started_at,dead_seen_at=nil,waiting_notified=false,
        task_token=descriptor.task_token,mode=descriptor.mode,
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
    -- mode: "sync"=全新拉取(完成过的旧缓存先清);"reinject"=纯离线,
    -- 只用上次拉取的数据重跑映射+注入,零网络。
    local mode = tostring(task.mode or "sync")
    -- 分批风控:每次同步最多拉这么多个新章节,大书分多次完成。
    local batch_limit = tonumber(self.store:preferences().sync_batch_limit) or 300
    self.keep_awake_enabled = self.store:preferences().sync_keep_awake ~= false

    local child = function()
        lower_worker_priority()
        local Store = require("pickthought.store")
        local Http = require("pickthought.http")
        local Api = require("pickthought.api")
        local WebFetch = require("pickthought.web_fetch")
        local Sync = require("pickthought.sync")
        local EpubReader = require("pickthought.epub_reader")
        local EpubInject = require("pickthought.epub_inject")
        local Thoughts = require("pickthought.thoughts")
        local JsonChild = require("pickthought.json")
        local UChild = require("pickthought.util")
        local LoggerChild = require("logger")

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
            if mode ~= "reinject" and UChild.file_exists(completed_marker) then
                UChild.remove_tree(cache_dir)
                UChild.mkdir(cache_dir)
            end
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
            local cached_annotations = {
                fetch_chapter = function(_, bid, uid)
                    local raw = UChild.read_file(cache_path(uid), true)
                    if raw then
                        local good, data = pcall(JsonChild.decode, raw)
                        if good and cache_valid(data) then
                            data.resumed = true
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

            local report, sync_err = Sync.run{
                doc_path = doc_path,
                book_id = book_id,
                api = api_for_sync,
                annotations = cached_annotations,
                load_meta = function(p) return EpubReader.load(p) end,
                read_text = function(m, href) return (EpubReader.read(m, href)) end,
                save_thoughts = function(bid, uid, groups) return Thoughts.save(store, bid, uid, groups) end,
                merge_thoughts = function(bid, uid, from, into) return Thoughts.merge(store, bid, uid, from, into) end,
                inject = function(src, bid, mapped, dest)
                    -- 写包按条目回报(2 秒节流):大书注入+压缩要跑几分钟,
                    -- 百分比与文件计数都得动;心跳同时喂饱父进程的停顿检测,
                    -- 免得纯本地打包被误报成「等待网络」。
                    local last_emit = 0
                    return EpubInject.inject_copy(src, bid, mapped, {dest = dest,
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
                map_cache_path = cache_dir .. "/map.json",
                progress = function(phase, i, n, text)
                    if cancelled() then return false end
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
            if not report then error(sync_err or "同步失败") end
            -- 状态落盘:阅读端据此做「继续拉取」菜单与自动分批触发。
            -- 离线重注不写:它不碰网络,pending 恒为 0,写进去会把「还剩 N 章」
            -- 的真实批次状态抹掉(真机翻车:重注后续拉菜单消失)。
            if mode ~= "reinject" then
                local pending = tonumber(report.chapters_pending) or 0
                local state_ok, state_json = pcall(JsonChild.encode, {
                    total = report.chapters_total, pending = pending, updated_at = os.time(),
                })
                if state_ok then UChild.atomic_write(cache_dir .. "/state.json", state_json, true) end
                -- 全部章节拉完才算「完成」:打标记保留缓存供离线重注,
                -- 下次全新同步看到标记会清空重拉;分批未完/取消/失败不打标记=续传。
                if pending == 0 then
                    UChild.atomic_write(completed_marker, tostring(os.time()), true)
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
            if raw_error:lower():find("not enough memory", 1, true) then
                display_error = "设备内存不足,同步未完成;原书与已有副本未受影响,已拉取章节保存在断点缓存。"
            end
            local was_cancelled = cancelled() or display_error == "已取消"
            emit{stage = was_cancelled and "cancelled" or "error", message = display_error}
            payload = {ok = false, cancelled = was_cancelled or nil, error = display_error}
        end
        local encoded = JsonChild.encode(payload)
        UChild.atomic_write(result_path, encoded, true)
    end

    local ok, pid, err = pcall(FFIUtil.runInSubProcess, child, false, false)
    if not ok or not pid then
        os.remove(worker_settings_path)
        return false, tostring(err or pid or "无法启动同步子进程")
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
        started_at = os.time(),
    }
    self:_claim(pid)
    self.backgrounded = false
    self:_hold_awake()
    logger.info("[撷思][SyncTask] started", "pid=", tostring(pid))
    self:_schedule()
    return true
end

return SyncTask
