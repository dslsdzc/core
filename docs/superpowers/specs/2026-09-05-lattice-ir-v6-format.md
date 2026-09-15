# 格形态 IR v6 二进制格式设计（存在结构主体）

> ## ⛔ 文档状态：已被 v7 取代（2026-09-10 Task 3 收官注记）
>
> v6 字节格式（5 段、NOD 28B、ENT 恒空、边不落盘）未单独实现即被 v7 演进取代——
> 2026-09-09 起字节权威 = `2026-09-09-lattice-ir-v7-format.md`（v7 = 6 段 + NOD 36B 邻接 +
> EDG 段必落 + ENT 实记录）；实施 = `plans/2026-09-09-lattice-ir-v7.md` Task 1-3（2026-09-10
> 收官）。**v7-only**：loader 拒 version≠7，无 v6 兼容/转换工具（.ccr = 管线中间产物
> 现生成）。本文件保留作历史基线。v6 时代裁决点/文字在 v7 语境下的结局：
>
> - **原则 6（v5 的 IR 变量槽模型保留）= P1 泄漏源标注**：槽模型下从未定值 var（全局/
>   参数/0 字面量槽）的 `g_df_var_producer` 播种 = 0 → 幽灵数据边 0→X + 自环 (0,0)（v7
>   实施计划 Task 0 注 A 实测）；v7 以播种修复（全 var 槽恒 -1）落地。语义侧修复（op
>   字典演进）独立后续——v7 载体设计 §2.2：泄漏从「载体结构泄漏」降级为「字典引用
>   泄漏」（显式遗留标注）。
> - **§7 开放点 1（NOD 边表是否必须）= 裁决：必落**：v6.0「先省略」路线未发生——v7
>   以 EDG 段（tag 6，8B {to_nod, kind}，邻接式）落地（P3 修复）。
> - **§4.1 ③ 文字 vs 实现（差异①）**：「区间 = [函数首节点, last_ref+1)」与实现不符——
>   def=-1 条目（参数等）区间 = **[first_ref, last_ref]**（live_start = 首引用指令，非
>   函数首节点）；盘上 live_end 半开 = last_ref+1。**实现语义为准**——v7 同规则（v7
>   载体设计 §4.1 注记同步）。
> - **§3.2「局部变量由 ENT 全量携带」未兑现**：v6.0 保守实施实际把局部变量声明并入
>   SYM func 记录（var 声明区）——v7 同此实现形状（字节 spec §3.2），ENT = 区间/版本
>   视图（非唯一声明面）。

> ## 📌 本文档用途（先读这段）
>
> **这份文件回答一个问题：v6 的 `.ccr` 文件在磁盘上长什么样（段布局、每段字段、字节语义）。**
>
> - **字节级最终规格的家 = `docs/ir-schema/coreir-schema.md`**（三形态总 schema：.cir 图 / .csr 规约 / .ccr 线性化——本文档的字节设计是草案，Task 4 开工时以 ccr_io.cr 实现为基、按 schema 文档惯例对齐并入；见计划 Task 6）。
> - **它是「设计定稿」，不是实现现状，更不是代码文档。** 代码里现在仍是 v5 格式（`ccr_io.cr` 头注释写明 v5 段序列）；本文描述的 v6 段（SYM/NOD/ENT/REG）**一行代码都还没写**。读到「v6 有 XXX 段」不等于代码里有——实现状态以实施计划为准。
> - **它在文档家族中的位置**：
>   ```
>   2026-08-27-lattice-form-ir-design.md  ← 方向定稿（为什么升 v6、存在结构是什么）
>         ↓ §4.2 的实质化
>   本文档（v6-format）                     ← 格式设计（字节怎么排）——就是本文
>         ↓ 实施依据
>   2026-09-05-lattice-ir-v6.md（计划）     ← 怎么实现（任务分解；Task 4 = 格式 IO 落地）
>   ```
> - **与硬件接口表（HIT）的关系**：HIT（`2026-09-05-hardware-interface-table.md`）是**后到**的概念（2026-09-05 同日稍晚定稿），本文档早于它、未含它。衔接点：v6 的 NOD op 是平台无关的 IR 操作，HIT 事件（sub/nand/load/store…）是它的**编码层接口**——「NOD op ↔ HIT event_id」的对齐是实施期事项（本文 §7 开放点 1 同源）。
> - **代理工作提示**：若你的任务涉及 .ccr 读写/后端发射/存在结构数据，先确认任务的坐标与格式版本——实施计划（`plans/2026-09-05-lattice-ir-v6.md`）里标了「格数据面 Task 1-3 先行（纯内存推导，不落盘）」；格式落盘是 Task 4，**当前代码与测试全部仍是 v5**。不要按本文设计去改 v5 代码，除非你的任务明确是格式 IO。

