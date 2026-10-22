# TODO #2026-09-15-5 批实施计划：暖缓存诊断不报错地（warm-cache diagnostics）与检查体系有缓存状态分支

> 实施记录：[implementation/2026-09-15-warm-cache-diagnostics.md](../implementation/2026-09-15-warm-cache-diagnostics.md)

> 面向执行代理：必须使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans，按任务逐步执行本计划。用复选框（`- [ ]`）跟踪进度。

目标：消除暖 `.cir` 缓存命中后安全检查面诊断不报错地消失这一类缺陷（不安全程序从第二次编译起不报错地通过），并修复检查体系无法检测该面的元缺陷（给两条 runner 增加有缓存状态分支）。范围是两条检查：主要检查是 TODO #2026-09-15-5 缺陷，派生检查是检查体系有缓存状态分支。

架构：分五段。1 前置侦查、冻结基线、侧表面全集清点（T0，源码零改动）。2 根因验证（T1：空缓存状态和有缓存状态，加装载期不变量探针，确认疑似机制）。3 修法实现（T2，按裁决门取向；候选 a/b/c/d 见第 2 节）。4 检查体系有缓存状态分支（T3：`parity_run.sh`/`probes_run.sh` 增加「同源二次构建」检查）。5 检查复验、文档、清单（T4）。

Tech Stack / 基准点（本实例实读，行号 = 当前树 `1592a1b5`）：
- 缓存面：`src/compiler/cir_cache.cr`（`CIR_CACHE_VER = 17` `:51` · `save_cir_cache` `:187` · `load_cir_cache` `:436` · `cir_read_snapshot` `:401` · `cir_compiler_identity` `:95` · `make_cir_cache_dir` `:629`）；快照段 = 头（magic/ver/identity/fp/sig/name，v17）++ vars/24B（`name/id/type` 三字段全载）++ nodes/64B（op/dest/s1/s2/s3/派生码/first_edge/edge_count；两槽装载期重派生）++ edges/32B ++ instrs/48B ++ 字符串段 ++ SG 记录/48B（v13）。
- var 记录字段全集 = `name/id/type` 三（`dyn_arr.cr:429-434` `irv_*` 访问器），因此 var 表本身被完整移动。
- 类型行空间：`alloc_type(kind, data, extra)` = 只追加、不去重（`checker.cr:10-19`）；`ir_gen` 期 5 处分配（`:1403` `alloc_type(TYP_PTR, elem_ti, 0)` / `:1409` `alloc_type(TYP_PTR, irv_type(op_var), 0)` / `:2584` `alloc_type(TYP_ARRAY, …)` / `:2641` `alloc_type(TYP_PTR, get_type_data(target_ti), asp)`（`asp = get_type_extra(source_ti)` = `as *T` 的地址空间/外部标记）/ `:2951` `alloc_type(TYP_ARRAY, TI_INT, cnt)`），这些行不随快照（快照只存 var 的 `type` 行号，不存行内容）。
- 消费点（本缺陷的观测点）：`provenance_verify.cr:63-70`：`ptr_ti := irv_type(s1); if ptr_ti >= 0 && get_type_kind(ptr_ti) == TYP_PTR && get_type_extra(ptr_ti) != 0 { check_error(EC_TU_DEREF, "external pointer dereference requires unsafe", 0, 0) }`；`get_type_kind/data/extra` 定义 = `checker.cr:322-334`。
- build 路径时序：`main.cr:496-561`（逐函数缓存循环）改为 `:565` `df_state_finalize` 改为 `:597-603` 安全检查面（`ptr_analysis_all` `:598` 改为 `region_check_all`，再 `provenance_verify_all` 改为 `g_diag_count > base_diags` `:603`，因此 rc=1）改为 `:612` CSE，再 `:615` `lower_to_ccr` 改为 `ccr`/`build` 分支。
- 检查体系：`tools/baseline/parity_run.sh:32-40`（逐档 `clean-cache` + `check`）· `tools/baseline/probes_run.sh`（同款）· `src/ci/run.sh:68-113`（selfhost-tests 接入点）。
- 既有同族先例（必须继承）：`cir_cache.cr:1-50` 的 v12–v18 版本注，每一版都是「快照携带了会随进程态变化的量，因此不报错地类，所以 bump 或改设计」；本缺陷 = 同族第 N 例（v18 注已把「项表」按「不写入文件、装载期重派生」结束；类型行空间尚无同等处理）。

