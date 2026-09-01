-- 桌面(LuaJIT)测试环境:stub 掉 KOReader 专属模块,mock ffi/archiver。
-- 用法:tests/run.lua 最先 require 本文件。
local M = {}

package.path = "pickthought.koplugin/?.lua;" .. package.path

package.preload["logger"] = function()
    local function noop() end
    return {dbg = noop, info = noop, warn = noop, err = noop}
end

-- 最小 JSON 引擎,满足 pickthought.json 的 encode/decode 需求(测试数据范围内)。
package.preload["json"] = function()
    local J = {}
    local ESC = {['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f",
        ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t"}
    local function is_array(t)
        local n = 0
        for k in pairs(t) do
            if type(k) ~= "number" then return false end
            n = n + 1
        end
        return n == #t
    end
    function J.encode(v)
        local kind = type(v)
        if v == nil then return "null" end
        if kind == "boolean" or kind == "number" then return tostring(v) end
        if kind == "string" then
            return '"' .. v:gsub('[%z\1-\31"\\]', function(c)
                return ESC[c] or string.format("\\u%04x", c:byte())
            end) .. '"'
        end
        if kind == "table" then
            local out = {}
            if is_array(v) then
                for _, item in ipairs(v) do out[#out + 1] = J.encode(item) end
                return "[" .. table.concat(out, ",") .. "]"
            end
            for k, item in pairs(v) do
                out[#out + 1] = J.encode(tostring(k)) .. ":" .. J.encode(item)
            end
            return "{" .. table.concat(out, ",") .. "}"
        end
        error("无法编码类型:" .. kind)
    end
    function J.decode(text)
        local pos = 1
        local function skip()
            local _, e = text:find("^[ \t\r\n]*", pos)
            pos = e + 1
        end
        local parse_value
        local function parse_string()
            local out = {}
            pos = pos + 1
            while true do
                local c = text:sub(pos, pos)
                if c == "" then error("字符串未闭合") end
                if c == '"' then pos = pos + 1; return table.concat(out) end
                if c == "\\" then
                    local n = text:sub(pos + 1, pos + 1)
                    local map = {b = "\b", f = "\f", n = "\n", r = "\r", t = "\t"}
                    if n == "u" then
                        local hex = text:sub(pos + 2, pos + 5)
                        local cp = tonumber(hex, 16) or 0
                        out[#out + 1] = cp < 0x80 and string.char(cp) or "?"
                        pos = pos + 6
                    else
                        out[#out + 1] = map[n] or n
                        pos = pos + 2
                    end
                else
                    out[#out + 1] = c
                    pos = pos + 1
                end
            end
        end
        parse_value = function()
            skip()
            local c = text:sub(pos, pos)
            if c == '"' then return parse_string() end
            if c == "{" then
                pos = pos + 1
                local obj = {}
                skip()
                if text:sub(pos, pos) == "}" then pos = pos + 1; return obj end
                while true do
                    skip()
                    local key = parse_string()
                    skip()
                    pos = pos + 1 -- ':'
                    obj[key] = parse_value()
                    skip()
                    local sep = text:sub(pos, pos)
                    pos = pos + 1
                    if sep == "}" then return obj end
                end
            end
            if c == "[" then
                pos = pos + 1
                local arr = {}
                skip()
                if text:sub(pos, pos) == "]" then pos = pos + 1; return arr end
                while true do
                    arr[#arr + 1] = parse_value()
                    skip()
                    local sep = text:sub(pos, pos)
                    pos = pos + 1
                    if sep == "]" then return arr end
                end
            end
            local literal = text:match("^[%w%.%+%-]+", pos)
            pos = pos + #literal
            if literal == "true" then return true end
            if literal == "false" then return false end
            if literal == "null" then return nil end
            return tonumber(literal)
        end
        return parse_value()
    end
    return J
end

package.preload["libs/libkoreader-lfs"] = function()
    -- 忠实模拟真实 lfs.attributes 的存在性语义:
    --   - 文件存在(1 参)→ 返回属性表; (2 参 "mode")→ 返回 "file"
    --   - 文件不存在 → 返回 nil, "No such file or directory"(供 path_exists_distinct 区分
    --     "不存在" 与 "权限/IO 不可检查",即作者第3轮意见 #3)。
    -- 注:本桩仅识别文件,不识别目录(目录检测依赖 lfs.dir);调用方以
    --   lfs.attributes(p,"mode")=="directory" 判目录时,桩对目录返回 nil,与旧桩一致,
    --   故不改变既有目录相关测试行为。
    local virtual_files = rawget(_G, "__PICKTHOUGHT_TEST_FILES")
    if not virtual_files then
        virtual_files = {}
        _G.__PICKTHOUGHT_TEST_FILES = virtual_files
    end
    local virtual_dirs = rawget(_G, "__PICKTHOUGHT_TEST_DIRS")
    if not virtual_dirs then
        virtual_dirs = {}
        _G.__PICKTHOUGHT_TEST_DIRS = virtual_dirs
    end
    local virtual_entries = rawget(_G, "__PICKTHOUGHT_TEST_DIR_ENTRIES")
    if not virtual_entries then
        virtual_entries = {}
        _G.__PICKTHOUGHT_TEST_DIR_ENTRIES = virtual_entries
    end
    local function attributes(path, field)
        if virtual_dirs[path] then
            if field == "mode" then return "directory" end
            return { mode = "directory" }
        end
        if virtual_files[path] then
            if field == "mode" then return "file" end
            if field == "modification" then return 0 end
            return { mode = "file" }
        end
        local f = io.open(path, "r")
        local exists = f ~= nil
        if f then f:close() end
        if not exists then
            return nil, "No such file or directory"
        end
        if field then
            if field == "mode" then return "file" end
            if field == "modification" then return 0 end
            return nil
        end
        return { mode = "file" }
    end
    return {
        attributes = attributes,
        symlinkattributes = attributes,
        dir = function(path)
            local names = virtual_entries[path] or {}
            local index = 0
            return function()
                index = index + 1
                return names[index]
            end
        end,
        mkdir = function() return true end,
        rmdir = function() return true end,
    }
end

-- 内存版 ffi/archiver:与真实 API 同语义(koreader-base ffi/archiver.lua):
-- - Reader 的 entries 索引只在 next()/iterate() 中惰性建立,seek/extractToMemory
--   对未迭代到的条目返回 nil(真实实现如此,曾掩盖过一个真机必炸的 bug)。
-- - Writer 的 open/setZipCompression/addFileFromMemory 成功返回 true,失败返回 nil 并置 self.err。
-- files: 有序数组 {{path=..., content=...}, ...} 模拟 zip 条目顺序。
-- mock_opts(可选):{fail_write_path = "...", eof_write_path = "..."} 模拟写入失败或
-- 写入完成后以 ARCHIVE_EOF 返回 false。
-- mod._last_writer 记录最后创建的 Writer 供测试断言。
function M.archiver_mock(files, mock_opts)
    local mod = {}
    mock_opts = mock_opts or {}
    mod._disk = {}          -- 模拟“磁盘”:路径 → 内容,供 extractToPath/addPath 流转
    mod._disk_add_calls = 0 -- 统计走磁盘中转(addPath)的条目数,验证大条目确实走盘

    local Reader = {}
    Reader.__index = Reader
    function Reader:new()
        mod._reader_new_count = (mod._reader_new_count or 0) + 1
        return setmetatable({entries = {}, size = 0}, self)
    end
    function Reader:open(path)
        self.path = path
        self.index = 0
        return true
    end
    function Reader:next()
        local i = math.floor(self.index or 0) + 1
        local f = files[i]
        if not f then return nil end
        self.index = i
        local entry = self.entries[i]
        if not entry then
            entry = {path = f.path, mode = f.mode or "file", size = #f.content, index = i}
            self.entries[i] = entry
            self.size = self.size + 1
        end
        self.entries[entry.path] = entry
        return entry
    end
    function Reader:iterate(keep_pos)
        if self.index ~= 0 and not keep_pos then self.index = 0 end
        return self.next, self
    end
    function Reader:seek(key)
        local entry = self.entries[key]
        if not entry then return end
        if entry.index == self.index then return entry end
        for _ in self:iterate(entry.index > self.index) do
            if entry.index == self.index then return entry end
        end
    end
    function Reader:extractToMemory(key)
        local entry = self:seek(key)
        if not entry or entry.mode ~= "file" then return end
        self.index = self.index + 0.1
        return files[entry.index].content
    end
    -- 磁盘中转桩:模拟 extractToPath 把条目内容写到“磁盘”(内存表),供 addPath 读回。
    function Reader:extractToPath(key, dest_path)
        if mock_opts.fail_extract_path == key then return end
        local entry = self.entries[key]
        if not entry then return end
        mod._disk[dest_path] = files[entry.index].content
        return true
    end
    function Reader:close(keep_info)
        self.index = nil
        if not keep_info then self.entries = {}; self.size = 0 end
    end

    local Writer = {}
    Writer.__index = Writer
    function Writer:new()
        local w = setmetatable({entries = {}, compression = "deflate"}, self)
        mod._last_writer = w
        return w
    end
    function Writer:open(path, format)
        self.opened_path, self.format = path, format
        return true
    end
    function Writer:setZipCompression(method)
        self.compression = method
        return true
    end
    function Writer:addFileFromMemory(entry_path, content, mtime)
        self.err = nil
        if mock_opts.fail_write_path == entry_path then
            self.err = "mock 写入失败"
            return
        end
        self.entries[#self.entries + 1] = {
            path = entry_path, content = content, mtime = mtime, compression = self.compression,
        }
        return true
    end
    -- 磁盘中转桩:保持 KOReader addPath(entry_root, root, recursive, mtime)
    -- 的真实参数顺序,从“磁盘”(内存表)读回内容并追加到压缩条目。
    function Writer:addPath(entry_path, src_path, recursive, mtime)
        self.err = nil
        if mock_opts.fail_write_path == entry_path then
            self.err = "mock 写入失败"
            return
        end
        local content = mod._disk[src_path]
        if content == nil then
            self.err = "mock 读盘失败:" .. tostring(src_path)
            return
        end
        self.entries[#self.entries + 1] = {
            path = entry_path, content = content, mtime = mtime, compression = self.compression,
        }
        mod._disk_add_args = mod._disk_add_args or {}
        mod._disk_add_args[#mod._disk_add_args + 1] = {
            entry_path = entry_path, source_path = src_path, recursive = recursive,
        }
        mod._disk_add_calls = (mod._disk_add_calls or 0) + 1
        if mock_opts.eof_write_path == entry_path then return false end
        return true
    end
    function Writer:close()
        self.err = nil
        self.closed = true
    end

    mod.Reader, mod.Writer = Reader, Writer
    return mod
end

function M.written(writer) return writer.entries end

-- 内存版 lua-ljsqlite3:与 KOReader 内建 ljsqlite3 的 prepare/exec/step 语义一致
-- (真实现见 koreader-base ffi/lua-ljsqlite3/init.lua)。
-- 每个 path 一个内存库 {rows={}, schema=false};prepare 返回的 stmt 支持
-- reset():bind(...):step() 链式调用。只覆盖 thought_db 用到的几条模板:
-- CREATE/DROP/BEGIN/COMMIT/ROLLBACK(exec)、DELETE WHERE / INSERT / SELECT。
-- _last_path 供测试断言路径。
package.preload["lua-ljsqlite3/init"] = function()
    local SQ3 = { _stores = {}, _last_path = nil, _last_mode = nil, _opens = {}, _execs = {},
        _prepared = {}, _checkpoint_calls = 0 }

    local function store_of(path)
        local s = SQ3._stores[path]
        if not s then s = { rows = {}, schema = false }; SQ3._stores[path] = s end
        return s
    end

    -- stmt 的 step 按 sql 模板分发;reset 清 binds 与游标。
    local function make_stmt(store, sql)
        local stmt = { _sql = sql, _binds = {}, _cursor = nil, _done = false }
        function stmt:reset() stmt._binds = {}; stmt._cursor = nil; stmt._done = false; return stmt end
        function stmt:bind(...) stmt._binds = { ... }; return stmt end
        function stmt:step()
            local sql, b = stmt._sql, stmt._binds
            if sql:find("INSERT") then
                store.rows[#store.rows + 1] = {
                    chapter_uid = b[1], range = b[2], item_index = b[3],
                    abstract = b[4], author = b[5], content = b[6],
                    likes = b[7], review_id = b[8],
                }
                return nil
            elseif sql:find("DELETE") then
                if stmt._done then return nil end
                stmt._done = true
                local uid, rng = b[1], b[2]
                local kept = {}
                for _, r in ipairs(store.rows) do
                    local match = (r.chapter_uid == uid)
                    if rng then match = match and (r.range == rng) end
                    if not match then kept[#kept + 1] = r end
                end
                store.rows = kept
                return nil
            elseif sql:find("SELECT") then
                if not stmt._cursor then
                    local uid, rng = b[1], b[2]
                    local matched = {}
                    for _, r in ipairs(store.rows) do
                        if r.chapter_uid == uid and (not rng or r.range == rng) then
                            matched[#matched + 1] = r
                        end
                    end
                    table.sort(matched, function(x, y) return x.item_index < y.item_index end)
                    stmt._cursor = { rows = matched, pos = 0 }
                end
                stmt._cursor.pos = stmt._cursor.pos + 1
                local r = stmt._cursor.rows[stmt._cursor.pos]
                if not r then return nil end
                -- SELECT 顺序:abstract, author, content, likes, review_id
                return { r.abstract, r.author, r.content, r.likes, r.review_id }
            elseif sql:find("PRAGMA") then
                if sql:find("integrity_check") then
                    if stmt._ic_done then return nil end
                    stmt._ic_done = true
                    return { "ok" }
                end
                if sql:find("wal_checkpoint") then
                    SQ3._checkpoint_calls = SQ3._checkpoint_calls + 1
                    return { 0, 0, 0 }  -- total_frames, ckpt_frames, status(0=成功)
                end
                if sql:find("user_version") then return { store.user_version or 0 } end
                return nil
            end
            return nil
        end
        function stmt:close() end
        return stmt
    end

    function SQ3.open(path, mode)
        SQ3._last_path = path
        SQ3._last_mode = mode
        SQ3._opens[#SQ3._opens + 1] = { path = path, mode = mode }
        local virtual_files = rawget(_G, "__PICKTHOUGHT_TEST_FILES")
        if virtual_files then virtual_files[path] = true end
        local store = store_of(path)
        local db = {}
        db._mode = mode
        function db:exec(sql)
            sql = tostring(sql or "")
            SQ3._execs[#SQ3._execs + 1] = { path = path, mode = mode, sql = sql }
            if sql:find("CREATE TABLE") then store.schema = true
            elseif sql:find("DROP TABLE") then store.schema = false; store.rows = {}
            elseif sql:find("user_version=") then
                store.user_version = tonumber(sql:match("user_version=(%d+)")) or 0
            end
            -- PRAGMA / BEGIN / COMMIT / ROLLBACK:无操作语义,放行。
            return true
        end
        function db:prepare(sql)
            SQ3._prepared[#SQ3._prepared + 1] = { path = path, mode = mode, sql = tostring(sql or "") }
            return make_stmt(store, sql)
        end
        function db:close() return true end
        return db
    end

    -- 测试辅助:重置所有内存库(每个 case 之间清状态)。
    function SQ3._reset()
        SQ3._stores = {}; SQ3._last_path = nil; SQ3._last_mode = nil; SQ3._opens = {}; SQ3._execs = {}
        SQ3._prepared = {}; SQ3._checkpoint_calls = 0
        local virtual_files = rawget(_G, "__PICKTHOUGHT_TEST_FILES")
        if virtual_files then for path in pairs(virtual_files) do virtual_files[path] = nil end end
        local virtual_dirs = rawget(_G, "__PICKTHOUGHT_TEST_DIRS")
        if virtual_dirs then for path in pairs(virtual_dirs) do virtual_dirs[path] = nil end end
        local virtual_entries = rawget(_G, "__PICKTHOUGHT_TEST_DIR_ENTRIES")
        if virtual_entries then for path in pairs(virtual_entries) do virtual_entries[path] = nil end end
    end
    return SQ3
end

return M
