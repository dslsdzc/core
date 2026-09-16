# 聚合读丢型（TODO #2026-09-16-16 · 总闸级）—— 批 2 计划（**只读侦查 + 裁决门**，2026-09-16）

**批名**：**聚合读丢型**（TODO #2026-09-16-16）· **批次位置**：用户排序的**第 2 批**（维护者 2026-09-16 派单）
**起点**：`develop = 2cfa2646`（PR #86 合入后；分支 `feature/agg-read-type`，写本文件时零源码改动）
**性质**：`只读侦查 → 落纸 → 取裁 → （裁后）实施`。**本轮零源码改动、零构建**。
**输入**：`TODO.md` #78（含 apx 批交叉引用裁-APX-8）· `docs/superpowers/specs/2026-09-16-apx-conversion-audit.md` §1 ③b/④b/⑤/⑥b/⑧ + §2 表 B + §errata · apx 批报告（`docs/superpowers/specs/2026-09-16-apx-conversion-batch-report.md`）
**本文件口径**：所有 `file:line` 均为 **`develop 2cfa2646` 现状**（亲自读过；与 TODO/审计中的旧行号有偏移 ⇒ 见 §0.4 坐标校正表）。凡标 **预判** 者 = 读码推断、**待 T1 实测**；凡标 **实核** 者 = 本轮直接读到的代码行。

---

## 0. 现状与根因

### 0.1 四个读点 + 一个结果槽（实核）

| 读点 | 现状坐标 | 今天怎么定型 | 声明面在哪 | 节点级零 alloc 可得？ |
|---|---|---|---|---|
| **结构体字段读** | `ir_gen.cr:2590`（`v := new_ir_var("field", TI_INT)`）· 发射 `:2597 IR_LOAD_FIELD` | 硬定 `TI_INT` | `si_field_type_node(si, fi)`（字段类型节点） | **✓**（先例 `dex_decl_form_of_expr:1075-1083`：`find_struct(ast_c(node))` + 节点判 `ast_type_val == TY_DEX`） |
| **数组/切片元素读** | `:2655`（`new_ir_var("elem", TI_INT)`）· 发射 `:2660 IR_LOAD_INDEX` / `:2668 IR_LOAD_INDEX_VAR` | 硬定 `TI_INT` | 数组 var 的 IR 型（`TYP_ARRAY/TYP_SLICE` 行 ⇒ `get_type_data` = 元素 ti） | **✓ 局部/字面量形**（`:2780 irv_set_type(v, alloc_type(TYP_ARRAY, elem_ti, N))` 已把元素 ti 写进数组型；`elem_ti_of_decl:343-349` 是纯表读）· **全局形**另有节点级先例（`dex_decl_form_of_expr:1085-1103` 扫 `g_global_lets`） |
| **match 臂载荷绑定** | `:2393`（`fv := new_ir_var("fld", TI_INT)`）· 发射 `:2395`/`:2412 IR_LOAD_FIELD` | 硬定 `TI_INT` | `ei_variant_type_node(ei, vi, pos)`（变体载荷类型节点；`enum_payload_ti:389-403` 同源） | **✓**（照 `:389-403` 去掉 `res_type_node` 即可） |
| **match 结果槽** | `:2299`（`new_ir_var("match_res", TI_INT)` + `:2300 emit(IR_ALLOC, …, TI_INT)`） | 硬定 `TI_INT`（含 `IR_ALLOC` 的 tk） | 无单一声明面——型由**各臂**决定，多臂可异型 | **✗ 未覆盖面**（见 §0.3；建议本批**不碰**，登记） |

> 补充事实：**元组元素读走 `:2590` 同形**（`EXPR_FIELD` 且 `ast_type_val > 0` = 数字下标记法）——元组**无声明面**（`field_ti_of_node:360` 显式 `return -1`）⇒ 本批的节点级通道**取不到元组元素的声明型**（见 §0.3 未覆盖面 U2）。

### 0.2 「丢型」为什么是**总闸**（读码实核的连锁面）

读点结果槽 `irv_type` 恒 `TI_INT` ⇒ 一切**按 IR 值型触发**的下游在「经聚合读入的值」上失明。本轮实核的**收益面**（修好后**自动**变正确，且无需改这些点）：

| 点位 | 今天为什么失明 | 修好后 |
|---|---|---|
| `dex_store_adjust:1046-1049` | `vt := irv_type(val)` = `TI_INT` ⇒ 两条转换支都不进 ⇒ **scaled 值直接写进 apx（binary64）槽** | `vt == TI_DEX_S` ⇒ 走 `dex_scaled_to_bits` |
| `dex_scale_int:1034`（精确路径 int 对齐） | 门 `!= TI_INT` 早退 ⇒ 读槽被当 int ⇒ 再 ×S | 原样参与（已是 scaled） |
| 二元分流 `:1311/1331/1334` | 读槽落「通用整数路径」 | 进 `TI_DEX_S` 精确路径 |
| extern 实参边界 `:1902` | 门 `irv_type(av) == TI_DEX_S` ⇒ 读槽不匹配 ⇒ scaled 当 binary64 位模式传出 | 触发 `:1905` scaled→bits |
| LET 继承 `:2503-2505` / `:2518-2519` | 无注解 LET 的槽型 = `irv_type(初值)` ⇒ 继承到 `TI_INT`（**类型经一次绑定即永久丢失**） | 继承 `TI_DEX_S` |
| 泛型实例键回落路径 `:1970-1976` | 键名串由实参 IR 型拼 ⇒ 读槽贡献 `"int"` | 贡献 `"dex"`（**与 #93 批的 TODO #2026-09-16-35 同面**，见 §5） |
| apx 批的**比较/运算点 hack** `dex_decl_form_of_expr:1072`（调用点 `:1285-1286`） | 该函数存在的唯一理由（注释 `:1065-1071` 自陈「#78 未修」） | **可退役**（但须先证明通用机制覆盖它，见 §4.4 突变控制） |

### 0.3 今天**仍是静默错值**的面（apx 批 hack 够不着）＝ 本批 RED 候选（**预判，待 T1 实测**）

apx 批 T3 的 hack **只作用于二元分流点**（`:1280-1286`，且要求**操作数节点本身**是 `EXPR_FIELD` 或**全局** ident 数组下标）。因此下列形态**今天仍是静默错值**：

| # | 形态（最小探针，全部显式形） | 为什么 hack 够不着 | 预判 |
|---|---|---|---|
| **R1** | `x := s.f; x * 2.0`（**LET 中转**） | hack 按**操作数节点**判；`x` 是 ident，`dex_decl_form_of_expr(ident) = 0`，且 `x` 的槽型已在 LET 处丢成 `TI_INT` | 静默错值 |
| **R2** | `enum E { V(dex) } … match e { V(x) => x * 2.0 }` | match 臂绑定是 `new_ir_var("fld", TI_INT)`，不在 hack 的两种节点形内 | 静默错值 |
| **R3** | 局部数组 `a : [dex;2] = [d, 1.0]; a[0] * 2.0` | hack 只认**全局** ident 数组（注释 `:1070` 自陈「局部数组无节点级声明面 ⇒ 不判」） | 静默错值 |
| **R4** | 元组 `t := (d, 1.0); t . 0 * 2.0` | 元组无声明面（同 U2） | 静默错值 |
| **R5** | `g : dex, apx, mut = 1.0; g = s.f;`（**写 apx 槽**） | hack 只在二元分流点；`dex_store_adjust` 看 `irv_type(val)` | 静默错值（scaled 位模式写进 binary64 槽） |
| **R6** | `extern fn c_dex(x: dex) -> dex; … c_dex(s.f)`（**extern 实参**） | 门 `:1902` 看 `irv_type(av)` | 静默错值 · **需实证**（extern 面另有历史语义，见 §10 U4） |
| **R7** | `fn f(x: dex) -> int {…} … f(s.f)`（**Core 调用实参**） | 环 `:1810-1848` 按**形参声明**转，但转的前提是看得见实参型 | **需实证**（T1 必须先把环读清） |
| **N1**（**非回归钉子**） | `s.f == d` / `@raw_int(s.f)`（apx 批已转正的 B-3/B-4/B-5/B-6/B-8 形） | — | **今天绿，修后须仍绿**（防「修法把正确的搞坏」） |

