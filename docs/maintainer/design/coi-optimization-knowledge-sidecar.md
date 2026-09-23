# Core Optimization Information（`.coi`）——优化知识旁挂格式（正式规格）

> 定位：受众 = 维护者 / `corec` · `corearch` · 优化器 · 验证器 · 打包者实现者；
> 状态 = **设计定稿（未实现）**——全文除显式标注 `[已实现]` 处外，**均无仓库对应物**。
>
> 设计意图真源 = **一份**维护者 2026-09-23 会话口述输入（**逐字，本文不改写它**）：
> - `/tmp/briefs/coi-raw.md` —— 22 节原文。本文 = 其**形式化展开 + 仓库锚定 + 不变量判据化 + 开放问题收口**。
>
> **核验基线 = `develop@origin` @ `0eb1efd3`**（`jj git fetch` 后实读）。本文一切 `file:line`
> **以该修订为准，非手边检出**——本仓多工作区并行，每个 `@` 都可能落后，而**落后检出与「上一代值」
> 逐字节相同，看不出异常**。故本文的锚点一律经 `jj file show -r develop@origin <path>` 取得。
> ✅ 附带事实：V8 规格档声明的核验基线**同为 `0eb1efd3`**（其头部自述），故本文对 C-10 的交叉引用行号与它自洽。
>
> 读本文须区分**三种声音**：
> ① **原文**（维护者原话——带引号或标「原文 §n」）；
> ② **本文展开**（写手的形式化/推导/建议——标「本文展开」）；
> ③ **现状实核**（带 `file:line` 或实测口径）。
> **三者不得混读**——尤其不得把 ② 读成 ①，不得把 ② 读成现状。
>
> 关联：
> - **格式同族**：[ccr-v8-open-relational-lattice.md](ccr-v8-open-relational-lattice.md)（V8 规格，**未推**；
>   本文 §〇.1 与 §三.4 处置其 C-10）· [2026-09-09-lattice-ir-v7-format.md](../../superpowers/specs/2026-09-09-lattice-ir-v7-format.md)
>   （现行 `.ccr` 段表设计定稿；其「开放点 3」正是本文的立论对象，见 §三.3）
> - **爆炸半径**：[2026-09-22-ccr-v8-blast-radius.md](../../superpowers/specs/2026-09-22-ccr-v8-blast-radius.md)（**未推**）
> - ⚠ **最需划界的一份**：[execution-mapping-design.md](execution-mapping-design.md)（**已合入 `develop`**）——
>   那份管**计算 → 执行域的放置**（`ExecutionDomain` / `CapabilityDomain` / `PerformanceProfile` / `RuntimeState`）；
>   本文管**优化知识的承载与失效**。**两者都出现「域」「能力」「代价」，但对象不同**——逐条划界见 §五 与 §〇.2。
> - **最紧的兄弟 spec**：[2026-09-11-performance-without-commitment-design.md](../../superpowers/specs/2026-09-11-performance-without-commitment-design.md)
>   （S-C，**已合入**）——S-C 的论题「性能决策 = 映射实例的选择，不是程序的一部分」与本文同构；
>   **本文 = 该论题在「知识承载面」上的实现格式**。S-C 的成本模型接口（`cost_model_query`）与本文 §十三 是同一件事的两面。
> - **旁挂先例**：[`src/compiler/cir_cache.cr`](../../../src/compiler/cir_cache.cr)（`.cir` 函数级快照缓存）
>   ——其**版本策略/身份闸/失效策略**是本文 §九 的直接借鉴对象与**负面前例**来源。
>
> ### 三态标注约定（全文强制）
>
> 本文凡陈述「仓库现在有什么」的句子，**逐句**带下列标记之一：
>
> | 标记 | 含义 | 举证义务 |
> |---|---|---|
> | `[已实现]` | 核验基线上**有实现** | **必须给 `file:line`**（本会话在 `develop@origin` 上实核，非记忆、非就地 grep） |
> | `[已设计未实现]` | 仓库有设计文档/规划但**无实现** | 必须给出处文件 |
> | `[提案]` | 本文新提出，仓库**无对应物** | 无（**默认档**） |
>
> ⚠ **默认必须是 `[提案]`**：核不到行号的句子一律**不得**标前两档。
> ⚠ **本文的主体是 `[提案]`**——实测依据：全仓 `grep -i '\.coi\b'`（`*.cr`/`*.md`/`*.py`/`*.sh`）= **0 行**，
> 即 `.coi` 在本仓**零对应物**。⇒ **不得把本文的任何设计条目读成现状**。
> 显式标记仅用于**锚点句**；**未被标记的设计陈述一律按 `[提案]` 读**。
> 三态计数见 §附录 A。

---

## ⭐ 关键现状（一屏速览——本文的立论硬支撑）

> 这三条是本文全部论证的地基。**读本文前先读这一屏**。全部在 `develop@origin` @ `0eb1efd3` 实核。

### K-1 `.ccr` 的 `opt_meta` 子节是**版本化的空壳载体**（`[已实现]` + 实测）

- `.ccr` 的 **SYM 段第 6 子节**承载 `g_opt_meta`（`src/compiler/ccr_io.cr:749` 写 / `:1269` 读），
  键表在 `src/compiler/ast.cr:659-663`，声明在 `src/compiler/globals.cr:378`。
- **产物实测**：**1872 个 `ver=9` 的 `.ccr` 产物**（口径：glob `build/**/*.ccr` + `/tmp/**/*.ccr`，按头 `magic==827474755 && version==9` 筛选，脚本自行走 SYM 子节序；mtime 2026-09-15…09-22）
  **`opt_count` 全部为 0**，且 SYM 段走查 `tail` 全 0（1872/1872，解析自洽）。
- **两条独立证据**：
  1. **写侧清单**——唯一写入者是 `src/arch/x86_64/regalloc.cr`，而它在 `backend_support_files`（`build_selfhost_native.py:65`）、
     **不在 `corec_files`（`:311-374`）** ⇒ **corec 写 `.ccr` 时 `g_opt_meta_count == 0`**；
  2. **产物实测**——上条所载的 1872/1872。
- ⇒ **含义**：该子节**占了格式位置、参与 load 校验、名字叫 metadata**，但在 corec→corearch 的传输上
  **不携带任何信息**——一个**静默的**位置。详 §三.1。

### K-2 现行教义已声明「分配决策不写回格式」，而 `g_opt_meta` 恰是分配决策的落盘载体

- 教义 `[已实现]`：`ccr_io.cr:84`「`home` 恒 -1（实例注记——**分配决策不写回格式**）」；
  v7 规格 `:106` / `:183` / `:200` 同结论。
- 事实 `[已实现]`：`OPT_KEY_REG_ASSIGN`（`var_idx → 物理寄存器`）**就是分配决策**，而它**就在 `.ccr` 里**。
- ⇒ **自相矛盾**；且 v7 规格的「**开放点 3**」原文留着「未来实例层选择写回（**非传输中间物用途**）时重议」
  ⇒ 本文主张 **`.coi` 就是那个用途**（⚠ 该读法是**本文展开**，非维护者原话——见 §二十五 U9）。详 §三.3。

### K-3 `.coi` 在本仓**零对应物**

- 全仓 `grep -i '\.coi\b'`（`*.cr`/`*.md`/`*.py`/`*.sh`）= **0 行**。
- ⇒ **本文主体全为 `[提案]`**；**不得把本文的任何设计条目读成现状**。

---

## 〇、术语护栏（开工前必须钉死）

本文与既有文档存在**四处同名不同义**。不钉死则后续所有讨论串线。

### 〇.1 `metadata`——⚠ 与 V8 规格的 C-10 **是同一个冲突**

| 词 | 本文的义 | 仓库既有物 | 处置 |
|---|---|---|---|
| **metadata**（V8 义） | V8 的 **relation 元数据**（`producer` / `epoch` / `evidence_ref`），不进 relation 的数学含义 | 无实现（V8 未落地） | 本文写「**relation metadata**」 |
| **metadata**（现行义） | **优化参数袋** = `g_opt_meta` | `[已实现]`：声明 `src/compiler/globals.cr:378`（注释原文 `metadata buffer for .ccr v3+`）、节注 `:376`、计数/容量 `:379`；键表 `src/compiler/ast.cr:659-663`；承载 = **SYM 段第 6 子节**（写点 `src/compiler/ccr_io.cr:749`、读点 `:1269`） | 本文一律写 **`g_opt_meta` / opt_meta 子节**，**不写裸「metadata」** |

**V8 规格 §九 C-10 原文**：「`metadata` 与现行 `g_opt_meta` **同名不同物**（且同处一个 `.ccr` 内）」；
其「我的核实结论 3」给的是**建议**：「V8 侧的对外名称至少加限定（如 `relation metadata` / `relations.metadata`），
或在承载面决策时一并改名」。

> ⚠ **同步（2026-09-23）——上引那条建议已被 V8 规格档撤回**：
> 该档自 **`dc19982b`** 起已把 C-10 的处置**改向**——**不再走「V8 侧改名」**，
> 改为「**等 `.coi` 把 `opt_meta` 整节搬出 `.ccr`**」。
> **撤回理由**：**改名与搬迁同时做，会在迁移期引入第三种叫法**。
> ⇒ **仅「V8 侧那条建议」作废**；**下文「本文展开——`.coi` 如何消解 C-10」的结论不受影响**
> （它本来就是根因级处置），**本档实质内容无需改动**。
> 出处：`docs/maintainer/design/ccr-v8-open-relational-lattice.md` §九 C-10 第 5 点（该档自 `dc19982b` 起）。

> 📌 **本文展开——`.coi` 如何消解 C-10**：
> C-10 的根因不是「两个东西都叫 metadata」，而是**优化参数袋**这个异物**寄居在 `.ccr` 里**——
> 只要它还在 `.ccr` 内，无论怎么改名，`.ccr` 里就永远有两个「元数据」概念需要靠限定词区分。
> **`.coi` 把 opt_meta 整节搬出 `.ccr` 之后，C-10 从「改名问题」降级为「不存在问题」**：
> `.ccr` 里只剩 relation metadata 一个候选者，「metadata」一词在 `.ccr` 语境下**恢复无歧义**。
> ⇒ **本格式是对 C-10 的根因级处置，不是又一个规避方案。** 搬迁的字节面代价见 §三.3。

### 〇.2 「域」「能力」「代价」——与执行映射设计的划界

| 词 | 本文的义 | `execution-mapping-design.md` 的义 | 处置 |
|---|---|---|---|
| **域 / domain** | ⚠ **本文不用此词**。本文只有「**优化域**」（§六：generic / target-specific），且明说它不是执行域 | **ExecutionDomain** = 计算→执行域的放置单位（`gpu0` 等）；**RelationDomain** = V8 的关系域 | 本文写「**优化域（generic / target-specific）**」，**永不写裸「域」** |
| **能力 / capability** | 本文只**引用**能力名（目标谓词的词汇，§十一），**不定义**它们 | **CapabilityDomain**（§3.7）+ **能力格**（§四） | 本文写「**能力谓词**」（引用位）；定义真源归 §19 #10 指名的硬件模型面 |
| **代价 / cost** | `.coi` 记录的**代价缓存**（带 `model_id` / `model_ver` 溯源） | **PerformanceProfile**（§3.8）+ §5.2 **Cost Model** + S-D 的 `cost_model_query` | 本文写「**代价记录**」（缓存位）；模型真源归 S-D，见 §十三 |

> 📌 **本文展开——为什么必须划这条线**：原文 §19 第 10/11 条**明确把硬件能力模型与运行时机器状态排除在 `.coi` 之外**。
> 而「目标特定优化信息」（原文 §3.2）又**必须**引用 ISA、微架构、加速器家族。⇒ 唯一自洽的读法是：
> **`.coi` 存的是「在该目标上如何优化」的知识，不是「该目标是什么」的知识**。
> 前者随时间累积、可丢弃、可重算；后者是硬件侧的真源，进 HIT / hw-map / `CapabilityDomain`。
> 越界即制造第二真源——本仓反复治过的病。

### 〇.3 「缓存 / 格」——本文的用法

- **缓存**：本文用**日常工程义**（「装载 `.coi` = 跳过重算」）。⚠ 既有的**教义义**
  （`docs/academic/cache-semantics.md` 条款 1–7：存在格的一类映射实例规律）**与本文无关**，
  本文不引用也不修改它们。凡需指教义处写全称「**缓存语义条款**」。
- **格 / Lattice**：本文**不使用**。`.coi` 不含格承诺（V8 §三 3.4 已把「格」移出 Core 要求）。

### 〇.4 「target / 目标」——一处必须钉的歧义

原文 §3.2 的 `target` 指**硬件目标**（ISA / 微架构 / 加速器）；原文 §12 的
`Target Section` / `TargetDescriptor` 同理。⚠ 本仓另有一个 **target triple** 用法
（`src/targets/x86_64-linux/` = **组合根目录**，`[已实现]`）。
⇒ 本文写「**硬件目标**（hardware target）」以示区分，**不写裸 `target` 指目录**。

---

## 一、目的与中心律（原文 §1）

### 1.1 原文的三分对照（**逐字保留**）

原文 §1：

```
.ccr:
    - stores target-independent program relations;
    - must remain applicable to any hardware;
    - is part of the long-term distributed representation.

.coi:
    - stores reusable optimization knowledge;
    - may contain both target-independent and target-specific information;
    - may be discarded at any time;
    - may be regenerated from .cir/.ccr and analysis;
    - must never be required for semantic correctness.
```

原文 §1 的定位行：「`.coi` MUST NOT replace `.ccr`.」

### 1.2 中心律（**本文的立论基石**）

原文 §1：

```
removing every .coi file must never make the program incorrect or unreadable;
it may only increase compilation cost or reduce optimization quality.
```

