import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]


class DebugModeContractTests(unittest.TestCase):
    def test_default_is_disabled(self):
        store = (ROOT / "pickthought.koplugin/pickthought/store.lua").read_text(encoding="utf-8")
        self.assertIn("debug_mode=false", store)

    def test_settings_menu_exposes_persistent_toggle(self):
        # R4 之后设置菜单构造器在 pickthought/ui/menus.lua。
        menus = (ROOT / "pickthought.koplugin/pickthought/ui/menus.lua").read_text(encoding="utf-8")
        self.assertIn('text = "调试模式(记录详细同步日志)"', menus)
        self.assertIn("p.debug_mode = not (p.debug_mode == true)", menus)
        self.assertIn("plugin.store:save_preferences(p)", menus)

    def test_diagnostic_sampling_is_gated(self):
        task = (ROOT / "pickthought.koplugin/pickthought/sync_task.lua").read_text(encoding="utf-8")
        self.assertIn("local debug_mode = diagnostics_enabled(preferences)", task)
        self.assertIn("if not debug_mode then return end", task)


if __name__ == "__main__":
    unittest.main()
