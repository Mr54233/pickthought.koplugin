-- ④ DB 完整性校验:integrity_check / checkpoint / 迁移追踪(user_version) / 损坏隔离。
-- 作者评审意见:open 必须区分"过程失败"与"确认损坏"——
--   过程失败(I/O、busy/locked、prepare/step 异常):保留原库,绝不删;
--   确认损坏:隔离(.corrupt-*)而非删除,绝不静默重建空库。
-- stubs 的 SQLite mock 已支持 PRAGMA integrity_check(返回 {"ok"})、
-- wal_checkpoint(返回 {0,0,0}) 与 user_version 读写。
local ThoughtDB = require("pickthought.thought_db")
local SQ3 = require("lua-ljsqlite3/init")

-- 跨平台临时目录(替代 lfs):CI/Linux 用 POSIX,Windows 回退 cmd(作者第3轮意见 #1:
-- 测试不得依赖 lfs,也避免仅依赖 Windows rmdir /s /q)。
local SEP = package.config:sub(1, 1)  -- "\\" on Windows
local function sh(cmd) return os.execute(cmd) == 0 end
local function mkdir_p(d)
    if SEP == "\\" then return sh('cmd /c mkdir "' .. d .. '" >nul 2>nul') end
    return sh('mkdir -p "' .. d .. '" 2>/dev/null')
end
local function rm_rf(d)
    if SEP == "\\" then return sh('cmd /c rmdir /s /q "' .. d .. '" >nul 2>nul') end
    return sh('rm -rf "' .. d .. '" 2>/dev/null')
end

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
local function tmp_dir()
    local d = "tests/_iso_tmp_" .. tostring(os.time()) .. "_" .. tostring(math.floor(math.random() * 1e7))
    mkdir_p(d)
    return d
end
-- 删除真实临时目录(跨平台,不依赖 lfs / Windows rmdir /s /q)。
local function rm_tmp(d) rm_rf(d) end
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
    -- 触发隔离:reserve_corrupt_main 应避开已存在的 old_target,换新名。
    local target, err = ThoughtDB.isolate_corrupt(dir)
    T.ok(target ~= nil, "隔离成功")
    T.ok(target ~= old_target, "新目标名不同于旧备份(避免覆盖)")
    T.ok(file_exists(old_target), "旧备份未被覆盖,仍保留")
    T.ok(file_exists(target), "新隔离目标存在")
    rm_tmp(dir)
end)

-- 作者第3轮意见 #4:直接覆盖 integrity_check 的 prepare/step 异常路径,
-- 而非整体替换函数。命中 `if not stmt then error(...)` 与 stmt:step() 抛错透传。
T.case("integrity_check:prepare 返回 nil 直接抛错(prepare 异常路径)", function()
    local fake = { prepare = function() return nil end, close = function() end }
    local ok, err = pcall(ThoughtDB.integrity_check, fake)
    T.ok(not ok, "prepare 返回 nil → integrity_check 抛错")
    T.ok(err ~= nil and tostring(err):find("prepare"), "错误含 prepare")
end)

T.case("integrity_check:stmt:step 抛错被透传为过程失败", function()
    local fake = {
        prepare = function()
            return { step = function() error("SQLITE_IOERR") end, close = function() end }
        end,
        close = function() end,
    }
    local ok, err = pcall(ThoughtDB.integrity_check, fake)
    T.ok(not ok, "step 抛错 → integrity_check 抛错(被 open 当作过程失败)")
    T.ok(err ~= nil and tostring(err):find("SQLITE_IOERR"), "透传底层错误")
end)

-- 作者第3轮意见 #3:sidecar 无法检查(权限/IO)时不能误判为"不存在"而静默跳过,
-- 必须保守地尝试归档,失败时返回错误(避免留下未归档文件)。
T.case("隔离:sidecar 无法检查(权限/IO)时保守报错,不静默跳过", function()
    local dir = tmp_dir()
    for _, name in ipairs({ "thoughts.db", "thoughts.db-wal", "thoughts.db-shm" }) do
        local f = io.open(dir .. "/" .. name, "w"); f:write("x"); f:close()
    end
    -- 注入 mock lfs:对 -shm 返回无法检查(Permission denied),模拟权限/IO 错误。
    local old_lfs = package.loaded["libs/libkoreader-lfs"]
    package.loaded["libs/libkoreader-lfs"] = {
        attributes = function(p)
            if p:find("%-shm$") then return nil, "Permission denied" end
            return { mode = "file" }
        end,
    }
    -- -shm 归档失败(模拟):无法检查 → 保守尝试 → 失败 → 必须报错而非跳过。
    local o_rn = os.rename
    os.rename = function(a, b)
        if b:find("-shm$") then return nil, "mock shm fail" end
        return o_rn(a, b)
    end
    local target, err = ThoughtDB.isolate_corrupt(dir)
    os.rename = o_rn
    package.loaded["libs/libkoreader-lfs"] = old_lfs
    T.ok(target == nil, "无法确认 sidecar 状态时隔离报错(不静默跳过)")
    T.ok(err ~= nil and tostring(err):find("sidecar"), "错误含 sidecar")
    rm_tmp(dir)
end)

