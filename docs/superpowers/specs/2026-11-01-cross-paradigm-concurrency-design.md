# Core 跨范式并发底层设计

> 定位：受众 = 维护者；状态 = 设计态；出处 = 本页。

状态：设计定稿（2026-11-01，待实施）
范围：执行体、区域、通信、传输计划、目标能力与映射的底层抽象。本文不定义新的源码语法。
上位规格：`docs/superpowers/specs/2026-09-17-concurrency-model-design.md`（语义、确定性、传输 primitive、预算与证书）
替换关系：本文替换 2026-09-17 规格中把 `M = OS 线程 / CPU 核数` 当作基础的实现假设；语义与不变量仍以上位规格为准。

## 1. 问题

当前实现把 CPU mapping 写成了并发模型本身：

- `M` 直接等于 OS 线程；`go` 被降成 `sched_go(fn_ptr, arg)`；
- 每个执行体被假设为“fiber + 自有栈 + `%fs` TLS”；
- channel 被假设为 8 字节字 + G 等待链；
- arena 被假设为每 M 的 `mmap` slot/segment 表；
- 运行时重新猜测编译器已经知道的类型、布局、owner 和生命周期。

后果不是“多 M 没调好”，而是对象模型和映射层混在一起：结果 channel 会落进编译器函数 arena，segment/slot 的 owner 会在运行时错位。这些在 GPU、FPGA、集群上更不可能成立。

> 并发是程序图上的执行体关系；线程、核心、warp、pipeline stage、节点都只是执行体的 mapping provider。

## 2. 设计原则

1. 并发是结构，不是硬件。并发关系由 ExecutionBody 与 ConcurrencyEdge 描述，不由线程/核心描述。
2. 编译期已知的事实是契约。布局、region owner、生命周期、传输义务、独立性由编译器给出；运行时不重新推导。
3. 目标期绑定资源能力。slot 种类/数量、memory space、传输路径、同步机制由 TargetProfile 给出，不进入源码/语义 IR。
4. 运行期只知道动态事实。实际可用 slot、拓扑、负载、动态大小、实际竞争、调度时机；运行时不定义语义。
5. mapping 不能改变语义。同一份计划在 CPU/GPU/FPGA/集群上执行，值、效应、控制去向、终止类别和已声明预算保持一致。
6. 不支持就 fail-closed。目标能力不足时拒绝或回退到语义等价方案；不生成表面可运行但语义不等价的映射。
7. 不新增源码语法。不引入泛型通道语法、lock/mutex/atomic/ownership 关键字，也不引入 CPU/GPU 专用关键字。并发 surface 仍是现有 `go`、channel、`await`、`yield`、`flow`。
8. 执行资源是逻辑 slot。一个核心可以有多个 slot，一个 slot 可以串行承载多个 body；核心数只是 slot provider 的一种默认来源。
9. 预算在 mapping 定稿时闭合。编译期给出可判定的预算义务；目标期/映射期把实际能力代入，状态可见。

## 3. 三分：编译期、目标期、运行期

| 阶段 | 知道什么 | 产出 |
|---|---|---|
| 编译期 | body 图、activation 结构、region 图、边与顺序、消息布局/bound、传输义务、独立性、liveness、可并行域 | ExecutionPlan / RegionPlan / TransferPlan / 约束 |
| 目标期 | slot 种类/层级/数量范围、memory space、传输路径与成本、同步能力、是否支持阻塞/动态创建、拓扑 | TargetProfile（版本化） |
| 运行期 | 实际可用 slot、实际拓扑、负载、动态 extent、实际竞争、调度时机 | MappingPlan 的实例与执行 |

编译期对象只携带约束（如 `space_constraint`、`home_constraint`），不携带具体 space/slot。具体值由 mapping 绑定。

## 4. 六个核心抽象

### 4.1 ExecutionBody / Activation

ExecutionBody 是并发结构的模板；Activation 是它在一次运行中的实例。