> 📌 **本文展开——中心律的判据化**：这句话**不是**一句愿景，它是一条**可机械检查的不变量**。
> 它的判据形状必须**两向**：
> - **正向**（移除无害）：删除全部 `.coi` ⇒ 编译 rc=0 **且** 产物（ELF + `.ccr`）**逐字节相同**；
> - **反向**（移除有代价但不致命）：存在至少一条记录，装载时使某可测工作量计数**下降**。
> ⚠ 只有正向没有反向 ⇒ 判据对「`.coi` 根本没被读」恒绿（**空壳绿**）；
> 只有反向没有正向 ⇒ 判据对「`.coi` 影响语义」恒绿。**两向缺一不可**。判据形状详式见 §四 #3/#4 与 §二十二。

---

## 二、管线位置（原文 §2）与现状核对

### 2.1 原文的管线图（**逐字保留**）

```
Source
  |
  v
.cir
  |
  +----------------------+
  |                      |
  v                      v
.ccr                   .coi
relations              optimization knowledge
  |                      |
  +----------+-----------+
             |
             v
    reconstruct / load .cir
             |
      target model + profile
             |
             v
         optimizer
             |
             v
         backend
             |
             v
         encoding
```

原文 §2 的两条依赖声明：

```
Dependency direction:  .coi -> .ccr/.cir
Forbidden direction:   .ccr -> required .coi
```

### 2.2 ⚠ 与现状的核对（**本文实核，含一处必须说明的偏差**）

| 图中元素 | 现状 | 判定 |
|---|---|---|
| `Source` → 图层（`.cir` 语义位） | `[已实现]`：lexer → parser → checker → ir_gen → dataflow 构 HDFG | ✅ 一致 |
| `.ccr` = relations 的承载 | `[已实现]`：`src/compiler/ccr_io.cr`；段表 8 段（§三.2） | ✅ 一致 |
| `.ccr` → `backend` → `encoding` | `[已实现]`：`corec` 产 `.ccr` ⇒ `corearch` 读 `.ccr` ⇒ ELF 发射 | ✅ 一致 |
| **`.cir` 在图中位于 `.ccr` 之前** | ⚠ **需区分两个「`.cir`」** | ⚠ 见下 |
| `target model + profile` | `[已设计未实现]`：`execution-mapping-design.md` §3.8/§3.9；HIT 表 `[已实现]`（表机制面） | ⚠ 见 §〇.2 |
| `.coi` | **零命中**（实测：全仓 `grep -i '\.coi\b'` 于 `*.cr`/`*.md`/`*.py`/`*.sh` = **0 行**） | `[提案]` |

> ⚠ **`.cir` 的两个义（本文展开，必读）**：
> 1. **图层**（原文 §2 图里的 `.cir`，语义位）= 数据流图形态的 IR。此义下「位于 `.ccr` 之前」**成立**——
>    `.ccr` 正是由图层导出的（`[已实现]`：NOD/EDG/REG/ENT 段的落盘源 = 内存 HDFG 表）。
> 2. **物理文件**（`.core/cache/cir/*.cir`）`[已实现]`：`src/compiler/cir_cache.cr` 的**函数级增量快照缓存**，
>    目录由 `cir_cache.cr:890-896`（`mkdir` syscall 83）创建，路径 **相对 cwd**（`main.cr:528`），
>    清理入口 `main.cr:417`（`rm -rf .core/cache/cir/`）。
>    ⇒ **此义下 `.cir` 不是分发产物、不是管线级产物，而是编译器本地缓存**；它与 `.ccr` **不并列**。
>
> ⇒ **读原文 §2 图时**：把 `.cir` 读作**义 1**（图层）方与现状自洽。
> ⚠ 但原文 §15 的**分发包**（`program.ccr` [+ `program.coi`] [+ profile]）里**没有 `.cir`**——
> 这与义 2（本地缓存）一致，与义 1（图层）不冲突但也不明说。**本文按「`.cir` 不入分发包」读**，
> 与 §15 逐字一致；此读法**未经维护者确认**，列入 §二十五 未核实清单。

---

## 三、【现状锚点】实核

> 本节回答「`.coi` 要搬的东西今天长什么样」。**§三.1 是全文最重要的现状**。

### 3.1 `g_opt_meta`——今天承载「优化元数据」的东西

**声明与键表** `[已实现]`：

| 项 | 位置 | 内容 |
|---|---|---|
| 节注 | `src/compiler/globals.cr:376` | `// Optimization levels and metadata (extensible key-value store)` |
| 缓冲声明 | `src/compiler/globals.cr:378` | `g_opt_meta : string, mut;` + 注释 `metadata buffer for .ccr v3+` |
| 计数/容量 | `src/compiler/globals.cr:379` | `g_opt_meta_count` / `g_opt_meta_cap` |
| 键常数 | `src/compiler/ast.cr:659-663` | `OPT_KEY_REG_ASSIGN = 0` · `OPT_META_STRIDE = 64` · `OPT_KEY_STACK_SHARE = 1` · `OPT_KEY_CSE = 2` |
| 分配器 | `src/compiler/dyn_arr.cr:1090` | `fn grow_opt_meta(needed: int)` |

**承载面** `[已实现]`——`.ccr` 的 **SYM 段第 6 子节**：

- 子节序（`src/compiler/ccr_io.cr:25` 头注原文）：
  `globals → funcs → str_consts → structs → enums → opt_meta`
- 盘上记录（`ccr_io.cr:749-766` 写侧 / `:1269-1292` 读侧）：
  `[opt_count u32][opt_count × {key u32, len u32, data lenB}]`
- 内存态步长 = `OPT_META_STRIDE = 64`B（头 8B = `{key u32, len u32}` + 数据 ≤56B ⇒ 每块 ≤5 个寄存器对）
- 读侧上界闸 `[已实现]`：`ccr_io.cr:1278` `if md_len > OPT_META_STRIDE - 8 || !ccr_has_bytes(...) { return -1; }`

**谁写 / 谁读** `[已实现]`（实测口径，见下）：

| 角色 | 位置 | 说明 |
|---|---|---|
| **写**（唯一） | `src/arch/x86_64/regalloc.cr` | **26 行**（口径：匹配式 `w32\(g_opt_meta\|w64\(g_opt_meta\|store8\(g_opt_meta` · 单位 = **行** · 范围 = 后端三轴；`instr.cr`/`corearch.cr` 均为 0 ⇒ 二者**纯读**）。`alloc_registers()` 阶段 5 终分配（`regalloc.cr:768-824`）+ 注入钩子（`:199-215`） |
| **写**（装载侧） | `src/compiler/ccr_io.cr` | load 时从 `.ccr` 重建（`:1269-1292`） |
| **读** | `src/arch/x86_64/instr.cr:34` `fn get_reg_for_var` | 发射面消费（`g2_slot` 路径） |
| **读** | `src/compiler/corearch.cr:186-201`（`--dump-regassign`）· `:210`（`--check-regalloc` 看门狗） | 诊断/测试通道 |

**单元归属** `[已实现]`（`build_selfhost_native.py`）：

- `src/arch/x86_64/regalloc.cr` 在 **`backend_support_files`**（`:65`），
  而 `corearch_files = common + hit_engine + kernel + arch_x86_64 + format_elf + os_linux + backend_support`（`:388-390`）；
- **`corec_files`（`:311-374`）不含 `regalloc.cr`**，也不含 `instr.cr`。
  （`corec_files` 含 `src/lattice/ent_kernel.cr`——即**内核在 corec，x86 实例不在**。）

> 📌 **本文实测结论（核心）**：`.ccr` 的 opt_meta 子节**在实际上永远是空的**。
> 证据链两级：
> 1. **写侧清单**：唯一写入者是 `regalloc.cr`，而它**不在 corec 清单**⇒ corec 写 `.ccr` 时 `g_opt_meta_count == 0`。
> 2. **产物实测**：扫描 1872 个 `ver=9` 的 `.ccr` 产物（`build/` 与 `/tmp`，mtime 2026-09-15 … 2026-09-22），
>    **`opt_count` 全部为 0**；且 SYM 段走查 `tail = 0`（1872/1872，解析自洽 ⇒ 非解析错位造成的假读）。
>
> ⇒ **结论**：SYM 段第 6 子节今天是一个**版本化了的空壳载体**——它占了格式位置、参与了校验、
> 但在 corec→corearch 的传输上**不携带任何信息**。
>
> #### ⚠ 口径表（**每个数都要带「怎么数的」**——本仓纪律）
>
> `g_opt_meta` 的枚举计数随细看只会变多。下表把**数法**与**数**并列——**脱离数法的计数不得引用**。

| 数法（**匹配式 · 单位 · 文件范围**） | 数 | 逐档分解 |
|---|---|---|
| **行数**：`grep -c 'g_opt_meta'` · 行 · 全仓 `*.cr` | **97** | `regalloc.cr` 54 · `ccr_io.cr` 12 · `ent_kernel.cr` 10 · `instr.cr` 7 · `corearch.cr` 6 · `dyn_arr.cr` 4 · `regalloc-consistency.cr` 2 · `globals.cr` 2 |
| **行数**：同上 · 行 · 后端三轴（`src/arch/*` + `src/compiler/corearch.cr`） | **67** | `regalloc.cr` 54 · `instr.cr` 7 · `corearch.cr` 6 |
| **读侧表达式（按行）**：`r32\(g_opt_meta\|r64\(g_opt_meta\|load8\(g_opt_meta` · 行 · 后端三轴 | **18** | `regalloc.cr` 10 · `instr.cr` 4 · `corearch.cr` 4 |
| **读侧表达式（按出现次数）**：同上匹配式 · 出现次数 · 后端三轴 | **19** | `regalloc.cr` 11 · `instr.cr` 4 · `corearch.cr` 4（一行可含 2 次 ⇒ 与「按行」不同） |
| **写侧表达式（按行）**：`w32\(g_opt_meta\|w64\(g_opt_meta\|store8\(g_opt_meta` · 行 · 后端三轴 | **26** | 全在 `regalloc.cr`（`instr.cr`/`corearch.cr` = **0** ⇒ 二者**纯读**） |
| **三档行数和**：`grep -c` · 行 · `regalloc.cr` + `instr.cr` + `ent_kernel.cr` | **71** | 54 + 7 + 10 |

> ⚠ **两处更正（本文自查，2026-09-23）**：
> 1. **本文先前报的「全仓 93 行」是算错**——本文自己打印的逐档数（54+12+10+7+6+4+2+2）**和就是 97**。
>    ⇒ 正确值 = **97**（与转述方一致）。**不是文件范围差异，是加法错误**。
> 2. **转述方的「71 处直读」**：其数**可复现**，但复现出来的数法是
>    **「`regalloc.cr` + `instr.cr` + `ent_kernel.cr` 三档含 `g_opt_meta` 的**行数**之和」**（54+7+10）。
>    ⚠ 两点必须写清：① 它**不是**「读侧表达式」——按行数读侧表达式 = 18，按出现次数 = 19；
>    ② 其中 `ent_kernel.cr` 的 **10 行全部是注释**（实测：该档读侧/写侧表达式均为 **0**）
>    ⇒ 这 10 行**不构成任何读点**。
>    ⇒ **结论：71 = 「三档行数和」（一个真实、可复现的量），但它的名字不该叫「读侧表达式」。**
>    **两处都不改数、只改数法**——上表即最终口径。
> ⇒ **本文此后一律用上表的数法引用**，不再写「N 处直读」这类**无口径**的说法。
>
> #### 📌 由此定下的两条纪律（**引用任何计数前先过这两条**）
>
> 1. **脱离数法的计数不得引用**——「N 处」「M 行」若不带匹配式/单位/文件范围，**一律不得引用**。
> 2. ⭐ **标签必须能被匹配式复现**——做不到就**只写匹配式、不起名字**。
>
> **第 2 条的理由就是本表第 6 行这个实例**：`71` 本身**没数错**，但它被起了「**读侧表达式**」这个名字之后，
> 一个**行数和**就变成了一个关于「**读取强度**」的主张（并据此被转述为「后端大量读取」）。
> **错名比错数更坏**——错数会被对拍发现，错名会**逃过一切数学校验**，因为它不对应任何匹配式。
> ⇒ 本表第 6 行**保留「三档行数和」这个能复现的名字**，**丢弃「读侧表达式」这个不能复现的名字**。
> ⚠ 反查手法（本例中抓住问题的那一步）：**名字一旦给出，就应当能用它反推出匹配式**；
> 反推不出（或反推出的匹配式给出**另一个数**）⇒ 名字是错的，**删名字、留匹配式**。

### 3.2 `.ccr` 的段表与版本闸——`.coi` 要引用的「身份」今天怎么表达

`[已实现]`（全部在 `src/compiler/ccr_io.cr`）：

| 项 | 行 | 值 / 语义 |
|---|---|---|
| `CCR_MAGIC` | `:134` | `827474755`（`"CCR1"`） |
| `CCR_VERSION` | `:135` | **`9`**——**v9-only**：load 校验 `== 9`，`version ≠ 9` **整类拒收**（D10 先例：**不得**静默当「段/字段缺席 = 空表」） |
| `CCR_SEG_COUNT` | `:138` | **`8`**——`STR SYM NOD ENT REG EDG TYPE IFACE`（规范序 tag 1..8） |
| `CCR_SEG_TYPE` / `CCR_SEG_IFACE` | `:139` / `:140` | `7` / `8` |
| 文件头 | `:33-34`（头注） | `[magic u32 \| version u32 \| seg_count u32 \| reserved u32]` = **16B** |
| 段表 | `:35-36`（头注） | `8 × 12B = {tag u32, offset u32, size u32}`，规范序，段体紧随段表连续排列 |
| load 闸 1（magic） | `:975` | `if magic != CCR_MAGIC { return -1; }` |
| load 闸 2（version） | `:979` | `if ver != CCR_VERSION { return -1; }` |
| load 闸 3（段 tag 域） | `:1006` | `if tg < 1 \|\| tg > CCR_SEG_COUNT { return -1; }` |
| load 闸 4（重复段） | `:1017-1018` | TYPE/IFACE 重复 ⇒ `return -1` |
| load 闸 5（必备段） | `:1027`（注） | TYPE/IFACE **必备**（D11：可选段 = 两种 `.ccr` 在野 = 静默降级面） |

