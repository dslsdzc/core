# R2 P2a Task 4 报告：收尾（回归 + 零变化复验 + 自举 + 收紧清单 + 文档/登记）

状态：完成（判据全部通过；收紧清单为空；2 条 pre-existing 缺陷登记 = TODO #25；1 条缓存态登记 = TODO #5 同族）
范围：Step 1 全量回归（23 套件）· Step 2 零变化复验（ELF 两态 + `.ccr` 4 语料）· Step 3 自举链 · Step 4 收紧清单 · Step 5 文档（spec 第 9 节 / TODO / findings）· Step 5b `.ccr`↔缓存态登记 · Step 5c Task 2 评审遗留 M2 用例 + 自指语料 `.ccr` 直接采样 · 评审清单 1-10 项逐条落实（落点见 第 8 节）· Step 6 提交。

产物：`src/compiler/type_selftest.cr`（+23 行，M2 用例 5 条）· `TODO.md`（F1/F2 划销 + #24 P2a 实施 + #25 F5/opt.cr 登记 + #5 同族第二实例）· `docs/superpowers/specs/2026-09-10-type-interface-unification-design.md`（第 9 节 P2 行）· `docs/superpowers/implementation/2026-09-10-type-shadow-findings.md`（第 0 节 注记 + 第 11 节 P2a 后复跑）。报告侧（不在 VCS）：本文件 + Task 3 报告数字重算/行号更正 + Task 2 报告 C-5① 收口注。

判据一行结论：23 套件 rc=0（含 `selftest-types` 93/93，从 88 增加 5 个 M2 用例）· ELF 逐字节 `95084e7b…d475`（开/关两态均 IDENTICAL）· `.ccr` 4/4 IDENTICAL（3 小语料 + 自指语料，冷缓存；自指为「冻结源 × pre/post 二进制」隔离法）· 自举 `corec2`/`corec3` CMP_IDENTICAL + N06=0/0 + 冒烟 rc=42 · 收紧清单 空。

---

## 1. 判据总表

| # | 判据 | 结果 | 证据 |
|---|------|------|------|
| 1 | 全量回归 23 套件 | rc=0 ×23（逐套件末行见 第 2 节） | 第 2 节 |
| 2 | ELF 逐字节（关态 / 开态） | IDENTICAL ×2（sha256 `95084e7b…d475` = R1 基线） | 第 3.1 节 |
| 3 | `check` stdout 两态 | CHECK-STDOUT-IDENTICAL（过滤 `^\[type-shadow` 两行后逐字节同） | 第 3.2 节 |
| 4 | `.ccr` 冷缓存（3 小语料） | 3/3 IDENTICAL（pre/post 二进制同源输入） | 第 3.3 节 |
| 5 | `.ccr` 冷缓存（自指语料，C-5① 直接采样） | IDENTICAL `e94e488f10c4…`（冻结源隔离法） | 第 3.4 节 |
| 6 | 自举链 | CMP_IDENTICAL · N06 0/0 · `error[` 2/2（既有 TF01 误报，行号 8595/8710）· 冒烟 rc=42 | 第 4 节 |
| 7 | 收紧清单（旧接受变为新拒绝） | 空（`old_looser=0` 全语料 26989 判定 + 拒绝集合恒等论证） | 第 5 节 |
| 8 | M2 用例（REF/SLICE 下钻位 + 站点 0/−1 分派） | 5 例全 PASS（93/93）；两个负控突变各自命中 | 第 6 节 |
| 9 | `.ccr` ↔ cir 缓存态登记 | 实测复现（冷 `53ebcf12…` 到热 `5054e26d…`），归入 TODO #5 同族 | 第 7 节 |
| 10 | 评审清单 1-7 项（+8-10）落点 | 逐条落实（见 第 8 节 落点表） | 第 8 节 |
| 11 | 文档落点 | spec 第 9 节 P2 行 已完成（a）+ P2b 待办 · TODO F1/F2 划销 + #24/#25 · findings 第 11 节 | 第 9 节 |

---

## 2. Step 1：全量回归（23 套件；cwd = 仓库根，全部 `nice -n 19`）

套件集 = P2a 各任务实际跑过的集合（Task 3 报告 第 8.4 节 同集）：17 selfhost + 5 bootstrap + `selftest-types`。

