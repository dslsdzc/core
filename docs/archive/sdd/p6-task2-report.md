# R2 P6 Task 2 报告：E-10 ¬ 面过判收口（引擎判定面）

日期：2026-09-14。任务：`docs/superpowers/plans/2026-09-14-r2-p6-tail.md` 的 Task 2，Step 1 到 6。
本任务提交：`911c692d`，父提交 `e5ce8f9e`（T1），路径限定 4 个文件。执行面为仓库外隔离 workspace `/tmp/p6t2/wt`。主树当时包含其他任务的在途改动，树不可编译，本任务对主树零改动。
合流记录，协调者操作：T2 `911c692d` 与 T3 `0819d506` 合流为 `9cfa6246`，双亲零冲突，两批符号都在。
口径：全部命令 `nice -n 19`；一次构建一次编译串行，每段前用 `ps -eo comm` 实查，全程 0 并发；比较产物前 `clean-cache`；cwd 为 workspace 根 `/tmp/p6t2/wt`；`/tmp` 命名空间全程 `/tmp/p6t2/**`，没有写共享名 `/tmp/corec2|corec3|corearch|corec`，CI job 内部固定名除外，跑前用 `ps` 实查为空。
基线：T1 提交 `e5ce8f9e`，判据值为 T1 记录：72 档 34 个 0、38 个 1；探针 29 档 17 个 0、12 个 1；canary `95084e7b…d475`；`.ccr` 四条 90823/90966/135341/135484；链 `5559beef…`。72 档对拍腿使用 `tools/baseline/parity_run.sh` 加 T1 重建基线 `/tmp/p6t1/base`，sha 与允许清单逐条相同，已实核。

---

## 1. 先裁和前置

| 序号 | 事项 | 结论（协调者裁定或本任务前置侦查） |
|---|---|---|
| 1 | 落点。计划 Step 3 原文写“`ak_disjoint` 在同类且异身份时返回 1” | 按字面不可实现。`ak_disjoint` 只接收类 id（`type_engine.cr:69`；调用面 `:118`/`:327` 和自测都只传类 id），身份信息只在项里。照字面改等于“同类一律不交”，是假不交，unsound。因此落点改为 `lit_implies` 的 ¬ 面，新增域守卫和链判定，在 `:326` 后插 1 行分派。协调者已采信 |
| 2 | 正乘正面（`lit_empty_pair:118`） | 不做。该分支经过 `lits_contradictory`、`inh_any_at:718`、`ty_inhabited`、`tt_witness`、`ty_exhaustive`，到达 match 穷尽性 TM03 生产面，撞计划停条件①。单列候选，本批零改动。`ty_disjoint` 全仓生产调用者为 0，只有自测 |
| 3 | 命名链半项（附录 E-10“命名链返回 1”） | 维持 -1，不翻转。它属于 P0 终审 Important B 的在册政策（`ak_disjoint:78-80` 加钉子用例 `named.not_disjoint`，`type_selftest.cr:1820`），翻转等于政策变更。协调者裁定维持，待裁登记另起 |
| 4 | P1（空链、链元素域外、不可判） | P1-a 裁定返回 0。域外逐位不变，零新增未覆盖面，零行为变化。P1-b（-1 加未覆盖面）属于扩面，须 report-only 先行，另立登记 |
| 5 | 域。计划 Step 2 写“身份令牌或类型项的原子” | 收窄为仅 `AK_SUM` 变体项。T3b §3.1 排序表只可复用“链元素可判域”这一事实，不可复用其结论方向。`te_elem_cmp` 判断元素是否等价，¬ 面判断两个整原子值集是否相交，元素“不等价”不等于整原子“不交” |

---

## 2. 用例（RED 到 GREEN 实测）

### 2.1 RED（隔离树内，仅测试侧重钉，无引擎补丁；日志 `/tmp/p6t2/red_final.log`）

```
T2DEBUG t3_b n=3489 tag=7 ak=9 ident=T3Color::T3Blue
T2DEBUG t3_r ident=T3Color::T3Red
T2DEBUG min ty_sub(B,notR)=0 ty_sub(B,notG)=0
T2DEBUG min ty_sub(B,t3_w)=0 ty_equiv(w,B)=0 ty_sub(B,B&notR)=0 uncovered=0
FAIL t3.witness_reverse_over_claim: got 0 want 1
FAIL t3.witness_equiv_over_claim: got 0 want 1
FAIL t3.product_neg_over_claim: got 0 want 1
401/404 type-engine cases passed          # rc=1
```

