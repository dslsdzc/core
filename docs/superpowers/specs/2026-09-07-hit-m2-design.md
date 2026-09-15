# HIT M2 设计（运行时核事件集 + 全表驱动收口）

日期：2026-09-07
状态：设计定稿（方案 1 拍板 + 节 1-3 逐节确认）
关联：`specs/2026-09-05-hardware-interface-table.md`（HIT 母 spec——§2 事件模型修订 + §6 M2 细化，本文为其实施设计）、`plans/2026-09-05-hit-minimal-core-m1.md`（M1 收官 + 偏差四项）、`TODO.md`「HIT 最小核」节（M2 挂账五条）、`specs/2026-09-07-regalloc-backend-design.md`（优化不进表——分配已归位 corearch 格形态层，本 M2 与其正交）

## 1. 背景与 M1 边界

M1 已落地最小核运行闭环：`core-x86.toml`（4 事件 × 单步投影模板 `{opcode ≤2B, reg_role, rm_role, rm_mode}`）→ `hit.cr`（表加载/查询）+ `lower_to_core.cr`（IR 直线子集 → 事件流 + 常量池）→ `emit_instr_tabled`（corearch `--table`，与旧路径并行、逐字节对照）。冒烟 = sub/add/mem exit 正确，11/11 测试绿。

M1 边界（本设计的起点）：
- **直线子集**：无 IR_BRANCH/JUMP/LABEL/CALL/RETURN 值/SPAWN——超子集 op 大声拒绝（'needs more events'）
- **4 事件 = 纯数据事件**：sub/nand/load/store 无控制转移能力——经典投影下分支/调用**不可合成到它们**（控制转移 = PC 语义，非数据事件）。M1 的「4 事件即可运行任意 Core 程序」表述仅在数据计算子集上成立
- **混合模式**：表覆盖 op 走表、未覆盖落旧路径（`emit_instr_tabled` 返回 -1 → `emit_instr`）
- nand 真语义（and+not 两步）未实现（单步 and 占位）；const 池无负值/宽值载体；`--table` × `--link/--shared` 显式拒绝；tagged/2L 路径整条落旧路径

## 2. 事件模型修订（运行时核）

**拍板（D-a）：表事件集 = 运行时核 9 事件**——4 数据事件保持（= 数据计算可移植子集），新增 5 个控制/调用/系统事件：

| id | 事件 | 签名要点 | 投影形态（x86） |
|---|---|---|---|
| 1-4 | sub/nand/load/store | 不变（M1 定稿） | 不变（M1 模板） |
| 5 | jump | 无条件转移，目标 = 事件流位置 | rel32 无条件跳转（模板 rel32 回填角色） |
| 6 | branch | 条件转移：条件 = 槽源（s1 值 ≠ 0 真），真/假双目标（事件流位置） | cmp + jcc 序列或 test+jcc（两步序列 + 双 rel32 回填） |
| 7 | call | 函数调用，目标 = 函数索引（.ccr REG root span 行序） | x86 call rel32（函数体 = 事件流子序列；回填目标 = callee 事件流位置） |
| 8 | ret | 函数返回（调用栈机制 = 运行时条目） | x86 ret（栈约定见 §7） |
| 9 | extern | 外部符号调用（系统边界；IR_CALL_EXTERN） | call 至外部符号（重定位机制复用旧路径 ext_rel） |

- **母 spec §2「最小核 4 事件即可运行 Core」表述修订为**：数据计算可移植子集 = 4 事件；完整程序 = 运行时核（9 事件，每表必备）——换表仍换平台（运行时核 + 投影列均为表内容）
- 扩展直通事件（add/and/or/xor/mul/div/cmp/shift 等 = id 10+）**可选**：表声明则降低层直通，未声明则 4 核合成（spec §5「查表优先，无表项再合成」落地）。**x86 大表 = 数据事件直通条目全量声明**（M2c 收口产物）
- branch 双目标 vs 单目标形态：IR_BRANCH(s1=条件, s2=真目标, s3=假目标) 天然双路；模板支持双 rel32（无条件侧 = 相邻 +5 跳过技巧由模板序列表达，不新增事件）

