-- 新增功能:clean_source 逃生口(指定外部干净 .epub 作注入源,绕开脏/缺失的 .orig)。
local Sync = require("pickthought.sync")

local CH1_TEXT = "<html><body><p>春江潮水连海平,海上明月共潮生。</p></body></html>"
local CH2_TEXT = "<html><body><p>滟滟随波千万里,何处春江无月明。</p></body></html>"

-- 文件级变量:记录 copy_file 调用,避免覆盖闭包捕获不到 make_deps 的局部 calls。
local last_copy

local function make_deps(overrides)
    local calls = {saved = {}, injected = nil, progress = {}, renames = {}, removed = {}, copied = nil}
    local deps = {
        _calls = calls,
        doc_path = "/books/书.epub",
        book_id = "b001",
        file_exists = function() return false end,
        rename = function(a, b) calls.renames[#calls.renames + 1] = {a, b}; return true end,
        remove = function(p) calls.removed[#calls.removed + 1] = p; return true end,
        copy_file = function(a, b) calls.copied = {a, b}; return true end,
        api = {
            chapters = function()
                return {data = {
                    {chapterUid = 1, title = "第一章", chapterIdx = 1},
                    {chapterUid = 2, title = "第二章", chapterIdx = 2},
                }}
            end,
        },
        annotations = {
            fetch_chapter = function(_, _, uid)
                if tostring(uid) == "1" then
                    return {
                        underlines = {{range = "0-7", markText = "春江潮水连海平"}},
                        review_map = {["0-7"] = {{content = "好句", author = "甲"}}},
                        review_groups = {{range = "0-7", texts = {{content = "好句", author = "甲"}}}},
                        underline_count = 1, thought_count = 1, thought_entry_count = 1, errors = {},
                    }
                end
                return {underlines = {}, review_map = {}, review_groups = {},
                    underline_count = 0, thought_count = 0, thought_entry_count = 0, errors = {}}
            end,
        },
        load_meta = function(p)
            calls.meta_path = p
            return {spine = {{href = "OEBPS/c1.xhtml"}, {href = "OEBPS/c2.xhtml"}}, has = {}}
        end,
        read_text = function(_, href)
            return href == "OEBPS/c1.xhtml" and CH1_TEXT or CH2_TEXT
        end,
        save_thoughts = function(book_id, uid, groups)
            calls.saved[#calls.saved + 1] = {book_id = book_id, uid = tostring(uid), groups = groups}
            return #groups
        end,
        inject = function(src, book_id, mapped, dest, options)
            calls.injected = {src = src, book_id = book_id, mapped = mapped,
                dest = dest, options = options}
            return {injected = #mapped, marks = #mapped,
                unmatched = {}, quote_aligned = #mapped, dropped = 0,
                underlines_resolved = #mapped, thoughts_linked = 1,
                thoughts_linked_by_uid = {["1"] = 1},
                merges = {{uid = "1", from = "2-5", into = "0-7"}}}
        end,
        merge_thoughts = function(book_id, uid, from, into)
            calls.merged = {book_id = book_id, uid = tostring(uid), from = from, into = into}
            return true
        end,
        progress = function(phase, i, n, text)
            calls.progress[#calls.progress + 1] = {phase = phase, i = i, n = n, text = text}
            return true
        end,
    }
    for k, v in pairs(overrides or {}) do deps[k] = v end
    return deps, calls
end

T.case("clean_source 全量重建从外部干净源注入(绕开脏 .orig)", function()
    local EpubInject = require("pickthought.epub_inject")
    local deps, calls = make_deps({
        clean_source = "/clean/原书.epub",
        file_exists = function(p) return p == "/clean/原书.epub" end,
        load_meta = function(p)
            if p == "/clean/原书.epub" then
                return {spine = {{href = "OEBPS/c1.xhtml"}, {href = "OEBPS/c2.xhtml"}}, has = {}}
            end
            -- doc_path 当前是脏注入版
            return {spine = {{href = "OEBPS/c1.xhtml"}, {href = "OEBPS/c2.xhtml"}},
                has = {[EpubInject.MARKER] = true}}
        end,
    })
    local report, err = Sync.run(deps)
    T.ok(report, "应成功: " .. tostring(err))
    T.eq(calls.injected.src, "/clean/原书.epub", "从干净源注入")
    T.eq(report.clean_source, "/clean/原书.epub", "report 记录干净源")
    T.eq(report.dest, "/books/书.epub", "dest 仍是书架路径")
    T.eq(report.backup, "/books/书.epub.orig", "备份路径")
    T.ok(calls.copied ~= nil, "干净源应固化到 .orig")
    T.eq(calls.copied[1], "/clean/原书.epub", "copy 源为干净源")
    T.eq(calls.copied[2], "/books/书.epub.orig", "copy 目标为 .orig")
    T.eq(#calls.renames, 2, "两次换位:脏版暂存 .old + 注入版顶上原路径")
    T.eq(calls.renames[1][1], "/books/书.epub", "脏注入版先让位")
    T.eq(calls.renames[1][2], "/books/书.epub.old", "暂存为 .old")
    T.eq(calls.renames[2][1], "/books/书.epub.pickthought-new", "注入版")
    T.eq(calls.renames[2][2], "/books/书.epub", "顶上原路径")
end)

T.case("clean_source 不存在 → 报错", function()
    local deps = make_deps({clean_source = "/nope.epub", file_exists = function() return false end})
    local report, err = Sync.run(deps)
    T.ok(report == nil and tostring(err):find("干净源不存在", 1, true), "报错: " .. tostring(err))
    -- injected 在调用方是共享闭包,这里用 report==nil 已足够证明未注入
end)

T.case("clean_source 本身是注入版 → 报错", function()
    local EpubInject = require("pickthought.epub_inject")
    local deps = make_deps({
        clean_source = "/clean/原书.epub",
        file_exists = function(p) return p == "/clean/原书.epub" end,
        load_meta = function(p)
            if p == "/clean/原书.epub" then
                return {spine = {}, has = {[EpubInject.MARKER] = true}}
            end
            return {spine = {}, has = {}}
        end,
    })
    local report, err = Sync.run(deps)
    T.ok(report == nil and tostring(err):find("干净源本身已是注入版", 1, true), "报错: " .. tostring(err))
end)

T.case("clean_source 固化 .orig 失败 → 回滚恢复原注入版", function()
    -- 修复后:脏 doc_path 已暂存为 .old,固化失败时回滚 .old → doc_path,
    -- 保住用户当前书,不丢失数据(不再是"注入版已生成但 .orig 未刷新"的半成品)。
    local EpubInject = require("pickthought.epub_inject")
    local deps, calls = make_deps({
        clean_source = "/clean/原书.epub",
        file_exists = function(p) return p == "/clean/原书.epub" end,
        load_meta = function(p)
            if p == "/clean/原书.epub" then
                return {spine = {{href = "OEBPS/c1.xhtml"}, {href = "OEBPS/c2.xhtml"}}, has = {}}
            end
            return {spine = {{href = "OEBPS/c1.xhtml"}, {href = "OEBPS/c2.xhtml"}},
                has = {[EpubInject.MARKER] = true}}
        end,
        copy_file = function(a, b) last_copy = {a, b}; return nil end,
    })
    local report, err = Sync.run(deps)
    T.ok(report == nil, "应失败(固化失败)")
    T.ok(tostring(err):find("已恢复原注入版", 1, true), "报错提示已恢复: " .. tostring(err))
    local staged, rolled = false, false
    for _, r in ipairs(calls.renames) do
        if r[1] == "/books/书.epub" and r[2] == "/books/书.epub.old" then staged = true end
        if r[1] == "/books/书.epub.old" and r[2] == "/books/书.epub" then rolled = true end
    end
    T.ok(staged, "脏注入版先暂存为 .old")
    T.ok(rolled, "固化失败回滚 .old → doc_path")
    T.ok(last_copy ~= nil, "复制被尝试")
end)

T.case("clean_source 重建:脏 doc_path 先让位,swap 不踩已存在目标", function()
    -- 复现设备端 rename 语义:目标已存在时 rename 失败(不覆盖)。
    -- 旧实现未把脏 doc_path 移开,会导致最终 swap(temp_dest→doc_path)失败、重注静默失败;
    -- 修复后脏 doc_path 先暂存为 .old 让出原路径,swap 才能成功。
    local EpubInject = require("pickthought.epub_inject")
    local existing = {["/books/书.epub"] = true, ["/clean/原书.epub"] = true}
    local deps, calls = make_deps({
        clean_source = "/clean/原书.epub",
        file_exists = function(p) return existing[p] == true end,
        load_meta = function(p)
            if p == "/clean/原书.epub" then
                return {spine = {{href = "OEBPS/c1.xhtml"}, {href = "OEBPS/c2.xhtml"}}, has = {}}
            end
            return {spine = {{href = "OEBPS/c1.xhtml"}, {href = "OEBPS/c2.xhtml"}},
                has = {[EpubInject.MARKER] = true}}
        end,
    })
    -- 模拟设备端 rename 语义:目标已存在时 rename 失败(不覆盖),并记录调用。
    deps.rename = function(a, b)
        calls.renames[#calls.renames + 1] = {a, b}
        if existing[b] then return false, "目标已存在" end
        existing[a] = nil; existing[b] = true
        return true
    end
    deps.remove = function(p)
        existing[p] = nil; calls.removed[#calls.removed + 1] = p; return true
    end
    local report, err = Sync.run(deps)
    T.ok(report, "脏 doc_path 已被 .old 暂存,swap 应成功: " .. tostring(err))
    local staged = false
    for _, r in ipairs(calls.renames) do
        if r[1] == "/books/书.epub" and r[2] == "/books/书.epub.old" then staged = true end
    end
    T.ok(staged, "脏注入版先暂存为 .old(让出原路径)")
    T.ok(#calls.removed >= 1, "应清理暂存的 .old")
    T.eq(report.dest, "/books/书.epub", "dest 仍是书架路径")
    T.eq(report.backup, "/books/书.epub.orig", "备份路径")
end)

T.case("clean_source 与 doc_path 相同 → 退回既有逻辑", function()
    local deps, calls = make_deps({
        clean_source = "/books/书.epub",
        file_exists = function() return false end,
    })
    local report, err = Sync.run(deps)
    T.ok(report, "应成功: " .. tostring(err))
    T.eq(calls.injected.src, "/books/书.epub", "源仍是原书")
    T.eq(calls.copied, nil, "未触发固化 .orig")
end)

T.case("clean_source 与 backup 相同且干净 → 走既有 .orig 逻辑", function()
    local deps, calls = make_deps({
        clean_source = "/books/书.epub.orig",
        file_exists = function(p) return p == "/books/书.epub.orig" end,
        load_meta = function(p)
            if p == "/books/书.epub.orig" then
                return {spine = {{href = "OEBPS/c1.xhtml"}, {href = "OEBPS/c2.xhtml"}}, has = {}}
            end
            local EpubInject = require("pickthought.epub_inject")
            return {spine = {{href = "OEBPS/c1.xhtml"}, {href = "OEBPS/c2.xhtml"}},
                has = {[EpubInject.MARKER] = true}}
        end,
    })
    local report, err = Sync.run(deps)
    T.ok(report, "应成功: " .. tostring(err))
    T.eq(calls.injected.src, "/books/书.epub.orig", "源是 .orig(既有逻辑)")
    T.eq(calls.copied, nil, "未重复固化")
end)
