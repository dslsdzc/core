# 把常用检查接入 CI（criteria-carrier）（实施记录）

> 对应计划：[plans/2026-09-16-criteria-carrier.md](../plans/2026-09-16-criteria-carrier.md)

## 概述

本记录覆盖把 canary 检查与自测接入 CI 的 T1 至 T3。计划写作时的状态为 T0 调查完成，T1 至 T3 实施中。T1 至 T3 在构建资源被其他阶段占用期间没有运行编译，先用已有产物和临时目录完成检查脚本、自测断言和接入点的验证。构建资源可用后，从 2026-09-16 04:49 起串行运行真实编译，完成脚本采集、CI 接入端到端、五个 CI job 和 62 档全枚举。期间发现并修复了本机 `$HOME/.core/lib/io/index` 使 `generics_test` 的 `.ccr` 多出 28 字节的问题，检查脚本改为把 `HOME` 固定到采集目录内的空目录。终态为五个 CI job 全部 rc=0，全枚举 62/62 rc=0，检查脚本 5/5，自测 7/7。

## 改动

### T1 至 T3：检查脚本、自测与接入点

T1 至 T3 的实测均未运行编译，构建资源被进行中的阶段占用。E1 至 E13 的验证覆盖检查脚本自测、真实产物校验、接入前后的自测、覆盖率检查、参数解析、采集路径端到端、产物时间检查和文档取证。

`canary_check.sh --selftest` 的 6/6 通过。S1 证明正常情况可以通过，S2 至 S6 覆盖五种会失败的情况。`--verify-only` 对 `/tmp/capt6` 与 `/tmp/fct3` 两处采集的真实产物各 5/5 通过。`pa.ccr` 改动一个字节后返回 rc=1，指出 `pa_ccr` 并打印期望值和实际值，其余四条仍通过。把 `pa_static_ccr` 的值误拷进 `pa.ccr` 槽的变体返回 rc=1，大小和 sha256 两条失败。

接入前 `python3 tests/harness/test_canary_carrier.py` 返回 rc=1，A1 与 A2 两项失败，说明检查没有真正接入；B 通过。接入后返回 rc=0，A1、A2、A3、B 全部通过；C 显式 `[SKIP]`，因为临时目录结构没有编译器。`python3 tests/harness/test_ci_hook_coverage.py` 返回 rc=0，`scope=65`，`hooked=38`，`unhooked(allowlisted)=27`，差集不变；新测试已接入，不进入允许清单。

`tests/selfhost/test_mw_task2.py --help` 显示新的 `--allow-skip` 选项已经就位。该检查只经过 argparse 解析后退出，不运行用例。采集路径的端到端测试使用模拟编译器，回应相同形式的 CLI，并用 `/tmp/capt6` 的真实产物作为响应，运行 `canary_check.sh` 默认模式，返回 rc=0，采集和校验全部通过 5/5。参数构造、逐条 `clean-cache`、执行顺序、`-o X` 生成 `X.ccr` 的规则都经过真实代码路径；只有编译一步由模拟器代替。执行顺序中，基准先写入 `pa.ccr`，`ccr` 步骤随后覆盖它。

自测的产物时间检查来自 E10 发现的错误通过。采集目录存在但比 `build/corec` 旧，即来自上一代二进制时，不能复用，需要重新采集。`test_canary_carrier.py` 的 C 层已实现 mtime 判断。CI 中 `run.sh` 先运行检查脚本，因此产物总是新的；这项检查只用于本地运行或顺序错误。

E12 结束 T0 的追加项。两组 `.ccr` 的四个值是同一测量方法在不同版本下的结果，旧 v8 为 `fb4a3b59…`、`592afa31…`、`ddec1ce6…`、`cd2af565…`，新 v9 为本表的值，不是无说明的变化。出处逐条查到 `file:line`，包括 P4 附录 D-1 表、`TODO.md:474`、`:521`、`:376`，以及 `p6-task3-report.md:62` 的「原 …」注。143 字节的原因是 `--static` 前置 `rt.cr`（`main.cr:433-437`，P4 D-1 已查明）。ELF 基准 28822B 是 ELF 文件大小，已实际检查 `\177ELF` 和 `-rwxr-xr-x`。

