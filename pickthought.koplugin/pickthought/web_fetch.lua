-- 数据源:微信读书划线 + 想法。
-- 划线走 /book/underlines(gateway,按章,返回该章所有划线,不限热度);
-- 想法走 /book/readreviews(gateway,按 range 拉该段全部,count=30)。
-- 输出与原 Annotations:fetch_chapter 同形:
-- {underlines, review_map, review_groups, underline_count, thought_count,
--  thought_entry_count, errors, underline_request_ok}
--
-- 历史:fork 时网关 403,把 underlines 换成 /web/book/bestbookmarks(web,整本热门 top),
-- 但 bestbookmarks 只给热门划线 range,非热门段(却有想法)的 range 丢失,readreviews
-- 按缺不全的 range 拉就漏大量想法(真机:118 章 bestbookmarks 1 划线,实际该章几十个 range)。
-- 现恢复上游(weread/miuread)的 underlines 做法——该章所有划线,range 覆盖全。
local logger = require("logger")

local WebFetch = {}
WebFetch.__index = WebFetch

local function scalar_str(v)
    local kind = type(v)
    if kind == "string" or kind == "number" then return tostring(v) end
    return ""
end

-- 想法引文里的排版占位([插图] 等)不在正文里,留着会毁掉引文对齐。
local function clean_quote(text)
    return (tostring(text or ""):gsub("%[插图%]", ""))
end

