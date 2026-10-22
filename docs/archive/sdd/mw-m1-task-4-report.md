# int 多字 M1 任务 4 报告：消费者适配（tag 读路径和 tag 维护）

日期：2026-09-07
状态：完成（complete）
测试：`tests/selfhost/test_mw_task4.py`，18 个用例 × O0/O1/O2 共 54 组全部通过，全套回归通过。

## 1. 交付物

| 文件 | 改动 |
|---|---|
| `src/arch/linux/ld/instr.cr` | 核心改动：tag 维护（定值点写 tag）和消费者读路径。新增 `e2_mw_t8/b8/ld8/st8`，即 rbp 相对字节小助手，支持 disp8 和 disp32；`e2_mw_tag_clr` 在快路径定值时清 tag；`e2_mw_tag_cpy` 在拷贝定值时传播 tag；`mw_oc_new` 和 `e2_mw_oc_check` 记录消费者站点（test tag 加 `jne 0F 85 rel32`，记录位置为 jne 起始处，即 test 前缀之后）；`e2_mw_ld2` 和 `e2_mw_sext` 负责 2-limb 解引用和快值符号扩展；`e2_mw_opnd_block` 为每个站点在函数尾生成 2L 块，包含静态分派装载、128 位算术和比较、公共落值。`emit_instr` 增加 IR_BINARY 的 int 路径站点检查，尾部 `e2_st` 后清 tag；IR_RETURN 读 tag，解指针取 lo limb；IR_STORE 和 IR_LOAD 拷贝 tag 传播。扩展 `mw_int_arith_jo_needed`，比较和 tagged 操作数也排除表路径。评审 Minor：修正 3 处 REX 前缀 docstring 错误，imul 和 PTR_ADD 的 "WB" 改为 "WRB" 共两处，movzx 的 "RB" 改为 "R" |
| `src/arch/linux/ld/elf.cr` | prologue 保存参数后，把 tagged 参数行的 tag 清 0；指令循环中记录 oc resume，与 jo 相同；函数尾在 jo 块之后发射 2L 操作数块，回填 jne，并清零计数 |
| `src/compiler/globals.cr` | oc 记录使用 8 条并行数组：pos1、pos2、s1、s2、dest、op、resume，加上 cap 和 count。注释与 jo 相同 |
| `src/compiler/dyn_arr.cr` | 增加 `grow_mw_oc_patch` |
| `tests/selfhost/test_mw_task4.py` | 新建，18 个用例 × {O0,O1,O2}，见第 4 节 |

代码改动全部只在 corearch 侧的发射路径。`.ccr`、IR、格层和前端零改动，保持语义层零改动的约束。

## 2. 范围决策（任务说明要求评审并披露）

### 2.1 tag 维护采用定值点写 tag，不在帧入口清零，是最小正确方案

tag 不变式“槽内是快值当且仅当 tag=0”由每个定值点维护。没有选择帧入口清零，论证如下。

- 行模型事实（`.ccr` 实证加报告第 6 节测试）：用户变量行只通过 IR_STORE 得到真正的定值。常量和算术都经过一次性临时行加 STORE；IR_ALLOC、CALL 等“写行”节点是 0 字节发射标记或临时行，不在 tag 闭包内。tag 闭包（规则 A、B、B'）成员行的定值点全集恰好有四类：
  ① add/sub 快路径落值，在 emit 尾部把 tag 清 0，这是回边再次执行时 stale tag=1 的根源；
  ② IR_STORE 和 IR_LOAD 的拷贝定值，运行时拷贝 tag：源 tagged 时拷贝字节，untagged 时清 0；
  ③ 本函数 prologue 的参数保存，tagged 参数行在函数内首次定值之前可能被消费者读取，本次调用之前的 stale 或无效 tag 需要确定为 0；
  ④ 2-limb 定值，慢路径块和 2L 块写指针并设 tag=1，由任务 3 和本任务实现。
