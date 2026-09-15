# 判据载体化批（criteria-carrier）：ELF canary + `.ccr` 四条 = 机器闸门

**日期**：2026-09-16 · **状态**：T0 侦查已实测落纸 → T1/T2/T3 实施中（**本批零构建**；
凡「实测」均标出处，凡需二进制者标「待实测（等构建槽）」）

**缘起（已实核）**：一份只读审计发现并经复核——ELF canary sha
`95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475`（28822B）与 `.ccr`
四条锁定值（96015 `680a6f98…` / 96158 `76f36e6a…` / 142793 `41e9d845…` / 142936
`704316c8…`）**在本仓 `*.py` / `*.sh` / `*.cr` / `*.toml` / `*.yml` 里命中数为 0**——
它们只活在 `docs/` 与 `.superpowers/` 的文字里，**零自动化载体**：每个批次的提交信息都在
引用它们，但那是**人工/代理手跑**的结果，不是机器闸门。同类事故本仓已发生过一次
（`test_backend_bootstrap.py` 自称已挂 CI 而 `run.sh` 零命中 ⇒ `error[N06]` 跨 5 任务 33 次
静默漏检，见 `src/ci/run.sh:72-73` 与 `tests/harness/test_ci_hook_coverage.py`）。本批把这一课
升一层：**把最常被引用的两条判据变成机器闸门**。

---

## 1. 配方（**唯一被许可的产生方式**；逐条含出处）

### 1.1 ELF canary

| 项 | 内容 |
|---|---|
| 语料 | `tests/suite/ptr_arith.cr`（15 行；`tests/suite/ptr_arith.cr:1-15` 实读） |
| 命令 | `clean-cache` → `build tests/suite/ptr_arith.cr --static -o <out>` |
| 判据 | sha256 `95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475` · 28822B |
| 出处 | `docs/superpowers/plans/2026-09-16-global-operand-seams.md:325`（本批在途计划）· `docs/superpowers/plans/2026-09-15-fail-closed-diagnostics.md:101` · `docs/superpowers/plans/2026-09-12-r2-p4-carrier.md:74` |
| 可执行原文 | `/tmp/capt1/t1b_criteria.sh:34-38`（`$CC clean-cache` → `$CC build tests/suite/ptr_arith.cr --static -o "$O/pa"` → `sha256sum` + `stat -c 'size=%s'`，并打印期望值） |

**口径限制**：canary 覆盖 = **该一档语料的发射面**。它是「发射面零泄漏」证据，**不是**新语义
正确性证据（`plans/2026-09-12-r2-p4-carrier.md:74` 明文：该语料对类型层不敏感）。

### 1.2 `.ccr` 四条（两语料 × 两口径，冷态）

| 名 | 语料 | 口径（命令） | sha256 | 字节 |
|---|---|---|---|---|
| `pa_ccr` | `tests/suite/ptr_arith.cr` | `clean-cache` → `ccr <src> -o <D>/pa.ccr` | `680a6f9843747b521213c3bcca1cf8724657943410f182e97ed63dcc11c7cd7a` | 96015 |
| `pa_static_ccr` | 同上 | `clean-cache` → `build <src> -o <D>/pa_st.bin --static`（产物 = `<D>/pa_st.bin.ccr`） | `76f36e6a6b6eb2f18fa5541550d09e5e73bb0e8dfc7df2ebbe3d747c382f329c` | 96158 |
| `gt_ccr` | `tests/suite/generics_test.cr` | `clean-cache` → `ccr <src> -o <D>/gt.ccr` | `41e9d84578ce2ca41934373ec0f96a2ec53e04422509147e05324b122e9f77eb` | 142793 |
| `gt_static_ccr` | 同上 | `clean-cache` → `build <src> -o <D>/gt_st.bin --static`（产物 = `<D>/gt_st.bin.ccr`） | `704316c81aecd6ad9ce7f04417ec9a786243b74df62e8178e8a2bc064132f1cb` | 142936 |

**出处（配方原文）**：`.superpowers/sdd/cap-task1-report.md:82`——
`| 8 | .ccr 两口径四条（冷态） | ccr F -o O / build F -o O --static（各 clean-cache；static 取 O.ccr） | … |`。
**可执行原文**：`/tmp/capt1/t1b_criteria.sh:41-53`（四条逐条 `clean-cache` 前置 + `cp "$O/pa_st.bin.ccr" "$O/pa_st.ccr"`）。
**值来源**：`.superpowers/sdd/p6-task3-report.md:62`（P6 T3 **重锁**：`delta = 4B × 节点数`，pa +5192 = 4×1298 · gt +7452 = 4×1863）+ `.superpowers/sdd/p6-task4-report.md:81`（P6 T4 复验「四条逐字节同」）。

