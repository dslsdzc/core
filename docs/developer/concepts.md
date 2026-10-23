# 核心概念导览

> 定位：受众 = 开发者（理解 Core 的设计思维）；状态 = active。
> 四篇分篇各讲一个概念（每篇末有深入链接）；本文是导览和一句话总览。

## 四个概念

| 概念 | 一句话 | 分篇 |
|---|---|---|
| 程序 = 一张图 | 代码编译为数据流图，图保留全部语义，不需要“模式”概念 | [concepts/graph.md](concepts/graph.md) |
| 内存自动管理 | 子图区域加编译器自动验证，不需要 borrow checker、GC 或标注 | [concepts/memory.md](concepts/memory.md) |
| 部署与代码分离 | 内存策略、操作系统、时间源等部署目标信息写入部署配置，不写入代码 | [concepts/deploy.md](concepts/deploy.md) |
| 规约内联验证 | #check/#ensure 写在函数上，验证不需要另学一门语言 | [concepts/spec.md](concepts/spec.md) |

## 共同基础：语义保留

语义保留指编译中间表示（IR）保留全部类型和语义信息，不逐级降格为机器指令。验证器使用 IR 就能得到完整的语义模型。这是 Core 支持形式化验证、跨平台行为一致和范式可迁移（经典、量子等）的共同基础。

## 阅读建议

- 初次接触：先读 [tutorial.md](tutorial.md)，概念在教程各阶段中展开
- 设计理解：读四个分篇
- 语法细节：[syntax.md](syntax.md)
- 术语表：`../glossary.md`（一般不需要查，本文只使用开发者术语）
