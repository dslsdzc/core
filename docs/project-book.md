# Core 项目书

> 定位:受众 = 用户与维护者;状态 = active;真源 = 本文件 + 下方链接的各设计文档(实现与文档冲突时以源码为准)。
> 本文档是项目定位的导航性文档——细节不重复,指向对应设计文档;愿景见 `z-vision.md`。

## 一、项目概述

Core 是一门全新、完全自主设计的编程语言与编译工具链,围绕「语义保鲜」理念构建:
编译器核心是一个**保留全部类型与语义信息的中间表示(IR)**——不将高级结构降格为低级指令,
而是把隐式行为、语法糖、类型推导、符号解析全部摊平、归一化、显式化,形成一份「语义源代码」。

在此之上,Core 原生支持完全形式化验证:验证器消费 IR 即可获得完整语义模型与证明义务,
无需自行重建语义(验证机制见 [spec-design.md](maintainer/design/spec-design.md))。

Core 的目标是证明:一门现代语言可以同时获得快速编译、轻松跨平台、完全形式化验证,
并且在设计上不互相妥协。

## 二、背景与问题

传统生态的四重割裂(详见 `docs/developer/tutorial.md` 的设计动机叙述):

1. **编译时间膨胀**——大型项目反复重做语义解析(头文件/泛型实例化/重载决议)
2. **跨平台代价**——运行时虚拟机臃肿;静态交叉编译仍需每平台全套前端
3. **验证与实现脱节**——实现与规约不同语言/工具/文件,验证器各自重建语义模型
4. **执行模型人为割裂**——调试/发布/实时/教学各一套心智模型,切换引入行为差异

共同根源:缺少同时承载实现语义与形式规约的中间层,以及不需要模式概念的通用执行模型。

## 三、核心思想

| 原则 | 一句话 | 细节 |
|---|---|---|
| 语义保鲜 | 语义信息在 IR 中全量保留,不逐级丢弃 | [execution-model.md](maintainer/design/execution-model.md) |
| 单一执行模型 | 全部代码 = HDFG(全息数据流图),执行方式由部署配置决定 | [execution-model.md](maintainer/design/execution-model.md)、[dataflow-design.md](maintainer/design/dataflow-design.md)(早期稿,已被前者取代) |
| 规约即语法 | 规约 = .cr 语法内的约束表达(2026-09 起 .corespec 独立格式退役,见 [adr/../maintainer/adr/adr-0001-corespec-crasm-retired.md](maintainer/adr/adr-0001-corespec-crasm-retired.md)) | [spec-design.md](maintainer/design/spec-design.md) |
| 三层映射 | 语义 → 图 → 格 → 编码;图表达计算,格承载计算,编码实现计算 | [memory-model.md](maintainer/design/memory-model.md)、[regalloc-cache-mapping.md](maintainer/design/regalloc-cache-mapping.md) |

## 四、系统骨架

```
.cr 源码 ──► 前端(corec)──► 语义 IR(.cir 图形态 / .ccr 格形态 v6 段表)
                 │              │
          语法/类型/借用检查     ├──► 后端(corearch)──► 目标机器码(x86-64 ELF 直出,见 adr-0003)
          名字解析/声明收集       │
                                └──► 形式化验证工具(消费 IR + 规约,独立组件)
```

- 前端/后端拆分为两个二进制,`.ccr` 为接口契约 —— [maintainer/adr/adr-0004-corec-corearch-split.md](maintainer/adr/adr-0004-corec-corearch-split.md)
- 模块级地图(每个 .cr 文件职责)见 `docs/maintainer/onboarding.md`
- 实现层 IR 形态演进:图形态 CIR / 格形态 CCR v6 段表 + ENT —— lattice-ir-v6 格式 spec(docs/superpowers/specs/2026-09-05-lattice-ir-v6-format.md;develop 合入前为前向链接)

## 五、状态速览

| 维度 | 状态 | 详见 |
|---|---|---|
| 自举 | Stage 0/1/2 三级管线可运行(2026-07 贯通,三阶段字节一致) | `docs/maintainer/onboarding.md` |
| 阻塞项 | corec2 tokenizer 死循环(9 全局变量未注册)等 | `TODO.md` |
| 当前工作区 | 见各 feature 分支与 TODO.md 挂账 | `TODO.md`、`docs/README.md` |

## 六、总结

Core 要回答的问题:若语言设计之初就把语法检查、语义 IR 与规约纳入统一框架——
实现层 IR 承载语义、规约承载行为约束、两者经符号精确关联——编译速度、跨平台与
形式化验证的门槛能降到什么程度?项目将用实际可运行的代码回答。
