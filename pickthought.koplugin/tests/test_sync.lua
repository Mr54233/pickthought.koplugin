local Sync = require("pickthought.sync")

local CH1_TEXT = "<html><body><p>春江潮水连海平,海上明月共潮生。</p></body></html>"
local CH2_TEXT = "<html><body><p>滟滟随波千万里,何处春江无月明。</p></body></html>"

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
        progress = function(phase, i, n, text, book_id)
            calls.progress[#calls.progress + 1] = {
                phase = phase, i = i, n = n, text = text, book_id = book_id,
            }
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
    T.eq(calls.progress[1].book_id, "b001", "单书章节列表进度携带书 ID")
    local fetch_progress
    for _, event in ipairs(calls.progress) do
        if event.phase == "fetch" then fetch_progress = event; break end
    end
    T.eq(fetch_progress.book_id, "b001", "单书拉取进度携带书 ID")
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

T.case("想法缓存写入失败不计入注入成功", function()
    local deps = make_deps({save_thoughts = function() return nil end})
    local report, err = Sync.run(deps)
    T.ok(report, "同步仍应完成: " .. tostring(err))
    T.eq(report.save_failures, 1, "记录想法缓存失败章节")
    T.eq(report.thoughts_injected, 0, "不可打开的想法不计成功")
    T.eq(report.thoughts_failed, 1, "不可打开的想法计入失败")
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

T.case("分批预算:拉满即收工,缓存命中免费", function()
    local rows = {}
    for i = 1, 10 do rows[i] = {chapterUid = i, title = "第" .. i .. "章", chapterIdx = i} end
    local network_calls = 0
    local deps, calls = make_deps({
        api = {chapters = function() return {data = rows} end},
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
        api = {chapters = function() return {data = rows} end},
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
        api = {chapters = function() return {data = rows} end},
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

T.case("连续硬失败触发断网熔断", function()
    local rows = {}
    for i = 1, 10 do rows[i] = {chapterUid = i, title = "第" .. i .. "章", chapterIdx = i} end
    local fetch_count = 0
    local deps, calls = make_deps({
        api = {chapters = function() return {data = rows} end},
        annotations = {
            fetch_chapter = function() fetch_count = fetch_count + 1; error("network request failed") end,
        },
    })
    local report, err = Sync.run(deps)
    T.ok(report == nil and tostring(err):find("连续", 1, true), "熔断报错: " .. tostring(err))
    T.ok(tostring(err):find("network request failed", 1, true), "熔断消息必须带真实错误: " .. tostring(err))
    T.eq(fetch_count, 3, "连续 3 章失败即中止,不磨完全书")
    T.eq(calls.injected, nil, "熔断后不注入")
end)

T.case("断点缓存命中不复位熔断计数", function()
    -- 缓存命中的章没有划线(不形成「贡献」),故不会触发「贡献后硬失败即停」分支;
    -- 连续硬失败计数不被缓存命中清零,3 次真实失败后熔断(评审四轮 P1#3 熔断语义)。
    local rows = {}
    for i = 1, 6 do rows[i] = {chapterUid = i, title = "第" .. i .. "章", chapterIdx = i} end
    local fetch_calls = 0
    local deps = make_deps({
        api = {chapters = function() return {data = rows} end},
        annotations = {
            fetch_chapter = function(_, _, uid)
                fetch_calls = fetch_calls + 1
                local n = tonumber(uid)
                if n % 2 == 0 then
                    -- 偶数章:断点缓存命中但无划线(不形成贡献,不触发即停分支)
                    return {underlines = {}, review_map = {}, review_groups = {},
                        resumed = true, underline_count = 0, thought_count = 0,
                        thought_entry_count = 0, errors = {}}
                end
                error("network request failed")
            end,
        },
    })
    local report, err = Sync.run(deps)
    T.ok(report == nil and tostring(err):find("连续", 1, true),
        "缓存命中(无贡献)穿插的连续网络失败仍应熔断: " .. tostring(err))
    T.ok(tostring(err):find("network request failed", 1, true), "熔断消息带真实错误")
    T.eq(fetch_calls, 5, "第 5 章(第 3 次真实失败)后中止")
end)

T.case("缓存命中后失败仍停在失败章节", function()
    -- 评审十轮 P1#1:上一章来自断点缓存(有划线,形成贡献),下一章网络请求失败时,
    -- 硬失败必须立即停在当前失败章,不得继续向后尝试(否则失败章被跳过、无法续传)。
    -- 失败章及后续章计入 pending,next_index 保持在失败章不递增。
    local rows = {}
    for i = 1, 5 do rows[i] = {chapterUid = i, title = "第" .. i .. "章", chapterIdx = i} end
    local fetch_calls = 0
    local deps = make_deps({
        api = {chapters = function() return {data = rows} end},
        annotations = {
            fetch_chapter = function(_, _, uid)
                fetch_calls = fetch_calls + 1
                local n = tonumber(uid)
                if n == 2 then
                    -- 第 2 章断点缓存命中(有划线,形成贡献)
                    return {underlines = {{range = "0-7", markText = "春江潮水连海平"}},
                        review_map = {}, review_groups = {}, resumed = true,
                        underline_count = 1, thought_count = 0, thought_entry_count = 0, errors = {}}
                end
                if n == 3 then error("network request failed") end  -- 缓存命中后失败
                return {underlines = {}, review_map = {}, review_groups = {},
                    underline_count = 0, thought_count = 0, thought_entry_count = 0, errors = {}}
            end,
        },
    })
    local report, err = Sync.run(deps)
    T.ok(report, "部分提交(第 2 章已注入): " .. tostring(err))
    T.eq(fetch_calls, 3, "第 3 章(缓存命中后)硬失败即停,不继续磨")
    local pb = report.per_book and report.per_book["b001"]
    T.ok(pb, "存在逐书状态")
    T.eq(pb.failed, true, "第 3 章失败标记本书未完成")
    T.eq(pb.next_index, 3, "续传游标停在第 3 章(失败章)")
    T.eq(pb.pending, 5 - 3 + 1, "待处理含第 3 章起剩余章")
    T.eq(report.chapters_pending, 5 - 3 + 1, "聚合 pending 与逐书一致")
    T.eq(pb.thought_save_incomplete or false, false, "本例非想法失败,不误标")
end)

T.case("末尾连续失败且成功章节无划线时报拉取失败而非无划线", function()
    local rows = {}
    for i = 1, 4 do rows[i] = {chapterUid = i, title = "第" .. i .. "章", chapterIdx = i} end
    local deps = make_deps({
        api = {chapters = function() return {data = rows} end},
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

T.case("想法缓存写失败计入 save_failures 不计入 thoughts_saved", function()
    local deps, _ = make_deps({
        save_thoughts = function() return nil, "磁盘满" end,
    })
    local report, err = Sync.run(deps)
    T.ok(report, "应成功: " .. tostring(err))
    T.eq(report.thoughts_saved, 0, "写失败不算保存成功")
    T.eq(report.save_failures, 1, "写失败计数")
end)

T.case("想法缓存写入失败保留续传位置且不生成完成标记", function()
    -- 评审十轮 P1#2:本批最后一章想法缓存写入失败时,划线已注入,但本书未完成——
    -- 须保留当前章续传位置、pending 非 0、标记想法写入未完成,使 sync_task(其 .completed
    -- 门禁为「not pb.failed 且 pending==0」)不会生成 .completed,下次同步从失败章续传。
    local rows = {}
    for i = 1, 3 do rows[i] = {chapterUid = i, title = "第" .. i .. "章", chapterIdx = i} end
    local deps = make_deps({
        api = {chapters = function() return {data = rows} end},
        annotations = {
            fetch_chapter = function(_, _, uid)
                if tostring(uid) == "3" then
                    return {underlines = {{range = "0-7", markText = "春江潮水连海平"}},
                        review_map = {["0-7"] = {{content = "好句", author = "甲"}}},
                        review_groups = {{range = "0-7", texts = {{content = "好句", author = "甲"}}}},
                        underline_count = 1, thought_count = 1, thought_entry_count = 1, errors = {}}
                end
                return {underlines = {}, review_map = {}, review_groups = {},
                    underline_count = 0, thought_count = 0, thought_entry_count = 0, errors = {}}
            end,
        },
        save_thoughts = function() return nil, "磁盘满" end,
    })
    local report, err = Sync.run(deps)
    T.ok(report, "应部分成功(划线已注入): " .. tostring(err))
    T.eq(report.save_failures, 1, "记录想法缓存失败")
    local pb = report.per_book and report.per_book["b001"]
    T.ok(pb, "存在逐书状态")
    T.eq(pb.failed, true, "本书标记未完成(禁止 .completed)")
    T.eq(pb.thought_save_incomplete, true, "想法写入失败标记")
    T.eq(pb.next_index, 3, "续传游标停在末章(失败章)")
    T.eq(pb.pending, 1, "末章想法待重试,pending=1")
    T.eq(report.chapters_pending, 1, "聚合 pending=1")
end)

T.case("想法缓存失败按复合键扣除,多书同 uid 不串", function()
    -- 评审十轮 P1#2:两本微信读书书共享 chapter_uid=1,仅 A 本想法缓存写入失败。
    -- 扣除须用 book_id+uid 复合键,不能把 B 本成功想法错计为失败、也不能漏扣 A 本失败想法
    -- (epub_inject 的 thoughts_linked_by_uid 已按复合键统计,sync.lua 扣除侧须对齐)。
    local rows = {}
    for i = 1, 2 do rows[i] = {chapterUid = i, title = "第" .. i .. "章", chapterIdx = i} end
    local deps, calls = make_deps({
        book_ids = {"A", "B"},
        api = {chapters = function() return {data = rows} end},
        annotations = {
            fetch_chapter = function(_, bid, uid)
                local n = tonumber(uid)
                if tostring(bid) == "A" and n == 1 then
                    return {underlines = {{range = "0-7", markText = "春江潮水连海平"}},
                        review_map = {["0-7"] = {{content = "A句", author = "甲"}}},
                        review_groups = {{range = "0-7", texts = {{content = "A句", author = "甲"}}}},
                        underline_count = 1, thought_count = 1, thought_entry_count = 1, errors = {}}
                elseif tostring(bid) == "B" and n == 1 then
                    return {underlines = {{range = "0-7", markText = "春江潮水连海平"}},
                        review_map = {["0-7"] = {{content = "B句", author = "乙"}}},
                        review_groups = {{range = "0-7", texts = {{content = "B句", author = "乙"}}}},
                        underline_count = 1, thought_count = 1, thought_entry_count = 1, errors = {}}
                end
                return {underlines = {}, review_map = {}, review_groups = {},
                    underline_count = 0, thought_count = 0, thought_entry_count = 0, errors = {}}
            end,
        },
        save_thoughts = function(bid, uid)
            if tostring(bid) == "A" and tostring(uid) == "1" then return nil, "磁盘满" end
            return 1
        end,
        inject = function(src, book_id, mapped, dest, options)
            -- 复合键统计,与 epub_inject 真实实现一致(A/1、B/1 各 1 条想法)
            return {injected = #mapped, marks = #mapped, unmatched = {}, quote_aligned = #mapped,
                dropped = 0, underlines_resolved = #mapped, thoughts_linked = 2,
                thoughts_linked_by_uid = {["A/1"] = 1, ["B/1"] = 1}, merges = {}}
        end,
    })
    local report, err = Sync.run(deps)
    T.ok(report, "多书应部分成功: " .. tostring(err))
    T.eq(report.save_failures, 1, "只 A 本第 1 章想法缓存失败")
    -- 复合键扣除:A 本失败想法被扣,B 本成功想法保留 → 注入成功想法 = 2 - 1 = 1
    T.eq(report.thoughts_injected, 1, "按复合键扣除后只计 B 本成功想法")
    T.eq(report.thoughts_failed, 1, "A 本失败想法计入失败")
    local pbA = report.per_book and report.per_book["A"]
    T.ok(pbA and pbA.thought_save_incomplete, "A 本标记想法写入未完成(禁止 .completed)")
end)

T.case("多书进度回调按顺序携带当前书 ID", function()
    local deps, calls = make_deps({
        book_ids = {"b001", "b002"},
        api = {chapters = function(_, bid)
            return {data = {
                {chapterUid = 1, title = "第一章(" .. tostring(bid) .. ")", chapterIdx = 1},
                {chapterUid = 2, title = "第二章(" .. tostring(bid) .. ")", chapterIdx = 2},
            }}
        end},
    })
    local report, err = Sync.run(deps)
    T.ok(report, "多书同步应成功: " .. tostring(err))
    local chapter_events, fetch_events = {}, {}
    for _, event in ipairs(calls.progress) do
        if event.phase == "chapters" then chapter_events[#chapter_events + 1] = event end
        if event.phase == "fetch" then fetch_events[#fetch_events + 1] = event end
    end
    T.eq(#chapter_events, 2, "两本书各产生章节列表进度")
    T.eq(chapter_events[1].book_id, "b001", "第一本章节列表进度带书 ID")
    T.eq(chapter_events[2].book_id, "b002", "第二本章节列表进度带书 ID")
    T.eq(#fetch_events, 4, "两本书各两章产生拉取进度")
    T.eq(fetch_events[1].book_id, "b001", "第一本拉取进度带书 ID")
    T.eq(fetch_events[3].book_id, "b002", "第二本拉取进度带书 ID")
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
end)

T.case("自适应资源预算停在章节边界并保留续传游标", function()
    local rows = {}
    for i = 1, 4 do rows[i] = {chapterUid = i, title = "第一章", chapterIdx = i} end
    local fetches = 0
    local deps, calls = make_deps({
        api = {chapters = function() return {data = rows} end},
        annotations = {
            fetch_chapter = function()
                fetches = fetches + 1
                return {
                    underlines = {{range = "0-7", markText = "春江潮水连海平"}},
                    review_map = {["0-7"] = {{content = "想法", abstract = "春江潮水连海平"}}},
                    review_groups = {{range = "0-7", texts = {{content = "想法"}}}},
                    underline_count = 1, thought_count = 1, thought_entry_count = 1, errors = {},
                }
            end,
        },
        max_batch_thought_entries = 1,
    })
    local report, err = Sync.run(deps)
    T.ok(report, "预算触发后已有章节仍应注入: " .. tostring(err))
    T.eq(fetches, 1, "达到想法预算后不再拉下一章")
    T.eq(report.chapters_pending, 3, "剩余章节计入 pending")
    T.eq(report.next_index, 2, "下一次从第二章继续")
    T.ok(tostring(report.batch_budget_reason):find("想法", 1, true), "报告记录预算原因")
    T.eq(#calls.injected.mapped, 1, "预算停止前的章节正常注入")
end)