**段级归属**（`.coi` 要引用的坐标全在这里）：

| 段 | tag | 记录 | 可否作 `.coi` 的引用锚 |
|---|---|---|---|
| `STR` | 1 | 字符串表 `[count][{len, data}]` | ✅（但 ⚠ 见 §九.4 STR 陷阱） |
| `SYM` | 2 | globals / funcs / str_consts / structs / enums / **opt_meta** | ✅ 函数行号可作锚；**opt_meta 是要搬走的那一节** |
| `NOD` | 3 | `40B {op, dest, src1, src2, src3, tk, first_edge, edge_count, +28 项索引}` | ✅ **图的坐标主锚**（NOD id = 文件序） |
| `ENT` | 4 | `28B {var_id, version, def_nod, live_start, live_end, home, flags}` | ✅ 条目级锚 |
| `REG` | 5 | `24B {kind, parent, enter_nod, exit_nod, first_ent, last_ent}` | ✅ **region 级锚** |
| `EDG` | 6 | `8B {to_nod, kind}` | ✅ 依赖锚 |
| `TYPE` | 7 | 类型行表 `24B {kind,data,extra}` + 项 DAG `40B {tag,a..d}` | ✅ 类型面锚 |
| `IFACE` | 8 | D14 五小节（Task 3 已落内容面） | ✅ 接口面锚 |

### 3.3 ⚠ 立论锚点：`g_opt_meta` 与现行教义**自相矛盾**，且 v7 规格的「开放点 3」正是留给它的

这是本文**最强的一条**现状发现，也是 `.coi` 存在的直接理由。

**教义侧** `[已实现]` / `[已设计未实现]`：

1. `src/compiler/ccr_io.cr:84`（ENT 段头注）原文：
   > `home 恒 -1（实例注记——分配决策不写回格式，字节 spec §3.5）`
2. `docs/superpowers/specs/2026-09-09-lattice-ir-v7-format.md:106` 原文：
   > `| home | i32 | **恒 -1 直通**（实例映射注记——分配决策 = 实例层，不写回格式） |`
3. 同档 `:183` / `:200` 的裁决（2026-09-10）原文：
   > loader 对 `home≠-1` / `flags≠0` **接受不拒绝**——home = 实例映射注记，`.ccr` = corec→corearch
   > **传输中间物**，实例层（分配/缓存映射）决策不写回格式；…
   > **开放点 3 保留：未来实例层选择写回（非传输中间物用途）时重议**

**事实侧** `[已实现]`：`OPT_KEY_REG_ASSIGN`（= `var_idx → 物理寄存器`）**就是一条分配决策**，
而它的落盘载体 `g_opt_meta` **就在 `.ccr` 的 SYM 段里**（§三.1）。

> 📌 **本文展开——两处矛盾的精确形状**：
> - 教义说「分配决策不写回格式」，事实是**格式里留了一个分配决策的袋子**。
>   今天这个袋子是空的（§三.1 实测 1872/1872 `opt_count=0`），所以矛盾**不显形**。
> - 但这正是「**静默**」的定义：一个**已经版本化、已经参与 load 校验、名字叫 metadata** 的载体，
>   只要有人往 `g_opt_meta` 写一条记录，`.ccr` 就**静默**变成「分配决策写回格式」的样子——与本仓三态纪律相悖。
> - **v7 规格的「开放点 3」是维护者自己留的口子**：「未来实例层选择写回（**非传输中间物用途**）时重议」。
>   **`.coi` 恰恰就是那个「非传输中间物用途」**——一份**分发出去**的、独立生命周期的优化知识载体。
>   ⇒ **`.coi` 是对开放点 3 的正式答复**，而不是又一次绕过。

**搬迁的字节面代价（必读）**：`opt_meta` 子节是 SYM 段的**最后一个子节**，盘上恒为 `[0u32]` = **4B**。
把它从 `.ccr` 移出 ⇒ SYM 段长 −4B ⇒ **`.ccr` 字节变** ⇒ 触发
（a）canary ELF 判据链条（本仓「ELF 变须维护者声明 + 同批重锁」），
（b）逐字节对拍的 pre/post 锚。**本文不裁决搬迁时机**——列入 §二十四 待裁 A。

### 3.4 旁挂先例：`.cir` 快照缓存 / `.core/cache/` / `CIR_CACHE_VER`

`[已实现]`，全部在 `src/compiler/cir_cache.cr`：

| 机制 | 位置 | 内容 |
|---|---|---|
| magic | `:50` | `CIR_CACHE_MAGIC = -4485090715960753727` |
| 版本 | `:135` | **`CIR_CACHE_VER = 22`**（历史链 12→…→20→21→22，每一代的 bump 理由逐条记在 `:3-134` 头注） |
| **身份闸** | `:179` `fn cir_compiler_identity` | 写运行中编译器自身 ELF（`/proc/self/exe`）**全文件内容哈希**；load 时比对，不等 ⇒ cache miss |
| 退化路径 | `:172-178`（注） | 取不到身份 ⇒ 身份 = 0 ⇒ **两端点均关缓存**，**绝不落「身份 0」条目**（否则两个同样取不到身份的编译器互相当同身份命中） |
| 分工（原文 `:170-172`） | —— | **VER = 手工粗粒度**（格式/语义生成代）· **身份 = 自动细粒度**（编译器内容驱动，「同格式、不同前端行为」也覆盖）。**两者都匹配才命中** |
| 目录 | `cir_cache.cr:890-896` · `main.cr:528` | `.core/cache/cir/`，**相对 cwd**；清理 `main.cr:417` |

**⚠ 负面前例（本文必须继承的教训）** `[已实现]`（`cir_cache.cr:104-116` 头注原文要点）：

> `func_fingerprint`（**实际位置 `ir_gen.cr:4001-4035`**，⚠ 见下）**不覆盖函数体内容**——只取源文件字节哈希 + 4 个函数级字段
> （kind/名/形参数/body 节点 kind），注释自称 `"Walk the body AST"`（`ir_gen.cr:4022`）但**代码是 stub**；`sig_fingerprint`（`:4037`）同理。
> ⇒ **关闭复活通道的是身份闸、不是指纹**；同批登记 TODO #2026-09-17-17。
>
> ⚠ **附带发现（本文实核）**：`cir_cache.cr` 头注把它标为 `ir_gen.cr:3964-3996`——
> **该引用在 `develop@origin` 上已陈旧**（实际 `:4001`，偏 ~37 行）。这本身是「**文档行号 ≠ 修订**」
> 的又一实例，也是本文全程用 `jj file show -r develop@origin` 而不就地 grep 的理由。

> 📌 **本文展开——这对 `.coi` 的 §九（身份与失效）意味着什么**：
> 原文 §6 要求记录携带 `source_fingerprint`，「fingerprint mismatch → record invalid」。
> **本仓的实测是：自造指纹会静默退化成 stub，而且退化后不报错。**
> ⇒ `.coi` **不得**只靠自造指纹。必须**双闸**：(a) 引用结构的指纹；(b) **生产者身份**
> （沿用 `.cir` 的「运行中二进制内容哈希」形态）。**双闸是本节给 §九 的硬约束**，不是可选项。

**`CIR_CACHE_VER` 与 `CCR_VERSION` 的现状对照** `[已实现]`：`.cir` 快照面已到 **22**，
而 `.ccr` 侧仍停在 **9**（`ccr_io.cr:137` 注原文：「`CIR_CACHE_VER` 当时为 17……**`.ccr` 侧仍不 bump**」）。
⇒ **两个格式的版本节奏是解耦的**——这是 `.coi` 应当效仿的：**独立版本位，不与 `.ccr` 联锁**。

---

## 四、【核心】12 条设计不变量（原文 §19）

> 原文 §19 原文：「The following should be treated as **hard design rules**」。
> 本文把每条**判据化**为三件套：**形式陈述 · 它禁止了什么 · 可机械检查的判据形状**。
> ⚠ 判据形状是**形状**——落地时写成脚本/测试才有约束力；写成散文等于没有。
> ⚠ 每条判据**默认须两向**（正向 + 反向钉子），单向判据对反向缺陷恒绿（本仓纪律）。

### #1 `.ccr` 保持独立于 `.coi`

- **形式陈述**：`.ccr` 的任何字段/段**不含**对 `.coi` 的引用；`.ccr` 的完成性判据（能否 load、能否发射）**不含**「`.coi` 是否存在」这个输入。
- **禁止**：`.ccr` 头部出现 sidecar 指针 / 期望哈希 / 「需配套 `.coi`」标记位；`.ccr` 的 `load` 因 `.coi` 缺失或损坏而失败。
- **判据形状**：
  - 结构闸：`load_ccr` 的全部拒绝点（`return -1`）的**输入集合**里**零** `g_coi_*` 符号——可用「把 `.coi` 相关全局全部置零/删除后重编 `corearch`，`load_ccr` 的拒绝路径集合不变」来证。
  - 行为闸：`.coi` 替换为随机字节 / 删除 ⇒ `corearch` rc 与产物**逐字节不变**。

### #2 `.coi` 可依赖 `.ccr`/`.cir` 的身份

- **形式陈述**：依赖**单向**——`.coi` 的每条记录至少含一个指向 `.ccr` 身份的字段（`source_ccr_identity` + 结构锚，§九.1）。
- **禁止**：反向依赖（`.ccr` → required `.coi`，即 #1）；`.coi` 记录在**无 `.ccr` 的情况下可独立解释语义**（那意味着它自带了程序语义 ⇒ 越界成第二语义权威）。
- **判据形状**：
  - schema 闸：记录必填字段表含 `source_ccr_identity`，且**不含**任何「节点/类型/值」的完整内联定义（只许锚 + 指针）。
  - 负向钉子：构造源身份不匹配的 `.coi` ⇒ **全记录失效**（不是「按缺省接受」）。

### #3 `.coi` 永远可选（⭐ 与 #4 并列最要紧）

- **形式陈述**：对任意合法 `.ccr`，`{ccr}` 与 `{ccr, coi}` 都是**合法输入**，且**语义等价**（发射产物逐字节相同）；差异只允许出现在**工作量/质量**维度。
- **禁止**：把 `.coi` 缺失编码成 error / diagnostic（原文 §5 的 `absence → recompute` 是**静默**路径）；把 `.coi` 放进 required-input 清单 / 构建系统的必需依赖；在缺 `.coi` 时走「降级语义」分支。
- **判据形状（两条，缺一不可）**：
  - (a) **移除态对拍**：同源 pre/post，删除全部 `.coi` ⇒ ELF + `.ccr` 的 **sha256 相同**且 rc=0。
  - (b) ⭐ **结构钉子（证明它真的没被违反）**：把所有 `.coi` 读点的返回值**强制为「未命中」**
    （编译期常量开关，例如 `g_coi_disabled := 1`），重编 ⇒ 产物仍**逐字节相同**。
    ⚠ 这条是关键：它证明的是「**`.coi` 没有参与语义**」，而 (a) 只能证明「**这一次** `.coi` 没有影响」。
    若只有 (a)，一个「`.coi` 命中时改了产物、但测试语料恰好没命中」的实现会**恒绿**。

### #4 `.coi` 绝不是语义权威（⭐）

- **形式陈述**：存在判定 `legal(O)`，由**当前编译器独立建立**；`use(O) ⟹ legal(O)`；**`legal` 的输入不含 `.coi` 自身**。
- **禁止**：任何「**因为 `.coi` 这么说，所以接受该变换**」的路径；`.coi` 载荷进入 checker / 类型判定 / 发射决策的**判定位**（只允许进**候选位**）。
- **判据形状（两条，缺一不可）**：
  - (a) ⭐ **敌意载荷对拍（证明它真的没被违反）**：把 `.coi` 全部载荷字节替换为**固定种子的伪随机**，
    重编 ⇒ 产物（ELF + `.ccr`）与**无 `.coi` 态逐字节相同**，且 rc=0（不崩、不报错）。
    ⚠ 这条**同时覆盖原文 §14 的验收句**（「forged record must not cause acceptance of an illegal transformation」）——
    因为「随机载荷下产物与无 `.coi` 态相同」蕴含「没有任何载荷被采信」。
  - (b) **结构闸**：`grep -rn 'coi' src/compiler/{checker,type_engine,ir_gen}.cr` = **0**（`.coi` 不进入语义 pass 的符号面）。
    ⚠ 该闸是**必要不充分**的（符号面干净 ≠ 判定位干净），故必须与 (a) 同用。

### #5 泛型与目标特定优化信息可共存

- **形式陈述**：候选集 = `generic ∪ { t : compatible(t, target) }`；两域在同一文件、同一 region 上可同时存在。
- **禁止**：把两者建成互斥模式（「要么 generic 要么 target」）；目标未知时**丢弃** generic。
- **判据形状**：目标未知 ⇒ generic 记录条数**不变**；目标已知 ⇒ 候选集 ≥ generic 条数；**反向钉子**：不 compatible 的目标记录**必须不在**候选集（防「全收」假绿）。

### #6 目标特定记录必须声明兼容条件

- **形式陈述**：每条 target 记录必含**非空**的 `target_descriptor` 引用；无谓词的 target 记录 = **格式非法**。
- **禁止**：target 段里出现「无谓词」的记录（= 伪装成 target-specific 的 generic，会让 §5 的候选集语义失准）。
- **判据形状**：装载器对 (i) `target_id` 悬空、(ii) 谓词为空，**必须二选一且写死**：**拒绝整档** 或 **按 #8 跳过**。
  ⚠ **本文建议：两者都拒绝**（悬空引用 = 损坏证据；空谓词 = 生成侧 bug，静默跳过会掩盖它）。此建议**未获裁决**，见 §二十四 待裁 G。

### #7 陈旧记录必须可安全丢弃

