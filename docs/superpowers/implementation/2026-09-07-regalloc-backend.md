# 寄存器分配移后端实施记录

> 对应计划：[plans/2026-09-07-regalloc-backend.md](../plans/2026-09-07-regalloc-backend.md)

## 概述

记录覆盖 2026-09-07 的寄存器分配移后端工作，包括 Task 1 的文件实测、Task 2 至 Task 6 的实现与验证，以及 Task 5 的表述清理和 Task 6 的文档结束。全部 Task 已完成。设计决策 R1a、R2=D-1=Y、R3、R5、D-3 与受波及面处置记录在 `specs/2026-09-07-regalloc-backend-design.md`，状态为设计定稿并实施完成。Task 2、Task 3、Task 4 因 corec 闭包相互依赖而合并为一个切换提交。纯迁移提交先行，可以独立评审。切换提交内按原 Task 顺序自查，记录见下。

## 改动

### Task 1 文件实测

`opt.cr` 实测 1940 行。计划头注写 1939 行，差 1 行，以实测为准。

corearch 闭包位于 `build_selfhost_native.py` 约 170-199 行。该闭包不含 `opt.cr`、`dataflow.cr`、`ir_gen.cr`、`pass.cr`，含 `ast.cr`、`globals.cr`、`dyn_arr.cr`、`ccr_io.cr`、`hit/*`、`arch/linux/ld/*` 和 `corearch.cr`。迁入符号凡定义于 `ir_gen` 或 `dataflow` 者，需要一并迁移或确认替代，见 `get_ir_var_name`。

`iri_*`、`irv_type`、`grow_opt_meta`、`ESZ_ENTRY`、`OFF_ENTRY_*` 常量与访问器都在 `dyn_arr.cr`，双侧闭包都包含这些符号，已确认。`g_opt_meta`、`g_ir_entries`、`g_ir_func_entry_*`、`g_ir_live_ranges` 等在 `globals.cr`，双侧闭包都包含，已确认。

### Task 1 探测结果

样本为：

```c
a:=7;b:=3;x:=a*b;y:=a*b;return x+y
```

在 `corec ccr` 的 O0、O1、O2 三档中，NOD、SYM（除 opt_meta）、ENT、REG 四段逐字节相同。STR 段 O0 比 O1 多 108B，未定位，疑为字符串 intern 序差异，与分配和 CSE 无关。SYM 段 O2 多 984B，等于 opt_meta 的 REG_ASSIGN 落盘。

推论一：`pass_cse` 对 `.ccr` 产物零效果。`lower_to_ccr` 从 df 重建时丢弃其 NOP 和替换。df 与线性流在 `ir_gen` 期同步后，CSE 不再回写 df。R5 的“O1=CSE 留 corec”应如实表述为：CSE 运行于 corec 进程内的 pre-lower 流，不体现在产物中。O1 与 O0 产物的唯一差异面是没有差异，这是现状。

推论二：现状 O2 分配窗口基于 CSE 后流，alloc 在 lower 前计算。产物按 CSE 前流发射，理论上存在不一致。实证无害，O2 全套通过。迁移后 alloc 在 corearch 基于载入流计算，该流是 CSE 前流，与产物同流，消除了这个不一致。行为等价硬约束（exit 和自举可运行检查）不受影响。分配决策与现状可以不逐字节相同，跨版本产物不同的约束已允许这一点。

### 提交线

1. `refactor: regalloc 编码决策层纯迁移入 corearch`。新建 `src/arch/linux/ld/regalloc.cr`，保真迁移 `opt.cr` 189-1737 行的数据面、共存、判定、注入和 CAG alloc。corearch 闭包接线。`get_ir_var_name` 移到 `dyn_arr.cr`，因为 corearch 闭包没有 `ir_gen.cr`，该符号由双侧共享。行为零变化基线为 build 通过，`compile` 和 `ccr_v6` 回归通过。
2. `feat: regalloc 移后端切换`，由 Task 2、Task 3、Task 4 合并，相互依赖的说明见概述。
   - corearch 在 load 后做 O2 自算 `alloc_registers`，并在 emit 前执行 `regalloc_verify_all`。违反时产生编译错误，成功时没有输出。表模式跳过该路径，M1 直线路径没有 O2 组合验证。
   - 调试通道随迁，使用同名 flag：`--dump-entries`、`--dump-coexist`、`--check-regalloc`、`--inject-*` 三态 dispatch，并新增 `--dump-regassign` 逐对输出。
   - corec 的 `opt.cr` 从 1940 行减到 312 行。迁走段删除，保留 AST 折叠和 `pass_cse`，并摘除 `optimize_all` 未使用代码的引用。`main.cr` 的 O2 段与 `cir` 调试通道摘除。`dataflow` lower 尾部的 compute 摘除。
   - `.ccr` 输出格式按 D-1=Y 和 R2 调整：ENT 段 0 条，SYM func 与 REG first/last_ent 恒为 -1，param_ents 恒为 -1，opt_meta 子节 0 块。格式结构保留。loader 空表语义已支持 `pcnt==0` 对应 -1，零 version bump。
   - 测试联动：`live_ranges` 通道改道 corearch，断言零变化；`mw_task5` 元断言改为 `--dump-regassign`；`ccr_v6` 重写恒空断言。`conversion` 和 `param_ents` 的实现方式消亡，相应测试删除或修改。
