local logger = require("logger")
local Thoughts = require("pickthought.thoughts")
local ok_socket, socket = pcall(require, "socket")

local Annotations = {}
Annotations.__index = Annotations

local AnnotationStyle = require("pickthought.annotation_style")
local CSS = AnnotationStyle.CSS

local function pause(seconds)
    if ok_socket and socket and type(socket.sleep) == "function" then socket.sleep(seconds) end
end

local function is_network_failure(value)
    local text=tostring(value or ""):lower()
    return text:find("network request failed",1,true)~=nil
        or text:find("timeout",1,true)~=nil
        or text:find("connection refused",1,true)~=nil
        or text:find("network is unreachable",1,true)~=nil
end

local function call_with_retry(label, fn)
    local last
    for attempt = 1, 3 do
        local ok, value = pcall(fn)
        if ok and type(value) == "table" then return true, value, false end
        last = ok and (label .. " returned invalid data") or tostring(value)
        local network_down=is_network_failure(last)
        local max_attempts=network_down and 2 or 3
        if attempt < max_attempts then
            logger.warn("[撷思][Annotations] retry", "label=", label, "attempt=", tostring(attempt), "error=", tostring(last))
            pause(attempt == 1 and 0.6 or 1.4)
        else
            return false,last,network_down
        end
    end
    return false,last,is_network_failure(last)
end

local function str(v) return v == nil and "" or tostring(v) end
local function scalar_str(v)
    local kind=type(v)
    if kind=="string" or kind=="number" then return tostring(v) end
    return ""
end

local function range_key(v)
    if type(v) ~= "table" then return "" end
    return scalar_str(rawget(v,"range") or rawget(v,"markRange") or rawget(v,"bookmarkRange"))
end

local function array_from(data, names)
    if type(data) ~= "table" then return {} end
    for _, name in ipairs(names) do if type(data[name]) == "table" then return data[name] end end
    if #data > 0 then return data end
    return {}
end

