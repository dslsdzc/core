# Core 文档中心

> 定位：受众 = 用户与维护者；状态 = active；真源 = 各文档头部定位声明（实现与文档冲突时以源码为准）。
> 分类规则：按「主题 × 读者 × 状态」组织；每份文档头部有定位声明（受众/状态/真源）。
> 一份文档一个职责；本文件是唯一导航索引，与目录树一致。

## 入口
- [愿景 z-vision](z-vision.md)— 项目愿景入口（顶层保留）

## 用户向（language/）
- [语言语法](language/syntax.md)— 词法/类型/声明/表达式/规约；真源 = grammar/core.ebnf + src/compiler/
- [学习路径](language/learning-path.md)
- [错误码参考](language/error-codes.md)
- [编辑器与 LSP 配置](language/editor-setup.md)

## 定稿参考（design/）— 维护者向
- [项目书](design/project-book.md)— 项目定位
- [执行模型](design/execution-model.md)— v2 执行模型（region 嵌套 + state edges）；[dataflow-design.md](design/dataflow-design.md) 已被其取代，留档
- [存储语义总览](design/memory-model.md)→ [缓存语义七条](design/cache-semantics.md)/[存在结构 v6](design/existence-structure.md)/[图锚定区域](design/region-model.md);[指针模型](design/pointer-model.md)、[寄存器分配缓存映射](design/regalloc-cache-mapping.md)
- [IR 操作语义](design/ir-op-semantics.md)、[术语表](design/glossary.md)
- [规约系统设计](design/spec-design.md)、[验证内核](design/verifier-kernel.md)、[@ 内建原语](design/at-intrinsics.md)
- [corelsp 设计](design/corelsp.md)— 语言服务器架构（检查管线/诊断通道/能力契约；用户接入见上 editor-setup 条）

## 特性提案（proposals/）
[generics](proposals/generics.md) / [comptime](proposals/comptime.md) / [ffi](proposals/ffi.md) / [concurrency](proposals/concurrency.md) / [dynamic-typing](proposals/dynamic-typing.md) / [lazy](proposals/lazy.md) / [distributed](proposals/distributed.md) / [probabilistic](proposals/probabilistic.md)（状态见各文件头注）

## 任务产物归档（archive/）
compcert 对照审查材料与修复记录（[reference](archive/compcert-reference.md)、[round4-findings](archive/compcert-round4-findings.md)）、[数值类型迁移盘点](archive/numeric-migration-inventory.md)、[内存模型能力格讨论备忘](archive/memory-model-capability-lattice.md)

## 维护者手册（maintainer/）
- [onboarding.md](maintainer/onboarding.md)— 新维护者入门（仓库地图/构建/分支/jj/雷区）
- [testing.md](maintainer/testing.md)— 测试与回归操作手册（三套定位/加用例/自举回归/失败定位）

## 决策记录（adr/）
[adr/](adr/) — ADR-0001 起，编号递增（Task 6 产出 ADR-0001~0004）

## 工具链目录（不动）
pseudocode/（TDD 交付物）、superpowers/（specs + plans）、coq/、ir-schema/、verifier/