| 套件 | rc | 末行 |
|---|---|---|
| `selftest_types` | 0 | `93/93 type-engine cases passed` |
| `test_type_engine` | 0 | `PASS test_selftest_types_all_pass` |
| `test_compile` | 0 | `All selfhost compile tests passed.` |
| `test_backend_bootstrap` | 0 | `[PASS] stage0 and stage1 O2 smoke ELFs return 7` |
| `test_hit_table` | 0 | `24/24 passed` |
| `test_ccr_v7` | 0 | `24/24 passed` |
| `test_live_ranges` | 0 | `13/13 passed` |
| `test_slice_bounds` | 0 | `7/7 passed` |
| `test_global_init` | 0 | `15/15 global-init cases passed (dual path)` |
| `test_lexer_parity` | 0 | `PASS test_legal_forms_unchanged` |
| `test_impl` | 0 | `7/7 passed` |
| `test_borrow` | 0 | `7/7 passed` |
| `test_pointer_safety` | 0 | `PASS test_dynamic_multi_target_pointer_is_rejected` |
| `test_region_cfg` | 0 | `22/22 passed` |
| `test_dex_type` | 0 | `5/5 passed` |
| `test_apx_tag` | 0 | `2/2 passed` |
| `test_directory_build` | 0 | `[PASS] a missing directory cannot fall back to the working directory` |
| `test_named_dedup` | 0 | `PASS test_named_dedup_pipeline_assertion` |
| `bootstrap_test_pipeline` | 0 | `29/29 passed` |
| `bootstrap_test_borrow` | 0 | `4/4 passed` |
| `bootstrap_test_generics` | 0 | `3/3 passed` |
| `bootstrap_test_modules` | 0 | `[PASS] import module : alias resolves qualified function calls` |
| `bootstrap_test_apx_tag` | 0 | `5/5 passed` |

原始日志：`/tmp/p2a_t4/reg/*.log` + `summary.txt`；脚本 `/tmp/p2a_t4/run_reg.sh`。
唯一与 Task 3 的差异 = `selftest-types` 88 增加到 93（本任务 M2 新增 5 例，见 第 6 节）；其余 22 套件末行逐字同。

---

## 3. Step 2：零变化复验

### 3.1 ELF 逐字节（冷缓存；cwd = 仓库根）

```
$ nice -n 19 ./build/corec clean-cache
$ nice -n 19 ./build/corec build tests/suite/ptr_arith.cr --static -o /tmp/p2a_t4_bin_off
OFF-IDENTICAL
$ nice -n 19 ./build/corec clean-cache
$ nice -n 19 ./build/corec build tests/suite/ptr_arith.cr --static --type-shadow -o /tmp/p2a_t4_bin_on
ON-IDENTICAL
$ sha256sum /tmp/r1t4_base_bin /tmp/p2a_t4_bin_off /tmp/p2a_t4_bin_on
95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475  /tmp/r1t4_base_bin
95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475  /tmp/p2a_t4_bin_off
95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475  /tmp/p2a_t4_bin_on
```
（三份同 sha256 因此 与 R1 基线逐字节同 + 影子开关零产物影响。）

### 3.2 `check` 路径两态

```
$ ./build/corec check tests/suite/ptr_arith.cr                # rc=1（既有 error[B04]）
$ ./build/corec check tests/suite/ptr_arith.cr --type-shadow  # rc=1
$ grep -v '^\[type-shadow' <on 输出> | cmp - <off 输出>，得到 CHECK-STDOUT-IDENTICAL
[type-shadow] decisions=74 agree=74 old_stricter=0 old_looser=0 unknown=0 unknown_bridge=0 unknown_engine=0 unknown_engine_uncovered=0 unknown_engine_budget=0 replace_bridge=0 replace_unknown=0
[type-shadow-sites] hotpatch-ret=0 generic-arg=0 generic-apply-base=0 unify-fallback=0 fn-body-ret=16 assign-binary=0 if-branch=7 assign-node=51
（sum(site)=74=decisions 通过；与 Task 3 / P1 基线逐字段同）
```

### 3.3 `.ccr` 冷缓存（3 小语料；每语料前 `clean-cache`）

方法：pre 二进制 = Task 3 终态（`/tmp/p2a_t4_pre_corec`，身份核验见 第 3.4 节 脚注），post 二进制 = 本任务终态（`/tmp/p2a_t4_post_corec`，sha256 `4f38a698cf1a…`）。两侧以同一份（终态）源码为输入。

