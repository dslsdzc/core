# Core IR 操作语义表（对照 CompCert x86/Op.v + Asm.v）

> 定位：受众 = 维护者；状态 = active

> 用途：CompCert 对照审查第四轮（2026-08-16）的**契约文档**——Task 2 后端审查逐 opcode 三方对照
> （本表定义语义 vs `src/arch/linux/ld/instr.cr` ELF 编码 vs `src/compiler/interp.cr` 解释执行）以本表为准。
> 本任务纯只读：**不修改任何 Core 代码**；`~/compcert/` 为只读真源，绝不修改。
> 差异标注约定：**D** = Core 有意不同于 CompCert（附设计理由）；**BC** = 可疑/bug 候选（Task 2 核实对象）。
> **状态（2026-08-17 → 2026-09）**：第四轮修复已完成并合入（F1-F20）——本表已同步修复后状态
> （「[ok] 已修复」标记），BC 表转为修复记录参考；D 表为设计差异，不受修复影响。
> **2026-09 更新注记**：① int 语义定稿为无上限数学整数(2026-08-23 起)——§1 的 64 位契约是**编码层快路径投影**,超界 = 编码层事务(见 adr/adr-0002 语境与 plans/2026-09-06-int-multiword-m1);② .ccr v6 NOD 坐标化(本表 instr 引用 = v5 线性形态,语义不变);③ 规约语法定稿 #check/#ensure。
> 修复记录见 `docs/archive/compcert-reference.md`「第四轮修复记录（2026-08-17）」；本表末尾「修复记录」小节汇总。

## 0. 真源与引用

| 文件 | 内容 | 引用格式 |
|---|---|---|
| `~/compcert/x86/Op.v` | 运算/条件/寻址模式的数学语义（`eval_operation`/`eval_condition`/`eval_addressing`） | Op.v:L275 |
| `~/compcert/x86/Asm.v` | 每条 x86 指令的小步语义（`exec_instr`）、标志模型（`compare_*`）、内存访问（`exec_load`/`exec_store`） | Asm.v:L610 |
| `~/compcert/common/Values.v` | 值的运算定义（`divs`/`addf`/`longoffloat`…） | Values.v:L405 |
| `~/compcert/lib/Integers.v` | 机器整数公理与定义（`Int64.divs = Z.quot` 等） | Integers.v:L193 |
| `~/compcert/lib/Floats.v` | IEEE 754 浮点定义（`to_long`/`of_long`） | Floats.v:L304 |
| `~/compcert/common/Memory.v` | 内存模型（`valid_access`/`load`/`store`） | Memory.v:L220 |

Core 侧只读来源：`src/compiler/ast.cr`（opcode 常量，L527-580）、`src/compiler/ir_gen.cr`（发射约定）、
`src/compiler/interp.cr`（解释执行现状）、`src/arch/linux/ld/instr.cr`（ELF 编码现状）、
`src/compiler/provenance_verify.cr` + `ptr_analysis.cr`（DEREF/STORE_PTR 运行时检查元数据填充）、
`src/runtime/rt.s`（bump 分配器）、`docs/superpowers/specs/2026-08-16-numeric-types-design.md`（dex/apx 设计）。

## 1. 表示法与状态模型

- **状态** `σ = (ρ, M, ctrl)`：`ρ` = 变量环境（IR 变量 → 64 位值槽）；`M` = 字节寻址内存（堆/栈/rodata）；
  `ctrl` = 控制流位置（解释器：节点游标 + 标签表；ELF：PC）。
- **int**(2026-08-23 定稿后)= 无上限数学整数:本表的 64 位二补语义是**编码层快路径投影**(i64 快路径,超界 = 编码层事务:溢出自动升级,见 plans/int-multiword-m1);验证层数学语义与编码层投影的分离见 spec-design §9.4。**本契约表以编码层(ELF 实际发射)为基准**,与 CompCert `Int64` 位向量对照仍成立——编码层投影正确性 = 数学语义的映射实例(见 academic/cache-semantics.md 条款 7)。
- **dex**（迁移目标）= 精确小数，定点表示：`v ∈ ℚ` ↔ 缩放整数 `⌊v·10⁶⌋`（S = 10⁶）。见 §4。
  > 注：设计文档（numeric-types-design.md）只定「缩放整数/定点实现、精度内置」，**未定缩放系数**——S = 10⁶ 是本契约的显式决策（十进制直觉、i64 内余量充足），迁移实现须以本表为准。
- **apx** = 近似授权（变量级标签）；CPU 兑现 = binary64（IEEE 754）快路径。当前 `TI_FLOAT` 路径即其前身实现。
- **错误形态**：Core 选择**硬陷阱中止**——`ud2`（SIGILL，越界/检查失败）或 `idiv #DE`（SIGFPE，除零/溢出），
  分配失败 → null。CompCert 选择**定义良好的错误值** `None`（`eval_operation`）→ `Stuck`（Asm 小步）。
  语义等价于「此路径无定义行为且程序中止」，但 Core 不在 IR 层显式表达错误值。
- 无符号比较：Core IR 无显式无符号比较 opcode（int 比较全按有符号 64 位，对照 CompCert `Ccompl`）；
  无符号语义仅以 `jb`/`jae` 技巧出现在边界检查中（§2.4 IR_BOUNDS_CHECK）。

## 2. Opcode 全清单

`ast.cr` L527-580 定义 0-50（**40 号空缺未定义**），加规划中的 `IR_APPROX = 51`（dex/apx 设计，尚未入 ast.cr）——
**共 51 个 opcode 条目**（50 个已定义 + 1 个规划）。`IR_RESOLVED`（L580）是 BRANCH/JUMP 的标签解析标记，非 opcode。

