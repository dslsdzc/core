# R2 P6 Task 1 实施报告：回归网可复现化（E-13）

日期：2026-09-14。任务：`docs/superpowers/plans/2026-09-14-r2-p6-tail.md` 的 Task 1（Step 1 到 6）。
起点：`bc4f0a43`（P6 计划定稿；工作副本 `f90cf65e` 为空，`jj status` 干净）。
口径：cwd 为仓库根；全部命令使用 `nice -n 19`；一次构建一次编译串行执行（建模前后用 `ps -eo comm` 实查）；比较产物前先 `clean-cache`；版本控制只用 `jj`；数字全部由本实例实跑。
证据：`/tmp/p6t1/`（本实例）。T0 输入：`docs/archive/sdd/p6-task0-report.md`（表 C 清点、表 D 定位点点、第 3.3 节 p5t3b 三栏）。

---

## 0. 摘要

| 项 | 结果 |
|---|---|
| 入仓 | `tools/baseline/{REBUILD.md,rebuild.sh,parity_run.sh,probes_run.sh}` 加 `tests/probes/`（README 加 29 档）加 `src/ci/run.sh` 自述块加 `TODO.md`（#50 加 #48① 闭合）加计划 Task 1 记录 |
| 配方可复现性 | `rebuild.sh` rc=0（41s），三个 sha 逐条等于允许清单；与 `/tmp/p6t0/base/`、`/tmp/p5t0/base/` 的 `cmp` 均为 IDENTICAL，共 3 次；冒烟 rc=42；`jj workspace` 零残留 |
| runner 保真（同源同比） | 入仓 `parity_run.sh` 对比迁移版 `/tmp/p3t0_run.sh check`（同一二进制）：72 档 `diff -rq` 零输出；rc 分布两侧相同，34 档 0、38 档 1 |
| 腿① 主判据 | 冻结基线配当前源对比当前二进制配当前源（T0 `parity_start`）零差异；与 P5 T7 的 `parity_post` 也零差异 |
| 探针（29 档） | 两态（冻结基线/当前二进制）`diff -rq` 零差异；rc 和日志 29/29 与 `/tmp/p5t7/probes_post` 逐字节相同；rc 17 档 0、12 档 1；入仓 sha 与 T0 清单 29/29 逐条相同 |
| 全量回归 | 五个 CI job 全部 rc=0；全枚举 58/58；`selftest-types` 404/404；`check src/compiler` rc=0；canary IDENTICAL（28822B）；自举链 `5559beef…` 加 N06=0 加冒烟 42 加 `--help` rc=1；`test_backend_bootstrap` rc=0 加 `error[` 为 0；构建确定性（多次构建同 sha） |
| 突变控制 | 5 条转红（M1 语料掉档、M2 伪条目、M4 cwd、M5 rc 通道、M7 源级判定放宽）加 1 条诚实未红（M3 clean-cache）；仓库零改动 |
| CI 挂钩 | 不加（`.github/workflows/core-ci.yml` 是浅检出 `fetch-depth: 2` 且没有 `jj`），评估结论见第 5 节 |

---

## 1. Step 1：配方和重建脚本（判据是干净环境跑通后 sha 对允许清单）

```
$ bash tools/baseline/rebuild.sh /tmp/p6t1/base        # rc=0，41s
[1/4] 检出 pinned revision 9bcb7083 到 /tmp/p6-baseline.XXXXXX/src（jj workspace add）
[2/4] 构建（nice -n 19 python3 build_selfhost_native.py）到 === BUILD SUCCESS ===；error[ = 0 行数 = 3
[3/4] sha256 对白名单
  OK corec    5d2b15ad746018619b01143cce400e6f3489ae72a962e12283a7afd3dcdb41e7
  OK corearch 493dc490dfaed7774b46b74ccf1cfeca9fe5f61620e34229afb8991b1628a2a7
  OK corelsp  18b94bd955fa204accf0753095a28f6499871566254d846333a7496c99109d49
[4/4] 拷贝 + 冒烟 到 OK smoke rc=42
$ for b in corec corearch corelsp; do cmp /tmp/p6t1/base/$b /tmp/p6t0/base/$b; cmp /tmp/p6t1/base/$b /tmp/p5t0/base/$b; done
（×6 IDENTICAL，与 T0 重建物及原 /tmp 副本逐字节同）
$ jj workspace list | grep -c p6-baseline-build   到 0（trap 收工 forget + 删目录）
```

