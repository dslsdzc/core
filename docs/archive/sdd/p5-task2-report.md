# R2 P5 Task 2 报告：DFNode.TK 单槽化（α），类型面单源 + 辅码分离 + `atom_of` 契约（零行为变化）

日期：2026-09-13 · 任务：`docs/superpowers/plans/2026-09-13-r2-p5-cleanup.md` Task 2（Step 1–6）
起点：`11913f8a`（P5 Task 1 提交；工作副本空、`jj status` 干净；`build/corec` = `8edb967f…`）
口径：cwd = 仓库根；全部命令 `nice -n 19`；一构建一编译串行（分段 `ps` 实查；一次自己造成的碰撞已登记，见 第 8 节-①）；比较任何 `.ccr`/缓存态产物前 `clean-cache`；数字全部本实例实跑。
交付：本报告（工作区，不入提交）+ 源码/测试/文档路径限定提交（第 9 节）。

---

## 0. 交付摘要（摘要）

| 项 | 结果 |
|---|---|
| 单槽形态（D19） | `OFF_DF_TK`(40) 语义 = 类型项引用（类型面唯一真源）；`OFF_DF_TK_TERM`(64) 更名 `OFF_DF_AUX` = 辅码（旗标/宽度/计数/不可逆行的原码；0 = 无）；`ESZ_DFNODE` 72B 不变 |
| 码 = 派生量 | `iri_tk` / `.ccr` NOD / `.cir` 快照一律 `sh_dfn_code_of_slots(项, 辅码)`；派生码不变量（D22-①）实测成立：88 档非自源 338,207 节点逐节点 diff 仅 F1 的 3 节点（已裁决偏差），其余 0 |
| F1 裁决实施 | `ir_gen.cr:1758` 补显式第 6 实参（`IR_HOTPATCH_ROUTE` = 无面 因此 `0`）：消除 r9 残留读；偏差 = 含 hotpatch 语料该节点码 4到0（3 节点，零消费者） |
| F2 裁决实施 | 分类表只覆盖原子行（`atom_of(项) == 行号`）；复合行由辅码槽保真（term = -1 ∧ aux = 原行码）因此 派生码逐字节 ≡ 旧混用码；5 个 `ti` 消费者的安全性审计 + 负控给出（第 4 节） |
| 盘面 | `.ccr` 两套口径冷态四条与基线逐条同；`--dump-objects` 逐字节同（2427 行）；`.cir` 快照布局/版本位零改动（`CIR_CACHE_VER` 保持 17、`CCR_VERSION` 保持 8） |
| ELF canary | `95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475`（28822B）IDENTICAL |
| 自测/套件 | `selftest-types` 367/367（355 + 12 新例）· `test_ccr_types` 40/40（从 34 增加到 40，增加 6）· `test_cir_warm_path` 19/19 · `test_cache_identity` 5/5（`VER_EXPECTED=17` 未动） |
| 全枚举 / CI | 56/56 rc=0 · 五 CI job 全 rc=0 · 自举链 `corec2==corec3` cmp IDENTICAL + N06=0 + 冒烟 42 |
| 影子对拍（下线前复跑） | `decisions = agree = 32767`，`old_stricter/old_looser/unknown*/replace_*` 全 0；非自源 67 档摘要与站点覆盖逐字节同（+147 决策全来自本任务新增的自源代码） |
| 突变控制 | 4 条逐条变为失败（分类表复合行 / 互斥破坏 / 派生面忽略辅码 / D23 越界门），第 6 节 |
| 判据重定（登记） | 冷/暖比对由「索引全等」改为「内容等价 + 派生码面逐行同」（暖态项索引/表长可小于冷态 = 预存缓存面局限，第 5 节-④） |
| 新硬错（D23） | 类型面行的可译性检查：emit 路径不可译 因此 `ccr_seg_prepare_save` 拒绝落盘（rc=1 + 诊断）；全语料 0 命中（report-only 先行） |

---

## 1. 单槽化形态与实现点（Step 2/3）

### 1.1 槽语义（`dyn_arr.cr`）

