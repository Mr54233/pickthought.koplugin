local ConfirmBox=require("ui/widget/confirmbox")
local Dispatcher=require("dispatcher")
local InfoMessage=require("ui/widget/infomessage")
local InputDialog=require("ui/widget/inputdialog")
local Menu=require("ui/widget/menu")
local UIManager=require("ui/uimanager")
local WidgetContainer=require("ui/widget/container/widgetcontainer")
local logger=require("logger")
local Config=require("pickthought.config")
local Text=require("pickthought.text")
local U=require("pickthought.util")
local Store=require("pickthought.store")
local Http=require("pickthought.http")
local Api=require("pickthought.api")
local Auth=require("pickthought.auth")
local Updater=require("pickthought.updater")
local Cookies=require("pickthought.cookies")
local Thoughts=require("pickthought.thoughts")
local Binding=require("pickthought.binding")
local SyncTask=require("pickthought.sync_task")
local SyncProgress=require("pickthought.sync_progress")
local SyncReport=require("pickthought.sync_report")
local BatchSync=require("pickthought.batch_sync")
local AnnotationCompat=require("pickthought.annotation_compat")
local AnnotationStyle=require("pickthought.annotation_style")
local Event=require("ui/event")
local _=Text.tr
local unpack_args=unpack or table.unpack
local source=debug.getinfo(1,"S").source:gsub("^@",""); local ROOT=source:match("^(.*)/main%.lua$") or "."
local Plugin=WidgetContainer:extend{name="pickthought",is_doc_only=false,version=Config.VERSION}

local ANNOTATION_STYLE_LABELS={
    default="默认样式",
    thin_solid="细实线",
    thin_dashed="细虚线",
    hidden="隐藏划线",
}

local function sanitize_saved_auth(store)
    local auth=store:auth()
    local cleaned,changed=Cookies.sanitize(auth.cookies or {})
    if changed then
        auth.cookies=cleaned
        store:save_auth(auth)
        logger.info("[撷思][Auth] startup cookie cleanup",
            "names=",table.concat(Cookies.names(cleaned),","))
    end
end

function Plugin:init()
    AnnotationCompat.install()
    math.randomseed(os.time()+math.floor(collectgarbage("count")))
    self.store=Store:new()
    logger.info("[撷思] initialized", "version=", tostring(Config.VERSION),
        "schema=", tostring(Config.SCHEMA), "root=", tostring(ROOT))
    sanitize_saved_auth(self.store)
    self.http=Http:new(self.store)
    self.api=Api:new(self.http,self.store)
    self.auth_flow=Auth:new(self.http,self.store,self)
    self.updater=Updater:new(self.http,self.store,self.version,ROOT)
    self.sync_task=SyncTask:new(self.store)
    UIManager:scheduleIn(0.8,function() self:_recover_sync_state() end)
    -- 自动检查更新默认关,用户在设置里开启才生效
    if self.store:preferences().auto_check_update==true then
        UIManager:scheduleIn(5,function() self:maybe_auto_check_update(false) end)
    end
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    local state=self.updater:startup()
    if state=="updated" then UIManager:scheduleIn(1,function() self:toast(_("Update installed"),3) end) end
end

function Plugin:onDispatcherRegisterActions() Dispatcher:registerAction("pickthought_show",{category="none",event="Show撷思",title=Config.NAME,filemanager=true,reader=true}) end
function Plugin:addToMainMenu(items) items.pickthought={text=Config.NAME,sorting_hint="tools",sub_item_table_func=function() return self.ui.document and self:reader_menu() or self:home_menu() end} end

function Plugin:info(t) UIManager:show(InfoMessage:new{text=tostring(t or "")}) end
function Plugin:toast(t,s) UIManager:show(InfoMessage:new{text=tostring(t or ""),timeout=s or 2}) end
function Plugin:safe(label,fn) return function(...) local a={...}; local ok,e=xpcall(function() return fn(unpack_args(a)) end,debug.traceback); if not ok then logger.err("[撷思]",label,e); self:info(_("Operation failed")..":\n"..U.first_line(e)) end end end
function Plugin:is_online() local ok,N=pcall(require,"ui/network/manager"); if not ok or not N or not N.isOnline then return true end; local g,v=pcall(N.isOnline,N); return not g or v==true end
function Plugin:online(label,fn) if not self:is_online() then self:info(_("Network unavailable")); return end; UIManager:scheduleIn(.05,self:safe(label,fn)) end
function Plugin:list(title,items,empty)
    if not items or #items==0 then self:info(empty or _("No items")); return end
    -- 普通 Menu 选中后不会自动关闭:包一层 callback,选中先关菜单再执行。
    local menu
    local wrapped={}
    for i,item in ipairs(items) do
        local copy={}; for k,v in pairs(item) do copy[k]=v end
        if type(copy.callback)=="function" then
            local original=copy.callback
            copy.callback=function(...) if menu then UIManager:close(menu) end; return original(...) end
        end
        wrapped[i]=copy
    end
    menu=Menu:new{title=title,item_table=wrapped,is_borderless=true,title_bar_fm_style=true}
    UIManager:show(menu)
end
function Plugin:logged_in() local a=self.store:auth(); return a.api_key~="" and next(a.cookies or {})~=nil end
function Plugin:require_login() if not self:logged_in() then self:info(_("Not logged in")); return false end return true end

function Plugin:_sync_status_item()
    if not (self.sync_task and self.sync_task:busy()) then return nil end
    return {text="同步进行中…(点按查看进度)",callback=self:safe("sync_status",function() self:_show_active_sync_dialog() end)}
end