## 3. 表格式 schema v2（投影模板语言扩展）

**拍板（D-b）：`core-x86.toml` schema v2**——模板步（step）从 M1 的 5 字段扩展为完整形态描述；按 instr.cr 现有形态族收敛（YAGNI：不做全 x86 指令集，只覆盖编译器发射面）：

```
step = {
  prefix: [u8...]                    # 前缀（66/0F 等，≤2）
  rex:   {w, r, x, b}                # REX 位（无 REX = 省略）
  opcode: [u8 1..3]
  modrm: {reg_role, rm_role, rm_mode}  # rm_mode: 0=reg / 1=rbp+disp32 / 2=SIB
  disp:  {size, src}                 # disp32 寻址（rm_mode 1/2）
  imm:   {size 1|2|4|8, role}        # 立即数角色（槽值/常量）
  rel:   {role, kind}                # rel32 回填（目标 = 事件流位置 | 函数 | 外部符号——kind 决定回填表）
  cond:  {role}                      # branch 条件源槽（cmp/test 序列的操作数角色）
  seq:   [step...]                   # 两步以上序列（nand = and+not；branch = cmp+jcc）
}
```

- 回填角色（rel kind）：M1 常量池 `hit_pool_patch` 机制扩展为三张回填表——事件流内部目标（jump/branch/call 函数体）、函数起点、外部符号
- 角色解析复用 M1 约定：操作数角色（dst/src1/src2/val/addr/cond）→ 槽（`g2_slot`/`e2_load_var` 机制）或事件流位置
- **每事件多形态**：事件可带多个 proj 条目（如 load 的 rm_mode 0/1/2 各一形态），发射按操作数形状选择（现 instr.cr 按类型/形状分发——数据化后 = 表内选择）
- **字段扩展注（Task 0 盘点 2026-09-07 回填，先于 Task 2 落地）**：modrm 增 base_role（rm_mode 1 泛化——缺省 rbp，可 = 槽值寄存器；rm_mode 2 细化 = SIB 字段组 {scale, index_role, base_role}；base_role=rip = mod=00 rm=101 池/全局/rodata 形）；modrm 可缺（E8/E9/C3/0F05/0F0B）且 reg_role 可为 /digit 操作码扩展（C6/C7/F6/F7/D3/C1）；rel 补 size {8|32}（rel32 三角色 kind 已有）；imm 补 lit 字面量与 imm64 回填 kind（movabs 函数绝对地址）；操作数角色集补寄存器字面量/隐含（rcx 移位计数、rax/rdx:rax idiv/cqo 对、ABI 调用寄存器、xmm0-7 为 SSE 面预留）；disp.size 支持 auto（槽偏移回填按幅度选 1|4——解释器规则，与旧路径 e2_ld/e2_st 选择一致）；字节拼接序 = prefix → REX → opcode → ModRM → SIB → disp → imm（解释器固定序，非字段）。

## 4. 降低层设计（lower_to_core 全 op 覆盖）

**拍板：直通优先、合成兜底**：

