# R2 P5 Task 5 报告：影子层下线 + 回归网切换（冻结基线同源对拍 + 行为探针 + 突变控制）

日期：2026-09-13 · 起点：`e6db38b8`（P5 Task 4；工作副本空、`jj status` 干净；起点 `build/corec` = `eae13428…`）
产物：`build/corec` = `2342fd03f84ff17a850e7caa1c14414885579bc03dd68a413bd3580e2c2e1e83`、`build/corearch` = `544e9201af10de3c9c24853ac21b595ffe2ecd0927f2ed615a218cbf9921424f`、`build/corelsp` = `99e341364bf23d0089d7a79c99a13beb0c76d33962163fd3741c1bb933d03244`
报告口径：数字全部本实例实测（命令 + 原始输出路径见 第 9 节）；未实测者标「未测」。路径限定提交（见 第 8 节）。

---

## 0. 一句话

Gate 成立（对照物已删 因此 影子判定对拍停摆：72 档全 `decisions=0 agree=0` + 全差异桶 0）因此 按 D24/D26 整体下线影子通道：12 个函数（站点挂点/对账/环缓冲/摘要/转储/kind/站点名/桥接 hits）+ `sh_finish`（main.cr）+ 17 个 `g_shadow_*` 全局 + 2 个 CLI 通道 + 9 个 checker 站点挂点；桥接缓存保留并剥调试计数（`g_shadow_map[+/_cap/_entries]` 改名为 `g_term_map[+/_cap/_entries]`）。回归网切换落纸 + 接线：判定面自此 = 冻结基线同源对拍（72 档 rc + 日志零差异）+ 行为探针（30 档探针集零差异 + 套件）+ 突变控制（2 条注入逐条变为失败 + 精确回滚）+ 三态纪律（ICE04）。零行为变化：ELF canary / `.ccr` 四件 / `--dump-objects` / `.cir` DOT 全 IDENTICAL，自举链 IDENTICAL。

---

## 1. Gate（判据 ①：下线前置，「没有任何东西再依赖影子通道的输出」）

### 1.1 静态面（依赖清点）

| 面 | 事实 |
|---|---|
| 判定对账 `sh_compare` | 零调用点（T4 Step 2 已移除；全仓 grep 仅剩定义/注释）因此 影子通道的判定输出结构性为空（不是「跑起来恰好 0 差异」） |
| 通道输出的消费者 | 仅 `sh_report`/`sh_dump_write`，由 `sh_finish` 调用（`main.cr` 2 处；run / build·check 路径）；`sh_finish` 又由 CLI 旗标 `--type-shadow` / `--type-shadow-dump` 触发（默认关） |
| 测试面 | 无任何测试驱动 `--type-shadow`（`grep -rn 'type-shadow' tests/` = 0 命中；`test_lsp.py:388` 仅历史注记） |
| 站点挂点 | 9 处 `sh_site_begin(id)`（checker 9 个判定点），只写站点直方图（`g_shadow_site_counts`），消费者仅 `sh_report` |
| 桥接缓存 `g_term_map` | 生产面（判定路径无条件经 `sh_term_of_ti`）因此 不删，只改名 + 剥 hits 计数 |

### 1.2 运行面（起点二进制 `eae13428…` × 当前源，72 档语料，逐档 `clean-cache`）

命令：`bash /tmp/p3t0_run.sh shadow build/corec /tmp/p5t5/parity_pre/shadow`（cwd = 仓库根）。

| 面 | 结果 |
|---|---|
| 影子摘要（70 档出摘要，余 2 档无 shadow 输出） | 70/70 档 `decisions=0 agree=0 old_stricter=0 old_looser=0 unknown=0 unknown_bridge=0 unknown_engine=0 unknown_engine_uncovered=0 unknown_engine_budget=0` |
| 站点直方图（仅内部读数，不作判据，D24 中间态口径） | `assign-node=24996 · fn-body-ret=5911 · if-branch=2045 · struct-field-type=28 · array-elem-type=4 · generic-apply-base=2`（其余 4 站 0，站点 6 已退役） |
| check rc 分布 | 34×0 / 38×1（与 T4 逐档同） |

