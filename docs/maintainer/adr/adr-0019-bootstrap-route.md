# ADR-0019: 项目启动与自举路线——Python bootstrap 先行 + 自托管目标

- 日期:2026-04-24(init)~ 2026-05-19(自编译测试)/ 2026-07-26(corec2→corec10 贯通)
- 状态:accepted(已实现:三级自举管线)
- 决策者:DslsDZC

## 背景
全新语言无编译器可用。早期提交(2026-04-24 init)同时出现:语言核心(lexer/parser/checker)、编辑器支持与后端起步。关键路线问题:用什么写第一个编译器、目标产物怎么验证。

## 决策
- **Python bootstrap 先行**(bootstrap/corec/):纯 Python 单遍管线,无外部依赖——作为 stage 0 构建自托管编译器
- **自托管为目标**:编译器用 Core 自身编写(src/compiler/),Python bootstrap 编译它出原生二进制
- 三级自举:stage 0(Python)→ stage 1(corec)→ stage 2(corec2);2026-07-26 corec2→corec10 全线贯通
- 扩展名 .core → .cr(2026-05-28,与前后端拆分同期)

## 后果
- 正面:自举闭环(语言写自己 = 最强验证);Python bootstrap 简单可审计
- 负面:Python/自托管双实现需保持一致(bootstrap 解释器截断方向等 bug 曾致发散——ir-op-semantics BC2);bootstrap 后期只作构建工具保留

## 关联
- 文档:CLAUDE.md(构建与自举);docs/maintainer/onboarding.md
- 相关 ADR:ADR-0003(ELF 直出)、ADR-0004(前后端拆分)
