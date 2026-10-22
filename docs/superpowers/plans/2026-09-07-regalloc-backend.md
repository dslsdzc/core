# 寄存器分配移后端实施计划

> 实施记录：[implementation/2026-09-07-regalloc-backend.md](../implementation/2026-09-07-regalloc-backend.md)

> 面向执行本计划的 agent：必须使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans，按任务逐项实现。用复选框（`- [ ]`）跟踪进度。

目标：寄存器分配（数据面加 CAG 分配加判定）从 corec（opt.cr）移到 corearch，让编码层资源决策回到后端；.ccr opt_meta REG_ASSIGN 不再跨进程传输；取消「纯机械映射」这一表述。

结构：按层拆 opt.cr（R1a）。语义优化（CSE 等）留在 corec；编码决策（compute_live_ranges/compute_entries/共存/alloc_registers/verify）迁到 corearch 的新模块。分配结果不再写入 .ccr（R2），corearch load 后自算，输入是 v6 ENT 段内存态加 IR。判定 verify 随分配移到 corearch，在 O2 自检（R3）。corec 的 `-O` 门语义调整（R5：O1 的 CSE 留在 corec；O2 的分配在 corearch）。

技术栈：Core 自举编译器（src/compiler/opt.cr 拆分、src/arch/linux/ld/ 新 regalloc 模块、ccr_io.cr）、Python bootstrap。

## 全局约束

- 版本控制用 `jj`，见项目规则第 2 条。提交 `jj commit -m`，不动 bookmark。
- 构建 `nice -n 19 python3 build_selfhost_native.py`，每次改动后重建；测试 `bash -c 'ulimit -c 0; ...'`。
- 行为等价是硬约束：迁移期和完成后，O2 产物行为与现状一致。分配决策等价，即后端自算与 corec 算出相同结果。O2 自举 byte-identical 的语义是同版本确定性，跨版本产物可以不同（格式简化），测试检查是行为或 exit 加自举可运行。
- 语义层零改动：corec 前端和 IR 语义不变，只拆 opt 层。
- 设计定稿：`specs/2026-09-07-regalloc-backend-design.md`（R1a/R2/R3 决定加 R4/R5 注）。
- 现状关键：分配事实源是 g_opt_meta OPT_KEY_REG_ASSIGN（.ccr SYM opt_meta 段传输）；后端 g2_slot 负编码消费；判定 regalloc_verify_all 在 main.cr O2 路径；多字 tagged 识别已在 corearch（instr.cr）。
- 测试：回归 compile/ccr_v6/region_cfg/live_ranges/hit_table/mw1-6/backend_bootstrap 加 corec check。

---

### Task 1: opt.cr 按层切分盘点（语义与编码归属清单）

文件：分析产出，无代码改动，只有切分清单文档。

- 读 opt.cr 全部 1939 行，分类所有函数：语义优化（AST/IR 优化，留 corec）、编码决策（活区间/条目/共存/分配/判定，迁 corearch）、共享工具（grow/buffer，随迁或复制）。
- 产出切分清单（函数到归属加依赖图。迁入 corearch 的函数依赖哪些 corec 侧符号或全局，这些依赖也要迁）。
- 交付：清单文档（.superpowers 或 plan 附注），Task 2 及之后按清单执行。

### Task 1 切分清单（设计输入，2026-09-07）

> 交付物是本清单。Task 2 及之后按此执行。D-1/D-2/D-3 三个决策点须在 Task 2 动工前向用户确认（计划原 R1a/R2/R3 取向已获授权，本清单把它们落实为具体选择）。

### 归属清单

A 语义优化，留 corec（opt.cr 不迁）

| 函数（行） | 性质/依赖 | 调用点 |
|---|---|---|
| ast_is_const_int(11)/ast_const_val(17)/ast_bool_as_int(21)/ast_fold_binary(26)/ast_optimize_body(65) | AST 常量折叠（AST 层，非编码决策） | optimize_all（未使用代码，见下） |
| pass_cse(1819) | 线性流 CSE：NOP 加引用替换（iri_set_op 等）；依赖 iri_*/g_ir_func_* | main.cr:580（O≥1） |
| optimize_all(1917) | 编排器（ptr_analysis/region_check/provenance/AST fold/pass_cse/alloc/pass_stack_share 的 O 门聚合） | 全仓无调用者，是未使用代码（main.cr 566-588 直调各 pass）。拆分时须摘除其 alloc_registers()/pass_stack_share() 引用，否则 corec 闭包内符号悬空 |