### 0.4 坐标校正表（TODO #2026-09-16-16 / 审计的旧行号 → 现状）

| TODO/审计写法 | 现状（`2cfa2646`） | 说明 |
|---|---|---|
| `ir_gen.cr:2513`（字段读） | **`:2590`**（`new_ir_var`）/ `:2597`（emit） | apx 批 + 容量批位移 |
| `:2578`（元素读） | **`:2655`** / 发射 `:2660`·`:2668` | 同上 |
| `:2591`（`IR_LOAD_INDEX_VAR`） | **`:2668`** | 同上 |
| `:2316`（match 绑定） | **`:2393`**（`fv` 定型）/ `:2395`·`:2412`（emit） | 同上 |
| `:2222`（match 结果槽，apx 批 T2 补） | **`:2299`**（+ `:2300` 的 `IR_ALLOC` tk） | 同上 |
| 审计 `:2520` / `:2583` / `:2556-2560` | 同上表 | — |

---

## 1. 硬约束复核与既有先例（**先例都是零 alloc 的**）

### 1.1 GC12 的真实边界（实核，比条目原文更窄——**须向维护者交代**）

- `ir_gen.cr:2455`：**带注解的 LET** 无条件调 `res_type_node(type_node)`——即 **ir_gen 里今天已有非 optrep 门控的 `res_type_node` 站点**。
- `checker.cr:957-967`：`res_type_node` 对**基类型节点**（`ast_kind == 0`）走 `ty_code_to_ti`（`iface_registry.cr:274-284`：**纯 if 链查表，零 alloc**）；对命名类型走 `alloc_named_type`（**alloc**）；对 `EXPR_ARRAY/EXPR_REFTYPE/EXPR_PTRTYPE` 走 `alloc_type`（**alloc**）。
- ⇒ **GC12 的准确表述**（建议本批写入 Global Constraints）：**ir_gen 路径不得新增「可能 alloc 的」`alloc_type`/`alloc_named_type` 站点**；「节点是基类型节点」的 `res_type_node` 是**纯查表**，但**本批一律不用它**——改用更窄的**节点判**（`ast_kind(tn) == 0 && ast_type_val(tn) == TY_DEX`），因为我们要的只是 **dex 轴**（二值），不是完整类型。

### 1.2 零 alloc 先例（三处，全在同一仓、同一文件群）

| 先例 | 坐标 | 手法 |
|---|---|---|
| 全局标量/数组的 dex 判定 | `reg_one_global:3206` | `ast_kind(ltn) == 0 && ast_type_val(ltn) == TY_DEX` |
| 比较点声明面查表 | `dex_decl_form_of_expr:1072-1106` | 同上判 + `si_field_type_node` / `g_global_lets` 扫描 |
| 元素型（纯表读） | `elem_ti_of_decl:343-349` → `get_type_kind/get_type_data` | 无 alloc、无 AST 扫描 |

**声明面侧表**（`irv_decl_ti:315` / `irv_set_decl_ti:321` / `slot_decl_ti:336`）也是零布局变更的进程内表：**不进 `.ccr`/`.cir`**（注释 `:305`），今天写点 5 处（`:2458`·`:2528`·`:2640`·`:2784`·`:2955`，其中 4 处带 `g_optrep_on` 门），读点 4 处（`:353`·`:412`·`:443`·`:1530`）。

---

## 2. 候选方案（逐案：改动面 / 风险 / 判据 / 足迹）

### 候选 ① **读点定型改「声明面 dex 形式」**（推荐主体）

**做法**：在 §0.1 的读点，把结果槽的**型**从常量 `TI_INT` 改为**节点级判定所得的形式**：

```
form_of_read(node_or_ctx) = TI_DEX_S  若 声明面为 dex（TY_DEX）
                          = TI_INT    否则（**保持逐字节不变**）
```

**要动的点**（4 处定型 + 若需 `IR_ALLOC` tk 同步）：`:2590` · `:2655` · `:2393` ·（本批**建议不动** `:2299`，见 §0.3/§10 U1）。

**改动面**：`ir_gen.cr` 一处新判定函数（照 `dex_decl_form_of_expr` 的零 alloc 手法，但**返回「元素/字段/载荷的声明形式」**而非布尔），3 个读点各 1 行；元素读复用 `elem_ti_of_decl(irv_type(arr_var))`（纯表读）。

**风险**（**全部为「仅 dex 聚合读程序」的足迹**，逐条见 §3）：
- `regalloc.cr:680-681`：`TI_DEX_S` **不参与寄存器分配** ⇒ 读槽恒栈驻留（功能等价、代码密度/性能变化）。
- `tag2l.cr:117/126/128/135/137`：只对 `TI_INT` 生效 ⇒ 读槽出 tag 闭包 ⇒ 帧尺寸与少量指令字节变（**仅当该槽今天真的带 tag**——需实证，见 §3.2）。
- `.ccr` SYM `ccr_io.cr:631/690` + `.cir` `cir_cache.cr:259`：per-var 型落盘 ⇒ 含 dex 聚合读的程序产字节变。
- **判据**：R1–R7 转精确值（腿 A）· `irv_type` 断言（腿 B）· N1 保持绿 · 锁定 5 条 IDENTICAL。

### 候选 ② **只补登记声明面侧表**（`irv_set_decl_ti` 先例；零后端足迹）

**做法**：读点不改 `irv_type`；改为在读点 `irv_set_decl_ti(v, TI_DEX_S)`（**存的是预置常量 `TI_DEX_S`，不 alloc**），并把 §0.2 的 6 个判定点的取型来源由 `irv_type(x)` 改成 `slot_decl_ti(x)`。

**改动面**：读点 3–4 行 + **6 个判定点各 1 行**（`dex_store_adjust`/`dex_scale_int`/二元分流 3 处/extern 边界/LET 继承）。`slot_decl_ti` 的既有消费者已核**无副作用**：`ti_is_optional(TI_DEX_S) = 0`（`:328-333`）· `elem_ti_of_decl(TI_DEX_S) = -1`（`:343-349`）· `is_ptr_var:626-636` 早退。

**优点**：**零后端足迹、零序列化足迹**（regalloc/tag2l/`.ccr`/`.cir` 全不看侧表）⇒ ELF 与 5 条锁定产物**逐字节不变**（比候选 ① 更保守）。
**缺点**：`irv_type` 仍是 `TI_INT` ⇒ **未来任何新的按值型分派消费者仍会失明**（「总闸」只堵了一半）；且**判据③（`irv_type` 断言）无法满足**——TODO #2026-09-16-16 的验收条款明写「聚合读的 `irv_type` 断言进自测」。

### 候选 ③ **混合**（① + 侧表同时登记）

① 为主，另在 LET（`:2458`）与读点补登记，使 `slot_decl_ti` 与 `irv_type` 两口径**一致**。代价 = ① 的足迹 + 侧表一致性维护；收益 = 消除「两口径不一致」的隐性坑。**推荐序：① → ③（若实施中发现 `slot_decl_ti` 口径有人依赖）**。

### 候选 ④ **只扩 hack 覆盖面**（不做，仅记录其爆炸半径）

把 `dex_decl_form_of_expr` 的节点形扩到 match 载荷/局部数组/元组 ⇒ 能救 R2/R3 的部分形态，但**救不了 R1（LET 中转）与 R5（写 apx 槽）**（它们不在二元分流点），且每加一个消费面就要复制一次 hack —— 与 #78「总闸」定性相悖。**登记为不做**。

---

## 3. 消费者盘点（**穷尽**，三面各由一份只读侦查支撑；逐条 `file:line`）

### 3.1 前端（`src/compiler/`）

