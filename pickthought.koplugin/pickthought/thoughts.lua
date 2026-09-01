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
local PopupDiagnostic = require("pickthought.diagnostic")

local Thoughts = {}

-- per-book SQLite 句柄缓存:点击锚点时避免反复 open/close。
-- KPW3 红线:句柄不得无上限累积——纯阅读期跨多本注入书点锚点会 slowly 涨内存
-- (每个句柄连带 SQLite + WAL 文件)。加 LRU 上限,超出关最久未用,释放文件句柄。
local db_cache = {}
local db_cache_order = {}   -- LRU 顺序:表头最久未用,表尾最近使用
local DB_CACHE_MAX = 4
local migrated = {}  -- book_dir → 最近一次检查确认没有残留旧 JSON

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
-- 逐文件迁移旧 JSON。只有写入 SQLite 成功且源文件删除成功,该文件才算完成;
-- 任一文件失败都保留源文件,不影响同批其他文件,后续可再次重试。
local function migrate_legacy(book_id, book_dir, db)
    local dir = book_dir .. "/thoughts"
    local attr_ok, mode, attr_err = pcall(lfs.attributes, dir, "mode")
    if not attr_ok then
        logger.warn("[撷思][Thoughts] legacy JSON directory check failed", "book=", tostring(book_id),
            "error=", tostring(mode))
        return false, 0, 1
    end
    if mode ~= "directory" then
        local text = tostring(attr_err or ""):lower()
        if text ~= "" and not text:find("no such file", 1, true)
            and not text:find("not exist", 1, true) and not text:find("不存在", 1, true) then
            logger.warn("[撷思][Thoughts] legacy JSON directory unavailable", "book=", tostring(book_id),
                "error=", tostring(attr_err))
            return false, 0, 1
        end
        return true, 0, 0
    end
    local list_ok, paths = pcall(U.list, dir)
    if not list_ok or type(paths) ~= "table" then
        logger.warn("[撷思][Thoughts] legacy JSON listing failed", "book=", tostring(book_id),
            "error=", tostring(list_ok and "目录列表格式异常" or paths))
        return false, 0, 1
    end
    local all_ok, migrated_count, failed_count = true, 0, 0
    for _, path in ipairs(paths) do
        local uid = path:match("([^/]+)%.json$")
        if uid then
            local file_ok, reason
            local read_call, raw, read_err = pcall(U.read_file, path, true)
            if not read_call or not raw then
                reason = "读取失败:" .. tostring(read_call and read_err or raw)
            else
                local decode_call, rows = pcall(Json.decode, raw)
                if not decode_call then
                    reason = "解析失败:" .. tostring(rows)
                elseif type(rows) ~= "table" then
                    reason = "数据格式不是数组"
                else
                    -- 空数组没有可迁移内容;保持旧行为为 no-op,避免误清理已有章节。
                    local write_call, written, write_err = true, true, nil
                    if #rows > 0 then
                        write_call, written, write_err = pcall(ThoughtDB.put_chapter, db, uid, rows)
                    end
                    if not write_call or written ~= true then
                        reason = "写入 SQLite 失败:" .. tostring(write_call and write_err or written)
                    else
                        local remove_call, removed, remove_err = pcall(os.remove, path)
                        local exists_call, still_exists = pcall(U.file_exists, path)
                        if not remove_call then
                            reason = "删除源文件失败:" .. tostring(removed)
                        elseif not exists_call then
                            reason = "无法确认源文件是否删除:" .. tostring(still_exists)
                        elseif not still_exists and (removed == true or removed == nil) then
                            file_ok = true
                        else
                            reason = "删除源文件失败:" .. tostring(remove_err or "文件仍存在")
                        end
                    end
                end
            end
            if file_ok then
                migrated_count = migrated_count + 1
            else
                all_ok = false
                failed_count = failed_count + 1
                logger.warn("[撷思][Thoughts] legacy JSON migration deferred",
                    "book=", tostring(book_id), "file=", tostring(path), "error=", tostring(reason))
            end
        end
    end
    if all_ok and migrated_count > 0 then
        logger.info("[撷思][Thoughts] legacy JSON migrated to sqlite", "book=", tostring(book_id),
            "files=", tostring(migrated_count))
    end
    return all_ok, migrated_count, failed_count
end

local function close_cached_db(book_dir)
    local db = db_cache[book_dir]
    if db then pcall(ThoughtDB.close, db) end
    db_cache[book_dir] = nil
    for i, value in ipairs(db_cache_order) do
        if value == book_dir then table.remove(db_cache_order, i); break end
    end
end

-- 查询失败时丢弃句柄,不做 checkpoint 或任何可能的二次写入。
local function discard_cached_db(book_dir, expected_db)
    local db = db_cache[book_dir]
    if expected_db and db ~= expected_db then return end
    if db then pcall(ThoughtDB.close_no_checkpoint, db) end
    db_cache[book_dir] = nil
    for i, value in ipairs(db_cache_order) do
        if value == book_dir then table.remove(db_cache_order, i); break end
    end
end

local function legacy_json_exists(book_dir)
    local dir = book_dir .. "/thoughts"
    local ok, mode, attr_err = pcall(lfs.attributes, dir, "mode")
    if not ok then return true end
    if mode ~= "directory" then
        local text = tostring(attr_err or ""):lower()
        return text ~= "" and not text:find("no such file", 1, true)
            and not text:find("not exist", 1, true) and not text:find("不存在", 1, true)
    end
    local list_ok, paths = pcall(U.list, dir)
    if not list_ok or type(paths) ~= "table" then return true end
    for _, path in ipairs(paths) do
        if path:match("[^/]+%.json$") then return true end
    end
    return false
