local bit = require("bit")
local D = require("pickthought.digests")
local P = {}
P.USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36 Edg/135.0.0.0"
P.SKILL_VERSION = "1.0.5"
P.READER_TOKEN = "3c5c8717f3daf09iop3423zafeqoi"

local function optional(v)
    if v == nil then return nil end
    local value = tostring(v):gsub("^%s+", ""):gsub("%s+$", "")
    local lower = value:lower()
    if value == "" or lower == "null" or lower == "undefined" then return nil end
    return value
end
P.optional = optional
local function scalar(v) if v==true then return "true" elseif v==false then return "false" elseif v==nil then return "null" end return tostring(v) end
function P.escape(v)
    return (scalar(v):gsub("([^%w%-_%.~])", function(c) return string.format("%%%02X", c:byte()) end))
end
function P.query(params)
    local keys={}; for k in pairs(params or {}) do if k~="s" then table.insert(keys,k) end end; table.sort(keys)
    local out={}; for _,k in ipairs(keys) do table.insert(out,k.."="..P.escape(params[k])) end; return table.concat(out,"&")
end
function P.web_sign(q)
    local a,b=0x15051505,0x15051505; local n=#q; local i=n
    while i>1 do
        a=bit.band(bit.bxor(a,bit.lshift(q:byte(i),(n-i+1)%30)),0x7fffffff)
        b=bit.band(bit.bxor(b,bit.lshift(q:byte(i-1),(i-1)%30)),0x7fffffff)
        i=i-2
    end
    return string.format("%x",a+b):lower()
end
local function chars_hex(s)
    local o={}; for i=1,#s do o[#o+1]=string.format("%x",s:byte(i)) end; return table.concat(o)
end
function P.obfuscate(value)
    local s=tostring(value); local digest=D.md5(s); local chunks={}; local kind
    if s:match("^%d+$") then
        kind="3"; for i=1,#s,9 do chunks[#chunks+1]=string.format("%x",tonumber(s:sub(i,i+8))) end
    else kind="4"; chunks[1]=chars_hex(s) end
    local out=digest:sub(1,3)..kind.."2"..digest:sub(-2)
    for i,c in ipairs(chunks) do out=out..string.format("%02x",#c)..c..(i<#chunks and "g" or "") end
    if #out<20 then out=out..digest:sub(1,20-#out) end
    return out..D.md5(out):sub(1,3)
end
function P.reader_url(book_id, chapter_uid)
    local u="https://weread.qq.com/web/reader/"..P.obfuscate(book_id)
    if chapter_uid~=nil then u=u.."k"..P.obfuscate(chapter_uid) end
    return u
end
function P.mp_reader_url(book_id) return "https://weread.qq.com/web/mp/reader/"..P.obfuscate(book_id) end
function P.content_fields(book_id, chapter_uid, psvts, style)
    local now=os.time(); if P.obfuscate(now)==tostring(psvts or "") then now=now+1 end
    local t={b=P.obfuscate(book_id),c=P.obfuscate(chapter_uid),r=tostring(math.random(0,9999)^2),ct=tostring(now),ps=tostring(psvts or ""),pc=P.obfuscate(now),sc=1,prevChapter=false,st=style and 1 or 0}
    t.s=P.web_sign(P.query(t)); return t
end
function P.app_id(ua)
    ua=ua or P.USER_AGENT
    local parts={}; for v in ua:gmatch("%S+") do parts[#parts+1]=v; if #parts==12 then break end end
    local prefix={}; for _,v in ipairs(parts) do prefix[#prefix+1]=tostring(#v%10) end
    local h=0; for i=1,#ua do h=bit.band(131*h+ua:byte(i),0x7fffffff) end
    return "wb"..table.concat(prefix).."h"..tostring(h)
end
function P.read_fields(opt)
    opt = opt or {}
    local now=opt.now or os.time(); local ts=opt.ts or now*1000+math.random(0,999); local rn=opt.rn or math.random(0,999)
    local token = optional(opt.token) or P.READER_TOKEN
    local ps = optional(opt.psvts) or optional(opt.ps) or ""
    local pclts = optional(opt.pclts) or optional(opt.pc)
    local pc = pclts or P.obfuscate(now)
    local sources = {
        token_source = optional(opt.token) and "page" or "default",
        pc_source = pclts and "page" or "generated",
        ps_source = ps ~= "" and "page" or "missing",
    }
    local t={appId=opt.app_id or P.app_id(opt.user_agent),b=P.obfuscate(opt.book_id),c=P.obfuscate(opt.chapter_uid or 0),ci=opt.chapter_index or 0,co=opt.chapter_offset or 0,sm=tostring(opt.summary or ""):sub(1,20),pr=opt.progress or 0,rt=opt.elapsed or 0,ts=ts,rn=rn,sg=D.sha256(tostring(ts)..tostring(rn)..token),ct=now,ps=ps,pc=pc}
    t.s=P.web_sign(P.query(t))
    sources.sg_ready = type(t.sg) == "string" and t.sg ~= ""
    sources.payload_fields_complete = t.appId ~= nil and t.b ~= nil and t.c ~= nil
        and t.sg ~= nil and t.s ~= nil and t.pc ~= nil and t.pc ~= "" and t.ps ~= ""
    return t, sources
end
function P.is_mp(id) return tostring(id or ""):sub(1,7)=="MP_WXS_" end
return P
