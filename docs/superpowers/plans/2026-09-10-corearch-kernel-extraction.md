# corearch 内核抽取实施计划（范式无关内核 + 实例定制，演进序步骤 2）

> 状态：实施完成（2026-09-10）。Task 1-4 对应提交：Task 1 语义侧纯迁移（b0d24b1b：ent_kernel.cr = 内核 32 函数逐字迁移加 LOC_HOME_BASE 单份随判定入内核；regalloc.cr 从 1560 行减到 844 行，只留机器侧；检查通道 sha256 逐字节同）。Task 2 写侧单源化（edc70fbe 加 c138c44c：删除 compute_entries_v7/ccr_grow_* 镜像、RPT_MAX/ir_op_kind_name 迁到内核、ent_kernel 进双 concat 加 src/compiler import ent_kernel；full-bootstrap 面 N06/SIGSEGV 缺口闭合，全链 N06=0 加 corec2/corec3 cmp=0）。Task 3 注册契约最小面（6413dd80：g_instance_decl 两行实例声明表加表驱动 dispatch，评审独立 48/48 通道 base 和 head 逐字节全同）。Task 4 结束（本提交：全量回归通过，compile/backend_bootstrap 链/hit_table 24/24/region_cfg 22/22/mw1-6/slice_bounds 7/7/live_ranges 13/13/ccr_v7 23/23/bootstrap 三套加 full-bootstrap guard 加自举重建快速验证；方案步骤 2 完成注记；cir cache 指纹缺陷列入 TODO 预存 Bug #5）。
> 面向执行本计划的 agent：必须使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans，按任务逐项实现。用复选框（`- [ ]`）跟踪进度。

目标：从 corearch 的 regalloc.cr 抽出范式无关内核（语义判定引擎加条目/区间数据面加注册契约最小面），机器侧（CAG 分配/meta 写入）留在 x86 实例。行为零变化，判定语义不动，只迁移代码。

结构：纯代码迁移加单源化收敛加最小契约形式化。数据面（g_ir_live_ranges/g_ir_entries = globals.cr 共享声明）已经是结构化语义对象。判定引擎（共存/规则12）不读值内容，不含寄存器名或 ABI 常量（硬编码点全在 alloc_registers 阶段 1/2/4 与 meta 写入，属于机器侧）。判定到机器侧的唯一读通道是 meta_reg_for_var（分配输出输入通道，随判定迁移）。双转录的第三处（ccr_io.cr compute_entries_v7 写侧镜像）借共享文件约束做单源化：corec 与 corearch 共用 globals，内核文件进双 concat 后，corec 写侧直调内核 compute_entries，删除镜像。

技术栈：src/arch/linux/ld/regalloc.cr（1560 行，拆分源）、src/compiler/ccr_io.cr（loader/写侧）、src/compiler/globals.cr 加 dyn_arr.cr 加 ast.cr（共享声明）、build_selfhost_native.py（双 concat 清单）、Python 测试（test_live_ranges.py 13 检查基准加 test_ccr_v7.py 23/23 写侧检查）。

设计 spec：`docs/superpowers/specs/2026-09-09-corearch-rewrite-design.md`（第 2 节裁决表：语义侧到内核、机器侧到 x86 实例；第 3 节演进序步骤 2 = 本计划执行依据）。

## 全局约束

- 版本控制用 `jj`，见项目规则第 2 条，git 被 hook 拦截。每任务用 `jj commit -m '<msg>'`。
- 构建 `nice -n 19 python3 build_selfhost_native.py`，约 2-3 分钟；测试加 `nice -n 19` 前缀，见项目规则第 6 条；清 .core/cache 跑测试。
- 行为零变化硬约束：判定语义不动，只迁移代码。检查 = test_live_ranges.py 13/13（判定通过和失败路径加 dump 通道输出不变）加 test_ccr_v7.py 23/23（写侧单源化后产物 byte-identical）加回归面（compile/backend_bootstrap/hit_table/region_cfg/mw1-6/slice_bounds/bootstrap 三套加 run.sh full-bootstrap corec 链。Task 结束做全量。ent_kernel 双 concat 共享后，src/compiler 单源自编译单元也是回归面成员：Task 2 评审发现该面 N06/SIGSEGV 缺口，src/compiler/_import.cr import ent_kernel 加 module.cr 跨树回退补齐）。
- 迁移纪律：逐函数迁移零改动（函数体 byte-identical 迁入新文件，除去重收敛点）；禁止顺手改语义或加接口抽象（方案要求「判定语义不动只迁移代码」，资源域参数化和双向注册契约属于后续步骤，不在本计划）。
- 共享文件约束：globals.cr/dyn_arr.cr/ast.cr/ccr_io.cr 进双二进制；regalloc.cr 只在 corearch concat；新内核文件若需 corec 侧（写侧单源化），进双 concat。
- 判定34 无实现（文档化 TODO：静态放置无驱逐事件，callee-saved 平凡满足），本计划不补实现。
- src/arch/linux/ld/main.cr 是死代码遗留（零 concat 引用），本计划不处理，删除待核列入待办。

