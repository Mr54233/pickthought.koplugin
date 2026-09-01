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

    def test_thought_popup_entry_uses_shared_config_and_document_cleanup(self):
        source = (ROOT / "pickthought.koplugin/main.lua").read_text(encoding="utf-8")

        self.assertIn(
            'local PopupConfig=require("pickthought.thought_popup.popup_config")',
            source,
        )
        self.assertIn("local options=PopupConfig.build(self,items)", source)
        self.assertIn("ThoughtPopup.show(options)", source)
        self.assertIn('require("pickthought.thought_popup").cleanup()', source)


if __name__ == "__main__":
    unittest.main()
