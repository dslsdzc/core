# Core 执行模型

> 定位：受众 = 维护者/贡献者/用户；状态 = active。
> 语义设计以本文件为准；实现以源码为准——图与 region 见 `src/compiler/dataflow.cr`，并发见 `src/stdlib/sched.cr`、`goroutine.cr`、`chan.cr`，执行器见 `src/compiler/interp.cr`，语法见 `grammar/core.ebnf`。
> 修订（2026-09）：并发一节重写。早期设计中的「OS 线程 / 抢占式」已被废弃，改用与实现一致的 Go 风格 GMP 简化模型。实现与设计的差距在各节以「已实现」或「设计态」标注，不删设计意图。

## 执行模型：HDFG

Core 只有一种执行语义，即 HDFG（全息数据流图）。源码经语义 IR 翻译后构成一张有向图，节点是操作，边是数据依赖，图的拓扑结构承载执行语义：

| 图结构 | 承载的语义 |
|---|---|
| 有向无环图（DAG） | 依赖偏序。无反馈，确定性 |
| 带环静态图 | 迭代。region 表达迭代与终止 |
| 动态图 | 并发。节点在运行时创建，生命周期动态管理 |

程序员不需要声明「模式」，图由代码直接决定。执行方式（串行、并行、调度）属于部署层，不改变图语义。

三层映射（术语见 `docs/glossary.md`）：图表达计算，对应关系空间；格承载计算，对应存在空间，内容是条目与配方；编码实现计算，对应物理空间，即 ELF。本文只讲图这一层。

## 图的结构：region 嵌套与 state edge

图不是摊平的网络。控制流以 region（存在结构段，SG）嵌套表达，副作用与终止以 state edge 表达。实现在 `dataflow.cr`，数据结构为 DFNode/DFEdge 加 sg 段表。

### 节点与边

DFNode 是操作节点，图结构本身携带类型与语义信息，不降格为指令。DFEdge 是值流边，其中 kind=1 的边称为 state edge，表达顺序约束，用于副作用链与循环终止依赖。

### region（SG 段）

region 是子图的字节域锚定。每个 region 记录 kind/enter/exit/parent/nstart/ncount，由 `sg_push`/`sg_pop` 管理（见 `dataflow.cr`；设计定稿见 region-cfg-design）。kind 的取值：

| 值 | kind | 对应语法 | 语义 |
|---|---|---|---|
| 0 | SG_FUNC | 函数 | 函数体域，根 region |
| 1 | SG_LOOP | loop | 迭代域。break/continue 是 region 语义操作 |
| 2 | SG_FOR | for 循环 | 有界迭代域 |
| 3 | SG_FLOW | flow | 可激活命名子图域 |
| 4 | SG_UNSAFE | unsafe | 图边界入口域，provenance 边界 |
| 5 | SG_IF | if/else | 条件分支域。条件求值前 push，区间覆盖 [条件, 汇合)。match 展开为 if 链，不单独建 region |

节点与 region 的归属由 `g_df_node_region[]` 记录。该数组与节点数组并行，在 `df_create_node` 时写入当前打开的 region id，使归属查询为 O(1)——解释器的 region 迭代、验证 pass 与 DOT 分组都不必线性扫描。

### 终止依赖与副作用链

state edge 是 DFEdge 中 kind=1 的边，kind=0 为普通的 data 边（边结构设计定稿见 region-cfg-design）。它有两个来源：

一是副作用链。每个函数维护一条 state 链，STORE、STORE_FIELD、STORE_INDEX 与非纯 CALL 按指令序连成 state 边（prev → cur）。链条在 `df_connect_srcs` 中随 emit 同步建立，由 `df_end_func` 闭合。

二是循环终止依赖。SG_LOOP 与 SG_FOR 的 exit 节点各有一条 state 边，从循环体最后一条副作用指令连向 exit。这条边把「循环不终止则图不终止」显式化，使循环终止与顺序性质可证。

### 执行投影

