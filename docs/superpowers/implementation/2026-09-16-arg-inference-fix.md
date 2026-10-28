# 实参推断缺失修复实施记录

> 对应计划：[plans/2026-09-16-arg-inference-fix.md](../plans/2026-09-16-arg-inference-fix.md)

## 概述

本记录覆盖 TODO #2026-09-16-31 的实参推断缺失修复，包括 T1 的零构建调查和构建检查，以及 T3 和 T4 的实现与分支检查。结论是：(a) 抽取 `infer_call_args(first_arg)` 并在四处 return 之前调用，(b) 在 checker 侧增加 fail-closed 限制，二者已经实现。分支 A、B、D 全部通过。分支 C 发现 1 处新引入误报，位置是 range-go 的 `go i 0..3 square(i)`。因此按停条件 1 停在 T4 停止点，等待在 (i)、(ii)、(iii) 三个处置中选择。分支 A 中 A1 至 A9 的 139 项已经全部消除。如果退回只做 (b) 或拆阶段，139 仍在。

## 改动

### 裁-ARG-5：`infer_expr` 的 EXPR_CALL 区 return 点枚举

枚举范围是 `checker.cr:2559-2842`。已有 6 处满足条件，这些 return 之前已经有推实参循环。

| 坐标 | 路径 | 推实参点 |
|---|---|---|
| `:2600` 改为 `:2608` 和 `:2610` | 模块限定调用 | `:2600-2606` 是 |
| `:2623` 改为 `:2630` | 方法调用和 dyn 方法 | `:2623-2628` 是 |
| `:2705` 改为 `:2691`、`:2693`、`:2730`、`:2735`、`:2738` | iface 约束泛型方法族 | `:2705-2710` 是 |
| `:2765` 改为 `:2773-2781` | SYM_SO_FN，即 .so 扩展 | `:2765-2770` 是 |
| `:2791` | 泛型直调，再走 `infer_gen_call` | 是。被调内部推，位置是 `checker.cr:1999+`，另见 `:2020` 和 `:2023` |
| `:2833` 改为 `:2840` | 尾分支，条件为 `func_ni < 0` | `:2833-2839` 是 |

缺失的有 4 处。原侦查只说 `:2817` 一处，所以 U4 解除：问题不是「有没有第三处」，而是有四处。

| 坐标 | 路径 | 处置 |
|---|---|---|
| `:2811` | `return TI_NEVER`，被调返回型为 `never` 的早退 | 补，同族 |
| `:2817` | `return sym_type(si)`，主问题位置，被调已经解析为 Core `fn` | 补 |
| `:2824` | `return r64(g_rt_builtin_ret_types, …)`，runtime builtin | 补 |
| `:2831` | `return TI_NEVER`，`EC_N_FUNC`，未定义函数 | 补，裁-ARG-3 已经裁定同阶段覆盖 |

因此修法实现形态是：抽取 `infer_call_args(first_arg)`，在上表四处的 return 之前统一调用，不是只补 `:2817`。

### 实现

`src/compiler/checker.cr` 增加 17 行。

- 新增 `fn infer_call_args(first_arg)`，作为单一依据。原函数尾循环改为调用本函数。
- 在四处「已解析」return 之前调用：`:2811` 是 never 返回型，`:2817` 是主问题位置，`:2824` 是 runtime builtin，`:2831` 是 `EC_N_FUNC`。
- `:2791` 的泛型直调不需要额外调用，因为 `infer_gen_call` 内部已经推。

(b) 的 fail-closed 限制没有按计划放在 `ir_gen`。计划原文写「在 `ir_gen` 处报硬错并拒绝产物」。实读发现既有 fail-closed 检查在 `main.cr:146-175`，位于 `check_all()` 之后、`ir_gen` 之前，所以在 ir_gen 期新增的诊断不经过该检查。要实现原方案，须改 `main.cr` 的构建控制流，风险面大。

