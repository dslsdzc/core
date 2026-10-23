# R2 P1 Task 4 收尾报告（回归 + 两态零变化 + 自举 + 文档/台账 + 评审遗留清零）

- 日期：2026-09-11
- brief：`docs/archive/sdd/task-4-brief.md`
- 前置：P1 Task 1（`e4c293b2`）/ Task 2（`844cec6c` + `514956a1`）/ Task 3（`75c20297`）均已评审通过
- 状态：完成（判据全过；无跳过项；边界与留白 5 条见 第 8 节）
- 报告：`docs/archive/sdd/r2p1-task-4-report.md`（本文件，未被 VCS 跟踪，`sdd/.gitignore` = `*`）

判据一行结论：全回归 14 套件 rc=0（含 `selftest-types` 72/72，71 + 本任务新增第二次重建守门用例）· 两态产物 OFF-IDENTICAL / ON-IDENTICAL（build 与 check 双路径）· 自举 CMP_IDENTICAL + N06=0 + 冒烟 rc=42 · Task 3 评审 4 Minor + 5 条登记 + harness 缺口全部落点。

---

## 1. Step 1：全量回归（13 项清单 + `selftest-types`）

清单来源 = R2 P0 计划 Task 5 Step 1（12 个 python 套件）；P1 计划 Task 4 记「13 项 + selftest-types」到 本报告按 12 套件 + `selftest-types`（第 13 项） 执行，并额外加固 2 套（`test_impl.py` / `tests/selfhost/test_borrow.py`，取 Task 3 报告的加固面），共 14 套。

前置：`nice -n 19 ./build/corec clean-cache` 输出 `cleaned .core/cache/cir/`；cwd = 仓库根；全部 rc=0（零 FAIL）。

| # | 套件 | rc | 末行（原始） |
|---|---|---|---|
| 0 | `./build/corec selftest-types` | 0 | `72/72 type-engine cases passed` |
| 1 | `tests/selfhost/test_type_engine.py` | 0 | `PASS test_selftest_types_all_pass` |
| 2 | `tests/selfhost/test_compile.py` | 0 | `All selfhost compile tests passed.` |
| 3 | `tests/selfhost/test_backend_bootstrap.py` | 0 | `[PASS] stage0 and stage1 O2 smoke ELFs return 7` |
| 4 | `tests/selfhost/test_hit_table.py` | 0 | `24/24 passed` |
| 5 | `tests/selfhost/test_ccr_v7.py` | 0 | `24/24 passed` |
| 6 | `tests/selfhost/test_live_ranges.py` | 0 | `13/13 passed` |
| 7 | `tests/selfhost/test_slice_bounds.py` | 0 | `7/7 passed` |
| 8 | `tests/selfhost/test_global_init.py` | 0 | `15/15 global-init cases passed (dual path)` |
| 9 | `tests/selfhost/test_lexer_parity.py` | 0 | `PASS test_legal_forms_unchanged` |
| 10 | `tests/bootstrap/test_pipeline.py` | 0 | `29/29 passed` |
| 11 | `tests/bootstrap/test_borrow.py` | 0 | `4/4 passed` |
| 12 | `tests/bootstrap/test_generics.py` | 0 | `3/3 passed` |
| + | `tests/selfhost/test_impl.py`（加固） | 0 | `7/7 passed` |
| + | `tests/selfhost/test_borrow.py`（加固） | 0 | `7/7 passed` |

原始日志：`/tmp/r2p1t4_reg/*.log`、汇总 `/tmp/r2p1t4_reg/summary.txt`（每套 `=== <路径> ===` / `rc=` / 末行）。

---

## 2. Step 2：两态零变化复验（Task 2 Step 5 命令；build 与 check 双路径）

### 2.1 build 路径（原始输出）

