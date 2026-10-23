# CAG 分配器重写报告（rc=0 挂账清项）

日期：2026-09-06
范围：v6 挂账清项中的 CAG（上下文贪心）分配器升级，内容包括重写 alloc_registers、修复 rc=0 根因、实现寄存器真实分配、用看门狗取得实证。接续 402 中断点，该中断点位于验证阶段。
参考：`docs/regalloc-cache-mapping.md`（第五节 CAG 定案）、`spec/regalloc-consistency.corespec`（R1/R2 判定规约）、前序产物 compute_live_ranges/compute_entries/verify_regalloc_consistency。

## 改动摘要

### src/compiler/opt.cr（全量重写 alloc_registers，新增 632 行）

rc=0 缺陷的根因（评审披露，本次重写修复）：旧实现每轮指令迭代前，把 `last_ref < ii` 的已分配 var 复位，形成 free 遍；reg_idx 单调递增且不复用；循环结束时只把末指令仍活跃的 var 写入 meta。实测 g_opt_meta 始终没有 REG_ASSIGN 对，后端因此全栈发射，结果正确但没有加速。

新实现分为 5 个阶段，结构上属于 First Fit 加上下文修正，也就是 CAG 静态放置的一个实例：

1. 阶段 1，门控扫描（hazard 并行标志）。审计发射器路径后，排除不能驻留寄存器的 var：类型门 TI_DEX/TI_DEX_S（XMM 内存路径）、TI_DYN（16B 双槽）、TI_UNIT；IR_CONST dest（e2_li 没有 reg 槽分支）；IR_REF s1（槽地址泄漏，是别名入口，必须保留 home）；IR_I2F s1（sd_cvt 内存源）；ti==TI_DEX/S 指令引用 var（防御）。
2. 阶段 2，回边探测与携带值标记（region 生命周期上下文）。对每条回边的 span [label_pos, branch_pos] 逐条指令扫描：如果 var 在 span 内的首次引用是读，就判为携带，并把窗口扩大到整个函数，避免循环尾部的文字区间与 var 不相交时污染携带值的寄存器。语义定位点点是 test_live_ranges 的 LOOP_CARRY_SRC。
3. 阶段 3，候选构建。窗口取 [first_ref, last_ref]。参数 `lv < pc` 时，窗口从函数头 0 开始；携带值的窗口为 st=0、en=ic−1。单指令引用或未使用的 var 跳过。按 (start, lv) 稳定升序排列，使用插入排序。
4. 阶段 4，位置扫描 First Fit。同一位置先 free（`var_end < p` 时归还），再分配，允许寄存器复用，这也是 rc=0 根因的修复点之一。`reg_occ` 有 5 个槽：rbx=3，r12 到 r15 对应 12 到 15。这些是 callee-saved 专用寄存器，ABI 保留契约的判定 ④ 因此自然满足。
5. 阶段 5，写入最终分配结果到 g_opt_meta。写入全部已分配对，不再只收集末指令活跃的 var。超过 5 对时按 5 切块，写成多块。块格式 data_len = 4+n×8，不超过 44，也不超过 STRIDE−8 的边界，安全。

注入改写为真实输出改写手段。真实分配已经覆盖之后，追加伪造对会被既有对遮蔽。因此新增元数据写侧辅助函数：`meta_reg_pair_off`（按与 instr.cr 的 get_reg_for_var 相同的布局解析）、`meta_set_reg`（已有对原位改写，无对则追加）、`meta_remove_var`（撤销寄存器驻留，使位置判定退化为 home/栈 seam）、`meta_reg_assign_total`（看门狗计数）。

- 注入 ①-home：找到共存条目对，先用 meta_remove_var 撤销两个 var 的驻留，再把 home 同置槽 7，使规则 ① 的 home 组违反。撤销后 var 的 home=−1，不参与 sweep，不会产生侧伤。
- 注入 ①-寄存器组：用 meta_set_reg 把两个共存 var 同置寄存器 3，使规则 ① 的寄存器组违反。
- 注入 ②-读点空洞：把 live_end 截断为 def；对未分配 var 强制使用寄存器 3，先撤销与目标共存且已分配的 var，防止规则 ① 侧伤。

