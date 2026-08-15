-- ④ DB 完整性校验:integrity_check / checkpoint / 迁移追踪(user_version) / 损坏隔离。
-- 作者评审意见:open 必须区分"过程失败"与"确认损坏"——
--   过程失败(I/O、busy/locked、prepare/step 异常):保留原库,绝不删;
--   确认损坏:隔离(.corrupt-*)而非删除,绝不静默重建空库。
-- stubs 的 SQLite mock 已支持 PRAGMA integrity_check(返回 {"ok"})、
-- wal_checkpoint(返回 {0,0,0}) 与 user_version 读写。
local ThoughtDB = require("pickthought.thought_db")
local SQ3 = require("lua-ljsqlite3/init")
local lfs = require("lfs")

local function fresh_db()
    SQ3._reset()
    return ThoughtDB.open("/book/dir")
end

-- 单测内 spy os.rename / os.remove,返回计数与还原闭包,用于断言"不删库/确实隔离"。
-- 同时记录首个 rename 目标(first_target)与全部 (from,to) 对,供真实文件测试核对。
local function spy_os()
    local c = { rename = 0, remove = 0, first_target = nil, renames = {} }
    local o_rn, o_rm = os.rename, os.remove
    os.rename = function(a, b)
        c.rename = c.rename + 1
        c.renames[#c.renames + 1] = { a, b }
        if c.first_target == nil and b then c.first_target = b end
        return o_rn(a, b)  -- 仍执行真实重命名,文件真的被移动
    end
    os.remove = function(a) c.remove = c.remove + 1; return o_rm(a) end
    return c, function() os.rename, os.remove = o_rn, o_rm end
end

-- 真实临时目录(用于验证 os.rename 真的移动了文件,而非只调用了 API)。
-- 跨平台创建(lfs.mkdir,不依赖 Windows mkdir)。
local function tmp_dir()
    local d = "tests/_iso_tmp_" .. tostring(os.time()) .. "_" .. tostring(math.floor(math.random() * 1e7))
    pcall(lfs.mkdir, d)
    return d
end
-- 跨平台递归删除(不依赖 Windows rmdir /s /q;用 lfs 遍历后逐文件/目录删除)。
local function rm_tmp(d)
    local function remove_recursive(path)
        local mode = lfs.attributes(path, "mode")
        if mode == "directory" then
            for name in lfs.dir(path) do
                if name ~= "." and name ~= ".." then
                    remove_recursive(path .. "/" .. name)
                end
            end
            lfs.rmdir(path)
        else
            os.remove(path)
        end
    end
    pcall(remove_recursive, d)
end
-- 真实文件中是否仍存在(存在返回 true)。
local function file_exists(p)
    local f = io.open(p, "r"); if f then f:close(); return true end
    return false
end

T.case("integrity_check 健康库返回 true", function()
    local db = fresh_db()
    T.ok(db ~= nil, "open 成功")
    local ok, msg = ThoughtDB.integrity_check(db)
    T.ok(ok == true, "integrity_check 返回 true")
    T.ok(msg == nil, "健康时无错误描述")
    ThoughtDB.close(db)
end)

T.case("integrity_check 对 nil db 返回 false", function()
    local ok, msg = ThoughtDB.integrity_check(nil)
    T.ok(ok == false, "nil db → false")
    T.ok(msg ~= nil, "带错误描述")
end)

T.case("checkpoint 不抛错且返回 true(读取真实 status=0)", function()
    local db = fresh_db()
    T.ok(ThoughtDB.checkpoint(db) == true, "checkpoint 返回 true")
    ThoughtDB.close(db)  -- close 内部也会 checkpoint
end)

T.case("open 写入 user_version 迁移标记(SCHEMA_VERSION=1)", function()
    local db = fresh_db()
    T.ok(db ~= nil, "open 成功")
    local store = SQ3._stores[ThoughtDB.db_path("/book/dir")]
    T.ok(store ~= nil, "store 存在")
    T.eq(store.user_version, 1, "user_version 写入为 1")
    ThoughtDB.close(db)
end)

T.case("open 健康库:正常返回 db,不触发隔离/删除", function()
    local c, restore = spy_os()
    local db = ThoughtDB.open("/book/healthy")
    restore()
    T.ok(db ~= nil, "健康库 open 成功")
    T.ok(c.rename == 0 and c.remove == 0, "健康库不隔离不删除")
    if db then ThoughtDB.close(db) end
end)

-- 真实临时文件测试:验证 os.rename 真的把主库 / WAL / SHM 移动到了 .corrupt-*,
-- 而非只调用了 API(作者意见 #6:旧测试 os.rename 实际失败也能通过)。
T.case("open 遇确认损坏:真实文件被隔离到 .corrupt-*,绝不删除", function()
    local dir = tmp_dir()
    for _, name in ipairs({ "thoughts.db", "thoughts.db-wal", "thoughts.db-shm" }) do
        local f = io.open(dir .. "/" .. name, "w"); f:write("x"); f:close()
    end
    local orig = ThoughtDB.integrity_check
    ThoughtDB.integrity_check = function(_d) return false, "mock corrupt" end
    local c, restore = spy_os()
    local db, err = ThoughtDB.open(dir)
    restore()
    ThoughtDB.integrity_check = orig
    T.ok(db == nil, "确认损坏 → open 返回 nil(不静默重建空库)")
    T.ok(err ~= nil and tostring(err):find("隔离"), "错误描述含'隔离'")
    T.ok(c.remove == 0, "绝不调用 os.remove 删除想法数据")
    -- 原主库 / WAL / SHM 应已不在原路径。
    T.ok(not file_exists(dir .. "/thoughts.db"), "原 thoughts.db 已移走")
    T.ok(not file_exists(dir .. "/thoughts.db-wal"), "原 -wal 已移走")
    T.ok(not file_exists(dir .. "/thoughts.db-shm"), "原 -shm 已移走")
    -- 首个 rename 目标即 .corrupt 主库;其 -wal/-shm 兄弟与 .isolated 标记都应存在。
    T.ok(c.first_target ~= nil, "记录了主库隔离目标")
    if c.first_target then
        T.ok(file_exists(c.first_target), "主库 .corrupt-* 真实存在")
        T.ok(file_exists(c.first_target .. "-wal"), "sidecar .corrupt-*-wal 真实存在")
        T.ok(file_exists(c.first_target .. "-shm"), "sidecar .corrupt-*-shm 真实存在")
        T.ok(file_exists(dir .. "/thoughts.db.isolated"), ".isolated 隔离标记已写入")
    end
    rm_tmp(dir)
end)

-- 作者意见 #2:损坏被隔离后,主库消失且写入 .isolated 标记;
-- 下次 open() 必须禁止自动重建空库(否则旧想法静默不可见)。
T.case("open 隔离态:禁止自动重建空库,返回 nil", function()
    local dir = tmp_dir()
    -- 仅写隔离标记,不写 thoughts.db(模拟隔离后主库已被移走)。
    local mk = io.open(dir .. "/thoughts.db.isolated", "w"); mk:close()
    SQ3._reset()
    local db, err = ThoughtDB.open(dir)
    T.ok(db == nil, "隔离态 → open 返回 nil(不自动建库)")
    T.ok(err ~= nil and tostring(err):find("隔离"), "错误描述含'隔离'")
    -- 关键:不得自动创建空库(既没有真实文件,也没有内存 store)。
    T.ok(not file_exists(dir .. "/thoughts.db"), "未自动创建真实 thoughts.db")
    T.ok(SQ3._stores[dir .. "/thoughts.db"] == nil, "未自动创建内存库(无写入)")
    -- 隔离标记保留,等待显式恢复/重同步。
    T.ok(file_exists(dir .. "/thoughts.db.isolated"), "隔离标记保留")
    rm_tmp(dir)
end)

-- 作者意见 #4:wal_checkpoint 返回 (busy, log, checkpointed),应以 row[1](busy) 为准。
local function fake_db_with_checkpoint(row)
    return {
        prepare = function(_, sql)
            if sql:find("wal_checkpoint") then
                return { step = function() return row end, close = function() end }
            end
            return { step = function() return nil end, close = function() end }
        end,
        close = function() end,
        exec = function() end,
    }
end
T.case("checkpoint:busy=1 判失败(不再误判成功)", function()
    local ok, err = ThoughtDB.checkpoint(fake_db_with_checkpoint({ 1, 5, 5 }))
    T.ok(ok == false, "busy → checkpoint 失败")
    T.ok(tostring(err):find("busy"), "错误含 busy")
end)
T.case("checkpoint:log!=checkpointed 判不完整", function()
    local ok, err = ThoughtDB.checkpoint(fake_db_with_checkpoint({ 0, 5, 3 }))
    T.ok(ok == false, "未全部折叠 → checkpoint 失败")
    T.ok(tostring(err):find("不完整"), "错误含 不完整")
end)
T.case("checkpoint:busy=0 且全部折叠 → 成功", function()
    local ok, err = ThoughtDB.checkpoint(fake_db_with_checkpoint({ 0, 0, 0 }))
    T.ok(ok == true, "busy=0 且 log==ckpt → checkpoint 成功")
end)

-- 作者意见 #3:isolate_corrupt 必须逐个检查 sidecar 重命名,源存在却失败时返回错误。
T.case("isolate_corrupt:主库+sidecar 真实移动并写 .isolated 标记", function()
    local dir = tmp_dir()
    for _, name in ipairs({ "thoughts.db", "thoughts.db-wal", "thoughts.db-shm" }) do
        local f = io.open(dir .. "/" .. name, "w"); f:write("x"); f:close()
    end
    local target, err = ThoughtDB.isolate_corrupt(dir)
    T.ok(target ~= nil, "隔离成功返回目标路径")
    T.ok(not file_exists(dir .. "/thoughts.db"), "主库已移走")
    T.ok(not file_exists(dir .. "/thoughts.db-wal"), "-wal 已移走")
    T.ok(not file_exists(dir .. "/thoughts.db-shm"), "-shm 已移走")
    T.ok(target and file_exists(target), "主库 .corrupt-* 存在")
    T.ok(target and file_exists(target .. "-wal"), "sidecar -wal 存在")
    T.ok(target and file_exists(target .. "-shm"), "sidecar -shm 存在")
    T.ok(file_exists(dir .. "/thoughts.db.isolated"), ".isolated 标记已写入")
    rm_tmp(dir)
end)
T.case("isolate_corrupt:sidecar 重命名失败返回 nil(不吞错)", function()
    local dir = tmp_dir()
    for _, name in ipairs({ "thoughts.db", "thoughts.db-wal" }) do
        local f = io.open(dir .. "/" .. name, "w"); f:write("x"); f:close()
    end
    local o_rn = os.rename
    os.rename = function(a, b)
        if b:find("-wal$") then return nil, "mock wal fail" end
        return o_rn(a, b)
    end
    local target, err = ThoughtDB.isolate_corrupt(dir)
    os.rename = o_rn
    T.ok(target == nil, "sidecar 隔离失败 → 返回 nil")
    T.ok(err ~= nil and tostring(err):find("sidecar"), "错误含 sidecar")
    rm_tmp(dir)
end)

T.case("open 遇核验过程失败(busy/prepare 异常):保留原库,不删", function()
    local orig = ThoughtDB.integrity_check
    ThoughtDB.integrity_check = function(_d) error("mock process failure: SQLITE_BUSY") end
    local c, restore = spy_os()
    local db, err = ThoughtDB.open("/busy/book")
    restore()
    T.ok(db == nil, "过程失败 → open 返回 nil")
    T.ok(err ~= nil and tostring(err):find("过程失败"), "错误描述含'过程失败'")
    T.ok(c.rename == 0, "过程失败不触发隔离/重命名")
    T.ok(c.remove == 0, "过程失败绝不删除想法数据")
    ThoughtDB.integrity_check = orig
end)

T.case("open 隔离失败(无法重命名)时显式报错,不静默空库", function()
    local orig = ThoughtDB.integrity_check
    ThoughtDB.integrity_check = function(_d) return false, "mock corrupt" end
    local o_rn = os.rename
    os.rename = function() return nil, "mock rename fail" end  -- 模拟重命名失败
    local db, err = ThoughtDB.open("/isolatefail/book")
    os.rename = o_rn
    T.ok(db == nil, "隔离失败 → open 返回 nil")
    T.ok(err ~= nil and tostring(err):find("隔离失败"), "错误描述含'隔离失败'")
    ThoughtDB.integrity_check = orig
end)

-- 作者第二轮复审 2026-08-15 失败安全边界:sidecar 移动失败后二次 open()
-- 必须仍被阻断且不自动创建新空库(标记先行 → 标记已留 → 阻断)。
-- 注意:pcall 包裹测试体,确保任何断言失败时仍 restore 全局 patch,
-- 不污染后续用例(本文件在 test_thoughts_lru 之前运行)。
T.case("隔离中途 sidecar 失败:二次 open 仍阻断且不建空库", function()
    local dir = tmp_dir()
    for _, name in ipairs({ "thoughts.db", "thoughts.db-wal", "thoughts.db-shm" }) do
        local f = io.open(dir .. "/" .. name, "w"); f:write("x"); f:close()
    end
    local orig = ThoughtDB.integrity_check
    local o_rn = os.rename
    local function restore()
        ThoughtDB.integrity_check = orig
        os.rename = o_rn
    end
    local ok, perr = pcall(function()
        -- 第一次:确认损坏 → 隔离(标记先行,主库移入 .corrupt-*,但 -wal 移动失败)。
        ThoughtDB.integrity_check = function(_d) return false, "mock corrupt" end
        os.rename = function(a, b)
            if b:find("-wal$") then return nil, "mock wal fail" end
            return o_rn(a, b)
        end
        local db1, err1 = ThoughtDB.open(dir)
        T.ok(db1 == nil, "首次隔离因 sidecar 失败返回 nil")
        T.ok(file_exists(dir .. "/thoughts.db.isolated"), "隔离标记已在主库移动前写入(阻断)")
        T.ok(not file_exists(dir .. "/thoughts.db"), "主库已移入 .corrupt-*(损坏证据保留,不回滚)")
        -- 第二次 open:标记存在 → 阻断,不建空库(标记在 do_open 前即阻断)。
        SQ3._reset()
        local db2, err2 = ThoughtDB.open(dir)
        T.ok(db2 == nil, "二次 open 被隔离标记阻断,返回 nil")
        T.ok(err2 ~= nil and tostring(err2):find("隔离"), "二次 open 错误含'隔离'")
        T.ok(SQ3._stores[dir .. "/thoughts.db"] == nil, "二次 open 未创建内存库(标记在 do_open 前阻断)")
        T.ok(file_exists(dir .. "/thoughts.db.isolated"), "隔离标记仍保留(保持阻断)")
    end)
    restore()
    rm_tmp(dir)
    if not ok then error(perr) end
end)

-- 作者第二轮复审 2026-08-15 失败安全边界:.isolated 标记写入失败时,
-- 不得移动主库,且后续 open() 不得自动建空库(保护原库)。
T.case("隔离标记写入失败:不移动主库,二次 open 不建空库", function()
    local dir = tmp_dir()
    local f = io.open(dir .. "/thoughts.db", "w"); f:write("x"); f:close()
    -- 让 .isolated 写入失败:io.open 对 .isolated 返回 nil(模拟不可写)。
    local orig_ioopen = io.open
    local orig = ThoughtDB.integrity_check
    local function restore()
        io.open = orig_ioopen
        ThoughtDB.integrity_check = orig
    end
    local ok, perr = pcall(function()
        io.open = function(p, mode)
            if p:find("%.isolated$") then return nil end
            return orig_ioopen(p, mode)
        end
        ThoughtDB.integrity_check = function(_d) return false, "mock corrupt" end
        -- 第一次 open:确认损坏 → 隔离(标记写入失败 → 中止,主库不移动)。
        local db1, err1 = ThoughtDB.open(dir)
        T.ok(db1 == nil, "标记写入失败 → 隔离中止,open 返回 nil")
        T.ok(file_exists(dir .. "/thoughts.db"), "主库未被移动(标记失败即中止)")
        -- 第二次 open:仍无标记(主库仍在),再次走损坏路径 → 标记仍失败 → open 拒绝返回可用库。
        SQ3._reset()
        local db2, err2 = ThoughtDB.open(dir)
        T.ok(db2 == nil, "二次 open 仍拒绝返回可用库(不建空库)")
        T.ok(not file_exists(dir .. "/thoughts.db.isolated"), "仍无隔离标记")
    end)
    restore()
    rm_tmp(dir)
    if not ok then error(perr) end
end)

-- 作者第二轮复审 2026-08-15 唯一备份名:预建同名 .corrupt-* 时,新的隔离
-- 操作必须换名,不得覆盖旧备份(防 Kindle 同秒重复隔离丢证据)。
T.case("隔离目标名唯一:预建同名 .corrupt-* 不被覆盖", function()
    local dir = tmp_dir()
    for _, name in ipairs({ "thoughts.db", "thoughts.db-wal", "thoughts.db-shm" }) do
        local f = io.open(dir .. "/" .. name, "w"); f:write("x"); f:close()
    end
    -- 预建一个旧备份(同 ts 前缀),里面放"OLD"标记。
    local base = dir .. "/thoughts.db"
    local old_ts = os.time()
    local old_target = base .. ".corrupt-" .. tostring(old_ts) .. "-0"
    local of = io.open(old_target, "w"); of:write("OLD BACKUP"); of:close()
    T.ok(file_exists(old_target), "预建旧备份存在")
    -- 触发隔离:unique_corrupt_target 应避开已存在的 old_target,换新名。
    local target, err = ThoughtDB.isolate_corrupt(dir)
    T.ok(target ~= nil, "隔离成功")
    T.ok(target ~= old_target, "新目标名不同于旧备份(避免覆盖)")
    T.ok(file_exists(old_target), "旧备份未被覆盖,仍保留")
    T.ok(file_exists(target), "新隔离目标存在")
    rm_tmp(dir)
end)
