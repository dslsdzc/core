# Mapping 层分离（`Graph → Lattice → **Mapping** → Encoding`）——**纸面计划**

> **基线（pin）**：`38e6c9923ea498d441b44f46e777acab3713b3e5`（现查的 `develop@origin`）。
> **取数纪律**：一律 `jj --ignore-working-copy file show -r <pin>`；**不以 bookmark 名当锚**。
> **性质**：本文件**只出清单、形状与代价，不出代码**；未改任何非本文档的文件。
> **口径**：计数写「**至少 N**」并附清点命令；**「确证」（本批实读/实跑）与「待实测」分列**。
> **动机（维护者原话）**：「反正迟早都要重构的，还不如给他做完整」⇒ **不做「先插一个 seam」的半步，做整层分离**。

---

## ① 泄漏面全枚举（**起点 ≠ 全集**；本节 = 逐处实读后的结果）

**方法论声明**：`* 8` 这类模式的**朴素 grep 会严重过计数**（见 §②）——下表每一行都经**人工按 §② 判据归类**后才列入。

| # | 站点（符号锚） | 计数（至少） | 证的是什么 | 类别 |
|---|---|---|---|---|
| 1 | `src/compiler/provenance_verify.cr` · `get_alloc_size`：`IR_ALLOC_ARRAY ⇒ return s1 * 8`（注释自陈「**元素恒 8 字节**」） | **1** | **分配块的大小**（供「访问偏移 ≤ 块大小」比较） | **语义字节** |
| 2 | 同函数：`IR_ALLOC_STRUCT ⇒ si_field_count(fi) * 8`（注释「与 instr.cr IR_ALLOC_STRUCT 一致」） | **1** | 同上（struct 路径） | **语义字节** |
| 3 | `src/compiler/ptr_analysis.cr` · `IR_ADDR_INDEX` 分支：`w64(g_offsets, d*8, base_off + idx_val * 8)`（注释「常量索引可精确计算（`idx*8`）」） | **1** | **指针在块内的字节偏移**（常量索引可精确算 ⇒ 编译期可证） | **语义字节** |
| 4 | 同档 · `IR_SLICE` 分支：`offset = low*8`（注释原文） | **1** | 同上（切片基点） | **语义字节** |
| 5 | `src/compiler/ir_gen.cr` · `type_size(ti)`（锚 = `fn type_size`） | **≥20 个 return 分支** | **目标类型的字节尺寸**（`TY_INT→8` · `TY_DEX→8` · `TY_BOOL→1` · `TY_CHAR→4` · `TY_STRING→8` · `TYP_ARRAY→elem×cnt` …） | **经典机器映射本体** |
| 6 | 同档 · `type_align(ti)` | **≥12 个 return 分支** | **目标类型的对齐**（int/dex/string/ptr/ref/slice/named → 8；bool→1；char→4） | **经典机器映射本体** |
| 7 | `src/compiler/ast.cr` · `IR_ARENA_NEW : 32`（`src1=size_estimate`）· `IR_ARENA_RESET : 33`（`src1=arena_id`） | **2** | **IR 语义层里编码了 arena 模型**（arena 是语义单位而非宿主机器细节 ⇒ 这条**未必**要降层，见 §③ 注） | **语义节点（待裁）** |
| 8 | `src/stdlib/goroutine.cr` · `stack := alloc(16384)`（注释「Allocate stack (16KB)」） | **1** | **固定 16KB 栈**（宿主栈尺寸假设） | **运行时假设** |
| 9 | `docs/maintainer/design/execution-model.md` §三（GMP 模型 / 固定 16KB / `fiber_switch`） | 文档面 | 把上两条写成**设计** | **文档面** |

**清点命令（可粘可跑）**：
```bash
DEV=$(jj --ignore-working-copy log -r develop@origin --no-graph -T 'commit_id')   # 取数锚：现查现用
jj --ignore-working-copy file show -r "$DEV" src/compiler/provenance_verify.cr | grep -nE '\* *8'
jj --ignore-working-copy file show -r "$DEV" src/compiler/ptr_analysis.cr     | grep -nE '\* *8'
jj --ignore-working-copy file show -r "$DEV" src/compiler/ir_gen.cr          | grep -n 'fn type_size\|fn type_align'
```

