local Json = require("pickthought.json")
local U = require("pickthought.util")
local logger = require("logger")

local PowerInhibit = {}
PowerInhibit.__index = PowerInhibit

local SERVICE = "com.lab126.powerd"
local PROPERTY = "preventScreenSaver"
local T1_PROPERTY = "touchScreenSaverTimeout"
local HELPER_TIMEOUT = 3
local VERIFY_INTERVAL = 300

local function default_read(path)
    local raw = U.read_file(path, true)
    if not raw then return nil end
    local ok, value = pcall(Json.decode, raw)
    if ok and type(value) == "table" then return value end
end

local function default_write(path, value)
    local ok, encoded = pcall(Json.encode, value)
    return ok and U.atomic_write(path, encoded, true) or nil
end

local function command_succeeded(ok, _, code)
    if ok == true then return true end
    if type(ok) == "number" then return ok == 0 end
    return tonumber(code) == 0
end

local function run_command(operation)
    if operation.kind == "get" then
        local command = "lipc-get-prop -i " .. SERVICE .. " " .. PROPERTY .. " 2>&1"
        local pipe, open_error = io.popen(command, "r")
        if not pipe then return {ok = false, error = tostring(open_error or "popen failed")} end
        local output = pipe:read("*a") or ""
        local closed, reason, code = pipe:close()
        if not command_succeeded(closed, reason, code) then
            return {ok = false, error = U.first_line(output, 160)}
        end
        local value = tonumber(U.trim(output))
        if value == nil then return {ok = false, error = "invalid value: " .. U.first_line(output, 80)} end
        return {ok = true, value = value}
    end

    local property = operation.kind == "t1" and T1_PROPERTY or PROPERTY
    local value = operation.kind == "t1" and 1 or tonumber(operation.value) or 0
    local command = "lipc-set-prop -i -- " .. SERVICE .. " " .. property .. " "
        .. tostring(value) .. " >/dev/null 2>&1"
    local ok, reason, code = os.execute(command)
    if command_succeeded(ok, reason, code) then return {ok = true} end
    return {ok = false, error = "exit=" .. tostring(code or ok)}
end

function PowerInhibit:new(opts)
    opts = opts or {}
    return setmetatable({
        pluginshare = opts.pluginshare,
        marker_path = assert(opts.marker_path, "marker_path required"),
        token = tostring(opts.token or ""),
        now = opts.now or os.time,
        read_marker = opts.read_marker or default_read,
        write_marker = opts.write_marker or default_write,
        remove_marker = opts.remove_marker or os.remove,
        run_async = opts.run_async,
        ffi_util = opts.ffi_util,
        schedule = opts.schedule,
        queue = {},
        queued_kinds = {},
        worker = nil,
        active = false,
        desired_active = false,
        last_verify = 0,
        last_t1 = 0,
        generation = 0,
        pause_previous = false,
        helper_timeout = tonumber(opts.helper_timeout) or HELPER_TIMEOUT,
        helper_poll_interval = tonumber(opts.helper_poll_interval) or 0.10,
    }, self)
end

function PowerInhibit:_pluginshare()
    if self.pluginshare then return self.pluginshare end
    local ok, value = pcall(require, "pluginshare")
    if ok then self.pluginshare = value end
    return ok and value or nil
end

function PowerInhibit:_marker()
    return self.read_marker(self.marker_path)
end

function PowerInhibit:owns_marker()
    local marker = self:_marker()
    return marker and tostring(marker.token or "") == self.token or false
end

function PowerInhibit:_schedule(delay, callback)
    if self.schedule then
        self.schedule(delay, callback)
        return true
    end
    local ok, manager = pcall(require, "ui/uimanager")
    if not ok or not manager or type(manager.scheduleIn) ~= "function" then return false end
    manager:scheduleIn(delay, callback)
    return true
end

function PowerInhibit:_finish_worker(result)
    local worker = self.worker
    if not worker then return end
    self.worker = nil
    self.queued_kinds[worker.operation.kind] = nil
    if worker.callback then worker.callback(result or {ok = false, error = "missing result"}) end
    self:_start_next()
end

