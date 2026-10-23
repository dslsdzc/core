# R2 P5 Task 3 报告：unknown 清零，命名面判定化（身份链和可判定面加强）

日期：2026-09-13。起点：`7f6c38cb`（P5 Task 2；工作副本为空，`jj status` 干净；起点 `build/corec` 为 `e3814ad8…`）。
产物：`build/corec` = `10f8d44dc1be14f7944acf30449b995a97f2334ee88618e2aa1dbcfb08a8ec6c`（两次构建逐字节相同）；证据目录 `/tmp/p5t3/`。
报告口径：数字全部由本实例实测（命令加原始输出路径），未实测的标“未测”。

---

## 0. 一句话

命名型（struct/enum/接口行、泛型形参、泛型应用）在引擎里原本一律返回 -1，回落到 legacy 并设置 `g_replace_unknown`。本任务按计划裁-2 (a) 做命名面判定化：桥接层给命名原子挂身份链（`[名字令牌]` / `[基名令牌，实参项…]`，两个构造点逐位同构），引擎侧按“同链为 1，链异且链元素在域内为 0，域外为 -1”判定，不接结构性展开（P3a 反证）。清零判据是语料和可判定域探针的 `replace_unknown` / `replace_bridge` 都为 0（实现前为每档 1 到 2）。残留 -1 只有两个面：① 参数链不变槽元素非同形（计划停条件②，本任务不动，见第 6 节）；② 域外守卫面（空链、位置错位、NEVER/DYN 混类、μ 变元，故意保持 -1，登记）。行为面与 legacy 同值（全语料 rc 和日志与冻结基线零差异；D26 同源对拍零差异），唯一收紧面是泛型约束站点的 TG02（第 7 节，登记）。

---

## 1. RED 基线（Step 1；冻结基线 `/tmp/p5t0/base/corec` 为 pre-P5，命名面与 T2 后同态）

探针是 `/tmp/p5t3/probes/n*.cr`，命令为 `corec check F --type-shadow --type-shadow-dump D`（逐档 `clean-cache` 无关，因为 check 不落缓存）。
下表是修复前后逐条对比（rc 和诊断逐条不变，清零不等于放宽也不等于收紧，包含预期拒绝者）：

| 探针（形态） | rc | RED `unknown_engine`/`replace_unknown` | POST 同列 | 说明 |
|---|---|---|---|---|
| n02 异名同形命名（NA 对比 NB） | 1 | 1 / 1 | 0 / 0 | Table D 主形态 ①（TA01 照旧） |
| n03 同实参泛型应用两实例化（`Box[int]` 两行） | 0 | 1 / 1 | 0 / 0 | Table D 主形态 ②（受照旧） |
| n04 异实参泛型应用（`Box[int]` 对比 `Box[str]`） | 1 | 1 / 1 | 0 / 0 | 同族（Table D 未列，本任务补测） |
| n10 命名对比原生（NA 对比 int） | 1 | 1 / 1 | 0 / 0 | 计划 Step 1 列出的混类形态 |
| n14 可选含异名（NA? 对比 NB?） | 1 | 1 / 1 | 0 / 0 | union 面（经 lit_implies 命名规则） |
| n15 应用实参含命名（`Box[NA]` 两次 / `Box[NA]` 对比 `Box[NB]`） | 1 | 2 / 2 | 0 / 0 | 实参位递归 |
| n16 嵌套应用（`Box[Box[int]]` 两处） | 0 | 1 / 1 | 0 / 0 | 规范形递归（b 为基型行） |
| n20 应用对比原生（`Box[NA]` 对比 `Box[int]`） | 1 | 1 / 1 | 0 / 0 | 实参位混类 |
| n21 泛型形参 T 赋 int | 1 | 1 / 1 | 0 / 0 | T 的链 [token] 对比 int 原子（混类） |
| n05 递归命名 / n09 泛型形参同 / n12 别名透明 / n19 引用传参 / n22 struct 互赋 / n23 同枚举 | 同前 | 0 / 0 | 0 / 0 | 原本已可判定（节点同一快路径） |
| n13 `[NA;2]` 对比 `[NB;2]` | 1 | 1 / 1 | 1 / 1（残留） | 不变槽面，停条件②（第 6 节） |
| n17 `*NA` 对比 `*NB` | 1 | 1 / 1 | 1 / 1（残留） | 同上 |
| n18 `(NA,int)` 对比 `(NB,int)` | 1 | 1 / 1 | 1 / 1（残留） | 同上 |

