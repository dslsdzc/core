# 把常用检查接入 CI（criteria-carrier）

> 实施记录：[implementation/2026-09-16-criteria-carrier.md](../implementation/2026-09-16-criteria-carrier.md)

日期：2026-09-16。性质：计划。本批不运行构建；标为“实测”的项目都有出处，需要二进制才能验证的项目标为“待实测（等构建资源）”。

## 起因

一次只读检查发现，ELF 基准的 sha256 `95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475`（28822B）和 `.ccr` 的四项基准值（96015 `680a6f98…`、96158 `76f36e6a…`、142793 `41e9d845…`、142936 `704316c8…`）在本仓库的 `*.py`、`*.sh`、`*.cr`、`*.toml`、`*.yml` 文件里都没有出现。它们只写在 `docs/` 和 `.superpowers/` 的文字里，没有任何自动检查。每批提交信息都引用这些值，但那些值是人工或代理手动运行得到的，不是 CI 检查。

同类问题此前发生过一次：`test_backend_bootstrap.py` 声称已接入 CI，但 `run.sh` 中没有调用，导致 `error[N06]` 在 5 个任务中有 33 次没有检出（见 `src/ci/run.sh:72-73` 和 `tests/harness/test_ci_hook_coverage.py`）。本批把最常被引用的两组值接入 CI。

## 检查的生成方法

以下方法是生成检查产物的唯一方式，每条都注明出处。

### ELF 产物基准

| 项 | 内容 |
|---|---|
| 语料 | `tests/suite/ptr_arith.cr`（15 行；`tests/suite/ptr_arith.cr:1-15` 实读） |
| 命令 | `clean-cache` → `build tests/suite/ptr_arith.cr --static -o <out>` |
| 基准值 | sha256 `95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475`，28822B 为 ELF 文件大小（对以 `\177ELF` 开头的可执行产物运行 `stat -c %s`；本次实际检查 `/tmp/capt6/pa_st.bin`，权限为 `-rwxr-xr-x`，大小 28822B） |
| 出处 | `docs/superpowers/plans/2026-09-16-global-operand-seams.md:325`（进行中的计划）、`docs/superpowers/plans/2026-09-15-fail-closed-diagnostics.md:101`、`docs/superpowers/plans/2026-09-12-r2-p4-carrier.md:74` |
| 可执行原文 | `/tmp/capt1/t1b_criteria.sh:34-38`（`$CC clean-cache` → `$CC build tests/suite/ptr_arith.cr --static -o "$O/pa"` → `sha256sum` 和 `stat -c 'size=%s'`，并打印期望值） |

适用范围：ELF 基准只检查这份语料生成的产物。它证明生成结果没有变化，不证明新语义正确（`plans/2026-09-12-r2-p4-carrier.md:74` 写明：该语料对类型层不敏感）。

### `.ccr` 四项基准

| 名称 | 语料 | 生成命令 | sha256 | 字节 |
|---|---|---|---|---|
| `pa_ccr` | `tests/suite/ptr_arith.cr` | `clean-cache` → `ccr <src> -o <D>/pa.ccr` | `680a6f9843747b521213c3bcca1cf8724657943410f182e97ed63dcc11c7cd7a` | 96015 |
| `pa_static_ccr` | 同上 | `clean-cache` → `build <src> -o <D>/pa_st.bin --static`（产物为 `<D>/pa_st.bin.ccr`） | `76f36e6a6b6eb2f18fa5541550d09e5e73bb0e8dfc7df2ebbe3d747c382f329c` | 96158 |
| `gt_ccr` | `tests/suite/generics_test.cr` | `clean-cache` → `ccr <src> -o <D>/gt.ccr` | `d92a2727d0c51aa887d7053305a26bdf85451303e08d268898cf1de76bae2c95` | 142765 |
| `gt_static_ccr` | 同上 | `clean-cache` → `build <src> -o <D>/gt_st.bin --static`（产物为 `<D>/gt_st.bin.ccr`） | `a1f7b99c68c7d433834593100a776b74f883de291482f20762fe7399ec5182ea` | 142908 |

