# int 多字 M1 Task 1 报告：tagged 槽框架（潜在多字变量识别、tag 区、栈布局）

日期：2026-09-06
状态：完成
测试：`tests/selfhost/test_mw_task1.py`（5 个样例 × O0/O1/O2 全部通过），全套回归通过

## 1. 交付物

| 文件 | 改动 |
|---|---|
| `src/arch/linux/ld/instr.cr` | 核心改动：潜在多字变量识别和 tag 区布局 API。`mw_setup_tags(fi,vs,vc)`（逐函数识别并填充 tag 字节偏移表）、`g2_tag_off(v)`（变量到 tag 字节偏移，-1 表示非 tagged）、`mw_frame_size(vc)`（含 tag 区的帧总字节，16 对齐规则与旧规则一致） |
| `src/arch/linux/ld/elf.cr` | 两处帧尺寸计算接入（Phase 2 dry-run 和 Phase 3 emit）：`vc*8` 改为 `mw_frame_size(vc)`（先调用 `mw_setup_tags`）；`g2_slot` 的变量槽偏移不变（tag 区在槽区之下） |
| `src/compiler/globals.cr` | 后端状态：`g_x86_mw_tag_off`（每个局部变量的 tag 偏移表，i64 数组）、`g_x86_mw_tag_off_cap`、`g_x86_mw_tag_count` |
| `src/compiler/dyn_arr.cr` | `grow_mw_tag_off`（与既有 grow_* 同型） |
| `tests/selfhost/test_mw_task1.py` | 新建，见第 4 节 |

代码改动全部只在 corearch 侧（识别在发射时的最终 IR 上运行），corec、`.ccr` 格式和前端零改动（详见下文）。

## 2. 识别规则（最小正确集和论证）

规则（逐函数，在局部 TI_INT 变量域 [vs, vs+vc) 上做值流闭包）：
- A：`IR_BINARY` 且 s3 ∈ {OP_ADD, OP_SUB} 且 dest 是域内 TI_INT，则 dest 标记为 tagged；
- B：`IR_LOAD`（后端对应 e2_load_var，直接拷贝槽值，不解引用）且 s1 是域内 TI_INT 且 s1 已 tagged，则 dest 标记为 tagged。

单遍前向扫描即可达到闭包（checker 保证定义先于使用；变量复用或重定义场景下静态标记没有歧义）。指令序内的传播天然包含 dest 在同一条指令中被重定义的情形。

最小性和正确性论证：M1 中大于 64 位的值只有一个生产者，即 add/sub 溢出慢路径写入其 dest（mul/div 溢出链属于 M2；大于 64 位的字面量被 lexer 拒绝，D4 推迟到 M2；call 返回值经过 64 位 rax；dex 走 TI_DEX，不在 int 域）。因此任何运行时可持有大于 64 位值的变量必然属于 {慢路径 dest} ∪ {对它逐位拷贝的变量}，也就是本闭包。集合外的变量恒为 64 位快值，为它预留的 tag 字节（如果有）恒不被置位或读取，只增加 1 字节栈开销。规则 A 无条件标记（没有区间分析，D1c 的静态免 tag 属于 M2），因此慢路径可达性必然被覆盖，保守但正确。

实现位置论证（与 plan 文件清单有偏差，plan 列的是 opt.cr）：在本仓库架构中，opt.cr（前端优化：alloc_registers/pass_stack_share/CSE）不在 corearch 构建闭包内（corec 和 corearch 是两个独立二进制，opt.cr 只进入 corec）；栈帧和槽偏移全部在 corearch（instr.cr 的 g2_slot，elf.cr）。如果按 plan 放在 opt.cr，识别结果必须通过 `.ccr` 元数据跨进程传递（要改 ccr 格式或版本，并改两处构建清单）。改在发射侧后，它是纯 IR 函数，零格式改动，O0/O1/O2 全部生效，而且识别所见 IR 与发射所见逐字节相同，没有同步变化风险。Task 5（D6 寄存器排除）的消费点在 corearch 的 `g2_slot`/`g2_tag_off`（元数据 REG_ASSIGN 忽略 tagged 变量），同样不需要 `.ccr` 通道。后续任务的消费方式见第 3 节。

类型和边界过滤：只有 TI_INT，且 dest/s1 落在当前函数变量域 [vs, vs+vc) 时才处理。dex（TI_DEX）、TI_STR（如果出现字符串 add）、TI_BOOL 等一律不 tag；PTR_ADD/PTR_SUB/PTR_DIFF（s3 编码不同）不 tag；全局变量作为 dest/s1 时不 tag。

