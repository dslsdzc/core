# 内核抽取任务 3 报告：注册契约的最小面（实例声明表和表驱动分派）

状态：完成（DONE），行为不变判据全部通过。提交：`6413dd80`，提交信息 `feat: 内核抽取 Task 3——注册契约最小面（实例声明表 + 表驱动分派,行为不变）`。

## 交付内容

### 步骤 1：文档化内核接口面（ent_kernel.cr，只改注释）

文件头注扩展为契约文档。内核 API 面就是本文件的函数集，现有名称即 API，不增加 `kern_` 包装层，按 YAGNI 裁决。按职责族列出数据面、判定服务、诊断通道。实例侧是 `regalloc.cr` 的机器函数，包括 CAG、`g_opt_meta` 写入和注入钩子。注册契约最小面的位置和字段位于 `corearch.cr` 的 `g_instance_decl`。

### 步骤 2：实例声明表（corearch.cr 的数据和查询）

`g_instance_decl` 每行包含 {id, name str_idx, opt_min, opt_max, allow_table, allow_link, needs_alloc, needs_verify}，共 8 个 i32，`INST_DECL_STRIDE = 32`，行序等于 id 序。

- INST_X86（id 0，默认实例）：窗口 [0,3]，allow_link=1，needs_alloc=1，needs_verify=1。
- INST_TABLE（id 1，表模式路径雏形）：窗口 [0,0]，声明为恒 O0 语义，allow_table=1，allow_link=0（保持 M2-1 的显式拒绝），needs_alloc=0，needs_verify=0。

查询面：`grow_instance_decl`、`instance_decl_add`（注册最小函数）、`instance_decl_init`（幂等）、8 个 `inst_*` 字段访问器、`instance_lookup(name str_idx)`、`instance_select()`。`instance_select()` 的流程是读 flag、取名称、查表、返回行。

### 步骤 3：引导收敛（表驱动分派，行为保序）

`corearch_main` 在 `cli_parse` 之后固定执行 `g_active_instance = instance_select()`。选择旗标是 `--table` 值是否存在，与装载条件同源。三路分派逐点查询活动实例行：

| 原直写条件 | 声明化条件 | 等价性 |
|---|---|---|
| `--table` 与 shared 或 link 组合时拒绝（`:106`） | `inst_allow_link(act)==0` 门 | 拒绝只由表实例触发（allow_link=0），消息和顺序不变 |
| 级别钳制 0..3 直写 | `inst_opt_min/max(INST_X86)` | x86 行窗口等于旧常数。表行 [0,0] 是语义侧职责窗口，CLI 值透传给发射侧，不按表窗口钳制。实测 `-O2 --table` 的帧布局仍随 `g_opt_level` 保持现状，见注 |
| O2 门 `level≥2 && hit_table_active()==0` | `level≥2 && inst_needs_alloc(act)!=0`，verify 另查 needs_verify | 此时实例等于装载态，装载失败已提前 exit |
| 表管线门 `hit_table_active()`（2 处） | `inst_allow_table(act)` | 同上，依赖恒等不变量，注释中已记录 |

`regalloc_debug_dispatch` 的六个分支零改动，保持请求分派形态，只增加角色头注。`--check-regalloc` 的顺序保持不变：强制 O2、alloc、看门狗、注入 3 次、verify_all、摘要和 rc。

### 步骤 4、5：判据

- flag 通道 15 项逐字节相同：dump-entries 两个程序、dump-coexist、inject-coexist-oob、check-regalloc 通过 2 次、注入失败 3 次、read-gap-nonfunc0、dump-regassign O0 和 O2、`--table` 与 link 拒绝、`--table` 加 dump-entries、`--table` 加 check-regalloc、hit-events-file 无表拒绝。
- `test_live_ranges` 13/13。回归快子集 compile、backend_bootstrap、hit_table、region_cfg 以及 `test_ccr_v7` 全部通过，测试前清理 `.core/cache`。
- 自举重建：`nice -n 19 build_selfhost_native.py`，三个二进制全部构建成功。

## 过程中发现的两个前置问题（与本任务无关，已甄别，建议登记）

1. `.core/cache/cir` 在跨编译器重建后不失效，这是前置缺陷。cir cache 以“源路径::函数名”为键缓存每个函数的 CIR。corec 二进制重建后旧键仍然命中，复用的 CIR 与新版字符串表序错位，导致 `--dump-entries` 等通道的输出中部分 var 名缺失。本任务验证中曾出现 name= 数量从 806 翻转为 381。清 cache 后判据可以逐字节复现。计划的 Global Constraints 已要求“清 `.core/cache` 后跑测试”，本次结论都以清 cache 状态为准。建议在 `cir_cache.cr` 中给缓存键加编译器指纹或内容哈希，否则每次重建二进制后测试面都可能被不报错地污染。
2. 任务开始时的 `build/` 二进制与提交源码不一致，属于环境陈旧。初始基线（未清 cache）与提交源码重建的输出在 var 名打印上有差异。纯重建、零代码改动就能复现该翻转，与任务 3 无关。判据定位点点采用“同源重建加清 cache”的基线。

## 设计注记（供评审）

- name 列是 str_idx，即 `str_intern` 的内联名。引导期在 `load_ccr` 之前内联；`load_ccr` 重置 `g_strs` 后索引失效。本任务的消费面 `instance_select` 都发生在选择期，没有装载后读名的路径。注释中已记录。蓝图注册校验如果读名，必须在装载后重新内联。
- 表行 [0,0] 窗口的语义是语义侧职责窗口：恒 O0 意味着 O2 组合验证永不执行，由 `needs_*=0` 强制。它不是 CLI 值域钳制。发射侧布局仍按 `g_opt_level` 透传。实测 `--table -O2` 与 `-O0` 输出不同字节，这是已有行为，钳制会破坏 byte-identical。
- `inst_id`、`inst_name` 等访问器和 id 字段用于声明完整性，属于注册契约的数据面。当前消费面见上表。`opt_min` 字段是 x86 窗口下界的来源，钳制时将小于 0 的值改为 0。
