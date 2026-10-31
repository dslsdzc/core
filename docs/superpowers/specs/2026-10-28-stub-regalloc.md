# 运行时 stub 与编译器的共享 CAG 寄存器分配

> 状态：已实施
> 日期：2026-10-28
> 关联：`docs/maintainer/design/regalloc-cache-mapping.md` 第 5 节 · `docs/maintainer/design/regalloc-consistency.md` · `src/lattice/regalloc_cag.cr`

## 概述

编译器的 IR 寄存器分配和运行时 stub 的寄存器分配使用同一个 CAG 核心。区别只在候选构造：IR 分配器从变量和版本构造候选，stub 从指令读写集构造候选。位置扫描、共存判定、固定约束、溢出和驱逐都在核心里。

CAG 的定义以 `docs/maintainer/design/regalloc-cache-mapping.md` 第 5 节为准。本文只记录共享核心的接口、stub 的上下文默认值和接入状态。

## 核心

文件：`src/lattice/regalloc_cag.cr`。

```text
struct CagAllocator
    cand(id, start, end)        // 闭区间
    reg(k, phys, class)         // 物理寄存器编号和类别
    context(id, uses, depth, remat_cost, store_cost, load_cost)
    pin_entry(id, phys)         // 硬约束
    call_at(at)                 // 调用点
    allow_eviction(on)
    run() -> int
    assigned(id) / spilled(id) / rematted(id) / spills()
```

分配规则：

```text
spill_cost(e) = depth(e) * uses(e) * (store_cost(e) + load_cost(e))
remat_cost(e) = 再生 e 的成本
evict_cost(e) = min(spill_cost(e), remat_cost(e))
```

没有空闲寄存器时，如果启用驱逐，选择 `evict_cost` 最小的共存条目。新条目自身的成本不低于其它条目时，新条目成为驱逐对象。这是区间序 First Fit 的情形。

调用点是缓存失效边界。调用点上，活跃且位于 caller-saved 寄存器的条目被驱逐；callee-saved 条目保留。跨调用点固定在 caller-saved 寄存器的条目是约束冲突。

错误值：

| 值 | 含义 |
|---|---|
| 0 | 成功 |
| -1 | 同一候选固定到两个寄存器 |
| -2 | 固定寄存器不在目标寄存器表 |
| -3 | 两个共存候选固定到同一寄存器 |
| -4 | 固定候选跨调用点占用 caller-saved 寄存器 |

## IR 分配器接入

`src/arch/x86_64/regalloc.cr` 的阶段 4 调用 `CagAllocator`。阶段 1 到 3 保留：

1. 检查控扫描，排除不能放进寄存器的类型。
2. 回边探测和携带值扩窗。
3. 候选构造，窗口为 `[first_ref, last_ref]` 加参数入口和携带值修正。

阶段 4 传入 5 个 callee-saved 寄存器，不设置 pin，不启用驱逐。区域深度和使用次数尚未接入，因此 CAG 在 IR 分配器上退化为区间序 First Fit，和接入前行为一致。

## stub 接入

文件：`src/compiler/stub_regalloc.cr`。

`StubAllocator` 从指令表构造每个虚拟寄存器的区间：

- 读和写都扩展区间。
- 只读虚拟寄存器的区间从首次使用开始。
- 指令上的固定约束转换成 `CagAllocator.pin_entry`。

stub 的上下文默认值：

| 上下文 | 值 | 原因 |
|---|---|---|
| uses | 1 | 候选构造不统计使用次数 |
| depth | 0 | 直线指令序列没有区域嵌套 |
| remat_cost | -1 | 没有再生方法 |
| store_cost / load_cost | 1 | 单位成本 |

`depth = 0` 使溢出成本为 0，stub 不启用驱逐。寄存器不足时，新候选溢出到 home 槽。这保持区间序 First Fit 的行为。

stub 没有调用点，不传 `call_at`。

## ELF 发射体接入

默认路径由 `src/runtime/alloc_body.cr` 编译出的 Core blob 承担；旧的
`emit_alloc_body_legacy`（30 条指令的 stub）已经删除，`--alloc-legacy` 开关
不再存在。
`StubAllocator` 分配寄存器，再用 `assigned` 的结果生成字节。`mul` 需要的
`rax/r10` 和 `rep stosb` 需要的 `rdi/rcx/rax` 通过 pin 固定；`base` 和 `cursor`
固定在 `r11/r9`，避免被清零路径覆盖。

arena 路径是直线代码。请求超过 1TB、没有可用的 slot、游标超出上限都执行
`ud2`，不返回 0。超过 64MB 的请求走独立 `mmap` extent，`arena_reset` 时 `munmap`。
没有 arena 时的全局堆路径保留，用于 `arena_init` 之前的分配。

分配器 stub 有意只用七个物理寄存器，使 class 索引无法在定义点获得寄存器。
`StubAllocator` 把它溢出到 `g_alloc_home_idx`，编码器在该值的两次使用前后
插入 `mov [home]` / `mov home`。分配器把 `rbp` 当 scratch，所以 `rbp`、`r14`、
`r15` 都在入口保存，在每条返回路径恢复；`push` 三次保持 `heap_expand` 调用前的
16 字节对齐。`arena_grow_pool` 是普通编译代码，调用前后保存 `r8`、`r9`、`r10`、
`r11` 四个 caller-saved 值。

## 测试

`corec selftest-stub-regalloc` 运行 13 个用例：

1. 不相交区间复用同一寄存器。
2. 共存区间需要不同寄存器。
3. 寄存器耗尽时溢出，不失败。
4. 两个溢出使用不同 home 槽。
5. 固定寄存器不分配给共存条目。
6. 同一候选固定到两个寄存器被拒绝。
7. 固定寄存器不在目标表被拒绝。
8. 只读候选从首次使用开始。
9. 两个共存候选固定到同一寄存器被拒绝。
10. 驱逐成本最低的共存条目。
11. 重算比写回 home 便宜时选择重算。
12. 调用点驱逐 caller-saved，保留 callee-saved。
13. 固定 caller-saved 条目跨调用点被拒绝。
14. 被驱逐的条目在后续驱逐释放寄存器后获得第二次分配。

`tests/selfhost/test_stub_regalloc.py` 要求 14 个用例全部通过，并把 14 作为下限，防止用例表被删减。

## 验收

1. `corec selftest-stub-regalloc` 9/9，返回 0。
2. `corec check src/compiler` 通过。
3. canary：`ea_mov_imm32` 编码修复改变了 canary ELF；新值见
   `tools/baseline/canary_values.tsv` 的重锁记录。
4. `tests/selfhost/test_live_ranges.py` 通过。

## 已知差异

1. pool 由 64MB segment 组成，每个 segment 64 个 1MB slot。上限由 `Core.toml`
   的 `arena_pool_limit` 配置；超过上限时 `arena_grow_pool` 打印错误，分配器随后 trap。
2. 档位 0 到 24 每次切 4KB 块；块用尽后再切一块。档位 25 使用当前 slot 的剩余
   空间，用尽后切新 slot。
3. 1MB 到 64MB 的请求取最新 segment 的连续 slot；超过 64MB 的请求走 mmap extent。
