# 格形态 IR 设计：`.ccr` 升级为格形态（C 路线）

日期：2026-08-27
状态：方向定稿，已实质化实施（2026-09）。v6 格式与数据面已实施（`archive/2026-09-05-lattice-ir-v6-format.md` 格式定稿，`plans/2026-09-05-lattice-ir-v6.md` 实施计划 Task 1-5 完成：存在区间、条目版本化、共存推导、段表 IO、判定自检）。v5 到 v6 的一次性转换按定稿取消（`.ccr` 中间产物没有生态，只保留 v6）。关联：`docs/regalloc-cache-mapping.md`、`docs/memory-model-capability-lattice.md` v4。

> 当前格式见 [2026-09-09-lattice-ir-v7-format.md](../superpowers/specs/2026-09-09-lattice-ir-v7-format.md)。本文是 2026-08-27 的方向定稿，v6 已被 v7 到 v9 演进取代，保留作为设计历史。

## 1. 背景与动机

### 1.1 三层形态命名体系

三层映射正式确立后（图、格、编码，见 `docs/memory-model-capability-lattice.md` v4 第四节），IR 形态与之对应：

| 形态 | 层 | 格式 | 职责 |
|---|---|---|---|
| 图形态 | 图 = 关系空间 | `.cir`（HDFG） | 表示结构 |
| 格形态 | 格 = 存在空间 | `.ccr`（本设计对象） | 表示存在（状态/条目/共存/驱逐） |
| 编码形态 | 编码 = 物理编码空间 | ELF | 运行 |

### 1.2 `.ccr` 的名称与内容不一致

- 缩写：`.ccr` = Core Control-flow Representation（`docs/ir-schema/coreir-schema.md`），名称写的是 CFG。
- 内容：v5 格式已是 SG region 段（`sg_count × 24B`：kind/enter/exit/parent/nstart/ncount），内容已是区域结构（图固定的存在结构），不再是基本块控制流。
- 语义：CFG 将被格取代（正确性不再按 CFG 路径陈述，而是对全部可能执行成立），“控制流表示”的定位描述已经过时。

### 1.3 时机：程序生态规模小

格形态即将实施，当前 `.cr`/`.ccr` 程序生态规模很小。现在定案改名与格式升级，成本为 O(仓库)；以后定案，成本为 O(仓库 + 生态 + 产物/缓存)。C 路线把改名与格式升级合为一次迁移。

## 2. 定位

格形态是格层（存在空间）的表示格式：

- 条目（IR 变量版本，规则 5 版本化）、方法（产生节点）、存在区间（图活性）、共存（存在区间相交）、驱逐/再生（缓存语义规则 2/3）、无方法条目标注（图内不可重算，规则 4b）。
- 寄存器分配判定直接消费格形态（`docs/regalloc-cache-mapping.md` 第 4 节的一致性判定：共存互斥、读点无陈旧、驱逐配对、调用失效，这些判定以存在区间与共存为主机）。
- 与 `.cir`（图形态）的关系：图是结构表达（关系空间），格形态是存在表达（状态空间）。`lower_to_ccr()` 从图派生线性投影的机制保留，v6 在其上加入存在结构。

## 3. 命名决策

| 候选 | 方案 | 成本 |
|---|---|---|
| A（已定案） | 扩展名 `.ccr` 保留，缩写展开改为 Core Region Representation；格式 v6 内部升级 | 零生态成本：扩展名 / magic（`CCR1`）/ CLI / 文件路径全不动 |
| B | 新扩展名（`.rir` / `.cer` / `.exr`）加新 magic 加 CLI 子命令 | 全链改名（代码/测试/文档），与 v6 升级同一迁移批次 |

推荐 A：把改名（语义）与格式升级合为一次迁移，关键是扩展名不动，这样迁移面最小；region 一词准确反映 v5 已实施的 SG region 段与图固定的存在结构。若未来需要显式区分格形态与线性投影两种格式，届时再引入 B 即可。

已定案（2026-08-27 确定）：方案 A。扩展名 `.ccr` 保留，缩写展开为 Core Region Representation；扩展名、magic（`CCR1`）、CLI、文件路径全不动，零生态成本。