判定：Gate 成立（通道的全部判定输出恒为空；剩余消费者只有其自身的旗标/摘要打印）。无活依赖 因此 继续。

---

## 2. Step 1/2：删除清单（逐件）

### 2.1 函数（13 个）

| 件 | 来源 | 前镜像 |
|---|---|---|
| `sh_compare`（判定对账）· `sh_record`（环缓冲）· `sh_site_begin`（挂点）· `sh_report`（摘要）· `sh_dump_write`（转储）· `sh_site_name` · `sh_kind_name` · `sh_count_agree` / `sh_count_old_stricter` / `sh_count_old_looser` / `sh_count_unknown` · `sh_map_hits`（桥接 hits 读数） | `ty_shadow.cr` | `jj file show -r @-` 计数：`fn` 76 减为 64（减少 12） |
| `sh_finish`（影子收尾：摘要 + 转储） | `main.cr` | −1 函数、−2 调用点 |

### 2.2 全局态（17 个）与常量

`g_shadow_on` · `g_shadow_site` · `g_shadow_total` · `g_shadow_agree` · `g_shadow_old_stricter` · `g_shadow_old_looser` · `g_shadow_unknown` · `g_shadow_unknown_bridge` · `g_shadow_unknown_engine` · `g_shadow_unknown_uncovered` · `g_shadow_unknown_budget` · `g_shadow_ring` · `g_shadow_ring_cap` · `g_shadow_ring_count` · `g_shadow_site_counts` · `g_shadow_site_cap` · `g_shadow_hits`（桥接调试计数）。
常量 `SHADOW_RING_CAP`（256）删除；`SHADOW_MAP_INIT_CAP` 改为 `TERM_MAP_INIT_CAP`。

改名（3 个，D 择一条件内：引用面 29 ≤ 30 且不触 corearch 清单）：`g_shadow_map` 改为 `g_term_map` · `g_shadow_map_cap` 改为 `g_term_map_cap` · `g_shadow_entries` 改为 `g_term_map_entries`（引用全改：`ty_shadow.cr` / `globals.cr` / `type_selftest.cr` / `test_lsp.py` 注记 / 各注）。

### 2.3 CLI / 挂点 / 计数补偿

- `--type-shadow` / `--type-shadow-dump` 两个隐藏通道 + `g_shadow_on = cli_has(...)` 赋值行（判定路径自此无开关）。
- checker 9 处 `sh_site_begin(id)` 挂点（站点 1/2/3/4/5/7/8/9/10）逐行删除；判定点本体一律保留（`type_compat_strict` / `type_compat_sym` 调用点，见 第 3 节-1 判据）。
- `sh_tk_split_impl` / `sh_tk_term_of_code` 的 hits 存-复原 hack 删除（D26-③ 的补偿面）；`sh_map_reset` 的 hits 复位删除。`entries` 不复原（装填因子守卫输入 = 真实占用，删不得）。

### 2.4 保留面（不是影子通道，随 gate 一并说明）

| 保留件 | 理由 |
|---|---|
| 桥接层全族（`sh_term_of_ti` 及构造点、`g_term_map`、`sh_map_*` 探测/守卫/重放） | 生产面：判定路径无条件经它译项 |
| 展开层全族（`sh_struct_term` / `sh_enum_domain_term` / `sh_iface_shape_term` / `sh_unf_*` / payload 面） | 生产面（满足判定 + 穷尽性域/模式项），P3 已裁决边界 |
| `--verify-named-dedup` + `named_dedup_verify`（checker.cr） | 非影子面（零 `g_shadow_*` 耦合）+ 有活消费者 `tests/selfhost/test_named_dedup.py`（全枚举 57 档之一）因此 删它 = 杀死既有回归网且违「自测用例只增不减」。偏离计划 D27 的一项，见 第 7 节-1 |
| `--verify-evp-nodes`（`sh_evp_verify`） | 同上（payload 列入库断言；有活用例 `test_optional.py` 面） |
| `sh_unf_hits` / `sh_unf_entries`（展开层缓存计数） | 展开层自身的自测读数（非影子判定通道），计划未列 |

