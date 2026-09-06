-- 想法评论查看:响应归一化 + 磁盘缓存(独立 SQLite,按本地书隔离)。
--
-- 数据流(Api → 本模块 → 弹窗)见 docs/implementation-thought-comments
-- 「新增评论归一化与 SQLite 磁盘缓存」:
--   * normalize_response():把 /web/review/single 的原始响应折叠成弹窗
--     可直接渲染的评论数组,失败时返回结构化错误,UI 层不接触原始响应。
--   * Cache:review_comments.db 每本本地书一个文件,不混 thoughts.db,
--     便于重置书籍时整文件删除;只在用户点击"查看评论"时打开、用完即关,
--     不保留常驻连接,内存中不留评论 LRU。
local Json = require("pickthought.json")
local logger = require("logger")
local Util = require("pickthought.util")

local M = {}

-- 默认 30 分钟;可选 0(关闭)/300/600/1800/3600 秒,非法值归一化为默认。
local DEFAULT_TTL = 1800
local VALID_TTL = { [0] = true, [300] = true, [600] = true, [1800] = true, [3600] = true }

-- 每本本地书的缓存上限(按 last_access_at 淘汰最旧)。
local DEFAULT_MAX_ITEMS = 128

M.DEFAULT_TTL_SECONDS = DEFAULT_TTL
M.DEFAULT_MAX_ITEMS = DEFAULT_MAX_ITEMS

-- 错误类别 → 用户文案(需求文档固定文案表)。
local MESSAGE = {
    invalid_review_id = "这条想法缺少评论 ID",
    not_logged_in = "登录已过期，请重新绑定微信读书",
    rate_limited = "请求频率受限，请稍后再试",
    network = "网络不可用或请求超时",
    invalid_response = "微信读书返回了无法识别的数据",
}

M.MESSAGE = MESSAGE

function M.message_for(error_kind)
    return MESSAGE[tostring(error_kind or "")] or MESSAGE.invalid_response
end

function M.normalize_ttl(value)
    value = tonumber(value)
    if value == nil then return DEFAULT_TTL end
    value = math.floor(value)
    if VALID_TTL[value] then return value end
    return DEFAULT_TTL
end

