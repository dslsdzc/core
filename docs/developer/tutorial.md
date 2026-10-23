# Core 渐进式学习路径

Core 的设计覆盖从零基础到编写操作系统内核的学习过程。学习路径按阶段展开，每个阶段的图结构复杂度递增，概念逐级累积。整个过程不需要换语言，不需要切换模式，也没有需要先学后忘的概念。

## 第一阶段：基础

目标：写出第一个程序，完成从输入到计算再到输出的纯计算。

引入的概念：

- 变量声明：`x := expr` 是推断写法，`x : Type = expr` 是显式写法，`x : ., mut` 是可变写法。
- 基本类型：`int`、`dex`、`bool`、`string`、`unit`。
- 函数：`fn name(args) -> ret { ... }`。
- 条件分支：`if` 和 `else` 是表达式，可以产生值。
- 循环：`for x in arr`、`for i in 0..n`。
- 数组 `[T]` 和结构体 `struct`。

图模型：DAG，无环，值按依赖顺序流动。不依赖同一份数据的部分互不干扰。

理解方式：顺序执行。每一步按文本顺序执行，所有变量值都可以观察和单步检查。

阶段目标：能写求和、数组统计和简单查找等纯计算程序。

应用场景：

- 命令行计算工具：求和、平均值、单位换算，使用 `int`、`dex`、数组和 `for`。
- 文本处理小程序：字符串查找、拼接和比较，使用 `string` 和函数组合。
- 数学程序：数列、阶乘和质数检测，使用函数和循环。

```core
fn sum(a: [int]) -> int:
    total : ., mut = 0
    for x in a:
        total = total + x
    return total
```

关联：`docs/developer/syntax.md`、`docs/maintainer/design/execution-model.md` 第 1 节。

## 第二阶段：结构化控制流

目标：理解持续运行。程序不再只做一次性计算，而是带状态运行。

引入的概念：

- `loop { ... }` 加 `break` 和 `continue`。
- `while` 条件循环。
- 状态保持：可变变量跨迭代存在。

图模型：带环的静态图。`loop` 和 `for` 让值沿环流动，循环的再次执行由图的环表达。

理解方式：循环就是图中的环，每轮迭代值沿环流动一周。程序开始出现执行次数，状态可以跨迭代存在。

阶段目标：能写计数器、状态机雏形和轮询循环。

应用场景：

- 猜数字游戏：使用 `loop`、输入比较和 `break`。
- 状态机：交通灯、订单状态流转，使用 `loop` 和跨迭代存在的可变状态。
- 轮询循环：持续运行的保护循环雏形，使用 `loop` 和退出条件。
- 简易 REPL：读取、求值和循环，使用 read、process 和 `loop`。

```core
fn counter() -> int:
    i : ., mut = 0
    loop:
        if i >= 5:
            break
        i = i + 1
    return i
```

关联：`docs/maintainer/design/execution-model.md` 第 3 节。

## 第三阶段：指针与内存

目标：理解字节级控制。程序从值的运算扩展到内存操作。

引入的概念：

- 原始指针：`*T` 类型、`&x` 取址、`*p` 解引用、`cast<T>(p)` 转换。
- `unsafe` 块：图边界输入，用于外部地址、FFI 返回值和无法自动追踪来源的场景。
- `@` 内建：`@sizeOf(T)`、`@alignOf(T)`、`@fields(T)`、`@comptime`、`@inline`。
- 内存控制：`alloc_at(addr, size, align)` 声明式放置。

图模型：每个指针都带有来源和偏移，来源是它来自哪次分配或取址。解引用时编译器自动核对边界，不需要标注生命周期。

理解方式：指针和 C 一样自由，安全由编译器自动验证，包括来源追踪和边界核对。`unsafe` 不是关闭验证，而是声明此处是图边界输入。进入图内部后，编译器重新获得追踪能力。

阶段目标：能安全地进行指针算术、类型双关和外部地址访问，不需要学习借用检查器。

应用场景：

