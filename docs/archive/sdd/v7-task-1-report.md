# v7 任务 1 报告：v7 格式骨架切换（version 7、NOD 36B、EDG 段、df 播种修复）

日期：2026-09-09
状态：完成（DONE），附 2 项保留项，见文末。

## 实现内容

### 写侧（corec，`src/compiler/ccr_io.cr`）

- `CCR_VERSION` 从 6 改为 7；`CCR_SEG_COUNT` 从 5 改为 6；新增常量 `ESZ_NOD_DISK=36`、`ESZ_EDGE_DISK=8`。
- NOD writer 从 28B 改为 36B：28B 语义字段，与 v6 逐字段一致，加 `first_edge u32` 和 `edge_count u32` 邻接域。
- 新增 EDG 段 writer，tag 6，位于规范序末段。落盘前，`ccr_collect_edges` 按节点序单遍走查 `g_df_edges` 头插链表，即 dataflow.cr 的内存邻接，得到每节点出边的连续段，再用 `ccr_fill_edge_buf` 第二遍填充扁平的 {to_nod, kind} 缓冲。写侧守卫与 loader 同域：链表归属错乱、后向边（to_nod 小于等于所属节点，含自环）、kind 大于 1，任一成立就拒绝落盘。loader 永不拒绝自己 writer 的产物。
- 段表从 5 项改为 6 项；扩展 `calc_ccr_size(edge_total)`、`ccr_nod_seg_size`，新增 `ccr_edg_seg_size`。

### 读侧（corearch，同一文件的 `load_ccr`）

- 版本校验要求等于 7。v6 读路径退役，v6 文件由版本检查拒收，没有转换工具。
- 段表 6 项，tag 1 到 6 按规范序；STR、SYM、NOD、REG、EDG 必备，ENT 可缺，保留 v5 精神。
- NOD 36B 读取：28B 语义字段重建线性流，发射输入与 v6 逐字段一致，这是行为等价的硬约束；邻接域暂存到 `nod_edge_meta`。
- EDG 解析和校验，依据 v7 spec 第 4 节，守卫面强度保持：连续段与 NOD 邻接域逐节点对照，要求 `first_edge == 前缀累计`、`Σ edge_count == edg_count`、行走完等于段体大小；每条边要求 `to_nod < instr_cnt`、`to_nod > 所属节点`（拓扑不变量 1）、`kind ≤ 1`。通过后写入 `g_v7_edges` 缓冲，8B 每条扁平记录，加 `g_v7_edge_count`，供后续任务或调试消费。

### 伪边播种修复（执行 controller ruling 1、2、3）

- 根因，表一注 A 已实证：`grow_df_arrays`（`dyn_arr.cr:516`）的新段依赖 alloc 零页。从未定值的 var，包括全局、参数、0 字面量槽，其 producer 槽为 0，被当成“节点 0”，于是 `df_use_var` 产生伪边 0 到 X，以及自环 (0,0)。修复方式是在 `grow_df_arrays` 中对新增长区 `[old_cap, nc)` 的 `g_df_var_producer` 槽显式播种 -1。既有区用 `_dyncpy` 保留；定值由 `df_create_node` 覆写。
- 缓存面：restore 路径同样走 `grow_df_arrays`，播种会自动覆盖未产出的 var 槽，并加注释说明；`CIR_CACHE_VER` 从 13 改为 14，位置 `cir_cache.cr`。旧快照含伪边，因此失效为 cache miss，无害重建。
- 播种后的行为验证。实现前先建 Python 独立模型，镜像 `df_connect_srcs` 语义并重放播种语义，与 buggy 的 `.cir` dump 交叉核对：模型边是 buggy 实发边的子集，差集就是伪边，全部为 0 到 X 形态。真实编译产物包含 fmt 自动导入，全局行恒为 0..21，因此 var 0 是全局且永不定值，EDG 为纯 def-use：没有 0 到 X，没有自环，没有 (0,0)，三个程序实测 sim 全部零违反。live `.cir` 复验：fresh probe DOT 有 1117 条边，0 个自环，from0 只有 n0 到 n3，是真实的 arena def-use。

### ELF 层配套修复（`src/arch/linux/ld/elf.cr`，任务文件清单之外，必要配套）

见保留项第 1 条。编译器巨型函数尾存在既有代码生成缺陷，通过重构 `hit_rel` 回填守卫规避，语义零变化，注记在代码内。

## 测试和结果

| 套件 | 结果 |
|---|---|
| `tests/selfhost/test_ccr_v7.py`，新增，6 个用例 | 6/6 通过 |
| `tests/selfhost/test_ccr_v6.py`，机械更新 8 个用例 | 8/8 通过 |
| `tests/selfhost/test_backend_bootstrap.py`，stage 链 | 11/11 通过，stage1 到 3 byte-identical |
| `tests/selfhost/test_compile.py` | 全部通过 |
| `tests/selfhost/test_hit_table.py` | 24/24 通过 |
| `tests/selfhost/test_region_cfg.py`，v7 walker 机械更新 | 22/22 通过 |
| `tests/selfhost/test_mw_task1.py`、`test_mw_task2.py` | 全部通过，V6File 改为 V7File 别名，NOD 8 元组解包机械更新 |
| `tests/selfhost/test_live_ranges.py`，附加 | 通过 |
| 冒烟：`corec run`、`check`、`cir`，fresh probe DOT 无伪边 | 通过 |

