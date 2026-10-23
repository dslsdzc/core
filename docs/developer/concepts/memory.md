# 概念：内存自动管理，无 GC，无标注

> 定位：受众 = 开发者；状态 = active（arena 已实现；区域机制设计态见注）。

## 内存安全：不需要 borrow checker

Core 的内存管理与 Rust 不同。Rust 使用类型层的借用规则，需要学习和标注；Core 由编译器在图上自动验证指针安全。指针的写法与 C 一样自由，越界、失效和生命周期由编译器负责。

## 回收机制：子图区域

内存按子图区域管理：

- 每个函数和循环有独立的内存区域
- 区域内分配使用指针碰撞，复杂度为 O(1)
- 子图结束时，整个区域重置回收，复杂度为 O(1)，没有 GC 停顿

```core
fn process_batch(items: [int]) -> int:
    // 本函数内的临时数据都位于函数区域
    // 函数返回时整块回收，无需 free
    total := 0
    for x in items:
        total = total + x
    return total
```

`go` 启动的并发子图各有独立区域，退出时整块回收。

## 长期服务的内存上限

内存上限等于并发子图数乘以区域容量，可以预测，没有 GC 停顿。区域复用和清零策略（用于敏感数据）由部署配置控制，默认不启用。

## 现状注记

子图 arena 已实现。区域机制的扩展形态（split、merge、size class 等）为设计态，按 TODO 推进。当前以源码行为为准。

## 延伸

- 实现与理论：`../../maintainer/design/region-model.md`、`../../academic/cache-semantics.md`（学术，可选）