---

## 3. 判据复验（全部本实例实跑）

| # | 判据 | 命令 / 结果 |
|---|---|---|
| 1 | 站点下线 ≠ 判定点下线 | 删挂点前后：`check src/compiler` rc=0；冻结基线同源对拍 72 档 rc + 日志逐字节零差异（第 3 节-5），判定面（拒绝/接受集合 + 诊断文本）逐字不变 |
| 2 | 构建 | `nice -n 19 python3 build_selfhost_native.py` rc=0；三 GUARD 行 `error[ = 0`；真实诊断计数 `grep -cE 'error\[[A-Z0-9]'` = 0 |
| 3 | 后端引导 | `nice -n 19 python3 tests/selfhost/test_backend_bootstrap.py` rc=0 + 日志 `error[` = 0；CI `bootstrap-tests` job rc=0 |
| 4 | 自源 | `nice -n 19 ./build/corec check src/compiler` rc=0 |
| 5 | 自测 | `selftest-types` 404/404（0 FAIL；P5 T5 两例重固定不增减，见 第 4 节） |
| 6 | 五 CI job | `check` / `bootstrap-tests` / `suite` / `selfhost-tests` / `full-bootstrap` 全 rc=0 |
| 7 | 全枚举 | 57/57 rc=0（50 selfhost + 7 bootstrap；路径编码日志 `/tmp/p5t5/enum/`） |
| 8 | ELF canary（硬检查） | 先 `clean-cache`，再 `build tests/suite/ptr_arith.cr --static`，结果为 `95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475`（28822B）IDENTICAL（突变回滚后复跑同值） |
| 9 | `.ccr` 两口径（冷态，带标） | `ptr_arith`：`ccr` 90823B `fb4a3b59…` / `build --static` 90966B `592afa31…`；`generics_test`：`ccr` 135341B `ddec1ce6…` / `build --static` 135484B `cd2af565…` ，四件与 T4 记录值逐字节同（`cmp` IDENTICAL） |
| 10 | `--dump-objects` | 两口径 3521 行，与 T4 记录 `cmp` IDENTICAL（非静态 / 静态各一） |
| 11 | `.cir` DOT | `generics_test` 165915B `b1bdf480…` 与 T4 `cmp` IDENTICAL |
| 12 | 冻结基线同源对拍（D26-① 主腿） | `/tmp/p5t0/base/corec`（pre-P5，`5d2b15ad…`）× 当前源 vs `build/corec`（post-T5）× 当前源：72 档 日志 + rc 逐字节零差异（`diff -rq` 零输出；两档 rc 分布同为 34×0/38×1） |
| 13 | 行为探针全集 | `/tmp/p5t3/probes` + `/tmp/p5t3b/probes` + `/tmp/p5t0/probes`（30 档，17 rc=0 / 13 rc=1）post-T5 vs T4 记录：`diff -rq` 零差异（rc + 日志逐档同） |
| 14 | 自举链 | `corec2 == corec3` `cmp` IDENTICAL（双 `75da3610…`，2854878B，模式 0755）+ N06 0 + 冒烟 42 + `--help` rc=1（corec2/corec3 逐字节同 因此 两进程日志同源，N06 单测即覆盖两方） |
| 15 | 构建确定性 | 期间全部构建（首建 / 五 CI job 内 5 次 / 三次突变回滚重建）产出同一 `build/corec` sha `2342fd03…`（抽检点 = 首建后、五 CI job 前后、三次回滚后；回滚为 `sha256sum -c` + 二进制逐字节对拍） |
| 16 | 突变控制 | 第 6 节（2 条注入逐条变为失败 + 精确回滚） |

---

## 4. 被删/重固定的自测与套件（判据 ③「逐条列出 + 理由」）

