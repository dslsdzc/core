# Mapping 层分离（Graph、Lattice、Mapping、Encoding 四层）：纸面计划

> 基线（pin）：`38e6c9923ea498d441b44f46e777acab3713b3e5`（现查的 `develop@origin`）。
> 取数纪律：一律使用 `jj --ignore-working-copy file show -r <pin>`，不以 bookmark 名当定位点。
> 性质：本文件只给出清单、形状与代价，不出代码；未改任何非本文档的文件。
> 口径：计数写「至少 N」并附清点命令；「确证」（本批实读或实际运行）与「待实测」分列。
> 动机（维护者原话）：「反正迟早都要重构的，还不如给他做完整」。因此不做「先插一个 seam」的半步，而是做整层分离。

---

## 1 泄漏面全枚举（起点不等于全集；本节为逐处实读后的结果）

方法论声明：`* 8` 这类模式的朴素 grep 会严重过计数（见第 2 节）。下表每一行都经人工按第 2 节检查归类后才列入。

| # | 站点（符号定位点） | 计数（至少） | 证的是什么 | 类别 |
|---|---|---|---|---|
| 1 | `src/compiler/provenance_verify.cr` · `get_alloc_size`：`IR_ALLOC_ARRAY 则 return s1 * 8`（注释自陈「元素恒 8 字节」） | 1 | 分配块的大小（供「访问偏移不超过块大小」比较） | 语义字节 |
| 2 | 同函数：`IR_ALLOC_STRUCT 则 si_field_count(fi) * 8`（注释「与 instr.cr IR_ALLOC_STRUCT 一致」） | 1 | 同上（struct 路径） | 语义字节 |
| 3 | `src/compiler/ptr_analysis.cr` · `IR_ADDR_INDEX` 分支：`w64(g_offsets, d*8, base_off + idx_val * 8)`（注释「常量索引可精确计算（`idx*8`）」） | 1 | 指针在块内的字节偏移（常量索引可精确计算，因此编译期可证） | 语义字节 |
| 4 | 同档 · `IR_SLICE` 分支：`offset = low*8`（注释原文） | 1 | 同上（切片基点） | 语义字节 |
| 5 | `src/compiler/ir_gen.cr` · `type_size(ti)`（定位点为 `fn type_size`） | ≥20 个 return 分支 | 目标类型的字节尺寸（`TY_INT` 为 8、`TY_DEX` 为 8、`TY_BOOL` 为 1、`TY_CHAR` 为 4、`TY_STRING` 为 8、`TYP_ARRAY` 为 elem×cnt 等） | 经典机器映射本体 |
| 6 | 同档 · `type_align(ti)` | ≥12 个 return 分支 | 目标类型的对齐（int/dex/string/ptr/ref/slice/named 为 8；bool 为 1；char 为 4） | 经典机器映射本体 |
| 7 | `src/compiler/ast.cr` · `IR_ARENA_NEW : 32`（`src1=size_estimate`）· `IR_ARENA_RESET : 33`（`src1=arena_id`） | 2 | IR 语义层里编码了 arena 模型（arena 是语义单位，不是主机机器细节，因此这条未必需要降层，见第 3 节注） | 语义节点（待裁） |
| 8 | `src/stdlib/goroutine.cr` · `stack := alloc(16384)`（注释「Allocate stack (16KB)」） | 1 | 固定 16KB 栈（主机栈尺寸假设） | 运行时假设 |
| 9 | `docs/maintainer/design/execution-model.md` 第 三 节（GMP 模型、固定 16KB、`fiber_switch`） | 文档面 | 把上两条写成设计 | 文档面 |

清点命令（可直接复制运行）：

```bash
DEV=$(jj --ignore-working-copy log -r develop@origin --no-graph -T 'commit_id')   # 取数定位：现查现用
jj --ignore-working-copy file show -r "$DEV" src/compiler/provenance_verify.cr | grep -nE '\* *8'
jj --ignore-working-copy file show -r "$DEV" src/compiler/ptr_analysis.cr     | grep -nE '\* *8'
jj --ignore-working-copy file show -r "$DEV" src/compiler/ir_gen.cr          | grep -n 'fn type_size\|fn type_align'
```

### 1.1 其它 pass 的同族核查（brief 未列，本批补充）

