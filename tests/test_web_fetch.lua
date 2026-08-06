package.preload["ltn12"] = function()
    return {source = {string = function(value) return value end},
        sink = {table = function() return function() end end}}
end
package.preload["socketutil"] = function()
    return {set_timeout = function() end, reset_timeout = function() end}
end

local WebFetch = require("pickthought.web_fetch")
local Http = require("pickthought.http")
local Api = require("pickthought.api")

-- /book/underlines 按章返回(该章所有划线,不限热度)
local UNDERLINES_116 = {underlines = {
    {range = "2974-3006", markText = "亲密关系中满足的秘诀"},
    {range = "2835-2850", markText = "我们总是喜欢那些喜欢我们的人。"},
}}
local UNDERLINES_119 = {underlines = {
    {range = "10-20", markText = "第119章的划线"},
}}

-- /book/readreviews 扁平(web 兼容)
local REVIEWS = {reviews = {
    {reviewId = "r1", review = {range = "2974-3006", content = "深有同感",
        abstract = "亲密关系中[插图]满足的秘诀", author = {name = "读者甲", nick = "甲"}}},
    {reviewId = "r2", review = {range = "2974-3006", content = "第二条想法",
        author = {nick = "乙"}}},
    {reviewId = "r3", review = {range = "500-600", content = "独立段的想法",
        abstract = "独立[插图]引文片段", author = {name = "丙"}}},
    {reviewId = "bad", review = {range = "1-2", content = ""}},
}}