| # | 名称 | 分组 | 发射方 | ELF 后端 | 解释器 | 本节 |
|---|---|---|---|---|---|---|
| 0 | IR_NOP | 控制流 | — | ✓ 空 | ✓ 空 | 2.5 |
| 1 | IR_CONST | 常量 | ir_gen | ✓ | ✓ | 2.1 |
| 2 | IR_BINARY | 算术 | ir_gen | ✓ | ✓（部分） | 2.2 |
| 3 | IR_UNARY | 算术 | ir_gen | ✓ | ✓ | 2.2 |
| 4 | IR_CALL | 调用 | ir_gen | ✓ | ✓（单层内联） | 2.5 |
| 5 | IR_RETURN | 调用 | ir_gen | ✓ | ✓ | 2.5 |
| 6 | IR_ALLOC | 内存 | ir_gen（标量槽标记） | ✓ 空 | ✓ 置 0 | 2.4 |
| 7 | IR_ALLOC_STRUCT | 内存 | ir_gen | ✓ | ✓ | 2.4 |
| 8 | IR_ALLOC_ARRAY | 内存 | ir_gen | ✓ | ✓ | 2.4 |
| 9 | IR_STORE | 拷贝（命名误导） | ir_gen | ✓ | ✓ | 2.1 |
| 10 | IR_LOAD | 拷贝 | ir_gen | ✓ | ✓ | 2.1 |
| 11 | IR_LOAD_FIELD | 内存 | ir_gen | ✓ | ✓ | 2.4 |
| 12 | IR_STORE_FIELD | 内存 | ir_gen | ✓ | ✓ | 2.4 |
| 13 | IR_LOAD_INDEX | 内存 | ir_gen | ✓ | ✓ | 2.4 |
| 14 | IR_STORE_INDEX | 内存 | ir_gen | ✓ | ✓ | 2.4 |
| 15 | IR_LOAD_INDEX_VAR | 内存 | ir_gen | ✓ | ✓ | 2.4 |
| 16 | IR_STORE_INDEX_VAR | 内存 | ir_gen | ✓ | ✓ | 2.4 |
| 17 | IR_MAKE_ENUM | 枚举 | ir_gen | ✓ | ✓（近似） | 2.6 |
| 18 | IR_REF | 地址 | ir_gen | ✓ | ✓（近似） | 2.4 |
| 19 | IR_BRANCH | 控制流 | ir_gen | ✓ | ✓ | 2.5 |
| 20 | IR_JUMP | 控制流 | ir_gen | ✓ | ✓ | 2.5 |
| 21 | IR_LABEL | 控制流 | ir_gen | ✓ | ✓ | 2.5 |
| 22 | IR_PHI | 控制流 | **无**（保留） | ✗ | ✗ | 2.5 |
| 23 | IR_LOAD_ENUM_TAG | 枚举 | ir_gen | ✓ | ✓（近似） | 2.6 |
| 24 | IR_SLICE | 内存 | ir_gen | ✓ | ✓（BC11 已修补实现） | 2.4 |
| 25 | IR_DEREF | 内存 | ir_gen | ✓ | ✓（近似） | 2.4 |
| 26 | IR_STORE_PTR | 内存 | ir_gen | ✓ | ✓（近似） | 2.4 |
| 27 | IR_SPAWN | 并发 | ir_gen | ✓（单线程近似） | ✓（单层） | 2.7 |
| 28 | IR_YIELD | 并发 | ir_gen | ✓（eager 值传递近似，BC8/F5 已修） | ✓ | 2.7 |
| 29 | IR_AWAIT | 并发 | ir_gen | ✓（eager） | ✓（eager） | 2.7 |
| 30 | IR_BOUNDS_CHECK | 内存/安全 | ext_safety | ✓ | ✓（BC11 已修补实现） | 2.4 |
| 31 | IR_ADDR_INDEX | 地址 | ir_gen | ✓ | ✓（BC11 已修补实现） | 2.4 |
| 32 | IR_ARENA_NEW | 内存 | ir_gen | ✓ | ✓（no-op 近似，BC11 已修） | 2.4 |
| 33 | IR_ARENA_RESET | 内存 | ir_gen（作用域退出） | ✓ | ✓（no-op 近似，BC11 已修） | 2.4 |
| 34 | IR_INLINE | 注解 | ir_gen | 空 | 空 | 2.9 |
| 35 | IR_NO_BOUNDS_CHECK | 注解 | ir_gen | 空 | 空 | 2.9 |
| 36 | IR_FAST | 注解 | ir_gen | 空 | 空 | 2.9 |
| 37 | IR_UNROLL | 注解 | ir_gen | 空 | 空 | 2.9 |
| 38 | IR_SECTION | 注解 | ir_gen | 空 | 空 | 2.9 |
| 39 | IR_HOTPATCH_ROUTE | 调用 | ir_gen | ✓ | ✗ | 2.5 |
| 40 | *（未定义）* | — | — | — | — | — |
| 41 | IR_DYN_TAG | 动态 | ir_gen | ✓ | ✗ | 2.6 |
| 42 | IR_DYN_VAL | 动态 | ir_gen | ✓ | ✗ | 2.6 |
| 43 | IR_DYN_PACK | 动态 | ir_gen | ✓ | ✗ | 2.6 |
| 44 | IR_DYN_DISPATCH | 动态 | ir_gen | ✓（占位） | ✗ | 2.6 |
| 45 | IR_CALL_EXTERN | 调用 | ir_gen | ✓ | ✗ | 2.5 |
| 46 | IR_LAZY_THUNK | 惰性 | ir_gen | ✓（eager） | ✓（eager） | 2.7 |
| 47 | IR_LAZY_FORCE | 惰性 | ir_gen | ✓（eager） | ✓（eager） | 2.7 |
| 48 | IR_FNADDR | 地址 | ir_gen | ✓ | ✓（d=0） | 2.5 |
| 49 | IR_I2F | 转换 | ir_gen | ✓（[注意] 见 BC-I2F） | ✗ | 2.3 |
| 50 | IR_F2I | 转换 | ir_gen | ✓ | ✗ | 2.3 |
| 51 | IR_APPROX | 注解（规划） | —（迁移时加入） | — | — | 2.9 |

对照 CompCert：Core 的「opcode + 操作数槽（dest/src1/src2/src3/type_kind）」形态对应 RTL 的 `Iop`（3 地址）
与 Asm 的 `instruction` 之间的中间层——语义表以 Asm.v 的机器语义为基准（opcode 最终由机器指令兑现），
算术层语义以 Op.v 的 `eval_operation` 为基准。

## 3. 分组语义定义

记法：`a` = `ρ(s1)`、`b` = `ρ(s2)`（变量取值）；`d` = dest 变量；`M[x]` = 内存 `x` 处 8 字节；
`→` = 状态变换；`⊥` = 中止（陷阱）。

### 2.1 常量与拷贝（对照 Op.v 常量/Omove）

- **IR_CONST**（1）：`d := s1`（立即数）。`type_kind` 决定解释：`TI_STR` → `d` = rodata 字符串基址
  （ELF 经 `lea r10,[rip+disp]` 补丁；对照 CompCert `Pmov_rs` Asm.v:L619-620 / `Oindirectsymbol` Op.v:L352）；
  `TI_FLOAT` → `d` = 位模式/定点缩放值。对照 `Olongconst`/`Ofloatconst`（Op.v:L76-78, 349-351）。
  **BC-CONST**：interp 对 `TI_STR` 存字符串表索引而非指针（无法做字符串操作）——解释器已知局限。
- **IR_LOAD**（10）：`d := ρ(s1)`——**变量取值拷贝**（含全局变量经 RIP 相对寻址，对照 Core 的 RIP 补丁机制；
  对标 CompCert `Pmovq_rm` Asm.v:L623-624 但无内存读取——名称误导，见 2.1 组注）。对照 `Omove` Op.v:L347。
- **IR_STORE**（9）：`ρ(s1) := ρ(s2)`——**变量赋值**（同样不是内存操作）。对照 `Omove`。
  > 组注：`IR_LOAD`/`IR_STORE` 在 Core 中是「槽间拷贝」，真正的内存操作是 FIELD/INDEX/DEREF 族——
  > 与 CompCert 的 load/store 命名不同，属 Core 的 IR 形态设计（D：扁平槽模型，全局/局部统一）。

### 2.2 算术（对照 Op.v eval_operation + Asm.v 整数算术）

`IR_BINARY`（2）按 `s3 = OP_*` 分派；`IR_UNARY`（3）按 `s3 = UOP_*` 分派。`type_kind = TI_FLOAT` 时走浮点路径（见下）。

