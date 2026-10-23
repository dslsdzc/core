# ADR-0016: 多 Arena 内存模型（取代全局 bump 分配器）

- 日期：2026-07-28
- 状态：accepted（已实现）
- 决策者：DslsDZC

## 背景

早期运行时使用单一全局 `bump` 分配器（BSS + mmap 扩展）。问题是内存生命周期与子图不一致：函数和循环产生的数据只能等到程序结束统一回收，长期运行时内存没有上限，回收时机也无法与执行结构对齐。

## 决策

- 每个子图（function/loop/for/unsafe）有自己的 arena：子图入口调用 `arena_new`，出口调用 `arena_reset`（重置游标，整体清空）。
- 新增 IR opcode：`IR_ARENA_NEW` = 32，`IR_ARENA_RESET` = 33（编译期预先计算大小）。
- ELF 后端有两条 `alloc` 路径：arena 感知路径（`g_current_arena`）和全局 `bump` 回退；支持 mmap 堆扩展。
- stdlib `arena.cr` 提供完整生命周期（init/new/reset）、动态元数据、free list 和嵌套。

## 后果

- 正面：子图退出时整块回收；分配是 O(1) `bump`；不需要 GC。
- 负面：arena 绑定子图意味着数据不能逃逸子图（跨子图引用受约束，后续由 `outlives` 修订放宽，见 ADR-0007）；07-28 后出现 `bump` 死循环等实现缺陷（已修）。

## 关联

- 文档：docs/maintainer/design/region-model.md 第四节（arena = 区域机制的分配器层）；specs/2026-07-28-arena-model-design.md
- 相关 ADR：ADR-0007（图绑定区域，arena 的语义升级）
