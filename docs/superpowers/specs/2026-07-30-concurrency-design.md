# 并发实现设计

## 概述

在 Core 中实现 M:N 协程并发模型。`go f()` 启动新 goroutine，goroutine 之间通过 channel 传值，不共享内存。每个 goroutine 拥有独立 arena，值在 channel 边界拷贝。

## 核心原则

- **不共享内存**：goroutine 之间不共享变量。所有通信通过 channel 传值。
- **「像图一样」**：每个 goroutine 是图上的一个节点，channel 是边。
- **Arena 隔离**：每个 goroutine 有自己的 arena。`go f()` 时创建新 arena。
- **Cooperative 调度**：只在 channel `send`/`recv` 和显式 `yield` 时切换。

## GMP 模型（简化）

```
G (goroutine) — fiber: 栈 + arena_id + 状态
M (machine)   — OS 线程: 当前 G + local run queue
P — 不分离，合并到 M

没有全局 GOMAXPROCS。M 数量 = CPU 核数（运行时配置）。
```

### G 状态

| 状态 | 含义 |
|------|------|
| `_Gidle` | 刚分配，未启动 |
| `_Grunnable` | 在运行队列中等待 |
| `_Grunning` | 正在某个 M 上执行 |
| `_Gwaiting` | 阻塞在 channel send/recv |
| `_Gdead` | 已退出，等待回收 |

### G 结构

```core
struct Goroutine:
    id: int,
    status: int,
    stack_ptr: int,    // 栈指针（固定 16KB 栈）
    stack_lo: int,     // 栈底
    arena_id: int,     // 绑定的 arena
    chan_wait: int,    // 阻塞在此 channel 上（_Gwaiting 时）
    next: int,         // 链表（run queue / wait queue）
```

### M 结构

```core
struct Machine:
    id: int,
    cur_g: int,        // 当前运行的 G
    runq_head: int,    // local run queue 头
    runq_tail: int,    // local run queue 尾
    g0: int,           // 系统 G（M 本身的栈）
```

## Channel

### `chan T` 语法

```core
ch := make(chan int, 10)  // 缓冲 channel，容量 10
send(ch, 42)              // 发送
val := recv(ch)            // 接收
close(ch)                 // 关闭
```

### channel 结构

```core
struct Channel:
    buf: string,          // 环形缓冲区
    cap: int,             // 容量
    len: int,             // 当前元素数
    head: int,            // 读指针
    elemsize: int,        // 元素大小
    send_wait: int,       // 等待发送的 G 链表头
    recv_wait: int,       // 等待接收的 G 链表头
    closed: int,          // 是否已关闭
```

### Channel 操作

**`send(ch, val)`**：
```
1. 如果 ch 已关闭 → panic
2. 如果有等待接收的 G → 直接拷贝给接收者，唤醒 G
3. 如果 buf 未满 → 拷贝到缓冲区
4. 如果 buf 已满 → 当前 G 阻塞，加入 send_wait 链表
```

**`recv(ch)`**：
```
1. 如果有等待发送的 G → 从发送者直接接收，唤醒发送者
2. 如果 buf 非空 → 从缓冲区读取
3. 如果 ch 已关闭且 buf 空 → 返回零值
4. buf 空且未关闭 → 当前 G 阻塞，加入 recv_wait 链表
```

**值拷贝语义**：channel 边界永远拷贝值，不传引用。发送方的值在发送后不变。

## `go f()` 语义

```core
go f(args);
```

1. 分配 G 结构 + 16KB 栈
2. 复制参数到新 arena
3. 创建新 arena（`arena_new()`）
4. 设置 G 状态为 `_Grunnable`
5. 投递到 M 的 local run queue
6. 返回（不等待 f 完成）

**返回值**：`go f()` 返回一个 channel，用于接收 `f` 的返回值：

```core
ch := go f(args)
result := recv(ch)  // 等待 f 完成并获取结果
```

## 调度器

### 调度循环

```
schedule():
  1. 从 local run queue 取一个 G
  2. 如果 local 为空，从 global run queue 偷
  3. 如果 global 也为空，进入 idle（OS 线程休眠）
  4. 恢复 G 的执行（load 栈指针 + jump）
```

### 切换点

| 操作 | 行为 |
|------|------|
| `send(ch, val)` | 如果 chan 满 → G 阻塞，schedule() |
| `val = recv(ch)` | 如果 chan 空 → G 阻塞，schedule() |
| `yield()` | 主动让出 CPU，G 回到 _Grunnable，schedule() |
| `go f()` | 新 G 入队，当前 G 继续执行 |

### Fiber 切换

```asm
; fiber_switch(from_sp, to_sp):
; 保存当前寄存器到 from_sp
; 从 to_sp 恢复寄存器
; 返回（在新栈上）
push rbx, r12-r15, rbp
push rdi (from_sp)  ; 存到 g.stack_ptr
mov [from_sp], rsp  ; 保存 RSP

mov rsp, [to_sp]    ; 恢复 RSP
pop rdi             ; 目标 G 的 stack_ptr
pop rbp, r15-r12, rbx
ret
```

## IR 指令

```core
IR_SPAWN : int = 27  // 已有: dest=chan, s1=fn_ni, s2=first_arg, s3=arg_count
IR_YIELD : int = 28  // 已有: s1=value_var
```

上列编号保持不变。`IR_SPAWN` 在后端编译为 fiber 创建 + 队列投递。`IR_YIELD` 编译为 fiber 切换。

## 实现清单

| # | 文件 | 改动 |
|---|------|------|
| 1 | `src/runtime/rt.s` | `fiber_switch` asm + `clone` syscall 包装 |
| 2 | `src/stdlib/sched.cr` | 调度器：G/M 管理、run queue、schedule() |
| 3 | `src/stdlib/chan.cr` | channel：send/recv/close、wait queue |
| 4 | `src/stdlib/goroutine.cr` | go：G 创建、arena 绑定、参数复制 |
| 5 | `src/compiler/ir_gen.cr` | `go f()` 完整 IR gen |
| 6 | `src/arch/linux/ld/instr.cr` | IR_SPAWN/IR_YIELD 编码 |
| 7 | `src/arch/linux/ld/sizes.cr` | 大小估算 |
| 8 | `tests/suite/chan_test.cr` | channel 测试 |
| 9 | `tests/suite/go_test.cr` | go + fiber + schedule 测试 |
