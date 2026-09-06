# 决策记录(ADR)

> 定位:受众 = maintainers;状态 = active;真源 = 各 ADR 正文(与 git 历史一致时以历史为准)。
> 规则:每份 ADR 记录一个已做决策的"为什么";设计细节不重复,见正文"关联"指向的文档。

## 编号规则

- 从 0001 起递增;新决策落地时追加,不修改已 accepted 的历史记录
- 状态:accepted(已采纳)/ superseded by ADR-000N(被取代)——被取代的保留原文,新决策另起新号
- 模板:

```markdown
# ADR-000N: 标题

- 日期:YYYY-MM-DD
- 状态:accepted
- 决策者:

## 背景
## 决策
## 后果(正面/负面)
## 关联
```

## 索引

| 编号 | 标题 | 状态 | 日期 |
|---|---|---|---|
| ADR-0001 | .corespec/.crasm 独立格式退役——规约并入 .cr 语法 | accepted | 2026-09-05/06 |
| ADR-0002 | .ccr v6 段表架构 + ENT 存在结构段 + REG 坐标化 | accepted | 2026-09-05 |
| ADR-0003 | 自举后端 x86-64 ELF 直出 | accepted | 2026-08 |
| ADR-0004 | corec/corearch 前后端拆分(.ccr 为接口契约) | accepted | 2026-05-28(8 月自举定格) |
| ADR-0005 | 内存模型分层定稿(图 → 格 → 编码)+ 能力定位 v4 | accepted | 2026-08-26/27 |
| ADR-0006 | 缓存语义 = 存储语义本体(2026-08-15 纠偏) | accepted | 2026-08-15 |
| ADR-0007 | 图锚定区域内存模型 + 逃逸 outlives 修订 | accepted | 2026-08-13 |
| ADR-0008 | 执行模型 region 化(RVSDG 嵌套 + state edges) | accepted | 2026-08-08 |
| ADR-0009 | 规约系统 v2(CIC 内核 + SMT 证书架构) | accepted | 2026-08-11 |
| ADR-0010 | 数值类型 dex/apx——精确/授权二分 | accepted | 2026-08-16 |
| ADR-0011 | 平台桥抽象(I/O 流/随机/哈希/时钟) | accepted | 2026-08-16 |
| ADR-0012 | int 无上限语义(数学整数 + 编码层投影) | accepted | 2026-08-23~09-06 |
| ADR-0013 | 类型系统方向 14 条(自动推导/借用收缩/声明式边界) | accepted | 2026-08-30 |
| ADR-0014 | 惰性求值——编译期下沉路线 | accepted | 2026-08-09 |
| ADR-0015 | HIT 硬件接口表(取代 .crasm 汇编层) | accepted | 2026-09-05 |
| ADR-0016 | 多 Arena 内存模型(取代全局 bump) | accepted | 2026-07-28 |
| ADR-0017 | 并发模型 = Go 风格 GMP 简化 | accepted | 2026-07-30/31 |
| ADR-0018 | 仓库治理——GitFlow + 双 ruleset + CI | accepted | 2026-08-09 |
| ADR-0019 | 项目启动与自举路线(Python bootstrap + 自托管) | accepted | 2026-04~07 |
| ADR-0020 | IR 双形态确立(.cir 图 / .ccr 格) | accepted | 2026-05-28 |
