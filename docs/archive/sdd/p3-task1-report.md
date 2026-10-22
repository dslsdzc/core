# R2 P3 Task 1 报告：定长退役收口（array/slice 方向、变型表、长度档位）

状态：DONE_WITH_CONCERNS。判据全部通过，另有 4 项登记。① EXPR_LET 站点没有任何兼容检查，这是既有缺口，本任务实测确认，未修，见 §6-1。② 不变槽的“确定不等价则为 0”加强，需要先有“链元素都是类型项”的不变量，见 §6-2。③ Task 0 的变体身份令牌从裸 name 索引升级为令牌原子，这是跨任务改动，实测依据见 §3.3，任务说明见 §6-3。④ 判定点参数顺序归一，这是实现裁决，见 §3.1。

提交：`ef61f002`（change `qvpuwwvz`，父提交 `61d3a8b4`，即 P3 Task 0 末提交）。路径限定 4 个文件：`src/compiler/checker.cr`、`ty_shadow.cr`、`type_engine.cr`、`type_selftest.cr`。373 insertions / 35 deletions。

计划：`docs/superpowers/plans/2026-09-11-r2-p3-capabilities.md` 的 Task 1。

起点：`61d3a8b4`，工作副本干净。基线二进制是起点树构建的 `build/corec 8c759c6c…`，本批开始时实测；该二进制在本批构建中被覆盖，未留档。语料和探针对照改用 `/tmp/p3t0_base_bin/corec 8f69e346…`（Task 0 起点树）。Task 0 报告 §2 判据 5 的“72 档 diff -r 空”已证明该二进制与起点树在语料面逐字节同日志。本批 §5 的 pA/pB/pC/pSliceW/pAsgnSlice 五个探针在两个二进制上实测同值，是等价性的直接交叉证据。

路径限定提交面：`src/compiler/ty_shadow.cr`、`type_engine.cr`、`checker.cr`、`type_selftest.cr`，4 个文件，与计划 Files 列逐字一致。

---

## 1. 交付物与落点（file:line，实测）

| 交付物 | 落点 |
|---|---|
| 变型表 `ty_variance_of(ak, slot)`，0 为不变，1 为协变；首版三个构造子加表外默认不变 | `type_engine.cr:247` |
| 参数链按变型比较 `tt_list_variance_at` / `tt_list_variance`。协变槽走 `ty_sub` 三态；AK_REF 槽 0 为可判定令牌；不变槽走 `tt_type_elem_same` 加 -1 未覆盖面 | `type_engine.cr:274 / 295` |
| 不变槽“类型项相等” `tt_type_elem_same` / `tt_seq_same`。序列项固定性位不参与比较，守卫条件是双方都是 AK_SEQUENCE | `type_engine.cr:214 / 223` |
| `lit_implies` 同形分支改接变型比较，收口未覆盖面①；AK_NAMED 分支不动 | `type_engine.cr:179-186` |
| 序列项构造点 `sh_seq_term(elem_ti, fixed_len)`，b 槽为固定性位：N 或 -1 | `ty_shadow.cr:219` |
| AK_REF 链槽 0 为 mut 标记 `sh_ref_mut_marker`，mut 成为判定维度 | `ty_shadow.cr:231` |
| 名字令牌 `sh_name_token`，变体身份从裸索引改为令牌原子，是 Task 0 硬化后的唯一改动 | `ty_shadow.cr:244` |
| 桥接三分支改接：ARRAY/SLICE 到 `sh_seq_term`，REF 到标记加元素 | `ty_shadow.cr:287-295` |
| `array_len_walk(a, b, dir)`。方向规则是源视图到目标固定则返回 0，不是 -1；对称核保持 P2a 原语义逐字 | `checker.cr:369` |
| 方向面 `array_len_constraint_ok`，签名不变；对称核 `array_len_constraint_sym` | `checker.cr:415 / 422` |
| 站点组合 `type_compat_strict`，参数顺序为（源，目标）；无方向站点组合 `type_compat_sym` | `checker.cr:433 / 440` |
| 10 个判定点参数顺序归一：6 处换序，hotpatch 站改用对称核；站点数量、位置、措辞分派不变 | `checker.cr:1168（sym）· 1536 · 1550 · 1566 · 1816 · 2017 · 2431 · 2779 · 2906 · 2972` |
| 自测用例段 20 例（t1.*），包含嵌套身份双钉和站点三态 | `type_selftest.cr:1227-1347` |