| 语料 | pre sha256（前 20） | post sha256（前 20） | 判定 |
|---|---|---|---|
| `tests/suite/ptr_arith.cr` | `bb9cbdb87f4f8342f604…` | 同左 | IDENTICAL |
| `tests/suite/at_test_struct.cr` | `53ebcf122deb6997a5ba…` | 同左 | IDENTICAL |
| `tests/suite/generics_test.cr` | `2132d565778c866b8717…` | 同左 | IDENTICAL |

（三值亦与 Task 3 报告 第 8.2 节 记录逐字同 因此 本批改动零 `.ccr` 影响。）

### 3.4 `.ccr` 自指语料（C-5① 直接采样收口）

为何不能直接用真实树：本任务对 `type_selftest.cr`（`main.cr` 编译单元成员）有改动 因此 真实树的「源内容」已变，pre/post 无法隔离编译器影响。
隔离法：以 rsync 冻结 Task 3 源树（`/tmp/p2a_t4/selfsrc_t3/`，`jj` 只读态 = 工作副本改动前快照），两侧同源编译 `src/compiler/main.cr`：

```
pre  × 冻结 Task 3 源 = e94e488f10c4a462fa4e27399d6e52e76b5d47b76085d852e13fbbd407dc74d
post × 冻结 Task 3 源 = e94e488f10c4a462fa4e27399d6e52e76b5d47b76085d852e13fbbd407dc74d   （IDENTICAL）
（both: 719 funcs / 101810 instrs）
```
因此 编译器改动对自指语料 `.ccr` 零影响。
另报「源内容变化」分量（隔离，非缺陷）：post × 真实 Task 4 源 = `42b6af4544d9c285c5fb…`（719 funcs / 101978 instrs，+168），差异成因 = 新增 5 条用例及其断言的代码进入编译单元，属预期源码变化（Task 3 第 8.2 节 同款归因先例）。
pre 身份核验（脚注）：`/tmp/p2a_t4_pre_corec` 对同一语料复算出 `bb9cbdb87f4f…/53ebcf122deb…/2132d565778c…/e94e488f10c4…` 四值，与 Task 3 报告 第 8.2 节 记录逐字相同 因此 确为 Task 3 终态二进制（非陈旧构建）。

---

## 4. Step 3：自举链

```
$ nice -n 19 ./build/corec build src/compiler/main.cr -o /tmp/p2a_t4_corec2 --static -O 0     # rc=0
$ nice -n 19 /tmp/p2a_t4_corec2 build src/compiler/main.cr -o /tmp/p2a_t4_corec3 --static -O 0 # rc=0
$ cmp /tmp/p2a_t4_corec2 /tmp/p2a_t4_corec3 && echo CMP_IDENTICAL
CMP_IDENTICAL        （sha256 920c8af47714061cc522… 两侧同）
N06 计数：0 / 0
error[ 计数：2 / 2   （两阶段逐字同）；均为既有 TF01 误报：lits_copy(8595) / ty_memo_slot_no_grow(8710)
$ nice -n 19 ./build/corec run 'fn main()->int{return 42;}'
smoke_rc=42
```

行号双路实测（评审 Minor 收口）：① 终态二进制 × Task 4 源得到 8595/8710；② Task 3 终态二进制 × 冻结 Task 3 源得到 8595/8710（`/tmp/p2a_t4/logs/frozen_t3_build.log`）。因此 Task 3 报告初稿的 8593/8708 = 陈旧日志值（产物生成于末次注释编辑之前），非源差异；`error[` 为 2/2，且 `cmp IDENTICAL` 结论不变。Task 3 报告已更正并注明来源。

---

## 5. Step 4：收紧清单（空）

口径：本批「旧接受变为新拒绝」逐条记录（brief 预期为空）。

| 证据面 | 结果 |
|---|---|
| 对拍语料 `old_looser` | 0（71 文件 / 26989 判定；final 产物独立重算，见 Task 3 报告 第 5.1 节 更正注） |
| 对拍语料 `old_stricter` | 0（引擎未比 legacy 更宽，亦无反向变化） |
| 判定点拒绝集合恒等（结构性论证） | `type_equal_old ⟺ type_equal_new ∧ constraint`（Task 2 第 2.3 节）因此 站点否决集合恒等、码不变、仅成因分措辞 |
| 行为面 | 23 套件 rc=0（含 `test_lexer_parity` / `test_dex_type` 的 TF01 码级门） |
| 自举面 | `corec2/corec3` cmp IDENTICAL + 编译器自身语料零新增诊断（`error[` 2/2 = 既有） |