-- 从 /book/underlines 返回里提取该章划线条目。
-- gateway 返回结构含 underlines/updated/bookmarks 任一键(同 miuread array_from);
-- 兼容直接是数组的情况。每条归一化为 {range, markText},range 兼容 range/markRange/bookmarkRange。
local function extract_underlines(data)
    local raw = {}
    if type(data) == "table" then
        for _, key in ipairs({"underlines", "updated", "bookmarks"}) do
            if type(data[key]) == "table" then raw = data[key]; break end
        end
        if #raw == 0 and type(data[1]) == "table" then raw = data end
    end
    local out = {}
    for _, row in ipairs(raw) do
        if type(row) == "table" then
            local range = scalar_str(row.range or row.markRange or row.bookmarkRange)
            if range ~= "" then
                out[#out + 1] = {range = range, markText = scalar_str(row.markText or row.mark_text)}
            end
        end
    end
    return out
end

function WebFetch.build_reviews(data)
    local map, order = {}, {}
    for _, row in ipairs(type(data) == "table" and data.reviews or {}) do
        if type(row) == "table" then
            local r = type(row.review) == "table" and row.review or row
            local range = scalar_str(r.range)
            if range ~= "" then
                -- gateway /book/readreviews 按 range 返回,想法嵌在 pageReviews(一 range 多条);
                -- 旧 /web/review/list 扁平,每 row 一条。兼容两种结构。
                local entries = type(row.pageReviews) == "table" and row.pageReviews or {row}
                if not map[range] then map[range] = {}; order[#order + 1] = range end
                local texts = map[range]
                for _, pr in ipairs(entries) do
                    local thought = (type(pr) == "table" and type(pr.review) == "table") and pr.review
                        or (type(pr) == "table" and pr) or {}
                    local content = scalar_str(thought.content)
                    if content ~= "" then
                        local author = type(thought.author) == "table" and thought.author or {}
                        texts[#texts + 1] = {
                            content = content,
                            abstract = clean_quote(thought.abstract or thought.contextAbstract),
                            author = scalar_str(author.name or author.nick),
                            likes = tonumber(pr.likesCount or thought.likesCount or row.likesCount or 0) or 0,
                            created = tonumber(thought.createTime or 0) or 0,
                            review_id = scalar_str(thought.reviewId or pr.reviewId or row.reviewId),
                        }
                    end
                end
            end
        end
    end
    local groups = {}
    for _, range in ipairs(order) do
        -- 过滤空组:range 建在 content 检查前,若所有想法 content 都空会留空组。
        if #map[range] > 0 then groups[#groups + 1] = {range = range, texts = map[range]} end
    end
    return map, groups
end

function WebFetch.build_chapter(book_id, uid, marks_rows, reviews_data)
    local underlines, seen = {}, {}
    for _, row in ipairs(marks_rows or {}) do
        if row.range ~= "" and not seen[row.range] then
            seen[row.range] = true
            underlines[#underlines + 1] = {range = row.range, markText = row.markText}
        end
    end
    local review_map, review_groups = WebFetch.build_reviews(reviews_data)
    -- 想法有自己的锚点 range:没有对应热门划线时补一条划线行,
    -- 引文用想法的 abstract(已清理),这样虚线和弹窗链接才有落点。
    for _, group in ipairs(review_groups) do
        if not seen[group.range] then
            seen[group.range] = true
            underlines[#underlines + 1] = {
                range = group.range,
                markText = clean_quote(group.texts[1] and group.texts[1].abstract or ""),
            }
        end
    end
    local entry_count = 0
    for _, group in ipairs(review_groups) do entry_count = entry_count + #group.texts end
    return {
        book_id = tostring(book_id), chapter_uid = tostring(uid),
        underlines = underlines, review_map = review_map, review_groups = review_groups,
        underline_count = #underlines, thought_count = #review_groups,
        thought_entry_count = entry_count,
        errors = {}, underline_request_ok = true,
    }
end

function WebFetch:new(api)
    return setmetatable({api = api}, self)
end

function WebFetch:fetch_chapter(book_id, uid, progress)
    progress = progress or function() end
    local chapter_uid = tostring(uid)
    -- /book/underlines:该章所有划线(不限热度),比 bestbookmarks(整本热门 top)覆盖全。
    local ok, data = pcall(function() return self.api:underlines(book_id, chapter_uid) end)
    if not ok then
        logger.warn("[撷思][WebFetch] underlines failed",
            "book=", tostring(book_id), "chapter=", chapter_uid, "error=", tostring(data))
        return {
            book_id = tostring(book_id), chapter_uid = chapter_uid,
            underlines = {}, review_map = {}, review_groups = {},
            underline_count = 0, thought_count = 0, thought_entry_count = 0,
            errors = {tostring(data)}, underline_request_ok = false,
        }
    end
    progress("underlines", 1, 1, "")
    local marks_rows = extract_underlines(data)
    -- 提取该章划线的 range(去重保序),按 range 拉全部想法。
    local ranges, seen = {}, {}
    for _, row in ipairs(marks_rows) do
        if not seen[row.range] then seen[row.range] = true; ranges[#ranges + 1] = row.range end
    end
    -- /book/readreviews 按 range 返回该段【全部】想法(每 range 最多 count=30),
    -- 远比 /web/review/list 的"章级热门前1-2条"完整。这是 fork 时换端点丢掉
    -- 的能力,现恢复(miuread/weread 原版均用此端点)。
    local all_reviews, errors = {}, {}
    if #ranges > 0 and self.api.readreviews then
        local batches = self.api:review_batches(ranges, 5)
        for index, batch in ipairs(batches) do
            progress("thoughts", index, #batches, "")
            local ok, resp = pcall(function() return self.api:readreviews(book_id, chapter_uid, batch) end)
            if ok and type(resp) == "table" and type(resp.reviews) == "table" then
                for _, r in ipairs(resp.reviews) do all_reviews[#all_reviews + 1] = r end
            elseif ok then
                -- 返回结构异常:降级逐 range 补(防一批异常拖垮整章)。
                logger.warn("[撷思][WebFetch] readreviews 结构异常,逐 range 补",
                    "book=", tostring(book_id), "chapter=", chapter_uid, "batch=", index)
                for _, item in ipairs(batch) do
                    local s_ok, s_resp = pcall(function() return self.api:readreviews(book_id, chapter_uid, {item}) end)
                    if s_ok and type(s_resp) == "table" and type(s_resp.reviews) == "table" then
                        for _, r in ipairs(s_resp.reviews) do all_reviews[#all_reviews + 1] = r end
                    end
                end
            else
                errors[#errors + 1] = tostring(resp)
                logger.warn("[撷思][WebFetch] readreviews 批次失败",
                    "book=", tostring(book_id), "chapter=", chapter_uid,
                    "batch=", index, "/", tostring(#batches), "error=", tostring(resp))
            end
        end
    end
    progress("thoughts", 1, 1, "")
    local result = WebFetch.build_chapter(book_id, chapter_uid, marks_rows, {reviews = all_reviews})
    result.errors = errors
    return result
end

return WebFetch
