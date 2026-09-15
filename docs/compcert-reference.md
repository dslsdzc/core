# CompCert 后端对照参考（形式化验证过的 C 编译器）

> CompCert：世界上唯一被形式化验证过的 C 编译器（INRIA，Leroy 团队）。
> 整个后端用 Coq 编写并被 Coq 证明正确——学习"验证过的后端"如何写、如何证的唯一教材。
> 本文件是对照 Core 后端的阅读地图。

## 获取源码

网络恢复后执行 `bash ~/get-compcert.sh`（自动尝试 GitHub / INRIA GitLab / 代理）。
或者手动下载 `https://github.com/AbsInt/CompCert/archive/refs/tags/v3.17.tar.gz`。

许可证：GPL v2（研究使用无问题）。

## 目录地图（v3.17 解压后，2026-08-11 已下载到 ~/compcert/）

```
compcert/
├── backend/          ← 后端核心（Coq 源码 + 证明并排）
│   ├── RTL.v         ← 3 地址中间表示（CFG，接近 Core 的 .cir HDFG）
│   ├── Allocation.v  ← 寄存器分配（图着色）
│   ├── Allocproof.v  ← 分配正确性证明（最著名的证明之一）
│   ├── Linearize.v   ← CFG → 线性指令序列
│   ├── Linearizeproof.v ← 线性化正确性证明
│   └── Mach.v        ← 机器抽象层
└── x86/              ← x86 目标（3.17 已合并 x86_32/64）
    ├── Asm.v         ← 每条指令的精确语义模型
    ├── Asmgen.v      ← 指令生成（Mach → Asm）
    ├── Asmgenproof.v + Asmgenproof1.v ← 生成正确性证明
    ├── Op.v          ← 操作语义（运算的数学定义）
    ├── Machregs.v    ← 寄存器定义
    └── TargetPrinter.ml ← 汇编文本打印（对应 Core 的 ELF 编码）
```

> 注：3.17 版本中 `backend/Asm.v`、`backend/Asmgen.v` 不存在——Asm/Asmgen 在目标目录 `x86/` 下；`Architecture.v` 也不存在（由 Machregs.v/Conventions1.v/Stacklayout.v 承担）。

## 与 Core 后端的对照表（v3.17 实际路径）

| CompCert 文件 | 内容 | 对照 Core 的 |
|---|---|---|
| `backend/RTL.v` | 3 地址 IR | `src/compiler/dataflow.cr`（HDFG） |
| `backend/Allocation.v` + `Allocproof.v` | 寄存器分配 + 正确性证明 | `src/compiler/opt.cr`（寄存器分配器） |
| `backend/Linearize.v` | 图 → 线性序列 | `src/compiler/ccr_io.cr` 的格形态 .ccr（v6：段表架构 + ENT 存在结构段；v6-only，见 `specs/2026-09-05-lattice-ir-v6-format.md`） |
| `x86/Asm.v` | 每条机器指令的语义模型 | `src/arch/linux/ld/instr.cr`（指令编码） |
| `x86/Asmgen.v` + `Asmgenproof.v` | 指令生成 + 生成正确性 | `corearch.cr` 的发射逻辑 |
| `x86/TargetPrinter.ml` | 汇编文本打印 | `src/arch/linux/ld/elf.cr`（ELF 输出） |
| `arm/Asm.v` / `aarch64/Asm.v` / `riscV/Asm.v` | 各目标指令定义 | `bootstrap/corec/backend/arm64_asm.py` |

## 两个最值得先看的点

1. **`backend/Allocproof.v` 的证明结构**——回答"寄存器分配正确性到底意味着什么"：
   分配前程序与分配后程序在**什么等价关系**下行为一致（模拟关系 + 良基归纳）。
   这正是 `opt.cr` 缺的那层论证。

