# Core 执行模型

语义设计以本文件为准，实现以源码为准。图与区域见 `src/compiler/dataflow.cr`，并发见 `src/stdlib/sched.cr`、`goroutine.cr`、`chan.cr`，执行器见 `src/compiler/interp.cr`，语法见 `grammar/core.ebnf`。

## 执行语义：HDFG

Core 只有一种执行语义，即 HDFG（全息数据流图）。源码经语义 IR 翻译后构成一张有向图，节点是操作，边是数据依赖。图的拓扑结构决定执行语义：

| 图结构 | 表示的语义 |
|---|---|
| 有向无环图（DAG） | 依赖偏序。没有反馈，结果确定 |
| 带环静态图 | 迭代。区域表示迭代与终止 |
| 动态图 | 并发。节点在运行时创建，数量不固定 |

程序员不需要声明执行模式，图由代码直接决定。串行、并行和调度属于部署层，不改变图语义。

三层映射的术语见 `docs/glossary.md`。图表示计算，对应关系空间。格表示计算，对应存在空间，内容是条目和生成规则。编码实现计算，对应物理空间，即 ELF。本文件只讨论图这一层。

## 图结构：区域嵌套与 state edge

图不是单层展开的网络。控制流以区域（region，存在结构段，SG）嵌套表示，副作用与终止以 state edge 表示。实现在 `dataflow.cr`，数据结构为 DFNode、DFEdge 和 SG 段表。

### 节点与边

DFNode 是操作节点。图结构本身包含类型和语义信息，不转换为指令。

DFEdge 是值流边。`kind=1` 的边称为 state edge，表示顺序约束，用于副作用序列和循环终止依赖；`kind=0` 是普通数据边。

### 区域

区域是子图在字节域中的范围。每个区域记录 `kind`、`enter`、`exit`、`parent`、`nstart`、`ncount`，由 `sg_push` 和 `sg_pop` 管理。实现见 `dataflow.cr`，设计见区域 CFG 设计文档。

`kind` 的取值：

| 值 | kind | 对应语法 | 语义 |
|---|---|---|---|
| 0 | SG_FUNC | 函数 | 函数体区域，最外层区域 |
| 1 | SG_LOOP | loop | 迭代区域。break 和 continue 是区域语义操作 |
| 2 | SG_FOR | for 循环 | 有界迭代区域 |
| 3 | SG_FLOW | flow | 可激活的命名子图区域 |
| 4 | SG_UNSAFE | unsafe | 图边界区域，也是 provenance 的边界 |
| 5 | SG_IF | if/else | 条件分支区域。条件求值前 push，区间覆盖条件和汇合点。match 展开为 if 序列，不单独建立区域 |

节点与区域的归属由 `g_df_node_region[]` 记录。该数组与节点数组并行，在 `df_create_node` 时写入当前打开的区域 id，因此归属查询为 O(1)。解释器的区域迭代、验证 pass 和 DOT 分组都不需要线性扫描。

### 终止依赖与副作用序列

state edge 有两个来源。

第一个来源是副作用序列。每个函数维护一组 state 边。STORE、STORE_FIELD、STORE_INDEX 和非纯 CALL 按指令序连成 state 边，从前一条指向当前一条。这些边在 `df_connect_srcs` 中随 emit 同步建立，由 `df_end_func` 结束。

第二个来源是循环终止依赖。SG_LOOP 和 SG_FOR 的 exit 节点各有一条 state 边，从循环体最后一条副作用指令连向 exit。这条边表示：如果循环不终止，图也不终止。循环终止与顺序性质因此可以证明。

### 执行投影

解释器（`interp.cr`）按 IR 顺序执行节点。对直线代码，文本顺序就是一个合法的拓扑序，源码注释中已有说明。区域表按 SG_LOOP 和 SG_FOR 的 enter、exit 控制循环，见 `globals.cr`。

原生执行直接生成 x86-64 ELF，属于编码层，见 `adr/adr-0003`。arena 的创建和释放见“内存生命周期”一节。

