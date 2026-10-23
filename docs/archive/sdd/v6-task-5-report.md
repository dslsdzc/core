# v6 任务 5 报告：判定消费的最小完整流程（.corespec 和 checker 自检）

日期：2026-09-06
分支：feature/lattice-ir-v6
提交：`qtnzkltt acd3d056`，即 commit `acd3d056`，提交信息 `feat: 判定一致性自检（共存互斥完整流程）+ regalloc-consistency.corespec 规约——v6 Task 5`
状态：完成（complete）。TDD 从失败到通过，回归全部通过，一次 Important 级披露见第 5 节。

## 1. 交付物

| 文件 | 改动 |
|---|---|
| `spec/regalloc-consistency.corespec` | 新建。一致性四条规约，R1 共存互斥、R2 读点无陈旧、R3 驱逐配对、R4 调用点失效，按 `grammar/corespec.ebnf` 的契约形态写成文档：原语契约 entry_var/live/coexist 等，type invariant，即条目表良构，每条规则的量化陈述，以及总判定入口。R3 和 R4 规约已经落定，代码留 TODO 注记，属于范围控制，YAGNI，与计划任务 5 步骤 3 同源。仓库其余 `.corespec` 都是空壳，本文件是第一份有实际内容的规约，头部已注明句法消费，即验证器，随规约体系阶段目标实施 |
| `src/compiler/opt.cr` | 任务 5 判定段：`meta_reg_for_var`，分配结果的镜像解析；`rl_merge_sort`，自底向上归并，16B 记录；`verify_regalloc_consistency(func_i)`，0 表示一致，1 表示违反，包含规则①全量和规则②覆盖框架；`regalloc_verify_all()`；三个测试注入钩子 `inject_home_conflict`、`inject_reg_conflict`、`inject_read_gap`，在全函数范围找目标。`alloc_registers` 处加已知注记，见第 5 节 |
| `src/compiler/main.cr` | cir 隐藏调试实现方式 `--check-regalloc`，强制 O2 分配并做判定自检，成功时 rc=0 并打印摘要行；注入标志 `--inject-home-conflict`、`--inject-reg-conflict`、`--inject-read-gap` 只在该实现方式下生效。O2 构建路径自检接线：`alloc_registers` 之后执行 `regalloc_verify_all() != 0 → return 1`，违反即编译错误，成功时不报错地 |
| `tests/selfhost/test_live_ranges.py` | 追加 2 组判定用例，从 3/5 变为 5/5 |

## 2. 关键设计决策

### 2.1 衔接设计：分配结果的真源是 `g_opt_meta`，不是 IR 负编码

任务说明和 `CLAUDE.md` 所述“分配编码为 IR 操作数负值”是 `opt.cr` 头注释的过时设计残留。现行实现是 `alloc_registers` 把 var 到 reg 对写入 `g_opt_meta`，键为 `OPT_KEY_REG_ASSIGN`，后端 `instr.cr` 的 `g2_slot` 和 `get_reg_for_var` 在发射时查询，corec 和 corearch 经 `.ccr` 共享同一份 meta。判定消费 opt 侧的镜像解析，即 `meta_reg_for_var`，镜像 `get_reg_for_var`；corec 不包含后端文件。代码注释已标明两处解析同格式，分配器升级时收敛到统一 seam。

### 2.2 版本级和变量级的对齐，选项 (b)

`alloc_registers` 是变量级单区间分配，条目是版本级。决策 (b) 是把分配结果按“条目所属 var”投影到版本条目上，判定做条目级表述，同位置两个条目共存即违反。论证如下。

- 等价性：一个 var 的版本区间并集等于它的活跃窗口，版本按定值点无缝切割。变量级分配的正确性判据是同一寄存器上的 var 的 `[first_ref,last_ref]` 不相交，与条目级“同位置条目不共存”在变量级分配下逐对等价，两个方向都成立。选项 (a) 只是 (b) 的退化特例。
- 面向未来：分配器升级为条目级，即 CAG，见 regalloc-cache-mapping 第五节，逐条目放置、spill、remat 之后，(a) 无法表述，因为版本各自落位置；(b) 无需改动，判定原样消费。home 回填 seam，即 `ent_home ≥ 0` 组，已并入同一位置编码，寄存器号直接使用，home 槽偏移 `LOC_HOME_BASE=1000000` 用于防碰撞。
- 额外收益：同一个 var 的多个版本使用同一寄存器，就是组内多条，版本切割的正确性会被 sweep 顺带校验。