| 件 | 处置 | 理由 |
|---|---|---|
| `t4.tk_derivation_not_a_shadow_site`（`type_selftest.cr`） | 重固定为 `t4.tk_query_purity_and_cache_hit` | 原断言 = 「实现方式面派生不扰动影子的 hits 计数」，hits 通道已删 因此 命题无对象。改固定同源性质：`sh_tk_term_of_code` 是纯查询（不写槽出参 / 不置 D23 失败位）+ 同 ti 返回同一项（缓存语义）。计数不增减 |
| `bridge.hit_delta`（`type_selftest.cr`） | 重固定为 `bridge.cache_hit_same_term_no_new_entry` | 原断言 = 「二次调用 hits 恰 +1」，无计数器后改固定「同项 + 不新增条目」（占用面证据，同一语义） |
| 其余 `selftest-types` 用例 | 零改动 | 桥接/展开/引擎/单槽化面与影子通道无关（影子期就已不依赖） |
| `tests/selfhost/*.py` 引用影子面者 | 无（grep 零命中） | 唯一改动 = `test_lsp.py` 注记里的 `g_shadow_map` 改为 `g_term_map`（纯改名同步；用例本体未动） |
| `test_named_dedup.py` | 保留（并新挂进 CI selfhost-tests） | 它驱动 `--verify-named-dedup`（非影子通道；P2a C-4 管线内断言 = 侧表↔`res_type_node` 三组一致性），属判定面回归网组件，下线后更应常在 |
| `src/ci/run.sh` | 计数注释同步（404 不变 + P5 T4/T5 记录）+ 新增「判定面回归网」自述块（判据 ⑥ 的落点） | 后续读者须知道影子通道已下线、什么接替了它 |

---

## 5. 回归网切换（判据 ⑥：现在谁在守判定面、住在哪里）

### 5.1 声明（同一提交落纸：`src/ci/run.sh` selfhost-tests 自述块 + `ty_shadow.cr` 文件头 + TODO；`globals.cr`/`main.cr`/`checker.cr` 相应段注同源）

> 判定面回归网（R2 P5 Task 5 起）= ① 冻结基线同源对拍 + ② 行为探针 + ③ 突变控制 + ④ 三态纪律（ICE04）。
> 影子通道（`--type-shadow` / `[type-shadow]` 摘要 / 差异转储 / 站点直方图 / `sh_compare` / `g_shadow_*`）已整体下线，
> 任何后续批次不得引用其计数/摘要/站点直方图。

### 5.2 四条腿的实现方式与判据

| 腿 | 实现方式 | 位置 | 判据形态 |
|---|---|---|---|
| ① 冻结基线同源对拍 | `/tmp/p5t0/base/corec`（pre-P5）+ `/tmp/p3t0_run.sh`（72 档，逐档 `clean-cache`） | 手工判据（冻结二进制不入库，见 第 7 节-4）；CI 内不可复现 | `check` rc + 日志逐档 `diff` = 空 |
| ② 行为探针 | `tests/selfhost/*.py`（`test_named_face` 18 例为主力）+ 30 档探针语料（`/tmp/p5t3{,b}`、`/tmp/p5t0`） | `src/ci/run.sh selfhost-tests`（已接线）+ `/tmp/p5t4/run_probes.sh` | 断言 rc / 诊断码 / 行为（不依赖任何已删通道） |
| ③ 突变控制 | 注入脚本（本报告 第 6 节 配方；`/tmp/p5t5/mut.sh`、`mut3.sh`） | 手工（每批收尾） | 注入 因此 网变为失败；回滚 因此 源 sha + 二进制 sha 复原 |
| ④ 三态纪律 | ICE04（P-A）硬错 + 段/项面拒绝（D13/D23） | `main.cr` 硬名单 + `ccr_io.cr` / `ccr_types.cr` save 拒绝 | 未知/不可译 因此 拒绝，绝不不报错地当 0/1 |

效力边界（继承口径，不稀释）：① 覆盖「判定面的 rc/诊断行为」（72 档）；② 覆盖各批行为面；实现方式面（TYPE/IFACE 段、corearch 读回、DFNode.TK 槽、运行期表示位）由结构性断言（`test_ccr_types` 40 例等）+ corearch 读回对拍 + 定向探针承担，影子通道对其零覆盖（继承声明）。N 面（数组长度）没有对拍腿（影子对 N 面失明），只能靠行为探针（第 5 节-② 的 `array_len_*` 探针与套件）。

