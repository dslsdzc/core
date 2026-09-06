# CompCert 对照审查第四轮发现清单（只读审查——修复已完成）

> 定位：受众 = 维护者；状态 = archive(compcert 对照审查第四轮记录)

> **状态：修复已完成（2026-08-16~17，维护者授权全修）——F1-F20 全部修复合入，本清单转为修复记录参考**。
> 原始产出为只读审查（未修改任何 Core 代码），修复范围当时由维护者决定（反馈门）。
> 修复记录见 `docs/archive/compcert-reference.md`「第四轮修复记录（2026-08-17）」；语义表已同步修复后状态
> （✅ 标记 + BC 表状态列，见 `docs/design/ir-op-semantics.md` §5/§7）；遗留项见 `TODO.md`。
> 契约：`docs/design/ir-op-semantics.md`（IR 操作语义表，Task 1 产物）；方法论：CompCert Coq 语义 = 真源，
> 三方对照（语义表 vs ELF 编码 instr.cr vs 解释器 interp.cr）。
> 日期：2026-08-16。审查分组：算术/转换（A）、内存/安全（B）、控制流/调用/并发/动态（C）、未修复项复核（T）。

## 0. 审查方法与环境（必须阅读）

- 四个只读审查 agent 并行执行，全部复现产物在 `/tmp/compcert-r4/`（临时目录，未触碰仓库）。
- **环境发现（重要）**：`build/corec`（13:24 构建）**不是从当前 HEAD 源码构建的**——含 dex 定点实验
  （float 字面量 → S=10⁶ 缩放整数）的过时产物；当前 HEAD 源码是 TI_FLOAT + IR_I2F（binary64 位模式）路径。
  两个独立审查组均发现并规避（在 /tmp 重建 = HEAD 语义编译器）。**建议：重新构建 build/ 产物并清空
  `.core/cache/`**（缓存按源码路径做 key，会污染 cir dump）。同时说明语义表 §4「迁移后 dex」曾有实现痕迹。
- import 解析依赖 cwd（须在仓库根运行）；`.core/cache/cir` 偶发陈旧缓存——复现需仓库根 cwd + 新鲜路径。
- CompCert 真源引用（Memory.v/Asm.v/Op.v/Values.v/Integers.v/Floats.v 全部文件:行号）经核实**全部准确**。

## 1. 确证 bug 清单（按优先级）

### 1.1 安全/崩溃级（安全检查类最高优先级）

