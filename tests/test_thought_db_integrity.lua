-- ④ DB 完整性校验:integrity_check / checkpoint / 迁移追踪(user_version) / 损坏隔离。
-- 作者评审意见:open 必须区分"过程失败"与"确认损坏"——
--   过程失败(I/O、busy/locked、prepare/step 异常):保留原库,绝不删;
--   确认损坏:隔离(.corrupt-*)而非删除,绝不静默重建空库。
-- stubs 的 SQLite mock 已支持 PRAGMA integrity_check(返回 {"ok"})、
-- wal_checkpoint(返回 {0,0,0}) 与 user_version 读写。
local ThoughtDB = require("pickthought.thought_db")
local SQ3 = require("lua-ljsqlite3/init")

local function fresh_db()
    SQ3._reset()
    return ThoughtDB.open("/book/dir")
end

-- 单测内 spy os.rename / os.remove,返回计数与还原闭包,用于断言"不删库/确实隔离"。
local function spy_os()
    local c = { rename = 0, remove = 0 }
    local o_rn, o_rm = os.rename, os.remove
    os.rename = function(...) c.rename = c.rename + 1; return o_rn(...) end
    os.remove = function(...) c.remove = c.remove + 1; return o_rm(...) end
    return c, function() os.rename, os.remove = o_rn, o_rm end
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

T.case("open 遇确认损坏:隔离(.corrupt-*)而非删除,返回 nil", function()
    local orig = ThoughtDB.integrity_check
    ThoughtDB.integrity_check = function(_d) return false, "mock corrupt" end
    local c, restore = spy_os()
    local db, err = ThoughtDB.open("/corrupt/book")
    restore()
    T.ok(db == nil, "确认损坏 → open 返回 nil(不静默重建空库)")
    T.ok(err ~= nil and tostring(err):find("隔离"), "错误描述含'隔离'")
    T.ok(c.rename >= 1, "损坏库被重命名隔离(.corrupt-*)")
    T.ok(c.remove == 0, "绝不调用 os.remove 删除想法数据")
    ThoughtDB.integrity_check = orig
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
