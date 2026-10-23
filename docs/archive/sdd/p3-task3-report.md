# R2 P3 任务 3 报告：穷尽性的真判定（match 补集空性和具体变体反例）

状态：完成，但有保留项（DONE_WITH_CONCERNS）。判据全部通过，另有 6 项登记：

① witness 的 `ty_equiv` 实测为 -1，属于未覆盖面，不是任务 0 报告记录的“等于 0”。

② `EXPR_ENUMPAT` 的名字槽是 `ast_a` 契约，本批实测时遇到过问题，见第 6 节第 2 项。

③ 空枚举域属于空洞穷尽，实测为 1，与计划原文“等于 0”有偏差。

④ 不可判面有四条：非枚举域、不可映射模式、异枚举变体、引用 scrutinee。

⑤ TM04 落在软面，评估后不升级为硬门。

⑥ `T?` 与用户自声明 `enum Option` 的交互。

以上都是发现或裁量登记，不是缺陷，见第 6 节。

提交：`e9818d62`（change `srmprsyvmsol`，父提交 `qvpuwwvz`，即 `ef61f002`，P3 任务 1 的末提交）。路径限定 6 个文件：`src/compiler/ty_shadow.cr`、`checker.cr`、`main.cr`、`type_selftest.cr`、`src/ci/run.sh`、新增的 `tests/selfhost/test_match_exhaust.py`。共 513 insertions、1 deletion。

计划：`docs/superpowers/plans/2026-09-11-r2-p3-capabilities.md` 的任务 3（P3a）。未越界到任务 4、5 的面，没有联合、可选和泛型约束。

起点：`ef61f002`，工作副本干净。基线二进制由起点树重建，为 `4b099c50…`，留档在 `/tmp/p3t3_base_bin/`，与任务 1 报告记录的交付 sha 同值。

范围口径：穷尽性等于补集空性，即 `ty_exhaustive(domain, patterns)`，再加具体变体反例。只对枚举 scrutinee 判穷尽，`T?` 和联合面留给任务 4。

## 1. 交付物和落点（file:line，实测）

| 交付物 | 落点 |
|---|---|
| 消费点头注，说明三个缺口：域守卫、模式守卫、反例命名；以及模式项约定 | `ty_shadow.cr:784-801` |
| `sh_match_pat_kind`：1 表示 ⊤（通配或绑定），2 表示变体模式，0 表示不可映射 | `ty_shadow.cr:802` |
| `sh_match_pat_variant`：裸名和 `Enum.Variant` 限定名都解析为本枚举的变体下标，-1 表示不可映射 | `ty_shadow.cr:817` |
| `sh_match_variant_term`：变体下标转成变体项，与域项使用同一构造 | `ty_shadow.cr:849` |
| `sh_match_bit`：计算 2^vi，使用循环形态，因为没有移位运算符，与 `iface_bit` 相同 | `ty_shadow.cr:858` |
| `sh_match_first_missing`：反例命名，返回首个未覆盖的变体下标 | `ty_shadow.cr:868` |
| `sh_match_exhaustive`：三态 1、0、-1；包含域守卫、不可映射守卫和引擎补集空性 | `ty_shadow.cr:881` |
| checker 的 `EXPR_MATCH` 模式采集：项链、覆盖位、不可映射标记、冗余臂标记，与臂体推断同一趟 | `checker.cr:2527-2565` |
| checker 的 `EXPR_MATCH` 判定和诊断：预算前后隔离，TM03 包含缺失变体名，TM04 为软面 | `checker.cr:2594-2611` |
| `EC_TM_EXHAUST`(9003) 加入 `run_frontend` 硬名单，先 report-only 后开门 | `main.cr:160` |
| 自测用例段 14 例（t3.*，249 变为 263） | `type_selftest.cr:1349-1470` |
| 行为覆盖集 16 例 | `tests/selfhost/test_match_exhaust.py`（228 行） |
| CI 挂钩（selfhost-tests） | `src/ci/run.sh:85` |

接口核对，与计划步骤 1、2 对照：模式项收集为，枚举模式经 `sh_match_variant_term` 转 `sh_variant_term`，绑定 ident 和通配转 `tt_top()`，scrutinee 经 `sh_enum_domain_term` 处理，后者是任务 0 的产物；判据走 `ty_exhaustive`；反例使用具体变体名。实现路径见第 3.3 节和第 6 节第 1 项。

## 2. 判据（命令和结果）