**会变**（候选 ① 下）：`ir_gen.cr:339`（`slot_decl_ti` 兜底）· `:1017`（`dex_scaled_to_bits` 门首次通过）· `:1034`（`dex_scale_int` 早退消失）· `:1046-1049`（`dex_store_adjust` 新支）· `:1233-1234`（二元取型）· `:1315/1321/1331/1334`（各自分流转正）· `:1407`+`:2509`（`IR_DYN_PACK` 的 tag 由 0 变 8）· `:1568`（一元负结果型）· `:1902`（extern 边界）· `:1970-1976`（泛型键名串）· `:2503-2505`/`:2518-2519`（LET 继承）· `:2764`（数组字面量 `elem_ti` 取自元素值型）。
**不会变**（逐条已核，理由见侦查表）：`:122`·`:140/149`·`:353`·`:412/443`·`:626/636`·`:654`·`:846`·`:961`·`:983`·`:1061`·`:1241/1247`·`:1305-1306`·`:1405`·`:1510`·`:1767`·`:2033`·`:2092`·`:2571`·`:2834`·`:2856`。
**需实证**：`:1530-1531→1550`（`&v` 的 pointee 型行身份）· `:2023-2024`（`_arg` 打包槽）· `:2527-2528`（侧表继承——取决于是否选候选 ③）。
**其它文件**：`opt.cr`（零类型读，纯 opcode/CSE）· `ptr_analysis.cr`（零 `irv_type`，Andersen 按 opcode）· `dataflow.cr`（零类型；`:464` 明注 `iri_tk` 是派生码）· `region_check.cr:62/98/118` 与 `provenance_verify.cr:66`（皆判 `TYP_PTR`；`TI_DEX_S` 与 `TI_INT` 同 kind ⇒ **不会变**）· `monomorph.cr`/`checker.cr`/`src/targets/*`（零命中）。
**解释器**：`interp.cr:293/298/304/310/609/616/624/632`——**全部只判容器是否 `TI_STR`**，与结果槽无关 ⇒ **不会变**；`ir_interp_binary:37-49` 按 opcode 分派、不读型 ⇒ 零消费点。

### 3.2 后端（`src/arch/x86_64/` · `src/os/linux/` · `src/format/elf/`）——**只有两个真变化点**

| 点 | 判定 | 依据 |
|---|---|---|
| **`regalloc.cr:680-681`** | **会变** | `ty == TI_DEX \|\| TI_DEX_S \|\| TI_DYN \|\| TI_UNIT ⇒ continue`（不建候选）。`TI_INT` 今天可分配 ⇒ 读槽由「可能驻寄存器」变「恒栈驻留」；同窗口其它 var 的分配可连带变 |
| **`tag2l.cr:117 / :126 / :128 / :135 / :137`** | **会变** | 规则 A/B/B′ 全部窄门 `irv_type(...) == TI_INT` ⇒ 读槽出入 tag 闭包；`g_x86_mw_tag_count`（`:157`）进 `pf_frame_size`（`frame.cr:51-67`）⇒ 帧尺寸与 `sub rsp` 立即数可能变（`elf.cr:998/1116`） |
| `callseq.cr:70/97/101/127/167/179` | **不会变** | 7 处全是 `== TI_DEX`；`TI_DEX_S` 与 `TI_INT` **同落整数类**（binary64 走 XMM、scaled 走整数寄存器——**本批不改变这一分工**） |
| `instr.cr` | **不会变** | 全文 `TI_DEX_S` 出现 **0** 次；`e2_load_var`/`e2_sd_*`/`IR_LOAD_FIELD:1137`/`IR_LOAD_INDEX:1313`/`IR_LOAD_INDEX_VAR:1349` 均无类型分支；`:386`·`:963` 只判 `== TI_DEX` |
| `frame.cr:51-67/119-168` | 间接 | 帧公式类型无关但含 tag 计数；`:160-168` 的「形参行清 tag」只覆盖形参 ⇒ 读槽本就不吃它 |
| `sizes.cr` | **不会变** | `instr_size(op)` 无类型入参 |
| `elf.cr` / `syscall.cr` / `entry.cr` / `ld.cr` / `resolve.cr` | **不会变** | 零类型分派（`elf.cr` 的 `TI_` 命中全是注释） |

**需实证**（缺证据，T1 必做）：① 读槽**今天是否真的带 tag**（若从不带 ⇒ tag2l/frame 零足迹）；② 读槽今天**是否真的被分配了寄存器**（若窗口冲突/带 hazard 位 ⇒ regalloc 零足迹）。

### 3.3 序列化面（**本批足迹的真源**）

| 产物 | 坐标 | 事实 |
|---|---|---|
| `.ccr` | `ccr_io.cr:631`（SYM 全局：`irv_type(gi)`）· **`:690`（SYM 函数 var 声明：`irv_type(row)`）** | **per-IR-var 型落盘** ⇒ 候选 ① 下，含 dex 聚合读的程序的 `.ccr` **字节变**（记录定长 ⇒ size 不变、sha 变） |
| `.ccr` 版本 | `CCR_VERSION = 9`（`ccr_io.cr:135`） | 本批**不改段结构** ⇒ 不 bump（但若最终方案触发落盘字节变化，按「禁的不是变化是无声变化」原则在报告里显式归因） |
| `.ccr` TYPE/IFACE 段 | `ccr_io.cr:380-390` · `ccr_types.cr:160-163` | 独立类型项表，**不承载 per-var 型** ⇒ 候选 ①（只给预置常量 `TI_DEX_S`，不 alloc）**不动 TYPE 段尺寸** |
| `.cir` | `cir_cache.cr:259`（`w64_cir(irv_type(v_idx))`）· `CIR_CACHE_VER = 17`（`:51`） | `.cir` 快照含 var 型 ⇒ 候选 ① 下暖/冷快照字节变（**语义一致**，两侧同源）；**`.cir` 不在 5 条 canary 内** |
| ELF | `elf.cr:55` | 无 IR 型面；但 §3.2 的两点会通过指令流间接改 ELF |

### 3.4 语料覆盖（**结论：锁定语料覆盖不到本批面**）

- **锁定 5 条**（`canary_values.tsv:88-92` / `test_canary_carrier.py:42`）：`canary_elf`+`pa_ccr`（`tests/suite/ptr_arith.cr`）· `pa_static_ccr` · `gt_ccr`/`gt_static_ccr`（`tests/suite/generics_test.cr`）。
- `ptr_arith.cr`：唯一聚合访问是 `&arr[2]`（`IR_ADDR_INDEX`，**不是** `:2655`）+ `*p`；**无 dex**。
- `generics_test.cr`：**有**聚合读（`:24`/`:58`/`:60`/`:67`/`:69` 的 `b.val` 等，声明型 = 泛型 `T` 实例化为 `int`/`str`），**但全档 `dex` 零出现**（`grep -n dex` 无命中）。
- ⇒ **预期：候选 ① 下 5 条 canary 全 IDENTICAL**（无 dex ⇒ `form = TI_INT` ⇒ 逐字节不变）。
- ⇒ ⚠ **同时必须写明的反面**：**锁定 5 条对本批目标面零区分力**（这正是上一批「`.ccr` 没变 ≠ 生成面没变」教训的镜像）。真正覆盖本批面的语料是**未锁定**的 `tests/suite/apx_conversion_test.cr`（`:15` dex 字段 · `:42/:44` 字段读 · `:47/:48/:51` 数组/切片元素读 · `:55` 元组元素读 · `:73` 比较 · `:85/:89` 枚举载荷）+ **本批新增探针**。
- ⇒ **副产物**：锁定 5 条是**实现口径的判别器**——若有人把候选 ① 做成**无条件**（不判声明面）施加，`generics_test.cr` 的 `b.val` 读槽会翻成 `TI_DEX_S` ⇒ `gt_ccr`/`gt_static_ccr` **必变**。**这条回归本身就能抓住「口径错误」**，须写进 Global Constraints。

---

## 4. 判据设计（**本批最容易搞错的地方**）

### 4.1 预期足迹总表

| 判据 | 期望（候选 ①，且实现只对 dex 生效） | 若不符 ⇒ 处置 |
|---|---|---|
| ELF canary `95084e7b…d475`(28822B) | **IDENTICAL** | 停，查口径 |
| `.ccr` 四条（96015/96158/142765/142908） | **IDENTICAL** | 停，查口径（极可能是「无条件施加」） |
| 74 档 parity `check` rc | **逐档全同** | 逐档归因 |
| 29 行为探针 rc | **全同**（`p_spawn` rc=0） | 停 |
| `p_dex`/`apx_conversion_test.cr` 等 dex 档 | **产物字节可变**（预期内）⇒ 按「旧值+新值+归因+出处」重锁或留痕 | — |
| 新探针（腿 A/B） | 全绿 | 停 |

### 4.2 探针设计表（**本批必须自建判据网**，canary 帮不上忙）

