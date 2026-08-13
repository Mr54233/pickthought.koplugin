-- spine 正文(原始 HTML)持久化缓存。
--
-- 背景:分批同步时,每批只要还有没见过的新章节(todo>0),map 阶段就必须
-- 把整本书的 spine 文件逐一读一遍,才能给新章节的引文定位(引文可能落在
-- 任何文件里)。原实现每批都从 EPUB 把每个 spine 文件解压进内存再 normalize,
-- 慢书 + 低性能设备(FAT32 SD、256MB RAM)上反复解压很费时。
--
-- 本缓存把每个 spine 文件的原始 HTML 落盘(与 map.json 同目录),第 2 批起
-- 直接读缓存文本喂给 ChapterMap,map 阶段不再解压原 EPUB、不再重复 normalize,
-- 大幅提速。代价:多占 ≈ 书大小 的磁盘(随「重置本书」一并清理)。
--
-- 红线安全:缓存的正是 read_text 的原始输出,ChapterMap 照常 normalize
-- (normalize 幂等),匹配结果与最终注入的 EPUB 字节完全一致;不触碰任何
-- 匹配逻辑,也不需要改动 ALGO_VERSION。缓存指纹与 map.json 同源(源书大小 @
-- 算法版本),换书或升算法自动整体作废。
local U = require("pickthought.util")
local Json = require("pickthought.json")

local SpineCache = {}

local function next_entry_seq(entries)
    local max_seq = 0
    for _, fname in pairs(entries or {}) do
        local seq = tostring(fname):match("^e(%d+)$")
        if seq then max_seq = math.max(max_seq, tonumber(seq) or 0) end
    end
    return max_seq + 1
end

-- 指纹形如 "123456@7",目录名里 "@" 换成 "_" 以免歧义。
local function sig_to_dir(signature)
    return "spine-" .. tostring(signature):gsub("@", "_")
end

-- 由 map.json 路径推导 spine 缓存目录(同目录下的 spine-<指纹> 子目录)。
-- 无 map_cache_path 时返回 nil(调用方未开启缓存)。
function SpineCache.dir_for(map_cache_path, signature)
    if not map_cache_path or not signature then return nil end
    local base = map_cache_path:match("^(.*)/[^/]+$")
    if not base or base == "" then base = map_cache_path:match("^(.*)\\[^\\]+$") end
    if not base or base == "" then base = "." end
    return base .. "/" .. sig_to_dir(signature)
end

-- 打开缓存:命中(指纹匹配 + manifest 存在)则 warm 模式直接服务;
-- 否则 cold 模式,首次 put 时建目录并捕获。dir 为 nil 时返回 nil(缓存禁用)。
function SpineCache.open(dir, signature)
    if not dir then return nil end
    local self = {
        dir = dir,
        signature = signature,
        mode = "cold",
        entries = {},
        _seq = 1,
        dir_ready = false,
        dirty = false,
    }
    setmetatable(self, { __index = SpineCache })

    -- 清理同目录下旧指纹遗留的 cache 目录(换书/升算法后旧目录失效,省磁盘)。
    local parent = dir:match("^(.*)/[^/]+$")
    if parent and parent ~= "" then
        local self_name = dir:match("/([^/]+)$")
        for _, f in ipairs(U.list(parent)) do
            local name = f:match("/([^/]+)$") or f
            if name:find("^spine%-") and name ~= self_name then
                pcall(U.remove_tree, f)
            end
        end
    end

    local manifest_path = dir .. "/manifest.json"
    if U.file_exists(manifest_path) then
        local raw = U.read_file(manifest_path, true)
        if raw then
            local ok, decoded = pcall(Json.decode, raw)
            if ok and type(decoded) == "table"
                and tostring(decoded.signature) == tostring(signature)
                and type(decoded.entries) == "table" then
                self.entries = decoded.entries
                self._seq = next_entry_seq(self.entries)
                self.mode = "warm"
            end
        end
    end
    if self.mode == "cold" then
        -- 清空任何上次中断留下的残缺缓存,从头捕获。
        pcall(U.remove_tree, dir)
        self.entries = {}
    end
    return self
end

function SpineCache:warm()
    return self.mode == "warm"
end

-- 当前 spine 全部 href 是否都已在缓存里(用于决定是否敢在 read_spine 走暖路径)。
function SpineCache:covers(spine)
    if self.mode ~= "warm" then return false end
    for _, item in ipairs(spine or {}) do
        local href = type(item) == "table" and item.href or tostring(item)
        local fname = self.entries[tostring(href)]
        if not fname or not U.file_exists(self.dir .. "/" .. tostring(fname)) then return false end
    end
    return true
end

-- 取缓存正文;缺失返回 nil(调用方据此回退真实读取并补写)。
function SpineCache:get(href)
    if self.mode ~= "warm" then return nil end
    local fname = self.entries[tostring(href)]
    if not fname then return nil end
    local data = U.read_file(self.dir .. "/" .. fname, true)
    if data == nil then return nil end
    return data
end

-- 写入一个 spine 文件的原始 HTML。content 为 nil 时忽略(读取失败不缓存)。
-- 文件名用单调序号 e1/e2/...,href 与文件名的映射记在 entries 里,永不撞名。
function SpineCache:put(href, content)
    if content == nil then return false end
    href = tostring(href)
    local fname = self.entries[href]
    local new_entry = false
    if not fname then
        fname = "e" .. tostring(self._seq)
        self._seq = self._seq + 1
        new_entry = true
    end
    if not self.dir_ready then
        local dir_ok = U.mkdir(self.dir)
        if not dir_ok and not U.file_exists(self.dir) then return false end
        self.dir_ready = true
    end
    local ok, wrote = pcall(U.atomic_write, self.dir .. "/" .. fname, content, true)
    if ok and wrote == true then
        if new_entry then self.entries[href] = fname end
        self.dirty = true
        return true
    end
    return false
end

-- 写入 manifest,供后续批次暖启动。暖模式发现缓存文件缺失时,回源补写后
-- 也必须把修复后的映射落盘。
function SpineCache:_write_manifest()
    if not self.dirty or not self.dir_ready then return false end
    local count = 0
    for _ in pairs(self.entries) do count = count + 1 end
    local manifest = { signature = self.signature, count = count, entries = self.entries }
    local ok, encoded = pcall(Json.encode, manifest)
    if not ok then return false end
    local wrote_ok, wrote = pcall(U.atomic_write, self.dir .. "/manifest.json", encoded, true)
    if not (wrote_ok and wrote == true) then return false end
    self.dirty = false
    return true
end

function SpineCache:close()
    return self:_write_manifest()
end

return SpineCache
