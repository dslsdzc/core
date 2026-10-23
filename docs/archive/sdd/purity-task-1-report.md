# 效应/纯度修正 Task 1 报告：真纯度计算（根因修复）

状态：完成（实现 + 红态 + 判据 + 证据链）。提交：`mkztxuuuortn` / `762bd4293871ac5949ba332009c4ea4425c38f93`（提交信息见 第6；提交后复验 ELF 仍 `95084e7b…d475` IDENTICAL）。

一行结论：`fi_ispure` 由「乐观常量 1」改为全程序 IR 面真计算（store 族/效应 opcode/传递闭包/SCC 保守 + 泛型实例到源合取），
state 链相随后移到 IR 生成结束点重建；`selftest-purity` 17/17、`selftest-types` 95/95、全回归 37/37 rc=0、
ELF 逐字节 `95084e7b…d475` IDENTICAL、自举 `corec2`/`corec3` CMP_IDENTICAL + N06=0/0 + 冒烟 rc=42。

---

## 0. 头号发现：计划给的时点不可执行；且 `fi_ispure` 有第二个（发射面）消费者

发现 1（计划自相矛盾）：Task 1 brief 要求「扫描每个函数的 IR 体（`g_ir_func_instr_start/instr_count`），时点 = `check_all()` 尾部」
，但 IR 体在 check_all 期并不存在：IR 生成是独立的后续阶段（`ir_gen_all()`：`ir_gen.cr:2694`；文件路径主循环：`main.cr:434+`），
`g_ir_func_instr_start/count` 在 `ir_gen_func`（`ir_gen.cr:2240/2299`）与文件路径缓存分支（`main.cr:497`）里才被写。
实测：check_all 尾部 `g_ir_func_count == 0`。因此 「IR 体扫描」与「check_all 尾部」二者不可兼得。

发现 2（更关键：纯度不是只有链一个消费者）：`fi_ispure` 的第二个读取点 `ir_gen.cr:1590` 是 lazy thunk 判定，
而 `IR_LAZY_THUNK` 是真实发射的 11 字节代码（`src/arch/x86_64/instr.cr:1362`：load+store，非空操作）。今日值恒 1 因此 几乎每个可解析调用都被包 thunk。
真纯度一旦在 IR 生成期可见，被调者不纯的调用不再包 thunk 因此 NOD/指令流改变 因此 ELF 必变。
实测取证（旧编译器 `cir` 语料 `tests/suite/ptr_arith.cr` 单元，16 函数）：按 store 族判据，`str_len/chr/get_char/str_sub/str_eq/str_cmp/concat/int_str/str_int/format/format_int/fpow2i/float_str_bits`
13 个函数不纯；该单元 21 个 `lazy_thunk` 中相当一部分挂在 `int_str/format/str_sub/fpow2i/str_len` 的调用点上。

因此 「真纯度 + 生成期可见」与「ELF 逐字节不变 + 禁止动 lazy」不可兼得。本实现取二者交集：

| 约束 | 落法 |
|---|---|
| 真纯度必须进 state 链（本批目的） | `compute_all_purity()` 在 IR 生成结束后写回 `fi_ispure`；链的连接（`df_connect_state`）相随后移 |
| ELF 逐字节不变（硬判据） | IR 生成期 `fi_ispure` 仍持 checker 的乐观默认值 = lazy 判定输入逐位不变 因此 发射面零改动 |
| 禁止动 lazy（硬约束） | `ir_gen.cr` 一行未改（lazy 代码、判定输入、thunk 发射全部原样） |

对 brief「时点由你定，但须说明为何安全」的回答：纯度必须在 `df_connect_state` 可读到真值之前就绪。
两条路，(a) 把纯度来源提前到 IR 之前（AST/checker 面），(b) 把链的连接后移到纯度之后。
选 (b) 的理由：纯度的权威面是 IR opcode（计划自己指定；dataflow 的分类表也按 opcode 说话），
AST 面缺少表达式类型（例如 `a+b` 与 `s+t` 的 store 触发差异要靠类型才知道）因此 (a) 会引入第三套效应判据且易与 IR 发散；
而链的迁移是纯结构重放，其保真性可被逐边对拍证明（见 第4.2）。

