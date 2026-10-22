# 内核完备 Task 1 报告：语义对象模型（对象面 API 和调度重建移实例）

状态：完成
日期：2026-09-10
基线：4f430703（Task 0 计划修复提交）
提交：单提交 `feat: 内核完备 Task 1，语义对象模型（对象面 API + NOD 对象存储 + 调度重建移实例 build_linear_schedule）`

## 1. 交付面

| 文件 | 改动 |
|---|---|
| `src/arch/linux/ld/ent_kernel.cr` | 在尾部追加语义对象模型一节：对象存储全局（g_v7_nod_sem 每节点 28B，节点语义字段镜像；g_v7_nod_meta 每节点 16B，节点邻接域；g_v7_nod_count）、布局常量（ESZ_NOD_SEM/ESZ_NOD_META/OFF_NS_*）、对象面访问器（nod_op/nod_dest/nod_s1/nod_s2/nod_s3/nod_tk/nod_edge_first/nod_edge_count 以及 v7_edge_to/v7_edge_kind）。这些属于内核接口面，由双 concat 共享。region_of_nod 不包含在内，Task 0 的定夺注记写入节头 |
| `src/compiler/ccr_io.cr` | 收敛 load_ccr：NOD 段重建循环改为对象载入（语义字段写 g_v7_nod_sem，邻接域写 g_v7_nod_meta）；g_ir_instrs/g_ir_instr_count 的写点全部清除；nod_edge_meta 从 loader 局部变量升为内核 g_v7_nod_meta（EDG 守卫消费同源，守卫逻辑零改动）；状态重置加入 g_v7_nod_count；头注释和段注释同步，注明守卫全程不依赖线性流 |
| `src/arch/linux/ld/regalloc.cr` | 尾部新增实例函数 `build_linear_schedule()`，把重建段函数体原样搬移过来（grow_ir_instrs 加 nod_* 访问器顺序直出，g_ir_instr_count 递增） |
| `src/compiler/corearch.cr` | 接线：load 成功并执行 init_backend_arrays 之后、regalloc_debug_dispatch 之前调用 build_linear_schedule()；新增隐藏调试 flag `--dump-objects` 和 dump_object_surface()（实例侧的薄通道，作为对象面测试实现方式） |
| `src/arch/linux/ld/main.cr` | 同样接线（load 成功后调用 build_linear_schedule，这是自举 stage 链入口，见第 3 节偏差 ①） |
| `src/arch/linux/ld/_import.cr` | 增加 `import regalloc`（接入自举 stage 链的编译集，见第 3 节偏差 ①） |
| `tests/selfhost/test_ccr_v7.py` | 新增测试 `test_v7_object_surface_recipe_readable`（对象面 EDG 配方可读判据）和 parse_object_dump 辅助函数（TDD，先失败后通过） |

## 2. 判据证据

| 判据 | 结果 |
|---|---|
| test_ccr_v7.py | 24/24（原有 23/23 保持，加对象面新测试 1 项） |
| 对象面 EDG 配方可读（设计第 4.4 节） | 全图逐节点、逐边等于 V7File 文件解析结果（语义字段和邻接域无损）；节点出边遍历（[first, first+count) 区间到 v7_edge_to/kind）等于文件 EDG 走查；源函数域的数据边和 state 边等于表一去幽灵后的期望（复用 EXPECT_DATA/EXPECT_STATE） |
| backend_bootstrap stage 链 | stage1 == stage2 == stage3 byte-identical（重建产物相同，证明是纯搬移），smoke ELF rc 7/7，O2 metadata ELF rc 7 |
| 回归快子集 | test_compile 全部通过，test_hit_table 24/24，test_region_cfg 22/22，test_live_ranges 13/13 |
| loader 守卫强度 | 负分支 9 个测试全部通过（ENT 越界、命名空间、EDG 拓扑、root span、version。NOD 计数和 g_v7_nod_meta 消费面证明零线性流依赖） |
| 手工冒烟 | O2 生产链（alloc、verify、ELF emit、run）结果为 45；--check-regalloc 0 violations；--dump-entries 正常（线性流重建后消费面全部可用） |

