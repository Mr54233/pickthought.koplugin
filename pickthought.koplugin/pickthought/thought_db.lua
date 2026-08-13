-- Per-book SQLite 想法存储。一个 book_dir 一个 thoughts.db,
-- 主键 (chapter_uid, range, item_index)。点击划线时按 (chapter_uid, range)
-- 单次索引查询取想法,不必解码整章 JSON、不必 Lua 侧遍历。
--
-- 反向移植自 finlater/weread.koplugin 的 thought_db.lua(AGPL-3.0),
-- 适配我们的字段(content/abstract/author/likes/review_id)与数据形状
-- (groups → {range, texts},texts 元素同 web_fetch.build_reviews 输出)。
-- 合并语义不放在本层(纯函数在 thoughts.merge_rows),ThoughtDB 只做
-- open/close/put_chapter/put_range/get_range/delete_range/remove_db。
local logger = require("logger")
local U = require("pickthought.util")

local ThoughtDB = {}

-- schema 版本:随结构性迁移递增;open 时已落后版本号的库在此升级(user_version 追踪)。
local SCHEMA_VERSION = 1

local function get_sq3()
    local ok, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if ok and SQ3 then return SQ3 end
    return nil
end

function ThoughtDB.available()
    return get_sq3() ~= nil
end

function ThoughtDB.db_path(book_dir)
    return tostring(book_dir or "") .. "/thoughts.db"
end

function ThoughtDB.remove_db(book_dir)
    local path = ThoughtDB.db_path(book_dir)
    for _, p in ipairs({ path, path .. "-wal", path .. "-shm" }) do
        os.remove(p)
    end
end

-- 读取/写入 schema 版本(用 SQLite 的 user_version PRAGMA 持久化,免额外表)。
local function get_user_version(db)
    local ok, stmt = pcall(function() return db:prepare("PRAGMA user_version") end)
    if not ok or not stmt then return 0 end
    local _ok, row = pcall(function() return stmt:step() end)
    pcall(function() stmt:close() end)
    return (row and tonumber(row[1])) or 0
end

local function set_user_version(db, v)
    pcall(function() db:exec("PRAGMA user_version=" .. tostring(v)) end)
end

-- 创建表 + 迁移追踪:user_version 低于当前则在此升级(目前 v1 无结构性迁移,仅补版本号)。
local function ensure_schema(db)
    local ok = pcall(function()
        db:exec([[CREATE TABLE IF NOT EXISTS review_items (
            chapter_uid TEXT    NOT NULL,
            range       TEXT    NOT NULL,
            item_index  INTEGER NOT NULL,
            abstract    TEXT,
            author      TEXT    NOT NULL,
            content     TEXT    NOT NULL,
            likes       INTEGER NOT NULL DEFAULT 0,
            review_id   TEXT    NOT NULL DEFAULT '',
            PRIMARY KEY (chapter_uid, range, item_index)
        ) WITHOUT ROWID]])
    end)
    if not ok then return false end
    local ver = get_user_version(db)
    if ver < SCHEMA_VERSION then
        set_user_version(db, SCHEMA_VERSION)
    end
    return true
end

-- 打开单个库(不含完整性核验与重建),供 open 复用。
local function do_open(path)
    local SQ3 = get_sq3()
    if not SQ3 then return nil end
    local ok, db = pcall(SQ3.open, path)
    if not ok or not db then return nil end
    pcall(function() db:exec("PRAGMA journal_mode=WAL") end)
    pcall(function() db:exec("PRAGMA synchronous=NORMAL") end)
    if not ensure_schema(db) then
        pcall(function() db:close() end)
        return nil
    end
    return db
end

