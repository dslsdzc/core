# TODO

## 已完成

### P0 全量修复（2026-07-23, PR #16, RhineIris）
- **ELF struct/array/enum 寻址修复**：`emit_instr()` 的 disp32 写入补上当前指令基址 `pos`
- **变量数组索引修复**：修正 `IR_LOAD_INDEX_VAR`/`IR_STORE_INDEX_VAR` 的 REX/ModRM/SIB
- **corec2 自举阻塞解除**：corec2 --help、tokenizer/check 和 corec2→corec3 均正常
- **O1 自举稳定性**：corec→corec2→corec3 在 O0/O1 下均成功
- **原生回归测试**：struct、array、enum tag、O1 aggregate ELF

### 后端自举修复（2026-07-27）
- **corearch 自举贯通**：解除 Phase 3 的 `SIGFPE`/`SIGSEGV`，stage1 → stage2 → stage3 可连续发射且二进制逐字节一致
- **64 位编码修复**：后端不再使用会被 CCR i32 截断的 `2147483648`/`4294967296` 字面量，`w32`/`w64` 正确编码有符号值
- **CCR 有符号字段修复**：`buf_read_i32()` 显式符号扩展，避免 `-1` 被当作 `4294967295` 变量下标
- **CCR 大小修复**：变量条目按实际 12 字节计算，并纳入 v3 优化元数据大小，不再截断文件尾
- **优化元数据修复**：独立 64 字节槽位、capacity 和扩容复制，O2 寄存器分配 metadata 可序列化并由自举后端读取
- **后端回归测试**：新增三阶段自举、字节一致、O0/O2 CCR 和原生 ELF 运行验证

## 本阶段已完成（2026-07-28~29）

### Arena 内存模型（完整实现）
- `src/stdlib/arena.cr` — 完整生命周期：init/new/reset，动态元数据，free list，嵌套
- `src/compiler/ir_gen.cr` — 子图绑定：每个函数/loop/for/unsafe 自动 arena lifecycle + 大小预计算
- `src/arch/linux/ld/elf.cr` — ELF 后端双路径 alloc：arena 感知 + 全局 bump 回退
- `src/arch/linux/ld/instr.cr` — IR_ARENA_NEW(32)/IR_ARENA_RESET(33) 编码
- `src/runtime/rt.cr` — g_current_arena/g_heap_ptr/g_heap_end 全局注册
- `src/compiler/dataflow.cr` — df_use_var OOB 修复
- mmap 堆扩展：BSS 打满后自动 mmap 1GB 新区域
- emit_alloc_body 零初始化 + 链式扩容标记满

### @ 内建原语（12 个全部完整）
- `@sizeOf(T)` / `@alignOf(T)` — 编译期常量，ELF 验证 8 / 1 
- `@fields(T)` — 遍历 struct fields，返回逗号分隔名字符串
- `@hasField(T, name)` / `@field(T, name)` — 结构体字段存在性 + 偏移量
- `@typeInfo(T)` — 类型名称字符串
- `@comptime(expr)` — 透传 IR gen
- `@inline(fn)` — IR_INLINE(34)
- `@no_bounds_check` — IR_NO_BOUNDS_CHECK(35)
- `@fast` — IR_FAST(36)
- `@unroll(n)` — IR_UNROLL(37)
- `@section(name)` — IR_SECTION(38)

### 增量缓存（函数级 .cir，默认开启）
- `src/compiler/cir_cache.cr` — save/load 每函数 .cir 快照
- 管线集成：编译自动检查 .core/cache/cir/
- `clean-cache` 子命令
- 无感缓存，不需要 `--incremental` 标志

### @hotpatch 滚动更新
- `IR_HOTPATCH_ROUTE(39)` — 调用点路由指令
- Parser `@hotpatch(ver=N)` + checker 多版本签名校验
- ELF 后端编码 + `g_hp_config`/`g_hp_inflight` 全局变量
- 运行时 `hotpatch.cr` + rt.s SIGHUP 信号处理 + in_flight drain 追踪

### 自举构建与值语义修复（2026-07-30）
- **目录构建修复**：`_import.cr` 依赖可由自举编译器正确加载，具名/无名目录和缺失目录行为均有回归覆盖
- **增量缓存修复**：缓存指纹纳入完整解析源，导入文件变化不再复用过期 `.cir`；快照改为内存组包后单次写入，完整自举不再产生数百万次微小系统调用
- **调用返回值修复**：普通调用不再因局部 `dest` 遮蔽写入变量 0，并将实际返回类型传播到 IR
- **lazy 值传递修复**：ELF 后端和解释器中的 thunk/force 保留已计算值及其类型
- **原生字符串长度修复**：整数局部变量不再误判为指针，`str_len("hello") == 5` 和 `str_len(@fields(Point)) == 3`
- **Python bootstrap 词法修复**：`old` 不再被错误保留，可作为普通标识符
- **自举依赖补全**：bootstrap 构建纳入并发运行时依赖、共享 arena 全局和 fiber 声明

### 首次堆扩展与动态字符串修复（2026-08-14）
- **分配器状态保留**：`heap_expand` 在设置 `mmap` 参数前保存并恢复对齐分配跨度、原始请求长度和当前 arena ID，扩容重试不再重叠后续分配或写入 0 长度头
- **整数转字符串修复**：`int_str(7)` / `int_str(567)` 的内容和隐藏长度头稳定正确
- **字符串拼接修复**：`println("AB" + "CD")` 正常输出，不再因首次动态分配的长度头损坏而崩溃
- **float 舍入修复**：六位小数舍入支持连续 9 的进位传播，`1.9999996` / `9.9999996` / `-1.9999996` 正确输出 `2` / `10` / `-2`
- **CIR/DOT 输出堆耗尽修复**：`df_graph_to_dot()` 与 `cir_text_dump()` 改用 growable buffer，消除逐片段拼接造成的二次方临时分配；`corec cir` 不再在固定 1 GiB 堆耗尽后 SIGSEGV
- **CCR v5 格式回归修复**：测试 walker 按实际 28 字节 instruction 记录前进，SG 段布局检查恢复为有效断言
- **arena 回归确认**：`arena_test.cr` 的基本分配、嵌套和 free-list 复用均通过
- **完整自举确认**：`corec build src/compiler` 在 O0/O1 下均成功，三代后端输出逐字节一致

### 指针宽度、外部地址与动态边界修复（2026-08-16）
- **访问宽度传递**：`IR_DEREF` / `IR_STORE_PTR` 保留 pointee 宽度，静态验证改为 `offset + width <= allocation_size`
- **读写统一验证**：越界 store 不再绕过 ProvenanceVerify，静态可确定的越界读写均阻止编译
- **外部地址空间**：整数转指针标记 `asp=1`，safe 代码解引被拒绝，`unsafe` 边界内保留原有能力
- **动态边界根因修复**：ELF 检查从错误的页内偏移改为 `pointer - allocation_base`，合法变量索引不再误触发 `SIGILL`
- **保守多目标语义**：运行时偏移且 points-to 存在多个 allocation 时拒绝编译，不伪造已证明的边界
- **回归与自举**：15 个指针回归覆盖静态/动态读写、类型双关与 unsafe；`corec2` / `corec3` 逐字节一致

## Region 化控制流（2026-08-08 完成）

嵌套 region 已落地（HDFG 结构；规格 docs/superpowers/specs/2026-08-08-region-cfg-design.md——该规格中的"RVSDG 式"为当时路线记录，结构后定名 HDFG）：
- SG_IF + g_df_node_region 显式映射 + sg_pop close 语义修复
- 解释器 region 迭代（回跳经 SG 表）+ lexer float/`..` 修复（`0..4` 的 `..` 被 float 扫描吃掉——for 循环 bug 真根因）
- state edges（副作用链 + 循环终止依赖）+ .ccr v5（SG 段 24B + edge kind + v4 兼容）

### 已知缺口（region 化相关，待修）
- 缓存命中路径 SG 段不完整（已修复，2026-08-18：CIR v13 保存/恢复嵌套 region 与 node→region 映射；`test_nested_regions_cache_persist` 覆盖）
- while 循环无终止依赖（已修复，2026-08-18：while 使用 SG_LOOP、arena reset 与终止 state edge；`test_while_region_and_termination_edge` / `test_while_break_continue_run` 覆盖）
- 终止边源边界与链头推进（已修复，2026-08-08——final review Important #1：sg_pop 终止边源须在 region 内 + 链头推进到 exit 节点，test_termination_edge_source_guard 覆盖）
- 解释器内联 callee 循环不更新局部状态（已修复，2026-08-18：补齐 callee `ALLOC/STORE/LOAD`、arena 与立即 return 语义；`test_inline_callee_while_run` 覆盖）
- callee inline 执行中的循环崩溃（解释器限制，预存）

## 预存 Bug（不阻塞开发，待修复）

### 1. 并发集成：单 M 已端到端验证，多 M 未验证
-  `go f(args)` 端到端已通：`sched_go(@addr(f), arg)` → g_new 存 saved_fn/saved_arg → 静态构建由 ELF 后端内联发射 fiber_init/fiber_switch/goroutine_entry_wrapper（不再依赖 rt.s 链接）→ wrapper 调用 saved_fn(saved_arg) → 结果经 result_ch 回传
-  主线程注册为 G 0，可经 channel 阻塞/唤醒；sched_yield 不再重排 Gwaiting
-  M 线程 worker loop（m_start_workers）未连到调度器完整测试——静态构建尚未内联发射 m_start_workers（rt.s 符号）
-  channel wait queue 链表操作未在多线程并发下验证
- 注意：G 结构 offset 56 同时用作 saved_fn（goroutine.cr）与 temp_val（chan.cr 等待队列 handoff）——单 G 流程可用（wrapper 在 chan 操作前读取 saved_fn），但字段语义重叠，重构时需拆分

### 2. 解释器局限
- **for 循环**: label/branch 与 dataflow 顺序执行不兼容
- **递归/跨函数调用**: inline 执行不支持 IR_CALL
- **泛型函数**: bootstrap 解释器已支持（并补充递归/泛型算术回归）；self-hosted 解释器的泛型实例化运行仍待 native 工具链验证

### 3. 标准库补全
- math.cr / collections.cr 均为 stub
- 字符串操作、JSON 序列化待补（JSON-RPC 序列化已完成；动态字符串索引边界与字节读写已接入，通用字符串 API 仍待补）

### 4. 自举编译器巨型函数尾代码生成缺陷（elf.cr 回填循环，2026-09-09 v7 Task 1 激活发现——用户批准推迟，注册跟踪）
- **现象**：elf_gen 的 hit_rel 回填循环（×24）在巨型函数尾读**未初始化栈槽**（循环界比较值）——gdb 实证全函数零写点；v6 时代同源 dir 构建潜伏（陈旧栈值恰 0），v7 loader 帧轮廓改变陈旧值（fsize-4 残值）后激活（确定性 codegen → 非 v7 loader 回归——v7 Task 1 评审裁决：loader 与 g_hit_rel 状态零引用，28B 语义字段 verbatim，stage 链 byte-identical + hit_table 24/24 证明 loader 干净）
- **现状**：elf.cr:1450-1479 语义等价规避（回填界读取一次入局部变量 + 无条件重置保持）+ 代码内注记（诚实标注 = 规避非修复）
- **子系统假设**：ELF 后端巨型函数尾的栈槽分配/寄存器分配（循环界变量被分配到一个全程无写点的栈槽——疑似栈槽复用/分配器对巨函数尾的处理）
- **repro**：还原 elf.cr 重构（注记处）→ `python3 build_selfhost_native.py` dir 构建 stage1 → 确定性 segv
- **gdb 证据**：v7 Task 1 报告（.superpowers/sdd/v7-task-1-report.md Concern 1）+ elf.cr 注记
- **修复方向**：编译器层专项（独立于 v7 链——仓促同修危及 byte-identical 判据）；修复后还原规避代码验证

### 5. cir cache 跨编译器重建不失效（2026-09-10 内核抽取 Task 3 评审确认——预存,**已修 2026-09-11**）
- **✅ 已修（2026-09-11，提交 `3be4cb48`；工作区报告 `.superpowers/sdd/fix-cache5-report.md`）**：
  根因 = 条目身份**只有目标源**（键 = 源路径::函数名；头部指纹 `func_fingerprint`/`sig_fingerprint` 只覆盖目标 AST）⇒ 同源重建后字符串驻留序（`g_strs` intern 序）漂移不反映到键/指纹上，旧条目被命中、快照内旧序索引（var `irv_name` / instr `s1..s3`）被当活产物恢复（rc=0 静默）。
  **RED（pre-fix 二进制 sha256 `f0f00d7d…`）**：①载荷毒化（alpha 条目内 `var[0]/var[2]` 的 `name_ni` 互换 =「另一编译器写下的索引序」）后重跑——条目原样未被重写（命中）且 dump 错位（`binary 24 = a + b` → `24 = 20 + b`、`dest=22` → `dest=a`，rc=0）⇒ 装载路径对「索引序是否属于本编译器」零判据；②跨二进制 A/B（bootstrap 建的 `build/corec` vs 自举建的 `corec2`）实测 B 直接沿用 A 条目（无重写）。
  修复 = 头部新增**编译器身份**字段（`CIR_CACHE_VER 16→17`，布局 magic/ver/**identity**/fp/sig/name_len/name…）：`cir_compiler_identity()` = **运行中编译器自身 ELF 的内容哈希**（`/proc/self/exe` 全文件单趟 FNV-1 64 乘加：8B 字 + 余尾 + 总长；memoized），save 写入 / load 比对，不等即 miss；身份取不到（无 procfs/读取失败）= 两端点均关缓存（**绝不落「身份 0」条目**——那正是本静默类在退化路径复活；`unshare -rm` + tmpfs 掩掉 /proc 实测 rc=0 且零条目落盘）。
  选型（推翻本条原「构建期源哈希常量」方向）：运行中二进制自哈希捕获**全部**决定编译器语义的输入（`src/compiler` 清单+顺序 + bootstrap Python 工具链 + rt.s + as/ld），构建期源哈希只是其中一部分的代理——漏 bootstrap/工具链即本类复活；且无需构建管道改动/生成文件（tests 直编 `src/compiler`、full-bootstrap 的 corec2/corec3 不因缺生成文件而断）。前提 = 本仓构建逐字节确定（两连建 cmp IDENTICAL，修复前后两侧均实测）⇒ 同源重建身份不变、命中面不退化；若构建转为非确定，症状 = 缓存恒 miss（性能面，由该判据暴露）。与 `CIR_CACHE_VER` 分工：VER = 手工粗粒度（格式/行为代），身份 = 自动细粒度（编译器内容驱动）——行为变更不再需要「记得 bump」。
  成本（实测，热身缓存，1.32MB 二进制）：逐字节形 +11.6ms/次（小件编译 17→29ms）→ 8 字节字粒度 min 基准 +2~3ms/次；只在真正走到缓存的进程付一次（strace：全量热身编译 1 次 `open("/proc/self/exe")`）。
  回归 = `tests/selfhost/test_cache_identity.py`（5/5：身份语义 = FNV-1(ELF) 且 ver=17 · 同身份仍命中[改「被装载跳过」的函数名字节 canary] · 异身份拒[身份+载荷毒化 → 条目被改写回当前身份] · 差分「条目缺失 ≡ 条目毒化」（dump + 重建条目逐字节同）· 跨二进制 A/B[副本+1 字节模拟重建：canary 被抹 + 身份改写为 B]）+ `src/ci/run.sh` selfhost-tests 挂钩；RED 对照 = 同一测试对 pre-fix 二进制 1/5（仅命中控制过）。
  判据 = 两连建 `build/corec` 逐字节 IDENTICAL（sha256 `699b360a…`）· selftest-types 95/95 · test_compile/test_purity PASS · test_ccr_v7 27/27 · clean-cache 后 ptr_arith ELF `95084e7b…d475` IDENTICAL · suite 21 pass/0 fail · params_limit 5/5 · tuple_slots 14/14 · nested_fn 17/17 · region_cfg 22/22 · impl 7/7 · borrow 7/7 · pointer_safety PASS · interp_parity 23/23。
  **未修（本单外，第二实例照旧）**：`.ccr` 冷/热缓存态分歧（`at_test_struct.cr`：cold `891377232b5b` ≠ warm `8dbb12f740d8`，第三次起稳定）本修复**不影响**（pre/post 三连跑同哈希）——根因 = 缓存命中路径不复现冷路径的字符串驻留/渲染状态（与编译器身份正交）⇒ 比较 `.ccr` 前仍须 `clean-cache`。另：`CORE_SAFE` 环境旗标与 `-O` 级别经核**不触及**缓存面（安全/优化 pass 均在缓存相之后，`main.cr:551/566/583`）。
- **现象**：`.core/cache/cir` 以「源路径::函数名」为键缓存每函数 CIR 快照；缓存命中时旧条目跨编译器重建存活 → 复用的 CIR 与新版字符串表（g_strs 驻留序）错位 → dump 通道（如 corearch --dump-entries）输出部分变量名缺失/错位——实证：806→381 个 `name=` 的翻转（Task 3 验证中复现，同源重建即触发，与具体代码改动无关）
- **机制**：指纹 = magic/格式版本/完整解析源 AST，无编译器身份分量；源未变则键/指纹不变 → 二进制重建后字符串驻留序漂移不反映到键上 → 陈旧条目静默污染 dump-channel var 名输出
- **证据**：内核抽取 Task 3 评审 concern ①（.superpowers/sdd/kernel-task-3-report.md）——Task 3 diff 仅 corearch + 注释，base↔head corec cmp 相同；清 .core/cache 后逐字节复现判据成立（计划 Global Constraints 的「清 cache 跑测试」即为规避）
- **修复方向**：cir_cache.cr 缓存键 += 编译器指纹（产物内容哈希或编译器身份分量）——重建后旧条目自动失效；现状兜底 = CIR_CACHE_VER 手工 bump + 测试前清 cache
- **同族第二实例（2026-09-11 R2 P2a Task 4 收官登记）：`.ccr` 输出与 cir 缓存态相关——同一二进制二次运行产出不同 `.ccr` 字节**。实证（Task 1 评审首测 + Task 4 亲测复现，`tests/suite/at_test_struct.cr`）：`clean-cache` 后首次 `corec ccr` → sha256 `53ebcf12…`；**同二进制紧接二次运行**（缓存已被首次填热）→ `5054e26d…`（三次运行起稳定于该值）。冷缓存下 pre/post 两态行为一致，故**判据比较 `.ccr` 前必须 `clean-cache`**（已并入 R2 P2a 计划 Global Constraints 精神与各任务采样方法）；本条与上条同源（缓存键缺编译器/环境身份分量），非独立缺陷。

### 6. 双入口能力分歧：ld project-mode 后端缺 HIT/表旗标（2026-09-10 ld 导入集修复评审确认——预存,待修）
- **现象**：`src/arch/linux/ld/main.cr` 的 corearch_main 只注册 **6** 个旗标（elf/shared/static/link/output/opt-level，:31-36；评审修正——原文计数 7 误），而 `src/compiler/corearch.cr` 的 corearch_main 同段注册其全部超集（:260-273）：`--table` / `--hit-events-file` / `--dump-events` / `--dump-table` 与全族 `--dump-entries`/`--dump-coexist`/`--dump-regassign`/`--check-regalloc`/`--inject-*`/`--dump-objects` 调试通道。ld/main.cr 全文零处引用 `table`/`instance_decl_init`/`instance_select`/`g_active_instance`/`g_hit_table`——即 ld project-mode 构建出的后端（`corec build src/arch/linux/ld`，test_backend_bootstrap 的 stage1/2/3 即此产物）**HIT lowering 层与表编码器已编译在内但惰性**（评审修正——原文「整体不含 HIT/表机制」过度表述；精确缺面 = CLI/分派接线：旗标注册 + 实例声明引导 + 表装载），`:15`「两入口行为同构」括注对表模式为假。
- **实证**：`./build/corearch --dump-table` → 正常解析（打印 usage）；ld project-mode 产物 `--dump-table` / `--table` → `unknown flag: --dump-table` / `unknown flag: --table`（cli_parse 拒绝，非 usage 兜底）。故 `src/arch/linux/ld/main.cr` 头注「入口二元性…两入口…（现 load 后行为同构）」（:11-15）对表模式（及全部调试通道）**为假**——同构仅限 ELF 发射主路径。
- **机制**：入口二元性（concat 入口 = src/compiler/corearch.cr wrapper；project-mode 入口 = ld/main.cr）靠人工双份维护 corearch_main——旗标注册与 load 后接线分散两处，无共享注册函数、无一致性守卫；《内核完备》抽取后 src/compiler/corearch.cr 单侧长表模式（M2 系列），ld/main.cr 未同步。
- **影响**：ld 自举 stage 链（及任何经 ld 工程构建的后端）无法经 --table 走表投影路径——表模式回归只在 concat corearch 面被覆盖；`--hit-events-file` 注入测试通道对 ld 产物同样缺席。当前无测试经此入口断言表模式，故静默。
- **证据**：本次 ld 导入集修复（N06/N01 静默未定义闭合）评审 trace —— .superpowers/sdd/lattice-move-report.md 与本文 #6 挂账；同类先例 = c138c44c（init 单元缺 import → 静默未定义 + SIGSEGV，N06 类静默失败反复出现于「入口/单元维护面不同步」）。
- **修复方向**：①旗标注册收敛——两入口共调一个 `register_backend_flags()`（或 ld/main.cr 直接复用 corearch.cr 的注册段），保留双 wrapper 前提下的单份真源；②或显式 documented divergence 留档——ld/main.cr 头注改为「表模式/调试通道仅 concat 入口支持」并加守卫（如 ld 产物遇 --table 报明确「此入口不支持表模式」而非 unknown flag）。①优先（同构主张才是原本设计意图）。**③静默未定义类守卫（2026-09-10 修复评审残留建议）**：project-mode 构建（`corec build src/arch/linux/ld` 等单元）的 `error[` 计数无任何自动断言——N06 类静默失败在 rc=0 + 产物正常 + 全部互测 byte-identical 的情况下完全不可见（pre-fix 状态即如此通过全套）；建议加「build log error 计数非零 = 失败」的构建/测试门（或 tools/diagnose.py 类收集纳入套件）。**已部分落地（波 1 Task 1 修复 c927525b）**：`test_backend_bootstrap.py` run_checked 加 `error[` 门（project-mode 事发层封闭）+ 构建脚本 bootstrap 面门；**残留 rc-only 面（评审清点）**：`test_mw_task2.py:172`、`test_compile.py:127`、`test_live_ranges.py:52,73`（文件模式）+ `test_directory_build.py:50,80,100`（project-mode）——同类门可同法接入；执行力边界注记 = test_backend_bootstrap 未被 CI job 调用（门仅手动/计划判据路径生效，`corec check <dir>` 面 rc=1 非静默已核）。
- **注意**：修①会改 ld project-mode 单元内容 → stage 链产物字节变（expected，非缺陷）；须同步跑 test_backend_bootstrap 判据（stage1==stage2==stage3 全程同源，仍成立）。
- **波 1 注记（2026-09-10 x86 实例化波 1 Task 1 搬迁 + Task 7 收官同步）**：双入口之一已随三轴搬迁移入组合根——`src/arch/linux/ld/main.cr` → **`src/targets/x86_64-linux/main.cr`**（本条目正文路径 = 搬迁前快照，语义未变）；即 **波 1 已搬、未收敛**：旗标注册分歧（本条目现象/机制段）逐字保持，`test_backend_bootstrap` stage 链仍走该入口，收敛留波 2（H7 纪律——波 1 只同步注记措辞、不动 flag 面）。正文头注文件位置同步：`src/targets/x86_64-linux/main.cr:12-16`（入口二元性注记）。

