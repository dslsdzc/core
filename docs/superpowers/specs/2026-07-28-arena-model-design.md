# Arena 内存模型实现设计

## 概述

Core 语言基于 Arena 的内存管理方案。本设计将现有的 1GB 全局 bump allocator 升级为多 Arena 池，每个子图（函数 / `loop` / `for` / `unsafe`）关联独立 Arena，分配自动从当前 Arena 的 bump pointer 分配，子图退出时整体重置游标。

### 核心原则

- **尽量少的汇编**：生命周期管理在 Core 中（`arena.cr`），只有 bump 分配路径本身在底层
- **零 API 冲击**：用户代码继续使用 `alloc()` — 无需学习新分配 API
- **透明集成**：编译器自动在子图边界插入 Arena 生命周期指令
- **向后兼容**：`g_current_arena = -1` 时完全回到现有全局 bump allocator 行为

## 架构

### 运行时数据布局（BSS）

```
BSS 段布局（新增字段用 + 标记）：
+ g_current_arena      [8B]  ← 当前 arena ID (-1 = 无 arena，使用全局 heap_ptr)
+ g_arena_pool_data    [8B]  ← arena pool 数据区基址（由 arena_init 填充）
+ g_arena_free_list    [8B]  ← 空闲 arena 链表表头 (-1 = 空)
  heap_ptr             [8B]  ← 全局 bump pointer（fallback，现有字段）
  heap_start                  ← 堆数据起始（1GB，全局 bump + 从中分配 Arena Pool）
  heap_end
```

> **设计决策**：arena metadata 数组（`cursors`、`sizes`、`parents`）作为 Core 全局变量动态分配（`g_arena_cursors = alloc(N * 8)`），不使用 BSS 静态数组。原因是固定上限（`MAX_ARENAS`）会在深层嵌套或大量并发子图时导致运行时错误——metadata 需要像 `g_df_nodes` 一样可扩容。性能代价：`emit_alloc_body` 多一次间接访存（加载指针值），在分配热路径上可接受。

### Arena slot 模型

每个 arena slot 由三个平行数组追踪：

| 数组 | 类型 | 含义 |
|------|------|------|
| `g_arena_cursors` | `string` (int[] 指针) | 当前 bump 偏移量（从 0 开始，按 8 字节对齐推进） |
| `g_arena_sizes` | `string` (int[] 指针) | 该 arena 的 chunk 上限（固定值 `arena_max_size`） |
| `g_arena_parents` | `string` (int[] 指针) | 创建此 arena 时的 `g_current_arena`（嵌套恢复用） |

初始化：`g_arena_cursors = alloc(MAX_ARENAS * 8)`（在 `arena_init` 中，此时 `g_current_arena = -1`，走全局 bump）。

### 分配路径

```
alloc(size):
  1.  if g_current_arena < 0:
          → 使用现有全局 bump（heap_ptr）
  2.  else:
          ai = g_current_arena
          aligned = (size + header_size + 7) & ~7
          cursor = arena_cursors[ai]
          if cursor + aligned > arena_sizes[ai]:
              return 0  // OOM
          arena_cursors[ai] += aligned
          return g_arena_pool_data + ai * arena_max_size + cursor
```

`g_arena_pool_data` 是 BSS 全局变量，存储由 `arena_init` 中 `alloc(pool_size)` 返回的指针值。在 `emit_alloc_body` 中通过 `lea r11, [rip + g_arena_pool_data]; mov r11, [r11]` 加载。

### 生命周期集成（子图 ↔ Arena）

```
子图入口 → sg_push(SG_*) → arena_new() → 设置 g_current_arena
子图内部 → alloc() 系列 → 自动从当前 arena 分配
子图出口 → arena_reset(ai) → cursor=0，g_current_arena=parent → sg_pop()
```

嵌套示例：
```
fn main():
    // arena_new() → ai=0, g_current_arena=0
    x := alloc(32)            // 从 arena 0 分配
    loop:
        // arena_new() → ai=1, g_current_arena=1, parent=0
        y := alloc(64)        // 从 arena 1 分配
    // arena_reset(1) → g_current_arena=0, cursor[1]=0
    z := alloc(16)            // 从 arena 0 分配
// arena_reset(0) → g_current_arena=-1, cursor[0]=0
```

## 组件设计

### 1. Stdlib（`src/stdlib/arena.cr`）— Core 代码