---

## 1. 实现

### 1.1 真纯度计算（`src/compiler/checker.cr:2891-3086`）

```
fn purity_op_effect(op) -> int        // 局部效应/硬不纯 opcode 面
fn src_func_of_ir(irf) -> int         // IR 函数序 到 源 FuncInfo 序（按源序跳过泛型重放）
fn df_func_of_node(pos) -> int        // DF 节点 到 所属 IR 函数（unsafe 区归属用）
fn compute_all_purity()               // 唯一入口
fn fi_ispure_of(name_ni) -> int       // 自测辅助（-1 = 无此函数）
```

纯（1）⟺ 全部成立（一律保守；出处 `plans/2026-08-08-region-cfg.md:484`）：

1. 体无 store 族：`IR_STORE / IR_STORE_FIELD / IR_STORE_INDEX / IR_STORE_INDEX_VAR` + `IR_STORE_PTR`（原始指针写同为效应，brief 未列 = 保守加面）；无 unsafe 区（IR 无 unsafe 专用 opcode，按 `SG_UNSAFE` 区的归属函数判定，归属 = 区起始节点落在哪个函数的节点区间）。
2. 体无 IO/FFI/并发效应 opcode：`IR_CALL_EXTERN / IR_HOTPATCH_ROUTE / IR_DYN_DISPATCH / IR_SPAWN / IR_YIELD / IR_AWAIT`（brief 只点名 extern；其余 5 个按 Task 2 的链分类表对齐，保守方向）。
3. 传递闭包内被调者全纯：`IR_CALL` 的 s3 = 名 ni 经 `find_func` 解析，不可解析（runtime builtin）因此 不纯；`IR_INLINE` 的 s1 同为名 ni（同样不可解析 因此 不纯，内联提示不复制被调者体，其效应在调用者指令里看不见）。
4. 递归/SCC 因此 保守不纯：不动点从「全不纯」起点升纯，自环/互环永远等不到「被调者已纯」因此 自动留在不纯，无需显式 SCC 检测（这也是为什么不需要 Tarjan）。

不动点实现（保守单调、无 worklist）：

```
局部位 local[fi]  ← 扫体（效应 opcode / 不可解析调用 / extern 声明 / unsafe 区 / 映射复核失败）
pure[fi] ← 0（全不纯起点）
loop changed:
    pure[fi] := 1  当且仅当  !local[fi] ∧ 该函数全部可解析被调者已 pure
    直至无变化（每轮 O(N)，轮数 ≤ 调用图深度；实测 corec2 全量构建与基线同量级，见 第5.3）
```

调用边在第一遍解析好并写在 `callee[指令下标]`（`find_func` 每调用点只查一次，计划的 O(F²) 风险点集中在此，实测见 第5.3）；
`alloc` 不保证清零（rt.s bump 分配器）因此 `local/pure/callee` 三表逐项显式初始化。

泛型（偏差，见 第7.2）：实例有自己的 IR 体 因此 纯度由自身体计算（型替换后效应结构可能不同：`T=string` 的 `+` 走 concat + store）；
源函数（无 IR 体、永不被调用）纯度 = 实例的合取（无实例 = 0）。二者合起来使「实例与源同值」恒成立，
取代 brief 的 `monomorph` 继承写入，该写入在本时点是错的：它抄的是乐观默认值 1，
会把有效应泛型（`fn gid[T](x:T)->T{ gst:.,mut=0; gst=1; return x; }`）的实例错标为纯（红态 第3 实测两例）。

### 1.2 state 链迁移（`src/compiler/dataflow.cr:160-252`）

