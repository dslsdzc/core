# Arena 边界处理设计

> 状态：② 完成（① 已完成；③ 待实施）
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

### 大对象路径

`g_arena_large_head[ai]` 由库的 `arena_reset` 维护。Core allocator blob
的 `alloc_arena_extent` 通过 bootstrap 的 `syscall6` 建立专用匿名 mmap：

- 布局与 reset 链一致：`+0` next 指针、`+8` munmap 长度、`+16` 隐藏长度头、
  `+24` payload。
- `arena_reset` 逐个 `munmap` 并清空 head/count。
- mmap 失败写 `g_alloc_fail_request`、class `-2`、当前 head 和 0，然后退出
  132。
- dynamic arena 的 >1MiB 对象不再回退到全局堆；static arena 的 >1MiB 请求
  仍在 static 分支内 trap。

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
| 1MB | 专用 mmap extent（对齐后大于 1MB） |
| 1MB + 8 | 专用 mmap extent |
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

### 表示

arena 的元数据数组和标量缓冲区都保存 **raw 机器字**。库和 stub 读取同一份
cell：

- stub 直接按 raw 读写标量缓冲区和元数据数组。
- 库的标量 getter 用 `load64` 按字面量偏移读取，setter 用 `cell_store` 按字面量
  偏移写入。不能把变量偏移直接交给 `cell_load`/`cell_store`：这两个函数的
  偏移会经过 big-int 运行时，在 arena 内部可能触发装箱并重入分配器。
- 元数据数组用 `cell_store` / `cell_load` 存取；数组里是 raw 值，stub 直接读。
- `g_current_arena` 保留一个普通全局镜像，供直接读取它的测试和旧程序使用。

### 初始化和 reset

- `g_arena_scalars_ready` 在标量缓冲区建立期间为 0；allocator body 看到 0 时走全局堆。
- `g_arena_suspend` 在 `arena_init` 和 `arena_reset` 期间为 1；stub 看到非 0 时
  走全局堆。这样 tagged 算术产生的 big-int 装箱不会进入半初始化或正在重置的
  arena。
- `arena_init` 分配标量缓冲区后立即把当前 arena 写成 -1，再继续分配元数据。
- `arena_new_sized` 和 `arena_reset` 用 raw 当前 arena；reset 结束前不清除
  suspend，避免最后一次 `cell_store` 重入。
- mmap extent 的数量保存在 `g_arena_large_count`，reset 按 tagged 计数循环，
  不把 raw 指针当整数比较。

### BigInt

`bi_to_word_checked` 增加 tagged 小整数快速路径：偶数且在立即数范围内的值直接
返回 `a / 2`，不再装箱。该路径用于所有 tagged 程序的 raw 偏移/长度转换，也
避免 arena 元数据访问在内部触发分配。`src/runtime/bigint_blob.cr` 已用
`tools/gen_bigint_blob.py` 重新生成。

`IR_ARENA_NEW` 的静态峰值在 tagged 模式下乘 2；无 arena 哨兵用 -2（tagged -1）。

### 编译器策略

删除 `ccr_set_raw_mode_from_source` 中 `fn arena_init` 触发 raw 的分支。arena
库按程序本来的模式编译。编译器自身仍因 `fn parse_expr` / `fn corearch_main`
使用 raw，不受影响。

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

已完成。arena 库按程序本来的 tagged 模式编译；元数据和标量缓冲区保存 raw
字，stub 直接读写。`ccr_set_raw_mode_from_source` 不再因 `fn arena_init`
选择 raw。BigInt 语义保留：`tests/suite/arena_test.cr` 通过，
`/tmp/tagbig2.cr` 在 arena 内打印并比较 2^32 和 2^64 的值，结果正确。

回归结果：

| 测试 | 结果 |
|---|---|
| `tests/suite/arena_test.cr` | ALL PASS |
| `tests/suite/arena_boundary_test.cr` | 0 |
| 2MB/100MB/1GB、跨 4KB 块、70 slot、静态峰值 | 0 |
| `chunks`（2000×64B + 200×10000B） | 0 |
| `many_slots` | 0 |
| `tagbig2`（2^32/2^64 BigInt） | 0 |
| `corec selftest-stub-regalloc` | 14/14 |
| canary | 5/5（ELF 重锁为 `368f4ab0…`，53430 B） |

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