日期：2026-09-05
状态：~~格式设计定稿（待实现）~~ → **已被 v7 取代（2026-09-10 收官）**——v6 仅以实施中间态存在（2026-09-09 段表 5 段 + NOD 28B + ENT 恒空落地后同日切换 v7，零生态，无 v6 文件存续），直接演进为 v7 真图载体（见文首 ⛔ 状态注记；字节权威 = `2026-09-09-lattice-ir-v7-format.md`）。决策拍板记录（D1 图节点坐标 / D2 corearch 重建投影 / D3 共存推导 sweep）均被 v7 继承。
关联：`docs/superpowers/specs/2026-08-27-lattice-form-ir-design.md`（方向定稿，§4.2 本设计为其实质化）、`docs/regalloc-cache-mapping.md`（判定四条）、`docs/memory-model-capability-lattice.md` v4、`docs/ir-schema/coreir-schema.md`（v5 规格，v6 实现时同步）、`src/compiler/cir_cache.cr`（图序列化先例）、`docs/superpowers/plans/2026-09-05-lattice-ir-v6.md`（实施计划——实现状态以它为准）、`docs/superpowers/specs/2026-09-05-hardware-interface-table.md`（HIT——后到概念，NOD op ↔ event_id 对齐见 §7）。

## 1. 设计原则

1. **存在为主体，执行为投影**：v5 文件描述「按什么顺序执行什么」（线性指令数组）；v6 描述「什么存在（条目 × 版本）、存在多久（区间）、由什么产生（配方）、嵌套在哪（region）」——执行序是可重建的投影，不再是文件主干。
2. **图节点坐标**（D1）：存在区间端点、region 边界、条目定值点全部以 **NOD id**（图节点序）为坐标——与 `.cir`（图形态）同坐标系，兑现「图 = 唯一真相层」。
3. **执行序重建**（D2）：corearch 从 NOD + REG 重建线性投影。图节点文件序即合法拓扑序（`dataflow.cr:351 lower_to_ccr` 注释：「sequential walk is already a valid topological schedule」）——重建 = 文件序直出 + region 边界标注，无排序成本。
4. **共存不落盘**（D3）：判定消费时从存在区间推导，sweep 算法 O(n log n)（排序）+ O(n)（扫描），不超线性、不冗余存储。
5. **v6-only**：不兼容 v5、无转换工具（.ccr 为管线中间产物，corec→corearch 现生成，零持久生态——2026-09-05 计划定稿）。
6. **v5 的 IR 变量槽模型保留**：NOD 的 dest/srcs 语义与 v5 instrs 相同（引用 vars 表变量 id）——corearch 指令发射逻辑最小改动；ENT 提供变量 × 版本的存在视图，经变量 id 与 NOD 关联。
7. **层定位（2026-09-05 补定，依 `memory-model-capability-lattice.md` v4 §四）**：本文档描述的格式横跨两层，阅读时区分——
   - **格层（范式无关承诺在此）**：存在结构语义——条目（位置+配方+存在）、版本、存在区间、共存关系（对称、无传递性，最弱理论）、判定规则条目泛型。`超图灵属于图不属于格`；格不需要理解范式。
   - **编码层（hw-map 域 = 经典投影实例，无范式无关承诺）**：字节布局——段表/字段宽/变长记录/对齐。字节层事务实现时定（Task 4），仓库先例 `cir_cache.cr` v13（函数级图序列化变长记录）。字节只是「把格编码成经典机器的字节」（备忘 §4.2 第三层定义）。

## 2. 总体布局

```
┌ Header（16B）──────────────────────────────┐
│ magic u32 = "CCR1"                          │
│ version u32 = 6                             │
│ seg_count u32                               │
│ reserved u32 = 0                            │
├ 段表（seg_count × 12B）────────────────────┤
│ {tag: u32, offset: u32, size: u32}          │  ← offset 相对文件头；段序自由
├ 段体（按段表寻址，段序任意）────────────────┤
│ STR / SYM / NOD / ENT / REG                 │
└─────────────────────────────────────────────┘
```

段 tag 常量：`1=STR 2=SYM 3=NOD 4=ENT 5=REG`（`6+` 预留：驱逐标注段 v6.1、证书段）。
所有 i32/u32 小端；offset/size 为 u32——中间产物 < 4GB（沿用 `ccr_i32_fits` 校验先例）。

## 3. 段定义

### 3.1 STR — 字符串表（不变）

`str_count u32` + `str_count × {len: u32, data: len bytes}`。语义同 v5。

### 3.2 SYM — 符号表（归并 v5 func_meta/structs/enums/globals）

