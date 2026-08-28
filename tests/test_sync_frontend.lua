-- 作者 #17 收尾复核(2026-08-18):前台禁用阻塞式 usleep 的集成测试。
-- 此前测试手动构造 no-op PerformanceMode 后直接喂给 inject_copy,并未真正走
-- main.lua:_sync_run 适配器,故无法锁定「前台适配器确实传入 no-op rest」。
-- 本测试改为:加载真实 main.lua,构造最小 Plugin 环境,直接调用 _sync_run,
-- 让真实的注入适配器把 perf 透传给 inject_copy;同时桩一个会记录调用的
-- ffi/util.usleep(模拟真实设备),断言前台路径下 usleep 调用次数为 0。
-- 并以「默认 rest(ffi/util.usleep 存在)确实会触发 usleep」做对照,证明 spy 有效。

local usleep_spy = { calls = 0 }

-- 桩掉 KOReader 专属模块,使 pickthought.main 可在桌面 LuaJIT 环境加载。
-- 需要特殊行为的两个:WidgetContainer:extend 仅返回表;ui/trapper 的 info/clear 被 _sync_run 调用。
package.preload["ui/widget/container/widgetcontainer"] = function()
    return { extend = function(_, t) return t end }
end
package.preload["ui/trapper"] = function()
    return { info = function() return true end, clear = function() end }
end
-- 模拟真实设备存在 ffi/util.usleep:默认 rest 会真正 sleep 阻塞前台协程。
-- max_us 记录单次最大 sleep 时长(评审七轮:用于断言多书限速冷却不做全局大等待)。
package.preload["ffi/util"] = function()
    return { gettime = function() return 1700000000, 0 end,
        usleep = function(us)
            usleep_spy.calls = usleep_spy.calls + 1
            usleep_spy.max_us = math.max(usleep_spy.max_us or 0, tonumber(us) or 0)
        end }
