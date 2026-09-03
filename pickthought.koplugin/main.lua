local ConfirmBox=require("ui/widget/confirmbox")
local Dispatcher=require("dispatcher")
local InfoMessage=require("ui/widget/infomessage")
local InputDialog=require("ui/widget/inputdialog")
local Menu=require("ui/widget/menu")
local TextViewer=require("ui/widget/textviewer")
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
local SyncGate=require("pickthought.sync_gate")
local SyncProgress=require("pickthought.sync_progress")
local UpdateProgress=require("pickthought.update_progress")
local SyncReport=require("pickthought.sync_report")
local Sync=require("pickthought.sync")
local BatchSync=require("pickthought.batch_sync")
local AnnotationCompat=require("pickthought.annotation_compat")
local AnnotationStyle=require("pickthought.annotation_style")
local Event=require("ui/event")
local PopupDiagnostic=require("pickthought.diagnostic")
local PopupConfig=require("pickthought.thought_popup.popup_config")
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
    PopupDiagnostic.set_enabled(self.store:preferences().debug_mode==true)
    logger.info("[撷思] initialized", "version=", tostring(Config.VERSION),
        "schema=", tostring(Config.SCHEMA), "root=", tostring(ROOT))
    sanitize_saved_auth(self.store)
    self.http=Http:new(self.store)
    self.api=Api:new(self.http,self.store)
    self.auth_flow=Auth:new(self.http,self.store,self)
    self.updater=Updater:new(self.http,self.store,self.version,ROOT)
    self.sync_task=SyncTask:new(self.store)
    UIManager:scheduleIn(0.8,function() self:_recover_sync_state() end)
    -- 自动检查由两个更新开关共同控制,新安装默认关闭。
    local update_preferences=self.store:preferences().update or {}
    if update_preferences.auto_update==true or update_preferences.notify_update==true then
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