```
ESZ_DFNODE : int = 72;   // 9 槽，字节数不变（D19）
OFF_DF_TK   : int = 40;  // 语义变更（P5 T2）：类型项引用（g_type_terms 行号；-1 = 无项）
OFF_DF_AUX  : int = 64;  // 原 OFF_DF_TK_TERM 槽位更名：辅码（0 = 无）
```
四条契约落文件头注：① 字节零变化（盘面/版本位零改动）；② 互斥（D22-②，由拆分器构造保证）；
③ 码 = 派生量（不得当独立真源存/读）；④ 写点 = `df_create_node`（本文件零前端符号）
+ `.cir` 装载侧重派生（盘面只表示派生码；进程内项引用不得跨进程，D20）。

### 1.2 分类表 + 拆分器（`ty_shadow.cr`，唯一真源）

```
fn sh_tk_is_type_face(opcode) -> int     // {CONST, BINARY, ALLOC, CALL, LOAD, I2F, F2I}
fn sh_tk_row_state(tk) -> int            // -1 = 非行码（tk<0 合法）; 0 = 不可译; 1 = 可译
fn sh_atom_of_term(term) -> int          // D21: TT_ATOM ∧ b ≥ 0 因此 b; 否则 -1（不近似）
fn sh_tk_face_of_code(opcode, tk) -> int // 0 = 类型行面（项可逆）/ 1 = 辅码面 / 2 = 无面
fn sh_tk_split(opcode, tk)               // emit 路径（计 D23 失败位）
fn sh_tk_split_load(opcode, tk)          // .cir 装载侧（不计 ，见 第 5 节-④）
fn sh_dfn_code_of_slots(term, aux) -> int// 唯一派生点：aux≠0 因此 aux；无项 因此 0；否则 atom_of(项)
fn sh_tk_term_of_code(opcode, tk) -> int // 纯查询兼容入口（自测/诊断）
```

类型行面 = {`IR_CONST`, `IR_BINARY`} ∪ P4 六排除项的再裁 {`IR_ALLOC`, `IR_CALL`, `IR_LOAD`,
`IR_I2F`, `IR_F2I`}。再裁理由：P4 的排除依据是「后端不按 `ti` 分派」（发射面判据），
而单槽化的类型面是语义面（`tk` 表示的就是类型行）因此 该理由不适用；`IR_LOAD_ENUM_TAG`
两调用点传字面量 `0`（非类型语义）因此 保留「无面」。依据行 = p5-task0-report 第 2 节的 51 行表 +
Δ `emit` 调用点逐 op 审计（本任务复核 7 个类型面 op 的全部调用点：`CONST/BINARY` 传
`TI_*`/`const_type`/`fti`；`ALLOC` 恒 `TI_INT/TI_UNIT`；`CALL` 传 `ir_call_return_type(func_ni)`
（返回类型行，可为命名/序列/指针行 因此 复合行由 F2 路径兜住）；`LOAD` 传 `target_ti`
（`declared_ti` / cast 的 `alloc_type(TYP_PTR,…)` 行）；`I2F/F2I` 恒 `TI_DEX`）。

辅码面 = {`IR_BOUNDS_CHECK`（0/1 旗标）, `IR_DEREF`/`IR_STORE_PTR`（访问宽度 8/4/2/1）,
`IR_SPAWN`（spawn_count；-1 = 动态）, `IR_HOTPATCH_ROUTE`（F1 修正后 0）}；其余 = 无面。
数值陷阱（P4 实测、本任务自测复钉）：旗标 `1` = `TI_DEX` 行、宽度 `8` = `TI_DEX_S` 行 因此
分类必须逐 op（`t4.tk_bounds_flag1_rejected` / `t4.tk_deref_width8_rejected` /
`p5t2.aux_trap_rows_translatable` 三例；突变 M1 证明这两格有效）。

### 1.3 写点 / 派生点（逐点清单）

