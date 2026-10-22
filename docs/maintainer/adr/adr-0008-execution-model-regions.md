# ADR-0008: 执行模型 region 化：RVSDG 风格嵌套 + state edges

- 日期：2026-08-08（region-cfg 定稿；HDFG v2 文档体系 2026-08-15 同步）
- 状态：accepted（已实现：dataflow.cr sg 段表 + 边 kind）
- 决策者：DslsDZC

## 背景

早期 HDFG 文档把图当作平面结构（节点/边/子图），控制流和副作用顺序依赖标签跳转与全局位置表来表达；验证和 region 迭代需要结构化边界。

## 决策

- 控制流使用 region 嵌套（`SG_FUNC/LOOP/FOR/FLOW/UNSAFE`，新增 `SG_IF`），region 是存在结构段（`kind`/`enter`/`exit`/`parent`/`nstart`/`ncount`）。
- state edges（边 `kind=1`）有两个来源：副作用序列（`STORE` 族/非纯 `CALL` 按指令序）和循环终止依赖（loop/for exit 连边，循环不终止则图不终止）。
- 解释器循环按 region enter/exit 迭代（break/continue = region 语义操作），不再依赖全局标签位置表。
- `g_df_node_region` 提供显式映射（O(1) 归属查询）。

## 后果

- 正面：终止性依赖被显式表达，可以证明；验证 pass、解释器和 DOT 共享 region 结构；v6 REG 段表示（坐标升级）。
- 负面：早期平面图文档（dataflow-design）整体被取代，保留存档，第 8 节的环标注仍然有效。

## 关联

- 文档：docs/maintainer/design/execution-model.md 第二节；specs/2026-08-08-region-cfg-design.md
- 相关 ADR：ADR-0002（v6 REG 段）
