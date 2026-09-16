# RVSDG 式 Region 化控制流设计

> **术语注记（2026-08-15）**：本规格中的"RVSDG 式"为当时设计路线的真实记录（参考 RVSDG 的嵌套 region 特征）；该结构后定名为 **HDFG（Holographic Dataflow Graph）**，术语演进见 docs/project-book.md。正文保留历史原样。

日期：2026-08-08
状态：已批准（brainstorming 会话，五节逐节确认）

## 1. 背景与动机

### 1.1 现状

当前控制流是线性 CFG 形态：

- 循环/分支编译为 `IR_LABEL` / `IR_JUMP` / `IR_BRANCH` 指令序列（ir_gen.cr:1147-1268）
- 数据流图（DFNode）只有数据依赖边；label/jump/branch 在图上是孤立节点（ir-schema：无变量输入 → 无边）
- 解释器按图执行（ip 走 `g_df_nodes`），循环靠 `g_label_poses` 位置表跳转——与图执行不兼容，即 TODO.md 预存 bug 第 3 条（for 循环 label/branch 问题）
- 嵌套 region 树已存在（`sg_push/sg_pop`，dataflow.cr:36-64，随 arena 机制生成）：SG_FUNC/SG_LOOP/SG_FOR/SG_FLOW/SG_UNSAFE，含 parent/enter/exit/nstart/ncount，但未语义化使用

### 1.2 论文依据

选择 RVSDG（Regionalized Value State Dependence Graph）路线：

- VDG 把循环建模为尾递归 λ 节点 → **终止性丢失**（图可能终止而程序不终止）
- VSDG 加 state edges（顺序执行依赖 + 循环终止依赖）→ 终止语义补齐，但平面图副作用节点不被保护
- RVSDG 用嵌套 region（loop/conditional 结构节点含子区域）→ 无环层次图，结构即语义，副作用被 region 保护；可回归 CFG，并行性完全暴露
- LAU 系统验证了"无环图 + 注入迭代"路线的可行性，但明确放弃循环体并行展开——RVSDG 无此限制

### 1.3 目标

把现有 SG 子图树升级为 RVSDG 式嵌套 region：

1. 新增 `SG_IF`（条件 region）
2. `g_df_node_region[]` 显式 DFNode→region 映射
3. 解释器循环按 region 迭代执行（根治 TODO #2026-07-25-1）
4. state edges（副作用链 + 循环终止依赖）
5. 序列化 v2（SG 段 + edge kind 进 .cir/.ccr，v1 兼容）
6. RegionCheck 迁移到显式映射；三 pass 回归

**ELF 后端零改动**——label/jump 保留给后端线性化（res_labels），region 是语义层。

## 2. Region 模型

### 2.1 Region 类型

现有（dataflow.cr:104-106）+ 新增：

| 值 | 名称 | 现有/新增 |
|----|------|-----------|
| 0 | SG_FUNC | 现有 |
| 1 | SG_LOOP | 现有 |
| 2 | SG_FOR | 现有 |
| 3 | SG_FLOW | 现有 |
| 4 | SG_UNSAFE | 现有 |
| 5 | SG_IF | **新增** |

`SG_IF`：if/else 在条件求值前、if 节点开头 `sg_push(SG_IF)`（ir_gen.cr:1138，push 先于 `gen_expr(cond)`），merge label 处 `sg_pop()`。区间覆盖 `[条件, 汇合)`。match 不单独建 region（展开为 if 链/跳转表）。

### 2.2 显式映射

新增并行数组 `g_df_node_region[]`（每 DFNode 一个 region id，跟随 `g_df_node_cap` 增长，照 `g_df_var_producer` 模式）：

- `df_create_node` 时写入当前 open region id（`sg_push` 维护的栈顶）
- O(1) 归属查询——解释器 region 迭代、验证 pass、DOT 分组免线性扫描

## 3. 解释器 region 迭代（P2）

现状：`ip` 走 DFNode 数组，`IR_BRANCH`/`IR_JUMP` 查 `g_label_poses` 跳转（interp.cr:187-197）。

改为 region 边界判定：

- 执行到 SG_LOOP/SG_FOR region 的 enter 节点 → 进入迭代模式（记录 region id 与 enter/exit 序号）
- 循环体按序执行；`IR_BREAK`（label 目标 == 当前 region exit）→ 跳出 region，继续 region 外下一节点
- `IR_JUMP` 回跳（label 目标 == region header）→ 重新开始迭代（回到 region enter）
- `IR_BRANCH`（for/while 条件）照旧按 label 跳转，但目标被识别为"区域内"或"region 出口"→ 判定迭代是否继续
- region exit 序号 → 正常结束迭代

