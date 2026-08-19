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


if __name__ == "__main__":
    unittest.main()