```
$ nice -n 19 ./build/corec clean-cache
cleaned .core/cache/cir/
$ nice -n 19 ./build/corec build tests/suite/ptr_arith.cr --static -o /tmp/p1t4_off
 -> /tmp/p1t4_off
$ nice -n 19 ./build/corec clean-cache
cleaned .core/cache/cir/
$ nice -n 19 ./build/corec build tests/suite/ptr_arith.cr --static --type-shadow -o /tmp/p1t4_on
[type-shadow] decisions=74 agree=74 old_stricter=0 old_looser=0 unknown=0 unknown_bridge=0 unknown_engine=0 unknown_engine_uncovered=0 unknown_engine_budget=0
[type-shadow-sites] hotpatch-ret=0 generic-arg=0 generic-apply-base=0 unify-fallback=0 fn-body-ret=16 assign-binary=0 if-branch=7 assign-node=51
 -> /tmp/p1t4_on
$ cmp /tmp/r1t4_base_bin /tmp/p1t4_off && echo OFF-IDENTICAL
OFF-IDENTICAL
$ cmp /tmp/r1t4_base_bin /tmp/p1t4_on && echo ON-IDENTICAL
ON-IDENTICAL
$ sha256sum /tmp/r1t4_base_bin /tmp/p1t4_off /tmp/p1t4_on
95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475  /tmp/r1t4_base_bin
95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475  /tmp/p1t4_off
95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475  /tmp/p1t4_on
```

### 2.2 check 路径（stdout 对偶）

```
$ nice -n 19 ./build/corec check tests/suite/ptr_arith.cr >| /tmp/p1t4_check_off.txt 2>&1 ; echo rc=$?
rc=1          # 既有 error[B04]（borrow），两态同
$ nice -n 19 ./build/corec check tests/suite/ptr_arith.cr --type-shadow >| /tmp/p1t4_check_on.txt 2>&1 ; echo rc=$?
rc=1
$ grep -c '^\[type-shadow' /tmp/p1t4_check_off.txt
0
$ grep '^\[type-shadow' /tmp/p1t4_check_on.txt
[type-shadow] decisions=74 agree=74 old_stricter=0 old_looser=0 unknown=0 unknown_bridge=0 unknown_engine=0 unknown_engine_uncovered=0 unknown_engine_budget=0
[type-shadow-sites] hotpatch-ret=0 generic-arg=0 generic-apply-base=0 unify-fallback=0 fn-body-ret=16 assign-binary=0 if-branch=7 assign-node=51
$ grep -v '^\[type-shadow' /tmp/p1t4_check_on.txt >| /tmp/p1t4_check_on_filtered.txt
$ cmp /tmp/p1t4_check_off.txt /tmp/p1t4_check_on_filtered.txt && echo CHECK-STDOUT-IDENTICAL
CHECK-STDOUT-IDENTICAL
```

两行互为校验：`sum(site) = 0+0+0+0+16+0+7+51 = 74 = decisions` 通过

### 2.3 dump 路径冒烟（M3 改动后 ON 通道完整性）

```
$ nice -n 19 ./build/corec check src/compiler/ccr_io.cr --type-shadow --type-shadow-dump /tmp/t4_dump.txt
[type-shadow] decisions=4180 agree=4179 old_stricter=0 old_looser=0 unknown=1 unknown_bridge=0 unknown_engine=1 unknown_engine_uncovered=1 unknown_engine_budget=0
[type-shadow-sites] hotpatch-ret=0 generic-arg=0 generic-apply-base=0 unify-fallback=0 fn-body-ret=725 assign-binary=0 if-branch=319 assign-node=3136
type-shadow dump: 1 entries -> /tmp/t4_dump.txt
（dump 内容：fn-body-ret	5	28	25	1	unknown_engine	0 ， kind 名 = M4 变更后的 `unknown_engine`）
```

`sum(site) = 725+319+3136 = 4180 = decisions` 通过。判定数变化说明：ccr_io 语料自指（编译器自身），本任务的源码/注释改动（`ty_shadow.cr` / `type_terms.cr` / `type_selftest.cr`）进入语料，因此判定数为 4180，Task 3 为 4177（+3），属 findings 第 2 节 已登记的自指语料变化，非回归。

---

## 3. Step 3：自举链

```
$ nice -n 19 ./build/corec build src/compiler/main.cr -o /tmp/t4_corec2 --static -O 0      # rc=0
$ /tmp/t4_corec2 build src/compiler/main.cr -o /tmp/t4_corec3 --static -O 0                # rc=0
$ cmp /tmp/t4_corec2 /tmp/t4_corec3 && echo CMP_IDENTICAL
CMP_IDENTICAL
$ grep -c 'N06' corec2_build.log ; grep -c 'N06' corec3_build.log
0
0
$ grep -c 'error\[' corec2_build.log ; grep -c 'error\[' corec3_build.log
2
2
$ nice -n 19 ./build/corec run 'fn main()->int{return 42;}'
smoke_rc=42
```

