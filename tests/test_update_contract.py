from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]


class UpdateContractTests(unittest.TestCase):
    def read(self, relative):
        return (ROOT / relative).read_text(encoding="utf-8")

    def test_menu_exposes_update_controls(self):
        # R4 之后菜单构造器在 pickthought/ui/menus.lua;收纳重组(2026-09-07)后
        # 更新/关于/重置全部书籍收纳进设置抽屉,各仅一处。
        menus = self.read("pickthought.koplugin/pickthought/ui/menus.lua")
        main = self.read("pickthought.koplugin/main.lua")
        for marker in (
            'text = "查看更新日志"',
            'text = "检查更新（当前版本 · " .. tostring(plugin.version) .. "）"',
            '{text = "更新", sub_item_table_func = function() return M.update_about_menu(plugin) end}',
            '{text = "关于", callback = plugin:safe("about", function() plugin:show_about() end)}',
            '{text = "重置全部书籍", callback = plugin:safe("clear_all", function() plugin:clear_all_data() end)}',
            "p.update.auto_update",
            "p.update.notify_update",
        ):
            self.assertIn(marker, menus)
        for marker in (
            "function Plugin:maybe_auto_check_update",
            "function Plugin:_do_update",
        ):
            self.assertIn(marker, main)
        update_menu = menus.split("function M.update_about_menu(plugin)", 1)[1].split(
            "return M", 1
        )[0]
        self.assertNotIn('text = "关于"', update_menu)
        self.assertNotIn('text = "当前版本', update_menu)
        self.assertNotIn('text = "重置全部书籍"', update_menu)
        self.assertNotIn("更新与关于", main)
        self.assertIn("撷思发现新版本 %s，请前往「更新」查看", main)
        self.assertEqual(
            menus.count('{text = "更新", sub_item_table_func = function() return M.update_about_menu(plugin) end}'),
            1,
            "更新入口收纳在设置抽屉内,仅一处",
        )

    def test_install_completion_offers_restart(self):
        source = self.read("pickthought.koplugin/main.lua")
        self.assertIn('ok_text="立即重启"', source)
        self.assertIn("UIManager:restartKOReader()", source)

    def test_progress_and_cleanup_contracts_exist(self):
        updater = self.read("pickthought.koplugin/pickthought/updater.lua")
        progress = self.read("pickthought.koplugin/pickthought/update_progress.lua")
        self.assertIn('local part=p..".part"', updater)
        self.assertIn("os.remove(part)", updater)
        self.assertIn("function Updater:download_to", updater)
        self.assertIn("on_progress", updater)
        self.assertIn("ProgressWidget", progress)
        self.assertIn('text="取消下载"', progress)

    def test_reset_clears_isolation_marker_without_targeting_corrupt_backups(self):
        source = self.read("pickthought.koplugin/main.lua")
        self.assertIn('"thoughts.db.isolated"', source)
        self.assertNotIn('"*.corrupt-*"', source)

        reset_body = source.split("function Plugin:_do_reset_book_data", 1)[1].split(
            "function Plugin:_dir_size", 1
        )[0]
        self.assertLess(
            reset_body.index("Thoughts.clear_memory_cache()"),
            reset_body.index("for _, name in ipairs(RESET_TARGETS)"),
            "重置应先关闭 SQLite 句柄再删除数据库文件",
        )


if __name__ == "__main__":
    unittest.main()
