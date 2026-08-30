local DataStorage=require("datastorage")
local lfs=require("libs/libkoreader-lfs")
local LuaSettings=require("luasettings")
local Config=require("pickthought.config")
local BatchSync=require("pickthought.batch_sync")
local Json=require("pickthought.json")
local U=require("pickthought.util")
local Store={}; Store.__index=Store
-- 想法弹窗重做后的设置。保留在原有 preferences.thoughts 下，避免破坏
-- 已安装用户的偏好文件和其他模块的读取路径。
local THOUGHT_POPUP_DEFAULTS={
 position="center",height_ratio=0.70,width_ratio=0.80,
 font_size_relative=0,font_size=nil,contrast=9,tap_to_page=false,
}
local LEGACY_SYNC_MIN_AVAILABLE_KB=96*1024
local LEGACY_SYNC_MAX_CACHE_BYTES=24*1024*1024
local LEGACY_SYNC_MAX_UNDERLINES=12000
local LEGACY_SYNC_MAX_THOUGHT_ENTRIES=30000
local CURRENT_SYNC_MIN_AVAILABLE_KB=128*1024
local CURRENT_SYNC_MAX_CACHE_BYTES=96*1024*1024
local CURRENT_SYNC_MAX_UNDERLINES=20000
local CURRENT_SYNC_MAX_THOUGHT_ENTRIES=150000
local defaults={
 schema=Config.SCHEMA,
 auth={api_key="",cookies={},account={name="",vid="",logged_at=0}},
 preferences={images=true,mp_images=false,shelf_covers=true,download_keep_awake=true,download_notice_enabled=true,download_complete_notice=true,show_annotations=true,annotation_style="default",annotation_mode="all",low_resource=false,download_dir="",shelf_sort="read",shelf_scope="all",shelf_view="compact",shelf_filters={},shelf_section="account",account_shelf_kind="books",account_shelf_sort="read",account_shelf_scope="all",generated_shelf_sort="opened",generated_shelf_scope="all",thoughts=THOUGHT_POPUP_DEFAULTS,update={manifest=Config.UPDATE_MANIFEST,auto_update=false,notify_update=false},sync={time_enabled=false,time_notice_enabled=true,progress_enabled=true,progress_notice_mode="first",manual_only=false,auto_upload=false,pull_on_open=true,check_resume=false,require_verified=false,interval=Config.READ_INTERVAL,idle_timeout=Config.IDLE_TIMEOUT,threshold=Config.REMOTE_THRESHOLD,resume_after=300},auto_batch_sync_opt_in=BatchSync.DEFAULT_AUTO,sync_keep_awake=true,sync_batch_limit=200,sync_max_cache_bytes=25165824,sync_max_underlines=12000,sync_max_thought_entries=30000,sync_min_available_kb=131072,debug_mode=false},
 library={},sessions={},shelf_cache={books={},mp={},updated_at=0},cover_index={},cover_guard={active=false,started_at=0,stage="",version=""},update_state={},update_info={},download_queue={},
 pending_installs={},last_cleanup_result={},read_report_consumed={},
}
local function public_documents_root(data_dir)
    local kindle_documents = "/mnt/us/documents"
    if lfs.attributes(kindle_documents,"mode")=="directory" then
        return kindle_documents .. "/PickThought"
    end
    local ok, home = pcall(function() return DataStorage:getDataDir() end)
    if ok and type(home)=="string" and home~="" then
        return home .. "/PickThought"
    end
    return data_dir .. "/books"
end

function Store:new(options)
    options=options or {}
    local data=options.data_dir or (DataStorage:getFullDataDir().."/"..Config.DATA_DIR)
    U.mkdir(data); U.mkdir(data.."/books"); U.mkdir(data.."/covers"); U.mkdir(data.."/temp"); U.mkdir(data.."/updates")
    local o=setmetatable({
        data_dir=data,
        cache_books_dir=data.."/books",
        default_books_dir=public_documents_root(data),
        covers_dir=data.."/covers",
        temp_dir=data.."/temp",
        updates_dir=data.."/updates",
        -- 设置文件与原版撷思分家:LuaSettings 是整文件重写,两个插件共用一份
        -- 会互相覆盖。首次启动从旧文件迁移(登录态/绑定原样带过来)。
        settings_path=options.settings_path or (function()
            local mine=DataStorage:getSettingsDir().."/pickthought.lua"
            if not U.file_exists(mine) then
                local legacy=DataStorage:getSettingsDir().."/pickthought.lua"
                if U.file_exists(legacy) then U.copy_file(legacy,mine) end
            end
            return mine
        end)(),
        download_state_path=data.."/download-state.json",
        isolated=options.isolated==true,
    },self)
    o.db=LuaSettings:open(o.settings_path)
    for k,v in pairs(defaults) do if o.db:readSetting(k,nil)==nil then o.db:saveSetting(k,U.copy(v)) end end
    o:migrate()
    o:normalize_thought_popup_preferences()
    -- v1.1.45 intentionally disables automatic legacy EPUB relocation. File
    -- moves must never run during every reader/file-manager transition.
    o.db:flush()
    return o
end

local function clamp_number(value, minimum, maximum)
    value=tonumber(value)
    if not value then return nil end
    return math.max(minimum,math.min(maximum,value))
end