B 数据面（存在区间/条目），归属随决策点 D-1（倾向迁 corearch 单主机）

| 函数（行） | 性质/依赖 | 调用点 |
|---|---|---|
| grow_live_ranges(198)/live_range_slot(205)/live_first(215)/live_last(220)/compute_live_ranges(228) | 区间表加逐函数扫描；尾部调 compute_entries 整表重建 | main.cr:505/514/520（cir dump 通道）、dataflow.cr:392（lower_to_ccr 尾，无条件执行，是 .ccr ENT 段唯一来源）、alloc_registers:1316 首行 |
| grow_entries(319)/grow_func_entry_meta(326)/ent_*(341-347)/entry_start(350)/entry_count(355)/compute_entries(360) | 版本条目表（ESZ_ENTRY 24B/条） | 同上（compute_live_ranges 尾部循环调用） |
| 依赖 | g_ir_live_ranges/count/cap、g_ir_entries/count/cap、g_ir_func_entry_*/g_ir_func_var_*/g_ir_func_instr_*/g_ir_func_count、iri_*(g_ir_instrs)、buf_read_i32(ccr_io.cr)、alloc/_dyncpy/r64/w64/w32 | corearch 闭包均有（entries 表由 load_ccr 重建：ccr_io.cr:1114-1183，含盘到内存的闭区间转换加 func 段界重建加 SYM first/last_ent 对照校验） |

C 判定族，迁 corearch（regalloc.cr），含注入测试钩子

| 函数（行） | 备注 |
|---|---|
| entries_coexist(544)/coexist_version_conflicts(560)/coexist_home_conflicts(591) | 共存（v6 Task 3；GC-1 越界守卫在 entries_coexist） |
| rl_rec_lt(694)/rl_merge_sort(704)/rl_print_loc(755)/rl_func_name(763)/rl_report_rule1(769)/rl_report_rule2(781)/rl_rule2_func(803)/verify_regalloc_consistency(872)/regalloc_verify_all(964) | 判定规则12（规约 regalloc-consistency.corespec）；LOC_HOME_BASE/RPT_MAX 文件内常量随迁 |
| meta_reg_for_var(670)/meta_reg_pair_off(1028)/meta_set_reg(1051)/meta_remove_var(1059)/meta_reg_assign_total(1101)/meta_append_reg_assign(1115) | g_opt_meta 读写侧辅助（镜像 instr.cr:33 get_reg_for_var 布局；迁后同进程，镜像收敛为直接消费） |
| try_inject_home_conflict(984)/inject_home_conflict(1013)/try_inject_reg_conflict(1136)/inject_reg_conflict(1163)/try_inject_read_gap(1179)/inject_read_gap(1229)/inject_coexist_oob(637) | 判定失败注入（cir --inject-* 测试实现方式；真实构建路径不注入） |
| 调用点（现状 corec） | main.cr:540（check-regalloc verify）、main.cr:587（O2 build verify 拦截）；dump_coexist_summary 经 main.cr:521 |
| 迁入依赖 | get_ir_var_name 定义在 ir_gen.cr:363（corearch 闭包没有），打印路径（rl_report_*/dump）会消费。处置：随迁迁移到 dyn_arr.cr（双侧共享位；dump.cr:45/dataflow.cr:460 的 corec 调用不受影响）；其余依赖同 B 加 g_opt_meta 表 |

D 分配，迁 corearch（regalloc.cr）

