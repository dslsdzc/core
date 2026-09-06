# Core 渐进式学习路径

> 定位：受众 = 开发者；状态 = active

Core 是少数不能归入"第一门语言"或"第 N 门语言"二元分类的设计。它的结构使得同一个语言可以陪伴程序员从零基础走到编写操作系统内核。

学习路径自然展开——每个阶段的图结构复杂度递增，概念逐级累积，**没有换过语言，没有切换过"模式"，没有需要遗忘的概念**。

---

## 第一阶段：基础

**目标**：写出第一个程序——"输入 → 计算 → 输出"的纯计算。

**引入的概念**：
- 变量声明：`x := expr`（推断）、`x : Type = expr`（显式）、`x : ., mut`（可变）
- 基本类型：int、dex、bool、string、unit
- 函数：`fn name(args) -> ret { ... }`
- 条件分支：`if / else`（表达式，可产生值）
- 循环：`for x in arr`、`for i in 0..n`
- 数组 `[T]`、结构体 `struct`

**图模型**：DAG——无环,值按依赖顺序流动;不依赖同一份数据的部分互不干扰。

**心智模型**：顺序执行——执行的每一步严格按文本顺序，所有变量值完全可观测、可单步。

**里程碑**：能写求和、数组统计、简单查找等纯计算程序。

**应用场景**：
- 命令行计算工具：求和/平均值/单位换算（int/dex + 数组 + for）
- 文本处理小程序：字符串查找/拼接/比较（string + 函数组合）
- 数学程序：数列、阶乘、质数检测（函数 + 循环）

```core
fn sum(a: [int]) -> int {
    total : ., mut = 0;
    for x in a { total = total + x; }
    return total;
}
```

**关联**：`docs/developer/syntax.md`、`docs/maintainer/design/execution-model.md` §5.1

---

## 第二阶段：结构化控制流

**目标**：理解"持续运行"——程序不再是一次性计算，而是有状态地运行。

**引入的概念**：
- `loop { ... }` + `break` / `continue`
- `while` 条件循环
- 状态保持：可变变量跨迭代存活

**图模型**：带环的静态图——loop/for 让值流绕圈,循环的"再次执行"由图的环表达。

**心智模型**：循环 = 图中的环——每轮迭代值沿环流动一周;程序开始出现时间维度(状态跨迭代存活)。

**里程碑**：能写计数器、状态机雏形、轮询循环。

**应用场景**：
- 猜数字游戏（loop + 输入比较 + break）
- 状态机：交通灯/订单状态流转（loop + 可变状态跨迭代存活）
- 轮询循环：持续运行的守护循环雏形（loop + 退出条件）
- 简易 REPL：读取-求值-循环（read + process + loop）

```core
fn counter() -> int {
    i : ., mut = 0;
    loop {
        if i >= 5 { break; }
        i = i + 1;
    }
    return i;
}
```

**关联**：`docs/maintainer/design/execution-model.md` §三(深入:执行模型与图的实现)

---

## 第三阶段：指针与内存

**目标**：理解"字节级控制"——程序从"值的运算"进入"内存的操作"。

**引入的概念**：
- 裸指针：`*T` 类型、`&x` 取址、`*p` 解引用、`cast<T>(p)` 转换
- `unsafe` 块:图边界入口(外部地址、FFI 返回值、无法自动追踪来源的场景)
- @ 内建：`@sizeOf(T)`、`@alignOf(T)`、`@fields(T)`、`@comptime`、`@inline`
- 内存控制：`alloc_at(addr, size, align)` 声明式放置

**图模型**：每个指针自带来源(它来自哪次分配/取址)与偏移;解引用时编译器自动核对边界——不需要你标注任何生命周期。

**心智模型**：指针和 C 一样自由;安全由编译器自动验证(来源追踪 + 边界核对)。unsafe 不是"关掉验证",是"声明此处是图边界入口"——一进图内,编译器重新获得追踪权。

**里程碑**：能安全地做指针算术、类型双关、外部地址访问——不需要学 borrow checker。