M1 已知边界（识别不做传播，本任务挂账，Task 2-4 前需要显式处理或用测试规避）：
1. 跨函数的 2-limb 值（调用实参、返回值、goroutine 通道），没有 tag 传递协议；
2. 出逃写（IR_STORE/STORE_PTR/STORE_INDEX 或全局赋值把 tagged 值写入全局、堆、数组）；
3. 其他潜在溢出生产者（UOP_NEG 的 -2^63 环绕、MUL/DIV、常量）属于 M2 溢出链范围（含 2-limb 态参与 mul/div/neg/比较，属于 M2）。
4. tag 字节初值：本任务只做布局，不发射 tag 写或读；Task 3/4 必须补「函数入口 tag 区清零」或等价的按定义置位（tag 不变量：槽内是快值当且仅当 tag=0）。tag 区在帧底，快路径不碰；当前任务没有读者，不影响行为。

## 3. 布局设计和接口（Task 2-5 的消费方式）

布局：变量槽区仍是 [rbp − vc*8, rbp)（`g2_slot` 公式不变）；tag 区在槽区之下，共 n 字节（n 为 tagged 数，变量索引升序 k=0..n−1，tag 的字节偏移为 −(vc*8 + 1 + k)）。帧总字节 `F = mw_frame_size(vc)`，即 (vc*8 + n) 按现有 SysV 规则取整：opt≥1（6 次 push）时 F ≡ 8 (mod 16)，opt<1（1 次 push）时 F ≡ 0 (mod 16)。推广为「对齐到目标余数」，n=0 时与原条件式逐字节同结果（对任意 vc 的四种情况逐一验证过），因此无 tag 的程序或函数帧公式与旧版完全一致。对齐垫片在帧底（tag 区之下），不挤压任何槽。参数保存、caller_off、寄存器参数装载都与帧尺寸无关（沿用既有偏移公式），不受影响。

接口输出（供后续任务消费）：
- `mw_setup_tags(fi, vs, vc)`：elf.cr 的 Phase 2/3 每函数调用一次（同源同结果，天然一致）；
- `g_x86_mw_tag_count`：tagged 数，等于 tag 区字节数（帧尺寸输入）；
- `g2_tag_off(var_idx)`（-1 表示非 tagged，表索引 = var_idx − 当前函数 var_start，只在函数内有效）：
  - Task 2/3 慢路径发射：jo 后写 tag=1，即 `mov byte [rbp+g2_tag_off(d)], 1`；
  - Task 3 慢路径入口 tag 区清零（或 Task 4 的消费者/定义点清零策略）；
  - Task 4 消费者（return、比较、后续算术）读 tag：`movzx` 加分支；
  - Task 5 D6：在 `g2_slot` 中，对 `g2_tag_off(v) ≥ 0` 的变量忽略 REG_ASSIGN 元数据（只放栈），纯后端过滤，不需要改 `.ccr`；
- `mw_frame_size(vc)`：Phase 2/3 的帧尺寸唯一来源（sz_sub_rsp/sz_add_rsp 的 4/7 字节阈自动一致）。

## 4. 测试

`tests/selfhost/test_mw_task1.py`（随提交，自包含）：
- oracle 架构：Python 独立实现 `.ccr` 二进制格式读取器（v1-v5 区段序步进），并复刻识别规则（与 Core 实现互相校验，不同实现针对同一断言面），计算期望 tag 数 n 和期望帧 F = frame_total(vc, n, opt)；ELF 侧扫描 `_start` 尾模式（E8 rel32 + `89 C7 B8 3C 00 00 00 0F 05`）定位 main，解析 prologue 的 sub rsp 立即数，断言相等。
- 用例（5 × {O0, O1, O2} = 15 个断言组，每组含帧断言和行为断言）：
  - s1_noarith `return 7`：0 tag，帧与旧布局逐字节一致（无 int 算术的函数帧零变化）；
  - s2_intadd：add dest 产生 1 tag（vc*8=56，帧 64@O0 / 72@O1,O2）；
  - s3_sub：sub dest 产生 1 tag；
  - s4_addcopy：add dest 加拷贝链（oracle 读取实际 `.ccr` IR，O0 为 2 tag）；
  - s5_loop：while 累加（赋值循环变量 dest）产生 2 tag；exit 45。
- 15 组全部 PASS；行为退出码为 7/0/7/6/45，符合预期。

