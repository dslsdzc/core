# ADR-0014: 惰性求值——编译期下沉路线

- 日期:2026-08-09
- 状态:accepted(方向定案;实现设计态)
- 决策者:DslsDZC

## 背景
图模型天然可表达惰性(节点不在边上游等待时不执行),但 IR 生成策略是 eager。惰性求值若做成运行时机制将引入新执行语义。

## 决策
- **惰性控制流 = 编译期下沉**:if 分支/循环体内的条件性使用经图分析延迟执行(编译期变换),非运行时 thunk 语义
- IR 保留显式 thunk 形态(IR_LAZY_THUNK/FORCE)作为迁移载体,当前 eager 近似

## 后果
- 正面:执行模型不新增惰性运行时语义;图分析统一处理
- 负面:控制流级惰性未实现(自动升级 eager 在实现中体现为使用点 force)

## 关联
- 文档:docs/maintainer/proposals/lazy.md;docs/maintainer/design/ir-op-semantics.md §2.7
