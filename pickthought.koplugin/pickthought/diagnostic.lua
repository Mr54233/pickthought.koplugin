-- 轻量调试观测:默认关闭,由设置中的 debug_mode 控制。
local logger = require("logger")

local unpack_args = unpack or table.unpack
local time_module
local request_id
local request_seq = 0
local request_started

local M = { enabled = false }

local function now_ms()
    if not time_module then
        local ok, value = pcall(require, "ui/time")
        if ok and type(value) == "table" and type(value.now) == "function" then
            time_module = value
        else
            time_module = false
        end
    end
    if time_module then
        local ok, value = pcall(time_module.now)
        -- ui/time stores fixed-point time in microseconds; normalize to ms so
        -- the diagnostic field names match their actual unit.
        if ok and tonumber(value) then return tonumber(value) / 1000 end
    end
    return math.floor((os.clock() or 0) * 1000 + 0.5)
end

local function elapsed(started)
    return math.max(0, math.floor(now_ms() - (tonumber(started) or now_ms()) + 0.5))
end

function M.set_enabled(value)
    M.enabled = value == true
end

function M.is_enabled()
    return M.enabled == true
end

function M.now()
    return now_ms()
end

function M.elapsed(started)
    return elapsed(started)
end

function M.begin()
    request_seq = request_seq + 1
    request_id = request_seq
    request_started = now_ms()
    return request_id
end

function M.current_id()
    return request_id
end

function M.elapsed_request()
    return elapsed(request_started)
end

function M.finish()
    request_id = nil
    request_started = nil
end

function M.log(event, fields)
    if not M.enabled then return end
    local args = { "[撷思][ThoughtPopupDiag]", "event=", tostring(event) }
    if request_id then
        args[#args + 1] = "request="
        args[#args + 1] = tostring(request_id)
    end
    local keys = {}
    for key in pairs(fields or {}) do keys[#keys + 1] = tostring(key) end
    table.sort(keys)
    for _, key in ipairs(keys) do
        args[#args + 1] = key .. "="
        args[#args + 1] = tostring(fields[key])
    end
    logger.info(unpack_args(args))
end

return M