2. **`backend/Asm.v` 的指令语义**——CompCert 正确性的地基：每条指令先有精确语义
   （作为数学对象定义，而不是字符串/字节），才有正确性可言。
   Core 的 `instr.cr` 目前只有编码没有语义——差距就在这里。

## 与 Core 的关键差异

- CompCert 生成汇编文本交外部 `as`/`ld`；Core 自己发射 ELF（`src/arch/linux/ld/`）
  ——ELF 输出是 Core 独有、CompCert 没有对照的部分
- CompCert 不验证前端（Clight 语法解析）；它的验证从语义化的中间语言开始
- CompCert 用 pass 分阶段 + 每阶段一个证明；Core 是单趟管线（架构哲学不同，对照时注意）

## 审查发现与修复记录（2026-08-11）

对照 CompCert 审查 Core 后端 + 指针分析链，发现并修复 6 个连锁 bug（安全关键）：

### 已修复（越界检查绕过链——5 个 bug 连锁，单独每个都不生效）

| # | 位置 | Bug | 修复 |
|---|---|---|---|
| 1 | `ptr_analysis.cr` IR_ADDR_INDEX | `&arr[i]` 运行时索引的 offset 无条件传播为数组 offset（0），provenance 误判"编译期安全"→ 越界裸读 | 索引常量可精确算（idx×8），运行时索引 → offset=-1（迫使运行时检查） |
| 2 | `instr.cr` IR_DEREF s3≠0 | ud2 写 `buf[cp]`（应为 `buf[pos+cp]`，污染函数头）；jae 越界跳 .safe（不崩溃）；jne 多 +2 跳指令中间 | 三处编码修正 |
| 3 | `ptr_analysis.cr` alloc 分支 + `get_alloc_size` | 所有 alloc 的 pts 恒设 bit 0（无 alloc 序号）；`get_alloc_size(bi)` 把位号当 DF 节点序号查节点 0 → 恒 -1 → 运行时检查**从设计上不可达** | 新增 `g_pa_alloc_count`/`g_pa_alloc_nodes` 映射表（alloc_seq → 节点序号），get_alloc_size 查表 + 修正 IR_ALLOC_ARRAY size（s1×8 非 s1×s2） |
| 4 | `ptr_analysis.cr` LOAD/STORE 传播 | STORE 传播混进 LOAD 分支（用 dest d，而 IR_STORE 的 d 恒 -1）→ 永不执行 → `p = &arr[i]` 的 offset 传播链断 | STORE 分支独立（s1 ← s2），移到 `if d >= 0` 块外 |
| 5 | `main.cr` build 流程 | provenance 的诊断只记录不拦截，编译期确定的越界照常生成二进制 | build 流程检查新增诊断数 → 打印 + return 1 |
| 6 | `region_check.cr`（3 处） | `alloc_seq := bi + nstart`（位号+函数起点）——修复 3 后位号是全局 alloc 序号，语义错位 → B11 误报 | 查 `g_pa_alloc_nodes` 映射表 |

验证：常量越界（`&arr[100]`）编译期拦截 ✓；运行时索引越界生成 `and $0xfff` + `cmp` + `jae→ud2` + `test` + `jne→.safe` 检查序列（objdump 确认跳转精确）✓。

### 第二轮审查（栈布局/调用约定，任务 2）新增修复

| # | 位置 | Bug | 修复 |
|---|---|---|---|
| 8 | `elf.cr` emit_alloc_body 全局 bump 路径 jbe | jbe 偏移 +14 漏了 `mov rdi,r9`（3 字节）→ 跳到指令中间 → 死循环（**所有无 arena 的堆分配程序挂起**） | jbe 改为 +17 |
| 11 | `elf.cr` 栈帧大小（dry run + 实际两处） | `size = vc*8` 未按 SysV 16 字节对齐：opt≥1 时需 ≡8 (mod 16)（6 个 push 后 rsp%16=8），vc 偶数时未对齐 → 调用点 rsp 未 16 对齐（FFI/外部调用会崩） | 对齐规则：opt≥1 → %16==8；opt<1 → %16==0 |
| 12 | `ptr_analysis.cr` alloc 分支 + `get_alloc_size` | `IR_ALLOC`（标量变量槽标记，不发射代码）被当作堆分配参与 pts 追踪 → `p = &arr[i]` 的 pts 含多个位（污染）→ s3 取错 alloc（标量 8 而非数组 40）→ 正常程序被误杀 | 只追踪 IR_ALLOC_STRUCT/IR_ALLOC_ARRAY |

