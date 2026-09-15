# ADR-0017: 并发模型 = Go 风格 GMP 简化(G 并入 M)

- 日期:2026-07-30(设计定稿)/ 2026-07-31(go 端到端)
- 状态:accepted(已实现——单 M 端到端;多 M 推进中)
- 决策者:DslsDZC

## 背景
早期执行模型文档设想"有 OS 用 OS 线程 / 无 OS 用时间片抢占"。实现 go 并发时发现:OS 线程模型把并发绑定平台线程与内核调度,无 OS 抢占在用户态成本高且与数据流图协作模型不匹配。

## 决策
- 采用 **Go runtime 同构的 GMP 简化模型**:G = goroutine(fiber,16KB 栈,独立 arena)、M = machine、**P 不分离合并到 M**;无 GOMAXPROCS,M 数 = CPU 核
- G 状态机(_Gidle/_Grunnable/_Grunning/_Gwaiting/_Gdead);local run queue + global 偷取;切换 = 用户态 fiber_switch(协作)
- channel 通信(环形缓冲 + send_wait/recv_wait 链表,值拷贝语义);go 返回 result_ch
- 早期"OS 线程/抢占式"设计废弃(文档层,2026-09 全量重写时清除)

## 后果
- 正面:协作调度无内核介入;每 G arena 生命周期对齐(goroutine 栈 + G 结构同生共死);与图模型一致(yield/recv = 图节点操作)
- 负面:多 M 并行、global queue、阻塞链完整化推进中;并发执行器语义(IR_SPAWN eager 近似)与调度模型的差距持续注记(ir-op-semantics §2.7)

## 关联
- 文档:docs/maintainer/design/execution-model.md §三(GMP);specs/2026-07-30-concurrency-design.md;stdlib sched.cr/goroutine.cr/chan.cr
- 相关 ADR:ADR-0007(每 G 独立区域)