-- Config.SCHEMA 在旧版本中没有连续递增，不能把这项迁移藏在 schema 分支
-- 里。每次启动做一次幂等补齐：旧高度/宽度保留，只有不存在的新字段才填入
-- 上游 v1.3.0 的默认值；旧字体枚举映射为近似相对字号。
function Store:normalize_thought_popup_preferences()
    local preferences=self.db:readSetting("preferences",{})
    if type(preferences)~="table" then preferences={} end
    local thoughts=preferences.thoughts
    local changed=false
    if type(thoughts)~="table" then thoughts={}; preferences.thoughts=thoughts; changed=true end

    if thoughts.position~="center" and thoughts.position~="bottom" then
        thoughts.position=THOUGHT_POPUP_DEFAULTS.position; changed=true
    end
    local height=clamp_number(thoughts.height_ratio,0.20,0.90)
    if height==nil then height=THOUGHT_POPUP_DEFAULTS.height_ratio end
    if thoughts.height_ratio~=height then thoughts.height_ratio=height; changed=true end
    local width=clamp_number(thoughts.width_ratio,0.40,1.00)
    if width==nil then width=THOUGHT_POPUP_DEFAULTS.width_ratio end
    if thoughts.width_ratio~=width then thoughts.width_ratio=width; changed=true end

    if thoughts.font_size~=nil then
        local absolute=clamp_number(thoughts.font_size,8,255)
        if absolute==nil then thoughts.font_size=nil; changed=true
        elseif thoughts.font_size~=absolute then thoughts.font_size=absolute; changed=true end
    end
    if thoughts.font_size==nil then
        local relative=clamp_number(thoughts.font_size_relative,-10,5)
        if relative==nil then
            local legacy={standard=-3,large=0,xlarge=3}
            relative=legacy[tostring(thoughts.font)] or THOUGHT_POPUP_DEFAULTS.font_size_relative
        end
        if thoughts.font_size_relative~=relative then thoughts.font_size_relative=relative; changed=true end
    end

    local contrast=clamp_number(thoughts.contrast,-3,9)
    if contrast==nil then contrast=THOUGHT_POPUP_DEFAULTS.contrast end
    if thoughts.contrast~=contrast then thoughts.contrast=contrast; changed=true end
    if thoughts.tap_to_page==nil then thoughts.tap_to_page=false; changed=true
    elseif type(thoughts.tap_to_page)~="boolean" then
        thoughts.tap_to_page=thoughts.tap_to_page==true; changed=true
    end

    if changed then self.db:saveSetting("preferences",preferences) end
    return changed