| 档 | 同族命中 | 结论 |
|---|---|---|
| `src/compiler/region_check.cr` | `g_pts`、`g_pa_alloc_nodes`、`g_sgs` 三条编译器侧表访问；零语义字节算术（其判定为区域与生命周期，与「块内偏移」正交） | 不是本批对象（与 brief 的假设不同，见第 7 节第 1 条） |
| `src/compiler/interp.cr` | 解释器有自己的槽宽假设（另一套表示） | 待实测（本批未逐处读；解释器是否属于 Mapping 层需单独裁） |
| `src/arch/` 下的全部文件（后端） | `type_size` 的使用点（帧布局、regalloc、宽度发射） | 消费者（第 3 节），不是泄漏面。后端本来就该知道字节 |

### 1.2 二档：执行策略泄漏（Arena 与 GMP，本批补充，brief 未列）

> 二档是「执行策略」层。它与一档（验证语义）不同：这一档泄漏的是「程序怎么执行」（区域生命周期、线程或协程模型、栈尺寸），不是「值怎么表示」。

(a) `Arena`：`IR_ARENA_NEW(32)` 和 `IR_ARENA_RESET(33)` 的全部消费点（7 档，逐处实读）：

| # | 站点 | 角色 | 备注 |
|---|---|---|---|
| 10 | `src/compiler/ast.cr`（`IR_ARENA_NEW : 32`、`IR_ARENA_RESET : 33`） | 定义 | `src1=size_estimate` / `src1=arena_id` |
| 11 | `src/compiler/ir_gen.cr`（`emit(IR_ARENA_RESET/NEW, …)`） | 生产者（4 处） | 函数入口与循环体内各一（注释「arena reused per iteration」） |
| 12 | `src/compiler/instr.cr`（`if op == IR_ARENA_NEW` / `IR_ARENA_RESET`） | 后端发射（2 分支） | 真正生成 arena 指令的唯一后端面 |
| 13 | `src/compiler/dataflow.cr`（`df_use_var` ×2 + DOT 名 `"arena_new"`） | HDFG 建模（3 处） | 把 arena 节点纳入数据流图 |
| 14 | `src/compiler/interp.cr`（`op2 == 32` / `op2 == 33`） | 解释器近似（2 处） | 注释自陈「interp 无 arena，no-op 近似」，因此解释器路径与 ELF 路径在此面语义不同（登记） |
| 15 | `src/compiler/opt.cr`（`if op == IR_ARENA_NEW/RESET { continue; }`） | 优化面跳过（2 处） | |
| 16 | `src/lattice/ent_kernel.cr`（`op == IR_ARENA_NEW 则 "ARENA_NEW"`） | 命名映射（1 处） | 中立核里的名字面（无行为） |

因此二档 (a) 的处置候选（不裁）：把 `IR_ARENA_NEW`/`IR_ARENA_RESET` 降成 `REGION_ENTER`/`REGION_EXIT` 或纯关系。必须登记一处现状：解释器对 arena 是 no-op 近似（上表 #14），因此任何「把 arena 降成关系」的改动都会同时改变「两条路径在 arena 面上是否一致」。这条未被任何既有检查覆盖（待实测）。

(b) `GMP`：文档面（维护者面，处置须单独询问）

| # | 站点 | 命中 | 性质 |
|---|---|---|---|
| 17 | `docs/maintainer/adr/adr-0017-concurrency-gmp.md` | 4（GMP、16KB、fiber_switch） | ADR，已决设计记录 |
| 18 | `docs/maintainer/design/execution-model.md` 第 三 节 | 7 | 维护者面设计文档 |
| 19 | `docs/maintainer/proposals/concurrency.md` | 1 | 提案面 |

代码面对应物（一档已列，此处交叉引用）：`src/stdlib/goroutine.cr` 的 `alloc(16384)`（16KB 栈）、`src/runtime/rt.s` 的 `fiber_switch`/`fiber_init`/`g_set_curg`（一档表外的运行时面）。

> 二档 (b) 的硬约束（team-lead 定）：`execution-model.md` 与 `adr-0017` 是维护者面的设计意图表述，改动它们等于改动设计意图的表述。因此该档处置必须单独询问维护者，本计划不得直接写成「改文档」。本节只登记位置与命中数。

### 1.3 三档：编译器自身实现绑定（登记，不动作）

`w64`/`r64` 的表访问、8 字节编译器记录（`ESZ_ASTNODE=72`/`ESZ_DFNODE`/`ESZ_TYPE_ROW`）、ELF 结构（`src/format/elf/*`）。按分析自己的话「暂时完全可以不管」，因此本计划只登记（第 2 节的检查已把它们与一档分开）。

