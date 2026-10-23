# R2 P5 Task 7 报告：收尾（全量回归、判据复验、统一台账、文档、P6 交接包）

日期：2026-09-14。任务：`docs/superpowers/plans/2026-09-13-r2-p5-cleanup.md` 的 Task 7，Step 1 到 6。
起点：`04c20487`，P5 Task 6 收尾；工作副本 `1413314e` 为空，`jj status` 干净。
产物：`build/corec` = `f737e26bf42fc3d1b8a921d545e0ab601bda154a91709509860f09775ea37d57`；`build/corearch` = `544e9201af10de3c9c24853ac21b595ffe2ecd0927f2ed615a218cbf9921424f`；`build/corelsp` = `4251108b04cf7fe1afb452b6a4e5fd8cbcc8eb5e9f345066fb865a2fd123dc07`。
口径：cwd 为仓库根；全部命令 `nice -n 19`；一次构建一次编译串行，每段前用 `ps` 实查；比较 `.ccr` 前后执行 `clean-cache`；数字全部为本实例实跑，命令和原始输出见 §7；继承的数值逐条标注。
证据：`/tmp/p5t7/`，本实例；`/tmp/p5t7/prev_run/`，中断实例旁证，仅用于交叉校验。

---

## 0. 交付摘要

| 项 | 结果 |
|---|---|
| 全量回归 | 五个 CI job 全部 rc=0；全枚举 58/58 rc=0（51 个 selfhost 加 7 个 bootstrap）；`check src/compiler` rc=0；`selftest-types` 404/404；构建确定性两次，三个二进制和构建日志逐字节相同 |
| 判据复验 | ELF canary `95084e7b…d475`（28822B）IDENTICAL；`.ccr` 两套口径四条等于 T5/T6 记录值；`--dump-objects` 3521 行 IDENTICAL；`.cir` DOT 165915B IDENTICAL；自举链 `corec2==corec3` 为 `5559beef…`，N06=0，冒烟 42 |
| 冻结基线同源对拍 | pre-P5 二进制 `5d2b15ad…` 加当前源，对比 `f737e26b…` 加当前源：72 档 rc 和日志 `diff -rq` 零输出，rc 分布两侧 34 个 0、38 个 1 |
| 行为探针（替代 T5 的检查面） | 30 档探针语料对比 T5 记录，`diff -rq` 零差异，rc 和日志逐档相同 |
| 突变控制（检查面有效性） | M1 派生面得到 400/404 加 35/40，`.ccr` sha 变化；M2 判定面得到 10/18 加 397/404，语料对拍子集 12/12 DIFF；两条精确回滚，仓库零改动 |
| 冷/热豁免表 | 三类缓存态复测：缓存启用档冷态不等于暖态但各自确定；含泛型或可选档缓存关闭，冷态等于暖态。见 §4-1 |
| 统一台账 | 删除/退役 6 件加 1 个改名族；收紧 5 类；放宽 0；修复 4；偏差 8 条，见 §3 |
| P6 交接包 | 计划附录 E 增补 7 条，E-10 到 E-16，包含现状、出处、影响面、建议、前置 |
| 文档 | spec §9 P5 行标为完成，加 §3.4/§6.2/§6.3；format spec §3.3 派生码语义加 D20 规范；findings §16 文件冻结；TODO #49 加 #24/#31/#48 指针更新 |
| 提交 | 路径限定 5 个文件，见 §6 |

---

## 1. 全量回归（Step 1，本实例实跑）

命令和原始输出：`/tmp/p5t7/t7a_regress.sh` 输出到 `/tmp/p5t7/t7a.out`，耗时 675 秒。