因此改在 checker 侧实现，条件相同，使用既有检查覆盖，零新控制流。在 `infer_call_args` 内，对「实参位的 `EXPR_CALL`，callee 为 `EXPR_FIELD`，且 `ast_data <= 0`」报 `EC_N_FUNC` 硬错。若 (a) 已修，本限制恒不触发。它的价值是防止未来同类回归。T4 须记录该事实，不把「无触发」当失败。

### U3 读码结论：(c) 路作废

候选 (c) 是：parser 构造 `EXPR_CALL` 时，若 callee 是 `EXPR_FIELD` 且 obj 是模块符号，立即写 `ast_data`。该方案不可行，前提被证伪。

模块符号由 `checker.cr:1635` 和 `checker.cr:1643` 的 `def_sym(alias_ni, SYM_MODULE, fileid_ni, -1)` 注册。该注册发生在 `check_all()`，入口是 `main.cr:137`。parse 由 `parse_all()` 执行，入口是 `main.cr:133`。因此 parse 期模块符号尚不存在，`find_sym` 必然落空。

所以裁-ARG-4 的「退路评估」结果是：没有退路。本次只有 (a) 加 (b) 一条路，这强化了裁-ARG-2 的同阶段决定。旁证是：这也解释了 I-3 在 bootstrap 侧靠「保留导入元数据并按 alias 解析」修复，绕开了 parse 期无符号的约束。

### U5 决定性发现

实参位的泛型调用在「非原生类型实参」下取到退化实例键，所以修后生成面会变。廉价判别是：同形泛型调用在 LET 位走 binds 路径，因此类型项键正确；在实参位走回落路径，所以按实参 IR 型拼名串。

| 实参类型 | LET 位（binds 路径） | 实参位（回落路径） | 一致？ |
|---|---|---|---|
| 原生 `int`，即 `idf(7)` | `idf[int]` | `idf[int]` | 一致 |
| 非原生 `P`，即结构体 | `idf[P]` | `idf[unit]`，退化 | 不一致 |

含义有两条，都必须在 T2 和 T3 处置。

1. 现状已有缺陷。实参位的泛型调用用退化键 `unit` 实例化。若实例体依赖 T，包括返回类型和参数类型，则行为可能错。本探针的 `idf` 返回常量，所以不可观测，因此没有继续追。
2. 修后本次性质变化。实参被推断，所以该调用点获得 `g_gen_binds`，所以 ir_gen 的泛型重定向从回落路径切到 binds 路径，所以实例名从 `idf[unit]` 改为 `idf[P]`，所以 `.cir` 和 `.ccr` 会变。这是修好，不是回归。

这正是裁-ARG「加码 1」的用武之处。`.ccr` 会变，所以不必先归因，先停下报给 lead。本次性质从「接线」变为「生成面变更」，检查标准须重新裁定。T2 须就本条取裁，见裁-ARG-8。

### T4 停止点：range-go 新引入误报

(a) 加 (b) 已经实现，分支 A、B、D 全部通过。分支 C 发现 1 处新引入误报，所以按第 7 节停条件 1 停下报给 lead，没有自行放宽。

唯一形态是 `go <iter> <a>..<b> <body>`，也就是 range-go。全仓有 3 处用法：`tests/probes/p_spawn.cr:3`、`tests/test_go_range.cr:10`、`tests/selfhost/test_interp_parity.py:164` 的 inline 源。74 档里的 `go_*` 语料使用单发形 `go square(21)`，不受影响，rc 逐档全同。

机理如下。`go i 0..3 square(i)` 的迭代变量 `i` 在 checker 里从未被绑定。

- `parser.cr:617`：range-go 只把迭代变量名写进 `EXPR_GO` 的 `c` 槽，也就是 `iter_var_ni`，不产生任何绑定。
- `checker.cr:2981-3000` 的 `EXPR_GO` 分支：直接执行 `body_ti := infer_expr(body)`，位置是 `:2985`，不绑定迭代变量。

