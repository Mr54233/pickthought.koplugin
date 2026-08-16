from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]


class UpdateContractTests(unittest.TestCase):
    def read(self, relative):
        return (ROOT / relative).read_text(encoding="utf-8")

    def test_menu_exposes_update_controls(self):
        source = self.read("pickthought.koplugin/main.lua")
        for marker in (
            'text="查看更新日志"',
            'text="检查更新（当前版本 · "..tostring(self.version).."）"',
            'items[#items+1]={text="更新",sub_item_table_func=function() return self:update_about_menu() end}',
            'items[#items+1]={text="关于",callback=self:safe("about",function() self:show_about() end)}',
            'items[#items+1]={text="重置全部书籍",callback=self:safe("clear_all",function() self:clear_all_data() end)}',
            'p.update.auto_update=',
            'p.update.notify_update=',
            'function Plugin:maybe_auto_check_update',
            'function Plugin:_do_update',
        ):
            self.assertIn(marker, source)
        update_menu = source.split("function Plugin:update_about_menu()", 1)[1].split("-- 启动后", 1)[0]
        self.assertNotIn('text="关于"', update_menu)
        self.assertNotIn('text="当前版本', update_menu)
        self.assertNotIn('text="重置全部书籍"', update_menu)
        self.assertNotIn('更新与关于', source)
        self.assertIn('撷思发现新版本 %s，请前往「更新」查看', source)
        self.assertEqual(source.count('items[#items+1]={text="更新",sub_item_table_func=function() return self:update_about_menu() end}'), 2)
        self.assertEqual(source.count('items[#items+1]={text="关于",callback=self:safe("about",function() self:show_about() end)}'), 2)
        self.assertEqual(source.count('items[#items+1]={text="重置全部书籍",callback=self:safe("clear_all",function() self:clear_all_data() end)}'), 2)

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


if __name__ == "__main__":
    unittest.main()
