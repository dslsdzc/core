# ADR-0001: .corespec/.crasm 独立格式退役，规约并入 .cr 语法

- 日期：2026-09-05/06
- 状态：accepted
- 决策者：DslsDZC
- 关联提交：`582a1e1`（refactor: .corespec 退役）；crasm 废弃标注（2026-09-05）

## 背景

仓库一度存在两套独立格式：`.corespec`（规约/契约文件）和 `.crasm`（统一汇编抽象层）。两者的思路相同：为特定职责发明独立文件格式与语法。代价是格式越多，真源越分散（`lexer`/`parser`/`ebnf`/后端各要维护一套），而且独立格式绑定经典硬件过深（寄存器/寻址/ISA 助记符/私有平台映射表）。

## 决策

- `.corespec` 退役（2026-09-06，提交 `582a1e1`）：取消独立规约格式，规约只用 `.cr` 语法表达。
- `.crasm` 废弃（2026-09-05）：取消独立汇编格式，相关能力由硬件接口表（HIT）承担。跨平台使用 HIT 事件加投影表；MMIO/特权/中断使用 `.cr` unsafe 加 HIT extern 接口事件。
- 语法责任并入 `grammar/core.ebnf`；`.corespec` 文件标注退役，`CLAUDE.md` 同步修改。

## 后果

- 正面：真源收敛，语言语法只有一个表达（`.cr`）；维护范围缩小，不再有私有格式路径。
- 负面：`core.ebnf` 和 `CLAUDE.md` 需要登记并清理残留的 `.corespec` 引用；`spec/` 目录残留 7 行占位文件，待清理；既有 `.corespec` 资产（`regalloc-consistency` 已迁移为 `.cr` 注释契约）需要按新形态改写。

## 关联

- 文档：docs/maintainer/design/crasm.md（废弃结束）；grammar/core.ebnf
- 后续：spec/ 目录的 .corespec 占位清理（已登记）
