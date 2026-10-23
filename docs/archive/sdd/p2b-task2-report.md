# R2 P2b 任务 2 报告：`iface_kind_of` 单一来源，桥接分派（`sh_native_ak`/`sh_base_ak`）与注册表合一

状态：完成（DONE）

提交：`31143cd0`（change `unplyusqz…`），提交信息 `refactor: R2 P2b Task 2——iface_kind_of 与桥接分派（sh_native_ak/sh_base_ak）单源化（全表对拍 + 负控探针实证零行为变化）`。路径限定为 4 个：`src/compiler/ty_shadow.cr`（31 行）、`src/compiler/type_selftest.cr`（51 行）、`src/compiler/iface_registry.cr`（15 行，只改注释）、`src/ci/run.sh`（2 行，同步用例数）。共 91 insertions、8 deletions。

计划：`docs/superpowers/plans/2026-09-11-r2-p2b-iface-ops.md` 的任务 2。

接手说明：前序 agent 因 API 错误中断。其 WIP（`ty_shadow.cr` 的委托和 legacy 拷贝）经复核与计划的 Interfaces 段逐字一致，两个门都显式保留，legacy 是字面拷贝，因此予以保留。本次补完对拍用例、反真空哨兵、全部判据（包括计划未列的负向对照）和提交。

## 1. 交付物和落点（file:line，实测）

| 交付物 | 落点 |
|---|---|
| 桥接入口改为简单转发 | `src/compiler/ty_shadow.cr:72-76`。`sh_native_ak` 的两个门原样保留：`ti < 0` 返回 -1，`get_type_kind(ti) != TYP_BASE` 返回 -1；末行 `return iface_by_ty_code(get_type_data(ti))`。`:87-89` 的 `sh_base_ak` 全部函数体为 `return iface_by_ty_code(ty)`。签名原样保留，因为影子证据链的可比性依赖调用点不变 |
| 对照物（字面拷贝，P5 删除） | `ty_shadow.cr:91-113` 的 `sh_native_ak_legacy` 和 `sh_base_ak_legacy`。改动前的实现逐字保留，生产路径零调用，只被 `type_selftest.cr` 引用 |
| 单一来源注记（桥接侧） | `ty_shadow.cr:27-31` 的文件头，以及 `:74-78` 的显式警告：不得把 `sh_native_ak` 换成 `iface_kind_of` |
| 单一来源注记（注册表侧） | `iface_registry.cr:164-166`，说明 `iface_by_ty_code` 是唯一实现；`:184-189` 是任务 2 的边界注：`sh_native_ak` 不调用 `iface_kind_of`，“单一来源”指共用同一张 TY 码逐项分派表，不是语义合并 |
| 对拍用例（7 个，138 变为 145） | `type_selftest.cr:569-618`：① `iface.by_ty_code_all_codes` 在 `:588`；② `iface.native_ak_all_rows` 在 `:597`；③ `iface.scan_coverage` 在 `:601`；④ `iface.compare_is_live` 在 `:604`；⑤ `iface.bridge_delegates` 在 `:607`；⑥ `iface.bridge_gate_kept` 在 `:613`；⑦ `iface.dispatch_no_index_shortcut` 在 `:617` |
| 用例数同步 | `src/ci/run.sh:71`，138 例改为 145 例，`P2b-T1` 改为 `P2b-T1/T2` |

范围检查：本任务只改映射的存放位置，不改变任何判定结果，对应计划的“保语义等于零行为变化”。没有顺便收紧或放宽任何格，没有改动 `iface_kind_of` 语义，没有改动注册表数据，没有改动 `ops` 位集（仍为空集）。

### 1.1 复核过的 WIP 事实（两处判据）

- `sh_native_ak` 不是 `iface_kind_of` 的别名。前者对 `TI_DYN` 行（kind 为 `TYP_DYN`）和全部结构、命名行返回 -1，DYN 走 `sh_term_of_ti` 的 `TYP_DYN` 分支；后者对同样这些行返回 `AK_DYN` 或对应的类。计划的 Interfaces 段明确要求“委托必须显式保留该门”，WIP 已保留，并用 `iface.bridge_gate_kept` 固定该行为。
- `iface_by_ty_code`（`iface_registry.cr:168-179`，任务 1 实施）与 `sh_base_ak_legacy`（`ty_shadow.cr:102-113`）逐项比对：9 个 `TY_*` 分支加 `-1` 后备的次序和取值完全相同，包括 `TY_DEX_S` 到 `AK_DEX`、`TY_GENERIC_PARAM` 到 `AK_NAMED` 两条已裁决的灰格。因此委托替换是恒等替换。

