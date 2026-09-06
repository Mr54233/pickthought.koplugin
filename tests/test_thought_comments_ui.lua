-- 想法评论 UI:居中/底部弹窗的菜单入口、导航栈与 X 键返回语义
-- (实施文档 §4/§5)。沿用 test_thought_popup_widgets 的 preload 隔离模式,
-- 放在全部弹窗测试之后加载,避免污染其他模块。

local function class(proto)
    proto = proto or {}
    proto.__index = proto
    function proto:extend(fields)
        fields = fields or {}
        fields.__index = fields
        return setmetatable(fields, {__index = self})
    end
    function proto:new(fields)
        local value = setmetatable(fields or {}, self)
        if value.init then value:init() end
        return value
    end
    function proto:clear() self.cleared = true end
    return proto
end

local shown_widgets = {}
local closed_widgets = {}
local notices = {}
-- 记录 scheduleIn 的定时器(评论数懒加载防抖用);unschedule 从记录中移除,
-- 与真实 UIManager 的语义对齐,才能断言"连续触发只保留最后一次"。
local scheduled_callbacks = {}
-- 只统计目标弹窗自身的关闭(菜单对话框/InfoMessage 的 close 不计入)。
local function close_count(popup)
    local n = 0
    for _, widget in ipairs(closed_widgets) do
        if widget == popup then n = n + 1 end
    end
    return n
end

package.preload["ui/bidi"] = function()
    return {
        flipIfMirroredUILayout = function(value) return value end,
        flipDirectionIfMirroredUILayout = function(value) return value end,
    }
end
local dialog_state = { last = nil }
package.preload["ui/widget/buttondialog"] = function()
    return class():extend{
        new = function(_, fields)
            dialog_state.last = fields
            return setmetatable(fields, {__index = getmetatable(fields) or {}})
        end,
    }
end
package.preload["ffi/blitbuffer"] = function() return {COLOR_WHITE = 255} end
package.preload["ui/widget/buttontable"] = function() return class() end
package.preload["ui/widget/container/centercontainer"] = function() return class() end
package.preload["ui/widget/container/bottomcontainer"] = function() return class() end
package.preload["device"] = function()
    return {
        input = {group = {Back = "Back", PgBack = "PgBack", PgFwd = "PgFwd"}},
        screen = {
            scaleBySize = function(_, value) return value end,
            getWidth = function() return 600 end,
            getHeight = function() return 800 end,
            getSize = function() return {w = 600, h = 800} end,
        },
        isTouchDevice = function() return false end,
        hasKeys = function() return false end,
        hasClipboard = false,
    }