end

local function legacy_migration_pending(book_dir, force)
    -- 正常阅读复用迁移完成标记,避免每次点击都扫目录;写入请求则强制重查,
    -- 以捕获失败后留下的文件或进程运行期间重新出现的旧 JSON。
    if migrated[book_dir] and not force then return false end
    return legacy_json_exists(book_dir)
end

local function maybe_migrate_legacy(book_id, book_dir, db, force)
    if not force and migrated[book_dir] then return true end
    if not legacy_json_exists(book_dir) then
        migrated[book_dir] = true
        return true
    end
    local call_ok, ok_mig = pcall(migrate_legacy, book_id, book_dir, db)
    if not call_ok then
        migrated[book_dir] = nil
        logger.warn("[撷思][Thoughts] legacy JSON migration crashed",
            "book=", tostring(book_id), "error=", tostring(ok_mig))
        return false
    end
    if ok_mig then migrated[book_dir] = true else migrated[book_dir] = nil end
    return ok_mig
end

local function open_db(store, book_id, writable)
    local book_dir = store:book_dir(book_id)
    local db = db_cache[book_dir]
    local legacy_pending
    if db then
        -- 只在写入请求时检查缓存期间新出现的旧 JSON;普通读取不能因迁移失败
        -- 每次点击都重新扫描目录或升级到完整打开。
        legacy_pending = writable and legacy_migration_pending(book_dir, true)
        if (writable or legacy_pending) and ThoughtDB.is_readonly(db) then
            close_cached_db(book_dir)
            db = nil
        end
    end
    if db then
        if writable and legacy_pending then maybe_migrate_legacy(book_id, book_dir, db, true) end
        db_cache_touch(book_dir)
        PopupDiagnostic.log("thoughts_db_cache_hit", {book=book_id})
        return db
    end
    local started = PopupDiagnostic.now()
    legacy_pending = legacy_migration_pending(book_dir, writable)
    local needs_migration = writable or legacy_pending
    local open_err
    if needs_migration then
        db, open_err = ThoughtDB.open(book_dir)
    else
        db, open_err = ThoughtDB.open_fast(book_dir)
    end
    PopupDiagnostic.log("thoughts_db_open", {book=book_id, elapsed_ms=PopupDiagnostic.elapsed(started), ok=db~=nil,
        writable=needs_migration})
    if not db then return nil, open_err end  -- 透传 ThoughtDB.open 的具体错误(作者第8轮意见 #3)
    db_cache[book_dir] = db
    db_cache_touch(book_dir)
    db_cache_evict()
    if needs_migration and legacy_pending then
        maybe_migrate_legacy(book_id, book_dir, db, true)
    else
        migrated[book_dir] = true
    end
    return db
end

function Thoughts.save(store, book_id, chapter_uid, groups)
    local db, dberr = open_db(store, book_id, true)
    if not db then return nil, dberr or "想法数据库不可用" end
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
    local db = open_db(store, book_id, true)
    if not db then return false end  -- 失败静默:merge 上层仅判真/假,无错误通道(保持原契约)
    local uid = tostring(chapter_uid or "")
    local from_texts, from_err = ThoughtDB.get_range(db, uid, from_range)
    if not from_texts then
        discard_cached_db(store:book_dir(book_id), db)
        logger.warn("[撷思][Thoughts] merge source query failed", "book=", tostring(book_id),
            "error=", tostring(from_err))
        return false
    end
    if #from_texts == 0 then return false end
    local into_texts, into_err = ThoughtDB.get_range(db, uid, into_range)
    if not into_texts then
        discard_cached_db(store:book_dir(book_id), db)
        logger.warn("[撷思][Thoughts] merge target query failed", "book=", tostring(book_id),
            "error=", tostring(into_err))
        return false
    end
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
    local started = PopupDiagnostic.now()
    local db, dberr = open_db(store, book_id, false)
    if not db then
        PopupDiagnostic.log("thoughts_find", {book=book_id, chapter=chapter_uid, elapsed_ms=PopupDiagnostic.elapsed(started), ok=false})
        return nil, dberr or "想法数据库不可用"
    end
    local query_started = PopupDiagnostic.now()
    local texts, query_err = ThoughtDB.get_range(db, tostring(chapter_uid or ""), tostring(range or ""))
    PopupDiagnostic.log("thoughts_range_query", {book=book_id, chapter=chapter_uid,
        elapsed_ms=PopupDiagnostic.elapsed(query_started), rows=type(texts)=="table" and #texts or 0,
        error=query_err})
    if not texts then
        discard_cached_db(store:book_dir(book_id), db)
        PopupDiagnostic.log("thoughts_find", {book=book_id, chapter=chapter_uid,
            elapsed_ms=PopupDiagnostic.elapsed(started), ok=false, error=query_err})
        return nil, query_err or "想法数据库读取失败"
    end
    if #texts == 0 then
        PopupDiagnostic.log("thoughts_find", {book=book_id, chapter=chapter_uid, elapsed_ms=PopupDiagnostic.elapsed(started), ok=false})
        return nil, "没有找到该划线对应的想法"
    end
    PopupDiagnostic.log("thoughts_find", {book=book_id, chapter=chapter_uid, elapsed_ms=PopupDiagnostic.elapsed(started), ok=true, rows=#texts})
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
    close_cached_db(book_dir)
end

return Thoughts
