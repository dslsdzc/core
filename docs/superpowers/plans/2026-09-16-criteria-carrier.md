# 判据载体化批（criteria-carrier）：ELF canary + `.ccr` 四条 = 机器闸门

**日期**：2026-09-16 · **状态**：T0 侦查已实测写进文档 → T1/T2/T3 实施中（**本批零构建**；
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
| 判据 | sha256 `95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475` · **28822B = ELF 文件大小**（`stat -c %s` 于 `\177ELF` 魔数的可执行产物上；本实例实核 `/tmp/capt6/pa_st.bin` = `-rwxr-xr-x` 28822B） |
| 出处 | `docs/superpowers/plans/2026-09-16-global-operand-seams.md:325`（本批在途计划）· `docs/superpowers/plans/2026-09-15-fail-closed-diagnostics.md:101` · `docs/superpowers/plans/2026-09-12-r2-p4-carrier.md:74` |
| 可执行原文 | `/tmp/capt1/t1b_criteria.sh:34-38`（`$CC clean-cache` → `$CC build tests/suite/ptr_arith.cr --static -o "$O/pa"` → `sha256sum` + `stat -c 'size=%s'`，并打印期望值） |

**约定限制**：canary 覆盖 = **该一档语料的发射面**。它是「发射面零泄漏」证据，**不是**新语义
正确性证据（`plans/2026-09-12-r2-p4-carrier.md:74` 明文：该语料对类型层不敏感）。

### 1.2 `.ccr` 四条（两语料 × 两种形式，冷态）

| 名 | 语料 | 约定（命令） | sha256 | 字节 |
|---|---|---|---|---|
| `pa_ccr` | `tests/suite/ptr_arith.cr` | `clean-cache` → `ccr <src> -o <D>/pa.ccr` | `680a6f9843747b521213c3bcca1cf8724657943410f182e97ed63dcc11c7cd7a` | 96015 |
| `pa_static_ccr` | 同上 | `clean-cache` → `build <src> -o <D>/pa_st.bin --static`（产物 = `<D>/pa_st.bin.ccr`） | `76f36e6a6b6eb2f18fa5541550d09e5e73bb0e8dfc7df2ebbe3d747c382f329c` | 96158 |
| `gt_ccr` | `tests/suite/generics_test.cr` | `clean-cache` → `ccr <src> -o <D>/gt.ccr` | `d92a2727d0c51aa887d7053305a26bdf85451303e08d268898cf1de76bae2c95` | 142765 |
| `gt_static_ccr` | 同上 | `clean-cache` → `build <src> -o <D>/gt_st.bin --static`（产物 = `<D>/gt_st.bin.ccr`） | `a1f7b99c68c7d433834593100a776b74f883de291482f20762fe7399ec5182ea` | 142908 |

> ⚠ 上表 gt 两行 = **本批 §9.2 重锁后**的值（环境归一化 / 空 `HOME`）。重锁前为
> 142793 `41e9d845…` / 142936 `704316c8…`（= 本机带 `~/.core/lib/io/index` 的值，
> **自本批起作废**，留痕见 `tools/baseline/canary_values.tsv` 头注）。

**出处（配方原文）**：`.superpowers/sdd/cap-task1-report.md:82`——
`| 8 | .ccr 两种形式四条（冷态） | ccr F -o O / build F -o O --static（各 clean-cache；static 取 O.ccr） | … |`。
**可执行原文**：`/tmp/capt1/t1b_criteria.sh:41-53`（四条逐条 `clean-cache` 前置 + `cp "$O/pa_st.bin.ccr" "$O/pa_st.ccr"`）。
**值来源**：`.superpowers/sdd/p6-task3-report.md:62`（P6 T3 **重锁**：`delta = 4B × 节点数`，pa +5192 = 4×1298 · gt +7452 = 4×1863）+ `.superpowers/sdd/p6-task4-report.md:81`（P6 T4 复验「四条逐字节同」）。

**约定限制（三条，逐条实测）**：
1. **必须 `clean-cache` 前置且逐条独立**——`clean-cache` = `rm -rf .core/cache/cir/`
   （`src/compiler/main.cr:408-414` 实读），**相对 cwd** ⇒ 本载体必须 `cd` 仓库根
   （记忆 `judgment_run_traps`：cir 缓存跨重建不失效、cwd 决定 import 解析）。
