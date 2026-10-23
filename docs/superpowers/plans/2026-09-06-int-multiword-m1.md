# int 多字表示 M1 实施计划（add/sub 全链：64 快路径 + 溢出 2-limb 扩展）

> 状态：M1 六任务全部完成（2026-09-07，Task 6 结束）。Task 2-6 各自回归加结束全量回归均通过。快路径 64 位内程序逐字节零变化，证据是 task2 z 用例和 backend_bootstrap stage1 到 3 byte-identical。M2 待办清单见 Task 6 执行记录与 spec 第 8 节。

> 面向执行本计划的 agent：必须使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans，按任务逐项实现。用复选框（`- [ ]`）跟踪进度。

目标：后端表示策略 B 的 M1。int 算术 add/sub 在 64 位快路径零开销直算，溢出时自动提升到固定 2-limb（128 位）多字表示。语义层（前端、图、格）零改动，只在编码层投影。

结构：语义 int 无上限（`specs/2026-09-06-int-unbounded-semantics.md` 定稿），编码层投影按本计划执行。D1a 使用 tagged 值槽，快值 64 位，多字对象指针加旁路 tag。D2b 在后端发射溢出检测，add/sub 加 jo 到慢路径。D3 固定 2-limb 128 位，超 128 报编码层错误。D4 超 64 字面量用词素重建进 rodata 2-limb，并引用 IR 常量池，复用 IR_LOAD 常量地址机制和 HIT 常量池先例。D5 分期实现 add/sub。D6 是寄存器分配形态，Task 5 定案为 tagged 变量可以驻寄存器，指针加帧 tag 自洽，见 Task 5 节。

技术栈：Core 自举编译器后端（src/compiler/opt.cr、src/arch/linux/ld/instr.cr/elf.cr、src/runtime/rt.s）、Python bootstrap（构建）。参考：HIT 常量池（src/arch/hit/lower_to_core.cr，rodata 2-limb 槽与引用先例）、CAG 分配器（opt.cr，D6 多字只栈接入点）。

## 全局约束

- 版本控制用 `jj`，见项目规则第 2 条。提交用 `jj commit -m`，不动 bookmark。
- 构建 `nice -n 19 python3 build_selfhost_native.py`，每次改动后重建，约 2 分钟。测试用 `bash -c 'ulimit -c 0; ...'`。
- 语义层零改动：前端、IR 语义、图、格都不变。int 算术仍是数学整数 IR，只有 IR_CONST 超 64 字面量走常量池引用路径。
- 快路径行为零变化：64 位内程序的 exit 和输出与现状完全一致，全套回归覆盖。
- 溢出检测只在后端发射，IR 不增加溢出感知操作。
- 设计定稿：`specs/2026-09-06-int-multiword-backend-design.md`，决策点按本计划开头确定。
- M1 范围：add/sub 溢出全链。mul/div/比较多字、打印多字、动态增长属于 M2 及以后。
- 测试：trap 类用 `ulimit -c 0`；回归 compile/ccr_v6/region_cfg/live_ranges/hit_table/backend_bootstrap 加 corec check src/compiler。

---

## 现状事实（执行前必读）

- int 变量是 64 位栈槽，g2_slot 偏移布局由 init_backend_arrays/opt 定。寄存器分配使用负编码，CAG 后才是真实分配。
- IR_BINARY(OP_ADD/SUB) 后端发射：e2_load_var(r10,s1) 加 e2_load_var(r11,s2) 加 opcode 加 modrm 加 e2_st(r10, slot d)。这是 instr.cr 的双寄存器累加形，x86 sub 为 4D 29 DA，add 为 4D 01 DA。
- x86 溢出检测：add/sub 后接 jo。实现为 0F 80 rel32 6B。Task 2 决策：rel8 的 ±127 对大函数不可达，下文「rel8」括注同义。
- HIT 常量池先例：rodata 尾追加 8B/槽，加 rip 位移回填（lower_to_core.cr + elf.cr）。
- IR_CONST s1 是 i64 槽（64 位）。超 64 字面量目前在 lexer 被拒，P2 守卫是编码层限制错误，见 int-unbounded 定稿。

## M1 设计决策（依草案倾向）