end
package.preload["ui/widget/container/framecontainer"] = function() return class() end
package.preload["ui/font"] = function() return {getFace = function(_, name, size) return {name = name, size = size} end} end
package.preload["ui/geometry"] = function() return class() end
package.preload["ui/gesturerange"] = function() return class() end
package.preload["ui/widget/container/inputcontainer"] = function() return class() end
package.preload["ui/widget/infomessage"] = function()
    return class():extend{
        new = function(_, fields)
            notices[#notices + 1] = fields
            return setmetatable(fields, {__index = getmetatable(fields) or {}})
        end,
    }
end
package.preload["pickthought.thought_popup.pages"] = function() return {} end
package.preload["pickthought.thought_popup.page_viewport"] = function() return class() end
package.preload["pickthought.thought_popup.scroll_container"] = function() return class() end
package.preload["ui/widget/linewidget"] = function() return class() end
package.preload["ui/size"] = function()
    return {padding = {large = 8, default = 4}, radius = {window = 6}, line = {thick = 2}}
end
package.preload["ui/widget/titlebar"] = function() return class() end
package.preload["ui/uimanager"] = function()
    return {
        setDirty = function(_, target, mode, region)
            if _G.__dirty_capture then
                _G.__dirty_capture[#_G.__dirty_capture + 1] =
                    {target = target, mode = mode, region = region}
            end
        end,
        close = function(_, widget) closed_widgets[#closed_widgets + 1] = widget end,
        show = function(_, widget) shown_widgets[#shown_widgets + 1] = widget end,
        isWidgetShown = function(_, widget) return widget._shown ~= false end,
        forceRePaint = function() end,
        scheduleIn = function(_, delay, cb)
            local entry = {delay = delay, cb = cb}
            scheduled_callbacks[#scheduled_callbacks + 1] = entry
            return cb
        end,
        unschedule = function(_, cb)
            for i, entry in ipairs(scheduled_callbacks) do
                if entry.cb == cb then
                    table.remove(scheduled_callbacks, i)
                    return
                end
            end
        end,
    }
end
package.preload["ui/widget/verticalgroup"] = function() return class() end
package.preload["ui/widget/verticalspan"] = function() return class() end
package.preload["ui/widget/container/widgetcontainer"] = function() return {free = function() end} end

for _, name in ipairs({
    "ui/bidi", "ui/widget/buttondialog", "ffi/blitbuffer", "ui/widget/buttontable",
    "ui/widget/container/centercontainer", "ui/widget/container/bottomcontainer",
    "device", "ui/widget/container/framecontainer", "ui/font", "ui/geometry",
    "ui/gesturerange", "ui/widget/infomessage",
    "ui/widget/container/inputcontainer", "pickthought.thought_popup.pages",
    "pickthought.thought_popup.page_viewport", "pickthought.thought_popup.scroll_container",
    "ui/widget/linewidget", "ui/size", "ui/widget/titlebar", "ui/uimanager",
    "ui/widget/verticalgroup", "ui/widget/verticalspan",
    "ui/widget/container/widgetcontainer",
    "pickthought.thought_popup.comments_view",
    "pickthought.thought_popup.base_widget",
    "pickthought.thought_popup.center_widget", "pickthought.thought_popup.widget",
}) do package.loaded[name] = nil end
package.preload["pickthought.thought_popup.center_widget"] = nil
package.preload["pickthought.thought_popup.widget"] = nil
package.preload["pickthought.thought_popup.comments_view"] = nil
package.preload["pickthought.thought_popup.pages"] = nil

local CenterWidget = require("pickthought.thought_popup.center_widget")
local BottomWidget = require("pickthought.thought_popup.widget")

local original_items = {
    { abstract = "原文摘录", author = "原作者", content = "想法正文", likes_count = 2, review_id = "pr" },
    { abstract = "", author = "评论者", content = "另一条想法", likes_count = 0, review_id = "" },
}
local comment_result = {
    ok = true,
    items = {
        { author = "路人甲", content = "说得对", likes_count = 1, review_id = "c1" },
        { author = "路人乙", content = "学到了", likes_count = 0, review_id = "" },
    },
    total_count = 5,
    truncated = true,
}

-- 构造带桩渲染层的弹窗实例(_buildLayout 被实例桩替换,避免整树构建)。
local function new_popup(class_def, opts)
    opts = opts or {}
    -- 注意:先声明局部变量再构造表,闭包才能捕获(教训来自 check_exists=nil)。
    local popup
    popup = setmetatable({
        items = opts.items or original_items,
        page_index = opts.page_index or 1,
        on_view_comments = opts.on_view_comments,
        _shown = true,
        _pages = {
            setContent = function() end,
            freeContentCaches = function() popup.freed = (popup.freed or 0) + 1 end,
        },
        _page_starts = {0, 10, 20},
        container = {dimen = {x = 0, y = 0, w = 400, h = 300}},
        _scroll_container = {scroll_offset = opts.scroll_offset or 77},
    }, {__index = class_def})
    -- _buildLayout 桩:重置页码(居中语义)/消费滚动恢复(底部语义)。
    popup._buildLayout = function(self)
        self.builds = (self.builds or 0) + 1
        if self._restore_scroll_offset then
            self._consumed_scroll = self._restore_scroll_offset
            self._restore_scroll_offset = nil
        end
        if class_def == CenterWidget then self.page_index = 1 end
    end
    popup._syncButtons = function() end
    return popup
end

local function menu_buttons(popup, item)
    dialog_state.last = nil
    popup:_showThoughtActionMenu(item)
    T.ok(dialog_state.last ~= nil, "弹出操作菜单")
    return dialog_state.last.buttons
end

local function click_view_comments(popup, item)
    local buttons = menu_buttons(popup, item)
    local entry = buttons[1][1]
    T.eq(entry.text, "查看评论", "评论入口是菜单第一项")
    entry.callback()
    return entry
end

-- ---------------------------------------------------------------- 菜单入口

T.case("居中弹窗:查看评论菜单第一项,可用且点击后切换视图", function()
    closed_widgets, notices = {}, {}
    local delivered
    local popup = new_popup(CenterWidget, {
        on_view_comments = function(item, ref)
            delivered = ref
            return comment_result
        end,
    })
    local entry = click_view_comments(popup, popup.items[1])
    T.eq(entry.enabled, true, "带 review_id + 回调 → 可用")
    T.ok(delivered == popup, "回调收到弹窗引用")
    T.eq(popup._comment_view.title, "想法正文",
        "标题栏(原原文摘录的位置)显示被长按的想法")
    T.eq(#popup._navigation, 1, "想法视图状态已压栈")
    T.eq(popup._navigation[1].items, original_items, "压栈保存原想法条目")
    T.eq(popup._navigation[1].page_index, 1, "压栈保存当前页码")
    T.eq(popup.items[1].author, "路人甲", "内容区只有评论列表")
    T.eq(popup.items[1].content, "说得对")
    T.eq(popup.page_index, 1, "评论视图从第一页开始")
end)

T.case("底部弹窗:菜单一致,压栈保存滚动偏移", function()
    closed_widgets, notices = {}, {}
    local popup = new_popup(BottomWidget, {
        scroll_offset = 77,
        on_view_comments = function() return comment_result end,
    })
    click_view_comments(popup, popup.items[1])
    T.eq(popup._navigation[1].scroll_offset, 77, "压栈保存滚动偏移")
    T.eq(popup.items[1].abstract, "想法正文", "底部布局想法进 quote 块(原正文摘要位置)")
    T.eq(popup.items[1].content, "", "content 置空防重复")
end)

T.case("进入评论视图必须请求重绘(缺失会导致屏幕停留旧视图)", function()
    -- 文件头部 uimanager stub 的 setDirty 是 no-op;这里改为在弹窗实例上
    -- 记录:重绘请求走 UIManager:setDirty(self,...),用桩替换 UIManager
    -- 不可行(会破坏其他用例),改为给 stub 加全局捕获开关。
    local captured = {}
    _G.__dirty_capture = captured
    local popup = new_popup(CenterWidget, {on_view_comments = function() return comment_result end})
    popup:_enterComments(popup.items[1], comment_result)
    _G.__dirty_capture = nil
    T.ok(#captured > 0 and captured[1].target == popup and captured[1].mode == "partial",
        "居中弹窗进入评论视图后请求了 partial 重绘")
end)

T.case("缺 review_id:菜单项置灰,点击提示不切换", function()
    closed_widgets, notices = {}, {}
    local popup = new_popup(CenterWidget, {
        on_view_comments = function() return comment_result end,
    })
    local entry = menu_buttons(popup, { abstract = "", author = "甲", content = "x", review_id = "" })[1][1]
    T.eq(entry.enabled, false, "置灰")
    entry.callback()
    T.eq(popup._comment_view, nil, "未切换视图")
    T.ok(notices[#notices] and notices[#notices].text == "这条想法缺少评论 ID",
        "提示缺少评论 ID")
end)

T.case("未注入回调:菜单项置灰(不崩溃)", function()
    closed_widgets, notices = {}, {}
    local popup = new_popup(CenterWidget, {})
    local entry = menu_buttons(popup, popup.items[1])[1][1]
    T.eq(entry.enabled, false, "无回调时置灰")
    entry.callback()
    T.eq(popup._comment_view, nil)
end)

-- ---------------------------------------------------------------- 加载结果

T.case("回调返回失败:提示错误,不切换视图", function()
    closed_widgets, notices = {}, {}
    local popup = new_popup(CenterWidget, {
        on_view_comments = function()
            return { ok = false, error = "network", message = "网络不可用或请求超时" }
        end,
    })
    click_view_comments(popup, popup.items[1])
    T.eq(popup._comment_view, nil)
    T.ok(notices[#notices] and notices[#notices].text == "网络不可用或请求超时")
end)

T.case("回调返回 nil(异步联网等待):不切换,迟到结果经 _enterComments 投递", function()
    closed_widgets, notices = {}, {}
    local popup = new_popup(CenterWidget, {
        on_view_comments = function() return nil end,
    })
    click_view_comments(popup, popup.items[1])
    T.eq(popup._comment_view, nil, "等待期间视图不变")
    local delivered = popup:_enterComments(popup.items[1], comment_result)
    T.ok(delivered, "异步就绪后投递成功")
    T.eq(popup._comment_view.title, "想法正文")
end)

T.case("空评论:提示暂无评论,不切换视图", function()
    closed_widgets, notices = {}, {}
    local popup = new_popup(CenterWidget, {
        on_view_comments = function()
            return { ok = true, items = {}, total_count = 0 }
        end,
    })
    click_view_comments(popup, popup.items[1])
    T.eq(popup._comment_view, nil)
    T.ok(notices[#notices] and notices[#notices].text == "这条想法暂无评论")
end)

T.case("弹窗已关闭时迟到结果被丢弃", function()
    closed_widgets, notices = {}, {}
    local popup = new_popup(CenterWidget, {})
    popup._shown = false
    T.eq(popup:_enterComments(popup.items[1], comment_result), false, "不投递")
    T.eq(popup._comment_view, nil)
end)

-- ---------------------------------------------------------------- 返回与关闭

T.case("居中弹窗 X 键:评论视图第一次返回,再次关闭", function()
    closed_widgets, notices = {}, {}
    local popup = new_popup(CenterWidget, {
        page_index = 2,
        on_view_comments = function() return comment_result end,
    })
    click_view_comments(popup, popup.items[1])
    popup:_handleCloseAction()
    T.eq(popup._comment_view, nil, "第一次 X 返回想法视图")
    T.eq(close_count(popup), 0, "不关闭弹窗")
    T.eq(popup.items, original_items, "恢复原想法条目")
    T.eq(popup.page_index, 2, "恢复进入前页码")
    T.ok((popup.freed or 0) >= 1, "释放评论页位图缓存")
    popup:_handleCloseAction()
    T.eq(close_count(popup), 1, "想法视图 X 关闭整个弹窗")
end)

T.case("底部弹窗横向滑动:评论视图返回,想法视图关闭", function()
    closed_widgets, notices = {}, {}
    local popup = new_popup(BottomWidget, {
        scroll_offset = 77,
        on_view_comments = function() return comment_result end,
    })
    click_view_comments(popup, popup.items[1])
    popup:onSwipeClose(nil, {direction = "west",
        pos = {intersectWith = function() return true end}})
    T.eq(popup._comment_view, nil, "评论视图滑动返回")
    T.eq(close_count(popup), 0, "不关闭弹窗")
    T.eq(popup._consumed_scroll, 77, "恢复进入前滚动偏移")
    T.eq(popup.items, original_items)
    popup:onSwipeClose(nil, {direction = "west",
        pos = {intersectWith = function() return true end}})
    T.eq(close_count(popup), 1, "想法视图滑动关闭")
end)

T.case("物理 Back 键:与 X 键同语义", function()
    closed_widgets, notices = {}, {}
    local popup = new_popup(CenterWidget, {
        on_view_comments = function() return comment_result end,
    })
    click_view_comments(popup, popup.items[1])
    popup:onClose()
    T.eq(popup._comment_view, nil, "评论视图 Back 返回")
    T.eq(close_count(popup), 0)
    popup:onClose()
    T.eq(close_count(popup), 1, "想法视图 Back 关闭")
end)

T.case("返回后再次进入:重新压栈,位图缓存再次释放", function()
    closed_widgets, notices = {}, {}
    local popup = new_popup(CenterWidget, {
        on_view_comments = function() return comment_result end,
    })
    click_view_comments(popup, popup.items[1])
    popup:_handleCloseAction()
    local freed_after_first = popup.freed or 0
    click_view_comments(popup, popup.items[1])
    T.eq(popup._comment_view.title, "想法正文", "再次进入评论视图")
    T.eq(#popup._navigation, 1, "栈深度正确(不叠加旧状态)")
    popup:_handleCloseAction()
    T.ok((popup.freed or 0) > freed_after_first, "每次返回都释放评论缓存")
end)

-- ------------------------------------------------- 底部弹窗返回与定位回归

T.case("底部弹窗返回想法视图必须请求重绘(缺失表现为“回不去”)", function()
    -- 2026-09-05 真机回归:_backToThoughts 只重建布局不重绘,墨水屏停留
    -- 在评论视图,用户感知为"横向滑动没反应、回不到想法列表"。
    closed_widgets, notices = {}, {}
    local captured = {}
    _G.__dirty_capture = captured
    local popup = new_popup(BottomWidget, {
        scroll_offset = 77,
        on_view_comments = function() return comment_result end,
    })
    popup:_enterComments(popup.items[1], comment_result)
    T.ok(#captured > 0, "进入评论视图请求重绘")
    captured = {}
    _G.__dirty_capture = captured
    popup:_handleCloseAction()
    _G.__dirty_capture = nil
    T.ok(#captured > 0 and captured[1].target == popup and captured[1].mode == "partial",
        "返回想法视图后请求 partial 重绘")
end)

T.case("底部弹窗点击弹窗外:评论视图返回,想法视图关闭", function()
    closed_widgets, notices = {}, {}
    local popup = new_popup(BottomWidget, {
        scroll_offset = 77,
        on_view_comments = function() return comment_result end,
    })
    local ges = {pos = {notIntersectWith = function() return true end}}
    click_view_comments(popup, popup.items[1])
    popup:onTapClose(nil, ges)
    T.eq(popup._comment_view, nil, "评论视图点击弹窗外返回想法视图")
    T.eq(close_count(popup), 0, "第一次点击不直接关闭整个弹窗")
    popup:onTapClose(nil, ges)
    T.eq(close_count(popup), 1, "想法视图点击弹窗外关闭")
end)

T.case("底部评论视图长按定位:首条无 meta 行时映射偏移 +1", function()
    closed_widgets, notices = {}, {}
    local popup = new_popup(BottomWidget, {
        on_view_comments = function() return comment_result end,
    })
    popup:_enterComments(popup.items[1], comment_result)
    -- 评论视图 items:[1]=父想法引用块(无 meta),[2]=路人甲,[3]=路人乙
    T.eq(popup.items[1].author, "", "父想法引用块不带 meta 行(作者名不再多余)")
    T.eq(popup.items[1].likes_count, 0)
    popup._pages.layout = {pieces = {
        {variant = "quote", y = 0, piece_h = 10},
        {variant = "meta", y = 10, piece_h = 10},
        {variant = "content", y = 20, piece_h = 10},
        {variant = "meta", y = 30, piece_h = 10},
        {variant = "content", y = 40, piece_h = 10},
    }}
    T.eq(popup:_findItemAtContentY(5), popup.items[1], "长按引用块 → 父想法")
    T.eq(popup:_findItemAtContentY(12), popup.items[2], "第 1 个 meta → 第一条评论")
    T.eq(popup:_findItemAtContentY(35), popup.items[3], "第 2 个 meta → 第二条评论")
    popup:_handleCloseAction()
    popup._pages.layout = {pieces = {
        {variant = "quote", y = 0, piece_h = 10},
        {variant = "meta", y = 10, piece_h = 10},
        {variant = "content", y = 20, piece_h = 10},
        {variant = "meta", y = 30, piece_h = 10},
    }}
    T.eq(popup:_findItemAtContentY(12), original_items[1], "想法视图首条有 meta,不偏移")
    T.eq(popup:_findItemAtContentY(35), original_items[2])
end)

T.case("居中评论视图长按定位:全评论条目映射不偏移", function()
    closed_widgets, notices = {}, {}
    local popup = new_popup(CenterWidget, {
        on_view_comments = function() return comment_result end,
    })
    popup:_enterComments(popup.items[1], comment_result)
    -- 居中评论视图 items 全是评论(都带 meta 行):[1]=路人甲,[2]=路人乙
    popup._pages.layout = {pieces = {
        {variant = "meta", y = 0, piece_h = 10},
        {variant = "content", y = 10, piece_h = 10},
        {variant = "meta", y = 20, piece_h = 10},
        {variant = "content", y = 30, piece_h = 10},
    }}
    T.eq(popup:_findItemAtContentY(2), popup.items[1], "第 1 个 meta → 第一条评论")
    T.eq(popup:_findItemAtContentY(22), popup.items[2], "第 2 个 meta → 第二条评论")
end)

T.case("进入评论视图就地记录评论数:返回列表后 meta 行可显示 评论 N", function()
    closed_widgets, notices = {}, {}
    local thought_items = {
        { abstract = "原文", author = "原作者", content = "想法正文",
          likes_count = 2, review_id = "pr" },
    }
    local popup = new_popup(BottomWidget, {
        items = thought_items,
        on_view_comments = function() return comment_result end,
    })
    popup:_enterComments(thought_items[1], comment_result)
    T.eq(thought_items[1].comment_count, 5,
        "total_count 就地写入想法条目(item 与列表共享同一张表)")
    popup:_handleCloseAction()
    T.eq(thought_items[1].comment_count, 5, "返回列表后仍保留")
end)

-- ------------------------------------------------ 评论数后台补齐的刷新

T.case("底部:refresh_comment_counts 重绘想法视图且保留滚动位置", function()
    closed_widgets, notices = {}, {}
    local popup = new_popup(BottomWidget, { scroll_offset = 55 })
    local captured = {}
    _G.__dirty_capture = captured
    popup:refresh_comment_counts()
    _G.__dirty_capture = nil
    T.ok(#captured > 0 and captured[1].mode == "partial", "请求了 partial 重绘")
    T.eq(popup._consumed_scroll, 55, "刷新保留当前滚动位置")
end)

T.case("底部:评论视图下 refresh_comment_counts 不动作", function()
    closed_widgets, notices = {}, {}
    local popup = new_popup(BottomWidget, {
        on_view_comments = function() return comment_result end,
    })
    popup:_enterComments(popup.items[1], comment_result)
    local builds_before = popup.builds or 0
    popup:refresh_comment_counts()
    T.eq(popup.builds, builds_before, "评论视图下不重建布局")
end)

T.case("居中:refresh_comment_counts 保留页码", function()
    closed_widgets, notices = {}, {}
    local popup = new_popup(CenterWidget, { page_index = 2 })
    popup:refresh_comment_counts()
    T.eq(popup.page_index, 2, "重排后页码不回跳")
end)

-- ------------------------------------------------ 评论数懒加载(视口+防抖)

local viewport_pieces = {
    { variant = "quote", y = 0, piece_h = 10 },
    { variant = "meta", y = 10, piece_h = 10 },
    { variant = "content", y = 20, piece_h = 30 },
    { variant = "meta", y = 50, piece_h = 10 },
    { variant = "content", y = 60, piece_h = 10 },
    { variant = "meta", y = 70, piece_h = 10 },
}

T.case("底部:visible_thought_items 返回滚动窗口内的条目", function()
    closed_widgets, notices = {}, {}
    local popup = new_popup(BottomWidget, { scroll_offset = 45 })
    popup._pages.layout = { pieces = viewport_pieces }
    popup._scroll_container.viewport_h = 35
    local view = popup:visible_thought_items()
    T.eq(#view, 1, "窗口 [45,80):meta 行在窗内的只有第 2 条(第 3 个 meta 越界)")
    T.eq(view[1], original_items[2])
    popup._scroll_container.scroll_offset = 0
    view = popup:visible_thought_items()
    T.eq(#view, 1, "窗口 [0,35) 只有首屏")
    T.eq(view[1], original_items[1])
end)

T.case("居中:visible_thought_items 返回当前页窗口内的条目", function()
    closed_widgets, notices = {}, {}
    local popup = new_popup(CenterWidget, { page_index = 2 })
    popup._page_starts = { 0, 45 }  -- 内容 y 偏移
    popup._viewport_h = 35
    popup._pages.layout = { pieces = viewport_pieces }
    local view = popup:visible_thought_items()
    T.eq(#view, 1, "第 2 页窗口 [45,80)")
    T.eq(view[1], original_items[2])
    popup.page_index = 1
    view = popup:visible_thought_items()
    T.eq(#view, 1, "第 1 页窗口 [0,35)")
    T.eq(view[1], original_items[1])
end)

-- 手动触发一个定时器:先从记录表移除再执行,对齐真实 UIManager
-- 的语义(触发的定时器不再挂在队列上)。
local function fire_scheduled()
    local entry = table.remove(scheduled_callbacks, 1)
    if entry then entry.cb() end
end

T.case("视口防抖:连续翻页只保留最后一次,停稳才触发,评论视图不触发", function()
    closed_widgets, notices = {}, {}
    scheduled_callbacks = {}
    local popup = new_popup(BottomWidget, {})
    local fired = 0
    popup.on_visible_items_settled = function() fired = fired + 1 end
    popup:_onVisibleItemsChanged()
    popup:_onVisibleItemsChanged()
    popup:_onVisibleItemsChanged()
    T.eq(#scheduled_callbacks, 1, "前两个定时器被 unschedule,只保留最后一次")
    T.eq(scheduled_callbacks[1].delay, 0.6, "防抖 0.6 秒")
    fire_scheduled()
    T.eq(fired, 1, "停稳后触发一次")
    -- 评论视图下不触发补数
    popup._comment_view = { parent_item = {} }
    popup:_onVisibleItemsChanged()
    fire_scheduled()
    T.eq(fired, 1, "评论视图下回调空转")
    popup._comment_view = nil
    -- 未注入回调(异常防线):不崩溃也不挂定时器
    popup.on_visible_items_settled = nil
    popup:_onVisibleItemsChanged()
    T.eq(#scheduled_callbacks, 0, "未注入回调时不记录定时器")
end)

T.case("评论视图:长按评论不再提供查看评论入口(评论是最后一层)", function()
    closed_widgets, notices = {}, {}
    local popup = new_popup(CenterWidget, {
        on_view_comments = function() return comment_result end,
    })
    popup:_enterComments(popup.items[1], comment_result)
    local buttons = menu_buttons(popup, popup.items[1])
    for _, row in ipairs(buttons) do
        for _, entry in ipairs(row) do
            T.ok(entry.text ~= "查看评论", "评论视图不出现查看评论入口")
        end
    end
    T.eq(buttons[1][1].text, "复制", "评论层保留复制等操作")
    -- 回到想法视图:查看评论入口恢复
    popup:_handleCloseAction()
    local thought_buttons = menu_buttons(popup, popup.items[1])
    T.eq(thought_buttons[1][1].text, "查看评论", "想法视图保留查看评论")
end)

T.case("居中:点击弹窗外与 X 同语义(评论态返回,想法态关闭)", function()
    closed_widgets, notices = {}, {}
    local popup = new_popup(CenterWidget, {
        on_view_comments = function() return comment_result end,
    })
    local ges = {pos = {notIntersectWith = function() return true end}}
    click_view_comments(popup, popup.items[1])
    popup:onTapClose(nil, ges)
    T.eq(popup._comment_view, nil, "评论视图点击弹窗外返回想法视图")
    T.eq(close_count(popup), 0, "不直接关闭整个弹窗")
    popup:onTapClose(nil, ges)
    T.eq(close_count(popup), 1, "想法视图点击弹窗外关闭")
end)

T.case("底部:高度变化的重建请求整屏局部刷新(清旧帧残影)", function()
    -- 真机:底部弹窗底部锚定、高度随内容变,评论视图(高)退回想法视图(矮)
    -- 时旧帧超出新区域的部分不会被 container 局部刷新覆盖,e-ink 残影叠帧。
    closed_widgets, notices = {}, {}
    local popup = new_popup(BottomWidget, {
        scroll_offset = 77,
        on_view_comments = function() return comment_result end,
    })
    popup._buildLayout = function(self)
        if self._restore_scroll_offset then
            self._consumed_scroll = self._restore_scroll_offset
            self._restore_scroll_offset = nil
        end
        self.height = (self.height or 0) + 50  -- 每次重建都变高
    end
    local captured = {}
    _G.__dirty_capture = captured
    popup:_enterComments(popup.items[1], comment_result)
    popup:_handleCloseAction()
    _G.__dirty_capture = nil
    -- KOReader 绘图模型:refresh 只是把帧缓冲推给 e-ink;弹窗画小之后,
    -- 旧帧区域必须由底层阅读器重画进帧缓冲才不会残留——所以断言的是
    -- "标记全部窗口脏"(setDirty("all","partial")),而不是刷新区域。
    local found_all_dirty = false
    for _, c in ipairs(captured) do
        if c.target == "all" and c.mode == "partial" then found_all_dirty = true end
    end
    T.ok(found_all_dirty, "高度变化 → 标记全部窗口脏(setDirty all partial)")
    T.eq(popup._consumed_scroll, 77, "滚动位置仍恢复")
end)

T.case("居中:高度变化的重建请求整屏局部刷新(清上下残影)", function()
    -- 居中弹窗内容矮于视口时缩到内容高度(居中锚定),高度变化时上下两头
    -- 都会残影,与底部弹窗同款处理(用户拍板:两弹窗要改一起改)。
    closed_widgets, notices = {}, {}
    local popup = new_popup(CenterWidget, {
        on_view_comments = function() return comment_result end,
    })
    popup._buildLayout = function(self)
        self.page_index = 1
        self.height = (self.height or 0) + 40  -- 每次重建都变高
    end
    local captured = {}
    _G.__dirty_capture = captured
    popup:_enterComments(popup.items[1], comment_result)
    popup:_handleCloseAction()
    _G.__dirty_capture = nil
    local found_all_dirty = false
    for _, c in ipairs(captured) do
        if c.target == "all" and c.mode == "partial" then found_all_dirty = true end
    end
    T.ok(found_all_dirty, "高度变化 → 标记全部窗口脏(setDirty all partial)")
    T.eq(popup.page_index, 1, "页码恢复不受影响")
end)

-- ------------------------------------------------ 中间点击打开评论

-- 三分区手势的 pos 桩:坐标 + intersect 方法(居中走容器/视口 dimen)。
local function zone_ges(x, y)
    return {pos = setmetatable({x = x, y = y}, {__index = {
        intersectWith = function() return true end,
        notIntersectWith = function() return false end,
    }})}
end

T.case("居中:三分区——中间打开命中想法的评论,右侧翻页", function()
    closed_widgets, notices = {}, {}
    local opened = nil
    local popup = new_popup(CenterWidget, {
        page_index = 1,
        on_view_comments = function(item)
            opened = item
            return comment_result
        end,
    })
    popup.tap_to_page = true
    popup.comment_tap_open = true
    popup._viewport = {dimen = {x = 0, y = 0, w = 400, h = 300}}
    popup._pages.layout = {pieces = viewport_pieces}
    local thought_item = popup.items[1]
    -- 中 1/3(x=200,rel=0.5)且 y 命中 items[1] 的 meta(y10)
    popup:onTapClose(nil, zone_ges(200, 10))
    T.ok(opened == thought_item, "中间点击打开命中想法的评论")
    T.eq(popup._comment_view.title, "想法正文", "走与菜单相同的打开链路")
    -- 回想法视图:右 1/3(x=360,rel=0.9)翻下一页
    popup:_handleCloseAction()
    popup:onTapClose(nil, zone_ges(360, 10))
    T.eq(popup.page_index, 2, "右 1/3 下一页")
end)

T.case("居中:中间点击未开启时保持左右二分;评论视图无中间区", function()
    closed_widgets, notices = {}, {}
    local open_count = 0
    local popup = new_popup(CenterWidget, {
        page_index = 1,
        on_view_comments = function()
            open_count = open_count + 1
            return comment_result
        end,
    })
    popup.tap_to_page = true
    popup.comment_tap_open = false  -- 未开启:rel=0.5 按右半 → 下一页
    popup._viewport = {dimen = {x = 0, y = 0, w = 400, h = 300}}
    popup._pages.layout = {pieces = viewport_pieces}
    popup:onTapClose(nil, zone_ges(200, 10))
    T.eq(open_count, 0, "未开启时中间点击不打开评论")
    T.eq(popup.page_index, 2, "保持左右二分(rel=0.5 → 右半)")
    -- 评论视图:三分区不生效(中间区消失),tap 落回二分翻页
    popup.comment_tap_open = true
    popup.page_index = 1
    popup:_enterComments(popup.items[1], comment_result)
    T.ok(popup._comment_view ~= nil, "进入评论视图")
    popup:onTapClose(nil, zone_ges(200, 10))
    T.eq(open_count, 0, "评论视图无中间区:中间 tap 不再打开")
    T.eq(popup._comment_view ~= nil, true, "仍处于评论视图")
end)