- **形式陈述**：失效是**记录级局部**的；失效路径**不产生诊断、不改变产物**。
- **禁止**：失效导致编译失败；失效面扩散到「整个 `.coi` 丢弃」以外还要波及 `.ccr`；把失效**写回** `.ccr`。
- **判据形状（**必须两向**）**：
  - 正向：改动被引用结构的**一个字节** ⇒ 该记录失效，且产物与无 `.coi` 态**相同**。
  - 反向钉子：**不**改动 ⇒ 该记录**必须命中**（防「恒失效」假绿——一个永远失效的实现让正向判据恒绿）。

### #8 未知的可选记录种类必须可跳过

- **形式陈述**：装载器对**未知 `kind`** 的行为 = 跳过该记录并继续；未知**段**同理。
- **禁止**：未知 kind ⇒ 拒绝整档；把 kind 做成**封闭枚举**（新增 kind 需要 bump 容器版本）。
- **判据形状**：注入一条 `kind` = 保留值/未知值的记录 ⇒ 装载成功且**其余记录的命中数不变**；
  **反向钉子**：把该注入记录的 kind 换成**已知值**但 schema 非法 ⇒ **必须拒绝**（证明「跳过」不是「一律不校验」）。

### #9 优化候选仍须过正常合法性/验证

- **形式陈述**：`use(O) ⟹ legal_checked(O)`，且 `legal_checked` = **正常路径**（不因 `.coi` 而短路）。
- **禁止**：`.coi` 命中时跳过验证（「信任缓存」）；`.coi` 载荷携带「已验证」标记位作为**跳过依据**。
- **判据形状**：
  - 行为闸：注入一条**非法**变换记录 ⇒ **必须被拒绝**（诊断/rc 非零，视该变换的失败面而定）。
  - schema 闸：记录字段表里**零** `verified` / `checked` / `trusted` 类字段（防「携带结论当依据」）。
  ⚠ 与 #4 的关系：#4 管「不得采信」，#9 管「**即使想采信也没用**」——两者合起来才封死「信任缓存」类缺陷。

### #10 硬件能力/模型信息**本身**不是 `.coi`

- **形式陈述**：`.coi` **只引用**能力名 / 维度（**选择器**），**不定义**它们；定义真源 = HIT 表 / hw-map / `CapabilityDomain`。
- **禁止**：在 `.coi` 里内联 feature 语义（如「`avx512f` 意味着 512 位向量」）；`.coi` 成为能力词汇表的**第二真源**。
- **判据形状**：
  - 词汇闸：`.coi` 的谓词字段**只允许出现**词汇表里的键 + 区间；装载器对**未知 feature 名** ⇒ 该记录**不可匹配**（**不是**「当作满足」）。
  - 零内联闸：`.coi` 的 schema 定义里**零** `feature → 语义` 映射表（`grep` schema 定义面）。
  - ⚠ **划界**：`execution-mapping-design.md` §3.7 `CapabilityDomain` 是**执行域放置**的能力偏序；
    本文的能力谓词**引用**它（或 HIT 的键），**不重复定义**。见 §〇.2 与 §二十五（词汇表真源未决）。

### #11 运行时机器状态不是 canonical `.coi`

- **形式陈述**：`.coi` 的 canonical 载荷**不含**随运行/调度/环境变化的量；此类量只出现在 **profile/runtime 面**，或 `.coi` 的**引用/签名**位置。
- **禁止**：把下列六项（原文 §10 清单）冻结成永久优化知识——
  当前热状态 · 当前时钟 · 当前空闲 VRAM · 当前 NUMA 放置 · 当前争用 · 当前可用设备数。
- **判据形状**：
  - schema 闸：`.coi` 记录字段表与原文 §10 六项清单**零同名**。
  - 来源闸：代价记录的必填 `source` ∈ {`static-model`, `compiler-estimate`} 才可进 **canonical 段**；
    `measured` / `profile` 只能进**条件段**且必带 `environment_signature`（§十三）。
  - **确定性闸（最强）**：同一 (source_ref, kind, target) 在两次独立编译中的产出**必须逐字节相同**——
    任何「冻结了机器状态」的实现会立刻不等。

### #12 优化器过程历史不是可复用优化知识

- **形式陈述**：`.coi` 记录 = 可复用的**结论**，不是产生它的**过程**。
- **禁止**：原文 §4 的八项进入记录 schema——
  搜索队列序 · 被拒候选历史 · 临时哈希表 · 分配器 scratch 状态 · 瞬态 SSA 编号 · 求解器内部状态 · 临时 e-graph 节点 · 后端调试轨迹。
- **判据形状**：
  - schema 闸：记录字段表与上述八项**零同名**。
  - **确定性闸**：同一 (source_ref, kind) 在两次独立编译中产生的记录**逐字节相同**。
    ⚠ 这条**与 #11 的确定性闸同源但不同因**：过程历史会带上顺序/时间/指针 ⇒ 立刻不等。
    ⇒ **一条判据同时钉两条不变量**，是本格式性价比最高的一条检查。

**不变量计数**：原文 §19 = **12 条**，本文逐条判据化 = **12 条**（无增删）。
⚠ 按本仓枚举计数纪律，读作「**至少 12 条**」——落地时若发现某条可拆（如 #3/#4 各自的两条闸），**计数只增不减**。

---

## 五、与 `.ccr` 的边界对照表

> 表分三块：**属于 `.ccr`** / **属于 `.coi`** / **两者都不属于**（原文 §4 与 §19 都点名了第三块）。
> ⚠ **边界有争议的逐条标出**（标 ⚠ 者进 §二十四 或 §二十五）。

### 5.1 属于 `.ccr`（目标无关 · 长期分发 · 语义面）

| 信息类 | 现载体 | 依据 | 争议 |
|---|---|---|---|
| 程序关系（值流 / 配方 / 图活性） | `NOD`/`EDG`/`REG`/`ENT` 段 | 原文 §1；`cache-semantics.md` 条款 1 | — |
| 类型面 | `TYPE(7)` 段 | `ccr_io.cr:97`（段注） | — |
| 接口面 | `IFACE(8)` 段 | `ccr_io.cr:112`（段注）；Task 3 已落内容面 | — |
| 存在结构（条目/版本/存在区间/region） | `ENT`/`REG` 段 | `ccr_io.cr:74`（ENT 注）· `:87`（REG 注）；`existence-structure.md` | — |
| 字符串 / 符号面 | `STR`/`SYM` 段 | `ccr_io.cr:38`（STR 注）· `:39`（SYM 注） | ⚠ 见 §九.4 STR 陷阱 |
| relation 元数据（V8） | （未实现） | V8 规格 §三 3.5 | ⚠ C-10 撞名，见 §〇.1 |

### 5.2 属于 `.coi`（可丢 · 可重算 · 优化面）

| 信息类 | 今天在哪 | 为什么归 `.coi` | 争议 |
|---|---|---|---|
| **分配决策**（var → 物理寄存器） | ⚠ **今天在 `.ccr` 的 `g_opt_meta`**（`OPT_KEY_REG_ASSIGN`） | 它是**优化知识**、可丢可重算；且教义已声明「分配决策不写回格式」（§三.3） | ⚠⚠ **最大争议项**：现行物理位置在 `.ccr`；搬迁 = `.ccr` 字节变 |
| 栈共享决策 | 键已声明（`OPT_KEY_STACK_SHARE`，`ast.cr:662`） | 同上；**实测零写点**（§三.1 写侧只有 `REG_ASSIGN`） | ⚠ 零写点 = 废弃还是待迁？待裁 E |
| CSE 结果 | 键已声明（`OPT_KEY_CSE`，`ast.cr:663`） | 同上；**实测零写点** | ⚠ 同上 |
| 泛型优化知识（原文 §3.1 十类） | 无 | 原文 §3.1 | — |
| 目标特定优化知识（原文 §3.2 十类） | 无 | 原文 §3.2 | ⚠ 其谓词词汇表真源未决（§二十五） |
| 代价记录 | 无 | 原文 §10 | ⚠ 与 S-D `cost_model_query` 重叠，边界见 §十三 |
| 索引（加速结构） | 无 | 原文 §13（「representation-level acceleration structures…may be rebuilt」） | — |

### 5.3 ⚠ 两者都不属于（**原文 §4 与 §19 都点名**）

| 信息类 | 应有的归属 | 依据 | 争议 |
|---|---|---|---|
| **硬件能力描述** | HIT 表（`[已实现]`：`src/arch/x86_64/core-x86.toml` + `src/arch/hit/hit.cr`）· hw-map · `CapabilityDomain`（`[已设计未实现]`） | §19 #10 | ⚠ `.coi` 的目标谓词**引用**它 ⇒ 接口面待定（§二十四 待裁 F） |
| **硬件拓扑** | 同上级（`execution-mapping-design.md` §3.3 `TopologyLink`） | §19 #10 | — |
| **canonical target model** | 同上 | 原文 §4 | — |
| **运行时机器状态** | `RuntimeState`（`execution-mapping-design.md` §3.9）· profile 数据 | §19 #11；原文 §10 | ⚠ `.coi` 的 `environment_signature` 是**引用**不是冻结（§十三） |
| **优化器过程历史** | 不落盘（调试面可另置） | §19 #12；原文 §4 | — |
| **机器码缓存** | 无（原文 §4 明列 non-goal） | 原文 §4 | — |
| **规约 / 证明 / 结果** | 规约语法并入 `.cr`；证明面另议 | 原文 §4 | ⚠ 本仓 `.corespec` 已退役（`CLAUDE.md`），与此一致 |
| **运行时部署数据库** | 无 | 原文 §4 | — |

> 📌 **本文展开——三块的判据（一句话版）**：
> **`.ccr` = 不可丢的语义**；**`.coi` = 可丢的优化**；**两者皆非 = 不是编译器产物的真源**
> （硬件模型归硬件侧，机器状态归运行时侧，过程历史归不落盘侧）。
> 边界争议的判据模板：**问「丢弃它会不会让程序失去意义」**——会 ⇒ `.ccr`；不会但会变慢 ⇒ `.coi`；都不是编译器该存的 ⇒ 第三块。

---

## 六、两个优化域（原文 §3）

### 6.1 泛型优化信息（原文 §3.1）

原文 §3.1 的十类（**逐字保留**）：expensive analysis summaries · reduction recognition ·
affine access recognition · fusion/fission candidates · canonical optimization forms ·
reusable dependence summaries · parallelization candidates · algebraic optimization opportunities ·
reusable pattern-recognition results · normalized subgraph descriptions useful to optimizers。

原文 §3.1 的两条约束（**本文最看重的一句**）：

```
Generic information may still be derivable from .cir/.ccr.
Its reason for existing is reuse and compilation-time reduction.

Generic information MUST NOT introduce semantics that cannot already be recovered from
the authoritative program representation.
```

> 📌 **本文展开**：第二句是 #4 在 generic 域上的**具体化**——它把「非权威」落成一条可判的**可推导性**要求：
> generic 记录的内容**必须**能从 `.ccr`/图层重新算出。⇒ 判据形状：**清空 generic 段后重算，必须得到逐字节相同的记录集**
> （这也是 §十二.3 的「regenerate generic section only」操作的验收式）。

### 6.2 目标特定优化信息（原文 §3.2）

原文 §3.2 的绑定维度（**逐字保留**）：ISA · ISA feature set · microarchitecture · accelerator family ·
GPU architecture · NPU generation · implementation revision · compiler/backend compatibility level。

原文 §3.2 的示例形态（**逐字保留**）：

```
x86-64-v4:   pattern P -> AVX-512 candidate
zen5:        region R -> preferred scheduling form
nvidia-smXXX: subgraph S -> tensor-core candidate
target-NPU:  graph G -> native primitive candidate
```

原文 §3.2 的十类内容（**逐字保留**）：pattern matches · instruction-selection candidates ·
preferred tiling · layout preferences · target-specific decomposition · scheduling candidates ·
vector width preferences · accelerator mapping candidates · cost estimates ·
target-specific transformation candidates。

原文 §3.2 的关键一句：

```
A target-specific record is still only optimization knowledge.
The backend/verifier must independently establish legality before using it.
```

> 📌 **本文展开**：`independently establish legality` = **#9 的原文出处**。
> 注意它说的是「**backend/verifier**」——即**判定方是后端/验证器，不是 `.coi`**。
> ⇒ 目标特定记录的**采纳路径**必须是「`.coi` 提名 → 后端独立判合法 → 采用」，**不能是**「`.coi` 提名即采用」。

---

## 七、非目标（原文 §4）

原文 §4 的 13 项 non-goals（**逐字保留**）：

```
- a replacement for .cir;
- a replacement for .ccr;
- a specification format;
- a proof/result format;
- a debugger database;
- a runtime deployment database;
- a hardware capability description format;
- a hardware topology format;
- a canonical target model;
- a mandatory PGO container;
- a machine-code cache;
- an optimizer execution log;
- an authoritative transformation history.
```

原文 §4 的第二张清单——**「不应仅因为优化器产生了就存下来」的八项**（**逐字保留**）：

```
- search queue order;
- rejected candidate history;
- temporary hash tables;
- allocator scratch state;
- transient SSA numbering;
- internal solver state;
- temporary e-graph nodes;
- backend debug traces.
```

原文 §4 的收束句：「`.coi` stores reusable knowledge, not optimizer process history.」

> 📌 **本文展开**：第二张清单 = **#12 的原文出处**，且它给了**一条可操作的判据模板**——
> 「**不应仅因为优化器产生了就存下来**」的判别问法：**「这条信息在两次独立编译中会不会相同？」**
> 会 ⇒ 可能是可复用知识；不会（顺序/时间/地址/编号）⇒ 过程历史，#12 禁止。
> 这正是 #12 的「确定性闸」的由来。

---

## 八、正确性模型（原文 §5）

### 8.1 原文的核心式

```
use(O) is legal only if the current compiler can independently validate that
applying O preserves the required program semantics.
```