解释器（`interp.cr`）按 IR 顺序执行节点。对直线代码，文本顺序就是一个合法的拓扑序，这一点源码注释中已有说明；region 表按 SG_LOOP/SG_FOR 的 enter/exit 驱动循环（见 `globals.cr`）。

原生执行走 ELF 直出 x86-64 机器码，属于编码层投影（见 `adr/adr-0003`）。arena 生命周期见「内存生命周期」一节。

图约束的是执行语义，物理执行方式由编码层决定。

## 并发：Go 风格 GMP 模型

此模型于 2026-09 定稿（原设计见 concurrency-design，2026-07-30）。并发执行采用与 Go runtime 同构的 GMP 简化模型：G 是 goroutine（fiber），M 是 machine（OS 线程），P 不单独分离，合并进 M。运行时没有全局 GOMAXPROCS，M 的数量等于 CPU 核数，由运行时配置决定。早期设计中「有 OS 时用线程、无 OS 时用时间片抢占」的方案已废弃。实现分布在 `src/stdlib/sched.cr`（调度）、`goroutine.cr`（G 生命周期）与 `chan.cr`（通信），`ir_gen.cr` 负责发射 go 调用。

### 并发原语

```core
ch := make(chan int, 10)  // 缓冲 channel,容量 10
go f(args)                // 异步启动,不等待
ch2 := go g(args)         // 返回 channel 句柄,用于接收返回值
send(ch, 42)              // 发送
val := recv(ch)           // 接收
close(ch)                 // 关闭
```

这些语法与 stdlib 中 `chan_*` 函数的对应关系见 `docs/developer/syntax.md` 第十一章与 `chan.cr`。go 还支持范围批量形态（`go var start..end expr`，在 `parser.cr` 中 desugar）。

### G：goroutine（fiber）

每个 G 是一个用户态协程，栈固定为 16KB，绑定独立的 arena：

```core
struct Goroutine:
    id: int
    status: int
    stack_ptr: int
    stack_lo: int
    arena_id: int
    chan_wait: int
    next: int   // 链表(run/wait queue)
```

G 的状态机有五个状态：`_Gidle`（未启动）、`_Grunnable`（在队列中）、`_Grunning`（执行中）、`_Gwaiting`（阻塞在 chan 的 send 或 recv）、`_Gdead`（已退出，待回收）。

`go f(args)` 的语义（设计定稿）是：

1. 分配 G 结构与 16KB 栈
2. 把参数复制到新 arena
3. 创建新 arena
4. 状态置为 `_Grunnable`，投递到 M 的 local run queue
5. 返回，不等待；若该表达式用作句柄，则返回 result channel

实现见 `goroutine.cr`：`g_new` 先建立 G 的 arena，再用 `fiber_init` 初始化协程栈；入口固定为 `goroutine_entry_wrapper`，`saved_fn` 与 `result_ch` 存放在 G 结构体中；`sched_go` 等于 `g_new` 加 `sched_enqueue`；wrapper 经 `saved_fn` 调用用户函数，结果经 `result_ch` 回传；`g_free` 通过 reset arena 整块回收。

### M：machine（OS 线程）

```core
struct Machine:
    id: int
    cur_g: int
    runq_head: int
    runq_tail: int
    g0: int  // g0 = M 自身的系统 G
```

`sched_init` 注册主线程，主流程的 G 记为 G0；`sched_spawn_workers(n)` 派生多个 M，以 m_idx 标识。

切换走用户态的 `fiber_switch`：保存旧 G 的寄存器到栈，装入新 G 的栈指针，全程无内核介入。

调度循环以 local run queue 为中心：取一个 G 运行；local 为空时从 global run queue 偷取；两者皆空则 idle，OS 线程休眠。切换点有两处：send 遇到已满的 chan 或 recv 遇到空的 chan 时，G 阻塞并进入等待链表，调用 `schedule()`；`yield()` 用于主动让出。

### channel 与通信

channel 由环形缓冲与等待链表组成：

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

send 的行为分四种情况：channel 已关闭则 panic；有等待接收的 G 则直接拷贝给接收者并唤醒它；缓冲未满则写入缓冲；缓冲已满则当前 G 阻塞，进入 send_wait。

