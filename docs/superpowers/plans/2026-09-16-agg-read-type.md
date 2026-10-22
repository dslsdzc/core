# 聚合读类型丢失（TODO #2026-09-16-16，总检查级）第 2 批计划：只读侦查与裁决门（2026-09-16）

> 实施记录：[implementation/2026-09-16-agg-read-type.md](../implementation/2026-09-16-agg-read-type.md)

批名：聚合读类型丢失（TODO #2026-09-16-16）。
批次位置：用户排序的第 2 批，维护者于 2026-09-16 指派。
起点：`develop = 2cfa2646`（PR #86 合入后）。分支为 `feature/agg-read-type`，写本文件时零源码改动。
性质：只读侦查，写进文档，取裁，裁定后实施。本轮零源码改动、零构建。
输入：`TODO.md` #78（含 apx 批交叉引用裁-APX-8）、`docs/superpowers/implementation/2026-09-16-apx-conversion-audit.md` 第 1 节 3b/4b/5/6b/8、第 2 节表 B、`docs/superpowers/implementation/2026-09-16-apx-conversion-batch-report.md`。
本文件约定：所有 `file:line` 都对应 `develop 2cfa2646` 的现状，由本代理逐行读过。这些行号与 TODO、审计中的旧行号存在偏移，见第 0.4 节坐标校正表。标「预判」的内容来自读码推断，等待 T1 实测；标「实核」的内容是本轮直接读到的代码行。

---

## 0. 现状与根因

### 0.1 四个读点与一个结果槽（实核）

| 读点 | 现状坐标 | 当前定型方式 | 声明面位置 | 节点级零 `alloc` 可得性 |
|---|---|---|---|---|
| 结构体字段读 | `ir_gen.cr:2590`（`v := new_ir_var("field", TI_INT)`）、发射点 `:2597 IR_LOAD_FIELD` | 硬定 `TI_INT` | `si_field_type_node(si, fi)`（字段类型节点） | 是（先例 `dex_decl_form_of_expr:1075-1083`：`find_struct(ast_c(node))` 与节点判 `ast_type_val == TY_DEX`） |
| 数组/切片元素读 | `:2655`（`new_ir_var("elem", TI_INT)`）、发射点 `:2660 IR_LOAD_INDEX` 与 `:2668 IR_LOAD_INDEX_VAR` | 硬定 `TI_INT` | 数组 var 的 IR 型（`TYP_ARRAY/TYP_SLICE` 行，`get_type_data` 即元素 ti） | 是 局部/字面量形（`:2780 irv_set_type(v, alloc_type(TYP_ARRAY, elem_ti, N))` 已把元素 ti 写进数组型；`elem_ti_of_decl:343-349` 是纯表读）。全局形另有节点级先例（`dex_decl_form_of_expr:1085-1103` 扫 `g_global_lets`） |
| match 臂载荷绑定 | `:2393`（`fv := new_ir_var("fld", TI_INT)`）、发射点 `:2395` 与 `:2412 IR_LOAD_FIELD` | 硬定 `TI_INT` | `ei_variant_type_node(ei, vi, pos)`（变体载荷类型节点；`enum_payload_ti:389-403` 同源） | 是（照 `:389-403` 去掉 `res_type_node` 即可） |
| match 结果槽 | `:2299`（`new_ir_var("match_res", TI_INT)`）与 `:2300 emit(IR_ALLOC, …, TI_INT)` | 硬定 `TI_INT`（含 `IR_ALLOC` 的 tk） | 无单一声明面，型由各臂决定，多臂可异型 | 否 未覆盖面（见 第 0.3 节；建议本批不碰，登记） |

> 补充事实：元组元素读走 `:2590` 的同形路径（`EXPR_FIELD` 且 `ast_type_val > 0`，即数字下标记法）。元组无声明面（`field_ti_of_node:360` 显式 `return -1`），因此本批的节点级通道取不到元组元素的声明型（见 第 0.3 节 未覆盖面 U2）。

### 0.2 「丢型」的总检查性质（读码实核的连锁面）

读点结果槽的 `irv_type` 恒为 `TI_INT`，因此一切按 IR 值型触发的下游在「经聚合读入的值」上无法检测。下表列出本轮实核的收益面，这些点在修好后自动变正确，且无需改动这些点：

