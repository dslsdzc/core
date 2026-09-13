# 格形态 IR v7 字节格式设计（真图载体）

日期：2026-09-09
状态：~~格式设计定稿（待实现）~~ → **已实施（2026-09-10，`plans/2026-09-09-lattice-ir-v7.md` Task 1-3 收官）**——v7 段表架构时代，字节状态以此为准；实施期裁决回填见 §4 规则 4 / §6 开放点 3、5。
**2026-09-12 追加（R2 P4 Task 1，D9/D10）**：**版本 7 → 8** + 段集合 +TYPE(7)/IFACE(8)（Task 1 落空壳；内容面归 Task 2/3）。文件名保留「v7」= 段表架构代号（改名引用面 40+ 处、收益为零）；**v8 = v7 的加法扩展**：前六段字节布局不变，加段 + 版本 bump。旧 v7 六段文件由版本闸**整类拒收**（不静默当「两段缺席 = 空表」）——本条为现行字节权威（§1/§2/§3.7/§3.8/§4 已同步）。
**2026-09-14 追加（R2 P5 Task 2/7）**：**版本 / 段集合 / 记录布局零变化**——单槽化只在**内存面**（DFNode `OFF_DF_TK` = 类型项引用 / `OFF_DF_AUX` = 辅码，72B 不变）；`.ccr` 面 `tk` 语义定为**派生码**（§3.3 的「`tk` 字段语义」块，含 D20 稳定引用形态规范）；`version` 保持 8、`CIR_CACHE_VER` 保持 17；`test_ccr_types` 34 → **40** 例。
性质：两段式第二段（字节格式）；语义定义 = `2026-09-09-lattice-ir-v7-carrier-design.md`（权威）；本文件 = 字节怎么排。

关联：
- `docs/superpowers/specs/2026-09-09-lattice-ir-v7-carrier-design.md`（v7 载体设计——语义权威：边必落/ENT 主干化/调度 = 投影/op 字典显式遗留）
- `docs/superpowers/specs/2026-09-05-lattice-ir-v6-format.md`（v6 字节基线——本文件在其段表架构上扩展）
- `src/compiler/cir_cache.cr`（图序列化编码先例 v13：邻接式 first_edge/edge_count——NOD/EDG 编码基线）
- `docs/superpowers/specs/2026-09-09-lattice-encoding-boundary-design.md`（格层边界——P3 边必落裁决）
- `docs/ir-schema/coreir-schema.md`（三形态 schema，实现时同步）

---

## 1. 与 v6 的差异（先读总表）

| 面 | v6 | v7 | **v8**（R2 P4 Task 1 起 = 现行版本） |
|---|---|---|---|
| version | 6 | **7**（magic `"CCR1"` 不变） | **8**（magic 不变；**旧 v7 六段文件由版本闸整类拒收**——D10） |
| 段集合 | STR/SYM/NOD/ENT/REG | + **EDG**（边段，tag 6） | + **TYPE(7) / IFACE(8)**（D9——原 `7+` 预留段顺移 9/10；**两段内容面现行**：TYPE = Task 2、IFACE = Task 3；T1 空壳期已退役） |
| NOD 记录 | 28B（op/dest/s1/s2/s3/tk） | **36B** = 28B 原字段 + `first_edge u32` + `edge_count u32` | 不变（36B） |
| 边 | 开放点（v6.0 省略） | **EDG 段必落**（P3 修复）——记录 8B 邻接式 | 不变 |
| ENT | 恒空（loader 空表语义） | **实记录**（corec 产时重建——P2 修复）；记录布局 28B 不变 | 不变 |
| 语义 | 文件序 = 执行序（唯一主干） | 文件序 = 合法调度（拓扑投影）；语义 = 图（NOD+EDG+REG+ENT） | 不变（TYPE/IFACE = 信息面，不参与发射） |
| 前六段字节 | — | — | **布局逐字节不变**（取值随 STR 段增长重编号——R2 P4 Task 3 起 IFACE 注册名按裁决 1 驻留 ⇒ 冷路径晚于 `init_types` 驻留的串 ni 整体后移；实测 `ptr_arith` SYM 同长不同 ni。语义不变、ELF canary 不变；判据按 TODO #26 = 结构性断言） |

v6 其余字节惯例沿用：小端、i32/u32、offset/size u32、`ccr_i32_fits` 界校验、段表 12B×n 段序自由、v7-only（无转换工具）、中间产物 < 4GB。

## 2. 总体布局

