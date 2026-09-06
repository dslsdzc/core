# ADR-0009: 规约系统 v2——CIC 内核 + SMT 证书架构

- 日期:2026-08-11(v2 定稿)
- 状态:accepted(设计定稿,未实现)
- 决策者:DslsDZC

## 背景
规约系统早期形态未定验证后端与表达力上限。需要:规约表达力、验证健全性、平民化三者的平衡。

## 决策
- 规约语言编译为 **CIC 项**(归纳构造演算):量词/归纳/高阶全在内核,表达力无上限
- **SMT 证书外包**:目标一阶化 → SMT 求解 → 证书 → 翻译成 CIC 证明项 → 内核重验——健全性唯一来源是 CIC 内核(SMTCoq 模式);SMT 只当搜索器
- 平民化分层:编译器自动推导 → #check/#ensure → spec fn(Core 写的纯检查函数)→ 用户入口分层(#induct/#lemma/证明项逃逸)
- 语法形态 2026-09 定稿:#check/#ensure 标注,.cr 内联(见 ADR-0001 退役同步)

## 后果
- 正面:表达力与健全性解耦(内核最小信任根);证明驱动优化(已证性质门控喂优化器)
- 负面:全链未实现(解析/翻译桥/SMT 通道/内核绑定);CIC 内核选择挂起(Rocq vs Lean 4,等社区)

## 关联
- 文档:docs/maintainer/design/spec-design.md、docs/academic/verifier-kernel.md(选型论证)
- 相关 ADR:ADR-0001(规约格式退役)