local function table_entries(data)
    local rows, invalid = {}, 0
    if type(data) ~= "table" then return rows, invalid end
    for _, value in ipairs(data) do
        if type(value) == "table" then
            rows[#rows + 1] = value
        else
            invalid = invalid + 1
        end
    end
    return rows, invalid
end

local function parse_range(value)
    local a, b = str(value):match("^(%d+)%-(%d+)$")
    a, b = tonumber(a), tonumber(b)
    if not a or not b or b <= a then return nil end
    return a, b
end

local function review_texts(group)
    local rows, seen, invalid = {}, {}, 0
    local pages, skipped = table_entries(array_from(group, {"pageReviews", "reviews", "updated"}))
    invalid = invalid + skipped
    for _, page in ipairs(pages) do
        -- Review payloads occasionally contain placeholders, functions or tables
        -- with surprising metatables. Keep each entry isolated so one malformed
        -- review can never abort the whole book download.
        local ok, item = pcall(function()
            if type(page) ~= "table" then return nil end
            local nested = rawget(page, "review")
            local r = type(nested) == "table" and nested or page
            if type(r) ~= "table" then return nil end
            local content = scalar_str(rawget(r, "content") or rawget(r, "review") or rawget(r, "text"))
            if content == "" then return nil end
            local author = type(rawget(r, "author")) == "table" and rawget(r, "author") or {}
            local author_name = scalar_str(rawget(author, "nick") or rawget(author, "name") or rawget(r, "authorName"))
            local key = scalar_str(rawget(r, "reviewId") or rawget(r, "id"))
            if key == "" then key = content .. "\0" .. author_name end
            return {
                key = key,
                content = content,
                abstract = scalar_str(rawget(r, "abstract") or rawget(r, "contextAbstract") or rawget(r, "markText")),
                created = tonumber(rawget(r, "createTime") or rawget(r, "createdAt") or 0) or 0,
                author = author_name,
                likes = tonumber(rawget(page, "likesCount") or rawget(r, "likesCount") or 0) or 0,
                review_id = scalar_str(rawget(r, "reviewId") or rawget(r, "id")),
            }
        end)
        if ok and item and not seen[item.key] then
            seen[item.key] = true
            item.key = nil
            rows[#rows + 1] = item
        elseif not ok or item == nil then
            invalid = invalid + 1
        end
    end
    return rows, invalid
end

local function normalize_reviews(data)
    local map, groups, group_count, entry_count, invalid_count = {}, {}, 0, 0, 0
    local source, skipped = table_entries(array_from(data, {"reviews", "updated"}))
    invalid_count = invalid_count + skipped
    for _, group in ipairs(source) do
        local key = range_key(group)
        if key ~= "" then
            local texts, invalid = review_texts(group)
            invalid_count = invalid_count + invalid
            if #texts > 0 then
                if not map[key] then group_count = group_count + 1; map[key] = {} end
                for _, item in ipairs(texts) do map[key][#map[key] + 1] = item end
                entry_count = entry_count + #texts
            end
        end
    end
    for key, texts in pairs(map) do groups[#groups + 1] = {range = key, texts = texts} end
    table.sort(groups, function(a, b) return tostring(a.range) < tostring(b.range) end)
    return map, groups, group_count, entry_count, invalid_count
end

function Annotations:new(api) return setmetatable({api = api}, self) end

function Annotations:fetch_chapter(book_id, uid, progress)
    local result = {book_id=str(book_id),chapter_uid=str(uid),underlines={},review_map={},review_groups={},underline_count=0,thought_count=0,thought_entry_count=0,errors={},underline_request_ok=false}
    progress = progress or function() end
    local ok, data = call_with_retry("underlines", function() return self.api:underlines(book_id, uid) end)
    if not ok then
        local err = str(data)
        result.errors[#result.errors + 1] = err
        logger.warn("[撷思][Annotations] underlines failed", "book=", result.book_id, "chapter=", result.chapter_uid, "error=", err)
        return result
    end
    result.underline_request_ok = true
    local invalid_underlines
    result.underlines, invalid_underlines = table_entries(array_from(data, {"underlines", "updated", "bookmarks"}))
    result.underline_count = #result.underlines
    if invalid_underlines > 0 then
        logger.warn("[撷思][Annotations] ignored invalid underline entries",
            "book=", result.book_id, "chapter=", result.chapter_uid,
            "count=", tostring(invalid_underlines))
    end
    local ranges, seen = {}, {}
    for _, row in ipairs(result.underlines) do
        local key = range_key(row)
        if key ~= "" and not seen[key] then seen[key] = true; ranges[#ranges + 1] = key end
    end
    progress("underlines", result.underline_count, result.underline_count, "")
    if #ranges == 0 then return result end
    local groups = {}
    local batches = self.api:review_batches(ranges, 5)
    for index, batch in ipairs(batches) do
        progress("thoughts", index, #batches, "")
        local good, response, network_down = call_with_retry("thoughts batch " .. tostring(index), function()
            return self.api:readreviews(book_id, uid, batch)
        end)
        if good then
            local rows, invalid = table_entries(array_from(response, {"reviews", "updated"}))
            for _, item in ipairs(rows) do groups[#groups + 1] = item end
            if invalid > 0 then
                logger.warn("[撷思][Annotations] ignored invalid review groups",
                    "book=", result.book_id, "chapter=", result.chapter_uid,
                    "batch=", tostring(index), "count=", tostring(invalid))
            end
        else
            if network_down then
                local err="batch "..tostring(index)..": "..str(response)
                result.errors[#result.errors+1]=err
                logger.warn("[撷思][Annotations] network unavailable; individual thought fallback skipped",
                    "book=",result.book_id,"chapter=",result.chapter_uid,
                    "batch=",tostring(index),"/",tostring(#batches),"error=",str(response))
                break
            end
            -- A grouped request can fail even when each individual range is valid.
            -- Fall back to one range at a time only for data-specific failures;
            -- a network outage must not explode into dozens of extra requests.
            local batch_errors = {}
            logger.warn("[撷思][Annotations] thoughts batch failed; trying individual ranges",
                "book=", result.book_id, "chapter=", result.chapter_uid,
                "batch=", index, "/", #batches, "error=", str(response))
            for item_index, item in ipairs(batch) do
                progress("thoughts", index, #batches, "逐条补全 " .. tostring(item_index) .. "/" .. tostring(#batch))
                local single_ok, single_response = call_with_retry(
                    "thought range " .. tostring(index) .. "." .. tostring(item_index),
                    function() return self.api:readreviews(book_id, uid, {item}) end)
                if single_ok then
                    local rows, invalid = table_entries(array_from(single_response, {"reviews", "updated"}))
                    for _, row in ipairs(rows) do groups[#groups + 1] = row end
                    if invalid > 0 then
                        logger.warn("[撷思][Annotations] ignored invalid review groups",
                            "book=", result.book_id, "chapter=", result.chapter_uid,
                            "batch=", tostring(index), "item=", tostring(item_index),
                            "count=", tostring(invalid))
                    end
                else
                    batch_errors[#batch_errors + 1] = str(item.range) .. ": " .. str(single_response)
                end
            end
            if #batch_errors > 0 then
                local err = table.concat(batch_errors, "; ")
                result.errors[#result.errors + 1] = "batch " .. index .. ": " .. err
                logger.warn("[撷思][Annotations] thoughts individual fallback incomplete",
                    "book=", result.book_id, "chapter=", result.chapter_uid,
                    "batch=", index, "/", #batches, "error=", err)
            end
        end
    end
    local invalid_reviews
    result.review_map, result.review_groups, result.thought_count,
        result.thought_entry_count, invalid_reviews = normalize_reviews({reviews=groups})
    if invalid_reviews > 0 then
        logger.warn("[撷思][Annotations] ignored invalid review entries",
            "book=", result.book_id, "chapter=", result.chapter_uid,
            "count=", tostring(invalid_reviews))
    end
    logger.info("[撷思][Annotations] chapter fetched", "book=", result.book_id, "chapter=", result.chapter_uid,
        "underlines=", result.underline_count, "thought_groups=", result.thought_count,
        "thought_entries=", result.thought_entry_count, "errors=", #result.errors)
    return result
end

local function utf8_len_at(text, i)
    local c = text:byte(i)
    if not c or c < 0x80 then return 1 end
    if c < 0xE0 then return 2 end
    if c < 0xF0 then return 3 end
    return 4
end

local NAMED_ENTITIES = {
    amp = "&", lt = "<", gt = ">", quot = '"', apos = "'",
    nbsp = " ", ensp = " ", emsp = " ", thinsp = " ",
    hellip = "…", mdash = "—", ndash = "–",
    lsquo = "‘", rsquo = "’", ldquo = "“", rdquo = "”",
    zwnj = "", zwj = "",
}

local function utf8_encode(codepoint)
    codepoint = tonumber(codepoint)
    if not codepoint or codepoint < 0 or codepoint > 0x10FFFF
        or (codepoint >= 0xD800 and codepoint <= 0xDFFF) then
        return nil
    end
    if codepoint < 0x80 then
        return string.char(codepoint)
    elseif codepoint < 0x800 then
        return string.char(0xC0 + math.floor(codepoint / 0x40), 0x80 + (codepoint % 0x40))
    elseif codepoint < 0x10000 then
        return string.char(
            0xE0 + math.floor(codepoint / 0x1000),
            0x80 + (math.floor(codepoint / 0x40) % 0x40),
            0x80 + (codepoint % 0x40)
        )
    end
    return string.char(
        0xF0 + math.floor(codepoint / 0x40000),
        0x80 + (math.floor(codepoint / 0x1000) % 0x40),
        0x80 + (math.floor(codepoint / 0x40) % 0x40),
        0x80 + (codepoint % 0x40)
    )
end

local function decode_html_unit(unit)
    unit = tostring(unit or "")
    local decimal = unit:match("^&#(%d+);$")
    if decimal then return utf8_encode(tonumber(decimal, 10)) or unit end
    local hexadecimal = unit:match("^&#[xX]([%x]+);$")
    if hexadecimal then return utf8_encode(tonumber(hexadecimal, 16)) or unit end
    local named = unit:match("^&([%w]+);$")
    if named and NAMED_ENTITIES[named] ~= nil then return NAMED_ENTITIES[named] end
    return unit
end

local function split_units(raw)
    local units, p = {}, 1
    while p <= #raw do
        local entity = raw:sub(p):match("^&[#%w]+;")
        if entity then
            units[#units + 1] = entity
            p = p + #entity
        else
            local n = utf8_len_at(raw, p)
            units[#units + 1] = raw:sub(p, p + n - 1)
            p = p + n
        end
    end
    return units
end

local function is_ignorable_text(value)
    if value == nil or value == "" then return true end
    if value:match("^%s+$") then return true end
    return value == "\194\160"       -- non-breaking space
        or value == "\227\128\128" -- ideographic space
        or value == "\226\128\139" -- zero-width space
        or value == "\226\128\140" -- zero-width non-joiner
        or value == "\226\128\141" -- zero-width joiner
        or value == "\239\187\191" -- UTF-8 BOM
end

local SKIP_TEXT_TAGS = {
    script = true, style = true, noscript = true, template = true, svg = true,
}

local function tag_info(raw)
    local slash, name = tostring(raw or ""):match("^<%s*(/?)%s*([%w:_%-]+)")
    if not name then return false, "", false end
    return slash == "/", name:lower(), tostring(raw):match("/%s*>$") ~= nil
end

local function tokenize(html)
    local tokens, visible = {}, 0
    local i, skip_depth, anchor_depth = 1, 0, 0
    while i <= #html do
        if html:sub(i, i) == "<" then
            local j = html:find(">", i + 1, true)
            if not j then
                local raw = html:sub(i)
                tokens[#tokens + 1] = {
                    kind="text", raw=raw, units=split_units(raw), start=visible,
                    skip=skip_depth > 0, inside_anchor=anchor_depth > 0,
                }
                if skip_depth == 0 then visible = visible + #tokens[#tokens].units end
                break
            end
            local raw = html:sub(i, j)
            local closing, name, self_closing = tag_info(raw)
            if closing and name == "a" then anchor_depth = math.max(0, anchor_depth - 1) end
            tokens[#tokens + 1] = {kind="tag", raw=raw}
            if closing and SKIP_TEXT_TAGS[name] then
                skip_depth = math.max(0, skip_depth - 1)
            elseif not closing and not self_closing and SKIP_TEXT_TAGS[name] then
                skip_depth = skip_depth + 1
            end
            if not closing and not self_closing and name == "a" then anchor_depth = anchor_depth + 1 end
            i = j + 1
        else
            local j = html:find("<", i, true) or (#html + 1)
            local raw = html:sub(i, j - 1)
            local units = split_units(raw)
            local skipped = skip_depth > 0
            tokens[#tokens + 1] = {
                kind="text", raw=raw, units=units, start=visible,
                stop=skipped and visible or (visible + #units), skip=skipped,
                inside_anchor=anchor_depth > 0,
            }
            if not skipped then visible = visible + #units end
            i = j
        end
    end
    return tokens, visible
end

local function utf16_width(value)
    local first = tostring(value or ""):byte(1) or 0
    return first >= 0xF0 and 2 or 1
end

local function build_text_index(tokens)
    local pieces, starts, ends, ordinals = {}, {}, {}, {}
    local compact_bounds, utf16_bounds = {}, {}
    local byte_pos, compact_count, utf16_count = 1, 0, 0

    for _, token in ipairs(tokens or {}) do
        if token.kind == "text" and not token.skip then
            for index, unit in ipairs(token.units or {}) do
                local raw_pos = token.start + index - 1
                local decoded = decode_html_unit(unit)

                if utf16_bounds[utf16_count] == nil then utf16_bounds[utf16_count] = raw_pos end
                local width = utf16_width(decoded)
                if width > 1 then
                    for extra = 1, width - 1 do utf16_bounds[utf16_count + extra] = raw_pos end
                end
                utf16_count = utf16_count + width
                utf16_bounds[utf16_count] = raw_pos + 1

                if not is_ignorable_text(decoded) then
                    compact_bounds[compact_count] = compact_bounds[compact_count] or raw_pos
                    pieces[#pieces + 1] = decoded
                    starts[byte_pos] = raw_pos
                    ordinals[byte_pos] = compact_count
                    local end_byte = byte_pos + #decoded - 1
                    ends[end_byte] = raw_pos + 1
                    byte_pos = end_byte + 1
                    compact_count = compact_count + 1
                    compact_bounds[compact_count] = raw_pos + 1
                end
            end
        end
    end

    return {
        text = table.concat(pieces), starts = starts, ends = ends, ordinals = ordinals,
        compact_bounds = compact_bounds, compact_count = compact_count,
        utf16_bounds = utf16_bounds, utf16_count = utf16_count,
    }
end

local function normalize_text(value)
    local raw = tostring(value or ""):gsub("<[^>]+>", "")
    local out, count = {}, 0
    for _, unit in ipairs(split_units(raw)) do
        local decoded = decode_html_unit(unit)
        if not is_ignorable_text(decoded) then
            out[#out + 1] = decoded
            count = count + 1
        end
    end
    return table.concat(out), count
end

local function quote_candidates(row, data)
    local values, seen = {}, {}
    local function add(value)
        local normalized, count = normalize_text(value)
        if count >= 2 and count <= 800 and normalized ~= "" and not seen[normalized] then
            seen[normalized] = true
            values[#values + 1] = normalized
        end
    end

    row = type(row) == "table" and row or {}
    for _, key in ipairs({"markText", "bookmarkText", "rangeText", "abstract", "text", "content"}) do
        add(row[key])
    end
    local reviews = data and data.review_map and data.review_map[range_key(row)] or nil
    for _, review in ipairs(reviews or {}) do add(review.abstract) end
    return values
end

local function locate_quote(index, needle, expected)
    if not index or tostring(index.text or "") == "" or tostring(needle or "") == "" then return nil end
    local best_a, best_b, best_score
    local from = 1
    while true do
        local first, last = index.text:find(needle, from, true)
        if not first then break end
        local a, b = index.starts[first], index.ends[last]
        if a ~= nil and b ~= nil and b > a then
            local compact_a = index.ordinals[first] or a
            local score = math.min(math.abs(a - expected), math.abs(compact_a - expected))
            if best_score == nil or score < best_score then
                best_a, best_b, best_score = a, b, score
            end
        end
        from = first + 1
    end
    return best_a, best_b
end

local function numeric_interval(a, b, visible_count, index)
    -- WeRead ranges are generated by JavaScript and may use UTF-16 offsets.
    -- Mapping through decoded text preserves positions after emoji/non-BMP text.
    local mapped_a = index and index.utf16_bounds and index.utf16_bounds[a]
    local mapped_b = index and index.utf16_bounds and index.utf16_bounds[b]
    if mapped_a ~= nil and mapped_b ~= nil and mapped_b > mapped_a then
        return mapped_a, mapped_b
    end
    a, b = math.max(0, a), math.min(visible_count, b)
    if b > a then return a, b end
end

local function intervals(data, visible_count, index)
    local out = {}
    -- dropped 是总数;overlapped(与更前划线重叠被去重)与 unlocated
    -- (本地正文找不到落点)分开计数,报告端才能把语义讲清楚。
    local stats = {quote_aligned=0, numeric=0, dropped=0, overlapped=0, unlocated=0}
    for _, row in ipairs(data.underlines or {}) do
        local raw_a, raw_b = parse_range(range_key(row))
        if raw_a then
            local a, b
            for _, quote in ipairs(quote_candidates(row, data)) do
                a, b = locate_quote(index, quote, raw_a)
                if a then break end
            end
            if a then
                stats.quote_aligned = stats.quote_aligned + 1
            elseif not data.no_numeric_fallback then
                -- 叠加注入合并文件时(epub_inject 置 no_numeric_fallback),
                -- 章节内数字偏移相对整个文件已失真,引文不中宁可丢弃。
                a, b = numeric_interval(raw_a, raw_b, visible_count, index)
                stats.numeric = stats.numeric + 1
            end
            if a and b and b > a then
                out[#out + 1] = {
                    a=a, b=b, key=range_key(row),
                    thought=#(data.review_map[range_key(row)] or {}) > 0,
                }
            else
                stats.dropped = stats.dropped + 1
                stats.unlocated = stats.unlocated + 1
            end
        else
            stats.dropped = stats.dropped + 1
            stats.unlocated = stats.unlocated + 1
        end
    end
    table.sort(out, function(x,y) if x.a==y.a then return x.b<y.b end return x.a<y.a end)
    local clean, cursor = {}, -1
    local merged = {}
    -- 全部被重叠合并的划线键(不止带想法的):上层跨文件统计「唯一划线是否
    -- 有着落」需要它,重叠合并算有着落,不算未注入。
    local overlapped_keys = {}
    for _, it in ipairs(out) do
        if it.a >= cursor then
            clean[#clean + 1] = it; cursor = it.b
        else
            -- 与前一条划线交叠而被合并:热门划线大量互相重叠,这是常态而非失败。
            -- 带想法的被合并划线不能丢内容:存活锚点升级为想法链接,
            -- 并记录 from→into 映射,由上层把想法并进存活锚点的组。
            stats.dropped = stats.dropped + 1
            stats.overlapped = stats.overlapped + 1
            overlapped_keys[#overlapped_keys + 1] = it.key
            local survivor = clean[#clean]
            if it.thought and survivor then
                survivor.thought = true
                merged[#merged + 1] = {from = it.key, into = survivor.key}
            end
        end
    end
    stats.merged = merged
    stats.overlapped_keys = overlapped_keys
    return clean, stats
end

local function render_text_token(token, marks, data)
    if token.skip or not token.units or #token.units == 0 then return token.raw end
    local out, pos = {}, token.start
    local active, thought_link_open = nil, false
    local function close_active()
        if not active then return end
        out[#out + 1] = "</span>"
        if thought_link_open then out[#out + 1] = "</a>" end
        active = nil
        thought_link_open = false
    end
    for _, unit in ipairs(token.units) do
        local mark
        for _, it in ipairs(marks) do if pos >= it.a and pos < it.b then mark = it; break end end
        if mark ~= active then
            close_active()
            active = mark
            if active then
                -- HTML does not allow links inside links. When an underline overlaps
                -- an existing footnote/noteref link, preserve the underline style but
                -- leave the original link as the only clickable target.
                if active.thought and not token.inside_anchor then
                    local href = Thoughts.href(data.book_id, data.chapter_uid, active.key)
                    out[#out + 1] = '<a class="pickthought-link" href="' .. href .. '">'
                    thought_link_open = true
                end
                local mark_class = Thoughts.mark_class(active.key)
                local display_class = active.thought and "pickthought-mark" or "pickthought-inline-mark"
                out[#out + 1] = '<span class="' .. display_class .. ' ' .. mark_class .. '" data-pickthought-range="' .. active.key .. '">'
            end
        end
        out[#out + 1] = unit
        pos = pos + 1
        if active and pos >= active.b then close_active() end
    end
    close_active()
    return table.concat(out)
end

local function inject(html, data)
    local tokens, visible_count = tokenize(html)
    local index = build_text_index(tokens)
    local marks, stats = intervals(data, visible_count, index)
    if #marks == 0 then return html, stats end
    local out = {}
    for _, token in ipairs(tokens) do
        if token.kind == "text" then out[#out + 1] = render_text_token(token, marks, data)
        else out[#out + 1] = token.raw end
    end
    return table.concat(out), stats
end

function Annotations:apply(html, data)
    if not data or data.underline_count == 0 then return html, "", {underlines=0,thoughts=0} end
    local rendered, alignment = inject(html, data)
    logger.info("[撷思][Annotations] alignment",
        "book=", tostring(data.book_id or ""), "chapter=", tostring(data.chapter_uid or ""),
        "quote=", tostring(alignment and alignment.quote_aligned or 0),
        "numeric=", tostring(alignment and alignment.numeric or 0),
        "dropped=", tostring(alignment and alignment.dropped or 0))
    return rendered, CSS, {
        underlines=data.underline_count, thoughts=data.thought_count,
        thought_entries=data.thought_entry_count or 0, errors=#(data.errors or {}),
        quote_aligned=alignment and alignment.quote_aligned or 0,
        numeric=alignment and alignment.numeric or 0,
        dropped=alignment and alignment.dropped or 0,
        overlapped=alignment and alignment.overlapped or 0,
        unlocated=alignment and alignment.unlocated or 0,
        merged=alignment and alignment.merged or {},
        overlapped_keys=alignment and alignment.overlapped_keys or {},
    }
end

return Annotations
