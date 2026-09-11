# 存在结构:v6 格形态 IR 的语义承载(ENT/NOD/REG)

> 定位:受众 = 维护者(ccr_io/分配器/验证器实现者);状态 = active(设计定稿,实现推进中)。
> 本文件从**语义视角**讲 v6 存在结构——七条缓存语义条款(权威 = docs/academic/cache-semantics.md)如何在 .ccr 中落成 IR 一等结构;字节级布局(段表/字段宽/对齐)的最终规格在 docs/ir-schema/coreir-schema.md(实现期并入),格式设计草案与实施状态以 docs/superpowers/specs/2026-09-05-lattice-ir-v6-format.md 与实施计划为准。
> 决策:adr/adr-0002(.ccr v6 段表架构)。

---

## 一、设计原则(v6 与 v5 的分野)

1. **存在为主体,执行为投影**:v5 文件描述"按什么顺序执行什么"(线性指令数组);v6 描述"什么存在(条目 × 版本)、存在多久(区间)、由什么产生(配方)、嵌套在哪(region)"——执行序是可重建的投影,不再是文件主干。
2. **图节点坐标(D1)**:存在区间端点、region 边界、条目定值点全部以 NOD id(图节点序)为坐标——与 .cir(图形态)同坐标系,兑现"图 = 唯一真相层"。
3. **执行序重建(D2)**:corearch 从 NOD + REG 重建线性投影——图节点文件序即合法拓扑序,重建 = 文件序直出 + region 边界标注,无排序成本。
4. **共存不落盘(D3)**:判定消费时从存在区间推导,sweep O(n log n),不超线性、不冗余存储。
5. **v6-only**:不兼容 v5、无转换工具(.ccr 为管线中间产物,零持久生态)。
6. **格层 vs 编码层**:ENT/NOD/REG 的语义(条目数学结构/版本/区间/共存)属格层,范式无关;字节宽/段表布局是编码层投影,可按编码空间调整。

---

## 二、段总览

| 段 | 内容 | 语义层角色 |
|---|---|---|
| STR | 字符串表 | 符号名的字节投影 |
| SYM | 符号表(函数/全局/结构/枚举,v5 func_meta 等归并) | 函数记录带 root_region 与 first_ent/last_ent |
| NOD | 节点表 = 图事件(v5 instrs 图坐标化)+ 显式边表 | **配方** |
| ENT | 条目表(v6 新增,存在结构核心) | **条目**:位置 + 配方 + 存在 |
| REG | region 表(SG 嵌套,坐标升级) | 存在区间锚定 |

变量(局部)不入 SYM——由 ENT 全量携带(存在即声明)。

---

## 三、ENT:条目表

ENT 记录字段与缓存条款的对应:

| 字段 | 语义 | 条款 |
|---|---|---|
| var_id | 变量 id(NOD dest/srcs 同命名空间;-1 = 匿名常量条目) | 条款 6(条目坐标) |
| version | 该变量第几版(1-based;每次定值 +1) | 条款 5(赋值 = 版本化) |
| def_nod | 定值节点 id(-1 = 函数参数/全局) | 条款 1/4(无配方) |
| live_start / live_end | 存在区间(NOD id);live_end 开区间(最后使用点 +1) | 条款 2 的量化基础 |
| home | 槽位(分配器回填;-1 = 未分配/寄存器候选) | 条款 4b + 条款 7 的接口 |
| flags | bit0 无配方 / bit1 参数 / bit2 全局 / bit3 驱逐候选(v6.1) | 条款 4b / 条款 2 |

### 版本化切分(条款 5 的落盘规则)

Core IR 非 SSA——变量每次定值切分一个新版本条目,相邻版本存在区间按定值点切割(版本 k 区间终点 = 版本 k+1 定值点)。

定值点收集规则:扫 NOD,dest ≥ 0 的节点 = 该变量的定值点,两处 carve-out(GC 批 2 勘定):
- IR_STORE 单列:定值目标在 s1(ρ(s1):=ρ(s2)),dest 恒 -1——不走 dest 列
- 三 op 排除:STORE_INDEX_VAR/STORE_PTR/DYN_DISPATCH 的 dest ≥ 0 **非**定值(值 = 被存值源/基址标注/占位)