E13 在检查规则改写后全部重跑。值表头重写，包含两类规则、只检查空缓存、两组历史值的关系。`--selftest` 6/6，两套真实产物 `--verify-only` 各 5/5，最小测试环境自测通过。

### CI 接入开销

检查脚本单独运行 1.04 秒，包含 5 条采集和校验。自测单独运行 2.24 秒，其中 C 层复用检查脚本刚生成的 `build/canary_artifacts/`，没有额外编译。在 `CI_JOB_NAME=selfhost-tests` 中合计增加约 3.3 秒，该 job 全程 78 秒。因此每次 PR 的 CI 增加约 3 秒。

### 构建资源可用后的真实运行

真实运行从 2026-09-16 04:49 起。串行等待 `plan-reffix` 的 parity、probes、warm 链结束后才开始，没有与其并行。

检查脚本默认模式使用真实采集，命令为 `bash tools/baseline/canary_check.sh`，返回 rc=0，5/5 通过，耗时 1.04 秒。五条与值表逐条相同：ELF 基准 `95084e7b…d475`、28822B；pa 的 96015 为 `680a6f98…`，96158 为 `76f36e6a…`；gt 的 142793 为 `41e9d845…`，142936 为 `704316c8…`。四项 `.ccr` 预期不变已由实测确认。#8 与 #25 的修复对这两份语料在结构上不可达，该判断成立。

自测的 C 层真实运行为 `test_canary_carrier.py --require-compiler`。第一次运行 rc=1，C 层发现测试自身的断言字面量错误，见 E17。修复后 rc=0，7/7，2.24 秒，包含「真实产物改动一个字节就失败并指出 `pa_ccr`」和「缺少产物就失败」。

E17 的原因和修复如下。检查脚本输出「期望(expected)= … 实际(actual)=」，`expected` 和 `=` 之间隔着一个 `)`，而断言写成了 `expected=`，所以始终匹配不到，始终错误地判定为失败。修复方法是将断言改为 `(expected)=` 和 `(actual)=`。`--selftest` 的 S2 和 S6 使用 grep 正则，模式中本来就包含 `(expected)=`，因此一直正确；B 层没有发现，C 层发现了。这说明自测检查的是检查脚本和断言本身，不是产物。

CI 接入端到端命令为 `CI_JOB_NAME=selfhost-tests bash src/ci/run.sh`，返回 rc=0，78 秒。日志中确实出现检查脚本 5/5 和自测 7/7，即 `[canary] PASS 5/5` 和 `[canary-carrier] PASS — pass=7 skip=0`，因此接入确实生效，不是注释里声称已接入。

T3 自证 A5 修复的失败中止行为。测试在隔离目录 `/tmp/mw_nobase` 运行，只软链 `build/corec` 和 `corearch`，没有 `mw_task2_zdiff` 基线，不影响共享的 `build/`。默认规则 rc=1，出现 9 条 `[FAIL] … zero-diff baseline missing … 默认 fail-closed`；修改前同一情况为 `[SKIP]` 且 rc=0。`--allow-skip` 时 rc=0，并显式显示 `[SKIP]` 和补救命令。有基线时全部通过，rc=0。

### CI 首次失败与 HOME 归一化

第一次 CI 失败发生在 2026-09-16，PR #80 的 `selfhost-tests`，运行编号 35025346214。`canary_elf`、`pa_ccr`、`pa_static_ccr` 全部通过。`gt_ccr` 从 142793 变为 142765，`gt_static_ccr` 从 142936 变为 142908，各减少 28 字节。

排除其他原因时逐条实测，避免误判。不是目录树不同：CI 日志为 `scope=64 hooked=37`，与本次未修改的复现树的 54 加 7 加 3 一致。不是源码路径，维护者已测。不是先运行测试造成影响：未修改的目录运行完整的 `selfhost-tests` 仍然 5/5。不是 Python 版本：`python3.13` 和 `3.14` 重建 `build/corec` 的 sha256 逐字节相同，为 `5a2ad474…`。

