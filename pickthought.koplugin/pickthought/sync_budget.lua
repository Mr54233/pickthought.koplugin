-- 同步批次的资源预算和轻量章节数据。
-- 完整想法正文只在当前章节的拉取/保存阶段存在;映射与注入只接收
-- range 存在性、首条摘要和实际想法数量,完整正文由 SQLite 提供。
local M = {}
M.__index = M

M.DEFAULTS = {
    -- 历史 200 章实测约 126876 条想法、12398 条划线;
    -- 预算应允许正常大批次,由实时内存负责最后一道保护。
    max_cache_bytes = 96 * 1024 * 1024,
    max_underlines = 20000,
    max_thought_entries = 150000,
    -- worker 已经 fork 后允许继续运行到 96MB;fork 前门槛仍由 SyncTask
    -- 独立保持 128MB,避免把 fork 的地址空间峰值和章节拉取混成一个值。
    min_available_kb = 96 * 1024,
}

local function scalar_bytes(value)
    local kind = type(value)
    if kind == "string" then return #value end
    if kind == "number" or kind == "boolean" then return 8 end
    return 0
end

local function non_empty(value)
    return tostring(value or ""):match("%S") ~= nil
end

local function copy_scalar_fields(row, keys)
    local out = {}
    for _, key in ipairs(keys) do
        local value = row[key]
        if type(value) == "string" or type(value) == "number" or type(value) == "boolean" then
            out[key] = value
        end
    end
    return out
end

local function compact_reviews(review_map)
    local compact, counts, ranges = {}, {}, {}
    local entries_total = 0
    for range, reviews in pairs(type(review_map) == "table" and review_map or {}) do
        if type(reviews) == "table" then
            local count, abstract = 0, nil
            for _, review in ipairs(reviews) do
                if type(review) == "table" then
                    count = count + 1
                    if not abstract then
                        local candidate = review.abstract or review.contextAbstract
                        if non_empty(candidate) then abstract = tostring(candidate) end
                    end
                end
            end
            if count > 0 then
                local key = tostring(range)
                compact[key] = {{abstract = abstract or ""}}
                counts[key] = count
                ranges[key] = true
                entries_total = entries_total + count
            end
        end
    end
    return compact, counts, ranges, entries_total
end