## 2. 判据（命令和结果，逐条）

| # | 判据 | 命令 | 结果 |
|---|---|---|---|
| 1 | 自举构建 | `nice -n 19 python3 build_selfhost_native.py` | rc=0；3 条 `[GUARD] … build log clean (error[ = 0, undefined = 0)`；`=== BUILD SUCCESS ===`（corec、corearch、corelsp） |
| 2 | 自测用例表 | `nice -n 19 ./build/corec selftest-types` | 145/145，零 FAIL，rc=0。基线 138，增加 7 例；计数变化已同步到 `run.sh:71` |
| 3 | ELF 逐字节 | `clean-cache`，然后 `build tests/suite/ptr_arith.cr --static -o /tmp/pa_p2b2`，再 `sha256sum` | `95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475`，IDENTICAL，等于计划要求的定值；与 `/tmp/pa_p2b2_base` 逐字节 `cmp` 相同。共复测 4 次，包括负向对照前后，结果恒同 |
| 4 | `.ccr` 逐字节（冷缓存，4 个语料） | 逐文件 `clean-cache`，然后 `ccr <f> -o …`，再与改动前基线 `/tmp/p2b2_base/ccr/` 做 `cmp`，基线由前序 agent 的冻结二进制产生 | 4/4 IDENTICAL：ptr_arith `ecd7a9df…`、at_test_struct `891377232b…`、generics_test `35cf0f26…`、dyn_test `dfb82d2b…`，与基线 sha 逐字相同 |
| 5 | 诊断零变化（语料至少 20 个） | 对 32 个 `tests/suite/*.cr` 逐个 `check`，用 `>|` 把 stdout、stderr 和 rc 写入磁盘，共 64 个文件 | `diff -r` 逐字节相同，对照的是改动前二进制和改动后二进制，源码相同。方法见第 3 节 |
| 6 | 回归 | `test_compile.py`、`test_purity.py`、`test_ccr_v7.py`、`test_type_engine.py`、`test_lsp.py` | 全部通过：PASS、PASS、27/27、PASS、ALL PASS（10 tests）。包括 P2a 评审 Critical 的 `test_double_open_bridge_cache_reset`，计划步骤 3 点名 |
| 7 | 影子语料（计划步骤 3） | 71 个文件 × `check --type-shadow --type-shadow-dump`，每档开始前 `clean-cache` | summary.tsv 和全部 dumps 逐字节相同，两个编译器同源对拍：`agree=28430 / decisions=28430 · old_stricter=0 · old_looser=0 · unknown=0 · unknown_bridge=0 · unknown_engine=0 · unknown_engine_budget=0 · unknown_engine_uncovered=0 · replace_bridge=0 · replace_unknown=0`。站点直方图为 `assign-node=21333 · fn-body-ret=5113 · if-branch=1950 · struct-field-type=28 · array-elem-type=4 · generic-apply-base=2 · assign-binary=0 · generic-arg=0 · hotpatch-ret=0 · unify-fallback=0` |
| 8 | 负向对照探针（计划未列，本报告自加，见第 4 节） | 把 `iface_by_ty_code` 的 `TY_BOOL` 钳位成 `AK_STRING`，重建后跑 selftest | 失败：`iface.by_ty_code_all_codes: got 1 want 0`、`iface.native_ak_all_rows: got 1 want 0`、`iface.bridge_delegates: got 0 want 1`，另有 3 条 P1 既有用例连带失败。复位后 145/145，ELF 哈希复原 |
| 9 | 注释面零泄漏（自加） | 改完 `iface_registry.cr` 和 `run.sh` 的注释后重建 | `build/corec` 和 `build/corearch` 与改前快照 `cmp` 逐字节相同，注释不进入 AST 或二进制 |
| 10 | 提交边界 | `jj commit -m … <4 路径>` | `jj show --stat` 只包含我的 4 个路径、91 insertions。`tests/suite/*.out` 和 `*.rc` 共 64 个捕获 scratch 未入库，`jj file list -r 31143cd0 | grep -c '\.cr\.\(out\|rc\)$'` 为 0，这些文件仍留在工作副本 |

## 3. 判据方法：为什么用同源双编译器对拍，而不是与历史基线比数字