| 序号 | 判据 | 命令 | 结果 |
|---|---|---|---|
| 1 | 构建 A | `nice -n 19 python3 build_selfhost_native.py`，日志 `t7_buildA.log` | rc=0；`error[`=0；`GUARD clean` 出现 3 次；sha 见 §0 |
| 2 | 构建 B | 同上，日志 `t7_buildB.log` | rc=0；sha 与 A 逐字节相同，构建日志也逐字节相同，得到 DETERMINISM-IDENTICAL 和 BUILD-LOGS-IDENTICAL |
| 3 | 五个 CI job | `CI_JOB_NAME={check,bootstrap-tests,suite,selfhost-tests,full-bootstrap} nice -n 19 src/ci/run.sh` | 全部 rc=0（`t7_ci_*.log`） |
| 4 | 自源和自测 | `./build/corec check src/compiler`、`./build/corec selftest-types` | rc=0；404/404（`t7_check_self.log` / `t7_selftest.log`） |
| 5 | 全枚举 | `for f in tests/selfhost/test_*.py tests/bootstrap/*.py`，58 档逐档 rc | 58/58 rc=0（`t7_enum.out` 加 `t7_enum/*.log`，非零 0 行） |
| 6 | 自举链 | full-bootstrap job 产物 | `corec2 == corec3 = 5559beef2abf…`（2854910B，与 T6 记录同值）；N06=0；冒烟 corec/corec3 双通道 rc=42 |
| 7 | 构建后复核 | `sha256sum build/*` | 与 A/B 同值，CI job 内重建不改值 |

与中断实例的衔接：前实例因 API 错误中断，在 `/tmp/p5t7/` 留有两次构建和五个 CI job 全绿的输出，止于枚举前。本实例全部重跑；旧输出存档到 `prev_run/`，只作交叉旁证。其 build1/build2 的 sha 与本实例逐字节相同，因此构建确定性达到 4 次，跨实例。

---

## 2. 判据复验（Step 2，本实例实跑）

命令：`/tmp/p5t7/t7b_criteria.sh` 输出到 `t7b.out`；补充 `/tmp/p5t7/t7d_warmhit.sh`、`/tmp/p5t7/t7e_coldwarm.sh`。

| 序号 | 判据 | 结果 |
|---|---|---|
| ① | ELF canary（硬性判据） | `clean-cache` 后 `build tests/suite/ptr_arith.cr --static`，得到 `95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475`（28822B），IDENTICAL |
| ② | `.ccr` 两套口径（冷态，带标） | `ccr` 口径：`ptr_arith` 90823B `fb4a3b59…`，`generics_test` 135341B `ddec1ce6…`；`build --static` 口径：90966B `592afa31…`，135484B `cd2af565…`。四条与 T5/T6 记录逐字节相同，差恒为 143B |
| ③ | `--dump-objects` | 两套口径各 3521 行，与 T5 记录 `cmp` IDENTICAL |
| ④ | `.cir` DOT | `generics_test` 165915B `b1bdf480…`，与 T5 记录 `cmp` IDENTICAL |
| ⑤ | 冻结基线同源对拍 | 72 档乘 `check`：pre-P5 `5d2b15ad…` 加当前源，对比 `f737e26b…` 加当前源，`diff -rq` 零输出；rc 分布两侧 34 个 0、38 个 1（`parity_frozen/` 对 `parity_post/`） |
| ⑥ | 行为探针全集 | `/tmp/p5t4/run_probes.sh`，T3/T3b/T0 三套共 30 档，与 `/tmp/p5t5/probes_post` 做 `diff -rq`，零差异 |
| ⑦ | 冷/热豁免表复测（三类缓存态） | 见 §4-1。`ptr_arith`/`chan_test` 真命中，ELF 冷等于暖，`.ccr` 冷不相等但各自确定；`generics_test` 和可选档 `entries=0`，冷等于暖 |
| ⑧ | 突变控制快照（检查面有效性） | M1 派生面：`selftest-types` 400/404，`test_ccr_types` 35/40，`ptr_arith.ccr` 的 `2f279f5c…` 不等于 `fb4a3b59…`；M2 判定面：`test_named_face` 10/18，`selftest-types` 397/404，语料对拍子集 12/12 DIFF，TA01/TF01 归零，3 档 rc 从 1 变为 0。两条在 `/tmp/p5t7/mut` 执行，仓库外实拷贝，仓库源码零改动，`jj status` 只有本任务的文档面改动 |

