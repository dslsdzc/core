# Core IR 操作语义

本表定义 Core IR 每个 opcode 的语义，用于三方对照：本表语义、`src/arch/x86_64/instr.cr` 的 ELF 编码、`src/compiler/interp.cr` 的解释执行。三者不一致时以本表为语义基准，编码和解释器需要修正。

`D` 表示 Core 有意不同于 CompCert，并附设计理由。`BC` 表示已知限制或未决问题；已经修复的项目不再列入本表。

## 0. 来源与引用

表里的 CompCert 来源是仓库外的 `~/compcert` 树。行号只在对应版本上有效，CompCert 更新后行号会变化。使用本表时，先确认本机 CompCert 版本，再把语义结论和行号引用分开判断。

| 文件 | 内容 | 引用格式 |
|---|---|---|
| `~/compcert/x86/Op.v` | 运算/条件/寻址模式的数学语义（`eval_operation`/`eval_condition`/`eval_addressing`） | Op.v:L275 |
| `~/compcert/x86/Asm.v` | 每条 x86 指令的小步语义（`exec_instr`）、标志模型（`compare_*`）、内存访问（`exec_load`/`exec_store`） | Asm.v:L610 |
| `~/compcert/common/Values.v` | 值的运算定义（`divs`/`addf`/`longoffloat`…） | Values.v:L405 |
| `~/compcert/lib/Integers.v` | 机器整数规则与定义（`Int64.divs = Z.quot` 等） | Integers.v:L193 |
| `~/compcert/lib/Floats.v` | IEEE 754 浮点定义（`to_long`/`of_long`） | Floats.v:L304 |
| `~/compcert/common/Memory.v` | 内存模型（`valid_access`/`load`/`store`） | Memory.v:L220 |

Core 侧只读来源：`src/compiler/ast.cr`（opcode 常量）、`src/compiler/ir_gen.cr`（发射约定）、
`src/compiler/interp.cr`（解释执行现状）、`src/arch/x86_64/instr.cr`（ELF 编码现状）、
`src/compiler/provenance_verify.cr` + `ptr_analysis.cr`（DEREF/STORE_PTR 运行时检查元数据填充）、
`src/runtime/rt.s`（bump 分配器）、`docs/superpowers/specs/2026-08-16-numeric-types-design.md`（dex/apx 设计）。

## 1. 表示法与状态模型

- 状态 `σ = (ρ, M, ctrl)`：`ρ` = 变量环境（IR 变量，64 位值槽）；`M` = 字节寻址内存（堆/栈/rodata）；
 `ctrl` = 控制流位置（解释器：节点游标 + 标签表；ELF：PC）。
- int = 无上限数学整数。本表的 64 位二补语义是编码层快路径投影；结果超出 64 位时升级到多字编码。验证层数学语义与编码层投影的分离见 `spec-design` 第 9.4 节。本契约表以编码层（ELF 实际发射）为基准，与 CompCert `Int64` 位向量的对照仍成立。
- dex（迁移目标）= 精确小数，定点表示：`v ∈ ℚ` ↔ 缩放整数 `⌊v·10⁶⌋`（S = 10⁶）。见第 4 节。
 > 注：numeric-types-design.md 只规定缩放整数表示和内置精度，没有规定缩放系数。S = 10⁶ 是本文的显式决定，迁移实现以本表为准。
- apx = 近似授权（变量级标签）；CPU 实现 = binary64（IEEE 754）快路径。当前 `TI_FLOAT` 路径即其前身实现。
- 错误形态：Core 选择硬陷阱中止，`ud2`（SIGILL，越界/检查失败）或 `idiv #DE`（SIGFPE，除零/溢出），
 分配失败，null。CompCert 选择定义良好的错误值 `None`（`eval_operation`），`Stuck`（Asm 小步）。
 语义等价于“此路径无定义行为且程序中止”，但 Core 不在 IR 层显式表达错误值。
- 无符号比较：Core IR 无显式无符号比较 opcode（int 比较全按有符号 64 位，对照 CompCert `Ccompl`）；
 无符号语义仅以 `jb`/`jae` 技巧出现在边界检查中（第 2.4 节 IR_BOUNDS_CHECK）。

## 2. Opcode 全清单

`ast.cr` 定义 0 到 50（40 号空缺），加 `IR_APPROX = 51`，共 51 个 opcode。51 个全部已定义；`IR_APPROX` 没有发射点。`IR_RESOLVED` 是 BRANCH/JUMP 的标签解析标记，不是 opcode。

> 注（2026-10-26）：`IR_MATCH`（54）已用于多路 `match` 与 `if`（见 §2.5）；本节的 0..51 计数是此前盘点，未含 52..54。