| body kind | 含义 | 典型映射 |
|---|---|---|
| `TASK` | 动态创建、可以挂起和通信的一次执行 | CPU fiber/thread、GPU persistent task、集群节点任务 |
| `DATA_PARALLEL` | 一个索引域上的多个独立实例 | GPU lane/warp/workgroup、CPU 线程池、SIMD |
| `PIPELINE` | 有输入/输出流的流水级 | FPGA stage、CPU 流水线、GPU stream |

```text
ExecutionBody {
  body_id
  kind
  entry
  param_layout              // 编译期已知
  owned_regions             // Region id 集
  input_ports / output_ports
  lifetime_class            // LEXICAL | UNTIL_JOIN | DYNAMIC
  requirements {            // 映射要求，不是目标事实
    may_suspend, needs_stack, dynamic_create, kernelizable
  }
}

Activation {
  activation_id
  body_id
  parent_activation
  group_id                  // DATA_PARALLEL 的实例组
  index_domain              // 动态或静态
  region_bindings
  binding_slot              // 由 MappingPlan 填
}
```

- `go` 声明的是“存在一个并发 body/activation”，不是“创建一个 OS 线程”。
- body 与 slot 不要求一一对应；一个 slot 可以串行承载多个 activation，一个核心可以承载多个 slot。
- `TASK` 若声明 `needs_stack`/`may_suspend`，非 stackful slot 只能映射其 `kernelizable` 子集，否则 host proxy 或 fail-closed。
- 现有循环被证明迭代独立时，可成为 `DATA_PARALLEL` body；不新增源码语法。

### 4.2 Region

Region 是一段有唯一 owner、生命周期、布局和 space 约束的状态/字节域。

```text
Region {
  region_id
  parent_region             // Region 树
  owner_body / owner_activation
  scope                     // INSTANCE | GROUP | BODY
  lifetime_class            // LEXICAL | UNTIL_JOIN | DYNAMIC
  space_constraint          // ANY | HOST_ONLY | DEVICE_ONLY | HOST_ACCESSIBLE
  layout / size_bound
  access_mode               // MUTABLE | READ_ONLY
}
```

- Region 图是树 + outlives 边，不是任意共享所有权图；每个 region 有唯一 owner。
- 运行时对象（Task、Channel、Message、等待节点）属于某个 owner region，永远不落进 compiler function arena。用户局部变量才走函数 arena。
- 实际 memory space 由 `MappingPlan` 绑定；编译期只写约束。
- 默认 share-nothing：跨 body 没有共享可变 region。只读共享是 mapping 优化，不是新 primitive。
- `scope=GROUP` 只允许在同一个 DATA_PARALLEL group 内共享；跨 group 的可变共享走 TransferPlan 或共享映射实验，且带等价性/死锁证明。

### 4.3 ConcurrencyEdge

Edge 描述 body/activation 之间的关系，不是物理时序：

- `SPAWN`：父 activation 创建子 activation；
- `SEND` / `RECV`：channel 边；
- `JOIN` / `AWAIT`：等待完成或输出就绪；
- `STATE`：副作用顺序；
- `DATA`：数据依赖；
- `ORDER`：显式顺序约束。

Edge 携带：顺序种类、是否可交换、channel FIFO 语义、传输义务引用。producer/consumer 数量是 channel 级属性，不是 edge 级属性。

可观察顺序只来自显式 edge、state 链和图上的顺序源；调度器的物理顺序不升格为语义。单产单消 channel 的 FIFO 是语义序；多产/多消没有跨发送者全局序，除非 `ordered(src)` 这类图标注（不是源码语法）或等价证明。

### 4.4 TransferPlan

TransferPlan 是编译器给出的跨 region/执行体数据义务：

| primitive | 语义 | 源侧后置条件 |
|---|---|---|
| `MOVE` | owner 永久转移 | 源侧失效，后续不可访问 |
| `LOAN` | owner 临时转移，之后归还 | 借出期间源侧不可访问，归还后恢复 |
| `SPLIT` | 不重叠子区域分给不同 body | 各子区域 owner 独立，互不重叠 |
| `FILL` | 接收方预留目标，生产方直接构造 | 目标 region 生命周期覆盖接收方使用 |
| `COPY` | 只复制无法消除的最小子区域 | 双方各持独立材料 |