`.ccr` 记录值引用口径，D28 继承：两套命令口径为 `corec ccr F -o O` 和 `corec build F -o O --static`，差恒为 143B，因为 `--static` 前置 `rt.cr`。上述四条都是冷态。

---

## 3. 统一台账（Step 3，T0 到 T6 汇总）

完整表包含每件的死亡证据、替代证据、全语料命中，已落在计划“统一台账”节（`docs/superpowers/plans/2026-09-13-r2-p5-cleanup.md`，6 小节）。这里只给汇总。

删除/退役 6 件加 1 个改名族：① `type_equal_legacy`，包含 7 处自调用，加两处回落。死亡证据是全语料 `replace_*=0`；替代证据是冻结对拍、探针、突变、ICE04。② `g_replace_*` 计数。③ `sh_*_ak_legacy` 桥接副本，零生产调用。④ 站点 6 加 `ir_gen` 死分支，parser 三面不可达，语料 0 命中。⑤ 影子层 12 个函数加 `sh_finish`、17 个全局、2 个 CLI、9 个挂点。Gate 是 `sh_compare` 零调用点，结构性为空。⑥ hits 存和复原 hack。⑦ 改名 `g_shadow_map` 为 `g_term_map`，桥接缓存属于生产面，保留。

收紧 5 类：D23 保存拒绝（T2）、TG02 混类（T3）、`te_elem_cmp` 不变槽 0（T3b）、ICE04 硬错（T4，P-A）、TA02 硬错（T6）。全语料命中逐条为 0，先做 report-only；对应各任务的突变控制是有效性证明。

放宽为 0。

修复 4 件：暖态 `.cir` SIGSEGV（T1）、F1 r9 残留 UB（T2）、声明位点不报错地错产物（T6）、死分支（T4）。

未覆盖面逐条见附录 E，共 16 条。

实施偏差 8 条：P4 六个排除项再裁、F2 三个候选裁决、冷/暖判据重定、APPLY b 槽取基型行、`.ccr` 判据在命名档重定、`--verify-named-dedup` 未删、T6 预期命中面不存在、冻结基线复现腿。

---

## 4. 与 T6 报告的差异和复核（本轮新信息）

1. 冷/热豁免表的三种缓存态，本实例新测，细化台账口径。① 缓存启用档，非可选且无泛型函数：`ptr_arith`（16 条目）、`chan_test`（46 条目）。条目戳三跑全等，是真命中；ELF 冷等于暖；`.ccr` 冷不相等，90966 变 90769B，231044 变 230936B，与 D-1 勘误“非可选冷不等于热是预存”一致，但各自确定，暖 1 等于暖 2。② 含泛型函数档，`entries=0`，缓存整体关闭，因为 `main.cr` 既有策略是任一泛型函数即 `cache_enabled=0`，冷等于暖。③ 可选档，`entries=0`，表示面关缓存，冷等于暖。首测用 `generics_test` 属于②档，缓存关闭，因此补测①档，避免把“冷等于暖”误判。这是本轮对 T5/T6 未覆盖面的一次补测。
2. 突变 harness 教训，登记。`test_named_face.py` 用 `Path(__file__).resolve()` 定位仓库根，突变 harness 里 `tests/` 用软链接时，套件会解析回仓库二进制，首跑假绿 18/18。改成实拷贝 `tests/` 后得到真值 10/18，与 T5 记录一致。`test_ccr_types.py` 用 `os.path.abspath`，不解析软链接，没有这个坑。教训已写入计划 Task 7 记录，供后续批 harness 参考。
3. 前实例旁证：其两次构建与本实例两次构建，三个二进制 sha 逐字节相同，因此构建确定性达到 4 次，跨实例、跨会话。

---

## 5. 文档和提交面（Step 4/5/6）

改动文件 5 个，路径限定提交：