参数/全局条目:def_nod = -1,区间 = [函数首节点, last_ref+1)。

### 无配方条目(条款 4/4b)

ENT flags bit0 = 无配方(图内不可重算)——必须有 home。匿名常量条目(var_id = -1)仅当被判定消费时物化,否则常量内联于 NOD src1——避免条目爆炸。

---

## 四、NOD:配方(图事件)

- NOD 的 dest/srcs 语义与 v5 instrs 相同(引用 vars 表变量 id)——corearch 指令发射逻辑最小改动
- v6 新增**显式边表**(from_nod/to_nod/kind):kind = 数据/state 边(.cir 语义落盘;v5 边不落盘)
  - state 边(kind=1)两条来源:副作用链(STORE 族/非纯 CALL 按序连边)+ 循环终止依赖(见 execution-model.md §二)
- 坐标约定:NOD id = 文件序索引——图节点坐标,存在区间端点直接引用

---

## 五、REG:存在区间锚定

REG 记录 = v5 sgs 坐标升级:

| 字段 | 语义 |
|---|---|
| kind | SG_IF/LOOP/FOR/FLOW/UNSAFE/FUNC |
| parent | 父 region id(-1 = 根) |
| enter_nod / exit_nod | 入口/出口节点(NOD id) |
| first_ent / last_ent | 区内条目范围(-1 = 无) |

REG 的 first_ent/last_ent 使"子图边界 = 存在域边界"成为直接查询——图锚定区域内存模型(region-model.md)的语义锚点:区域生命周期由 region 的存在结构推导,而非词法作用域。

---

## 六、共存判定:不落盘,sweep 推导

`entries_coexist` 不逐对枚举(消费侧现算):

1. 按 live_start 排序条目(O(n log n))
2. 单遍扫描:维护活跃条目集(start < 当前点 ≤ end 的条目);新条目进入时,与活跃集中 end > start 的条目即共存——按 end 排序的活跃集弹出(end ≤ start 移出)
3. 判定四条消费此关系(共存互斥等:同 home 组内做 2 的扫描,O(k log k) per 组)

共存 = 对称、无传递性(最弱理论——最多模型)。无需输出全量共存表——判定四条都是存在性/∀ 检查,sweep 给出相交证据即止。

---

## 七、与 v5 差异与消费方影响

| 面 | v5 | v6 |
|---|---|---|
| 组织 | 定序段 | Header + 段表(tag/offset/size) |
| 指令 | instrs 线性数组(主干) | NOD 图事件 + 显式边表(与 ENT 并列) |
| 坐标 | 指令序 | NOD id(图坐标) |
| 变量 | vars 表 | ENT(变量 × 版本,含区间/home/flags) |
| region | sgs(enter/exit 指令号) | REG(enter/exit NOD id + 区内条目范围) |
| 共存 | 无 | 不落盘,sweep 推导 |
| 兼容 | — | v6-only,无转换工具 |

消费方:corec 前端产 NOD+REG + 条目重建;corearch 段表寻址 → 投影重建 → 发射;判定(分配器/一致性自检)消费 ENT;证书等判定产物独立于 .ccr,不落本文件。

---

## 八、开放点(实现期定夺,以实施计划为准)

1. NOD 显式边表是否必须(v6.0 可省略,v6.1 按需)——编码层问题
2. 变长记录/对齐/校验规则——编码层问题
3. ENT home 回填方式(原地改写 vs 内存态)
4. 预留段 tag 6+(驱逐标注段 v6.1、证书段)

---

## 九、关联

- 条款权威:docs/academic/cache-semantics.md(七条)
- 格式字节级:docs/superpowers/specs/2026-09-05-lattice-ir-v6-format.md(设计定稿)
- 方向:docs/superpowers/specs/2026-08-27-lattice-form-ir-design.md
- 决策:docs/maintainer/adr/adr-0002-ccr-v6-segment-table.md
- 实施:docs/superpowers/plans/2026-09-05-lattice-ir-v6.md(状态以此为准)
- 分配器判定:docs/maintainer/design/regalloc-cache-mapping.md(判定四条消费共存)
