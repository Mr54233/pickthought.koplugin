-- 新增功能:clean_source 逃生口(指定外部干净 .epub 作注入源,绕开脏/缺失的 .orig)。
local Sync = require("pickthought.sync")
local U = require("pickthought.util")

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

T.case("clean_source 固化 .orig 失败且回滚失败 → 明确告知 .old 位置(不谎称已恢复)", function()
    -- 复现作者场景:P1#2 —— 固化失败 + 回滚 rename 也失败,函数不得谎称"已恢复原注入版",
    -- 必须明确告知 .old 才是当前实际文件,保留作人工恢复入口。
    local EpubInject = require("pickthought.epub_inject")
    local rec = {renames = {}}  -- 预声明稳定表,避免闭包捕获尚未赋值的 calls 局部
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
        copy_file = function(a, b) last_copy = {a, b}; return nil end,  -- 固化失败
        rename = function(a, b)
            rec.renames[#rec.renames + 1] = {a, b}
            -- 回滚 rename(.old → doc_path) 失败(模拟文件占用/权限)
            if a == "/books/书.epub.old" and b == "/books/书.epub" then
                return false, "回滚 rename 失败(模拟)"
            end
            return true
        end,
    })
    local report, err = Sync.run(deps)
    T.ok(report == nil, "应失败")
    local e = tostring(err)
    T.ok(e:find("无法恢复当前注入版", 1, true) or e:find("手动", 1, true),
        "应明确提示未恢复且需手动: " .. e)
    T.ok(not e:find("已恢复原注入版", 1, true), "不得谎称已恢复原注入版: " .. e)
end)

T.case("clean_source 重建:swap 失败且回滚失败 → 明确告知实际位置", function()
    -- P1#2 —— 换位失败 + 回滚失败:doc_path 最终不存在、.old 仍残留,
    -- 函数必须如实说明 .old 位置,而非返回"已恢复"。
    local EpubInject = require("pickthought.epub_inject")
    local existing = {["/books/书.epub"] = true, ["/clean/原书.epub"] = true}
    local rec = {renames = {}, removed = {}}
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
        copy_file = function(a, b) last_copy = {a, b}; return true end,  -- 固化成功
        rename = function(a, b)
            rec.renames[#rec.renames + 1] = {a, b}
            if a == "/books/书.epub.pickthought-new" and b == "/books/书.epub" then
                return false, "swap 失败(模拟)"  -- 换位失败
            end
            if a == "/books/书.epub.old" and b == "/books/书.epub" then
                return false, "回滚失败(模拟)"  -- 回滚失败
            end
            if existing[b] then return false, "目标已存在" end
            existing[a] = nil; existing[b] = true; return true
        end,
        remove = function(p) existing[p] = nil; rec.removed[#rec.removed + 1] = p; return true end,
    })
    local report, err = Sync.run(deps)
    T.ok(report == nil, "应失败")
    local e = tostring(err)
    T.ok(e:find("暂存于", 1, true) or e:find("无法恢复", 1, true),
        "应明确提示 .old 实际位置: " .. e)
    T.ok(not e:find("已恢复原", 1, true), "不得谎称已恢复: " .. e)
end)