---

## 2 同族甄别（本节最重要：防止把整批判歪）

### 为什么必须先做这一步

本次报告第一遍 grep 就把编译器的侧表跨步当成了「语义字节算术」（team-lead 也复述过同一问题）。原始 grep 的命中里大部分不是本批对象：

```bash
jj --ignore-working-copy file show -r "$DEV" src/compiler/ptr_analysis.cr | grep -cE '\* *8'   # 原始命中
```

其中表跨步（`alloc(nc * 8)`、`_dyncpy(g_pts, cap * 8, nb)`、`r64(g_pts, var * 8)`）全部不属于本批。它们描述的是「编译器自己的数组每个元素 8 字节」，与被编译程序的布局无关。两类混在同一屏、外形完全相同，因此必须给出检查。

### 检查（可机械判断，两问）

> 问基址：`* 8` 的基是不是编译器自己的表或缓冲？（`g_pts`、`g_offsets`、`g_pa_alloc_nodes`、`g_df_var_producer`、`g_sg_*`、`alloc(nc*8)` 的返回值等）
> 问因子：那个 `8` 代表的是被编译程序里某元素的字节宽，还是编译器记录的字节宽？

- 两问都指向「编译器自己」，则不属于本批（编译器运行在哪，不等于 Core 程序只能运行在哪）；
- 因子来自被编译程序的数量（数组长度 `s1`、字段数 `si_field_count(fi)`、目标类型 `ti`），则属于本批。

### 反例对照（至少一对「看起来一样但分属两侧」）

对照 A（同一档、同一函数、外形逐字相同 `s1 * 8`）：

| 行 | 代码 | 侧 |
|---|---|---|
| `provenance_verify.cr` 的 `get_alloc_size` | `return s1 * 8;  // count * 8` | 语义侧，`s1` 是被编译程序的数组元素个数，因此 8 是目标元素宽 |
| `provenance_verify.cr` 的 `IR_DEREF` 分支 | `pts := r64(g_pts, s1 * 8);` | 编译器侧，基址 `g_pts` 是编译器侧表（每 IR 变量一槽），`s1` 是 IR 变量号 |

对照 B（同一档、不同函数）：

| 行 | 代码 | 侧 |
|---|---|---|
| `ptr_analysis.cr` 的 `IR_ADDR_INDEX` | `base_off + idx_val * 8` | 语义侧，`idx_val` 是被编译程序的常量下标 |
| `ptr_analysis.cr` 的 `grow_pa_alloc_nodes` 族 | `nb := alloc(nc * 8);` | 编译器侧，扩容自己的表 |

因此一句话检查：看那个 `8` 乘的是「程序的量」还是「编译器的量」。基址是 `g_*` 侧表且索引是编译器槽号，则属于编译器侧。

### 另一条易混项（不属于本批，但读者会遇到）

`ESZ_ASTNODE = 72`、`ESZ_DFNODE`、`ESZ_TYPE_ROW` 这类记录跨步常量是编译器数据结构的布局，与目标程序布局无关，因此同属「编译器自己」。检查同上：问基址是否为 `g_ast`/`g_df_nodes`/`g_types`。

---

## 3 Mapping Contract 的形状

### 抽象侧是什么

不是数值，而是两个关系：

1. `extent : Entry 到 Q`，每个分配条目的尺寸量（`Q` 是不透明量，不是字节）；
2. `offset ∈ extent(entry)`，某指针指向该条目内的某个偏移（同样是不透明量），以及判定「偏移是否越界」所需的比较在同一 `Q` 域内可判定。

配套的第三条（现状由 `ir_gen::type_size` 承担）：`stride : Type 到 Q`，即「元素到尺寸量」的映射，供 `count × stride` 与 `field_count × stride` 使用（现状两处硬编码 8）。

### 它替换掉什么

| 现状（第 1 节站点） | 现在算的 | 抽象后 |
|---|---|---|
| `provenance_verify` 的 `s1 * 8` / `field_count * 8` | 字节大小 | `extent = count × stride(T)`（`stride` 来自 Mapping） |
| `ptr_analysis` 的 `idx_val * 8` / `low*8` | 字节偏移 | `offset = index × stride(T) + base`（同上） |
| `ir_gen::type_size/type_align` | 硬编码 `8/1/4` | Mapping 实例的数据（经典映射等于今天的值；非经典映射为另一套） |

