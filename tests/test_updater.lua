local Updater=require("pickthought.updater")
local Digests=require("pickthought.digests")
local U=require("pickthought.util")

local function manifest(version,payload)
    return {
        version=version or "0.3.2",name="撷思 PickThought",
        package_type="full",package_url="https://example.com/pickthought.zip",
        sha256=Digests.sha256(payload),size=#payload,
        notes="## 本次更新\n\n**修复下载**\n\n- 保留日志",
    }
end

local function make_updater(payload,mode)
    local store={updates_dir="tests",_update_info={}}
    function store:save_update_info(value) self._update_info=value end
    function store:update_info() return self._update_info end
    local http={}
    local updater=Updater:new(http,store,"0.3.1","tests")
    function updater:download_to(_,path,_,on_progress)
        if mode=="fail" then return nil,"网络失败" end
        local file=assert(io.open(path,"wb"))
        local first=payload:sub(1,math.max(1,math.floor(#payload/2)))
        local second=payload:sub(#first+1)
        file:write(first)
        if on_progress and on_progress(#first,#payload)==false then
            file:close()
            return nil,"已取消"
        end
        if mode=="cancel" then
            file:close()
            return nil,"已取消"
        end
        file:write(second)
        file:close()
        if on_progress then on_progress(#payload,#payload) end
        return true
    end
    return updater,store,http
end

local function cleanup(version)
    local base="tests/pickthought-"..tostring(version)..".zip"
    os.remove(base)
    os.remove(base..".part")
end

T.case("Updater: 清单缓存纯文本更新日志",function()
    local payload="update-payload"
    local updater,store,http=make_updater(payload)
    local m=manifest("0.3.2",payload)
    function http:get_json() return m end
    local result=updater:check()
    T.eq(result.version,"0.3.2","发现新版本")
    local cached=updater:cached_info()
    T.eq(cached.version,"0.3.2","缓存版本")
    T.eq(cached.notes,"本次更新\n\n修复下载\n\n保留日志","更新日志去除 Markdown")
end)

T.case("Store: 更新开关默认关闭并可持久化",function()
    local settings_by_path={}
    package.preload["datastorage"]=function()
        return {
            getFullDataDir=function() return "tests" end,
            getSettingsDir=function() return "tests" end,
            getDataDir=function() return "tests" end,
        }
    end
    package.preload["luasettings"]=function()
        return {open=function(_,path)
            settings_by_path[path]=settings_by_path[path] or {}
            local values=settings_by_path[path]
            return {
                readSetting=function(_,key) return values[key] end,
                saveSetting=function(_,key,value) values[key]=value end,
                flush=function() end,
            }
        end}
    end
    package.loaded["datastorage"]=nil
    package.loaded["luasettings"]=nil
    package.loaded["pickthought.store"]=nil
    local Store=require("pickthought.store")
    local first=Store:new({data_dir="tests",settings_path="tests/.tmp-update-settings"})
    T.eq(first:preferences().update.auto_update,false,"自动更新默认关闭")
    T.eq(first:preferences().update.notify_update,false,"更新通知默认关闭")
    local p=first:preferences(); p.update.auto_update=true; p.update.notify_update=true
    first:save_preferences(p)
    local second=Store:new({data_dir="tests",settings_path="tests/.tmp-update-settings"})
    T.ok(second:preferences().update.auto_update,"自动更新持久化")
    T.ok(second:preferences().update.notify_update,"更新通知持久化")
end)

T.case("Updater: 当前版本也保留更新日志",function()
    local payload="current-payload"
    local updater,store,http=make_updater(payload)
    updater.version="0.3.2"
    function http:get_json() return manifest("0.3.2",payload) end
    local result=updater:check()
    T.ok(result.current,"当前版本标记")
    T.eq(store._update_info.version,"0.3.2","当前版本缓存")
end)

T.case("Updater: 清单拒绝非全量包",function()
    local payload="delta-payload"
    local updater,_,http=make_updater(payload)
    local m=manifest("0.3.2",payload); m.package_type="delta"
    function http:get_json() return m end
    local ok,err=updater:check()
    T.ok(not ok,"非全量包拒绝")
    T.ok(tostring(err):find("全量包",1,true)~=nil,"拒绝原因")
end)

T.case("Updater: 下载回调进度并在校验成功后改名",function()
    local version="0.3.21"
    local payload="valid-update-payload"
    cleanup(version)
    local updater=make_updater(payload)
    local events={}
    local path=updater:download(manifest(version,payload),function(event)
        events[#events+1]=event
    end)
    T.ok(path:find("pickthought%-"..version,1)~=nil,"返回正式包")
    T.eq(U.read_file(path,true),payload,"正式包内容")
    T.ok(not U.file_exists(path..".part"),"成功后无 part")
    T.ok(#events>=3,"收到下载进度")
    T.eq(events[#events].stage,"verifying","最后阶段为校验")
    cleanup(version)
end)

T.case("Updater: 流式下载按数据块回调进度",function()
    local old_preload=package.preload["ssl.https"]
    local old_loaded=package.loaded["ssl.https"]
    package.preload["ssl.https"]=function()
        return {request=function(options)
            options.sink("abc")
            options.sink("def")
            return 1,200,{["content-length"]="6"},"OK"
        end}
    end
    package.loaded["ssl.https"]=nil
    local updater=Updater:new({}, {updates_dir="tests"}, "0.3.1", "tests")
    local path="tests/.tmp_update_stream.part"
    os.remove(path)
    local events={}
    local ok,err=updater:download_to("https://example.com/update.zip",path,6,function(current,total)
        events[#events+1]={current,total}
    end)
    package.preload["ssl.https"]=old_preload
    package.loaded["ssl.https"]=old_loaded
    T.ok(ok,err or "流式下载成功")
    T.eq(U.read_file(path,true),"abcdef","流式文件内容")
    T.ok(#events>=2,"按数据块回调")
    T.eq(events[#events][2],6,"进度总大小")
    os.remove(path)
end)

T.case("Updater: SHA-256 失败清理 part",function()
    local version="0.3.22"
    local payload="bad-hash-payload"
    cleanup(version)
    local updater=make_updater(payload)
    local m=manifest(version,payload); m.sha256=Digests.sha256("other")
    local ok=pcall(function() updater:download(m) end)
    local path="tests/pickthought-"..version..".zip"
    T.ok(not ok,"错误校验应失败")
    T.ok(not U.file_exists(path),"SHA 失败无正式包")
    T.ok(not U.file_exists(path..".part"),"SHA 失败清理 part")
    cleanup(version)
end)

T.case("Updater: 包大小不符清理 part",function()
    local version="0.3.25"
    local payload="size-mismatch-payload"
    cleanup(version)
    local updater=make_updater(payload)
    local m=manifest(version,payload); m.size=#payload+1
    local ok=pcall(function() updater:download(m) end)
    local path="tests/pickthought-"..version..".zip"
    T.ok(not ok,"大小错误应失败")
    T.ok(not U.file_exists(path..".part"),"大小错误清理 part")
    cleanup(version)
end)

T.case("Updater: 清单声明超过上限时不开始下载",function()
    local version="0.3.26"
    local payload="too-large-payload"
    cleanup(version)
    local updater=make_updater(payload)
    local m=manifest(version,payload); m.size=10*1024*1024+1
    local ok=pcall(function() updater:download(m) end)
    local path="tests/pickthought-"..version..".zip"
    T.ok(not ok,"超限清单应失败")
    T.ok(not U.file_exists(path..".part"),"超限不产生 part")
    cleanup(version)
end)

T.case("Updater: 用户取消清理 part",function()
    local version="0.3.23"
    local payload="cancel-payload"
    cleanup(version)
    local updater=make_updater(payload,"cancel")
    local ok,err=pcall(function() updater:download(manifest(version,payload),function() return true end) end)
    local path="tests/pickthought-"..version..".zip"
    T.ok(not ok,"取消应结束下载")
    T.ok(tostring(err):find("已取消",1,true)~=nil,"取消原因")
    T.ok(not U.file_exists(path..".part"),"取消清理 part")
    cleanup(version)
end)

T.case("Updater: 官方地址失败后继续镜像地址",function()
    local version="0.3.24"
    local payload="mirror-payload"
    cleanup(version)
    local updater=make_updater(payload,"mirror")
    local calls=0
    function updater:download_to(url,path,_,on_progress)
        calls=calls+1
        if calls==1 then return nil,"官方地址失败" end
        local file=assert(io.open(path,"wb")); file:write(payload); file:close()
        if on_progress then on_progress(#payload,#payload) end
        return true
    end
    local m=manifest(version,payload)
    m.package_urls={"https://example.com/mirror.zip"}
    local path=updater:download(m)
    T.ok(calls>=2,"失败后尝试第二地址")
    T.eq(U.read_file(path,true),payload,"镜像包内容")
    cleanup(version)
end)
