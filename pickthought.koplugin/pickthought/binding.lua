-- 本地书 ↔ 微信读书书目的绑定:搜索/章节响应规范化 + 按文档路径持久化。
--
-- 绑定模型(2026-08 起支持「一本本地书绑定多本微信读书书」,用于合集/套装 EPUB):
--   all[doc_path] 是一个 map:{ [book_id] = {book_id, title, author, bound_at, bound_order} }
-- 旧版本是单条记录(all[doc_path] = record),读取时自动迁移为单元素 map 并落盘。
-- 对外保持向后兼容:Binding.get 仍返回「主绑定」(最近绑定的一本)单记录,
-- 因此单绑定场景与旧代码、旧测试行为完全一致。
--
-- store 只需 get(k, default) / set(k, v) 两个方法。
local Binding = {}

local KEY = "bindings"

local function is_record(v)
    return type(v) == "table" and type(v.book_id) == "string" and v.book_id ~= ""
end

-- ffi/util 提供秒+微秒;没有 KOReader 运行时(桌面测试/旧环境)时回退到 os.time。
-- bound_order 仍作为同一时刻的持久化并列裁决,避免 map 的 pairs 顺序泄漏到 UI。
local function precise_now()
    local ok, fu = pcall(require, "ffi/util")
    if ok and fu and type(fu.gettime) == "function" then
        local called, sec, usec = pcall(fu.gettime)
        sec, usec = tonumber(sec), tonumber(usec) or 0
        if called and sec then return sec + usec / 1000000 end
    end
    return os.time()
end

local function next_order(map)
    local last = 0
    for _, rec in pairs(map or {}) do
        local order = tonumber(type(rec) == "table" and rec.bound_order)
        if order and order > last then last = order end
    end
    return last + 1
end

local function compare_records(a, b)
    local at_a, at_b = tonumber(a.bound_at) or 0, tonumber(b.bound_at) or 0
    if at_a ~= at_b then return at_a < at_b and -1 or 1 end
    local order_a = tonumber(a.bound_order) or 0
    local order_b = tonumber(b.bound_order) or 0
    if order_a ~= order_b then return order_a < order_b and -1 or 1 end
    local id_a, id_b = tostring(a.book_id or ""), tostring(b.book_id or "")
    if id_a == id_b then return 0 end
    return id_a < id_b and -1 or 1
end

-- 把存储值规范成 map {[book_id]=record}。旧单键记录在此迁移并落盘(仅迁移时写一次)。
-- 返回规范后的 map(可能为空表)。
local function normalize(store, doc_path)
    local all = store:get(KEY, {})
    local v = all[tostring(doc_path or "")]
    if is_record(v) then
        -- 旧单键格式:迁移为单元素 map。
        local map = { [v.book_id] = v }
        all[tostring(doc_path or "")] = map
        store:set(KEY, all)
        return map
    end
    if type(v) == "table" then
        local clean = {}
        for k, rec in pairs(v) do
            if is_record(rec) then clean[tostring(rec.book_id or k)] = rec end
        end
        return clean
    end
    return {}
end

local function load_all(store)
    return store:get(KEY, {})
end

-- 该本地书绑定的全部书,以 map 形式返回 {[book_id]=record}。
function Binding.records(store, doc_path)
    return normalize(store, doc_path)
end

-- 单本绑定记录,或 nil。
function Binding.get_record(store, doc_path, book_id)
    return normalize(store, doc_path)[tostring(book_id or "")]
end

-- 向后兼容:返回「主绑定」单记录(最近 bound_at 的一本)。单绑定场景即那一本。
function Binding.get(store, doc_path)
    local map = normalize(store, doc_path)
    local primary
    for _, rec in pairs(map) do
        if not primary or compare_records(rec, primary) > 0 then
            primary = rec
        end
    end
    return primary
end