**口径限制（三条，逐条实测）**：
1. **必须 `clean-cache` 前置且逐条独立**——`clean-cache` = `rm -rf .core/cache/cir/`
   （`src/compiler/main.cr:408-414` 实读），**相对 cwd** ⇒ 本载体必须 `cd` 仓库根
   （记忆 `judgment_run_traps`：cir 缓存跨重建不失效、cwd 决定 import 解析）。
2. **两口径不可互推**：`ccr` 口径与 `build` 口径的 `.ccr` **内容不同**（差恒 143B）。本实例
   解码段表实测（`/tmp/capt6/{pa.ccr,pa_st.ccr}`，下表）：差异**只在 STR 段 +79B 与 SYM 段
   +64B**，NOD/ENT/REG/EDG/TYPE/IFACE 六段尺寸逐字节相同。
   ⇒ 143B 是**接口面语义差**（`build` 路径在 `save_ccr` 前多 intern 了串/sym），
   **不是** 输出路径长度差（见下条）。
3. **与输出路径无关（关键，实测）**：同一逻辑产物写入三个互不相同的输出目录、跨越三批、
   三次采集，四条 sha **逐条相同**——
   `/tmp/capt1`（2026-09-14，容量批 T1）· `/tmp/capt6`（2026-09-16，全局 seam 批在途）·
   `/tmp/fct3`（2026-09-15，fail-closed T3）。⇒ 本闸门在 CI（任意临时目录）可复现。

| 段（tag） | pa `ccr` 口径 | pa `build` 口径 | 差 |
|---|---|---|---|
| STR(1) | 1711 | 1790 | **+79** |
| SYM(2) | 6452 | 6516 | **+64** |
| NOD(3) | 51924 | 51924 | 0 |
| ENT(4) | 23020 | 23020 | 0 |
| REG(5) | 2068 | 2068 | 0 |
| EDG(6) | 9028 | 9028 | 0 |
| TYPE(7) | 1248 | 1248 | 0 |
| IFACE(8) | 452 | 452 | 0 |
| **合计** | 96015 | 96158 | **+143** |

（段表解码 = 本实例实跑：头 16B（`CCR1` magic + version 9 + seg_count 8 + 保留），
随后 8×12B `{tag u32, offset u32, size u32}`，与 `src/compiler/ccr_io.cr:32-36` 头注一致。
版本真源 `ccr_io.cr:135` `CCR_VERSION = 9`。）

### 1.3 起点值现状（**待实测（等构建槽）**）

四条 + canary 的**最近一次**同源实测 = 在途批计划
`docs/superpowers/plans/2026-09-16-global-operand-seams.md:325-326`（该批声明 canary 必须
IDENTICAL、`.ccr` 四条锁定值不变）。本批**未跑构建**（构建槽被 `plan-reffix` 占用，见 §5 纪律）
⇒ 本载体落盘时四点值标「**待实测**」；T4 收官须在构建槽开放后跑一次
`tools/baseline/canary_check.sh` 转绿作背书。**若转红 ⇒ 不是载体 bug 就是真回归，两者都必须
先停下上报，不得就地改锁定值**（见 §6 换代纪律）。

---

## 2. 载体设计

### 2.1 组成

| 文件 | 角色 |
|---|---|
| `tools/baseline/canary_values.tsv` | **锁定值单一真源**：`name<TAB>artifact<TAB>sha256<TAB>size`，5 条。带文件头注（配方 + 出处 + 口径） |
| `tools/baseline/canary_check.sh` | **闸门本体**：按 §1 配方产出 5 件产物 → 与值表逐条比对（sha **与** 尺寸） |
| `tests/harness/test_canary_carrier.py` | **牙**：机械挂点断言 + 合成自测（无编译器）+ 真产物篡改（有编译器时） |

### 2.2 `canary_check.sh` 接口

```
bash tools/baseline/canary_check.sh [<corec二进制>]        # 默认 ./build/corec
    —— 采集（5 条编译，逐条 clean-cache）+ 校验；rc=0 全绿 / 1 任一不符 / 2 用法错
bash tools/baseline/canary_check.sh --verify-only [<dir>]  # 只校验既有产物（不编译）
bash tools/baseline/canary_check.sh --selftest             # 合成夹具自证（无编译器，毫秒级）
环境：CANARY_VALUES=<tsv>（值表路径，默认入仓表）· CANARY_NO_NICE=1（免 nice）
```

采集目录默认 `build/canary_artifacts/`（`build/` 不入库）。**脚本不自建编译器**——
前置 = `./build/corec` 存在且 `./build/corearch` 同目录（`build` 路径按
`src/compiler/main.cr:713-721` 用 `get_arg(0)` 的目录拼 `corearch` 调用）。

### 2.3 fail-closed 四条（**逐条对应一个已知静默形态**）