function Plugin:home_menu()
    local items={}
    items[#items+1]=self:_sync_status_item()
    items[#items+1]={text="选择书籍同步想法",callback=self:safe("fm_sync",function()
        self:pick_book("选择要同步的 EPUB(长按文件名选中)",function(path) self:sync_entry(path) end)
    end)}
    items[#items+1]={text="选择书籍绑定微信读书",callback=self:safe("fm_bind",function()
        self:pick_book("选择要绑定的 EPUB(长按文件名选中)",function(path) self:bind_book(path) end)
    end)}
    items[#items+1]={text="选择书籍更多操作(重注 / 续拉 / 还原)",callback=self:safe("fm_actions",function()
        self:pick_book("选择 EPUB(长按文件名选中)",function(path) self:book_actions(path) end)
    end)}
    items[#items+1]={text="账户",sub_item_table_func=function() return self:account_menu() end}
    items[#items+1]={text="设置",sub_item_table_func=function() return self:settings_menu() end}
    items[#items+1]={text="更新与关于",sub_item_table_func=function() return self:update_about_menu() end}
    return items
end

function Plugin:reader_menu()
    local items={}
    items[#items+1]=self:_sync_status_item()
    items[#items+1]={text="绑定微信读书",callback=self:safe("bind",function() self:bind_book() end)}
    items[#items+1]={text="同步划线与想法",callback=self:safe("sync_thoughts",function() self:sync_thoughts() end)}
    local doc_path=self:current_doc_path()
    local doc_bound=doc_path and Binding.get(self.store,doc_path)
    if doc_bound then
        items[#items+1]={text="划线样式（"..self:annotation_style_label().."）",
            sub_item_table_func=function() return self:annotation_style_menu() end}
        local state=self:_sync_state(doc_bound.book_id)
        if state and (tonumber(state.pending) or 0)>0 then
            items[#items+1]={text=string.format("继续拉取后续章节(还剩 %d 章)",state.pending),
                callback=self:safe("continue_sync",function() self:sync_entry(doc_path,"sync") end)}
        end
    end
    if doc_path and self:_has_reinject_cache(doc_path) then
        items[#items+1]={text="重新注入(用上次数据,离线)",callback=self:safe("reinject",function() self:sync_entry(doc_path,"reinject") end)}
    end
    if doc_bound or (doc_path and U.file_exists(doc_path..".orig")) then
        items[#items+1]={text="重置本书(清数据+还原原版)",callback=self:safe("reset",function() self:reset_book_data(doc_path) end)}
    end
    items[#items+1]={text="账户",sub_item_table_func=function() return self:account_menu() end}
    items[#items+1]={text="设置",sub_item_table_func=function() return self:settings_menu() end}
    items[#items+1]={text="更新与关于",sub_item_table_func=function() return self:update_about_menu() end}
    return items
end

-- 文件管理器里直接选一本 EPUB,不必先打开书。
function Plugin:pick_book(title,on_pick)
    local PathChooser=require("ui/widget/pathchooser")
    local start_dir=_G.G_reader_settings and _G.G_reader_settings:readSetting("home_dir") or nil
    if not start_dir then
        local ok,fmutil=pcall(require,"apps/filemanager/filemanagerutil")
        if ok and type(fmutil.getDefaultDir)=="function" then start_dir=fmutil.getDefaultDir() end
    end
    local chooser=PathChooser:new{
        title=title,
        path=start_dir,
        select_directory=false,
        select_file=true,
        file_filter=function(filename) return tostring(filename):lower():match("%.epub$")~=nil end,
        onConfirm=function(path)
            -- PathChooser 的 Choose 回调是先跑 onConfirm、再连关确认框和全屏
            -- 选择器;两层关闭各排一次全屏重绘,单推一拍弹的窗口仍会被第二波
            -- 重绘顶掉(真机:操作面板一闪就回主页;进度框当初能活是因为
            -- 同步流程内部又推了一拍)。统一连推两拍,等重绘全部落地。
            UIManager:nextTick(function()
                UIManager:nextTick(function()
                    if tostring(path):lower():find(".撷思.epub",1,true) then
                        self:info("这是撷思版副本,请选择原书")
                        return
                    end
                    on_pick(path)
                end)
            end)
        end,
    }
    UIManager:show(chooser)
end

-- 文件管理器选书后的操作面板:与阅读器菜单同一套能力与判定,
-- 不打开书也能续拉/离线重注/还原。
function Plugin:book_actions(path)
    local ButtonDialog=require("ui/widget/buttondialog")
    local bound=Binding.get(self.store,path)
    local dialog
    local function act(fn) return function() UIManager:close(dialog); fn() end end
    local rows={}
    rows[#rows+1]={{text="同步划线与想法",callback=act(function() self:sync_entry(path) end)}}
    if bound then
        local state=self:_sync_state(bound.book_id)
        if state and (tonumber(state.pending) or 0)>0 then
            rows[#rows+1]={{text=string.format("继续拉取后续章节(还剩 %d 章)",state.pending),
                callback=act(function() self:sync_entry(path,"sync") end)}}
        end
        rows[#rows+1]={{text="清理本书数据",callback=act(function() self:reset_book_data(path) end)}}
    end
    if self:_has_reinject_cache(path) then
        rows[#rows+1]={{text="重新注入(用上次数据,离线)",callback=act(function() self:sync_entry(path,"reinject") end)}}
    end
    if bound or U.file_exists(path..".orig") then
        rows[#rows+1]={{text="重置本书(清数据+还原原版)",callback=act(function() self:reset_book_data(path) end)}}
    end
    rows[#rows+1]={{text=bound and "重新绑定微信读书" or "绑定微信读书",
        callback=act(function() self:bind_book(path) end)}}
    rows[#rows+1]={{text="取消",callback=function() UIManager:close(dialog) end}}
    local title=self:doc_title_guess(path)
    if bound then title=title.."\n已绑定:"..tostring(bound.title or bound.book_id) end
    dialog=ButtonDialog:new{title=title,buttons=rows}
    UIManager:show(dialog)
end

-- ===== 绑定微信读书 =====
function Plugin:current_doc_path()
    local doc=self.ui and self.ui.document
    return doc and doc.file or nil
end

function Plugin:doc_title_guess(path)
    if not path or path==self:current_doc_path() then
        local props=(self.ui and self.ui.doc_props) or {}
        local title=U.trim(tostring(props.display_title or props.title or ""))
        if title~="" then return title end
    end
    local name=tostring(path or self:current_doc_path() or ""):match("([^/\\]+)$") or ""
    return (name:gsub("%.[eE][pP][uU][bB]$",""))
end

function Plugin:bind_book(path,on_bound)
    path=path or self:current_doc_path()
    if not path then self:info("请先打开一本本地书") return end
    local current=Binding.get(self.store,path)
    if not current then self:bind_search(path,on_bound) return end
    local ButtonDialog=require("ui/widget/buttondialog")
    local display=tostring(current.title or current.book_id or "")
    if tostring(current.author or "")~="" then display=display.." · "..tostring(current.author) end
    local dialog
    dialog=ButtonDialog:new{
        title="当前绑定:\n"..display,
        buttons={
            {{text="重新绑定",callback=function() UIManager:close(dialog); self:bind_search(path,on_bound) end}},
            {{text="解除绑定",callback=function() UIManager:close(dialog); Binding.clear(self.store,path); self:toast("已解除绑定") end}},
            {{text="取消",callback=function() UIManager:close(dialog) end}},
        },
    }
    UIManager:show(dialog)
end

function Plugin:bind_search(path,on_bound)
    if not self:require_login() then return end
    local d
    d=InputDialog:new{title="搜索微信读书",input=self:doc_title_guess(path),buttons={{
        {text="取消",id="close",callback=function() UIManager:close(d) end},
        {text="搜索",is_enter_default=true,callback=function()
            local q=U.trim(d:getInputText()); UIManager:close(d)
            if q=="" then self:info("请输入书名") return end
            self:online("bind_search",function()
                -- 先把「正在搜索」画上屏,再发阻塞请求(主线程同步 http)。
                local searching=InfoMessage:new{text="正在搜索「"..q.."」…"}
                UIManager:show(searching)
                UIManager:scheduleIn(0.1,self:safe("bind_search_run",function()
                local ok,data=pcall(function() return self.api:search(q) end)
                UIManager:close(searching)
                if not ok then self:info("搜索失败:\n"..U.first_line(data)) return end
                local rows=Binding.normalize_search(data)
                if #rows==0 then self:info("没有搜到「"..q.."」,换个关键词试试") return end
                local menu
                local items={}
                for _,row in ipairs(rows) do
                    local label=row.title~="" and row.title or row.book_id
                    if row.author~="" then label=label.." · "..row.author end
                    items[#items+1]={text=label,callback=function()
                        if menu then UIManager:close(menu) end
                        Binding.save(self.store,path,{book_id=row.book_id,title=row.title,author=row.author})
                        self:toast("已绑定:"..(row.title~="" and row.title or row.book_id))
                        if on_bound then on_bound() end
                    end}
                end
                menu=Menu:new{title="选择要绑定的书",item_table=items,is_borderless=true,title_bar_fm_style=true}
                UIManager:show(menu)
                end))
            end)
        end},
    }}}
    UIManager:show(d); d:onShowKeyboard()
end

function Plugin:account_menu()
    local out={
        {text=_("QR login"),callback=self:safe("login",function() self.auth_flow:start() end)},
        {text=_("Manual credentials"),callback=self:safe("manual",function() self:manual_credentials() end)},
        {text=_("Account status"),callback=function() local a=self.store:auth(); self:info((self:logged_in() and _("Logged in") or _("Not logged in")).."\n"..tostring(a.account.name or "").."\nVID: "..tostring(a.account.vid or "")) end},
    }
    if self:logged_in() then out[#out+1]={text=_("Clear account data"),callback=function() UIManager:show(ConfirmBox:new{text="清除当前账户信息？\n\n将退出微信读书账户。",ok_callback=function() self.auth_flow:cancel(); self.store:clear_auth(); self:toast(_("Logout")) end}) end} end
    return out
end

function Plugin:manual_credentials()
    local d; d=InputDialog:new{title=_("Enter API key"),input=self.store:auth().api_key or "",buttons={{{text=_("Cancel"),id="close",callback=function() UIManager:close(d) end},{text=_("Confirm"),is_enter_default=true,callback=function() local key=U.trim(d:getInputText()); UIManager:close(d); self:manual_cookie(key) end}}}}; UIManager:show(d); d:onShowKeyboard()
end

function Plugin:manual_cookie(key)
    local d; d=InputDialog:new{title=_("Enter Cookie header"),input="",buttons={{{text=_("Cancel"),id="close",callback=function() UIManager:close(d) end},{text=_("Confirm"),is_enter_default=true,callback=function() local jar=Cookies.parse_header(d:getInputText()); self.store:save_auth({api_key=key,cookies=jar,account={name="Manual",vid=jar.wr_vid or "",logged_at=os.time()}}); UIManager:close(d); self:toast(_("Logged in")) end}}}}; UIManager:show(d); d:onShowKeyboard()
end

function Plugin:settings_menu()
    return {
        {text="划线样式",sub_item_table_func=function() return self:annotation_style_menu() end},
        {text="想法弹窗字体",sub_item_table_func=function() return self:thought_font_menu() end},
        {text="阅读时自动分批拉取后续章节",checked_func=function()
            return BatchSync.auto_enabled(self.store:preferences())
        end,callback=function()
            local p=self.store:preferences()
            p.auto_batch_sync_opt_in=not BatchSync.auto_enabled(p)
            self.store:save_preferences(p)
        end},
        {text="同步时保持唤醒(防锁屏中断)",checked_func=function()
            return self.store:preferences().sync_keep_awake~=false
        end,callback=function()
            local p=self.store:preferences()
            local enabled=not (p.sync_keep_awake~=false)
            p.sync_keep_awake=enabled
            self.store:save_preferences(p)
            -- 对进行中的任务即时生效,不必等下次同步。
            if self.sync_task then self.sync_task:set_keep_awake(enabled) end
        end},
    }
end

function Plugin:annotation_style_label()
    local key=AnnotationStyle.normalize_runtime_style(
        self.store:preferences().annotation_style)
    return ANNOTATION_STYLE_LABELS[key] or ANNOTATION_STYLE_LABELS.default
end

function Plugin:annotation_style_menu()
    local choices={
        {"default",ANNOTATION_STYLE_LABELS.default},
        {"thin_solid",ANNOTATION_STYLE_LABELS.thin_solid},
        {"thin_dashed",ANNOTATION_STYLE_LABELS.thin_dashed},
        {"hidden",ANNOTATION_STYLE_LABELS.hidden},
    }
    local rows={}
    for _,choice in ipairs(choices) do
        local key,label=choice[1],choice[2]
        rows[#rows+1]={text=label,radio=true,checked_func=function()
            return AnnotationStyle.normalize_runtime_style(
                self.store:preferences().annotation_style) == key
        end,callback=function()
            local p=self.store:preferences()
            p.annotation_style=key
            self.store:save_preferences(p)
            local ok,err=self:apply_annotation_style()
            if ok then
                self:toast("划线样式已切换为："..label)
            elseif self.ui and self.ui.document then
                self:info("划线样式已保存,但当前页面未刷新：\n"..tostring(err or "未知错误"))
            else
                self:toast("划线样式已保存,下次打开书籍时生效")
            end
        end}
    end
    return rows
end

function Plugin:_annotation_stylesheet()
    local typeset=self.ui and self.ui.typeset
    if not typeset or type(typeset.css)~="string" or typeset.css=="" then
        return nil, "阅读器样式表不可用"
    end
    local tweaks=""
    local styletweak=self.ui.styletweak
    if styletweak and type(styletweak.getCssText)=="function" then
        tweaks=styletweak:getCssText() or ""
    end
    local style=AnnotationStyle.normalize_runtime_style(
        self.store:preferences().annotation_style)
    return typeset.css,tweaks.."\n"..AnnotationStyle.runtime_css(style),style
end

-- Reapply a saved style to the currently open bound EPUB. This follows the
-- upstream runtime stylesheet approach: the EPUB and its .orig backup stay
-- untouched, while the current document is reflowed in place.
function Plugin:apply_annotation_style()
    if not self.ui or not self.ui.document then
        return false, "当前没有打开的书"
    end
    local path=self:current_doc_path()
    if not path or not Binding.get(self.store,path) then
        return false, "当前书籍未绑定"
    end
    local base,stylesheet,style=self:_annotation_stylesheet()
    if not base then return false,stylesheet end
    local ok,err=pcall(function()
        self.ui.document:setStyleSheet(base,stylesheet)
        self.ui:handleEvent(Event:new("UpdatePos"))
    end)
    if not ok then
        return false,err
    end
    logger.info("[撷思][AnnotationStyle] applied", "style=",style)
    return true
end

function Plugin:thought_font_menu()
    local choices={{"standard","较小（默认）"},{"large","适中"},{"xlarge","接近正文"}}
    local rows={}
    for _,choice in ipairs(choices) do
        local key,label=choice[1],choice[2]
        rows[#rows+1]={text=label,radio=true,checked_func=function() return (self.store:preferences().thoughts or {}).font==key end,callback=function()
            local p=self.store:preferences(); p.thoughts=p.thoughts or {}; p.thoughts.font=key; self.store:save_preferences(p); self:toast("想法字体已设为："..label)
        end}
    end
    return rows
end

function Plugin:update_about_menu()
    return {
        {text="检查更新",callback=self:safe("update",function() self:check_update() end)},
        {text="重置全部书籍",callback=self:safe("clear_all",function() self:clear_all_data() end)},
        {text="当前版本 · "..tostring(self.version),enabled=false},
        {text="关于",callback=self:safe("about",function() self:show_about() end)},
    }
end

-- 启动后静默检查更新(每 24h 一次,失败 6h 后重试)。有新版 toast 提示,不弹窗。
-- 移植自 miuread maybe_auto_check_update。
function Plugin:maybe_auto_check_update(force)
    if self._auto_update_check_running then return false end
    local now = os.time()
    local interval = Config.AUTO_UPDATE_INTERVAL
    local state = self.store:get("update_check", {})
    local last = tonumber(state.last_attempt_at) or 0
    if not force and now - last < interval then return false end
    if not self:is_online() then return false end
    self._auto_update_check_running = true
    state.last_attempt_at = now
    self.store:set("update_check", state)
    UIManager:scheduleIn(0.05, self:safe("auto-update", function()
        local m = self.updater:check()
        self._auto_update_check_running = false
        local fresh = self.store:get("update_check", {})
        if m and not m.current then
            fresh.last_success_at = os.time()
            self.store:set("update_check", fresh)
            self:toast(string.format("发现新版本 %s,「更新与关于」查看", tostring(m.version or "")), 5)
        elseif m then
            fresh.last_success_at = os.time()
            self.store:set("update_check", fresh)
        else
            fresh.last_attempt_at = os.time() - (interval - Config.AUTO_UPDATE_RETRY_INTERVAL)
            self.store:set("update_check", fresh)
        end
    end))
    return true
end

function Plugin:check_update()
    if not self:is_online() then self:info(_("Network unavailable")); return end
    local Trapper=require("ui/trapper")
    Trapper:wrap(function()
        if not Trapper:info("正在检查更新…") then return end
        local m,e=self.updater:check()
        Trapper:clear()
        if not m then self:_update_fail("检查更新失败：\n"..tostring(e or "未知错误")); return end
        if m.current then self:info("当前已是最新版本\n\n当前版本："..tostring(self.version)); return end
        local text="发现新版本："..tostring(m.version)
        if m.name and tostring(m.name)~="" then text=text.."\n"..tostring(m.name) end
        if m.notes and tostring(m.notes)~="" then text=text.."\n\n更新说明：\n"..tostring(m.notes) end
        text=text.."\n\n是否下载并安装？"
        -- 推迟到协程外弹 ConfirmBox:Trapper 退出 + 菜单关闭各排一次重绘,
        -- 同步弹的窗口会被顶掉(和文管选书操作面板同一类时序 bug)。
        UIManager:nextTick(function()
            UIManager:show(ConfirmBox:new{text=text,ok_text="下载并安装",
                ok_callback=function() self:_do_update(m) end})
        end)
    end)
end

function Plugin:_do_update(m)
    local Trapper=require("ui/trapper")
    Trapper:wrap(function()
        local path
        local ok_dl,err=pcall(function()
            path=self.updater:download(m, function(msg)
                if not Trapper:info(msg) then error("已取消") end
            end)
        end)
        if not ok_dl or not path then
            Trapper:clear()
            if tostring(err or ""):find("已取消") then return end
            self:_update_fail("下载失败：\n"..tostring(err or "未知错误"))
            return
        end
        if not Trapper:info("正在安装更新…") then return end
        local ok_inst,er=self.updater:install(path,m)
        Trapper:clear()
        if ok_inst then self:info("更新已安装\n\n请完全退出并重新启动 KOReader。")
        else self:_update_fail("安装失败：\n"..tostring(er)) end
    end)
end

function Plugin:_update_fail(text)
    UIManager:show(InfoMessage:new{text=tostring(text or ""),flush_events_on_show=true})
end

function Plugin:show_about()
    self:info(Config.NAME.." "..self.version.."\n\n撷思 撷思\n只同步微信读书划线与想法到本地 EPUB 副本\n\n".._("Unofficial client").."\n\n".._("This build has not been verified with every Kindle model or every WeRead book."))
end

function Plugin:onShow撷思()
    local items=self.ui.document and self:reader_menu() or self:home_menu()
    self:list(Config.NAME,items)
end

-- ===== 同步划线与想法 =====
-- 阅读器入口:后台任务同步,不影响继续阅读。
function Plugin:sync_thoughts()
    local path=self:current_doc_path()
    if not path then self:info("请先打开一本本地书") return end
    self:sync_entry(path)
end

-- 统一同步入口:阅读器与文件管理器共用,path 为原书路径。
-- mode="sync"(默认,全新拉取/续批)| "reinject"(离线,用上次数据重注)。
-- opts.background=true 时静默后台启动(自动分批用),opts.silent 抑制报错弹窗。
function Plugin:sync_entry(path,mode,opts)
    mode=mode or "sync"
    opts=opts or {}  -- 多数调用点只传 path/mode,opts 缺省空表(防 .confirmed 访问崩溃)
    if self.sync_task and self.sync_task:busy() then self:_show_active_sync_dialog() return end
    if not tostring(path or ""):lower():match("%.epub$") then self:info("只支持 EPUB 格式的本地书") return end
    if not self:require_login() then return end
    local EpubReader=require("pickthought.epub_reader")
    local available,gate_err=EpubReader.available()
    if not available then self:info(tostring(gate_err)) return end
    if mode~="reinject" and not self:is_online() then self:info(_("Network unavailable")) return end
    local bound=Binding.get(self.store,path)
    if not bound then
        -- 未绑定不再只报错:直接引导绑定,绑定完成后自动继续同步。
        UIManager:show(ConfirmBox:new{
            text="这本书还没绑定微信读书书目。\n先绑定,完成后自动开始同步?",
            ok_text="去绑定",
            ok_callback=function() self:bind_search(path,function() self:sync_entry(path,mode) end) end,
            cancel_text="取消",
        })
        return
    end
    -- 已有完整缓存(.completed)时,弹窗说明行为(从缓存继续,非清缓存重拉)。
    -- 用户确认后才同步;要全新重拉引导走「重置本书」。opts.confirmed 避免重复弹窗。
    if not opts.confirmed and mode~="reinject" then
        local completed=self.store:book_cache_path(bound.book_id).."/sync-cache/.completed"
        if U.file_exists(completed) then
            local state=self:_sync_state(bound.book_id) or {}
            local processed=tonumber(state.total) or math.max(0,(tonumber(state.next_index) or 1)-1)
            UIManager:show(ConfirmBox:new{
                text=string.format("检测到本书已有完整同步缓存\n\n当前已处理到第 %d 章\n本次将从第 %d 章开始检查新增章节\n结束章节需获取最新目录后确定\n同时补齐缓存中拉取失败的章节\n\n如需全部重新拉取,请先使用「重置本书」选项。",
                    processed,processed+1),
                ok_text="继续",
                ok_callback=function()
                    opts.confirmed=true
                    UIManager:nextTick(function() self:sync_entry(path,mode,opts) end)
                end,
                cancel_text="取消",
            })
            return
        end
        local limit=tonumber(self.store:preferences().sync_batch_limit) or 200
        local plan=BatchSync.plan(self:_sync_state(bound.book_id),limit)
        if plan then
            UIManager:show(ConfirmBox:new{
                text=BatchSync.prompt_text(plan,opts.background==true),
                flush_events_on_show=true,
                ok_text=opts.background==true and "后台同步" or "开始同步",
                ok_callback=function()
                    opts.confirmed=true
                    UIManager:nextTick(function() self:sync_entry(path,mode,opts) end)
                end,
                cancel_text="暂不拉取",
            })
            return
        end
    end
    if self.sync_task and self.sync_task:available() then
        self:_start_sync_task(path,bound,mode,opts)
    elseif mode=="reinject" then
        self:info("此设备不支持离线重注(缺少子进程支持),请直接同步")
    else
        -- 极少数不支持子进程的平台:退回前台 Trapper 流程。
        local Trapper=require("ui/trapper")
        Trapper:wrap(function() self:_sync_run(path,bound) end)
    end
end

function Plugin:_has_reinject_cache(path)
    local bound=path and Binding.get(self.store,path)
    if not bound then return false end
    -- 有 chapters.json 就说明至少完成过一批,离线重注即可用(分批未完也算)。
    return U.file_exists(self.store:book_cache_path(bound.book_id).."/sync-cache/chapters.json")
end

-- 读同步进度状态(child 写的 state.json);60s 内存缓存,翻页检查零成本。
function Plugin:_sync_state(book_id)
    local now=os.time()
    local cached=self._sync_state_cache
    if cached and cached.book_id==tostring(book_id) and now-cached.at<60 then return cached.state end
    local raw=U.read_file(self.store:book_cache_path(book_id).."/sync-cache/state.json",true)
    local state=nil
    if raw then
        local ok,decoded=pcall(function() return require("pickthought.json").decode(raw) end)
        if ok and type(decoded)=="table" then state=decoded end
    end
    self._sync_state_cache={book_id=tostring(book_id),at=now,state=state}
    return state
end

function Plugin:_batch_prompt_path(book_id)
    return self.store:book_cache_path(book_id).."/sync-cache/prompt.json"
end

function Plugin:_batch_prompt_state(book_id)
    local raw=U.read_file(self:_batch_prompt_path(book_id),true)
    if not raw then return nil end
    local ok,state=pcall(function() return require("pickthought.json").decode(raw) end)
    return ok and type(state)=="table" and state or nil
end

function Plugin:_save_batch_prompt_state(book_id,state)
    if type(state)~="table" then return false end
    return U.atomic_write(self:_batch_prompt_path(book_id),require("pickthought.json").encode(state),true)
end

-- ===== 后台同步任务运行时 =====
function Plugin:_persist_sync_state(runtime)
    self.store:set("sync_runtime",{
        status="active",doc_path=runtime.doc_path,book_id=runtime.book_id,title=runtime.title,
        task=runtime.task,started_at=runtime.started_at,
    })
end

function Plugin:_clear_sync_state() self.store:set("sync_runtime",{}) end

function Plugin:_start_sync_task(path,bound,mode,opts)
    opts=opts or {}
    local title=U.trim(tostring(bound.title or ""))
    if title=="" then title=self:doc_title_guess(path) end
    local runtime={doc_path=path,book_id=bound.book_id,title=title,mode=mode,started_at=os.time(),dialog=nil,background=false}
    local ok,err=self.sync_task:start({doc_path=path,book_id=bound.book_id,title=title,mode=mode},
        function(state) self:_on_sync_progress(runtime,state) end,
        function(result) self:_finish_sync(runtime,result) end)
    if not ok then
        if opts.silent then logger.warn("[撷思][Sync] auto batch start failed",tostring(err))
        else self:info("无法启动后台同步:\n"..tostring(err)) end
        return false
    end
    runtime.task=self.sync_task:descriptor()
    self._sync_runtime=runtime
    self:_persist_sync_state(runtime)
    if opts.background then
        -- 自动分批:不打断阅读,直接后台跑,完成后照常弹结果。
        runtime.background=true
        self.sync_task:set_backgrounded(true)
    else
        -- 阅读器菜单(TouchMenu)同样是「先跑回调再关菜单」:
        -- 推迟一拍再弹进度框,免得被菜单关闭的重绘顶掉。
        UIManager:nextTick(function() self:_show_active_sync_dialog() end)
    end
    return true
end

function Plugin:_on_sync_progress(runtime,state)
    if self._sync_runtime~=runtime then return end
    runtime.last_state=U.copy(state or {})
    -- 大书提醒(每次任务只提一次):章节总数超过单批上限时说明分批策略。
    if not runtime.big_book_notified and runtime.mode~="reinject"
        and state and state.stage=="fetch" then
        local total=tonumber(state.total) or 0
        local limit=tonumber(self.store:preferences().sync_batch_limit) or 200
        if total>limit then
            runtime.big_book_notified=true
            local continuation=BatchSync.auto_enabled(self.store:preferences())
                and "或继续阅读时自动补。"
                or "或阅读到边界时按提示后台补。"
            self:toast(string.format(
                "本书共 %d 章。为防风控,单次最多拉 %d 章;"
                .."其余用「继续拉取后续章节」按钮,%s",total,limit,continuation),6)
        end
    end
    if runtime.dialog then runtime.dialog:set_state(state) end
end

function Plugin:_close_sync_dialog()
    local runtime=self._sync_runtime
    local dialog=runtime and runtime.dialog
    if not dialog then return end
    runtime.dialog=nil
    pcall(function() dialog:close() end)
end

function Plugin:_send_sync_to_background()
    local runtime=self._sync_runtime
    if not runtime or not self.sync_task:busy() then return end
    runtime.background=true
    self:_close_sync_dialog()
    self.sync_task:set_backgrounded(true)
    self:toast("同步已转入后台,可继续阅读;完成后会提示",3)
end

function Plugin:_show_active_sync_dialog()
    local runtime=self._sync_runtime
    if not runtime or not self.sync_task or not self.sync_task:busy() then
        self:info("当前没有进行中的同步任务")
        return
    end
    if runtime.dialog then return end
    runtime.background=false
    self.sync_task:set_backgrounded(false)
    local dialog
    dialog=SyncProgress:new{
        title="正在同步《"..tostring(runtime.title or "未命名").."》",
        on_cancel=function() if self.sync_task then self.sync_task:cancel() end end,
        on_background=function() self:_send_sync_to_background() end,
    }
    runtime.dialog=dialog
    dialog:show()
    if runtime.last_state then dialog:set_state(runtime.last_state) end
end

function Plugin:_batch_fragment_position(doc,page,total_pages)
    if not doc or type(doc.getPageXPointer)~="function" then return nil,nil end
    local ok,current_xpointer=pcall(function() return doc:getPageXPointer(page) end)
    local current=ok and BatchSync.fragment_index(current_xpointer) or nil
    if not current then return nil,nil end

    local cache=self._batch_fragment_cache
    if not cache or cache.doc~=doc or cache.total_pages~=total_pages then
        local last_ok,last_xpointer=pcall(function() return doc:getPageXPointer(total_pages) end)
        cache={doc=doc,total_pages=total_pages,
            total=last_ok and BatchSync.fragment_index(last_xpointer) or nil}
        self._batch_fragment_cache=cache
    end
    return current,cache.total
end

-- ===== 阅读分批:到达已同步章节末尾时,自动或询问拉下一批 =====
function Plugin:_maybe_auto_batch(page)
    local now=os.time()
    if self._auto_batch_checked_at and now-self._auto_batch_checked_at<30 then return end
    self._auto_batch_checked_at=now
    if self._auto_batch_started or self._batch_prompt_open then return end
    if not (self.sync_task and self.sync_task:available()) or self.sync_task:busy() then return end
    local path=self:current_doc_path()
    if not path or not tostring(path):lower():match("%.epub$") then return end
    local bound=Binding.get(self.store,path)
    if not bound then return end
    local state=self:_sync_state(bound.book_id)
    if not state or (tonumber(state.pending) or 0)<=0 then return end
    local doc=self.ui and self.ui.document
    if not doc then return end
    local ok_pages,total_pages=pcall(function() return doc:getPageCount() end)
    if not ok_pages or not tonumber(total_pages) or total_pages<=0 then return end
    local fragment,fragment_total=self:_batch_fragment_position(doc,page,total_pages)
    local preferences=self.store:preferences()
    local auto=BatchSync.auto_enabled(preferences)
    local position_key=table.concat({tostring(bound.book_id),tostring(fragment),
        tostring(fragment_total),tostring(state.next_index)},":")
    if self._batch_position_log_key~=position_key then
        self._batch_position_log_key=position_key
        logger.info("[撷思][BatchSync] reading position",
            "page=",tostring(page),"/",tostring(total_pages),
            "fragment=",tostring(fragment),"/",tostring(fragment_total),
            "next_index=",tostring(state.next_index))
    end
    local should_offer,context=BatchSync.should_offer{
        state=state, batch_limit=preferences.sync_batch_limit,
        page=page, total_pages=total_pages,
        fragment=fragment, fragment_total=fragment_total,
        dismissed=not auto and self:_batch_prompt_state(bound.book_id) or nil,
    }
    if not should_offer then return end
    if not self:logged_in() or not self:is_online() then return end
    logger.info("[撷思][BatchSync] boundary reached",
        "page=",tostring(page),"/",tostring(total_pages),
        "fragment=",tostring(fragment),"/",tostring(fragment_total),
        "estimated_chapter=",tostring(context.read_chapter),
        "next_index=",tostring(context.plan.start_index),
        "auto=",tostring(auto))
    if auto then
        self._auto_batch_started=true
        self:toast(BatchSync.background_text(context.plan),3)
        if not self:_start_sync_task(path,bound,"sync",{background=true,silent=true}) then
            self._auto_batch_started=nil
        end
        return
    end

    self._batch_prompt_open=true
    UIManager:show(ConfirmBox:new{
        text=BatchSync.prompt_text(context.plan,true),
        flush_events_on_show=true,
        ok_text="后台同步",
        ok_callback=function()
            self._batch_prompt_open=nil
            self._auto_batch_started=true
            if not self:_start_sync_task(path,bound,"sync",{background=true,silent=true}) then
                self._auto_batch_started=nil
            end
        end,
        cancel_text="暂不拉取",
        cancel_callback=function()
            self._batch_prompt_open=nil
            local dismissal=BatchSync.dismissal(context)
            if dismissal then self:_save_batch_prompt_state(bound.book_id,dismissal) end
        end,
    })
end

function Plugin:onPageUpdate(page)
    pcall(function() self:_maybe_auto_batch(page) end)
end

function Plugin:_merge_sync_auth(result)
    if type(result.auth)~="table" then return end
    -- 子进程用隔离设置副本,期间刷新的 cookie 要合并回主设置。
    self.store:reload()
    local current=self.store:auth()
    local merged=U.copy(current.cookies or {})
    for name,value in pairs(result.auth.cookies or {}) do merged[name]=value end
    current.cookies=Cookies.sanitize(merged)
    if tostring(result.auth.api_key or "")~="" then current.api_key=result.auth.api_key end
    self.store:save_auth(current)
end

function Plugin:_finish_sync(runtime,result)
    if self._sync_runtime~=runtime then return end
    self:_close_sync_dialog()
    self.sync_task:set_backgrounded(false)
    self._sync_runtime=nil
    self:_clear_sync_state()
    -- 同步进度状态已变化:失效内存缓存,自动分批允许下一轮触发。
    self._sync_state_cache=nil
    self._auto_batch_started=nil
    result=result or {}
    self:_merge_sync_auth(result)
    if result.ok==true and type(result.report)=="table" then
        Thoughts.clear_memory_cache()
        self:_sync_report(result.report)
        return
    end
    local err=tostring(result.error or "未知错误")
    if result.cancelled or err=="同步已取消" then
        self:toast("同步已取消;已拉取章节保留在断点,下次同步会续传",4)
        return
    end
    -- 子进程的错误消息不少已自带断点提示,别再拼一遍(真机截图出过双重提示)。
    local hint=err:find("断点",1,true) and "" or "\n\n已拉取章节保存在断点缓存,再次同步会继续。"
    if Http.is_auth_error(err) then
        self:_auth_fail(err)
        return
    end
    if Http.is_network_error(err) then
        self:_sync_fail("网络问题,同步未完成\n\n"..U.first_line(err,160).."\n\n请检查网络后重试")
        return
    end
    self:_sync_fail("同步未完成:\n"..U.first_line(err,220)..hint)
end

function Plugin:_auth_fail(err)
    UIManager:show(ConfirmBox:new{
        text = "登录已失效,请重新登录\n\n原因:"..U.first_line(err,140).."\n\n已拉取的数据保留,重新登录后再次同步即可续传。",
        ok_text = "去登录",
        ok_callback = function()
            UIManager:nextTick(function() self.auth_flow:start() end)
        end,
        cancel_text = "稍后",
    })
end

function Plugin:_recover_sync_state()
    -- 插件实例随文档开关频繁重建:先 reload 拿磁盘上的最新状态,
    -- 避免用 init 时的内存快照幽灵接管一个已经收尾的任务。
    self.store:reload()
    local state=self.store:get("sync_runtime",{})
    if state.status~="active" or type(state.task)~="table" then
        self.sync_task:clear_stale_awake()
        return
    end
    -- 描述符体检:进度与结果文件都没了说明任务早已收尾/被清理,直接清状态。
    if not U.file_exists(tostring(state.task.progress_path or ""))
        and not U.file_exists(tostring(state.task.result_path or "")) then
        self:_clear_sync_state()
        self.sync_task:clear_stale_awake()
        return
    end
    local runtime={doc_path=state.doc_path,book_id=state.book_id,title=state.title,
        started_at=state.started_at,task=state.task,dialog=nil,background=true}
    self._sync_runtime=runtime
    local ok,err=self.sync_task:attach(state.task,
        function(progress) self:_on_sync_progress(runtime,progress) end,
        function(result) self:_finish_sync(runtime,result) end)
    if ok then
        self.sync_task:set_backgrounded(true)
        logger.info("[撷思][Sync] 后台同步已接管","pid=",tostring(state.task.pid))
        return
    end
    self._sync_runtime=nil
    self:_clear_sync_state()
    self.sync_task:clear_stale_awake()
    logger.info("[撷思][Sync] 上次同步已中断",tostring(err))
    UIManager:scheduleIn(1.5,function()
        self:toast("上次同步已中断,断点已保留;再次同步会继续",4)
    end)
end

function Plugin:_sync_fail(text)
    -- flush_events_on_show:注入阶段长时间阻塞里排队的点击不能秒关结果窗。
    UIManager:show(InfoMessage:new{text=tostring(text or ""),flush_events_on_show=true})
end

function Plugin:_sync_run(path,bound)
    local Trapper=require("ui/trapper")
    local Sync=require("pickthought.sync")
    local EpubReader=require("pickthought.epub_reader")
    local EpubInject=require("pickthought.epub_inject")
    local WebFetch=require("pickthought.web_fetch")
    if not Trapper:info("正在读取本地书…") then return end
    -- Sync.run 内部对 api/fetch 已 pcall,但 ChapterMap/EpubReader 的意外异常
    -- 会死在协程里(Trapper 只记日志),必须在这里收敛成用户可见的失败。
    local ok,report,err=xpcall(function()
        return Sync.run{
            doc_path=path,
            book_id=bound.book_id,
            api=self.api,
            annotations=WebFetch:new(self.api),
            load_meta=function(p) return EpubReader.load(p) end,
            read_text=function(m,href) return (EpubReader.read(m,href)) end,
            read_spine=function(m,callback) return EpubReader.each_spine(m,callback) end,
            save_thoughts=function(book_id,uid,groups) return Thoughts.save(self.store,book_id,uid,groups) end,
            merge_thoughts=function(book_id,uid,from,into) return Thoughts.merge(self.store,book_id,uid,from,into) end,
            map_cache_path=self.store:book_dir(bound.book_id).."/sync-cache/map.json",
            inject=function(src,book_id,mapped,dest,options)
                return EpubInject.inject_copy(src,book_id,mapped,
                    {dest=dest,append=options and options.append==true,
                     meta=options and options.meta})
            end,
            progress=function(phase,i,n,text)
                local msg
                if phase=="chapters" then msg="正在获取章节列表…"
                elseif phase=="fetch" then msg=string.format("正在拉取划线与想法 %d/%d\n%s\n(点按屏幕可取消)",i,n,tostring(text or ""))
                elseif phase=="map" then
                    if n and n>0 and i and i>0 then
                        msg=string.format("正在匹配本地章节 %d/%d 个正文文件",i,n)
                        if n>200 then msg=msg.."\n大型书籍的文本匹配需要较长时间,请耐心等待" end
                    else msg="正在匹配本地章节…" end
                else msg="正在生成划线版并替换…\n(书较大时需要一点时间)" end
                return Trapper:info(msg)
            end,
        }
    end,debug.traceback)
    Trapper:clear()
    if not ok then
        logger.err("[撷思][Sync] unexpected error",tostring(report))
        self:_sync_fail("同步失败:\n"..U.first_line(report,220))
        return
    end
    if not report then
        if tostring(err)~="已取消" then self:_sync_fail("同步失败:\n"..U.first_line(err,220)) end
        return
    end
    self:_sync_report(report)
end

function Plugin:_sync_report(report)
    if report.no_changes then
        local pending = tonumber(report.chapters_pending) or 0
        local reason = report.rate_limited
            and "\n\n微信读书触发频率限制,稍后重试即可继续。" or ""
        if pending > 0 then
            self:info(string.format("本批没有可注入的新数据\n\n还剩 %d 章,再次同步会继续。%s", pending, reason))
        else
            self:info("没有新的章节需要同步" .. reason)
        end
        return
    end
    local lines=SyncReport.build(report,{
        auto_batch=BatchSync.auto_enabled(self.store:preferences()),
    })
    logger.info("[撷思][Sync] report",
        "chapters=",tostring(report.chapters_with_data),"/",tostring(report.chapters_total),
        "matched=",tostring(report.chapters_matched),
        "marks=",tostring(report.marks),"aligned=",tostring(report.quote_aligned),
        "numeric=",tostring(report.numeric),"overlapped=",tostring(report.overlapped),
        "unlocated=",tostring(report.unlocated))
    UIManager:show(ConfirmBox:new{
        text=table.concat(lines,"\n"),
        icon="check",
        flush_events_on_show=true,
        ok_text="打开划线版",
        ok_callback=function()
            local ReaderUI=require("apps/reader/readerui")
            ReaderUI:showReader(report.dest)
        end,
        cancel_text="稍后",
    })
end

function Plugin:restore_original(path)
    path=path or self:current_doc_path()
    if not path then self:info("请先打开一本本地书") return end
    if self.sync_task and self.sync_task:busy() then
        self:info("同步任务进行中,请等它完成(或取消)后再还原")
        return
    end
    local backup=path..".orig"
    if not U.file_exists(backup) then self:info("没有找到原书备份("..backup..")") return end
    -- 书正开着时,reloadDocument 会自动重载原版;文管里还原则下次打开即原版。
    local is_open=path==self:current_doc_path()
    UIManager:show(ConfirmBox:new{
        text="将用原书备份覆盖当前划线版,书内注入的划线与想法会移除(想法缓存保留)。",
        ok_text="还原原书",
        ok_callback=function()
            os.remove(path)
            local ok,err=os.rename(backup,path)
            if not ok then self:info("还原失败:\n"..tostring(err or "重命名失败")); return end
            if is_open and self.ui and type(self.ui.reloadDocument)=="function" then
                -- 自动重载:丢弃注入版缓存,重读已替换的原版文件,免得用户手动关闭再开。
                local reload_ok=pcall(function() self.ui:reloadDocument(nil, true) end)
                self:toast(reload_ok and "已还原原书" or "已还原原书,请重新打开本书",3)
            else
                self:toast("已还原原书",3)
            end
        end,
        cancel_text="取消",
    })
end

-- 重置本书:清该书所有同步缓存/想法/映射 + 还原原书(若有注入)。
-- 双重确认(破坏性)。回到"未同步+原版书"状态,保留绑定关系。重新同步即可恢复。
local RESET_TARGETS = {"sync-cache", "thoughts", "thoughts.db", "thoughts.db-wal", "thoughts.db-shm"}

function Plugin:reset_book_data(path)
    path = path or self:current_doc_path()
    if not path then self:info("请先选择一本书"); return end
    local bound = Binding.get(self.store, path)
    local has_orig = U.file_exists(path..".orig")
    if not bound and not has_orig then self:info("这本书无撷思数据,也无原书备份"); return end
    local title = self:doc_title_guess(path)
    local book_dir = bound and self.store:book_dir(bound.book_id) or nil
    local lines = {}
    if book_dir then lines[#lines+1] = "• 清同步缓存/想法数据库/章节映射" end
    if has_orig then lines[#lines+1] = "• 还原原书(移除书内划线)" end
    UIManager:show(ConfirmBox:new{
        text = string.format("将重置《%s》:\n\n%s\n\n保留绑定关系,重新同步即可恢复。", title, table.concat(lines, "\n")),
        ok_text = "继续",
        ok_callback = function()
            UIManager:show(ConfirmBox:new{
                text = "再次确认:重置《"..title.."》?\n此操作不可撤销。",
                ok_text = "确认重置",
                ok_callback = function()
                    self:_do_reset_book_data(book_dir, path, title)
                end,
                cancel_text = "取消",
            })
        end,
        cancel_text = "取消",
    })
end

function Plugin:_dir_size(path)
    local lfs = require("libs/libkoreader-lfs")
    local total = 0
    local function walk(p)
        for name in lfs.dir(p) do
            if name ~= "." and name ~= ".." then
                local full = p .. "/" .. name
                local attr = lfs.attributes(full)
                if attr and attr.mode == "file" then total = total + (attr.size or 0)
                elseif attr and attr.mode == "directory" then walk(full) end
            end
        end
    end
    pcall(walk, path)
    return total
end

-- 还原单本原书:删注入版,.orig 顶回。返回是否还原成功。
function Plugin:_restore_original_file(path)
    if not U.file_exists(path..".orig") then return false end
    os.remove(path)
    local ok = os.rename(path..".orig", path)
    if ok and path == self:current_doc_path() and self.ui and self.ui.reloadDocument then
        pcall(function() self.ui:reloadDocument(nil, true) end)
    end
    return ok == true
end

function Plugin:_do_reset_book_data(book_dir, path, title)
    local cleared, size_bytes = 0, 0
    if book_dir then
        size_bytes = self:_dir_size(book_dir)
        for _, name in ipairs(RESET_TARGETS) do
            if U.remove_tree(book_dir .. "/" .. name) then cleared = cleared + 1 end
        end
    end
    Thoughts.clear_memory_cache()
    self._sync_state_cache = nil
    local was_open = path == self:current_doc_path()
    local restored = self:_restore_original_file(path)
    local msg = "已重置《"..title.."》\n\n"
    if cleared > 0 then msg = msg .. string.format("清理 %d 项,约 %.1f MB\n", cleared, size_bytes/1048576) end
    if restored then
        msg = msg .. (was_open and "书已还原原版,当前书已自动重新打开\n" or "书已还原原版\n")
    end
    msg = msg .. "重新同步即可恢复"
    self:info(msg)
end

-- 重置全部书籍:清所有 book_dir 数据 + 还原所有有备份的原书。
function Plugin:clear_all_data()
    UIManager:show(ConfirmBox:new{
        text = "将重置所有书:\n\n• 清全部书的同步缓存/想法/映射\n• 还原所有注入书为原版\n\n保留绑定关系,各书需重新同步。",
        ok_text = "继续",
        ok_callback = function()
            UIManager:show(ConfirmBox:new{
                text = "再次确认:重置全部书籍?\n此操作不可撤销。",
                ok_text = "确认重置",
                ok_callback = function() self:_do_clear_all() end,
                cancel_text = "取消",
            })
        end,
        cancel_text = "取消",
    })
end

function Plugin:_do_clear_all()
    local lfs = require("libs/libkoreader-lfs")
    local root = self.store.cache_books_dir
    local total_size, book_count, restored_count = 0, 0, 0
    if lfs.attributes(root, "mode") == "directory" then
        for name in lfs.dir(root) do
            if name ~= "." and name ~= ".." then
                local bd = root .. "/" .. name
                if lfs.attributes(bd, "mode") == "directory" then
                    total_size = total_size + self:_dir_size(bd)
                    for _, n in ipairs(RESET_TARGETS) do U.remove_tree(bd .. "/" .. n) end
                    book_count = book_count + 1
                end
            end
        end
    end
    -- 还原所有绑定书(有 .orig 的)
    local bindings = self.store:get("bindings", {})
    for doc_path in pairs(bindings) do
        if self:_restore_original_file(doc_path) then restored_count = restored_count + 1 end
    end
    Thoughts.clear_memory_cache()
    self._sync_state_cache = nil
    self:info(string.format("已重置全部书籍\n\n%d 本书,约 %.1f MB\n还原 %d 本原书\n各书重新同步即可恢复",
        book_count, total_size/1048576, restored_count))
end

-- ===== 想法弹窗体系（点击 EPUB 锚点 → 弹窗）=====
local function extract_thought_href(value,seen,depth)
    if depth>4 or value==nil then return nil end
    if type(value)=="string" then return value:match("(pickthought%-[%x%.]+)") end
    if type(value)~="table" then return nil end
    seen=seen or {}; if seen[value] then return nil end; seen[value]=true
    for _,key in ipairs({"href","url","target","link","uri","dest","destination"}) do local found=extract_thought_href(value[key],seen,depth+1); if found then return found end end
    for _,child in pairs(value) do local found=extract_thought_href(child,seen,depth+1); if found then return found end end
end

function Plugin:_teardown_thought_tap()
    if self._thought_tap_setup and self.ui and self.ui.unRegisterTouchZones then pcall(function() self.ui:unRegisterTouchZones({{id="pickthought_thought_popup",overrides={"tap_link"}}}) end) end
    self._thought_tap_setup=nil
end

function Plugin:_thought_font_size(level)
    local Device=require("device")
    return Device.screen:scaleBySize(self:_thought_font_pt(level))
end

function Plugin:_thought_font_pt(level)
    local doc=self.ui and self.ui.document
    local configurable=doc and doc.configurable or {}
    local candidates={
        configurable.font_size,
        configurable.fontsize,
        self.ui and self.ui.rolling and self.ui.rolling.font_size,
    }
    local base
    for _,value in ipairs(candidates) do
        value=tonumber(value)
        if value and value>=10 and value<=80 then base=value; break end
    end
    if not base and _G.G_reader_settings and _G.G_reader_settings.readSetting then
        local ok,value=pcall(_G.G_reader_settings.readSetting,_G.G_reader_settings,"cre_font_size",22)
        if ok then base=tonumber(value) end
    end
    base=math.max(14,math.min(48,base or 22))
    local factors={standard=0.86,large=1.00,xlarge=1.15}
    local factor=factors[tostring(level or "standard")] or 1
    return math.floor(base*factor+.5)
end

local function usable_font_name(value)
    if type(value)~="string" then return nil end
    value=value:match("^%s*(.-)%s*$")
    if value=="" then return nil end
    return value
end

function Plugin:_thought_font_name()
    local name=usable_font_name(self.ui and self.ui.font and self.ui.font.font_face)
    if name then return name end
    local doc=self.ui and self.ui.document
    if doc and type(doc.getFontFace)=="function" then
        local ok,value=pcall(doc.getFontFace,doc)
        if ok then
            name=usable_font_name(value)
            if name then return name end
        end
    end
    if _G.G_reader_settings and type(_G.G_reader_settings.readSetting)=="function" then
        local ok,value=pcall(_G.G_reader_settings.readSetting,_G.G_reader_settings,"cre_font")
        if ok then return usable_font_name(value) end
    end
    return nil
end

function Plugin:_show_thought_href(href)
    local info=Thoughts.parse_href(href); if not info then return false end
    if self._thought_popup_busy then return true end
    self._thought_popup_busy=true
    local started=os.clock()
    local ok,unexpected=xpcall(function()
        local group,err=Thoughts.find(self.store,info.book_id,info.chapter_uid,info.range)
        if not group then self:info(tostring(err or "没有想法内容")); return end
        local items=Thoughts.popup_items(group)
        if #items==0 then self:info("没有想法内容"); return end
        local prefs=self.store:preferences().thoughts or {}
        local ThoughtPopup=require("pickthought.thought_popup")
        ThoughtPopup.show{items=items,
            height_ratio=tonumber(prefs.height_ratio) or 0.62}
        logger.info("[撷思][ThoughtPopup] opened",
            "book=",tostring(info.book_id),"chapter=",tostring(info.chapter_uid),
            "comments=",tostring(#(group.texts or {})),
            "elapsed_ms=",tostring(math.floor((os.clock()-started)*1000+.5)))
    end,debug.traceback)
    self._thought_popup_busy=false
    if not ok then
        logger.err("[撷思][ThoughtPopup] open failed",tostring(unexpected))
        self:info("想法弹窗打开失败：\n"..U.first_line(unexpected,220))
    end
    return true
end

function Plugin:_on_thought_tap(ges)
    if not self.ui or not self.ui.link or not self.ui.link.getLinkFromGes then return false end
    local ok,link=pcall(self.ui.link.getLinkFromGes,self.ui.link,ges); if not ok or not link then return false end
    local href=extract_thought_href(link,{},0); if not href then return false end
    return self:_show_thought_href(href)
end

function Plugin:_setup_thought_tap()
    if self._thought_tap_setup or not self.ui or not self.ui.registerTouchZones then return end
    local ok,Device=pcall(require,"device"); if ok and Device.isTouchDevice and not Device:isTouchDevice() then return end
    self.ui:registerTouchZones({{id="pickthought_thought_popup",ges="tap",screen_zone={ratio_x=0,ratio_y=0,ratio_w=1,ratio_h=1},overrides={"tap_link"},handler=function(ges) return self:_on_thought_tap(ges) end}})
    self._thought_tap_setup=true
end

-- ===== 事件 =====
function Plugin:onReadSettings()
    -- KOReader calls this before the document is rendered. Do not emit
    -- UpdatePos here: applying a stylesheet at onReaderReady can start a
    -- seamless reload loop on rolling documents.
    if not self.ui or not self.ui.document then return end
    local path=self:current_doc_path()
    if not path or not Binding.get(self.store,path) then return end
    local base,stylesheet,style=self:_annotation_stylesheet()
    if not base then return end
    local ok,err=pcall(function()
        self.ui.document:setStyleSheet(base,stylesheet)
    end)
    if not ok then
        logger.warn("[撷思][AnnotationStyle] initial apply failed",
            "style=",tostring(style),tostring(err))
    end
end

function Plugin:onReaderReady()
    -- 文件管理器阶段可能尚未加载 readerannotation,进入阅读器时重试一次。
    AnnotationCompat.install()
    self:_teardown_thought_tap(); self:_setup_thought_tap()
end

function Plugin:onCloseDocument()
    local path = self:current_doc_path()
    local binding = path and Binding.get(self.store, path)
    if binding and binding.book_id then
        Thoughts.close_book(self.store, binding.book_id)
    end
    self:_teardown_thought_tap()
end

function Plugin:onFlushSettings() self.store:flush() end

return Plugin
