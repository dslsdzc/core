# kc-task-0 报告：内核完备任务 0 盘点（计划定位点点）

盘点完成于 2026-09-10。基源是设计 spec `docs/superpowers/specs/2026-09-10-corearch-kernel-completion-design.md` 的第 1、2、4、6 节，加上步骤 2 收尾态代码。五个交付物逐项如下。行号为盘点日的定位点点：`ccr_io.cr` 1372 行、`ent_kernel.cr` 807 行、`regalloc.cr` 795 行、`corearch.cr` 492 行。

## 交付物 1：load_ccr 重建段的依赖面（任务 1 移出裁决的依据）

### 重建段定位（纠正旧定位点点）

NOD 到 `g_ir_instrs` 的线性重建位于 `ccr_io.cr` 的 NOD 段解析 `:1207-1236`，不在先前定位点点 `~:1361-1393`。当前文件共 1372 行，EDG 校验尾在 `:1369`，旧定位点点已经过时，重新核对如上。结构和读写的全集如下。

- 每条 NOD 记录 36B（盘上）读入后，邻接域 `first_edge`、`edge_count`（`+24`、`+28`）写入 load_ccr 局部的 `nod_edge_meta`。`:1213` 分配，每节点 16B，不是全局结构。任务说明中的猜测不成立。28B 语义字段经 `iri_set_op/dest/s1/s2/s3/tk`（`:1228-1233`）写入 `g_ir_instrs`，`ESZ_IRINSTR = 48B`，见 `dyn_arr.cr:55`；同时递增 `g_ir_instr_count`（`:1234`）。`grow_ir_instrs(instr_cnt)` 在 `:1211`。
- 消费方是 data 缓冲和段表局部变量（`seg_off3`、`seg_end3`、`pos`、`ccr_has_bytes`）。load_ccr 全程没有 `iri_*` 读取，只写不读线性流。
- `g_v7_edges`、`g_v7_edge_count` 是全局变量，在 `:1343-1344` 写入，属于 EDG 段，校验后进入缓冲 `:1339-1344`，不属于重建段。任务说明中的猜测不成立。`g_v7_edges` 当前零消费方，全 `src` grep 已确认。设计第 1.1 节“零消费方”属实，EDG 段是任务 1 对象面新消费的候选数据源。

### GC-3、ENT、EDG 守卫的消费面（决定性事实）

| 守卫 | 位置 | 消费内容 | 是否依赖线性流 |
|---|---|---|---|
| GC-3 root span 上界 | `:1244-1251` | `g_ir_func_instr_start/count`（REG 段派生回填 `:1186-1202`）、`func_cnt`、NOD 段头计数 `instr_cnt`（局部） | 否。消费 `nod_count`（段头值），不消费 `g_ir_instrs` |
| ENT 校验 | `:1255-1322` | 段头 `ent_cnt`；`evr ≥ 1`（`:1273`）；`ev` 对 var 命名空间（SYM 声明区总量 `:1274`）；`els ≥ ele` 且 `ele > instr_cnt` 拒收（`:1275`）；`ed ≥ instr_cnt` 拒收（`:1277`）且 `ed == els` 定值恒等（`:1279`）；块界重建 `:1291-1321` 读取 `g_ir_entries`、`g_ir_func_var_start/count`、`fn_meta`（SYM first/last 双写对照 `:1312-1318`） | 否。界全部等于 NOD 坐标（`evr/els/ele` 对 `instr_cnt`）加 SYM 命名空间；零 `iri_*` 读取，任务说明中的确认项成立 |
| EDG 校验 | `:1335-1369` | `instr_cnt`、`nod_edge_meta`（NOD 邻接域 `:1349-1352`：前缀累计对照加段界出 EDG）、边记录（`to < instr_cnt :1360`、`to > 所属节点 :1361`、`kind ≤ 1 :1359`、`Σ == edg_cnt :1368`、`pos` 走完段体 `:1369`） | 否。但 loader 必须保留 NOD 记录的邻接域读取，因为 `first_edge`、`edge_count` 在 36B 记录内 |

