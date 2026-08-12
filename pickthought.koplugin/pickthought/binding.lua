-- 本地书 ↔ 微信读书书目的绑定:搜索/章节响应规范化 + 按文档路径持久化。
--
-- 绑定模型(2026-08 起支持「一本本地书绑定多本微信读书书」,用于合集/套装 EPUB):
--   all[doc_path] 是一个 map:{ [book_id] = {book_id, title, author, bound_at} }
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
    local primary, primary_at
    for _, rec in pairs(map) do
        local at = tonumber(rec.bound_at) or 0
        if not primary or at > (primary_at or 0) then
            primary, primary_at = rec, at
        end
    end
    return primary
end

-- 该本地书绑定的所有书,数组(按绑定时间升序),供 UI 展示与管理。
function Binding.list(store, doc_path)
    local map = normalize(store, doc_path)
    local out = {}
    for _, rec in pairs(map) do out[#out + 1] = rec end
    table.sort(out, function(a, b)
        return (tonumber(a.bound_at) or 0) < (tonumber(b.bound_at) or 0)
    end)
    return out
end

-- 绑定/更新某一本微信读书书。同名 book_id 覆盖,不同 book_id 并存(1:N)。
function Binding.add(store, doc_path, record)
    record = record or {}
    if not is_record(record) then return nil, "record 缺少有效的 book_id" end
    if not record.bound_at then record.bound_at = os.time() end
    local all = load_all(store)
    local map = normalize(store, doc_path)
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
                if not item.bookInfo and item.books == nil and item.bookId ~= nil then
                    raws[#raws + 1] = item
                end
            end
        end
    end
    if data.books then collect(data.books) end
    if data.results then collect(data.results) end
    if #raws == 0 then collect(data) end
    local function suffix(format)
        if format == "txt" then return " [网络]" end
        if format == "epub" then return " [出版]" end
        return ""
    end
    for _, raw in ipairs(raws) do
        local id = raw.bookId
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
                if type(rec) == "table" and tostring(rec.bookId or "") == book_id_s then
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
    local raw = {}
    if type(source) == "table" then
        for _, ch in ipairs(source) do raw[#raw + 1] = ch end
    end
    local rows = {}
    for _, ch in ipairs(raw) do
        if type(ch) == "table" and ch.chapterUid ~= nil then
            rows[#rows + 1] = {
                uid = tostring(ch.chapterUid),
                title = tostring(ch.title or ""),
                chapterIdx = tonumber(ch.chapterIdx),
            }
        end
    end
    table.sort(rows, function(a, b)
        local ai = a.chapterIdx or 0
        local bi = b.chapterIdx or 0
        if ai ~= bi then return ai < bi end
        return a.uid < b.uid
    end)
    for _, r in ipairs(rows) do r.chapterIdx = nil end
    return rows
end

return Binding