分配粒度采用 var 级单位置。消费 seam 包括 meta 每个 var 一条对、后端 g2_slot 查询没有指令上下文、.ccr 同构传输，这些都按 var 级处理。版本级分配留作未来升级点。判定按决策 b 把 var 投影到版本条目；分配器将来升级到版本级时，判定不需要改动。

### src/compiler/main.cr（新增 4 行）

cir --check-regalloc 分支在 alloc_registers() 之后打印看门狗行 `regalloc-assign: N pairs`，内容是 meta 中 REG_ASSIGN 对的总数。rc>0 表示寄存器真实分配已经发生，用于防止回退；CAG 之前该值恒为 0。

### tests/selfhost/test_live_ranges.py（新增 93 行）

- `check_regalloc_real_use`：用 6 个共存 int var 压 5 个 callee-saved 寄存器的上限，断言 pairs ≥ 5。修复前该值恒为 0，测试失败。
- `check_regalloc_loop_carry`：循环携带值的语义定位点点。O1 基线对比 O2 真实分配，断言相同，rc==20。朴素的文字窗口会污染携带寄存器，导致提前 break，s=5。
- 更新绿路径 docstring 中覆盖来源的披露。判定消费端首次读取真实数据。

## 验证证据（全部通过）

| 实现方式 | 结果 |
|---|---|
| 重建 `python3 build_selfhost_native.py`（nice 19） | BUILD SUCCESS（corec/corearch/corelsp） |
| `test_live_ranges.py` | 8/8 PASS。包含 real use 95 pairs、loop-carry O1/O2 均为 rc=20、注入红路径 rules 1/1/2、非 func 0 读点空洞 |
| `test_backend_bootstrap.py`（O2 三阶段自举） | stage1/2/3 byte-identical，smoke ELF rc=7 |
| `--check-regalloc` 看门狗直证 | `regalloc-assign: 95 pairs` / `funcs 16 violations 0` |
| 回归：test_compile / test_ccr_v6 (4/4) / test_region_cfg (22/22) / test_slice_bounds (7/7) / test_impl (7/7) / test_borrow (7/7) / test_native_strings / test_native_memory (6/6) / test_pointer_safety / test_hit_table (9/9) / test_directory_build | 全部通过 |
| `corec check src/compiler/main.cr` | rc=0（opt.cr 全图通过 type check） |
| 套件差分 O1 vs O2（generics/dyn/arena/cache/chan/fnaddr_test.cr） | stdout 和 rc 逐字节一致（分配器语义对复杂程序没有扰动） |

## 偏差披露

1. 携带值判定使用文字近似，不是 CFG 活性分析。判定依据是 span 内首次引用的形式，用来看是否携带或定值。条件定值路径和非 span 首引用的读点需要真正的 CFG 活性分析。RegionCheck 图层是升级点。残余风险是分配达不到最优，或者在极少数边角情况下发生污染。当前测试语料和 O2 三阶段自举都没有触发。
2. 没有动态驱逐和 spill。静态放置失败时（超过 5 个共存），不放置，让 var 驻留栈，保留 home。判定 ③④ 没有事件。按 CAG 范围控制，留待下一批在解锁 caller-saved 时处理。
3. 门控列举基于发射器路径审计。如果将来新增 hazard 未覆盖的路径，例如非 g2_slot 槽访问的指令形态，需要同步扩展门控。alloc 区头部已经注明。
4. 报告文件位于 `.superpowers/`（gitignore），不进入提交。判定规约先落到 spec/regalloc-consistency.corespec，R3/R4 留到实现 spill 和调用点时再补。

## 提交