### 2.3 sweep 门禁（任务 3 评审台账硬约束）

规则①没有复用 `coexist_home_conflicts`，那是 O(E²)。实现是：收集有位置的条目 (loc, entry)，按 (loc, live_start) 自底向上归并排序，O(k log k)，与 v6 格式定稿第 4.2 节“归并或插入”同源，实现选择了归并。然后在同一 loc 段内按 ls 升序单遍维持最大 `live_end`：`max_end ≥ 当前 ls` 即存在相交对。O(k) 扫描给出相交存在性和违规对，诊断打印上限 `RPT_MAX=8`，计数不封顶。

### 2.4 规则②框架的覆盖义务边界

② 是“寄存器驻留变量的每个读点都有活跃版本覆盖”。覆盖义务边界从首个版本化定值（IR_ALLOC 或 IR_STORE）之后开始：版本区间从定值点起无缝覆盖到 `last_ref`，义务内的读点恒有版本。② 是对构造不变量和条目模型的回归守卫，当前构造保证为真。未来 `compute_entries` 按格式定稿第 4.1 节“dest ≥ 0 即定值点”升级，把 ALLOC_ARRAY 和 ALLOC_STRUCT 纳入版本化后，义务会自动扩大，本检查零改动，任务 2 评审注记的窗口由这个 seam 消化。读点是非 STORE-s1 的 s1、s2 引用，STORE 的 s1 是写目标，dest 从不读。扫描按读点升序，版本游标单调推进，每个 var 为 O(R+m)。注入失败路径，即截断末版区间，已实证违规检测。

### 2.5 违反处置

选择轻量路径，即任务说明的选项：打印 violation 行，main 返回 1，作为编译错误；成功时全部不报错地。测试实现方式 `--check-regalloc` 恒打印摘要行 `regalloc-consistency: funcs N violations M`，作为测试断言实现方式；构建路径不自带摘要。

## 3. 测试

`tests/selfhost/test_live_ranges.py` 5/5 全部通过。

- 失败路径，TDD 先行：三条注入各自断言 rc=1、摘要 violations 至少 1、rule N 诊断行。`--inject-home-conflict` 触发 rule 1 home 组，`--inject-reg-conflict` 触发 rule 1 寄存器组，`--inject-read-gap` 触发 rule 2。
- 通过路径：fib 加 6 变量程序，`--check-regalloc` rc=0，没有 violation 行；O2 构建路径的自检同时被 `run_smoke` 的 O2 rc=55 隐式覆盖。
- 注入前声明“同一二进制无注入时 rc=0”，失败路径证明 verify 真消费数据，而不是恒真。

注意，实现调优历史：注入曾假设 func 0 是被测函数。cwd 解析差异会把标准库函数并进来，本仓库在 cwd=BASE 编译时会自动链入 fmt.cr，实测 16 个函数且 main 是 func 0，因此 func 顺序不可假设。注入改为在全函数范围找“首个满足形状”的目标，确定性不受影响。

## 4. 回归

| 套件 | 结果 |
|---|---|
| `build_selfhost_native.py`，自举重建 5 轮 | BUILD SUCCESS |
| `tests/selfhost/test_live_ranges.py` | 5/5 |
| `tests/selfhost/test_compile.py` | 全部通过 |
| `tests/selfhost/test_ccr_v6.py` | 4/4 |
| `tests/selfhost/test_region_cfg.py` | 22/22 |
| `tests/selfhost/test_backend_bootstrap.py` | 11/11，包含 stage0、stage1 的 O2 metadata CCR 路径 |
| `corec check src/compiler` | ok，rc=0 |
| O2 真实程序编译，`tests/suite/arena_test.cr --opt-level 2`，16 个函数全部通过自检 | 全部通过 |

`alloc_registers` 的指派逻辑零语义改动，只加注记和调用点，任务范围控制落实。

## 5. Important 披露：alloc_registers 当前产出恒为空的分配（已有问题）

调试注入失败的过程中实证：`alloc_registers` 对每个函数都 rc=0。指令循环每一步会把 `last_ref < ii` 的已分配 var 复位，即“归还”，循环结束时只保留末指令仍活跃的 var，实际没有 var 存在，因此 `g_opt_meta` 没有 REG_ASSIGN 对，后端 `g2_slot` 全部落到栈。实测 O2 构建的 `.ccr` SYM 段 `opt_meta count = 0`。