---

## 6. 突变控制（2 条 + 精确回滚）

驱动：`/tmp/p5t5/mut.sh`（M1）、`/tmp/p5t5/mut3.sh`（M2b）；回滚校验 = 源 sha256 对拍 + 二进制 sha 复原（逐字节回 `2342fd03…`）。

| 突变 | 内容 | 变为失败证据 |
|---|---|---|
| M1（派生面） | `sh_dfn_code_of_slots` 删辅码分支（辅码/复合行码丢失 因此 派生码错值） | `selftest-types` 400/404（4 FAIL）；`test_ccr_types` 35/40（5 FAIL）；`ptr_arith.ccr` sha `2f279f5c…` ≠ 记录值 `fb4a3b59…`（实现方式面变为失败） |
| M2（判定面，判定放宽） | `type_equal_engine`：`if e == 0 { return false; }` 改为 `return true`（「确定不等价」当等价） | `test_named_face` 10/18（8 FAIL）；`selftest-types` 397/404（7 FAIL）；语料同源对拍 12/12 档 DIFF（TA01/TF01 全数消失；其中 `chan_test`/`conc_test`/`go_e2e_test` rc 从 1 变为 0，即拒绝不报错地消失，正是影子对拍过去要抓的那一类） |
| M2 反证（同 12 档的冻结对拍） | 突变二进制 vs `/tmp/p5t0/base/corec`（同源同档） | DIFF 12/12（冻结腿与记录腿同向变为失败 因此 网的两条腿都活着） |

回滚：两条突变后均 `sha256sum -c` 源复原 + 重建 因此 `build/corec` 逐字节回 `2342fd03…`（`ROLLBACK-BIN-EXACT` ×3）；回滚后复跑 `selftest-types` 404/404 + canary IDENTICAL。

---

## 7. 实施偏离 / 登记（诚实，逐条）

1. `--verify-named-dedup` 未删（偏离计划 D27/Task 5 Files 的明列项）。理由三条：① 它不是影子通道（零 `g_shadow_*` / 零 `sh_compare` 耦合；实现 `named_dedup_verify` 在 checker.cr，与影子层无调用关系）；② 有活消费者 = `tests/selfhost/test_named_dedup.py`（全枚举 57 档之一，驱动它做「侧表 ↔ `res_type_node`」管线内断言），删旗标 = 该套件无驱动 = 杀死一条既有回归网，且违 Global Constraints「自测用例只增不减」；③ 本任务的边界纪律（协调者指令）「不删影子层自身面以外的东西」。回退面 = 一行（`main.cr` 的 `cli_flag_bool("verify-named-dedup", …)` + `run_frontend` 的调用块 + 该 py 套件），若维护者仍要清 `#24` 同族通道，须同提交另给该断言的替身实现方式（现无可用的 in-process 通道：`selftest-types` 不跑 `check_all` 全流水线）。提请复核。
2. `g_shadow_*` 改名面已执行（计划留的择一条件：引用 ≤ 30 且不触 corearch 清单 因此 执行）。`sh_` 函数前缀保留（`sh_term_of_ti` 等是判定面入口名，改名面远超 30 处且零语义收益），文件头注已写明「`sh_` = 历史前缀，语义 = 桥接/类型项层」。
3. 文件名 `ty_shadow.cr` 保留（改名触三面清单：`build_selfhost_native.py` ×2 + `src/compiler/_import.cr` + `src/targets/x86_64-linux/_import.cr`，收益 = 命名，风险 = 清单变化）因此 以文件头注 + 本报告登记；若要改名 = 独立小批。
4. 冻结基线二进制不入库：D26-① 的「冻结基线同源对拍」是每批手工判据（`/tmp/p5t0/base/` 为 /tmp 产物，跨会话可能被清）。风险登记：`/tmp` 清理后该腿不可复现（需重建 pre-P5 二进制 = `jj` 检出 `e6db38b8^…`（P4 收尾 `9bcb7083`）重建）。建议（转 P6/维护者裁决）：把冻结二进制或「重建配方 + sha 允许清单」落进仓库（如 `tools/p5-baseline/`），否则该腿只在本批有效。
5. 自举链 corec3 日志：本轮 corec3 由 corec2 生成（`cmp` IDENTICAL 双 `75da3610…`）因此 两二进制逐字节同 因此 N06 计数在 corec2 日志上测得（0）即覆盖 corec3（同一程序）。CI `full-bootstrap` job（corec2==corec3 + `--help` rc=1）同批 rc=0 = 独立佐证。
6. 突变 M2 的首轮子集（6 档）全部 SAME（诚实登记）：所选 6 档不经过「引擎判 0」的判定点 因此 对拍不失败。这不是网失效（换成 TA01/TF01 面 12 档即 12/12 DIFF），登记为选样教训：突变控制的语料必须选该突变语义覆盖到的面（本轮配方已写入 `/tmp/p5t5/mut3.sh` 可复用）。
7. 未测：`.cir` 暖态路径在删除后的重跑（沿用 T1 的 `test_cir_warm_path` 19/19 = CI 内已跑，rc=0；本轮未单列复跑）；`corelsp` 进程级 LSP 会话（`test_lsp.py` 在枚举 57/57 内 rc=0）。
8. 计划行号定位点已变化：计划 Task 5 列的 `main.cr:236-238/:244/:182`、`ty_shadow.cr:472-538/:678` 等定位点点沿 T2–T4 变化，实施以符号定位点（函数名/旗标名）为准（前镜像行号见 第 2 节）。