- D1a：值槽 64 位（现状不变），加旁路 tag 表。每函数潜在多字变量一个 tag 槽位。栈帧扩展：函数 var_count 不变，tag 区是栈帧尾附加区域，按「可能溢出变量」位图或每变量 1 槽。
- D2b：纯后端发射。快路径 add/sub 后接 jo 到慢路径块，块内是 2-limb 例程，代码内联或调用。
- D3：2-limb 128 位固定，低 limb 是快值，高 limb 是符号扩展。超 128 溢出报运行时错误，即编码层 128 限制，M1。
- D4：超 64 字面量是词素。.ccr 是否已存需要查：NOD 的 src1 是 i64，装不下，是否扩展 ccr_io 常量？最小方案是 lexer 不再拒绝，但 IR_CONST 无法表示。M1 决策：超 64 字面量仍由前端拒绝，保留编码层错误消息。常量多字属于 M2。D4 推迟，因为 IR_CONST 的 64 位槽是格层表示，扩展需要 v6 常量段，与 dex 精度同族，待 v6 处理。M1 只做运行时溢出，即运行时值运算结果超 64。编译期超 64 常量留 M2。
- D5：add/sub。
- D6：可能溢出的变量（慢路径可达）不进入寄存器。分配器静态标记：函数中含可能大值运算的变量只放栈。保守 M1 曾考虑「含 add/sub 结果的所有 int 变量都是潜在多字，因此只放栈」，这个范围太宽。M1 精化为慢路径输出变量 tagged，分配器对 tagged 槽变量不分配寄存器，保守性能可以接受。Task 5 定案修订为不排除，实证见 Task 5 节。

## 慢路径形态（M1 设计）

```
快路径：add r10,r11，然后 jo slow_n（jo 用 rel32 0F 80，Task 2 定案）
慢路径块 slow_n：值已在 r10/r11（环绕结果）
  正确 128 值 = 符号扩展重建：[r10 结果, 高位 = (r10<0 ? -1 : 0)]
  （add 溢出结果低 64 位 = r10 环绕值。数学和 = 环绕低 64 + 进位修正？
   add 溢出 jo 后 r10 = 环绕和；真值 = 环绕和 + (2^64 or -2^64)，由 CF/OF 判定）
  存 2-limb 到槽对（低槽 = 环绕值 + 高槽 = 修正）
  设 tag（该槽对 = 多字态）
```

实现简化候选是槽对模型：每个潜在多字 int 变量占 2 槽，低 64 加高 64 符号扩展，合计 128 值。快路径只写低槽，高槽是否隐含符号扩展？不行。快路径值的高槽恒为符号扩展，写低槽时同步写高槽需要 2 次 store，有性能损失。因此采用 tag 方案：值槽保持 64 位，快路径单 store；多字时值槽存指针，指向 2-limb 堆对象，tag 置位。tag 位放旁路，每潜在变量 1 字节 tag 区。慢路径写 tag 和指针，快路径不碰 tag。

最终 M1 表示，实现者按此细化：

- 潜在多字变量（慢路径可达，即本函数有 add/sub 且变量处于其结果链）在栈帧附带 tag 字节和值槽 64，值为快值或 2-limb 堆指针。
- 慢路径：jo 后走内联修正代码。数学值等于 r10 环绕值加 OF 判定的 ±2^64。用 jo 后的 r10 和 CF 重建高 limb，保证数学正确。然后从 arena 分配 16B 堆，写 2-limb，值槽存指针，tag 置位。
- 消费者（后续 add/sub/return）必须读 tag：tag=0 时快值直用；tag=1 时解指针取 2-limb。M1 中慢路径结果再参与算术需要 2-limb 算术原语。是否限制慢路径结果只能 return 或比较而不再次算术？这个限制不可取。真正的 2-limb add 原语是 M1 必需的，包括 2-limb 与快值混合 add。实现者按最小正确方案处理：提供 2-limb add/sub 例程，值等于 a+b 的数学结果，低加低带进位链，高加高。例程放 rt.s 或内联。

M1 完整性边界，实现者执行时若超界要披露：add/sub 结果超 64 后 2-limb 表示正确；后续 add/sub、比较、return 正确处理 2-limb；打印（int_str）超 64 值正确。M1 是否包含打印？不含则 return 大值时 exit 码截断，仍可视为正确（低 8 位），打印多字属于 M2。M1 验收标准是运算链正确，最终值数学正确，经 return 低 8 位或测试钩子验证全 128。

---

### Task 1: tagged 槽框架（潜在多字变量识别 + tag 区 + 栈布局）

