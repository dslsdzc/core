# 概念:内存——自动、无 GC、无标注

> 定位:受众 = 开发者;状态 = active(arena 已实现;区域机制设计态见注)。

## 不用学 borrow checker

Core 的内存管理与 Rust 不同路:Rust 用类型层的借用规则(需要你学与标注),Core 由编译器在图上自动验证指针安全。你写指针和 C 一样自由,编译器负责:越界、悬垂、生命周期。

## 内存怎么回收:子图区域

内存按**子图区域**管理:

- 每个函数/循环有独立内存区域
- 区域内分配 = 指针碰撞,O(1)
- 子图结束 → 区域整体重置回收,O(1),无 GC 停顿

```core
fn process_batch(items: [int]) -> int {
    // 本函数内的临时数据都活在函数区域
    // 函数返回 → 整块回收,无需 free
    total := 0;
    for x in items { total = total + x; }
    return total;
}
```

`go` 启动的并发子图各有独立区域,退出整块回收。

## 长期服务的内存上限

内存上限 = 并发子图数 × 区域容量——可预测,无 GC 停顿。区域复用/清零策略(敏感数据)为部署配置控制(非默认)。

## 现状注记

子图 arena 已实现;区域机制的扩展形态(split/merge/size class 等)为设计态,按 TODO 推进——当前以源码行为为准。

## 延伸

- 实现与理论:`../../maintainer/design/region-model.md`、`../../academic/cache-semantics.md`(学术,可选)