修前不可见的原因是：`square(i)` 是已解析直调的实参，所以该实参从不被推断，所以 `i` 从未被检查，所以没有诊断，rc=0。修后暴露的原因是：实参被推断，所以 `i` 被检查，因此发现未绑定，所以报 N01。

按裁-ARG-1 规则①的反面，这是误报。规则①要求「命中三族且该名或界确实不存在」才判「本来就该报」。此处码是 `N01`，属于三族内，符合前半条。但 `i` 在语言层面确实存在，因为 `go i a..b body` 的语义就是绑定 `i`，ir_gen 侧也按 `EXPR_GO.c` 使用该名。因此不满足「确实不存在」。所以判定为新引入误报，按第 7 节停条件 1 停下。该条件的表述是「任一档出现三族之外的新诊断」，其精神是一切不能判「本来就该报」的新诊断。

处置有三个选项，等待裁决。

| 选项 | 内容 | 代价和风险 |
|---|---|---|
| (i) | 同阶段补 `go` 迭代变量绑定，建议采用 | 在 `checker.cr` 的 `EXPR_GO` 分支 `:2985` 的 `infer_expr(body)` 之前，把 `iter_var_ni` 绑成一个 int 局部。`ast_c(node)` 大于 0 时为 range-go。作用域限于 body。改动面是 checker 一处，增加数行。风险是须与 ir_gen 侧的 `EXPR_GO.c` 用法一致，使用同一名字，且须确认作用域正确恢复。这是语言语义本就该有的绑定，属于修正 checker 的缺失，不是绕过。 |
| (ii) | 豁免该形态 | 把 range-go 的 `i` 加入豁免或允许清单。不推荐，因为等于把误报合法化，违反本仓「不掩盖」纪律。 |
| (iii) | 停并重裁阶段 | 判定 (i) 超范围，因此退回只做 (b)，也就是只处理不报错问题，或者拆阶段。代价是 139 仍在。 |

如果裁 (i)，T4 继续做：补绑定，然后重运行三条检查、29 个探针和 `interp_parity`。阶段报告须写明「本条是修实参推断顺带暴露的 checker `go` 绑定缺失」。

该停止点有方法学价值。若按「新增诊断一律算修好」的约定，`p_spawn` 和 `interp_parity` 的两处红会被误记为「修好」。分支 C 的「逐条归因，不许把新增诊断当修好」纪律正是抓到它的机制。

## 验收结果

### 放大面基线

放大面是 74 档 check 码集，直接复用 apx 阶段 leg-① 记录。二进制内容是 develop `0808a8ca`，apx 已经 squash 合入。

- 返回码分布是 35 档 rc=0、39 档 rc=1。
- 码集分布按各档去重后计数。39 档有码的档中，含 `N06` 的档最多：7 档纯 `N06`，6 档 `N01+N06+TA01`，5 档 `N01+N06+TA01+TB01`，其余略。`N01` 独立 2 档，`TF01` 8 档，`N11` 5 档，`B04` 2 档。
- 关键含义是：`N06` 和 `N01` 在存量语料里本就常见，多为负例档。因此放大只可能影响当前 `rc=0` 的 35 档。已经变红的档不会因为新增诊断而「更红」到改变 rc。所以「超过 5 档变为失败且其中任一归因不清」这一超预期阈值（裁-ARG-1）在上界 35 档的语境下是合理偏紧的。
- 分支 C 判读约定是：看每档码集是否新增，不是「有 N06 就算新」。已经含 N06 的档须比对码个数和组合。
- 证据是 `/tmp/apx-t1/pc2/logs/*.{rc,log}` 的 74 档，以及 `/tmp/apx-t1/pr_cur/` 的 29 档行为探针。

### RED 语料确认

`tests/selfhost/test_arg_inference_gap.py` 共 19 例，其中 10 例 RED（分支 A 9 例，分支 B 1 例），9 例绿。与侦查一致。`--report` 模式可以重新运行。

### T1 构建步骤和起点检查

