local ChapterMap = require("pickthought.chapter_map")

local FILES = {
    ["OEBPS/c1.xhtml"] = [[<html><head><title>卷一</title></head><body>
<h2>第一章 春江潮水</h2>
<p>春江潮水连海平,
海上&amp;明月共潮生。</p></body></html>]],
    ["OEBPS/c2.xhtml"] = [[<html><body>
<h2>第二章 月照花林</h2>
<p>滟滟随波千万里,何处春江无月明。</p>
<p>江流宛转绕芳甸,月照花林皆似霰。</p></body></html>]],
}

local SPINE = {{href = "OEBPS/c1.xhtml"}, {href = "OEBPS/c2.xhtml"}}

local function read_text(href) return FILES[href] end

T.case("normalize 剥标签解实体去空白", function()
    T.eq(ChapterMap.normalize("<p>春江  潮水\n连海平</p>"), "春江潮水连海平", "标签+空白")
    T.eq(ChapterMap.normalize("海上&amp;明月"), "海上&明月", "实体")
    T.eq(ChapterMap.normalize("&#x8FD9;&#x662F;"), "这是", "十六进制数值实体解码为中文")
    T.eq(ChapterMap.normalize("&#36825;&#26159;"), "这是", "十进制数值实体解码为中文")
    T.eq(ChapterMap.normalize("&#8220;引&#8221;"), "“引”", "弯引号数值实体与字面一致")
end)

T.case("流式映射收到取消后立即停止扫描", function()
    local calls = 0
    local ok, err = pcall(function()
        return ChapterMap.build_stream(SPINE, function(callback)
            for index, item in ipairs(SPINE) do
                calls = calls + 1
                if callback(item, FILES[item.href], nil, index) == false then
                    return false, "已取消"
                end
            end
            return true
        end, {{uid = "1", title = "第一章", underlines = {
            {range = "0-7", markText = "春江潮水连海平"},
        }}})
    end)
    T.ok(not ok and tostring(err):find("已取消", 1, true), "取消应从流式映射返回")
    T.eq(calls, 2, "未取消时映射扫描全部正文")

    calls = 0
    local cancelled_ok, cancelled_err = pcall(function()
        return ChapterMap.build_stream(SPINE, function(callback)
            calls = calls + 1
            callback(SPINE[1], FILES[SPINE[1].href], nil, 1)
            return false, "已取消"
        end, {{uid = "1", title = "第一章", underlines = {
            {range = "0-7", markText = "春江潮水连海平"},
        }}})
    end)
    T.ok(not cancelled_ok and tostring(cancelled_err):find("已取消", 1, true),
        "底层读取取消应继续向上映射")
    T.eq(calls, 1, "底层读取取消后不再扫描下一轮")
end)