验证（干净构建）：正常索引 `v=30` exit 0 ✓；越界索引 exit 132（SIGILL）✓；常量越界编译期拦截 ✓。

### 未修复（预先存在，另行处理）

| # | 现象 | 影响 |
|---|---|---|
| 7 | ~~字符串拼接 + println 崩溃/挂起（`"AB"+"CD"`）~~ **已修（2026-08-16 第四轮复核）** | 见下方「迁移后复核」 |
| 9 | ~~数组读取值错位（ptr_arith 的 `*p != 30`——旧工具链产物）~~ **已修（2026-08-16 第四轮复核）** | 见下方「迁移后复核」 |
| 10 | ~~region_check B11 对 deref 读出的 int 误报指针逃逸~~ **已修（2026-08-16 第四轮复核）** | 见下方「迁移后复核」 |
| 13 | ~~float 类型是壳~~ **已实现（2026-08-11）**：字面量（IEEE 754 位模式，±1ulp）+ 算术（addsd/subsd/mulsd/divsd）+ 比较（comisd+setcc），运行时验证通过——即 apx 后端快路径（binary64）的早期实现（当时类型名为 float，2026-08-16 设计定案迁移为 dex + apx） | 待续：int↔小数转换、XMM 参数传递、小数打印（阶段 4-6 完成） |
| 14 | `.ccr` 序列化 s1 用 32 位（buf_write_i32）——大 int 常量 / 小数（当时 float）位模式 > 2^31 被截断（静默损坏） | 修复：s1 改 64 位（写/读/尺寸同步） |
| 15 | `buf_read_i64` 缺 `h3 < 128` 的 else 分支——高位字节（bit 56-62）贡献丢失（0x4009... → 0x0009...） | 修复：补 else 分支 |
| 16 | ~~`int_str` 对部分值返回空字符串（int_str(7) 恒空、int_str(567) 编译相关不稳定）——打印链 bug（预先存在，大数路径暴露）~~ **已修（2026-08-16 第四轮复核）** | 见下方「迁移后复核」 |

#### 迁移后复核（2026-08-16，第四轮，只读）

| # | 状态 | 证据 |
|---|---|---|
| 7 | **已修** | `println("AB"+"CD")` → ABCD、exit 0（无崩溃/挂起）；check_error 消息完整（error[N06] 带源码定位） |
| 9 | **已修** | tests/suite/ptr_arith.cr 重编译运行 exit 0（`*p==30`、`*q=99` 写后读全过） |
| 10 | **已修** | 4 变体（数组/循环数组/循环子图堆分配/结构体字段 deref 读 int 后 return）编译零诊断 + 运行 20/20/102/10 全正确；region_check_all 在 build 管线恒运行（main.cr:495），有诊断即构建失败——编译成功即证无误报 |
| 16 | **已修** | int_str(7/0/567/-5/12345678) 打印全正确，exit 0（含边界与大数；3.14→"3.4" 精度丢失路径消失） |

## 小数运算（binary64）实现记录（阶段 4-6，2026-08-11；当时类型名为 float，2026-08-16 设计定案后语义归入 apx 后端快路径）

