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
--   clean_source    可选:外部干净 .epub 路径,作为注入源绕开脏/缺失的 .orig
--   copy_file       可选:(src,dst)->ok 复制文件,默认 U.copy_file(固化 .orig 用)
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
    -- 统一恢复封装:检查 rename 返回值,失败返回明确错误(避免"已恢复"与实际不符,P1#2)。
    local function try_recover(from, to)
        local ok, e = rename(from, to)
        if not ok then return nil, "恢复动作失败(" .. tostring(e or "rename 失败") .. ")" end
        return true
    end
    -- 默认用流式复制(分块读写 + 进度心跳),避免大书一次性读入内存触发 OOM(P1#1)。
    local copy_file = deps.copy_file or function(a, b)
        return U.copy_file_stream(a, b, function(done, total)
            -- 必须 return step(...) 的布尔值:progress 返回 false(取消)时,
            -- 该 false 需透传到 U.copy_file_stream 的 res==false 判定,
            -- 否则取消信号在默认复制路径上被吞掉、会继续完成 .orig 固化与原书替换。
            return step("copy", done, total, "固化干净源")
        end)
    end

    -- 已有注入版时,增量同步直接以当前书为源;首次/全量重建才从 .orig 读取。
    local doc_path = tostring(deps.doc_path)
    local backup = Sync.backup_path(doc_path)
    -- 旧 .orig 备份恢复:把 .orig.old 还原为标准 .orig 路径(作者 2026-08-19 意见 #1)。
    -- 仅当 .orig.old 存在时有动作;.orig 目标若已存在(新固化残缺/半成品)先移除再还原
    -- (Windows rename 不允许覆盖已存在目标)。返回 true 或 nil,err。
    local function restore_backup_old()
        local old_backup = backup .. ".old"
        if not file_exists(old_backup) then return true end
        if file_exists(backup) then
            local ok_rm = remove(backup)
            if not ok_rm then
                return nil, "无法移除残缺的 .orig 目标(" .. tostring(backup) .. ")"
            end
        end
        return try_recover(old_backup, backup)
    end
    local current_meta, current_meta_err = deps.load_meta(doc_path)
    -- 当前 EPUB 存在但解析失败(损坏):绝不能当作"干净原书"继续,
    -- 否则下面 rename(doc_path, backup) 会把损坏文件当原书备份/销毁(P1#2, 2026-08-15 二轮)。
    -- 必须在任何 rename/copy 前中止,且保证 doc_path/.orig/.old 都不被改动。
    if not current_meta and file_exists(doc_path) then
        return nil, "当前 EPUB(" .. tostring(doc_path) .. ") 已损坏无法解析,已中止操作(未改动任何文件);"
            .. "请手动恢复原书,或指定一份可用的干净源后重试"
    end
    local append = deps.append == true and current_meta and current_meta.has
        and current_meta.has[EpubInject.MARKER] == true

    -- ① 干净源逃生口:允许指定外部干净 .epub 作注入源,绕开脏/缺失的 .orig。
    -- 仅当该源存在且不含注入标记时才采用;与 doc_path/.orig 相同则按既有逻辑走。
    local clean_source = deps.clean_source and tostring(deps.clean_source) or nil
    local clean_meta, clean_err
    if clean_source and clean_source ~= doc_path and clean_source ~= backup then
        if not file_exists(clean_source) then
            return nil, "指定的干净源不存在:" .. clean_source
        end
        clean_meta, clean_err = deps.load_meta(clean_source)
        if not clean_meta then
            return nil, "指定的干净源无法读取:" .. tostring(clean_err)
        end
        if clean_meta.has and clean_meta.has[EpubInject.MARKER] then
            return nil, "指定的干净源本身已是注入版,不能作为干净源;请换一份原书"
        end
    else
        clean_source = nil
    end

    local src = append and doc_path
        or (clean_source or (file_exists(backup) and backup or doc_path))

    local meta, meta_err
    if src == clean_source and clean_meta then
        meta = clean_meta
    else
        meta, meta_err = deps.load_meta(src)
    end
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
        -- 指纹 = 源书大小 + 匹配算法版本 + 内容指纹:换书/改算法/改内容都让旧映射作废重建。
        -- 内容指纹取文件头尾采样做 FNV-1a,避免"同体积不同内容"的 EPUB 复用旧章节映射/缓存(P2, 2026-08-15 二轮)。
        -- 指定 clean_source 重建时,映射必须基于干净源本身(而非可能版本不同的 .orig/当前书),
        -- 故把 clean_source 的规范化路径也纳入签名;并强制废弃旧映射缓存,杜绝复用。
        local use_clean = (src == clean_source and clean_source) or nil
        local map_source = use_clean or (file_exists(backup) and backup) or doc_path
        -- 作者意见 #6:clean_source 完整路径含分隔符,直接进签名会让分隔符落入缓存目录名,
        -- 生成异常嵌套目录;改为对路径做哈希(定长、无分隔符)。
        local src_sig = use_clean and ("@" .. U.path_hash(use_clean)) or ""
        local fingerprint = U.content_fingerprint(map_source) or "0"
        map_signature = tostring(U.file_size(map_source) or 0) .. "@"
            .. tostring(ChapterMap.ALGO_VERSION) .. "@" .. fingerprint .. src_sig
        if use_clean then
            -- 指定干净源:强制废弃旧映射缓存,避免同体积不同内容复用旧 spine/map(P2)。
            map_store = {}
        else
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
    local kept_original = nil  -- 作者第8轮:干净原书被暂存为 .old 时记录路径,成功后保留不删
    if src == doc_path and not append then
        -- 首次:原书让位为备份,注入版顶上原路径(进度侧车不动)。
        local ok_backup, backup_err = rename(doc_path, backup)
        if not ok_backup then
            remove(temp_dest)
            return nil, "无法备份原书:" .. tostring(backup_err or "重命名失败")
        end
        backed_up = true
    elseif clean_source and src == clean_source and not append then
        -- 从外部干净源全量重建。
        -- 中断残留恢复(作者 2026-08-19 意见 #2):上一进程可能中断在"主书已移入 .old、
        -- 新书尚未换回"阶段,此时 doc_path 缺失而 .old 存在——.old 是最后可恢复副本,
        -- 必须恢复回 doc_path 而非删除,否则丢失最后副本、后续重建也因原书路径不存在而失败。
        -- 仅当 doc_path 存在且可解析时,.old 才是可安全清理的陈旧残留。
        local old_path = doc_path .. ".old"
        if file_exists(old_path) then
            if not file_exists(doc_path) then
                local ok_recover, rec_err = try_recover(old_path, doc_path)
                if not ok_recover then
                    remove(temp_dest)
                    return nil, "检测到中断残留(主文件缺失,但存在 " .. old_path .. "),且自动恢复失败;"
                        .. "请手动将 " .. old_path .. " 重命名为 " .. doc_path .. " 以恢复原书。("
                        .. tostring(rec_err or "未知") .. ")"
                end
                -- 恢复后重新解析当前书(可能是注入版或干净书),统一走下方分支;
                -- 解析失败(恢复副本损坏)必须中止并保留恢复出的文件,绝不把损坏副本
                -- 当干净书继续,否则成功后会清掉最后一份可恢复文件(作者 2026-08-20 第7轮意见①)。
                current_meta, current_meta_err = deps.load_meta(doc_path)
                if not current_meta then
                    remove(temp_dest)
                    return nil, "中断残留已恢复(" .. tostring(old_path) .. " → " .. tostring(doc_path)
                        .. "),但恢复出的副本无法解析(" .. tostring(current_meta_err or "未知") .. ");"
                        .. "已中止后续流程并保留该文件,请更换可用干净源后重试"
                end
            else
                -- 主路径存在:确认可解析才认定 .old 为陈旧残留,否则保留(不删除)。
                local meta_ok = pcall(function() return deps.load_meta(doc_path) end)
                if not meta_ok then
                    remove(temp_dest)
                    return nil, "当前 EPUB 已损坏且存在暂存 " .. old_path .. ",已中止操作(未删除任何文件);"
                        .. "请先处理损坏文件或指定可用干净源"
                end
                -- 关键 P1 修复(作者文件保留边界):若 .old 是上一次重建保留的原始干净书
                -- (无注入 MARKER,来自 kept_original),它不是陈旧残留,绝不能在此删除——
                -- 否则连续两次 clean_source 重建会销毁用户最初的干净原书。跳过清理,
                -- 交由下方 is_current_injected 分支改名 .old.kept 保留。
                local old_meta_ok, old_meta = pcall(function() return deps.load_meta(old_path) end)
                if old_meta_ok and old_meta and old_meta.has and old_meta.has[EpubInject.MARKER] ~= true then
                    -- 保留的原始干净书:不在此清理,留待后续分支处理。
                else
                    local ok_rm, rm_err = remove(old_path)
                    if not ok_rm then
                        remove(temp_dest)
                        return nil, "无法清理旧的暂存文件,请重试"
                    end
                end
            end
        end
        -- 安全前置(P1#3):确认当前 doc_path 确实是注入版;若当前仍是干净原书
        -- (如首次注入中途失败),不能把它当"旧注入版"丢进 .old 销毁——否则不同版本的
        -- 原书会被永久丢弃。此时应保留为 .orig 备份(与首次注入一致),干净源仅作注入来源。
        local is_current_injected = current_meta and current_meta.has
            and current_meta.has[EpubInject.MARKER] == true
        if is_current_injected then
            -- 脏注入版先暂存为 .old 以便失败回滚,再把干净源固化为 .orig 备份。
            local old_path = doc_path .. ".old"
            if file_exists(old_path) then
                -- 关键 P1 修复(作者文件保留边界):若已存在的 .old 是上一次重建保留的
                -- 原始干净书(无注入 MARKER,来自"当前书是干净原书"分支的 kept_original),
                -- 绝不能删除或覆盖它——否则连续两次 clean_source 重建会销毁用户最初的干净原书。
                -- 改为改名 .old.kept 让出 .old 给当前脏注入版作回滚暂存,并记入 kept_original 跳过成功清理。
                local ok_meta, old_meta = pcall(function() return deps.load_meta(old_path) end)
                if ok_meta and old_meta and old_meta.has and old_meta.has[EpubInject.MARKER] ~= true then
                    local kept_path = doc_path .. ".old.kept"
                    if file_exists(kept_path) then
                        local ok_rk = remove(kept_path)
                        if not ok_rk then
                            remove(temp_dest)
                            return nil, "无法清理旧的保留干净书,请重试"
                        end
                    end
                    if not rename(old_path, kept_path) then
                        remove(temp_dest)
                        return nil, "无法保留原始干净书(.old→.old.kept),请重试"
                    end
                    kept_original = kept_path
                else
                    local ok_rm, rm_err = remove(old_path)
                    if not ok_rm then
                        remove(temp_dest)
                        return nil, "无法清理旧的暂存文件,请重试"
                    end
                end
            end
            if not rename(doc_path, old_path) then
                remove(temp_dest)
                return nil, "无法暂存原注入版(请先关闭本书或确认未被占用)"
            end
            local ok_copy, copy_err, copy_status = copy_file(clean_source, backup)
            if not ok_copy then
                remove(temp_dest)
                if copy_status == "cancelled" then
                    -- 复制被用户取消:doc_path 已暂存为 .old,恢复回去;backup 未被改动。
                    local ok_restore, restore_err = try_recover(old_path, doc_path)
                    if ok_restore then
                        return nil, "已取消干净源固化,已恢复原注入版(.old→doc_path)"
                    end
                    return nil, "已取消干净源固化,但无法恢复当前注入版;请手动将 "
                        .. old_path .. " 重命名为 " .. doc_path .. " 以恢复原书。(" .. tostring(restore_err or "未知") .. ")"
                end
                -- 固化失败:尽量回滚 .old → doc_path,恢复结果必须检查(P1#2)。
                local ok_restore, restore_err = try_recover(old_path, doc_path)
                if ok_restore then
                    return nil, "干净源固化到 .orig 失败,已恢复原注入版(.old→doc_path);后续重注需再次指定干净源"
                end
                -- 恢复失败:保留 .old 作人工恢复入口,明确告知实际位置。
                return nil, "干净源固化到 .orig 失败,且无法恢复当前注入版;请手动将 "
                    .. old_path .. " 重命名为 " .. doc_path .. " 以恢复原书。(" .. tostring(restore_err or "未知") .. ")"
            end
            backed_up = true
        else
            -- 当前书是干净原书,且指定了外部 clean_source(可能与当前书版本不同)。
            -- 统一注入基线:.orig 必须是注入基线 clean_source(而非当前不同版本的书),
            -- 并把当前书暂存为 .old 保留,避免用户打开的版本被覆盖销毁(作者意见 #4)。
            local old_path = doc_path .. ".old"
            if file_exists(old_path) then
                local ok_rm = remove(old_path)
                if not ok_rm then remove(temp_dest); return nil, "无法清理旧的暂存文件,请重试" end
            end
            if file_exists(backup) then
                local old_backup = backup .. ".old"
                if file_exists(old_backup) then
                    local ok_rm2 = remove(old_backup)
                    if not ok_rm2 then remove(temp_dest); return nil, "无法清理旧备份暂存,请重试" end
                end
                if not rename(backup, old_backup) then
                    remove(temp_dest); return nil, "无法暂存旧 .orig 备份,请重试"
                end
            end
            -- 固化注入基线(clean_source)为 .orig,使最终 .orig 与注入源一致(作者意见 #4)。
            local ok_copy, copy_err, copy_status = copy_file(clean_source, backup)
            if not ok_copy then
                remove(temp_dest)
                -- 旧 .orig(.orig.old)必须还原为标准路径,否则后续直接重注误报缺备份
                -- (作者 2026-08-19 意见 #1)。此时 doc_path 尚未离位(原书完好)。
                local rb_ok, rb_err = restore_backup_old()
                local rb_hint
                if rb_ok then
                    rb_hint = "旧 .orig 备份已恢复(.orig.old→.orig)"
                else
                    rb_hint = "旧 .orig 备份恢复失败(" .. tostring(rb_err or "未知") .. "),请手动将 "
                        .. (backup .. ".old") .. " 重命名为 " .. backup .. " 以恢复备份"
                end
                if copy_status == "cancelled" then
                    -- 取消发生在固化 .orig 之前:当前干净原书尚未离位(doc_path 仍完好),
                    -- 直接报取消即可,不要谎称"无法恢复"(作者意见 #1/#2)。
                    return nil, "已取消干净源固化,原书未改动(" .. tostring(doc_path) .. ");" .. rb_hint
                end
                return nil, "干净源固化到 .orig 失败,原书未改动(" .. tostring(doc_path) .. ");"
                    .. rb_hint .. ";后续重注需再次指定干净源"
            end
            -- 暂存当前书为 .old(保留用户打开的版本),让出原路径供 swap。
            if not rename(doc_path, old_path) then
                remove(temp_dest)
                -- 复制已成功、但主书暂存失败:必须完整回滚,使文件状态与操作前一致
                -- (否则 .orig 已换成新版本而 doc_path 仍是旧版本,后续重注会使用不匹配的
                -- 备份——作者 2026-08-20 第7轮意见②)。restore_backup_old 内部先移除
                -- 新副本再恢复旧 .orig(.orig.old → .orig)。
                local rb_ok, rb_err = restore_backup_old()
                if rb_ok then
                    return nil, "干净源已固化但无法暂存当前书(.old),已回滚旧 .orig 备份并清理新副本;"
                        .. "请关闭本书或确认未被占用后重试"
                end
                return nil, "干净源已固化但无法暂存当前书(.old),且旧 .orig 备份回滚失败("
                    .. tostring(rb_err or "未知") .. ");请手动将 " .. (backup .. ".old")
                    .. " 重命名为 " .. backup .. " 以恢复备份"
            end
            -- 本分支:当前书是干净原书、指定了外部 clean_source 重建。暂存为 .old 的
            -- 是用户原本打开的干净原书(可能与 clean_source 版本不同),并非脏注入版临时
            -- 暂存。成功 swap 后 MUST 保留而非走通用 .old 清理逻辑删除(作者第8轮意见):
            -- 否则不同版本的原始干净书会被永久销毁。标记 kept_original 跳过清理并提示恢复。
            kept_original = old_path
            backed_up = true
        end
    end
    local ok_swap, swap_err = rename(temp_dest, doc_path)
    if not ok_swap then
        remove(temp_dest)
        -- 首次注入/干净源重建已让原书离位时才需要回滚。增量失败时旧注入版仍在原路径，
        -- 绝不能删除它或移动干净 .orig；上一代只在原子替换成功时由系统丢弃。
        if backed_up and not file_exists(doc_path) then
            -- 统一恢复逻辑:优先恢复原始注入版(.old),其次恢复干净 .orig(作者意见 #2)。
            -- 必须记录"实际恢复的是哪一份",提示与实际文件状态一致,绝不谎称已恢复旧注入版。
            local recovered, rec_err, recovered_from
            local old_path = doc_path .. ".old"
            if file_exists(old_path) then
                recovered, rec_err = try_recover(old_path, doc_path)
                recovered_from = "old"
                if not recovered and file_exists(backup) then
                    recovered, rec_err = try_recover(backup, doc_path)
                    recovered_from = "clean"
                end
            elseif file_exists(backup) then
                recovered, rec_err = try_recover(backup, doc_path)
                recovered_from = "clean"
            end
            if not recovered then
                local msg = "无法替换原书(" .. tostring(swap_err or "rename 失败") .. ")"
                if file_exists(old_path) then
                    msg = msg .. ";当前注入版暂存于 " .. old_path .. ",请手动恢复"
                elseif file_exists(backup) then
                    msg = msg .. ";干净原书备份位于 " .. backup .. ",请手动恢复"
                end
                if rec_err then msg = msg .. "。恢复动作失败:" .. tostring(rec_err) end
                return nil, msg
            end
            -- 恢复成功:提示必须与实际文件状态一致(作者意见 #2)。
            -- 旧 .orig(.orig.old)同样要还原,否则后续重注误报缺备份(作者 2026-08-19 意见 #1)。
            local rb_ok, rb_err = restore_backup_old()
            local rb_hint = ""
            if not rb_ok then
                rb_hint = ";但旧 .orig 备份(.orig.old)未能自动恢复,请手动将 "
                    .. (backup .. ".old") .. " 重命名为 " .. backup .. " 以恢复备份("
                    .. tostring(rb_err or "未知") .. ")"
            end
            if recovered_from == "clean" then
                return nil, "无法替换原书,已恢复干净原书(.orig→doc_path):" .. tostring(swap_err or "重命名失败") .. rb_hint
            end
            return nil, "无法替换原书,已恢复暂存副本(.old→doc_path):" .. tostring(swap_err or "重命名失败") .. rb_hint
        end
        return nil, "无法替换原书,已恢复原文件:" .. tostring(swap_err or "重命名失败")
    end
    -- 重建成功:清理暂存的脏 .old / 旧 .orig 暂存(已无回滚需要,且避免占用空间)。
    -- 清理结果必须检查:失败残留的 .orig.old 可能被后续误当有效旧备份恢复,须明确
    -- 记录并随报告提示(作者 2026-08-20 第7轮意见③)。
    local cleanup_warnings = {}
    local old_path = doc_path .. ".old"
    if file_exists(old_path) then
        -- 作者第8轮:本 .old 是原始干净书(kept_original)时保留不删,供用户手动恢复;
        -- 其余脏暂存 .old(脏注入版临时回滚)才清理。
        if old_path == kept_original then
            logger.info("[撷思][Sync] 原始干净书已保留于 " .. tostring(old_path) .. ",不清理(供恢复)")
        else
            local ok_rm = remove(old_path)
            if not ok_rm then
                cleanup_warnings[#cleanup_warnings + 1] = "无法清理暂存文件 " .. tostring(old_path)
                logger.warn("[撷思][Sync] 成功重建后清理 .old 失败", old_path)
            end
        end
    end
    local old_backup = backup .. ".old"
    if file_exists(old_backup) then
        local ok_rm = remove(old_backup)
        if not ok_rm then
            cleanup_warnings[#cleanup_warnings + 1] = "无法清理旧备份暂存 " .. tostring(old_backup)
            logger.warn("[撷思][Sync] 成功重建后清理 .orig.old 失败", old_backup)
        end
    end

    local underlines_injected = math.min(total_underlines,
        math.max(0, tonumber(stats.underlines_resolved) or 0))
    local thoughts_injected = math.max(0, tonumber(stats.thoughts_linked) or 0)
    thoughts_injected = math.min(total_thought_entries, math.max(0, thoughts_injected))
    return with_batch_fields{
        dest = doc_path,
        backup = backup,
        clean_source = clean_source,
        -- 成功收尾时暂存清理失败的警告(作者 2026-08-20 第7轮意见③),报告层展示。
        cleanup_warnings = #cleanup_warnings > 0 and cleanup_warnings or nil,
        -- 作者第8轮:原始干净书被暂存为 .old 并保留时,记录路径供报告提示手动恢复。
        kept_original = kept_original,
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
