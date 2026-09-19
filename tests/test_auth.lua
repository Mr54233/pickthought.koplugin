-- Auth 登录链路单元测试(上游四项移植 R2)。
-- _poll 的 URL 构造是纯字符串拼接,用桩 http 捕获 URL 断言形式,
-- 不触网、不碰真实 Cookie jar 状态。
-- auth.lua 顶部 require 多个 KOReader 模块,先预载最小桩再加载被测模块。
package.preload["device"] = package.preload["device"] or function()
    return {isKindle = function() return false end, screen = {scaleBySize = function(n) return n end}}
end
package.preload["ui/widget/qrmessage"] = package.preload["ui/widget/qrmessage"] or function()
    return {new = function() return {} end}
end
package.preload["ui/widget/buttondialog"] = package.preload["ui/widget/buttondialog"] or function()
    return {new = function() return {} end}
end
package.preload["ui/widget/inputdialog"] = package.preload["ui/widget/inputdialog"] or function()
    return {new = function() return {} end}
end
package.preload["ui/uimanager"] = package.preload["ui/uimanager"] or function()
    return {close = function() end, show = function() end, scheduleIn = function() end,
        unschedule = function() end, setDirty = function() end}
end
local Auth = require("pickthought.auth")

T.case("R1: 自动更新间隔为 1 小时(上游 v1.5.0 对齐)", function()
    -- 直接读源码断言,不吃模块缓存:test_thought_popup_config 会给
    -- pickthought.config 装部分桩(无 AUTO_UPDATE_INTERVAL),套件内
    -- require 到的是桩而非真实配置。
    local fh = io.open("pickthought.koplugin/pickthought/config.lua", "r")
    T.ok(fh ~= nil, "config.lua 可读")
    local src = fh:read("*a")
    fh:close()
    T.ok(src:find("AUTO_UPDATE_INTERVAL = 60 %* 60", 1, false), "间隔 24h → 1h")
    T.ok(src:find("AUTO_UPDATE_RETRY_INTERVAL = 6 %* 60 %* 60", 1, false), "失败重试间隔保持 6h")
end)

local function poll_with(otp)
    local captured
    local stub = {
        http = {
            get_json = function(_, url)
                captured = url
                return {statusCode = -1}, {}
            end,
        },
        jar = {},
    }
    -- 只借用 _poll 的 URL 构造;Cookie.header 在 jar 为空表时返回空串。
    local auth = setmetatable({}, {__index = Auth})
    auth.http = stub.http
    auth.jar = {}
    local ok, err = pcall(function() return Auth._poll(auth, "uid 1", otp) end)
    -- 响应是桩,-1 会走错误路径;URL 已捕获即可。
    T.ok(captured ~= nil, "URL 已捕获: " .. tostring(err))
    return captured
end

T.case("R2: OTP 空值为 nil 时 URL 以 &otp= 结尾", function()
    local url = poll_with(nil)
    T.ok(url:find("&otp=$"), "空值带等号: " .. tostring(url))
    T.ok(url:find("uid=", 1, true), "uid 参与拼接")
end)

T.case("R2: OTP 空串等价 nil,同样 &otp= 结尾", function()
    local url = poll_with("")
    T.ok(url:find("&otp=$"), "空串同裸等号: " .. tostring(url))
end)

T.case("R2: OTP 有值时 &otp=<转义值>", function()
    local url = poll_with("1234")
    T.ok(url:find("&otp=1234$"), "有值拼接: " .. tostring(url))
end)

T.case("R2: uid 经过转义(空格 → %20)", function()
    local url = poll_with(nil)
    T.ok(url:find("uid%%20", 1, false), "uid 转义生效: " .. tostring(url))
end)

