-- 注入编排:本地 EPUB + 想法数据 → 撷思版副本。
-- 原书只读;副本先写 dest..".tmp" 再 rename。zip 读写只走 ffi/archiver。
--
-- chapters 契约(Task 5/6 供数):数组,每项
--   {chapter_uid=..., href=...(zip 全路径/相对 OPF 路径/纯文件名,依次精确、resolve、后缀匹配),
--    underlines={{range="a-b", markText=...}, ...}, review_map={[range]={{content,author,...}}}}
local Annotations = require("pickthought.annotations")
local AnnotationStyle = require("pickthought.annotation_style")
local EpubReader = require("pickthought.epub_reader")
local Json = require("pickthought.json")
local U = require("pickthought.util")
local logger = require("logger")
local PerformanceMode = require("pickthought.performance_mode")

local M = {}

M.MARKER = "pickthought.json"

-- 无 DRM 书也常带 encryption.xml 做字体混淆,这两种算法不影响注入,放行。
local FONT_OBFUSCATION_ALGOS = {
    ["http://www.idpf.org/2008/embedding"] = true,
    ["http://ns.adobe.com/pdf/enc#RC"] = true,
}

-- 本身已是压缩格式的条目,重打包时原样 store:再 deflate 只烧 CPU 不省空间,
-- 图多的大书打包能明显提速。正文与其余条目保持 deflate。
local STORED_EXTS = {
    jpg = true, jpeg = true, png = true, gif = true, webp = true,
    woff = true, woff2 = true, mp3 = true, m4a = true, mp4 = true, ogg = true,
}

local GC_FULL_INTERVAL = 16
local GC_MEMORY_SAMPLE_INTERVAL = 8
local GC_LARGE_ENTRY_BYTES = 2 * 1024 * 1024
local GC_HEAP_GROWTH_KB = 8 * 1024
local GC_LOW_MEMORY_KB = 128 * 1024
-- 非目标条目 ≥ 此大小走磁盘拷贝(extractToPath→临时文件→addPath),不进 Lua 堆,
-- 灭大图/大字库/多媒体条目的 OOM 尖峰。阈值权衡:太小会为大量小条目增加 SD I/O,
-- 太大则中等大条目仍驻留堆;512KB 可覆盖绝大多数图片/字体/媒体。
local DISK_PATH_THRESHOLD = 512 * 1024

local function memory_available_kb()
    local raw = U.read_file("/proc/meminfo", true)
    if not raw then return nil end
    local values = {}
    for key, value in raw:gmatch("([%a_]+):%s*(%d+)%s*kB") do
        values[key] = tonumber(value)
    end
    return values.MemAvailable or (values.MemFree and
        (values.MemFree + (values.Buffers or 0) + (values.Cached or 0)))
end

local function new_gc_policy(opts)
    local gc = opts.collect_garbage or collectgarbage
    local read_memory = opts.read_memory_available_kb or memory_available_kb
    local heap = tonumber(gc("count")) or 0
    local state = {
        processed = 0, since_full = 0, full_collections = 0,
        heap_after_full_kb = heap, peak_heap_kb = heap, min_available_kb = nil,
    }
    function state:release(content_bytes)
        self.processed = self.processed + 1
        self.since_full = self.since_full + 1
        local current_heap = tonumber(gc("count")) or 0
        self.peak_heap_kb = math.max(self.peak_heap_kb, current_heap)
        local reason
        if tonumber(content_bytes or 0) >= GC_LARGE_ENTRY_BYTES then
            reason = "large_entry"
        elseif current_heap - self.heap_after_full_kb >= GC_HEAP_GROWTH_KB then
            reason = "heap_growth"
        elseif self.since_full >= GC_FULL_INTERVAL then
            reason = "interval"
        elseif self.processed % GC_MEMORY_SAMPLE_INTERVAL == 0 then
            local available = tonumber(read_memory())
            if available then
                self.min_available_kb = self.min_available_kb and
                    math.min(self.min_available_kb, available) or available
                if available < GC_LOW_MEMORY_KB then reason = "low_memory" end
            end
        end
        if reason then
            gc("collect")
            self.full_collections = self.full_collections + 1
            self.since_full = 0
            self.heap_after_full_kb = tonumber(gc("count")) or 0
        else
            gc("step", 400)
        end
        return reason
    end
    return state