### 7. 死文件 `src/compiler/elf.cr`（566 行，零 importer，不入任何清单）——符号遮蔽/归属误导（2026-09-10 x86 实例化波 1 Task 1 评审登记）
- **现象**：`src/compiler/elf.cr` 无任何 importer、不入任何 concat 清单（build_selfhost_native.py / Core.toml / _import.cr 三面皆无），但以**同名符号**与活文件碰撞。**定义级碰撞集（评审修正——原 13 名清单夸大）**：`w8/w32/w64`（= src/compiler/dyn_arr.cr 字节写函数）、`w16`（= src/format/elf/elf.cr:741，非 dyn_arr）、`align_up`（活 elf.cr:745）、`g_asm_code_size`（活 elf.cr:748）；另死文件对 `g_label_poses/g_label_count`（定义于 src/compiler/globals.cr:113-114）有写点。原列其余 11 名（elf_write_code/elf_begin/elf_finish/parse_line/encode_instr/measure_instr/asm_to_bytes/skip_dir/is_label_line/ElfCtx/LineInfo）在活树任何文件中均不存在——遮蔽危害结论不变，碰撞面以本表为准。
- **第二实例（活文件双源——2026-09-10 波 1 Task 2 评审登记）**：同名**双活**文件——`src/compiler/entry.cr`（corec 闭包 shim，属 corec concat）vs `src/os/linux/entry.cr`（OS 轴 _start 启动，波 1 Task 2 迁入）。组合根 `import entry` 命中靠回退链槽序（os/linux 槽 6 先于 compiler 槽 7——评审加载迹实证命中正确文件）；corec 单元侧 `g_source_dir = src/compiler/` 槽 1 自身目录命中 = 设计内。与死文件实例的差异：**两文件皆活** → 修复方向 = 结构性防护（改名一者或 import 独立 fileid），**非删除**；失败形态 = 链序重排即翻转（重复 `fn main` / undefined `compiler_main`——project-mode `error[` 门可捕，但该门未被 CI 调用，见 #6 ③ 执行力边界注记）。
- **机制/隐患**：`module.cr` 回退链序当前**恰好**保护它——三轴目录（`src/format/elf` 等）置于 `src/compiler/` **之前**（module.cr:544-553 注释明言：否则本文件遮蔽 `src/format/elf/elf.cr` → 目标单元解析漂移 → elf_gen 等 N06 静默未定义）。但这是**顺序依赖**而非结构保证：任何回退链重排或新增目录（波 1 Task 2-6 正在改 import 集与命中面）都可能翻转命中，而翻转后果 = `error[` 静默未定义类故障（先例见 #6 ③ / c138c44c）。
- **实证**：波 1 Task 1 评审（.superpowers/sdd/w1-task-1-report.md §2.1、§6.1）+ module.cr:548-553 注释推理；代码级引用 = 零（仅 plans 历史文档 `2026-08-08-pseudocode-tdd.md:400,413` 提及）；`tools/pseudocode_extract.py` ROOTS 含 `src/compiler` 整目录 glob，仍从该死文件抽取 ELF 写侧符号 → `docs/pseudocode/标识符对照表.md` **20 行**归属误导（且对照表整体未随波 1 重生成——212 行仍写已退役 `src/arch/linux/ld` 路径；重生成 = 修复方向二部分）。
- **修复方向**：**删除**（首选——零 importer、零功能贡献；删除需用户明确许可，铁律 #3）并重生成伪代码对照表；备选 = 迁出活树（`legacy/` 等，避开 ROOTS glob）保留历史。删除后复跑 test_backend_bootstrap + full-bootstrap guard（预期零影响、byte-identical）。

### 8. 前端 ≥18 形参静默误编译类（2026-09-10 x86 实例化波 1 Task 5 评审登记——高优先级：静默误编译）
- **✅ 已修（2026-09-11，提交 `d7ad71d314cb` + 缓存面 `68ffa1e8`；工作区报告 `.superpowers/sdd/fix-params18-report.md`）**：
  根因 = `FuncInfo.param_types` 是 **16 槽定长内嵌槽区**（`dyn_arr.cr` `OFF_FI_PARAM_TYPES=16` ⇒ `16+16×8=144=OFF_FI_RETURN_TYPE`），而 `parser.cr:1224` / `monomorph.cr:423` 写入无界——第 17 槽踩 `return_type`、**第 18 槽踩 `ast_node`**；形参类型值 `TY_INT=0` 恰把 `ast_node` 写成 AST 节点表首项（`rt.cr:4:13` 的 int 类型节点）⇒ checker 读 `fi_ast_node=0` 发 TF01 误归 + `.ccr` `name_idx=0`('import')/`param_count=0` + IR 体 46→28 instrs，而 `corec build` 仍 rc=0、产物 SIGSEGV 139（N=17 因 `TY_INT=0` **误打正着**；钳位最小实验单独证明因果）。
  修复 = 槽区扩至 `MAX_FN_PARAMS=64`（对齐 `ast.cr` 镜像 `[int;64]`；覆盖 ≥22 参 = 6 寄存器 + 16 栈参的 `>127B` 栈清理形，使该结构 runtime 可达）+ `fi_param_type`/`fi_set_param_type` **唯一读写点护栏**（未来新调用点结构性地不可能再越界写）+ 超限签名 `P020` 硬错 rc=1（绝不静默 rc=0）。
  回归 = `tests/selfhost/test_params_limit.py`（N=17/18 逐值 + 22/64 逐参校验 + 65 拒绝且无产物）+ `tests/suite/params_many.cr`（22 参 = `add rsp,0x80` 128B 栈清理形 runtime 覆盖——**Task 5 Minor 4 收口**）+ `src/ci/run.sh` 挂钩。
  缓存面 = `CIR_CACHE_VER 15→16`（修复前 ≥18 参函数的坏 IR 已被写入 `.cir` 快照；键不含编译器身份 ⇒ 同源指纹相同会命中旧快照复活坏产物——评审 Important，已收口）。
  **修复方向 ② 的阈值经重定**：字面「≥18 形参改硬错」与 ③（N=18 ok）+④（22 参 runtime rc=0）互斥 ⇒ 硬错定在 64（唯一自洽解）。
- **现象（评审修正——非单纯"丢名"）**：≥18 形参的函数在 .ccr 中 `name_idx=0`（解析为字符串表首项 'import'）且 `param_count=0`（N=17 正常：name_idx=3 'f' param_count=17）；同源 checker 另发 `error[TF01] Function return type mismatch` 并**误归到无关声明**（如 `g_rt_argc : int, mut;`）；`corec build` **仍 rc=0**，产物 SIGSEGV/错值（多行 18/20 参签名同样触发——参数计数依赖，非行长度依赖）。调用补丁随后失败 rel32=0 → rc=139。
- **复现**：m18 probe（task 5 报告 + 评审 /tmp 产物）——基线工具链同样复现 = 预存，非波 1 引入（波 1 四文件均不在 corec_files）。
- **影响**：a) 静默误编译类（rc=0 + 崩）；b) `>127B 栈清理形`（需 ≥16 栈参 = ≥22 形参）**无 runtime 覆盖可能**（结构不可达）——波 1 Task 5 的 7B add rsp 形仅字节级覆盖（评审确认 16×push + add rsp,0x80 逐字节同）。
- **修复方向**：①修参数表解析/AST bookkeeping（根源）；②≥18 形参签名改硬错 rc=1（防御面）；③回归探针 `N=17 ok / N=18 rejected-or-ok` 入 tests/；④缺陷修复后补 22 参调用 runtime 用例（`tests/suite`，断言 rc=0）——任务 5 Minor 4 的收口条件。
### 9. extern >6 int 参静默语义缺口（2026-09-10 波 1 Task 5 评审登记——callseq.cr:45 指针落地）
- **现象**：IR_CALL_EXTERN 仅装载 6 个寄存器参（不调用栈参/清理——与 IR_CALL 的不对称，预存原样保留于 callseq.cr）；>6 int 参 extern 调用 = 静默语义缺口。
- **取证/修复**：FFI 面（2026-07-30 FFI 计划未提及）；修复 = extern 栈参分派补齐或显式拒绝（rc=1）——波 2 FFI 面。

### 10. elf.cr 三处手写 syscall 序列 = OS 轴收编面（2026-09-10 波 1 Task 6 评审登记——波 2 / 实例 B 前必办）
- **现象**：`src/format/elf/elf.cr` 内三处 raw syscall 序列（**非内置体径**——内置体 syscall3/4 已归 src/os/linux/syscall.cr）：`emit_heap_expand` mmap（:442-468——6 参 rdi/rsi/rdx/r10/r8/r9，raw `w8(...)` 发射）、worker exit（:680——`mov eax,60` + syscall，**syscall1 形**）、clone（:710-724——`mov eax,56` + syscall，**syscall5 形**）。
- **为何登记而非报告注**：①在**格式轴**文件里——波 2 若只做"syscall3/4 参数化"扫不到它们；②**证伪实例 B 承诺**——设计 §1/§5"换轴零改动"要求非 Linux OS 轴下 Linux ABI 字节不得留在 `src/format/elf/`。
- **修复方向**：OS 轴 syscall 序面收编（搬运/参数化到 `src/os/linux/`——波 2 或实例 B 前置任务）；`elf.cr` 相关注已加交叉引用（Task 6 评审同批）。
- **关联**：波 1 Task 6 评审 Important（.superpowers/sdd/w1-task-6-report.md）；TODO #8 ④（22 参 runtime 用例）同属波 1 遗留收口。

### 11. 解释器 callee 内联路径缺 opcode（枚举 / 裸指针 / 切片 / 边界检查族）→ 双路径分叉（2026-09-10 R1 终审扩写——Important，本批 15 例未覆盖）
- **✅ 已修（2026-09-11，提交 `9068629c`（并入后 `c589c47b` 系）；报告 `.superpowers/sdd/fix-interp11-report.md`）**：
  改法 = **分派统一为单实现**（`ir_interp_call` / `ir_interp_run_fn`：callee 内联臂与主循环臂共用同一实现，不再两处各写一份）——比逐个补 opcode 更彻底；18 族按「同语义同守卫」补齐，另补 **嵌套/递归内联**（重入帧保存恢复 + 深度守卫 + 中止码沿调用链上抛，**绝不静默落 0**）。
  回归 = `tests/selfhost/test_interp_parity.py` **23/23**（interp callee ≡ interp main ≡ ELF oracle）；**RED 对照**（换回修复前 interp.cr 重建）= 4/23，TODO 原件 interp `0`/SIGSEGV(`-11`)/`0` vs ELF `33`/`33`/`7` → GREEN 全对齐。
  判据：selftest-types 95/95 · test_compile/test_purity PASS · test_ccr_v7 27/27 · **ELF 逐字节 `95084e7b…d475` IDENTICAL**。
  **余留**：① `IR_DYN_TAG`(41) 全仓无 ir_gen 发射点 = 当前不可达（内联侧为防御性对齐，建议另单）；② 深度守卫超限 interp rc=255+诊断 而 ELF SIGSEGV（**都非静默**，行为不同）；③ `IR_FNADDR=0`/`ARENA no-op` 为既存近似，判据只钉「双路径一致」不钉「与 ELF 等价」。
- **现象**：解释器（interp.cr）的 callee 内联分派相对主循环**缺 18 个 opcode**（终审实测清单：4/17/18/23/24/25/26/27/28/29/30/41/42/43/44/45/48/51）——Task 4 只补了聚合族（7/8/11-16/31），其余仍缺。
- **复现（终审亲跑）**：① 枚举：`build/review_t4/p14_enum_in_callee.cr` interp rc=0 vs ELF rc=33（interp 错值）；`build/review_t4/p15_enum_split.cr` interp rc=139（SIGSEGV）vs ELF rc=33。② 裸指针解引用：`g:[int;3]=[5,6,7]; fn f()->int{ p:=&g[2]; return *p; } fn main()->int{return f();}` → interp rc=0 vs ELF rc=7。ELF 侧均正确。
- **机制**：外函数内联路径缺 opcode 分派（主循环有、callee 路径无）；静默分叉类（rc 不反映）。
- **批前基线**：同两例批前 interp 亦 0/未处理、ELF 139 → **非本批回归**；但 R1「全局双路径一致」的留白比原 #11 标题（仅枚举族）更宽。
- **修复方向**：按 Task 4 §6.2 同款「与主循环同语义同守卫」逐族补齐（枚举 / 裸指针解引用 / 切片 / 边界检查 / DYN_PACK…），并加双路径用例入 tests/。

### 12. 类型别名仅一层解析（2026-09-10 R1 Task 4 评审发现——Minor）
- **现象**：`type A = [int;2]; type B = A; g : B;` 仍双路径 SIGSEGV（interp rc=139 / ELF rc=139；R1 Task 5 亲测复核）；一层别名（`g : A`）正常（对照 interp rc=7）。
- **机制**：`agg_elem_count_of` 只解析一层别名，嵌套别名至底元素类型/长度未回溯。
- **修复方向**：`agg_elem_count_of` 递归/迭代至底（并防环——自引用别名）。有初值形态工作、无初值形态崩，故非全断。

### 13. lexer 诊断前缀不一致 + 重复打印 + 边缘形态分歧（2026-09-10 R1 Task 3/5 评审与实测发现——诊断门零覆盖面）
- **① 前缀不一致（守卫/测试门零覆盖——重要）**：lexer 走 `add_error`（`src/compiler/lexer.cr:38-44`）输出 `error: <msg>`（**无错误码**），而 checker/其余走 `diag.cr:134` 的 `error[XX]`。既有守卫与测试门（`build_selfhost_native.py:171-185` guard_build_log、`test_backend_bootstrap.py:29-40` run_checked、test_global_init `has_diag`）一律扫 `error[`——对 **lexer 诊断零覆盖**（实测 `./build/corec run 'fn main()->int{return 0xZZ;}'` → `error: invalid digit in integer literal`，全无 `error[`，rc=1 非静默故未被吞，但门不可见）。建议统一格式或扩展守卫扫描面（`error:` 类同样计入门）。
- **② 重复打印 4 遍（Task 3 评审 Minor）**：同一条 lexer 诊断打印 4 次——多轮 tokenize 累积、`tokenize()` 不清零 `g_error_count`（既有行为，父版同款注释）。措辞层噪声，非正确性。
- **③ 边缘形态分歧（既有，超出 R1 判据集）**：`1._5`（self-hosted 响亮报错 vs bootstrap 词法层 INT(1)+DOT+IDENT(_5)——整管线下仍报错、**无静默接受**）；`1.`（既有分歧）；`0x_` 诊断措辞优先级变化（现报分隔符消息，原报 invalid integer literal——两者皆错误，仅措辞）。

### 14. bootstrap 后端：全局初值为非字面量（含一元负号）→ 静默降级为 0（2026-09-10 R2 P0 Task 1 实测确认）
- **现象**：`bootstrap/corec/frontend/ir_gen.py:68-74` 的 `constant_value` **只对 `Literal` 赋值**——`x : int = -1;`（一元负号）、`x : int = f();`（调用）等初值一律拿到 `.quad 0`（`bootstrap/corec/backend/x86_64_stack_asm.py:622-626` 的 `cv is None` 分支），解释器侧同源（`interpreter.py:35/81` 取 `constant_value`）→ **静默错值**（0 冒充初值）。
- **影响面**：仅 **bootstrap 构建路径**（Python 工具链产出物）；self-hosted 路径的同类缺陷已由 R1 Task 4（`71cb6278`：main 序言注入 + 解释器常量阶段）修复。当前自举链未触发（编译器自身无此类全局），属潜伏缺陷。
- **触发实证**：R2 P0 Task 1 的 `tt_top()` 惰性 memo 原计划用全局 `= -1` 作「未初始化」哨兵 → 实测返回项 0（= ⊥），被迫改零初值 + ready 位（`g_tt_top_ok`/`g_tt_nil_ok`）。
- **修复方向**：bootstrap `ir_gen.py` 的初值提取扩展到一元负号/常量折叠可判定形态（与 self-hosted 的 `global_init_val` 对齐），或对不可判定初值发诊断（**禁止静默 0**）；判据 = `tests/bootstrap/` 增用例（负号初值/调用初值 → 值正确或响亮报错）。

### 15. R2 P0 类型项引擎落地（2026-09-10——落点与未覆盖面登记，非缺陷）
- **落点**：`src/compiler/type_terms.cr`（类型项 DAG 表 48B/条 + 开放寻址索引 + 哈希去重 + NNF/DNF 规范化）、`src/compiler/type_engine.cr`（三态判定 `ty_sub`/`ty_equiv`/`ty_disjoint`/`ty_inhabited` + 反例 `tt_witness` + 穷尽性 `ty_exhaustive`（补集空性）；原子类互斥公理、μ 展开余归纳 memo、预算守卫）、`src/compiler/type_selftest.cr`（38 例用例表）+ CLI `corec selftest-types` + 判据 `tests/selfhost/test_type_engine.py`。spec = `docs/superpowers/specs/2026-09-10-type-interface-unification-design.md` §9 P0；计划 = `docs/superpowers/plans/2026-09-10-r2-p0-type-engine.md`。
- **P0 边界兑现**：checker/ir_gen/后端/内核零改动；产物 byte-identical（`ptr_arith.cr` 与 R1 基线逐字节相同）；自举 `corec2/corec3` `cmp` IDENTICAL。
- **未覆盖面（显式登记：命中返回 -1 或按守卫，**不静默**）**：① 参数化原子的参数仅同形判等（变型规则 = P3）；② `AK_NAMED` 具体行不展开（待 P2 接入 checker 类型表后可用）；③ 空递归（如 μX.X）按深度守卫 512 → -1；④ 判定预算默认 200000 步（**规范化亦计入**：∩ 分配律 2^n 爆炸在 n≈13-14 处截断），超限 → -1 + `g_ty_exhausted`；⑤ 命中①/②/`¬μ` 时置 `g_ty_uncovered = 1`（写入点在 `lit_implies` 与 `tt_nnf_neg`）并以 -1 上抛——**未覆盖面恒给「未知」，不给确定答案**；⑥ memo 重建（`ty_memo_rehash`）与「进行中」状态的交互**无实测覆盖**（现有规则下需单次证明内 >512 互异对才可达；读码核验成立，复审登记）。
- **三态约定（判据面）**：判定 API 返回 `1 = 成立 / 0 = 不成立 / -1 = 未知（预算耗尽或未覆盖）`；`tt_witness` 另用 `-2 = 未知` 与 `-1 = 不可满足` 严格区分（`ty_exhaustive` 对 -2 返回 -1，绝不当「穷尽」）。**预算耗尽的结果一律不缓存**（memo 每顶层查询清空）。

### 16. 函数体内嵌套 `fn` 声明 → 编译段错误 rc=139（2026-09-10 R2 P1 Task 2 评审确认——既有缺陷，非该批回归）
- **✅ 已修（2026-09-11，提交 `f417d3453a79`；报告 `.superpowers/sdd/fix-nestedfn16-report.md`）**：
  根因 = `parse_primary` **无 `T_FN` 分支** ⇒ 语句位遇嵌套 `fn` 落回通用兜底 → 解析**失步**；随后 struct 字面量字段循环在 EOF 处**自旋** → bump allocator 耗尽 → `grow_ast` 的 `rep movsb` 向 **NULL** 拷贝（gdb 实测 `rdi=0`、`rcx=0x12000000`＝288MB），日志止于 `[3/5] parse`（与 TODO 归属证据一致）。
  **结局判定（推翻 TODO 原文「判据 rc=0」前提）**：嵌套 `fn` **不属语言面**——`grammar/core.ebnf` 的 Statement 不含 FunctionDecl、bootstrap 对同输入报 SyntaxError、函数值设计为 YAGNI 挂起 ⇒ 正确结局 = **定位拒绝 `P021`（rc=1）**，而非 rc=0。依据已写入 `tests/selfhost/test_nested_fn.py` 文件头与 `run.sh` 注释。
  修复 = `P021` 定位拒绝 + `}`-键循环 6 处 EOF 护栏（防同类自旋）+ `run.sh` selfhost-tests 挂钩；回归 = `test_nested_fn.py` 17/17（含 4 例 EOF 失步探针，独立对拍父版均 rc=139）+ `tests/suite` 21 pass/0 fail。
  **余留**：① EOF 失步恢复期会重复打印无定位 parse error（有界 ≤64、毫秒级、rc=1；既有报告面，非本次引入）；② 若将来要「支持」嵌套函数，`P021` 即显式拦截点，需连 checker/ir_gen/后端一起做。
- **最小复现**：函数体内**嵌套 `fn` 声明**的 `.cr` 编译 rc=139（评审最小件 `/tmp/rv_nested.cr`）；**扁平版（同逻辑不嵌套）rc=0** → 触发点 = 嵌套 fn 声明本身。注意：原先被归因的 `tests/suite/at_test_mini4/6` 只是同族样例（**mini6 并无 `@inline`**，原报告措辞有误）。
- **归属证据**：编译日志止于 `[3/5] parse...`（该行打印于 `parse_all()` 之前），checker 的 `[4/5]` 未开始 → 崩点在 parse→checker 之间；**在 R2 P1 之前的编译器上同样复现**（两版均 139）→ 与影子层/类型引擎无关。
- **影响**：`tests/suite/` 中 2 个 fixture 长期 rc=139（P1 语料扫描标记 SKIP）。
- **修复方向**：嵌套 fn 的解析/注册路径（parser 的嵌套声明处理或 checker `collect_decls`）——先定位崩溃点（gdb/诊断输出），再修；判据 = 最小复现 rc=0 + 两个 fixture 恢复 + 全回归。
- **实现期实证教训（后续期通用）**：Core **无三元运算符** `?:`；取模须非负（i64 向零截断，负下标 → 越界静默失效）；键比较**不得依赖 i64 回绕**（bootstrap 解释器任意精度 → 回绕等式恒假）；字面矛盾规则须窄（正原子 × 异类负原子**不空**：`int ∩ ¬string = int`）；μ 展开必须走 memo 入口（余归纳终止）。

### 17. R2 P1 影子对拍落地（2026-09-11——落点 / 开关默认值与产物影响 / 裁决归属登记，非缺陷）
- **落点**：`src/compiler/ty_shadow.cr`（桥接 ti→类型项 + per-ti 缓存 + 8 站点挂点 + 分类计数 + 摘要/转储）、`src/compiler/checker.cr`（`type_equal` → `type_equal_core` 包装 + 8 站点 `sh_site_begin`）、`src/compiler/type_selftest.cr`（桥接用例）、`src/compiler/globals.cr`（`g_shadow_*` 组）、`src/compiler/main.cr`（CLI 旗标）。清单三处注册：corec + **corelsp**（Task 2 起 checker 引用影子层）+ test_compile。清单 = `docs/superpowers/specs/2026-09-10-type-shadow-findings.md`；计划 = `plans/2026-09-10-r2-p1-shadow-parity.md`；提交链 `e4c293b2`（桥接）→`844cec6c`+`514956a1`（挂点/补强）→`75c20297`（Step 0 拆因 + 语料清单）。
- **开关默认值与产物影响（登记）**：`--type-shadow`（**默认关**，纯观察通道；`--type-shadow-dump <file>` 另给差异转储）。两态产物**逐字节相同**（`ptr_arith.cr` 开/关/基线三份 sha256 全等 `95084e7b…d475`；`check` 路径 stdout 仅开态追加以 `[type-shadow]`/`[type-shadow-sites]` 起头的两行）。影子预算/memo 每次判定前后各 `ty_budget_reset` → 不污染 checker 判定；关态 `sh_site_begin` 首行早退（Task 4 M3）→ 关态残留开销 = 每次判定一次全局读。**结论：开关可安全长期保留默认关，无产物影响。**
- **差异清单裁决归属（登记）**：findings 的 F1（P2 硬前置）/F2（P2 裁决）/F3/F4（checker 缺陷面，单开任务）与「按差异清单替换旧判定」的**替换门**全部归 **P2**；P2 验收不得只看「差异数 = 0」，须同时报告站点覆盖（P1 实测 4/8 站点零命中）。下 #18-#21 为逐条登记。
- **站点 6 去留裁决（终审 M-1 交接项）**：站点 6（`assign-binary`，`EXPR_BINARY + OP_ASSIGN` 遗留路径——parser 已把 `=` 一律降为 `EXPR_ASSIGN`，`parser.cr:222-224`，故**不可达、无样本**）**保留挂点，去留归 P2 裁决**——零成本且留证据面（若 parser 未来恢复 `=` 的二元形态，挂点自动生效）；**不删**（删须同步 findings §8 与 `ty_shadow.cr` 站点表，属 P2 的站点面清理一并办）。

### 18. ~~F1（P2 硬前置）：同名 named 类型占多行未规范化 → 引擎按行建原子 → 判不了~~（2026-09-11 R2 P2a Task 1 **已修**：建表去重——唯一分配点收敛 `alloc_named_type` + 开放寻址侧表（装填守卫/重建重放/回写重探，照 `sh_map_*` 先例），8 个生产分配点全改调；12 个读取点读**名字**故语义不变。落点 `src/compiler/checker.cr`（+`globals.cr`/`type_selftest.cr`），提交 `3c8402e8`（评审 3 Minor 收口 `8c9d773f` 纯注释）；判据 = `selftest-types`（f1.* 四例 + 扩容重建例）+ 侧表↔`res_type_node` 管线内断言（`tests/selfhost/test_named_dedup.py`，正控 mismatches=0 / 负控注入 6、rc=1）+ P1 9 条 unknown **清零** + ELF 逐字节同）
- **现象**：`type_equal_core` 的 `TYP_NAMED` 按 **name_idx** 判等（同名恒等价）；类型表同一名字可占**多行**（`MemLayout` 2 行 / `Box` 5 行——`res_call_type` 在符号不可见处 `alloc_type(TYP_NAMED,...)` 新建行、泛型实例化另建行），而桥接按**行号**建原子 `tt_atom(AK_NAMED, ti, -1)` → 两个不同原子 → 引擎 `AK_NAMED` 不展开 → **-1（未判定）**。
- **实证**：P1 三档语料 26,704 判定中 9 条差异（去重 3 类型对）**全部**由此产生（`old_looser=0`、`old_stricter=0`；差异 = 「旧能判、引擎判不了」）；根因探针 = findings §4.2 + §6.F1。
- **影响（为何是硬前置）**：替换后主流「同类型比较」会从**真**变**未判定**；若 P2 把未知当拒绝 → 大面积假拒，当通过 → 静默失去命名类型检查。二者皆不可接受。
- **修复方向**：二选一并裁决——① 引擎侧引入 named 身份规范化（同名 → 同一原子，需 name 注册表）；② 桥接把同名行折叠到同一项（须先裁决「同名是否恒等价」，会掩盖跨声明域同名）。**P2 第一项，且须补同名多行的守门用例**（findings 探针 B/F/G/K 可升格为回归）。