- 最小单点：`ty_sub(B, ¬R) = 0`、`ty_sub(B, ¬G) = 0`。语义真值应为 1，因为异变体值集不交。
- 两侧项身份：`tt_display` 退化，见 §6-②，因此改用令牌名实取。得到 `T3Color::T3Blue` 和 `T3Color::T3Red`；结构为 `n=3489 tag=7(TT_ATOM) ak=9(AK_SUM)`。
- RED 时点：三次独立复现，时间分别为 R1 02:52:27、R2 02:53:09、R3 02:54:05，都早于其他任务首写时刻 02:54:33；二进制符号表实核包含旧名 `sh_atom_of_term`，因此未受其改名面影响。

### 2.2 GREEN（引擎补丁加 11 例；`selftest-types` 415/415）

三个用例重钉：`t3.witness_reverse_over_claim` 为 `ty_sub(t3_b, t3_w)`，`t3.witness_equiv_over_claim` 为 `ty_equiv(t3_w, t3_b)`，`t3.product_neg_over_claim` 为 `ty_sub(t3_b, tt_inter(t3_b, tt_not(t3_r)))`。期望值从 0 改为 1，全部通过。

邻域负控 11 例，使用子 runner `ts_t2_neg_run`，不内联 `type_selftest_run`，因为巨型函数内联新用例有 rc=139 前科：

| 序号 | 用例名 | 输入 | 期望 | 角色 |
|---|---|---|---|---|
| ① | `t2.neg_same_identity_not_disjoint` | `ty_sub(sum_11, ¬sum_11)` | 0 | 防止“一律判不交”的过度加强 |
| ② | `t2.neg_var_literal_stays_minus1` | `ty_sub(tt_var(0), ¬sum_11)` | -1 加 uncovered | μ 变元字面走既有域外路径，三态不稀释 |
| ③ | `t2.neg_topk_left_unchanged` | `ty_sub(⊤ₖ(AK_SUM), ¬sum_11)` | 0 | 语义钉子。类顶包含全类值；既有 `neg.supertype*` 走 ¬ 乘 ¬ 分支，不覆盖 `:327` |
| ④ | `t2.neg_topk_right_unchanged` | `ty_sub(sum_11, ¬⊤ₖ(AK_SUM))` | 0 | 反向同上 |
| ⑤ | `t2.neg_cross_enum_same_name` | `ty_sub(sum_21, ¬sum_11)` 两次加同项 | 1 / 1 / 0 | 身份包含枚举名，属于 P3-T1 令牌碰撞类 |
| ⑥ | `t2.neg_token_literal_not_identity_face` | `ty_sub(token_v1, ¬token_v2)` | 0 | AK_UNIT 令牌字面，非 AK_SUM，类域钉子 |
| ⑦ | `t2.neg_named_stays_minus1` | `ty_sub(tt_atom(AK_NAMED,7,-1), ¬sum_11)` | -1 加 uncovered | 政策钉子，P0 Important B，不翻转 |
| ⑧ | `t2.neg_chain_elem_out_of_domain_pin` | 空链项、链含 μ 变元项 | 0 / 0 | P1-a 钉子，域外逐位不变 |
| ⑨ | `t2.neg_param_face_stays_zero` | `[int]` 对 ¬`[int ∪ string]`，双向 | 0 / 0 | D4。参数化面“链不同即不交”不成立，语义上 `[int] ⊆ [int∪string]` |
| ⑩ | `t2.neg_same_enum_diff_variant` | `ty_sub(sum_12b, ¬sum_11)` 两次加同项 | 1 / 1 / 0 | 同枚举异变体，暴露首版实现缺陷的那条，见 §3.3 |
| ⑪ | `t2.neg_ref_mut_marker_face_stays_zero` | `&int` 对 ¬`&mut int`，双向 | 0 / 0 | REF mut 标记位是令牌，类域守卫的稳定自测齿，M2a |

夹具为纯合成，使用 `str_intern`、`sh_name_token`、`tt_atom/tt_cons/tt_nil/tt_union/tt_var/tt_top_k`，不依赖 `g_types`、`sh_term_of_ti`、`init_types()`，与调用序列其他段解耦。

---

## 3. 实现（`src/compiler/type_engine.cr`，增加 59 行；`ak_disjoint` 本体零改动）

### 3.1 新增两个函数（放在 `te_named_pair` 之后、`lit_implies` 之前）

