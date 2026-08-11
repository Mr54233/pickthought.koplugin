local Thoughts = require("pickthought.thoughts")
local SQ3 = require("lua-ljsqlite3/init")

-- 最小 store mock:book_dir 返回一个伪目录(ThoughtDB 在 mock SQLite 下用内存库,
-- 不真建文件)。每个 case 用独立目录,并在开头 reset 内存库避免串扰。
local function store_with(dir)
    return { book_dir = function(_, _) return dir end }
end

T.case("Thoughts.save → find 往返(SQLite 后端)", function()
    SQ3._reset()
    local store = store_with("/t/sf")
    local n = Thoughts.save(store, "b1", "999", {
        { range = "0-7", texts = {
            { content = "开篇即巅峰", author = "甲", likes = 12, review_id = "r1",
              abstract = "春江潮水连海平" },
            { content = "同意", author = "乙", likes = 0, review_id = "" },
        } },
    })
    T.eq(n, 2, "save 返回写入条数")
    local group = Thoughts.find(store, "b1", "999", "0-7")
    T.ok(group, "find 取回 group")
    T.eq(#group.texts, 2, "2 条想法")
    T.eq(group.texts[1].content, "开篇即巅峰", "item_index 升序")
    T.eq(group.texts[1].abstract, "春江潮水连海平", "abstract 保留")
    T.eq(tonumber(group.texts[1].likes), 12, "likes 保留")
end)

T.case("save 同章覆盖:重写替换旧数据", function()
    SQ3._reset()
    local store = store_with("/t/overwrite")
    Thoughts.save(store, "b", "1", {
        { range = "0-7", texts = { { content = "旧", author = "x", likes = 0, review_id = "" } } },
        { range = "10-15", texts = { { content = "另一段", author = "y", likes = 0, review_id = "" } } },
    })
    Thoughts.save(store, "b", "1", {
        { range = "0-7", texts = { { content = "新", author = "z", likes = 1, review_id = "n1" } } },
    })
    local g = Thoughts.find(store, "b", "1", "0-7")
    T.eq(#g.texts, 1, "0-7 被整体替换")
    T.eq(g.texts[1].content, "新", "内容是新版")
    T.eq(Thoughts.find(store, "b", "1", "10-15"), nil, "同章未涉及的旧 range 随章替换清除")
end)

T.case("popup_text 格式化纯文本", function()
    local text = Thoughts.popup_text({ texts = {
        { content = "好评", author = "甲", likes = 5, review_id = "r1", abstract = "原文" },
        { content = "赞", author = "", likes = 0, review_id = "" },
    } })
    T.ok(text:find("甲", 1, true), "含作者")
    T.ok(text:find("赞 5", 1, true), "含点赞数")
    T.ok(text:find("好评", 1, true), "含内容")
    T.ok(text:find("微信读书用户", 1, true), "空作者兜底")
end)

T.case("popup_text 按 review_id 去重", function()
    local text = Thoughts.popup_text({ texts = {
        { content = "同一条", author = "甲", likes = 0, review_id = "dup" },
        { content = "同一条", author = "甲", likes = 0, review_id = "dup" },
    } })
    local _, count = text:gsub("同一条", "")
    T.eq(count, 1, "相同 review_id 只出现一次")
end)

T.case("popup_items 对齐原生弹窗数据并去重", function()
    local items = Thoughts.popup_items({ texts = {
        { content = "第一条", author = "甲", likes = 5, review_id = "r1", abstract = "原文" },
        { content = "第一条重复", author = "甲", likes = 6, review_id = "r1", abstract = "忽略" },
        { content = "第二条", author = "", likes = 0, review_id = "" },
    } })
    T.eq(#items, 2, "相同 review_id 去重")
    T.eq(items[1].abstract, "原文", "首条保留摘要")
    T.eq(items[2].abstract, "", "后续条目不重复显示摘要")
    T.eq(items[1].likes_count, 5, "点赞字段适配")
    T.eq(items[2].author, "微信读书用户", "作者兜底")
end)

T.case("Thoughts.merge 合并到 SQLite(into 已存在)", function()
    SQ3._reset()
    local store = store_with("/t/merge1")
    Thoughts.save(store, "b", "5", {
        { range = "2-5", texts = { { content = "被合并", author = "乙", likes = 0, review_id = "f1" } } },
        { range = "0-7", texts = { { content = "存活", author = "甲", likes = 1, review_id = "i1" } } },
    })
    T.ok(Thoughts.merge(store, "b", "5", "2-5", "0-7"), "merge 成功")
    local into = Thoughts.find(store, "b", "5", "0-7")
    T.eq(#into.texts, 2, "into 含两边的想法")
    T.eq(Thoughts.find(store, "b", "5", "2-5"), nil, "from 已删除")
end)

T.case("Thoughts.merge:into 不存在时 from 改名", function()
    SQ3._reset()
    local store = store_with("/t/merge2")
    Thoughts.save(store, "b", "5", {
        { range = "9-12", texts = { { content = "孤立", author = "丙", likes = 0, review_id = "x1" } } },
    })
    T.ok(Thoughts.merge(store, "b", "5", "9-12", "0-7"), "改名成功")
    local g = Thoughts.find(store, "b", "5", "0-7")
    T.ok(g and #g.texts == 1, "想法搬到 into range")
    T.eq(Thoughts.find(store, "b", "5", "9-12"), nil, "旧 range 清空")
end)

T.case("Thoughts.group_abstract 取首条摘要", function()
    SQ3._reset()
    local store = store_with("/t/abs")
    Thoughts.save(store, "b", "1", {
        { range = "0-7", texts = {
            { content = "想法", author = "甲", likes = 0, review_id = "", abstract = "原文摘要" },
        } },
    })
    local group = Thoughts.find(store, "b", "1", "0-7")
    T.eq(Thoughts.group_abstract(group), "原文摘要", "摘要取自首条")
    T.eq(Thoughts.group_abstract({ texts = { { content = "x", abstract = "" } } }), "", "无摘要返空")
end)
