-- 同步批次状态的纯逻辑与提交顺序。
-- 文件读写由调用方注入,便于桌面测试状态写失败和完成标记失败。
local M = {
    RUNNING = "running",
    PARTIAL = "partial",
    COMPLETE = "complete",
}

function M.is_complete(previous, marker_exists)
    local status = type(previous) == "table" and tostring(previous.status or "") or ""
    return status == M.COMPLETE or (status == "" and marker_exists == true)
end

function M.finalize(report, now)
    report = type(report) == "table" and report or {}
    local pending = tonumber(report.chapters_pending) or 0
    local complete = pending == 0
        and (tonumber(report.fetch_errors) or 0) == 0
        and (tonumber(report.save_failures) or 0) == 0
        and not report.rate_limited
    return {
        complete = complete,
        state = {
            status = complete and M.COMPLETE or M.PARTIAL,
            total = report.chapters_total,
            pending = pending,
            next_index = tonumber(report.next_index) or ((tonumber(report.chapters_total) or 0) + 1),
            retry_after = report.rate_limit_wait and (os.time() + report.rate_limit_wait) or nil,
            batch_start = report.batch_start,
            batch_end = report.batch_end,
            updated_at = now or os.time(),
        },
    }
end

function M.commit(report, options)
    options = options or {}
    local result = M.finalize(report, options.now)
    if type(options.write_state) ~= "function" then
        return nil, "同步状态提交器未配置"
    end
    local state_ok, state_error = options.write_state(result.state)
    if not state_ok then
        return nil, "同步内容已生成,但同步状态保存失败:" .. tostring(state_error or "写入失败")
    end

    if result.complete then
        if type(options.write_marker) ~= "function" then
            return nil, "同步状态已保存,但完成标记提交器未配置"
        end
        local marker_ok, marker_error = options.write_marker(tostring(result.state.updated_at))
        if not marker_ok then
            return nil, "同步状态已保存,但完成标记保存失败:" .. tostring(marker_error or "写入失败")
        end
    elseif type(options.marker_exists) == "function" and options.marker_exists() then
        local removed = type(options.remove_marker) == "function"
            and options.remove_marker() or nil
        if options.marker_exists() then
            return nil, "同步状态已保存,但旧完成标记无法清理"
        end
        -- 删除接口在某些平台上对已消失的文件返回 nil,只要最终不存在即可。
        if removed == false then return nil, "同步状态已保存,但旧完成标记无法清理" end
    end
    return result.state
end

return M
