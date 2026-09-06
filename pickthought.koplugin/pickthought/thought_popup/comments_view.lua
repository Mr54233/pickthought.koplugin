-- 评论视图的内容构建(居中/底部两个弹窗组件共用,实施文档 §5)。
--
-- 不新建第二个弹窗:评论视图复用现有 PageRenderer 管线,这里只负责把
-- "被长按的想法 + 归一化后的评论"折叠成渲染器认识的 items 形状:
--   { abstract, author, content, likes_count, review_id }
--
-- 位置差异(用户澄清:第一层"正文摘录的位置"变成这条想法,下面是评论):
--   * center(skip_quote=true):标题栏显示被长按的想法本身,items 只放评论;
--   * bottom(无标题栏):父想法的 content 放进 items[1].abstract,由
--     quote 块渲染为「…」摘要;author/likes 置空,meta 行(作者名)不渲染,
--     想法原文下面直接就是评论列表。
--
-- 两个列表的条目仍是标准想法 item 形状,因此长按评论仍走同一套
-- _findItemAtContentY → 菜单逻辑(评论带自身 review_id 时可继续下钻)。
local RC = require("pickthought.review_comments")
local sanitize_meta = RC.sanitize_meta

local M = {}

local function trim(value)
    if type(value) ~= "string" then return "" end
    return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- 评论视图标题(居中布局,显示在第一层原文摘录的位置):
--- 被长按的那条想法本身(用户澄清:顶部变成这条想法)。
function M.comment_title(parent_item)
    parent_item = type(parent_item) == "table" and parent_item or {}
    local content = trim(tostring(parent_item.content or ""))
    if content == "" then content = trim(tostring(parent_item.abstract or "")) end
    return content
end

--- items[1] 是否渲染 meta 行(content_builder:作者/赞/评论数任一非空才渲染)。
--- _findItemAtContentY 用它修正"第 k 个 meta 块对应第几条 item"的定位:
--- 底部评论视图的 items[1](想法原文引用块)没有 meta 行,后续 meta 块
--- 对应 items[2]、items[3]…,直接数 meta 会整体错一位。
function M.first_item_has_meta(items)
    local first = type(items) == "table" and items[1] or nil
    if type(first) ~= "table" then return false end
    if trim(tostring(first.author or "")) ~= "" then return true end
    if (tonumber(first.likes_count) or 0) > 0 then return true end
    return (tonumber(first.comment_count) or 0) > 0
end

--- 当前视口内的想法条目(评论数懒加载):以条目的 meta 行是否落在
--- y 范围 [top,bottom) 内为准——"评论 N"显示在 meta 行上,meta 不在
--- 屏上时刷了也看不见,滚回来时防抖回调自然会补。meta 计数走全量
--- piece 序列(窗口上方还有 meta,窗口内第 1 个 meta 并不是全局第 1
--- 条),quote 块 → items[1],第 k 个 meta 块 → items[k+偏移](首条无
--- meta 行时偏移 +1),与组件的 _findItemAtContentY 同规则。
function M.items_in_view(items, pieces, top, bottom)
    items = type(items) == "table" and items or {}
    local out = {}
    if type(pieces) ~= "table" or #pieces == 0 then return out end
    if type(top) ~= "number" or type(bottom) ~= "number" or bottom <= top then
        return out
    end
    local base = M.first_item_has_meta(items) and 0 or 1
    local seen, meta_count = {}, 0
    for _, piece in ipairs(pieces) do
        if type(piece) == "table" then
            local variant = piece.variant
            if variant == "meta" then
                meta_count = meta_count + 1
            end
            local visible = type(piece.y) == "number" and type(piece.piece_h) == "number"
                and piece.y < bottom and (piece.y + piece.piece_h) > top
            if visible and (variant == "quote" or variant == "meta") then
                local idx = variant == "quote" and 1 or (meta_count + base)
                local item = items[idx]
                if item and not seen[item] then
                    seen[item] = true
                    out[#out + 1] = item
                end
            end
        end
    end
    return out
end

--- 构建评论视图渲染条目。
--- @param parent_item table 被长按的想法 item(含 author/content/likes_count)
--- @param comments table[] normalize_response 返回的评论数组
--- @param position string "center" | "bottom"
--- @return table[] items
function M.build_items(parent_item, comments, position)
    parent_item = type(parent_item) == "table" and parent_item or {}
    local parent = {
        content = trim(tostring(parent_item.content or "")),
        review_id = trim(tostring(parent_item.review_id or "")),
    }

    -- 需求(用户澄清):第一层弹窗"正文摘录的位置"变成这条想法,
    -- 内容区只放评论列表。
    --  * 居中:那条想法显示在标题栏(原文摘录的位置),由组件的
    --    _title() 取 parent 内容;items 只放评论。
    --  * 底部:quote 块(原正文摘要的位置)承载这条想法;author/likes
    --    置空让 meta 行(作者名)不渲染,想法原文下面直接接评论。
    local items = {}
    if position == "bottom" then
        items[#items + 1] = {
            abstract = parent.content,
            author = "",
            content = "",
            likes_count = 0,
            review_id = parent.review_id,
        }
    end

    for _, comment in ipairs(type(comments) == "table" and comments or {}) do
        if type(comment) == "table" and trim(tostring(comment.content or "")) ~= "" then
            local author = sanitize_meta(comment.author)
            items[#items + 1] = {
                abstract = "",
                author = author ~= "" and author or "微信读书用户",
                content = trim(tostring(comment.content or "")),
                likes_count = tonumber(comment.likes_count) or 0,
                review_id = trim(tostring(comment.review_id or "")),
            }
        end
    end
    return items
end

return M
