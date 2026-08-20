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
    -- 返回格式校验(作者第4轮意见 #3):integrity_check 必须至少返回一行;
    -- 否则视为核验过程异常(格式异常),按"过程失败"处理(保留原库、绝不触发隔离)。
    if not row or type(row) ~= "table" then
        pcall(function() stmt:close() end)
        error("integrity_check 返回格式异常:缺少结果行")
    end
    while row do
        if type(row) ~= "table" then
            pcall(function() stmt:close() end)
            error("integrity_check 返回格式异常:结果行非表")
        end
        local v = row[1]
        if type(v) ~= "string" then
            pcall(function() stmt:close() end)
            error("integrity_check 返回格式异常:首列非字符串")
        end
        if v ~= "ok" then bad[#bad + 1] = v end
        row = stmt:step()
    end
    pcall(function() stmt:close() end)
    if #bad == 0 then return true end
    return false, table.concat(bad, "; ")
end

-- 原子无覆盖目标预留:优先用 C.open(O_CREAT|O_EXCL) 在 Linux(含 Kindle ARM Linux)
-- 上原子占用目标名——"探测即占用",彻底消除"先探测再 os.rename"的 TOCTOU 竞态,
-- 绝不会覆盖已有 .corrupt-* 备份(作者第4轮意见 #1)。仅 Linux + ffi 可用时启用;
-- 非 Linux / 无 ffi(如 Windows 测试环境)退化为 probe+rename,同样能正确跳过已存在目标。
local ffi = nil
pcall(function() ffi = require("ffi") end)
local ATOMIC_OPEN, ATOMIC_FLAGS, ATOMIC_MODE
-- 修正(作者第5轮意见 #1):ffi.abi("os") 返回布尔值而非字符串,导致 Kindle Linux 永远
-- 走降级路径、TOCTOU 竞态实际仍存在。正确判断应用 ffi.os(字符串:"Linux"/"Windows"/...)。
-- 仅 Linux + ffi 可用时启用原子路径(作者第5轮意见 #2:必须补 ffi.cdef 声明 open/close,
-- 否则加载期报 "missing declaration for symbol 'open'";cdef 冲突则退化为 nil → 降级路径)。
if ffi and ffi.os == "Linux" then
    local ok_cdef = pcall(ffi.cdef, [[
        int open(const char *pathname, int flags, int mode);
        int close(int fd);
    ]])
    if ok_cdef then
        ATOMIC_OPEN = ffi.C.open          -- open(2)
        ATOMIC_FLAGS = 0x40 + 0x80 + 0x1  -- O_CREAT | O_EXCL | O_WRONLY
        ATOMIC_MODE = 0x180              -- 0600
    end
end

-- 原子独占创建目标(空文件)。成功返回 true(目标名已独占占有,可安全移入主库内容);
-- 已存在/权限失败返回 false;ffi 不可用时返回 nil(交由调用方退化处理)。
local function atomic_claim(cand)
    if not ATOMIC_OPEN then return nil end
    local fd = ATOMIC_OPEN(cand, ATOMIC_FLAGS, ATOMIC_MODE)
    local n = tonumber(fd) or -1
    if n >= 0 then
        if ffi.C.close then pcall(ffi.C.close, fd) end
        return true
    end
    return false
end

-- 无覆盖目标预留:先原子占用候选目标(已存在则跳过换名),再 os.rename 主库内容填入。
-- 原子路径下候选是我们刚独占的空占位,rename 覆盖它不会触碰任何真实备份;
-- 退化路径下先 probe 存在即跳过。任一步失败均持续换名重试,绝不返回未经确认的候选
-- (作者第3轮意见 #2 + 第4轮意见 #1:消除竞态隐患,序号到顶后再次确认目标为空)。
-- 仅在 rename 真正成功时返回占用名;极端持续失败时返回 nil。
local function reserve_corrupt_main(base)
    local ts = os.time()
    local salt = 0
    local attempts = 0
    while attempts < 100000 do
        attempts = attempts + 1
        local cand = base .. ".corrupt-" .. tostring(ts) .. "-" .. tostring(salt)
        local claimed
        local ac = atomic_claim(cand)
        if ac == true then
            claimed = true   -- 已原子独占 cand(空文件),可安全移入主库内容。
        elseif ac == false then
            claimed = false  -- cand 已存在(原子创建失败)→ 跳过换名,绝不覆盖。
        else
            -- 无 ffi / 未知平台:退化 probe——不存在才允许 rename 占用。
            local probe = io.open(cand, "r")
            if probe then probe:close(); claimed = false
            else claimed = true end
        end
        if claimed then
            -- cand 已确认空闲:把主库内容移入(原子路径下覆盖我们刚独占的空占位,
            -- 不会触碰任何真实备份)。rename 失败(极小概率权限)则清理空占位。
            if os.rename(base, cand) then return cand end
            os.remove(cand)
        end
        salt = salt + 1
        if salt > 9999 then ts = os.time(); salt = 0 end  -- 安全阀:换时间戳继续,再次确认
    end
    return nil
end

-- 区分"文件不存在"与"因权限/I-O 无法检查"(作者第3轮意见 #3)。
-- lfs(libs/libkoreader-lfs)在 KOReader 运行时可用,其 attributes 的错误码可区分
-- 二者;测试环境无 lfs 时退化为 io.open 探测(此时无法区分,保守按"可检查"处理)。
-- 返回 (exists, state):state 为 "uncheckable" 表示无法确认(权限/IO),调用方应保守处理。
local function path_exists_distinct(path)
    local lfsm = package.loaded["libs/libkoreader-lfs"]
    if lfsm and lfsm.attributes then
        local attr, err = lfsm.attributes(path)
        if attr then return true, nil end
        if err and tostring(err):lower():find("no such file") then
            return false, nil
        end
        return false, "uncheckable"
    end
    local f = io.open(path, "r")
    if f then f:close(); return true, nil end
    return false, nil
end

-- 写入并校验隔离标记:.isolated 存在即视为已隔离,即使主库仍残留也阻断自动重建
-- (防部分隔离态 / 标记先行阶段静默建空库)。返回是否写入成功。
local function write_isolated_marker(base)
    local f = io.open(base .. ".isolated", "w")
    if not f then return false end
    f:close()
    local check = io.open(base .. ".isolated", "r")  -- 校验确实落盘
    if not check then return false end
    check:close()
    return true
end

-- 损坏隔离:把 .db/-wal/-shm 重命名为 .corrupt-<ts>-<salt>,保留证据供诊断/人工恢复。
-- 用 os.rename(而非 os.remove)以保证想法数据可恢复,绝不静默丢弃。
-- 失败安全边界(作者第二轮复审 2026-08-15):
--   1) 标记先行:先写并校验 .isolated,标记失败则不得移动主库,直接报错;
--   2) 主库/WAL/SHM 逐个移动,每步校验返回值;
--   3) 任一步失败保留隔离标记(阻断后续自动建库);sidecar 失败尝试回滚主库,
--      回滚失败仍保持阻断;
--   4) 核心:无论哪步失败,下次 open() 都不得得到新空库。
-- 返回约定:成功返回 target 路径;否则返回 nil,err。
function ThoughtDB.isolate_corrupt(book_dir)
    local base = ThoughtDB.db_path(book_dir)
    -- 主库必须存在才隔离;无法确认主库状态时保守报错,绝不静默跳过(避免损坏证据丢失)。
    local main_exists, main_state = path_exists_distinct(base)
    if not main_exists then
        if main_state == "uncheckable" then
            return nil, "主库状态无法确认(权限/IO),隔离中止以保护原库"
        end
        return nil, "主库不存在,无需隔离"
    end
    -- 1) 标记先行:标记写入失败 → 中止,绝不移动主库。
    if not write_isolated_marker(base) then
        return nil, "隔离标记写入失败,中止隔离以保护原库"
    end
    -- 2) 主库移动(以 rename 自身预留唯一目标,消除探测后 rename 竞态)。
    local target = reserve_corrupt_main(base)
    if not target then
        -- 主库移动失败:标记已就位(阻断),不回滚标记,直接报错。
        return nil, "主库重命名失败(隔离标记已就位,阻断自动重建)"
    end
    -- 3) sidecar 逐个移动;源存在(或无法确认)却失败 → 归档不完整,返回错误。
    --    绝不把"无法检查"的 sidecar 误判为不存在而留下未归档文件(作者第3轮意见 #3)。
    for _, ext in ipairs({ "-wal", "-shm" }) do
        local src = base .. ext
        local exists, state = path_exists_distinct(src)
        if exists or state == "uncheckable" then
            if not os.rename(src, target .. ext) then
                -- sidecar 隔离失败:保留标记(阻断自动重建);主库已留在 .corrupt-*
                -- 作为损坏证据,不回滚(避免把损坏文件移回原处掩盖证据)。
                return nil, "sidecar 隔离失败: " .. src
            end
        end
    end
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

-- 隔离态判定改由 open() 内直接调用 path_exists_distinct 完成(区分"确不存在"与
-- "无法确认",作者第4轮意见 #2),不再保留单独的 is_isolated 函数。

function ThoughtDB.open(book_dir)
    if type(book_dir) ~= "string" or book_dir == "" then return nil end
    local SQ3 = get_sq3()
    if not SQ3 then return nil end
    U.mkdir(book_dir)
    local base = ThoughtDB.db_path(book_dir)
    -- 隔离标记:区分"确不存在"与"无法确认"(作者第4轮意见 #2)。
    -- 无法确认(权限/IO)时保守阻断,避免掩盖隔离态 / 损坏证据。
    local iso_present, iso_state = path_exists_distinct(base .. ".isolated")
    if iso_present then
        return nil, "数据库已被隔离(损坏),禁止自动重建;请恢复或重新同步"
    end
    if iso_state == "uncheckable" then
        return nil, "隔离标记状态无法确认(权限/IO),阻断自动重建以保护数据"
    end
    -- 主库存在性:区分"明确不存在"与"无法确认"(作者第4轮意见 #2)。
    -- 无法确认 → 报错阻断,绝不交给 SQLite 自动创建空库。
    local main_present, main_state = path_exists_distinct(base)
    if main_state == "uncheckable" then
        return nil, "主库状态无法确认(权限/IO),阻断自动重建以保护数据"
    end
    if not main_present then
        -- 主库缺失:检查是否有孤立 sidecar(-wal/-shm)。孤儿 sidecar 表明上次写入中途
        -- 崩溃,主库可能已损坏/丢失——此时绝不允许 SQLite 静默新建空库(作者第4轮意见 #2)。
        for _, ext in ipairs({ "-wal", "-shm" }) do
            local ex, st = path_exists_distinct(base .. ext)
            if ex or st == "uncheckable" then
                return nil, "主库缺失但存在孤立 sidecar(" .. ext .. "),阻断自动重建"
            end
        end
        -- 主库确缺失且无 sidecar:允许 SQLite 正常新建(首次打开一本书)。
    end
    local db = do_open(base)
    if not db then return nil end
    -- 打开即核验完整性:先做一次无写入的只读核验(作者意见 #5),
    -- 确认健康后再做连接级 PRAGMA + schema 初始化 / user_version 写入,绝不先改原库。
    local ic_ok, healthy, detail = pcall(ThoughtDB.integrity_check, db)
    if not ic_ok then
        logger.warn("[撷思][ThoughtDB] integrity_check 过程失败,保留原库", base, tostring(healthy))
        ThoughtDB.close_no_checkpoint(db)  -- 隔离前不 checkpoint(作者意见 #1)
        return nil, "integrity_check 过程失败: " .. tostring(healthy)
    elseif healthy ~= true then
        logger.warn("[撷思][ThoughtDB] integrity_check 检出损坏,隔离而非删除", base, tostring(detail))
        ThoughtDB.close_no_checkpoint(db)  -- 隔离前不 checkpoint(作者意见 #1)
        local iso, iso_err = ThoughtDB.isolate_corrupt(book_dir)
        if iso then
            return nil, "已隔离损坏库至 " .. iso .. ";想法可由本地注入源(离线缓存)重建"
        end
        return nil, "损坏库隔离失败(" .. tostring(iso_err or "无法重命名") .. ");请手动检查 " .. base
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
        local mk = io.open(base .. ".isolated", "r")
        if mk then mk:close(); os.remove(base .. ".isolated") end
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