| 阶段 | 内容 | 验证 |
|---|---|---|
| 4 | int↔小数转换（当时 float = binary64，即 apx 快路径）：IR_I2F/IR_F2I + cvtsi2sd（F2 0F 2A）/cvttsd2si（F2 48 0F 2C）；ir_gen 小数运算中 int 操作数隐式转换 | `3.14 + 2`（int 2 隐式转）> 5.0 → exit 0 ✓ |
| 5 | XMM 参数传递（SysV：int 用 ir 0-5 → rdi..r9，小数（当时 float）用 fr 0-7 → xmm0-7，独立编号）+ 小数返回（xmm0）+ 栈参数（小数超 8 用 sub+movsd） | `add_f(1.5, 2.5)` = 4.0 > 3.9 → exit 0 ✓ |
| 6 | 小数打印：`float_str_bits`（位模式 → 十进制，长除小数提取 + 去尾零 + 简单舍入）——迁移后为 dex 打印（保留为 apx 路径实现） | 2.0→"2"、0.5→"0.5"、6.5→"6.5"、-1.0→"-1" ✓；3.14→"3.4"（int_str bug 干扰，见发现 16） |

## 寄存器分配对照结论（任务 3，2026-08-11）

对照 CompCert `backend/Allocation.v` + `Allocproof.v`（图着色 + 溢出 + 模拟关系证明）审查 `opt.cr` 的 `alloc_registers`（线性扫描）：

| 对照点 | CompCert | Core | 结论 |
|---|---|---|---|
| 分配算法 | 冲突图着色（干涉图）+ 溢出 | 线性扫描：活跃区间 [first,last]，每变量独占寄存器、**从不重用** | ⚠️ 保守正确但浪费（5 寄存器后全栈） |
| 正确性条件 | 着色无冲突 + 模拟关系证明 | 变量独占寄存器 → 无冲突（隐式满足） | ✅ 正确 |
| 活跃性 | 精确 liveness（控制流敏感） | 线性区间近似（保守） | ✅ 正确（保守） |
| 跨调用存活 | caller/callee-saved 混合 | 只用 callee-saved（rbx,r12-15，prologue push/epilogue pop） | ✅ 正确（简化但有效） |
| 溢出 | 图着色溢出到栈 | 无溢出——超 5 变量全栈 | ⚠️ 性能差距 |

**O2 运行验证**（首次验证，全部通过）：简单运算（42 ✓）、跨函数调用（callee-saved 保护，30 ✓）、循环（45 ✓）、指针 deref（✓）、越界 SIGILL（132 ✓）。

**未发现正确性 bug**——差距在优化能力（寄存器重用/溢出/精确活跃性），非正确性。

## 调用约定对照结论（任务 2 完整版）

| 约定点 | CompCert（SysV） | Core | 结论 |
|---|---|---|---|
| 整数参数寄存器 | DI,SI,DX,CX,R8,R9 | rdi,rsi,rdx,rcx,r8,r9 | ✅ 一致 |
| callee-saved | rbx,rbp,r12-r15 | 同 | ✅ 一致 |
| 栈参数（第 7+ 个） | S Outgoing，调用点 [rsp+0..] | push r10（右到左）+ add rsp 清理 | ✅ 一致 |
| 栈帧 16 字节对齐 | frame_env_aligned 证明 | 修复 11 前未对齐 | ✅ 已修 |
| 返回值 | rax（128 位用 rdx:rax） | rax（无 128 位类型） | ✅ 一致 |
| varargs | 调用点 AL = XMM 参数数 | 不设 AL（无小数参数 → AL 无意义） | ✅ 无小数参数时正确 |
| outgoing 区域 | 固定帧内区域 | push/add 临时区 | ✅ 功能等价 |
| 小数参数（当时 float） | XMM0-7 | 无 SSE 实现（发现 13；阶段 4-5 已补 XMM 传递） | ❌ 当时为类型壳（apx 快路径后已实现） |

## 第四轮对照审查记录（2026-08-16，只读）