### 8.2 原文的四条失效映射（**逐字保留**）

```
.coi corruption -> discard/reject optimization information
.coi absence     -> recompute optimization knowledge
.coi mismatch    -> invalidate affected records
.coi stale       -> ignore affected records
```

原文的「Never」句：

```
.coi mismatch -> change program semantics
```

### 8.3 原文的记录定位（**逐字保留**）

记录**应**被视为：`candidate` · `cached analysis` · `reusable summary` · `reusable match`。
记录**不得**被视为：`semantic fact that must be trusted`。

> 📌 **本文展开——四条失效映射的**共同形状**：四条的**右端全部是「丢弃/重算/失效/忽略」**，
> 即 **fail-closed 到「什么都不用」**。本仓既有教义的原话（`cache-semantics.md` 条款 2′ 注）：
> > **判不出 ⇒ 不可驱逐（fail-closed）**：归属判定返回「未知」时判为不可驱逐，而不是可驱逐——
> > 否则「义务未满足」与「义务未被检查」在观测上不可区分，就是静默语义破坏。
>
> ⚠ **方向必须注意**：缓存语义的 fail-closed 是「**判不出 ⇒ 不敢丢**」（保守留）；
> `.coi` 的 fail-closed 是「**判不出 ⇒ 不敢用**」（保守弃）。**两者方向相反但同构**——
> 都是把「未知」推向**不改变语义**的那一侧。⇒ 判据形状：对每一类失效，**「未知」必须落在「不使用」侧**。

---

## 九、身份与失效（原文 §6）

### 9.1 原文的候选身份（**逐字保留**）

```
- relation-set fingerprint;
- region fingerprint;
- subgraph fingerprint;
- stable entity IDs;
- canonical structural digest;
- dependency fingerprint.
```

原文的记录概念式（**逐字保留**）：

```
record {
    id
    kind
    source_ref
    source_fingerprint
    validity
    payload
}
```

原文的失效律：

```
fingerprint mismatch -> record invalid
```

原文的**局部性**要求：

> Invalidation should be local when possible. Changing one region should not invalidate unrelated
> optimization records for the entire program unless the record depends on global structure.

### 9.2 ⚠ 本文展开——本仓的硬约束：**双闸**，不许只靠指纹

引 §三.4 的负面前例：本仓的 `func_fingerprint` / `sig_fingerprint` **注释自称走 AST，代码是 stub**
（`ir_gen.cr:4001-4035` / `:4037`），且该退化**不报错**。⇒ 若 `.coi` 只靠自造指纹，
则「指纹退化 → 旧记录被静默命中 → 优化知识被应用到已改变的结构上」是**必然**的失败模式。

⇒ **本文建议（硬约束）**：`.coi` 的身份采**双闸**——

| 闸 | 内容 | 借鉴来源 |
|---|---|---|
| **闸 1：结构指纹** | 对记录引用的结构区间（NOD/ENT/REG/TYPE 坐标 + 其内容）做结构化摘要 | 原文 §6 的六个候选 |
| **闸 2：生产者身份** | 生成该记录的编译器/优化器的**内容身份**（沿用 `.cir` 的「运行中二进制全文件哈希」形态） | `cir_cache.cr:179` `[已实现]` |

**两闸都匹配才命中**。理由引 `cir_cache.cr:170-172` 原文：「VER = 手工粗粒度…身份 = 自动细粒度…
**两者都必须匹配才命中**——格式变更手工 bump，行为变更由身份自动接管，不必再记得 bump」。
⚠ 另必须继承其**退化纪律**：身份取不到 ⇒ **关缓存**，**绝不落「身份 0」条目**（否则两个取不到身份的
编译器互相当同身份命中）。⇒ `.coi`：身份不可证 ⇒ **该 `.coi` 整档不用**（= 无 `.coi` 态）。

### 9.3 本文展开——局部失效的**可实现形态**

原文要求「invalidation should be local when possible」。本仓现状使「局部」**不可白得**：

- NOD id = **文件序**（`ccr_io.cr:71-75` 头注）⇒ **任何上游改动都会平移后续节点 id**；
- 因此「region 级失效」的前提（region 的身份在编辑后仍可认出）**今天不成立**。

⇒ **本文建议**：
- **v1 采用「记录携带其引用区间的显式指纹」**——不依赖 id 稳定性，指纹变了就失效（保守但正确）；
- **局部性作为优化而非前提**：当指纹粒度 = 记录自己声明的区间时，改一个 region **不会**让
  别的 region 的记录失效（因为它们的指纹只覆盖各自区间）。**这就白得了原文要的局部性**，
  且不需要 id 稳定。⚠ 代价：跨 region 的记录（依赖全局结构的）必须声明，且会整片失效——与原文
  「unless the record depends on global structure」一致。

### 9.4 ⚠ 本文展开——STR 段的指针陷阱（**本仓已实测的坑**）

`.ccr` 的 `STR` 段 = **编译期全量 interned 串**。本仓实测结论（`ccr_str_segment_trap`）：
**必经路径上新增一次 `str_intern` 会破「`.ccr` 逐字节不变」判据**——因为串表内容/顺序变了。

⇒ **对 `.coi` 的直接影响**：若 `.coi` 的 `source_ref` 用**字符串名**（函数名 / 变量名 / region 名）作锚，
则：
- 它**依赖 `.ccr` 的 STR 段内容** ⇒ `.coi` 的锚会随**无关**的 intern 变化而变（脆弱）；
- 且 `.coi` 若自己维护串表，**新增 intern 可能反噬 `.ccr` 的字节判据**（若两者共享 intern 池）。

⇒ **本文建议**：`source_ref` 的**主锚用数值坐标**（NOD/ENT/REG 行 id + TYPE 项索引），
**字符串名只作诊断字段**（`debug_name`，不参与失效判定）。此建议列入 §二十四 待裁 D（是否允许字符串锚作为可选加速）。

---

## 十、兼容性（原文 §7）

### 10.1 原文要求区分的四个版本（**逐字保留**）

```
format version
producer version
optimization record version
target descriptor version
```

原文的可跳过原则：

```
old compiler + new unknown optional record  -> ignore record
new compiler + old valid record             -> use if compatibility rules permit
```

原文的扩展性偏好：「The format should prefer **appendable namespaces** instead of requiring
a global redesign for each new optimizer.」

### 10.2 本文展开——四个版本的**载体与失效语义**（建议定稿）

| 版本 | 载体 | 不匹配时的行为 | 借鉴 |
|---|---|---|---|
| `format version` | 文件头（容器级） | **整档拒收**（不是「尽力解析」） | `.ccr` `CCR_VERSION`：`version ≠ 9` 整类拒收（`ccr_io.cr:979`）· `.cir` magic（`cir_cache.cr:575`） |
| `producer version` | 文件头 | **整档不用**（= 无 `.coi` 态）；⚠ 若采 §九.2 的**内容身份**，此项**可自动化**，不必手工 bump | `cir_cache.cr:179` 身份闸 |
| `optimization record version` | 每记录 | **跳过该记录**（≠ 整档拒收） | 原文 §7「unknown record kinds SHOULD be skippable」 |
| `target descriptor version` | 每目标描述符 | **跳过该目标组**（其下记录一并跳过） | 原文 §8 的部分匹配 |

> ⚠ **两条纪律**（本文展开，源自本仓 `.ccr` 的既有原则）：
> 1. **不得把「版本不匹配」静默当「段/字段缺席 = 空表」**——`CCR_VERSION` 从 7→8 升级时的原话：
>    「留 7 会让旧 6 段文件被静默读成「两段缺席 = 空表」——**正是三态纪律要消灭的静默类**」（`ccr_io.cr:8-10`）。
>    ⇒ `.coi` 的 format version 不匹配 = **拒收**，不是「空 `.coi`」。
>    ⚠ 但注意与 #3 的交互：**「拒收」在本格式里等价于「无 `.coi`」**，因为 `.coi` 本来就可选
>    ⇒ 拒收**不产生诊断**，静默降级为「重算」。**这与 `.ccr` 的拒收性质不同**（`.ccr` 拒收 = 编译失败）。
> 2. **appendable namespace 优先于封闭枚举**：`kind` 用**点分命名空间**（`generic.reduction` / `target.isel`），
>    新增 kind **不 bump format version** ⇒ 满足 #8。

---

## 十一、目标匹配（原文 §8）

### 11.1 原文的目标谓词（**逐字保留**）

```
target {
    architecture
    feature requirements
    feature exclusions
    implementation family
    minimum revision
    maximum revision
    backend ABI/version constraints
}
```

原文示例（**逐字保留**）：

```
architecture = x86_64
requires = [avx512f, avx512vl]

architecture = gpu
vendor = NVIDIA
compute_model >= X
```

原文要求：「Target predicates SHOULD support **partial matching**.」
及：「More-specific compatible entries may coexist with generic entries.」

原文的选择模型（**逐字保留**）：

```
generic optimization knowledge
    + all compatible target-specific knowledge
    -> optimizer candidate set
```

### 11.2 本文展开——谓词语言的**结论**（不是待裁）

> 原文 §20 把「target predicate language」列为开放问题。本文给出**结论**（依据 = #10 + 本仓既有物）。

**结论：不新造语言。谓词 = 「能力名 × 区间」的 DNF（析取范式）**：

```
predicate := clause ( "|" clause )*        # DNF：任一条满足即可匹配
clause    := term ( "&" term )*            # 合取
term      := feature_name [ relop bound ]  # relop ∈ { >=, <=, ==, != }
                                          # 无 relop = 存在性判定（"具备该 feature"）
```

- **`feature_exclusions`** 用 `!=` 表达（原文 §8 列的 exclusions 维度，**不需要独立语法**）。
- **部分匹配**（原文要求）由 DNF 自然给出：子句按能力名集合的**包含关系**比较，
  **更具体的子句 ⊆ 更泛的子句** ⇒ 更具体者优先（同 §17 的 `specificity` 序）。
- **`implementation family` / `minimum|maximum revision`** 落为 `feature_name` 的**区间项**
  （`family == zen`、`revision >= 5`）——即把原文的三个维度**统一到「名 + 区间」**，不设三套语法。

⚠ **词汇表真源（撞 #10）**：`feature_name` 的**取值集合不归 `.coi` 定义**。
- **本文建议**：词汇表真源 = **HIT 表文件**（`[已实现]`：`src/arch/x86_64/core-x86.toml` 是**表数据**、
  `src/arch/hit/hit.cr` 是**引擎**，且 `hit.cr` 头注原文：「字段值域/关联规则校验错误**全部拒绝加载**」——
  即**已经有词汇表纪律的现成载体**）。
- 备选：`execution-mapping-design.md` §3.7 `CapabilityDomain` 的十个能力维度（`[已设计未实现]`）。
- **本文不裁决** ⇒ §二十四 待裁 F。

---

## 十二、两域共存（原文 §9）

原文 §9 的示例（**逐字保留**）：

```
Generic:
    region R is a recognized reduction
    region R has affine accesses

x86:  R -> vector reduction candidate
GPU:  R -> warp reduction candidate
NPU:  R -> native reduction primitive candidate
```

原文的三条决策（**逐字保留**）：

```
If the target is unknown:  use Generic only
If the target is known:    use Generic + compatible target-specific entries
If .coi is absent:         rediscover everything from .cir/.ccr
```

> 📌 **本文展开**：这三条给出了 #5 的判据、#3 的「absence」路径，和 §11.2 选择模型的完整语义。
> ⚠ 注意第三条**不是错误路径**：它是**设计上的正常路径**（原文 §5 的 `absence -> recompute`）。
> ⇒ 实现上「目标未知」与「`.coi` 缺席」**必须汇入同一条代码路径**（都是「只有 generic——而无 generic 时即全量重算」），
> 否则会产生「两种降级行为」= 两套语义 = 静默分歧面。

---

## 十三、代价信息（原文 §10）

### 13.1 原文的约束与形态（**逐字保留**）

> Cost data may exist inside **target-specific** optimization records, but it must be treated as
> **conditional and non-authoritative**.

原文的五个来源：

```
- static target model;
- measured benchmark;
- profile;
- heuristic estimate;
- compiler-generated estimate.
```

原文的代价概念式：

```
cost {
    metric
    value
    confidence
    source
    environment_signature
}
```

原文关于运行时依赖数据的立场：

> Cost information that depends on runtime state **should normally live in runtime/profile data**
> rather than canonical `.coi`.

原文的六项「不稳定运行时依赖数据」（**逐字保留**）：

```
- current thermal state;
- current clock;
- current free VRAM;
- current NUMA placement;
- current contention;
- currently available device count.
```

原文的收束：「`.coi` may **reference** such data classes but should not **freeze** transient machine state as permanent optimization knowledge.」

### 13.2 本文展开——与 S-D 成本模型的边界（**结论**）

本仓已有一个**成本模型接口**（S-C/S-D，`[已设计未实现]`）：
`cost_model_query(kind, subject, mapping_desc) -> { cost, band（必填）, model_id, model_ver, assumptions[] }`。

⇒ **边界（本文建议）**：

| 面 | 归属 | 理由 |
|---|---|---|
| **成本模型本身**（如何算、量纲、band 定义） | **S-D** | 原文 §4 明列 `.coi` 不是 canonical target model |
| **成本查询的结果**（某 (subject, target) 的代价） | **`.coi`**（作为**可丢的缓存**） | 它是可重算的 ⇒ 符合 §5 的 `candidate` / `cached analysis` 定位 |
| **模型身份**（`model_id` / `model_ver`） | **`.coi` 记录的必填溯源字段** | 模型换代 ⇒ 缓存失效（= §十.2 的 `producer version` 同构） |

⇒ **`.coi` 的代价记录 = 一次 cost model 查询的缓存**，必带 `model_id`/`model_ver`。
原文 §10 的五来源**映射到本仓**：

