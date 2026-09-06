# ADR-0020: IR 双形态确立——.cir(图形态)+ .ccr(格形态)

- 日期:2026-05-28(.cir/.ccr 格式与 spec 文档)
- 状态:accepted(演进中:.cir 图形态保持,.ccr 历 v2-v6 段表升级——ADR-0002)
- 决策者:DslsDZC

## 背景
自托管编译器需要中间产物格式承载"语义保鲜":单一 IR 要么偏图(验证友好)要么偏线性(后端友好)。早期(2026-05-28)确立双产物:数据流图描述(.cir)与二进制格式(.ccr)。

## 决策
- **.cir** = 数据流图格式描述(图形态——验证/分析消费)
- **.ccr** = 二进制格式(格形态线性投影——后端消费;早期版本含变量/指令段)
- corec 产出两者,corearch 消费 .ccr(前后端以 .ccr 为契约——ADR-0004)
- v6(2026-09)将 .ccr 升级为存在结构主体(段表 + ENT/NOD/REG),.cir 语义为图坐标真源

## 后果
- 正面:验证面(.cir)与执行面(.ccr)分离;格式演进有 spec 文档与 schema(ir-schema/)
- 负面:双格式同步成本(.cir/.ccr 表述需一致);v5→v6 不兼容(中间产物零持久生态,可接受)

## 关联
- 文档:docs/ir-schema/(schema);docs/maintainer/design/existence-structure.md(v6);docs/superpowers/specs/2026-08-27-lattice-form-ir-design.md(方向)
- 相关 ADR:ADR-0002、ADR-0004
