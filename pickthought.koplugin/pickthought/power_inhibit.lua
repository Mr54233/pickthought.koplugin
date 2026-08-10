local Json = require("pickthought.json")
local U = require("pickthought.util")
local logger = require("logger")

local PowerInhibit = {}
PowerInhibit.__index = PowerInhibit

local SERVICE = "com.lab126.powerd"
local PROPERTY = "preventScreenSaver"

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

function PowerInhibit:new(opts)
    opts = opts or {}
    return setmetatable({
        device = opts.device,
        pluginshare = opts.pluginshare,
        marker_path = assert(opts.marker_path, "marker_path required"),
        token = tostring(opts.token or ""),
        now = opts.now or os.time,
        read_marker = opts.read_marker or default_read,
        write_marker = opts.write_marker or default_write,
        remove_marker = opts.remove_marker or os.remove,
        active = false,
        last_verify = 0,
    }, self)
end

function PowerInhibit:_pluginshare()
    if self.pluginshare then return self.pluginshare end
    local ok, value = pcall(require, "pluginshare")
    if ok then self.pluginshare = value end
    return ok and value or nil
end

function PowerInhibit:_lipc()
    local device = self.device
    local powerd = device and device.powerd
    local handle = powerd and powerd.lipc_handle
    if handle and type(handle.get_int_property) == "function"
        and type(handle.set_int_property) == "function" then
        return handle
    end
end

function PowerInhibit:_get_system_value()
    local handle = self:_lipc()
    if not handle then return nil, "unsupported" end
    local ok, value = pcall(handle.get_int_property, handle, SERVICE, PROPERTY)
    if not ok then return nil, tostring(value) end
    return tonumber(value)
end

function PowerInhibit:_set_system_value(value)
    local handle = self:_lipc()
    if not handle then return nil, "unsupported" end
    local ok, err = pcall(handle.set_int_property, handle, SERVICE, PROPERTY, tonumber(value) or 0)
    if not ok then return nil, tostring(err) end
    local actual, read_err = self:_get_system_value()
    if actual ~= tonumber(value) then
        return nil, read_err or ("readback=" .. tostring(actual))
    end
    return true
end

function PowerInhibit:_marker()
    return self.read_marker(self.marker_path)
end

function PowerInhibit:owns_marker()
    local marker = self:_marker()
    return marker and tostring(marker.token or "") == self.token or false
end

function PowerInhibit:acquire()
    local marker = self:_marker()
    local share = self:_pluginshare()
    if not marker then
        local previous = self:_get_system_value()
        marker = {
            system_previous = tonumber(previous),
            pause_previous = share and share.pause_auto_suspend == true or false,
        }
    end
    marker.token = self.token
    marker.updated_at = self.now()
    if share then share.pause_auto_suspend = true end

    if not self.write_marker(self.marker_path, marker) then
        logger.warn("[撷思][PowerInhibit] marker write failed")
        if share then share.pause_auto_suspend = marker.pause_previous == true end
        return false
    end
    local system_ok, system_err
    if marker.system_previous ~= nil then
        system_ok, system_err = self:_set_system_value(1)
    else
        system_err = "previous value unavailable"
    end
    self.active = true
    self.last_verify = self.now()
    logger.info("[撷思][PowerInhibit] acquired",
        "system_verified=", tostring(system_ok == true),
        "detail=", tostring(system_err or ""))
    return system_ok == true
end

function PowerInhibit:verify(force)
    if not self.active then return false end
    local marker = self:_marker()
    if not marker or tostring(marker.token or "") ~= self.token then return false end
    local now = self.now()
    if not force and now - self.last_verify < 60 then return true end
    local share = self:_pluginshare()
    if share then share.pause_auto_suspend = true end
    if marker.system_previous == nil then return false end
    local ok, err = self:_set_system_value(1)
    self.last_verify = now
    if not ok then
        logger.warn("[撷思][PowerInhibit] verification failed", tostring(err))
    end
    return ok == true
end

local function restore(self, marker)
    local share = self:_pluginshare()
    if share then share.pause_auto_suspend = marker.pause_previous == true end
    if marker.system_previous ~= nil then
        local ok, err = self:_set_system_value(marker.system_previous)
        if not ok then return nil, err end
    end
    self.remove_marker(self.marker_path)
    return true
end

function PowerInhibit:release()
    local marker = self:_marker()
    self.active = false
    if not marker then return true end
    if tostring(marker.token or "") ~= self.token then
        logger.info("[撷思][PowerInhibit] ownership transferred")
        return false
    end
    local ok, err = restore(self, marker)
    logger.info("[撷思][PowerInhibit] released",
        "restored=", tostring(ok == true), "detail=", tostring(err or ""))
    return ok == true
end

function PowerInhibit:clear_stale()
    local marker = self:_marker()
    if not marker then return true end
    local ok, err = restore(self, marker)
    logger.info("[撷思][PowerInhibit] stale lock cleanup",
        "restored=", tostring(ok == true), "detail=", tostring(err or ""))
    return ok == true
end

return PowerInhibit
