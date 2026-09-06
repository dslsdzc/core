# ADR-0008: 执行模型 region 化——RVSDG 风格嵌套 + state edges

- 日期:2026-08-08(region-cfg 定稿;HDFG v2 文档体系 2026-08-15 同步)
- 状态:accepted(已实现:dataflow.cr sg 段表 + 边 kind)
- 决策者:DslsDZC

## 背景
早期 HDFG 文档的图是平面概念(节点/边/子图),控制流与副作用顺序的表达依赖标签跳转与全局位置表;验证与 region 迭代需要结构化边界。

## 决策
- 控制流 = **region 嵌套**(SG_FUNC/LOOP/FOR/FLOW/UNSAFE + 新增 SG_IF),region = 存在结构段(kind/enter/exit/parent/nstart/ncount)
- **state edges(边 kind=1)** 两条来源:副作用链(STORE 族/非纯 CALL 按指令序)+ 循环终止依赖(loop/for exit 连边——循环不终止则图不终止)
- 解释器循环按 region enter/exit 迭代(break/continue = region 语义操作),摆脱全局标签位置表
- g_df_node_region 显式映射(O(1) 归属查询)

## 后果
- 正面:终止性依赖显式化可证;验证 pass/解释器/DOT 共享 region 结构;v6 REG 段承载(坐标升级)
- 负面:早期平面图文档(dataflow-design)整体被取代(留档,§8 环标注仍权威)

## 关联
- 文档:docs/maintainer/design/execution-model.md §二;specs/2026-08-08-region-cfg-design.md
- 相关 ADR:ADR-0002(v6 REG 段)
