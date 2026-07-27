-- 数据源:微信读书 web 端(Cookie 鉴权,网关 Bearer key 已不可靠)。
-- 热门划线整本一次拉回按章分组;章节想法按章拉取;输出与原
-- Annotations:fetch_chapter 完全同形,sync/epub_inject 无感消费:
-- {underlines, review_map, review_groups, underline_count, thought_count,
--  thought_entry_count, errors, underline_request_ok}
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

function WebFetch.group_marks(data)
    local by_uid = {}
    local box = type(data) == "table" and (type(data.bestBookMarks) == "table" and data.bestBookMarks or data) or {}
    for _, item in ipairs(box.items or {}) do
        if type(item) == "table" then
            local uid = scalar_str(item.chapterUid)
            local range = scalar_str(item.range)
            if uid ~= "" and range ~= "" then
                by_uid[uid] = by_uid[uid] or {}
                local rows = by_uid[uid]
                rows[#rows + 1] = {range = range, markText = scalar_str(item.markText)}
            end
        end
    end
    return by_uid
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
    return setmetatable({api = api, marks = {}}, self)
end

function WebFetch:_marks_for(book_id)
    local key = tostring(book_id)
    if self.marks[key] == nil then
        local ok, data = pcall(function() return self.api:web_bestbookmarks(key) end)
        if not ok then return nil, tostring(data) end
        self.marks[key] = WebFetch.group_marks(data)
    end
    return self.marks[key]
end

function WebFetch:fetch_chapter(book_id, uid, progress)
    progress = progress or function() end
    local chapter_uid = tostring(uid)
    local by_uid, marks_err = self:_marks_for(book_id)
    if not by_uid then
        logger.warn("[撷思][WebFetch] bestbookmarks failed",
            "book=", tostring(book_id), "error=", tostring(marks_err))
        return {
            book_id = tostring(book_id), chapter_uid = chapter_uid,
            underlines = {}, review_map = {}, review_groups = {},
            underline_count = 0, thought_count = 0, thought_entry_count = 0,
            errors = {marks_err}, underline_request_ok = false,
        }
    end
    progress("underlines", 1, 1, "")
    local marks_rows = by_uid[chapter_uid]
    -- 提取该章划线的 range(去重保序),按 range 拉全部想法。
    local ranges, seen = {}, {}
    for _, row in ipairs(marks_rows or {}) do
        local r = tostring(row.range or "")
        if r ~= "" and not seen[r] then seen[r] = true; ranges[#ranges + 1] = r end
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