-- 完整性核验:PRAGMA integrity_check 返回 "ok" 即健康,否则收集损坏描述。
-- FAT32/SD 卡易损,KPW3 上收益最大。
function ThoughtDB.integrity_check(db)
    if not db then return false, "no db" end
    local ok, stmt = pcall(function() return db:prepare("PRAGMA integrity_check") end)
    if not ok or not stmt then return false, "prepare failed" end
    local bad, step_ok, row = {}, pcall(function() return stmt:step() end)
    while step_ok and row do
        if tostring(row[1] or "") ~= "ok" then bad[#bad + 1] = tostring(row[1]) end
        step_ok, row = pcall(function() return stmt:step() end)
    end
    pcall(function() stmt:close() end)
    if not step_ok then return false, "step failed" end
    if #bad == 0 then return true end
    return false, table.concat(bad, "; ")
end

-- WAL 检查点:把 WAL 折叠进主库并截断,减小断电损坏面、回收 -wal/-shm 文件。
function ThoughtDB.checkpoint(db)
    if not db then return false end
    return pcall(function() db:exec("PRAGMA wal_checkpoint(TRUNCATE)") end)
end

function ThoughtDB.open(book_dir, _attempt)
    if type(book_dir) ~= "string" or book_dir == "" then return nil end
    local SQ3 = get_sq3()
    if not SQ3 then return nil end
    U.mkdir(book_dir)
    local path = ThoughtDB.db_path(book_dir)
    local db = do_open(path)
    if not db then return nil end
    -- 打开即核验完整性;损坏则丢弃本地缓存(想法可由注入源重建),重建干净库,仅重试一次防递归。
    local ic_ok, healthy, msg = pcall(ThoughtDB.integrity_check, db)
    if not ic_ok or healthy ~= true then
        logger.warn("[撷思][ThoughtDB] integrity_check 异常,重建", path, tostring(msg or healthy))
        pcall(ThoughtDB.close, db)
        if not _attempt then
            ThoughtDB.remove_db(book_dir)
            return ThoughtDB.open(book_dir, true)
        end
        return nil
    end
    return db
end

function ThoughtDB.close(db)
    if db then
        pcall(ThoughtDB.checkpoint, db)
        pcall(function() db:close() end)
    end
end

local function insert_rows(db, chapter_uid, groups)
    local ins = db:prepare([[INSERT INTO review_items
        (chapter_uid, range, item_index, abstract, author, content, likes, review_id)
        VALUES (?,?,?,?,?,?,?,?)]])
    for _, group in ipairs(groups or {}) do
        local range = tostring((type(group) == "table" and group.range) or "")
        if range ~= "" then
            for idx, item in ipairs((type(group) == "table" and group.texts) or {}) do
                if type(item) == "table" and tostring(item.content or "") ~= "" then
                    ins:reset():bind(
                        chapter_uid, range, idx,
                        tostring(item.abstract or ""),
                        tostring(item.author or ""),
                        tostring(item.content or ""),
                        tonumber(item.likes or 0) or 0,
                        tostring(item.review_id or "")
                    ):step()
                end
            end
        end
    end
    ins:close()
end

-- 替换一章的全部想法(groups 形状同 Thoughts.save 输入)。单事务。
function ThoughtDB.put_chapter(db, chapter_uid, groups)
    if not db then return false end
    chapter_uid = tostring(chapter_uid or "")
    local ok, err = pcall(function()
        db:exec("BEGIN")
        local del = db:prepare("DELETE FROM review_items WHERE chapter_uid=?")
        del:reset():bind(chapter_uid):step()
        del:close()
        insert_rows(db, chapter_uid, groups)
        db:exec("COMMIT")
    end)
    if not ok then
        pcall(function() db:exec("ROLLBACK") end)
        logger.warn("[撷思][ThoughtDB] put_chapter failed", tostring(err))
        return false
    end
    return true
end

-- 替换一个 range 的想法(texts = {content,abstract,author,likes,review_id} 列表)。
function ThoughtDB.put_range(db, chapter_uid, range_str, texts)
    if not db then return false end
    chapter_uid, range_str = tostring(chapter_uid or ""), tostring(range_str or "")
    local ok, err = pcall(function()
        db:exec("BEGIN")
        local del = db:prepare("DELETE FROM review_items WHERE chapter_uid=? AND range=?")
        del:reset():bind(chapter_uid, range_str):step()
        del:close()
        insert_rows(db, chapter_uid, { { range = range_str, texts = texts } })
        db:exec("COMMIT")
    end)
    if not ok then
        pcall(function() db:exec("ROLLBACK") end)
        logger.warn("[撷思][ThoughtDB] put_range failed", tostring(err))
        return false
    end
    return true
end

-- 查一个 range 的全部想法,返回 texts 列表(同 compact_group 输出的 texts 形状)。
function ThoughtDB.get_range(db, chapter_uid, range_str)
    if not db then return nil end
    local ok, stmt = pcall(function()
        return db:prepare([[SELECT abstract, author, content, likes, review_id
            FROM review_items WHERE chapter_uid=? AND range=? ORDER BY item_index]])
    end)
    if not ok or not stmt then return nil end
    local texts = {}
    local step_ok, row = pcall(function()
        return stmt:reset():bind(tostring(chapter_uid or ""), tostring(range_str or "")):step()
    end)
    if not step_ok then pcall(function() stmt:close() end); return nil end
    while row do
        texts[#texts + 1] = {
            abstract = row[1], author = row[2], content = row[3],
            likes = tonumber(row[4]) or 0, review_id = row[5],
        }
        step_ok, row = pcall(function() return stmt:step() end)
        if not step_ok then pcall(function() stmt:close() end); return nil end
    end
    pcall(function() stmt:close() end)
    return texts
end

-- 删除一个 range 的全部想法。
function ThoughtDB.delete_range(db, chapter_uid, range_str)
    if not db then return false end
    local ok = pcall(function()
        local del = db:prepare("DELETE FROM review_items WHERE chapter_uid=? AND range=?")
        del:reset():bind(tostring(chapter_uid or ""), tostring(range_str or "")):step()
        del:close()
    end)
    return ok
end

return ThoughtDB
