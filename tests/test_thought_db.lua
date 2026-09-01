-- stubs 已由 tests/run.lua 最先 require,SQLite mock 通过 package.preload 注册。
local ThoughtDB = require("pickthought.thought_db")
local SQ3 = require("lua-ljsqlite3/init")

local function fresh_db()
    SQ3._reset()
    return ThoughtDB.open("/book/dir")
end

local GROUPS = {
    {
        range = "0-7",
        texts = {
            { content = "开篇即巅峰", author = "读者甲", likes = 12, review_id = "r1",
              abstract = "春江潮水连海平" },
            { content = "同意", author = "读者乙", likes = 0, review_id = "" },
        },
    },
    { range = "10-15", texts = { { content = "另一段", author = "丙", likes = 3, review_id = "r2" } } },
}

T.case("ThoughtDB.put_chapter / get_range 往返", function()
    local db = fresh_db()
    T.ok(ThoughtDB.put_chapter(db, "999", GROUPS), "put_chapter 成功")
    local texts = ThoughtDB.get_range(db, "999", "0-7")
    T.ok(texts and #texts == 2, "0-7 取回 2 条")
    T.eq(texts[1].content, "开篇即巅峰", "item_index 升序:第 1 条")
    T.eq(tonumber(texts[1].likes), 12, "likes 字段")
    T.eq(texts[1].abstract, "春江潮水连海平", "abstract 字段")
    T.eq(texts[2].author, "读者乙", "第 2 条作者")
    T.eq(texts[2].review_id, "", "空 review_id 保留")
    T.eq(#ThoughtDB.get_range(db, "999", "10-15"), 1, "另一个 range")
    ThoughtDB.close(db)
end)

T.case("put_chapter 替换覆盖旧章", function()
    local db = fresh_db()
    ThoughtDB.put_chapter(db, "1", GROUPS)
    ThoughtDB.put_chapter(db, "1", { { range = "0-7", texts = {
        { content = "新版唯一", author = "新", likes = 0, review_id = "n1" } } } })
    local texts = ThoughtDB.get_range(db, "1", "0-7")
    T.eq(#texts, 1, "旧章被整体替换,只剩新版 1 条")
    T.eq(texts[1].content, "新版唯一", "内容是新版")
    T.eq(#ThoughtDB.get_range(db, "1", "10-15"), 0, "旧 range 随章替换清除")
    ThoughtDB.close(db)
end)

T.case("put_range / delete_range 精确到 range", function()
    local db = fresh_db()
    ThoughtDB.put_range(db, "5", "0-7", {
        { content = "a", author = "x", likes = 0, review_id = "" },
        { content = "b", author = "y", likes = 1, review_id = "i2" },
    })
    T.eq(#ThoughtDB.get_range(db, "5", "0-7"), 2, "put_range 写入 2 条")
    ThoughtDB.put_range(db, "5", "0-7", { { content = "覆盖", author = "z", likes = 0, review_id = "" } })
    T.eq(#ThoughtDB.get_range(db, "5", "0-7"), 1, "put_range 覆盖旧 range")
    ThoughtDB.delete_range(db, "5", "0-7")
    T.eq(#ThoughtDB.get_range(db, "5", "0-7"), 0, "delete_range 清空")
    ThoughtDB.close(db)
end)

T.case("空 content 的条目被丢弃(与 compact_group 一致)", function()
    local db = fresh_db()
    ThoughtDB.put_chapter(db, "9", { { range = "0-7", texts = {
        { content = "", author = "空", likes = 0, review_id = "" },
        { content = "有效", author = "甲", likes = 0, review_id = "" } } } })
    T.eq(#ThoughtDB.get_range(db, "9", "0-7"), 1, "空内容不入库")
    ThoughtDB.close(db)
end)

T.case("get_range:查询成功但无行返回空表", function()
    local db = {
        prepare = function()
            return {
                reset = function(self) return self end,
                bind = function(self) return self end,
                step = function() return nil end,
                close = function() end,
            }
        end,
    }
    local rows, err = ThoughtDB.get_range(db, "empty", "0-1")
    T.ok(rows and #rows == 0, "空查询返回空表")
    T.eq(err, nil, "空查询没有错误")
end)

T.case("get_range:prepare/bind/step 异常返回具体错误", function()
    local prepared, prepare_err = ThoughtDB.get_range({
        prepare = function() error("mock prepare failure") end,
    }, "1", "0-1")
    T.ok(prepared == nil and tostring(prepare_err):find("prepare"),
        "prepare 异常不会伪装成空结果")

    local bound, bind_err = ThoughtDB.get_range({
        prepare = function()
            return {
                reset = function(self) return self end,
                bind = function() error("mock bind failure") end,
                close = function() end,
            }
        end,
    }, "1", "0-1")
    T.ok(bound == nil and tostring(bind_err):find("bind"),
        "bind 异常不会伪装成空结果")

    local stepped, step_err = ThoughtDB.get_range({
        prepare = function()
            return {
                reset = function(self) return self end,
                bind = function(self) return self end,
                step = function() error("mock step failure") end,
                close = function() end,
            }
        end,
    }, "1", "0-1")
    T.ok(stepped == nil and tostring(step_err):find("step"),
        "step 异常不会伪装成空结果")
end)

T.case("get_range:后续 step 和 statement close 异常也返回错误", function()
    local calls = 0
    local rows, step_err = ThoughtDB.get_range({
        prepare = function()
            return {
                reset = function(self) return self end,
                bind = function(self) return self end,
                step = function()
                    calls = calls + 1
                    if calls == 1 then return { "a", "b", "第一条", 0, "r1" } end
                    error("mock later step failure")
                end,
                close = function() end,
            }
        end,
    }, "1", "0-1")
    T.ok(rows == nil and tostring(step_err):find("step"),
        "后续 step 异常不会返回部分结果")

    local closed, close_err = ThoughtDB.get_range({
        prepare = function()
            return {
                reset = function(self) return self end,
                bind = function(self) return self end,
                step = function() return nil end,
                close = function() error("mock close failure") end,
            }
        end,
    }, "1", "0-1")
    T.ok(closed == nil and tostring(close_err):find("close"),
        "statement close 异常返回具体错误")
end)

T.case("db_path / remove_db", function()
    T.eq(ThoughtDB.db_path("/b"), "/b/thoughts.db", "db_path 命名")
    -- remove_db 在 mock 下不抛错即可
    T.ok(pcall(ThoughtDB.remove_db, "/anywhere"), "remove_db 不抛错")
end)