| # | 名称 | 分组 | 发射方 | ELF 后端 | 解释器 | 本节 |
|---|---|---|---|---|---|---|
| 0 | `IR_NOP` | 控制流 | — | 有（空） | 有（空） | 2.5 |
| 1 | `IR_CONST` | 常量 | `ir_gen` | 有 | 有 | 2.1 |
| 2 | `IR_BINARY` | 算术 | `ir_gen` | 有 | 有（部分） | 2.2 |
| 3 | `IR_UNARY` | 算术 | `ir_gen` | 有 | 有 | 2.2 |
| 4 | `IR_CALL` | 调用 | `ir_gen` | 有 | 有（单层内联） | 2.5 |
| 5 | `IR_RETURN` | 调用 | `ir_gen` | 有 | 有 | 2.5 |
| 6 | `IR_ALLOC` | 内存 | `ir_gen`（标量槽标记） | 有（空） | 有（置 0） | 2.4 |
| 7 | `IR_ALLOC_STRUCT` | 内存 | `ir_gen` | 有 | 有 | 2.4 |
| 8 | `IR_ALLOC_ARRAY` | 内存 | `ir_gen` | 有 | 有 | 2.4 |
| 9 | `IR_STORE` | 拷贝（命名误导） | `ir_gen` | 有 | 有 | 2.1 |
| 10 | `IR_LOAD` | 拷贝 | `ir_gen` | 有 | 有 | 2.1 |
| 11 | `IR_LOAD_FIELD` | 内存 | `ir_gen` | 有 | 有 | 2.4 |
| 12 | `IR_STORE_FIELD` | 内存 | `ir_gen` | 有 | 有 | 2.4 |
| 13 | `IR_LOAD_INDEX` | 内存 | `ir_gen` | 有 | 有 | 2.4 |
| 14 | `IR_STORE_INDEX` | 内存 | `ir_gen` | 有 | 有 | 2.4 |
| 15 | `IR_LOAD_INDEX_VAR` | 内存 | `ir_gen` | 有 | 有 | 2.4 |
| 16 | `IR_STORE_INDEX_VAR` | 内存 | `ir_gen` | 有 | 有 | 2.4 |
| 17 | `IR_MAKE_ENUM` | 枚举 | `ir_gen` | 有 | 有（近似） | 2.6 |
| 18 | `IR_REF` | 地址 | `ir_gen` | 有 | 有（近似） | 2.4 |
| 19 | `IR_BRANCH` | 控制流 | `ir_gen` | 有 | 有 | 2.5 |
| 20 | `IR_JUMP` | 控制流 | `ir_gen` | 有 | 有 | 2.5 |
| 21 | `IR_LABEL` | 控制流 | `ir_gen` | 有 | 有 | 2.5 |
| 22 | `IR_PHI` | 控制流 | 无（保留） | 无 | 无 | 2.5 |
| 23 | `IR_LOAD_ENUM_TAG` | 枚举 | `ir_gen` | 有 | 有（近似） | 2.6 |
| 24 | `IR_SLICE` | 内存 | `ir_gen` | 有 | 有 | 2.4 |
| 25 | `IR_DEREF` | 内存 | `ir_gen` | 有 | 有（近似） | 2.4 |
| 26 | `IR_STORE_PTR` | 内存 | `ir_gen` | 有 | 有（近似） | 2.4 |
| 27 | `IR_SPAWN` | 并发 | `ir_gen` | 有（单线程近似） | 有（单层） | 2.7 |
| 28 | `IR_YIELD` | 并发 | `ir_gen` | 有（eager 值传递近似） | 有 | 2.7 |
| 29 | `IR_AWAIT` | 并发 | `ir_gen` | 有（eager） | 有（eager） | 2.7 |
| 30 | `IR_BOUNDS_CHECK` | 内存/安全 | `ext_safety` | 有 | 有 | 2.4 |
| 31 | `IR_ADDR_INDEX` | 地址 | `ir_gen` | 有 | 有 | 2.4 |
| 32 | `IR_ARENA_NEW` | 内存 | `ir_gen` | 有 | 有（no-op 近似） | 2.4 |
| 33 | `IR_ARENA_RESET` | 内存 | `ir_gen`（作用域退出） | 有 | 有（no-op 近似） | 2.4 |
| 34 | `IR_INLINE` | 注解 | `ir_gen` | 空 | 空 | 2.9 |
| 35 | `IR_NO_BOUNDS_CHECK` | 注解 | `ir_gen` | 空 | 空 | 2.9 |
| 36 | `IR_FAST` | 注解 | `ir_gen` | 空 | 空 | 2.9 |
| 37 | `IR_UNROLL` | 注解 | `ir_gen` | 空 | 空 | 2.9 |
| 38 | `IR_SECTION` | 注解 | `ir_gen` | 空 | 空 | 2.9 |
| 39 | `IR_HOTPATCH_ROUTE` | 调用 | `ir_gen` | 有 | 无 | 2.5 |
| 40 | *（未定义）* | — | — | — | — | — |
| 41 | `IR_DYN_TAG` | 动态 | `ir_gen` | 有 | 无 | 2.6 |
| 42 | `IR_DYN_VAL` | 动态 | `ir_gen` | 有 | 无 | 2.6 |
| 43 | `IR_DYN_PACK` | 动态 | `ir_gen` | 有 | 无 | 2.6 |
| 44 | `IR_DYN_DISPATCH` | 动态 | `ir_gen` | 有（占位） | 无 | 2.6 |
| 45 | `IR_CALL_EXTERN` | 调用 | `ir_gen` | 有 | 无 | 2.5 |
| 46 | `IR_LAZY_THUNK` | 惰性 | `ir_gen` | 有（eager） | 有（eager） | 2.7 |
| 47 | `IR_LAZY_FORCE` | 惰性 | `ir_gen` | 有（eager） | 有（eager） | 2.7 |
| 48 | `IR_FNADDR` | 地址 | `ir_gen` | 有 | 有（d=0） | 2.5 |
| 49 | `IR_I2F` | 转换 | `ir_gen` | 有 | 无 | 2.3 |
| 50 | `IR_F2I` | 转换 | `ir_gen` | 有 | 无 | 2.3 |
| 51 | `IR_APPROX` | 注解 | —（已定义，零发射点） | — | — | 2.9 |