`error[` 两行均为既有 TF01 误报（两阶段逐字相同、非本任务引入）：`lits_copy`（8217）与 `ty_memo_slot_no_grow`（8332），即 Task 1 评审记录的「TF01 恰 2 条（既有）」，`ty_shadow.cr` 头注同款登记（自托管 checker 对「loop 收尾无裸 return」的已知误报面对）。N06 = 0（两阶段）。

构建守卫（`build_selfhost_native.py`，三单元）：

```
[GUARD] corec: manifest OK (41 files) ; build log clean (error[ = 0, undefined = 0)  -> build/corec
[GUARD] corearch / x86_64-linux target / corelsp 全部通过 ; === BUILD SUCCESS ===
```

---

## 4. Step 4：文档

| 项 | 落点 |
|---|---|
| spec 第 9 节 P1 行标 已完成 + 落点 | `docs/superpowers/specs/2026-09-10-type-interface-unification-design.md:248`（P1 行重写：四步落点 / 提交链 `e4c293b2`、`844cec6c` 加 `514956a1`、`75c20297` / 未覆盖面与交 P2 项 ①②③④） |
| TODO 登记：影子模式开关的默认值与产物影响 | `TODO.md` #17（`--type-shadow` 默认关；两态产物逐字节同；关态残留开销 = 每次判定一次全局读；结论 = 可安全长期保留默认关） |
| TODO 登记：差异清单的后续裁决归属 | `TODO.md` #17 末段（F1/F2/F3/F4 + 替换门全部归 P2；P2 验收须报站点覆盖） |
| 台账 | `docs/superpowers/implementation/2026-09-11-sdd-progress.md` 追加「R2 P1 Task 4」段（本文件即其事实来源） |

---

## 5. Step 4b：挂账清零（5 项逐条）

| # | 挂账 | 处置 |
|---|---|---|
| ① | `build_selfhost_native.py:309` 注释更正 | 核销（Task 2 已做，勿重复劳动）：挂账行号 :309，现文在 `:310`（Task 2 自身编辑使其 +1），现文 = 「corelsp 清单也必须含本层（Task 2 起 checker.cr 的 type_equal 包装引用 sh_compare/sh_site_begin…corearch 无 checker 故仍不含）」；与实测清单一致（`corelsp_files` 含 `type_terms/type_engine/ty_shadow`；`corearch_files = common + hit + kernel + 三轴 + backend_support`，grep `type_terms` = 0 命中）。 |
| ② | Task 1 评审「>1024 条目第二次重建无实测」 | 补守门用例（非登记）：`type_selftest.cr` 增 `bridge.grow_rehash2`（71 增加到 72 例）。原例只推过第一条守卫线（entries=511，cap 从 1024 变为 2048）；本例再入 1100 条互异 ti 把条目推过第二条守卫线（entries=1023，cap 从 2048 变为 4096），断三件事：①重放守恒（恰 +1100）②`g_shadow_map_cap >= 4096`（cap 只从 1024 逐次翻倍，到达 4096 必然经过 ≥2 次重建 = 第二次重建确实发生）③首批（第一次重建前入表）条目仍命中（两次重放均搬运）。负控实证有效（/tmp 副本，仓未触碰）：把守卫改成「cap ≥ 2048 后不再重建」，得到 `FAIL bridge.grow_rehash2: got 0 want 1`（71/72），而既有 `bridge.grow_rehash` / `bridge.grow_cap_doubled` 仍 PASS，因此该用例对「第二次重建」专项有判别力，非没有实际作用。 |
| ③ | 既有缺陷：函数体内嵌套 `fn` 导致 rc=139 | 核销：TODO #16 已在案（最小复现 `/tmp/rv_nested.cr`、崩点在 parse 到 checker 之间、两版编译器均复现、mini6 无 `@inline` 的措辞更正），本任务无新增信息，不改写。 |
| ④ | `src/compiler/type_terms.cr:73` 头注半句陈旧 | 更正：删「corearch/corelsp 不受影响」，改为「corearch 不受影响（其清单无 checker/引擎层）；corelsp 更正（Task 2 评审 M3）：自 Task 2 起 checker 的 type_equal 包装引用影子层，因此 corelsp 清单必须链接引擎 + 影子层，本文件已在其中」。 |
| ⑤ | Task 2 评审 M5：站点 4「恒 agree」不得据以判收敛 | 核销（Task 3 已写足）：findings 第 5 节(c) 勘误（「不是恒 agree，而是本轮语料根本没跑到」+ 探针 B/K 实测「base 对得到 agree，含 named 对得到 unknown」）+ 第 9 节 限制 1（站点 1/2/4 零命中，四面无证据）。本任务仅复核落点，未重复改文。 |