T.case("clean_source 重建:当前书是干净原书(未注入)→ 统一基线,原书保留为 .old 不丢", function()
    -- 作者意见 #4(2026-08-17):首次注入中途失败后当前书仍是干净原书(有章节缓存但无 MARKER),
    -- 此时若另一份 clean_source 版本不同,绝不能把当前书丢进 .orig 混入错误版本。
    -- 修复后采用"统一注入基线":干净源固化为 .orig(注入基线与源一致),
    -- 当前打开的干净原书暂存为 .old 保留——不销毁、不混入 .orig。
    local EpubInject = require("pickthought.epub_inject")
    local deps, calls = make_deps({
        clean_source = "/clean/原书.epub",
        file_exists = function(p) return p == "/clean/原书.epub" end,  -- .orig 不存在
        load_meta = function(p)
            if p == "/clean/原书.epub" then
                return {spine = {{href = "OEBPS/c1.xhtml"}, {href = "OEBPS/c2.xhtml"}}, has = {}}
            end
            -- doc_path 是干净原书(无 MARKER),但曾有章节缓存(首次注入失败场景)
            return {spine = {{href = "OEBPS/c1.xhtml"}, {href = "OEBPS/c2.xhtml"}}, has = {}}
        end,
    })
    local report, err = Sync.run(deps)
    T.ok(report, "应成功: " .. tostring(err))
    -- 干净源固化到 .orig(统一注入基线,与注入源一致)
    T.eq(calls.copied[1], "/clean/原书.epub", "copy 源为干净源")
    T.eq(calls.copied[2], "/books/书.epub.orig", "copy 目标为 .orig")
    -- 当前干净原书暂存为 .old 保留(不销毁、不混入 .orig)
    local staged_as_old, staged_as_orig = false, false
    for _, r in ipairs(calls.renames) do
        if r[1] == "/books/书.epub" and r[2] == "/books/书.epub.old" then staged_as_old = true end
        if r[1] == "/books/书.epub" and r[2] == "/books/书.epub.orig" then staged_as_orig = true end
    end
    T.ok(staged_as_old, "当前干净原书应暂存为 .old 保留(不销毁)")
    T.ok(not staged_as_orig, "当前干净原书不得直接当 .orig(避免版本不一致)")
    T.eq(report.dest, "/books/书.epub", "dest 仍是书架路径")
    T.eq(report.backup, "/books/书.epub.orig", "备份路径为干净源固化结果")
end)