2. **两种形式不可互推**：`ccr` 约定与 `build` 约定的 `.ccr` **内容不同**（差恒 143B）。本实例
   解码段表实测（`/tmp/capt6/{pa.ccr,pa_st.ccr}`，下表）：差异**只在 STR 段 +79B 与 SYM 段
   +64B**，NOD/ENT/REG/EDG/TYPE/IFACE 六段尺寸逐字节相同。
   ⇒ 143B 是**接口面语义差**，**不是** 输出路径长度差（见下条）。
   **根因（P4 附录 D-1 已查明，本批复核尺寸面一致）**：`--static` 在
   `src/compiler/main.cr:433-437` 前置 `rt.cr`（"so `*` functions inline"）⇒ **4 全局 + 1 串**
   进 `.ccr` = +143B（出处：`docs/superpowers/plans/2026-09-12-r2-p4-carrier.md` 附录 D-1
   「根因（T7 查明，消除 ±143B 漂移疑云）」）。
3. **与输出路径无关（关键，实测）**：同一逻辑产物写入三个互不相同的输出目录、跨越三批、
   三次采集，四条 sha **逐条相同**——
   `/tmp/capt1`（2026-09-14，容量批 T1）· `/tmp/capt6`（2026-09-16，全局 seam 批在途）·
   `/tmp/fct3`（2026-09-15，fail-closed T3）。⇒ 本闸门在 CI（任意临时目录）可复现。

| 段（tag） | pa `ccr` 约定 | pa `build` 约定 | 差 |
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
版本出处 `ccr_io.cr:135` `CCR_VERSION = 9`。）

### 1.3 两套历史值的关系（**T0 追加项结案：(甲) 之「同口径不同时代」，非漂移**）

`criteria-strength-audit` 表 C 第 2 条给出的四值与各批提交信息/本表**对不上**——已查清：
**不是同一对象的两个面，而是同一约定的两个时代**，且换代是**显式的、有归因的、旧值留痕的**。

实为**三代链**（非两代），逐代出处实挖：

| 代 | 时点 / 格式 | 值（语料 A `ptr_arith` / 语料 B `generics_test` × 约定 ①②） | 出处（`file:line`） | 代内变化是否有显式归因 |
|---|---|---|---|---|
| **G1** | P4 T7 收官 2026-09-13 / v8（NOD **36B**） | pa 90823B `fb4a3b59…` / 90966B `592afa31…`；gt 134701B `cafb4278…` / 134844B `ec8413ec…` | `docs/superpowers/plans/2026-09-12-r2-p4-carrier.md` **附录 D-1 表**（T7 实测 + 复测逐条复现）· `TODO.md:474` · `TODO.md:444` | — （起点） |
| **G2** | P5 T7 2026-09-14 / v8 | pa **不变** 90823B `fb4a3b59…` / 90966B `592afa31…`；gt **+640B** ⇒ 135341B `ddec1ce6…` / 135484B `cd2af565…` | `TODO.md:521`（P5 T7 复验）· `TODO.md:376`（P5 T5-era） | ⚠ **本批未挖到「原→新」式显式重锁声明**（P5 复验只记新值）——登记为**留痕缺口**（不影响本载体：G2 已被 G3 取代） |
| **G3（现行）** | P6 T3 起 2026-09-14→今 / v9（NOD **40B**） | pa **96015** `680a6f98…` / **96158** `76f36e6a…`；gt **142793** `41e9d845…` / **142936** `704316c8…` | `.superpowers/sdd/p6-task3-report.md:62`（**P6 T3 重锁**）· `p6-task4-report.md:81`（T4 复验四条逐字节同）· 本表 §1.2 | ✅ **有**：逐条「原 …」括注 + `delta = 4B × 节点数`（pa +5192=4×1298；gt +7452=4×1863） |

> **G3 之上的第四代（本批 §9.2）**：gt 两条 142793/142936 → **142765/142908**（−28B），
> 归因 = `$HOME/.core/lib/<模块>/index` 是否在场（**非格式/内容演进，是环境面**）⇒
> 载体已同批归一化 `HOME` 并重锁。**故现行值以 §1.2 表（= 值表）为准**。