注：表中 gt 两行是本次改动更新后的值（环境归一化，使用空的 `HOME`）。更新前为 142793 `41e9d845…` 和 142936 `704316c8…`，这是本机存在 `~/.core/lib/io/index` 时测得的值，自本批起不再使用。记录见 `tools/baseline/canary_values.tsv` 头注。

生成方法的出处：`docs/archive/sdd/cap-task1-report.md:82` 的表格第 8 行（`.ccr` 两种形式四条，空缓存状态，`ccr F -o O` 或 `build F -o O --static`，各自先运行 `clean-cache`，static 形式取 `O.ccr`）。

可执行原文：`/tmp/capt1/t1b_criteria.sh:41-53`（四条逐条先运行 `clean-cache`，并执行 `cp "$O/pa_st.bin.ccr" "$O/pa_st.ccr"`）。

基准值的来源：`docs/archive/sdd/p6-task3-report.md:62`（P6 T3 更新基准值：`delta = 4B × 节点数`，pa 增加 5192 字节，等于 4×1298；gt 增加 7452 字节，等于 4×1863）和 `docs/archive/sdd/p6-task4-report.md:81`（P6 T4 复验，四条逐字节相同）。

适用范围有三条，均已实测：

1. 每条命令执行前都要先运行 `clean-cache`，并且四条分别执行。`clean-cache` 等于 `rm -rf .core/cache/cir/`（`src/compiler/main.cr:408-414` 实读），路径相对于当前工作目录，因此检查脚本需要先 `cd` 到仓库根目录。此前的记录是：cir 缓存跨重建不失效，当前工作目录决定 import 解析。
2. 两种命令生成的 `.ccr` 内容不同，固定相差 143 字节。本次解码段表实测（`/tmp/capt6/{pa.ccr,pa_st.ccr}`，见下表）：差异只在 STR 段增加 79 字节、SYM 段增加 64 字节，NOD、ENT、REG、EDG、TYPE、IFACE 六段大小逐字节相同。因此这 143 字节来自接口层的内容差异，不是输出路径长度不同。原因已在 P4 附录 D-1 查明，本次复核的段大小一致：`--static` 会在 `src/compiler/main.cr:433-437` 先加入 `rt.cr`（注释为 “so `*` functions inline”），因此多出 4 个全局量和 1 个字符串进入 `.ccr`，共 143 字节。出处为 `docs/superpowers/plans/2026-09-12-r2-p4-carrier.md` 附录 D-1。该节记录了 T7 查明的原因，并消除了 ±143B 的来源疑问。
3. 结果与输出路径无关（已实测）。同一逻辑产物写入三个不同的输出目录，跨越三批，采集三次，四条 sha 每次相同：`/tmp/capt1`（2026-09-14，容量批 T1）、`/tmp/capt6`（2026-09-16，全局 seam 批进行中）、`/tmp/fct3`（2026-09-15，fail-closed T3）。因此这个检查可以在 CI 的任意临时目录中复现。

| 段（tag） | pa `ccr` 命令 | pa `build` 命令 | 差 |
|---|---|---|---|
| STR(1) | 1711 | 1790 | +79 |
| SYM(2) | 6452 | 6516 | +64 |
| NOD(3) | 51924 | 51924 | 0 |
| ENT(4) | 23020 | 23020 | 0 |
| REG(5) | 2068 | 2068 | 0 |
| EDG(6) | 9028 | 9028 | 0 |
| TYPE(7) | 1248 | 1248 | 0 |
| IFACE(8) | 452 | 452 | 0 |
| 合计 | 96015 | 96158 | +143 |

段表解码为本次实际运行结果：头 16 字节为 `CCR1` magic、version 9、seg_count 8 和保留字段，随后是 8 个 12 字节的 `{tag u32, offset u32, size u32}`，与 `src/compiler/ccr_io.cr:32-36` 头注一致。版本出处为 `ccr_io.cr:135` 的 `CCR_VERSION = 9`。

### 两组历史值的关系