end
function Store:migrate()
    local schema=tonumber(self.db:readSetting("schema",1)) or 1
    if schema<Config.SCHEMA then
        local previous=self.db:readSetting("preferences",{}) or {}
        local p=U.merge(defaults.preferences,previous)
        if schema<10 then
            p.annotation_mode="all"
            p.show_annotations=true
            p.sync=p.sync or {}
            p.sync.manual_only=true
            p.sync.auto_upload=false
            p.sync.pull_on_open=false
            p.sync.check_resume=false
            p.sync.require_verified=false
        end
        if schema<11 and previous.download_keep_awake==nil then
            p.download_keep_awake=true
        end
        -- Schema 12 keeps private checkpoints/comments in koreader/pickthought while
        -- final EPUB files default to the normal KOReader documents directory.
        if schema<13 then
            local sessions=self.db:readSetting("sessions",{}) or {}
            for _,session in pairs(sessions) do
                if type(session)=="table" then
                    session.report_context=nil
                    session.psvts=nil; session.pclts=nil; session.token=nil
                    session.reader_url=nil; session.context_updated_at=nil
                    session.last_path=nil; session.last_attempts=nil; session.last_stage=nil
                    session.last_response_summary=nil; session.last_http_code=nil
                    session.last_http_length=nil; session.last_payload_public=nil
                    session.last_error=nil; session.consecutive_failures=0
                    session.read_context_version=2
                end
            end
            self.db:saveSetting("sessions",sessions)
        end
        if schema<15 then
            p.sync=p.sync or {}
            if previous.sync==nil or previous.sync.progress_enabled==nil then p.sync.progress_enabled=true end
            p.sync.pull_on_open=p.sync.progress_enabled~=false
            p.sync.require_verified=false
            p.sync.manual_only=false
        end
        if schema<16 then
            -- Public builds use one fixed OTA manifest. Legacy channel/URL
            -- preferences are ignored and replaced by the repository address.
            p.update={manifest=Config.UPDATE_MANIFEST}
        end
        if schema<18 then
            -- Replace the legacy centered comment card with the compact
            -- bottom-sheet layout. These dimensions were never user-facing,
            -- so migrate existing installations instead of preserving the
            -- oversized saved values.
            p.thoughts=p.thoughts or {}
            p.thoughts.width_ratio=0.92
            p.thoughts.height_ratio=0.42
        end
        if schema<19 then
            -- v1.0.6 treats the saved height as a maximum, not a fixed card
            -- height. Give the comments room to show several entries while
            -- allowing short content to shrink to its actual rendered size.
            p.thoughts=p.thoughts or {}
            p.thoughts.width_ratio=0.94
            p.thoughts.height_ratio=0.60
        end
        if schema<20 then
            -- v1.0.7 uses a near-full-width comments sheet with compact outer
            -- and inner spacing. Migrate old saved dimensions so existing
            -- installations receive the same layout without clearing data.
            p.thoughts=p.thoughts or {}
            p.thoughts.width_ratio=0.985
            p.thoughts.height_ratio=0.60
        end
        if schema<21 then
            -- v1.0.8 returns to a centered dialog and reallocates interior
            -- space to the selected text and comments instead of leaving
            -- large blank areas. Existing installs are migrated directly.
            p.thoughts=p.thoughts or {}
            p.thoughts.width_ratio=0.94
            p.thoughts.height_ratio=0.68
        end
        if schema<22 then
            -- v1.0.9 removes MuPDF's internal page margins and sizes short
            -- comment dialogs from the actual rendered content height.
            p.thoughts=p.thoughts or {}
            p.thoughts.width_ratio=0.94
            p.thoughts.height_ratio=0.68
        end
        if schema<23 then
            -- v1.0.10 combines the lighter card proportions with the denser
            -- comment list: slightly smaller dialog, balanced inner spacing,
            -- framed source quote and compact inline like counts.
            p.thoughts=p.thoughts or {}
            p.thoughts.width_ratio=0.91
            p.thoughts.height_ratio=0.60
        end
        if schema<24 then
            -- v1.1.0 adds the combined local/cloud shelf, two-column cover
            -- view, compact list, local shelf search and single-scope filters.
            if previous.shelf_view==nil then p.shelf_view="grid" end
            if previous.shelf_scope==nil then
                local old=previous.shelf_filters or {}
                if old.downloaded then p.shelf_scope="downloaded"
                elseif old.reading then p.shelf_scope="reading"
                elseif old.finished then p.shelf_scope="finished"
                else p.shelf_scope="all" end
                p.shelf_filters={}
            end
            if previous.shelf_sort==nil then p.shelf_sort="read" end
        end
        if schema<25 then
            -- v1.1.1 removes the unstable custom two-column Menu layout and
            -- returns every device to the proven one-column compact shelf.
            p.shelf_view="compact"
        end
        if schema<26 then
            -- v1.1.25 adds a user-facing switch for the automatic reading-time
            -- status notice. Existing users keep the current visible behavior.
            p.sync=p.sync or {}
            if previous.sync==nil or previous.sync.time_notice_enabled==nil then
                p.sync.time_notice_enabled=true
            end
        end
        if schema<28 then
            -- v1.1.34 records only the short-lived shelf-cover render guard.
            -- If KOReader exits while a cover page is being built, the next
            -- launch can open the shelf once without covers and avoid a loop.
            self.db:saveSetting("cover_guard",U.copy(defaults.cover_guard))
        end
        if schema<29 then
            -- Reset position confirmation for the new two-way sync rule and
            -- neutralize old diagnostic labels kept in user settings.
            local sessions=self.db:readSetting("sessions",{}) or {}
            local function neutral(value)
                if type(value)~="string" then return value end
                value=value:gsub("legacy_[%d%.]+_","compat_read_report_")
                value=value:gsub("[%d]+%.[%d]+%.[%d]+%s*原版","兼容")
                value=value:gsub("%s+"," ")
                return value
            end
            for _,session in pairs(sessions) do
                if type(session)=="table" then
                    session.remote_verified=false
                    session.verified_at=nil
                    session.verified_reason=nil
                    session.last_path=neutral(session.last_path)
                    session.last_stage=neutral(session.last_stage)
                    session.last_response_summary=neutral(session.last_response_summary)
                end
            end
            self.db:saveSetting("sessions",sessions)
        end

        if schema<30 then
            -- v1.1.36 keeps the cloud shelf order by default and separates
            -- progress-success notices from reading-time notices.
            p.sync=p.sync or {}
            if previous.sync==nil or previous.sync.progress_notice_mode==nil then
                p.sync.progress_notice_mode="first"
            end
            if tostring(previous.shelf_sort or "read")=="read" then
                p.shelf_sort="cloud"
            end
        end

        if schema<31 then
            -- v1.1.37 simplifies the menus and persists the single-download queue.
            -- Existing download/image preferences are retained internally for
            -- compatibility, but they are no longer exposed as routine toggles.
            self.db:saveSetting("download_queue", self.db:readSetting("download_queue", {}) or {})
        end
        if schema<32 then
            -- v1.1.38 separates the current account shelf from EPUB files
            -- generated by PickThought. The old mixed shelf settings are kept only
            -- as migration input so local files can no longer disturb the
            -- account shelf's default ordering.
            p.shelf_section=tostring(previous.shelf_section or "account")
            if p.shelf_section~="generated" then p.shelf_section="account" end
            p.account_shelf_kind=tostring(previous.account_shelf_kind or "books")
            if p.account_shelf_kind~="mp" then p.account_shelf_kind="books" end
            local old_sort=tostring(previous.account_shelf_sort or previous.shelf_sort or "cloud")
            local account_sort_map={cloud="default",default="default",read="read",update="update",progress="progress",title="title",author="author"}
            p.account_shelf_sort=account_sort_map[old_sort] or "default"
            local old_scope=tostring(previous.account_shelf_scope or previous.shelf_scope or "all")
            local account_scope_map={all="all",downloaded="generated",generated="generated",ungenerated="ungenerated",top="top",archive="archive"}
            p.account_shelf_scope=account_scope_map[old_scope] or "all"
            p.generated_shelf_sort=tostring(previous.generated_shelf_sort or "opened")
            if not ({opened=true,generated=true,title=true,author=true,size=true})[p.generated_shelf_sort] then p.generated_shelf_sort="opened" end
            p.generated_shelf_scope=tostring(previous.generated_shelf_scope or "all")
            if not ({all=true,in_account=true,removed=true,clean=true,notes=true})[p.generated_shelf_scope] then p.generated_shelf_scope="all" end
        end
        if schema<33 then
            -- v1.1.39 restores the shelf ordering that most closely matches
            -- the mobile client: cloud readUpdateTime descending. Old labels
            -- such as default/cloud represented interface-array order and are
            -- migrated automatically; explicit user choices are preserved.
            local old_sort=tostring(previous.account_shelf_sort or previous.shelf_sort or p.account_shelf_sort or "read")
            local account_sort_map={
                cloud="read",default="read",cloud_order="read",interface="read",read="read",
                update="update",progress="progress",title="title",author="author",
            }
            p.account_shelf_sort=account_sort_map[old_sort] or "read"
            p.shelf_sort="read"
        end
        if schema<36 then
            -- Rebuild the small pending-install index once. This replaces the
            -- old full-library scan on every document close.
            local pending={}
            local library=self.db:readSetting("library",{}) or {}
            local function add_pending(book_id,kind,chapter_uid,record)
                if type(record)~="table" or record.pending_install~=true
                    or tostring(record.pending_file or "")=="" then return end
                local key=table.concat({tostring(book_id),tostring(chapter_uid or "full"),tostring(kind or "")},":")
                pending[#pending+1]={key=key,book_id=tostring(book_id),kind=tostring(kind or ""),
                    chapter_uid=chapter_uid and tostring(chapter_uid) or nil,file=record.file,
                    pending_file=record.pending_file,created_at=tonumber(record.downloaded_at) or os.time()}
            end
            for book_id,book in pairs(library) do
                for kind,record in pairs(book.variants or {}) do add_pending(book_id,kind,nil,record) end
                for uid,row in pairs(book.chapters or {}) do
                    for kind,record in pairs(row or {}) do add_pending(book_id,kind,uid,record) end
                end
            end
            self.db:saveSetting("pending_installs",pending)
            self.db:saveSetting("last_cleanup_result",{})
        end
        self.db:saveSetting("preferences",p)
        self.db:saveSetting("schema",Config.SCHEMA)
    end
