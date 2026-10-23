# ADR-0014: 惰性求值：编译期变换路线

- 日期：2026-08-09
- 状态：accepted（方向定案；实现处于设计态）
- 决策者：DslsDZC

## 背景

图模型本身可以表达惰性：节点不在边上游等待时就不执行。但 IR 生成策略是 `eager`。如果惰性求值做成运行时机制，会引入新的执行语义。

## 决策

- 惰性控制流在编译期变换：`if` 分支和循环体内的条件性使用经图分析延迟执行，不是运行时 `thunk` 语义。
- IR 保留显式的 `thunk` 形态（`IR_LAZY_THUNK`/`FORCE`）作为迁移实现方式，当前用 `eager` 近似。

## 后果

- 正面：执行模型不新增惰性运行时语义；由图分析统一处理。
- 负面：控制流级惰性未实现（自动升级 `eager` 在实现中体现为使用点 `force`）。

## 关联

- 文档：docs/maintainer/proposals/lazy.md；docs/maintainer/design/ir-op-semantics.md 第 2.7 节