---

## Task 1: 语义侧迁移，新内核文件 + 数据面/判定引擎纯迁移

文件：
- 新建：`src/arch/linux/ld/ent_kernel.cr`（内核：语义判定引擎加条目/区间数据面；文件头注：范式无关，不读值内容，无寄存器名/ABI 常量/编码知识）
- 修改：`src/arch/linux/ld/regalloc.cr`（删除语义侧函数，改为调内核；保留机器侧）
- 修改：`build_selfhost_native.py`（corearch concat 加 ent_kernel.cr）

接口：
- 迁入内核的函数（regalloc.cr 现位到 ent_kernel.cr，逐函数零语义改动）：
  - 数据面：grow_live_ranges (:18)/live_range_slot (:25)/live_first (:35)/live_last (:40)/compute_live_ranges (:48)/grow_entries (:139)/grow_func_entry_meta (:146)/ent_off/ent_var/ent_def/ent_live_start/ent_live_end/ent_home/ent_flags (:161-167)/entry_start (:170)/entry_count (:175)/compute_entries (:180-268)
  - 共存：entries_coexist (:364)/coexist_version_conflicts (:380)/coexist_home_conflicts (:411)
  - sweep 检查：rl_rec_lt (:515)/rl_merge_sort (:525)
  - 诊断：dump_entries_summary (:314)/dump_coexist_summary (:440)/rl_print_loc (:576)/rl_func_name (:584)。注意 rl_print_loc 内的 x86 注释（:580 "3=rbx"）随迁，注释层本计划不清理，注记待后续
  - 常量：LOC_HOME_BASE (:486)（位置编码约定 = 判定与实例的共享 seam）。裁决修正（Task 1 实证）：单份随判定迁入内核。原因是 concat 单编译单元下自举 NameResolver 拒绝重复顶层声明（name_resolver.py:73 无去重守卫加 symbol_table.py:28 NameError），且机器侧实证零引用
