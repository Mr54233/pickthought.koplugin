-- 同步编排:拉取微信读书划线与想法 → 想法缓存 → 章节映射 → 注入并替换原书。
-- 替换语义:首次同步把原书备份为 <path>.orig,注入版顶替原路径——KOReader 的
-- 阅读进度/侧车跟着路径走,进度得以保留;再次同步从 .orig 干净原书重新注入。
-- 全部外部能力经 deps 注入,便于桌面测试;UI(进度/取消)由调用方通过 progress 提供。
--
-- deps:
--   doc_path        本地 EPUB 路径(书架上正在用的路径)
--   book_id         微信读书 bookId
--   api             :chapters(book_id)
--   annotations     :fetch_chapter(book_id, uid) → 与 annotations.lua 同形
--   load_meta(path) → meta, err(epub_reader.load 的形状)
--   read_text(meta, href) → html|nil
--   save_thoughts(book_id, uid, review_groups)
--   inject(src, book_id, mapped_chapters, dest) → stats, err(epub_inject.inject_copy)
--   progress(phase, i, n, text) → 返回 false 表示取消(可选)
--   file_exists/rename/remove(可选,默认真实文件系统)
local Binding = require("pickthought.binding")
local ChapterMap = require("pickthought.chapter_map")
local EpubInject = require("pickthought.epub_inject")
local Json = require("pickthought.json")
local U = require("pickthought.util")

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

    -- 源解析:书架路径若已是注入版(有 .orig 备份),从干净备份重新注入。
    local doc_path = tostring(deps.doc_path)
    local backup = Sync.backup_path(doc_path)
    local src = file_exists(backup) and backup or doc_path

    local meta, meta_err = deps.load_meta(src)
    if not meta then return nil, meta_err end
    if meta.has and meta.has[EpubInject.MARKER] then
        if src == doc_path then
            return nil, "这本书已被注入过,但找不到原书备份(" .. backup .. "),无法重新同步"
        end
        return nil, "原书备份本身是注入版,数据异常;请手动恢复原书后重试"
    end

    if not step("chapters", 0, 1, "获取章节列表") then return nil, "已取消" end
    local ok, chapters_raw = pcall(function() return deps.api:chapters(deps.book_id) end)
    if not ok then return nil, "获取章节列表失败:" .. tostring(chapters_raw) end
    local chapter_list = Binding.normalize_chapters(chapters_raw, deps.book_id)
    if #chapter_list == 0 then return nil, "微信读书返回的章节列表为空" end

    local fetched = {}
    local total_underlines = 0
    local total_thought_entries = 0
    -- 分批风控:每次同步最多向网络拉 fetch_budget 个新章节(缓存命中免费),
    -- 到量干净收工,剩余章节记入 chapters_pending,下次同步自动续。
    local fetch_budget = tonumber(deps.fetch_budget)
    if fetch_budget and fetch_budget <= 0 then fetch_budget = nil end
    local fresh_fetches = 0
    local chapters_pending = 0
    -- 硬失败=整章划线都没拉到(决定是否中止);部分失败=划线在手、想法批次有缺(只计报告)。
    local hard_failures, partial_errors = 0, 0
    local thoughts_saved, save_failures = 0, 0
    local consecutive_hard = 0
    -- 记住最后一次真实错误:失败消息必须告诉用户到底错在哪,不能只说「网络失败」。
    local last_error
    local function short_err(text)
        text = tostring(text or "未知错误"):gsub("^.-%.lua:%d+:%s*", "")
        if #text > 160 then text = text:sub(1, 160) .. "…" end
        return text
    end
    for i, ch in ipairs(chapter_list) do
        if fetch_budget and fresh_fetches >= fetch_budget then
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
        if good and type(data) == "table" and data.underline_request_ok ~= false then
            -- 断点缓存命中(resumed)不算网络成功,不能复位熔断计数:
            -- 离线续传时散布的缓存命中会把计数清零,让熔断永不触发。
            if not data.resumed then consecutive_hard = 0 end
            if #(data.errors or {}) > 0 then partial_errors = partial_errors + 1 end
            total_underlines = total_underlines + (data.underline_count or 0)
            total_thought_entries = total_thought_entries + (data.thought_entry_count or 0)
            if (data.underline_count or 0) > 0 then
                fetched[#fetched + 1] = {
                    uid = ch.uid, title = ch.title,
                    underlines = data.underlines, review_map = data.review_map,
                }
            end
            if #(data.review_groups or {}) > 0 then
                local ok_save, saved = pcall(deps.save_thoughts, deps.book_id, ch.uid, data.review_groups)
                if ok_save and saved then
                    thoughts_saved = thoughts_saved + 1
                else
                    save_failures = save_failures + 1
                end
            end
        else
            hard_failures = hard_failures + 1
            consecutive_hard = consecutive_hard + 1
            if not good then
                last_error = tostring(data)
            elseif type(data) == "table" then
                last_error = tostring((data.errors or {})[1] or last_error or "接口返回异常")
            end
            -- 断网熔断:连续多章整章失败(每章重试要吃满超时)不能逐章磨完全书。
            -- 最后一章失败时不熔断,让已取到的数据走完正常出口。
            if consecutive_hard >= 3 and i < #chapter_list then
                return nil, string.format("连续 %d 章拉取失败,已中止同步。\n最后错误:%s",
                    consecutive_hard, short_err(last_error))
            end
        end
    end
    if hard_failures >= #chapter_list then
        return nil, string.format("划线拉取失败(共 %d 章)。\n最后错误:%s",
            hard_failures, short_err(last_error))
    end
    if total_underlines == 0 then
        if hard_failures > 0 then
            return nil, string.format("有 %d 章拉取失败,已成功的章节没有划线。\n最后错误:%s",
                hard_failures, short_err(last_error))
        end
        if chapters_pending > 0 then
            return nil, string.format("本批 %d 章都没有划线;还剩 %d 章,再次同步继续拉取",
                #chapter_list - chapters_pending, chapters_pending)
        end
        return nil, "这本书在微信读书里没有划线"
    end

    if not step("map", 0, 1, "匹配本地章节") then return nil, "已取消" end
    -- 映射结果缓存:章节→文件的映射对同一本源书是稳定的,续批/离线重注
    -- 只需要匹配没见过的新章节。缓存带源文件指纹,源变了整体作废。
    local map_store, map_signature
    if deps.map_cache_path then
        -- 指纹 = 源书大小 + 匹配算法版本:换书或改算法都让旧映射作废重建。
        map_signature = tostring(U.file_size(src) or 0) .. "@" .. tostring(ChapterMap.ALGO_VERSION)
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

    -- 每读一个 spine 文件发一次心跳(只作活动信号,不在文件中途响应取消),
    -- 免得特大书的纯 CPU 匹配被看门狗当成死吊。
    local map_count = 0
    local spine_total = #(meta.spine or {})
    local mapped_new, unmatched_new = {}, {}
    if #todo > 0 then
        mapped_new, unmatched_new = ChapterMap.build(meta.spine, function(href)
            map_count = map_count + 1
            step("map", map_count, spine_total, href)
            return deps.read_text(meta, href)
        end, todo)
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
    if #mapped == 0 then
        return nil, "没有任何章节能匹配到本地书,请确认绑定的和本地打开的是同一本书"
    end
    -- 未匹配章节连带损失的划线数(报告要能说清"失败带走了多少")。
    local underlines_by_uid = {}
    for _, ch in ipairs(fetched) do underlines_by_uid[tostring(ch.uid)] = #(ch.underlines or {}) end
    local unmatched_underlines = 0
    for _, row in ipairs(unmatched) do
        unmatched_underlines = unmatched_underlines + (underlines_by_uid[tostring(row.uid)] or 0)
    end

    if not step("inject", 0, 1) then return nil, "已取消" end
    -- 注入到中间文件(无 .epub 后缀,不会闪现在书架),成功后原子换位。
    local temp_dest = doc_path .. ".pickthought-new"
    local stats, inject_err = deps.inject(src, deps.book_id, mapped, temp_dest)
    if not stats then return nil, inject_err end

    -- 重叠划线被合并的,把想法并进存活锚点的组:点一个虚线看到这一段全部想法。
    if deps.merge_thoughts then
        for _, merge in ipairs(stats.merges or {}) do
            pcall(deps.merge_thoughts, deps.book_id, merge.uid, merge.from, merge.into)
        end
    end

    if src == doc_path then
        -- 首次:原书让位为备份,注入版顶上原路径(进度侧车不动)。
        local ok_backup, backup_err = rename(doc_path, backup)
        if not ok_backup then
            remove(temp_dest)
            return nil, "无法备份原书:" .. tostring(backup_err or "重命名失败")
        end
    end
    local ok_swap, swap_err = rename(temp_dest, doc_path)
    if not ok_swap then
        remove(doc_path)
        ok_swap, swap_err = rename(temp_dest, doc_path)
    end
    if not ok_swap then
        remove(temp_dest)
        -- 回滚:无论首次还是重同步,书架路径上必须留有可读的书。
        if not file_exists(doc_path) then rename(backup, doc_path) end
        return nil, "无法替换原书:" .. tostring(swap_err or "重命名失败")
    end

    return {
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
        total_underlines = total_underlines,
        total_thought_entries = total_thought_entries,
        unmatched = unmatched,
        unmatched_underlines = unmatched_underlines,
        fetch_errors = hard_failures + partial_errors,
    }
end

return Sync