```
┌ Header（16B）──────────────────────────────┐
│ magic u32 = "CCR1"                          │
│ version u32 = 8                             │
│ seg_count u32 = 8                           │
│ reserved u32 = 0                            │
├ 段表（seg_count × 12B）────────────────────┤
│ {tag: u32, offset: u32, size: u32}          │  ← offset 相对文件头；段序自由
├ 段体 ──────────────────────────────────────┤
│ STR / SYM / NOD / EDG / ENT / REG           │
│ + TYPE / IFACE                              │
└─────────────────────────────────────────────┘
```

段 tag 常量：`1=STR 2=SYM 3=NOD 4=ENT 5=REG 6=EDG` + **`7=TYPE 8=IFACE`**（R2 P4 Task 1，D9——两段必备，D11；`9+` 预留顺移：驱逐标注段 v6.1 延续、证书段）。corec 写侧用**规范序**（tag = 行号 1..8、offset = 前段尾、段体紧随段表连续）；loader 仍按规范序校验（`tg == ri+1` + 段体连续两闸形状自 v7 不变）。

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

**`tk` 字段语义（R2 P5 Task 2 起 = 现行；字节/偏移/版本零变化）**：`tk` = **派生码**——类型面 op → 类型行（`IR_CONST`/`IR_BINARY` ∪ `{IR_ALLOC, IR_CALL, IR_LOAD, IR_I2F, IR_F2I}`）；辅码面 op → 旗标/宽度/计数（`IR_BOUNDS_CHECK`/`IR_DEREF`/`IR_STORE_PTR`/`IR_SPAWN`/`IR_HOTPATCH_ROUTE`）；其余 → 0。由 `sh_dfn_code_of_slots(类型项, 辅码)` **单源派生**（emit / `lower_to_ccr` / `.cir` 装载侧三处同源；分类表 = `ty_shadow.cr` 的 `sh_tk_face_of_code`）。**盘面不承载进程内项引用**——D20 禁令：进程内项表索引不得跨进程/跨复位边界（P4 `bad_term=329` 红证）；未来跨边界唯一许可形态 = **TYPE 段文件内项索引**（β，转 P6）。P5 单槽化只在**内存面**（DFNode 72B 不变：`OFF_DF_TK` = 类型项引用 / `OFF_DF_AUX` = 辅码），NOD `.ccr` 面实测与 P4 逐字节同（`ptr_arith`/`generics_test`；`--dump-objects` 同）——详见 `plans/2026-09-13-r2-p5-cleanup.md` Task 2。

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

### 3.7 TYPE — 类型面（tag 7；R2 P4 Task 2 内容面落地）

**现行（Task 2）**：两小节 = `row_count u32` + `row_count × 24B {kind,data,extra}`
（**i64×3**——与内存 `g_types` 槽逐位同源；24B/条按 8B 字段计）→ `term_count u32`
+ `term_count × 40B {tag,a,b,c,d}`（**i64×5**；类型项 DAG，**哈希不落盘**——加载侧
由五字段重算 `tt_hash5`）。字段宽度注记：Task 1 此处曾以 `i32` 记法书写但字节数
写 24B/40B（自相矛盾）——**实施权威 = 8B 字段**（内存槽宽度，无截断面），
`ccr_io.cr` 头注释同步（实现权威）。

**段内容确定性（D13）**：段体 = 类型表/接口表的**纯函数**（与判定历史无关）——
写侧 `save` 前做「项层规范化重建」（`ccr_types.cr:ccr_type_populate`：项层/引擎/
桥接三面复位 → 按行序逐行装填 → 序列化），故项 DAG 行号 = 行序遍历的构造序。
（注：**行表本身**的冷/热 `.cir` 缓存态分歧 = 既有的前端行分配面——缓存命中跳过
ir_gen 的 `alloc_type`，`ptr_arith` 实测冷 15 行/热 12 行且热 = 冷前缀；见 P4
Task 2 报告，本 spec 只记段面。）

**loader 校验（违规 = 拒绝，三态纪律 C.5-3）**：段必备（D11）+ 两小节计数/长度
自洽 + 段体无尾随字节 + `tag ∈ 0..10`（TT_*）+ `a..d ≥ -1` + **子项引用 -1 或
< 自身行号**（拓扑无环；标注槽按 tag 分派跳过——ATOM 的 a/b、MU/VAR 的 a 等，
字段表见 `ccr_io.cr:ccr_type_term_ref_ok`）。载入 = 重建 `g_types` 行表 +
`g_type_terms` 项表 + `g_tt_index` 索引（`grow_tt_index`/`tt_reindex` 重放），
失败整体拒绝（**不得**留空表）。