function Plugin:annotation_style_item()
    return {text="划线样式（"..self:annotation_style_label().."）",
        sub_item_table_func=function() return self:annotation_style_menu() end}
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
    items[#items+1]=self:annotation_style_item()
    items[#items+1]={text="账户",sub_item_table_func=function() return self:account_menu() end}
    items[#items+1]={text="设置",sub_item_table_func=function() return self:settings_menu() end}
    items[#items+1]={text="更新",sub_item_table_func=function() return self:update_about_menu() end}
    items[#items+1]={text="重置全部书籍",callback=self:safe("clear_all",function() self:clear_all_data() end)}
    items[#items+1]={text="关于",callback=self:safe("about",function() self:show_about() end)}
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
        items[#items+1]=self:annotation_style_item()
        -- 多书聚合:任何一本有待同步章节都提供「继续拉取」,不只看第一本(P1#4);
        -- 失败书/剩余未知书同样保留入口,不让聚合 0 吞掉失败态(评审五轮 P1#2)。
        local agg=self:_aggregate_sync_state(doc_path)
        if agg.pending>0 or agg.books_failed>0 or agg.books_unknown>0 then
            items[#items+1]={text=self:_continue_sync_label(agg),
                callback=self:safe("continue_sync",function() self:sync_entry(doc_path,"sync") end)}
        end
    end
    if doc_path and self:_has_reinject_cache(doc_path) then
        items[#items+1]={text="重新注入(用上次数据,离线)",callback=self:safe("reinject",function() self:reinject_with_clean(doc_path) end)}
    end
    if doc_bound or (doc_path and U.file_exists(doc_path..".orig")) then
        items[#items+1]={text="重置本书(清数据+还原原版)",callback=self:safe("reset",function() self:reset_book_data(doc_path) end)}
    end
    items[#items+1]={text="账户",sub_item_table_func=function() return self:account_menu() end}
    items[#items+1]={text="设置",sub_item_table_func=function() return self:settings_menu() end}
    items[#items+1]={text="更新",sub_item_table_func=function() return self:update_about_menu() end}
    items[#items+1]={text="重置全部书籍",callback=self:safe("clear_all",function() self:clear_all_data() end)}
    items[#items+1]={text="关于",callback=self:safe("about",function() self:show_about() end)}
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
    rows[#rows+1]={{text=bound and "重新绑定微信读书" or "绑定微信读书",
        callback=act(function() self:bind_book(path) end)}}
    rows[#rows+1]={{text="同步划线与想法",callback=act(function() self:sync_entry(path) end)}}
    if bound then
        -- 划线样式入口(上游 v0.3.3 契约:文件管理器书籍操作保留样式入口)。
        rows[#rows+1]={{text="划线样式（"..self:annotation_style_label().."）",
            callback=act(function() self:list("划线样式",self:annotation_style_menu()) end)}}
        -- 多书聚合:任何一本有待同步章节都提供「继续拉取」(P1#4);失败书/未知书
        -- 保留入口(评审五轮 P1#2)。
        local agg=self:_aggregate_sync_state(path)
        if agg.pending>0 or agg.books_failed>0 or agg.books_unknown>0 then
            rows[#rows+1]={{text=self:_continue_sync_label(agg),
                callback=act(function() self:sync_entry(path,"sync") end)}}
        end
        rows[#rows+1]={{text="清理本书数据",callback=act(function() self:reset_book_data(path) end)}}
    end
    if self:_has_reinject_cache(path) then
        rows[#rows+1]={{text="重新注入(用上次数据,离线)",callback=act(function() self:reinject_with_clean(path) end)}}
    end
    if bound or U.file_exists(path..".orig") then
        rows[#rows+1]={{text="重置本书(清数据+还原原版)",callback=act(function() self:reset_book_data(path) end)}}
    end
    if bound then
        local n=#Binding.list(self.store,path)
        rows[#rows+1]={{text=string.format("管理已绑定书目(%d)",n),callback=act(function() self:manage_bindings(path) end)}}
    end
    rows[#rows+1]={{text="取消",callback=function() UIManager:close(dialog) end}}
    local title=self:doc_title_guess(path)
    if bound then
        local list=Binding.list(self.store,path)
        if #list>1 then
            title=title..string.format("\n已绑定 %d 本微信读书书",#list)
        else
            title=title.."\n已绑定:"..tostring(bound.title or bound.book_id)
        end
    end
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
    local list=Binding.list(self.store,path)
    local dialog
    dialog=ButtonDialog:new{
        title="当前绑定:\n"..display,
        buttons={
            {{text="重新绑定",callback=function() UIManager:close(dialog); self:bind_search(path,on_bound) end}},
            {{text=string.format("管理已绑定书目(%d)",#list),callback=function() UIManager:close(dialog); self:manage_bindings(path,on_bound) end}},
            {{text="解除绑定",callback=function() UIManager:close(dialog); Binding.clear(self.store,path); self:toast("已解除绑定"); self:_rebuild_from_orig(path) end}},
            {{text="取消",callback=function() UIManager:close(dialog) end}},
        },
    }
    UIManager:show(dialog)
end

-- 多书绑定管理:查看已绑定的全部微信读书书,可逐本移除或追加,亦可一键解绑全部。
function Plugin:manage_bindings(path,on_bound)
    path=path or self:current_doc_path()
    if not path then return end
    local ButtonDialog=require("ui/widget/buttondialog")
    local list=Binding.list(self.store,path)
    local dialog
    local function act(fn) return function() UIManager:close(dialog); fn() end end
    local rows={}
    for _,rec in ipairs(list) do
        local label=tostring(rec.title or rec.book_id)
        if tostring(rec.author or "")~="" then label=label.." · "..tostring(rec.author) end
        rows[#rows+1]={{text="移除:"..label,callback=act(function()
            Binding.remove(self.store,path,rec.book_id)
            self:toast("已移除:"..label)
            -- 从 .orig 按剩余绑定重建,移除被解绑书的内容残留(P2#7)。
            self:_rebuild_from_orig(path)
            self:manage_bindings(path,on_bound)
        end)}}
    end
    rows[#rows+1]={{text="添加另一本微信读书书",callback=act(function() self:bind_search(path,on_bound) end)}}
    if #list>0 then
        rows[#rows+1]={{text="解除全部绑定",callback=act(function()
            Binding.clear(self.store,path); self:toast("已解除全部绑定"); self:_rebuild_from_orig(path)
        end)}}
    end
    rows[#rows+1]={{text="取消",callback=function() UIManager:close(dialog) end}}
    local title=#list>0 and string.format("已绑定 %d 本微信读书书:",#list) or "尚未绑定任何微信读书书"
    dialog=ButtonDialog:new{title=title,buttons=rows}
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
        {text="想法弹窗设置",sub_item_table_func=function() return self:thought_popup_menu() end},
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
        {text="调试模式(记录详细同步日志)",checked_func=function()
            return self.store:preferences().debug_mode==true
        end,callback=function()
            local p=self.store:preferences()
            p.debug_mode=not (p.debug_mode==true)
            self.store:save_preferences(p)
            PopupDiagnostic.set_enabled(p.debug_mode==true)
            self:toast(p.debug_mode and "调试模式已开启,下次同步生效"
                or "调试模式已关闭,下次同步生效")
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

local function popup_percent(value, fallback)
    return math.floor(((tonumber(value) or fallback) * 100) + .5)
end

function Plugin:_thought_popup_preferences()
    return self.store:preferences().thoughts or {}
end

function Plugin:_save_thought_popup_preferences(update)
    local preferences=self.store:preferences()
    preferences.thoughts=preferences.thoughts or {}
    for key,value in pairs(update or {}) do preferences.thoughts[key]=value end
    self.store:save_preferences(preferences)
    return preferences.thoughts
end

function Plugin:thought_popup_menu()
    local thoughts=self:_thought_popup_preferences()
    local position=thoughts.position=="bottom" and "底部" or "居中"
    local contrast=tonumber(thoughts.contrast) or 9
    local contrast_label=contrast==9 and "纯黑（默认）" or ((contrast>0 and "+" or "")..tostring(contrast))
    local font_label
    if thoughts.font_size~=nil then
        font_label="固定 "..tostring(math.floor(tonumber(thoughts.font_size) or 0))
    else
        local relative=tonumber(thoughts.font_size_relative) or 0
        font_label=relative==0 and "跟随正文" or ((relative>0 and "+" or "")..tostring(relative))
    end
    return {
        {text="位置："..position,callback=self:safe("thought_popup_position",function() self:show_thought_popup_position_picker() end)},
        {text="高度："..tostring(popup_percent(thoughts.height_ratio,PopupConfig.DEFAULTS.height_ratio)).."%",callback=self:safe("thought_popup_height",function() self:show_thought_popup_height_picker() end)},
        {text="宽度："..tostring(popup_percent(thoughts.width_ratio,PopupConfig.DEFAULTS.width_ratio)).."%",enabled_func=function() return self:_thought_popup_preferences().position~="bottom" end,callback=self:safe("thought_popup_width",function() self:show_thought_popup_width_picker() end)},
        {text="字号："..font_label,callback=self:safe("thought_popup_font",function() self:show_thought_popup_font_size_picker() end)},
        {text="字体对比度："..contrast_label,callback=self:safe("thought_popup_contrast",function() self:show_thought_popup_contrast_picker() end)},
        {text="点击左右区域翻页",checked_func=function() return self:_thought_popup_preferences().tap_to_page==true end,callback=self:safe("thought_popup_tap",function()
            local enabled=not (self:_thought_popup_preferences().tap_to_page==true)
            self:_save_thought_popup_preferences({tap_to_page=enabled})
            self:toast(enabled and "想法弹窗左右点击翻页已开启" or "想法弹窗左右点击翻页已关闭")
        end)},
    }
end

function Plugin:show_thought_popup_position_picker()
    local ButtonDialog=require("ui/widget/buttondialog")
    local dialog
    local function choose(position)
        UIManager:close(dialog)
        self:_save_thought_popup_preferences({position=position})
        self:toast(position=="bottom" and "想法弹窗已设为底部" or "想法弹窗已设为居中")
    end
    dialog=ButtonDialog:new{title="想法弹窗位置",buttons={
        {{text="居中",callback=function() choose("center") end}},
        {{text="底部",callback=function() choose("bottom") end}},
        {{text="取消",callback=function() UIManager:close(dialog) end}},
    }}
    UIManager:show(dialog)
end

function Plugin:_show_thought_popup_ratio_picker(kind, title, minimum, maximum, fallback)
    local SpinWidget=require("ui/widget/spinwidget")
    local thoughts=self:_thought_popup_preferences()
    local current=popup_percent(thoughts[kind],fallback)
    local spin=SpinWidget:new{
        value=current,value_min=minimum,value_max=maximum,
        value_step=PopupConfig.LIMITS.ratio_step,precision="%d%%",
        default_value=popup_percent(fallback),
        ok_text="确定",title_text=title,
        info_text=title.."占屏幕"..(kind=="width_ratio" and "宽度" or "高度").."的比例。",
        callback=function(widget)
            local saved=self:_save_thought_popup_preferences({[kind]=widget.value/100})
            logger.info("[撷思][ThoughtPopup] preference changed",kind,tostring(saved[kind]))
        end,
    }
    UIManager:show(spin)
end

function Plugin:show_thought_popup_height_picker()
    local limits=PopupConfig.LIMITS
    self:_show_thought_popup_ratio_picker("height_ratio","想法弹窗高度",
        limits.min_height_ratio*100,limits.max_height_ratio*100,PopupConfig.DEFAULTS.height_ratio)
end

function Plugin:show_thought_popup_width_picker()
    if self:_thought_popup_preferences().position=="bottom" then
        self:toast("底部想法弹窗使用全屏宽度")
        return
    end
    local limits=PopupConfig.LIMITS
    self:_show_thought_popup_ratio_picker("width_ratio","想法弹窗宽度",
        limits.min_width_ratio*100,limits.max_width_ratio*100,PopupConfig.DEFAULTS.width_ratio)
end

function Plugin:show_thought_popup_font_size_picker()
    local Screen=require("device").screen
    local thoughts=self:_thought_popup_preferences()
    local spin
    local function show(absolute)
        local title="想法弹窗字号"
        if absolute then
            spin=require("ui/widget/spinwidget"):new{
                width=math.floor(Screen:getWidth()*.75),
                value=tonumber(thoughts.font_size) or self:_thought_font_pt(),
                value_min=12,value_max=255,precision="%d",ok_text="确定",title_text=title,
                info_text="固定字号不随正文大小变化。",
                callback=function(widget)
                    self:_save_thought_popup_preferences({font_size=widget.value,font_size_relative=nil})
                end,
                extra_text="改为相对正文字号",
                extra_callback=function() UIManager:close(spin); show(false) end,
            }
        else
            spin=require("ui/widget/spinwidget"):new{
                width=math.floor(Screen:getWidth()*.75),
                value=tonumber(thoughts.font_size_relative) or 0,
                value_min=-10,value_max=5,precision="%+d",ok_text="确定",title_text=title,
                info_text="0 为跟随正文；负值更小，正值更大。",
                callback=function(widget)
                    self:_save_thought_popup_preferences({font_size_relative=widget.value,font_size=nil})
                end,
                extra_text="改为固定字号",
                extra_callback=function() UIManager:close(spin); show(true) end,
            }
        end
        UIManager:show(spin)
    end
    show(thoughts.font_size~=nil)
end

function Plugin:show_thought_popup_contrast_picker()
    local SpinWidget=require("ui/widget/spinwidget")
    local spin=SpinWidget:new{
        value=tonumber(self:_thought_popup_preferences().contrast) or 9,
        value_min=-3,value_max=9,precision="%+d",ok_text="确定",title_text="想法弹窗字体对比度",
        info_text="默认值 9 为纯黑；降低数值可使用更浅的灰色。",
        callback=function(widget) self:_save_thought_popup_preferences({contrast=widget.value}) end,
    }
    UIManager:show(spin)
end

function Plugin:update_about_menu()
    local function update_preference(name)
        return (self.store:preferences().update or {})[name]==true
    end
    return {
        {text="检查更新（当前版本 · "..tostring(self.version).."）",callback=self:safe("update",function() self:check_update() end)},
        {text="查看更新日志",callback=self:safe("update-log",function() self:show_update_log() end)},
        {text="自动更新",checked_func=function() return update_preference("auto_update") end,
            callback=function()
                local p=self.store:preferences(); p.update=p.update or {}
                p.update.auto_update=not (p.update.auto_update==true)
                self.store:save_preferences(p)
                self:toast(p.update.auto_update and "自动更新已开启" or "自动更新已关闭")
                if p.update.auto_update==true or p.update.notify_update==true then
                    UIManager:scheduleIn(0.1,function() self:maybe_auto_check_update(true) end)
                end
            end},
        {text="通知有可用更新",checked_func=function() return update_preference("notify_update") end,
            callback=function()
                local p=self.store:preferences(); p.update=p.update or {}
                p.update.notify_update=not (p.update.notify_update==true)
                self.store:save_preferences(p)
                self:toast(p.update.notify_update and "更新通知已开启" or "更新通知已关闭")
                if p.update.auto_update==true or p.update.notify_update==true then
                    UIManager:scheduleIn(0.1,function() self:maybe_auto_check_update(true) end)
                end
        end},
    }
end

-- 启动后静默检查更新(每 24h 一次,失败 6h 后重试)。
function Plugin:maybe_auto_check_update(force)
    if self._auto_update_check_running then return false end
    local settings=self.store:preferences().update or {}
    if not force and settings.auto_update~=true and settings.notify_update~=true then return false end
    local now=os.time()
    local interval=Config.AUTO_UPDATE_INTERVAL
    local state=self.store:get("update_check",{})
    local last=tonumber(state.last_attempt_at) or 0
    if not force and now-last<interval then return false end
    if not self:is_online() then return false end
    self._auto_update_check_running=true
    state.last_attempt_at=now
    self.store:set("update_check",state)
    UIManager:scheduleIn(0.05,self:safe("auto-update",function()
        local ok,m,e=pcall(function() return self.updater:check() end)
        self._auto_update_check_running=false
        local fresh=self.store:get("update_check",{})
        local current_settings=self.store:preferences().update or {}
        if ok and m and not m.current then
            fresh.last_success_at=os.time()
            self.store:set("update_check",fresh)
            if current_settings.notify_update==true then
                self:toast(string.format("撷思发现新版本 %s，请前往「更新」查看",tostring(m.version or "")),5)
            end
            if current_settings.auto_update==true then
                UIManager:nextTick(function() self:_do_update(m,true) end)
            end
        elseif ok and m then
            fresh.last_success_at=os.time()
            self.store:set("update_check",fresh)
        else
            fresh.last_attempt_at=os.time()-(interval-Config.AUTO_UPDATE_RETRY_INTERVAL)
            self.store:set("update_check",fresh)
            logger.warn("[撷思][Updater] automatic check failed",tostring(e or m))
        end
    end))
    return true
end

function Plugin:_update_log_text(m)
    m=m or {}
    local version=tostring(m.version or self.version)
    local text="版本："..version
    if m.name and tostring(m.name)~="" then text=text.."\n"..tostring(m.name) end
    local notes=Updater.normalize_notes(m.notes)
    text=text.."\n\n更新说明：\n"..(notes~="" and notes or "暂无更新说明")
    if m.checked_at then text=text.."\n\n检查时间："..U.now_text(m.checked_at) end
    return text
end

function Plugin:_show_update_log(m)
    local viewer
    viewer=TextViewer:new{
        title="更新日志 · v"..tostring(m.version or self.version),
        text=self:_update_log_text(m),text_type="general",auto_para_direction=true,
        buttons_table={{{text="关闭",callback=function() UIManager:close(viewer) end}}},
    }
    UIManager:show(viewer)
end

function Plugin:show_update_log()
    local cached=self.updater:cached_info()
    if not self:is_online() then
        if cached then self:_show_update_log(cached)
        else self:info("没有缓存的更新日志,请连接网络后重试") end
        return
    end
    local Trapper=require("ui/trapper")
    Trapper:wrap(function()
        if not Trapper:info("正在读取更新日志…") then return end
        local m,e=self.updater:check()
        Trapper:clear()
        if not m then
            if cached then self:_show_update_log(cached)
            else self:_update_fail("读取更新日志失败：\n"..tostring(e or "未知错误")) end
            return
        end
        UIManager:nextTick(function()
            self:_show_update_log(self.updater:cached_info() or m)
        end)
    end)
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
        if m.name and tostring(m.name)~="" then text=text.."\n"..Updater.normalize_notes(m.name) end
        local notes=Updater.normalize_notes(m.notes)
        if notes~="" then text=text.."\n\n更新说明：\n"..notes end
        text=text.."\n\n是否下载并安装？"
        -- 推迟到协程外,避免菜单重绘把确认框顶掉。
        UIManager:nextTick(function()
            UIManager:show(ConfirmBox:new{text=text,ok_text="下载并安装",
                ok_callback=function() self:_do_update(m,false) end})
        end)
    end)
end

function Plugin:_update_retry_after_busy()
    local state=self.store:get("update_check",{})
    state.last_attempt_at=os.time()-(Config.AUTO_UPDATE_INTERVAL-Config.AUTO_UPDATE_RETRY_INTERVAL)
    self.store:set("update_check",state)
end

function Plugin:_show_update_installed(silent)
    if silent then
        self:toast("更新已安装,请重启 KOReader",5)
        return
    end
    UIManager:show(ConfirmBox:new{
        text="更新已安装\n\n需要重启 KOReader 才会生效。",
        ok_text="立即重启",
        ok_callback=function() UIManager:restartKOReader() end,
        cancel_text="稍后",
    })
end

function Plugin:_do_update(m,silent)
    if SyncGate.busy(self.sync_task) then
        if not silent then self:info("同步任务进行中,请等它完成或取消后再安装更新") end
        self:_update_retry_after_busy()
        return
    end
    local Trapper=require("ui/trapper")
    Trapper:wrap(function()
        local progress
        if not silent then
            progress=UpdateProgress:new{title="更新撷思",on_cancel=function() end}
            progress:show()
        end
        local path
        local ok_dl,err=pcall(function()
            path=self.updater:download(m,progress and function(event)
                progress:set_state(event)
                return not progress.cancelled
            end or nil)
        end)
        if not ok_dl or not path then
            if progress then progress:close() end
            if tostring(err or ""):find("已取消",1,true) then return end
            self:_update_fail("下载失败：\n"..tostring(err or "未知错误"),silent)
            return
        end
        if SyncGate.busy(self.sync_task) then
            if progress then progress:close() end
            if not silent then self:info("同步任务已开始,本次更新暂不安装") end
            self:_update_retry_after_busy()
            return
        end
        if progress then progress:set_state({stage="installing",percent=100}) end
        local ok_inst,er=self.updater:install(path,m)
        if progress then progress:close() end
        if ok_inst then self:_show_update_installed(silent)
        else self:_update_fail("安装失败：\n"..tostring(er),silent) end
    end)
end

function Plugin:_update_fail(text,silent)
    if silent then self:toast("自动更新失败: "..U.first_line(text,120),5); return end
    UIManager:show(InfoMessage:new{text=tostring(text or ""),flush_events_on_show=true})
end

function Plugin:show_about()
    self:info(Config.NAME.." "..self.version.."\n\n撷思 撷思\n只同步微信读书划线与想法到本地 EPUB 副本\n\n".._("Unofficial client").."\n\n".._("This build has not been verified with every Kindle model or every WeRead book."))
end

function Plugin:_sync_mutation_blocked(message)
    if not SyncGate.busy(self.sync_task) then return false end
    self:info(message or "同步任务进行中,请等它完成或取消后再操作")
    return true
end

function Plugin:_capture_sync_context(path, bound)
    return SyncGate.capture(self.ui and self.ui.document, path, bound and bound.book_id)
end

function Plugin:_resolve_sync_context(context)
    local path = self:current_doc_path()
    local bound = path and Binding.get(self.store, path)
    if not SyncGate.matches(context, self.ui and self.ui.document, path,
        bound and bound.book_id) then
        return nil
    end
    return path, bound
end

function Plugin:_stale_sync_context()
    self:info("当前书籍已变化,请重新触发同步")
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
    -- 离线重注(reinject,含解绑后按剩余绑定重建)只用本地缓存 + 用户选定的干净原书,
    -- 不碰网络、无需登录;联网同步(sync)仍须登录。clean_source 逃生舱在退出登录后
    -- 仍可用(作者第8轮意见),登录失效却本地有缓存时重建也不再被拦截(评审三轮 P1#2)。
    if mode ~= "reinject" and not self:require_login() then return end
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
        -- 多书绑定:任何一本书已有完整缓存即视为「可续传」。
        local completed=false
        for _, bid in ipairs(self:_book_ids(path)) do
            if U.file_exists(self.store:book_cache_path(bid).."/sync-cache/.completed") then completed=true; break end
        end
        if completed then
            -- 多书聚合:已处理章数 = 各书总量 - 各书待处理之和,不只看第一本(P1#4)。
            local agg=self:_aggregate_sync_state(path)
            local processed=math.max(0,(tonumber(agg.total) or 0)-(tonumber(agg.pending) or 0))
            local text
            if #self:_book_ids(path)>1 then
                -- 多书:不同远程书章节坐标独立,不推导单一连续章节范围(评审五轮 P1#1),
                -- 只展示聚合数量 + 失败/未知提示。
                local extra={}
                if agg.books_failed>0 then extra[#extra+1]=string.format("%d 本上次同步失败",agg.books_failed) end
                if agg.books_unknown>0 then extra[#extra+1]=string.format("%d 本剩余章节未知",agg.books_unknown) end
                local note=#extra>0 and ("\n"..table.concat(extra,"；")..",本次将重新尝试") or ""
                text=string.format("检测到本书已有完整同步缓存\n\n多书聚合:已处理 %d 章,还剩 %d 章\n本次从各书各自的续传位置开始检查新增章节\n结束章节需获取最新目录后确定\n同时补齐缓存中拉取失败的章节%s\n\n如需全部重新拉取,请先使用「重置本书」选项。",
                    processed,tonumber(agg.pending) or 0,note)
            else
                text=string.format("检测到本书已有完整同步缓存\n\n当前已处理到第 %d 章\n本次将从第 %d 章开始检查新增章节\n结束章节需获取最新目录后确定\n同时补齐缓存中拉取失败的章节\n\n如需全部重新拉取,请先使用「重置本书」选项。",
                    processed,processed+1)
            end
            UIManager:show(ConfirmBox:new{
                text=text,
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
        -- 多书:用聚合状态生成续拉提示(实际同步按每本书各自的 state.json 续传,P1#4)。
        local plan=BatchSync.plan(#self:_book_ids(path)>1 and self:_aggregate_sync_state(path) or self:_sync_state(bound.book_id),limit)
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
    local bound = path and Binding.get(self.store, path)
    if not bound then return false end
    -- 后台重注的硬前提是每本绑定书都有可解析的章节缓存;只看文件存在会把
    -- 空文件/损坏 JSON 误报成可重注,用户点进去才在子进程里失败。
    local Json = require("pickthought.json")
    local ids = self:_book_ids(path)
    if #ids == 0 then return false end
    local function read_json(cache_path)
        local raw = U.read_file(cache_path, true)
        if not raw then return nil end
        local ok, decoded = pcall(Json.decode, raw)
        return ok and type(decoded) == "table" and decoded or nil
    end
    local function valid_chapters(bid)
        local cache_path = self.store:book_cache_path(bid) .. "/sync-cache/chapters.json"
        local decoded = read_json(cache_path)
        if not decoded then return false end
        local ok, rows = pcall(Binding.normalize_chapters, decoded, bid)
        return ok and type(rows) == "table" and #rows > 0
    end
    local function valid_map(bid)
        local cache_path = self.store:book_cache_path(bid) .. "/sync-cache/map.json"
        if not U.file_exists(cache_path) then return true end
        local decoded = read_json(cache_path)
        if not decoded or type(decoded.signature) ~= "string"
            or decoded.signature == "" or type(decoded.map) ~= "table" then
            return false
        end
        local entries = 0
        for _, value in pairs(decoded.map) do
            if type(value) ~= "table" or type(value.hrefs) ~= "table"
                or #value.hrefs == 0 then
                return false
            end
            for _, href in ipairs(value.hrefs) do
                if type(href) ~= "string" or href == "" then return false end
            end
            entries = entries + 1
        end
        return entries > 0
    end

    local all_cached = true
    for _, bid in ipairs(ids) do
        if not valid_chapters(bid) or not valid_map(bid) then
            all_cached = false
            break
        end
    end
    if all_cached then
        -- 全部绑定书已缓存(含干净原书已同步),提供离线重注入口。
        return true
    end
    -- 任一本绑定书的章节缓存缺失/损坏时,后台重注必然无法读取该书的目录;
    -- 即使当前 EPUB 带注入标记或 map.json 看起来存在,也不能提前显示入口。
    return false
end

-- 离线重注入口:先让用户决定是否提供一份干净原书作为注入源。
-- 当 .orig 备份被污染(本身是撷思版)时,必须选一份干净原书才能重注(clean_source 逃生舱);
-- 选「直接重注」则走旧逻辑(依赖 .orig,脏备份会报错提示恢复原书)。
function Plugin:reinject_with_clean(path)
    local ConfirmBox=require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text="离线重注需要一份干净的原始 EPUB 作为注入源。\n\n"..
            "· 若原书备份(.orig)完好,可直接重注;\n"..
            "· 若 .orig 已被污染(本身已是撷思版),必须选一份干净原书才能重注。",
        ok_text="选择干净原书",
        ok_callback=function()
            self:pick_book("选择干净的原始 EPUB（未注入的）",function(clean)
                self:sync_entry(path,"reinject",{clean_source=clean})
            end)
        end,
        cancel_text="直接重注(用现有备份)",
        cancel_callback=function()
            self:sync_entry(path,"reinject")
        end,
    })
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

-- 聚合某本地书绑定的全部微信读书书的同步状态(P1#4):继续拉取 / 自动拉取 /
-- 报告不应只读取第一本绑定书,否则第二本有待同步内容时状态与范围会错。
-- 返回 {pending,total,next_index,completed,books_with_pending,books_failed,
--       books_unknown,multi_book,per_book={[bid]=state}}。
-- next_index 取「有待同步书里最早的续传位置」,使 BatchSync.plan 的起始章合理。
-- pending=nil(章节列表失败/为空)= 剩余未知:不得当作 0,单独计数 books_unknown,
-- 失败书不因聚合而消失(评审五轮 P1#2)。
function Plugin:_aggregate_sync_state(path)
    local ids=self:_book_ids(path)
    local agg={pending=0,total=0,next_index=0,completed=false,books_with_pending=0,
        books_failed=0,books_unknown=0,multi_book=#ids>1,per_book={}}
    if #ids==0 then return agg end
    local min_next=nil
    for _, bid in ipairs(ids) do
        local st=self:_sync_state(bid) or {}
        agg.per_book[tostring(bid)]=st
        if st.failed then agg.books_failed=agg.books_failed+1 end
        local p=tonumber(st.pending)
        if p==nil then
            agg.books_unknown=agg.books_unknown+1
        else
            agg.pending=agg.pending+p
            if p>0 then
                agg.books_with_pending=agg.books_with_pending+1
                local nidx=tonumber(st.next_index) or 0
                if min_next==nil or nidx<min_next then min_next=nidx end
            end
        end
        agg.total=agg.total+(tonumber(st.total) or 0)
        agg.next_index=math.max(agg.next_index,tonumber(st.next_index) or 0)
        if U.file_exists(self.store:book_cache_path(bid).."/sync-cache/.completed") then agg.completed=true end
    end
    if min_next~=nil then agg.next_index=min_next end
    return agg
end

-- 「继续拉取」菜单标签(多书聚合,评审五轮 P1#2):待同步章数之外,失败书/未知书
-- 也要在入口可见,不能因聚合 pending 为 0 而让「继续拉取」入口凭空消失。
function Plugin:_continue_sync_label(agg)
    local label
    if (agg.pending or 0) > 0 then
        label=string.format("继续拉取后续章节(还剩 %d 章)",agg.pending)
    else
        label="继续拉取后续章节(重试失败书)"
    end
    local extra={}
    if agg.books_with_pending>1 then extra[#extra+1]=string.format("%d 本待同步",agg.books_with_pending) end
    if agg.books_failed>0 then extra[#extra+1]=string.format("%d 本失败",agg.books_failed) end
    if agg.books_unknown>0 then extra[#extra+1]=string.format("%d 本剩余未知",agg.books_unknown) end
    if #extra>0 then label=label.."（"..table.concat(extra,"、").."）" end
    return label
end

-- 该本地书绑定的全部微信读书书 id(数组,按绑定时间升序),供多书同步入口统一
-- 传 book_ids(1:N 合集场景)。无绑定时回退到主绑定单元素列表,单绑定与旧行为一致。
function Plugin:_book_ids(path)
    local list = Binding.list(self.store, path)
    local ids = {}
    for _, rec in ipairs(list) do
        if type(rec) == "table" and type(rec.book_id) == "string" and rec.book_id ~= "" then
            ids[#ids + 1] = rec.book_id
        end
    end
    if #ids == 0 then
        local b = Binding.get(self.store, path)
        if b and type(b.book_id) == "string" and b.book_id ~= "" then ids[#ids + 1] = b.book_id end
    end
    return ids
end

-- 绑定书名快照:同步任务可能在后台运行期间切换文档或修改绑定,
-- 报告必须使用本次任务启动时的书名,不能依赖结束时的当前文档。
function Plugin:_binding_titles(path)
    local titles = {}
    for _, rec in ipairs(Binding.list(self.store, path)) do
        if type(rec) == "table" and type(rec.book_id) == "string" and rec.book_id ~= "" then
            local title = U.trim(tostring(rec.title or ""))
            if title ~= "" then titles[rec.book_id] = title end
        end
    end
    return titles
end

function Plugin:_sync_display_title(path, bound, book_ids, titles)
    -- 多书任务按 book_ids 顺序处理，弹窗刚打开时先显示第一本实际会处理的书；
    -- 后续由进度状态把标题更新为当前书目，不能把合集说明固定在标题上。
    local title = ""
    if type(book_ids) == "table" and #book_ids > 0 and type(titles) == "table" then
        title = U.trim(tostring(titles[tostring(book_ids[1])] or ""))
    end
    if title == "" then title = U.trim(tostring(bound and bound.title or "")) end
    return title ~= "" and title or self:doc_title_guess(path)
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

function Plugin:_batch_prompt_key(path)
    return table.concat(self:_book_ids(path or ""), ",")
end

function Plugin:_record_batch_failure(path, context, reason, prompt_key)
    local failure = BatchSync.failure(context, reason)
    if not failure then return false end
    local key = prompt_key or self:_batch_prompt_key(path)
    if key == "" then return false end
    local saved = self:_save_batch_prompt_state(key, failure)
    if not saved then
        logger.warn("[撷思][BatchSync] failed to save failed batch state", "key=", key)
    end
    return saved
end

function Plugin:_clear_batch_prompt_state(path, prompt_key)
    local key = prompt_key or self:_batch_prompt_key(path)
    if key == "" then return true end
    local state_path = self:_batch_prompt_path(key)
    local removed = os.remove(state_path)
    return removed or not U.file_exists(state_path)
end

function Plugin:_defer_batch_sync(operation_context, context, prompt_key, source, silent)
    self._auto_batch_started=true
    UIManager:nextTick(function()
        local path_now,bound_now=self:_resolve_sync_context(operation_context)
        if not path_now then
            self._auto_batch_started=nil
            self:_stale_sync_context()
            return
        end
        if not self:_start_sync_task(path_now,bound_now,"sync",{
            background=true,silent=silent,source=source,
            batch_context=context,batch_prompt_key=prompt_key,
        }) then self._auto_batch_started=nil end
    end)
end

-- ===== 后台同步任务运行时 =====
function Plugin:_persist_sync_state(runtime)
    self.store:set("sync_runtime",{
        status="active",doc_path=runtime.doc_path,book_id=runtime.book_id,title=runtime.title,
        book_ids=U.copy(runtime.book_ids or {}),titles=U.copy(runtime.titles or {}),
        source=runtime.source,task=runtime.task,started_at=runtime.started_at,
    })
end

function Plugin:_clear_sync_state() self.store:set("sync_runtime",{}) end

function Plugin:_start_sync_task(path,bound,mode,opts)
    opts=opts or {}
    -- 多书绑定:统一把全部绑定书 id 传给后台任务,各书独立续传/注入(1:N 合集)。
    local book_ids=self:_book_ids(path)
    local titles=self:_binding_titles(path)
    local title=self:_sync_display_title(path,bound,book_ids,titles)
    local source=opts.source or (opts.background and "batch_auto" or "manual")
    local runtime={doc_path=path,book_id=bound.book_id,book_ids=book_ids,titles=titles,
        title=title,mode=mode,source=source,started_at=os.time(),dialog=nil,background=false,
        batch_context=opts.batch_context,batch_prompt_key=opts.batch_prompt_key}
    local ok,err=self.sync_task:start({doc_path=path,book_id=bound.book_id,book_ids=book_ids,titles=U.copy(titles),title=title,mode=mode,
            source=source,clean_source=opts.clean_source,allow_memory_retry=opts.background ~= true},
        function(state) self:_on_sync_progress(runtime,state) end,
        function(result) self:_finish_sync(runtime,result) end)
    if not ok then
        if opts.batch_context then
            self:_record_batch_failure(path, opts.batch_context, err, opts.batch_prompt_key)
        end
        if opts.silent then
            logger.warn("[撷思][Sync] auto batch start failed",tostring(err))
            if opts.batch_context then self:toast("本批自动补批未完成,请从菜单手动重试",5) end
        elseif opts.batch_context then
            self:info(BatchSync.failure_text(opts.batch_context.plan, err))
        else
            self:info("无法启动后台同步:\n"..tostring(err))
        end
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
            local scope="本书"
            if tonumber(state.book_count) and tonumber(state.book_count)>1 then
                scope="当前书目《"..tostring(state.book_title or "绑定书目").."》"
            end
            local continuation=BatchSync.auto_enabled(self.store:preferences())
                and "或继续阅读时自动补。"
                or "或阅读到边界时按提示后台补。"
            self:toast(string.format(
                "%s共 %d 章。为防风控,单次最多拉 %d 章;"
                .."其余用「继续拉取后续章节」按钮,%s",scope,total,limit,continuation),6)
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
    -- 捕获当前阅读上下文,供下方 _resolve_sync_context 校验「仍是同一本书」;
    -- 此前该函数引用了未定义的 operation_context(=nil),onPageUpdate 的 pcall 会把
    -- 自动/确认同步的启动错误吞掉,表现为静默失效(评审四轮 P1#2)。切书后该上下文
    -- 不再匹配当前文档,resolve 返回 nil 触发过期提示。
    local operation_context=self:_capture_sync_context(path,bound)
    -- 多书聚合坐标与本地 EPUB 物理章节无可靠偏移映射,基于聚合 next_index/pending
    -- 的自动触发会误拉/漏拉(评审三轮 P1#3);多书场景暂禁用自动触发,用户仍可
    -- 手动「继续拉取」(走每本书各自的 state.json 续传)。
    if #self:_book_ids(path) > 1 then return end
    -- 多书聚合:任何一本有待同步章节都应触发自动/询问拉取,不只看第一本(P1#4)。
    local agg=self:_aggregate_sync_state(path)
    if agg.pending<=0 then return end
    local state=agg
    local doc=self.ui and self.ui.document
    if not doc then return end
    local ok_pages,total_pages=pcall(function() return doc:getPageCount() end)
    if not ok_pages or not tonumber(total_pages) or total_pages<=0 then return end
    local fragment,fragment_total=self:_batch_fragment_position(doc,page,total_pages)
    local preferences=self.store:preferences()
    local auto=BatchSync.auto_enabled(preferences)
    -- 多书:以绑定书集合为去重/忽略键,避免第一本忽略状态误伤其他书(P1#4)。
    local book_key=table.concat(self:_book_ids(path),",")
    local position_key=table.concat({book_key,tostring(fragment),
        tostring(fragment_total),tostring(state.next_index)},":")
    if self._batch_position_log_key~=position_key then
        self._batch_position_log_key=position_key
        logger.info("[撷思][BatchSync] reading position",
            "page=",tostring(page),"/",tostring(total_pages),
            "fragment=",tostring(fragment),"/",tostring(fragment_total),
            "next_index=",tostring(state.next_index))
    end
    local prompt_state = self:_batch_prompt_state(book_key)
    local should_offer,context=BatchSync.should_offer{
        state=state, batch_limit=preferences.sync_batch_limit,
        page=page, total_pages=total_pages,
        fragment=fragment, fragment_total=fragment_total,
        dismissed=not auto and prompt_state or nil,
        failed=prompt_state,
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
        local current_path,current_bound=self:_resolve_sync_context(operation_context)
        if not current_path then self:_stale_sync_context(); return end
        self:toast(BatchSync.background_text(context.plan),3)
        self:_defer_batch_sync(operation_context,context,book_key,"batch_auto",true)
        return
    end

    self._batch_prompt_open=true
    UIManager:show(ConfirmBox:new{
        text=BatchSync.prompt_text(context.plan,true),
        flush_events_on_show=true,
        ok_text="后台同步",
        ok_callback=function()
            self._batch_prompt_open=nil
            if self:_sync_mutation_blocked("已有同步任务进行中,本次不重复启动") then return end
            self:_defer_batch_sync(operation_context,context,book_key,"batch_confirm",false)
        end,
        cancel_text="暂不拉取",
        cancel_callback=function()
            self._batch_prompt_open=nil
            local dismissal=BatchSync.dismissal(context)
            if dismissal then self:_save_batch_prompt_state(book_key,dismissal) end
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
        self:_clear_batch_prompt_state(runtime.doc_path,runtime.batch_prompt_key)
        Thoughts.clear_memory_cache()
        self:_sync_report(result.report,runtime)
        return
    end
    local err=tostring(result.error or "未知错误")
    if runtime.batch_context then
        self:_record_batch_failure(runtime.doc_path,runtime.batch_context,err,runtime.batch_prompt_key)
    end
    if result.cancelled or err=="同步已取消" then
        self:toast("同步已取消;已拉取章节保留在断点,下次同步会续传",4)
        return
    end
    if runtime.batch_context then
        self:_sync_fail(BatchSync.failure_text(runtime.batch_context.plan,err))
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
        and not U.file_exists(tostring(state.task.result_path or ""))
        and not U.file_exists(tostring(state.task.cancel_path or "")) then
        self:_clear_sync_state()
        self.sync_task:clear_stale_awake()
        return
    end
    local book_ids=type(state.book_ids)=="table" and state.book_ids or {}
    if #book_ids==0 and state.book_id then book_ids={tostring(state.book_id)} end
    local titles=type(state.titles)=="table" and state.titles or {}
    local runtime={doc_path=state.doc_path,book_id=state.book_id,book_ids=book_ids,titles=titles,
        title=state.title,source=state.source or state.task.source or "recovery",
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
    local PerformanceMode=require("pickthought.performance_mode")
    local sync_book_ids=self:_book_ids(path)
    local sync_titles=type(self._binding_titles)=="function" and self:_binding_titles(path) or {}
    local sync_book_index={}
    for index,bid in ipairs(sync_book_ids or {}) do sync_book_index[tostring(bid)]=index end
    if not Trapper:info("正在读取本地书…") then return end
    -- Sync.run 内部对 api/fetch 已 pcall,但 ChapterMap/EpubReader 的意外异常
    -- 会死在协程里(Trapper 只记日志),必须在这里收敛成用户可见的失败。
    local ok,report,err=xpcall(function()
        return Sync.run{
            doc_path=path,
            book_id=bound.book_id,
            book_ids=sync_book_ids,
            titles=sync_titles,
            api=self.api,
            annotations=WebFetch:new(self.api),
            load_meta=function(p) return EpubReader.load(p) end,
            read_text=function(m,href) return (EpubReader.read(m,href)) end,
            read_spine=function(m,callback) return EpubReader.each_spine(m,callback) end,
            save_thoughts=function(book_id,uid,groups) return Thoughts.save(self.store,book_id,uid,groups) end,
            merge_thoughts=function(book_id,uid,from,into) return Thoughts.merge(self.store,book_id,uid,from,into) end,
            -- P1#2:前台也用函数式 map_cache_path,与后台一致(每书独立 map.json)。
            map_cache_path=function(bid) return self.store:book_dir(bid).."/sync-cache/map.json" end,
             inject=function(src,book_id,mapped,dest,options)
                 return EpubInject.inject_copy(src,book_id,mapped,
                    {dest=dest,append=options and options.append==true,
                     meta=options and options.meta,
                     -- 多书:透传全部绑定书 id,marker 记录完整来源(P1#4)。
                     book_ids=options and options.book_ids,
                     progress=options and options.progress,
                     -- 前台 Trapper 回退路径:降级让出必须用非阻塞方式。本路径 Sync.run
                     -- 处于 xpcall 内,Lua 5.1 无法跨 C 调用 yield,故不能用 coroutine.yield,
                     -- 也不能用 fu.usleep(会阻塞前台协程、不交还 UIManager)。这里显式传入
                     -- no-op rest,禁用 blocking rest(作者意见 #2 选项①)。子进程 worker 走
                     -- Sync.run 另一注入入口,保留默认 usleep 让出 CPU。
                     perf=PerformanceMode:new({ rest=function() end })})
            end,
             progress=function(phase,i,n,text,progress_book_id,metrics)
                 local msg
                 local book_index=progress_book_id and sync_book_index[tostring(progress_book_id)]
                 local book_title=progress_book_id and sync_titles[tostring(progress_book_id)] or nil
                 local book_prefix=(#sync_book_ids > 1 and book_index)
                     and string.format("当前书目 %d/%d：《%s》\n",book_index,#sync_book_ids,book_title or "绑定书目") or ""
                 metrics=type(metrics)=="table" and metrics or {}
                 local count=SyncProgress.format_count
                 if phase=="chapters" then msg=book_prefix.."正在获取章节列表…"
                 elseif phase=="fetch" then msg=book_prefix..string.format("正在拉取划线与想法 %d/%d\n%s\n当前章节已拉取：划线 %s 条，想法 %s 条\n本轮累计已拉取：划线 %s 条，想法 %s 条\n%s\n(点按屏幕可取消)",
                     i,n,tostring(text or ""),count(metrics.current_fetch_underlines),
                     count(metrics.current_fetch_thoughts),count(metrics.fetch_underlines),count(metrics.fetch_thoughts),
                     tostring(metrics.fetch_message or ""))
                 elseif phase=="map" then
                     if n and n>0 and i and i>0 then
                         msg=string.format("正在匹配本地章节 %d/%d 个正文文件",i,n)
                         msg=msg.."\n本轮已拉取：章节 "..count(metrics.fetch_chapters)
                             .." 章，划线 "..count(metrics.fetch_underlines)
                             .." 条，想法 "..count(metrics.fetch_thoughts).." 条"
                         if metrics.current_file and metrics.current_file~="" then
                             msg=msg.."\n当前文件："..tostring(metrics.current_file)
                                 .."\n当前文件关联：划线 "..count(metrics.current_file_underlines)
                                 .." 条，想法 "..count(metrics.current_file_thoughts).." 条"
                         end
                         msg=msg.."\n本轮累计已匹配：划线 "..count(metrics.matched_underlines)
                             .." 条，想法 "..count(metrics.matched_thoughts).." 条"
                         msg=msg.."\n本轮累计已扫描：正文文件 "..count(metrics.matched_files).." 个"
                         if n>200 then msg=msg.."\n书籍较大时，此阶段可能持续较长时间。\n具体耗时取决于书籍大小、设备性能和想法数量。\n进度会继续，请耐心等待，勿强制退出 KOReader。" end
                     else msg="正在匹配本地章节…" end
                 else
                     msg="正在生成划线版并替换…"
                     msg=msg.."\n本轮已拉取：章节 "..count(metrics.fetch_chapters)
                         .." 章，划线 "..count(metrics.fetch_underlines)
                         .." 条，想法 "..count(metrics.fetch_thoughts).." 条"
                     if metrics.current_file_target and metrics.current_file then
                         msg=msg.."\n当前文件："..tostring(metrics.current_file)
                             .."\n当前文件注入：划线 "..count(metrics.current_file_underlines)
                             .." 条，想法 "..count(metrics.current_file_thoughts).." 条"
                     end
                     msg=msg.."\n本轮累计注入：划线 "..count(metrics.injected_underlines)
                         .." 条，想法 "..count(metrics.injected_thoughts).." 条"
                         .."\n书籍较大时，此阶段可能持续较长时间。"
                         .."\n具体耗时取决于书籍大小、设备性能和想法数量。"
                         .."\n进度会继续，请耐心等待，勿强制退出 KOReader。"
                 end
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

function Plugin:_sync_report(report,runtime)
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
    -- 后台任务优先使用启动时快照,避免任务结束后当前文档/绑定变化导致明细串书。
    local titles=runtime and runtime.titles
    if type(titles)~="table" or next(titles)==nil then
        local p=runtime and runtime.doc_path or self:current_doc_path()
        titles=p and self:_binding_titles(p) or {}
    end
    local lines=SyncReport.build(report,{
        auto_batch=BatchSync.auto_enabled(self.store:preferences()),
        titles=titles,
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

function Plugin:restore_original(path, confirmed)
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
    local function do_restore()
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
    end
    -- confirmed=true 时静默还原(解绑后重建用,避免二次确认),否则弹确认框。
    if confirmed then do_restore(); return end
    UIManager:show(ConfirmBox:new{
        text="将用原书备份覆盖当前划线版,书内注入的划线与想法会移除(想法缓存保留)。",
        ok_text="还原原书",
        ok_callback=function()
            if self:_sync_mutation_blocked("同步任务已开始,本次还原已取消") then return end
            if is_open and path ~= self:current_doc_path() then
                self:_stale_sync_context()
                return
            end
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

-- 绑定集合变化(移除/解绑)后,从 .orig 按剩余绑定重建注入版,移除已解绑书的内容残留(P2#7)。
-- 无剩余绑定则直接还原原版(移除全部注入内容);原书备份缺失则提示无法重建。
function Plugin:_rebuild_from_orig(path)
    local orig = path..".orig"
    if not U.file_exists(orig) then
        self:toast("未找到原书备份,无法重建(已解绑,注入内容可能残留)")
        return
    end
    local ids = self:_book_ids(path)
    if #ids == 0 then
        -- 全部解绑:还原原版,移除所有注入内容。
        self:restore_original(path, true)
        return
    end
    -- 仍有绑定:离线重建(用各书本地缓存),不重新联网拉取;重建后只含剩余书内容。
    self:toast("正在按剩余绑定重建注入版…")
    self:sync_entry(path, "reinject")
end

-- 重置本书:清该书所有同步缓存/想法/映射 + 还原原书(若有注入)。
-- 双重确认(破坏性)。回到"未同步+原版书"状态,保留绑定关系。重新同步即可恢复。
local RESET_TARGETS = {"sync-cache", "thoughts", "thoughts.db", "thoughts.db-wal", "thoughts.db-shm", "thoughts.db.isolated"}

function Plugin:reset_book_data(path)
    if self:_sync_mutation_blocked("同步任务进行中,请等它完成或取消后再重置本书") then return end
    path = path or self:current_doc_path()
    if not path then self:info("请先选择一本书"); return end
    local bound = Binding.get(self.store, path)
    local has_orig = U.file_exists(path..".orig")
    -- 多书绑定:每本书有独立 sync-cache,重置需逐本清理。
    local book_ids = self:_book_ids(path)
    local book_dirs = {}
    for _, bid in ipairs(book_ids) do book_dirs[#book_dirs+1] = self.store:book_dir(bid) end
    if #book_dirs == 0 and not has_orig then self:info("这本书无撷思数据,也无原书备份"); return end
    local title = self:doc_title_guess(path)
    local lines = {}
    if #book_dirs > 0 then
        lines[#lines+1] = "• 清同步缓存/想法数据库/章节映射" .. (#book_dirs > 1 and string.format("(%d 本)", #book_dirs) or "")
    end
    if has_orig then lines[#lines+1] = "• 还原原书(移除书内划线)" end
    UIManager:show(ConfirmBox:new{
        text = string.format("将重置《%s》:\n\n%s\n\n保留绑定关系,重新同步即可恢复。", title, table.concat(lines, "\n")),
        ok_text = "继续",
        ok_callback = function()
            if self:_sync_mutation_blocked("同步任务已开始,本次重置已取消") then return end
            UIManager:show(ConfirmBox:new{
                text = "再次确认:重置《"..title.."》?\n此操作不可撤销。",
                ok_text = "确认重置",
                ok_callback = function()
                    if self:_sync_mutation_blocked("同步任务已开始,本次重置已取消") then return end
                    self:_do_reset_book_data(book_dirs, path, title)
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

function Plugin:_do_reset_book_data(book_dirs, path, title)
    local cleared, size_bytes = 0, 0
    local was_open = path == self:current_doc_path()
    -- 先关闭 SQLite 句柄,再删除数据库文件,避免关闭时重新触碰已删除的 WAL。
    Thoughts.clear_memory_cache()
    for _, book_dir in ipairs(book_dirs) do
        size_bytes = size_bytes + self:_dir_size(book_dir)
        for _, name in ipairs(RESET_TARGETS) do
            if U.remove_tree(book_dir .. "/" .. name) then cleared = cleared + 1 end
        end
    end
    self._sync_state_cache = nil
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
    if self:_sync_mutation_blocked("同步任务进行中,请等它完成或取消后再重置全部书籍") then return end
    UIManager:show(ConfirmBox:new{
        text = "将重置所有书:\n\n• 清全部书的同步缓存/想法/映射\n• 还原所有注入书为原版\n\n保留绑定关系,各书需重新同步。",
        ok_text = "继续",
        ok_callback = function()
            if self:_sync_mutation_blocked("同步任务已开始,本次重置已取消") then return end
            UIManager:show(ConfirmBox:new{
                text = "再次确认:重置全部书籍?\n此操作不可撤销。",
                ok_text = "确认重置",
                ok_callback = function()
                    if self:_sync_mutation_blocked("同步任务已开始,本次重置已取消") then return end
                    self:_do_clear_all()
                end,
                cancel_text = "取消",
            })
        end,
        cancel_text = "取消",
    })
end

function Plugin:_do_clear_all()
    if self:_sync_mutation_blocked("同步任务进行中,暂不能重置全部书籍") then return end
    local lfs = require("libs/libkoreader-lfs")
    local root = self.store.cache_books_dir
    local total_size, book_count, restored_count = 0, 0, 0
    -- 先关闭所有 SQLite 句柄,再删除数据库文件,避免关闭时重新触碰已删除的 WAL。
    Thoughts.clear_memory_cache()
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
    -- 未指定旧字体枚举时返回正文基准大小；新弹窗以相对字号 0 表示跟随正文。
    local factor=factors[tostring(level)] or 1
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
    PopupDiagnostic.set_enabled(self.store:preferences().debug_mode==true)
    local owns_request=PopupDiagnostic.current_id()==nil
    if owns_request then PopupDiagnostic.begin() end
    local started=PopupDiagnostic.now()
    PopupDiagnostic.log("show_begin", {book=info.book_id, chapter=info.chapter_uid, range=info.range})
    local ok,unexpected=xpcall(function()
        local find_started=PopupDiagnostic.now()
        local group,err=Thoughts.find(self.store,info.book_id,info.chapter_uid,info.range)
        PopupDiagnostic.log("thought_find", {elapsed_ms=PopupDiagnostic.elapsed(find_started), ok=group~=nil})
        if not group then self:info(tostring(err or "没有想法内容")); return end
        local items_started=PopupDiagnostic.now()
        local items=Thoughts.popup_items(group)
        PopupDiagnostic.log("popup_items", {elapsed_ms=PopupDiagnostic.elapsed(items_started), count=#items})
        if #items==0 then self:info("没有想法内容"); return end
        local require_started=PopupDiagnostic.now()
        local ThoughtPopup=require("pickthought.thought_popup")
        PopupDiagnostic.log("popup_module_require", {elapsed_ms=PopupDiagnostic.elapsed(require_started)})
        local config_started=PopupDiagnostic.now()
        local PopupConfig=require("pickthought.thought_popup.popup_config")
        local options=PopupConfig.build(self,items)
        PopupDiagnostic.log("popup_config_build", {elapsed_ms=PopupDiagnostic.elapsed(config_started)})
        local popup_started=PopupDiagnostic.now()
        ThoughtPopup.show(options)
        PopupDiagnostic.log("popup_show_return", {elapsed_ms=PopupDiagnostic.elapsed(popup_started), total_ms=PopupDiagnostic.elapsed(started)})
        logger.info("[撷思][ThoughtPopup] opened",
            "book=",tostring(info.book_id),"chapter=",tostring(info.chapter_uid),
            "comments=",tostring(#(group.texts or {})),
            "elapsed_ms=",tostring(PopupDiagnostic.elapsed(started)))
    end,debug.traceback)
    self._thought_popup_busy=false
    if not ok then
        logger.err("[撷思][ThoughtPopup] open failed",tostring(unexpected))
        self:info("想法弹窗打开失败：\n"..U.first_line(unexpected,220))
    end
    PopupDiagnostic.log("show_end", {elapsed_ms=PopupDiagnostic.elapsed(started), ok=ok})
    if owns_request then PopupDiagnostic.finish() end
    return true
end

function Plugin:_on_thought_tap(ges)
    if not self.ui or not self.ui.link or not self.ui.link.getLinkFromGes then return false end
    PopupDiagnostic.set_enabled(self.store:preferences().debug_mode==true)
    PopupDiagnostic.begin()
    PopupDiagnostic.log("tap_begin", {})
    local link_started=PopupDiagnostic.now()
    local ok,link=pcall(self.ui.link.getLinkFromGes,self.ui.link,ges)
    PopupDiagnostic.log("link_lookup", {elapsed_ms=PopupDiagnostic.elapsed(link_started), ok=ok, found=link~=nil})
    if not ok or not link then PopupDiagnostic.finish(); return false end
    local parse_started=PopupDiagnostic.now()
    local href=extract_thought_href(link,{},0)
    PopupDiagnostic.log("link_parse", {elapsed_ms=PopupDiagnostic.elapsed(parse_started), found=href~=nil})
    if not href then PopupDiagnostic.finish(); return false end
    local result=self:_show_thought_href(href)
    PopupDiagnostic.finish()
    return result
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
    pcall(function() require("pickthought.thought_popup").cleanup() end)
    self:_teardown_thought_tap()
end

function Plugin:onFlushSettings() self.store:flush() end

return Plugin
