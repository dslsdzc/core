# ADR-0019: 项目启动与自举路线：Python bootstrap 先行 + 自托管目标

- 日期：2026-04-24（init）~ 2026-05-19（自编译测试）/ 2026-07-26（corec2 到 corec10 贯通）
- 状态：accepted（已实现：三级自举管线）
- 决策者：DslsDZC

## 背景

全新语言没有编译器可用。早期提交（2026-04-24 init）同时出现语言核心（`lexer`/`parser`/`checker`）、编辑器支持和后端起步。关键路线问题是：第一个编译器用什么语言实现，目标产物如何验证。

## 决策

- Python bootstrap 先行（`bootstrap/corec/`）：纯 Python 单遍管线，无外部依赖，作为 stage 0 构建自托管编译器。
- 自托管是目标：编译器用 Core 自身编写（`src/compiler/`），由 Python bootstrap 编译出原生二进制。
- 三级自举：stage 0（Python）、stage 1（`corec`）、stage 2（`corec2`）；2026-07-26 `corec2` 到 `corec10` 全线贯通。
- 扩展名从 `.core` 改为 `.cr`（2026-05-28，与前后端拆分同期）。

## 后果

- 正面：自举完整流程，语言编译自身是最强的验证；Python bootstrap 简单，可以审计。
- 负面：Python 和自托管两套实现需要保持一致（bootstrap 解释器的截断方向等缺陷曾导致结果发散，见 `ir-op-semantics` BC2）；bootstrap 后期只作为构建工具保留。

## 关联

- 文档：CLAUDE.md（构建与自举）；docs/maintainer/onboarding.md
- 相关 ADR：ADR-0003（ELF 直出）、ADR-0004（前后端拆分）