| # | 位置 | 现象 | 证据 | 对照依据 |
|---|---|---|---|---|
| **F1** | ext_mgr.cr L37-40 + ext_safety.cr L8-31 + ir_gen.cr L1551/L1557（BC6，确证） | **直接数组索引（非指针路径）越界读写无任何运行时检查——双重死亡**：① 插件注册被 `CORE_SAFE=1` 门控（默认关）；② ir_gen 恒传 `arr_len_lit=-1` → `IR_BOUNDS_CHECK` 永不发射。复现：`arr:[int;8]` 后 `arr[100]=999` → **exit=42 静默越界**（不崩溃）；`arr[-1]=22` 静默覆盖 alloc size header；`CORE_SAFE=1` 重建无差异。**新增：写路径（ir_gen.cr L742-753）连钩子调用点都没有**——即使两重门控修复，写路径仍无检查 | 复现程序 /tmp/compcert-r4/mem/bc6_oob.cr | 对照 CompCert：越界 load/store → `None`（Memory.v L531）→ Stuck；Core 直接索引路径连陷阱都没有（与 `&arr[i]` 的 provenance 检查链不对称——第一轮已修） |
| **F2** | checker.cr L2044-2067 + ext_safety.cr L20-24（BC16，确证） | **常量索引编译期越界检查缺失**：`arr[100]`（len 8）编译零诊断 + 运行静默。checker 只查类型不查界；ext_safety 编译期分支死于 F1 门控 | 同 F1 复现程序 | 同 F1 |
| **F3** | instr.cr L1358-1361（BC9 升级，确证） | **IR_DYN_DISPATCH rel8 补丁写入位置错位**——用指令内相对偏移当绝对缓冲区偏移（缺 `pos` 基），补丁值写错地址 → 机器码中三个 `je` 的 rel8 **全部为 0** → **已知 tag 也恒坠错误路径** → 函数体中间 `xor eax,eax; ret`（弹出局部槽）→ **已知/未知 tag 均 SIGSEGV（exit=139）**。`s2`（方法名）全程未用 | 复现 bc9_dyn_known.cr/bc9_dyn_unknown.cr；反汇编 `74 00` 三处 | 语义表 2.6（占位实现）；问题比语义表 BC9 描述（未知 tag 静默返回 0）更严重——任何 dispatch 都崩溃 |
| **F4** | instr.cr L827 vs ir_gen.cr L871 vs ast.cr L556（BC1 升级，确证） | **IR_SPAWN 操作数约定四方错位**：ir_gen/interp 用 s3=函数名、s1=首参；ELF `name_ni := s1` 拿参数变量索引当函数名查表 → 补丁失败 → `call rel32=0` → 栈不平衡 → **SIGSEGV（exit=139）**。**新增：ELF SPAWN 从不装载参数**（call 前无 `mov rdi`）。ast.cr L556 注释本身布局也错 | 复现 s1.cr（`go i 0..3 f(i)`）；反汇编 `e8 00 00 00 00` | 语义表 2.5；CompCert 无并发（D8）——Core 侧实现缺陷 |
| **F5** | instr.cr L1265-1274 + interp.cr L201-203（BC8 升级，确证） | **IR_YIELD 三方语义各不相同**：定义语义（ast.cr L557）= 向 flow 消费者通道发射值；ELF = `call sched_yield()` 忽略 s1（未导入 → rel32=0 → rc=139；导入后无 goroutine 上下文 → rsp=0 → rc=139）；interp = 槽复制且 **dest=-1 → 写 `g_ir_vals[-8]`（堆下溢写，静默 UB）**。**新增：flow fn 语法本身解析失败**（parser.cr L1333-1341 把 T_FN 当函数名）——设计语法不可达 | 复现 t_yield2.cr/y3c.cr | 语义表 2.7 |
| **F6** | instr.cr L1048-1053 + ir_gen.cr L758 + provenance_verify.cr L52-129（BC10，确证） | **IR_STORE_PTR 发射态 dest=-1/s3=0 → ELF 边界检查恒跳过**；仅 provenance_verify 后置改写（单运行时目标）才启用；`run`/`check`/`cir` 路径不跑 provenance。**新增：provenance_verify.cr L106 注释「null trap only (s3=0, fast path)」不实——s3=0 时连 null 陷阱都没有**（instr.cr L1051 直接跳过整个检查序列） | 改写生效验证：`&arr[i]+*p`：i=100/8/-1 → SIGILL(132)、i=7 → 42（边界精确）；非 build 流程无检查 | 语义表 2.4 |

### 1.2 正确性 bug（数据错误/错值）