end

function M.copy_path(src)
    src = tostring(src or "")
    local stem = src:match("^(.*)%.[eE][pP][uU][bB]$") or src
    return stem .. ".撷思.epub"
end

function M.is_copy(path, archiver)
    local meta = EpubReader.load(path, archiver)
    return meta ~= nil and meta.has[M.MARKER] == true
end

local function drm_blocked(meta, archiver)
    if not meta.has["META-INF/encryption.xml"] then return false end
    local enc = EpubReader.read(meta, "META-INF/encryption.xml", archiver)
    if not enc then return true end
    local found = false
    for algo in enc:gmatch('Algorithm%s*=%s*"([^"]*)"') do
        found = true
        if not FONT_OBFUSCATION_ALGOS[algo] then return true end
    end
    for algo in enc:gmatch("Algorithm%s*=%s*'([^']*)'") do
        found = true
        if not FONT_OBFUSCATION_ALGOS[algo] then return true end
    end
    return not found
end

local function ensure_style(html)
    if html:find('id="' .. AnnotationStyle.INLINE_STYLE_ID .. '"', 1, true) then return html end
    local tag = AnnotationStyle.inline_style_tag()
    local head_end = html:find("</[Hh][Ee][Aa][Dd]%s*>")
    if head_end then
        return html:sub(1, head_end - 1) .. tag .. html:sub(head_end)
    end
    local _, body_end = html:find("<[Bb][Oo][Dd][Yy][^>]*>")
    if body_end then
        return html:sub(1, body_end) .. tag .. html:sub(body_end + 1)
    end
    -- 无 head/body 的碎片:插在 <html> 或 XML 声明之后,不能顶在 <?xml?> 前面。
    local _, html_end = html:find("<[Hh][Tt][Mm][Ll][^>]*>")
    if html_end then
        return html:sub(1, html_end) .. tag .. html:sub(html_end + 1)
    end
    local _, decl_end = html:find("^%s*<%?[^>]*%?>")
    if decl_end then
        return html:sub(1, decl_end) .. tag .. html:sub(decl_end + 1)
    end
    return tag .. html
end