| 点位 | 当前无法检测原因 | 修好后 |
|---|---|---|
| `dex_store_adjust:1046-1049` | `vt := irv_type(val)` 取到 `TI_INT`，两条转换支都不进，scaled 值直接写进 apx（binary64）槽 | `vt == TI_DEX_S` 时走 `dex_scaled_to_bits` |
| `dex_scale_int:1034`（精确路径 int 对齐） | 门 `!= TI_INT` 时早退，读槽被当作 int，于是再乘 S | 原样参与（已是 scaled） |
| 二元分流 `:1311/1331/1334` | 读槽落入「通用整数路径」 | 进 `TI_DEX_S` 精确路径 |
| extern 实参边界 `:1902` | 门 `irv_type(av) == TI_DEX_S` 不匹配读槽，scaled 被当作 binary64 位模式传出 | 触发 `:1905` 的 scaled，再bits |
| LET 继承 `:2503-2505` / `:2518-2519` | 无注解 LET 的槽型取自 `irv_type(初值)`，于是继承到 `TI_INT`（类型经一次绑定即永久丢失） | 继承 `TI_DEX_S` |
| 泛型实例键回落路径 `:1970-1976` | 键名串由实参 IR 型拼成，读槽贡献 `"int"` | 贡献 `"dex"`（与 #93 批的 TODO #2026-09-16-35 同面，见 第 5 节） |
| apx 批的比较/运算点 hack `dex_decl_form_of_expr:1072`（调用点 `:1285-1286`） | 该函数存在的唯一理由（注释 `:1065-1071` 自陈「#78 未修」） | 可退役（但须先证明通用机制覆盖它，见 第 4.4 节 突变控制） |

### 0.3 仍为不报错地错值且 apx 批 hack 未覆盖的面， 本批 RED 候选（预判，待 T1 实测）

apx 批 T3 的 hack 只作用于二元分流点（`:1280-1286`），且要求操作数节点本身是 `EXPR_FIELD` 或全局 ident 数组下标。因此下列形态当前仍是不报错地错值：

| # | 形态（最小探针，全部显式形） | hack 未覆盖的原因 | 预判 |
|---|---|---|---|
| R1 | `x := s.f; x * 2.0`（LET 中转） | hack 按操作数节点判；`x` 是 ident，`dex_decl_form_of_expr(ident) = 0`，且 `x` 的槽型已在 LET 处丢成 `TI_INT` | 不报错地错值 |
| R2 | `enum E { V(dex) } … match e { V(x) => x * 2.0 }` | match 臂绑定是 `new_ir_var("fld", TI_INT)`，不在 hack 的两种节点形内 | 不报错地错值 |
| R3 | 局部数组 `a : [dex;2] = [d, 1.0]; a[0] * 2.0` | hack 只认全局 ident 数组（注释 `:1070` 自陈「局部数组无节点级声明面，因此不判」） | 不报错地错值 |
| R4 | 元组 `t := (d, 1.0); t . 0 * 2.0` | 元组无声明面（同 U2） | 不报错地错值 |
| R5 | `g : dex, apx, mut = 1.0; g = s.f;`（写 apx 槽） | hack 只在二元分流点；`dex_store_adjust` 看 `irv_type(val)` | 不报错地错值（scaled 位模式写进 binary64 槽） |
| R6 | `extern fn c_dex(x: dex) -> dex; … c_dex(s.f)`（extern 实参） | 门 `:1902` 看 `irv_type(av)` | 不报错地错值 · 需实证（extern 面另有历史语义，见 第 10 节 U4） |
| R7 | `fn f(x: dex) -> int {…} … f(s.f)`（Core 调用实参） | 环 `:1810-1848` 按形参声明转换，但转换的前提是看得见实参型 | 需实证（T1 必须先把环读清） |
| N1（非回归断言） | `s.f == d` / `@raw_int(s.f)`（apx 批已转正的 B-3/B-4/B-5/B-6/B-8 形） | — | 当前绿，修后须仍绿（防「修法改坏正确面」） |

### 0.4 坐标校正表（TODO #2026-09-16-16 与审计的旧行号，以及当前状态）

| TODO/审计写法 | 现状（`2cfa2646`） | 说明 |
|---|---|---|
| `ir_gen.cr:2513`（字段读） | `:2590`（`new_ir_var`）/ `:2597`（emit） | apx 批与容量批的位移 |
| `:2578`（元素读） | `:2655` / 发射 `:2660`·`:2668` | 同上 |
| `:2591`（`IR_LOAD_INDEX_VAR`） | `:2668` | 同上 |
| `:2316`（match 绑定） | `:2393`（`fv` 定型）/ `:2395`·`:2412`（emit） | 同上 |
| `:2222`（match 结果槽，apx 批 T2 补） | `:2299`（含 `:2300` 的 `IR_ALLOC` tk） | 同上 |
| 审计 `:2520` / `:2583` / `:2556-2560` | 同上表 | — |

