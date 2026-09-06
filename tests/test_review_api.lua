-- Api:review_comments 契约(实施文档 §2):URL/参数/限速作用域/错误短路。

STUBS = STUBS or require("tests.stubs")
-- test_sync_frontend 会注册 api/http 的 preload 桩且先于本文件执行;
-- 这里清掉桩并用真实模块,结束后恢复,避免污染后续测试。
local ORIG_PRELOADS = {
    api = package.preload["pickthought.api"],
    http = package.preload["pickthought.http"],
}
package.preload["pickthought.api"] = nil
package.preload["pickthought.http"] = nil
package.loaded["pickthought.api"] = nil
package.loaded["pickthought.http"] = nil
local Api = require("pickthought.api")

local function new_api(capture)
    local http = {
        get_json = function(_, url, opt)
            capture.url = url
            capture.opt = opt
            return capture.response or { comments = {} }
        end,
    }
    local store = {
        auth = function() return { api_key = "test-key" } end,
    }
    return Api:new(http, store)
end

T.case("review_comments:空 review_id 短路返回失败,不发请求", function()
    local capture = {}
    local api = new_api(capture)
    local result = api:review_comments("", nil)
    T.eq(type(result), "table")
    T.eq(result.ok, false)
    T.eq(result.error, "invalid_review_id")
    T.eq(capture.url, nil, "未发起任何请求")
end)

T.case("review_comments:URL、默认参数与请求选项符合实施文档", function()
    local capture = { response = { comments = {} } }
    local api = new_api(capture)
    local data = api:review_comments("abc123", nil)
    T.eq(data, capture.response, "原始响应 table 原样返回,归一化在 review_comments 完成")
    T.ok(capture.url:find("^https://weread%.qq%.com/web/review/single%?reviewId=abc123&commentsCount=50&commentsDirection=0&likesCount=0&synckey=0$") ~= nil,
        "URL 与默认参数正确")
    local opt = capture.opt
    T.eq(opt.retries, 1)
    T.eq(opt.timeout[1], 8)
    T.eq(opt.timeout[2], 15)
    T.eq(opt.pacing_scope, "review-comments")
    T.eq(opt.min_interval, 0.45)
    T.eq(opt.pacing_jitter, 0.10)
    T.eq(opt.rate_limit_scope, "review-comments")
    T.eq(opt.rate_limit_fail_fast, true, "冷却期 fail-fast,避免阻塞 UI")
    T.ok(opt.headers.Referer:find("^https://weread%.qq%.com/$") ~= nil)
    T.ok(opt.headers.Accept:find("application/json") ~= nil)
end)

T.case("review_comments:comments_count 参数生效", function()
    local capture = {}
    local api = new_api(capture)
    api:review_comments("abc", { comments_count = 10 })
    T.ok(capture.url:find("commentsCount=10", 1, true) ~= nil)
end)

T.case("review_comments:pacing_min_interval 覆盖生效,默认 0.45", function()
    -- 评论数懒加载预取批量传 0.2 压总时长;点击路径不传维持 0.45。
    local capture = {}
    local api = new_api(capture)
    api:review_comments("abc", { pacing_min_interval = 0.2 })
    T.eq(capture.opt.min_interval, 0.2)
    local capture2 = {}
    local api2 = new_api(capture2)
    api2:review_comments("abc", nil)
    T.eq(capture2.opt.min_interval, 0.45)
end)

-- ------------------------------------------------ 续期(2026-09-06 真机回归)

T.case("续期 body 报错也放行重试(修复:长时间休眠后首次请求误报登录过期)", function()
    -- 真机实测:休眠唤醒后 skey 失效,续期接口 body 携带运营提示 errCode
    -- (-2013/-12013)但 Set-Cookie 已轮换出新会话;旧逻辑把 body 报错当成
    -- 续期失败跳过重试,用户看到一次"登录已过期",第二次点击才恢复。
    local state = { calls = 0 }
    local http = {
        get_json = function()
            state.calls = state.calls + 1
            if state.calls == 1 then
                error("登录状态已失效 [撷思Auth] error_code=-2012: 登录超时")
            end
            return { comments = {}, commentsCount = 0 }
        end,
        post_json = function(_, url)
            state.renew_url = url
            error("鉴权失败")  -- body errCode≠0,Http:json 抛错
        end,
    }
    local api = Api:new(http, { auth = function() return { api_key = "k" } end })
    local data = api:review_comments("abc", nil)
    T.eq(data.commentsCount, 0, "续期换到的新会话生效,重试成功")
    T.eq(state.calls, 2, "原请求 + 续期后重试,共两次")
    T.ok(state.renew_url:find("/web/login/renewal", 1, true) ~= nil, "走了续期接口")
end)

T.case("续期传输失败也放行重试,由重试报真实错误", function()
    local http = {
        get_json = function()
            error("登录状态已失效 [撷思Auth] error_code=-2012: 登录超时")
        end,
        post_json = function() error("HTTP transport unavailable: timeout") end,
    }
    local api = Api:new(http, { auth = function() return { api_key = "k" } end })
    local ok, err = pcall(function() return api:review_comments("abc", nil) end)
    T.eq(ok, false)
    T.ok(tostring(err):find("error_code=%-2012") ~= nil,
        "重试的失败原因如实上报,不再被续期失败截胡")
end)

package.preload["pickthought.api"] = ORIG_PRELOADS.api
package.preload["pickthought.http"] = ORIG_PRELOADS.http
package.loaded["pickthought.api"] = nil
package.loaded["pickthought.http"] = nil