### 19. ~~F2（P2 裁决）：数组长度 `N` 旧判定比、引擎不比 → 替换即放宽~~（2026-09-11 R2 P2a Task 2 **已裁决并实施**：用户裁决 = 落「常量档长度约束」保持现状拒绝语义——`array_len_constraint_ok` 沿结构对应位下钻比 N（数组元素/指针元素/引用元素/切片元素/元组字段/泛型应用实参 6 位），身份分支去 N，判定点 `type_compat_strict` 显式补检（`-1` = 长度违反 → 专属措辞，码不变）；判定点**恒先调 `type_equal`** 保影子站点采样面。落点 `src/compiler/checker.cr`，提交 `b36d8e76`（评审 M1「同形」限定 `507daf7a` 纯注释）；判据 = `selftest-types` f2.* 8 例（**Task 4 补至 10 例**：+REF/SLICE 下钻位）+ 异长拒绝行为探针 + 全语料 `old_stricter=0`（探针 D/G 的 F2 面消除）；**P3 面遗留**：符号档/动态档长度约束未实现（本批按字面量比较 extras，异形不下钻））——**✅ 2026-09-12 收口（P3a Task 1；#34）**：动态档 = 既有运行期检查（`g_ir_slice_lens` 侧表 + `IR_BOUNDS_CHECK`，R1 已落）+ checker 字面量界检查；**符号档 = VC 义务，显式登记不实现**；N 读取面守门 = 「N 只许被常量档检查与表示层读（`arr_len_lit_of`/`type_size`/`type_align`），身份/子类型路径零 N」已由 `t1.n_face_gate*` 用例钉住（含嵌套固定性「b 盲」比较修复）
- **现象**：`type_equal_core` 的 `TYP_ARRAY` 分支比较 `extra`（= N）；桥接按 R1 裁决**不把 N 入身份**（`AK_SEQUENCE` 参数链只含元素项）→ 替换后 `[int;3]` vs `[int;4]` **静默通过**（当前是 `error[TF01]`）。
- **实证**：探针 D（`[int;4]` 返回给 `[int;3]`）与探针 G（泛型实参位）均 `old_stricter=1`；本轮语料 0 触发。
- **修复方向**：R1 的「N 不入身份」是 **IR 侧**身份裁决；**checker 侧是否保留 N 检查需单独裁决**——保留 → 需在引擎/桥接把 N 作为维度/字面量入判定；不保留 → 记为有意的语言放宽并写进 spec。裁决后同步 `bridge.len_not_identity` 用例语义。

### 20. F3：调用位点实参类型不匹配**无诊断**（`unify_types` 返回值被丢弃，`checker.cr:1053`）
- **现象**：`infer_gen_call` 调 `unify_types(pattern_ti, concrete_ti);`（`src/compiler/checker.cr:1053`）**丢弃返回值**；非泛型调用位点同样不报。
- **实证**：`fn take2(n: int)->int` 以 `take2("s")` 调用 → 输出 `ok`（无诊断）；`fn take[T](a: T, n: str)` 以 `take(1, 2)` 调用 → `ok`（探针 J/C，源在 `/tmp/r2p1t3/probes/`）。
- **与影子的关系**：影子只对账 `type_equal` 的 verdict（此例两侧皆「拒」= agree），**不负责诊断**；但 P2 若以引擎判定作为诊断来源，必须补「判定 → 诊断」这一环（含 `unknown` 的处置策略：拒绝 / 降级警告 / 放行，需与「语义保鲜」目标一致）。
- **修复方向**：单开任务（属 checker 缺陷面，非影子层）。

### 21. ~~F4：泛型函数**后续形参**的声明类型在推断中不生效~~（2026-09-11 R2 P3 Task 5 **已修**：根因 = `infer_gen_call` 的形参链导航 `pn = pn + 1` 假设 EXPR_PARAM 在节点表**连续**——实际每个形参的**类型节点**都在其形参节点之前分配（`parse_type` 对**每个**类型都占一节点，含基类型）⇒ 第 i+1 个形参落在类型节点上，`ast_data(该节点)` 对基类型节点 = 0 ⇒ `res_call_type(0)` 读**AST 节点 0**（本文件首个类型节点）⇒ 后续形参的声明类型被绕过、且未绑定形参被凭空绑定（节点 0 恰是某泛型形参 ident 时绑到它）。修法 = 前扫到下一个 EXPR_PARAM（照 `ir_gen.cr` 三处同款：dex 参数对齐 :1481-1487 / 参数建 var :2279-2285 / mono 克隆 :2715），扫到表尾置 -1。判据 = selftest `t5.f4_later_param_declared_type`（手工夹具复刻不连续布局 + 节点 0 = 另一泛型形参 ident，正/负控）+ `t5.f4_bind_seg_recorded` + 行为 `tests/selfhost/test_generic_constr.py::f4_later_param_binds_correctly`（旧态假拒 TF01 → 新态 rc=0，**放宽 1 条**见 #33）+ 突变控制 M1（退回旧导航 → 两处同时红）。落点 `src/compiler/checker.cr` 的 `infer_gen_call`。）
- **现象**：`fn take[T](a: T, n: int)` 以 `take(1, "s")` 调用时，`unify_types` 收到的 pattern 是 **`gparam(T)`** 而非 `int`（探针副本 `[dbg-unify]` 实测）；`fn take[T](a: T, n: str)` 以 `take(1, 2)` 调用同样收到 `gparam(T)`。而**首个形参为具体类型**时正常（探针 K：`fn take[T](n: int, a: T)` → pattern = `base(int)`，正确进站点 4）。
- **影响**：泛型函数的非泛型形参类型约束在调用推断中被绕过（与 #20 叠加 → 完全无诊断）。
- **修复方向**：单开任务定位 `ast_data(pn)` / 形参链导航（`infer_gen_call`，`checker.cr:1030-1060`）。

### 33. R2 P3 Task 5 落地（2026-09-11——泛型约束：保留 / 实例化判定 / monomorph 实例键类型项化；**半 P3a 交付 + P3b 阻塞登记**，含未覆盖面）
- **落点**：`src/compiler/parser.cr`（结构/枚举泛型约束**不再丢**：`save_struct_gen_constrs`/`save_enum_gen_constrs`——**空槽预填 -1**，见 §缺陷①；F4 无关）、`src/compiler/globals.cr`（`g_sgen_constr`/`g_egen_constr` 两张稀疏侧表 + `g_gen_binds` 调用点绑定段 + `g_constr_seen` 诊断去重表）、`src/compiler/dyn_arr.cr`（增长函数 + `si_gen_constr`/`ei_gen_constr` 读取护栏）、`src/compiler/checker.cr`（F4 形参链修复；`gen_constr_type_ti`/`gen_constr_satisfied`/`gen_constr_witness_str`/`gen_constr_raise`/`gen_inst_constr_check` + 去重表；`infer_gen_call` 的**本质轴**判定 + 调用点绑定登记；`res_type_node`/`res_call_type` 的**实例化点**检查）、`src/compiler/ty_shadow.cr`（`tt_display` 反例文本化——**零 str_intern**，守 `.ccr` STR 段约束）、`src/compiler/monomorph.cr`（`inst_key_of_ti` 规范结构名 / `inst_type_node_of_ti` 类型节点合成 / `gen_subst_ti` + `inst_ti_concrete` / `gen_remap_binds` 克隆期绑定重映射 / `gen_find_or_create_bind`）、`src/compiler/ir_gen.cr`（泛型调用点优先用 checker 绑定段建键）、`src/compiler/type_selftest.cr`（**279 → 288 例**，t5.* 9 例）、`tests/selfhost/test_generic_constr.py`（新建 **14 例**）、`src/ci/run.sh`（selfhost-tests 挂新套件 + 计数同步）、**`build_selfhost_native.py`**（`monomorph.cr` 自 `backend_support_files` 迁入 `corec_files`——见 §登记③）。
- **落地语义（P3a 半边）**：① 结构/枚举泛型约束保留 + **实例化点**判定；② 实例化判定 = `ty_sub(实参项, 约束项)`（**本质轴**：约束名 = 原生/已声明类型）三态，违反 = `error[TG02]`（**软诊断**，未新开硬门）+ **非空反例文本**；③ monomorph 实例键 = 类型行**规范结构名**（`inst_key_of_ti`），替换 = **ti 型节点合成**（取代名字文本替换）；④ F4（#21）。
- **P3b 阻塞面（本批显式不判，**不得**当「不满足」）**：`T: I`（I = `interface` 名）的**满足判定**须走 P2b 注册表 `iface_satisfies`（未交付，P3 计划附录 A.3-①）⇒ ① 结构/枚举实例化点对接口约束 = **-1 零动作**（`tests/selfhost/test_generic_constr.py::struct_iface_constr_unjudged` 钉住）；② 函数调用点**回落**既有 `check_iface` 名拼接路径（逐字未动，`iface_constr_legacy_*` 两例）。
- **缺陷①（本批修复）**：稀疏侧表的**零初值 = 合法名字 ni**（首个驻留串）⇒ 未写过的槽被读成 0 = 有效约束名（凭空约束）——修法 = save 函数整行（MAX_GENERICS 槽）预填 -1；selftest `t5.constr_side_table_readback` 钉（突变 M4 咬合）。
- **登记②（MAX_GENERICS = 4，**未解除**）**：>4 泛型形参现状 = parse 期硬报（实测 `P01`/`TA08`，**非静默截断**）；解除需改 struct/enum 表布局（`OFF_SI/OFF_EI_GENERIC_NAMES` 各 4 槽 + `ESZ_*` 变更）+ `parse_generics_into` 的 4 槽常量 + `ccr_io` 零写槽 ⇒ 归单开批；触发条件 = 语料出现 >4 形参（当前最大 = 2：`tests/suite/generics_test.cr` 的 `pair[A,B]`）。
- **未覆盖面（显式登记）**：命名类型实参 vs 原生约束 = **-1 不判**（引擎 AK_NAMED 不展开 ⇒ `struct Box[T: int]` + `Box[S]` 静默，行为例 `struct_inst_named_arg_unjudged`）；`never` **不**满足原生约束（引擎 AK_NEVER 是与 AK_INT 互斥的**原子**而非 ⊥——既有语义，本批如实钉住）；约束名既非类型也非接口 ⇒ 不判（**拼写错误的约束名静默**，`unknown_constr_name_unjudged`）；复合实参（元组/嵌套应用）无语法形态 ⇒ 键走行号兜底 + 替换回落名字路径；ti 型替换**不覆盖实例形参**（`EXPR_FN` 分支不克隆形参——形参类型由 `fi_param_type` 裸码承担）；`inst_key_of_ti` 对未知 kind 用行号兜底（同编译期内确定，跨行同型不去重）。
- **登记③（清单变更）**：`monomorph.cr` 自 corearch 的 `backend_support_files` 迁出——corearch 侧对它**零代码引用**（逐符号脚本核对：全部定义符只出现在 `globals.cr` 的注释里），而本批的类型项化需 checker/parser 层符号（`get_type_kind`/`alloc_node`，corearch 清单无此层）；安全面 = ELF canary 逐字节同 + 全套回归 + `corec2==corec3`。
- **死码登记**：`ir_gen.cr` 的 `find_or_create_mono_func` **零调用者**（全仓 grep 实测）；其读调用节点 `int_val` 的**旧语义**（= 首个绑定类型名）已被本批改写为「绑定段起始 + 1」——若将来自复活，必须先改该函数（否则错读绑定段下标）。
- **判据（Task 5）**：`selftest-types` **288/288**；`test_generic_constr.py` **14/14**；`test_iface_ops` 76/76 · `test_match_exhaust` 16/16 · `test_optional` 12/12 · `test_impl` 7/7 · `test_ccr_v7` 27/27；ELF canary `95084e7b…d475` **IDENTICAL**；`.ccr`：`ptr_arith` 逐字节同、`generics_test` **+370B**（唯一差异 = `get_val[unit]` → `get_val[int]` + `get_val[string]`，即**反折叠**；逐段 STR+10/SYM+56/NOD+180/ENT+84/REG+24/EDG+16 = **恰一个额外实例**，无结构漂移）；全语料 72 档 check 面诊断/rc **零差异**；影子 `decisions=30338 agree=30338`，全计数 0，站点覆盖同前批（站点 1/2/4/6 语料零命中、3 仅 2 次）；`corec2==corec3` IDENTICAL + N06=0 + 冒烟 42；突变控制 4 条（M1 F4 / M2 本质轴判定 / M3 实例键 / M4 约束保留）逐条咬合且**复位后二进制逐字节复原**（`d78f49aa…`）。报告 = `.superpowers/sdd/p3-task5-report.md`。

### 34. R2 P3a 落地（2026-09-12——五任务：引擎展开层 / 定长退役收口 / 穷尽性 / 联合可选 / 泛型约束；**P3b 剩余面 + 收紧台账 + P5 继承项登记**）
- **落点与提交链**（P3a = Task 0/1/3/4/5；计划 = `docs/superpowers/plans/2026-09-11-r2-p3-capabilities.md`，**P3b 开工前必读其附录 B**）：
  · **Task 0 引擎展开层**（`61d3a8b4`）：`src/compiler/{ty_shadow,checker,type_engine,globals,type_selftest}.cr`——`sh_struct_term`/`sh_enum_domain_term`/`sh_variant_term`/`sh_iface_shape_term`（占位 -1）+ `iface_satisfies` 占位（恒 -1）+ 展开缓存（第二张表）+ 行→声明入口（`decl_name_of_ti`/`find_struct_row_of`/`find_enum_row_of`）。**语义边界 = 只服务满足判定与域查询，等价判定保持原子名义**；纯新增 502/0、72 档三面零差异。
  · **Task 1 定长退役收口**（`ef61f002`）：变型表 `ty_variance_of`（只读协变/可写不变/表外默认不变）+ `sh_seq_term`（固定性位入 b 槽，N 不入等价身份）+ `sh_ref_mut_marker`（mut 成判定维度）+ `array_len_walk` 方向规则（视图→固定 ⇒ 0）+ 10 判定点参序归一（源, 目标）；关闭「切片→固定长」静默放宽（P2a 洞）。
  · **Task 3 穷尽性真判定**（`e9818d62`）：`sh_match_*`（模式项/覆盖位/反例命名）+ checker `EXPR_MATCH` 判定 + `EC_TM_EXHAUST`(9003) 入硬名单（report-only 先行）+ TM04 软面；新套件 `tests/selfhost/test_match_exhaust.py`（16 例）。
  · **Task 4 联合/可选**（`c8c7731b`）：`T?` = `T ∪ null`（`TYP_OPTIONAL`/`TYP_NULL` + `EXPR_OPTIONAL`；`AK_NULL` = 引擎原生第九员，**不进** iface_registry 条目表——`iface.count == 13` 为判据硬值）；退役内建 Option 注册 + `Some`/`None` 关键字名分派 + `EXPR_TRY` 结构解包（废名字串）；枚举载荷**类型节点列**（T0 交接①）；可选目标子类型注入（`ti_subsumes`）；修 `Some(x)` 实参链挂死 + `sym_*` 越界崩；新套件 `test_optional.py`（12 例）。
  · **Task 5 泛型约束（P3a 半边）**（`9c0a83ec`）：结构/枚举约束保留（侧表 + 空槽预填 -1）+ 实例化点 `ty_sub` 本质轴判定（TG02 软诊断 + `tt_witness` 反例文本，零 `str_intern`）+ F4（#21 划销）+ monomorph 实例键类型项化；`T: I` 半边 = P3b；新套件 `test_generic_constr.py`（14 例）。
- **判据（收官复验，2026-09-12）**：全量回归 = 五 CI job（selfhost-tests · bootstrap-tests · suite · check · full-bootstrap）+ **42 selfhost + 7 bootstrap 全量套件**逐档 rc 记录；`selftest-types` 212→**288**；ELF canary `95084e7b…d475` IDENTICAL（clean-cache）；`corec2==corec3` cmp IDENTICAL + N06=0 + 冒烟 42；影子终态 `decisions=30128 agree=30128`（P3a 收官修复 target 清单后由 30338 → 30128，−210 = monomorph 退出 target 两档闭包；全计数 0，站点覆盖同报：站点 1/2/4/6 语料零命中、3 仅 2 次）；`.ccr`：T0/T1/T3 不变 · T4 = 「Option」串退役（STR −10B）· T5 = `generics_test` +370B（`get_val[unit]`→`get_val[int]`+`get_val[string]` 反折叠；`ptr_arith` 不变）；`check` job rc=1 = **既有 red 划界**（2 条 TF01 误报 `lits_copy`/`ty_memo_slot_no_grow`，行号随源码增长漂移，非本批引入）。（→ **2026-09-13 TF01 收口已修**，见 #40；本句为当期实跑记录，原样保留。）
- **收紧/放宽台账（P3a 汇总；逐条 = 计划附录 B.2）**：**收紧 18 条**（T0 0 · T1 6 · T3 6 · T4 3 · T5 3；其中 1 条 rc 不变仅诊断码集合扩张）+ 诊断面新增 1（TM04 软）+ **放宽 8 条**（T4 7 含 1 条非语义放宽 · T5 1）+ 实例名忠实化 6（T5 反折叠等）+ 挂死修复 2 端（T4）。**全语料零命中**（72 档 × 五任务同源双编译器对拍）⇒ 自举源码零改造。
- **P3b 剩余面（~~未开工；唯一阻塞 = `iface_satisfies` 未交付~~ ⇒ **2026-09-12 已全部交付**：Task 0b `9aa1786c` + Task 2 `44100ba4` + Task 6 `e838f18b` + 收官 **#39**；各件详版 = #36/#37/#38）**：Task 2 横切接口（形状条目 + 索引/切片/迭代消费点 `get_type_kind` 直比换位）、Task 6 impl 契约（签名类型项化 + 满足判定接引擎 + mangling 退役）、Task 5 的 `T: I` 半边（接线点已就位：`gen_constr_satisfied` 首分支 + `sh_iface_shape_term`）。开工顺序与硬口径（report-only / STR 段约束 / 三态纪律）见计划附录 B.1。
- **登记面（本批新增/更新；详版 = 计划附录 B.4 十九条）**：**非枚举域不判穷尽**（不假装穷尽/不假装不穷尽）+ **空枚举域 = 空洞穷尽**（实测判穷尽=1；计划原文「=0」偏差登记）+ **空递归保守**（P0 未覆盖面③，本批未动）+ **MAX_* 上限处置总口径**（MAX_ENUM_VARIANTS/MAX_VARIANT_TYPES 越界写未修 = **#35**（17 变体实测：check 静默 rc=0 / build rc=1；代码级定位含 224B 越界）· MAX_GENERICS=4 已登记未解除（#33 登记②）· 三者同族 ⇒ 统一「先加护栏、再评估解除」）；函数侧 `save_func_gen_constrs` 稀疏零初值同族风险（未修）；`never` 非 ⊥（不满足原生约束 / 不给 `never ⊆ T?`）；命名实参 vs 原生约束 = -1 不判（引擎 AK_NAMED 不展开）；运行期可选表示未统一（裸值 vs `Some(...)` 对象）= **`Some` 臂双路径 SIGSEGV（check/build rc=0 零诊断 + 产物/解释器 rc=139，非 P3a 引入）= 计划附录 B.7 一等条目（P3b/P4 必修）**；`EXPR_LET` 无检查 = #32（本站点仍留缺口）；bootstrap `&&`/`||` 不短路根因仍开放（T4 只关 `g_syms` 未分配触发链）；witness 含空析取支（反例命名走覆盖位，若净化 `tt_norm` 须同步）；`EXPR_ENUMPAT` 名字槽 = `ast_a`（新消费者必守）。
- **P5 继承项（并入 #24/#30 清单；状态更新）**：`type_equal_legacy` 删除（**状态更新**：T0 展开层按设计只服务满足判定/域查询 ⇒「unknown 清零前提 = 引擎命名展开」**不会被 T0 满足**——等价面展开属**裁决**；P5 须裁「接受命名展开（推翻 P2a 对拍基线）」或「legacy 长期化」）+ `sh_*_ak_legacy` 删除 + 站点 6 挂点 + 影子层（`--type-shadow`/`replace_*`）同族下线 + `tt_display` 零 `str_intern` 的可选改造（若 P5 接受 `.ccr` STR 段增长）。
- **判据继承（#26）**：本批 `.ccr` 判定按 #26 口径执行（`test_ccr_v7` 结构性断言 27/27 + 语义零变化 + 自举稳定），T4/T5 变更面**逐段实测**（非「与旧版逐字节同」）；三任务 ELF canary 全同 ⇒ 类型层改动未泄进发射面。
- **⚠ 收官发现并修复的回归（Task 7；**T5 漏改 project-mode 清单**）**：`src/targets/x86_64-linux/_import.cr`（corearch project-mode 导入清单）的 `import monomorph` 漏删——T5 只把 `monomorph.cr` 从 concat 面 `backend_support_files` 迁出，而 monomorph.cr 的类型项化新增 checker/parser 层依赖（`get_type_kind`/alloc_node 族 46 处）⇒ project-mode corearch 构建 **33×error[N06] 静默未定义**（rc=0 + 产物照出；stage 链互测不可见），`tests/selfhost/test_backend_bootstrap.py` 的 project-mode `error[` 门首步 rc=1。**为何 P3a 期间不可见** = 该套件未挂 CI（#31，同批已更新证据）。**修复** = 删该行（与 concat 面同一零引用证据；注记落文件头）；**复验** = 该套件 rc=0（stage1/2/3 逐字节同 + smoke/O2 smoke 全绿）+ project-mode 构建日志 `error[` = 0（33→0）+ ELF canary `95084e7b…d475` 不变 + 三二进制 sha 不变（本文件不入任何 concat 清单）。⇒ 收官全量枚举（42+7 逐档）终态 **49/49 rc=0**。
- **报告**：`.superpowers/sdd/p3-task{0,1,3,4,5,7}-report.md`（六份）。

### 22. 仓库卫生：suite 空 fixture ×2 + 死文件扫描噪声（2026-09-11 R2 P1 Task 3 语料扫描发现）
- **`tests/suite/test_control_flow.cr` / `test_generics.cr` = 0 字节空文件**：`corec` 对它们报 `error: cannot read`（**勘误**：Task 2 报告曾记为「预期失败 fixture」，实为空文件）。修复方向 = 补内容或删名（删需用户许可，铁律 #3）。
- **`src/compiler/elf.cr`**：`check` 扫描 rc=0 但 **2 个 parse error、decisions=0**——陈旧遗留文件（死文件本体的登记见 #7；本条补充**语料卫生**事实：批量 check 脚本须排除它，否则 parse error 混入语料日志）。**`src/compiler/linker.cr` 为 0 字节空文件**（同类：批扫时排除或删除）。
- **实证**：findings §8 末「其他已登记项」；语料日志 `/tmp/r2p1t3/all_tiers2.txt`。

### 23. harness 缺口：`.claude/hooks/block-git.py` 只拦「以 git 开头」→ 复合/管道命令可绕过（2026-09-11 R2 P1 Task 3 评审发现——**只登记，本轮不改 harness**）
- **现象**：钩子仅判 `stripped == "git"` 或 `stripped.startswith("git ")`（`.claude/hooks/block-git.py:10-11`）——`cd x && git status`、`echo hi; git log`、`(git status)`、`sudo git ...` 等**复合/包装形态全部放行**；铁律 #2 的「机械拦截」有洞。
- **影响**：非恶意误用（多 agent 并行时的习惯性复合命令）即可能绕过禁 git 约束；本轮工作副本已出现一次只读 `git diff --numstat` 违例（Task 3 自陈 D7，无写操作）。
- **修复方向（建议单开）**：按 shell 分隔符（`;` `&&` `||` `|` `(` 换行等）分词后做**词边界**匹配，命中 `git` 词即拒（注意放行 `jj git push` 等 jj 子命令形态与 `gitignore` 类词元）；并补负控用例（复合形态必拒、`jj git` 必放）。