### 谁消费它（实读后的角色划分）

| 角色 | 档 | 依据 |
|---|---|---|
| 生产者（偏移） | `ptr_analysis.cr`（写 `g_offsets`，3 个写点） | 实读：`w64(g_offsets, …)` ×3 |
| 唯一比较者 | `provenance_verify.cr`（读 `g_offsets`，1 个读点） | 实读：`g_offsets` 的读者全仓只有它（清点命令见第 1 节） |
| 尺寸/对齐提供者 | `ir_gen.cr::type_size/type_align`（以及后端使用点） | 实读 |
| 区域/生命周期（与字节面正交） | `region_check.cr`（`g_pts`/`g_pa_alloc_nodes`/`g_sgs`） | 实读：零字节算术 |
| 解析成字节 | 后端（`src/arch/x86_64/*` 的帧布局、regalloc、宽度发射） | 取证（未逐处枚举，待实测） |

### 经典映射在哪一步把它解析成字节

在后端选定的那一刻（target triple 为 `x86_64-linux`，因此使用 SysV ABI）：`Mapping.classic_x86_64` 提供 `stride(int)=8`、`size(bool)=1`、`align(char)=4` 等，即把今天 `type_size/type_align` 里的表原样搬进数据面。

### 非经典映射（GPU 或其它）不必回答同一个 `sizeof()`，它落在哪

落在同一个 Contract 的另一实例：

- GPU 的 `stride` 和 `extent` 可以不是字节（如「元素个数 × 每元素 lane 数」）；
- 只要 1 生产者（`ptr_analysis`）、2 比较者（`provenance_verify`）、3 尺寸提供者三方使用同一个 `Q`，`Q` 是字节还是别的量，对验证逻辑透明；
- 因此不需要让 GPU 回答「你的 `int` 几字节」，需要的是让「越界比较」在它的 `Q` 里可判定；
- 注意：`IR_ARENA_NEW/RESET`（第 1 节 #7）与 16KB 栈（第 1 节 #8）是否随之下层，待裁。arena 可能是语义单位（子图即生命周期域），下层的是它的容量表示。本文件不裁。

---

## 4 实施序与每步检查（每步可单独验收）

默认检查（除注明外）是逐字节不变：`.ccr` + ELF + canary 五条（`tools/baseline/canary_check.sh` 5/5，且与固定值逐字节相同）+ D1 确定性门禁 5 条。

| 步 | 内容 | 检查 | 变了要有理由 |
|---|---|---|---|
| S1 | 把 `ir_gen::type_size/type_align` 的常量抽成命名数据表（Mapping 经典实例），函数体改读表 | 逐字节不变（纯重构，行为零变化） | 不允许变 |
| S2 | 把 `provenance_verify` 的 2 处 `* 8` 改走 `extent`/`stride` 接口 | 逐字节不变 + 第 5 节逐处证明表更新 | 不允许变 |
| S3 | 把 `ptr_analysis` 的 2 处（`idx*8` / `low*8`）改走同一接口 | 同上 | 不允许变 |
| S4 | Mapping 实例化点落位（target triple 到实例），后端显式取 `stride/size/align` | 逐字节不变 | 不允许变 |
| S5 | 文档面（`execution-model.md` 第 三 节、`IR_ARENA_*` 的语义注记）+ 非经典映射的空实例登记 | 文档一致性 + 全量层 | |
| S6 | 完成：全量五档 + canary + 第 5 节复核 | 五档 rc=0 + canary 5/5 + 第 5 节零未登记损失 | |

每步的回退点就是该步的提交。S1–S4 全部要求「逐字节不变」，因此回退没有产物风险。

### 4.1 三档的实施排序（team-lead 倾向：一档到二档；三档只登记不动）

| 档 | 范围 | 排期 | 前置 |
|---|---|---|---|
| 一（验证语义） | S1–S4（第 1 节 #1–#6） | 先行 | 无（S1 即可开始实施） |
| 二（执行策略） | Arena（#10–#16）、GMP 代码面（`goroutine.cr` 16KB、`rt.s` fiber 族） | 一档之后 | 二档 (b) 的文档面须先询问维护者（ADR 和 design 是设计意图表述）；二档 (a) 的 arena 降层须先解决「解释器 no-op 近似」的一致性面（第 1 节 1.2 小节 #14） |
| 三（编译器自身） | `w64/r64` 表访问、8 字节记录、ELF 结构 | 只登记，不动 | 分析自陈「暂时完全可以不管」 |