**读回通道**：`corearch --dump-types`（corec 侧 `ccr --dump-types` 同一打印路径，
含项层原语 probe 行 = `tt_norm`/`tt_is_dnf`/`tt_is_literal` 在同构重建表上的
逐点同值证据）——跨进程行格式对拍载体（tests/selfhost/test_ccr_types.py）。
**未覆盖面**：判定原语（`ty_sub`/`ty_equiv`/`ty_disjoint` 族，`type_engine.cr`）
跨进程同值未覆盖——该文件不入 corearch 清单（两条既有 TF01 诊断触发 project-mode
`error[`=0 门），归 Task 3/4/P5 收口（T2 报告登记）。

### 3.8 IFACE — 接口面（tag 8；R2 P4 Task 3 内容面落地）

**现行（Task 3）**：五小节（D14；各带 count u32；**字段宽度 = 逐字段声明形**）：
① `native_count u32 = 16`（扩列硬值：13 → +AK_NULL/AK_SUM/AK_FN——裁决 3/7）
+ `× 24B {ak i32, ti_row i32, name_ni i32, lit_code i32, ops i64}`（`g_iface_entries`
原样；`name_ni` = R2 P4 Task 3 起的注册名，STR 段增长按裁决 1 接受）；
② `shape_count u32` + `× 8B {name_ni i32, term i32}`（六条 D17 生产名：`sequence` /
`sequence_ro` / `sequence_rw` / `indexable` / `iterable` / `product` → 形状项）；
③ `iface_count u32` + `× {name_ni i32, method_count i32, generic_count i32, pad i32}`
+ `method_count × 80B {name_ni i32, param_count i32, self_mode i32, ret_term i32,
param_terms[8] i32, param_codes[8] i32}`——**方法记录字段序取计划「声明行」序**
（同块尺寸式两数组次序相反 ⇒ 取声明行为准，登记见 Task 3 报告）；`ret_term`/
`param_terms` = **类型项索引**（签名项；-1 = 不可建——写侧遇不可建 = 拒绝落盘，
`ccr_iface_populate`），`param_codes` = **信息面**裸码（S6 消费点不入段）；
④ `impl_count u32` + `× 8B {trait_ni i32, type_ni i32}`（`g_impl_for`——裁决 2：
声明元数据，不入判定）；⑤ `method_count u32` + `× 12B {type_ni i32, method_ni i32,
mangled_ni i32}`（`g_methods`——`iface_find_method` 的唯一数据面）。

**loader 校验（违规 = 拒绝，三态纪律 C.5-3）**：段必备（D11）+ 五小节计数/长度
自洽 + 行走完 == 段体（无尾随字节）+ `native_count == 16` + 结构域（ak ∈ 0..AK_NULL、
method_count ≤ `MAX_IFACE_METHODS`、param_count ≤ `MAX_IFACE_METHOD_PARAMS`、
self_mode ∈ 0..3）+ **跨段引用域**：`name_ni`/`type_ni`/`method_ni`/`mangled_ni` ∈
[0, STR 串数)、`ti_row` ∈ {-1} ∪ [0, TYPE 行数)、`term` ∈ {-1} ∪ [0, TYPE 项数)
（TYPE(7) 先于 IFACE(8) 解析 ⇒ 两域已建立）。载入 = 重建 `g_iface_entries`
（`g_iface_registry_ok = 1`——**段 = corearch 侧真源**）/ `g_iface_shape_*` /
`g_ifaces`（corearch 无 AST ⇒ 节点槽恒 -1，**项槽** = 段值）/ `g_impl_for` /
`g_methods`；失败整体拒绝（**不得**静默当空表）。

**读回通道**：`corearch --dump-ifaces`（corec 侧 `ccr --dump-ifaces` 同一打印路径；
含 `ifaceprobe` 行 = 跨段项索引在重建项表上的解析同值证据；`ifacesig*` 节 = corec-only
活算对拍）——跨进程行格式对拍载体（tests/selfhost/test_ccr_types.py）。**零判定面
变化**：扩列三行 ops = 0（纯信息面），`iface_kind_of` 的行分派与 P2b 域逐格保持。

## 4. 不变量与校验规则