**结论（对「(甲) 还是 (乙)」的回答）**：审计表 C 第 2 条引的四值 = **G2**（P5 T7 代），
非与本表冲突；G2→G3 有**显式归因**（P6 T3 格式 v8→v9）。但 G1→G2 的 gt 变化**缺一条显式
重锁声明**——这恰好**印证了本批的立论**：`锁定值`单靠「记在文档里」不足以当闸门，
**必须配「变化即归因」的机制**（本载体 + §6 两级纪律）；否则每一代都会留下一处
「不知道它为什么变了」的缺口。

**换代归因（原文实读）**：`p6-task3-report.md:62` 写「pa ccr **96015B** `680a6f98…`（**原** 90823
`fb4a3b59…`）· pa static **96158B** …（**原** 90966 `592afa31…`）· gt ccr **142793B** …（**原** 135341
`ddec1ce6…`）· gt static **142936B** …（**原** 135484 `cd2af565…`）；**delta = 4B × 节点数**
（pa +5192 = 4×1298；gt +7452 = 4×1863）」。即：NOD 记录 36B→40B（TYPE 段文件空间项索引）
⇒ 每节点 +4B ⇒ 四条同步增大并**显式重锁**。审计表 C 引的旧四值 = **P4/P5 时代（v8）记录值**。

> **判据契约因此是两级的**（**不得**写成「永远不该变」——那会把每次正当的格式/内容演进变成
> 假红，正是 P6 T3 那种重锁会踩的坑；**也不得**写成「随便变」——那等于没有闸门）：
>
> | 判据 | 性质 | 值变了怎么办 |
> |---|---|---|
> | **ELF canary** | **发射面零泄漏检测器** | **停下上报**（变 = 类型/载体层改动泄进发射面）——除非维护者显式声明发射面变更并同批重锁 |
> | **`.ccr` 四条** | **格式+内容形状检测器** | **值变 ≠ 必然回归**：先**归因**（格式/版式演进？内容面演进？）——归因成立 ⇒ 同批重锁 + 旧值留痕；**归因不出/属于发射面 ⇒ 按回归处理，停下上报** |
>
> 依据（两例「有归因的重锁」）：P6 T3 = 格式演进（v8→v9，4B×节点数）；P4 T3 = 内容面演进
> （`TODO.md:444`「STR 增长实测 +16 串/+156B」+「TYPE 段 +360~400B」）；反向例 = `TODO.md:454`
> 的「**用户程序零扰动**」（该批预期 `.ccr` 不变的正面判据）。
> **本闸门禁止的不是变化，是无声变化。**
>
> **只锁冷态**（**不得**「补全」成冷暖双锁——否则在已知豁免面上引入假红）：① 一切记录值都是
> 冷态（`cap-task1-report.md:82` 明标「冷态」）⇒ 载体复现的就是记录约定；② P4 附录 D-1 明载
> **非可选程序的冷≠热是预存面**（pre-P4 二进制同病 89086/88954）并被**豁免**（TODO #2026-09-10-1 末条家族）
> ⇒ 锁暖态 = 把「已登记豁免的已知分歧面」变成红闸门；③ 暖态在本两档**零区分力**——T1 表 B 8c
> 实测四条冷=暖（`cap-task1-report.md:84`），且 `generics_test` 是**构造性**的（含泛型 ⇒
> `src/compiler/main.cr:480-486`（`:484` 置 0）`cache_enabled = 0` ⇒ 冷≡暖）。暖态面**另有专属
> 机器闸门**（`tests/selfhost/test_warm_cache_gate.py` 已挂 CI + `tools/baseline/warm_leg.sh`
> 手工广度判据）⇒ **此处不锁 ≠ 无人守**。⚠ 若将来本两档出现冷≠热：**冷锁仍成立**（冷是记录约定），
> 暖侧分歧归暖态闸门抓，**不并到这里**。

### 1.4 起点值现状（**历史快照**——写进文档时构建槽被占；**实测结论见 §9.1 / §9.2**）