```
df_connect_state(node_id, opcode, s3)     // 本体与签名未改（Task 2 的改动面原样保留）
df_state_close_regions_at(head, next, pos) // 循环终止规则（原 sg_pop 块，逐句复刻）
df_replay_state_chain()                    // 成品图重放：每函数链头重置 + 关闭位触发规则
df_state_finalize()                        // = compute_all_purity() + df_replay_state_chain()
```

- `df_create_node` 不再即时连链；`sg_pop` 的链块（终止边 + 链头推进）整块移入重放（不在两处重复）。
- 重放保真要点：节点创建序 = 程序序；`g_last_state_node` 每函数重置（与 `df_begin_func` 同语义）；
  关闭位 = 该区 `OFF_SG_EXIT`（= 关闭时 `g_df_node_count`）因此 `last_node = pos-1`，守卫（区非空 ∧ 链头在区内）逐句照抄；
  同位置的多个区按区号降序处理（= `sg_pop` 的 LIFO 关闭序）；每关闭位恰好处理一次（函数末端处理 `start+cnt`，下一函数走 `n=0` 时跳过 `start`）；
  函数 0 的 `start`（位 0）无人处理，但那里 `last_node = -1 < nstart ≥ 0` 因此 规则恒 no-op（已注）。
- 两个调用点（链消费者之前）：`ir_gen_all()` 尾（run / `dump.cr` 的 cir 路径）与 `main.cr:524`（build/ccr/cir 文件路径，位于 `cir` 转储 / 区域检查 / `lower_to_ccr` / 保存 `.ccr` 之前）。
- cir 缓存版本 14 到 15（`cir_cache.cr`）：快照不再持久化链边（链在保存时尚未建立）；旧快照带链边 + 重建再连一次 = 重复链边，必须失效（cache miss = 无害重建）。

### 1.3 新增自测通道

- `src/compiler/purity_selftest.cr`（198 行）+ CLI `selftest-purity`（`main.cr`）+ `tests/selfhost/test_purity.py`（驱动，`MIN_CASES = 17`）。
- 通道自建最小管线（tokenize 到 res_imports 到 parse_all 到 check_all 到 ir_gen_all，与 `run` 路径同序），
  断言 IR 生成后写回的值 + state 链边集语义（4 例：效应调用被链穿过 / 纯调用不被触及 / 循环终止依赖 / 无循环无 label 边负控）。

---

## 2. 判据汇总

| # | 判据 | 结果 |
|---|---|---|
| 1 | `selftest-purity` | 17/17 PASS，rc=0（`tests/selfhost/test_purity.py` PASS） |
| 2 | `selftest-types` | 95/95 type-engine cases passed（无回归） |
| 3 | 全回归 37 套件 | 37/37 rc=0（含 `test_ccr_v7` 24/24、`test_compile`、`test_backend_bootstrap`、`test_lsp`） |
| 4 | ELF 逐字节 | `95084e7b…d475` IDENTICAL（ptr_arith.cr，`cmp` 通过） |
| 5 | ELF 变化面证据（链已变程序） | `chain_probe.cr` 链 +26 边 因此 ELF 仍逐字节相同（`bbdee11a…9973`） |
| 6 | `.ccr` 变化实测 | 仅 kind=1 边增长：ptr_arith +24（293到317）、chain_probe +26；NOD 与 kind=0 数据边逐字节不动（见 第5） |
| 7 | 自举 `corec2`/`corec3` | CMP_IDENTICAL（`e5ec38d2…70`）· N06=0/0 · `error[`=2/2（既有 TF01，基线与本实现同数） |
| 8 | 冒烟 | `corec run 'fn main()->int{return 42;}'` rc=42；`corec2` 同 rc=42；`corec2 selftest-purity` 13/13（旧表）/ 17/17（终表） |
| 9 | 链语义（Task 1 目的） | 效应调用 `store 到 call 到 store` 被链穿过（red 态 got 0）；纯调用同形下 `touch == 0`；循环终止边在（重放复刻成功） |