| 站点 | 改动 | 说明 |
|---|---|---|
| `ir_gen.cr::emit` | 一次 `sh_tk_split` 写入两槽；`iri_tk = sh_dfn_code_of_slots(两槽)` | 唯一拆分点：同一次拆分同时喂 DFNode 两槽与 `iri_tk` 因此 无第二真源 |
| `dataflow.cr::df_create_node` | 签名 `(…, tk_term, tk_aux)`；落 `OFF_DF_TK`/`OFF_DF_AUX`；`df_connect_srcs(…, tk_aux)` | 仅存储；零前端符号纪律保持；BOUNDS_CHECK 的旗标依赖改读辅码 |
| `dataflow.cr::lower_to_ccr` | `iri_set_tk(派生码)` | 重建面单源（本文件对桥接符号的唯一依赖，已注记） |
| `ir_gen.cr::arr_len_lit_of` | 读派生码（不是 40 槽） | `TI_STR` 判定；常量节点为原子行 因此 值同 |
| `cir_cache.cr` 写侧 | 节点盘记录写派生码 | 盘面逐字节不变（旧值 ≡ 派生码） |
| `cir_cache.cr` 装载侧 | 由盘码重派生两槽（`sh_tk_split_load`） | 时点 = emit 等价点（逐函数、逐节点序） |
| `provenance_verify.cr:57` | 宽度改读 `OFF_DF_AUX` | 该处读的是宽度（仅 DEREF/STORE_PTR 消费）；读 40 槽会把项行号当宽度 |
| `interp.cr:256/:546` | 读派生码 | `ir_interp_binary` 不消费该参（值同 因此 零行为变化） |
| `instr.cr` / `regalloc.cr` / `lower_to_core.cr` / `dump.cr` / `ccr_io.cr` | 零改动 | 读的是 `iri_tk`（派生码）因此 值逐节点同（判据见 第 3 节） |

---

## 2. F1 处置（裁决：修调用点）

事实（Task 0 实测 + 本任务读码复核）：`ir_gen.cr:1758` 的 `emit(IR_HOTPATCH_ROUTE, dest,
func_ni, first_arg_var, ac)` 只传 5 参（`emit` 形参 6 个）因此 第 6 参 = r9 残留
（corec 由 Python bootstrap 生成，`bootstrap/corec/backend/x86_64_stack_asm.py:222-226`
只为实际存在的实参写寄存器；自托管语义下缺省实参 = 0），同一语料不同程序形状实测 `0`/`4` 两值。

处置（协调者裁决：把未定义行为烘进分类表不可接受）：补显式第 6 实参 `0`
（`IR_HOTPATCH_ROUTE` 的类型面 = 「无」因此 显式「无类型」标记，与其余无面 op 的实参一致）。
已裁决偏差登记：含 hotpatch 语料该节点码从 4 变为 0（全语料 3 节点、仅 `hotpatch_test.cr`；
该值本是残留垃圾、零 `ti` 消费者、后端不按 ti 分派）。canary 语料 `ptr_arith` 不含 hotpatch
因此 canary 不受影响（第 3 节 实测）。pin：`p5t2.hotpatch_route_no_face`（自测）+ ㉞（python 语料面）。

---

## 3. 零行为变化判据（Step 5）