| # | 判据 | 命令 | 结果 |
|---|---|---|---|
| 1 | 自举构建 | `nice -n 19 python3 build_selfhost_native.py` | rc=0，`=== BUILD SUCCESS ===`；三个守卫都输出 `build log clean (error[ = 0, undefined = 0)` |
| 2 | 自测用例表 | `nice -n 19 ./build/corec selftest-types` | 263/263。基线 249/249，增加 14 例，零 FAIL，rc=0 |
| 3 | 接口查表回归 | `nice -n 19 python3 tests/selfhost/test_iface_ops.py` | 76/76 passed |
| 4 | ELF canary 逐字节 | `clean-cache`，然后 `build tests/suite/ptr_arith.cr --static -o /tmp/pa_p3t3_final`，再 sha256 | `95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475`，IDENTICAL |
| 5 | 收紧清单和全语料 report-only | 见第 3 节的 22 个探针旧新对照，第 3.2 节的 72 档 check 日志对拍 | 7 条“旧接受、新拒绝或新诊断”；语料零命中 |
| 6 | 影子对拍门 | 72 档 `--type-shadow --type-shadow-dump`，旧新二进制各一遍，逐档 clean-cache | 见第 4 节 |
| 7 | 回归套件 | `test_compile`、`test_type_engine`、`test_iface_ops`、`test_purity`、`test_ccr_v7`、`test_impl`、`test_interp_float`、`test_interp_parity`（23/23）、`test_native_memory`、`test_lsp`（10/10） | 全部通过 |
| 8 | `.ccr`（计划预期为不变） | `clean-cache`，然后 `ccr tests/suite/ptr_arith.cr` | `ecd7a9dfd557810651d9f4a31bf5775556b5c15518fb0a9dbacb56af83dcd29d`，IDENTICAL |
| 9 | CI 的 selfhost-tests 全套 | `nice -n 19 env CI_JOB_NAME=selfhost-tests bash src/ci/run.sh` | rc=0，0 FAIL，包含新档 16/16；重建后三个二进制 sha 不变，构建确定性成立 |
| 10 | 自举链 | `CI_JOB_NAME=full-bootstrap src/ci/run.sh` | rc=0；`corec2 == corec3`，`cmp` IDENTICAL（2,242,446 B）；N06 计数为 0；冒烟 `run 'fn main()->int{return 42;}'` 得到 42，corec 和 corec2 双通道一致 |
| 11 | 突变控制 | 见第 5 节 | M1、M2、M3 得到 257/263，失败用例按突变互不重叠，行为集为 12/15；复位后 263/263，三个 sha 逐字节复原 |
| 12 | 其余 CI 档 | `suite`（rc=0，ALL PASS）、`bootstrap-tests`（3/3）、`check`（rc=1，属于既有失败划界，见第 7 节第③项） | 见左 |

二进制（冻结树）：corec `54fd5c94…`，corearch `2b835710…`，与基线同值，因为 corearch 清单不包含 checker 和 ty_shadow；corelsp `9a66c613…`。

## 3. 行为探针（任务 3 主判据）和收紧清单

探针目录为 `/tmp/r2p3t3_probe/`，共 22 例，主集 19 例，追加 3 例。runner 为 `run.sh`，逐档 clean-cache，cwd 为仓库根，记录 build 和 run。旧二进制为 `/tmp/p3t3_base_bin/corec`，新二进制为本批 `build/corec 54fd5c94…`。report-only 态和开门态各跑一遍留档，分别为 `RO2_summary.txt` 和 `NEW_summary.txt`。

### 3.1 收紧清单（旧接受、新拒绝，逐条）