`criteria-strength-audit` 表 C 第 2 条给出的四个值与各批提交信息和本表不一致。现已查明：这不是同一个对象的两种记录，而是同一测量方法在不同版本下的结果；版本变化有明确说明，也有旧值记录。

实际有三个版本，每个版本的出处如下：

| 版本 | 时间与格式 | 值（语料 A `ptr_arith`、语料 B `generics_test`，各两种命令） | 出处（`file:line`） | 版本内变化是否有说明 |
|---|---|---|---|---|
| G1 | P4 T7 结束 2026-09-13，v8（NOD 36B） | pa 90823B `fb4a3b59…`、90966B `592afa31…`；gt 134701B `cafb4278…`、134844B `ec8413ec…` | `docs/superpowers/plans/2026-09-12-r2-p4-carrier.md` 附录 D-1 表（T7 实测和复测逐条复现）、`TODO.md:474`、`TODO.md:444` | 无（起点） |
| G2 | P5 T7 2026-09-14，v8 | pa 不变，90823B `fb4a3b59…`、90966B `592afa31…`；gt 增加 640B，变为 135341B `ddec1ce6…`、135484B `cd2af565…` | `TODO.md:521`（P5 T7 复验）、`TODO.md:376`（P5 T5 时期） | 注：本次没有找到“原值到新值”的明确更新记录（P5 复验只记录了新值）。这一项记为记录缺失，不影响本检查，因为 G2 已被 G3 取代。 |
| G3（当前） | P6 T3 起 2026-09-14 至今，v9（NOD 40B） | pa 96015 `680a6f98…`、96158 `76f36e6a…`；gt 142793 `41e9d845…`、142936 `704316c8…` | `docs/archive/sdd/p6-task3-report.md:62`（P6 T3 更新基准值）、`p6-task4-report.md:81`（T4 复验四条逐字节相同）、本表〈`.ccr` 四项基准〉 | 有：逐条注明“原 …”，并记录 `delta = 4B × 节点数`（pa 增加 5192，等于 4×1298；gt 增加 7452，等于 4×1863） |

G3 之后的第四个版本（实施记录中说明）：gt 两条从 142793 和 142936 变为 142765 和 142908，减少 28 字节。变化原因是 `$HOME/.core/lib/<模块>/index` 是否存在，不是格式或内容变化，而是环境差异。检查脚本已在同一批中固定 `HOME` 并更新基准值。因此当前值以〈`.ccr` 四项基准〉表为准。

结论：审计表 C 第 2 条引用的四个值是 G2（P5 T7 版本），与本表不冲突。G2 到 G3 有明确说明（P6 T3 格式从 v8 改为 v9）。但 G1 到 G2 的 gt 变化缺少明确的更新记录。这正好说明本批的判断：只把值记在文档里不能作为检查，需要有“变化时说明原因”的规则（本检查脚本和〈更新基准值的规则〉）。否则每个版本都会留下一个不知道值为什么变化的问题。

版本变化的原因（原文摘录）：`p6-task3-report.md:62` 写“pa ccr 96015B `680a6f98…`（原 90823 `fb4a3b59…`）、pa static 96158B …（原 90966 `592afa31…`）、gt ccr 142793B …（原 135341 `ddec1ce6…`）、gt static 142936B …（原 135484 `cd2af565…`）；delta = 4B × 节点数（pa +5192 = 4×1298；gt +7452 = 4×1863）”。即 NOD 记录从 36 字节变为 40 字节（TYPE 段文件空间项索引），每个节点增加 4 字节，四条同步增大并明确更新。审计表 C 引用的旧四值是 P4、P5 时期（v8）的记录值。

因此检查规则分两类。不能写成“永远不应变化”，否则每次正常的格式或内容变化都会导致检查失败，P6 T3 那次更新基准值就会遇到这个问题；也不能写成“可以随意变化”，那等于没有检查。

