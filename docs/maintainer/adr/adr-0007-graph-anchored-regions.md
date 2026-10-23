# ADR-0007: 图绑定区域内存模型 + 逃逸修订（统一方向 v2）

- 日期：2026-08-13（含 08-09 统一方向 v2 演进）
- 状态：accepted（部分实现：arena 层已实施，区域机制 M1-M3 处于设计态）
- 决策者：DslsDZC

## 背景

多 Arena 模型（2026-07-28）把 arena 绑定到子图。进一步的问题是内存区域与图的关系、跨区域引用策略、栈的角色。早期方案的逃逸规则有四条，一律禁止跨区域。

## 决策

- 区域绑定图：区域是子图节点的字节域，不是词法作用域的影子；生命周期由图活性决定，不采用 LIFO。
- Arena 降级为分配器层的实现（区域是 arena slot 的语义升级）。
- 逃逸规则从四条合并为一条 outlives 顺序判定：引用者的使用区间必须落在被引用区域的有效区间内（`RegionCheck` 的 `cur_seq` < `exit_seq` 即该判定）；全局变量视为程序级虚拟区域。
- 栈只在语义层视为区域（栈上对象有 provenance；硬件栈保留，避免双栈）。
- 外部世界接口（FFI/IO）与硬件描述表同构，后演化为 HIT，见 ADR-0015。

## 后果

- 正面：go/flow 的非 LIFO 生命周期可行；跨区域引用合法，由顺序判定；验证检查是图活性。
- 负面：split/merge/share、IR 层回收点、size class 策略待实现（M1-M3）。

## 关联

- 文档：docs/maintainer/design/region-model.md、pointer-model.md；archive/2026-08-13-graph-anchored-regions-design.md
- 相关 ADR：ADR-0006（缓存语义规则 7 = 正确性标准）
