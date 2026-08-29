-- 同步进度对话框:改自原撷思 download_progress.lua。
-- 左「取消同步」右「后台同步」;后台后任务继续,可从菜单再次打开本对话框。
local Blitbuffer = require("ffi/blitbuffer")
local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local InputContainer = require("ui/widget/container/inputcontainer")
local ProgressWidget = require("ui/widget/progresswidget")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local U = require("pickthought.util")

local Screen = Device.screen

local SyncProgress = InputContainer:extend{
    title = "撷思同步",
    on_cancel = nil,
    on_background = nil,
}

local function clamp(v, lo, hi)
    v = tonumber(v) or lo
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

function SyncProgress:init()
    self.dimen = Screen:getSize()
    self.cancelled = false
    self._title = self.title or "撷思同步"

    local frame_width = math.floor(Screen:getWidth() * 0.82)
    local frame_height = math.floor(Screen:getHeight() * 0.60)
    local content_width = frame_width - Size.padding.large * 2
    local content_height = frame_height - Size.padding.large * 2
    local group = VerticalGroup:new{align="center"}

    self.title_widget = TextBoxWidget:new{
        text = self._title,
        face = Font:getFace("ffont", 22),
        bold = true,
        width = content_width,
        height = math.floor(content_height * 0.15),
        height_adjust = false,
        height_overflow_show_ellipsis = true,
        alignment = "center",
    }
    group[#group + 1] = self.title_widget
    group[#group + 1] = VerticalSpan:new{width = Size.padding.large}

    self.progress = ProgressWidget:new{
        width = content_width,
        height = Screen:scaleBySize(20),
        percentage = 0,
        fillcolor = Blitbuffer.COLOR_BLACK,
        padding = Size.padding.small,
        margin = Size.margin.tiny,
    }
    group[#group + 1] = self.progress
    group[#group + 1] = VerticalSpan:new{width = Size.padding.small}

    self.percent_widget = TextBoxWidget:new{
        text = "0%",
        face = Font:getFace("cfont", 19),
        width = content_width,
        height = math.floor(content_height * 0.07),
        height_adjust = false,
        alignment = "center",
    }
    group[#group + 1] = self.percent_widget
    group[#group + 1] = VerticalSpan:new{width = Size.padding.large}

    self.status_widget = TextBoxWidget:new{
        text = "准备同步……",
        face = Font:getFace("cfont", 18),
        width = content_width,
        height = math.floor(content_height * 0.48),
        height_adjust = false,
        height_overflow_show_ellipsis = true,
        alignment = "center",
    }
    group[#group + 1] = self.status_widget
    group[#group + 1] = VerticalSpan:new{width = Size.padding.large}

    self.buttons = ButtonTable:new{
        width = content_width,
        show_parent = self,
        zero_sep = true,
        buttons = {{
            {
                text = "取消同步",
                callback = function()
                    if self.cancelled then return end
                    self.cancelled = true
                    self.status_widget:setText("正在取消……")
                    self:_redraw()
                    if self.on_cancel then self.on_cancel() end
                end,
            },
            {
                text = "后台同步",
                callback = function()
                    if self.cancelled then return end
                    if self.on_background then self.on_background() end
                end,
            },
        }},
    }
    group[#group + 1] = self.buttons

    local fixed_area = CenterContainer:new{
        dimen = Geom:new{x=0, y=0, w=content_width, h=content_height},
        group,
    }
    self.frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.window,
        radius = Size.radius.window,
        padding = Size.padding.large,
        fixed_area,
    }
    self[1] = CenterContainer:new{
        dimen = self.dimen,
        self.frame,
    }
end

local function clean_status(value, limit)
    local text = tostring(value or ""):gsub("[%c]+", " "):gsub("%s+", " ")
    text = U.trim(text)
    limit = tonumber(limit) or 160
    if #text > limit then text = text:sub(1, limit) .. "…" end
    return text
end

function SyncProgress:_redraw()
    local target = (self.frame and self.frame.dimen) or self.dimen
    UIManager:setDirty(self, function()
        return "fast", target
    end)
end

function SyncProgress._title_for_state(state)
    state = state or {}
    if state.stage ~= "chapters" and state.stage ~= "fetch" then return nil end
    local book_title = clean_status(state.book_title, 100)
    if book_title == "" then return nil end
    return "正在同步《" .. book_title .. "》"
end

function SyncProgress:set_title(title)
    if title == nil then return false end
    title = clean_status(title, 100)
    if title == "" or title == self._title then return false end
    self._title = title
    self.title = title
    if self.title_widget then self.title_widget:setText(title) end
    return true
end

function SyncProgress:set_state(state)
    state = state or {}
    -- 多书拉取阶段把当前远端书名放在标题，而不是正文再加一行重复信息。
    -- 映射/注入是合集级操作，保留最后一个拉取书目的标题即可。
    local title_changed = self:set_title(SyncProgress._title_for_state(state))
    local current = tonumber(state.current) or 0
    local total = tonumber(state.total) or 0
    local percent = tonumber(state.percent)
    if not percent then
        percent = total > 0 and (current / total) or 0
    elseif percent > 1 then
        percent = percent / 100
    end
    percent = clamp(percent, 0, 1)

    local labels = {
        prepare = "读取本地书",
        chapters = "获取章节列表",
        resume = "恢复同步断点",
        fetch = "拉取划线与想法",
        map = "匹配本地章节",
        inject = "生成划线版并替换原书",
        done = "同步完成",
        error = "同步失败",
        cancelled = "同步已取消",
    }
    local rows = {}
    rows[#rows + 1] = labels[state.stage] or tostring(state.stage or "处理中")
    if total > 0 and state.stage == "fetch" then
        rows[#rows + 1] = "章节 " .. tostring(current) .. " / " .. tostring(total)
    elseif total > 0 and state.stage == "map" then
        rows[#rows + 1] = "正文文件 " .. tostring(current) .. " / " .. tostring(total)
        if total > 200 then rows[#rows + 1] = "大型书籍的文本匹配需要较长时间,请耐心等待" end
    elseif total > 0 and current > 0 and state.stage == "inject" then
        rows[#rows + 1] = "写入文件 " .. tostring(current) .. " / " .. tostring(total)
        if total > 200 then rows[#rows + 1] = "大型书籍的注入与压缩需要几分钟,请耐心等待" end
    end
    if state.chapter and state.chapter ~= "" then rows[#rows + 1] = clean_status(state.chapter, 120) end
    if state.message and state.message ~= "" then rows[#rows + 1] = clean_status(state.message, 180) end
    local percent_text = tostring(math.floor(percent * 100 + 0.5)) .. "%"
    local status_text = table.concat(rows, "\n")
    local signature = percent_text .. "\n" .. status_text
    if signature == self._last_signature and not title_changed then return end
    self._last_signature = signature
    self.progress:setPercentage(percent)
    self.percent_widget:setText(percent_text)
    self.status_widget:setText(status_text)
    self:_redraw()
end

function SyncProgress:show()
    UIManager:show(self, "ui")
end

function SyncProgress:close()
    UIManager:close(self, "ui")
end

return SyncProgress