该语义，即逐指令 free、不复用、循环末清点，先于 v6 存在。任务 1 做过逐行等价重构，diff 核实 free 和 assign 逻辑未变。正确性不受影响，全栈发射合法，但 O2 寄存器加速长期没有生效，也没有人察觉，因为测试只断言行为。已在不改语义的前提下于 `alloc_registers` 加注记。修复，即回池复用或 CAG 升级，建议登记到 v6 任务 6 或上下文贪心任务。判定消费 seam，即 `meta_reg_for_var` 和 verify，已经就绪，届时会自动接管真实分配输出。

这个发现同时意味着：本任务通过路径的规则①和②在当前结构下是平凡为真，因为没有寄存器条目，违规路径由注入失败测试实证。分配器修复或升级后，验证器零改动投入实战。

## 6. 待说明的问题和注记

1. ② 当前不触发：覆盖义务边界的设计使 ② 在没有寄存器分配时不触发，这是构造不变量。如果评审要求 ② 由真实语料触发，需要先落第 4.1 节的定值建模升级，即 ALLOC_ARRAY 和 STRUCT 版本化，超出本任务的范围控制。已在 `.corespec` 的 R2 和代码注记中标出 seam。
2. meta 双份解析：`meta_reg_for_var`（`opt.cr`）和 `get_reg_for_var`（`instr.cr`）镜像解析同一格式。已有注记，分配器升级时统一。
3. M-5 上界校验登记延续，来自任务 3 评审：verify 和注入访问器未加 `e ≥ g_entry_count` 上界校验，判定原语化之前补。本轮注入和 verify 只遍历表内合法范围。
4. R3 和 R4 没有代码，按任务说明做范围控制。判定在 `lower_to_ccr` 重建线性流之前运行，分配决策基于同一份前 lower 流。当前分配器不复用寄存器，这个差异对发射没有影响。随着复用分配器升级，自检点可能需要移到 lower 尾部，注记在案。
5. 注入钩子 `--inject-*` 只存在于 cir debug 分支，永不进入 build 路径。`--inject-reg-conflict` 自造 meta 对，不依赖真实分配输出，见第 5 节披露；`--inject-read-gap` 同时自造 meta 驻留并截断条目区间。

---

# v6 任务 5 评审修复报告（F1、F2、M1、M2、M3）

日期：2026-09-06
分支：feature/lattice-ir-v6
提交：`oowoympn bb38bfb7`，提交信息 `fix: v6 Task 5 评审修复——F1 rl_rule2_func 全局坐标错配（局部 ii→inst，非 func 0 失明）+ 红用例（read-gap 注入 func 9）；F2 corespec.ebnf 补 SpecImplies；M1/M2/M3 措辞收敛`
状态：原为需要修复，现已修复完成。F1 从失败到通过已实证，F2、M1、M2、M3 落实，回归全部通过。

## 1. F1（实质缺陷）：rl_rule2_func 的局部下标和全局坐标错配

根因：条目表的 `ent_def`、`ent_live_start`、`ent_live_end` 存的是全局指令坐标，`compute_entries` 写入 `inst := ist + ii`，见 `opt.cr` 的 `compute_entries`。`rl_rule2_func` 扫描时使用局部下标 `ii`，范围 0 到 ic−1。在 func 0 上，ist=0，`ii == inst`，掩盖了错配。三处比较误用了局部量：

- 门禁 `ii >= ent_def(first_def)`，即义务起点。
- 游标推进 `ent_def(nx) > ii`。
- 覆盖判定 `ent_live_end(cv) < ii`。

在非 func 0 函数上，ist 大于 0，规则②无法检测，只会漏报不会误报，因为门禁永不通过或坐标错档。

修复，在 `opt.cr` 的 `rl_rule2_func`：三处比较全部改用 `inst := ist + ii`。该局部变量原本已经算好，供 `iri_op`、`iri_s1`、`iri_s2` 使用。注释标注坐标纪律和回归测试名。

从失败到通过的实证，先失败后通过：