end
function Store:get(k,d) local v=self.db:readSetting(k,nil); return v==nil and U.copy(d) or v end
function Store:set(k,v) self.db:saveSetting(k,v); self.db:flush() end
function Store:auth() return U.merge(defaults.auth,self:get("auth",{})) end
function Store:save_auth(v) self:set("auth",U.merge(defaults.auth,v or {})) end
function Store:clear_auth() self:set("auth",U.copy(defaults.auth)) end
function Store:preferences()
    local preferences=U.merge(defaults.preferences,self:get("preferences",{}))
    preferences.thoughts=U.merge(THOUGHT_POPUP_DEFAULTS,preferences.thoughts or {})
    -- 96MB 是前一轮测试版本写入的临时安全线,不是用户可配置选项;
    -- 升级后迁移到为映射/注入预留余量的 128MB。
    if tonumber(preferences.sync_min_available_kb)==LEGACY_SYNC_MIN_AVAILABLE_KB then
        preferences.sync_min_available_kb=CURRENT_SYNC_MIN_AVAILABLE_KB
    end
    if tonumber(preferences.sync_max_cache_bytes)==LEGACY_SYNC_MAX_CACHE_BYTES then
        preferences.sync_max_cache_bytes=CURRENT_SYNC_MAX_CACHE_BYTES
    end
    if tonumber(preferences.sync_max_underlines)==LEGACY_SYNC_MAX_UNDERLINES then
        preferences.sync_max_underlines=CURRENT_SYNC_MAX_UNDERLINES
    end
    if tonumber(preferences.sync_max_thought_entries)==LEGACY_SYNC_MAX_THOUGHT_ENTRIES then
        preferences.sync_max_thought_entries=CURRENT_SYNC_MAX_THOUGHT_ENTRIES
    end
    return preferences
end
function Store:save_preferences(v)
    local preferences=U.merge(defaults.preferences,v or {})
    preferences.thoughts=U.merge(THOUGHT_POPUP_DEFAULTS,preferences.thoughts or {})
    if tonumber(preferences.sync_min_available_kb)==LEGACY_SYNC_MIN_AVAILABLE_KB then
        preferences.sync_min_available_kb=CURRENT_SYNC_MIN_AVAILABLE_KB
    end
    if tonumber(preferences.sync_max_cache_bytes)==LEGACY_SYNC_MAX_CACHE_BYTES then
        preferences.sync_max_cache_bytes=CURRENT_SYNC_MAX_CACHE_BYTES
    end
    if tonumber(preferences.sync_max_underlines)==LEGACY_SYNC_MAX_UNDERLINES then
        preferences.sync_max_underlines=CURRENT_SYNC_MAX_UNDERLINES
    end
    if tonumber(preferences.sync_max_thought_entries)==LEGACY_SYNC_MAX_THOUGHT_ENTRIES then
        preferences.sync_max_thought_entries=CURRENT_SYNC_MAX_THOUGHT_ENTRIES
    end
    self:set("preferences",preferences)