- 契约：`docs/ir-op-semantics.md`（IR 操作语义表——Task 1，对照 Op.v/Asm.v/Values.v/Integers.v/Floats.v/Memory.v 逐 opcode 定义）
- 发现清单：`docs/compcert-round4-findings.md`（Task 2 只读审查产物——F1-F20，含证据分级与修复优先级）
- **流程**：四组并行只读审查（算术/转换、内存/安全、控制流/调用/并发/动态、未修复项复核）+ 清单任务审查（spec ✅）——**全程未修改任何 Core 代码**；修复范围待维护者反馈后另行授权（反馈门）
- 核心结论：
  - **安全类**：直接数组索引越界守卫双重死亡（F1/F2，`arr[100]` 静默越界）——`&arr[i]` 路径第一轮已修、直接索引路径仍无检查；DEREF 检查对大分配（alloc_sz≥2³¹）失效（F17）
  - **崩溃类**：DYN_DISPATCH rel8 补丁错位（F3，已知 tag 也崩溃）、SPAWN 操作数约定错位（F4）、枚举裸变体（F15）、CALL_EXTERN 不传参（F16）——均 SIGSEGV
  - **正确性**：I2F 缺 REX.W（F7，|a|≥2³¹ 转 float 错误）、NaN 比较（F8）、解释器无 TI_FLOAT 分支/STORE_PTR 槽拷贝/枚举 payload 损坏（F9/F12/F13）、分配尺寸 ≥2³² 回绕（F14）、YIELD 堆下溢写（F5）、SLICE 无 high 界守卫（F11）、Python 解释器除/模方向（F10）
  - **工具链**：build/ 产物与 HEAD 源码不一致（F18，dex 实验残留，需重建 + 清 .core/cache）、check 退出码（F19）、dump 名表缺 49/50/29（F20）
  - **死路径**（启用时需按契约补语义）：OP_SHL/SHR、OP_AND/OR、EC_R_*、IR_F2I 无发射方、interp 12 个未实现 opcode
  - **证伪/正常**：DEREF off-by-one 数学精确、float 字面量 mov imm64、setl/setg 族、FNADDR/HOTPATCH/枚举布局/DYN 双槽/BRANCH-JUMP/LAZY/AWAIT 三方一致
  - **语义表修正**（3 处）：cmpf_bool 对 NaN 为 `Some false`（非 None）；sar 为向下取整（8 倍数等价）；BC14 仅 ≥2³² 回绕（[2³¹,2³²) 表述证伪）
- 未修复项 7/9/10/16 迁移后**全部已修**（见上表）

## 第四轮修复记录（2026-08-17）

修复授权：维护者（2026-08-16 反馈门通过，授权全修 F1-F20）。分三波合入，commits 以 jj change id（commit 前缀）标注：

