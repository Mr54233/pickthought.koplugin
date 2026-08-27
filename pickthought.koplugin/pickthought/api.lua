local Protocol = require("pickthought.protocol")
local U = require("pickthought.util")
local Http = require("pickthought.http")
local logger = require("logger")

local Api = {}
Api.__index = Api

local function scalar(value, depth, seen)
    local kind = type(value)
    if kind == "string" or kind == "number" or kind == "boolean" then return value end
    if kind ~= "table" or (depth or 0) > 4 then return nil end
    seen = seen or {}
    if seen[value] then return nil end
    seen[value] = true
    for _, key in ipairs({"chapterUid", "chapterId", "uid", "id", "value", "node"}) do
        local candidate = scalar(value[key], (depth or 0) + 1, seen)
        if candidate ~= nil then return candidate end
    end
end

local function sanitize(value, path, seen)
    local kind = type(value)
    path = path or "$"
    if kind == "nil" or kind == "string" or kind == "number" or kind == "boolean" then return value end
    if kind ~= "table" then error("unsupported parameter at " .. path .. ": " .. kind) end
    seen = seen or {}
    if seen[value] then error("cyclic parameter at " .. path) end
    seen[value] = true
    local out, max, count, array = {}, 0, 0, true
    for key in pairs(value) do
        count = count + 1
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then array = false else max = math.max(max, key) end
    end
    if array and max ~= count then array = false end
    if array then
        for i = 1, max do out[i] = sanitize(value[i], path .. "[" .. i .. "]", seen) end
    else
        for key, item in pairs(value) do
            if type(key) ~= "string" then error("non-string object key at " .. path) end
            local clean = sanitize(item, path .. "." .. key, seen)
            if clean ~= nil then out[key] = clean end
        end
    end
    seen[value] = nil
    return out
end

local function unwrap(data)
    local current = data
    for _ = 1, 4 do
        if type(current) ~= "table" then break end
        local candidate
        for _, key in ipairs({"data", "result", "payload"}) do
            if type(current[key]) == "table" then
                local only = true
                for k in pairs(current) do
                    if k ~= key and k ~= "errCode" and k ~= "errMsg" and k ~= "code" and k ~= "message" then only = false; break end
                end
                if only then candidate = current[key]; break end
            end
        end
        if not candidate then break end
        current = candidate
    end
    return current
end

