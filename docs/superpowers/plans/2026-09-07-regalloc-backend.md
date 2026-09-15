# 寄存器分配移后端实施计划

> **状态：全部 Task 完成（2026-09-07）**——Task 1-6 执行记录见文末；设计决策
> 拍板（R1a / R2=D-1=Y / R3 / R5 / D-3）与受波及面处置见 specs/
> 2026-09-07-regalloc-backend-design.md（状态：设计定稿 + 实施完成）。
> 执行偏差：Task 2/3/4 因 corec 闭包互锁（数据面摘除 ↔ 落盘废止 ↔ 通道迁移
> 同批编译）合并为单一切换提交——纯搬移提交先行（可独立评审），切换提交内
> 按原 Task 顺序自查（见执行记录）。

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 寄存器分配（数据面 + CAG 分配 + 判定）从 corec（opt.cr）移至 corearch——编码层资源决策归位后端；.ccr opt_meta REG_ASSIGN 不再跨进程传输；「纯机械映射」表述取消。

**Architecture:** 按层拆 opt.cr（R1a）：语义优化（CSE 等）留 corec；编码决策（compute_live_ranges/compute_entries/共存/alloc_registers/verify）迁 corearch（新模块）。分配结果不再入 .ccr（R2）——corearch load 后自算（输入 = v6 ENT 段内存态 + IR）。判定 verify 随分配移 corearch O2 自检（R3）。corec `-O` 门语义调整（R5：O1=CSE 留 corec；O2=分配在 corearch）。

**Tech Stack:** Core 自举编译器（src/compiler/opt.cr 拆分、src/arch/linux/ld/ 新 regalloc 模块、ccr_io.cr）、Python bootstrap。

## Global Constraints

- 版本控制 `jj`（铁律 #2）。提交 `jj commit -m`；不动 bookmark
- 构建 `nice -n 19 python3 build_selfhost_native.py` 每次改动重建；测试 `bash -c 'ulimit -c 0; ...'`
- **行为等价硬约束**：迁移期/完成后 O2 产物行为与现状一致（分配决策等价——后端自算与 corec 算同结果；O2 自举 byte-identical 语义：同版本确定性——跨版本产物可不同（格式简化），测试判据 = 行为/exit + 自举可运行）
- 语义层零改动（corec 前端/IR 语义不变——只 opt 层拆分）
- 设计定稿：`specs/2026-09-07-regalloc-backend-design.md`（R1a/R2/R3 拍板 + R4/R5 注）
- 现状关键：分配真相源 = g_opt_meta OPT_KEY_REG_ASSIGN（.ccr SYM opt_meta 段传输）；后端 g2_slot 负编码消费；判定 regalloc_verify_all 在 main.cr O2 路径；多字 tagged 识别已在 corearch（instr.cr）
- 测试：回归 compile/ccr_v6/region_cfg/live_ranges/hit_table/mw1-6/backend_bootstrap + corec check

---

### Task 1: opt.cr 按层切分盘点（语义 vs 编码归属清单）

**Files:** 分析产出（无代码改动——切分清单文档）
- 读 opt.cr 全 1939 行，分类所有函数：语义优化（AST/IR 优化——留 corec）/ 编码决策（活区间/条目/共存/分配/判定——迁 corearch）/ 共享工具（grow/buffer——随迁或复制）
- 产出切分清单（函数 → 归属 + 依赖图——迁入 corearch 的函数依赖哪些 corec 侧符号/全局——依赖也要迁）
- 交付：清单文档（.superpowers 或 plan 附注），Task 2+ 按清单执行

### Task 2: corearch 分配模块迁入（行为等价双跑验证）

**Files:** 新建 src/arch/linux/ld/regalloc.cr（数据面+分配+判定迁入）+ corearch 闭包接线 + opt.cr 侧停用（O2 门不再调 alloc_registers）
- 迁移顺序：数据面（compute_live_ranges/entries/共存）→ 分配（alloc_registers + meta）→ 判定（verify）——依赖全局表（g_ir_*）corearch load 后已有
- 触发点：corearch load 后、emit 前（O2 时）——替代 corec 传输
- 验证：O2 行为等价（后端自算 vs 原 corec 算——迁移期间可双跑对照 exit/产物行为）——后端分配结果 = corec 原结果（逐变量 reg 对照——过渡期测试）
- test_mw_task5 哨兵（REG_ASSIGN 元数据通道）——corearch 侧同进程消费（tag 表直接可读）