- 缓冲区与内存池管理：固定大小缓冲区的分配和访问，使用指针和自动边界验证。
- 硬件寄存器访问：MMIO 读写，使用 `unsafe` 和 `0x` 外部地址。
- 位操作与类型双关：按位模式解释，例如 `*(dex*)&i`，切换字节视图，不需要 `unsafe`。
- 布局查询：结构体大小、对齐和字段偏移，使用 `@sizeOf`、`@alignOf` 和 `@fields`，是序列化和协议实现的基础。

```core
fn deref(arr: [int], i: int) -> int:
    p := &arr[i]      // 来源 = arr，偏移 = i，编译器自动记录
    return *p         // 越界时在编译期拦截，或在运行时检查

unsafe:
    mmio := 0x7fff0000 as *int   // 外部地址：图边界输入
    *mmio = 42
```

关联：`docs/maintainer/design/pointer-model.md`、`docs/maintainer/design/memory-model.md`。

## 第四阶段：并发与通信

目标：理解数据驱动。程序是一张图，节点可以并发运行，数据在边上流动。

引入的概念：

- `go f(args)`：启动一段并发计算，与主流程并行执行。
- `h := go f(...)`：返回句柄。
- `await h`：等待结果。
- `flow`：可激活的命名子图模板。`yield` 暂停并输出值。
- 通道（`chan`）：跨执行流传递数据。

图模型：动态图。`go` 在运行时生成新的子图，与启动它的代码并行执行。

理解方式：节点、边和令牌。执行方式从按行执行过渡到数据驱动，执行顺序由数据是否可用决定，不由文本顺序决定。

阶段目标：能写生产者消费者和并发管道，包括扇出与扇入。

应用场景：

- 生产者消费者：`chan` 传递任务和结果，分离生产与消费的速率。
- 并行计算：多个 worker 分块求和或统计，使用 `go`、`await` 和 `go var start..end` 范围收集。
- 并发管道：流水线处理，使用 `flow` 和 `yield` 做流式处理。
- 并发任务池：批量独立任务并发执行，使用 `go` 和结果通道聚合。

```core
flow worker(id: int) -> int:
    yield id * 2

fn main() -> int:
    w := go worker(21)
    v := await w
    return v   // 42
```

关联：`docs/maintainer/proposals/concurrency.md`、`docs/maintainer/design/execution-model.md` 第 3 节。

## 形式规约

形式规约尚未实现。本节是设计预览。规约形式在 2026-09 定为 `#check` 和 `#ensure` 标注，与 `#pure`、`#terminating` 标签同族，见 `docs/developer/syntax.md` 第十章和 `docs/maintainer/design/spec-design.md`。独立的 `.corespec` 格式已经退役，见 `docs/maintainer/adr/adr-0001-corespec-crasm-retired.md`。规约语法和验证管线都没有实现，当前编译器不读取规约。

目标：理解行为约定。程序由实现和保证组成。

位置：形式规约是横切能力。任何阶段的代码都可以配规约，不依赖特定能力层。推荐在掌握函数签名和类型系统后引入。

引入的概念：

- `#check(...)`：前置条件。
- `#ensure(...)`：后置条件，可以引用 `result` 和 `old(x)`。
- `spec fn`：检查函数，用 Core 编写的纯逻辑函数。
- 函数内规约：`#check` 和 `#ensure` 标注，在 `.cr` 内表达。独立规约格式已经退役。

图模型：规约约束附加在图上，目前是设计状态。性质和代码来自同一来源，验证器直接使用同一张图。

理解方式：函数除了说明做什么，还说明保证什么。这些保证是代码的一部分，验证器可以直接使用。

阶段目标：能给函数写前置条件和后置条件，用检查函数表达性质，例如有序性、排列性和不变量。

```core
fn divide(a: int, b: int) -> int #check(b != 0) #ensure(result * b <= a):
    return a / b
```

关联：`docs/maintainer/design/spec-design.md`、`docs/developer/syntax.md` 第十章、`docs/maintainer/adr/adr-0001-corespec-crasm-retired.md`、`docs/superpowers/specs/` 中的验证管线设计稿。