**应用场景**：
- 缓冲区/内存池管理：固定大小缓冲区的分配与访问（指针 + 边界自动验证）
- 硬件寄存器访问：MMIO 读写（unsafe + 0x 外部地址，见下方示例）
- 位操作/类型双关：位模式解释（`*(dex*)&i`——字节视图切换，无需 unsafe）
- 布局查询：结构体大小/对齐/字段偏移（@sizeOf/@alignOf/@fields——序列化与协议实现的基础）

```core
fn deref(arr: [int], i: int) -> int {
    p := &arr[i];      // 来源 = arr,偏移 = i(编译器自动记录)
    return *p;         // 越界 → 编译期拦截或运行时检查
}

unsafe {
    mmio := 0x7fff0000 as *int;   // 外部地址：图边界入口
    *mmio = 42;
}
```

**关联**：`docs/maintainer/design/pointer-model.md`、`docs/maintainer/design/memory-model.md`

---

## 第四阶段：并发与通信

**目标**：理解"数据驱动"——程序是一张图，节点可以并发运行，数据在边上流动。

**引入的概念**：
- `go f(args)`：启动并发执行（独立 HDFG 子图 / fiber）
- `h := go f(...)`：返回句柄
- `await h`：等待结果
- `flow`：可激活的命名子图模板；`yield`：暂停并输出值
- 通道（chan）：跨执行流传递数据

**图模型**：动态图——go 在运行时长出新的子图,与启动它的代码并行流动。

**心智模型**：节点、边、令牌——从"一行一行执行"平滑过渡到"数据驱动"：执行顺序由数据可用性驱动，而非文本顺序。

**里程碑**：能写生产者-消费者、并发管道（扇出/扇入）。

**应用场景**：
- 生产者-消费者：chan 传递任务与结果（解耦生产与消费速率）
- 并行计算：多 worker 分块求和/统计（go + await + go var start..end 范围收集）
- 并发管道：流水线处理（flow + yield，数据流式加工）
- 并发任务池：批量独立任务并发执行（go + 结果通道聚合）

```core
flow worker(id: int) -> int {
    yield id * 2;
}

fn main() -> int {
    w := go worker(21);
    v := await w;
    return v;   // 42
}
```

**关联**：`docs/maintainer/proposals/concurrency.md`、`docs/maintainer/design/execution-model.md` §5.3

---

## 形式规约（横切能力）

