# CLAUDE.md

撷思(PickThought)开发指南。供 Claude Code / 开发者参考,记录代码之外的隐性知识与约定。
全局行为准则见 `~/.claude/CLAUDE.md`,本文件只补充项目特定内容。

## 项目定位

非官方 KOReader 插件:从微信读书拉取一本书的热门划线与公开想法,引文对齐后注入到本地已有的 EPUB。**不下载书、不上传数据、不丢原书(.orig 备份)**。会员书可拉(付费墙锁正文不锁社区数据)。

核心数据流:`拉取(web端点) → 断点缓存 → 章节映射(引文对齐) → 流式注入 → 原地替换(.orig备份) → SQLite存储 → 点击锚点TextViewer弹窗`

## 关键约束

- **KOReader ≥ v2026.03**(硬性):依赖内建 `ffi/archiver`(libarchive FFI,EPUB 解包/重打包)与 `lua-ljsqlite3`(想法存储)。更早版本直接不可用,不做 fallback。
- **AGPL-3.0**:移植了 weread.koplugin 的 SQLite 模块,按协议必须同协议开源。
- 书必须是用户本地 EPUB;微信 range 对不上本地正文,必须走引文对齐,不能照搬数字偏移。

## 开发基建

桌面测试无需 KOReader 环境,用 LuaJIT + stub:
```bash
luajit tests/run.lua   # 76 例,全绿才能提交
```
- `tests/stubs.lua`:mock 掉 logger/json/lfs,并提供 `archiver_mock`(惰性索引,与真实 ffi/archiver 同语义)和 `lua-ljsqlite3` 内存 mock。
- 新增模块要在 `tests/run.lua` 的 files 列表注册测试文件。
- main.lua 不被测试覆盖(依赖 KOReader 运行时),改动后用 `luajit -bl main.lua` 单独做语法检查。

## 提交规范

- 提交标题必须带规范前缀,格式为 `<type>(<scope>): 中文说明`;按改动性质使用 `feat`、`fix`、`perf`、`refactor`、`test`、`docs`、`ci` 或 `chore`。
- 前缀和 scope 可以保留 Conventional Commits 的英文写法,但说明正文和提交正文必须使用中文,不允许直接提交全英文标题或正文。
- 不要使用没有前缀的裸标题,否则 `tools/release_notes.py` 无法分类,发版摘要会漏掉该提交。
- 提交前检查 `git diff`、测试结果和 `git log`,不要改写已推送的提交历史;需要修正时追加规范提交。

## 真机调试(Kindle)

- SSH:`ssh -p 2222 root@<kindle-ip>`(空密码)。设备锁屏会断网,亮屏才连得上。
- 日志:`/mnt/us/koreader/crash.log`(grep `撷思` 看插件日志)。
- 部署:`tar -czf - pickthought.koplugin | ssh ... "cd /mnt/us/koreader/plugins && rm -rf pickthought.koplugin && tar -xzf -"`
- **部署后必须提醒用户完全退出并重启 KOReader**(不重启新代码不生效)。
- OOM 取证:`ssh ... "dmesg | grep -i oom"`(看内核是否击毙 reader.lua 子进程)。
- 现场探针:写 .lua 脚本 scp 到 /tmp,`cd /mnt/us/koreader && ./luajit /tmp/probe.lua` 跑(注意 package.path 要接上 plugins 和 frontend)。

## 命名与隔离约定

这些是注入到书里或落到磁盘的**持久标识**,改了会让已注入的书/已存的数据失效,慎重:
- 锚点前缀 `pickthought-`(href:`pickthought-{hex(book)}.{hex(chap)}.{hex(range)}`)
- CSS 类名 `pickthought-*`(mark/link/star/inline-mark/has-thought)
- HTML 属性 `data-pickthought-range`、注入标记 `pickthought.json`
- 数据目录 `<koreader-data>/pickthought/`、设置 `<settings>/pickthought.lua`、SQLite `<book_dir>/thoughts.db`
- 日志标签 `[撷思]`
- 与觅阅(miuread-)、微读(wrthought-)前缀不同,三插件可同装共存。