- 保留 regalloc.cr（机器侧）：meta_reg_for_var (:491。裁决：随判定迁入内核，它是判定输入通道（verify 读分配输出），纯读取）；meta_set/append/remove/reg_assign_total (:849-936) 留实例侧（写入 = 实例动作）；alloc_registers (:1136-1560) 留；注入钩子 (:805-1125) 留（注入 = 改分配结果，属实例侧测试通道）；ir_op_kind_name (:278) 留（dump 诊断公共，或随迁。裁决：留 regalloc.cr，两文件同 concat 可以互调）
- verify 判定面（规则12合成）。裁决：本任务迁移 verify_regalloc_consistency (:693-781)/rl_rule2_func (:624)/rl_report_rule1/2 (:590/:602)/regalloc_verify_all (:785)。它们读 meta_reg_for_var（已随判定迁入内核），迁移后 verify 全在内核；regalloc.cr 机器侧经 alloc_registers 尾或外部调用内核 verify（现调用点 corearch.cr:69/:163 不变，函数名不变即可）。
- 检查：test_live_ranges.py 13/13 加回归快子集（O2 check-regalloc 路径通过，corearch.cr 调用点签名不变）

- [ ] Step 1: 建 ent_kernel.cr（文件头加迁移函数框架，先迁数据面 grow/live/ent accessor 加 compute_live_ranges/compute_entries）
- [ ] Step 2: corearch concat 加 ent_kernel.cr；构建确认无符号冲突（函数跨文件调用可以，concat 是单编译单元）
- [ ] Step 3: 迁移共存/sweep/诊断/dump 函数
- [ ] Step 4: 迁移 verify 判定面（meta_reg_for_var 加 rl_* 加 verify_*）
- [ ] Step 5: regalloc.cr 删已迁函数（保留机器侧加对外调用面）；构建加 test_live_ranges 13/13（检查：dump-entries/coexist 输出与迁移前逐字节同，先跑基线再跑迁移后对照）
- [ ] Step 6: 回归快子集（compile/backend_bootstrap/hit_table/region_cfg）
- [ ] Step 7: 提交 `refactor: 内核抽取 Task 1：语义侧迁移 ent_kernel.cr（判定引擎 + 数据面纯迁移，零语义改动）`

---

## Task 2: 写侧单源化，消除 compute_entries_v7 镜像

文件：
- 修改：`src/compiler/ccr_io.cr`（删 compute_entries_v7 :458-579 加 ccr_grow_entries/ccr_grow_func_entry_meta :419-433 加局部 lr 表机制；写侧直调内核 compute_entries/compute_live_ranges；save_ccr ENT 写调用点 :611 适配）
- 修改：`src/arch/linux/ld/regalloc.cr` 加 `src/arch/linux/ld/ent_kernel.cr`（把 RPT_MAX 加 ir_op_kind_name 从 regalloc.cr 迁入 ent_kernel.cr。Task 1 评审 Important：这两个声明在机器侧零剩余使用（ir_op_kind_name 唯一调用方 = 内核 dump_entries_summary；RPT_MAX 唯一使用方 = 内核 rl_rule2_func/verify_regalloc_consistency），regalloc.cr 不在 corec concat，内核进 corec concat 前不迁则 corec 构建解析失败；迁移零风险）
- 修改：`build_selfhost_native.py`（ent_kernel.cr 进 corec concat，corec 二进制需要内核 compute_entries）
- 测试：`tests/selfhost/test_ccr_v7.py`（23/23，ENT 实记录产物 byte-identical 检查）

接口：
- 内核 compute_entries/compute_live_ranges 现用全局 g_ir_live_ranges/g_ir_entries（globals.cr 共享声明，corec 进程内可用；corec 侧时序：save 前调用，即 main.cr ccr/build 路径 lower_to_ccr 后。compute_live_ranges 扫 g_ir_instrs（lower 后 = df 镜像），与 corearch 语义相同）
- 差异消解（Task 0 勘探注记）：1 表实现方式（ccr_io 局部 lr 改为内核全局 g_ir_live_ranges，corec 侧 grow/init 检查）；2 整表重置时序（compute_entries 的 func_i==0 分支与 compute_entries_v7 函数头清零，统一为内核语义）；3 grow 单实例（删 ccr_* 副本）；4 半开转换（写侧盘布局 +1 逻辑保留在 ccr_io 写点，内核算闭区间，写盘转换归 ccr_io）
- 检查：test_ccr_v7.py 23/23（含 ENT 手算期望和独立模型 replay，产物与 Task 2 原实现 byte-identical 即镜像消除无损）加 test_live_ranges 13/13（corearch 侧不动）

- [ ] Step 1: RPT_MAX 加 ir_op_kind_name 迁入 ent_kernel.cr（从 regalloc.cr，Task 1 评审 Important 携带），然后 corec concat 加 ent_kernel.cr；构建（corec 二进制含内核）
- [ ] Step 2: ccr_io 写侧适配：save ENT 前调内核 compute_live_ranges 加逐函数 compute_entries（func_i 循环。内核 compute_live_ranges 尾部已逐 func 调 compute_entries，直接调 compute_live_ranges 即可），然后写盘（半开转换保留）
- [ ] Step 3: 删 compute_entries_v7/ccr_grow_*/局部 lr 机制（ccr_param_entry_id/ccr_ent_* 访问器如仍被 loader 或写侧使用则保留，按实际引用删）
- [ ] Step 4: test_ccr_v7.py 23/23 通过（产物 byte-identical。若差异，先比对 ENT 段，差异即单源化语义偏差，修内核调用序，不改检查）
- [ ] Step 5: 回归快子集
- [ ] Step 6: 提交 `refactor: 内核抽取 Task 2：写侧单源化（compute_entries_v7 镜像消除，双转录 R5 收敛）`

---

## Task 3: 注册契约最小面，实例声明表 + 内核引导

文件：
- 修改：`src/compiler/corearch.cr`（分派形式化：三路分派（--table×opt 门/--opt-level/O2 verify/调试 flag）改为实例声明表加表驱动 dispatch）
- 修改：`ent_kernel.cr`（内核入口函数族：kern_ 前缀导出，kern_compute_entries/kern_verify_all/kern_dump_* 封装现函数名；实例能力声明数据结构和注册函数最小面）
- 测试：`tests/selfhost/test_live_ranges.py`（13/13，flag 通道输出不变）

接口：
- 实例声明表最小形态（Core 无高阶函数，使用数据表加 switch 分派）：
  - `g_instance_decl : {id i32, name str_idx, opt_min i32, opt_max i32, allow_table i32, allow_link i32, needs_alloc i32, needs_verify i32}` × n（表数据 = x86 实例声明加表模式路径声明。表模式是独立实例路径的雏形，见方案第 2 节表裁决）
  - 引导：corearch_main 读 flag，查表选实例（现三路分派逻辑收敛为表查询加 switch 调用）
  - 内核入口：现有函数名加 kern_ 别名，或直接以现名作为内核 API。裁决：现名即 API，加头注「内核接口面 = 本文件函数集」，不加包装层（YAGNI）
- 行为检查：flag 测试通道输出逐字节不变（dump-entries/coexist/check-regalloc 全同），纯形式化重构
- 范围克制注：本任务只做最小面（声明表加引导收敛）。资源域代数参数化（判定读 g_opt_meta 的耦合）和双向契约（判定结果回填 home）属于方案后续步骤，本计划不做（见全局约束的迁移纪律）。

- [ ] Step 1: 内核头注加接口面声明（kern_ API 面 = 现函数集，文档化，不动代码）
- [ ] Step 2: 实例声明表（corearch.cr 数据加查询函数）
- [ ] Step 3: 三路分派收敛为表驱动 dispatch（--check-regalloc 顺序 :58-75 保序：强制 O2、alloc、看门狗、注入、verify_all，行为不变）
- [ ] Step 4: test_live_ranges 13/13 加回归快子集
- [ ] Step 5: 提交 `feat: 内核抽取 Task 3：注册契约最小面（实例声明表 + 表驱动分派，行为不变）`

---

## Task 4: 结束，全量回归 + 自举重建 + 文档/清单

文件：
- 测试：全量回归面（compile/backend_bootstrap/hit_table/region_cfg/mw1-6/slice_bounds/live_ranges/ccr_v7 加 bootstrap 三套加 full-bootstrap stage：`./build/corec build src/compiler/main.cr -o /tmp/corec2 --static -O 0` 输出 N06-free 且 /tmp/corec2 快速验证通过，这是 src/compiler 单源自编译单元含内核的保护性断言）
- 修改：`docs/superpowers/specs/2026-09-09-corearch-rewrite-design.md`（第 2 节裁决表执行状态注记加步骤 2 完成标记；新发现注记：判定到 meta 的读通道随判定入内核，写入留实例，注册契约需要双向（勘探发现））
- 修改：`src/arch/linux/ld/main.cr` 死代码注记（删除待核列入待办。本任务裁决：只注记不删，确认非本计划范围）
- 测试：`nice -n 19 python3 build_selfhost_native.py` 重建加快速验证（corec check/run 小样本加 backend_bootstrap stage 链）

接口：
- 读取：Task 1-3 全部
- 验证：全量回归通过加自举重建快速验证；文档同步（方案步骤 2 完成、裁决表状态、双转录收敛注记 R5 消除）；progress 清单

- [ ] Step 1: 全量回归跑批
- [ ] Step 2: 自举重建加快速验证
- [ ] Step 3: 文档同步（方案状态/裁决表/新发现注记：判定到 meta 的读通道方向、grow/accessor 收敛成果、rl_print_loc x86 注释待清列入待办）
- [ ] Step 4: 提交 `docs: 内核抽取结束：方案步骤 2 完成 + 全量回归 + 文档同步`

---

## 风险注记

- Task 1 是最大风险（迁移 30 多个函数跨文件）。检查是 dump/verify 输出与迁移前逐字节同（先基线后对照）；逐函数零改动纪律防止语义变化。
- 双 concat 符号共享：ent_kernel.cr 进 corec concat（Task 2）时，ccr_io 内残留同名函数（ccr_grow_* 等已删），删除完整性以构建加测试判断。
- LOC_HOME_BASE 单份随判定入内核（裁决修正：双份不可构建，机器侧零引用实证。实例 seam 常量单源化是注册契约参数化步骤的天然内容，届时实例侧经内核导出访问）。
- corec 侧 compute_live_ranges 首次运行时序（g_ir_live_ranges grow/init。corec 进程 init_df 是否没有此表初始化？globals 声明即零态，compute 前自 grow，与 corearch 同路径，回归验证）。
- 判定34 无实现不补（见全局约束）。verify 覆盖规则12，test_live_ranges 现有通过和失败路径即检查基准。