`test_ccr_v7` 实话实说：未红（24/24 全 PASS，期望表 41/13 未动）。
原因：该 fixture 里唯一的可解析调用是 `pure_add`（本批判为纯 因此 无调用边，与旧一致），其余调用全是 runtime builtin（`find_func < 0`，新旧都入链）；
故其 EDG 期望天然不变。但本批的 `.ccr` 变化面是真实的（见 第5 实测），Task 3 的更新基准值若需要，应针对「含可解析不纯调用」的语料。

---

## 3. 红态（TDD Step 1-2：先有测试、无实现）

红态复现法（不触碰本工作区文件）：用 `jj workspace add -r @- /tmp/purity-recon/base` 取改动前源树，
只把测试脚手架（`purity_selftest.cr` 原样 + `fi_ispure_of` 十行 + CLI 两行 + 清单两条）放进去，
不放任何实现（无 `compute_all_purity`、无链迁移、`ir_gen.cr`/`dataflow.cr` 零改动）因此 即 brief 的「Step 1 写用例」状态。

```
$ nice -n 19 ./build/corec selftest-purity           # 红态树（@- 源 + 仅脚手架）
PASS purity.pure_add
PASS purity.pure_caller
FAIL purity.effect_store: got 1 want 0
FAIL purity.call_effect: got 1 want 0
FAIL purity.call_extern: got 1 want 0
FAIL purity.call_builtin: got 1 want 0
FAIL purity.self_rec: got 1 want 0
FAIL purity.mut_rec_a: got 1 want 0
FAIL purity.mut_rec_b: got 1 want 0
FAIL purity.generic_instance_pure: got 0 want 1
FAIL purity.generic_instance_eq_source: got 0 want 1
PASS purity.generic_effect_instance
FAIL purity.generic_effect_eq_source: got 0 want 1
FAIL chain.impure_call_pierced: got 0 want 3
PASS chain.pure_call_untouched
PASS chain.loop_exit_termination
PASS chain.no_label_edge_without_loop
6/17 purity cases passed            （驱动 rc=1）
```

红态读数与侦查预判逐条吻合：负控①-⑤ 全 `got 1`（乐观常量）；⑥ 泛型实例 `got 0`（`monomorph` 未写该字段，`rt.s` zero-init）；
`chain.impure_call_pierced got 0`（效应调用不在链上 = 本批要修的 P0 现象本身）；
`chain.pure_call_untouched`/`loop_exit_termination` 在红态即 PASS（前者因旧行为亦不入链、后者因旧 `sg_pop` 规则活着），
两者的同时成立正是绿态要守的东西：迁移不得把①的"入链"和③的"终止依赖"任一弄丢。

实现后：17/17 PASS（同一用例表，仅实现差异）。

---

## 4. 证据（原始输出）

### 4.1 ELF 逐字节（硬判据）

```
$ nice -n 19 ./build/corec clean-cache
$ nice -n 19 ./build/corec build tests/suite/ptr_arith.cr -o /tmp/purity-recon/pa_final --static   # rc=0
$ sha256sum /tmp/purity-recon/pa_final /tmp/r1t4_base_bin
95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475  /tmp/purity-recon/pa_final
95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475  /tmp/r1t4_base_bin
$ cmp /tmp/purity-recon/pa_final /tmp/r1t4_base_bin && echo ELF_IDENTICAL
ELF_IDENTICAL
```

链变了、发射面仍不动的正面证据（比「无变化语料」更强的实验）：`chain_probe.cr`（含 loop + 不纯调用 + 纯调用）
在本批下链 +26 边，与基线编译器产物逐字节相同：

```
$ sha256sum cp_elf_new cp_elf_old
bbdee11aba2bb8dcf1c96a860d8add619efc743c3bb3d7f113cbf8ebdea19973  cp_elf_new
bbdee11aba2bb8dcf1c96a860d8add619efc743c3bb3d7f113cbf8ebdea19973  cp_elf_old
$ cmp cp_elf_new cp_elf_old && echo ELF_IDENTICAL_ON_CHANGED_CHAINS
ELF_IDENTICAL_ON_CHANGED_CHAINS
```