local function compact_underlines(underlines)
    local out = {}
    local keys = {"range", "markRange", "bookmarkRange", "markText", "bookmarkText",
        "rangeText", "text", "content", "abstract"}
    for _, row in ipairs(type(underlines) == "table" and underlines or {}) do
        if type(row) == "table" then
            out[#out + 1] = copy_scalar_fields(row, keys)
        end
    end
    return out
end

function M.compact(data)
    if type(data) ~= "table" then return nil end
    local review_map, thought_counts, thought_ranges, review_entries = compact_reviews(data.review_map)
    -- 续传读取的是已经压缩过的缓存;恢复每个 range 的真实想法数,不能把
    -- 每个 range 的摘要哨兵误当成一条想法。
    if type(data.thought_count_by_range) == "table" then
        thought_counts, thought_ranges, review_entries = {}, {}, 0
        for range, value in pairs(data.thought_count_by_range) do
            local count = tonumber(value) or 0
            if count > 0 then
                local key = tostring(range)
                thought_counts[key] = count
                thought_ranges[key] = true
                review_entries = review_entries + count
            end
        end
    end
    local thought_entry_count = tonumber(data.thought_entry_count)
        or tonumber(data.thought_count)
        or review_entries
    local thought_count = tonumber(data.thought_count)
    if not thought_count then
        thought_count = 0
        for _ in pairs(thought_ranges) do thought_count = thought_count + 1 end
    end
    return {
        book_id = data.book_id,
        chapter_uid = data.chapter_uid,
        underlines = compact_underlines(data.underlines),
        review_map = review_map,
        thought_count_by_range = thought_counts,
        thought_ranges = thought_ranges,
        underline_count = tonumber(data.underline_count) or #(data.underlines or {}),
        thought_count = thought_count,
        thought_entry_count = thought_entry_count,
        errors = type(data.errors) == "table" and data.errors or {},
        underline_request_ok = data.underline_request_ok,
        resumed = data.resumed,
        deferred = data.deferred,
        rate_limited = data.rate_limited,
        rate_limit_wait = data.rate_limit_wait,
        cache_bytes = tonumber(data.cache_bytes),
    }
end

function M.estimate_bytes(data)
    if type(data) ~= "table" then return 0 end
    -- cache_bytes 是压缩后落盘 JSON 的大小,不能代表拉取阶段的运行时对象;
    -- 预算必须根据完整 review_map/review_groups 估算,否则大批次会被严重低估。
    local total = 256
    for _, row in ipairs(data.underlines or {}) do
        if type(row) == "table" then
            for _, key in ipairs({"range", "markText", "bookmarkText", "rangeText", "text", "content", "abstract"}) do
                total = total + scalar_bytes(row[key]) + 8
            end
        end
    end
    for range, reviews in pairs(data.review_map or {}) do
        total = total + scalar_bytes(range) + 16
        for _, review in ipairs(reviews or {}) do
            if type(review) == "table" then
                for _, key in ipairs({"content", "abstract", "contextAbstract", "author", "likes", "created", "review_id"}) do
                    total = total + scalar_bytes(review[key]) + 8
                end
            end
        end
    end
    for _, group in ipairs(data.review_groups or {}) do
        total = total + 32
        for _, review in ipairs(type(group) == "table" and group.texts or {}) do
            if type(review) == "table" then
                for key, value in pairs(review) do
                    total = total + scalar_bytes(key) + scalar_bytes(value) + 8
                end
            end
        end
    end
    return total
end

function M:new(opts)
    opts = opts or {}
    local function positive(value, fallback)
        value = tonumber(value)
        return value and value > 0 and value or fallback
    end
    return setmetatable({
        max_cache_bytes = positive(opts.max_cache_bytes, M.DEFAULTS.max_cache_bytes),
        max_underlines = positive(opts.max_underlines, M.DEFAULTS.max_underlines),
        max_thought_entries = positive(opts.max_thought_entries, M.DEFAULTS.max_thought_entries),
        min_available_kb = positive(opts.min_available_kb, M.DEFAULTS.min_available_kb),
        read_memory_available_kb = opts.read_memory_available_kb,
        cache_bytes = 0,
        underlines = 0,
        thought_entries = 0,
        chapters = 0,
        min_observed_available_kb = nil,
        stop_reason = nil,
    }, M)
end

function M:can_fetch()
    local available
    if type(self.read_memory_available_kb) == "function" then
        local ok, value = pcall(self.read_memory_available_kb)
        if ok then available = tonumber(value) end
        if available then
            self.min_observed_available_kb = math.min(self.min_observed_available_kb or available, available)
        end
    end
    local reason
    -- 内存是硬安全门槛,优先于数量预算报告;否则内存已经越线时仍会被
    -- 误报成“想法数量达到预算”。
    if available and available < self.min_available_kb then
        reason = string.format("设备可用内存低于安全线(%dMB)", math.floor(self.min_available_kb / 1024))
    elseif self.chapters > 0 and self.cache_bytes >= self.max_cache_bytes then
        reason = "本批缓存数据已达到预算"
    elseif self.chapters > 0 and self.underlines >= self.max_underlines then
        reason = "本批划线数量已达到预算"
    elseif self.chapters > 0 and self.thought_entries >= self.max_thought_entries then
        reason = "本批想法数量已达到预算"
    end
    self.stop_reason = reason
    return reason == nil, reason, available
end

function M:account(data)
    if type(data) ~= "table" then return end
    self.chapters = self.chapters + 1
    self.cache_bytes = self.cache_bytes + M.estimate_bytes(data)
    self.underlines = self.underlines + (tonumber(data.underline_count) or #(data.underlines or {}))
    self.thought_entries = self.thought_entries + (tonumber(data.thought_entry_count)
        or tonumber(data.thought_count) or 0)
end

function M:summary()
    return {
        cache_bytes = self.cache_bytes,
        underlines = self.underlines,
        thought_entries = self.thought_entries,
        chapters = self.chapters,
        min_available_kb = self.min_observed_available_kb,
        stop_reason = self.stop_reason,
        max_cache_bytes = self.max_cache_bytes,
        max_underlines = self.max_underlines,
        max_thought_entries = self.max_thought_entries,
        min_memory_kb = self.min_available_kb,
    }
end

return M