签名核对，与计划 Interfaces 块一致：`ty_variance_of(ak, slot)`、`sh_seq_term(elem, fixed_len)`、`array_len_constraint_ok(a, b)` 签名不变，方向规则在其内部。

---

## 2. 判据（命令与结果）

| 序号 | 判据 | 命令 | 结果 |
|---|---|---|---|
| 1 | 自举构建 | `nice -n 19 python3 build_selfhost_native.py` | rc=0；三个守卫 `build log clean (error[ = 0, undefined = 0)`（corec/corearch/corelsp） |
| 2 | 自测用例表 | `nice -n 19 ./build/corec selftest-types` | 249/249。基线 229/229，增加 20 例，零 FAIL，rc=0 |
| 3 | 接口查表回归 | `nice -n 19 python3 tests/selfhost/test_iface_ops.py` | 76/76 通过 |
| 4 | ELF canary 逐字节 | clean-cache，然后 `build tests/suite/ptr_arith.cr --static -o /tmp/pa_p3t1b`，再 sha256 | `95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475`，IDENTICAL |
| 5 | 收紧清单 | 见 §3，19 个探针在旧新二进制上逐条运行 | 6 条“旧接受、新拒绝”，全语料零命中，见 §4 |
| 6 | 影子对拍门 | 72 档 `--type-shadow --type-shadow-dump`，旧新二进制各一遍，逐档 clean-cache | 见 §4 |
| 7 | 回归套件 | `test_compile`、`test_purity`、`test_ccr_v7`、`test_type_engine`、`test_impl`、`test_borrow`、`test_pointer_safety`、`test_params_limit`、`test_tuple_slots`、`test_agg_slots`，加 `CI_JOB_NAME=selfhost-tests src/ci/run.sh` | 全部通过：27/27、76/76、All selfhost compile tests passed，CI rc=0，0 FAIL |
| 8 | `.ccr`（计划预期不变） | clean-cache，然后 `ccr tests/suite/ptr_arith.cr` | `ecd7a9dfd557810651d9f4a31bf5775556b5c15518fb0a9dbacb56af83dcd29d`，IDENTICAL，等于 P2b/Task 0 记录值 |
| 9 | 自举链 | `CI_JOB_NAME=full-bootstrap src/ci/run.sh` | rc=0；`corec2 == corec3`，`cmp` IDENTICAL（2192286 B）；`corec3 --help` rc=1，既有约定 |
| 10 | 突变控制 | 见 §5。3 处突变，用例咬合，复位后三个 sha 逐字节复原 | M1 241/249（方向组 8 例）、M2 247/249（mut 组 2 例）、M3 246/249（嵌套身份组 3 例）；三次复位均 249/249，三个 sha 复原 |
| 11 | 确定性和资源纪律 | 连续同源重建，包含 CI/bootstrap 两个 job 自带的重建 | 三个二进制 sha 完全相同，`corec 4b099c50…` 全程不变；全程 `nice -n 19`，串行构建 |

自举源码 10 处 `[T;N]` 零改造复验：全语料包含 `src/compiler/**`（t2/t3 档，见 §4），逐档 rc 和日志零差异，因此自举源码没有一处需要改造。这是 R1 裁决的延续。

---

## 3. 行为探针（Task 1 主判据）和收紧清单

探针目录 `/tmp/r2p3t1_probe/`，19 例，cwd 为探针目录。旧二进制为 `/tmp/p3t0_base_bin/corec`，新二进制为本批 `build/corec 4b099c50…`。

### 3.1 收紧清单（旧接受，新拒绝，逐条）

