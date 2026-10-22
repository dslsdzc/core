# #60 批 T3 报告：判据的暖态腿和入仓定路径探针语料

日期：2026-09-15。任务：#60 批 T3，计划 `docs/superpowers/plans/2026-09-15-warm-cache-diagnostics.md`。
工作地：`/tmp/p7wt`。提交：`227b747e`，父提交 `e0e92eef`，即 T2；路径限定 17 个文件；`jj status` 干净。
二进制：`corec 129d55a6…`、`corearch 22e96d03…`，与 T2 逐字节相同，因此本批零编译器源码改动，构造上没有发射面风险。
纪律：`nice -n 19`，逐段 `ps`，主树零写入，本报告路径已授权除外；CI 和扫描期间不碰源；`ulimit -c 0`；没有 restore/rebase/新 workspace；canary 无豁免；固盘 `/tmp/fct4/t3-state.md`；`/tmp` 剩余 4.9G，大中间物未生成，最大件是 `/tmp/fct4/t3/**`，数十 MB。

---

## 0. 摘要

| 项 | 结果 |
|---|---|
| 入仓语料 | `tests/probes/warm/` 共 7 档，加 README 记录逐档判据。定路径是设计要点 |
| 腿 | `tools/baseline/warm_leg.sh` 两层，加 `warm_run.sh` 自测齿层入口；`parity_run.sh`/`probes_run.sh` 挂广度层，`WARM_LEG=0` 可关闭 |
| 暖态生效档数 | 自测齿层 7/7；parity 广度层 40/72；probes 广度层 15/29。0 表示空洞警报，不可接受 |
| 时长 | 自测齿层 0.9 秒；probes 广度层增加 3.5 秒；parity 广度层增加 125 秒；套件即 CI 最小面 0.5 秒 |
| CI 决定 | 只挂最小面，即 `tests/selfhost/test_warm_cache_gate.py` 10 例，已入 `selfhost-tests`；全量扫描留作手工判据，数字见 §4 |
| 突变 | 4 条：M1 自测齿腿失败；M2 空洞警报；M3 唯一路径导致恒绿，证明定路径是载荷；M4 断言致盲导致缺陷不可见 |
| 判据 | 全部通过，见 §6：canary IDENTICAL；`.ccr` 四条；72 档和探针零差异对 T1；枚举 61/61；五个 CI job 5/5；链 IDENTICAL |

---

## 1. 入仓语料清单（`tests/probes/warm/`，7 档）

| 序号 | 文件 | 形态 | 判据（冷到暖） |
|---|---|---|---|
| 1 | `tu03_load.cr` | 外部指针解引用，读 | rc=1 加 TU03 到 rc=1 加 TU03；暖态 rc=0 即缺陷回归 |
| 2 | `tu03_store.cr` | 同上，写 | 同上 |
| 3 | `tk01_oob_load.cr` | 越界读 `&arr[0] + 1` | rc=1 加 TK01 到 rc=1 加 TK01 |
| 4 | `tk01_oob_store.cr` | 越界写 | 同上 |
| 5 | `tk01_width.cr` | 宽度跨界 `as *[int; 2]` | 同上 |
| 6 | `plain.cr` | 正控 | rc=0 到 rc=0，且条目存在，且二跑真命中，防止腿恒绿空洞 |
| 7 | `alloc_witness.cr` | 见证面，数组字面量加取址，生成期分配复合行 | rc=0 到 rc=0，且本档 `main` 没有条目，符合 T2 见证规则 |

设计要点，定路径：缓存键是 `源路径::函数名`，因此语料必须按入仓路径就地编译。拷到唯一 temp 路径等于结构性无暖态，腿会恒绿，§5 的 M3 已实证。旁面 `tk01_*` 三档走 `g_pts` 和宽度码，每构建重算，不依赖生成期类型行，因此它们本来就不该变脸；绿说明缺陷面被精确固定，T1 E1 有旁证。

---

## 2. 腿设计（和既有 runner 的关系）

实核，决定腿的形态：`check` 面写 0 条缓存条目，`clean-cache` 后 `check`，条目数为 0；`ccr` 面为 15。因此既有两条 runner 的主腿，即 `check` 面，结构上无法表示暖态。处理如下：