### ①-bis 其它 pass 的同族核查（**brief 未列，本批补**）

| 档 | 同族命中 | 结论 |
|---|---|---|
| `src/compiler/region_check.cr` | `g_pts` / `g_pa_alloc_nodes` / `g_sgs` 三条**编译器侧表**访问；**零语义字节算术**（其判定 = **区域与生命周期**，与「块内偏移」正交） | **不是本批对象**（与 brief 的假设不同，见 §⑦-1） |
| `src/compiler/interp.cr` | 解释器有自己的槽宽假设（另一套表示） | **待实测**（本批未逐处读；解释器是否属「Mapping 层」需单裁） |
| `src/arch/**`（后端） | `type_size` 的**使用点**（帧布局/regalloc/宽度发射） | **消费者**（§③），**不是泄漏面**——后端**本来就该**知道字节 |

### ①-ter 二档：执行策略泄漏（**Arena 与 GMP**——本批补，brief 未列）

> **二档 = 「执行策略」层**：与一档（验证语义）不同，这一档漏的是**「程序怎么执行」**（区域生命周期、线程/协程模型、栈尺寸），不是「值怎么表示」。

**(a) `Arena`：`IR_ARENA_NEW(32)` / `IR_ARENA_RESET(33)` 的**全部消费点（**7 档**，逐处实读）：

| # | 站点 | 角色 | 备注 |
|---|---|---|---|
| 10 | `src/compiler/ast.cr`（`IR_ARENA_NEW : 32` · `IR_ARENA_RESET : 33`） | **定义** | `src1=size_estimate` / `src1=arena_id` |
| 11 | `src/compiler/ir_gen.cr`（`emit(IR_ARENA_RESET/NEW, …)`） | **生产者（4 处）** | 函数入口与循环体内各一（注释「arena reused per iteration」） |
| 12 | `src/compiler/instr.cr`（`if op == IR_ARENA_NEW` / `IR_ARENA_RESET`） | **后端发射（2 分支）** | 真正生成 arena 指令的**唯一**后端面 |
| 13 | `src/compiler/dataflow.cr`（`df_use_var` ×2 + DOT 名 `"arena_new"`） | **HDFG 建模（3 处）** | 把 arena 节点纳入数据流图 |
| 14 | `src/compiler/interp.cr`（`op2 == 32` / `op2 == 33`） | **解释器近似（2 处）** | 注释自陈「**interp 无 arena——no-op 近似**」⇒ **解释器腿与 ELF 腿在此面语义不同**（登记） |
| 15 | `src/compiler/opt.cr`（`if op == IR_ARENA_NEW/RESET { continue; }`） | **优化面跳过（2 处）** | —— |
| 16 | `src/lattice/ent_kernel.cr`（`op == IR_ARENA_NEW ⇒ "ARENA_NEW"`） | **命名映射（1 处）** | 中立核里的**名字**面（无行为） |

⇒ **二档(a) 的处置候选**（**不裁**）：`IR_ARENA_NEW/RESET` 降成 `REGION_ENTER/EXIT` **或纯关系**。
⚠ **一处必须登记的现状**：**解释器对 arena 是 no-op 近似**（上表 #14）⇒ 任何「把 arena 降成关系」的改动**会同时改变「两条腿在 arena 面上是否一致」**——这条**未被任何既有判据覆盖**（**待实测**）。

**(b) `GMP`：文档面（**维护者面**，处置须单问）**

| # | 站点 | 命中 | 性质 |
|---|---|---|---|
| 17 | `docs/maintainer/adr/adr-0017-concurrency-gmp.md` | 4（GMP/16KB/fiber_switch） | **ADR = 已决设计记录** |
| 18 | `docs/maintainer/design/execution-model.md` §三 | 7 | **维护者面设计文档** |
| 19 | `docs/maintainer/proposals/concurrency.md` | 1 | 提案面 |

**代码面对应物**（一档已列，此处交叉引用）：`src/stdlib/goroutine.cr` 的 `alloc(16384)`（16KB 栈）· `src/runtime/rt.s` 的 `fiber_switch`/`fiber_init`/`g_set_curg`（tier 1 表外的**运行时**面）。