| 腿 | 内容 | 判据形态 |
|---|---|---|
| **腿 A（语义值）** | R1 `x := s.f; x * 2.0` · R2 match 载荷 · R3 局部数组元素 · R4 元组元素 · R5 `g_apx = s.f` · R6 extern 实参 · R7 Core 调用实参 | `build --static` + **运行值**断言（期望值 = scaled 语义下的精确值）；**双路径**（`run` + ELF） |
| **腿 B（界面断言，**TODO #2026-09-16-16 判据③**）** | 同一批源，`cir`/`ccr` 转储断言**读槽 `irv_type` = `TI_DEX_S`**（≥6 例，逐读点：字段/元素/切片/载荷/嵌套/LET 中转） | 机制面正据（**不依赖运行值**——能在语义面还没接线时先红） |
| **腿 C（回归）** | 74 档 + 29 探针 + 锁定 5 条 + `interp_parity` + `selftest-types` | rc/sha 对拍 |
| **腿 D（突变控制）** | ① **关掉 apx hack**（`:1285-1286` 注释掉）⇒ 腿 A/B **仍须全绿**（证明通用机制独立成立）；② **把读点改成无条件 `TI_DEX_S`** ⇒ 锁定 5 条**必红**（证明 canary 判别器有效、口径不是摆设） | 两条突变都必须按预期红/绿 |
| **腿 E（口径边界）** | 非 dex 聚合读（`int` 字段/数组）**必须零足迹**：产物与改前逐字节相同 | 逐字节 `cmp` |

### 4.3 「今天绿」的非回归钉子（N1）

apx 批已转正的 B-3/B-4/B-5/B-6/B-8 探针（`tests/selfhost/test_apx_conversion.py` + `tests/suite/apx_conversion_test.cr`）**本批不得回退**；且它们**必须继续在「关掉 hack」下成立**（腿 D①）。

### 4.4 hack 退役口径（**建议：本批只验证、不删**）

`dex_decl_form_of_expr` 在候选 ① 落地后对**其覆盖面内的形态**成为冗余。**建议**：本批**保留**该函数并加注释说明「通用机制已覆盖，退役候选」；**退役动作**留待腿 D① 连续两批绿之后（与 `elf.cr` 死文件教训同族：删之前要有独立判据证明无依赖）。

---

## 5. 与 #93 批的交互（预判 + 可证伪探针）

1. **#97（实参位泛型退化实例键）**：读点定型改变实参 IR 型 ⇒ `:1970-1976` 的**回落键名串**由 `"int"` 变 `"dex"` ⇒ `idf(s.f)` 的实例键变化。**这是「键更精确」的顺向修复**，但会**新增实例**（`.ccr` 里实例名/NOD 数变）⇒ 走「显式归因 + 同批留痕」。**探针**：`idf(s.f)` 与 `idf(x_dex_local)` 的实例名必须一致（照腿 D 手法）。
2. **#93 的 19 例 + 腿 D/E**：必须保持全绿（腿 C 已含）。特别注意 #93 的腿 B（`g(nosuchfn(1))` ⇒ `error[N06]`）与 `infer_call_args` 的 fail-closed 护栏——**本批不动 checker**，但若实施中确实需要动 checker 侧（不预期），**停下报维护者**。
3. **新暴露预判**：读点定型后，**此前被 `TI_INT` 掩盖的静默面**会开始「正确地报错或正确地算」——若哪一档从 rc=0 变 rc=1，按 #93 批纪律**默认回归嫌疑**逐条归因，**不许把「新增诊断」当修好**（`2026-09-16-criteria-strength-audit.md` §0quater）。

---

## 6. 裁决门（逐条：问句 / 影响 / 推荐 / 未取裁时行为）

| # | 问句 | 影响 | 推荐 | 未取裁时行为 |
|---|---|---|---|---|
| **裁-AGG-1** | 候选 ①（改 `irv_type`）vs 候选 ②（只补侧表）？ | ① = 真堵总闸、满足判据③，代价 = dex 聚合读程序的 ELF/`.ccr` 字节足迹（regalloc 栈驻留 + tag 出闭包）；② = 零足迹，但总闸只堵一半、判据③不可满足 | **①**（并把 ② 作为「若维护者要求零后端足迹」的备选） | 不实施 |
| **裁-AGG-2** | match 结果槽 `:2299` 是否纳入本批？ | 多臂异型 ⇒ 需臂分析；不纳入 = 留一个已知未覆盖面 | **不纳入**（登记 U1），本批只做四个读点中的三个 + 元素 | 不纳入 |
| **裁-AGG-3** | 元组数字下标（无声明面）怎么办？ | 影响 R4 能否转正；无声明面 ⇒ 只能从**元组构造点**登记元素形式（新机制）或**登记未覆盖** | **登记未覆盖**（U2）+ 保留 hack 覆盖其比较形；**不引入新机制** | 登记 |
| **裁-AGG-4** | 泛型字段/元素（`Box[T].val`，声明型 = 类型参数）？ | `TY_DEX` 判定对类型参数为假 ⇒ 泛型实例化为 dex 时本批**不覆盖** | **登记未覆盖**（U3），与 #97 交互面单列 | 登记 |
| **裁-AGG-5** | hack（`dex_decl_form_of_expr`）本批删不删？ | 删 = 少一处 hack；不删 = 冗余但安全 | **不删**，加「退役候选」注释；删除留待腿 D① 两批绿 | 不删 |
| **裁-AGG-6** | `IR_ALLOC` 的 tk（`ir_gen.cr:2300`）与 `IR_DYN_PACK` 的 tag（`:1407/:2509`）是否同批拉齐？ | 拉齐 = 更一致；不拉 = 保持改面最小 | **只改结果槽型，不主动改 tk/tag**（让它们随值型自然变；变了要归因） | 不动 |
| **裁-AGG-7** | `.ccr`/`.cir` 若如预期**不变**（锁定语料零 dex），是否仍要 bump 版本号？ | 不 bump = 旧产物仍被命中（**语义一致**，因为变化只发生在 dex 聚合读程序——它们的旧 `.ccr`/`.cir` 与新版**不等价**！） | **需你裁**：建议 **bump `.cir`（`CIR_CACHE_VER` 17→18）+ 对 `.ccr` 按「同版本号但语义变了」的风险给结论**。§10 U5 给出两种口径的代价 | 停，等裁 |
| **裁-AGG-8** | 腿 D②（无条件突变）导致锁定 5 条必红——是否把该突变固化为常驻判据（照判据批 22/22 先例）？ | 固化 = 防「口径被改宽」；代价 = CI 时间 | **固化**（一行开关 + 期望必红） | 不固化 |

---

## 7. 任务表

| 任务 | 内容 | 出口判据 |
|---|---|---|
| **T1** | **零构建侦查复核**：① 逐条实核 §3.2 的两个「需实证」（读槽今天是否带 tag / 是否分到寄存器）；② 实读调用环 `:1810-1848` 定 R7；③ 把 R1–R7 写成探针源并跑**改前基线**（预期：静默错值/139） | 每条 RED 都有「改前实测值」（不许只写预判） |
| **T2** | **先裁落纸**（八门结论）+ 探针入库（RED 状态，白名单登记） | 门逐条有裁决 |
| **T3** | **实施**：声明形式判定函数 + 3 读点定型（+ 若裁-AGG-1 选②，则 6 判定点改取型） | 腿 A/B 转绿；腿 E 零足迹 |
| **T4** | **判据复验**：腿 C 全量 + 腿 D 突变 + 腿 E + 锁定 5 条 + 重锁判定（若有 dex 档产物变） | 全绿 + 逐条归因 |
| **T5** | **收官**：TODO #2026-09-16-16 状态 + 批报告 + 未覆盖面登记（U1–U4）+ 交叉引用（#97/#93/审计表 B） | `jj status` 干净 + 五 CI job |

---

## 8. Global Constraints（写入实施期的硬约束）