- 主腿原样保留。`logs/` 格式和产物不变，与历史基线 `diff -rq logs` 的可比性保持。
- 暖态腿走 `ccr` 面，结果落在 `<outdir>/warm/`，语料清单单一真源为 `<outdir>/corpus.tsv`，由父 runner 生成。
- 分两层：广度层使用父 runner 的 72/29 档，抓广谱暖态回归；自测齿层使用入仓语料 7 档，包含期望值断言。分层理由是既有语料不含 TU03 形态，T1 已实核，因此广度层对 pre-fix 基线预期为绿，M1 二进制实测 72/29 档 FAIL=0。如果把语料和广度混成一腿，冻结基线的用途即同源对拍会被缺陷本体污染。
- 命中口径：只认本档源路径前缀的条目，即 `源路径::函数名`。比较冷跑后和暖跑后的 `size + mtime(ns)`，未变者算真命中。`%y` 精确到纳秒，同秒重写不会误判为命中。

---

## 3. 暖态生效档数和时长（实测，2026-09-15 本机）

| 腿 | 档数 | 暖态生效（至少 1 次真命中） | FAIL | 时长（含 `/usr/bin/time` 级实测） |
|---|---|---|---|---|
| 自测齿层 `warm_run.sh` | 7 | 7 | 0 | 0.9 秒 |
| parity 广度层 | 72 | 40，其余 32 档 0 条目，属于早失败或负例档 | 0 | 增加 125 秒，主腿约 25 秒变为 150 秒 |
| probes 广度层 | 29 | 15 | 0 | 增加 3.5 秒，主腿约 1 秒变为 4.5 秒 |

暖态生效为 0 就是空洞警报，腿绿但根本没有走到暖态。M2/M3 两条突变的读数见 §5。

---

## 4. CI 挂钩决定（决定和时长）

决定：只挂最小面，不挂全量。依据如下：

1. 最小面是 `tests/selfhost/test_warm_cache_gate.py`，10 例，就地编译入仓语料，0.5 秒。T2 已入 `selfhost-tests`，本 T3 只把它重写为“语料入仓加就地编译”，并补 `build` 面同判、见证选择性、正控真命中。覆盖率和自测齿层同语料同判据。
2. parity 广度层增加 125 秒，72 档乘 2 次 `ccr`，以大文件为主，在 CI 中性价比低。probes 广度层增加 3.5 秒，虽然便宜，但与套件同语料，没有新增覆盖。
3. 与计划一致：全量扫描留作手工判据，`tools/baseline/REBUILD.md` 已载用法和预期。

---

## 5. 突变 4 条（逐条实证腿的载荷性）

| 序号 | 突变（脚本或二进制） | 期望 | 实测 |
|---|---|---|---|
| M1 | 去见证，`mut1 = ba89c21a…`，即 pre-fix 行为 | 自测齿腿失败 | FAIL=2：`tu03_load`/`tu03_store`，冷态 rc=1 加 TU03 到暖态 rc=0 不报错地；腿部 rc=1，通过 |
| M2 | 不变量过宽，`mut2 = da492699…`，恒不落盘 | 无缺陷但腿成空洞 | FAIL=0，且暖态生效 0，构成空洞警报。M2 二进制下自测齿腿 rc=0，通过 |
| M3 | 唯一 temp 路径，突变版腿在暖跑前先 `cp` 到随机路径 | 缺陷在场仍恒绿 | FAIL=0，且暖态生效 0，证明定路径是载荷设计，通过 |
| M4 | 断言致盲，突变版腿在比较前执行 `rc2=rc1; c2=c1` | 缺陷不可见 | FAIL=0，M1 二进制在场，说明断言本身是载荷，通过 |

M3/M4 的突变脚本在 `/tmp/fct4/t3/{mut_vacuous.sh,mut_blind.sh}`，不入仓。入仓的是干净腿。二者的构造是对入仓腿的两处最小改写，报告内已给出改法，可以复现。

---

## 6. 判据全套（本 T3 实跑）

