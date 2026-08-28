local EpubReader = require("pickthought.epub_reader")

local CONTAINER = [[<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>]]

local OPF = [[<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0">
  <metadata><dc:title xmlns:dc="http://purl.org/dc/elements/1.1/">测试书</dc:title></metadata>
  <manifest>
    <item href="Text/ch%201.xhtml" id="c1" media-type="application/xhtml+xml"/>
    <item id="c2" media-type="application/xhtml+xml" href="Text/../Text/ch2.xhtml"/>
    <item id="css" href="style.css" media-type="text/css"/>
  </manifest>
  <spine><itemref idref="c1"/><itemref idref="c2" linear="no"/></spine>
</package>]]

local function fake_book()
    return STUBS.archiver_mock({
        {path = "mimetype", content = "application/epub+zip"},
        {path = "META-INF/container.xml", content = CONTAINER},
        {path = "OEBPS/content.opf", content = OPF},
        {path = "OEBPS/Text/ch 1.xhtml", content = "<html><head></head><body>一</body></html>"},
        {path = "OEBPS/Text/ch2.xhtml", content = "<html><head></head><body>二</body></html>"},
        {path = "OEBPS/style.css", content = "body{}"},
    })
end

T.case("resolve 路径规范化", function()
    T.eq(EpubReader.resolve("OEBPS", "Text/ch%201.xhtml"), "OEBPS/Text/ch 1.xhtml", "百分号解码+拼接")
    T.eq(EpubReader.resolve("OEBPS", "Text/../Text/ch2.xhtml"), "OEBPS/Text/ch2.xhtml", "../ 折叠")
    T.eq(EpubReader.resolve("", "ch.xhtml"), "ch.xhtml", "根目录 OPF")
    T.eq(EpubReader.resolve("OEBPS", "/abs/ch.xhtml"), "abs/ch.xhtml", "绝对路径去除首斜杠")
    T.eq(EpubReader.resolve("OEBPS", "a&amp;b.xhtml"), "OEBPS/a&b.xhtml", "XML 实体解码")
    T.eq(EpubReader.resolve("OEBPS", "ch+1.xhtml"), "OEBPS/ch+1.xhtml", "+ 是路径字面量,不转空格")
end)

T.case("命名空间前缀的 OPF/container 也能解析", function()
    local ns_container = [[<odc:container xmlns:odc="urn:oasis:names:tc:opendocument:xmlns:container">
<odc:rootfiles><odc:rootfile full-path="content.opf"/></odc:rootfiles></odc:container>]]
    local ns_opf = [[<opf:package xmlns:opf="http://www.idpf.org/2007/opf"><opf:manifest>
<opf:item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
</opf:manifest><opf:spine><opf:itemref idref="c1"/></opf:spine></opf:package>]]
    local book = STUBS.archiver_mock({
        {path = "mimetype", content = "application/epub+zip"},
        {path = "META-INF/container.xml", content = ns_container},
        {path = "content.opf", content = ns_opf},
        {path = "ch1.xhtml", content = "<html><body>一</body></html>"},
    })
    local meta, err = EpubReader.load("ns.epub", book)
    T.ok(meta, "带前缀应解析成功: " .. tostring(err))
    T.eq(meta.opf_dir, "", "根目录 OPF")
    T.eq(#meta.spine, 1, "spine 解析")
    T.eq(meta.spine[1].href, "ch1.xhtml", "前缀 itemref/item 均命中")
end)

T.case("zip 重复条目在 names 中去重", function()
    local book = STUBS.archiver_mock({
        {path = "mimetype", content = "application/epub+zip"},
        {path = "META-INF/container.xml", content = CONTAINER},
        {path = "OEBPS/content.opf", content = OPF},
        {path = "OEBPS/Text/ch 1.xhtml", content = "<html/>"},
        {path = "OEBPS/Text/ch2.xhtml", content = "<html/>"},
        {path = "OEBPS/Text/ch2.xhtml", content = "<html>dup</html>"},
    })
    local meta = EpubReader.load("dup.epub", book)
    T.eq(#meta.names, 5, "重复路径只入列一次")
end)

T.case("load 解析 container/OPF/spine", function()
    local meta, err = EpubReader.load("fake.epub", fake_book())
    T.ok(meta, "load 应成功: " .. tostring(err))
    T.eq(meta.opf_path, "OEBPS/content.opf", "opf_path")
    T.eq(meta.opf_dir, "OEBPS", "opf_dir")
    T.eq(#meta.names, 6, "全部条目入列")
    T.ok(meta.has["OEBPS/style.css"], "has 索引")
    T.eq(#meta.spine, 2, "spine 数量")
    T.eq(meta.spine[1].href, "OEBPS/Text/ch 1.xhtml", "spine1 href 解析(属性乱序+转义)")
    T.eq(meta.spine[2].href, "OEBPS/Text/ch2.xhtml", "spine2 href 规范化")
    T.eq(meta.spine[1].media_type, "application/xhtml+xml", "media_type")
end)

T.case("read 取单条目", function()
    local meta = EpubReader.load("fake.epub", fake_book())
    local body = EpubReader.read(meta, "OEBPS/Text/ch2.xhtml", fake_book())
    T.ok(body and body:find("二", 1, true), "read 内容")
    local missing, err = EpubReader.read(meta, "不存在", fake_book())
    T.ok(missing == nil and err ~= nil, "缺失条目返回 nil, err")
end)

T.case("each_spine 单次打开流式读取全部正文", function()
    local book = fake_book()
    local meta = EpubReader.load("fake.epub", book)
    local opened_after_load = book._reader_new_count
    local rows = {}
    local ok, err = EpubReader.each_spine(meta, function(item, content, read_err, index)
        rows[#rows + 1] = {href = item.href, content = content, err = read_err, index = index}
    end, book)
    T.ok(ok, "流式读取成功: " .. tostring(err))
    T.eq(book._reader_new_count - opened_after_load, 1, "全部 spine 只新建一个 Reader")
    T.eq(#rows, 2, "读取两个 spine")
    T.eq(rows[1].href, "OEBPS/Text/ch 1.xhtml", "第一个正文")
    T.eq(rows[1].index, 1, "保留 spine 序号")
    T.ok(rows[2].content:find("二", 1, true), "第二个正文内容")
end)

T.case("each_spine 回调取消后停止读取并关闭 Reader", function()
    local book = fake_book()
    local meta = EpubReader.load("cancel.epub", book)
    local calls = 0
    local ok, err = EpubReader.each_spine(meta, function()
        calls = calls + 1
        return false
    end, book)
    T.eq(ok, false, "取消应返回 false")
    T.eq(err, "已取消", "取消错误")
    T.eq(calls, 1, "取消后只回调一个正文")
    T.eq(book._reader_new_count, 2, "取消后 Reader 已关闭且没有重复打开")
end)

T.case("坏包报错", function()
    local no_container = STUBS.archiver_mock({{path = "mimetype", content = "application/epub+zip"}})
    local meta, err = EpubReader.load("bad.epub", no_container)
    T.ok(meta == nil and tostring(err):find("container", 1, true), "缺 container.xml 报中文错")
end)
