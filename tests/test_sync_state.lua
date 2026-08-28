local SyncState = require("pickthought.sync_state")

T.case("同步状态只有连续无错误批次才算 complete", function()
    local complete = SyncState.finalize({
        chapters_total = 400, chapters_pending = 0, next_index = 401,
        fetch_errors = 0, save_failures = 0,
    }, 123)
    T.eq(complete.state.status, "complete", "完整批次状态")
    T.ok(complete.complete, "完整批次允许完成标记")

    for _, report in ipairs({
        {chapters_total = 400, chapters_pending = 1, next_index = 400},
        {chapters_total = 400, chapters_pending = 0, next_index = 401, fetch_errors = 1},
        {chapters_total = 400, chapters_pending = 0, next_index = 401, save_failures = 1},
        {chapters_total = 400, chapters_pending = 0, next_index = 401, rate_limited = true},
    }) do
        local partial = SyncState.finalize(report, 123)
        T.eq(partial.state.status, "partial", "异常批次不能标记完成")
        T.ok(not partial.complete, "异常批次不写完成标记")
    end
end)

T.case("同步状态提交先写 state 再处理完成标记", function()
    local events = {}
    local state = SyncState.commit({
        chapters_total = 10, chapters_pending = 0, next_index = 11,
    }, {
        now = 123,
        write_state = function(value)
            events[#events + 1] = "state:" .. value.status
            return true
        end,
        write_marker = function(value)
            events[#events + 1] = "marker:" .. value
            return true
        end,
    })
    T.eq(state.status, "complete", "提交完整状态")
    T.eq(table.concat(events, ","), "state:complete,marker:123", "提交顺序")
end)

T.case("同步状态写失败时不允许提交完成标记", function()
    local marker_calls = 0
    local state, err = SyncState.commit({
        chapters_total = 10, chapters_pending = 0, next_index = 11,
    }, {
        write_state = function() return nil, "磁盘满" end,
        write_marker = function() marker_calls = marker_calls + 1; return true end,
    })
    T.ok(state == nil, "状态写失败应中止")
    T.ok(tostring(err):find("状态保存失败", 1, true), "保留状态写错误")
    T.eq(marker_calls, 0, "状态写失败不得写完成标记")
end)

T.case("完成标记写失败时保留已写入状态", function()
    local state, err = SyncState.commit({
        chapters_total = 10, chapters_pending = 0, next_index = 11,
    }, {
        write_state = function(value)
            T.eq(value.status, "complete", "先保存完整状态")
            return true
        end,
        write_marker = function() return nil, "磁盘满" end,
    })
    T.ok(state == nil, "完成标记失败应报告提交失败")
    T.ok(tostring(err):find("完成标记保存失败", 1, true), "保留完成标记错误")
end)

T.case("部分批次会清理旧完成标记", function()
    local marker_present = true
    local events = {}
    local state, err = SyncState.commit({
        chapters_total = 10, chapters_pending = 2, next_index = 9,
    }, {
        now = 123,
        write_state = function(value)
            events[#events + 1] = "state:" .. value.status
            return true
        end,
        marker_exists = function() return marker_present end,
        remove_marker = function()
            events[#events + 1] = "remove"
            marker_present = false
            return true
        end,
    })
    T.ok(state and not err, "部分状态提交成功")
    T.eq(state.status, "partial", "部分状态")
    T.eq(table.concat(events, ","), "state:partial,remove", "先写状态再清旧标记")
    T.ok(not marker_present, "旧完成标记已清理")
end)

T.case("旧完成标记清理失败时不宣称提交完成", function()
    local marker_present = true
    local state, err = SyncState.commit({
        chapters_total = 10, chapters_pending = 2, next_index = 9,
    }, {
        write_state = function() return true end,
        marker_exists = function() return marker_present end,
        remove_marker = function() return nil, "权限不足" end,
    })
    T.ok(state == nil, "旧标记未清理应报告失败")
    T.ok(tostring(err):find("旧完成标记无法清理", 1, true), "保留标记清理错误")
end)

T.case("旧版无 status 时仍兼容完成标记", function()
    T.ok(SyncState.is_complete({}, true), "旧版完成标记")
    T.ok(not SyncState.is_complete({status = "partial"}, true), "部分状态覆盖旧标记")
    T.ok(SyncState.is_complete({status = "complete"}, false), "状态可独立恢复完成")
end)

T.case("未知剩余量与失败元数据不得被折算成完成", function()
    local state = SyncState.commit({
        chapters_total = 20, chapters_pending = nil, next_index = 7,
        fetch_errors = 1, failed = true, error = "章节列表失败",
    }, {
        now = 123,
        write_state = function(value)
            T.eq(value.status, "partial", "未知剩余量应为部分状态")
            T.eq(value.pending, nil, "未知剩余量保持 nil")
            T.eq(value.failed, true, "保留失败标志")
            T.eq(value.error, "章节列表失败", "保留失败原因")
            return true
        end,
        marker_exists = function() return false end,
    })
    T.eq(state.status, "partial", "未知剩余量不能完成")
end)