图约束执行语义，物理执行方式由编码层决定。

## 并发：Go 风格 GMP 模型

并发执行使用与 Go runtime 同构的 GMP 简化模型。G 是 goroutine（fiber），M 是 machine（OS 线程）。P 不单独分离，合并进 M。运行时没有全局 GOMAXPROCS；M 的数量等于 CPU 核数，由运行时配置决定。

早期设计中的“有 OS 时用线程、无 OS 时用时间片抢占”已经废弃。实现分布在 `src/stdlib/sched.cr`（调度）、`goroutine.cr`（G 的创建、运行和释放）和 `chan.cr`（通信），`ir_gen.cr` 负责生成 go 调用。

### 并发原语

```core
ch := make(chan int, 10)  // 缓冲 channel，容量 10
go f(args)                // 异步启动，不等待
ch2 := go g(args)         // 返回 channel 句柄，用于接收返回值
send(ch, 42)              // 发送
val := recv(ch)           // 接收
close(ch)                 // 关闭
```

这些语法与 stdlib 中 `chan_*` 函数的对应关系见 `docs/developer/syntax.md` 第十一章和 `chan.cr`。go 还支持范围批量形式 `go var start..end expr`，在 `parser.cr` 中展开。

### G：goroutine（fiber）

每个 G 是一个用户态协程，栈固定为 16 KiB，绑定独立的 arena：

```core
struct Goroutine:
    id: int
    status: int
    stack_ptr: int
    stack_lo: int
    arena_id: int
    chan_wait: int
    next: int   // 队列后继指针（run queue 或 wait queue）
```

G 有五个状态：`_Gidle`（未启动）、`_Grunnable`（在队列中）、`_Grunning`（执行中）、`_Gwaiting`（阻塞在 chan 的 send 或 recv）、`_Gdead`（已退出，等待释放）。

`go f(args)` 的语义：

1. 分配 G 结构和 16 KiB 栈。
2. 把参数复制到新 arena。
3. 创建新 arena。
4. 把状态置为 `_Grunnable`，放入 M 的本地运行队列。
5. 返回，不等待。如果该表达式用作句柄，返回 result channel。

实现见 `goroutine.cr`。`g_new` 先建立 G 的 arena，再用 `fiber_init` 初始化协程栈。起点固定为 `goroutine_entry_wrapper`，`saved_fn` 和 `result_ch` 存放在 G 结构体中。`sched_go` 等于 `g_new` 加 `sched_enqueue`。wrapper 经 `saved_fn` 调用用户函数，结果经 `result_ch` 回传。`g_free` 通过 reset arena 整块释放。

### M：machine（OS 线程）

```core
struct Machine:
    id: int
    cur_g: int
    runq_head: int
    runq_tail: int
    g0: int  // g0 = M 自身的系统 G
```

`sched_init` 注册主线程，主流程的 G 记为 G0。`sched_spawn_workers(n)` 创建多个 M，以 `m_idx` 标识。

切换使用用户态的 `fiber_switch`：保存旧 G 的寄存器到栈，装入新 G 的栈指针，全程没有内核介入。

调度循环主要使用本地运行队列：取出一个 G 运行；本地队列为空时从全局运行队列获取；两者都为空时进入 idle，OS 线程等待。切换点有两处。send 遇到已满的 chan 或 recv 遇到空的 chan 时，G 阻塞并进入等待队列，调用 `schedule()`。`yield()` 用于主动放弃 CPU。

### channel 与通信

channel 由环形缓冲和等待队列组成：

```core
struct Channel:
    buf: string
    cap: int
    len: int
    head: int
    elemsize: int
    send_wait: int
    recv_wait: int
    closed: int
```

send 分四种情况：

1. channel 已关闭时 panic。
2. 有等待接收的 G 时，直接复制给接收者并恢复它的执行。
3. 缓冲未满时写入缓冲。
4. 缓冲已满时，当前 G 阻塞，进入 `send_wait`。

recv 同样分四种情况：

