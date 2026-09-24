# 概率编程 pass 实现设计


> **术语注记（2026-08-15）**：本规格为历史设计记录，其中「数据流图」（及「RVSDG 式」）为当时术语；该结构后定名为 **HDFG（Holographic Dataflow Graph，全息数据流图）**，术语演进见 `docs/project-book.md`。正文保留历史原样。

## 概述

在 Core 编译器中实现 ProbabilityPass——一个在数据流图上运行的概率推导 pass。该 pass 不需要新语法、不需要运行时系统、不需要 CPS 变换，全部工作在编译期完成。

参考 Mappl (PLDI 2024) 的变量消元编译方法，并利用 Core 已有的数据流图简化实现。

## 核心原则

- **概率以 pass 形态实现，而非新增语言特性。**
- **数据流图天然记录了所有依赖关系。** Mappl 需借助信息流类型系统与 CPS 变换才能分析的信息，Core 的数据流图上已经具备。
- **`random()` 是库函数。** 编译器不做特殊对待——pass 看到的是 `IR_CALL random` 节点。
- **观测即条件分支。** `if sensor > 30` — pass 在该分支边上标注观察约束。

## ProbabilityPass 架构

```
输入: 数据流图 (g_df_nodes, g_df_edges)
      分支节点 (IR_BRANCH) 已就位
      random() 调用 (IR_CALL) 作为普通节点出现

pass 流程:
  1. scan_random_calls()  — 扫描 random() 节点
  2. tag_branch_weights() — 识别 random() < p 模式，标注分支概率
  3. propagate_weights()  — 沿值流传播概率权重
  4. apply_observations() — 处理观测约束（条件分支）
  5. annotate_graph()     — 将分布信息附到图节点上

消费端:
  - 优化器: 低概率路径放远
  - 代码生成: 冷热路径分离
  - 验证器: 统计性质检验

无运行时开销: 全部信息在编译期走完。
```

## Step 1：`random()` 节点识别

```core
fn scan_random_calls() {
    // 遍历所有 DF 节点
    ni := 0;
    loop {
        if ni >= g_df_node_count { break; }
        op := r64(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_OPCODE);
        if op == IR_CALL {
            fn_ni := r64(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S3);
            fn_name := istr_get(fn_ni);
            if str_eq(fn_name, "random") != 0 {
                mark_random_node(ni);
            }
        }
        ni = ni + 1;
    }
}
```

## Step 2：分支概率标注

`random() < p` 模式在图中是 `IR_BRANCH s1=condition`。如果 `condition` 的上游是 `IR_BINARY(OP_LT, random_call, IR_CONST(p))`，则：

```core
fn tag_branch_weights() {
    // 对每个 BRANCH 节点:
    //   检查 condition 是否来自 random() < const
    //   如果是: 在分支边上标注 probability = p
    //   如果不是: 标记为 unknown (不做优化)
}
```

图上的表示：

```
random() ──→ IR_CONST(0.3)
    ↓            ↓
 IR_BINARY(OP_LT)
    ↓
 IR_BRANCH → true_edge (weight=0.3)
          → false_edge (weight=0.7)
```

## Step 3：权重传播

沿值流传播概率权重。原理与数据流分析相同——每个值的"可能概率"沿分支边与数据边传播：

```core
fn propagate_weights() {
    // 对每个 PHI 节点（值汇合点）:
    //   从汇合的两个分支取权重
    //   权重相乘后作为该值的分布概率
    //
    // 示例:
    //   result := if random() < 0.05 { "rare" } else { "common" }
    //   → result 的分布: {5% "rare", 95% "common"}
    
    // 迭代直到不动点（和 PointerAnalysis 一样的模式）
    changed := 1;
    loop {
        if changed == 0 { break; }
        changed = 0;
        // 遍历所有 PHI/BINARY 节点
        // 更新权重
    }
}
```

## Step 4：观测约束

`if sensor > 30 { ... }` — 条件分支同时也是一个观测。pass 在该处标注：

```core
fn apply_observations() {
    // 找到条件分支中涉及 random() 返回值的
    // 在分支边上标注后验约束
    //   P(true_temp | sensor > 30)
    // 之后的 PHI 节点使用后验而不是先验
}
```

## Step 5：图标注

概率信息附加到 DF 节点上供优化器和验证器消费：

```core
// 新增 DF 节点字段（复用现有字段）
// OFF_DF_PROB: int = 48  — 概率权重 (fixed-point, 0-1)
// EXTENDED_ESZ_DFNODE: int = 72  (原本 64 + 8)
```

替代方案：使用独立的 `g_node_probs[]` 数组（8 bytes per node），不修改 `DFNODE` 结构。

## 与 Mappl 的对比

| Mappl | Core |
|-------|------|
| 信息流类型系统 → 分析依赖 | 数据流图边已记录所有依赖 |
| CPS 变换 → 处理分支上下文 | 图的分支节点已在图上 |
| 消元子问题分解 | 子图边界已划分 |
| 类型安全证明 | 图结构保证正确性 |
| 运行时消元 | 编译期权重传播 |

## 实现清单

| # | 文件 | 改动 |
|---|------|------|
| 1 | `src/compiler/prob_pass.cr` | 新建：ProbabilityPass 五个步骤 |
| 2 | `src/compiler/main.cr` | passe 管线中插入 ProbabilityPass |
| 3 | `src/compiler/globals.cr` | g_node_probs 数组 |
| 4 | `tests/suite/prob_test.cr` | 测试 |