-- =====================================================================
-- 作者第4轮复审 2026-08-18:三处数据安全边界补齐(原子预留 / 异常状态判定 / 格式校验)
-- =====================================================================

-- 第4轮意见 #1:损坏备份目标原子无覆盖预留——预占/并发场景下旧 .corrupt-* 备份内容不被覆盖。
T.case("隔离:预占场景下旧 .corrupt-* 备份内容不被覆盖", function()
    local dir = tmp_dir()
    for _, name in ipairs({ "thoughts.db", "thoughts.db-wal", "thoughts.db-shm" }) do
        local f = io.open(dir .. "/" .. name, "w"); f:write("MAIN"); f:close()
    end
    local base = dir .. "/thoughts.db"
    local old_ts = os.time()
    local old_target = base .. ".corrupt-" .. tostring(old_ts) .. "-0"
    local of = io.open(old_target, "w"); of:write("OLD BACKUP PAYLOAD"); of:close()
    T.ok(file_exists(old_target), "预建旧备份存在")
    local target, err = ThoughtDB.isolate_corrupt(dir)
    T.ok(target ~= nil, "隔离成功")
    T.ok(target ~= old_target, "新目标名不同于旧备份(避免覆盖)")
    -- 关键:旧备份内容原样保留,未被新隔离覆盖(无论原子路径还是退化 probe 路径)。
    local rf = io.open(old_target, "r"); local content = rf and rf:read("*a"); if rf then rf:close() end
    T.ok(content == "OLD BACKUP PAYLOAD", "旧备份内容未被覆盖")
    -- 新隔离目标承载真实主库内容。
    local nf = io.open(target, "r"); local ncontent = nf and nf:read("*a"); if nf then nf:close() end
    T.ok(ncontent == "MAIN", "新隔离目标承载主库内容")
    rm_tmp(dir)
end)

-- 第4轮意见 #2:.isolated 标记读取失败(权限/IO)→ 保守阻断自动重建,避免掩盖隔离态。
T.case("open:隔离标记无法确认(权限/IO)→ 阻断自动重建", function()
    local dir = tmp_dir()
    local old_lfs = package.loaded["libs/libkoreader-lfs"]
    package.loaded["libs/libkoreader-lfs"] = {
        attributes = function() return nil, "Permission denied" end,
    }
    local c, restore = spy_os()
    local db, err = ThoughtDB.open(dir)
    restore()
    package.loaded["libs/libkoreader-lfs"] = old_lfs
    T.ok(db == nil, "标记无法确认 → open 返回 nil(阻断)")
    T.ok(err ~= nil and tostring(err):find("无法确认"), "错误含'无法确认'")
    T.ok(c.rename == 0 and c.remove == 0, "阻断时不隔离不删除")
    T.ok(not file_exists(dir .. "/thoughts.db"), "未自动创建空库")
    rm_tmp(dir)
end)

-- 第4轮意见 #2:主库状态无法确认(权限/IO)→ 阻断自动重建,绝不交给 SQLite 建空库。
T.case("open:主库状态无法确认(权限/IO)→ 阻断自动重建", function()
    local dir = tmp_dir()
    -- .isolated 视为不存在,主库视为无法确认;其余随意。
    local old_lfs = package.loaded["libs/libkoreader-lfs"]
    package.loaded["libs/libkoreader-lfs"] = {
        attributes = function(p)
            if p:find("%.isolated$") then return nil, "No such file or directory" end
            return nil, "Permission denied"
        end,
    }
    local c, restore = spy_os()
    local db, err = ThoughtDB.open(dir)
    restore()
    package.loaded["libs/libkoreader-lfs"] = old_lfs
    T.ok(db == nil, "主库无法确认 → open 返回 nil(阻断)")
    T.ok(err ~= nil and tostring(err):find("无法确认"), "错误含'无法确认'")
    T.ok(c.rename == 0 and c.remove == 0, "阻断时不隔离不删除")
    T.ok(not file_exists(dir .. "/thoughts.db"), "未自动创建空库")
    rm_tmp(dir)
end)