| # | 判据 | 命令 / 基准 | 结果 |
|---|---|---|---|
| 1 | 三二进制构建 | `nice -n 19 python3 build_selfhost_native.py` | rc=0；三面 `build log clean (error[ = 0, undefined = 0)`（GUARD 行） |
| 2 | 自源 check | `./build/corec check src/compiler` | rc=0 |
| 3 | 类型引擎自测 | `./build/corec selftest-types` | 367/367（355 增加 12：原子行契约/两槽正控/扩面 5 op/复合行走辅码 ×2/辅码面码值/数值陷阱复证/无面空槽/派生码契约/互斥/F1/D23） |
| 4 | 结构性断言套件 | `tests/selfhost/test_ccr_types.py` | 40/40（从 34 增加到 40，增加 6：㉜复合行走辅码 · ㉝互斥不变量 · ㉞F1 无面 · ㉟复合行冷/暖 · ㊱复合行 NOD 同序 · ㊲快照盘面派生码保真） |
| 5 | ELF canary | 先 `clean-cache`，再 `build tests/suite/ptr_arith.cr --static`，最后取 sha256 | IDENTICAL `95084e7b…d475`（28822B） |
| 6 | `.ccr` 冷态（两套口径） | `ccr F -o O` / `build F -o O --static`（各 `clean-cache`） | `ptr_arith` 90823B `fb4a3b59…` · `generics_test` 134701B `cafb4278…` · `--static` 同款 90966B `592afa31…` / 134844B `ec8413ec…` ，四条与 T1 起点基线逐条同（= T0 冻结值） |
| 7 | `--dump-objects` | T0 冻结 corearch vs 新 corearch × 同 `.ccr` | 逐字节同（2427 行） |
| 7b | `.cir` 面零变化 | T0 冻结 corec vs 新 corec × `cir tests/suite/ptr_arith.cr`：① DOT 产物；② `.core/cache/cir` 16 条快照 | ① 逐字节同（113980B）；② 快照 payload 16/16 逐字节同（仅头部「编译器身份」字段异 = TODO #5 的有意面：身份随二进制变） |
| 8 | 派生码不变量（D22-①） | 全语料 + 探针 94 档 × `cir --dump-tk-terms`（88 档出节点；3 档自源因源变更排除、3 档空文件）到 逐节点 `(op, tk)` diff | 338,207 节点：差异仅 `(op=39, 4到0) × 3`（= F1 已裁决偏差，仅 `hotpatch_test.cr`）；其余 0 |
| 9 | 全枚举 | `tests/selfhost/test_*.py`（49）+ `tests/bootstrap/*.py`（7） | 56/56 rc=0 |
| 10 | 五 CI job | `CI_JOB_NAME=<j> bash src/ci/run.sh` ×5 | 全 rc=0（check / bootstrap-tests / selfhost-tests / suite / full-bootstrap） |
| 11 | 自举链 | full-bootstrap job，然后 `cmp /tmp/corec2 /tmp/corec3`，再检查 N06 和冒烟 | IDENTICAL + N06=0 + 冒烟 42 |
| 12 | 自举回归套件 | `python3 tests/selfhost/test_backend_bootstrap.py` | rc=0 + 构建日志 `error[` = 0 |
| 13 | 开工起点基线（同任务起点） | T1 二进制 × 当前源：canary/`.ccr`/94 档 dump/72 档 `check` | 见 第 8 节 证据路径；`.ccr` 四条与 第 3 节-#6 逐条同（因此 判据面完整流程） |
| 14 | 其它套件 | `test_cir_warm_path` / `test_cache_identity` / `test_type_engine` / `test_compile` / `test_purity` / `test_optional` | 19/19 · 5/5（`VER_EXPECTED=17` 未动）· PASS · PASS · PASS · 34/34 |

### 3.1 语料同源对拍（72 档 `check` 面；起点基线 vs 最终）

* rc 分布：两侧 34×0 / 38×1（逐档 rc diff 空）。
* 日志 diff：2 档（`t2_src_compiler__import.cr` · `t3_src_compiler_ccr_io.cr`），逐行核 = 仅源码行号位移（`28772` 变为 `28964` 等；本任务给自源加了 ~190 行）因此 非语义差异。

### 3.2 影子对拍（T5 前「每任务复跑」纪律；最终二进制 × 最终源）

* 聚合（72 档跑、70 档出摘要）：`decisions = agree = 32767`；`old_stricter / old_looser /
  unknown / unknown_bridge / unknown_engine / unknown_engine_budget / unknown_engine_uncovered /
  replace_bridge / replace_unknown` 全 0。
* 逐档：摘要与站点覆盖的 mismatch = 恰 3 档自源文件（`src/compiler/main.cr` / `_import.cr` /
  `ccr_io.cr`，本任务改了这三处源码）；其余 67 档逐字节同。
* 站点覆盖同报（最终）：`assign-node=24838 · fn-body-ret=5855 · if-branch=2040 ·
  struct-field-type=28 · array-elem-type=4 · generic-apply-base=2`（Σ = 32767 = decisions，互相校验）；其余 4 站 0（含站点 6 = 0 命中）。T0 起点为 `24721/5828/2037/28/4/2`（Σ 32620），
  增量 +147 全部来自自源三档（本任务新增源码），非语义面变化。
* 继承声明：影子通道对实现方式面零覆盖（本任务的实现方式证据 = 结构性断言 + canary + 直方图，见 ①）。

---

## 4. F2 裁决与证明（协调者要求的「审计 + 探针 / 负控」）

裁决（协调者）：分类表只覆盖原子行；复合行显式派生 -1（`atom_of` 契约，不得近似）。
实施（对应 Task 0 候选 (iii)+(ii)）：类型面 op 的行若非「项可逆」（`atom_of(sh_term_of_ti(tk))
== tk` 不成立）因此 不建项（term = -1），原码进 辅码槽（`aux = tk`）因此 派生码逐字节 ≡ 旧混用码。