```text
TransferPlan {
  transfer_id
  from_region / to_activation
  primitive
  copy_set                 // 对 COPY 精确到 subregion
  source_postcondition     // INVALID | RETURN | DISJOINT | NONE
  space_path_constraint    // 不是具体路径
  budget_refs
}
```

关键规则：

- Plan 是 target-neutral 的；物理上可以 DMA、RDMA、COW、kernel 直写，但不改变所有者/可见性语义。
- 跨 memory space 的 `MOVE` 可以在物理上发生拷贝，但逻辑上源侧仍然失效；物理搬运字节单独记预算，不能把 MOVE 的逻辑 0 当成物理 0。
- MOVE 不能无条件降级为 COPY。只有当源侧在 plan 中确实 dead（或显式记录失效）时，才允许把 MOVE 的实现改成分离副本；否则拒绝或串行。
- LOAN 不能用 COPY 替代：COPY 不会归还所有权，也不会恢复源侧访问禁令。
- SPLIT 不能用 COPY 替代，除非复制后的子区域仍然满足“互不重叠 + 各自 owner”且源侧不再使用；否则拒绝。
- FILL 在目标 region 已存在且语义等价时可以回退 COPY；否则拒绝。
- COPY 永远可行，但只允许复制 CopySet；分析不精确只增加复制量，不产生错误拒绝。
- `SHARE` 不是 primitive；只读共享是 mapping 优化。可变共享只属于实验 shared mapping，带等价性与死锁证书。

### 4.5 TargetCapabilities / TargetProfile

TargetProfile 是版本化的目标描述，可由后端配置、部署 TOML 或受控探测产生；它不是语义分析。

```text
TargetProfile {
  version
  topology {
    nodes: [{node_id, parent_node, locality}],
    links: [{from, to, bandwidth_class, latency_class}]
  }
  slots: [{
    kind: CPU_THREAD | CPU_FIBER | GPU_LANE | GPU_WARP | GPU_WORKGROUP | PIPELINE_STAGE | REMOTE_NODE,
    scope, parent_kind,
    count_min, count_max,
    stackful, may_suspend, dynamic_create,
    preemption: NONE | COOPERATIVE | PREEMPTIVE
  }]
  memory: [{
    space: HOST | DEVICE_GLOBAL | DEVICE_SHARED | LOCAL | BRAM | REMOTE,
    scope, capacity, shared, coherent, host_accessible,
    consistency: SEQUENTIAL | RELEASE_ACQUIRE | WEAK | NONE
  }]
  transfers: [{from_space, to_space, mechanism, supported, cost_model}]
  sync: [{kind: ATOMIC | BARRIER | QUEUE | RENDEZVOUS | HANDSHAKE,
          scope, blocking, ordering}]
  resources { compute_units, local_memory, ... }
  scheduling: COOPERATIVE | PREEMPTIVE | STATIC | HYBRID
  limits { max_activation_depth, max_blocking_activations, dynamic_memory }
}
```

- slot 是层级：CPU thread/fiber、GPU lane 到 warp 到 workgroup、pipeline stage 都是父子关系，不是扁平同义词。
- `count_min/count_max` 是逻辑 slot 的范围；CPU 核数只是提供者，不是含义。
- 一个 core 可以有多个 slot；一个 slot 可以串行承载多个 activation。
- 目标可以声明“不支持任意阻塞通信”“不支持动态 activation 创建”等限制；mapping 据此拒绝或改映射。
- `TargetProfile` 版本化；运行期探测只能收窄已知能力，不能建立新的合法性。

### 4.6 MappingPlan

MappingPlan 把 ExecutionPlan 落到具体 target：