因此重建移出后守卫全部成立。前提是 loader 仍然读取 NOD 段头计数（段界校验必需）和每条记录的邻接域。可搬移的部分是 28B 语义字段写入线性流，即 `iri_set_*` 和计数维护。

### loader 内的顺序依赖（段按 offset 随机寻址，当前解析顺序为 STR、SYM、REG、NOD、ENT、EDG）

1. SYM 的 funcs 段生成 `fn_meta` 暂存（`:955`，每函数 24B，包含 {root, first, last}）和 `func_cnt`，供 REG 根行校验使用：`rfcnt < func_cnt` 在 `:1175`，根行 first/last 等于 `fn_meta` 在 `:1176-1178`。
2. REG 根 span 回填函数指令边界 `g_ir_func_instr_start/count`（`:1186-1202`），供 GC-3 使用，需要 NOD 计数。
3. NOD 段计数供 ENT 界校验（`:1275`、`:1277`）和 EDG 界校验（`:1360`）。
4. NOD 邻接生成 `nod_edge_meta`，供 EDG 前缀对照。
5. SYM 的 globals 和 funcs 声明区生成 var 命名空间，供 ENT `var_id` 界校验（`:1274`）。
6. ENT 和 EDG 互不依赖；EDG 段自身的 pos 走完检查独立。
7. 重建段在 loader 内没有下游消费者，全部消费都在 load 返回之后。

### load 后的依赖和接线点裁决（任务说明中的问题）

- `init_backend_arrays`（`corearch.cr :130-132`，调用点在 `:297`）只重置 `g_x86_*` 数组，不依赖线性流。
- 全部下游都消费 `g_ir_instrs`，也就是重建产物。dispatch 分支 `compute_live_ranges`（`:153/:158/:163`，扫描 `iri_dest/s1/s2`）调用 `alloc_registers`（`:169/:191`），再调用 `regalloc_verify_all`（`:199`）。生产 O2 门在 `:309` 执行 alloc，在 `:312` 执行 verify。ELF 发射面（`instr.cr`、`elf.cr`、`resolve.cr`）全部由 `g_ir_instrs` 驱动。
- 因此 `build_linear_schedule()` 的接线点在 load_ccr 成功（`:296`）之后、`regalloc_debug_dispatch`（`:305`）之前。NOD 文件缓冲 `buf`（`corearch.cr :291`）存在到 `corearch_main` 结束，重扫式重建可行。但 NOD 段界目前是 load_ccr 的局部变量，重扫式需要把 NOD 段的 offset 和 count 传出，或者由段表重新定位；load 之后文件内存仍在，段表头也可以重读。另一种形态是在 loader 内建立 NOD 对象存储，作为对象面 `nod_*` 访问器的数据源。目前 NOD 语义字段除了 `g_ir_instrs` 之外没有任何保留，邻接信息也只是 load_ccr 局部变量。因此任务 1 必须裁决 NOD 对象的留存形态。
- load_ccr 的另一个调用方是 `src/arch/linux/ld/main.cr:56`，属于死代码。该文件自注记为 2026-09-10 内核抽取任务 4：零 concat 引用，双二进制清单都不包含它，实际入口是 `src/compiler/corearch.cr`。签名和搬移改动不需要同步这个文件。

## 交付物 2：region_of_nod 的定夺（设计 spec 第 6 节挂账 ①，裁决为不包含）

