-- ④ DB 完整性校验:integrity_check / checkpoint / 迁移追踪(user_version) / 损坏重建。
-- stubs 的 SQLite mock 已支持 PRAGMA integrity_check(返回 {"ok"}) 与 user_version 读写。
local ThoughtDB = require("pickthought.thought_db")
local SQ3 = require("lua-ljsqlite3/init")

local function fresh_db()
    SQ3._reset()
    return ThoughtDB.open("/book/dir")
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

T.case("checkpoint 不抛错且返回 true", function()
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

T.case("open 遇损坏库重建一次后成功(防无限递归)", function()
    local orig = ThoughtDB.integrity_check
    local calls = 0
    ThoughtDB.integrity_check = function(_d)
        calls = calls + 1
        if calls == 1 then return false, "mock corrupt" end
        return true
    end
    local db = ThoughtDB.open("/corrupt/book")
    T.ok(db ~= nil, "重建后 open 成功")
    T.eq(calls, 2, "恰好重建一次(第二次核验通过)")
    ThoughtDB.integrity_check = orig
    if db then ThoughtDB.close(db) end
end)

T.case("open 持续损坏时仅重试一次后返回 nil", function()
    local orig = ThoughtDB.integrity_check
    local calls = 0
    ThoughtDB.integrity_check = function() calls = calls + 1; return false, "always corrupt" end
    local db = ThoughtDB.open("/doomed/book")
    T.ok(db == nil, "持续损坏 → open 返回 nil")
    T.eq(calls, 2, "首次核验 + 重建后复核,共两次")
    ThoughtDB.integrity_check = orig
end)
