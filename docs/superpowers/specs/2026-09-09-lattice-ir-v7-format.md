# 格形态 IR v7 字节格式设计（真图载体）

日期：2026-09-09
状态：~~格式设计定稿（待实现）~~ → **已实施（2026-09-10，`plans/2026-09-09-lattice-ir-v7.md` Task 1-3 收官）**——v7-only 时代，字节状态以此为准；实施期裁决回填见 §4 规则 4 / §6 开放点 3、5
性质：两段式第二段（字节格式）；语义定义 = `2026-09-09-lattice-ir-v7-carrier-design.md`（权威）；本文件 = 字节怎么排。

关联：
- `docs/superpowers/specs/2026-09-09-lattice-ir-v7-carrier-design.md`（v7 载体设计——语义权威：边必落/ENT 主干化/调度 = 投影/op 字典显式遗留）
- `docs/superpowers/specs/2026-09-05-lattice-ir-v6-format.md`（v6 字节基线——本文件在其段表架构上扩展）
- `src/compiler/cir_cache.cr`（图序列化编码先例 v13：邻接式 first_edge/edge_count——NOD/EDG 编码基线）
- `docs/superpowers/specs/2026-09-09-lattice-encoding-boundary-design.md`（格层边界——P3 边必落裁决）
- `docs/ir-schema/coreir-schema.md`（三形态 schema，实现时同步）

---

## 1. 与 v6 的差异（先读总表）

| 面 | v6 | v7 |
|---|---|---|
| version | 6 | **7**（magic `"CCR1"` 不变） |
| 段集合 | STR/SYM/NOD/ENT/REG | + **EDG**（边段，tag 6） |
| NOD 记录 | 28B（op/dest/s1/s2/s3/tk） | **36B** = 28B 原字段 + `first_edge u32` + `edge_count u32` |
| 边 | 开放点（v6.0 省略） | **EDG 段必落**（P3 修复）——记录 8B 邻接式 |
| ENT | 恒空（loader 空表语义） | **实记录**（corec 产时重建——P2 修复）；记录布局 28B 不变 |
| 语义 | 文件序 = 执行序（唯一主干） | 文件序 = 合法调度（拓扑投影）；语义 = 图（NOD+EDG+REG+ENT） |

v6 其余字节惯例沿用：小端、i32/u32、offset/size u32、`ccr_i32_fits` 界校验、段表 12B×n 段序自由、v7-only（无转换工具）、中间产物 < 4GB。

## 2. 总体布局

```
┌ Header（16B）──────────────────────────────┐
│ magic u32 = "CCR1"                          │
│ version u32 = 7                             │
│ seg_count u32                               │
│ reserved u32 = 0                            │
├ 段表（seg_count × 12B）────────────────────┤
│ {tag: u32, offset: u32, size: u32}          │  ← offset 相对文件头；段序自由
├ 段体 ──────────────────────────────────────┤
│ STR / SYM / NOD / EDG / ENT / REG           │
└─────────────────────────────────────────────┘
```

段 tag 常量：`1=STR 2=SYM 3=NOD 4=ENT 5=REG 6=EDG`（`7+` 预留：驱逐标注段 v6.1 延续、证书段）。

## 3. 段定义

### 3.1 STR — 字符串表（不变）

`str_count u32` + `str_count × {len: u32, data: len bytes}`。语义同 v6。

### 3.2 SYM — 符号表（不变）

同 v6（函数/全局/结构/枚举）。函数 `param_ents` = 条目 id——v7 ENT 实记录后解析到真实条目。

### 3.3 NOD — 节点表（36B）〔格层语义 + 编码层字节；first_edge/count = 邻接索引〕

`nod_count u32` + `nod_count × 36B`：

| 字段 | 类型 | 语义 |
|---|---|---|
| op | i32 | 操作码（op 字典——语义不变声明，见载体设计 §2.2） |
| dest | i32 | 产出变量 id（-1 = 无产出） |
| src1 | i64 | 源变量/立即数 |
| src2 | i32 | 源/辅助 |
| src3 | i32 | 辅助/宽度 |
| tk | i32 | 类型码 |
| first_edge | u32 | 出边在 EDG 段的起始下标 |
| edge_count | u32 | 出边数 |

邻接约定：节点出边在 EDG 段**连续**（节点 i+1 的 first_edge = 节点 i 的 first_edge + edge_count）——重建流式零索引（cir_cache v13 同款）。文件序 = 节点 id 序 = 生产者选择的合法拓扑调度。

### 3.4 EDG — 边表（8B/记录，v7 新增）〔配方闭合的载体〕

`edg_count u32` + `edg_count × 8B`：

| 字段 | 类型 | 语义 |
|---|---|---|
| to_nod | u32 | 目标节点 id（from = 所属节点，邻接隐含） |
| kind | u32 | 边类：0 = 数据（def-use 值流）、1 = state（副作用序 = VSDG 状态链）；（2+ 预留） |