四条 + canary 的**最近一次**同源实测 = 在途批计划
`docs/superpowers/plans/2026-09-16-global-operand-seams.md:325-326`（该批声明 canary 必须
IDENTICAL、`.ccr` 四条锁定值不变）。本批**未跑构建**（构建槽被 `plan-reffix` 占用，见 §5 纪律）
⇒ 本载体落盘时四点值标「**待实测**」；T4 收官须在构建槽开放后跑一次
`tools/baseline/canary_check.sh` 转绿作背书。**若转红 ⇒ 先按 §1.3 的两级契约归因**：
canary（发射面）⇒ 停下上报；`.ccr` 四条 ⇒ 归因成立才可同批重锁，**归因不出/指向发射面则
按回归处理**——两条路都**不得就地改锁定值**（见 §6 换代纪律）。

---

## 2. 载体设计

### 2.1 组成

| 文件 | 角色 |
|---|---|
| `tools/baseline/canary_values.tsv` | **锁定值单一依据**：`name<TAB>artifact<TAB>sha256<TAB>size`，5 条。带文件头注（配方 + 出处 + 约定） |
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

### 2.5 本载体自己怎么自证（**「闸门能变红」固定**）

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

> **实测**（§9 E1–E7）：S1–S6 全按设计；「翻一字节 ⇒ 红且指名产物」已用**真产物**（从
> `/tmp/capt6`、`/tmp/fct3` 两处采集）跑通，**零编译**。仅「由载体自己采集真产物」这一步
> 待构建槽开放（§9 待实测）。

---

## 3. 挂点（T2）

| 落点 | 改动 |
|---|---|
| `src/ci/run.sh` `selfhost-tests` job | 尾部追加 `bash tools/baseline/canary_check.sh`（真闸）+ `python3 tests/harness/test_canary_carrier.py`（牙）|
| `tests/harness/ci_hook_allowlist.txt` | 新测试文件已挂 ⇒ **不进白名单**；`test_mw_task2.py` 条目理由列按 T3 实况改写 |
| `tests/harness/test_ci_hook_coverage.py` | 无需改约定（新测试文件在 SCOPE 内且已挂 ⇒ 差集不变）；注释里的实测基线计数同步 |
| `src/ci/run.sh` 注释 | 挂点旁按「注释即判据」体例写明：值表出处、两种形式、为何挂 selfhost-tests（需已验证编译器）|

**为何挂 `selfhost-tests` 而非 `bootstrap-tests`**：本闸门需要**已构建的** `build/corec/corearch`
（且 `build` 路径要 corearch 同目录），而 `selfhost-tests` 首行即 `build_selfhost`
（`src/ci/run.sh:78`）。`bootstrap-tests` 不构建编译器。**成本 = 1 档 canary ELF + 4 次 `.ccr`
（2 语料 × 2 约定），语料 240B / 2.5KB，均为秒级；`--selftest` 与机械判据毫秒级。**

> **成本实测（2026-09-16，构建槽静默期实跑）**：载体独立 **1.04s**（5 条采集 + 校验全含）；
> 牙独立 **2.24s**（其中 C 层复用载体刚落盘的 `build/canary_artifacts/` ⇒ **零额外编译**）；
> 在 `CI_JOB_NAME=selfhost-tests` 内合计给该 job 增约 **3.3s**（该 job 全程 **78s**）。
> ⇒ 本闸门对 PR 层 CI 的边际成本 ≈ **3 秒/次**，与「秒级」预估一致。

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

## 6. 换代纪律（**只在此处更新锁定值**；两级契约见 §1.3）

**核心命题：本闸门禁止的不是变化，是无声变化。** 因此「不符」的处置**按判据分级**：

| 判据 | 值变了 ⇒ | 换代条件 |
|---|---|---|
| **ELF canary**（发射面零泄漏） | **停下上报**（默认按越界处理） | 仅当维护者**显式声明发射面变更**并取裁 ⇒ 同批重锁 |
| **`.ccr` 四条**（格式+内容形状） | **先归因**：格式/版式演进？内容面演进？（对照 §1.3 的两例先例） | 归因成立 ⇒ 同批重锁；**归因不出 / 归因指向发射面 ⇒ 按回归处理，停下上报** |

1. **归因先于换代**：无归因的变化一律按**回归**处理（这正是 `p6-task3-report.md:62` 那种
   「原 … ⇒ 新 …，delta = 4B × 节点数」写法的意义——它把一次变化**变成可审的**）。
2. **不得**因为跑出来不符就改值表对齐——那正是本闸门要抓的「静默漂移」。
3. 换代须**同批**记录：旧值 + 新值 + **归因** + 出处提交；旧值不删（留痕面 =
   `tools/baseline/canary_values.tsv` 头注 + 本计划）。