| 检查 | 性质 | 值变化时如何处理 |
|---|---|---|
| ELF 基准 | 检查生成结果没有变化 | 停止并上报（变化表示类型或产物层的改动进入了生成结果）。只有维护者明确声明生成结果变化并作出决定，才在同一批更新基准值 |
| `.ccr` 四项 | 检查格式和内容形状 | 值变化不一定是回归。先查明原因：格式或版式变化，还是内容变化。原因明确时在同一批更新基准值并保留旧值；原因无法确定或指向生成结果时，按回归处理，停止并上报 |

依据是两次有说明的更新：P6 T3 是格式变化（v8 到 v9，4B×节点数）；P4 T3 是内容变化（`TODO.md:444` 记录“STR 增长实测 +16 串/+156B”和“TYPE 段 +360~400B”）。相反的例子是 `TODO.md:454` 的“用户程序零变化”，那是该批预期 `.ccr` 不变的正面检查。

这个检查要发现的是没有说明的变化，不是变化本身。

只检查空缓存状态。不要补成“空缓存和有缓存都检查”，否则会在已知的例外情况上导致检查失败。第一，所有记录值都是空缓存状态，检查脚本复现的就是记录条件。第二，P4 附录 D-1 写明，非可选程序的空缓存与有缓存结果不同，这是先前已存在的问题（pre-P4 二进制也有同样问题，89086/88954），并且已经豁免（TODO #2026-09-10-1 末条家族）。检查有缓存状态会把已登记豁免的已知差异变成失败检查。第三，有缓存状态在这两份语料上没有区分能力。T1 表 B 8c 实测四条空缓存结果与有缓存结果相同（`cap-task1-report.md:84`），而且 `generics_test` 是构造性的：包含泛型，`src/compiler/main.cr:480-486`（`:484` 置 0）设置 `cache_enabled = 0`，所以空缓存与有缓存结果相同。有缓存状态另有专门的自动检查（`tests/selfhost/test_warm_cache_gate.py` 已接入 CI，`tools/baseline/warm_leg.sh` 是手工广度检查），因此这里不检查不代表没有人检查。注：如果将来这两份语料的空缓存与有缓存结果出现差异，空缓存检查仍然有效；有缓存侧的差异由有缓存检查负责，不并入这里。

### 当前基准值

以下为历史记录。写本文时构建资源被占用，实测结论见实施记录〈构建资源可用后的真实运行〉和〈第一次发现 CI 失败〉。

四项 `.ccr` 值和 ELF 基准最近一次同源实测来自进行中的计划 `docs/superpowers/plans/2026-09-16-global-operand-seams.md:325-326`（该计划要求 ELF 基准不变，`.ccr` 四项基准值不变）。本批没有运行构建（构建资源被 `plan-reffix` 占用，见〈本批约束〉）。因此写入本文时，四个值标为“待实测”。T4 结束时需要在构建资源可用后运行一次 `tools/baseline/canary_check.sh`，并用通过结果验证。如果检查失败，先按〈两组历史值的关系〉中的两类规则查明原因：ELF 基准属于生成结果，停止并上报；`.ccr` 四项只有在原因明确时才能在同一批更新基准值，原因无法确定或指向生成结果时按回归处理。两种情况都不能直接修改基准值（见〈更新基准值的规则〉）。

## 检查脚本的设计

### 组成

| 文件 | 作用 |
|---|---|
| `tools/baseline/canary_values.tsv` | 基准值的唯一来源：`name<TAB>artifact<TAB>sha256<TAB>size`，共 5 条。文件头注明生成方法、出处和适用范围 |
| `tools/baseline/canary_check.sh` | 检查脚本：按〈检查的生成方法〉生成 5 件产物，与值表逐条比较 sha256 和大小 |
| `tests/harness/test_canary_carrier.py` | 自测：检查 CI 接入是否正确，并做合成自测（无编译器）和真实产物改动测试（有编译器时） |

### `canary_check.sh` 的接口

```
bash tools/baseline/canary_check.sh [<corec二进制>]        # 默认 ./build/corec
    采集（5 条编译，逐条 clean-cache）并校验；rc=0 全部通过，1 任一不符，2 用法错误
bash tools/baseline/canary_check.sh --verify-only [<dir>]  # 只校验既有产物（不编译）
bash tools/baseline/canary_check.sh --selftest             # 合成文件自测（无编译器，毫秒级）
环境：CANARY_VALUES=<tsv>（值表路径，默认仓库内的值表）· CANARY_NO_NICE=1（不使用 nice）
```

