# R2 P3 能力阶段实施记录

> 对应计划：[plans/2026-09-11-r2-p3-capabilities.md](../plans/2026-09-11-r2-p3-capabilities.md)

## 概述

R2 P3 能力阶段分 P3a 和 P3b 两个阶段。P3a 交付 Task 0、Task 1、Task 3、Task 4、Task 5 和 Task 7，提交链为 `61d3a8b4`、`ef61f002`、`e9818d62`、`c8c7731b`、`9c0a83ec`，另加结束提交。P3b 交付 Task 0b、Task 2、Task 6 和 Task 7b，提交链为 `9aa1786c`、`44100ba4`、`e838f18b`，另加 Task 7b 结束提交。2026-09-12 的更新记录显示 P3 全阶段结束。P3b 开工期的阻塞、接线和登记内容在附录 B；P4 开工必读材料是附录 C，也就是实现方式交接包。

## 改动

### Task 0 引擎展开层

本任务为纯新增，新增 502 行，删除 0 行。用例从 212 增加到 229。行为没有变化，72 档语料在三个面上的 diff 为空。提交为 `61d3a8b4`。报告在 `docs/archive/sdd/p3-task0-report.md`。

### Task 1 定长移除结束

用例从 229 增加到 249。本任务收紧 6 项，放宽 0 项。修复的问题是「切片到固定长」被不报错地放宽。提交为 `ef61f002`。报告在 `docs/archive/sdd/p3-task1-report.md`。

### Task 0b（P3b）`iface_satisfies` 契约回补

本任务实现三态契约。分派轴为 A>C>B。实例化点 `T: I` 做真判定。全语料零命中，收紧 6 项，放宽 0 项。ELF 和 `.ccr` 逐字节相同。提交为 `9aa1786c`。报告在 `docs/archive/sdd/p3b-task0-report.md`。

### Task 2 横切接口

用例从 304 增加到 319。本任务处理六形状项，包括 `⊤ₖ` 形和只读与可写分野。本任务完成索引与切片消费点换位。收紧 0 项，放宽 0 项。行为保持的证据是：12 个用例在旧、新两个二进制上相同，全语料零差异。ELF 和 `.ccr` 逐字节相同。提交为 `44100ba4`。报告在 `docs/archive/sdd/p3b-task2-report.md`。

### Task 3 穷尽性真判定

用例从 249 增加到 263。本任务收紧 6 项，另有 1 项软收紧（TM04）。TM03 为强制门。新增套件 16 例。提交为 `e9818d62`。报告在 `docs/archive/sdd/p3-task3-report.md`。

### Task 4 联合与可选

用例从 263 增加到 279。本任务收紧 3 项，放宽 7 项，其中包括 2 端挂死修复。新增套件 12 例。提交为 `c8c7731b`。报告在 `docs/archive/sdd/p3-task4-report.md`。

### Task 5 泛型约束（P3a 半边）

用例从 279 增加到 288。本任务收紧 3 项，放宽 1 项，实例名忠实化 6 项。新增套件 14 例。`T: I` 的另一半在 P3b。提交为 `9c0a83ec`。报告在 `docs/archive/sdd/p3-task5-report.md`。

### Task 6 impl 契约

用例从 319 增加到 333。本任务实现签名四维检查，包括参数、返回、应用实参和接收者模式。形状项逐成员判定。本任务移除 mangling，`str_intern` 为零。本任务修复泛型体内方法调用崩溃，旧返回码为 139，修复后得到正确值。收紧 4 条，放宽 0 条。ELF 和 `.ccr` 逐字节相同。提交为 `e838f18b`。报告在 `docs/archive/sdd/p3b-task6-report.md`。

### Task 7 结束（P3a）

本任务完成全量回归（49/49）、canary、清单汇总和交接包（附录 B）。本任务发现并修复 T5 的 project-mode 清单漏改回归，记录在附录 B.6。提交为结束提交。报告在 `docs/archive/sdd/p3-task7-report.md`。

### Task 7b 结束（P3b）

本任务完成全量回归，包括五个 CI job、46 个 selfhost 档和 7 个 bootstrap 档逐档运行。检查复验包括 canary、corec2 与 corec3、N06 和快速验证。统一清单记录收紧 10 项、放宽 0 项。本任务还完成 P3 总状态和 P4 交接包（附录 C）。结束提交见结束报告第 7 节。报告在 `docs/archive/sdd/p3b-task7-report.md`。

## 验收结果

实施状态总表（2026-09-12，P3b 结束更新）：

