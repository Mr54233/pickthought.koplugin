local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local ok_http, http = pcall(require, "socket.http")
local ok_https, https = pcall(require, "ssl.https")
local ok_socket, socket = pcall(require, "socket")
local lfs = require("libs/libkoreader-lfs")
local Json = require("pickthought.json")
local Cookies = require("pickthought.cookies")
local Protocol = require("pickthought.protocol")
local Util = require("pickthought.util")
local logger = require("logger")

local Http = {}
Http.__index = Http

local function hget(headers, name)
    local target = tostring(name):lower()
    for k, v in pairs(headers or {}) do
        if type(k) == "string" and k:lower() == target then return v end
    end
end

local function is_weread_url(url)
    local host = tostring(url or ""):match("^https?://([^/]+)")
    if not host then return false end
    host = host:lower():gsub(":%d+$", "")
    return host == "weread.qq.com" or host:sub(-#".weread.qq.com") == ".weread.qq.com"
end

local function absolute(base, loc)
    loc = tostring(loc or "")
    if loc:match("^https?://") then return loc end
    local scheme, host = tostring(base):match("^(https?)://([^/]+)")
    if not scheme then return loc end
    if loc:sub(1, 1) == "/" then return scheme .. "://" .. host .. loc end
    local dir = tostring(base):match("^(https?://.*/)") or (scheme .. "://" .. host .. "/")
    return dir .. loc
end

local function transient_status(code)
    code = tonumber(code)
    return code == 408 or code == 425 or code == 429 or code == 500
        or code == 502 or code == 503 or code == 504
end

local RATE_LIMIT_MARKER = "[撷思RateLimit]"

local function body_rate_limit_code(text)
    text = tostring(text or "")
    if text == "" then return nil end
    local lower = text:lower()
    local looks_limited = text:find("-2014", 1, true)
        or text:find("请求频率超限", 1, true)
        or lower:find("rate limit", 1, true)
        or lower:find("too many requests", 1, true)
    if not looks_limited then return nil end
    local decoded, data = pcall(Json.decode, text)
    if decoded and type(data) == "table" then
        local code = data.errCode or data.errcode or data.code
        local message = tostring(data.errMsg or data.errmsg or data.message or data.msg or "")
        local message_lower = message:lower()
        if tonumber(code) == -2014 or tonumber(code) == 429 or tonumber(code) == 499
            or message:find("请求频率超限", 1, true)
            or message_lower:find("rate limit", 1, true)
            or message_lower:find("too many requests", 1, true) then
            return tostring(code or "response")
        end
        return nil
    end
    return "response"
end

local function rate_limit_message(code, wait, active)
    local prefix = active and "请求频率仍受限" or "请求频率暂时受限"
    return prefix .. " " .. RATE_LIMIT_MARKER
        .. " error_code=" .. tostring(code or "unknown")
        .. " wait_seconds=" .. tostring(math.max(1, math.ceil(tonumber(wait) or 1)))
        .. ": 已停止继续请求,同步断点会保留,请稍后重试。"
end

local function rate_limit_wait(value)
    return tonumber(tostring(value or ""):match("%[撷思RateLimit%].-wait_seconds=(%d+)"))
end

local function pause(seconds)
    if ok_socket and socket and type(socket.sleep) == "function" then
        socket.sleep(seconds)
    end
end

local function clock_now()
    if ok_socket and socket and type(socket.gettime) == "function" then
        return socket.gettime()
    end
    return os.time()
end

function Http:new(store)
    local data_dir = store and tostring(store.data_dir or "") or ""
    return setmetatable({
        store = store, user_agent = Protocol.USER_AGENT,
        last_weread_request_at_by_scope = {},
        shared_pacing_path = data_dir ~= "" and (data_dir .. "/weread-pacing.json") or nil,
        shared_rate_limit_path = data_dir ~= "" and (data_dir .. "/weread-rate-limit.json") or nil,
    }, self)
end

function Http:_pacing_path(scope)
    local path = tostring(self.shared_pacing_path or "")
    if path == "" then return "" end
    scope = tostring(scope or "global"):gsub("[^%w%-_]", "-")
    if scope == "" or scope == "global" then return path end
    return path:gsub("%.json$", "") .. "-" .. scope .. ".json"
end

function Http:_rate_limit_path(scope)
    local path = tostring(self.shared_rate_limit_path or "")
    if path == "" then return "" end
    scope = tostring(scope or "global"):gsub("[^%w%-_]", "-")
    if scope == "" or scope == "global" then return path end
    return path:gsub("%.json$", "") .. "-" .. scope .. ".json"
end

local function release_state_lock(path)
    if type(lfs.rmdir) == "function" then pcall(lfs.rmdir, path) end
end

local function state_lock_stale(path)
    if type(lfs.attributes) ~= "function" then return false end
    local ok, modified = pcall(lfs.attributes, path, "modification")
    return ok and tonumber(modified) and os.time() - tonumber(modified) > 10
end

local function acquire_state_lock(path)
    if type(lfs.mkdir) ~= "function" then return false end
    local deadline = clock_now() + 2
    while clock_now() < deadline do
        if lfs.mkdir(path) == true then return true end
        if state_lock_stale(path) then release_state_lock(path) end
        pause(0.04)
    end
    return false
end

function Http:_reserve_shared_pacing(scope, interval, jitter)
    local path = self:_pacing_path(scope)
    interval = math.max(0, tonumber(interval) or 0)
    jitter = math.max(0, tonumber(jitter) or 0)
    if path == "" or interval <= 0 then return 0 end

    local lock_path = path .. ".lock"
    if not acquire_state_lock(lock_path) then return 0 end
    local ok, wait = pcall(function()
        local now = clock_now()
        local next_at = 0
        local raw = Util.read_file(path, true)
        if raw then
            local decoded, state = pcall(Json.decode, raw)
            if decoded and type(state) == "table" then next_at = tonumber(state.next_at) or 0 end
        end
        if next_at < now - interval or next_at > now + 120 then next_at = now end
        local scheduled = math.max(now, next_at)
        local extra = jitter > 0 and math.random() * jitter or 0
        local wrote, err = Util.atomic_write(path, Json.encode({
            next_at = scheduled + interval + extra,
            scope = tostring(scope or "global"), updated_at = os.time(),
        }), true)
        if not wrote then
            logger.warn("[撷思][HTTP] shared pacing state write failed", tostring(err))
            return 0
        end
        return math.max(0, scheduled - now)
    end)
    release_state_lock(lock_path)
    if not ok then
        logger.warn("[撷思][HTTP] shared pacing reservation failed", tostring(wait))
        return 0
    end
    return tonumber(wait) or 0
end

function Http:_shared_rate_limit(scope)
    local path = self:_rate_limit_path(scope)
    if path == "" then return 0 end
    local raw = Util.read_file(path, true)
    if not raw then return 0 end
    local decoded, state = pcall(Json.decode, raw)
    local until_at = decoded and type(state) == "table" and tonumber(state.until_at) or nil
    if not until_at then
        pcall(os.remove, path)
        return 0
    end
    local remaining = math.ceil(until_at - os.time())
    if remaining <= 0 then
        pcall(os.remove, path)
        return 0
    end
    return remaining, state
end

function Http:_set_shared_rate_limit(seconds, code, url, scope)
    local path = self:_rate_limit_path(scope)
    seconds = math.max(30, math.min(1800, tonumber(seconds) or 300))
    if path == "" then return seconds end

    local lock_path = path .. ".lock"
    if not acquire_state_lock(lock_path) then
        logger.warn("[撷思][HTTP] shared rate-limit lock unavailable", "scope=", tostring(scope))
        return seconds
    end
    local ok, wait = pcall(function()
        local now = os.time()
        local until_at = now + seconds
        local raw = Util.read_file(path, true)
        if raw then
            local decoded, state = pcall(Json.decode, raw)
            if decoded and type(state) == "table" then
                until_at = math.max(until_at, tonumber(state.until_at) or 0)
            end
        end
        local source = tostring(url or ""):gsub("%?.*$", "")
        local wrote, err = Util.atomic_write(path, Json.encode({
            until_at = until_at, code = tostring(code or "unknown"), source = source,
            scope = tostring(scope or "global"), updated_at = now,
        }), true)
        if not wrote then error(err or "state write failed") end
        return math.max(1, math.ceil(until_at - now))
    end)
    release_state_lock(lock_path)
    if not ok then
        logger.warn("[撷思][HTTP] shared rate-limit state write failed", tostring(wait))
        return seconds
    end
    return tonumber(wait) or seconds
end

function Http:_pace(url, opt)
    opt = opt or {}
    if not is_weread_url(url) or opt.pacing == false then return end
    local scope = tostring(opt.pacing_scope or opt.rate_limit_scope or "global")
    local interval = tonumber(opt.min_interval) or 0
    local jitter = tonumber(opt.pacing_jitter) or 0
    if interval <= 0 and jitter <= 0 then return end
    local now = clock_now()
    local last = tonumber((self.last_weread_request_at_by_scope or {})[scope]) or 0
    local wait = math.max(0, interval - (now - last))
    if wait > 0 then pause(wait) end
    if opt.shared_pacing == true then
        local shared_wait = self:_reserve_shared_pacing(scope, interval, jitter)
        if shared_wait > 0 then pause(shared_wait) end
    elseif jitter > 0 then
        pause(math.random() * jitter)
    end
    local requested_at = clock_now()
    self.last_weread_request_at_by_scope = self.last_weread_request_at_by_scope or {}
    self.last_weread_request_at_by_scope[scope] = requested_at
end

function Http:_jar()
    local auth = self.store:auth()
    local original = auth.cookies or {}
    local jar, changed = Cookies.sanitize(original)
    if changed then
        auth.cookies = jar
        self.store:save_auth(auth)
        logger.info("[撷思][HTTP] removed temporary cookies from saved login",
            "names=", table.concat(Cookies.names(jar), ","))
    end
    return jar
end

function Http:_save_jar(jar)
    local auth = self.store:auth()
    local cleaned = Cookies.sanitize(jar or {})
    if not Cookies.same(auth.cookies or {}, cleaned) then
        auth.cookies = cleaned
        self.store:save_auth(auth)
    end
end

function Http:_request_once(opt)
    local redirects = tonumber(opt.redirects) or 5
    local current = assert(opt.url, "url required")
    local method = opt.method or (opt.body and "POST" or "GET")
    local body = opt.body
    local jar = self:_jar()
    local headers = {}
    for k, v in pairs(opt.headers or {}) do headers[k] = v end
    headers["User-Agent"] = headers["User-Agent"] or self.user_agent
    headers["Accept"] = headers["Accept"] or "*/*"
    if opt.auth ~= false and is_weread_url(current) then
        local cookie = Cookies.header(jar)
        if cookie ~= "" then headers["Cookie"] = cookie end
    end
    if body then
        headers["Content-Length"] = tostring(#body)
        headers["Content-Type"] = headers["Content-Type"] or "application/json;charset=UTF-8"
    end

    for hop = 0, redirects do
        local chunks = {}
        socketutil:set_timeout((opt.timeout and opt.timeout[1]) or 15, (opt.timeout and opt.timeout[2]) or 35)
        local transport
        if current:match("^https:") then
            transport = ok_https and https or (ok_http and http or nil)
        else
            transport = ok_http and http or nil
        end
        if not transport or type(transport.request) ~= "function" then
            socketutil:reset_timeout()
            return nil, nil, nil, current, "HTTP transport unavailable"
        end
        local called, ok, code, resp_headers, status = pcall(transport.request, {
            url = current,
            method = method,
            headers = headers,
            source = body and ltn12.source.string(body) or nil,
            sink = ltn12.sink.table(chunks),
        })
        socketutil:reset_timeout()
        if not called then return nil, nil, nil, current, tostring(ok) end
        local text = table.concat(chunks)
        code = tonumber(code)
        if not code then return text, nil, resp_headers, current, tostring(status or ok) end

        local set_cookie = hget(resp_headers, "set-cookie")
        if set_cookie and opt.auth ~= false then
            local before = Cookies.sanitize(jar)
            jar = Cookies.absorb(jar, set_cookie, {protect_core=true})
            if not Cookies.same(before, jar) then self:_save_jar(jar) end
            headers["Cookie"] = Cookies.header(jar)
        end

        local location = hget(resp_headers, "location")
        if code >= 300 and code < 400 and location and hop < redirects then
            current = absolute(current, location)
            if opt.auth ~= false and is_weread_url(current) then
                local cookie = Cookies.header(jar)
                headers["Cookie"] = cookie ~= "" and cookie or nil
            else
                headers["Cookie"] = nil
            end
            if code == 303 then
                method, body = "GET", nil
                headers["Content-Length"] = nil
            end
        else
            return text, code, resp_headers, current
        end
    end
    return nil, nil, nil, current, "too many redirects"
end

function Http:request(opt)
    opt = opt or {}
    local retries = tonumber(opt.retries)
    if retries == nil then retries = 2 end
    retries = math.max(0, math.min(5, retries))
    local rate_limit_scope = tostring(opt.rate_limit_scope or "")
    local rate_limit_enabled = rate_limit_scope ~= "" and is_weread_url(opt.url)
    if rate_limit_enabled then
        local remaining, state = self:_shared_rate_limit(rate_limit_scope)
        if remaining > 0 then
            if opt.rate_limit_fail_fast == true then
                error(rate_limit_message(state and state.code, remaining, true))
            end
            pause(remaining)
        end
    end
    local last_text, last_code, last_headers, last_url, last_error

    for attempt = 1, retries + 1 do
        self:_pace(opt.url, opt)
        local text, code, headers, url, err = self:_request_once(opt)
        last_text, last_code, last_headers, last_url, last_error = text, code, headers, url, err
        if rate_limit_enabled then
            local limited_code
            if tonumber(code) == 429 or tonumber(code) == 499 then
                limited_code = tostring(code)
            else
                limited_code = body_rate_limit_code(text)
            end
            if limited_code then
                local retry_after_value = hget(headers, "retry-after")
                local retry_after = retry_after_value and tonumber(retry_after_value) or nil
                local cooldown = tonumber(opt.rate_limit_cooldown) or 300
                if retry_after then cooldown = math.max(cooldown, retry_after) end
                local wait = self:_set_shared_rate_limit(cooldown, limited_code,
                    url or opt.url, rate_limit_scope)
                error(rate_limit_message(limited_code, wait, false))
            end
        end
        if code and not transient_status(code) then return text, code, headers, url end
        if code and transient_status(code) and attempt > retries then return text, code, headers, url end
        if not code and attempt > retries then
            error("network request failed: " .. tostring(err or "unknown"))
        end
        logger.warn("[撷思][HTTP] retry", "attempt=", tostring(attempt), "url=", tostring(url or opt.url),
            "status=", tostring(code or err or "network"))
        pause(math.min(2.5, 0.35 * (2 ^ (attempt - 1))))
    end
    if last_code then return last_text, last_code, last_headers, last_url end
    error("network request failed: " .. tostring(last_error or "unknown"))
end

local AUTH_ERROR_MARKER = "[撷思Auth]"

local function auth_error_message(code, message)
    local suffix = tostring(message or ""):gsub("[%c]+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    local out = "登录状态已失效 " .. AUTH_ERROR_MARKER .. " error_code=" .. tostring(code or "unknown")
    if suffix ~= "" then out = out .. ": " .. suffix end
    return out
end

local function service_error(data, url)
    local code = data.errCode or data.errcode or data.code
    local message = tostring(data.errMsg or data.errmsg or data.message or data.msg or code or "")
    local lower = message:lower()
    if tonumber(code) == -2012 or lower:find("login timeout", 1, true)
        or message:find("登录超时", 1, true) then
        -- -2012 means the current web session can no longer be used. It does
        -- not prove that another device replaced this one, so keep the real
        -- code and let the caller attempt one controlled cookie renewal.
        return auth_error_message(code or -2012, message)
    end
    if is_weread_url(url) and (message == "用户不存在" or lower == "user not found") then
        return auth_error_message(code or "user_not_found", message)
    end
    return message
end

local function auth_error_code(value)
    local text = tostring(value or "")
    return text:match("%[撷思Auth%]%s+error_code=([^:%s]+)")
        or text:match("error_code=([%-]?%d+)")
end

local function is_auth_error(value)
    local text = tostring(value or "")
    local lower = text:lower()
    return text:find(AUTH_ERROR_MARKER, 1, true) ~= nil
        or tonumber(auth_error_code(text)) == -2012
        or lower:find("http 401", 1, true) ~= nil
        or lower:find("http 403", 1, true) ~= nil
        or lower:find("login expired", 1, true) ~= nil
        or lower:find("login timeout", 1, true) ~= nil
        or lower:find("session expired", 1, true) ~= nil
        or lower:find("not logged", 1, true) ~= nil
        or lower:find("api key is not configured", 1, true) ~= nil
        or text:find("未登录", 1, true) ~= nil
        or text:find("登录过期", 1, true) ~= nil
        or text:find("登录授权已过期", 1, true) ~= nil
        or text:find("重新登录", 1, true) ~= nil
        or text:find("登录超时", 1, true) ~= nil
        or text:find("登录失效", 1, true) ~= nil
        or text:find("登录状态已失效", 1, true) ~= nil
end

local function is_rate_limit_error(value)
    local text = tostring(value or "")
    local lower = text:lower()
    return text:find(RATE_LIMIT_MARKER, 1, true) ~= nil
        or lower:find("http 429", 1, true) ~= nil
        or lower:find("http 499", 1, true) ~= nil
        or text:find("请求频率超限", 1, true) ~= nil
        or text:find("-2014", 1, true) ~= nil
        or lower:find("rate limit", 1, true) ~= nil
end

function Http:json(opt)
    local text, code, headers, url = self:request(opt)
    text = text or ""
    if not code or code < 200 or code >= 300 then
        local content_type = hget(headers, "content-type") or "unknown"
        local preview = Util.first_line(text, 180)
        local message = "HTTP " .. tostring(code or "nil")
            .. ", content_type=" .. tostring(content_type)
            .. ", body_bytes=" .. tostring(#text)
        if preview ~= "" then message = message .. ": " .. preview end
        error(message)
    end
    local ok, data = pcall(Json.decode, text)
    if not ok then error("invalid JSON from " .. tostring(url) .. ": " .. Util.first_line(text, 180)) end
    if type(data) == "table" then
        local ec = data.errCode or data.errcode
        if ec == nil and tonumber(data.code) and tonumber(data.code) < 0 then ec = data.code end
        if ec and tonumber(ec) ~= 0 then error(service_error(data, url)) end
    end
    local meta = {
        code = code,
        length = #(text or ""),
        content_type = hget(headers, "content-type"),
        url = url,
        preview = Util.first_line(text, 180),
    }
    return data, headers, meta
end

function Http:get_json(url, opt)
    opt = opt or {}; opt.url = url; opt.method = "GET"; return self:json(opt)
end

function Http:post_json(url, value, opt)
    opt = opt or {}; opt.url = url; opt.method = "POST"; opt.body = Json.encode(value); return self:json(opt)
end

function Http:download(url, opt)
    opt = opt or {}; opt.url = url; opt.method = opt.method or "GET"
    if opt.retries == nil then opt.retries = 3 end
    local body, code, headers, final = self:request(opt)
    if code < 200 or code >= 300 then error("download HTTP " .. tostring(code)) end
    return body, headers, final
end

Http.auth_error_code = auth_error_code
Http.auth_error_message = auth_error_message
Http.is_auth_error = is_auth_error
Http.is_rate_limit_error = is_rate_limit_error
Http.rate_limit_wait = rate_limit_wait

-- 区分网络错误(连接/超时)与鉴权错误——同步失败时告诉用户是"网络问题"还是"登录问题"。
local function is_network_error(value)
    local text = tostring(value or "")
    local lower = text:lower()
    return lower:find("network request failed", 1, true) ~= nil
        or lower:find("http nil", 1, true) ~= nil
        or lower:find("status=nil", 1, true) ~= nil
        or lower:find("connection", 1, true) ~= nil
        or lower:find("broken pipe", 1, true) ~= nil
        or lower:find("timed out", 1, true) ~= nil
        or lower:find("timeout", 1, true) ~= nil
        or text:find("网络不可用", 1, true) ~= nil
        or text:find("网络请求失败", 1, true) ~= nil
end
Http.is_network_error = is_network_error

return Http
