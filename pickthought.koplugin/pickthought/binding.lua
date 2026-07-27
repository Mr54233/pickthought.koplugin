-- 本地书 ↔ 微信读书书目的绑定:搜索/章节响应规范化 + 按文档路径持久化。
-- store 只需 get(k, default) / set(k, v) 两个方法。
local Binding = {}

local KEY = "bindings"

local function scalar_str(v)
    local kind = type(v)
    if kind == "string" or kind == "number" then return tostring(v) end
    return ""
end

local function rows_of(data, names)
    if type(data) ~= "table" then return {} end
    for _, name in ipairs(names) do
        if type(data[name]) == "table" then return data[name] end
    end
    if #data > 0 then return data end
    return {}
end

function Binding.normalize_search(data)
    local out = {}
    local function add_row(row)
        if type(row) ~= "table" then return end
        local info = type(row.bookInfo) == "table" and row.bookInfo or row
        local book_id = scalar_str(info.bookId or info.book_id)
        if book_id ~= "" then
            out[#out + 1] = {
                book_id = book_id,
                title = scalar_str(info.title),
                author = scalar_str(info.author),
            }
        end
    end
    for _, row in ipairs(rows_of(data, {"books", "results", "updated"})) do
        -- /store/search 真实响应是分组形状:results=[{type=..., books=[{bookInfo=...}]}],
        -- 分组行自身无 bookId,需要下钻 books(与主菜单同款处理)。
        if type(row) == "table" and type(row.books) == "table"
            and scalar_str(row.bookId or row.book_id) == "" then
            for _, sub in ipairs(row.books) do add_row(sub) end
        else
            add_row(row)
        end
    end
    return out
end

local function chapter_uid_of(row)
    if type(row) ~= "table" then return "" end
    return scalar_str(row.chapterUid or row.chapterId or row.uid)
end

-- 经典章节接口按「书记录」返回:{data=[{bookId=..., updated=[章节...]}]},
-- 记录行没有 chapterUid;按 book_id 选中目标记录后下钻内层数组。
local function chapter_rows(data, book_id)
    local rows = rows_of(data, {"data", "updated", "chapters", "chapterInfos"})
    if #rows == 0 or chapter_uid_of(rows[1]) ~= "" then return rows end
    local function inner_of(record)
        if type(record) ~= "table" then return nil end
        for _, key in ipairs({"updated", "chapterInfos", "chapters"}) do
            if type(record[key]) == "table" then return record[key] end
        end
        return nil
    end
    local fallback
    for _, record in ipairs(rows) do
        local inner = inner_of(record)
        if inner then
            fallback = fallback or inner
            if book_id and scalar_str(record.bookId) == tostring(book_id) then return inner end
        end
    end
    return fallback or rows
end

function Binding.normalize_chapters(data, book_id)
    local out = {}
    for index, row in ipairs(chapter_rows(data, book_id)) do
        local uid = chapter_uid_of(row)
        if uid ~= "" then
            out[#out + 1] = {
                uid = uid,
                title = scalar_str(row.title),
                idx = tonumber(row.chapterIdx) or index,
            }
        end
    end
    table.sort(out, function(a, b) return a.idx < b.idx end)
    return out
end

function Binding.get(store, doc_path)
    local all = store:get(KEY, {})
    return all[tostring(doc_path or "")]
end

function Binding.save(store, doc_path, record)
    local all = store:get(KEY, {})
    record = record or {}
    if not record.bound_at then record.bound_at = os.time() end
    all[tostring(doc_path or "")] = record
    store:set(KEY, all)
end

function Binding.clear(store, doc_path)
    local all = store:get(KEY, {})
    all[tostring(doc_path or "")] = nil
    store:set(KEY, all)
end

return Binding
