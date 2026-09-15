# Core 执行模型

> 定位:受众 = 维护者/贡献者/用户;状态 = active。
> 真源:语义设计以本文件为准;实现以源码为准——图/region:src/compiler/dataflow.cr;并发:src/stdlib/sched.cr、goroutine.cr、chan.cr;执行器:src/compiler/interp.cr;语法:grammar/core.ebnf。
> 本文 2026-09 全量重写:并发部分废弃旧"OS 线程/抢占式"设计,改为与实现一致的 Go 风格 GMP 简化模型;实现与设计的差距以"设计态/已实现"标注,不删设计意图。

---

## 一、唯一执行模型(HDFG)

Core 只有一种执行语义:HDFG(全息数据流图)。代码经语义 IR 翻译后构成一张有向图——
节点是操作,边是数据依赖。图的拓扑承载执行语义:

| 图结构 | 承载语义 |
|---|---|
| 有向无环图(DAG) | 依赖偏序——无反馈,确定性 |
| 带环静态图 | 迭代——region 表达迭代与终止 |
| 动态图 | 并发——节点运行时创建、生命周期动态管理 |

程序员不需要声明"模式":代码写了什么,图就反映什么。执行方式(串行/并行/调度)属于
部署层,图语义不变。

三层映射(术语见 docs/glossary.md):**图**表达计算(关系空间)、**格**承载计算
(存在空间,条目/配方)、**编码**实现计算(物理空间,ELF)。本文只讲图这一层。

---

## 二、图的落地形状:region 嵌套与 state edges

图不是一张摊平的网络——控制流以 **region(存在结构段 SG)嵌套**表达,副作用与终止以
**state edges** 表达。实现于 dataflow.cr(DFNode/DFEdge + sg 段表)。

### 2.1 节点与边

- DFNode:操作节点,图结构携带类型与语义信息(不降格为指令)
- DFEdge:值流边;其中 **state edge**(边 kind=1)表达顺序约束——副作用链与循环终止依赖

### 2.2 region(SG 段)

region 是子图的字节域锚定:每个 region 记录 kind/enter/exit/parent/nstart/ncount
(sg_push/sg_pop,见 dataflow.cr;设计定稿 = region-cfg-design)。kind 取值:

| 值 | kind | 对应语法 | 语义 |
|---|---|---|---|
| 0 | SG_FUNC | 函数 | 函数体域(根 region) |
| 1 | SG_LOOP | loop | 迭代域(break/continue 为 region 语义操作) |
| 2 | SG_FOR | for 循环 | 有界迭代域 |
| 3 | SG_FLOW | flow | 可激活命名子图域 |
| 4 | SG_UNSAFE | unsafe | 图边界入口域(provenance 边界) |
| 5 | SG_IF | if/else | 条件分支域(条件求值前 push,区间覆盖 [条件, 汇合);match 展开为 if 链,不单独建 region) |

显式映射:`g_df_node_region[]` 并行数组——df_create_node 时写入当前 open region id,
O(1) 归属查询(解释器 region 迭代/验证 pass/DOT 分组免线性扫描)。

### 2.3 终止依赖与副作用链

state edge = DFEdge 的 kind=1 边(0=data,1=state;边结构设计定稿 = region-cfg-design)。
两条来源:

1. **副作用链**:每个函数维护一条 state 链——STORE/STORE_FIELD/STORE_INDEX/非纯 CALL
   按指令序连 state 边(prev → cur),构建于 df_connect_srcs(emit 同步建图),df_end_func 闭合
2. **循环终止依赖**:SG_LOOP/SG_FOR 的 exit 节点,从循环体最后一条副作用指令连一条
   state 边到 exit——"循环不终止则图不终止",终止性依赖显式化后可证循环终止与顺序性质

### 2.4 执行投影:顺序即拓扑

- **解释器**(interp.cr):按 IR 顺序执行节点——对直线代码,文本顺序即合法拓扑序
  (源码注释明言);region 表按 SG_LOOP/SG_FOR 的 enter/exit 驱动循环(globals.cr)
- **原生**:ELF 直出 x86-64 机器码(编码层投影,见 adr/adr-0003);arena 生命周期见 §四

图是执行语义的载体,不是执行方式的决定者——物理执行由编码层决定,图只约束语义。

---

## 三、并发:Go 风格 GMP 模型(G 并入 M 的简化)

> 2026-09 定稿(设计 = concurrency-design,2026-07-30):并发执行采用 **Go runtime 同构的
> GMP 简化模型**——G = goroutine(fiber),M = machine(OS 线程),**P 不分离,合并到 M**;
> 无全局 GOMAXPROCS,M 数量 = CPU 核数(运行时配置)。
> 废弃早期设计的"有 OS 用线程 / 无 OS 时间片抢占"。实现:src/stdlib/sched.cr(调度)、
> goroutine.cr(G 生命周期)、chan.cr(通信);ir_gen.cr 发射 go 调用。

### 3.1 并发原语

```core
ch := make(chan int, 10);  // 缓冲 channel,容量 10
go f(args);                // 异步启动,不等待
ch2 := go g(args);         // 返回 channel 句柄,用于接收返回值
send(ch, 42);              // 发送
val := recv(ch);           // 接收
close(ch);                 // 关闭
```

- 语法层与 stdlib chan_* 的对应见 docs/developer/syntax.md 第十一章与 chan.cr
- go 也支持范围批量形态(go var start..end expr,parser.cr desugar)

### 3.2 G:goroutine(fiber)

每个 G = 一个用户态协程,固定 16KB 栈,绑定独立 arena:

```core
struct Goroutine {
    id: int;  status: int;  stack_ptr: int;  stack_lo: int;
    arena_id: int;  chan_wait: int;  next: int;   // 链表(run/wait queue)
}
```

