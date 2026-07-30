local Config = require("pickthought.config")
local logger = require("logger")

local MemoryMode = {}
MemoryMode.__index = MemoryMode

local SETTING_KEY = Config.LOW_MEMORY_SETTING or "DGLOBAL_CACHE_FREE_PROPORTION"
local TARGET_RATIO = tonumber(Config.LOW_MEMORY_RATIO) or 0.15
local EPSILON = 0.000001

local function same_ratio(left, right)
    left, right = tonumber(left), tonumber(right)
    return left ~= nil and right ~= nil and math.abs(left - right) <= EPSILON
end

local function object_method(object, name)
    local ok, method = pcall(function() return object[name] end)
    return ok and type(method) == "function" and method or nil
end

local function settings_object()
    local defaults = rawget(_G, "G_defaults")
    if defaults == nil then return nil, "当前 KOReader 不支持修改缓存设置" end
    if not object_method(defaults, "readSetting") or not object_method(defaults, "saveSetting") then
        return nil, "当前 KOReader 缺少缓存设置接口"
    end
    return defaults
end

local function read_setting()
    local defaults, error_message = settings_object()
    if not defaults then return nil, nil, error_message end
    local ok, value = pcall(object_method(defaults, "readSetting"), defaults, SETTING_KEY, nil)
    if not ok then return nil, nil, tostring(value) end
    return true, value
end

local function flush_settings(defaults)
    local flush = object_method(defaults, "flush")
    if flush then
        local ok, flush_error = pcall(flush, defaults)
        if not ok then return nil, tostring(flush_error) end
    end
    return true
end

local function write_setting(value, remove)
    local defaults, error_message = settings_object()
    if not defaults then return nil, error_message end

    local ok, write_error
    if remove then
        local delete_setting = object_method(defaults, "delSetting")
        if not delete_setting then return nil, "当前 KOReader 无法恢复未设置状态" end
        ok, write_error = pcall(delete_setting, defaults, SETTING_KEY)
    else
        ok, write_error = pcall(object_method(defaults, "saveSetting"), defaults, SETTING_KEY, value)
    end
    if not ok then return nil, tostring(write_error) end

    local flushed, flush_error = flush_settings(defaults)
    if not flushed then return nil, flush_error end

    local read_ok, current, read_error = read_setting()
    if not read_ok then return nil, read_error end
    if not remove and not same_ratio(current, value) then
        return nil, "缓存设置写入后未生效"
    end
    return true
end

function MemoryMode:new(store)
    return setmetatable({store=store}, self)
end

function MemoryMode:_state()
    local preferences = self.store:preferences()
    local state = type(preferences.memory_mode) == "table" and preferences.memory_mode or {}
    return {
        enabled=state.enabled==true,
        previous_known=state.previous_known==true,
        previous_ratio=state.previous_ratio,
    }, preferences
end

function MemoryMode:status()
    local state = self:_state()
    local ok, current, error_message = read_setting()
    if not ok then
        return {enabled=state.enabled, available=false, matches=false, error=error_message}
    end
    local matches=same_ratio(current,TARGET_RATIO)
    return {
        enabled=state.enabled,
        available=true,
        matches=matches,
        residual=state.enabled~=true and matches,
        previous_known=state.previous_known==true,
        previous_ratio=state.previous_ratio,
        current_ratio=tonumber(current),
        target_ratio=TARGET_RATIO,
    }
end

function MemoryMode:set_enabled(enabled)
    enabled = enabled == true
    local state, preferences = self:_state()
    if enabled == state.enabled then
        local status = self:status()
        if not enabled or status.matches then return true, {changed=false, status=status} end
    end

    local read_ok, current, read_error = read_setting()
    if not read_ok then return nil, read_error end

    if enabled then
        if same_ratio(current,TARGET_RATIO) and state.enabled~=true then
            return nil,"检测到外部或残留的低内存设置，请先恢复后再开启"
        end
        local previous_known = current ~= nil
        local previous_ratio = current
        local written, write_error = write_setting(TARGET_RATIO, false)
        if not written then return nil, write_error end

        preferences.memory_mode = {
            enabled=true,
            previous_known=previous_known,
            previous_ratio=previous_ratio,
        }
        local saved, save_error = pcall(self.store.save_preferences, self.store, preferences)
        if not saved then
            write_setting(previous_ratio, not previous_known)
            return nil, tostring(save_error)
        end
        logger.info("[撷思][MemoryMode] enabled", "ratio=", tostring(TARGET_RATIO))
        return true, {changed=true, enabled=true, target_ratio=TARGET_RATIO}
    end

    local external_change = not same_ratio(current, TARGET_RATIO)
    if not external_change then
        local restored, restore_error = write_setting(state.previous_ratio, not state.previous_known)
        if not restored then return nil, restore_error end
    end

    preferences.memory_mode = {
        enabled=false,
        previous_known=state.previous_known==true,
        previous_ratio=state.previous_ratio,
    }
    local saved, save_error = pcall(self.store.save_preferences, self.store, preferences)
    if not saved then
        if not external_change then write_setting(TARGET_RATIO, false) end
        return nil, tostring(save_error)
    end
    logger.info("[撷思][MemoryMode] disabled", "external_change=", tostring(external_change))
    return true, {changed=true, enabled=false, external_change=external_change}
end

function MemoryMode:restore_detected()
    local state,preferences=self:_state()
    if state.enabled then return self:set_enabled(false) end
    local read_ok,current,read_error=read_setting()
    if not read_ok then return nil,read_error end
    if not same_ratio(current,TARGET_RATIO) then
        return true,{changed=false,not_detected=true}
    end
    local restored,restore_error=write_setting(state.previous_ratio,not state.previous_known)
    if not restored then return nil,restore_error end
    preferences.memory_mode={
        enabled=false,
        previous_known=state.previous_known==true,
        previous_ratio=state.previous_ratio,
    }
    local saved,save_error=pcall(self.store.save_preferences,self.store,preferences)
    if not saved then
        write_setting(TARGET_RATIO,false)
        return nil,tostring(save_error)
    end
    logger.info("[撷思][MemoryMode] detected target restored",
        "previous_known=",tostring(state.previous_known==true))
    return true,{changed=true,enabled=false,detected=true,used_default=state.previous_known~=true}
end

MemoryMode.SETTING_KEY = SETTING_KEY
MemoryMode.TARGET_RATIO = TARGET_RATIO
MemoryMode._same_ratio = same_ratio

return MemoryMode
