local M = {DEFAULT_AUTO = false}

local function integer(value)
    return math.floor(tonumber(value) or 0)
end

local function positive(value)
    value = integer(value)
    return value > 0 and value or nil
end

local function format_integer(value)
    local text = tostring(math.max(0, integer(value))):reverse():gsub("(%d%d%d)", "%1,"):reverse()
    text = text:gsub("^,", "")
    return text
end

function M.auto_enabled(preferences)
    return type(preferences) == "table" and preferences.auto_batch_sync_opt_in == true
end

function M.plan(state, batch_limit)
    state = type(state) == "table" and state or {}
    batch_limit = positive(batch_limit) or 200
    local total = positive(state.total)
    local pending = tonumber(state.pending)
    if total and pending and pending <= 0 then return nil end

    -- 多书:不同远程书的章节坐标是彼此独立的序列,不能推导单一连续章节范围
    -- (评审五轮 P1#1:伪范围「从第 1 章拉到第 7 章」不属于任何一本书)。
    -- 只返回聚合数量 + 逐书明细,start/end 置空,展示层不得生成跨书区间。
    if state.multi_book == true then
        if (total or 0) == 0 and (pending or 0) == 0 then return nil end
        return {
            multi = true,
            total = total,
            pending = pending and math.max(0, integer(pending)) or nil,
            batch_limit = batch_limit,
            books_with_pending = positive(state.books_with_pending),
            per_book = type(state.per_book) == "table" and state.per_book or nil,
        }
    end

    local start_index = positive(state.next_index)
    if not start_index and total and pending then
        start_index = math.max(1, total - math.max(0, integer(pending)) + 1)
    end
    start_index = start_index or 1
    local end_index = start_index + batch_limit - 1
    if total then end_index = math.min(total, end_index) end
    if end_index < start_index then return nil end

    return {
        start_index = start_index,
        end_index = end_index,
        count = end_index - start_index + 1,
        processed_to = start_index - 1,
        total = total,
        pending = pending and math.max(0, integer(pending)) or nil,
        batch_limit = batch_limit,
    }
end

function M.prompt_text(plan, background)
    if not plan then return nil end
    if plan.multi then
        -- 多书:只展示聚合数量 + 逐书明细,绝不生成跨书伪范围(评审五轮 P1#1)。
        local lines = {"继续同步划线与想法", ""}
        if plan.pending and plan.pending > 0 then
            lines[#lines + 1] = string.format("剩余共 %s 章（跨 %s 本书）",
                format_integer(plan.pending), format_integer(plan.books_with_pending or 1))
        else
            lines[#lines + 1] = "剩余章节数量未知"
        end
        lines[#lines + 1] = "本批按每本书各自的续传位置分批拉取"
        local pb = plan.per_book
        if type(pb) == "table" then
            local bids = {}
            for bid in pairs(pb) do bids[#bids + 1] = bid end
            table.sort(bids)
            if #bids > 0 then
                lines[#lines + 1] = ""
                lines[#lines + 1] = "逐书明细"
                for _, bid in ipairs(bids) do
                    local st = pb[bid]
                    local label = tostring((st and st.title) or bid)
                    local p = tonumber(st and st.pending)
                    if st and st.failed then
                        lines[#lines + 1] = string.format("· %s：上次失败（%s）",
                            label, tostring(st.error or "未知错误"))
                    elseif p and p > 0 then
                        lines[#lines + 1] = string.format("· %s：还剩 %s 章（续传第 %s 章）",
                            label, format_integer(p), format_integer(tonumber(st.next_index) or 1))
                    elseif p == 0 then
                        lines[#lines + 1] = string.format("· %s：已同步完成", label)
                    else
                        lines[#lines + 1] = string.format("· %s：剩余未知", label)
                    end
                end
            end
        end
        lines[#lines + 1] = ""
        lines[#lines + 1] = background
            and "同步将在后台进行，不影响继续阅读。"
            or "开始后将显示同步进度，也可转入后台继续阅读。"
        return table.concat(lines, "\n")
    end
    local lines = {plan.start_index == 1 and "同步划线与想法" or "继续同步划线与想法", ""}
    if plan.processed_to > 0 then
        lines[#lines + 1] = string.format("当前已处理到第 %s 章", format_integer(plan.processed_to))
    else
        lines[#lines + 1] = "当前尚未拉取章节"
    end
    lines[#lines + 1] = string.format("本批计划：从第 %s 章开始，拉取并注入到第 %s 章",
        format_integer(plan.start_index), format_integer(plan.end_index))
    if plan.total then
        lines[#lines + 1] = string.format("本批共 %s 章，全书还剩 %s 章未拉取",
            format_integer(plan.count), format_integer(plan.pending or (plan.total - plan.processed_to)))
    else
        lines[#lines + 1] = string.format("本批最多 %s 章；若全书不足，以实际末章为准",
            format_integer(plan.count))
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = background
        and "同步将在后台进行，不影响继续阅读。"
        or "开始后将显示同步进度，也可转入后台继续阅读。"
    return table.concat(lines, "\n")
end

function M.background_text(plan)
    if not plan then return "正在后台拉取后续章节…" end
    if plan.multi then
        -- 多书:不生成跨书「第 X–Y 章」伪范围,只报聚合数量(评审五轮 P1#1)。
        if plan.pending and plan.pending > 0 then
            return string.format("正在后台拉取剩余 %s 章（多书聚合）…", format_integer(plan.pending))
        end
        return "正在后台拉取后续章节（多书聚合）…"
    end
    return string.format("正在后台拉取并注入第 %s–%s 章…",
        format_integer(plan.start_index), format_integer(plan.end_index))
end

function M.fragment_index(xpointer)
    xpointer = tostring(xpointer or "")
    local index = tonumber(xpointer:match("/DocFragment%[(%d+)%]"))
    if index then return index end
    if xpointer:find("/DocFragment", 1, true) then return 1 end
end

function M.estimate_read_chapter(page, total_pages, total_chapters, fragment, fragment_total)
    page, total_pages, total_chapters = tonumber(page), tonumber(total_pages), positive(total_chapters)
    fragment, fragment_total = positive(fragment), positive(fragment_total)
    if not total_chapters then return nil end
    if fragment and fragment_total and fragment <= fragment_total then
        local fraction = fragment / fragment_total
        return math.max(1, math.min(total_chapters, math.ceil(fraction * total_chapters)))
    end
    if not page or not total_pages or total_pages <= 0 then return nil end
    local fraction = math.max(0, math.min(1, page / total_pages))
    return math.max(1, math.min(total_chapters, math.ceil(fraction * total_chapters)))
end

function M.read_bucket(chapter_index, batch_limit)
    chapter_index = positive(chapter_index)
    batch_limit = positive(batch_limit) or 200
    if not chapter_index then return nil end
    return math.floor((chapter_index - 1) / batch_limit) + 1
end

local function same_failed_batch(state, plan)
    return type(state) == "table" and state.status == "failed"
        and integer(state.start_index) == integer(plan.start_index)
        and integer(state.end_index) == integer(plan.end_index)
        and integer(state.total) == integer(plan.total)
        and integer(state.batch_limit) == integer(plan.batch_limit)
end

function M.should_offer(args)
    args = args or {}
    if args.busy then return false, "busy" end
    local plan = M.plan(args.state, args.batch_limit)
    if not plan or not plan.total or not plan.pending or plan.pending <= 0 then
        return false, "nothing_pending"
    end
    local read_chapter = M.estimate_read_chapter(args.page, args.total_pages, plan.total,
        args.fragment, args.fragment_total)
    if not read_chapter then return false, "unknown_position" end
    if read_chapter < math.max(1, plan.start_index - 1) then return false, "before_boundary" end

    -- 在已同步末章触发时，拒绝应覆盖即将进入的下一批；否则第 200 章拒绝后
    -- 翻到 201 章会立刻再弹一次。
    local bucket = math.max(M.read_bucket(read_chapter, plan.batch_limit),
        M.read_bucket(plan.start_index, plan.batch_limit))
    local dismissed = type(args.dismissed) == "table" and args.dismissed or nil
    if same_failed_batch(args.failed, plan) then
        return false, "failed"
    end
    if dismissed and integer(dismissed.total) == plan.total
        and integer(dismissed.batch_limit) == plan.batch_limit
        and bucket <= integer(dismissed.bucket) then
        return false, "dismissed"
    end
    return true, {
        plan = plan,
        read_chapter = read_chapter,
        bucket = bucket,
    }
end

function M.dismissal(context)
    if type(context) ~= "table" or type(context.plan) ~= "table" then return nil end
    return {
        bucket = context.bucket,
        total = context.plan.total,
        batch_limit = context.plan.batch_limit,
        dismissed_at = os.time(),
    }
end

function M.failure(context, reason)
    if type(context) ~= "table" or type(context.plan) ~= "table"
        or context.plan.start_index == nil then return nil end
    local plan = context.plan
    reason = tostring(reason or "未知错误"):gsub("%s+", " ")
    if #reason > 220 then reason = reason:sub(1, 220) .. "…" end
    return {
        status = "failed",
        start_index = plan.start_index,
        end_index = plan.end_index,
        total = plan.total,
        batch_limit = plan.batch_limit,
        bucket = context.bucket,
        reason = reason,
        failed_at = os.time(),
    }
end

function M.failure_text(plan, reason)
    if type(plan) ~= "table" or plan.start_index == nil then
        return "本批自动补批未完成\n\n请从菜单中手动选择“继续拉取后续章节”重试。"
    end
    local detail = tostring(reason or "未知错误"):gsub("%s+", " ")
    if #detail > 220 then detail = detail:sub(1, 220) .. "…" end
    return table.concat({
        "本批自动补批未完成",
        "",
        string.format("计划拉取第 %s～%s 章，本批尚未完成。",
            format_integer(plan.start_index), format_integer(plan.end_index)),
        "原因：" .. detail,
        "",
        "本次已暂停自动补批，继续翻页不会重复弹窗。",
        "请清理内存或重启 KOReader，然后在菜单中手动选择“继续拉取后续章节”。",
        string.format("手动重试仍从第 %s 章开始。", format_integer(plan.start_index)),
    }, "\n")
end

return M
