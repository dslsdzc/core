# SDD 执行日志处理记录

## 范围

`docs/archive/sdd/` 是 SDD 工具的暂存目录，不在版本控制内。处理前有 305 个 Markdown 文件和 136 个 review diff 文件，共约 14MB。

文件构成：

| 类别 | 数量 |
|---|---:|
| 任务报告 `*-report.md` | 216 |
| 任务说明 `*-brief.md` | 65 |
| 评审记录 | 5 |
| 决策表 | 1 |
| 进度汇总 | 1 |
| 其他 | 17 |

## 已处理

1. 删除 136 个 review diff 文件。它们是审查时的补丁快照，内容已由 jj 历史和报告覆盖，共约 8.4MB。
2. 对 216 份任务报告做状态核对。116 份在开头明确写完成或全部通过；`cag-report.md` 和 `int-unbounded-report.md` 的“挂账”是报告内章节，任务本身已完成。其余报告没有统一状态行，但对应任务已由后续阶段或 TODO 记录覆盖。
3. 保留四份有独立价值的记录，移到实施记录目录：
   - `2026-09-11-sdd-decisions-sheet.md`
   - `2026-09-11-sdd-safety-review-a.md`
   - `2026-09-11-sdd-safety-review-b.md`
   - `2026-09-11-sdd-progress.md`
4. 被当前文档引用的 108 个文件移到 `docs/archive/sdd/`，保留链接可达。
5. 其余报告、任务说明、评审和临时文件在核对后删除。

## 未关闭事项的归属

SDD 里出现的未实现或挂账项，已经集中在 `TODO.md` 的“预存 Bug”和“待实现特性”两节。主要家族：

- 多 M 并发验证。
- 解释器局限：`for` 循环、跨函数调用、泛型实例化。
- 标准库补全：`math.cr`、`collections.cr`、字符串 API。
- 自举编译器巨型函数尾代码生成缺陷。
- `extern` 超过 6 个整数参数的语义缺口。
- `elf.cr` 三处手写 syscall 序列迁到 OS 轴。
- 类型别名只解析一层。
- `lexer` 诊断前缀和重复打印。
- 控制流自动惰性的 `use_count` 时序。
- HIT M2 全表驱动。
- 性能自动化家族。

这些条目以 `TODO.md` 为准，SDD 不再是第二份清单。

## 已关闭的 SDD 派生项

- `2026-09-10-2` 双入口旗标分歧：两入口共用 `register_backend_flags()`，project-mode 入口显式拒绝表模式和调试通道。
- `2026-09-10-3` 未使用的 `src/compiler/elf.cr`：已删除，`module.cr` 注释同步。

## 当前状态

`.superpowers/sdd/` 已删除。四份有独立价值的记录在 `docs/superpowers/implementation/`；被文档引用的 108 份报告在 `docs/archive/sdd/`；其余 197 份原始日志和 136 份 diff 已删除。文档引用已从 `.superpowers/sdd/` 更新到新位置。