对照 CompCert：Core 的“opcode + 操作数槽（dest/src1/src2/src3/type_kind）”形态对应 RTL 的 `Iop`（3 地址）
与 Asm 的 `instruction` 之间的中间层，语义表以 `Asm.v` 的机器语义为基准（opcode 最终由机器指令实现），
算术层语义以 `Op.v` 的 `eval_operation` 为基准。

## 3. 分组语义定义

记法：`a` = `ρ(s1)`、`b` = `ρ(s2)`（变量取值）；`d` = dest 变量；`M[x]` = 内存 `x` 处 8 字节；
`->` = 状态变换；`⊥` = 中止（陷阱）。

### 2.1 常量与拷贝（对照 `Op.v` 常量/`Omove`）

- IR_CONST（1）：`d := s1`（立即数）。`type_kind` 决定解释：`TI_STR`，`d` = rodata 字符串基址
 （ELF 经 `lea r10,[rip+disp]` 补丁；对照 CompCert `Pmov_rs` Asm.v:L619-620 / `Oindirectsymbol` Op.v:L352）；
 `TI_FLOAT` 时，`d` = 位模式/定点缩放值。对照 `Olongconst`/`Ofloatconst`（Op.v:L76-78, 349-351）。
 解释器对 `TI_STR` 存字符串表索引而不是指针，因此不能做字符串操作。这是解释器的已知限制。
- IR_LOAD（10）：`d := ρ(s1)`，变量取值拷贝（含全局变量经 RIP 相对寻址，对照 Core 的 RIP 补丁机制；
 对标 CompCert `Pmovq_rm` Asm.v:L623-624 但无内存读取，名称误导，见 2.1 组注）。对照 `Omove` Op.v:L347。
- IR_STORE（9）：`ρ(s1) := ρ(s2)`，变量赋值（同样不是内存操作）。对照 `Omove`。
 > 组注：`IR_LOAD`/`IR_STORE` 在 Core 中是“槽间拷贝”，真正的内存操作是 FIELD/INDEX/DEREF 族，
 > 与 CompCert 的 load/store 命名不同，属 Core 的 IR 形态设计（D：扁平槽模型，全局/局部统一）。

### 2.2 算术（对照 `Op.v` `eval_operation` + `Asm.v` 整数算术）

`IR_BINARY`（2）按 `s3 = OP_*` 分派；`IR_UNARY`（3）按 `s3 = UOP_*` 分派。`type_kind = TI_FLOAT` 时走浮点路径（见下）。

| OP_* （s3） | 语义（int 路径，64 位模 2⁶⁴） | 对照 CompCert |
|---|---|---|
| OP_ADD 1 | `d := (a + b) mod 2⁶⁴`（回绕） | `Val.addl`（`Oaddlimm` Op.v:L391；`Paddq_ri` Asm.v:L709-710），同为模 2⁶⁴ |
| OP_SUB 2 | `d := (a − b) mod 2⁶⁴` | `Val.subl`（`Osubl` Op.v:L392；`Psubq_rr` Asm.v:L713-714） |
| OP_MUL 3 | `d := (a · b) mod 2⁶⁴`（低 64 位） | `Val.mull`（`Omull` Op.v:L393；`Pimulq_rr` Asm.v:L717-718） |
| OP_DIV 4 | `d := trunc(a/b)`（向零截断）；`b=0` 或 `a=min_signed ∧ b=−1`，`⊥`（idiv #DE，SIGFPE） | `Val.divls`（Values.v:L727-735）：除零/`min_signed/−1`，`None`（Stuck），否则 `Int64.divs = Z.quot`（向零，Integers.v:L193）。abort 形态一致 |
| OP_MOD 5 | `d := a − trunc(a/b)·b`（余数符号随被除数）；同 DIV 的 `⊥` 条件 | `Val.modls`（Values.v:L737-745）：`Int64.mods = Z.rem`（Integers.v:L195） |
| OP_EQ 6 | `d := (a = b) ? 1 : 0` | `Ccompl Ceq`（Op.v:L45, L281-282），`Val.cmpl_bool`；Asm 层 `compare_longs` ZF（Asm.v:L439-444）+ `Cond_e`（Asm.v:L481-485） |
| OP_NE 7 | `d := (a ≠ b) ? 1 : 0` | `Ccompl Cne`；`Cond_ne` |
| OP_LT 8 | `d := (a <ₛ b) ? 1 : 0`（有符号） | `Ccompl Clt`；Asm 层 `Cond_l = OF≠SF`（Asm.v:L511-515），ELF 用 `setl` 有 |
| OP_GT 9 | `d := (a >ₛ b) ? 1 : 0` | `Ccompl Cgt`；`Cond_g`（Asm.v:L526-530），ELF `setg` 有 |
| OP_LE 10 | `d := (a ≤ₛ b) ? 1 : 0` | `Ccompl Cle`；`Cond_le`（Asm.v:L516-520），ELF `setle` 有 |
| OP_GE 11 | `d := (a ≥ₛ b) ? 1 : 0` | `Ccompl Cge`；`Cond_ge`（Asm.v:L521-525），ELF `setge` 有 |
| OP_AND 12 | `d := (a≠0 ∧ b≠0) ? 1 : 0`（逻辑与，非短路；域 = 0/1） | 无直接对照，CompCert C 的 `&&` 在前端分支化，IR 层无布尔运算 |
| OP_OR 13 | `d := (a≠0 ∨ b≠0) ? 1 : 0`（逻辑或，非短路） | 同上 |
| OP_SHL 15 | `d := a << (b mod 64)`（x86 cl 掩码），当前无发射方 | `Oshll` Op.v:L408-409，`Val.shll`（Values.v:L797-802：`Int.ltu n2 Int64.iwordsize'` 检查，越界为 `Vundef`）；Asm 层 `Psalq_rcl` Asm.v:L809-810。D：Core 使用硬件掩码，CompCert 为未定义 |
| OP_SHR 16 | `d := a >>ₗ (b mod 64)`（ELF 用 `shr`，逻辑右移），当前无发射方 | `Oshrl` Op.v:L410-411 是算术右移（`Val.shrl`，Values.v:L806-813）；`Pshrq_rcl` Asm.v:L817-818 是逻辑右移。Core 没有无符号类型，`>>` 的语义尚未确定 |
| OP_PTR_ADD 17 | `d := (a + 8b) mod 2⁶⁴`（指针 + 元素数，元素 8 字节） | 寻址计算：`Oleal`/`Aindexed2scaled`（Op.v:L327-328, L416；Asm.v:L701-702） |
| OP_PTR_SUB 18 | `d := (a − 8b) mod 2⁶⁴` | 同上（负偏移） |
| OP_PTR_DIFF 19 | `d := floor((a−b)/8)`（元素数；ELF 用 `sar` 算术右移 = 向下取整（floor）非向零截断，仅在差为 8 倍数时等价，实际发射场景恒满足，无发散） | 无精确对照（CompCert 指针差为 builtin `__builtin_ptrdiff`）；`Osub`+移位组合 |