Spec / 依据： TODO #2026-09-15-5（本批主要检查；含「派生建议：runner 加有缓存状态分支」）· FC 批报告 `docs/archive/sdd/fc-task2-report.md` 第 7 节（空缓存/有缓存对照表：P6 期 `ae01de75…` 与本批 `d107b34b…` 同样的问题，因此预存）· `cir_cache.cr` 版本族注（v14/v16/v17/v18 的「不报错地类」检查）· FC 批 Global Constraints 的 fail-closed 精神（「宁可 miss 不可不报错地」）。

---

## 前置状态（本计划未运行任何构建/测试；下列全部为实读或既有报告记录值，出处逐条标注）

- 现象（FC T2 施工中实测，出处 `docs/archive/sdd/fc-task2-report.md` 第 7 节）：同一源、同一二进制，`clean-cache` 与否为唯一变量，空缓存状态 `error[TU03]` 报出（rc=1、无产物）；有缓存状态诊断消失，因此 rc=0 且照常产出 ELF（28822B）；`build --static` 与 `ccr` 两面同样的问题；P6 期二进制 `ae01de75…` 同值复现，所以预存。
- 复现源（最小）：`fn main() -> int { p := 4096 as *int; return *p; }\n`（= `tests/selfhost/test_pointer_safety.py:131-138` 的形态；`as *int` 带地址空间，因此 `alloc_type(TYP_PTR, …, asp)`）。
- 性质：不安全程序第二次编译起不报错地通过（「判定继续，因此不报错地错产物」的典型形态）。
- 检查未检查范围（元缺陷）：两条 runner 逐档 `clean-cache`（`parity_run.sh:35` / `probes_run.sh`），因此整个检查体系对该面无法检测；CI 五 job 亦不含有缓存状态分支。
- 既有缓解（部分面）：可选表示程序关缓存（`main.cr:488-491`：`g_optrep_on != 0，因此 cache_enabled = 0`，实读 `:491`），先例证明「关缓存」是本仓可接受的回退处理手段（本条是候选修法的基准）。

---

## 1. 根因侦查写进文档（T0/T1 的内容；已实读 vs 待实证 分明）

### 1.1 已实读的事实链（本实例逐条实读源码）

| # | 事实 | 基准 |
|---|---|---|
| F1 | 快照完整移动 var 表（`name/id/type` 三字段），`irv_set_type(v_id, v_type)` | `cir_cache.cr:436-500` 的 vars 段 |
| F2 | 快照不移动类型行内容（`g_types` 行 = `{kind, data, extra}`）；装载只恢复 行号 | `cir_cache.cr` 段清单（`:215-232`：vars/nodes/edges/instrs/字符串/SG，无 types 段） |
| F3 | `alloc_type` 只追加不去重，因此行号空间 = 分配序的纯函数 | `checker.cr:10-19` |
| F4 | `ir_gen` 期有 5 处 `alloc_type`（非前端），因此缓存命中（跳过 `ir_gen_func`）时这些行不会被分配 | `ir_gen.cr:1403/1409/2584/2641/2951` |
| F5 | 本缺陷的消费点读的就是行号，再 行内容（`get_type_kind/get_type_extra`） | `provenance_verify.cr:63-70` + `checker.cr:322-334` |
| F6 | 安全检查面在缓存命中路径上照常运行（`ptr_analysis_all` 等对全体节点运行），所以问题不在「pass 没运行」 | `main.cr:597-603` |
| F7 | `g_pts`/`g_offsets` 每次构建清零重算（`w64(g_pts, var_idx*8, 0)`），因此它们本身不是「缺失」源；但其输入含 F5 的行内容，所以缺陷经由类型行传导 | `ptr_analysis.cr:172-210` |
| F8 | 同族先例：v18 已把「项表」按「不写入文件、装载期重派生」结束（避免第二处定义 + 跨进程索引悬空）；类型行空间无同等处理 | `cir_cache.cr:24-50`（v18 注）+ `sh_tk_split_load` |
| F9 | 「关缓存」为本仓既有回退处理（可选表示程序即如此） | `main.cr:488-491` |