| 序号 | 用例 | 旧 | 新 | 新措辞 | 成因和处置 |
|---|---|---|---|---|---|
| 1 | pA `fn g() -> [int;3] { b:[int;4]=…; return b[0..2]; }`，站点 5 顶层，视图到固定 | rc=0 | rc=1 | `error[TF01]: Array length constraint not satisfied` | 计划 Step 3 明确要求翻转的第 1 条。P2a 引入的不报错地放宽在本批关闭 |
| 2 | pF `struct S { a: [int;3] }` 接切片值，站点 9 | rc=0 | rc=1 | `error[TS03]: Array length constraint not satisfied` | 同一规则在字段位生效，是计划“站点面”的自然外延 |
| 3 | pIf1 `if c { arr } else { sl }`，站点 7，合并结果类型为 then 侧 | rc=0 | rc=1 | `error[TC02]: Array length constraint not satisfied` | 同规则。结果类型是 then_ti，因此 else 侧不能弱于它，见 §3.2 参数顺序归一 |
| 4 | pN3 `return [s, s]`，站点 5 嵌套，视图到固定：`[[int;3];2]` 接切片元素数组字面量 | rc=0 | rc=1 | `error[TF01]: Array length constraint not satisfied` | 嵌套位同律，6 个递归位全覆盖；措辞与顶层一致，一致性由 §3.3 的不变性修复保证 |
| 5 | pE1 `fn f(x: &mut int) -> &int { return x; }` | rc=0 | rc=1 | `error[TF01]: Function return type mismatch` | mut 入链，成为判定维度，替代旧的“不入链”；legacy 本来判不等，所以引擎与 legacy 归位一致 |
| 6 | pE2 `fn f(x: &int) -> &mut int { return x; }` | rc=0 | rc=1 | `error[TF01]: Function return type mismatch` | 反向同拒。计划 pE 原文的“反向拒绝”就是 mut 面的等式语义，不是 Rust 的 `&mut T <: &T` 单向 |

全语料命中为 0。§4 的 72 档 check 面旧新逐字节同日志，因此 6 条收紧没有一条触及自举源码或套件语料，没有出现“停下上报”的情形。

### 3.2 语义保持面（回归负控，旧新同值）

| 用例 | 语义 | 旧到新 |
|---|---|---|
| pB `fn h() -> [int] { c:[int;3]=…; return c; }` | 固定到视图，拓宽放行（spec §5.1 `[T;N] <: [T]`） | rc=0 到 rc=0，通过 |
| pAsgnSlice `x:[int] = a;`，站点 8 切片目标接数组值 | 拓宽。这是参数顺序归一的判别用例，换序前这里会被误拒 | rc=0 到 rc=0，通过 |
| pD `struct S { a: [int] }` 接数组值，站点 9 同向 | 同上 | rc=0 到 rc=0，通过 |
| pIf2 `if c { sl } else { arr }`，站点 7 反向 | 合并类型为切片，数组值可以进入 | rc=0 到 rc=0，通过 |
| pE3 / pE4 `&int` 到 `&int`，`&mut int` 到 `&mut int` | 同 mut 不变，防止“一律拒绝”退化 | rc=0 到 rc=0，通过 |
| pC / pN1 / pN2 异长（顶层和嵌套，双向） | 常量档拒绝语义保持，措辞不变 | rc=1 到 rc=1，通过，均为 `Array length constraint not satisfied` |
| pSliceW `s := a[0..3]; s[0] = 9;` | 切片可写，这是本批变型表的语义前提，见 §3.3 | rc=0 到 rc=0，通过 |
| pG / pG2 / pG3 | 既有缺口，EXPR_LET 无检查，不是本批面，见 §6-1 | rc=0 到 rc=0，未变 |

### 3.3 实现裁决（计划未定处，逐条）