---

## 1. 硬约束复核与既有先例（既有先例均为零 `alloc`）

### 1.1 GC12 的真实边界（实核；比条目原文更窄，须向维护者交代）

- `ir_gen.cr:2455`：带注解的 LET 无条件调用 `res_type_node(type_node)`。也就是说，ir_gen 中当前已有非 optrep 门控的 `res_type_node` 站点。
- `checker.cr:957-967`：`res_type_node` 对基类型节点（`ast_kind == 0`）走 `ty_code_to_ti`（`iface_registry.cr:274-284`：纯 if 链查表，零 alloc）；对命名类型走 `alloc_named_type`（alloc）；对 `EXPR_ARRAY/EXPR_REFTYPE/EXPR_PTRTYPE` 走 `alloc_type`（alloc）。
- GC12 的准确表述（建议本批写入 Global Constraints）为：ir_gen 路径不得新增「可能 alloc 的」`alloc_type`/`alloc_named_type` 站点。「节点是基类型节点」的 `res_type_node` 是纯查表，但本批一律不用它，改用更窄的节点判（`ast_kind(tn) == 0 && ast_type_val(tn) == TY_DEX`），因为本批要的只是 dex 轴（二值），不是完整类型。

### 1.2 零 `alloc` 先例（三处，均在同一仓、同一文件群）

| 先例 | 坐标 | 手法 |
|---|---|---|
| 全局标量/数组的 dex 判定 | `reg_one_global:3206` | `ast_kind(ltn) == 0 && ast_type_val(ltn) == TY_DEX` |
| 比较点声明面查表 | `dex_decl_form_of_expr:1072-1106` | 同上判 + `si_field_type_node` / `g_global_lets` 扫描 |
| 元素型（纯表读） | `elem_ti_of_decl:343-349` 改为 `get_type_kind/get_type_data` | 无 alloc、无 AST 扫描 |

声明面侧表（`irv_decl_ti:315`、`irv_set_decl_ti:321`、`slot_decl_ti:336`）也是零布局变更的进程内表，不进 `.ccr`/`.cir`（注释 `:305`）。该表当前的写点有 5 处（`:2458`·`:2528`·`:2640`·`:2784`·`:2955`，其中 4 处带 `g_optrep_on` 门），读点有 4 处（`:353`·`:412`·`:443`·`:1530`）。

---

## 2. 候选方案（逐案列出改动面、风险、检查与影响）

### 候选 1 读点定型改「声明面 dex 形式」（推荐主体）

做法：在 第 0.1 节的读点，把结果槽的型从常量 `TI_INT` 改为节点级判定所得的形式：

```
form_of_read(node_or_ctx) = TI_DEX_S  若 声明面为 dex（TY_DEX）
                          = TI_INT    否则（保持逐字节不变）
```

要动的点（4 处定型；若需则同步 `IR_ALLOC` 的 tk）：`:2590` · `:2655` · `:2393`；本批建议不动 `:2299`（见 第 0.3 节/第 10 节 U1）。

改动面：`ir_gen.cr` 新增一处判定函数（照 `dex_decl_form_of_expr` 的零 alloc 手法，但返回「元素/字段/载荷的声明形式」而非布尔），3 个读点各改 1 行；元素读复用 `elem_ti_of_decl(irv_type(arr_var))`（纯表读）。

风险（全部为「仅 dex 聚合读程序」的影响，逐条见 第 3 节）：
- `regalloc.cr:680-681`：`TI_DEX_S` 不参与寄存器分配，读槽恒栈驻留（功能等价，代码密度与性能变化）。
- `tag2l.cr:117/126/128/135/137`：只对 `TI_INT` 生效，读槽因而出 tag 闭包，帧尺寸与少量指令字节变化（仅当该槽当前真的带 tag，需实证，见 第 3.2 节）。
- `.ccr` SYM `ccr_io.cr:631/690` 与 `.cir` `cir_cache.cr:259`：per-var 型写入文件，含 dex 聚合读的程序产字节变化。
- 检查：R1–R7 转精确值（分支 A）· `irv_type` 断言（分支 B）· N1 保持绿 · 固定 5 条 IDENTICAL。

