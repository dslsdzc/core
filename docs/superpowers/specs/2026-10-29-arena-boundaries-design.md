# Arena 边界处理设计

> 状态：部分实施（① 完成；② 保留 raw 门；③ 待实施）
> 日期：2026-10-29
> 关联：`docs/superpowers/specs/2026-10-28-arena-size-classes.md` · `docs/superpowers/specs/2026-10-28-stub-regalloc.md`

## 目标

把 arena 剩余的三类边界补齐：

1. 分配器边界：重复 reset、多个 mmap extent、大小临界值、slot 和 pool 临界值、失败见证。
2. tagged-int arena：导入 arena 的用户程序保留 BigInt 语义，不再强制 raw。
3. 解释器 `corec run`：`IR_ALLOC`、`IR_ARENA_NEW`、`IR_ARENA_RESET` 使用 arena 语义，而不是宿主堆近似。

并发 arena 不在本设计内。用户已确认本轮不纳入并发。

## 非目标

1. 对象级释放和块复用。
2. arena 元数据的热更新。
3. 线程间共享 arena。

## ① 分配器边界

### 重复 reset

新增 `g_arena_live` 数组，每个 arena 一个字节：

- `arena_new_sized` 设置 `live[ai] = 1`。
- `arena_reset` 只在 `live[ai] == 1` 时执行释放，执行后置 0。
- 第二次 `arena_reset` 直接返回，不再次把 `ai` 推入 free list。

`g_arena_live` 与其它元数据一起扩容和清零。

### 多个 mmap extent

`g_arena_large_head[ai]` 已经维护单链表。`arena_reset` 逐个 `munmap` 并清空头指针。新增测试在同一 arena 中分配三个大于 64MB 的对象，验证：

- 三个对象地址不同。
- 首尾字节可写可读。
- reset 后 `strace` 看到三次 `munmap`。

### mmap 失败见证

extent 的 `mmap` 返回负值时，当前跳到 `capacity_full`，见证值不适合区分失败原因。改为写入：

| 全局 | 值 |
|---|---|
| `g_alloc_fail_request` | 请求字节数 |
| `g_alloc_fail_class` | -2（extent mmap 失败） |
| `g_alloc_fail_cursor` | 当前 `g_arena_large_head[ai]` |
| `g_alloc_fail_limit` | 0 |

然后 `ud2`。

### 大小临界值

新增回归覆盖：

| 大小 | 期望路径 |
|---|---|
| 0 | 最小 class |
| 3361 | class 25 |
| 3362 | class 25 |
| 4088 | 256 项查表的最后一项 |
| 4089 | 查表 clamp |
| 4096 | class 25 尾部 |
| 1MB - 8 | class 25 尾部 |
| 1MB | 连续 slot |
| 1MB + 8 | 连续 slot |
| 64MB - 8 | 64 个连续 slot |
| 64MB | mmap extent |
| 64MB + 1 | mmap extent |
| 1TB | 允许进入，mmap 失败后 trap |
| 1TB + 1 | 入口 1TB 检查 trap |
| -1 | 入口 1TB 检查 trap（无符号比较） |

### slot 和 pool 临界值

新增回归覆盖：

- 第 63、64、65 个 slot 的地址落在正确 segment。
- pool limit 为 64MB、128MB、192MB 时，segment 数量的成功和失败边界。
- `arena_pool_limit` 为 0 按无上限处理（不 clamp 到 64MB）。
- slot free list 在 reset 后按 LIFO 复用。
- 分配失败后继续调用 reset 不破坏 free list。

### 全局堆边界

无 arena 时的全局堆分配：

- 2GB 请求触发两次 1GB `heap_expand`，返回地址可写。
- `mmap` 失败时走统一 trap，不返回 0。

## ② tagged-int arena

### 原则

arena 元数据数组继续用 `cell_store` / `cell_load` 存取。tagged 模式下这两个函数在边界上完成 tagged 与 raw 的转换，数组里保存的是 raw 值，stub 可以直接读写。

需要转换的只有**标量全局**：

| 全局 | stub 读 | stub 写 |
|---|---|---|
| `g_current_arena` | untag | — |
| `g_arena_max_size` | untag | — |
| `g_arena_pool_slots` | untag | — |
| `g_segment_count` | untag | — |
| `g_arena_slot_count` | untag | tag |
| `g_arena_slot_free` | untag | tag |

untag 用算术右移 1，tag 用左移 1。`g_alloc_fail_*` 和 `g_alloc_home_idx` 是 stub 内部诊断/暂存，保持 raw。

### 静态峰值参数

`IR_ARENA_NEW` 的 `s1` 是字节峰值，后端直接 `mov rdi, s1`。tagged 模式下 `arena_new_sized` 的参数是 tagged int，改为 `mov rdi, s1 * 2`。raw 模式保持原值。