- body/activation 映射到 slot kind / instance；
- region 映射到 memory space；
- transfer 映射到物理机制（DMA/RDMA/COW/kernel copy）；
- schedule 映射到允许的交错与同步；
- body 的 home/slot 选择只在这里出现。

合法性规则：

1. body kind、requirements 被 slot kind 支持；
2. region 的 space_constraint 存在且满足容量、可见性和一致性；
3. transfer 有路径，或能回退到语义等价的 primitive（见 4.4，不是无条件 COPY）；
4. sync 能满足 edge 的顺序和等待语义；
5. 阻塞或动态创建等限制满足；
6. 任何生成的 sync 或阻塞等待有无环证书；不能证明则 SERIAL、语义等价回退或拒绝；
7. 任何一步不能证明，fail-closed。

MappingPlan 不是 `.ccr` 内容。transfer/sync 决策与证书走决策记录旁路（承 2026-09-17 evidence §16 G5/G6）。

### 4.7 Plan artifact 与 runtime ABI

同一份 plan 要能在 CPU/SIMT 上执行，plan 不能只存在于编译器进程里：

```text
ConcurrencyPlan {
  version
  execution_plan   // bodies, activations templates, edges
  region_plan      // region tree, constraints, lifetimes
  transfer_plan    // obligations
  channel_plan     // descriptors
  budget_plan      // obligations + declared entries
  target_requirements
}
```

- plan 是旁路 artifact（版本化二进制/结构化元数据），不写进 `.ccr`；代码只携带 plan id / descriptor id。
- MappingPlan 单独存放，绑定 TargetProfile 版本；同一 plan 可以有多个 MappingPlan。
- runtime entry ABI 至少包含：注册 plan、创建 activation、channel 操作、transfer 执行、完成/等待。具体 ABI 由实施计划定。
- plan 版本不匹配时 fail-closed，不允许“尽量解析”。

## 5. 调度、确定性与预算

- 调度器只消费 body/activation 图和 Edge，不假设线程/栈/fiber。
- slot 是逻辑执行上下文；一个 core 上可以有多个 slot，一个 slot 可以串行跑多个 activation。
- 调度可以改变执行时机，不能改变可观察语义：值、效应、控制去向、终止类别、已声明预算。
- 独立性由编译器证明；没有证明且没有显式顺序，拒绝编译，不让调度器决定结果。
- CPU 协作调度、GPU warp 调度、FPGA 静态调度、集群网络调度都是 mapping；语义相同。
- 多 slot/多实例不是“基础”以外的第二套语义；它是 MappingPlan 的参数。

### 5.1 目标期预算闭包

- 编译期产生预算义务（B-渐进/B-计数/B-等待）和可判定的 bound；无法判定记 `unknown`。
- MappingPlan 定稿时，用 TargetProfile 的传输成本/同步成本/slot 数计算每条预算，状态写 `proved | unknown | violated | measured`。
- `measured` 只作报告证据，不能解除义务；`unknown` 不渲染为通过。
- 运行期 remap/负载变化只能在预计算预算包络内选择；超包络时报告或按 policy 拒绝。
- 预算证书走决策记录旁路，不写 `.ccr`。

### 5.2 确定性判定

| 情形 | 处置 |
|---|---|
| 两个 activation 可交换 `T1∘T2 = T2∘T1` | 任意调度合法 |
| 不可交换，但图上有显式 T1→T2 顺序 | 按图顺序执行 |
| 不可交换，且没有显式顺序/显式不确定性 | 拒绝编译 |

mapping 只能选择时机和资源，不能补语义、不能把不可交换变成可交换。

## 6. 消息与 channel

源码不新增泛型通道语法。现有 `chan_make` / `chan_send` / `chan_recv` / `chan_close` 仍是 surface。

编译器从 `chan_make` 的 `elemsize` 和所有 `chan_send`/`chan_recv` 使用点推导内部 `MessageLayout`；不写 `Chan<T>` 这样的源码类型。若使用点冲突、句柄逃逸到无法定位、或 layout 无法确定，fail-closed。