### Task 3: .ccr opt_meta 出格式（R2）

**Files:** ccr_io.cr（save/load SYM opt_meta 段移除或空）+ test_ccr_v6/region_cfg walker 更新
- REG_ASSIGN 不再落盘（corearch 自算）——opt_meta 段处理（全出？仅 REG_ASSIGN 出？——若 opt_meta 仅此用途则段整体移除——盘点确认）
- ENT home 字段处置（分配回填 = corearch 内存态——落盘恒 -1？或字段保留——决策执行时按设计定稿）
- 格式版本（v6 内部再改 or version bump？——同仓同步 v6-only——内部改段即可）

### Task 4: 判定迁移（R3）

**Files:** verify_regalloc_consistency 等（已随 Task 2 迁）——触发点移 corearch（emit 前 O2 自检——违反 = 编译错误）；main.cr corec 侧判定触发移除
- 测试：判定红注入用例在 corearch 路径仍红（--inject-* 通道移 corearch）

### Task 5: 表述清除 + CLI 语义（R5）

**Files:** opt.cr/g2_slot 注释「pure mechanical translation」清除（g2_slot 改述 = 后端槽解析 seam）；corec `-O` 帮助/门语义（O1 留 corec CSE；O2 分配已在 corearch——corec -O 仅影响 CSE——CLI 文案）；regalloc-consistency.cr 参考实现指针更新

### Task 6: 回归 + 文档收尾

- 全套回归（含 mw1-6 哨兵更新确认、backend_bootstrap、O2 自举可运行）
- spec 状态（R1-R5 拍板记录 + 实施完成）+ TODO 挂账（如有残余）

---

## 风险（评审注意）

- opt.cr 拆分依赖图遗漏（迁入函数引用未迁符号 → 编译错——Task 1 清单完备性关键）
- 行为等价验证（迁移过渡双跑——corec 分配停用瞬间 O2 行为依赖 corearch 正确）
- .ccr opt_meta 移除的 walker/测试联动面
- 多字 tagged 分配同侧整合（Task 5 哨兵 → corearch 内断言）

---

## Task 1 执行记录（2026-09-07）：按层切分盘点

> 交付物 = 本清单。Task 2+ 按此执行；**D-1/D-2/D-3 三个拍板点须在 Task 2 动工前向用户拍板**（计划原 R1a/R2/R3 取向已获授权，本清单把它们落实为具体选择）。

### 文件实测

- `opt.cr` 实际 **1940 行**（计划头注 1939——差 1，以实测为准）
- corearch 闭包（build_selfhost_native.py ~170-199）**不含** opt.cr/dataflow.cr/ir_gen.cr/pass.cr——含 ast.cr/globals.cr/dyn_arr.cr/ccr_io.cr/hit/*/arch/linux/ld/* + corearch.cr。→ 迁入符号凡定义于 ir_gen/dataflow 者需一并搬移或确认替代（见下 get_ir_var_name）
- iri_*/irv_type/grow_opt_meta/ESZ_ENTRY/OFF_ENTRY_* 常量与访问器均在 dyn_arr.cr（双侧闭包含）✓；g_opt_meta/g_ir_entries/g_ir_func_entry_*/g_ir_live_ranges 等在 globals.cr（双侧）✓

### 归属清单

**A 语义优化——留 corec（opt.cr 不迁）**

