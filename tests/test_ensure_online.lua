-- 联网保障封装 ensure_online(实施文档 §7):
-- 已连接同步就绪 / Kindle 恢复路径 / 降级路径 / 超时兜底 / generation 作废。

STUBS = STUBS or require("tests.stubs")
package.loaded["pickthought.ensure_online"] = nil

local function fresh_module(deps_overrides)
    -- 每个用例注入独立的 network/uimanager/device,隔离 timers 与状态。
    package.loaded["ui/uimanager"] = nil
    package.loaded["ui/network/manager"] = nil
    package.loaded["device"] = nil
    package.loaded["pickthought.ensure_online"] = nil
    package.preload["ui/uimanager"] = function() return deps_overrides.uimanager end
    package.preload["ui/network/manager"] = function() return deps_overrides.network end
    package.preload["device"] = function() return deps_overrides.device end
    local module = require("pickthought.ensure_online")
    module._deps.uimanager = deps_overrides.uimanager
    module._deps.network = deps_overrides.network
    module._deps.device = deps_overrides.device
    return module
end

local function new_world(opts)
    opts = opts or {}
    local timers = {}
    local world = {
        connected = opts.connected == true,
        timers = timers,
        connectivity_callbacks = {},
        unscheduled = 0,
        restore_called = 0,
        toggle_called = 0,
    }
    world.uimanager = {
        scheduleIn = function(_, delay, fn)
            timers[#timers + 1] = { delay = delay, fn = fn, kind = "schedule" }
        end,
    }
    world.network = {
        isConnected = function() return world.connected end,
        restoreWifiAsync = function() world.restore_called = world.restore_called + 1 end,
        scheduleConnectivityCheck = function(_, callback)
            world.connectivity_callbacks[#world.connectivity_callbacks + 1] = callback
        end,
        unscheduleConnectivityCheck = function() world.unscheduled = world.unscheduled + 1 end,
        toggleWifiOn = opts.toggle and function() world.toggle_called = world.toggle_called + 1 end or nil,
    }
    world.device = {
        isKindle = function() return opts.kindle ~= false end,
    }
    return world
end

local function fire_timer(world, kind, delay)
    for i, timer in ipairs(world.timers) do
        if (kind == nil or timer.kind == kind) and (delay == nil or timer.delay == delay) then
            table.remove(world.timers, i)
            timer.fn()
            return timer
        end
    end
    return nil
end

T.case("已连接:同步 on_ready,不安排任何计时器", function()
    local world = new_world{ connected = true }
    local EO = fresh_module(world)
    local events = {}
    EO.ensure_online{
        on_ready = function() events[#events + 1] = "ready" end,
        on_error = function() events[#events + 1] = "error" end,
    }
    T.eq(#events, 1, "只有 ready"); T.eq(events[1], "ready", "直接就绪")
    T.eq(#world.timers, 0, "无计时器")
    T.eq(world.restore_called, 0, "不触发 Wi-Fi 恢复")
end)

T.case("Kindle 离线:restoreWifiAsync + 联网检查回调后 ready", function()
    local world = new_world{ connected = false, kindle = true }
    local EO = fresh_module(world)
    local events = {}
    local gen = EO.ensure_online{
        on_status = function(text) events[#events + 1] = "status:" .. text end,
        on_ready = function() events[#events + 1] = "ready" end,
        on_error = function() events[#events + 1] = "error" end,
    }
    T.eq(#events, 1, "只有 status"); T.eq(events[1], "status:正在打开 Wi-Fi…", "先提示开 Wi-Fi")
    T.ok(world.restore_called == 1, "调用 restoreWifiAsync")
    T.eq(#world.connectivity_callbacks, 1, "注册联网检查")
    world.connectivity_callbacks[1]()
    T.eq(#events, 2, "两个事件"); T.eq(events[2], "ready", "联网后 ready")
    -- 45 秒兜底计时器在 finished 后失效
    fire_timer(world, "schedule", 45)
    T.eq(#events, 2, "finished 后超时回调不再触发")
end)

T.case("等待超时:on_error 并注销联网检查", function()
    local world = new_world{ connected = false }
    local EO = fresh_module(world)
    local errors = {}
    EO.ensure_online{
        on_ready = function() errors[#errors + 1] = "ready" end,
        on_error = function(msg) errors[#errors + 1] = msg end,
    }
    local timer = fire_timer(world, "schedule", 45)
    T.ok(timer ~= nil, "存在 45 秒兜底计时器")
    T.eq(#errors, 1)
    T.ok(errors[1]:find("无法连接网络", 1, true) ~= nil, "超时提示可重试")
    T.eq(world.unscheduled, 1, "注销 connectivity check")
end)

T.case("generation 作废:旧流程的回调静默退出", function()
    local world = new_world{ connected = false }
    local EO = fresh_module(world)
    local events = {}
    local gen = EO.ensure_online{
        on_ready = function() events[#events + 1] = "ready" end,
        on_error = function() events[#events + 1] = "error" end,
    }
    EO.cancel(gen)
    world.connectivity_callbacks[1]()
    fire_timer(world, "schedule", 45)
    T.eq(#events, 0, "作废后不触发任何回调")
    -- 新流程不受影响
    world.connected = true
    local events2 = {}
    EO.ensure_online{ on_ready = function() events2[#events2 + 1] = "ready" end }
    T.eq(#events2, 1, "新流程 ready"); T.eq(events2[1], "ready")
end)

T.case("非 Kindle 且无降级能力:立即 on_error", function()
    local world = new_world{ connected = false, kindle = false, toggle = false }
    local EO = fresh_module(world)
    local errors = {}
    EO.ensure_online{ on_error = function(msg) errors[#errors + 1] = msg end }
    T.eq(#errors, 1, "无 Wi-Fi 能力立即失败,不反复开关")
end)

T.case("非 Kindle:toggleWifiOn 降级可用", function()
    local world = new_world{ connected = false, kindle = false, toggle = true }
    local EO = fresh_module(world)
    local events = {}
    EO.ensure_online{
        on_status = function() events[#events + 1] = "status" end,
        on_ready = function() events[#events + 1] = "ready" end,
    }
    T.ok(world.toggle_called == 1, "调用 toggleWifiOn")
    T.eq(#world.connectivity_callbacks, 1, "仍注册联网检查")
    world.connectivity_callbacks[1]()
    T.eq(#events, 2, "两个事件"); T.eq(events[2], "ready", "降级后 ready")
end)