| # | 位置 | 现象 | 证据 | 对照依据 |
|---|---|---|---|---|
| **F7** | instr.cr L353-363（BC-I2F，确证） | **IR_I2F 的 `cvtsi2sd` 缺 REX.W**（`F2 0F 2A` 32 位操作数）：\|a\|≥2³¹ 的 int64→float 截断为低 32 位符号扩展。实测：`y:=2⁴⁰; z:=1.5+y; z>1e12` 返回 0（应 1）——2⁴⁰ 转成 0.0 | 复现 bc_i2f.cr；字节验证 F2 0F 2A（无 48） | CompCert `Ofloatoflong`（Op.v:L438）= `Float.of_long`（Floats.v:L318）；对照 IR_F2I 的 `F2 48 0F 2C`（有 REX.W，L430）——不对称遗漏 |
| **F8** | instr.cr L466-481（BC5，确证） | **apx 路径浮点 `==`/`!=` 对 NaN 语义错误**：`comisd` + `sete`/`setne` 直读 ZF——NaN==NaN 得 1（IEEE/CompCert 应为 0）。实测 `nan:=0.0/0.0; nan==nan` → 1。CompCert 机器层用 `Cond_and Cond_np Cond_e`（Asmgen.v L260）以 PF 纠正 | 复现 bc5_nan.cr（exit=1 应为 0）；`66 0F 2F` + `0F 94` 字节验证 | Asm.v compare_floats L453-463（无序时 ZF=1）；Op.v Ccompf → Values.v L928-931 `cmpf_bool`（NaN → `Some false`） |
| **F9** | interp.cr L99-117（BC4 TI_FLOAT 部分，确证） | **自托管解释器无 TI_FLOAT 分支**：float 算术按 64 位整数位模式运算（1.5 位模式 + 2.5 位模式 ≠ 5.0）。实测 `corec run`：`1.5+2.5==5.0` 返回 0（应 1）；纯 int 对照正常 | 复现 bc4_float_interp.cr | 语义表 2.2 浮点路径；ELF 有 addsd/comisd 路径 |
| **F10** | bootstrap/corec/backend/interpreter.py L108-112/L123（BC2，确证） | **Python bootstrap 解释器整数除/模截断方向错误**：Python `//` 向下取整（-7/3=-3 应为 -2）、`%` 余数符号随除数（-7%3=2 应为 -1）。ELF 与 Python ELF 后端（x86_64_stack_asm.py L191-194 idiv）均向零 ✓——**BC2 仅影响纯 Python 解释器**（tests 经 interpreter.py 跑时行为不同） | 实测四组值全部错误；ELF 对照 exit=1 ✓ | 契约：向零截断（Values.v L727 divls；Integers.v L193 `Z.quot`） |
| **F11** | ir_gen.cr L1546 + instr.cr L1202-1212（BC7，确证） | **IR_SLICE 只算指针，high 界（s3）不进运行时值**：`s := arr[0..2]; s[100]` → **exit=0 静默越界读**（无长度守卫） | 复现 bc7_slice.cr | 语义表 2.4；slice 无 CompCert 对照（C 无 slice）——Core 侧缺陷 |
| **F12** | interp.cr L211（BC12，确证） | **interp 的 IR_STORE_PTR 槽拷贝错位**：解释为 `slot[s1] := slot[d]`（源在 d），与 ELF `M[ρ(s1)] := ρ(s2)` 不一致；发射 d=-1 → 恒 no-op。实测 `x:=5; p:=&x; *p=42; return x`：**ELF 42 vs interp 5** | 复现 bc10_storeptr.cr | 语义表 2.4 |
| **F13** | interp.cr L192/L159-165（BC13，确证） | **interp 枚举 payload 损坏**：MAKE_ENUM/LOAD_ENUM_TAG 值复制（变体名驻留索引被当变量槽号读）；STORE_FIELD 把名字索引当地址写内存（小地址写，可能崩溃）。实测 `Third(33)` match：**ELF 33 vs interp 0** | 复现 bc13_enum.cr | 语义表 2.6；仅 tag 枚举可工作 |
| **F14** | instr.cr L905-915（BC14，部分确证） | **IR_ALLOC_ARRAY 分配尺寸经 `mov edi, imm32`（32 位零扩展）**：尺寸 ≥2³² 按 mod 2³² 回绕。实测 2³² → `mov edi, 0` → 实际只分配 8 字节 → 布局错乱（exit=64）。**语义表「[2³¹,2³²) 高 32 位丢失」表述证伪**——零扩展对该区间编码正确（实测 2³¹ → `mov edi, 0x80000000` ✓）；该区间真实问题是 OOM→null→直接索引裸 SIGSEGV（F1 并发症） | 复现 bc14_wrap.cr/bc14_2g.cr | 语义表 2.4（需修正，见 §5） |
| **F15** | ir_gen.cr L507-522（新增 N1，确证） | **枚举裸变体引用崩溃**：`c := Red`（不加括号）→ ir_gen 解析为 "unresolved" 哑变量、不发 IR_MAKE_ENUM → 后续 LOAD_ENUM_TAG 解引用垃圾值 → **SIGSEGV（exit=139）**；`Red()` 调用形式正常（exit=1）；interp 两态 rc=0（值复制模型自洽掩盖） | 复现 N1 程序；cir 证据 `alloc c; store c <- 22` 无 MAKE_ENUM | 语义表 2.6 只覆盖调用形式——裸变体路径未被覆盖 |
| **F16** | instr.cr L798-811 + elf.cr ext_rel（新增 N2/5a，确证） | **IR_CALL_EXTERN 两个缺陷**：① 编码器从不装载参数（s2/s3 被忽略，call 前无寄存器装载）；② 静态构建下 ext_rel 不解析 → rel32=0。实测 `abs(-5)` → **rc=139** | 复现 abs 程序；反汇编 call 前无 `mov rdi` | 语义表 2.5（exec_step_external 对照）；操作数约定本身（s1=名字）发射/后端一致 ✓ |
| **F17** | instr.cr L256-287（新增，确证） | **DEREF 边界检查 `cmp rax, imm32` 符号扩展**：alloc_sz ≥ 2³¹ 时 limit 编码为负 imm32 → 无符号比较**永不陷阱** → 大分配无越界检查（BC14 同族） | 代码推导 + alloc_sz=64 精确边界验证（i=7 过/i=8/-1 陷阱）——小分配无 off-by-one，大分配失效 | 语义表 2.4；对称发现：`sz=s1*8` 64 位溢出为负 → instr.cr L907 `if sz>0` 静默不发射 |

### 1.3 工具链/诊断

