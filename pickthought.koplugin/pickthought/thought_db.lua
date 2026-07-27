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

function ThoughtDB.open(book_dir)
    if type(book_dir) ~= "string" or book_dir == "" then return nil end
    local SQ3 = get_sq3()
    if not SQ3 then return nil end
    U.mkdir(book_dir)
    local path = ThoughtDB.db_path(book_dir)
    local ok, db = pcall(SQ3.open, path)
    if not ok or not db then return nil end
    pcall(function() db:exec("PRAGMA journal_mode=WAL") end)
    pcall(function() db:exec("PRAGMA synchronous=NORMAL") end)
    local schema_ok = pcall(function()
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
    if not schema_ok then
        pcall(function() db:close() end)
        return nil
    end
    return db
end

function ThoughtDB.close(db)
    if db then pcall(function() db:close() end) end
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