`IR_UNARY`（3）：

- `UOP_NEG` 1：`d := (−a) mod 2⁶⁴`。对照 `Onegl`（Op.v:L390）`Val.negl`；`Pnegq`（Asm.v:L705-706）。
- `UOP_NOT` 2：`d := (a = 0) ? 1 : 0`，逻辑非（非按位非）。对照 `Onotl`（Op.v:L407）是按位非，D：Core 无双关按位非 opcode（不需要）。

浮点路径（`type_kind = TI_FLOAT`，当前实现 = apx 快路径 binary64；迁移后 = dex 见第 4 节）：

- OP_ADD..OP_DIV：`d := a ⊕ b`（IEEE 754 `addsd/subsd/mulsd/divsd`）。对照 `Oaddf..Odivf`（Op.v:L419-422），`Val.addf`（Values.v:L538,556），IEEE binary64（`Bplus/Bminus/Bmult/Bdiv`，mode_NE 就近舍入）；Asm 层 `Paddd_ff` 等（Asm.v:L865-872）。
- OP_EQ..OP_GE：`comisd` + 无符号 setcc（`sete/setne/setb/seta/setbe/setae`）。对照 Asm.v `compare_floats`（L453-463）：ZF = （x=y ∨ 无序），CF = ¬（x≥y）（= x<y ∨ 无序），PF = 无序。
 - `OP_EQ` 使用 `setnp` + `sete`，`OP_NE` 使用 `setp` + `setne`，与 IEEE 语义和 CompCert `Ccompf Ceq`（Op.v:L49, L285）一致。直接使用 ZF 会让 NaN 等于 NaN。dex 没有 NaN，不受影响。
 - `OP_LT -> setb(CF)` / `OP_GE -> setae(CF=0)` / `OP_LE -> setbe(CF∨ZF)` / `OP_GT -> seta(CF=0∧ZF=0)` 与 CompCert `Cond_b/ae/be/a`（Asm.v:L491-510）一致（含无序时 LT/LE 为真，与 CompCert 相同的硬件语义）。

整数除法和取模在 ELF、Python bootstrap 解释器和自托管解释器中都向零截断。ELF 使用 `idiv`；解释器使用绝对值和符号处理，余数符号随被除数。这与 CompCert `Z.quot` 和 `Z.rem` 一致。

### 2.3 转换（对照 `Op.v` 转换族）

- IR_I2F（49）：`d := float(int64(a))`。对照 `Ofloatoflong`（Op.v:L169, L438），`Val.floatoflong` = `Float.of_long`（Floats.v:L318-320：`BofZ` 53 位二进制浮点，就近舍入）。ELF 使用 `F2 48 0F 2A`（`cvtsi2sd`，带 REX.W）。迁移后语义：int 到 dex 为 `d := a·10⁶`（精确，无舍入）。
- IR_F2I（50）：`d := trunc(f)`（向零截断）。对照 `Olongoffloat`（Op.v:L167, L437），`Val.longoffloat` = `Float.to_long`（Floats.v:L308-309：`ZofB_range` 向零截断，越界为 `None`）。ELF 使用 `cvttsd2si`，越界时硬件返回 INT64_MIN；CompCert 定义为 `None`。当前没有 IR_F2I 发射方，因此该差异不可触发。启用前需要确定越界语义。迁移后语义：dex 到 int 为 `d := trunc(a/10⁶)`（有损转换，`EC_R_LOSSY_CONVERT` R004 检查点）。
- interp：op 49 和 50 通过 `i64_to_f64` 与 `f64_to_i64` 的软件路径实现。