`old_stricter` / `old_looser` / `unknown`（两个桶）/ `replace_bridge` 全档全为 0（前后都是）。
语料（72 档）RED 为 `replace_unknown=0`（T0 表 C 实测）。命名面 -1 只在探针形态出现，清零判据仍必须在探针面成立。

---

## 2. 实现（Step 3）

### 2.1 桥接侧：命名面身份链（`ty_shadow.cr`）

新增内容位于 `sh_null_term` 与 `sh_term_of_ti` 之间：

```
fn sh_named_identity_term(ti)         // TYP_NAMED / TYP_GENERIC_PARAM
    = tt_atom(AK_NAMED, ti, tt_cons(sh_name_token(get_type_data(ti)), tt_nil()))
fn sh_apply_args_chain(ti, variant)   // 泛型应用实参链（variant 0 = 桥接面递归 / 1 = 签名面递归）
fn sh_apply_identity_term(ti, variant)
    = tt_atom(AK_NAMED, 基型行，tt_cons(sh_name_token(基名 ni), 实参项链))
```

- b 槽语义：NAMED/PARAM 为本行（named_dedup 按名规范，同名同行）；APPLY 为基型行（规范形，与 `sh_sig_term_of_ti` 原形态一致）。b 仍是标注（D21 的 `atom_of` 消费者），引擎命名面只比较 a/c。APPLY 取基型行而不是本行是规范形要求：`Box[int]` 两处实例化各占一行（`alloc_type` 裸分配），如果 b 取本行，同型两行的节点不同，节点同一快路径、不变槽结构比较、接口签名（`iface_axis` 的 `tt_list_same`）都会失真。实测 n03/n16 两处实例化的项逐节点相同（`t3n.apply_two_rows_same_args` / `t3n.nested_apply_same`）。
- `sh_term_of_ti`：NAMED/PARAM/APPLY 三个分支改走上述构造；`else`（未知 kind 防御分支）保持无链，因此引擎域外返回 -1，不猜。
- `sh_sig_term_of_ti`（:1146，双构造点契约）：NAMED/PARAM 分支与 APPLY 分支同步为同一形态（APPLY 由“基型行加裸实参链”改为“基型行加 [基名令牌，实参项链]”），因此两个点对同型逐位同构（`t3n.two_points_isomorphic` 断言 `sh_sig_term_of_ti(x) == sh_term_of_ti(x)`）。差异只剩实参项的递归函数（桥接面对签名面，签名面数组 N 不入项，语义等价由引擎判，实测 `ifc.sig_len_not_in_identity` 等接口面用例全部通过）。

### 2.2 引擎侧：命名面可判定域（`type_engine.cr`，`lit_implies` 正原子分支）

替换原来“`AK_NAMED` 一律返回 -1”的守卫（:192/:198 两处之一，正原子面；¬ 面保持 -1，见第 5 节第 3 条）：

```
if tt_tag(lp) == TT_ATOM && tt_tag(lq) == TT_ATOM {
    pk := tt_a(lp); qk := tt_a(lq);
    if pk == AK_NAMED || qk == AK_NAMED {
        d := te_named_pair(pk, lp, qk, lq);
        if d == -1 { g_ty_uncovered = 1; return -1; }
        return d;
    }
    if pk != qk { return 0; }
    lv := tt_list_variance(pk, tt_c(lp), tt_c(lq));
    ...
```

新增判定核（同文件，`lit_implies` 之前）：