测试前都执行 `rm -rf .core/cache`。每次 corec 调用使用唯一临时路径，因此 cache miss，得到确定性的 fresh 编译，这是 EDG 内容断言的前提。

## TDD 证据

- 失败态，步骤 1、2：`test_ccr_v7.py` 首次运行 0/6，报 `expected version 7, got 6`，因为还是 v6 writer。附带实证 version 6 文件被旧 corearch 接受，rc=0。
- 通过态，步骤 3 到 5：写侧、读侧、播种修复实现，加 `test_ccr_v6.py` 机械更新后，v7 6/6 和 v6-file 8/8 一次全部通过。EDG 内容断言 `test_v7_edge_content_small_program` 检查 pure_add 和 main 两个函数的精确边集合，为 41 条 data 边加 13 条 state 边，与实现前模型的期望逐边吻合。伪边回归会表现为集合多边，立即失败。
- 步骤 6 回归：全部通过，见上表。
- 步骤 7：已提交。

## 修改的文件（commit `4f255fb4`）

- `src/compiler/ccr_io.cr`：v7 写读双侧、常量、头注释。
- `src/compiler/dyn_arr.cr`：`grow_df_arrays` 的 producer 播种 -1。
- `src/compiler/cir_cache.cr`：`CIR_CACHE_VER` 从 13 改为 14，加注释。
- `src/arch/linux/ld/elf.cr`：`hit_rel` 回填守卫重构，见保留项第 1 条。
- `tests/selfhost/test_ccr_v7.py`：新建 V7File walker，包含 header、6 段段表、36B NOD、EDG 走查、reject 面（version 不等于 7、后向边、Σ 不符）、EDG 内容期望、roundtrip。
- `tests/selfhost/test_ccr_v6.py`：机械更新，version 7、6 段、36B NOD、EDG 走查、拒绝 version 不等于 7；ENT 空断言暂留，任务 2 翻转。
- `tests/selfhost/test_region_cfg.py`：`ccr_walk` 机械更新到 v7 契约。
- `tests/selfhost/test_mw_task1.py`、`test_mw_task2.py`：import 别名，NOD 8 元组解包。

## 自审发现

- 没有 cir 相关测试断言过伪边，这是规则 4 的预期通过面。region_cfg 和 mw 断言 region 结构、状态边和终止边，播种不触及这些，除 NOD 元组宽度机械更新外零语义改动。
- 写侧守卫和 loader 同域校验已覆盖自环、后向、kind、Σ、连续段。branch 和 jump 的目标是操作数，不是边，这是 spec 第 4 节的边界声明，校验实现没有把操作数当边。
- EDG 内容和表一期望：源函数两个函数为 41 条数据边加 13 条 state 边，逐条吻合“去掉伪边后”的语义。GAP 行，包括 I2F、F2I、ADDR_INDEX、YIELD、AWAIT、CALL_EXTERN 多参等，按 `df_connect_srcs` 现状为无出边，记录在案，不是本任务的修复面。
- 跨函数边：播种后没有。源 span 内的数据边全部有 in-span 断言。fmt 模块函数边走全文件拓扑和 kind 校验。

## 保留项

1. `elf.cr` 的 `hit_rel` 回填守卫重构，必要配套，不在任务文件清单内：backend_bootstrap 的 stage1，即 `corec build src/arch/linux/ld` 目录构建产物，在 v7 下确定性 segv，位置在 emit 尾部的 `hit_rel` 回填区。排查链：崩溃指令读取 `(rdi=fsize−4 值, rsi=0)`，gdb 证实 `elf_gen` 内 ×24 行回填循环的 bound 和 base 局部变量，是全函数没有任何写点的未初始化栈槽，读到陈旧栈值，值精确跟踪 `load_ccr` 帧残留，即输入文件 fsize−4。根因定性为自举编译器对巨型函数尾控制流形状的既有代码生成缺陷。同源码 concat 构建 corearch-full 时，陈旧栈值恰好为 0，缺陷潜伏未触发；v6 目录构建同源潜伏。v7 loader 的帧轮廓变化，虽非语义，把它激活了。修复是重构 `elf.cr` 该回填块的守卫，计数先读局部，再加外层 if，语义等价，代码内有注记。这是规避形状，不是修复编译器根因。编译器层缺陷待核，不是本任务范围。规避不是绕过，语义等价并且全回归验证。如果未来重排 ld 源码布局，该缺陷可能再次触发。
2. loader 的后置 EDG 解析在 ENT 之后，解析序为 STR、SYM、REG、NOD、ENT、EDG。EDG 是文件末段，如果未来段序变化需要同步。当前与 writer 规范序锁步，walk 校验 end==fsize 是双保险。
3. 目录构建产物 stage1 自身包含 ccr_io 编译物的布局敏感性，与保留项第 1 条同源。测试依赖该产物时需要注意。

## 报告文件

`docs/archive/sdd/v7-task-1-report.md`