### 2.4 内存与地址（对照 `Memory.v` 模型 + `Asm.v` 访问指令）

分配（对照 CompCert `Pallocframe`（Asm.v:L948-958）/`Mem.alloc`（Memory.v:L348），L531 是 `store`，勿误引）：

- IR_ALLOC（6）：标量变量槽标记，后端不发射代码（栈槽由帧布局分配）；interp 置 `d := 0`。CompCert 无对照（帧是伪指令级概念）。
- IR_ALLOC_STRUCT（7）：`d := alloc(fc·8)`，`fc` = 结构体字段数（`s3` = 结构体名 ni）；返回零初始化堆块（rt.s L72-103：8 字节长度头 + 数据区 `rep stosb` 清零；OOM，null）。对照 `Mem.alloc m 0 sz`（总是成功、零初始化、有界块），D：Core bump 分配器 OOM 返回 null（后续 deref 由边界检查捕获），CompCert 分配总是成功。
- IR_ALLOC_ARRAY（8）：`d := alloc(cnt·esz)`，`s1` = 元素数，`s2` = 元素大小（小于等于 0 时取 8）。ELF 固定使用 `sz = s1·8`，忽略不等于 8 的 `s2`；当前发射的 `s2` 都是 0 或 8。分配尺寸用 `movabs rdi, imm64` 装入 64 位立即数；结果溢出为负时按 OOM 处理。DEREF 的边界比较同样使用 64 位立即数，避免分配大小大于等于 2³¹ 时符号扩展失效。解释器分配 `cnt·esz+8` 字节，包含 8 字节头；该头只用于解释器内部，和 ELF 布局不完全一致。

load/store（对照 `Mem.load`/`Mem.store` Memory.v:L428/L531 + `valid_access` L220：
要求 `[ofs, ofs+size_chunk) ⊆ block` 且对齐；Core 无权限/对齐概念，D：Core 内存模型 = 分配块 + 边界检查，无权限/对齐维度）：

- IR_LOAD_FIELD（11）：`d := M[ρ(s1) + 8·s3]`（字段偏移 = 字段号×8）。对照 `Pmovq_rm` + `Aindexed`（Asm.v:L623-624； Op.v:L322-323）。interp：`ptr≠0` 时 `r64(ptr, s3·8)`，`ptr=0` 时退回槽值（近似）。
- IR_STORE_FIELD（12）：`M[ρ(s1) + 8·s3] := ρ(s2)`。对照 `Pmovq_mr`（Asm.v:L627-628）。
- IR_LOAD_INDEX（13）：`d := M[ρ(s1) + 8·s3]`（常量索引 `s3`）。常量索引越界时，checker 报告 R002、TK05 或 TK06 并拒绝编译。
- IR_STORE_INDEX（14）：`M[ρ(s1) + 8·s3] := ρ(s2)`。
- IR_LOAD_INDEX_VAR（15）：`d := M[ρ(s1) + 8·ρ(s2)]`。运行期数组索引由 `IR_BOUNDS_CHECK` 检查，越界触发陷阱。`CORE_SAFE` 默认开启；设为 0 可以关闭检查。ext 注册表使用 16 字节记录，`ir_gen` 传入真实数组长度，读路径和写路径都发射边界检查。对照 CompCert：越界 load/store 返回 `None`（Stuck）；Core 在访问前触发硬陷阱。
- IR_STORE_INDEX_VAR（16）：`M[ρ(s1) + 8·ρ(s2)] := ρ(d)`。值在 dest 槽，ELF 使用 `mov [r10+r11·8], r12`，解释器也读 `d`。操作数约定与 IR_STORE 不同，这是既有约定。越界检查使用同一个 `IR_BOUNDS_CHECK`。
- IR_DEREF（25）：`d := M[ρ(s1)]`；运行时边界检查（provenance_verify 后置填充 `s2`=分配基址变量、`s3`=分配大小、`ti`=访问宽度；instr.cr L256-287 `e2_ptr_bounds_check`）：
 `⊥` iff `ρ(s1) = 0`（null）∨ `ρ(s1) − base ≥ᵤ (alloc_sz − width + 1)`（无符号）。
 安全条件等价于“访问末字节在 `[base, base+alloc_sz)` 内”，与 CompCert `Mem.load` 的 `ofs+size ≤ blocksize` 一致；负偏移在无符号比较下总是越界。`s3 = 0` 时不生成检查，这条快速路径只用于 `unsafe` 场景。对照 `Pmovq_rm`。无检查路径只在 provenance 信息未填充时出现，`unsafe` 块显式跳过检查。