效果：循环场景不再依赖全局 `g_label_poses` 位置表；`break`/`continue` 成为 region 语义操作；嵌套时 break 跳出多层（label 目标属于外层 region → 直接跳该 region exit）；early return / 异常路径不受影响。

## 4. State Edges（P3）

### 4.1 边结构

`ESZ_DFEDGE` 24→32 字节，新增 `kind` 字段：`0=data`（现有 def-use 边）、`1=state`（顺序/终止依赖）。

### 4.2 两条来源

1. **副作用链**：每个函数维护一条 state 链——`STORE`/`STORE_FIELD`/`STORE_INDEX`/非纯 `CALL` 按指令序连 state 边（prev → cur）
2. **循环终止依赖**：SG_LOOP/SG_FOR 的 exit 节点，从循环体最后一条副作用指令连一条 state 边到 exit——保证"循环不终止则图不终止"

构建位置：`df_connect_srcs` 内（emit 同步建图处），按 opcode 判定副作用；`df_end_func` 闭合链。

### 4.3 影响

- 三 pass 不遍历边（已核实）→ 零影响
- DOT 输出：state 边用虚线区分
- 每条 STORE 一次 O(1) 追加，无扫描开销

## 5. 序列化 v2（P4）

- 文件头版本号 v1→v2（.cir 文本 + .ccr 二进制）
- 新增 SG 段：`sg_count × 24B`（6×i32：kind/enter/exit/parent/nstart/ncount，内存格式 48B 与线格式 24B 区分——`ESZ_SG_DISK`）
- DFEdge 序列化带 kind
- v1 兼容：加载 v1 文件按旧格式解析，region 树退化为单 FUNC region
- 影响面：ccr_io.cr（save/load）、ir-schema 文档

## 6. 验证 Pass 迁移（P5）

- RegionCheck：改用 `g_df_node_region` 直接取归属 + parent 链（区间语义不变，O(1) 查询）
- PointerAnalysis / ProvenanceVerify：零改动，仅回归

## 7. 阶段划分与验收

| 阶段 | 内容 | 验收 |
|---|---|---|
| P1 | SG_IF 生成 + `g_df_node_region[]` + DOT 按 region 分组 | `cir` dump 断言 if/loop 的 region 结构与归属正确 |
| P2 | 解释器 region 迭代执行 | 现有循环测试全过 + TODO #2026-07-25-1 for 用例通过 |
| P3 | state edges | 图断言：STORE 序列有 state 链、loop exit 有终止边 |
| P4 | 序列化 v2 + v1 兼容 | save→load 往返一致；旧 .ccr 可加载 |
| P5 | RegionCheck 显式映射 + 全量回归 + 自举 O0/O1 | bootstrap 回归全绿 |

## 8. 测试策略

- 每阶段 TDD：先写失败测试（`.cir` dump 文本断言 / `corec run` 运行断言）
- 回归重点：`tests/suite/` 循环/嵌套/break-continue 用例；解释器；自举三阶段（corec→corec2→corec3，O0/O1）
- 新增用例：嵌套 region（if 内 loop、loop 内 if、双循环）、break 跳出多层、for 的 ivar 跨迭代保持

## 9. 风险与对策

| 风险 | 对策 |
|---|---|
| region 迭代改解释器 → 现有循环行为变化 | 回归先行；P2 独立验证 |
| label 与 region 判定共存 → 边界 bug | break/continue 的 label 目标与 region exit 映射用专项用例覆盖 |
| 序列化 v2 破坏自举 | v1 兼容加载 + 自举三阶段回归；追加段不改旧字段 |
| state edges 增加构建开销 | O(1) 追加，不引入扫描 |

## 10. 明确不做（YAGNI）

- ELF 后端零改动（label 保留给线性化）
- 任意 goto
- 验证工具消费（外部组件，等格式定型）
- SG_IF 的 then/else 独立子 region（分支内结构由嵌套 region 表达）

## 11. 文档同步（随各阶段）

- `docs/project-book.md` 5.2 / `docs/execution-model.md`："带反馈环的静态图"愿景 → region 迭代语义
- `docs/ir-schema/coreir-schema.md`：SG 段 + edge kind + v2 版本
- `CLAUDE.md` 架构段：dataflow.cr 职责描述更新