排序理由是依赖关系，不是工作量：一档的产物（`extent`/`stride` 的 `Q` 域）是二档的前置，Arena 的容量表示最终也要在同一 `Q` 域里说清。反过来先做二档，会在 `Q` 未定时先定 capacity 的表示，属于过早决定。

二档不得并入一档的步骤，必须独立批次验收：一档的默认检查是「逐字节不变」，而二档的 arena 降层很可能有意改变 IR 形态，因此检查不同，批次必须分开。

---

## 5 硬性验收项：验证强度不得净减

> 改前能证的，改后要么仍能证，要么显式登记为「已知不再能证」并给出理由。

为什么必须有这一项：把字节偏移抽象化，最危险的形态不是编不过，而是证明变弱了却没人发现，与 S6 那一类问题同属不报错地。

### 5.0 首条（本批唯一「一改就弱、且不会失败」的点）

> 既有后备不得丢失：`provenance_verify.cr::get_alloc_size` 末尾的 `return -1;  // unknown (defer to runtime check)`，以及 `ptr_analysis.cr` 的「运行时索引，因此写 `-1`」，都是有意设计，不是「没写」。

(a) `-1` 的语义（实施时必须原样保留）：「这里证不了，因此交给运行时」。这是编译期静态证明的诚实退让，由运行期检查后备。

(b) 为什么它是本批的底线：抽象化天然会「少证一点」，而少证不会失败。`-1` 是这个批次里唯一已经显式写出来的「少证」，保住它等于保住本批的底线。反之，把 `-1` 换成任何具体值（或换成「不写」）都是净减且不报错地。

(c) 断言要断言到「走了哪条路」，不能只断 rc：构造一个会落进 `-1` 分支的输入（运行时索引或未知分配），改后必须仍落进它。

- 检查形态为断言路径，例如该变量的 offset 槽仍为 `-1`，或该分配的 size 查询仍返回 `-1`。不得只断言 `rc=0`，rc 对「不报错地退化」不敏感；
- 反控：同一批里必须有一个走具体值分支的输入（常量索引）仍走具体值，否则「一律回 `-1`」也会让断言全部通过，两个方向都要检查。

### 5.1 两条路径（interp 与 ELF）在地址和 arena 面已有可观测差异

性质：这是既有分歧，不是本批引入。但本批（二档）可能改变它的可见性，因此必须算进强度表。至于该不该对齐，不是本批的事；本计划只给观测，不裁对错。

观测方法（最小、两条路径可运行、rc 即读数）：`corec run <内联源码>` 的 rc 等于 `main` 的返回值。已自证：`return 42` 时 rc=42。

```core
fn main() -> int:
    i : ., mut = 0
    prev : ., mut = 0
    gap : ., mut = 0
    loop:
        if i >= 3:
            break
        s := alloc(8)
        p : ., mut = 0
        unsafe:
            p = @ptr_of(s)
        if i > 0:
            gap = p - prev
        prev = p
        i = i + 1
    return gap
```

实测读数（本批实际运行，不是注释转述）：

| 探针 | interp 路径（`corec run`） | ELF 路径（`corec build --static` + 执行） |
|---|---|---|
| 上式（三次 `alloc(8)` 的末次距离） | rc = 0 | rc = 16 |
| 单次 `alloc(8)` 的 `@ptr_of` 是否为 0 | 是（rc=7 分支：地址 = 0） | 否（距离 16 非 0，故地址非 0） |
| 自证 rc 通道 | `main` 返回 42，因此 rc=42 | |

因此观测成立：两条路径输出不同，分别为 0 和 16。

定界说明（如实登记，不要过度解读）：本探针证明的是「两条路径在地址和 arena 面可区分」，不是「差异的成因是 arena no-op」。interp 侧 `@ptr_of(s)` 恒为 0（与「interp 的串是 intern 索引，不是地址」一致），该事实本身已足以造成本差异。因此「arena no-op」与「无地址概念」两条成因，本探针未分离（待实测或待裁）。`interp.cr` 注释自陈「interp 无 arena，no-op 近似」是注释，与上表读数分开看待。

逐处表（本批已填「改前」列；「改后」列由实施方填写）：

