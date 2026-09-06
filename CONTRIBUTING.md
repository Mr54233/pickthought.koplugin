# 贡献指南 / Contributing

感谢你关注撷思（PickThought）——一个非官方的 KOReader 插件，从微信读书拉取一本书的热门划线与公开想法，引文对齐后注入本地已有的 EPUB。

为了让 Issue 和 PR 更容易被处理，请遵循下面的规则。项目特定的开发知识见 [CLAUDE.md](CLAUDE.md)，发布流程见 [RELEASING.md](RELEASING.md)。

## 提交 Issue / Issues

提交 issue 前请先搜索已有 issue，并阅读 [README](README.md)。

**Bug 反馈必须包含：**

- 清晰的复现步骤，或能展示问题如何发生的截图/录屏；
- KOReader 日志（Kindle 上位于 `koreader/crash.log`，可 `grep 撷思` 过滤插件日志）；
- 插件版本号（Release 版本或 commit hash）；
- KOReader 版本号；
- 设备型号；
- 期望行为与实际行为。

**隐私：** 不要在 issue、日志、截图或 PR 中包含 API key、Cookie（`wr_skey`、`wr_rt`、`wr_vid`、`ptcz` 等）、账号信息或私人书籍内容。失败日志可能记录服务端原始响应体，分享 `crash.log` 前必须先检查并删除敏感信息。

## 提交 PR / Pull Requests

请让 PR 尽量聚焦。较大的功能建议先开 issue 讨论再实现。每个 PR 都必须说明它解决了什么问题或新增了什么特性。

- **Bugfix PR** 必须至少提供其一：关联 issue（`Fixes #123`）或原 bug 的清晰复现步骤，并说明如何验证修复。
- **Feature PR** 必须说明：新增了什么能力、改善了什么使用流程；涉及 UI、弹窗、排版或交互的，必须附真机截图或录屏。

## 项目约定

- **提交信息**：`<type>(<scope>): 中文说明`。type 使用 `feat`、`fix`、`perf`、`refactor`、`test`、`docs`、`ci`、`chore`；前缀可保留英文写法，说明必须中文。禁止无前缀的裸标题——`tools/release_notes.py` 无法分类，发版摘要会漏掉该提交。
- **模块命名空间**：项目自有 Lua 模块必须位于 `pickthought.koplugin/pickthought/` 下，以 `require("pickthought.<module>")` 加载；想法弹窗 UI 位于 `pickthought/thought_popup/`。禁止项目自有的根级 `lib/`、`ui/` 目录与 `require("lib.*")` 裸命名空间。KOReader 自带模块（`ui/*`、`device`、`logger`、`ffi/*`、`libs/*` 等）不受限。**由 `tools/check_namespace.py` 强制。**
- **日志**：统一 `logger.info/warn/err`，消息带 `[撷思][模块名]` 前缀，便于 `grep 撷思` 过滤。
- **用户可见文本**：当前仅中文，直接写中文字符串；如未来需要多语言，再引入统一的翻译模块，不在此提前抽象。
- **设置与数据**：会持续增长的数据（想法、评论、缓存、坐标映射等）一律存入专用 SQLite 数据库；`preferences` 只放小体量配置与关键状态，不放数据集合。
- **微信读书非公开 Web API**：新增或修改任何非公开接口，必须先在 `scripts/` 提交可独立运行、可复现的 Python 验证脚本，再实现 Lua 版本。脚本不得打印或保存真实凭据。
- **版本与发版**：`_meta.lua`、`pickthought/config.lua`、`update.json` 三个版本载体只允许经 `tools/prepare_release.py` 修改；**GitHub Release 只能由 `vX.Y.Z` tag 推送触发 workflow 创建，禁止手动 `gh release create`**。流程见 [RELEASING.md](RELEASING.md)。
- **禁止入库**：KOReader 的 `settings`、EPUB/缓存产物、真实凭据、私人书籍内容。**由 `tools/check_secrets.py` 强制。**

## 本地检查 / Local checks

提交 PR 前请运行：

```bash
luajit tests/run.lua                                  # Lua 测试全绿
python3 -m unittest discover -s tests -p 'test_*.py'  # Python 工具测试
python3 tools/check_namespace.py                      # 模块命名空间
python3 tools/check_secrets.py                        # 敏感信息扫描
git diff --check                                      # 补丁格式
```

改动了 `main.lua` 时额外执行 `luajit -bl pickthought.koplugin/main.lua` 做语法检查（main.lua 依赖 KOReader 运行时，不在测试覆盖内）。CI 还会构建并校验插件包（`tools/build_package.py` + `validate_package.py` + `validate_manifest.py`），本地如需自查可运行同样三步。

新增模块时记得在 `tests/run.lua` 的 files 列表注册对应测试文件。

`luacheck` 暂未引入，欢迎后续以独立 PR 添加配置并接入 CI。