```text
ChannelDescriptor {
  channel_id
  element_layout          // 编译期推导；不是源码语法
  capacity                // 静态值或 bound
  producer_consumer       // SPSC / MPSC / SPMC / MPMC；channel 级属性
  space_constraint
  transfer_rules          // 每个边界的 TransferPlan 引用
  fifo_semantics          // SPSC FIFO = 语义序
}

MessageRef {
  region_id
  offset
  size
  layout_id
  space_handle            // 由 MappingPlan 绑定；不是裸指针
  identity_table          // 无生成方法条目的重指表
}
```

- 运行时不再传“8 字节字”；发送/接收传 `MessageRef`。
- CPU mapping 可以用环形缓冲 + 等待 activation；GPU mapping 可以用 device queue/stream；集群可以用网络消息；语义不变。
- 目标不能阻塞时，mapping 可以用缓冲/流式/宿主代理；不能因此改变 FIFO/顺序语义。
- 零容量 channel 是 rendezvous：发送方和接收方在边界会合；`cap=0` 的第一批切片可以不做，但一旦支持，语义按 rendezvous 定义。
- close 后 send 是显式 panic/abort；close 后 recv 先排空缓冲，再返回零值。第一批实现若暂不支持 close/零容量，明确报错，不静默。
- 多产/多消不是默认承诺；需要显式图约束或编译器证明，否则 fail-closed。
- `ordered(src)` 是图标注（`.ccr` 语义标注可承载），不是新增源码语法。

## 7. 与现有设计和代码的关系

| 对象 | 关系 |
|---|---|
| 2026-09-17 并发模型规格 | 语义权威：确定性、五 primitive、预算、证书、不变量 |
| 2026-07-30 GMP 设计 / ADR-0017 | 降级为 CPU mapping 参考，不再是语义模型 |
| `src/stdlib/{sched,chan,goroutine,arena}.cr` | 当前 CPU 后端原型；只作参考，不作为首批 CPU slice 的实现 |
| 2026-09-04 消息边界标签 | SHARE 降级为 mapping 优化；消息子区域/身份重指并入 MessageLayout |
| S-A / S-E / S-D | 义务分级、确定性执法、决策记录与 explain 的既有机制 |
| `.ccr` | 只允许语义标注；transfer/sync 决策与证书不进 |

迁移建议：

- 新 runtime 独立目录；旧 runtime 仅用于 self-host 编译器过渡和 CPU mapping 对照。
- 新底层先以 plan + descriptor ABI 为稳定接口，不先重写 scheduler。
- CPU mapping 与 SIMT mapping 共用同一份 ConcurrencyPlan/TransferPlan。
- self-host 编译器仍由旧编译器构建，新 runtime 不依赖新语法。

## 8. 首批映射切片

### CPU slice

- slot：CPU_FIBER（协作）或 CPU_THREAD（抢占），由 TargetProfile 选一种，不并列；
- memory：HOST；
- channel：环形缓冲 + activation 等待；
- TASK：stackful、可挂起；
- DATA_PARALLEL：线程池/SIMD；
- runtime 对象走 owner region，不走 compiler function arena。

### SIMT slice（GPU-like）

- slot 层级：lane、warp、workgroup 的父子层级；
- memory：DEVICE_GLOBAL / DEVICE_SHARED / LOCAL，host 通过显式传输路径；
- TASK 只映射 `kernelizable` 子集；`needs_stack`/任意阻塞的 TASK 用 host proxy 或 fail-closed；
- DATA_PARALLEL：索引域映射到 lane/workgroup；
- 阻塞 channel：device queue/stream 或宿主代理；不支持时 fail-closed；
- Region scope：INSTANCE 默认私有，GROUP 仅限同一 workgroup。

### 纵向切片（现有 surface）

```core
import sched
import chan

fn worker(req: string) -> int:
    v := chan_recv(req)
    return v + 1

fn main() -> int:
    req := chan_make(8, 1)
    h := go worker(req)
    chan_send(req, 41)
    v := chan_recv(h)
    return v - 42
```

