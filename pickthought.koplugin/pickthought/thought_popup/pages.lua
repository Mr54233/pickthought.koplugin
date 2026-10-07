--[[--
Thought popup pagination and page rendering (shared by both popup positions).

The bottom bar (widget.lua) and the centered dialog (center_widget.lua) render
the same review content with the same fonts and size settings; this module
owns the pipeline they share:

  * one-shot pagination of the review blocks (ContentBuilder + Paginator),
    cached in a koreader Cache keyed by (items, font, margins, height_ratio);
  * per-piece glyph bitmaps (piece cache);
  * lazy page bitmaps (page cache), where a page is a y-slice of the flowing
    content, so a single long thought may span several pages.

Widgets ask for page starts with computePages(viewport_h) and render page
bitmaps on demand with renderPage(page_idx, page_starts). The page -> piece
inverted index is rebuilt whenever the page_starts table changes (i.e. when
the viewport height changes), while layout and piece caches are freed only
when the content or geometry key changes.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Cache = require("cache")
local CacheItem = require("cacheitem")
local ContentBuilder = require("pickthought.thought_popup.content_builder")
local Device = require("device")
local FaceFactory = require("pickthought.thought_popup.face_factory")
local Paginator = require("pickthought.thought_popup.paginator")
local Screen = Device.screen
local logger = require("logger")
local PopupDiagnostic = require("pickthought.diagnostic")

local PAGE_BB_CACHE_MAX = 8
local PIECE_CACHE_MAX = 200
local LAYOUT_CACHE_MAX = 6

local PieceItem = CacheItem:extend{}
function PieceItem:onFree()
    if self.bb and self.bb.free then self.bb:free() end
end

local PageItem = CacheItem:extend{}
function PageItem:onFree()
    if self.bb and self.bb.free then self.bb:free() end
end

local LayoutItem = CacheItem:extend{}
function LayoutItem:onFree()
    Paginator.freeTextPieces(self.pieces)
end

local function newPieceCache()
    return Cache:new{ slots = PIECE_CACHE_MAX, enable_eviction_cb = true }
end

local function newPageCache()
    return Cache:new{ slots = PAGE_BB_CACHE_MAX, enable_eviction_cb = true }
end

local function newLayoutCache()
    return Cache:new{ slots = LAYOUT_CACHE_MAX, enable_eviction_cb = true }
end

local function itemsKey(items)
    local parts = {}
    for _, item in ipairs(items or {}) do
        parts[#parts + 1] = string.format("%s|%s|%s|%d|%d",
            tostring(item.abstract or ""),
            tostring(item.author or ""),
            tostring(item.content or ""),
            tonumber(item.likes_count) or 0,
            -- comment_count 参与 key:后台补齐评论数后 meta 行文本变化,
            -- 必须让 setContent 判定 key 变化并重排,否则刷了也看不到。
            tonumber(item.comment_count) or 0)
    end
    return table.concat(parts, "\n")
end

local function geomKey(doc_font_name, doc_font_size, margins, height_ratio, content_width, contrast)
    local m = margins or {}
    return string.format("%s|%d|%d_%d_%d_%d|%.4f|%d|%d",
        doc_font_name or "", doc_font_size or 0,
        m.left or 0, m.right or 0, m.top or 0, m.bottom or 0,
        height_ratio or 0.35,
        content_width or 0,
        tonumber(contrast) or 0)
end

local PageRenderer = {}

--- @param opts table { items, doc_font_name, doc_font_size, doc_margins,
---                    height_ratio, content_width? }
--- content_width (optional) is the full inner column width before margins
--- (defaults to the screen width, which is what the bottom popup uses; the
--- centered popup passes its narrower frame width).
function PageRenderer:new(opts)
    opts = opts or {}
    local self_obj = setmetatable({}, { __index = PageRenderer })
    self_obj.items = opts.items or {}
    self_obj.doc_font_name = opts.doc_font_name
    self_obj.doc_font_size = opts.doc_font_size or Screen:scaleBySize(18)
    self_obj.doc_margins = opts.doc_margins or {
        left = Screen:scaleBySize(20),
        right = Screen:scaleBySize(20),
        top = Screen:scaleBySize(10),
        bottom = Screen:scaleBySize(10),
    }
    self_obj.height_ratio = opts.height_ratio or 0.35
    self_obj.content_width = opts.content_width
    self_obj.contrast = tonumber(opts.contrast) or 0
    self_obj.skip_quote = opts.skip_quote == true
    self_obj._layout_cache = newLayoutCache()
    self_obj._page_bbs = newPageCache()
    self_obj._piece_cache = newPieceCache()
    self_obj._items_key = itemsKey(self_obj.items)
    self_obj._geom_key = geomKey(self_obj.doc_font_name, self_obj.doc_font_size,
        self_obj.doc_margins, self_obj.height_ratio, self_obj.content_width,
        self_obj.contrast)
    self_obj._bb_key = self_obj._items_key .. "|" .. self_obj._geom_key
    self_obj._page_pieces = {}
    self_obj._page_pieces_key = nil
    -- Public layout results, refreshed by ensureLayout():
    self_obj.layout = nil
    self_obj.content_h = 0
    self_obj.text_w = 0
    self_obj.boundaries = nil
    return self_obj
end

--- Reload content/geometry; re-layout only when the cache key changed.
--- content_width (optional) is the full inner column width before margins;
--- the centered popup passes its frame width so a width change re-paginates.
--- contrast (optional) shifts every block's gray level; a change re-lays out
--- because the colors are baked into the pieces.
function PageRenderer:setContent(items, doc_font_name, doc_font_size, doc_margins, height_ratio, content_width, contrast)
    self.items = items or {}
    if doc_font_name ~= nil then self.doc_font_name = doc_font_name end
    if doc_font_size ~= nil then self.doc_font_size = doc_font_size end
    if doc_margins ~= nil then self.doc_margins = doc_margins end
    if height_ratio ~= nil then self.height_ratio = height_ratio end
    if content_width ~= nil then self.content_width = content_width end
    if contrast ~= nil then self.contrast = tonumber(contrast) or 0 end
    local new_items_key = itemsKey(self.items)
    local new_geom_key = geomKey(self.doc_font_name, self.doc_font_size,
        self.doc_margins, self.height_ratio, self.content_width, self.contrast)
    local new_bb_key = new_items_key .. "|" .. new_geom_key
    if new_bb_key ~= self._bb_key then
        self._items_key = new_items_key
        self._geom_key = new_geom_key
        self._bb_key = new_bb_key
        self:ensureLayout()
    end
end

function PageRenderer:paginate()
    local t0 = os.clock()
    local blocks = ContentBuilder.build(self.items, { contrast = self.contrast, skip_quote = self.skip_quote })
    local t1 = os.clock()

    local item_width = math.min(math.ceil(self.doc_margins.right * 2 / 5), Screen:scaleBySize(10))
    local inner_w = self.content_width or Screen:getWidth()
    local text_w = inner_w - self.doc_margins.left - self.doc_margins.right - item_width
    if text_w < 10 then text_w = 10 end
    local base_size = math.max(8, math.floor(self.doc_font_size or 0))

    local pieces = {}
    local boundaries = {}
    local y = 0

    local function addTextPiece(variant, text, fg, width, x, keep_next, opts)
        local face = FaceFactory:getFace(self.doc_font_name, base_size, variant)
        if not face then return false end
        local line_h, extra, baseline = Paginator.textPieceMetrics(face)
        local paginated = Paginator.paginateText(text, face, width)
        local n_lines = paginated.n_lines
        local piece_h = n_lines * line_h + extra
        local piece_y = y
        local line_bounds = {}
        for k = 1, n_lines do
            local line_top = piece_y + (k - 1) * line_h
            local line_bottom = piece_y + k * line_h
            -- extra is the actual glyph tail reserved by the text bitmap;
            -- attach it to the final line so a page boundary cannot split it.
            if k == n_lines then line_bottom = piece_y + piece_h end
            line_bounds[k] = { top = line_top, bottom = line_bottom }
        end
        pieces[#pieces + 1] = {
            kind = "text", variant = variant, text = text, fg = fg,
            face = face, width = width, x = x, y = piece_y,
            n_lines = n_lines, line_h = line_h, piece_h = piece_h,
            baseline = baseline, xtext = paginated.xtext, lines = paginated.lines,
            line_bounds = line_bounds,
            align = opts and opts.align or nil,
            targeted_width = opts and opts.targeted_width or nil,
        }
        if keep_next and n_lines >= 1 then
            boundaries[#boundaries + 1] = {
                top = piece_y,
                bottom = line_bounds[n_lines].bottom,
                keep_next = true,
            }
        else
            for k, bounds in ipairs(line_bounds) do
                boundaries[#boundaries + 1] = {
                    top = bounds.top,
                    bottom = bounds.bottom,
                }
            end
        end
        y = y + piece_h
        return true
    end

    for _, block in ipairs(blocks) do
        if block.kind == "separator" then
            -- 分隔线与其后作者行同属一个条目的 header(上游 #193):
            -- 线的边界归到 meta 行,长按定位才能覆盖整组视觉元素。
            y = y + math.floor(base_size * (block.spacing_before or 0) + 0.5)
            local thickness = math.max(1, Screen:scaleBySize(1))
            pieces[#pieces + 1] = {
                kind = "separator", fg = block.fg,
                x = 0, y = y, width = text_w, piece_h = thickness,
            }
            y = y + thickness + math.floor(base_size * (block.spacing_after or 0) + 0.5)
        elseif block.kind == "meta" then
            -- meta 行(上游 #193 双列):likes 右列先量宽(上限 text_w*0.4),
            -- author 左列用剩余宽度;两列基线对齐,行边界含分隔线起点。
            -- 零赞零评论(likes_text=nil)时走单列整宽,作者名照样渲染
            -- (此前该分支要求 likes_text,0 赞条目的作者名整行消失)。
            y = y + math.floor(base_size * (block.spacing_before or 0) + 0.5)
            local header_top = y
            local likes_piece = nil
            if block.likes_text then
            local likes_width_max = math.max(1, math.floor(text_w * 0.4))
            local likes_face = FaceFactory:getFace(self.doc_font_name, base_size, "likes")
            if likes_face then
                local likes_line_h, likes_extra, likes_baseline =
                    Paginator.textPieceMetrics(likes_face)
                local likes_paginated = Paginator.paginateText(
                    block.likes_text, likes_face, likes_width_max)
                local likes_w = 0
                for _, line in ipairs(likes_paginated.lines or {}) do
                    likes_w = math.max(likes_w, line.width or 0)
                end
                likes_w = math.max(1, math.min(likes_width_max,
                    math.ceil(likes_w)))
                likes_piece = {
                    kind = "text", variant = "likes", text = block.likes_text,
                    fg = block.likes_fg, face = likes_face,
                    width = likes_w, x = text_w - likes_w, y = y,
                    n_lines = likes_paginated.n_lines, line_h = likes_line_h,
                    piece_h = likes_paginated.n_lines * likes_line_h + likes_extra,
                    baseline = likes_baseline,
                    xtext = likes_paginated.xtext, lines = likes_paginated.lines,
                    line_bounds = {}, align = "right", targeted_width = likes_w,
                }
                for k = 1, likes_piece.n_lines do
                    likes_piece.line_bounds[k] = {
                        top = y + (k - 1) * likes_line_h,
                        bottom = y + k * likes_line_h,
                    }
                end
            end
            end
            local author_width = likes_piece
                and math.max(1, likes_piece.x - math.floor(base_size * 0.6 + 0.5))
                or text_w
            -- 记录 likes 构造时的 y:author 排版会推进 y,lb 偏移必须以
            -- 构造点为基准(CodeRabbit 式边界 bug:用推进后的 y 算偏移
            -- 会得出 0,likes 行边界留在构造位置导致整块不可见)。
            local likes_base_y = y
            local author_added = addTextPiece("meta", block.text, block.fg,
                author_width, 0, false)
            if author_added and likes_piece then
                -- 基线对齐:likes 列顶部下移,与 author 首行基线一致
                local author_piece = pieces[#pieces]
                likes_piece.y = likes_base_y + math.max(0,
                    (author_piece.baseline or 0) - (likes_piece.baseline or 0))
                local lb_shift = likes_piece.y - likes_base_y
                for k, bounds in ipairs(likes_piece.line_bounds) do
                    bounds.top = bounds.top + lb_shift
                    bounds.bottom = bounds.bottom + lb_shift
                end
                pieces[#pieces + 1] = likes_piece
                local row_h = math.max(author_piece.piece_h,
                    likes_piece.y - likes_base_y + likes_piece.piece_h)
                -- 边界注册顺序必须按 top 单调:likes 行(同 y 起)在 author
                -- 多行边界之前插入;computePages 顺序遍历,乱序会切断 likes
                -- 的可见区间(它整块不可见)。
                local author_bounds_count = #author_piece.line_bounds
                local insert_at = #boundaries - author_bounds_count + 1
                for k = #likes_piece.line_bounds, 1, -1 do
                    local bounds = likes_piece.line_bounds[k]
                    table.insert(boundaries, insert_at,
                        { top = bounds.top, bottom = bounds.bottom })
                end
                -- meta 行边界覆盖整组 header(分隔线+双列),供长按定位
                boundaries[#boundaries + 1] = {
                    top = header_top, bottom = likes_base_y + row_h,
                }
                y = likes_base_y + row_h
            elseif author_added then
                local author_piece = pieces[#pieces]
                boundaries[#boundaries + 1] = {
                    top = header_top,
                    bottom = author_piece.y + author_piece.piece_h,
                }
            end
            y = y + math.floor(base_size * (block.spacing_after or 0) + 0.5)
        elseif block.kind == "paragraph" then
            y = y + math.floor(base_size * (block.spacing_before or 0) + 0.5)
            addTextPiece(block.variant, block.text, block.fg, text_w, 0,
                block.variant == "meta")
            y = y + math.floor(base_size * (block.spacing_after or 0) + 0.5)
        end
    end

    local content_h = math.max(1, y)
    local t2 = os.clock()
    if PopupDiagnostic.is_enabled() then
        logger.info(string.format(
            "[撷思][ThoughtPopup] paginated in %.1fms (blocks %.1fms) items=%d content_h=%d",
            (t2 - t0) * 1000, (t1 - t0) * 1000, #self.items, content_h))
    end
    PopupDiagnostic.log("popup_paginate", {elapsed_ms=math.floor((t2-t0)*1000+0.5),
        blocks_ms=math.floor((t1-t0)*1000+0.5), items=#self.items, content_h=content_h})
    return {
        pieces = pieces,
        boundaries = boundaries,
        content_h = content_h,
        item_count = #self.items,
        text_w = text_w,
    }
end

--- (Re)build the layout: free stale page bitmaps, load the cached layout or
--- paginate. Idempotent; call once after construction / setContent.
function PageRenderer:ensureLayout()
    self:_freePageBBs()
    self:_freePieceCache()
    self._layout_cache = self._layout_cache or newLayoutCache()
    local cached = self._layout_cache:get(self._bb_key)
    if cached then
        self.layout = cached
        self.content_h = cached.content_h
        self.boundaries = cached.boundaries
        self.text_w = cached.text_w
        return
    end
    local layout = LayoutItem:new(self:paginate())
    self._layout_cache:insert(self._bb_key, layout)
    self.layout = layout
    self.content_h = layout.content_h
    self.boundaries = layout.boundaries
    self.text_w = layout.text_w
end

--- Page start list for a viewport height (pure logic, see paginator.lua).
--- Always contains at least { 0 }.
function PageRenderer:computePages(viewport_h)
    return Paginator.computePages(self.boundaries, viewport_h, self.content_h)
end

function PageRenderer:_getPieceTextBB(piece)
    self._piece_cache = self._piece_cache or newPieceCache()
    local cached = self._piece_cache:get(piece)
    if cached then return cached.bb end
    local bb = Paginator.renderTextPiece(piece)
    if not bb then return nil end
    self._piece_cache:insert(piece, PieceItem:new{ bb = bb })
    return bb
end

function PageRenderer:_freePieceCache()
    if self._piece_cache and self._piece_cache.clear then
        self._piece_cache:clear()
    else
        self._piece_cache = newPieceCache()
    end
end

--- Render (and cache) the bitmap of page page_idx within page_starts.
--- page_starts is the page list returned by computePages; the page -> piece
--- index is rebuilt whenever a different page_starts table is passed.
function PageRenderer:renderPage(page_idx, page_starts)
    if self._page_pieces_key ~= page_starts then
        self._page_pieces = Paginator.buildPagePieceIndex(
            self.layout and self.layout.pieces, page_starts, self.content_h)
        self._page_pieces_key = page_starts
    end
    self._page_bbs = self._page_bbs or newPageCache()
    local cached = self._page_bbs:get(page_idx)
    if cached then return cached.bb end
    if not page_starts or page_idx < 1 or page_idx > #page_starts then return nil end
    local p0 = page_starts[page_idx]
    local p1 = page_starts[page_idx + 1] or self.content_h
    local h = math.max(1, p1 - p0)
    local bbtype = Screen:isColorEnabled() and Blitbuffer.TYPE_BBRGB32 or Blitbuffer.TYPE_BB8
    local bb = Blitbuffer.new(self.text_w, h, bbtype)
    bb:fill(Blitbuffer.COLOR_WHITE)

    for _, piece in ipairs(self._page_pieces[page_idx] or {}) do
        local r = Paginator.pieceVisibleRange(piece, p0, p1)
        if r and piece.kind == "separator" then
            -- 分隔线(上游 #193):在 piece.y 处画一条 text_w 宽、piece_h 粗的灰线,
            -- 随页面位图一起被裁剪(r.dest_y/r.src_y 处理跨页)。
            -- 颜色取用与现有渲染兼容:灰度值直接走 Color8(有桩环境可能缺构造器,
            -- 此时退回 paintRect 的默认白写——线缺失但不崩)。
            local line_y = math.floor(r.dest_y + 0.5)
            local line_h = math.min(math.ceil(r.src_h), h - line_y)
            if line_y >= 0 and line_h > 0 then
                local ok_paint, paint_err = pcall(function()
                    if Screen:isColorEnabled() then
                        bb:paintRectRGB32(0, line_y, self.text_w, line_h,
                            Blitbuffer.ColorRGB32(piece.fg, 0xFF))
                    else
                        bb:paintRect(0, line_y, self.text_w, line_h,
                            Blitbuffer.Color8(piece.fg))
                    end
                end)
                if not ok_paint then
                    PopupDiagnostic.log("popup_separator_paint_fallback",
                        {err = tostring(paint_err)})
                end
            end
        elseif r and piece.kind == "text" then
            local text_bb = self:_getPieceTextBB(piece)
            if text_bb then
                local source_height = text_bb.getHeight and text_bb:getHeight() or piece.piece_h
                local source_width = text_bb.getWidth and text_bb:getWidth() or piece.width
                local src_y = math.max(0, math.floor(r.src_y + 0.5))
                local src_end = math.min(source_height,
                    math.ceil(r.src_y + r.src_h - 0.5))
                local dest_y = math.floor(r.dest_y + 0.5)
                if dest_y < 0 then
                    src_y = src_y - dest_y
                    dest_y = 0
                end
                local blit_h = math.min(src_end - src_y, h - dest_y)
                local blit_w = math.min(piece.width, source_width, self.text_w)
                if src_y < src_end and blit_h > 0 and blit_w > 0 and dest_y < h then
                    bb:blitFrom(text_bb, piece.x, dest_y, 0, src_y, blit_w, blit_h)
                end
            else
                logger.warn("[撷思][ThoughtPopup] text render failed:",
                    "y=", piece.y, "n_lines=", piece.n_lines,
                    "text=", tostring(piece.text):sub(1, 40))
            end
        end
    end

    self._page_bbs:insert(page_idx, PageItem:new{ bb = bb })
    return bb
end

function PageRenderer:_freePageBBs()
    if self._page_bbs and self._page_bbs.clear then
        self._page_bbs:clear()
    else
        self._page_bbs = newPageCache()
    end
    self._page_pieces = {}
    self._page_pieces_key = nil
end

--- Drop every cached bitmap and layout (called on document close / position
--- switch); the next use re-paginates from scratch.
function PageRenderer:freeContentCaches()
    self:_freePageBBs()
    self:_freePieceCache()
    if self._layout_cache and self._layout_cache.clear then
        self._layout_cache:clear()
    else
        self._layout_cache = newLayoutCache()
    end
    self.layout = nil
    self.boundaries = nil
end

return PageRenderer
