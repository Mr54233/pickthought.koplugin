# 撷思 PickThought

**书是你的,想法是社区的——撷思把后者塞进前者。**

非官方 KOReader 插件:从微信读书拉取划线与公开想法,引文对齐后注入本地 EPUB。点按虚线,弹窗看想法。

## 功能

- 划线与想法注入(underlines 全部划线 + readreviews 按 range 全部想法)
- 原地替换原书,进度保留,`.orig` 备份可一键还原
- 后台同步,断点续传,防锁屏,重启自动接管
- 大书分批(200 章/次),防风控
- SQLite 存储,原生位图想法弹窗,点按秒开；支持居中/底部显示、长内容分页或滚动、物理翻页键与可选左右点按翻页
- 阅读中一键切换默认、细实线、细虚线或隐藏划线样式
- 在线 OTA 更新

## 环境

KOReader ≥ v2026.03(需要 `ffi/archiver` + `lua-ljsqlite3`)。

## 安装

1. 解压到 `koreader/plugins/pickthought.koplugin`
2. 重启 KOReader
3. 账户扫码登录 → 选书绑定 → 同步 → 点虚线看想法

## 致谢

衍生自 [miuread-koreader](https://github.com/miumiupy98-art/miuread-koreader)(同步框架/HTTP) 与 [weread.koplugin](https://github.com/finlater/weread.koplugin)(SQLite/弹窗)。基于 [AGPL-3.0](LICENSE)。

`fonts/NotoEmoji-Regular.ttf` 用于想法弹窗的 Emoji 回退，采用 [SIL Open Font License 1.1](pickthought.koplugin/fonts/LICENSE)。
