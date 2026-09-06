# int 多字表示 M1 实施计划（add/sub 全链：64 快路径 + 溢出 2-limb 扩展）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 后端表示策略 B 的 M1：int 算术 add/sub 在 64 位快路径零开销直算，溢出时自动提升到固定 2-limb（128 位）多字表示——语义层（前端/图/格）零改动，纯编码层投影。

**Architecture:** 语义 int 无上限（`specs/2026-09-06-int-unbounded-semantics.md` 定稿）→ 编码层投影（本计划）：D1a tagged 值槽（快值 64 位 / 多字对象指针 + 旁路 tag）；D2b 纯后端溢出检测发射（add/sub + jo → 慢路径）；D3 固定 2-limb 128 位（超 128 报编码层错）；D4 超 64 字面量 = 词素重建进 rodata 2-limb + IR 常量池引用（复用 IR_LOAD 常量地址机制——HIT 常量池先例）；D5 分期 add/sub；D6 多字变量只栈不寄存器。

**Tech Stack:** Core 自举编译器后端（src/compiler/opt.cr、src/arch/linux/ld/instr.cr/elf.cr、src/runtime/rt.s）、Python bootstrap（构建）。参考：HIT 常量池（src/arch/hit/lower_to_core.cr——rodata 2-limb 槽与引用先例）、CAG 分配器（opt.cr——D6 多字只栈接入点）。

## Global Constraints

- 版本控制用 `jj`（铁律 #2）。提交 `jj commit -m`；不动 bookmark
- 构建 `nice -n 19 python3 build_selfhost_native.py` 每次改动重建（~2 分钟）；测试 `bash -c 'ulimit -c 0; ...'`
- **语义层零改动**：前端/IR 语义/图/格不变（int 算术仍数学整数 IR——仅 IR_CONST 超 64 字面量走常量池引用路径）
- 快路径行为零变化：64 位内程序 exit/输出与现状完全一致（全套回归）
- 溢出检测发射仅后端（IR 不加溢出感知操作）
- 设计定稿：`specs/2026-09-06-int-multiword-backend-design.md`（决策点按本计划头拍板）
- M1 范围：add/sub 溢出全链；mul/div/比较多字、打印多字、动态增长 = M2+
- 测试：trap 类 `ulimit -c 0`；回归 compile/ccr_v6/region_cfg/live_ranges/hit_table/backend_bootstrap + corec check src/compiler

---

## 现状事实（执行前必读）

- int 变量 = 64 位栈槽（g2_slot 偏移布局 init_backend_arrays/opt 定）；寄存器分配负编码（CAG 后真实分配）
- IR_BINARY(OP_ADD/SUB) 后端发射：e2_load_var(r10,s1)+e2_load_var(r11,s2)+opcode+modrm+e2_st(r10, slot d)（instr.cr 双寄存器累加形；x86 sub 4D 29 DA、add 4D 01 DA 形）
- x86 溢出检测：add/sub 后 jo（0x70/0x71 rel8）——本计划慢路径跳转载体
- HIT 常量池先例：rodata 尾追加 8B/槽 + rip 位移回填（lower_to_core.cr + elf.cr）
- IR_CONST s1 = i64 槽（64 位）——超 64 字面量现状在 lexer 被拒（P2 守卫 = 编码层限制错误，见 int-unbounded 定稿）

## M1 设计拍板（依草案倾向）

- **D1a**：值槽 64 位（现状不变）+ **旁路 tag 表**（每函数潜在多字变量一个 tag 槽位——栈帧扩展：函数 var_count 不变，tag 区 = 栈帧尾附加区域按「可能溢出变量」位图/每变量 1 槽）
- **D2b**：纯后端发射——快路径 add/sub 后 jo → 慢路径块（2-limb 例程，代码内联或调用）
- **D3**：2-limb 128 位固定（低 limb = 快值、高 limb = 符号扩展）；超 128 溢出 → 运行时错误（编码层 128 限制，M1）
- **D4**：超 64 字面量 = 词素（.ccr 已存？——查：NOD src1 i64 装不下——**ccr_io 常量扩展**？最小：lexer 不再拒但 IR_CONST 无法承载 → **M1 决策：超 64 字面量仍前端拒绝（编码层错误消息保留）**——常量多字 = M2（D4 推迟，因 IR_CONST 64 位槽是格层表示，扩展需 v6 常量段——与 dex 精度同族待 v6）——**M1 只做运行时溢出（运行时值运算结果超 64）**，编译期超 64 常量 M2
- **D5**：add/sub
- **D6**：可能溢出变量（慢路径可达）不进寄存器——分配器静态标记：函数含可能大值运算的变量 = 只栈（保守 M1：**含 add/sub 结果的所有 int 变量 = 潜在多字 = 只栈？太宽**——M1 精化：慢路径输出变量 tagged——分配器对 tagged 槽变量不分配寄存器（保守可接受 M1 性能）

## 慢路径形态（M1 设计）