| OP_* (s3) | 语义（int 路径，64 位模 2⁶⁴） | 对照 CompCert |
|---|---|---|
| OP_ADD 1 | `d := (a + b) mod 2⁶⁴`（回绕） | `Val.addl`（`Oaddlimm` Op.v:L391；`Paddq_ri` Asm.v:L709-710）——同为模 2⁶⁴ |
| OP_SUB 2 | `d := (a − b) mod 2⁶⁴` | `Val.subl`（`Osubl` Op.v:L392；`Psubq_rr` Asm.v:L713-714） |
| OP_MUL 3 | `d := (a · b) mod 2⁶⁴`（低 64 位） | `Val.mull`（`Omull` Op.v:L393；`Pimulq_rr` Asm.v:L717-718） |
| OP_DIV 4 | `d := trunc(a/b)`（**向零截断**）；`b=0` 或 `a=min_signed ∧ b=−1` → `⊥`（idiv #DE → SIGFPE） | `Val.divls`（Values.v:L727-735）：除零/`min_signed/−1` → `None`（Stuck），否则 `Int64.divs = Z.quot`（向零，Integers.v:L193）。**abort 形态一致** |
| OP_MOD 5 | `d := a − trunc(a/b)·b`（余数符号随被除数）；同 DIV 的 `⊥` 条件 | `Val.modls`（Values.v:L737-745）：`Int64.mods = Z.rem`（Integers.v:L195） |
| OP_EQ 6 | `d := (a = b) ? 1 : 0` | `Ccompl Ceq`（Op.v:L45, L281-282）→ `Val.cmpl_bool`；Asm 层 `compare_longs` ZF（Asm.v:L439-444）+ `Cond_e`（Asm.v:L481-485） |
| OP_NE 7 | `d := (a ≠ b) ? 1 : 0` | `Ccompl Cne`；`Cond_ne` |
| OP_LT 8 | `d := (a <ₛ b) ? 1 : 0`（**有符号**） | `Ccompl Clt`；Asm 层 `Cond_l = OF≠SF`（Asm.v:L511-515）——ELF 用 `setl` ✓ |
| OP_GT 9 | `d := (a >ₛ b) ? 1 : 0` | `Ccompl Cgt`；`Cond_g`（Asm.v:L526-530）——ELF `setg` ✓ |
| OP_LE 10 | `d := (a ≤ₛ b) ? 1 : 0` | `Ccompl Cle`；`Cond_le`（Asm.v:L516-520）——ELF `setle` ✓ |
| OP_GE 11 | `d := (a ≥ₛ b) ? 1 : 0` | `Ccompl Cge`；`Cond_ge`（Asm.v:L521-525）——ELF `setge` ✓ |
| OP_AND 12 | `d := (a≠0 ∧ b≠0) ? 1 : 0`（逻辑与，**非短路**；域 = 0/1） | 无直接对照——CompCert C 的 `&&` 在前端分支化，IR 层无布尔运算 |
| OP_OR 13 | `d := (a≠0 ∨ b≠0) ? 1 : 0`（逻辑或，非短路） | 同上 |
| OP_SHL 15 | `d := a << (b mod 64)`（x86 cl 掩码）——**当前无发射方**（死路径，见 BC3） | `Oshll` Op.v:L408-409 → `Val.shll`（Values.v:L797-802：`Int.ltu n2 Int64.iwordsize'` 守卫，越界 → `Vundef`）；Asm 层 `Psalq_rcl` Asm.v:L809-810——**D：Core 硬件掩码 vs CompCert 未定义** |
| OP_SHR 16 | `d := a >>ₗ (b mod 64)`（ELF 用 `shr` = **逻辑右移**）——当前无发射方 | `Oshrl` Op.v:L410-411 = **算术右移**（`Val.shrl`，Values.v:L806-813：`Int64.shr'` 算术右移）；`Pshrq_rcl` Asm.v:L817-818 是逻辑。**BC3（死路径已确认，第四轮 §2）：若将来发射，需定语义（Core 无无符号类型，`>>` 语义悬空）** |
| OP_PTR_ADD 17 | `d := (a + 8b) mod 2⁶⁴`（指针 + 元素数，元素 8 字节） | 寻址计算：`Oleal`/`Aindexed2scaled`（Op.v:L327-328, L416；Asm.v:L701-702） |
| OP_PTR_SUB 18 | `d := (a − 8b) mod 2⁶⁴` | 同上（负偏移） |
| OP_PTR_DIFF 19 | `d := floor((a−b)/8)`（元素数；ELF 用 `sar` 算术右移 = **向下取整（floor）非向零截断**，仅在差为 8 倍数时等价——实际发射场景恒满足，无发散） | 无精确对照（CompCert 指针差为 builtin `__builtin_ptrdiff`）；`Osub`+移位组合 |

`IR_UNARY`（3）：

- `UOP_NEG` 1：`d := (−a) mod 2⁶⁴`。对照 `Onegl`（Op.v:L390）`Val.negl`；`Pnegq`（Asm.v:L705-706）。
- `UOP_NOT` 2：`d := (a = 0) ? 1 : 0`——**逻辑非**（非按位非）。对照 `Onotl`（Op.v:L407）是**按位**非——**D：Core 无双关按位非 opcode**（不需要）。

**浮点路径**（`type_kind = TI_FLOAT`，当前实现 = apx 快路径 binary64；迁移后 = dex 见 §4）：

- OP_ADD..OP_DIV：`d := a ⊕ b`（IEEE 754 `addsd/subsd/mulsd/divsd`）。对照 `Oaddf..Odivf`（Op.v:L419-422）→ `Val.addf`（Values.v:L538,556）→ IEEE binary64（`Bplus/Bminus/Bmult/Bdiv`，mode_NE 就近舍入）；Asm 层 `Paddd_ff` 等（Asm.v:L865-872）。
- OP_EQ..OP_GE：`comisd` + 无符号 setcc（`sete/setne/setb/seta/setbe/setae`）。对照 Asm.v `compare_floats`（L453-463）：ZF = (x=y ∨ 无序)，CF = ¬(x≥y)（= x<y ∨ 无序），PF = 无序。
  - `OP_EQ → sete(ZF)`：NaN 时得 **1**。CompCert `Ccompf Ceq`（Op.v:L49, 285）：Op.v 层 `Val.cmpf_bool` 对 NaN 返回 **`Some false`**（IEEE 语义，Values.v L928-931）而非 `None`（`None` 仅出现在非 float 值输入）；机器层分歧在 `compare_floats` 无序时 ZF=1，Asmgen 用 `Cond_and Cond_np Cond_e`（Asmgen.v L260 = `setnp` ∧ `sete`）落地 IEEE 语义——**NaN 时 == 为 false**。**BC-FCMP [ok] 已修复（2026-08-17，第四轮 F8）：ELF 的 `==`/`!=` 已改 `setnp+sete` / `setp+setne` 组合（instr.cr L495-503，对照 Asmgen.v L260）**。dex 无 NaN（全序），不受影响。
  - `OP_LT → setb(CF)` / `OP_GE → setae(CF=0)` / `OP_LE → setbe(CF∨ZF)` / `OP_GT → seta(CF=0∧ZF=0)` 与 CompCert `Cond_b/ae/be/a`（Asm.v:L491-510）一致（含无序时 LT/LE 为真——与 CompCert 相同的硬件语义）。

**BC2 [ok] 已修复（2026-08-17，第四轮 F10）——整数除/模截断方向三方已统一为向零截断**：
- ELF 后端：`idiv` → 向零截断（与 CompCert `Z.quot` 一致）✓
- Python bootstrap 解释器（`bootstrap/corec/backend/interpreter.py`）：**已修**——`//` 改 abs+符号向零截断、`%` 余数符号随被除数（修复前 Python `//` = 向下取整（-7/3 = -3，C 为 -2）、`%` 余数符号随除数——与 Core 的 C 语义不一致）；`tests/bootstrap/test_pipeline.py` 补四组负操作数回归用例（-7/3、7/-3、-7%3、7%-3）
- 自托管 interp.cr 的 `lv / rv` 行为取决于承载二进制：经 ELF 构建 → 向零；经 Python bootstrap 跑测试 → 向下（修复后一致）。
- 契约定为：**向零截断**（对照 CompCert）。

