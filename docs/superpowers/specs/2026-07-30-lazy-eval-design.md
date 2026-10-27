# 惰性求值实现设计


> 术语注记（2026-08-15）：本规格为历史设计记录，其中「数据流图」（及「RVSDG 式」）为当时术语；该结构后定名为 HDFG（Holographic Dataflow Graph，全息数据流图），术语演进见 `docs/project-book.md`。正文保留历史原样。

状态：调用级子集已实现（2026-08-08）；控制流级方向在 2026-08-09 定为编译期指令下沉路线（不做运行时 thunk），详见 `docs/lazy.md` 与 `TODO.md`「控制流自动惰性」。本 spec 的运行时 thunk 设计（flag + 9 字节结构 + asm 草案）已被取代，`IR_LAZY_THUNK`/`IR_LAZY_FORCE` 编号保留。

## 概述

在 Core 编译器中实现自动惰性求值。编译器分析数据流图，对纯函数且只用在一个分支中的节点自动延迟求值。不需要 `lazy` 关键字。

## 核心原则

- 无关键字：编译器自动推导，用户不需要标注。
- 图本身支持惰性：节点没有下游消费者需要时不执行。当前 IR 采用 eager 策略，这是实现选择，不是图的限制。
- 惰性不改变语义：这是纯编译器优化，输出一致。
- 副作用标记决定策略：有副作用的调用总是 eager。

## 副作用分析

### 纯函数判定

一个函数是纯函数（可惰性）当且仅当：

| 条件 | 说明 |
|------|------|
| 无 IO 操作 | 不调用 print/read_file/write_file |
| 无 FFI 调用 | 不调用 extern fn |
| 无全局变量写入 | 不修改 g_ 开头的变量 |
| 无 volatile 内存操作 | 不是 unsafe 原始指针写入 |

### 副作用标记源

| 来源 | 策略 |
|------|------|
| `fn f() -> int { ... }`（纯计算） | 可惰性 |
| `fn f() { print(...); }` | 不可惰性 |
| `extern fn getchar() -> int;` | 不可惰性 |
| `unsafe { *p = val; }` | 不可惰性 |
| `syscall3(...)` | 不可惰性 |
| `alloc()` | 可惰性（纯内存分配，无外部副作用） |

### 实现方式

在 checker 中为每个函数标记一个纯函数标志位：

```core
// checker.cr: 函数注册时分析函数体
fn is_pure_func(func_node: int) -> int:
    // 扫描函数体
    // 如果有 IO/FFI/unsafe 调用，返回 0
    // 如果全为纯计算，返回 1
```

存储在 `g_funcs` 的新字段中：

```core
OFF_FN_ISPURE : int = 32  // 新字段，1=纯函数
ESZ_FN 增长为 40
```

或者采用更简单的方案：在 IR gen 时做惰性分析，不修改 `g_funcs`。

## 使用计数分析

在 IR gen 阶段（或作为单独的一遍），统计每个 IR 变量的使用次数：

```core
// 对每个 IR 变量 v:
//   v 被多少条边引用？
//   只在一个分支里使用（if 的 then 分支）：可惰性
//   在循环体内每次都用到：eager
//   在循环体内条件性用到：惰性
```

实现：在 dataflow 图上遍历边，对每个 producer 节点统计 consumer 数量。

## IR 表示

### 新增 IR 操作

```core
IR_LAZY_THUNK  : int = 46  // dest=thunk_var, s1=expr_var，包装为惰性 thunk
IR_LAZY_FORCE  : int = 47  // dest=val_var, s1=thunk_var，强制求值
```

### Thunk 表示

`IR_LAZY_THUNK` 在 IR 层面是一个 `(computed, value)` 对：

```core
// thunk = { computed: bool, value: 8bytes }
// 首次 IR_LAZY_FORCE 时检查 computed
// 如果已计算，直接返回 value
// 如果未计算，执行表达式，保存 value 和 computed=true
```

### IR gen

```core
// 原本: 
x := expensive();       // IR_CONST/IR_CALL x, ...
y := cond ? x : 0;      // IR_BRANCH, IR_PHI y, ...

// 惰性优化后:
x := expensive();       // IR_CALL x, ...
t := IR_LAZY_THUNK t, x // 包装为 thunk
// 在分支中:
v := IR_LAZY_FORCE v, t  // 如果执行到该分支则求值
```

## 后端（ELF）

`IR_LAZY_THUNK`：分配 9 字节的 thunk 结构（1 byte flag + 8 byte value）。flag 初始为 0。

`IR_LAZY_FORCE`：检查 flag，为 0 则执行表达式并设置 flag=1。flag 为 1 时直接返回 value。

```asm
; IR_LAZY_FORCE:
mov al, [thunk_ptr]     ; 检查 computed flag
test al, al
jne .computed
; 未计算：执行表达式
call expr_func
mov [thunk_ptr + 1], r10  ; 保存 value
mov byte [thunk_ptr], 1    ; 设置 computed = 1
jmp .done
.computed:
mov r10, [thunk_ptr + 1]  ; 直接读取已缓存的值
.done:
```

## 实现清单

| # | 文件 | 改动 |
|---|------|------|
| 1 | `src/compiler/ast.cr` | IR_LAZY_THUNK(46), IR_LAZY_FORCE(47) |
| 2 | `src/compiler/checker.cr` | 纯函数标记 |
| 3 | `src/compiler/dataflow.cr` | 使用计数分析 |
| 4 | `src/compiler/ir_gen.cr` | 惰性 thunk 发射 + 适用判定 |
| 5 | `src/compiler/opt.cr` | 跳过 |
| 6 | `src/compiler/ccr_io.cr` | 序列化 |
| 7 | `src/arch/linux/ld/instr.cr` | LAZY_THUNK/FORCE 编码 |
| 8 | `src/arch/linux/ld/sizes.cr` | 大小估算 |
| 9 | `tests/suite/lazy_test.cr` | 测试 |
