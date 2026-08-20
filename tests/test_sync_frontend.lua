-- 作者 #17 收尾复核(2026-08-18):前台禁用阻塞式 usleep 的集成测试。
-- 此前测试手动构造 no-op PerformanceMode 后直接喂给 inject_copy,并未真正走
-- main.lua:_sync_run 适配器,故无法锁定「前台适配器确实传入 no-op rest」。
-- 本测试改为:加载真实 main.lua,构造最小 Plugin 环境,直接调用 _sync_run,
-- 让真实的注入适配器把 perf 透传给 inject_copy;同时桩一个会记录调用的
-- ffi/util.usleep(模拟真实设备),断言前台路径下 usleep 调用次数为 0。
-- 并以「默认 rest(ffi/util.usleep 存在)确实会触发 usleep」做对照,证明 spy 有效。

local usleep_spy = { calls = 0 }

-- 桩掉 KOReader 专属模块,使 pickthought.main 可在桌面 LuaJIT 环境加载。
-- 需要特殊行为的两个:WidgetContainer:extend 仅返回表;ui/trapper 的 info/clear 被 _sync_run 调用。
package.preload["ui/widget/container/widgetcontainer"] = function()
    return { extend = function(_, t) return t end }
end
package.preload["ui/trapper"] = function()
    return { info = function() return true end, clear = function() end }
end
-- 模拟真实设备存在 ffi/util.usleep:默认 rest 会真正 sleep 阻塞前台协程。
package.preload["ffi/util"] = function()
    return { gettime = function() return 1700000000, 0 end,
        usleep = function() usleep_spy.calls = usleep_spy.calls + 1 end }
end
-- 其余 KOReader 模块(ui/*、apps/*、device、dispatcher、libs/*)统一桩为占位表,
-- 避免逐个枚举遗漏(如 ui/widget/qrmessage 等)。
table.insert(package.loaders, function(modname)
    if modname:match("^ui/") or modname:match("^apps/") or modname:match("^ffi/")
        or modname == "device" or modname == "dispatcher"
        or modname:match("^libs/") then
        -- 类桩:KOReader 模块普遍以 SomeBase:extend{...} 定义类,故需提供 extend。
        return function() return { extend = function(_, t) return t end } end
    end
    return nil
end)

-- 桩掉 _sync_run 依赖的 pickthought 模块(避免真实 EPUB/网络/DB IO):
-- 这些仅在 _sync_run 内部被 require,且需捕获其传入的 perf。
package.preload["pickthought.thoughts"] = function()
    return {
        save = function(_, _, _, groups) return #(groups or {}) end,
        merge = function() return true end,
        close_book = function() end,
    }
end
package.preload["pickthought.web_fetch"] = function()
    return { new = function()
        return { fetch_chapter = function(_, book_id, uid)
            -- 至少返回一条划线 + 想法,使 Sync.run 越过「没有划线」闸门、走到 inject。
            return {
                underlines = { { range = "0-7", markText = "春江潮水连海平" } },
                review_map = { ["0-7"] = { { content = "好句", author = "甲" } } },
                review_groups = { { range = "0-7", texts = { { content = "好句", author = "甲" } } } },
                underline_count = 1, thought_count = 1, thought_entry_count = 1, errors = {},
            }
        end }
    end }
end
package.preload["pickthought.epub_reader"] = function()
    return {
        load = function() return { spine = { { href = "OEBPS/c1.xhtml" } }, has = {} } end,
        -- 章节正文须包含划线的 markText,否则章节匹配失败(Sync.run 在注入前即中止)。
        read = function(_, href)
            return "<html><body><p>春江潮水连海平,海上明月共潮生。</p></body></html>"
        end,
        -- each_spine 须回传 (item, content, err, index):真实实现把章节 HTML 作为
        -- 第 2 个参数喂给 callback(见 epub_reader.lua:156),ChapterMap 靠它做引文投票;
        -- 只传 item 会让 content 为 nil,章节匹配彻底失败。
        each_spine = function(_, cb)
            cb({ href = "OEBPS/c1.xhtml" },
                "<html><body><p>春江潮水连海平,海上明月共潮生。</p></body></html>")
            return true
        end,
    }
end
-- inject 适配器桩:记录 _sync_run 实际透传的 perf,不做真实文件 IO。
local captured = { inject_called = false, perf = nil }
package.preload["pickthought.epub_inject"] = function()
    return { inject_copy = function(_, _, mapped, options)
        captured.inject_called = true
        captured.perf = options and options.perf
        return { injected = #(mapped or {}), marks = 0, unmatched = {}, dropped = 0 }
    end }
end
for _, m in ipairs({ "pickthought.thoughts", "pickthought.web_fetch",
    "pickthought.epub_reader", "pickthought.epub_inject" }) do
    package.loaded[m] = nil  -- 确保 _sync_run 的懒加载拿到桩而非缓存
end

-- 加载真实 main.lua(返回 Plugin 类),不进 require 缓存名冲突。
local chunk = assert(loadfile("pickthought.koplugin/main.lua"))
local Plugin = chunk()

T.case("前台 _sync_run 适配器透传 no-op rest,绝不调用 usleep(作者 #17 收尾复核)", function()
    usleep_spy.calls = 0
    captured.inject_called = false
    captured.perf = nil

    -- 最小 Plugin 环境:_sync_run 只用 self.api / self.store / _sync_fail / _sync_report。
    local self = {}
    function self:_sync_fail(msg) self.fail_msg = msg end
    function self:_sync_report(r) self.report = r end
    self.api = { chapters = function()
        return { data = { { chapterUid = 1, title = "第一章", chapterIdx = 1 } } }
    end }
    self.store = {
        book_dir = function() return "/tmp/pt_fake_bookdir" end,
        preferences = function() return {} end,
    }

    -- 关键:走真实 _sync_run 适配器(而非手动构造 perf)。
    Plugin._sync_run(self, "/tmp/书.epub", { book_id = "b001" })

    T.ok(captured.inject_called, "前台 _sync_run 应调用 inject 适配器")
    T.ok(captured.perf ~= nil, "_sync_run 应为 inject 传入 perf")
    -- 即使真实设备存在 ffi/util.usleep,前台 no-op rest 也不得触发它(否则阻塞 UI 主线程)。
    T.eq(usleep_spy.calls, 0, "前台 _sync_run 不得调用 usleep(阻塞 UI 主线程)")

    -- 直接调用传入的 perf._rest 也应是非阻塞 no-op(前台路径的保证本体)。
    if captured.perf and captured.perf._rest then captured.perf._rest() end
    T.eq(usleep_spy.calls, 0, "前台 perf._rest 为 no-op(非阻塞)")

    -- 对照:默认 rest(ffi/util.usleep 存在)确实会触发 usleep —— 证明 spy 有效、
    -- 且子进程 worker 路径仍用 usleep 让出 CPU(前台必须避免这条路径)。
    usleep_spy.calls = 0
    local PerformanceMode = require("pickthought.performance_mode")
    PerformanceMode.default()._rest()
    T.ok(usleep_spy.calls > 0, "对照:默认 rest(ffi/util.usleep 存在)应触发 usleep(前台必须避免此路径)")
end)
