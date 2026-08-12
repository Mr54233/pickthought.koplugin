local Compat = require("pickthought.annotation_compat")

local function new_annotation_module()
    local module = {}
    function module.buildAnnotation(self, bookmark)
        return {id = bookmark.id, page = bookmark.page}
    end
    function module.getAnnotationsFromBookmarksHighlights(self, bookmarks, highlights, init)
        self.get_calls = (self.get_calls or 0) + 1
        local annotations = {}
        for i = #bookmarks, 1, -1 do
            table.insert(annotations, self:buildAnnotation(bookmarks[i], highlights, init))
        end
        if init then self:sortItems(annotations) end
        return annotations
    end
    function module.sortItems(self, annotations)
        self.sorted = annotations
    end
    return module
end

local function new_reader(module, rolling, valid)
    local calls = 0
    local document = {
        isXPointerInDocument = function(_, pointer)
            calls = calls + 1
            return valid[pointer] == true
        end,
    }
    local reader = setmetatable({ui = {rolling = rolling}, document = document}, {
        __index = module,
    })
    return reader, function() return calls end
end

T.case("annotation compat 保留有效起止 xpointer", function()
    local module = new_annotation_module()
    T.ok(Compat.install(module), "安装成功")
    local reader = new_reader(module, true, {start = true, finish = true})
    local item = reader:buildAnnotation({id = 1, page = "start", pos1 = "finish"})
    T.eq(item.id, 1, "有效划线保留")
end)

T.case("annotation compat 跳过无效起点", function()
    local module = new_annotation_module()
    T.ok(Compat.install(module), "安装成功")
    local reader = new_reader(module, true, {finish = true})
    T.eq(reader:buildAnnotation({id = 2, page = "bad"}), nil, "无效起点跳过")
end)

T.case("annotation compat 跳过无效终点", function()
    local module = new_annotation_module()
    T.ok(Compat.install(module), "安装成功")
    local reader = new_reader(module, true, {start = true})
    T.eq(reader:buildAnnotation({id = 3, page = "start", pos1 = "bad"}), nil,
        "无效终点跳过")
end)

T.case("annotation compat 分页模式不检查 xpointer", function()
    local module = new_annotation_module()
    T.ok(Compat.install(module), "安装成功")
    local reader, calls = new_reader(module, false, {})
    local item = reader:buildAnnotation({id = 4, page = "bad", pos1 = "also-bad"})
    T.eq(item.id, 4, "分页注释保留")
    T.eq(calls(), 0, "分页模式不调用 xpointer 检查")
end)

T.case("annotation compat 混合加载只保留有效项", function()
    local module = new_annotation_module()
    T.ok(Compat.install(module), "安装成功")
    local reader = new_reader(module, true, {one = true, three = true})
    local items = reader:getAnnotationsFromBookmarksHighlights({
        {id = 1, page = "one"},
        {id = 2, page = "bad"},
        {id = 3, page = "three"},
    }, {}, true)
    T.eq(#items, 2, "只返回两个有效注释")
    T.eq(reader.get_calls, 1, "调用原始批量加载函数")
    T.eq(items[1].id, 3, "保留有效注释 3")
    T.eq(items[2].id, 1, "保留有效注释 1")
end)

T.case("annotation compat 重复安装不会重复包裹", function()
    local module = new_annotation_module()
    T.ok(Compat.install(module), "首次安装成功")
    local build = module.buildAnnotation
    local get = module.getAnnotationsFromBookmarksHighlights
    T.ok(Compat.install(module), "重复安装成功")
    T.eq(module.buildAnnotation, build, "buildAnnotation 只包裹一次")
    T.eq(module.getAnnotationsFromBookmarksHighlights, get, "批量加载只包裹一次")
end)

T.case("annotation compat 缺少检查 API 时保留注释", function()
    local module = new_annotation_module()
    T.ok(Compat.install(module), "安装成功")
    local reader = setmetatable({ui = {rolling = true}, document = {}}, {
        __index = module,
    })
    local item = reader:buildAnnotation({id = 5, page = "unknown"})
    T.eq(item.id, 5, "缺少 API 不误删注释")
end)