```
fn atom_same_class_disjoint(p: int, q: int) -> int {
    if tt_tag(p) == TT_TOP_K || tt_tag(q) == TT_TOP_K { return 0; }   // ② 类顶
    if tt_a(p) != AK_SUM { return 0; }                                 // ③ 非身份型原子
    cp := tt_c(p);
    cq := tt_c(q);
    if cp < 0 || cq < 0 { return 0; }                                  // ④ 空链（**无牙齿行**，见 §6-①）
    d := sum_chain_same(cp, cq);
    if d == 1 { return 0; }                                            // 同身份 ⇒ 相交
    if d == 0 { return 1; }                                            // 异身份 ⇒ 确定不交
    return 0;                                                          // ⑤ 不可判（P1-a）
}

// AK_SUM 链 = [枚举名令牌, 变体名令牌]（唯一生产构造点 ty_shadow.cr:823）⇒ 逐元素**节点同一性**
fn sum_chain_same(p: int, q: int) -> int {
    if p == q { return 1; }
    if p < 0 || q < 0 { return -1; }
    if tt_tag(p) != TT_CONS || tt_tag(q) != TT_CONS { return -1; }
    e1 := tt_a(p); e2 := tt_a(q);
    if e1 != e2 {
        if te_is_name_token(e1) == 0 || te_is_name_token(e2) == 0 { return -1; }
        return 0;
    }
    return sum_chain_same(tt_b(p), tt_b(q));
}
```

### 3.2 接线（`lit_implies` 的 ¬ 面，`:326` 后、`:327` 前）

```
if pk == AK_NAMED || xk == AK_NAMED { g_ty_uncovered = 1; return -1; }   // 不改（政策面）
if pk == xk { return atom_same_class_disjoint(lp, x); }                  // ← 新增 1 行
if ak_disjoint(pk, xk) == 1 { return 1; }                                // 只服务 pk != xk
```

### 3.3 实际错误和修正（首版到终版，本任务最重要的实现教训）

- 首版用 `te_chain_cmp(0, cp, cq)` 比较链。它是命名面的槽位语义：槽 0 是令牌，槽大于等于 1 是泛型实参类型项。AK_SUM 的槽 1 是变体令牌，因此走 `te_arg_cmp` 到 `ty_equiv`。两个不同令牌在结构比较下判等，因为令牌的 `b` 槽只是标注，引擎只看 `a`/`c`，同形，于是误判为同链。
- 现象很有迷惑性：三个 `t3.*_over_claim` 仍判 0，而当时 9 个负控全部通过，⑤ 跨枚举在槽 0 被令牌规则救回。仅靠既有用例组无法暴露这个缺陷。
- 暴露和修复：补 ⑩“同枚举异变体”后转红；改用 `sum_chain_same`，逐元素令牌同一性，与槽位无关，之后全绿。
- 不变量依据：AK_SUM 的唯一生产构造点是 `ty_shadow.cr:823`，双令牌链；`sh_variant_payload_term` 造的是 `AK_PRODUCT`，不是 AK_SUM，因此“链元素都是令牌”成立。
- 未动 `te_elem_cmp`、`te_named_pair`、`te_chain_cmp`、`ak_disjoint`、`lit_empty_pair`，停条件③满足。

---

## 4. 判据（全套实测；基线为 T1 `e5ce8f9e`）