### 2.3 转换（对照 Op.v 转换族）

- **IR_I2F**（49）：`d := float(int64(a))`。对照 `Ofloatoflong`（Op.v:L169, L438）→ `Val.floatoflong` = `Float.of_long`（Floats.v:L318-320：`BofZ` 53 位二进制浮点，就近舍入）。ELF 编码现状：`F2 48 0F 2A`（`cvtsi2sd`，**REX.W 已补——BC-I2F [ok] 已修复（2026-08-17，第四轮 F7）**，`e2_sd_cvt` instr.cr L378-389）。修复前为 `F2 0F 2A`（32 位操作数）只转换低 32 位符号扩展，`|a| ≥ 2³¹` 时结果错误（如 `2⁴⁰ → 0.0`），与 `IR_F2I` 的 `cvttsd2si` `F2 48 0F 2C`（REX.W ✓）不对称。迁移后语义：int→dex = `d := a·10⁶`（精确，无舍入）。
- **IR_F2I**（50）：`d := trunc(f)`（向零截断）。对照 `Olongoffloat`（Op.v:L167, L437）→ `Val.longoffloat` = `Float.to_long`（Floats.v:L308-309：`ZofB_range` 向零截断，**越界 → None**）。当前 ELF 用 `cvttsd2si`：向零截断 ✓，但**越界结果是硬件哨兵 0x8000000000000000**（Intel SDM：异常掩码默认下越界 `cvttsd2si` 返回不定值 INT64_MIN——文档化行为）——CompCert 定义为 `None`（Stuck）。**BC-F2I（死路径已确认，第四轮 §2）：IR_F2I 无发射方（语言级 float→int 转换不存在），当前不可触发**；若将来启用需定越界语义。迁移后语义：dex→int = `d := trunc(a/10⁶)`（有损转换，`EC_R_LOSSY_CONVERT` R004 检查点）。
- interp：op 49/50 **已实现**（`i64_to_f64`/`f64_to_i64`，f64.cr 软件路径，BC11 已修）——原「静默跳过」见 BC11（已修复）。

### 2.4 内存与地址（对照 Memory.v 模型 + Asm.v 访问指令）

分配（对照 CompCert `Pallocframe`（Asm.v:L948-958）/`Mem.alloc`（Memory.v:L348）——L531 是 `store`，勿误引）：

- **IR_ALLOC**（6）：标量变量槽标记——后端不发射代码（栈槽由帧布局分配）；interp 置 `d := 0`。CompCert 无对照（帧是伪指令级概念）。
- **IR_ALLOC_STRUCT**（7）：`d := alloc(fc·8)`——`fc` = 结构体字段数（`s3` = 结构体名 ni）；返回零初始化堆块（rt.s L72-103：8 字节长度头 + 数据区 `rep stosb` 清零；OOM → **null**）。对照 `Mem.alloc m 0 sz`（总是成功、零初始化、有界块）——**D：Core bump 分配器 OOM 返回 null（后续 deref 由边界检查捕获），CompCert 分配总是成功**。
- **IR_ALLOC_ARRAY**（8）：`d := alloc(cnt·esz)`——`s1`=元素数，`s2`=元素大小（≤0 → 8）；ELF 固定 `sz = s1·8`（忽略 `s2`≠8；当前发射均 `s2∈{0,8}` 一致）。**BC14 [ok] 已修复（2026-08-17，第四轮 F14）**：分配尺寸已改 `movabs rdi, imm64`（64 位立即数，≥2³² 不再回绕，`sz` 溢出为负按 OOM 处理）——修复前 `mov edi, imm32`（0xBF 零扩展）对 [2³¹, 2³²) **编码本就正确**（原「高 32 位丢失」表述不准确，F14 实测证伪），仅 ≥2³² 按 mod 2³² 回绕。同族一并修复：DEREF 边界比较改 `movabs rcx, imm64` + `cmp rax, rcx`（F17，alloc_sz ≥ 2³¹ 不再符号扩展失效）、ud2 写位置修正（F1c，pos+cp）。interp：`cnt·esz+8` 字节（含头）——注意 interp 多分配 8 字节头（与 ELF 布局不完全一致，仅解释器内部自洽）。

load/store（对照 `Mem.load`/`Mem.store` Memory.v:L428/L531 + `valid_access` L220：
要求 `[ofs, ofs+size_chunk) ⊆ block` 且对齐；Core 无权限/对齐概念——**D：Core 内存模型 = 分配块 + 边界检查，无权限/对齐维度**）：

- **IR_LOAD_FIELD**（11）：`d := M[ρ(s1) + 8·s3]`（字段偏移 = 字段号×8）。对照 `Pmovq_rm` + `Aindexed`（Asm.v:L623-624; Op.v:L322-323）。interp：`ptr≠0` 时 `r64(ptr, s3·8)`，`ptr=0` 时退回槽值（近似）。
- **IR_STORE_FIELD**（12）：`M[ρ(s1) + 8·s3] := ρ(s2)`。对照 `Pmovq_mr`（Asm.v:L627-628）。
- **IR_LOAD_INDEX**（13）：`d := M[ρ(s1) + 8·s3]`（常量索引 `s3`）。**BC16 [ok] 已修复（2026-08-17，第四轮 F2）**：checker 已补编译期常量界检查（R002/TK05/TK06 硬错误门）——修复前常量索引的编译期越界检查缺失（checker 只查「非数组类型」；ext_safety 的编译期检查同死于 BC6 门控）。
- **IR_STORE_INDEX**（14）：`M[ρ(s1) + 8·s3] := ρ(s2)`。
- **IR_LOAD_INDEX_VAR**（15）：`d := M[ρ(s1) + 8·ρ(s2)]`。**BC6 [ok] 已修复（2026-08-17，第四轮 F1）**：运行时索引越界守卫已启用——`CORE_SAFE` 默认开启、ext 注册表 16 字节记录布局修复（w64 偏移重叠致插件永不匹配）、ir_gen 传真实数组长度并补**写路径**钩子，`IR_BOUNDS_CHECK` 正常发射。修复前插入路径**双重死亡**：① 插件注册被 `CORE_SAFE=1` 环境变量门控；② ir_gen 两个调用点恒传 `arr_len_lit = -1` → `IR_BOUNDS_CHECK` **永不发射**——直接 `arr[i]`（非指针路径）的越界读写**无任何运行时检查**（与 `&arr[i]` 解引用的 provenance 检查链不对称——后者已在第一轮修复）。对照 CompCert：越界 load/store → `None`（Stuck）——Core 修复后前置硬陷阱。
- **IR_STORE_INDEX_VAR**（16）：`M[ρ(s1) + 8·ρ(s2)] := ρ(d)`——**注意值在 dest 槽**（ELF：`mov [r10+r11·8], r12`，instr.cr L1175-1186；interp 同用 `d`）。操作数约定与 IR_STORE 不同（D：历史约定，契约按发射/后端一致为准）。越界守卫同 BC6（**已修复** 2026-08-17，F1 补写路径钩子）。
- **IR_DEREF**（25）：`d := M[ρ(s1)]`；运行时边界检查（provenance_verify 后置填充 `s2`=分配基址变量、`s3`=分配大小、`ti`=访问宽度；instr.cr L256-287 `e2_ptr_bounds_check`）：
  `⊥` iff `ρ(s1) = 0`（null）∨ `ρ(s1) − base ≥ᵤ (alloc_sz − width + 1)`（无符号）。
  安全条件等价于「访问末字节 ∈ [base, base+alloc_sz)」，与 CompCert `Mem.load` 的 `ofs+size ≤ blocksize` 一致（负偏移在无符号下恒越界）✓。`s3 = 0` → 无检查（快速路径，unsafe 场景）。对照 `Pmovq_rm`；**BC-DEREF**：无检查路径仅当 provenance 未填充时出现（unsafe 块显式跳过）——第四轮核实完成：未发现绕过链（findings §3 证伪 off-by-one，i=7/8/-1 边界精确）。
