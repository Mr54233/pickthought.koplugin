-- 想法数据:per-book SQLite 存储(thoughts.db),点击锚点按 (chapter_uid, range)
-- 单次索引查询取想法,交给原生 TextViewer 分页显示。
--
-- 锚点格式 pickthought-{hex(book)}.{hex(chap)}.{hex(range)} 与注入侧(epub_inject)
-- 共用,不变:已注入的书不因存储后端切换而失效。
-- 旧版按章存 thoughts/{uid}.json,首次打开某书数据库时一次性迁移并删旧目录。
local Json = require("pickthought.json")  -- 仅迁移旧 JSON 用
local U = require("pickthought.util")
local ThoughtDB = require("pickthought.thought_db")
local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")

local Thoughts = {}

-- per-book SQLite 句柄缓存:点击锚点时避免反复 open/close。
-- KPW3 红线:句柄不得无上限累积——纯阅读期跨多本注入书点锚点会 slowly 涨内存
-- (每个句柄连带 SQLite + WAL 文件)。加 LRU 上限,超出关最久未用,释放文件句柄。
local db_cache = {}
local db_cache_order = {}   -- LRU 顺序:表头最久未用,表尾最近使用
local DB_CACHE_MAX = 4
local migrated = {}  -- book_dir → 已检查旧 JSON 迁移(进程内不重复扫)