- 消费者只读取“本次调用内已经执行过定值”之后的 tag，因此定值点写 tag 已经全覆盖，帧入口清零是冗余的。它会增加每次调用约 n 字节的 store，并让 prologue 更复杂，收益为 0。
- 未定值就读取属于已有的未初始化 UB 语义，M1 不承诺比 UB 更好。
- 测试护栏：h1 是 2L 到常量重定义再 return；h2 是循环中同一站点快慢交替，失败用例中 stale tag 会把快值 2^62 当作指针解引用，导致 SEGV；h4 是参数经过 2 次调用后的 stale tag。h1 和 h2 在本任务之前是通过的，因为没有读者；本任务之后它们保护消费者侧的 tag 维护。失败证据是缺少①、②、③中任一实现就会崩溃。

### 2.2 再算术：M1 包含 2-limb 参与 add/sub（全 128 位混合算术），这是正确性裁决

任务说明问“再次算术是否属于 M1”，按正确性裁决为包含。理由如下。

- 计划完整性边界行明确写着“后续 add/sub/比较/return 正确处理 2-limb”，M1 验收标准是“运算链正确，最终值数学正确”。链上的 2L 值再次参与 add/sub，是最短链（溢出后再加 1）的组成部分。
- 如果不包含，任何“2L 后再算术”都会不报错地产生错误值，例如把指针当整数相加，违背正确性优先。
- 实现形态是：每个消费者站点（add/sub 和比较）在快路径前检查 tag，函数尾为每个站点生成独立块。操作数行静态 untagged 时零检查、零块，untagged 快路径字节零变化保持，task2 的 z 用例逐字节断言继续通过。静态 tagged 时运行时分派。
- 128 位算法：A 和 B 各载入 (lo, hi)。快值用 `sar 63` 符号扩展；2L 解引用读 `[ptr+0]` 和 `[ptr+8]`。add 使用 add/adc 进位链；sub 使用 sub 加借位链，rax 暂存；比较时高 limb 按有符号比较，相等时低 limb 按无符号比较，这是两补语义，低 limb 按有符号比较会得到相反结果，c3 用于判别。结果如果可装入 64 位，即 `hi == signmask(lo)`，就降级为快值并设 tag 0；否则新建 2-limb 对象并设 tag 1。
- down-normalize 是正确性必需，不是优化。它维持“2L 意味着 |v| ≥ 2^63，因此数学上非零”的不变式。IR_BRANCH 对 2L 指针的 test 真值性因此天然正确，不需要改分支。2L 值在数学上可能为 0 的场景，例如 `x + (−x)`，会经降级回到快值。同时省去堆分配，链可以重新进入快路径。
- 无码域错误路径，论证如下。M1 的 2L 输入 |v| ≤ 2^64−1，快输入 ≤ 2^63−1，加法和减法的结果 |S| < 2^66，远小于 2^127，128 位固定码域不会越界。需要约 2^63 步链累积才触及边界，属于理论情况。D3 的动态增长和码域错误留给 M2。a6 验证 hi 可以超出 {0,−1} 域，−2^64−8 得到 hi=−2，结果仍然精确。
- 结果落值尾部分 L_fit 和 2L 两路，与任务 3 的 jo 块相同，使用 `alloc(16)` 双 push/pop 自平衡，alloc_patch 同批回填，只碰 caller-saved 寄存器。CAG 只使用 callee-saved 寄存器，契约侧已有证明。

### 2.3 不包含的内容（保持 M1 边界，披露）

