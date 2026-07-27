local EpubInject = require("pickthought.epub_inject")
local Json = require("pickthought.json")

local CONTAINER = [[<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
<rootfiles><rootfile full-path="OEBPS/content.opf"/></rootfiles></container>]]
local OPF = [[<package><manifest>
<item id="c1" href="Text/ch1.xhtml" media-type="application/xhtml+xml"/>
<item id="c2" href="Text/ch2.xhtml" media-type="application/xhtml+xml"/>
</manifest><spine><itemref idref="c1"/><itemref idref="c2"/></spine></package>]]
local CH1 = "<html><head><title>一</title></head><body><p>春江潮水连海平,海上明月共潮生。</p></body></html>"
local CH2 = "<html><head><title>二</title></head><body><p>滟滟随波千万里,何处春江无月明。</p></body></html>"

local function book_files()
    return {
        {path = "mimetype", content = "application/epub+zip"},
        {path = "META-INF/container.xml", content = CONTAINER},
        {path = "OEBPS/content.opf", content = OPF},
        {path = "OEBPS/Text/ch1.xhtml", content = CH1},
        {path = "OEBPS/Text/ch2.xhtml", content = CH2},
        {path = "OEBPS/Images/cover.png", content = "PNG-FAKE-BYTES"},
    }
end

local CHAPTERS = {{
    chapter_uid = "42", href = "Text/ch1.xhtml",
    underlines = {{range = "0-7", markText = "春江潮水连海平"}},
    review_map = {["0-7"] = {{content = "开篇即巅峰", author = "读者甲"}}},
}}