| # | 用例 | 旧 | 新 | 新措辞 | 说明 |
|---|---|---|---|---|---|
| 1 | p1 缺臂 `match c { Red => 1, Green => 2, }`，c 为 Green | check rc=0、build rc=0 且有产物 | rc=1，无产物 | `error[TM03]: Non-exhaustive match: missing variant 'Blue'` | 计划步骤 3 明确要求翻转的面 |
| 2 | p1b 缺臂，且运行值就是缺失变体，c 为 Blue，返回 v+100 | rc=0 且有产物，运行 rc=100，未匹配时不报错地返回 0 | rc=1，无产物 | 同上 | 不报错地错误编译的直接证据，修复前零信号 |
| 3 | p4 payload 变体缺臂，缺 `Third` | rc=0 且有产物，运行 rc=0，不报错地返回 0 | rc=1，无产物 | `missing variant 'Third'` | payload 变体同样处理，按变体身份判断 |
| 4 | p8b 无臂 `match c { }` | build rc=0 且有产物，只有 TF01 软诊断，运行 rc=0 | rc=1，无产物 | `missing variant 'One'` | 未覆盖面等于全域 |
| 5 | p17 枚举形参位缺臂，scrutinee 来自形参 ti | rc=0 且有产物 | rc=1，无产物 | `missing variant 'Blue'` | 非构造器来源同样处理 |
| 6 | p20b 用户自声明 `enum Option[T]` 加 `int?` 匹配，缺 `None` 臂 | rc=0 | rc=1 | `missing variant 'None'` | 声明枚举进入域判定，与任务 4 的交互见第 6 节第 6 项 |
| 7 | p11 重复臂，`Red` 出现两次 | rc=0，无诊断 | rc=0（软面），加 `error[TM04]: Redundant match arm` | 6:9，指向该臂模式 | 新增诊断面，不是 rc 收紧。评估后不升级为硬门，见第 3.3 节第 4 项 |

收紧条数口径：rc 面收紧 6 条，即 #1 到 #6；诊断面新增 1 条，即 #7，为软面。全语料，包括自源、套件和 fixtures，零命中，因此没有“停下上报”的情形。

### 3.2 登记面和非收紧面（旧新同值，语义登记）

| 用例 | 语义 | 旧到新 | 登记口径 |
|---|---|---|---|
| p2、p3、p6、p8、p10、p12、p13 | 全覆盖、通配、限定名、单变体、泛型枚举、绑定臂、嵌套枚举 | rc=0 到 rc=0，运行值相同：2、7、3、4、5、9、2 | 正例，判定不误伤 |
| p5（int scrutinee 加字面量臂）、p15（struct scrutinee） | 非枚举域 | rc=0 到 rc=0，零诊断 | 域限定，非枚举域不判，不假装穷尽，也不假装不穷尽 |
| p7（枚举匹配混入 `5 =>` 臂）、p16（异枚举 `Other.X` 臂） | 不可映射模式 | rc=0 到 rc=0，零诊断 | 不可映射时返回 -1，不判。不得当作 ∅ 凭空判不穷尽，也不得当作 ⊤ 凭空判穷尽 |
| p18（`&Color` scrutinee 缺臂） | 引用 scrutinee | rc=0 到 rc=0 | `find_enum_row_of(TYP_REF)` 为 -1，不判，登记为缺口 |
| p19（`int?` 匹配，没有声明 `Option`） | `T?` 面 | rc=0 到 rc=0 | 没有声明枚举，域不可展开，不判。属于任务 4 的面，本批不提前处理 |
| p14（空枚举 `enum E { }` 加零臂 match） | 空域 | rc=0 到 rc=0 | 空洞穷尽，实测判据为 1，见第 6 节第 3 项；源码面空枚举可写，parser 未报 P009，实测 |
| p9（空枚举声明本体） | 无 | rc=0 到 rc=0 | parser 接受 `enum E { }`。`EC_P_ENUM_EMPTY` 有定义但未 raise，这是既有事实，登记 |

### 3.3 实现裁决（计划未定或与计划文有偏差的地方，逐条）

1. 引擎不在本任务的文件面内，因此三个缺口全部在消费点，这是协调者的裁决：域守卫、模式守卫、反例命名。三态纪律要求一切“未知”都返回 -1，零诊断、零动作，不得当作 0 或 1。
2. 反例不取 witness 项，改用覆盖位命名，这是任务 0 第 5 节第②项的处置。缺失 B 时，引擎 witness 为 `(A∩¬A)∪(B∩¬A)`。本批实测 `ty_equiv(witness, B)` 为 -1，属于未覆盖面；`ty_sub(witness,B)` 为 1，反方向为 -1，可空为 1。因此 witness 项不能用作显示名。覆盖位由 checker 采集，使用同源变体项构造，可以给出具体变体名，而且与引擎判据是两条独立路径。用 `t3.counterexample_named_variant` 固定两路的一致性。
3. 限定名 `Enum.Variant` 的解析取最后一个点之后的部分，口径与 `ir_gen.get_variant_name_idx` 相同，前缀必须是本枚举名。不调用 `str_intern`，因为 `.ccr` 的 STR 段是 `g_strs` 全量，这是 P2b 附录 A.3-② 的硬判据约束。字符串比较逐项走 `str_eq`。
4. TM04 落在软面，评估结论是不升级为硬门。冗余判据是覆盖面无贡献，包括重复变体和通配之后再次出现，证明面清晰。但理由有三：计划只对 9003 明确要求开门，9004 只要求同期评估；Rust 对 unreachable pattern 也使用警告口径；rc 面收紧没有对应授权。因此只发出诊断，rc 不动，rc=0 且产物照常生成，`test_match_exhaust.py::redundant_arm_soft` 固定该行为。
5. 预算隔离：判定前后各执行 `ty_budget_reset(200000)`，参照 `type_equal_engine` 的窗口纪律。展开层的步进计入该窗口。
6. 不可映射等于整场不判，而不是逐臂忽略。任一臂不可映射，该 match 就零诊断。保守方向是少报，避免误报，登记的代价是混臂 match 会漏判。