根因假说（待 T1 确证）：暖路径的行号空间与冷路径不一致，缓存命中跳过 `ir_gen_func`，所以 F4 的 5 处行不分配，因此后续函数/前端的 `alloc_type` 序号整体前移（或后移），而快照里的 `v_type` 行号是冷路径的编号，所以命中后 `get_type_kind(v_type)` 读到别的行（或未初始化行），因此 `== TYP_PTR && extra != 0` 不成立，所以 TU03 不报错地跳过。

### 1.2 缓存命中路径数据流（实读）

```
[逐函数] main.cr:535  `if cache_enabled != 0 { cached = load_cir_cache(cache_path, fi); }`
   ├─ 命中（`cached == 0`，main.cr:536-549）：恢复 vars/nodes/edges/instrs/SG；
   │    不执行 ir_gen_func（因此 F4 的 5 处 alloc_type、g_ir_locals、字符串常量、
   │    外链重定位、内层 SG push/pop 等生成期副作用全部缺席）
   └─ miss（main.cr:550-557；`ir_gen_func` `:552` + `save_cir_cache` `:556`）：ir_gen_func + save_cir_cache（冷路径，副作用全有）
[全函数后] main.cr:565 `df_state_finalize()`（链重建，幂等）
[安全面] :598 `ptr_analysis_all()` 到 `region_check_all()` 到 `provenance_verify_all()`，因此 `:603` 判定
，因此消费 irv_type（快照来的行号）+ 行内容（本次进程的行空间）所以 F5 的判定
```

### 1.3 侧表面全集（「进程内状态、快照不载」的候选面；T0 出「逐条实证版」）

> 约定：仅列生成期（`ir_gen`/`lower`/passes）建立且被缓存命中后的消费者读取的表。判定列 = 本实例实读结论（`是` 已重建 / `风险项` 不载，因此嫌疑 / `?` 待实证）。