- 2L 操作数进入 MUL、DIV、SHL、一元 neg、移位，以及出逃写，包括 STORE 到全局、堆、数组和跨函数传递 2L。任务 1 报告的边界不变，本任务不会让它更糟，测试语料会规避。表（HIT）模式下，tagged 比较站点已随 `mw_int_arith_jo_needed` 扩展排除到旧路径，因为 2L 比较需要读 tag，而表路径不知道 tag。
- arena 生命周期（任务 3 concern #2 复核）：2L 对象通过标准 alloc 分配。没有激活 arena 的纯算术作用域中，`sg_alloc_total=0`，arena 不建立，分配落在全局 bump，生命周期等于进程生命期，测试都在这种形态下。含分配的循环或作用域如果触发慢路径，且 2L 值跨越 `arena_reset`，就会出现悬挂。语义层的 int 不应依赖 arena，这是 M2 的已知遗留问题。本任务只披露，不修改 alloc 语义。
- 观察项，不是本任务引入，也未修复：自举的 corec lexer 遇到非 ASCII 字节（包括注释内的全角字符）会报 parse error。因此 `.cr` 语料必须是纯 ASCII。测试文件的内嵌源码已经满足。这是与 mw 无关的既有 lexer 行为。

## 3. 布局和接口（供任务 5、6 使用）

- oc 记录：`g_x86_mw_oc_{pos1,pos2,s1,s2,dest,op,resume}`，8 个并行 i64 数组共享 cap。pos2 = -1 表示没有第二检查，即 s1==s2 或 s2 untagged。`g2_init` 逐函数清零。站点顺序等于指令顺序，单条指令至多 1 个站点。
- 检查指令为 `test byte [rbp+tag], 0xFF` 加 `jne rel32`（0F 85，6 字节）。函数尾块超过 127B，rel8 不可达，理由与 jo 相同。回填位置是 jne 起始处。test 前缀为 4 或 7 字节，如果误记为 test 起始处，会把 rel32 覆写到 test 的 disp 或 imm，首版 bug 就是这样，失败到通过的实证在案。
- 块（`e2_mw_opnd_block`）按站点静态参数化。根据 t1、t2 是否存在，分派形态三选一。块内 jcc 和 jmp 全部使用 rel8，块不超过约 120B，内部分派的两个 jmp 会回填。公共落值尾与任务 3 的 jo 块形状相同。
- 帧布局不变。tag 区和帧尺寸公式与任务 1 相同，没有新的帧字节，task1 的帧断言继续通过。
- 新增字节全部在 tagged 站点：检查每个操作数约 10 至 13B，每个定值点清 tag 4 至 7B，每个站点块约 90 至 160B。untagged 快路径零字节影响，task2 的 z 用例逐字节零差异保持。

## 4. 测试

`test_mw_task4.py` 自包含，复用 task3 的 `syscall3` 原始 16B 通道验证全 128 位。18 个用例 × O0/O1/O2：

- return 解指针（r1、r2）：2^63+6 返回 exit 6，−2^63−1 返回 exit 255。失败证据是改动前 exit 等于指针低字节 8，本任务之前 return 不解 tag。
- 2L 比较（c1-c5）：负数 2L 小于 0，指针为正会得到相反结果，用于判别；2L 与快负值比较；低 limb 按无符号判别，5 < 2^63+1，按有符号 lo 会得到相反结果；同值不同对象的 EQ，指针 EQ 会得到相反结果，用于判别 128 位 EQ；GE、LE 以及 && 链。
- 链式算术（a1-a7）：2L 加快值、快值加 2L（分派 B 路）、2L 减快值、2L 减快值后降级（exit 251 等于 2^63−5 的低字节，本任务之前是指针算术的无效值）、2L 加 2L 的负修正归位（−1 降级）、2L 减 2L 的双 limb 借位链（−2^64−8 得到 [lo=2^64−8, hi=−2]，hi 超出 {0,−1} 域，在 128 码域内精确）、循环携带链（6×2^62 = 2^64+2^63，得到 hi=1，同一站点经历快值、溢出、混合的完整链）。
- tag 维护（h1-h4）：2L 到常量重定义后 return 7；循环中同一站点交替，stale tag 会崩溃，属于失败用例；拷贝传播，`y:=x` 和 `z:=x as int` 都读到 2^63，验证 STORE 和 LOAD 的 tag 拷贝；参数 stale tag，经过 2 次调用，参数 prologue 如果不清 tag 就会崩溃。