> ⚠ **二档(b) 的硬约束（team-lead 定）**：`execution-model.md` 与 `adr-0017` 是**维护者面的设计意图表述** ⇒ **动它们 = 动设计意图的表述** ⇒ **该档处置必须单独问维护者**，**本计划不得直接写成「改文档」**。本节只**登记位置与命中数**。

### ①-quater 三档：编译器自身实现绑定（**登记，不动作**）

`w64`/`r64` 的表访问 · 8 字节编译器记录（`ESZ_ASTNODE=72`/`ESZ_DFNODE`/`ESZ_TYPE_ROW`）· ELF 结构（`src/format/elf/*`）。
**按分析自己的话「暂时完全可以不管」** ⇒ **本计划只登记**（§② 的判据已把它们与一档分开）。

---

## ② ⚠ 同族甄别（**本节最重要：防把整批判歪**）

### 为什么必须先做这一步

**我的第一遍 grep 就把编译器的侧表跨步当成了「语义字节算术」**（team-lead 亦复述过同一坑）。原始 grep 的命中里**大部分不是本批对象**：

```bash
jj --ignore-working-copy file show -r "$DEV" src/compiler/ptr_analysis.cr | grep -cE '\* *8'   # 原始命中
```
其中 **表跨步**（`alloc(nc * 8)` · `_dyncpy(g_pts, cap * 8, nb)` · `r64(g_pts, var * 8)`）**全部不属本批**——它们描述的是「**编译器自己的数组**每个元素 8 字节」，与**被编译程序**的布局无关。
**两类混在一屏、外形完全相同**，故必须给判据。

### 判据（可机械判，**两问**）

> **问基址**：`* 8` 的**基**是不是**编译器自己的表/缓冲**？（`g_pts` · `g_offsets` · `g_pa_alloc_nodes` · `g_df_var_producer` · `g_sg_*` · `alloc(nc*8)` 的返回值 …）
> **问因子**：那个 `8` 代表的是**被编译程序**里某元素的字节宽，还是**编译器记录**的字节宽？

- **两问都指向「编译器自己」** ⇒ **不属本批**（编译器跑在哪 ≠ Core 程序只能跑在哪）；
- **因子来自被编译程序的数量**（数组长度 `s1` · 字段数 `si_field_count(fi)` · 目标类型 `ti`）⇒ **属本批**。

### 反例对照（**至少一对「看起来一样但分属两侧」**）

**对照 A（同一档、同一函数、外形逐字相同 `s1 * 8`）**：
| 行 | 代码 | 侧 |
|---|---|---|
| `provenance_verify.cr` 的 `get_alloc_size` | `return s1 * 8;  // count * 8` | **语义侧**——`s1` = **被编译程序**的数组元素个数 ⇒ 8 是**目标元素宽** |
| `provenance_verify.cr` 的 `IR_DEREF` 分支 | `pts := r64(g_pts, s1 * 8);` | **编译器侧**——基址 `g_pts` 是编译器侧表（每 IR 变量一槽），`s1` 是**IR 变量号** |

**对照 B（同一档、不同函数）**：
| 行 | 代码 | 侧 |
|---|---|---|
| `ptr_analysis.cr` 的 `IR_ADDR_INDEX` | `base_off + idx_val * 8` | **语义侧**——`idx_val` = 被编译程序的常量下标 |
| `ptr_analysis.cr` 的 `grow_pa_alloc_nodes` 族 | `nb := alloc(nc * 8);` | **编译器侧**——扩容自己的表 |

⇒ **一句话判据**：**看那个 `8` 乘的是「程序的量」还是「编译器的量」**；基址是 `g_*` 侧表 **且** 索引是编译器槽号 ⇒ 编译器侧。

### 另一条易混（**不属本批，但读者会踩**）

`ESZ_ASTNODE = 72` · `ESZ_DFNODE` · `ESZ_TYPE_ROW` 这类**记录跨步常量**：它们是**编译器数据结构的布局**，**与目标程序布局无关** ⇒ 同属「编译器自己」。**判据同上**（问基址：`g_ast`/`g_df_nodes`/`g_types`）。

---

## ③ Mapping Contract 的形状

### 抽象侧是什么

不是数值，而是**两个关系**：

1. **`extent : Entry → Q`**——每个分配条目的**尺寸量**（`Q` 是**不透明量**，不是字节）；
2. **`offset ∈ extent(entry)`**——某指针指向该条目内的**某个偏移**（同样是不透明量），**以及**判定「偏移是否越界」所需的**比较**在同一 `Q` 域内可判定。