end
-- 其余 KOReader 模块(ui/*、apps/*、device、dispatcher、libs/*)统一桩为占位表,
-- 避免逐个枚举遗漏(如 ui/widget/qrmessage 等)。
table.insert(package.loaders, function(modname)
    if modname:match("^ui/") or modname:match("^apps/") or modname:match("^ffi/")
        or modname == "device" or modname == "dispatcher"
        or modname:match("^libs/") then
        -- 类桩:KOReader 模块普遍以 SomeBase:extend{...} 定义类,故需提供 extend。
        return function() return { extend = function(_, t) return t end } end
    end
    return nil
end)

-- 桩掉 _sync_run 依赖的 pickthought 模块(避免真实 EPUB/网络/DB IO):
-- 这些仅在 _sync_run 内部被 require,且需捕获其传入的 perf。
package.preload["pickthought.thoughts"] = function()
    return {
        save = function(_, _, _, groups) return #(groups or {}) end,
        merge = function() return true end,
        close_book = function() end,
    }
end
-- 网络拉取调用记录(评审七轮:用于断言冷却书 A 不走网络、正常书 B 走网络)。
local fetcher_calls = {}
package.preload["pickthought.web_fetch"] = function()
    return { new = function()
        return { fetch_chapter = function(_, book_id, uid)
            fetcher_calls[#fetcher_calls + 1] = tostring(book_id) .. ":" .. tostring(uid)
            -- 至少返回一条划线 + 想法,使 Sync.run 越过「没有划线」闸门、走到 inject。
            return {
                underlines = { { range = "0-7", markText = "春江潮水连海平" } },
                review_map = { ["0-7"] = { { content = "好句", author = "甲" } } },
                review_groups = { { range = "0-7", texts = { { content = "好句", author = "甲" } } } },
                underline_count = 1, thought_count = 1, thought_entry_count = 1, errors = {},
            }
        end }
    end }
end
package.preload["pickthought.epub_reader"] = function()
    return {
        load = function() return { spine = { { href = "OEBPS/c1.xhtml" } }, has = {} } end,
        -- 章节正文须包含划线的 markText,否则章节匹配失败(Sync.run 在注入前即中止)。
        read = function(_, href)
            return "<html><body><p>春江潮水连海平,海上明月共潮生。</p></body></html>"
        end,
        -- each_spine 须回传 (item, content, err, index):真实实现把章节 HTML 作为
        -- 第 2 个参数喂给 callback(见 epub_reader.lua:156),ChapterMap 靠它做引文投票;
        -- 只传 item 会让 content 为 nil,章节匹配彻底失败。
        each_spine = function(_, cb)
            cb({ href = "OEBPS/c1.xhtml" },
                "<html><body><p>春江潮水连海平,海上明月共潮生。</p></body></html>")
            return true
        end,
    }
end
-- inject 适配器桩:记录 _sync_run 实际透传的 perf,不做真实文件 IO。
local captured = { inject_called = false, perf = nil }
package.preload["pickthought.epub_inject"] = function()
    return { inject_copy = function(_, _, mapped, options)
        captured.inject_called = true
        captured.perf = options and options.perf
        -- 模拟产物文件:Sync.run 注入后 rename temp_dest → doc_path,桩必须落盘。
        local dest = options and options.dest
        if dest then
            local okc, f = pcall(io.open, dest, "w")
            if okc and f then f:write("INJECTED"); f:close() end
        end
        return { injected = #(mapped or {}), marks = 0, unmatched = {}, dropped = 0 }
    end }
end
for _, m in ipairs({ "pickthought.thoughts", "pickthought.web_fetch",
    "pickthought.epub_reader", "pickthought.epub_inject" }) do
    package.loaded[m] = nil  -- 确保 _sync_run 的懒加载拿到桩而非缓存
end

-- 加载真实 main.lua(返回 Plugin 类),不进 require 缓存名冲突。
local chunk = assert(loadfile("pickthought.koplugin/main.lua"))
local Plugin = chunk()

T.case("前台 _sync_run 适配器透传 no-op rest,绝不调用 usleep(作者 #17 收尾复核)", function()
    usleep_spy.calls = 0
    captured.inject_called = false
    captured.perf = nil

    -- 最小 Plugin 环境:_sync_run 只用 self.api / self.store / _book_ids / _sync_fail / _sync_report。
    local self = {}
    function self:_sync_fail(msg) self.fail_msg = msg end
    function self:_sync_report(r) self.report = r end
    -- 多书版 _sync_run 经 _book_ids 取绑定书列表(评审 P1#1 接线)。
    self._book_ids = function() return { "b001" } end
    self.api = { chapters = function()
        return { data = { { chapterUid = 1, title = "第一章", chapterIdx = 1 } } }
    end }
    self.store = {
        book_dir = function() return "/tmp/pt_fake_bookdir" end,
        preferences = function() return {} end,
    }

    -- 关键:走真实 _sync_run 适配器(而非手动构造 perf)。
    -- 该用例只验证前台适配器,映射缓存路径是虚拟路径;显式模拟缓存写成功,
    -- 避免把「虚拟目录不存在」误测成同步提前退出。
    local U = require("pickthought.util")
    local original_atomic_write = U.atomic_write
    U.atomic_write = function(cache_path, data, binary)
        if tostring(cache_path):find("/sync%-cache/map%.json$") then return true end
        return original_atomic_write(cache_path, data, binary)
    end
    Plugin._sync_run(self, "/tmp/书.epub", { book_id = "b001" })
    U.atomic_write = original_atomic_write

    T.ok(captured.inject_called, "前台 _sync_run 应调用 inject 适配器")
    T.ok(captured.perf ~= nil, "_sync_run 应为 inject 传入 perf")
    -- 即使真实设备存在 ffi/util.usleep,前台 no-op rest 也不得触发它(否则阻塞 UI 主线程)。
    T.eq(usleep_spy.calls, 0, "前台 _sync_run 不得调用 usleep(阻塞 UI 主线程)")

    -- 直接调用传入的 perf._rest 也应是非阻塞 no-op(前台路径的保证本体)。
    if captured.perf and captured.perf._rest then captured.perf._rest() end
    T.eq(usleep_spy.calls, 0, "前台 perf._rest 为 no-op(非阻塞)")

    -- 对照:默认 rest(ffi/util.usleep 存在)确实会触发 usleep —— 证明 spy 有效、
    -- 且子进程 worker 路径仍用 usleep 让出 CPU(前台必须避免这条路径)。
    usleep_spy.calls = 0
    local PerformanceMode = require("pickthought.performance_mode")
    PerformanceMode.default()._rest()
    T.ok(usleep_spy.calls > 0, "对照:默认 rest(ffi/util.usleep 存在)应触发 usleep(前台必须避免此路径)")
end)


T.case("离线重注入口只接受有效的章节与映射缓存", function()
    local U = require("pickthought.util")
    local path = "/books/离线重注.epub"
    local cache_root = "/cache/b001/sync-cache/"
    local files = {}
    local saved_read_file, saved_file_exists = U.read_file, U.file_exists
    U.read_file = function(cache_path) return files[tostring(cache_path)] end
    U.file_exists = function(cache_path) return files[tostring(cache_path)] ~= nil end

    local self = {
        store = {
            get = function(_, key, default)
                if key == "bindings" then
                    return {[path] = {b001 = {book_id = "b001", bound_at = 1}}}
                end
                return default
            end,
            set = function() end,
            book_cache_path = function() return "/cache/b001" end,
        },
    }
    self._book_ids = function() return {"b001"} end

    local chapters_path = cache_root .. "chapters.json"
    local map_path = cache_root .. "map.json"
    local ok, err = xpcall(function()
        files[chapters_path] = '{"data":[{"chapterUid":1,"title":"第一章","chapterIdx":1}]}'
        files[map_path] = '{"signature":"sig","map":{"1":{"hrefs":["OEBPS/c1.xhtml"]}}}'
        T.ok(Plugin._has_reinject_cache(self, path), "有效缓存应显示离线重注入口")

        files[chapters_path] = "{}"
        T.ok(not Plugin._has_reinject_cache(self, path), "章节 JSON 结构无效时隐藏入口")
        files[chapters_path] = '{"data":[{"chapterUid":1,"title":"第一章","chapterIdx":1}]}'
        files[map_path] = '{"signature":"sig","map":{"1":{"hrefs":[]}}}'
        T.ok(not Plugin._has_reinject_cache(self, path), "映射目标为空时隐藏入口")
        files[map_path] = "not-json"
        T.ok(not Plugin._has_reinject_cache(self, path), "映射 JSON 损坏时隐藏入口")
    end, debug.traceback)

    U.read_file, U.file_exists = saved_read_file, saved_file_exists
    if not ok then error(err, 0) end
end)

-- 评审七轮(2026-08-21):多书限速冷却调度——A 书 retry_after 未过期(限速冷却)、
-- B 书正常:任务不再按全部书 max retry_after 做启动前全局 usleep;冷却书 A 的
-- 章节列表与章节数据都只读本地缓存(绝不发网络)、保留原状态且不生成 .completed;
-- 未限速书 B 正常拉取注入并生成 .completed;多书重建时 A 的已缓存划线照常参与注入。
T.case("多书限速冷却:A 冷却只读缓存不发网络,B 正常完成,无全局等待", function()
    local dir = "tests/.tmp_cooldown"
    -- 平台适配(CI 是 Linux,本地是 Windows):目录/临时文件操作按平台分支。
    local IS_WINDOWS = package.config:sub(1, 1) == "\\"
    local function rm_dir(d)
        if IS_WINDOWS then os.execute('rd /s /q "' .. d .. '" 2>nul')
        else os.execute('rm -rf "' .. d .. '" 2>/dev/null') end
    end
    local function rm_glob(glob)
        if IS_WINDOWS then
            os.execute('del /q "' .. glob .. '" 2>nul')
        else
            os.execute('rm -f ' .. glob .. ' 2>/dev/null')
        end
    end
    local function mkdirs(d)
        if IS_WINDOWS then
            os.execute('mkdir "' .. d .. '" 2>nul')
        else
            os.execute('mkdir -p "' .. d .. '"')
        end
    end
    -- 开头清理上次残留(断言失败时清理代码不执行,残留的 .orig 会让 src 取错、
    -- 干扰本次运行;每次运行必须从干净状态开始)。
    rm_dir(dir)
    rm_glob(IS_WINDOWS and "tests\\sync-progress-*.json" or "tests/sync-progress-*.json")
    rm_glob(IS_WINDOWS and "tests\\sync-result-*.json" or "tests/sync-result-*.json")
    rm_glob(IS_WINDOWS and "tests\\sync-cancel-*" or "tests/sync-cancel-*")
    local function write_file(path, content)
        local f = assert(io.open(path, "w")); f:write(content); f:close()
    end
    local function fexists(p)
        local f = io.open(p, "rb"); if not f then return false end; f:close(); return true
    end
    -- 逐级创建缓存目录(Windows cmd 与 Linux mkdir -p 分别处理)。
    mkdirs(dir)
    mkdirs(dir .. "/bA")
    mkdirs(dir .. "/bA/sync-cache")
    mkdirs(dir .. "/bB/sync-cache")
    -- A 冷却:state.json 带未过期 retry_after;chapters.json 缓存;1.json 章节缓存(旧划线)。
    write_file(dir .. '/bA/sync-cache/state.json',
        string.format('{"retry_after":%d,"next_index":1,"pending":1,"total":1}', os.time() + 600))
    write_file(dir .. '/bA/sync-cache/chapters.json',
        '{"data":[{"chapterUid":1,"title":"第一章","chapterIdx":1}]}')
    write_file(dir .. '/bA/sync-cache/1.json',
        '{"underlines":[{"range":"0-7","markText":"A旧划线"}],"review_groups":[],"underline_count":1,"thought_count":0,"thought_entry_count":0,"errors":[],"underline_request_ok":true}')
    -- 主书文件(多书重建先备份 doc_path → .orig)。
    write_file(dir .. "/book.epub", "EPUB-CONTENT")
    -- 父进程侧 settings 文件(U.copy_file 复制到 worker settings)。
    write_file("tests/.tmp_cooldown_settings.lua", "return {}\n")

    -- 网络调用记录 + worker 侧依赖桩。
    -- 关键:清掉 run.lua 前面测试缓存的真实 store/http/api/web_fetch 等模块,
    -- 让下面的桩(含文件级 web_fetch/epub_reader/epub_inject/thoughts 桩)生效;
    -- pickthought.sync 保持真实(Sync.run 走完整逻辑)。
    for _, m in ipairs({ "pickthought.store", "pickthought.http", "pickthought.api",
        "pickthought.web_fetch", "pickthought.epub_reader", "pickthought.epub_inject",
        "pickthought.thoughts" }) do
        package.loaded[m] = nil
    end
    local api_chapters_calls = {}
    fetcher_calls = {}
    package.preload["pickthought.store"] = function()
        return { new = function()
            return {
                book_dir = function(_, bid) return "tests/.tmp_cooldown/" .. tostring(bid) end,
                auth = function() return {} end,
            }
        end }
    end
    package.preload["pickthought.http"] = function()
        return { new = function() return {} end }
    end
    package.preload["pickthought.api"] = function()
        return { new = function()
            return { chapters = function(_, bid)
                api_chapters_calls[#api_chapters_calls + 1] = tostring(bid)
                return { data = { { chapterUid = 1, title = "第一章", chapterIdx = 1 } } }
            end }
        end }
    end

    -- 关键:run.lua 前面 test_sync_task 已 require sync_task 并缓存其 ffi/util 桩
    -- (runInSubProcess 不执行 fn)。强制重载,让本文件顶部含 usleep 的桩生效,
    -- 且 SyncTask 的 FFIUtil upvalue 与后续修改的 FFIUtil 指向同一张表。
    package.loaded["pickthought.sync_task"] = nil
    package.loaded["ffi/util"] = nil
    local SyncTask = require("pickthought.sync_task")
    local task_store = {
        temp_dir = "tests",
        settings_path = "tests/.tmp_cooldown_settings.lua",
        data_dir = "tests",
        flush = function() end,
        preferences = function() return { sync_batch_limit = 200, sync_keep_awake = false, sync_debug = false } end,
    }
    local task = SyncTask:new(task_store)
    task._prepare_worker_memory = function() return true end
    task._release_memory_mode = function() end
    task._enable_memory_mode = function() return true end

    local UIManager = require("ui/uimanager")
    UIManager.scheduleIn = function() end  -- start() 尾部 _schedule 用
    local FFIUtil = require("ffi/util")
    FFIUtil.isSubProcessDone = function() return true end  -- available() 要求存在
    FFIUtil.runInSubProcess = function(fn)  -- 同步执行 worker,pid=1。
        fn()
        return 1
    end
    usleep_spy.calls = 0
    usleep_spy.max_us = 0
    captured.inject_called = false

    local ok, err = task:start({
        doc_path = "tests/.tmp_cooldown/book.epub",
        book_id = "bB",
        book_ids = { "bA", "bB" },
        mode = "sync",
        allow_memory_retry = true,
    })
    T.ok(ok, "多书同步任务启动: " .. tostring(err))

    -- 结果 payload:worker 已同步执行完并写 result。
    local result = nil
    if task.job and task.job.result_path then
        local raw = (require("pickthought.util")).read_file(task.job.result_path, true)
        if raw then
            local good, dec = pcall(require("pickthought.json").decode, raw)
            if good then result = dec end
        end
    end
    if not (result and result.ok == true) then
        print("DIAG worker failed:", result and tostring(result.error) or "result=nil",
            "| result_path=", task.job and task.job.result_path or "nil")
        local raw2 = task.job and task.job.result_path
            and (require("pickthought.util")).read_file(task.job.result_path, true) or nil
        print("DIAG raw result:", raw2 or "nil")
    end
    T.ok(result and result.ok == true, "worker 同步成功")

    -- ① 无全局等待:所有 usleep 均 < 1 秒(礼貌间隔 200-400ms;启动前全局冷却等待已删除)。
    T.ok(usleep_spy.max_us < 1000000, "无启动前全局冷却等待(max_usleep=" .. tostring(usleep_spy.max_us) .. ")")
    -- ② A 不发网络:章节列表与章节数据都走缓存,api/fetcher 零调用 A。
    T.eq(#api_chapters_calls, 1, "只有 B 被请求章节列表(A 冷却走缓存)")
    T.eq(api_chapters_calls[1], "bB", "请求章节列表的书是 B")
    T.eq(#fetcher_calls, 1, "只有 B 走网络拉取(A 冷却读缓存)")
    T.eq(fetcher_calls[1], "bB:1", "网络拉取的是 B 第 1 章")
    -- ③ A 不生成 .completed(冷却书保留原状态);B 正常完成生成 .completed。
    T.ok(not fexists(dir .. '/bA/sync-cache/.completed'), "冷却书 A 不生成 .completed")
    T.ok(fexists(dir .. '/bB/sync-cache/.completed'), "正常书 B 生成 .completed")
    -- ④ A 的 state.json 原样保留(retry_after 未被动)。
    local a_state = nil
    local a_raw = (require("pickthought.util")).read_file(dir .. '/bA/sync-cache/state.json', true)
    if a_raw then
        local good, dec = pcall(require("pickthought.json").decode, a_raw)
        if good then a_state = dec end
    end
    T.ok(a_state and a_state.retry_after and a_state.retry_after > os.time(),
        "冷却书 A 的 state.json 保留原 retry_after(未覆盖)")
    -- ⑤ 多书重建:A 的已缓存划线参与注入(B 正常拉取也注入)。
    T.ok(captured.inject_called, "注入执行(A 缓存划线 + B 新划线一起重建)")

    -- 清理临时文件与缓存目录(平台自适应)。
    rm_dir(dir)
    os.remove("tests/.tmp_cooldown_settings.lua")
    rm_glob(IS_WINDOWS and "tests\\sync-progress-*.json" or "tests/sync-progress-*.json")
    rm_glob(IS_WINDOWS and "tests\\sync-result-*.json" or "tests/sync-result-*.json")
    rm_glob(IS_WINDOWS and "tests\\sync-cancel-*" or "tests/sync-cancel-*")
end)

-- 评审八轮 P1#1(2026-08-22):冷却书缓存不完整时,缺失章不得计入已处理、游标停在
-- 首个缺失章、剩余计入 pending、报告显式展示暂缓/剩余待同步、保留 retry_after、
-- 不写 .completed;另一本正常书 B 照常完成。补齐「一本书限速且只缓存部分章节、
-- 另一本书正常同步」的回归测试(此前缺失章被当成空成功数据计入已处理,报告误报完成)。
T.case("多书限速冷却:A 部分缓存(缺失章 deferred),B 正常完成,报告暂缓不误报完成", function()
    local dir = "tests/.tmp_cooldown_partial"
    local IS_WINDOWS = package.config:sub(1, 1) == "\\"
    local function rm_dir(d)
        if IS_WINDOWS then os.execute('rd /s /q "' .. d .. '" 2>nul')
        else os.execute('rm -rf "' .. d .. '" 2>/dev/null') end
    end
    local function rm_glob(glob)
        if IS_WINDOWS then os.execute('del /q "' .. glob .. '" 2>nul')
        else os.execute('rm -f ' .. glob .. ' 2>/dev/null') end
    end
    local function mkdirs(d)
        if IS_WINDOWS then os.execute('mkdir "' .. d .. '" 2>nul')
        else os.execute('mkdir -p "' .. d .. '"') end
    end
    rm_dir(dir)
    rm_glob(IS_WINDOWS and "tests\\sync-progress-*.json" or "tests/sync-progress-*.json")
    rm_glob(IS_WINDOWS and "tests\\sync-result-*.json" or "tests/sync-result-*.json")
    rm_glob(IS_WINDOWS and "tests\\sync-cancel-*" or "tests/sync-cancel-*")
    local function write_file(path, content)
        local f = assert(io.open(path, "w")); f:write(content); f:close()
    end
    local function fexists(p)
        local f = io.open(p, "rb"); if not f then return false end; f:close(); return true
    end
    mkdirs(dir)
    mkdirs(dir .. "/bA/sync-cache")
    mkdirs(dir .. "/bB/sync-cache")
    -- A 冷却:state.json 带未过期 retry_after;chapters.json 列 2 章;只缓存 1.json,
    -- 2.json 故意缺失→第 2 章 deferred(缺失章不计入已处理、游标停在 2、剩余计入 pending)。
    write_file(dir .. '/bA/sync-cache/state.json',
        string.format('{"retry_after":%d,"next_index":1,"pending":2,"total":2}', os.time() + 600))
    write_file(dir .. '/bA/sync-cache/chapters.json',
        '{"data":[{"chapterUid":1,"title":"第一章","chapterIdx":1},{"chapterUid":2,"title":"第二章","chapterIdx":2}]}')
    write_file(dir .. '/bA/sync-cache/1.json',
        '{"underlines":[{"range":"0-7","markText":"A旧划线1"}],"review_groups":[],"underline_count":1,"thought_count":0,"thought_entry_count":0,"errors":[],"underline_request_ok":true}')
    -- 注意:不写 2.json(模拟缺失)→ 第 2 章 deferred。
    write_file(dir .. "/book.epub", "EPUB-CONTENT")
    write_file("tests/.tmp_cooldown_partial_settings.lua", "return {}\n")

    for _, m in ipairs({ "pickthought.store", "pickthought.http", "pickthought.api",
        "pickthought.web_fetch", "pickthought.epub_reader", "pickthought.epub_inject",
        "pickthought.thoughts" }) do
        package.loaded[m] = nil
    end
    package.preload["pickthought.store"] = function()
        return { new = function()
            return {
                book_dir = function(_, bid) return "tests/.tmp_cooldown_partial/" .. tostring(bid) end,
                auth = function() return {} end,
            }
        end }
    end
    package.preload["pickthought.http"] = function()
        return { new = function() return {} end }
    end
    package.preload["pickthought.api"] = function()
        return { new = function()
            return { chapters = function(_, bid)
                -- B 正常书:返回 1 章;A 冷却走缓存,api 不被调用。
                return { data = { { chapterUid = 1, title = "第一章", chapterIdx = 1 } } }
            end }
        end }
    end

    package.loaded["pickthought.sync_task"] = nil
    package.loaded["ffi/util"] = nil
    local SyncTask = require("pickthought.sync_task")
    local task_store = {
        temp_dir = "tests",
        settings_path = "tests/.tmp_cooldown_partial_settings.lua",
        data_dir = "tests",
        flush = function() end,
        preferences = function() return { sync_batch_limit = 200, sync_keep_awake = false, sync_debug = false } end,
    }
    local task = SyncTask:new(task_store)
    task._prepare_worker_memory = function() return true end
    task._release_memory_mode = function() end
    task._enable_memory_mode = function() return true end

    local UIManager = require("ui/uimanager")
    UIManager.scheduleIn = function() end
    local FFIUtil = require("ffi/util")
    FFIUtil.isSubProcessDone = function() return true end
    FFIUtil.runInSubProcess = function(fn) fn(); return 1 end
    usleep_spy.calls = 0
    usleep_spy.max_us = 0
    captured.inject_called = false

    local ok, err = task:start({
        doc_path = "tests/.tmp_cooldown_partial/book.epub",
        book_id = "bB",
        book_ids = { "bA", "bB" },
        mode = "sync",
        allow_memory_retry = true,
    })
    T.ok(ok, "多书同步任务启动: " .. tostring(err))

    local result = nil
    if task.job and task.job.result_path then
        local raw = (require("pickthought.util")).read_file(task.job.result_path, true)
        if raw then
            local good, dec = pcall(require("pickthought.json").decode, raw)
            if good then result = dec end
        end
    end
    T.ok(result and result.ok == true, "worker 同步成功(B 正常完成)")

    -- ① 无全局等待:所有 usleep < 1 秒(礼貌间隔 200-400ms;冷却书不发网络、不全局等待)。
    T.ok(usleep_spy.max_us < 1000000, "无启动前全局冷却等待(max_usleep=" .. tostring(usleep_spy.max_us) .. ")")
    -- ② B 正常完成生成 .completed。
    T.ok(fexists(dir .. '/bB/sync-cache/.completed'), "正常书 B 生成 .completed")
    -- ③ A 不生成 .completed(缺失章 deferred,未真正完成)。
    T.ok(not fexists(dir .. '/bA/sync-cache/.completed'), "冷却书 A 不生成 .completed(缺失章 deferred)")
    -- ④ A 状态:deferred 标记 + pending>0(缺失章计入) + retry_after 保留未覆盖。
    local a_state, a_raw = nil, (require("pickthought.util")).read_file(dir .. '/bA/sync-cache/state.json', true)
    if a_raw then
        local good, dec = pcall(require("pickthought.json").decode, a_raw)
        if good then a_state = dec end
    end
    T.ok(a_state and a_state.deferred == true, "冷却书 A 状态标记 deferred(缺失章未计入已处理)")
    T.ok(a_state and tonumber(a_state.pending) == 1, "冷却书 A pending=1(仅第 2 章未命中)")
    T.ok(a_state and tonumber(a_state.next_index) == 2, "冷却书 A 续传游标停在首个缺失章(第 2 章)")
    T.ok(a_state and a_state.retry_after and a_state.retry_after > os.time(),
        "冷却书 A 保留原 retry_after(未覆盖)")
    -- ⑤ 报告:含 deferred_books、不得显示「全部章节已处理完成」。
    if result and result.report then
        local SyncReport = require("pickthought.sync_report")
        local lines = SyncReport.build(result.report, {})
        local text = table.concat(lines, "\n")
        T.ok(text:find("暂缓") ~= nil, "报告显式展示 A 书暂缓/剩余待同步")
        T.ok(text:find("全部章节已处理完成") == nil, "报告不得误报全部完成(A 缺失章 deferred)")
    else
        print("DIAG: result.report 缺失,跳过报告文本断言")
    end

    rm_dir(dir)
    os.remove("tests/.tmp_cooldown_partial_settings.lua")
    rm_glob(IS_WINDOWS and "tests\\sync-progress-*.json" or "tests/sync-progress-*.json")
    rm_glob(IS_WINDOWS and "tests\\sync-result-*.json" or "tests/sync-result-*.json")
    rm_glob(IS_WINDOWS and "tests\\sync-cancel-*" or "tests/sync-cancel-*")
end)

-- 评审九轮 P1(2026-08-24):冷却书有章节目录缓存但零划线缓存时,每章都返回 deferred
-- (total_underlines==0、fetched 为空),此前会被 sync.lua 的「本批没有划线」分支误判为
-- 普通失败、sync_task 据此清 .completed 并覆盖 state.json,导致 retry_after 与暂缓态丢失、
-- 冷却书下次提前重发请求。修复后 deferred 作为非失败/未完成态返回报告,保留 pending/
-- next_index/retry_after,不生成 .completed,报告显示「暂缓」不误报完成。
T.case("多书限速冷却:A 零划线缓存(全章 deferred),B 正常完成,不误判失败保留 retry_after", function()
    local dir = "tests/.tmp_cooldown_zero"
    local IS_WINDOWS = package.config:sub(1, 1) == "\\"
    local function rm_dir(d)
        if IS_WINDOWS then os.execute('rd /s /q "' .. d .. '" 2>nul')
        else os.execute('rm -rf "' .. d .. '" 2>/dev/null') end
    end
    local function rm_glob(glob)
        if IS_WINDOWS then os.execute('del /q "' .. glob .. '" 2>nul')
        else os.execute('rm -f ' .. glob .. ' 2>/dev/null') end
    end
    local function mkdirs(d)
        if IS_WINDOWS then os.execute('mkdir "' .. d .. '" 2>nul')
        else os.execute('mkdir -p "' .. d .. '"') end
    end
    rm_dir(dir)
    rm_glob(IS_WINDOWS and "tests\\sync-progress-*.json" or "tests/sync-progress-*.json")
    rm_glob(IS_WINDOWS and "tests\\sync-result-*.json" or "tests/sync-result-*.json")
    rm_glob(IS_WINDOWS and "tests\\sync-cancel-*" or "tests/sync-cancel-*")
    local function write_file(path, content)
        local f = assert(io.open(path, "w")); f:write(content); f:close()
    end
    local function fexists(p)
        local f = io.open(p, "rb"); if not f then return false end; f:close(); return true
    end
    mkdirs(dir)
    mkdirs(dir .. "/bA/sync-cache")
    mkdirs(dir .. "/bB/sync-cache")
    -- A 冷却:state.json 带未过期 retry_after;chapters.json 列 2 章;关键:本章节缓存
    -- 完全缺失(不写任何 1.json/2.json)→ 每章都走 cooldown 分支返回 deferred,
    -- total_underlines==0、fetched 为空(零划线缓存场景)。
    write_file(dir .. '/bA/sync-cache/state.json',
        string.format('{"retry_after":%d,"next_index":1,"pending":2,"total":2}', os.time() + 600))
    write_file(dir .. '/bA/sync-cache/chapters.json',
        '{"data":[{"chapterUid":1,"title":"第一章","chapterIdx":1},{"chapterUid":2,"title":"第二章","chapterIdx":2}]}')
    -- 注意:不写任何 1.json / 2.json → 全章 deferred。
    write_file(dir .. "/book.epub", "EPUB-CONTENT")
    write_file("tests/.tmp_cooldown_zero_settings.lua", "return {}\n")

    for _, m in ipairs({ "pickthought.store", "pickthought.http", "pickthought.api",
        "pickthought.web_fetch", "pickthought.epub_reader", "pickthought.epub_inject",
        "pickthought.thoughts" }) do
        package.loaded[m] = nil
    end
    package.preload["pickthought.store"] = function()
        return { new = function()
            return {
                book_dir = function(_, bid) return "tests/.tmp_cooldown_zero/" .. tostring(bid) end,
                auth = function() return {} end,
            }
        end }
    end
    package.preload["pickthought.http"] = function()
        return { new = function() return {} end }
    end
    package.preload["pickthought.api"] = function()
        return { new = function()
            return { chapters = function(_, bid)
                return { data = { { chapterUid = 1, title = "第一章", chapterIdx = 1 } } }
            end }
        end }
    end

    package.loaded["pickthought.sync_task"] = nil
    package.loaded["ffi/util"] = nil
    local SyncTask = require("pickthought.sync_task")
    local task_store = {
        temp_dir = "tests",
        settings_path = "tests/.tmp_cooldown_zero_settings.lua",
        data_dir = "tests",
        flush = function() end,
        preferences = function() return { sync_batch_limit = 200, sync_keep_awake = false, sync_debug = false } end,
    }
    local task = SyncTask:new(task_store)
    task._prepare_worker_memory = function() return true end
    task._release_memory_mode = function() end
    task._enable_memory_mode = function() return true end

    local UIManager = require("ui/uimanager")
    UIManager.scheduleIn = function() end
    local FFIUtil = require("ffi/util")
    FFIUtil.isSubProcessDone = function() return true end
    FFIUtil.runInSubProcess = function(fn) fn(); return 1 end
    usleep_spy.calls = 0
    usleep_spy.max_us = 0
    captured.inject_called = false

    local ok, err = task:start({
        doc_path = "tests/.tmp_cooldown_zero/book.epub",
        book_id = "bB",
        book_ids = { "bA", "bB" },
        mode = "sync",
        allow_memory_retry = true,
    })
    T.ok(ok, "多书同步任务启动: " .. tostring(err))

    local result = nil
    if task.job and task.job.result_path then
        local raw = (require("pickthought.util")).read_file(task.job.result_path, true)
        if raw then
            local good, dec = pcall(require("pickthought.json").decode, raw)
            if good then result = dec end
        end
    end
    -- 关键断言:零划线冷却书不得被误判失败 → worker 整体仍成功(B 正常完成)。
    T.ok(result and result.ok == true, "worker 同步成功(零划线冷却书不误判失败): " .. tostring(err))

    -- ① B 正常完成生成 .completed。
    T.ok(fexists(dir .. '/bB/sync-cache/.completed'), "正常书 B 生成 .completed")
    -- ② A 不生成 .completed(全章 deferred,未真正完成)。
    T.ok(not fexists(dir .. '/bA/sync-cache/.completed'), "冷却书 A 不生成 .completed(零划线全章 deferred)")
    -- ③ A 状态:deferred 标记 + 全章 pending(2 章均未命中) + retry_after 保留未覆盖。
    local a_state, a_raw = nil, (require("pickthought.util")).read_file(dir .. '/bA/sync-cache/state.json', true)
    if a_raw then
        local good, dec = pcall(require("pickthought.json").decode, a_raw)
        if good then a_state = dec end
    end
    T.ok(a_state and a_state.deferred == true, "冷却书 A 状态标记 deferred(零划线全章未计入已处理)")
    T.ok(a_state and tonumber(a_state.pending) == 2, "冷却书 A pending=2(两章均未命中缓存)")
    T.ok(a_state and tonumber(a_state.next_index) == 1, "冷却书 A 续传游标停在第 1 章(首个缺失章)")
    -- ④ 最关键:retry_after 保留未覆盖 —— 此前 bug 会清 .completed 且覆盖 state 丢失 retry_after。
    T.ok(a_state and a_state.retry_after and a_state.retry_after > os.time(),
        "冷却书 A 保留原 retry_after(未因误判失败而丢失)")
    -- ⑤ 报告:含 deferred_books、不得显示「全部章节已处理完成」。
    if result and result.report then
        local SyncReport = require("pickthought.sync_report")
        local lines = SyncReport.build(result.report, {})
        local text = table.concat(lines, "\n")
        T.ok(text:find("暂缓") ~= nil, "报告显式展示 A 书暂缓/剩余待同步")
        T.ok(text:find("全部章节已处理完成") == nil, "报告不得误报全部完成(A 零划线全章 deferred)")
    else
        print("DIAG: result.report 缺失,跳过报告文本断言")
    end

    rm_dir(dir)
    os.remove("tests/.tmp_cooldown_zero_settings.lua")
    rm_glob(IS_WINDOWS and "tests\\sync-progress-*.json" or "tests/sync-progress-*.json")
    rm_glob(IS_WINDOWS and "tests\\sync-result-*.json" or "tests/sync-result-*.json")
    rm_glob(IS_WINDOWS and "tests\\sync-cancel-*" or "tests/sync-cancel-*")
end)