文件：opt.cr（识别和 tag 区布局）、instr.cr/elf.cr（槽偏移）、测试。执行偏差：识别和布局实际实现在 corearch 侧的 instr.cr（mw_setup_tags）和 elf.cr。opt.cr 不在 corearch 构建闭包，论证见 Task 1 报告第 2 节与 Task 5 节执行注记。

- 识别：函数内 add/sub 的 dest 变量链是潜在多字。保守做法是取所有 add/sub dest，再传播到使用它的变量。M1 保守范围是：函数内有 add/sub 时哪些变量 tagged，由实现者定最小正确集并论证。
- tag 区：栈帧附加，每 tagged 变量 1 字节。扩展 g2_slot 布局。
- 测试：tag 区布局正确。无 tag 程序栈布局不变，即快路径零变化。

### Task 2: 快路径溢出检测发射（add/sub + jo 到慢路径）

文件：instr.cr、sizes.cr（sz 同步）、测试

- add/sub 发射后接 jo（rel8）到慢路径块；sizes 同步。
- 测试：溢出触发，构造 2^63 附近的 add，反汇编并检查行为。

### Task 3: 慢路径 + 2-limb 表示运行时

文件：慢路径代码（内联例程 instr.cr 或 rt）加 2-limb 堆（arena）加 tag 写

- jo 后做数学修正，OF 判定符号和进位。
- 2-limb add/sub 例程，处理慢值再运算。
- 测试：溢出值数学正确，测试钩子验证全 128。

### Task 4: 消费者适配（读 tag：return/比较/后续算术）

文件：instr.cr return/比较发射、tag 读路径

- return 大值：exit 低 8 位正确，现机制天然支持，另做 tag 清理。
- 比较：2-limb 比较，先高 limb 后低。
- 测试：溢出值比较和链式运算正确。

### Task 5: 分配器适配（D6：tagged 变量只栈）

文件：opt.cr alloc_registers。执行注记：本计划此节沿用 Task 1 的偏差。识别实现在 corearch 侧 instr.cr，opt.cr 不在 corearch 构建闭包，跨进程需要 .ccr 通道。Task 5 的消费点是发射侧 g2_slot/get_reg_for_var，不是 opt.cr。见 Task 1 报告第 2 节。

- tagged（潜在多字）变量排除寄存器分配，只放栈。CAG 分配器加标记输入。
- 测试：O2 自举 byte-identical，溢出程序在 O2 下正确。

执行记录（Task 5 完成，2026-09-07），定案：不改，D6 排除不实施。

- 现状核实（实证）：O2 下 tagged 变量确实被 CAG 分配寄存器，包括运行时 2L 态（循环携带值、参数行、双 2L 对象，驻 rbx/r12-15）。O1 没有寄存器分配，alloc_registers 的门是 opt_level≥2，入口 opt.cr optimize_all，所以 O1 下 tagged 恒为只栈。
- 裁决依据：D6 的原始动机是多字值不能驻单个寄存器，这一动机被最终 D1a 表示消解。槽或寄存器中驻留的是快值或 2-limb 堆指针，128 位载荷在堆对象里，tag 在帧字节里。值读写只有 g2_slot 一个 seam，tag 只有 g2_tag_off 一个 seam，reg 形态状态完整：jo 慢路径回存 e2_mov(dst_reg,rax)、2L 块装载、return 解指针都经过 g2_slot。表路径 preflight 已拒绝 reg 形态变量。排除方案零收益，因为没有独立发射路径可删，而且有代价，因为 tagged 是最常见的 add 循环行。
- 测试加固：test_mw_task5.py。O2 元断言（oracle tagged ∩ REG_ASSIGN ≠ ∅，在运行时 2L 溢出函数加 16B 通道行为同用例链接），加 O1 元断言（REG_ASSIGN = 0），加三类用例在 O0/O1/O2 全部通过。将来若改变决定改为只栈，O2 元断言会失败，须同步更新并附新证据。
- 注记同步：spec int-multiword-backend-design 第 6 节（D6 条目）加 instr.cr mw_setup_tags 消费方接口注释（D6 定案）。

### Task 6: 验证 + 回归 + 文档

- 溢出程序套件，构造边界值：i64max+1 链、负数、混合快慢。
- 快路径零变化回归全套加 O2 自举。
- TODO/spec 状态更新（M1 完成，M2 待办：mul/div/比较多字、打印、D4 常量多字、动态增长、D1c 静态免 tag）。

执行记录（Task 6 结束，2026-09-07），M1 完成。