| # | 位置 | 现象 | 证据 |
|---|---|---|---|
| **F18** | build/（新增，确证） | **构建产物与 HEAD 源码不一致**：build/corec + corearch（13:24）= dex 定点实验的过时产物（float 字面量 → S=10⁶），HEAD 源码 = binary64 + IR_I2F。`.core/cache/cir` 按源码路径做 key 污染 dump | 两个独立审查组均发现；全仓库无 1000000 缩放代码 |
| **F19** | main.cr check 子命令（新增，确证） | **`check` 子命令对诊断错误仍返回 exit 0**（不拦截退出码）；`build` 路径有修复 5 机制正常拦截。根因：`run_frontend()`（main.cr L126-134）对 type-check 诊断非致命（注释明示 "non-fatal"），check 分支无条件 return 0 | t_err2.cr 实测 |
| **F20** | dataflow.cr L480 `df_opcode_name`（新增，确证） | **opcode 名表缺 IR_I2F(49)/IR_F2I(50)/IR_AWAIT(29)**——cir/ccr dump 中显示 `?`（dump.cr L82 为调用方；审查复核补 IR_AWAIT，原报告只查了 49/50） | grep 代码 |

## 2. 死路径确认（非现行缺陷，修复启用时需同步语义）

| # | 项目 | 结论 | 证据 |
|---|---|---|---|
| BC3 | OP_SHL/OP_SHR 无发射方（OP_SHR 编码为逻辑 `shr`，契约方向悬空；CompCert `Oshrl` 为算术） | 确证死路径 | 全仓库 grep 无发射方引用（仅 ast.cr 定义 L282-283 与 instr.cr 编码 L495-512） |
| BC15 | IR_BINARY OP_AND/OR 按位实现 vs 逻辑（非 0/1 输入发散） | 确证死路径（ir_gen 分支化短路，D11 一致）；interp 有逻辑分支与 ELF 不对称 | instr.cr L556-557 |
| BC17 | EC_R_DIV_ZERO/OVERFLOW/LOSSY_CONVERT/OOB 全仓库无引用 | 确证（预留常量） | grep 仅 ast.cr L483-486 |
| BC-F2I | IR_F2I **无发射方**（float→int 语言级转换不存在）；`cvttsd2si` 编码含 REX.W ✓ | 死路径——BC-F2I（越界硬件哨兵）当前不可触发 | grep ir_gen 无 IR_F2I |
| BC11 | interp 未实现 12 个 opcode：24/30/31/32/33/41/42/43/44/45/49/50（静默跳过、无报错） | 确证；运行期对照：dyn rc=1 vs 0、slice rc=1 vs 0、addrindex rc=1 vs 0、extern rc=0（静默错值）vs 139 | interp.cr 分发分支逐一核查 |

## 3. 证伪/正常（三方一致或设计差异，无需处理）

| # | 项目 | 结论 | 证据 |
|---|---|---|---|
| DEREF off-by-one | 边界检查数学精确（陷阱 iff `ptr=0 ∨ ptr−base ≥ᵤ alloc_sz−width+1` ⟺ 访问末字节 ∉ [base, base+alloc_sz)），负偏移无符号恒越界；jae/jne 跳转补丁精确 | 证伪（无 off-by-one） | instr.cr L256-287；i=7/8/-1 运行验证 |
| OP_PTR_DIFF | sar = 向下取整（非向零），但合法程序指针差恒 8 倍数 → 无发散 | 设计差异（无实际发散） | 实测 ptrdiff_neg.cr exit=0 |
| float 字面量 mov imm64 | 位模式完整保留（1.5/1e12/2⁴⁰ movabs 全对） | 证伪（正常） | instr.cr L166-192 |
| idiv 除零/min_signed/-1 | SIGFPE（exit=136）——契约 D3 硬陷阱形态与 CompCert `None` 的 abort 形态一致 | 确证（设计差异 D3） | 实测 divzero/minsigned_div_neg1 |
| setl/setg/setle/setge | 有符号编码正确（对照 Cond_l/g/le/ge OF/SF 逻辑） | 证伪（正常） | 边界值实测全对 |
| FNADDR | movabs 占位 + Phase 3 链接期补丁（对照 Op.v L352 symbol_address）；interp d:=0 | 一致 | fnaddr_test rc=0 |
| HOTPATCH_ROUTE | 操作数约定/编码/补丁一致 | 一致 | hotpatch_test rc=0 |
| 枚举 tag 布局 | MAKE_ENUM `[tag(imm32), payload...]` + LOAD_ENUM_TAG 读 [r10+0]（变体数 ≤2³¹） | 一致（裸变体 F15 除外） | 字节验证 |
| DYN 双槽布局 | PACK 值→+0、tag→+8；TAG/VAL 读取一致 | 一致（dispatch F3 除外） | instr.cr L1277-1302 |
| BRANCH/JUMP 标签解析 | res_labels 双遍 + interp 区域回边（SG_LOOP/SG_FOR）；对照 Pjcc/Pjmp_l 语义等价（D2 形态差异） | 一致 | loop/while 实测 rc=0 |
| LAZY_THUNK/FORCE、AWAIT | eager 近似三方一致 | 一致（设计差异 D8） | lazy_test rc=0 |
| IR_CALL vs CALL_EXTERN 约定 | 发射方/后端各自对齐（CALL_EXTERN 缺陷见 F16） | 一致 | ir_gen L1170/L1165 ↔ instr.cr L581/L800 |

