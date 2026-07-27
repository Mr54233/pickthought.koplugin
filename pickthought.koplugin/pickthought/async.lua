local FFIUtil=require("ffi/util")
local Json=require("pickthought.json")
local U=require("pickthought.util")
local UIManager=require("ui/uimanager")
local Async={}; Async.__index=Async
function Async:new(store, options)
    options = options or {}
    return setmetatable({store=store,job=nil,poll=nil,poll_interval=tonumber(options.poll_interval) or .25},self)
end
function Async:available() return type(FFIUtil.runInSubProcess)=="function" and type(FFIUtil.isSubProcessDone)=="function" and not (type(FFIUtil.isAndroid)=="function" and FFIUtil.isAndroid()) end
function Async:busy() return self.job~=nil end
function Async:_schedule()
    if self.poll then return end; local task; task=function() if self.poll~=task then return end; self.poll=nil; self:_check() end; self.poll=task; UIManager:scheduleIn(self.poll_interval,task)
end
function Async:_check()
    local j=self.job; if not j then return end; if os.time()-j.started>j.timeout then pcall(FFIUtil.terminateSubProcess,j.pid); j.timedout=true end
    local ok,done=pcall(FFIUtil.isSubProcessDone,j.pid,false); if ok and not done and not j.timedout then self:_schedule(); return end
    local raw=U.read_file(j.path,true); os.remove(j.path); os.remove(j.path..".tmp"); self.job=nil
    local result; if j.timedout then result={ok=false,error="worker timeout"} elseif not raw then result={ok=false,error="worker returned no result"} else local good,x=pcall(Json.decode,raw); result=good and x or {ok=false,error="worker result decode failed"} end
    if j.callback then j.callback(result) end
end
function Async:cancel(reason)
    if not self.job then return end; self.job.callback=nil; pcall(FFIUtil.terminateSubProcess,self.job.pid); os.remove(self.job.path); self.job=nil
end
function Async:run(label,fn,callback,timeout)
    if self.job then return false,"worker busy" end
    if not self:available() then local ok,x=pcall(fn); callback(ok and {ok=true,value=x} or {ok=false,error=tostring(x)}); return true end
    local path=self.store.temp_dir.."/worker-"..tostring(os.time()).."-"..tostring(math.random(10000,99999))..".json"; local child=function() local ok,x=pcall(fn); local res=ok and {ok=true,value=x} or {ok=false,error=tostring(x)}; local encoded=Json.encode(res); U.atomic_write(path,encoded,true) end
    local ok,pid,err=pcall(FFIUtil.runInSubProcess,child,false,false); if not ok or not pid then return false,tostring(err or pid) end; self.job={pid=pid,path=path,label=label,callback=callback,started=os.time(),timeout=timeout or 45}; self:_schedule(); return true
end
return Async