### 24. R2 P2a 落地（2026-09-11——落点 / 未覆盖面登记 / P5 继承项，非缺陷）
- **落点**：`src/compiler/checker.cr`（`alloc_named_type` + 去重侧表 / `array_len_constraint_ok` / `type_compat_strict`+`diag_type_incompatible` / `type_equal_engine`+`type_equal_legacy` 拆分）、`src/compiler/ty_shadow.cr`（对照物切 legacy + `replace_*` 计数）、`src/compiler/globals.cr`（`g_named_dedup*` / `g_replace_*`）、`src/compiler/main.cr`（`--verify-named-dedup`）、`src/compiler/type_selftest.cr`（f1./f2./t3.* 用例）、`tests/selfhost/test_named_dedup.py`（新增）。计划 = `docs/superpowers/plans/2026-09-10-r2-p2-replace.md`；报告三份 = `.superpowers/sdd/r2p2-task-{1,2,3}-report.md` + 收官报告。提交链 `3c8402e8`+`8c9d773f`（F1）→ `b36d8e76`+`507daf7a`（F2）→ `10718ba8`（判定替换）→ 收官（本条目所在提交）。
- **行为面兑现**：判定权由结构判等移交引擎（`ty_equiv`），unknown（-1）/桥接失败**回落 legacy 并计数**（`replace_unknown`/`replace_bridge`，不静默）；ELF 逐字节 = R1 基线 `95084e7b…d475`（开/关两态）；自举 `corec2/corec3` cmp IDENTICAL + N06=0 + 冒烟 42；**已跑集**（17 selfhost + 5 bootstrap + `selftest-types`）rc=0。
- **评审 Critical 修复（2026-09-11 终审；本条目所在提交）**：**桥接缓存 `g_shadow_map` 无重置钩子**——本批起判定路径**无条件**调 `sh_term_of_ti`（此前仅 `--type-shadow` 下），而 `init_types()` 只清类型表与 `named_dedup` 侧表、**未清桥接缓存** ⇒ 长驻进程（corelsp 每请求 `reset_frontend_state → check_all`）里行号复用 + 命中即返回 = **两个不同类型被判等**（静默漏报；评审实证 corelsp 同 URI 两次 `didOpen` 换元素型 → 第二次 diagnostics=0）。修法 = `sh_map_reset()`（cap/entries/hits 归零）经 `init_types()` 调用（照 `named_dedup_reset` 先例）；判据 = `selftest-types` `t3c.*` 两例（计数 + 行为双断；**突变控制**：副本去掉该调用 → 93/95、两例 FAIL）+ LSP 双请求用例 `test_double_open_bridge_cache_reset`（修复前实测 RED：V2 diagnostics=0；修复后 1 条 `Assignment type mismatch`）+ ELF/`.ccr`/自举逐项复验。
- **未覆盖面（显式登记）**：① 站点 1/2/4/6 语料**零命中**（同 P1）→「对拍差异归零」效力范围 = 赋值/返回/if 面（站点 5/7/8），泛型实参/应用基型/兜底等价/热补丁四面的证据来自定向探针而非语料（P1 交接硬性要求：报差异数须同报站点覆盖）；② 语料 `replace_unknown = 0` 说明语料未触达引擎未知面——未知面证据来自探针与 C-1（`G<[int;3]>` 等 **5 处** =1：n5/n6 + `c1_genapply_same/diff/diff2`）。
- **P5 继承项（须在删 legacy 前清零/落地）**：① **`type_equal_legacy` 删除归 P5**——现为「对拍对照物 + unknown/桥接回落实现」双用；② **unknown 清零的前提 = 引擎命名展开**（`TYP_GENERIC_APPLY`/`AK_NAMED` 目前不展开 → 引擎 -1 → 回落 legacy；命名类型/泛型应用面的等价判定**仍由 legacy 承担**）——引擎命名展开落地前 unknown 清零不可达，且删 legacy 会把「回落」变「未判定」；③ 站点 6 挂点去留（P1 终审 M-1 交接）随 P5 站点面清理一并办；④ **R2 P2b Task 2 的 `sh_native_ak_legacy`/`sh_base_ak_legacy` 删除归 P5**——现为零生产调用的「全表对拍对照物」（`ty_shadow.cr:91-113`，仅 `type_selftest.cr` 的 `iface.by_ty_code_all_codes`/`iface.native_ak_all_rows`/`iface.compare_is_live` 三例引用）；删时须同步调整这三例（对拍面改为「生产入口 vs 表」或随影子层下线一并撤）。
- **同族清偿（P5 前必办）**：**桥接缓存（`g_shadow_map` 及其 `g_shadow_*` 诊断计数）+ `type_equal_legacy` 同属「调试/对拍结构进了生产判定路径」一族**——P1 时两者皆仅 `--type-shadow` 下活跃，P2a 起 `sh_term_of_ti` 与 legacy 回落都在**默认路径**上。清偿方向 = 引擎覆盖面补齐后（命名展开 + 长度面入库）删除 legacy 回落、桥接层退化为纯调试通道（或随影子层一并下线），届时 `g_shadow_map` 的失效钩子、`replace_*` 计数、`--verify-named-dedup`/`--type-shadow` 两个隐藏通道一并清理。
- **覆盖清单（Task 4 挂账 → 由终审转入本条）**：F2 约束的 **4/6 下钻位（REF / SLICE 元素位）用例已补（`f2.ref_elem_reject` / `f2.slice_elem_reject`）但缺「突变控制」**（未验证把该位实现改坏时用例真的会红——其余下钻位同此：现有用例只断「同长 → 1 ∧ 异长 → 0」，未见证伪实验）。补法 = 逐位做一次「删/改该位下钻 → 用例必须 FAIL」的突变实验并记档（同 `t3c.*` 与 LSP 用例的负控做法）。
- **P2b 待办（同 spec §9 P2 行）**：`infer_expr` 公理区 → `iface_ops` 查表接线；`res_type_node` 两表合一。→ ~~**2026-09-11 已落地**，见 #30~~（P2b 未交付面——`iface_satisfies` 等——已转入 P3 交接包：findings §12 + P3 计划附录 A）。

### 25. F5：`EXPR_TUPLE` 元素连续槽位假设对**复合表达式元素**不成立 → 元组字段类型错录（假拒 + soundness 漏放；含 `opt.cr:177` 恒空转登记）
- **✅ 已修（2026-09-11，提交 `0390f0f4`；工作区报告 `.superpowers/sdd/fix-tuple25-report.md`）**：
  parser 元组分支改**两趟**（先全部解析元素值、后统建连续 wrapper；`EXPR_TUPLE` 契约 a=首 wrapper / b=个数，wrapper.a=元素值节点）。**TODO 原建议「照 struct 先例（交错 wrapper）」经实测不成立**——交错下相邻 wrapper 间插着下一值子树（`P{a:11,b:g()}` 误返 0），故不采用。消费点 4 处同步解引用（checker/ir_gen/monomorph/opt；`opt.cr` 与 `ir_gen ast_patch_node` 两处 a/b 槽约定一并校正，经核均无调用者 = 死码，产物零影响）。
  **第二根因**：checker `EXPR_TUPLE` 元素类型**两趟落盘**（`data_start` 曾在推断循环前取 ⇒ 嵌套元素推断向 `g_gen_apply_data` 追加数据顶开后续落点、extra 错位 ⇒ 嵌套元组异型互赋静默通过）。回归 = `tests/selfhost/test_tuple_slots.py` 14 例（3 主判据 + 边界 3 + 嵌套 4 + IR/ELF 冒烟）。
  **同族已修（另立条目 #28，2026-09-11）**：struct 字面量复合字段值误编译（`P{a:11,b:g()}` 返 0）、ARRAY 复合元素 `[[1,2],[3,4]]` vs `[5,6]` 静默接受、monomorph 数组克隆实参错位——三处与元组同属「值节点连续槽位」契约，修法同款两趟 wrapper。
- **现象（Task 3 评审加码定位，pre-existing；建议单开任务）**：元组字面量 `(e0, e1, …)` 的元素类型按「`a + 0..a+ec-1` 连续槽位」读取，但**复合表达式元素自身占多个 AST 槽**（如 `[1,2,3]` 的数组节点在其 3 个子节点**之后**）→ 后续元素的槽位推断全错位。两类实证（`/tmp/r2p2t3/probes`）：
  - ① **假拒绝（类型面）**：`(1,a)` vs `(1,[1,2,3])`（**语义同型** `(int,[int;3])`）→ 误报 `error[TA01]`；
  - ② **soundness 漏放**：`(1,[1,2,3])` vs `(1,h())`（`h()->int`，**异型互赋**）→ **静默接受**；
  - ③ N 面漏检（Task 3 §6.1）：`(int,[int;3])` 字段位的异长静默通过（元素为复合表达式时该位无检查）。
  - 反证边界：`([1,2,3],1)`（数组在**首位**）正确——首位 = `parse_expr` 返回值，位置天然正确；`(1,a)`（单节点元素）正确。
- **root cause（实读）**：`parser.cr:487` 元组分支只记 `ef = parse_expr()` 首元素节点 + `ec` 元素**个数**，注释「stored in consecutive g_ast slots」对复合元素不成立；**对照物 = struct 字面量有 wrapper**（`parser.cr:459` 每字段值后 `ast_alloc(0, fv, …)` 建转发节点 → 字段恒连续），元组分支缺同款。
- **消费点（4 处同假设，须一并复核）**：`checker.cr:2639`（`infer_expr` 的 `EXPR_TUPLE` 分支）、`ir_gen.cr:2207`（`gen_expr` 的 `EXPR_TUPLE`）、`monomorph.cr:296`（注释原文「elements are consecutive」）、**`opt.cr:177`**（`EXPR_ARRAY || EXPR_TUPLE` 分支——读 `ast_b`/`ast_c` 而约定是 `a`/`b`（a=首元素槽、b=个数）⇒ 数组/元组元素优化**恒空转**（`ac` 取到 0 → 循环体从不执行）；**无正确性影响**，但同属「a/b 槽约定被写错」家族，修 F5 时一并校正）。
- **修复方向**：补 wrapper（照 struct 先例，改动最小）或改元素存储为显式槽位表；须同步 4 个消费点。
- **判据（建议）**：修 parser 后 3 条新探针（异长拒 / 同型接受 / 异型拒）+ `selftest-types` 增例 + 4 消费点复核 + ELF/`.ccr` 逐字节（**注意：改 AST 布局可能改变产物，须列明并逐字节实测**）+ 全回归。
- **为何未在 P2a 修**：修法动 AST 布局 + **4 个消费点**（上列），可能改变 `.ccr`/ELF 产物 → 须单独立项裁决（非「顺手改」面）。

### 26. 判据重定：state 边 / 纯度类改动的判定基准（2026-09-11 效应/纯度修正批 Task 3 确立——**非缺陷，登记性条目**）
- **适用面**：凡触及 state 链 / 纯度的改动——`dataflow.cr`（`df_connect_state` / `df_replay_state_chain`）、`checker.cr`（`purity_op_effect` / `compute_all_purity`）、`monomorph.cr`（实例纯度继承）、`ccr_io.cr`（EDG/NOD 序列化）等。
- **新判据**（取代旧「`.ccr` 与旧版逐字节相同」）：① **语义零变化**（解释器 + ELF 两侧行为一致）；② **边集语义断言**——`.ccr` 层 `tests/selfhost/test_ccr_v7.py` 三条性质（可证纯调用⇒无 kind=1 入边 / 效应调用四类（store 体·extern·不可解析 builtin·间接调用）⇒必有 kind=1 入边 / 每函数链独立零跨函数；各带正负控）+ C 层同族 `corec selftest-purity`；③ **自举稳定**（连续两次编译产物一致：`corec2`/`corec3` `cmp` IDENTICAL + N06=0 + 冒烟 42）。
- **旧判据退役理由**：该类改动**必然改**产物——`.ccr` 的 **EDG 段**（kind=1 边增删）与 **NOD 邻接域**（first_edge/edge_count；节点序不变——链只加边）、`corearch --dump-objects` 通道输出、（缓存态下）`.core/cache/cir` 与二次运行产物。Task 1/2 实测：`IR_CALL_EXTERN`/`IR_SPAWN`/`IR_YIELD` 由不入链改为入链 ⇒ EDG kind=1 边 +N。**ELF 逐字节不变判据在本类改动下仍有效**（lazy 判定解耦：`ir_gen.cr` 的 lazy 与 `IR_LAZY_THUNK/FORCE` 发射面不动）——若 ELF 变，说明改动泄进发射面，须停下上报。
- **操作约束**：比较任何 `.ccr` 产物 sha 前必须 `clean-cache`（同 #5 家族：**冷/热缓存态 `.ccr` 分歧**——2026-09-11 起「升级后旧缓存静默失效」那一半已随 #5 修复关闭[编译器身份字段]，本约束由冷/热分歧面继续承担）；`.cir` 缓存同源受此约束。
- **实测锚**：Task 1（`762bd429`）/ Task 2（`c9099d73`）/ Task 3（本条目所在提交）三任务后 `test_ccr_v7.py` 的 `EXPECT_DATA 41 / EXPECT_STATE 13` **未变**——fixture（PROBE_SRC）只含可证纯调用（不入链）与 store 族，无新入链 opcode ⇒ 期望表不重锁（该判断本身 = 实测后按「确无变化则不重锁」处理的记录）。
- **R2 P3a 继承（2026-09-12，P3 Task 7 收官；#34）**：本批（Task 0/1/3/4/5）对 `.ccr` 的判定**一律按本条口径执行**——T0/T1/T3 `.ccr` 逐字节不变；**T4 变**（内建 Option 串退役：STR 段 −10B、后续索引整体 −1，逐段实测）；**T5 变**（`generics_test` +370B = 恰一个额外实例：`get_val[unit]` → `get_val[int]`+`get_val[string]` 反折叠，逐段实测）；三任务 **ELF canary 均逐字节同** ⇒ 类型层改动未泄进发射面（本条「ELF 变须停下上报」条款得到执行）；结构性断言 `test_ccr_v7` 27/27 全程绿。

### 27. 效应/纯度修正批落地（2026-09-11 P0 插队批——`fi_ispure` 真计算 + state 链分类表补全；**非缺陷，落地登记**）
- **落点**：`src/compiler/checker.cr`（`purity_op_effect` :2891 · `compute_all_purity` :2938 · `fi_ispure_of` :3083 · `src_func_of_ir` / `df_func_of_node`）、`src/compiler/dataflow.cr`（`df_connect_state` :146 改调单一真源 · `df_replay_state_chain` :197 · `df_state_finalize` :249）、`src/compiler/purity_selftest.cr`（新增，26 例）、`src/compiler/monomorph.cr`（实例→源侧表登记）、`src/compiler/cir_cache.cr`（版本 14→15——快照不再持久化链边）、`tests/selfhost/test_purity.py`、`tests/selfhost/test_ccr_v7.py`（24→27）。
- **提交链**：`762bd429`（Task 1：真纯度计算 + 链迁至 IR 生成后重建）→ `c9099d73`（Task 2：分类表补全 / 单一真源）→ `c7ca4251`（Task 3：判据重定）→ 收官（本条目所在提交：全量回归 + 复验 + 本回填）。
- **修了什么（P0 症状）**：`fi_ispure` 由「乐观常量 1」（`checker.cr:1107`/`:1142` 两写入点——**有意保留**为 IR 生成期的冻结输入，见残余面①）改为全程序 IR 面真计算——保守起点（全不纯）+ 调用图不动点升纯 + 递归/SCC 保守 + 不可解析调用保守 + `unsafe` 区不纯 + 泛型（实例按自身体；源 = 实例合取）⇒ `print`/`read_file`/`chan_send`/`sched_go` 等一切可解析但不纯的调用重新入 state 链。分类表 opcode 面收敛为 `purity_op_effect` **单一真源**（D7）：`IR_CALL_EXTERN`/`IR_SPAWN`/`IR_YIELD`/`IR_HOTPATCH_ROUTE`/**间接调用 `IR_DYN_DISPATCH`**/`IR_STORE_PTR`/`IR_AWAIT` 全入链。
- **链覆盖范围（回填口径，供 spec 引用）**：函数内 = store 家族 + 上列全部效应 opcode + 一切不可解析调用 + 一切被判不纯的可解析调用；**链仍每函数重置**（`df_replay_state_chain` 链头重置与 `df_begin_func` 同语义——跨函数不连；判据域内调用节点 = 被调者效应的序代理）。**残余面**：① lazy 判定（`ir_gen.cr:1590`）**有意冻结**（本批 `ir_gen.cr` 零改动 ⇒ 生成期 `fi_ispure` 仍是乐观默认值）；② 其 use_count 时序缺陷**独立未修**（保持登记于「控制流自动惰性」节）。
- **判据（本批确立，见 #26）与收官实测（Task 4）**：全量回归 **38/38 rc=0**（7 bootstrap + 31 selfhost，含 `test_ccr_v7` 27/27 · `test_purity` · `test_compile`）；`tests/suite` 语料 **20/20**（非 `*_mini*` 且非空 = 20 个）build+run rc=0；ELF canary `tests/suite/ptr_arith.cr` = `95084e7b…d475` **IDENTICAL**；语料级「旧前端（Task 1 前）+ 当前后端 vs 当前全链」**20/20 ELF 逐字节相同**（发射面零泄漏；运行 rc/stdout 同）；自举两连建（`build_selfhost_native.py` ×2）corec/corearch/corelsp 产物 sha 逐一相同 + `corec2b`/`corec3b` `cmp` **IDENTICAL** + N06=0 + 冒烟 42。
- **`.ccr` 变更面（Task 4 实测，冷缓存）**：kind=1（链）边增删为唯一语义差；**NOD 语义字段（op/dest/s1/s2/s3/tk）零差异**（节点序不变），唯 `first_edge`/`edge_count` 邻接域随动；STR/SYM/ENT/REG 四段逐字节不变。量级（旧前端→当前）：`CHAIN_SRC` 303→**329**（+26）· `PROBE_SRC` 298→322（+24，但 src 域期望集合未变——Task 3）· `ptr_arith` 293→**318**（+25；Task 1 时代为 317，Task 2 的 opcode 面 +1）· 无效应程序 `fn main()->int{return 42;}` 285→309（+24——**全部**来自编译内建的 runtime/builtin 函数体，该程序自身零调用）。归因（noeffect 逐 opcode）：新增入链目标 = `IR_CALL` +18 入边、`IR_STORE` +6 入边。**效应 opcode 清单唯一 = `purity_op_effect`**（新增 IR opcode 必须同步该处，否则链/纯度两判据漂移——D7 的机械保证）。

### 28. F5 同族：`EXPR_STRUCT` / `EXPR_STRUCTPAT` / `EXPR_ARRAY`（字面量形）的「值节点连续槽位」假设同样不成立 → 静默错误值 + `a[1][0]` SIGSEGV + soundness 漏放
- **✅ 已修（2026-09-11，本条提交；工作区报告 `.superpowers/sdd/fix-struct2-report.md`；F5 系由 #25 发现者提出）**：parser 三分支统一**两趟**（先解析全部值进暂存表、后统建连续 wrapper）。契约 = `EXPR_STRUCT`/`EXPR_STRUCTPAT`/`EXPR_ARRAY`(字面量形) 的 **a=首 wrapper、b=个数**；wrapper（kind=`EXPR_NONE`）在 `g_ast` 中连续、`wrapper.a`=值节点。消费点 5 处同步逐 wrapper 解引用：`parser.cr:452`（struct 字面量）/ `parser.cr:607`（数组字面量）/ struct 模式分支（同款）· `checker.cr:2513`（`infer_expr` EXPR_STRUCT）/ `checker.cr:2576`（EXPR_ARRAY）· `ir_gen.cr:2087`（`gen_expr`）/ `ir_gen.cr:2112`（数组）/ `ir_gen.cr:2606`+`:2622`（`ast_patch_node`）· `monomorph.cr:282`+`:311`+`:391`（克隆改「先克隆值、后统建 wrapper」）· `opt.cr:130`+`:188`（折叠）。
- **现象（RED 实测，修复前）**：① 静默错误值 `P{a: 11, b: g()}`（`g()->3`）→ `p.b` 得 **0**（`p.a*100+p.b` = 76≙1100，rc=0 无任何诊断）；`P{a: g(), b: h()}` → `p.b` 得 0；② `[[1,2],[3,4]]` 的 `a[1]` 被读成扁平 int 3 → `a[1][0]` **SIGSEGV 139**；`[1, g(), 3]` 的 `a[1]` 得 0；③ soundness：`[[1,2],[3,4]]` 与 `[5,6]` 类型互赋**静默通过**（元素类型被错录为 int）。
- **root cause（实读）**：`parser.cr` struct 字面量分支原文 `fv := parse_expr(); ast_alloc(0, fv, …)` 逐值后随建 wrapper——值节点是复合表达式（调用 / 嵌套字面量 / 下标）时子树自占多槽、夹在相邻 wrapper 之间 ⇒ 第 2 个起槽位整体错位，消费者读到值节点的**子节点**。数组/模式分支同形（数组更甚：连 `[T; N]` 类型形与字面量形共用 `EXPR_ARRAY`，靠 b=0 区分）。**#25 的元组修复即为模板，本条目 = 同契约补齐最后三处实例**。
- **附带修正（同族、原恒空转/旧约定残留）**：`opt.cr` 的 EXPR_STRUCT/EXPR_ARRAY 分支直接对 wrapper 递归，而 wrapper 的 `EXPR_NONE` 在该函数无分支 ⇒ 字段值/元素**从不被常量折叠**（静默空转）；`ir_gen.cr` `ast_patch_node` 的 EXPR_STRUCT 分支同为对 wrapper 空转（泛型实例体内 struct 字面量字段中的方法调用名得不到替换）；`[v; N]` 重复形由「浅拷贝根节点 N−1 份」改为「共享同一值节点 + N 个 wrapper」（语义等价，不再复制多槽子树）；`monomorph.cr` EXPR_STRUCT/EXPR_STRUCTPAT 旧 `gen_clone_consecutive(b, c * 2)` 为「2 节点/字段」旧约定残留（对现 1 wrapper/字段布局**多克隆一倍**）→ 一并改两趟。
- **判据（实测）**：`selftest-types` 95/95 · `test_compile` PASS · `test_purity` PASS · `test_tuple_slots` 14/14（未回归）· `test_ccr_v7` 27/27 · 新增 `tests/selfhost/test_agg_slots.py` **13/13**（值 9 例 build+run 退出码 = main 返回值 & 0xFF：struct 主判据 2 + 三字段中位 + 嵌套 struct + 单槽反证边界 + 泛型实例体克隆 + 数组中位 / 嵌套数组 / `[v;N]`；类型 4 例：嵌套 vs 扁平拒 / 元素数不符拒 / 同形收 / `[T;N]` 类型形控制）+ `src/ci/run.sh` selfhost-tests 挂钩；ELF canary `tests/suite/ptr_arith.cr` = `95084e7b…d475` **IDENTICAL**（该语料**含**数组字面量 ⇒ 数组侧的「AST 布局零泄漏」为实测证据，非同 #25 的「语料无该构造」情形）；`.ccr` sha 与前序状态相同（`ecd7a9df…d29d`，struct 修复后 → 数组修复后未变）。
- **本族剩余面（发现即登记，未修）**：① **struct 字面量字段名被丢弃**——parser 取 `fni` 后从未写入（值按**声明位序**绑定）：`P{b: 11, a: 22}` 静默得 `a=11,b=22`（rc=0 静默错值），字段名/顺序校验、缺字段均不存在；② **struct 字面量字段类型不比对声明**：`P{a: 1, b: "x"}`（b: int）、`P{a: 1}`（缺 b）、`P{a: 1, b: 3}`（b: Q 结构体）全部 rc=0 静默通过；③ **数组元素同质性不检查**：`[1, "x", 3]` rc=0；④ **struct 模式绑定未实现**（`P{a: x}` 中 `x` 报 N01 未定义——checker 对 `EXPR_STRUCTPAT` 直接返 `TI_UNIT`、ir_gen 返 -1）⇒ 模式分支的槽位修复为防御性，无可观测行为变化。以上四项另立条目。