### 编译器策略

删除 `ccr_set_raw_mode_from_source` 中 `fn arena_init` 触发 raw 的分支。arena 库按程序本来的模式编译。

编译器自身仍因 `fn parse_expr` / `fn corearch_main` 使用 raw，不受影响。

### 回归

- tagged 程序（无 `import cli`）导入 arena：小对象、跨 4KB 块、2MB、100MB、1GB。
- 同一程序使用 `int_str` 打印大于 2^32 的值，确认 BigInt 语义未被 arena 破坏。
- `tests/suite/arena_test.cr` 保持 ALL PASS。
- canary 四条 `.ccr` 和 ELF 不变（arena 未导入 canary）。

## ③ 解释器 run 路径

### 新增 Core 分配函数

在 `src/stdlib/arena.cr` 增加 `arena_alloc(size: int) -> string`，按与 ELF stub 相同的顺序实现：

1. 读 `g_current_arena`；小于 0 时返回空串或走宿主堆（由调用方决定）。
2. 计算 `aligned = align_up(size + 8, 8)`。
3. 选择 class 25 或查表 class。
4. class 25 使用 slot 尾部；其它 class 切 4KB 块。
5. 块或尾部不足时链接新 slot。
6. 大于 1MB 时取连续 slot；大于 64MB 时 mmap extent。
7. 写隐藏长度头，返回数据指针。

该函数只服务解释器；ELF 仍使用手写 stub。两者的一致性由同一组 arena 测试覆盖。

### 解释器接线

- `IR_ALLOC`：如果被解释程序有 `arena_alloc` 且 `g_current_arena >= 0`，把大小写入临时槽，调用 `arena_alloc`，结果写入目标槽；否则保持现有宿主 `alloc`。
- `IR_ARENA_NEW`：如果存在 `arena_new` / `arena_new_sized`，按 `s1` 调用并把返回的 arena id 写入目标槽；否则写 -1。
- `IR_ARENA_RESET`：如果存在 `arena_reset`，把 arena id 写入临时槽并调用；否则空操作。

解释器自己的 `alloc`（编译器数据结构）不变，继续使用宿主堆。arena 库内部的元数据分配在 `g_current_arena = -1` 时也走宿主堆。

### 回归

- `corec run tests/suite/arena_test.cr` 返回 0。
- `corec run` 一个 2MB + 100MB 分配程序，返回值与 native 一致。
- 解释器的失败路径：pool limit 和 1TB 请求都停止执行并报错，不返回 0。

## 实施状态

### ① 分配器边界

已完成：

- `g_arena_live` 防止重复 reset 再次入 free list。
- `arena_pool_limit = 0` 表示无上限。
- mmap extent 失败写 `class = -2` 见证。
- segment/extent 指针用 `store_str_ptr` / `load_str_ptr` 存取。
- `tests/suite/arena_boundary_test.cr` 覆盖 0、3361、3362、4088、4089、4096、
  1MB、64MB 临界值，三个 extent，重复 reset，70 个 slot 和零 pool 上限。
- arena 基础设施函数不创建自动 arena；导入 arena 的程序不为 main 创建自动 arena。

### ② tagged-int arena

未启用。stub 的标量 tag/untag 和指针 cell 路径已经写入源码，但 arena 库的
tagged 标量比较仍会触发装箱值的错误路径：arena id 或 extent 指针会被当成
boxed big-int 解引用。`ccr_set_raw_mode_from_source` 继续在源文件包含
`fn arena_init` 时选择 raw。启用前需要先修 tagged 标量表示，或把全部标量
改为 cell 访问。

### ③ 解释器 run 路径

未实施。`corec run` 的 `IR_ALLOC` 仍使用宿主堆；`IR_ARENA_NEW` /
`IR_ARENA_RESET` 仍是近似。实施需要 Core 版 `arena_alloc` 和解释器接线。

## 实施顺序

1. ① 的 `g_arena_live`、mmap 失败见证、边界测试。
2. ② 的标量 tag/untag、峰值参数、删除 raw 分支、tagged 回归。
3. ③ 的 `arena_alloc`、解释器接线、parity 回归。
4. 全量验证：arena 测试、stub-regalloc、canary、`corec check src/compiler`。
5. 文档和值表按实际结果更新。

## 风险

1. ② 的标量 tag/untag 会改变分配器体字节；canary 不导入 arena，ELF 不变。
2. ③ 的 Core 分配器与 ELF stub 可能语义漂移；用同一组边界测试覆盖，并在测试中比较返回值、可写范围和 reset 行为。
3. 解释器的临时槽分配要与现有扁平槽模型兼容；如果 `IR_ALLOC` 在函数入口之前执行，需要先分配临时槽。