采集目录默判定 `build/canary_artifacts/`（`build/` 不进入版本库）。脚本不构建编译器。运行前需要 `./build/corec` 存在，并且 `./build/corearch` 在同一目录（`build` 路径按 `src/compiler/main.cr:713-721` 使用 `get_arg(0)` 的目录拼接 `corearch` 调用）。

### 失败时中止的四条规则

每条规则对应一种已知的失败情形，这些情形都不会报错：

| 编号 | 规则 | 对应的失败情形 |
|---|---|---|
| F1 | 任一步 rc 不为 0 就失败（包括编译失败、产物缺失） | 编译失败但没有产物，于是跳过断言并显示通过 |
| F2 | 值表缺少名称，或条目数不是 5，就失败 | 值表被改小，检查数量减少，却显示全部通过 |
| F3 | 逐条比较 sha256 和字节数，任一项不符就失败，并打印期望值和实际值 | 只比较大小，内容改变但大小相同，显示通过。单独报告大小可以更早发现问题 |
| F4 | 工具缺失（没有 `build/corec`，没有 `sha256sum`）就失败 | 缺少工具时没有执行检查，却显示通过 |

### 对产物没有影响

本批只新增三个文件，并修改注释和 CI 接入点，没有修改 `.cr` 源码。因此 `build/corec` 和 `build/corearch` 的二进制不变，ELF 基准和四项 `.ccr` 的生成过程逐字节不变。这是从改动范围得到的判断，实测验证见〈两组历史值的关系〉中的通过记录。唯一的间接影响是 `build/canary_artifacts/` 目录。它存放构建产物，`build/` 不进入版本库。每条命令的 `clean-cache` 只作用于相对于当前工作目录的 `.core/cache/cir/`（`main.cr:408-414`），不写入源码目录，也不写入基准值。

### 检查脚本如何自测

`canary_check.sh --selftest` 在临时目录生成合成文件和对应的值表，逐条验证检查逻辑本身：

| 子检查 | 输入 | 期望结果 |
|---|---|---|
| S1 | 合成文件与对应的值表一致 | 通过（证明正常情况下可以通过，不是始终失败） |
| S2 | 大小相同，改动一个字节 | 失败（证明比较的是 sha256，不只是大小） |
| S3 | 截断一个字节（大小改变） | 失败 |
| S4 | 删除产物文件 | 失败（文件缺失） |
| S5 | 值表删除一条 | 失败（检查数量减少） |
| S6 | 值表的期望 sha256 换成错误值 | 失败，消息包含“期望 … 实际 …” |

`tests/harness/test_canary_carrier.py` 再加两层检查。第一层是自动检查：`run.sh` 确实调用了检查脚本和这个测试，否则会再次出现“声称已接入”的问题。第二层是真实产物改动：采集真实产物，改动 `pa.ccr` 的一个字节，`--verify-only` 应当失败。第二层在真实数据上确认“值不符就失败”。

## 接入 CI（T2）

| 位置 | 改动 |
|---|---|
| `src/ci/run.sh` 的 `selfhost-tests` job | 在末尾追加 `bash tools/baseline/canary_check.sh`（自动检查）和 `python3 tests/harness/test_canary_carrier.py`（自测） |
| `tests/harness/ci_hook_allowlist.txt` | 新测试文件已接入，不进入允许清单；`test_mw_task2.py` 条目的理由列按 T3 的实际情况改写 |
| `tests/harness/test_ci_hook_coverage.py` | 不需要修改规则（新测试文件在 SCOPE 内且已接入，差集不变）；注释中的实测基线计数同步更新 |
| `src/ci/run.sh` 注释 | 在接入点旁按“注释即检查”的体例写明：值表出处、两种形式、为什么接入 `selfhost-tests`（需要已验证的编译器） |