1. **拓扑不变量（语义约束的字节形态）**：EDG 每条边 `所属节点 < to_nod`（数据/state 边前向——DAG 拓扑调度）；违规 = 文件损坏拒绝
2. **边界声明（非边）**：branch/jump/调用目标的 NOD id 引用（可后向——回边语义）是**操作数字段，不是边**；循环语义 = REG（SG_LOOP 嵌套）+ state 链表达（VSDG 先例）——EDG 只承载数据/state 两类前向边
3. `edg_count` == Σ edge_count；NOD/ENT/REG 引用 id 界内（NOD id < nod_count 等）
4. 段表 offset/size 界、ENT home/flags 读入放行——**裁决（2026-09-10 Task 2 review R3）**：loader 对 home≠-1 / flags≠0 **接受不拒绝**——home = 实例映射注记，.ccr = corec→corearch 传输中间物，实例层（分配/缓存映射）决策不写回格式；非 -1/非 0 值不构成损坏证据（无消费方依赖恒 -1/0 前提之外的安全面）。开放点 3 保留：未来实例层选择写回（非传输中间物用途）时重议
5. magic/version（**`version == 8`**——R2 P4 Task 1 起；`version ≠ 8` 整类拒收，含全部 v7 六段文件——D10）；`ccr_i32_fits` 沿用（中间产物 < 4GB）
6. **段集合完备性（R2 P4 Task 1，D11）**：`seg_cnt` 未满 / 缺任一必备段（STR/SYM/NOD/REG/EDG/**TYPE/IFACE**）⇒ 拒绝；ENT 仍可缺（v5 精神：旧段缺失 = 空表，`ccr_io.cr` 既有口径）。**「缺段 = 空表」仅适用于 ENT**——TYPE/IFACE 缺席必须响亮拒绝（可选段 = 两种 `.ccr` 在野 = 静默降级面）
7. **~~空壳期段体校验（R2 P4 Task 1）~~（已退役——R2 P4 Task 3）**：TYPE 段自 Task 2 起、IFACE 段自 Task 3 起皆为内容面，校验 = §3.7/§3.8 的逐条不变量（含跨段引用域）；两段**必备**（规则 6）不变

## 5. 消费方影响

- **corec（产）**：图化（节点 + 数据/state 边 + 区域——dataflow.cr VSDG 机制先例；构建时机核实 = 实施计划项）→ 条目重建（载体设计 §4）→ 邻接化（first_edge/edge_count 连续布局）→ 写 v7
- **corearch（载）**：段表寻址 → NOD/EDG/ENT 载入 → 校验（§4）→ 图 → 线性调度重建（载体设计 §3：文件序 + 沿边合法性校验 + REG 展开）→ 发射（现路径语义）
- 判定/证书：共存 sweep（v6 §4.2）消费 ENT 区间；图语义消费（验证/优化）直接消费 NOD+EDG
- **TYPE/IFACE 段（R2 P4 Task 1 起）**：Task 1 = 空壳，**零消费者**（loader 仅做存在性/空壳校验）；内容面（Task 2/3）落地后由 corearch 载入**重建**类型行表/类型项表与接口表（统一设计 spec §6.3 的 `atom_of` 承接面）——纯信息面，**不参与 ELF 发射**（发射面零泄漏判据 = ELF canary 不变）
- 测试族：test_ccr_v7.py 27/27（2026-09-10 Task 3 迁移收官；2026-09-12 R2 P4 Task 1 结构断言重定 = 8 段/`HEADER_TABLE=112`/`seg_count==8`/坏版本 (7,6,5)）+ test_ccr_types.py **40/40**（T1 新建 9 例 = 段机制/loader 负分支/旧 v7 文件拒收；T2 内容面 +10（行表/项 DAG 序列化 + 确定性装填 + corearch 读回对拍 + 拓扑/标注槽负分支）；T3 IFACE 内容面 +10（五小节/扩列 16/形状命名化/签名项化/impl 边与方法表/跨段引用域）；T4 DFNode.TK 项槽 +6（逐节点允许清单规则/dex 语料/NOD 36B 同序/冷·暖快照对称/dump 零产物影响/`.cir` 布局未变）；**P5 T2 单槽化 +6**（复合行走辅码 / 互斥不变量 / F1 hotpatch 无面 / 复合行冷·暖对称 / 复合行 NOD 同序 / 快照盘面派生码保真）；机制面随批重定）——v6 测试族已合并退役；无版本链对照（v8-only 世界，行为判据 = 全量回归 + stage 链 byte-identical，见载体设计 §3.3 注记）。**判据口径（TODO #26，T1 起）**：不以「与旧版逐字节同」为准 = 结构断言全绿 + 语义零变化 + 自举稳定。

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