因此 逐字节不变的机制（不是运气）：链边只进 EDG 段；`lower_to_ccr` 按节点创建序直出（`dataflow.cr:351-371`，与边无关），
`compute_usage_counts` 显式跳过 kind≠0（`dataflow.cr:337`），corearch 三轴不读 EDG（`src/arch|format|os` 对 `g_df_edges`/`v7_edge_*` 零引用，唯一命中是注释）。

### 4.2 链重放保真（旧 vs 新逐边对拍）

对拍法：两编译器各自 `cir` 出 DOT（state 边 = dashed/red），按函数节点区间取逐边集合比较。

```
--- probe_loop (循环 + store，无调用) ---
  OLD state: [(store到store), (store到store), (store到store), (store到label)]
  NEW state: 同上                                          SAME     ← 循环终止规则重放逐边一致
--- probe_seq (store / 不纯调用 / store) ---
  OLD state: [(store到store)]
  NEW state: [(store到call:effect), (call:effect到store)]    DIFF ← 本批目的（效应调用入链）
--- probe_pure_call (store / 纯调用 / store) ---
  SAME                                                     ← 纯调用不入链（与旧同）
--- probe_loop_call (循环内不纯调用) ---
  OLD: [(store到store), (store到label)]
  NEW: [(store到call), (call到store), (store到label)]         DIFF ← 终止依赖现在覆盖循环内效应调用
```

### 4.3 `.ccr` 变化面实测（旧 vs 新，冷缓存）

```
ptr_arith   OLD: nod=1298 edg=1103 kinds={0:810, 1:293} size=88753
ptr_arith   NEW: nod=1298 edg=1127 kinds={0:810, 1:317} size=88945     ← NOD/数据边不变，kind=1 +24
chain_probe OLD: nod=1360 edg=1139 kinds={0:841, 1:298} size=92947
chain_probe NEW: nod=1360 edg=1165 kinds={0:841, 1:324} size=93155     ← +26
```

因此 变化面 = 仅 `EDG` 段的 kind=1 边（数量与文件长度）；NOD/数据边（kind=0）/其余段零变化。Task 3 更新基准值时的期望面即此。
> [批终审订正 2026-09-11] 上两处「NOD 逐字节不动 / 零变化」作为断言是错的，NOD 的邻接域字段（first_edge/edge_count）随 kind=1 边增删必变。终审独立 A/B 的订正版口径 = NOD 语义字段 (op,dest,s1,s2,s3,tk) 差异 = 0、kind=0 边逐集合相同，kind=1 边 303到329（与 T4 报告逐数吻合）。代码无涉，仅本报告措辞失实（树内 TODO #26/#27 已是订正版）。


### 4.4 自举链（原始输出）

```
$ nice -n 19 ./build/corec build src/compiler/main.cr -o /tmp/purity-recon/corec2 --static -O 0     # rc=0
$ nice -n 19 /tmp/purity-recon/corec2 build src/compiler/main.cr -o /tmp/purity-recon/corec3 --static -O 0  # rc=0
$ cmp corec2f corec3f && echo CMP_IDENTICAL
CMP_IDENTICAL
$ sha256sum corec2f corec3f          # 提交态源（终表 17 例）
00e5a1d52834ccd650e6fe350cbc1cca7db22fff5166b39960f7651088901769  corec2f
00e5a1d52834ccd650e6fe350cbc1cca7db22fff5166b39960f7651088901769  corec3f
$ grep -c "N06" corec2f_build.log corec3f_build.log
corec2f_build.log:0
corec3f_build.log:0
$ grep -n "error\[" corec2f_build.log      # 既有 TF01 误报，基线条数同为 2
42:error[TF01]: Function return type mismatch
48:error[TF01]: Function return type mismatch
$ nice -n 19 ./build/corec run 'fn main() -> int { return 42; }'   # rc=42
$ nice -n 19 /tmp/purity-recon/corec2f run 'fn main() -> int { return 42; }'  # rc=42
$ nice -n 19 /tmp/purity-recon/corec2f selftest-purity  到 17/17 purity cases passed
```