原因已确认。编译器解析 `import` 时读取 `$HOME/.core/lib/<模块>/index`，并把其中声明的函数名保留进字符串表（`src/compiler/module.cr:523-530`）。本机存在 `~/.core/lib/io/index`，大小 164B。`generics_test` 使用 `import io` 和 `import fmt`，因此多保留了 `print_int`（9 字节）和 `println_int`（11 字节），正好 28 字节。CI 没有这个文件，所以少 28 字节。`ptr_arith.cr` 没有 import，从不读取 `$HOME`，所以 pa 的三条检查全部通过。段级定位显示，差异全部在 STR 段，从 2521 变为 2493，其余七段逐字节相同。

在本机将 `HOME` 设为空目录，得到的 size 和 sha256 与 CI 逐条相同，值为 `d92a2727…` 和 `a1f7b99c…`。

修复选择方案 A，本次实施。检查脚本把 `HOME` 固定为采集目录内的空 `home/`，并设置 `CORE_SAFE=1`，同时在输出中打印实际值。`.ccr` 四项中 gt 的两项在同一组更新为 142765 和 142908，同时保留旧值并注明适用范围。不能 unset 或置空 `HOME`，因为 `module.cr:526` 有硬编码的 `/home/DslsDZC` 后备路径，已单独登记 TODO #2026-09-16-21。

「解耦」的准确含义由维护者于 2026-09-16 确定。原方案 A 条件 4 的表述经实测更正。解耦指检查结果不受检查脚本控制范围之外的任何 `HOME` 影响，包括开发者机器、CI runner 和其他人的机器。V1 证明：开发者的 `HOME` 包含 `io/index` 时，检查仍然 5/5 通过。检查脚本自己控制的 `HOME` 是检查输入的一部分：每次采集都用 `rm -rf` 重建为空目录，因此外部无法在运行中改变它，也不应假装它不影响结果。V2a 和 V2b 证明：放入索引产物后结果确实变化，此时检查失败才是正确行为，因为这改变了输入，不是环境干扰。如果将来需要检查「索引存在」的情况，应另立语料和生成方法，不要放宽这项检查。

原条件 4 把「与外部环境解耦」和「对自己控制的输入不敏感」混为一谈。后者不成立：受控的 `HOME` 就是编译器实际使用的 `HOME`。这项更正由双方确认。

## 验收结果

### T1 至 T3 实测（无编译器）