因此 本批收紧面为空，如实记录（P2a 用户裁决即「不留不报错地缺口、也不收紧」）。残留风险不在收紧面而在覆盖面：站点 1/2/4/6 零命中（见 Task 3 第 5.3 节 / findings 第 11 节），「空清单」不得读作「这些面无差异」。

---

## 6. Step 5c M2：Task 2 评审遗留用例（REF/SLICE 下钻位 + 站点 0/−1 分派）

落点：`src/compiler/type_selftest.cr`（+23 行，5 条用例，插在 `f2.*` 组尾）。

| 用例 | 断言 | 意图 |
|---|---|---|
| `f2.ref_elem_reject` | `&[int;3]` 自反得到 1，且 `&[int;4]` 对 `&[int;3]` 得到 0 | 约束的 REF 递归位（下钻 6 位中此前缺该位；`extra`=mut 归身份、约束不重复） |
| `f2.slice_elem_reject` | `[[int;3]]` 自反得到 1，且 `[[int;4]]` 对 `[[int;3]]` 得到 0 | 约束的 SLICE 递归位（同上，此前缺） |
| `t3.strict_dispatch_ok` | `type_compat_strict([int;3],[int;3]另一行)` = 1 | 站点兼容态 |
| `t3.strict_dispatch_identity` | `type_compat_strict([int;3], int)` = 0 | 身份不匹配，使用原措辞（异结构面） |
| `t3.strict_dispatch_len` | `type_compat_strict([int;4],[int;3])` = -1 | 长度违反，使用专属措辞；且它同时证明 `type_equal` 已放行（引擎身份确实 N-free） |

判据：`selftest-types` 得到 93/93 PASS，rc=0（88 + 5）。

负控（实证断言非没有实际作用；仓库外副本 `/tmp/p2a_t4/negctl{,2}`，均 `nice -n 19` 重建）：

| 突变 | 结果 |
|---|---|
| 摘除 `array_len_constraint_ok` 的 `\|\| ka == TYP_REF \|\| ka == TYP_SLICE` | `FAIL f2.ref_elem_reject` + `FAIL f2.slice_elem_reject`，得到 91/93, rc=1（其余全 PASS 因此 突变定位精确、两例确有效） |
| `type_compat_strict` 把 `return -1` 并成 `return 0` | `FAIL t3.strict_dispatch_len: got 0 want -1`，得到 92/93, rc=1（因此 0/−1 的区分由用例固定；这正是「站点接线」面） |

---

## 7. Step 5b：`.ccr` 输出与 cir 缓存态相关（登记，实测复现）

```
$ nice -n 19 ./build/corec clean-cache
$ ./build/corec ccr tests/suite/at_test_struct.cr -o w1，得到 sha256 53ebcf122deb…（= 冷缓存值）
$ ./build/corec ccr tests/suite/at_test_struct.cr -o w2，得到 sha256 5054e26dcebc…   （二次运行，缓存已热）
$ ./build/corec ccr tests/suite/at_test_struct.cr -o w3，得到 sha256 5054e26dcebc…   （三次起稳定）
```
因此 同一二进制二次运行产出不同 `.ccr` 字节（评审 `53ebcf12…`到`5054e26d…` 结论独立复现）；冷缓存下 pre/post 行为一致。
落点：`TODO.md` #5（cir cache 跨编译器重建不失效）同族第二实例，并明写：判据比较 `.ccr` 前必须 `clean-cache`（本任务四处 `.ccr` 判据均先 `clean-cache`，见 第 3.3 节/第 3.4 节）。

---

## 8. 评审给定清单（1-10 项）逐条落点

