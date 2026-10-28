# ADR-0004: corec/corearch 前后端二进制拆分（.ccr 为接口契约）

- 日期：2026-05-28（拆分，随 .core 更名为 .cr）；2026-08（自举贯通后职责确定，corearch 独立发射）
- 状态：accepted
- 决策者：DslsDZC
- 关联提交：main.cr/corearch.cr 拆分阶段（CLAUDE.md 已记录）

## 背景

2026-05-28 将单编译器拆为前后端（`.core` 更名为 `.cr` 同期）；自举管线进一步要求“前端编译 `.cr` 生成中间产物，后端发射 ELF”这两步可以独立驱动。`corec2` 自身编译时，前端需要反复调用后端；如果前后端在同一个二进制里，就无法单独验证后端对同一 `.ccr` 的发射一致性，也无法分开调试，前端死循环和后端 SIGFPE 会互相掩盖。

## 决策

- 拆为两个二进制：`corec`（前端：lex、parse、check、ir、ccr 写出）和 `corearch`（后端：`.ccr` 读入、ELF 发射）。`corearch` 也可以单独运行 `--elf --static`。
- `.ccr` 文件是前后端接口契约：v5 为线性指令/变量段，后演进为 v6 段表（见 ADR-0002）。
- `corec` 的 `build` 子命令内部自动调用 `corearch`；用户也可以手工分步执行，例如逐字节对比发射结果。

## 后果

- 正面：三阶段自举可以逐字节验证（`corec`、`corec2`、`corec3` 发射一致）；后端可以独立回归（O0/O1/O2 CCR 与原生 ELF 运行验证）；`.ccr` 成为稳定的格式边界和 dump 实现方式。
- 负面：两个二进制带来分发复杂度（两份 CLI 入口）；`.ccr` 格式稳定性成为硬约束，格式一变，前后端必须同步，形成版本耦合。

## 关联

- 文档：docs/project-book.md（系统结构）；CLAUDE.md（Build & Test 命令）
- 相关 ADR：ADR-0002（.ccr v6 段表）、ADR-0003（ELF 直出）