- IR_STORE_PTR（26）：`M[ρ(s1)] := ρ(s2)`；边界检查同 DEREF（`d` = 基址变量，`s3` = 大小）。`s3=0` 仍发射 null 陷阱，由 `e2_ptr_null_check` 承担。解释器通过 `ir_interp_deref_write` 完成指针写入，操作数与 ELF 一致。
- IR_ADDR_INDEX（31）：`d := ρ(s1) + 8·ρ(s2)`（`&arr[i]`，`s3` = scale，当前恒为 3；ELF 硬编码 scale=3，忽略 `s3`）。对照 `Oleal` + `Aindexed2scaled`。该指令不直接做边界检查：常量索引在编译期拦截，变量索引由后续 DEREF 的 provenance 信息承担。解释器已实现。
- IR_SLICE（24）：`d := ρ(s1) + 8·ρ(s2)`（`&arr[low]`；`s3` = high 变量）。字面量界登记在长度侧表，创建期做检查，slice 也传播 provenance；解释器同步实现 SLICE。运行期 high 界目前不进入结果值，slice 解引用没有长度信息。完整检查需要 slice 类型，属于后续 IR 形态演进。CompCert 没有 slice。
- IR_REF（18）：`d := &ρ(s1)`（栈帧内地址，ELF `lea r10,[rbp+disp]`；interp：值复制近似）。对照 `Oleal`/`Aindexed`（Asm.v:L701-702）。
- IR_BOUNDS_CHECK（30）：`if ρ(s1) ≥ᵤ s2 -> ud2`（SIGILL，程序中止）；`s2 < 0` 时为空操作。无符号比较同时覆盖 `index ≥ max_len` 和 `index < 0`：负索引在无符号下是很大的数。对照 CompCert：越界 load/store 返回 `None`（Stuck）；Core 在访问前显式检查并触发硬陷阱，D：中止而不是留下未定义值（安全优先）。ELF 从变量槽加载 `s1`（index），从字面量加载 `s2`（max_len），使用 `movabs r11, imm64`、`cmp r10, r11` 和 `jb +2` 跳过 `ud2`。解释器越界时返回中止。
- IR_ARENA_NEW（32）：`d := arena_new(s1)`（新 arena 句柄；`s1` = 大小估计）。CompCert 没有 arena 概念（每个函数一个 `Pallocframe` 帧），D：Core 使用 arena 内存模型（`docs/maintainer/design/region-model.md` 第 4 节），没有 CompCert 对照。解释器置 0，是 no-op 近似。
- IR_ARENA_RESET（33）：`arena_reset(ρ(s1))`；`s1 < 0` 时为空操作，ELF 用 `jl` 保护避免递归。解释器为 no-op 近似。

### 2.5 控制流与调用

- IR_NOP（0）：无状态变化。
- IR_LABEL（21）：标签定义（`s1` = 标签号），无副作用。对照 `Plabel`（Asm.v:L946-947）。
- IR_JUMP（20）：`goto L(s1)`。对照 `Pjmp_l`（Asm.v:L903-904）。interp 有回边特例（SG_LOOP/SG_FOR region 表驱动循环迭代，非标签表），Core 数据流 region 机制，无 CompCert 对照。
- IR_BRANCH（19）：`if ρ(s1) ≠ 0 goto L(s2) else goto L(s3)`（true 在前）。对照 `Pjcc`（Asm.v:L909-914），CompCert 消费标志位（`eval_testcond`），Core 直接测试值（`test` + `je/jmp`）：语义等价，形态不同（D：Core 无标志寄存器状态，比较直接产值）。`ir_gen` 默认不再发射本 opcode；它仅为历史 `.ccr`/合成 fixture 兼容保留。
- IR_MATCH（54）：按 CASE 表分派 `ρ(s1)`；`s2` = CASE 起始索引，`s3` = 行数。`if`/`while`/`for`/`&&`/`||` 及内部条件分派编码为 `VALUE(0)` + `DEFAULT`（true 走 fallthrough），多路 `match` 由 `ir_gen` 生成；`if` 作为表达式时分支值汇入一个结果槽。后端按行数/值分布选择线性、二分或跳转表；单 `VALUE(0)` + 紧邻 `DEFAULT` 走 test/je/jne 快路径。CASE 行语义见 v10 `.ccr` 规范 §11。
- IR_PHI（22）：`d :=` 按到达前驱边选择的值（SSA φ），当前无发射方/无后端/无解释器实现（保留给未来 SSA 形态）。CompCert RTL 无 φ（非 SSA 需求）。D：保留项。
- IR_RETURN（5）：返回 `ρ(s1)`（`TI_FLOAT`，XMM0；int，RAX）；`main` 的返回 = 进程退出码。对照 `Pret` + `final_state`（Asm.v:L934-935, L1144-1148）。
- IR_CALL（4）：`d := f(args)`，`s1` = 首参变量、`s2` = 参数个数、`s3` = 函数名 ni。使用 SysV AMD64 调用约定（int 参数在 rdi、rsi、rdx、rcx、r8、r9 和栈上；float/apx 参数在 xmm0 到 xmm7）。对照 `Pcall_s`（Asm.v:L930-931）、`extcall_arguments`（L1071-1091）和 16 字节栈帧对齐（CompCert `frame_env_aligned`）。内建函数（syscall3、load8、store8、r64、w64 等）在 ELF 中直接展开，解释器对 syscall 族返回 0。
- IR_CALL_EXTERN（45）：外部符号调用，`s1`=函数名 ni、`s2`=首参、`s3`=参数个数（注意：约定与 IR_CALL 不同，名字在 s1）。ELF：外部重定位 `call rel32`。对照 CompCert `exec_step_external`（Asm.v:L1120-1127）。
- IR_HOTPATCH_ROUTE（39）：热补丁路由调用（s1=名字、s2=首参、s3=参数数，同 CALL_EXTERN 约定）。ELF：call patch 同 CALL。对照无（CompCert 无热补丁），D。
- IR_FNADDR（48）：`d := &f`（`s1`=函数名 ni；`movabs` imm64 + 链接期补丁）。对照 `Oindirectsymbol`（Op.v:L79, L352），`Genv.symbol_address`。interp：`d := 0`（无地址概念，已知局限）。
- IR_SPAWN（27）：创建并发执行单元，`d` = future/结果、`s1` = 首参、`s2` = 参数个数、`s3` = 函数名 ni。参数按 SysV 约定装载。ELF 使用单线程近似：直接调用并把结果存入 `d`。解释器执行单层内联。CompCert 没有并发，D。