| 记录 | 字段 | 说明 |
|---|---|---|
| 函数 | `name→STR, param_count, param_ents[param_count]×u32`（参数 = 条目 id）、`ret_type u32`、`root_region i32`（REG id）、`first_ent/last_ent i32`（本函数条目范围，-1 = 无） | v5 func_meta 的 instr_start/count 由 root_region + NOD 范围取代 |
| 全局 | `name→STR, init_val i64` | 同 v5 globals（条目引用经 ENT flags=全局） |
| 结构 | `name→STR, field_count, fields×{name→STR, type u32}` | 同 v5 |
| 枚举 | `name→STR, variant_count, variants×{name→STR, fields…}` | 同 v5 |

变量（局部）不入 SYM——由 ENT 全量携带（存在即声明，v5 vars 表并入 ENT 的 var 属性）。

### 3.3 NOD — 节点表（图事件 = 配方；v5 instrs 的图坐标化）〔格层语义 + 编码层字节：节点 = 图事件（格层）；字段宽 = 编码层投影〕

`nod_count u32` + `nod_count × 28B`：

| 字段 | 类型 | 语义（同 v5 instrs） |
|---|---|---|
| op | i32 | 操作码 |
| dest | i32 | 产出变量 id（-1 = 无产出） |
| src1 | i64 | 源变量/立即数 |
| src2 | i32 | 源/辅助 |
| src3 | i32 | 辅助/宽度 |
| tk | i32 | 类型码 |

+ `edge_count u32` + `edges × 24B {from_nod u32, to_nod u32, kind u32, reserved u32}`（v6 新增显式边——v5 边不落盘；格式以 `cir_cache.cr` v13 的 DFEdge 32B 记录为基线压缩而来；kind = 数据/state 边，.cir 语义）。

坐标约定：**NOD id = 文件序索引 0..nod_count-1**——即图节点坐标（D1），存在区间端点直接引用它。执行重建 = 文件序 + REG 边界。

### 3.4 ENT — 条目表（存在结构核心，v6 新增）〔**格层本体**：条目的数学结构（位置+配方+存在）在此；字节宽（28B）是编码层投影，可按编码空间调整〕

`ent_count u32` + `ent_count × 28B`：

| 字段 | 类型 | 语义 |
|---|---|---|
| var_id | i32 | 变量 id（与 NOD dest/srcs 同命名空间；-1 = 匿名常量条目） |
| version | u32 | 该变量第几版（1-based；每次定值 +1） |
| def_nod | i32 | 定值节点 id（-1 = 函数参数/全局） |
| live_start | u32 | 存在区间起点（NOD id，含定值） |
| live_end | u32 | 存在区间终点（NOD id，**开区间**：最后使用点 +1） |
| home | i32 | 槽位（分配器回填；-1 = 未分配/寄存器候选） |
| flags | u32 | bit0 无配方（图内不可重算，条款 4b → 必须有 home）；bit1 参数；bit2 全局；bit3 驱逐候选（v6.1 用） |

**版本化语义**：Core IR 非 SSA（变量多定值）——变量每次定值切分一个新版本条目（定值点收集规则 = §4.1：dest ≥ 0 的 NOD；`IR_STORE` 的定值目标在 s1——ρ(s1):=ρ(s2)，dest 恒 -1；`IR_STORE_INDEX_VAR`/`IR_STORE_PTR`/`IR_DYN_DISPATCH` 的 dest ≥ 0 非定值——值为源/元数据/占位，GC 批 2 勘定）；相邻版本的存在区间按定值点切割（版本 k 区间终点 = 版本 k+1 定值点）。
**匿名常量条目**（var_id = -1）：仅当常量被判定消费（如跨调用存活）时物化，否则常量内联于 NOD src1——避免条目爆炸。

### 3.5 REG — region 表（SG 嵌套，坐标升级）〔格层语义 + 编码层字节〕

`reg_count u32` + `reg_count × 24B`：

| 字段 | 类型 | 语义 |
|---|---|---|
| kind | u32 | SG_IF/LOOP/FOR/FLOW/UNSAFE/FUNC |
| parent | i32 | 父 region id（-1 = 根） |
| enter_nod | u32 | 入口节点 id（v5 enter 指令号的坐标升级） |
| exit_nod | u32 | 出口节点 id |
| first_ent | i32 | 区内首条目（-1 = 无） |
| last_ent | i32 | 区内末条目 |

## 4. 推导与判定（消费侧，不落盘）〔**纯格层**：区间/共存的数学推导，与字节编码无关〕

### 4.1 条目重建（corec 产生 v6 时）