4. 「停下上报」是**默认动作**（是回归就修回归，是越界就取裁），**不是**改值表。
5. **反向义务**：若某批**预期 `.ccr` 不变**（如 P4 T5「用户程序零扰动」型），则该批把本闸门
   当**正面判据**用——此时「绿」即证据，须在批次报告里引用本载体的输出。
6. **判据效力范围（2026-09-16 CI 红档后补，**必须与锁定值同处留存**）**：本闸门的 `.ccr`
   四条**自 2026-09-16 起**锁定「**环境归一化（受控空 `HOME`）**下的产物」。
   在此之前的所有 gt 锁值（142793/142936，G3 期）**从来不是跨机可复现的值**——它们是
   「本机 `~/.core/lib/io/index` 在场」时测得的；换言之，**此后回看，那些「锁定值命中」
   都隐含依赖该文件在场**，在没有该文件的机器（如 CI runner）上判据必然红。这不是狡辩空间，
   是**判据的效力范围**。详见 `tools/baseline/canary_values.tsv` 头注「本批重锁」与 §9.2。

---

## 7. 未覆盖面（**逐条 = 仍是纪律而非机器**；含挂点成本估算）

| # | 判据 | 现状 | 挂它是机器闸门的成本估算 |
|---|---|---|---|
| U1 | `test_backend_bootstrap.py`（N06 静默唯一门） | **未挂 CI**（白名单「最高危」条） | 中：需 corec+目录 project-mode 构建一次；时长未实测 ⇒ 须先量 |
| U2 | `.cir` DOT 165915B / `b1bdf480…` | 纯纪律（无载体） | **低**：与 `.ccr` 同为单档 `ccr cir` 产物，可仿本批加进 `canary_values.tsv`（**但 DOT 面含行号/名字**⇒ 随编译器自身源码改动漂移风险高，须先裁约定） |
| U3 | `--dump-objects` 3521 行 | 纯纪律 | 低-中：`corearch <ccr> --dump-objects \| wc -l`；**行数面**同 U2 的漂移风险 |
| U4 | 自举链 `corec2 == corec3` + N06=0 + 冒烟 42 + `--help` rc=1 | **已挂** `full-bootstrap`（`run.sh:132-143`）——但 `full` 层在免费计划下仅 `workflow_dispatch` 可达 | 0（已机器；缺的是**触发**） |
| U5 | `test_mw_task1/3/4/5/6.py`（M1 多字族） | 未挂（白名单同族） | 中：需 corec；`test_mw_task2` 修完后同批评估 |
| U6 | `test_hit_table.py` / `test_lsp.py` / `test_live_ranges.py` 等 23 selfhost 档 | 未挂（白名单逐条） | 逐档不同（多为需 corec 的中成本）；**根因 = 无「挂点扩容批」**，本批不扩 |
| U7 | `selftest-types 415/415` | 已挂 `selfhost-tests`（`run.sh:94`）但**计数下限**由套件内 `MIN_CASES` 守——两处约定靠人同步 | 低：可机械断言「run.sh 注释计数 == `test_type_engine.py:MIN_CASES`」 |
| U8 | `tools/baseline/parity_run.sh` / `probes_run.sh` / `warm_leg.sh` 广度判据 | 未挂（**CI 不可行**：需 jj + 完整历史，CI 浅检出无 jj） | 不可挂（登记即终态） |
| U9 | `test_mw_task2.py` 零 diff 断言 | 本批 T3 修「缺失即 FAIL」后仍是**本地判据** | 低-中：挂它需在**改动前编译器**上先产基线 ⇒ CI 结构性不可挂（基线段不可得）；T3 修法与白名单理由承担诚实性 |

---

## 8. 判据（本批自身）

- **T1**：`bash tools/baseline/canary_check.sh --selftest` rc=0（S1–S6 全按设计）；
  `python3 tests/harness/test_canary_carrier.py` rc=0。
- **T1 真判据（待实测，等构建槽）**：`bash tools/baseline/canary_check.sh` rc=0（5/5）。
- **T2**：`python3 tests/harness/test_ci_hook_coverage.py` rc=0（新挂点不改差集；白名单不腐烂）。
- **T3**：`python3 tests/selfhost/test_mw_task2.py` 在**无基线**时 **rc=1**（改前为 rc=0）；
  带 `--allow-skip` 时 rc=0。