T.case("U.copy_file_stream 流式复制(分块/进度/失败)", function()
    -- P1#1 —— 干净源复制必须分块读写(避免大书 OOM)并上报进度心跳,且源缺失要报错。
    local src = os.tmpname()
    local dst = os.tmpname()
    local f = io.open(src, "wb")
    local big = ("A"):rep(2500000)  -- 2.5MB > 1MB 分块,验证多次分块
    f:write(big); f:close()
    local progress_calls = 0
    local ok, e = U.copy_file_stream(src, dst, function() progress_calls = progress_calls + 1 end)
    T.ok(ok, "复制应成功: " .. tostring(e))
    local g = io.open(dst, "rb")
    local got = g:read("*a"); g:close()
    T.eq(#got, #big, "目标大小一致(未截断)")
    T.ok(got == big, "目标内容一致(未损坏)")
    T.ok(progress_calls > 1, "应多次上报进度(分块心跳),实际=" .. tostring(progress_calls))
    os.remove(src); os.remove(dst)
    -- 失败:源不存在
    local ok2, e2 = U.copy_file_stream(src .. ".nope", dst)
    T.ok(not ok2 and tostring(e2):find("源文件", 1, true), "源缺失应报错: " .. tostring(e2))
end)

T.case("clean_source 重建:启动前遗留 .old 应被清理,不阻塞重建", function()
    -- .old 遗留时的恢复行为:上一次被中断会留下 .old,本次重建应先用 remove 清掉它,
    -- 再暂存当前注入版为 .old,最终成功并清理,不残留。
    local EpubInject = require("pickthought.epub_inject")
    local existing = {["/books/书.epub"] = true, ["/clean/原书.epub"] = true,
        ["/books/书.epub.old"] = true}  -- 模拟上轮遗留的 .old
    local rec = {renames = {}, removed = {}}
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
        rename = function(a, b)
            rec.renames[#rec.renames + 1] = {a, b}
            if existing[b] then return false, "目标已存在" end
            existing[a] = nil; existing[b] = true; return true
        end,
        remove = function(p) existing[p] = nil; rec.removed[#rec.removed + 1] = p; return true end,
    })
    local report, err = Sync.run(deps)
    T.ok(report, "遗留 .old 应被清理后成功重建: " .. tostring(err))
    local removed_old = false
    for _, p in ipairs(rec.removed) do
        if p == "/books/书.epub.old" then removed_old = true end
    end
    T.ok(removed_old, "启动前应清理遗留的 .old")
end)

T.case("clean_source:当前书存在但解析失败(损坏)→ 中止且不改动任何文件", function()
    -- P1#2, 2026-08-15 二轮 —— 当前 EPUB 存在但 load_meta 失败(损坏),
    -- 若继续会把它当"干净原书" rename 成 .orig 销毁。必须在 rename/copy 前中止,零改动。
    local deps, calls = make_deps({
        clean_source = "/clean/原书.epub",
        file_exists = function(p)
            return p == "/clean/原书.epub" or p == "/books/书.epub"  -- doc_path 存在但损坏
        end,
        load_meta = function(p)
            if p == "/clean/原书.epub" then
                return {spine = {{href = "OEBPS/c1.xhtml"}}, has = {}}
            end
            return nil, "EPUB 损坏:无法解析"  -- doc_path 解析失败
        end,
    })
    local report, err = Sync.run(deps)
    T.ok(report == nil, "应失败(损坏中止)")
    T.ok(tostring(err):find("已损坏", 1, true) or tostring(err):find("无法解析", 1, true),
        "报错应指明损坏: " .. tostring(err))
    T.eq(#calls.renames, 0, "任何 rename 都不应发生(doc_path/.orig/.old 均未被改动)")
    T.eq(calls.copied, nil, "不应触发固化")
end)

T.case("U.copy_file_stream:替换失败保留旧备份并清理临时文件", function()
    -- P1#3, 2026-08-15 二轮 —— 最终替换目标失败时,旧备份(.prev→b 还原)完好,临时文件清理。
    local src = os.tmpname(); local dst = os.tmpname()
    local f = io.open(src, "wb"); f:write(("A"):rep(1000)); f:close()
    local g = io.open(dst, "wb"); g:write("OLD-BACKUP"); g:close()  -- 预先存在的可用备份
    local real_rename = os.rename
    os.rename = function(a, b)
        if a == dst .. ".copy.tmp" and b == dst then
            return nil, "模拟替换失败"  -- 仅阻断最终 tmp→b 替换
        end
        return real_rename(a, b)
    end
    local ok, e = U.copy_file_stream(src, dst)
    os.rename = real_rename
    T.ok(not ok and tostring(e):find("替换为目标失败", 1, true), "应报替换失败: " .. tostring(e))
    local h = io.open(dst, "rb"); local got = h:read("*a"); h:close()
    T.eq(got, "OLD-BACKUP", "旧备份内容未被覆盖/丢失(.prev 已还原)")
    T.ok(not U.file_exists(dst .. ".copy.tmp"), "临时文件应已清理")
    T.ok(not U.file_exists(dst .. ".prev"), "无残留 .prev")
    os.remove(src); os.remove(dst)
end)

T.case("U.copy_file_stream:用户取消 → 丢弃临时副本,保留旧备份", function()
    -- P1#3, 2026-08-15 二轮 —— on_progress 返回 false 视为取消,丢弃临时副本,旧 b 不动。
    local src = os.tmpname(); local dst = os.tmpname()
    local f = io.open(src, "wb"); f:write(("A"):rep(2000000)); f:close()
    local g = io.open(dst, "wb"); g:write("OLD-BACKUP"); g:close()
    local cancelled_called = false
    local ok, e, status = U.copy_file_stream(src, dst, function(done)
        if done > 500000 and not cancelled_called then
            cancelled_called = true
            return false  -- 用户取消
        end
        return true
    end)
    T.ok(not ok and status == "cancelled", "应返回取消状态: " .. tostring(e))
    local h = io.open(dst, "rb"); local got = h:read("*a"); h:close()
    T.eq(got, "OLD-BACKUP", "旧备份未被改动")
    T.ok(not U.file_exists(dst .. ".copy.tmp"), "临时副本应已清理")
    os.remove(src); os.remove(dst)
end)

T.case("clean_source 重建:固化 .orig 时用户取消(默认复制路径)→ 中止且不替换原书", function()
    -- 作者意见 #1(2026-08-17):复制阶段的取消结果须从进度回调继续向上传递,
    -- 用户取消后不得继续完成 .orig 固化与原书替换。此处令 copy_file 直接返回
    -- 默认 U.copy_file_stream 在复制中途被取消的契约三元组
    -- (nil,"已取消复制","cancelled")——底层 progress→on_progress→copy_file_stream 的取消机制
    -- 已由 "U.copy_file_stream:用户取消" 用例单独覆盖;本用例验证 Sync.run 收到该取消状态后
    -- 正确中止:不继续 .orig 固化、不执行最终 swap、并把 .old 回滚为 doc_path。
    local EpubInject = require("pickthought.epub_inject")
    local deps, calls = make_deps({
        clean_source = "/clean/原书.epub",
        file_exists = function(p) return p == "/clean/原书.epub" end,
        load_meta = function(p)
            if p == "/clean/原书.epub" then
                return {spine = {{href = "OEBPS/c1.xhtml"}}, has = {}}
            end
            return {spine = {{href = "OEBPS/c1.xhtml"}}, has = {[EpubInject.MARKER] = true}}
        end,
        -- 模拟默认 copy_file 包装器在复制中途被取消的返回契约。
        copy_file = function(a, b)
            last_copy = {a, b}
            return nil, "已取消复制", "cancelled"
        end,
    })
    local report, err = Sync.run(deps)
    T.ok(report == nil, "应失败(用户取消)")
    local e = tostring(err)
    T.ok(e:find("取消", 1, true), "报错应指明取消: " .. e)
    -- 关键:取消后不得继续完成 .orig 固化与原书替换(最终 swap)。
    local swapped = false
    for _, r in ipairs(calls.renames) do
        if r[1] == "/books/书.epub.pickthought-new" and r[2] == "/books/书.epub" then swapped = true end
    end
    T.ok(not swapped, "取消后不得执行最终 swap(原书替换)")
    -- 当前注入版(.old)应被回滚为 doc_path,原书不被破坏。
    local rolled = false
    for _, r in ipairs(calls.renames) do
        if r[1] == "/books/书.epub.old" and r[2] == "/books/书.epub" then rolled = true end
    end
    T.ok(rolled, "取消后应将 .old 回滚为 doc_path(恢复原注入版)")
    T.ok(last_copy ~= nil, "复制被尝试(默认复制路径)")
end)

T.case("U.content_fingerprint:同体积不同内容 → 不同指纹", function()
    -- P2, 2026-08-15 二轮 —— 内容指纹用于区分"同体积不同内容"的 EPUB,避免复用错误映射。
    local a = os.tmpname(); local b = os.tmpname()
    local fa = io.open(a, "wb"); fa:write(("X"):rep(1000)); fa:close()
    local fb = io.open(b, "wb"); fb:write(("Y"):rep(1000)); fb:close()  -- 同大小不同内容
    local fp_a = U.content_fingerprint(a)
    local fp_b = U.content_fingerprint(b)
    T.ok(fp_a and fp_b, "应得到指纹")
    T.ok(fp_a ~= fp_b, "同体积不同内容指纹应不同: " .. tostring(fp_a) .. " vs " .. tostring(fp_b))
    T.eq(U.file_size(a), U.file_size(b), "大小相同(排除仅靠大小区分)")
    os.remove(a); os.remove(b)
end)

T.case("U.content_fingerprint:损坏/缺失文件返回 nil", function()
    local fp = U.content_fingerprint("/no/such/file.epub")
    T.ok(fp == nil, "缺失文件应返回 nil(调用方回退默认指纹)")
end)