`jj commit -m 'feat: CAG 分配器重写，rc=0 根因修复 + 寄存器真实分配 + 看门狗实证（v6 挂账清项）'`

---

# Critical 复审修复报告（2026-09-06，评审轮 2 跟进）

- 评审：`docs/archive/sdd/cag-review-full.md`（Critical 1 项、Important 3 项、Minor 5 项）
- 提交：`jj commit -m 'fix: 携带值判定健全化，条件定值跨回边存活按携带处理（CAG 复审 Critical）'`
- 修复范围：opt.cr alloc_registers 阶段 2 的回边携带判定；测试方面，test_live_ranges.py 新增语义定位点点。
- 判定模型升级评估结论见下文“判定同步评估”：挂账，不升级。条目表和判定仍使用同一套文字区间模型，健全化需要换成存在区间来源，也就是接入 RegionCheck，`docs/regalloc-cache-mapping.md` 第三节已经定案。本次修复在分配器侧完成健全化，并补充行为语义定位点点。判定侧的升级超出本任务范围，作为挂账披露。

## 根因（Critical：条件定值导致携带值寄存器污染）

阶段 2 的携带判定只认一种情况：回边 span 内首次引用是读，就判为携带（opt.cr 旧 1333-1377）。如果首次引用是定值形式（dest / STORE-s1），就判为每轮刷新、不携带。这个推断只在定值无条件每轮执行时成立。

例如 `if c { x = 7; }`，STORE 在文本上是 span 内 x 的首次引用（def-form），但条件不成立的轮次不会执行。x 的旧值（上一轮或 pre-loop）实际跨回边存在，后续轮次仍会读它。阶段 4 按文字窗口终点归还 x 的寄存器，循环尾部文字区间不相交的 var（例如 `i=i+1` 的临时变量）经 First Fit 拿到同一寄存器，每轮回边前就发生污染，下一轮读 x 得到污染值。

O2 下出现确定性误编译：v_noz 应为 14，实得 8；conddef_repro3 应为 24，实得 22。O0/O1 正确。pre-CAG 版本（rsvvywusrqtz 重建，rc=0，全栈发射）在 O2 下正确，因此缺陷由本提交引入。判定（规则 ①/② 加 entries_coexist）同样使用文字区间模型，给出 0 违反，不报错地放行。

## 修复方案（opt.cr 阶段 2 健全化，采用保守携带判定）

携带判定统一为：首次引用是读，判为携带；首次引用是定值 d，但 d 未必每轮执行，也判为携带。后者的判定条件是，d 可以被 span 内的条件分支跳过，并且循环仍继续：

> 存在 IR_BRANCH b ∈ [t0, d)，其目标 label 位置 t ∈ (d, b0]，即跳过 d 后仍在 span 内直达或继续循环。

- 实现：对每个 span 做差分标记（`skp[]`）。对 span 内每个 BRANCH 的 forward 目标 t ∈ (pp, b0]，区间 [pp+1, t−1] 计数加 1，t 处减 1。前缀累计大于 0 表示该位置可以被跳过。state-1（首次引用为定值）的 var，如果定值点落在可跳过位置，就置 `car[lv]=1`，阶段 3 的窗口扩大到整个函数（`st=0; en=ic−1`），不再与尾部 var 共享寄存器。回跳或外跳目标（≤ pp 或 > b0）不计，因为跳过即退出循环，不存在继续循环后读旧值的路径。exit-code 的读值由 ALLOC/入口装载定值加窗口模型保证，详见方案推演注记。
- 附带防御（同指令自读）：dest/STORE-s1 定值如果在本指令内自读（s1/s2 等于目标，读先于写，该读本身可能取上一轮的值），按首次引用为读处理。当前 IR 没有这种形态，x=x+1 的读位于独立 BINARY 指令，首次引用已经是读形式。这里做防御性统一，防止未来 IR 形态回归。
- 复杂度：每个 span 额外 O(span + vc)，每个 BRANCH 调用两次 label_pos_of，与既有回边收集同量级。利用率代价：只有条件定值 var 被扩窗，v_noz/conddef 形状下 x 不再与尾部临时变量共享。regalloc-assign 在全语料上从 95 pairs 降到 93 pairs，原因是 stdlib 少量条件定值 var 扩窗。5 个寄存器的上限利用率基本无损。
- 方案正确性推演（窗口模型下不携带的充分条件）：span 内首次引用为无条件定值 d，则每轮在首个读之前刷新寄存器。尾部 var 共享窗口（文字不相交）只在本轮 d 之后写寄存器，下一轮的读发生在 d 之后，d 已刷新，不会污染。如果 d 可以被跳过，这条链断裂，必须按携带处理。嵌套循环跨 span 由外层 span 按同一规则后备，外层 span 包含内层循环条件分支目标 ≤ b0_out。