### 2.6 枚举与动态类型

- IR_MAKE_ENUM（17）：`d := alloc(8·(1+s2))`；`M[d+0] := s1`（tag）；payload 由后续 `IR_STORE_FIELD(ai+1)` 填充。tag = 变体名驻留字符串索引（match 生成也按名字索引比较，ir_gen L1382-1396）。对照：CompCert 无运行时枚举（C 枚举 = 编译期常量），D：Core 枚举有运行时 tag 布局 `[tag(8B), payload...]`；依赖跨模块稳定的字符串驻留。ELF 用 `mov qword [r10+0], imm32`（tag 为符号扩展 imm32，变体数 ≤ 16 无影响）。
- IR_LOAD_ENUM_TAG（23）：`d := M[ρ(s1)+0]`（读 tag）。对照同上。
- interp：MAKE_ENUM 和 STORE_FIELD 按堆布局实现，带 payload 的枚举不再把名字索引当地址写入。LOAD_ENUM_TAG 读取堆上的 tag。
- IR_DYN_PACK（43）：`M[d+0] := ρ(s1)`；`M[d+8] := s2`（tag = 类型索引），dyn 变量占 16 字节双槽。
- IR_DYN_TAG（41）：`d := M[ρ(s1)+8]`。IR_DYN_VAL（42）：`d := M[ρ(s1)+0]`。
- IR_DYN_DISPATCH（44）：按 dyn tag 分发到已知类型处理器。ELF 当前是占位实现：int、bool、str 三档 compare-chain，未知 tag 落入 `xor eax,eax; ret`，即当前函数返回 0；`s2`（方法或函数名）未使用。已知 tag 正确分发，未知 tag 返回 0 是既定占位语义。CompCert 没有动态类型，D。

### 2.7 并发 / 流 / 惰性（对照：CompCert 无，全部为 D 设计差异）

- IR_SPAWN：见 2.5。
- IR_YIELD（28）：语义是向 flow 消费者通道发送 `ρ(s1)`。ELF 和解释器都使用 eager 值传递近似：`d := ρ(s1)`。解释器保留 `d >= 0` 检查，避免 dest 为 -1 时写入值缓冲区之外。完整 go/G-M 调度见 `docs/maintainer/design/execution-model.md` 第 3 节。
- IR_AWAIT（29）：语义 = 阻塞直到 future 就绪，`d` = 结果。ELF/interp 均为值复制（eager 近似，已文档化），D：单线程模式的既定近似。
- IR_LAZY_THUNK（46）：`d` = 惰性包装（s1 = 表达式求值）。IR_LAZY_FORCE（47）：`d` = 强求结果。两者当前均 eager 近似（值传递，ELF/interp 一致），D：惰性求值尚未实现（lazy 设计文档），IR 保留显式 thunk 形态以便迁移。

### 2.8 注解（无运行语义；对照：CompCert 无对应，D）

- IR_INLINE（34）：内联提示（`s1`=函数）。
- IR_NO_BOUNDS_CHECK（35）：授权后续 DEREF 跳过边界检查（unsafe），由 provenance_verify 消费。
- IR_FAST（36）：性能提示，忽略，行为零变化（与 apx 的语义级许可严格区分，见第 4 节）。
- IR_UNROLL（37）：循环展开提示（`s1`=次数）。
- IR_SECTION（38）：代码段提示（`s1`=段名 ni）。
- IR_APPROX（51）：apx 语义级变换授权附注。带该附注时，后端可以对后续 dex 运算使用近似实现（CPU 上为 binary64 FPU；其他执行方式可以忽略附注，走精确缩放整数）。该 opcode 不改变 dex 的数学语义，契约是“精确，或经授权的近似”。当前没有发射点。CompCert 没有授权机制，D。

## 4. dex/apx 语义契约

> 现状：`TI_FLOAT` 路径 = binary64（apx 快路径前身）；字面量经 `str_to_f64_bits`（lexer.cr L331）。迁移后：
> 字面量，dex 定点；`float` 类型名删除，`dex, apx`。

- dex 值 = 缩放整数 `v = n / 10⁶`（n = i64；S = 10⁶，四舍五入取整入位）。S = 10⁶ 为本契约显式决策（设计文档未定缩放系数，见第 1 节注）。表示范围内精确、全序（无 NaN/±0/无穷，与 CompCert IEEE 语义的根本差异 D：dex 是数学实数语义，CompCert 是 IEEE 754 机器语义）。
- 字面量：十进制解析，定点整数（替换 `str_to_f64_bits`）。
- 算术（IR 保持纯精确，dex 运算 = 缩放整数指令序列）：
 - 加/减：`(n₁ ± n₂)/10⁶`（直接 i64 加减，同缩放无换算）；
 - 乘：`(n₁·n₂)/10⁶`，需 128 位中间积或溢出检查（溢出，`EC_R_OVERFLOW` R003）；
 - 除：`(n₁·10⁶)/n₂`，需 128 位中间；`n₂=0`，`EC_R_DIV_ZERO` R001；
 - 比较：直接 i64 比较（同缩放），比 CompCert `Ccompf` 强（无排序问题）。