原子性判据：类型行面只接受 `TT_ATOM ∧ b ≥ 0` 的项（b 槽即行号）。可逆行 = 基类型行
（`TI_INT/DEX/DEX_S/BOOL/STR/UNIT/CHAR/NEVER`）+ `TYP_DYN` + `TYP_NAMED`/`TYP_GENERIC_PARAM`/
`TYP_GENERIC_APPLY`（后三者的项是 `tt_atom(AK_NAMED, ti, -1)`，b = 行号 因此 可逆）；
不可逆（复合）= `TYP_PTR`/`TYP_REF`/`TYP_ARRAY`/`TYP_SLICE`/`TYP_OPTIONAL`/`TYP_NULL`/`TYP_TUPLE`
（项为 `AK_PTR(b=-1)`/`AK_SEQUENCE(b=N 或 -1)`/union/product/`AK_NULL(b=-1)`）。

普查（全语料 + 探针 94 档，实测）：
* 复合行节点 恰 1 个：`tests/suite/ptr_ref_first.cr` 节点 9 = `op2(BINARY) tk=10`（指针行，
  Task 0 F2 实测同款）；自足夹具（`&arr[1]` + `p+1`）另证 `op2 tk=13` 同形态。
* 辅码面节点：`op27(SPAWN) aux=-1 ×3`、`op25(DEREF) aux=8 ×1`、`op26(STORE_PTR) aux=8 ×1`；
  其余 op 的 `aux_nonzero = 0`（`*_ptr_arith` 2 · `*_ptr_ref_first` 1 · `p_spawn` 3 档）。
* 类型面 op 节点总数 304,855（其中 `tk<0` = 0 ，语料无「无类型路径」样本，代码面已覆盖）。

5 个 `ti` 消费者的安全性证明（方法 = ① Task 0 的机器审计复核 + ② 本任务的「值敏感面」
逐点核 + ③ 逐节点直方图负控）：

| 消费者 | 谓词 | 复合行（码 10/13）经此 | 结论 |
|---|---|---|---|
| `instr.cr:485` `IR_CONST` | `ti == TI_STR`(3) | 复合行只在 `op2` 出现（`op1` 的 tk 全域实测 ∈ {0,1,2,3,8} 全为原子行） | 不变 |
| `instr.cr:518` `IR_BINARY` | `ti == TI_DEX`(1) | `10 ≠ 1`（旧值也是 10） | 逐字节同支 |
| `instr.cr:1101/1132` `IR_DEREF`/`IR_STORE_PTR` | 宽度（`e2_ptr_bounds_check`） | 两 op 属辅码面（宽度 8 保真，与旧值同） | 不变 |
| `instr.cr:1340` `IR_BOUNDS_CHECK` | `ti != 0` | 辅码面：旗标 1 保真、旗标 0 因此 `aux=0` 因此 派生 0（旧值 0） | 不变 |
| 旁路：`regalloc.cr:457` | `tk == TI_DEX ∨ TI_DEX_S`（1/8） | `10/13` 皆不等（旧值亦不等） | 不变 |
| 旁路：`lower_to_core.cr:250/574` · `ir_gen.cr:129` | `IR_CONST` 的 `TI_STR` | 同 `op1` 行域（原子） | 不变 |
| 旁路：`dump.cr:125` | `IR_ALLOC` 文本 | `IR_ALLOC` 语料 tk ∈ {4, 0}（原子行） | 不变 |
| 旁路：`interp.cr:256/546` | 传 `ir_interp_binary`（函数体不消费） | 值同 | 不变 |
| 旁路：`provenance_verify.cr:57` | 宽度（读点已改读辅码） | 同宽度面 | 不变 |

负控（有效的反证）：本设计下复合行码逐字节保真，故「消费者读到 -1」这一支未发生
（比裁决要求的「读 -1 行为等价」更强：读到的就是旧值本身）。为证明即使走 (iii) 的 -1 分支也
安全，另做了两个方向的反证：① `p5t2.slot_composite_row_to_aux` / ㉜ 逐节点断言
`term == -1 ∧ aux == tk ∧ 派生码 == tk`（非空：两处语料都必须出现该形态）；② 突变 M1（复合行
也入项槽 因此 派生码 -1）因此 直方图与断言同时变为失败（第 6 节），即「分类表这一格的错」是可被抓住的，
不是「看起来没变」。

---

## 5. 登记面（不不报错地，逐条给证据级）

① F1 偏差：含 hotpatch 语料 `op39` 码 `4到0`（3 节点）；该值原是 r9 残留垃圾、零消费者。
   本任务修根因（显式实参）而非把 UB 写进表；偏差由 第 3 节-#8 的逐节点 diff 精确量化。
