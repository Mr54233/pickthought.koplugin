-- 续期冷静期单元测试(真机 2026-10-07:网页登录失效后,评论/划线每个
-- 请求都阻塞一轮续期交换 5~9s×2 重试,前台弹窗长时间无法打断)。
-- _web_call 的 auth 失败路径:首次尝试续期;交换失败或重试仍 401 进入
-- 5 分钟冷静期;冷静期内后续 auth 失败快速短路,不再发起续期交换。
-- 必须清掉先前测试装上的 api/http preload 桩,加载真实模块
-- (同 test_review_api 的做法);结束恢复,避免污染后续测试。
local ORIG_PRELOADS = {
    api = package.preload["pickthought.api"],
    http = package.preload["pickthought.http"],
}
package.preload["pickthought.api"] = nil
package.preload["pickthought.http"] = nil
package.loaded["pickthought.api"] = nil
package.loaded["pickthought.http"] = nil
local Api = require("pickthought.api")
local REAL_LOADED = {
    api = package.loaded["pickthought.api"],
    http = package.loaded["pickthought.http"],
}

local function new_api(http)
    return Api:new(http, {auth = function() return {api_key = "k"} end}, nil)
end

T.case("冷静期: 续期交换失败后,后续请求快速失败不再发起续期交换", function()
    local renew_attempts, fn_calls = 0, 0
    local api = new_api({
        post_json = function()
            renew_attempts = renew_attempts + 1
            error("HTTP 401, body_bytes=0 [撷思Auth] error_code=-2012", 0)
        end,
    })
    local function web_fn()
        fn_calls = fn_calls + 1
        error("登录状态已失效 [撷思Auth] error_code=-2012", 0)
    end
    -- 第一轮:auth 失败 → 续期交换 1 次 → 重试仍失败 → 进入冷静期
    local ok1, err1 = pcall(function() return api:_web_call(web_fn) end)
    T.ok(not ok1, "首轮失败")
    T.eq(renew_attempts, 1, "首轮发起 1 次续期交换")
    -- 第二轮:冷静期内,不再发起续期交换
    local ok2, err2 = pcall(function() return api:_web_call(web_fn) end)
    T.ok(not ok2, "冷静期内仍快速失败")
    T.eq(renew_attempts, 1, "冷静期内续期交换次数不增加")
    T.eq(fn_calls, 3, "web_fn 首轮 2 次+冷静期 1 次")
    T.ok(tostring(err2):find("重新扫码登录", 1, true), "错误提示重新扫码登录")
end)

T.case("冷静期是实例状态:新 Api 实例不受污染", function()
    local renew_attempts = 0
    local server_rejects = true
    local fresh = new_api({
        -- 续期交换成功 = 服务端已轮换会话:副作用解除"服务器拒绝"状态
        post_json = function()
            renew_attempts = renew_attempts + 1
            server_rejects = false
            return true
        end,
    })
    local function web_fn()
        if server_rejects then error("登录状态已失效 [撷思Auth] error_code=-2012", 0) end
        return "ok"
    end
    -- 首次:auth 失败 → 续期(成功并解除拒绝态) → 重试通过;不设冷静期
    local ok1, r1 = pcall(function() return fresh:_web_call(web_fn) end)
    T.ok(ok1, "续期成功后重试通过: " .. tostring(r1))
    T.eq(renew_attempts, 1, "发起过一次续期交换")
    T.eq(fresh._renew_fail_until, nil, "成功路径不设冷静期")
end)

-- 恢复真实 api/http 模块(本文件加载的是清桩后的真实实现,
-- 需在套件收尾前还原 preload/loaded,防桩残留污染后续测试文件)。
package.preload["pickthought.api"] = ORIG_PRELOADS.api
package.preload["pickthought.http"] = ORIG_PRELOADS.http
package.loaded["pickthought.api"] = REAL_LOADED.api
package.loaded["pickthought.http"] = REAL_LOADED.http
