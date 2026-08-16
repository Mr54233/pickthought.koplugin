local Config=require("pickthought.config")
local Digests=require("pickthought.digests")
local U=require("pickthought.util")
local logger=require("logger")
local Updater={}; Updater.__index=Updater
local MAX_PACKAGE_BYTES=10*1024*1024

function Updater:new(http,store,version,plugin_root)
    return setmetatable({http=http,store=store,version=version,plugin_root=plugin_root},self)
end

local function valid_https(url)
    return type(url)=="string" and url:match("^https://")~=nil
end

local function append_unique(out,seen,value)
    if valid_https(value) and not seen[value] then
        seen[value]=true
        out[#out+1]=value
    end
end

local function is_github_resource(url)
    if type(url)~="string" then return false end
    return url:match("^https://github%.com/")
        or url:match("^https://raw%.githubusercontent%.com/")
end

local function with_github_mirrors(url,out,seen)
    append_unique(out,seen,url)
    if not is_github_resource(url) then return end
    for _,prefix in ipairs(Config.GITHUB_MIRRORS or {}) do
        if valid_https(prefix) then
            if prefix:sub(-1)~="/" then prefix=prefix.."/" end
            append_unique(out,seen,prefix..url)
        end
    end
end

function Updater:manifest_urls()
    local out,seen={},{}
    local configured=Config.UPDATE_MANIFESTS
    if type(configured)=="table" then
        for _,url in ipairs(configured) do with_github_mirrors(url,out,seen) end
    else
        with_github_mirrors(Config.UPDATE_MANIFEST,out,seen)
    end
    return out
end

function Updater:manifest_url()
    return self:manifest_urls()[1]
end

local function collect_table_urls(value,out,seen)
    if type(value)~="table" then return end
    for _,url in ipairs(value) do with_github_mirrors(url,out,seen) end
end

local function package_urls(manifest)
    local out,seen={},{}
    if type(manifest)~="table" then return out end
    with_github_mirrors(manifest.package_url or manifest.url,out,seen)
    collect_table_urls(manifest.package_urls,out,seen)
    collect_table_urls(manifest.mirror_urls,out,seen)
    collect_table_urls(manifest.mirrors,out,seen)
    return out
end

local function command_ok(rc)
    return rc==true or rc==0
end

local function file_bytes(path)
    local data=U.read_file(path,true)
    if type(data)~="string" then return nil end
    return data
end

local function header_value(headers,name)
    local wanted=tostring(name or ""):lower()
    for key,value in pairs(headers or {}) do
        if tostring(key):lower()==wanted then return value end
    end
end

local function plain_notes(value)
    local text=tostring(value or ""):gsub("\r\n","\n"):gsub("\r","\n")
    text=text:gsub("^[ \t]*#+[ \t]*",""):gsub("\n[ \t]*#+[ \t]*","\n")
    text=text:gsub("%*%*(.-)%*%*","%1"):gsub("__(.-)__","%1")
    text=text:gsub("`(.-)`","%1")
    text=text:gsub("%[([^%]]+)%]%([^%)]+%)","%1")
    text=text:gsub("\n[ \t]*[-*+][ \t]+","\n")
    return text:gsub("^[ \t]+",""):gsub("[ \t]+$","")
end

Updater.normalize_notes=plain_notes

local function validate_manifest(m)
    if type(m)~="table" or type(m.version)~="string" or m.version=="" then
        return nil,"更新清单缺少版本号"
    end
    if m.package_type~=nil and tostring(m.package_type)~="full" then
        return nil,"更新清单不是全量包"
    end
    if #package_urls(m)==0 then return nil,"更新清单缺少安装包地址" end
    local expected=tostring(m.sha256 or ""):lower():gsub("%s+","")
    if expected=="" then return nil,"更新清单缺少 SHA-256" end
    return true
end

function Updater:check()
    local urls=self:manifest_urls()
    if #urls==0 then return nil,"更新地址未配置" end
    local errors={}
    for _,url in ipairs(urls) do
        local ok,m=pcall(function()
            return self.http:get_json(url,{auth=false,retries=1,redirects=8,timeout={15,45}})
        end)
        if ok then
            local valid,reason=validate_manifest(m)
            if valid then
                logger.info("[撷思][Updater] manifest loaded",url,"version=",tostring(m.version))
                self:cache_info(m)
                if not U.semver_newer(m.version,self.version) then
                    return {current=true,version=m.version,name=m.name,notes=m.notes}
                end
                return m
            end
            errors[#errors+1]=reason
        else
            errors[#errors+1]=tostring(m)
            logger.warn("[撷思][Updater] manifest failed",url,tostring(m))
        end
    end
    return nil,errors[#errors] or "无法读取更新清单"
end

function Updater:cache_info(m)
    if not self.store or type(self.store.save_update_info)~="function" then return end
    self.store:save_update_info({
        version=tostring(m and m.version or ""),
        name=plain_notes(m and m.name),
        notes=plain_notes(m and m.notes),
        checked_at=os.time(),
    })
end

function Updater:cached_info()
    if not self.store or type(self.store.update_info)~="function" then return nil end
    local info=self.store:update_info()
    if type(info)~="table" or tostring(info.version or "")=="" then return nil end
    return info
end

local function curl_download(url,path)
    local cmd="curl -L --fail --silent --show-error --connect-timeout 20 --max-time 180 --max-filesize "
        ..tostring(MAX_PACKAGE_BYTES).." -o "
        ..U.shell_quote(path).." "..U.shell_quote(url).." 2>/dev/null"
    logger.info("[撷思][Updater] curl fallback download",url)
    local ok=command_ok(os.execute(cmd))
    if not ok then os.remove(path) end
    return ok
end

local function stream_download(url,path,total_hint,on_progress)
    local ok_http,http=pcall(require,"socket.http")
    local ok_https,https=pcall(require,"ssl.https")
    local ok_socketutil,socketutil=pcall(require,"socketutil")
    local transport=url:match("^https://") and (ok_https and https or nil)
        or (ok_http and http or nil)
    if not transport or type(transport.request)~="function" then
        return nil,"HTTP 流式下载不可用"
    end

    local file,open_error=io.open(path,"wb")
    if not file then return nil,open_error or "无法创建更新临时文件" end
    local received=0
    local total=tonumber(total_hint) or 0
    local stream_error
    local function sink(chunk,err)
        if chunk then
            if received+#chunk>MAX_PACKAGE_BYTES then
                stream_error="更新包过大(超过 10MB)"
                return nil,stream_error
            end
            local wrote,werr=file:write(chunk)
            if not wrote then
                stream_error=werr or "写入更新临时文件失败"
                return nil,stream_error
            end
            received=received+#chunk
            if on_progress then
                local called,keep=pcall(on_progress,received,total)
                if not called then
                    stream_error=tostring(keep)
                    return nil,stream_error
                end
                if keep==false then
                    stream_error="已取消"
                    return nil,stream_error
                end
            end
        end
        if err and tostring(err)~="" then
            stream_error=tostring(err)
            return nil,stream_error
        end
        return 1
    end

    if ok_socketutil and socketutil and socketutil.set_timeout then
        socketutil:set_timeout(20,180)
    end
    local called,result,code,headers,status=pcall(transport.request,{
        url=url,method="GET",headers={
            ["User-Agent"]="KOReader-PickThought-Updater/1.0",
            ["Accept"]="application/zip,application/octet-stream,*/*",
        },sink=sink,redirect=true,
    })
    if ok_socketutil and socketutil and socketutil.reset_timeout then
        socketutil:reset_timeout()
    end
    pcall(file.flush,file)
    pcall(file.close,file)
    if not called then os.remove(path); return nil,tostring(result) end
    if stream_error then os.remove(path); return nil,stream_error end
    code=tonumber(code)
    if not code or code<200 or code>=300 then
        os.remove(path)
        return nil,"HTTP "..tostring(code or status or "error")
    end
    local content_length=tonumber(header_value(headers,"content-length"))
    if content_length and content_length>0 then total=content_length end
    if on_progress then on_progress(received,total) end
    return true
end

function Updater:download_to(url,path,total_hint,on_progress)
    return stream_download(url,path,total_hint,on_progress)
end

local function download_one(self,url,path,total_hint,on_progress)
    os.remove(path)
    local ok,downloaded,err=pcall(function()
        return self:download_to(url,path,total_hint,on_progress)
    end)
    if ok and downloaded then
        return true
    end
    err=ok and err or tostring(downloaded)
    if tostring(err):find("已取消",1,true) then
        return nil,err
    end
    logger.warn("[撷思][Updater] Lua streaming download unavailable or failed; using curl",url,tostring(err))
    if curl_download(url,path) then
        local size=U.file_size(path) or 0
        if on_progress then on_progress(size,total_hint or size) end
        return true
    end
    return nil,tostring(err or "下载失败")
end

function Updater:download(m, on_progress)
    local urls=package_urls(m)
    if #urls==0 then error("更新包地址无效") end
    local p=self.store.updates_dir.."/pickthought-"..U.id_name(m.version)..".zip"
    local part=p..".part"
    local expected=tostring(m.sha256 or ""):lower():gsub("%s+","")
    if expected=="" then error("更新清单缺少 SHA-256") end
    local expected_size=tonumber(m.size or m.bytes or m.package_size)
    if expected_size and expected_size>MAX_PACKAGE_BYTES then error("更新包过大(超过 10MB)") end
    local last_error="下载失败"

    os.remove(p)
    os.remove(part)
    local function report(event)
        if not on_progress then return true end
        return on_progress(event)~=false
    end

    for index,url in ipairs(urls) do
        if not report({stage="downloading",current=0,total=expected_size or 0,percent=0,
            source=index,sources=#urls}) then
            os.remove(part); error("已取消")
        end
        local downloaded,err=download_one(self,url,part,expected_size,function(current,total)
            local total_bytes=tonumber(total) or expected_size or 0
            local percent=total_bytes>0 and math.floor(math.min(1,current/total_bytes)*100+0.5) or 0
            return report({stage="downloading",current=current,total=total_bytes,percent=percent,
                source=index,sources=#urls})
        end)
        if not downloaded and tostring(err or ""):find("已取消",1,true) then
            os.remove(part)
            error("已取消")
        end
        local raw=downloaded and file_bytes(part) or nil
        if type(raw)=="string" and #raw>0 then
            if #raw > MAX_PACKAGE_BYTES then
                last_error="更新包过大(超过 10MB)"
                logger.warn("[撷思][Updater] package too large", url, "bytes=", tostring(#raw))
            elseif expected_size and expected_size>0 and #raw~=expected_size then
                last_error="更新包大小不符"
                logger.warn("[撷思][Updater] size mismatch",url,"expected=",tostring(expected_size),"actual=",tostring(#raw))
            else
                local actual=Digests.sha256(raw):lower()
                if actual==expected then
                    if not report({stage="verifying",current=#raw,total=expected_size or #raw,percent=100,
                        source=index,sources=#urls}) then
                        os.remove(part); error("已取消")
                    end
                    os.remove(p)
                    local moved=os.rename(part,p)
                    if not moved then
                        os.remove(p)
                        moved=os.rename(part,p)
                    end
                    if not moved then
                        os.remove(part)
                        error("无法保存已校验的更新包")
                    end
                    logger.info("[撷思][Updater] package downloaded",
                        "source=",tostring(index),"bytes=",tostring(#raw),"version=",tostring(m.version))
                    return p
                end
                last_error="更新包校验失败"
                logger.warn("[撷思][Updater] sha256 mismatch",url)
            end
        else
            last_error=err or "更新包下载失败或文件为空"
        end
        os.remove(part)
    end
    os.remove(part)
    error(last_error)
end

local function safe_relative(rel)
    if type(rel)~="string" or rel=="" or rel:sub(1,1)=="/" or rel:find("\\",1,true) then return nil end
    for part in rel:gmatch("[^/]+") do if part==".." or part=="." or part=="" then return nil end end
    return rel
end

function Updater:install(path,manifest)
    local stamp=tostring(os.time()).."-"..tostring(math.random(1000,9999))
    local stage=self.store.updates_dir.."/stage-"..stamp
    local unpacked=stage.."/unpacked"
    local backup=self.store.updates_dir.."/backup-"..stamp
    U.remove_tree(stage); U.remove_tree(backup); U.mkdir(unpacked)

    -- 全量包必须只包含一个 pickthought.koplugin 根目录。
    local rc=os.execute("unzip -q "..U.shell_quote(path).." -d "..U.shell_quote(unpacked).." 2>/dev/null")
    if not command_ok(rc) then U.remove_tree(stage); return nil,"解压更新包失败" end

    local incoming=unpacked.."/pickthought.koplugin"
    if not U.file_exists(incoming.."/main.lua") or not U.file_exists(incoming.."/_meta.lua") then
        U.remove_tree(stage); return nil,"更新包缺少 pickthought.koplugin 或插件文件不完整"
    end
    -- 版本验证:解压后读 _meta.lua 确认 version == manifest version(防下载/解压损坏)
    local meta_raw=U.read_file(incoming.."/_meta.lua",true) or ""
    local staged_version=meta_raw:match('version%s*=%s*"([^"]+)"')
    if not staged_version or tostring(staged_version)~=tostring(manifest.version) then
        U.remove_tree(stage); return nil,"更新包版本不匹配(期望 "..tostring(manifest.version)..",实际 "..tostring(staged_version)..")"
    end
    local roots=U.list(unpacked)
    if #roots~=1 or roots[1]~=incoming then
        U.remove_tree(stage); return nil,"更新包根目录必须只包含 pickthought.koplugin"
    end

    local ok,e=U.copy_tree(self.plugin_root,backup)
    if not ok then U.remove_tree(stage); return nil,"备份当前插件失败："..tostring(e) end

    local function rollback(message)
        U.remove_tree(self.plugin_root)
        local restored,re=U.copy_tree(backup,self.plugin_root)
        U.remove_tree(stage)
        if not restored then return nil,tostring(message).."；回滚也失败："..tostring(re) end
        return nil,tostring(message).."；已恢复旧版本"
    end

    U.remove_tree(self.plugin_root)
    local moved=os.rename(incoming,self.plugin_root)
    if not moved then
        local copied,ce=U.copy_tree(incoming,self.plugin_root)
        if not copied then return rollback("安装新文件失败："..tostring(ce)) end
    end
    if not U.file_exists(self.plugin_root.."/main.lua") or not U.file_exists(self.plugin_root.."/_meta.lua") then
        return rollback("安装后的插件文件不完整")
    end

    -- 兼容旧清单；全量替换通常不再需要 delete_list。
    if type(manifest.delete_list)=="table" then
        for _,rel in ipairs(manifest.delete_list) do
            rel=safe_relative(rel)
            if not rel then return rollback("delete_list 包含不安全路径") end
            local target=self.plugin_root.."/"..rel
            local removed=U.remove_tree(target)
            if removed==false then return rollback("无法删除旧文件："..rel) end
        end
    end

    U.remove_tree(stage)
    self.store:save_update_state({pending=true,expected=manifest.version,backup=backup,installed_at=os.time()})
    logger.info("[撷思][Updater] update installed","version=",tostring(manifest.version),"backup=",tostring(backup))
    return true
end

function Updater:startup()
    local s=self.store:update_state()
    if not s.pending then return nil end
    if tostring(s.expected)==tostring(self.version) then
        if s.backup then U.remove_tree(s.backup) end
        self.store:save_update_state({})
        return "updated"
    end
    return "mismatch"
end

return Updater