- v7 文件没有 `g_df_node_region`。loader 不重建节点到区域的映射：REG 段只派生 `nstart/ncount` 写回 `g_sgs` 行（`ccr_io :1172-1173`，即 enter/exit 副本），不生成任何节点到区域的数组。
- corec 构建侧的映射是构建期快照：`dataflow.cr` 的 `df_create_node :110` 写入 `g_df_node_region[nid] = g_cur_sg`，-1 表示无区域；`sg_push/sg_pop` 以 `g_df_node_count` 记录 enter/exit。内存态不落盘，loader 侧没有对应物。
- 零消费方的事实：corearch 的 concat 清单在 `build_selfhost_native.py :174-199`，包含 hit、ent_kernel、regalloc、sizes/instr/resolve/elf/ld、ccr_io、monomorph、corearch。`g_sgs` 的唯一消费者是 `ccr_io.cr` 的 loader 自身，用于校验、派生和回填。`ent_kernel`、`regalloc`、`instr`、`elf`、`resolve`、`corearch` 全部没有 `OFF_SG_*` 或 `g_sgs` 读取，判定①②不消费区域。另注：设计第 1.2 节“区域面：现有 sg 访问器”的表述不准确。corearch 侧没有任何 `sg_*` 访问器函数，读写都用 `r64/w64` 直接偏移；corec 侧也只有 `dataflow.cr` 的 `sg_push/sg_pop`，没有字段访问器族。
- 推导可行性：REG 行由压栈序、parent 链和 enter/exit 节点坐标组成，形成层流嵌套区间。SG_FUNC 根行 span 与函数指令范围在 save（`:759-765`）和 load（GC-3）两侧都校验过；函数行是相邻 SG_FUNC 行之间的连续段。`region_of_nod(n)` 等于包含 n 的最深行。每次查询可以扫描该函数的 REG 行，复杂度 O(该函数 REG 行数)；也可以用栈扫预计算，复杂度 O(nodes+rows)，事件为 enter/exit 加开行栈。数据无损，后续补充可行，成本低。
- 定夺：对象面 API 不包含 `region_of_nod`，区域面只做 REG 行遍历。理由是零现消费方，配方可读承诺只需要 EDG 和 NOD 邻接；预计算表会成为没有消费者的内核数据，不符合 YAGNI；③④尚未实现，区域感知判定没有落点。未来按需引入，本报告的推导注记就是成本和算法备忘。因此任务 1 的对象面 API 不包含区域推导访问器；任务 4 同步文档时，在 spec 第 1.2 节 API 表把 `region_of_nod` 标为已决的挂账项（不包含）。

## 交付物 3：登记 API 的接入面（任务 2 调用点清单）

### alloc_registers 第 5 阶段的写点（唯一生产写面）

`regalloc.cr :733-792`，逐函数尾部：rc 计数 `:739-744`，asg_lv 收集 `:745-756`，块原语直写（store8 头、count、对 `@+12`，每块切 5 对，`g_opt_meta_count = ei + 1` 在 `:789`）。写对为 var（全局 id `vw = vs + lvp`）到 reg（`r64(var_asg, lvp*8)`）。登记调用点在每个函数的第 5 阶段尾部：对 asg_lv 中的每个 var，其全版本条目 e 落在 `[entry_start(fi), entry_start(fi) + entry_count(fi))` 且 `ent_var(e) == vw` 时，逐一调用 `kern_loc_assign(e, rn)`。等价性纪律：var 级分配要求同一个 var 的所有条目使用同一个 loc，包括 def=-1 的参数条目。`compute_entries` 保证有定值的 var 没有 def=-1 条目，同一 var 的多个版本区间相邻且不相交，因此同组 sweep 不会误报。只登记部分条目会破坏 `rl_rule2_func :643` 的 var 级过滤和 verify `:726/:742` 的逐条目投影，实施时必须登记全部条目（任务 2 注记）。

### 注入钩子的写点（6+1 个：顶层面 3 个、try_* 3 个、coexist-oob 1 个；实际写点在 try_*）

| 钩子 | 位置 | meta 写 | 登记配对 |
|---|---|---|---|
| try_inject_home_conflict | `regalloc.cr :40-67` | `meta_remove_var(v1/v2)` 在 `:56-57`，`home=7` 直写条目表在 `:58-59`。`g_ir_entries` 是内核数据面，无需登记；读侧由 `ent_home` 加域 `home_base` 合成，与现在直读 `ent_home` 等价 | 清除 v1/v2 的全条目登记，随 `meta_remove_var` 配对覆盖 |
| try_inject_reg_conflict | `:192-217` | `meta_set_reg(v1/v2, 3)` 在 `:208-209`，原位改写或追加 | 登记或改写 v1/v2 的全条目为 3 |
| try_inject_read_gap | `:235-283` | 条件执行 `meta_remove_var :267`，`meta_set_reg(gv, 3) :275`，`live_end` 截断 `:277`。条目表直写，无需登记 | 清除共存 var，并登记 gv |
| inject_coexist_oob | `:22-29` | 零 meta 写 | 无 |