| 函数 | 语义 |
|---|---|
| `te_is_name_token(e)` | 身份令牌形态为 `TT_ATOM ∧ AK_UNIT ∧ b ≥ 0`（名字令牌、变体名令牌、mut 标记同式） |
| `te_is_arg_term(e)` | 实参位允许的项为 `TT_ATOM / TT_UNION / TT_INTER / TT_CONS / TT_NIL`（μ 变元、¬、裸值为域外） |
| `te_token_cmp(e1,e2)` | 令牌位：节点同一性（不同节点返回 0）；位置错位（非令牌）返回 -1 |
| `te_arg_cmp(e1,e2)` | 实参位：使用引擎自身的 `ty_equiv`（三态直传，N 面经既有不变槽 b 忽略规则自动正确） |
| `te_chain_cmp(slot,p,q)` | 链逐元素（slot 0 为令牌位，≥1 为实参位）；链形不同返回 0；非链形返回 -1 |
| `te_named_pair(pk,p,qk,q)` | 同类（都是 NAMED）时比较链（空链返回 -1）；混类时，命名侧带链且异类侧不是 NEVER/DYN 返回 0，否则 -1 |

规则与 legacy 的口径对齐（等价面）：同链对应 legacy 1；链异对应 legacy 0（legacy 是 kind 加 data 递归，命名行的 data 是名字索引，named_dedup 使“同名等价于同行”，因此与令牌同一性一致）；混类对应 legacy 跨 kind 为 false，即 0。
不接结构性展开（链里只有身份令牌和实参类型项，没有字段或变体结构）：`unf.nominal_structural_equal`（展开项结构相等）与 `unf.nominal_equiv_atomic_decided`（桥接项为 0）双断并存，钉住边界。

### 2.3 适用域守卫（计划 Step 3-③）和域外面（故意保持 -1）

- 空链命名原子（未覆盖面②的原形态，没有身份可判）返回 -1。
- 令牌位放类型项，或者实参位是 μ 变元（非类型项），返回 -1（位置错位不猜）。
- `AK_NEVER` / `AK_DYN` 混类返回 -1（⊥/⊤ 语义没有在本层建模，“never ⊆ X”“X ⊆ dyn”不属于本批）。
- ¬ 面（`lp ⊆ ¬x` 的命名守卫）返回 -1，未动（桥接层不产 TT_NOT，生产不可达，登记）。

---

## 3. 清零判据（Step 2）：全语料和探针

| 面 | 命令 | 结果 |
|---|---|---|
| 语料 `replace_unknown` / `replace_bridge` | `bash /tmp/p3t0_run.sh shadow ./build/corec /tmp/p5t3/parity/final_shadow`（72 档） | 0 / 0（70 档出摘要；全分类计数 `old_stricter=old_looser=unknown=unknown_bridge=unknown_engine=unknown_engine_uncovered=unknown_engine_budget=0`）；`decisions=agree=32917`（零差异） |
| 探针语料（可判定域 18 档） | 第 1 节表的 POST 列 | `unknown_engine=0 ∧ replace_unknown=0` 全档 |
| 站点覆盖（shadow，同报） | 上汇总 | `assign-node=24932 · fn-body-ret=5897 · if-branch=2051 · struct-field-type=28 · array-elem-type=4 · generic-apply-base=2`（其余 4 站为 0） |
| 残留（不变槽面 3 档） | n13/n17/n18 | 仍为 1 / 1（可判定但本任务不动，停条件②，第 6 节） |

---

## 4. 判据复验（Step 4，全部由本实例实跑）