失败和通过的证据：改动前的旧二进制运行 r、c、a 组全部失败，表现为错值、指针字节或 SIGSEGV 前身；实现后 54/54 通过。h1、h3、h4 在改动前就通过，因为读者不存在时它们只是守卫。tag 维护测试的价值在于防止实现回退，去掉任一清 tag 或拷贝就会崩溃。

回归，全部通过：

- `test_mw_task1.py` 全部通过，帧和 tag 布局不变，没有新的帧字节。
- `test_mw_task2.py` 全部通过，jo 形状和 z 零差异，untagged 快路径字节零变化保持。
- `test_mw_task3.py` 全部通过，CF 和 op 判别矩阵不受影响。
- `test_mw_task4.py` 54/54。
- `test_hit_table.py` 11/11，`test_compile.py` 全部通过，`test_ccr_v6.py` 9/9，`test_backend_bootstrap.py` 全部通过（stage1 到 2 到 3 加 O2 smoke）。
- 全套 selfhost 测试：apx_tag 2/2、borrow 7/7、dex_arith 11/11、dex_type 5/5、directory_build、impl 7/7、live_ranges 13/13、native_float/strings/memory、pointer_safety、region_cfg 22/22、slice_bounds 7/7、interp_float 全部通过。
- `./build/corec check src/compiler` ok。
- 自举完整流程：`build_selfhost_native.py` 全量重建成功。编译器自身包含 15 个 stdlib 函数和巨型函数，tagged add 和比较站点全部经过新路径。

## 5. 提交

- `jj commit`。工作副本父提交为 `kvxlzlzx / 8e9c4bfe`，即任务 3。未改动任何 bookmark。

## 6. 待说明的问题和登记项（任务 5、6 入口）

1. 任务 5（D6 只栈化）的消费点：tagged 变量如果被 O1/O2 分配到寄存器，值槽就是 callee-saved 寄存器。本任务的全部读写路径都经过 `g2_slot`（包括块内装载）和 tag 帧字节，寄存器形态的语义自洽，h3 和 h4 在 O1/O2 下通过可以证明。任务 5 排除寄存器分配后，块内路径简化为纯栈，不存在正确性依赖。
2. 表（HIT）模式：tagged 比较站点随本任务排除到旧路径，保证语义正确。表模式加溢出程序仍是 M1 未验证的组合，测试语料未覆盖，task 2 有同样的披露。
3. arena 生命周期遗留问题（第 2.3 节）：含分配作用域、慢路径、跨 reset 的 2L 值属于 M2。正确方向是 2L 对象永久 bump，或跨 reset 复制。
4. 块体积：每个消费者站点约 90 至 160B，位于函数尾冷区。大函数多站点时线性增长，与 jo 块同族。共享块或模板压缩留作后续优化。
5. 非 ASCII 语料限制（第 2.3 节观察）：corec lexer 对非 ASCII 字节报错，纯 ASCII 约束已写入测试惯例。
6. `hi ∈ {0,−1}` 不变量已经放宽：链式混合算术的 2L 值 hi 可以超出 {0,−1}，a6 的 −2 已实证。后续任务或 M2 如果依赖该不变量需要重新审查。本任务各路径都按全 128 位语义实现，不依赖它。

## 7. 评审修复（Critical：fits-64 检查编码从 0x4D 改为 0x49，增加判别回归 d1/d2）

日期：2026-09-07
状态：完成（complete）
测试：`test_mw_task4.py` 20 个用例 × O0/O1/O2 共 60 组全部通过，全套回归通过，失败到通过的实证在案。

### Critical：`e2_mw_opnd_block` 的 fits-64 检查 reg 字段编码错误（instr.cr）