- 配对点的取舍（最小面）：在 meta 写辅助函数体内嵌入配对，即 `meta_set_reg :107-111`、`meta_remove_var :115-154`、`meta_append_reg_assign :171-186`，3 个函数就能覆盖全部注入路径。第 5 阶段的原语直写不经过辅助函数，因此配对面总共是第 5 阶段写点、`meta_set_reg`、`meta_remove_var` 三处；`meta_append` 经 `meta_set_reg` 路径覆盖。顶层 `inject_*` 函数只做遍历，没有写操作。
- 注入读探针：`regalloc.cr :254/:261` 调用内核的 `meta_reg_for_var`，见交付物 4 的修正注。

### regalloc_debug_dispatch 的 flag 路径时序（判定何时读登记表）

- 判定的唯一读面是 `regalloc_verify_all`（`ent_kernel :798-807`），它调用 `verify_regalloc_consistency` 逐函数检查。调用点有两处：
  1. `--check-regalloc` 分支（`corearch.cr :188-205`）保序执行：强制 O2 在 `:190`，`alloc_registers` 在 `:191`（第 5 阶段逐函数登记完成），看门狗 `meta_reg_assign_total :194`（直读 `g_opt_meta`，属于实例面 viewer，不经过登记表，维持现状），注入钩子 `:196-198`（配对同步），最后 `regalloc_verify_all :199` 读登记表。表在 verify 之前一定已经填充，因为 alloc 尾部完成登记，注入点也同步。
  2. 生产 O2 门（`corearch.cr :308-314`）：alloc 在 `:309`，verify 在 `:312`，时序相同。
- 其余分支不需要登记表：dump-entries `:152-156`、inject-coexist-oob `:157-161`、dump-coexist `:162-166` 只运行 `compute_live_ranges` 和条目表 dump；dump-regassign `:167-187` 直读 `g_opt_meta`，属于实例面输出，不经过登记表。
- 不存在空表 verify 路径：生产门要求 `g_opt_level≥2` 且 `inst_needs_alloc` 声明；check 分支强制为 2。verify 不会在未 alloc 状态下运行，因此登记表在进程起点为空表，与现状等价（meta 为空、home 全为 -1，得到 0 违反）。
- `alloc_registers` 内 O0/O1 提前返回（`regalloc.cr :372`），空函数 continue（`:388`）。对应函数的 meta 为空或无条目，登记面同样为空，行为等价。

## 交付物 4：判定读 meta 面的全集（通道切换的精确函数面）

