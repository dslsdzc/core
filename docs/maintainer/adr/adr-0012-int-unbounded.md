# ADR-0012: int 无上限语义——数学整数 + 编码层快路径投影

- 日期:2026-08-23(语义修订)~ 2026-09-06(语言层定稿 + 错误码归位)
- 状态:accepted
- 决策者:DslsDZC

## 背景
int 若为 64 位机器整数,规约验证在无界域证明的结论与实际运行(溢出回绕)可能不一致(int-unbounded 问题);同时性能需要 64 位快路径。

## 决策
- **语义层:int = 无上限数学整数**(公理化接口,无溢出概念——溢出非语义事件)
- **编码层:64 位机器字 = 快路径投影**;超界 = 编码层事务(静态区间证明免检;推导不出才检查提升;表示策略归 hw-map 远期,后端策略 B:64 快路径 + 溢出扩展 2-limb)
- 溢出类错误(lexer 字面量守卫/CCR i32 字段校验)= 编码层限制错误,重新归位
- int 公理可被 .cr 规约对照验证(CompCert 精神推广到原语层);与 dex 精确两线不混(int = 语义无上限、dex = 表示层工程)

## 后果
- 正面:验证结论与运行语义一致(#ensure(x + y > x) 无条件成立);快路径性能保留
- 负面:多字表示/溢出升级实现推进中(M1/M2,见 plans/2026-09-06-int-multiword-m1);IR 契约表以编码层为基准需持续注记(ir-op-semantics)

## 关联
- 文档:docs/maintainer/design/ir-op-semantics.md §1/D1;specs(int-unbounded-semantics、plans/int-multiword-m1)
- 相关 ADR:ADR-0010(dex/apx)