`edg_count` 必等于 Σ 各节点 edge_count（校验规则 ②）。

### 3.5 ENT — 条目表（28B，布局不变；内容恒空 → 实记录）〔格层本体〕

`ent_count u32` + `ent_count × 28B`：

| 字段 | 类型 | 语义 |
|---|---|---|
| var_id | i32 | 变量 id（-1 = 匿名常量条目） |
| version | u32 | 版本（1-based；每次定值 +1） |
| def_nod | i32 | 定值节点 id（-1 = 参数/全局） |
| live_start | u32 | 存在区间起点（NOD id，含定值） |
| live_end | u32 | 存在区间终点（NOD id，开区间） |
| home | i32 | **恒 -1 直通**（实例映射注记——分配决策 = 实例层，不写回格式） |
| flags | u32 | bit0 无配方（图内不可重算）；bit1 参数；bit2 全局；bit3 驱逐候选（v6.1 延续） |

产生规则 = 载体设计 §4（v6 §4.1 规则执行化 + 两处 carve-out）。

### 3.6 REG — region 表（24B，不变）

同 v6（kind/parent/enter_nod/exit_nod/first_ent/last_ent，坐标 = NOD id）。

## 4. 不变量与校验规则

1. **拓扑不变量（语义约束的字节形态）**：EDG 每条边 `所属节点 < to_nod`（数据/state 边前向——DAG 拓扑调度）；违规 = 文件损坏拒绝
2. **边界声明（非边）**：branch/jump/调用目标的 NOD id 引用（可后向——回边语义）是**操作数字段，不是边**；循环语义 = REG（SG_LOOP 嵌套）+ state 链表达（VSDG 先例）——EDG 只承载数据/state 两类前向边
3. `edg_count` == Σ edge_count；NOD/ENT/REG 引用 id 界内（NOD id < nod_count 等）
4. 段表 offset/size 界、ENT home/flags 读入放行——**裁决（2026-09-10 Task 2 review R3）**：loader 对 home≠-1 / flags≠0 **接受不拒绝**——home = 实例映射注记，.ccr = corec→corearch 传输中间物，实例层（分配/缓存映射）决策不写回格式；非 -1/非 0 值不构成损坏证据（无消费方依赖恒 -1/0 前提之外的安全面）。开放点 3 保留：未来实例层选择写回（非传输中间物用途）时重议
5. magic/version；`ccr_i32_fits` 沿用（中间产物 < 4GB）

## 5. 消费方影响

- **corec（产）**：图化（节点 + 数据/state 边 + 区域——dataflow.cr VSDG 机制先例；构建时机核实 = 实施计划项）→ 条目重建（载体设计 §4）→ 邻接化（first_edge/edge_count 连续布局）→ 写 v7
- **corearch（载）**：段表寻址 → NOD/EDG/ENT 载入 → 校验（§4）→ 图 → 线性调度重建（载体设计 §3：文件序 + 沿边合法性校验 + REG 展开）→ 发射（现路径语义）
- 判定/证书：共存 sweep（v6 §4.2）消费 ENT 区间；图语义消费（验证/优化）直接消费 NOD+EDG
- 测试族：ccr_v6（9/9）→ v7 同构测试 + v6 链 vs v7 链行为判据测试（载体设计 §3.3）

## 6. 开放点（实施期定夺）

1. EDG kind 扩展（2+ 预留：驱逐标注/证书边）——仅常量定义，不占空间（v6 先例同款）
2. NOD 28B 原字段与 v5 instrs 的同构声明是否需版本字段级文档对齐（ir-schema coreir-schema 同步项）
3. ENT home 非 -1 的处理级——**裁决（2026-09-10）：接受不拒绝**（§4 规则 4 注记回填）；若未来实例层选择回写（非传输中间物用途）时重议
4. 图化生产的构建时机（dataflow 现服务于 dump/分析面或全量编译——决定 v7 产成本；实施计划核实）
5. loader 侧 per-parameter ENT 内容核对与嵌套 REG 行条目范围内容核对——**推迟裁决（2026-09-10 Task 2 review R4）**：per-param 核对（param_ents 应指向该参数 var 的 def=-1 条目等）需 fn_meta 参数窗口展开（现 fn_meta 无 per-param 声明面），在 Python 测试族净锁（test_ccr_v7.py 全量块切分/param_ents/SYM 双写断言 = 测试侧同语义锁，2026-09-10 Task 3 迁移收官）期间不值得扩 fn_meta——测试锁保持，loader 内容锁挂账（未来 fn_meta 展开时激活）

## 7. 关联同步项

- v7 载体设计（语义权威）——本文件实现时以 ccr_io.cr 为基、按 schema 文档惯例对齐并入（v6 先例同款流程）
- 实施计划（后置）——依赖本文件 §6 开放点 1-4 的定夺
- corearch 重写设计（决策点 3）——消费 §5 corearch 载入 + 载体设计 §3 重建契约