| # | 判据 | 命令 | 结果 |
|---|---|---|---|
| 1 | 构建 | `nice -n 19 python3 build_selfhost_native.py`，2 次 | rc=0；`build/corec` `10f8d44d…` 两次逐字节相同；`corearch 6f9f31d8…` / `corelsp c78f613f…` 未变（T3 未触其清单面） |
| 2 | 自源 check | `./build/corec check src/compiler` | rc=0 |
| 3 | 类型引擎自测 | `./build/corec selftest-types` | 386/386（367 加 19 个新例；3 处重钉见第 5 节） |
| 4 | 新套件 | `python3 tests/selfhost/test_named_face.py` | 18/18（接受 10，拒绝 8；不依赖影子通道） |
| 5 | ELF canary | `clean-cache`，然后 `build tests/suite/ptr_arith.cr --static` | IDENTICAL `95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475`（28822B） |
| 6 | `.ccr`（两套口径，冷态） | `corec ccr` / `corec build --static` 加 `clean-cache` | `ptr_arith` 90823B `fb4a3b59…` / 90966B `592afa31…`（与基线逐字节相同）；`generics_test` 135341B（增加 640）/ 135484B（增加 640）（差恒为 143B），delta 来自 TYPE 段项表（见第 8 节第 ② 条） |
| 7 | `--dump-objects` | 旧 `.ccr` 对比新 `.ccr`（`generics_test`） | 逐字节相同（3521 行） |
| 8 | `.cir` DOT | `corec cir`（`generics_test`） | 逐字节相同 |
| 9 | 全枚举 | 57 档（`tests/selfhost/test_*.py` 加 `tests/bootstrap/*.py`） | 57/57 rc=0（T2 的 56 加新套件 1） |
| 10 | 五个 CI job | `CI_JOB_NAME={check,bootstrap-tests,suite,selfhost-tests,full-bootstrap} bash src/ci/run.sh` | 见第 4.1 节 |
| 11 | 自举链 | `corec` 到 `corec2` 到 `corec3` 加 `cmp` 加 N06 加冒烟加 `--help` | `cmp` IDENTICAL（双 `ba8d98b8…`）；N06 为 0/0；冒烟 42；`--help` rc=1 |
| 12 | 冻结基线同源对拍（D26） | `bash /tmp/p3t0_run.sh check /tmp/p5t0/base/corec <新目录>` 对比 `... ./build/corec <新目录>`（同一份当前源） | 72 档 rc 逐档相同，日志 0 差异（比较器见第 4.2 节） |
| 13 | 语料 check 分布 | 上 | 34 档 0 / 38 档 1（与 T0 基线逐档相同） |
| 14 | 突变控制，至少 2 条 | 第 9 节 | M1/M2/M3 逐条转红；精确回滚（源 sha 复原加二进制逐字节回原值） |

### 4.1 五个 CI job

| job | rc | 备注 |
|---|---|---|
| check | 0 | build 加 `check src/compiler` rc=0 |
| bootstrap-tests | 0 | 3/3 |
| suite | 0 | ALL PASS |
| selfhost-tests | 0 | 全部套件通过（含新挂 `test_named_face.py` 18/18；`test_generic_constr.py` 15/15，其中 1 例重钉见第 7 节） |
| full-bootstrap | 0 | `cmp /tmp/corec2 /tmp/corec3` IDENTICAL 加 `--help` rc=1。首跑 rc=127 是自录扰动：本实例在作业运行中编辑 `run.sh`，bash 按字节偏移增量读脚本，导致误解析；文件静止后重跑 rc=0，见第 10 节第 6 条 |

原始输出在 `/tmp/p5t3/ci2_*.log` 加 `ci3_full-bootstrap.log`。

### 4.2 D26 同源对拍口径

“冻结基线配当前源”对比“当前二进制配当前源”，逐档 `check`，rc 零差异，日志零差异（`/tmp/p5t3/parity/final_base_on_newsrc` 对比 `/tmp/p5t3/parity/final_check`）。
另外，与 T0 的“冻结二进制配旧源”基线相比，唯一差异是 5 个自源文件（`src/compiler/{_import,ccr_io,main}.cr`、`src/targets/x86_64-linux/{_import,main}.cr`）的 `decisions` 增量（增加 147，全部 agree，零差异桶）。原因是自源里多了本任务的代码行（站点数随源增长；T0 到 T2 也有同类增加 147）。非自源 65 档逐字节相同。

