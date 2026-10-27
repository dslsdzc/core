# Core 并发模型设计

## 概述

Core 的并发模型是：语义上确定，默认无共享可变状态，数据传输自动优化，共享内存只作为可选的映射策略。

源语言不新增 lock、mutex、atomic 或 ownership 语法。程序只描述逻辑、状态关系和并发关系。编译器负责把它转换为并发依赖、所有权与传输计划，必要时再生成同步计划。

## 设计原则

- 未显式声明的调度差异不得改变可观察语义。
- 默认 share-nothing：跨执行体没有共享可变状态。
- 默认不生成用户数据锁。
- 复制只在无法消除时发生，并且只复制最小的子区域。
- 同步实现和映射选择不能反向定义语义。

## 执行体与内存

执行体拥有独立的 region 和 arena。跨执行体的数据关系由传输计划处理。

默认配置有三条约束：

- 没有共享可变状态。
- 没有用户可见的锁。
- 编译器不为用户数据生成锁。

编译器自身在编译过程中的内部同步属于实现细节，不属于语言语义。

## 数据传输

五种 primitive 固定为 MOVE、LOAN、SPLIT、FILL、COPY。

| primitive | 语义 | 复制量 |
|---|---|---|
| MOVE | 所有权从 A 永久转移到 B | 0 |
| LOAN | 所有权临时转移给 B，之后回到 A；任何时刻只有一个执行体可以访问 | 0 |
| SPLIT | 把区域 R 拆成互不重叠的 R1…Rn，分别归不同执行体所有 | 0 |
| FILL | 接收方预留目标区域，生产方直接构造，接收方随后激活所有权 | 0 |
| COPY | 只复制无法通过前四种方式消除的最小子区域 | 见下 |

COPY 的范围是 CopySet：

```
CopySet = Live_sender ∩ Needed_receiver ∩ NonTransferable
```

完整消息不整体复制，只复制 CopySet。

STREAM 是调度策略，不是第六种所有权模式。DROP、RECOMPUTE、INLINE、BATCH、DMA、RDMA 也不加入 primitive 集合。

### COPY 优化

COPY 的目标不是让 memcpy 更快，而是同时降低三个量：

- CopiedBytes
- VisibleCopyLatency
- BandwidthPressure

消除顺序固定为：

1. MOVE 消除
2. SPLIT 消除
3. FILL 和目标分配
4. 死子区域消除
5. 部分 COPY
6. 分块 COPY
7. 异步 COPY
8. 消费方驱动的预取或复制
9. 同步全量物化，作为最差回退

例：1 GiB 消息可以降为 700 MiB MOVE、200 MiB 接收方不需要的区域、90 MiB FILL、9.99 MiB SPLIT、4 KiB COPY。逻辑大小仍是 1 GiB，实际复制量是 4 KiB。

COPY 可以流水化。编译器按接收方未来的访问顺序复制子区域，在接收方使用当前块时复制下一块。Copy Scheduler 负责块大小、复制顺序、复制与计算重叠、预取距离、NUMA 放置和 DMA/CPU 选择。这些都属于映射层，不进入语言语义。

## 确定性

对两个并行 transition T1 和 T2，编译器检查四项：

- 内存是否独立。
- 状态是否独立。
- 是否可交换。
- 可观察顺序是否无关。

处理规则：

| 情形 | 处理 |
|---|---|
| T1∘T2 = T2∘T1 | 任意调度合法 |
| 不可交换，但图上有 T1 到 T2 的顺序 | 按图上的顺序执行 |
| 不可交换，且没有显式声明不确定性 | 拒绝编译，不能让调度器决定结果 |

`go` 声明的是“存在并发执行体”，不声明执行顺序。通道 FIFO 在单生产者单消费者面上是语义顺序；多生产者多消费者面没有跨发送者的全局顺序，除非显式使用 `ordered(src)` 标注。未标注但顺序可观察的并发，拒绝编译。

## 共享内存映射（实验）

默认关闭：

```toml
[concurrency]
shared_mapping = false
```

实验模式：

```toml
[experimental.concurrency]
shared_mapping = true
```

开启后，编译器可以对原本必须 COPY 的义务比较 Copy 成本和 Shared+Sync 成本。如果能证明共享表示与原语义等价，就允许共享区域加自动生成的同步。同步机制可以是 atomic、mutex、rwlock、spinlock、transaction 或串行化所有者，由后端选择。源代码不变。

硬规则：如果语义要求两个长期独立、分别可变的版本，shared+lock 不能冒充 COPY，必须真的产生两个状态。

## 同步规划

同步规划的输入：

- ReadSet
- WriteSet
- Region
- Provenance
- Lifetime
- State edge
- Commutativity
- Target capability
- Contention estimate

输出是以下之一：

- NONE
- ATOMIC
- GUARD
- TRANSACTION
- SERIALIZE

优先级从强到弱：

1. 证明独立
2. 所有权变换
3. atomic
4. 细粒度同步
5. transaction
6. 串行化

高层只产生约束，例如“T1 和 T2 不得在 R 上重叠”。IR 中没有 `LOCK` 指令。映射层根据目标选择具体机制：x86 可以用 atomic、mutex、TSX、futex，RISC-V 可以用 AMO、LR-SC、lock，其他目标可以用 capability 或调度器机制。

## 死锁

如果决定生成锁，必须同时生成锁依赖图并证明无环。

如果发现环，不能继续生成该映射。依次尝试：

1. 合并锁
2. 改变粒度
3. 改用 transaction
4. 串行化
5. 回退到 COPY