## 3. 偏差与裁决执行注记

①（重要）Task 0 的“main.cr 是死代码，无须同步”裁决与实证不符。backend_bootstrap stage 链的入口是 ld 独立工程 main.cr 的 corearch_main，它的 load_ccr 调用（main.cr:56）是活消费方。证据：ld 独立工程的 .ccr 函数清单包含 main/corearch_main（464 个函数，没有 regalloc.cr，因为该文件不在 _import.cr 的导入集）；backend_bootstrap 基线能跑通，说明 stage 链逐字节复制了这个入口。如果不接线，load 后 g_ir_instrs 为空，stage 链必然中断，违反硬性判据。处理方式：main.cr 在 load 后调用 build_linear_schedule()，ld/_import.cr 增加 `import regalloc`。实证结果是加导入后独立工程编译通过，alloc_registers 等成为该工程的死代码，行为不变。build_selfhost_native.py 的 corearch concat 本来就包含 regalloc.cr，两处注册齐全。这个偏差是判据驱动的必要修正，不是违反裁决；ruling 3 的接线点在两个入口以相同语义实施。

② 对象留存形态采用裁决 (a) 的对象存储，实施为双缓冲。g_v7_nod_sem 每节点 28B，是盘上 36B 剥离邻接后的镜像，offset 布局与盘上相同，loader 逐字段用 buf_read_* 读入，再以 w32/w64 写回，等于盘字节镜像。g_v7_nod_meta 每节点 16B，内容为 {first_edge i64, edge_count i64}，由原 nod_edge_meta loader 局部变量升格为内核缓冲。EDG 守卫消费邻接域时改读 g_v7_nod_meta，守卫逻辑零改动，只更换背衬变量。裁决要求记录内存成本：每节点新增永久成本 28B + 16B = 44B，g_ir_instrs 每节点 48B 是既有成本。实测样例 1276 个节点约 55 KB；大盘点规模（30K+ 指令）约 1.3 MB。arena 进程内一次性分配，可以接受，不需要退回 (b) 文件重扫。

③ 对象面测试实现方式是新的隐藏调试 flag `--dump-objects`（corearch.cr，实例侧的 dump_object_surface 薄通道，读取内核访问器，内核不新增函数面；行格式契约在 parse_object_dump 中）。判据要求对象面断言有输出通道，沿用 dump-entries/dump-regassign/dump-table 的既有 test-channel 先例。dump 分支在 build_linear_schedule 之后、O2 职责门和发射之前返回，不触碰发射路径。

④ 重建段搬移纪律：build_linear_schedule 的函数体是原 load_ccr NOD 重建循环逐行搬移（grow_ir_instrs(instr_cnt 到 g_v7_nod_count)，6 个字段 iri_set_*，g_ir_instr_count 递增）。字段数值经 nod_* 访问器读取，buf_read_* 的符号扩展与 loader 原解析完全一致。REG 展开和函数边界回填（root span 到 g_ir_func_instr_start/count）留在 loader，由 GC-3 守卫消费，Task 0 已确认。

⑤ region_of_nod 不包含在内（Task 0 定夺）：对象面只包含节点、边、条目和 REG 行遍历，节头注记已经实施。

## 4. 挂账与风险

- 中立性静态 guard 属于 Task 4 范围。本任务在 ent_kernel 新增的面都是纯内核符号：g_v7_* 缓冲、nod_*/v7_edge_* 访问器、buf_read_*（ccr_io 内核文件），零实例符号。guard 在 Task 4 实施时不受本任务影响。
- 表模式（--table）路径不经过本任务的新面，load、schedule、hit_lower_program 照旧，hit_table 24/24 已实证。
- corec concat 包含新代码（load_ccr 改动和 ent_kernel 对象面），但 corec 永不调用 loader，compile 套件全部通过，实证零影响。
- Task 0 挂账的“删除 main.cr”如果将来执行，需要同步摘除 _import.cr 的 regalloc 导入和 main.cr 的接线注记，现有注记已经写明。

---

# 内核完备 Task 1 评审修复报告（I-1 / M-3 / M-1）