这个检查接入 `selfhost-tests` 而不是 `bootstrap-tests`，原因是它需要已构建的 `build/corec` 和 `build/corearch`，并且 `build` 路径要包含 `corearch`。`selfhost-tests` 第一行就运行 `build_selfhost`（`src/ci/run.sh:78`），而 `bootstrap-tests` 不构建编译器。开销是 1 个 ELF 基准产物和 4 次 `.ccr` 生成（2 份语料 × 2 种命令），语料为 240B 和 2.5KB，都在秒级；`--selftest` 和自动检查在毫秒级。

## T3：修复零差异检查在缺少基线时跳过的问题

核实结果：`tests/selfhost/test_mw_task2.py:284-303` 的零差异检查分支中，`else` 分支（`:301-303`）只执行 `print("[SKIP] …")`，没有设置 `ok = False`。基线位于 `build/mw_task2_zdiff/`（`:44` 为 `ZDIFF = BUILD / "mw_task2_zdiff"`；`build/` 不进入版本库），而 `run.sh` 从不传入 `--snapshot`（已读全文，没有匹配）。因此这项检查可能完全不执行：新克隆或 CI 中始终显示 `[SKIP]`，但返回码为 0。

修改方法：默认在基线缺失时判定为失败（`ok = False`，`[FAIL]` 行包含补救命令）；只有显式传入 `--allow-skip` 时才保留 `[SKIP]`。`--snapshot` 的含义不变。同一批在 `ci_hook_allowlist.txt` 的 `test_mw_task2.py` 条目理由列写明现状（该文件没有接入 CI，只影响本地手动运行）、没有接入 CI 的原因和开销估算。

## 本批约束

- 本批不运行构建（构建资源被 `plan-reffix` 批占用）。需要二进制才能验证的项目一律标为“待实测（等构建资源）”，不能把待测写成已测。
- 只使用 `jj`（铁律 #2）；提交时限定路径；写文件后立即运行 `jj status`。
- 计划中的每个 `file:line` 都已亲自阅读确认（见〈检查的生成方法〉的逐条出处）。
- 生成方法不猜测：〈检查的生成方法〉中的方法全部来自可执行原文（`/tmp/capt1/t1b_criteria.sh`）和报告原文，值经过三处独立采集（`/tmp/capt1`、`/tmp/capt6`、`/tmp/fct3`）实测一致。

## 更新基准值的规则

只在这里更新基准值。两类规则见〈两组历史值的关系〉。

原则：这个检查要发现的是没有说明的变化，不是变化本身。因此“不一致”的处理按检查类型区分：

| 检查 | 值变化时 | 更新条件 |
|---|---|---|
| ELF 基准（生成结果没有变化） | 停止并上报（默认按超出范围处理） | 只有维护者明确声明生成结果变化并作出决定，才在同一批更新基准值 |
| `.ccr` 四项（格式和内容形状） | 先查明原因：格式或版式变化，还是内容变化（对照〈两组历史值的关系〉中的两次先例） | 原因明确时在同一批更新基准值；原因无法确定或指向生成结果时，按回归处理，停止并上报 |

1. 先查明原因再更新。没有说明的变化一律按回归处理。`p6-task3-report.md:62` 的写法（“原 …，新 …，delta = 4B × 节点数”）之所以有用，是因为它让一次变化可以被审阅。
2. 不能因为运行结果不一致就修改值表使其一致。那正是这个检查要发现的、没有说明的变化。
3. 更新需要在同一批记录：旧值、新值、原因和出处提交。旧值不删除（记录位置为 `tools/baseline/canary_values.tsv` 头注和本计划）。
4. “停止并上报”是默认处理（如果是回归就修复回归，如果超出范围就由维护者决定），不是修改值表。
5. 另一种用法：如果某一批预期 `.ccr` 不变（例如 P4 T5 的“用户程序零变化”），该批可以把这项检查作为正面证据。此时“通过”就是证据，需要在批次报告中引用检查脚本的输出。
6. 适用范围（2026-09-16 CI 失败后补充，需要和基准值放在一起）：`.ccr` 四项从 2026-09-16 起以“环境归一化（受控的空 `HOME`）下的产物”为基准。在此之前的所有 gt 基准值（142793/142936，G3 期间）都不能跨机器复现：它们是在本机存在 `~/.core/lib/io/index` 时测得的。因此此前所谓“基准值与记录一致”都隐含依赖这个文件存在；在没有该文件的机器上（例如 CI runner）检查必然失败。这不是例外，而是这项检查的适用范围。详见 `tools/baseline/canary_values.tsv` 头注和〈第一次发现 CI 失败〉。