local function unique_candidates(value)
    local raw = scalar(value)
    local out, seen = {}, {}
    local function add(v)
        if type(v) ~= "string" and type(v) ~= "number" then return end
        if type(v) == "string" and v == "" then return end
        local key = type(v) .. ":" .. tostring(v)
        if not seen[key] then seen[key] = true; out[#out + 1] = v end
    end
    -- 数字候选排最前:原版链路里 chapterUid 一路是数字,网关按数字实测过;
    -- 字符串候选只作兜底(候选间的自动重试只认 params error 文案)。
    local number = tonumber(raw)
    if number then add(number) end
    add(raw)
    if raw ~= nil then add(tostring(raw)) end
    return out
end

local WEB = "https://weread.qq.com"

function Api:new(http, store, reader)
    return setmetatable({http = http, store = store, reader = reader}, self)
end

-- 网关的 Bearer key 短时效且已对大部分端点 403;数据面全部走 web 端
-- (Cookie 鉴权)。登录态失效时用 wr_rt 续期一次(原 reader:renew 同款请求,
-- set-cookie 由 http 层自动写回 jar),再重试原请求。
function Api:renew_session()
    if self._renewing then return false, "登录状态正在续期" end
    self._renewing = true
    local ok, err = pcall(function()
        local data = self.http:post_json(WEB .. "/web/login/renewal", {rq="%2Fweb%2Fbook%2Fread", ql=false},
            {headers={Origin=WEB, Referer=WEB .. "/", Accept="application/json, text/plain, */*"}, retries=2})
        if type(data) ~= "table" then error("续期接口返回无效数据") end
    end)
    self._renewing = false
    if ok then
        logger.info("[撷思][Api] web session renewed")
        return true
    end
    return false, tostring(err)
end

function Api:_web_call(fn)
    local ok, result = pcall(fn)
    if ok then return result end
    if not Http.is_auth_error(result) then error(result) end
    local renewed, renew_err = self:renew_session()
    if not renewed then
        error(tostring(result) .. ";自动续期失败(" .. tostring(renew_err or "") .. "),请重新扫码登录")
    end
    return fn()
end

function Api:call(name, params, request_options)
    local payload = sanitize(U.copy(params or {}))
    payload.api_name = tostring(name)
    payload.skill_version = Protocol.SKILL_VERSION

    local function request_once()
        local auth = self.store:auth()
        if tostring(auth.api_key or "") == "" then error("API key is not configured") end
        local options = U.copy(request_options or {})
        options.auth = false
        options.headers = options.headers or {}
        options.headers.Authorization = "Bearer " .. tostring(auth.api_key)
        if options.retries == nil then options.retries = 2 end
        return self.http:post_json("https://i.weread.qq.com/api/agent/gateway", payload, options)
    end

    local ok, data = pcall(request_once)
    if not ok and Http.is_auth_error(data) and self.reader then
        local recovered, recover_error = self.reader:_recover_login_session()
        logger.warn("[撷思][API] authentication recovery",
            "api=", tostring(name), "ok=", tostring(recovered),
            "error=", recovered and "" or tostring(recover_error))
        if recovered then ok, data = pcall(request_once) end
    end
    if not ok then error(tostring(name) .. ": " .. tostring(data)) end
    return unwrap(data)
end

function Api:shelf(options)
    options=options or {}
    return self:call("/shelf/sync", {}, {
        retries=options.retries==nil and 1 or options.retries,
        timeout=options.timeout or {10,18},
    })
end
function Api:web_search(q, offset, count)
    local url = WEB .. "/web/search/global?keyword=" .. Protocol.escape(tostring(q or ""))
        .. "&maxIdx=" .. tostring(offset or 0) .. "&count=" .. tostring(count or 32) .. "&fragmentSize=120"
    return self:_web_call(function()
        return self.http:get_json(url, {retries=1, timeout={10, 18}, headers={Referer=WEB .. "/"}})
    end)
end

function Api:search(q, offset, count)
    local ok, data = pcall(function() return self:web_search(q, offset, count) end)
    if ok then return data end
    local fallback_ok, fallback = pcall(function()
        return self:call("/store/search", {keyword=tostring(q or ""), scope=10, maxIdx=offset or 0, count=count or 30}, {retries=1, timeout={10, 18}})
    end)
    if fallback_ok then return fallback end
    error(data)
end

-- 热门划线:chapterUid 参数不起过滤作用,整本一次拉回,调用方按章分组。
function Api:web_bestbookmarks(id)
    id = tostring(id or "")
    if id == "" then error("invalid book id") end
    return self:_web_call(function()
        return self.http:get_json(WEB .. "/web/book/bestbookmarks?bookId=" .. Protocol.escape(id)
            .. "&count=2000&synckey=0", {retries=2, headers={Referer=Protocol.reader_url(id)}})
    end)
end

-- 章节想法(公开热门,含 range/content/abstract/作者)。
function Api:web_chapter_reviews(id, uid)
    id = tostring(id or "")
    if id == "" then error("invalid book id") end
    return self:_web_call(function()
        return self.http:get_json(WEB .. "/web/review/list?bookId=" .. Protocol.escape(id)
            .. "&chapterUid=" .. Protocol.escape(uid)
            .. "&listType=8&maxIdx=0&count=100&listMode=3&synckey=0",
            {retries=2, headers={Referer=Protocol.reader_url(id)}})
    end)
end
function Api:book(id) return self:call("/book/info", {bookId=tostring(id)}) end

-- 章节列表走原版实测过的 web 端点(Cookie 鉴权,响应为
-- {bookId?, synckey?, chapters:[{chapterUid,title,chapterIdx,...}]}
-- 顶层 chapters 数组,注意不是 data);网关的 /book/chapterinfo 无历史消费者,
-- 真机返回 HTTP 403,仅保留为兜底。
function Api:web_chapters(id)
    id = tostring(id or "")
    if id == "" then error("invalid book id") end
    return self:_web_call(function()
        return self.http:post_json(WEB .. "/web/book/chapterInfos", {bookIds={id}}, {
            retries = 3,
            headers = {
                Origin = WEB,
                Referer = Protocol.reader_url(id),
            },
        })
    end)
end

function Api:chapters(id)
    local ok, data = pcall(function() return self:web_chapters(id) end)
    if ok then return data end
    local fallback_ok, fallback = pcall(function()
        return self:call("/book/chapterinfo", {bookId=tostring(id)})
    end)
    if fallback_ok then return fallback end
    error(data)
end
function Api:progress(id) return self:call("/book/getprogress", {bookId=tostring(id), _t=os.time()}) end
function Api:web_progress(id)
    id=tostring(id or "")
    if id=="" then error("invalid book id") end
    local url="https://weread.qq.com/web/book/getProgress?bookId="
        ..Protocol.escape(id).."&_="..tostring(os.time())..tostring(math.random(1000,9999))
    local data=self.http:get_json(url,{
        auth=true,retries=0,timeout={8,15},
        headers={
            Accept="application/json, text/plain, */*",
            Referer=Protocol.reader_url(id),
            ["Cache-Control"]="no-cache, no-store, max-age=0",
            Pragma="no-cache",
        },
    })
    if type(data)=="table" then
        data._progress_source="web_cookie"
        data._progress_fetched_at=os.time()
    end
    return data
end

local WEB_ANNOTATION_OPTIONS = {
    auth = true, retries = 1, timeout = {10, 18},
    pacing_scope = "annotations-web", min_interval = 0.45,
    pacing_jitter = 0.10, shared_pacing = true,
    rate_limit_scope = "annotations-web", rate_limit_fail_fast = true,
    rate_limit_cooldown = 300,
}

local AGENT_ANNOTATION_OPTIONS = {
    retries = 0, timeout = {10, 18},
    pacing_scope = "annotations-agent", min_interval = 4.25,
    pacing_jitter = 0.35, shared_pacing = true,
    rate_limit_scope = "annotations-agent", rate_limit_fail_fast = true,
    rate_limit_cooldown = 900,
}

-- 按书隔离限速/节流 scope(评审八轮 P1#2):基础 scope 固定为 annotations-web/
-- annotations-agent,但实际请求须把 book_id 并入 scope,使 A 书触发的 429 冷却锁
-- 只阻塞 A 书自身、不 fail-fast 掉 B 书的同接口请求(Http 层按 scope 生成独立
-- 锁文件 _rate_limit_path/_pacing_path)。基础表保持不变,仅此处构建含 book_id 的副本。
local function annotation_options_with_book(base, book_id)
    return {
        auth = base.auth,
        retries = base.retries,
        timeout = base.timeout,
        pacing_scope = base.pacing_scope .. "-" .. tostring(book_id or "global"),
        min_interval = base.min_interval,
        pacing_jitter = base.pacing_jitter,
        shared_pacing = base.shared_pacing,
        rate_limit_scope = base.rate_limit_scope .. "-" .. tostring(book_id or "global"),
        rate_limit_fail_fast = base.rate_limit_fail_fast,
        rate_limit_cooldown = base.rate_limit_cooldown,
    }
end

local function annotation_batch_error(value)
    local text = tostring(value or ""):lower()
    return text:find("params error", 1, true) ~= nil
        or text:find("invalid range", 1, true) ~= nil
        or text:find("invalid parameter", 1, true) ~= nil
        or text:find("range error", 1, true) ~= nil
end

local function annotation_headers(book_id, chapter_uid)
    return {
        Accept = "application/json, text/plain, */*",
        Origin = WEB,
        Referer = Protocol.reader_url(book_id, chapter_uid),
        ["Cache-Control"] = "no-cache, no-store, max-age=0",
        Pragma = "no-cache",
    }
end

function Api:_chapter_call(name, id, chapter_uid, extra, request_options)
    local last
    local candidates = unique_candidates(chapter_uid)
    if #candidates == 0 then error(name .. ": invalid chapterUid") end
    for _, uid in ipairs(candidates) do
        local payload = U.copy(extra or {})
        payload.bookId = tostring(id)
        payload.chapterUid = uid
        local ok, value = pcall(self.call, self, name, payload, request_options)
        if ok then return value end
        last = value
        if not tostring(value):lower():find("params error%(node%)") then error(value) end
    end
    error(last or (name .. ": params error(node)"))
end

function Api:underlines(id, chapter_uid)
    local ok, value = pcall(function()
        local last
        for _, uid in ipairs(unique_candidates(chapter_uid)) do
            local url = WEB .. "/web/book/underlines?bookId="
                .. Protocol.escape(tostring(id or ""))
                .. "&chapterUid=" .. Protocol.escape(uid)
            local call_ok, data = pcall(function()
                return self:_web_call(function()
                    return self.http:get_json(url, {
                        auth = true, retries = WEB_ANNOTATION_OPTIONS.retries,
                        timeout = WEB_ANNOTATION_OPTIONS.timeout,
                        pacing_scope = WEB_ANNOTATION_OPTIONS.pacing_scope .. "-" .. tostring(id),
                        min_interval = WEB_ANNOTATION_OPTIONS.min_interval,
                        pacing_jitter = WEB_ANNOTATION_OPTIONS.pacing_jitter,
                        shared_pacing = WEB_ANNOTATION_OPTIONS.shared_pacing,
                        rate_limit_scope = WEB_ANNOTATION_OPTIONS.rate_limit_scope .. "-" .. tostring(id),
                        rate_limit_fail_fast = WEB_ANNOTATION_OPTIONS.rate_limit_fail_fast,
                        rate_limit_cooldown = WEB_ANNOTATION_OPTIONS.rate_limit_cooldown,
                        headers = annotation_headers(id, uid),
                    })
                end)
            end)
            if call_ok and type(data) == "table" then return data end
            last = call_ok and "web underlines returned invalid data" or data
            if not annotation_batch_error(last) then error(last) end
        end
        error(last or "web underlines failed")
    end)
    if ok then
        value._annotation_source = "web"
        return value
    end
    logger.warn("[撷思][Api] web underlines unavailable; using Skill Gateway",
        "book=", tostring(id), "chapter=", tostring(chapter_uid), "error=", tostring(value))
    local result = self:_chapter_call("/book/underlines", id, chapter_uid, nil,
        annotation_options_with_book(AGENT_ANNOTATION_OPTIONS, id))
    if type(result) == "table" then result._annotation_source = "agent" end
    return result
end

function Api:review_batches(ranges, batch_size)
    local out = {}
    batch_size = tonumber(batch_size) or 5
    for first = 1, #(ranges or {}), batch_size do
        local batch = {}
        for i = first, math.min(first + batch_size - 1, #ranges) do
            local range = scalar(ranges[i]) or ranges[i]
            batch[#batch + 1] = {range=tostring(range or ""), maxIdx=0, count=30, synckey=0}
        end
        out[#out + 1] = batch
    end
    return out
end

function Api:readreviews(id, chapter_uid, batch)
    local payload_batch = sanitize(batch or {})
    local ok, value = pcall(function()
        local last
        for _, uid in ipairs(unique_candidates(chapter_uid)) do
            local call_ok, data = pcall(function()
                return self:_web_call(function()
                    return self.http:post_json(WEB .. "/web/book/readReviews", {
                        bookId = tostring(id or ""), chapterUid = uid, reviews = payload_batch,
                    }, {
                        auth = true, retries = WEB_ANNOTATION_OPTIONS.retries,
                        timeout = WEB_ANNOTATION_OPTIONS.timeout,
                        pacing_scope = WEB_ANNOTATION_OPTIONS.pacing_scope .. "-" .. tostring(id),
                        min_interval = WEB_ANNOTATION_OPTIONS.min_interval,
                        pacing_jitter = WEB_ANNOTATION_OPTIONS.pacing_jitter,
                        shared_pacing = WEB_ANNOTATION_OPTIONS.shared_pacing,
                        rate_limit_scope = WEB_ANNOTATION_OPTIONS.rate_limit_scope .. "-" .. tostring(id),
                        rate_limit_fail_fast = WEB_ANNOTATION_OPTIONS.rate_limit_fail_fast,
                        rate_limit_cooldown = WEB_ANNOTATION_OPTIONS.rate_limit_cooldown,
                        headers = annotation_headers(id, uid),
                    })
                end)
            end)
            if call_ok and type(data) == "table" then return data end
            last = call_ok and "web readReviews returned invalid data" or data
            if not annotation_batch_error(last) then error(last) end
        end
        error(last or "web readReviews failed")
    end)
    if ok then
        value._annotation_source = "web"
        return value
    end
    if annotation_batch_error(value) then error(value) end
    logger.warn("[撷思][Api] web readReviews unavailable; using Skill Gateway",
        "book=", tostring(id), "chapter=", tostring(chapter_uid),
        "ranges=", tostring(#payload_batch), "error=", tostring(value))
    local result = self:_chapter_call("/book/readreviews", id, chapter_uid,
        {reviews = payload_batch}, annotation_options_with_book(AGENT_ANNOTATION_OPTIONS, id))
    if type(result) == "table" then result._annotation_source = "agent" end
    return result
end

Api._scalar = scalar
Api._sanitize = sanitize
Api._unique_candidates = unique_candidates

return Api