## 4. 影子对拍门复跑和站点覆盖（与差异数一同报告）

72 档，包括 t1 的 `tests/suite` 32 档、t2 自源 2 档、t3 后端和 kernel 15 档、t4 stdlib 19 档、t5 examples 4 档。逐档 clean-cache，旧新二进制各一遍。

- `diff -r` 比较 check 面日志：只有 2 处行号位移。`t2_src_compiler_main.cr.log` 中 `lits_copy` 和 `ty_memo_slot_no_grow` 两条既有 TF01 误报的诊断行号从 9528/9751 变为 9534/9757，原因是本批新增源码行使自源行号位移。诊断集合、条数和 rc 全部相同，`summary diff` 为空。shadow 日志和 dump 的 `diff -r` 为空，因此旧二进制配新源等于新二进制配新源，同源双编译器对拍逐字节相同。
- 聚合，新二进制，使用 `/tmp/p3t0_agg.py`：`decisions=29442 agree=29442 old_stricter=0 old_looser=0 unknown=0 unknown_bridge=0 unknown_engine=0 unknown_engine_uncovered=0 unknown_engine_budget=0 replace_bridge=0 replace_unknown=0`。`agree == decisions` 成立，`sum(sites) == decisions` 成立，旧新两份聚合逐值相同。
- 站点覆盖直方图：`assign-node=22282`、`fn-body-ret=5230`、`if-branch=1896`、`struct-field-type=28`、`array-elem-type=4`、`generic-apply-base=2`。站点 1（hotpatch-ret）、2（generic-arg）、4（unify-fallback）、6（assign-binary）在语料中零命中，站点 3（generic-apply-base）仅 2 次，与 P1、P2a、P2b、任务 0、任务 1 口径相同。
- 效力范围声明，确认计划前提：`src/compiler/**` 和 `tests/suite/**` 实测零 `match` 表达式、零 `enum` 声明。全仓 grep 逐条核过，命中都是注释或字符串字面量。因此本能力面在语料中零命中，零差异不是本任务的证据。正确性由第 3 节的 22 个探针、第 2 节判据 2 的 14 例、新档 16 例和第 5 节突变控制承担。
- 语料自指：本批新增源码进入语料，判定数从 29,267（任务 1）变为 29,442，增加 175，等于新增行自身的判定。

## 5. 突变控制（用例有效性；复位后二进制逐字节复原）

| # | 突变（临时，已复位） | 预期失败 | 实测 |
|---|---|---|---|
| M1 单独 | `sh_match_exhaustive` 的不可映射守卫失效，把 `unmappable != 0` 改为 `> 99` | 不可映射守卫例 | 262/263，恰好 1 例 `t3.unmappable_guard_unknown` 失败 |
| M1+M2 | 追加 `sh_match_pat_variant` 的限定名前缀守卫失效 | 名字解析例 | 261/263，增量恰好 1 例，即 `t3.pat_name_resolution`，异枚举前缀被当成本枚举 |
| M1+M2+M3 | 追加 `sh_match_first_missing` 恒返回 -1，反例命名失效 | 反例命名组 | 257/263，增量恰好 4 例：`t3.counterexample_named_variant`、`t3.no_arms_not_exhaustive`、`t3.payload_mixed_cover`、`t3.dup_arm_complement`。行为集为 12/15，`missing_arm_rejected` 和 `no_arms_rejected` 缺少具体变体名，`unmappable_pattern_not_judged` 在不判面误报。后者来自 M1，前两者来自 M3 |
| 无 | 复位，三处还原并重建 | 263/263 且 sha 复原 | 263/263，rc=0；`build/corec 54fd5c94…`、`corearch 2b835710…`、`corelsp 9a66c613…` 三个 sha 与突变前逐字节相同，构建确定性和复位完整性成立；`jj status` 显示工作副本相对 `e9818d62` 零差异 |