- **IR_STORE_PTR**（26）：`M[ρ(s1)] := ρ(s2)`；边界检查同 DEREF（`d`=基址变量、`s3`=大小）。**BC10 [ok] 已修复（2026-08-17，第四轮 F6）**：`s3=0` 发射态**保留 null 陷阱**（拆出 `e2_ptr_null_check`，修复前连 null 陷阱都没有，检查序列整体跳过）；provenance_verify 后置改写依赖已不再关键。**BC12 [ok] 已修复（F12）**：interp 的 STORE_PTR 已改 `M[ρ(s1)] := ρ(s2)`（`ir_interp_deref_write`，与 ELF 操作数一致）——修复前为槽拷贝（`w64(slot[s1], slot[d])`，d=-1 时恒 no-op）。
- **IR_ADDR_INDEX**（31）：`d := ρ(s1) + 8·ρ(s2)`（`&arr[i]`，`s3`=scale，当前恒 3；ELF 硬编码 scale=3 忽略 s3）。对照 `Oleal` + `Aindexed2scaled`。无边界检查（由后续 DEREF 的 provenance 承担；常量索引编译期拦截）。interp 已实现（BC11 已修，2026-08-17）。
- **IR_SLICE**（24）：`d := ρ(s1) + 8·ρ(s2)`（`&arr[low]`；`s3` = high 变量）。**BC7 [ok] 部分修复（2026-08-17，第四轮 F11）**：切片字面量界已建长度侧表 + 创建期检查 + slice provenance 传播（interp 同步补 SLICE）；**运行时 high 界仍不进入值**——slice 解引用无长度信息，完整修复需 IR 形态演进（slice 类型），已标注设计项（见 TODO）。对照 CompCert：slice 无对照（C 无 slice）。
- **IR_REF**（18）：`d := &ρ(s1)`（栈帧内地址，ELF `lea r10,[rbp+disp]`；interp：值复制近似）。对照 `Oleal`/`Aindexed`（Asm.v:L701-702）。
- **IR_BOUNDS_CHECK**（30）：`if ρ(s1) ≥ᵤ s2 → ud2`（SIGILL ⊥）；`s2 < 0` → no-op。无符号比较对负索引正确捕获（负 → 无符号巨大 ≥ᵤ 正界）✓；且能同时覆盖 `index ≥ max_len` 与 `index < 0`。对照：CompCert 越界在 load/store 返回 `None` → `Stuck`；Core 前置显式检查 + 硬陷阱——**D：中止而非未定义值（安全优先）**。ELF 编码现状（F1c 修复后，instr.cr L1373-1392）：`s1`（index）按变量槽加载（`e2_load_var` r10），**`s2`（max_len）按字面量加载**（`movabs r11, imm64` + `cmp r10, r11` + `jb +2` 跳过 ud2）——修复前两个操作数**均按变量槽加载**（`e2_load_var`），与发射约定「s2 = 字面量长度」冲突，编码会把字面量当变量索引加载。**BC6 [ok] 已修复（2026-08-17，第四轮 F1）**：发射路径已启用（见 IR_LOAD_INDEX_VAR）。interp 已实现（BC11 已修）——越界返回中止，解释器内 OOB 不再静默。
- **IR_ARENA_NEW**（32）：`d := arena_new(s1)`（新 arena 句柄；`s1`=大小估计）。对照：CompCert 无 arena 概念（每函数 `Pallocframe` 一帧）——**D：Core arena 内存模型（docs/maintainer/design/region-model.md §四），无 CompCert 对照**。interp：no-op 近似（置 0，BC11 已修）。
- **IR_ARENA_RESET**（33）：`arena_reset(ρ(s1))`；`s1 < 0` → no-op（ELF 带 `jl` 保护防递归）。interp：no-op 近似（BC11 已修）。

### 2.5 控制流与调用

- **IR_NOP**（0）：无状态变化。
- **IR_LABEL**（21）：标签定义（`s1` = 标签号），无副作用。对照 `Plabel`（Asm.v:L946-947）。
- **IR_JUMP**（20）：`goto L(s1)`。对照 `Pjmp_l`（Asm.v:L903-904）。interp 有回边特例（SG_LOOP/SG_FOR region 表驱动循环迭代，非标签表）——Core 数据流 region 机制，无 CompCert 对照。
- **IR_BRANCH**（19）：`if ρ(s1) ≠ 0 goto L(s2) else goto L(s3)`（true 在前）。对照 `Pjcc`（Asm.v:L909-914）——CompCert 消费标志位（`eval_testcond`），Core 直接测试值（`test` + `je/jmp`）：语义等价，形态不同（**D：Core 无标志寄存器状态，比较直接产值**）。
- **IR_PHI**（22）：`d :=` 按到达前驱边选择的值（SSA φ）——**当前无发射方/无后端/无解释器实现**（保留给未来 SSA 形态）。CompCert RTL 无 φ（非 SSA 需求）。D：保留项。
- **IR_RETURN**（5）：返回 `ρ(s1)`（`TI_FLOAT` → XMM0；int → RAX）；`main` 的返回 = 进程退出码。对照 `Pret` + `final_state`（Asm.v:L934-935, L1144-1148）。
- **IR_CALL**（4）：`d := f(args)`——`s1`=首参变量、`s2`=参数个数、`s3`=函数名 ni。SysV AMD64 调用约定（int：rdi,rsi,rdx,rcx,r8,r9 + 栈；float/apx：xmm0-7）。对照 `Pcall_s`（Asm.v:L930-931）+ `extcall_arguments`（L1071-1091）+ 栈帧对齐（16 字节，Compcert `frame_env_aligned` 证明——Core 已修，见 compcert-reference 修复 11）。内建（syscall3/load8/store8/r64/w64/…）在 ELF 直接展开（instr.cr L631-783），interp 对 syscall 族返回 0（已知局限）。
- **IR_CALL_EXTERN**（45）：外部符号调用——`s1`=函数名 ni、`s2`=首参、`s3`=参数个数（**注意：约定与 IR_CALL 不同，名字在 s1**）。ELF：外部重定位 `call rel32`。对照 CompCert `exec_step_external`（Asm.v:L1120-1127）。
- **IR_HOTPATCH_ROUTE**（39）：热补丁路由调用（s1=名字、s2=首参、s3=参数数，同 CALL_EXTERN 约定）。ELF：call patch 同 CALL。对照无（CompCert 无热补丁）——D。
- **IR_FNADDR**（48）：`d := &f`（`s1`=函数名 ni；`movabs` imm64 + 链接期补丁）。对照 `Oindirectsymbol`（Op.v:L79, L352）→ `Genv.symbol_address`。interp：`d := 0`（无地址概念，已知局限）。
- **IR_SPAWN**（27）：创建并发执行单元——`d`=future/结果、`s1`=首参、`s2`=参数个数、`s3`=函数名 ni（**按 ir_gen.cr L871 实际发射**）。**BC1 [ok] 已修复（2026-08-17，第四轮 F4）**：操作数约定统一为 s3=函数名，并补 SysV 参数装载（修复前 ast.cr 注释/instr.cr（`name_ni := s1`）与发射方/interp 四方错位——ELF 拿参数变量索引当函数名查表、且从不装载参数 → SIGSEGV）。ELF 现为单线程近似（直接 call 存结果）；interp 单层内联。对照：CompCert 无并发——D。