function PowerInhibit:_poll_worker()
    local worker = self.worker
    if not worker then return end
    local ffi_util = worker.ffi_util
    if not worker.timed_out and self.now() - worker.started_at >= self.helper_timeout then
        worker.timed_out = true
        pcall(ffi_util.terminateSubProcess, worker.pid)
        logger.warn("[撷思][PowerInhibit] helper timeout", "operation=", worker.operation.kind)
        local callback = worker.callback
        worker.callback = nil
        if callback then callback({ok = false, error = "helper timeout", timeout = true}) end
    end
    local ok, done = pcall(ffi_util.isSubProcessDone, worker.pid, false)
    if ok and not done then
        self:_schedule(self.helper_poll_interval, function() self:_poll_worker() end)
        return
    end
    local result
    if worker.timed_out then
        result = {ok = false, error = "helper timeout", timeout = true}
    elseif not ok then
        pcall(ffi_util.terminateSubProcess, worker.pid)
        result = {ok = false, error = tostring(done)}
    else
        local raw = U.read_file(worker.result_path, true)
        if raw then
            local decoded, value = pcall(Json.decode, raw)
            result = decoded and value or {ok = false, error = "helper result decode failed"}
        else
            result = {ok = false, error = "helper returned no result"}
        end
    end
    os.remove(worker.result_path)
    os.remove(worker.result_path .. ".tmp")
    self:_finish_worker(result)
end

function PowerInhibit:_run_helper(operation, callback)
    local ffi_util = self.ffi_util
    if not ffi_util then
        local ok_ffi, loaded = pcall(require, "ffi/util")
        if ok_ffi then ffi_util = loaded end
    end
    if not ffi_util or type(ffi_util.runInSubProcess) ~= "function"
        or type(ffi_util.isSubProcessDone) ~= "function" then
        return false, "subprocess unsupported"
    end
    local result_path = self.marker_path .. ".helper-" .. tostring(self.now())
        .. "-" .. tostring(math.random(10000, 99999)) .. ".json"
    local child = function()
        local result = run_command(operation)
        local encoded = Json.encode(result)
        U.atomic_write(result_path, encoded, true)
    end
    local called, pid, start_error = pcall(ffi_util.runInSubProcess, child, false, false)
    if not called or not pid then return false, tostring(start_error or pid) end
    self.worker = {
        pid = pid,
        ffi_util = ffi_util,
        operation = operation,
        callback = callback,
        result_path = result_path,
        started_at = self.now(),
    }
    if not self:_schedule(self.helper_poll_interval, function() self:_poll_worker() end) then
        pcall(ffi_util.terminateSubProcess, pid)
        self.worker = nil
        return false, "scheduler unavailable"
    end
    return true
end

function PowerInhibit:_start_next()
    if self.worker or #self.queue == 0 then return end
    local item = table.remove(self.queue, 1)
    if self.run_async then
        self.worker = {operation = item.operation, callback = item.callback, injected = true}
        local accepted, err = self.run_async(item.operation, function(result)
            if self.worker and self.worker.injected then self:_finish_worker(result) end
        end)
        if accepted then return end
        self.worker = nil
        self.queued_kinds[item.operation.kind] = nil
        if item.callback then item.callback({ok = false, error = tostring(err or "helper unavailable")}) end
        self:_start_next()
        return
    end
    local accepted, err = self:_run_helper(item.operation, item.callback)
    if accepted then return end
    self.queued_kinds[item.operation.kind] = nil
    if item.callback then item.callback({ok = false, error = tostring(err or "helper unavailable")}) end
    self:_start_next()
end