| 函数（行） | 性质/依赖 | 调用点 |
|---|---|---|
| ast_is_const_int(11)/ast_const_val(17)/ast_bool_as_int(21)/ast_fold_binary(26)/ast_optimize_body(65) | AST 常量折叠（AST 层，非编码决策） | optimize_all（死码，见下） |
| pass_cse(1819) | 线性流 CSE：NOP + 引用替换（iri_set_op 等）；依赖 iri_*/g_ir_func_* | **main.cr:580（O≥1）** |
| optimize_all(1917) | 编排器（ptr_analysis/region_check/provenance/AST fold/pass_cse/alloc/pass_stack_share 的 O 门聚合） | **全仓无调用者 = 死码**（main.cr 566-588 直调各 pass）。拆分时须摘除其 alloc_registers()/pass_stack_share() 引用（否则 corec 闭包内符号悬空） |

**B 数据面（存在区间/条目）——归属随拍板点 D-1（倾向迁 corearch 单宿主）**

| 函数（行） | 性质/依赖 | 调用点 |
|---|---|---|
| grow_live_ranges(198)/live_range_slot(205)/live_first(215)/live_last(220)/compute_live_ranges(228) | 区间表 + 逐函数扫描；尾部调 compute_entries 整表重建 | main.cr:505/514/520（cir dump 通道）、dataflow.cr:392（lower_to_ccr 尾——**无条件，.ccr ENT 段唯一来源**）、alloc_registers:1316 首行 |
| grow_entries(319)/grow_func_entry_meta(326)/ent_*(341-347)/entry_start(350)/entry_count(355)/compute_entries(360) | 版本条目表（ESZ_ENTRY 24B/条） | 同上（compute_live_ranges 尾部循环调用） |
| 依赖 | g_ir_live_ranges/count/cap、g_ir_entries/count/cap、g_ir_func_entry_*/g_ir_func_var_*/g_ir_func_instr_*/g_ir_func_count、iri_*(g_ir_instrs)、buf_read_i32(ccr_io.cr)、alloc/_dyncpy/r64/w64/w32 | corearch 闭包均有（entries 表由 load_ccr 重建：ccr_io.cr:1114-1183，含盘→内存闭区间转换 + func 段界重建 + SYM first/last_ent 对照校验） |

**C 判定族——迁 corearch（regalloc.cr）**（含注入测试钩子）

| 函数（行） | 备注 |
|---|---|
| entries_coexist(544)/coexist_version_conflicts(560)/coexist_home_conflicts(591) | 共存（v6 Task 3；GC-1 越界守卫在 entries_coexist） |
| rl_rec_lt(694)/rl_merge_sort(704)/rl_print_loc(755)/rl_func_name(763)/rl_report_rule1(769)/rl_report_rule2(781)/rl_rule2_func(803)/verify_regalloc_consistency(872)/regalloc_verify_all(964) | 判定规则①②（规约 regalloc-consistency.corespec）；LOC_HOME_BASE/RPT_MAX 文件内常量随迁 |
| meta_reg_for_var(670)/meta_reg_pair_off(1028)/meta_set_reg(1051)/meta_remove_var(1059)/meta_reg_assign_total(1101)/meta_append_reg_assign(1115) | g_opt_meta 读写侧辅助（镜像 instr.cr:33 get_reg_for_var 布局——迁后同进程，镜像收敛为直接消费） |
| try_inject_home_conflict(984)/inject_home_conflict(1013)/try_inject_reg_conflict(1136)/inject_reg_conflict(1163)/try_inject_read_gap(1179)/inject_read_gap(1229)/inject_coexist_oob(637) | 判定红注入（cir --inject-* 测试载体；真实构建路径不注入） |
| 调用点（现状 corec） | main.cr:540（check-regalloc verify）、main.cr:587（O2 build verify 拦截）；dump_coexist_summary 经 main.cr:521 |
| 迁入依赖 | get_ir_var_name **定义在 ir_gen.cr:363（corearch 闭包无）**——打印路径（rl_report_*/dump）消费；处置：随迁搬至 dyn_arr.cr（双侧共享位；dump.cr:45/dataflow.cr:460 的 corec 调用不受影响）；其余依赖同 B + g_opt_meta 表 |

**D 分配——迁 corearch（regalloc.cr）**