```
快路径：add r10,r11 → jo slow_n  （jo = 0x70 rel8）
慢路径块 slow_n：值已在 r10/r11（环绕结果）
  → 正确 128 值 = 符号扩展重建：[r10 结果, 高位 = (r10<0 ? -1 : 0)]（add 溢出结果低 64 位 = r10 环绕值——数学和 = 环绕低 64 + 进位修正？——add 溢出 jo 后 r10 = 环绕和；真值 = 环绕和 + (2^64 or -2^64)——由 CF/OF 判定）
  → 存 2-limb 到槽对（低槽 = 环绕值 + 高槽 = 修正）
  → 设 tag（该槽对 = 多字态）
```

实现简化候选：**槽对模型**——每个「潜在多字」int 变量占 2 槽（低 64 + 高 64 符号扩展 = 128 值）——快路径只写低槽且高槽 = 符号扩展隐含？不——快路径值高槽恒符号扩展（写低槽时同步写高槽 = 2 store？性能损）……**tag 方案**：值槽 64 保持快路径单 store；多字时值槽 = 指针到 2-limb 堆对象 + tag 置位。tag 位放哪？旁路（每潜在变量 1 字节 tag 区）——慢路径写 tag+指针，快路径不碰 tag。

**最终 M1 表示**（实现者按此细化）：
- 潜在多字变量（慢路径可达 = 本函数有 add/sub 且变量为其结果链）→ 栈帧附带 tag 字节 + 值槽 64（快值或 2-limb 堆指针）
- 慢路径：jo → 内联修正代码（数学值 = r10 环绕 + OF? ±2^64 判定——用 jo 后 r10 与 CF 重建高 limb 数学正确）→ 分配 16B 堆（arena）→ 写 2-limb → 值槽存指针 + tag 置位
- 消费者（后续 add/sub/return）须读 tag：tag=0 快值直用；tag=1 解指针 2-limb（M1：慢路径结果再参与算术 = 需 2-limb 算术原语——**M1 范围**：慢路径结果只允许 return/比较（不再次算术）？——限制丑陋——真 2-limb add 原语 = M1 必要（2-limb+快值混合 add）——实现者按最小正确：2-limb add/sub 例程（值 = a+b 数学：低+低 进位链 + 高+高）——放 rt.s 或内联例程）

M1 完整性边界（实现者执行时若超界披露）：add/sub 结果超 64 → 2-limb 表示正确 → 后续 add/sub/比较/return 正确处理 2-limb → 打印（int_str）超 64 值正确（M1 含？——不含则 return 大值 exit 码截断仍「正确」（低 8 位）——打印多字 = M2）——**M1 验收 = 运算链正确（最终值数学正确——经 return 低 8 位或测试钩子验证全 128）**

---

### Task 1: tagged 槽框架（潜在多字变量识别 + tag 区 + 栈布局）

**Files:** opt.cr（识别 + tag 区布局）、instr.cr/elf.cr（槽偏移）、测试

- 识别：函数内 add/sub 的 dest 变量链 = 潜在多字（保守：所有 add/sub dest + 传播到使用它的变量？——M1 保守 = 函数内有 add/sub 则哪些变量 tagged——实现者定最小正确集并论证）
- tag 区：栈帧附加（每 tagged 变量 1 字节）——g2_slot 布局扩展
- 测试：tag 区布局正确（无 tag 程序栈布局不变 = 快路径零变化）

### Task 2: 快路径溢出检测发射（add/sub + jo → 慢路径）

**Files:** instr.cr、sizes.cr（sz 同步）、测试

- add/sub 发射后 jo（rel8）→ 慢路径块；sizes 同步
- 测试：溢出触发（构造 2^63 附近 add）反汇编/行为

### Task 3: 慢路径 + 2-limb 表示运行时

**Files:** 慢路径代码（内联例程 instr.cr 或 rt）+ 2-limb 堆（arena）+ tag 写
- jo 后数学修正（OF 判定符号/进位）
- 2-limb add/sub 例程（慢值再运算）
- 测试：溢出值数学正确（测试钩子验全 128）

### Task 4: 消费者适配（读 tag：return/比较/后续算术）

**Files:** instr.cr return/比较发射、tag 读路径
- return 大值：exit 低 8 位正确（现机制天然）+ tag 清理
- 比较：2-limb 比较（先高 limb 后低）
- 测试：溢出值比较/链式运算正确

### Task 5: 分配器适配（D6：tagged 变量只栈）

**Files:** opt.cr alloc_registers
- tagged（潜在多字）变量排除寄存器分配（只栈）——CAG 分配器加标记输入
- 测试：O2 自举 byte-identical + 溢出程序 O2 正确

### Task 6: 验证 + 回归 + 文档

- 溢出程序套件（构造边界值：i64max+1 链、负数、混合快慢）
- 快路径零变化回归全套 + O2 自举
- TODO/spec 状态更新（M1 完成、M2 挂账：mul/div/比较多字、打印、D4 常量多字、动态增长、D1c 静态免 tag）

---

## 已知偏差/风险（评审注意）

- jo 慢路径的数学修正（环绕 + ±2^64）正确性是核心——评审重点
- M1 保守 tagged 集可能宽（性能）——静态精化 = M2（D1c）
- 2-limb 堆对象 arena 归属（函数 arena reset 时机——慢路径分配的生命周期）
- return 大值验证只能低 8 位（exit 码）——全 128 验证需测试钩子（扩展 dump 或专用断言通道）