### 2.6 枚举与动态类型

- **IR_MAKE_ENUM**（17）：`d := alloc(8·(1+s2))`；`M[d+0] := s1`（tag）；payload 由后续 `IR_STORE_FIELD(ai+1)` 填充。**tag = 变体名驻留字符串索引**（match 生成也按名字索引比较——ir_gen L1382-1396）。对照：CompCert 无运行时枚举（C 枚举 = 编译期常量）——**D：Core 枚举有运行时 tag 布局 `[tag(8B), payload...]`**；依赖跨模块稳定的字符串驻留。ELF 用 `mov qword [r10+0], imm32`（tag 为符号扩展 imm32，变体数 ≤ 16 无影响）。
- **IR_LOAD_ENUM_TAG**（23）：`d := M[ρ(s1)+0]`（读 tag）。对照同上。
- interp：MAKE_ENUM/LOAD_ENUM_TAG 均为**值复制**（枚举值 = 名字索引，无堆布局）——解释器内部自洽的近似表示；**BC13 [ok] 已修复（2026-08-17，第四轮 F13）**：interp 已按堆布局实现 MAKE_ENUM/STORE_FIELD（带 payload 枚举不再把名字索引当地址写）——修复前带 payload 枚举在 interp 中损坏（仅 tag 枚举可工作）。
- **IR_DYN_PACK**（43）：`M[d+0] := ρ(s1)`；`M[d+8] := s2`（tag = 类型索引）——dyn 变量占 16 字节双槽。
- **IR_DYN_TAG**（41）：`d := M[ρ(s1)+8]`。**IR_DYN_VAL**（42）：`d := M[ρ(s1)+0]`。
- **IR_DYN_DISPATCH**（44）：按 dyn tag 分发到已知类型处理器，未知 tag → 错误。ELF 现为占位实现：int/bool/str 三档 compare-chain，未知 tag 落入 `xor eax,eax; ret`（**在函数体中间发射 `ret`——语义 = 当前函数返回 0**）；`s2`（方法/函数名）未使用。**BC9 [ok] 已修复（2026-08-17，第四轮 F3）**：rel8 补丁写入加 `pos` 基——修复前补丁写错地址（三个 `je` 的 rel8 全为 0）→ 已知 tag 也坠错误路径 → 函数体中间 ret → 任何 dispatch 都 SIGSEGV（比占位语义更严重）；修复后已知 tag 正确分发，未知 tag 静默 0 为既定占位语义。对照：CompCert 无动态类型——D。

### 2.7 并发 / 流 / 惰性（对照：CompCert 无，全部为 D 设计差异）

- **IR_SPAWN**：见 2.5。
- **IR_YIELD**（28）：语义 = **向 flow 消费者通道发射 `ρ(s1)`**（ast.cr L557）。**BC8 [ok] 已修复（2026-08-17，第四轮 F5）**：ELF 改 **eager 值传递近似**（`d := ρ(s1)`，不再 `call sched_yield()`——修复前实现与定义语义不符且未导入符号 rel32=0 崩溃）；interp 补 `d >= 0` 守卫（修复前发射恒 dest=-1 → `g_ir_vals[-8]` 堆下溢写，静默 UB）。三方一致为 eager 近似（D：单线程模式既定近似——完整 go/G-M 调度见 docs/maintainer/design/execution-model.md §三）；flow fn 语法已修（parser 不再把 T_FN 当函数名）。
- **IR_AWAIT**（29）：语义 = 阻塞直到 future 就绪，`d` = 结果。ELF/interp 均为值复制（eager 近似，已文档化）——D：单线程模式的既定近似。
- **IR_LAZY_THUNK**（46）：`d` = 惰性包装（s1 = 表达式求值）。**IR_LAZY_FORCE**（47）：`d` = 强求结果。两者当前均 eager 近似（值传递，ELF/interp 一致）——D：惰性求值尚未落地（lazy 设计文档），IR 保留显式 thunk 形态以便迁移。

### 2.8 注解（无运行语义；对照：CompCert 无对应——D）

- **IR_INLINE**（34）：内联提示（`s1`=函数）。
- **IR_NO_BOUNDS_CHECK**（35）：授权后续 DEREF 跳过边界检查（unsafe）——由 provenance_verify 消费。
- **IR_FAST**（36）：性能提示——**忽略 → 行为零变化**（与 apx 的语义级许可严格区分，见 §4）。
- **IR_UNROLL**（37）：循环展开提示（`s1`=次数）。
- **IR_SECTION**（38）：代码段提示（`s1`=段名 ni）。
- **IR_APPROX**（51，规划中）：apx **语义级**变换授权附注——授权后端对后续 dex 运算做近似兑现（CPU → binary64 FPU；其他范式 → 忽略附注走精确缩放整数）。**非语义 opcode**（不改变 dex 的数学语义本身；「精确，或经授权的近似」契约）。对照 CompCert：无（CompCert 永远是 IEEE 754 语义，不存在授权机制）——D：范式普适哲学的落地（dex/apx 设计 §三）。

## 4. dex/apx 语义契约（迁移目标，2026-08-16 设计定案）

> 现状：`TI_FLOAT` 路径 = binary64（apx 快路径前身）；字面量经 `str_to_f64_bits`（lexer.cr L331）。迁移后：
> 字面量 → dex 定点；`float` 类型名删除 → `dex, apx`。

- **dex 值** = 缩放整数 `v = n / 10⁶`（n = i64；S = 10⁶，四舍五入取整入位）。**S = 10⁶ 为本契约显式决策**（设计文档未定缩放系数，见 §1 注）。表示范围内精确、全序（无 NaN/±0/无穷——与 CompCert IEEE 语义的**根本差异 D**：dex 是数学实数语义，CompCert 是 IEEE 754 机器语义）。
- **字面量**：十进制解析 → 定点整数（替换 `str_to_f64_bits`）。
- **算术**（IR 保持纯精确，dex 运算 = 缩放整数指令序列）：
  - 加/减：`(n₁ ± n₂)/10⁶`（直接 i64 加减，同缩放无换算）；
  - 乘：`(n₁·n₂)/10⁶`——需 128 位中间积或溢出检查（溢出 → `EC_R_OVERFLOW` R003）；
  - 除：`(n₁·10⁶)/n₂`——需 128 位中间；`n₂=0` → `EC_R_DIV_ZERO` R001；
  - 比较：直接 i64 比较（同缩放）——比 CompCert `Ccompf` 强（无排序问题）。
- **转换**：int→dex：`n·10⁶`（精确）；dex→int：`trunc(n/10⁶)`（有损 → `EC_R_LOSSY_CONVERT` R004 检查点）。
  IR_I2F/IR_F2I 迁移后即 int↔dex 转换（浮点形态退役）。
