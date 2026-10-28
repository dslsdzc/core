# AST span 第一次实施记录

> 状态：已实施（第二次尝试成功后保留）
> 日期：2026-10-27
> 关联：`docs/superpowers/plans/2026-10-27-ast-span.md`

## 做了什么

按计划第 3 步切换节点布局：

1. `ESZ_ASTNODE` 从 72 改成 64，`line`、`col` 两个字段换成一个 64 位 span 字段，内容是 `lo + hi × 2³²`。
2. token 的 `lo`、`hi` 改成全局字节偏移加 1，使 0 继续表示“无位置”。
3. 解析器里属于 `alloc_node` 的 `tok_ln`、`tok_cl` 全部换成 `tok_lo`、`tok_hi`，包括跨行调用。
4. `ast_line`、`ast_col` 改为经 SourceManager 换算。
5. monomorph 克隆节点时复制原 span。

构建通过。单文件诊断正确。

## 失败点

`check src/compiler` 产生 4414 条诊断，大量函数被报成未定义。

原因：AST 的 `line` 不只是诊断坐标，它同时是**全局行号**。以下消费者都按全局行号索引：

| 消费者 | 用途 |
|---|---|
| `diag_fileid_for_line` | 行号到文件 |
| `g_line_lib`、`lib_of_line` | 行号到所属库 |
| `lib_of_node` | 节点到所属库，决定符号可见性 |
| `.ccr` 的行号字段 | 函数和符号的位置 |

第一次实现让 `ast_line` 返回文件内行号，上面四个消费者把行号当全局行号用，文件和库归属全部错位，符号可见性随之失效，于是出现大量“未定义函数”。

中途改成 `ast_line` 返回 `line_base + 文件内行号`（即全局行号）后，两文件用例的文件归属恢复正确，但 `check src/compiler` 仍然失败，说明还有其它消费者依赖全局行号的精确值。

## 回退

`jj restore` 放弃工作副本改动，重新构建，`check src/compiler` 通过，canary 未受影响。

## 修订后的顺序

先迁移消费者，再切换布局：

1. 节点暂时同时保留行号和 span（72 字节增至 80 字节）。这一步只增加信息，不改变任何判定。
2. 把 `lib_of_node`、`diag_fileid_for_line`、`g_line_lib` 的索引、LSP 位置换算逐个改成按 span 查找，行号只用于最终显示。
3. 全部消费者迁移完并且测试通过后，再删除行号和列号字段，节点降到 64 字节。
4. 每一步都能单独构建和回退。

代价是中间阶段节点多 8 字节，收益是每一步都可验证，不会出现整棵树红掉的状态。

## 第二次尝试（同日，成功）

第一次失败的真正原因是 `ast_line` 的返回值变了，而不是 span 本身。第二次保留它的历史语义：返回全局行号，由 span 解码得到。四个按全局行号索引的消费者因此不用改。

关键实现：

| 位置 | 变化 |
|---|---|
| `dyn_arr.cr` | 节点 64 字节，`OFF_AS_SPAN` 存 `lo + hi × 2³²` |
| `lexer.cr` | token 偏移是全局字节偏移加 1，0 表示无位置 |
| `parser.cr` | `alloc_node` 的位置参数改成 `tok_lo` / `tok_hi`；函数节点的位置也改为字节偏移 |
| `source.cr` | `ast_line`、`ast_col`、`ast_lo`、`ast_hi`，以及带缓存的 `sm_span_file` |
| `lib_manager.cr` | `lib_of_node` 直接从 span 取所属文件 |

修复的两个既有缺陷：

1. `def_type_sym` 用位置为 0 的合成节点推导类型符号所属库，导致所有类型符号 owner = -1。`sym_visible` 把 owner < 0 当作可见，于是非 pub 库类型（例如 `Argv4`）在库外可见。改为直接用声明行号算 owner。
2. `find_struct_by_name` 把解析器写入的源名当作唯一名查询。所属库修正后，用户结构体与库类型同名时解析到库里的那个。改为先按（源名，当前库）查。

性能：`sm_span_file` 缓存上一次命中的文件，`lib_of_node` 改走 span。`check src/compiler` 冷缓存 44.9 秒，改造前 52.7 秒。

验证：`check src/compiler` 通过；pub-visibility、pub-label、lib-manager、cast 12/12、struct-impl 14/14、import-graph 7/7、diag-gate 28/28、impl 8/8、enum-impl 5/5、iface-ops 73/73、hit-table 24/24、ccr-types 53/53、apx-conversion、s1p-liveness、field-inference 5/5；canary 5/5 不变。