---

## 8. 提交面

- 提交（路径限定）：`build_selfhost_native.py` · `src/ci/run.sh` · `src/compiler/_import.cr` · `src/compiler/ccr_types.cr` · `src/compiler/checker.cr` · `src/compiler/globals.cr` · `src/compiler/main.cr` · `src/compiler/ty_shadow.cr` · `src/compiler/type_selftest.cr` · `src/compiler/type_terms.cr` · `tests/selfhost/test_lsp.py` · `docs/superpowers/plans/2026-09-13-r2-p5-cleanup.md` · `TODO.md` · `docs/superpowers/implementation/2026-09-10-type-shadow-findings.md`
- 本报告（`docs/archive/sdd/`）= 工作区产物（`.gitignore:33` 已忽略），不入提交。
- `jj diff --stat`（源码面，提交前）：11 文件 / +184 / −383（`ty_shadow.cr` −207+14 为主）。

---

## 9. 证据路径

| 用途 | 路径 |
|---|---|
| Gate 面（起点二进制 × 72 档 shadow/check） | `/tmp/p5t5/parity_pre_shadow.out` + `parity_pre_shadow/` · `/tmp/p5t5/parity_pre_check.out` + `parity_pre/check/` |
| 冻结基线同源对拍 | `/tmp/p5t5/parity_frozen/check/`（vs `parity_post/check/`：`diff -rq` 零输出） |
| post-T5 语料 | `/tmp/p5t5/parity_post_check.out` + `parity_post/check/` |
| 探针全集 | `/tmp/p5t5/probes_post/`（vs `/tmp/p5t4/probes_post/`）· runner `/tmp/p5t4/run_probes.sh` |
| 构建 / 自测 / CI / 枚举 / 链 | `/tmp/p5t5/build1.log` · `selftest*` · `ci_{check,bootstrap-tests,suite,selfhost-tests,full-bootstrap}.log` · `enum/*`（57 档） · `chain_{build2,corec2}.log` + `/tmp/p5t5/corec{2,3}` |
| canary / `.ccr` / dump / cir | `/tmp/pa_p5t5` + `/tmp/pa_p5t5b` · `/tmp/p5t5/{pa,pa_st,gt,gt_st}.ccr` · `{gt,gt_st}_do.txt` · `gt.cir`（对照 `/tmp/p5t4/`） |
| 突变控制 | `/tmp/p5t5/mut.sh` · `mut3.sh` · `mut*.log` · `mut_M2b_corpus/` · `{ty_shadow,checker}.cr.pristine` |
| 前镜像（删除面） | `/tmp/p5t5/ty_shadow_pre.cr` · `globals_pre.cr`（`jj file show -r @-`） |