回归（全部通过）：
- `test_backend_bootstrap.py` 11/11 PASS，含 stage1、2、3 byte-identical（tag 布局确定性的最强证明：同一 `.ccr` 重发射逐字节一致）和 O0/O2 smoke；
- `test_region_cfg.py` 22/22、`test_compile.py` ALL PASS、`test_native_strings/memory/pointer_safety/slice_bounds/native_float/dex_arith/apx_tag/impl` 全部通过；
- `./build/corec check src/compiler` ok；
- 基线字节不变性（开发期一次性验证）：改动前保存 corec/corearch 二进制，与改动后对同源输出逐字节 diff，5 个样例的 diff 字节 100% 都是 sub/add rsp 立即数（帧增减 16 的倍数），没有任何其他指令或数据字节差异；`return 7` 程序的 main（0 tag）零 diff。

## 5. 提交和工作副本状况（并行会话交互）

计划/规格文档（`docs/superpowers/plans/2026-09-06-int-multiword-m1.md`、`specs/2026-09-06-int-unbounded-semantics.md`、`specs/2026-09-06-int-multiword-backend-design.md`）不在当前工作副本中（在 ymtkzovlzsst/uwnmxukxnuzp/wyonmwrrplzr 分支链上，通过 `jj file show` 读取，分支尚未合入本线）。

并行会话交互：本会话与 feature/docs-reorg 会话共享同一个 jj 工作副本。该会话的整树提交（change lluwzlkuuutz「docs: docs/README.md 导航索引」）把我未提交的 src 四处改动全部扫入其提交（内容完好，位于 docs-reorg 线祖先链，xwnrnksx 及之后的提交都包含）；期间其操作还曾短暂回退工作副本的 elf.cr（随后恢复）。当前磁盘状态与提交内容一致，二进制从该状态重建并复验通过。因此：

- 代码提交归属为 lluwzlkuuutz（docs-reorg 会话的整树提交，不是本会话提交）。内容经验证是本会话设计/实现的最终态（改动前快照基线 diff 全部通过，记录在案）；
- 本会话独立提交：change `symplypo` / commit `f042e5f2`（路径限定，只含 `tests/selfhost/test_mw_task1.py`，避免扫入该会话在途的 docs 改动）；
- 提交时工作副本 @ 已推进到 docs-reorg 线（xwnrnksx 之上），未动任何 bookmark；
- 如果要把 Task 1 代码归位到 M1 计划分支（ymtkzovlzsst 系）或独立提交，需要在并行会话收敛后做分支整理（jj rebase/split 属于共享历史改写，本次未做）。

## 6. Concerns / 挂账

1. 提交归属混乱（见上节）：lluwzlkuuutz 含代码，f042e5f2 只含测试。建议并行收敛后把 4 个 src 文件从 docs-reorg 线拆出（或确认无碍）。
2. tag 初值：tag 字节由谁、何时清零或置位，是 Task 3/4 的决策点（本任务没有读者，零行为影响，但 Task 3 慢路径发射前必须定）。
3. IR_LOAD 拷贝链（规则 B）的实际触发面很窄：ir_gen 中 IR_LOAD 主要用于 `as` 转换（int 到 int 也可能产出）；保守保留的成本约为 0。
4. M1 边界四项（第 2 节末尾）需要 Task 2-6 逐一显式处理或声明规避；2-limb 值参与调用或存储前必须有测试护栏。
5. O2 交互：tagged 变量如果被 alloc_registers 分配到寄存器（O2），`g2_slot` 返回寄存器编码；tag 字节仍在栈上，Task 3 慢路径经 `g2_slot(d)` 写指针时同样走寄存器（值语义一致）。D6 的只栈化是 Task 5 的可选收紧，不是正确性必需（本任务已论证）。
6. 测试 oracle 的 `.ccr` 读取器依赖当前段表布局，ccr v6 段表化时需要同步（测试已按 v1-v5 兼容写法步进）。

## 7. 评审修复（追加，2026-09-07）

评审 Important 发现：`mw_setup_tags` 的单遍前向扫描对循环携带值不成立。运行时 tag 状态可以沿回边携带（循环体内的拷贝点在线性顺序上先于其 tag 源的定义），「定义先于使用」的线性论证只对无环情况成立。Task 3/4 会继承漏标。

