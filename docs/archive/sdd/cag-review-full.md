# CAG 分配器升级：独立复审完整报告（评审轮 2）

- 评审对象：`cd5e7a4c9b52`（jj `pqmqtlzvlmpk`），提交信息为 feat: CAG 分配器重写，包含 rc=0 根因修复、寄存器真实分配、看门狗实证，属于 v6 挂账清项。
- 评审包：`docs/archive/sdd/review-cd5e7a4c.diff`，880 行。实施报告：`docs/archive/sdd/cag-report.md`。设计依据：`docs/regalloc-cache-mapping.md`。
- 复审方式：独立代码走查，检查 opt.cr 的 alloc_registers 现文 1162-1553；独立复跑全部关键测试；不预设前轮结论。
- 日期：2026-09-06。
- 判定：Needs fixes。有 1 个 Critical，O2 寄存器分配可复现误编译，本提交引入；Important 为 O2 自举 byte-identical 声称的证据错标确认；另有多处次要证据措辞失真。

---

## 一、结论摘要

1. Critical，误编译，本提交引入。携带值判定，即阶段 2 回边扫描，只认“span 内首引用为读”为携带。遇到条件定值时，例如 `if c { x = … }`，span 内首引用是定值指令 STORE 或 def-form，但该指令并非每轮执行。x 的值在 skip 路径上仍然跨回边存在，却被判为不携带。阶段 4 因此把 x 的寄存器按文字窗口终点归还，让给循环尾文字区间不交的 var。该 var 的定值在回边前污染 x 的寄存器，下轮读 x 读到污染值。两个最小复现：v_noz 应为 14，实得 8；conddef_repro3 应为 24，实得 22。O2 确定性复现，O0/O1 正确。归属验证：以 rsvvywusrqtz（cd5e7a4c 父代）重建 pre-CAG corec，同程序 O2 输出正确，为 14/24。因此误编译由本提交的寄存器真实分配引入，不是 pass_stack_share 的存量问题。该 pass 使用同一文字窗口模型，但实测 pre-CAG 未误编译这两个程序。判定规则①和②在真实 O2 build 路径与 cir 实现方式上对该程序都报 0 违反，用户得到不报错地错误代码。
2. Important，证据错标，前轮方向确认。报告声称 `test_backend_bootstrap.py` 的 O2 三阶段自举 byte-identical，实际该测试三阶段全部以 `-O 0` 构建（`test_backend_bootstrap.py:72` 的 `"-O","0"`），alloc_registers 全程不执行。其 O2 腿只是 `return 7` 元数据烟测，没有任何可分配变量，rc=0。仓库内没有任何测试把自举语料跑过真实寄存器分配。byte-identical 声称不能作为“分配器正确”的证据，它实际验证的是 O0 后端的可复现性。
3. Important，证据来源错标。“95 pairs / funcs 16”来自 main 加 15 个自动并入的标准库函数的整语料看门狗计数，cir 实现方式和 O2 build 路径都是如此，见 .ccr 段解码实证。`check_regalloc_real_use` 断言（`tests/selfhost/test_live_ranges.py:299-314`）只断言全语料总数大于等于 5，没有断言被测 main 的 6 个变量是否真的获得分配。语料设计意图和断言对象错位。
4. Important，偏差披露定性错误。`cag-report.md` 偏差披露 #1 和 `opt.cr:1203-1209` 把该近似定性为“分配不达最优或极边角污染”。它实际是健全性漏洞，也就是正确性漏洞，触发代价极小，只需 5 行函数。披露存在但不充分：披露了近似，没有披露它能产生错误代码，也没有披露判定不拦截。
5. 正面核实：verify 确实接在真实 O2 build 路径（`main.cr:572-577`）。8/8 的 `test_live_ranges` 和 `test_backend_bootstrap` 全部复跑通过。loop-carry 语义定位点，即探测到的形状，O1/O2 rc=20 复现。寄存器复用修复，包括 free 后复用、函数末全量落 meta，在解码中真实生效。但上述全部通过证据都落在携带值判定已覆盖的形状上。漏洞形状是条件定值，没有一个测试覆盖。