| 原文来源 | 本文归类 | 可否进 canonical 段 |
|---|---|---|
| `static target model` | 模型面（S-D 定义） | ✅（可复现） |
| `compiler-generated estimate` | 编译器推断（可复现） | ✅ |
| `heuristic estimate` | 编译器推断（可复现，但 `confidence` 低） | ✅ |
| `measured benchmark` | **测量面** | ⚠ 仅**条件段** + 必带 `environment_signature` |
| `profile` | **测量面** | ⚠ 同上 |

⚠ **待裁 J（§二十四）**：`band` 字段是否**必须**贯穿进 `.coi` 的代价记录（S-D 把 `band` 定为**必填**，
而原文 §10 的概念式只有 `confidence`）。本文建议：**两者都留**（`confidence` = 原文口径，`band` = S-D 口径），
但这会让同一信息有两个载体 ⇒ 需维护者裁。

---

## 十四、记录类（原文 §11）

原文 §11 的初始记录类（**逐字保留**）：

**Generic**：`GENERIC_PATTERN` · `ANALYSIS_SUMMARY` · `REDUCTION_INFO` · `AFFINE_INFO` ·
`DEPENDENCE_SUMMARY` · `PARALLEL_CANDIDATE` · `FUSION_CANDIDATE` · `NORMAL_FORM` · `REWRITE_CANDIDATE`

**Target-specific**：`TARGET_PATTERN` · `ISEL_CANDIDATE` · `SCHEDULE_CANDIDATE` · `TILING_CANDIDATE` ·
`LAYOUT_CANDIDATE` · `VECTORIZATION_CANDIDATE` · `ACCELERATOR_MAPPING` · `TARGET_COST`

原文的保留声明：

> **These names are provisional.** The format should support extension **without forcing all future
> optimization knowledge into a fixed enum.**

> 📌 **本文展开——「provisional + 非固定枚举」的可实现形态**：把上面的 17 个名字**不是**实现成枚举，
> 而是实现成 **`kind` 命名空间下的「已知 kind 注册表」**（§十.2 纪律 2）：
> - 注册表命中 ⇒ 按该 kind 的 schema 解析；
> - 未命中 ⇒ **跳过**（#8）。
> ⇒ 17 个名字只是**首批注册条目**，不是格式边界。**这直接满足原文的保留声明**，
> 且判据化后就是 #8 的反向钉子（已知 kind + 非法 schema ⇒ 必须拒绝）。

---

## 十五、容器结构（原文 §12）

### 15.1 原文的概念布局（**逐字保留**）

```
COI Header

String/Namespace Table
Entity Reference Table

Generic Section
    Record[]
    Index[]

Target Section
    TargetDescriptor[]
    TargetRecordGroup[]
    Index[]

Integrity Section
    optional checksums
    optional per-section hashes
```

原文的高层文本模型：

```
coi {
    version
    source { ccr_identity  optional_cir_identity }
    generic { records... }
    targets { target_descriptor...  records... }
}
```

原文的免责句：「The final binary representation **does not need to mirror this syntax exactly**.」

### 15.2 本文展开——二进制容器的**结论**（Q1）

**结论：采用与 `.ccr` **同构**的「定长头 + 段表 + 段体」架构，但段号空间与版本闸**独立**。**

```
[header]:  magic u32 | format_version u32 | seg_count u32 | reserved u32
[seg table]: seg_count × {tag u32, offset u32, size u32}   （规范序，段体连续紧随）
[seg bodies]
```

理由（依据 = 本仓既有物）：
1. `.ccr` 的段表架构 `[已实现]`（`ccr_io.cr:62-66`），且**其判据已工程化**：
   规范序闸 / 段体连续闸 / 必备段闸 / 重复段闸（§三.2 的 load 闸 3/4/5）。
   复用它 ⇒ 「格式实现 bug」的面**降到接近零**（这是本仓最贵的资产之一）。
2. 段表天然满足原文 §15 的三条分发要求（见 §十八）：剥离 target 段 = 段表操作，不需重写记录。
3. 与 `.cir` 的**教训**一致：`.cir` 用定长 magic + 版本（`cir_cache.cr:50/135`）也是同族形态。

⚠ **与 `.ccr` 的三个**必须不同**（否则制造耦合）：
| 项 | `.ccr` | `.coi`（本文建议） |
|---|---|---|
| magic | `827474755`（`"CCR1"`） | **不同值**（防串档） |
| 版本闸 | `CCR_VERSION = 9`，load 校验 `== 9` | **独立版本位**；不匹配 ⇒ 整档不用（§十.2） |
| 段号空间 | `1..8`（规范序，**封闭且有闸**） | **可扩展**（未知段 = 跳过，满足 #8）⇒ ⚠ 与 `.ccr` 的「未知 tag ⇒ `return -1`」**方向相反** |

> ⚠ **本文展开——为什么段号纪律必须相反**：`.ccr` 的 `load` 对 `tg > CCR_SEG_COUNT` **拒收**
> （`ccr_io.cr:1006`），因为 `.ccr` 的段是**语义面**，未知段 = 有语义没读 ⇒ 必须拒。
> `.coi` 的段是**优化面**，未知段 = 有优化没读 ⇒ **跳过**（#8）。
> **同一机制、相反纪律**——这是本格式最容易被实现错的一处，**判据形状见 #8**。

### 15.3 本文展开——原文字符串表 / 实体引用表的处置（Q3 相关）

原文的 `String/Namespace Table` 与 `Entity Reference Table` 两节，本文建议：
- **不复刻 `String/Namespace Table`** 为必需节——理由 = §九.4 的 STR 陷阱（字符串锚脆弱且可能反噬 `.ccr` 字节判据）；
- **保留** `Entity Reference Table` 概念 = §9.1 的 `source_ref` 承载面，但**主锚用数值坐标**。
- ⚠ 若落地时确需字符串表，**必须是 `.coi` 私有的串表**（绝不与 `.ccr` 的 intern 池共享）——判据：
  「`.coi` 的串表增删**不改变** `.ccr` 的任何字节」。

---

## 十六、索引（原文 §13）

原文 §13 的索引维度（**逐字保留**）：

```
by source entity · by region · by relation fingerprint · by optimization kind
by target predicate · by pattern signature
```

原文的定位句：

> Indexes are **representation-level acceleration structures**. They are **not optimization
> semantics** and **may be rebuilt**.

> 📌 **本文展开**：这句话给了索引**极强的自由度**，也给了**极强的判据**：
> - 自由度：索引可以任意形态（甚至可以不落盘，装载时重建）；
> - 判据：**删掉索引段，装载结果（候选集）必须逐字节/逐条相同**——只有工作量变化。
> ⇒ 这是 #3 的又一实例（可选性），且**是 `.coi` 内部自己的 #3**。
> ⚠ 与 #7 的关系：索引**不参与失效判定**（否则索引过期会静默改变候选集）——索引只是「去哪找」，
> 「找出来的算不算」由 §九 的身份闸判。

---

## 十七、安全与信任（原文 §14）

### 17.1 原文要求（**逐字保留**）

> `.coi` should be treated as **untrusted input** when distributed.

解析器必须校验：

```
- lengths;  - offsets;  - section bounds;  - record versions;
- reference validity;  - target descriptor bounds;  - payload schema.
```

原文的后果清单：

```
A forged optimization record MAY cause:
    - rejection;  - fallback;  - additional compiler work.

It MUST NOT cause:
    - acceptance of an illegal transformation;
    - semantic corruption;
    - verifier bypass.
```

### 17.2 本文展开——与 #4 / #9 的关系，及判据

⚠ **本节的三个 `MUST NOT` 与 #4/#9 是同一件事的三个面**：

| 原文 MUST NOT | 本文对应 |
|---|---|
| acceptance of an illegal transformation | **#9**（正常验证不短路）+ **#4**（不采信） |
| semantic corruption | **#4**（语义权威）+ **#3**（可选性） |
| verifier bypass | **#9**（验证路径不被 `.coi` 影响） |

⇒ **判据形状 = #4(a) 的敌意载荷对拍**（随机载荷 ⇒ 产物与无 `.coi` 态逐字节相同）+ **#9 的行为闸**（非法变换 ⇒ 必拒）。
**本文建议把这两条判据作为 `.coi` 落地批的**必备**验收项**（§二十二 的验收判据 1/3 已含其雏形）。

**解析器复杂度（Q11，原文 §20 的「maximum parser complexity」）——本文结论**：

**线性单遍 + 无回溯 + 先验边界校验**：
1. 全部长度/偏移**在使用前**校验（借用 `.ccr` 的 `ccr_has_bytes(pos, n, seg_end)` 形态，`[已实现]`）；
2. **payload = 不透明字节 + 长度**——格式层**永不**递归解析 payload，由该 kind 的消费者自行校验 schema；
3. **无递归下降**（无嵌套容器、无自引用结构）；
4. 内存占用上界 = `O(文件大小)`（**禁止**多次展开/放大）。
5. **判据形状**：fuzz（随机字节 / 截断 / 长度溢出 / 越界偏移）⇒ 全部 **rc≠0 或安全跳过**，
   **不得 SIGSEGV**。⚠ 本仓已有先例：越界读可让守卫**静默返回 1**
   （`src/arch/x86_64/regalloc.cr:17-23` 头注：`coexist-oob-guard` 的守卫缺失 ⇒「读穿缓冲则崩溃」/「全零槽 ⇒ 误判共存」）
   ⇒ 本判据**必须包含崩溃面**，不能只看返回值。

---

## 十八、分发行为（原文 §15）

### 18.1 原文的合法包配置（**逐字保留**）

```
program.ccr
```
```
program.ccr  +  program.coi
```
```
program.ccr  +  program.coi  +  runtime/profile data
```

原文：「`.coi` can contain multiple target-specific records in one file.」示例：

```
generic · x86-64-v3 · x86-64-v4 · zen5 · armv9 · gpu-family-A · npu-family-B
```

原文的剥离许可：

> A distributor may **strip target-specific entries that are irrelevant to its deployment
> without modifying `.ccr`**.

> 📌 **本文展开——这条是 §15.2 分节结构的**存在理由**：**
> 「剥离而不改 `.ccr`」+「一个文件含多目标」两条**同时**成立 ⇒ 剥离必须是**文件内的段级操作**。
> 若把 generic 与 target 混在一节里，剥离就需要**重写记录**（且要重算索引/偏移）——
> 那就是把「分发操作」变成「格式操作」，风险面完全不同。
> ⇒ **物理分节（generic 段 / target 段 / 每目标组可分）是 §十五 的必需要求，不是优化**。
> ⇒ 这也是 §二十二 落地顺序把「分节」排在「记录」之前的理由。

---

## 十九、更新模型（原文 §16）

原文 §16 的可能操作（**逐字保留**）：

```
- regenerate all .coi;
- regenerate generic section only;
- add support for a new target;
- replace one target section;
- discard stale records;
- merge compatible optimization packages.
```

原文的目的句：

> This allows the **same `.ccr` artifact** to accumulate better optimization knowledge over time
> **without changing the canonical program relations**.

> 📌 **本文展开**：六个操作**全部是段级/档级**的，没有一个是记录级 diff。
> ⇒ 支持 §二十二 的落地顺序结论：**「段级独立替换」是增量的最小可用形态**，
> 而「记录级增量」在当前身份方案下（§九.3：NOD id = 文件序）**做不到**，且**不必要**。
> ⚠ 与 §九.3 的局部失效**不矛盾**：局部失效管「**失效判定**的粒度」，段级替换管「**文件更新**的粒度」。
> 两者可以不同粒度（失效可以是记录级，更新仍是段级）。

---

## 二十、合并语义（原文 §17）

### 20.1 原文的多源示例（**逐字保留**）

```
compiler-generated generic.coi
vendor-gpu.coi
deployment-profile.coi
```

原文的合并优先序（**逐字保留**）：

```
- validity over specificity;
- compatible more-specific target entries over generic target entries;
- newer schema only when semantically compatible;
- independently verified candidates over blindly trusted hints.
```

原文的关键一句：

> **Conflicting optimization candidates are not semantic conflicts.** They are **alternative
> candidates** for the optimizer to evaluate.

### 20.2 本文展开——合并的**结构性结论**

1. **多 `.coi` 是常态，不是异常**（原文 §17 三源示例）。⇒ 装载器 API 收**列表**，不是单文件。
2. **合并的产物 = 候选集，不是「胜者」**：原文明确「conflicting candidates are not semantic conflicts」
   ⇒ 合并**不得**做「冲突消解」（消解会产生「哪个赢了」的语义负担），只做**排序 + 去重**。
3. **优先序的四条**落为**候选集内的排序键**（不是过滤器）：
   `validity` > `specificity` > `schema 新旧` > `verified`。
   ⚠ 注意第 1 条 `validity over specificity`：**有效性优先于特异性**——即「更新的、更泛的」胜过「过期的、更具体的」。
4. ⚠ **待裁 H（§二十四）**：同 `(source_ref, kind)` 的两条记录 payload 不同时，
   **保留两条** 还是 **取 validity 高者**？本文建议**保留两条**（原文第 3 句支持），
   但这让候选集**无界**（同一 region 可被任意多 `.coi` 提名）⇒ 需要一条**上界纪律**。

---

## 二十一、与未来硬件的关系（原文 §18）

原文（**逐字保留**）：

> `.ccr` is responsible for universal applicability. `.coi` is not required to be universally applicable.

```
For future unknown hardware:
    .ccr remains valid
    generic .coi may remain useful
    incompatible target-specific .coi is ignored
    new target-specific .coi may be generated later
```

原文的结论句：「Therefore **hardware evolution does not require rewriting the canonical relation format**.」

> 📌 **本文展开**：这四行是 **#10 + #18 的联合推论**，且它给出了**一条极强的判据**：
> 对任意**未知**硬件目标，`.ccr` 的字节**不变**、generic 记录**仍可用**、
> 不兼容的 target 记录**被忽略而非拒绝整档**。
> ⇒ 判据形状：构造一个**词汇表里不存在的**目标描述符 ⇒ 装载必须成功（不拒收整档）、
> generic 记录命中数不变、target 记录**全部不匹配**（而非「全部匹配」）。
> ⚠ 「**不匹配而非拒绝**」是 #10 的词汇闸的**确切语义**（未知 feature 名 ⇒ 该记录不可匹配）。