结论：配方为 `jj workspace add --revision 9bcb7083` 加 `python3 build_selfhost_native.py`，已经固化且可复现。sha 不符时 `exit 1`（硬检查），允许清单换代纪律写在 `REBUILD.md`，不得通过修改允许清单来对齐失败。

## 2. Step 2：runner 入仓（判据是与迁移 runner 同源同比）

```
$ bash tools/baseline/parity_run.sh /tmp/p6t1/base/corec /tmp/p6t1/parity_repo   # 19s
PARITY DONE：72 档 · rc 分布 34×0 / 38×1
$ bash /tmp/p3t0_run.sh check /tmp/p6t1/base/corec /tmp/p6t1/parity_tmp          # 17s
$ diff -rq /tmp/p6t1/parity_repo/logs /tmp/p6t1/parity_tmp/logs                 # 零输出
```

腿① 主判据（本批首次用入仓 runner 和重建基线执行）：

```
$ diff -rq /tmp/p6t1/parity_repo/logs /tmp/p6t0/parity_start/check/logs   # 零输出（冻结基线 vs 当前二进制）
$ diff -rq /tmp/p6t1/parity_repo/logs /tmp/p5t7/parity_post/check/logs    # 零输出（vs P5 收官记录）
```

与迁移 runner 有两处有意差异，均已落纸：① 影子模式整体剥除（旗标已随 P5 T5 删除，属于死码）；② 使用 `shopt -s nullglob` 加计数断言 72（语料数变化时硬失败，不不报错地缩小覆盖面）。逐档 `clean-cache` 和文件命名继承。

## 3. Step 3：探针语料入仓（判据是两态零差异加与 P5 记录逐条相同）

```
$ cp /tmp/p5t0/probes/*.cr /tmp/p5t3/probes/*.cr tests/probes/ && ls tests/probes/*.cr | wc -l   到 29
$ sha 交叉核（入仓 29 档 vs T0 /tmp/p6t0/probes_manifest.txt）              到 29/29 逐条同（实拷保真）
$ bash tools/baseline/probes_run.sh /tmp/p6t1/base/corec /tmp/p6t1/probes_base   到 29 档 17×0/12×1
$ bash tools/baseline/probes_run.sh ./build/corec        /tmp/p6t1/probes_cur    到 29 档 17×0/12×1
$ diff -rq /tmp/p6t1/probes_base /tmp/p6t1/probes_cur                       # 零差异（rc + 日志）
$ 与 /tmp/p5t7/probes_post：rc 29/29 同；日志 29/29 `cmp` 逐字节同
```

U-4 收口：正式清点是 29 个 `.cr`（`/tmp/p5t0/probes` 11 个加 `/tmp/p5t3/probes` 18 个）。“30”是 29 加一个字面 glob 伪条目（`_tmp_p5t3b_probes_*.cr`，rc=1，log 为 `error: cannot read …/*.cr`；两态恒等，因此该条对拍是空洞的）。`/tmp/p5t3b/probes` 是 T3b 的输出目录（21 个 log 加 6 个 dump），因此 Step 3 没有源重建（T0 第 3.3 节已实测复现其 red 族）。
运行条件写在 README，不假装可以复跑：① 变异态 15 件（`.M{1..4}.log` 加 `.M2.dump`）需要重造变异二进制；② 42 行 shadow 摘要没有二进制可以产生，不得引用；③ 红态复现必须用冻结基线（仍带旗标）。