| 波 | 内容 | 提交 | 验证要点 |
|---|---|---|---|
| 波 1（安全/内存） | **F1/F2**（直接索引越界守卫：CORE_SAFE 默认开、ext 注册表 16 字节记录布局修复、ir_gen 传真实数组长度 + 写路径钩子、checker 编译期常量界检查 R002/TK05/TK06）、**F6**（STORE_PTR s3=0 保留 null 陷阱，拆 `e2_ptr_null_check`）、**F11**（切片字面量界侧表 + 创建期检查 + provenance 传播，interp 补 SLICE/BOUNDS_CHECK）、**F14**（分配尺寸改 `movabs rdi, imm64`，溢出按 OOM）、**F16**（CALL_EXTERN 装载 SysV 参数 + 静态构建 extern 未解析报编译期错误）、**F17**（边界比较改 `movabs rcx, imm64` + `cmp rax, rcx`，ud2 写位置修正 pos+cp）；附带：concat 结果标注 string 类型、字符串长度头按存储字节数 | suwmxstmxvzz（901a33b865b0）；rmktsvmlqrzq（570193a48412）；zuzmpruwlxqw（82cfeaa1812e） | 常量越界编译期拦截（编译零诊断/运行正确）；运行时越界 SIGILL（132）；null 陷阱保留；≥2³¹ limit 无符号正确；≥2³² 尺寸不回绕；extern 缺符号编译期失败（不再 rel32=0） |
| 波 2（浮点/解释器） | **F7**（cvtsi2sd 补 REX.W，`e2_sd_cvt`）、**F8**（float `==`/`!=` 改 `setnp+sete`/`setp+setne`，对照 Asmgen.v L260）、**F9/F12/F13/BC11**（interp：TI_FLOAT 走 f64.cr IEEE 754 软件实现、STORE_PTR 与 ELF 操作数一致、枚举按堆布局、12 个 opcode 补齐）、**F10/BC2**（bootstrap 除/模 abs+符号向零截断，补四组负操作数回归）、**F20**（opcode 名表补 IR_AWAIT/BOUNDS_CHECK/ADDR_INDEX/I2F/F2I/NOP）；f64.cr 新增（add/sub/mul/div 就近偶数舍入 + 6 比较含无序 + i64_to_f64/f64_to_i64，**减法分支 RNE 1-ulp 借位修正**）；lexer `str_to_f64_bits` 终止展开；interp IR_BINARY 统一分派重构 + callee 内联指针模型 | pvnrqpkvuuku（9d63d6837096）；ynpzokvrnnlu（2d2f6060180e）；yulkvmmrqxmy（6abb8e959581）；ovltyurunnxk（e3e0ae22a076） | 差分验证 125760 项 + 偏置 119592 项 + 随机减法 150000 项（5→0）+ 偏置加法 147648 项全 0 失败；端到端 2.5−b 翻转；新增 test_interp_float.py / test_native_float.py；f64.cr 入自举构建清单 |
| 波 3（控制流/调用/诊断） | **F3**（DYN_DISPATCH rel8 补丁加 pos 基）、**F4**（SPAWN 操作数约定统一 s3=函数名 + 补 SysV 参数装载）、**F5**（YIELD 改 eager 值传递近似 + interp d≥0 守卫 + flow fn 语法修正）、**F15**（枚举裸变体发射无 payload MAKE_ENUM）、**F19**（check 子命令诊断 rc=1）；**I-1**（read_file procfs 伪文件循环读取——lseek SEEK_END 返回 0 场景，get_env 检查分支可达）、**I-2**（syscall4 第 4 参经 r10 传递——wait4 rusage，修复前 r10 残留垃圾→内核 EFAULT→退出码传播不可靠） | rmypkzyqlmwu（37452789e7b2）；lsusukvvovlv（4311ea4a41e3）；xmmrklzyulzl（9cb5c84715ed）；myvkpzqkvkku（b142c334eeec）；wynytvqmzywp（89c9cd9c654c） | 已知/未知 tag 分发正确（反汇编 `74 xx` 补丁精确，不再 139）；`go` 语句 exit 0；YIELD 三方一致（堆下溢写消除）；裸变体 exit 1；check 诊断 rc=1/无诊断 rc=0；get_env 在 CORE_SAFE=0 下检查分支可达；wait4 rusage 传递可靠 |

附注：

- **F18（环境项）**：build/ 产物重建 + 清缓存——修复验证均基于全新重建产物（build/corec + corearch，2026-08-17 00:27），消除 dex 实验残留污染。
- **test_directory_build 回归**：波 3 审查发现（波 1 附带修复「字符串长度头按存储字节数」对转义形式计数偏长，GAS .asciz 反转义后引号类比较恒失败→Core.toml 项目名读取失效）——**已修**（nsysysyukvyv c8c4d22f：长度头改按**原始字符串 UTF-8 字节数**，同时覆盖中文按字符数偏短与转义按转义形式偏长两种情况）。
- 修复后遗留项（M-2/I-3/lexer 字面量等）见 `TODO.md`「第四轮 CompCert 对照遗留项（2026-08-17 记）」；语义表已同步（✅ 标记 + BC 表状态列，见 `docs/ir-op-semantics.md` §5/§7）。