### 29. F5 同族剩余面（#28 修复时发现即登记，2026-09-11——struct/数组字面量的「名 / 型 / 同质性」三校验全缺 + struct 模式绑定未实现）
- **✅ ①②③ 已修（2026-09-11；工作区报告 `.superpowers/sdd/fix-agg29-report.md`）**：
  · **① 名字绑定** —— parser 把字段名 idx 写入 **wrapper.b**（EXPR_STRUCT 契约：`wrapper.a`=值节点、`wrapper.b`=名字 idx，**-1 = 无名字信息 → 位序回落**；与值并列的平行名字表，两趟结构不变、仍无交错分配）。字段值**按名字绑定**（与 Python bootstrap 的 `gen_struct_lit` 同语义）：checker 解出「字面量字段 i → 声明下标 j」（`struct_field_index_by_name`），ir_gen 同一解算落 `IR_STORE_FIELD`，求值顺序仍为**源序**（实测 `P{b:nx(), a:nx()}` = 201 = b 先求值）。monomorph 克隆**保留 wrapper.b**（丢名字 ⇒ 实例体回落位序 = 静默错值，与 #29 同类）。
  · **② 三校验 + 类型比对** —— 未知字段 `TS02` / 重复字段 `TS04` / 缺字段 `TS01`（只报首个）/ 字段类型 vs 声明 `TS03`（判定走 `type_compat_strict` + `diag_type_incompatible`，与赋值同一引擎，站点 9）。**两侧任一含未实例化泛型参数（`TYP_GENERIC_PARAM`，含嵌套）→ 跳过比对**（不假拒：泛型函数体 `fn f[T](x: T){ p := P{a:1,b:x}; }` 的值类型是 T）；字段声明类型提及结构体泛型参数（`T` / `[T;3]` / `Box[T]`）→ 跳过比对、走参数绑定（`unify_types`）。**附带修正**：泛型结构体字面量的 `TYP_GENERIC_APPLY` 实参改按**参数声明序**取（旧代码按字面量字段序 ⇒ 双参数且字段序 ≠ 参数序时实参错位）。
  · **③ 元素同质性** —— 元素类型取**首**元素（旧代码逐个覆盖 = 随**末**元素漂移），后续逐个比对 `TK02`（站点 10），同样带泛型参数跳过门。
  · **硬错误门（非静默的必要条件）**：`TS01-04` + `TK02` 入 `run_frontend` 硬错误名单（与 R002/TK05/TK06 同类）——修复前这些字面量即便报错也照常产出二进制：未知/缺字段 ⇒ 字段从未写入（读垃圾值）、错型 ⇒ 按错宽度存、异质数组 ⇒ 类型漂移（soundness 漏放）。现 rc=1 且**无产物**。
- **④ struct 模式绑定仍未实现**（独立特性，需 checker + ir_gen 联动；`EXPR_STRUCTPAT` 槽位契约已由 #28 对齐）——本任务范围外，保持原状。
- **附带修复（发现即修，本条提交）：bootstrap 后端 `return` 非块终结符** —— `bootstrap/corec/backend/x86_64_stack_asm.py` 仅在「块的最后一条指令恰是 ReturnInstr」时补 epilogue：**同块双 return**（return 后跟死代码）时两条 `mov rax, ...` 都发射、只在末尾退出 ⇒ 返回值 = **最后一个** return 的值（死代码赢，静默错值）。实测命中 `checker.cr` 的 `unify_types`（`return true; return false;` 被编成**恒返 false**）——此函数返回值此前**无人使用**（`infer_gen_call` 丢弃返回值、递归点从未触发）故长期潜伏；#29 的泛型绑定判定首次消费其返回值即暴露（`Box{val=100}` 被误判 TS03）。修复 = ReturnInstr 视为**块终结符**（发射 epilogue 后停止发射同块余下指令）。全 `build/corec.s` 扫描：命中面恰此 1 处。
- **判据（实测，均在冷缓存下）**：`tests/selfhost/test_agg_checks.py` **17/17**（值 7：名字绑定主判据 / 源序副作用 / 三字段逆序 / 乱序+嵌套字面量 / 泛型 Pair 乱序 / 双参数字段序≠参数序 / 泛型函数体经 monomorph 克隆；类型 10：负 7（TS02+TS01 / TS04 / TS01 / TS03 int←string / TS03 Q←int / TK02 扁平 / TK02 嵌套，均验 rc≠0 + 码 + **无产物** + 定位）/ 正 3）+ `src/ci/run.sh` selfhost-tests 挂钩；`selftest-types` 95/95 · `test_compile` PASS · `test_purity` PASS · `test_agg_slots` 13/13 · `test_tuple_slots` 14/14 · `test_ccr_v7` 27/27 · selfhost 其余 7 套（impl/borrow/pointer_safety/params_limit/nested_fn/interp_parity/cache_identity/backend_bootstrap）全绿 · bootstrap 三套 29/29+4/4+3/3 · `tests/suite` 21 语料 ALL PASS（**generics_test.cr 是本次唯一被新检查拦下的现存语料**——见附带修复：它是 `Box { val = 100 }` 被误拒，属修复前潜伏的 bootstrap 误编译面，非新检查过严）· ELF canary `ptr_arith` = `95084e7b…d475` **IDENTICAL** · 三阶段自举 corec2 ≡ corec3 逐字节。
- **`.ccr`/形状面**：名字随 wrapper 携带**不改变 IR 发射**（消费者解算后字段位与修复前同名同序写法完全一致）——ELF 逐字节 canary 与三阶段自举逐字节为证。

### 30. R2 P2b 落地（2026-09-11——`infer_expr` 公理区查表接线 + 双份 TY→TI 合一；落点 / 未覆盖面 / P3 交接，非缺陷）
- **落点**：新建 `src/compiler/iface_registry.cr`（13 条本质条目表 = 8 原生 + product/sequence/ref/ptr/named，40B/条 × 5 字段 `{ak, ti_row, name_ni, lit_code, ops}`，静态常量、不 alloc `g_types` 行；`iface_*` 查询 API 11 个 + `ty_code_to_ti` 单表）、`src/compiler/checker.cr`（字面量定型 5 处 `:1906-1911` ← `iface_lit_ti`；算术门 ANY `:1969` / 逻辑门 ALL `:1984` / `if` ONE `:2298` / `while` ONE `:2411` ← `iface_permits`；索引兜底拒绝 `:2678` ← `IP_INDEX`；8 个 TY→TI 站点 ← `ty_code_to_ti`，含 `res_type_node`/`res_call_type` 两表合一）、`src/compiler/ty_shadow.cr`（`sh_native_ak`/`sh_base_ak` 委托 `iface_by_ty_code` 单源化，legacy 拷贝保留为对照物）、`src/compiler/globals.cr`（`g_iface_*` + `IP_*` 位下标常量——**必须落 globals.cr**：变量/常量跨文件按声明序可见）、`type_selftest.cr`（**95 → 212 例**）、`tests/selfhost/test_iface_ops.py`（新建 **76 例**）、`src/ci/run.sh`（selfhost-tests 新挂 `test_type_engine.py`（`selftest-types` 212 例——P0/P1/P2a 一路漏挂）与 `test_iface_ops.py`）。计划 = `docs/superpowers/plans/2026-09-11-r2-p2b-iface-ops.md`；报告六份 = `.superpowers/sdd/p2b-task{1..6}-report.md` + 收官报告。
- **提交链**：`7f520dce`（T1 建层）→ `31143cd0`（T2 桥接单源化）→ `9b15fd2a`（测试挂 CI + 计划回填）→ `6d2790cd`（T3 字面量定型）→ `a99ee825`（T4 操作许可）→ `7145eea5`（T5 容器面）→ `30545da7`（T6 双表合一）→ 收官（本条目所在提交）。
- **口径兑现（保语义 = 零行为变化，硬判据）**：表的每格 = 现状逐格转录（格注现状 `file:line`）⇒ **收紧清单 = 空**（「旧接受 → 新拒绝」零条，反向亦零条）。收官实测：全量回归 **46 套件 rc=0**（7 bootstrap + 39 selfhost；计划记 38 = 7+31，差 8 为期间新增套件）+ `selftest-types` **212/212** + `test_iface_ops` **76/76**；ELF canary `95084e7b…d475` **IDENTICAL**（clean-cache；**开/关影子两态逐字节同**）；`.ccr` 4 档逐字节同（`ecd7a9df…`/`891377232b…`/`35cf0f26…`/`dfb82d2b…`，与 T1~T6 逐字一致）；**同源双编译器对拍**（旧二进制 × 新源 == 新二进制 × 新源）：21 档语料 check 输出 + 自源 `check src/compiler` + 32 档影子通道（decisions=2826 agree=2826，全计数 0）逐字节同；自举 `corec2==corec3` IDENTICAL（`c201916d…a7d9`）+ **N06=0**（两段 build log）+ `--help` rc=1 + 冒烟 42；`build/corec` 重建后 sha 复原（`8f69e346…858b`，构建确定性）。自源仅既有 2 条 TF01 误报（`lits_copy:9383` / `ty_memo_slot_no_grow:9498`，`ty_shadow.cr:143-146` 已登记；两侧编译器输出逐字节同 ⇒ 非本批引入）。（→ **2026-09-13 TF01 收口已修**，见 #40：`lits_copy` = 真·类型洗白（返回型改 `string`），`ty_memo_slot_no_grow` = checker 落空分析缺失；`ty_shadow.cr` 注释已同批改写。）
- **P3 交接（本批最有价值的产出）**：**未接线站点台账 31 条**（T4 的 14 + T5 的 17：结果规则 / 无拒绝路径 / 谓词非类级位，逐条实测理由）+ **P3 裁决点 10 项**（`iface_satisfies` 未交付 / `name_ni=-1`（.ccr STR 段约束）/ `TY_DEX_S` 不入表 / `never` 调用位点=unit 而类型位点=never / 「全许可列」11 位×13 类 / 字段·转换面无拒绝路径 / dyn 逐行谓词 + 位图 64 上限 / 索引侧缺「须 int」位 / 枚举域无 `AK_SUM` 条目 / 性能面）落 `docs/superpowers/plans/2026-09-11-r2-p3-capabilities.md` **附录 A**；现状九条宽松面事实表落 `docs/superpowers/specs/2026-09-10-type-shadow-findings.md` **§12**。
- **未覆盖面（显式登记）**：`iface_satisfies`（零调用者，P3 交付）；`iface_size`/`iface_align`（归 hw-map）；横切轴/用户轴条目；`AK_SUM`/`AK_FN` 无 checker 对应；dyn 位图 64 上限；`name_ni=-1`；18+18+8 个候选站点中**仅 5 个门 + 5 处字面量定型 + 8 个映射站点**（另加桥接单源化）可零行为变化接线，其余 31 个逐条实测不可接线（理由见附录 A.2）。
- **P5 继承项（并入 #24 清单）**：`sh_native_ak_legacy`/`sh_base_ak_legacy` 删除（T2 对照物，仅 `type_selftest.cr` 三例引用；删时同步调整）+ `type_equal_legacy` 删除 + unknown 清零（同 #24 原口径，前提 = 引擎命名展开）。

### 31. CI 挂点缺口：`selfhost-tests` 挂 15/39、`bootstrap-tests` 挂 3/7（2026-09-11 R2 P2b 阶段评审登记——非缺陷，覆盖面缺口）
- **现状**：`src/ci/run.sh` 的 `selfhost-tests` 只跑 15/39 个 selfhost 套件、`bootstrap-tests` 只跑 3/7 个 bootstrap 套件；未挂套件含前序阶段点名的守卫——`tests/selfhost/test_lsp.py`（桥接缓存重置，R2 P2a 评审 Critical 的回归钉）、`test_named_dedup.py`、`test_slice_bounds.py`。
- **影响**：不削弱 P2b 批自身保证（其两个新测试文件已挂 `run.sh:71-72`），但上述守卫此后回归 CI 捕获不到。
- **建议修法**：一次性挂齐（评估耗时后决定全集或分批）。
- **2026-09-12 复测（P3a 收官；#34）**：`selfhost-tests` 挂 **18/42**（期间新增 3 档——`test_match_exhaust` / `test_optional` / `test_generic_constr`——均已挂钩）、`bootstrap-tests` 仍 **3/7**；缺口未变。收官全量枚举（42+7 逐档 rc）仅在收官运行器里执行一次，**未**落 CI。
- **⚠ 缺口的实际代价（2026-09-12 实证，#34）**：P3 Task 5 的 monomorph 迁出只改了 concat 面清单（`build_selfhost_native.py`），漏改 project-mode 清单（`src/targets/x86_64-linux/_import.cr` 的 `import monomorph`）⇒ project-mode corearch 构建 **33×error[N06] 静默未定义**（rc=0 + 产物照出），**该缺陷在整个 P3a 期间不可见**（5 个任务的回归面均未跑到：`test_backend_bootstrap.py` 正是唯一守卫，而未挂 CI）；收官全量枚举首次暴露（rc=1）。⇒ 本条从「覆盖面缺口」升级为「已有一次真实漏检」；挂齐建议的优先级相应上调（至少把 `test_backend_bootstrap.py` / `test_lsp.py` / `test_named_dedup.py` / `test_slice_bounds.py` 四个点名的守卫先挂）。

### 32. `EXPR_LET` 站点**无任何兼容检查**（2026-09-11 R2 P3 Task 1 实测发现 → Task 4 登记——既有洞，建议专批）
- **现状**：`checker.cr` 的 `EXPR_LET` 分支（`infer_expr`）**只登记符号**：`ti := val_ti; if type_node >= 0 { ti = res_type_node(type_node); }`——**不做值/注解比对**（该分支无 `type_equal`/`type_compat_strict` 调用，全仓 grep 可核）。实测（Task 1 与 Task 4 两代二进制同值）：
  · `x: [int;3] = s;`（s 为切片）→ **rc=0**（pA 类静默放宽的站点外同族；pA 面已被 Task 1 关闭，本站点仍留缺口）；
  · `x: [int;4] = [1,2,3];`（常量档异长）→ **rc=0**（比 pA 更宽）；
  · Task 4 面：`x: int? = 5; y: int = x;`（**可选值流进窄槽**）→ check rc=0、build rc=0、`run rc=5`——即 `T? ⊄ T` 的站点级拒绝（返回位/赋值位已落，见 Task 4 的 `type_compat_strict` 注）在**本站点可被绕过**；同族 `fn f(v: int)` ← `int?` 实参 ⇒ 运行期拿指针值（实测 `run rc=8`）——后者归 **#20（F3 调用位点无诊断）**，与本案互为姊妹面。
- **为何不是 Task 1/Task 4 顺手修**：本站**不是**既有 10 判定点之一（Task 1 报告 §6-① 已论证）；追加 = 「**新增判定点 + 新硬错误门**」，须走全语料 report-only 清单（Global Constraints 第 6 条）与「判定点不变」之外的裁决。Task 4 的判定面改动一律限于既有 `type_compat_strict` 组合函数内部（可选目标注入），**未**新增站点。
- **建议修法**：按 Task 1 §3.1 的参序（源 = `val_ti`，目标 = 注解行）在 `EXPR_LET` 加 `type_compat_strict` + `diag_type_incompatible`（码/措辞沿用 TF01/TA01/TC02 体系或新码，二者先裁决），**先全语料 report-only** 出清单（预期命中：泛型函数体内的 `T` 注解、`[T;N]` 表示提示位、可选注入面——逐条审查后入硬名单）；同时确认「无注解 `x := <值>`」与「`x : .` auto 注解」不受影响。修完应同时覆盖 #20 的调用位点面（同参序同判定），或显式在 #20 划界。

### 35. 前端枚举表**写入侧无护栏**：≥17 变体 / ≥17 载荷类型越界写（2026-09-12 R2 P3a 阶段评审登记——**#8 同族**；代码级定位 + check/build 两面实测）
- **机制（代码级逐行核对，2026-09-12）**：`parser.cr` 枚举分支的变体循环（`:1672` 变体名 / `:1679` 载荷裸码 / `:1683` 载荷节点 / `:1690` 载荷计数；`:1694` 收尾写 variant_count）对 `vc`/`tc` **无任何上限闸**。布局（`dyn_arr.cr:158-164`，T4 扩表后）：`OFF_EI_VARIANTS=8` · `OFF_EV_SIZE=272`（name 8 + types[16] 128 + type_count 8 + type_nodes[16] 128）· `OFF_EI_VARIANT_COUNT=4360`（= 8+16×272，**恰 16 槽**）· `ESZ_ENUMINFO=4408`。**第 17 个变体**（0-based 下标 16）槽起点 = **4360 = `OFF_EI_VARIANT_COUNT` 自身**（先覆盖 variant_count），槽尾 4632 ⇒ 越过记录尾 **224B**（踩下一条枚举记录头部；分配按记录数 `grow_enums` = `nc*ESZ_ENUMINFO` ⇒ 溢出者为缓冲区最后一条记录时越出分配）。载荷侧同构：第 17 个载荷类型写 `OFF_EV_TYPES+16×8 = 136 = OFF_EV_TYPE_COUNT`（并踩 type_nodes 槽）。
- **两面实测（2026-09-12；17 变体最小例 `enum E17 { V0..V16 }`，P3a 收官二进制）**：`check` = **rc=0 零诊断**（前端不读回 ⇒ **「静默」只限这一面**）；`build` = **rc=1**（corearch `.ccr` 读回侧闸 `ccr_io.cr:1121` `vc > MAX_ENUM_VARIANTS` ⇒ `error: .ccr enum variant count exceeds max` + `error: invalid .ccr file`，**无产物**；载荷侧 `:1148` 同）——但**写入已在读回闸之前发生**（护栏在读回侧 ≠ 写入侧）。
- **既有事实**：`MAX_ENUM_VARIANTS`/`MAX_VARIANT_TYPES`（皆 16，`ast.cr:117-118`）**只**被 `.ccr` 读回侧消费（全仓 grep；parse 侧零引用）；`ty_shadow.cr:955` 注释「MAX_ENUM_VARIANTS = 16 保证不溢出」以「写入侧有闸」为前提——该前提不成立。
- **未做（如实登记）**：越界写的**运行期危害形态**（跨记录污染 / 越 buffer 的具体破坏）未单独构造复现——本轮只测两面 rc + 常量/写点逐行核对；危害面排查可伴随修复批做。
- **修复方向（照 #8 先例）**：①parser 写入点护栏（`vc >= MAX_ENUM_VARIANTS` / `tc >= MAX_VARIANT_TYPES` ⇒ `P0xx` 硬错 rc=1，绝不静默；唯一写点收口照 #8 的 `fi_param_type`/`fi_set_param_type` 式）；②访问器侧护栏（`ei_variant_*` 读写加范围闸）；③**先 report-only** 全语料（当前 72 档零命中）。**同族**：MAX_GENERICS=4（#33 登记②）、#8（16 槽形参区）——统一「先加护栏、再评估解除」。
- **关联**：计划附录 B.4-7（登记面；「静默」措辞已按本条两面实测修正）+ B.7（一等条目：可选表示缺口）；出处 = `.superpowers/sdd/p3-task4-report.md` §7-⑥。

### 36. R2 P3b Task 0 落地（2026-09-12——`iface_satisfies` 契约交付：轴分派/三态/首个消费者；**P3b 唯一阻塞解除**，含未覆盖面登记）
- **交付面（P2b 交接契约 ① 的落地；计划 = `docs/superpowers/plans/2026-09-11-r2-p3-capabilities.md` 附录 B.1）**：`iface_satisfies(t_ti, iface_ni)`（`src/compiler/type_engine.cr`）= **原生/横切/用户三类同入口**，三态 1/0/-1 + 每查询预算隔离（照 `type_equal_engine`/`gen_constr_satisfied`）。轴分派 = **A 横切形状名**（`iface_shape_*` 表，本批**空表** → 恒未命中；条目细化归 Task 2 Step 1）→ **C 用户接口**（`find_iface` 命中：① 形状项路由 `sh_iface_shape_term`（Task 6 落地前恒 -1）→ ② 结构谓词 `iface_user_satisfies`）→ **B 本质轴**（= P3a `gen_constr_satisfied` 引擎面逐字同口径，迁移到统一入口）。轴优先序 A > C > B（同名撞车时：形状优先；原生名 vs 接口名**保持 P3a 现状 = 接口优先**，selftest `isat.axis_order_*` 两例钉死）。
- **首个消费者（P3a 接线点换位）**：① `gen_constr_satisfied` 首分支（函数调用点）——**1 提前返回**，0/-1 一律回落既有 `check_iface` 名拼接路径（**措辞/去重/rc 逐字未动**；0 → 新措辞的切换归 Task 6 Step 3）；② **新消费者** `gen_inst_constr_satisfied`（结构/枚举实例化点）——**直取真值** ⇒ `T: I` 在实例化点**真判定**（P3a 登记面关闭）。谓词 = **与 `check_iface` 同源**（方法名在位 + 参数计数 + 返回码），域 = 命名行（`TYP_NAMED` / `TYP_GENERIC_APPLY` 基名）；非命名行/dyn/泛型形参 ⇒ **-1 不判**（绝不「查不到即 0」）。判定路径**零 `str_intern`**（走 `g_methods` 三元组查名，不构造 `"T.m"` 串——`.ccr` STR 段守卫，selftest `isat.no_str_intern_on_missing` 钉死）。
- **收紧台账（旧 → 新；全语料 72 档零命中，同源对拍旧/新逐字节同）**：结构/枚举实例化点「接口约束违反」由 **rc=0 零诊断** ⇒ **check rc=1 + `error[TG02]` + `does not satisfy interface 'I'`**（措辞与既有函数调用点路径一致；TG02 软诊断——check rc=1 / build rc=0 + 产物照出，与既有约束检查同门同码，**未新增硬门**）。逐例 = `test_iface_satisfies.py` 6 条（缺方法/计数不符/返回码不符/枚举侧/多方法半实现/第二接口）；`test_generic_constr.py::struct_iface_constr_unjudged`（P3a 的「不判」钉）按台账改为 `..._violated`（rc=1）+ 新增正控 `..._present_accepted`。**未覆盖面（登记，非漏放）**：接口签名槽 = **映射层编码**（parser 两侧同取 `unpack_type`/`ast_type_val`，非原生类型节点一律塌缩为码 0 = `TY_INT`，`self`/`&self` 槽两侧均写码 0）⇒ 逐参数类型不参与判定、返回码语义 = 编码相等（`inst_encoding_limit_named_ret_pinned` 钉住现状）；**解锁 = Task 6 Step 1 签名类型项化**后由形状项包含判定取代（`iface_satisfies` 轴 C ① 的路由已是切换点）。
- **判据（详版 = `.superpowers/sdd/p3b-task0-report.md`）**：`selftest-types` **304/304**（288 → +16 `isat.*`：轴分派 4 / 三态 3 / 谓词对拍 1 / 零驻留 1 / 形状表 3 / 空接口 1 / 泛型应用 1 / 预算隔离 1）+ 新套件 `tests/selfhost/test_iface_satisfies.py` 17 例（已挂 `run.sh` selfhost-tests）+ `test_iface_ops` 76/76 · `test_generic_constr` 15/15 · `test_match_exhaust` 16/16 · `test_optional` 12/12 · `test_impl` 7/7；ELF canary 逐字节同 + 同源对拍零差异 + 影子全计数 0（站点覆盖同报）+ 突变控制（逐条咬合 + 复位后二进制逐字节复原）+ 全回归 + 自举链。
- **P3b 剩余（未开工，阻塞已解除）**：Task 2 横切接口（形状条目细化 = 注册进本批的 `iface_shape_*` 表 + 索引/切片/迭代消费点换位）· Task 6 impl 契约（签名类型项化 + `check_iface`/`check_impl_for` 接引擎 + mangling 退役 + `sh_iface_shape_term` 建形状项）· 函数调用点的 0 → 新措辞切换（Task 6 Step 3）。
- **关联**：计划附录 B.1（本批解除唯一阻塞项）/ B.2（收紧台账追加）/ B.4-1（`save_func_gen_constrs` 稀疏零初值——**未触发**：本批未动 `infer_gen_call` 的约束循环）/ B.4-3（命名实参 vs 原生约束 = -1，同族未覆盖面）；出处 = P3b Task 0 报告。