## 4. 格式设计方向（v6）

### 4.1 现状（v5）

- 指令数组（28B/条：opcode/dest/src1-3/type_kind）、变量表、字符串表、全局段
- SG region 段（24B/条：kind/enter/exit/parent/nstart/ncount），区域结构已实施
- DFEdge 不落盘（仅在内存与 `.cir` 缓存中）

### 4.2 v6 增量（存在结构段）

不做格式兼容：v6 与 v5 的数学结构有较大变化（线性程序改为存在结构）。条目、存在区间、共存、驱逐无法通过追加段表达（v4 到 v5 的 SG 段只是尾部超集扩展，先例不适用）。提供 v5 到 v6 的一次性转换（从线性投影重建存在结构：图活性推导加版本化重建），程序生态规模小时转换成本最低：

1. 条目版本段：版本化条目（变量 × 版本）得到存在区间 [start, end]（图活性，RegionCheck 语义）
2. 共存关系：存在区间相交的显式标注，或推导规则（从图活性派生，避免冗余存储）
3. home 标注：条目持久位置（栈槽）声明
4. 无方法条目标记：边界加图内不可重算（规则 4b），作为“必须有 home、驱逐必写回”规则的输入
5. 驱逐/填充点（可选，v6.1）：spill/load 插入位置的标注

### 4.3 与分配判定的接口

- 判定（`regalloc-cache-mapping.md` 第 4 节四条）消费：存在区间、共存、home、无方法标记
- 证书挂载位置：分配结果（映射）与判定规约（.corespec）挂在格形态之上
- 实现顺序：存在结构段，判定消费，贪心放置（`opt.cr` 升级）

## 5. 迁移路线（一次迁移）

执行人：第二维护者（TODO 横向扩展）；验证完整流程：DslsDZC。全部事项已列入 `TODO.md`：

1. 命名定案（第 3 节决策点）
2. 格式 v6 序列化/反序列化（`ccr_io.cr` save/load）加 v5 到 v6 一次性转换工具（不承诺后向兼容）
3. ELF 后端适配（`src/arch/linux/ld/`）
4. CLI / `corearch` 参数（若走方案 B：扩展名/子命令/magic）
5. 自举管线（`build_selfhost_native.py`、`bootstrap/corec/ir/ccr.py`）
6. 测试迁移（`tests/selfhost/`、`tests/bootstrap/`）
7. 文档同步（`coreir-schema.md` / `CLAUDE.md` / `project-book.md` / `compcert-reference.md`，本文档已先行更新描述，执行阶段复核）
8. 寄存器分配判定接入格形态（消费存在区间和共存，加贪心放置）

## 6. 范围边界（YAGNI）

- 不做 `.cir` 改名（图形态不变）
- 不做 ELF 改名（编码形态不变）
- 本会话不做任何代码改动（执行交由第二维护者）
- 做：命名定案、格式 v6 设计细化、迁移清单（写入 `TODO.md`）

## 7. 验收标准

- 格式 v6 可序列化/反序列化（自身完整流程，不承诺 v5 后向兼容，数学结构变化较大）
- v5 到 v6 的一次性转换工具（程序生态规模小时进行，不承诺双向兼容）
- 存在结构段携带：条目版本、存在区间、共存、home、无方法标记
- 分配判定直接从格形态消费（无 CFG 路径结构）
- 命名体系三种形态一致：图 = `.cir` / 格 = `.ccr`（或定案名）/ 编码 = ELF
- 文档与实现一致（执行阶段复核）

## 8. 关联

- `docs/regalloc-cache-mapping.md`：分配是缓存语义映射的实例；第 4 节判定消费格形态
- `docs/memory-model-capability-lattice.md` v4：三层映射（图、格、编码）；规则 4b（图内不可重算）；规则封闭、对象开放
- `docs/memory-model.md` 第一节：缓存语义七条加规则 4b
- `docs/ir-schema/coreir-schema.md`：`.ccr` 格式 schema（v6 实施时更新）
- `docs/maintainer/design/execution-annotation-space.md`：执行标注空间
- `TODO.md`：全部执行事项
