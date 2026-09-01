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

-- 作者第8轮意见 #3:ThoughtDB.open 的具体错误必须透传到 Thoughts.save/find,
-- 不得被吃成通用的"想法数据库不可用"(便于真机定位是损坏隔离/权限/迁移失败等)。
T.case("Thoughts.open_db 透传 ThoughtDB.open 的具体错误(作者第8轮 #3)", function()
    SQ3._reset()
    local store = store_with("/t/errprop")
    -- mock ThoughtDB.open 返回 nil + 具体错误(如损坏隔离/迁移失败描述)。
    local ThoughtDB = require("pickthought.thought_db")
    local orig_open = ThoughtDB.open
    local orig_open_fast = ThoughtDB.open_fast
    local SPECIFIC = "损坏库已隔离到 .corrupt-*,请重同步(target=...) "
    ThoughtDB.open = function(_dir) return nil, SPECIFIC end
    ThoughtDB.open_fast = function(_dir) return nil, SPECIFIC end

    local cnt, serr = Thoughts.save(store, "b", "1", {
        { range = "0-7", texts = { { content = "x", author = "a", review_id = "" } } },
    })
    local save_ok = cnt == nil and serr == SPECIFIC

    local grp, ferr = Thoughts.find(store, "b", "1", "0-7")

    ThoughtDB.open = orig_open
    ThoughtDB.open_fast = orig_open_fast
    T.ok(save_ok, "save 透传具体错误(非通用文案): " .. tostring(serr))
    T.ok(grp == nil, "find 在 open_fast 失败时返回 nil")
    T.ok(ferr == SPECIFIC, "find 透传具体错误: " .. tostring(ferr))
end)