1. **GC12′**（本批重述，见 §1.1）：ir_gen 路径**不得新增可能 alloc 的类型站点**；本批一律用**节点判**（`ast_kind(tn)==0 && ast_type_val(tn)==TY_DEX`）与**纯表读**（`get_type_kind/get_type_data`），**不调** `res_type_node`/`alloc_type`/`alloc_named_type`。
2. **口径门**：定型**只对声明面为 dex** 生效；**非 dex 聚合读逐字节不变**（腿 E 是这一条的判据）。
3. **canary 判别器**：锁定 5 条**必须 IDENTICAL**；同时报告必须写明「本批 canary 对目标面零区分力」——**不得**用 canary 绿代替本批判据。
4. **无名变化禁止**：任何 `.ccr`/`.cir`/ELF 字节变化必须**逐档归因 + 旧值/新值/出处**（含 dex 档）；**若出现预期外变化 ⇒ 停**（停条件 2）。
5. **不许把「新增诊断/新增失败」当修好**（判据批 §0quater）。
6. **毒丸守卫**：改动若需动 `checker.cr`（不预期）⇒ **停下报维护者**。

---

## 9. 停条件（命中即停、报维护者，不自行放宽）

1. 锁定 5 条 canary 出现**任何非预期变化**。
2. **任何非 dex 聚合读**程序的产物字节变化（= 口径泄漏）。
3. 腿 D①（关 hack）下腿 A 出现红 ⇒ 说明通用机制**覆盖面不足**（不是「hack 冗余」）。
4. 74 档出现 rc 由 0→1 的档且**归因不清**。
5. 实施中发现必须复用「那 5 个声明面 API」（GC12 原口径）才能推进。
6. `.cir`/`.ccr` 版本号 bump 的裁决（裁-AGG-7）未取裁之前，涉及产物锁定的 T4 步骤不得开工。

---

## 10. 未决项（U）

- **U1**：match **结果槽** `:2299`（多臂异型，需臂分析）——本批登记不修。
- **U2**：**元组**元素（无声明面；`field_ti_of_node:360` 显式返回 -1）——登记；其「比较形」今天靠 hack 兜（`dex_decl_form_of_expr` 对 `ast_type_val > 0` 也返回 0 ⇒ **其实连 hack 也没覆盖**，R4 的 RED 属性待 T1 实测确认）。
- **U3**：**泛型**字段/元素（声明型 = 类型参数 T）——本批不覆盖；与 `TODO #2026-09-16-35`（退化实例键）**同面**，建议后续批合并处理。
- **U4**：**extern 实参**（R6）——extern 的 dex 语义有历史契约（①b「apx 实参原样保留恰合 C ABI」）⇒ 本批改动是否**应当**影响 extern 形**需维护者确认**（否则 R6 应从腿 A 移除、改列「语义待定」）。
- **U5**：**`.cir`/`.ccr` 是否 bump**（裁-AGG-7）：口径 A = 不 bump（理由：锁定 5 条不变、且变化只落在 dex 聚合读程序）；口径 B = bump `.cir` 17→18（理由：旧 `.cir` 快照里读槽型是 `TI_INT`，与新建的 `TI_DEX_S` **不等价** ⇒ 同一源文件在修复前后会命中不同语义的旧快照，**这正是 #8 缓存事故的同族**）。**建议口径 B**（bump `.cir`）+ **`.ccr` 侧**同步给出结论（`.ccr` 无「快照复用」语义 ⇒ 可只留痕不 bump，但须写成显式声明）。
- **U6**：**超大 scaled 值的 tag 语义**（§3.2）：读槽掉出 tag 闭包后，若该值参与 2L（多字）路径的算术，语义是否仍正确 —— 需一条**边界探针**（构造 |scaled| 接近 2⁶² 的 dex 字段值 + ADD/MUL）实证；不成立 ⇒ tag2l 需要把 `TI_DEX_S` 纳入闭包（届时**改面扩大**，须回取裁）。

---

## 11. §T1 记录（2026-09-16 —— 前置 + 冻结基线 + R1–R7 **改前实测**）

> 维护者裁决（2026-09-16）：八门**全按推荐**（裁-AGG-1=① · -2/-3/-4 登记 · -5 hack 不删（退役判据=腿 D① 连绿两批）· -6 不改 `IR_ALLOC` tk/`IR_DYN_PACK` tag · -7 **bump `CIR_CACHE_VER` 17→18** 且四要素齐 · -8 突变固化）· **U4 裁：extern 边界 = 规范化成 ABI binary64**（⇒ R6 进腿 A，期望 = 转换）。

### 11.1 前置与冻结基线（实核）

- 起点 `develop = 99ae6bdd`；分支 `feature/agg-read-type`（本记录 = 该链首个提交）。
- **冻结基线（改前二进制）** = 现成 `build/corec` + `build/corearch`；**同源证明**：`jj diff --from e7243955 --to develop --stat -- src/compiler src/arch src/os src/format build_selfhost_native.py` = **0 files changed**（该二进制所建源面与 `develop 99ae6bdd` 逐字节同）⇒ 即「改前基线」。
- 备份 + sha256：`/tmp/agg-t1/pre/corec` = `a689de9a205a2c1f…` · `/tmp/agg-t1/pre/corearch` = `8dd89647971f6af3…`。
- **命令纪律（本轮踩到，留痕）**：① `corec build` 必须在**仓库根**跑（否则 `error: cannot locate src/runtime/rt.cr`）；② 重定向到**已存在**日志文件被 noclobber 拦 ⇒ 命令根本没跑、读到的是上一轮旧日志 ⇒ **假红**（本轮首轮 8/8「失败」即此）⇒ 改用 `>|` + 新路径。

### 11.2 探针源（8 档 · T1 实测稿；入仓/挂点见 T2）

```core
// R1 · LET 中转丢型
struct S { f: dex }
fn main() -> int {
    d : dex, apx = 7.0;
    s : ., mut = S { f = d };
    x := s.f;
    if x * 2.0 != 14.0 { return 1; }
    return 7;
}

// R2 · match 臂载荷绑定
enum E { V(dex) }
fn main() -> int {
    d : dex, apx = 7.0;
    e : ., mut = V(d);
    return match e { V(x) => { if x * 2.0 != 14.0 { return 1; } return 7; } };
}

// R3 · 局部数组元素读
fn main() -> int {
    d : dex, apx = 7.0;
    a : [dex; 2] = [d, 1.0];
    if a[0] * 2.0 != 14.0 { return 1; }
    return 7;
}

// R4 · 元组元素读（数字下标无声明面）
fn main() -> int {
    d : dex, apx = 7.0;
    t := (d, 1.0);
    if (t . 0) * 2.0 != 14.0 { return 1; }
    return 7;
}

// R5 · 聚合读写回 apx（binary64）槽
g : dex, apx, mut = 1.0;
struct S { f: dex }
fn main() -> int {
    d : dex, apx = 7.0;
    s : ., mut = S { f = d };
    g = s.f;
    if g != 7.0 { return 1; }
    return 7;
}

// R6 · extern 实参（判定形态 = IR 断言，见 11.6）
struct S { f: dex }
extern fn dex_agg_arg_check(d: dex) -> int;
fn main() -> int {
    d : dex, apx = 7.0;
    s : ., mut = S { f = d };
    r := dex_agg_arg_check(s.f);
    return r;
}

// R7（非回归钉子）· Core 调用实参
struct S { f: dex }
fn dbl(x: dex) -> dex { return x * 2.0; }
fn main() -> int {
    d : dex, apx = 7.0;
    s : ., mut = S { f = d };
    y := dbl(s.f);
    if y != 14.0 { return 1; }
    return 7;
}

// N1（非回归钉子）· apx 批已转正的比较/raw 形
struct S { f: dex }
fn main() -> int {
    d : dex, apx = 7.0;
    s : ., mut = S { f = d };
    if @raw_int(s.f) / 1000000 != 7 { return 1; }
    if s.f != 7.0 { return 2; }
    return 7;
}
```

### 11.3 改前实测（冻结基线编译 + `--static` 产物运行）

| 探针 | 期望 | **改前实测** | 判定 |
|---|---|---|---|
| R1 LET 中转 | 7 | **1** | **RED**（静默错值） |
| R2 match 载荷 | 7 | **1** | **RED** |
| R3 局部数组元素 | 7 | **1** | **RED** |
| R4 元组元素 | 7 | **1** | **RED** |
| R5 写回 apx 槽 | 7 | **1** | **RED** |
| R6 extern 实参 | （IR 断言，§11.6） | **run_rc = 139**（静态链既有崩溃面） | **RED**（正据 = IR 面，§11.4） |
| R7 Core 实参（钉子） | 7 | **7** | **绿**（与读码判定一致 ⇒ 归类修正，§11.6） |
| N1 apx 批已转正形（钉子） | 7 | **7** | **绿** |

