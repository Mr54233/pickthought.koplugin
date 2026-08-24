local BatchSync = require("pickthought.batch_sync")

T.case("分批自动拉取必须由用户显式开启", function()
    T.eq(BatchSync.DEFAULT_AUTO, false, "新开关默认关闭")
    T.ok(not BatchSync.auto_enabled({}), "缺省为询问模式")
    T.ok(not BatchSync.auto_enabled({auto_batch_sync = true}), "不继承旧版默认开启值")
    T.ok(BatchSync.auto_enabled({auto_batch_sync_opt_in = true}), "新开关显式开启后才自动")
end)

T.case("首次与续批使用同一套计划范围", function()
    local first = BatchSync.plan(nil, 200)
    T.eq(first.start_index, 1, "首次从第 1 章开始")
    T.eq(first.end_index, 200, "首次计划到第 200 章")
    T.eq(first.count, 200, "首次最多 200 章")
    T.ok(BatchSync.prompt_text(first, false):find("若全书不足，以实际末章为准", 1, true),
        "首次未知总章数时不虚报实际末章")

    local next_batch = BatchSync.plan({total = 1615, pending = 1415, next_index = 201}, 200)
    T.eq(next_batch.start_index, 201, "续批只认同步游标")
    T.eq(next_batch.end_index, 400, "续批固定 200 章")
    T.eq(next_batch.processed_to, 200, "当前已处理到第 200 章")
    local text = BatchSync.prompt_text(next_batch, true)
    T.ok(text:find("从第 201 章开始，拉取并注入到第 400 章", 1, true), "明确计划起止章")
    T.ok(text:find("本批共 200 章，全书还剩 1,415 章未拉取", 1, true), "明确本批和剩余章数")
    T.ok(text:find("同步将在后台进行，不影响继续阅读", 1, true), "阅读确认明确后台执行")
end)

T.case("计划范围支持旧状态回退与最后不足一批", function()
    local recovered = BatchSync.plan({total = 1000, pending = 600}, 200)
    T.eq(recovered.start_index, 401, "缺 next_index 时由 total-pending 恢复连续游标")
    T.eq(recovered.end_index, 600, "恢复后仍按单批上限")

    local last = BatchSync.plan({total = 1615, pending = 15, next_index = 1601}, 200)
    T.eq(last.start_index, 1601, "最后一批起点")
    T.eq(last.end_index, 1615, "最后一批不越过全书末章")
    T.eq(last.count, 15, "最后一批实际 15 章")
    T.eq(BatchSync.plan({total = 1615, pending = 0, next_index = 1616}, 200), nil,
        "没有待拉章节时不生成计划")
end)

T.case("任务运行时阅读到边界也绝不重复启动", function()
    local offer, reason = BatchSync.should_offer{
        busy = true,
        state = {total = 1615, pending = 1415, next_index = 201},
        batch_limit = 200, page = 200, total_pages = 1615,
    }
    T.eq(offer, false, "忙碌时不触发")
    T.eq(reason, "busy", "返回明确互斥原因")
end)

T.case("优先使用 EPUB 结构片段而不是失真的页数比例", function()
    T.eq(BatchSync.fragment_index("/body/DocFragment[206]/body/div/p.0"), 206,
        "解析带序号 DocFragment")
    T.eq(BatchSync.fragment_index("/body/DocFragment/body/p.0"), 1,
        "首个 DocFragment 无序号时按 1")
    T.eq(BatchSync.fragment_index("/body/div/p.0"), nil, "非 EPUB 结构不误判")

    local page_estimate = BatchSync.estimate_read_chapter(1383, 12991, 1615)
    T.eq(page_estimate, 172, "真机页数比例会把第 201 章错估为 172")
    local fragment_estimate = BatchSync.estimate_read_chapter(1383, 12991, 1615, 206, 1640)
    T.eq(fragment_estimate, 203, "结构片段进度恢复到约第 203 章")

    local offer, context = BatchSync.should_offer{
        state = {total = 1615, pending = 1415, next_index = 201},
        batch_limit = 200,
        page = 1383, total_pages = 12991,
        fragment = 206, fragment_total = 1640,
    }
    T.ok(offer, "真机第 201 章应触发续批询问")
    T.eq(context.plan.start_index, 201, "仍从连续同步游标开始")
end)

T.case("拿不到结构片段时保留页数比例回退", function()
    local offer = BatchSync.should_offer{
        state = {total = 1000, pending = 800, next_index = 201},
        batch_limit = 200, page = 200, total_pages = 1000,
    }
    T.ok(offer, "非 crengine 或结构读取失败时仍可按页数触发")
end)

T.case("拒绝一次后跨到下一阅读批次才再次询问", function()
    local state = {total = 1615, pending = 1415, next_index = 201}
    local before, reason = BatchSync.should_offer{
        state = state, batch_limit = 200, page = 199, total_pages = 1615,
    }
    T.eq(before, false, "未到已同步末章不提示")
    T.eq(reason, "before_boundary", "边界前原因")

    local offer, context = BatchSync.should_offer{
        state = state, batch_limit = 200, page = 200, total_pages = 1615,
    }
    T.ok(offer, "读到第 200 章提示下一批")
    T.eq(context.plan.start_index, 201, "提示拉取第 201 章起")
    T.eq(context.bucket, 2, "拒绝覆盖即将进入的第二阅读批次")
    local dismissed = BatchSync.dismissal(context)

    for _, page in ipairs({201, 300, 400}) do
        local again = BatchSync.should_offer{
            state = state, batch_limit = 200, page = page, total_pages = 1615,
            dismissed = dismissed,
        }
        T.eq(again, false, "第二阅读批次内不重复询问:" .. tostring(page))
    end
    local again, next_context = BatchSync.should_offer{
        state = state, batch_limit = 200, page = 401, total_pages = 1615,
        dismissed = dismissed,
    }
    T.ok(again, "进入第三阅读批次再次询问")
    T.eq(next_context.plan.start_index, 201, "跳读后仍从旧同步游标补齐")
    T.eq(next_context.plan.end_index, 400, "一次确认仍只补一个固定批次")
end)

T.case("补完落后批次后按新游标继续且不受旧拒绝记录影响", function()
    local old_dismissal = {bucket = 2, total = 1615, batch_limit = 200}
    local offer, context = BatchSync.should_offer{
        state = {total = 1615, pending = 1215, next_index = 401},
        batch_limit = 200, page = 402, total_pages = 1615,
        dismissed = old_dismissal,
    }
    T.ok(offer, "用户仍在新同步边界之后时可继续询问")
    T.eq(context.plan.start_index, 401, "第二次确认补第 401 章起")
    T.eq(context.plan.end_index, 600, "不跳章也不突破 200 章上限")

    local changed_book = BatchSync.should_offer{
        state = {total = 1700, pending = 1500, next_index = 201},
        batch_limit = 200, page = 401, total_pages = 1700,
        dismissed = old_dismissal,
    }
    T.ok(changed_book, "章节总数变化后旧拒绝记录失效")
end)

T.case("自动模式提示也明确本批范围", function()
    local text = BatchSync.background_text(BatchSync.plan({
        total = 1615, pending = 1415, next_index = 201,
    }, 200))
    T.eq(text, "正在后台拉取并注入第 201–400 章…", "自动启动短提示范围明确")
end)
