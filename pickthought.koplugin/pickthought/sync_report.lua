local M = {}

local function number(value)
    return math.max(0, math.floor(tonumber(value) or 0))
end

local function integer(value)
    local text = tostring(number(value)):reverse():gsub("(%d%d%d)", "%1,"):reverse()
    text = text:gsub("^,", "")
    return text
end

local function percent(done, total, decimals, trim_zero)
    done, total = number(done), number(total)
    if total == 0 then return "--" end
    local value = math.min(100, done / total * 100)
    local text = string.format("%." .. tostring(decimals) .. "f", value)
    if trim_zero then text = text:gsub("%.0+$", "") end
    return text .. "%"
end

function M.build(report, options)
    report = report or {}
    options = options or {}
    local total = number(report.chapters_total)
    local pending = math.min(total, number(report.chapters_pending))
    local processed_total = total - pending
    local batch_count = number(report.chapters_processed)
    local batch_end = number(report.batch_end)
    local batch_start = number(report.batch_start)
    if batch_count > 0 and batch_end == 0 then batch_end = processed_total end
    if batch_count > 0 and batch_start == 0 then batch_start = batch_end - batch_count + 1 end

    local total_underlines = number(report.total_underlines)
    local total_thoughts = number(report.total_thought_entries)
    local underlines_injected = math.min(total_underlines, number(report.underlines_injected))
    local thoughts_injected = math.min(total_thoughts, number(report.thoughts_injected))
    local underlines_failed = total_underlines - underlines_injected
    local thoughts_failed = total_thoughts - thoughts_injected

    local lines = {
        "同步完成",
        "",
        "本批章节",
    }
    local function book_label(bid)
        local label = options.titles and options.titles[tostring(bid)]
        label = type(label) == "string" and label:gsub("^%s+", ""):gsub("%s+$", "") or ""
        return label ~= "" and label or "绑定书目"
    end
    local book_count = number(report.book_count)
    if book_count == 0 and type(report.per_book) == "table" then
        for _ in pairs(report.per_book) do book_count = book_count + 1 end
    end
    -- 多书:不同远程书章节坐标独立,不推导单一连续范围(评审五轮 P1#1),
    -- 只展示聚合数量;逐书真实 range/pending/next_index 见下方「逐书明细」。
    if report.multi_book then
        lines[#lines + 1] = string.format("本批共 %s 章（%s 个绑定书目合计）",
            integer(batch_count), integer(book_count))
        lines[#lines + 1] = string.format("拉取成功：%s/%s 章（%s）",
            integer(report.chapters_fetch_succeeded), integer(batch_count),
            percent(report.chapters_fetch_succeeded, batch_count, 1, true))
        lines[#lines + 1] = string.format("注入进度：已处理 %s 章（绑定书目合计）", integer(processed_total))
    else
        lines[#lines + 1] = string.format("拉取范围：第 %s–%s 章", integer(batch_start), integer(batch_end))
        lines[#lines + 1] = string.format("拉取成功：%s/%s 章（%s）",
            integer(report.chapters_fetch_succeeded), integer(batch_count),
            percent(report.chapters_fetch_succeeded, batch_count, 1, true))
        lines[#lines + 1] = string.format("注入进度：已处理到第 %s 章", integer(batch_end))
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "本批数据"
    lines[#lines + 1] = string.format("拉取到：划线 %s 条，想法 %s 条",
        integer(total_underlines), integer(total_thoughts))
    lines[#lines + 1] = string.format("注入成功：划线 %s 条，想法 %s 条",
        integer(underlines_injected), integer(thoughts_injected))
    lines[#lines + 1] = string.format("注入失败：划线 %s 条，想法 %s 条",
        integer(underlines_failed), integer(thoughts_failed))
    lines[#lines + 1] = string.format("注入成功率：划线 %s，想法 %s",
        percent(underlines_injected, total_underlines, 2),
        percent(thoughts_injected, total_thoughts, 2))
    lines[#lines + 1] = ""
    lines[#lines + 1] = report.multi_book and "已绑定书目进度" or "全书进度"
    lines[#lines + 1] = string.format("已处理：%s/%s 章（%s）",
        integer(processed_total), integer(total), percent(processed_total, total, 1, true))
    lines[#lines + 1] = string.format("未拉取：%s 章（%s）",
        integer(pending), percent(pending, total, 1, true))

    if pending > 0 then
        local next_start = number(report.next_index)
        if next_start == 0 then next_start = processed_total + 1 end
        local batch_limit = number(report.batch_limit)
        if batch_limit == 0 then batch_limit = 200 end
        local next_count = math.min(pending, batch_limit)
        if report.multi_book then
            -- 多书:续传位置逐书独立,不生成跨书「第 a–b 章」伪范围(评审五轮 P1#1)。
            lines[#lines + 1] = string.format("下一批：共 %s 章（逐书续传位置见明细）", integer(next_count))
        else
            local next_end = next_start + next_count - 1
            lines[#lines + 1] = string.format("下一批：第 %s–%s 章，共 %s 章",
                integer(next_start), integer(next_end), integer(next_count))
        end
        lines[#lines + 1] = ""
        lines[#lines + 1] = options.auto_batch == false
            and "菜单「继续拉取后续章节」手动拉，或阅读到边界时按提示后台补"
            or "菜单「继续拉取后续章节」手动拉，或继续阅读时自动补"
    elseif report.failed_books and #report.failed_books > 0 then
        -- 存在失败书/剩余未知书:不得显示「全部章节已处理完成」(评审六轮 P1#2)——否则
        -- 与逐书明细里「某本书同步失败」前后矛盾。明确列出失败书。
        local f = {}
        for _, bid in ipairs(report.failed_books) do
            f[#f + 1] = book_label(bid)
        end
        lines[#lines + 1] = "有书同步失败/剩余未知：" .. table.concat(f, "、")
    elseif report.deferred_books and #report.deferred_books > 0 then
        -- 冷却书部分缓存命中、剩余章 deferred(评审八轮 P1#1):非失败但非真正完成,
        -- 明确标「暂缓」,不得显示「全部章节已处理完成」。
        local f = {}
        for _, bid in ipairs(report.deferred_books) do
            f[#f + 1] = book_label(bid)
        end
        lines[#lines + 1] = "有书同步暂缓：" .. table.concat(f, "、")
    else
        lines[#lines + 1] = report.multi_book and "全部已绑定书目章节已处理完成" or "全部章节已处理完成"
    end

    -- 逐书明细(P1#4):多书绑定时,聚合状态之外再列出每本书的进度与失败,
    -- 避免只显示第一本而漏掉其他书的待同步内容。单书不重复展示。
    local per_book = report.per_book
    if type(per_book) == "table" then
        local bids = {}
        for bid in pairs(per_book) do bids[#bids + 1] = bid end
        table.sort(bids)
        if #bids > 1 then
            lines[#lines + 1] = ""
            lines[#lines + 1] = "逐书明细"
            for _, bid in ipairs(bids) do
                local pb = per_book[bid] or {}
                local label = book_label(bid)
                local p = number(pb.pending)
                local t = number(pb.total)
                local nx = number(pb.next_index)
                if pb.failed then
                    lines[#lines + 1] = string.format("· %s：同步失败（%s）", label,
                        tostring(pb.error or "未知错误"))
                elseif pb.deferred then
                    -- 冷却书部分缓存命中、剩余章 deferred(评审八轮 P1#1):明确标「暂缓」,
                    -- 不显示为「还剩 N 章」的普通待拉取,也不与「已完成」混淆。
                    lines[#lines + 1] = string.format("· %s：限速冷却中，暂缓 %s 章（续传第 %s 章）",
                        label, integer(p), integer(nx))
                elseif p > 0 then
                    lines[#lines + 1] = string.format("· %s：已处理 %s/%s 章，还剩 %s 章（续传第 %s 章）",
                        label, integer(t - p), integer(t), integer(p), integer(nx))
                else
                    lines[#lines + 1] = string.format("· %s：%s/%s 章已完成", label, integer(t), integer(t))
                end
            end
        end
    end

    if #(report.unmatched or {}) > 0 then
        lines[#lines + 1] = string.format("有 %s 章未匹配本地正文", integer(#report.unmatched))
    end
    if number(report.fetch_errors) > 0 then
        lines[#lines + 1] = string.format("有 %s 章未拉全，重新同步可补", integer(report.fetch_errors))
    end
    if report.rate_limited then
        lines[#lines + 1] = "微信读书触发频率限制，本批已提前停止；稍后重试即可继续"
    end
    if number(report.save_failures) > 0 then
        lines[#lines + 1] = string.format("有 %s 章想法缓存写入失败，请检查存储空间",
            integer(report.save_failures))
    end
    -- 成功收尾时暂存清理失败的警告(作者 2026-08-20 第7轮意见③):残留的 .orig.old
    -- 可能被后续误当有效旧备份,须明确提示。
    if type(report.cleanup_warnings) == "table" and #report.cleanup_warnings > 0 then
        lines[#lines + 1] = string.format("有 %s 项暂存文件清理失败(不影响本次结果):",
            integer(#report.cleanup_warnings))
        for _, w in ipairs(report.cleanup_warnings) do
            lines[#lines + 1] = "· " .. tostring(w)
        end
    end

    lines[#lines + 1] = ""
    -- 作者第8轮:原始干净书被暂存为 .old 并保留时,明确提示其位置与恢复方式,
    -- 避免用户以为原书已被销毁、也防止后续误当脏暂存清理。
    if report.kept_original then
        lines[#lines + 1] = "原始干净书已保留(未删除):" .. tostring(report.kept_original)
        lines[#lines + 1] = "如需恢复原书,请手动将该文件重命名为原书名(.epub)"
    end
    lines[#lines + 1] = "已替换原书(阅读进度保留)"
    lines[#lines + 1] = "原版备份:" .. tostring(report.backup or "")
    return lines
end

return M
