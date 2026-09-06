# Core 文档中心

> 定位:受众 = 所有读者(入口);状态 = active。
> 分类规则:一级 = **受众**(developer/maintainer/academic),二级 = 主题;每份文档头部有定位声明(受众/状态/真源)。
> 一份文档一个职责;实现与文档冲突时以源码为准(既有惯例),设计意图与实现差距以"设计态"标注(设计文档优先于代码)。

## 开发者(developer/)——用 Core 写程序

- [quickstart.md](developer/quickstart.md)— 快速开始(构建/第一个程序)
- [tutorial.md](developer/tutorial.md)— 渐进学习路径
- [concepts.md](developer/concepts.md)— 核心概念导览(图/内存/部署/规约,分篇见 concepts/)
- [syntax.md](developer/syntax.md)— 语言语法参考
- [examples.md](developer/examples.md)— 示例集
- [faq.md](developer/faq.md)— 常见问题
- [errors.md](developer/errors.md)— 错误码参考
- [editors.md](developer/editors.md)— 编辑器与 LSP 配置
- [at-intrinsics.md](developer/at-intrinsics.md)— @ 内建原语

## 维护者(maintainer/)——改编译器

**上手**:[onboarding.md](maintainer/onboarding.md)(先读)→ [testing.md](maintainer/testing.md)(回归操作)

**设计参考**(maintainer/design/):
- 执行模型 / 图与 region:[execution-model.md](maintainer/design/execution-model.md)、[dataflow-design.md](maintainer/design/dataflow-design.md)(早期稿,已被取代,留档)
- 存储语义:[memory-model.md](maintainer/design/memory-model.md)(总览)、[cache-semantics.md](academic/cache-semantics.md)(七条权威,跨 academic)、[existence-structure.md](maintainer/design/existence-structure.md)(v6 承载)、[region-model.md](maintainer/design/region-model.md)(经典映射)
- 指针与验证 pass:[pointer-model.md](maintainer/design/pointer-model.md)、[regalloc-cache-mapping.md](maintainer/design/regalloc-cache-mapping.md)
- 规约系统:[spec-design.md](maintainer/design/spec-design.md);IR 操作语义:[ir-op-semantics.md](maintainer/design/ir-op-semantics.md);corelsp:[corelsp.md](maintainer/design/corelsp.md);已废弃:[crasm.md](maintainer/design/crasm.md)

**决策记录**:[adr/](maintainer/adr/README.md)— ADR-0001 起

**特性提案**(maintainer/proposals/):generics/concurrency/dynamic-typing/comptime/ffi/lazy/distributed/probabilistic(状态见各文件头注)

## 学术(academic/)——验证/理论读者

- [cache-semantics.md](academic/cache-semantics.md)— 缓存语义七条(存储语义本体,权威)
- [lattice-theory.md](academic/lattice-theory.md)— 三层映射理论定稿(图 → 格 → 编码)
- [verifier-kernel.md](academic/verifier-kernel.md)— 验证内核选型(CIC 信任根)

## 顶层

- [project-book.md](project-book.md)— 项目定位导航
- [glossary.md](glossary.md)— 架构术语表(跨受众)
- [z-vision.md](z-vision.md)— 愿景

## 档案与工具链目录(不参与受众分类)

archive/(任务产物)、pseudocode/(TDD 交付物)、superpowers/(specs + plans 工作目录)、coq/、ir-schema/、verifier/
