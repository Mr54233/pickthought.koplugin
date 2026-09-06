"""tools/check_namespace.py 与 tools/check_secrets.py 的回归测试。"""

import sys
import unittest
from pathlib import Path

TOOLS_DIR = Path(__file__).resolve().parent.parent / "tools"
sys.path.insert(0, str(TOOLS_DIR))

import check_namespace  # noqa: E402
import check_secrets  # noqa: E402


class SecretPatternTest(unittest.TestCase):
    def scan(self, text):
        hits = []
        for _label, pattern in check_secrets.PATTERNS:
            hits.extend(match.group(0) for match in pattern.finditer(text))
        return hits

    def test_real_credentials_are_detected(self):
        cases = [
            "Authorization: Bearer wrk-Ab12Cd34Ef56Gh78",
            "Cookie: wr_skey=AbCdEf12345678901234; wr_vid=1234567890",
            "x-wrpa-0: AAAABBBBCCCCDDDD",
            "thirdwx=AbCdEf123456",
        ]
        for text in cases:
            with self.subTest(text=text):
                self.assertTrue(self.scan(text), f"应命中: {text}")

    def test_placeholders_and_code_idioms_are_ignored(self):
        cases = [
            "wr_skey=XXX",                       # 约定占位
            "wr_skey=XXXXXXXXXXXXXXXX",          # 8+ 个 X 的占位
            "wrk-xxxxxxxxxxxxxxxx",              # 文档示例 key
            "wr_rt=Protocol.escape(refresh)",    # 源码赋值,非凭据
            "cookies.wr_skey and settings",      # 无等号赋值的普通代码
        ]
        for text in cases:
            with self.subTest(text=text):
                self.assertEqual(self.scan(text), [], f"不应命中: {text}")


class NamespaceTest(unittest.TestCase):
    def test_project_modules_resolve(self):
        self.assertTrue(check_namespace.module_exists("pickthought.util"))
        self.assertTrue(check_namespace.module_exists("pickthought.json"))
        self.assertTrue(
            check_namespace.module_exists("pickthought.thought_popup.pages")
        )

    def test_unknown_project_modules_fail(self):
        self.assertFalse(check_namespace.module_exists("pickthought.no_such"))
        self.assertFalse(check_namespace.module_exists("pickthought.popup.typo"))

    def test_require_pattern_covers_both_call_styles(self):
        for source in (
            'local u = require("pickthought.util")',
            "local ok, j = pcall(require, 'pickthought.json')",
        ):
            with self.subTest(source=source):
                modules = [
                    match.group(1)
                    for match in check_namespace.REQUIRE_RE.finditer(source)
                ]
                self.assertIn("pickthought.util" if "util" in source
                              else "pickthought.json", modules)

    def test_repo_currently_passes(self):
        self.assertEqual(check_namespace.main(), 0)


if __name__ == "__main__":
    unittest.main()