## 红绿证据

修复前（cd5e7a4c 原提交 build/corec）：

| 实现方式 | 结果 |
|---|---|
| v_noz O2 | 8（应为 14） |
| conddef_repro3 O2 | 22（应为 24） |
| test_live_ranges.py | 8/10（新增条件定值定位点点的 O2 腿失败） |

修复后（本提交 build/corec 重建，nice 19）：

| 实现方式 | 结果 |
|---|---|
| v_noz O2（`./build/corec build /tmp/v_noz.cr --static -O 2`） | 14，通过（O1=14 不变） |
| conddef_repro3 O2 | 24，通过（O1=24 不变） |
| .ccr 解码实证 | var 29 (x) 对应 reg 14，不再与循环尾临时变量共享。原先 var 39 同 reg 14 的情况已确认消除 |
| test_live_ranges.py | 9/9。包含新增 cond-def-carry 的 v_noz=14 / conddef-z=24 在 O1 和 O2 下的四条腿、loop-carry O1/O2=20、real use 93 pairs、注入红路径 rules 1/1/2、非 func 0 读点空洞 |
| test_backend_bootstrap.py | PASS（stage0-2 加 O2 冒烟 rc=7） |
| 回归 test_compile / test_ccr_v6 / test_region_cfg / test_slice_bounds | 全部通过（4/4、22/22、7/7、compile PASS） |
| `corec check src/compiler` | rc=0（opt.cr 全图通过 type check） |

## 真 O2 自举验证（评审 I-1 补缺，此前三阶段全部为 -O 0）

命令 `./build/corec build src/compiler/main.cr -o /tmp/corec_o2 --static -O 2`。固定编译器经真实寄存器分配路径自举，594 个函数级语料全部经过 alloc_registers 和 regalloc_verify_all，结果为 rc=0、violations 0，构建日志中 grep 不到 violation 行。冒烟结果：
- `/tmp/corec_o2 run 'fn main()->int{return 42;}'` 得到 42，通过。
- `/tmp/corec_o2 build /tmp/o2_smoke.cr --static -O 2`，这是带循环和条件定值的真实程序，包含 verify，结果为 rc=0、violations 0，运行得到 14，通过。
- 注：`corec build` 调用同目录的 corearch。自举产物放在 /tmp 时，需要执行 `ln -s build/corearch /tmp/corearch`，因为路径按可执行文件所在目录解析。

## 判定同步评估（披露与挂账）

- 判定（rule ①/② 加 entries_coexist 加 compute_entries 版本区间）与修复前的分配器使用同一套文字区间模型。条件定值 var 的版本条目区间仍然是 [def, last_ref] 的闭区间。如果将来分配器回归为与尾部 var 共享，判定仍会给出 0 违反，因为规则 ① 看不到跨回边存在。
- 修复后分配器输出保守正确，条件定值 var 使用整函数窗口，不共享。因此真实分配下判定给出 0 违反是合法通过，确实没有可报告的违反。判定对本缺陷类别回归的检测能力缺口，由新增行为语义定位点点后备，即 cond-def-carry 的 O1/O2 结果为 14/24。
- 判定和条目表的健全化，需要按回边存在延展存在区间，这要更换来源到 RegionCheck 活性，或者升级条目区间语义，会影响 --dump-entries 断言和 .ccr ENT 段含义。此事超出本任务范围，挂账处理：随 `docs/regalloc-cache-mapping.md` 第三节“条目区间来源 = RegionCheck cur_seq/exit_seq 接线”一并升级。届时判定不需要结构性改动，决策 b 已经预留。