---

## 二、Critical：条件定值导致携带值寄存器污染（误编译，本提交引入）

### 2.1 场景（文件与行号）

- `src/compiler/opt.cr:1333-1377`，阶段 2 回边探测和携带值标记。对每个回边 span `[label_pos, branch_pos]` 逐指令扫描，状态机为 0 未见、1 首引用是定值、2 首引用是读。
  - def-form 判定在 1351-1358：dest 在函数段返回 1；`op==IR_STORE && s1∈函数段` 返回 1。
  - 读形式 s1/s2 仅在 state==0 时才置 2，并设置 `car[lv]=1`（1359-1372）。
  - 漏洞：条件定值的 STORE 指令在文本上位于 span 内，是 x 的 span 内首引用，因此状态为 1，判为不携带。但条件不成立的路径上该 STORE 不执行，x 的旧值，即 pre-loop 或上一轮的值，实际跨回边存在，后续轮仍会被读。def-form 首引用推出“每轮刷新”，只在无条件定值时成立。
- `src/compiler/opt.cr:1415`：窗口扩整函数只在 `car[lv]!=0` 时执行。漏判者的窗口止于文字末引用。
- `src/compiler/opt.cr:1447-1489`，阶段 4：x 的窗口终点过后寄存器归还，循环尾 var 的文字窗口与 x 不交，First Fit 拿到同一寄存器。
- 判定为何不拦截：`opt.cr:490-498` 的 `entries_coexist`、`compute_entries` 版本区间（349-434，按定值点文字切割 `min(def_{j+1}-1, last_ref)`）、规则①扫描（794-882）全部是文字区间模型，与分配器同源同盲区。规则②（`rl_rule2_func` 725-790）同样按文字 def 游标覆盖。三处共享同一近似，任何一处都看不到“条件路径上旧值存在”。

### 2.2 复现路径（两个最小复现，O2 确定性复现，O0/O1 正确）

复现 A，无显式 z，更小，文件 `/tmp/v_noz.cr`：

```core
fn main()->int{
  i := 0;
  s := 0;
  x : int, mut = 3;
  loop {
    if i >= 2 { break; }
    if i == 0 { x = 7; }   // 条件定值：span 首引用 = STORE(def-form)，因此判不携带
    s = s + x;             // 读 x（每轮；i==0 后 x 恒 7，跨回边存活）
    i = i + 1;             // 尾部文字窗口与 x 不交的定值，因此拿到 x 的寄存器
  }
  return s;
}
```

- 期望 14，O0=14、O1=14、pre-CAG O2=14；本提交 O2=8，读到了 `i+1` 临时值 1，7+1=8。
- .ccr 实据，解码 `/tmp/v_noz_o2.ccr`，O2 build 流，REAL REG_ASSIGN：`var 29 (x)` 分配 `reg 14`，`var 39 (<147> 循环尾临时)` 也分配 `reg 14`，两个 var 同寄存器，证据确凿。同时 var 24/25(i)/27(s)/31 分配 rbx/r12/r13/r15。

复现 B，带 z，文件 `/tmp/conddef_repro3.cr`，同形，break 界为 2，`if i==0 { x=7 }`，尾部为 `z:=5; s=s+z;`：

- 期望 24，O1=24、pre-CAG O2=24；本提交 O2=22，尾轮读到 z 侧值 5，偏差 +2。
- .ccr 实据：`var 29 (x)` 分配 `reg 14`，`var 39 (<148>)` 也分配 `reg 14`，同寄存器。

判定不拦截的实据：两个复现的 O2 build 都成功，verify 0 违反、无诊断行、产出 ELF；cir 实现方式 `--check-regalloc` 同样 `violations 0`。O2 用户因此得到不报错地错误代码。

