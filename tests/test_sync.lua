local Sync = require("pickthought.sync")
local U = require("pickthought.util")

local CH1_TEXT = "<html><body><p>春江潮水连海平,海上明月共潮生。</p></body></html>"
local CH2_TEXT = "<html><body><p>滟滟随波千万里,何处春江无月明。</p></body></html>"

-- 测试环境 lfs 是 no-op 桩,无法真正建目录/写文件,导致 U.atomic_write 静默失败,
-- 使 map.json 与 spine 缓存无法持久化(第二批被迫冷模式重读)。用内存 FS 替身
-- 临时替换 U 的磁盘函数,验证完立即还原,不影响其他用例。
local function with_memfs(fn)
    local saved = {}
    for _, k in ipairs({"mkdir", "read_file", "file_exists", "atomic_write", "remove_tree", "list"}) do
        saved[k] = U[k]
    end
    local fs = {}
    U.mkdir = function(p) fs[tostring(p)] = fs[tostring(p)] or true; return true end
    U.file_exists = function(p) return fs[tostring(p)] ~= nil end
    U.read_file = function(p) local c = fs[tostring(p)]; return c == true and nil or c end
    U.atomic_write = function(p, d) fs[tostring(p)] = d; return true end
    U.remove_tree = function(p)
        local pk = tostring(p)
        for k in pairs(fs) do
            if k == pk or k:sub(1, #pk + 1) == pk .. "/" then fs[k] = nil end
        end
        return true
    end
    U.list = function(p)
        local o = {}; local pre = tostring(p) .. "/"
        for k in pairs(fs) do if k:sub(1, #pre) == pre then o[#o + 1] = k end end
        return o
    end
    local ok, err = xpcall(fn, debug.traceback, fs)
    for k, v in pairs(saved) do U[k] = v end
    if not ok then error(err, 0) end
end

local function make_deps(overrides)
    local calls = {saved = {}, injected = nil, progress = {}, renames = {}, removed = {}}
    local deps = {
        _calls = calls,
        doc_path = "/books/书.epub",
        book_id = "b001",
        file_exists = function() return false end,
        rename = function(a, b) calls.renames[#calls.renames + 1] = {a, b}; return true end,
        remove = function(p) calls.removed[#calls.removed + 1] = p; return true end,
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

T.case("同步全流程", function()
    local deps, calls = make_deps()
    local report, err = Sync.run(deps)
    T.ok(report, "应成功: " .. tostring(err))
    T.eq(report.chapters_total, 2, "章节总数")
    T.eq(report.chapters_with_data, 1, "有划线章节数")
    T.eq(report.injected, 1, "注入章节数")
    T.eq(report.thoughts_saved, 1, "想法缓存章节数")
    T.eq(report.dest, "/books/书.epub", "替换后 dest 就是原书路径")
    T.eq(report.backup, "/books/书.epub.orig", "备份路径")
    T.eq(calls.injected.src, "/books/书.epub", "首次从原书注入")
    T.eq(calls.injected.dest, "/books/书.epub.pickthought-new", "注入到中间文件")
    T.ok(type(calls.injected.options.meta) == "table", "复用已加载的 EPUB meta")
    T.eq(#calls.renames, 2, "两次换位")
    T.eq(calls.renames[1][1], "/books/书.epub", "原书让位")
    T.eq(calls.renames[1][2], "/books/书.epub.orig", "成为备份")
    T.eq(calls.renames[2][1], "/books/书.epub.pickthought-new", "注入版")
    T.eq(calls.renames[2][2], "/books/书.epub", "顶上原路径")
    T.eq(report.fetch_errors, 0, "无拉取错误")
    T.eq(report.total_underlines, 1, "拉取划线总数")
    T.eq(report.total_thought_entries, 1, "拉取想法总数")
    T.eq(report.underlines_injected, 1, "注入成功划线")
    T.eq(report.underlines_failed, 0, "注入失败划线")
    T.eq(report.thoughts_injected, 1, "注入成功想法")
    T.eq(report.thoughts_failed, 0, "注入失败想法")
    T.eq(report.batch_start, 1, "本批从第 1 章开始")
    T.eq(report.batch_end, 2, "本批处理到第 2 章")
    T.eq(report.chapters_processed, 2, "本批处理 2 章")
    T.eq(report.chapters_fetch_succeeded, 2, "两章划线请求均成功")
    T.eq(report.chapters_matched, 1, "匹配章数")
    T.eq(report.unmatched_underlines, 0, "未匹配无连带损失")
    T.eq(calls.merged.from, "2-5", "重叠想法合并被分发")
    T.eq(calls.merged.into, "0-7", "并入存活锚点")
    T.eq(#calls.saved, 1, "save_thoughts 调用一次")
    T.eq(calls.saved[1].uid, "1", "缓存第一章")
    T.eq(#calls.injected.mapped, 1, "注入一章")
    T.eq(calls.injected.mapped[1].href, "OEBPS/c1.xhtml", "映射到 c1")
    T.eq(calls.injected.mapped[1].chapter_uid, "1", "chapter_uid 传递")
    T.ok(#calls.progress >= 3, "进度回调发生")
end)

T.case("重同步从 .orig 干净备份注入", function()
    local deps, calls = make_deps({
        file_exists = function(p) return p == "/books/书.epub.orig" end,
    })
    local report, err = Sync.run(deps)
    T.ok(report, "应成功: " .. tostring(err))
    T.eq(calls.meta_path, "/books/书.epub.orig", "meta 读的是备份")
    T.eq(calls.injected.src, "/books/书.epub.orig", "从备份注入")
    T.eq(#calls.renames, 1, "只有注入版顶位一次")
    T.eq(calls.renames[1][2], "/books/书.epub", "顶上原路径")
    T.eq(report.dest, "/books/书.epub", "dest 仍是书架路径")
end)

T.case("想法缓存写入失败时停在当前章节", function()
    local deps, calls = make_deps({
        api = {chapters = function()
            return {data = {
                {chapterUid = 1, title = "第一章", chapterIdx = 1},
                {chapterUid = 2, title = "第二章", chapterIdx = 2},
            }}
        end},
        annotations = {
            fetch_chapter = function(_, _, uid)
                if tostring(uid) == "1" then
                    return {underlines = {{range = "0-7", markText = "春江潮水连海平"}},
                        review_map = {}, review_groups = {}, underline_count = 1,
                        thought_count = 0, thought_entry_count = 0, errors = {}}
                end
                return {underlines = {{range = "0-7", markText = "滟滟随波千万里"}},
                    review_map = {["0-7"] = {{content = "想法"}}},
                    review_groups = {{range = "0-7", texts = {{content = "想法"}}}},
                    underline_count = 1, thought_count = 1, thought_entry_count = 1, errors = {}}
            end,
        },
        save_thoughts = function(_, uid)
            if tostring(uid) == "2" then return nil, "磁盘满" end
            return true
        end,
    })
    local report, err = Sync.run(deps)
    T.ok(report, "前一章成功时应提交部分结果: " .. tostring(err))
    T.eq(report.save_failures, 1, "记录想法缓存失败章节")
    T.eq(report.next_index, 2, "保存失败章节不能推进游标")
    T.eq(report.chapters_pending, 1, "保存失败章节计入待处理")
    T.eq(#calls.injected.mapped, 1, "只注入保存成功的前一章")
end)

T.case("增量同步保留干净备份并原子替换当前注入版", function()
    local EpubInject = require("pickthought.epub_inject")
    local meta_paths = {}
    local deps, calls = make_deps({
        append = true,
        file_exists = function(p) return p == "/books/书.epub.orig" end,
        load_meta = function(p)
            meta_paths[#meta_paths + 1] = p
            local has = {}
            if p == "/books/书.epub" then has[EpubInject.MARKER] = true end
            return {path = p, spine = {{href = "OEBPS/c1.xhtml"},
                {href = "OEBPS/c2.xhtml"}}, has = has}
        end,
    })
    local report, err = Sync.run(deps)
    T.ok(report, "应成功: " .. tostring(err))
    T.eq(calls.injected.src, "/books/书.epub", "从当前注入版继续追加")
    T.eq(calls.injected.options.append, true, "注入器使用追加模式")
    T.eq(#calls.renames, 1, "只换入新版本,不移动当前书到备份")
    T.eq(calls.renames[1][1], "/books/书.epub.pickthought-new", "新版本原子换位")
    T.eq(calls.renames[1][2], "/books/书.epub", "覆盖当前注入版")
    T.eq(#calls.removed, 0, "成功路径不删除当前书或备份")
    T.ok(meta_paths[#meta_paths] == "/books/书.epub.orig", "映射读取干净备份")
end)

T.case("增量同步拒绝已污染的原书备份", function()
    local EpubInject = require("pickthought.epub_inject")
    local deps, calls = make_deps({
        append = true,
        file_exists = function(p) return p == "/books/书.epub.orig" end,
        load_meta = function(p)
            local has = {[EpubInject.MARKER] = true}
            return {path = p, spine = {{href = "OEBPS/c1.xhtml"}}, has = has}
        end,
    })
    local report, err = Sync.run(deps)
    T.ok(report == nil and tostring(err):find("备份已被注入", 1, true),
        "污染备份必须拒绝: " .. tostring(err))
    T.eq(calls.injected, nil, "拒绝后不得生成新 EPUB")
    T.eq(#calls.renames, 0, "拒绝后不得换位")
end)

T.case("增量换位失败保留当前书和干净备份", function()
    local EpubInject = require("pickthought.epub_inject")
    local deps, calls = make_deps({
        append = true,
        file_exists = function(p)
            return p == "/books/书.epub" or p == "/books/书.epub.orig"
        end,
        load_meta = function(p)
            local has = {}
            if p == "/books/书.epub" then has[EpubInject.MARKER] = true end
            return {path = p, spine = {{href = "OEBPS/c1.xhtml"},
                {href = "OEBPS/c2.xhtml"}}, has = has}
        end,
    })
    deps.rename = function(a, b)
        calls.renames[#calls.renames + 1] = {a, b}
        return nil, "busy"
    end
    local report, err = Sync.run(deps)
    T.ok(report == nil and tostring(err):find("无法替换原书", 1, true),
        "换位失败应报错: " .. tostring(err))
    T.eq(#calls.renames, 1, "只尝试新版本换位一次")
    T.eq(#calls.removed, 1, "只清理未换入的临时文件")
    T.eq(calls.removed[1], "/books/书.epub.pickthought-new", "当前书与备份均不删除")
end)

T.case("已注入但无备份时拒绝并说明", function()
    local EpubInject = require("pickthought.epub_inject")
    local deps = make_deps({
        load_meta = function()
            return {spine = {{href = "x"}}, has = {[EpubInject.MARKER] = true}}
        end,
    })
    local report, err = Sync.run(deps)
    T.ok(report == nil and tostring(err):find("找不到原书备份", 1, true), "报错: " .. tostring(err))
end)

T.case("进度回调返回 false 即取消", function()
    local deps, calls = make_deps({
        progress = function(phase) return phase ~= "fetch" end,
    })
    local report, err = Sync.run(deps)
    T.ok(report == nil and tostring(err):find("取消", 1, true), "取消: " .. tostring(err))
    T.eq(calls.injected, nil, "取消后不得注入")
end)

T.case("全书无划线", function()
    local deps = make_deps({
        annotations = {
            fetch_chapter = function()
                return {underlines = {}, review_map = {}, review_groups = {},
                    underline_count = 0, thought_count = 0, thought_entry_count = 0, errors = {}}
            end,
        },
    })
    local report, err = Sync.run(deps)
    T.ok(report == nil and tostring(err):find("没有划线", 1, true), "无划线报错: " .. tostring(err))
end)

T.case("全部章节拉取失败按网络错误报", function()
    local deps = make_deps({
        annotations = {
            fetch_chapter = function() error("network request failed") end,
        },
    })
    local report, err = Sync.run(deps)
    T.ok(report == nil and tostring(err):find("拉取失败", 1, true), "全失败报错: " .. tostring(err))
end)

T.case("章节列表接口失败", function()
    local deps = make_deps({
        api = {chapters = function() error("boom") end},
    })
    local report, err = Sync.run(deps)
    T.ok(report == nil and tostring(err):find("章节列表失败", 1, true), "报错: " .. tostring(err))
end)

T.case("引文全不匹配本地书", function()
    local deps = make_deps({
        read_text = function() return "<html><body>完全无关的另一本书内容</body></html>" end,
    })
    local report, err = Sync.run(deps)
    T.ok(report == nil and tostring(err):find("匹配", 1, true), "映射失败报错: " .. tostring(err))
end)

T.case("映射缓存:续批只匹配新章节", function()
    local cache_file = "tests/.tmp_map_cache.json"
    os.remove(cache_file)
    local U = require("pickthought.util")

    local reads1 = 0
    local deps1 = make_deps({
        map_cache_path = cache_file,
        read_text = function(_, href)
            reads1 = reads1 + 1
            return href == "OEBPS/c1.xhtml" and CH1_TEXT or CH2_TEXT
        end,
    })
    local report1, err1 = Sync.run(deps1)
    T.ok(report1, "首次应成功: " .. tostring(err1))
    T.ok(reads1 > 0, "首次读取了正文文件")
    T.ok(U.file_exists(cache_file), "映射结果落盘")

    -- 第二次:同一章节已在缓存里,不该再读任何正文文件
    local reads2 = 0
    local deps2 = make_deps({
        map_cache_path = cache_file,
        read_text = function(_, href)
            reads2 = reads2 + 1
            return href == "OEBPS/c1.xhtml" and CH1_TEXT or CH2_TEXT
        end,
    })
    local report2, err2 = Sync.run(deps2)
    T.ok(report2, "续批应成功: " .. tostring(err2))
    T.eq(reads2, 0, "全部命中映射缓存,零文件读取")
    T.eq(report2.injected, 1, "缓存映射照常注入")
    T.eq(report2.chapters_matched, 1, "匹配章数一致")

    -- 算法版本变化必须让缓存整体作废,否则旧算法的失败结论永久生效
    local ChapterMap = require("pickthought.chapter_map")
    local saved = ChapterMap.ALGO_VERSION
    ChapterMap.ALGO_VERSION = saved + 1
    local reads3 = 0
    local deps3 = make_deps({
        map_cache_path = cache_file,
        read_text = function(_, href)
            reads3 = reads3 + 1
            return href == "OEBPS/c1.xhtml" and CH1_TEXT or CH2_TEXT
        end,
    })
    local report3 = Sync.run(deps3)
    ChapterMap.ALGO_VERSION = saved
    T.ok(report3, "算法升版后仍应成功")
    T.ok(reads3 > 0, "算法升版后缓存作废,重新匹配")
    os.remove(cache_file)
end)

T.case("映射缓存:旧的未匹配结论下一轮仍会重试", function()
    local cache_file = "tests/.tmp_map_retry.json"
    os.remove(cache_file)
    local U = require("pickthought.util")
    local failed, err1 = Sync.run(make_deps({
        map_cache_path = cache_file,
        read_text = function() return "<html><body>暂时无法命中的正文</body></html>" end,
    }))
    T.ok(failed == nil and tostring(err1):find("匹配", 1, true), "首次未匹配应结束并提示匹配失败: " .. tostring(err1))
    local Json = require("pickthought.json")
    local decoded = Json.decode(U.read_file(cache_file, true))
    T.ok(decoded and decoded.map and decoded.map["1"] == nil, "新的未匹配结果不得永久写入 false")
    decoded.map["1"] = false -- 模拟旧版本遗留的永久失败缓存。
    T.ok(U.atomic_write(cache_file, Json.encode(decoded), true), "写入旧 false 缓存")

    local reads = 0
    local retried, err2 = Sync.run(make_deps({
        map_cache_path = cache_file,
        read_text = function(_, href)
            reads = reads + 1
            return href == "OEBPS/c1.xhtml" and CH1_TEXT or CH2_TEXT
        end,
    }))
    T.ok(retried, "旧 false 结果不应阻止下一轮重试: " .. tostring(err2))
    T.ok(reads > 0, "旧 false 结果应重新读取正文")
    T.eq(retried.injected, 1, "重试后应成功注入")
    os.remove(cache_file)
end)

T.case("映射缓存写入失败时同步不得继续注入", function()
    local U = require("pickthought.util")
    local cache_file = "tests/.tmp_map_cache_write_failure.json"
    local report, err
    with_memfs(function()
        U.atomic_write = function(path)
            if tostring(path) == cache_file then return nil, "磁盘满" end
            return true
        end
        local deps, calls = make_deps({map_cache_path = cache_file})
        report, err = Sync.run(deps)
        T.eq(calls.injected, nil, "映射缓存保存失败后不得进入注入")
    end)
    T.ok(report == nil, "映射缓存保存失败应终止同步")
    T.ok(tostring(err):find("映射缓存保存失败", 1, true),
        "错误应明确指出映射缓存保存失败: " .. tostring(err))
    T.ok(tostring(err):find("磁盘满", 1, true),
        "错误应保留底层写入原因: " .. tostring(err))
end)

T.case("正文 spine 缓存:冷读落盘,续批暖读不再解压", function()
    local U = require("pickthought.util")
    local SpineCache = require("pickthought.spine_cache")
    local saved = {}
    for _, key in ipairs({"mkdir", "read_file", "file_exists", "atomic_write", "remove_tree", "list"}) do
        saved[key] = U[key]
    end
    local fs = {}
    U.mkdir = function(path) fs[tostring(path)] = fs[tostring(path)] or true; return true end
    U.file_exists = function(path) return fs[tostring(path)] ~= nil end
    U.read_file = function(path)
        local value = fs[tostring(path)]
        return value == true and nil or value
    end
    U.atomic_write = function(path, data) fs[tostring(path)] = data; return true end
    U.remove_tree = function(path)
        local prefix = tostring(path)
        for key in pairs(fs) do
            if key == prefix or key:sub(1, #prefix + 1) == prefix .. "/" then fs[key] = nil end
        end
        return true
    end
    U.list = function(path)
        local out, prefix = {}, tostring(path) .. "/"
        for key in pairs(fs) do
            if key:sub(1, #prefix) == prefix then out[#out + 1] = key end
        end
        return out
    end

    local function finish(ok, err)
        for key, value in pairs(saved) do U[key] = value end
        if not ok then error(err, 0) end
    end
    local cache_file = "tests/.tmp_sync_spine_map.json"
    -- 签名格式 = 大小@算法版本@内容指纹(无干净源时干净源后缀为空);
    -- 测试中 map_source 为不存在的虚拟路径,故大小=0、指纹=0。
    local signature = "0@" .. tostring(require("pickthought.chapter_map").ALGO_VERSION) .. "@0"
    local spine_dir = SpineCache.dir_for(cache_file, signature)
    U.remove_tree(spine_dir)

    local function rows(count)
        local out = {}
        for i = 1, count do
            out[i] = {chapterUid = i, title = "第一章", chapterIdx = i}
        end
        return out
    end
    local function chapter_data(_, _, uid)
        local text = tostring(uid) == "1" and "春江潮水连海平" or "滟滟随波千万里"
        return {
            underlines = {{range = "0-7", markText = text}}, review_map = {}, review_groups = {},
            underline_count = 1, thought_count = 0, thought_entry_count = 0, errors = {},
        }
    end

    local cold_scans = 0
    local deps1, calls1 = make_deps({
        api = {chapters = function() return {data = rows(1)} end},
        annotations = {fetch_chapter = chapter_data},
        map_cache_path = cache_file,
        spine_cache = true,
        read_spine = function(meta, callback)
            cold_scans = cold_scans + 1
            for index, item in ipairs(meta.spine) do
                local html = item.href == "OEBPS/c1.xhtml" and CH1_TEXT or CH2_TEXT
                callback(item, html, nil, index)
            end
            return true
        end,
    })
    local ok, err = xpcall(function()
        local report1, err1 = Sync.run(deps1)
        T.ok(report1, "冷缓存首批同步成功: " .. tostring(err1))
        T.eq(cold_scans, 1, "首批只扫描一次真实 spine")
        T.ok(U.file_exists(spine_dir .. "/manifest.json"), "首批落盘 spine manifest")
        T.ok(calls1.injected and #calls1.injected.mapped == 1, "首批注入一章")

        local warm_scans = 0
        local deps2, calls2 = make_deps({
            api = {chapters = function() return {data = rows(2)} end},
            annotations = {fetch_chapter = chapter_data},
            map_cache_path = cache_file,
            spine_cache = true,
            read_spine = function()
                warm_scans = warm_scans + 1
                error("暖缓存命中时不应重新解压 spine")
            end,
        })
        local report2, err2 = Sync.run(deps2)
        T.ok(report2, "暖缓存续批同步成功: " .. tostring(err2))
        T.eq(warm_scans, 0, "新增章节匹配直接读取暖缓存")
        T.ok(calls2.injected and #calls2.injected.mapped == 2, "续批包含旧章和新章的注入数据")
    end, debug.traceback)

    finish(ok, err)
end)

T.case("分批预算:拉满即收工,缓存命中免费", function()
    local rows = {}
    for i = 1, 10 do rows[i] = {chapterUid = i, title = "第" .. i .. "章", chapterIdx = i} end
    local network_calls = 0
    local deps, calls = make_deps({
        api = {chapters = function() return {chapters = rows} end},
        annotations = {
            fetch_chapter = function(_, _, uid)
                local n = tonumber(uid)
                if n <= 2 then
                    -- 前两章:断点缓存命中,不占预算
                    return {underlines = {{range = "0-7", markText = "春江潮水连海平"}},
                        review_map = {}, review_groups = {}, resumed = true,
                        underline_count = 1, thought_count = 0, thought_entry_count = 0, errors = {}}
                end
                network_calls = network_calls + 1
                return {underlines = {{range = "0-7", markText = "春江潮水连海平"}},
                    review_map = {}, review_groups = {},
                    underline_count = 1, thought_count = 0, thought_entry_count = 0, errors = {}}
            end,
        },
        fetch_budget = 3,
    })
    local report, err = Sync.run(deps)
    T.ok(report, "应成功: " .. tostring(err))
    T.eq(network_calls, 3, "只发 3 个网络请求")
    T.eq(report.chapters_pending, 5, "2 缓存 + 3 网络 = 5 章处理,剩 5 章待拉")
    T.eq(#calls.injected.mapped, 5, "已拉到的 5 章照常注入")
end)

T.case("同步优先使用单遍 spine 读取", function()
    local deps, calls = make_deps()
    deps.read_text = function() error("不应回退逐条读取") end
    deps.read_spine = function(meta, callback)
        calls.spine_scans = (calls.spine_scans or 0) + 1
        for index, item in ipairs(meta.spine) do
            local content = item.href == "OEBPS/c1.xhtml" and CH1_TEXT or CH2_TEXT
            callback(item, content, nil, index)
        end
        return true
    end
    local report, err = Sync.run(deps)
    T.ok(report, "流式同步成功: " .. tostring(err))
    T.eq(calls.spine_scans, 1, "只执行一次 spine 扫描")
    T.eq(calls.injected.mapped[1].href, "OEBPS/c1.xhtml", "映射结果不变")
end)

T.case("章节批次预算限制缓存回放,不再一次性注入全书", function()
    local rows = {}
    for i = 1, 10 do rows[i] = {chapterUid = i, title = "第" .. i .. "章", chapterIdx = i} end
    local fetch_calls = 0
    local deps, calls = make_deps({
        api = {chapters = function() return {chapters = rows} end},
        annotations = {
            fetch_chapter = function()
                fetch_calls = fetch_calls + 1
                return {underlines = {{range = "0-7", markText = "春江潮水连海平"}},
                    review_map = {}, review_groups = {}, resumed = true,
                    underline_count = 1, thought_count = 0, thought_entry_count = 0, errors = {}}
            end,
        },
        chapter_budget = 3,
    })
    local report, err = Sync.run(deps)
    T.ok(report, "应成功: " .. tostring(err))
    T.eq(fetch_calls, 3, "缓存回放也只处理本批 3 章")
    T.eq(report.chapters_pending, 7, "剩余 7 章")
    T.eq(report.next_index, 4, "下批从第 4 章开始")
    T.eq(report.batch_start, 1, "本批起点")
    T.eq(report.batch_end, 3, "本批终点")
    T.eq(report.chapters_processed, 3, "本批实际处理数")
    T.eq(report.chapters_fetch_succeeded, 3, "本批拉取成功数")
    T.eq(#calls.injected.mapped, 3, "本批只注入 3 章")
end)

T.case("已完成缓存续同步跳过旧章,只注入新章", function()
    local rows = {}
    for i = 1, 5 do rows[i] = {chapterUid = i, title = "第" .. i .. "章", chapterIdx = i} end
    local deps, calls = make_deps({
        api = {chapters = function() return {chapters = rows} end},
        annotations = {
            fetch_chapter = function(_, _, uid)
                if tonumber(uid) < 5 then
                    return {underlines = {{range = "0-7", markText = "春江潮水连海平"}},
                        review_map = {}, review_groups = {}, resumed = true,
                        underline_count = 1, thought_count = 0, thought_entry_count = 0, errors = {}}
                end
                return {underlines = {{range = "0-7", markText = "春江潮水连海平"}},
                    review_map = {}, review_groups = {},
                    underline_count = 1, thought_count = 0, thought_entry_count = 0, errors = {}}
            end,
        },
        skip_resumed = true,
        fetch_budget = 1,
    })
    local report, err = Sync.run(deps)
    T.ok(report, "应成功: " .. tostring(err))
    T.eq(report.chapters_pending, 0, "新章处理后无剩余")
    T.eq(report.next_index, 6, "游标到章节末尾")
    T.eq(#calls.injected.mapped, 1, "旧缓存不重复注入")
end)

T.case("限流章节不推进游标,下次同步可重试", function()
    local deps, calls = make_deps({
        annotations = {
            fetch_chapter = function(_, _, uid)
                if tostring(uid) == "1" then
                    return {underlines = {{range = "0-7", markText = "春江潮水连海平"}},
                        review_map = {}, review_groups = {}, underline_count = 1,
                        thought_count = 0, thought_entry_count = 0, errors = {},
                        underline_request_ok = false, rate_limited = true,
                        rate_limit_wait = 7}
                end
                return {underlines = {}, review_map = {}, review_groups = {},
                    underline_count = 0, thought_count = 0, thought_entry_count = 0, errors = {}}
            end,
        },
    })
    local report, err = Sync.run(deps)
    T.ok(report, "限流应返回可续传报告: " .. tostring(err))
    T.eq(report.rate_limited, true, "报告标记限流")
    T.eq(report.rate_limit_wait, 7, "报告携带下次重试等待时间")
    T.eq(report.next_index, 1, "限流章下次仍从当前章开始")
    T.eq(report.chapters_processed, 0, "限流章未完成,不计入本批")
    T.eq(calls.injected, nil, "限流章的半成品不注入")
end)

T.case("章节部分拉取失败也不能推进游标", function()
    local deps, calls = make_deps({
        annotations = {
            fetch_chapter = function(_, _, uid)
                if tostring(uid) == "1" then
                    return {underlines = {{range = "0-7", markText = "春江潮水连海平"}},
                        review_map = {}, review_groups = {}, underline_count = 1,
                        thought_count = 0, thought_entry_count = 0, errors = {}}
                end
                return {underlines = {{range = "0-7", markText = "滟滟随波千万里"}},
                    review_map = {}, review_groups = {}, underline_count = 1,
                    thought_count = 0, thought_entry_count = 0,
                    errors = {"想法批次请求失败"}}
            end,
        },
    })
    local report, err = Sync.run(deps)
    T.ok(report, "前一章成功时应保留部分结果: " .. tostring(err))
    T.eq(report.fetch_errors, 1, "部分失败计入拉取错误")
    T.eq(report.next_index, 2, "部分失败章节不能推进游标")
    T.eq(report.chapters_pending, 1, "部分失败章节计入待处理")
    T.eq(#calls.injected.mapped, 1, "不注入部分失败章节")
end)

T.case("首个硬失败立即停在失败章节", function()
    local rows = {}
    for i = 1, 10 do rows[i] = {chapterUid = i, title = "第" .. i .. "章", chapterIdx = i} end
    local fetch_count = 0
    local deps, calls = make_deps({
        api = {chapters = function() return {chapters = rows} end},
        annotations = {
            fetch_chapter = function() fetch_count = fetch_count + 1; error("network request failed") end,
        },
    })
    local report, err = Sync.run(deps)
    T.ok(report == nil and tostring(err):find("划线拉取失败", 1, true), "失败报错: " .. tostring(err))
    T.ok(tostring(err):find("network request failed", 1, true), "失败消息必须带真实错误: " .. tostring(err))
    T.eq(fetch_count, 1, "首个失败即停止,避免跨过连续游标")
    T.eq(calls.injected, nil, "熔断后不注入")
end)

T.case("缓存命中后失败仍停在失败章节", function()
    local rows = {}
    for i = 1, 7 do rows[i] = {chapterUid = i, title = "第" .. i .. "章", chapterIdx = i} end
    local fetch_calls = 0
    local deps = make_deps({
        api = {chapters = function() return {chapters = rows} end},
        annotations = {
            fetch_chapter = function(_, _, uid)
                fetch_calls = fetch_calls + 1
                local n = tonumber(uid)
                if n == 1 then
                    -- 第一章:断点缓存命中(resumed),不发网络
                    return {underlines = {{range = "0-7", markText = "春江潮水连海平"}},
                        review_map = {}, review_groups = {}, resumed = true,
                        underline_count = 1, thought_count = 0, thought_entry_count = 0, errors = {}}
                end
                error("network request failed")
            end,
        },
    })
    local report, err = Sync.run(deps)
    T.ok(report, "缓存命中后应保留前一章结果: " .. tostring(err))
    T.eq(report.next_index, 2, "缓存命中后失败仍应停在失败章")
    T.eq(fetch_calls, 2, "缓存命中后只尝试失败章节")
end)

T.case("末尾连续失败且成功章节无划线时报拉取失败而非无划线", function()
    local rows = {}
    for i = 1, 4 do rows[i] = {chapterUid = i, title = "第" .. i .. "章", chapterIdx = i} end
    local deps = make_deps({
        api = {chapters = function() return {chapters = rows} end},
        annotations = {
            fetch_chapter = function(_, _, uid)
                if tostring(uid) == "1" then
                    return {underlines = {}, review_map = {}, review_groups = {},
                        underline_count = 0, thought_count = 0, thought_entry_count = 0, errors = {}}
                end
                error("network request failed")
            end,
        },
    })
    local report, err = Sync.run(deps)
    T.ok(report == nil, "应失败")
    T.ok(tostring(err):find("拉取失败", 1, true), "归因网络: " .. tostring(err))
    T.ok(not tostring(err):find("这本书在微信读书里没有划线", 1, true), "不得误报为书无划线")
end)

T.case("单章拉取失败不中断,计入 fetch_errors", function()
    local deps, calls = make_deps({
        annotations = {
            fetch_chapter = function(_, _, uid)
                if tostring(uid) == "2" then error("timeout") end
                return {
                    underlines = {{range = "0-7", markText = "春江潮水连海平"}},
                    review_map = {}, review_groups = {},
                    underline_count = 1, thought_count = 0, thought_entry_count = 0, errors = {},
                }
            end,
        },
    })
    local report, err = Sync.run(deps)
    T.ok(report, "应成功: " .. tostring(err))
    T.eq(report.fetch_errors, 1, "失败章节计数")
    T.eq(report.injected, 1, "成功章节照常注入")
    T.eq(report.next_index, 2, "失败章节作为连续游标边界")
    T.eq(report.chapters_pending, 1, "失败章节计入待处理")
end)

-- fix #2:同步路径不依据整章 fetch(含网络/限流)耗时判定降级,避免网络慢误触发
-- 粘性降级、挤占本地注入的让出预算。回归:即便传入 perf 桩,同步也不应采样或让出。
T.case("同步不依据网络耗时降级(fix #2 回归)", function()
    local rest_calls, record_calls = 0, 0
    local perf_spy = {
        record = function() record_calls = record_calls + 1 end,
        rest = function() rest_calls = rest_calls + 1 end,
        degraded = function() return false end,
    }
    local deps, calls = make_deps({
        perf = perf_spy,  -- 若日后重新把 perf 接入 sync,此桩可捕获误用
        annotations = {
            -- 返回有效数据(否则 sync 会因"无划线"提前终止),但 sync 本就不对其计时/降级。
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
    })
    local report, err = Sync.run(deps)
    T.ok(report, "同步应成功: " .. tostring(err))
    T.eq(record_calls, 0, "sync 不应采样整章 fetch 耗时")
    T.eq(rest_calls, 0, "sync 不应因网络慢触发让出")
end)


T.case("多书绑定:一次同步聚合多本微信读书书并合并注入", function()
    -- 模拟「一本本地合集 EPUB 绑了 b001、b002 两本微信读书书」。
    -- 两本各自有第一章(划线一致,都能映射到本地 c1);验证:两本都被拉取、
    -- 注入的 mapped 合并了两本的章节(各自带 book_id)、inject 收到完整 book_ids。
    local api_calls = {}
    local fetch_calls = {}
    local deps, calls = make_deps({
        book_ids = {"b001", "b002"},
        api = {
            chapters = function(_, bid)
                api_calls[#api_calls + 1] = tostring(bid)
                local suffix = tostring(bid)
                return {chapters = {
                    {chapterUid = 1, title = "第一章(" .. suffix .. ")", chapterIdx = 1},
                    {chapterUid = 2, title = "第二章(" .. suffix .. ")", chapterIdx = 2},
                }}
            end,
        },
        annotations = {
            fetch_chapter = function(_, bid, uid)
                fetch_calls[#fetch_calls + 1] = {book_id = tostring(bid), uid = tostring(uid)}
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
    })
    local report, err = Sync.run(deps)
    T.ok(report, "多书聚合应成功: " .. tostring(err))

    -- 两本书的章节列表都被请求过(逐本拉取聚合)。
    T.eq(#api_calls, 2, "按 book_ids 逐本拉取章节列表")
    T.ok(api_calls[1] == "b001" and api_calls[2] == "b002", "先拉 b001 再拉 b002")

    -- 章节总数为两本之和;有划线的章节为两本各自的第一章。
    T.eq(report.chapters_total, 4, "章节总数=两本之和")
    T.eq(report.chapters_with_data, 2, "两本各有 1 章有划线")

    -- 注入的 mapped 合并了两本书的章节,且每行都带正确的 book_id。
    local books_in_mapped = {}
    for _, row in ipairs(calls.injected.mapped) do
        books_in_mapped[row.book_id] = true
    end
    T.eq(#calls.injected.mapped, 2, "合并注入两本各有 1 章")
    T.ok(books_in_mapped["b001"] and books_in_mapped["b002"], "两本都在注入结果里")

    -- inject 调用收到完整 book_ids(解决「换绑漏书」的根因:一次性合并重建)。
    T.eq(type(calls.injected.options.book_ids), "table", "inject 选项携带 book_ids")
    T.eq(calls.injected.options.book_ids[1], "b001", "book_ids 含 b001")
    T.eq(calls.injected.options.book_ids[2], "b002", "book_ids 含 b002")

    -- 多书强制干净重建(不走增量 append),从原书/备份读取而非当前注入版。
    T.eq(calls.injected.options.append, false, "多书强制全量重建,不增量追加")
end)

T.case("多书同步入口:从 Binding.list 取 book_ids + 函数式 map 缓存(P1#1/P1#2)", function()
    -- 复刻 main.lua 的接线:_book_ids 从 Binding.list 取全部绑定书 id,map_cache_path
    -- 用函数式(每书独立 map.json),与后台 sync_task 完全一致(P1#2 统一约定)。
    local Binding = require("pickthought.binding")
    local kv = {}
    local store = {
        get = function(_, k, d) return kv[k] ~= nil and kv[k] or d end,
        set = function(_, k, v) kv[k] = v end,
    }
    local path = "/books/合集.epub"
    Binding.save(store, path, {book_id = "b1", title = "甲"})
    Binding.save(store, path, {book_id = "b2", title = "乙"})
    local function book_ids_of(p)
        local list = Binding.list(store, p)
        local ids = {}
        for _, rec in ipairs(list) do
            if rec and rec.book_id then ids[#ids + 1] = rec.book_id end
        end
        if #ids == 0 then
            local b = Binding.get(store, p)
            if b and b.book_id then ids[#ids + 1] = b.book_id end
        end
        return ids
    end
    local book_ids = book_ids_of(path)
    T.eq(#book_ids, 2, "入口取到两本书 id")

    local deps, calls = make_deps({
        book_ids = book_ids,
        api = { chapters = function(_, bid)
            return {data = {
                {chapterUid = 1, title = tostring(bid) .. "-1", chapterIdx = 1},
                {chapterUid = 2, title = tostring(bid) .. "-2", chapterIdx = 2},
            }}
        end},
    })
    deps.map_cache_path = function(bid) return "/cache/" .. bid .. "/sync-cache/map.json" end
    local report, err = Sync.run(deps)
    T.ok(report, "入口多书聚合应成功: " .. tostring(err))
    T.eq(report.chapters_total, 4, "两本各 2 章=4")
    T.ok(report.per_book["b1"] and report.per_book["b2"], "per_book 两本都在")
    T.eq(#calls.injected.mapped, 2, "两本各有 1 章有划线,合并注入 2 章")
end)

T.case("多书同步按书记录续传游标 per_book(P1#5)", function()
    local deps = {
        doc_path = "/books/合集.epub",
        book_ids = {"b1", "b2"},
        file_exists = function() return false end,
        rename = function() return true end,
        remove = function() return true end,
        api = { chapters = function(_, bid)
            if bid == "b1" then
                return {data = {
                    {chapterUid=1,title="b1-1",chapterIdx=1},
                    {chapterUid=2,title="b1-2",chapterIdx=2},
                    {chapterUid=3,title="b1-3",chapterIdx=3},
                }}
            end
            return {data = {
                {chapterUid=1,title="b2-1",chapterIdx=1},
                {chapterUid=2,title="b2-2",chapterIdx=2},
                {chapterUid=3,title="b2-3",chapterIdx=3},
                {chapterUid=4,title="b2-4",chapterIdx=4},
                {chapterUid=5,title="b2-5",chapterIdx=5},
            }}
        end},
        -- 两本书的每个章节都带可匹配的划线(引文落在本地 c1 文本里),确保全部章节
        -- 都能匹配→每本 pending=0、next_index=末章+1。
        annotations = { fetch_chapter = function(_, _, uid)
            return {underlines={{range="0-7",markText="春江潮水连海平"}}, review_map={}, review_groups={},
                underline_count=1, thought_count=0, thought_entry_count=0, errors={}}
        end},
        load_meta = function() return {spine={{href="c1"}}, has={}} end,
        read_text = function(_, href)
            return "<html><body><p>春江潮水连海平,海上明月共潮生。</p></body></html>"
        end,
        save_thoughts = function() return 0 end,
        inject = function() return {injected=1,marks=1,unmatched={},quote_aligned=1,dropped=0,underlines_resolved=1,thoughts_linked=0,thoughts_linked_by_uid={},merges={}} end,
        progress = function() return true end,
    }
    local report = Sync.run(deps)
    T.ok(report, "多书同步应成功")
    T.eq(report.chapters_total, 8, "章节总数=3+5")
    T.ok(report.per_book and report.per_book["b1"] and report.per_book["b2"],
        "per_book 含两本书,不混为单一聚合")
    T.eq(report.per_book["b1"].total, 3, "b1 总数")
    T.eq(report.per_book["b1"].next_index, 4, "b1 续传位置(全部完成→末章+1)")
    T.eq(report.per_book["b1"].pending, 0, "b1 无待处理")
    T.eq(report.per_book["b2"].total, 5, "b2 总数")
    T.eq(report.per_book["b2"].next_index, 6, "b2 续传位置(全部完成→末章+1)")
    T.eq(report.per_book["b2"].pending, 0, "b2 无待处理")
    T.eq(report.chapters_pending, 0, "聚合待处理=两本之和(0)")
end)

T.case("两批同步:第二批命中 spine 缓存不再重读正文(P1#2)", function()
    local MARKER = require("pickthought.epub_inject").MARKER
    local doc_path = "/books/两批.epub"
    local spine = {{href = "OEBPS/c1.xhtml"}, {href = "OEBPS/c2.xhtml"}}
    local TEXT = {
        ["OEBPS/c1.xhtml"] = "<html><body><p>春江潮水连海平,海上明月共潮生。</p></body></html>",
        ["OEBPS/c2.xhtml"] = "<html><body><p>滟滟随波千万里,何处春江无月明。</p></body></html>",
    }

    -- 用内存 FS 替身包裹两批,使 map.json / spine 缓存在批间真正持久化
    -- (测试环境 lfs 是 no-op,裸跑会让 atomic_write 静默失败、第二批走冷模式重读)。
    with_memfs(function()
        local map_path = "tests/.tmp_twobatch/map.json"
        local read_counts = {}
        local flags = { batch2 = false }
        local deps = {
            doc_path = doc_path,
            book_id = "b1",
            file_exists = function(p) return flags.batch2 and tostring(p):find("%.orig") end,
            rename = function() return true end,
            remove = function() return true end,
            api = { chapters = function()
                return {data = {
                    {chapterUid=1,title="1",chapterIdx=1},
                    {chapterUid=2,title="2",chapterIdx=2},
                    {chapterUid=3,title="3",chapterIdx=3},
                    {chapterUid=4,title="4",chapterIdx=4},
                }}
            end},
            annotations = { fetch_chapter = function(_, _, uid)
                local t = {["1"]="春江潮水连海平",["2"]="滟滟随波千万里",
                           ["3"]="春江潮水连海平",["4"]="滟滟随波千万里"}
                local txt = t[tostring(uid)]
                if txt then
                    return {underlines={{range="0-7",markText=txt}}, review_map={}, review_groups={},
                        underline_count=1, thought_count=0, thought_entry_count=0, errors={}}
                end
                return {underlines={}, review_map={}, review_groups={}, underline_count=0, thought_count=0, thought_entry_count=0, errors={}}
            end},
            load_meta = function(p)
                if flags.batch2 and tostring(p):find("%.orig") then
                    return {spine = spine, has = {}}
                end
                if flags.batch2 and tostring(p) == doc_path then
                    return {spine = spine, has = {[MARKER] = true}}
                end
                return {spine = spine, has = {}}
            end,
            read_text = function(_, href)
                read_counts[href] = (read_counts[href] or 0) + 1
                return TEXT[href]
            end,
            save_thoughts = function() return 0 end,
            inject = function() return {injected=1,marks=1,unmatched={},quote_aligned=1,dropped=0,underlines_resolved=1,thoughts_linked=0,thoughts_linked_by_uid={},merges={}} end,
            progress = function() return true end,
            -- P1#2:前台也改用函数式 map_cache_path,与后台一致(每书独立 map.json)。
            map_cache_path = function() return map_path end,
            spine_cache = true,
        }
        -- 第一批:全量拉取,冷模式捕获 spine 缓存,真实 read_text 被调用。
        local r1 = Sync.run(deps)
        T.ok(r1, "第一批应成功")
        local calls1 = 0
        for _, c in pairs(read_counts) do calls1 = calls1 + c end
        T.ok(calls1 > 0, "第一批读取了正文(冷捕获)")

        -- 第二批:从 ch3 续传(增量 append;ch3/ch4 引文落在 c1/c2,均已在第一批缓存)。
        flags.batch2 = true
        deps.append = true
        deps.chapter_start = 3
        local r2 = Sync.run(deps)
        T.ok(r2, "第二批应成功")
        T.eq(r2.per_book["b1"].next_index, 5, "第二批续传完成位置")
        T.eq(r2.per_book["b1"].pending, 0, "第二批该书全部完成")

        -- 第二批整批映射只命中 spine 缓存,不得再调用真实 read_text。
        local calls2 = 0
        for _, c in pairs(read_counts) do calls2 = calls2 + c end
        T.eq(calls2, calls1, "第二批未重新读取已缓存的正文文件")
    end)
end)

-- 评审三轮 P1#1:多书场景下,某本书「章节列表拉取失败」必须记失败态、不写 pending,
-- 且绝不能让 sync_task 误以为该书已「完成」(否则下次无法经断点缓存续传)。
T.case("多书章节列表拉取失败:记失败态且不写 pending(P1#1)", function()
    local deps = {
        doc_path = "/books/合集.epub",
        book_ids = {"b1", "b2"},   -- 两本: b1 拉章节列表直接抛错,b2 正常
        file_exists = function() return false end,
        rename = function() return true end,
        remove = function() return true end,
        api = { chapters = function(_, bid)
            if bid == "b1" then
                error("获取章节列表失败:网络超时")   -- 抛错 → pcall 捕获 → 软失败
            end
            return {data = {
                {chapterUid=1,title="b2-1",chapterIdx=1},
                {chapterUid=2,title="b2-2",chapterIdx=2},
            }}
        end},
        annotations = { fetch_chapter = function(_, _, uid)
            return {underlines={{range="0-7",markText="春江潮水连海平"}}, review_map={}, review_groups={},
                underline_count=1, thought_count=0, thought_entry_count=0, errors={}}
        end},
        load_meta = function() return {spine={{href="c1"}}, has={}} end,
        read_text = function(_, href)
            return "<html><body><p>春江潮水连海平,海上明月共潮生。</p></body></html>"
        end,
        save_thoughts = function() return 0 end,
        inject = function() return {injected=1,marks=1,unmatched={},quote_aligned=1,dropped=0,underlines_resolved=1,thoughts_linked=0,thoughts_linked_by_uid={},merges={}} end,
        progress = function() return true end,
    }
    local report = Sync.run(deps)
    T.ok(report, "b2 成功取到数据,整体不应硬失败")
    T.ok(report.per_book and report.per_book["b1"] and report.per_book["b2"], "per_book 两本都在")
    T.ok(report.per_book["b1"].failed == true, "b1 标记 failed")
    T.ok(report.per_book["b1"].pending == nil, "b1 不写 pending(避免 sync_task 误判完成)")
    T.eq(report.per_book["b1"].next_index, 1, "b1 续传起点重置为 1")
    T.eq(report.per_book["b1"].total, 0, "b1 总量未知(列表未取到)")
    T.eq(report.per_book["b2"].pending, 0, "b2 正常完成")
    T.ok(not report.per_book["b2"].failed, "b2 非失败书")
end)

-- 评审三轮 P1#1:多书某本书连续章拉取失败触发熔断,必须记录「下次从失败章续传」的
-- 完整状态(next_index=失败章、pending=剩余章、total),且不误标完成。
T.case("多书连续失败熔断:记录续传游标且不误标完成(P1#1)", function()
    local deps = {
        doc_path = "/books/合集.epub",
        book_ids = {"b1", "b2"},
        file_exists = function() return false end,
        rename = function() return true end,
        remove = function() return true end,
        api = { chapters = function(_, bid)
            if bid == "b1" then
                return {data = {   -- 4 章:前 3 章划线拉取抛错 → 连续 3 章熔断
                    {chapterUid=1,title="b1-1",chapterIdx=1},
                    {chapterUid=2,title="b1-2",chapterIdx=2},
                    {chapterUid=3,title="b1-3",chapterIdx=3},
                    {chapterUid=4,title="b1-4",chapterIdx=4},
                }}
            end
            return {data = {
                {chapterUid=1,title="b2-1",chapterIdx=1},
                {chapterUid=2,title="b2-2",chapterIdx=2},
            }}
        end},
        annotations = { fetch_chapter = function(_, bid, uid)
            if bid == "b1" and tonumber(uid) <= 3 then
                error("断网:章 " .. tostring(uid) .. " 划线拉取失败")  -- 前 3 章硬失败
            end
            return {underlines={{range="0-7",markText="春江潮水连海平"}}, review_map={}, review_groups={},
                underline_count=1, thought_count=0, thought_entry_count=0, errors={}}
        end},
        load_meta = function() return {spine={{href="c1"}}, has={}} end,
        read_text = function(_, href)
            return "<html><body><p>春江潮水连海平,海上明月共潮生。</p></body></html>"
        end,
        save_thoughts = function() return 0 end,
        inject = function() return {injected=1,marks=1,unmatched={},quote_aligned=1,dropped=0,underlines_resolved=1,thoughts_linked=0,thoughts_linked_by_uid={},merges={}} end,
        progress = function() return true end,
    }
    local report = Sync.run(deps)
    T.ok(report, "b2 成功取到数据,整体不应硬失败")
    T.ok(report.per_book and report.per_book["b1"] and report.per_book["b2"], "per_book 两本都在")
    T.ok(report.per_book["b1"].failed == true, "b1 标记 failed(熔断)")
    T.eq(report.per_book["b1"].next_index, 3, "b1 从失败章(第3章)续传")
    T.eq(report.per_book["b1"].pending, 2, "b1 剩余 2 章(第3、4章)待处理")
    T.eq(report.per_book["b1"].total, 4, "b1 总量 4")
    T.eq(report.per_book["b2"].pending, 0, "b2 正常完成")
    T.ok(not report.per_book["b2"].failed, "b2 非失败书")
    -- 评审五轮 P1#2#3:熔断失败书的 pending(剩余 2 章)必须计入聚合 chapters_pending,
    -- 否则完成报告会同时显示「全书已处理完成」与「某本书同步失败」。
    T.eq(report.chapters_pending, 2, "失败书剩余章计入聚合 chapters_pending")
end)

-- 评审四轮 P1#4:多书聚合报告不能把不同远程书的独立章节坐标拼成单一连续区间。
-- 不同书各有自己的第 1..N 章,合并出的「1–5」区间在本地 EPUB 上并无意义。
-- 因此多书聚合 batch_start/batch_end 应为 nil,真实逐书 range 由 per_book 承载。
T.case("多书聚合不合并章节区间为单一范围(P1#4)", function()
    local deps = {
        doc_path = "/books/合集.epub",
        book_ids = {"b1", "b2"},
        file_exists = function() return false end,
        rename = function() return true end,
        remove = function() return true end,
        api = { chapters = function(_, bid)
            if bid == "b1" then
                return {data = {
                    {chapterUid=1,title="b1-1",chapterIdx=1},
                    {chapterUid=2,title="b1-2",chapterIdx=2},
                    {chapterUid=3,title="b1-3",chapterIdx=3},
                    {chapterUid=4,title="b1-4",chapterIdx=4},
                    {chapterUid=5,title="b1-5",chapterIdx=5},
                }}
            end
            return {data = {
                {chapterUid=1,title="b2-1",chapterIdx=1},
                {chapterUid=2,title="b2-2",chapterIdx=2},
            }}
        end},
        annotations = { fetch_chapter = function(_, _, uid)
            return {underlines={{range="0-7",markText="春江潮水连海平"}}, review_map={}, review_groups={},
                underline_count=1, thought_count=0, thought_entry_count=0, errors={}}
        end},
        load_meta = function() return {spine={{href="c1"}}, has={}} end,
        read_text = function(_, href)
            return "<html><body><p>春江潮水连海平,海上明月共潮生。</p></body></html>"
        end,
        save_thoughts = function() return 0 end,
        inject = function() return {injected=1,marks=1,unmatched={},quote_aligned=1,dropped=0,underlines_resolved=1,thoughts_linked=0,thoughts_linked_by_uid={},merges={}} end,
        progress = function() return true end,
    }
    local report = Sync.run(deps)
    T.ok(report, "多书聚合应成功")
    T.eq(report.batch_start, nil, "多书聚合不输出合并区间(各书坐标独立)")
    T.eq(report.batch_end, nil, "多书聚合不输出合并区间")
    T.eq(report.per_book["b1"].batch_start, 1, "b1 逐书 batch_start 仍真实")
    T.eq(report.per_book["b1"].batch_end, 5, "b1 逐书 batch_end 仍真实")
    T.eq(report.per_book["b2"].batch_start, 1, "b2 逐书 batch_start 仍真实")
    T.eq(report.per_book["b2"].batch_end, 2, "b2 逐书 batch_end 仍真实")
end)

-- 评审四轮 P1#4:两本书章节数差异很大时,聚合绝对不能报出「第 1–N 章」这种误导区间。
-- b1 有 10 章、b2 只有 3 章,聚合若仍输出 1–10 会让用户误以为两书都拉到第 10 章。
T.case("多书游标不同范围不连续时不报合并区间(P1#4)", function()
    local deps = {
        doc_path = "/books/合集.epub",
        book_ids = {"b1", "b2"},
        file_exists = function() return false end,
        rename = function() return true end,
        remove = function() return true end,
        api = { chapters = function(_, bid)
            if bid == "b1" then
                local rows = {}
                for i = 1, 10 do
                    rows[i] = {chapterUid=i, title="b1-"..i, chapterIdx=i}
                end
                return {data = rows}
            end
            return {data = {
                {chapterUid=1,title="b2-1",chapterIdx=1},
                {chapterUid=2,title="b2-2",chapterIdx=2},
                {chapterUid=3,title="b2-3",chapterIdx=3},
            }}
        end},
        annotations = { fetch_chapter = function(_, _, uid)
            return {underlines={{range="0-7",markText="春江潮水连海平"}}, review_map={}, review_groups={},
                underline_count=1, thought_count=0, thought_entry_count=0, errors={}}
        end},
        load_meta = function() return {spine={{href="c1"}}, has={}} end,
        read_text = function(_, href)
            return "<html><body><p>春江潮水连海平,海上明月共潮生。</p></body></html>"
        end,
        save_thoughts = function() return 0 end,
        inject = function() return {injected=1,marks=1,unmatched={},quote_aligned=1,dropped=0,underlines_resolved=1,thoughts_linked=0,thoughts_linked_by_uid={},merges={}} end,
        progress = function() return true end,
    }
    local report = Sync.run(deps)
    T.ok(report, "多书聚合应成功")
    T.eq(report.chapters_total, 13, "聚合章节总数=10+3")
    T.eq(report.batch_start, nil, "绝不报「第 1–10 章」这种跨书合并区间")
    T.eq(report.batch_end, nil, "绝不报合并区间")
    T.eq(report.per_book["b1"].total, 10, "b1 真实总数")
    T.eq(report.per_book["b1"].batch_end, 10, "b1 逐书 batch_end=10")
    T.eq(report.per_book["b2"].total, 3, "b2 真实总数")
    T.eq(report.per_book["b2"].batch_end, 3, "b2 逐书 batch_end=3")
end)

-- 评审五轮 P1#2:多书章节列表为空时不得当「成功」返回——否则任务层按空状态写
-- .completed,失败书被误标完成、续传入口消失。必须写 per_book 失败态(pending=nil),
-- 其余书正常继续。
T.case("多书章节列表为空:记失败态且不生成 .completed 语义(P1#2)", function()
    local deps = {
        doc_path = "/books/合集.epub",
        book_ids = {"b1", "b2"},   -- b1 章节列表为空,b2 正常
        file_exists = function() return false end,
        rename = function() return true end,
        remove = function() return true end,
        api = { chapters = function(_, bid)
            if bid == "b1" then
                return {data = {}}   -- 空列表:不明原因,不得当「无内容完成」
            end
            return {data = {
                {chapterUid=1,title="b2-1",chapterIdx=1},
                {chapterUid=2,title="b2-2",chapterIdx=2},
            }}
        end},
        annotations = { fetch_chapter = function(_, _, uid)
            return {underlines={{range="0-7",markText="春江潮水连海平"}}, review_map={}, review_groups={},
                underline_count=1, thought_count=0, thought_entry_count=0, errors={}}
        end},
        load_meta = function() return {spine={{href="c1"}}, has={}} end,
        read_text = function(_, href)
            return "<html><body><p>春江潮水连海平,海上明月共潮生。</p></body></html>"
        end,
        save_thoughts = function() return 0 end,
        inject = function() return {injected=1,marks=1,unmatched={},quote_aligned=1,dropped=0,underlines_resolved=1,thoughts_linked=0,thoughts_linked_by_uid={},merges={}} end,
        progress = function() return true end,
    }
    local report = Sync.run(deps)
    T.ok(report, "b2 正常取到数据,整体不应硬失败")
    T.ok(report.per_book and report.per_book["b1"], "b1 有 per_book 记录")
    T.ok(report.per_book["b1"].failed == true, "b1 标记 failed(空列表=失败态,不误标完成)")
    T.ok(report.per_book["b1"].pending == nil, "b1 pending=nil(剩余未知,不得当 0)")
    T.eq(report.per_book["b1"].total, 0, "b1 总量 0")
    T.eq(report.per_book["b1"].next_index, 1, "b1 续传起点 1")
    T.eq(report.per_book["b2"].pending, 0, "b2 正常完成")
    T.eq(report.multi_book, true, "报告带多书标志(展示层据此不推导伪范围)")
end)

-- 评审五轮 P1#2:多书全部失败(章节列表请求失败)时整体必须报错并列出各书原因,
-- 不得返回一个「看起来成功」的空报告。
T.case("多书全部失败:整体报错并列出各书原因(P1#2)", function()
    local deps = {
        doc_path = "/books/合集.epub",
        book_ids = {"b1", "b2"},
        file_exists = function() return false end,
        rename = function() return true end,
        remove = function() return true end,
        api = { chapters = function(_, bid)
            error("章节列表请求失败:book=" .. tostring(bid))
        end},
        annotations = { fetch_chapter = function() return {} end },
        load_meta = function() return {spine={{href="c1"}}, has={}} end,
        read_text = function() return "" end,
        save_thoughts = function() return 0 end,
        inject = function() return {} end,
        progress = function() return true end,
    }
    local report, err = Sync.run(deps)
    T.ok(report == nil, "全部失败应整体报错")
    local e = tostring(err)
    T.ok(e:find("以下书同步失败", 1, true), "报错指明多书失败: " .. e)
    T.ok(e:find("b1", 1, true) and e:find("b2", 1, true), "报错列出失败书: " .. e)
end)

-- 评审五轮 P1#2:失败书状态落盘后(per_book.failed + pending=nil),再次同步重试
-- 失败书并成功;失败态不会让「继续拉取」入口消失,续传起点不丢。
T.case("多书章节列表失败后再次同步:重试失败书成功(P1#2)", function()
    local attempt = 0
    local deps = {
        doc_path = "/books/合集.epub",
        book_ids = {"b1", "b2"},
        file_exists = function() return false end,
        rename = function() return true end,
        remove = function() return true end,
        api = { chapters = function(_, bid)
            if bid == "b1" then
                attempt = attempt + 1
                if attempt == 1 then error("章节列表请求失败:网络超时") end
                return {data = {
                    {chapterUid=1,title="b1-1",chapterIdx=1},
                }}
            end
            return {data = {
                {chapterUid=1,title="b2-1",chapterIdx=1},
            }}
        end},
        annotations = { fetch_chapter = function(_, _, uid)
            return {underlines={{range="0-7",markText="春江潮水连海平"}}, review_map={}, review_groups={},
                underline_count=1, thought_count=0, thought_entry_count=0, errors={}}
        end},
        load_meta = function() return {spine={{href="c1"}}, has={}} end,
        read_text = function(_, href)
            return "<html><body><p>春江潮水连海平,海上明月共潮生。</p></body></html>"
        end,
        save_thoughts = function() return 0 end,
        inject = function() return {injected=1,marks=1,unmatched={},quote_aligned=1,dropped=0,underlines_resolved=1,thoughts_linked=0,thoughts_linked_by_uid={},merges={}} end,
        progress = function() return true end,
    }
    local r1 = Sync.run(deps)
    T.ok(r1, "首次:b2 成功,b1 软失败,整体仍出报告")
    T.ok(r1.per_book["b1"].failed == true, "首次 b1 失败态")
    T.ok(r1.per_book["b1"].pending == nil, "首次 b1 pending=nil(剩余未知)")
    T.eq(r1.per_book["b2"].pending, 0, "首次 b2 完成")
    local r2 = Sync.run(deps)
    T.ok(r2, "重试应成功")
    T.eq(r2.per_book["b1"].pending, 0, "重试后 b1 完成")
    T.ok(not r2.per_book["b1"].failed, "重试后 b1 无失败标记")
    T.eq(r2.per_book["b2"].pending, 0, "b2 保持完成")
end)


-- 评审六轮 P1#1(2026-08-20):未明确完成(.completed 已清除)时,已缓存章节必须重新注入,
-- 不能因旧完成标记开启 skip_resumed 而把"上次已拉取但尚未注入"的新缓存跳过。
-- 本用例与「已完成缓存续同步跳过旧章」互为对照:skip_resumed=false 时 resumed 缓存
-- 也进入注入(幂等重注入),保证上次中断未进 EPUB 的章节被补上。
T.case("缓存续同步:未明确完成(skip_resumed=false)时缓存章节重新注入", function()
    local rows = {}
    for i = 1, 5 do rows[i] = {chapterUid = i, title = "第" .. i .. "章", chapterIdx = i} end
    local deps, calls = make_deps({
        api = {chapters = function() return {chapters = rows} end},
        annotations = {
            fetch_chapter = function(_, _, uid)
                return {underlines = {{range = "0-7", markText = "春江潮水连海平"}},
                    review_map = {}, review_groups = {}, resumed = true,
                    underline_count = 1, thought_count = 0, thought_entry_count = 0, errors = {}}
            end,
        },
        skip_resumed = false,  -- 未明确完成:不清跳过语义
        fetch_budget = 5,
    })
    local report, err = Sync.run(deps)
    T.ok(report, "应成功: " .. tostring(err))
    T.eq(report.chapters_pending, 0, "无剩余")
    -- 关键:缓存章节全部重新注入(不因 resumed 而跳过),上次未注入的缓存被补上。
    T.ok(#calls.injected.mapped >= 5, "5 章缓存全部重新注入,而非被跳过")
end)