| 序号 | 判据 | 实测 | 期望 | 判定 |
|---|---|---|---|---|
| 1 | `selftest-types` | 415/415（404 加 11），rc=0 | 至少 404，只增 | 通过 |
| 2 | `check src/compiler` | rc=0 | rc=0 | 通过 |
| 3 | ELF canary | `95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475`（28822B） | 等于 T1 记录 | 通过，IDENTICAL |
| 4 | `.ccr` 两口径四条（冷态） | pa 90823 `fb4a3b59…`，pa_st 90966 `592afa31…`，gt 135341 `ddec1ce6…`，gt_st 135484 `cd2af565…`，差恒 143B | 等于 T1 记录 | 通过 |
| 5 | `--dump-objects` 两口径 | 各 3521 行，`cmp` 等于 T0 记录 | 3521 | 通过 |
| 6 | `.cir` DOT | 165915B `b1bdf480…`，`cmp` 等于 T0 记录 | 相同 | 通过 |
| 7 | 五个 CI job | `check`/`bootstrap-tests`/`suite`/`selfhost-tests`/`full-bootstrap` | 全部 rc=0 | 通过 |
| 8 | 全枚举 | 58/58（51 加 7） | 58/58 | 通过 |
| 9 | 自举链 | `corec2 == corec3` IDENTICAL（`8d979246…`，2871830B）；N06=0；冒烟 42；`--help` rc=1 | 相同 | 通过 |
| 10 | 冻结基线同源对拍 72 档 | `tools/baseline/parity_run.sh`，冻结基线加当前源对比当前二进制加当前源，`diff -rq` 零输出；rc 分布两侧 34 个 0、38 个 1 | 零差异 | 通过 |
| 11 | 对 T0 起点附加归因 | 只有两个自源档（`t2_src_compiler__import.cr` / `t3_src_compiler_ccr_io.cr`）差异，为纯行号偏移 +155，等于本任务净增 166 减 11；去行号后内容 md5 逐字相同 | 可归因 | 通过 |
| 12 | 探针 29 档 | rc 为 17 个 0、12 个 1，等于 T1 基线；逐档日志内容 `cmp` 同 T0 记录，29/29 | 零差异 | 通过 |
| 13 | `test_backend_bootstrap` | 枚举内 rc=0；workspace 构建日志 `[GUARD] … error[ = 0, undefined = 0` | rc=0 且 error[=0 | 通过 |

附注：T1 的 `probes_run.sh` 与 T0 的 `/tmp/p5t4/run_probes.sh` 输出文件名不同，分别是 `tests_probes_*` 和 `_tmp_p5t*_probes_*`。因此“探针零差异”是按 basename 映射后逐档内容 `cmp`，29/29 相同，不是目录级 `diff -rq`。

---

## 5. 突变控制（判据为 M1、M2a、M2c′、M3；每个变体执行改、构建、selftest、回滚、源 sha 校验）

| 编号 | 精确操作 | 实测 | 判定 |
|---|---|---|---|
| M1 撤销加强 | 删除 `if pk == xk { return atom_same_class_disjoint(lp, x); }` | 5 个 FAIL：三个 `t3.*_over_claim` 加 ⑤ 加 ⑩，410/415 | 稳定自测齿 |
| M2a 类域守卫去掉 | 删除 `if tt_a(p) != AK_SUM { return 0; }` | ⑪ 转红，`&int` 对 `&mut int` 误判 1，假不交；414/415 | 稳定自测齿。需要 ⑪，序列面 ⑨ 走 -1 分支，不触发该守卫 |
| M2c′ P1-a 出口改判 | `return 0;  // ⑤ 不可判` 改为 `return 1;` | ⑧ 转红，空链或链元素域外被误判不交；414/415 | 稳定自测齿 |
| M3 次序对照（最小性） | 新行移到 `ak_disjoint` 之后 | 415/415 零差异 | 两序等价，改动最小 |
| M3b 附加证据，非判据 | `if pk == xk { return … }` 改为无条件 `return …` | 既有 `exhaust.witness_bool` 转红，说明 `pk == xk` 条件必要 | 记录 |
| M2b 不作判据 | 删除 `⊤ₖ` 守卫 | 解释不稳定。`tt_top_k` 的 `c` 槽为 0（`type_terms.cr:229`）而不是 -1，空链守卫拦不住，后退到“term 0 当链”的解释，结果不定 | 仅探索记录。③④ 的真实角色是语义钉子，防止将来扩域或重排把 `⊤ₖ` 误当身份原子 |
| — | 回滚校验 | 每个变体回滚后源 sha 逐条复原；回滚后复跑 415/415 | 通过 |

---

## 6. 偏差和需要说明的事项

1. 无自测齿行，如实登记。`atom_same_class_disjoint` 调用侧的空链守卫 `if cp < 0 || cq < 0 { return 0; }` 单独删除零差异，与 `sum_chain_same` 内层 `p < 0 || q < 0` 返回 -1 行为等价。保留它作为显式域注释，便于阅读，不假称它是突变自测齿。⑧ 的自测齿在 M2c′，即不可判出口。
2. `tt_display_at` 参数链分支渲染退化，是预存缺陷，未修，建议入 TODO。带链原子一律渲染为 `>`，裸原子正常。实测量：`tt_display(tt_atom(AK_SUM,-1,-1))` 为 `"sum"`，`tok` 为 `"unit"`，而 `sum1` 为 `">"`，`seq1` 为 `">"`，`ptr` 为 `">"`，且 `str_len = 1`。影响面是 ICE04 和泛型约束反例诊断中参数化类型的显示退化。本批不改，因为 `ty_shadow.cr` 不是本任务面，且诊断文本变化会动 72 档对拍面。本报告的“两侧项身份”因此改用令牌名，通过 `istr_get` 实取。
3. 正乘正面候选，`lit_empty_pair:118`，正乘正同类异身份时判不交。语义上同样成立，但会经 `ty_inhabited`、`tt_witness`、`ty_exhaustive` 到达 match 穷尽性 TM03 生产面。本批不实施，协调者裁定，登记为单列候选。
4. 命名链半项：`AK_NAMED` 维持 -1，P0 终审 Important B 在册政策。附录 E-10 的“命名链返回 1”不作为缺陷收口实施，属于政策变更，待裁登记另起。⑦ 用例把该政策钉在 ¬ 面。
5. 用例组自测齿原本不足：首版实现缺陷在既有 9 个负控下全绿，靠新增 ⑩ 才暴露。这说明“负控通过”不等于“加强正确”。本批因此把负控从计划下限 4 提到 11，包含两条主判据同族的正例。
6. 执行面隔离：主树当时包含其他任务在途改动，树不可编译，报 `Undefined name: sh_atom_of_term` 9 次。本任务全程在仓库外 workspace 执行，用 `jj workspace add -r e5ce8f9e` 创建。主树零改动、零提交、零还原。已由协调者合流为 `9cfa6246`。
7. 未测和未做：`COREC_WARM_SELF=1` 自源暖态两例，与判定面无关，T1/R2 已由其他任务覆盖；`.M2..M4` 类变异面属于 T3b 残留，不是本批。
8. `/tmp` 共享名：CI `full-bootstrap` job 内部固定写 `/tmp/corec2|corec3|corearch`（`src/ci/run.sh:119-123`）。跑前用 `ps` 实查没有并发构建进程后才执行，本批只有本任务一方在场。

---

## 7. 证据路径（`/tmp/p6t2/**`；workspace 目录仍在磁盘，`jj workspace` 注册已由协调者 forget）

| 用途 | 路径 |
|---|---|
| 执行 workspace，即提交 `911c692d` 所在 | `/tmp/p6t2/wt`，源为 `e5ce8f9e` 加本任务两个文件加 `run.sh` 加计划勘误 |
| 中间验算 workspace，含 T3 七处改名的撤销版 | 同上。用 `jj workspace add /tmp/p6t2/wt -r e5ce8f9e` 后拷入两个文件，再用 `sed` 还原 `sh_atom_of_term`，校验 `grep -c tt_atom_of_term = 0` |
| 提交信息全文 | `/tmp/p6t2/t2_commit_msg.txt` |
| RED 证据 | `red_build{,2,3,4}.log`、`red_selftest{,2,3,4}.log`、`red_final.log`，包含身份、单点和 3 个 FAIL |
| GREEN 证据 | `iso_build4.log`、`iso_selftest4.log`（415/415）、`iso_build{,1,2,3}.log`/`iso_selftest{,1,2,3}.log`，415 前的过程档，含首版缺陷暴露记录 |
| 全套判据 | `iso_judge.sh` 到 `iso_judge.out`（首轮）、`iso_judge_final.out`（最终态）；`iso/{check_self,canary,j3*,j4}.log`、`iso/{pa,pa.ccr,pa_st.ccr,gt.ccr,gt_st.ccr}`、`iso/{gt_do.txt,gt_st_do.txt,gt.cir}`、`iso/parity_frozen*/`、`iso/parity_post*/`、`iso/probes/`、`iso/ci_*.log`、`iso/enum_list.txt` 加 `iso/enum_*.log`（58 档） |
| 突变控制 | `iso_mut.sh` 到 `iso_mut.out`、`mut/{M0,M1,M2a,M2c,M2p,M3,M3b}_*.log`、`mut/engine.pristine` 回滚源。M2c′ 日志名为 `M2cp_*`；M2c 精确版为 `M2c2_*` |
| 草案，前置侦查产出，供追溯 | `domain_proof_draft.md`、`t2_patch_draft.diff`（v3）、`t2_cases_draft.md`、`plan_task2_erratum_draft.md`、`EXEC_NOTES.md` |
| 上游基线，继承 | `/tmp/p6t1/base/{corec,corearch,corelsp}`，sha 与允许清单逐条相同，已实核；`/tmp/p6t0/**`，T0 判据记录、探针和语料基线、冻结基线 `/tmp/p6t0/base` |