### 2.3 归属（pre-CAG 对照实验）

以父代 rsvvywusrqtz 的 `src/compiler/{opt,main}.cr` 加当前 HEAD 的其余源，在 `/tmp/pcag` 重建 pre-CAG corec，使用 `build_selfhost_native.py`：

| 程序 | pre-CAG O2 | 本提交 O2 |
|---|---|---|
| v_noz | 14，正确 | 8，错误 |
| conddef_repro3 | 24，正确 | 22，错误 |

pre-CAG O2 同样运行 pass_stack_share，使用同一文字窗口模型，且结果正确。因此误编译由本提交引入：寄存器真实分配使 x 落寄存器并与尾 var 共享；pre-CAG rc=0 全栈发射没有这条路径。pass_stack_share 具有同类理论模型风险（`opt.cr:1555-1630`），但在本组复现上不构成实际污染。修复时建议一并把 CFG/RegionCheck 活性作为两个 pass 的共同升级点。报告偏差 #1 已把 RegionCheck 列为升级点，方向正确，须落实为正确性修复，不能当成质量优化。

### 2.4 修复方向（供参考）

- 最小健全化：条件定值无法从文字流判定“每轮执行”，因此把 span 内 def-form 首次出现但位于条件区域（BRANCH 与目标 label 之间）的 var 一律按携带处理；或者把携带判定的 def-form 要求收紧为“def 前无同 span 读，且 def 无条件”。
- 正确方向：存在区间改由 RegionCheck/CFG 活性导出。`docs/regalloc-cache-mapping.md` 第三节的条目区间来源为 RegionCheck 的 cur_seq/exit_seq，已经定案但未接线。分配器与判定同步换源。
- 回归测试：把复现 A/B 作为语义定位点，O1/O2 使用同一断言，加入 `test_live_ranges.py`。现有 `LOOP_CARRY_SRC` 只覆盖“首引用为读”的测试形状。

---

## 三、Important：证据错标和覆盖错位（前轮方向核实）

### I-1 “O2 三阶段自举 byte-identical”错标（cag-report.md 验证证据表第 2 行）

`tests/selfhost/test_backend_bootstrap.py` 的 stage0 为 `corec build BACKEND_SOURCE … "-O","0"`（`:72`）。三阶段全部 `-O 0`，`alloc_registers`（门控 `g_opt_level>=2`，`opt.cr:1222` 加 `main.cr:572`）与 `pass_stack_share` 全程不执行。byte-identical（stage1/2/3）验证的是 O0 后端输出的可复现性，与分配器无关。O2 腿（`:125-143`）只对 `fn main()->int{return 7;}` 造 O2 元数据 CCR，没有任何可分配变量，没有 REG_ASSIGN 对，未触发任何分配语义。报告行“test_backend_bootstrap.py（O2 三阶段自举）stage1/2/3 byte-identical”与测试实际覆盖不符。仓库内目前不存在把自举语料（594 函数级）跑过真实寄存器分配的测试。

### I-2 “95 pairs / funcs 16”实现方式和断言对象错位

- 看门狗行（`main.cr:525`）与 `meta_reg_assign_total` 计数的是整语料 REG_ASSIGN 对总数。cir 实现方式和 O2 build 路径的语料都是被测源加 15 个自动并入的 stdlib 函数，funcs 16。.ccr 解码实证：func 1-15 为 str_len/chr/get_char/str_sub/str_eq/str_cmp/concat/int_str/str_int/to_str/format/format2/format_int/fpow2i/float_str_bits。“95 pairs”绝大部分来自这 15 个函数，不是“6 个共存 int var”的成果。
- `check_regalloc_real_use`（`tests/selfhost/test_live_ranges.py:288-314`）：docstring 声称“覆盖源为 6 个共存 int var，压 5 个 callee-saved 上限”，断言却只检查全语料总数大于等于 5。即使被测 main 的 6 个变量一个都没分到，全部栈驻留，只要 stdlib 函数分到 5 对以上，测试仍然通过。主函数是否真的获得分配没有断言。另做的 .ccr 解码显示 6-var main 在 O2 build 流确实获得 5 对，包含 a 到 d 加 `_arena`；cir 实现方式大概率同理。结论是碰巧为真，但断言本身证明不了它。
- 因此，看门狗作为“寄存器真实分配实证加防回退”是有效的，修复前恒 0 的红变绿成立；但作为“6 共存 var 压满 5 寄存器”的证据是实现方式错标。