-- 第4轮意见 #2:主库缺失但仍有孤立 sidecar(-wal/-shm)→ 阻断自动重建(不静默建空库)。
T.case("open:主库缺失但有孤立 sidecar → 阻断,不建空库", function()
    local dir = tmp_dir()
    -- 仅留 orphan -wal(模拟上次写入中途崩溃),无主库、无 .isolated。
    local f = io.open(dir .. "/thoughts.db-wal", "w"); f:write("x"); f:close()
    local c, restore = spy_os()
    local db, err = ThoughtDB.open(dir)
    restore()
    T.ok(db == nil, "orphan sidecar → open 返回 nil(阻断)")
    T.ok(err ~= nil and tostring(err):find("孤立"), "错误含'孤立'")
    T.ok(c.rename == 0 and c.remove == 0, "阻断时不隔离不删除原(可能残留的)数据")
    T.ok(not file_exists(dir .. "/thoughts.db"), "未自动创建真实 thoughts.db")
    rm_tmp(dir)
end)

-- 第4轮意见 #2(放行路径):主库确缺失且无 sidecar → 允许 SQLite 正常新建(首次打开一本书)。
T.case("open:主库确缺失且无 sidecar → 正常新建", function()
    SQ3._reset()
    local clean = "/book/fresh-" .. tostring(os.time()) .. "-" .. tostring(math.floor(math.random() * 1e7))
    local c, restore = spy_os()
    local db, err = ThoughtDB.open(clean)
    restore()
    T.ok(db ~= nil, "首次打开(无主库无 sidecar)→ open 成功")
    T.ok(err == nil, "无错误")
    T.ok(c.rename == 0 and c.remove == 0, "无损坏/隔离,不重命名不删除")
    T.ok(SQ3._stores[clean .. "/thoughts.db"] ~= nil, "内存库已建立(正常新建)")
    if db then ThoughtDB.close(db) end
end)

-- 第4轮意见 #3:integrity_check 返回格式异常(无结果行)→ 抛错,按过程失败处理(保留原库)。
T.case("integrity_check:无结果行(格式异常)→ 抛错(过程失败)", function()
    local fake = { prepare = function() return { step = function() return nil end, close = function() end } end }
    local ok, err = pcall(ThoughtDB.integrity_check, fake)
    T.ok(not ok, "无结果行 → integrity_check 抛错(过程失败,保留原库)")
    T.ok(err ~= nil and tostring(err):find("格式"), "错误含'格式'")
end)

-- 第4轮意见 #3:integrity_check 返回首列非字符串(格式异常)→ 抛错,避免误判为确认损坏。
T.case("integrity_check:首列非字符串(格式异常)→ 抛错", function()
    local fake = { prepare = function() return { step = function() return { 123 } end, close = function() end } end }
    local ok, err = pcall(ThoughtDB.integrity_check, fake)
    T.ok(not ok, "首列非字符串 → 抛错(不误判损坏、不触发隔离)")
    T.ok(err ~= nil and tostring(err):find("格式"), "错误含'格式'")
end)

-- 第4轮意见 #3:integrity_check 格式异常经 open 按过程失败处理(保留原库,不隔离不删)。
T.case("open:integrity_check 格式异常 → 过程失败(保留原库,不隔离不删)", function()
    local orig = ThoughtDB.integrity_check
    -- 模拟底层返回格式异常(非标准结果),integrity_check 应抛错 → open 视为过程失败。
    ThoughtDB.integrity_check = function(_d) error("integrity_check 返回格式异常:缺少结果行") end
    local c, restore = spy_os()
    local db, err = ThoughtDB.open("/fmt/book")
    restore()
    T.ok(db == nil, "格式异常 → open 返回 nil(不静默重建空库)")
    T.ok(err ~= nil and tostring(err):find("过程失败"), "错误含'过程失败'")
    T.ok(c.rename == 0, "格式异常不触发隔离/重命名")
    T.ok(c.remove == 0, "格式异常绝不删除想法数据")
    ThoughtDB.integrity_check = orig
end)