local function trim(value)
    if type(value) ~= "string" then return "" end
    return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- 评论元数据的 XText 安全过滤(真机 SIGBUS 取证:作者名含 emoji/韩文填充符
-- ㅤ/特殊空白,meta 块 shaping 走 emoji 回退字形,渲染原生崩溃)。
-- 按 UTF-8 序列过滤:完整 1-3 字节序列保留(中文/拉丁/常用符号),
-- 4 字节序列(emoji)与非法残尾丢弃,ASCII 控制字符剥除。
local function sanitize_meta(value)
    local text = tostring(value or "")
    local out = {}
    local pos = 1
    local n = #text
    while pos <= n do
        local b = string.byte(text, pos)
        if b < 128 then
            if b >= 32 and b ~= 127 then out[#out + 1] = text:sub(pos, pos) end
            pos = pos + 1
        elseif b >= 194 and b <= 223 and pos + 1 <= n then
            out[#out + 1] = text:sub(pos, pos + 1); pos = pos + 2
        elseif b >= 224 and b <= 239 and pos + 2 <= n then
            out[#out + 1] = text:sub(pos, pos + 2); pos = pos + 3
        else
            pos = pos + 4  -- 4 字节序列(emoji/符号扩展)或非法残尾:丢弃
        end
    end
    text = table.concat(out)
    text = text:gsub("%s+", " ")
    return trim(text)
end
M.sanitize_meta = sanitize_meta

-- 评论正文保留 emoji(正文 XText shaping 与想法一致,真机验证安全);
-- 只剥控制字符(保留换行),超长按字节截断并去掉 UTF-8 残尾。
local MAX_CONTENT_BYTES = 8000

local function sanitize_content(value)
    local text = tostring(value or "")
    text = text:gsub("[%z\1-\8\11-\12\14-\31]", "")
    if #text > MAX_CONTENT_BYTES then
        text = text:sub(1, MAX_CONTENT_BYTES)
        text = text:gsub("[\128-\191]+$", "")
    end
    return text
end

function extract_comment(entry)
    if type(entry) ~= "table" then return nil end
    local user = type(entry.user) == "table" and entry.user or {}
    local author_obj = type(entry.author) == "table" and entry.author or {}
    local author = sanitize_meta(user.name or user.nick or author_obj.name
        or author_obj.nick or user.nickname or entry.author
        or entry.name or entry.nickName or "")
    local content = sanitize_content(trim(tostring(entry.content or entry.text
        or entry.htmlContent or "")))
    if content == "" then return nil end
    return {
        author = author ~= "" and author or "微信读书用户",
        content = content,
        likes_count = tonumber(entry.likes or entry.likeCount or entry.likesCount) or 0,
        review_id = trim(tostring(entry.reviewId or entry.id or "")),
    }
end

-- 从响应的兼容位置提取评论数组:/web/review/single 把数组放在顶层 comments,
-- 兼容 review/data 包裹的历史形状。
local function extract_comments(data)
    if type(data.comments) == "table" then return data.comments end
    if type(data.review) == "table" and type(data.review.comments) == "table" then
        return data.review.comments
    end
    if type(data.data) == "table" then
        local inner = data.data
        if type(inner.comments) == "table" then return inner.comments end
        if type(inner.review) == "table" and type(inner.review.comments) == "table" then
            return inner.review.comments
        end
    end
    return nil
end

local function extract_total(data, items)
    local candidates = {
        data.commentsCount, data.total, data.totalCount,
        type(data.review) == "table" and data.review.commentsCount or nil,
        type(data.data) == "table" and data.data.commentsCount or nil,
    }
    for _, candidate in ipairs(candidates) do
        local value = tonumber(candidate)
        if value and value >= 0 then return value end
    end
    return #items
end

--- 归一化契约(实施文档 §3 + 2026-09-05 真机形状修正):
--- 成功 { ok=true, items, total_count, truncated }
--- 失败 { ok=false, error, message }
--- 真机实测两套合法形状:
---   * 有评论:顶层 comments + commentsCount(另含 hotComments)
---   * 无评论:顶层只有 review 详情,没有 comments 键 → 合法空评论
--- errCode 非 0(HTTP 200 业务错误,如 -2003 参数格式错误):
---   映射为 invalid_review_id 并透传 errMsg,不是登录失效。
function M.normalize_response(data, requested_review_id)
    if type(data) ~= "table" then
        return { ok = false, error = "invalid_response", message = MESSAGE.invalid_response }
    end
    if data.ok == false and type(data.error) == "string" then
        return {
            ok = false,
            error = data.error,
            message = M.message_for(data.error),
        }
    end
    local err_code = tonumber(data.errCode)
    if err_code ~= nil and err_code ~= 0 then
        return { ok = false, error = "invalid_review_id",
            message = tostring(data.errMsg or "") ~= ""
                and tostring(data.errMsg) or MESSAGE.invalid_review_id }
    end
    local raw = extract_comments(data)
    if raw == nil then
        if type(data.review) == "table" then
            return { ok = true, items = {}, total_count = 0, truncated = false,
                review_id = trim(tostring(requested_review_id or "")) }
        end
        return { ok = false, error = "invalid_response", message = MESSAGE.invalid_response }
    end
    local items = {}
    for _, entry in ipairs(raw) do
        local comment = extract_comment(entry)
        if comment then items[#items + 1] = comment end
    end
    local total = extract_total(data, items)
    return {
        ok = true,
        items = items,
        total_count = total,
        truncated = total > #items,
        review_id = trim(tostring(requested_review_id or "")),
    }
end

-- SQLite 句柄获取与 thought_db 同款:加载失败返回 nil,调用方按缓存不可用处理。
local function get_sq3()
    local ok, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if ok and SQ3 then return SQ3 end
    return nil
end

local function open_db(path)
    local SQ3 = get_sq3()
    if not SQ3 then return nil end
    local ok, db = pcall(SQ3.open, path)
    if not ok or not db then return nil end
    return db
end

local function close_db(db)
    if db then pcall(function() db:close() end) end
end

-- 缓存库损坏(打开/建表失败)时删除重建:缓存是可再生数据,允许直接删,
-- 不套 thought_db 的隔离流程(那里保护的是用户想法,这里只是副本)。
local function destroy_db_file(path)
    for _, suffix in ipairs({ "", "-wal", "-shm" }) do
        os.remove(path .. suffix)
    end
    logger.warn("[撷思][ReviewComments] 缓存库不可用,已删除重建:", path)
end

local function ensure_schema(db)
    local ok = pcall(function()
        db:exec([[CREATE TABLE IF NOT EXISTS review_comment_cache (
            review_id      TEXT PRIMARY KEY,
            book_id        TEXT NOT NULL,
            total_count    INTEGER NOT NULL,
            payload_json   TEXT NOT NULL,
            fetched_at     INTEGER NOT NULL,
            last_access_at INTEGER NOT NULL,
            expires_at     INTEGER NOT NULL
        )]])
    end)
    if not ok then return false end
    -- lua-ljsqlite3 的 exec 只取第一条语句,索引必须逐条执行。
    ok = pcall(function()
        db:exec([[CREATE INDEX IF NOT EXISTS idx_review_comment_cache_expires
            ON review_comment_cache(expires_at)]])
    end)
    if not ok then return false end
    ok = pcall(function()
        db:exec([[CREATE INDEX IF NOT EXISTS idx_review_comment_cache_access
            ON review_comment_cache(last_access_at)]])
    end)
    return ok
end

--- 磁盘缓存。一个实例绑定一本本地书的 review_comments.db。
--- opts = { path = "…/review_comments.db", max_items = 128 }
M.Cache = {}

local Cache = M.Cache

function Cache.new(opts)
    opts = type(opts) == "table" and opts or {}
    local self_obj = setmetatable({}, { __index = Cache })
    self_obj.path = tostring(opts.path or "")
    self_obj.max_items = math.max(1, tonumber(opts.max_items) or DEFAULT_MAX_ITEMS)
    return self_obj
end

-- 打开缓存库;失败时先删文件重建一次,仍失败则返回 nil(缓存不可用,不阻塞在线加载)。
function Cache:_open()
    if self.path == "" then return nil end
    local db = open_db(self.path)
    if db then
        if ensure_schema(db) then return db end
        close_db(db)
    end
    destroy_db_file(self.path)
    db = open_db(self.path)
    if not db then return nil end
    if not ensure_schema(db) then
        close_db(db)
        return nil
    end
    return db
end

local function query_error(stage, detail)
    return "评论缓存" .. tostring(stage) .. "失败: " .. tostring(detail or "未知错误")
end

--- 读取未过期缓存;命中后更新 last_access_at。
--- 返回 record = { items, total_count, fetched_at } 或 nil(未命中/过期/不可用)。
function Cache:get(review_id, now)
    review_id = trim(tostring(review_id or ""))
    now = tonumber(now) or os.time()
    if review_id == "" then return nil end
    local db = self:_open()
    if not db then return nil end
    local record
    local ok, err = pcall(function()
        local purge = db:prepare("DELETE FROM review_comment_cache WHERE expires_at <= ?")
        purge:reset():bind(now)
        purge:step()
        purge:close()

        local stmt = db:prepare([[SELECT total_count, payload_json, fetched_at
            FROM review_comment_cache WHERE review_id = ? AND expires_at > ?]])
        stmt:reset():bind(review_id, now)
        local row = stmt:step()
        if type(row) == "table" then
            local decoded = Json.decode(tostring(row[2] or ""))
            if type(decoded) == "table" then
                record = {
                    items = decoded,
                    total_count = tonumber(row[1]) or #decoded,
                    fetched_at = tonumber(row[3]) or now,
                }
                local touch = db:prepare(
                    "UPDATE review_comment_cache SET last_access_at = ? WHERE review_id = ?")
                touch:reset():bind(now, review_id)
                touch:step()
                touch:close()
            end
        end
        stmt:close()
    end)
    close_db(db)
    if not ok then
        logger.warn("[撷思][ReviewComments] 读取失败:", query_error("查询", err))
        return nil
    end
    return record
end

--- 写入缓存;超过 max_items 按 last_access_at 淘汰最旧。
function Cache:put(review_id, book_id, result, now, ttl)
    review_id = trim(tostring(review_id or ""))
    now = tonumber(now) or os.time()
    ttl = tonumber(ttl)
    if ttl == nil or ttl <= 0 then return false end
    if review_id == "" or type(result) ~= "table" or type(result.items) ~= "table" then
        return false
    end
    local db = self:_open()
    if not db then return false end
    local ok, err = pcall(function()
        local payload = Json.encode(result.items)
        local upsert = db:prepare([[INSERT INTO review_comment_cache
            (review_id, book_id, total_count, payload_json, fetched_at, last_access_at, expires_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(review_id) DO UPDATE SET
                book_id=excluded.book_id,
                total_count=excluded.total_count,
                payload_json=excluded.payload_json,
                fetched_at=excluded.fetched_at,
                last_access_at=excluded.last_access_at,
                expires_at=excluded.expires_at]])
        upsert:reset():bind(review_id, tostring(book_id or ""),
            tonumber(result.total_count) or #result.items, payload,
            now, now, now + ttl)
        upsert:step()
        upsert:close()

        local trim_sql = db:prepare([[DELETE FROM review_comment_cache WHERE review_id IN (
            SELECT review_id FROM review_comment_cache ORDER BY last_access_at DESC
            LIMIT -1 OFFSET ?)]])
        trim_sql:reset():bind(self.max_items)
        trim_sql:step()
        trim_sql:close()

        local purge = db:prepare("DELETE FROM review_comment_cache WHERE expires_at <= ?")
        purge:reset():bind(now)
        purge:step()
        purge:close()
    end)
    close_db(db)
    if not ok then
        logger.warn("[撷思][ReviewComments] 写入失败:", query_error("写入", err))
        return false
    end
    return true
end

--- 清空当前书缓存(用户把"评论缓存"设置为关闭时调用)。
function Cache:clear()
    local db = self:_open()
    if not db then return false end
    local ok, err = pcall(function()
        db:exec("DELETE FROM review_comment_cache")
    end)
    close_db(db)
    if not ok then
        logger.warn("[撷思][ReviewComments] 清空失败:", query_error("清空", err))
    end
    return ok == true
end

--- 惰性清理过期记录(打开缓存、查询前、写入后已顺带执行;
--- 书籍关闭/插件重置时由调用方主动触发)。
function Cache:purge_expired(now)
    now = tonumber(now) or os.time()
    local db = self:_open()
    if not db then return false end
    local ok, err = pcall(function()
        local stmt = db:prepare("DELETE FROM review_comment_cache WHERE expires_at <= ?")
        stmt:reset():bind(now)
        stmt:step()
        stmt:close()
    end)
    close_db(db)
    return ok == true
end

--- 读透:先查未过期缓存,未命中执行 loader(在线加载)并回写。
--- loader 返回 normalize_response 的结果形态;ttl<=0(关闭)时跳过读写。
function M.cache_get(cache, review_id, loader, book_id, now, ttl)
    review_id = trim(tostring(review_id or ""))
    now = tonumber(now) or os.time()
    ttl = tonumber(ttl)
    if ttl == nil or ttl < 0 then ttl = DEFAULT_TTL end
    if review_id == "" then
        return { ok = false, error = "invalid_review_id", message = MESSAGE.invalid_review_id }
    end
    if cache and ttl > 0 then
        local record = cache:get(review_id, now)
        if record then
            record.ok = true
            record.from_cache = true
            record.review_id = review_id
            return record
        end
    end
    local result = loader()
    if type(result) ~= "table" or not result.ok then
        -- 过期行已在 get 的懒清理中删除,刷新失败不降级展示旧评论。
        return result
    end
    if cache and ttl > 0 then
        cache:put(review_id, book_id, result, now, ttl)
    end
    return result
end

--- 批量读取想法的已知评论数(想法列表 meta 行"评论 N"展示用)。
--- 列表接口(/web/review/list 等)不携带评论数字段(真机 155KB 响应全字段
--- 核验),评论数只存在于单条详情 /web/review/single 的 commentsCount——
--- 因此这里只读"点开过"的想法留在缓存库里的 total_count:文件不存在/
--- 查询失败一律返回空表,绝不创建缓存文件;不看 expires_at,过期的评论数
--- 仍是可显示的提示,点开时会自动刷新。
function M.cached_total_counts(db_path, review_ids)
    local out = {}
    db_path = tostring(db_path or "")
    if db_path == "" or not Util.file_exists(db_path) then return out end
    local wanted = {}
    for _, id in ipairs(type(review_ids) == "table" and review_ids or {}) do
        id = trim(tostring(id or ""))
        if id ~= "" then wanted[id] = true end
    end
    if next(wanted) == nil then return out end
    local db = open_db(db_path)
    if not db then return out end
    local ok, err = pcall(function()
        local stmt = db:prepare(
            "SELECT review_id, total_count FROM review_comment_cache")
        while true do
            local row = stmt:step()
            if type(row) ~= "table" then break end
            local id = trim(tostring(row[1] or ""))
            if wanted[id] then out[id] = tonumber(row[2]) or 0 end
        end
        stmt:close()
    end)
    close_db(db)
    if not ok then
        logger.warn("[撷思][ReviewComments] 评论数读取失败:", query_error("查询", err))
        return {}
    end
    return out
end

return M