| 函数（行） | 备注 |
|---|---|
| label_pos_of(1303)/alloc_registers(1313) | CAG 上下文贪心（区头注释 1242-1302 含全部语义论证——随迁）；阶段 1-5：hazard 门控/回边携带/候选窗口/First Fit/meta 落块 |
| 调用点（现状） | main.cr:532（check-regalloc 强制 O2）、**main.cr:583（O2 build）**、opt.cr optimize_all（死码，摘除） |
| 迁入依赖 | B 全部（alloc 首行 compute_live_ranges()——D-1 裁决它算不算第二次）、iri_*/irv_type（TI_DEX/TI_DYN/TI_UNIT 类型门）、IR_CONST/IR_REF/IR_I2F/IR_DYN_*/IR_JUMP/IR_BRANCH/IR_LABEL/IR_STORE 常量（ast.cr 双侧）、g_opt_meta 写侧 grow_opt_meta/store8（双侧）、g_opt_level（corearch CLI --opt-level 已接，corearch.cr:38-40；corec build 已透传：main.cr:644） |

**E 栈共享——现状产物死路径，处置随拍板点 D-3**

| 函数（行） | 备注 |
|---|---|
| pass_stack_share(1739) | 窗口共享填 g_stack_map；**g_stack_map 不落 .ccr**（ccr_io 无序列化），corearch.cr:7 启动置 "" → instr.cr:64-67（g2_slot）消费恒不命中 → 对 ELF 产物零效果（现状空跑） |
| 依赖 | iri_*/g_ir_func_*/g_stack_map（instr.cr 侧读取在 g2_slot:64——恒空） |

**F 调试通道——联动随拍板点 D-2**

| 函数（行） | 备注 |
|---|---|
| ir_op_kind_name(458)/dump_entries_summary(494)/dump_coexist_summary(620) | corec `cir --dump-entries/--dump-coexist` 载体（main.cr:504-523）；test_live_ranges.py 消费 |
| 判定注入族（C 组） | corec `cir --check-regalloc/--inject-*` 载体（main.cr:529-546）；test_live_ranges.py 消费（含 test_mw_task5 的 REG_ASSIGN 元断言读取通道？——mw_task5 走 corec build O2 产物行为 + cir 元断言两种） |
| 说明 | corearch 已有 debug 命令先例（--table/--dump-events）；通道迁移 = corearch 加等价 flag 组 + 测试改道 |

### 现状链路（迁移基线——全部经实证/读码确认）

```
corec build/ccr:
  ir_gen_all（线性 g_ir_instrs 与 df 平行产出）
  → O≥1: pass_cse(580)        [作用于 g_ir_instrs]
  → O≥2: alloc_registers(583) [内 compute_live_ranges+entries；写 g_opt_meta REG_ASSIGN]
          regalloc_verify_all(587) → 违反 = 编译错误
          pass_stack_share(588)   [写 g_stack_map——不落盘]
  → lower_to_ccr(591)          [自 df 重建 g_ir_instrs（= CSE 前形态）；尾 compute_live_ranges+entries（重建流）]
  → save_ccr: SYM opt_meta 子节（g_opt_meta 块，key 0=REG_ASSIGN 有产物；key 1/2=STACK_SHARE/CSE 预留无写入者）+ ENT 段（28B/条，home 现状恒 -1——alloc 不回填 home）+ REG/SYM func first/last_ent 对照
corearch:
  load_ccr（g_opt_meta/entries/func 边界重建 + 校验）→ init_backend_arrays（g_stack_map=""）
  → elf_gen → g2_slot(54)：meta 查 g_opt_meta（g_opt_level≥1 门）→ E2_REG_SLOT_BASE+reg；否则栈槽
```

### 实证结论（2026-09-07 探测）

- 样本 `a:=7;b:=3;x:=a*b;y:=a*b;return x+y` 在 `corec ccr` 三档（O0/O1/O2）：
  - **NOD/SYM(除 opt_meta)/ENT/REG 四段逐字节相同**；STR 段 O0 比 O1 多 108B（未定位，疑字符串 intern 序差异——与分配/CSE 无关）
  - SYM 段 O2 多 984B = opt_meta REG_ASSIGN 落盘