### 4.5 回归

37 套件顺序跑（`nice -n 19`，逐套件 rc 记录）：37/37 rc=0。
（首轮唯一红 = `tests/selfhost/test_compile.py`，根因 = 该文件的编译器源清单未含新文件 因此 resolver `Undefined name: purity_selftest_run`；
按该文件自身约定的「与 build_selfhost_native.py 的 corec 清单同位」补一条后 rc=0。属清单同步，非实现缺陷。）

---

## 5. 编译期开销（计划风险① `find_func` O(F²)）

`corec2` 全量构建（733 函数 / 103889 指令）：`14.96s user`、墙钟 69s（`nice -n 19` 单核友好）。
纯度遍的边解析 = 每调用点一次 `find_func`（≈5 万次 × O(F≈800) 线性扫），全程序一次；不动点多轮扫体为 O(N) 级。
未见可比基线的显著劣化（同机同 nice 下与基线构建同量级）；若后续大工程触发阈值，再按计划建议换哈希索引。

---

## 6. 提交

`feat: 效应纯度修正 Task 1，真纯度计算（全程序 IR 面 + 调用图不动点 + SCC 保守）替换乐观常量；state 链迁至 IR 生成后重建（lazy 判定冻结保发射面）`

> brief 原拟提交信息含「monomorph 继承源纯度」，本实现未用该写法（第7 偏差 3：该时点抄的是乐观默认值），改为实例到源映射侧表 + 源=实例合取；提交信息按实际改动改写。
（工作区内 `docs/superpowers/specs/2026-09-11-merge-semantics-design.md` 的改动属其他 agent，不在本提交内。）

---

## 7. 与 brief/plan 的偏差清单（逐条理由）

| # | 计划原文 | 本实现 | 理由 |
|---|---|---|---|
| 1 | 时点 = `check_all()` 尾部（IR 体就绪） | 时点 = IR 生成结束后（`df_state_finalize`） | 第0 发现 1：IR 体在 check_all 期不存在（实测 `g_ir_func_count == 0`）；brief 明示「具体落点由你按实际代码定，须说明为何安全」 |
| 2 | 删除 `checker.cr:1107/1142` 两处 `fi_set_ispure(...,1)` | 保留（并加注为「lazy 冻结输入」） | 第0 发现 2：删除 因此 生成期 `fi_ispure == 0` 因此 全部 thunk 消失 因此 发射面变、ELF 判据破。真值在同一字段上由 `compute_all_purity` 于 IR 生成后覆盖写回 |
| 3 | `monomorph` 实例继承源纯度 `fi_set_ispure(new, fi_ispure(src))` | 实例由自身体算；源 = 实例合取；`monomorph` 改为登记实例到源侧表 | 第1.1 末段：该时点抄的是乐观默认值（会把有效应泛型错标纯，红态 ⑥ 两例即此）。合取规则使「实例与源同值」仍恒成立且更精确 |
| 4 | 效应面 = store 族 4 + extern | 加 `IR_STORE_PTR`、`IR_AWAIT`、`IR_INLINE`、`SG_UNSAFE` 区 | 保守方向加面（少判纯 = 多入链 = 语义安全）；`IR_INLINE` 不复制被调者体 因此 必须按调用边算 |
| 5 | （未提） | cir 缓存版本 14到15；`test_compile.py` 源清单补条目；新增 `selftest-purity` CLI 与自测文件 | 缓存快照内容变更（不再含链边）因此 必须失效；源清单变化 = resolver 报错（红过一次）；自测通道 = brief Step 1 授权 |