| # | 侧表 | 建立期 | 快照是否载 | 消费者 | 判定 |
|---|---|---|---|---|---|
| 1 | `g_types` 行内容（`{kind,data,extra}`） | 前端 + `ir_gen`（5 处） | 不载（只载行号） | 判定引擎桥接 / ICE04 / TU03 检查 / `type_size` / `lower` | 风险项 本缺陷主嫌（F2/F4/F5） |
| 2 | `g_ir_locals`（局部变量表） | `ir_gen` 逐函数 | 不载 | `lower_to_ccr` / 帧布局 | 风险项 嫌疑（T1 实证：命中函数的 local 计数/内容） |
| 3 | `g_ir_str_consts`（字符串常量池） | `ir_gen` 逐函数 | 部分（快照有字符串段，`:221-227`，须实证覆盖面） | `.ccr` STR 段 / 运行期常量 | ? 待实证 |
| 4 | `g_x86_ext_rel_*`（外链重定位表） | `ir_gen`（`IR_CALL_EXTERN` 等） | 不载 | corearch 静态链接符号解析（`ctx_emit_static` 的 unresolved 检查） | 风险项 嫌疑（命中，因此重定位缺失，所以 F162 类不报错地？） |
| 5 | `g_df_node_region` / `g_sgs` 内层 region | `ir_gen`（`sg_push/sg_pop`） | 部分（v13 载 SG 记录；装载把节点归属到 `g_cur_sg`） | `region_check`（B011）/ `subgraph_containing` / DFG DOT | 风险项 已知近似（`cir_cache.cr` 装载段自注「Minor #4」） |
| 6 | `g_ir_var_rep` / `g_ir_var_decl_ti`（可选表示侧表） | `ir_gen` | 不载 | 解包点表示判定 | 是 已由「可选程序关缓存」缓解（`main.cr:488-491`） |
| 7 | `g_pts` / `g_offsets` / `g_pa_alloc_nodes` | `ptr_analysis_all`（每次构建） | 不载（且不需） | `provenance_verify` / `region_check` | 是 每构建清零重算（F7），但输入受 #1 污染 |
| 8 | `g_type_terms` / `g_term_map`（项表/映射） | emit 期按需追加 | 不载、装载期重派生（v18 设计） | 判定引擎 / `.ccr` TYPE 段 | 是 已结束（F8） |
| 9 | 状态链（state 边） | `df_state_finalize`（幂等） | 不载（v15 起设计如此） | 纯度/效应面 | 是 |
| 10 | `g_ir_globals` / `g_x86_is_global` | `ir_gen_globals`（循环前一次） | 不载 | 全局寻址 | 是（循环前运行，与命中无关） |
| 11 | 前端族（`g_syms`/`g_funcs`/`g_structs`/`g_enums`/`g_ifaces`/`g_impl_for`/`g_methods`/`g_type_aliases`/`g_gen_*`/`g_borrow_*`/`g_global_lets`/`g_cov_bits`/`g_purity_inst_*`/`g_line_fileid`/`g_segs`） | `tokenize`/`check_all`（每次构建） | 不载（且不需） | 各前端消费者 | 是 前端每次全运行（`main.cr:440` `run_frontend` 在缓存循环之前） |
| 12 | `g_ccr_type_seg`/`g_ccr_iface_seg`/`g_ccr_nod_item`（段体缓冲） | `ccr_seg_prepare_save`（save 前） | 不载（且不需） | `save_ccr` | 是 |
| 13 | `g_strs`/`g_str_hash`（驻留表） | 全流程 | 不载 | 一切名字索引 | 是 由编译器身份字段覆盖（v17 / TODO #2026-09-10-1） |
| 14 | `g_dyn_type_sets` / `g_gen_map` / `g_gen_apply_data` | 前端 | 不载 | 前端 | 是 |
| 15 | `g_hotpatch_*` / `g_rt_builtin_*` | 前端注册 | 不载 | 调用/注册面 | 是 |

侧表面全集 = 15 条（`风险项` 嫌疑 4 条：#1 主嫌 · #2/#4/#5 待实证；`是` 11 条）。T0 的交付 = 逐条把「判定」列做实（含一条脚本：列出全部 `g_*` 侧表 × 建立期 × 是否在 `cir_cache.cr` 段清单内 × 消费者）。

### 1.4 证实 / 证伪实验设计（T1 执行）

| 实验 | 做法 | 判读 |
|---|---|---|
| E1 行号空间对照 | 空缓存/有缓存两态各运行复现源，打印：命中函数的每个 var 的 `irv_type` + `g_type_count` + 该行 `{kind,data,extra}`（经新增隐藏 dump 通道，照 `--dump-tk-terms`/`--dump-nod-items` 先例） | 空缓存/有缓存两态行内容不同（或行号越界/行错位），因此假说成立 |
| E2 归因钳位 | 在 `provenance_verify.cr:66` 的判定前插入只读计数（空缓存/有缓存两态各运行），统计「`ptr_ti >= 0` 通过数 / `TYP_PTR` 通过数 / `extra != 0` 通过数」 | 若有缓存状态在 `TYP_PTR` 或 `extra` 步归零，因此归因定死该判定 |
| E3 反向钳位（证伪） | 关缓存（`COREC_...` / 代码内 `cache_enabled = 0` 的等价物：先删 `.core/cache/cir`）后重运行，因此诊断恒在 | 若「关缓存仍消失」所以假说被证伪（另有他因） |
| E4 覆盖面扫（report-only） | 空缓存/有缓存两态对比运行全语料（72 + 探针 29 + 套件内联源），diff「诊断码集」因此产出有缓存状态不报错地面清单（不只 TU03） | 清单 = 本缺陷的真实影响面（也是 T3 有缓存状态分支的预期基线） |
| E5 侧表面逐个实证 | 对 第 1.3 节的 `风险项` 各条做 E1 式对照（locals 计数 / 重定位表长 / SG 内层结构 / 字符串池） | 逐条给「有缺陷 / 无缺陷」定论 |