function PowerInhibit:_enqueue(operation, callback)
    if self.queued_kinds[operation.kind] then return false end
    self.queued_kinds[operation.kind] = true
    self.queue[#self.queue + 1] = {operation = operation, callback = callback}
    self:_start_next()
    return true
end

function PowerInhibit:_drop_queued()
    local running_kind = self.worker and self.worker.operation and self.worker.operation.kind
    self.queue = {}
    self.queued_kinds = {}
    if running_kind then self.queued_kinds[running_kind] = true end
end

function PowerInhibit:acquire()
    if self.desired_active then return true end
    self.desired_active = true
    self.active = true
    self.generation = self.generation + 1
    local generation = self.generation
    local share = self:_pluginshare()
    local marker = self:_marker()
    local pause_previous = marker and marker.pause_previous == true
        or (share and share.pause_auto_suspend == true or false)
    self.pause_previous = pause_previous
    if share then share.pause_auto_suspend = true end

    local function set_system_lock()
        self:_enqueue({kind = "set", value = 1}, function(result)
            if generation ~= self.generation then return end
            self.last_verify = self.now()
            if not result.ok then
                logger.warn("[撷思][PowerInhibit] acquire failed", tostring(result.error or ""))
            end
        end)
    end

    if marker then
        marker.token = self.token
        marker.updated_at = self.now()
        if not self.write_marker(self.marker_path, marker) then
            if share then share.pause_auto_suspend = pause_previous end
            self.active, self.desired_active = false, false
            logger.warn("[撷思][PowerInhibit] marker write failed")
            return false
        end
        if marker.system_previous ~= nil then set_system_lock() end
        return true
    end

    self:_enqueue({kind = "get"}, function(result)
        if generation ~= self.generation or not self.desired_active then
            if share then share.pause_auto_suspend = pause_previous end
            return
        end
        local saved = {
            system_previous = result.ok and tonumber(result.value) or nil,
            pause_previous = pause_previous,
            token = self.token,
            updated_at = self.now(),
        }
        if not self.write_marker(self.marker_path, saved) then
            if share then share.pause_auto_suspend = pause_previous end
            self.active, self.desired_active = false, false
            logger.warn("[撷思][PowerInhibit] marker write failed")
            return
        end
        if saved.system_previous ~= nil then
            set_system_lock()
        else
            logger.warn("[撷思][PowerInhibit] system value unavailable", tostring(result.error or ""))
        end
    end)
    return true
end

function PowerInhibit:verify(force)
    if not self.active or not self.desired_active or not self:owns_marker() then return false end
    local now = self.now()
    if not force and now - self.last_verify < VERIFY_INTERVAL then return true end
    local share = self:_pluginshare()
    if share then share.pause_auto_suspend = true end
    local queued = self:_enqueue({kind = "set", value = 1}, function(result)
        self.last_verify = self.now()
        if not result.ok then
            logger.warn("[撷思][PowerInhibit] verification failed", tostring(result.error or ""))
        end
    end)
    if queued then self.last_verify = now end
    return queued
end

function PowerInhibit:reset_timeout(force)
    if not self.active or not self.desired_active then return false end
    local now = self.now()
    if not force and now - self.last_t1 < VERIFY_INTERVAL then return true end
    local queued = self:_enqueue({kind = "t1"}, function(result)
        self.last_t1 = self.now()
        if not result.ok then
            logger.warn("[撷思][PowerInhibit] Kindle T1 reset failed", tostring(result.error or ""))
        end
    end)
    if queued then self.last_t1 = now end
    return queued
end

function PowerInhibit:_restore(marker, stale)
    local share = self:_pluginshare()
    if share then share.pause_auto_suspend = marker.pause_previous == true end
    if marker.system_previous == nil then
        local current = self:_marker()
        if current and tostring(current.token or "") == tostring(marker.token or "") then
            self.remove_marker(self.marker_path)
        end
        return true
    end
    local expected_token = tostring(marker.token or "")
    return self:_enqueue({kind = "restore", value = marker.system_previous}, function(result)
        local current = self:_marker()
        local unchanged = current and tostring(current.token or "") == expected_token
        if result.ok and unchanged then
            self.remove_marker(self.marker_path)
        elseif result.ok and current then
            self:_enqueue({kind = "set", value = 1}, function(repair)
                if not repair.ok then
                    logger.warn("[撷思][PowerInhibit] ownership repair failed", tostring(repair.error or ""))
                end
            end)
        end
        logger.info("[撷思][PowerInhibit] " .. (stale and "stale lock cleanup" or "released"),
            "restored=", tostring(result.ok == true), "detail=", tostring(result.error or ""))
    end)
end

function PowerInhibit:release()
    self.desired_active = false
    self.active = false
    self.generation = self.generation + 1
    local marker = self:_marker()
    if not marker then
        local share = self:_pluginshare()
        if share then share.pause_auto_suspend = self.pause_previous == true end
        self:_drop_queued()
        return true
    end
    if tostring(marker.token or "") ~= self.token then
        logger.info("[撷思][PowerInhibit] ownership transferred")
        return false
    end
    self:_drop_queued()
    return self:_restore(marker, false)
end

function PowerInhibit:clear_stale()
    local marker = self:_marker()
    if not marker then return true end
    self.desired_active = false
    self.active = false
    self.generation = self.generation + 1
    self:_drop_queued()
    return self:_restore(marker, true)
end

PowerInhibit.HELPER_TIMEOUT = HELPER_TIMEOUT
PowerInhibit.VERIFY_INTERVAL = VERIFY_INTERVAL

return PowerInhibit