| 函数（行） | 备注 |
|---|---|
| label_pos_of(1303)/alloc_registers(1313) | CAG 上下文贪心（区头注释 1242-1302 含全部语义论证，随迁）；阶段 1-5：hazard 门控/回边携带/候选窗口/First Fit/meta 落块 |
| 调用点（现状） | main.cr:532（check-regalloc 强制 O2）、main.cr:583（O2 build）、opt.cr optimize_all（未使用代码，摘除） |
| 迁入依赖 | B 全部（alloc 首行 compute_live_ranges()，D-1 裁决它算不算第二次）、iri_*/irv_type（TI_DEX/TI_DYN/TI_UNIT 类型门）、IR_CONST/IR_REF/IR_I2F/IR_DYN_*/IR_JUMP/IR_BRANCH/IR_LABEL/IR_STORE 常量（ast.cr 双侧）、g_opt_meta 写侧 grow_opt_meta/store8（双侧）、g_opt_level（corearch CLI --opt-level 已接，corearch.cr:38-40；corec build 已透传：main.cr:644） |

E 栈共享，现状产物走死路径，处置随决策点 D-3

| 函数（行） | 备注 |
|---|---|
| pass_stack_share(1739) | 窗口共享填 g_stack_map；g_stack_map 不落 .ccr（ccr_io 无序列化），corearch.cr:7 启动置 ""，因此 instr.cr:64-67（g2_slot）消费恒不命中，对 ELF 产物零效果（现状空跑） |
| 依赖 | iri_*/g_ir_func_*/g_stack_map（instr.cr 侧读取在 g2_slot:64，恒空） |

F 调试通道，联动随决策点 D-2

| 函数（行） | 备注 |
|---|---|
| ir_op_kind_name(458)/dump_entries_summary(494)/dump_coexist_summary(620) | corec `cir --dump-entries/--dump-coexist` 实现方式（main.cr:504-523）；test_live_ranges.py 消费 |
| 判定注入族（C 组） | corec `cir --check-regalloc/--inject-*` 实现方式（main.cr:529-546）；test_live_ranges.py 消费（含 test_mw_task5 的 REG_ASSIGN 元断言读取通道？mw_task5 走 corec build O2 产物行为加 cir 元断言两种） |
| 说明 | corearch 已有 debug 命令先例（--table/--dump-events）；通道迁移即 corearch 加等价 flag 组加测试改道 |

### 现状链路（迁移基准，全部经实证或读码确认）

```
corec build/ccr:
  ir_gen_all（线性 g_ir_instrs 与 df 平行产出）
  然后 O≥1: pass_cse(580)        [作用于 g_ir_instrs]
  然后 O≥2: alloc_registers(583) [内 compute_live_ranges+entries；写 g_opt_meta REG_ASSIGN]
          regalloc_verify_all(587)，违反即编译错误
          pass_stack_share(588)   [写 g_stack_map，不落盘]
  然后 lower_to_ccr(591)          [自 df 重建 g_ir_instrs（CSE 前形态）；尾 compute_live_ranges+entries（重建流）]
  然后 save_ccr: SYM opt_meta 子节（g_opt_meta 块，key 0=REG_ASSIGN 有产物；key 1/2=STACK_SHARE/CSE 预留无写入者）+ ENT 段（28B/条，home 现状恒 -1，alloc 不回填 home）+ REG/SYM func first/last_ent 对照
corearch:
  load_ccr（g_opt_meta/entries/func 边界重建 + 校验）然后 init_backend_arrays（g_stack_map=""）
  然后 elf_gen 然后 g2_slot(54)：meta 查 g_opt_meta（g_opt_level≥1 门）得到 E2_REG_SLOT_BASE+reg；否则栈槽
```

### 待决策点（Task 2 动工前问用户）

- D-1 .ccr ENT 段去留（R2 细化，决定数据面单主机还是双主机）：
  - 方案 X（ENT 保留传输）：数据面生成留在 corec（lower 尾不变、cir 通道不动）；corearch 分配输入是载入 ENT 加自算 live ranges（盘上没有 var 级区间表），alloc 首行 compute_live_ranges 迁入即重算；数据面计算双主机，有语义变化风险，与「归属调整」目标相悖。
  - 方案 Y（推荐）：ENT 段始终为空或移出格式（loader 已支持段缺失等于空，pcnt=0 与 SYM first/last_ent=-1 对照；格式结构零改动，无 version bump）；数据面计算单主机 corearch（compute_live_ranges/entries/grow/访问器迁 regalloc.cr）；corec lower 尾摘除调用；save 侧 ENT 计数 0；SYM/REG first/last_ent 落 -1；「发射不依赖 ENT」见 ccr_io.cr:74 注，已确认。