### 候选 2 只补登记声明面侧表（`irv_set_decl_ti` 先例；零后端影响）

做法：读点不改 `irv_type`，改为在读点调用 `irv_set_decl_ti(v, TI_DEX_S)`（存的是预置常量 `TI_DEX_S`，不 alloc），并把 第 0.2 节的 6 个判定点的取型来源由 `irv_type(x)` 改成 `slot_decl_ti(x)`。

改动面：读点 3–4 行，加 6 个判定点各 1 行（`dex_store_adjust`/`dex_scale_int`/二元分流 3 处/extern 边界/LET 继承）。`slot_decl_ti` 的既有消费者已核无副作用：`ti_is_optional(TI_DEX_S) = 0`（`:328-333`）· `elem_ti_of_decl(TI_DEX_S) = -1`（`:343-349`）· `is_ptr_var:626-636` 早退。

优点：零后端影响、零序列化影响（regalloc/tag2l/`.ccr`/`.cir` 全不看侧表），ELF 与 5 条固定产物逐字节不变（比候选 1 更保守）。
缺点：`irv_type` 仍是 `TI_INT`，未来任何新的按值型分派消费者仍会无法检测（「总检查」只堵了一半）；且检查3（`irv_type` 断言）无法满足，因为 TODO #2026-09-16-16 的验收规则明写「聚合读的 `irv_type` 断言进自测」。

### 候选 3 混合（1 与侧表同时登记）

以 1 为主，另在 LET（`:2458`）与读点补登记，使 `slot_decl_ti` 与 `irv_type` 两种形式一致。代价 = 1 的影响 + 侧表一致性维护；收益 = 消除「两种形式不一致」的隐性缺陷。推荐序：1，再 3（若实施中发现 `slot_decl_ti` 约定有人依赖）。

### 候选 4 只扩 hack 覆盖面（不做，仅记录其影响范围）

把 `dex_decl_form_of_expr` 的节点形扩到 match 载荷/局部数组/元组，能救 R2/R3 的部分形态，但救不了 R1（LET 中转）与 R5（写 apx 槽）（它们不在二元分流点），且每加一个消费面就要复制一次 hack，与 #78「总检查」定性相悖。登记为不做。

---

## 3. 消费者清单（穷尽，三面各由一份只读侦查支撑；逐条 `file:line`）

### 3.1 前端（`src/compiler/`）

会变（候选 1 下）：
- `ir_gen.cr:339`（`slot_decl_ti` 回退处理）
- `:1017`（`dex_scaled_to_bits` 门首次通过）
- `:1034`（`dex_scale_int` 早退消失）
- `:1046-1049`（`dex_store_adjust` 新支）
- `:1233-1234`（二元取型）
- `:1315/1321/1331/1334`（各自分流转正）
- `:1407` 与 `:2509`（`IR_DYN_PACK` 的 tag 由 0 变 8）
- `:1568`（一元负结果型）
- `:1902`（extern 边界）
- `:1970-1976`（泛型键名串）
- `:2503-2505`/`:2518-2519`（LET 继承）
- `:2764`（数组字面量 `elem_ti` 取自元素值型）

不会变（逐条已核，理由见侦查表）：`:122`·`:140/149`·`:353`·`:412/443`·`:626/636`·`:654`·`:846`·`:961`·`:983`·`:1061`·`:1241/1247`·`:1305-1306`·`:1405`·`:1510`·`:1767`·`:2033`·`:2092`·`:2571`·`:2834`·`:2856`。

需实证：`:1530-1531 改为 1550`（`&v` 的 pointee 型行身份）· `:2023-2024`（`_arg` 打包槽）· `:2527-2528`（侧表继承，取决于是否选候选 3）。

其它文件：
- `opt.cr`（零类型读，纯 opcode/CSE）
- `ptr_analysis.cr`（零 `irv_type`，Andersen 按 opcode）
- `dataflow.cr`（零类型；`:464` 明注 `iri_tk` 是派生码）
- `region_check.cr:62/98/118` 与 `provenance_verify.cr:66`（皆判 `TYP_PTR`；`TI_DEX_S` 与 `TI_INT` 同 kind，因此不会变）
- `monomorph.cr`/`checker.cr`/`src/targets/*`（零命中）

解释器：`interp.cr:293/298/304/310/609/616/624/632` 全部只判容器是否 `TI_STR`，与结果槽无关，因此不会变；`ir_interp_binary:37-49` 按 opcode 分派、不读型，所以零消费点。