前序 agent 的基线（`/tmp/p2b2_base*`）是改动前的编译器运行改动前的源码。我的改动包含 `type_selftest.cr` 新增的 36 行用例，而 `type_selftest.cr` 被 `_import.cr` 传递 import，因此 `check src/compiler/{main,_import,ccr_io}.cr` 的输入变大，影子判定数自然上涨。实测核对如下。

- 前基线，改动前二进制运行改动前源码：`decisions=28370`。
- 我的首轮，改动后二进制运行改动后源码：`decisions=28430`，增加 60。
- 差值全部落在 3 个文件：`main.cr` 从 4473 变为 4493，`_import.cr` 从 4351 变为 4371，`ccr_io.cr` 从 4684 变为 4704。各增加 20，即 assign-node 增加 18、fn-body-ret 增加 2，与本任务新增的 7 条 `ts_check` 语句量吻合。其余 68 档逐字节不动。
- 决定性实验：把改动前的二进制（`/tmp/p2b2_base_bin/corec`）运行在当前源码上，产出与改动后的二进制完全一致，第 2 节第 5 项和第 7 项的 `diff -r` 全为空。

因此结论是：增加的 60 全部由输入增长解释，判定面零变化。为避免误导，本报告不复用计划书沿用的 findings 第 11 节旧值 26989。该口径与前后两个基线都不符，前基线本来就是 28370，这里如实登记。

## 4. 负向对照探针（本报告自加的因果证明，计划未列）

“全表对拍”的两个用例是本任务的判据本体，必须证明它们不是没有实际执行。

1. 常态哨兵（永久用例）：`iface.scan_coverage`，码面 10 个键全部扫描，并用 `r64` 回读校验；行面恰好等于 `g_type_count` 且至少为 9。`iface.compare_is_live` 对一对已知不相等的值必须报告不相等。这两个用例防止循环没有运行或比较退化造成的虚假通过。
2. 钳位探针（临时，已复位）：把 `iface_registry.cr` 的 `TY_BOOL → AK_BOOL` 改成 `→ AK_STRING`，只改一行，带 `PROBE` 标记。重建后 selftest 报告 137/145，恰好是 `by_ty_code_all_codes`、`native_ak_all_rows`、`bridge_delegates` 等 8 个用例失败，两张对拍表在码面和行面各捕获 1 处失配。复位后 `jj diff src/compiler/iface_registry.cr` 为空，字节级确认无残留；selftest 回到 145/145，ELF 哈希复原，`build/corec` 与探针前的构建产物行为一致，重跑第 2 节第 5 项和第 7 项的整轮对拍仍然全空。
   - 纪律说明：该探针是本 agent 自己写入并立即撤销的临时改动，不是还原既有工作。仓库已有先例是“钳位最小实验单独证明因果”。复位证据是空 diff 加哈希复原。

## 5. 未决和交接

1. `sh_*_ak_legacy` 属于临时对照物，计划明确记录“P5 删除”，已按计划登记意图。TODO #24 的 P5 继承项条目没有由本任务改写。计划说“登记入 TODO #24”，如果需要在 `TODO.md` 中显式落一条，请协调者裁决。本任务未动 `TODO.md`，保持提交路径限定。现状是 legacy 两个函数零生产调用，只在 `type_selftest.cr:585` 的码面、`:594` 的行面、`:605` 的活性哨兵三处引用。
2. `tests/suite/*.cr.out` 和 `*.cr.rc` 共 64 个，未跟踪，是前序 agent 的语料捕获 scratch，未入库，已核对。本任务的等价对拍改用 `/tmp/p2b2_t2*` 写入磁盘，没有再污染工作副本。这 64 个文件仍留在工作副本，建议后续任务收尾时统一清理或加入忽略。本任务未删除，因为不是本任务创建的产物，删除需要明确许可。
3. `src/ci/run.sh:71` 的用例数同步，138 改为 145。这属于注释内计数。如果 P2b 任务 3、4、5 继续增加用例，该处需要继续同步。`test_type_engine.py` 本身只断言 `passed == total && total >= MIN_CASES`，不固定具体数字。
4. 计划步骤 3 的“71 文件、26989、agree 26989”：本批实测为 28430，同源对拍恒等，见第 3 节。26989 和 28370 都已无法在当前口径复现，findings 第 11 节时点更早。如果后续任务需要基线数字，请以本次 `31143cd0` 的 `/tmp/p2b2_t2b` 产物或“同源双编译器对拍为空”为准。