- D-2 调试通道联动（随 D-1=Y）：corec `cir` 的 dump-entries/dump-coexist/check-regalloc/inject-* 实现方式与 test_live_ranges.py 改道 corearch（新 flag 组：--dump-entries/--dump-coexist/--check-regalloc/--inject-*，corearch load .ccr 后内存态即数据面）；corec 侧分支删除。D-1=X 则通道不动（数据面留 corec），仅判定注入随判定迁移面另行处置。
- D-3 pass_stack_share 处置：(a) 随迁并启用（行为新变：帧缩小。现状产物无共享，启用有行为差异风险，需要独立验证）；(b) 停用（推荐：产物零差异，调用摘除加 optimize_all 未使用代码同步清理；恢复列入未来 corearch 内以 alloc 同 seam 实现）；(c) 留 corec 空跑（现状，不调整归属）。

### Task 2: corearch 分配模块迁入（行为等价双跑验证）

文件：新建 src/arch/linux/ld/regalloc.cr（数据面加分配加判定迁入）加 corearch 闭包接线加 opt.cr 侧停用（O2 门不再调 alloc_registers）

- 迁移顺序：数据面（compute_live_ranges/entries/共存）、分配（alloc_registers 加 meta）、判定（verify）。依赖的全局表（g_ir_*）在 corearch load 后已有。
- 触发点：corearch load 后、emit 前（O2 时），替代 corec 传输。
- 验证：O2 行为等价（后端自算与原 corec 计算，迁移期间可以双跑对照 exit 和产物行为）。后端分配结果应等于 corec 原结果，过渡期测试逐变量 reg 对照。
- test_mw_task5 标记值（REG_ASSIGN 元数据通道）在 corearch 侧同进程消费，tag 表直接可读。

### Task 3: .ccr opt_meta 出格式（R2）

文件：ccr_io.cr（save/load SYM opt_meta 段移除或置空）加 test_ccr_v6/region_cfg walker 更新

- REG_ASSIGN 不再落盘，由 corearch 自算。opt_meta 段如何处理：全部移出还是只移出 REG_ASSIGN？若 opt_meta 只有此用途则整段移除，盘点时确认。
- ENT home 字段处置：分配回填只在 corearch 内存态，落盘始终为 -1，或保留字段，执行时按设计定稿决策。
- 格式版本：v6 内部再改还是 version bump？同仓同步 v6-only，内部改段即可。

### Task 4: 判定迁移（R3）

文件：verify_regalloc_consistency 等，已随 Task 2 迁移。触发点移到 corearch，emit 前 O2 自检，违反即编译错误。main.cr 的 corec 侧判定触发移除。

- 测试：判定失败注入用例在 corearch 路径仍然失败（--inject-* 通道移到 corearch）。

### Task 5: 表述清除 + CLI 语义（R5）

文件：opt.cr/g2_slot 注释「pure mechanical translation」清除，g2_slot 改述为后端槽解析 seam；corec `-O` 帮助和门语义（O1 留 corec CSE；O2 分配已在 corearch，corec -O 只影响 CSE；CLI 文案）；regalloc-consistency.cr 参考实现指针更新。

### Task 6: 回归 + 文档收尾

- 全套回归（含 mw1-6 标记值更新确认、backend_bootstrap、O2 自举可运行）。
- spec 状态（R1-R5 决定记录加实施完成）加 TODO 待办（如有残余）。

---

## 风险（评审注意）

- opt.cr 拆分依赖图遗漏（迁入函数引用未迁符号，导致编译错误。Task 1 清单完备性是关键）。
- 行为等价验证（迁移过渡双跑。corec 分配停用瞬间，O2 行为依赖 corearch 正确）。
- .ccr opt_meta 移除的 walker 和测试联动面。
- 多字 tagged 分配同侧整合（Task 5 标记值移到 corearch 内断言）。

---