配套的**第三条**（现状由 `ir_gen::type_size` 承担）：**`stride : Type → Q`**——「元素 → 尺寸量」的映射，供 `count × stride` 与 `field_count × stride` 使用（现状两处**硬编码 8**）。

### 它替换掉什么

| 现状（§① 站点） | 现在算的 | 抽象后 |
|---|---|---|
| `provenance_verify` 的 `s1 * 8` / `field_count * 8` | **字节**大小 | `extent = count × stride(T)`（`stride` 来自 Mapping） |
| `ptr_analysis` 的 `idx_val * 8` / `low*8` | **字节**偏移 | `offset = index × stride(T) + base`（同上） |
| `ir_gen::type_size/type_align` | 硬编码 `8/1/4` | **Mapping 实例的数据**（经典 = 今天的值；非经典 = 另一套） |

### 谁消费它（**实读后的角色划分**）

| 角色 | 档 | 依据 |
|---|---|---|
| **生产者（偏移）** | `ptr_analysis.cr`（写 `g_offsets`，**3 个写点**） | 实读：`w64(g_offsets, …)` ×3 |
| **唯一比较者** | `provenance_verify.cr`（读 `g_offsets`，**1 个读点**） | 实读：`g_offsets` 的读者**全仓只有它**（清点命令见 §①） |
| **尺寸/对齐提供者** | `ir_gen.cr::type_size/type_align`（+ 后端使用点） | 实读 |
| **区域/生命周期**（**与字节面正交**） | `region_check.cr`（`g_pts`/`g_pa_alloc_nodes`/`g_sgs`） | 实读：**零字节算术** |
| **解析成字节** | **后端**（`src/arch/x86_64/*` 的帧布局/regalloc/宽度发射） | 取证（未逐处枚举，**待实测**） |

### 经典映射在哪一步把它解析成字节

**在后端选定的那一刻**（target triple = `x86_64-linux` ⇒ SysV ABI）：`Mapping.classic_x86_64` 提供 `stride(int)=8`、`size(bool)=1`、`align(char)=4` …——**即今天 `type_size/type_align` 里那张表原样搬进数据面**。

### 非经典映射（GPU / 其它）**不必回答同一个 `sizeof()`** —— 它落在哪

落在**同一个 Contract 的另一实例**：
- GPU 的 `stride` / `extent` 可以**不是字节**（如「元素个数 × 每元素 lane 数」）；
- **只要 ① 生产者（`ptr_analysis`）② 比较者（`provenance_verify`）③ 尺寸提供者 三方用同一个 `Q`**，`Q` 是字节还是别的**对验证逻辑透明**；
- ⇒ **不需要**让 GPU 回答「你的 `int` 几字节」——**需要的是让「越界比较」在它的 `Q` 里可判定**。
- ⚠ **`IR_ARENA_NEW/RESET`（§①-7）与 16KB 栈（§①-8）是否随之下层 = 待裁**：arena 可能是**语义**单位（子图 = 生命周期域），而下层的是**它的容量表示**。本文件**不裁**。

---

## ④ 施工序 + 每步判据（**每步可单独验收**）

**默认判据（除注明外）= 逐字节不变**：`.ccr` + ELF + **canary 五条**（`tools/baseline/canary_check.sh` 5/5 且与锁定值逐字节相同）+ D1 确定性闸门 5 条。

| 步 | 内容 | 判据 | 变了要有理由 |
|---|---|---|---|
| **S1** | `ir_gen::type_size/type_align` 的**常量**抽成命名数据表（Mapping 经典实例），函数体改读表 | **逐字节不变**（纯重构，行为零变化） | 不允许变 |
| **S2** | `provenance_verify` 的 2 处 `* 8` 改走 `extent`/`stride` 接口 | **逐字节不变** + **§⑤ 逐处证明表**更新 | 不允许变 |
| **S3** | `ptr_analysis` 的 2 处（`idx*8` / `low*8`）改走同一接口 | 同上 | 不允许变 |
| **S4** | Mapping 实例化点落位（target triple → 实例），后端**显式取** `stride/size/align` | 逐字节不变 | 不允许变 |
| **S5** | 文档面（`execution-model.md` §三 · `IR_ARENA_*` 的语义注记）+ 非经典映射的**空实例**登记 | 文档一致性 + 全量层 | —— |
| **S6** | 收口：全量五档 + canary + §⑤ 复核 | 五档 rc=0 + canary 5/5 + **§⑤ 零未登记损失** | —— |

