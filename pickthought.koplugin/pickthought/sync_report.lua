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
        string.format("拉取范围：第 %s–%s 章", integer(batch_start), integer(batch_end)),
        string.format("拉取成功：%s/%s 章（%s）",
            integer(report.chapters_fetch_succeeded), integer(batch_count),
            percent(report.chapters_fetch_succeeded, batch_count, 1, true)),
        string.format("注入进度：已处理到第 %s 章", integer(batch_end)),
        "",
        "本批数据",
        string.format("拉取到：划线 %s 条，想法 %s 条",
            integer(total_underlines), integer(total_thoughts)),
        string.format("注入成功：划线 %s 条，想法 %s 条",
            integer(underlines_injected), integer(thoughts_injected)),
        string.format("注入失败：划线 %s 条，想法 %s 条",
            integer(underlines_failed), integer(thoughts_failed)),
        string.format("注入成功率：划线 %s，想法 %s",
            percent(underlines_injected, total_underlines, 2),
            percent(thoughts_injected, total_thoughts, 2)),
        "",
        "全书进度",
        string.format("已处理：%s/%s 章（%s）",
            integer(processed_total), integer(total), percent(processed_total, total, 1, true)),
        string.format("未拉取：%s 章（%s）",
            integer(pending), percent(pending, total, 1, true)),
    }

    if pending > 0 then
        local next_start = number(report.next_index)
        if next_start == 0 then next_start = processed_total + 1 end
        local batch_limit = number(report.batch_limit)
        if batch_limit == 0 then batch_limit = 200 end
        local next_count = math.min(pending, batch_limit)
        local next_end = next_start + next_count - 1
        lines[#lines + 1] = string.format("下一批：第 %s–%s 章，共 %s 章",
            integer(next_start), integer(next_end), integer(next_count))
        lines[#lines + 1] = ""
        lines[#lines + 1] = options.auto_batch == false
            and "菜单「继续拉取后续章节」手动拉，或阅读到边界时按提示后台补"
            or "菜单「继续拉取后续章节」手动拉，或继续阅读时自动补"
    else
        lines[#lines + 1] = "全部章节已处理完成"
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
    lines[#lines + 1] = "已替换原书(阅读进度保留)"
    lines[#lines + 1] = "原版备份:" .. tostring(report.backup or "")
    return lines
end

return M
