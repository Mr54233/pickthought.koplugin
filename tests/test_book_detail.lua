-- 绑定书籍详情(Issue #28):字段归一化、行构建、简介截断、
-- 封面渲染与弹窗布局(有/无封面)。沿用 preload 隔离模式,放 UI 测试组末尾。

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
    return proto
end

-- —— cover_thumbnail 的 renderimage 桩 ——
-- 注意:main.lua 顶部 require 了 book_detail/cover_thumbnail,test_sync_frontend
-- 等更早的测试加载真实 main.lua 时会用通用 ui/* 桩把它们连带缓存;因此
-- 这里 preload + package.loaded 双清,强制本文件拿到自己的桩再加载。
local render_calls = { decode_fail = false, freed = 0 }
package.preload["ui/renderimage"] = function()
    local function fake_image(w, h)
        return {
            getWidth = function() return w end,
            getHeight = function() return h end,
            free = function() render_calls.freed = render_calls.freed + 1 end,
        }
    end
    local RenderImage = {}
    function RenderImage:renderImageFile(path)
        if render_calls.decode_fail then error("cover decode failed") end
        render_calls.last_source = path
        return fake_image(660, 990)
    end
    function RenderImage:scaleBlitBuffer(image, w, h)
        render_calls.scaled_to = {w = w, h = h}
        local scaled = fake_image(w, h)
        scaled.writePNG = function(_, target)
            render_calls.last_target = target
            render_calls.written = (render_calls.written or 0) + 1
        end
        return scaled
    end
    return RenderImage
end
package.loaded["ui/renderimage"] = nil
package.loaded["pickthought.cover_thumbnail"] = nil

local CoverThumbnail = require("pickthought.cover_thumbnail")
local Binding = require("pickthought.binding")

-- —— book_detail 的 UI 桩 ——
local widget_tree = {}
local shown = {}
-- preload + 清缓存双保险:全量套件里其他测试的通用 ui/* 加载器可能已把
-- 同名模块写进 package.loaded,preload 优先级再高也查不到缓存命中之前。
local function stub(mod, builder)
    package.preload[mod] = builder
    package.loaded[mod] = nil
end
stub("ffi/blitbuffer", function()
    return { COLOR_WHITE = "white", COLOR_GRAY = "gray", COLOR_BLACK = "black" }
end)
stub("ui/widget/button", function()
    return class():extend{
        new = function(_, fields)
            fields.press = function()
                if fields.callback then fields.callback() end
            end
            widget_tree[#widget_tree + 1] =
                {kind = "button", text = fields.text, fields = fields}
            return setmetatable(fields, {__index = {}})
        end,
    }
end)
for _, spec in ipairs({
    {"ui/widget/container/centercontainer", "center"},
    {"ui/widget/container/framecontainer", "frame"},
    {"ui/widget/horizontalgroup", "horizontal"},
    {"ui/widget/verticalgroup", "vertical"},
    {"ui/widget/imagewidget", "image"},
}) do
    stub(spec[1], function()
        return class():extend{
            new = function(_, fields)
                fields._kind = spec[2]
                widget_tree[#widget_tree + 1] = {kind = spec[2], fields = fields}
                return setmetatable(fields, {__index = {}})
            end,
        }
    end)
end
-- inputcontainer 用 class() 默认 new(会调 init),自定义 new 会吞掉
-- BookDetailDialog:init,导致子 widget 一个都不构建。
stub("ui/widget/container/inputcontainer", function() return class() end)
stub("ui/font", function()
    return { getFace = function(_, name, size) return {name = name, size = size} end }
end)
stub("ui/geometry", function()
    return { new = function(_, g) return g end }
end)
for _, spec in ipairs({{"ui/widget/horizontalspan", "hspan"},
    {"ui/widget/verticalspan", "vspan"}, {"ui/widget/textboxwidget", "textbox"},
    {"ui/widget/textwidget", "text"}}) do
    stub(spec[1], function()
        return class():extend{ new = function(_, f)
            widget_tree[#widget_tree + 1] = {kind = spec[2], fields = f}
            return setmetatable(f, {__index = {}})
        end }
    end)
end
stub("ui/size", function()
    return { padding = {small = 2, default = 5, large = 10},
        border = {thin = 1, button = 1, window = 2},
        radius = {window = 3} }
end)
local dirty_marked = {}
stub("ui/uimanager", function()
    return {
        show = function(_, w) shown[#shown + 1] = w end,
        close = function(_, w) w._closed = true end,
        scheduleIn = function() end,
        -- 长按路径必须显式入队刷新(行高亮已入队小区域,裸 show 的全屏兜底
        -- 不触发),契约:show 后紧跟 setDirty(dialog, "ui")。
        setDirty = function(_, w, mode)
            dirty_marked[#dirty_marked + 1] = {widget = w, mode = mode}
        end,
    }
end)
stub("device", function()
    return { screen = {getWidth = function() return 1072 end,
        getHeight = function() return 1448 end},
        isTouchDevice = function() return true end }
end)

package.loaded["pickthought.book_detail"] = nil
local BookDetail = require("pickthought.book_detail")

local function find_widgets(kind)
    local out = {}
    for _, w in ipairs(widget_tree) do
        if w.kind == kind then out[#out + 1] = w end
    end
    return out
end

T.case("normalize_search 透传版本区分字段(Issue #28)", function()
    local rows = Binding.normalize_search{books = {{
        bookInfo = {bookId = "b1", title = "马可瓦尔多", author = "卡尔维诺",
            format = "epub", cover = "https://cdn.example/cover.jpg",
            translator = "张密", publisher = "译林出版社", publishTime = "2020-01"},
    }}}
    T.eq(rows[1].format, "epub", "format 透传")
    T.eq(rows[1].cover, "https://cdn.example/cover.jpg", "cover 透传")
    T.eq(rows[1].translator, "张密", "translator 透传")
    T.eq(rows[1].title, "马可瓦尔多 [出版]", "既有后缀语义不变")
    local bare = Binding.normalize_search{books = {{
        bookInfo = {bookId = "b2", title = "网文", author = "作者"},
    }}}
    T.eq(bare[1].format, nil, "缺失字段为 nil 不是空串")
    T.eq(bare[1].cover, nil, "cover 缺失为 nil")
end)

T.case("normalize_book_info:顶层与嵌套形态、缺失默认", function()
    local full = {title = "马可瓦尔多", author = "卡尔维诺", translator = "张密",
        publisher = "译林出版社", publishTime = "2020-01", categoryName = "外国文学",
        intro = "简介", cover = "https://cdn/1.jpg", format = "epub"}
    local top = Binding.normalize_book_info(full)
    T.eq(top.translator, "张密", "顶层 translator")
    T.eq(top.publishTime, "2020-01", "顶层 publishTime")
    local nested = Binding.normalize_book_info{data = full}
    T.eq(nested.publisher, "译林出版社", "嵌套 data 形态")
    local empty = Binding.normalize_book_info(nil)
    T.eq(empty.title, "", "nil 输入返回全空默认")
    T.eq(empty.cover, "", "cover 默认空串")
    local alias = Binding.normalize_book_info{publish_time = "2019-12", category = "小说"}
    T.eq(alias.publishTime, "2019-12", "publish_time 别名")
    T.eq(alias.categoryName, "小说", "category 别名")
end)

T.case("build_rows:行序/缺失显示「—」/格式映射", function()
    local rows = BookDetail.build_rows{title = "马可瓦尔多", author = "卡尔维诺",
        translator = "张密", publisher = "译林出版社", publishTime = "2020-01",
        categoryName = "外国文学", format = "epub"}
    T.eq(#rows, 7, "六行基础 + 格式行")
    T.eq(rows[3][1], "译者", "行序:第三行译者")
    T.eq(rows[3][2], "张密", "译者值")
    T.eq(rows[7][2], "出版", "epub → 出版")
    local txt = BookDetail.build_rows{title = "网文", author = "作者", format = "txt"}
    T.eq(txt[3][2], "—", "txt 无译者显示 —")
    T.eq(txt[4][2], "—", "无出版社显示 —")
    T.eq(txt[7][2], "网络", "txt → 网络")
    local unknown = BookDetail.build_rows{format = "pdf"}
    T.eq(#unknown, 6, "未知格式不显示格式行")
end)

T.case("intro_excerpt:UTF-8 按字符安全截断", function()
    T.eq(BookDetail.intro_excerpt(nil), "", "nil → 空")
    T.eq(BookDetail.intro_excerpt("  "), "", "纯空白 → 空")
    local short = string.rep("中", 100)
    T.eq(BookDetail.intro_excerpt(short), short, "100 字不超限原样")
    local exact = string.rep("中", 120)
    T.eq(BookDetail.intro_excerpt(exact), exact, "恰好 120 字不截断")
    local long = string.rep("中", 150)
    local cut = BookDetail.intro_excerpt(long)
    T.eq(#cut, 120 * 3 + 3, "截到 120 个汉字 + 省略号")
    T.ok(cut:sub(-3, -1) == "…", "尾部省略号")
    local mixed = string.rep("a", 120) .. "中"
    local cut2 = BookDetail.intro_excerpt(mixed)
    T.eq(cut2, string.rep("a", 120) .. "…", "多字节边界整字符丢弃,不留半个字符")
end)

T.case("CoverThumbnail.render:缩放、写盘、释放", function()
    render_calls.decode_fail = false
    render_calls.freed = 0
    render_calls.scaled_to = nil
    local ok, result = CoverThumbnail.render("/tmp/cover.jpg", "/tmp/cover.png", 160, 240)
    T.eq(ok, "/tmp/cover.png", "返回目标路径")
    T.eq(render_calls.scaled_to.w, 160, "660×990 等比缩到 160 宽")
    T.eq(render_calls.scaled_to.h, 240, "高度 240")
    T.ok(render_calls.written == 1, "writePNG 恰一次")
    T.ok(render_calls.freed >= 2, "中间 blitbuffer 已释放")
    render_calls.decode_fail = true
    local failed, err = CoverThumbnail.render("/tmp/bad.jpg", "/tmp/bad.png", 160, 240)
    T.eq(failed, nil, "解码失败返回 nil")
    T.ok(err and tostring(err):find("cover decode failed", 1, true), "带错误信息")
    render_calls.decode_fail = false
end)

T.case("BookDetail.show:有封面布局含 ImageWidget 与全套文字行", function()
    widget_tree = {}
    shown = {}
    local bound = false
    local dialog = BookDetail.show{
        row = {book_id = "b1"},
        info = {title = "马可瓦尔多", author = "卡尔维诺", translator = "张密",
            publisher = "译林出版社", publishTime = "2020-01",
            categoryName = "外国文学", format = "epub", intro = "卡尔维诺的经典"},
        cover_path = "/tmp/cover.png",
        on_bind = function() bound = true end,
    }
    T.ok(#shown == 1, "弹窗已 show")
    T.eq(#dirty_marked, 1, "show 后显式入队刷新")
    T.eq(dirty_marked[1].mode, "ui", "刷新模式 ui")
    T.eq(dirty_marked[1].widget, shown[1], "刷新指向弹窗自身")
    local images = find_widgets("image")
    T.eq(#images, 1, "恰一个 ImageWidget")
    T.eq(images[1].fields.file, "/tmp/cover.png", "封面文件接线")
    local frames = find_widgets("frame")
    T.eq(frames[1].fields.width, math.floor(1072 * 0.85), "弹窗框定宽 85% 屏宽")
    local boxes = find_widgets("textbox")
    T.eq(#boxes, 8, "7 行字段 + 1 段简介,全部按列宽分配")
    local joined = {}
    for _, t in ipairs(boxes) do joined[#joined + 1] = tostring(t.fields.text) end
    local all = table.concat(joined, "|")
    T.ok(all:find("译者: 张密", 1, true), "译者行: " .. all)
    T.ok(all:find("出版社: 译林出版社", 1, true), "出版社行")
    T.ok(all:find("出版时间: 2020-01", 1, true), "出版时间行")
    local buttons = find_widgets("button")
    T.eq(#buttons, 2, "关闭 + 绑定此书")
    T.eq(buttons[2].text, "绑定此书", "绑定按钮文案")
    buttons[2].fields.press()
    T.ok(bound, "绑定回调触发")
    T.ok(dialog._closed, "弹窗随绑定关闭")
    T.eq(#dirty_marked, 2, "关闭也显式入队刷新")
    T.eq(dirty_marked[2].mode, "partial", "关闭刷新模式 partial")
end)

T.case("BookDetail.show:无封面纯文字布局", function()
    widget_tree = {}
    shown = {}
    BookDetail.show{
        row = {book_id = "b2"},
        info = {title = "网文", author = "作者", format = "txt"},
        cover_path = nil,
        on_bind = nil,
    }
    T.eq(#find_widgets("image"), 0, "无 ImageWidget")
    local buttons = find_widgets("button")
    T.eq(buttons[2].text, "绑定此书", "按钮仍在")
    T.eq(#find_widgets("textbox"), 7, "7 行字段按列宽分配,无简介不追加")
end)

T.case("BookDetail.show:on_bind 缺失时按钮无回调不报错", function()
    widget_tree = {}
    BookDetail.show{row = {book_id = "b3"}, info = {title = "x"}, cover_path = nil}
    local buttons = find_widgets("button")
    buttons[2].fields.press()
    T.ok(true, "无回调按下不抛错")
end)

T.case("R5 详情缓存:往返/封面/未命中/到期自删/损坏自删", function()
    local U = require("pickthought.util")
    -- 内存 FS 替身(同 test_sync with_memfs 模式),用完即还原。
    local saved = {}
    for _, k in ipairs({"mkdir", "read_file", "file_exists", "atomic_write"}) do
        saved[k] = U[k]
    end
    local fs = {}
    U.mkdir = function(p) fs[tostring(p)] = true; return true end
    U.read_file = function(p) return fs[tostring(p)] end
    U.file_exists = function(p) return fs[tostring(p)] ~= nil end
    U.atomic_write = function(p, d) fs[tostring(p)] = d; return true end
    -- drop_cache_files 走 os.remove(真 FS),memfs 下替身为同步清表项。
    local saved_remove = os.remove
    os.remove = function(p) fs[tostring(p)] = nil; return true end
    local store = {book_dir = function(_, id) return "/cache/" .. tostring(id) end}
    local info = {title = "马可瓦尔多", author = "卡尔维诺", translator = "张密",
        publisher = "译林出版社", publishTime = "2020-01", format = "epub",
        cover = "https://cdn/1.jpg", intro = "简介"}

    local m1, m1c = BookDetail.load_cache(store, "b1")
    T.eq(m1, nil, "未命中:无缓存返回 nil")
    T.eq(m1c, nil, "未命中无封面值")

    BookDetail.save_cache(store, "b1", info, nil)
    local got, cover = BookDetail.load_cache(store, "b1")
    T.eq(got ~= nil, true, "保存后命中")
    T.eq(got.translator, "张密", "字段往返完整")
    T.eq(cover, nil, "无封面缓存 cover 为 nil")

    fs["/cache/b2/" .. BookDetail.COVER_CACHE_NAME] = "PNGDATA"
    BookDetail.save_cache(store, "b2", info, "/cache/b2/" .. BookDetail.COVER_CACHE_NAME)
    local got2, cover2 = BookDetail.load_cache(store, "b2")
    T.eq(cover2, "/cache/b2/" .. BookDetail.COVER_CACHE_NAME, "封面路径命中")

    -- 到期:fetched_at 拨回 40 天前,读取应判过期并删除缓存文件。
    local Json = require("pickthought.json")
    local stale = Json.encode({fetched_at = os.time() - 40 * 24 * 3600,
        info = info, cover = true})
    fs["/cache/b3/book-info.json"] = stale
    fs["/cache/b3/" .. BookDetail.COVER_CACHE_NAME] = "PNGDATA"
    local e1 = BookDetail.load_cache(store, "b3")
    T.eq(e1, nil, "过期返回 nil")
    T.eq(fs["/cache/b3/book-info.json"], nil, "过期后详情 JSON 已自动删除")
    T.eq(fs["/cache/b3/" .. BookDetail.COVER_CACHE_NAME], nil, "过期后封面 PNG 已自动删除")

    -- 损坏:非法 JSON 同样触发自删。
    fs["/cache/b4/book-info.json"] = "{broken"
    fs["/cache/b4/" .. BookDetail.COVER_CACHE_NAME] = "PNGDATA"
    local c1 = BookDetail.load_cache(store, "b4")
    T.eq(c1, nil, "损坏返回 nil")
    T.eq(fs["/cache/b4/book-info.json"], nil, "损坏后文件已清理")

    -- 无书名:有效 JSON 但空 title → 按未命中(不动文件,save 侧不会写出该形态)。
    fs["/cache/b5/book-info.json"] = Json.encode({fetched_at = os.time(),
        info = {title = ""}})
    local t1 = BookDetail.load_cache(store, "b5")
    T.eq(t1, nil, "空书名按未命中")

    for k, v in pairs(saved) do U[k] = v end
    os.remove = saved_remove
end)
