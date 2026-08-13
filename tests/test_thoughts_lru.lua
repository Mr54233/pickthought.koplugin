-- SQLite 连接 LRU 淘汰测试。
-- 思路:对真实 pickthought.thought_db 的 open/close 做 spy,
-- 记录每次 open 的目录与被淘汰(evict)/close_book 关闭的目录,从而断言 LRU 真实生效。
-- 关键:不替换模块、不返回代理句柄——open/close 仍走真实实现并返回真实句柄,
-- 避免干扰 Thoughts.save 的真实写入路径(早先的代理包装会让 save 静默失败)。
local real_db = require("pickthought.thought_db")
local SQ3 = require("lua-ljsqlite3/init")

-- 句柄 → 目录 反查表(弱键,避免句柄泄漏)。
local handle_dir = setmetatable({}, { __mode = "k" })
local opened, closed = {}, {}

local orig_open = real_db.open
local orig_close = real_db.close
real_db.open = function(book_dir)
    opened[#opened + 1] = book_dir
    local db = orig_open(book_dir)
    if db then handle_dir[db] = book_dir end
    return db
end
real_db.close = function(db)
    if db and handle_dir[db] then closed[handle_dir[db]] = true end
    return orig_close(db)
end

-- 确保 thoughts 重新捕获(已 spy 的)同一 thought_db 表。
package.loaded["pickthought.thoughts"] = nil
local Thoughts = require("pickthought.thoughts")

local function store_with(dir)
    return { book_dir = function(_, _) return dir end }
end

local function reset_spies()
    for k in pairs(opened) do opened[k] = nil end
    for k in pairs(closed) do closed[k] = nil end
end

T.case("LRU: 打开超过上限会淘汰最久未用的句柄", function()
    SQ3._reset()
    reset_spies()
    local dirs = {}
    for i = 1, 6 do dirs[i] = "/t/lru/b" .. i end
    -- 每本各存一条,save 内部会 open_db;DB_CACHE_MAX=4,开第5本淘汰 b1、开第6本淘汰 b2
    for i = 1, 6 do
        Thoughts.save(store_with(dirs[i]), "b" .. i, "1", {
            { range = "0-7", texts = { { content = "想法" .. i, author = "x", likes = 0, review_id = "" } } },
        })
    end
    T.ok(closed[dirs[1]], "最旧句柄 b1 被淘汰关闭")
    T.ok(closed[dirs[2]], "次旧句柄 b2 被淘汰关闭")
    T.ok(not closed[dirs[6]], "最新句柄 b6 未被淘汰")
    T.ok(not closed[dirs[5]], "较新句柄 b5 未被淘汰")
end)

T.case("close_book 释放单本句柄后可重新打开且不丢数据", function()
    SQ3._reset()
    reset_spies()
    local store = store_with("/t/closebook")
    Thoughts.save(store, "cb", "1", {
        { range = "0-7", texts = { { content = "x", author = "甲", likes = 0, review_id = "" } } },
    })
    Thoughts.close_book(store, "cb")
    T.ok(closed["/t/closebook"], "close_book 触发了句柄 close")
    local g = Thoughts.find(store, "cb", "1", "0-7")
    T.ok(g and #g.texts == 1, "close_book 后重新打开仍可读取")
    T.eq(g.texts[1].content, "x", "内容未丢失")
end)

T.case("LRU 压力下多本数据均可检索(淘汰不丢数据)", function()
    SQ3._reset()
    reset_spies()
    local N = 12
    for i = 1, N do
        Thoughts.save(store_with("/t/stress/" .. i), "s" .. i, "1", {
            { range = "0-7", texts = { { content = "d" .. i, author = "乙", likes = 0, review_id = "" } } },
        })
    end
    -- 淘汰只关闭句柄、不删数据;重新打开(新句柄)应仍能读到。
    for i = 1, N do
        local g = Thoughts.find(store_with("/t/stress/" .. i), "s" .. i, "1", "0-7")
        T.ok(g and #g.texts == 1, "书 s" .. i .. " 数据可检索")
    end
end)