---

## 5. 翻转钉和自测（Step 1/4）

重钉 3 处（翻转向量逐条）：

| 旧钉 | 位置 | 新钉 | 实测 |
|---|---|---|---|
| `t3.unknown_fallback_legacy`（断言回落恰好加 1） | `type_selftest.cr` t3 段 | `t3.named_face_decided_no_fallback`（引擎自决为 0 且零回落） | FAIL 变 PASS |
| `unf.nominal_equiv_atomic_unknown`（断言 `ty_equiv == -1`） | `type_selftest.cr` unf 段 | `unf.nominal_equiv_atomic_decided`（引擎自决为 0） | FAIL 变 PASS |
| `unf.nominal_type_equal_false`（断言回落加 1） | 同上 | 同例名，断言零回落（`g_replace_unknown` 零增量） | FAIL 变 PASS |

未动（守住边界）：`unf.nominal_structural_equal`（展开项结构相等为 1，是“等价面不展开”的对照断）、`t1.n_face_gate_nested`（断言不回落，见第 5 节第 3 条口径说明）、`t3.bridge_fallback_legacy`（桥接缺口回落，仍是 -1 面）、`unf.ga_*`（展开层）等。

新增用例段 `ts_t3n_run()` 共 19 例（`t3n.*`，见 run.sh 注）：链形态、同名同行、异名判否、混类判否、NEVER/DYN 域外、空链域外、令牌位错位、实参位 μ 变元、回落归零、应用规范 b 槽、同实参两行同节点、异实参判否、应用对比裸名、双构造点同构、嵌套应用、可选含命名、域外并集面、不变槽残留登记、同元素序列等价。

新套件 `tests/selfhost/test_named_face.py` 共 18 例（行为断言形态：接受为 `build` 加执行 rc=0；拒绝为 `check` rc=1 加诊断，且 `build` 面同样有诊断；不依赖影子通道，因此 P5 T5 下线后照常可跑）。挂在 `src/ci/run.sh` 的 selfhost-tests。

注（预存行为，不是本任务引入，写套件时实测发现）：TA01/TG02 等非硬名单诊断不阻止 `build`（`main.cr:149-170` 的硬名单检查只收 R002/TK05/TK06/TS*/TK02/TM03），因此 `corec build` 在这些诊断下仍 rc=0 并产出二进制（冻结基线同样）。本套件以 `check` rc 为判据面（照项目判据口径）。建议另单登记（见第 8 节第 ④ 条）。

---

## 6. 停条件②（触发，按纪律未单方改动）

| 项 | 内容 |
|---|---|
| 触发证据 | `struct NA{x:int} struct NB{x:int}`；`a:[NA;2]; b:[NB;2]; a=b;`（n13），清零后仍是 `unknown_engine=1 replace_unknown=1`；同族 n17（`*NA` 对比 `*NB`）、n18（元组） |
| 成因 | 数组、指针、元组的元素位是 `tt_list_variance_at` 的不变槽：`tt_type_elem_same(ha,hb) != 1` 时设置 `g_ty_uncovered=1; return -1`。元素是已经可判的命名原子，节点不同就判不出，返回 -1 |
| 语义地位 | 可判定（legacy 判 0，行为面早已正确拒绝）。本任务未动，依据计划 Step 3-③ 原文“该面本任务不动，除非探针证明残留 -1 来自该面；动则须逐面给出链元素皆类型项的证据” |
| 建议修法（未实施） | 不变槽元素比较改为三态：`tt_type_elem_same == 1` 时为同；否则 `te_elem_cmp`（令牌按节点同一性，类型项按 `ty_equiv`）为 0 时返回 0；域外返回 -1。收益是 n13/n17/n18 残留清零；代价和风险是把“确定不同返回 0”从命名面扩到全部不变槽元素（含原生、结构、令牌），超出本任务原范围 |
| 处置 | 已向协调者提出单独裁决（消息已发）；本提交按“不动”执行，残留和证据落纸（第 3 节加本表加套件 `residual.*` 两例钉行为不变）。裁定（2026-09-13，协调者）为走默认案 ①：本任务只做命名面清零，该面另立一步，紧跟本任务派发 |
| 状态（2026-09-13 后续） | CLOSED，由 R2 P5 Task 3b 实施（`te_elem_cmp` 不变槽元素三态）：n13/n17/n18 残留从 `unknown_engine=replace_unknown=1` 变为 0/0；报告 `docs/archive/sdd/p5-task3b-report.md`、计划“Task 3b”节、证据 `/tmp/p5t3b/`。链元素排序表、全语料零翻转、突变控制 4 条（M2 中和类型项面时本残留复红 1/1，是因果硬证据） |