runner 入仓（`probes_run.sh`，计划外增补）：显式清单加计数断言 29，消除迁移期 runner 的伪条目形态。理由是探针腿只搬语料不搬 runner，证据仍然是空洞的。

## 4. 全量回归和判据（Step 5，全部由本实例实跑）

| # | 判据 | 结果 |
|---|---|---|
| 1 | 五个 CI job（`check`/`bootstrap-tests`/`selfhost-tests`/`suite`/`full-bootstrap`） | 全部 rc=0（16s、无、108s、21 档、无） |
| 2 | 全枚举（51 个 selfhost 加 7 个 bootstrap） | 58/58 rc=0（92s；`/tmp/p6t1/enum.out`，非零 0 行） |
| 3 | `selftest-types` | 404/404 |
| 4 | `check src/compiler` | rc=0（`ok`） |
| 5 | ELF canary | `95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475`（28822B）IDENTICAL |
| 6 | 自举链 | `corec2 == corec3` IDENTICAL（`5559beef2abf…`，2854910B），N06 为 0，冒烟 42，`--help` rc=1 |
| 7 | `test_backend_bootstrap.py` | rc=0 加日志 `error[` 为 0 |
| 8 | 构建确定性 | 五个 job 内多次构建产出同 sha：`corec f737e26b…`、`corearch 544e9201…`、`corelsp 4251108b…`（等于 P5 T7 记录值） |
| 9 | `bash -n src/ci/run.sh` | 语法 OK（本任务唯一的 `src/` 改动是自述块注释） |
| 10 | 改动面自核 | 36 个路径（`src/` 只有 `run.sh`；`src/compiler/checker.cr` sha `fff7a8ba…` 等于 P5 T6 记录值，说明源码零改动） |
| 11 | 并发实查 | 各段开跑前用 `ps -eo comm` 过滤 `python3|corec|corearch|corelsp`，0 命中 |

## 5. Step 4：CI 面评估（结论是不挂钩）

- 决定性证据：`.github/workflows/core-ci.yml:52/79` 使用 `actions/checkout@…` 加 `fetch-depth: 2`（浅检出），工作流内没有 `jj`（grep 实核，命中都是注释或 group 名），因此 pinned revision `9bcb7083` 在 CI 环境不可得。
- 增量实测（供后续批参考）：`rebuild.sh` 41s，72 档对拍 19s，探针 1s。数值虽小，但不解决前置问题。
- 落纸：`run.sh` 自述块写明“手工判据加入仓配方”，不再引用已死的 `/tmp` 路径；`REBUILD.md` 的已知限制有同样说明。

## 6. 突变控制（5 条转红加 1 条诚实未红；仓库零改动）

驱动为 `/tmp/p6t1/mut/`（runner 副本加源级实拷贝 `msrc/`）；回滚面无需处理（仓库外），仓库源码 sha 自核未动。

| # | 突变 | 面 | 实测 |
|---|---|---|---|
| M1 | 语料清单掉一档（注释 `run_one t3 src/compiler/ccr_io.cr`） | runner 覆盖面 | rc=1 加 `CORPUS COUNT 71 != 72` 加 `diff -rq` 报“只在参照中存在：`t3_src_compiler_ccr_io.cr.{log,rc}`” |
| M2 | 撤掉 `nullglob` 加零匹配目录 glob（复现 U-4 形态） | 伪条目 | rc=1 加 `PROBE COUNT 30 != 29`（迁移期形态被抓） |
| M4 | `cd /tmp`（cwd 陷阱） | 路径和覆盖面 | rc=1 加 `CORPUS COUNT 3 != 72` 加缺档 |
| M5 | rc 通道打哑（`local rc=0`） | rc 采集 | 72 档全 0 对比参照 34 档 0、38 档 1，产生 36 个 `.rc` DIFF |
| M7 | 源级：`checker.cr:592` 的 `if e == 0 { return false; }` 改为 `return true`（判定放宽；仓库外实拷贝重建，`corec 527ca428…`） | 腿① 对真实行为变更的敏感度 | 12 档日志加 rc DIFF；rc 分布 39 档 0、33 档 1（5 档从 1 变 0，拒绝不报错地消失），与 P5 T5 M2 同类可抓 |
| M3 | 去掉逐档 `clean-cache`（计划建议的突变面） | 缓存纪律 | 仍然通过（未转红）。`check` 面不读 `.cir` 缓存，本腿检不出。诚实登记；clean-cache 对 `build` 和 `.ccr` 面仍然必需 |