### I-3 偏差披露 #1 定性错误（健全性漏洞被披露为质量近似）

`cag-report.md` 偏差披露 #1 写：“条件定值路径 + 非 span 首引用读点需真 CFG 活性……残余风险 = 分配不达最优或极边角污染，当前测试语料 + O2 三阶段自举未触发”；`opt.cr:1208-1209` 同。本复审证明该风险不是“分配不达最优”，而是确定性误编译，见第二节。触发语料就是两个 5 行函数。而且“O2 三阶段自举未触发”的前提因 I-1 并不存在，该测试没有跑 O2。披露文字存在，值得肯定，但把正确性漏洞降级为质量漏洞，导致验证和判定绿路径的声称，即“判定消费端首次吃到真数据；误报即红”（`test_live_ranges.py:259-268`），被误导性地呈现为已覆盖。

---

## 四、Minor

1. `tests/selfhost/test_live_ranges.py:296-297` docstring 写“必有栈驻留余数，驱逐/落 home 路径共存验证”。分配器没有驱逐，超过 5 个共存就不放置（`opt.cr:1196-1199`）。“落 home”表述与“不分配等于保留栈 home”一致，但“驱逐路径共存验证”措辞过载，因为没有驱逐事件。
2. `opt.cr:1225-1229` 分配器内 `reg_phys` 每次函数迭代重新 `alloc` 5×8，且 MAX_REGS 在函数级重复声明，外循环外 1225 与内层都有。这是死代码和重复分配，每函数 40B，不是正确性问题。
3. 阶段 2 的标签和回边收集每函数 alloc 若干临时变量，包括 lab_id/lab_ps/bt/st/car，循环外不释放。bump 分配器语义下可以接受，但 `bt` 按 `ic*16` 上限分配，实际只需要 `bn` 稀疏。大函数内存 16B×ic 无碍。不构成问题，仅记录。
4. `opt.cr:1402` 注释“未用 / 单指令引用”跳过 `l <= f`。若 var 首引用即末引用，且该指令同指令读写，例如 `x = x+1` 的 STORE 目标与 s1 不在同一指令，不适用，窗口为 0 不分配。对同一指令 def+use 的 var，例如 IR 级 `dest==s1` 形态，如果存在，读先于写，寄存器零窗口安全。无实证风险，记录待查。
5. 解码发现 func 0 的 `_arena` 变量获得寄存器 rbx/r12。arena 句柄变量没有被门控排除。当前行为正确，arena 指针走普通 load/store 路径，但属于门控列举式审计的未论证面。对应其偏差披露 #3，需要在门控文档补 arena 变量论证或排除。

---

## 五、硬约束核实表