T.case("find 冷缓存走只读路径,save 再升级为完整写句柄", function()
    SQ3._reset()
    local store = store_with("/t/readonly-upgrade")
    Thoughts.save(store, "b", "1", {
        { range = "0-7", texts = { { content = "旧内容", author = "甲", review_id = "old" } } },
    })
    Thoughts.clear_memory_cache()
    local group = Thoughts.find(store, "b", "1", "0-7")
    T.ok(group and group.texts[1].content == "旧内容", "只读快速路径返回原有数据")
    local before_save_checkpoints = SQ3._checkpoint_calls
    Thoughts.save(store, "b", "1", {
        { range = "0-7", texts = { { content = "新内容", author = "乙", review_id = "new" } } },
    })
    local modes = {}
    for _, item in ipairs(SQ3._opens) do modes[#modes + 1] = item.mode or "default" end
    T.eq(modes[1], "default", "首次保存使用完整打开")
    T.eq(modes[2], "ro", "冷缓存读取使用只读打开")
    T.eq(modes[3], "default", "写入前从只读升级为完整打开")
    T.eq(SQ3._checkpoint_calls, before_save_checkpoints, "只读句柄升级时不额外 checkpoint")
    local updated = Thoughts.find(store, "b", "1", "0-7")
    T.ok(updated and updated.texts[1].content == "新内容", "升级写入后数据可再次读取")
end)

T.case("find 查询失败返回明确错误并丢弃失效缓存", function()
    SQ3._reset()
    local store = store_with("/t/query-error-cache")
    Thoughts.save(store, "b", "1", {
        { range = "0-7", texts = { { content = "可恢复", author = "甲", review_id = "q1" } } },
    })
    local ThoughtDB = require("pickthought.thought_db")
    local original_get_range = ThoughtDB.get_range
    local before_error_checkpoints = SQ3._checkpoint_calls
    ThoughtDB.get_range = function() return nil, "模拟读取失败" end
    local group, err = Thoughts.find(store, "b", "1", "0-7")
    ThoughtDB.get_range = original_get_range
    T.ok(group == nil and tostring(err):find("模拟读取失败"),
        "查询失败透传具体错误")
    T.eq(SQ3._checkpoint_calls, before_error_checkpoints,
        "查询失败丢弃句柄时不执行 checkpoint")

    local recovered = Thoughts.find(store, "b", "1", "0-7")
    T.ok(recovered and recovered.texts[1].content == "可恢复",
        "失败后重新打开数据库可以读取")
    T.eq(SQ3._opens[#SQ3._opens].mode, "ro", "失败后没有复用失效句柄")
    Thoughts.clear_memory_cache()
end)

T.case("旧 JSON 迁移:成功删除,失败保留并可重试", function()
    SQ3._reset()
    Thoughts.clear_memory_cache()
    local store = store_with("/t/legacy-retry")
    local dir = "/t/legacy-retry/thoughts"
    local paths = { dir .. "/1.json", dir .. "/2.json", dir .. "/3.json", dir .. "/4.json", dir .. "/5.json" }
    local present = {}
    local content = {
        [paths[1]] = "[{\"range\":\"0-7\",\"texts\":[{\"content\":\"旧数据一\",\"author\":\"甲\",\"review_id\":\"l1\"}]}]",
        [paths[2]] = "[{\"range\":\"0-7\",\"texts\":[{\"content\":\"旧数据二\",\"author\":\"乙\",\"review_id\":\"l2\"}]}]",
        [paths[3]] = "不是合法 JSON",
        [paths[4]] = "[{\"range\":\"0-7\",\"texts\":[{\"content\":\"删除失败仍保留\",\"author\":\"丙\",\"review_id\":\"l4\"}]}]",
    }
    for path in ipairs(paths) do present[paths[path]] = true end
    local old_lfs = require("libs/libkoreader-lfs")
    local old_attributes = old_lfs.attributes
    local old_list = require("pickthought.util").list
    local U = require("pickthought.util")
    local old_read_file, old_file_exists = U.read_file, U.file_exists
    local old_remove = os.remove
    local old_put = require("pickthought.thought_db").put_chapter
    local fail_second = true
    local remove_blocked = true
    local ok, failure
    local function restore()
        old_lfs.attributes = old_attributes
        U.list = old_list
        U.read_file, U.file_exists = old_read_file, old_file_exists
        os.remove = old_remove
        require("pickthought.thought_db").put_chapter = old_put
    end
    old_lfs.attributes = function(path, field)
        if path == dir and field == "mode" then return "directory" end
        return old_attributes(path, field)
    end
    U.list = function(path)
        if path == dir then
            local result = {}
            for _, item in ipairs(paths) do
                if present[item] then result[#result + 1] = item end
            end
            return result
        end
        return old_list(path)
    end
    U.read_file = function(path, binary)
        if path == paths[5] then return nil, "模拟读取失败" end
        if content[path] then return content[path] end
        return old_read_file(path, binary)
    end
    U.file_exists = function(path)
        if present[path] ~= nil then return present[path] end
        return old_file_exists(path)
    end
    os.remove = function(path)
        if present[path] ~= nil then
            if not present[path] then return nil, "文件不存在" end
            if path == paths[4] and remove_blocked then return nil, "模拟删除失败" end
            present[path] = false
            return true
        end
        return old_remove(path)
    end
    require("pickthought.thought_db").put_chapter = function(db, uid, rows)
        if uid == "2" and fail_second then return false end
        return old_put(db, uid, rows)
    end
    ok, failure = xpcall(function()
        local first = Thoughts.find(store, "b", "1", "0-7")
        T.ok(first and first.texts[1].content == "旧数据一", "有效 JSON 已迁移并可读取")
        T.ok(not present[paths[1]], "成功迁移的源文件已删除")
        T.ok(present[paths[2]], "写入失败的源文件保留")
        T.ok(present[paths[3]] and present[paths[5]], "解析/读取失败的源文件保留")
        fail_second = false
        remove_blocked = false
        local retried = Thoughts.save(store, "b", "99", {})
        T.ok(retried ~= nil, "下一次写操作触发剩余 JSON 重试")
        local second, second_err = Thoughts.find(store, "b", "2", "0-7")
        T.ok(second and second.texts[1].content == "旧数据二",
            "下一次读取可读到重试迁移的数据: " .. tostring(second_err))
        T.ok(not present[paths[2]], "重试成功后删除源文件")
        T.ok(not present[paths[4]], "删除失败文件在重试成功后删除")
        T.ok(present[paths[3]] and present[paths[5]], "持续失败文件继续保留")
    end, debug.traceback)
    restore()
    Thoughts.clear_memory_cache()
    T.ok(ok, failure)
end)

T.case("merge 查询失败时不写入或删除数据", function()
    SQ3._reset()
    local store = store_with("/t/merge-query-error")
    Thoughts.save(store, "b", "1", {
        { range = "from", texts = { { content = "来源", author = "甲", review_id = "m1" } } },
        { range = "into", texts = { { content = "目标", author = "乙", review_id = "m2" } } },
    })
    local ThoughtDB = require("pickthought.thought_db")
    local original_get_range = ThoughtDB.get_range
    local original_put_range = ThoughtDB.put_range
    local original_delete_range = ThoughtDB.delete_range
    local writes, deletes = 0, 0
    ThoughtDB.get_range = function() return nil, "模拟合并查询失败" end
    ThoughtDB.put_range = function(...) writes = writes + 1; return original_put_range(...) end
    ThoughtDB.delete_range = function(...) deletes = deletes + 1; return original_delete_range(...) end
    local merged = Thoughts.merge(store, "b", "1", "from", "into")
    ThoughtDB.get_range = original_get_range
    ThoughtDB.put_range = original_put_range
    ThoughtDB.delete_range = original_delete_range
    T.ok(not merged, "查询失败时合并返回失败")
    T.eq(writes, 0, "查询失败时不写入目标 range")
    T.eq(deletes, 0, "查询失败时不删除来源 range")
    Thoughts.clear_memory_cache()
end)
