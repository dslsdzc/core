# ADR-0017: 并发模型 = Go 风格 GMP 简化（G 并入 M）

- 日期：2026-07-30（设计定稿）/ 2026-07-31（go 端到端）
- 状态：accepted（已实现：单 M 端到端；多 M 推进中）
- 决策者：DslsDZC

## 背景

早期执行模型文档设想“有 OS 时用 OS 线程，无 OS 时用时间片抢占”。实现 go 并发时发现：OS 线程模型把并发绑定到平台线程和内核调度，无 OS 时的用户态抢占成本高，而且与数据流图的协作模型不匹配。

## 决策

- 采用与 Go runtime 同构的 GMP 简化模型：G = `goroutine`（`fiber`，16KB 栈，独立 arena），M = machine，P 不分离，合并到 M；没有 `GOMAXPROCS`，M 的数量等于 CPU 核数。栈尺寸常量是 `src/stdlib/goroutine.cr` 的 `G_STACK_SIZE`。
- G 状态机（`_Gidle`/`_Grunnable`/`_Grunning`/`_Gwaiting`/`_Gdead`）；本地 run queue 加全局队列偷取；切换是用户态 `fiber_switch`（协作式）。
- channel 通信（环形缓冲 + `send_wait`/`recv_wait` 队列，值拷贝语义）；go 返回 `result_ch`。

## 后果

- 正面：协作调度没有内核介入；每个 G 的 arena 生命周期一致（`goroutine` 栈和 G 结构同时创建、同时释放）；与图模型一致（yield/recv = 图节点操作）。
- 负面：多 M 并行、global queue、阻塞状态完整化仍在推进；并发执行器语义（`IR_SPAWN` 的 eager 近似）与调度模型的差距会持续记录（`ir-op-semantics` 第 2.7 节）。

## 关联

- 文档：docs/maintainer/design/execution-model.md 第三节（GMP）；specs/2026-07-30-concurrency-design.md；stdlib sched.cr/goroutine.cr/chan.cr
- 相关 ADR：ADR-0007（每 G 独立区域）
