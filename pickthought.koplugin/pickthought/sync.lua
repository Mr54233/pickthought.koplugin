-- 同步编排:拉取微信读书划线与想法 → 想法缓存 → 章节映射 → 注入并替换原书。
-- 替换语义:首次同步把原书备份为 <path>.orig,注入版顶替原路径——KOReader 的
-- 阅读进度/侧车跟着路径走,进度得以保留;后续批次在当前副本上增量追加。
-- 全部外部能力经 deps 注入,便于桌面测试;UI(进度/取消)由调用方通过 progress 提供。
--
-- deps:
--   doc_path        本地 EPUB 路径(书架上正在用的路径)
--   book_id         微信读书 bookId
--   api             :chapters(book_id)
--   annotations     :fetch_chapter(book_id, uid) → 与 annotations.lua 同形
--   load_meta(path) → meta, err(epub_reader.load 的形状)
--   read_text(meta, href) → html|nil
--   read_spine(meta, callback)(可选) → 单遍流式读取全部 spine；缺省回退 read_text
--   save_thoughts(book_id, uid, review_groups)
--   inject(src, book_id, mapped_chapters, dest) → stats, err(epub_inject.inject_copy)
--   progress(phase, i, n, text) → 返回 false 表示取消(可选)
--   file_exists/rename/remove(可选,默认真实文件系统)
local Binding = require("pickthought.binding")
local ChapterMap = require("pickthought.chapter_map")
local EpubInject = require("pickthought.epub_inject")
local Json = require("pickthought.json")
local SpineCache = require("pickthought.spine_cache")
local U = require("pickthought.util")
local logger = require("logger")

local Sync = {}

Sync.BACKUP_SUFFIX = ".orig"

function Sync.backup_path(doc_path) return tostring(doc_path) .. Sync.BACKUP_SUFFIX end

