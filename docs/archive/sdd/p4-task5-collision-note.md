# P4 Task 5 并发碰撞记录（第二实例 `p4-task5b` 的只读交付，2026-09-13）

本文件由第二个 p4-task5 实例（`p4-task5b`）撰写，只登记不与对方冲突的独立测量，以及对 `@` 未提交文件的只读判断。
本实例接到 lead 的“resume”指令时，原 agent 仍然活着：它已经在 04:02:33 提交 `2be26cc5`，并在 04:03:54 和 04:04:35 继续修改两个文件，04:10:45 起重跑 corec2/corec3 链。
本实例发现碰撞后停止全部构建（`ci_all.sh` 已 kill），未提交，未写任何仓库文件（本文件除外）。

采用的独立基线由本实例自建，对方未使用：`/tmp/p4t5_base/build/{corec,corearch}`。做法是用 `jj file show -r 387abf2e` 取回 4 个源文件（`ir_gen.cr`/`globals.cr`/`main.cr`/`instr.cr`）到 `387abf2e` 内容，其余同 `@`，再用 `build_selfhost_native.py` 全量构建（rc=0）。这个二进制度量的是“修复前”的一手证据，可以复用。

---

## ① 重叠测量清单（本实例自测，不引用对方报告）

| # | 项 | 命令 | 结果 | 采数时刻 | 用的二进制 |
|---|---|---|---|---|---|
| 1 | 构建 | `nice -n 19 python3 build_selfhost_native.py` | rc=0（三面 `[GUARD] … log clean`） | 04:01:50 到 04:03 | 无 |
| 2 | 自源检查 | `./build/corec check src/compiler` | rc=0（`ok`） | 约 04:04:5x | `build/corec`@04:02 |
| 3 | 类型引擎自测 | `./build/corec selftest-types` | 355/355 | 约 04:04:5x | `build/corec`@04:02 |
| 4 | 可选套件 | `python3 tests/selfhost/test_optional.py` | 32/32（当时 `len(ok)=32`） | 约 04:04:1x | `build/corec`@04:02 |
| 5 | 自举回归 | `python3 tests/selfhost/test_backend_bootstrap.py` | rc=0（11 条 `[PASS]` 全部通过） | 约 04:04:3x | `build/corec`@04:02 |
| 6 | ELF canary | `clean-cache`，然后 `build tests/suite/ptr_arith.cr -o /tmp/pa_p4t5 --static` | `95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475`，IDENTICAL（与 T4 记录值相同） | 约 04:04 到 04:05 | `build/corec`@04:02 |
| 7 | `.ccr` 面 | `ptr_arith` 冷热两态，基线和新各一份 | 冷态 `592afa31d66cc75a…`（90966B）两侧逐字节相同；热态 `16996f1c95f6143…`（90769B）两侧逐字节相同。因此本任务对非可选程序的 `.ccr` 零字节变化。冷热不同（差 125 instr，头 24B 处）是预存问题，基线也得到同样两个值，TODO #5 第二实例已登记 | 约 04:05 | 两个编译器 |
| 8 | CI job（3/5） | `CI_JOB_NAME={bootstrap-tests,check,suite} bash src/ci/run.sh` | bootstrap-tests 3/3，check ok，suite ALL PASS | 04:05 到 04:12 | 见 ② |
| 9 | 第 5 个根因独立对照 | 全局可选槽 `g : int? = Some(5)` / `= None`，基线和 新，双路径 | 基线得到 ELF 0 / interp 5，以及 ELF 0 / interp 9，属于不报错地双路径分歧；新得到 5/5、9/9 | 约 04:2x | `/tmp/p4t5_base` 加 `build/corec`@04:06:55 |

### B.7 四形态 before/after（双路径，本实例逐形态实测）

| 形态（源见 `/tmp/p4t5/{a_some,b_wild,c_payload}.cr`） | check | build | 修复前 ELF / interp | 修复后 ELF / interp |
|---|---|---|---|---|
| (a) 裸值加 `Some` 臂（B.7 最小复现） | 0（零诊断） | 0 | 139 / 139 | 5 / 5 |
| (b) 裸值加纯通配臂（不得回退） | 0 | 0 | 7 / 7 | 7 / 7 |
| (c) 正控 `Some(9)` 加 `Some` 臂（真载荷） | 0 | 0 | 9 / 9 | 9 / 9 |

“修复前”是 `/tmp/p4t5_base/build/corec`，本实例从 `387abf2e` 重建，与 03:04 那批旧探针二进制 `a_some`=139、`b_wild`=7、`c_payload`=9 独立吻合，也与 B.7 登记表吻合。
“修复后”是 `build/corec`@04:02，内容等于已提交态 `2be26cc5`。

---

## ② 采数窗口和并发污染标注