状态：完成
日期：2026-09-10
基线：035ea289（Task 1 提交）
提交：单提交 `fix: 内核完备 Task 1 补正，ld/main.cr 活入口注记重写（I-1）+ EDG 守卫常量化（M-3）+ 设计 第1.2 配方查询注记（M-1）`

## 修复清单

| 编号 | 文件 | 修复 |
|---|---|---|
| I-1 | `src/arch/linux/ld/main.cr:5-15` | 把“死代码遗留注记”重写为“活入口注记”：记录 stage 链的活性（main:152 到 corearch_main :23，到 load_ccr :56，到 build_linear_schedule :63），引用 `tests/selfhost/test_backend_bootstrap.py` 的 project mode（`corec build <目录>` 的入口是该目录的 main.cr，这是与 concat 清单并列的独立构建机制）和 Task 1 偏差 ①。删除“零 concat 引用”“实际入口 = corearch.cr”“删除挂账”等断言，替换为准确的入口二元性：corearch concat 入口是 src/compiler/corearch.cr，ld project-mode 入口是本文件，两条都是活路径，都已接线。旧注记误判的根因（只核对 concat 清单）留档，防止再次误导。合并或删除的前提条件（双入口接线加 _import.cr 导入集同步）也已记录 |
| I-1 | `docs/superpowers/plans/2026-09-10-corearch-kernel-completion.md` Task 0 盘点 ① 末条 | 原文“另一 load_ccr 调用方 = main.cr:56，死代码，改签名或搬移无须同步”整条划掉并驳斥，补注：证据是 Task 1 报告第 3 节偏差 ①（backend_bootstrap stage 链活入口，Task 1 已接线），改签名或搬移必须双入口同步 |
| M-3 | `src/compiler/ccr_io.cr:1367-1368` | EDG 守卫读取邻接域的偏移字面量 `ei4 * 16` / `ei4 * 16 + 8` 改为 `ei4 * ESZ_NOD_META` / `ei4 * ESZ_NOD_META + 8`。常量定义在 ent_kernel.cr:828 `ESZ_NOD_META : int = 16;`，与 NOD 写循环 :1247-1248 同源，同值防止变化；该常量已在本函数 :1226/:1247-1248 使用，作用域已实证 |
| M-1 | `docs/superpowers/specs/2026-09-10-corearch-kernel-completion-design.md` 第 1.2 节配方查询行 | 追加注记：实现方式是文档化的遍历模式（ent_kernel.cr:857-860 配方查询节注释，按 [first, first+count) 邻接区间逐边读 v7_edge_to/kind，访问器齐备后遍历即查询）。`nod_inputs` 函数封装未交付，符合计划规定（禁止新增接口抽象）；封装由消费方按需实现（YAGNI） |

## 覆盖验证命令与输出

```bash
$ nice -n 19 python3 build_selfhost_native.py     # ccr_io.cr/main.cr 改动 到 双 concat 二进制重建
=== BUILD SUCCESS ===
  build/corec    ，frontend:  .cr 到 .ccr/.cir
  build/corearch ，backend:   .ccr 到 binary
  build/corelsp  ，LSP server: frontend + json
# exit 0；corec/corearch 均 04:05 新产物

$ nice -n 19 python3 tests/selfhost/test_backend_bootstrap.py   # I-1 覆盖（stage 链含 ld-project 入口路径）
11 个 [PASS]，0 个 [FAIL]  到 11/11
（stage0 builds corearch stage1 / stage1 emits corearch stage2 / … 全链通过，ld/main.cr 活入口实证）

$ nice -n 19 python3 tests/selfhost/test_ccr_v7.py              # M-3 覆盖（loader 守卫）
24/24 passed
```

## 结论

- I-1 注记重写后做了自洽性检查，没有残留“死代码/删除”的活性断言。旧注记只以过去式留档，记录误导历史和根因。入口二元性和双入口同步义务记录完整。
- M-3 常量替换为同值（16），是纯等价改动。重建加 test_ccr_v7 24/24（含守卫负分支 9 个测试）证明零行为变化。
- 重建完成，两套覆盖套件全部通过。stage 链 byte-identical 判据随 test_backend_bootstrap 11/11 再次确认。
