# 撷思 PickThought 发布流程

## 日常开发

- PR 和推送到 `main` 会自动运行 CI。
- CI 包含 Lua 测试、全量 LuaJIT 编译、Python 工具测试、补丁检查和插件包校验。
- CI 会上传一个保留 7 天的测试包 Artifact，但不会创建 Release。
- Issue/PR 测试包仍然使用对应评论附件，不创建正式 Release。

## 准备发版

在干净的 `main` 工作区执行，下面以 `0.3.1` 为例：

```powershell
python tools/prepare_release.py `
  --version 0.3.1 `
  --previous-tag v0.3.0 `
  --repository Mr54233/pickthought.koplugin `
  --package-output .build/pickthought.koplugin.zip
```

脚本会更新 `_meta.lua`、`config.lua` 和 `update.json`，并使用确定性打包计算正式包的大小与 SHA-256。脚本不会自动提交或推送。

检查结果后提交并推送主线：

```powershell
git diff --check
git add pickthought.koplugin/_meta.lua pickthought.koplugin/pickthought/config.lua update.json
git commit -m "chore(release): 准备 v0.3.1"
git push origin main
```

等待 `CI` 通过后，在刚刚通过检查的主线提交上创建同版本 tag：

```powershell
git tag v0.3.1
git push origin v0.3.1
```

## 正式发布

推送 `vX.Y.Z` tag 后，Release workflow 会：

1. 调用同一套质量检查。
2. 确认 tag 指向 `origin/main` 当前提交。
3. 下载质量检查生成的包并重新校验。
4. 校验包内版本、`update.json` 版本、大小和 SHA-256 完全一致。
5. 生成中文更新摘要、Issue/PR 关联和 Contributors。
6. 创建 GitHub Release，并附带 ZIP 包和 SHA-256 文件。

Release workflow 不会切换到 `main`，也不会自动修改、提交或推送版本文件和 `update.json`。因此版本提交、tag 和正式包之间的关系是可审计的。

`skip_tests` 只允许在 Actions runner 不可用时通过 `workflow_dispatch` 使用，测试失败不能用它绕过。正常发版不要使用这个选项。

## Kindle 本地 staging

GitHub runner 不直接连接 Kindle。使用本地 PowerShell 脚本部署测试包：

```powershell
powershell -ExecutionPolicy Bypass -File tools/deploy-kindle.ps1 `
  -Target root@192.168.31.176 `
  -Port 2222 `
  -RemotePluginPath /mnt/us/koreader/plugins/pickthought.koplugin `
  -PackagePath .build/pickthought.koplugin.zip
```

脚本会先上传到远端唯一暂存目录，校验入口文件后再替换当前插件，并保留旧版本备份。部署完成后必须完全重启 KOReader。

回滚时显式指定备份目录：

```powershell
powershell -ExecutionPolicy Bypass -File tools/deploy-kindle.ps1 `
  -Target root@192.168.31.176 `
  -Port 2222 `
  -RemotePluginPath /mnt/us/koreader/plugins/pickthought.koplugin `
  -Rollback `
  -BackupPath /mnt/us/koreader/plugins/pickthought.koplugin.__backup-20260815-120000
```