> 注：语义表 §2.1 正文的 BC-CONST 标记（interp 对 TI_STR 存字符串表索引而非指针）不在 §5 BC 表内，本轮未核实——保持「解释器已知局限」，后续轮次可补。

## 4. Task 3：未修复项复核结论（迁移后状态）

| # | 现象 | 复核结论 | 证据 |
|---|---|---|---|
| 7 | 字符串拼接 + println 崩溃/挂起 | **已修** | `println("AB"+"CD")` → ABCD、exit 0；check_error 消息完整（error[N06] 带源码定位） |
| 9 | 数组读取值错位（ptr_arith `*p != 30`） | **已修** | tests/suite/ptr_arith.cr 重编译运行 exit 0（`*p==30`、`*q=99` 写后读全过） |
| 10 | region_check B11 对 deref 读出的 int 误报 | **已修** | 4 变体（数组/循环数组/循环子图堆分配/结构体字段）编译零诊断 + 运行 20/20/102/10 全正确（变体 C 的 alloc 位于 LOOP 子图 exit 早于 return——若 pts 未按类型过滤必被拦，最贴近原始误报语义） |
| 16 | int_str 空字符串 | **已修** | 7/0/567/-5/12345678 打印全正确（含边界与大数），exit 0 |

## 5. 语义表修正建议（契约文档，Task 2 核实产物）

1. **L154**：`Val.cmpf_bool` 对 NaN 返回 `Some false`（IEEE 语义，Values.v L928-931）而非 `None`——`None` 仅出现在非 float 值输入；机器层分歧在 `compare_floats` 无序时 ZF=1，Asmgen 用 `Cond_and Cond_np Cond_e`（Asmgen.v L260）落地 IEEE 语义（BC5 结论方向不变）。
2. **L143**：`sar` 是向下取整（floor）非向零截断——仅在差为 8 倍数时等价（实际发射场景恒满足，无 bug）。
3. **BC14**：「[2³¹, 2³²) 的尺寸高 32 位丢失（按低 32 位取值）」不准确——`mov edi, imm32` 零扩展对该区间编码正确；应修正为「仅 ≥2³² 按 mod 2³² 回绕」，并补充同族缺陷（F17 cmp imm32 符号扩展、sz 溢出为负静默）。
4. 建议在 BC 表标注 BC-F2I 为死路径（当前无发射方）。

## 6. 修复优先级建议（原决策记录——已全部执行）

> 完成状态：以下各档于 2026-08-16~17 全部修复并合入（维护者授权全修）；本节保留原优先级建议并标注完成状态。

1. **P0（安全）——已修**：F1+F2（直接索引越界——编译期常量界 + 运行时检查 + 写路径钩子）+ F17（大分配检查失效）
2. **P0（崩溃）——已修**：F3（DYN_DISPATCH 全崩溃）、F4（SPAWN 全崩溃）、F15（裸变体崩溃）
3. **P1（正确性）——已修**：F7（I2F 高 32 位）、F8（NaN 比较）、F9/F12/F13（interp 错值）、F14（大尺寸回绕）
4. **P1（机制）——已修**：F5（YIELD 语义 + 堆下溢写）、F6（STORE_PTR 检查链路）、F16（CALL_EXTERN）
5. **P2（工具链）——已修**：F18（重建 build/ + 清缓存）、F19（check 退出码）、F20（dump 名表）
6. **P3（死路径）——已确认，维持**：BC3/BC15/BC17/BC-F2I/BC11——启用/实现时按契约补语义（BC11 已随第四轮波 2 补齐 interp 12 个 opcode；其余维持死路径状态）

> 修复完成（2026-08-16~17）。本清单转为修复记录参考；遗留项（M-2/I-3/lexer 字面量等）见 `TODO.md`「第四轮遗留项」。
