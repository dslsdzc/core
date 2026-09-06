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
| ADR-0004 | corec/corearch 前后端拆分(.ccr 为接口契约) | accepted | 2026-08 |