### 3.2 后端（`src/arch/x86_64/` · `src/os/linux/` · `src/format/elf/`）， 只有两个真变化点

| 点 | 判定 | 依据 |
|---|---|---|
| `regalloc.cr:680-681` | 会变 | `ty == TI_DEX \|\| TI_DEX_S \|\| TI_DYN \|\| TI_UNIT，因此 continue`（不建候选）。`TI_INT` 当前可分配，所以读槽由「可能驻寄存器」变「恒栈驻留」；同窗口其它 var 的分配可连带变 |
| `tag2l.cr:117 / :126 / :128 / :135 / :137` | 会变 | 规则 A/B/B′ 全部窄门 `irv_type(...) == TI_INT`，读槽因而出入 tag 闭包；`g_x86_mw_tag_count`（`:157`）进 `pf_frame_size`（`frame.cr:51-67`），因此帧尺寸与 `sub rsp` 立即数可能变（`elf.cr:998/1116`） |
| `callseq.cr:70/97/101/127/167/179` | 不会变 | 7 处全是 `== TI_DEX`；`TI_DEX_S` 与 `TI_INT` 同落整数类（binary64 走 XMM、scaled 走整数寄存器，本批不改变这一分工） |
| `instr.cr` | 不会变 | 全文 `TI_DEX_S` 出现 0 次；`e2_load_var`/`e2_sd_*`/`IR_LOAD_FIELD:1137`/`IR_LOAD_INDEX:1313`/`IR_LOAD_INDEX_VAR:1349` 均无类型分支；`:386`·`:963` 只判 `== TI_DEX` |
| `frame.cr:51-67/119-168` | 间接 | 帧公式类型无关但含 tag 计数；`:160-168` 的「形参行清 tag」只覆盖形参，因此读槽本就不使用它 |
| `sizes.cr` | 不会变 | `instr_size(op)` 无类型入参 |
| `elf.cr` / `syscall.cr` / `entry.cr` / `ld.cr` / `resolve.cr` | 不会变 | 零类型分派（`elf.cr` 的 `TI_` 命中全是注释） |

需实证（缺证据，T1 必做）：1 读槽当前是否真的带 tag（若从不带，则 tag2l/frame 零影响）；2 读槽当前是否真的被分配了寄存器（若窗口冲突/带 hazard 位，则 regalloc 零影响）。

### 3.3 序列化面（本批影响的出处）

| 产物 | 坐标 | 事实 |
|---|---|---|
| `.ccr` | `ccr_io.cr:631`（SYM 全局：`irv_type(gi)`）· `:690`（SYM 函数 var 声明：`irv_type(row)`） | per-IR-var 型写入文件，因此候选 1 下，含 dex 聚合读的程序的 `.ccr` 字节变（记录定长，故 size 不变、sha 变） |
| `.ccr` 版本 | `CCR_VERSION = 9`（`ccr_io.cr:135`） | 本批不改段结构，因此不 bump（但若最终方案触发写入文件字节变化，按「禁的不是变化是无声变化」原则在报告里显式归因） |
| `.ccr` TYPE/IFACE 段 | `ccr_io.cr:380-390` · `ccr_types.cr:160-163` | 独立类型项表，不表示 per-var 型，因此候选 1（只给预置常量 `TI_DEX_S`，不 alloc）不动 TYPE 段尺寸 |
| `.cir` | `cir_cache.cr:259`（`w64_cir(irv_type(v_idx))`）· `CIR_CACHE_VER = 17`（`:51`） | `.cir` 快照含 var 型，因此候选 1 下暖/冷快照字节变（语义一致，两侧同源）；`.cir` 不在 5 条 canary 内 |
| ELF | `elf.cr:55` | 无 IR 型面；但 第 3.2 节的两点会通过指令流间接改 ELF |

### 3.4 语料覆盖（结论：固定语料覆盖不到本批面）