### 37. R2 P3b Task 2 落地（2026-09-12——横切接口接线：六条形状项 + 索引/切片消费点换位；**行为保持**，含未覆盖面登记）
- **交付面（计划 Task 2 Step 1/3）**：① **形状条目（Step 1）**=`src/compiler/iface_registry.cr` 横切形状段六条构造器——`sh_shape_seq`（序列接口 = `⊤ₖ(AK_SEQUENCE)`）、`sh_shape_seq_ro`（只读序列 = 序列本体 ∪ `&[⊤ₖ(SEQ)]`，只读视图由 **AK_REF 协变槽**判定 = 「只读 = 协变」兑现；T1 §6-④ 登记的「只读序列形状」在视图面闭合）、`sh_shape_seq_rw`（可写序列 = 序列本体；拒绝只读视图）、`sh_shape_indexable`（可索引 = `⊤ₖ(SEQ) ∪ ⊤ₖ(STRING)`，与 IP_INDEX 许可集逐行同集）、`sh_shape_iterable`（可迭代 = 序列；字符串不宣称——迭代面无类型检查代码面证据）、`sh_shape_product`（= `⊤ₖ(AK_PRODUCT)`）。**⊤ₖ 形是硬约束**：`sequence<⊤>` 参数链在不变槽落 -1（Task 0 §1.3 勘误；`x2.fixedness_not_in_shape_judgment` 反向钉住「固定性不入形状判定」）。② **消费点换位（Step 3）**=`src/compiler/checker.cr` 索引兜底门（`iface_permits(iface_kind_of(ti), IP_INDEX)` → `iface_satisfies_term(ti, sh_shape_indexable())`）与 range 分支类别判定（`arr_kind == TYP_ARRAY` → 序列形状 ∧ **固定性位**取自序列项 b 槽 `sh_seq_fixed_len_of_ti`）；结果三分支（arr→元素+F2 / slice→元素 / str→int）**原地保留**（同时决定结果类型，A.2 #16-18）。**三态纪律**：形状 -1（不可译行）**不**折算，回落既有判定（索引门回落许可表 / range 回落 kind 直比）。
- **行为保持（本任务主判据；旧二进制 = P3b Task 0 基线 `aa54d26a` 构建）**：新套件 `tests/selfhost/test_xcut_iface.py` 12 例**两二进制逐例同**（正例三路同证 arr/slice/str 索引 + range 产视图 5 例；TK01 软诊断负例 int/bool/ptr/struct 4 例 + range 切片分支 unit 钉子 1 例；F2 字面量越界 / F11 切片界**硬错误**钉子 2 例）；全语料 72 档 check 面**零差异**（rc + 诊断码集合）；ELF canary `95084e7b…d475` 逐字节同；`.ccr` `54e3856b383301be…`（88943B）逐字节同 ⇒ 零 STR 段增长（形状项只进类型项 DAG，**零 `str_intern`**，`x2.no_str_intern` 钉死）。
- **收紧/放宽台账**：**收紧 0 · 放宽 0**（本任务为换位批，无新诊断、无新硬门 ⇒ 计划 Global Constraints 第 6 条的 report-only 前置未被触发；range 分支的切片→unit 现状（A.2 #15，未接线）**保持**，其收紧 knob 仍登记）。
- **未覆盖面（登记，非漏放）**：① 可写**视图**形状不可表达（`ref(mut=1, ⊤ₖ(SEQ))` ⇒ 不变槽遇 ⊤ 落 **-1**，`x2.rw_view_unexpressible` 钉死三态）；② 形状**名字面生产路径不注册**（注册名 = 驻留 ni；初始化路径 `str_intern` 会令 `.ccr` STR 段增长 = A.3-② 硬约束 ⇒ 命名消费语法 `T: 可索引` 待命名裁决；本批消费者皆为**无名字**消费点，走 `iface_satisfies_term`）；③ `可迭代` 面未接线（checker 的 `EXPR_FOR` 现状零类型检查）；④ 用户接口形状项仍不可展开（`sh_iface_shape_term` 恒 -1 = Task 6 Step 1）。
- **判据（详版 = `.superpowers/sdd/p3b-task2-report.md`）**：`selftest-types` **319/319**（304 → +15 `x2.*`：形状满足 7 + 逐行枚举等价 2 + 注册/复位 2 + 零驻留 1 + 三态 1 + 接口面 1 + 固定性判定面 1）+ 新套件 12 例挂 `run.sh`；`test_iface_ops` 76/76 · `test_iface_satisfies` 17/17 · `test_generic_constr` 15/15 · `test_match_exhaust` 16/16 · `test_optional` 12/12 · `test_impl` 7/7；全语料零差异 + 影子对拍 + 五 CI job + 更宽 selfhost 枚举 + 突变控制（注入 → 预测用例红 → 复位二进制逐字节复原）；ELF/`.ccr` 逐字节同。
- **关联**：计划附录 B.1（Task 2 条目状态更新）/ B.4-16（只读序列视图第二层协变——本批在**形状面**闭合，序列构造子自身仍不变）/ B.4-19（性能面：本批把判定面接到索引热路径 ⇒ 编译耗时实测登记）；出处 = P3b Task 2 报告。

### 38. R2 P3b Task 6 落地（2026-09-12——impl 契约：签名类型项化 + 形状项逐成员判定 + mangling 退役；含两处裁决与未覆盖面登记）
- **交付面（计划 Task 6 Step 1/3）**：① **签名类型项化（Step 1）**=`g_ifaces` 方法条目新增类型**节点**槽（`OFF_IFM_PARAM_NODES` / `OFF_IFM_RET_NODE` / `OFF_IFM_SELF_MODE`；`ESZ_IFMETHOD` 88→168、`ESZ_IFACEINFO` 1432→2712——**不入 `.ccr` 序列化**，实测逐字节同）+ parser 写点；裸码槽**保留**（S6 站点返回型映射的值域 = 映射层编码，P2b 已显式化钉住）；参数裸码槽自本批起**零读者**（登记：参数码面由节点取代）。② **满足判定接引擎 + mangling 退役（Step 3）**：方法解析改 `g_methods` 表查询（`type_has_method` / `check_iface` / `check_impl_for` / 泛型约束路径全走 `iface_find_method`；**零 `str_intern`**——旧 `type_has_method` 对缺失名会增长驻留表）；`sh_iface_shape_term` 建**形状项**（方法集 = product of fn，b 槽 = 方法名）；判定 = **逐成员包含**（方法名表查询 + 接收者模式显式比较 + 签名 fn 项经引擎结构比较原语 `tt_list_same`）。**为何不用整形状 `ty_sub`**（实测两条）：引擎对 `AK_NAMED` 不展开（P0 未覆盖面②）⇒ 命名行实参与 product 形状恒 -1（负例会静默降级「不判」）；product 的引擎比较是结构相等而非子集包含 ⇒ 带额外方法的实现方被误拒。**为何不用 `ty_sub` 做逐成员签名比较**：引擎把不变槽的「确定不同」上抛为 **-1**（`tt_list_variance_at` 分支），直接消费会让签名不符退化为「不判」= 静默通过面复活（突变 M3b 实证：8 自测例 + 3 行为例红）；签名项为**规范形**（N 不入项 / 泛型应用展开 / 命名行按名）⇒ 同型恒同节点、异型恒异节点 ⇒ `tt_list_same`（0/1 全域）即正确判据。
- **两处裁决（本批作出，均登记为语言设计面）**：① **用户轴保持结构口径**（方法集包含），**不**采纳 spec §2.3 的**名义口径**（`impl I for T` 声明即满足）——采纳会翻转既有钉死用例（`test_generic_constr.py::iface_constr_legacy_pass`、`test_iface_satisfies.py` 的固有 impl 正例 5+ 例），且属语义争议（spec §0 裁决 6：停下上报）；名义化 = 语言设计决策，须维护者裁。② **形状名字面生产路径仍不注册**（Task 2 登记项延续）：接口形状项按**接口自身名 ni** 建（parser 已驻留），零新串 ⇒ 无 `.ccr` STR 段增长；命名消费语法（`T: 可索引`）仍待裁决。
- **收紧台账（旧 = Task 2 基线二进制 `/tmp/p3b2_pre_mut_corec` 逐例实测；新套件 20 例：旧 14/20 → 新 20/20）**：签名面 4 条（**参数类型**命名型不符 / **返回类型**命名型 vs 原生 / **泛型应用实参**不符 / **接收者模式**不符）由 rc=0 零诊断 ⇒ rc=1 + TG02；`test_iface_satisfies.py::inst_encoding_limit_named_ret_pinned`（编码面判「满足」）按台账改为 `..._rejected`（rc=1 + TG02）。**放宽 0**。**崩溃修复（台账外，同一任务收益）**：泛型体内方法调用（`fn f[T: I]` 的 `x.m()`）旧态 = 合成 `"T.m"` 串 + 克隆期文本替换 ⇒ 实例体调用目标悬空，**产物运行 rc=139**（build rc=0）⇒ 本批改为实例化时按具体类型**查表解析**（`CALL_FLAG_IFACE_METHOD` + monomorph 的 EXPR_CALL 克隆分支）⇒ 运行 rc=N（正确值；两例实测 7/9）。**解释器面登记**：`corec run` 的解析面不支持方法调用语句（旧二进制同 rc=1，非本批引入）⇒ 该两例走 check + ELF 两路。
- **未覆盖面（登记，非漏放）**：① **上限保留**（`MAX_IFACE_METHODS=16` / `MAX_IFACE_METHOD_PARAMS=8`；超限 = **硬错 rc=1**，非静默截断——新套件两例钉死；解除需方法表迁侧表，按 B.4-7「先加护栏、再评估解除」口径）；② **接口泛型形参**仍被 parser 丢弃（`interface I[T]` ⇒ 签名含形参行的匹配只在同一声明内成立）；③ `dyn` 位图行不入签名规范形（含 dyn 的签名 ⇒ -1 不判）；④ **变参签名**不可表达（⇒ -1）；⑤ 签名比较走 `type_equal` 之外的 `tt_list_same`（**不变**口径）；`&T` 协变等变型规则不在签名面（需要时另裁）；⑥ 运行期可选表示未统一（B.7 一等条目）未动；⑦ 泛型方法调用解析失败的兜底（形参未绑定/嵌套形参/具体类型无此方法）保持原状不发明目标（登记）。
- **判据（详版 = `.superpowers/sdd/p3b-task6-report.md`）**：`selftest-types` **333/333**（319 → +14 `ifc.*`：签名四维 + 形状项三面 + 表查询/同源/三态/零驻留）+ 新套件 `tests/selfhost/test_impl_iface.py` **20 例**（已挂 `run.sh` selfhost-tests）+ 既有套件全绿（`test_iface_ops` 76/76 · `test_iface_satisfies` 17/17（按台账改 1 例）· `test_xcut_iface` 12/12 · `test_generic_constr` 15/15 · `test_match_exhaust` 16/16 · `test_optional` 12/12 · `test_impl` 7/7）；**ELF canary `95084e7b…d475` IDENTICAL + `.ccr` 逐字节同（88943B/130974B）——类型层改动零泄漏发射面**；同源对拍（72 档 check 日志 `diff -r` 空）+ 影子对拍（30628/30628 agree，全计数 0；站点覆盖同报）+ 五 CI job（`check` = 既有 2 条 TF01 误报划界）+ 更宽 selfhost 枚举 45/45 + `test_backend_bootstrap` rc=0（附录 B.6 必含档）+ 突变控制 4 条（M1 应用展开 / M2 接收者模式 / M3b `tt_list_same`↔`ty_sub` / M4 monomorph 解析——**M4 为行为级独有牙**，如实登记）→ 复位后二进制逐字节复原。
- **关联**：计划 Task 6 + 附录 B.1（Task 6 条目）/ B.4-4（MAX_GENERICS 同族口径）/ B.4-6+B.7（可选表示一等缺口，未动）；出处 = P3b Task 6 报告。

### 39. R2 P3b 收官（2026-09-12——三件提交链 + 全量回归 + 统一台账 + P4 交接包；**P3 全阶段收官**）
- **交付链**：`9aa1786c`（Task 0b `iface_satisfies` 契约回补——P3b 唯一阻塞解除）→ `44100ba4`（Task 2 横切接口——六条形状项 + 索引/切片消费点换位；行为保持）→ `e838f18b`（Task 6 impl 契约——签名类型项化 + 形状项逐成员判定 + mangling 退役 + 泛型体内方法调用崩溃修复）+ 本收官提交。逐件详版 = **#36/#37/#38**。
- **全量回归（Task 7b 本轮实跑；cwd = 仓库根、`nice -n 19`、一构建一编译串行、比较前 `clean-cache`）**：五 CI job = `selfhost-tests` **rc=0**（21 套件：76/76 · 27/27 · 20/20 · 17/17 · 15/15 · 16/16 · 12/12 · 12/12 等）· `bootstrap-tests` **rc=0**（3 档 29+4+3 全 PASS）· `suite` **rc=0**（21 档 `.cr` 编译+运行全过；`*_mini*`/空 fixture 按既有规则跳过）· `full-bootstrap` **rc=0**（`corec2 == corec3` `cmp` IDENTICAL sha `03c9812fc735ec4b…` 双 2542222B + `--help` rc=1 既有约定）· `check` **rc=1 = 既有 red 划界**（`check src/compiler` 恰 **2 条 TF01 误报** `lits_copy`/`ty_memo_slot_no_grow`——check 命令按 F19 以非零反映任意诊断 ⇒ rc=1 由该既有误报产生，同源对拍两侧一致，非本批引入）【→ **2026-09-13 TF01 收口已修**（#40）：`check src/compiler` **rc=0**】；全枚举 **45 selfhost + 7 bootstrap 逐档 rc=0**（含 #31 未挂 CI 档，`test_backend_bootstrap` rc=0 = 附录 B.6 必含档）。
- **判据（本轮实跑）**：`clean-cache` → ELF canary `95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475` **IDENTICAL**；`corec2/corec3` `cmp` IDENTICAL + **N06=0**（两构建日志各 0 命中；日志 `error[` = 2 = 上述既有 TF01）+ 冒烟 `run 'fn main()->int{return 42;}'` **42**（corec/corec2 双通道）+ `corec3 --help` rc=1；`.ccr` = P3b 三件**零变更**（`ptr_arith` 88943B `54e3856b383301be…` / `generics_test` 130974B `97be2f9e7431fde5…`，与 Task 0/2/6 记录值逐字节同）；`selftest-types` **333/333**。
- **P3b 统一台账（收紧 10 / 放宽 0 / 崩溃修复 1；详版 = 计划 Task 7b）**：**T0 6**（实例化点 `T: I` 违反 rc=0 零诊断 → rc=1 + `error[TG02]`；旧 = P3a 收官构建）· **T2 0/0**（换位批：12 例探针老/新两二进制逐例同 + 72 档 check `diff -r` 空 + 影子旧×新同值）· **T6 4**（签名四维：参数类型/返回类型/应用实参/接收者模式 → rc=1 + TG02；旧 = Task 2 基线构建）+ 崩溃修复 1（泛型体内方法调用旧产物跑 rc=139 → 正确值 7/9）。**全语料零命中** + 同源对拍零差异（T0 30271 / T2 30400 / T6 30628 判定，全计数 0，站点覆盖同报）+ 突变控制 11 条（4+3+4）逐条咬合。**TG02 = 软诊断**（check rc=1 / build rc=0 + 产物照出）——P3b 未新增硬门。
- **P3 阶段总账（P3a + P3b）**：**合计 收紧 28 · 放宽 8 · 软诊断面 +1（TM04）· 实例名忠实化 6 · 挂死与崩溃修复 3 端**；五项目标能力（定长退役/序列接口/穷尽性·联合·可选/泛型约束/impl 契约）全部接通；`selftest-types` 95 → **333**；新套件 **6 个**（match_exhaust 16 · optional 12 · generic_constr 15 · iface_satisfies 17 · xcut_iface 12 · impl_iface 20）。判据面全程稳定：ELF canary IDENTICAL（全阶段）· 自举链 cmp/N06/冒烟（全阶段）· `.ccr` 变更面 = 仅 T4（STR −10B）与 T5（`generics_test` +370B 反折叠），P3b 三件零变更。
- **P4 交接（新；P4 无独立计划——实查）**：计划 **附录 C** = 载体盘点（类型项 DAG/`g_ifaces` 节点槽/形状表/`g_impl_for`/`g_methods` 全在进程内存、**零 `.ccr` 序列化**；`ccr_io.cr` 全文件 `iface`/`impl_for`/`g_methods` 命中 = 0）+ **加段四面**（`CCR_SEG_COUNT`/save/load 闸与标量族/`test_ccr_v7` 结构断言；tag 7+ 预留）+ **翻转钉 7 条** + **待裁决 8 条**（形状命名语法 + STR 段增长 · #38 名义 vs 结构 · 13 条表扩列 vs 引擎侧另表 · 整形状 `ty_sub` 路由 · B.7 可选表示 · MAX_* 统一处置 · `never`/符号档 · TK 升格发射面判据）。
- **未开工（终态；P3 未覆盖面）**：iterable 接线（`EXPR_FOR` 零类型检查，`checker.cr:2810-2821`）· 形状命名消费语法（`T: 可索引`）· 整形状 `ty_sub` 路由（实测不可用）· **#38**（用户轴名义 vs 结构，维护者裁）· B.7 可选表示统一（`Some` 臂双路径 rc=139）· **#32**（`EXPR_LET` 无检查）· **#35**（枚举写侧无护栏）· MAX_* 解除（MAX_GENERICS=4 等）。
- **关联**：#34（P3a 落地）· #36/#37/#38（P3b 三件详版）· 计划 Task 7b + 附录 C · spec §9 P3 行（本批更新为 P3a+P3b 双 ✅）；报告 = `.superpowers/sdd/p3b-task7-report.md`。

### 40. TF01 收口：`check src/compiler` 两条长期诊断（2026-09-13——落空分析 + `lits_copy` 类型洗白；**check 门 rc 归零 + P4 Task 2 corearch 清单步解阻**）
- **定性（探针实证，先于修复，旧二进制）**：`lits_copy` = **真·类型洗白**——`alloc` 类型模型 = `() -> string`（`checker.cr` `bi_add("alloc", TI_STR)`），声明 `-> int` 且 `return buf` ⇒ 与模型冲突；消费面（`r64(buf: string, …)`、`lits_contradictory_buf` 另一调用点传 `g_ty_lits : string`）全为字节缓冲 ⇒ 修 = 声明改 `string`（**不是**放宽 `alloc` 模型）。`ty_memo_slot_no_grow` = **checker 误报**——体以**无 break 的 loop** 收尾（只从体内 `return` 出）⇒ 永不落空，而站点 5 以「块末语句类型」判（`EXPR_LOOP` 恒 unit）⇒ 误报 TF01。
- **修法**：`checker.cr` 新增落空分析 `stmt_cannot_fall_through` + `loop_body_has_break` + `seg_has_break`（保守：只认**不产出值**的不可落空形态——无直系 break 的 loop / 双分支皆不可落空且有 else 的 if / STMT·UNSAFE·block 包裹；**`return` 不判 divergence**（其值类型正是站点 5 的被检对象）；break 扫描在嵌套循环处截断（break 归内层）、未枚举形态 fail-closed），站点 5 接线一行；`type_engine.cr` 两处签名改 `string`；`ty_shadow.cr` 头注改写（原文记载该误报面，被本 TODO/计划引用）。
- **判据**：`check src/compiler` **rc=0**（诊断 0 条）；构建 rc=0（GUARD clean：corec 45 / corearch **32** / corelsp 31）；`test_backend_bootstrap` rc=0（`error[`=0）；`selftest-types` **338/338**；ELF canary `95084e7b…d475` IDENTICAL（清单步前后各一次）；全枚举 **47 selfhost + 7 bootstrap 全 rc=0**；`full-bootstrap` rc=0（`corec2==corec3` `991eecc1…b2ba` 双 2604942B + N06=0 + 冒烟 42 + `--help` rc=1）；同源对拍（30 档语料 check 输出 + rc）**零差异**；突变控制 5 条逐条单点转红（过接受/过拒绝/嵌套截断/match 臂链/连续段）；新套件 `tests/selfhost/test_tf01_fallthrough.py` **19 例**挂 `src/ci/run.sh`。
- **附带**：`test_iface_ops` 3 条**过期期望**随批更新（少掉的 TF01 恰为同误报类、三条用例的关注面诊断原样保留（含行号）⇒ 76/76 复绿）；**P4 Task 2 §9-② 收口路径 (a) 兑现**——`type_engine.cr` 入 corearch 清单两面（31→32 文件），project-mode `error[`=0 门通过（`ty_sub` 族跨进程同值探针面解阻，消费者待接；corearch 二进制变大 = 死码，非判据面）。
- **登记（本批不修）**：① TF01 对 `build` **非致命**（含 TF01 的源 `corec build` rc=0 且照出可运行产物，实测）⇒ 本批收益面 = `check` 门（CI/工具链/清单门），非运行期行为；② `while <标识符> { … }` 被当**结构体字面量**解析（`parse_while_expr` 缺 `parse_if_expr` 同款 `g_parse_no_struct_literal` 守卫；旧二进制同款复现，既有）；③ 非落空体内 `return` 的**值类型**不核对（显式放宽面；逐 return 核对需重跑推断 = 副作用风险，本批不做；套件 `pos_boundary_no_return_value_check` 注释钉住边界）。
- **关联**：#39（P3b 收官——本批改写其「既有 red 划界」句）· spec `docs/superpowers/specs/2026-09-10-type-shadow-findings.md`（P2b 收紧清单句）· 计划 `docs/superpowers/plans/2026-09-12-r2-p4-carrier.md`（Task 2 §9-② / Task 7 Step 1）· 报告 = `.superpowers/sdd/tf01-cleanup-report.md`。

### 41. R2 P4 Task 3：IFACE 段内容落地（2026-09-13——扩列 16 + 形状命名化 + 签名项化 + impl 边/方法表 + corearch 读回）
- **交付**：本提交（路径限定 13 文件 = `src/compiler/{dyn_arr,iface_registry,checker,globals,ccr_types,ccr_io,main,corearch,type_selftest}.cr` + `tests/selfhost/test_ccr_types.py` + `src/ci/run.sh` + 格式 spec）。详版 = `.superpowers/sdd/p4-task3-report.md`。
- **段布局（D14 五小节；字段宽度逐条；实现权威 = `ccr_io.cr` 头注释 + spec §3.8）**：① 原生条目 **16 行 × 24B** `{ak i32, ti_row i32, name_ni i32, lit_code i32, ops i64}`；② 形状 **6 条 × 8B** `{name_ni i32, term i32}`；③ 用户接口 `{name_ni, method_count, generic_count, pad}` + 方法 **× 80B** `{name_ni, param_count, self_mode, ret_term, param_terms[8], param_codes[8]}`（**字段序取计划「声明行」序**——同块尺寸式两数组次序相反，实施登记）；④ impl 边 × 8B；⑤ 方法表 × 12B。实测：`ptr_arith` 452B · 夹具（2 接口/3 方法/1 impl）744B。
- **扩列（裁决 3 + 7）**：`IFACE_ENTRY_COUNT` 13 → **16**（+`AK_NULL`/`AK_SUM`/`AK_FN`，`ops = 0` = **纯信息面**）；`name_ni` 逐名注册（裁决 1 接受 STR 段增长——16 行名 + 4 形状独有名 = 20 名一表）；`iface_kind_of` **零改动**（判定面零变化由全类型行枚举 + `TYP_NULL/TYP_OPTIONAL` 行显式 -1 守门）。
- **形状命名化（裁决 1 + D17）**：六名（`sequence`/`sequence_ro`/`sequence_rw`/`indexable`/`iterable`/`product`）经 `iface_shape_builtin_init` 在 **`init_types` 尾部**注册 + D13 重建重跑；命名**消费语法**（`T: 可索引`）仍未开工（P3 遗留项）。
- **签名项化**：`sh_iface_sig_ret_term`/`sh_iface_sig_param_term` 按接口声明序装填进 `g_ifaces` 新槽（`OFF_IFM_PARAM_TERMS=168`/`OFF_IFM_RET_TERM=232`；`ESZ_IFMETHOD` 168→**240**、`ESZ_IFACEINFO` 2712→**3864**）；**不可建（`dyn` 位图行入签名）⇒ save 拒绝**（先 report-only：61 档零命中后开门）。
- **读回（corearch）**：五小节重建条目表（`g_iface_registry_ok=1` = **段为真源**）/形状表/接口表（corearch 无 AST ⇒ 节点槽恒 -1、**项槽 = 段值**）/impl 边/方法表；**跨段引用域闸**（`name_ni` 等 < STR 串数、`ti_row` < TYPE 行数、`term` < TYPE 项数）；`--dump-ifaces`（双侧共用打印路径）+ `ifaceprobe` 摘要 = 项索引在重建项表上的解析同值。
- **判据（最终二进制 `6da65418…`）**：构建 rc=0（三面 `error[`=0/undefined=0）· **`check src/compiler` rc=0** · `selftest-types` **338 → 347** · `test_ccr_types` **19 → 28**（T3 新 10 例 + 机制面重定）· ELF canary `95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475` **IDENTICAL** · 自举链 `corec2==corec3` cmp IDENTICAL（双 2737902B `55dc7cda…`）+ N06=0 + 冒烟 42（corec/corec2）+ `corec3 --help` rc=1 · **五 CI job 全 rc=0** + 全枚举 **54/54**（47 selfhost + 7 bootstrap）· 同源对拍 check 72 档 diff 空 + 影子 `decisions=32280=agree`（站点覆盖同报，两侧恒等）· report-only 61 档**零新增拒收** · 突变控制 **3 条逐条转红**（loader 闸关/签名装填跳过/init_types 注册缺失）。
- **`.ccr` 记录值（冷缓存；P3b/T2 值作废）**：`ptr_arith` 90823B `fb4a3b59103f4e0c…` · `generics_test` 134701B `cafb42781f8a4f9b…` · 自源（同源树）10418710B `3d6178130a88a518…`。**STR 增长实测**（裁决 1 的兑现面）：+16 串/+156B（`ptr_arith`）、+155B（`generics_test`）、**0**（自源——编译器源码已驻留全部 20 名）；**连带面**：新驻留名使「晚于 `init_types` 驻留」的串 ni 整体后移 ⇒ 用户程序 `.ccr` 的 SYM（名字列）与 NOD（`IR_CALL` 的 `src3` = callee ni）取值重编号（**布局不变、语义不变、ELF canary 不变**；自源前六段逐字节同）；TYPE 段 +360~400B（形状项在建项序前段）。
- **登记（本批不修/承接）**：① 方法记录字段序的计划文两处冲突（取声明行序）；② `ESZ_IFMETHOD`/`ESZ_IFACEINFO` 内存扩槽**不入盘、不入 `.cir` 快照**（快照字段清单核对 = vars/DF/SG/instrs/str_consts + 冷/暖两态一致复证）⇒ **不触发 `CIR_CACHE_VER`**；③ corearch 侧 IFACE 段仍**无判定消费者**（项槽/形状项的引擎消费 = P5 的 `atom_of` 承接面，`--dump-ifaces` 是当前唯一读回通道）；④ 签名编码面（`isat.axis_c_ret_code`/`inst_encoding_limit_named_ret_rejected`）按计划**只落证据、未改用例**（改动归 P5）；⑤ 未用形参项槽 = -1（写侧显式填 + loader 结构域接受）。
- **关联**：#40（check 门 rc=0——本批 `check` 判据口径由此更新）· #39（P3b 交接附录 C 的翻转钉逐条处置）· 计划 `docs/superpowers/plans/2026-09-12-r2-p4-carrier.md` Task 3 · spec `docs/superpowers/specs/2026-09-09-lattice-ir-v7-format.md` §3.8。

