-- 评论视图内容构建(居中/底部共用 comments_view,实施文档 §5)。

STUBS = STUBS or require("tests.stubs")
package.loaded["pickthought.thought_popup.comments_view"] = nil
local CommentsView = require("pickthought.thought_popup.comments_view")

local parent = {
    author = "原作者",
    content = "这是被长按的想法正文",
    likes_count = 5,
    review_id = "parent-r",
}
local comments = {
    { author = "甲", content = "评论一", likes_count = 1, review_id = "c1" },
    { author = "乙", content = "评论二", likes_count = 2, review_id = "" },
    { content = "没有作者" },
}

T.case("居中布局:items 只含评论(想法显示在标题栏)", function()
    local items = CommentsView.build_items(parent, comments, "center")
    T.eq(#items, 3, "仅 3 条评论,父想法不上内容区")
    T.eq(items[1].author, "甲")
    T.eq(items[1].content, "评论一")
    T.eq(CommentsView.comment_title(parent), "这是被长按的想法正文",
        "标题=被长按的想法本身(显示在原文摘录的位置)")
    T.eq(items[2].author, "乙")
end)

T.case("底部布局:父想法 content 进 quote 块,meta 行不渲染", function()
    local items = CommentsView.build_items(parent, comments, "bottom")
    T.eq(#items, 4)
    T.eq(items[1].abstract, parent.content, "abstract 由 quote 块渲染为摘要")
    T.eq(items[1].content, "", "content 置空避免正文重复")
    T.eq(items[1].author, "", "author 置空:想法原文下不再多一行作者名")
    T.eq(items[1].likes_count, 0, "likes 置空:meta 行整体不渲染")
    T.eq(items[1].review_id, "parent-r")
    T.eq(CommentsView.first_item_has_meta(items), false,
        "首条无 meta:_findItemAtContentY 定位需偏移 +1")
end)

T.case("first_item_has_meta:作者/赞/评论数任一非空即渲染 meta 行", function()
    T.eq(CommentsView.first_item_has_meta({ { author = "张三" } }), true)
    T.eq(CommentsView.first_item_has_meta({ { author = "", likes_count = 3 } }), true)
    T.eq(CommentsView.first_item_has_meta({ { author = "", comment_count = 2 } }), true)
    T.eq(CommentsView.first_item_has_meta({ { author = "", likes_count = 0 } }), false)
    T.eq(CommentsView.first_item_has_meta({}), false, "空条目不崩溃返回 false")
    T.eq(CommentsView.first_item_has_meta(nil), false)
    -- 想法列表视图(两条普通想法):首条有作者,meta 定位不偏移
    T.eq(CommentsView.first_item_has_meta({
        { author = "甲", content = "一" }, { author = "乙", content = "二" },
    }), true)
end)

T.case("items_in_view:按 y 窗口取可见条目,映射规则与长按定位一致", function()
    local items = {
        { author = "原作者", content = "想法" },
        { author = "甲", content = "评论一" },
        { author = "乙", content = "评论二" },
    }
    local pieces = {
        { variant = "quote", y = 0, piece_h = 10 },
        { variant = "meta", y = 10, piece_h = 10 },
        { variant = "content", y = 20, piece_h = 30 },
        { variant = "meta", y = 50, piece_h = 10 },
        { variant = "content", y = 60, piece_h = 10 },
        { variant = "meta", y = 70, piece_h = 10 },
    }
    local view = CommentsView.items_in_view(items, pieces, 0, 35)
    T.eq(#view, 1, "首屏窗口 [0,35):quote+首条 meta+其正文")
    T.eq(view[1], items[1])
    view = CommentsView.items_in_view(items, pieces, 45, 80)
    T.eq(#view, 2, "窗口 [45,80):meta 行在窗内的才算可见(正文尾巴不算)")
    T.eq(view[1], items[2])
    T.eq(view[2], items[3])
    -- 首条无 meta(底部评论视图形状):父想法纯 quote,两条评论两个 meta,
    -- base=1 → 第 k 个 meta 对应 items[k+1]
    local comment_items = { { author = "" }, { author = "甲" }, { author = "乙" } }
    local comment_pieces = {
        { variant = "quote", y = 0, piece_h = 10 },
        { variant = "meta", y = 10, piece_h = 10 },
        { variant = "content", y = 20, piece_h = 30 },
        { variant = "meta", y = 50, piece_h = 10 },
        { variant = "content", y = 60, piece_h = 10 },
    }
    view = CommentsView.items_in_view(comment_items, comment_pieces, 45, 80)
    T.eq(#view, 1, "meta 在窗外的条目不算可见(滚回来时再补)")
    T.eq(view[1], comment_items[3])
    -- 异常输入不崩溃
    T.eq(#CommentsView.items_in_view(nil, pieces, 0, 10), 0)
    T.eq(#CommentsView.items_in_view(items, nil, 0, 10), 0)
    T.eq(#CommentsView.items_in_view(items, pieces, 10, 10), 0, "空窗口返回空表")
end)

T.case("空作者与空内容评论的兜底与过滤", function()
    local items = CommentsView.build_items(parent, comments, "center")
    T.eq(items[3].author, "微信读书用户", "无作者评论兜底")
    T.eq(items[3].content, "没有作者")
    local filtered = CommentsView.build_items(parent, {
        { author = "甲", content = "   " },
        { author = "乙", content = "" },
    }, "center")
    T.eq(#filtered, 0, "空内容评论不进入渲染条目")
end)

T.case("异常输入不崩溃:父想法/评论非 table", function()
    local items = CommentsView.build_items(nil, nil, "center")
    T.eq(#items, 0, "居中布局无评论即空列表")
    T.eq(CommentsView.comment_title(nil), "", "父想法缺失时标题为空")
    local items2 = CommentsView.build_items(parent, { "junk", 42 }, "bottom")
    T.eq(#items2, 1, "非 table 评论被过滤(仅父想法 quote)")
end)