| 编号 | 项目 | 结果 | 性质 |
|---|---|---|---|
| E1 | `canary_check.sh --selftest` | rc=0，6/6。S1 证明正常情况可以通过，S2 至 S6 五种情况会失败。 | 实测，无编译器 |
| E2 | `--verify-only` 对 `/tmp/capt6` 采集的真实产物（2026-09-16，全局 seam 阶段进行中的采集体） | 5/5 通过 | 实测，无编译器 |
| E3 | `--verify-only` 对 `/tmp/fct3` 采集的真实产物（2026-09-15，fail-closed T3 采集体，另一个目录、另一个阶段） | 5/5 通过 | 实测，无编译器 |
| E4 | 真实产物 `pa.ccr` 改动一个字节，大小不变，运行 `--verify-only` | rc=1，指出 `pa_ccr`，打印期望值和实际值，其余 4 条仍通过 | 实测，无编译器 |
| E5 | 误将 `pa_static_ccr` 的值拷入 `pa.ccr` 槽（S2 的「值不符」变体） | rc=1，大小和 sha256 两条失败 | 实测，无编译器 |
| E6 | `python3 tests/harness/test_canary_carrier.py`（接入前） | rc=1，A1 与 A2 两项失败，发现没有真正接入；B 通过 | 实测，临时目录结构，无 `build/` |
| E7 | 同上，接入后 | rc=0，A1、A2、A3、B 全部通过；C 显式 `[SKIP]`，该临时结构无编译器 | 实测，临时目录结构 |
| E8 | `python3 tests/harness/test_ci_hook_coverage.py` | rc=0，`scope=65`，`hooked=38`，`unhooked(allowlisted)=27`。差集不变；新测试已接入，不进入允许清单。 | 实测，纯 Python |
| E9 | `tests/selfhost/test_mw_task2.py --help` | 新的 `--allow-skip` 选项已就位 | 实测，argparse 解析后退出，不运行用例 |
| E10 | 采集路径端到端：模拟编译器回应相同形式的 CLI，用 `/tmp/capt6` 的真实产物作为响应，运行 `canary_check.sh` 默认模式 | rc=0，采集和校验全部通过 5/5。参数构造、逐条 `clean-cache`、执行顺序和 `-o X` 生成 `X.ccr` 的规则都经过真实代码路径，只有编译一步由模拟器代替。 | 实测，未运行编译 |
| E11 | 自测的产物时间检查，E10 发现的错误通过问题：采集目录存在但比 `build/corec` 旧（来自上一代二进制） | 不能复用，需要重新采集。`test_canary_carrier.py` 的 C 层 mtime 判断已实现。CI 中 `run.sh` 先运行检查脚本，因此产物总是新的，这项检查只用于本地运行或顺序错误。 | 实测，代码路径和最小测试环境重新运行 |
| E12 | T0 追加项结案：两组 `.ccr` 四个值是同一测量方法在不同版本下的结果 | 旧 v8 为 `fb4a3b59…`、`592afa31…`、`ddec1ce6…`、`cd2af565…`，新 v9 为本表的值，不是无说明的变化。出处逐条查到 `file:line`：P4 附录 D-1 表、`TODO.md:474`、`:521`、`:376`、`p6-task3-report.md:62` 的「原 …」注。143 字节的原因是 `--static` 前置 `rt.cr`（`main.cr:433-437`，P4 D-1 已查明）。ELF 基准 28822B 是 ELF 文件大小，已实际检查 `\177ELF` 和 `-rwxr-xr-x`。 | 实测，文档和产物取证，未运行编译 |
| E13 | 检查规则改写后全部重跑：值表头重写（两类规则、只检查空缓存、两组历史值的关系） | `--selftest` 6/6，两套真实产物 `--verify-only` 各 5/5，最小测试环境自测通过 | 实测，未运行编译 |

E1 至 E7 说明 S1 至 S6 全部按设计工作。「改动一个字节就失败并指出产物」已经用 `/tmp/capt6` 和 `/tmp/fct3` 两处采集的真实产物运行通过，没有运行编译。只有「由检查脚本自己采集真实产物」这一步要等构建资源。

E4 和 E5 不只证明比较的是 sha256，而不是只比较大小。它们还证明失败时能指出原因，即指出产物并打印期望值和实际值。检查失败但没有人看得懂，同样是检查失效的情况。

### 构建资源可用后的真实运行

