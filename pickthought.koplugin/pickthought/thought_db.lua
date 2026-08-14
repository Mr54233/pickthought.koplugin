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
    -- 同时清理隔离标记:用户主动清缓存后允许下次 open 正常重建(作者意见 #2)。
    for _, p in ipairs({ path, path .. "-wal", path .. "-shm", path .. ".isolated" }) do
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

-- 迁移分发点:目前仅 SCHEMA_VERSION=1,无结构性迁移。未来升级时按 user_version
-- 顺序在此执行,例如:for v = from+1, SCHEMA_VERSION do MIGRATIONS[v](db) end
-- 注意:本插件无线上账号/云同步,想法可由本地注入源(离线缓存)重建,故 open 内
-- 不做"数据迁移式重建";损坏库交由 isolate_corrupt 隔离,由用户/同步重新注入。
local MIGRATIONS = {}  -- 预留:MIGRATIONS[2] = function(db) ... end

local function migrate(db, from_version)
    for v = (from_version or 0) + 1, SCHEMA_VERSION do
        if MIGRATIONS[v] then
            local ok, err = pcall(MIGRATIONS[v], db)
            if not ok then
                logger.warn("[撷思][ThoughtDB] 迁移 v" .. tostring(v) .. " 失败", tostring(err))
            end
        end
    end
end

-- 创建表 + 迁移追踪:user_version 低于当前则在此升级(目前 v1 仅补版本号,无结构性迁移)。
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
        migrate(db, ver)
        set_user_version(db, SCHEMA_VERSION)
    end
    return true
end

-- 仅打开连接(不做任何 schema 写入),供 open 复用。
-- 关键:不在打开时执行 CREATE TABLE / user_version 写入,保证随后
-- 的 integrity_check 是“无写入的只读核验”(作者意见 #5:发现损坏前绝不修改原库)。
local function do_open(path)
    local SQ3 = get_sq3()
    if not SQ3 then return nil end
    local ok, db = pcall(SQ3.open, path)
    if not ok or not db then return nil end
    return db
end

-- 完整性核验:PRAGMA integrity_check 返回 "ok" 即健康,否则收集损坏描述。
-- FAT32/SD 卡易损,KPW3 上收益最大。
-- 返回约定(与 open 的契约):
--   true                  → 健康(detail 为 nil)
--   false, detail         → 确认损坏(detail 为损坏描述,非异常)
--   抛错                  → 核验过程本身失败(prepare/step 异常、I/O、busy/locked、
--                          格式异常等)。open 必须按"过程失败"处理,绝不删库。
--   (db 为 nil 时返回 false,"no db",属调用方契约错误,不抛错。)
function ThoughtDB.integrity_check(db)
    if not db then return false, "no db" end
    local stmt = db:prepare("PRAGMA integrity_check")
    if not stmt then error("integrity_check prepare 失败") end
    local bad = {}
    local row = stmt:step()
    while row do
        if tostring(row[1] or "") ~= "ok" then bad[#bad + 1] = tostring(row[1]) end
        row = stmt:step()
    end
    stmt:close()
    if #bad == 0 then return true end
    return false, table.concat(bad, "; ")
end

-- 损坏隔离:把 .db/-wal/-shm 重命名为 .corrupt-<ts>,保留证据供诊断/人工恢复。
-- 用 os.rename(而非 os.remove)以保证想法数据可恢复,绝不静默丢弃。
-- 返回约定:成功返回 target 路径;主库重命名失败 / sidecar(源存在却)重命名失败
-- 均返回 nil,err(作者意见 #3:sidecar 隔离失败不得被吞掉当成成功)。
function ThoughtDB.isolate_corrupt(book_dir)
    local base = ThoughtDB.db_path(book_dir)
    local ts = os.time()
    local target = base .. ".corrupt-" .. tostring(ts)
    -- 主库必须先重命名成功,否则无隔离可言。
    if not os.rename(base, target) then return nil, "主库重命名失败" end
    -- 一并隔离 WAL/SHM:仅当源文件确实存在时才重命名;源不存在(无 WAL)属正常,
    -- 不算失败。源存在却重命名失败 → 归档不完整,返回错误(作者意见 #3)。
    for _, ext in ipairs({ "-wal", "-shm" }) do
        local src = base .. ext
        local probe = io.open(src, "r")
        if probe then
            probe:close()
            if not os.rename(src, target .. ext) then
                return nil, "sidecar 隔离失败: " .. src
            end
        end
    end
    -- 写入隔离标记:阻止 open() 在下次自动重建空库(作者意见 #2)。
    -- 旧想法不会因自动建空库而静默不可见;须显式恢复/重同步后才允许重建。
    local mk = io.open(base .. ".isolated", "w")
    if mk then mk:close() end
    return target
end

-- WAL 检查点:把 WAL 折叠进主库并截断,减小断电损坏面、回收 -wal/-shm 文件。
-- wal_checkpoint 返回三列 (busy, log_frames, checkpointed_frames):
--   busy=1 表示因其他连接忙而未完成;log!=checkpointed 表示未全部折叠。
-- 旧实现误用 row[3](checkpointed_frames)当状态,会把成功折叠非空 WAL 误判失败、
-- 把 busy 误判成功(作者意见 #4)。此处以 row[1](busy) 为准。
function ThoughtDB.checkpoint(db)
    if not db then return false, "no db" end
    local stmt = db:prepare("PRAGMA wal_checkpoint(TRUNCATE)")
    if not stmt then
        logger.warn("[撷思][ThoughtDB] checkpoint prepare 失败")
        return false, "prepare failed"
    end
    local ok, row = pcall(function() return stmt:step() end)
    pcall(function() stmt:close() end)
    if not ok or not row then
        logger.warn("[撷思][ThoughtDB] checkpoint step 失败")
        return false, "step failed"
    end
    -- 列序:busy, log_frames, checkpointed_frames
    local busy = tonumber(row[1]) or 1
    if busy ~= 0 then
        logger.warn("[撷思][ThoughtDB] checkpoint busy=", busy)
        return false, "checkpoint busy"
    end
    local log = tonumber(row[2]) or 0
    local ckpt = tonumber(row[3]) or 0
    if log ~= ckpt then
        logger.warn("[撷思][ThoughtDB] checkpoint 不完整 log=", log, " ckpt=", ckpt)
        return false, "checkpoint 不完整"
    end
    return true
end

-- 隔离态判定:主库已被重命名为 .corrupt-*,且写入了 .isolated 标记。
-- 此时禁止 open() 自动重建空库(作者意见 #2):否则旧想法会静默变成不可见,
-- 须显式恢复或重新同步后才允许重建。
local function is_isolated(book_dir)
    local base = ThoughtDB.db_path(book_dir)
    -- 主库仍存在 → 未隔离(健康或首次打开)。
    local probe = io.open(base, "r")
    if probe then probe:close(); return false end
    -- 主库缺失但存在隔离标记 → 已隔离。
    local mk = io.open(base .. ".isolated", "r")
    if mk then mk:close(); return true end
    return false
end

function ThoughtDB.open(book_dir)
    if type(book_dir) ~= "string" or book_dir == "" then return nil end
    local SQ3 = get_sq3()
    if not SQ3 then return nil end
    U.mkdir(book_dir)
    -- 隔离态:主库已重命名为 .corrupt-*,禁止自动重建空库(作者意见 #2)。
    if is_isolated(book_dir) then
        return nil, "数据库已被隔离(损坏),禁止自动重建;请恢复或重新同步"
    end
    local path = ThoughtDB.db_path(book_dir)
    local db = do_open(path)
    if not db then return nil end
    -- 打开即核验完整性:先做一次无写入的只读核验(作者意见 #5),
    -- 确认健康后再做连接级 PRAGMA + schema 初始化 / user_version 写入,绝不先改原库。
    local ic_ok, healthy, detail = pcall(ThoughtDB.integrity_check, db)
    if not ic_ok then
        logger.warn("[撷思][ThoughtDB] integrity_check 过程失败,保留原库", path, tostring(healthy))
        ThoughtDB.close_no_checkpoint(db)  -- 隔离前不 checkpoint(作者意见 #1)
        return nil, "integrity_check 过程失败: " .. tostring(healthy)
    elseif healthy ~= true then
        logger.warn("[撷思][ThoughtDB] integrity_check 检出损坏,隔离而非删除", path, tostring(detail))
        ThoughtDB.close_no_checkpoint(db)  -- 隔离前不 checkpoint(作者意见 #1)
        local iso, iso_err = ThoughtDB.isolate_corrupt(book_dir)
        if iso then
            return nil, "已隔离损坏库至 " .. iso .. ";想法可由本地注入源(离线缓存)重建"
        end
        return nil, "损坏库隔离失败(" .. tostring(iso_err or "无法重命名") .. ");请手动检查 " .. path
    end
    -- 健康:此时才设置连接级 PRAGMA + schema 初始化 / user_version 写入。
    pcall(function() db:exec("PRAGMA journal_mode=WAL") end)
    pcall(function() db:exec("PRAGMA synchronous=NORMAL") end)
    if not ensure_schema(db) then
        ThoughtDB.close_no_checkpoint(db)
        return nil, "schema 初始化失败"
    end
    -- 健康库建立成功:清理可能残留的隔离标记(作者意见 #2)。
    -- 仅当标记确实存在时才删除,避免对不存在文件做无效 os.remove。
    pcall(function()
        local mk = io.open(path .. ".isolated", "r")
        if mk then mk:close(); os.remove(path .. ".isolated") end
    end)
    return db
end

function ThoughtDB.close(db)
    if db then
        pcall(ThoughtDB.checkpoint, db)
        pcall(function() db:close() end)
    end
end

-- 仅关闭句柄,不做 WAL checkpoint。用于损坏 / 过程失败路径,避免在隔离前
-- 修改或截断主库 / WAL,保证 .corrupt-* 是原始损坏证据(作者意见 #1)。
function ThoughtDB.close_no_checkpoint(db)
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