| # | 规则 | 防的静默形态 |
|---|---|---|
| F1 | 任一步 rc≠0 ⇒ 红（含编译失败、产物缺失） | 「编译挂了但没产物 ⇒ 跳过断言 ⇒ 绿」 |
| F2 | 值表缺 name / 值表条目数 ≠ 5 ⇒ 红 | 「值表被改小 ⇒ 断言面缩水而全绿」 |
| F3 | 逐条比 **sha256 与字节数两项**，任一不符 ⇒ 红并打印**期望 vs 实际** | 「只比尺寸 ⇒ 换内容同尺寸假绿」（尺寸单独报 = 更早诊断） |
| F4 | 工具缺失（无 `build/corec`、无 `sha256sum`）⇒ 红 | 「环境缺件 ⇒ 空跑绿」 |

### 2.4 零足迹论证（**载体本身不改判据值**）

本批只**新增**三个文件 + **改注释/挂点**，**零 `.cr` 源码改动** ⇒
`build/corec`/`corearch` 二进制度不变 ⇒ canary 与四条 `.ccr` 的**产生过程**逐字节不变。
（构造性论证；**实测背书 = §1.3 的转绿跑**。）唯一的间接面：`build/canary_artifacts/`
是构建产物目录（`build/` 已不入库），且每步 `clean-cache` 只作用于相对 cwd 的
`.core/cache/cir/`（`main.cr:408-414`）——不写源树、不写判据面。

### 2.5 本载体自己怎么自证（**「闸门能变红」钉死**）

`canary_check.sh --selftest` 在临时目录造合成夹具 + 派生值表，逐条断言**判据函数本身**：

| 子检 | 输入 | 期望 |
|---|---|---|
| S1 | 夹具与派生值表**自洽** | **绿**（证明绿路可达，不是恒红） |
| S2 | 同尺寸**翻转一字节** | **红**（证明比的是 sha，不是只看尺寸） |
| S3 | 截断一字节（尺寸变） | **红** |
| S4 | 删除产物文件 | **红**（缺件） |
| S5 | 值表**删掉一条** | **红**（断言面缩水） |
| S6 | 值表期望 sha 换成**假值** | **红** 且消息含「期望 … 实际 …」 |

`tests/harness/test_canary_carrier.py` 再往上加两层：**机械**（run.sh 真挂本载体与本测试；
否则「自称已挂」复现）+ **真产物篡改**（采集真产物 → 翻 `pa.ccr` 一字节 → `--verify-only`
**必须红**）。后者是「值不符 ⇒ 必红」在**真判据**上的闭环。

---

## 3. 挂点（T2）

| 落点 | 改动 |
|---|---|
| `src/ci/run.sh` `selfhost-tests` job | 尾部追加 `bash tools/baseline/canary_check.sh`（真闸）+ `python3 tests/harness/test_canary_carrier.py`（牙）|
| `tests/harness/ci_hook_allowlist.txt` | 新测试文件已挂 ⇒ **不进白名单**；`test_mw_task2.py` 条目理由列按 T3 实况改写 |
| `tests/harness/test_ci_hook_coverage.py` | 无需改口径（新测试文件在 SCOPE 内且已挂 ⇒ 差集不变）；注释里的实测基线计数同步 |
| `src/ci/run.sh` 注释 | 挂点旁按「注释即判据」体例写明：值表真源、两口径、为何挂 selfhost-tests（需已验证编译器）|

**为何挂 `selfhost-tests` 而非 `bootstrap-tests`**：本闸门需要**已构建的** `build/corec/corearch`
（且 `build` 路径要 corearch 同目录），而 `selfhost-tests` 首行即 `build_selfhost`
（`src/ci/run.sh:78`）。`bootstrap-tests` 不构建编译器。**成本 = 1 档 canary ELF + 4 次 `.ccr`
（2 语料 × 2 口径），语料 240B / 2.5KB，均为秒级；`--selftest` 与机械腿毫秒级。**
（**待实测（等构建槽）**：实测时长须回填本节。）

---

## 4. T3 · A5 静默消失修复（同批顺手）

**实核**：`tests/selfhost/test_mw_task2.py:284-303`——零 diff 分支的 `else` 支
（`:301-303`）只 `print("[SKIP] …")`，**不置 `ok = False`**；基线在 `build/mw_task2_zdiff/`
（`:44` `ZDIFF = BUILD / "mw_task2_zdiff"`；`build/` 不入库）且 `run.sh` 从不传 `--snapshot`
（`run.sh` 全文实读：零命中）⇒ **判据可整体静默消失**（新克隆/CI 恒 `[SKIP]` 而 rc=0）。

**改法**：默认 **基线缺失即 FAIL**（`ok = False` + `[FAIL]` 行含补救命令）；
仅当显式 `--allow-skip` 时保留 `[SKIP]`。`--snapshot` 语义不变。
同批在 `ci_hook_allowlist.txt` 的 `test_mw_task2.py` 条目理由列写明**现状**
（该文件未挂 CI ⇒ 只影响本地手动跑）与「为何仍未挂 CI」+ 成本估算。

