# 撷思 PickThought

**书是你的,想法是社区的——撷思把后者塞进前者。**

非官方 KOReader 插件:从微信读书拉取划线与公开想法,引文对齐后注入本地 EPUB。点按虚线,弹窗看想法,还能看想法下面的评论。

## 功能

### 划线与想法

- 全量注入:underlines 全部划线 + readreviews 按 range 全部想法,引文对齐到本地正文
- 原地替换原书,阅读进度保留,`.orig` 备份可一键还原
- 阅读中一键切换划线样式:默认 / 细实线 / 细虚线 / 隐藏
- 后台同步,断点续传,防锁屏,重启自动接管;大书分批(200 章/次),防风控
- 绑定过的书可离线「重新注入」;单本或全部一键重置

### 想法弹窗

- SQLite + 原生位图渲染,点按秒开;居中 / 底部两种位置
- 长内容自动分页(物理翻页键 / 点按翻页)或滚动,支持跨页不裁切
- 高度、宽度、字号(跟随正文或固定)、字体对比度均可调,Emoji 有回退字体
- 三分区点按(可选):左右区域翻页,中间区域直接打开当前想法的评论

### 想法评论

- 长按想法「查看评论」:作者、点赞、正文一览;无评论数据的旧想法自动置灰
- 评论数懒加载:想法列表停稳后自动批量拉取评论数,以 ❝ 标注;SQLite 缓存时长可调,翻页不重复请求
- 可关闭评论数获取提示气泡,拉取不打扰阅读

## 环境

KOReader ≥ v2026.03(需要 `ffi/archiver` + `lua-ljsqlite3`)。

## 安装

从 [Releases](https://github.com/Mr54233/pickthought.koplugin/releases/latest) 下载 `pickthought.koplugin.zip`:

1. 解压到 `koreader/plugins/pickthought.koplugin`
2. 完全重启 KOReader,在「工具」菜单找到「撷思」
3. 账户扫码登录 → 选书绑定微信读书 → 同步 → 点虚线看想法

## 更新日志

见 [Releases](https://github.com/Mr54233/pickthought.koplugin/releases)。

## 贡献

欢迎 Issue 与 PR:提交规范、模块命名空间与本地检查清单见 [CONTRIBUTING.md](CONTRIBUTING.md),发布流程见 [RELEASING.md](RELEASING.md)。

## 致谢

衍生自 [miuread-koreader](https://github.com/miumiupy98-art/miuread-koreader)(同步框架/HTTP) 与 [weread.koplugin](https://github.com/finlater/weread.koplugin)(SQLite/弹窗)。基于 [AGPL-3.0](LICENSE)。

`fonts/NotoEmoji-Regular.ttf` 用于想法弹窗的 Emoji 回退,采用 [SIL Open Font License 1.1](pickthought.koplugin/fonts/LICENSE)。