- `ent_kernel.cr` 代码级 `g_opt_meta` 读点只有一个函数 `meta_reg_for_var :504-525`。全文 grep 到 12 处 `g_opt_meta` 提及，其中 11 处是注释，只有此函数有 5 处代码读取：循环界 `g_opt_meta_count :507`；块 key r32 `@mo :509`；`data_len @mo+4 :511`；对 var `@mo+8+di :515`；对 reg `@mo+8+di+4 :517`。布局为 `OPT_META_STRIDE` 64（`ast.cr:642`）加 key `OPT_KEY_REG_ASSIGN = 0`（`ast.cr:641`）在 `+0`，`data_len` u32 在 `+4`，`count` u32 在 `+8`（跳过，di 从 4 起按 `@+12/+16` 以 8B 步进）。这与 loader 的 opt_meta 段（`ccr_io :1117-1140`）以及实例的 `meta_reg_pair_off`（`regalloc.cr :84-103`，count 界扫描使用相同偏移）布局一致。
- 调用点在切换后不动：`rl_rule2_func :643`（驻留过滤，var 级语义）、`verify_regalloc_consistency` 计数遍 `:726`、记录构建遍 `:742`。切换方式是等价改写 `meta_reg_for_var` 的函数体，改为查询登记表，即设计第 2.1 节的“{entry 序到 loc}”表和 var 级语义保持注，见交付物 3 的等价性纪律。
- `LOC_HOME_BASE` 的代码面（域参数化替换面）：常量在 `:500`，`rl_print_loc :590` 用于分类打印，verify `:744` 的 home 组投影为 `LOC_HOME_BASE + ent_home(e)`。`reg_domain` 目前没有分组消费点。规则①的组别来自 meta 和 `ent_home` 两个投影，二者天然不相交：reg 为 0..15，home 大于等于 10⁶。`reg_domain` 是声明面参数，另加防相交护栏，实施按 spec 第 2.2 节。
- emit 面独立，已核对：`instr.cr` 的 `get_reg_for_var :34-53` 是字节级同构的独立函数，`g2_slot :55-73` 使用它，`elf.cr:1309` 和 `resolve.cr:36-37` 也在这一面。该面不动。dump-regassign（`corearch.cr :167-187`）是实例面 viewer，不动。
- 计划假设被实证反驳（修正注，任务 2 必须修改）：计划任务 2 写“删除 `meta_reg_for_var`，确认 emit 面无引用”，但只核对了 `instr.cr`。`regalloc.cr` 的注入探针 `try_inject_read_gap :254/:261` 调用了 `meta_reg_for_var`，属于实例侧读内核函数。任务 2 删除或改写时必须同步这两处。建议改为实例侧私有扫描，直接读 `g_opt_meta`，布局风格与 `meta_reg_pair_off`、`meta_set_reg` 相同；也可以复用 `meta_reg_pair_off ≥ 0` 的判断。当前 `:254/:261` 的语义是“gv 是否已被真实分配覆盖”。corec 的 concat 没有引用，`ent_kernel` 定义随编译进行，未使用不会报错，删除后对 corec 侧零影响。
- 另注（观察项）：loader 的 SYM opt_meta 段（`:1117-1140`）把文件中的 opt_meta 块载入 `g_opt_meta`，第 5 阶段的追加块从该计数继续（`g_opt_meta_count` 续接）。D-1=Y 时文件不再带 REG_ASSIGN，首次匹配没有遮蔽；登记表通道天然绕开这段历史，登记只镜像实例写入。切换后判定面是净隔离。

## 交付物 5：中立性 guard 设计（任务 4 的前置设计）

### ent_kernel.cr 当前的符号面（代码级实例相关符号全集）

- `g_opt_meta`、`g_opt_meta_count`，出现在 `meta_reg_for_var` 函数体，任务 2 切换后清零。
- `OPT_KEY_REG_ASSIGN`、`OPT_META_STRIDE`，同一函数体，切换后清零。
- `LOC_HOME_BASE`，`:500` 常量，`:590/:744` 代码使用，任务 2 移除。
- 注释层的实例提及，guard 剥掉注释后不会拦截，记录在案：x86、机器侧、`regalloc.cr` 文件引用（头注 `:4-30`），“instr.cr 的 g2_slot/get_reg_for_var”（`:478/:502`），`rl_print_loc` 的 x86 寄存器枚举注（`:593`，“3=rbx, 12-15=r12-r15”），`alloc_registers()` 前置条件注（`:704`），`OPT_KEY_REG_ASSIGN` 真相源注（`:477`）。
- 代码级没有寄存器名或 ELF 面 token，grep 已确认，rbx、r12 等只出现在 `:593` 注释中。

### 结构性守卫（已有，写入文档）

`ent_kernel.cr` 由两个 concat 共享：`build_selfhost_native.py` 的 corec `:149` 和 corearch `:181` 都包含它。如果它引用实例独有的文件符号（`regalloc`、`instr`、`elf`、`resolve`、`ld`、`sizes`、`hit`、`corearch.cr`），corec concat 会编译失败，因此结构性护栏已经存在。文本 guard 真正要防的是共享声明文件里的实例符号，这些文件两个 concat 都有，包括 `globals.cr`、`ast.cr`、`dyn_arr.cr`。`g_opt_meta` 和 opt 常量布局正属于这一类，结构守卫拦不住 `g_opt_meta`，因为两个 concat 都能编译它，这就是静态 guard 必要性的实证。

### 断言排除集（代码面 token 级）

