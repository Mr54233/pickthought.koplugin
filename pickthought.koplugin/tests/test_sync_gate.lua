local SyncGate = require("pickthought.sync_gate")

T.case("同步门禁识别活动 worker", function()
    T.ok(SyncGate.busy({busy = function() return true end}), "活动任务阻止破坏性操作")
    T.ok(not SyncGate.busy({busy = function() return false end}), "空闲任务允许操作")
    T.ok(not SyncGate.busy(nil), "没有任务对象允许操作")
end)

T.case("自动同步确认上下文必须仍是同一本书", function()
    local document = {}
    local context = SyncGate.capture(document, "/books/a.epub", "book-a")
    T.ok(SyncGate.matches(context, document, "/books/a.epub", "book-a"), "原书上下文有效")
    T.ok(not SyncGate.matches(context, {}, "/books/a.epub", "book-a"), "切换文档后失效")
    T.ok(not SyncGate.matches(context, document, "/books/b.epub", "book-a"), "切换路径后失效")
    T.ok(not SyncGate.matches(context, document, "/books/a.epub", "book-b"), "重新绑定后失效")
end)

T.case("文件管理器上下文不要求 reader document", function()
    local context = SyncGate.capture(nil, "/books/a.epub", "book-a")
    T.ok(SyncGate.matches(context, nil, "/books/a.epub", "book-a"), "文管路径上下文有效")
    T.ok(not SyncGate.matches(context, nil, "/books/a.epub", "book-b"), "文管绑定变化后失效")
end)
