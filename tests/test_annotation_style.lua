local AnnotationStyle = require("pickthought.annotation_style")

T.case("标注样式恢复默认橙色虚线并保留正文颜色", function()
    T.ok(AnnotationStyle.CSS:find("border-bottom: 2px dashed #ff6b35;", 1, true),
        "样式恢复橙色虚线")
    T.ok(AnnotationStyle.CSS:find("padding-bottom: 2px;", 1, true),
        "保留默认虚线间距")
    T.ok(AnnotationStyle.CSS:find("color: inherit;", 1, true),
        "想法正文继承原色")
    T.ok(not AnnotationStyle.CSS:find("text-decoration-color:", 1, true),
        "不依赖下划线颜色属性")
    T.ok(AnnotationStyle.css_is_current(AnnotationStyle.CSS), "新样式被识别为当前版本")
    T.ok(not AnnotationStyle.css_is_current([[
        /* MIUREAD_ANNOTATION_STYLE_V2_BEGIN */
        .pickthought-mark { text-decoration: underline; text-decoration-color: #ff6b35; color: inherit; }
    ]]), "旧白色实线样式不被误判为当前版本")
end)

T.case("旧白色实线样式可改写为默认虚线样式", function()
    local old = [[
/* MIUREAD_ANNOTATION_STYLE_V2_BEGIN */
.pickthought-mark { text-decoration: underline; text-decoration-color: #ff6b35; color: inherit; }
/* MIUREAD_ANNOTATION_STYLE_V2_END */
]]
    local rewritten, changed = AnnotationStyle.rewrite_css(old)
    T.ok(changed, "旧样式应被改写")
    T.ok(rewritten:find("border-bottom: 2px dashed #ff6b35;", 1, true), "写入默认虚线")
    T.ok(not rewritten:find("text-decoration-color:", 1, true), "移除白色实线样式")
end)

T.case("运行时划线样式键规范化", function()
    T.eq(AnnotationStyle.normalize_runtime_style(nil), "default", "空值使用默认样式")
    T.eq(AnnotationStyle.normalize_runtime_style("thin_solid"), "thin_solid", "合法样式保留")
    T.eq(AnnotationStyle.normalize_runtime_style("unknown"), "default", "未知样式回退默认")
end)

T.case("运行时样式只覆盖统一注入 class", function()
    local solid = AnnotationStyle.runtime_css("thin_solid")
    T.ok(solid:find(".pickthought-inline-mark", 1, true) ~= nil, "实线覆盖普通划线")
    T.ok(solid:find(".pickthought-mark", 1, true) ~= nil, "实线覆盖想法划线")
    T.ok(solid:find("border-bottom: 1px solid", 1, true) ~= nil, "实线为 1px")
    T.ok(solid:find("!important", 1, true) ~= nil, "覆盖规则具有优先级")
    T.ok(solid:find("display", 1, true) == nil, "不修改 display")
    T.ok(solid:find("white-space", 1, true) == nil, "不修改 white-space")
end)

T.case("隐藏样式不删除想法链接", function()
    local hidden = AnnotationStyle.runtime_css("hidden")
    T.ok(hidden:find("text-decoration: none", 1, true) ~= nil, "隐藏视觉下划线")
    T.ok(hidden:find("border-bottom: 0", 1, true) ~= nil, "清除边框")
    T.ok(hidden:find("pointer-events", 1, true) == nil, "保留想法链接点击")
end)

T.case("细虚线运行时样式使用统一 class", function()
    local dashed = AnnotationStyle.runtime_css("thin_dashed")
    T.ok(dashed:find("border-bottom: 1px dashed", 1, true) ~= nil, "虚线为 1px")
    T.ok(dashed:find(".pickthought-inline-mark", 1, true) ~= nil, "虚线覆盖普通划线")
    T.ok(dashed:find(".pickthought-mark", 1, true) ~= nil, "虚线覆盖想法划线")
end)

T.case("默认运行时样式不追加覆盖", function()
    T.eq(AnnotationStyle.runtime_css("default"), "", "默认样式使用 EPUB 内联 CSS")
end)

T.case("文字样式归一化:非法值回落跟随正文", function()
    T.eq(AnnotationStyle.normalize_text_style(nil), "normal", "空值默认 normal")
    T.eq(AnnotationStyle.normalize_text_style("bold"), "bold", "合法值保留")
    T.eq(AnnotationStyle.normalize_text_style("huge"), "normal", "非法值回落")
    T.eq(AnnotationStyle.DEFAULT_TEXT_STYLE, "normal", "默认即跟随正文")
end)

T.case("跟随正文用 !important 压过书内链接色与默认层 navy(Issue #23)", function()
    local css = AnnotationStyle.text_runtime_css("normal")
    T.ok(css:find("color: inherit !important", 1, true) ~= nil,
        "颜色强制继承(书内 a 色规则与 epub.css navy 均失效)")
    T.ok(css:find("font-weight: inherit !important", 1, true) ~= nil,
        "字重继承")
    T.ok(css:find(".pickthought-link", 1, true) ~= nil,
        "覆盖想法链接(带想法的划线是 a 标签,灰色来源)")
    T.ok(css:find(".pickthought-inline-mark", 1, true) ~= nil,
        "覆盖普通划线")
end)

T.case("加粗与淡化文字样式", function()
    local bold = AnnotationStyle.text_runtime_css("bold")
    T.ok(bold:find("font-weight: bold !important", 1, true) ~= nil, "加粗")
    T.ok(bold:find("color: inherit !important", 1, true) ~= nil, "加粗时颜色仍继承")
    local gray = AnnotationStyle.text_runtime_css("gray")
    T.ok(gray:find("color: #888888 !important", 1, true) ~= nil, "淡化灰")
    T.ok(gray:find("font%-weight", 1, true) == nil, "淡化不改字重")
end)

T.case("斜体文字样式(Issue #23 追加)", function()
    T.eq(AnnotationStyle.normalize_text_style("italic"), "italic", "斜体为合法选项")
    local css = AnnotationStyle.text_runtime_css("italic")
    T.ok(css:find("font-style: italic !important", 1, true) ~= nil, "斜体样式")
    T.ok(css:find("color: inherit !important", 1, true) ~= nil, "颜色保持继承")
    T.ok(css:find("font%-weight", 1, true) == nil, "斜体不改字重")
end)
