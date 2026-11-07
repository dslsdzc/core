# CAG: per-register live/pinned index

> 定位：受众 = 维护者；状态 = 已完成；出处 = 本页。

日期：2026-11-07
分支：`perf/cag-live-index`

## 1. 变更

`CagAllocator.location_taken` 原来对每个候选寄存器扫描全部 `count` 个条目：

```text
for each id:
  for each register:
    for each entry: overlap + pin/assign check
```

现在分配器维护两张按寄存器分段的列表：

- `live_ids/live_count`：非 pinned 的已分配条目；
- `pin_ids/pin_count`：pinned 条目（pin 在条目开始前就参与占用判断）。

主扫描按 start 升序处理，列表按 `end < current_start` 压缩已经结束的条目。
second chance 按 id 序而不是 start 序重试，不能使用该压缩，因此该阶段切回
`location_taken_full`；这保留了原来的分配结果和诊断顺序。列表按最坏
“每条目最多两次赋值”预留 `2 × count` 槽。

## 2. 实测

合成 250/500/1000 变量、O2、冷 `.cir`：

| 变量数 | verifier 修复后 | CAG 后 | 变化 |
|---:|---:|---:|---:|
| 250 | 0.575s | 0.517s | −10% |
| 500 | 1.533s | 1.367s | −11% |
| 1000 | 5.027s | 4.388s | −13% |

三档 ELF 与改前逐字节相同；`canary_check.sh` 5/5。

## 3. 验证

```text
test_stub_regalloc.py       PASS（pin/call/evict/remat/second-chance 自测）
test_live_ranges.py         13/13（rules 1/1/2 + read-gap）
test_backend_bootstrap.py   PASS（stage1/2/3 逐字节相同）
ccr-cir area                13/13
canary area                  6/6
canary_check.sh              5/5
```

第一次实现曾把 `end < start` 的压缩用到 second chance 上，导致 rule 1
overlap；已由 `retry_mode` 的全扫描回退修正，测试复现并验证。