```core
// === 全局变量 ===
g_current_arena : int, mut = -1

// Arena metadata arrays (allocated in arena_init, accessed by emit_alloc_body)
g_arena_cursors : string, mut     // int[] — element = cursor offset
g_arena_sizes   : string, mut     // int[] — element = chunk max size
g_arena_parents : string, mut     // int[] — element = parent arena ID

g_arena_pool_data : string, mut   // pool base pointer (from alloc)
g_arena_max_size : int, mut
g_arena_free_list : int, mut = -1
g_arena_count : int, mut = 0
g_arena_cap   : int, mut = 0    // metadata 数组容量

// === API ===
fn arena_init(pool_size: int, arena_size: int):
    // 从全局 bump heap 分配 pool 数据区。
    // 此时 g_current_arena = -1，alloc() 走全局 bump 路径
    g_arena_pool_data = alloc(pool_size)
    g_arena_max_size = arena_size
    g_arena_free_list = -1
    g_arena_count = 0
    g_arena_cap = 0

fn arena_new() -> int:
    // 从 free list 取，或创建新 slot
    // 设置 parent = g_current_arena
    // 设置 g_current_arena = new_id
    // cursor = 0
    // 返回 new_id

fn arena_reset(ai: int):
    // cursor = 0
    // g_current_arena = parent
    // 推入 free list

fn arena_avail(ai: int) -> int:
    // 返回剩余可用字节数
```

`arena_alloc` 不需要作为独立的 Core 函数——现有 `alloc()` 已经 arena-aware。

### 2. 运行时（`src/runtime/rt.s`）— BSS 扩展

BSS 段新增 `emit_alloc_body` 热路径直接访问的字段：

```asm
.section .bss
.balign 4096
g_current_arena: .space 8
g_arena_pool_data: .space 8
g_arena_free_list: .space 8
heap_ptr: .space 8            ; 现有，fallback
heap_start: .space 1024 * 1024 * 1024
heap_end:
```

> 元数据数组是 Core 全局变量（`alloc()` 动态分配），不在 BSS 中。

### 3. ELF 后端 — `emit_alloc_body` 修改（`src/arch/linux/ld/elf.cr`）

现有 `emit_alloc_body`（~84 字节）是内联 bump allocator。修改为双路径：

```
路径 A (arena 激活):  g_current_arena ≥ 0
  1. lea r11, [rip + g_arena_pool_data]; mov r11, [r11]  → r11 = pool base
  2. 加载 arena_cursors[ai] → rcx = old_cursor
  3. 对齐 size：rdi = (rdi + 15) & -8
  4. 检查 OOM：rcx + rdi > arena_sizes[ai]? → ja .Loom
  5. 更新 arena_cursors[ai] += rdi
  6. 返回 r11 + ai*arena_max_size + old_cursor

路径 B (无 arena):  g_current_arena < 0
  1. 现有逻辑：bump heap_ptr
```

函数签名不变：`rdi = size`，`rax = 返回指针`。调用方无需感知路径差异。

### 4. 编译器 — 新增 IR 指令（`src/compiler/ast.cr`）

```core
IR_ARENA_NEW   : int = 30   // arena_new dest, src1(size_estimate)
IR_ARENA_RESET : int = 31   // arena_reset src1
```

`IR_ARENA_NEW` 的 `src1` 是编译器预估的 arena 大小（编译期常量或 0=默认）。后端的 `arena_new_impl` 用此值选取合适 chunk 大小或触发链式扩容。

#### IR Gen 插桩点（`src/compiler/ir_gen.cr`）

| 子图类型 | arena_new 位置 | arena_reset 位置 |
|----------|---------------|-----------------|
| SG_FUNC | `ir_gen_func()` 开头 | `IR_RETURN` emit 之前 |
| SG_LOOP | `sg_push(SG_LOOP)` 之前 | `sg_pop()` 之后 |
| SG_FOR | `sg_push(SG_FOR)` 之前 | `sg_pop()` 之后 |
| SG_UNSAFE | `sg_push(SG_UNSAFE)` 之前 | `sg_pop()` 之后 |
| SG_FLOW | `sg_push(SG_FLOW)` 之前（编译器插桩点预留） | `sg_pop()` 之后 |
| SG_GO | `sg_push(SG_GO)` 之前（编译器插桩点预留） | `sg_pop()` 之后 |

