# WeRead PR #117 划线与想法同步实现分析

## 范围与基准

- 上游 PR：[finlater/weread.koplugin#117](https://github.com/finlater/weread.koplugin/pull/117)，标题为 `feat: sync local-book underlines and thoughts`。
- 分析对象：该 PR 合并前的 head `3744c04f96bc695ed2fc69684b4fae33c4a10aed`。
- 对照对象：`Mr54233/pickthought.koplugin` 的 `main`，分析时为 `a4eed38`。
- 本文只讨论“为本地书同步微信读书划线与想法”的实现；书架、下载、阅读统计等上游功能不在范围内。

本分支中的上游代码是 `3744c04` 的源码快照，用于审阅，不是可直接合并到撷思的功能分支，也不保留上游原始 Git 历史。

## 结论

上游 #117 不是另一种 EPUB 注入实现，而是**不修改书文件的 XPointer 外部标注叠加方案**。它和撷思都能在本地书中展示微信读书划线与想法，但数据落点、定位算法、渲染时机和失败边界均不同。

撷思当前方案仍更符合“将划线和想法注入 EPUB 副本”的产品目标。上游方案不能直接替代撷思的注入管线；它的价值在于提供了一个可选的、无文件改写的阅读器叠加模式思路。

上游 v1.2.0 发布说明提到该功能“参考了 pickthought.koplugin 的实现”，但 #117 的 PR 正文、提交信息、评论和源码中没有指向撷思某个具体 PR 的链接，也未发现 `pickthought` 或 `Mr54233` 的代码引用。因此，这更像是参考功能方向与交互目标，而不是直接移植某个撷思 PR。

## 实现对比

| 维度 | 撷思当前方案 | 上游 #117 |
| --- | --- | --- |
| 标注载体 | 重写 EPUB XHTML，插入 `span` 和想法链接 | SQLite 中保存 XPointer 记录，原书不变 |
| 划线渲染 | EPUB 重开后由 KOReader 正常渲染 HTML/CSS | `ReaderView:registerViewModule()` 在阅读时计算屏幕矩形并绘制 |
| 想法点击 | 点击注入的 `pickthought-*` 链接，再按 `book_id/chapter_uid/range` 查询想法库 | 点击当前页叠加矩形，直接使用记录中保存的想法项 |
| 章节定位 | 先映射微信章节到本地 EPUB spine，再在对应 XHTML 内定位 | 不做章节到 spine 映射，直接对整个文档搜索引文 |
| 精确落点 | 引文定位优先；同版文本可按微信 UTF-16 range 兜底 | 仅保存全文搜索命中的 XPointer；找不到全文则尝试 90 字节前缀 |
| 重复文本处理 | 在已确定的章节文件内，以期望 range 距离选择候选 | 全文搜索最多 16 个候选，按全局游标选择下一个候选 |
| 同步恢复 | 章节缓存、地图缓存、增量注入与后台任务机制 | 每章及每个想法请求批次均写入 SQLite checkpoint |
| 文件移动/替换 | 注入文件与 `.orig` 备份在原路径协作；可恢复原书 | 数据库按文档路径哈希命名；移动或替换文件后需重新匹配 |
| 支持范围 | EPUB 注入链路 | 仅支持有 XPointer 和屏幕位置 API 的可重排 CREngine 文档；PDF/DjVu 不支持 |

## 上游 #117 的链路

### 1. 绑定与同步数据

用户先为当前文件搜索并选择微信读书书目。绑定信息、同步结果和断点数据均存入以文档路径派生的 SQLite 文件：

`weread/lib/external_annotations_db.lua`

该数据库保存：

- 本地文件与微信读书书目的绑定；
- 已完成章节的划线和想法；
- 未完成章节及已拉到的想法批次；
- 最终 XPointer 标注记录和匹配统计。

同步按章节拉取划线，再按 range 分批拉取想法。每个网络批次完成后立即写 checkpoint，因此取消或异常后可从下一未完成请求继续。

### 2. 从引文定位到 XPointer

`weread/lib/external_annotations.lua` 的 `locate()` 将每条微信读书划线转为当前本地文档的一对 XPointer：

1. 从 `markText`、`bookmarkText`、`rangeText`、`abstract` 等字段取引文；缺失时取同 range 想法的摘要。
2. 对当前 KOReader 文档调用 `findAllText()` 做全文搜索，最多保留 16 个结果。
3. 找不到完整引文时，仅搜索前 90 UTF-8 字节。
4. 将候选起点转换为文档位置，选择全局游标之后最靠前的一个，得到 `pos0`、`pos1`。
5. 把 XPointer、引文、微信 range 和想法内容写入外部数据库。

这个方案不解析 EPUB，也不修改 HTML。它的准确性依赖于当前本地书的全文与微信读书引文足够一致，并假设按微信 range 排序的划线在本地文档中也大致顺序一致。

### 3. 阅读时叠加渲染

`weread/ui/xpointer_overlay.lua` 在 `ReaderView` 原有绘制阶段：

1. 过滤与当前可见文档位置相交的 XPointer；
2. 调用 `getScreenBoxesFromPositions()` 得到各段屏幕矩形；
3. 用 KOReader 的 `drawHighlightRect(..., "underscore")` 画下划线；
4. 缓存页模式下的矩形，字体、边距、横竖屏变化时通过 `onUpdatePos()` 和 `onDocumentRerendered()` 清缓存；
5. 点击命中矩形后打开原生想法弹窗。

它明确避免向 KOReader 的 annotation 数组和 `.sdr` 写入记录，也不写回 EPUB。

## 撷思当前链路

### 1. 章节映射

`pickthought/chapter_map.lua` 先把微信章节映射到 EPUB spine 文件：

- 从每章多条划线抽取至多八条引文；
- 流式扫描 EPUB spine，避免大书一次性持有全部正文；
- 用多引文命中评分确认目标文件，并排除目录页；
- 支持一个微信章节映射到多个本地正文文件；
- 证据不足时可由章节标题兜底，但进入 `quote_only` 模式以避免数字范围错投。

因此，撷思不会将同一句热门文本在全书任意位置的第一次命中直接当成目标，而是先建立章节边界。

### 2. XHTML 内精确定位与注入

`pickthought/annotations.lua` 对每个已映射 XHTML：

- 解析文本单元，建立 HTML 原始位置、可见文本位置和 UTF-16 位置索引；
- 优先用引文在该 XHTML 内定位，并根据微信 range 的期望位置选最近候选；
- 引文不可用且映射证据足够强时，使用微信的 UTF-16 range 作为数值兜底；
- 处理 emoji 等非 BMP 字符的 UTF-16 宽度；
- 合并重叠划线，并将被合并划线的想法归并到保留锚点；
- 写入下划线 `span`；有想法的标记包裹为 `pickthought-*` 链接。

`pickthought/epub_inject.lua` 将修改后的条目写入新的 EPUB，加入标识文件后再原子替换目标。`pickthought/sync.lua` 在首次同步时将原书保留为 `<path>.orig`，后续批次在注入副本上增量追加，同时始终从干净原书读取文本来维持定位稳定性。

### 3. 想法数据与点击

`pickthought/thought_db.lua` 和 `pickthought/thoughts.lua` 按微信书籍、章节和 range 保存想法。阅读器点击注入链接后，`main.lua` 解析链接并读取对应想法组，再显示撷思弹窗。

## 关键差异及影响

### 定位正确性

上游的全书搜索路径较短，但只用“引文 + 全局游标”消解重复文本。以下情况更容易错位或漏标：

- 书中重复出现短句、题记、诗句或常见段落；
- 本地版与微信版存在前言、目录、增删章节或文字修订；
- 完整引文搜索失败后退化为 90 字节前缀；
- 单个微信章节在本地被拆分或合并。

撷思增加章节映射、多引文投票、目录页排除、局部候选距离选择和 UTF-16 range 兜底，代价是实现更重、需要读取并重打包 EPUB。对“尽量将标记落到正确位置”的目标，这些约束是有意义的，不应为了减少代码量删除。

### 文件安全与用户体验

上游方案的优势是不会改动原书、也不用重打包；同步完成即可显示，清除数据只删除侧车数据库。它适合将“无侵入”放在首位的场景。

撷思采用 `.orig` 备份和原子替换，承担了重写 EPUB 的成本，但换来两个结果：划线是书文件的一部分，且依然能沿用 KOReader 的正常链接处理和阅读渲染路径。当前实现已对重写失败、原书回滚、增量追加和大书内存压力做了专门处理。

### 渲染性能与兼容性

上游每次绘制需将可见记录转为屏幕矩形，并通过页缓存降低重复开销。其文档将低内存设备、快速翻页和滚动模式性能列为后续验证门槛，说明该实现仍是实验性原型。

撷思将定位与标记生成主要放在同步阶段，阅读阶段没有额外的 XPointer 到屏幕矩形投影成本。但其同步阶段需要重写 ZIP/EPUB，且只能用于可注入的 EPUB。

## 可借鉴与不应直接移植的部分

可以借鉴：

- 每个想法请求批次提交 checkpoint 的恢复粒度；
- 用户明确可见的“取消后可恢复”状态；
- 外部标注模式作为未来的可选、无文件改写能力；
- 布局变化时使位置缓存失效的完整生命周期处理。

不应直接移植：

- 用全书 `findAllText()` 取代撷思的章节映射和 XHTML 局部定位；
- 以路径哈希作为唯一身份而没有文件指纹或迁移策略；
- 在未完成低内存、快速翻页和滚动模式真机验证前，将 XPointer overlay 作为默认实现；
- 将外部标注与 EPUB 注入的想法数据模型混用，而不先定义迁移和清理语义。

## 建议

1. 保持 EPUB 注入作为撷思的默认和主实现，不以 #117 替换现有同步管线。
2. 若要提供“原书零修改”模式，应以独立功能立项，而不是向现有 `Sync.run()` 直接塞入条件分支。
3. 该模式应复用现有绑定、微信接口和想法分组模型，但另建稳定的侧车记录格式，并使用文件内容指纹而非仅路径识别书籍。
4. 在实现前定义验收：重复引文、章节拆合、字体和横竖屏重排、快速翻页、滚动模式、文件移动、清除数据和恢复中断同步。
5. 保留注入模式，因为其章节边界与 UTF-16 定位约束仍是提高标注正确性的核心能力。

## 相关代码

上游 #117：

- `weread/lib/external_annotations.lua`
- `weread/lib/external_annotations_db.lua`
- `weread/ui/xpointer_overlay.lua`
- `weread/ui/xpointer_overlay_controller.lua`
- `docs/xpointer-overlay-prototype.md`

撷思对照基准 `a4eed38`：

- `pickthought.koplugin/pickthought/sync.lua`
- `pickthought.koplugin/pickthought/chapter_map.lua`
- `pickthought.koplugin/pickthought/annotations.lua`
- `pickthought.koplugin/pickthought/epub_inject.lua`
- `pickthought.koplugin/pickthought/thought_db.lua`
- `pickthought.koplugin/pickthought/thoughts.lua`
- `pickthought.koplugin/main.lua`