### 6.1 交接条目（给后续批次，可直接作该批 RED），已于 Task 3b 闭合（见文末状态行）

复现（红态用冻结基线 `/tmp/p5t0/base/corec`；POST 为本提交二进制）：

```
# 探针（源码 + 前后两态日志 + dump 均在 /tmp/p5t3/probes/）
cat /tmp/p5t3/probes/n13_arr_diff_named.cr          # struct NA{x:int} struct NB{x:int}; a:[NA;2]; b:[NB;2]; a=b;
nice -n 19 /tmp/p5t0/base/corec   check /tmp/p5t3/probes/n13_arr_diff_named.cr --type-shadow --type-shadow-dump /tmp/x.dump   # 红态：unknown_engine=1 replace_unknown=1（rc=1 TA01）到 /tmp/p5t3/probes/n13_arr_diff_named.base.log
nice -n 19 ./build/corec          check /tmp/p5t3/probes/n13_arr_diff_named.cr --type-shadow --type-shadow-dump /tmp/x.dump   # 本提交后仍 1/1 到 /tmp/p5t3/probes/n13_arr_diff_named.log
# 同族：n17_ptr_named（*NA vs *NB）/ n18_tuple_named（(NA,int) vs (NB,int)），双双 1/1
```

成因：`tt_list_variance_at` 的不变槽：`tt_type_elem_same(ha,hb) != 1` 时设置 `g_ty_uncovered=1; return -1`。元素是已经可判的命名原子，节点不同就判不出；如果元素是序列，`tt_seq_same` 已经忽略 N，N 面不是问题。
影响面是全部不变槽元素（原生、结构、令牌、命名，不止命名面）。
建议修法（未实施）：不变槽元素比较改为三态 `te_elem_cmp`。`tt_type_elem_same == 1` 时为同；否则两侧都是令牌（AK_UNIT 且 b ≥ 0）时按节点同一性（不同节点返回 0），两侧都是类型项时用引擎 `ty_equiv`（0/1/-1 直传），其余返回 -1。结果为 0 时 `return 0`，为 -1 时设置 uncovered 并 `return -1`。
该批开工前须带齐三件证据（协调者裁定）：① “链元素皆类型项或身份令牌”的适用域证明；② 全语料对拍（72 档 rc 加日志加 shadow 计数，与冻结基线同源）；③ 突变控制加负控。尤其要确认令牌按节点同一性比较是否会误判“两个同名但不同节点”（现状令牌为 `tt_atom(AK_UNIT, ni, -1)`，同名即同节点，DAG 去重，该形态应不可达，须用探针钉死）；另一个负控是令牌与原生 `unit` 类型项同形（`AK_UNIT ∧ b ≥ 0`），位置或语境错位时不得误判。
行为面预期：n13/n17/n18 的 rc 和诊断不变，提高的只是引擎判定率，回落计数归零。套件 `test_named_face.py` 的 `residual.*` 两例已按“行为不变”钉住，修法实施后应照常全部通过；如果不通过，说明误伤行为面，应停下上报。