② D23 判据面 = emit only：装载侧不计数。理由：盘码可能落在暖进程更小的类型表之外
   （见 ④），这不是本进程的编译器 bug；缓存命中绝不因此让编译失败（首轮实测曾触发一次
   误拒，`test_p5t2_ccr_nod_composite_parity` 失败态抓出，已按根因收口）。
③ D23 全语料 0 命中（report-only 先行）：94 档 dump 的 `face_fail` 全 0 因此 检查门开启无
   语料代价；检查的有效性由突变 M4 证明（越界行 因此 rc=1 + 诊断 + 无产物）。
④ 预存缓存面局限（P6 承接）：暖态类型表/项表可小于冷态，缓存命中跳过该函数的 IR
   生成，而 `ir_gen` 自身 `alloc_type` 新行（`ir_gen.cr:1277/:1283/:2434/:2491/:2792` 的
   addr/ref/cast/数组行）因此 冷态存在的行暖态不存在 因此 引用它的节点暖态项不可重建
   （`term = -1`）。实测：通用夹具 `rows` 16到13 / `terms` 18到17；复合夹具同形态。
   影响面：仅内存项槽；派生码面（op,tk,aux）逐行相同 因此 发射面/盘面零影响
   （P4 的窄清单掩盖了它：CONST/BINARY 的行皆由 checker 建；P5 扩面后暴露）。
   因此 判据随之重定（㉙/㉟）：内容等价（tag/a/b/c）+ 派生码面取代「索引全等」；索引/表长
   允许变化，缺失项只允许出现在「行越出暖表」处（精确形态断言，非放宽）。
   根治 = β 盘面项索引（P6 交接包附录 E-1）。
⑤ `.cir` 快照零改动：写侧仍 8×8B/节点（写派生码）、读侧两槽重派生；`CIR_CACHE_VER` 保持 17、
   `test_cache_identity.py:VER_EXPECTED` 未 flip（`test_cache_identity` 5/5 实测）。
⑥ `test_ccr_types.py` 判据重定（同 ④）：㉙ 由「header 全等 + 行全等」改为「派生码面 + 项内容
   等价 + 缺失项精确形态」；已在用例 docstring 与 run.sh 注释落纸。
⑦ 未覆盖面（不不报错地）：`tk < 0` 的类型面路径（`IR_LOAD`/`IR_CALL` 的未定型路径）在语料/探针
   中 0 样本 因此 只有代码面 + 自测（`sh_tk_row_state` 的 `-1` 分支）覆盖；不假装有语料证据。
⑧ 性能：`emit` 每节点一次分类查询（无面 op = 几次整数比较；类型面 op = 桥接缓存查询）；
   分类查询内部的 `sh_term_of_ti` 命中不计入影子计数（hits 复原包住整个拆分函数，含分类
   查询自身；该复原最初漏了分类查询，被 `t4.tk_derivation_not_a_shadow_site` 抓出失败后修正）。
   未做微基准（P4 T4 已测该路径无回退；本任务只增比较次数，量级 = 10^-8s/节点）。

---

## 6. 突变控制（4 条；`/tmp` 侧实拷贝构建，仓库源码零改动）

harness = `/tmp/p5t2/mut/{m1,m2,m3,m4}/`（`build_selfhost_native.py` + `bootstrap/` + `src/` 实拷贝 +
`tests` 软链）；变异点逐条：

| 突变 | 内容 | 期望 | 实测 |
|---|---|---|---|
| M1 | `sh_tk_face_of_code`：删「项可逆」判据（复合行也入项槽） | 派生码面变为失败（F2/D22-①） | 见 第 6.1 节 |
| M2 | `sh_tk_split_impl` 的 else 分支同时写项槽 | 互斥不变量变为失败（D22-②） | 见 第 6.1 节 |
| M3 | `sh_dfn_code_of_slots` 忽略辅码（只 `atom_of(项)`） | 派生码面变为失败（旗标/宽度丢失） | 见 第 6.1 节 |
| M4 | `emit` 传 `g_type_count`（越界行） | D23 检查：rc=1 + 诊断 + 无产物 | 见 第 6.1 节 |

### 6.1 实测结果