## 章节映射与 ALGO_VERSION

`chapter_map.lua` 的 `ALGO_VERSION`(当前 6):**任何影响匹配结果的改动(引文窗口、投票规则、归一化、目录页判定)都必须 +1**。映射缓存把 `源书大小@ALGO_VERSION` 写进指纹,算法一改旧缓存整体作废。原因:旧算法缓存下来的"匹配失败"会永久生效,改进永远轮不到那些章节(真机翻车过)。

匹配核心思路:按划线热度原序取引文前缀(90 字节),在本地正文里投票;得分 ≥ min(2, 引文数) 的文件为注入目标。单引文命中多文件=真歧义不定案;多引文各中一半=拆分章(微信一章=本地多章)正常信号,多目标注入。章号体系不一致时 `title_key` 剥掉"第X章"编号前缀用章名兜底。

## 踩过的坑(务必避免重蹈)

1. **ffi/archiver Reader:seek 只认 iterate 过的条目**——提取前必须先 iterate 到目标。archiver_mock 在 open 时预建索引曾掩盖此 bug,真机必炸。mock 已改为惰性索引(同真实语义)。
2. **serializable_copy 永久 seen 标记会丢弃共享子表**——review_map 与 review_groups 共享同一张 texts 表,第二次出现整个被丢,断点缓存写坏。用路径级防环(递归返回时 `seen[value]=nil`)。
3. **注入不能把全部渲染结果攥内存**——旧实现先算好所有目标文件再写包,大书(剑来 ALGO6 后目标文件翻倍)OOM 被内核击毙。改流式:写包循环走到哪文件就地表注入+写出+释放,内存峰值从"全部目标"降到"单文件"。
4. **看门狗墙钟 idle 要豁免设备挂起**——poll 间隔远超调度周期说明设备睡过觉,挂起期间父子进程都被冻结,墙钟 idle 对子进程不公平。poll 间隔>30s 即重置活动基线,否则唤醒首轮误杀健康子进程。
5. **terminateSubProcess 对 attach 的非亲子进程是 no-op**——KOReader 重启后接管旧子进程属此场景。杀完必须 `/proc` 复核,仍活着对进程组 SIGKILL;杀不死不许谎报"已取消"。
6. **文件选择器 onConfirm 连关两窗(确认框+全屏选择器),各排一次重绘**——同步弹新窗要 `UIManager:nextTick` 连推两拍,等重绘落地。单拍会被第二波重绘顶掉(进度框/操作面板一闪就没)。
7. **划线引文按热度原序取,不按长度排**——微信对长引文做中段省略,整条拿去匹配必失配(真机:5 条 90 字节引文 4 条失配)。按长度优先会把能命中的短名句挤出。引文截前 90 字节前缀(省略点几乎不在开头)。
8. **网关 `/book/chapterinfo` 历史 403**——该 api_name 零消费者,随后 Bearer key 整体过期全端点 403。全面切 web 端点(`/web/book/chapterInfos`、`/web/book/bestbookmarks`、`/web/review/list`)+ `renew_session` 自动续期。
9. **离线重注不要写 state.json**——重注不碰网络,pending 恒 0,写进去会抹掉真实批次状态,"继续拉取后续章节"菜单被误杀。
10. **报告"未注入"要按唯一划线统计**——拆分章一章对多文件,同一条划线在没对齐的文件各计一次 unlocated 会虚高数倍(三项相加超总数)。跨目标文件聚合,落锚或被重叠合并即算有着落。

## 改动检查清单

- 改了匹配逻辑 → `ALGO_VERSION` +1,跑 `test_chapter_map`
- 改了锚点/类名/标记格式 → 已注入的书失效(需用户重同步),评估影响再动
- 改了 thoughts 数据形状 → 桌面 sqlite mock 测试 + 真机迁移验证
- 同步流程改动 → 验证断点续传/熔断/看门狗/挂起豁免不破
- 注入/打包改动 → 大书(剑来级)真机验证不 OOM
- 部署到 Kindle → 提醒用户重启 KOReader