| 任务 | 状态 | 提交 | 验收要点 | 报告 |
|---|---|---|---|---|
| Task 0 引擎展开层 | 已完成，已交付 | `61d3a8b4` | 纯新增 502 行，删除 0 行。用例从 212 增加到 229。72 档语料在三个面上的 diff 为空。 | `docs/archive/sdd/p3-task0-report.md` |
| Task 1 定长移除结束 | 已完成，已交付 | `ef61f002` | 用例从 229 增加到 249。收紧 6 项，放宽 0 项。修复「切片到固定长」不报错地放宽。 | `docs/archive/sdd/p3-task1-report.md` |
| Task 0b（P3b）`iface_satisfies` 契约回补 | 已完成，已交付 | `9aa1786c` | 三态契约。分派轴为 A>C>B。实例化点 `T: I` 做真判定。全语料零命中，收紧 6 项，放宽 0 项。ELF 和 `.ccr` 逐字节相同。 | `docs/archive/sdd/p3b-task0-report.md` |
| Task 2 横切接口 | 已完成，已交付（P3b） | `44100ba4` | 用例从 304 增加到 319。六形状项包括 `⊤ₖ` 形和只读与可写分野。索引与切片消费点换位。收紧 0 项，放宽 0 项。行为保持：12 个用例在旧、新两个二进制上相同，全语料零差异。ELF 和 `.ccr` 逐字节相同。 | `docs/archive/sdd/p3b-task2-report.md` |
| Task 3 穷尽性真判定 | 已完成，已交付 | `e9818d62` | 用例从 249 增加到 263。收紧 6 项，另有 1 项软收紧（TM04）。TM03 为强制门。新增套件 16 例。 | `docs/archive/sdd/p3-task3-report.md` |
| Task 4 联合与可选 | 已完成，已交付 | `c8c7731b` | 用例从 263 增加到 279。收紧 3 项，放宽 7 项，其中包括 2 端挂死修复。新增套件 12 例。 | `docs/archive/sdd/p3-task4-report.md` |
| Task 5 泛型约束（P3a 半边） | 已完成，已交付 | `9c0a83ec` | 用例从 279 增加到 288。收紧 3 项，放宽 1 项，实例名忠实化 6 项。新增套件 14 例。`T: I` 的另一半在 P3b。 | `docs/archive/sdd/p3-task5-report.md` |
| Task 6 impl 契约 | 已完成，已交付（P3b） | `e838f18b` | 用例从 319 增加到 333。签名四维包括参数、返回、应用实参和接收者模式。形状项逐成员判定。mangling 移除后 `str_intern` 为零。泛型体内方法调用崩溃修复，旧返回码 139 改为正确值。收紧 4 条，放宽 0 条。ELF 和 `.ccr` 逐字节相同。 | `docs/archive/sdd/p3b-task6-report.md` |
| Task 7 结束（P3a） | 已完成，已交付 | 结束提交 | 全量回归 49/49。canary 通过。清单汇总。交接包为附录 B。发现并修复 T5 的 project-mode 清单漏改回归（附录 B.6）。 | `docs/archive/sdd/p3-task7-report.md` |
| Task 7b 结束（P3b） | 已完成，已交付 | 见结束报告第 7 节 | 全量回归包括五个 CI job、46 个 selfhost 档和 7 个 bootstrap 档逐档运行。检查复验包括 canary、corec2 与 corec3、N06 和快速验证。统一清单记录收紧 10 项、放宽 0 项。本任务完成 P3 总状态和 P4 交接包（附录 C）。 | `docs/archive/sdd/p3b-task7-report.md` |

### 自检记录

spec 覆盖：第 5.1 节定长、序列和长度约束对应 Task 0、Task 1、Task 2。第 5.2 节泛型对应 Task 5。第 5.3 节 impl 对应 Task 6。第 5.4 节穷尽性、联合和可选对应 Task 3、Task 4。第 9 节 P3 行的五项目标能力逐项有对应任务。`TODO.md:446` 的 fixed-array-retire「未办 = 类型身份移除本身」由 Task 1 结束，Task 1 枚举了 5 条读码事实，不是推测。

占位符扫描：无 TBD。两处决策点显式登记，分别是 Task 4 的 `null` 原子表示和 Task 5 的 MAX_GENERICS 解除或登记。记录注明两者都属于「实施前须定」，不属于「稍后填」。

命名一致性：`sh_struct_term`、`sh_enum_domain_term`、`sh_variant_term`、`sh_iface_shape_term`、`ty_variance_of`、`sh_seq_term` 和 `iface_satisfies` 在任务间一致。`iface_satisfies` 是 P2b 交接契约名。

数字约定：95 为实测值，命令是 `grep -c "fails = fails + ts_check("`，结果为 95。26,989 和 67 文件是 findings 第 11 节的实测值。pA 到 pD 四个探针是本计划在 2026-09-11 的实测值。其余「≥N 例」是计划下限，可以增加，不可以减少。

## 遗留问题

记录没有给出两处决策点的最终取值。两处决策点分别是 Task 4 的 `null` 原子表示，以及 Task 5 的 MAX_GENERICS 解除或登记。需要维护者确认最终结论。

计划登记的风险项和缓解措施如下。

1. 展开层裁定涉及 Task 0 的「仅满足判定展开、等价不展开」边界。裁错会导致判定全面变化，并推翻 P2a 基线。缓解措施是影子对拍逐任务归零，加名义不变量用例。
2. pA 类不报错地放宽已经实测在库，形态是切片到数组。本次收紧即修，须走收紧清单加 report-only。
3. 穷尽性硬错误会影响用户返回码。缓解措施是语料零 match 加 report-only 先行。
4. monomorph 实例键变更会使 `.ccr` 和 SYM 随之变化。折叠缺陷修复可能改变既有实例数，须实测报告。
5. P2b 依赖项阻塞涉及 Task 2、Task 6 和 Task 5 的一半。交付方式是分阶段：P3a 先行，P3b 等 P2b。

## 不包含

本次不包含 P4 及之后的实施。P4 的开工材料是附录 C。
