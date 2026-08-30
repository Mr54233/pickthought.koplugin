local logger = require("logger")
local Thoughts = require("pickthought.thoughts")

local Annotations = {}
Annotations.__index = Annotations

local AnnotationStyle = require("pickthought.annotation_style")
local CSS = AnnotationStyle.CSS

local function str(v) return v == nil and "" or tostring(v) end

local function range_key(v)
    if type(v) ~= "table" then return "" end
    return str(rawget(v,"range") or rawget(v,"markRange") or rawget(v,"bookmarkRange"))
end

local function has_thought(data, key)
    if type(data) ~= "table" then return false end
    if type(data.thought_ranges) == "table" and data.thought_ranges[key] then return true end
    return type(data.review_map) == "table"
        and type(data.review_map[key]) == "table" and #data.review_map[key] > 0
end

local function parse_range(value)
    local a, b = str(value):match("^(%d+)%-(%d+)$")
    a, b = tonumber(a), tonumber(b)
    if not a or not b or b <= a then return nil end
    return a, b
end

function Annotations:new() return setmetatable({}, self) end

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
                    thought=has_thought(data, range_key(row)),
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
                -- 带 book_id:多书合并注入时,from→into 的想法并进需定位到正确的书。
                merged[#merged + 1] = {from = it.key, into = survivor.key, book_id = data.book_id}
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
        if thought_link_open then
            out[#out + 1] = "</a>"    -- 折叠:单 <a> 承载链接+标注,无内层 <span>
        else
            out[#out + 1] = "</span>" -- 仅 <span>(无想法 / 处于既有链接内)
        end
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
                -- leave the original link as the only clickable target(仍用独立 <span>)。
                if active.thought and not token.inside_anchor then
                    -- 折叠:把「链接 <a> + 标注 <span>」合并为单个 <a class="pickthought-link pickthought-mark">,
                    -- 减半样式元素数量;配合 annotation_style 使用共享 class 的默认样式,
                    -- 保留低内存设备的结构优化。
                    local href = Thoughts.href(data.book_id, data.chapter_uid, active.key)
                    out[#out + 1] = '<a class="pickthought-link pickthought-mark" data-pickthought-range="'
                        .. active.key .. '" href="' .. href .. '">'
                    thought_link_open = true
                else
                    local display_class = active.thought and "pickthought-mark" or "pickthought-inline-mark"
                    -- 注意: 不追加 Thoughts.mark_class 生成的唯一 class(pickthought-mark-<hex>)。
                    -- 该 class 仅被生成、从不被 CSS/代码读取,却会让 CRE 为每个标注各建一份
                    -- 无法合并的样式,在多书合集(数千标注)下撑爆样式数据存储池导致 KPW3 段错误。
                    -- 唯一标识已由 data-pickthought-range 与 href 承载,去掉它样式零变化、功能不受影响。
                    out[#out + 1] = '<span class="' .. display_class .. '" data-pickthought-range="' .. active.key .. '">'
                end
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