> `SG_FLOW` 和 `SG_GO` 的 arena 插桩点已预留。当前编译器未实现 `go`/`flow` 原语，但 arena 层已准备好——`sg_push(SG_FLOW)` 时自动 `arena_new()` 创建独立 arena，`sg_pop()` 时自动 `arena_reset()` 回收。`flow`/`go` 的结果跨 arena 拷贝机制在对应原语实现时加入即可。

每次 `arena_new` 创建一个新的 IR 变量 `_arena_N` 存储 arena ID。

#### ELF 编码（`src/arch/linux/ld/instr.cr`）

`IR_ARENA_NEW` → emit 调用 `arena_new`（通过 `emit_alloc_body` 附近新增的辅助函数或已有的外部队列）

`IR_ARENA_RESET` → emit 调用 `arena_reset`

**实现选择**：`arena_new`/`arena_reset` 存在两种实现路径——作为外部函数（通过 `ctx_add_plt("arena_new", ...)` 机制）或内联 emit，需在两者之间取舍。

本设计选择**外部函数**方式：与现有 `alloc` 类似，`arena_new`/`arena_reset` 实现为 `emit_alloc_body` 附近的代码片段，通过 call+relocation 跳转。这使得 Core stdlib 可以定义 API，后端提供实现。

### 5. 其他文件修改

| 文件 | 改动 |
|------|------|
| `src/compiler/dataflow.cr` | `df_opcode_name()` 添加新 opcode 名字；`df_connect_srcs()` 处理 edge |
| `src/compiler/ccr_io.cr` | `save_ccr()`/`load_ccr()` 序列化新增 opcode |
| `src/compiler/dyn_arr.cr` | 如需要添加新 opcode 的常量 |
| `src/compiler/opt.cr` | 确保新 opcode 被 pass 跳过（不影响现有优化） |
| `src/arch/linux/ld/resolve.cr` | label resolution 中处理新 opcode |
| `src/compiler/corearch.cr` | 确保新 opcode 被 gen2 代码路径处理 |

### 6. 编译期 Arena 大小预计算

`memory-model.md` 要求编译器为每个子图计算最大内存需求，作为 `arena_new` 的 size 参数。实现在 `ir_gen.cr` 中。

**算法**：在 IR gen 阶段，为每个子图维护一个累计 `alloc_total`：

1. 初始化子图（`sg_push`）时 `alloc_total = 0`
2. 遇到 IR_ALLOC(0, s1, 0, 0)：如果 s1 是编译期常量，`alloc_total += s1`
3. 遇到 IR_ALLOC_STRUCT：根据 struct field 数量计算 `fc * 8`，累加
4. 遇到 IR_ALLOC_ARRAY：`s1 * 8`（s1 是元素数量），如果 s1 是编译期常量则累加
5. 动态大小（变量作为 alloc 参数）：跳过不计
6. 子图结束时（`sg_pop` 前），累计值为 `estimated_size`
7. 如果 `estimated_size == 0`（全动态，无可推大小），使用默认值（如 64KB）

实现位置：在 `emit()` 函数入口处检查 opcode，若属于 `ALLOC` 系列则累加一个子图级计数器。

```core
// ir_gen.cr 新增
g_sg_alloc_total : string, mut  // per-subgraph allocation total
g_sg_alloc_cap   : int, mut

fn sg_alloc_push(kind: int):
    grow_sg_alloc(g_sg_count + 1)
    w64(g_sg_alloc_total, g_sg_count * 8, 0)
    sg_push(kind)

fn sg_alloc_pop():
    total := r64(g_sg_alloc_total, (g_sg_count - 1) * 8)
    if total == 0:
        total = 65536
    // default 64KB for dynamic-only
    emit(IR_ARENA_NEW, arena_var, total, 0, 0, 0)
    sg_pop()

fn track_alloc_size(size: int):
    if g_sg_count > 0:
        old := r64(g_sg_alloc_total, (g_sg_count - 1) * 8)
        w64(g_sg_alloc_total, (g_sg_count - 1) * 8, old + size)
```

`track_alloc_size` 在每个 `emit(IR_ALLOC_X, ...)` 处调用。

## `IR_ALLOC` 指令的零改动

关键设计决定：**`IR_ALLOC`、`IR_ALLOC_STRUCT`、`IR_ALLOC_ARRAY` 指令本身不需要修改**。它们都 emit `call alloc`，而 `alloc()` 函数本身已经是 arena-aware。这使得编译器改动最小化。

