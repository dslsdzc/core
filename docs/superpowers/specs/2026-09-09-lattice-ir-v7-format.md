# 格形态 IR 字节格式

> **历史文档（v7 / v8 / v9）**：本文固定描述 v7→v9 时代的 `.ccr` 字节布局，
> 包括 version 9 的 8 段表、28B ENT 与 `home` 字段。**它不是当前格式**，
> 仅作历史留痕，不随实现更新。当前线格式（v10：9 段、ENT 24B、无 `home`）
> 见 `docs/superpowers/specs/2026-10-23-lattice-ccr-v10-design.md`；v9 文件
> 自 v10 cutover 起整类拒收，只作为负向 fixture 保留在测试中。

## 概述

`.ccr` 是格形态的字节表示。当前版本是 9，使用段表架构。语义定义以 carrier 设计为准，本文件定义字节布局。

文件由头部、段表和段体组成：

```text
Header 16B
    magic u32 = "CCR1"
    version u32 = 9
    seg_count u32 = 8
    reserved u32 = 0

段表 seg_count × 12B
    tag u32
    offset u32      相对文件头
    size u32

段体
    STR SYM NOD ENT REG EDG TYPE IFACE
```

段 tag：

```text
1=STR  2=SYM  3=NOD  4=ENT
5=REG  6=EDG  7=TYPE 8=IFACE
```

写侧使用规范序：tag 等于行号，offset 等于前一段尾部，段体紧随段表连续排列。loader 校验段号和段体连续。

设计状态：已实施。格式版本演进、实施裁决和检查集合见 `docs/superpowers/implementation/2026-09-09-lattice-ir-v7-format-audit.md`。

## 段定义

### STR：字符串表

```text
str_count u32
str_count × {len: u32, data: len bytes}
```

### SYM：符号表

保存函数、全局、结构体和枚举。函数 `param_ents` 是条目 id，加载后解析到真实条目。

### NOD：节点表

```text
nod_count u32
nod_count × 40B
```

| 字段 | 类型 | 语义 |
|---|---|---|
| `op` | i32 | 操作码 |
| `dest` | i32 | 产出变量 id，-1 表示无产出 |
| `src1` | i64 | 源变量或立即数 |
| `src2` | i32 | 源或辅助 |
| `src3` | i32 | 辅助或宽度 |
| `tk` | i32 | 类型码，派生码 |
| `item` | i32 | TYPE 段文件空间项索引，-1 表示无项 |
| `first_edge` | u32 | 出边在 EDG 段的起始下标 |
| `edge_count` | u32 | 出边数 |

邻接约定：节点出边在 EDG 段连续。节点 i+1 的 `first_edge` 等于节点 i 的 `first_edge` 加 `edge_count`。重建时流式读取，不需要索引。

文件序等于节点 id 序，等于生产者选择的合法拓扑调度。

`item` 是 TYPE 段文件空间项索引。写侧在保存期由盘上派生码重新派生，不能沿用 emit 期的进程内表索引。读侧在 TYPE 段解析后做一致性校验：`item` 越界，或 `atom_of(item)` 不等于盘上 `tk`，拒绝加载。缓存命中跳过 `ir_gen` 时可以写入 -1，`tk` 仍保真。

`tk` 是派生码，由类型项和辅码共同计算。分类规则：

- 类型面 op：`IR_CONST`、`IR_BINARY`，以及 `IR_ALLOC`、`IR_CALL`、`IR_LOAD`、`IR_I2F`、`IR_F2I`。
- 辅码面 op：`IR_BOUNDS_CHECK`、`IR_DEREF`、`IR_STORE_PTR`、`IR_SPAWN`、`IR_HOTPATCH_ROUTE`。
- 其余得到 0。

进程内类型项索引不能跨进程或跨复位边界使用。跨边界只允许 TYPE 段文件内项索引。

### EDG：边表

```text
edg_count u32
edg_count × 8B {to_nod: u32, kind: u32}
```

`from` 由所属节点隐含。

`kind`：

- 0 是数据边，表示 def-use 值流。
- 1 是 state 边，表示副作用顺序。
- 2 及以上预留。

`edg_count` 必须等于所有节点 `edge_count` 之和。

### ENT：条目表

```text
ent_count u32
ent_count × 28B
```

| 字段 | 类型 | 语义 |
|---|---|---|
| `var_id` | i32 | 变量 id，-1 表示匿名常量条目 |
| `version` | u32 | 版本，1-based，每次定值加 1 |
| `def_nod` | i32 | 定值节点 id，-1 表示参数或全局 |
| `live_start` | u32 | 存在区间起点，包含 |
| `live_end` | u32 | 存在区间终点，开区间 |
| `home` | i32 | 恒为 -1，实例映射注记，分配决策不写回格式 |
| `flags` | u32 | bit0 无生成方法，bit1 参数，bit2 全局，bit3 移除候选 |

条目产生规则见实现方式设计第 4 节。

### REG：区域表

```text
24B {kind, parent, enter_nod, exit_nod, first_ent, last_ent}
```

坐标使用 NOD id。

### TYPE：类型面

两小节：