- **数据 op**（add/sub/mul/div/and/or/xor/not/shift/cmp/select/const 等）：表含直通事件（id 10+）→ 事件直发；表无 → 4 核合成规则表补齐（M1 已有 add 反减；nand 真语义 = and+not 两步序列；or = 德摩根；xor = 组合；cmp = sub + 符号判别落槽；const = 池 load 扩展**负值/宽值**——池记录带宽度域，8B 槽装不下时借位链落 16B（M1 偏差 #3 载体落地））
- **控制流**：IR_LABEL/IR_JUMP/IR_BRANCH → jump/branch 事件；**标签 → 事件流位置映射**（IR label id 表 + 两遍法：遍 1 记 label 事件序位置、遍 2 回填 rel32——事件流生成后回填，同常量池 patch 先例）；函数级控制（loop/for/if-else 已由 IR 标签序展开，region 结构不参与事件流）
- **调用**：IR_CALL → call 事件（callee = 函数索引——.ccr SYM func 行序 + REG root span 边界；函数体事件流位置 = 降低时按函数序排布后回填）；IR_RETURN 值 → ret 事件 + 返回值槽约定（§7）；IR_CALL_EXTERN → extern 事件（符号名 → 外部符号表）
- **tagged/2L 路径（多字）**：2L 算术/比较的 IR 形态 = BINARY 溢出链 + 辅助块——M1 偏差「tagged 落旧路径」的根因 = 发射层块（jo 慢路径/2L 操作数块）不走表。M2 处置：**2L 快路径（无溢出）op 走表直通/合成；溢出慢路径块 = 序列算法保留代码**（§5 数据化边界同款——块内单指令查表，块序算法保留）
- **SPAWN/goroutine/通道**：IR_SPAWN 等 = 编译器自用面（corec 自举需要）——降低层接现有运行时函数（goroutine 包装）→ extern/call 事件表达；若个别 op 无事件且不可合成 → 保留旧路径（混合）至 M2d 终态前逐项清点（自举语料实证覆盖）

## 5. 发射数据化收口（全表驱动）

**拍板（D-c 边界）：数据化范围 = 单指令编码形态；序列算法保留代码（调模板）**：

- instr.cr 2381 行按形态族逐块迁移（sz_* 族 + e2_* 族清单在 writing-plans 时逐函数盘点）：单指令编码（前缀/REX/opcode/ModRM/disp/imm/rel）→ 表数据；**每个迁移块以旧路径逐字节对照为判据（表模式产物 byte-identical = 模板正确性判据延续 M1）**
- **保留为解释器算法的序列**（非平台特有 = 表外）：prologue/epilogue、参数拷贝、2L 慢路径块、函数帧布局（g2_slot 帧公式）、分配/判定（格形态层——regalloc-backend 已定优化不进表）
- 收口完成态：`emit_instr` 硬编码分发 → 表数据查询 + 模板解释器；旧路径与表路径**汇合为同一条**（表 = 唯一发射真源；「混合模式」概念消失——所有 op 都有表条目或合成规则）

## 6. 运行时条目（最小描述）

**拍板（D-d）：运行时条目数据入表 + 校验；解释器实现当前 x86 ABI 一档**（多 ABI 通用解释器 = YAGNI）：

```
runtime = {
  call:    {机制 = 栈, 返回地址位置, 栈生长方向}
  param:   {传递 = 栈 | 寄存器集（条目声明；x86 档 = 栈传递 + 现行约定）}
  save:    {callee-saved 集}          # 与分配器 callee-saved 集一致（rbx/r12-15）
  extern:  {入口约定, 符号解析}
}
```

- 解释器读取运行时条目生成 call/ret 序列（参数拷贝/栈帧 = 代码算法按条目参数化——**条目数据驱动序列选择，非每 ABI 一份代码**；x86 档 = 参数化实例之一）
- rt.s/静态链接机制复用（自举产物 = 静态自包含 ELF 同现路径）
- 表校验：事件集必备性（运行时核 9 事件缺失 → 拒绝）、rel kind 与模板一致性

## 7. 测试与验收链

1. **模板对照**：每个新形态/新事件模板 → 同源程序表模式 vs 旧路径 ELF **逐字节对照**（M1 判据延续）+ 单事件定向用例
2. **suite 覆盖**：`tests/suite/*.cr` + 自写覆盖（控制流/循环/函数调用/递归/打印/内存/位运算）表模式 exit 断言全绿——**混合过渡态判据（M2b）**
3. **组合验证**（M1 偏差清点）：HIT × tagged/2L（2L 快路径走表 + 慢路径块）、`--table` × `--link/--static`（extern 重定位）、O2 分配在表模式（**M2 拍板：表模式恒 O0 全栈发射不变**——优化 = 格形态层与表正交；表模式 O2 恢复 = 发射器汇合后自然解锁，挂账 M3））
4. **自举验收**：M2b 末——表模式（混合过渡态）corec 编译自己跑通（提前暴露降低/调用层的全语言面问题）；M2d 末——汇合后纯表（零旧路径残留）corec 编译自己跑通（全表驱动收口终验）

