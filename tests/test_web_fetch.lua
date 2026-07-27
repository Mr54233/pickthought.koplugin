local WebFetch = require("pickthought.web_fetch")

local BEST = {bestBookMarks = {synckey = 1, totalCount = 3, chapters = {}, items = {
    {bookId = "b1", bookmarkId = "b1_116_2974-3006", chapterUid = 116,
     range = "2974-3006", markText = "亲密关系中满足的秘诀", totalCount = 9622, users = {}},
    {bookId = "b1", bookmarkId = "b1_116_2835-2850", chapterUid = 116,
     range = "2835-2850", markText = "我们总是喜欢那些喜欢我们的人。", totalCount = 7530, users = {}},
    {bookId = "b1", bookmarkId = "b1_119_10-20", chapterUid = 119,
     range = "10-20", markText = "第119章的划线", totalCount = 5, users = {}},
}}}

local REVIEWS = {synckey = 2, totalCount = 100, hasMore = 0, reviews = {
    {reviewId = "r1", review = {bookId = "b1", chapterUid = 116, range = "2974-3006",
        content = "深有同感", abstract = "亲密关系中[插图]满足的秘诀",
        createTime = 1700000000, author = {name = "读者甲", nick = "甲"}}},
    {reviewId = "r2", review = {bookId = "b1", chapterUid = 116, range = "2974-3006",
        content = "第二条想法", abstract = "", author = {nick = "乙"}}},
    {reviewId = "r3", review = {bookId = "b1", chapterUid = 116, range = "500-600",
        content = "没有对应热门划线的想法", abstract = "独立[插图]引文片段",
        author = {name = "丙"}}},
    {reviewId = "bad", review = {bookId = "b1", chapterUid = 116, range = "1-2", content = ""}},
}}

local REVIEWS_GW = {reviews = {
    {range = "2974-3006", pageReviews = {
        {reviewId = "r1", likesCount = 5, review = {content = "深有同感",
            abstract = "亲密关系中[插图]满足的秘诀", author = {name = "甲"}}},
        {reviewId = "r2", likesCount = 0, review = {content = "第二条想法",
            author = {nick = "乙"}}},
    }},
    {range = "500-600", pageReviews = {
        {likesCount = 1, review = {content = "独立段的想法", abstract = "独立引文片段",
            author = {name = "丙"}}},
    }},
}}