| 文件 | 改动 |
|---|---|
| `docs/superpowers/plans/2026-09-13-r2-p5-cleanup.md` | 新增“实施状态总表（12 提交链）”“收尾总述：类型接口化工作流的终态（一页）”“统一台账（T0 到 T6）”；Task 7 六步勾选加实施记录，含突变和 harness 教训；D26 替代表收口注；附录 E 增补 E-10 到 E-16 |
| `docs/superpowers/specs/2026-09-10-type-interface-unification-design.md` | §3.4/§6.2/§6.3 收尾实施块，包含单槽形态、D20 规范、暖态项面局限、β 交 P6；§9 P5 行标为完成，附提交链、判据、统一台账、未覆盖面指针 |
| `docs/superpowers/specs/2026-09-09-lattice-ir-v7-format.md` | 头部 P5 追加注；§3.3 NOD 的 `tk` 等于派生码语义块，含 D20 禁令和许可形态；测试族 `test_ccr_types` 从 34 改为 40 |
| `docs/superpowers/implementation/2026-09-10-type-shadow-findings.md` | §16 P5 收尾，终态复核，文件自此冻结。§15 已由 T5 落盘；§16 声明通道已死，替代检查面的口径强制继承 |
| `TODO.md` | #49 R2 P5 收尾条目；#24 ①③ 划销加同族清偿注；#31 挂点复测 28/51；#48 登记①接 P6 附录 E-13 |

CLAUDE.md 没有改动。本批无文件或结构变化，没有新增、改名、删除源文件。其 `src/compiler/` 清单早于 R2 各批的类型引擎文件，属于预存陈旧面，不在本批范围。

P6 交接包，附录 E 增补，逐条包含现状、出处、影响面、建议、前置：

- E-10 ¬ 面过判。T3b 揭开，只有 witness 项的 `ty_sub` 消费者，全语料零翻转。建议加强“¬ 面异身份原子不交”；前置是 T3b 排序表复用的适用域证明和负控。
- E-11 `-> never` 调用返回型缺口。T6 发现，全语料 0 命中。建议调用返回型补 `TI_NEVER`；前置是与 E-12 同批，因为同一调用推断面。
- E-12 #20/F3 调用位点无诊断，`unify_types` 返回值被丢弃。建议接诊断，码体系照 TA01/TA02，硬名单前先 report-only；前置是调用面错误标记和级联抑制语义。
- E-13 冻结基线可复现性。T5 §7-4，维护者已裁定“重建，不落二进制”。建议增加 `tools/baseline/REBUILD.md`，记录 pinned revision `9bcb7083` 和 sha 允许清单。
- E-14 ICE04/P-A 签核加非硬名单诊断不阻 `build`，这是政策对偶面。建议一次政策复核同裁三问：硬名单、是否收紧、入检查判据成文化。
- E-15 `string == int` 混比双路径分歧加单条目超过 1GiB 分片。T1 §6。建议语言面裁决混比语义，分片独立登记。
- E-16 设计先例引用面。policy-injection 和 explain-predict 两个 spec 以 `--type-shadow` 为先例。建议下次修订改写为实现方式 `--verify-*` 加行为探针。

待维护者签核，本批遗留，风险已给回退面：ICE04/P-A 政策，回退为一行；`--verify-named-dedup` 保留，偏离 D27，回退为一行；冻结基线配方落位。

---

## 6. 提交

提交为 `5b93c9fe`（change `puulwqvw`）。`jj diff -r 5b93c9fe --summary` 实核为上述 5 个路径，零 `src/`、零 `tests/` 改动，源码零改动，纯文档。提交后工作副本为 `15da9397`，空提交，供后续批继续。

```
docs: R2 P5 Task 7 收官——全量回归（五 CI job + 全枚举 58/58 + selftest 404/404 + 构建确定性 ×2）+
判据复验（canary 95084e7b…d475 IDENTICAL · .ccr 两口径四条 · dump-objects/.cir DOT 逐字节同 ·
冻结基线同源对拍 72 档零差异 · 探针全集 30 档零差异 · 突变控制 M1/M2 转红+精确回滚 · 冷/热三类缓存态复测）+
统一台账（删除/退役 6 件+1 改名族 · 收紧 5 类 · 放宽 0 · 修复 4 · 偏差 8 条）+ 文档（spec §9 P5 完成 +
§3.4/§6.2/§6.3 · format spec NOD tk=派生码+D20 规范 · findings §16 冻结 · TODO #49）+ 附录 E 增补 7 条
```