- 现象：`0x4D 39 D3` 是 REX.W+R+B，reg 字段为 r10，实际指令是 `cmp r11, r10`，比较 hi 和 lo。意图是 `cmp r11, rdx`，比较 hi 和 `sar63(lo)`，即 signmask，应该编码为 `0x49 39 D3`（REX.W+B）。
- fits 判据从“hi == signmask(lo)”错成“hi == lo”：
  - 假 fit，即 hi==lo 且 hi 不在 {0,−1} 中时，会不报错地降级并截断快值。实际运行中观察到，链达到 −2^64−2 时截断为 −2，2^64+1 时截断为 1，错误值落槽且 tag 为 0，没有任何错误信号。
  - `mov rdx, r10` 加 `sar rdx, 63` 成为死代码，因为 cmp 不读 rdx。
  - 反向的假 not-fit，即 hi=0、lo 为正且可装入 64 位，例如 a4 的 2^63−5，会多执行一次 `alloc(16)` 并转为 2L。值路径巧合地掩盖了问题，return 解 lo limb、exit 取低字节都得到相同值，既有 16B 断言用例全部看不到。评审确认 d1/d2 形态是唯一能判别的地方。
- 修复是把一个字节从 `0x4D` 改为 `0x49`，即 `w8` 从 77 改为 73。`sar63` 恢复为 `cmp r11,rdx`，重新成为有效代码，死代码状态随修复消失，没有删除代码。行内注释标注编码判别，防止回退。
- 判别回归 d1/d2：链达到 −2^64−2 时 hi==lo==−2；2^64+1 时 hi==lo==1。真正的判据是 signmask(−2)=−1≠hi、signmask(1)=0≠hi，因此必须保持 2L。使用 `syscall3(1,1,x,16)` 的 16B 通道做全 128 位断言。
  - 失败（修复前的 buggy build）：6/6 失败。假 fit 截断后把快值当指针，write 返回 EFAULT，stdout 为空且 exit 242≠16。既有 18 个用例仍然 54/54 通过，实证了不可见性。
  - 通过（修复后）：d1/d2 × O0/O1/O2 全部通过，60/60 全部通过。

### Important：spec 的 return 出逃边界句

- `docs/superpowers/specs/2026-09-06-int-multiword-backend-design.md` 第 5 节补充：“return 出逃边界（M1 定案）：M1 内 return 2L 给内部调用方是确定性截断，低 64 位 wrap，解指针取低 limb，不是指针无效值。全 128 位 return，即调用方读 tag 并传递 2-limb 对象，属于 M2。”main 到 OS exit 使用同一机制，一并注明。

### Minor

- 报告数字订正：16 个用例改为 18 个、54 组。涉及报告头部、第 1 节表格、第 4 节、失败和通过证据段、回归清单共 5 处，48/48 改为 54/54。
- IR_STORE 和 IR_LOAD 的 `s1<0` 尾分支补注释：域外行在规则 B、B' 闭包之外，恒为 untagged，没有 tag 拷贝字节，属于防御后备论证。
- 块体积注释订正：旧断言“块不超过约 120B”改为最坏约 160B，但块内 rel8 只跨局部子区，最远的前向 je 到 L_fit 不超过约 60B，±127 恒足够；跨块长距恒为 rel32。
- tag 维护论证，即①至④定值点写 tag 的全集，写入 `mw_setup_tags` 注释，识别规则与维护模型在同一处引用。

### 验证（修复后全套）

- `test_mw_task1/2/3.py` 全部通过，帧布局、jo 形状、CF 判别矩阵零扰动。
- `test_mw_task4.py` 60/60，包含 d1/d2 判别回归。
- `test_hit_table.py` 11/11，`test_compile.py` 全部通过，`test_ccr_v6.py` 9/9，`test_backend_bootstrap.py` 全部通过（stage1 到 2 到 3 byte-identical，加 O2 smoke）。
- `./build/corec check src/compiler` ok。

### 提交

- `jj commit`。提交 id `9699d813a78be0cc6156fff3176b7d9f21d04784`，工作副本父提交为 `a5709dcf`，即任务 4。未改动任何 bookmark。