1. 判定点参数顺序归一，这是唯一触及站点行的改动。方向规则对参数顺序敏感，而 P2a 落点时 10 个站点的实参顺序随各站原有 `type_equal` 调用继承，没有归一。实测站点 5 是（值，声明），站点 6/8/9/10 与 unify 三处是（目标，源）。本批把有方向语义的 9 个站点归一为（源，目标）。站点 5 原本正确，不动；6/8/9/10/unify(2/3/4) 换序；hotpatch 站（1）两侧都是声明，没有源和目标，改用对称核 `type_compat_sym`，等于现状语义，防止“按声明序改判”的任意性。换序零副作用有两面证明：身份面 `type_equal`（ty_equiv 双向）与长度面同 kind 的 extra 相等都对称，这是码级；行为面是 §4 全语料 72 档逐字节同日志，加上 §2 判据 6 的影子面同值。站点集合、位置、诊断码、措辞分派未动。
2. 固定性存放在序列项的 b 槽，作为标注，方向判定在 checker。引擎比较只看 a/c 两槽（`lit_implies`），所以 b 槽天然不进入等价身份，实测 `[int;3] ≡ [int;4]` 为 1。方向规则读类型行（kind/extra），不依赖项。因此计划的“N 不进入等价身份，只进入固定性位”在两层同时成立：项层的 b 槽标注，判定层的 checker 常量档和方向。
3. 序列项的固定性必须做“b 盲”比较。这是本批实测发现的回归和修复。固定性 b 会经嵌套元素位的节点同一性泄进判定：`[[int;3];2]` 的元素项与 `[[int];2]` 的元素项除 b 外逐位相同，但节点不同，于是判为非同形，引擎返回 -1（未覆盖面），回落 legacy。实测后果是 pN3 的措辞从长度专属退化为“Function return type mismatch”，并且身份路径出现 N/固定性，违反 R1 不变量。修法是 `tt_type_elem_same`：双方都是 AK_SEQUENCE 原子时忽略 b，做结构相等并递归元素；其余构造子一律按节点同一性，AK_NAMED 的 b 是行号，属于身份。修复后 pN1/pN2/pN3 三项措辞一致，都是长度专属；嵌套 N 由引擎自决，不回落，`t1.n_face_gate_nested` 断言 `g_replace_unknown` 增量为 0。
4. 变体身份令牌升级，这是 Task 0 产物的硬化，1 行加 1 个新函数。Task 0 的变体项链是 `[枚举名 ni, 变体名 ni]`，裸 name 索引入链。索引是别名，任何把链元素当术语解释的比较都会把 `str_intern` 的小整数当术语下标读取，名字碰撞就会不报错地判等。实证两条：① 首次实现把不变槽改用 `ty_equiv` 比较，`unf.enum_variant_identity_scoped` 失败，异枚举同名变体被判等；② 本批新增的固定性守卫 `tt_type_elem_same` 同样会读链元素的 class。因此令牌改为 `tt_atom(AK_UNIT, ni, -1)`，与 mut 标记同式，只按节点同一性比较。语义等价：异名得到异节点，同名得到同节点。Task 0 的 8 个 `unf.*` 用例全部通过。
5. 不变槽非同形返回 -1（未覆盖面），不是 0。语义上“不变槽参数不等价就不是子类型（0）”是正确的加强，但它需要确定不等价的判定，而链中可能有非类型令牌，见上一条。因此本批保持 P0 语义，返回 -1 加 `g_ty_uncovered`，生产面由 legacy 回落给出同一结论，实测 pE1/pE2 的拒绝就走这条路。登记为后续面，见 §6-2。变型用例因此断言“两向都不得判 1”（可变面）和“正向判 1、反向判 0”（只读面，协变槽由 ty_sub 决定）。
6. AK_PTR / AK_SEQUENCE 元素槽为不变。数组、切片、原始指针在现代码里可写，探针 pSliceW 的 `s[0] = 9` rc=0 可以实证，因此元素协变不健全。只读协变只经只读 ref（`&T`）表达。保守面登记：`&[int]` 与 `&[int∪str]` 因序列自身不变而不予放行，不做“只读序列视图”的第二层协变。本语言没有“只读序列”独立构造子。

---

## 4. 影子对拍门复跑和站点覆盖（与差异数同报）

72 档包含 t1 `tests/suite` 32 档、t2 自源 2 档、t3 后端/kernel 15 档、t4 stdlib 19 档、t5 examples 4 档，逐档 `clean-cache`，旧新二进制各一遍。

- `diff -r` 的 check 面日志为空（0 行）；shadow 日志为空（0 行）；shadow dump 为空（0 行）。因此旧二进制加新源等于新二进制加新源，同源双编译器对拍逐字节相同。
- 聚合（新，`/tmp/p3t0_agg.py`）：`decisions=29267 agree=29267 old_stricter=0 old_looser=0 unknown=0 unknown_bridge=0 unknown_engine=0 unknown_engine_uncovered=0 unknown_engine_budget=0 replace_bridge=0 replace_unknown=0`；`agree == decisions` 成立，`sum(sites) == decisions` 成立。零收紧移动，§3.1 的 6 条收紧全部在语料之外。
- 站点覆盖直方图：`assign-node=22134 · fn-body-ret=5212 · if-branch=1887 · struct-field-type=28 · array-elem-type=4 · generic-apply-base=2`；站点 1/2/4/6 在语料中零命中，与 P1/P2a/P2b/Task 0 同口径。
- 效力范围声明：零差异只覆盖赋值、返回、if 面。本任务的新能力面，包括 array 与 slice 方向、变型表、mut 维度、嵌套固定性，在语料中零命中，因此由 §3 的 19 个探针、§2 判据 2 的 20 个用例、§5 的突变控制承担证据，不能用对拍归零充当其证据。
- 语料自指：语料包含 `src/compiler/**` 自身，本批新增行进入语料，判定数从 29,237 变为 29,267，增加 30。

