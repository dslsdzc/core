# Backend linearization: register lookup and Rule 2 verification

> 定位：受众 = 维护者；状态 = 已完成；出处 = 本页。

日期：2026-11-07
分支：`perf/backend-direct-index`

## 1. 结论

O2 后端的两条平方级路径已经拆掉：

1. `get_reg_for_var` 每个操作数扫描全部 `g_opt_meta` pair。现在分配结束后构建
   `var -> reg` 直查表，发射阶段 O(1)；旧扫描保留为映射未构建/注入失效时的回退。
2. `rl_rule2_func` 对每个常驻变量重新扫描全部条目和全部节点。现在每个函数先建
   `var -> version entries` 与 `var -> read positions` 两张计数排序索引，再按变量
   遍历自己的读取位置。诊断顺序保持“变量序，再指令升序”。

实测（合成 250/500/1000 变量、O2、冷 `.cir`）：

| 变量数 | 改前 | 改后 | 变化 |
|---:|---:|---:|---:|
| 250 | 0.799s | 0.575s | -28% |
| 500 | 2.396s | 1.533s | -36% |
| 1000 | 8.286s | 5.027s | -39% |

三档 ELF 与改前逐字节相同；`canary_check.sh` 5/5。

## 2. 热点归属（callgrind）

改前 250 变量、O2：

```text
corearch_main
  regalloc_verify_all                 50.7%
    verify_regalloc_consistency       50.0%
      rl_rule2_func                   49.96%
  alloc_registers                     35.9%
    CagAllocator.run                  28.6%
  load_ccr                             9.4%
  build_linear_schedule                2.4%
  elf_gen                              0.87%
```

`get_reg_for_var` 不在前二十；它确实存在，但不是这个负载的决定性热点。改后：

```text
alloc_registers                       70.1%
  CagAllocator.run                    55.9%
load_ccr                              18.4%
elf_gen                                4.66%
regalloc_verify_all                    3.76%
```

下一步的真热点是 `CagAllocator.location_taken`（每变量 × 每寄存器 × 全条目扫描），
不是 `label_pos_of`/`g2_str_off`。

## 3. 被否掉的方案：从 ENT 推导 live ranges

ENT 的 `live_start/live_end` 看起来可以省掉 `compute_live_ranges` 的节点扫描，但实测
不等价。用 19 个函数、带循环和未使用参数的 `.ccr` 做逐变量对拍：

```text
loop_carry / n:  scan=(12,12)  ent=(12,13)
unused / b:      scan=(-1,-1)  ent=(0,6)
format2 / a0:    scan=(-1,-1)  ent=(0,7)
```

两个差异：

- 文件里的 `live_end` 是节点扫描的 `last_ref + 1`（半开），直接取 max 会多 1。
- 未引用参数在 ENT 里写成整个函数范围，节点扫描给 `-1`。从 ENT 归并会让这些参数
  突然变成全函数活跃，改变寄存器分配。

因此本轮不按“从 ENT 重算”改。若将来要改，先改 ENT 的未引用参数语义，再做逐字节
对拍。

## 4. 验收

```text
tests/selfhost/test_live_ranges.py      13/13
tests/selfhost/test_stub_regalloc.py    PASS
tests/selfhost/test_hit_table.py        24/24
src/ci/run_tests.py --area ccr-cir      13/13
src/ci/run_tests.py --area canary        6/6
src/ci/run_tests.py --area core          9/9
tools/baseline/canary_check.sh           5/5
```

`rl_rule2_func` 的负例（rule 2 read-gap）仍被检出；诊断文本与顺序未变。

## 5. 边界

- 本轮不改 `.ccr` 格式，不需要 v11。
- 本轮不改 CAG 分配算法；`location_taken` 的索引化留到下一批，避免把分配结果
  变化和验证加速混在一个提交里。
- 本轮不改 `g2_str_off`、`label_pos_of`；在这份负载中它们不是主因。等 CAG 处理后
  再按新的 profile 决定。
