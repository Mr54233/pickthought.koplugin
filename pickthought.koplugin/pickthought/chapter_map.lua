-- 章节映射:用划线引文在本地 spine 文档里投票,把微信读书章节映射到 zip 内 href。
-- 引文和文档正文走同一套 normalize(剥标签、解实体、去全部空白),
-- 这样换行/排版/实体化差异不影响命中;引文全不中时用章节标题兜底(避开目录页)。
local logger = require("logger")

local ChapterMap = {}

-- 匹配算法版本:任何影响匹配结果的改动(引文窗口、投票规则、目录页判定、
-- 归一化规则)都必须 +1。映射缓存把它写进指纹,算法一改缓存整体作废——
-- 否则旧算法缓存下来的「匹配失败」会永久生效,改进永远轮不到那些章节。
ChapterMap.ALGO_VERSION = 7

-- 标题钥匙:剥掉「第X章/节/回…」编号前缀。微信与本地书的章号体系
-- 经常不一致(实测:微信「第六章 姑娘请自重」= 本地「第二百八十四章
-- 姑娘请自重」),整标题匹配必死;章名本体才是稳定标识。
-- 剥完不足 6 字节(如「上」「下」)退回全标题。
function ChapterMap.title_key(title)
    local t = ChapterMap.normalize(title)
    local stripped = t:gsub("^第[%d零一二三四五六七八九十百千两]+[章节回卷部集篇]", "")
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

-- 单文件流式:内存里同一时刻只保留一个正文文件的文本(百兆大书在
-- 256MB 的老设备上不能把全书文本都攥在手里),对它一次性统计所有章节的
-- 引文命中与标题命中,然后立刻释放。
local function build_with_scanner(spine, chapters, scan)
    chapters = chapters or {}
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

    local scores = {}       -- [ci] = {{href, score}, ...}(spine 顺序)
    local title_hits = {}   -- [ci] = {href, ...}(已排除目录页)
    local function process_item(spine_index, item, html, read_err)
        local text = html and ChapterMap.normalize(html) or nil
        if not text then
            logger.warn("[撷思][ChapterMap] 读取章节失败",
                "href=", tostring(item.href), "err=", tostring(read_err))
        elseif text ~= "" then
            -- 目录页检测不再单独扫 all_titles(大书是 千标题×千文件 的天文数字):
            -- 复用下面每章标题命中的结果,统计本文件命中了多少个「不同标题」,
            -- 超过阈值判为目录页,整批命中作废。
            local file_title_cis = {}
            local distinct_titles = {}
            local distinct_count = 0
            for ci in ipairs(chapters) do
                local quotes = quotes_list[ci]
                if #quotes > 0 then
                    local score = 0
                    for _, quote in ipairs(quotes) do
                        if text:find(quote, 1, true) then score = score + 1 end
                    end
                    if score > 0 then
                        scores[ci] = scores[ci] or {}
                        scores[ci][#scores[ci] + 1] = {
                            href = item.href, score = score, spine_index = spine_index,
                        }
                    end
                end
                local title = titles[ci]
                if title and text:find(title, 1, true) then
                    file_title_cis[#file_title_cis + 1] = ci
                    if not distinct_titles[title] then
                        distinct_titles[title] = true
                        distinct_count = distinct_count + 1
                    end
                end
            end
            if distinct_count < toc_threshold then
                for _, ci in ipairs(file_title_cis) do
                    title_hits[ci] = title_hits[ci] or {}
                    title_hits[ci][#title_hits[ci] + 1] = {
                        href = item.href, spine_index = spine_index,
                    }
                end
            end
        end
        text = nil
        collectgarbage("step", 400)
        return true
    end
    local scan_ok, scan_err = scan(process_item)
    if scan_ok == nil or scan_ok == false then error(scan_err or "无法读取 EPUB 正文") end
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
                        quote_only = quote_only, book_id = ch.book_id,
                    }
                end
            else
                unmatched[#unmatched + 1] = {uid = tostring(ch.uid or ""), title = ch.title,
                    reason = "no_hit", book_id = ch.book_id}
            end
        end
    end
    return mapped, unmatched
end

function ChapterMap.build(spine, read_text, chapters)
    return build_with_scanner(spine, chapters, function(visit)
        for index, item in ipairs(spine or {}) do
            local ok, html, err = pcall(read_text, item.href)
            if ok and html == false then return false, "已取消" end
            if visit(index, item, ok and html or nil, ok and err or html) == false then
                return false, "已取消"
            end
        end
        return true
    end)
end

function ChapterMap.build_stream(spine, each_text, chapters)
    return build_with_scanner(spine, chapters, function(visit)
        return each_text(function(item, content, err, index)
            return visit(index, item, content, err)
        end)
    end)
end

return ChapterMap