G 状态机:_Gidle(未启动)/ _Grunnable(队列中)/ _Grunning(执行中)/
_Gwaiting(阻塞在 chan send/recv)/ _Gdead(退出待回收)。

`go f(args)` 语义(设计定稿):
1. 分配 G 结构 + 16KB 栈
2. 复制参数到新 arena
3. 创建新 arena
4. 状态置 _Grunnable,投递到 M 的 local run queue
5. 返回(不等待;若用作句柄则返回 result channel)

实现(goroutine.cr):g_new 先建 G 的 arena,再 fiber_init 初始化协程栈;entry 恒为
goroutine_entry_wrapper,saved_fn/result_ch 存 G 结构体;sched_go = g_new + sched_enqueue;
wrapper 经 saved_fn 调用户函数,结果经 result_ch 回传;g_free = reset arena 整块回收。

### 3.3 M:machine(OS 线程)

```core
struct Machine {
    id: int;  cur_g: int;  runq_head: int;  runq_tail: int;  g0: int;  // g0 = M 自身的系统 G
}
```

- sched_init 注册主线程(G0 = 主流程的 G);sched_spawn_workers(n) 派生多 M(m_idx 标识)
- 切换 = 用户态 fiber_switch(保存旧 G 寄存器到栈、装入新 G 栈指针)——无内核介入
- 调度循环(local run queue):取一个 G 运行;local 空 → 从 global run queue 偷;
  global 也空 → idle(OS 线程休眠)
- 切换点:send 遇满 chan / recv 遇空 chan → G 阻塞入等待链表,schedule();yield() 主动让出

### 3.4 Channel 与通信

channel = 环形缓冲 + 等待链表:

```core
struct Channel {
    buf: string;  cap: int;  len: int;  head: int;  elemsize: int;
    send_wait: int;  recv_wait: int;  closed: int;
}
```

- send:已关闭 → panic;有等待接收的 G → 直拷给接收者并唤醒;buf 未满 → 入缓冲;
  buf 满 → 当前 G 阻塞入 send_wait
- recv:有等待发送的 G → 直收并唤醒发送者;buf 非空 → 取缓冲;已关闭且空 → 零值;
  空且未关 → G 阻塞入 recv_wait
- **值拷贝语义**:channel 边界永远拷贝值,不传引用;发送方的值发送后不变

实现:chan.cr 的 chan_make/chan_send/chan_recv/chan_close;go 句柄本身即 result channel。

### 3.5 实现现状与设计态

已实现(2026-07-31 go 端到端):go 单发、chan 同步、result 回传、G0 = 主线程、
协作切换(单 M 起)。设计态/推进中:多 M worker 并行、global run queue 偷取、
G 状态机完整化(_Gwaiting 阻塞链)、range go 批量、select 聚合、语言层 await 收尾语法。
推进记录见 docs/superpowers/plans/2026-07-30-concurrency.md。

---

## 四、内存生命周期:arena

分配以 **arena** 为单元——arena 是"图锚定区域"内存模型的当前实现形态
(区域 = 子图节点,生命周期 = 图活性;概念设计见 2026-08-13-graph-anchored-regions-design,
映射实例层见 docs/maintainer/design/region-model.md):

- 函数/loop/for/unsafe 等子图自动获得 arena 生命周期(ir_gen.cr 在子图边界发射
  IR_ARENA_NEW=32/IR_ARENA_RESET=33,含编译期大小预计算;ELF 后端双路径 alloc:
  arena 感知 + 全局 bump 回退,见 arch/linux/ld/elf.cr;实现计划 = arena-model)
- 每个 go 的 G 在创建时独立建 arena,fiber 栈与 G 结构体同生共死,g_free = reset 整块回收
- 静态已知大小路径 = 纯 bump 零碎片;动态路径分档;物理约束(配额等)由部署配置声明(§五)

---

## 五、部署配置与时间语义(设计态)

> 以下为设计意图,部分未落地——落地状态以平台桥设计与 plans/ 为准。

### 5.1 代码不规定分配策略

Core 代码只描述计算逻辑与数据结构,不规定内存从哪来。语义 IR 保留类型/边界/编译期上限
信息,但不固定分配策略。物理约束在部署配置中声明(TOML,如 allocation = "static"/"dynamic"),
编译器据此检查兼容性并生成适配代码。

### 5.2 时间语义

时钟语义 = 单调时间序(数学):代码不区分零时间/物理实时/仿真时间,只要求单调。
时间源由部署上下文与后端决定(平台桥语义接口 now_monotonic/sleep_ms;系统调用隔离在后端)
——裸机用硬件时钟、普通 OS 用系统时钟、仿真器可控。部署配置决定时间源,程序语义不变。

I/O 同理:程序语义 = 流变换(转导器:(输入流)→(输出流));系统调用是物理实现,由后端按
部署目标隔离,不进入程序语义。

### 5.3 资源配额

配额(CPU/内存/速率)属运营策略,在部署配置中可选声明,不声明即无限制;代码不变。

---

## 六、代码与部署分离

同一份代码:

- 教学环境 → 解释器逐步执行,可单步
- 桌面 → AOT 编译原生执行(ELF 直出)
- 嵌入/裸机 → 静态分配 + arena,零运行时依赖
- 集群 → 图可远程部署(分布式为设计态,见 docs/maintainer/proposals/distributed.md)

代码不改。图语义唯一。部署配置不同。

---

## 七、结论

代码生成图结构,图承载执行语义;region 嵌套与 state edges 表达控制流与副作用;
并发 = Go 风格 GMP 模型(go/fiber/chan,协作调度);内存 = arena 生命周期;
执行方式与物理约束归部署层。拓扑简单则执行简单,拓扑复杂则执行复杂——
不需要人为命名任何"模式"。