专一性由增量法实测：M1 为 1 例，单独实测；M2 为 1 例，增量实测；M3 为 4 例，并集 6 例减去已测 2 例，逐例点名来自 M1+M2+M3 的 FAIL 列表。三面的失败用例互不重叠，行为集提供独立交叉证据：M1 使不判面的误报被检出，M3 使反例名缺失被检出。

## 6. 发现和登记（影响后续任务）

### ① witness 三态实测为 -1（修正任务 0 报告的一处措辞）

任务 0 第 5 节第②项写“按 `ty_equiv` 与‘该变体’不等”，读者会理解成 `== 0`。本批实测，使用 3 变体枚举、缺 1 个：`ty_sub(w, 缺失变体) = 1`，`ty_sub(缺失变体, w) = -1`，因为空析取支让反向结构比较落空；`ty_equiv = -1`；`ty_inhabited = 1`。因此“不等”的准确形态是 -1，属于未覆盖面，正是三态纪律禁止当作 0 用的那一类。反例命名因此必须走覆盖位，本批已实现。`t3.counterexample_named_variant` 把四个值逐一固定，防止后续“顺手净化 `tt_norm`”的改动悄悄改变该面。

### ② `EXPR_ENUMPAT` 的名字槽是 `ast_a`（本批实测时遇到问题，供任务 4、6 和后续模式面消费者参考）

首版实现按 `ast_int_val` 读取模式名，遵循 `EXPR_IDENT` 的约定。但 parser 把枚举模式名写在 slot a，即 `alloc_node(EXPR_ENUMPAT, ni, …)`，`ir_gen` 的消费点也使用 `ast_a`。后果是全部变体模式都被判为不可映射，判定恒为 -1，形成零诊断的虚假通过。report-only 态的 19 个探针中，p1、p4、p11、p17 全都没有诊断，而 selftest 全部通过，因为 selftest 夹具和 helper 同错自洽，这正是“同源同错”陷阱的实例。行为探针使用真实 parser 输入，是唯一抓到这个缺陷的手段，修复后两者对齐。因此登记：任何新消费 `EXPR_ENUMPAT` 的代码必须使用 `ast_a`。selftest 夹具的人造节点已同步，位置在 `type_selftest.cr` 内构造 `EXPR_ENUMPAT` 的地方。

### ③ 空枚举域是空洞穷尽（计划原文“等于 0”的偏差登记）

计划步骤 2 写“空枚举域 = 0，无值可覆盖，登记语义”。在补集语义下事实相反：域为 ⊥，反例集恒空，因此 `sh_match_exhaustive` 为 1，即空洞穷尽。本批用 `t3.empty_domain_vacuous` 固定该行为，并断言 `count = 0` 时反例命名为 -1。不报错是正确行为，因为空类型没有值可漏，报错等于假装不穷尽。另注：源码面 `enum E { }` 可写，实测 p9 rc=0，`EC_P_ENUM_EMPTY`(P009) 有定义但未见 raise，因此该边界可以经源码到达。p14 中空枚举加零臂 match 得到 rc=0，登记。

### ④ 不可判面四条（登记，均 rc=0）

(i) 非枚举域，包括 int、string、bool、原生类型和 struct，受域限定。(ii) 不可映射模式，包括字面量、struct 模式、未声明名和异枚举限定名，整场不判，见第 3.3 节第 6 项。(iii) 引用 scrutinee，例如 `&Enum`，`find_enum_row_of(TYP_REF)` 为 -1。(iv) `T?` 没有声明枚举，属于任务 4 的面。后续如果要把“不可判”收窄为“判”，需要先扩域判定面，由任务 4、6 或专门批次处理，并各自先走 report-only。

### ⑤ TM04 软面（评估结论见第 3.3 节第 4 项）

诊断面新增一条。如果后续批次要升级为硬门，必须重跑全语料 report-only。本批已零命中，成本低。

### ⑥ `T?` 与用户自声明 `enum Option` 的交互（任务 4 交接项）