都不行时，拒绝编译。不能把潜在死锁留给用户。

## 可观察语义与预算

可观察语义包括五项：

1. 值输出
2. 效应：STORE、通道 send、extern 调用、YIELD
3. 控制去向
4. 终止类别：正常终止、显式 panic 或 abort、不终止
5. 预算向量

绝对墙钟时间和逐微秒延迟不进入语义。时间只以预算条目出现：

| 形态 | 内容 | 判定方式 |
|---|---|---|
| B-渐进 | 可见延迟相对 payload 的量级 | 由传输计划的形状推出 |
| B-计数 | CopiedBytes、copy 次数、sync 等待次数、内存上界 | 由计划每级产物计数 |
| B-等待 | 最长同步等待上界 | 由同步计划档位给出 |

每条预算必须有来源：默认规则、程序内显式标注或 policy。预算必须在编译期可判。无法判定时记为 `unknown`，不能当成通过。预算不满足或未证明时，必须在报告中可见；高安全档可以拒绝编译。

默认规则：

- 可见延迟不随 payload 线性增长。
- 同步等待为 0。
- CopiedBytes 由计划给出，不设额外常数上界。

`explain` 输出的 `modeled` 数值是对语义的主张，不是描述性输出。它必须带状态：`proved`、`unknown`、`violated` 或 `measured`。测量只能作为报告证据，不能代替证明。

## 解释输出

`corec explain concurrency foo.cr` 默认输出：

- 通道逻辑 payload 大小
- 传输计划：MOVE、SPLIT、FILL、COPY 各多少
- 复制调度：同步块、异步块大小
- 可见复制延迟，标注为 modeled
- 共享映射状态

实验模式再输出：

- 选中的同步机制
- 避免的复制量
- 语义等价证明状态
- 死锁自由证明状态

## 不变量

1. 确定性：任何未显式声明的调度差异不改变值、效应、控制去向、终止类别和预算向量。
2. 源语言没有 lock、mutex、atomic 或 ownership 语法。
3. 默认 share-nothing：默认映射下没有跨执行体的共享可变状态。
4. 保守 COPY：全 COPY 永远语义有效；分析不精确只损失性能，不产生错误拒绝。
5. 语义优先：映射选择翻转时，非预算分量不变，已声明的预算不能由满足变成不满足。
6. 锁不进 IR：IR 中没有锁指令。
7. fail-closed：无法证明无死锁时，不启用该映射，或拒绝编译。
8. 共享不能冒充 COPY：两个独立可变版本必须产生两个真实状态。
9. 预算可见：`violated` 和 `unknown` 必须出现在报告中，不能渲染成通过。

## 实施顺序

先完成三项地基：

| 序 | 项 | 内容 |
|---|---|---|
| 0a | 多 M 启用 | `sched_spawn_workers` 接线，多 M 下的 runq 和恢复执行面 |
| 0b | 消息表示 | 跨执行体消息使用子区域或句柄加值移动，不再只传 8 字节字 |
| 0c | 并发运行时验证 | 多 M 下 wait list 的无锁正确性 |

0b 和 0a 可以并行，0c 覆盖两者。

然后按原顺序实施：

| # | 步骤 |
|---|---|
| 1 | Transfer Analysis：MOVE、SPLIT、COPY，CopySet 精确到子区域 |
| 2 | FILL 和目标放置 |
| 3 | LOAN |
| 4 | Copy Scheduler |
| 5 | Copy Cost Model：CopiedBytes、VisibleLatency、Bandwidth |
| 6 | 实验共享映射，先支持编译器生成 mutex/rwlock |
| 7 | 自动同步规划：atomic、transaction、串行化 |
| 8 | 交换性与确定性证明 |
| 9 | 死锁证书 |
| 10 | 自适应映射：profile-guided 选择 COPY/shared、mutex/rwlock、atomic/transaction、块大小 |

步 1 之前还需要两项输入：标签对齐表，以及指针分析表示升级。它们不是新步骤，是步 1 的前置。

## 不包含

- 源语言中的 lock、mutex、atomic、ownership 语法
- 用户可见锁
- IR 中的锁指令
- STREAM 作为所有权 primitive
- SHARE 作为第六种 primitive；SHARE 降级为映射层优化
- 把绝对墙钟时间或逐微秒延迟写进语义
- 用运行时测量代替语义证明
- 把潜在死锁留给用户处理
- 在单 M 上为 shared mapping 做等价性证明或死锁证书

## 未决问题

| # | 问题 | 需要谁决定 |
|---|---|---|
| 1 | SPSC 是文档约定，还是要在语法、类型或诊断中强制 | 维护者 |
| 2 | FILL 的预留区域如何与 arena_reset 生命周期对齐 | 维护者 |
| 3 | LOAN 与 borrow checker 的关系，借出期间的访问禁令是否复用现有规则 | 维护者 |
| 4 | `explain concurrency` 的冷态和热态输出如何保持一致，决策记录如何随缓存条目存取 | 维护者 |
| 5 | `[concurrency]` 和 `[experimental.concurrency]` 的 TOML 段解析放在哪一组 | 维护者 |
| 6 | 通道 FIFO 提升为语义序后，现有 6 个 go/chan 测试如何更新基准值 | 维护者 |
| 7 | 多 M 启用后，wait list 的无锁假设如何验证 | 维护者 |

## 参考

设计所依据的仓库事实、逐条决定记录、术语来源和未核实项见 [2026-09-17-concurrency-model-evidence.md](../implementation/2026-09-17-concurrency-model-evidence.md)。
