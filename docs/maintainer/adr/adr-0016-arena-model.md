# ADR-0016: 多 Arena 内存模型(取代全局 bump 分配器)

- 日期:2026-07-28
- 状态:accepted(已实现)
- 决策者:DslsDZC

## 背景
早期运行时用单一全局 bump 分配器(BSS + mmap 扩展)。问题:内存生命周期与子图脱节——函数/循环产生的数据只能等到程序结束统一回收,长期服务内存无界;回收时机无法与执行结构对齐。

## 决策
- **每个子图(function/loop/for/unsafe)自己的 arena**:子图入口 arena_new、出口 arena_reset(游标重置,格式化清空)
- 新 IR opcode:IR_ARENA_NEW = 32 / IR_ARENA_RESET = 33(编译期大小预计算)
- ELF 后端双路径 alloc:arena 感知(g_current_arena)+ 全局 bump 回退;mmap 堆扩展
- stdlib arena.cr 完整生命周期(init/new/reset)、动态元数据、free list、嵌套

## 后果
- 正面:子图退出即整块回收;分配 O(1) bump;无 GC
- 负面:arena 绑定子图 = 数据不能逃逸子图(跨子图引用受约束,后续由 outlives 修订放宽——ADR-0007);07-28 后遇 bump 死循环等实现 bug(已修)

## 关联
- 文档:docs/maintainer/design/region-model.md §四(arena = 区域机制的分配器面);specs/2026-07-28-arena-model-design.md
- 相关 ADR:ADR-0007(图锚定区域,arena 的语义升级)
