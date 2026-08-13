local BookReviews = {}

local function trim(text)
    return tostring(text or ""):match("^%s*(.-)%s*$")
end

local function utf8_char(codepoint)
    if codepoint < 0x80 then
        return string.char(codepoint)
    elseif codepoint < 0x800 then
        return string.char(
            0xC0 + math.floor(codepoint / 0x40),
            0x80 + codepoint % 0x40
        )
    elseif codepoint < 0x10000 then
        return string.char(
            0xE0 + math.floor(codepoint / 0x1000),
            0x80 + math.floor(codepoint / 0x40) % 0x40,
            0x80 + codepoint % 0x40
        )
    elseif codepoint <= 0x10FFFF then
        return string.char(
            0xF0 + math.floor(codepoint / 0x40000),
            0x80 + math.floor(codepoint / 0x1000) % 0x40,
            0x80 + math.floor(codepoint / 0x40) % 0x40,
            0x80 + codepoint % 0x40
        )
    end
    return ""
end

local function decode_entities(text)
    local named = {
        amp = "&",
        apos = "'",
        gt = ">",
        lt = "<",
        nbsp = " ",
        quot = '"',
    }
    text = text:gsub("&#[xX]([%da-fA-F]+);", function(value)
        return utf8_char(tonumber(value, 16) or 0)
    end)
    text = text:gsub("&#(%d+);", function(value)
        return utf8_char(tonumber(value, 10) or 0)
    end)
    return text:gsub("&([%a]+);", function(name)
        return named[name:lower()] or "&" .. name .. ";"
    end)
end

function BookReviews.plain_text(value)
    local text = tostring(value or "")
    text = text:gsub("<[bB][rR]%s*/?%s*>", "\n")
    text = text:gsub("</[pP]%s*>", "\n\n")
    text = text:gsub("</[dD][iI][vV]%s*>", "\n")
    text = text:gsub("<[^>]->", "")
    text = decode_entities(text)
    text = text:gsub("\r\n?", "\n")
    text = text:gsub("[ \t]+\n", "\n")
    text = text:gsub("\n[ \t]+", "\n")
    text = text:gsub("[ \t][ \t]+", " ")
    text = text:gsub("\n\n\n+", "\n\n")
    return trim(text)
end

local function unwrap_review(entry)
    local review = type(entry) == "table" and entry or {}
    for _i = 1, 4 do
        if type(review.review) ~= "table" then
            break
        end
        review = review.review
    end
    return review
end

local function author_name(author)
    if type(author) == "table" then
        return trim(author.nick or author.name or author.userName or author.username)
    end
    return trim(author)
end

function BookReviews.normalize_item(entry)
    local review = unwrap_review(entry)
    local content = BookReviews.plain_text(review.content)
    if content == "" then
        content = BookReviews.plain_text(review.htmlContent)
    end
    local rating = tonumber(review.star) or 0
    if rating > 10 then
        rating = rating / 10
    end
    return {
        review_id = review.reviewId,
        author = author_name(review.author),
        content = content,
        rating = rating,
        create_time = tonumber(review.createTime) or 0,
        is_finish = review.isFinish == true or tonumber(review.isFinish) == 1,
        idx = tonumber(type(entry) == "table" and entry.idx) or 0,
    }
end

function BookReviews.normalize_list(data)
    data = type(data) == "table" and data or {}
    local items = {}
    for _i, entry in ipairs(data.reviews or {}) do
        items[#items + 1] = BookReviews.normalize_item(entry)
    end
    return {
        items = items,
        total_count = tonumber(data.reviewsCnt) or #items,
        recent_count = tonumber(data.recentTotalCnt) or 0,
        has_more = data.reviewsHasMore == true or tonumber(data.reviewsHasMore) == 1,
        synckey = tonumber(data.synckey) or 0,
    }
end

function BookReviews.format_date(value)
    if type(value) == "string" then
        value = trim(value)
        local year, month, day = value:match("(%d%d%d%d)[-/%.](%d%d?)[-/%.](%d%d?)")
        if year then
            return string.format("%s-%02d-%02d", year, tonumber(month), tonumber(day))
        end
        if not tonumber(value) then
            return value
        end
    end
    local timestamp = tonumber(value)
    if not timestamp or timestamp <= 0 then
        return ""
    end
    if timestamp > 100000000000 then
        timestamp = math.floor(timestamp / 1000)
    end
    return os.date("%Y-%m-%d", timestamp)
end

function BookReviews.format_rating(value)
    local rating = tonumber(value) or 0
    if rating <= 0 then
        return ""
    end
    return string.format("%.1f", rating)
end

function BookReviews.preview(text, max_chars)
    text = BookReviews.plain_text(text):gsub("\n+", " ")
    max_chars = tonumber(max_chars) or 60
    local bytes, chars = 0, 0
    while bytes < #text and chars < max_chars do
        local byte = text:byte(bytes + 1)
        local width = byte < 0x80 and 1
            or byte < 0xE0 and 2
            or byte < 0xF0 and 3
            or 4
        bytes = bytes + width
        chars = chars + 1
    end
    if bytes < #text then
        return text:sub(1, bytes) .. "…"
    end
    return text
end

return BookReviews
