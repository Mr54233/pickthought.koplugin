local lfs = require("libs/libkoreader-lfs")
local U = {}
function U.copy(v, seen)
    if type(v) ~= "table" then return v end
    seen=seen or {}; if seen[v] then return seen[v] end
    local o={}; seen[v]=o; for k,x in pairs(v) do o[U.copy(k,seen)]=U.copy(x,seen) end; return o
end
function U.merge(a,b)
    local o=U.copy(a or {}); for k,v in pairs(b or {}) do if type(v)=="table" and type(o[k])=="table" then o[k]=U.merge(o[k],v) else o[k]=U.copy(v) end end; return o
end
function U.trim(s) return (tostring(s or ""):gsub("^%s+",""):gsub("%s+$","")) end
function U.first_line(s,n) local v=tostring(s or ""):match("^[^\r\n]*") or ""; n=n or 240; return #v>n and v:sub(1,n).."…" or v end
function U.safe_name(s,f) local v=U.trim(tostring(s or ""):gsub("[%z%c/\\:%*%?\"<>|]","_")):gsub("%s+"," "); return v~="" and v or (f or "item") end
function U.id_name(s) local v=tostring(s or ""):gsub("[^%w%._%-]","_"); return v~="" and v or "unknown" end
function U.xml(s) return (tostring(s or ""):gsub("&","&amp;"):gsub("<","&lt;"):gsub(">","&gt;"):gsub('"',"&quot;"):gsub("'","&apos;")) end
function U.url_decode(s) return (tostring(s or ""):gsub("+"," "):gsub("%%(%x%x)",function(h) return string.char(tonumber(h,16)) end)) end
function U.file_exists(p) local f=io.open(p,"rb"); if not f then return false end f:close(); return true end
function U.read_file(p,b) local f,e=io.open(p,b and "rb" or "r"); if not f then return nil,e end local d=f:read("*a"); f:close(); return d end
function U.file_size(p) local f=io.open(p,"rb"); if not f then return nil end local n=f:seek("end"); f:close(); return n end
function U.mkdir(p)
    if not p or p=="" then return false end
    if lfs.attributes(p,"mode")=="directory" then return true end
    local parent=p:match("^(.*)/[^/]+$"); if parent and parent~="" and parent~=p then U.mkdir(parent) end
    local ok=lfs.mkdir(p); return ok or lfs.attributes(p,"mode")=="directory"
end
function U.atomic_write(p,d,b)
    local parent=p:match("^(.*)/[^/]+$"); if parent then U.mkdir(parent) end
    local t=p..".tmp-"..tostring(os.time()).."-"..tostring(math.random(1000,9999)); local f,e=io.open(t,b and "wb" or "w"); if not f then return nil,e end
    local ok,er=f:write(d or ""); f:flush(); f:close(); if not ok then os.remove(t); return nil,er end
    -- 先试原子改名(POSIX 直接覆盖);仅在失败时(Windows 目标已存在)删除旧文件重试,
    -- 避免无条件先删——改名失败时至少不弄丢已有文件。
    local r,re=os.rename(t,p)
    if not r then os.remove(p); r,re=os.rename(t,p) end
    if not r then os.remove(t); return nil,re end; return true
end
function U.remove_tree(p)
    p=tostring(p or "")
    if p=="" then return true end
    local mode
    if type(lfs.symlinkattributes)=="function" then mode=lfs.symlinkattributes(p,"mode") end
    if not mode then mode=lfs.attributes(p,"mode") end
    if mode=="file" or mode=="link" then
        local ok,err=os.remove(p)
        if ok or not lfs.attributes(p,"mode") then return true end
        return nil,err
    end
    if mode~="directory" then return true end
    local ok,iter,state=pcall(lfs.dir,p)
    if not ok or type(iter)~="function" then return nil,tostring(iter or state or "无法读取目录") end
    for x in iter,state do
        if x~="." and x~=".." then
            local removed,err=U.remove_tree(p.."/"..x)
            if not removed then return nil,err end
        end
    end
    local removed,err=lfs.rmdir(p)
    if removed or lfs.attributes(p,"mode")~="directory" then return true end
    return nil,err
