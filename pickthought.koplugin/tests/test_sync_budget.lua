local SyncBudget = require("pickthought.sync_budget")

T.case("轻量章节数据保留想法计数和摘要但释放正文", function()
    local data = {
        book_id = "b1", chapter_uid = "9",
        underlines = {{range = "0-7", markText = "正文引文"}},
        review_map = { ["0-7"] = {
            {content = "第一条很长的想法正文", abstract = "正文引文摘要", author = "甲", review_id = "r1"},
            {content = "第二条很长的想法正文", abstract = "", author = "乙", review_id = "r2"},
        }},
        review_groups = {{range = "0-7", texts = {
            {content = "第一条很长的想法正文"}, {content = "第二条很长的想法正文"},
        }}},
        underline_count = 1, thought_count = 1, thought_entry_count = 2,
    }
    local compact = SyncBudget.compact(data)
    T.eq(compact.thought_count_by_range["0-7"], 2, "保存 range 的真实想法数量")
    T.ok(compact.thought_ranges["0-7"], "保存想法 range 存在性")
    T.eq(#compact.review_map["0-7"], 1, "只保留首条摘要")
    T.eq(compact.review_map["0-7"][1].abstract, "正文引文摘要", "保留引文回退摘要")
    T.eq(compact.review_map["0-7"][1].content, nil, "不保留想法正文")
    T.eq(compact.thought_entry_count, 2, "保留总想法条目数")
end)

T.case("重复压缩缓存不会把想法数降成摘要哨兵数", function()
    local compact = SyncBudget.compact({
        underlines = {{range = "0-1"}},
        review_map = {["0-1"] = {{abstract = "摘要"}}},
        thought_count_by_range = {["0-1"] = 7},
        thought_ranges = {["0-1"] = true},
        thought_count = 1, thought_entry_count = 7,
    })
    T.eq(compact.thought_count_by_range["0-1"], 7, "续传保持真实 range 计数")
end)

T.case("批次预算按想法条目停止在章节边界", function()
    local budget = SyncBudget:new{
        max_cache_bytes = 1024 * 1024,
        max_underlines = 100,
        max_thought_entries = 3,
        min_available_kb = 1,
    }
    local ok = budget:can_fetch()
    T.ok(ok, "第一章允许开始")
    budget:account({cache_bytes = 100, underline_count = 1, thought_entry_count = 3})
    local next_ok, reason = budget:can_fetch()
    T.ok(not next_ok, "达到想法预算后停止下一章")
    T.ok(tostring(reason):find("想法", 1, true), "预算原因明确")
    local summary = budget:summary()
    T.eq(summary.thought_entries, 3, "预算统计想法条目")
end)

T.case("可用内存低于安全线时阻止新批次", function()
    local budget = SyncBudget:new{
        max_cache_bytes = 1024 * 1024, max_underlines = 100,
        max_thought_entries = 100, min_available_kb = 100,
        read_memory_available_kb = function() return 50 end,
    }
    local ok, reason, available = budget:can_fetch()
    T.ok(not ok, "低内存不开始批次")
    T.eq(available, 50, "记录实时可用内存")
    T.ok(tostring(reason):find("安全线", 1, true), "低内存原因明确")
end)

T.case("默认内存安全线为 128MB", function()
    T.eq(SyncBudget.DEFAULTS.min_available_kb, 128 * 1024, "为映射和注入预留余量")
    T.eq(SyncBudget.DEFAULTS.max_thought_entries, 150000, "允许历史 200 章想法规模")
    T.eq(SyncBudget.DEFAULTS.max_underlines, 20000, "允许历史 200 章划线规模")
end)

T.case("运行时预算不使用压缩缓存大小代替完整数据估算", function()
    local data = {
        cache_bytes = 10,
        underlines = {{range = "0-1"}},
        review_map = {["0-1"] = {{content = string.rep("想法正文", 100)}}},
        review_groups = {{texts = {{content = string.rep("想法正文", 100)}}}},
    }
    T.ok(SyncBudget.estimate_bytes(data) > 1000, "按完整运行时数据估算")
end)