未做（有意）：`ir_gen.cr` 的 lazy 判定与其 use_count 时序缺陷（`ir_gen.cr` 本批零改动，逐字节证据见 第4.1）；Task 2 的分类表（`df_connect_state` 本体未动）。

---

## 8. 对 Task 2 的移交通知（重要）

1. `df_connect_state` 的调用点变了：不再由 `df_create_node` 调，而由 `df_replay_state_chain`（`dataflow.cr:196`）在成品图上逐节点重放调用。
   签名 `(node_id, opcode, s3)` 未变；`s1` 需从节点读：`r64(g_df_nodes, node_id * ESZ_DFNODE + OFF_DF_S1)`。
2. Task 2 的验收例已可复现：`fn effect(){st=1;}` 被 main 调两次 因此 main 链出现两个 CALL（本任务 第4.2 的 `probe_seq` 是单次版：`store 到 call 到 store` 已在自测里钉住）。
3. 改动只在分类表内：加 `IR_CALL_EXTERN`（恒入链）/ `IR_SPAWN`/`IR_YIELD`/`IR_HOTPATCH_ROUTE`/`IR_DYN_DISPATCH` 分支即可；
   「可解析调用按真纯度」一条已生效（`fi_ispure` 现在是真值）。
4. 若 Task 2 要加边集断言：`purity_selftest.cr` 里的 `ps_call_node / ps_state_touch / ps_has_label_state_target` 三个探针可直接复用（已入自测面）。
5. `.ccr` 期望：只动 EDG 的 kind=1 边（第4.3）；含可解析不纯调用的语料才会有差异，`test_ccr_v7` 的 fixture 不在其列（第2 末）。

---

## 9. Concerns（如实）

1. lazy 冻结是刻意的：本批不动它 因此 「不纯调用的 thunk 包裹」这一既有行为保留（thunk 在解释器/后端均为 eager 值转移，语义无害）。
   真纯度已就位后，lazy 批可以「按真纯度 + 修 use_count 时序」一次做完；届时 ELF 判据必须重定（本批已把该决策的依据实测留档）。
2. 泛型映射的不报错地防线：`src_func_of_ir` 是「按源序跳过泛型」的重放，调用方逐函数用 `g_ir_func_name_idx` 复核名字，复核失败即判不纯（防映射变化不报错地错标）；实测自举/自指语料零变化。
3. 保守面代价：`IR_STORE` 在本地变量赋值上也发射 因此 几乎任何带局部变量的函数都判不纯（`str_len` 亦然）。
   这是 brief 的规则本身（"体无 store 族"）而非实现选择；收益是 P0 缺陷（效应调用丢失顺序）在最宽面上被消除。
4. 编译期：未发现显著劣化（第5），但 `find_func` 线性扫是计划已记的风险点，大工程若触发阈值需换索引。
5. 其他 agent 并发改动：本工作区还有 `docs/.../merge-semantics-design.md` 的他人改动（未纳入本提交）。

---

## 10. 复现命令（判据全链）

```sh
cd /home/DslsDZC/core
nice -n 19 python3 build_selfhost_native.py                                   # 建 corec/corearch/corelsp
nice -n 19 ./build/corec selftest-purity                                      # 17/17
nice -n 19 ./build/corec selftest-types                                       # 95/95
nice -n 19 python3 tests/selfhost/test_purity.py                              # PASS
nice -n 19 ./build/corec clean-cache && nice -n 19 ./build/corec build tests/suite/ptr_arith.cr -o /tmp/pa --static
sha256sum /tmp/pa                                                             # 95084e7b…d475
nice -n 19 ./build/corec build src/compiler/main.cr -o /tmp/corec2 --static -O 0
cp build/corearch /tmp/corearch && nice -n 19 /tmp/corec2 build src/compiler/main.cr -o /tmp/corec3 --static -O 0
cmp /tmp/corec2 /tmp/corec3 && echo CMP_IDENTICAL
nice -n 19 ./build/corec run 'fn main() -> int { return 42; }'                # rc=42
```