end
function Store:books_root() local p=self:preferences().download_dir; if p=="" then p=self.default_books_dir end; U.mkdir(p); return p end
function Store:epub_root() return self:books_root() end
function Store:book_cache_path(id) return self.cache_books_dir.."/"..U.id_name(id) end
function Store:book_dir(id) local p=self:book_cache_path(id); U.mkdir(p); return p end
function Store:epub_path(filename) local p=self:epub_root().."/"..tostring(filename); U.mkdir(self:epub_root()); return p end

local function basename(path) return tostring(path or ""):match("([^/]+)$") end
function Store:migrate_legacy_epubs()
    local all=self.db:readSetting("library",{}) or {}
    local changed=false
    local root=self:epub_root()
    local function move_record(record)
        if type(record)~="table" or type(record.file)~="string" or record.file=="" then return end
        if not U.file_exists(record.file) then return end
        if record.file:sub(1,#root+1)==root.."/" then return end
        if record.file:sub(1,#self.cache_books_dir+1)~=self.cache_books_dir.."/" then return end
        local name=basename(record.file); if not name then return end
        local target=root.."/"..name
        if U.file_exists(target) then
            local stem,ext=name:match("^(.*)(%.epub)$")
            target=root.."/"..tostring(stem or name).." [迁移]"..tostring(ext or "")
        end
        local ok=os.rename(record.file,target)
        if not ok then ok=U.copy_file(record.file,target); if ok then os.remove(record.file) end end
        if ok then record.file=target; record.directory=root; changed=true end
    end
    for _,book in pairs(all) do
        for _,record in pairs(book.variants or {}) do move_record(record) end
        for _,row in pairs(book.chapters or {}) do for _,record in pairs(row or {}) do move_record(record) end end
        if changed then book.directory=root end
    end
    if changed then self.db:saveSetting("library",all) end
end
function Store:library() return self:get("library",{}) end
function Store:book(id) return self:library()[tostring(id)] end
function Store:save_book(id,patch)
    local all=self:library(); local key=tostring(id); all[key]=U.merge(all[key] or {book_id=key,variants={},chapters={}},patch or {}); self:set("library",all); return all[key]
end
function Store:save_variant(id,kind,record)
    local b=self:book(id) or {book_id=tostring(id),variants={},chapters={}}; b.variants=b.variants or {}; b.variants[kind]=U.copy(record); return self:save_book(id,b)
end
function Store:save_chapter_variant(id,uid,kind,record)
    local b=self:book(id) or {book_id=tostring(id),variants={},chapters={}}; b.chapters=b.chapters or {}; local key=tostring(uid); b.chapters[key]=b.chapters[key] or {}; b.chapters[key][kind]=U.copy(record); return self:save_book(id,b)
end
function Store:variant(id,kind) local b=self:book(id); return b and b.variants and b.variants[kind] end
function Store:chapter_variant(id,uid,kind) local b=self:book(id); return b and b.chapters and b.chapters[tostring(uid)] and b.chapters[tostring(uid)][kind] end
local function add_unique_path(out,seen,path)
    path=tostring(path or "")
    if path~="" and not seen[path] then seen[path]=true; out[#out+1]=path end
end
function Store:partial_cache_paths(id)
    local root=self:book_cache_path(id)
    local out={}
    if lfs.attributes(root,"mode")~="directory" then return out end
    local ok,iter,state=pcall(lfs.dir,root)
    if not ok or type(iter)~="function" then return out end
    for name in iter,state do
        if name~="." and name~=".." and tostring(name):match("^%.pickthought%-partial%-") then out[#out+1]=root.."/"..name end
    end
    table.sort(out)
    return out
end
function Store:book_has_partial_cache(id) return #self:partial_cache_paths(id)>0 end
function Store:variant_paths(id,kind)
    local r=self:variant(id,kind)
    return r and r.file and {r.file} or {}
end
function Store:chapter_paths(id,uid)
    local b=self:book(id); local row=b and b.chapters and b.chapters[tostring(uid)]
    local out,seen={},{}
    for _,r in pairs(row or {}) do add_unique_path(out,seen,r and r.file) end
    return out
end
function Store:book_paths(id,include_cache)
    local b=self:book(id)
    local out,seen={},{}
    if b then
        for _,r in pairs(b.variants or {}) do add_unique_path(out,seen,r and r.file) end
        for _,row in pairs(b.chapters or {}) do for _,r in pairs(row or {}) do add_unique_path(out,seen,r and r.file) end end
    end
    if include_cache~=false then add_unique_path(out,seen,self:book_cache_path(id)) end
    return out
end
function Store:all_download_paths(include_covers)
    local out,seen={},{}
    for id,_ in pairs(self:library()) do for _,path in ipairs(self:book_paths(id,true)) do add_unique_path(out,seen,path) end end
    add_unique_path(out,seen,self.cache_books_dir)
    if include_covers then add_unique_path(out,seen,self.covers_dir) end
    return out
end
local function book_has_records(book)
    if type(book)~="table" then return false end
    if next(book.variants or {}) then return true end
    for _,row in pairs(book.chapters or {}) do if next(row or {}) then return true end end
    return false
end
function Store:forget_variant(id,kind)
    local all=self:library(); local key=tostring(id); local b=all[key]; if not b then return end
    if b.variants then b.variants[kind]=nil end
    if not book_has_records(b) and not self:book_has_partial_cache(id) then all[key]=nil end
    self:set("library",all)
end
function Store:forget_chapter(id,uid,kind)
    local all=self:library(); local key=tostring(id); local b=all[key]; local row=b and b.chapters and b.chapters[tostring(uid)]
    if row then row[kind]=nil; if next(row)==nil then b.chapters[tostring(uid)]=nil end end
    if b and not book_has_records(b) and not self:book_has_partial_cache(id) then all[key]=nil end
    self:set("library",all)
end
function Store:forget_chapter_all(id,uid)
    local all=self:library(); local key=tostring(id); local b=all[key]
    if b and b.chapters then b.chapters[tostring(uid)]=nil end
    if b and not book_has_records(b) and not self:book_has_partial_cache(id) then all[key]=nil end
    self:set("library",all)
end
function Store:forget_book(id) local all=self:library(); all[tostring(id)]=nil; self:set("library",all) end
function Store:forget_all_books() self:set("library",{}) end
function Store:prune_missing_files()
    local all=self:library(); local changed=false
    for id,b in pairs(all) do
        for kind,r in pairs(b.variants or {}) do if not (r and r.file and U.file_exists(r.file)) then b.variants[kind]=nil; changed=true end end
        for uid,row in pairs(b.chapters or {}) do
            for kind,r in pairs(row or {}) do if not (r and r.file and U.file_exists(r.file)) then row[kind]=nil; changed=true end end
            if next(row or {})==nil then b.chapters[uid]=nil; changed=true end
        end
        if not book_has_records(b) and not self:book_has_partial_cache(id) then all[id]=nil; changed=true end
    end
    if changed then self:set("library",all) end
    return changed
end
function Store:delete_variant(id,kind)
    for _,path in ipairs(self:variant_paths(id,kind)) do U.remove_tree(path) end
    self:forget_variant(id,kind)
end
function Store:delete_chapter(id,uid,kind)
    local r=self:chapter_variant(id,uid,kind); if r and r.file then U.remove_tree(r.file) end
    self:forget_chapter(id,uid,kind)
end
function Store:delete_book(id)
    for _,path in ipairs(self:book_paths(id,true)) do U.remove_tree(path) end
    self:forget_book(id)
end
function Store:all_books()
    local o={}; for id,b in pairs(self:library()) do local x=U.copy(b); x.book_id=x.book_id or id; o[#o+1]=x end
    table.sort(o,function(a,b) return tonumber(a.updated_at or a.downloaded_at or 0)>tonumber(b.updated_at or b.downloaded_at or 0) end); return o
end
local function normalize_path(path)
    local value=tostring(path or ""):gsub("\\","/"):gsub("/+","/")
    value=value:gsub("/%./","/")
    while value:find("/[^/]+/%.%./") do value=value:gsub("/[^/]+/%.%./","/") end
    if #value>1 then value=value:gsub("/$","") end
    return value
end

local function read_pipe(command)
    local pipe=io.popen(command,"r")
    if not pipe then return nil end
    local data=pipe:read("*a")
    pipe:close()
    if data=="" then return nil end
    return data
end

local function xml_unescape(value)
    return tostring(value or "")
        :gsub("&lt;", "<"):gsub("&gt;", ">")
        :gsub("&quot;", '"'):gsub("&apos;", "'")
        :gsub("&amp;", "&")
end

local function filename_key(path)
    local name=tostring(basename(path) or ""):lower()
    -- Treat harmless spacing differences around the variant suffix as the same
    -- filename, but only relink when the match is unique.
    return name:gsub("[%s　]+", "")
end

function Store:epub_identity(path)
    if not path or not U.file_exists(path) or not tostring(path):lower():match("%.epub$") then return nil end
    local quoted=U.shell_quote(path)
    local identity={}
    local raw=read_pipe("unzip -p "..quoted.." OEBPS/pickthought.json 2>/dev/null")
    if raw then
        local ok,value=pcall(Json.decode,raw)
        if ok and type(value)=="table" then identity=U.copy(value) end
    end
    local opf=read_pipe("unzip -p "..quoted.." OEBPS/package.opf 2>/dev/null")
    if opf then
        identity.book_id=identity.book_id
            or opf:match("pickthought://book/([^<%s]+)")
            or opf:match("pickthought%-([^<%s]+)")
        identity.title=identity.title or xml_unescape(opf:match("<dc:title[^>]*>(.-)</dc:title>"))
        identity.author=identity.author or xml_unescape(opf:match("<dc:creator[^>]*>(.-)</dc:creator>"))
    end
    if tostring(identity.book_id or "")~="" then return identity end

    -- PickThought-generated EPUB entries are stored without compression. If a
    -- device lacks a usable unzip -p, inspect only the tail instead of loading
    -- a large book into memory.
    local file=io.open(path,"rb")
    if file then
        local size=file:seek("end") or 0
        file:seek("set",math.max(0,size-1024*1024))
        local tail=file:read("*a") or ""
        file:close()
        local id=tail:match('"book_id"%s*:%s*"([^"]+)"') or tail:match("pickthought://book/([^<%s]+)")
        if id then
            return {
                book_id=id,
                variant=tail:match('"variant"%s*:%s*"([^"]+)"'),
                standalone=tail:match('"standalone"%s*:%s*true')~=nil,
            }
        end
    end
    return nil
end

function Store:identify_file(path,relink)
    if not path then return nil end
    local normalized=normalize_path(path)
    local current_size=U.file_size(path)
    local all=self:library()
    local function match_record(record)
        return type(record)=="table" and record.file and normalize_path(record.file)==normalized
    end
    local function relink_record(book,record)
        if not relink or type(record)~="table" then return end
        if record.file~=path then
            record.file=path
            record.directory=path:match("^(.*)/[^/]+$")
        end
        record.file_size=current_size or record.file_size
        book.directory=record.directory or book.directory
        self:set("library",all)
    end
    for _,b in pairs(all) do
        for kind,r in pairs(b.variants or {}) do
            if match_record(r) then relink_record(b,r); return b,r,kind end
        end
        for uid,row in pairs(b.chapters or {}) do
            for kind,r in pairs(row or {}) do
                if match_record(r) then
                    r.chapter_uid=uid
                    relink_record(b,r)
                    return b,r,kind
                end
            end
        end
    end

    local meta=self:epub_identity(path)
    -- For older files without embedded identity, a harmless spacing-only rename
    -- can still be repaired. Relink only one unambiguous filename candidate.
    local wanted_name=filename_key(path)
    if not meta and wanted_name~="" then
        local matches={}
        for _,b in pairs(all) do
            for kind,r in pairs(b.variants or {}) do
                if type(r)=="table" and filename_key(r.file)==wanted_name then
                    matches[#matches+1]={book=b,record=r,kind=kind}
                end
            end
            for uid,row in pairs(b.chapters or {}) do
                for kind,r in pairs(row or {}) do
                    if type(r)=="table" and filename_key(r.file)==wanted_name then
                        matches[#matches+1]={book=b,record=r,kind=kind,uid=uid}
                    end
                end
            end
        end
        if #matches==1 then
            local found=matches[1]
            if found.uid then found.record.chapter_uid=found.uid end
            relink_record(found.book,found.record)
            return found.book,found.record,found.kind
        end
    end

    local id=meta and tostring(meta.book_id or "") or ""
    if id=="" then return nil end
    local kind=tostring(meta.variant or "")
    if kind=="" then kind="notes" end
    local b=all[id]
    local chapters=type(meta.chapters)=="table" and meta.chapters or {}
    local standalone=meta.standalone==true
    local uid=tostring(meta.chapter_uid or ((chapters[1] and (chapters[1].uid or chapters[1].chapter_uid)) or ""))
    local record

    if b then
        if standalone then
            local row=uid~="" and b.chapters and b.chapters[uid] or nil
            record=row and (row[kind] or row.notes or row.clean)
            if record then record.chapter_uid=uid end
        else
            record=b.variants and (b.variants[kind] or b.variants.notes or b.variants.clean)
        end
        -- Metadata proves the book identity. If its old library row is missing,
        -- recover a minimal row instead of treating the EPUB as an external book.
        if not record then
            record={
                book_id=id,title=meta.title or b.title or basename(path),author=meta.author or b.author or "",
                file=path,directory=path:match("^(.*)/[^/]+$"),variant=kind,
                downloaded_at=tonumber(meta.generated_at) or os.time(),chapter_map=chapters,
                chapter_count=#chapters,complete=meta.complete~=false,file_size=current_size,
            }
            if standalone and uid~="" then
                record.chapter_uid=uid
                b.chapters=b.chapters or {}; b.chapters[uid]=b.chapters[uid] or {}; b.chapters[uid][kind]=record
            else
                b.variants=b.variants or {}; b.variants[kind]=record
            end
        end
    else
        b={
            book_id=id,title=meta.title or tostring(basename(path) or id):gsub("%.epub$",""),
            author=meta.author or "",variants={},chapters={},catalog=chapters,
            directory=path:match("^(.*)/[^/]+$"),updated_at=os.time(),recovered=true,
        }
        record={
            book_id=id,title=b.title,author=b.author,file=path,directory=b.directory,
            variant=kind,downloaded_at=tonumber(meta.generated_at) or os.time(),
            chapter_map=chapters,chapter_count=#chapters,complete=meta.complete~=false,
            file_size=current_size,recovered=true,
        }
        if standalone and uid~="" then
            record.chapter_uid=uid; b.chapters[uid]={[kind]=record}
        else
            b.variants[kind]=record
        end
        all[id]=b
    end

    if record and relink then relink_record(b,record) end
    return b,record,kind
end

function Store:file_record(path)
    return self:identify_file(path,true)
end

function Store:mark_last_read(id,path,progress)
    id=tostring(id or "")
    if id=="" then return end
    local patch={last_read_at=os.time()}
    if path then patch.last_read_path=path end
    if progress~=nil then patch.progress_local_percent=tonumber(progress) end
    self:save_session(id,patch)
end
function Store:session(id) return self:get("sessions",{})[tostring(id)] end
function Store:save_session(id,patch) local a=self:get("sessions",{}); local k=tostring(id); a[k]=U.merge(a[k] or {},patch or {}); self:set("sessions",a); return a[k] end
function Store:clear_session(id) local a=self:get("sessions",{}); a[tostring(id)]=nil; self:set("sessions",a) end
function Store:shelf_cache() return U.merge(defaults.shelf_cache,self:get("shelf_cache",{})) end
function Store:save_shelf_cache(v) self:set("shelf_cache",U.merge(defaults.shelf_cache,v or {})) end
function Store:update_cached_progress(id,percent)
    id=tostring(id or "")
    percent=tonumber(percent)
    if id=="" or percent==nil then return false end
    local cache=self:shelf_cache()
    local changed=false
    for _,group in ipairs({cache.books or {},cache.mp or {}}) do
        for _,row in ipairs(group) do
            if tostring(row.bookId or row.book_id or "")==id then
                row.progress=U.clamp(percent,0,100)
                row.finished=row.progress>=100
                changed=true
            end
        end
    end
    if changed then self:save_shelf_cache(cache) end
    return changed
end
function Store:cover_guard() return U.merge(defaults.cover_guard,self:get("cover_guard",{})) end
function Store:save_cover_guard(v) self:set("cover_guard",U.merge(defaults.cover_guard,v or {})) end
function Store:cover_path(id) return self.covers_dir.."/"..U.id_name(id)..".img" end
function Store:update_state() return self:get("update_state",{}) end
function Store:save_update_state(v) self:set("update_state",v or {}) end
function Store:update_info() return self:get("update_info",{}) end
function Store:save_update_info(v) self:set("update_info",v or {}) end
function Store:download_state()
    local raw=U.read_file(self.download_state_path,true)
    if not raw or raw=="" then return {} end
    local ok,value=pcall(Json.decode,raw)
    return ok and type(value)=="table" and value or {}
end
function Store:save_download_state(value)
    local ok,encoded=pcall(Json.encode,value or {})
    if not ok then return false,encoded end
    return U.atomic_write(self.download_state_path,encoded,true)
end
function Store:clear_download_state() os.remove(self.download_state_path) end
function Store:download_queue() return self:get("download_queue",{}) end
function Store:save_download_queue(queue) self:set("download_queue",type(queue)=="table" and queue or {}) end
function Store:enqueue_download(job)
    local queue=self:download_queue(); queue[#queue+1]=U.copy(job or {}); self:save_download_queue(queue); return #queue
end
function Store:dequeue_download()
    local queue=self:download_queue(); if #queue==0 then return nil end
    local job=table.remove(queue,1); self:save_download_queue(queue); return job
end
function Store:remove_queued_download(index)
    local queue=self:download_queue(); index=tonumber(index); if not index or not queue[index] then return false end
    table.remove(queue,index); self:save_download_queue(queue); return true
end
function Store:pending_installs() return self:get("pending_installs",{}) end
function Store:save_pending_installs(rows) self:set("pending_installs",type(rows)=="table" and rows or {}) end
function Store:add_pending_install(book_id,kind,chapter_uid,record)
    local rows=self:pending_installs()
    local key=table.concat({tostring(book_id or ""),tostring(chapter_uid or "full"),tostring(kind or "")},":")
    local item={key=key,book_id=tostring(book_id or ""),kind=tostring(kind or ""),
        chapter_uid=chapter_uid and tostring(chapter_uid) or nil,file=record and record.file,
        pending_file=record and record.pending_file,created_at=os.time()}
    local replaced=false
    for index,row in ipairs(rows) do
        if tostring(row.key or "")==key then rows[index]=item; replaced=true; break end
    end
    if not replaced then rows[#rows+1]=item end
    self:save_pending_installs(rows)
    return item
end
function Store:remove_pending_install(book_id,kind,chapter_uid)
    local rows,out=self:pending_installs(),{}
    local key=table.concat({tostring(book_id or ""),tostring(chapter_uid or "full"),tostring(kind or "")},":")
    local changed=false
    for _,row in ipairs(rows) do
        if tostring(row.key or "")==key then changed=true else out[#out+1]=row end
    end
    if changed then self:save_pending_installs(out) end
    return changed
end
function Store:prune_pending_installs()
    local rows,out=self:pending_installs(),{}
    local changed=false
    for _,row in ipairs(rows) do
        if row.pending_file and U.file_exists(row.pending_file) then out[#out+1]=row else changed=true end
    end
    if changed then self:save_pending_installs(out) end
    return out
end
function Store:last_cleanup_result() return self:get("last_cleanup_result",{}) end
function Store:save_cleanup_result(result) self:set("last_cleanup_result",type(result)=="table" and result or {}) end
function Store:is_read_report_consumed(stamp)
    stamp=tostring(stamp or "")
    if stamp=="" then return false end
    local rows=self:get("read_report_consumed",{})
    return rows[stamp]~=nil
end
function Store:mark_read_report_consumed(stamp)
    stamp=tostring(stamp or "")
    if stamp=="" then return end
    local rows=self:get("read_report_consumed",{})
    rows[stamp]=os.time()
    local ordered={}
    for key,at in pairs(rows) do ordered[#ordered+1]={key=key,at=tonumber(at) or 0} end
    table.sort(ordered,function(a,b) return a.at>b.at end)
    for index=#ordered,21,-1 do rows[ordered[index].key]=nil end
    self:set("read_report_consumed",rows)
end
function Store:flush() self.db:flush() end
function Store:reload()
    self.db = LuaSettings:open(self.settings_path)
    return self
end
return Store