- 转换：int，dex：`n·10⁶`（精确）；dex，int：`trunc(n/10⁶)`（有损，`EC_R_LOSSY_CONVERT` R004 检查点）。
 IR_I2F/IR_F2I 迁移后即 int↔dex 转换（浮点形态退役）。
 - apx 实现：带 IR_APPROX 的 dex 运算，binary64（IEEE 754，对照 `Oaddf` 等 Op.v:L419-422 语义；
 结果 = 就近舍入近似）。这些行为只影响 apx 路径，dex 精确路径不受影响。

## 5. 差异点汇总

### 有意设计差异（不强行对齐 CompCert）

| # | 差异 | 设计理由 |
|---|---|---|
| D1 | 编码层 int = 64 位机器整数，模 2⁶⁴ 回绕；语义层 int = 无上限数学整数，64 位结果是无上限语义的快路径投影 | 与 CompCert `Int64` 位向量一致（编码层对照）；三层分离：语义（数学）、格（编码层事务）、64 位投影 |
| D2 | 无标志寄存器状态；比较直接产 0/1 值 | 数据流 IR（语义保留）形态，标志是机器惯例，不进 IR 语义 |
| D3 | 错误 = 硬陷阱（SIGILL/SIGFPE）而非 `None`/`Stuck` | 安全优先：越界/除零中止程序，不留未定义值路径；错误不在 IR 层显式表达 |
| D4 | 无无符号比较 opcode（无符号仅用于边界检查技巧） | int 全有符号（CompCert 的 Ccompu/Ccomplu 显式二元来自 C 语义，Core 无此需求） |
| D5 | 枚举 tag = 变体名驻留索引（运行时布局 [tag, payload]） | 语义保留（tag 可读名）而非编号；C 枚举无运行时形态 |
| D6 | 内存模型 = 分配块 + 边界检查，无权限/对齐维度 | 语言无 MMIO/无别名权限需求；对齐由 x86 容忍（未对齐访问合法） |
| D7 | arena 内存模型（ARENA_NEW/RESET） | 作用域内存回收（docs/maintainer/design/region-model.md）；CompCert 每函数一帧不可比 |
| D8 | IR_YIELD/AWAIT/SPAWN/DYN_*/HOTPATCH/LAZY/FAST 等 | CompCert 无并发/动态类型/热补丁/惰性，无对照部分不强行映射 |
| D9 | 移位量 ≥ 64：硬件掩码（mod 64）vs CompCert `Vundef` | Core 跟随硬件（机器语义），CompCert 保守未定义；OP_SHL/SHR 当前无发射方 |
| D10 | dex/apx 精确-授权二分 | 范式通用性原则：默认精确（数学语义），近似需显式授权（apx 标签） |
| D11 | 逻辑 `&&`/`||` 在 IR 层分支化短路（ir_gen L588-612 用 IR_BRANCH 实现短路），IR_BINARY 的布尔 op（s3=12/13）无发射方 | 与 CompCert 前端分支化做法不同，结果相同；IR_BINARY s3=12/13 为死路径 |

### 已知限制

| 编号 | 位置 | 现状 | 依据 |
|---|---|---|---|
| BC3 | `ast.cr`、`instr.cr` | OP_SHL 和 OP_SHR 没有发射方。启用前需要确定右移语义：ELF 的 `shr` 是逻辑右移，CompCert `Oshrl` 是算术右移，Core 没有无符号类型。 | 本表 2.2 |
| BC7 | `ir_gen.cr`、`instr.cr` | IR_SLICE 只计算结果指针。high 界不进入运行时值，slice 解引用没有长度检查。完整检查需要 slice 类型。 | 本表 2.4 |
| BC15 | `instr.cr` | IR_BINARY 的 OP_AND 和 OP_OR 当前按位实现，非 0/1 输入与逻辑语义不一致。当前没有发射方；`ir_gen` 用分支实现短路。 | 本表 2.2 |
| BC17 | `ast.cr` | `EC_R_DIV_ZERO`、`EC_R_OVERFLOW`、`EC_R_LOSSY_CONVERT`、`EC_R_OOB` 是预留常量，当前没有引用。运行时错误依赖硬件陷阱。dex 迁移时启用。 | 本表 2.4 |

## 6. 覆盖检查

- 51 个 opcode 条目全部已定义（0 到 51，40 空缺），每个条目都有操作数、状态变化和结果说明。
- ELF 编码和解释器的分发分支与本表逐项对照。
- 未决项只有 BC3、BC7、BC15 和 BC17；其余差异属于 D1 到 D11 的有意设计。
- CompCert 引用按 `Op.v`、`Asm.v`、`Values.v`、`Integers.v`、`Floats.v`、`Memory.v` 的文件和行号列出。
- dex（S=10⁶ 定点）和 apx（binary64）语义在第 4 节覆盖。
- 已修复的缺陷不列入本表；本表只描述当前代码和当前限制。
