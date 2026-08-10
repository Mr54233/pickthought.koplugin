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

return M