交接结论（2026-09-13，Task 3b 实测）：三种形态的残留计数从 1/1 变为 0/0，rc 和诊断逐条不变，套件 `residual.*` 两例照常全部通过（18/18），本交接条目的预期全部成立。另外发现并登记一项预存的 ¬ 面过判，被本步揭开（`B ⊆ ¬R` 判 0；影响面仅是 witness 项的 `ty_sub` 消费者，全语料零翻转），见 p5-task3b-report 第 7 节。

---

## 7. 收紧面（登记；新 rc=1 面的 report-only 证据）

命名面接入引擎后，混类判定（命名对原生等）从 -1 变为 0。消费侧有一处把 0 和 -1 分开处理：

- 站点：`gen_constr_satisfied` / `gen_inst_constr_satisfied`（泛型约束满足判定，`checker.cr:2069/:1327`）。0 时调用 `gen_constr_raise`（TG02 加反例）；-1 时零动作（不判）。
- 触发形态：`struct Box[T: int] { … }` 加 `Box[S]`（S 是命名结构体），以及同族“命名实参对原生约束”。
- report-only 证据：全语料 72 档 0 命中（rc 分布和逐档日志与冻结基线逐条相同；D26 同源对拍零差异）。唯一命中面是 `tests/selfhost/test_generic_constr.py` 的 1 例登记面（原断言“不判则零诊断”）。
- 语义：正确。S 不是 int，legacy 的 `type_equal(S,int) = false` 也是同一结论，旧的“不判”纯属引擎未覆盖面。
- 处置：该例重钉为 `struct_inst_named_arg_rejected`（TG02 加反例断言）；`build` 侧 rc 不变（TG02 不在硬名单，产物面零变化）。提请复核：如果裁决“约束站点应保持不判”，回退面是 `te_named_pair` 混类分支回到 -1，探针 n10/n20/n21 的计数会复红，已在报告显式标注。

---

## 8. 登记（不不报错地）

1. 残留面：不变槽元素非同形（第 6 节），可判定但未动（停条件②）。
2. `.ccr` TYPE 段增长（`generics_test` 增加 640B）：身份链需要新的项行（名字令牌原子加 CONS 链），TYPE 段项表从 52 行变为 68 行（`terms 52` 到 68、`rows 42` 到 42 不变；实测 dump 对比 `term 19/20/21` 为令牌、CONS、带链命名原子）。影响面仅是 TYPE 元数据段，发射面零泄漏（同语料 ELF 与基线逐字节相同，`--dump-objects` 相同，`.cir` DOT 相同）；`ptr_arith`（没有语料命名行）两条口径记录逐字节相同。判据 ⑤ 因此按“无语料命名行档逐字节相同加命名档 delta 归因”重定（T2 已有判据重定先例）。
3. `¬` 面（`lit_implies` 的否定守卫）未动：桥接层零 TT_NOT 生产，不可达；保持 -1（登记，不是漏放）。
4. 预存发现（另单建议）：非硬名单诊断（TA01/TG02 等）不阻止 `build`（第 5 节注），本任务只记录，不修。
5. 未编码角落（kind 维）：本链不区分 kind（TYP_NAMED 与 TYP_GENERIC_PARAM 同名时判等，legacy 按 kind 判否）。可达性未证实（需要同名跨类比较才触发）；登记，未加 kind 标记（避免动 token 空间）。
6. `--dump-tk-terms` 面：APPLY 行的项 b 槽由“本行”变为“基型行”，该项在 DF 实现方式分类里由 face 0（项可逆）降为 face 1（辅码保真），派生码不变（D22-① 不受影响）；语料实测 APPLY 行不入 `tk`（T0 直方图 tk 属于 {0,1,2,3,8,10}），零可观测变化。
7. 未测：`ty_sub` 负值的独立计数通道（T0 表 D 已登记无通道）。本任务的残留归属靠 `--type-shadow` 计数加自测段直断，不引为 `ty_sub` 统计。

---

## 9. 突变控制（至少 2 条；逐条转红加精确回滚）

