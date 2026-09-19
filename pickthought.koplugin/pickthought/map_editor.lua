-- 章节映射手动指认(上游 v1.5.1「章节对应管理」的撷思最小闭环适配)。
-- 纯逻辑模块:读写 map.json 的单章条目,UI 在 main.lua 用 Menu 组装。
-- 手动条目 manual=true:sync.lua 加载时直接复用不进自动 todo,写入段
-- 不覆写 manual 条目(自动定案跳过已手动指认的章)。
local logger = require("logger")
local Json = require("pickthought.json")
local U = require("pickthought.util")

local MapEditor = {}

local function load_cache(cache_path)
    local raw = U.read_file(cache_path, true)
    if not raw then return nil, "映射缓存不存在,先执行一次同步" end
    local ok, decoded = pcall(Json.decode, raw)
    if not ok or type(decoded) ~= "table" or type(decoded.map) ~= "table" then
        return nil, "映射缓存无法解析"
    end
    return decoded
end

local function save_cache(cache_path, decoded)
    local ok_encode, encoded = pcall(Json.encode, decoded)
    if not ok_encode then return nil, "映射缓存序列化失败" end
    local written = U.atomic_write(cache_path, encoded, true)
    if not written then return nil, "映射缓存写入失败" end
    return true
end

-- 列表:缓存条目 + 当前批次章节,按 manual/miss/auto 分组返回展示行。
-- chapters 来自本地断点缓存的章名列表(由调用方从 sync-cache 目录构建)。
function MapEditor.list(cache_path, chapters)
    local decoded, err = load_cache(cache_path)
    if not decoded then return nil, err end
    local rows = {manual = {}, miss = {}, auto = {}}
    for _, ch in ipairs(chapters or {}) do
        local uid = tostring(ch.uid or "")
        local entry = decoded.map[uid]
        local row = {uid = uid, title = tostring(ch.title or "")}
        if type(entry) == "table" and entry.manual and type(entry.hrefs) == "table" then
            row.status = "manual"
            row.href = tostring(entry.hrefs[1] or "")
            rows.manual[#rows.manual + 1] = row
        elseif type(entry) == "table" and type(entry.hrefs) == "table" and #entry.hrefs > 0 then
            row.status = "auto"
            row.href = tostring(entry.hrefs[1] or "")
            rows.auto[#rows.auto + 1] = row
        else
            row.status = "miss"
            rows.miss[#rows.miss + 1] = row
        end
    end
    return rows
end

-- 指认:覆写单章条目为 manual。href 必须在 spine 内,spine 由调用方传入
-- (map_editor 不读 EPUB,保持纯逻辑可测)。
function MapEditor.assign(cache_path, uid, href, spine, algo_version)
    uid, href = tostring(uid or ""), tostring(href or "")
    if uid == "" then return nil, "章节标识缺失" end
    local decoded, err = load_cache(cache_path)
    if not decoded then return nil, err end
    local spine_ok = false
    for _, item in ipairs(spine or {}) do
        if tostring(item.href or item) == href then spine_ok = true break end
    end
    if not spine_ok then return nil, "目标文件不在本书 spine 内" end
    decoded.map[uid] = {hrefs = {href}, manual = true,
        algo = algo_version or 0}
    local saved, save_err = save_cache(cache_path, decoded)
    if not saved then return nil, save_err end
    logger.info("[撷思][MapEditor] assigned uid=", uid, "href=", href)
    return true
end

-- 清除指认:删除条目,下一批走自动匹配。
function MapEditor.clear(cache_path, uid)
    uid = tostring(uid or "")
    local decoded, err = load_cache(cache_path)
    if not decoded then return nil, err end
    if decoded.map[uid] then
        decoded.map[uid] = nil
        local saved, save_err = save_cache(cache_path, decoded)
        if not saved then return nil, save_err end
        logger.info("[撷思][MapEditor] cleared uid=", uid)
    end
    return true
end

return MapEditor