local function run_inject(files, chapters, mock_opts, opts)
    local Arc = STUBS.archiver_mock(files, mock_opts)
    local renames = {}
    opts = opts or {}
    opts.archiver = Arc
    opts.rename = opts.rename or function(a, b) renames[#renames + 1] = {a, b}; return true end
    opts.now = function() return 1234567890 end
    local stats, err = EpubInject.inject_copy("/books/书.epub", "b001", chapters, opts)
    return stats, err, Arc, renames
end

T.case("copy_path 命名", function()
    T.eq(EpubInject.copy_path("/books/书.epub"), "/books/书.撷思.epub", "标准 .epub")
    T.eq(EpubInject.copy_path("/books/书.EPUB"), "/books/书.撷思.epub", "大写后缀")
    T.eq(EpubInject.copy_path("/books/书"), "/books/书.撷思.epub", "无后缀")
end)

T.case("端到端注入", function()
    local prog = {}
    local stats, err, Arc, renames = run_inject(book_files(), CHAPTERS, nil, {
        progress = function(name, i, n) prog[#prog + 1] = {name = name, i = i, n = n} end,
    })
    T.ok(stats, "inject_copy 应成功: " .. tostring(err))
    T.eq(stats.injected, 1, "注入 1 章")
    T.ok(stats.marks >= 1, "至少 1 处锚点")
    T.eq(#stats.unmatched, 0, "无未匹配章节")
    T.eq(stats.dest, "/books/书.撷思.epub", "dest 默认命名")

    local w = Arc._last_writer
    local entries = STUBS.written(w)
    T.eq(entries[1].path, "mimetype", "mimetype 首条")
    T.eq(entries[1].compression, "store", "mimetype 用 store")
    T.eq(entries[1].content, "application/epub+zip", "mimetype 内容原样")

    local by_path = {}
    for _, e in ipairs(entries) do by_path[e.path] = e end
    local ch1 = by_path["OEBPS/Text/ch1.xhtml"]
    T.ok(ch1.compression == "deflate", "正文用 deflate")
    T.ok(ch1.content:find('class="pickthought-mark', 1, true), "锚点 span 注入")
    T.ok(ch1.content:find('href="#pickthought-', 1, true), "想法链接注入(专属前缀)")
    T.ok(ch1.content:find('id="pickthought-annotation-style"', 1, true), "内联样式注入 head")
    T.ok(ch1.content:find("</title>", 1, true) and ch1.content:find("春江潮水", 1, true), "原结构保留")
    T.eq(by_path["OEBPS/Text/ch2.xhtml"].content, CH2, "未涉及章节逐字节原样")
    T.eq(by_path["OEBPS/Images/cover.png"].compression, "store", "已压缩媒体原样 store")
    T.eq(by_path["OEBPS/Images/cover.png"].content, "PNG-FAKE-BYTES", "媒体内容逐字节原样")
    T.eq(by_path[EpubInject.MARKER].compression, "deflate", "媒体 store 之后 marker 回到 deflate")

    T.ok(#prog >= 4, "逐条目进度回调发生")
    T.eq(prog[#prog].i, 6, "计数走到最后一个条目")
    T.eq(prog[#prog].n, 6, "总数=全部 zip 条目")
    for k = 2, #prog do
        T.ok(prog[k].i > prog[k - 1].i, "进度计数单调递增")
    end

    local marker = by_path[EpubInject.MARKER]
    T.ok(marker, "marker 条目存在")
    local decoded = Json.decode(marker.content)
    T.eq(decoded.book_id, "b001", "marker 记录 book_id")
    T.eq(decoded.created, 1234567890, "marker 用注入的 now")

    T.eq(w.opened_path, "/books/书.撷思.epub.tmp-1234567890", "先写带时间戳的 tmp")
    T.eq(renames[1][1], "/books/书.撷思.epub.tmp-1234567890", "rename src")
    T.eq(renames[1][2], "/books/书.撷思.epub", "rename dest")
end)

T.case("拒绝二次注入(is_copy)", function()
    local files = book_files()
    files[#files + 1] = {path = EpubInject.MARKER, content = "{}"}
    T.ok(EpubInject.is_copy("x.epub", STUBS.archiver_mock(files)), "is_copy 识别 marker")
    local stats, err = run_inject(files, CHAPTERS)
    T.ok(stats == nil and tostring(err):find("撷思", 1, true), "对副本注入应拒绝并报中文错")
end)

T.case("章节匹配:后缀与未匹配", function()
    local chapters = {
        {chapter_uid = "42", href = "ch1.xhtml", underlines = CHAPTERS[1].underlines,
         review_map = CHAPTERS[1].review_map},
        {chapter_uid = "99", href = "nope.xhtml", underlines = {{range = "0-3", markText = "xx"}}, review_map = {}},
    }
    local stats, err = run_inject(book_files(), chapters)
    T.ok(stats, "应成功: " .. tostring(err))
    T.eq(stats.injected, 1, "纯文件名后缀匹配成功")
    T.eq(stats.unmatched[1], "99", "未匹配章节记入 unmatched")
end)

T.case("无 head 的章节:样式插到 body 开头", function()
    local files = book_files()
    files[4] = {path = "OEBPS/Text/ch1.xhtml",
        content = "<html><body><p>春江潮水连海平,海上明月共潮生。</p></body></html>"}
    local stats, _, Arc = run_inject(files, CHAPTERS)
    T.eq(stats.injected, 1, "无 head 也能注入")
    local entries = STUBS.written(Arc._last_writer)
    local ch1
    for _, e in ipairs(entries) do if e.path == "OEBPS/Text/ch1.xhtml" then ch1 = e end end
    local style_at = ch1.content:find('id="pickthought-annotation-style"', 1, true)
    local body_at = ch1.content:find("<body", 1, true)
    T.ok(style_at and body_at and style_at > body_at, "样式落在 body 之后")
end)

T.case("大写 HEAD 与无 head/body 碎片的样式插入", function()
    local files = book_files()
    files[4] = {path = "OEBPS/Text/ch1.xhtml",
        content = "<HTML><HEAD><TITLE>一</TITLE></HEAD><BODY><p>春江潮水连海平,海上明月共潮生。</p></BODY></HTML>"}
    local _, _, Arc = run_inject(files, CHAPTERS)
    local ch1
    for _, e in ipairs(STUBS.written(Arc._last_writer)) do
        if e.path == "OEBPS/Text/ch1.xhtml" then ch1 = e end
    end
    local style_at = ch1.content:find('id="pickthought-annotation-style"', 1, true)
    local head_close = ch1.content:find("</HEAD>", 1, true)
    T.ok(style_at and head_close and style_at < head_close, "大写 </HEAD> 也识别,样式进 head")

    files = book_files()
    files[4] = {path = "OEBPS/Text/ch1.xhtml",
        content = '<?xml version="1.0"?><section><p>春江潮水连海平,海上明月共潮生。</p></section>'}
    local _, _, Arc2 = run_inject(files, CHAPTERS)
    local frag
    for _, e in ipairs(STUBS.written(Arc2._last_writer)) do
        if e.path == "OEBPS/Text/ch1.xhtml" then frag = e end
    end
    local decl_end = frag.content:find("?>", 1, true)
    local frag_style = frag.content:find("<style", 1, true)
    T.ok(frag_style and decl_end and frag_style > decl_end, "样式不能插到 <?xml?> 之前")
end)

T.case("写入失败中止并且不 rename", function()
    local stats, err, _, renames = run_inject(book_files(), CHAPTERS,
        {fail_write_path = "OEBPS/Text/ch2.xhtml"})
    T.ok(stats == nil, "写失败应返回 nil")
    T.ok(tostring(err):find("写入副本失败", 1, true), "报写入错误: " .. tostring(err))
    T.eq(#renames, 0, "失败时不得 rename")
end)

T.case("重叠划线只计实际锚点数", function()
    local chapters = {{
        chapter_uid = "42", href = "Text/ch1.xhtml",
        underlines = {
            {range = "0-7", markText = "春江潮水连海平"},
            {range = "2-5"},
        },
        review_map = {},
    }}
    local stats, err = run_inject(book_files(), chapters)
    T.ok(stats, "应成功: " .. tostring(err))
    T.eq(stats.marks, 1, "重叠划线去重后 marks 记实际注入数")
    T.eq(stats.dropped, 1, "被去重叠丢弃的划线计入 dropped")
    T.eq(stats.overlapped, 1, "分项:重叠去重")
    T.eq(stats.unlocated, 0, "分项:未定位为零")
end)

T.case("后缀歧义进 unmatched,同一文件多章叠加注入", function()
    local opf = [[<package><manifest>
<item id="p1" href="part1/ch1.xhtml" media-type="application/xhtml+xml"/>
<item id="p2" href="part2/ch1.xhtml" media-type="application/xhtml+xml"/>
</manifest><spine><itemref idref="p1"/><itemref idref="p2"/></spine></package>]]
    local files = {
        {path = "mimetype", content = "application/epub+zip"},
        {path = "META-INF/container.xml", content = CONTAINER},
        {path = "OEBPS/content.opf", content = opf},
        {path = "OEBPS/part1/ch1.xhtml", content = CH1},
        {path = "OEBPS/part2/ch1.xhtml", content = CH2},
    }
    local chapters = {
        {chapter_uid = "amb", href = "ch1.xhtml", underlines = CHAPTERS[1].underlines,
         review_map = {}},
        {chapter_uid = "42", href = "part1/ch1.xhtml",
         underlines = {{range = "0-7", markText = "春江潮水连海平"}}, review_map = {}},
        {chapter_uid = "43", href = "part1/ch1.xhtml",
         underlines = {{range = "8-15", markText = "海上明月共潮生"}}, review_map = {}},
    }
    local stats, err, Arc = run_inject(files, chapters)
    T.ok(stats, "应成功: " .. tostring(err))
    T.eq(stats.injected, 2, "同一文件两章都注入")
    T.eq(#stats.unmatched, 1, "只有歧义章节未匹配")
    T.eq(stats.unmatched[1], "amb", "歧义章节")
    local ch1
    for _, e in ipairs(STUBS.written(Arc._last_writer)) do
        if e.path == "OEBPS/part1/ch1.xhtml" then ch1 = e end
    end
    T.ok(ch1.content:find('data-pickthought-range="0-7"', 1, true), "第一章锚点在")
    T.ok(ch1.content:find('data-pickthought-range="8-15"', 1, true), "第二章锚点叠加在同一文件")
    local _, style_count = ch1.content:gsub('id="pickthought%-annotation%-style"', "")
    T.eq(style_count, 1, "样式只内联一次")
end)

T.case("没有划线数据时明确报错", function()
    local stats, err = run_inject(book_files(), {
        {chapter_uid = "42", href = "Text/ch1.xhtml", underlines = {}, review_map = {}},
    })
    T.ok(stats == nil and tostring(err):find("没有划线数据", 1, true), "空数据错误信息: " .. tostring(err))
end)

T.case("DRM 加密拒绝,字体混淆放行", function()
    local drm_files = book_files()
    drm_files[#drm_files + 1] = {path = "META-INF/encryption.xml", content = [[<encryption>
<EncryptedData><EncryptionMethod Algorithm="http://www.w3.org/2001/04/xmlenc#aes128-cbc"/></EncryptedData>
</encryption>]]}
    local stats, err = run_inject(drm_files, CHAPTERS)
    T.ok(stats == nil and tostring(err):find("DRM", 1, true), "内容加密应拒绝: " .. tostring(err))

    local font_files = book_files()
    font_files[#font_files + 1] = {path = "META-INF/encryption.xml", content = [[<encryption>
<EncryptedData><EncryptionMethod Algorithm="http://www.idpf.org/2008/embedding"/></EncryptedData>
</encryption>]]}
    local stats2, err2 = run_inject(font_files, CHAPTERS)
    T.ok(stats2 ~= nil, "仅字体混淆应放行: " .. tostring(err2))
end)

T.case("叠加章节引文不中时丢弃,不做数字兜底", function()
    local chapters = {
        {chapter_uid = "42", href = "Text/ch1.xhtml",
         underlines = {{range = "0-7", markText = "春江潮水连海平"}}, review_map = {}},
        {chapter_uid = "43", href = "Text/ch1.xhtml",
         underlines = {{range = "0-4", markText = "别章的文字根本不在这个文件里"}}, review_map = {}},
    }
    local stats, err, Arc = run_inject(book_files(), chapters)
    T.ok(stats, "应成功: " .. tostring(err))
    T.eq(stats.injected, 1, "叠加章节引文不中 → 只有第一章注入")
    local ch1
    for _, e in ipairs(STUBS.written(Arc._last_writer)) do
        if e.path == "OEBPS/Text/ch1.xhtml" then ch1 = e end
    end
    T.ok(not ch1.content:find('data-pickthought-range="0-4"', 1, true), "不得用数字偏移把 43 章划线画进 42 章正文")
    T.eq(stats.unlocated, 1, "分项:引文不中的叠加划线计入未定位")
end)

T.case("拆分章跨文件按唯一划线计未注入", function()
    -- 一个微信章拆到两个本地文件(quote_only):划线 A 只在 ch1、划线 B 只在
    -- ch2 对得上。旧算法每个文件各报一条 unlocated(共 2),唯一划线口径应为 0。
    local chapters = {
        {chapter_uid = "7", href = "Text/ch1.xhtml", quote_only = true,
         underlines = {
            {range = "0-7", markText = "春江潮水连海平"},
            {range = "100-107", markText = "滟滟随波千万里"},
         }, review_map = {}},
        {chapter_uid = "7", href = "Text/ch2.xhtml", quote_only = true,
         underlines = {
            {range = "0-7", markText = "春江潮水连海平"},
            {range = "100-107", markText = "滟滟随波千万里"},
         }, review_map = {}},
    }
    local stats, err = run_inject(book_files(), chapters)
    T.ok(stats, "应成功: " .. tostring(err))
    T.eq(stats.injected, 1, "同 uid 拆分注入只计一章")
    T.eq(stats.marks, 2, "两条划线各落一个文件")
    T.eq(stats.unlocated, 0, "每条划线都有着落,未注入必须为 0")
end)

T.case("叠加章节同 range 键按出现次数差计数", function()
    local chapters = {
        {chapter_uid = "42", href = "Text/ch1.xhtml",
         underlines = {{range = "0-7", markText = "春江潮水连海平"}}, review_map = {}},
        {chapter_uid = "43", href = "Text/ch1.xhtml",
         underlines = {{range = "0-7", markText = "海上明月共潮生"}}, review_map = {}},
    }
    local stats, err = run_inject(book_files(), chapters)
    T.ok(stats, "应成功: " .. tostring(err))
    T.eq(stats.injected, 2, "同 range 键的叠加章节也计入注入")
    T.eq(stats.marks, 2, "出现次数差计数不被键碰撞清零")
end)

T.case("重叠划线带想法时并入存活锚点", function()
    local chapters = {{
        chapter_uid = "42", href = "Text/ch1.xhtml",
        underlines = {
            {range = "0-7", markText = "春江潮水连海平"},
            {range = "2-5", markText = "潮水连海"},
        },
        review_map = {["2-5"] = {{content = "被合并划线上的想法", author = "乙"}}},
    }}
    local stats, err, Arc = run_inject(book_files(), chapters)
    T.ok(stats, "应成功: " .. tostring(err))
    T.eq(stats.marks, 1, "只留一个锚点")
    T.eq(#stats.merges, 1, "记录合并映射")
    T.eq(stats.merges[1].from, "2-5", "from=被合并划线")
    T.eq(stats.merges[1].into, "0-7", "into=存活锚点")
    T.eq(stats.merges[1].uid, "42", "带章节 uid")
    local ch1
    for _, e in ipairs(STUBS.written(Arc._last_writer)) do
        if e.path == "OEBPS/Text/ch1.xhtml" then ch1 = e end
    end
    T.ok(ch1.content:find("pickthought-mark", 1, true), "存活锚点升级为想法虚线")
    T.ok(ch1.content:find('href="#pickthought-', 1, true), "存活锚点带想法链接")
end)

T.case("rename 目标已存在时重试", function()
    local calls = 0
    local stats, err = run_inject(book_files(), CHAPTERS, nil, {
        rename = function()
            calls = calls + 1
            if calls == 1 then return nil, "file exists" end
            return true
        end,
    })
    T.ok(stats, "重试后应成功: " .. tostring(err))
    T.eq(calls, 2, "rename 失败后重试一次")
end)