1. 测试注入用例的设计：注入机制 `try_inject_read_gap` 按函数顺序取首个“末版本 live_end 大于 def”的 var。如果 func 0 的 main 可注入，缺陷就不可见。用例构造为：main 只做调用，没有版本化定值，不可注入；8 个参数-only 的 noop 函数，不可注入，用来增大 ist；目标 `sum6` 有 6 变量体，可以注入，排在 func 9。实测布局为 sum6 的 ist=49，大于 ic，约 26。读点的局部下标不超过 25，永远越不过全局 def，约 50 以上。缺陷下门禁恒不通过，完全无法检测。
2. 失败，修复前的二进制：新用例 `check_regalloc_read_gap_nonfunc0` FAIL，输出 `rc=0, funcs 25 violations 0`。注入截断末版区间后，规则②漏报。套件 5/6。
3. 通过，修复后的二进制：同一用例 PASS，rc=1，诊断 `regalloc-consistency: func 9 (sum6): rule 2 violation: read of var 59 name=a at instr 68 not covered by any active version entry`，摘要 `funcs 25 violations 1`。套件 6/6。

回归保护机制：如果未来有人把三处比较改回局部 `ii`，func 9 目标无法检测，rc=0，本用例就会失败，回归会拦截。func 0 的覆盖由既有 `check_regalloc_violations` 继续保护，该用例在 func 0 上注入 read-gap。

## 2. F2（文法缺产生式）：corespec.ebnf 补 SpecImplies

- `grammar/corespec.ebnf`：在 SpecExpr 链顶加一层，`SpecExpr = SpecImplies; SpecImplies = SpecLogicalOr [ '==>' SpecImplies ];`。右结合，右侧递归展开，`A==>B==>C` 等于 `A==>(B==>C)`；优先级低于 `||`，是 SpecLogicalOr 的上层。注记量词箭头 `'=>'`，即 SpecQuantifier，是不同词法形态，不冲突。
- `spec/regalloc-consistency.corespec` 文件头的“语言形态依 grammar/corespec.ebnf”补记：蕴含 `==>` 的文法已包含 SpecImplies 产生式，评审 F2 后补充，右结合，低于 `||`。
- 安全性：全仓 grep 没有任何解析器或工具消费三份 `.ebnf`，它们只是文法文档，`corec check` 不涉及，文法改动零执行面。

## 3. M1（测试披露矛盾）：覆盖来源改写

`test_live_ranges.py` 的 `check_regalloc_consistency` docstring 原文是“a-e 占 5 个 callee-saved，f 落栈，寄存器组和读点覆盖均实际触发”，与第 5 节披露矛盾。实测分配输出为空，没有寄存器驻留条目，规则①和②的通过路径是结构性平凡为真。改写为：通过路径的覆盖来源如实披露，即不触发加行为定位点点回归；规则①和②的实际触发证据是注入失败路径，包括 `check_regalloc_violations` 和新的 `check_regalloc_read_gap_nonfunc0`。

## 4. M2（注记措辞过宽）：rc“恒为 0”收敛，并登记防回退

`opt.cr` 的 `alloc_registers` 区头注记从“rc 恒为 0”改为“实测语料上 rc 恒为 0”，语料包括 `tests/suite` 和自举构建语料，这不是形式保证。追加登记，v6 任务 6 或 CAG 之前：分配器改动后必须用 `--check-regalloc` 实现方式核对 rc 汇总，要求 REG_ASSIGN 对数大于 0，或者加看门狗计数，全函数 rc 等于 0 时告警，防止回归。

## 5. M3（术语块分界缺失）：内存态闭区间和落盘半开区间

`regalloc-consistency.corespec` 的术语块“存在区间”条目补坐标分界注记：本文件按内存态闭区间 `[live_start, live_end]` 书写；落盘 `.ccr` 的 ENT 是半开区间，见 v6 格式定稿第 3.4 节，`live_end` 编码“最后使用点加 1”，读入重建内存态时 `end−1` 就是本文件的 `live_end`，两端点定义在这里对齐。

## 6. 回归

| 套件 | 结果 |
|---|---|
| `build_selfhost_native.py` | BUILD SUCCESS |
| `tests/selfhost/test_live_ranges.py` | 6/6，新增非 func 0 的读点空洞用例，从失败到通过已实证 |
| `tests/selfhost/test_compile.py` | 全部通过 |
| `tests/selfhost/test_ccr_v6.py` | 4/4 |
| `corec check src/compiler` | ok，rc=0 |

`alloc_registers` 的指派逻辑零语义改动。本轮只加注记和修复判定侧，F1 属于判定实现缺陷，不是分配器语义问题。