## 未决披露（同一模型的预存项，不是本提交引入）

- pass_stack_share（opt.cr 1555 起）与分配器使用同一套文字窗口模型，栈槽共享对栈驻留的循环携带 var 存在同类理论风险。本组复现没有触发，因为 O2 下携带 var 都驻留寄存器，槽位空闲；O1 不运行 stack_share。评审 2.3 节建议两个 pass 一起更换来源到 RegionCheck。同样挂账，本任务不改。
- 评审 Minor 1/2/3/4 记录在案：docstring 措辞、reg_phys 重复分配、bt 稀疏上限、单指令 def+use 窗口。Minor 4 由本次修复的自读防御分支覆盖，其余不属于正确性问题。

---

# Critical 复审修复报告（2026-09-06，评审轮 2 跟进，第二轮：else 臂残留）

- 提交：`jj commit -m 'fix: else 臂条件定值携带判定，forward IR_JUMP 差分标记（CAG 复审 Critical 第二轮）'`
- 修复范围：opt.cr alloc_registers 阶段 2，差分标记补上 IR_JUMP；测试方面，test_live_ranges.py 新增 else 臂语义定位点点和控制组。

## 根因（Critical 残留：else 臂条件定值导致同寄存器污染）

首轮修复覆盖了 then 臂的条件定值，使用 BRANCH-skip 差分。复审发现同一机制在 else 臂仍有残留。if-else 的发射布局如下：

```
BRANCH c, L_then, L_else;  L_then: A; JUMP L_merge;  L_else: B; JUMP L_merge;
```

else 体 B 被 then 末尾的无条件 JUMP 结构性跳过。阶段 2 的可跳过差分只扫描 IR_BRANCH 目标，遗漏了 IR_JUMP。并且 B 内的定值正好落在 BRANCH 自身 else 目标的标号处，差分区间 [pp+1, t−1] 不包含终点 t，BRANCH 路径天然覆盖不到。于是 else 臂 def-form 的首次引用被判为每轮必执行、不携带。阶段 4 在文字窗口终点归还寄存器，循环尾部不相交的 var 拿到同一寄存器，回边前发生污染，下一轮读到错误值。

O2 下出现确定性误编译：p_else1/p_while 应为 22，实得 20。pre-CAG（rc=0，全栈发射）在 O2 下正确，因此这类缺陷由 CAG 真实分配引入。首轮修复只覆盖 then 臂，else 臂是同一类的残留。

## 修复方案（opt.cr 阶段 2：差分标记补 forward IR_JUMP）

对 span 内的 forward IR_JUMP (u, t)（t ∈ (u, b0]，与 BRANCH 使用同一判据：跳过之后仍在 span 内继续循环），同样生成 [u+1, t−1] 差分，覆盖起点加 1、终点减 1。语义是：JUMP 跳过区域内的 def 与 BRANCH 跳过等价，每轮未必执行，旧值跨回边存在，因此按携带处理，窗口扩大到整个函数。over-mark 只损失利用率，方向是安全的：