变异面逐条实核（`diff -r -x '*.cir'` = 恰一处一行；仓库侧 `*.cir` 为忽略件不参与）：

```
m1  ty_shadow.cr:  if sh_tk_row_state(tk) == 1 { if sh_atom_of_term(...) == tk { return 0; } }
                因此  if sh_tk_row_state(tk) == 1 { return 0; }          // 复合行也入项槽
m2  ty_shadow.cr:  g_sh_slot_aux = tk;  因此  + g_sh_slot_term = sh_term_of_ti(tk);   // 两槽同置
m3  ty_shadow.cr:  if tk_aux != 0 { return tk_aux; }  因此  删（辅码被忽略）
m4  ir_gen.cr:     sh_tk_split(opcode, type_kind)  因此  sh_tk_split(opcode, g_type_count)   // 越界行
```

四条全部构建 rc=0（mutant corec sha ≠ 仓库 `e3814ad8…`：`5a490ecb…`/`ed6ea059…`/`1c01b5ff…`/`21fdb674…`）。

| 突变 | 定向判据 | 实测（变为失败） |
|---|---|---|
| M1 复合行也入项槽 | 自测 + `--dump-tk-terms` 直方图 + python ㉜ | 自测 365/367（`p5t2.slot_composite_row_to_aux` / `slot_array_row_to_aux` FAIL）；`ptr_ref_first` node 9 = `op2 tk=-1 term=13 aux=0`（正常 = `tk=10 term=-1 aux=10` 因此 派生码从 10 变为 -1 = D22-① 破坏，被抓住）；python ㉜ FAIL `prf node 9: non-row item in term slot (term=13 b=-1)` |
| M2 两槽同置 | 自测互斥例 + python ㉝/㉖ | 自测 361/367（`slot_mutual_exclusion` / `slot_aux_face_codes` / `slot_none_face_empty` / `hotpatch_route_no_face` / `slot_array_row_to_aux` FAIL）；㉝ FAIL `prf node 9: both slots set (term=13 aux=10)`；㉖ FAIL `node 0: non-mint op 32 got term 10` |
| M3 派生面忽略辅码 | 自测 + 直方图 + python ㉖ | 自测 363/367（`slot_aux_face_codes` / `code_derivation_contract` / 复合行两例 FAIL）；`ptr_arith op=25/26 tk=0 aux=8`（正常 = `tk=8`：访问宽度被吞掉）；㉖ FAIL `node 18: derived code 0 != aux 8`；canary 仍 IDENTICAL（该语料的宽度值未改变发射字节，故必须靠直方图/断言抓，正是本设计给它们留的位置） |
| M4 emit 传越界行 | D23 检查（端到端） | `corec ccr` rc=1 + `error: 456 type-face DF node(s) with untranslatable type row — refusing to save .ccr (D23)` + 无产物；对照（仓库二进制同源）rc=0 + 产物 YES 因此 检查有效、且不误伤正常路径 |

M1 的额外收获（用例强化）：M1 首跑暴露 ㉜ 的过滤式断言存在「tk 也被算成 -1 因此 自洽掩盖」的漏洞，因此已补直接反证「项槽不得出现非行项（`term ≥ 0 ∧ tag == TT_ATOM ∧ b < 0`）」+ ㉖ 的 `b ≥ 0` 断言；补后 M1 的失败消息变精确（`non-row item in term slot (term=13 b=-1)`），仓库二进制同两例仍通过（无假阳性）。这是突变控制的主要价值面：抓的是判据的漏洞，不只是实现的错。

---

## 7. 判据重定与口径（登记）

* 冷/暖判据（第 5 节-④）：`test_ccr_types` ㉙/㉟ 改用内容等价 + 派生码面；`rows/terms/with_term`
  的冷/暖差异是预存的（P4 T7 勘误已量化「TYPE 行表 热 12 / 冷 15」= 同一根因）。
* `.ccr` 记录值：引用一律带口径 + 缓存态（第 3 节-#6 四条均为冷态；两套口径差恒 143B 未变）。
* 影子通道：仍在下线前（Task 5 面）；本任务按其纪律复跑并同报站点覆盖与差异数（第 3.2 节）。

---

## 8. 执行纪律与偏离（诚实登记）