## 第四轮 CompCert 对照遗留项（2026-08-17 记）

来源：`docs/compcert-round4-findings.md`（F1-F20 修复后残留）+ 波 1-3 修复审查产出。F1-F20 已全部修复，以下为范围外/需 IR 形态演进的遗留项：

- ~~**M-2**：字符串索引 `s[5]` 静默 OOB（TI_STR 无检查）~~（2026-08-29 修变量下标路径 + 字符串读写按字节处理；2026-09-05 #61 收尾补全：常量下标路径 `emit_string_lit_bounds` 覆盖读/写/复合赋值三处——修复前 `s[9]` 常量越界静默；同时修复词法错误被 `parse_all()`/多轮 `tokenize()` 清零吞没的机制，溢出守卫等词法错误现正确上报）
- ~~**I-3**：模块别名导入断裂（`import fmt : f` / 模块限定调用生成对伪函数 "import" 的调用）~~（2026-08-29 已修：bootstrap 保留导入元数据并按 alias 解析限定调用；`tests/bootstrap/test_modules.py` 覆盖）
- ~~**lexer 字面量解析 2 项**：`2305843009213693952.0` 字面量解析为垃圾值（bi>53 时 pow2i(负数)=1）；>18 位整数部分静默截断~~（2026-08-29 已修：宽整数显式报错，宽小数避免负指数幂；`test_dex_type.py` 覆盖）
- ~~**Minor-2**：SPAWN 结果存储用 e2_st(rax) 非 e2_store_ret——float 返回值 spawn 存垃圾~~（2026-08-29 已修：IR_SPAWN 按返回类型保存 XMM0/rax）
- ~~**F11 切片长度**~~（2026-09-05 已修：字面量界原已完成——`g_ir_slice_lens` 侧表 + LET/赋值传播；同日补齐运行时界——`len = high − low` 长度变量登记（侧表编码：≥0 字面量 / ≤−2 长度变量 / −1 清除），沿赋值传播，解引用处发射动态 `IR_BOUNDS_CHECK`（ti=1，interp/ELF 零后端改动）；`tests/selfhost/test_slice_bounds.py` 7 用例覆盖——越界读/写/变量下标/空切片 trap，合法访问值与字面量界回归。来源：compcert-round4-findings.md F11 / 语义表 BC7）
- ~~**ccr v5 指令记录 i32 截断** ≥2³¹ 的 s3~~（2026-08-30 已修：`save_ccr` 对所有 i32 指令/region 字段做有符号范围校验，超界直接拒绝写出；`load_ccr` 对各段长度/计数做越界检查；`corearch` 拒绝无效文件大小；`test_ccr_writer_rejects_i32_overflow_inputs` 覆盖 writer guard）
- ~~**core_pattern 管道**致陷阱程序 core dump 挂起~~（2026-09-05 临时处理：`src/ci/run.sh` 全局 `ulimit -c 0`；trap 类测试内置 `RLIMIT_CORE=0`——test_slice_bounds / test_pointer_safety。机理：桌面 core_pattern = systemd-coredump 管道，SIGILL 后内核写 core 经管道唤醒服务，拥堵时进程挂起；GitHub CI 容器为文件 core_pattern 无此坑。根治方向 = 图推导边界判定 pass——可静态判定的越界前移为编译期拒绝，缩小运行时 trap 面，见下条目。来源：波 3 测试审查）
- ~~**BC-CONST**：interp TI_STR 字符串表索引近似~~（2026-08-29 已修：解释器统一用驻留索引传递字符串，补齐 `str_len`/`str_eq`/`concat`/`int_str`/`chr`/`get_char`/`str_sub` 与字节索引路径）

## 架构规划

### 指针安全模型
见 `docs/pointer-model.md`。裸指针 + HDFG provenance 推导，编译器自动验证，退路 `unsafe`。
三 pass：PointerAnalysis、RegionCheck、ProvenanceVerify — 全部实现。

### Arena 内存模型
见 `docs/memory-model.md`。已完整实现。堆按 HDFG 子图划分独立 Arena，指针碰撞分配，
游标重置回收。Arena 边界对应 HDFG 子图边界。

### 文档更新
- `docs/memory-model.md` — 设计文档（待同步实现细节）
- **docs 重组合并时的连带改点（2026-09-11 登记，`feature/docs-reorg` 已推送 `9eab0757` 待合）**：该分支把 `docs/error-codes.md` → `docs/developer/errors.md`、`docs/compcert-reference.md` → `docs/archive/compcert-reference.md`，故**合并该分支时必须同步两处 src 注释**：`src/compiler/ast.cr:315`、`src/compiler/ptr_analysis.cr:235`（在本线/当前 develop 上这两个路径**仍然正确**，故不在 docs 分支内改——避免把 src/ 拉进 docs 分支，也避免在本线留下悬空引用）。
- `docs/pointer-model.md` — 指针安全完整设计
- `docs/language-syntax.md` — 指针、@ 内建语法已更新
- `docs/at-intrinsics.md` — @ 内建原语完整规格

### 6. 同步源码修改到伪代码文档（2026-08-09 记）
- 背景：伪代码（docs/pseudocode/）基于源码快照翻译；以下源码变更后对应文档未同步
- 待同步清单：
  - `elf.cr` 编码修复（mov [r8],r10d → 45 89 10、BAD rip 检查白名单 0x48）→ elf-1.md / elf-4.md
  - `parser.cr` local_stmts 动态扩容 + parse_all 防死循环 → parser-1/2/3/4.md
  - `instr.cr` get_arg r10 push/pop 保护 → instr-2/3.md
  - `main.cr` 静态桥接桩发射逻辑 → arch main.md
  - `ptr_analysis.cr` 注释修正 → ptr_analysis.md
  - `lexer.cr` 浮点/`..` 范围修复（main 已有）→ 核对 lexer.md 是否已反映
- 完成后需重跑 `python3 tools/pseudocode_check.py` 并更新相应文档的源行数标注

### 7. 类型双关验证（2026-08-16 已修复）
- 类型双关保留，合法判据为 provenance + 字节偏移 + 访问宽度
- cast 通过有类型的 `IR_LOAD` 保留值流和 `asp`，不会断开 points-to 传播
- `IR_DEREF` / `IR_STORE_PTR` 统一执行 `off + width <= alloc_size`
- 整数转指针产生 `asp=1`，解引必须位于 `unsafe`
- 动态偏移使用 points-to 目标的实际 allocation base 生成 ELF 检查；多目标无法唯一定位基址时保守拒绝
- 回归见 `tests/selfhost/test_pointer_safety.py`

### 测试清单陈旧 + exists 静默跳过（2026-09-10 R1 Task 5 发现——**已修，登记备查同类面**；本小节编号系文档区既有序列，与「预存 Bug」区 #8 无关）
- **已修**：`tests/selfhost/test_compile.py` `concat_sources()` 原以 `if os.path.exists(path)` **静默跳过**缺失条目——三条 `src/compiler/backend/**`（x86_64.cr / x86_64/instr.cr / resolve.cr）自波 1 三轴搬迁后长期不存在，清单无声缺斤短两而测试始终「全绿」。现改为**存在性断言**（`build_selfhost_native.py` guard_manifest 同款，缺失即 rc=1；负对照实证有牙：插入伪路径 → 精确报出该条目名）。死条目已删，清单条目全部现存。
- **为何不补入三轴文件（实证）**：补入 `src/arch/x86_64/*` + `src/format/elf/*` + `src/os/linux/*` 后该单元缺 **68 个 HIT 引擎符号**（`src/arch/hit/hit.cr` / `lower_to_core.cr` 属独立清单段）——三轴文件归属 **corearch 编译单元**，本清单 = corec 前端单元闭包，故原为**刻意裁剪**（就地注释已写明归属）；已按 brief 的 fallback 分支处理（不硬塞、不静默跳过）。
- **同类面建议**：其余「文件清单 + exists 静默跳过」形态应同法改存在性断言（波 1 评审曾清点同类 rc-only 面：`test_mw_task2.py:172` / `test_compile.py:127` / `test_live_ranges.py:52,73` / `test_directory_build.py:50,80,100`——那是 rc 门面，本条是**清单完整性**面，二者互补）。

### 内存模型方向：能力 + 格（v4 发布，2026-08-27）
- 备忘：`docs/memory-model-capability-lattice.md`（v1 2026-08-16 → v2 2026-08-20 → v3 2026-08-26 → **v4 发布**；上下文包已删并入）
- **v4 定稿**：**规则封闭对象开放**（层规则零签名 = 缓存七条；对象无界；新范式三件事 = 图标注 / CIC 内部定义 / 硬件映射，无枚举）；**无格承诺**（格代数 = 映射参数，判定/定理只在关系层面）；**M1 定论：能力不提升一等公民**（语义还原图上：身份 = 图节点 / 无配方 = 标注 / 授权归治理层；可逆、暂不执行）；**M4 输入：图内不可重算条款**（已并入 memory-model.md 条款 4b）；**寄存器分配 = 缓存语义映射实例**（`docs/regalloc-cache-mapping.md` 正式参考 + `docs/superpowers/specs/2026-08-27-regalloc-cache-mapping-design.md` 设计记录）
- **三层映射正式晋升：图 → 格 → 编码**（2026-08-27 更名：原「二进制」硬编码经典惯例，零硬件惯例；编码 = 物理编码空间）
- 能力形态（v2/v3 保留，重定位治理层）：能力 = ⟨身份符号, 授权集, 域约束, 派生源⟩；结构 = 能力树（编译期兑现，运行期经典路径零新增）；代数 = PCM × 布尔格（经典行组织参数，非层本体承诺）
- **验证主线**：Graph → Lattice 映射通用性 8 项清单（备忘 §十二）——因果 / 非因果 / 模糊 / 非确定 / 并发异步 / 反馈 / 超图灵 / 格层不重引入顺序执行；v4 实证 = 寄存器分配判定以纯格对象写出（无路径结构）
- 待办：
  - 开放问题收敛（授权集完整枚举 / 可复制性规则 / 用户面句柄 / 分数权限 / 能力进规约 / 寄存器分配落地）
  - 记忆模型文档一致性复查（memory-model.md 并入条款 4b 后）
  - 寄存器分配实现规划：共存关系落定（图活性）→ 判定规约 → 贪心放置（opt.cr 升级）→ checker 自检
  - 实现规划（远期）：能力流分析（PointerAnalysis 推广）+ 三 pass 能力化重写——内存模型层面大改

### 格形态 IR 升级（C 路线）——**v6 主线 Task 1-6 完成（2026-09-06）**
- 设计：`docs/superpowers/specs/2026-08-27-lattice-form-ir-design.md` + 格式定稿 `specs/2026-09-05-lattice-ir-v6-format.md`（B 方向：存在结构主体；格层语义范式无关承诺/编码层字节 = hw-map 域，层定位补定）
- 命名已定案：方案 A（扩展名/magic/CLI 不动；.ccr = Core Region Representation）
- 事项完成核对：
  - ~~格式 v6 序列化/反序列化~~（2026-09 Task 4：段表架构 + ENT 28B 落盘，v6-only——v5→v6 转换工具按定稿取消：.ccr 中间产物零生态）
  - ~~存在结构段：条目版本/存在区间/共存/home/无配方标记~~（Task 1-3 数据面 + Task 4 落盘；无配方标记 = ENT flags bit0 字段就位）
  - ~~ELF 后端适配~~（v6 段表内 NOD 重建内存态，发射语义零改动；自举闭环 byte-identical 实证）
  - ~~CLI~~（方案 A：不动；corearch 加 --table/--dump-events 属 HIT 线）
  - ~~自举管线~~（v6 全程接管 build；bootstrap/corec/ir/ccr.py 不存在——.ccr 仅 self-hosted 读写）
  - ~~测试迁移~~（test_ccr_v6/region_cfg walker v6/全链回归）
  - ~~文档复核~~（coreir-schema/CLAUDE.md/project-book/compcert-reference 已按实现形状同步——Task 6）
  - ~~寄存器分配判定接入格形态~~（Task 5：regalloc-consistency.corespec 规约 + sweep 自检；**贪心放置 = 后续**——上下文贪心升级挂账）
- 后续挂账：SYM 归并/REG 坐标化（v6.0 保守路径，Task 4 评审 I-1）、ENT flags 无配方完整语义（条款 4b）、判定 R3/R4（驱逐配对/调用失效）

### 寄存器分配 = 缓存语义映射实例（落地，2026-08-27 记）
- 设计：`docs/regalloc-cache-mapping.md`（正式参考）+ `docs/superpowers/specs/2026-08-27-regalloc-cache-mapping-design.md`（设计记录）——分配 = 格 → 编码的映射实例（条款 7）；驱逐不变量 = order-free 语义保持；判定单层、分配算法定案 = 上下文贪心（零证明）
- 执行人：第二维护者（TODO 横向扩展）；验证闭环：DslsDZC
- 事项：
  - 共存关系落定：图活性存活区间相交（复用 RegionCheck cur_seq/exit_seq 机制）；条目版本（IR_STORE 切分）的图表示确认
  - 判定规约：一致性四条（共存互斥 / 读点无陈旧 / 驱逐配对 / 调用失效）写成 .corespec（先规格后实现）
  - 贪心放置策略：版本区间 + 共存检查 + 驱逐写回（`opt.cr` alloc_registers 增量升级；解锁 caller-saved = 调用点失效契约落地）
  - 无配方条目规则：边界 + 图内不可重算必须有 home、驱逐必写回（memory-model 条款 4b 落地）
  - checker：编译期一致性自检（debug 全开，release 可选）
  - 格形态接入：存在区间/共存消费（格形态 v6 落地后，见「格形态 IR 升级」节）
  - （远期）证书层：最优性证书（DP 表重放或 ILP 对偶）——验证「最优」而不只是「一致」

### LSP 生产化（2026-08-28 定稿，五问决策）
- 设计：`docs/superpowers/specs/2026-08-28-lsp-production-design.md`——Zed 优先 / 混合数据通道（LSP 承载渲染 + coreview 独立查看器）/ 分阶段架构（闭包级 → 项目级）/ corelsp 增量演进
- 执行人：第二维护者（TODO 横向扩展）；验证闭环：DslsDZC
- **P0（现在，闭包级）**：
  - session.cr 策略接口（文件级/闭包级/项目级三实现共用，rpc/lsp 层只面对接口）
  - ClosureSession：import 闭包检查（复用 res_imports）——消除跨文件 Undefined name 假错误
  - 错误恢复（diag 机制补全，parser 崩一处不拖垮整文件）
  - hover 富内容 v1：指针 points-to（闭包近似，复用 ptr_analysis）/ 配方（值 = 产生节点）/ 范式标注（region 种类）
  - inlay hints v1：赋值版本链（条款 5 版本化）
  - 诊断增强：unsafe/例外入口区域标记（CORE-E 代码分类）
  - 协议测试扩展（富内容/inlay/诊断 code）+ Zed 端到端验证（验收：日常写 Core 无假错误 + 指针 hover 可用）
- **P1（格形态 v6 后，项目级）**：
  - coreview v1（Web 查看器：HDFG 图视图 DFNode/DFEdge + region + state edges；管线探索器源码↔AST↔HDFG↔格形态↔汇编；数据源 corec cir/ccr dump）
  - ProjectSession：全项目编译 + 三 pass + 图构建 + 缓存失效（增量/失效传播）
  - 增量同步（textDocumentSync=2）
  - hover v2：证明状态（#check/#ensure）/ 精确 pts
  - rename / code actions / workspace symbol / references
- **P2（随主线）**：
  - 惰性显示（inlay，依赖惰性分析落地）
  - 寄存器/驱逐显示（依赖分配器实现）
  - spec-aware LSP（hover 规约/反例落源码，依赖验证管线——翻译桥/CIC）
  - coreview 联动（代码 ↔ 图双向高亮）
  - VS Code 客户端（协议层已编辑器无关）

### 设计定稿待实现（补挂账，2026-08-28 审计）
- **概率性 pass**（probabilistic-pass，2026-07-30 已批准）：src/ 零实现，仅文档（`docs/probabilistic.md`）——范式相关，优先级低，待排期
- **硬件映射表**（hw-map，2026-08-23 已批准）：MMIO 设备语义表 + 投影表——crasm 依赖已解除（2026-09-05 crasm 退役）；与硬件接口表（HIT）同族——HIT = 指令/运行层接口（`specs/2026-09-05-hardware-interface-table.md`），hw-map = 设备层接口，同构（语义表范式无关 + 投影表实例）。实现仍待排期。关联 `docs/superpowers/specs/2026-08-23-hw-map-design.md`
- **平台桥抽象**（platform-abstract，2026-08-16 定案）：设计定案待实现——语义接口 + 后端实现原则；程序 IO = 流转导器。关联 `docs/superpowers/specs/2026-08-16-platform-abstract-design.md`
- ~~**错误码体系**（error-codes，2026-08-08 已批准）~~（2026-09-05 复核：体系完整——ast.cr 定义 `EC_R_*`，checker.cr:2080/2095 发射 R002（编译期越界），main.cr:148 硬错误路径（R002/TK05/TK06 拦编译），diag.cr `error_cat_prefix`/`pad_diag_num` 完整打印 R001-R004；BC17「全仓库无引用」为历史旧况，已过时）
- ~~**裸指针 asp 标记**（bare-ptr-model）~~（2026-09-05 落点核实：ir_gen.cr:2111-2117 整数转指针 asp=1 且从 `source_ti` 的 type extra 继承/清零，checker.cr:2244-2246 同步——与 pointer-model 设计一致）
- **dex 任意精度精确小数未实现**（dex-precision，2026-08-28 审计）：设计 = 无上限小数位精确小数；实现 = 定点 S=10⁶（`src/stdlib/dex.cr:3-18`，注释「定点方案（执行时定稿，2026-08-16）」）——6 位小数 + int64 硬上限（加减 ≤9.2e12、乘 |a|·|b| ≤9.2e6）；设计意图与实现为语义级偏差。修复方向 = 动态位数表示（任意精度运算，重活，排期）
- **apx 降级策略被实现为报错**（apx-degrade，2026-08-28 审计）：设计 = 只支持精确的环境直接忽略 apx 标签、走精确语义（优雅降级）；实现 = 解释器对 apx 的 I2F/F2I 显式报错（`src/stdlib/dex.cr:32-33`；报错本身是 Task 6 安全修复——替代静默跳过致 SIGFPE，但方向与设计相悖）。修复方向 = 解释器忽略 apx 标签走精确路径。注：apx 结果跨环境可不同（native 走 binary64），为标签显式代价，账本如实记录
- **宽度类型移出语言**（width-out-of-language，2026-08-30 定案）：设计决定——int 无上限为默认（已定）；宽度（i64/u32/w32 等）不进入语言类型/标签体系，避免第二标签范式（单标签单范式原则）；机器形状全部归 hw-map/硬件接口表（`docs/superpowers/specs/2026-08-23-hw-map-design.md` 设备层 + `specs/2026-09-05-hardware-interface-table.md` 指令/运行层；crasm 退役后链式阻塞解除）；apx 保持单一语义 = 精度降级开关，不扩张为宽度标签。三层映射对应：图/格 = 纯数学，编码 = hw-map 领域。语言侧清理（不阻塞，可立即做）——**✅ 2026-09-10 语言面收窄 R1 全部完成**：~~ast.cr `T_INT_I8..T_INT_U64` / `T_FLOAT_F32/F64` 死条目移除（勿重编号）~~（落点 ce3e541c——ast.cr 墓碑注释 + `W_*` 值域 + parser 两处死分支）、~~`_f32/_f64` 后缀死路径处理~~（落点 51d74be3——侦查裁决 = 纯机器宽度 → 退役并响亮报错；后缀位宽在词法层即丢弃、data 槽恒 0，无语言语义承载）、~~`1_000` 两编译器分歧复核~~（落点 51d74be3——`_` 分隔符不支持，bootstrap/self-hosted **统一响亮报错**：原 self-hosted 静默消费成值 0、bootstrap 静默接受成 1000，双向皆错；新增 `tests/selfhost/test_lexer_parity.py`）；v6 规格影响：编码层宽度由目标自动决定，hw-map 为未来显式控制通道（v6 格式规格先行更新）
- **定长数组裁决**（fixed-array-retire，2026-09-10 用户拍板）：`[T; N]` **退役类型构造器身份、保留为「内联容量存储」表示提示**（语义归处 = product / 序列接口 + 长度 where / 图 F11 长度来源链；表示层归处 = 映射参数，与 hw-map 同层）；自举 10 处用法零改造。**R1 已办（2026-09-10）**：裁决注记（aa76f7f5——ast/checker/parser 七处「表示层概念」注释，零行为）+ 全局定长路径修复（71cb6278，见下行「全局初始化机制」）。**未办 = 类型身份退役本身**：`[T; N]` 从类型相等/子类型判定中降格 = **接口化轮 R2 落实**（checker 类型判定重做时自然剔除——R1 明确不做）。设计见 `docs/superpowers/specs/2026-09-10-language-surface-narrowing-design.md`（状态 = 已实施（R1））。**✅ R2 P3a 已办（2026-09-12，Task 1 `ef61f002`；TODO #34）**：N 与「固定/视图」维度**已从等价身份剔除**、入**变型/方向**规则——`ty_variance_of`（只读协变 / 可写不变 / 表外默认不变）+ `array_len_constraint_ok` 方向档（`[T;N] <: [T]` 放行、**视图→固定拒绝**、异长常量档拒绝）；`&T`/`&mut T` 进参数链（mut = 等式判定维度）；「切片→固定长」静默放宽关闭（P2a 洞，收紧清单 T1-1~T1-6）；自举 10 处 `[T;N]` 零改造复验（全语料零命中）。**剩余面** = 符号档长度约束（VC 义务，显式登记不实现——计划 §侦查 3 裁决）+ `EXPR_LET` 站点无检查（另立 #32）
- **全局初始化机制**（global-init，2026-09-10 R1 Task 4 落地 71cb6278）：文件级全局的运行期初始化 = **main 序言 IR 注入**（需运行期初始化的全局：聚合 / 非常量初值 → `alloc + 逐元素/求值存 + 写槽` 序列）+ **解释器常量阶段**（标量常量初值）。两路径语义一致（判据 `tests/selfhost/test_global_init.py` 15 例双路径精确 rc）。原缺陷：`[T; N]` 全局 run rc=139（SIGSEGV）或静默 0；同面根因四修 = ELF 字段访问全局基址（`e2_load_var` 规约，原读栈垃圾）/ 解释器 callee 内联缺聚合族 opcode / callee 返回值暂存槽覆写首个全局 / 类型别名一层解析。**约束**：注入点选 main 序言的理由 = 无新 IR 函数 / 无 .ccr 段变更 / 无 `_start` 字节扰动——**未来若支持非 main 入口或库形态，须迁移到独立 init 区**（届时本条目的注入点假设失效）。**缓存交叉引用（终审提示，2026-09-11 随 TODO #5 修订）**：注入点在 `ir_gen_func(main)`，而函数命中 cir 缓存时根本不走该函数（`main.cr` cache-hit 分支）——**同二进制内**命中恢复的是注入后的快照（含注入），无碍；**跨编译器升级面已随 TODO #5 修复关闭**（提交 `3be4cb48`：头部编译器身份字段 = 运行中 ELF 内容哈希 ⇒ 重建后旧条目自动 miss，不再依赖人工 `clean-cache` 兜底。批前该场景本就 139，非回归）；比较 `.ccr` 前仍须 `clean-cache`（理由改由 #5 末条承担：冷/热缓存态 `.ccr` 分歧未修）
  - **记录（Task 4 评审 Minor，不修）**：① Task 4 报告 §6.5 称注入在 `g_cur_ret_ti = ret_ti` **之后**，实际在**之前**（`ir_gen.cr:2282`，= brief 指定位置）——报告措辞与代码不符（读码无歧义，代码正确、报告笔误）；② `alloc_type(TYP_ARRAY, TI_INT, cnt)` 硬编码元素类型 `TI_INT`（无观测差异——当前元素尺寸恒 8；未来出现非 8 字节元素类型时需参数化）
