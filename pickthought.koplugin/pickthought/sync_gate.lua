-- 后台同步期间的前台操作门禁与确认上下文校验。
-- 只做纯状态判断,具体提示和操作由 main.lua 负责。
local Gate = {}

function Gate.busy(sync_task)
    return sync_task ~= nil and type(sync_task.busy) == "function"
        and sync_task:busy() == true
end

function Gate.capture(document, path, book_id)
    return {
        document = document,
        path = tostring(path or ""),
        book_id = tostring(book_id or ""),
    }
end

function Gate.matches(context, document, path, book_id)
    if type(context) ~= "table" then return false end
    if context.document ~= nil and context.document ~= document then return false end
    if tostring(context.path or "") ~= tostring(path or "") then return false end
    return tostring(context.book_id or "") == tostring(book_id or "")
end

return Gate
