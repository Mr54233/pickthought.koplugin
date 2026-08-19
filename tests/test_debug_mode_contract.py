import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]


class DebugModeContractTests(unittest.TestCase):
    def test_default_is_disabled(self):
        store = (ROOT / "pickthought.koplugin/pickthought/store.lua").read_text(encoding="utf-8")
        self.assertIn("debug_mode=false", store)

    def test_settings_menu_exposes_persistent_toggle(self):
        main = (ROOT / "pickthought.koplugin/main.lua").read_text(encoding="utf-8")
        self.assertIn('text="调试模式(记录详细同步日志)"', main)
        self.assertIn("p.debug_mode=not (p.debug_mode==true)", main)
        self.assertIn("self.store:save_preferences(p)", main)

    def test_diagnostic_sampling_is_gated(self):
        task = (ROOT / "pickthought.koplugin/pickthought/sync_task.lua").read_text(encoding="utf-8")
        self.assertIn("local debug_mode = diagnostics_enabled(preferences)", task)
        self.assertIn("if not debug_mode then return end", task)


if __name__ == "__main__":
    unittest.main()
