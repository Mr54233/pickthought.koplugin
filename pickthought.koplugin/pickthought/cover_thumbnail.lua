--[[--
封面缩略渲染(Issue #28 绑定书籍详情)。

移植自上游 weread lib/cover_thumbnail.lua:解码 → 等比缩放 → writePNG,
渲染完立即释放中间 blitbuffer。上游在子进程渲染(书架网格批量场景);
撷思是长按详情的单书单图(封面 ≤660×990,blitbuffer ≤3MB),同步解码
预计 <300ms,弹窗打开路径可接受;真机若感知卡顿再迁 runInSubProcess,
外部接口不变。
--]]--

local RenderImage = require("ui/renderimage")

local CoverThumbnail = {}

local function free(buffer)
    if buffer and type(buffer.free) == "function" then
        pcall(buffer.free, buffer)
    end
end

-- source:封面图片文件路径;target:缩放后 PNG 输出路径。
-- 成功返回 target,失败返回 nil + 错误信息。
function CoverThumbnail.render(source, target, max_width, max_height)
    max_width = math.max(1, math.floor(tonumber(max_width) or 160))
    max_height = math.max(1, math.floor(tonumber(max_height) or 240))
    local image, scaled
    local ok, result = xpcall(function()
        image = assert(RenderImage:renderImageFile(source, false, nil, nil),
            "cover decode failed")
        local width = math.max(1, tonumber(image:getWidth()) or 1)
        local height = math.max(1, tonumber(image:getHeight()) or 1)
        local ratio = math.min(1, max_width / width, max_height / height)
        local target_width = math.max(1, math.floor(width * ratio + 0.5))
        local target_height = math.max(1, math.floor(height * ratio + 0.5))
        if target_width ~= width or target_height ~= height then
            scaled = assert(RenderImage:scaleBlitBuffer(
                image, target_width, target_height, false), "cover scale failed")
        else
            scaled = image
        end
        -- KOReader 的 writePNG 失败时抛错,成功无返回值。
        scaled:writePNG(target)
        return target
    end, debug.traceback)
    if scaled ~= image then free(scaled) end
    free(image)
    if not ok then return nil, result end
    return result
end

return CoverThumbnail