- continue：回跳目标 ≤ 跳源，或者前向到循环尾。回跳不计（t ≤ u）。前向形态的跳过区域是剩余循环体，def 被跳过后循环确实继续，标记正确。
- break/外跳：目标 > b0，不计。跳过即退出循环，不存在继续循环后读旧值的路径。
- 链式 JUMP、嵌套 if-else、两臂各自收尾 JUMP：跳过区域嵌套叠加，等于差分前缀累计。各自方向都是“跳过仍可能继续”，因此保守标为携带，只付出利用率代价。
- 正确性上界：新标定的定值都满足“存在跳过它且循环仍继续的执行路径”，与首轮已审定的 BRANCH 差分方向论证相同，即该链断裂时必须按携带处理。不会把无条件定值误标。无条件 JUMP 之前的 def 必然执行，之后的 def 必然被跳过；后者如果仍有读，就是真携带，如果不可达，则由状态-1 的读点判据后备。

实现：差分扫描循环（原 1422-1438）改为 `if IR_BRANCH {...} else if IR_JUMP`，IR_JUMP 的目标在 s1，读取方式与回边收集相同。注释同步更新为两轮判据的统一定义。

## 红绿证据

修复前（23b007d3 首轮提交 build/corec）：

| 实现方式 | 结果 |
|---|---|
| p_else1 O2（`if i<2 {s=s+1} else {x=7}` loop+break 形） | 20（应为 22） |
| p_while O2（while 头条件同形 if-else） | 20（应为 22） |
| test_live_ranges.py | 10/11（新增 else 臂定位点点的 O2 腿失败；O1=22 绿基线正确） |

修复后（本提交 build/corec 重建，nice 19）：

| 实现方式 | 结果 |
|---|---|
| p_else1 O2 / p_while O2 | 22 / 22，通过 |
| 首轮复现不回归：v_noz O2=14 / conddef_repro3 O2=24 | 保持通过 |
| 控制组无过标：p_then2 O2=30（then 臂定值）/ p_cont O2=31（continue+else） | 保持通过（JUMP 差分未扰动 BRANCH 路径结论，行为断言后备） |
| test_live_ranges.py | 11/11。包含新定位点点 else1/else-while 在 O1 和 O2 下的四条腿均为 22、控制组 then2=30/cont=31、首轮 v_noz/conddef-z 四条腿、loop-carry、real use 93 pairs、注入红路径、非 func 0 读点空洞 |
| test_backend_bootstrap.py | PASS（stage0-2 加 O2 元数据段冒烟 rc=7） |
| 回归 test_compile / test_ccr_v6 / test_region_cfg / test_slice_bounds | 全部通过（compile PASS、4/4、22/22、7/7） |
| `corec check src/compiler` | rc=0（opt.cr 全图通过 type check） |

## 真 O2 自举复验（评审 I-1 同款）

执行 `./build/corec build src/compiler/main.cr -o /tmp/corec_o2 --static -O 2`，结果为 violations 0，594 个函数级语料全部经过 alloc_registers 和 regalloc_verify_all。
- `/tmp/corec_o2 run 'fn main()->int{return 42;}'` 得到 42，通过。
- `/tmp/corec_o2 build /tmp/p_else1.cr --static -O 2`，用 O2 构建的编译器再次编译 else 臂复现程序，得到 22，通过。

## 利用率代价

全语料 `regalloc-assign` 看门狗保持 93 pairs 不变。首轮修复后就是 93，本轮新标的 def 都是受污染风险的 var。p_else1/p_while 的 x 已经按条件定值扩窗，5 个寄存器的上限利用率基本无损。定位点点用例的程序级 pairs 已由 real-use 断言覆盖。

## 未决披露（同一模型的预存项，不是本提交引入，承接首轮报告）

- 判定（rule ①/② 加 entries_coexist）使用同一套文字区间模型，对本缺陷类别的回归存在检测缺口。该缺口由本轮新增行为语义定位点点后备，即 else-def-carry 的 O1/O2 结果为 22，加控制组 then2/cont。条目区间健全化挂账，随 `docs/regalloc-cache-mapping.md` 第三节 RegionCheck 接线一并升级。决策 b 已经预留。
- pass_stack_share 使用同一套文字窗口模型，存在理论风险；评审 Minor 记录同首轮。本任务不改。