全部 8 档 `check` = 0 error（**无诊断**：这正是「静默」的实测证据）。

### 11.4 IR 级机理正据（比 rc 更强的钉子）

| 探针 | cir 证据（改前） | 读法 |
|---|---|---|
| **R1** | `load_field field = s.0` → `const _dsc = 1000000` → `binary _dxt = x * _dsc` → `binary _dxm = _dxt * dex` | **读槽被当 int 二次缩放**（`dex_scale_int` 的 ×S）⇒ 值放大 10⁶ |
| **R3** | `--dump-entries`：`var 40 name=elem kind=LOAD_INDEX` 之后依次 `_dsc`(1e6 常量) → `_dxt`(BINARY) → `_dxm`(BINARY) | 同上，另一读点 |
| **R6** | `load_field field = s.0` → `call_extern dest=call s1=6 s2=36 s3=1` ——**中间零转换**（既无 scaled→bits，亦无位模式常量重发射） | extern 契约破坏的**正据**（今天为空序列） |
| **R7**（钉子） | `load_field field = s.0` → `call dbl(field)` ——零转换**且正确** | Core 形参物化 scaled ↔ 读值 scaled **同形** ⇒ 直传正确 |

### 11.5 两条「需实证」的实核结论

1. **tag 面（§3.2 ①）——收窄（T1 结论）**：读槽**从不作 `IR_BINARY ADD/SUB` 的 dest**（dest 恒是新槽 `bin`/`_dx*`），而 tag 规则 A（`tag2l.cr:117`）只标 ADD/SUB **dest**；且精确路径的结果槽 `_dxm`/`bin` 在**改前/改后同为 `TI_DEX_S`**（`ir_gen.cr:1338/1342` 硬编码）⇒ **R1/R3/R4 预期无 tag 差异**；tag 足迹只可能出现在「非 dex 聚合读」的整数路径，而那条路径被声明面门控 ⇒ **预期零 tag 足迹**。最终以 T3/T4 改前/改后对拍为准（帧尺寸 + `.ccr` 尺寸）。
2. **regalloc 面（§3.2 ②）——读码确证、足迹待对拍**：`regalloc.cr:680-681` 对 `TI_DEX_S` 不建候选（读码确证）；读槽今天 `TI_INT` ⇒ 有资格进候选（是否真命中窗口/无 hazard 位需 T3 对拍）。**预期足迹** = 该槽由「可能驻寄存器」变「恒栈驻留」。

### 11.6 归类修正（T1 实测结论 ⇒ 改口径）

- **R7：「RED 候选」→「非回归钉子」**（读码 + 实测双证：今日 rc=7）。**修后必须仍绿**。
- **R6：判定形态「运行值」→「IR 级断言」**：extern dex 调用的**静态链运行路径既有崩溃**（`tests/suite/ffi_test.cr:8-11` 头注明载「运行时 FFI 被 corearch `--link` 静态路径既有崩溃阻塞」⇒ 该档只声明不调用），实测 `run_rc = 139`。⇒ 照既有先例 `tests/selfhost/test_dex_arith.py::test_extern_dex_arg_cir` 用 **cir 断言**判定；本批断言 = 「`load_field` 与 `call_extern` 之间**必须出现**转换序列」（**改前为空 ⇒ RED 正据已取，见 §11.4**）。
- **U4 裁后口径**：extern 边界 = **规范化成 ABI binary64**（`ir_gen.cr:1900-1907` 只做 `TI_DEX_S → bits`）⇒ R6 期望 = **转换**（不是「不变」、也不是「转 scaled」）。

### 11.7 批报告必写条目（维护者指定；T5 不得遗漏）

1. **镜像教训**：「`.ccr` 没变 ≠ 生成面没变」（#93 批）↔「**`.ccr` 没变 ≠ 这个面被覆盖了**」（本批）——两句合起来才完整：**判据的「绿」只在它的覆盖域内有意义**。
2. **GC12 的自我修正顺序**：先查出 `res_type_node` 对**基类型节点**是纯查表零 alloc、把规则**改准**，再决定**不用它**（本批一律不调）——「先把规则改准，再决定用不用」。

### 11.8 T1 未决（转 T2/T3）

- T1-1：R1–R7 的**入仓形态**（py 套件内联源 + 白名单登记 + 挂点）——T2 做。
- T1-2：R6 的 cir 断言**精确正则**（转换序列在 computed 值下的实际指令形态）——T3 实施时按实际 cir 落地。
- T1-3：`CIR_CACHE_VER` 17→18 的**注释文本**与 `.ccr` 显式结论的落点（报告 + 代码注释）——T3/T5。

---

## 12. §T2 记录（2026-09-16 —— 探针入仓 + 白名单 + 两条陷阱落仓 + T3 验收形状）

> 维护者 T2 放行（2026-09-16）：① R7/R6 归类修正**确认**；② 两条陷阱**必须落仓级文档**（不能只活在报告里，
> 判据 = 下一个人搜「noclobber」能在仓里搜到）；③ T3 判据补「**槽型正确 + 无重复转换**两条都要」。

### 12.1 探针入仓（RED 语料）

- **新文件**：`tests/selfhost/test_agg_read_type.py`（**未挂 CI**，白名单有条目）。
  - **腿 A（语义值）**：R1 LET 中转 · R2 match 载荷 · R3 局部数组元素 · R4 元组元素 · R5 写回 apx 槽
    （期望 `elf=7`）。
  - **腿 C（非回归钉子）**：R7 Core 调用实参 · N1 apx 批已转正形（改前即绿、修后须仍绿）。
  - **腿 B（界面见证，见 12.3）**：B1/B2 反方向（无 `_dxt`）· B3 正方向（`_dxdiv` 恰好 1）· B4 extern
    调用点前须有转换。
- **改前实测（`build/corec` = 冻结基线 `a689de9a…`）**：腿 A **5/5 红**（`elf=1`，`check` 0 error）
  · 腿 C **2/2 绿**（`elf=7`）· 腿 B **4/4 红**（`_dxt`×1 / `_dxt`×1 / `_dxdiv`=0 / 无转换）
  ⇒ **整档 9 项失败**，与 §11 的 T1 实测一致。
- **白名单条目**（`tests/harness/ci_hook_allowlist.txt`）：写明「RED 语料，勿挂」+ 修复批三件套
  （删条目 + 挂 `run.sh` + 改头注）。

### 12.2 两条陷阱落仓级文档（维护者要求）

- **落点**：`tools/baseline/REBUILD.md` 新增 **`### 命令层陷阱（假红）`**（置于「换代纪律」之前，
  与既有「口径限制 / 已知限制」同区）——① `noclobber`：重定向到已存在日志 ⇒ **命令根本没跑**、
  读到上一轮旧日志；② `corec build` 必须在**仓库根**跑（否则 `cannot locate src/runtime/rt.cr`）。
  两条**叠加**时表现为「整批探针全失败」（#78 T1 首轮 8/8 假红）。
- **判据**：`grep -rn noclobber tools/` **命中该文件**（仓级可搜）。批报告（T5）另单列一节。

### 12.3 T3 验收形状（**维护者指定：槽型正确 + 无重复转换，两条都要**）

R1 的 IR 证据（§11.4）给出**判据形状**：

> 修后 `load_field` 的**结果槽类型**必须是 `TI_DEX_S`（而非 `TI_INT`），且**下游不得再出现那次多余的
> `× _dsc`**——后者是**「转换不重复」**的判据（**既不能漏转，也不能转两遍**）。

**落进套件的形态**（= 腿 B，已实现，**两个方向都取门控忠实的见证**）：