- 固定 5 条（`canary_values.tsv:88-92` / `test_canary_carrier.py:42`）：`canary_elf`+`pa_ccr`（`tests/suite/ptr_arith.cr`）· `pa_static_ccr` · `gt_ccr`/`gt_static_ccr`（`tests/suite/generics_test.cr`）。
- `ptr_arith.cr`：唯一聚合访问是 `&arr[2]`（`IR_ADDR_INDEX`，不是 `:2655`）与 `*p`；无 dex。
- `generics_test.cr`：有聚合读（`:24`/`:58`/`:60`/`:67`/`:69` 的 `b.val` 等，声明型 = 泛型 `T` 实例化为 `int`/`str`），但全档 `dex` 零出现（`grep -n dex` 无命中）。
-，因此预期：候选 1 下 5 条 canary 全 IDENTICAL（无 dex，所以 `form = TI_INT`，因此逐字节不变）。
-，因此风险项 同时必须写明的反面：固定 5 条对本批目标面零区分力（这正是上一批「`.ccr` 没变 ≠ 生成面没变」教训的镜像）。真正覆盖本批面的语料是未固定的 `tests/suite/apx_conversion_test.cr`（`:15` dex 字段 · `:42/:44` 字段读 · `:47/:48/:51` 数组/切片元素读 · `:55` 元组元素读 · `:73` 比较 · `:85/:89` 枚举载荷）+ 本批新增探针。
-，因此副产物：固定 5 条是实现约定的判别器，若有人把候选 1 做成无条件（不判声明面）施加，`generics_test.cr` 的 `b.val` 读槽会改变成 `TI_DEX_S`，所以 `gt_ccr`/`gt_static_ccr` 必变。这条回归本身就能抓住「约定错误」，须写进 Global Constraints。

---

## 4. 验收设计（本批最易出错之处）

### 4.1 预期影响总表

| 检查 | 期望（候选 1，且实现只对 dex 生效） | 若不符，因此处置 |
|---|---|---|
| ELF canary `95084e7b…d475`(28822B) | IDENTICAL | 停，查约定 |
| `.ccr` 四条（96015/96158/142765/142908） | IDENTICAL | 停，查约定（极可能是「无条件施加」） |
| 74 档 parity `check` rc | 逐档全同 | 逐档归因 |
| 29 行为探针 rc | 全同（`p_spawn` rc=0） | 停 |
| `p_dex`/`apx_conversion_test.cr` 等 dex 档 | 产物字节可变（预期内），按「旧值+新值+归因+出处」更新基准值或留痕 | — |
| 新探针（分支 A/B） | 全部通过 | 停 |

### 4.2 探针设计表（本批必须自建检查体系，canary 帮不上忙）

| 检查 | 内容 | 检查形态 |
|---|---|---|
| 分支 A（语义值） | R1 `x := s.f; x * 2.0` · R2 match 载荷 · R3 局部数组元素 · R4 元组元素 · R5 `g_apx = s.f` · R6 extern 实参 · R7 Core 调用实参 | `build --static` 加运行值断言（期望值 = scaled 语义下的精确值）；双路径（`run` + ELF） |
| 分支 B（界面断言，TODO #2026-09-16-16 检查3） | 同一批源，`cir`/`ccr` 转储断言读槽 `irv_type` = `TI_DEX_S`（≥6 例，逐读点：字段/元素/切片/载荷/嵌套/LET 中转） | 机制面正据（不依赖运行值，能在语义面还没接线时先红） |
| 分支 C（回归） | 74 档 + 29 探针 + 固定 5 条 + `interp_parity` + `selftest-types` | rc/sha 对比 |
| 分支 D（突变控制） | 1 关掉 apx hack（`:1285-1286` 注释掉），分支 A/B 仍须全部通过（证明通用机制独立成立）；2 把读点改成无条件 `TI_DEX_S`，固定 5 条必红（证明 canary 判别器有效、约定不是摆设） | 两条突变都必须按预期红/绿 |
| 分支 E（适用范围） | 非 dex 聚合读（`int` 字段/数组）必须零影响：产物与改前逐字节相同 | 逐字节 `cmp` |

### 4.3 当前已绿的非回归断言（N1）

apx 批已转正的 B-3/B-4/B-5/B-6/B-8 探针（`tests/selfhost/test_apx_conversion.py` 与 `tests/suite/apx_conversion_test.cr`）本批不得回退；且它们必须继续在「关掉 hack」下成立（分支 D1）。

### 4.4 hack 退役约定（建议本批只验证、不删）

`dex_decl_form_of_expr` 在候选 1 实现后，对其覆盖面内的形态成为冗余。建议：本批保留该函数并加注释说明「通用机制已覆盖，退役候选」；退役动作留待分支 D1 连续两批绿之后（与 `elf.cr` 未使用文件教训同族：删之前要有独立检查证明无依赖）。

---

## 5. 与 #93 批的交互（预判与可证伪探针）

