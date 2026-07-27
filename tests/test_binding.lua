local Binding = require("pickthought.binding")

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
