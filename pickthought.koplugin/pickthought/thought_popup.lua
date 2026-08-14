-- 原生想法弹窗。
-- 参考 weread.koplugin 的 thought_popup:用 TextViewer 的文本布局测量分页,
-- 并用自定义按钮替换查找/顶部/底部/关闭默认按钮。

local Device = require("device")
local BD = require("ui/bidi")
local Font = require("ui/font")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local logger = require("logger")

local Screen = Device.screen
local SEPARATOR = "\n\n"

local NativeThoughtPopup = TextViewer:extend{
    items = nil,
    display_pages = nil,
    page_index = 1,
    height_ratio = 0.62,
    completion_callback = nil,
}

local function format_item(item)
    local meta = "▸ " .. tostring(item.author or "微信读书用户")
    local likes = tonumber(item.likes_count or item.likes or 0) or 0
    if likes > 0 then meta = meta .. "  · 赞 " .. tostring(likes) end
    return meta .. "\n" .. tostring(item.content or "")
end

local function build_pages(items, fits)
    local pages, first, texts = {}, 1, {}
    local function flush(last)
        pages[#pages + 1] = {first_index = first, last_index = last,
            text = table.concat(texts, SEPARATOR)}
    end
    for index, item in ipairs(items) do
        local item_text = format_item(item)
        if #texts > 0 then
            local candidate = {}
            for i, text in ipairs(texts) do candidate[i] = text end
            candidate[#candidate + 1] = item_text
            if not fits(table.concat(candidate, SEPARATOR)) then
                flush(index - 1)
                first, texts = index, {}
            end
        end
        texts[#texts + 1] = item_text
    end
    if #texts > 0 then flush(#items) end
    return pages
end

-- KOReader 新版使用 scroll_widget/box_widget,旧版使用 scroll_text_w.text_widget。
function NativeThoughtPopup:_text_widgets()
    local scroll = self.scroll_widget or self.scroll_text_w
    local box = self.box_widget or (scroll and scroll.text_widget)
    return scroll, box
end

function NativeThoughtPopup:_measure_pages()
    local _, box = self:_text_widgets()
    if not box or type(box.getVisLineCount) ~= "function" then return end
    local visible_lines = box:getVisLineCount()
    local function fits(text)
        local measurement = TextBoxWidget:new{
            text = text,
            dialog = self,
            face = box.face,
            fgcolor = box.fgcolor,
            width = box.width,
            alignment = self.alignment,
            justified = self.justified,
            lang = self.lang,
            para_direction_rtl = self.para_direction_rtl,
            auto_para_direction = self.auto_para_direction,
            alignment_strict = self.alignment_strict,
            for_measurement_only = true,
        }
        local lines = measurement:getAllLineCount()
        measurement:free()
        return lines <= visible_lines
    end
    local ok, pages = pcall(build_pages, self.items, fits)
    if ok and type(pages) == "table" and #pages > 0 then
        self.display_pages = pages
    else
        logger.warn("[撷思][ThoughtPopup] 分页测量失败:", tostring(pages))
    end
end

function NativeThoughtPopup:_update_page()
    local count = #self.display_pages
    if self.page_index < 1 then
        self.page_index = 1
    elseif self.page_index > count then
        self.page_index = count
    end
    local page = self.display_pages[self.page_index]
    local abstract = self.items[1] and self.items[1].abstract
    self.title = type(abstract) == "string" and abstract ~= "" and abstract:gsub("%s+", " ") or "想法"
    self.text = page.text
    self.charlist = nil
end

function NativeThoughtPopup:_progress_text()
    local page = self.display_pages[self.page_index]
    return tostring(page.last_index) .. "/" .. tostring(#self.items)
end

function NativeThoughtPopup:_build_buttons()
    local popup = self
    return {{
        {
            text = "‹ 上一条",
            id = "previous_thought",
            enabled_func = function() return popup.page_index > 1 end,
            callback = function() popup:change_page(-1) end,
        },
        {
            text = popup:_progress_text(),
            id = "thought_position",
            callback = function() end,
        },
        {
            text = "下一条 ›",
            id = "next_thought",
            enabled_func = function() return popup.page_index < #popup.display_pages end,
            callback = function() popup:change_page(1) end,
        },
    }}
end

function NativeThoughtPopup:_sync_buttons()
    if not (self.button_table and self.button_table.getButtonById) then return end
    local previous = self.button_table:getButtonById("previous_thought")
    local position = self.button_table:getButtonById("thought_position")
    local next_button = self.button_table:getButtonById("next_thought")
    local function set_enabled(button, enabled)
        if not button then return end
        if button.enableDisable then
            button:enableDisable(enabled)
        elseif enabled then
            button:enable()
        else
            button:disable()
        end
        if button.refresh then button:refresh() end
    end
    set_enabled(previous, self.page_index > 1)
    set_enabled(next_button, self.page_index < #self.display_pages)
    if position and position.setText then
        position:setText(self:_progress_text(), position.width)
        if position.refresh then position:refresh() end
    end
end

function NativeThoughtPopup:_replace_text()
    local scroll, box = self:_text_widgets()
    if not (box and type(box.setText) == "function") then return false end
    box.virtual_line_num = 1
    box.charlist = nil
    box:setText(self.text)
    if scroll then
        scroll.text = self.text
        if scroll.resetScroll then scroll:resetScroll() end
    end
    return true
end

function NativeThoughtPopup:init(reinit)
    self.items = self.items or {}
    self.display_pages = self.display_pages or build_pages(self.items, function() return false end)
    self.page_index = math.max(1, math.min(self.page_index or 1, #self.display_pages))
    self.height_ratio = math.max(0.55, math.min(0.85, self.height_ratio or 0.62))
    self.width = Screen:getWidth() - Screen:scaleBySize(24)
    self.height = math.floor(Screen:getHeight() * self.height_ratio)
    self.show_menu = false
    self.add_default_buttons = false
    self.text_type = "general"
    self.alignment = "left"
    self.auto_para_direction = true
    self.title_multilines = true
    self.title_face = Font:getFace("x_smalltfont", 18)
    self.buttons_table = self:_build_buttons()
    self:_update_page()
    TextViewer.init(self, reinit)
    -- 点按由弹窗处理为上一条/下一条,正文上下滑动仍由 ScrollTextWidget 滚动。
    local scroll = self:_text_widgets()
    if scroll and scroll.setTapScrollEnabled then
        scroll:setTapScrollEnabled(false)
    end
    if not reinit and not self._pages_measured then
        self._pages_measured = true
        self:_measure_pages()
        self:_update_page()
        if self.titlebar and self.titlebar.setTitle then
            self.titlebar:setTitle(self.title, true)
        end
        self:_replace_text()
        self:_sync_buttons()
    end
end

function NativeThoughtPopup:onTapClose(arg, ges)
    if ges and ges.pos and self.textw
            and ges.pos:intersectWith(self.textw.dimen) then
        local previous = ges.pos.x < Screen:getWidth() / 2
        if BD.flipIfMirroredUILayout then
            previous = BD.flipIfMirroredUILayout(previous)
        end
        self:change_page(previous and -1 or 1)
        return true
    end
    return TextViewer.onTapClose(self, arg, ges)
end

function NativeThoughtPopup:onSwipe(arg, ges)
    if not (ges and ges.pos and self.textw
            and ges.pos:intersectWith(self.textw.dimen)) then
        return TextViewer.onSwipe(self, arg, ges)
    end

    local direction = BD.flipDirectionIfMirroredUILayout(ges.direction)
    if direction == "west" then
        self:change_page(1)
        return true
    elseif direction == "east" then
        self:change_page(-1)
        return true
    elseif direction == "north" or direction == "south" then
        local scroll = self:_text_widgets()
        if scroll and scroll.scrollText then
            scroll:scrollText(direction == "north" and 1 or -1)
            return true
        end
    end
    return false
end

function NativeThoughtPopup:change_page(delta)
    local next_index = self.page_index + delta
    if next_index < 1 or next_index > #self.display_pages then return end
    self.page_index = next_index
    self:_update_page()
    if not self:_replace_text() then
        self:init(true)
        local scroll = self:_text_widgets()
        if scroll and scroll.scrollToTop then scroll:scrollToTop() end
    end
    self:_sync_buttons()
    -- 标题栏是固定的原文摘录,切换想法只刷新正文区域;按钮由各自的
    -- refresh() 处理,避免整块弹窗重绘导致标题栏闪屏。
    if self.textw and self.textw.dimen then
        UIManager:setDirty(self, "partial", self.textw.dimen)
    elseif self.frame and self.frame.dimen then
        UIManager:setDirty(self, "partial", self.frame.dimen)
    end
end

function NativeThoughtPopup:onClose()
    UIManager:close(self)
    return true
end

function NativeThoughtPopup:onCloseWidget()
    TextViewer.onCloseWidget(self)
    if self.completion_callback then
        local callback = self.completion_callback
        self.completion_callback = nil
        callback()
    end
end

local Popup = {}
local active

local function is_showing(widget)
    if not widget then return false end
    local ok, shown = pcall(UIManager.isWidgetShown, UIManager, widget)
    return ok and shown == true
end

function Popup.show(opts)
    opts = opts or {}
    local items = opts.items or opts.pages
    if type(items) ~= "table" or #items == 0 then error("想法弹窗缺少内容") end
    if active and is_showing(active) then UIManager:close(active) end
    local popup
    popup = NativeThoughtPopup:new{
        items = items,
        page_index = opts.page_index or 1,
        height_ratio = opts.height_ratio,
        completion_callback = function()
            if active == popup then active = nil end
            if opts.close_callback then opts.close_callback() end
        end,
    }
    active = popup
    UIManager:show(active)
    return active
end

function Popup.close_visible()
    if active then UIManager:close(active); active = nil end
end

function Popup.is_showing()
    return is_showing(active)
end

return Popup