- 起点检查在 develop 树重建后执行。构建成功，得到三产物。快速验证返回 42。`canary_check.sh` 为 5/5 PASS：`95084e7b…d475` 28822B，`pa` 96015，`pa_static` 96158，`gt` 142765，`gt_static` 142908。
- 固定基线重建使用 `tools/baseline/rebuild.sh /tmp/apx-t1/base93`。三个 sha 与允许清单逐条相同，快速验证 42。临时 workspace 已经 forget。
- 构建占用检查在执行前运行，`pgrep` 为空，说明没有其他阶段构建。
- U5 决定性发现见改动一节。

### 分支 A、B、D

| 检查 | 结果 |
|---|---|
| A，明确面，9 例 | 19 例套件由 10 RED 变为 0 RED。A1 至 A9 的 139 全消，均得到精确值。 |
| B，不报错的地面，正据 | `g(nosuchfn(1))` 由「`check` rc=0 零诊断」变为「`check` rc=1 加 `error[N06]`」。 |
| D，裁-ARG-8 H4，正据 | 实参位泛型由 `idf[unit]` 退化改为 `idf[P]` 精确，与 LET 位一致。TODO #2026-09-16-35 的既有缺陷由本次附带修复。 |
| 对照 9 例 | 全部保持绿，即 C1 至 C9。其中包括 C7 和 C9 的 oracle 对照：外层模块调用和方法调用当前即报 N06。 |

自纠 2 处。探针 A5 和 A6 的期望值在本次写错。A5 实得 7，等于 `p.v`，正确。A6 实得 3，即字符串相等，所以 `str_neq_3` 返回 0 正确。因此统一成功码为 0。

### 分支 C-①：新增诊断面

- 74 档 rc 逐档全同，为 35 个 0、39 个 1，与基线一致。没有档改变红。
- 码集变化 11 档，全部是 t2、t3、t4 的「单文件独立 check」档，也就是编译器、后端和标准库源码。文件是 `arch/x86_64/frame`、`arch/x86_64/instr`、`arch/x86_64/regalloc`、`arch/x86_64/tag2l`、`format/elf/elf`、`format/elf/ld`、`format/elf/resolve`、`lattice/ent_kernel`、`os/linux/callseq`、`os/linux/entry`、`stdlib/hotpatch`。
- 真新增 849 条，按「码加文本」计，排除位置变化。分布是 N01 767 条、N06 81 条、TB01 1 条。
- 逐条归因：N01 和 N06 全部是「独立文件里本就不存在的全局名或函数」。例子包括 `frame.cr` 单检时的 `g_x86_rip_patch_count`、`instr.cr` 的 `g_x86_alloc_patch_count`、`elf.cr` 的 `g_x86_func_offsets`。这些档本来就是大量 N01 和 N06 的单文件检查，基线即 39 档 rc=1 的一员。实参内的未定义名此前不报错，现在被报出，所以判定为本来就该报。
- TB01 1 条是同因级联，证据是：`ent_kernel.cr:195` 的 `_dyncpy(g_ir_entries, g_entry_cap * ESZ_ENTRY, nb)`，该算术在实参位，操作数 `ESZ_ENTRY` 本身就是同一个 N01 未定义名。因此类型未知，所以报 TB01。该档基线已有 2 条 TB01，属于同类。因此判定为本来就该报，属于同因级联。这落在第 1 节检查的「三族外但可证本来就坏」分支，证据已经给出。
- 结果是零「新引入误报」，零「归因不清」。裁-ARG-1 的三条规则全部满足。

### 方法学修正

首轮对比使用「码、行号、列、文本」做集合差，报出 889 条，其中 N11 38 条，文本是「Duplicate function definition」，全部在 `ccr_io.cr` 档。这些实际是假新增。该档的 t2 和 t3 语料是多文件组合单元，import 解析后行空间共享。本次在 `checker.cr` 新增 17 行，所以该单元中 `checker.cr` 之后的所有行号整体加 17。实测从 `23827` 变为 `23844`。因此集合差把「位移」误判为「新增」。

