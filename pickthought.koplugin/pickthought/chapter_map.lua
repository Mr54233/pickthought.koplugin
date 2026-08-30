-- 章节映射:用划线引文在本地 spine 文档里投票,把微信读书章节映射到 zip 内 href。
-- 引文和文档正文走同一套 normalize(剥标签、解实体、去全部空白),
-- 这样换行/排版/实体化差异不影响命中;引文全不中时用章节标题兜底(避开目录页)。
--
-- 正文文件通常包含一个或少数几个 h1-h6 章节标题。能识别到这些标题时,
-- 先建立本地章节边界,只在对应边界内做引文投票;没有可靠章节结构时才回退
-- 到整文件扫描。这样不会改变无结构 EPUB 的兼容性,也不会让同一文件内
-- 不同章节的重复引文互相投票。
local logger = require("logger")

local ChapterMap = {}

-- 匹配算法版本:任何影响匹配结果的改动(引文窗口、投票规则、目录页判定、
-- 归一化规则)都必须 +1。映射缓存把它写进指纹,算法一改缓存整体作废——
-- 否则旧算法缓存下来的「匹配失败」会永久生效,改进永远轮不到那些章节。
ChapterMap.ALGO_VERSION = 8

-- 标题钥匙:剥掉「第X章/节/回…」编号前缀。微信与本地书的章号体系
-- 经常不一致(实测:微信「第六章 姑娘请自重」= 本地「第二百八十四章
-- 姑娘请自重」),整标题匹配必死;章名本体才是稳定标识。
-- 剥完不足 6 字节(如「上」「下」)退回全标题。
local CHAPTER_ENDINGS = {"章", "节", "回", "卷", "部", "集", "篇"}
local CHAPTER_NUMBER_TOKENS = {
    "零", "〇", "一", "二", "三", "四", "五", "六", "七", "八", "九",
    "十", "百", "千", "万", "两",
}

local function is_chapter_number(value)
    local number = tostring(value or ""):gsub("%d", "")
    for _, token in ipairs(CHAPTER_NUMBER_TOKENS) do
        number = number:gsub(token, "")
    end
    return number == ""
end