| # | 站点 | 改前证什么（实读） | 改后证什么（待填） |
|---|---|---|---|
| 1 | `get_alloc_size` `IR_ALLOC_ARRAY` | 块大小 = `count × 8`，因此与偏移比较可判越界 | ? |
| 2 | 同上 `IR_ALLOC_STRUCT` | 块大小 = `字段数 × 8` | ? |
| 3 | `ptr_analysis` `IR_ADDR_INDEX` | 常量索引可精确算偏移，因此编译期可证；运行时索引写 `-1`，「迫使 `provenance_verify` 生成运行时检查」 | ? |
| 4 | 同上 `IR_SLICE` | `low*8`（常量时）；非常量时写 `-1` | ? |

不得丢失的既有后备见 5.0 节。此处保留交叉引用，避免读者漏读。

两条控制组（缺一不可）：

- 正控：一个已知会被 `provenance_verify` 拒绝的程序，改后仍须被拒绝，并断言到具体错误码（错误码待实测；本批只读，未运行）。
- 反控（防止「一律拒绝」）：一个正常程序（如 `tests/suite/` 的既有语料）改后仍须 rc=0，否则无法区分「拒得对」与「一律拒绝」。

---

## 6 回退条件（可执行）

1. S1–S4 任一步做不到「逐字节不变」，则停下，按「变的是哪一面」报裁（`.ccr` 变、ELF 变、仅 canary 值变，处置不同）；
2. canary 五条任一值变化，且无法归因到「该步声明要变」，立即回退该步。硬性约束：不许自行同步更新；
3. 第 5 节逐处表出现「能证变为不能证」且未登记，本项失败，回退该步；
4. 正控由「被拒」变为「通过」，或反控由 rc=0 变为非 0，回退；
5. 全量五档任一失败，按既有纪律处置（先归因，再决定回退粒度）；
6. 二档任何一步若改变了两条路径在第 5.1 节观测上的关系（`corec run` 的 rc 与 ELF 路径的 rc 由「0 与 16」变成别的关系）且未登记，则停，登记前不得继续。即使新关系「看起来更一致」也停，「顺带对齐」同样是未经裁决的状态变更。

---

## 7 与预期不符（本批实测）

1. `region_check.cr` 没有字节算术，因此它不是本批的消费者（brief 把它列为消费方之一）。它的判定面是区域与生命周期（`g_pts`/`g_pa_alloc_nodes`/`g_sgs`），与「块内偏移」正交，因此 Mapping 层分离不改变它的证明强度。这条降低了本批风险。
2. `g_offsets` 全仓只有 1 个读者（`provenance_verify`）和 3 个写点（`ptr_analysis`），因此字节偏移这一面的扇入和扇出比预想小得多。
3. 朴素 grep 的 `* 8` 绝大多数是编译器侧表跨步（见第 2 节），因此任何以「`* 8` 命中数」当工作量的估计都会高估。本批要求先按第 2 节检查筛过再计数。
4. `provenance_verify` 的 `-1` 后备是验证强度的一部分（「unknown，因此 defer to runtime check」）。抽象化最容易在无意识中把它换成具体值，这是本批最可能的不报错地损失点。
5. `type_size` 与 `type_align` 是两份平行的硬编码表（同形，各自约 20 和 12 个 return），因此抽 Mapping 时必须同时抽，否则两表变化（一类 `TYP_*` 在一个表里有、另一个表里落默认 8）。
6. `IR_ARENA_NEW/RESET`（`ast.cr` 的 32/33）的归属待裁：它到底是「主机机器假设」（该降层）还是「语言语义单位」（不该降）。本批不裁，只登记。
7. 解释器路径与 ELF 路径在地址和 arena 面的可观测差异，本批实测为 `0` 与 `16`。该条属于既有差异且零检查覆盖，按 team-lead 裁定移出本节，列为第 5 节的并列项，强度表要把它算进去。
8. `IR_ARENA_*` 的消费面是 7 档、11 处（含后端 `instr.cr` 与中立核 `ent_kernel.cr`），因此二档不是「改一个 IR 节点」，它横跨编译器、后端、中立核三层。

---

## 附：本批未测项（如实登记）

- 正控程序的具体错误码（未运行，只读批）；
- `interp.cr` 是否属于本批（未逐处读）；
- 后端 `type_size` 使用点的逐处清单（未枚举）；
- 「抽象化后运行时检查的生成点是否仍存在」（`-1` 链路的运行期后果），未测。