**每步的回退点** = 该步的提交（S1–S4 全部「逐字节不变」⇒ 回退无产物风险）。

### ④-bis 三档的实施排序（**team-lead 倾向：一 → 二；三档只登记不动**）

| 档 | 范围 | 排期 | 前置 |
|---|---|---|---|
| **一（验证语义）** | S1–S4（§① #1–#6） | **先行** | 无（S1 即可开工） |
| **二（执行策略）** | Arena（#10–#16）· GMP 代码面（`goroutine.cr` 16KB / `rt.s` fiber 族） | **一之后** | ⚠ **二档(b) 的文档面须先问维护者**（ADR/design 是设计意图表述）；二档(a) 的 arena 降层**须先解决「解释器 no-op 近似」的一致性面**（§①-ter #14） |
| **三（编译器自身）** | `w64/r64` 表访问 · 8 字节记录 · ELF 结构 | **只登记，不动** | ——（分析自陈「暂时完全可以不管」） |

**排序理由（不是工作量，是依赖）**：一档的产物（`extent`/`stride` 的 `Q` 域）**是二档的前置**——Arena 的「容量表示」最终也要在同一 `Q` 域里说清；反过来先做二档会**在 `Q` 未定时先定 capacity 的表示**，属过早决定。
⚠ **二档不得并入一档的步**（独立批次验收）：一档的默认判据是「逐字节不变」，而**二档的 arena 降层很可能有意改变 IR 形态**（⇒ 判据不同、批次必须分开）。

---

## ⑤ ⚠ 硬性验收项：**验证强度不得净减**

> **改前能证的，改后要么仍能证，要么显式登记为「已知不再能证」并给理由。**

**为什么必须有**：把字节偏移抽象化，最危险的形态**不是编不过，是证明变弱了而没人发现**——**与 S6 那一类同一种静默**。

### ⑤-0 ⚠⚠ 首条（**本批唯一「一改就弱、且不会红」的点**）

> **既有兜底不得丢失**：`provenance_verify.cr::get_alloc_size` 末尾
> **`return -1;  // unknown (defer to runtime check)`**
> 与 `ptr_analysis.cr` 的「**运行时索引 ⇒ 写 `-1`**」是**有意设计**，**不是「没写」**。

**(a) `-1` 的语义（必须在实施时原样保留）**：**「这里证不了 ⇒ 交给运行时」**——即**编译期静态证明的诚实退让**，由运行期检查兜底。
**(b) 为什么它是本批的底线**：抽象化天然会「少证一点」，而**少证不会红**；`-1` 是这个批次里**唯一已经显式写出来的那条「少证」**⇒ **把它保住 = 保住了本批的底线**；反之，**把 `-1` 换成任何具体值（或换成「不写」）都 = 净减且静默**。
**(c) 钉子（**断言到「走了哪条路」，不是只断 rc**）**：构造一个**会落进 `-1` 分支**的输入（运行时索引 / 未知分配），**改后必须仍落进它**。
- 判据形态 = 断言**路径**（如：该变量的 offset 槽**仍为 `-1`** / 该分配的 size 查询**仍回 `-1`**），**不得**只断言 `rc=0`（rc 对「静默退化」不敏感）；
- **反控**：同一批里必须有一个**走具体值分支**的输入（常量索引）**仍走具体值**——否则「一律回 `-1`」也会让钉子全绿（**两向**）。

**逐处表（本批已填「改前」列；「改后」列由实施方填）**：

| # | 站点 | **改前证什么**（实读） | **改后证什么**（待填） |
|---|---|---|---|
| 1 | `get_alloc_size` `IR_ALLOC_ARRAY` | 块大小 = `count × 8` ⇒ 与偏移比较可判越界 | ? |
| 2 | 同上 `IR_ALLOC_STRUCT` | 块大小 = `字段数 × 8` | ? |
| 3 | `ptr_analysis` `IR_ADDR_INDEX` | **常量索引**可精确算偏移 ⇒ 编译期可证；**运行时索引 ⇒ 写 `-1`**，「迫使 `provenance_verify` 生成运行时检查」 | ? |
| 4 | 同上 `IR_SLICE` | `low*8`（常量时）；非常量 ⇒ `-1` | ? |

