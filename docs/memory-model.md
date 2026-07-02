# Arena 内存模型

## 概述

Core 采用基于 Arena 的统一内存管理方案，将堆内存划分为与数据流子图绑定的独立 Arena。每个 Arena 内部使用线性指针碰撞分配（bump allocation），回收直接将整个 Arena 游标重置回起始地址（格式化清空）。所有权系统静态保证区域内无活跃引用逃逸。

长期运行服务的内存占用上限由并发区域数量决定，天然无 GC 停顿。

---

## 设计动机

### 传统内存管理的痛点

| 方案 | 问题 |
|------|------|
| 手动 malloc/free | 悬挂指针、双重释放、内存泄漏 |
| 引用计数 (RC) | 循环引用、原子操作开销、Cache Miss 链式更新 |
| 跟踪式 GC (Mark-Sweep/Compact) | 停顿不可预测、内存开销不确定、不适合硬实时 |
| RAII + 所有权 (Rust) | 静态正确，但复杂数据结构需精细设计借用关系，且 Drop 顺序在运行时产生开销 |

### Arena 方案的优势

- **分配 O(1)**：仅指针碰撞，无空闲链表遍历
- **回收 O(1)**：整体重置游标，不逐元素析构
- **无碎片**：Arena 内线性分配，无释放操作，不会产生内部碎片
- **可预测**：分配只检查 Arena 剩余容量，无 GC 停顿
- **Cache 友好**：同一子图的数据集中在同一 Arena，空间局部性好

---

## 核心概念

### Arena

Arena 是一段连续虚拟内存区域，维护一个单调递增的分配游标（bump pointer）：

```
┌─────────────────────────────────────────────┐
│  Arena                                       │
│  ┌──────┬──────┬──────┬──────┬─────────────┐│
│  │ Alloc │ Alloc │ Alloc │      │  剩余空间   ││
│  │  #1   │  #2   │  #3   │      │            ││
│  └──────┴──────┴──────┴──────┴─────────────┘│
│         ↑                           ↑       │
│      游标 (ptr)                  上限 (end)   │
└─────────────────────────────────────────────┘
```

分配伪代码：

```
fn alloc(size: usize) -> *mut u8 {
    let remaining = self.end - self.ptr;
    let aligned = align_up(size, 8);
    if aligned > remaining { return OOM; }
    let addr = self.ptr;
    self.ptr += aligned;
    addr
}
```

### 子图绑定

每个数据流图节点（DFNode）可关联一个 Arena。执行器在激活节点时将其 Arena 设为当前 Arena，节点内所有分配均来自该 Arena。

```
DFGraph                    Arena Pool
┌──────────┐             ┌──────────────┐
│  node A  │────────────▶│  Arena A      │
│  node B  │────────┐    │              │
│  node C  │──┐     └───▶│  Arena B      │
│  node D  │──│─────────▶│  Arena C      │
└──────────┘  │          │  Arena D      │
              │          └──────────────┘
              │                 ↑
              │         Arena Pool —— 所有 Arena
              │         由运行时统一管理
```

### 生命周期

Arena 生命周期绑定到子图执行周期：

| 构造 | 子图开始执行时创建。容量由编译器静态推断或配置指定 |
|------|------------------------------------------------------|
| 分配 | 子图内所有分配均从绑定 Arena 的 bump pointer 分配 |
| 回收 | 子图执行完毕后，Arena 游标重置到起始地址。不调用析构函数 |
| 复用 | Arena 返回 Arena Pool，供后续同类子图重复使用 |

---

## 所有权与逃逸分析

Arena 方案的核心前提：**子图内分配的引用不会逃逸到子图之外**。编译器通过静态分析保证：

### 逃逸规则

1. **向下逃逸禁止**：Arena A 内分配的对象不能作为参数传递给生命周期比 A 长的子图
2. **向上逃逸禁止**：Arena A 内分配的对象不能作为返回值给生命周期比 A 长的调用者
3. **全局逃逸禁止**：Arena A 内分配的对象不能赋值给全局变量
4. **跨 Arena 引用禁止**：Arena A 内的指针不能指向 Arena B 内的对象

### 例外：RawRef\<T\>

以下情况允许跨 Arena 引用，但必须在 `unsafe` 块中显式声明：

- 内核级共享数据结构（如进程控制块）
- 硬件寄存器映射
- 跨 Arena 的只读共享

`unsafe` 块在此处的作用不是"关掉检查"，而是"我知道这违反规则，但我保证安全"。

### 实现方式

逃逸分析在 IR 层面以数据流分析实现：

- 每个 IR 变量标注 Arena 来源（`ArenaTag`）
- 赋值/传参时检查 ArenaTag 兼容性
- 违反规则产生编译错误，除非在 `unsafe` 块中

```
// 伪代码：ArenaTag 传播
let a = Arena::new();         // a.tag = ArenaA
let x = alloc_in(a, 32);     // x.tag = ArenaA
let y = x;                    // y.tag = ArenaA (传播)
let z = some_func(x);         // z.tag = ArenaA (返回tag传播)
store_global(g, x);           // 错误：ArenaA → Global 逃逸
unsafe { store_global(g, x) } // 允许：unsafe 豁免
```