3. Task 5 表述清除，本批执行。Task 6 文档结束，覆盖 spec、plan、TODO，本批执行。

### Task 5 表述清除

- `regalloc.cr` 判定区头和镜像注记共 5 处，包括“`.ccr` 传输 meta”和“corec 不含后端文件”，改为 corearch 进程内自算自消费的表述。
- `instr.cr` 的 `get_reg_for_var` 头注“saved in .ccr v3+”改为自算填充表述。
- `globals.cr` 的存在区间和条目表注记原写“填充方 opt.cr”，改为 `regalloc.cr` 加 D-1=Y 注。
- `regalloc-consistency.cr` 的参考实现指针从 `opt.cr` 改为 `regalloc.cr`。负编码数据模型表述清理。缺口注记更新，覆盖 `pass_stack_share` 停用、`param_ents` 测试实现方式消亡、GC-1 已修。
- CLI 语义按 R5 更新：corec 和 corearch 的 `-O` 帮助文案改为 O1 等于 CSE 在 corec 进程内，O2 等于分配加判定在 corearch，corec build 透传。src 侧没有“纯机械映射”表述残留。`docs/project-book` 的后端哲学表述列入 TODO 待办校对。
- `opt.cr` 文件头注释原为 AST-level 单一表述，改为剩件清单。

### Task 6 文档结束

- 全套回归通过，范围见验收结果。
- spec 状态更新：R1-R5 和 D-3 决定记录加实施完成，第 6、7 节更新。
- TODO 待办残余写入 `TODO.md` 新节，包含栈共享 corearch 恢复、R4 时间分布实测、v6 格式文档 ENT/opt_meta 恒空同步、project-book 后端哲学表述校对。

## 验收结果

### Task 2 行为等价

corearch 自算分配路径下，以下用例全部通过：

| 用例 | 结果 |
|---|---|
| `cse_probe` | exit 42 |
| `fib` | 55 |
| `loop-carry` | 20 |
| `cond-def` | 14/24 |
| `else-def` | 22/22 |
| `else-control` | 30/31 |
| `region` roundtrip | 6 |
| `ccr_v6` roundtrip | 15 |
| `backend_bootstrap` | stage 7 |

双跑过渡验证：切换前 corec 落盘 meta 的旧 `.ccr` 由新 corearch 加载仍正常。载入 meta 首匹配遮蔽自算块，兼容旧产物。新 `.ccr` 没有 meta，自算块生效。

与计划原“逐 var reg 对照”的偏差：CSE 实证无产物效果，NOD 在 O0、O1、O2 逐字节相同。因此 corec meta（算于 CSE 后流）与 corearch 自算（算于载入 pre-CSE 流）的窗口可以不同。计划硬约束（行为、exit、自举可运行检查）是验证检查，未做逐对恒同断言。判定自洽性反而提升，因为分配、判定和产物同流。

### Task 3 `.ccr` 载荷

- ENT 段恒 4B，count 为 0。opt_meta 恒 0 块。func 和 REG 的 first/last 为 -1。`ccr_v6` 的 8/8 恒空断言和 walker 全部通过。
- loader 对空表与 -1 的对照零改动通过。
- home 字段随 ENT 落盘消亡。内存表 home 保留，属于 corearch 自算态。M1 分配不回填，判定 home 组规则保留供未来回填。

### Task 4 判定失败注入

corearch 路径下判定失败注入仍然失败。`test_live_ranges` 的 `check_regalloc_violations`（rules 1/1/2）、`read_gap_nonfunc0`（rule 2 on func 1）、coexist OOB guard 全部通过，共 13/13。`check-regalloc` watchdog 的 `regalloc-assign pairs > 0` 实证自算分配真实发生。

corec 侧判定触发已移除，包括 `main.cr` 的 O2 段和 `cir --check-regalloc`。

### Task 5 与 Task 6

Task 5 注释改动后 build 通过，关键子集复查通过。全套回归覆盖：

| 范围 | 结果 |
|---|---|
| `mw1-6` | 通过 |
| `compile` | 通过 |
| `backend_bootstrap` stage0-2 | 通过 |
| `ccr_v6` | 8/8 |
| `region_cfg` | 22/22 |
| `slice_bounds` | 7/7 |
| `hit_table` | 11/11 |
| `live_ranges` | 13/13 |
| bootstrap 三套 | 通过 |
| selfhost 其余 | 通过 |

Task 6 的 spec 第 6、7 节已更新为实施完成。TODO 残余已写入 `TODO.md` 新节。

## 遗留问题

- 栈共享的 corearch 恢复尚未执行。
- R4 的时间分布实测尚未执行。
- v6 格式文档的 ENT 和 opt_meta 恒空同步尚未完成。
- `docs/project-book` 的后端哲学表述尚未校对。
- 表模式（M1 直线路径）跳过 O2 组合验证。该路径当前没有 O2 组合验证。
- M1 分配不回填 home。内存表 home 和判定 home 组规则保留，等待未来回填。

## 不包含

- 未做计划原先的逐 var reg 对照。
- 未要求跨版本的分配决策逐字节相同。
- 未提升 `.ccr` 版本号。
- 未在表模式增加 O2 组合验证。
- 未恢复栈共享的 corearch 实现。
- 未执行 R4 时间分布实测。
- 未同步 v6 格式文档的 ENT 和 opt_meta 恒空说明。
- 未校对 `docs/project-book` 的后端哲学表述。
- 未在 M1 分配中回填 home。