function Sync.run(deps)
    local progress = deps.progress or function() return true end
    local function step(phase, i, n, text)
        return progress(phase, i, n, text) ~= false
    end
    local file_exists = deps.file_exists or U.file_exists
    local rename = deps.rename or os.rename
    local remove = deps.remove or os.remove

    -- 已有注入版时,增量同步直接以当前书为源;首次/全量重建才从 .orig 读取。
    local doc_path = tostring(deps.doc_path)
    local backup = Sync.backup_path(doc_path)
    local current_meta = deps.load_meta(doc_path)
    local append = deps.append == true and current_meta and current_meta.has
        and current_meta.has[EpubInject.MARKER] == true
    local src = append and doc_path or (file_exists(backup) and backup or doc_path)

    local meta, meta_err = deps.load_meta(src)
    if not meta then return nil, meta_err end
    if meta.has and meta.has[EpubInject.MARKER] and not append then
        if src == doc_path then
            return nil, "这本书已被注入过,但找不到原书备份(" .. backup .. "),无法重新同步"
        end
        return nil, "原书备份本身是注入版,数据异常;请手动恢复原书后重试"
    end
    local backup_meta
    if append then
        if not file_exists(backup) then
            return nil, "这本书已被注入过,但找不到干净原书备份(" .. backup .. "),无法继续同步"
        end
        backup_meta, meta_err = deps.load_meta(backup)
        if not backup_meta then return nil, meta_err end
        if backup_meta.has and backup_meta.has[EpubInject.MARKER] then
            return nil, "原书备份已被注入,无法保证可还原;请手动恢复干净原书备份后重试"
        end
    end

    if not step("chapters", 0, 1, "获取章节列表") then return nil, "已取消" end
    local ok, chapters_raw = pcall(function() return deps.api:chapters(deps.book_id) end)
    if not ok then return nil, "获取章节列表失败:" .. tostring(chapters_raw) end
    local chapter_list = Binding.normalize_chapters(chapters_raw, deps.book_id)
    if #chapter_list == 0 then return nil, "微信读书返回的章节列表为空" end

    local fetched = {}
    local total_underlines = 0
    local total_thought_entries = 0
    -- fetch_budget 是网络预算; chapter_budget 是 CPU/注入预算,两者不能混用。
    local fetch_budget = tonumber(deps.fetch_budget)
    if fetch_budget and fetch_budget <= 0 then fetch_budget = nil end
    local chapter_start = math.max(1, tonumber(deps.chapter_start) or 1)
    if not append then chapter_start = 1 end
    local chapter_budget = tonumber(deps.chapter_budget)
    if chapter_budget and chapter_budget <= 0 then chapter_budget = nil end
    local skip_resumed = deps.skip_resumed == true
    local fresh_fetches = 0
    local chapters_pending = 0
    local rate_limited = false
    local rate_limit_wait
    local next_index = chapter_start
    local batch_start_index, batch_end_index
    local chapters_processed, chapters_fetch_succeeded = 0, 0
    local selected_end = #chapter_list
    -- 硬失败=整章划线都没拉到;部分失败=章节数据不完整。两者都不能跨过,
    -- 否则后续章节虽然拉到了,连续游标却会把失败章节永久跳过。
    local hard_failures, partial_errors = 0, 0
    local thoughts_saved, save_failures = 0, 0
    -- 记住最后一次真实错误:失败消息必须告诉用户到底错在哪,不能只说「网络失败」。
    local last_error
    local function short_err(text)
        text = tostring(text or "未知错误"):gsub("^.-%.lua:%d+:%s*", "")
        if #text > 160 then text = text:sub(1, 160) .. "…" end
        return text
    end
    if not skip_resumed and chapter_budget then
        selected_end = math.min(#chapter_list, chapter_start + chapter_budget - 1)
    end
    local i = chapter_start
    while i <= #chapter_list do
        local ch = chapter_list[i]
        if fetch_budget and fresh_fetches >= fetch_budget then
            chapters_pending = #chapter_list - i + 1
            break
        end
        if not skip_resumed and i > selected_end then
            chapters_pending = #chapter_list - i + 1
            break
        end
        if not step("fetch", i, #chapter_list, ch.title) then return nil, "已取消" end
        local good, data = pcall(function()
            return deps.annotations:fetch_chapter(deps.book_id, ch.uid)
        end)
        -- 预算按"网络请求次数"计:缓存命中(resumed)免费,失败的尝试也占额度。
        if not (good and type(data) == "table" and data.resumed) then
            fresh_fetches = fresh_fetches + 1
        end
        local chapter_rate_limited = good and type(data) == "table" and data.rate_limited == true
        local skipped_completed_cache = good and type(data) == "table"
            and data.resumed and skip_resumed
        local chapter_completed = false
        if chapter_rate_limited then
            rate_limited = true
            rate_limit_wait = tonumber(data.rate_limit_wait) or rate_limit_wait
            chapters_pending = #chapter_list - i + 1
        elseif good and type(data) == "table" and data.resumed and skip_resumed then
            -- 完整缓存只扫描以寻找新增/缺失章节,不重复写库和重注入旧章节。
            chapter_completed = true
        elseif good and type(data) == "table" and data.underline_request_ok ~= false then
            total_underlines = total_underlines + (data.underline_count or 0)
            total_thought_entries = total_thought_entries + (data.thought_entry_count or 0)
            local data_errors = #(data.errors or {})
            if data_errors > 0 then
                partial_errors = partial_errors + 1
                last_error = tostring((data.errors or {})[1] or "章节数据不完整")
                chapters_pending = #chapter_list - i + 1
            else
                local save_ok = true
                if #(data.review_groups or {}) > 0 then
                    local ok_save, saved = pcall(deps.save_thoughts, deps.book_id, ch.uid, data.review_groups)
                    if ok_save and saved then
                        thoughts_saved = thoughts_saved + 1
                    else
                        save_ok = false
                        save_failures = save_failures + 1
                        last_error = "想法缓存保存失败:" .. tostring(saved or "未知错误")
                        chapters_pending = #chapter_list - i + 1
                    end
                end
                if save_ok then
                    if (data.underline_count or 0) > 0 then
                        fetched[#fetched + 1] = {
                            uid = ch.uid, title = ch.title,
                            underlines = data.underlines, review_map = data.review_map,
                        }
                    end
                    chapter_completed = true
                else
                    -- 想法落盘失败时不把本章交给注入器,下次从本章重试。
                end
            end
        else
            hard_failures = hard_failures + 1
            if not good then
                last_error = tostring(data)
            elseif type(data) == "table" then
                last_error = tostring((data.errors or {})[1] or last_error or "接口返回异常")
            end
            chapters_pending = #chapter_list - i + 1
        end
        if chapter_completed and not skipped_completed_cache then
            batch_start_index = batch_start_index or i
            batch_end_index = i
            chapters_processed = chapters_processed + 1
            if good and type(data) == "table" and data.underline_request_ok ~= false
                and #(data.errors or {}) == 0 then
                chapters_fetch_succeeded = chapters_fetch_succeeded + 1
            end
        end
        if not chapter_completed then
            next_index = i
            break
        end
        next_index = i + 1
        i = i + 1
    end
    if chapters_pending == 0 and next_index <= #chapter_list then
        chapters_pending = #chapter_list - next_index + 1
    end
    local function with_batch_fields(report)
        report.batch_start = batch_start_index
        report.batch_end = batch_end_index
        report.chapters_processed = chapters_processed
        report.chapters_fetch_succeeded = chapters_fetch_succeeded
        report.batch_limit = chapter_budget or fetch_budget or #chapter_list
        return report
    end
    if hard_failures > 0 and #fetched == 0 then
        return nil, string.format("划线拉取失败(共 %d 章)。\n最后错误:%s",
            hard_failures, short_err(last_error))
    end
    if total_underlines == 0 then
        if hard_failures > 0 then
            return nil, string.format("有 %d 章拉取失败,已成功的章节没有划线。\n最后错误:%s",
                hard_failures, short_err(last_error))
        end
        if chapters_pending > 0 and not rate_limited then
            return nil, string.format("本批 %d 章都没有划线;还剩 %d 章,再次同步继续拉取",
                #chapter_list - chapters_pending, chapters_pending)
        end
        if not skip_resumed and not rate_limited then return nil, "这本书在微信读书里没有划线" end
        return with_batch_fields{
            no_changes = true, chapters_total = #chapter_list,
            chapters_pending = chapters_pending, next_index = next_index,
            total_underlines = 0, total_thought_entries = 0,
            chapters_with_data = 0, chapters_matched = 0,
            unmatched = {}, unmatched_underlines = 0,
            fetch_errors = hard_failures + partial_errors,
            rate_limited = rate_limited or nil,
            rate_limit_wait = rate_limit_wait,
        }
    end

    if not step("map", 0, 1, "匹配本地章节") then return nil, "已取消" end
    -- 映射结果缓存:章节→文件的映射对同一本源书是稳定的,续批/离线重注
    -- 只需要匹配没见过的新章节。缓存带源文件指纹,源变了整体作废。
    local map_store, map_signature
    -- 增量注入的当前 EPUB 已含旧批次标记;新章节映射仍从 .orig 干净正文读取,
    -- 避免 HTML 标记增长后改变引文定位结果。
    local map_meta = backup_meta or meta
    if deps.map_cache_path then
        -- 指纹 = 源书大小 + 匹配算法版本:换书或改算法都让旧映射作废重建。
        local map_source = file_exists(backup) and backup or doc_path
        map_signature = tostring(U.file_size(map_source) or 0) .. "@" .. tostring(ChapterMap.ALGO_VERSION)
        local raw = U.read_file(deps.map_cache_path, true)
        if raw then
            local ok_decode, decoded = pcall(Json.decode, raw)
            if ok_decode and type(decoded) == "table"
                and tostring(decoded.signature) == map_signature
                and type(decoded.map) == "table" then
                map_store = decoded.map
            end
        end
        map_store = map_store or {}
    end

    -- 缓存值格式:false = 确认无法匹配;{hrefs={...}, num=true|nil} =
    -- 目标文件列表(拆分章多目标),num 表示单目标强投票、允许数字兜底。
    local known, todo = {}, {}
    for _, ch in ipairs(fetched) do
        local cached = map_store and map_store[tostring(ch.uid)]
        if cached == nil then
            todo[#todo + 1] = ch
        elseif cached == false then
            known[tostring(ch.uid)] = false
        elseif type(cached) == "table" and type(cached.hrefs) == "table" and #cached.hrefs > 0 then
            known[tostring(ch.uid)] = cached
        else
            todo[#todo + 1] = ch
        end
    end

    -- 兜底:旧缓存的 underlines markText 为空(/book/underlines 不返回文本),
    -- chapter_map 没引文素材。用同 range 想法的 abstract(原文摘要)补填,
    -- 让旧缓存(重注/续传)也能正确映射,不用重新拉。
    for _, ch in ipairs(fetched) do
        for _, u in ipairs(ch.underlines or {}) do
            if tostring(u.markText or ""):find("%S") == nil then
                local texts = ch.review_map and ch.review_map[u.range]
                if type(texts) == "table" and texts[1] and texts[1].abstract then
                    u.markText = texts[1].abstract
                end
            end
        end
    end

    -- 每读一个 spine 文件发一次心跳(只作活动信号,不在文件中途响应取消),
    -- 免得特大书的纯 CPU 匹配被看门狗当成死吊。
    local map_count = 0
    local spine_total = #(map_meta.spine or {})
    local mapped_new, unmatched_new = {}, {}

    -- B:spine 正文(原始 HTML)持久化缓存。仅当调用方显式开启 deps.spine_cache 且存在
    -- map 缓存、且本批确有新章节要匹配(todo>0)时启用;测试不开启,行为完全不变。
    -- 第 2 批起直接读缓存文本,不再从 EPUB 解压每个 spine 文件、不再重复 normalize。
    -- 单书场景 map_cache_path 为字符串路径;缓存目录取 map.json 同目录下的 spine-<指纹>。
    local spine_cache
    if deps.spine_cache and deps.map_cache_path and #todo > 0 then
        local sc_dir = SpineCache.dir_for(deps.map_cache_path, map_signature)
        if sc_dir then
            spine_cache = SpineCache.open(sc_dir, map_signature)
            logger.info("[撷思][SpineCache]", spine_cache and (spine_cache:warm() and "warm" or "cold") or "disabled",
                "spine=", tostring(spine_total))
        end
    end
    local real_read_text = deps.read_text
    local real_read_spine = deps.read_spine
    local function cached_read_text(m, href)
        if spine_cache then
            local cached = spine_cache:get(href)
            if cached ~= nil then return cached end
        end
        local html = real_read_text and real_read_text(m, href)
        if spine_cache then spine_cache:put(href, html) end
        return html
    end
    local function cached_read_spine(m, callback)
        if spine_cache then
            if spine_cache:warm() and spine_cache:covers(m.spine) then
                -- 暖模式:直接从缓存流式喂,完全不碰 EPUB。
                for index, item in ipairs(m.spine or {}) do
                    local html = spine_cache:get(item.href)
                    callback(item, html, html == nil and "缓存缺失" or nil, index)
                end
                return true
            end
            if real_read_spine then
                -- 冷模式:真实读取并捕获进缓存。
                return real_read_spine(m, function(item, content, err, index)
                    spine_cache:put(item.href, content)
                    return callback(item, content, err, index)
                end)
            end
            -- 无真实 read_spine:走 read_text 路径(仍经缓存)。
            for index, item in ipairs(m.spine or {}) do
                callback(item, cached_read_text(m, item.href), nil, index)
            end
            return true
        end
        -- 缓存未启用:完全等价于原行为,绝不会误调 read_text。
        if real_read_spine then
            return real_read_spine(m, callback)
        end
        for index, item in ipairs(m.spine or {}) do
            callback(item, real_read_text and real_read_text(m, item.href), nil, index)
        end
        return true
    end

    if #todo > 0 then
        local map_started_at = os.time()
        if deps.read_spine then
            mapped_new, unmatched_new = ChapterMap.build_stream(map_meta.spine, function(visit)
                return cached_read_spine(map_meta, function(item, content, err, index)
                    map_count = map_count + 1
                    step("map", map_count, spine_total, item and item.href)
                    visit(item, content, err, index)
                end)
            end, todo)
        else
            mapped_new, unmatched_new = ChapterMap.build(map_meta.spine, function(href)
                map_count = map_count + 1
                step("map", map_count, spine_total, href)
                return cached_read_text(map_meta, href)
            end, todo)
        end
        if spine_cache then spine_cache:close() end
        logger.info("[撷思][ChapterMap] completed",
            "spine=", tostring(spine_total), "chapters=", tostring(#todo),
            "streamed=", tostring(deps.read_spine ~= nil),
            "spine_cache=", spine_cache and (spine_cache:warm() and "warm" or "cold") or "off",
            "elapsed_s=", tostring(math.max(0, os.time() - map_started_at)))
    end

    -- 合并:按 fetched 原序拼装(拆分章一 uid 多行),新结果回写缓存。
    local new_rows_by_uid = {}
    for _, row in ipairs(mapped_new) do
        local rows = new_rows_by_uid[row.chapter_uid] or {}
        rows[#rows + 1] = row
        new_rows_by_uid[row.chapter_uid] = rows
    end
    local unmatched_uid = {}
    for _, row in ipairs(unmatched_new) do
        if row.reason == "no_hit" then unmatched_uid[tostring(row.uid)] = true end
    end
    local mapped, unmatched = {}, {}
    local matched_uids = {}
    for _, ch in ipairs(fetched) do
        local uid = tostring(ch.uid)
        local cached = known[uid]
        if type(cached) == "table" then
            matched_uids[uid] = true
            local quote_only = (not cached.num or #cached.hrefs > 1) or nil
            for _, href in ipairs(cached.hrefs) do
                mapped[#mapped + 1] = {
                    chapter_uid = uid, href = tostring(href),
                    underlines = ch.underlines, review_map = ch.review_map or {},
                    quote_only = quote_only,
                }
            end
        elseif cached == false then
            unmatched[#unmatched + 1] = {uid = uid, title = ch.title, reason = "no_hit"}
        elseif new_rows_by_uid[uid] then
            matched_uids[uid] = true
            local hrefs = {}
            for _, row in ipairs(new_rows_by_uid[uid]) do
                mapped[#mapped + 1] = row
                hrefs[#hrefs + 1] = row.href
            end
            if map_store then
                map_store[uid] = {hrefs = hrefs,
                    num = (#hrefs == 1 and not new_rows_by_uid[uid][1].quote_only) or nil}
            end
        elseif unmatched_uid[uid] then
            unmatched[#unmatched + 1] = {uid = uid, title = ch.title, reason = "no_hit"}
            if map_store then map_store[uid] = false end
        else
            -- no_data(无划线)章节:不入缓存,下批有数据时再匹配。
            unmatched[#unmatched + 1] = {uid = uid, title = ch.title, reason = "no_data"}
        end
    end
    if deps.map_cache_path and map_store then
        local ok_encode, encoded = pcall(Json.encode, {signature = map_signature, map = map_store})
        if ok_encode then U.atomic_write(deps.map_cache_path, encoded, true) end
    end
    -- 未匹配章节连带损失的划线数(报告要能说清"失败带走了多少")。
    local underlines_by_uid = {}
    for _, ch in ipairs(fetched) do underlines_by_uid[tostring(ch.uid)] = #(ch.underlines or {}) end
    local unmatched_underlines = 0
    for _, row in ipairs(unmatched) do
        unmatched_underlines = unmatched_underlines + (underlines_by_uid[tostring(row.uid)] or 0)
    end

    if #mapped == 0 then
        if not skip_resumed then
            return nil, "没有任何章节能匹配到本地书,请确认绑定的和本地打开的是同一本书"
        end
        return with_batch_fields{
            no_changes = true, chapters_total = #chapter_list,
            chapters_pending = chapters_pending, next_index = next_index,
            total_underlines = total_underlines,
            total_thought_entries = total_thought_entries,
            chapters_with_data = #fetched, chapters_matched = 0,
            unmatched = unmatched, unmatched_underlines = unmatched_underlines,
            fetch_errors = hard_failures + partial_errors,
            rate_limited = rate_limited or nil,
            rate_limit_wait = rate_limit_wait,
        }
    end

    if not step("inject", 0, 1) then return nil, "已取消" end
    -- 注入到中间文件(无 .epub 后缀,不会闪现在书架),成功后原子换位。
    local temp_dest = doc_path .. ".pickthought-new"
    local stats, inject_err = deps.inject(src, deps.book_id, mapped, temp_dest,
        {append = append, meta = meta})
    if not stats then return nil, inject_err end

    -- 重叠划线被合并的,把想法并进存活锚点的组:点一个虚线看到这一段全部想法。
    if deps.merge_thoughts then
        for _, merge in ipairs(stats.merges or {}) do
            pcall(deps.merge_thoughts, deps.book_id, merge.uid, merge.from, merge.into)
        end
    end

    local backed_up = false
    if src == doc_path and not append then
        -- 首次:原书让位为备份,注入版顶上原路径(进度侧车不动)。
        local ok_backup, backup_err = rename(doc_path, backup)
        if not ok_backup then
            remove(temp_dest)
            return nil, "无法备份原书:" .. tostring(backup_err or "重命名失败")
        end
        backed_up = true
    end
    local ok_swap, swap_err = rename(temp_dest, doc_path)
    if not ok_swap then
        remove(temp_dest)
        -- 首次注入已经让原书离位时才需要回滚。增量失败时旧注入版仍在原路径，
        -- 绝不能删除它或移动干净 .orig；上一代只在原子替换成功时由系统丢弃。
        if backed_up and not file_exists(doc_path) then rename(backup, doc_path) end
        return nil, "无法替换原书:" .. tostring(swap_err or "重命名失败")
    end

    local underlines_injected = math.min(total_underlines,
        math.max(0, tonumber(stats.underlines_resolved) or 0))
    local thoughts_injected = math.max(0, tonumber(stats.thoughts_linked) or 0)
    thoughts_injected = math.min(total_thought_entries, math.max(0, thoughts_injected))
    return with_batch_fields{
        dest = doc_path,
        backup = backup,
        injected = stats.injected,
        marks = stats.marks,
        quote_aligned = stats.quote_aligned,
        numeric = stats.numeric,
        dropped = stats.dropped,
        overlapped = stats.overlapped,
        unlocated = stats.unlocated,
        inject_unmatched = stats.unmatched,
        thoughts_saved = thoughts_saved,
        save_failures = save_failures,
        chapters_total = #chapter_list,
        chapters_with_data = #fetched,
        chapters_matched = (function()
            local n = 0
            for _ in pairs(matched_uids) do n = n + 1 end
            return n
        end)(),
        chapters_pending = chapters_pending,
        next_index = next_index,
        total_underlines = total_underlines,
        total_thought_entries = total_thought_entries,
        underlines_injected = underlines_injected,
        underlines_failed = total_underlines - underlines_injected,
        thoughts_injected = thoughts_injected,
        thoughts_failed = total_thought_entries - thoughts_injected,
        unmatched = unmatched,
        unmatched_underlines = unmatched_underlines,
        fetch_errors = hard_failures + partial_errors,
        rate_limited = rate_limited or nil,
        rate_limit_wait = rate_limit_wait,
    }
end

return Sync