-- gateway pageReviews 嵌套(一 range 多想法)
local REVIEWS_GW = {reviews = {
    {range = "2974-3006", pageReviews = {
        {reviewId = "r1", likesCount = 5, review = {content = "深有同感",
            abstract = "亲密关系中[插图]满足的秘诀", author = {name = "甲"}}},
        {reviewId = "r2", likesCount = 0, review = {content = "第二条想法",
            author = {nick = "乙"}}},
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

local function make_api(underlines_fn, reviews_fn)
    return {
        underlines = function(_, _, uid) return underlines_fn(uid) end,
        review_batches = function(_, ranges, size) return review_batches(ranges, size) end,
        readreviews = reviews_fn,
    }
end

T.case("build_reviews 扁平结构", function()
    local map, groups = WebFetch.build_reviews(REVIEWS)
    T.eq(#groups, 2, "两个 range 组(空 content 丢弃)")
    T.eq(#map["2974-3006"], 2, "同 range 两条想法")
    T.eq(map["2974-3006"][1].content, "深有同感", "content")
    T.eq(map["2974-3006"][1].abstract, "亲密关系中满足的秘诀", "[插图] 清理")
    T.eq(map["2974-3006"][1].author, "读者甲", "作者优先 name")
    T.eq(map["500-600"][1].review_id, "r3", "review_id")
end)

T.case("build_reviews 展开嵌套 pageReviews(gateway)", function()
    local map, groups = WebFetch.build_reviews(REVIEWS_GW)
    T.eq(#groups, 1, "一个 range")
    T.eq(#map["2974-3006"], 2, "pageReviews 展开两条")
    T.eq(tonumber(map["2974-3006"][1].likes), 5, "likes 从 pageReview 项取")
end)

T.case("build_chapter 合并划线与想法锚点", function()
    local marks_rows = {
        {range = "2974-3006", markText = "亲密关系中满足的秘诀"},
        {range = "2835-2850", markText = "我们总是喜欢那些喜欢我们的人。"},
    }
    local result = WebFetch.build_chapter("b1", "116", marks_rows, REVIEWS)
    T.eq(result.underline_count, 3, "2 划线 + 1 想法补位(500-600)")
    T.eq(result.thought_entry_count, 3, "三条想法")
    local by_range = {}
    for _, row in ipairs(result.underlines) do by_range[row.range] = row end
    T.eq(by_range["500-600"].markText, "独立引文片段", "想法补位用清理后 abstract")
end)

T.case("fetch_chapter: underlines + readreviews 全链路", function()
    local fetcher = WebFetch:new(make_api(
        function(uid) return tostring(uid) == "116" and UNDERLINES_116 or UNDERLINES_119 end,
        readreviews_from(REVIEWS.reviews)
    ))
    local result = fetcher:fetch_chapter("b1", 116)
    T.eq(result.underline_count, 2, "该章所有划线(underlines 按章)")
    T.eq(result.thought_entry_count, 2, "2974-3006 两条想法(readreviews 按 range)")
    T.eq(#result.errors, 0, "无错误")
    local again = fetcher:fetch_chapter("b1", "119")
    T.eq(again.underline_count, 1, "119 章 1 划线")
end)

T.case("fetch_chapter: underlines 失败=硬失败,readreviews 失败不拖垮划线", function()
    local hard = WebFetch:new(make_api(
        function() error("HTTP 403") end,
        readreviews_from(REVIEWS.reviews)
    )):fetch_chapter("b1", 116)
    T.eq(hard.underline_request_ok, false, "underlines 失败=整章硬失败")
    T.ok(tostring(hard.errors[1]):find("403", 1, true), "错误透传")

    local partial = WebFetch:new(make_api(
        function(uid) return UNDERLINES_116 end,
        function() error("timeout") end
    )):fetch_chapter("b1", 116)
    T.eq(partial.underline_request_ok, true, "想法失败不拖垮划线")
    T.eq(partial.underline_count, 2, "划线仍在")
    T.ok(#partial.errors > 0, "记为部分失败")
end)

T.case("fetch_chapter: readreviews 按 range 拉同段多条(gateway 嵌套)", function()
    local fetcher = WebFetch:new(make_api(
        function(uid) return UNDERLINES_116 end,
        readreviews_from(REVIEWS_GW.reviews)
    ))
    local result = fetcher:fetch_chapter("b1", 116)
    local found = 0
    for _, g in ipairs(result.review_groups or {}) do
        if g.range == "2974-3006" then found = #g.texts end
    end
    T.eq(found, 2, "2974-3006 段两条想法(pageReviews 展开)")
end)

T.case("499 限流被识别并停止当前章节批次", function()
    T.ok(Http.is_rate_limit_error("HTTP 499: 请求频率超限,请稍后再试"), "499 限流错误应识别")
    local result = WebFetch:new(make_api(
        function() return UNDERLINES_116 end,
        function() error("HTTP 499: 请求频率超限,请稍后再试") end
    )):fetch_chapter("b1", 116)
    T.eq(result.rate_limited, true, "章节标记限流")
    T.eq(result.rate_limit_wait, 2, "首次限流建议等待 2 秒")
    T.eq(result.underline_count, 2, "已有划线仍保留在结果中")
end)

T.case("Web 接口失败时回退 Agent Gateway", function()
    local calls = {}
    local fake_http = {
        get_json = function(_, url)
            calls[#calls + 1] = url
            error("HTTP 503")
        end,
        post_json = function(_, url, payload)
            calls[#calls + 1] = url
            if url:find("readReviews", 1, true) then error("HTTP 503") end
            return {underlines = {{range = "0-7", markText = "春江潮水连海平"}}}
        end,
    }
    local fake_store = {auth = function() return {api_key = "test-key"} end}
    local api = Api:new(fake_http, fake_store)
    local underlines = api:underlines("b1", 116)
    T.eq(underlines._annotation_source, "agent", "Web underlines 失败后走 Agent")
    local reviews = api:readreviews("b1", 116, {{range = "0-7"}})
    T.eq(reviews._annotation_source, "agent", "Web readReviews 失败后走 Agent")
    T.ok(calls[1]:find("/web/book/underlines", 1, true), "先尝试 Web underlines")
    T.ok(calls[2]:find("api/agent/gateway", 1, true), "underlines 回退 Gateway")
    T.ok(calls[3]:find("/web/book/readReviews", 1, true), "先尝试 Web readReviews")
    T.ok(calls[4]:find("api/agent/gateway", 1, true), "readReviews 回退 Gateway")
end)

T.case("Web 接口成功时不调用 Agent Gateway", function()
    local calls = {}
    local fake_http = {
        get_json = function(_, url, options)
            calls[#calls + 1] = {url = url, options = options}
            return {underlines = {}}
        end,
        post_json = function(_, url, payload, options)
            calls[#calls + 1] = {url = url, options = options}
            return {reviews = {}}
        end,
    }
    local fake_store = {auth = function() return {api_key = "test-key"} end}
    local api = Api:new(fake_http, fake_store)
    T.eq(api:underlines("b1", 116)._annotation_source, "web", "Web underlines 成功优先")
    T.eq(api:readreviews("b1", 116, {{range = "0-7"}})._annotation_source, "web",
        "Web readReviews 成功优先")
    T.eq(#calls, 2, "Web 成功不触发 Agent")
    T.eq(calls[1].options.pacing_scope, "annotations-web", "Web 使用独立节流域")
    T.eq(calls[2].options.shared_pacing, true, "Web 使用共享节流")
end)

T.case("大批次参数错误时二分拆分,不逐条盲重试", function()
    local ranges = {
        {range = "1-2", markText = "亲密关系中满足的秘诀"},
        {range = "3-4", markText = "我们总是喜欢那些喜欢我们的人。"},
        {range = "5-6", markText = "独立段的想法"},
    }
    local calls = {}
    local fetcher = WebFetch:new({
        underlines = function() return {underlines = ranges} end,
        review_batches = function(_, items) return {items} end,
        readreviews = function(_, _, _, batch)
            calls[#calls + 1] = #batch
            if #batch > 1 then error("params error(node)") end
            return {reviews = {}}
        end,
    })
    local result = fetcher:fetch_chapter("b1", 116)
    T.eq(#calls, 5, "3 个 range 的二分请求为 5 次,不退化为额外逐条循环")
    T.eq(result.rate_limited, nil, "参数错误不应误判为限流")
    T.eq(#result.errors, 0, "拆分后单 range 全部成功")
end)