- **推论：pass_cse 对 .ccr 产物零效果**（lower_to_ccr 自 df 重建丢弃其 NOP/替换；df 与线性流在 ir_gen 期同步后 CSE 不再回写 df）。含义：
  - R5「O1=CSE 留 corec」如实表述为：CSE 运行于 corec 进程内 pre-lower 流，不承载于产物；O1 与 O0 产物的唯一差异面 = 无（现状）
  - 现状 O2 分配窗口基于 CSE 后流（alloc 在 lower 前算）而产物按 CSE 前流发射——理论缝隙存在、实证无害（O2 全套绿）；**迁移后 alloc 在 corearch 基于载入流（CSE 前）计算，与产物同流自洽**——反而消除缝隙。行为等价硬约束（exit/自举可运行判据）不受影响；分配决策与现状可不逐字节同（约束已允许跨版本产物不同）

### 待拍板点（Task 2 动工前问用户）

- **D-1 .ccr ENT 段去留**（R2 细化——决定数据面单/双宿主）：
  - 方案 X（ENT 保留传输）：数据面生成留 corec（lower 尾不变、cir 通道不动）；corearch 分配输入 = 载入 ENT + 需自算 live ranges（盘上无 var 级区间表）→ alloc 首行 compute_live_ranges 迁入即重算 → **数据面计算双宿主**（语义漂移风险，与「归位」目标相悖）
  - 方案 Y（推荐）：ENT 段恒空/出格式（loader 已支持段缺失 = 空 + pcnt=0 与 SYM first/last_ent=-1 对照——**格式结构零改动、无 version bump**）；数据面计算单宿主 corearch（compute_live_ranges/entries/grow/访问器迁 regalloc.cr）；corec lower 尾摘除调用；save 侧 ENT 计数 0；SYM/REG first/last_ent 落 -1；「发射不依赖 ENT」（ccr_io.cr:74 已注）✓
- **D-2 调试通道联动**（随 D-1=Y）：corec `cir` 的 dump-entries/dump-coexist/check-regalloc/inject-* 载体与 test_live_ranges.py 改道 corearch（新 flag 组：--dump-entries/--dump-coexist/--check-regalloc/--inject-*，corearch load .ccr 后内存态即数据面）；corec 侧分支删除。D-1=X 则通道不动（数据面留 corec），仅判定注入随判定迁移面另行处置
- **D-3 pass_stack_share 处置**：（a）随迁并启用（行为新变：帧缩小——现状产物无共享，启用 = 行为差异风险，需独立验证）；（b）停用（推荐：产物零差异，调用摘除 + optimize_all 死码同步清理；恢复 = 未来 corearch 内以 alloc 同 seam 实现，挂账）；（c）留 corec 空跑（现状，不归位）

---

## Task 2-6 执行记录（2026-09-07）

### 提交线（每提交可独立评审）

1. `refactor: regalloc 编码决策层纯搬移入 corearch`——新建 `src/arch/linux/ld/regalloc.cr`（opt.cr 189-1737 保真搬移：数据面/共存/判定/注入/CAG alloc）+ corearch 闭包接线 + `get_ir_var_name` 移 dyn_arr.cr（corearch 闭包无 ir_gen.cr——双侧共享位）；行为零变化基线（build 绿 + compile/ccr_v6 回归绿）
2. `feat: regalloc 移后端切换`（Task 2+3+4 合并——互锁说明见顶部状态注）：
   - corearch：load 后 **O2 自算 alloc_registers + regalloc_verify_all**（emit 前，违反 = 编译错误，成功静默）；表模式跳过（M1 直线路径无 O2 组合验证）；调试通道随迁同名 flag（--dump-entries/--dump-coexist/--check-regalloc/--inject-* 三态 dispatch + 新 --dump-regassign 逐对输出）
   - corec：opt.cr 1940→312 行（迁走段删除；留 AST 折叠 + pass_cse + optimize_all 死码摘引用）；main.cr O2 段与 `cir` 调试通道摘除；dataflow lower 尾 compute 摘除
   - .ccr 出格式（D-1=Y/R2）：ENT 段 0 条、SYM func 与 REG first/last_ent 恒 -1、param_ents 恒 -1、opt_meta 子节 0 块——格式结构保留（loader 空表语义已支持：pcnt==0 ↔ -1 对照），零 version bump
   - 测试联动：live_ranges 通道改道 corearch（断言零变化）；mw_task5 元断言改 --dump-regassign；ccr_v6 重写恒空断言（conversion/param_ents 载体消亡删/改）
