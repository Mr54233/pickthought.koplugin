-- 想法评论:归一化契约 + 磁盘缓存行为(需求/实施文档"想法评论查看")。
-- 缓存测试使用本文件内置的轻量 SQLite 桩(仅覆盖 review_comment_cache
-- 用到的 SQL 模板,语义与 lua-ljsqlite3 一致);stubs.lua 里的桩是
-- thought_db 专用形状,不能复用。

STUBS = STUBS or require("tests.stubs")

package.loaded["pickthought.review_comments"] = nil
local RC = require("pickthought.review_comments")

-- ---------------------------------------------------------------- 归一化

T.case("评论归一化:标准响应折叠为弹窗条目", function()
    local result = RC.normalize_response({
        comments = {
            { user = { name = "张三" }, content = "写得真好", likes = 3, reviewId = "c1" },
            { author = "李四", content = "  深有同感  ", likeCount = 0 },
            { user = { nickname = "王五" }, content = "", likes = 9 },
        },
        commentsCount = 12,
    }, "r1")
    T.ok(result.ok, "归一化成功")
    T.eq(#result.items, 2, "空内容评论被过滤")
    T.eq(result.items[1].author, "张三")
    T.eq(result.items[1].content, "写得真好")
    T.eq(result.items[1].likes_count, 3)
    T.eq(result.items[1].review_id, "c1")
    T.eq(result.items[2].author, "李四")
    T.eq(result.items[2].content, "深有同感", "首尾空白被清理")
    T.eq(result.total_count, 12, "commentsCount 作为总数")
    T.ok(result.truncated, "总数大于返回条数时标记 truncated")
    T.eq(result.review_id, "r1")
end)

T.case("评论归一化:作者缺失兜底为微信读书用户", function()
    local result = RC.normalize_response({ comments = { { content = "不错" } } }, "r2")
    T.eq(result.items[1].author, "微信读书用户")
    T.eq(result.likes_count == nil, true)
end)

T.case("评论归一化:兼容 review/data 包裹形状", function()
    local result = RC.normalize_response({
        review = { comments = { { content = "A" } }, commentsCount = 1 },
    }, "r3")
    T.ok(result.ok)
    T.eq(#result.items, 1)
    local result2 = RC.normalize_response({
        data = { comments = { { content = "B" } } },
    }, "r4")
    T.ok(result2.ok)
    T.eq(result2.items[1].content, "B")
end)

T.case("评论归一化:非 table/缺数组/errCode 非零 → invalid_response", function()
    for _, data in ipairs({ nil, "text", {}, { errCode = -2012 }, { comments = "x" } }) do
        local result = RC.normalize_response(data, "r")
        T.eq(result.ok, false)
        T.eq(result.error, "invalid_response")
        T.eq(result.message, "微信读书返回了无法识别的数据")
    end
end)

T.case("评论归一化:结果形态失败值透传并映射文案", function()
    local result = RC.normalize_response({ ok = false, error = "rate_limited" }, "r")
    T.eq(result.ok, false)
    T.eq(result.error, "rate_limited")
    T.eq(result.message, "请求频率受限，请稍后再试")
end)

T.case("评论归一化:总数缺省时等于条数且不标记 truncated", function()
    local result = RC.normalize_response({ comments = { { content = "A" }, { content = "B" } } }, "r")
    T.eq(result.total_count, 2)
    T.eq(result.truncated, false)
end)

-- ---------------------------------------------------------------- TTL

T.case("normalize_ttl:合法值保留,非法值归一化为 1800", function()
    for _, value in ipairs({ 0, 300, 600, 1800, 3600 }) do
        T.eq(RC.normalize_ttl(value), value)
    end
    for _, value in ipairs({ nil, "x", -5, 60, 7200, 1.5 }) do
        T.eq(RC.normalize_ttl(value), 1800)
    end
end)

T.case("message_for:未知类别回退 invalid_response 文案", function()
    T.eq(RC.message_for("network"), "网络不可用或请求超时")
    T.eq(RC.message_for("not_logged_in"), "登录已过期，请重新绑定微信读书")
    T.eq(RC.message_for("invalid_review_id"), "这条想法缺少评论 ID")
    T.eq(RC.message_for("nope"), "微信读书返回了无法识别的数据")
end)

-- ---------------------------------------------------------------- 缓存桩

-- 轻量 SQLite 桩:仅实现 review_comment_cache 的 SQL 模板。
local function new_sqlite_stub()
    local SQ3 = { stores = {} }
    local function store_of(path)
        local s = SQ3.stores[path]
        if not s then s = { rows = {}, schema = false }; SQ3.stores[path] = s end
        return s
    end
    local function make_stmt(store, sql)
        local stmt = { _sql = sql, _binds = {}, _done = false }
        function stmt:reset() stmt._binds = {}; stmt._done = false; stmt._cursor = nil; return stmt end
        function stmt:bind(...) stmt._binds = { ... }; return stmt end
        function stmt:step()
            local sql, b = stmt._sql, stmt._binds
            if sql:find("INSERT INTO") then
                -- upsert by review_id
                for i, r in ipairs(store.rows) do
                    if r.review_id == b[1] then store.rows[i] = {
                        review_id = b[1], book_id = b[2], total_count = b[3],
                        payload_json = b[4], fetched_at = b[5],
                        last_access_at = b[6], expires_at = b[7],
                    } return nil end
                end
                store.rows[#store.rows + 1] = {
                    review_id = b[1], book_id = b[2], total_count = b[3],
                    payload_json = b[4], fetched_at = b[5],
                    last_access_at = b[6], expires_at = b[7],
                }
                return nil
            elseif sql:find("UPDATE review_comment_cache SET last_access_at") then
                for _, r in ipairs(store.rows) do
                    if r.review_id == b[2] then r.last_access_at = b[1] end
                end
                return nil
            elseif sql:find("DELETE FROM review_comment_cache WHERE expires_at") then
                local kept = {}
                for _, r in ipairs(store.rows) do
                    if r.expires_at > b[1] then kept[#kept + 1] = r end
                end
                store.rows = kept
                return nil
            elseif sql:find("ORDER BY last_access_at DESC") then
                table.sort(store.rows, function(x, y) return x.last_access_at > y.last_access_at end)
                local kept = {}
                for i, r in ipairs(store.rows) do
                    if i <= b[1] then kept[#kept + 1] = r end
                end
                store.rows = kept
                return nil
            elseif sql:find("SELECT total_count, payload_json, fetched_at") then
                for _, r in ipairs(store.rows) do
                    if r.review_id == b[1] and r.expires_at > b[2] then
                        return { r.total_count, r.payload_json, r.fetched_at }
                    end
                end
                return nil
            elseif sql:find("SELECT review_id, total_count FROM") then
                -- cached_total_counts 的全表扫描:逐行返回,行尽返回 nil
                if stmt._cursor == nil then stmt._cursor = 1 end
                local r = store.rows[stmt._cursor]
                if not r then return nil end
                stmt._cursor = stmt._cursor + 1
                return { r.review_id, r.total_count }
            end
            return nil
        end
        function stmt:close() return true end
        return stmt
    end
    function SQ3.open(path)
        local store = store_of(path)
        local db = {}
        function db:exec(sql)
            sql = tostring(sql or "")
            if sql:find("CREATE TABLE") then store.schema = true end
            if sql:find("DELETE FROM review_comment_cache$") then store.rows = {} end
            return true
        end
        function db:prepare(sql) return make_stmt(store, sql) end
        function db:close() return true end
        return db
    end
    return SQ3
end

local ORIGINAL_SQLITE_PRELOAD = package.preload["lua-ljsqlite3/init"]
local ORIGINAL_SQLITE_LOADED = package.loaded["lua-ljsqlite3/init"]

local function fresh_cache()
    -- 每个用例换一支独立的内存桩;stubs.lua 里的通用桩是 thought_db 专用
    -- 形状,不能复用。文件末尾恢复原 preload,避免污染后续测试。
    local SQ3 = new_sqlite_stub()
    package.preload["lua-ljsqlite3/init"] = function() return SQ3 end
    package.loaded["lua-ljsqlite3/init"] = nil
    -- 让失败路径的 logger.warn 直接可见(缓存写入失败时定位用)。
    package.loaded["logger"] = { dbg = print, info = print,
        warn = function(...) print("[RC-warn]", ...) end, err = print }
    package.loaded["pickthought.review_comments"] = nil
    local module = require("pickthought.review_comments")
    -- 临时探针:确认 json 引擎在 run 语境下的形状
    local j = package.loaded["pickthought.json"]
    print("[probe] json engine:", type(j), j and type(j.encode) or "n/a",
        "raw json:", type(package.loaded["json"]),
        "preload json:", type(package.preload["json"]),
        "path:", package.path:match("([^;]+)"))
    print("[probe] raw json encode:", type(package.loaded["json"] and package.loaded["json"].encode))
    print("[probe] pickthought.json file:", package.searchpath and
        package.searchpath("pickthought.json", package.path) or "n/a")
    local count = 0
    if type(j) == "table" then for _ in pairs(j) do count = count + 1 end end
    print("[probe] j tostring:", tostring(j), "pairs count:", count,
        "same as raw:", j == package.loaded["json"])
    return module, SQ3
end

T.case("缓存:写入后未过期命中,过期后不可见", function()
    local RCm, SQ3 = fresh_cache()
    local cache = RCm.Cache.new{ path = "/tmp/rc-test.db" }
    local result = { ok = true, items = { { author = "a", content = "c" } }, total_count = 1 }
    T.ok(cache:put("r1", "book1", result, 1000, 1800), "写入成功")
    local hit = cache:get("r1", 1500)
    T.ok(hit ~= nil, "有效期内命中")
    T.eq(hit.total_count, 1)
    T.eq(hit.items[1].content, "c")
    T.eq(cache:get("r1", 1000 + 1801), nil, "过期后未命中")
    T.eq(SQ3.stores["/tmp/rc-test.db"].schema, true, "建表语句已执行")
end)

T.case("缓存:cache_get 读透,loader 结果回写,ttl=0 跳过读写", function()
    local RCm = fresh_cache()
    local cache = RCm.Cache.new{ path = "/tmp/rc-test2.db" }
    local calls = 0
    local loader = function()
        calls = calls + 1
        return { ok = true, items = { { author = "a", content = "c" } }, total_count = 1 }
    end
    local first = RCm.cache_get(cache, "r9", loader, "b", 100, 1800)
    T.ok(first.ok and not first.from_cache, "首次未命中走 loader")
    local second = RCm.cache_get(cache, "r9", loader, "b", 200, 1800)
    T.ok(second.ok and second.from_cache, "第二次命中缓存")
    T.eq(calls, 1, "loader 只执行一次")

    local empty_calls = 0
    local disabled_cache = RCm.Cache.new{ path = "/tmp/rc-test3.db" }
    RCm.cache_get(disabled_cache, "r9", function()
        empty_calls = empty_calls + 1
        return { ok = true, items = {}, total_count = 0 }
    end, "b", 100, 0)
    local again = RCm.cache_get(disabled_cache, "r9", function()
        empty_calls = empty_calls + 1
        return { ok = true, items = {}, total_count = 0 }
    end, "b", 200, 0)
    T.eq(empty_calls, 2, "关闭缓存时每次都加载")
    T.ok(again.ok)
end)

T.case("缓存:cache_get 不缓存失败结果,失败不降级", function()
    local RCm = fresh_cache()
    local cache = RCm.Cache.new{ path = "/tmp/rc-test4.db" }
    local calls = 0
    local loader = function()
        calls = calls + 1
        return { ok = false, error = "network", message = "网络不可用或请求超时" }
    end
    local first = RCm.cache_get(cache, "r", loader, "b", 100, 1800)
    local second = RCm.cache_get(cache, "r", loader, "b", 200, 1800)
    T.eq(calls, 2, "失败结果不落盘,每次重试")
    T.eq(first.ok, false)
    T.eq(second.ok, false)
end)

T.case("缓存:cache_get 空 review_id 直接失败,不调 loader", function()
    local RCm = fresh_cache()
    local cache = RCm.Cache.new{ path = "/tmp/rc-test5.db" }
    local called = false
    local result = RCm.cache_get(cache, "", function()
        called = true
        return { ok = true, items = {}, total_count = 0 }
    end, "b", 100, 1800)
    T.eq(called, false)
    T.eq(result.error, "invalid_review_id")
end)

T.case("缓存:超过 max_items 按 last_access_at 淘汰最旧", function()
    local RCm = fresh_cache()
    local cache = RCm.Cache.new{ path = "/tmp/rc-test6.db", max_items = 2 }
    cache:put("r1", "b", { ok = true, items = { { content = "1" } }, total_count = 1 }, 100, 1800)
    cache:put("r2", "b", { ok = true, items = { { content = "2" } }, total_count = 1 }, 200, 1800)
    cache:get("r1", 300)  -- r1 变为最近访问
    cache:put("r3", "b", { ok = true, items = { { content = "3" } }, total_count = 1 }, 400, 1800)
    T.ok(cache:get("r1", 500) ~= nil, "最近访问的 r1 保留")
    T.eq(cache:get("r2", 500), nil, "最旧的 r2 被淘汰")
    T.ok(cache:get("r3", 500) ~= nil, "最新的 r3 保留")
end)

T.case("缓存:clear 清空当前书缓存", function()
    local RCm = fresh_cache()
    local cache = RCm.Cache.new{ path = "/tmp/rc-test7.db" }
    cache:put("r1", "b", { ok = true, items = { { content = "1" } }, total_count = 1 }, 100, 1800)
    T.ok(cache:get("r1", 200) ~= nil)
    T.ok(cache:clear(), "清空成功")
    T.eq(cache:get("r1", 300), nil, "清空后未命中")
end)

T.case("缓存:ttl<=0 拒绝写入", function()
    local RCm = fresh_cache()
    local cache = RCm.Cache.new{ path = "/tmp/rc-test8.db" }
    T.eq(cache:put("r1", "b", { ok = true, items = {}, total_count = 0 }, 100, 0), false)
    T.eq(cache:get("r1", 200), nil)
end)

-- ------------------------------------------ 已知评论数(想法列表 meta 行)

-- 临时缓存库:cached_total_counts 用 Util.file_exists 探测文件存在,
-- 桩库不落盘,所以这里先落一个真实空文件再让桩接管内容。
local COUNTS_DB = "tests/.tmp_rc_counts.db"

local function seed_counts_db(rows)
    os.remove(COUNTS_DB)
    local fh = io.open(COUNTS_DB, "wb")
    T.ok(fh ~= nil, "临时缓存文件已创建(file_exists 探测用)")
    fh:close()
    local RCm = fresh_cache()
    local cache = RCm.Cache.new{ path = COUNTS_DB }
    for _, row in ipairs(rows) do
        cache:put(row.id, "b", { ok = true,
            items = { { content = "c" } }, total_count = row.count },
            row.at or 100, row.ttl or 1800)
    end
    return RCm
end

T.case("cached_total_counts:只返回请求过的 review_id 的评论数", function()
    local RCm = seed_counts_db({ { id = "r1", count = 3 }, { id = "r2", count = 7 } })
    local counts = RCm.cached_total_counts(COUNTS_DB, { "r2", "missing" })
    T.eq(counts.r2, 7)
    T.eq(counts.r1, nil, "未请求的条目不返回")
    T.eq(counts.missing, nil)
    os.remove(COUNTS_DB)
end)

T.case("cached_total_counts:过期行仍返回(展示用提示,点开会刷新)", function()
    local RCm = seed_counts_db({ { id = "r1", count = 5, at = 100, ttl = 10 } })
    local counts = RCm.cached_total_counts(COUNTS_DB, { "r1" })
    T.eq(counts.r1, 5, "不看 expires_at")
    os.remove(COUNTS_DB)
end)

T.case("cached_total_counts:文件不存在返回空表且绝不建文件", function()
    local RCm = fresh_cache()
    os.remove(COUNTS_DB)
    local counts = RCm.cached_total_counts(COUNTS_DB, { "r1" })
    T.eq(next(counts), nil, "文件缺失 → 空表")
    local fh = io.open(COUNTS_DB, "rb")
    T.eq(fh, nil, "只读路径绝不创建缓存文件")
    T.eq(next(RCm.cached_total_counts(COUNTS_DB, {})), nil, "空 id 列表 → 空表")
    T.eq(next(RCm.cached_total_counts("", { "r1" })), nil, "空路径 → 空表")
end)

-- 恢复 stubs.lua 的原 SQLite 桩,后续测试(thought_db 等)不受本文件影响。
package.preload["lua-ljsqlite3/init"] = ORIGINAL_SQLITE_PRELOAD
package.loaded["lua-ljsqlite3/init"] = ORIGINAL_SQLITE_LOADED
package.loaded["logger"] = nil
package.loaded["pickthought.review_comments"] = nil


T.case("归一化:真实设备形状——无 comments 键但 review 详情=合法空评论", function()
    -- 2026-09-05 设备 Cookie 实测:review/single 无评论时顶层无 comments 键
    local result = RC.normalize_response({
        reviewId = "r1",
        review = { content = "原想法", author = { name = "甲" } },
        likesCount = 2,
    }, "r1")
    T.ok(result.ok, "无 comments 键是合法空评论,不是错误")
    T.eq(#result.items, 0)
    T.eq(result.total_count, 0)
end)

T.case("归一化:errCode=-2003(参数格式错误)映射为 invalid_review_id", function()
    -- 设备实测:无效/失效 reviewId 返回 HTTP 200 + errCode=-2003,不是登录失效
    local result = RC.normalize_response({
        errCode = -2003, errMsg = "参数格式错误", errLog = "C3piAf9", info = "",
    }, "bad-rid")
    T.eq(result.ok, false)
    T.eq(result.error, "invalid_review_id")
    T.eq(result.message, "参数格式错误", "透传服务端 errMsg")
end)

T.case("归一化:真实评论条目形状(author 为 table 且 content 取自 content)", function()
    local result = RC.normalize_response({
        comments = {
            { user = { name = "读者甲" }, content = "说得对", likesCount = 3, id = "c9" },
            { author = { name = "读者乙" }, htmlContent = "<p>带标签</p>" },
        },
        commentsCount = 2,
    }, "r1")
    T.ok(result.ok)
    T.eq(result.items[1].author, "读者甲")
    T.eq(result.items[1].likes_count, 3)
    T.eq(result.items[1].review_id, "c9")
    T.eq(result.items[2].author, "读者乙", "author 为 table 时取 name")
    T.ok(result.items[2].content:find("带标签", 1, true) ~= nil)
end)
