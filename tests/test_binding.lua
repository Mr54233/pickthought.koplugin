local Binding = require("pickthought.binding")

local function count(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

T.case("normalize_search 容错三种形状", function()
    local nested = {books = {
        {bookInfo = {bookId = "b1", title = "春江花月夜", author = "张若虚"}},
        {bookInfo = {title = "无 id 应被丢弃"}},
    }}
    local rows = Binding.normalize_search(nested)
    T.eq(#rows, 1, "嵌套 bookInfo + 丢弃无 id")
    T.eq(rows[1].book_id, "b1", "book_id")
    T.eq(rows[1].title, "春江花月夜", "title")
    T.eq(rows[1].author, "张若虚", "author")

    local flat = {results = {{bookId = "b2", title = "平铺"}}}
    T.eq(Binding.normalize_search(flat)[1].book_id, "b2", "results 平铺")

    local direct = {{bookId = 33, title = "直接数组"}}
    T.eq(Binding.normalize_search(direct)[1].book_id, "33", "直接数组 + 数字 id 转字符串")

    T.eq(#Binding.normalize_search(nil), 0, "nil 安全")
    T.eq(#Binding.normalize_search("oops"), 0, "非表安全")
end)

T.case("normalize_search 处理 /store/search 真实分组形状", function()
    local grouped = {totalCount = 2, results = {
        {type = 1, books = {
            {bookInfo = {bookId = "b1", title = "春江花月夜", author = "张若虚"}},
            {bookInfo = {bookId = "b2", title = "春江水暖", author = "某人"}},
        }},
        {type = 2, books = {{bookInfo = {bookId = "b3", title = "第三本"}}}},
    }}
    local rows = Binding.normalize_search(grouped)
    T.eq(#rows, 3, "分组 results[].books[] 全部下钻")
    T.eq(rows[1].book_id, "b1", "组1书1")
    T.eq(rows[3].book_id, "b3", "组2书1")
end)

T.case("normalize_chapters 处理书记录嵌套与 chapterInfos", function()
    local nested = {data = {
        {bookId = "other", updated = {{chapterUid = 99, title = "别的书"}}},
        {bookId = "b001", updated = {
            {chapterUid = 1, title = "第一章", chapterIdx = 1},
            {chapterUid = 2, title = "第二章", chapterIdx = 2},
        }},
    }}
    local rows = Binding.normalize_chapters(nested, "b001")
    T.eq(#rows, 2, "按 bookId 选中目标书记录")
    T.eq(rows[1].uid, "1", "下钻 updated 内层")

    local no_match = Binding.normalize_chapters(nested, "nope")
    T.eq(no_match[1].uid, "99", "无匹配记录时退回第一条记录")

    local infos = {chapterInfos = {{chapterUid = 5, title = "五"}}}
    T.eq(Binding.normalize_chapters(infos)[1].uid, "5", "chapterInfos 键")
end)

T.case("normalize_chapters 容错与排序", function()
    local data = {data = {
        {chapterUid = 2, title = "第二章", chapterIdx = 2},
        {chapterUid = 1, title = "第一章", chapterIdx = 1},
        {title = "无 uid 丢弃"},
    }}
    local rows = Binding.normalize_chapters(data)
    T.eq(#rows, 2, "丢弃无 uid")
    T.eq(rows[1].uid, "1", "按 chapterIdx 排序,uid 字符串化")
    T.eq(rows[2].title, "第二章", "title 保留")

    local updated = {updated = {{chapterUid = "7", title = "更新形状"}}}
    T.eq(Binding.normalize_chapters(updated)[1].uid, "7", "updated 形状")

    local direct = {{chapterUid = 9}}
    T.eq(Binding.normalize_chapters(direct)[1].uid, "9", "直接数组,无 title 容忍")
    T.eq(#Binding.normalize_chapters(nil), 0, "nil 安全")
end)

T.case("normalize_chapters 认真实 web 端点形状(顶层 chapters)", function()
    -- 真机实测 /web/book/chapterInfos 返回 {bookId?, synckey?, chapters:[...]}
    local real = {bookId = "22584111", synckey = 1119519248,
        chapters = {
            {chapterUid = 1, title = "封面", chapterIdx = 1},
            {chapterUid = 3, title = "临讲", chapterIdx = 2},
        }}
    local rows = Binding.normalize_chapters(real, "22584111")
    T.eq(#rows, 2, "顶层 chapters 直接识别")
    T.eq(rows[1].uid, "1", "uid 提取")
    T.eq(rows[2].uid, "3", "保留原 chapterUid(非连续)")
    -- 无 bookId 字段的返回(仅 synckey)也应识别,这是 40638616 失败的形态
    local no_book = {synckey = 1, chapters = {{chapterUid = 1, title = "x", chapterIdx = 1}}}
    T.eq(#Binding.normalize_chapters(no_book), 1, "无 bookId 仍识别 chapters")
end)

T.case("绑定存取清", function()
    local kv = {}
    local store = {
        get = function(_, k, d) return kv[k] ~= nil and kv[k] or d end,
        set = function(_, k, v) kv[k] = v end,
    }
    T.eq(Binding.get(store, "/books/a.epub"), nil, "未绑定返回 nil")
    Binding.save(store, "/books/a.epub", {book_id = "b1", title = "书", author = "作者"})
    local rec = Binding.get(store, "/books/a.epub")
    T.eq(rec.book_id, "b1", "保存后可读")
    T.ok(tonumber(rec.bound_at), "自动记录 bound_at")
    Binding.save(store, "/books/b.epub", {book_id = "b2"})
    Binding.clear(store, "/books/a.epub")
    T.eq(Binding.get(store, "/books/a.epub"), nil, "清除生效")
    T.eq(Binding.get(store, "/books/b.epub").book_id, "b2", "不影响其他绑定")
end)

T.case("normalize_search 标注版本类型(format)", function()
    local rows = Binding.normalize_search{books={
        {bookInfo={bookId="b1", title="剑来", author="烽火", format="txt"}},
        {bookInfo={bookId="b2", title="剑来精校", author="烽火", format="epub"}},
        {bookInfo={bookId="b3", title="未知版", author="x"}},
    }}
    T.eq(rows[1].title, "剑来 [网络]", "txt 标网络")
    T.eq(rows[2].title, "剑来精校 [出版]", "epub 标出版")
    T.eq(rows[3].title, "未知版", "无 format 不标注")
end)

T.case("绑定支持一本本地书绑多本微信读书书(1:N)", function()
    local kv = {}
    local store = {
        get = function(_, k, d) return kv[k] ~= nil and kv[k] or d end,
        set = function(_, k, v) kv[k] = v end,
    }
    local path = "/books/合集.epub"
    Binding.save(store, path, {book_id = "b1", title = "甲", author = "作者A"})
    Binding.save(store, path, {book_id = "b2", title = "乙", author = "作者B"})
    local records = Binding.records(store, path)
    T.eq(count(records), 2, "两本并存")
    T.ok(records["b1"] and records["b2"], "按 book_id 建 map")
    -- 同 book_id 覆盖,不新增
    Binding.save(store, path, {book_id = "b1", title = "甲(修订)"})
    T.eq(count(Binding.records(store, path)), 2, "同 id 覆盖不新增")
    T.eq(Binding.get_record(store, path, "b1").title, "甲(修订)", "覆盖生效")
    -- 移除一本,另一本仍在
    Binding.remove(store, path, "b1")
    T.eq(count(Binding.records(store, path)), 1, "移除后剩一本")
    T.ok(Binding.get_record(store, path, "b2"), "另一本保留")
    -- 移除最后一本质空(map 退化空表,键从 bindings 中清除)
    Binding.remove(store, path, "b2")
    T.eq(count(Binding.records(store, path)), 0, "全移除后键被清")
end)

T.case("绑定旧单键格式自动迁移为 1:N map", function()
    local kv = {}
    local store = {
        get = function(_, k, d) return kv[k] ~= nil and kv[k] or d end,
        set = function(_, k, v) kv[k] = v end,
    }
    local path = "/books/旧.epub"
    -- 旧版:all[doc_path] 直接是单条记录
    kv["bindings"] = {[path] = {book_id = "old1", title = "旧书", bound_at = 100}}
    local rec = Binding.get(store, path)
    T.eq(rec.book_id, "old1", "旧格式可读")
    -- 读取即迁移并落盘
    local migrated = kv["bindings"][path]
    T.ok(type(migrated) == "table" and migrated["old1"], "已迁移为 map")
    -- 迁移后仍能正常加第二本
    Binding.save(store, path, {book_id = "old2", title = "新书"})
    T.eq(count(Binding.records(store, path)), 2, "迁移后可继续 1:N")
end)

T.case("Binding.get 返回最近绑定的主书,list 按时间升序", function()
    local kv = {}
    local store = {
        get = function(_, k, d) return kv[k] ~= nil and kv[k] or d end,
        set = function(_, k, v) kv[k] = v end,
    }
    local path = "/books/p.epub"
    Binding.save(store, path, {book_id = "first", bound_at = 10})
    Binding.save(store, path, {book_id = "second", bound_at = 20})
    T.eq(Binding.get(store, path).book_id, "second", "最近绑定为主")
    local list = Binding.list(store, path)
    T.eq(#list, 2, "list 两本")
    T.eq(list[1].book_id, "first", "list 首为最早")
    T.eq(list[2].book_id, "second", "list 末尾最近")
end)

T.case("Binding 同一时间绑定按持久化顺序稳定裁决", function()
    local kv = {}
    local store = {
        get = function(_, k, d) return kv[k] ~= nil and kv[k] or d end,
        set = function(_, k, v) kv[k] = v end,
    }
    local path = "/books/same-second.epub"
    Binding.save(store, path, {book_id = "first", bound_at = 100})
    Binding.save(store, path, {book_id = "second", bound_at = 100})
    local records = Binding.records(store, path)
    T.eq(records.first.bound_order, 1, "首条绑定顺序")
    T.eq(records.second.bound_order, 2, "后绑定顺序")
    T.eq(Binding.get(store, path).book_id, "second", "同一时间最近绑定为主")
    local list = Binding.list(store, path)
    T.eq(list[1].book_id, "first", "同一时间列表首项稳定")
    T.eq(list[2].book_id, "second", "同一时间列表末项稳定")
end)

T.case("normalize_chapters 兼容旧字段 chapterId/uid (P2#6)", function()
    -- 旧网关章节响应用 chapterId 或 uid 而非 chapterUid,归一化不得丢章。
    local with_chapterId = {{chapterId = 11, title = "旧Id章", chapterIdx = 1}}
    local rows = Binding.normalize_chapters(with_chapterId)
    T.eq(#rows, 1, "chapterId 被识别")
    T.eq(rows[1].uid, "11", "chapterId 作 uid")

    local with_uid = {{uid = 22, title = "仅uid", chapterIdx = 2}}
    T.eq(Binding.normalize_chapters(with_uid)[1].uid, "22", "uid 被识别")

    -- 混合:部分新部分旧,都不丢。
    local mixed = {
        {chapterUid = 1, title = "新", chapterIdx = 1},
        {chapterId = 2, title = "旧", chapterIdx = 2},
    }
    T.eq(#Binding.normalize_chapters(mixed), 2, "新旧混排都保留")
end)

T.case("normalize_search 兼容旧字段 book_id / updated (P2#6)", function()
    -- 旧网关搜索结果用 book_id(下划线)而非 bookId,归一化不得丢结果。
    local underscore = {{book_id = "b9", title = "旧字段书", author = "某人"}}
    local rows = Binding.normalize_search(underscore)
    T.eq(#rows, 1, "book_id 被识别")
    T.eq(rows[1].book_id, "b9", "book_id 作 book_id")

    -- 直接数组里混用 bookId / book_id。
    local mixed = {{bookId = "a1", title = "新"}, {book_id = "a2", title = "旧"}}
    local rows2 = Binding.normalize_search(mixed)
    T.eq(#rows2, 2, "bookId 与 book_id 混排都保留")
    T.eq(rows2[1].book_id, "a1", "首条")
    T.eq(rows2[2].book_id, "a2", "次条")

    -- updated 容器下的搜索结果也能被收集。
    local in_updated = {updated = {{bookId = "u1", title = "updated内"}}}
    T.eq(Binding.normalize_search(in_updated)[1].book_id, "u1", "updated 容器被收集")
end)

-- 评审三轮收尾:部分微信读书网关返回的子书记录用 book_id(下划线)而非 bookId,
-- normalize_chapters 在 data.data 混排时仍须按目标书命中,否则该书章节被漏掉。
T.case("normalize_chapters 兼容 data.data 混排 bookId 与 book_id(收尾)", function()
    local data = {data = {
        {bookId = "other", updated = {{chapterUid = 1, title = "别的书"}}},
        {book_id = "b001", updated = {{chapterUid = 2, title = "目标书"}}},
    }}
    local rows = Binding.normalize_chapters(data, "b001")
    T.eq(#rows, 1, "按 book_id(下划线)命中目标书记录")
    T.eq(rows[1].title, "目标书", "返回目标书的章节而非别的书")
end)