| 编号 | 项目 | 结果 | 性质 |
|---|---|---|---|
| E15 | 检查脚本默认模式（真实采集）`bash tools/baseline/canary_check.sh` | rc=0，5/5 通过，1.04 秒。五条与值表逐条相同：ELF 基准 `95084e7b…d475`、28822B；pa 96015 为 `680a6f98…`，96158 为 `76f36e6a…`；gt 142793 为 `41e9d845…`，142936 为 `704316c8…`。四项 `.ccr` 预期不变已由实测确认。 | 实测，真实编译 |
| E16 | 自测的 C 层真实运行 `test_canary_carrier.py --require-compiler` | 第一次运行 rc=1，C 层发现测试自身的断言字面量错误，见 E17。修复后 rc=0，7/7，2.24 秒，包含「真实产物改动一个字节就失败并指出 `pa_ccr`」和「缺少产物就失败」。 | 实测，真实编译 |
| E17 | E16 错误的原因和修复 | 检查脚本输出「期望(expected)= … 实际(actual)=」，`expected` 和 `=` 之间隔着 `)`，断言写成 `expected=`，因此始终匹配不到，始终错误地判定为失败。修复为 `(expected)=` 和 `(actual)=`。`--selftest` 的 S2 与 S6 使用 grep 正则，模式中本来就有 `(expected)=`，因此一直正确；B 层没有发现，C 层发现了。 | 实测，真实编译 |
| E18 | CI 接入端到端 `CI_JOB_NAME=selfhost-tests bash src/ci/run.sh` | rc=0，78 秒。日志中出现 `[canary] PASS 5/5` 和 `[canary-carrier] PASS — pass=7 skip=0`，接入确实生效。 | 实测，真实编译 |
| E19 | 五个 CI job 全部 rc=0 | `bootstrap-tests` rc=0，包含 hook-coverage 的 `scope=65`、`hooked=38`、`unhooked=27`，`BLOCK 20` 与 `ALLOW 16` 合计 36/36；`check` rc=0，30 秒；`suite` rc=0，19 秒；`selfhost-tests` rc=0，78 秒；`full-bootstrap` rc=0，676 秒。 | 实测，真实编译 |
| E20 | `full-bootstrap`（自举链） | rc=0，676 秒，N06 计数 0。`corec2 == corec3` 的 `cmp` 结果相同，两者都是 2892374B，sha256 都是 `093ba2305c204fdd1ce1ad892af21ade75fb79dfcb3957fdc897affd73d9c814`。 | 实测，真实编译 |
| E21 | T3 自证 A5 修复的失败中止行为 | 在 `/tmp/mw_nobase` 运行，只软链 `build/corec` 和 `corearch`，没有 `mw_task2_zdiff` 基线，不影响共享的 `build/`。默认规则 rc=1，9 条 `[FAIL] … zero-diff baseline missing … 默认 fail-closed`；修改前同一情况为 `[SKIP]` 且 rc=0。`--allow-skip` 时 rc=0，并显式显示 `[SKIP]` 和补救命令。有基线时全部通过，rc=0。 | 实测，真实编译 |
| E22 | 全部枚举（套件全集为 `tests/selfhost/test_*.py` 55 个和 `tests/bootstrap/test_*.py` 7 个） | 62/62 rc=0，207 秒。没有 FAIL；判定标准是输出中没有 `FAIL:` 行，不只是计数。 | 实测，真实编译 |

本次只新增 3 个文件，修改注释和接入点，没有修改 `.cr` 源码。因此 ELF 基准和四项 `.ccr` 逐条相同，见 E15。从改动范围得到的判断与实测一致。

### HOME 归一化验证

| 编号 | 场景 | 结果 |
|---|---|---|
| V1 | 新建目录，检查脚本使用默认设置，开发者的 `$HOME` 仍包含 `io/index` | 5/5 通过。输出包含 `[canary] 环境归一化：HOME=<采集目录>/home（空目录，已建）· CORE_SAFE=1`，因此检查结果不受开发者 `$HOME` 影响。 |
| V2a | 有效的 `HOME` 包含真实的 `io/index`，直接运行编译器，绕过检查脚本 | 142793B，`41e9d845…`，等于旧基准值。原因在两个方向上都能复现：有索引时为 142793，无索引时为 142765。 |
| V2b | 有效的 `HOME` 包含无害索引，只列出已保留的名称 `print` 和 `read_file` | 大小相同，为 142765，但 sha256 不同。STR、SYM、NOD、IFACE 四段内容变化，说明结果取决于索引是否存在，不只是索引中的新名称。 |

## 遗留问题

- `module.cr:526` 有硬编码的 `/home/DslsDZC` 后备路径，因此不能 unset 或置空 `HOME`。该问题已登记 TODO #2026-09-16-21。
- 自测的 C 层在没有编译器的临时目录中显式 `[SKIP]`。本地运行需要编译器时，要加 `--require-compiler` 才能执行 C 层。
- 如果将来需要检查「`$HOME` 索引存在」的情况，需要另立语料和生成方法。当前检查不放宽，也没有为该情况准备语料。
- 产物时间检查只用于本地运行或顺序错误。CI 中 `run.sh` 先运行检查脚本，产物总是新的，这条路径没有在 CI 中触发。

## 不包含

- T1 至 T3 期间没有运行编译，构建资源被进行中的阶段占用。
- 没有修改 `.cr` 源码。本次只新增 3 个文件，修改注释和接入点。
- 没有 unset 或置空 `HOME`。
- 没有放宽「索引存在」的检查，也没有为该情况新增语料。
- 没有把产物时间检查扩展到 CI 的正常顺序，因为 CI 中产物总是新的。