---

## 5. 突变控制（用例非真空性；复位后二进制逐字节复原）

| 序号 | 突变（临时，已复位） | 预期失败 | 实测 |
|---|---|---|---|
| M1 | `array_len_walk` 方向分支失效，`dir == 1` 改为 `dir == 2`，即回到 P2a 语义 | 方向组应全红 | 241/249，8 例：`t1.dir_slice_to_arr_reject`、`t1.strict_view_to_fixed`、`t1.dyn_tier_decided`、`t1.dir_nested_ptr`、`t1.dir_nested_elem`、`t1.dir_nested_tuple`、`t1.dir_nested_genapply`、`t1.dir_nested_strict`。探针面：pA/pF/pIf1/pN3 从 rc=1 回到 rc=0，pE1/pE2 仍 rc=1，说明 mut 维度独立 |
| M2 | AK_REF 链退回“mut 不入链”，`tt_cons(in2, tt_nil())` | mut 维度组应红 | 247/249，2 例：`t1.var_mut_marker_dimension`、`bridge.ref_inner`（随布局更新的既有断言）。探针面：pE1/pE2 从 rc=1 回到 rc=0，pA/pF/pN3 仍 rc=1，说明方向面独立 |
| M3 | 不变槽比较退回 `tt_list_same`，去掉固定性盲 | 嵌套身份组应红 | 246/249，3 例：`t1.n_face_gate_nested`、`t1.fixedness_not_identity_nested`（`ty_equiv` 得 -1 而不是 1，说明令牌或固定性泄入）、`t1.dir_nested_strict`。措辞面在修复前实测：pN3 退化为“Function return type mismatch” |
| — | 复位（三处还原并逐次重建） | 249/249 加 sha 复原 | 三次复位后均 249/249，rc=0；`build/corec 4b099c50…`、`corearch 2b835710…`、`corelsp 30b5cdf6…` 三个 sha 与突变前逐字节相同，说明构建确定性和复位完整 |

专一性：突变咬合面互不重叠。M1 只影响方向组 8 例，M2 只影响 mut 组 2 例，M3 只影响嵌套身份组 3 例。探针面同时给出“哪条收紧来自哪处”的独立交叉证据：M1 去掉方向后 pA/pF/pIf1/pN3 复活，M2 去掉 mut 入链后 pE1/pE2 复活。

---

## 6. 发现（登记，影响后续任务）

### ① EXPR_LET 站点没有任何兼容检查（既有缺口，本批未修，建议专批收口）

`checker.cr` 的 `EXPR_LET` 分支（`infer_expr`）只登记符号：`ti := val_ti; if type_node >= 0 { ti = res_type_node(type_node); }`。它不做值和注解的比对，该分支没有 `type_equal` 或 `type_compat_strict` 调用，全仓 grep 可以核对。实测旧新二进制同值：

- `fn h(s: [int]) -> int { x: [int;3] = s; … }` 得到 rc=0。切片值进入固定长注解，是“pA 类不报错地放宽”的站点外同族问题。
- `fn main() -> int { x: [int;4] = [1,2,3]; … }` 得到 rc=0。常量档异长也不检查，比 pA 更宽。

未修理由：这个站点不是既有 10 个判定点之一。追加它等于新增判定点和新硬错误门，必须走全语料 report-only，并且超出计划“判定点不变”的范围。建议专批或在 Task 7 收口时，按 §3.1 的参数顺序（源为 val_ti，目标为注解）加 `type_compat_strict`，先跑全语料 report-only。

影响面：本批 6 条收紧不包含这个缺口，因此“定长退役收口”在这个站点仍留缺口。这里如实登记，不用语料零命中掩盖。

### ② 不变槽“确定不等价则为 0”需要“链元素都是类型项”的不变量（后续面）