输入：图（NOD + 边 + REG）。步骤：
1. 定值点收集：扫 NOD，dest ≥ 0 的节点 = 该变量的定值点 → 版本切分（def_nod、version）
   ——两处 carve-out（规则全文与出处 = §3.4「版本化语义」，GC 批 2 勘定）：
   ① IR_STORE 单列：定值目标在 s1（ρ(s1):=ρ(s2)，dest 恒 -1）——不走 dest 列；
   ② 三 op 排除：STORE_INDEX_VAR/STORE_PTR/DYN_DISPATCH 的 dest ≥ 0 **非**定值
   （值 = 被存值源/基址标注/占位）——不产版本。①/② 之外 dest ≥ 0 方为定值点
2. 活区间：图坐标扫描（同 `alloc_registers` 的 [first_ref, last_ref] 逻辑，坐标单位 = NOD id）——版本 k 区间 = [def_k, def_{k+1}) 与 [def_k, last_ref+1) 的截断
3. 参数/全局条目：def_nod = -1，区间 = [函数首节点, last_ref+1)

### 4.2 共存判定（判定消费时现算，O(n log n) 不超线性——D3）

`entries_coexist` 不逐对枚举。算法（sweep）：
1. 按 live_start 排序条目（O(n log n)，自举编译器内自带排序——归并或插入，函数级 n ≤ 数千）
2. 单遍扫描：维护**活跃条目集**（start < 当前点 ≤ end 的条目）；新条目 start 进入时，与活跃集中 end > start 的条目即共存——用按 end 排序的活跃集弹出（end ≤ start 的移出）
3. 判定四条消费此关系（如共存互斥：分配到同 home 的条目对是否相交——同 home 组内做 2 的扫描，O(k log k) per 组）

无需输出全量共存表——判定四条都是「存在性/∀ 检查」，sweep 给出相交证据即止。

### 4.3 投影重建（corearch，D2）

corearch 读 v6：NOD 文件序 = 拓扑序（图创建序合法，先例注释）→ 线性指令流 = NOD 直出 + REG 边界插入（region 开始/结束标注，SG 段语义同 v5 消费方式）→ 现有 ELF 发射逻辑几乎不变（读段改走段表 + NOD 字段与 v5 instrs 同布局）。

## 5. 与 v5 差异总表

| 面 | v5 | v6 |
|---|---|---|
| version | 5 | 6（magic/扩展名/CLI 不动——方案 A） |
| 组织 | 定序段 | Header + 段表（tag/offset/size） |
| 指令 | instrs 28B 线性数组（主干） | NOD 28B 图事件 + 显式边表（与 ENT 并列，非唯一主干） |
| 坐标 | 指令序 | NOD id（图坐标，D1） |
| 变量 | vars 表 | ENT（变量 × 版本，含区间/home/flags） |
| region | sgs 24B（enter/exit 指令号） | REG 24B（enter/exit NOD id + 区内条目范围） |
| 共存 | 无 | 不落盘，sweep 推导（D3） |
| 执行序 | 文件即序 | corearch 从 NOD+REG 重建（文件序即拓扑序，D2） |
| 兼容 | — | v6-only，无转换工具 |

## 6. 消费方影响

- **corec（前端）**：lower 阶段产 NOD+REG（现 lower_to_ccr 坐标化）+ 条目重建（§4.1）→ save v6
- **corearch（后端）**：段表寻址 → 投影重建（§4.3）→ 发射；判定（分配器/一致性自检）消费 ENT（§4.2）
- **判定/证书**：共存/驱逐/证书是判定产物，独立于 .ccr（格形态之上），不落本文件
- **宽度标签**：不进入 v6（width-out-of-language；v5 格式本就无宽度字段，NOD tk 为类型码不变）

## 7. 开放点（实现期定夺）

1. NOD 边表是否必须（corearch 若只用文件序 + REG 即可发射，边仅供判定/未来 pass 消费——v6.0 可先省略，v6.1 按需引入；cir_cache 有完整先例）——**编码层问题，实现时定**
2. 变长记录编码（SYM 函数 param_ents 等）/ 对齐 / 校验规则——**编码层问题，Task 4 开工时定**（参照 cir_cache v13 先例；格层语义不依赖这些细节）
3. ENT home 由谁回填：分配器（corearch 内）原地改写 .ccr 还是内存态回填后另存——若 .ccr 只作 corec→corearch 传输，home 字段可为 -1 直通（判定在 corearch 内存态跑）
4. 段表预留 tag 6+（驱逐标注/证书段）不占空间，仅常量定义

## 8. 关联

- `docs/superpowers/plans/2026-09-05-lattice-ir-v6.md` — 实施计划（Task 4/5 依本设计）
- `docs/superpowers/specs/2026-08-27-lattice-form-ir-design.md` — 方向定稿（§4.2 的实质化）
- `docs/ir-schema/coreir-schema.md` — v5 schema（实现期更新为 v6）
- `docs/regalloc-cache-mapping.md` §四 — 判定四条（共存互斥/读点无陈旧/驱逐配对/调用失效）