recv 的行为同样分四种情况：有等待发送的 G 则直接接收并唤醒发送者；缓冲非空则取缓冲；已关闭且缓冲为空则返回零值；缓冲为空且未关闭则 G 阻塞，进入 recv_wait。

channel 边界永远拷贝值，不传引用。发送方的值在发送后不再改变。

实现在 `chan.cr`，函数为 `chan_make`/`chan_send`/`chan_recv`/`chan_close`。go 语句返回的句柄本身就是一个 result channel。

### 实现现状

截至 2026-07-31，go 已端到端可用，包括 go 单发、chan 同步、结果回传、G0 为主线程，以及从单 M 起步的协作切换。

以下仍在设计态：多 M worker 并行、global run queue 偷取、G 状态机完整化（`_Gwaiting` 阻塞链）、range go 批量、select 聚合、语言层的 await 收尾语法。推进记录见 `docs/superpowers/plans/2026-07-30-concurrency.md`。

## 内存生命周期：arena

分配以 arena 为单元。arena 是「图锚定区域」内存模型的当前实现形态：区域对应子图节点，生命周期对应图活性。概念设计见 `2026-08-13-graph-anchored-regions-design`，映射实例层见 `docs/maintainer/design/region-model.md`。

函数、loop、for、unsafe 等子图自动获得 arena 生命周期。`ir_gen.cr` 在子图边界发射 `IR_ARENA_NEW=32` 与 `IR_ARENA_RESET=33`，并做编译期大小预计算；ELF 后端有两条分配路径，arena 感知路径与全局 bump 回退，见 `arch/linux/ld/elf.cr`。实现计划见 arena-model。

每个 go 创建 G 时独立建立 arena，fiber 栈与 G 结构体同生共死，`g_free` 通过 reset 整块回收。

大小在静态已知时走纯 bump 路径，零碎片；动态大小则分档处理。物理约束（例如配额）由部署配置声明，见「部署配置与时间语义」一节。

## 部署配置与时间语义

> 本节为设计意图，部分尚未落地。落地状态以平台桥设计文档与 `plans/` 为准。

### 代码不规定分配策略

Core 代码只描述计算逻辑与数据结构，不规定内存的来源。语义 IR 保留类型、边界与编译期上限信息，但不固定分配策略。物理约束在部署配置中声明（TOML，例如 `allocation = "static"` 或 `"dynamic"`），编译器按该声明检查兼容性并生成适配代码。

### 时间语义

时钟语义是数学意义上的单调时间序。代码不区分零时间、物理实时与仿真时间，只要求单调。时间源由部署上下文与后端决定：平台桥提供 `now_monotonic`/`sleep_ms` 两个语义接口，系统调用隔离在后端。裸机用硬件时钟，普通 OS 用系统时钟，仿真器可以自行控制。部署配置决定时间源，程序语义不变。

I/O 同理。程序语义是流变换，即转导器 `(输入流) → (输出流)`。系统调用是物理实现，由后端按部署目标隔离，不进入程序语义。

### 资源配额

配额（CPU、内存、速率）属于运营策略，可在部署配置中声明，不声明即无限制。代码不变。

## 代码与部署分离

同一份代码可以部署到不同环境：

- 教学环境 → 解释器逐步执行，可单步
- 桌面 → AOT 编译为原生代码执行（ELF 直出）
- 嵌入与裸机 → 静态分配加 arena，零运行时依赖
- 集群 → 图可远程部署（分布式为设计态，见 `docs/maintainer/proposals/distributed.md`）

这四种情况的代码相同，图的语义相同，只有部署配置不同。

## 小结

代码生成图结构，图承载执行语义。region 嵌套与 state edge 表达控制流与副作用。并发是 Go 风格 GMP 模型，由 go、fiber 与 chan 构成，采用协作调度。内存以 arena 管理生命周期。执行方式与物理约束归部署层，拓扑简单则执行简单，拓扑复杂则执行复杂，不需要人为命名任何模式。
