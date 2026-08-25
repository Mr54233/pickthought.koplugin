-- SpineCache 单元测试:冷模式捕获 → 暖模式命中,内容字节一致;指纹变更作废。
-- 用内存 FS 替身临时替换 U 的磁盘函数(测试环境的 lfs 是 no-op,无法真正建目录),
-- 验证完立即还原,不影响其他用例。
local SpineCache = require("pickthought.spine_cache")
local U = require("pickthought.util")

local CH1 = "<html><body><p>春江潮水连海平。</p></body></html>"
local CH2 = "<html><body><p>海上明月共潮生。</p></body></html>"

-- 在内存 FS 替身上运行 fn(fs);fn 内可用 fs 预置/断言;结束后还原 U。
local function with_memfs(fn)
    local saved = {}
    for _, k in ipairs({"mkdir", "read_file", "file_exists", "atomic_write", "remove_tree", "list"}) do
        saved[k] = U[k]
    end
    local fs = {}
    U.mkdir = function(p) fs[tostring(p)] = fs[tostring(p)] or true; return true end
    U.file_exists = function(p) return fs[tostring(p)] ~= nil end
    U.read_file = function(p) local c = fs[tostring(p)]; return c == true and nil or c end
    U.atomic_write = function(p, d) fs[tostring(p)] = d; return true end
    U.remove_tree = function(p)
        local pk = tostring(p)
        for k in pairs(fs) do
            if k == pk or k:sub(1, #pk + 1) == pk .. "/" then fs[k] = nil end
        end
        return true
    end
    U.list = function(p)
        local o = {}; local pre = tostring(p) .. "/"
        for k in pairs(fs) do if k:sub(1, #pre) == pre then o[#o + 1] = k end end
        return o
    end
    local ok, err = xpcall(fn, debug.traceback, fs)
    for k, v in pairs(saved) do U[k] = v end
    if not ok then error(err, 0) end
end

T.case("SpineCache: 冷捕→暖服 内容一致且指纹作废", function()
    with_memfs(function()
        local dir = "tests/.tmp_spine/spine-12345_7"
        local sig = "12345@7"
        local spine = {{href = "OEBPS/c1.xhtml"}, {href = "OEBPS/c2.xhtml"}}

        -- 冷模式:捕获两个 spine 文件
        local cold = SpineCache.open(dir, sig)
        T.ok(cold and not cold:warm(), "冷模式开启")
        cold:put("OEBPS/c1.xhtml", CH1)
        cold:put("OEBPS/c2.xhtml", CH2)
        cold:close()

        -- 暖模式:命中,内容字节一致,covers 全中
        local warm = SpineCache.open(dir, sig)
        T.ok(warm and warm:warm(), "暖模式命中已有缓存")
        T.ok(warm:covers(spine), "covers 覆盖全部 href")
        T.eq(warm:get("OEBPS/c1.xhtml"), CH1, "c1 内容一致")
        T.eq(warm:get("OEBPS/c2.xhtml"), CH2, "c2 内容一致")

        -- 缺 href 的 spine 不应被 covers(暖路径会回退真实读取)
        T.ok(not warm:covers({{href = "OEBPS/missing.xhtml"}}), "缺 href 不 covers")

        -- 指纹变更(换书/升算法)→ 旧缓存整体作废,回到冷模式
        local other = SpineCache.open(dir, "99999@8")
        T.ok(other and not other:warm(), "指纹不符→冷模式重捕")
    end)
end)

T.case("SpineCache: 同长度正文损坏触发回源并可修复", function()
    with_memfs(function(fs)
        local dir = "tests/.tmp_spine/spine-corrupt_7"
        local sig = "12345@7"
        local spine = {{href = "OEBPS/c1.xhtml"}}
        local cold = SpineCache.open(dir, sig)
        cold:put("OEBPS/c1.xhtml", CH1)
        cold:close()
        fs[dir .. "/e1"] = ("X"):rep(#CH1)
        local warm = SpineCache.open(dir, sig)
        T.ok(warm:warm(), "manifest 字段完整时仍进入暖模式")
        T.ok(not warm:covers(spine), "同长度内容损坏必须退出暖路径")
        T.eq(warm:get("OEBPS/c1.xhtml"), nil, "损坏正文不得返回")
        T.ok(warm:put("OEBPS/c1.xhtml", CH1), "回源正文可补写")
        T.ok(warm:close(), "修复后的 manifest 可写入")
        local repaired = SpineCache.open(dir, sig)
        T.ok(repaired:covers(spine), "修复后重新进入暖路径")
        T.eq(repaired:get("OEBPS/c1.xhtml"), CH1, "修复正文内容一致")
    end)
end)

T.case("SpineCache: 旧 manifest 无完整性字段时冷启动重建", function()
    with_memfs(function(fs)
        local dir = "tests/.tmp_spine/spine-legacy_7"
        local sig = "12345@7"
        fs[dir] = true
        fs[dir .. "/manifest.json"] =
            '{"signature":"12345@7","entries":{"OEBPS/c1.xhtml":"e1"}}'
        fs[dir .. "/e1"] = CH1
        local cache = SpineCache.open(dir, sig)
        T.ok(cache and not cache:warm(), "旧 manifest 必须视为冷缓存")
        T.ok(fs[dir .. "/manifest.json"] == nil and fs[dir .. "/e1"] == nil,
            "冷启动应清理旧 manifest 和正文")
    end)
end)

T.case("SpineCache: 缓存缺失 get 返回 nil", function()
    with_memfs(function(fs)
        local dir = "tests/.tmp_spine/spine-miss_7"
        local sig = "12345@7"
        local cold = SpineCache.open(dir, sig)
        cold:put("OEBPS/c1.xhtml", CH1)
        cold:close()
        local warm = SpineCache.open(dir, sig)
        T.eq(warm:get("OEBPS/c2.xhtml"), nil, "未在缓存的 href get 返回 nil")
        T.eq(warm:get("nonexistent"), nil, "完全未知 href get 返回 nil")
        -- 暖模式但请求未在 entries 的 href:covers 必为 false(迫使回退真实读取)
        T.ok(not warm:covers({{href = "OEBPS/c2.xhtml"}}), "含未缓存 href 的 spine 不 covers")
        -- manifest 有记录但实体文件被删时,也必须退出暖路径。
        fs[dir .. "/e1"] = nil
        T.ok(not warm:covers({{href = "OEBPS/c1.xhtml"}}), "缓存文件被删后不应误判 covers")
    end)
end)

T.case("SpineCache: 原子写返回失败不登记映射", function()
    -- 原子写失败时(模拟磁盘满返回 nil),put/close 必须不抛出,且 get 应优雅
    -- 回退 nil(走真实读取补写),绝不污染后续匹配结果。
    with_memfs(function(fs)
        local dir = "tests/.tmp_spine/spine-fail_7"
        local sig = "111@7"
        local sc = SpineCache.open(dir, sig)
        T.ok(sc and not sc:warm(), "冷模式开启(写盘失败路径)")
        local saved_atomic = U.atomic_write
        U.atomic_write = function() return nil, "disk full" end
        local ok_put, err_put = pcall(function() sc:put("OEBPS/c1.xhtml", CH1) end)
        U.atomic_write = saved_atomic
        T.ok(ok_put, "put 在写盘失败时仍不抛错: " .. tostring(err_put))
        T.eq(sc:get("OEBPS/c1.xhtml"), nil, "get 写盘失败内容返回 nil(回退真实读取)")
        local ok_close = pcall(sc.close, sc)
        T.ok(ok_close, "close 在写盘失败时仍不抛错")
        T.ok(not fs[dir .. "/manifest.json"], "写盘失败不得生成 manifest")
    end)
end)

T.case("SpineCache: 暖模式缺文件可修复并更新 manifest", function()
    with_memfs(function(fs)
        local dir = "tests/.tmp_spine/spine-repair_7"
        local sig = "12345@7"
        local cold = SpineCache.open(dir, sig)
        cold:put("OEBPS/c1.xhtml", CH1)
        cold:put("OEBPS/c2.xhtml", CH2)
        cold:close()
        fs[dir .. "/e1"] = nil

        local warm = SpineCache.open(dir, sig)
        T.ok(warm and warm:warm(), "manifest 存在时仍进入暖模式")
        T.ok(not warm:covers({{href = "OEBPS/c1.xhtml"}, {href = "OEBPS/c2.xhtml"}}),
            "缺文件触发回源路径")
        T.ok(warm:put("OEBPS/c1.xhtml", CH1), "缺失文件可回源补写")
        T.ok(warm:put("OEBPS/c3.xhtml", "第三章"), "暖模式可追加新文件")
        T.ok(warm:close(), "修复后的 manifest 写入成功")

        local repaired = SpineCache.open(dir, sig)
        T.ok(repaired:warm(), "修复后仍可暖启动")
        T.ok(repaired:covers({
            {href = "OEBPS/c1.xhtml"}, {href = "OEBPS/c2.xhtml"}, {href = "OEBPS/c3.xhtml"},
        }), "修复后的三条缓存均有效")
        T.eq(repaired:get("OEBPS/c1.xhtml"), CH1, "c1 修复内容一致")
        T.eq(repaired:get("OEBPS/c3.xhtml"), "第三章", "新增 c3 内容一致")
    end)
end)

T.case("SpineCache: 中断残留缓存被清并重捕", function()
    with_memfs(function(fs)
        local dir = "tests/.tmp_spine/spine-interrupt_7"
        local sig = "12345@7"
        -- 预置「中断残留」:目录存在但无 manifest,仅一个半截文件。
        fs[dir] = true
        fs[dir .. "/e1"] = "<html partial"
        -- open:无 manifest → cold,且清空残留目录。
        local sc = SpineCache.open(dir, sig)
        T.ok(sc and not sc:warm(), "无 manifest 的残留目录→冷模式重捕")
        T.ok(fs[dir .. "/e1"] == nil, "残留半截文件被清理")
        -- 重捕应能正常写入并在下一轮暖命中。
        sc:put("OEBPS/c1.xhtml", CH1)
        sc:close()
        local warm = SpineCache.open(dir, sig)
        T.ok(warm and warm:warm(), "重捕后暖命中")
        T.eq(warm:get("OEBPS/c1.xhtml"), CH1, "重捕内容一致")
    end)
end)