| 判据 | 实测 | 基线 | 判定 |
|---|---|---|---|
| ELF canary（硬性判据，无豁免） | `95084e7b…d475`（28822B） | 相同 | IDENTICAL |
| `.ccr` 四条（冷态） | 96015 `680a6f98…`、96158 `76f36e6a…`、142793 `41e9d845…`、142936 `704316c8…` | 相同 | 通过 |
| `--dump-objects` / `.cir` DOT | 3521 行 / 165915B `b1bdf480…` | 相同 | 通过 |
| `selftest-types` / `check src/compiler` | 415/415 / rc=0 | 相同 | 通过 |
| 72 档同源对拍 | 34 个 0、38 个 1，`diff -rq logs` 对 T1 为 0 行 | 相同 | 通过 |
| 探针 29 档 | 17 个 0、12 个 1，对 T1 零差异，排除 T3 新增产物 `warm/` 和 `corpus.tsv` | 相同 | 通过 |
| 自测齿腿 | 7 档，暖态生效 7，FAIL=0 | — | 通过 |
| 全枚举 | 61/61，非零 0；`test_warm_cache_gate` 10/10 | T2 为 61 | 通过 |
| 五个 CI job | check、bootstrap-tests、suite、selfhost-tests、full-bootstrap 5/5 rc=0 | 相同 | 通过 |
| 自举链 | `corec2 == corec3` 为 `006e58e1…` IDENTICAL，N06=0，冒烟 42，`--help` rc=1 | 相同 | 通过 |

---

## 7. 登记和边界（不猜）

1. 广度层对 pre-fix 二进制预期为绿，M1 实测 72/29 档 FAIL=0。它的价值是广谱未来回归，不是复现本缺陷。自测齿层才是缺陷面的判据。两层的预期值已写入 `REBUILD.md`，避免误读为“基线不合规”。
2. `check` 面没有暖态，0 条目，本批已实核。这是腿必须走 `ccr` 面的原因，也证伪了“runner 加二跑就够”的想法：只加二跑而不换面，就是恒绿空洞。
3. 本批零编译器源码改动，`corec` sha 与 T2 逐字节相同，因此 canary、四条、dump、cir 的“同值”是构造性的，仍逐项实测，见上表。
4. `/tmp` 侧未入仓的两件：M3/M4 突变脚本，构造已载本报告；`/tmp/fct4/t3/**` 原始证据，是判据件。
5. 自纠，如实登记：① 腿首跑把快照取在冷跑前，得到条目 0 的假读数，已修；② M3 首版 `$RANDOM` 用了两次，`cp` 和 `f` 指向不同文件，出现假红，已修；③ M3 首跑没有重定向 stdin，广度层 `read` 挂起 10 分钟，已 kill 重跑，不是产品问题。三件都不影响最终读数，修正后重跑全量。
6. 未决：(c)/(d)，即快照表示类型行，依维护者裁定本批不实施。挂了两个可证伪触发条件：未判面构造出暖态消费者，或命中率成为瓶颈。触发后先试“加一行见证”的廉价路径，已写入 TODO #60。
7. CI 面未挂腿本体。`warm_leg.sh`/`warm_run.sh` 只手工运行，并由判据脚本调用。如果日后要挂，自测齿层 0.9 秒可以直接进 `selfhost-tests`，与套件覆盖重叠，收益是校验 runner 自身。

---

## 8. 证据路径

| 用途 | 路径 |
|---|---|
| 本报告和状态盘 | `docs/archive/sdd/warm-task3-report.md`、`/tmp/fct4/t3-state.md` |
| 判据全套 | `/tmp/fct4/t3/final/**`：`pa`、`*.ccr`、`gt_do.txt`、`gt.cir`、`parity_t3/**`、`probes_t3/**`、`warm_corpus/**`、`enum/**` |
| 腿两态对照 | `/tmp/fct4/t3/{parity_cur,parity_m1,probes_cur,probes_m1}/warm/**` 加 `leg_*.out` |
| 突变 | `/tmp/fct4/t3/warm_{curb,m1b,m2b,m3b,m4}/**`、`mut_vacuous.sh`、`mut_blind.sh`、缺陷二进制 `mut1=ba89c21a…` / `mut2=da492699…` |
| 时长 | `warm_leg`/`parity_cur.out`/`probes_cur.out` 的 `time` 输出，报告 §3 |
| 语料入仓 | `tests/probes/warm/`，7 个 `.cr` 加 `README.md`；腿为 `tools/baseline/{warm_leg,warm_run,parity_run,probes_run}.sh` 加 `REBUILD.md` |