| # | 项 | 落点 |
|---|---|---|
| 1 | 报告数字重算（final 产物） | Task 3 报告：头部注 + 第 1 节行 + 第 5.1 节表 + 第 5.3 节 直方图/脚注全部改为 26989/26989 · 4949/1919/20119（T2 7998 / T3 14055）；并新增「校验来源」：`/tmp/r2p2t3_run.sh` 不做 `sum(site)==decisions` 校验（只打印），该性质由 Task 3 评审 + Task 4 独立重算（67 行 0 违例）复核 因此 第 5.3 节 脚注已更正措辞 |
| 2 | F5 登记（含新证据） | `TODO.md` #25（新条目）：root cause `parser.cr:487`（对照 `parser.cr:459` struct wrapper）+ 3 类影响（假拒 `(1,a)` 对 `(1,[1,2,3])` 报 TA01 / soundness 漏放 `(1,[1,2,3])` vs `(1,h())` 不报错地接受 / N 面漏检）+ 4 消费点（`checker.cr:2639`·`ir_gen.cr:2207`·`monomorph.cr:296`·`opt.cr:177`）+ 判据建议（3 探针 + selftest + 4 消费点 + ELF/`.ccr` 逐字节 + 全回归）。Task 3 报告 第 9 节 F5 段同步扩写（含 `ir_gen.cr:2199` 改为 `2207` 修正） |
| 3 | `opt.cr:177` 恒没有实际作用 | 并入 #25 同一条目：读 `ast_b`/`ast_c` 而约定 `a`/`b` 因此 元素优化恒没有实际作用（无正确性影响） |
| 4 | 措辞更正（0 字节空文件） | Task 3 报告 第 5.1 节 注 + 第 1 节表：`test_control_flow.cr`/`test_generics.cr` = 0 字节空文件（`error: cannot read` rc=1），非「2 解析失败」；t1 有效语料 = 29（31 − 2）。与 TODO #22 既有勘误一致 |
| 5 | 第 8.3 节 自举行号 | Task 3 报告 第 8.3 节：8593/8708 改为 8595/8710 + 追加更正注（双路实测：终态×(T4 源) 与 T3 二进制×(冻结 T3 源) 同值，因此是陈旧日志值） |
| 6 | M2 用例 | 本任务实现：第 6 节（5 例 + 2 个负控突变） |
| 7 | Step 5b 登记 | 本任务实现：第 7 节（TODO #5 同族第二实例 + 「判据前必须 clean-cache」） |
| 8 | spec 第 9 节 P2 行 / TODO / findings | 第 9 节（文档落点表） |
| 9 | 收紧清单 | 第 5 节：空（含「不得读作这些面无差异」的覆盖面限定） |
| 10 | Step 1-3 判据 | 第 2 节 / 第 3 节 / 第 4 节 全跑（23 套件 + ELF 两态 + `.ccr` 4 语料含自指 + 自举 cmp/N06/冒烟 42） |

---

## 9. Step 5：文档落点

| 文档 | 改动 |
|---|---|
| `docs/superpowers/specs/2026-09-10-type-interface-unification-design.md` | 第 9 节 P2 行：标 （a）部分 已完成 已实施（= P2a），F1 去重 / F2 常量档长度约束 / 判定替换（unknown 回落计数）/ 对拍复跑 26989/26989 + 站点覆盖 / 收紧清单空 / 行为面判据 / 落点与提交链 / 未覆盖面（站点 1/2/4/6 零命中、语料 `replace_unknown=0`）/ P5 继承项（legacy 删除、unknown 清零前提 = 引擎命名展开、站点 6 去留）；标 （b）部分（P2b，另立计划），`infer_expr` 公理区改为 `iface_ops` 查表接线 + `res_type_node` 两表合一 |
| `TODO.md` | ① #18（F1）/ #19（F2）划销（`…` + 已修说明 + 落点 + 提交 + 判据）② #24 新增「R2 P2a 实施」（落点 / 行为面兑现 / 未覆盖面 / P5 继承项：`type_equal_legacy` 删除归 P5 · unknown 清零前提 = 引擎命名展开 · 站点 6 去留；P2b 待办）③ #25 新增 F5 + `opt.cr:177` ④ #5 追加同族第二实例（`.ccr` ↔ 缓存态） |
| `docs/superpowers/implementation/2026-09-10-type-shadow-findings.md` | 第 0 节 头部完整流程注记（F1/F2 已实施；第 1 节-第 10 节 = P1 时点记录）+ 新增 第 11 节「P2a 后复跑」（通道差异 = 对照物切 legacy / 主计数对照表 26,704到26,989 / 站点覆盖同报 + 逐档直方图 / N 面口径：对拍不得充当 N 面证据、探针承担 / 残留与交 P5） |
| 报告侧（不在 VCS） | `r2p2-task-3-report.md`（第 1 节/第 5.1 节/第 5.3 节/第 8.3 节/第 9 节 数字与措辞更正 + 校验来源）、`r2p2-task-2-report.md`（C-5① 直接采样收口注） |

---

## 10. 提交