## 错误处理

| 场景 | 行为 |
|------|------|
| Arena OOM（当前 chunk 空间不足） | 尝试链式扩容：从全局 alloc 新 chunk，链接到 arena 链表，继续分配。全局 alloc 也 OOM 时返回 0 |
| Arena 池 metadata 耗尽 | `g_arena_cursors/sizes/parents` 动态扩容，无上限 |
| 非法的 arena ID | `arena_reset(-1)` 等无操作 |

### 链式扩容（Chunk Overflow）

当 `arena_alloc` 在当前 chunk 中空间不足时，处理路径不是返回 0，而是执行以下步骤：

1. 通过全局 alloc（此时 `g_current_arena` 暂存为 -1）分配一个新 chunk
2. 新 chunk 挂在当前 arena 的链表末尾
3. cursor 重置到新 chunk 起始位置
4. 在新 chunk 中执行分配

reset 时只回收第一个 chunk 的 cursor（O(1) 重置），overflow chunks 可以归还到全局或保留在 arena 上供下次复用。

当前实现选择：overflow chunks 在 reset 时归还全局（`heap_ptr` 回退），保持 arena 的"用完即弃"语义。后续可优化为保留在 free list 中复用。

## 测试策略

1. **Unit test**（新增 `tests/suite/arena_test.cr`）:
   - 基本生命周期：init → new → alloc → reset
   - 嵌套 arena：函数内 loop 内再分配
   - OOM 触发
   - free list 复用

2. **现有测试**（验证不退化）:
   - 所有现有 suite 测试（无 arena 时应走 global fallback）
   - self-hosted 编译管线

## 不包含的功能

以下功能属于 `memory-model.md` 设计但依赖其他未实现的原语，不在本次实现中：

- **Flow/Go 并发 arena**：编译器的 `go`/`flow` 原语尚未实现。待这些原语就绪后，每个 `go`/`flow` 调用在 `sg_push(SG_FLOW/GO)` 处自然获得独立 arena
- **敏感数据清零选项**：部署配置控制的 optional 行为，不影响 Arena 模型核心语义
- **跨安全边界隔离**：同上的部署配置项，当前只有单进程模型

## 实现清单

| # | 文件 | 改动 |
|---|------|------|
| 1 | `src/stdlib/arena.cr` | 重写：`arena_init`, `arena_new`, `arena_reset`, 全局变量定义 + 动态扩容 + 链式 alloc |
| 2 | `src/runtime/rt.s` | BSS 段添加 `g_current_arena`, `g_arena_pool_data`, `g_arena_free_list` |
| 3 | `src/compiler/ast.cr` | 新增 `IR_ARENA_NEW`(30), `IR_ARENA_RESET`(31) opcodes |
| 4 | `src/compiler/dataflow.cr` | 注册新 opcode 的 df_opcode_name / edge 处理 |
| 5 | `src/compiler/ir_gen.cr` | 新增 `sg_alloc_push/pop` + `track_alloc_size`；函数/loop/for 入口插 arena_new + 大小预计算，出口插 arena_reset |
| 6 | `src/compiler/ccr_io.cr` | 序列化/反序列化新增 opcode |
| 7 | `src/compiler/opt.cr`, `resolve.cr` | 跳过新 opcode（不影响现有 pass） |
| 8 | `src/arch/linux/ld/elf.cr` | 修改 `emit_alloc_body` 为 arena-aware（双路径 + 链式扩容） |
| 9 | `src/arch/linux/ld/instr.cr` | 添加 `IR_ARENA_NEW`/`IR_ARENA_RESET` 编码 |
| 10 | `src/arch/linux/ld/resolve.cr` | label resolution 中处理新 opcode |
| 11 | `tests/suite/arena_test.cr` | Arena 生命周期 + 子图绑定 + OOM 链式扩容 + 嵌套测试 |

## 依赖关系

| 前置条件 | 说明 |
|----------|------|
| 现有 ELF 后端正常工作 | emit_alloc_body、IR 编码路径已验证 |
| 现有子图基础设施 | sg_push/sg_pop、SG_FUNC/LOOP/FOR/UNSAFE |
| arena.cr 全局变量注册 | 需要确保 `g_current_arena` 等全局变量被 parser 注册到 `g_ir_globals`（参见 Known Issues 中未注册全局变量问题） |
