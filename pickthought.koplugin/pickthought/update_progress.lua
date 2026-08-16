local Blitbuffer=require("ffi/blitbuffer")
local ButtonTable=require("ui/widget/buttontable")
local CenterContainer=require("ui/widget/container/centercontainer")
local Device=require("device")
local Font=require("ui/font")
local FrameContainer=require("ui/widget/container/framecontainer")
local Geom=require("ui/geometry")
local InputContainer=require("ui/widget/container/inputcontainer")
local ProgressWidget=require("ui/widget/progresswidget")
local Size=require("ui/size")
local TextBoxWidget=require("ui/widget/textboxwidget")
local UIManager=require("ui/uimanager")
local VerticalGroup=require("ui/widget/verticalgroup")
local VerticalSpan=require("ui/widget/verticalspan")

local UpdateProgress=InputContainer:extend{
    title="更新撷思",
    on_cancel=nil,
}

local function format_bytes(value)
    value=tonumber(value) or 0
    if value>=1024*1024 then return string.format("%.1f MB",value/(1024*1024)) end
    if value>=1024 then return string.format("%.0f KB",value/1024) end
    return tostring(value).." B"
end

local function clean(value,limit)
    local text=tostring(value or ""):gsub("[%c]+"," "):gsub("%s+"," ")
    text=text:gsub("^%s+",""):gsub("%s+$","")
    limit=tonumber(limit) or 180
    return #text>limit and text:sub(1,limit).."…" or text
end

function UpdateProgress:init()
    self.dimen=Device.screen:getSize()
    self.cancelled=false
    local frame_width=math.floor(Device.screen:getWidth()*0.84)
    local frame_height=math.floor(Device.screen:getHeight()*0.43)
    local content_width=frame_width-Size.padding.large*2
    local content_height=frame_height-Size.padding.large*2
    local group=VerticalGroup:new{align="center"}

    self.title_widget=TextBoxWidget:new{
        text=self.title,face=Font:getFace("ffont",22),bold=true,
        width=content_width,height=math.floor(content_height*0.16),
        height_adjust=false,height_overflow_show_ellipsis=true,alignment="center",
    }
    group[#group+1]=self.title_widget
    group[#group+1]=VerticalSpan:new{width=Size.padding.large}
    self.progress=ProgressWidget:new{
        width=content_width,height=Device.screen:scaleBySize(20),percentage=0,
        fillcolor=Blitbuffer.COLOR_BLACK,padding=Size.padding.small,margin=Size.margin.tiny,
    }
    group[#group+1]=self.progress
    group[#group+1]=VerticalSpan:new{width=Size.padding.small}
    self.percent_widget=TextBoxWidget:new{
        text="0%",face=Font:getFace("cfont",19),width=content_width,
        height=math.floor(content_height*0.13),height_adjust=false,alignment="center",
    }
    group[#group+1]=self.percent_widget
    self.status_widget=TextBoxWidget:new{
        text="准备下载更新……",face=Font:getFace("cfont",18),width=content_width,
        height=math.floor(content_height*0.37),height_adjust=false,
        height_overflow_show_ellipsis=true,alignment="center",
    }
    group[#group+1]=self.status_widget
    group[#group+1]=VerticalSpan:new{width=Size.padding.small}
    group[#group+1]=ButtonTable:new{
        width=content_width,show_parent=self,zero_sep=true,buttons={{
            {text="取消下载",callback=function()
                if self.cancelled then return end
                self.cancelled=true
                self.status_widget:setText("正在取消……")
                self:_redraw()
                if self.on_cancel then self.on_cancel() end
            end},
        }},
    }

    local fixed=CenterContainer:new{
        dimen=Geom:new{x=0,y=0,w=content_width,h=content_height},group,
    }
    self.frame=FrameContainer:new{
        background=Blitbuffer.COLOR_WHITE,bordersize=Size.border.window,
        radius=Size.radius.window,padding=Size.padding.large,fixed,
    }
    self[1]=CenterContainer:new{dimen=self.dimen,self.frame}
end

function UpdateProgress:_redraw()
    local target=(self.frame and self.frame.dimen) or self.dimen
    UIManager:setDirty(self,function() return "fast",target end)
end

function UpdateProgress:set_state(event)
    event=event or {}
    local stage=tostring(event.stage or "preparing")
    local percent=tonumber(event.percent) or 0
    percent=math.max(0,math.min(100,percent))
    self.progress:setPercentage(percent/100)
    self.percent_widget:setText(tostring(math.floor(percent+0.5)).."%")
    local status
    if stage=="downloading" then
        local current=tonumber(event.current) or 0
        local total=tonumber(event.total) or 0
        local source=event.source and event.sources and
            ("\n下载源 "..tostring(event.source).."/"..tostring(event.sources)) or ""
        if total>0 then
            status="正在下载更新\n"..format_bytes(current).." / "..format_bytes(total)..source
        else
            status="正在下载更新\n已下载 "..format_bytes(current)..source
        end
    elseif stage=="verifying" then
        status="正在校验更新包……"
    elseif stage=="installing" then
        status="正在安装更新……"
    elseif stage=="complete" then
        status="更新已安装"
    else
        status="正在准备更新……"
    end
    self.status_widget:setText(clean(status,220))
    self:_redraw()
end

function UpdateProgress:show() UIManager:show(self,"ui") end
function UpdateProgress:close() UIManager:close(self,"ui") end

return UpdateProgress
