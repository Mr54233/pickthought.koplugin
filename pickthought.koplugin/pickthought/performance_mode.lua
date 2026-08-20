-- pickthought/performance_mode.lua
-- 滑窗耗时采样 + 降级标志。纯状态机,无 UIManager 依赖。
--
-- 设计约束(来自对注入热路径的探查):
--   * 注入热路径运行在 FFIUtil.runInSubProcess 派生的 worker 子进程内,无 UIManager 事件循环,
--     因此「插入 UIManager:tick 防墨水屏冻结」在此语义不成立;退而求其次,降级时在慢单元之间
--     让出 CPU(默认 FFIUtil.usleep),把算力交还阅读主线程,防低性能墨水屏(KPW3)卡顿。
--   * 既有代码多用整秒 os.time(),无法分辨 <1s 的慢阈值,故时钟必须由调用方注入单调毫秒。
--
-- 用法:
--   local perf = PerformanceMode.default()          -- 生产默认(ffi 时钟 + 默认 usleep 让出)
--   local perf = PerformanceMode:new({ now_ms=fake, slow_ms=500, consecutive=3 })  -- 测试/自定义
--   perf:record("ch-12", elapsed_ms)                -- 每单元处理完调用一次
--   if perf:degraded() then perf:rest() end          -- 降级时让出 CPU
local M = {}
M.__index = M

local function make_default_clock()
    local ok, fu = pcall(require, "ffi/util")
    if ok and fu and fu.gettime then
        -- fu.gettime() 返回两个值:秒、微秒。旧实现 math.floor(fu.gettime()*1000)
        -- 只乘了第一个返回值(秒),微秒被丢弃 → 仅整秒精度,1200-1999ms 慢单元被
        -- 记成 1000ms 而漏触发降级(作者意见 #1)。此处拆分秒+微秒得完整毫秒精度。
        -- 另:gettimeofday 非单调,系统时间回拨/跳变会让 now 变小,破坏耗时与窗口判断;
        -- 故取非递减值做回拨保护(作者意见 #1:对时钟回拨进行保护)。
        local last = 0
        return function()
            local sec, usec = fu.gettime()
            sec = tonumber(sec) or 0
            usec = tonumber(usec) or 0
            -- 拆分秒+微秒得完整毫秒并向下取整:1700000000,123456 → 1700000000123。
            local now = math.floor(sec * 1000 + usec / 1000)
            if now < last then now = last end  -- 回拨保护:钳制为非递减
            last = now
            return now
        end
    end
    -- 回退:os.clock 本身是单调(进程 CPU 时间),天然抗回拨。
    return function() return math.floor((os.clock() or 0) * 1000) end
end

-- 降级时让出 CPU:默认 FFIUtil.usleep(150ms);ffi 不可用时为空操作(测试环境安全)。
local function make_default_rest()
    local ok, fu = pcall(require, "ffi/util")
    if ok and fu and fu.usleep then
        return function() fu.usleep(150 * 1000) end
    end
    return function() end
end

function M:new(opts)
    opts = opts or {}
    local now_ms = opts.now_ms or make_default_clock()
    local rest = opts.rest or make_default_rest()
    return setmetatable({
        now_ms = now_ms,
        window_s = tonumber(opts.window_s) or 600,     -- 滑窗 600s
        slow_ms = tonumber(opts.slow_ms) or 1200,      -- 慢阈值 1200ms
        consecutive = tonumber(opts.consecutive) or 2, -- 连续 2 次超阈值触发降级
        samples = {},
        slow_streak = 0,
        _last_slow_ts = nil,   -- 上一次慢样本的时间戳(ms),用于窗口感知的连续计数
        _degraded = false,
        degraded_since = nil,
        _last_rest_ts = nil,   -- 上一次实际让出的时间戳(ms),用于墙钟节流(#4)
        rest_min_gap_ms = tonumber(opts.rest_min_gap_ms) or 1000,  -- #4:两次让出最小间隔
        _rest = rest,
    }, M)
end

function M.default()
    return M:new({})
end

function M:now()
    return self.now_ms()
end

-- 记录一次单元处理耗时(ms)。裁剪滑窗 + 更新慢连续计数 + 必要时置位降级。
function M:record(name, ms)
    ms = tonumber(ms) or 0
    local now = self.now_ms()
    local cutoff = now - self.window_s * 1000
    while #self.samples > 0 and self.samples[1].t < cutoff do
        table.remove(self.samples, 1)
    end
    self.samples[#self.samples + 1] = { t = now, ms = ms, name = name }
    if ms >= self.slow_ms then
        -- 仅当上一次慢样本也在窗口内,才续接连续计数;否则视为新的连续慢段起点。
        -- 修复 #3:避免陈旧(已超出窗口)的慢样本继续把 streak 推过阈值而误降级。
        if self._last_slow_ts ~= nil and (now - self._last_slow_ts) <= self.window_s * 1000 then
            self.slow_streak = self.slow_streak + 1
        else
            self.slow_streak = 1
        end
        self._last_slow_ts = now
    else
        self.slow_streak = 0
        self._last_slow_ts = nil
    end
    if not self._degraded and self.slow_streak >= self.consecutive then
        self._degraded = true
        self.degraded_since = now
    end
end

function M:degraded()
    return self._degraded
end

-- 降级时让出 CPU;非降级为空操作。
-- #4:墙钟节流——两次实际让出之间至少间隔 rest_min_gap_ms,避免大书(上千条目)每项都
-- sleep 导致累计数百秒(1615 条目 × 150ms ≈ 242s)。被节流跳过时不调用 _rest。
function M:rest()
    local now = self.now_ms()
    if self._last_rest_ts ~= nil and (now - self._last_rest_ts) < self.rest_min_gap_ms then
        return
    end
    self._last_rest_ts = now
    return self._rest()
end

function M:reset()
    self.samples = {}
    self.slow_streak = 0
    self._last_slow_ts = nil
    self._degraded = false
    self.degraded_since = nil
    self._last_rest_ts = nil
end

-- 当前滑窗内慢单元数(诊断/测试用)。
function M:slow_count()
    local n = 0
    for _, s in ipairs(self.samples) do
        if s.ms >= self.slow_ms then n = n + 1 end
    end
    return n
end

return M