| 见证 | 门（唯一真源） | 出现 ⇒ 断言 |
|---|---|---|
| **`_dxt`**（`const _dsc = 1000000` + `binary _dxt = <v> * _dsc`） | `dex_scale_int:1033-1040` 的门 `irv_type(var) == TI_INT` | **出现 ⇒ 读槽仍是 `TI_INT`**（反方向）⇒ R1/R3 要求计数 **0** |
| **`_dxdiv`**（`i2f _dxf` + `const _dxsc` + `binary _dxdiv = _dxf / _dxsc`） | `dex_scaled_to_bits:1016-1029` 的门 `irv_type(var) == TI_DEX_S`（且非字面量） | **出现 ⇒ 读槽已是 `TI_DEX_S`**（正方向）⇒ R5 要求计数 **恰好 1**（= 槽型正确 **且** 不重复转换） |
| **`load_field … call_extern` 之间的序列** | extern 分支门 `irv_type(av) == TI_DEX_S`（`:1902`） | **必须非空**（R6；改前为空 = RED 正据） |

> **为何用「门控忠实见证」而不是直接读槽型**：`.cir` 文本转储**不打印普通 IR 变量的类型**
> （`dump.cr:50-60` 的 `type_kind_name` 只在 `alloc`/`const` 行输出，且 `TI_DEX`(1) 与 `TI_DEX_S`(8)
> **同名 "dex"、不可区分**）；权威通道 = `.ccr` SYM 的 per-var 型字节（`ccr_io.cr:690`），但那要写
> 二进制解析。⇒ 本批先用**门控见证**（其门**恰好**是我们要断言的类型谓词 ⇒ 忠实），
> `.ccr` SYM 解析列为 **T3 可选加固**（若 T3 顺手，加一条直接断言更佳）。

### 12.4 裁-AGG-7 的落点（bump 文案与 `.ccr` 结论）

- **`CIR_CACHE_VER` 17→18**（`cir_cache.cr:51`）——**T3 实施**，注释文案（须写清原因）：
  > `// 18：TODO #2026-09-16-16「聚合读丢型」——聚合读结果槽型由 TI_INT 改为声明面形式（dex 声明 ⇒ TI_DEX_S）。
  > //     旧快照里读槽型 = TI_INT，与修复后语义**不等价** ⇒ 命中旧条目会复活「丢型」的坏 IR。
  > //     与 TODO #2026-09-10-4（缓存键缺编译器身份）**同族**：cache miss = 无害重建。`
- **`.ccr`：不 bump**，但**报告须写明**「**dex 程序的 `.ccr` 内容会变**（格式不变、内容变）」——
  防后来人把「版本没 bump」读成「内容没变」。落点 = 批报告 §判据 + `.ccr` 段。
- **判据**：cache miss ⇒ 无害重建（照 TODO #2026-09-10-4 收口口径）；canary/五条**不受影响**（无 dex）——
  与**停条件①**（非 dex 聚合读任何字节变化 ⇒ 停）**互为印证**。

### 12.5 T2 未决（转 T3）

- T2-1：`.ccr` SYM per-var 型解析（可选加固，见 12.3 注）。
- T2-2：`run.sh` 挂点与头注转正（**T3 修复后**的三件套第二步）。
- T2-3：R6 的断言在 T3 实施后需**按实际 cir 形态复核**（转换序列可能随实现口径变化）。

---

## 13. §T3 记录（2026-09-16 —— 实施 + 判据 + 突变 + 换代重锁）

> 维护者 T3 放行（2026-09-16）：① 事故「我担一半」+ 正确配方入派单口径；② 门控见证设计获肯定（「先确认工具链能不能表达 X」）；
> ③ 实施口径 = 声明面形式判定 + 3 读点定型 + `CIR_CACHE_VER` 17→18 + 腿 A/B 转绿 + 挂点三件套；判据 = 腿 A 5/5（**见 §13.4 冲突**）·
> 腿 B 四条见证 · 腿 C 钉子 · **停条件①**（非 dex 任何字节变化 ⇒ 停）· **停条件②**（关 hack 后腿 A 红 ⇒ 停）。

### 13.1 实施（**零 alloc 通道**；3 读点 + 1 处 bump + 挂点三件套）

| # | 位置 | 改动 |
|---|---|---|
| ① | `ir_gen.cr`（`enum_payload_ti` 之后新增）| **4 个节点级 helper**：`agg_read_form_is_dex`（`ast_kind(tn)==0 && ast_type_val(tn)==TY_DEX`——**不调** `res_type_node`）· `agg_field_read_form`（`si_field_type_node` + 节点判；数字元组下标 `ast_type_val>0` ⇒ `TI_INT`）· `agg_elem_read_form`（`elem_ti_of_decl(slot_decl_ti(arr))` **纯表读**；`TI_DEX`/`TI_DEX_S` 都归一到 `TI_DEX_S`——聚合存储恒 scaled）· `agg_payload_read_form`（`find_gsym`+`find_enum_row_of`+`ei_variant_type_node` + 节点判）|
| ② | 字段读（`:2647` 邻域）| `irv_set_type(v, agg_field_read_form(node, fi))`——**在 `fi` 解出之后**（位序无关，但语义要 fi）；非 dex ⇒ `TI_INT` = 原值 ⇒ **零足迹** |
| ③ | 元素读（`:2717` 邻域）| `irv_set_type(v, agg_elem_read_form(arr_var))` |
| ④ | match 载荷绑定（`:2450` 邻域）| `irv_set_type(fv, agg_payload_read_form(arm_pat, fi))`（`EXPR_ENUMPAT`：`a`=变体名 ni）|
| ⑤ | `cir_cache.cr:51` | `CIR_CACHE_VER` **17 → 18** + 注释（旧快照读槽型 `TI_INT` 与新语义**不等价** ⇒ 命中旧条目会复活坏 IR；与 TODO #2026-09-10-4 同族；cache miss = 无害重建）；并把历史条目「v18（不 bump——R2 P4 Task 4…）」改标题为「**[曾议 v18 而未 bump]**」避免与本次撞号 |
| ⑥ | 挂点三件套 | `run.sh` `selfhost-tests` **+1 行** · `ci_hook_allowlist.txt` **−1 条** · 套件头注转「已修」 |

### 13.2 判据（终态全绿）

| 判据 | 结果 |
|---|---|
| **腿 A**（语义值） | R1 LET 中转 · R2 match 载荷 · R3 局部数组元素 · R5 写回 apx 槽 —— **elf=7 全绿**（改前全 = 1）· R4 见 §13.4 |
| **腿 B**（界面见证） | B1 反方向 `_dxt`=**0** · B2 反方向 `_dxt`=**0** · B3 正方向 `_dxdiv`=**恰好 1** · B4 extern `load_field…call_extern` 之间有转换 —— **四条全绿**（改前四条全红）|
| **腿 C**（钉子） | R7（Core 实参）· N1（apx 已转正形）**全绿** |
| **停条件①**（非 dex 零足迹） | canary **5/5 IDENTICAL**（ELF `95084e7b…d475` 28822B + `.ccr` 四条）——`generics_test` 含 int/str 字段读而**零 dex** ⇒ 这条同时是「非 dex 读槽恒 `TI_INT`」的**行为证据** |
| 74 档 parity | rc **逐档全同**（35×0 / 39×1）· 暖腿 **FAIL=0**（41 档真命中）|
| 29 行为探针 | rc **与基线全同** |
| 挂点 harness | `test_ci_hook_coverage.py` **PASS**（scope=69 hooked=48 unhooked=21）|
| 五 CI job / 自举链 | §13.5 |
| **二进制同一性论证** | 注释/测试改动后**重建 = `64c8a7d6…` 与判据二进制逐字节同** ⇒ 已跑的 canary/parity/probes 结论对**终态**成立（不是「大概没变」）|

### 13.3 腿 D① 突变（**关掉 apx hack**）——**通过**

把 `:1342-1343` 两行 hack 注释化 → 重建 → 跑判据：**apx 批套件 23 例全绿 + 本批 6 例 + 腿 B 全绿**
⇒ **通用机制独立成立**（hack 的覆盖面被声明面机制完全接管）⇒ **hack 冗余确认**（退役判据「腿 D① 连绿两批」第一步达成）；
随后恢复源码 + 重建 + 复验（全绿）。

### 13.4 ⚠ R4（元组）与 T3 口径的**冲突**（须你裁）