## 应用领域

四个能力层是语言的基础。在此基础上，图模型和部署配置分离，使同一门语言可以覆盖多个领域。每个领域是四层能力的不同组合，代码不变，部署配置不同。

| 领域 | 用到的能力层 | 图结构特征 | 部署配置 | 状态 |
|---|---|---|---|---|
| 系统编程（内核、驱动、协议栈） | 1、2、3、4 加 `unsafe` 和 HIT | 全部结构 | 裸机或无 OS | 能力已实现 |
| 嵌入式与实时（无 MMU、确定性） | 1、3 | DAG 或静态图 | 静态分配，无 GC | 能力已实现 |
| 并发服务（服务器、网络后端） | 3、4 | 动态图 | 多核，OS 线程 | 已实现基础并发：`go` 和 `chan` |
| 数据处理与科学计算 | 1、3 | DAG | 通用 | 已实现，支持 `dex` 和数组 |
| 编译器与工具链 | 1、2、3、4 | 全部 | 通用 | 自举实证，用语言编写自身 |
| 安全关键系统（航空、医疗、金融） | 全部加规约 | 全部加图上约束 | 验证 | 规约设计状态 |
| 分布式系统 | 3、4 加远程节点 | 跨机图 | 集群 | 设计状态，`go @("node")` |

### 示例：系统编程

内核、驱动和网络协议栈会用到前面每个能力层的概念。DAG 对应中断处理路径，带环静态图对应设备轮询，动态图对应进程调度器，规约对应安全关键的隔离性质。

新增概念：

- 原始指针：`*T` 类型、`&x` 取址、`*p` 解引用、`cast<T>(p)` 转换。
- `unsafe` 块：图边界输入，用于外部地址、FFI 返回值和无法自动追踪来源的场景。
- `@` 内建：`@sizeOf(T)`、`@alignOf(T)`、`@fields(T)`、`@comptime`、`@inline`。
- 内存控制：`alloc_at(addr, size, align)` 声明式放置和布局控制。
- 硬件接口（HIT）：MMIO、特权和中断通过 `unsafe` 与 HIT extern 事件处理。独立汇编格式 `.crasm` 已经废弃，见 `docs/maintainer/adr/adr-0001-corespec-crasm-retired.md`。

理解方式：字节级控制和图边界。指针和 C 一样自由，安全由编译器自动验证。`unsafe` 是声明图边界输入，不是关闭验证。

```core
unsafe {
    mmio := 0x7fff0000 as *int;   // 外部地址：图边界输入
    *mmio = 42;
}
```

关联：`docs/maintainer/design/pointer-model.md`、`docs/maintainer/design/memory-model.md`、`docs/maintainer/adr/adr-0001-corespec-crasm-retired.md`。

### 示例：嵌入式与实时

无 MMU 目标和确定性延迟的主要特点是图固定区域和部署配置。静态路径完全使用 bump 分配，没有无法使用的剩余空间，也没有 GC 停顿。部署配置使用 `allocation = "static"`。

关联：`docs/maintainer/design/execution-model.md` 第 5 节、`docs/maintainer/design/memory-model.md`。

## 阶段与图结构对照

| 能力层 | 语法特性 | 图结构 | 理解方式 |
|---|---|---|---|
| 1 基础 | 变量、函数、分支、`for` | DAG | 顺序执行 |
| 2 结构化控制流 | `loop`、`while` | 带反馈环的静态图 | 循环调度 |
| 3 指针与内存 | `*T`、`&`、`unsafe`、`@` 内建、`alloc_at` | 来源追踪加自动边界验证 | 字节级控制 |
| 4 并发与通信 | `go`、`await`、`flow`、`yield`、`chan` | 动态图 | 数据驱动 |
| 横切：形式规约 | `#check`、`#ensure`、`spec fn` | 图上约束 | 行为约定 |

整个过程中，概念只增加，不减少。每个能力层学到的内容都会在下一个应用领域中继续使用。同一门语言可以从第一个程序扩展到编译器和内核。
