-- SpineCache 单元测试:冷模式捕获 → 暖模式命中,内容字节一致;指纹变更作废。
-- 用内存 FS 替身临时替换 U 的磁盘函数(测试环境的 lfs 是 no-op,无法真正建目录),
-- 验证完立即还原,不影响其他用例。
local SpineCache = require("pickthought.spine_cache")
local U = require("pickthought.util")

local CH1 = "<html><body><p>春江潮水连海平。</p></body></html>"
local CH2 = "<html><body><p>海上明月共潮生。</p></body></html>"

T.case("SpineCache: 冷捕→暖服 内容一致且指纹作废", function()
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

    for k, v in pairs(saved) do U[k] = v end
end)
