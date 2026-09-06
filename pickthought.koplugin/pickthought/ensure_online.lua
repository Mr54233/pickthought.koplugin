-- 评论加载前的联网保障(实施文档 §7「网络开启策略」)。
--
-- 设计边界:
--   * 已联网:同步判定,立即 on_ready,不打扰 UI。
--   * 未联网:Kindle 优先 restoreWifiAsync + scheduleConnectivityCheck
--     (KOReader 官方恢复路径,connectivityCheck 自身 45 秒放弃);
--     其他平台按可用性降级 toggleWifiOn / turnOnWifi / enableWifi。
--   * 等待全程非阻塞(scheduleIn 检查点),弹窗保持可交互。
--   * generation 防重入:同一弹窗同时只允许一个联网流程;新点击作废旧
--     流程,被作废的回调静默退出;弹窗关闭/返回时调用方作废当前流程。
--   * 开 Wi-Fi 失败(能力缺失/设备拒绝)立即 on_error,不反复开关。
--   * 不主动关闭 Wi-Fi(恢复现场交给 KOReader 的 wifi_was_on 机制)。
local logger = require("logger")

local UIManager = require("ui/uimanager")
local NetworkMgr = require("ui/network/manager")
local Device = require("device")

local M = {}

-- 每次调用的自增代号;调用方保存返回值并据此作废旧流程。
local generation = 0

local deps = {
    network = NetworkMgr,
    uimanager = UIManager,
    device = Device,
}
-- 测试注入点(仅测试修改,不暴露到生产路径)。
M._deps = deps

local function notify(opts, event, payload)
    if type(opts[event]) ~= "function" then return end
    pcall(opts[event], payload)
end

--- 确保设备在线,就绪后回调。
--- opts = {
---   on_status = function(text)   -- 阶段提示:「正在打开 Wi-Fi…」
---   on_ready   = function()      -- 已联网,可以发起请求
---   on_error   = function(message) -- 联网失败/等待超时
--- }
--- @return number generation 本次流程代号(调用方存续期比对用)
function M.ensure_online(opts)
    opts = opts or {}
    generation = generation + 1
    local gen = generation
    local network = deps.network
    local uimanager = deps.uimanager

    local function stale()
        return gen ~= generation
    end

    -- 安全网:connectivityCheck 45 秒自弃但不会回调失败分支,
    -- 这里用自己的超时把失败反馈给用户(实施文档 §7 #6)。
    local finished = false
    local function finish()
        finished = true
    end

    local function fail(message)
        if stale() or finished then return end
        finish()
        logger.info("[撷思][EnsureOnline] 联网失败:", message)
        notify(opts, "on_error", message)
    end

    local function ready()
        if stale() or finished then return end
        finish()
        logger.info("[撷思][EnsureOnline] 已联网")
        notify(opts, "on_ready")
    end

    -- 1) 已连接:同步就绪(非阻塞判定,实施文档 §7 #1)。
    local connected = false
    pcall(function() connected = network:isConnected() == true end)
    if connected then
        ready()
        return gen
    end

    -- 2) 开 Wi-Fi + 等联网。
    logger.info("[撷思][EnsureOnline] Wi-Fi 未连接,尝试打开")
    notify(opts, "on_status", "正在打开 Wi-Fi…")

    local schedule_connectivity = false
    if Device.isKindle and deps.device:isKindle() then
        -- Kindle:官方异步恢复路径(restoreWifiAsync 不阻塞,
        -- scheduleConnectivityCheck 每 0.25s 检查一次,45s 自弃)。
        pcall(function() network:restoreWifiAsync() end)
        schedule_connectivity = true
    else
        -- 其他平台:按可用性降级(实施文档 §7 #3)。
        local started = nil
        if type(network.toggleWifiOn) == "function" then
            started = pcall(function()
                network:toggleWifiOn(function() end, false)
            end)
        elseif type(network.turnOnWifi) == "function" then
            started = pcall(function()
                network:turnOnWifi(function() end, false)
            end)
        elseif type(network.enableWifi) == "function" then
            started = pcall(function()
                network:enableWifi(function() end, false)
            end)
        end
        if not started then
            fail("无法打开 Wi-Fi，请检查设备后重试")
            return gen
        end
        if type(network.scheduleConnectivityCheck) == "function" then
            schedule_connectivity = true
        else
            -- 没有联网检查能力:轮询 isConnected(非阻塞 scheduleIn)。
            local iter = 0
            local function poll()
                if stale() or finished then return end
                iter = iter + 1
                local ok_now = false
                pcall(function() ok_now = network:isConnected() == true end)
                if ok_now then
                    ready()
                elseif iter >= 90 then
                    fail("无法连接网络，请检查 Wi-Fi 后重试")
                else
                    uimanager:scheduleIn(0.5, poll)
                end
            end
            uimanager:scheduleIn(0.5, poll)
            uimanager:scheduleIn(45, function()
                fail("无法连接网络，请检查 Wi-Fi 后重试")
            end)
            return gen
        end
    end

    if schedule_connectivity then
        pcall(function()
            network:scheduleConnectivityCheck(function()
                ready()
            end)
        end)
    end

    -- 超时安全网(45 秒):connectivityCheck 失败时不回调,由这里兜底反馈。
    uimanager:scheduleIn(45, function()
        if stale() or finished then return end
        pcall(function() network:unscheduleConnectivityCheck() end)
        fail("无法连接网络，请检查 Wi-Fi 后重试")
    end)

    return gen
end

--- 作废当前(或指定)流程:弹窗关闭/返回/重新点击时调用。
function M.cancel(target_generation)
    if target_generation ~= nil and target_generation ~= generation then return end
    generation = generation + 1
end

return M