1. #97（实参位泛型退化实例键）：读点定型改变实参 IR 型，因此 `:1970-1976` 的回落键名串由 `"int"` 变 `"dex"`，`idf(s.f)` 的实例键随之变化。这是「键更精确」的顺向修复，但会新增实例（`.ccr` 里实例名/NOD 数变），须走「显式归因 + 同批留痕」。探针：`idf(s.f)` 与 `idf(x_dex_local)` 的实例名必须一致（照分支 D 手法）。
2. #93 的 19 例与分支 D/E：必须保持全部通过（分支 C 已含）。特别注意 #93 的分支 B（`g(nosuchfn(1))`，因此 `error[N06]`）与 `infer_call_args` 的 fail-closed 限制。本批不动 checker，但若实施中确实需要动 checker 侧（不预期），停下报维护者。
3. 新暴露预判：读点定型后，此前被 `TI_INT` 掩盖的不报错地面会开始「正确地报错或正确地算」。若哪一档从 rc=0 变 rc=1，按 #93 批纪律默认回归嫌疑逐条归因，不许把「新增诊断」当修好（`2026-09-16-criteria-strength-audit.md` 第 0quater 节）。

---

## 6. 裁决门（逐条列出问句、影响、推荐与未取裁时行为）

| # | 问句 | 影响 | 推荐 | 未取裁时行为 |
|---|---|---|---|---|
| 裁-AGG-1 | 候选 1（改 `irv_type`）vs 候选 2（只补侧表）？ | 1 = 真堵总检查、满足检查3，代价 = dex 聚合读程序的 ELF/`.ccr` 字节影响（regalloc 栈驻留 + tag 出闭包）；2 = 零影响，但总检查只堵一半、检查3不可满足 | 1（并把 2 作为「若维护者要求零后端影响」的备选） | 不实施 |
| 裁-AGG-2 | match 结果槽 `:2299` 是否纳入本批？ | 多臂异型，因此需臂分析；不纳入 = 留一个已知未覆盖面 | 不纳入（登记 U1），本批只做四个读点中的三个 + 元素 | 不纳入 |
| 裁-AGG-3 | 元组数字下标（无声明面）怎么办？ | 影响 R4 能否转正；无声明面，因此只能从元组构造点登记元素形式（新机制）或登记未覆盖 | 登记未覆盖（U2）+ 保留 hack 覆盖其比较形；不引入新机制 | 登记 |
| 裁-AGG-4 | 泛型字段/元素（`Box[T].val`，声明型 = 类型参数）？ | `TY_DEX` 判定对类型参数为假，因此泛型实例化为 dex 时本批不覆盖 | 登记未覆盖（U3），与 #97 交互面单列 | 登记 |
| 裁-AGG-5 | hack（`dex_decl_form_of_expr`）本批删不删？ | 删 = 少一处 hack；不删 = 冗余但安全 | 不删，加「退役候选」注释；删除留待分支 D1 两批绿 | 不删 |
| 裁-AGG-6 | `IR_ALLOC` 的 tk（`ir_gen.cr:2300`）与 `IR_DYN_PACK` 的 tag（`:1407/:2509`）是否同批统一？ | 统一 = 更一致；不拉 = 保持改面最小 | 只改结果槽型，不主动改 tk/tag（让它们随值型自然变；变了要归因） | 不动 |
| 裁-AGG-7 | `.ccr`/`.cir` 若如预期不变（固定语料零 dex），是否仍要 bump 版本号？ | 不 bump = 旧产物仍被命中（语义一致，因为变化只发生在 dex 聚合读程序，它们的旧 `.ccr`/`.cir` 与新版不等价） | 需你裁：建议 bump `.cir`（`CIR_CACHE_VER` 17 改为 18）+ 对 `.ccr` 按「同版本号但语义变了」的风险给结论。第 10 节 U5 给出两种约定的代价 | 停，等裁 |
| 裁-AGG-8 | 分支 D2（无条件突变）导致固定 5 条必红，是否把该突变固化为常驻检查（照检查批 22/22 先例）？ | 固化 = 防「约定被改宽」；代价 = CI 时间 | 固化（一行开关 + 期望必红） | 不固化 |

---

## 7. 任务表