- **零足迹**：五 CI job + 全枚举 + canary/四条 —— **待实测（等构建槽）**。

---

## 9. 本批实测记录（T1–T3；**全部零编译**——构建槽被在途批占用）

| # | 项 | 结果 | 性质 |
|---|---|---|---|
| E1 | `canary_check.sh --selftest` | **rc=0 · 6/6**（S1 绿路可达 + S2–S6 五类必红） | 实测（无编译器） |
| E2 | `--verify-only` 对 `/tmp/capt6` 采集的真产物（2026-09-16，全局 seam 批在途采集体） | **5/5 PASS** | 实测（无编译器） |
| E3 | `--verify-only` 对 `/tmp/fct3` 采集的真产物（2026-09-15，fail-closed T3 采集体；**另一目录、另一批次**） | **5/5 PASS** | 实测（无编译器） |
| E4 | 真产物 `pa.ccr` **翻一字节（尺寸不变）** ⇒ `--verify-only` | **rc=1**，指名 `pa_ccr` + 打印期望 vs 实际；其余 4 条仍 PASS | 实测（无编译器） |
| E5 | 误拷 `pa_static_ccr` 值入 `pa.ccr` 槽（S2 的「值不符」变体） | **rc=1**，两条 FAIL（size + sha256） | 实测（无编译器） |
| E6 | `python3 tests/harness/test_canary_carrier.py`（挂点前） | **rc=1**：A1/A2 双 FAIL（「未真挂」被抓）+ B PASS | 实测（临时树骨架，无 `build/`） |
| E7 | 同上（挂点后） | **rc=0**：A1/A2/A3/B 全 PASS；C 显式 `[SKIP]`（该骨架无编译器） | 实测（临时树骨架） |
| E8 | `python3 tests/harness/test_ci_hook_coverage.py` | **rc=0 · scope=65 hooked=38 unhooked(allowlisted)=27**（差集不变；新测试已挂 ⇒ 不进白名单） | 实测（纯 python） |
| E9 | `tests/selfhost/test_mw_task2.py --help` | 新 `--allow-skip` 旗标就位 | 实测（argparse 即退，不跑用例） |
| E10 | **采集路径端到端**：桩编译器（回应同形状 CLI、用 `/tmp/capt6` 真产物作响应）驱动 `canary_check.sh` 默认模式 | **rc=0 · 采集 + 校验全绿 5/5** ⇒ 参数构造 / 逐条 `clean-cache` / 次序（canary 先落 `pa.ccr`、`ccr` 步覆盖之）/ `-o X ⇒ X.ccr` 派生 **全部经真代码路径验证**（仅「编译」一环由桩替代） | 实测（无编译） |
| E11 | 牙的**新鲜度守卫**（E10 暴露的假绿面）：采集目录存在但**比 `build/corec` 旧**（= 上一代二进制的陈货）⇒ 不得复用，须重采 | 已实现（`test_canary_carrier.py` C 层 mtime 判据）；CI 中 `run.sh` 先跑载体 ⇒ 恒新鲜，该守卫只防本地/乱序 | 实测（代码路径 + 骨架复跑） |
| E12 | **T0 追加项结案**：两套 `.ccr` 四值 = (甲)「同口径不同时代」（旧 v8 `fb4a3b59…`/`592afa31…`/`ddec1ce6…`/`cd2af565…` ↔ 新 v9 = 本表），**非漂移** | 出处逐条挖到 `file:line`（P4 附录 D-1 表 · `TODO.md:474`/`:521`/`:376` ↔ `p6-task3-report.md:62` 的「原 …」括注 + `delta = 4B × 节点数`）；143B 根因 = `--static` 前置 `rt.cr`（`main.cr:433-437`，P4 D-1 已查明）；canary 28822B = **ELF 文件大小**（`\177ELF` + `-rwxr-xr-x`，实核） | 实测（文档/产物取证，零编译） |
| E13 | 判据契约改写后全层复跑：值表头重写（两级契约 + 冷态-only + 两代关系） | `--selftest` 6/6 · 两套真产物 `--verify-only` 各 5/5 · 骨架 harness PASS | 实测（零编译） |