E4 是「先量后改」的核心：修法取向未定前，先量出「有缓存状态不报错地面到底有多大」（可能一例，也可能一打，因此见裁决门 3）。

---

## 2. 修法候选（4 条）+ 推荐

> 检查统一为：有缓存状态不得不报错地（宁可 miss 不可不报错地）+ 不引入第二处定义（D20）+ 缓存收益不塌方（命中率可接受）。

| 候选 | 形态 | 影响面 | 风险 | 检查 |
|---|---|---|---|---|
| (a) 命中时重建 | 装载后补运行生成期副作用（重放 `alloc_type` 5 处 / `g_ir_locals` / 重定位 / SG） | 需精确复现分配序（跨函数、含部分命中） | 高：分配序依赖函数内控制流，因此相当于「再运行一遍 ir_gen」＝缓存收益归零 | 空缓存/有缓存两态 `g_type_count` 与行内容逐行同 |
| (b) 命中时检测缺失，因此拒绝条目（fail-closed） | 装载后不变量校验：录 `type_count`/行指纹于条目头，装载期不符，所以视作 miss（无害重建） | 小（快照 +8~16B/条目；VER bump 视形态） | 命中率下降（若校验过粗，因此大面积 miss）；必须先量（E4 + 命中率实测） | 有缓存状态诊断恒在（= 空缓存状态）；命中率下降幅度有实测数字 |
| (c) 快照扩容载入侧表 | 把生成期 `g_types` 行（或必要的 5 类行）写入文件 + 装载期恢复 | 中（格式变更 + `CIR_CACHE_VER` bump + 旧条目整类失效） | 第二处定义（D20）：行内容可由 (kind,data,extra) 重派生，因此与 v18 的「不写入文件重派生」先例冲突，须论证 | `.ccr`/canary 逐字节同 + 空缓存/有缓存 dump 逐行同 |
| (d) 把依赖侧表的安全检查移出缓存未检查范围 | 让安全面不依赖生成期行内容：如把「外部指针」标记在 IR 内表示（辅码/新 opcode 变体）或由前端（每构建必运行）落定，因此安全检查只读 IR | 中（触 `ir_gen`/`.ccr` 布局/消费点） | 改发射/格式面，所以 canary 硬性检查；须先证 IR 面能无损表示 | canary IDENTICAL + 空缓存/有缓存两态诊断同 + `.ccr` 记录值更新基准值论证 |

### 推荐（两步走）

1. 第一步（无条件）：候选 (b) 的最小形态，装载期不变量校验 + 违则 miss（fail-closed 回退处理）。理由：1 与 FC 批「宁可 miss 不可不报错地」同精神；2 改动小、不触格式/发射面；3 立刻消除不报错地（命中率代价待 E4 量化后可再优化）；4 与 v14/v16/v17 的既有 bump 先例同族（先临时修复）。
2. 第二步（按 T1 实证 + 裁决）：(d) 优先于 (a)/(c)。理由：(d) 把「生成期量表」从安全面依赖中移除 = 根因级（隐患不只 TU03：第 1.3 节的 风险项 各条同源）；(a) 的收益/成本比最差（等于放弃缓存）；(c) 与 v18「不写入文件重派生」先例冲突，须维护者裁（待裁：格式面变更）。
注意：待裁标注：候选 (c) 涉快照格式面（`CIR_CACHE_VER` bump + 失效面）；候选 (d) 涉IR/发射面（canary 硬性检查 + `.ccr` 记录值），两者均须维护者批。

---

## 3. 裁决门（开始前置）