- 04:12 之前没有并发构建者。可查证的对方活动起点是 04:05:31（detached orphan，ppid 1，运行 `bash /tmp/p4t5/enumerate.sh`）和 04:10:45（活会话 zsh，运行 `corec2` 到 `corec3` 链）。
- 干净数据（本实例独占，可以直接采信）：#1 到 #7 以及 B.7 表全部。这些都在 04:05 前采集，`build/corec` 的 mtime 证明当时用的就是本实例 04:02 建的二进制。
- 并发窗口 04:05 到 04:12：#8 的三条 CI 日志。这个窗口内，对方 orphan 在跑全枚举（多套件并发），我和对方都会重建 `build/corec`。三条结果都是绿的，但“哪个二进制跑出了绿”无法归因，只能当弱证据，需要对方收官复跑。
- 未完成（本实例 kill，无结果）：`full-bootstrap`（04:10 起，cmp、N06、冒烟 42 都未由本实例复现）、`selfhost-tests`、全枚举 54/54、同源语料对拍（脚本已备好未跑：`/tmp/p4t5/corpus.sh`，`/tmp/p4t5/mine_ci_*.log` 是上述日志）。
- 另一条不冲突的强证据：04:06:55 的 `build_selfhost_native.py`（CI check job 内）在 `@` 的未提交态上构建成功，说明未提交改动可以编译，见 ③。

---

## ③ 对 `@` 两个未提交文件的只读判断（供 lead 决定是否保留）

`jj status`：`M src/arch/x86_64/instr.cr`（净 +5/−1），`M tests/selfhost/test_optional.py`（+10）。改动看起来是完整改动，不是半成品。判断依据如下。

### （A）`instr.cr` 的 `IR_LOAD_ENUM_TAG` 源侧改走 `e2_load_var`

改动是 `cp += e2_ld(buf, pos+cp, 10, o1)` 改为 `cp += e2_load_var(buf, pos+cp, 10, s1)`。
自洽且最小：`e2_load_var` 对非全局源恰好返回 `e2_ld(…, g2_slot(v))`，逐字节同编码，因此没有全局枚举 scrutinee 的程序发射面零变化（canary 按构造应当 IDENTICAL）。对全局源，它发 RIP 相对 lea 加 mov，并记录 `g_x86_rip_patch_*`，与 `IR_LOAD`/`IR_STORE` 相同，Phase 3 回填。因此这个方向是修根因，不是绕开问题。
必要性已由本实例独立证实，不依赖对方数字：无表位全局槽加装箱值时，基线为 `ELF=0 / interp=5` 和 `ELF=0 / interp=9`，属于不报错地双路径分歧，比崩溃更坏。加上该改动后为 5/5、9/9。如果丢弃，这个面会回到未登记的不报错地默认值。原报告第 4 节只登记了“全局槽裸值形态”，没有登记这组装箱分歧。
残留问题都是小面，不阻塞：① `o1 := g2_slot(s1)` 变成死绑定（直接使用 `s1`），属于清洁性问题；② 目的槽仍走 `g2_slot(d)`（全局目的行没有分派），改动注释自称“当前零发射点”，该说法对编译器自产 IR 成立，但对用户代码本实例没有穷举验证；③ `e2_load_var` 没有 `sz_load_var` 那样的 `v < g_ir_var_count` 守卫，与既有 `IR_LOAD`/`IR_STORE` 用法一致，不是新风险。
保留所需（由对方或 lead 决定）：canary、`.ccr`、全枚举、自举链复跑，本实例未跑。

### （B）`tests/selfhost/test_optional.py` 增加 2 例

追加 `uncovered_global_boxed_ok`（期望 5）和 `uncovered_global_none_ok`（期望 9），都使用既有的 `case_dual` 助手。形态自洽，与 (A) 的行为一一对应，本实例实测 5/5、9/9 吻合。
唯一未完成的是计数同步：`len(ok)` 现在是 34，但 `src/ci/run.sh:88` 注释仍写“= 32 例”，`docs/archive/sdd/p4-task5-report.md` 第 5-5 节和第 8 节也仍写 32/32 与 12 到 32。保留则必须同步，属于纯注释和文档面。这两例也是“全局槽”面唯一的运行时钉子。
采信前提同 (A)：套件本身本实例按 32 例跑过（32/32），34 例版未复跑。

一句话结论：两份改动是同一根因（全局行分派缺失）的一对完整收口，包含后端修复和用例钉子。缺口只在判据复跑和三处计数同步。丢弃会留下一个未登记的不报错地错值类。

---

## 附：本实例留下的可复用资产（均不占仓库）
- `/tmp/p4t5_base/`（pre-Task-5 全量工具链，`387abf2e` 语义）和 `/tmp/p4t5_base/src/`（四个文件的旧版）。
- `/tmp/p4t5b/{gbox,gnone}.cr` 及其基线和 新二进制（③-A 的对照证据）。
- `/tmp/p4t5/corpus.sh`（同源语料对拍脚本，未跑）、`/tmp/p4t5/mine_ci_*.log`（第 ② 节的日志）。
