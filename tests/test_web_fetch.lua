local WebFetch = require("pickthought.web_fetch")

-- fixture 来自真机探测(bestbookmarks / review/list 的真实形状)
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

T.case("group_marks 按章分组", function()
    local by_uid = WebFetch.group_marks(BEST)
    T.eq(#by_uid["116"], 2, "116 章两条")
    T.eq(#by_uid["119"], 1, "119 章一条")
    T.eq(by_uid["116"][1].range, "2974-3006", "range 透传")
    T.eq(by_uid["116"][1].markText, "亲密关系中满足的秘诀", "markText 透传")
end)

T.case("build_reviews 按 range 分组并清理引文", function()
    local map, groups = WebFetch.build_reviews(REVIEWS)
    T.eq(#groups, 2, "两个 range 组(空 content 丢弃)")
    T.eq(#map["2974-3006"], 2, "同 range 两条想法")
    T.eq(map["2974-3006"][1].content, "深有同感", "content")
    T.eq(map["2974-3006"][1].abstract, "亲密关系中满足的秘诀", "[插图] 清理")
    T.eq(map["2974-3006"][1].author, "读者甲", "作者优先 name")
    T.eq(map["2974-3006"][2].author, "乙", "无 name 用 nick")
    T.eq(map["500-600"][1].review_id, "r3", "review_id")
end)

T.case("build_chapter 合并划线与想法锚点", function()
    local by_uid = WebFetch.group_marks(BEST)
    local result = WebFetch.build_chapter("b1", "116", by_uid["116"], REVIEWS)
    T.eq(result.underline_count, 3, "2 热门划线 + 1 想法补位")
    T.eq(result.thought_count, 2, "两个想法组")
    T.eq(result.thought_entry_count, 3, "三条想法")
    T.eq(result.underline_request_ok, true, "成功标志")
    local by_range = {}
    for _, row in ipairs(result.underlines) do by_range[row.range] = row end
    T.ok(by_range["2974-3006"] and by_range["2835-2850"], "热门划线都在")
    T.eq(by_range["500-600"].markText, "独立引文片段", "想法补位划线用清理后的 abstract")
    T.eq(#result.review_map["2974-3006"], 2, "review_map 对齐")
end)

T.case("fetch_chapter 成功与降级路径", function()
    local api_ok = {
        web_bestbookmarks = function() return BEST end,
        web_chapter_reviews = function(_, _, uid)
            return tostring(uid) == "116" and REVIEWS or {reviews = {}}
        end,
    }
    local fetcher = WebFetch:new(api_ok)
    local result = fetcher:fetch_chapter("b1", 116)
    T.eq(result.underline_count, 3, "全链路成功")
    T.eq(#result.errors, 0, "无错误")
    local again = fetcher:fetch_chapter("b1", "119")
    T.eq(again.underline_count, 1, "热门划线整本缓存后按章取")

    local api_marks_fail = {
        web_bestbookmarks = function() error("HTTP 403") end,
        web_chapter_reviews = function() return REVIEWS end,
    }
    local hard = WebFetch:new(api_marks_fail):fetch_chapter("b1", 116)
    T.eq(hard.underline_request_ok, false, "热门划线失败=整章硬失败")
    T.ok(tostring(hard.errors[1]):find("403", 1, true), "错误透传")

    local api_reviews_fail = {
        web_bestbookmarks = function() return BEST end,
        web_chapter_reviews = function() error("timeout") end,
    }
    local partial = WebFetch:new(api_reviews_fail):fetch_chapter("b1", 116)
    T.eq(partial.underline_request_ok, true, "想法失败不拖垮划线")
    T.eq(partial.underline_count, 2, "只有热门划线")
    T.eq(#partial.errors, 1, "记为部分失败")
end)
