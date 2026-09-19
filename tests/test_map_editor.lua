-- MapEditor 手动指认单元测试(上游四项移植 R3)。
local MapEditor = require("pickthought.map_editor")
local Json = require("pickthought.json")
local U = require("pickthought.util")

local CACHE = "tests/.tmp_map_editor.json"
local SPINE = {
    {href = "OEBPS/c1.xhtml"}, {href = "OEBPS/c2.xhtml"}, {href = "OEBPS/c3.xhtml"},
}
local CHAPTERS = {
    {uid = "1", title = "第一章 春江潮水"},
    {uid = "2", title = "第二章 月照花林"},
    {uid = "3", title = "第三章 独钓寒江"},
}

local function seed(entries)
    os.remove(CACHE)
    U.atomic_write(CACHE, Json.encode({signature = "s", map = entries}), true)
end

T.case("R3: list 三种状态正确分组", function()
    seed({
        ["1"] = {hrefs = {"OEBPS/c1.xhtml"}, algo = 11},
        ["2"] = {no_hit = true, n = 1, len = 10, algo = 11},
        ["3"] = nil,
    })
    -- 第三章手动条目
    local decoded = Json.decode(U.read_file(CACHE, true))
    decoded.map["3"] = {hrefs = {"OEBPS/c3.xhtml"}, manual = true, algo = 11}
    U.atomic_write(CACHE, Json.encode(decoded), true)
    local rows, err = MapEditor.list(CACHE, CHAPTERS)
    T.ok(rows, "list 成功: " .. tostring(err))
    T.eq(#rows.manual, 1, "手动组=1")
    T.eq(rows.manual[1].uid, "3", "手动组是第三章")
    T.eq(#rows.miss, 1, "未匹配组=1(no_hit)")
    T.eq(#rows.auto, 1, "自动组=1")
    T.eq(rows.auto[1].uid, "1", "自动组是第一章")
    os.remove(CACHE)
end)

T.case("R3: assign 覆写并带 manual 标记与当前算法版本", function()
    seed({["1"] = {no_hit = true, n = 1, len = 10, algo = 11}})
    local ok, err = MapEditor.assign(CACHE, "1", "OEBPS/c2.xhtml", SPINE, 99)
    T.ok(ok, "指认成功: " .. tostring(err))
    local decoded = Json.decode(U.read_file(CACHE, true))
    T.eq(decoded.map["1"].hrefs[1], "OEBPS/c2.xhtml", "目标正确")
    T.eq(decoded.map["1"].manual, true, "manual 标记")
    T.eq(decoded.map["1"].algo, 99, "记录指认时算法版本")
    -- 原条目的 no_hit 字段应被整体覆写掉
    T.eq(decoded.map["1"].no_hit, nil, "旧 no_hit 结论清除")
    os.remove(CACHE)
end)

T.case("R3: assign 拒绝 spine 外的目标文件", function()
    seed({["1"] = {no_hit = true, n = 1, len = 10, algo = 11}})
    local ok, err = MapEditor.assign(CACHE, "1", "OEBPS/gone.xhtml", SPINE, 99)
    T.eq(ok, nil, "拒绝")
    T.ok(tostring(err):find("spine", 1, true), "错误说明原因: " .. tostring(err))
    os.remove(CACHE)
end)

T.case("R3: assign 对不存在的缓存文件报可读错误", function()
    os.remove(CACHE)
    local ok, err = MapEditor.assign(CACHE, "1", "OEBPS/c1.xhtml", SPINE, 99)
    T.eq(ok, nil, "拒绝")
    T.ok(tostring(err):find("同步", 1, true), "提示先同步: " .. tostring(err))
end)

T.case("R3: clear 删除条目恢复自动", function()
    seed({["1"] = {hrefs = {"OEBPS/c1.xhtml"}, manual = true, algo = 11}})
    local ok = MapEditor.clear(CACHE, "1")
    T.ok(ok, "清除成功")
    local decoded = Json.decode(U.read_file(CACHE, true))
    T.eq(decoded.map["1"], nil, "条目已删除,下一批走自动")
    os.remove(CACHE)
end)

T.case("R3: sync 加载段 manual 条目优先复用(不进自动 todo)", function()
    local Sync = require("pickthought.sync")
    local ChapterMap = require("pickthought.chapter_map")
    local cache_file = "tests/.tmp_map_editor_sync.json"
    os.remove(cache_file)
    -- 章名与正文完全对不上:自动匹配必然 no_hit,只有 manual 能救。
    local fixture = {api = {chapters = function() return {data = {
        {chapterUid = 1, title = "微信独有的章名甲", chapterIdx = 1},
        {chapterUid = 2, title = "微信独有的章名乙", chapterIdx = 2}}} end},
        annotations = {fetch_chapter = function(_, _, uid)
            return {underlines = {{range = "0-7", markText = "书里完全没有的句子" .. tostring(uid)}},
                review_map = {}, review_groups = {},
                underline_count = 1, thought_count = 0, thought_entry_count = 0, errors = {}}
        end}}
    local function make_deps_local()
        -- 复用 test_sync 的 make_deps(含完整成功路径桩)
        local deps = STUBS and nil
        return deps
    end
    -- 直接内联最小 make_deps(与 test_sync.make_deps 同构)
    local function build_deps(overrides)
        local deps = {
            doc_path = "fake.epub", book_id = "b1",
            api = fixture.api, annotations = fixture.annotations,
            map_cache_path = cache_file,
            spine = {{href = "OEBPS/c1.xhtml"}, {href = "OEBPS/c2.xhtml"}},
            read_text = function() return "<html><body>无关正文内容</body></html>" end,
            load_meta = function() return {spine = {{href = "OEBPS/c1.xhtml"}, {href = "OEBPS/c2.xhtml"}},
                names = {"OEBPS/c1.xhtml", "OEBPS/c2.xhtml"}} end,
            file_exists = function(p) return p == "fake.epub.orig" or p == "fake.epub" end,
            file_size = function() return 100 end,
            content_fingerprint = function() return "fp" end,
            rename = function(a, b) return true, nil end,
            remove = function() return true end,
            copy_file = function() return true end,
            progress = function() return true end,
            inject = function() return {unlocated = 0, unlocated_by_uid = {}} end,
            save_thoughts = function() return true end,
            merge_thoughts = function() return true end,
            atomic_write = function() return true end,
            read_file = function(p)
                if tostring(p):find("map%.json$") then
                    local raw = U.read_file(cache_file, true)
                    return raw
                end
                return nil
            end,
            store = nil,
        }
        for k, v in pairs(overrides or {}) do deps[k] = v end
        return deps
    end
    -- 首轮:两章 no_hit(引文与标题都失配)
    local report1 = Sync.run(build_deps())
    -- no_hit 全部落盘时 Sync.run 返回 nil+错误(匹配失败);此时缓存已写,
    -- 这正是要构造的"未匹配"起点。
    T.ok(report1 == nil, "首轮以匹配失败收尾(no_hit 落盘)")
    T.ok(U.file_exists(cache_file), "缓存已写")
    -- 手动指认第一章到 c1
    local ok = MapEditor.assign(cache_file, "1", "OEBPS/c1.xhtml",
        {{href = "OEBPS/c1.xhtml"}, {href = "OEBPS/c2.xhtml"}}, ChapterMap.ALGO_VERSION)
    T.ok(ok, "手动指认")
    -- 第二轮:第一章 manual 复用照常注入,第二章仍 no_hit
    local report2, err2 = Sync.run(build_deps())
    T.ok(report2, "第二轮成功(manual 救回): " .. tostring(err2))
    T.eq(report2.chapters_matched, 1, "仅 manual 章命中(另一章仍 no_hit)")
    os.remove(cache_file)
end)

T.case("R3 追加: spine 失效的手动条目被自动结果覆写,不再永留缓存", function()
    -- CodeRabbit #27 Caution 回归:manual 指认的目标文件从 spine 消失后,
    -- 加载段清标记回自动;自动匹配结果必须覆写掉失效 manual 条目,
    -- 否则每批重扫该章、编辑器永远显示过期指认。
    local Sync = require("pickthought.sync")
    local ChapterMap = require("pickthought.chapter_map")
    local cache_file = "tests/.tmp_map_editor_stale.json"
    os.remove(cache_file)
    local fixture = {api = {chapters = function() return {data = {
        {chapterUid = 1, title = "第一章 春江潮水", chapterIdx = 1}}} end},
        annotations = {fetch_chapter = function()
            return {underlines = {{range = "0-7", markText = "春江潮水连海平"}},
                review_map = {}, review_groups = {},
                underline_count = 1, thought_count = 0, thought_entry_count = 0, errors = {}}
        end}}
    local function build_deps(spine)
        return {
            doc_path = "fake.epub", book_id = "b1",
            api = fixture.api, annotations = fixture.annotations,
            map_cache_path = cache_file,
            spine = spine,
            read_text = function(_, href)
                return href == "OEBPS/c1.xhtml"
                    and "<html><body><p>春江潮水连海平。</p></body></html>"
                    or "<html><body><p>别处正文。</p></body></html>"
            end,
            load_meta = function() return {spine = spine,
                names = {"OEBPS/c1.xhtml", "OEBPS/c2.xhtml"}} end,
            file_exists = function(p) return p == "fake.epub.orig" or p == "fake.epub" end,
            file_size = function() return 100 end,
            content_fingerprint = function() return "fp" end,
            rename = function() return true, nil end,
            remove = function() return true end,
            copy_file = function() return true end,
            progress = function() return true end,
            inject = function() return {unlocated = 0, unlocated_by_uid = {}} end,
            save_thoughts = function() return true end,
            merge_thoughts = function() return true end,
            atomic_write = function() return true end,
            read_file = function(p)
                if tostring(p):find("map%.json$") then return U.read_file(cache_file, true) end
                return nil
            end,
        }
    end
    local old_spine = {{href = "OEBPS/c1.xhtml"}, {href = "OEBPS/c2.xhtml"}}
    -- 首轮:自动命中第一章(有老 spine)
    local report1 = Sync.run(build_deps(old_spine))
    T.ok(report1, "首轮成功")
    -- 手动指认到 c2
    local ok = MapEditor.assign(cache_file, "1", "OEBPS/c2.xhtml", old_spine,
        ChapterMap.ALGO_VERSION)
    T.ok(ok, "手动指认到 c2")
    -- 模拟 spine 变化:c2 被删,只剩 c1
    local new_spine = {{href = "OEBPS/c1.xhtml"}}
    local report2 = Sync.run(build_deps(new_spine))
    T.ok(report2, "spine 变化后仍成功")
    -- 失效 manual 必须已被自动结果覆写:条目不再是 manual 且指向现存文件
    local decoded = Json.decode(U.read_file(cache_file, true))
    local entry = decoded.map["1"]
    T.eq(entry.manual, nil, "失效 manual 标记已清除")
    T.eq(entry.hrefs[1], "OEBPS/c1.xhtml", "已被自动结果覆写为现存目标")
    -- 第三轮:同 spine 再跑,应零重扫(条目已是正常自动缓存)
    local reads3 = 0
    local deps3 = build_deps(new_spine)
    local raw_read = deps3.read_text
    deps3.read_text = function(...) reads3 = reads3 + 1 return raw_read(...) end
    local report3 = Sync.run(deps3)
    T.ok(report3, "第三轮成功")
    T.eq(reads3, 0, "覆写后的条目正常复用,不再反复重扫")
    os.remove(cache_file)
end)
