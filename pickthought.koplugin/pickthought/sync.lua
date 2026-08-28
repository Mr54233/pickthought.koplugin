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
local SpineCache = require("pickthought.spine_cache")
local logger = require("logger")

local Sync = {}

-- 绑定支持「一本本地书绑多本微信读书书」(合集/套装 EPUB)。book_ids 为列表;
-- 未提供时回退到单个 deps.book_id(旧调用方/旧测试保持原样)。去重保序。
local function book_ids_of(deps)
    if type(deps.book_ids) == "table" and #deps.book_ids > 0 then
        local seen, out = {}, {}
        for _, b in ipairs(deps.book_ids) do
            local s = tostring(b or "")
            if s ~= "" and not seen[s] then seen[s] = true; out[#out + 1] = s end
        end
        if #out > 0 then return out end
    end
    if deps.book_id then return {tostring(deps.book_id)} end
    return {}
end

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

    -- 绑定支持「一本本地书绑多本微信读书书」。book_ids 为列表;未提供时
    -- 回退到单个 deps.book_id,旧调用方/旧测试行为不变。
    local book_ids = book_ids_of(deps)
    if #book_ids == 0 then return nil, "未指定要同步的微信读书书" end
    local multi_book = #book_ids > 1
    -- 多书合并映射的缓存键命名空间(防跨书 uid 撞键);单书退化为纯 uid,缓存格式不变。
    local function ck(bid, uid) return multi_book and (tostring(bid) .. "/" .. tostring(uid)) or tostring(uid) end
    -- 映射缓存路径:可传函数(每书独立文件)或字符串(单书单文件,旧行为)。
    local function cache_path_for(bid)
        if type(deps.map_cache_path) == "function" then return deps.map_cache_path(bid) end
        return deps.map_cache_path
    end

    -- 已有注入版时,增量同步直接以当前书为源;首次/全量重建才从 .orig 读取。
    -- 多书合并注入必须基于干净 .orig 整体重建,不能走增量 append(否则漏书)。
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
    -- 多书必须整体重建(不能走增量 append),单书才允许增量 append(沿用 PR 守卫)。
    local append = (not multi_book) and deps.append == true and current_meta and current_meta.has
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

    -- 每本书独立拉取,累积到同一 fetched 列表;每章携带 book_id 供后续
    -- save_thoughts / 注入 / 想法合并正确定位到对应书。
    local fetched = {}
    local total_underlines = 0
    local total_thought_entries = 0
    local chapters_total_all = 0
    -- fetch_budget 是网络预算; chapter_budget 是 CPU/注入预算,两者不能混用。
    local fetch_budget = tonumber(deps.fetch_budget)
    if fetch_budget and fetch_budget <= 0 then fetch_budget = nil end
    local chapter_budget = tonumber(deps.chapter_budget)
    if chapter_budget and chapter_budget <= 0 then chapter_budget = nil end
    local skip_resumed = deps.skip_resumed == true
    local chapters_pending = 0
    local rate_limited = false
    local rate_limit_wait
    local next_index
    local batch_start_index, batch_end_index
    -- 续传游标按书保存(P1#5):每本书一份 {next_index, pending, total, start},
    -- 避免多书时全局 next_index 被末本覆盖、state.json 写入聚合值。
    local per_book = {}
    local chapters_processed, chapters_fetch_succeeded = 0, 0
    -- 硬失败=整章划线都没拉到(决定是否中止);部分失败=划线在手、想法批次有缺(只计报告)。
    local hard_failures, partial_errors = 0, 0
    local thoughts_saved, save_failures = 0, 0
    local thought_save_failed = {}
    -- 多书按书隔离:预算消耗 / 连续失败 / 限速状态每本独立(book_fresh_fetches、
    -- book_consecutive_hard / book_rate_limited 在 fetch_book 内局部化,结束处聚合进报告)。
    -- 第一本耗尽预算或触发限速/熔断不得影响后续书(评审二轮 P1#2)。
    local failed_books = {}
    -- 暂缓书列表(评审八轮 P1#1):冷却书部分缓存命中、剩余章 deferred——非失败、
    -- 也非真正完成,报告据此不得显示「全部完成」,状态不写 .completed。
    local deferred_books = {}
    -- 记住最后一次真实错误:失败消息必须告诉用户到底错在哪,不能只说「网络失败」。
    local last_error
    local function short_err(text)
        text = tostring(text or "未知错误"):gsub("^.-%.lua:%d+:%s*", "")
        if #text > 160 then text = text:sub(1, 160) .. "…" end
        return text
    end

    -- 单本书的拉取(含续拉预算/熔断)。多书时每本都从头拉(各书独立续拉暂不支撑)。
    local function fetch_book(bid)
        -- 每本书独立的预算/限速/连续失败状态:第一本耗尽预算或触发限速/熔断,
        -- 不得影响后续书(评审二轮 P1#2)。
        local book_fresh_fetches = 0
        local book_consecutive_hard = 0
        local book_rate_limited = false
        local book_rate_limit_wait
        if not step("chapters", 0, 1, "获取章节列表") then return nil, "已取消" end
        local ok, chapters_raw = pcall(function() return deps.api:chapters(bid) end)
        if not ok then
            local msg = "获取章节列表失败:" .. tostring(chapters_raw)
            if multi_book then
                -- 章节列表拉取失败:本书软失败。记录失败态与续传起点,不写 pending
                -- (未知)以免 sync_task 误判「完成」(评审三轮 P1#1)。多书恒为全量重建
                -- (append=false)→续传起点恒为 1,下次同步仍可从头经断点缓存续传。
                per_book[bid] = {failed = true, error = msg,
                    next_index = 1, pending = nil, total = 0, start = 1}
                return false, msg -- 多书:本书软失败,继续下一本
            end
            return nil, msg
        end
        local chapter_list = Binding.normalize_chapters(chapters_raw, bid)
        chapters_total_all = chapters_total_all + #chapter_list
        if #chapter_list == 0 then
            if multi_book then
                -- 章节列表为空:明确失败态,不得当「成功」返回(评审五轮 P1#2)。
                -- 否则任务层按空状态生成 .completed,失败书被误标完成、续传入口消失。
                -- pending=nil(剩余未知)保持缺失语义,聚合端不得当作 0。
                per_book[bid] = {failed = true, error = "微信读书返回的章节列表为空",
                    next_index = 1, pending = nil, total = 0, start = 1}
                return false, per_book[bid].error
            end
            return nil, "微信读书返回的章节列表为空"
        end
        -- 续传起点按书取:优先 deps.chapter_starts[bid](多书按书),回退 deps.chapter_start。
        -- 多书强制 append=false 时会在此被重置为 1(整体从 .orig 重建)。
        local chapter_start = math.max(1, tonumber(
            (deps.chapter_starts and deps.chapter_starts[bid]) or deps.chapter_start) or 1)
        if not append then chapter_start = 1 end
        local selected_end = #chapter_list
        if (not multi_book) and (not skip_resumed) and chapter_budget then
            selected_end = math.min(#chapter_list, chapter_start + chapter_budget - 1)
        end
        local i = chapter_start
        local book_next = chapter_start
        -- 本书独立的待处理章节计数,最后并入聚合 chapters_pending 并记入 per_book。
        local book_pending = 0
        -- 本章是否已被实际注入/保存(用于区分「失败前有无有效产出」)。
        -- 失败且未贡献任何章节 → 单书致命 / 多书软失败;失败但已有贡献 → 部分提交。
        local book_contributed = false
        local book_last_contrib_resumed = false  -- 最近一次贡献章节是否断点缓存命中(决定硬失败后是否部分提交)
        local book_failed, book_failed_index, book_failed_reason
        -- 想法缓存写入失败:本章划线已注入,但该书本轮未真正完成,须禁止生成 .completed
        -- 并保留当前章续传位置(评审十轮 P1#2)。
        local book_thought_incomplete
        -- 冷却书缓存未命中:本书标记 deferred(非失败、非完成),游标停在首个缺失章。
        local book_deferred, book_deferred_index
        -- 本书批次起止(逐书记录,避免全局累加器被末本覆盖,P1#4)。
        local book_batch_start, book_batch_end
        -- 本书进入前 fetched 长度,熔断(整书失败)时据此回退剔除本书已加入的章节,
        -- 避免失败书的残缺数据混入注入(见 test 断点缓存命中不复位熔断计数)。
        local book_fetch_start = #fetched
        while i <= #chapter_list do
            local ch = chapter_list[i]
            ch.book_id = bid
            if fetch_budget and book_fresh_fetches >= fetch_budget then
                book_pending = book_pending + (#chapter_list - i + 1)
                break
            end
            if (not multi_book) and (not skip_resumed) and i > selected_end then
                book_pending = book_pending + (#chapter_list - i + 1)
                break
            end
            if not step("fetch", i, #chapter_list, ch.title) then return nil, "已取消" end
            local good, data = pcall(function()
                return deps.annotations:fetch_chapter(bid, ch.uid)
            end)
            -- 预算按"网络请求次数"计:缓存命中(resumed)免费,失败的尝试也占额度。
            if not (good and type(data) == "table" and data.resumed) then
                book_fresh_fetches = book_fresh_fetches + 1
            end
            -- 冷却书缓存未命中:明确 deferred 状态(评审八轮 P1#1)。该章未实际拉取、
            -- 不得计入已处理、不推进游标;续传游标停在第一个缺失章节,剩余章节计入
            -- pending;报告显示该书暂缓/剩余待同步,绝不显示「全部完成」;原有
            -- retry_after 保留(冷却结束后再补拉)。resumed=true 仅用于不占网络预算。
            if good and type(data) == "table" and data.deferred == true then
                book_deferred = true
                book_deferred_index = i
                book_next = i
                book_pending = book_pending + (#chapter_list - i + 1)
                break
            end
            local chapter_rate_limited = good and type(data) == "table" and data.rate_limited == true
            local skipped_completed_cache = good and type(data) == "table"
                and data.resumed and skip_resumed
            if chapter_rate_limited then
                book_rate_limited = true
                book_rate_limit_wait = tonumber(data.rate_limit_wait) or book_rate_limit_wait
        elseif good and type(data) == "table" and data.resumed and skip_resumed and not multi_book then
            -- 单书增量续传:当前注入版已含旧批内容,完整缓存只扫描寻找新增/缺失章节,
            -- 不重复写库和重注入旧章节。多书场景恒为全量重建(append=false/.orig),
            -- 旧批内容不在当前书,必须随本次重建重新注入,故多书不在此跳过、走下一分支
            -- 合并缓存内容,避免「第二批只新增一本书导致其他书的旧划线和想法消失」(P1#3)。
        elseif good and type(data) == "table" and data.underline_request_ok ~= false then
                -- 断点缓存命中(resumed)不算网络成功,不能复位熔断计数:
                -- 离线续传时散布的缓存命中会把计数清零,让熔断永不触发。
                if not data.resumed then book_consecutive_hard = 0 end
                if #(data.errors or {}) > 0 then
                    -- 章节拉取返回错误(想法批次等):本章视为失败,停在当前章、不注入、
                    -- 计入拉取错误;已有成功章节则部分提交,否则依多书/单书决定软失败或致命
                    -- (评审四轮 P1#3:失败章节不得进入注入与 .completed)。
                    partial_errors = partial_errors + 1
                    book_failed = true
                    book_failed_index = i
                    book_failed_reason = "划线拉取失败: " .. short_err(tostring((data.errors or {})[1] or "接口返回异常"))
                    break
                end
                total_underlines = total_underlines + (data.underline_count or 0)
                total_thought_entries = total_thought_entries + (data.thought_entry_count or 0)
                if (data.underline_count or 0) > 0 then
                    fetched[#fetched + 1] = {
                        uid = ch.uid, title = ch.title, book_id = bid,
                        underlines = data.underlines, review_map = data.review_map,
                    }
                    book_contributed = true
                    book_last_contrib_resumed = data.resumed == true
                end
                if #(data.review_groups or {}) > 0 then
                    local ok_save, saved = pcall(deps.save_thoughts, ch.book_id, ch.uid, data.review_groups)
                    if ok_save and saved then
                        thoughts_saved = thoughts_saved + 1
                    else
                        save_failures = save_failures + 1
                        -- 统一复合键 book_id+UID,与 epub_inject 的 thoughts_linked_by_uid 对齐
                        -- (多书场景同 uid 不串键,成功/失败数量才准)。见评审二轮 P1#5。
                        thought_save_failed[ck(ch.book_id, ch.uid)] = true
                        -- 想法缓存写入失败:本章划线已加入 fetched 照常注入(不回滚已拉划线),
                        -- 但本书本轮未真正完成——标记未完成、停在当前章、剩余章计入 pending、禁止
                        -- 生成 .completed(评审十轮 P1#2)。下次同步从当前章续传:重注本章划线为幂等,
                        -- 重试想法缓存写入;失败的章节不再因 pending=0 被误判为已完成。
                        book_thought_incomplete = true
                        book_failed = true
                        book_failed_index = i
                        book_failed_reason = "想法缓存写入失败,本章想法未保存(划线已注入,保留续传位置)"
                        break
                    end
                end
            else
                hard_failures = hard_failures + 1
                book_consecutive_hard = book_consecutive_hard + 1
                if not good then
                    last_error = tostring(data)
                elseif type(data) == "table" then
                    last_error = tostring((data.errors or {})[1] or last_error or "接口返回异常")
                end
                -- 断网熔断:连续多章整章硬失败(每章重试要吃满超时)不能逐章磨完全书。
                -- 连续 3 章硬失败且非末章即熔断(评审四轮 P1#3);末章的连续失败由下方收尾
                -- 逻辑按「拉取失败」统一报错。resumed(断点缓存命中)不复位 book_consecutive_hard
                -- (见 line 239),故离线续传中散布的缓存命中不会把连续计数清零、让熔断永不触发。
                if book_consecutive_hard >= 3 and i < #chapter_list then
                    -- 多书:本书熔断,记录完整续传状态(下一游标=失败章、待处理=剩余章、总量)
                    -- 继续下一本,不让第一本拖垮整批(评审二轮 P1#2);failed 标记阻止
                    -- sync_task 误写 .completed(评审三轮 P1#1),下次仍可从 i 续传(断点缓存命中)。
                    local remaining = #chapter_list - i + 1
                    per_book[bid] = {
                        failed = true,
                        error = string.format("连续 %d 章拉取失败,已中止本书同步: %s", book_consecutive_hard, short_err(last_error)),
                        next_index = i, pending = remaining,
                        total = #chapter_list, start = chapter_start,
                    }
                    -- 整书熔断:回退剔除本书已加入的章节(含断点缓存命中的),失败书数据不注入。
                    while #fetched > book_fetch_start do fetched[#fetched] = nil end
                    return false, per_book[bid].error
                elseif book_contributed then
                    -- 无论上一次贡献来自真实网络还是断点缓存命中,孤立硬失败都统一停在当前
                    -- 失败章、部分提交(评审四轮 P1#3 + 评审十轮 P1#1):失败章不进注入、游标停在
                    -- 失败章不递增、剩余章计入 pending,下次同步从失败章续传。不再因上一章是缓存
                    -- 命中就继续向后尝试(否则失败章被跳过、无法正确重试,见 test 缓存命中后失败
                    -- 仍停在失败章节)。真正「全无贡献的连续硬失败」由下方熔断分支(>=3)收口。
                    book_failed = true
                    book_failed_index = i
                    book_failed_reason = "划线拉取失败: " .. short_err(last_error)
                    break
                end
            end
            if not chapter_rate_limited and not skipped_completed_cache then
                book_batch_start = book_batch_start or i
                book_batch_end = i
                chapters_processed = chapters_processed + 1
                if good and type(data) == "table" and data.underline_request_ok ~= false
                    and #(data.errors or {}) == 0 then
                    chapters_fetch_succeeded = chapters_fetch_succeeded + 1
                end
            end
            book_next = book_rate_limited and i or (i + 1)
            if book_rate_limited then
                book_pending = book_pending + (#chapter_list - book_next + 1)
                break
            end
            i = i + 1
        end
        -- 本书限速状态聚合进报告级 rate_limited(多书任一书被限即整体标记,见 P1#4)。
        if book_rate_limited then
            rate_limited = true
            rate_limit_wait = book_rate_limit_wait or rate_limit_wait
        end
        if book_failed then
            -- 失败章节:游标停在失败章,待处理=剩余章节(含失败章本身),失败章不进注入
            -- (评审四轮 P1#3)。failed 标记阻止 sync_task 误写 .completed(评审三轮 P1#1)。
            book_next = book_failed_index
            book_pending = #chapter_list - book_failed_index + 1
        elseif book_deferred then
            -- 冷却书部分缓存命中:已缓存章照常注入,未命中章标记 deferred——游标停在
            -- 首个缺失章,剩余(含本)计入 pending;非失败、非完成,不写 .completed。
            book_next = book_deferred_index
            book_pending = #chapter_list - book_deferred_index + 1
        elseif book_pending == 0 and book_next ~= nil and book_next <= #chapter_list then
            book_pending = book_pending + (#chapter_list - book_next + 1)
        end
        -- 记录本书续传游标,并并入聚合 chapters_pending / next_index(P1#5)。
        per_book[bid] = {
            next_index = book_next,
            pending = book_pending,
            total = #chapter_list,
            start = chapter_start,
            batch_start = book_batch_start,
            batch_end = book_batch_end,
                    failed = book_failed or book_thought_incomplete or nil,
                    error = book_failed_reason,
                    -- 想法缓存写入失败:该书本轮未完成(划线已注入,想法待重试),sync_task 据此
                    -- 禁止生成 .completed、保留续传位置(评审十轮 P1#2)。
                    thought_save_incomplete = book_thought_incomplete or nil,
                    -- 冷却书缓存未命中:明确 deferred(评审八轮 P1#1),非失败、非完成;
                    -- sync_task 据此保留 retry_after、不写 .completed、报告显示暂缓。
                    deferred = book_deferred or nil,
                    -- 限速等待按书隔离(评审六轮 P2#3):只有实际触发限速的书带 retry_after,
                    -- 下一轮不再让未限速的书一起等待。
                    rate_limit_wait = book_rate_limited and book_rate_limit_wait or nil,
        }
        chapters_pending = chapters_pending + book_pending
        next_index = book_next
        return true
    end

    for _, bid in ipairs(book_ids) do
        local ok, err = fetch_book(bid)
        if ok == nil then
            -- 硬中止(用户取消 / 单书致命错误):直接退出整个同步。
            return nil, err
        elseif ok == false then
            -- 多书:本书软失败(章节列表拉取失败 / 章节列表为空 / 连续失败熔断),
            -- 记录后继续下一本,不让第一本拖垮整批(评审二轮 P1#2)。
            failed_books[#failed_books + 1] = bid
            -- 失败书已知的待处理章节计入聚合 chapters_pending(评审五轮 P1#2#3):
            -- 熔断书 pending=剩余章,若不计入,完成报告会同时显示「全书已处理完成」
            -- 与「某本书同步失败」;pending=nil(章节列表失败/为空 = 剩余未知)保持
            -- 缺失语义,聚合端不得当作 0 而吞掉失败书。
            local pb = per_book[bid]
            if pb and pb.pending then
                chapters_pending = chapters_pending + pb.pending
            end
        else
            -- 冷却书部分缓存命中、剩余章 deferred:非失败,但本报告轮未真正完成,
            -- 收集到 deferred_books 供报告层不显示「全部完成」(评审八轮 P1#1)。
            local pb = per_book[bid]
            if pb and pb.deferred then
                deferred_books[#deferred_books + 1] = bid
            end
        end
    end
    -- 聚合批次起止:单书时 batch_start/end 即本书真实章节区间,直接取本书;
    -- 多书时不同远程书的章节坐标是彼此独立的序列,不能拼成单一连续区间
    -- (评审四轮 P1#4),故多书聚合不输出合并区间(置 nil),逐书真实 range 由
    -- per_book[bid].batch_start/batch_end 承载,报告只展示聚合数量 + 逐书明细。
    batch_start_index = nil
    batch_end_index = nil
    if not multi_book then
        for _, bid in ipairs(book_ids) do
            local pb = per_book[bid]
            if pb and pb.batch_start then
                batch_start_index = math.min(batch_start_index or pb.batch_start, pb.batch_start)
                batch_end_index = math.max(batch_end_index or pb.batch_end, pb.batch_end)
            end
        end
    end
    -- 多书部分失败:若所有书都软失败且无任何章节数据,整体报错;
    -- 只要有书取到数据,就继续注入成功的部分(其余书的章节留在 fetched 之外,P1#2)。
    if #failed_books > 0 and #fetched == 0 then
        local msgs = {}
        for _, bid in ipairs(failed_books) do
            msgs[#msgs + 1] = tostring(bid) .. ": " .. tostring((per_book[bid] and per_book[bid].error) or "拉取失败")
        end
        return nil, "以下书同步失败:\n" .. table.concat(msgs, "\n")
    end
    local function with_batch_fields(report)
        report.batch_start = batch_start_index
        report.batch_end = batch_end_index
        report.chapters_processed = chapters_processed
        report.chapters_fetch_succeeded = chapters_fetch_succeeded
        report.batch_limit = chapter_budget or fetch_budget or chapters_total_all
        -- 多书标志:报告/弹窗层据此不推导单一连续章节范围(评审五轮 P1#1)。
        report.multi_book = multi_book or nil
        report.book_count = #book_ids
        -- 失败书列表:报告层据此不得显示「全部章节已处理完成」(评审六轮 P1#2)。
        report.failed_books = #failed_books > 0 and failed_books or nil
        -- 暂缓书:冷却书部分缓存命中、剩余章 deferred,非失败但非真正完成(评审八轮 P1#1)。
        report.deferred_books = #deferred_books > 0 and deferred_books or nil
        -- 按书续传游标,供调用方逐书写 state.json / .completed(P1#5)。
        report.per_book = per_book
        return report
    end
    -- 冷却书零划线(deferred):非失败、非完成(评审九轮 P1)。
    -- 即使本轮没有任何划线,也返回 deferred 报告,保留 pending/next_index/retry_after,
    -- 不生成 .completed,报告显示「同步暂缓」。不得落入下方「本批没有划线」失败分支
    -- (否则 sync_task 按普通失败清 .completed、丢失 retry_after,冷却书下次提前重发请求)。
    -- deferred 书在第 218 行即 break,不会贡献 hard_failures,此处优先于失败分支判定。
    if #deferred_books > 0 and #fetched == 0 then
        return with_batch_fields{
            deferred = true,
            chapters_total = chapters_total_all,
            chapters_pending = chapters_pending, next_index = next_index,
            total_underlines = 0, total_thought_entries = 0,
            chapters_with_data = 0, chapters_matched = 0,
            unmatched = {}, unmatched_underlines = 0,
            fetch_errors = hard_failures + partial_errors,
            rate_limited = rate_limited or nil,
            rate_limit_wait = rate_limit_wait,
        }
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
            return nil,                 string.format("本批 %d 章都没有划线;还剩 %d 章,再次同步继续拉取",
                chapters_total_all - chapters_pending, chapters_pending)
        end
        if not skip_resumed and not rate_limited then return nil, "这本书在微信读书里没有划线" end
        return with_batch_fields{
            no_changes = true, chapters_total = chapters_total_all,
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
        -- 故把 clean_source 的规范化路径也纳入签名;签名相同的连续重建可复用缓存。
        local use_clean = (src == clean_source and clean_source) or nil
        local map_source = use_clean or (file_exists(backup) and backup) or doc_path
        -- 作者意见 #6:clean_source 完整路径含分隔符,直接进签名会让分隔符落入缓存目录名,
        -- 生成异常嵌套目录;改为对路径做哈希(定长、无分隔符)。
        local src_sig = use_clean and ("@" .. U.path_hash(use_clean)) or ""
        local fingerprint = U.content_fingerprint(map_source) or "0"
        map_signature = tostring(U.file_size(map_source) or 0) .. "@"
            .. tostring(ChapterMap.ALGO_VERSION) .. "@" .. fingerprint .. src_sig
        -- 多书:汇总每本书的独立缓存文件(命名空间化键);单书:沿用原缓存文件。
        map_store = {}
        for _, bid in ipairs(book_ids) do
            local cp = cache_path_for(bid)
            local raw = U.read_file(cp, true)
            if raw then
                local ok_decode, decoded = pcall(Json.decode, raw)
                if ok_decode and type(decoded) == "table"
                    and tostring(decoded.signature) == map_signature
                    and type(decoded.map) == "table" then
                    for k, v in pairs(decoded.map) do
                        map_store[ck(bid, k)] = v
                    end
                end
            end
        end
    end

    -- 缓存值格式:{hrefs={...}, num=true|nil} = 目标文件列表(拆分章多目标),
    -- num 表示单目标强投票、允许数字兜底。未匹配结果不落盘,后续可重新尝试。
    local known, todo = {}, {}
    for _, ch in ipairs(fetched) do
        local key = ck(ch.book_id, ch.uid)
        local cached = map_store and map_store[key]
        if cached == nil or cached == false then
            -- false 是旧版本写入的"永久未匹配"结果,不能继续信任;重新加入待匹配。
            todo[#todo + 1] = ch
        elseif type(cached) == "table" and type(cached.hrefs) == "table" and #cached.hrefs > 0 then
            known[key] = cached
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

    -- B:spine 正文持久化缓存。仅当调用方显式开启 deps.spine_cache 且存在 map
    -- 缓存、且本批确有新章节要匹配(todo>0)时启用;测试不开启,行为完全不变。
    -- 第 2 批起直接读缓存文本,不再从 EPUB 解压每个 spine 文件、不再重复 normalize。
    local spine_cache
    if deps.spine_cache and deps.map_cache_path and #todo > 0 then
        -- map_cache_path 可能是函数(多书),需先解析为字符串;spine 缓存按 EPUB 物理文件,
        -- 多书共享同一本地书,取 book_ids[1] 即可。
        local resolved_mcp = cache_path_for(book_ids[1])
        local sc_dir = SpineCache.dir_for(resolved_mcp, map_signature)
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
                    if callback(item, html, html == nil and "缓存缺失" or nil, index) == false then
                        return false, "已取消"
                    end
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
                if callback(item, cached_read_text(m, item.href), nil, index) == false then
                    return false, "已取消"
                end
            end
            return true
        end
        -- 缓存未启用:完全等价于原行为,绝不会误调 read_text。
        if real_read_spine then
            return real_read_spine(m, callback)
        end
        for index, item in ipairs(m.spine or {}) do
            if callback(item, real_read_text and real_read_text(m, item.href), nil, index) == false then
                return false, "已取消"
            end
        end
        return true
    end

    if #todo > 0 then
        local map_started_at = os.time()
        if deps.read_spine then
            mapped_new, unmatched_new = ChapterMap.build_stream(map_meta.spine, function(visit)
                return cached_read_spine(map_meta, function(item, content, err, index)
                    map_count = map_count + 1
                    if not step("map", map_count, spine_total, item and item.href) then
                        return false
                    end
                    return visit(item, content, err, index)
                end)
            end, todo)
        else
            mapped_new, unmatched_new = ChapterMap.build(map_meta.spine, function(href)
                map_count = map_count + 1
                if not step("map", map_count, spine_total, href) then return false end
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
        local key = ck(row.book_id, row.chapter_uid)
        local rows = new_rows_by_uid[key] or {}
        rows[#rows + 1] = row
        new_rows_by_uid[key] = rows
    end
    local unmatched_uid = {}
    for _, row in ipairs(unmatched_new) do
        if row.reason == "no_hit" then unmatched_uid[ck(row.book_id, row.uid)] = true end
    end
    local mapped, unmatched = {}, {}
    local matched_uids = {}
    for _, ch in ipairs(fetched) do
        local key = ck(ch.book_id, ch.uid)
        local cached = known[key]
        if type(cached) == "table" then
            matched_uids[key] = true
            local quote_only = (not cached.num or #cached.hrefs > 1) or nil
            for _, href in ipairs(cached.hrefs) do
                mapped[#mapped + 1] = {
                    chapter_uid = tostring(ch.uid), href = tostring(href),
                    underlines = ch.underlines, review_map = ch.review_map or {},
                    quote_only = quote_only, book_id = ch.book_id,
                }
            end
        elseif cached == false then
            unmatched[#unmatched + 1] = {uid = tostring(ch.uid), title = ch.title, reason = "no_hit", book_id = ch.book_id}
        elseif new_rows_by_uid[key] then
            matched_uids[key] = true
            local hrefs = {}
            for _, row in ipairs(new_rows_by_uid[key]) do
                mapped[#mapped + 1] = {
                    chapter_uid = tostring(ch.uid), href = row.href,
                    underlines = ch.underlines, review_map = ch.review_map or {},
                    quote_only = row.quote_only, book_id = ch.book_id,
                }
                hrefs[#hrefs + 1] = row.href
            end
            if map_store then
                map_store[key] = {hrefs = hrefs,
                    num = (#hrefs == 1 and not new_rows_by_uid[key][1].quote_only) or nil}
            end
        elseif unmatched_uid[key] then
            unmatched[#unmatched + 1] = {uid = tostring(ch.uid), title = ch.title, reason = "no_hit", book_id = ch.book_id}
            if map_store then map_store[key] = nil end
        else
            -- no_data(无划线)章节:不入缓存,下批有数据时再匹配。
            unmatched[#unmatched + 1] = {uid = tostring(ch.uid), title = ch.title, reason = "no_data", book_id = ch.book_id}
        end
    end
    if deps.map_cache_path and map_store then
        -- 按书归组写回各自缓存文件(命名空间键拆回纯 uid);单书即原文件原格式。
        local by_book = {}
        for key, val in pairs(map_store) do
            local bid, uid = key, key
            if multi_book then bid, uid = key:match("^(.-)/(.*)$") end
            bid = bid or book_ids[1]
            uid = uid or key
            by_book[bid] = by_book[bid] or {}
            by_book[bid][uid] = val
        end
        for bid, m in pairs(by_book) do
            local cp = cache_path_for(bid)
            local ok_encode, encoded = pcall(Json.encode, {signature = map_signature, map = m})
            if not ok_encode then
                return nil, "映射缓存序列化失败(" .. tostring(cp) .. "):" .. tostring(encoded)
            end
            local write_call, written, write_error = pcall(U.atomic_write, cp, encoded, true)
            if not write_call or not written then
                local detail = write_call and write_error or written
                return nil, "映射缓存保存失败(" .. tostring(cp) .. "):"
                    .. tostring(detail or "写入失败")
            end
        end
    end
    -- 未匹配章节连带损失的划线数(报告要能说清"失败带走了多少")。
    local underlines_by_uid = {}
    for _, ch in ipairs(fetched) do underlines_by_uid[ck(ch.book_id, ch.uid)] = #(ch.underlines or {}) end
    local unmatched_underlines = 0
    for _, row in ipairs(unmatched) do
        unmatched_underlines = unmatched_underlines + (underlines_by_uid[ck(row.book_id, row.uid)] or 0)
    end

    if #mapped == 0 then
        if not skip_resumed then
            return nil, "没有任何章节能匹配到本地书,请确认绑定的和本地打开的是同一本书"
        end
        return with_batch_fields{
            no_changes = true, chapters_total = chapters_total_all,
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
    -- 多书时把所有绑定书的 mapped 章节合并进同一次注入,book_ids 一并列进 MARKER。
    local temp_dest = doc_path .. ".pickthought-new"
    local stats, inject_err = deps.inject(src, book_ids[1], mapped, temp_dest,
        {append = append, meta = meta, book_ids = book_ids})
    if not stats then return nil, inject_err end

    -- 重叠划线被合并的,把想法并进存活锚点的组:点一个虚线看到这一段全部想法。
    if deps.merge_thoughts then
        for _, merge in ipairs(stats.merges or {}) do
            pcall(deps.merge_thoughts, merge.book_id or book_ids[1], merge.uid, merge.from, merge.into)
        end
    end

    local backed_up = false
    local kept_original = nil  -- 作者第8轮:干净原书被暂存为 .old 时记录路径,成功后保留不删
    -- clean_source 重建当前注入版时,旧 .orig 也必须纳入同一笔事务:
    -- 最终换位失败后,当前书可以回滚但备份不能悄悄变成另一版本。
    local rollback_clean_backup
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
            local old_backup = backup .. ".old"
            local had_backup = file_exists(backup)
            -- 上次中断可能只留下 .orig.old。它仍是唯一可恢复的干净备份,
            -- 即使标准 .orig 缺失也必须纳入本次事务,失败时恢复回 .orig。
            local backup_staged = not had_backup and file_exists(old_backup)
            if had_backup then
                -- 旧 .orig 先离位,避免新源复制成功后覆盖掉唯一可用的干净备份。
                if file_exists(old_backup) then
                    local ok_rm, rm_err = remove(old_backup)
                    if not ok_rm then
                        remove(temp_dest)
                        return nil, "无法清理旧备份暂存(" .. tostring(rm_err or "删除失败") .. "),请重试"
                    end
                end
                local ok_stage, stage_err = rename(backup, old_backup)
                if not ok_stage then
                    remove(temp_dest)
                    return nil, "无法暂存旧 .orig 备份(" .. tostring(stage_err or "重命名失败") .. "),请重试"
                end
                backup_staged = true
            end
            rollback_clean_backup = function()
                if backup_staged then
                    return restore_backup_old()
                end
                -- 原先没有 .orig 时,失败不能留下新源生成的半成品备份。
                if file_exists(backup) then
                    local ok_rm, rm_err = remove(backup)
                    if not ok_rm then
                        return nil, "无法清理新 .orig 备份(" .. tostring(rm_err or "删除失败") .. ")"
                    end
                end
                return true
            end
            if not rename(doc_path, old_path) then
                remove(temp_dest)
                local rb_ok, rb_err = rollback_clean_backup()
                if rb_ok then
                    return nil, "无法暂存原注入版(请先关闭本书或确认未被占用)"
                end
                return nil, "无法暂存原注入版,且旧 .orig 备份回滚失败(" .. tostring(rb_err or "未知") .. ")"
            end
            local ok_copy, copy_err, copy_status = copy_file(clean_source, backup)
            if not ok_copy then
                remove(temp_dest)
                local backup_ok, backup_err = rollback_clean_backup()
                local function backup_failure_hint()
                    if backup_ok then
                        if backup_staged then return "旧 .orig 备份已恢复" end
                        return "未检测到旧 .orig 备份,新 .orig 已清理"
                    end
                    if not backup_staged then
                        return "新 .orig 备份清理失败(" .. tostring(backup_err or "未知") .. ")"
                            .. ";请检查 " .. backup
                    end
                    return "旧 .orig 备份恢复失败(" .. tostring(backup_err or "未知") .. ")"
                        .. ";请手动将 " .. old_backup .. " 重命名为 " .. backup
                end
                if copy_status == "cancelled" then
                    -- 复制被用户取消:doc_path 已暂存为 .old,同时恢复旧 .orig。
                    local ok_restore, restore_err = try_recover(old_path, doc_path)
                    if ok_restore and backup_ok then
                        return nil, "已取消干净源固化,已恢复原注入版(.old→doc_path)," .. backup_failure_hint()
                    end
                    return nil, "已取消干净源固化,但回滚未完成;请手动将 "
                        .. old_path .. " 重命名为 " .. doc_path .. " 以恢复原书。(" .. tostring(restore_err or "未知") .. ")"
                        .. ";" .. backup_failure_hint()
                end
                -- 固化失败:尽量回滚 .old → doc_path,恢复结果必须检查(P1#2)。
                local ok_restore, restore_err = try_recover(old_path, doc_path)
                if ok_restore and backup_ok then
                    return nil, "干净源固化到 .orig 失败,已恢复原注入版(.old→doc_path)," .. backup_failure_hint()
                end
                -- 任一回滚失败:保留实际路径,明确告知人工恢复入口。
                return nil, "干净源固化到 .orig 失败,且回滚未完成;请手动将 "
                    .. old_path .. " 重命名为 " .. doc_path .. " 以恢复原书。(" .. tostring(restore_err or "未知") .. ")"
                    .. ";" .. backup_failure_hint()
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
            local old_backup = backup .. ".old"
            local had_backup = file_exists(backup)
            local backup_staged = not had_backup and file_exists(old_backup)
            if had_backup then
                if file_exists(old_backup) then
                    local ok_rm2 = remove(old_backup)
                    if not ok_rm2 then remove(temp_dest); return nil, "无法清理旧备份暂存,请重试" end
                end
                if not rename(backup, old_backup) then
                    remove(temp_dest); return nil, "无法暂存旧 .orig 备份,请重试"
                end
                backup_staged = true
            end
            rollback_clean_backup = function()
                if backup_staged then
                    return restore_backup_old()
                end
                if file_exists(backup) then
                    local ok_rm, rm_err = remove(backup)
                    if not ok_rm then
                        return nil, "无法清理新 .orig 备份(" .. tostring(rm_err or "删除失败") .. ")"
                    end
                end
                return true
            end
            -- 固化注入基线(clean_source)为 .orig,使最终 .orig 与注入源一致(作者意见 #4)。
            local ok_copy, copy_err, copy_status = copy_file(clean_source, backup)
            if not ok_copy then
                remove(temp_dest)
                -- 旧 .orig(.orig.old)必须还原为标准路径,否则后续直接重注误报缺备份
                -- (作者 2026-08-19 意见 #1)。此时 doc_path 尚未离位(原书完好)。
                local rb_ok, rb_err = rollback_clean_backup()
                local rb_hint
                if rb_ok then
                    if backup_staged then
                        rb_hint = "旧 .orig 备份已恢复(.orig.old→.orig)"
                    else
                        rb_hint = "未检测到旧 .orig 备份,新 .orig 已清理"
                    end
                else
                    if backup_staged then
                        rb_hint = "旧 .orig 备份恢复失败(" .. tostring(rb_err or "未知") .. "),请手动将 "
                            .. old_backup .. " 重命名为 " .. backup .. " 以恢复备份"
                    else
                        rb_hint = "新 .orig 备份清理失败(" .. tostring(rb_err or "未知")
                            .. "),请检查 " .. backup
                    end
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
                local rb_ok, rb_err = rollback_clean_backup()
                if rb_ok then
                    local rb_hint = backup_staged and "已回滚旧 .orig 备份并清理新副本" or "已清理新 .orig 备份"
                    return nil, "干净源已固化但无法暂存当前书(.old)," .. rb_hint .. ";"
                        .. "请关闭本书或确认未被占用后重试"
                end
                local rb_hint = backup_staged and ("且旧 .orig 备份回滚失败(" .. tostring(rb_err or "未知")
                    .. ");请手动将 " .. old_backup .. " 重命名为 " .. backup .. " 以恢复备份")
                    or ("且新 .orig 备份清理失败(" .. tostring(rb_err or "未知") .. ");请检查 " .. backup)
                return nil, "干净源已固化但无法暂存当前书(.old)," .. rb_hint
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
            -- 即使原书回滚失败,也要尝试恢复旧 .orig;否则两个文件可能落在不同版本。
            local rb_ok, rb_err
            if rollback_clean_backup then
                rb_ok, rb_err = rollback_clean_backup()
            else
                rb_ok, rb_err = restore_backup_old()
            end
            if not recovered then
                local msg = "无法替换原书(" .. tostring(swap_err or "rename 失败") .. ")"
                if file_exists(old_path) then
                    msg = msg .. ";当前注入版暂存于 " .. old_path .. ",请手动恢复"
                elseif file_exists(backup) then
                    msg = msg .. ";干净原书备份位于 " .. backup .. ",请手动恢复"
                end
                if rec_err then msg = msg .. "。恢复动作失败:" .. tostring(rec_err) end
                if not rb_ok then
                    msg = msg .. ";旧 .orig 备份恢复失败,请手动将 " .. (backup .. ".old")
                        .. " 重命名为 " .. backup .. "(" .. tostring(rb_err or "未知") .. ")"
                end
                return nil, msg
            end
            -- 恢复成功:提示必须与实际文件状态一致(作者意见 #2)。
            local rb_hint = ""
            if not rb_ok then
                rb_hint = ";但旧 .orig 备份回滚未能自动完成,请手动将 "
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
    -- 扣除保存失败的想法:用与 thought_save_failed、epub_inject 的 thoughts_linked_by_uid
    -- 完全一致的复合键 ck(book_id, uid) 查询(多书同 uid 不串键,失败想法不被错计为成功,
    -- 见 test 想法缓存失败按复合键扣除)。单书时 ck 退化为纯 uid,与旧版一致。
    for _, ch in ipairs(fetched) do
        if thought_save_failed[ck(ch.book_id, ch.uid)] then
            thoughts_injected = math.max(0, thoughts_injected
                - (tonumber((stats.thoughts_linked_by_uid or {})[ck(ch.book_id, ch.uid)]) or 0))
        end
    end
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
        chapters_total = chapters_total_all,
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