见 §3.3-5。`ty_equiv` 级比较在链包含令牌时会误判。令牌已经升级为原子（§3.3-4），但引擎仍没有“链元素都是类型项”的可检查不变量，展开层项和桥接项混用同一链空间。因此本批不开。如果 Task 3（穷尽性）或 Task 4（联合）需要更强的“不等价”判定，先落这个不变量。

### ③ 跨任务改动登记（Task 0 产物硬化）

`sh_variant_term` 的身份令牌从裸 name 索引改为 `sh_name_token` 原子，见 §3.3-4，实测依据两条。接口和语义未变：异枚举同名仍不判等，域和模式项仍逐位同一。Task 0 的 `unf.*` 8 例和穷尽性端到端 3 例全部通过。如果 plan-p3 复核要求回退，回退即恢复“链元素为裸索引”的别名风险，并且本批的固定性盲守卫 `tt_type_elem_same` 会改读其 class，二者必须同批处理。

### ④ 只读序列视图的第二层协变未做（保守面）

见 §3.3-6。`&[T]` 在 T 的维度上仍然不变，序列构造子自身不变。spec §5.1 的“只读序列视图协变”在本批以“只读 ref 元素协变”兑现。如果需要 `&[int] <: &[int∪str]` 一类判定，必须引入只读序列形状，落在 Task 2 的横切形状。

### ⑤ 性能（如实登记）

新增比较路径只在参数不是同一节点时触发，`p == q` 快路径保证主流零开销。语料 72 档 check 面没有耗时异常，`full-bootstrap` 和 CI 全部通过。未做基准测量，同 P2b 附录 A.3-⑩ 口径。

---

## 7. 过程说明

- 红态：本批没有单独构建“无新符号”的红态，同 Task 0 §7 口径。新符号此前全仓零定义，构建期 `Undefined name` 硬失败就是红。用例非真空性由 §5 的三处突变控制承担，专例成组咬合，复位后 sha 复原。
- 基线二进制：起点树的 `8c759c6c…` 未留档，被本批构建覆盖。对照使用 `8f69e346…`（Task 0 起点树，Task 0 已证语料面等价），并用五个探针实测同值交叉验证，见报告开头。
- `test_ccr_v7` 和 `.ccr` 判据：类型表行序未动，`.ccr` 逐字节相同，实测通过，没有用“结构性断言”替代。
- 语料运行器和探针：不是仓库文件。复用 `/tmp/p3t0_run.sh`，留档在 `/tmp/r2p3t1_probe/`、`/tmp/r2p3t1_sweep/`。报告与 `docs/archive/sdd/` 其余报告一致，不入提交，未被 jj 跟踪。
- 报告交付时，`build/corec = 4b099c50…`，冻结树连续两次构建 sha 相同。

---

## 8. 证据命令速查（可复核）

```bash
# 判据 2（用例表，249）
nice -n 19 ./build/corec selftest-types | tail -1
# 判据 4（ELF canary；必须先 clean-cache、cwd = 仓库根）
nice -n 19 ./build/corec clean-cache && nice -n 19 ./build/corec build tests/suite/ptr_arith.cr -o /tmp/x --static && sha256sum /tmp/x
# 判据 8（.ccr）
nice -n 19 ./build/corec clean-cache && nice -n 19 ./build/corec ccr tests/suite/ptr_arith.cr -o /tmp/y.ccr && sha256sum /tmp/y.ccr
# 探针（19 例；sed 换 BIN 即可跑旧二进制对照）
bash /tmp/r2p3t1_probe/run.sh ./build/corec
# 语料四遍对拍（check/shadow × 旧/新）
bash /tmp/p3t0_run.sh check  /tmp/p3t0_base_bin/corec /tmp/o && bash /tmp/p3t0_run.sh check  ./build/corec /tmp/n && diff -r /tmp/o/logs /tmp/n/logs
bash /tmp/p3t0_run.sh shadow /tmp/p3t0_base_bin/corec /tmp/os && bash /tmp/p3t0_run.sh shadow ./build/corec /tmp/ns && diff -r /tmp/os/logs /tmp/ns/logs && nice -n 19 python3 /tmp/p3t0_agg.py /tmp/ns
# 自举链
nice -n 19 env CI_JOB_NAME=full-bootstrap bash src/ci/run.sh && cmp /tmp/corec2 /tmp/corec3
# CI selfhost-tests 全套
nice -n 19 env CI_JOB_NAME=selfhost-tests bash src/ci/run.sh
```
