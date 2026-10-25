# Core 文档

> 定位：受众 = 所有读者；状态 = active。
> 分类规则：一级是受众（developer、maintainer、academic），二级是主题。每份文档开头有定位声明，写明受众、状态和出处。
> 每份文档只覆盖一个主题。
> 优先级规则：设计定稿和计划优先于代码。实现与设计不一致时，文档保持定稿，并标注“设计态”或“按计划推进”。计划未覆盖的实现细节（记号、关键字等）以源码为准。
> 更新规则：语言或实现变化时，更新相关文档的状态和正文，例如把 active 改为 superseded，把设计态改为已实现。开发者文档随语言变化更新。

## 开发者（developer/）：用 Core 写程序

- [quickstart.md](developer/quickstart.md)：快速开始（构建、第一个程序）
- [tutorial.md](developer/tutorial.md)：渐进学习顺序
- [concepts.md](developer/concepts.md)：核心概念（分篇：[graph](developer/concepts/graph.md)、[memory](developer/concepts/memory.md)、[deploy](developer/concepts/deploy.md)、[spec](developer/concepts/spec.md)）
- [syntax.md](developer/syntax.md)：语言语法参考
- [examples.md](developer/examples.md)：示例集
- [faq.md](developer/faq.md)：常见问题
- [errors.md](developer/errors.md)：错误码参考
- [editors.md](developer/editors.md)：编辑器与 LSP 配置
- [at-intrinsics.md](developer/at-intrinsics.md)：@ 内建原语

## 维护者（maintainer/）：编译器开发

开始：[onboarding.md](maintainer/onboarding.md)（建议首先阅读），[testing.md](maintainer/testing.md)（回归操作）

设计参考（maintainer/design/）：

- 前端语义与类型基线：[frontend-semantics.md](maintainer/design/frontend-semantics.md)
- 执行模型与图、region：[execution-model.md](maintainer/design/execution-model.md)、[dataflow-design.md](maintainer/design/dataflow-design.md)（早期稿，已被取代，仅作历史参考）
- 存储语义：[materialization-space.md](maintainer/design/materialization-space.md)（层定义是存在格，Materialization Space）、[memory-model.md](maintainer/design/memory-model.md)（总览）、[cache-semantics.md](academic/cache-semantics.md)（规则 1 到 7 以该文为准。缓存映射是该层的一类实例）、[existence-structure.md](maintainer/design/existence-structure.md)（v6 表示）、[region-model.md](maintainer/design/region-model.md)（经典映射）
- 指针与验证 pass：[pointer-model.md](maintainer/design/pointer-model.md)、[regalloc-cache-mapping.md](maintainer/design/regalloc-cache-mapping.md)
- 规约系统：[spec-design.md](maintainer/design/spec-design.md)。IR 操作语义：[ir-op-semantics.md](maintainer/design/ir-op-semantics.md)。corelsp：[corelsp.md](maintainer/design/corelsp.md)。已废弃：[crasm.md](maintainer/design/crasm.md)。

决策记录：[adr/](maintainer/adr/README.md)，ADR-0001 起

特性提案（maintainer/proposals/）：generics、concurrency、dynamic-typing、comptime、ffi、lazy、distributed、probabilistic（状态见各文件开头的注释）

## 学术（academic/）：验证和理论读者

- [cache-semantics.md](academic/cache-semantics.md)：规则 1 到 7（以该文为准）。缓存映射是该层的一类实例。层本体是存在格，见 [maintainer/design/materialization-space.md](maintainer/design/materialization-space.md)。
- [lattice-theory.md](academic/lattice-theory.md)：三层映射理论定稿（图、格、编码）
- [verifier-kernel.md](academic/verifier-kernel.md)：验证内核选型历史。CIC 已废止，McTT 是当前信任根。

## 顶层

- [project-book.md](project-book.md)：项目定位与文档索引
- [glossary.md](glossary.md)：架构术语表（跨受众）
- [doc-style.md](doc-style.md)：文档写作规范
- [z-vision.md](z-vision.md)：愿景

## 档案与工具链目录（不属于受众分类）

- archive/（任务产物）：[compcert-reference.md](archive/compcert-reference.md)、[compcert-round4-findings.md](archive/compcert-round4-findings.md)、[numeric-migration-inventory.md](archive/numeric-migration-inventory.md)、[memory-model-capability-lattice.md](archive/memory-model-capability-lattice.md)
- [superpowers/](superpowers/)（specs、plans 和 implementation 工作目录。2026-09-16 新增：[compile-time-theorems](superpowers/specs/2026-09-16-compile-time-theorems.md)、[verification-slice](superpowers/plans/2026-09-16-verification-slice.md)、[preexisting-bug-ledger](superpowers/implementation/2026-09-16-preexisting-bug-ledger.md)）
- [implementation/](superpowers/implementation/README.md)：计划的实施记录
- 10K 以上 Markdown 清单与处理分类：[implementation/2026-10-23-md-over-10k-inventory.md](superpowers/implementation/2026-10-23-md-over-10k-inventory.md)
- 文档与实现的核对（2026-09-16）：[implementation/2026-09-16-doc-reality-audit.md](superpowers/implementation/2026-09-16-doc-reality-audit.md)，列出与实现不符的文档断言（35 条：危险 7、陈旧 6、成立 20、无法判定 2），并给出逐条修订去向。修改文档或按文档设计前，先查这张表。
- [ir-schema/](ir-schema/)：[coreir-schema.md](ir-schema/coreir-schema.md)、[corespecir-schema.md](ir-schema/corespecir-schema.md)
- [verifier/](verifier/)：[kernel-spec.md](verifier/kernel-spec.md)；[coq/](coq/README.md)：Coq 验证 stdlib 纯函数