- `req`：main 生产、worker 消费，SPSC；
- `h`：worker 生产、main 消费，SPSC；
- 不依赖调度顺序：main 先发后收，worker 先收后发。

### DATA_PARALLEL 切片

```core
a : [int; 64], mut
for i in 0..64:
    a[i] = i * i
```

编译器证明迭代独立后，将 `for` 映射为 DATA_PARALLEL body；不新增语法。第一批若识别不了，在 plan 中标 `serial_fallback`，不假装并行。

### 验收

- 同一份 ConcurrencyPlan 在 CPU/SIMT 上产生相同的值、效应、顺序和终止类别；
- 目标能力不足时拒绝，不生成静默错误的映射；
- 不新增源码语法；
- runtime 对象不落进 compiler function arena；
- 预算状态可见，`unknown` 不渲染为通过。

## 9. 不变量

本文继承 2026-09-17 规格的全部不变量 I1–I9，不弱化、不替换。包括：确定性、零用户锁、默认 share-nothing、保守 COPY、语义优先、锁不进 IR、fail-closed、共享不能替代 COPY、预算可见。以下仅列增量：

1. 无硬件绑定：语义层没有线程、核心、warp、节点；只有 body/activation/region/edge/plan。
2. 编译期事实不复算：运行时不重新推导布局、owner、生命周期、独立性。
3. 目标事实不进入语义层：具体 space/slot/同步机制只在 TargetProfile/MappingPlan。
4. 运行时对象 owner region：Task/Channel/Message 永不进入函数 arena。
5. plan 旁路：transfer/sync 决策与证书不落 `.ccr`。
6. data-parallel 是一等 body：并发不只等于 `go` 任务；独立索引域可以被编译器映射为并行实例。
7. 预算闭包：MappingPlan 定稿给出每条预算的 `proved/unknown/violated/measured`；运行期 remap 不超出包络。
8. 目标描述版本化：TargetProfile/ConcurrencyPlan 版本不匹配时 fail-closed。

## 10. 未决问题

| # | 问题 | 需要谁决定 |
|---|---|---|
| 1 | DATA_PARALLEL 的识别边界：只靠现有循环 + 独立性证明，还是需要图标注（不新增语法） | 维护者 |
| 2 | GPU 上阻塞 channel 的合法映射范围：device queue / stream / host proxy 的语义与预算 | 维护者 |
| 3 | 跨 memory space 的 MOVE/LOAN 物理回退规则与预算记账 | 维护者 |
| 4 | TargetProfile/ConcurrencyPlan 的文件位置、版本化与二进制格式 | 维护者 |
| 5 | pipeline body 与现有 `flow` / `yield` 的关系 | 维护者 |
| 6 | 首批 SIMT 切片是真实 GPU 后端还是 host 上的 SIMT 模拟器 | 维护者 |
| 7 | 旧 runtime 的退役时点与 self-host 过渡窗口 | 维护者 |
| 8 | 实验 shared mapping 是否保留；保留则等价性/死锁证书如何进入 MappingPlan | 维护者 |
| 9 | 零容量/close 是否进入首批 slice | 维护者 |

## 11. 实施顺序（提案）

0. 本文 spec 定稿；ConcurrencyPlan/TargetProfile schema 定稿；
1. plan artifact、版本字段、runtime entry ABI；
2. `MessageLayout` 推导 + `ChannelDescriptor`（不新增源码类型）；
3. runtime 对象 owner region（Task/Channel/Message 脱离 function arena）；
4. CPU mapping 纵向切片；
5. SIMT mapping 纵向切片（host 模拟优先）；
6. slot 层级/数量/拓扑配置接入；
7. MOVE / COPY / LOAN 的运行时执行器与合法回退；
8. DATA_PARALLEL 识别与映射；
9. 确定性/交换性执法接线（S-E）；
10. 预算/证书/explain（S-D）；
11. 旧 runtime 退役。

本文只定义底层抽象与边界；具体实施由后续 plan 展开。