① 一次自造碰撞：基线运行（Step 0）尚未收尾时我并发跑了一次 python 套件（同缓存目录）
   因此 两条用例出现假失败（「暖运行重写了缓存条目」/ 头部变化）。已识别并按纪律重跑：
   所有最终判据均在无并发窗口串行复跑（本报告引用的数字全部来自该窗口）。登记为操作教训
   （runner 的 clean-cache 与测试的缓存快照不可并发）。
② 首轮实现把 `hits` 复原只包住 `sh_term_of_ti` 一处（分类查询遗漏）因此 `t4.tk_derivation_not_a_shadow_site`
   变为失败；已按根因修正（复原包住整个拆分函数 + 兼容入口），修正后 367/367。
③ 首轮实现让 D23 检查对装载侧也计数 因此 暖态（缓存命中）误拒一次
   （`test_p5t2_ccr_nod_composite_parity` 失败态抓出）因此 按 第 5 节-② 收口为 emit-only。
④ 判据重定 2 处（㉙/㉟）与新增 `rows=` 观测列（dump 头）已同批落纸（第 5 节-⑥/第 7 节）。

### 8.1 证据路径（本机）

* 基线：`/tmp/p5t2/{base_bins.sha,canary_base.txt,rec_*.txt,base_tkhist/,parity/base_check/}`
* 最终：`/tmp/p5t2/{final_bins.sha,final_canary.log,pa_ccr4.ccr,gen_ccr4.ccr,objs_new4.txt,new_tkhist/}`
* 判据日志：`/tmp/p5t2/{final_battery.out,final_*.log,parity/final_check/,final_ci_*.log,final_enum.out}`
* 突变：`/tmp/p5t2/mut/{m1,m2,m3,m4}/` + `/tmp/p5t2/mut_results.md`
* 驱动脚本：`/tmp/p5t2/{step0_baseline.sh,criteria.sh,final_battery.sh}`

---

## 9. 提交（Step 6；路径限定）

提交 = `7f6c38cb`（change `oxkxlswn`；`jj diff -r 7f6c38cb --summary` 核过 = 恰 16 路径，`src/`/`tests/`/`TODO.md`/计划）：

```
refactor: R2 P5 Task 2，DFNode.TK 单槽化（α）：OFF_DF_TK=类型项引用（类型面唯一真源）+
OFF_DF_TK_TERM到OFF_DF_AUX=辅码（旗标/宽度/计数/不可逆行的原码），ESZ_DFNODE 保持 72B
因此 布局与版本位零改动（CCR_VERSION=8 · CIR_CACHE_VER=17）；码=派生量（…）；
分类表（Task 0 表 A 代码化）+ F1/F2 裁决实施 + D23 新硬错 + 消费点逐点核；
判据 = selftest-types 367/367 · test_ccr_types 40/40 · canary IDENTICAL · .ccr/.cir
零变化 · 派生码不变量（94 档 338,207 节点 diff 仅 F1 的 3 节点）· 全枚举 56/56 ·
五 CI job · 自举链 · 影子对拍 · 构建确定性 ×2 · 突变控制 4 条；登记：暖态表可更小（P6）
```

文件（16）：`TODO.md` · `docs/superpowers/plans/2026-09-13-r2-p5-cleanup.md`（Task 2 六步勾选 + 实施记录）· `src/ci/run.sh`（selftest 计数 355到367 / `test_ccr_types` 34到40 注释）· `src/compiler/{ty_shadow,dyn_arr,dataflow,ir_gen,cir_cache,dump,provenance_verify,interp,globals,checker,ccr_types,type_selftest}.cr` · `tests/selfhost/test_ccr_types.py`。

提交后 `jj status` = 工作副本干净（空提交 `324d7331`）。本报告与其它 `docs/archive/sdd/*` 报告同档：不入版本控制。

---

## 10. 给 T3+ 的输入

* `sh_*` 分类表已就位：T3（unknown 清零）不触本文件面；T4/T5 删 legacy/影子层时
  不得动 `sh_tk_split`/`sh_dfn_code_of_slots`（它们是实现方式面单源，非判定面）。
* D20 稳定引用形态：本批盘面只表示派生码（进程内项引用零跨进程），β（P6）若落盘项索引，
  前置 = 本报告的 F2/原子行判据 + `atom_of` 契约。
* 冷/暖项面差异（第 5 节-④）若在 T3–T7 的判据里再现，按本报告的精确形态断言处理（勿回退到
  「索引全等」，那是 P4 窄清单期的偶然性质）。