```text
row_count u32
row_count × 24B {kind i64, data i64, extra i64}

term_count u32
term_count × 40B {tag i64, a i64, b i64, c i64, d i64}
```

行表与内存类型表槽位同源。项表是类型项 DAG，哈希不落盘，加载时由五个字段重算。

段内容必须确定：段体是类型表和接口表的纯函数，与判定历史无关。写侧在保存前重建项层，按行序装填并序列化，因此项 DAG 行号是行序遍历的构造序。

loader 校验：

- TYPE 段必备。
- 两小节计数和长度自洽。
- 段体没有尾随字节。
- `tag` 在允许范围。
- 子项引用是 -1 或小于自身行号，保证无环。

加载时重建类型行表、类型项表和索引。失败整体拒绝，不能留空表。

读回通道是 `--dump-types`。

### IFACE：接口面

五小节：

1. `native_count u32`，当前为 16，后接 `× 24B {ak i32, ti_row i32, name_ni i32, lit_code i32, ops i64}`。这是原生接口条目。
2. `shape_count u32`，后接 `× 8B {name_ni i32, term i32}`。形状名包括 `sequence`、`sequence_ro`、`sequence_rw`、`indexable`、`iterable` 和 `product`。
3. `iface_count u32`，后接条目头 `{name_ni, method_count, generic_count, pad}`，再后接方法数组。每个方法是 `80B {name_ni, param_count, self_mode, ret_term, param_terms[8], param_codes[8]}`。`ret_term` 和 `param_terms` 是类型项索引，-1 表示不可建。写侧遇到不可建时拒绝落盘。
4. `impl_count u32`，后接 `× 8B {trait_ni, type_ni}`。这是声明元数据，不进入判定。
5. `method_count u32`，后接 `× 12B {type_ni, method_ni, mangled_ni}`。这是方法查找的数据面。

loader 校验：

- IFACE 段必备。
- 五小节计数和长度自洽。
- 行走完等于段体，没有尾随字节。
- `native_count` 等于 16。
- `ak`、`method_count`、`param_count` 和 `self_mode` 在允许范围。
- 跨段引用在 STR 和 TYPE 的范围内。
- TYPE 先于 IFACE 解析。

加载时重建接口条目、形状表、接口表、impl 边和方法表。失败整体拒绝，不能当作空表。

读回通道是 `--dump-ifaces`。

## 校验规则

1. 拓扑：EDG 每条边的所属节点小于 `to_nod`。数据和 state 边都是前向边。违反则文件损坏，拒绝加载。
2. 边界声明不是边：branch、jump 和调用目标的 NOD id 是操作数字段，可以后向。循环语义由 REG 和 state 链表达。EDG 只保存数据和 state 两类前向边。
3. `edg_count` 等于所有节点 `edge_count` 之和。NOD、ENT 和 REG 的引用 id 必须在范围内。
4. 段表 offset 和 size 必须在界内。`home` 和 `flags` 读入时放行，非 -1 或非 0 不构成损坏。`home` 是实例映射注记，分配决策不写回格式。
5. magic 和版本必须匹配。`version` 必须等于 9，旧版本整类拒收。中间产物必须小于 4GB。
6. 段集合必须完备。STR、SYM、NOD、REG、EDG、TYPE 和 IFACE 缺一即拒绝。ENT 可以缺席，缺席按空表处理。TYPE 和 IFACE 不能缺席，否则会出现两种 `.ccr` 并存和无提示降级。
7. TYPE 和 IFACE 的段体按各自的逐条不变量校验，包括跨段引用范围。两段必备规则不变。

## 消费方

- `corec` 生产 `.ccr`：图化节点、边和区域，重建条目，邻接化，写段表。
- `corearch` 加载 `.ccr`：段表寻址，加载 NOD、EDG 和 ENT，校验，重建线性调度，发射。
- 验证和优化：直接使用 NOD 和 EDG。共存 sweep 使用 ENT 区间。
- TYPE 和 IFACE：由 `corearch` 加载并重建类型表、类型项表和接口表。它们不参与 ELF 发射。
- 测试：`test_ccr_v7.py` 检查段结构，`test_ccr_types.py` 检查 TYPE 和 IFACE 的内容、加载负分支和读回。

## 开放点

1. EDG `kind` 的 2 以上值预留给移除标注和证书边，只定义常量，不占空间。
2. NOD 字段与旧版指令的同构声明是否需要版本级文档对齐。
3. ENT `home` 非 -1 时的处理级别。当前接受不拒绝。未来实例层选择回写时重新讨论。
4. 图化生产的构建时机，决定 `.ccr` 的生产成本。
5. loader 对每个参数条目和嵌套区域条目范围的内容核对。当前测试锁保持，loader 内容锁挂账。

## 关联

- 修订记录和实施注记：`docs/superpowers/implementation/2026-09-09-lattice-ir-v7-format-audit.md`
- 语义定义：`docs/superpowers/specs/2026-09-09-lattice-ir-v7-carrier-design.md`
- v6 字节基线：`docs/archive/2026-09-05-lattice-ir-v6-format.md`
- IR schema：`docs/ir-schema/coreir-schema.md`
- 类型接口实施：`docs/superpowers/specs/2026-09-10-type-interface-unification-design.md`
