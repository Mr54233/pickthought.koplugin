local AnnotationStyle = require("pickthought.annotation_style")

T.case("标注样式保留正文颜色并单独设置下划线颜色", function()
    T.ok(AnnotationStyle.CSS:find("text-decoration-color: #ff6b35;", 1, true),
        "样式设置橙色下划线")
    T.ok(AnnotationStyle.CSS:find("color: inherit;", 1, true),
        "想法正文继承原色")
    T.ok(not AnnotationStyle.CSS:find("\n    color: #ff6b35;", 1, true),
        "不把想法正文设置为橙色")
    T.ok(AnnotationStyle.css_is_current(AnnotationStyle.CSS), "新样式被识别为当前版本")
    T.ok(not AnnotationStyle.css_is_current([[
        /* MIUREAD_ANNOTATION_STYLE_V2_BEGIN */
        .pickthought-mark { text-decoration: underline; color: #ff6b35; }
    ]]), "旧橙色正文样式不被误判为当前版本")
end)

T.case("旧样式可改写为低内存样式", function()
    local old = [[
/* MIUREAD_ANNOTATION_STYLE_V2_BEGIN */
.pickthought-mark { border-bottom: 2px dashed #ff6b35; padding-bottom: 2px; }
/* MIUREAD_ANNOTATION_STYLE_V2_END */
]]
    local rewritten, changed = AnnotationStyle.rewrite_css(old)
    T.ok(changed, "旧样式应被改写")
    T.ok(rewritten:find("text-decoration-color: #ff6b35;", 1, true), "写入新下划线颜色")
    T.ok(not rewritten:find("border-bottom: 2px dashed", 1, true), "移除边框样式")
end)
