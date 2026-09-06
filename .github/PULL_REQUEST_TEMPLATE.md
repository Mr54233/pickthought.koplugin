## 变更说明

请说明这个 PR 解决了什么问题，或者新增了什么特性。

## 类型

- [ ] Bugfix
- [ ] Feature
- [ ] Refactor
- [ ] Documentation
- [ ] Other

## Bugfix 要求

如果这是 bugfix，请至少提供以下其中一项：

- 关联 issue：`Fixes #123`
- 修复前的清晰复现步骤，并说明如何验证修复有效

## Feature 要求

如果这是新增特性，请说明：

- 新增了什么能力
- 典型使用场景
- 如果涉及 UI、弹窗、排版或交互，请附真机截图或录屏

## 测试

请说明你如何验证这个 PR。

- [ ] 已运行 `luajit tests/run.lua`（全绿）
- [ ] 已运行 `python3 -m unittest discover -s tests -p 'test_*.py'`
- [ ] 已运行 `python3 tools/check_namespace.py` 与 `python3 tools/check_secrets.py`
- [ ] 改动了 `main.lua`，已运行 `luajit -bl pickthought.koplugin/main.lua`
- [ ] 已在 KOReader / Kindle 真机测试（UI 改动必做；部署后需完全重启 KOReader）
- [ ] 不适用，仅文档或注释变更

测试说明:

```text

```

## 非公开微信读书 API

如果本 PR 新增或修改任何非公开微信读书 Web API，必须先在 `scripts/` 提交可独立运行、可复现的 Python 验证脚本。脚本不得打印或保存真实 API key、Cookie、Token 或账号标识。

- [ ] 不涉及非公开微信读书 API
- [ ] 已新增或更新可复现的 Python 验证脚本

脚本路径:

```text
scripts/
```

复现命令与脱敏结果:

```text

```

## 模块结构

- 项目自有 Lua 模块位于 `pickthought.koplugin/pickthought/`，以 `require("pickthought.<module>")` 加载；想法弹窗 UI 在 `pickthought/thought_popup/`
- 禁止根级 `lib/`、`ui/` 项目模块与裸 `lib.*` 命名空间（`tools/check_namespace.py` 会强制）
- `require("ui/widget/menu")` 等 KOReader 自带模块不受限

## 隐私 Checklist

- [ ] 我没有提交 KOReader settings、EPUB/缓存产物、API key、Cookie、`x-wrpa-*` 头或私人书籍内容（`tools/check_secrets.py` 会扫描）

## 发版提醒

- `_meta.lua`、`pickthought/config.lua`、`update.json` 只经 `tools/prepare_release.py` 修改
- GitHub Release 只由 `vX.Y.Z` tag 推送触发 workflow 创建，不要手动 `gh release create`
- 流程详见 [RELEASING.md](RELEASING.md)
