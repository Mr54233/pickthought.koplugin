T.case("stub 环境能加载现有纯 Lua 模块", function()
    local U = require("pickthought.util")
    T.eq(U.trim("  x  "), "x", "util.trim")
    local Thoughts = require("pickthought.thoughts")
    T.eq(Thoughts.href("b1", "c2", "3-9"), "#pickthought-6231.6332.332d39", "thoughts.href hex(专属前缀,与原版撷思不冲突)")
    local Annotations = require("pickthought.annotations")
    local html = "<html><body><p>春江潮水连海平,海上明月共潮生。</p></body></html>"
    local data = {
        book_id = "b1", chapter_uid = "c2",
        underlines = {{range = "0-6", markText = "春江潮水连海平"}},
        review_map = {["0-6"] = {{content = "好句", author = "我"}}},
        underline_count = 1, thought_count = 1, errors = {},
    }
    local rendered = Annotations:new(nil):apply(html, data)
    T.ok(rendered:find("pickthought-link", 1, true), "注入引擎离线可用,应产出想法锚点")
end)

T.case("Thoughts.merge_rows 合并重叠划线的想法组", function()
    local Thoughts = require("pickthought.thoughts")
    local rows = {
        {range = "0-7", texts = {{content = "甲说", author = "甲", review_id = "r1"}}},
        {range = "2-5", texts = {{content = "乙说", author = "乙", review_id = "r2"},
                                 {content = "甲说", author = "甲", review_id = "r1"}}},
    }
    T.ok(Thoughts.merge_rows(rows, "2-5", "0-7"), "合并发生")
    T.eq(#rows[1].texts, 2, "去重后并入 1 条(r1 已存在不重复)")
    T.eq(rows[1].texts[2].review_id, "r2", "乙的想法进入存活组")
    T.ok(not Thoughts.merge_rows(rows, "2-5", "0-7"), "再次合并无新增")

    local lone = {{range = "9-12", texts = {{content = "孤想法", review_id = "r9"}}}}
    T.ok(Thoughts.merge_rows(lone, "9-12", "0-7"), "目标组缺失时重新锚定")
    T.eq(lone[1].range, "0-7", "组改挂到存活锚点的 range")
end)

T.case("atomic_write 可覆盖已存在文件", function()
    local U = require("pickthought.util")
    local p = "tests/.tmp_atomic_test"
    T.ok(U.atomic_write(p, "v1", true), "首写")
    T.ok(U.atomic_write(p, "v2", true), "覆盖写(Windows rename 需删目标重试)")
    T.eq(U.read_file(p, true), "v2", "内容为新值")
    os.remove(p)
end)

T.case("archiver mock 与真实 API 同语义", function()
    local Arc = STUBS.archiver_mock({{path = "mimetype", content = "application/epub+zip"}})
    local r = Arc.Reader:new()
    T.ok(r:open("fake.epub"), "open 返回 true")
    T.eq(r:seek("mimetype"), nil, "未迭代前 seek 必须返回 nil(真实 archiver 语义)")
    T.eq(r:extractToMemory("mimetype"), nil, "未迭代前 extract 必须返回 nil")
    for _ in r:iterate() do end
    T.eq(r:extractToMemory("mimetype"), "application/epub+zip", "迭代后可按名提取")
    local w = Arc.Writer:new{}
    T.ok(w:open("out.epub", "epub"), "writer open 返回 true")
    T.ok(w:setZipCompression("store"), "setZipCompression 返回 true")
    T.ok(w:addFileFromMemory("mimetype", "application/epub+zip", 0), "addFileFromMemory 成功返回 true")
    T.eq(STUBS.written(w)[1].compression, "store", "writer 记录压缩方式")
    T.eq(Arc._last_writer, w, "_last_writer 记录")

    local FailArc = STUBS.archiver_mock({}, {fail_write_path = "x"})
    local fw = FailArc.Writer:new{}
    fw:open("out.epub", "epub")
    T.eq(fw:addFileFromMemory("x", "data", 0), nil, "写失败返回 nil")
    T.ok(fw.err ~= nil, "写失败置 err")
end)