- **apx 兑现**：带 IR_APPROX 的 dex 运算 → binary64（IEEE 754，对照 `Oaddf` 等 Op.v:L419-422 语义；
  结果 = 就近舍入近似）。**BC-I2F/BC-F2I/BC-FCMP 均属 apx 路径，dex 精确路径不受影响**。

## 5. 差异点汇总（D = 有意设计；BC = bug 候选，Task 2 核实对象）

### 有意设计差异（不强行对齐 CompCert）

| # | 差异 | 设计理由 |
|---|---|---|
| D1 | 编码层 int = 64 位机器整数,模 2⁶⁴ 回绕(2026-08-23 后 = 无上限数学整数的快路径投影) | 与 CompCert `Int64` 位向量一致(编码层对照);语义层 = 数学整数(spec 9.4/int-unbounded 定稿)——三层分离:语义(数学)→ 格(编码层事务)→ 64 位投影 |
| D2 | 无标志寄存器状态；比较直接产 0/1 值 | 数据流 IR（语义保鲜）形态——标志是机器惯例，不进 IR 语义 |
| D3 | 错误 = 硬陷阱（SIGILL/SIGFPE）而非 `None`/`Stuck` | 安全优先：越界/除零中止程序，不留未定义值路径；错误不在 IR 层显式表达 |
| D4 | 无无符号比较 opcode（无符号仅用于边界检查技巧） | int 全有符号（CompCert 的 Ccompu/Ccomplu 显式二元来自 C 语义，Core 无此需求） |
| D5 | 枚举 tag = 变体名驻留索引（运行时布局 [tag, payload]） | 语义保鲜（tag 可读名）而非编号；C 枚举无运行时形态 |
| D6 | 内存模型 = 分配块 + 边界检查，无权限/对齐维度 | 语言无 MMIO/无别名权限需求；对齐由 x86 容忍（未对齐访问合法） |
| D7 | arena 内存模型（ARENA_NEW/RESET） | 作用域内存回收（docs/maintainer/design/region-model.md）；CompCert 每函数一帧不可比 |
| D8 | IR_YIELD/AWAIT/SPAWN/DYN_*/HOTPATCH/LAZY/FAST 等 | CompCert 无并发/动态类型/热补丁/惰性——无对照部分不强行映射 |
| D9 | 移位量 ≥ 64：硬件掩码（mod 64）vs CompCert `Vundef` | Core 跟随硬件（机器语义），CompCert 保守未定义；OP_SHL/SHR 当前无发射方 |
| D10 | dex/apx 精确-授权二分 | 范式普适哲学：默认精确（数学语义），近似需显式授权（apx 标签） |
| D11 | 逻辑 `&&`/`||` 在 IR 层**分支化短路**（ir_gen L588-612 用 IR_BRANCH 实现短路），IR_BINARY 的布尔 op（s3=12/13）无发射方 | 与 CompCert 前端分支化殊途同归；IR_BINARY s3=12/13 为死路径 |

### Bug 候选清单（BC——Task 2 核实/证伪产物；2026-08-17 修复后转为记录参考）

| # | 位置 | 现象 | 依据 | 状态（2026-08-17） |
|---|---|---|---|---|
| **BC-I2F** | instr.cr L352-363 | **IR_I2F 的 `cvtsi2sd` 缺 REX.W**：`F2 0F 2A`（32 位操作数）→ `\|a\|≥2³¹` 的 int64→float 截断为低 32 位符号扩展（如 2⁴⁰ → 0.0）。IR_F2I 有 `F2 48 0F 2C` 对照可见遗漏 | 本表 2.3；CompCert `Ofloatoflong`（Op.v:L438）语义对照 | [ok] 已修复（2026-08-17，第四轮 F7：`e2_sd_cvt` 补 REX.W） |
| BC1 | instr.cr L825-836（IR_SPAWN `name_ni := s1`） | SPAWN 操作数约定错位：发射方/interp 用 `s3`=函数名、`s1`=首参；ELF 拿 `s1`（参数变量索引）当函数名查表；ast.cr L556 注释与二者皆不同 | 本表 2.5；ir_gen.cr L871 vs instr.cr L828 | [ok] 已修复（2026-08-17，第四轮 F4：统一 s3=函数名 + SysV 参数装载） |
| BC2 | bootstrap/corec/backend/interpreter.py L108 | 整数除/模截断方向：Python `//` 向下取整 vs 契约向零截断（ELF `idiv` ✓，CompCert `Z.quot` ✓）——负除数程序在 bootstrap 与 ELF 下结果不同 | 本表 2.2；Values.v L727 / Integers.v L193 | [ok] 已修复（2026-08-17，第四轮 F10：abs+符号向零截断，补四组负操作数回归） |
| BC3 | ast.cr L282-283 + instr.cr L495-512 | OP_SHL/OP_SHR 无发射方（死路径）；若启用，OP_SHR 用 `shr`（逻辑）而契约方向未定（CompCert `Oshrl` 为算术） | 本表 2.2 | 死路径已确认（第四轮 §2）——启用时按契约补语义 |
| BC4 | interp.cr L96-123 | 解释器对 TI_FLOAT 无分支：float 算术按整数位模式运算（结果错误）；op 24/30/31/32/33/41-45/49/50 未实现（静默跳过）；`IR_STORE_PTR` 槽拷贝错位（BC12 细化） | 本表 2.2/2.3/2.4 | [ok] 已修复（2026-08-17，第四轮 F9：TI_FLOAT 走 f64.cr 软件实现；其余 opcode 随 BC11 补齐） |
| BC5 | instr.cr L460-481 | apx 路径 `==`/`!=` 对 NaN：`sete`/`setne` 直接读 ZF——NaN==NaN 得 1（IEEE/CompCert 为 false） | 本表 2.2 浮点路径；Asm.v compare_floats L453-463 | [ok] 已修复（2026-08-17，第四轮 F8：`setnp+sete`/`setp+setne`，对照 Asmgen.v L260） |
| **BC6** | ext_safety.cr L8-31 + ir_gen.cr L1551/L1557 + instr.cr L1219-1230 | **直接数组索引的运行时越界守卫双重死亡**：①插件注册被 `CORE_SAFE=1` 门控；②ir_gen 恒传 `arr_len_lit=-1` → `IR_BOUNDS_CHECK` 永不发射。`arr[i]`（非指针路径）越界读写无任何检查（与 `&arr[i]` 的 provenance 检查链不对称）。另外 ELF 编码按变量槽加载 s2，与「字面量长度」发射约定冲突（若修复发射方需同步修编码）。**安全检查类，高优先级** | 本表 2.4 | [ok] 已修复（2026-08-17，第四轮 F1：CORE_SAFE 默认开 + 注册表布局修复 + 真实长度 + 写路径钩子 + s2 字面量加载） |
| BC7 | ir_gen.cr L1546 + instr.cr L1202-1212 | IR_SLICE 只算指针；high 界（s3）不进入运行时值——slice 解引用无长度守卫 | 本表 2.4 | [ok] 部分修复（2026-08-17，第四轮 F11：切片字面量界侧表 + 创建期检查 + provenance 传播）；运行时 high 界需 slice 类型（IR 形态演进，设计项，见 TODO） |
| BC8 | instr.cr L1265-1274 | IR_YIELD 实现为 `call sched_yield()` 且忽略 s1——与定义语义「向消费者通道发射值」不符；interp 复制、ELF 让出 CPU，三方不一致 | 本表 2.7 | [ok] 已修复（2026-08-17，第四轮 F5：ELF 改 eager 值传递近似，interp 补 d≥0 守卫，三方一致） |
| BC9 | instr.cr L1304-1364 | IR_DYN_DISPATCH 未知 tag → `xor eax,eax; ret`（函数体中间 ret，语义 = 整个函数返回 0）；`s2` 未用 | 本表 2.6 | [ok] 已修复（2026-08-17，第四轮 F3：rel8 补丁加 pos 基——修复前已知 tag 也崩溃（SIGSEGV），现已知 tag 正确分发） |
| BC10 | ir_gen.cr L758 + instr.cr L1048-1059 | IR_STORE_PTR 发射时 dest=-1/s3=0 → ELF 边界检查恒跳过；仅 provenance_verify 后置改写才启用——非 build 流程/多目标时无检查 | 本表 2.4 | [ok] 已修复（2026-08-17，第四轮 F6：s3=0 保留 null 陷阱（拆出 `e2_ptr_null_check`），修复前连 null 陷阱都没有） |
| BC11 | interp.cr | 解释器未实现 12 个 opcode（24/30/31/32/33/41/42/43/44/45/49/50）——`run` 模式静默错值 | 本表 2.4-2.7 | [ok] 已修复（2026-08-17，第四轮波 2：12 个 opcode 全部补齐——SLICE/BOUNDS_CHECK/ADDR_INDEX/ARENA no-op/DYN 双槽/DISPATCH 与 CALL_EXTERN 显式报错/I2F/F2I f64 路径） |
| BC12 | interp.cr L211 | IR_STORE_PTR 解释为 `w64(slot[s1], slot[d])`（槽拷贝、源在 d），与 ELF `M[ρ(s1)] := ρ(s2)` 不一致；d=-1 时恒 no-op | 本表 2.4 | [ok] 已修复（2026-08-17，第四轮 F12：改 `ir_interp_deref_write`，与 ELF 操作数一致） |
| BC13 | interp.cr L192 | 枚举 payload：MAKE_ENUM/LOAD_ENUM_TAG 值复制 + STORE_FIELD 把名字索引当地址写 → 带 payload 枚举损坏 | 本表 2.6 | [ok] 已修复（2026-08-17，第四轮 F13：interp 按堆布局实现 MAKE_ENUM/STORE_FIELD） |
| BC14 | instr.cr L905-915（IR_ALLOC_ARRAY）、L885-903（ALLOC_STRUCT） | 分配尺寸经 `mov edi, imm32`（0xBF 零扩展写 32 位寄存器）：≥2³² 按 mod 2³² 回绕（[2³¹, 2³²) 零扩展编码正确——原「高 32 位丢失」表述证伪） | 本表 2.4 | [ok] 已修复（2026-08-17，第四轮 F14：改 `movabs rdi, imm64`，溢出按 OOM；同族 F17 一并修复） |
| BC15 | instr.cr L556-557 | IR_BINARY `OP_AND`/`OP_OR` 实现为按位 and/or：非 0/1 输入时与逻辑语义发散（当前无发射方，低优先级） | 本表 2.2 | 死路径已确认（第四轮 §2）——ir_gen 分支化短路（D11），启用时按契约补语义 |
| BC16 | checker.cr L2065 + ext_safety.cr L20-25 | 常量索引（`arr[100]`）的编译期越界检查缺失：checker 只查类型不查界；ext_safety 的编译期分支同样死于 BC6 的门控（`arr_len_lit` 恒 -1） | 本表 2.4 | [ok] 已修复（2026-08-17，第四轮 F2：checker 编译期常量界检查，R002/TK05/TK06 硬错误门） |
| BC17 | — | `EC_R_DIV_ZERO`/`EC_R_OVERFLOW`/`EC_R_LOSSY_CONVERT`/`EC_R_OOB`（ast.cr L483-486）全仓库无引用——运行时错误不产生诊断（依赖硬件陷阱） | 本表 0/2.4 | 死路径已确认（第四轮 §2，预留常量）——dex 迁移时按 R001/R003/R004 启用 |

