local SyncReport = require("pickthought.sync_report")

local function render(report)
    return table.concat(SyncReport.build(report), "\n")
end

T.case("同步报告展示本批、注入与下一批进度", function()
    local text = render{
        batch_start = 601, batch_end = 800,
        chapters_processed = 200, chapters_fetch_succeeded = 200,
        chapters_total = 1615, chapters_pending = 815,
        next_index = 801, batch_limit = 200,
        total_underlines = 3233, total_thought_entries = 8592,
        underlines_injected = 3232, thoughts_injected = 8500,
        unmatched = {}, fetch_errors = 0, save_failures = 0,
        backup = "/mnt/us/book/神秘复苏.epub.orig",
    }
    T.ok(text:find("拉取范围：第 601–800 章", 1, true), "显示本批章节范围")
    T.ok(text:find("拉取成功：200/200 章（100%）", 1, true), "显示章节成功率")
    T.ok(text:find("注入进度：已处理到第 800 章", 1, true), "显示注入终点")
    T.ok(text:find("拉取到：划线 3,233 条，想法 8,592 条", 1, true), "显示本批拉取量")
    T.ok(text:find("注入成功：划线 3,232 条，想法 8,500 条", 1, true), "显示注入成功量")
    T.ok(text:find("注入失败：划线 1 条，想法 92 条", 1, true), "显示注入失败量")
    T.ok(text:find("注入成功率：划线 99.97%，想法 98.93%", 1, true), "分别显示成功率")
    T.ok(text:find("已处理：800/1,615 章（49.5%）", 1, true), "显示全书已处理进度")
    T.ok(text:find("未拉取：815 章（50.5%）", 1, true), "显示全书未拉取进度")
    T.ok(text:find("下一批：第 801–1,000 章，共 200 章", 1, true), "显示下一批范围")
    T.ok(text:find("菜单「继续拉取后续章节」手动拉，或继续阅读时自动补", 1, true),
        "保留继续同步提示")
    T.ok(text:find("已替换原书(阅读进度保留)", 1, true), "保留替换提示")
    T.ok(text:find("原版备份:/mnt/us/book/神秘复苏.epub.orig", 1, true), "保留备份路径")
end)

T.case("同步报告最后一批不再提示下一批", function()
    local text = render{
        batch_start = 1601, batch_end = 1615,
        chapters_processed = 15, chapters_fetch_succeeded = 15,
        chapters_total = 1615, chapters_pending = 0,
        next_index = 1616, batch_limit = 200,
        total_underlines = 10, total_thought_entries = 0,
        underlines_injected = 10, thoughts_injected = 0,
        unmatched = {}, backup = "book.epub.orig",
    }
    T.ok(text:find("全部章节已处理完成", 1, true), "末批显示完成")
    T.ok(not text:find("下一批：", 1, true), "末批不显示下一批")
    T.ok(text:find("注入成功率：划线 100.00%，想法 --", 1, true), "无想法时不伪造成功率")
end)

T.case("询问模式的完成报告不误称自动补", function()
    local text = table.concat(SyncReport.build({
        batch_start = 1, batch_end = 200,
        chapters_processed = 200, chapters_fetch_succeeded = 200,
        chapters_total = 1000, chapters_pending = 800,
        next_index = 201, batch_limit = 200,
        total_underlines = 1, underlines_injected = 1,
        total_thought_entries = 0, thoughts_injected = 0,
        unmatched = {}, backup = "book.epub.orig",
    }, {auto_batch = false}), "\n")
    T.ok(text:find("阅读到边界时按提示后台补", 1, true), "关闭自动后说明询问模式")
    T.ok(not text:find("继续阅读时自动补", 1, true), "关闭自动后不误称自动拉取")
end)
