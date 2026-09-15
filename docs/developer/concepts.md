# 核心概念导览

> 定位:受众 = 开发者(理解 Core 的设计思维);状态 = active。
> 四篇分篇各讲一个概念(每篇末有深入链接);本文是入口与一句话总览。

## 四个概念

| 概念 | 一句话 | 分篇 |
|---|---|---|
| 程序 = 一张图 | 代码编译为数据流图,图保留全部语义——不需要"模式"概念 | [concepts/graph.md](concepts/graph.md) |
| 内存自动管理 | 子图区域 + 编译器自动验证——无 borrow checker、无 GC、无标注 | [concepts/memory.md](concepts/memory.md) |
| 部署与代码分离 | 物理世界(内存策略/OS/时间源)进部署配置,不进代码 | [concepts/deploy.md](concepts/deploy.md) |
| 规约内联验证 | #check/#ensure 写在函数上,验证不用学第二门语言 | [concepts/spec.md](concepts/spec.md) |

## 为什么这些概念成立:语义保鲜

编译中间表示(IR)保留全部类型与语义信息,不逐级降格为机器指令——验证器消费 IR 即获得完整语义模型。这是 Core 支持形式化验证、跨平台行为一致、范式可迁移(经典/量子/…)的共同基础。

## 阅读建议

- 第一次接触:先 [tutorial.md](tutorial.md) 上手,概念随阶段展开
- 想理解设计:读四个分篇
- 语法细节:[syntax.md](syntax.md)
- 术语表:`../glossary.md`(一般不需要查——本文只用开发者术语)