-- 完整模拟 Linux 原子预留的 fake ffi(作者第6轮意见 #3:必须真实模拟占位状态、错误码
-- 与 fd 生命周期,而非只统计调用次数):
--   - C.open(O_CREAT|O_EXCL) 语义:目标已存在(真实文件或本流程已占位)→ -1 + errno=EEXIST(17);
--     成功 → 分配伪 fd 并记录占位(占位仅内存态,不落真实文件,使 Windows 上后续
--     os.rename 能成功——与真实 Linux 的"rename 覆盖空占位"等价)。
--   - errno_map[path] 可注入非 EEXIST 错误码(权限/磁盘等)模拟异常。
--   - C.close 记录被关闭 fd 对应路径当时的文件内容:若 close 发生在 rename 完成之后,
--     该路径应已承载主库内容("MAIN")——据此断言"fd 保持到 rename 完成后才关闭"。
local function make_fake_ffi(errno_map)
    local state = {
        open_calls = 0, close_calls = 0, success_calls = 0,
        fds = {}, opened = {}, errno = 0,
        closed_content = nil,  -- 最近一次 close 时该路径的内容(验证 close 时机)
    }
    local C = {
        open = function(path, _flags, _mode)
            state.open_calls = state.open_calls + 1
            state.errno = 0
            -- errno_map 支持按路径精确注入,或 "*" 通配注入(对所有候选生效)。
            local injected = errno_map and (errno_map[path] or errno_map["*"])
            if injected then
                state.errno = injected
                return -1
            end
            local f = io.open(path, "r")
            if f then f:close(); state.errno = 17; return -1 end  -- 已存在(EEXIST)
            if state.opened[path] then state.errno = 17; return -1 end
            state.opened[path] = true
            state.success_calls = state.success_calls + 1
            local fd = 10 + state.success_calls
            state.fds[fd] = path
            return fd
        end,
        close = function(fd)
            state.close_calls = state.close_calls + 1
            local p = state.fds[fd]
            if p then
                local f = io.open(p, "r")
                if f then
                    state.closed_content = f:read("*a"); f:close()
                else
                    state.closed_content = nil
                end
                state.fds[fd] = nil
            end
            return 0
        end,
    }
    return { os = "Linux", abi = function() return true end, cdef = function() end,
        C = C, errno = function() return state.errno end, _state = state }
end

-- 注入 fake ffi 并重新加载模块(仅用例作用域,结束后还原),返回 (模块, fake)。
local function with_fake_ffi(errno_map)
    local real_ffi = package.loaded["ffi"]
    local real_tdb = package.loaded["pickthought.thought_db"]
    local fake = make_fake_ffi(errno_map)
    package.loaded["ffi"] = fake
    package.loaded["pickthought.thought_db"] = nil
    local AtomicTDB = require("pickthought.thought_db")
    package.loaded["ffi"] = real_ffi  -- 模块已捕获 fake,立即还原全局 ffi,避免污染其它用例
    return AtomicTDB, fake, function() package.loaded["pickthought.thought_db"] = real_tdb end
end