local function db_cache_touch(book_dir)
    for i, v in ipairs(db_cache_order) do
        if v == book_dir then table.remove(db_cache_order, i); break end
    end
    db_cache_order[#db_cache_order + 1] = book_dir
end

local function db_cache_evict()
    while #db_cache_order > DB_CACHE_MAX do
        local old = table.remove(db_cache_order, 1)
        local db = db_cache[old]
        if db then pcall(ThoughtDB.close, db) end
        db_cache[old] = nil
    end
end

local function hex_encode(value)
    return (tostring(value or ""):gsub(".", function(ch)
        return string.format("%02x", ch:byte())
    end))
end

local function hex_decode(value)
    if type(value) ~= "string" or value == "" or value:find("[^0-9a-fA-F]") or #value % 2 ~= 0 then
        return nil
    end
    return (value:gsub("(%x%x)", function(pair)
        return string.char(tonumber(pair, 16))
    end))
end

-- 锚点前缀需与其他微信读书插件不同,避免共存时 tap 拦截冲突。
-- 三个插件可能同装,各自的 tap 拦截只认领自己的前缀才能共存。
function Thoughts.anchor(book_id, chapter_uid, range)
    return "pickthought-" .. hex_encode(book_id) .. "." .. hex_encode(chapter_uid) .. "." .. hex_encode(range)
end

function Thoughts.href(book_id, chapter_uid, range)
    return "#" .. Thoughts.anchor(book_id, chapter_uid, range)
end

function Thoughts.parse_href(href)
    local anchor = tostring(href or ""):match("(pickthought%-[%x%.]+)")
    if not anchor then return nil end
    local b, c, r = anchor:match("^pickthought%-([%x]+)%.([%x]+)%.([%x]+)$")
    if not b then return nil end
    local book_id, chapter_uid, range = hex_decode(b), hex_decode(c), hex_decode(r)
    if not book_id or not chapter_uid or not range then return nil end
    return {book_id = book_id, chapter_uid = chapter_uid, range = range, anchor = anchor}
end

function Thoughts.cache_dir(store, book_id)
    local dir = store:book_dir(book_id) .. "/thoughts"
    U.mkdir(dir)
    return dir
end

function Thoughts.db_path(store, book_id)
    return ThoughtDB.db_path(store:book_dir(book_id))
end

-- 一次性迁移:旧版按章存 thoughts/{uid}.json,新版 per-book SQLite。
-- 首次打开某书数据库时,若旧目录还有 JSON,全部导入后删旧文件。
-- chapter_uid 都是数字字符串,U.id_name 对其恒等,文件名(去 .json)即 uid。
local function migrate_legacy(book_id, book_dir, db)
    local dir = book_dir .. "/thoughts"
    if lfs.attributes(dir, "mode") ~= "directory" then return end
    local any = false
    for _, path in ipairs(U.list(dir)) do
        local uid = path:match("([^/]+)%.json$")
        if uid then
            local raw = U.read_file(path, true)
            if raw then
                local ok, rows = pcall(Json.decode, raw)
                if ok and type(rows) == "table" and #rows > 0 then
                    ThoughtDB.put_chapter(db, uid, rows)
                    any = true
                end
            end
            os.remove(path)
        end
    end
    if any then
        logger.info("[撷思][Thoughts] legacy JSON migrated to sqlite", "book=", tostring(book_id))
    end
end

local function open_db(store, book_id)
    local book_dir = store:book_dir(book_id)
    local db = db_cache[book_dir]
    if db then
        db_cache_touch(book_dir)
        return db
    end
    db = ThoughtDB.open(book_dir)
    if not db then return nil end
    db_cache[book_dir] = db
    db_cache_touch(book_dir)
    db_cache_evict()
    if not migrated[book_dir] then
        migrated[book_dir] = true
        local ok_mig = pcall(migrate_legacy, book_id, book_dir, db)
        if not ok_mig then logger.warn("[撷思][Thoughts] migrate_legacy failed", tostring(book_id)) end
    end
    return db
end

function Thoughts.save(store, book_id, chapter_uid, groups)
    local db = open_db(store, book_id)
    if not db then return nil, "想法数据库不可用" end
    local count = 0
    for _, g in ipairs(groups or {}) do
        if type(g) == "table" then
            for _, item in ipairs(g.texts or {}) do
                if type(item) == "table" and tostring(item.content or "") ~= "" then
                    count = count + 1
                end
            end
        end
    end
    if not ThoughtDB.put_chapter(db, tostring(chapter_uid), groups) then
        return nil, "想法写入失败"
    end
    logger.info("[撷思][Thoughts] saved", "book=", tostring(book_id),
        "chapter=", tostring(chapter_uid), "items=", tostring(count))
    return count, Thoughts.db_path(store, book_id)
end

-- 把 from_range 组的想法并进 into_range 组(注入时重叠划线被合并,
-- 存活锚点要能弹出被合并划线的想法)。纯函数,便于测试。
-- into 组不存在时直接把 from 组重新锚定为 into(内容原地改名)。
function Thoughts.merge_rows(rows, from_range, into_range)
    from_range, into_range = tostring(from_range or ""), tostring(into_range or "")
    if from_range == "" or into_range == "" or from_range == into_range then return false end
    local from_group, into_group
    for _, row in ipairs(rows or {}) do
        if type(row) == "table" then
            if tostring(row.range) == from_range then from_group = row end
            if tostring(row.range) == into_range then into_group = row end
        end
    end
    if not from_group or type(from_group.texts) ~= "table" then return false end
    if not into_group then
        from_group.range = into_range
        return true
    end
    into_group.texts = type(into_group.texts) == "table" and into_group.texts or {}
    local seen = {}
    for _, item in ipairs(into_group.texts) do
        local key = tostring(item.review_id or "")
        if key == "" then key = tostring(item.author or "") .. "\0" .. tostring(item.content or "") end
        seen[key] = true
    end
    local appended = false
    for _, item in ipairs(from_group.texts) do
        local key = tostring(item.review_id or "")
        if key == "" then key = tostring(item.author or "") .. "\0" .. tostring(item.content or "") end
        if not seen[key] then
            seen[key] = true
            into_group.texts[#into_group.texts + 1] = item
            appended = true
        end
    end
    return appended
end

function Thoughts.merge(store, book_id, chapter_uid, from_range, into_range)
    from_range, into_range = tostring(from_range or ""), tostring(into_range or "")
    if from_range == "" or into_range == "" or from_range == into_range then return false end
    local db = open_db(store, book_id)
    if not db then return false end
    local uid = tostring(chapter_uid or "")
    local from_texts = ThoughtDB.get_range(db, uid, from_range)
    if not from_texts or #from_texts == 0 then return false end
    local into_texts = ThoughtDB.get_range(db, uid, into_range) or {}
    -- 复用已测的纯函数(操作 rows 结构)做去重合并。
    local rows = { { range = from_range, texts = from_texts },
        { range = into_range, texts = into_texts } }
    Thoughts.merge_rows(rows, from_range, into_range)
    -- merge_rows 后:into 原有→rows[2].texts 是合并结果;into 原空→rows[1].range 被改成 into。
    local merged_texts = (#into_texts > 0) and rows[2].texts or rows[1].texts
    ThoughtDB.put_range(db, uid, into_range, merged_texts)
    ThoughtDB.delete_range(db, uid, from_range)
    return true
end

function Thoughts.find(store, book_id, chapter_uid, range)
    local db = open_db(store, book_id)
    if not db then return nil, "想法数据库不可用" end
    local texts = ThoughtDB.get_range(db, tostring(chapter_uid or ""), tostring(range or ""))
    if not texts or #texts == 0 then return nil, "没有找到该划线对应的想法" end
    return { range = tostring(range), texts = texts }
end

local function clean(value)
    return U.trim(tostring(value or ""):gsub("[%z\1-\8\11\12\14-\31]", " "):gsub("%s+", " "))
end

function Thoughts.group_abstract(group)
    for _, item in ipairs((group and group.texts) or {}) do
        local abstract = clean(item.abstract)
        if abstract ~= "" then return abstract end
    end
    return ""
end

-- 适配原生想法弹窗:保留 SQLite 顺序,并按 review_id 去重。
function Thoughts.popup_items(group)
    local items, seen = {}, {}
    for _, item in ipairs((group and group.texts) or {}) do
        local content = clean(item.content)
        if content ~= "" then
            local author = clean(item.author)
            if author == "" then author = "微信读书用户" end
            local review_id = tostring(item.review_id or "")
            local key = review_id ~= "" and ("id:" .. review_id) or (author .. "\0" .. content)
            if not seen[key] then
                seen[key] = true
                items[#items + 1] = {
                    abstract = #items == 0 and clean(item.abstract) or "",
                    author = author,
                    content = content,
                    likes_count = tonumber(item.likes or 0) or 0,
                }
            end
        end
    end
    return items
end

-- 把想法格式化成 TextViewer 用的纯文本:每条「作者 · 赞 / 内容」,条目间空行分隔。
function Thoughts.popup_text(group)
    local parts, seen = {}, {}
    for _, item in ipairs((group and group.texts) or {}) do
        local content = clean(item.content)
        if content ~= "" then
            local author = clean(item.author)
            if author == "" then author = "微信读书用户" end
            local review_id = tostring(item.review_id or "")
            local key = review_id ~= "" and ("id:" .. review_id) or (author .. "\0" .. content)
            if not seen[key] then
                seen[key] = true
                local meta = "▸ " .. author
                local likes = tonumber(item.likes or 0) or 0
                if likes > 0 then meta = meta .. "  ·  赞 " .. tostring(likes) end
                parts[#parts + 1] = meta .. "\n" .. content
            end
        end
    end
    return table.concat(parts, "\n\n")
end

function Thoughts.clear_memory_cache()
    for _, db in pairs(db_cache) do pcall(ThoughtDB.close, db) end
    db_cache = {}
    db_cache_order = {}
    -- migrated 不清:进程内已迁移的 book 不重复扫(目录已空,下次也跳过)。
end

-- 关闭单本书句柄(阅读端关闭文档时调用),释放 SQLite + WAL 文件。
-- 之后若再点该书的锚点,open_db 会重新打开,无害。
function Thoughts.close_book(store, book_id)
    local book_dir = store:book_dir(book_id)
    local db = db_cache[book_dir]
    if db then
        pcall(ThoughtDB.close, db)
        db_cache[book_dir] = nil
        for i, v in ipairs(db_cache_order) do
            if v == book_dir then table.remove(db_cache_order, i); break end
        end
    end
end

return Thoughts