---

## 5. 纪律（本批硬约束）

- **本批零构建**（构建槽被 `plan-reffix` 批占用）⇒ 凡需二进制者一律标「待实测（等构建槽）」，
  **不得**把待测写成已测。
- **jj only**（铁律 #2）；提交**路径限定**；写文件后立刻 `jj status`。
- 计划里每个 `file:line` 已自读确认（§1 逐条出处）。
- **不猜配方**：§1 配方全部来自可执行原文（`/tmp/capt1/t1b_criteria.sh`）+ 报告表原文，
  且值经三处独立采集体（`/tmp/capt1`、`/tmp/capt6`、`/tmp/fct3`）实测吻合。

---

## 6. 换代纪律（**只在此处更新锁定值**）

1. 锁定值换代 = 判据面**显式声明**变更（如 §1.2 那条「发射面/格式面变更 + 维护者取裁」）。
   **不得**因为跑出来不符就改值表对齐——那正是本闸门要抓的「静默漂移」。
2. 换代须**同批**记录：旧五值 + 新五值 + 理由 + 出处提交；旧值不删（注记留痕）。
3. 判据不符时的**唯一正确动作** = 停下上报（是回归就修回归，是越界就取裁），
   **不是**改值表。

---

## 7. 未覆盖面（**逐条 = 仍是纪律而非机器**；含挂点成本估算）

| # | 判据 | 现状 | 挂它是机器闸门的成本估算 |
|---|---|---|---|
| U1 | `test_backend_bootstrap.py`（N06 静默唯一门） | **未挂 CI**（白名单「最高危」条） | 中：需 corec+目录 project-mode 构建一次；时长未实测 ⇒ 须先量 |
| U2 | `.cir` DOT 165915B / `b1bdf480…` | 纯纪律（无载体） | **低**：与 `.ccr` 同为单档 `ccr cir` 产物，可仿本批加进 `canary_values.tsv`（**但 DOT 面含行号/名字**⇒ 随编译器自身源码改动漂移风险高，须先裁口径） |
| U3 | `--dump-objects` 3521 行 | 纯纪律 | 低-中：`corearch <ccr> --dump-objects \| wc -l`；**行数面**同 U2 的漂移风险 |
| U4 | 自举链 `corec2 == corec3` + N06=0 + 冒烟 42 + `--help` rc=1 | **已挂** `full-bootstrap`（`run.sh:132-143`）——但 `full` 层在免费计划下仅 `workflow_dispatch` 可达 | 0（已机器；缺的是**触发**） |
| U5 | `test_mw_task1/3/4/5/6.py`（M1 多字族） | 未挂（白名单同族） | 中：需 corec；`test_mw_task2` 修完后同批评估 |
| U6 | `test_hit_table.py` / `test_lsp.py` / `test_live_ranges.py` 等 23 selfhost 档 | 未挂（白名单逐条） | 逐档不同（多为需 corec 的中成本）；**根因 = 无「挂点扩容批」**，本批不扩 |
| U7 | `selftest-types 415/415` | 已挂 `selfhost-tests`（`run.sh:94`）但**计数下限**由套件内 `MIN_CASES` 守——两处口径靠人同步 | 低：可机械断言「run.sh 注释计数 == `test_type_engine.py:MIN_CASES`」 |
| U8 | `tools/baseline/parity_run.sh` / `probes_run.sh` / `warm_leg.sh` 广度腿 | 未挂（**CI 不可行**：需 jj + 完整历史，CI 浅检出无 jj） | 不可挂（登记即终态） |
| U9 | `test_mw_task2.py` 零 diff 断言 | 本批 T3 修「缺失即 FAIL」后仍是**本地腿** | 低-中：挂它需在**改动前编译器**上先产基线 ⇒ CI 结构性不可挂（基线段不可得）；T3 修法与白名单理由承担诚实性 |

---

## 8. 判据（本批自身）

- **T1**：`bash tools/baseline/canary_check.sh --selftest` rc=0（S1–S6 全按设计）；
  `python3 tests/harness/test_canary_carrier.py` rc=0。
- **T1 真腿（待实测，等构建槽）**：`bash tools/baseline/canary_check.sh` rc=0（5/5）。
- **T2**：`python3 tests/harness/test_ci_hook_coverage.py` rc=0（新挂点不改差集；白名单不腐烂）。
- **T3**：`python3 tests/selfhost/test_mw_task2.py` 在**无基线**时 **rc=1**（改前为 rc=0）；
  带 `--allow-skip` 时 rc=0。
- **零足迹**：五 CI job + 全枚举 + canary/四条 —— **待实测（等构建槽）**。