**⚠ 不得丢失的既有兜底** —— 见上 **⑤-0**（已升为首条；此处在原表位置保留交叉引用，避免读者漏读）。

**两条控制组**（缺一不可）：
- **正控**：一个**已知会被 `provenance_verify` 拒**的程序，改后**仍须被拒**，并**断言到具体错误码**（错误码**待实测**——本批只读，未跑）。
- **反控（防「一律拒」）**：一个正常程序（如 `tests/suite/` 的既有语料）改后**仍须 rc=0**——否则「拒得对」与「一律拒」不可分。

---

## ⑥ 回退条件（可执行）

1. **S1–S4 任一步做不到「逐字节不变」** ⇒ **停下**，按「变的是哪一面」报裁（`.ccr` 变 vs ELF 变 vs 仅 canary 值变 ⇒ 处置不同）；
2. **canary 五条任一值变化且无法归因到「该步声明要变」** ⇒ **立即回退该步**（红线：不许自行重锁）；
3. **§⑤ 逐处表出现「能证 ⇒ 不能证」且未登记** ⇒ **本项红，回退该步**；
4. **正控由「被拒」变「通过」**（或反控由 rc=0 变非 0）⇒ **回退**；
5. **全量五档任一红** ⇒ 按既有纪律处置（先归因，再决定回退粒度）。

---

## ⑦ 与预期不符（本批实测）

1. **`region_check.cr` 零字节算术 ⇒ 它不是本批的消费者**（brief 把它列为消费方之一）。它的判定面是**区域与生命周期**（`g_pts`/`g_pa_alloc_nodes`/`g_sgs`），与「块内偏移」正交 ⇒ **Mapping 层分离不改变它的证明强度**（这条**降低了本批风险**）。
2. **`g_offsets` 全仓只有 1 个读者**（`provenance_verify`）· 3 个写点（`ptr_analysis`）⇒ **字节偏移这一面的扇入/扇出比预想小得多**。
3. **朴素 grep 的 `* 8` 绝大多数是编译器侧表跨步**（见 §②）⇒ 任何以「`* 8` 命中数」当工作量的估计**都会高估**；本批要求**先按 §② 判据筛过**再计数。
4. **`provenance_verify` 的 `-1` 兜底是验证强度的一部分**（「unknown ⇒ defer to runtime check」）——抽象化最容易在无意识中把它换成具体值，**这是本批最可能的静默损失点**。
5. **`type_size` 与 `type_align` 是两份平行硬编码表**（同形、各自 ~20/~12 个 return）⇒ 抽 Mapping 时**必须同时抽**，否则两表漂移（一类 `TYP_*` 在一个表里有、另一个表里落默认 8）。
6. **`IR_ARENA_NEW/RESET`（`ast.cr` 的 32/33）的归属待裁**：它到底是「宿主机器假设」（该降层）还是「语言语义单位」（不该降）——本批**不裁**，只登记。
7. **解释器对 arena 是 no-op 近似**（`interp.cr` 注释自陈「**interp 无 arena——no-op 近似**」）⇒ **两条腿（interp / ELF）在 arena 面上语义不同**，且**没有被任何既有判据覆盖**（我按「逐处实读」扫 `IR_ARENA_*` 的全部 7 档时才发现）⇒ **二档(a) 开工前必须先决定这条的处置**（否则「降层」会**顺手改变两条腿的一致性**而无人察觉）。
8. **`IR_ARENA_*` 的消费面是 7 档、11 处**（含**后端** `instr.cr` 与**中立核** `ent_kernel.cr`）⇒ 二档**不是「改一个 IR 节点」**，它横跨编译器/后端/中立核三层。

---

## 附：本批**未测**项（如实登记）

- 正控程序的具体**错误码**（未跑——只读批）；
- `interp.cr` 是否属本批（未逐处读）；
- 后端 `type_size` 使用点的**逐处清单**（未枚举）；
- 「抽象化后**运行时检查**的生成点是否仍存在」（`-1` 链路的运行期后果）——**未测**。
