local PerformanceMode = require("pickthought.performance_mode")

T.case("初始未降级", function()
    local perf = PerformanceMode:new({ now_ms = function() return 0 end, slow_ms = 100, consecutive = 2 })
    T.ok(not perf:degraded(), "初始不应降级")
    T.eq(perf:slow_count(), 0, "初始慢计数为 0")
end)

T.case("连续慢条目触发降级", function()
    local t = 0
    local perf = PerformanceMode:new({
        now_ms = function() t = t + 10; return t end, slow_ms = 100, consecutive = 2,
    })
    perf:record("a", 200); T.ok(not perf:degraded(), "单次慢不应降级")
    perf:record("b", 200); T.ok(perf:degraded(), "连续两次慢应降级")
end)

T.case("快单元打断连续慢", function()
    local t = 0
    local perf = PerformanceMode:new({
        now_ms = function() t = t + 10; return t end, slow_ms = 100, consecutive = 2,
    })
    perf:record("a", 200)
    perf:record("b", 10)   -- 快:打断
    T.ok(not perf:degraded(), "快单元应打断连续慢")
    perf:record("c", 200)
    perf:record("d", 200)
    T.ok(perf:degraded(), "重新连续两次慢应降级")
end)

T.case("滑窗裁剪只影响慢计数", function()
    local t = 0
    local perf = PerformanceMode:new({
        now_ms = function() t = t + 10; return t end, slow_ms = 100, consecutive = 2, window_s = 600,
    })
    perf:record("a", 200)
    perf:record("b", 200)
    T.eq(perf:slow_count(), 2, "两慢样本在窗内")
    t = t + 700 * 1000  -- 推进超过窗口
    perf:record("c", 200)
    T.eq(perf:slow_count(), 1, "旧样本已移出窗口")
end)

T.case("reset 清空状态", function()
    local t = 0
    local perf = PerformanceMode:new({
        now_ms = function() t = t + 10; return t end, slow_ms = 100, consecutive = 2,
    })
    perf:record("a", 200)
    perf:record("b", 200)
    T.ok(perf:degraded(), "已降级")
    perf:reset()
    T.ok(not perf:degraded(), "reset 后未降级")
    T.eq(perf:slow_count(), 0, "reset 后慢计数为 0")
end)

T.case("降级时 rest 调用注入回调", function()
    local called = 0
    local perf = PerformanceMode:new({
        now_ms = function() return 0 end, rest = function() called = called + 1 end,
        slow_ms = 100, consecutive = 1,
    })
    perf:record("a", 200)
    T.ok(perf:degraded(), "单次超阈值即降级")
    perf:rest()
    T.eq(called, 1, "rest 应调用注入回调")
    perf:reset()
    perf:rest()
    T.eq(called, 2, "rest() 始终执行注入回调(降级与否由调用方决定)")
end)

T.case("default() 字段合理", function()
    local perf = PerformanceMode.default()
    T.eq(perf.window_s, 600, "默认滑窗 600s")
    T.eq(perf.slow_ms, 1200, "默认慢阈值 1200ms")
    T.eq(perf.consecutive, 2, "默认连续 2 次")
    T.eq(perf.rest_min_gap_ms, 1000, "默认让出墙钟节流 1000ms")
end)

T.case("滑窗外陈旧慢样本不续接 streak(fix #3)", function()
    local t = 0
    local perf = PerformanceMode:new({
        now_ms = function() t = t + 10; return t end, slow_ms = 100, consecutive = 2, window_s = 600,
    })
    perf:record("a", 200)   -- streak=1,未降级
    T.ok(not perf:degraded(), "单次慢不应降级")
    t = t + 700 * 1000      -- 推进超过窗口(>600s)
    perf:record("b", 200)   -- 与上一次慢间隔已超出窗口 → 视为新段起点 streak=1,而非续接成 2
    T.ok(not perf:degraded(), "窗口外的陈旧慢样本不应续接 streak 触发降级")
end)