> [注意] **未实现**：本节为设计预览。规约形态 2026-09 定稿为 `#check`/`#ensure` 标注(与 #pure/#terminating 标签同族,见 `docs/developer/syntax.md` 第十章与 `docs/maintainer/design/spec-design.md`;独立 `.corespec` 格式已退役,见 adr/adr-0001),但**规约语法与验证管线均未实现**——当前编译器不消费规约。实现推进见 spec-design.md 与 TODO.md。

**目标**：理解"行为契约"——程序 = 实现 + 保证。

**位置**：横切能力——任何阶段的代码都可配规约，不依赖特定能力层；推荐在掌握函数签名和类型系统后引入。

**引入的概念**：
- `#check(...)`：前置条件
- `#ensure(...)`：后置条件（可引用 `result`、`old(x)`）
- `spec fn`：检查函数（用 Core 写的纯逻辑函数）
- 函数内规约(`#check`/`#ensure` 标注,.cr 内表达——独立规约格式已退役)

**图结构**：图上的约束——规约约束挂载为图的标注（TagNode/.csr 方向，设计态），通过符号引用精确关联 HDFG 节点。

**心智模型**：函数不只"做什么"，还"保证什么"——意图成为代码的一等公民，验证器可消费。

**里程碑**：能给函数写前置/后置条件，用检查函数表达性质（有序性、排列性、不变量）。

```core
fn divide(a: int, b: int) -> int
    #check(b != 0)
    #ensure(result * b <= a)
{
    return a / b;
}
```

**关联**：`docs/maintainer/design/spec-design.md`、`docs/developer/syntax.md` 第十章、`docs/maintainer/adr/adr-0001-corespec-crasm-retired.md`(格式退役决策)、`docs/superpowers/specs/`(验证管线设计稿)

---

## 应用领域

四个能力层是语言的基础；在此之上，Core 的图模型 + 部署配置分离让**同一门语言覆盖多个领域**——每个领域是四层能力的不同组合，代码不变，部署配置不同：

| 领域 | 用到的能力层 | 图结构特征 | 部署配置 | 状态 |
|------|------------|-----------|---------|------|
| **系统编程**（内核/驱动/协议栈） | ①②③④ + unsafe/HIT | 全部结构 | 裸机/无 OS | 能力已实现 |
| **嵌入式与实时**（无 MMU/确定性） | ①③ | DAG/静态图 | 静态分配/无 GC | 能力已实现 |
| **并发服务**（服务器/网络后端） | ③④ | 动态图 | 多核/OS 线程 | 已实现（单 M 端到端） |
| **数据处理与科学计算** | ①③ | DAG | 通用 | 已实现（dex/数组） |
| **编译器与工具链** | ①②③④ | 全部 | 通用 | **自举实证**（语言写自己） |
| **安全关键系统**（航空/医疗/金融） | 全部 + 规约 | 全部 + 图上约束 | 验证 | 规约设计态 |
| **分布式系统** | ③④ + 远程节点 | 跨机图 | 集群 | 设计态（`go @("node")`） |

### 示例：系统编程

内核、驱动、网络协议栈——之前每个能力层学到的概念全部在场：DAG 对应中断处理路径，带环静态图对应设备轮询，动态图对应进程调度器，规约对应安全关键的隔离性质。

**新增概念**：
- 裸指针：`*T` 类型、`&x` 取址、`*p` 解引用、`cast<T>(p)` 转换
- `unsafe` 块:图边界入口(外部地址、FFI 返回值、无法自动追踪来源的场景)
- @ 内建：`@sizeOf(T)`、`@alignOf(T)`、`@fields(T)`、`@comptime`、`@inline`
- 内存控制：`alloc_at(addr, size, align)` 声明式放置、布局控制
- 硬件接口(HIT):MMIO/特权/中断经 unsafe + HIT extern 事件(独立汇编格式 .crasm 已废弃,见 maintainer/adr/adr-0001)

**心智模型**：字节级控制 + 图边界——指针和 C 一样自由,安全由编译器自动验证;unsafe 是"声明图边界入口",不是"关掉验证"。

```core
unsafe {
    mmio := 0x7fff0000 as *int;   // 外部地址：图边界入口
    *mmio = 42;
}
```

**关联**：`docs/maintainer/design/pointer-model.md`、`docs/maintainer/design/memory-model.md`、`docs/maintainer/adr/adr-0001-corespec-crasm-retired.md`(crasm 废弃决策)

### 示例：嵌入式与实时

无 MMU 目标、确定性延迟——图锚定区域（静态路径纯 bump 零碎片、无 GC 停顿）+ 部署配置（`allocation = "static"`）是核心卖点。

**关联**：`docs/maintainer/design/execution-model.md` §3（部署配置）、`docs/maintainer/design/memory-model.md`

---

## 阶段与图结构对照

| 能力层 | 语法特性 | 图结构 | 心智模型 |
|--------|---------|--------|---------|
| ① 基础 | 变量、函数、分支、for | DAG | 顺序执行 |
| ② 结构化控制流 | loop、while | 带反馈环的静态图 | 循环调度 |
| ③ 指针与内存 | *T、&、unsafe、@内建、alloc_at | 来源追踪 + 自动边界验证 | 字节级控制 |
| ④ 并发与通信 | go、await、flow、yield、chan | 动态图 | 数据驱动 |
| 横切：形式规约 | #check/#ensure/spec fn | 图上约束 | 行为契约 |

整个过程中，概念只增不减——每个能力层学到的都留在下一个应用领域中继续使用，最终形成一个从"第一个程序"到"编译器与内核"的连续路径：**同一门语言，从零基础走到任何领域**。