---

## 6. Step 4c：Task 3 评审遗留（4 Minor + 5 登记 + harness）

### M1 文档精度（含 2 行未提交修正的先核后并）
- 工作副本 2 行修正已核实正确，随本提交一并实施：
  - `findings:6` 上游行，原「P0 引擎（`844cec6c`）+ … Task 2 挂点/通道（`514956a1`）」哈希挂错对象；`jj log` 实证 `844cec6c` = `feat: R2 P1 Task 2，影子判定挂点…`、`514956a1` = `test: R2 P1 Task 2 评审补强`，据此修正为「P1 Task 2 挂点/通道（`844cec6c` + 评审补强 `514956a1`）」通过
  - `findings:15` TL;DR，「71 个文件」到「67 个有效文件（71 个候选中 4 个排除，见 第 2 节）」；第 2 节 档表（31+2+15+19+4 = 71 候选；有摘要 27+2+15+19+4 = 67；排除 = 2 个 0 字节 + 2 个 rc=139）与 第 3.1 节 合计行（67（+4 排除））互证 通过
- 第 3.1 节 不变式行「全部 71 行」到「全部 67 条摘要行（71 候选 − 4 排除 = 67）」。
- 同款错误连带更正：`docs/archive/sdd/r2p1-task-3-report.md:186`「在 71 行逐行成立」到「在 67 条摘要行逐行成立」（同一事实错误，评审只点名 findings；不连带修正会留不一致）。

### M2「前 6 字段」改为「前 5 组 key=value」（3 处）
- `findings:40`、`docs/archive/sdd/r2p1-task-3-report.md:14`、`src/compiler/ty_shadow.cr` `sh_report` 头注。
- 复核依据（评审从 `28fed09` 逐字比对，本任务独立复算）：`jj file show -r 28fed09 src/compiler/ty_shadow.cr` 的 `sh_report` 打印恰 5 组 `decisions/agree/old_stricter/old_looser/unknown`；Step 0 追加 4 组，因此「前 5 组前缀不变」成立，「前 6 字段」为误。

### M3 关态开销（取方案②：早退 + 注释如实改写）
- `src/compiler/ty_shadow.cr` `sh_site_begin` 首行加 `if g_shadow_on == 0 { return; }`；同步改写头注，原「影子关时 wrapper 不调本函数」不成立（8 个站点无条件调用；全仓仅 `type_equal` 包装内一处 `g_shadow_on` 判断）；新注记如实描述：关态若不守卫 = 每次判定多一次调用 + 一次性 64B alloc + 计数 RMW；早退后残留开销 = 一次全局读 + 返回。
- 早退安全性：`g_shadow_site` / `g_shadow_site_counts` / `g_shadow_site_cap` 的唯一读点 = `sh_record` 与 `sh_report`，前者只在 `sh_compare` 内（已由包装的 `g_shadow_on` 门控）、后者首行即查 `g_shadow_on`（直方图另有 `g_shadow_site_cap > 0` 后备）到 关态无读者。
- 改后复验：两态判据仍 OFF-IDENTICAL / ON-IDENTICAL（第 2.1 节 三份 sha256 全等）+ `selftest-types` 72/72 + 全部回归通过（第 1 节）到 早退满足「两态零变化」。

### M4 dump kind 名
- findings 第 1.1 节（转储 kind 空间段）增「读 dump 者须知（M4）：Step 0 前 `kind=0` 名为 `unknown`，现名 `unknown_engine`（契约变更）；仓内已核无消费者，破坏面仅限外部/未来脚本」。第 2.3 节 dump 冒烟实测输出 `unknown_engine` 通过