用户如果自声明 `enum Option[T] { N, S(T) }`，`T?` 的 match 会进入本批判定。p20 全臂时零诊断，p20b 缺臂时产生 TM03 `missing variant 'None'`。任务 4 把 `T?` 改为 `T ∪ null` 联合项后，本路径 `find_enum_row_of(scrutinee)` 到 `sh_enum_domain_term` 对联合 ti 的走向须由任务 4 裁决。本批未触碰，`T?` 的桥接和注册表行语义零改动。

## 7. 过程说明

- 失败态没有单独构建，口径与任务 0、1 相同。`sh_match_*` 五个符号此前在全仓零定义，构建期的 `Undefined name` 硬失败就是失败态。用例有效性由第 5 节突变控制承担。
- report-only 和开门两态都留档：`/tmp/r2p3t3_probe/{OLD,RO2,NEW}_summary.txt`，其中 RO2 表示诊断已 emit、rc 未收紧，NEW 表示开门。开门依据是第 3.2 节的全语料日志逐字节相同，清单为空。先在 72 档 report-only 跑了一遍，再在 `main.cr:160` 追加一行。
- `check` CI 档 rc=1 属于既有失败划界：两条 TF01（`lits_copy` 和 `ty_memo_slot_no_grow`）是 ty_shadow.cr 记载的 loop 落空既有误报，任务 1 提交信息已划界。基线二进制配新源同样出现，第 4 节 check 面 diff 只有行号位移，因此不是本批引入。自源零 TM03、TM04，bootstrap 日志和全部 sweep 都逐条 grep 过，没有“停下上报”情形。
- 工作量口径：本批共 9 次自举构建。实现和调试 4 次，依次为首版 report-only、调试打印、槽位修复、开门；突变控制 5 次，依次为三突变并集、复位、M1 单独、M1+M2、终态复位。另有 CI 两次自带重建和自举链一次构建，sha 全程不变。第 2 节的全部判据，除突变态外，都适用于同一冻结二进制 `54fd5c94…`，终态复位后 sha 逐字节复原。全程使用 `nice -n 19`，串行构建。
- 语料运行器和探针是非仓库文件，复用 `/tmp/p3t0_run.sh`，留档在 `/tmp/r2p3t3_probe/`。报告与 `docs/archive/sdd/` 的其他报告一样不入提交，因为未被 jj 跟踪。
- `t3.` 前缀有歧义提示：`type_selftest.cr` 原有 6 个 `t3.*`，是 P2a 的 `type_compat_strict` 分派例，与本批 14 个 `t3.*` 前缀相同但名字没有碰撞。本批名字包括 `cover_all`、`missing_one_verdict` 等。grep 时按全名定位。

## 8. 证据命令速查（可复核）

```bash
# 判据 2（用例表，263）
nice -n 19 ./build/corec selftest-types | tail -1
# 判据 4（ELF canary；必须先 clean-cache、cwd = 仓库根）
nice -n 19 ./build/corec clean-cache && nice -n 19 ./build/corec build tests/suite/ptr_arith.cr -o /tmp/x --static && sha256sum /tmp/x
# 判据 8（.ccr）
nice -n 19 ./build/corec clean-cache && nice -n 19 ./build/corec ccr tests/suite/ptr_arith.cr -o /tmp/y.ccr && sha256sum /tmp/y.ccr
# 探针（22 例；换 BIN 即跑对照）
bash /tmp/r2p3t3_probe/run.sh /tmp/p3t3_base_bin/corec OLD
bash /tmp/r2p3t3_probe/run.sh ./build/corec NEW
bash /tmp/r2p3t3_probe/run2.sh ./build/corec NEW2      # p18-p20
# 语料四遍对拍（check/shadow × 旧/新）
bash /tmp/p3t0_run.sh check  /tmp/p3t3_base_bin/corec /tmp/o && bash /tmp/p3t0_run.sh check  ./build/corec /tmp/n && diff -r /tmp/o/logs /tmp/n/logs
bash /tmp/p3t0_run.sh shadow /tmp/p3t3_base_bin/corec /tmp/os && bash /tmp/p3t0_run.sh shadow ./build/corec /tmp/ns && diff -r /tmp/os/logs /tmp/ns/logs && nice -n 19 python3 /tmp/p3t0_agg.py /tmp/ns
# 新档 + CI + 自举链
nice -n 19 python3 tests/selfhost/test_match_exhaust.py
nice -n 19 env CI_JOB_NAME=selfhost-tests bash src/ci/run.sh
nice -n 19 env CI_JOB_NAME=full-bootstrap bash src/ci/run.sh && cmp /tmp/corec2 /tmp/corec3
```
