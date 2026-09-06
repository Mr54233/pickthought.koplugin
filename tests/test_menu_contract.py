from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]


class MenuContractTests(unittest.TestCase):
    def test_annotation_style_is_not_duplicated_in_settings(self):
        source = (ROOT / "pickthought.koplugin/main.lua").read_text(encoding="utf-8")
        settings = source.split("function Plugin:settings_menu()", 1)[1].split(
            "function Plugin:annotation_style_label()", 1
        )[0]

        self.assertNotIn("划线样式", settings)
        self.assertNotIn("annotation_style_menu", settings)
        self.assertEqual(
            source.count("items[#items+1]=self:annotation_style_item()"),
            2,
            "文件管理器和已绑定书籍的阅读器菜单应各保留一个入口",
        )
        self.assertIn(
            'self:list("划线样式",self:annotation_style_menu())',
            source,
            "文件管理器的书籍更多操作应保留样式入口",
        )

    def test_bind_entry_not_duplicated_in_book_actions(self):
        # 作者 2026-08-20 第6轮意见:文件管理器操作菜单重复添加「重新绑定微信读书」入口。
        source = (ROOT / "pickthought.koplugin/main.lua").read_text(encoding="utf-8")
        book_actions = source.split("function Plugin:book_actions(", 1)[1].split(
            "function Plugin:doc_title_guess", 1
        )[0]
        self.assertEqual(
            book_actions.count('text=bound and "重新绑定微信读书" or "绑定微信读书"'),
            1,
            "文件管理器操作菜单只应有一个绑定/重新绑定入口",
        )

    def test_thought_popup_settings_replace_legacy_font_menu(self):
        source = (ROOT / "pickthought.koplugin/main.lua").read_text(encoding="utf-8")
        settings = source.split("function Plugin:settings_menu()", 1)[1].split(
            "function Plugin:annotation_style_label()", 1
        )[0]

        self.assertIn('text="想法弹窗设置"', settings)
        self.assertIn("function Plugin:thought_popup_menu()", source)
        self.assertNotIn("function Plugin:thought_font_menu()", source)
        for label in ("位置：", "高度：", "宽度：", "字号：", "字体对比度：", "点击左右区域翻页"):
            self.assertIn(label, source, f"想法弹窗设置缺少：{label}")
        self.assertNotIn('text="恢复默认尺寸"', source, "恢复默认尺寸不应占用设置菜单入口")
        self.assertIn("default_value=popup_percent(fallback)", source, "宽高调节页应提供原生默认值按钮")

        config = (ROOT / "pickthought.koplugin/pickthought/config.lua").read_text(encoding="utf-8")
        self.assertIn("width_ratio = 0.90", config)
        self.assertIn("height_ratio = 0.80", config)
        self.assertIn("min_width_ratio = 0.60", config)
        self.assertIn("min_height_ratio = 0.50", config)
        self.assertIn("ratio_step = 5", config)
        self.assertIn("value_step=PopupConfig.LIMITS.ratio_step", source)

    def test_thought_popup_entry_uses_shared_config_and_document_cleanup(self):
        source = (ROOT / "pickthought.koplugin/main.lua").read_text(encoding="utf-8")

        self.assertIn(
            'local PopupConfig=require("pickthought.thought_popup.popup_config")',
            source,
        )
        self.assertIn("local options=PopupConfig.build(self,items)", source)
        self.assertIn("ThoughtPopup.show(options)", source)
        self.assertIn('require("pickthought.thought_popup").cleanup()', source)

    def test_thought_popup_settings_include_comment_cache(self):
        # 想法评论查看(需求文档 2026-09-05):设置菜单必须有评论缓存入口,
        # 且选择器支持关闭/5/10/30 分钟/1 小时,关闭时清空当前书缓存。
        # (2026-09-06:原用例误写在 unittest.main() 之后从未被执行,移回类内。)
        source = (ROOT / "pickthought.koplugin/main.lua").read_text(encoding="utf-8")
        self.assertIn("评论缓存：", source)
        self.assertIn("function Plugin:show_comment_cache_picker()", source)
        for label in ('"关闭"', '"5 分钟"', '"10 分钟"', '"30 分钟（默认）"', '"1 小时"'):
            self.assertIn(label, source)
        self.assertIn("comment_cache_seconds=seconds", source)
        self.assertIn("ReviewComments.Cache.new", source)

    def test_thought_popup_wires_on_view_comments(self):
        # 弹窗只持有只读回调:main.lua 构造 options 时注入 on_view_comments,
        # 闭包捕获锚点解析出的 book_id;弹窗组件不得直接持有 store。
        # (2026-09-06:原用例误写在 unittest.main() 之后从未被执行,移回类内。)
        source = (ROOT / "pickthought.koplugin/main.lua").read_text(encoding="utf-8")
        self.assertIn("options.on_view_comments=function(item,popup)", source)
        self.assertIn("self:_show_thought_comments(item,popup_book_id,popup)", source)
        popup_entry = (ROOT / "pickthought.koplugin/pickthought/thought_popup.lua").read_text(encoding="utf-8")
        self.assertIn("on_view_comments = opts.on_view_comments", popup_entry)
        for widget in ("center_widget", "widget"):
            text = (ROOT / f"pickthought.koplugin/pickthought/thought_popup/{widget}.lua").read_text(encoding="utf-8")
            self.assertIn('_("查看评论")', text, f"{widget} 缺少评论菜单项")
            self.assertIn("enabled = viewable", text, f"{widget} 缺少置灰逻辑")
            self.assertIn("_enterComments", text)
            self.assertIn("_backToThoughts", text)

    def test_comment_counts_lazy_prefetch_wiring(self):
        # 评论数懒加载(需求 2026-09-06):视口稳定(翻页/滚动停下防抖)后
        # 只补当前可见条目。组件暴露 visible_thought_items/refresh_comment_counts
        # 和防抖回调;scroll_container 提供 on_offset_changed;布局缓存 key
        # 必须包含 comment_count,否则补数后不重排。
        source = (ROOT / "pickthought.koplugin/main.lua").read_text(encoding="utf-8")
        self.assertIn("options.on_visible_items_settled=function()", source)
        self.assertIn(
            "self:_prefetch_visible_comment_counts(popup,popup_book_id)", source
        )
        self.assertIn(
            "function Plugin:_prefetch_visible_comment_counts(popup,book_id)", source
        )
        popup_entry = (ROOT / "pickthought.koplugin/pickthought/thought_popup.lua").read_text(encoding="utf-8")
        self.assertIn("on_visible_items_settled = opts.on_visible_items_settled", popup_entry)
        for widget in ("center_widget", "widget"):
            text = (ROOT / f"pickthought.koplugin/pickthought/thought_popup/{widget}.lua").read_text(encoding="utf-8")
            self.assertIn("function", text)
            self.assertIn("visible_thought_items", text, f"{widget} 缺少可见条目查询")
            self.assertIn("_onVisibleItemsChanged", text, f"{widget} 缺少视口防抖")
            self.assertIn("refresh_comment_counts", text, f"{widget} 缺少刷新")
        scroll = (ROOT / "pickthought.koplugin/pickthought/thought_popup/scroll_container.lua").read_text(encoding="utf-8")
        self.assertIn("on_offset_changed", scroll)
        pages = (ROOT / "pickthought.koplugin/pickthought/thought_popup/pages.lua").read_text(encoding="utf-8")
        self.assertIn("item.comment_count", pages, "布局缓存 key 必须含 comment_count")

    def test_comment_fetch_notice_setting(self):
        # 用户拍板(2026-09-06):批量拉取的几秒里默认弹"正在获取评论数…"
        # 提示;想法弹窗设置提供开关,默认开(nil 视为开,向后兼容)。
        source = (ROOT / "pickthought.koplugin/main.lua").read_text(encoding="utf-8")
        self.assertIn('text="评论数获取提示"', source)
        self.assertIn("comment_fetch_notice~=false", source)
        self.assertIn('"正在获取评论数…"', source)

    def test_comment_prefetch_constants_declared_before_use(self):
        # 回归(2026-09-06 真机"想法弹窗打开失败 time.lua arithmetic on nil"):
        # 节奏常量的 local 声明在 _show_thought_href 之后,Lua local 无提升,
        # 函数内读到全局 nil → scheduleIn(nil) 崩溃。声明必须在使用点之前。
        source = (ROOT / "pickthought.koplugin/main.lua").read_text(encoding="utf-8")
        decl = source.find("local COMMENT_PREFETCH_FIRST_DELAY")
        use = source.find("function Plugin:_show_thought_href")
        self.assertGreaterEqual(decl, 0, "找不到节奏常量声明")
        self.assertGreater(use, 0, "找不到 _show_thought_href")
        self.assertLess(decl, use, "节奏常量必须声明在 _show_thought_href 之前(local 无提升)")


if __name__ == "__main__":
    unittest.main()