local function review_batches(ranges, size)
    size = tonumber(size) or 5
    local out = {}
    for first = 1, #(ranges or {}), size do
        local batch = {}
        for i = first, math.min(first + size - 1, #ranges) do
            batch[#batch + 1] = {range = ranges[i], maxIdx = 0, count = 30, synckey = 0}
        end
        out[#out + 1] = batch
    end
    return out
end

local function readreviews_from(rows)
    return function(_, _, uid, batch)
        local want = {}
        for _, item in ipairs(batch) do want[tostring(item.range)] = true end
        local out = {}
        for _, row in ipairs(rows) do
            local r = row.review or row
            local range = tostring((type(r) == "table" and r.range) or row.range or "")
            if want[range] then out[#out + 1] = row end
        end
        return {reviews = out}
    end
end

local function make_api(marks_fn, reviews_fn)
    return {
        web_bestbookmarks = marks_fn,
        review_batches = function(_, ranges, size) return review_batches(ranges, size) end,
        readreviews = reviews_fn,
    }
end

T.case("group_marks 按章分组", function()
    local by_uid = WebFetch.group_marks(BEST)
    T.eq(#by_uid["116"], 2, "116 章两条")
    T.eq(#by_uid["119"], 1, "119 章一条")
    T.eq(by_uid["116"][1].range, "2974-3006", "range 透传")
    T.eq(by_uid["116"][1].markText, "亲密关系中满足的秘诀", "markText 透传")
end)

T.case("build_reviews 扁平结构(web)", function()
    local map, groups = WebFetch.build_reviews(REVIEWS)
    T.eq(#groups, 2, "两个 range 组")
    T.eq(#map["2974-3006"], 2, "同 range 两条想法")
    T.eq(map["2974-3006"][1].content, "深有同感", "content")
    T.eq(map["2974-3006"][1].abstract, "亲密关系中满足的秘诀", "[插图] 清理")
    T.eq(map["2974-3006"][1].author, "读者甲", "作者优先 name")
    T.eq(map["2974-3006"][2].author, "乙", "无 name 用 nick")
    T.eq(map["500-600"][1].review_id, "r3", "review_id")
end)

T.case("build_reviews 展开嵌套 pageReviews(gateway)", function()
    local map, groups = WebFetch.build_reviews(REVIEWS_GW)
    T.eq(#groups, 2, "两个 range")
    T.eq(#map["2974-3006"], 2, "pageReviews 展开两条")
    T.eq(map["2974-3006"][1].content, "深有同感", "第一条 content")
    T.eq(tonumber(map["2974-3006"][1].likes), 5, "likes 从 pageReview 项取")
    T.eq(map["2974-3006"][2].author, "乙", "第二条作者")
    T.eq(#map["500-600"], 1, "另一段一条")
end)

T.case("build_chapter 合并划线与想法锚点", function()
    local by_uid = WebFetch.group_marks(BEST)
    local result = WebFetch.build_chapter("b1", "116", by_uid["116"], REVIEWS)
    T.eq(result.underline_count, 3, "2 热门划线 + 1 想法补位")
    T.eq(result.thought_count, 2, "两个想法组")
    T.eq(result.thought_entry_count, 3, "三条想法")
    local by_range = {}
    for _, row in ipairs(result.underlines) do by_range[row.range] = row end
    T.ok(by_range["2974-3006"] and by_range["2835-2850"], "热门划线都在")
    T.eq(by_range["500-600"].markText, "独立引文片段", "想法补位划线用清理后的 abstract")
    T.eq(#result.review_map["2974-3006"], 2, "review_map 对齐")
end)

T.case("fetch_chapter 按 range 拉想法(readreviews)", function()
    local fetcher = WebFetch:new(make_api(function() return BEST end, readreviews_from(REVIEWS.reviews)))
    local result = fetcher:fetch_chapter("b1", 116)
    T.eq(result.underline_count, 2, "划线 range 的想法拉回(独立想法 range 不在 bestbookmarks,本轮不拉)")
    T.eq(#result.errors, 0, "无错误")
    T.eq(result.thought_entry_count, 2, "2974-3006 两条按 range 拉回")
    local again = fetcher:fetch_chapter("b1", "119")
    T.eq(again.underline_count, 1, "热门划线整本缓存后按章取")
end)

T.case("fetch_chapter 划线失败硬失败,想法失败不拖垮划线", function()
    local hard = WebFetch:new(make_api(function() error("HTTP 403") end,
        readreviews_from(REVIEWS.reviews))):fetch_chapter("b1", 116)
    T.eq(hard.underline_request_ok, false, "划线失败=整章硬失败")
    T.ok(tostring(hard.errors[1]):find("403", 1, true), "错误透传")

    local partial = WebFetch:new(make_api(function() return BEST end,
        function() error("timeout") end)):fetch_chapter("b1", 116)
    T.eq(partial.underline_request_ok, true, "想法失败不拖垮划线")
    T.eq(partial.underline_count, 2, "只有热门划线")
    T.ok(#partial.errors > 0, "记为部分失败")
end)

T.case("fetch_chapter 按 range 拉同段多条(gateway 嵌套)", function()
    local fetcher = WebFetch:new(make_api(function() return BEST end,
        readreviews_from(REVIEWS_GW.reviews)))
    local result = fetcher:fetch_chapter("b1", 116)
    local found = 0
    for _, g in ipairs(result.review_groups or {}) do
        if g.range == "2974-3006" then found = #g.texts end
    end
    T.eq(found, 2, "2974-3006 段两条想法(不再是热门前1-2)")
end)