- **类型系统方向定案**（type-system-direction，2026-08-30 定稿）：图本体 + 接口统一总纲——图 = 唯一真相层（类型 = 图标注、接口 = 图上契约、类型检查 = 图良构性验证 pass，与指针三 pass 同级）；接口注册表（int/dex/string = 原生接口条目，规则内建、公理引用规约层、用户不可实现）；where 值约束三档语义（常量→编译错误 / 符号→VC / 动态→运行时检查）；泛型 = 编译期接口具体化（无运行期字典）；宽度移出语言（见 width-out-of-language）。损失账本（免费午餐债 5 项）+ 演进顺序（where 值约束 → 泛型=编译期接口 → 验证切片 → v6 格形态 → 类型概念收敛，两条根基革命不得同时进行）+ 学术支撑（PLDI 2025 Webs 平行印证、语义子类型 = 完整补偿、ISO TS 6010 provenance 对齐）详见 `docs/superpowers/specs/2026-08-30-type-system-direction-design.md`
- **边界判定图 pass**（bounds-inference，2026-09-05 挂账）：在 HDFG 上做下标/切片长度的符号传播 pass（与指针三 pass 同级）——idx 来源链 + slice 长度来源链（F11 侧表传播的图化升级）：证明恒安全 → 不发射检查（零成本）；证明恒越界 → 编译期 R002 拒绝；证明不了 → 保留运行时检查并带图推导必要性标注。目标：运行时 trap 面最小化（trap = 推导不出才留的兜底，兼作验证证据）；核心_pattern 桌面挂起坑的根治方向（见 :125 划销注）。现状基础：pass_before_array_access/ext_safety 检查发射钩子、slice_len 侧表（字面量/长度变量编码）、checker R002 编译期越界
## HIT 最小核（2026-09-06 M1 完成 → M2 挂账）

硬件接口表（`docs/superpowers/specs/2026-09-05-hardware-interface-table.md`）M1 最小核运行闭环已完成：表文件/解析（`src/arch/hit/`）、表驱动编码器（`emit_instr_tabled` 预检+分层）、合成层（IR 直线子集 → 4 核事件流 + 常量池，add→sub 反减）、冒烟闭环（sub/add/mem exit 2/12/5，9/9 测试）。

**M2 挂账**：
- 控制流/函数调用/移位/乘除等全 op 合成（M1 子集边界 = main 入口函数；stdlib 闭包辅助函数现走旧路径混合模式）
- nand 真语义（x86 and+not 两步序列投影）——现单步 and 占位；and→nand/or 合成规则（源语言无位与/或运算符载体）
- ~~`--table` × `--link/--shared` 组合~~（2026-09-06 已处理：显式拒绝 stderr+exit 1——test_hit_table 三形态覆盖）
- 全量切换：无 --table 旧路径退役（emit 循环门控翻转）
- corec build 透传 `--table`；事件流/表数据入 v6 段（NOD op ↔ HIT event_id 对齐）
- M2 挂账细节（2026-09-06 已清 3/4）：~~hit_w32 负值哨兵~~（存 0）、~~add 反减 dest-fresh 前提~~（d==s1 落 0 事件防御）、~~'events emitted' 计数改名~~；**负值/宽常量池载体**（仍待——M1 冒烟无负常量形态）

## int 多字 M1（2026-09-07 M1 完成 → M2 挂账）

int 无上限语义（`docs/superpowers/specs/2026-09-06-int-unbounded-semantics.md`）的编码层投影 M1 已完成：add/sub 溢出全链——64 位快路径零开销直算 + jo 溢出检测 → 自动提升固定 2-limb（128 位）多字表示（tagged 槽：快值/堆对象指针 + 帧 tag 字节；tag 卫生四类定值点；128 位混合算术/比较；return 确定性截断语义）。实施 plan `docs/superpowers/plans/2026-09-06-int-multiword-m1.md` 六任务收官，设计定稿 `docs/superpowers/specs/2026-09-06-int-multiword-backend-design.md`（§8 M2 挂账全文）；快路径零变化：64 位内程序逐字节不变（test_mw_task2 z 用例 + backend_bootstrap stage1→3 byte-identical）；测试 `tests/selfhost/test_mw_task{1..6}.py`（含 i64max±1 边界套件）全绿。

**M2 挂账**（摘要——细节见 spec §8）：
- mul/div 溢出链与 2L 参与（M1 只 add/sub）；UOP_NEG −2^63 环绕链
- 2L 值打印（int_str 超 64）
- D4：超 64 编译期常量（IR_CONST 64 位槽 = 格层表示，需 v6 常量段——与 dex 精度同族）；超 128 码域动态增长（现编码层限制错）
- return 全 128 内部传递（现确定性截断低 64）；出逃写/跨函数 2L（全局/堆/数组）
- D1c 静态区间证明免 tag（保守 tagged 集：每变量行 1B tag + 每站 jo 6B + 块 ~45-160B）
- 共享块/模板压缩（函数尾冷区线性增长，非正确性项）
- 表（HIT）模式 × 运行时 2L 组合验证（tagged 路径整条落旧路径——语义正确未验组合）
- arena 生命周期债（2L 对象跨 arena_reset 悬挂；正确方向 = 永久 bump 或跨 reset 复制）

## 寄存器分配移后端（2026-09-07 完成 → 挂账）

编码层资源决策（寄存器分配数据面 + CAG 分配 + 一致性判定）从 corec（opt.cr）
归位 corearch（`src/arch/linux/ld/regalloc.cr`）完成：.ccr 不再携带分配结果与
条目（ENT 恒空 / opt_meta 恒 0 / func·REG first_ent 恒 -1 / param_ents 恒 -1——
格式结构保留、loader 空表语义已支持、零 version bump）；corearch O2 = load 后
自算 alloc + verify（emit 前，违反 = 编译错误，成功静默）；判定/条目调试通道
随迁（--dump-entries/--dump-coexist/--check-regalloc/--inject-*/--dump-regassign
同名 flag）；pass_stack_share 停用（产物死路径实证——g_stack_map 不落盘、
corearch 恒空跑，零产物差异）。设计定稿 `docs/superpowers/specs/2026-09-07-regalloc-backend-design.md`
（R1-R5/D-3 拍板记录 + 实施完成）；plan `docs/superpowers/plans/2026-09-07-regalloc-backend.md`
六 Task 收官；回归全绿（mw1-6 + live_ranges 13/13 + ccr_v6 8/8 + region_cfg
22/22 + compile + backend_bootstrap stage0-2 + hit_table 11/11 + bootstrap 三套）。

**挂账（残余）**：
- 栈共享恢复（pass_stack_share 停用——恢复 = corearch 内以 alloc 同 seam 实现并启用）
- CSE 语义实证：pass_cse 对 .ccr 产物零效果（NOD O0/O1/O2 逐字节同——lower 自
  df 重建丢弃其 NOP/替换）——O1 门语义现为进程内运行、产物不承载；产物级 CSE
  生效需专项决策（重建链语义层优化归位）
- R4：compile-time-linearity 的 corec 侧减负实测（分配/数据面计算已移 corearch）
- v6 格式文档（specs/2026-09-05-lattice-ir-v6-format.md）ENT/opt_meta 载荷语义
  同步（恒空态——ccr_io.cr 头注释为实现权威已先行）
- docs/project-book.md 后端分层哲学表述（「机械翻译器」措辞与分配归位后现实）
  校对

## 规约语法并入 .cr（2026-09-06 .corespec 退役挂账）

独立 .corespec 格式/语言退役（crasm 同构：规约只有一种表达 = Core 语言，无第二套文件/语言）：
- ~~grammar/corespec.ebnf~~（退役标注——内容保留为迁移源）→ **迁移：规约语法（requires/ensures/old/result/where/SpecImplies）并入 grammar/core.ebnf**
- ~~spec/*.corespec 4 文件~~（退役标注）→ 组件行为契约迁移至对应 .cr 注释/契约文档（先例：src/compiler/regalloc-consistency.cr）
- **.cr 规约语法实现**（requires/ensures/where 子句 = 语言实现——原类型系统方向定案线：where 值约束三档 → 验证切片；TagNode 图节点已在设计 coreir-schema「图即验证」）
- .csr（图约束二进制）保留——它是 .cr 规约编译进图后的序列化，非独立语言
- 文档引用（10+ 文件）随语法并入逐步同步

## 待实现特性

### 控制流自动惰性（2026-08-09 记）
- 目标：控制流结构（if / while / for 等）的分支表达式自动惰性求值——未被执行的路径不产生求值开销。判定表见 `docs/lazy.md`：结果只用一个分支 → 延迟；有副作用（IO/FFI/unsafe/volatile）→ 永远 eager；循环体内每次都用 → eager；循环体内条件性用 → 惰性
- 现状（源码核实，2026-08-09）：
  - IR_LAZY_THUNK(46)/IR_LAZY_FORCE(47) 已存在（ast.cr:571）；ir_gen 在纯函数调用后包 THUNK（ir_gen.cr:1106），`force_if_thunk()` 在所有操作数位置发 FORCE
  - **但当前 thunk 不产生实际延迟**：IR_CALL 在 THUNK 之前已急切发射，ELF 后端（instr.cr:1091，注释明言 "Calls are currently emitted eagerly… typed value transfer"）和解释器（interp.cr:194）都按纯值搬运降级——语义上是 no-op，只保证输出不变
  - **use_count 时序问题**：`compute_usage_counts()`（dataflow.cr:325）在全部 ir_gen 之后才运行（dataflow.cr:381），而 THUNK 判定在 ir_gen 当时读 `g_var_use_count`（ir_gen.cr:1108）→ 判定时恒 0/未初始化，`use_count <= 1` 恒真，实际每个纯调用都被包——"单次使用"条件名存实亡
  - **行号复核（2026-09-11，效应/纯度修正批 Task 4）**：上条的源码锚点为 2026-08-09 快照、已漂移——THUNK 判定现 `ir_gen.cr:1588-1599`（`fi_ispure` 读 `:1590`、`g_var_use_count` 读 `:1592`）；`compute_usage_counts()` 现 `dataflow.cr:405`（调用点 `:461`）。**本缺陷独立于效应/纯度批**：该批（#27）已把 `fi_ispure` 改为真计算，但**有意冻结**本节的 lazy 判定（`ir_gen.cr` 零改动 ⇒ 生成期读到的仍是 checker 的乐观默认值）且未动 use_count 时序 ⇒ 本缺陷保持未修，待独立批（含 ELF 判据重定——见 #26/#27）。
  - 无 `lazy()` 显式惰性内建（旧条目"共存策略"为过时信息；docs/lazy.md 明确"无关键字"）
  - 控制流级惰性（if/while/for 分支表达式）与循环体内条件性惰性均未实现——即本条目
- 方向（2026-08-09 定为编译期指令下沉路线，不做运行时实现）：
  - 原理：惰性 = 指令放置问题（docs/lazy.md:5 "图本来就是惰性的"）。纯函数调用无副作用 → 把 IR_CALL 从分支前下沉到唯一消费点，执行恰好一次且只在被执行的路径上；不需要运行时 thunk/flag/9 字节结构
  - 实现：ir_gen 之后的 CFG 后置 pass（`compute_usage_counts()` 正好提供 sink 所需输入）：纯 + 单次使用 → 把 CALL 移到唯一消费点之前
    - if 分支惰性：下沉进分支块（phi 输入仍合法——值定义在各路径上）
    - 循环体内条件性用：下沉进循环内条件块；参数 loop-invariant 时先 hoist 出循环再下沉（顺带 LICM）
    - 多条路径需要 → 不 sink，放公共支配点（自动升级 eager，用户不感知）
  - 约束：alloc 类下沉须检查 arena 归属——不能把分配下沉到会在使用点之前 reset 的 arena（SG_LOOP 每次迭代 reset）；纯函数陷阱（div0 等）时机会移到执行点，按"惰性不改变语义"接受
  - 现有 IR_LAZY_THUNK/IR_LAZY_FORCE（no-op 值搬运）可退役或保留兼容；**interp / ELF 后端零改动**
  - 循环体内"条件性用"与 if 分支惰性并列但需分开验证
- 参考：`docs/lazy.md`、`docs/superpowers/specs/2026-07-30-lazy-eval-design.md`、`src/compiler/ir_gen.cr`、`src/compiler/dataflow.cr`、`tests/suite/lazy_test.cr`（当前仅验证"包装后输出不变"）

### 性能自动化（2026-08-30 记）

- **自动并发**（auto-parallel，2026-08-30）：数据依赖 + state edges 已显式化 → 无依赖 region 的可并行性**可判定**（区别于传统自动并行化的依赖猜测——四十年失败史的根源）。算法：扫描图 → 找无依赖独立 region → 自动分派 goroutine（go/sched 机制已有）。与 R-HLS（IEEE 2024，RVSDG 动态调度）平行；「并发异步」= 8 项验证清单的实证场景。注意：并行粒度成本模型（调度开销 vs 收益）需启发式；起步 = 显式 go 保持 + safe 子集自动并行
- **自动记忆化**（auto-memo，2026-08-30）：图显式纯度判定（无副作用边）→ 多次使用的纯节点自动缓存结果。与自动惰性同机制（惰性 = 延迟执行，memo = 缓存结果），可共用判定/下沉基础设施。**判定事实现状（2026-09-11 效应/纯度批后，见 #27）**：state 链判据面已覆盖全部保守效应——可证纯调用不入链；extern/spawn/yield/hotpatch/**间接调用 `IR_DYN_DISPATCH`**/裸指针写一律保守入链 ⇒ 「无副作用边 ⇒ 纯」不再有乐观常量漏洞（本批修的 P0 症状即「memo 会把可观测效应缓存掉」）。**消费侧注意**：若实现读 `fi_ispure` 旗标而非链边，须在 IR 生成之后读（`compute_all_purity` 写回后）——生成期该字段是冻结的乐观默认值（lazy 判定解耦，见「控制流自动惰性」节）。
- **PGO 自动剖析**（pgo，2026-08-30）：编译器自动插桩收集热路径 → 自动内联/特化/字段布局。标准基础设施（LLVM 成熟路线），零用户标注
- **自动向量化**（auto-vectorize，2026-08-30）：可向量化 region 检测 → SIMD 发射（hw-map 编码层落地后接入）。标准技术，优先级低
- **自动内联**（auto-inline，2026-08-30）：热路径自动内联（PGO 配套）；`@inline` 显式保留
- **自动软件流水**（auto-pipeline，2026-08-30）：循环自动流水化。标准技术，优先级低

明确不自动：**自动 apx**（精度意图——编译器猜不了意图，apx 标签必须显式；Poseidon（LLVM 2024）参照仅限无验证义务上下文）；**数据结构自动选择**（依赖意图，太远）

### 验证/工具自动化（2026-08-30 记）

- **不变量自动推断**（invariant-inference，2026-08-30）：循环不变量/部分前置条件自动推断——Houdini（注解推断，MSR 2005）+ ICE（反例驱动不变量生成）路线；系统先尝试推断，推不出的才让用户写（与「显式性最小集 = where 值约束」衔接）
- **证明搜索自动**（proof-search，2026-08-30）：SMT 层自动找证明，零证明脚本——Verus 免证明自动化路线（EPR 限制逻辑、proof-by-computation）
- **测试生成自动**（test-gen，2026-08-30）：where 约束/规约 → 约束求解器自动生成测试用例（验证管线的副产品，近零成本）
- **序列化/打印自动**（serialize-auto，2026-08-30）：从接口声明自动生成序列化代码与打印格式（serde 式派生；`dex_str` 已是雏形）——类型驱动代码生成家族

### ~~.crasm 统一汇编抽象层~~（2026-08-09 记｜**2026-09-05 退役**）
- **退役（2026-09-05）**：独立 .crasm 格式取消——绑定经典硬件过深（寄存器/寻址/ISA 助记符/私有平台映射表），被**硬件接口表（HIT）**吸收：跨平台 = HIT 事件 + 投影表；MMIO/特权/中断 = `.cr` unsafe + HIT extern 接口事件；事件可读形态 = v6 NOD 文本 dump。正式声明 = `docs/crasm.md` 状态行（已废弃，保留为历史记录）；依赖解除引用见本文件「硬件映射表」与「宽度类型移出语言」两条。**原里程碑方向全部作废（保留下文备查），无实施计划。**
- （历史）目标：内核路线（project-book 第五阶段）的汇编级能力——MMIO、特权指令、中断。跨平台统一指令集 + 无限虚拟寄存器 + 平台映射表，寄存器分配按 v4 方向（缓存语义映射实例，`docs/regalloc-cache-mapping.md`——无限虚拟寄存器 + 平台映射表正是映射实例形态；现 `alloc_registers` 线性扫描器为升级起点）
- （历史）现状：设计已批准（2026-08-08 brainstorming 逐节确认），2026-08-09 整理为正式文档 `docs/crasm.md`；实现从未落地（lexer/parser 无 asm 语法）——2026-09-05 整体退役
- ~~方向（按里程碑顺序）：~~
  - ~~1. `.crasm` 词法/解析（结构化指令 → AST 复用）~~
  - ~~2. 寄存器生命周期 pass + 测试（未初始化读/重复写/生命周期逃逸/宽度一致/分支一致性）~~
  - ~~3. 特权约束表 + 用法验证 + unsafe 隔离~~
  - ~~4. x86-64 映射表（翻译器）+ 字节级测试~~
  - ~~5. .cr extern 接口接线 + 端到端~~
  - ~~6. （后补）ARM64/RISC-V 映射表~~
- 明确不做（YAGNI，退役前定案保留）：模拟器/调试器、C 生态兼容、指令级时序验证、特权副作用验证（隔离，人工保证）
- 参考：`docs/crasm.md`（**已废弃 2026-09-05**）、`docs/superpowers/specs/2026-08-08-crasm-design.md`（批准记录，历史）

### 对照 CompCert 审查发现的未修复 bug（2026-08-11 记，详见 docs/compcert-reference.md）

- ~~**region_check 误报（B11）**：deref 读出的 int 值被当作指针做区域逃逸检查——`v := *p; return v;` 被拦（预先存在，pts 语义需按类型过滤）~~（2026-08-29 已修：deref/return/store 仅对指针类型执行 provenance/区域逃逸检查；`test_deref_loaded_int_is_not_pointer_escape` 覆盖原始误报）

### float 支持实现记录（2026-08-11，对照 IEEE 754 / SysV 标准实现）

- 字面量：decimal → binary64 位模式（纯整数算法，≤18 位有效数字，±1ulp）
- 算术：addsd/subsd/mulsd/divsd（F2 0F 5x C1）；比较：comisd + setcc 无符号标志
- 转换：IR_I2F/IR_F2I（cvtsi2sd/cvttsd2si）+ float 运算 int 操作数隐式转换
- 参数/返回：SysV XMM0-7（int/float 独立编号）+ XMM0 返回 + 栈参数（float 超 8）
- 打印：float_str_bits（位模式 → 十进制，长除 + 去尾零 + 跨位进位舍入）
- 验证：O0/O1/O2 运行全部通过；待办：f32 单精度、printf 风格最短表示

### corelsp 服务器加固 TODO（2026-08-16 终审分流，详见 LSP 任务审查记录）

- ~~json.cr：节点索引无边界防御（-1/过期索引）、重复键取首值（规范为末值）、`\b`/`\f`/`\/` 拒绝、递归深度无上限~~（2026-08-28 已修：节点边界、末值语义、标准转义、128 层深度上限、代理对合并、INT64 边界与溢出检查）
- ~~rpc.cr：Content-Length 数字溢出绕过上限（19+ 位 → 负 n → alloc）、"content-length" 子串可被其他头误匹配、裸 `\n\n` 头终止符不识别（规范强制 CRLF，合规）、逐字节读性能（100KB ≈ 10 万次 syscall）~~（2026-08-30 已修：按 CRLF 行解析、字段起始匹配、数值预检与重复字段拒绝；stdin 改为 4KB 分块读取，保持逐字节解析语义）
- ~~analysis.cr：类型节点索引 0 边界（文件首语句为命名类型 fn 时 hover 回退 "int"）、self 参数显示 "int"（impl 解析挂起前不可达）、definition 指向 fn 关键字而非函数名、查询忽略请求 uri（多文档场景悬停 A 返回 B）、多字节字符串按字节列宽匹配（非 UTF-16）~~（2026-08-28 已修：函数名令牌定义位置、请求 URI 快照隔离、UTF-16 code unit 坐标；self/impl 语义仍受前端快照限制）
- analysis.cr：completion/documentSymbol 关键字/@ 表以字面量 if 链镜像（新增关键字时漂移风险——已注释指向真源）；~~semanticTokens 未闭合字符串以 `\` 结尾 span+1~~（2026-08-29 已修：span 在源末截断）；T_INT_I8.. 和 T_LET 是保留但不由当前 lexer 发射的历史 token 常量，semanticTokens 不再将其误分类为 type（后缀位宽迁移仍待实现）
- test_lsp.py：第七组 read 超时已修（select 5s）；`->` 标记扫描已限定帧间（终审顺手修完成）
- 顺手修遗留：报告文档类笔误（lsp-task-7-report 字节数、lsp-task-6-report §1 表未同步 T_WHILE）——scratch 文件，不阻塞

### 数值类型（dex/apx）迁移遗留 TODO（2026-08-16 终审分流）

- ~~**corearch `--link <so>` 静态路径崩溃**（so_parse_text SIGILL/SIGSEGV，ld.cr:400 附近）~~（2026-08-30 已修：静态链接 relocation 使用 user-code 相对偏移，避免把 `.so` 嵌入偏移重复叠加；`.text` 优先按 section 名精确选择；修复 Intel 语法下 `call r16` 的保留寄存器名冲突；静态输出补 writable BSS `PT_LOAD`；`tests/selfhost/test_dex_arith.py::test_extern_dex_static_link` + `tests/fixtures/dex_ffi_shim.c` 覆盖实际 `.so` 构建、`corearch --link` 和 ELF 运行）
- ~~sizes.cr: IR_APPROX 无显式条目~~（2026-08-29 已补显式 0 字节条目，与其他注解指令对齐）
- ~~泛型+dex 返回类型~~（2026-08-30 已修复/验证：局部 dex 槽位按 `apx` 标签正确区分 binary64 与缩放整数；普通 Core 函数边界统一缩放形式；bootstrap 泛型与 native dex/APX 回归通过）
- str_to_f64_bits ~2ulp 截断（保留站点文档化限制）：binary64 判别子用 1/3（0.1b+0.2b==0.3 仅 −1ulp 组合恰好落位模式，不可作断言）；native APX/FFI/格式化回归已在 WSL 通过
- ~~INT_LIT 缺 hex/octal/binary 前缀分支（0x1F 等）；`1_000` 下划线产生 T_INT(-1) 静默值 0~~（2026-08-29 已修：bootstrap 与自举 lexer 支持 `0x`/`0o`/`0b` 及下划线，并拒绝非法数字；2026-09-05 #61 收尾补强：溢出守卫按 base 校准——固定 i64max/10 阈值对 base 16 无效，`0x8000000000000000` 静默环绕为 i64min；现 16/8/2 分别用 i64max/base 阈值，bootstrap `read_number` 同步前缀进制溢出拒绝，cir_cache 魔数改 signed 十进制同字节模式）
- interp 裸 opcode 数字风格（与既有 op == 26 风格一致，非缺陷）；`_f32/_f64` 宽度透传死路径（EBNF/inventory 争议点 7 已标注，apx 位宽标注需新发射路径）