## 6. 自检

- [x] 全清单：50 个已定义 opcode（0-50，40 空缺）+ 规划 IR_APPROX=51，共 51 条，interp.cr 分发分支交叉验证（原 interp 未实现的 12 个 opcode 已于 2026-08-17 补齐，BC11）
- [x] 每个 opcode 均有数学形式语义（输入操作数 → 状态变化 → 输出）
- [x] 无「待定」项（OP_SHL/OP_SHR 标注为「无发射方、契约悬空」并列入 BC3——是明确状态而非待定）
- [x] 差异点均有理由（D1-D11）或标注 bug 候选（BC1-BC17——2026-08-17 修复后逐条标注状态，转为记录参考）
- [x] CompCert 引用均为真源核实（Op.v/Asm.v/Values.v/Integers.v/Floats.v/Memory.v，附文件:行号），未杜撰
- [x] dex（S=10⁶ 定点）与 apx（binary64）语义已覆盖（§4）
- [x] 只读性：本任务未修改任何 Core 代码与 ~/compcert/
- [x] 质量审查修正（2026-08-16 复核后）：Mem.alloc 行号更正（Memory.v:L348，非 L531）；BC14 零扩展措辞更正；S=10⁶ 标注为契约显式决策；D11 短路措辞更正；BC-F2I Intel SDM 措辞更正；Ccompf NaN 补 Op.v 层 None 与 Asmgen.v:L260 `Cond_and Cond_np Cond_e` 引用；Onotl/Values.v shll/shrl/ext_mgr 行号与引用归属校正
- [x] 第四轮修复同步（2026-08-17）：F1-F20 全部修复合入后，本表已同步修复后状态（[ok] 标记 + BC 表状态列 + 正文过时表述更新）；契约修正 3 处见文件末尾「修复记录」

## 7. 修复记录（2026-08-17，第四轮）

- **F1-F20 全部修复并合入**（维护者授权全修，2026-08-16~17）：安全类 F1/F2/F6/F17、崩溃类 F3/F4/F5/F15/F16、
  正确性 F7-F14、工具链 F18/F19/F20。分三波合入，详见 `docs/archive/compcert-reference.md`「第四轮修复记录（2026-08-17）」。
- **契约修正 3 处**（本表已同步）：
  1. L154（BC-FCMP）：`Val.cmpf_bool` 对 NaN 返回 **`Some false`**（IEEE 语义，Values.v L928-931）而非 `None`
     ——`None` 仅出现在非 float 值输入；机器层分歧在 `compare_floats` 无序时 ZF=1，Asmgen 用
     `Cond_and Cond_np Cond_e`（Asmgen.v L260）落地 IEEE 语义（BC5 结论方向不变，F8 已修）。
  2. L143（OP_PTR_DIFF）：`sar` 是**向下取整（floor）非向零截断**——仅在差为 8 倍数时等价
     （实际发射场景恒满足，无发散）。
  3. BC14：「[2³¹, 2³²) 的尺寸高 32 位丢失」表述**不准确**——`mov edi, imm32` 零扩展对该区间编码正确
     （F14 实测证伪）；修正为「仅 ≥2³² 按 mod 2³² 回绕」，同族缺陷（F17 cmp imm32 符号扩展、sz 溢出为负静默）一并修复。
- **因修复而过时的状态已同步**：IR_BOUNDS_CHECK `s2` 改字面量加载（F1c）、IR_I2F REX.W 已补（F7）、
  interp 12 个 opcode 补齐（BC11）、BC 表逐条标注状态列（BC3/BC15/BC17/BC-F2I 死路径确认，D 表不变）。