T.case("rest 墙钟节流(fix #4):让出次数受限,不随条目线性增长", function()
    local t = 0
    local perf = PerformanceMode:new({
        now_ms = function() return t end, slow_ms = 100, consecutive = 1, rest_min_gap_ms = 1000,
    })
    local rest_calls = 0
    perf._rest = function() rest_calls = rest_calls + 1 end
    perf:record("x", 200)    -- 触发降级
    local entries = 1615
    for i = 1, entries do
        t = t + 150         -- 每单元 +150ms 时钟
        if perf:degraded() then perf:rest() end
    end
    T.ok(rest_calls < entries, "让出次数必须 < 条目数(无节流时等于 1615)")
    T.ok(rest_calls <= 250, "墙钟节流后应在 ~240 次量级,而非 1615")
    T.ok(rest_calls >= 100, "节流不应完全饿死让出(应有合理次数)")
end)

-- 作者意见 #1:生产默认计时器必须拆分 ffi/util.gettime() 的(秒, 微秒)两个返回值,
-- 否则只有整秒精度(1200-1999ms 被记成 1000ms 漏触发降级);且 gettimeofday 非单调,
-- 需对时钟回拨做保护。
T.case("default 时钟:拆分秒+微秒得完整毫秒 + 回拨保护(fix #1)", function()
    package.preload["ffi/util"] = function()
        return { gettime = function() return 1700000000, 123456 end, usleep = function() end }
    end
    package.loaded["ffi/util"] = nil  -- 清缓存,使 require 重新走 preload
    local perf = PerformanceMode.default()
    -- 1700000000s,123456us → 1700000000*1000 + 123456/1000 = 1700000000123.456 → floor
    T.eq(perf:now(), 1700000000123, "秒+微秒合并为完整毫秒(非整秒精度)")
    -- 回拨保护:第二次 gettime 微秒回拨,now 不应变小。
    package.preload["ffi/util"] = function()
        local seq = { { 1700000000, 200000 }, { 1700000000, 100000 } }  -- 第二次微秒回拨
        local i = 0
        return { gettime = function() i = i + 1; local v = seq[i] or seq[2]; return v[1], v[2] end,
                 usleep = function() end }
    end
    package.loaded["ffi/util"] = nil
    local perf2 = PerformanceMode.default()
    local a = perf2:now()  -- 1700000000200
    local b = perf2:now()  -- 1700000000100(回拨) → 钳制为 >= a
    T.ok(b >= a, "时钟回拨被钳制为非递减(now 不回退)")
    package.preload["ffi/util"] = nil
    package.loaded["ffi/util"] = nil
end)

-- 作者意见 #2:子进程 worker 的默认 rest 走 fu.usleep(阻塞式让出 CPU,worker 无 UIManager
-- 安全);前台 Trapper 回退路径必须替换为非阻塞 rest(如 no-op),否则 usleep 会阻塞前台
-- 协程且不交还 UIManager。本测试验证这一契约:默认 rest 调 usleep,而传入的 no-op rest
-- 不再调 usleep(即 main.lua 前台包装所做的替换是有效的)。
T.case("default rest 用 fu.usleep;前台回退可替换为 no-op 非阻塞(#2)", function()
    local usleep_calls = 0
    package.preload["ffi/util"] = function()
        return { gettime = function() return 0, 0 end,
                 usleep = function() usleep_calls = usleep_calls + 1 end }
    end
    package.loaded["ffi/util"] = nil
    local perf_def = PerformanceMode.default()
    perf_def._rest()  -- 默认 rest 应调用 fu.usleep(子进程路径)
    T.eq(usleep_calls, 1, "默认 rest 调用 fu.usleep(子进程 worker 让出)")
    -- 前台回退路径:显式传入 no-op rest,降级时不得再调用 usleep。
    usleep_calls = 0
    local perf_fg = PerformanceMode:new({ now_ms = function() return 0 end, rest = function() end })
    perf_fg._rest()
    T.eq(usleep_calls, 0, "前台 no-op rest 不调用 fu.usleep(非阻塞)")
    package.preload["ffi/util"] = nil
    package.loaded["ffi/util"] = nil
end)