---

## 与数据流图的集成

### 子图类型与 Arena 策略

| 子图类型 | Arena 策略 | 说明 |
|----------|-----------|------|
| DAG (函数/分支/for) | 栈式 Arena | 函数入口创建，出口回收。与调用栈深度同步 |
| 静态循环 (loop) | 固定 Arena | 循环开始前分配，结束后回收。容量根据循环不变量预计算 |
| Flow | 独立 Arena | 每次 flow 激活创建独立 Arena。并发 flow 各自独立 |
| Go | 独立 Arena | 每个 goroutine 拥有独立 Arena。退出时整体回收 |
| Yield/Recv | 消息 Arena | 跨 flow 传递的数据在接收端 Arena 中重新分配 |

### Arena 嵌套

Arena 可嵌套：子图在父图的 Arena 内创建子 Arena。子 Arena 回收后，父 Arena 不受影响。

```
Arena A (函数 main)
├── Arena B (loop 主体)
├── Arena C (flow 1)
└── Arena D (flow 2)
    └── Arena E (flow 2 内的子 loop)
```

---

## 运行时布局

### Arena 内存池

运行时维护一个 Arena Pool，包含固定数量的预分配 Arena：

```
Arena Pool
┌────┬────┬────┬────┬────┬────┬────┬────┐
│ P0 │ P1 │ P2 │ P3 │ P4 │ P5 │ P6 │ P7 │
└────┴────┴────┴────┴────┴────┴────┴────┘
  │                       ↑
  │                 分配中的 Arena
  │
  └─── 空闲 Arena
```

- 活跃 Arena 数量 = 当前并发子图数量
- 任一时刻，最多 `MAX_CONCURRENCY` 个 Arena 同时活跃
- 未使用的 Arena 留在池中，不需归还操作系统
- 必要时可向操作系统扩展 Arena 容量

### 大小预计算

编译器在 IR 生成阶段计算每个子图的最大内存需求：

1. 遍历子图内所有 `alloc` 调用
2. 静态推断大多数分配大小（结构体、数组已知长度）
3. 对动态分配（如运行时决定的缓冲区大小）标注最大容量上限
4. 若无法推断上限，使用部署配置中的默认容量

---

## 与并发模型的协作

### 无锁分配

每个 Arena 只被一个执行线程访问。Arena 内 bump pointer 可以是线程局部变量，无需原子操作。

```
// 线程安全：每线程 Arena
thread_local! {
    static CURRENT_ARENA: RefCell<Arena>;
}
```

### Go/Flow 的 Arena 隔离

```
go f()  →  新 Arena G  →  函数 f 内所有分配在 G
                                       ↓
                                    f 结束 → Arena G 整体回收
                                       ↓
                                    go 表达式的结果 → 拷贝到父 Arena
```

- `go f()` 创建独立 Arena，f 的返回值在 f 结束后拷贝到父 Arena
- `flow` 的每个分支拥有独立 Arena，分支退出时回收
- `yield` 的数据通过消息 Arena 传递，接收方在自己的 Arena 中重新分配

### 停止机制

长期运行的服务，内存占用上限为 `MAX_CONCURRENCY × MAX_ARENA_SIZE`。当 Arena Pool 耗尽空闲 Arena 时，新的 go/flow 被阻塞直到有 Arena 可用。不需要 GC。

---

## Rust 风格的对比

| | Rust (RAII + 所有权) | Core (Arena) |
|--|---------------------|--------------|
| 分配开销 | 栈分配 O(1)，堆分配需寻找空闲块 | Bump O(1) |
| 释放开销 | Drop 链递归 O(深度) | 游标重置 O(1) |
| 借用检查 | 生命周期标注复杂，NLL 推断有局限 | ArenaTag 传播，按子图边界检查 |
| 并发 | Arc/RwLock 运行时开销 | Arena 隔离，无共享 |
| 循环引用 | 需 Weak 打破 | 同 Arena 内允许循环（回收时整体释放） |
| GC | 无 GC | 无 GC（Arena 回收等价于批量释放） |
| 适用场景 | 通用系统编程 | 数据流驱动、并发密集、实时系统 |

---

## 待解决问题

### Arena 碎片化

虽然 Arena 内无碎片，但 Arena 整体大小预分配可能导致：
- 小分配占用大 Arena → 空间浪费
- 动态 Arena 大小调整策略待设计

候选方案：分档 Arena（size class）、链式 Arena（用满后追加新块）

### 逃逸分析精度

当前设计依赖编译器的跨子图逃逸分析。以下情况的精度需要验证：
- 通过函数指针/接口调用的间接逃逸
- 条件性逃逸（某些分支逃逸某些分支不逃逸）
- RawRef 与 unsafe 的交互边界

### Arena 复用策略

Arena 返回 Pool 后，重置游标但不清除内存。敏感场景可能需要清零：
- 跨安全边界的进程隔离
- 包含密钥或隐私数据的 Arena
- 由部署配置控制，非默认行为