jj change `wrsxouwvosytrukvlsmxuprmkmkoqpzs`（短 `wrsxouwv`）/ commit `428a335979a6dc1810869be5d87e4ea3da602719`（短 `428a3359`），路径限定 4 文件 `+77 / -4`：
`src/compiler/type_selftest.cr`（+23）· `TODO.md`（+22/-2）· `docs/superpowers/specs/2026-09-10-type-interface-unification-design.md`（+1/-1）· `docs/superpowers/implementation/2026-09-10-type-shadow-findings.md`（+31/-1）。
提交信息：`test: R2 P2a Task 4 收尾，M2 用例（REF/SLICE 下钻位 + 站点 0/-1 措辞分派，双负控突变有效）+ 自指 .ccr 冷缓存直接采样 + F1/F2 划销与 P2a 实施登记（含 F5/opt.cr:177 + .ccr 缓存态同族）`。
提交后 `jj status` 为空；本报告不在 VCS（`docs/archive/sdd/.gitignore` = `*`）。

原始材料索引：回归 `/tmp/p2a_t4/reg/`；零变化 `/tmp/p2a_t4/logs/elf.txt`·`check_two_state.txt`·`cache_dependence.txt`；`.ccr` `/tmp/p2a_t4/ccr_*`；自举 `/tmp/p2a_t4/logs/corec{2,3}_build.log`；冻结源 `/tmp/p2a_t4/selfsrc_t3/`；负控 `/tmp/p2a_t4/negctl{,2}/` + `logs/negctl*_selftest.log`；pre/post 二进制 `/tmp/p2a_t4_pre_corec`·`/tmp/p2a_t4_post_corec`。

---

## 11. 自检与 concerns

占位符扫描：无 TBD / 无「稍后填」；提交哈希在 第 10 节 以 jj change 记录（提交时点自指问题见下 C-4）。
命名一致性：`type_compat_strict` / `array_len_constraint_ok` / `f2.ref_elem_reject` / `t3.strict_dispatch_*` 全仓一致。

- C-1（.ccr 判据的口径，已按硬约束执行）：四处 `.ccr` 判据一律 `clean-cache` 前置（第 7 节 实测证明不这样做的结论不可比）。自指语料额外采用「冻结源 × pre/post」隔离法，该法不能替代「真实树」判据，后者受源内容变化干扰（本任务如实分列两分量，第 3.4 节）。
- C-2（M2 用例的覆盖面边界）：新例覆盖 `array_len_constraint_ok` 的 REF/SLICE 两位与站点三态分派；未覆盖「REF 的 `extra`（mut）由身份判定而非约束负责」这一反向不对称（该行为在站点层不可观测，不同 mut 会先被 `type_equal` 否决，返回 0）。已在用例注释注明，不新增断言（避免把身份面行为写进约束面用例）。
- C-3（Task 3 报告重算的性质）：本次修正的是报告数字（final 产物重算），未重跑对拍语料，语料运行环境（P2a 终态二进制）未变，且 第 3 节的 ELF/`.ccr` 判据独立复核了产物面；`sum(site)==decisions` 由 Task 4 独立重算 67 行（0 违例）复核。原脚本不做校验这点已写进报告（避免后来者误引）。
- C-4（提交哈希的自指限制）：TODO #24 的提交链只列到 Task 3（`10718ba8`），Task 4 自身哈希不能写进自身提交（先例：P1 条目录到 Task 3）。Task 4 哈希 = jj change `wrsxouwvosytrukvlsmxuprmkmkoqpzs` / commit `428a335979a6dc1810869be5d87e4ea3da602719`（见 第 10 节；仅本报告与 `jj log` 可见）。提交后做了一次 `jj squash`（同一提交内改一行 TODO 措辞「三个消费者」改为「4 个消费点」），commit hash 由 `cb72dae8` 变为 `428a3359`（change id 不变），文件内容面与全部判据不受影响（纯文档行，改后 `jj status` 空、diff stat 不变）。
- C-5（未做面，如实登记）：① 全语料诊断文本 pre/post 逐条 diff 仍未做（Task 2/3 同款替代证据：逐文件 rc + 自举 `error[` 2/2 逐字同 + 码级 TF01 门）；② `opt.cr:177` 的「恒没有实际作用」为读码判定（未做运行时插桩实测，该分支没有实际作用即无副作用，插桩需另建调试件，登记于 TODO #25 由后续任务实证）；③ 性能未基准（Task 3 C-2 残留项，语料规模无感）。