### 登记 TODO（5 条写入 TODO.md #18-#22）
| 条 | TODO 落点 | 内容要点 |
|---|---|---|
| F1（P2 硬前置） | #18 | 同名 named 多行未规范化（`MemLayout` 2 行 / `Box` 5 行），导致桥接按行建原子，引擎返回 -1；9 条差异 100% 由此产生；替换会把主流同类型比较从「真」变「未判定」，因此列为 P2 第一项 + 守门用例；两条修复路线并存待裁 |
| F2（P2 裁决） | #19 | 数组长度 N 旧比引擎不比（现状 `error[TF01]`，替换后不报错地通过）；R1 裁决仅覆盖 IR 身份，checker 侧须另裁；探针 D/G 实证 |
| F3 | #20 | 调用位点实参不匹配无诊断（`unify_types` 返回值被丢弃 `checker.cr:1053`）；探针 J/C；P2 以引擎判定作诊断源时必须补「判定到诊断」接线 |
| F4 | #21 | 泛型函数后续形参声明类型在推断中不生效（pattern 收到 `gparam(T)`）；与 #20 叠加，完全无诊断；`infer_gen_call` `checker.cr:1030-1060` |
| 仓库卫生 | #22 | `tests/suite/test_control_flow.cr` / `test_generics.cr` 0 字节（勘误「预期失败 fixture」措辞）；`src/compiler/elf.cr` check rc=0 但 2 parse error / decisions=0（本体登记见 #7，本条补语料卫生）；`src/compiler/linker.cr` 0 字节 |

### harness 缺口（新，评审发现；只登记不改）
- TODO #23：`.claude/hooks/block-git.py:10-11` 只拒「以 `git` 开头」到 `cd x && git status` / `echo hi; git log` / 子 shell 等复合形态放行；建议单开修复（按 shell 分隔符分词 + 词边界匹配，放行 `jj git push` 等 jj 子命令），本轮未触碰 harness 文件（`jj status` 无 `.claude/` 变更）。

---

## 7. Step 5：提交（路径限定）

- 提交路径（6 个，全部为已跟踪文件；`docs/archive/sdd/*` 被该目录 `.gitignore`（`*`）忽略，不入提交，报告/台账以工作区文件形式留存，与前三个任务的惯例一致）：

```
TODO.md
docs/superpowers/specs/2026-09-10-type-interface-unification-design.md
docs/superpowers/implementation/2026-09-10-type-shadow-findings.md
src/compiler/ty_shadow.cr
src/compiler/type_selftest.cr
src/compiler/type_terms.cr
```

- 提交哈希：`7624a53cf972d06b2e5681a4d51fb64e1f510d28`（change `mktwvotystrr`；6 文件 +71/-10；提交后 `jj status` = 「no changes」到 提交态 = 判据态：本任务的编辑全部发生在构建/判据之前，构建后直至提交零文件改动，故 第 1 节-第 3 节 判据即提交内容的判据，无需第二次重建复核）

---

## 8. 限制 / concerns（诚实边界）

1. 「13 项」的口径：P0 计划 Task 5 Step 1 实列 12 个 python 套件（却写「Expected: 全部通过（13 项）」）；P1 计划记「13 项 + selftest-types」。本任务按「12 套件 + `selftest-types` = 13」执行并另加固 2 套（`test_impl` / selfhost `test_borrow`）到 无论采用何种口径，覆盖面只多不少；若原意另有所指（第 13 个套件名），本报告的 14 套清单可与评审口径对齐复核。
2. 负控的作用域：`bridge.grow_rehash2` 的负控只证「第二次重建被抑制时用例报错」，不证「重放搬错条目也会失败」，后者由 ①重放守恒断言（恰 +1100）覆盖（若重放丢/多条目，条目数断言即失败），但未单独做该形态的负控（首例 `bridge.grow_rehash` 的负控在 Task 1 已做同族）。
3. 关态开销未做基准：M3 只承诺「消除多余调用/alloc/RMW」与「两态零变化」，未测开态/关态吞吐（沿用 Task 2 concern ⑦、findings 第 9.6 节的同一留白）。
4. 自指语料变化：本次源码改动使编译器自身语料的判定数 +3（ccr_io 4177到4180）；跨提交比较判定数须同源同二进制（findings 第 2 节 已登记）。
5. 未动 `plans/2026-09-10-r2-p1-shadow-parity.md`：该计划与 P0 计划同惯例（复选框一律留空、状态由 spec 第 9 节 / progress.md 表示）；本任务沿用，未改计划文件。

---

## 9. 收口记录：P1 全批终审 4 Minor（2026-09-11）

终审（opus）判定 READY（无 Critical/Important），4 条 Minor 由本任务就地收口，提交 `b58abbcfaa15f755decf476643ee59d6c03fccea`（change `tpmvvplkvnsx`；4 文件路径限定：`TODO.md` / findings / `src/compiler/globals.cr` / `src/compiler/ty_shadow.cr`）。

