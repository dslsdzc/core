# ADR-0007: 图锚定区域内存模型 + 逃逸修订(统一方向 v2)

- 日期:2026-08-13(含 08-09 统一方向 v2 演进)
- 状态:accepted(部分实现——arena 层已落地,区域机制 M1-M3 设计态)
- 决策者:DslsDZC

## 背景
多 Arena 模型(2026-07-28)把 arena 绑定子图;进一步问题是内存区域与图的关系、跨区域引用策略、栈的角色。早期方案逃逸规则四条一刀切禁止跨区域。

## 决策
- **区域锚定图**:区域 = 子图节点的字节域,非词法作用域影子;生命周期 = 图活性(非 LIFO)
- **Arena 降级为分配器面实现**(区域 = arena slot 语义升级)
- **逃逸四条坍缩为一条 outlives 顺序判定**:引用者使用区间 ⊆ 被引用区域存活区间(RegionCheck cur_seq < exit_seq 即该判定);全局 = 程序级虚拟区域
- **栈 = 区域仅语义层**(栈上对象有 provenance;硬件栈保留,防双栈)
- 外部世界接口(FFI/IO)与硬件描述表同构(后演化为 HIT,见 ADR-0015)

## 后果
- 正面:go/flow 非 LIFO 生命周期可行;跨区域引用合法化(顺序判定);验证判据 = 图活性
- 负面:split/merge/share、IR 层回收点、size class 策略待实现(M1-M3)

## 关联
- 文档:docs/maintainer/design/region-model.md、pointer-model.md;specs/2026-08-13-graph-anchored-regions-design.md
- 相关 ADR:ADR-0006(缓存语义条款 7 = 正确性标准)