- 边界套件 `tests/selfhost/test_mw_task6.py`（8 用例 × O0/O1/O2 = 24 组全部通过）。task3/4 已覆盖 CF/op 判别矩阵和消费者判别，本套件补边界值组合。e1 是 i64max+1，恰好一步越界。e2 是上边界三步越界链，然后降级回 i64max，再越界，fits 检查看 lo 符号位往返。e3 是下边界邻域，−(2^63−1)+−1 = −2^63，快值不溢出；负 OF 只发生在 < −2^63，字面量 −2^63 被 lexer 拒绝，所以须用此构造。另含 add/sub 连续越界和回升降级。e4 是 sub 形式（i64max − −1）。e5 是上下边界同函数双站，加 2L 与 2L 的高 limb 判别。e6 是 i64max 边界 fast 与 2L 比较真值表（LT/GT 双分派，EQ/GE 假性 −10 标记值）。e7 是 −2^63 快值与 −2^63−1 2L 比较，同 hi 时低 limb 无符号判别。e8 是循环携带越上边界。期望值由 Python 独立计算（limb_bytes），16B 通道验全 128，exit 验数学低字节。
- 结束全量回归（本任务一次性全套）：mw task1-6 + hit_table + compile + backend_bootstrap（stage1 到 3 byte-identical，是快路径零变化最强的确定性证明）+ ccr_v6 + region_cfg + slice_bounds + `corec check src/compiler`，全部通过。各任务期间各自回归通过之外，结束全量记录在案。
- 文档同步：本 plan（状态行和本执行记录）、spec（第 8 节 M2 待办加状态行）、TODO.md（新节「int 多字 M1（2026-09-07 M1 完成，M2 待办）」）。
- 验收报告：`docs/archive/sdd/mw-m1-task-6-report.md`（M1 六任务全链证据）。

M2 待办（M1 边界外清单，详见 spec 第 8 节）：mul/div 溢出链与 2L 参与；2L 值打印（int_str 超 64）；D4 超 64 编译期常量（IR_CONST 64 位槽是格层表示，需要 v6 常量段，与 dex 精度同族）；超 128 码域动态增长（现在报编码层错）；D1c 静态区间免 tag（保守 tagged 集每变量行 1 字节栈开销加 jo 和块的静态代价）；共享块/模板压缩（jo/2L 块约 45-160B，每站点在函数尾冷区线性增长）；表（HIT）模式与运行时 2L 组合验证（现在 tagged 路径整条走旧路径，语义正确，组合未验证）；arena 生命周期遗留问题（2L 对象跨 arena_reset）；return 全 128 内部传递（现在确定性截断低 64）；UOP_NEG −2^63 环绕链；出逃写和跨函数 2L（全局/堆/数组/调用实参返回值）。

---

## 已知偏差和风险（评审注意）

- jo 慢路径的数学修正（环绕加 ±2^64）正确性是核心，评审重点。已验（Task 3）：sbb 推演闭式（add hi=CF?−1:0 / sub hi=CF?0:−1），8 万以上随机样本零偏差，CF/op 判别矩阵（m1-m6），边界对 brute-force；编码级经 task2 jo rel32/task3 块发射逐字节核对。
- M1 保守 tagged 集可能偏宽，影响性能。静态精化属于 M2（D1c）。代价已记录（Task 1/3/4）：tag 为每 tagged 变量行 1 字节栈开销（帧公式，无 tag 程序逐字节不变），每站点 jo 6B，函数尾块约 45-160B，冷区线性增长。精化（区间证明免 tag 免检测）属于 M2（D1c）。
- 2-limb 堆对象的 arena 归属（函数 arena reset 时机，慢路径分配的生命周期）。已核（Task 3/4）：慢路径经标准 alloc 双路。无激活 arena 时（纯算术作用域，sg_alloc_total=0，arena 不建）落全局 bump，即进程生命期。arena 激活时与周围分配同 chunk 同生命周期。含分配作用域加 2L 跨 reset 是 M2 遗留问题（spec 第 8 节）。
- return 大值验证只能看低 8 位（exit 码），全 128 验证需要测试钩子（扩展 dump 或专用断言通道）。已解（Task 3）：测试钩子为 syscall3(1,1,x,16) 原始 16B 通道，x 槽是 2L 对象指针的直接可观测面，零 runtime 改动。另加 spec 第 5 节 return 出逃边界句：M1 内 return-2L 到内部调用方为确定性截断低 64，全 128 return 属于 M2。