-- href 匹配:精确 zip 路径 → 相对 OPF 解析 → 文件名后缀(多个命中视为歧义,不注入)。
local function match_entry(meta, href)
    href = tostring(href or "")
    if href == "" then return nil end
    if meta.has[href] then return href end
    local resolved = EpubReader.resolve(meta.opf_dir, href)
    if meta.has[resolved] then return resolved end
    local tail = "/" .. href:gsub("^/+", "")
    local found
    for _, item in ipairs(meta.spine) do
        if item.href:sub(-#tail) == tail then
            if found and found ~= item.href then return nil end
            found = item.href
        end
    end
    return found
end

local function range_of(row)
    if type(row) ~= "table" then return "" end
    local value = row.range or row.markRange or row.bookmarkRange
    local kind = type(value)
    return (kind == "string" or kind == "number") and tostring(value) or ""
end

local function count_occurrences(text, needle)
    local n, from = 0, 1
    while true do
        local at = text:find(needle, from, true)
        if not at then return n end
        n = n + 1
        from = at + #needle
    end
end

-- 实际落进正文的锚点数:按划线 range 逐个对比注入前后 data-pickthought-range 的出现次数。
-- (annotations 的 dropped 不含去重叠环节丢弃的划线,直接数结果才准;
-- 同一文件叠加多章时按出现次数差对比,跨章同 range 键也不误判。)
-- 第二返回值:落锚的 range 键集合,供跨文件聚合「唯一划线」的着落。
local function count_marks(rendered, underlines, base)
    local n, seen, hit = 0, {}, {}
    for _, row in ipairs(underlines or {}) do
        local key = range_of(row)
        if key ~= "" and not seen[key] then
            seen[key] = true
            local needle = 'data-pickthought-range="' .. key .. '"'
            if count_occurrences(rendered, needle) > (base and count_occurrences(base, needle) or 0) then
                n = n + 1
                hit[key] = true
            end
        end
    end
    return n, hit
end

local function chapter_data(book_id, ch)
    -- 多书合并注入时,每个 mapped 章节自带 ch.book_id;单书场景回退到入参 book_id。
    book_id = ch.book_id or book_id
    local underlines = ch.underlines or {}
    local review_map = ch.review_map or {}
    local thought_counts = ch.thought_count_by_range or {}
    local thought_count = tonumber(ch.thought_count)
    if not thought_count then
        for _ in pairs(review_map) do thought_count = (thought_count or 0) + 1 end
    end
    return {
        book_id = book_id, chapter_uid = tostring(ch.chapter_uid or ""),
        underlines = underlines, review_map = review_map,
        thought_count_by_range = thought_counts, thought_ranges = ch.thought_ranges,
        quote_only = ch.quote_only,
        underline_count = #underlines, thought_count = thought_count, errors = {},
    }
end

local function get_archiver(archiver)
    if archiver then return archiver end
    local ok, mod = pcall(require, "ffi/archiver")
    if not ok then return nil, "需要 KOReader v2026.03 或更新版本(缺少 ffi/archiver)" end
    return mod
end

-- 非目标大条目走磁盘拷贝:extractToPath 抽到临时文件 → addPath 写回,全程不进 Lua 堆,
-- 灭大图/字库/媒体造成的 OOM 尖峰。失败返回 false,调用方回退内存路径(行为不变)。
-- 注意 addPath 恒按 entry_root/rel 拼 zip 路径,顶层无斜杠条目(如 mimetype,已单独处理)
-- 无法用其正确表示,故 first 缺失时直接回退。
local function copy_entry_via_disk(reader, writer, entry, mtime, disk_tmp_base)
    local _, rest = tostring(entry.path):match("^([^/]+)/(.*)$")
    if not rest or rest == "" then return false end
    local sub = disk_tmp_base .. "-e" .. tostring(entry.index)
    U.mkdir(sub)
    local source_path = sub .. "/" .. rest
    local parent = source_path:match("^(.*)/[^/]+$")
    if parent then U.mkdir(parent) end
    local ok_ext = reader:extractToPath(entry.path, source_path)
    if not ok_ext then
        pcall(U.remove_tree, sub)
        return false
    end
    -- KOReader 的 addPath(entry_root, root, recursive, mtime):第一个参数是
    -- ZIP 内目标路径,第二个才是刚抽出的本地源文件。
    local ok_add = writer:addPath(entry.path, source_path, true, mtime)
    pcall(U.remove_tree, sub)
    -- KOReader 的 ZipWriter.addPath 在到达 ZIP 末尾时可能返回 false 但 writer.err 为空,
    -- 这属于正常 EOF,不应误报失败;只有 writer.err 真正置位才是写入错误。
    if not ok_add and writer.err then return nil, "addPath" end
    return true
end

function M.inject_copy(src, book_id, chapters, opts)
    opts = opts or {}
    local rename = opts.rename or os.rename
    local now = opts.now or os.time

    local started_at = now()
    local meta = opts.meta
    if type(meta) ~= "table" or tostring(meta.path or "") ~= tostring(src) then
        local err
        meta, err = EpubReader.load(src, opts.archiver)
        if not meta then return nil, err end
    end
    if meta.has[M.MARKER] and not opts.append then
        return nil, "该文件已是撷思版副本,请对原书执行注入"
    end
    if drm_blocked(meta, opts.archiver) then return nil, "该 EPUB 受 DRM 保护,无法注入想法" end

    -- 预归组:这里只做 href 匹配,把章节按目标文件分组;正文读取与划线定位
    -- 推迟到写包循环里逐文件就地进行,注好立刻写出释放。绝不把全部注入结果
    -- 攥在内存里——真机教训:剑来映射改进后目标文件数翻了几倍,数百个渲染
    -- 结果同时驻留,把 256MB 设备上的子进程直接压进内核 OOM(SIGKILL,
    -- 异常退出且无结果文件)。
    local stats = {
        injected = 0, marks = 0, unmatched = {},
        quote_aligned = 0, numeric = 0, dropped = 0, overlapped = 0, unlocated = 0,
        underlines_resolved = 0, thoughts_linked = 0, thoughts_linked_by_uid = {},
        merges = {}, target_files = 0, batch_apply_calls = 0,
        shared_index_builds = 0, batch_fallbacks = 0,
    }
    local groups, group_count = {}, 0
    local total_underlines = 0
    -- 多书:聚合/去重/统计按 book_id+chapter_uid 复合键,避免不同书相同 uid 串书;
    -- 单书退化为纯 uid,统计语义与旧版完全一致(与 sync.lua 的 ck 对齐)。
    local multi_book = type(opts) == "table" and type(opts.book_ids) == "table" and #opts.book_ids > 1
    local function ckey(bid, uid)
        return multi_book and (tostring(bid) .. "/" .. tostring(uid)) or tostring(uid)
    end
    -- 同一微信章可能映射到多个本地文件。按 uid + range 预先去重，任一目标
    -- 落锚（含重叠合并）就算该划线及其想法注入成功。
    local uid_track = {} -- [ckey] = {total={}, resolved={}, thoughts={}}
    for _, ch in ipairs(chapters or {}) do
        total_underlines = total_underlines + #(ch.underlines or {})
        local uid = tostring(ch.chapter_uid or "")
        local bid = ch.book_id or book_id
        local track = uid_track[ckey(bid, uid)]
        if not track then
            track = {total = {}, resolved = {}, thoughts = {}}
            uid_track[ckey(bid, uid)] = track
        end
        for _, row in ipairs(ch.underlines or {}) do
            local key = range_of(row)
            if key ~= "" then
                track.total[key] = true
                local reviews = ch.review_map and ch.review_map[key]
                local count = tonumber(ch.thought_count_by_range
                    and ch.thought_count_by_range[key])
                    or (type(reviews) == "table" and #reviews or 0)
                track.thoughts[key] = math.max(track.thoughts[key] or 0, count)
            end
        end
        local entry_path = match_entry(meta, ch.href)
        if not entry_path then
            -- 未匹配或后缀歧义,不能安静吞掉。
            stats.unmatched[#stats.unmatched + 1] = tostring(ch.chapter_uid or ch.href or "?")
        else
            local rows = groups[entry_path]
            if not rows then
                rows = {}
                groups[entry_path] = rows
                group_count = group_count + 1
            end
            rows[#rows + 1] = ch
        end
    end
    if total_underlines == 0 then return nil, "没有划线数据,无需生成副本" end
    if group_count == 0 then
        return nil, string.format("没有可注入的章节(未匹配 %d 章,定位失败 %d 条划线)",
            #stats.unmatched, stats.dropped)
    end

    local mod, arc_err = get_archiver(opts.archiver)
    if not mod then return nil, arc_err end

    local dest = opts.dest or M.copy_path(src)
    local mtime = now()
    -- tmp 带时间戳:两个 worker 罕见并发时(重启接管失控 + 重新同步)
    -- 不会互相截断同一个临时文件。
    local tmp = dest .. ".tmp-" .. tostring(mtime)
    local writer = mod.Writer:new{}
    if not writer:open(tmp, "epub") then
        return nil, "无法创建副本:" .. tostring(writer.err or tmp)
    end
    local function close_writer()
        local ok, result = pcall(function() return writer:close() end)
        if not ok then return nil, tostring(result) end
        if result == false then
            return nil, tostring(writer.err or "EPUB writer 收尾失败")
        end
        if writer.err then return nil, tostring(writer.err) end
        return true
    end
    -- 非目标大条目走磁盘拷贝的临时根目录:本批同步一个,失败/结束统一清理。
    local disk_tmp = dest .. ".spine-" .. tostring(mtime)
    U.mkdir(disk_tmp)

    local reader
    -- 非目标大条目走磁盘的临时根,失败/结束统一清理(见上方 disk_tmp 定义)
    local function fail(message)
        local detail = writer.err
        local closed, close_error = close_writer()
        if reader then reader:close() end
        pcall(U.remove_tree, disk_tmp)
        os.remove(tmp)
        if not closed then
            detail = (detail and (detail .. ";") or "") .. "writer close: " .. tostring(close_error)
        end
        return nil, message .. (detail and ("(" .. detail .. ")") or "")
    end

    writer:setZipCompression("store")
    local mime = meta.has["mimetype"] and EpubReader.read(meta, "mimetype", opts.archiver)
        or "application/epub+zip"
    if not writer:addFileFromMemory("mimetype", mime, mtime) then
        return fail("写入副本失败:mimetype")
    end
    writer:setZipCompression("deflate")
    local compression = "deflate"

    -- 单遍流式复制:迭代中就地提取当前条目(与 archiveviewer 的 extractAll 同款),
    -- 避免每条目重开重扫整包;命中注入目标的文件此刻套锚点,写完立即释放。
    reader = mod.Reader:new()
    if not reader:open(src) then
        reader = nil
        return fail("无法打开 EPUB:" .. tostring(src))
    end
    local marker_chapters = {}
    if opts.append and meta.has[M.MARKER] then
        local raw_marker = EpubReader.read(meta, M.MARKER, opts.archiver)
        local ok_marker, old_marker = pcall(Json.decode, raw_marker or "")
        if ok_marker and type(old_marker) == "table" and type(old_marker.chapters) == "table" then
            for _, row in ipairs(old_marker.chapters) do
                if type(row) == "table" then marker_chapters[#marker_chapters + 1] = row end
            end
        end
    end
    local injected_uids = {}
    local injected_thought_keys = {}
    local injected_thoughts_total = 0
    -- 跨文件聚合每条划线的着落:拆分章一章对多文件,同一条划线在没对齐的文件里
    -- 各计一次 unlocated,直接累加会虚高数倍(真机:4 万条划线报 3.2 万未注入,
    -- 三项相加超过总数)。唯一划线在任一目标文件落锚或被重叠合并,即算有着落。
    local total_entries = #meta.names
    local seen_entries = 0
    local gc_policy = new_gc_policy(opts)
    local perf = opts.perf or PerformanceMode.default()
    local written = {["mimetype"] = true, [M.MARKER] = true}
    for entry in reader:iterate() do
        if entry.mode == "file" then
            seen_entries = seen_entries + 1
            if not written[entry.path] then
                written[entry.path] = true
                local entry_start = perf:now()
                local rows = groups[entry.path]
                local ext = entry.path:match("%.(%w+)$")
                local want = (not rows) and ext and STORED_EXTS[ext:lower()] and "store" or "deflate"
                if want ~= compression then
                    writer:setZipCompression(want)
                    compression = want
                end
                -- 非目标且较大(图/字库/媒体)的条目走磁盘拷贝,不进 Lua 堆,灭 OOM 尖峰;
                -- 目标条目(需改内容)与较小条目走内存快路径。磁盘路径失败一律回退内存。
                local via_disk, disk_err
                if not rows and entry.size and entry.size >= DISK_PATH_THRESHOLD
                   and entry.path:find("/", 1, true) then
                    via_disk, disk_err = copy_entry_via_disk(reader, writer, entry, mtime, disk_tmp)
                end
                if disk_err then
                    return fail("磁盘中转写入失败:" .. entry.path)
                end
                if not via_disk then
                    local content = reader:extractToMemory(entry.path)
                    if not content then
                        local read_err = reader.err
                        return fail("无法读取 EPUB 条目:" .. entry.path
                            .. (read_err and ("(" .. read_err .. ")") or ""))
                    end
                    local progress_detail = {target_file = rows ~= nil}
                    if rows then
                        stats.target_files = stats.target_files + 1
                        local data_rows = {}
                        for _, ch in ipairs(rows) do data_rows[#data_rows + 1] = chapter_data(book_id, ch) end
                        local rendered, applied_rows, apply_meta =
                            Annotations:new(nil):apply_many(content, data_rows)
                        stats.batch_apply_calls = stats.batch_apply_calls
                            + (apply_meta and apply_meta.batch_apply_calls or 1)
                        stats.shared_index_builds = stats.shared_index_builds
                            + (apply_meta and apply_meta.shared_index_builds or 0)
                        if apply_meta and apply_meta.fallback then
                            stats.batch_fallbacks = stats.batch_fallbacks + 1
                        end
                        local has_new_marks = false
                        local file_mark_count, file_thought_count = 0, 0
                        local file_thought_keys = {}
                        local function account_thoughts(data, track, keys)
                            for key in pairs(keys or {}) do
                                local thought_key = ckey(data.book_id, data.chapter_uid)
                                    .. "\0" .. tostring(key)
                                if not file_thought_keys[thought_key] then
                                    file_thought_keys[thought_key] = true
                                    file_thought_count = file_thought_count
                                        + (tonumber(track.thoughts[key]) or 0)
                                end
                                if not injected_thought_keys[thought_key] then
                                    injected_thought_keys[thought_key] = true
                                    injected_thoughts_total = injected_thoughts_total
                                        + (tonumber(track.thoughts[key]) or 0)
                                end
                            end
                        end
                        for _, applied in ipairs(applied_rows or {}) do
                            local data, ch_stats = applied.data, applied.stats or {}
                            local mark_count, hit_keys = applied.mark_count or 0, applied.hit_keys or {}
                            local track = uid_track[ckey(data.book_id, data.chapter_uid)]
                            for key in pairs(hit_keys) do track.resolved[key] = true end
                            for _, key in ipairs(ch_stats.overlapped_keys or {}) do
                                track.resolved[tostring(key)] = true
                            end
                            stats.quote_aligned = stats.quote_aligned + (ch_stats.quote_aligned or 0)
                            stats.numeric = stats.numeric + (ch_stats.numeric or 0)
                            stats.dropped = stats.dropped + (ch_stats.dropped or 0)
                            stats.overlapped = stats.overlapped + (ch_stats.overlapped or 0)
                            for _, merge in ipairs(ch_stats.merged or {}) do
                                stats.merges[#stats.merges + 1] = {
                                    uid = data.chapter_uid, from = merge.from, into = merge.into,
                                    book_id = merge.book_id or data.book_id,
                                }
                            end
                            if mark_count > 0 then
                                has_new_marks = true
                                file_mark_count = file_mark_count + mark_count
                                account_thoughts(data, track, hit_keys)
                                local overlapped = {}
                                for _, key in ipairs(ch_stats.overlapped_keys or {}) do
                                    overlapped[tostring(key)] = true
                                end
                                account_thoughts(data, track, overlapped)
                                -- 拆分章会产生同 uid 多行,injected 按「有锚点落书的微信章」去重计数。
                                -- 多书按 book_id+uid 复合键,不同书同 uid 不互相吞掉计数。
                                if not injected_uids[ckey(data.book_id, data.chapter_uid)] then
                                    injected_uids[ckey(data.book_id, data.chapter_uid)] = true
                                    stats.injected = stats.injected + 1
                                end
                                stats.marks = stats.marks + mark_count
                                marker_chapters[#marker_chapters + 1] = {
                                    uid = data.chapter_uid, href = entry.path, marks = mark_count,
                                    book_id = data.book_id,
                                }
                            end
                        end
                        content = has_new_marks and ensure_style(rendered) or rendered
                        progress_detail.current_file_underlines = file_mark_count
                        progress_detail.current_file_thoughts = file_thought_count
                        progress_detail.injected_files = stats.target_files
                        progress_detail.injected_underlines = stats.marks
                        progress_detail.injected_thoughts = injected_thoughts_total
                    end
                    if not writer:addFileFromMemory(entry.path, content, mtime) then
                        return fail("写入副本失败:" .. entry.path)
                    end
                    if opts.progress then
                        local progress_ok, progress_result = pcall(opts.progress,
                            entry.path, seen_entries, total_entries, progress_detail)
                        if not progress_ok then return fail("进度回调失败:" .. tostring(progress_result)) end
                        if progress_result == false then return fail("已取消") end
                    end
                    local content_bytes = #content
                    content = nil
                    gc_policy:release(content_bytes)
                else
                    local progress_detail = {target_file = false}
                    if opts.progress then
                        local progress_ok, progress_result = pcall(opts.progress,
                            entry.path, seen_entries, total_entries, progress_detail)
                        if not progress_ok then return fail("进度回调失败:" .. tostring(progress_result)) end
                        if progress_result == false then return fail("已取消") end
                    end
                    gc_policy:release(entry.size or 0)
                end
                -- 每单元本地处理耗时采样;降级时让出 CPU。与 opts.progress 心跳解耦:
                -- 前台注入路径(经 main.lua 的 inject 包装)不传 progress,但同样需要让出。
                perf:record(entry.path, perf:now() - entry_start)
                if perf:degraded() then perf:rest() end
            end
        end
    end
    U.remove_tree(disk_tmp)
    reader:close()
    reader = nil

    -- 未注入 = 唯一划线里既没落锚也没被重叠合并的(跨全部目标文件聚合)。
    for uid, track in pairs(uid_track) do
        for key in pairs(track.total) do
            if track.resolved[key] then
                stats.underlines_resolved = stats.underlines_resolved + 1
                local linked = track.thoughts[key] or 0
                stats.thoughts_linked = stats.thoughts_linked + linked
                stats.thoughts_linked_by_uid[uid] =
                    (stats.thoughts_linked_by_uid[uid] or 0) + linked
            else
                stats.unlocated = stats.unlocated + 1
            end
        end
    end

    if stats.injected == 0 then
        pcall(U.remove_tree, disk_tmp)
        close_writer()
        os.remove(tmp)
        return nil, string.format("没有可注入的章节(未匹配 %d 章,定位失败 %d 条划线)",
            #stats.unmatched, stats.dropped)
    end

    if compression ~= "deflate" then writer:setZipCompression("deflate") end
    -- 多书合并注入时记录 book_ids 列表;单书场景退化为 [book_id]。
    -- 保留顶层 book_id(首本)字段以兼容旧版读取已注入书的 MARKER。
    local book_ids = opts.book_ids
    if type(book_ids) ~= "table" or #book_ids == 0 then
        book_ids = { tostring(book_id or "") }
    end
    if not writer:addFileFromMemory(M.MARKER, Json.encode({
        version = 1, book_id = tostring(book_ids[1] or ""), book_ids = book_ids,
        created = mtime, source = src, chapters = marker_chapters,
    }), mtime) then
        return fail("写入副本失败:" .. M.MARKER)
    end
    local closed, close_error = close_writer()
    if not closed then
        os.remove(tmp)
        return nil, "关闭 EPUB 副本失败:" .. tostring(close_error)
    end

    local ok, rename_err = rename(tmp, dest)
    if not ok then
        -- Windows 上 rename 不覆盖已存在目标:清掉旧副本重试一次。
        os.remove(dest)
        ok, rename_err = rename(tmp, dest)
    end
    if not ok then
        os.remove(tmp)
        return nil, "无法生成副本:" .. tostring(rename_err or "重命名失败")
    end
    stats.dest = dest
    stats.gc_full_collections = gc_policy.full_collections
    stats.peak_heap_kb = math.floor(gc_policy.peak_heap_kb + 0.5)
    stats.min_available_kb = gc_policy.min_available_kb
    logger.info("[撷思][EpubInject] completed",
        "entries=", tostring(gc_policy.processed),
        "target_files=", tostring(stats.target_files),
        "batch_apply_calls=", tostring(stats.batch_apply_calls),
        "shared_index_builds=", tostring(stats.shared_index_builds),
        "batch_fallbacks=", tostring(stats.batch_fallbacks),
        "full_gc=", tostring(gc_policy.full_collections),
        "peak_heap_kb=", tostring(stats.peak_heap_kb),
        "min_available_kb=", tostring(stats.min_available_kb or "unknown"),
        "elapsed_s=", tostring(math.max(0, now() - started_at)))
    return stats
end

return M