| 任务 | 内容 | 出口检查 |
|---|---|---|
| T1 | 零构建侦查复核：1 逐条实核 第 3.2 节的两个「需实证」（读槽当前是否带 tag / 是否分到寄存器）；2 实读调用环 `:1810-1848` 定 R7；3 把 R1–R7 写成探针源并运行改前基线（预期：不报错地错值/139） | 每条 RED 都有「改前实测值」（不许只写预判） |
| T2 | 先裁写进文档（八门结论）+ 探针入库（RED 状态，允许清单登记） | 门逐条有裁决 |
| T3 | 实施：声明形式判定函数 + 3 读点定型（若裁-AGG-1 选2，则 6 判定点改取型） | 分支 A/B 变为通过；分支 E 零影响 |
| T4 | 检查复验：分支 C 全量 + 分支 D 突变 + 分支 E + 固定 5 条 + 更新基准值判定（若有 dex 档产物变） | 全部通过 + 逐条归因 |
| T5 | 完成：TODO #2026-09-16-16 状态 + 批报告 + 未覆盖面登记（U1–U4）+ 交叉引用（#97/#93/审计表 B） | `jj status` 干净 + 五 CI job |

---

## 8. Global Constraints（写入实施期的硬约束）

1. GC12′（本批重述，见 第 1.1 节）：ir_gen 路径不得新增可能 alloc 的类型站点；本批一律用节点判（`ast_kind(tn)==0 && ast_type_val(tn)==TY_DEX`）与纯表读（`get_type_kind/get_type_data`），不调 `res_type_node`/`alloc_type`/`alloc_named_type`。
2. 约定门：定型只对声明面为 dex 生效；非 dex 聚合读逐字节不变（分支 E 是这一条的检查）。
3. canary 判别器：固定 5 条必须 IDENTICAL；同时报告必须写明「本批 canary 对目标面零区分力」，不得用 canary 绿代替本批检查。
4. 无名变化禁止：任何 `.ccr`/`.cir`/ELF 字节变化必须逐档归因 + 旧值/新值/出处（含 dex 档）；若出现预期外变化，因此停（停条件 2）。
5. 不许把「新增诊断/新增失败」当修好（检查批 第 0quater 节）。
6. 毒丸守卫：改动若需动 `checker.cr`（不预期），停下报维护者。

---

## 9. 停条件（命中即停、报维护者，不自行放宽）

1. 固定 5 条 canary 出现任何非预期变化。
2. 任何非 dex 聚合读程序的产物字节变化（= 约定泄漏）。
3. 分支 D1（关 hack）下分支 A 出现红，说明通用机制覆盖面不足（不是「hack 冗余」）。
4. 74 档出现 rc 由 0 改为 1 的档且归因不清。
5. 实施中发现必须复用「那 5 个声明面 API」（GC12 原约定）才能推进。
6. 裁-AGG-7 的 `.cir`/`.ccr` 版本号 bump 裁决未取裁之前，涉及产物固定的 T4 步骤不得开始。

---

## 10. 未决项（U）

- U1：match 结果槽 `:2299`（多臂异型，需臂分析），本批登记不修。
- U2：元组元素（无声明面；`field_ti_of_node:360` 显式返回 -1），登记；其「比较形」当前靠 hack 兜（`dex_decl_form_of_expr` 对 `ast_type_val > 0` 也返回 0，因此连 hack 也未覆盖该形，R4 的 RED 属性待 T1 实测确认）。
- U3：泛型字段/元素（声明型 = 类型参数 T），本批不覆盖；与 `TODO #2026-09-16-35`（退化实例键）同面，建议后续批合并处理。
- U4：extern 实参（R6），extern 的 dex 语义有历史契约（1b「apx 实参原样保留恰合 C ABI」），因此本批改动是否应当影响 extern 形需维护者确认（否则 R6 应从分支 A 移除、改列「语义待定」）。
- U5：`.cir`/`.ccr` 是否 bump（裁-AGG-7）：约定 A = 不 bump（理由：固定 5 条不变、且变化只落在 dex 聚合读程序）；约定 B = bump `.cir` 17 改为 18（理由：旧 `.cir` 快照里读槽型是 `TI_INT`，与新建的 `TI_DEX_S` 不等价，同一源文件在修复前后会命中不同语义的旧快照，这正是 #8 缓存事故的同族）。建议约定 B（bump `.cir`）加 `.ccr` 侧同步给出结论（`.ccr` 无「快照复用」语义，可只留痕不 bump，但须写成显式声明）。
- U6：超大 scaled 值的 tag 语义（第 3.2 节）：读槽掉出 tag 闭包后，若该值参与 2L（多字）路径的算术，语义是否仍正确，需一条边界探针（构造 |scaled| 接近 2⁶² 的 dex 字段值 + ADD/MUL）实证；不成立则 tag2l 需要把 `TI_DEX_S` 纳入闭包（届时改面扩大，须回取裁）。

---