正确的身份是「码加诊断文本」，本记录采用这个约定。行号只用于定位，不用于身份。修正后真新增为 849 条。

### 零影响

- ELF canary `95084e7b…d475`，28822B，IDENTICAL。H1 满足。
- `.ccr` 四条全部 IDENTICAL：`pa` 96015，`pa_static` 96158，`gt` 142765，`gt_static` 142908。因此 C-② 面为空。`ptr_arith` 和 `generics_test` 两个语料没有触到实参位泛型，所以无需更新基准值。H2 的四要素本条无需执行，但保留为「若将来变」的纪律。
- `check src/compiler` 返回 rc=0，0 error。最大语料零新诊断。
- 接入点三件套完成：`run.sh` 已接入，允许清单条目已删，头注转正。`test_ci_hook_coverage.py` PASS，scope=67，hooked=40，unhooked=27。

### 停止点检查

| 检查 | 基线 | 修后 |
|---|---|---|
| `tests/probes/p_spawn.cr`，29 个行为探针之一，`tests/probes/README.md:42` 期望 rc=0 | rc=0 | rc=1，新增 `error[N01]: Undefined name 'i'`，位置 `p_spawn.cr:3` |
| `tests/selfhost/test_interp_parity.py`，已经接入 CI 的套件 | 23/23 | 22/23，4 个子项 FAIL：`range_go_spawn_callee` 的 opcodes、interp-callee、interp-main、elf-callee |

截至停止点，其余检查全部通过：分支 A 的 19 例套件 0 RED；分支 B 的 `g1` 改为 N06 正据；分支 D 的实参位 `idf[P]` 正据；74 档 rc 逐档全同，含 (b) 后复验；码集变化 11 档逐条归因全部为「本来就该报」，即 N01 767 条、N06 81 条、TB01 1 条同因级联；canary IDENTICAL，`.ccr` 四条全 IDENTICAL；`check src/compiler` rc=0，0 error；`selftest-types` 415/415；接入点覆盖 PASS；(b) 无触发面。

## 遗留问题

1. T4 停止点等待裁决，有三个选项。(i) 同阶段补 `go` 迭代变量绑定，建议采用。(ii) 豁免该形态。(iii) 停并重裁阶段。如果选 (iii)，139 仍在。
2. range-go 迭代变量绑定缺失。`parser.cr:617` 只把变量名写进 `EXPR_GO` 的 `c` 槽，`checker.cr:2981-3000` 不绑定迭代变量。这是新误报的根因。
3. 实参位泛型实例键退化是既有缺陷，对应 TODO #2026-09-16-35。实例体依赖 T 时行为可能错。本探针的 `idf` 返回常量，所以不可观测。分支 D 的修复已经顺带覆盖该缺陷。
4. (b) 的 fail-closed 限制因为 (a) 已修而恒不触发。它的价值是防止未来同类回归。T4 须记录该事实，不把「无触发」当失败。
5. 修后 `.ccr` 预期会变，实例名从 `idf[unit]` 改为 `idf[P]`。本次性质从「接线」变为「生成面变更」，检查标准须在裁-ARG-8 重新裁定。
6. `tests/probes/p_spawn.cr` 和 `tests/selfhost/test_interp_parity.py` 在停止点仍然是红的，尚未修复。

## 不包含

本次不包含 range-go 迭代变量绑定修复，该事项等待裁决。

本次不包含 (c) 的 parser 期模块符号路径，该方案的前提已经被证伪。

本次不包含在 `ir_gen` 处报硬错并拒绝产物。fail-closed 限制改在 checker 侧实现。

如果选 (iii)，本次不包含 139 个失败的修复。

本次不包含对实参位泛型实例键退化的独立修复。该缺陷由分支 D 的修复顺带覆盖。

本次不包含 `p_spawn` 和 `interp_parity` 两处红的修复。这两处红是停止点的证据。