---

## 二十二、落地顺序（原文 §21「Minimal V1」的**改写**）

> ⚠⚠ **本节是对原文 §21 的**改写**，改写依据 = 维护者 2026-09-23 当场指示原话：
> 「**不规定什么 v1 反正你完整实现**」。
> ⇒ **本节不是「最小版 / 分期交付」**。下面的顺序**不缩小交付面**，只回答「**先做什么后做什么能减少返工**」。
> 原文 §21 开头那句「The first implementation should stay **deliberately small**」**本文不保留该主张**
> ——它与维护者指示冲突，按其指示作废；**原文 §21 的四条「要证明的性质」全部保留**，
> 但改写成**验收判据**（见 §二十二.2），**不是**「只证明这些就够了」。
>
> 原文 §21 的 V1 字段清单（header / generic records / target descriptors / target records / index）
> **本文视为「首批字段形状」的建议**，不再称为 V1 边界。

### 22.1 落地顺序（按**返工半径**排，不是按重要性排）

排序原则（本文展开）：**被后续所有东西依赖的，先做**；做完之后不再改格式的，后做。
判断「返工半径」的问法 = **「如果它后置，已经写好的哪些东西要重做？」**

| 序 | 做什么 | 若后置的返工面（= 为什么要先做） |
|---|---|---|
| **1** | **身份与失效方案**（§九：数值坐标主锚 + 双闸） | 记录格式的一切字段都挂在它上面。后置 ⇒ **全部已写的记录 schema 重做** |
| **2** | **容器骨架** + **未知段/未知 kind 的跳过能力**（§十五.2、#8） | 跳过能力后置 ⇒ 第一批记录会**锁死「必须全懂」**的语义，之后每加一个 kind 都要 bump 格式 |
| **3** | **物理分节**（generic 段 / target 段 / 每目标组）（§十八） | 分节后置 ⇒ §18 剥离、§19 分节替换、§20 合并**三处全部返工**（它们都要求「不改 `.ccr` 就能改 `.coi`」） |
| **4** | **单条泛型记录的端到端只读通道**（能读、能忽略、**暂不参与优化**） | 此时即可实证 **#3 与 #4**（可选性 / 非权威）——**在没有任何优化收益之前**就能把它们钉死 |
| **5** | **目标谓词 + 目标记录 + 候选集合并**（§十一、§十二、§二十） | 此时可实证 **#5 / #6 / #10**（共存 / 兼容声明 / 词汇闸） |
| **6** | **失效检测的负向钉子**（§九.2 双闸 + #7 的反向钉子） | 此时可实证 **#7**（陈旧可丢弃）——且是为第 7 步提供**可信的观测面** |
| **7** | **可测量的收益** + **代价记录**（§十三）+ **索引**（§十六） | **最后做，因为它不改格式**：收益是「装载后工作量下降」的观测，索引是可重建的加速结构。⚠ 若前 6 步做对，此步**零格式风险** |

⚠ **两处必须提前的例外**（顺序里的硬约束，不是偏好）：
- **#8（未知 kind 跳过）必须在第 2 步**——见上表第 2 行理由；它是**格式的不可逆决策**。
- **#4/#3 的判据必须在第 4 步**——它们是**安全性判据**，早于任何收益验证 ⇒ 避免「先有收益、后被发现有语义影响」的返工。

### 22.2 原文 §21 的四条性质 → **验收判据**（**措辞已由「只证明」改为「必须成立」**）

> 原文 §21 原文：「V1 should prove **only** four properties」+ 四条清单。
> ⚠ 本文**去掉「only」**：四条是**必须成立的验收判据**，不是交付面的上界。
> 每条给 **(判据形状, 反向钉子)** 两半——只写正向即空壳绿。

| # | 性质（原文逐字） | 验收判据（本文展开） | 反向钉子（防假绿） |
|---|---|---|---|
| 1 | `.coi` can be removed safely | 删除全部 `.coi` ⇒ rc=0 **且** ELF + `.ccr` **sha256 相同**（同源 pre/post 对拍） | 把全部 `.coi` 读点强制「未命中」⇒ 产物**仍**逐字节相同（证明不是「这次恰好没影响」） |
| 2 | generic and target-specific records can coexist | 同一 region 同挂 generic + 2 个不同 target ⇒ 候选集 = 3 条 | 目标未知 ⇒ 候选集 = 1 条（generic）；且**不兼容**的目标记录**不在**候选集 |
| 3 | stale records are detected and ignored | 改动被引用结构的 1 字节 ⇒ 该记录失效，产物 = 无 `.coi` 态 | **不**改动 ⇒ 该记录**必须命中**（防「恒失效」假绿） |
| 4 | loading `.coi` measurably reduces rediscovery/matching work | 同语料冷/暖两次编译：暖态的分析/匹配**计数下降**，产物逐字节相同 | `.coi` 全失效时计数**必须回到冷态水平**（防「计数器恒降」假绿） |

> ⚠ **第 4 条的两个已知陷阱（本文展开，必读）**：
> 1. **暖态读数前必须清缓存**：本仓实测——暖态 `.cir` 重放的**首次 intern 在 gen 期的合成串会取到别串**，
>    且 rc=0 静默（`warm_cache_synth_string_trap`，VER 17–20 四代全复现）。
>    ⇒ 判据 4 的「暖态」必须在**干净缓存**下取，否则读数本身不可信。
> 2. **「计数下降」必须两向**：单向断言（「暖态计数 ≤ 冷态」）对「计数器根本没接上」恒绿。
>    ⇒ 必须配反向钉子（失效态 = 冷态水平）。

---

## 二十三、原文 §20「Open design questions」——**13 条逐条结论**

> ⚠ 维护者指示：「**不规定什么 v1 反正你完整实现**」+ 任务要求「**逐条给出结论**…**含糊留白即不合格**」。
> ⇒ 本节对 13 条**全部给出结论**；**确实必须由维护者裁的，明确标成待裁并给选项**（§二十四 汇总）。
> 体例：**问题 · 结论（本文展开）· 依据 · 状态**。

| # | 问题（原文 §20 逐字） | 结论 | 依据 | 状态 |
|---|---|---|---|---|
| 1 | final binary container layout | **定长头 + 段表 + 段体**（与 `.ccr` 同构）；magic 与版本闸独立；**段号可扩展**（未知段跳过） | §十五.2；`.ccr` 段表 `[已实现]` 的判据可复用 | ✅ 结论（子项待裁 A1：是否共享 `ccr_io.cr` 的段表辅助函数） |
| 2 | compression strategy | **v1 不压缩**。若将来要：仅**整段**压缩（不做流式），且**压缩段必须可跳过**（不知压缩格式 ⇒ 跳过该段 = 空） | §十七的解析复杂度纪律（压缩器 = 攻击面 + 复杂度）；#8 的跳过纪律 | ✅ 结论（子项待裁 A2：是否留 per-section 压缩标志位） |
| 3 | stable entity/reference identity scheme | **不新建身份**：直接引用 `.ccr` 的空间坐标（NOD 文件序 / ENT id / REG 行 id / SYM 函数行号 / TYPE 项索引）作**主锚**；**字符串名只作诊断**（`debug_name`，不参与失效判定） | §9.3（NOD id = 文件序，另立身份 = 第二真源）；§9.4（STR 陷阱） | ✅ 结论（子项待裁 A3：是否需要跨重编稳定的 id） |
| 4 | fingerprint algorithm and granularity | **双闸**：结构指纹（覆盖记录**自己声明的引用区间**）+ **生产者内容身份**。**禁止**只靠自造指纹 | §9.2；`cir_cache.cr:104-116` 的 stub 负面前例 + `:179` 身份闸 `[已实现]` | ✅ 结论（子项待裁 A4：指纹算法与确定性口径） |
| 5 | record namespace/versioning rules | **两层**：文件级 `format_version`（容器，不匹配 ⇒ 整档不用）+ 记录级 `kind`（**点分命名空间**，可追加）+ `record_version`。未知 kind ⇒ **跳过** | §十.2；#8；原文 §11「非固定枚举」 | ✅ 结论（无待裁） |
| 6 | target predicate language | **不新造语言**：谓词 = 「能力名 × 区间」的 **DNF**（`&`/`\|`/`>=`/`<=`/`==`/`!=`）；`feature_exclusions` 用 `!=` 表达；`family`/`revision` 统一为「名 + 区间」 | §十一.2；#10（词汇表不归 `.coi`） | ✅ 结论（子项待裁 A5：**词汇表真源** = HIT 还是 `CapabilityDomain`） |
| 7 | whether generic and target-specific data use one file or separable sections | **一个文件 + 物理分节**（generic 段 / target 段 / 每目标组可分） | §十八（「一个文件含多目标」+「剥离而不改 `.ccr`」两条同时成立 ⇒ 剥离必须是段级操作） | ✅ 结论（无待裁） |
| 8 | merge precedence rules | **优先序四条 = 候选集内的排序键**（不是过滤器）：`validity` > `specificity` > `schema` > `verified`。**不做冲突消解**（原文：冲突不是语义冲突） | §二十.2；原文 §17 | ✅ 结论（子项待裁 A6：同 `(source_ref, kind)` payload 不同 ⇒ 保留两条还是取一） |
| 9 | whether vendor-provided optimization packages are signed | **v1 不引入签名**。理由：`.coi` 一律视为 **untrusted input**（原文 §14），**正确性不依赖来源** ⇒ 签名只提供「来源声明」，不提供「可信度提升」。**但为签名留位**（未知段跳过 ⇒ 天然可留） | 原文 §14（必须独立验证）+ #4/#9 | ✅ 结论（子项待裁 A7：是否加**来源声明**字段——非签名，仅溯源） |
| 10 | whether expensive analysis summaries should have TTL/version constraints | **不用 TTL（时间），用版本闸（内容）**。**明令禁止**用挂钟时间做失效判据；`environment_signature` 里的时间戳只能是**诊断信息**，不得参与判定 | §9.2（`.cir` 的教训：身份闸 = 内容驱动、自动、可复现；TTL = 时钟驱动、不可复现）；本仓「判据锚定非确定值」失效形态 | ✅ 结论（无待裁） |
| 11 | maximum parser complexity | **线性单遍 + 无回溯 + 先验边界校验**；payload **不透明**（格式层永不递归解析）；**无递归下降**；内存 `O(文件大小)`；fuzz ⇒ rc≠0 或安全跳过，**不得 SIGSEGV** | §十七.2；`.ccr` 的 `ccr_has_bytes` 形态 `[已实现]`；`coexist-oob-guard` 的越界先例 | ✅ 结论（无待裁） |
| 12 | incremental update strategy | **段级独立替换 = 增量的最小可用形态**（§十六 的六个操作全是段级/档级）。**记录级 diff 不做**（当前身份方案下做不到，且 §16 不要求）。**失效判定的粒度（记录级）与文件更新的粒度（段级）可以不同** | §十九；§9.3 | ✅ 结论（无待裁） |
| 13 | exact boundary between .coi cost data and runtime/profile data | 判据 = **可复现性**（不是「是不是数字」）。`static-model` / `compiler-estimate` / `heuristic` ⇒ **canonical 段**；`measured` / `profile` ⇒ **条件段** + 必带 `environment_signature`，消费方须独立确认签名匹配，否则**降级为 heuristic**。原文 §10 的六项运行时状态**一律不入** canonical | §十三.2；原文 §10；§19 #11 | ✅ 结论（子项待裁 A8：`band` 与 `confidence` 是否并存） |

**计数**：13 条中 **13 条有结论**，其中 **8 条带子项待裁**（A1–A8，进 §二十四）。
⚠ 按枚举计数纪律，读作「**至少 13 条**」。

---

## 二十四、待裁清单（**本文不替维护者裁决**）

> 体例：**项 · 选项 · 本文倾向（若有）· 影响面**。
> ⚠ 与 §二十三 的 A1–A8 对应；**A9–A11 是本文新提出的**（不在原文 §20 的 13 条内）。