实 IR 核验（修复前先做）：评审例「snap := x as int」在真实 IR 中是 `IR_LOAD 临时行` 来自 `x`，加 `IR_STORE snap` 来自 `临时行` 两跳；而 `x = x + k` 是 `IR_BINARY ADD 临时行` 加 `IR_STORE x` 来自 `临时行`。ir_gen 的赋值形态是临时行算值、IR_STORE 定值拷贝落变量行（probe1-3 的 `.ccr` dump 实证：`d := c` 是 STORE d 从 c 直拷；常量或算术结果全部经临时行；`as` 是 IR_LOAD 拷贝加 STORE）。推论：
- 只标 IR_BINARY dest 等于只标一次性临时行；变量行（return/比较消费的槽、跨迭代携带者）只经 IR_STORE 得到值，评审前的规则 A+B 永远不会标记它们。单遍改为不动点时如果只改迭代策略，评审例在真实 IR 上仍然不可触发；
- 补上 B'（IR_STORE 定值拷贝边：s2 已标记则标记 s1）后，评审例才真实成立：x 经「add 临时行，再到 STORE」入集，snap 链（x 到 LOAD 行，再到 STORE snap）在循环回边场景必须多遍收敛（snap 的定值点线性先于 x 的 tag 源，第 1 遍漏掉，第 2 遍捕获）。

修复（`src/arch/linux/ld/instr.cr`，commit ppzxtqso / 7a6b17b1）：
- Pass 1 从单遍前向改为不动点扫描（重复全扫，直到某一遍没有新标记；单调，因此至多 vc+1 遍）；
- 规则集为 A（BINARY ADD/SUB dest）、B（IR_LOAD 拷贝，as 形态）、B'（IR_STORE 定值拷贝），域和类型守卫不变（域内 TI_INT；全局 s1 的 STORE 是出逃边界，照旧）；
- 头注释同步（闭包语义，边界 #2 改为「STORE 局部 s1 属于 B' 闭包；全局 s1、STORE_PTR、INDEX 属于出逃」）。

测试（`tests/selfhost/test_mw_task1.py`）：
- oracle 读取器改写为 v6 段表解析（`from test_ccr_v6 import V6File`，格式唯一来源，v6 段表化时只需改一处）；函数指令域由 REG root region [enter,exit) 切分，var 域由 SYM 记录序游标累加；
- oracle 规则等于修复后算法（含退化形态开关：单遍 / 无 B'，供区分断言）；
- 新增 s6_loopcopy（评审失败用例：循环内 `snap = x as int` 先于 `x = x + 1`；exit 2）。O0 元断言：不动点集合真包含单遍前向集合（s6: fp=6 > sp=4）；
- 新增 s7_framediff（8 个 add 定值点加 1 个拷贝变量行）。帧级可观测：旧规则 8 tag，新规则 10 tag，O1/O2 帧 168 对 184（相差 16B）；
- 失败/通过证据：旧二进制（评审前规则）跑 s7 @O1/O2 得到帧 168，不等于期望的 184，FAIL；修复后 21/21 组和元断言全部通过；
- 旧样例计数变化（oracle 驱动自动重算）：s2/s3 从 1 变为 2 tag、s4 从 2 变为 6、s5 从 2 变为 4。tag 集现在包含消费槽变量行（语义上必须如此：return/比较会读变量槽）；本任务零行为影响（没有 tag 读写者），帧尺寸变大是保守设计为每个变量行保留 1 字节的代价。

回归（修复后全部通过）：test_mw_task1 ALL PASS；test_hit_table 11/11；test_compile ALL PASS；test_backend_bootstrap（stage1、2、3 byte-identical 加 O2 smoke）；`./build/corec check src/compiler` ok。

Concerns / 挂账（评审修复相关）：
1. 帧断言有 16B 对齐桶盲区：vc*8 加 tag 数落在同一个 16B 桶内时帧字节相同（s6 的旧/新实现帧同为 128/136）。帧断言是粗粒度一致性 smoke，精确 tag 集的正确性靠 oracle 元断言和 s7 帧级用例；后续任务如果有 tag 字节级可观测面（如慢路径反汇编），建议再加一级断言。
2. B' 使 STORE 局部 s1 的 tag 字节进入布局。Task 2/3 发射 STORE 时必须决定 tag 拷贝策略（s2 已标记时，把 tag 字节拷贝到 s1，还是慢路径直接写消费槽？）。Task 1 报告第 2 节边界 #2 的措辞已被本修复改写，M1 边界清单需要 Task 2-4 按新规则集重审。
3. 旧样例期望计数的变化（见上文）：报告第 4 节记录的「s2_intadd 1 tag / s4 2 tag / s5 2 tag」数字已被新语义取代（以 oracle 现算为准），如果 Task 2+ 的文档引用旧数，需要同步。
4. 样例 s6 的原稿在循环体内用 `:=` 声明 snap，导致循环作用域遮蔽（return 读到外层未初始化变量，exit 0）。这不是编译器缺陷，测试稿已改为循环外声明、循环内赋值。