1. 有等待发送的 G 时，直接接收并恢复发送者的执行。
2. 缓冲非空时取缓冲。
3. 已关闭且缓冲为空时返回零值。
4. 缓冲为空且未关闭时，G 阻塞，进入 `recv_wait`。

channel 边界始终复制值，不传引用。发送方的值在发送后不再改变。

实现见 `chan.cr`，函数为 `chan_make`、`chan_send`、`chan_recv`、`chan_close`。go 语句返回的句柄本身就是一个 result channel。

### 实现状态

截至 2026-07-31，go 已端到端可用，包括 go 单发、chan 同步、结果回传、G0 为主线程，以及从单 M 开始的协作切换。

以下仍在设计阶段：多 M worker 并行、全局运行队列获取、G 状态机完整化（`_Gwaiting` 阻塞状态）、range go 批量、select 聚合、语言层的 await 收尾语法。设计细节见 `docs/superpowers/plans/2026-07-30-concurrency.md`。

## 内存生命周期：arena

分配以 arena 为单元。arena 是“区域对应子图”内存模型的当前实现形式：区域对应子图节点，生命周期对应图是否在执行。概念设计见 `docs/archive/2026-08-13-graph-anchored-regions-design.md`，映射实例层见 `docs/maintainer/design/region-model.md`。

函数、loop、for、unsafe 等子图自动获得 arena 的生命周期。`ir_gen.cr` 在子图边界生成 `IR_ARENA_NEW=32` 和 `IR_ARENA_RESET=33`，并做编译期大小预计算。ELF 后端有两条分配路径：使用 arena 的路径和全局 bump 后备路径，见 `arch/linux/ld/elf.cr`。实现计划见 arena-model。

每个 go 创建 G 时独立建立 arena，fiber 栈和 G 结构体一起分配和释放。`g_free` 通过 reset 整块释放。

大小在静态已知时使用纯 bump 路径，不会产生无法使用的剩余空间。动态大小时分档处理。物理约束由部署配置声明，见“部署配置与时间语义”一节。

## 部署配置与时间语义

本节说明设计意图，部分内容尚未实施。实施状态以平台接口设计文档和 `plans/` 为准。

### 代码不规定分配策略

Core 代码只描述计算逻辑和数据结构，不规定内存的来源。语义 IR 保留类型、边界和编译期上限信息，但不固定分配策略。物理约束在部署配置中声明（TOML，例如 `allocation = "static"` 或 `"dynamic"`），编译器按该声明检查兼容性并生成适配代码。

### 时间语义

时钟语义是数学意义上的单调时间序。代码不区分零时间、物理实时和仿真时间，只要求单调。时间源由部署上下文和后端决定：平台接口提供 `now_monotonic` 和 `sleep_ms` 两个语义接口，系统调用隔离在后端。无操作系统环境使用硬件时钟，普通 OS 使用系统时钟，仿真器可以自行控制。部署配置决定时间源，程序语义不变。

I/O 同理。程序语义是流变换，即转导器从输入流到输出流。系统调用是物理实现，由后端按部署目标隔离，不进入程序语义。

### 资源配额

配额（CPU、内存、速率）属于运营策略，可以在部署配置中声明。不声明即无限制。代码不变。

## 代码与部署分离

同一份代码可以部署到不同环境：

- 教学环境：解释器逐步执行，可以单步。
- 桌面：AOT 编译为原生代码执行，直接生成 ELF。
- 嵌入和无操作系统环境：静态分配加 arena，没有运行时依赖。
- 集群：图可以远程部署。分布式仍在设计阶段，见 `docs/maintainer/proposals/distributed.md`。

这四种情况的代码相同，图的语义相同，只有部署配置不同。

## 小结

代码生成图结构，图表示执行语义。区域嵌套和 state edge 表示控制流与副作用。并发使用 Go 风格 GMP 模型，由 go、fiber 和 chan 构成，采用协作调度。内存以 arena 管理生命周期。执行方式和物理约束属于部署层。图简单时执行简单，图复杂时执行复杂，不需要人为命名模式。