local function strip_chapter_number(value)
    if value:sub(1, #"第") ~= "第" then return value end
    local rest = value:sub(#"第" + 1)
    local ending_pos, ending_len
    for _, ending in ipairs(CHAPTER_ENDINGS) do
        local pos = rest:find(ending, 1, true)
        if pos and (not ending_pos or pos < ending_pos) then
            ending_pos, ending_len = pos, #ending
        end
    end
    if not ending_pos or ending_pos <= 1
        or not is_chapter_number(rest:sub(1, ending_pos - 1)) then
        return value
    end
    return rest:sub(ending_pos + ending_len)
end

local function strip_update_suffix(value)
    local text = value
    local function strip_group(current, opening, closing)
        local last_open = nil
        local search_from = 1
        while true do
            local pos = current:find(opening, search_from, true)
            if not pos then break end
            last_open = pos
            search_from = pos + #opening
        end
        local close_at = #current - #closing + 1
        if last_open and close_at > last_open
            and current:sub(close_at, close_at + #closing - 1) == closing
            and current:sub(last_open + #opening, close_at - 1):find("更", 1, true) then
            return current:sub(1, last_open - 1)
        end
        return current
    end
    local previous
    repeat
        previous = text
        text = strip_group(text, "（", "）")
        text = strip_group(text, "(", ")")
    until text == previous
    return text
end

function ChapterMap.title_key(title)
    local t = strip_update_suffix(ChapterMap.normalize(title))
    local stripped = strip_chapter_number(t)
    if #stripped >= 6 then return stripped end
    return t
end

local ENTITIES = {
    amp = "&", lt = "<", gt = ">", quot = '"', apos = "'",
    nbsp = "", ensp = "", emsp = "", thinsp = "", hellip = "…",
    mdash = "—", ndash = "–", ldquo = "“", rdquo = "”", lsquo = "‘", rsquo = "’",
}

local function utf8_char(code)
    if not code or code < 0 or code > 0x10FFFF
        or (code >= 0xD800 and code <= 0xDFFF) then
        return ""
    end
    if code < 0x80 then return string.char(code) end
    if code < 0x800 then
        return string.char(0xC0 + math.floor(code / 0x40), 0x80 + code % 0x40)
    end
    if code < 0x10000 then
        return string.char(0xE0 + math.floor(code / 0x1000),
            0x80 + math.floor(code / 0x40) % 0x40, 0x80 + code % 0x40)
    end
    return string.char(0xF0 + math.floor(code / 0x40000),
        0x80 + math.floor(code / 0x1000) % 0x40,
        0x80 + math.floor(code / 0x40) % 0x40, 0x80 + code % 0x40)
end

-- 全角→半角(字母/数字/标点)。出版版标题/正文常用全角,不转就和半角对不上。
-- 移植自 miuread bed9f5a (fix: correct chapter title extraction)。
local function fold_fullwidth(value)
    value = value:gsub("\239\188([\129-\191])", function(c) return string.char(c:byte() - 96) end)
    value = value:gsub("\239\189([\128-\158])", function(c) return string.char(c:byte() - 32) end)
    return value
end

-- 不可见字符/排版空白。只清真正的空白和不可见字符(单码点精确清除)。
-- 不能用范围(如 U+2000-U+203F / U+3000-U+303F)——会误清弯引号、中文句号、
-- 破折号等内容标点,导致引文/正文 normalize 后丢内容,匹配全挂。
local BLANK_PATTERNS = {
    "\194\160",             -- U+00A0 nbsp
    "\194\173",             -- U+00AD soft hyphen
    "\227\128\128",         -- U+3000 全角空格(只空格,不清 CJK 标点)
    "\226\128\139",         -- U+200B 零宽空格
    "\226\128\140",         -- U+200C 零宽非连接符
    "\226\128\141",         -- U+200D 零宽连接符
    "\239\187\191",         -- U+FEFF BOM
}

function ChapterMap.normalize(value)
    local text = tostring(value or ""):gsub("<[^>]*>", " ")
    -- 数值实体解码成字面 UTF-8:实体化编码的中文正文(&#x8FD9; 之类)必须还原,
    -- 否则整章 normalize 成空串,引文永不命中。
    text = text:gsub("&#[xX](%x+);", function(hex) return utf8_char(tonumber(hex, 16)) end)
    text = text:gsub("&#(%d+);", function(dec) return utf8_char(tonumber(dec, 10)) end)
    text = text:gsub("&(%a+);", function(name) return ENTITIES[name] or "" end)
    -- 全角→半角,再去不可见字符/排版空白和 ASCII 空白。
    text = fold_fullwidth(text)
    for _, pattern in ipairs(BLANK_PATTERNS) do text = text:gsub(pattern, "") end
    text = text:gsub("%s+", "")
    return text
end

local function scalar_str(v)
    local kind = type(v)
    if kind == "string" or kind == "number" then return tostring(v) end
    return ""
end

-- 参与投票的引文至少 12 字节(约 4 个汉字):太短的句子在多个文件里都会出现,只会投错票。
local MIN_QUOTE_BYTES = 12
-- 引文只取前缀窗口:微信对长引文的 abstract 会做中段省略/跨段拼接,
-- 整条拿去匹配必失败(真机实证 573-1314 字节的引文全部 0 命中,
-- 截前 90 字节后恢复命中);省略点几乎不出现在开头,前缀最保真。
local MAX_QUOTE_BYTES = 90

local function utf8_prefix(text, max_bytes)
    if #text <= max_bytes then return text end
    local cut = max_bytes
    -- 退到完整 UTF-8 字符边界:下一字节若是续字节(0x80-0xBF)说明切在字符中间。
    while cut > 1 do
        local next_byte = text:byte(cut + 1)
        if not next_byte or next_byte < 0x80 or next_byte >= 0xC0 then break end
        cut = cut - 1
    end
    return text:sub(1, cut)
end

-- 保持 underlines 原始顺序取引文(热门划线本身按热度排,「二月二,龙抬头。」
-- 这种全民短句就在最前),不按长度排序——长引文在精校版差异面前最脆,
-- 按长度优先曾把 5 个 90 字节的坏引文选满,把能精确命中的短名句挤出局。
function ChapterMap.quotes_of(underlines, limit)
    limit = tonumber(limit) or 8
    local out, seen = {}, {}
    for _, row in ipairs(underlines or {}) do
        if #out >= limit then break end
        if type(row) == "table" then
            for _, key in ipairs({"markText", "bookmarkText", "rangeText", "abstract", "text", "content"}) do
                local quote = utf8_prefix(ChapterMap.normalize(scalar_str(row[key])), MAX_QUOTE_BYTES)
                if #quote >= MIN_QUOTE_BYTES and not seen[quote] then
                    seen[quote] = true
                    out[#out + 1] = quote
                    break
                end
            end
        end
    end
    return out
end

-- 从原始 HTML 提取 h1-h6 标题,再换算到 normalize 后的字节坐标。
-- 用标题所在 opening tag 之前的规范化长度计算位置,避免正文中先出现同名
-- 文本时把标题边界错放到前文。非 h 标签书籍不返回边界,由旧回退路径处理。
local function heading_blocks(html, normalized)
    local source = tostring(html or "")
    local blocks, cursor = {}, 1
    while cursor <= #source do
        local open_start, open_end, level = source:find(
            "<%s*[hH]([1-6])[^>]*>", cursor)
        if not open_start then break end
        local close_start, close_end = source:find(
            "</%s*[hH]" .. tostring(level) .. "%s*>", open_end + 1)
        if not close_start then break end
        local inner = source:sub(open_end + 1, close_start - 1)
        local heading = ChapterMap.normalize(inner)
        if heading ~= "" then
            local start = #ChapterMap.normalize(source:sub(1, open_end)) + 1
            if start >= 1 and start <= #normalized + 1 then
                blocks[#blocks + 1] = {
                    start = start, title = heading,
                    key = ChapterMap.title_key(heading),
                }
            end
        end
        cursor = close_end + 1
    end
    table.sort(blocks, function(a, b) return a.start < b.start end)
    local unique = {}
    for _, block in ipairs(blocks) do
        local previous = unique[#unique]
        if not previous or previous.start ~= block.start then
            unique[#unique + 1] = block
        end
    end
    for index, block in ipairs(unique) do
        block["end"] = unique[index + 1] and unique[index + 1].start or (#normalized + 1)
    end
    return unique
end

-- 单文件流式:内存里同一时刻只保留一个正文文件的文本(百兆大书在
-- 256MB 的老设备上不能把全书文本都攥在手里),对它一次性统计所有章节的
-- 引文命中与标题命中,然后立刻释放。
local function build_with_scanner(spine, chapters, scan, options)
    chapters = chapters or {}
    options = options or {}
    -- 预计算每章引文与规范化标题;全部标题用于识别目录页
    -- (一个文件若包含大半章节标题,它是目录/导航页,标题兜底绝不能落在上面)。
    local quotes_list, titles = {}, {}
    local all_titles, seen_titles = {}, {}
    for ci, ch in ipairs(chapters) do
        quotes_list[ci] = #(ch.underlines or {}) > 0 and ChapterMap.quotes_of(ch.underlines) or {}
        local title = ChapterMap.title_key(ch.title)
        titles[ci] = #title >= 6 and title or nil
        if titles[ci] and not seen_titles[title] then
            seen_titles[title] = true
            all_titles[#all_titles + 1] = title
        end
    end
    local toc_threshold = math.max(2, math.ceil(#all_titles * 0.5))

    local title_index = {}   -- [title_key] = {chapter indexes}
    for ci, title in ipairs(titles) do
        if title then
            title_index[title] = title_index[title] or {}
            title_index[title][#title_index[title] + 1] = ci
        end
    end

    local scores = {}       -- [ci] = {{href, score}, ...}(spine 顺序)
    local title_hits = {}   -- [ci] = {href, ...}(已排除目录页)
    local title_hit_seen = {} -- [ci][href] = true,同文件重复标题只算一个目标
    local metrics = {
        primary_files = 0, bounded_files = 0, bounded_chapters = 0,
        fallback_files = 0, fallback_chapters = 0, quote_checks = 0,
        checkpoints = 0,
    }

    local function checkpoint()
        metrics.checkpoints = metrics.checkpoints + 1
        if type(options.on_check) == "function"
            and metrics.checkpoints % (tonumber(options.check_interval) or 16) == 0 then
            return options.on_check(metrics) ~= false
        end
        return true
    end

    local function add_title_hit(ci, item, spine_index)
        local href = tostring(item.href)
        title_hit_seen[ci] = title_hit_seen[ci] or {}
        if title_hit_seen[ci][href] then return end
        title_hit_seen[ci][href] = true
        title_hits[ci] = title_hits[ci] or {}
        title_hits[ci][#title_hits[ci] + 1] = {
            href = item.href, spine_index = spine_index,
        }
    end

    local function quote_in_ranges(text, quote, ranges)
        if not ranges then return text:find(quote, 1, true) ~= nil end
        for _, range in ipairs(ranges) do
            local first, last = text:find(quote, range.start, true)
            if first and first < range["end"] then
                if last + 1 <= range["end"] then return true end
            end
        end
        return false
    end

    local function process_item(spine_index, item, html, read_err, phase, target_set)
        local text = html and ChapterMap.normalize(html) or nil
        if not text then
            logger.warn("[撷思][ChapterMap] 读取章节失败",
                "href=", tostring(item.href), "err=", tostring(read_err))
        elseif text ~= "" then
            phase = phase or "primary"
            if phase == "primary" then metrics.primary_files = metrics.primary_files + 1 end
            local blocks = heading_blocks(html, text)
            local block_matches = {}
            local distinct_titles = {}
            local distinct_count = 0
            local legacy_title_cis = {}
            local legacy_distinct = 0
            if #blocks == 0 then
                local legacy_seen = {}
                for ci, title in ipairs(titles) do
                    if title and text:find(title, 1, true) then
                        legacy_title_cis[#legacy_title_cis + 1] = ci
                        if not legacy_seen[title] then
                            legacy_seen[title] = true
                            legacy_distinct = legacy_distinct + 1
                        end
                    end
                end
            end
            for _, block in ipairs(blocks) do
                local matches = title_index[block.key]
                if matches then
                    if not distinct_titles[block.key] then
                        distinct_titles[block.key] = true
                        distinct_count = distinct_count + 1
                    end
                    for _, ci in ipairs(matches) do
                        block_matches[ci] = block_matches[ci] or {}
                        block_matches[ci][#block_matches[ci] + 1] = {
                            start = block.start, ["end"] = block["end"],
                        }
                    end
                else
                    -- 卷首说明可能把目标章名包在更长标题里(例如“第一卷...惊蛰...卷首”)。
                    -- 只在 h 标签块内做子串匹配,不会退化为每个正文文件扫描所有标题。
                    for ci, title in ipairs(titles) do
                        if title and block.key:find(title, 1, true) then
                            block_matches[ci] = block_matches[ci] or {}
                            block_matches[ci][#block_matches[ci] + 1] = {
                                start = block.start, ["end"] = block["end"],
                            }
                        end
                    end
                end
            end
            local is_toc = (#blocks > 0 and distinct_count >= toc_threshold)
                or (#blocks == 0 and legacy_distinct >= toc_threshold)
            local bounded = #blocks > 0 and (distinct_count > 0 or next(block_matches) ~= nil) and not is_toc
            local candidates = {}

            if phase == "fallback" then
                metrics.fallback_files = metrics.fallback_files + 1
                for ci in pairs(target_set or {}) do candidates[ci] = true end
                -- 回退也要保留目录页保护:正文标题可做兜底,目录标题不可做兜底。
                if not is_toc then
                    for ci in pairs(target_set or {}) do
                        local title = titles[ci]
                        if title and text:find(title, 1, true) then
                            add_title_hit(ci, item, spine_index)
                        end
                    end
                end
            elseif #blocks == 0 then
                -- 没有结构化标题的 EPUB 保留完整旧路径。
                for ci in ipairs(chapters) do candidates[ci] = true end
                if not is_toc then
                    for _, ci in ipairs(legacy_title_cis) do
                        add_title_hit(ci, item, spine_index)
                    end
                end
            elseif is_toc then
                -- 标题数量达到目录阈值时不信任边界,但引文仍按旧路径检查。
                for ci in ipairs(chapters) do candidates[ci] = true end
            elseif bounded then
                metrics.bounded_files = metrics.bounded_files + 1
                for ci, ranges in pairs(block_matches) do
                    candidates[ci] = ranges
                    metrics.bounded_chapters = metrics.bounded_chapters + 1
                    for _ in ipairs(ranges) do add_title_hit(ci, item, spine_index) end
                end
                -- 有 h 标签但标题写在卷首说明/自定义节点里的 EPUB,保留旧的
                -- 标题兜底;仅在本文件没有任何精确标题边界时执行,避免把主路径
                -- 退化成“每文件扫描全部目标标题”。
                if distinct_count == 0 and not is_toc then
                    for ci, title in ipairs(titles) do
                        if title and text:find(title, 1, true) then
                            add_title_hit(ci, item, spine_index)
                        end
                    end
                end
            end

            for ci, ranges in pairs(candidates) do
                if not checkpoint() then return false end
                local quotes = quotes_list[ci]
                if #quotes > 0 then
                    local score = 0
                    for _, quote in ipairs(quotes) do
                        if not checkpoint() then return false end
                        metrics.quote_checks = metrics.quote_checks + 1
                        if quote_in_ranges(text, quote, type(ranges) == "table" and ranges or nil) then
                            score = score + 1
                        end
                    end
                    if score > 0 then
                        scores[ci] = scores[ci] or {}
                        scores[ci][#scores[ci] + 1] = {
                            href = item.href, score = score, spine_index = spine_index,
                        }
                    end
                end
            end
            if phase == "fallback" then
                for _ in pairs(target_set or {}) do metrics.fallback_chapters = metrics.fallback_chapters + 1 end
            end
        end
        text = nil
        collectgarbage("step", 400)
        if not checkpoint() then return false end
        return true
    end

    local scan_ok, scan_err = scan(process_item, "primary")
    if scan_ok == nil or scan_ok == false then error(scan_err or "无法读取 EPUB 正文") end

    -- 标题索引未覆盖的章节才启动兼容回退。正常有结构书籍不会进入这里;
    -- 标题被改写、正文没有 h 标签或 EPUB 结构异常时仍能复用旧定位语义。
    local fallback_cis, fallback_count = {}, 0
    for ci, quotes in ipairs(quotes_list) do
        if #quotes > 0 then
            local strong_min = math.min(2, #quotes)
            local has_strong = false
            for _, entry in ipairs(scores[ci] or {}) do
                if entry.score >= strong_min then has_strong = true; break end
            end
            if not has_strong and not title_hits[ci] then
                fallback_cis[ci] = true
                fallback_count = fallback_count + 1
            end
        end
    end
    if fallback_count > 0 then
        scan_ok, scan_err = scan(process_item, "fallback", fallback_cis)
        if scan_ok == nil or scan_ok == false then error(scan_err or "无法读取 EPUB 正文") end
    end
    logger.info("[撷思][ChapterMap] strategy",
        "bounded_files=", tostring(metrics.bounded_files),
        "bounded_chapters=", tostring(metrics.bounded_chapters),
        "fallback_files=", tostring(metrics.fallback_files),
        "fallback_chapters=", tostring(fallback_count),
        "quote_checks=", tostring(metrics.quote_checks))
    local function by_spine(a, b)
        return (tonumber(a.spine_index) or 0) < (tonumber(b.spine_index) or 0)
    end
    for _, rows in pairs(scores) do table.sort(rows, by_spine) end
    for _, rows in pairs(title_hits) do table.sort(rows, by_spine) end

    -- 一个微信章可以映射到多个本地文件(实测:微信版《剑来》把本地两章
    -- 合并成一章,单文件模型让每章后半的划线永远落不进书)。
    -- 多目标/标题兜底目标一律 quote_only:各文件只注入能在该文件里
    -- 引文对齐的划线,禁用数字兜底,防止错位与跨文件重复。
    local MAX_TARGETS = 4
    local mapped, unmatched = {}, {}
    for ci, ch in ipairs(chapters) do
        local underlines = ch.underlines or {}
        if #underlines == 0 then
            unmatched[#unmatched + 1] = {uid = tostring(ch.uid or ""), title = ch.title, reason = "no_data"}
        else
            -- 统一定案规则:得分 ≥ min(2, 引文数) 的文件都是注入目标。
            -- 多个强档文件平分不是歧义,恰是「微信合并章拆在多个本地文件」
            -- 的正常信号(各半引文各中一半)。
            -- 弱证据仍不定案:多条引文只中 1 条是俗语复现的孤证
            -- (真实翻车:《惊蛰》错投《日出》),转标题兜底;
            -- 单引文命中多个文件才是真歧义,放弃投票。
            local strong_min = math.min(2, #quotes_list[ci])
            local targets = {}
            local vote_single = false
            for _, entry in ipairs(scores[ci] or {}) do
                if entry.score >= strong_min and #targets < MAX_TARGETS then
                    targets[#targets + 1] = entry.href
                end
            end
            if strong_min == 1 and #targets > 1 then targets = {} end
            if #targets > 0 then
                vote_single = #targets == 1
            else
                -- 标题兜底放宽到 1~3 个命中:合并章/卷首引用会让标题出现在
                -- 多个文件里,quote_only 把关后多注不错,只会多救回。
                local hits = title_hits[ci] or {}
                if #hits >= 1 and #hits <= 3 then
                    for _, hit in ipairs(hits) do targets[#targets + 1] = hit.href end
                end
            end
            if #targets > 0 then
                -- 只有「投票强证据 + 单目标」保留数字兜底(同版书受益);
                -- 其余场景数字偏移不可信,一律 quote_only。
                local quote_only = not vote_single or nil
                for _, href in ipairs(targets) do
                    mapped[#mapped + 1] = {
                        chapter_uid = tostring(ch.uid or ""), href = href,
                        underlines = underlines, review_map = ch.review_map or {},
                        thought_count_by_range = ch.thought_count_by_range,
                        thought_ranges = ch.thought_ranges,
                        thought_count = ch.thought_count,
                        thought_entry_count = ch.thought_entry_count,
                        cache_bytes = ch.cache_bytes,
                        quote_only = quote_only, book_id = ch.book_id,
                    }
                end
            else
                unmatched[#unmatched + 1] = {uid = tostring(ch.uid or ""), title = ch.title,
                    reason = "no_hit", book_id = ch.book_id}
            end
        end
    end
    return mapped, unmatched, metrics
end

function ChapterMap.build(spine, read_text, chapters, options)
    return build_with_scanner(spine, chapters, function(visit, phase, target_set)
        for index, item in ipairs(spine or {}) do
            local ok, html, err = pcall(read_text, item.href)
            if ok and html == false then return false, "已取消" end
            if visit(index, item, ok and html or nil, ok and err or html,
                    phase, target_set) == false then
                return false, "已取消"
            end
        end
        return true
    end, options)
end

function ChapterMap.build_stream(spine, each_text, chapters, options)
    return build_with_scanner(spine, chapters, function(visit, phase, target_set)
        return each_text(function(item, content, err, index)
            return visit(index, item, content, err, phase, target_set)
        end, phase, target_set)
    end, options)
end

return ChapterMap