## 8. 里程碑分段（M2a-d，writing-plans 分解为任务）

- **M2a 事件集 + 模板语言 v2**：schema v2 解析（hit.cr 扩展）+ jump/branch/call/ret/extern 投影模板 + 模板解释器新形态 + 逐模板对照测试
- **M2b 降低层全 op**：控制流标签映射/回填、调用降低、合成规则补齐（nand 真语义/负值宽值池/直通优先）+ suite 与自写覆盖绿（混合过渡态）+ **自举冒烟（混合态先行验证——全语言面提前实证，风险处置）**
- **M2c 发射收口**：instr.cr 形态族逐块数据化（byte-identical 回归逐块绿）+ 汇合（emit 单路径——表 = 唯一发射真源，混合模式概念消失）
- **M2d 运行时 + 纯表自举**：运行时条目数据化 + call/ret/extern 序列参数化 + 组合验证清点 + 纯表自举收口（零旧路径残留终验）+ 文档（母 spec §2/§6 修订回填 + TODO 清账）

## 9. 风险与处置

- **自举工程量**：表模式必须支持编译器自用全语言面——处置：全 op 降低覆盖在 IR 层（与源特性正交——IR op 全集固定）；自举语料 = 实证收口，混合态先验降风险
- **模板表达力边界**：个别编码形态 schema v2 未覆盖 → 处置：形态族清单先盘点（writing-plans 前置任务——读 instr.cr 全 2381 行分类），schema 按清单定稿；迁移中发现新形态 → 字段扩展 + 对照测试先行
- **call/ret 与 2L 慢路径/帧布局交互**：调用点 2L 值跨函数 = M1 已知边界（无协议）——处置：保持现状边界（表模式与旧路径同语义面），不扩 2L 调用协议
- **性能/体积**：自举 .ccr 事件流 + 回填规模——处置：对照测试先行,必要时降低器局部优化（非本里程碑验收项）
- **回归面**：instr.cr 逐块迁移风险——处置：每块迁移独立提交 + byte-identical 对照 + 全套回归（mw1-6/live_ranges/ccr_v6/region_cfg/compile/backend_bootstrap）

## 10. 拍板记录（2026-09-07 用户确认）

1. **范围 = A+B 全量**（母 spec §6 M2 全表驱动 + TODO 挂账全项；按依赖排序分批执行）
2. **验收语料含自举**（M2 终态 = corec 经表模式编译自己成功运行；suite + 自写覆盖为过程判据）
3. **方案 1**（运行时核事件集 + 降低完备 + 发射数据化收口；方案 2 图调度、方案 3 crasm 直通表 = 否决）
4. **节 1**：9 事件 id 分配 + 每表必备运行时核 + schema v2 字段集
5. **节 2**：数据化边界 = 单指令编码（序列算法保留代码调模板）；运行时条目最小描述 + x86 一档
6. **节 3**：M2a-d 分段 + 验收链（模板对照 → suite → 组合 → 自举两段）
7. **M2 附加拍板**：表模式恒 O0（优化 = 格形态层，与表正交；表模式 O2 恢复挂账 M3）

## 11. 关联文档同步项

- 母 spec（2026-09-05-hardware-interface-table.md）§2 表述修订 + §6 M2 状态（M2d 收尾回填）
- TODO.md「HIT 最小核」节 M2 挂账清账（逐项随里程碑提交划除）
- M1 plan 偏差注记（随 M2b/c 清点划除）
