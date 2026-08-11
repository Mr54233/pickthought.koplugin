-- EPUB 元数据读取:ffi/archiver (libarchive) 之上解析 container.xml → OPF → spine。
-- 要求 KOReader >= v2026.03;详见 docs/task3-zip-feasibility.md。
-- 注意:真实 Archiver.Reader 的 seek/extractToMemory 只认迭代过程中建立的条目索引,
-- 任何提取前必须先 iterate 经过目标条目。
local E = {}

local function get_archiver(archiver)
    if archiver then return archiver end
    local ok, mod = pcall(require, "ffi/archiver")
    if not ok then return nil, "需要 KOReader v2026.03 或更新版本(缺少 ffi/archiver)" end
    return mod
end

function E.available()
    local mod, err = get_archiver(nil)
    return mod ~= nil, err
end

local XML_ENTITIES = {amp = "&", lt = "<", gt = ">", quot = '"', apos = "'"}

-- OPF/container 里的 href 是 XML 属性 + URI:先解 XML 实体,再解 %xx。
-- URI 路径中的 + 是字面量,不能按表单编码转空格。
local function decode_href(value)
    value = tostring(value or "")
    value = value:gsub("&#[xX]?(%x+);", function(hex)
        local code = tonumber(hex, 16) or tonumber(hex, 10)
        return (code and code < 0x80) and string.char(code) or ""
    end)
    value = value:gsub("&(%a+);", function(name) return XML_ENTITIES[name] or ("&" .. name .. ";") end)
    value = value:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end)
    return value
end

function E.resolve(base_dir, href)
    local raw = decode_href(href)
    raw = raw:gsub("^/+", "")
    local joined = (tostring(base_dir or "") ~= "" and not tostring(href or ""):match("^/"))
        and (base_dir .. "/" .. raw) or raw
    local parts = {}
    for seg in joined:gmatch("[^/]+") do
        if seg == ".." then
            if #parts > 0 then table.remove(parts) end
        elseif seg ~= "." then
            parts[#parts + 1] = seg
        end
    end
    return table.concat(parts, "/")
end

local function attr(tag, name)
    return tag:match(name .. '%s*=%s*"([^"]*)"') or tag:match(name .. "%s*=%s*'([^']*)'")
end

-- 老工具链会给 OPF/OCF 元素绑定命名空间前缀(<opf:item>、<odc:rootfile>),
-- 解析前统一剥掉元素名前缀;仅用于匹配,不回写。
local function strip_ns_prefix(xml)
    return (tostring(xml or ""):gsub("<(%/?)[%w_%-]+:", "<%1"))
end

local function open_reader(path, archiver)
    local mod, err = get_archiver(archiver)
    if not mod then return nil, err end
    local reader = mod.Reader:new()
    if not reader:open(path) then return nil, "无法打开 EPUB:" .. tostring(path) end
    return reader
end

function E.load(path, archiver)
    local reader, err = open_reader(path, archiver)
    if not reader then return nil, err end
    local names, has = {}, {}
    for entry in reader:iterate() do
        if entry.mode == "file" and not has[entry.path] then
            names[#names + 1] = entry.path
            has[entry.path] = true
        end
    end
    local container = has["META-INF/container.xml"] and reader:extractToMemory("META-INF/container.xml")
    if not container then
        reader:close()
        return nil, "EPUB 缺少 META-INF/container.xml,不是有效的 EPUB"
    end
    local rootfile = strip_ns_prefix(container):match("<rootfile%s[^>]*>") or ""
    local opf_path = attr(rootfile, "full%-path")
    opf_path = opf_path and E.resolve("", opf_path) or nil
    if not opf_path or not has[opf_path] then
        reader:close()
        return nil, "EPUB 的 container.xml 未指向有效 OPF"
    end
    local opf = reader:extractToMemory(opf_path)
    reader:close()
    if not opf then return nil, "无法读取 OPF:" .. opf_path end

    local opf_dir = opf_path:match("^(.*)/[^/]+$") or ""
    local scan = strip_ns_prefix(opf)
    local manifest = {}
    for tag in scan:gmatch("<item[%s/][^>]*>") do
        local id = attr(tag, "id")
        local href = attr(tag, "href")
        if id and href then
            manifest[id] = {href = E.resolve(opf_dir, href), media_type = attr(tag, "media%-type") or ""}
        end
    end
    local spine = {}
    for tag in scan:gmatch("<itemref[%s/][^>]*>") do
        local idref = attr(tag, "idref")
        local item = idref and manifest[idref]
        if item then
            spine[#spine + 1] = {idref = idref, href = item.href, media_type = item.media_type}
        end
    end
    if #spine == 0 then return nil, "OPF 中没有可用的 spine 章节" end
    return {path = path, names = names, has = has, opf_path = opf_path, opf_dir = opf_dir, spine = spine}
end

-- 一次性读取:新开 Reader 迭代到目标条目再提取(seek 只认已迭代的条目)。
function E.read(meta, name, archiver)
    local reader, err = open_reader(meta.path, archiver)
    if not reader then return nil, err end
    local content
    for entry in reader:iterate() do
        if entry.path == name then
            content = reader:extractToMemory(name)
            break
        end
    end
    local read_err = reader.err
    reader:close()
    if content == nil then
        return nil, "无法读取 EPUB 条目:" .. tostring(name) .. (read_err and("(" .. read_err .. ")") or "")
    end
    return content
end

-- 单次打开顺序读取全部 spine 正文。回调参数为(item, content, err, spine_index)；
-- ZIP 条目顺序可以与 OPF spine 不同，spine_index 供上层恢复书序。
function E.each_spine(meta, callback, archiver)
    local reader, err = open_reader(meta.path, archiver)
    if not reader then return nil, err end
    local wanted = {}
    for index, item in ipairs(meta.spine or {}) do
        local rows = wanted[item.href]
        if not rows then rows = {}; wanted[item.href] = rows end
        rows[#rows + 1] = {index = index, item = item}
    end
    local seen = {}
    local ok, scan_err = xpcall(function()
        for entry in reader:iterate() do
            local rows = not seen[entry.path] and wanted[entry.path] or nil
            if entry.mode == "file" and rows then
                seen[entry.path] = true
                local content = reader:extractToMemory(entry.path)
                local read_err = content == nil and (reader.err or
                    ("无法读取 EPUB 条目:" .. tostring(entry.path))) or nil
                for _, row in ipairs(rows) do
                    callback(row.item, content, read_err, row.index)
                end
            end
        end
        for href, rows in pairs(wanted) do
            if not seen[href] then
                for _, row in ipairs(rows) do
                    callback(row.item, nil, "EPUB 中缺少 spine 条目:" .. tostring(href), row.index)
                end
            end
        end
    end, debug.traceback)
    reader:close()
    if not ok then error(scan_err) end
    return true
end

return E