T.case("实体化编码的正文也能被引文命中", function()
    local files = {
        ["c1.xhtml"] = "<html><body><p>&#26149;&#27743;&#28526;&#27700;&#36830;&#28023;&#24179;</p></body></html>",
    }
    local mapped = ChapterMap.build({{href = "c1.xhtml"}}, function(h) return files[h] end, {
        {uid = "1", title = "第一章", underlines = {{range = "0-7", markText = "春江潮水连海平"}}},
    })
    T.eq(#mapped, 1, "实体化正文命中")
    T.eq(mapped[1].href, "c1.xhtml", "映射正确")
end)

T.case("标题兜底避开目录页", function()
    local files = {
        ["toc.xhtml"] = [[<html><body><ol>
<li>第一章 春江潮水</li><li>第二章 月照花林</li></ol></body></html>]],
        ["c1.xhtml"] = FILES["OEBPS/c1.xhtml"],
        ["c2.xhtml"] = FILES["OEBPS/c2.xhtml"],
    }
    local spine = {{href = "toc.xhtml"}, {href = "c1.xhtml"}, {href = "c2.xhtml"}}
    local chapters = {
        {uid = "1", title = "第一章 春江潮水",
         underlines = {{range = "0-3", markText = "微信侧独有文字甲乙丙丁"}}},
        {uid = "2", title = "第二章 月照花林",
         underlines = {{range = "0-3", markText = "微信侧独有文字戊己庚辛"}}},
    }
    local mapped, unmatched = ChapterMap.build(spine, function(h) return files[h] end, chapters)
    T.eq(#mapped, 2, "两章都经标题兜底命中: unmatched=" .. tostring(#unmatched))
    T.eq(mapped[1].href, "c1.xhtml", "第一章不落目录页")
    T.eq(mapped[2].href, "c2.xhtml", "第二章不落目录页")
end)

T.case("巨型省略引文按前缀窗口匹配", function()
    -- 模拟微信 abstract:前 40 字与正文一致,中段被省略拼接后整条在书里不存在。
    local head = string.rep("春江潮水连海平海上明月共潮生", 4)
    local broken_quote = head .. string.rep("这段被省略拼接后书里没有", 20)
    local files = {["c1.xhtml"] = "<html><body><p>" .. head .. "滟滟随波千万里。</p></body></html>"}
    local quotes = ChapterMap.quotes_of({{range = "0-9", markText = broken_quote}})
    T.ok(#quotes[1] <= 90, "引文截断到前缀窗口: len=" .. #quotes[1])
    local mapped = ChapterMap.build({{href = "c1.xhtml"}}, function(h) return files[h] end, {
        {uid = "1", title = "短", underlines = {{range = "0-9", markText = broken_quote}}},
    })
    T.eq(#mapped, 1, "前缀命中,整章不再因巨型引文失配")
end)

T.case("拆分章:一微信章注入多本地文件(quote_only)", function()
    -- 微信把本地两章合并:引文一半在 cA、一半在 cB(各 ≥2 条)。
    local files = {
        ["cA.xhtml"] = [[<html><body><p>甲文件专属引文其一在此处出现。甲文件专属引文其二也在这。</p></body></html>]],
        ["cB.xhtml"] = [[<html><body><p>乙文件专属引文其一在此处出现。乙文件专属引文其二也在这。</p></body></html>]],
    }
    local spine = {{href = "cA.xhtml"}, {href = "cB.xhtml"}}
    local chapters = {{
        uid = "9", title = "第一章 合并",
        underlines = {
            {range = "0-1", markText = "甲文件专属引文其一"},
            {range = "1-2", markText = "甲文件专属引文其二"},
            {range = "2-3", markText = "乙文件专属引文其一"},
            {range = "3-4", markText = "乙文件专属引文其二"},
        },
    }}
    local mapped, unmatched = ChapterMap.build(spine, function(h) return files[h] end, chapters)
    T.eq(#unmatched, 0, "无未匹配")
    T.eq(#mapped, 2, "同一微信章产出两个目标文件")
    T.eq(mapped[1].chapter_uid, "9", "uid 相同")
    T.eq(mapped[2].chapter_uid, "9", "uid 相同")
    T.ok(mapped[1].href ~= mapped[2].href, "两个不同文件")
    T.ok(mapped[1].quote_only and mapped[2].quote_only, "拆分章一律 quote_only")
end)

T.case("章号体系不一致时按章名本体兜底", function()
    -- 微信「第六章 姑娘请自重」 vs 本地「第二百八十四章 姑娘请自重」
    local files = {
        ["c294.xhtml"] = "<html><head><title>第二百八十四章 姑娘请自重</title></head><body><h2>第二百八十四章 姑娘请自重</h2><p>正文内容。</p></body></html>",
        ["c295.xhtml"] = "<html><body><h2>第二百八十五章 别的章</h2><p>别的内容。</p></body></html>",
    }
    local spine = {{href = "c294.xhtml"}, {href = "c295.xhtml"}}
    local chapters = {{
        uid = "1077", title = "第六章 姑娘请自重",
        underlines = {{range = "0-1", markText = "精校后不存在的引文内容一"},
                      {range = "1-2", markText = "精校后不存在的引文内容二"}},
    }}
    local mapped, unmatched = ChapterMap.build(spine, function(h) return files[h] end, chapters)
    T.eq(#mapped, 1, "剥编号后章名命中: unmatched=" .. tostring(#unmatched))
    T.eq(mapped[1].href, "c294.xhtml", "跨编号体系救回正确章节")
    T.eq(ChapterMap.title_key("第六章 姑娘请自重"), "姑娘请自重", "title_key 剥前缀")
    T.eq(ChapterMap.title_key("第三章 上"), "第三章上", "剥完过短退回全标题")
end)

T.case("标题多命中(≤3)救援为多目标 quote_only", function()
    local files = {
        ["v.xhtml"] = "<html><body><h1>第一卷 引用了 第一章 惊蛰 的卷首</h1><p>卷首语。</p></body></html>",
        ["c.xhtml"] = "<html><body><h2>第一章 惊蛰</h2><p>二月二,龙抬头。</p></body></html>",
    }
    local spine = {{href = "v.xhtml"}, {href = "c.xhtml"}}
    local chapters = {{
        uid = "1", title = "第一章 惊蛰",
        underlines = {{range = "0-1", markText = "精校后已不存在的引文甲"},
                      {range = "1-2", markText = "精校后已不存在的引文乙"}},
    }}
    local mapped = ChapterMap.build(spine, function(h) return files[h] end, chapters)
    T.eq(#mapped, 2, "标题两处命中都作为目标(旧算法直接放弃)")
    T.ok(mapped[1].quote_only, "标题目标 quote_only,引文对齐把关")
end)

T.case("引文按热度原序取,短名句不被长引文挤出", function()
    local underlines = {
        {range = "0-3", markText = "二月二,龙抬头。"},
        {range = "1-2", markText = string.rep("很长的引文占位内容", 12)},
        {range = "2-3", markText = string.rep("另一条很长的引文内容", 12)},
    }
    local quotes = ChapterMap.quotes_of(underlines)
    T.eq(quotes[1], "二月二,龙抬头。", "第一条热门短句保住投票席位")
end)

T.case("孤证引文不定案:转标题兜底救回正确章节", function()
    -- 复刻剑来翻车:5 条引文里 4 条被精校差异灭掉,剩下的俗语只在错误
    -- 章节里出现;旧算法 1 分定案错章,新算法转标题兜底定对。
    local files = {
        ["c07.xhtml"] = [[<html><head><title>第一章 惊蛰</title></head><body>
<h2>第一章 惊蛰</h2><p>二月二,龙抬头。少年推开门。</p></body></html>]],
        ["c09.xhtml"] = [[<html><head><title>第三章 日出</title></head><body>
<h2>第三章 日出</h2><p>命里有时终须有,命里无时莫强求,这是老人常说的话。</p></body></html>]],
    }
    local spine = {{href = "c07.xhtml"}, {href = "c09.xhtml"}}
    local chapters = {{
        uid = "999", title = "第一章 惊蛰",
        underlines = {
            {range = "0-1", markText = "命里有时终须有,命里无时莫强求,这是老人常说的话"},
            {range = "1-2", markText = "精校版里已经不存在的第一句引文内容甲"},
            {range = "2-3", markText = "精校版里已经不存在的第二句引文内容乙"},
            {range = "3-4", markText = "精校版里已经不存在的第三句引文内容丙"},
            {range = "4-5", markText = "精校版里已经不存在的第四句引文内容丁"},
        },
    }}
    local mapped, unmatched = ChapterMap.build(spine, function(h) return files[h] end, chapters)
    T.eq(#mapped, 1, "应经标题兜底命中: unmatched=" .. tostring(#unmatched))
    T.eq(mapped[1].href, "c07.xhtml", "孤证不定案,标题救回正确章节(而非 1 分错投 c09)")
end)

T.case("投票平票视为歧义转兜底", function()
    local files = {
        ["a.xhtml"] = "<html><body><p>两个文件都有的同一段引文内容。甲文件专属段落。</p></body></html>",
        ["b.xhtml"] = "<html><body><p>两个文件都有的同一段引文内容。乙文件专属段落。</p></body></html>",
    }
    local spine = {{href = "a.xhtml"}, {href = "b.xhtml"}}
    local chapters = {{uid = "1", title = "短",
        underlines = {{range = "0-9", markText = "两个文件都有的同一段引文内容"}}}}
    local mapped, unmatched = ChapterMap.build(spine, function(h) return files[h] end, chapters)
    T.eq(#mapped, 0, "平票不硬选")
    T.eq(unmatched[1].reason, "no_hit", "标题太短兜底不了 → no_hit")
end)

T.case("引文投票映射两章", function()
    local chapters = {
        {uid = "11", title = "第一章", underlines = {{range = "0-7", markText = "海上&明月共潮生"}}},
        {uid = "12", title = "第二章", underlines = {{range = "9-9", markText = "月照花林皆似霰"}}},
    }
    local mapped, unmatched = ChapterMap.build(SPINE, read_text, chapters)
    T.eq(#mapped, 2, "两章均命中")
    T.eq(#unmatched, 0, "无未命中")
    T.eq(mapped[1].href, "OEBPS/c1.xhtml", "第一章 → c1(实体+换行都不挡命中)")
    T.eq(mapped[2].href, "OEBPS/c2.xhtml", "第二章 → c2")
    T.eq(mapped[1].chapter_uid, "11", "chapter_uid 透传")
    T.ok(mapped[1].underlines and mapped[1].review_map, "underlines/review_map 透传")
end)

T.case("标题兜底", function()
    local chapters = {{
        uid = "21", title = "第二章 月照花林",
        underlines = {{range = "0-3", markText = "微信侧独有的文字不在本地书里"}},
    }}
    local mapped, unmatched = ChapterMap.build(SPINE, read_text, chapters)
    T.eq(#mapped, 1, "引文不中时标题兜底")
    T.eq(mapped[1].href, "OEBPS/c2.xhtml", "标题命中 c2")
    T.eq(#unmatched, 0, "无未命中")
end)

T.case("no_data 与 no_hit", function()
    local chapters = {
        {uid = "31", title = "空章", underlines = {}},
        {uid = "32", title = "查无此章", underlines = {{range = "0-3", markText = "完全不存在的引文文本"}}},
    }
    local mapped, unmatched = ChapterMap.build(SPINE, read_text, chapters)
    T.eq(#mapped, 0, "都不该命中")
    T.eq(unmatched[1].reason, "no_data", "无划线 → no_data")
    T.eq(unmatched[2].reason, "no_hit", "引文标题都不中 → no_hit")
    T.eq(unmatched[2].uid, "32", "uid 保留")
end)

T.case("多个微信章节命中同一文件且顺序保留", function()
    local chapters = {
        {uid = "41", title = "上半", underlines = {{range = "0-5", markText = "滟滟随波千万里"}}},
        {uid = "42", title = "下半", underlines = {{range = "6-9", markText = "江流宛转绕芳甸"}}},
    }
    local mapped = ChapterMap.build(SPINE, read_text, chapters)
    T.eq(#mapped, 2, "两章都映射")
    T.eq(mapped[1].href, "OEBPS/c2.xhtml", "同一文件")
    T.eq(mapped[2].href, "OEBPS/c2.xhtml", "同一文件")
    T.eq(mapped[1].chapter_uid, "41", "顺序保留")
    T.eq(mapped[2].chapter_uid, "42", "顺序保留")
end)

T.case("流式读取顺序不同也按 spine 顺序输出多目标", function()
    local spine = {{href = "a.xhtml"}, {href = "b.xhtml"}}
    local files = {
        ["a.xhtml"] = "<p>甲文件专属引文其一。甲文件专属引文其二。</p>",
        ["b.xhtml"] = "<p>乙文件专属引文其一。乙文件专属引文其二。</p>",
    }
    local chapters = {{uid = "1", title = "合并章", underlines = {
        {markText = "甲文件专属引文其一"}, {markText = "甲文件专属引文其二"},
        {markText = "乙文件专属引文其一"}, {markText = "乙文件专属引文其二"},
    }}}
    local mapped = ChapterMap.build_stream(spine, function(visit)
        visit(spine[2], files["b.xhtml"], nil, 2)
        visit(spine[1], files["a.xhtml"], nil, 1)
        return true
    end, chapters)
    T.eq(#mapped, 2, "两个目标均命中")
    T.eq(mapped[1].href, "a.xhtml", "恢复 spine 第一项")
    T.eq(mapped[2].href, "b.xhtml", "恢复 spine 第二项")
end)

T.case("章节边界只检查相关候选并返回指标", function()
    local files = {
        ["c1.xhtml"] = "<h2>第一章 甲乙丙丁</h2><p>第一章的正文引文甲乙丙丁。</p>",
        ["c2.xhtml"] = "<h2>第二章 戊己庚辛</h2><p>第二章的正文引文戊己庚辛。</p>",
        ["c3.xhtml"] = "<h2>第三章 壬癸子丑</h2><p>第三章的正文引文壬癸子丑。</p>",
        ["c4.xhtml"] = "<h2>第四章 其他内容</h2><p>无关正文。</p>",
        ["c5.xhtml"] = "<h2>第五章 其他内容</h2><p>无关正文。</p>",
        ["c6.xhtml"] = "<h2>第六章 其他内容</h2><p>无关正文。</p>",
    }
    local spine = {}
    for i = 1, 6 do spine[i] = {href = "c" .. tostring(i) .. ".xhtml"} end
    local chapters = {
        {uid = "1", title = "第一章 甲乙丙丁", underlines = {
            {range = "0-8", markText = "第一章的正文引文甲乙丙丁"},
        }},
        {uid = "2", title = "第二章 戊己庚辛", underlines = {
            {range = "0-8", markText = "第二章的正文引文戊己庚辛"},
        }},
        {uid = "3", title = "第三章 壬癸子丑", underlines = {
            {range = "0-8", markText = "第三章的正文引文壬癸子丑"},
        }},
    }
    local mapped, unmatched, metrics = ChapterMap.build(spine, function(href) return files[href] end,
        chapters, {check_interval = 1})
    T.eq(#mapped, 3, "三章均命中")
    T.eq(#unmatched, 0, "没有未匹配章节")
    T.ok(metrics and metrics.bounded_files >= 3, "记录章节边界命中文件")
    T.ok(metrics.quote_checks <= 9, "候选搜索量被章节边界压缩")
    T.ok(metrics.checkpoints > 0, "记录协作检查点")
end)

T.case("章节映射检查点取消会停止扫描", function()
    local calls = 0
    local ok, err = pcall(function()
        return ChapterMap.build({{href = "c1.xhtml"}, {href = "c2.xhtml"}}, function(href)
            return "<h2>第一章 甲乙丙丁</h2><p>第一章的正文引文甲乙丙丁。</p>"
        end, {{uid = "1", title = "第一章 甲乙丙丁", underlines = {
            {range = "0-8", markText = "第一章的正文引文甲乙丙丁"},
        }}}, {check_interval = 1, on_check = function()
            calls = calls + 1
            return false
        end})
    end)
    T.ok(not ok and tostring(err):find("已取消", 1, true), "检查点取消向上传播")
    T.ok(calls > 0, "触发了检查点")
end)