**E4/E5 的意义**：不只证明「比的是 sha 而非只比尺寸」，还证明**红是可诊断的**（指名产物 +
期望 vs 实际）——「闸门变红但没人看得懂」同样是判据失效形态。

### 9.1 构建槽开放后的真跑（2026-09-16 04:49 起；串行闸门 = 等待 `plan-reffix` 的
parity/probes/warm 链静默后才开工，未与其并行）

| # | 项 | 结果 | 性质 |
|---|---|---|---|
| **E15** | **载体默认模式（真采集）** `bash tools/baseline/canary_check.sh` | **rc=0 · 5/5 PASS · 1.04s**；五条与值表**逐条 IDENTICAL**（canary `95084e7b…d475` 28822B · pa 96015 `680a6f98…` / 96158 `76f36e6a…` · gt 142793 `41e9d845…` / 142936 `704316c8…`）⇒ **四条 `.ccr` 预期 IDENTICAL 已被实测确认**（#8/#25 修复对本两语料构造性不可达，判断成立） | **实测（真编译）** |
| **E16** | 牙的 C 层真跑 `test_canary_carrier.py --require-compiler` | 首跑 **rc=1** —— C 层抓到**本测试自身的断言字面量 bug**（见 E17）；修复后 **rc=0 · 7/7 · 2.24s**（含「真产物翻一字节 ⇒ 必红且指名 pa_ccr」+「缺产物 ⇒ 必红」） | **实测（真编译）** |
| **E17** | 上述 bug 的性质与修复 | 载体渲染的是「期望**(expected)=** … 实际**(actual)=**」——`expected` 与 `=` 之间**隔着 `)`**，而断言写成 `expected=` ⇒ **恒不命中 ⇒ 恒假红**。修 = 断言改 `(expected)=` / `(actual)=`（`--selftest` 的 S2/S6 用 **grep 正则**、模式里本就含 `(expected)=` ⇒ 一直是对的，故 B 层没抓到、**C 层抓到了**）。**这正是「牙」的价值：它抓的是闸门/断言自身，不是产物。** | 实测（真编译） |
| **E18** | **CI 挂点端到端** `CI_JOB_NAME=selfhost-tests bash src/ci/run.sh` | **rc=0 · 78s**；日志内**确凿出现**载体 5/5 与牙 7/7（`[canary] PASS 5/5` + `[canary-carrier] PASS — pass=7 skip=0`）⇒ 挂点**真接线**，非「注释里自称已挂」 | 实测（真编译） |
| **E19** | **五 CI job 全 rc=0** | `bootstrap-tests` **rc=0**（含 hook-coverage：scope=65 hooked=38 unhooked=27 · BLOCK 20/ALLOW 16 = 36/36）· `check` **rc=0 · 30s** · `suite` **rc=0 · 19s** · `selfhost-tests` **rc=0 · 78s** · `full-bootstrap` **rc=0 · 676s** | 实测（真编译） |
| **E20** | `full-bootstrap`（自举链） | rc=0 · **676s** · N06 计数 **0** · `corec2 == corec3` `cmp` **IDENTICAL**（双 **2892374B**，sha256 双 `093ba2305c204fdd1ce1ad892af21ade75fb79dfcb3957fdc897affd73d9c814`） | 实测（真编译） |
| **E21** | **T3 自证（A5 修复的 fail-closed）**——在**隔离树**跑（`/tmp/mw_nobase`：仅 `build/corec`/`corearch` 软链，无 `mw_task2_zdiff` 基线），**零风险于共享 build/** | 默认约定 **rc=1 · 9 条 `[FAIL] … zero-diff baseline missing … 默认 fail-closed`**（改前同情形 = `[SKIP]` 且 rc=0）· `--allow-skip` ⇒ **rc=0** + 显式 `[SKIP]`（带补救命令）· 有基线树内 ⇒ **ALL PASS rc=0** | 实测（真编译） |
| **E22** | 全枚举（套件全集 = `tests/selfhost/test_*.py` 55 + `tests/bootstrap/test_*.py` 7） | **62/62 rc=0 · 207s**（零 FAIL——判据 = 无任何 `FAIL:` 行写入，非仅计数） | 实测（真编译） |

**零足迹结论（实测）**：本批只新增 3 文件 + 改注释/挂点，**零 `.cr` 源码改动** ⇒
canary 与四条 `.ccr` **逐条 IDENTICAL**（E15）——构造性论证与实测一致。

### 9.2 【闸门的第一份真产出】CI 红档 → 机理闭环 → 裁 (A) 环境归一化（2026-09-16）

**红档**（PR #80 selfhost-tests，run 35025346214）：`canary_elf` / `pa_ccr` / `pa_static_ccr`
全 PASS，**`gt_ccr` 142793→142765 · `gt_static_ccr` 142936→142908（各 −28B）**。

**归属排除（逐条实测，避免误判）**：树不同 ✗（CI 日志 `scope=64 hooked=37` == 本批干净复现树
54+7+3）· 源路径 ✗（维护者已测）· 先跑测试污染 ✗（干净树跑完整 `selfhost-tests` 仍 5/5）·
Python 版本 ✗（`python3.13` 与 `3.14` 重建 `build/corec` **逐字节同 sha** `5a2ad474…`）。

**机理（闭环）**：编译器解析 `import` 时读 **`$HOME/.core/lib/<模块>/index`** 并把其中声明的
函数名驻留进串表（`src/compiler/module.cr:523-530`）。本机有 `~/.core/lib/io/index`（164B）⇒
`generics_test`（`import io`/`import fmt`）多驻留 `print_int`(9)+`println_int`(11) = **恰 28B**；
CI 无该文件 ⇒ 少这 28B。**`ptr_arith.cr` 零 import ⇒ 从不读 `$HOME`** ⇒ pa 三条全过——与观测一致。
段级定位：差异**全在 STR 段**（2521→2493），其余七段逐字节同。

**决定性复现**：本机 `HOME=<空目录>` ⇒ **CI 的 size 与 sha 逐条相同**（`d92a2727…`/`a1f7b99c…`）。

**修复（裁 (A)，本批实施）**：载体把 `HOME` 锁定到**采集目录内的空 `home/`**（+ `CORE_SAFE=1`），
并在输出打印实际值；`.ccr` 四条中 gt 两条**同批重锁**为 142765/142908（旧值留痕 + 效力范围注）。
**不得 unset/置空 `HOME`**——`module.cr:526` 有硬编码 `/home/DslsDZC` 兜底（已独立登记 TODO #2026-09-16-21）。

**验证（三次实跑）**：

| # | 场景 | 结果 |
|---|---|---|
| **V1** | 干净树 + 载体默认（**开发者 `$HOME` 仍含 `io/index`**） | **5/5 PASS**，输出含 `[canary] 环境归一化：HOME=<采集目录>/home（空目录，已建）· CORE_SAFE=1` ⇒ **证明闸门与开发者 `$HOME` 解耦** |
| **V2a** | 有效 `HOME` 含真实 `io/index`（直连编译器，绕过载体） | 142793B `41e9d845…` = **旧锁值** ⇒ 机理双向可复现（有索引↔142793；无↔142765） |
| **V2b** | 有效 `HOME` 含**良性**索引（只列已驻留名 `print`/`read_file`） | 尺寸同（142765）但 **sha 不同**（STR/SYM/NOD/IFACE 四段内容变）⇒ **敏感性 = 索引存在性**，不只新名 |

> **「解耦」的准确定义（维护者 2026-09-16 定稿；原裁 (A) 条件 4 的表述经实测更正）**：
> **解耦 = 与载体控制范围之外的任何 `$HOME`（开发者机 / CI runner / 他人机器）解耦**
> ——V1 证：开发者 `$HOME` 带 `io/index` 时仍 5/5。
> **载体自身的受控 `HOME` 是判据输入的一部分**：每次采集 `rm -rf` 重建为空 ⇒ 既不可被外部
> 在运行中污染，也**不假装对它不敏感**——V2a/V2b 证：往里放索引产物真变 ⇒ **闸门红才是
> 正确行为**（那是**改输入**，不是环境噪声）。
> 若将来需要「索引在场」的覆盖面，**另立语料/约定，绝不放宽本闸门**。
>
> （原条件 4 把「与外部环境解耦」与「对自己的受控输入不敏感」混为一谈；后者不成立——
> 受控 `HOME` 就是编译器的**有效** `HOME`。此更正为双方确认。）
