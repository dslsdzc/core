# Core 并发原语

> 定位:受众 = 维护者/贡献者;状态 = **active(已实现)**——go/chan 端到端可用(2026-07-31);细节见 src/stdlib/goroutine.cr、chan.cr、src/scheduler/;本设计文档的 flow/yield/await 扩展为演进方向

## 设计原则

- **只有一张图。** go/flow/yield/await/walk 都是图上的节点和边，不是额外的运行时概念。
- **有 OS 用 OS 线程，无 OS 抢占式时间片。** 没有 actor、没有 CSP、没有 async/await 关键字。

## 原语

### flow

声明一个可激活的命名子图。

```core
flow counter() -> int {
    i := 0;
    loop {
        yield i;
        i = i + 1;
        if i >= 5 { break; }
    }
}
```

`flow` 在图上创建一个子图模板。每次 `go` 将子图实例化一次。

### go

激活一个 flow 实例，产生一个新的图节点，与调用者并行。

```core
c := go counter();
// 图上：counter 子图被实例化，新节点加入图
// 有 OS：新线程
// 无 OS：新节点加入就绪队列
```

`go` 返回一个指向 flow 实例的句柄。调用者通过 `await` 获取 flow 的输出。

### yield

暂停当前 flow，输出一个值。

```core
flow numbers() {
    yield 1;   // 暂停，输出 1
    yield 2;   // 恢复，暂停，输出 2
    yield 3;   // 恢复，暂停，输出 3
}
```

`yield` 在图上是一个暂停点：当前节点的执行暂停，值沿输出边传递给消费者。消费者通过 `await` 接收。

多个 `yield` 的 flow 类似生成器——每次 `yield` 后可以继续执行到下一个 `yield`。

### await

等待一个 flow 实例的输出。

```core
c := go counter();
v := await c;       // 等待 counter 输出一个值
// v = 0
v = await c;        // 等待 counter 输出下一个值
// v = 1
```

`await` 在图上是一个同步点：当前节点等待目标子图的输出边就绪。

### walk

在节点间移动执行，状态在移动过程中保留。

```core
walker process(data: [int]) {
    result := compute(data);       // 当前节点上执行
    step @("node2");               // 移动到 node2，状态保留
    save(result);                  // 在 node2 上存储
    step @("node3");               // 移动到 node3
    report(result);                // 在 node3 上输出
}
```

`walk` 激活一个 walker 实例。walker 不是在新节点上启动新执行——而是将当前执行上下文（栈、局部变量）序列化后传输到目标节点继续执行。

`step` 暂停当前 walker，将状态传输到目标节点，在目标节点上恢复执行。

走完的 walker 和 flow 一样可以被 `await`。

## 图上的表示

```
go counter() → 新节点，子图实例化，独立上下文

yield val    → 暂停当前节点，值沿输出边传递
               接收边就绪 → 节点恢复

await c      → 等待目标节点的输出边有值
               边就绪 → 节点继续

walk fn()    → 创建 walker 实例
step @("n")  → 序列化当前上下文，传输到目标节点，恢复
```

```
                         ┌──────┐
        go counter() ───→│  ctx │──→ yield 1 ───→ await
                         │  ctx │──→ yield 2 ───→ await
                         │  ctx │──→ yield 3 ───→ await
                         └──────┘

                         ┌──────┐         ┌──────┐         ┌──────┐
        walk process() ─→│node1  │──step──→│node2  │──step──→│node3  │
                         │ state │         │ state │         │ state │
                         └──────┘         └──────┘         └──────┘
```

## 与其它模型的对应

| Core | OS 线程 | Go goroutine | Erlang |
|------|---------|-------------|--------|
| `flow` | 函数 | `func` | `spawn` |
| `go` | `pthread_create` | `go` | `spawn` |
| `yield` | — | — | — |
| `await` | `pthread_join` | `wg.Wait` | `receive` |
| `walk` | 线程迁移（已废弃） | — | 无直接对应 |
| `step` | — | — | — |

## 当前状态

**更新（2026-07-31）**：`go f(args)` 端到端可用——`sched_go(@addr(f), arg)` →
g_new 存 saved_fn/saved_arg → ELF 后端内联发射 fiber_init/fiber_switch/goroutine_entry_wrapper →
wrapper 调用 saved_fn(saved_arg) → 结果经 result_ch 回传。主线程注册为 G 0，
可经 channel 阻塞/唤醒；sched_yield 不再重排 Gwaiting。
`walker` / `step` 尚未实现；多 M worker 线程的完整验证待补（见 `TODO.md` 预存 bug 第 2 条）。