| # | 问句 | 影响 | 本计划推荐 | 未取裁时 |
|---|---|---|---|---|
| 裁-W1 | 修法取向：(a) 重建 / (b) 检测即 miss / (c) 快照扩容 / (d) 移出未检查范围？（可组合，如 b+d） | 全批 | b（先行，回退处理）+ d（根因，若 T1 证实 第 1.3 节 风险项 面不止一处）；(c) 须另批（格式面） | 只落 b（fail-closed 回退处理），其余登记 |
| 裁-W2 | 有缓存状态分支是否进 CI？本仓五 CI job 现无有缓存状态面；加入 = CI 时长 ↑（`selfhost-tests` 已 108s）vs 消除未检查范围 | T3 + `run.sh` | 进 `selfhost-tests`（最小面：单档空缓存/有缓存对比）+ 全量有缓存状态扫描留手工检查（照 `tools/baseline/` 的「手工检查 + 入仓配方」先例） | 只入仓 runner（手工运行），CI 不动（登记未检查范围） |
| 裁-W3 | 是否顺带扫其它侧表面（第 1.3 节的 风险项 4 条 + `?` 1 条）？一次可能暴露多例 | T1/T2 范围 | 扫（E4/E5，report-only 零风险），命中面过大，因此转独立批（停条件） | 只修 TU03 面（其余登记） |
| 裁-W4 | 可否用「对该类程序关缓存」作为回退处理（照 `g_optrep_on` 先例 `main.cr:488-490`）？ | 修法面 | 可作为 b 的降级备选（若 (b) 的校验不可实现或命中率崩） | 不实施；仅登记 |

---

## 4. 任务总表

| 任务 | 内容 | 依赖 |
|---|---|---|
| T0 | 前置侦查 + 冻结基线（`rebuild.sh`）+ 起点检查 + 侧表面全集逐条做实（第 1.3 节的 15 条 × {建立期/是否载/消费者/判定}）+ 复现源归档 | — |
| T1 | 根因实证（E1–E5）：空缓存/有缓存 dump 通道 + 归因钳位 + 证伪项 + 有缓存状态不报错地面全语料对比清单（先量后改） | T0 |
| T2 | 修法实现（按裁-W1；b 先行，再 d 视证据）+ 用例（空缓存/有缓存两态行为固定 + 负控「不安全程序不得不报错地通过」） | T1 + 裁-W1 |
| T3 | 检查体系有缓存状态分支：`parity_run.sh`/`probes_run.sh` 加「同源二次构建」检查（空缓存/有缓存 rc + 诊断对比）；CI 面按裁-W2 | T2 |
| T4 | 检查复验（五 CI/枚举/selftest/canary/`.ccr` 四条/自举链/`backend_bootstrap`）+ 文档（TODO #2026-09-15-5 结束 + `cir_cache.cr` 版本族注 + 本计划清单）+ 批终态 | 全部 |

---

## 5. Global Constraints（照 P6/FC 简版）

- jj only；提交路径限定；`nice -n 19`；一构建一编译串行（每段前 `ps` 实查）；cwd = 仓库根；比较任何 `.ccr`/缓存态产物前 `clean-cache`。
- /tmp 空间（本批新增）：`/tmp` 仅剩 ~5G，因此构建/产物控制在 /tmp/fct4 之外小量；遇 ENOSPC，所以停下报告，只清本批自己的临时物并逐条登记（禁删证据目录）。
- ELF canary（硬性检查）：`95084e7b…d475`（28822B）；本批若触发射面（候选 d），因此变即停（须先裁）。
- `.ccr` 四条（约定带命令 + 空缓存/有缓存）：96015/96158/142793/142936（差恒 143B）；本批正是「冷≠暖」缺陷，因此记录值必须分空缓存/有缓存两栏（冷栏 = 上述基准值；暖栏 = T0 实测）。
- 三态纪律：装载期任何「不可证」因此拒绝（= miss），不得不报错地采用。
- 先量后改：T1 的 E4 清单未出、裁决门未取裁，因此不得落修法（report-only 先行）。
- 测试只增不减；用例带「空缓存/有缓存两态」维度；`.cir` 缓存条目不是交付产物（约定豁免，照 FC 批裁-FC-6）。
- 不得回退既有收纳：v12–v18 的版本族处理、`sh_tk_split_load` 重派生、编译器身份字段（TODO #2026-09-10-1）、FC 批检查（默认阻断 + 豁免表 9 条），一律不动。