## 尚未接入 CI 的检查

以下项目前仍靠人工执行，附接入 CI 的开销估算：

| 编号 | 检查 | 现状 | 接入 CI 的开销估算 |
|---|---|---|---|
| U1 | `test_backend_bootstrap.py`（N06 未检出问题的唯一检查） | 没有接入 CI（允许清单中的“最高危”条目） | 中等：需要 corec 和目录 project-mode 构建一次；时长未实测，需要先测量 |
| U2 | `.cir` DOT 165915B、`b1bdf480…` | 只靠人工（没有自动检查） | 低：与 `.ccr` 一样是单份 `ccr cir` 产物，可以按本批的方法加入 `canary_values.tsv`。但 DOT 输出包含行号和名字，会随编译器源码改动而变化，风险较高，需要先确定记录方式 |
| U3 | `--dump-objects` 3521 行 | 只靠人工 | 低到中等：`corearch <ccr> --dump-objects \| wc -l`；行数同样有 U2 的变化风险 |
| U4 | 自举链 `corec2 == corec3`、N06=0、快速验证 42、`--help` rc=1 | 已接入 `full-bootstrap`（`run.sh:132-143`），但 `full` 层在免费计划下只能通过 `workflow_dispatch` 触发 | 0（已经是自动检查，缺少的是触发） |
| U5 | `test_mw_task1/3/4/5/6.py`（M1 多字族） | 没有接入（允许清单中的同类项） | 中等：需要 corec；`test_mw_task2` 修完后在同一批评估 |
| U6 | `test_hit_table.py`、`test_lsp.py`、`test_live_ranges.py` 等 23 个 selfhost 档 | 没有接入（允许清单逐条列出） | 各档不同（多数需要 corec，开销中等）；原因是还没有专门扩充 CI 接入的批次，本批不扩充 |
| U7 | `selftest-types 415/415` | 已接入 `selfhost-tests`（`run.sh:94`），但计数下限由套件内的 `MIN_CASES` 保证，两处约定需要人工同步 | 低：可以用自动检查确认 `run.sh` 注释中的计数等于 `test_type_engine.py:MIN_CASES` |
| U8 | `tools/baseline/parity_run.sh`、`probes_run.sh`、`warm_leg.sh` 广度检查 | 没有接入（CI 不可行：需要 jj 和完整历史，CI 的浅检出没有 jj） | 无法接入（登记为最终状态） |
| U9 | `test_mw_task2.py` 零差异断言 | 本批 T3 改为“缺失即失败”后仍是本地检查 | 低到中等：接入它需要在改动前的编译器上先生成基线，CI 在结构上无法做到（拿不到基线阶段）；T3 的修改方法和允许清单中的理由用于如实说明这一点 |

## 本批的验收条件

- T1：`bash tools/baseline/canary_check.sh --selftest` rc=0（S1 至 S6 全部按设计工作）；`python3 tests/harness/test_canary_carrier.py` rc=0。
- T1 真实检查（待实测，等构建资源）：`bash tools/baseline/canary_check.sh` rc=0（5/5）。
- T2：`python3 tests/harness/test_ci_hook_coverage.py` rc=0（新接入点不改变差集；允许清单不失效）。
- T3：`python3 tests/selfhost/test_mw_task2.py` 在没有基线时 rc=1（修改前为 rc=0）；带 `--allow-skip` 时 rc=0。
- 对产物没有影响：五个 CI job、全部枚举、ELF 基准和四项 `.ccr`，待实测（等构建资源）。