end
function U.list(p)
    local o={}; if lfs.attributes(p,"mode")~="directory" then return o end
    for x in lfs.dir(p) do if x~="." and x~=".." then o[#o+1]=p.."/"..x end end; table.sort(o); return o
end
function U.copy_file(a,b) local d,e=U.read_file(a,true); if not d then return nil,e end return U.atomic_write(b,d,true) end
-- 流式复制:分块读写(默认 1MB),避免大书一次性读入 Lua 内存触发 OOM(KPW3/KPW4)。
-- on_progress(done, total) 可选,返回 false 表示用户取消;返回 true 或 nil,err(第三值为 "cancelled")。
-- 安全性(P1#3, 2026-08-15 二轮):先写入同目录临时文件,逐次检查读/写/flush/close 结果,
-- 成功后才原子替换最终目标;任何失败或取消都清理临时文件并保留原 b(可用备份不被覆盖/丢弃)。
function U.copy_file_stream(a, b, on_progress)
    local fi = io.open(a, "rb")
    if not fi then return nil, "无法打开源文件:" .. tostring(a) end
    local tmp = b .. ".copy.tmp"
    local fo = io.open(tmp, "wb")
    if not fo then fi:close(); return nil, "无法创建临时文件:" .. tostring(tmp) end
    local size = U.file_size(a) or 0
    local chunk = 1024 * 1024
    local done = 0
    local cancelled = false
    while true do
        local data, rerr = fi:read(chunk)
        if data == nil then
            if rerr then
                -- 读取错误(非 EOF):源文件中途损坏,半截副本绝不能当作成功备份(作者意见 #5)。
                fi:close(); fo:close(); pcall(os.remove, tmp)
                return nil, "读取源文件失败:" .. tostring(rerr)
            end
            break  -- 正常 EOF
        end
        local w, werr = fo:write(data)
        if not w then
            fi:close(); fo:close(); pcall(os.remove, tmp)
            return nil, "写入临时文件失败:" .. tostring(werr or "未知")
        end
        done = done + #data
        if on_progress then
            local ok_p, res = pcall(on_progress, done, size)
            if ok_p and res == false then cancelled = true; break end
        end
    end
    fi:close()
    local ok_flush, ferr = fo:flush()
    if not ok_flush then fo:close(); pcall(os.remove, tmp); return nil, "刷新临时文件失败:" .. tostring(ferr or "未知") end
    local ok_close, cerr = fo:close()
    if not ok_close then pcall(os.remove, tmp); return nil, "关闭临时文件失败:" .. tostring(cerr or "未知") end
    if cancelled then
        pcall(os.remove, tmp)  -- 取消:丢弃临时副本,保留原有 b
        return nil, "已取消复制", "cancelled"
    end
    -- 成功:原子替换。若 b 已存在,先暂存为 .prev 以便失败回退(不直接覆盖可用备份)。
    local had_prev = U.file_exists(b)
    if had_prev then
        local prev = b .. ".prev"
        if U.file_exists(prev) then pcall(os.remove, prev) end
        local ok_mv, mv_err = os.rename(b, prev)
        if not ok_mv then pcall(os.remove, tmp); return nil, "暂存旧备份失败:" .. tostring(mv_err or "未知") end
    end
    local ok_rename, rerr = os.rename(tmp, b)
    if not ok_rename then
        -- .prev 回滚结果必须检查:回滚失败绝不能谎称成功(作者意见 #5)。
        if had_prev and U.file_exists(b .. ".prev") then
            local ok_rb, rb_err = os.rename(b .. ".prev", b)
            if not ok_rb then
                pcall(os.remove, tmp)
                return nil, "替换为目标失败且无法回滚旧备份:" .. tostring(rerr or "未知")
                    .. ";回滚错误:" .. tostring(rb_err or "未知")
            end
        end
        pcall(os.remove, tmp)
        return nil, "替换为目标失败:" .. tostring(rerr or "未知")
    end
    if had_prev then pcall(os.remove, b .. ".prev") end
    return true
end

-- 轻量内容指纹:对文件头尾各采样 64KB 做 FNV-1a 哈希,用于在不计算完整哈希的前提下
-- 快速区分"同体积不同内容"的 EPUB,避免复用错误的章节映射/缓存(P2, 2026-08-15 二轮)。
function U.content_fingerprint(path)
    local bit = require("bit")
    local f = io.open(path, "rb")
    if not f then return nil end
    local SAMPLE = 65536
    local size = U.file_size(path) or 0
    local buf = {}
    f:seek("set", 0)
    local head = f:read(SAMPLE)
    if head then buf[#buf + 1] = head end
    if size > SAMPLE * 2 then
        f:seek("set", size - SAMPLE)
        local tail = f:read(SAMPLE)
        if tail then buf[#buf + 1] = tail end
    end
    f:close()
    local h = 2166136261
    for _, s in ipairs(buf) do
        for i = 1, #s do
            -- LuaJIT(Lua5.1)无原生按位异或,用 bit 库;乘后取模保持 32 位。
            h = (bit.bxor(h, s:byte(i)) * 16777619) % 4294967296
        end
    end
    return string.format("%08x", h)
end

-- 路径指纹:FNV-1a 对路径字符串做定长 16 进制哈希,不含路径分隔符。
-- 用于把 clean_source 的完整路径纳入缓存签名时,避免分隔符直接落入
-- 缓存目录名造成异常嵌套目录(作者意见 #6)。
function U.path_hash(path)
    local bit = require("bit")
    local s = tostring(path or "")
    local h = 2166136261
    for i = 1, #s do
        h = (bit.bxor(h, s:byte(i)) * 16777619) % 4294967296
    end
    return string.format("%08x", h)
end
function U.copy_tree(a,b)
    local m=lfs.attributes(a,"mode"); if m=="file" then return U.copy_file(a,b) end; if m~="directory" then return nil,"source missing" end
    U.mkdir(b); for x in lfs.dir(a) do if x~="." and x~=".." then local ok,e=U.copy_tree(a.."/"..x,b.."/"..x); if not ok then return nil,e end end end; return true
end
function U.extract_balanced_json(text,marker)
    local p=text:find(marker,1,true); if not p then return nil end; p=text:find("{",p,true); if not p then return nil end
    local depth,quote,esc=0,false,false; for i=p,#text do local c=text:sub(i,i); if quote then if esc then esc=false elseif c=="\\" then esc=true elseif c=='"' then quote=false end else if c=='"' then quote=true elseif c=="{" then depth=depth+1 elseif c=="}" then depth=depth-1; if depth==0 then return text:sub(p,i) end end end end
end
function U.clamp(v,a,b) v=tonumber(v) or a; if v<a then return a elseif v>b then return b end return v end
function U.percent(n,d) d=tonumber(d) or 0; if d<=0 then return 0 end return math.floor(U.clamp((tonumber(n) or 0)*100/d,0,100)+.5) end
function U.now_text(t) t=tonumber(t) or 0; return t>0 and os.date("%Y-%m-%d %H:%M:%S",t) or "—" end
function U.shell_quote(s) return "'"..tostring(s):gsub("'","'\\''").."'" end
function U.semver_newer(a,b)
    local function parts(v) local o={}; for n in tostring(v):gmatch("%d+") do o[#o+1]=tonumber(n) end return o end
    local x,y=parts(a),parts(b); for i=1,math.max(#x,#y) do local p,q=x[i] or 0,y[i] or 0; if p~=q then return p>q end end; return false
end
return U