---

## 6. 起点基线值（出处逐条；本计划未复测）

| # | 项 | 值 | 出处 |
|---|---|---|---|
| 1 | 起点提交 | `1592a1b5`（FC 批 T6 完成） | 协调者给定；本实例未运行 `jj` |
| 2 | 二进制 | `corec 308f06a3…` / `corearch 22e96d03…` | FC T6 报告（重建后与 T3 逐字节同） |
| 3 | 五 CI job / 全枚举 / selftest | 5/5 rc=0 / 60/60 / 415/415 | FC T6 报告 第 1 节 |
| 4 | canary / `.ccr` 四条 | `95084e7b…d475`（28822B）/ 96015·96158·142793·142936（差恒 143B） | FC T6 报告 第 1 节 |
| 5 | 72 档 / 探针 29 | 34×0/38×1 / 17×0/12×1 | FC T6 报告 第 1 节 |
| 6 | 自举链 / `backend_bootstrap` | `24802386a1…` IDENTICAL + N06=0 + 冒烟 42 / rc=0 | FC T6 报告 第 1 节 |
| 7 | 有缓存状态缺陷证据 | 冷 rc=1 无产物 / 暖 rc=0 出 ELF（`build --static` 与 `ccr` 同样的问题；P6 期二进制同值） | FC T2 报告 第 7 节（本批主要检查的 RED 起点） |

---

## 7. 停条件 · 未决项 · 自检记录

### 7.1 停条件
1. E4 命中面过大（有缓存状态不报错地面 > 3 档或涉及 2 + 类码），因此停下上报（修法取向需重裁；可能转「缓存面重设计」独立批）。
2. 修法须触快照格式（候选 c）或发射面（候选 d）而未取裁，因此停。
3. canary / `.ccr` 四条 / `--dump-objects` / `.cir` DOT 任一变化，因此停（发射面泄漏）。
4. 关缓存回退处理也无救（E3 证伪：关缓存仍不报错地），因此停（假说崩塌，须重侦查）。
5. `/tmp` ENOSPC，因此停手报告（禁删证据）。
6. 有缓存状态分支入 CI 后任一 job 由绿变为失败且非本批预期，因此停。

### 7.2 未决项（不猜）
1. 行号空间变化的确切形态（越界 / 错位 / 未初始化），待 T1 的 E1 实测；本计划只给假说与基准。
2. 命中率代价（候选 b 的校验粒度，因此 miss 率），待实测（T1/T2）。
3. 第 1.3 节的 `?`/`风险项` 各条（#2/#3/#4/#5）是否有独立缺陷，待 T1 的 E5。
4. `cir_cache.cr` 版本族注是否需新增 v19 段，按修法形态定（待裁-W1）。
5. 有缓存状态分支的 CI 接入点与时长增量，待裁-W2 + T3 实测。

### 7.3 自检记录
- 本计划未运行任何构建/测试/`jj`；所有「现状值」= 实读源码或既有 FC 报告记录值（出处已标）；需实测的数字（有缓存状态不报错地面档数、命中率、行号空间对照）一律留 T1，未预填。
- 根因段落的诚实性：假说与事实分离（第 1.1 节 九条实读事实 + 一条标注「待 T1 确证」的假说）；未把「疑似机制」写成「已证机制」。
- 与既有裁决的一致性：不触 FC 批检查/豁免表（9 条不动）；候选 (c)/(d) 的越界面已显式标「待裁」；「关缓存」备选有既有先例（`g_optrep_on`）但不擅自实施。
- 本批最大风险（一句）：修法若选「命中时重建」（候选 a）会消耗缓存收益（等于每构建全量 ir_gen），选 (c)/(d) 则触格式/发射面，故推荐 b 先行临时修复 + d 根因（须裁），且先量后改（E4 清单未出不得动码）。

---