| # | 待裁项 | 选项 | 本文倾向 | 影响面 |
|---|---|---|---|---|
| **A1** | 是否共享 `ccr_io.cr` 的段表辅助函数 | (a) 共享（少写代码，但 `.coi` 实现进 `corearch` 清单 ⇒ 与 `.ccr` 强耦合）(b) 独立实现（代码重复，但两格式版本节奏解耦） | **(b)** —— §三.4 实测两格式版本节奏已解耦（`.cir` 22 vs `.ccr` 9） | `.coi` 实现进哪个构建清单 |
| **A2** | 是否留 per-section 压缩标志位 | (a) 不留（v1 完全不压缩）(b) 留位但恒 0（将来不用 bump 格式） | **(b)** —— 留位成本 = 1 bit，改格式成本 = 全量重生成 | 容器头布局（**改后不可逆**） |
| **A3** | 是否需要**跨重编稳定**的实体 id | (a) 不需要（用 `.ccr` 文件序坐标，重编即失效）(b) 需要（引入稳定 id 层） | **(a)** —— (b) 会引入新身份层 = 第二真源（§9.3） | 失效率（(a) 下任何上游改动整档失效） |
| **A4** | 结构指纹的算法与确定性口径 | (a) 复用本仓既有哈希族（如 `tt_hash5` 风格）(b) 新定一套 | 无倾向（**需实测确定性**） | 指纹实现与判据 |
| **A5** | 能力谓词的**词汇表真源** | (a) HIT 表文件（`core-x86.toml`，`[已实现]`，已有「值域校验错误全部拒绝加载」纪律）(b) `execution-mapping-design.md` §3.7 `CapabilityDomain`（`[已设计未实现]`）(c) 两者合一，HIT 为实例、CapabilityDomain 为维度 | **(a) 为首批**，长程向 (c) 收敛 | #10 的词汇闸落点；与 §〇.2 的划界 |
| **A6** | 同 `(source_ref, kind)` payload 不同时：保留两条还是取一 | (a) 保留全部（原文 §17 支持）(b) 取 validity 高者 | **(a) + 上界纪律** —— (a) 会让候选集无界，须配一条上界 | 候选集大小 / 优化器评估成本 |
| **A7** | 是否加「来源声明」字段（**非签名**，仅溯源） | (a) 加（如 `producer_name`，纯诊断）(b) 不加 | **(a)** —— 与 A2 同理：留位便宜、改格式贵 | 记录头布局 |
| **A8** | 代价记录里 `band`（S-D 必填）与 `confidence`（原文 §10 口径）是否并存 | (a) 并存（两口径都有）(b) 只用 `band`（向 S-D 收口）(c) 只用 `confidence`（保持原文） | **(a)** —— 但两载体 = 同一信息两个来源，须定主从 | §十三的代价记录 schema |
| **A9** | ⚠ **`g_opt_meta` 搬迁的时机** | (a) 与 V8 落地同批搬 (b) 与 `.coi` 落地批搬 (c) 先只标记（在两处都注明归属），后搬 | 无倾向（**须维护者裁**） | ⚠ **`.ccr` 字节变**（SYM 段 −4B）⇒ canary ELF 判据链 + 逐字节对拍锚（§三.3） |
| **A10** | ⚠ **`OPT_KEY_STACK_SHARE` / `OPT_KEY_CSE` 的处置** | (a) 废弃（实测零写点）(b) 迁入 `.coi` 首批 kind (c) 保留在 `.ccr` | **(a) 或 (b)** —— 实测**零写点**（§三.1）；留在 `.ccr` 只会维持「空壳载体」状态 | 键表 + 文档面 |
| **A11** | ⚠ **`.coi` 的默认发现路径 / 命名约定** | (a) 默认 `<program>.coi`（与 `<program>.ccr` 同名同目录）(b) 无默认，必须显式列出（支持 §17 的多源 `vendor-gpu.coi` 等）(c) 默认 + 可追加 | **(a) + (c)**（默认同名，另可显式追加多源） | 打包/分发工具链；与 §18 三个包配置的对应 |
| **A12** | ⚠ **`.cir` 是否入分发包**（§二.2 的读法确认） | (a) 不入（本文读法，与原文 §15 逐字一致）(b) 入 | **(a)** —— 但**未经维护者确认**（列入 §二十五） | 分发格式面 |

**待裁项计数 = 12**（A1–A12；其中 A1–A8 来自 §二十三 的子项，A9–A12 为本文新提出）。
⚠ 读作「**至少 12 项**」。

---

## 二十五、未核实清单（**宁缺勿猜**）

> 本仓纪律：**核不到的标「未核实」**。以下各项**本文未能实核**，落地前必须补核。

| # | 未核实项 | 为什么未核实 | 补核方式 |
|---|---|---|---|
| **U1** | ~~「后端 71 处直读 `g_opt_meta`」这一计数~~ → **已解决（2026-09-23）** | ✅ **已澄清**：**71** 可复现 = `regalloc.cr` 54 + `instr.cr` 7 + `ent_kernel.cr` 10 的**行数和**；
  ⚠ 但该**数法名**（「读侧表达式」）**对不上**——按行数读侧表达式 = 18、按出现次数 = 19；且 `ent_kernel.cr` 那 10 行**全是注释**（该档读/写表达式均 = 0）。
  **本文先前报的「全仓 93 行」经查是本文的加法错误**（自打印逐档数之和 = 97）。⇒ **正确值 = 97（全仓）/ 67（后端三轴）**，见 §三.1 口径表 | 两处**都不改数、只写清数法**；已落地为 §三.1 的**口径表**（匹配式 · 单位 · 文件范围三列齐全） |
| **U2** | `g_opt_meta` 在 **corec 侧**是否**真的**恒空 | 本文有**两级证据**（写侧清单：`regalloc.cr` 不在 `corec_files`；产物实测：1872/1872 `opt_count=0`），但**未在 corec 上加计数器实测**「写 `.ccr` 前 `g_opt_meta_count == 0`」 | 在 `save_ccr` 入口加一条诊断打印（或一次性探针），跑 `corec build` 实读 |
| **U3** | 产物实测样本的**编译器代次** | 1872 个 `ver=9` 产物的 mtime ∈ 2026-09-15…2026-09-22，**未逐一核对**其由哪个编译器修订产生（只核了 `ver=9`） | 用当前 `develop@origin` 重建 `corec` 后**新产一个 `.ccr`**，重跑本解析器 |
| **U4** | **能力谓词词汇表**的真源（A5） | `core-x86.toml` 的键**是否足以表达** §11.1 的七个维度（尤其 `implementation family` / `min|max revision` / `backend ABI`）**未逐键核对** | 逐键对拍 `core-x86.toml` 与原文 §8 的七维度 |
| **U5** | `.cir` 是否入分发包（A12） | 原文 §15 的三个包配置里**没有** `.cir`；本文按「不入」读，但原文 §2 的图里 `.cir` 在管线中。**维护者未确认此读法** | 请维护者确认 |
| **U6** | `execution-mapping-design.md` 的 §3.7/§3.8/§3.9 与本文 §五.3 的**逐字段**边界 | 本文只核了**节标题与节号**（`:553` `CapabilityDomain` / `:596` `PerformanceProfile` / `:622` `RuntimeState` / `:765` `Cost Model`），**未逐字段对拍** | 逐字段对拍，补一张 §五.3 的字段级表 |
| **U7** | S-D 的 `cost_model_query` 返回结构（`band`/`assumptions[]`）的**现行文本** | 本文引的是 `execution-mapping-design.md` 与 S-C 中的**转述**，未读 S-D 原文档 | 读 `2026-09-11-explain-predict-incremental-design.md` §1.7.3/§2.6 |
| **U8** | V8 规格档的 C-10 **是否已在别处被裁决/改名** | 该档**未推**（不在 `develop@origin`）；本文读的是其 `ccrv8-ws` 工作副本，**该副本可能落后于其作者的最新稿** | 与其作者（`ccrv8b`）对齐，或待其推送后以修订为准 |
| **U9** | 「`.coi` 是对 v7 规格开放点 3 的答复」这一**读法** | 该读法是**本文展开**（§三.3），**不是维护者原话**；v7 规格的「开放点 3」措辞是否涵盖本场景，**未获确认** | 请维护者确认 |
| **U10** | `.ccr` 的 `IFACE(8)` 段「Task 3 已落内容面」的**完成度** | 本文核到 `ccr_io.cr:1592-1609` 已有 D14 五小节解析 + `IFACE_ENTRY_COUNT` 校验（`[已实现]`），但其**内容是否已覆盖全部计划项**未核 | 对拍 R2 P4 Task 3 计划与实际 |
| **U11** | 1872 个产物中**是否有非 corec 产出**的 `.ccr` | 未逐一追溯来源（可能是 `corec2`/`corec3`/测试临时产物） | 按需追溯 |

**未核实项计数 = 11**（U1–U11）。⚠ 读作「**至少 11 项**」。

---

## 二十六、一句话定义（原文 §22）

原文 §22（**逐字保留**）：

> `.coi` is an **optional, non-authoritative sidecar** that stores reusable generic and
> target-specific optimization knowledge while leaving `.ccr` as the universal,
> target-independent representation of program relations.

> 📌 **本文展开——这一句与 12 条不变量的对应**（用于自查定义与不变量是否一致）：
> | 定义中的词 | 对应不变量 |
> |---|---|
> | **optional** | #3（永远可选） |
> | **non-authoritative** | #4（绝不是语义权威）+ #9（仍须验证） |
> | **sidecar** | #1（`.ccr` 独立）+ #2（依赖单向） |
> | **reusable … knowledge** | #12（不是过程历史） |
> | **generic and target-specific** | #5（可共存）+ #6（目标记录须声明兼容） |
> | **leaving `.ccr` as the universal… representation** | #1 + #10（硬件模型不入）+ #11（运行时状态不入）+ #8/#7（未知/陈旧可跳过丢弃） |
> ⇒ **12 条不变量覆盖定义的全部构成词**，无剩余、无冗余。

---

## 附录 A：三态标注计数

| 标记 | 计数 | 说明 |
|---|---|---|
| `[已实现]` | **33** | 口径：`grep -o '\[已实现\]' <this file> \| wc -l`（**按出现次数**）。本文全部 `[已实现]` 均带 `develop@origin` @ `0eb1efd3` 的 `file:line` 或实测口径 |
| `[已设计未实现]` | **8** | 口径同上行（按出现次数）；逐项见下 |
| `[提案]` | 2（**显式标记**） | 口径同上行（按出现次数）。⚠ **本档是默认档**：未被标记的设计陈述**一律按 `[提案]` 读** ⇒ **实际覆盖 = 本文主体**；依据 = 全仓 `grep -i '\.coi\b'` = **0 行** |

**`[已实现]` 逐项**（本文引用的全部现状锚点）：

| 锚点 | 位置 |
|---|---|
| `g_opt_meta` 声明 / 节注 / 计数 | `src/compiler/globals.cr:376` · `:378` · `:379` |
| opt_meta 键表 | `src/compiler/ast.cr:659-663` |
| opt_meta 分配器 | `src/compiler/dyn_arr.cr:1090` |
| opt_meta 写 / 读 / 上界闸 | `src/compiler/ccr_io.cr:749` · `:1269` · `:1278` |
| opt_meta 唯一写侧 | `src/arch/x86_64/regalloc.cr`（写点 **26 行**；口径见 §三.1 口径表；终分配 `:768-824`；注入 `:199-215`） |
| opt_meta 读侧 | `src/arch/x86_64/instr.cr:34` · `src/compiler/corearch.cr:186-201` · `:210` |
| 单元归属 | `build_selfhost_native.py:65` · `:311-374` · `:388-390` |
| `.ccr` 常量与段表 | `src/compiler/ccr_io.cr:134-140` · `:32-36`（头注布局） |
| `.ccr` 各段注释起点 | `src/compiler/ccr_io.cr:38` STR · `:39` SYM · `:60` NOD · `:65` EDG · `:74` ENT · `:87` REG · `:97` TYPE · `:112` IFACE |
| `.ccr` load 闸 | `src/compiler/ccr_io.cr:975` · `:979` · `:1006` · `:1017-1018` · `:1027` |
| `.ccr` ENT home 注记 | `src/compiler/ccr_io.cr:84` |
| v7 规格 home 裁决 | `docs/superpowers/specs/2026-09-09-lattice-ir-v7-format.md:106` · `:183` · `:200` |
| `.cir` magic / VER / 身份闸 / 目录 | `src/compiler/cir_cache.cr:50` · `:135` · `:179` · `:890-896` · `main.cr:528` · `main.cr:417` |
| `.cir` 指纹 stub 负面前例 | `src/compiler/cir_cache.cr:104-116`（注）→ **实际** `ir_gen.cr:4001-4035` / `:4037`（注内标 `:3964-3996` **已陈旧**） |
| HIT 表 / 引擎 | `src/arch/x86_64/core-x86.toml` · `src/arch/hit/hit.cr` |
| 越界守卫先例 | `src/arch/x86_64/regalloc.cr:17-23`（注） |
| **产物实测** | 1872 个 `ver=9` `.ccr`，`opt_count` 全 0 / SYM `tail` 全 0（**口径见 §三.1 口径表**） |

**`[已设计未实现]` 逐项**：V8 Entity/Relation/metadata（`ccr-v8-open-relational-lattice.md`）·
`CapabilityDomain` / `PerformanceProfile` / `RuntimeState` / `Cost Model`（`execution-mapping-design.md` §3.7/§3.8/§3.9/§5.2）·
S-D 的 `cost_model_query`（`2026-09-11-explain-predict-incremental-design.md`）·
存在格 / Materialization Space（`materialization-space.md`）。

---

## 附录 B：与原文 22 节的覆盖对照（自查）

| 原文节 | 本文节 | 忠实度 |
|---|---|---|
| §1 Purpose | §一 | 逐字保留三分对照 + 中心律 |
| §2 Pipeline | §二 | 逐字保留图 + **加了现状核对与 `.cir` 两义澄清** |
| §3 Two domains | §六 | 逐字保留全部清单 |
| §4 Non-goals | §七 | 逐字保留 13 + 8 项 |
| §5 Correctness model | §八 | 逐字保留四条失效映射 |
| §6 Identity/invalidation | §九 | 逐字保留 + **加了双闸硬约束与 STR 陷阱** |
| §7 Compatibility | §十 | 逐字保留四个版本 |
| §8 Target matching | §十一 | 逐字保留 + **谓词语言结论** |
| §9 Coexistence | §十二 | 逐字保留三条决策 |
| §10 Cost information | §十三 | 逐字保留五来源 + 六项运行时状态 |
| §11 Record classes | §十四 | 逐字保留 17 类 + provisional 声明 |
| §12 Container | §十五 | 逐字保留概念布局 + **二进制结论** |
| §13 Indexing | §十六 | 逐字保留六维度 |
| §14 Security | §十七 | 逐字保留校验清单 + MUST NOT |
| §15 Distribution | §十八 | 逐字保留三个包配置 |
| §16 Update model | §十九 | 逐字保留六个操作 |
| §17 Merge semantics | §二十 | 逐字保留优先序四条 |
| §18 Future hardware | §二十一 | 逐字保留四行 |
| §19 Invariants | **§四** | 12 条，**逐条判据化**（三件套） |
| §20 Open questions | **§二十三** | 13 条，**逐条结论** |
| §21 Minimal V1 | **§二十二** | ⚠ **改写**（依据维护者指示）——四条性质**保留并改为验收判据** |
| §22 One-sentence | §二十六 | 逐字保留 + 与 12 条不变量的对应自查 |