-- 该本地书绑定的所有书,数组(按绑定时间升序),供 UI 展示与管理。
function Binding.list(store, doc_path)
    local map = normalize(store, doc_path)
    local out = {}
    for _, rec in pairs(map) do out[#out + 1] = rec end
    table.sort(out, function(a, b) return compare_records(a, b) < 0 end)
    return out
end

-- 绑定/更新某一本微信读书书。同名 book_id 覆盖,不同 book_id 并存(1:N)。
function Binding.add(store, doc_path, record)
    record = record or {}
    if not is_record(record) then return nil, "record 缺少有效的 book_id" end
    local all = load_all(store)
    local map = normalize(store, doc_path)
    if not record.bound_at then record.bound_at = precise_now() end
    record.bound_order = next_order(map)
    map[tostring(record.book_id)] = record
    all[tostring(doc_path or "")] = map
    store:set(KEY, all)
    return record
end

-- 兼容旧调用:Binding.save 等价于 add(替换同一 book_id 的绑定)。
function Binding.save(store, doc_path, record)
    return Binding.add(store, doc_path, record)
end

-- 移除某一本绑定;若该本地书再无绑定则清除整条记录。
function Binding.remove(store, doc_path, book_id)
    local all = load_all(store)
    local map = normalize(store, doc_path)
    map[tostring(book_id or "")] = nil
    if next(map) then
        all[tostring(doc_path or "")] = map
    else
        all[tostring(doc_path or "")] = nil
    end
    store:set(KEY, all)
end

-- 解除该本地书的全部绑定。
function Binding.clear(store, doc_path)
    local all = load_all(store)
    all[tostring(doc_path or "")] = nil
    store:set(KEY, all)
end

-- 搜索结果归一:支持 books[] / results[].books[] / results[] 直接 / 直接数组 四种形状,
-- 下钻 bookInfo 或直接字段,数字 id 转字符串;format 标注版本类型(txt=网络/epub=出版)。
function Binding.normalize_search(data)
    local out = {}
    if type(data) ~= "table" then return out end
    local raws = {}
    local function collect(arr)
        if type(arr) ~= "table" then return end
        for _, item in ipairs(arr) do
            if type(item) == "table" then
                if item.bookInfo then raws[#raws + 1] = item.bookInfo end
                if item.books then collect(item.books) end
                if not item.bookInfo and item.books == nil
                    and (item.bookId ~= nil or item.book_id ~= nil) then
                    raws[#raws + 1] = item
                end
            end
        end
    end
    if data.books then collect(data.books) end
    if data.results then collect(data.results) end
    -- 兼容旧网关搜索响应:列表可能藏在 updated 下。
    if type(data.updated) == "table" then collect(data.updated) end
    if #raws == 0 then collect(data) end
    local function suffix(format)
        if format == "txt" then return " [网络]" end
        if format == "epub" then return " [出版]" end
        return ""
    end
    for _, raw in ipairs(raws) do
        -- 兼容旧网关响应:id 字段可能是 book_id(下划线)而非 bookId。
        local id = raw.bookId or raw.book_id
        if id ~= nil and tostring(id) ~= "" then
            out[#out + 1] = {
                book_id = tostring(id),
                title = tostring(raw.title or "") .. suffix(raw.format),
                author = tostring(raw.author or ""),
            }
        end
    end
    return out
end

-- 章节列表归一:真实 web 端点(/web/book/chapterInfos)返回
--   {bookId?, synckey?, chapters:[{chapterUid,title,chapterIdx,...}]}
-- 故优先认 data.chapters;旧文档说的嵌套 {data=[{bookId,updated}]} 仅作兜底。
-- 无 bookId 选择时 data.data / chapterInfos / updated / 直接数组 皆可用。
-- 丢弃无 chapterUid 的条目,uid 字符串化,按 chapterIdx 升序排列。
function Binding.normalize_chapters(data, book_id)
    local out = {}
    if type(data) ~= "table" then return out end
    local book_id_s = book_id ~= nil and tostring(book_id) or nil
    local source
    if type(data.chapters) == "table" then
        source = data.chapters
    elseif type(data.data) == "table" then
        local chosen
        if book_id_s then
        for _, rec in ipairs(data.data) do
            if type(rec) == "table" and tostring(rec.bookId or rec.book_id or "") == book_id_s then
                chosen = rec; break
            end
        end
        end
        if chosen then
            -- 命中目标书记录:取其 updated/chapterInfos 内层章节。
            source = chosen.updated or chosen.chapterInfos or chosen.data
        else
            -- data.data 可能是章节数组(无 bookId),也可能是书记录数组但无匹配
            -- 目标书:无匹配时若首条是书记录则退回其 updated,否则当章节数组处理。
            local first = data.data[1]
            if type(first) == "table"
                and (first.bookId ~= nil or first.updated ~= nil or first.chapterInfos ~= nil) then
                source = first.updated or first.chapterInfos or first.data
            else
                source = data.data
            end
        end
    elseif type(data.chapterInfos) == "table" then
        source = data.chapterInfos
    elseif type(data.updated) == "table" then
        source = data.updated
    else
        source = data
    end
    -- 兼容旧网关响应:章节可能嵌套在 chapters 子数组里,摊平避免整章被丢弃。
    -- 有 uid 的章自身保留,若它又含嵌套子章节则一并摊平(父章 + 子章都在)。
    local raw = {}
    local function collect_chapters(list)
        if type(list) ~= "table" then return end
        for _, ch in ipairs(list) do
            if type(ch) == "table" then
                local has_uid = ch.chapterUid ~= nil or ch.chapterId ~= nil or ch.uid ~= nil
                if has_uid then raw[#raw + 1] = ch end
                if type(ch.chapters) == "table" and #ch.chapters > 0 then
                    collect_chapters(ch.chapters)
                end
            end
        end
    end
    collect_chapters(source)
    local rows = {}
    for idx, ch in ipairs(raw) do
        -- 兼容旧网关响应:chapterUid 缺失时回退 chapterId / uid,避免整章被丢弃。
        if type(ch) == "table" and (ch.chapterUid ~= nil or ch.chapterId ~= nil or ch.uid ~= nil) then
            rows[#rows + 1] = {
                uid = tostring(ch.chapterUid or ch.chapterId or ch.uid),
                title = tostring(ch.title or ""),
                chapterIdx = tonumber(ch.chapterIdx),
                ord = idx,
            }
        end
    end
    -- 排序:有 chapterIdx 按数字序;缺 chapterIdx 时保留输入顺序(稳定),不按 uid 字符串序
    -- 乱序(评审二轮 P2#6:旧响应缺 chapterIdx 时按 UID 字符串排序会打乱真实章节顺序)。
    table.sort(rows, function(a, b)
        local ai, bi = a.chapterIdx, b.chapterIdx
        if ai ~= nil and bi ~= nil then
            if ai ~= bi then return ai < bi end
            return a.ord < b.ord
        end
        if ai == nil and bi == nil then return a.ord < b.ord end
        return ai ~= nil
    end)
    for _, r in ipairs(rows) do r.chapterIdx = nil; r.ord = nil end
    return rows
end

function Binding.offer_reinject(has_inject, has_chapter_cache)
    if has_inject then return true end
    return has_chapter_cache == true
end


return Binding