3. Task 5 表述清除（本批，见下）+ Task 6 文档收尾（spec/plan/TODO，本批）

### Task 2 验证（行为等价，切换后全锚点）

- O2 行为等价：cse_probe exit 42、fib 55、loop-carry 20、cond-def 14/24、else-def 22/22、else-control 30/31、region roundtrip 6、ccr_v6 roundtrip 15、backend_bootstrap stage 7——全部绿（corearch 自算分配路径）
- 双跑过渡验证：切换前 corec 落盘 meta 的旧 .ccr 由新 corearch 加载仍正常（载入 meta 首匹配遮蔽自算块 = 兼容旧产物）；新 .ccr 无 meta → 自算块生效
- 与 plan 原「逐 var reg 对照」的偏差：CSE 实证无产物效果（NOD O0/O1/O2 逐字节同）→ corec meta（算于 CSE 后流）与 corearch 自算（算于载入 pre-CSE 流）窗口可不同——计划硬约束（行为/exit + 自举可运行判据）为验证判据，未做逐对恒同断言；判定自洽性反而提升（分配/判定/产物同流）

### Task 3 验证

- .ccr 载荷：ENT 段恒 4B（count 0）、opt_meta 恒 0 块、func/REG first/last -1（ccr_v6 8/8 恒空断言 + walker 全绿）；loader 对空表与 -1 对照零改动通过
- home 字段：随 ENT 落盘消亡；内存表 home 保留（corearch 自算态，M1 分配不回填——判定 home 组规则保留供未来回填）

### Task 4 验证

- 判定红注入在 corearch 路径仍红：test_live_ranges check_regalloc_violations（rules 1/1/2）+ read_gap_nonfunc0（rule 2 on func 1）+ coexist OOB guard——全绿（13/13）；check-regalloc watchdog（regalloc-assign pairs > 0）实证自算分配真实发生
- corec 侧判定触发（main.cr O2 段 + cir --check-regalloc）已移除

### Task 5 表述清除（本次提交）

- regalloc.cr 判定区头/镜像注记（「.ccr 传输 meta」「corec 不含后端文件」等 5 处）→ corearch 进程内自算自消费表述
- instr.cr get_reg_for_var 头注（「saved in .ccr v3+」）→ 自算填充表述
- globals.cr 存在区间/条目表注记（填充方 opt.cr）→ regalloc.cr + D-1=Y 注
- regalloc-consistency.cr：参考实现指针 opt.cr → regalloc.cr；负编码数据模型表述清理；缺口注记更新（pass_stack_share 停用、param_ents 测试载体消亡、GC-1 已修）
- CLI 语义（R5）：corec/corearch `-O` 帮助文案更新（O1 = CSE corec 进程内；O2 = 分配+判定 corearch，corec build 透传）；「纯机械映射」表述 src 侧无残留（docs/project-book 后端哲学表述 → TODO 挂账校对）
- opt.cr 文件头注释（AST-level 单一表述）→ 剩件清单

### Task 6 收尾（本批）

- [x] 全套回归绿（切换提交后全量：mw1-6 + compile + backend_bootstrap stage0-2 + ccr_v6 8/8 + region_cfg 22/22 + slice_bounds 7/7 + hit_table 11/11 + live_ranges 13/13 + bootstrap 三套 + selfhost 其余）；Task 5 注释改动后 build 绿 + 关键子集复查（见提交记录）
- [x] spec 状态：R1-R5/D-3 拍板记录 + 实施完成（§6/§7 更新）
- [x] TODO 挂账（残余）：见 TODO.md 新节——栈共享 corearch 恢复、R4 时间分布实测、v6 格式文档 ENT/opt_meta 恒空同步、project-book 后端哲学表述校对