- 你的 T3 口径写「腿 A **5/5** 转绿（R1–R5）」，但 **裁-AGG-3** 已裁「**元组**（无声明面）**登记，不纳入本批**」。
- 实测事实：元组构造（`ir_gen.cr` 的 `EXPR_TUPLE` 分支）给元组 var 定型 `TI_INT`、**不携带元素 ti** ⇒ 数字下标读（`t . 0`）**取不到声明面** ⇒ 本批的通道覆盖不到它（R4 修后仍 = 1）。
- **我的处置（按裁-AGG-3 执行，不静默）**：3 读点实施**不含元组**；套件把 R4 移入 **`[GAP]` 组**——**只观测、不计入判据**（打印期望值与实测值，注明裁决与出处）；后续批修复时须把它移回 `CASES`。
- **若要现在就覆盖元组**（最小机制，供你裁）：在元组构造点按「**全元素同形**」把该形式登记进**既有声明侧表**（`irv_set_decl_ti(tv, TI_DEX_S)`，2 行、零 alloc）；数字下标读再查 `slot_decl_ti(obj_var)`。
  **代价/风险**：`slot_decl_ti(tv)` 变 `TI_DEX_S` 会波及唯一取址面 `ir_gen.cr:1530`（`&tuple` 的 pointee 型行身份：`TYP_PTR(TI_INT)` → `TYP_PTR(TI_DEX_S)`）⇒ 需一条实证；且这是**新机制**，与「最小改动」口径相抵。**推荐：维持裁-AGG-3（登记）**。

### 13.5 五 CI job / 自举链（回填 · 全部 rc=0）

| job | rc | 关键内证 |
|---|---|---|
| `check` | **0** | corearch / corelsp `build log clean (error[ = 0, undefined = 0)`；`check src/compiler` 0 error |
| `bootstrap-tests` | **0** | bootstrap 套件全绿 |
| `selfhost-tests` | **0** | `test_ccr_types.py` **49/49** · `interp_parity` **23/23** · 本批套件（挂点后随 job 跑）全绿 |
| `suite` | **0** | **23 档 ALL PASS**（含 `apx_conversion_test.cr`）|
| `full-bootstrap` | **0** | `cmp /tmp/corec2 /tmp/corec3` **恒等**（2904726 B · sha256 `b8e4298ad0d7…`）|

> 命令口径：`CI_JOB_NAME=<job> bash src/ci/run.sh`（**argv 写法 = 假红**，见 `tools/baseline/REBUILD.md` 的命令层陷阱段）。

**二进制同一性论证**（§13.2 末行）：终态源码（注释/测试改动后）重建 = `64c8a7d6…` 与判据二进制**逐字节同** ⇒ 已在 T3 中期跑出的 canary/parity/probes 三组结论**对终态继续成立**（不是「大概没变」）。

### 13.6 换代重锁清单（**裁-AGG-7 的四要素**：旧值 · 新值 · 归因 · 出处）

| 载体 | 旧 → 新 | 处置 |
|---|---|---|
| `cir_cache.cr:51` | `CIR_CACHE_VER` 17 → **18** | 改常量 + 注释（归因写清）|
| `tests/selfhost/test_ccr_types.py` ㉛/㊲ + 模块头注 | 断言 `ver == 17` → **18** | 断言改 18 + 三处注释写明「旧值 17 / 新值 18 / 归因 / 出处」|
| `tests/selfhost/test_cache_identity.py` | `VER_EXPECTED` 17 → **18** | 同上（**布局未变** ⇒ `layout()` 的 v17 分支按 `VER_EXPECTED` 复用，无需新分支）|
| `src/compiler/dyn_arr.cr:112` · `src/compiler/ccr_io.cr:137` | 陈旧注释「CIR_CACHE_VER=17 不 bump」 | 注释更新 + 指向本批（**注释-only，零行为**）|
| `.ccr`（`CCR_VERSION=9`） | **不 bump** | 交付格式、无快照复用语义；但**报告须写明「dex 程序的 `.ccr` 内容会变」**（防「版本没 bump」被读成「内容没变」）|

> **重锁过程留痕**：首轮 `selfhost-tests` **rc=1**，两例因版本位（`test_p4t4_cir_snapshot_layout_unbumped` / `test_p5t2_snapshot_disk_code_preserved`）；重锁后**复跑又红**——但那次是**环境 flake**（同套件在干净缓存下 49/49 通过；改前二进制对照跑 47/49 = 恰为该两例版本断言，属预期）；第三次红 = `test_cache_identity.py` 的 `VER_EXPECTED` 未同步（本表第 3 行）⇒ 一并重锁后 **rc=0**。

### 13.7 未覆盖面（本批登记，供后续批）

- **U7 · `IR_SLICE` 产物的元素读**：切片 var 的 IR 型恒 `TI_INT`（且 `is_ptr_var:627` 对 `TI_DEX_S` **早退 0** ⇒ 改切片 var 型会改指针判断，**不可**用「给切片 var 定型」的办法）⇒ 切片元素的声明形式**无处寄存**（若要覆盖需新增侧表或换寄存面）。
- **U1** match 结果槽（裁-AGG-2）· **U2/U4 元组与泛型**（裁-AGG-3/-4）——已在 §10 登记，本批未动。

### 13.8 T3 未决（转 T4/T5）

- T3-1：`.ccr` SYM per-var 型的直接断言（可选加固；本批用门控见证 + canary/parity 覆盖）。
- T3-2：R4 的取裁（§13.4）。
- T3-3：腿 D①「连绿两批」的第二次（下批复跑本套件 + apx 套件且 hack 仍关）⇒ 达成后可删 hack（TODO #2026-09-16-16 追记）。
- T3-4：`.cn`/`.cir` 之外是否有第三处落 per-var 型的产物（本轮扫描：`ccr_io.cr:631/:690` 与 `cir_cache.cr:259` 两处，未见第三处）。

---

## 14. §T5 记录（2026-09-16 —— 收官）

### 14.1 交付

- **`TODO #2026-09-16-36`**（新条目；编号按 develop `66eb9589` 现状取 = 最大 #97 + 1）：**元组数字下标 + `IR_SLICE` 产物元素读**合成一条
  （现象 · 最小机制（元组构造点按「全元素同形」登记 `irv_set_decl_ti`，2 行零 alloc）· 代价与待实证（`&tuple` pointee 型行身份）·
  切片侧三候选 · 同族互引（#97/#91）· 修复时判据 · 状态登记未修）。
- **`TODO #2026-09-16-16` 状态 → ✅ 已修**（修法 + 判据 + 未覆盖面指向 #98）。
- **批报告**：`docs/superpowers/specs/2026-09-16-agg-read-type-batch-report.md`（§0 一行结论 · §1 提交链 · §2 根因修法 ·
  §3 判据 · §4 腿 D① 突变 · §5 二进制同一性论证 · §6 镜像教训 · §7 GC12 顺序 · §8 陷阱落仓 · §9 换代重锁 ·
  §10 R4 的 `[GAP]` 处置与裁决出处 · §11 判据可行性经验 · §12 未覆盖面 · §13 诚实边界）。
- 提交：`5a245777`（TODO）· `9de1c4c0`（报告）· 本记录。

### 14.2 收官判据复跑（**全绿**）

| 判据 | 结果 |
|---|---|
| canary | **PASS 5/5**（ELF + `.ccr` 四条 IDENTICAL）|
| `check` | rc=0（corearch/corelsp `build log clean (error[ = 0, undefined = 0)`）|
| `bootstrap-tests` | rc=0 |
| `selfhost-tests` | rc=0（含本批套件已挂点 · 49/49 ccr_types · 23/23 interp_parity）|
| `suite` | rc=0（23 档 ALL PASS）|
| `full-bootstrap` | rc=0（`cmp corec2 corec3` **恒等** 2904726 B）|
| **二进制同一性** | T5 重建 = `64c8a7d6…` 与判据二进制**逐字节同** ⇒ canary/parity/probes 结论对终态成立（§5 论证）|

### 14.3 批终态一行结论

**修好**（同报告 §0）：聚合读结果槽硬定 `TI_INT` ⇒ 总闸级连锁失明 —— 读点定型改**声明面形式**（零 alloc 节点判）+
`CIR_CACHE_VER` 17→18；**腿 A 4/5 转绿（R4 按裁-AGG-3 登记 `[GAP]`）· 腿 B 四条见证 · 腿 C 钉子 · canary 5/5 IDENTICAL ·
74 档/29 探针 rc 全同 · 五 CI job rc=0 · 自举链恒等 · 腿 D① 突变通过（hack 冗余确认）**。