| 突变 | 内容 | 转红证据 | 回滚 |
|---|---|---|---|
| M1 | 身份链令牌塌缩为常量（`sh_name_token(0)`），异名同形判断为相等 | 自测 8 例 FAIL（含 `t3n.diff_name_diff` / `chain_shape`）；套件 16/18（`named.diff_name_rejected` / `named.optional_diff_rejected` 转绿，假阳性被抓） | 源 sha 复原，重建二进制逐字节回原值 |
| M2 | 规则放宽（链异也返回 1） | 自测 7 例 FAIL；套件 14/18（异名、异实参、可选 4 例转绿） | 同上 |
| M3 | 去掉适用域守卫（空链判 0） | 自测 1 例 FAIL（`t3n.no_chain_out_of_domain`，源级探针不可达域外面，有效性来自自测段） | 同上 |

驱动 `/tmp/p5t3/mut.py`；回滚校验为 `sha256sum -c /tmp/p5t3/mut_src_before.txt` 加三个二进制 sha 复原（先例是 T1 突变控制同款纪律）。

---

## 10. 执行偏离（诚实登记）

1. APPLY 项的 b 槽取基型行（计划接口没有明写 b 的取值），理由是规范形（第 2.1 节）。副作用是双构造点从“失同步”变为“逐位同构”，计划停条件③不再触发。
2. `.ccr` 判据重定（第 8 节第 ② 条）：计划 Step 4-⑤ 的“冷态逐字节相同”在含命名行的语料上不可满足（身份链必然新增项行）。已按“无语料命名行档相同加 delta 归因可复核”重定并落纸。
3. 约束站点收紧（第 7 节）：计划未预列，report-only 后登记并重钉 1 例，提请复核。
4. 一次探针语法返工：`Box[int] { v: 1 }` 字面量形态 parser 不解析（P01，冻结基线同样，是预存面），套件改用形参位形态（等于 Table D 主形态原样）。
5. 未改：`globals.cr`（没有新计数，清零证据走影子摘要加自测直断）；`CIR_CACHE_VER`/`CCR_VERSION`/`ESZ_*`/`OFF_*`/NOD 36B/.cir 快照布局零触碰。
6. CI full-bootstrap 首跑 rc=127 是自录扰动，不是代码缺陷：本实例在该后台作业运行期间编辑了 `src/ci/run.sh`（计数注释），bash 按字节偏移增量读脚本，尾部误解析（`src/ci/run.sh: 行 121: xit: 未找到命令`）。文件静止后重跑 rc=0 加 `cmp` IDENTICAL（`/tmp/p5t3/ci3_full-bootstrap.log`）。教训是 CI 作业运行期间不得编辑其脚本或清单，这是 T1“一构建一编译串行”纪律的自然延伸。

---

## 11. 证据路径

| 用途 | 路径 |
|---|---|
| RED/POST 探针（19 档加各自 `.log/.dump`；RED 侧为 `*.base.log`） | `/tmp/p5t3/probes/` |
| 语料对拍（check/shadow/D26，含逐档 logs） | `/tmp/p5t3/parity/{final_check,final_shadow,final_base_on_newsrc}/` 加 `parity_*.out` |
| 构建日志（6 次：确定性加突变重建） | `/tmp/p5t3/build{1..6}.log` |
| 自测和套件日志 | `/tmp/p5t3/{selftest1..3,t_generic_constr,t_ccr_types,t_ccr_v7}.log`、`enum3_*.log` |
| CI job | `/tmp/p5t3/ci2_*.log` |
| 自举链 | `/tmp/p5t3/chain2/{corec2,corec3,corec2.log,corec3.log}` |
| canary / `.ccr` / dump 对拍 | `/tmp/p5t3/{pa_final,f_*_ccr.out,f_*_st.out.ccr,gt_do*.txt,gt*.cir}` |
| 突变控制 | `/tmp/p5t3/mut.py` 加 `mut_src_before.txt` |