-- 作者第5轮意见 2026-08-19:原子无覆盖路径在 Kindle Linux 必须真实启用,且测试须覆盖原子分支
-- (此前 CI 走降级 probe 路径,未验证 O_CREAT|O_EXCL 原子占用)。
-- 第6轮意见(2026-08-20):fake 须完整模拟占位状态、错误码与 fd 生命周期。
-- 本用例验证:① 目标被占用(EEXIST)时换新名;② 旧 .corrupt-* 内容不被覆盖;
-- ③ 占位 fd 保持到 rename 完成之后才关闭(close 时目标已承载主库内容)。
T.case("原子预留(Linux 分支):目标被占用时换名,旧备份不覆盖,fd 保持到 rename 后关闭", function()
    local AtomicTDB, fake, restore_tdb = with_fake_ffi(nil)

    local dir = tmp_dir()
    for _, name in ipairs({ "thoughts.db", "thoughts.db-wal", "thoughts.db-shm" }) do
        local f = io.open(dir .. "/" .. name, "w"); f:write("MAIN"); f:close()
    end
    local base = dir .. "/thoughts.db"
    -- 预建"当前秒 salt 0"的旧备份,恰好命中 reserve_corrupt_main 首个候选 → 模拟目标被占用。
    local old_target = base .. ".corrupt-" .. tostring(os.time()) .. "-0"
    local of = io.open(old_target, "w"); of:write("OLD BACKUP PAYLOAD"); of:close()
    T.ok(file_exists(old_target), "预建旧备份(当前秒 salt0)存在,恰好命中首个候选")

    local target, err = AtomicTDB.isolate_corrupt(dir)
    restore_tdb()

    T.ok(fake._state.open_calls > 0, "原子分支(ffi.C.open)确实被走到,非降级 probe 路径")
    T.ok(target ~= nil, "隔离成功(原子分支已启用)")
    T.ok(target ~= old_target, "目标被占用 → 换新名(不覆盖旧备份)")
    -- 旧备份内容原样保留(原子 open(O_EXCL) 在占用同名目标时失败,分支换名)。
    local rf = io.open(old_target, "r"); local content = rf and rf:read("*a"); if rf then rf:close() end
    T.ok(content == "OLD BACKUP PAYLOAD", "旧备份内容未被原子预留覆盖")
    -- 新目标承载主库内容。
    local nf = io.open(target, "r"); local ncontent = nf and nf:read("*a"); if nf then nf:close() end
    T.ok(ncontent == "MAIN", "新目标承载主库内容")
    -- 占位 fd 生命周期(第6轮意见 #2):close 发生在 rename 之后——close 时该路径应已
    -- 承载主库内容(占位已被 rename 覆盖),而非空占位。
    T.eq(fake._state.closed_content, "MAIN", "fd 保持到 rename 完成后才关闭(close 时目标已承载主库内容)")
    -- 每次成功 open 最终都有对应 close(无 fd 泄漏);EEXIST 失败尝试不产生 fd,不计入。
    T.ok(fake._state.close_calls >= fake._state.success_calls, "成功占位的 fd 均已关闭")
    rm_tmp(dir)
end)

-- 作者第6轮意见 #1:atomic_claim 必须读取 errno,仅 EEXIST 换名重试;权限/磁盘/IO 错误
-- 立即中止(绝不盲目循环 100000 次阻塞 Kindle),且隔离标记保留阻断自动重建。
T.case("原子预留:非 EEXIST 错误(errno=EACCES)立即中止,不换名不循环,标记保留", function()
    -- 模块 require 时捕获 ATOMIC_OPEN,故 errno 注入须在加载前(通配 "*" 对所有候选生效)。
    local AtomicTDB, fake, restore_tdb = with_fake_ffi({ ["*"] = 13 })  -- EACCES:权限不足

    local dir = tmp_dir()
    local f = io.open(dir .. "/thoughts.db", "w"); f:write("MAIN"); f:close()
    local target, err = AtomicTDB.isolate_corrupt(dir)
    restore_tdb()

    T.ok(target == nil, "非 EEXIST 错误 → 隔离失败")
    T.ok(tostring(err):find("目标占用失败") or tostring(err):find("重命名失败"),
        "错误含失败原因: " .. tostring(err))
    T.eq(fake._state.open_calls, 1, "只尝试 1 次即中止,不盲目换名循环")
    T.ok(file_exists(dir .. "/thoughts.db.isolated"), ".isolated 标记保留(阻断自动重建)")
    T.ok(file_exists(dir .. "/thoughts.db"), "主库未被移动(保护原库)")
    rm_tmp(dir)
end)

-- 作者第6轮意见 #4:path_exists_distinct 在 lfs 不可用时退化的 io.open 也要区分
-- "不存在"与"权限/IO 错误"(后者 → uncheckable → 阻断自动建库,不误判为不存在)。
T.case("open:无 lfs 退化 io.open 遇权限错误 → uncheckable 阻断自动重建", function()
    local dir = tmp_dir()
    -- 让主库路径是一个"目录":io.open(dir, "r") 打不开且错误不是 "No such file" → uncheckable。
    mkdir_p(dir .. "/thoughts.db")
    -- 移除 lfs(loaded + preload),强制 path_exists_distinct 走 io.open 退化分支。
    local old_loaded = package.loaded["libs/libkoreader-lfs"]
    local old_preload = package.preload["libs/libkoreader-lfs"]
    package.loaded["libs/libkoreader-lfs"] = nil
    package.preload["libs/libkoreader-lfs"] = nil
    local c, restore = spy_os()
    local db, err = ThoughtDB.open(dir)
    restore()
    package.loaded["libs/libkoreader-lfs"] = old_loaded
    package.preload["libs/libkoreader-lfs"] = old_preload

    T.ok(db == nil, "主库无法检查 → open 返回 nil(阻断)")
    T.ok(tostring(err):find("无法确认"), "错误含'无法确认': " .. tostring(err))
    T.ok(c.rename == 0 and c.remove == 0, "阻断时不隔离不删除")
    T.ok(not file_exists(dir .. "/thoughts.db"), "未自动创建空库")
    rm_tmp(dir)
end)
