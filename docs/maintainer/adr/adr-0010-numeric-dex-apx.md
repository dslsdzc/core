# ADR-0010: 数值类型 dex/apx——精确/授权二分

- 日期:2026-08-16
- 状态:accepted(设计定案;dex 迁移推进中,float 退役)
- 决策者:DslsDZC

## 背景
float 的 IEEE 754 语义与"语义保鲜 + 范式普适"冲突(NaN/±0/舍入是机器惯例);需要精确数值的范式无关表达 + 性能快路径。

## 决策
- **dex** = 精确小数(定点缩放整数,S = 10⁶ 契约决策):全序、无 NaN/±0/无穷,数学实数语义
- **apx** = 近似授权(变量级标签):CPU 兑现 = binary64 快路径;仅授权后近似
- IR_I2F/IR_F2I 迁移为 int↔dex 转换(浮点形态退役);TI_FLOAT 路径 = apx 前身
- 宽度类型(f32/f64 后缀)= 编码层标注,移出语言定案(2026-08-30 随类型系统方向)

## 后果
- 正面:精确默认、近似显式授权;验证无 NaN 陷阱;契约表(ir-op-semantics §4)有显式缩放决策
- 负面:溢出/除零/有损转换需要错误码检查点(R001/R003/R004);128 位中间积处理

## 关联
- 文档:specs/2026-08-16-numeric-types-design.md、docs/maintainer/design/ir-op-semantics.md §4
- 相关 ADR:ADR-0012(int 无上限)