| 序号 | 声称（cag-report.md） | 核实方式 | 结果 |
|---|---|---|---|
| H1 | test_live_ranges.py 8/8 PASS | 独立复跑（nice 19，ulimit -c 0） | 通过，8/8，包含 real use 95 pairs、loop-carry O1/O2=20、注入 1/1/2、非 func0。但见 I-2/I-3 和 Critical，实现方式形状未覆盖条件定值 |
| H2 | test_backend_bootstrap byte-identical | 独立复跑 | 测试通过，但三阶段为 `-O 0`（`:72`），分配器未执行；O2 腿为 `return 7`，无分配语义。声称措辞错标，见 I-1 |
| H3 | O2 门控 | `main.cr:569-579` 走查 | alloc_registers 和 regalloc_verify_all 在 build/ccr 命令 O2 时真实执行，条件为 `g_opt_level>=2`；O1 默认 build 不执行分配 |
| H4 | verify 在 O2 build 路径跑，不只 cir 实现方式 | `main.cr:572-577` 走查加复现程序 O2 build | 代码路径真实存在且执行；复现程序上 0 违反但输出错误，属于 Critical。路径存在不等于判定能拦住本漏洞，判定与分配器使用同一文字模型 |
| H5 | 95 pairs 来自“6 共存 var”程序 | .ccr 段解码（`/tmp/realuse.ccr`、`/tmp/v_noz_o2.ccr`） | 部分错标：pairs 计数是全语料，即 main 加 15 个 stdlib 函数；main 本身在 O2 build 流确实获得约 5 对，包含 `_arena`，但断言对象是总数，不是 main，见 I-2 |
| H6 | 判定“绿路径在真实分配下仍绿” | 复现程序 O2 build 加 cir `--check-regalloc` | 技术上为真，violations 0，但因文字区间模型盲区，绿在错误程序上也成立。声称的验证意义不成立，见 Critical 和 I-3 |
| H7 | loop-carry 语义定位点（O1/O2 rc=20） | 独立复跑 | 复现 20/20，仅覆盖“span 首引用为读”的测试形状；条件定值形状属于 Critical，无测试 |
| H8 | 套件差分 O1 对 O2 逐字节一致 | 无测试文件落库，报告自述 | 不可复核，未入库。按 Critical，其 O2 腿在含条件定值循环的程序上本应失败；语料如果确实没有此形状，恰好证明该形状无覆盖 |
| H9 | 修复前 rc 恒 0 根因描述 | `opt.cr:1181-1185` 加旧代码走查 | 与旧实现一致：free 遍、单调不复用、只收末指令活跃 |
| H10 | 复现归属，是否本提交引入 | `/tmp/pcag` pre-CAG 重建加 O2 复跑 | 本提交引入：pre-CAG O2 为 14/24，正确；本提交 O2 为 8/22，错误 |

## 六、独立复跑记录

```
test_live_ranges.py:        8/8 PASS（原文复现）
test_backend_bootstrap.py:  全部 PASS（stage 0-2 均 -O 0；O2 腿 return 7）
cir src/compiler/main.cr --check-regalloc:  regalloc-assign: 7037 pairs / funcs 594 violations 0
v_noz:        O1=14 O2=8（错）；pre-CAG O2=14（O0/O3 未跑）
conddef_repro3: O0=24 O1=24 O2=22（错）；pre-CAG O2=24
repro（读先于条件定值变体 v_earlyread）: O1=20 O2=20（正确，被测形状）
v_uncdef（无条件定值首引用）: O1=24 O2=24（正确，def-form 假设成立形状）
.ccr 解码（/tmp/decode_ccr.py，v6 段表式）：v_noz func0 实配 6 对，含 var29(x) 分配 r14 与 var39 分配 r14 共享
```

## 七、分档和判定

- Critical 1 个：`opt.cr` 阶段 2/4 的携带值判定存在条件定值漏洞，导致 O2 确定性误编译。本提交引入，判定不拦截，产生不报错地错误代码。
- Important 3 个：I-1，O2 自举 byte-identical 证据错标；I-2，pairs 实现方式与断言错位；I-3，偏差披露将健全性漏洞定性为质量近似。
- Minor 5 个，见第四节。

判定：Needs fixes。修复要求：(1) 携带值判定健全化，或者把存在区间换成 RegionCheck，并把 Critical 复现加为语义定位点；(2) 修正报告、测试和 docstring 的证据措辞，包括 O2 三阶段错标和实现方式错位；(3) 修复前不得宣称“判定在真实分配下绿灯等于正确性保证”；O2 默认对自举语料的信任必须等修复后用真实 O2 自举构建复核，当前没有该测试。