路径限定：`docs/superpowers/plans/2026-09-13-r2-p5-cleanup.md`、`docs/superpowers/specs/2026-09-10-type-interface-unification-design.md`、`docs/superpowers/specs/2026-09-09-lattice-ir-v7-format.md`、`docs/superpowers/implementation/2026-09-10-type-shadow-findings.md`、`TODO.md`。源码零改动，`jj diff --summary` 实核。本报告与其他 `docs/archive/sdd/*` 同档，不入版本控制。

---

## 7. 证据路径（/tmp/p5t7/）

| 用途 | 路径 |
|---|---|
| 回归驱动和输出 | `t7a_regress.sh`、`t7a.out`（675s）、`t7_buildA.log`/`t7_buildA.sha`、`t7_buildB.log`/`t7_buildB.sha`、`t7_ci_{check,bootstrap-tests,suite,selfhost-tests,full-bootstrap}.log`、`t7_check_self.log`、`t7_selftest.log`、`t7_enum.out` 加 `t7_enum/*.log`（58 档） |
| 判据驱动和输出 | `t7b_criteria.sh`、`t7b.out`、`t7_canary.log` 加 `pa`、`pa.ccr`/`pa_st.ccr`/`gt.ccr`/`gt_st.ccr`、`gt_do.txt`/`gt_st_do.txt`、`gt.cir`、`t7_cw_*`（冷/暖）、`t7_opt_*`/`opt_prog.cr`、`probes_post/`（30 档）、`parity_{frozen,post}/check/`（72 档乘 logs/dumps） |
| 冷/热补测 | `t7d_warmhit.sh` 加 `t7d.out`、`t7e_coldwarm.sh` 加 `t7e.out`、`wh1/wh2`、`ptr_arith_{1,2,3}.bin{,.ccr}`、`chan_test_{1,2,3}.bin{,.ccr}`、`dt_{cold,warm}.ccr` |
| 突变控制 | `t7c_mutation.sh` 加 `t7c.out`、`mut/`，实拷贝 harness：`mut_base_build.log`、`mut_M1_*`、`mut_M2_*`、`mut_M2_<corpus>.log` 共 12 份 |
| 中断实例旁证（存档） | `prev_run/`，两次构建加五个 CI job 日志加草稿脚本 |
| 冻结基线（继承 T0） | `/tmp/p5t0/base/{corec,corearch,corelsp}`，分别为 `5d2b15ad…`/`493dc490…`/`18b94bd9…`；runner `/tmp/p3t0_run.sh`，sha `12dc571f…` |

---

## 8. 需要说明的事项

1. 本实例首跑的 redirect 空转：fish noclobber 使用 `>` 时不覆写已存在文件，导致第一次 build 调用没有执行，rc=1。已识别，日志时间戳早于本实例，随后重跑，没有判据受影响。
2. M2 的 named_face 首测假绿，是软链接 harness 坑，见 §4-2。已用实拷贝 `tests/` 复测，得到真值 10/18，首测结论作废。
3. `generics_test` 首测作为冷/暖主证不成立，因为它属于缓存关闭档。已补测①档，三档并列写入报告，见 §3-⑥。
4. 继承者和实跑者的区分：§1/§2 全部判据为本实例实跑；T0 到 T6 的台账和判据值属于继承，本轮用 §2 复跑逐条验证其可复现性。唯一不可复现的是影子通道读数，按构造已删除，见 findings §15/§16。
5. 未测：`COREC_WARM_SELF=1` 的自源暖态两例，约 3 分钟、1.25GB 缓存，T1 已实测，本轮未单列，CI 内 `test_cir_warm_path` 19/19 包含其余例子；corelsp 进程级 LSP 会话，`test_lsp.py` 在枚举 58/58 内 rc=0 可以佐证。