排除 `g_opt_meta`、`g_opt_meta_count`、`LOC_HOME_BASE`、`OPT_KEY_*`、`OPT_META_STRIDE`（meta 布局族）、`E2_REG_SLOT_BASE/E2_*`、`g_x86_*`、寄存器名 token（rbx/r12/r13/r14/r15/rax 等，即实例枚举注记名）、ELF 面 token（ELF/elf_gen 等）。NOD、EDG、ENT、REG 是文件格式语义名，不拦截，属于 spec 第 4.3 节的例外。

实现注：必须先剥掉注释再扫描标识符。本文件全部使用 `//` 行注释，没有 `/* */` 块注释，剥注释函数约 10 行 Python。扫描用 `\b[a-zA-Z_][a-zA-Z0-9_]*\b`。`rl_print_loc` 的 x86 注记在注释层，不剥会误报。可选强化成本低：要求 `ent_kernel` 引用的标识符与实例独有文件的函数定义集交集为空，这是结构守卫的文本镜像。

### 测试落点

在 `tests/selfhost/` 新建 `test_ent_kernel_neutrality.py`，纯源码文本扫描加断言排除集，不依赖构建，秒级完成。同目录 25 个 `test_*.py` 都采用单体模式，`main()` 返回 0 或 1，并打印 PASS/FAIL，参照 `test_live_ranges.py` 的主函数惯例。任务 4 步骤 1 先写测试并让它失败，因为当前 `meta_reg_for_var` 和 `LOC_HOME_BASE` 仍在代码中；任务 2 切换通道后转为通过。先写 guard 可以尽早暴露问题。

## 文件改动

- `/home/DslsDZC/core/docs/superpowers/plans/2026-09-10-corearch-kernel-completion.md`：回填“任务 0 盘点结果”节，写入①至⑤五条注记，替换占位 blockquote，固定任务 1 至 4 的实施。
- `/home/DslsDZC/core/docs/archive/sdd/kc-task-0-report.md`：本报告。`.superpowers/` 未入版本库，属于工作产物。`src/` 和 `tests/` 零改动，遵守铁律 #4 的行为零变化。
- 提交（jj）：`docs: 内核完备 Task 0 盘点——重建段依赖面/region_of_nod 定夺/登记接入面/判定读 meta 面/中立性 guard 设计（计划定位点点回填）`

## 待核问题

1. `meta_reg_for_var` 有实例侧引用（`regalloc.cr :254/:261`）。计划任务 2 假设“只需确认 emit 面”，已被实证反驳。任务 2 的步骤 3、4 必须同时改这两处，否则删除函数会导致 corearch concat 编译失败。
2. NOD 语义字段在 loader 侧没有留存。重建移出后，对象面 `nod_*` 访问器和 `build_linear_schedule` 的数据源形态尚未确定，可选 loader NOD 对象存储或文件重扫。这是任务 1 的首要裁决。EDG 守卫迫使邻接解析留在 loader，NOD 记录读取不能整体搬走。
3. 接线点在 `corearch_main` 的 load 之后、dispatch 之前，即 `:296-:305` 之间。dispatch 各分支包括注入通道都消费线性流，漏接会导致 dispatch 路径（`--check-regalloc` 等）先崩溃。
4. 设计 spec 第 1.2 节“现有 sg 访问器”的表述不准确，实际没有访问器族。如果区域面需要行访问，就是纯新增的薄读取层；任务 4 同步文档时一并修正。
5. 登记表键序（entry 序）和判定 var 级过滤语义的等价改写是任务 2 的精确面：登记全部条目的纪律，加上表查询版 `meta_reg_for_var` 的语义“var 有任一已登记条目”。见交付物 3 和 4 的注。
6. 旧定位点点（`load_ccr :1361-1393`、corearch flow `:150-164`）已经过时。本报告和计划回填以重新核对的值（`ccr_io :1207-1236` 等）为准。
7. 待核项：无。全部结论都由代码现态读出。“loader 仍须保留 NOD 邻接解析”是 EDG 守卫的推论。如果任务 1 选择整体搬走 EDG 校验则另论，但把守卫留在内核是计划既定方案，按推论执行。