| 条 | 处置 | 落点 |
|---|---|---|
| M-1（交接缺口，最要紧） | 裁决 = 保留挂点待 P2（零成本、留证据面；不删，删须同步 findings + `ty_shadow.cr` 站点表，归 P2 站点面清理）。两处落点：TODO #17 新增「站点 6 去留裁决」条（权威登记处）+ findings 第 8 节 原「建议 Task 4 决定去留」改写为已裁决（同步指向 TODO #17）。仓内相关登记一致性复核（改后亲跑 grep）：TODO #17（本次新增）/ findings 第 8 节（本次改写）/ `ty_shadow.cr` 站点表第 6 行（原文已标「parser 已无生产点 = 遗留路径，无样本」，无需改）/ 计划 `plans/2026-09-10-r2-p1-shadow-parity.md:261`（原文已写「去留待 P2 裁决」，与本次裁决同向，无需改） | `TODO.md` #17；`findings:256` |
| M-2（文档精度） | findings 第 10 节 复现命令注释 `# 71/71` 改为 `# 72/72（Task 4 后：+ 第二次重建守门 bridge.grow_rehash2；Task 3 时点 = 71/71）`；第 1.2 节的 71/71 属历史输出，保留 | `findings` 第 10 节 |
| M-3（可复现性） | 第 3.1 节表下加「Task 3 时点注」：表内数字为 `75c20297` 实测；自指行在最终提交上一致 +3（`main.cr` 3964到3967、`_import.cr` 3844到3847、`ccr_io.cr` 4177到4180 ，本任务亲跑复核，非转抄）；非自指行不变（抽检 `ptr_arith.cr` = 74、`toml.cr` = 120 与表一致）；并注明该组数字随编译器自身源码（含注释行）移动，引用须连提交号 | `findings` 第 3.1 节 |
| M-4（措辞） | `globals.cr:251-253` 与 `ty_shadow.cr:26-28`「关时连读都不发生」改为「除 `g_shadow_on` 自身外连读都不发生（`type_equal` 包装 / `sh_site_begin` 早退 / `sh_report`/`sh_dump_write` 首行）」，与 `ty_shadow.cr:247-251` 的 M3 注一致 | `src/compiler/globals.cr`；`src/compiler/ty_shadow.cr` |

收口复验（改动含 2 个源文件注释，按要求重建）：

```
$ nice -n 19 python3 build_selfhost_native.py
[GUARD] corec: manifest OK (41 files) ; build log clean (error[ = 0, undefined = 0)
[GUARD] corearch / x86_64-linux target / corelsp 全部通过 ; === BUILD SUCCESS ===
$ nice -n 19 ./build/corec selftest-types | tail -1
72/72 type-engine cases passed
$ nice -n 19 ./build/corec clean-cache && nice -n 19 ./build/corec build tests/suite/ptr_arith.cr --static -o /tmp/p1t4b_off
$ nice -n 19 ./build/corec clean-cache && nice -n 19 ./build/corec build tests/suite/ptr_arith.cr --static --type-shadow -o /tmp/p1t4b_on
$ cmp /tmp/r1t4_base_bin /tmp/p1t4b_off && echo OFF-IDENTICAL
OFF-IDENTICAL
$ cmp /tmp/r1t4_base_bin /tmp/p1t4b_on && echo ON-IDENTICAL
ON-IDENTICAL
$ sha256sum /tmp/r1t4_base_bin /tmp/p1t4b_off /tmp/p1t4b_on
95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475  /tmp/r1t4_base_bin
95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475  /tmp/p1t4b_off
95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475  /tmp/p1t4b_on
（ON 态摘要照常：decisions=74 agree=74 / 站点和 0+0+0+0+16+0+7+51=74=decisions）
```

未重跑项（如实标注）：14 套回归未重跑，本次改动为注释 + 文档（无行为面：注释在词法阶段即丢弃，产物判据已逐字节证零变化）；若评审要求全量重跑，可在本提交上补跑（预计与 第 1 节 同结果）。

流程注记：报告与台账位于 `docs/archive/sdd/`，该目录 `.gitignore` = `*`，报告文件无法入提交（jj 路径限定不含被忽略路径）；本任务两笔提交（`7624a53c` / `b58abbcf`）均只含已跟踪文件，报告/台账以工作区文件形式随提交号引用（沿用 Task 1-3 惯例）。