## 7. 执行更正（相对计划文本，逐条落纸）

1. 探针是 29 个而不是 30 个，并且源没有丢（`/tmp/p5t3b/probes` 是输出目录），因此 Step 3 不包含源重建（计划原写的“重建件”不存在）。
2. `probes_run.sh` 是计划外增补（理由见第 3 节）；`tests/probes/*.cr` 源内不加注（逐字节保真优先，来源表写在 README）。
3. 未建 `tests/selfhost/test_baseline_recipe.py`（Step 4 不挂钩 CI，因此没有该套件；枚举计数保持 58）。
4. `run.sh` 的 selfhost-tests 挂点实际是 28 档 py（计划写 14，已陈旧）。本任务未改该计数注（属于 T5 卫生批，避免扩大范围）；本任务对该文件只改 `:70-80` 自述块。
5. `rebuild.sh` 的 sha 硬检查用 `mktemp` 加 `trap` 收工，比 T0 手跑版多两步：忘记 forget 会留下 workspace 残留，已由 trap 兜住。`COREC_REPO_ROOT` 环境变量供突变和异机复用的仓库根覆盖面。

## 8. 提交和改动面

路径限定提交（见提交信息）：`tools/baseline/REBUILD.md`、`tools/baseline/rebuild.sh`、`tools/baseline/parity_run.sh`、`tools/baseline/probes_run.sh`、`tests/probes/`（README 加 29 档）、`src/ci/run.sh`、`TODO.md`、`docs/superpowers/plans/2026-09-14-r2-p6-tail.md`。零二进制入库（允许清单在 `REBUILD.md`）。
本报告在 `docs/archive/sdd/`，属于工作区产物（`.gitignore` 覆盖），不入提交。

## 9. 诚实项（不不报错地）

1. M3 未转红（第 6 节）。计划建议的突变面在本腿不适用，自测齿改由 M1/M2/M4/M5/M7 承担，其中 M7 是源级。
2. M6 中途废弃。本实例尝试“绝对语料加错 cwd”以隔离 cwd 效应，sed 改写不全，7 档命中即被计数检查拦下，结论未采用。M4 已经给出同类红证。登记以免被误读为“跑了 6 条”。
3. 并发窗口：本轮测量期间工作副本只含本任务 36 个路径改动（`jj diff --stat` 与 `checker.cr` sha 双证）。任务尾声 #104/#105/#106（T2/T3/T4a）已置 `in_progress`，因此本报告的判据针对的树状态是 `bc4f0a43` 加本任务改动。后续批如果改源，必须以本任务提交为新起点重取基线（基线纪律）。
4. 未测：CI 环境内的实际可达性（没有远端执行面）；`COREC_WARM_SELF=1` 自源暖态两例（T0 第 8 节第 1 条同样未测）；`probes_run.sh` 在变异二进制下的重跑（依赖重造变异件，见 README）。
5. T0 计划面：T0 未在计划里留“Task 0 实施记录”，其 Step 勾选仍是 `[ ]`（T0 只出报告）。本任务未代改（避免跨任务编辑），建议 T6 收官时补记，本报告只登记该事实。
