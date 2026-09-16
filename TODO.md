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

### 5. ~~cir cache 跨编译器重建不失效（2026-09-10 内核抽取 Task 3 评审确认——预存,**已修 2026-09-11**）~~ —— **已核销（2026-09-16 分类账复核）**：`cir_cache.cr` `cir_compiler_identity()` 在位（+ 头部 identity 字段）+ `test_cache_identity.py` 5/5（提交 `3be4cb48`）
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

### 8. ~~前端 ≥18 形参静默误编译类（2026-09-10 x86 实例化波 1 Task 5 评审登记——高优先级：静默误编译）~~ —— **已核销（2026-09-16 分类账复核）**：`dyn_arr.cr:89` `MAX_FN_PARAMS=64` + `:467/:473` 读写护栏 + P020 硬错（提交 `d7ad71d3`/`68ffa1e8`）
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

### 11. ~~解释器 callee 内联路径缺 opcode（枚举 / 裸指针 / 切片 / 边界检查族）→ 双路径分叉（2026-09-10 R1 终审扩写——Important，本批 15 例未覆盖）~~ —— **已核销（2026-09-16 分类账复核）**：`tests/selfhost/test_interp_parity.py` 在位且已挂 CI（`src/ci/run.sh`）——分派已统一为单实现
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
- **触发实证 ②（2026-09-13，R2 P4 Task 5）**：本任务的两枚表示码常量 `OE_BARE = -1` / `OE_BOXED = -2`（先置于 `ir_gen.cr`、后移 `globals.cr` 均同病）在自举链二进制里**读 0** ⇒ `Some` 初值的表示位与裸值同码 ⇒ 解包走错分支（gdb 实测 `emit_rep_set(enc=0)`、常量槽读 0）；**改走 `oe_bare()/oe_boxed()` 函数**（返回值表达式不受该路径限制）后消解。原文「当前自举链未触发（编译器自身无此类全局）」**已不成立**——本仓自源现有此形态。
- **live 实例（本轮实测）**：`cir_cache.cr` 的 `CIR_CACHE_MAGIC : int = -4485090715960753727` 在 bootstrap 构建的 corec/corearch 里同读 0 ⇒ 落盘 `.cir` 头部 magic 实测 **全 0**（`od` 读缓存文件首 8B = `0000000000000000`，应为 C1C1…）——写/读两侧同常量故**自洽**（不炸测试），但格式与 spec 记载的 magic 值静默不符（属本条目同族；修复须与 `CIR_CACHE_VER` bump 同批）。
- **修复方向**：bootstrap `ir_gen.py` 的初值提取扩展到一元负号/常量折叠可判定形态（与 self-hosted 的 `global_init_val` 对齐），或对不可判定初值发诊断（**禁止静默 0**）；判据 = `tests/bootstrap/` 增用例（负号初值/调用初值 → 值正确或响亮报错）。

### 15. R2 P0 类型项引擎落地（2026-09-10——落点与未覆盖面登记，非缺陷）
- **落点**：`src/compiler/type_terms.cr`（类型项 DAG 表 48B/条 + 开放寻址索引 + 哈希去重 + NNF/DNF 规范化）、`src/compiler/type_engine.cr`（三态判定 `ty_sub`/`ty_equiv`/`ty_disjoint`/`ty_inhabited` + 反例 `tt_witness` + 穷尽性 `ty_exhaustive`（补集空性）；原子类互斥公理、μ 展开余归纳 memo、预算守卫）、`src/compiler/type_selftest.cr`（38 例用例表）+ CLI `corec selftest-types` + 判据 `tests/selfhost/test_type_engine.py`。spec = `docs/superpowers/specs/2026-09-10-type-interface-unification-design.md` §9 P0；计划 = `docs/superpowers/plans/2026-09-10-r2-p0-type-engine.md`。
- **P0 边界兑现**：checker/ir_gen/后端/内核零改动；产物 byte-identical（`ptr_arith.cr` 与 R1 基线逐字节相同）；自举 `corec2/corec3` `cmp` IDENTICAL。
- **未覆盖面（显式登记：命中返回 -1 或按守卫，**不静默**）**：① 参数化原子的参数仅同形判等（变型规则 = P3）；② `AK_NAMED` 具体行不展开（待 P2 接入 checker 类型表后可用）；③ 空递归（如 μX.X）按深度守卫 512 → -1；④ 判定预算默认 200000 步（**规范化亦计入**：∩ 分配律 2^n 爆炸在 n≈13-14 处截断），超限 → -1 + `g_ty_exhausted`；⑤ 命中①/②/`¬μ` 时置 `g_ty_uncovered = 1`（写入点在 `lit_implies` 与 `tt_nnf_neg`）并以 -1 上抛——**未覆盖面恒给「未知」，不给确定答案**；⑥ memo 重建（`ty_memo_rehash`）与「进行中」状态的交互**无实测覆盖**（现有规则下需单次证明内 >512 互异对才可达；读码核验成立，复审登记）。
- **三态约定（判据面）**：判定 API 返回 `1 = 成立 / 0 = 不成立 / -1 = 未知（预算耗尽或未覆盖）`；`tt_witness` 另用 `-2 = 未知` 与 `-1 = 不可满足` 严格区分（`ty_exhaustive` 对 -2 返回 -1，绝不当「穷尽」）。**预算耗尽的结果一律不缓存**（memo 每顶层查询清空）。

### 16. ~~函数体内嵌套 `fn` 声明 → 编译段错误 rc=139（2026-09-10 R2 P1 Task 2 评审确认——既有缺陷，非该批回归）~~ —— **已核销（2026-09-16 分类账复核）**：`parser.cr` P021 定位诊断（`ast.cr:337` `EC_P_NESTED_FN`）+ `test_nested_fn.py` 在位且挂 CI（提交 `f417d345`）
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

### 17. R2 P1 影子对拍落地（2026-09-11——落点 / 开关默认值与产物影响 / 裁决归属登记，非缺陷） —— **已归档（2026-09-16 分类账复核）**：登记对象（影子层）已由 P5 T5 整体删除（`--type-shadow` 三注册面零在位）
- **落点**：`src/compiler/ty_shadow.cr`（桥接 ti→类型项 + per-ti 缓存 + 8 站点挂点 + 分类计数 + 摘要/转储）、`src/compiler/checker.cr`（`type_equal` → `type_equal_core` 包装 + 8 站点 `sh_site_begin`）、`src/compiler/type_selftest.cr`（桥接用例）、`src/compiler/globals.cr`（`g_shadow_*` 组）、`src/compiler/main.cr`（CLI 旗标）。清单三处注册：corec + **corelsp**（Task 2 起 checker 引用影子层）+ test_compile。清单 = `docs/superpowers/specs/2026-09-10-type-shadow-findings.md`；计划 = `plans/2026-09-10-r2-p1-shadow-parity.md`；提交链 `e4c293b2`（桥接）→`844cec6c`+`514956a1`（挂点/补强）→`75c20297`（Step 0 拆因 + 语料清单）。
- **开关默认值与产物影响（登记）**：`--type-shadow`（**默认关**，纯观察通道；`--type-shadow-dump <file>` 另给差异转储）。两态产物**逐字节相同**（`ptr_arith.cr` 开/关/基线三份 sha256 全等 `95084e7b…d475`；`check` 路径 stdout 仅开态追加以 `[type-shadow]`/`[type-shadow-sites]` 起头的两行）。影子预算/memo 每次判定前后各 `ty_budget_reset` → 不污染 checker 判定；关态 `sh_site_begin` 首行早退（Task 4 M3）→ 关态残留开销 = 每次判定一次全局读。**结论：开关可安全长期保留默认关，无产物影响。**
- **差异清单裁决归属（登记）**：findings 的 F1（P2 硬前置）/F2（P2 裁决）/F3/F4（checker 缺陷面，单开任务）与「按差异清单替换旧判定」的**替换门**全部归 **P2**；P2 验收不得只看「差异数 = 0」，须同时报告站点覆盖（P1 实测 4/8 站点零命中）。下 #18-#21 为逐条登记。
- **站点 6 去留裁决（终审 M-1 交接项）**：站点 6（`assign-binary`，`EXPR_BINARY + OP_ASSIGN` 遗留路径——parser 已把 `=` 一律降为 `EXPR_ASSIGN`，`parser.cr:222-224`，故**不可达、无样本**）**保留挂点，去留归 P2 裁决**（**后由 P5 D25 推翻**：`tok2op` 零 `OP_ASSIGN` + 语料站点直方图 0 命中 ⇒ 分支与挂点**已删**，`P5 Task 4 / #47`；站点 id 不重编号、退役注记落站点表）。

### 18. ~~F1（P2 硬前置）：同名 named 类型占多行未规范化 → 引擎按行建原子 → 判不了~~（2026-09-11 R2 P2a Task 1 **已修**：建表去重——唯一分配点收敛 `alloc_named_type` + 开放寻址侧表（装填守卫/重建重放/回写重探，照 `sh_map_*` 先例），8 个生产分配点全改调；12 个读取点读**名字**故语义不变。落点 `src/compiler/checker.cr`（+`globals.cr`/`type_selftest.cr`），提交 `3c8402e8`（评审 3 Minor 收口 `8c9d773f` 纯注释）；判据 = `selftest-types`（f1.* 四例 + 扩容重建例）+ 侧表↔`res_type_node` 管线内断言（`tests/selfhost/test_named_dedup.py`，正控 mismatches=0 / 负控注入 6、rc=1）+ P1 9 条 unknown **清零** + ELF 逐字节同）
- **现象**：`type_equal_core` 的 `TYP_NAMED` 按 **name_idx** 判等（同名恒等价）；类型表同一名字可占**多行**（`MemLayout` 2 行 / `Box` 5 行——`res_call_type` 在符号不可见处 `alloc_type(TYP_NAMED,...)` 新建行、泛型实例化另建行），而桥接按**行号**建原子 `tt_atom(AK_NAMED, ti, -1)` → 两个不同原子 → 引擎 `AK_NAMED` 不展开 → **-1（未判定）**。
- **实证**：P1 三档语料 26,704 判定中 9 条差异（去重 3 类型对）**全部**由此产生（`old_looser=0`、`old_stricter=0`；差异 = 「旧能判、引擎判不了」）；根因探针 = findings §4.2 + §6.F1。
- **影响（为何是硬前置）**：替换后主流「同类型比较」会从**真**变**未判定**；若 P2 把未知当拒绝 → 大面积假拒，当通过 → 静默失去命名类型检查。二者皆不可接受。
- **修复方向**：二选一并裁决——① 引擎侧引入 named 身份规范化（同名 → 同一原子，需 name 注册表）；② 桥接把同名行折叠到同一项（须先裁决「同名是否恒等价」，会掩盖跨声明域同名）。**P2 第一项，且须补同名多行的守门用例**（findings 探针 B/F/G/K 可升格为回归）。

### 19. ~~F2（P2 裁决）：数组长度 `N` 旧判定比、引擎不比 → 替换即放宽~~（2026-09-11 R2 P2a Task 2 **已裁决并实施**：用户裁决 = 落「常量档长度约束」保持现状拒绝语义——`array_len_constraint_ok` 沿结构对应位下钻比 N（数组元素/指针元素/引用元素/切片元素/元组字段/泛型应用实参 6 位），身份分支去 N，判定点 `type_compat_strict` 显式补检（`-1` = 长度违反 → 专属措辞，码不变）；判定点**恒先调 `type_equal`** 保影子站点采样面。落点 `src/compiler/checker.cr`，提交 `b36d8e76`（评审 M1「同形」限定 `507daf7a` 纯注释）；判据 = `selftest-types` f2.* 8 例（**Task 4 补至 10 例**：+REF/SLICE 下钻位）+ 异长拒绝行为探针 + 全语料 `old_stricter=0`（探针 D/G 的 F2 面消除）；**P3 面遗留**：符号档/动态档长度约束未实现（本批按字面量比较 extras，异形不下钻））——**✅ 2026-09-12 收口（P3a Task 1；#34）**：动态档 = 既有运行期检查（`g_ir_slice_lens` 侧表 + `IR_BOUNDS_CHECK`，R1 已落）+ checker 字面量界检查；**符号档 = VC 义务，显式登记不实现**；N 读取面守门 = 「N 只许被常量档检查与表示层读（`arr_len_lit_of`/`type_size`/`type_align`），身份/子类型路径零 N」已由 `t1.n_face_gate*` 用例钉住（含嵌套固定性「b 盲」比较修复）
- **现象**：`type_equal_core` 的 `TYP_ARRAY` 分支比较 `extra`（= N）；桥接按 R1 裁决**不把 N 入身份**（`AK_SEQUENCE` 参数链只含元素项）→ 替换后 `[int;3]` vs `[int;4]` **静默通过**（当前是 `error[TF01]`）。
- **实证**：探针 D（`[int;4]` 返回给 `[int;3]`）与探针 G（泛型实参位）均 `old_stricter=1`；本轮语料 0 触发。
- **修复方向**：R1 的「N 不入身份」是 **IR 侧**身份裁决；**checker 侧是否保留 N 检查需单独裁决**——保留 → 需在引擎/桥接把 N 作为维度/字面量入判定；不保留 → 记为有意的语言放宽并写进 spec。裁决后同步 `bridge.len_not_identity` 用例语义。

### 20. F3：调用位点实参类型不匹配**无诊断**（`unify_types` 返回值被丢弃；**锚点已勘误（2026-09-16）：`checker.cr:1053` → 定义 `:1912` / 丢弃点 `:2021`**）
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
- **P5 继承项（并入 #24/#30 清单；**本条已全部收口**）**：~~`type_equal_legacy` 删除~~（**已删：P5 Task 4 / #47**）+ ~~`sh_*_ak_legacy` 删除~~（同上）+ ~~站点 6 挂点~~（同上）+ ~~影子层（`--type-shadow`/`replace_*`）同族下线~~（**已删：P5 Task 5 / #48**——判定通道/环缓冲/摘要/转储/站点直方图/9 挂点/17 全局/2 CLI 通道；回归网切换见 #48）+ `tt_display` 零 `str_intern` 的可选改造（**未做，转 P6**，若接受 `.ccr` STR 段增长）；**残项** = `--verify-named-dedup`（非影子面 + 有活消费者 ⇒ 不删，偏离登记见 #48）。
- **判据继承（#26）**：本批 `.ccr` 判定按 #26 口径执行（`test_ccr_v7` 结构性断言 27/27 + 语义零变化 + 自举稳定），T4/T5 变更面**逐段实测**（非「与旧版逐字节同」）；三任务 ELF canary 全同 ⇒ 类型层改动未泄进发射面。
- **⚠ 收官发现并修复的回归（Task 7；**T5 漏改 project-mode 清单**）**：`src/targets/x86_64-linux/_import.cr`（corearch project-mode 导入清单）的 `import monomorph` 漏删——T5 只把 `monomorph.cr` 从 concat 面 `backend_support_files` 迁出，而 monomorph.cr 的类型项化新增 checker/parser 层依赖（`get_type_kind`/alloc_node 族 46 处）⇒ project-mode corearch 构建 **33×error[N06] 静默未定义**（rc=0 + 产物照出；stage 链互测不可见），`tests/selfhost/test_backend_bootstrap.py` 的 project-mode `error[` 门首步 rc=1。**为何 P3a 期间不可见** = 该套件未挂 CI（#31，同批已更新证据）。**修复** = 删该行（与 concat 面同一零引用证据；注记落文件头）；**复验** = 该套件 rc=0（stage1/2/3 逐字节同 + smoke/O2 smoke 全绿）+ project-mode 构建日志 `error[` = 0（33→0）+ ELF canary `95084e7b…d475` 不变 + 三二进制 sha 不变（本文件不入任何 concat 清单）。⇒ 收官全量枚举（42+7 逐档）终态 **49/49 rc=0**。
- **报告**：`.superpowers/sdd/p3-task{0,1,3,4,5,7}-report.md`（六份）。

### 22. 仓库卫生：suite 空 fixture ×2 + 死文件扫描噪声（2026-09-11 R2 P1 Task 3 语料扫描发现）
- **`tests/suite/test_control_flow.cr` / `test_generics.cr` = 0 字节空文件**：`corec` 对它们报 `error: cannot read`（**勘误**：Task 2 报告曾记为「预期失败 fixture」，实为空文件）。修复方向 = 补内容或删名（删需用户许可，铁律 #3）。
- **`src/compiler/elf.cr`**：`check` 扫描 rc=0 但 **2 个 parse error、decisions=0**——陈旧遗留文件（死文件本体的登记见 #7；本条补充**语料卫生**事实：批量 check 脚本须排除它，否则 parse error 混入语料日志）。**`src/compiler/linker.cr` 为 0 字节空文件**（同类：批扫时排除或删除）。
- **实证**：findings §8 末「其他已登记项」；语料日志 `/tmp/r2p1t3/all_tiers2.txt`。

### 23. ~~harness 缺口：`.claude/hooks/block-git.py` 只拦「以 git 开头」→ 复合/管道命令可绕过~~（2026-09-11 登记）——**✅ 2026-09-16 修复**
- **现象（原）**：钩子仅判 `stripped == "git"` 或 `stripped.startswith("git ")`（`.claude/hooks/block-git.py:10-11`）——`cd x && git status`、`echo hi; git log`、`(git status)`、`sudo git ...` 等**复合/包装形态全部放行**；铁律 #2 的「机械拦截」有洞。
- **影响**：非恶意误用（多 agent 并行时的习惯性复合命令）即可能绕过禁 git 约束；2026-09-11 工作副本曾出现一次只读 `git diff --numstat` 违例（Task 3 自陈 D7，无写操作）。
- **修复（2026-09-16 已实施，按原登记方向）**：改为**词边界扫描** —— 先按 shell 分隔符（`;` `&&` `||` `|` `&` `(` `)` 换行 反引号 `$(`）切段；每段 `shlex` 分词后**跳过前导**（环境赋值 / 前缀命令 sudo·doas·env·nice·nohup·time·exec·command·xargs·timeout·stdbuf·setsid·ionice·cpulimit·parallel·watch / shell 名 / 旗标 / 纯数字），再看**首个命令词**是否为 `git`（含 `/usr/bin/git`、`git.exe` 形态）；另**递归扫描** `bash -c '…'` / `sh -c "…"` 内联脚本（深度 ≤ 3）。**放行面**：`jj git push`（git 非命令词）· `echo git` · `grep -n git` · `find . -name .gitignore` · 引号内非命令位。
- **判据**：`tests/harness/test_block_git.py`，**30 例**（BLOCK 19：裸 / 带路径 / `&&` / `;` / `|` / `||` / `&` / 子壳 / `$()` / 反引号 / `bash -c` / `sh -c` / sudo / nice / env / xargs / timeout / 嵌套；ALLOW 11）⇒ 实测 **30/30**；已挂 CI **`bootstrap-tests`** job（`src/ci/run.sh` 一行，纯 python 无需编译器）。
- **失败模式（有意）**：hook 自身异常**一律放行**（exit 0）—— 宁可漏拦，不可把会话卡死。

### 24. R2 P2a 落地（2026-09-11——落点 / 未覆盖面登记 / P5 继承项，非缺陷）
- **落点**：`src/compiler/checker.cr`（`alloc_named_type` + 去重侧表 / `array_len_constraint_ok` / `type_compat_strict`+`diag_type_incompatible` / `type_equal_engine`+`type_equal_legacy` 拆分）、`src/compiler/ty_shadow.cr`（对照物切 legacy + `replace_*` 计数）、`src/compiler/globals.cr`（`g_named_dedup*` / `g_replace_*`）、`src/compiler/main.cr`（`--verify-named-dedup`）、`src/compiler/type_selftest.cr`（f1./f2./t3.* 用例）、`tests/selfhost/test_named_dedup.py`（新增）。计划 = `docs/superpowers/plans/2026-09-10-r2-p2-replace.md`；报告三份 = `.superpowers/sdd/r2p2-task-{1,2,3}-report.md` + 收官报告。提交链 `3c8402e8`+`8c9d773f`（F1）→ `b36d8e76`+`507daf7a`（F2）→ `10718ba8`（判定替换）→ 收官（本条目所在提交）。
- **行为面兑现**：判定权由结构判等移交引擎（`ty_equiv`），unknown（-1）/桥接失败**回落 legacy 并计数**（`replace_unknown`/`replace_bridge`，不静默）；ELF 逐字节 = R1 基线 `95084e7b…d475`（开/关两态）；自举 `corec2/corec3` cmp IDENTICAL + N06=0 + 冒烟 42；**已跑集**（17 selfhost + 5 bootstrap + `selftest-types`）rc=0。
- **评审 Critical 修复（2026-09-11 终审；本条目所在提交）**：**桥接缓存 `g_shadow_map` 无重置钩子**——本批起判定路径**无条件**调 `sh_term_of_ti`（此前仅 `--type-shadow` 下），而 `init_types()` 只清类型表与 `named_dedup` 侧表、**未清桥接缓存** ⇒ 长驻进程（corelsp 每请求 `reset_frontend_state → check_all`）里行号复用 + 命中即返回 = **两个不同类型被判等**（静默漏报；评审实证 corelsp 同 URI 两次 `didOpen` 换元素型 → 第二次 diagnostics=0）。修法 = `sh_map_reset()`（cap/entries/hits 归零）经 `init_types()` 调用（照 `named_dedup_reset` 先例）；判据 = `selftest-types` `t3c.*` 两例（计数 + 行为双断；**突变控制**：副本去掉该调用 → 93/95、两例 FAIL）+ LSP 双请求用例 `test_double_open_bridge_cache_reset`（修复前实测 RED：V2 diagnostics=0；修复后 1 条 `Assignment type mismatch`）+ ELF/`.ccr`/自举逐项复验。
- **未覆盖面（显式登记）**：① 站点 1/2/4/6 语料**零命中**（同 P1）→「对拍差异归零」效力范围 = 赋值/返回/if 面（站点 5/7/8），泛型实参/应用基型/兜底等价/热补丁四面的证据来自定向探针而非语料（P1 交接硬性要求：报差异数须同报站点覆盖）；② 语料 `replace_unknown = 0` 说明语料未触达引擎未知面——未知面证据来自探针与 C-1（`G<[int;3]>` 等 **5 处** =1：n5/n6 + `c1_genapply_same/diff/diff2`）。
- **P5 继承项（须在删 legacy 前清零/落地）**：① ~~**`type_equal_legacy` 删除归 P5**——现为「对拍对照物 + unknown/桥接回落实现」双用~~（**已删：P5 Task 4 / #47**——引擎唯一权威 + 回落计数随删；残部 = 影子层，已由 P5 Task 5 / #48 下线）；② **unknown 清零的前提 = 引擎命名展开**（`TYP_GENERIC_APPLY`/`AK_NAMED` 目前不展开 → 引擎 -1 → 回落 legacy；命名类型/泛型应用面的等价判定**仍由 legacy 承担**）——引擎命名展开落地前 unknown 清零不可达，且删 legacy 会把「回落」变「未判定」；**状态更新（R2 P5 Task 3）**：清零已由**命名面判定化**（身份链，**不接**结构性展开——P3a 反证口径保持）达成：语料 + 探针可判定域回落计数 = 0（见 #46）；残留 -1 = 不变槽面（停条件②，单独裁决；**已由 P5 Task 3b / #46 收口**）；③ ~~站点 6 挂点去留（P1 终审 M-1 交接）随 P5 站点面清理一并办~~（**已办：P5 Task 4 / #47**——分支与挂点删除（三面不可达证明 + 语料 `assign-binary=0`）；站点 id 不重编号）；④ ~~**R2 P2b Task 2 的 `sh_native_ak_legacy`/`sh_base_ak_legacy` 删除归 P5**~~（**已删：P5 Task 4 / #47**——三例对拍改钉**冻结期望表** `ts_t4_ak_expected`/`ts_t4_native_ak_expected`，生产文件里不再有第二份实现）。
- **同族清偿（P5 前必办）**：**桥接缓存（`g_shadow_map` 及其 `g_shadow_*` 诊断计数）+ `type_equal_legacy` 同属「调试/对拍结构进了生产判定路径」一族**——P1 时两者皆仅 `--type-shadow` 下活跃，P2a 起 `sh_term_of_ti` 与 legacy 回落都在**默认路径**上。清偿方向 = 引擎覆盖面补齐后（命名展开 + 长度面入库）删除 legacy 回落、桥接层退化为纯调试通道（或随影子层一并下线），届时 `g_shadow_map` 的失效钩子、`replace_*` 计数、`--verify-named-dedup`/`--type-shadow` 两个隐藏通道一并清理。**T7 注（R2 P5 收官）**：本段清偿方向**已全部兑现**——legacy 回落与 `replace_*` 计数删除（#47）、桥接层剥调试计数并改名 `g_term_map`（桥接缓存 = 生产面保留；#48）、`--type-shadow`/`--type-shadow-dump` 下线（#48）；`--verify-named-dedup` 经裁决**保留**（非影子面 + 活消费者 `test_named_dedup.py`，偏离登记见 #48）。
- **覆盖清单（Task 4 挂账 → 由终审转入本条）**：F2 约束的 **4/6 下钻位（REF / SLICE 元素位）用例已补（`f2.ref_elem_reject` / `f2.slice_elem_reject`）但缺「突变控制」**（未验证把该位实现改坏时用例真的会红——其余下钻位同此：现有用例只断「同长 → 1 ∧ 异长 → 0」，未见证伪实验）。补法 = 逐位做一次「删/改该位下钻 → 用例必须 FAIL」的突变实验并记档（同 `t3c.*` 与 LSP 用例的负控做法）。
- **P2b 待办（同 spec §9 P2 行）**：`infer_expr` 公理区 → `iface_ops` 查表接线；`res_type_node` 两表合一。→ ~~**2026-09-11 已落地**，见 #30~~（P2b 未交付面——`iface_satisfies` 等——已转入 P3 交接包：findings §12 + P3 计划附录 A）。

### 25. ~~F5：`EXPR_TUPLE` 元素连续槽位假设对**复合表达式元素**不成立 → 元组字段类型错录（假拒 + soundness 漏放；含 `opt.cr:177` 恒空转登记）~~ —— **已核销（2026-09-16 分类账复核）**：`test_tuple_slots.py` 14/14 且挂 CI（提交 `0390f0f4`；两趟 wrapper 契约）
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
- **R2 P4 继承与判据勘误（2026-09-13，P4 Task 7 收官；#44）**：P4 载体批（8 提交）全程按本条口径（结构性断言 + 语义零变化 + 自举稳定，不以「与旧版逐字节同」为准——T1 起旧记录值作废、T3 起 STR 增长按裁决 1 接受）。**两条勘误落纸（计划 Global Constraints + 附录 D-1，实测）**：(i) **「`.ccr` 冷/热两态逐字节同」对非可选程序本就不可达**（冷≠热 = 预存，pre-P4 二进制同病 89086/88954，本条「冷/热缓存态 `.ccr` 分歧」那一半至今未修）⇒ 该判据只对**可选面零足迹**程序成立（可选程序关 `.cir` 缓存 ⇒ 冷≡热按构造；实测 `2bfbbe2b…` 97604B 冷热同）；非可选程序改为「冷/热各自确定性 + 与同源基线编译器逐字节同（同口径）」。**TYPE 段「纯函数」承诺项面成立、行面不成立**（行表热 12/冷 15 = 热路径跳过 `ir_gen` 不重建 `alloc_type` 行）。(ii) **`.ccr` 记录值有两条命令口径**（引用必须带口径）：`corec ccr F -o O`（`ptr_arith` 90823B / `generics_test` 134701B）vs `corec build F -o O --static`（90966B / 134844B；`--static` 前置 `rt.cr` ⇒ +143B，`main.cr:423-425`）——两者各自确定性可重复。
- **R2 P3a 继承（2026-09-12，P3 Task 7 收官；#34）**：本批（Task 0/1/3/4/5）对 `.ccr` 的判定**一律按本条口径执行**——T0/T1/T3 `.ccr` 逐字节不变；**T4 变**（内建 Option 串退役：STR 段 −10B、后续索引整体 −1，逐段实测）；**T5 变**（`generics_test` +370B = 恰一个额外实例：`get_val[unit]` → `get_val[int]`+`get_val[string]` 反折叠，逐段实测）；三任务 **ELF canary 均逐字节同** ⇒ 类型层改动未泄进发射面（本条「ELF 变须停下上报」条款得到执行）；结构性断言 `test_ccr_v7` 27/27 全程绿。

### 27. 效应/纯度修正批落地（2026-09-11 P0 插队批——`fi_ispure` 真计算 + state 链分类表补全；**非缺陷，落地登记**）
- **落点**：`src/compiler/checker.cr`（`purity_op_effect` :2891 · `compute_all_purity` :2938 · `fi_ispure_of` :3083 · `src_func_of_ir` / `df_func_of_node`）、`src/compiler/dataflow.cr`（`df_connect_state` :146 改调单一真源 · `df_replay_state_chain` :197 · `df_state_finalize` :249）、`src/compiler/purity_selftest.cr`（新增，26 例）、`src/compiler/monomorph.cr`（实例→源侧表登记）、`src/compiler/cir_cache.cr`（版本 14→15——快照不再持久化链边）、`tests/selfhost/test_purity.py`、`tests/selfhost/test_ccr_v7.py`（24→27）。
- **提交链**：`762bd429`（Task 1：真纯度计算 + 链迁至 IR 生成后重建）→ `c9099d73`（Task 2：分类表补全 / 单一真源）→ `c7ca4251`（Task 3：判据重定）→ 收官（本条目所在提交：全量回归 + 复验 + 本回填）。
- **修了什么（P0 症状）**：`fi_ispure` 由「乐观常量 1」（`checker.cr:1107`/`:1142` 两写入点——**有意保留**为 IR 生成期的冻结输入，见残余面①）改为全程序 IR 面真计算——保守起点（全不纯）+ 调用图不动点升纯 + 递归/SCC 保守 + 不可解析调用保守 + `unsafe` 区不纯 + 泛型（实例按自身体；源 = 实例合取）⇒ `print`/`read_file`/`chan_send`/`sched_go` 等一切可解析但不纯的调用重新入 state 链。分类表 opcode 面收敛为 `purity_op_effect` **单一真源**（D7）：`IR_CALL_EXTERN`/`IR_SPAWN`/`IR_YIELD`/`IR_HOTPATCH_ROUTE`/**间接调用 `IR_DYN_DISPATCH`**/`IR_STORE_PTR`/`IR_AWAIT` 全入链。
- **链覆盖范围（回填口径，供 spec 引用）**：函数内 = store 家族 + 上列全部效应 opcode + 一切不可解析调用 + 一切被判不纯的可解析调用；**链仍每函数重置**（`df_replay_state_chain` 链头重置与 `df_begin_func` 同语义——跨函数不连；判据域内调用节点 = 被调者效应的序代理）。**残余面**：① lazy 判定（`ir_gen.cr:1590`）**有意冻结**（本批 `ir_gen.cr` 零改动 ⇒ 生成期 `fi_ispure` 仍是乐观默认值）；② 其 use_count 时序缺陷**独立未修**（保持登记于「控制流自动惰性」节）。
- **判据（本批确立，见 #26）与收官实测（Task 4）**：全量回归 **38/38 rc=0**（7 bootstrap + 31 selfhost，含 `test_ccr_v7` 27/27 · `test_purity` · `test_compile`）；`tests/suite` 语料 **20/20**（非 `*_mini*` 且非空 = 20 个）build+run rc=0；ELF canary `tests/suite/ptr_arith.cr` = `95084e7b…d475` **IDENTICAL**；语料级「旧前端（Task 1 前）+ 当前后端 vs 当前全链」**20/20 ELF 逐字节相同**（发射面零泄漏；运行 rc/stdout 同）；自举两连建（`build_selfhost_native.py` ×2）corec/corearch/corelsp 产物 sha 逐一相同 + `corec2b`/`corec3b` `cmp` **IDENTICAL** + N06=0 + 冒烟 42。
- **`.ccr` 变更面（Task 4 实测，冷缓存）**：kind=1（链）边增删为唯一语义差；**NOD 语义字段（op/dest/s1/s2/s3/tk）零差异**（节点序不变），唯 `first_edge`/`edge_count` 邻接域随动；STR/SYM/ENT/REG 四段逐字节不变。量级（旧前端→当前）：`CHAIN_SRC` 303→**329**（+26）· `PROBE_SRC` 298→322（+24，但 src 域期望集合未变——Task 3）· `ptr_arith` 293→**318**（+25；Task 1 时代为 317，Task 2 的 opcode 面 +1）· 无效应程序 `fn main()->int{return 42;}` 285→309（+24——**全部**来自编译内建的 runtime/builtin 函数体，该程序自身零调用）。归因（noeffect 逐 opcode）：新增入链目标 = `IR_CALL` +18 入边、`IR_STORE` +6 入边。**效应 opcode 清单唯一 = `purity_op_effect`**（新增 IR opcode 必须同步该处，否则链/纯度两判据漂移——D7 的机械保证）。

### 28. ~~F5 同族：`EXPR_STRUCT` / `EXPR_STRUCTPAT` / `EXPR_ARRAY`（字面量形）的「值节点连续槽位」假设同样不成立 → 静默错误值 + `a[1][0]` SIGSEGV + soundness 漏放~~ —— **已核销（2026-09-16 分类账复核）**：`test_agg_slots.py` 13/13 且挂 CI（三分支两趟）
- **✅ 已修（2026-09-11，本条提交；工作区报告 `.superpowers/sdd/fix-struct2-report.md`；F5 系由 #25 发现者提出）**：parser 三分支统一**两趟**（先解析全部值进暂存表、后统建连续 wrapper）。契约 = `EXPR_STRUCT`/`EXPR_STRUCTPAT`/`EXPR_ARRAY`(字面量形) 的 **a=首 wrapper、b=个数**；wrapper（kind=`EXPR_NONE`）在 `g_ast` 中连续、`wrapper.a`=值节点。消费点 5 处同步逐 wrapper 解引用：`parser.cr:452`（struct 字面量）/ `parser.cr:607`（数组字面量）/ struct 模式分支（同款）· `checker.cr:2513`（`infer_expr` EXPR_STRUCT）/ `checker.cr:2576`（EXPR_ARRAY）· `ir_gen.cr:2087`（`gen_expr`）/ `ir_gen.cr:2112`（数组）/ `ir_gen.cr:2606`+`:2622`（`ast_patch_node`）· `monomorph.cr:282`+`:311`+`:391`（克隆改「先克隆值、后统建 wrapper」）· `opt.cr:130`+`:188`（折叠）。
- **现象（RED 实测，修复前）**：① 静默错误值 `P{a: 11, b: g()}`（`g()->3`）→ `p.b` 得 **0**（`p.a*100+p.b` = 76≙1100，rc=0 无任何诊断）；`P{a: g(), b: h()}` → `p.b` 得 0；② `[[1,2],[3,4]]` 的 `a[1]` 被读成扁平 int 3 → `a[1][0]` **SIGSEGV 139**；`[1, g(), 3]` 的 `a[1]` 得 0；③ soundness：`[[1,2],[3,4]]` 与 `[5,6]` 类型互赋**静默通过**（元素类型被错录为 int）。
- **root cause（实读）**：`parser.cr` struct 字面量分支原文 `fv := parse_expr(); ast_alloc(0, fv, …)` 逐值后随建 wrapper——值节点是复合表达式（调用 / 嵌套字面量 / 下标）时子树自占多槽、夹在相邻 wrapper 之间 ⇒ 第 2 个起槽位整体错位，消费者读到值节点的**子节点**。数组/模式分支同形（数组更甚：连 `[T; N]` 类型形与字面量形共用 `EXPR_ARRAY`，靠 b=0 区分）。**#25 的元组修复即为模板，本条目 = 同契约补齐最后三处实例**。
- **附带修正（同族、原恒空转/旧约定残留）**：`opt.cr` 的 EXPR_STRUCT/EXPR_ARRAY 分支直接对 wrapper 递归，而 wrapper 的 `EXPR_NONE` 在该函数无分支 ⇒ 字段值/元素**从不被常量折叠**（静默空转）；`ir_gen.cr` `ast_patch_node` 的 EXPR_STRUCT 分支同为对 wrapper 空转（泛型实例体内 struct 字面量字段中的方法调用名得不到替换）；`[v; N]` 重复形由「浅拷贝根节点 N−1 份」改为「共享同一值节点 + N 个 wrapper」（语义等价，不再复制多槽子树）；`monomorph.cr` EXPR_STRUCT/EXPR_STRUCTPAT 旧 `gen_clone_consecutive(b, c * 2)` 为「2 节点/字段」旧约定残留（对现 1 wrapper/字段布局**多克隆一倍**）→ 一并改两趟。
- **判据（实测）**：`selftest-types` 95/95 · `test_compile` PASS · `test_purity` PASS · `test_tuple_slots` 14/14（未回归）· `test_ccr_v7` 27/27 · 新增 `tests/selfhost/test_agg_slots.py` **13/13**（值 9 例 build+run 退出码 = main 返回值 & 0xFF：struct 主判据 2 + 三字段中位 + 嵌套 struct + 单槽反证边界 + 泛型实例体克隆 + 数组中位 / 嵌套数组 / `[v;N]`；类型 4 例：嵌套 vs 扁平拒 / 元素数不符拒 / 同形收 / `[T;N]` 类型形控制）+ `src/ci/run.sh` selfhost-tests 挂钩；ELF canary `tests/suite/ptr_arith.cr` = `95084e7b…d475` **IDENTICAL**（该语料**含**数组字面量 ⇒ 数组侧的「AST 布局零泄漏」为实测证据，非同 #25 的「语料无该构造」情形）；`.ccr` sha 与前序状态相同（`ecd7a9df…d29d`，struct 修复后 → 数组修复后未变）。
- **本族剩余面（发现即登记，未修）**：① **struct 字面量字段名被丢弃**——parser 取 `fni` 后从未写入（值按**声明位序**绑定）：`P{b: 11, a: 22}` 静默得 `a=11,b=22`（rc=0 静默错值），字段名/顺序校验、缺字段均不存在；② **struct 字面量字段类型不比对声明**：`P{a: 1, b: "x"}`（b: int）、`P{a: 1}`（缺 b）、`P{a: 1, b: 3}`（b: Q 结构体）全部 rc=0 静默通过；③ **数组元素同质性不检查**：`[1, "x", 3]` rc=0；④ **struct 模式绑定未实现**（`P{a: x}` 中 `x` 报 N01 未定义——checker 对 `EXPR_STRUCTPAT` 直接返 `TI_UNIT`、ir_gen 返 -1）⇒ 模式分支的槽位修复为防御性，无可观测行为变化。以上四项另立条目。

### 29. ~~F5 同族剩余面（#28 修复时发现即登记，2026-09-11——struct/数组字面量的「名 / 型 / 同质性」三校验全缺 + struct 模式绑定未实现）~~ —— **已核销（2026-09-16 分类账复核）**：`test_agg_checks.py` 17/17 且挂 CI + TS01-04/TK02 入硬门（**注**：④ struct 模式绑定 = 新特性，非缺陷，另计）
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
- **P5 继承项（并入 #24 清单；~~已落地~~）**：~~`sh_native_ak_legacy`/`sh_base_ak_legacy` 删除~~ + ~~`type_equal_legacy` 删除~~（**均已删：P5 Task 4 / #47**）+ ~~unknown 清零~~（**已达成：P5 Task 3/3b，见 #46**）。

### 31. CI 挂点缺口：`selfhost-tests` 挂 15/39、`bootstrap-tests` 挂 3/7（2026-09-11 R2 P2b 阶段评审登记——非缺陷，覆盖面缺口）
- **现状**：`src/ci/run.sh` 的 `selfhost-tests` 只跑 15/39 个 selfhost 套件、`bootstrap-tests` 只跑 3/7 个 bootstrap 套件；未挂套件含前序阶段点名的守卫——`tests/selfhost/test_lsp.py`（桥接缓存重置，R2 P2a 评审 Critical 的回归钉）、`test_named_dedup.py`、`test_slice_bounds.py`。
- **影响**：不削弱 P2b 批自身保证（其两个新测试文件已挂 `run.sh:71-72`），但上述守卫此后回归 CI 捕获不到。
- **建议修法**：一次性挂齐（评估耗时后决定全集或分批）。**2026-09-13 进展（P5 T5 / #48）**：`test_named_dedup.py` 已挂进 `selfhost-tests`（点名四守卫之一；另三：`test_backend_bootstrap.py` **经 2026-09-16 实读未挂**（`src/ci/run.sh` 命中 0；全仓仅 `build_selfhost_native.py` 的注释提及——该守卫只在手工全枚举路径执行）、`test_lsp.py`/`test_slice_bounds.py` 仍未挂）。
- **2026-09-12 复测（P3a 收官；#34）**：`selfhost-tests` 挂 **18/42**（期间新增 3 档——`test_match_exhaust` / `test_optional` / `test_generic_constr`——均已挂钩）、`bootstrap-tests` 仍 **3/7**；缺口未变。收官全量枚举（42+7 逐档 rc）仅在收官运行器里执行一次，**未**落 CI。
- **2026-09-14 复测（P5 收官；#49）**：`selfhost-tests` 挂 **28/51**（P5 期间新增挂钩 3 档：`test_named_face` / `test_let_check` / `test_named_dedup`；其余为前批挂点）、`bootstrap-tests` 仍 **3/7**；**未挂守卫** = `test_lsp.py` / `test_slice_bounds.py`（+ 其余按耗时未挂的档）。缺口缩小但未闭合 ⇒ 保留本条。**兜底口径**：P5 起每批收官以**全枚举 58/58**（逐档 rc）实测，不依赖 CI 挂点覆盖面。
- **⚠ 缺口的实际代价（2026-09-12 实证，#34）**：P3 Task 5 的 monomorph 迁出只改了 concat 面清单（`build_selfhost_native.py`），漏改 project-mode 清单（`src/targets/x86_64-linux/_import.cr` 的 `import monomorph`）⇒ project-mode corearch 构建 **33×error[N06] 静默未定义**（rc=0 + 产物照出），**该缺陷在整个 P3a 期间不可见**（5 个任务的回归面均未跑到：`test_backend_bootstrap.py` 正是唯一守卫，而未挂 CI）；收官全量枚举首次暴露（rc=1）。⇒ 本条从「覆盖面缺口」升级为「已有一次真实漏检」；挂齐建议的优先级相应上调（至少把 `test_backend_bootstrap.py` / `test_lsp.py` / `test_named_dedup.py` / `test_slice_bounds.py` 四个点名的守卫先挂）。

### 32. ~~`EXPR_LET` 站点**无任何兼容检查**（2026-09-11 R2 P3 Task 1 实测发现 → Task 4 登记——既有洞，建议专批）~~ —— **已核销（2026-09-16 分类账复核）**：`checker.cr` `check_let_annot_compat` 在位 + `test_let_check.py` 挂 CI（P5 T6）
- **✅ 已修（2026-09-13，R2 P5 Task 6；报告 `.superpowers/sdd/p5-task6-report.md`）**：
  - **修法**：新判定函数 `checker.cr::check_let_annot_compat`（与 `type_compat_strict` / `diag_type_incompatible` 同族），两个调用点共用——① `infer_expr` 的 `EXPR_LET` 分支（局部，本站点）；② `check_global_let`（**全局初始化器**——原登记面 `:1614-1620` 的注册趟同形缺口，本任务**显式划界覆盖**：全局符号同样在注册趟取注解行 ⇒ 不查同样静默错产物）。参序 =（源 = `val_ti`，目标 = 注解行）——Task 1 §3.1 归一。码 = **TA02**（`EC_TA_DECL`，error-codes.md 既有槽位「变量声明类型与初始值不符」，修复前**定义零 raise**；复用而非新码）+ 入 `main.cr` 硬名单 ⇒ `build` 亦拒绝。
  - **豁免四条**（各附理由，见函数头注）：无注解 / `: .` / `: auto` / 无初值（无契约可核）· 注解 `dyn`（按值追踪；照赋值位点）· 值 `TI_NEVER`（底部 + **错误标记=诊断级联抑制**：`x : int = nosuchname` 只发 N01 不叠 TA02）· 注解为泛型形参（声明期不可验证；照返回位点 `return 5` 于 `-> T` 体今天即 rc=0 的既有策略，套件 `let_generic_param_annotation_not_judged` 同策略钉住）。
  - **RED→GREEN（三形态 + 同族）**：`x : int = "s"` / `x : [int;3] = s`（切片）/ `x : [int;4] = [1,2,3]` / `x : int? = 5; y : int = x` 全部 check rc=0 零诊断（冻结基线 `/tmp/p5t0/base/corec` 与本批起点 `2342fd03…` 同值 = 预存）⇒ 现全部 TA02 定位硬错 + `build` rc=1 **无产物**（拒绝早于 lower/写 .ccr/ELF）。
  - **report-only 全语料（开门依据）**：72 档 runner `check` **rc 34×0/38×1 与 pre-P5 基线逐档同 + 诊断正文逐条同（归一化）**；`check src/compiler` rc=0 零诊断；**58 套件全枚举**（tests/selfhost 内联源 + tests/bootstrap 全部经 corec 编译）命中面 = **1 例**（`test_named_face.py::named.in_container_same` 的 `p : *NA = 0;`）⇒ 已按「与赋值位点既有语义对齐」修正为无初值声明（`*T ← int/null` 在**赋值位点**早已 TA01 拒绝，两侧同证；非新增语义，见报告 §收紧台账）。
  - **判据（全部本实例实跑，二进制 `f737e26b…`）**：新套件 `tests/selfhost/test_let_check.py` **24/24**（含正控 13 + 级联抑制 2；挂 `src/ci/run.sh` selfhost-tests）· `selftest-types` **404/404** · `check src/compiler` rc=0 · `test_backend_bootstrap` rc=0 + `error[`=0 · 五 CI job 全 rc=0 · 全枚举 **58/58** · **ELF canary `95084e7b…d475` IDENTICAL** · `.ccr` 两套口径四条与 T5 记录**逐字节同**（`ptr_arith` `fb4a3b59…`/`592afa31…`；`generics_test` `ddec1ce6…`/`cd2af565…`）· 自举链 `corec2==corec3` cmp IDENTICAL（`5559beef…`）+ N06=0 + 冒烟 42 + `--help` rc=1 · 冻结基线同源对拍 72 档 **rc + 诊断正文零差异** · **突变控制 4 条**逐条单点转红（局部调用点移除 → 15/24；豁免④移除 → 23/24；硬名单条目移除 → 20/24「静默面复活」；全局面调用点移除 → 23/24）并**精确回滚**（源 sha + 三二进制 sha 复原）。
  - **未覆盖 / 登记**：`-> never` 函数的**调用**被推断为 unit（非 never；`return boom()` 今天即 TF01）⇒ `x : int = boom()` 新增 TA02——与邻站现状一致、非新类，全语料零 `-> never`；`EXPR_FOR` iterable 接线（附录 E-6）与 **#20（F3 调用位点）** 不并入本任务（本任务只落声明位点；#20 仍开放，见其条目）。

### 35. ~~前端枚举表**写入侧无护栏**：≥17 变体 / ≥17 载荷类型越界写（2026-09-12 R2 P3a 阶段评审登记——**#8 同族**；代码级定位 + check/build 两面实测）~~ —— **已核销（2026-09-16 分类账复核）**：**转历史**：容量批 E-3 三 `MAX_*` 退役 + P022/P023 停发（`ast.cr:338-339` 注「已退役、零 raise」）+ `test_enum_limit.py` 挂 CI
- **✅ 已修（2026-09-13，R2 P4 Task 6；工作区报告 `.superpowers/sdd/p4-task6-report.md`）**：
  根因 = `EnumVariant` 槽区（16 槽 × `OFF_EV_SIZE=272`）与 `StructInfo` 字段槽区（16 槽，**同族第三处**，本轮 RED 步实测 `check` rc=0 静默）是**定长内嵌槽区**——其后紧跟自身 count/generic 槽，再往后是**邻记录**（同一 buffer），而 parser 的写入循环对 `vc`/`tc`/`fc` 零上限闸。
  **危害形态（首次构造，收口本条「未做」项；二进制 = 修复前 `6afbd333`，三档探针 + 突变对照）**：(a) 17 变体声明 `check` **rc=0 零诊断**；(b) **该枚举上的 match 穷尽性判定被静默禁用**——第 17 变体名槽与 `variant_count` 同址（4360），count 后写胜出 ⇒ 第 17 名槽存的是 count 值 ⇒ `sh_variant_term` 的「名→变体项」查表失败 ⇒ 域不可展开 ⇒ 三态回落 **-1「不判」** ⇒ **真·非穷尽 match 也 rc=0 零诊断**（对照：16 变体同形必报 TM03——同探针实测）；(c) 第 17 变体**不可构造**：`V16()` ⇒ 假诊断「Undefined enum constructor 'V16'」；(d) 17 字段结构体 / 17 载荷类型同族（载荷第 17 槽写 = `OFF_EV_TYPE_COUNT`、第 17 载荷**节点**写 = 下一变体槽首 `OFF_EV_SIZE`）。越界写多数落在 `grow_enums`/`grow_structs` 的扩容余量内 ⇒ **无 SIGSEGV 可观测**——危害 = **表污染 + 判定静默**（不是崩溃），故 `check` 面全静默。
  修复 = ① parser 三处写入点跳过超限槽（计数保持真值，照 P020 的 `add_func(pc)` 先例）+ 末尾 `error[P022]`（枚举变体/载荷）/`error[P023]`（结构体字段）**定位硬错**——由 **parse 阶段诊断闸**（`main.cr` 的 `[3/5] parse...` 之后 `g_diag_count > 0 ⇒ rc=1`，与 P019/P020/P021 同款）拒绝；实测 **hard 名单条目对本族冗余**（删条目零行为差异 ⇒ 未加）⇒ 拒绝发生在**前端**，不进入 lower/写 `.ccr`/ELF（阶段断言入回归用例）；② `dyn_arr.cr` **唯一受护写点**（`ei_set_variant_name/type/type_count/type_node` + `si_set_field_name/type/type_node`，照 `fi_set_param_type` 先例）+ **读护栏**（`vi ≥ MAX ⇒ 名字/类型码/类型节点 -1、计数 0`；count 保持真值使 `.ccr` 读回闸仍响亮）。
  回归 = `tests/selfhost/test_enum_limit.py`（13 例：16 边界三面正控 + 17 变体/载荷/字段 × check+build 拒绝 + 无产物 + 「拒绝早于 lower/写 .ccr/ELF」阶段断言）+ `src/ci/run.sh` 挂钩。
  判据（Task 6 实测）= `check src/compiler` rc=0 · `test_backend_bootstrap` rc=0 + `error[`=0 · `selftest-types` 355/355 · **ELF canary IDENTICAL** · **`.ccr` 与修复前编译器逐字节同**（`ptr_arith` `592afa31…` 90966B / `generics_test` `ec8413ec…` 134844B——同源双编译器对拍：修复前二进制 `6afbd333` × 修复后 `5d2b15ad`）· 全枚举 55/55 · 自举链 · 突变控制（删 3 条诊断 ⇒ **8 例红 + 静默面复活**（`check` rc=0）；复位 ⇒ 二进制逐字节复原 `5d2b15ad`）。
  **未解除（评估见 Task 6 报告 §解除评估）**：三上限仍为 16；`MAX_GENERICS=4` 面不属本类（写入侧有界，超限 = parse 期硬报 P01 desync，无静默接受面）；`MAX_IFACE_METHODS/PARAMS` 已有 P13/P11 硬错护栏（本轮复测成立）。
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

### 40. ~~TF01 收口：`check src/compiler` 两条长期诊断（2026-09-13——落空分析 + `lits_copy` 类型洗白；**check 门 rc 归零 + P4 Task 2 corearch 清单步解阻**）~~ —— **已核销（2026-09-16 分类账复核）**：`checker.cr` `stmt_cannot_fall_through` 在位 + `check src/compiler` rc=0（T0 实测）
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

### 42. R2 P4 Task 4：DFNode.TK 迁移期双槽（2026-09-13——允许清单制派生 + `.cir` 快照不落槽（实测推翻计划 D15 前提）+ 发射面零泄漏证明）
- **交付**：本提交（路径限定 9 文件 = `src/compiler/{dyn_arr,dataflow,ir_gen,ty_shadow,cir_cache,dump,main,type_selftest}.cr` + `tests/selfhost/test_ccr_types.py` + `src/ci/run.sh` + 计划/格式 spec）。详版 = `.superpowers/sdd/p4-task4-report.md`。
- **双槽形态（D15）**：`ESZ_DFNODE` 64 → **72B**；`OFF_DF_TK=40` **语义/字节零变化**（混用码原样），新增 `OFF_DF_TK_TERM=64`（类型项引用，-1 = 无项）；唯一写点 = `df_create_node`（emit 传参；`dataflow.cr` 不引用桥接符号）。
- **允许清单推导（Step 2 产物）**：`instr.cr` 全文件 `ti` 消费者 **5 处**（`IR_CONST(ti==TI_STR)` · `IR_BINARY(ti==TI_DEX)` · `IR_DEREF`/`IR_STORE_PTR` = `e2_ptr_bounds_check` 的 **access_width** · `IR_BOUNDS_CHECK(ti!=0)` 旗标）× 216 个 `emit(` 调用点逐 op 静态审计 × 全语料 NOD 的 (op,tk) 直方图 ⇒ **清单 = {IR_CONST, IR_BINARY}**。**实证陷阱两例**：`ptr_arith` 的 `IR_DEREF/IR_STORE_PTR` 传 `tk=8`（访问宽度，数值恰 = `TI_DEX_S` 行）、`IR_BOUNDS_CHECK` 传 `tk=1`（动态上限旗标，数值恰 = `TI_DEX` 行）——无差别派生即凭空安项。排除面登记：`IR_ALLOC`/`IR_CALL`/`IR_I2F`/`IR_F2I`/`IR_LOAD` 传合法类型行但后端不按 `ti` 分派 ⇒ 暂不入清单（P5 再裁）。
- **`.cir` 快照 = 不落项槽（**计划 D15 的实测修正**）**：计划原写「快照入项槽 + `CIR_CACHE_VER` 17→18」，前提「不入槽 ⇒ 冷/暖分歧」**被实测推翻且方向相反**：入槽版本 `ptr_arith` 冷 `terms=13 bad_term=0` vs 暖 `terms=10` **`bad_term=329`**（恢复来的项引用全数越出暖进程项表——项表是**进程内**内容寻址表、emit 期按需追加）。修正 = 快照记录仍 **8×8B = 64B**（格式零变化 ⇒ **不 bump**），装载侧在 **emit 等价时点**（逐函数逐节点序）`sh_tk_term_of_code(opcode, tk)` 重派生 ⇒ 冷/暖 `(op,tk,term,tag,a,b,c)` **逐行相同**（实测 1298 行全等、两态 `terms=13 bad_term=0`）。另：落盘 = 「纯函数值与其入参并存」= 第二真源（本仓反复治过的病）。
- **通道**：新增 corec hidden flag `cir --dump-tk-terms`（只读；逐节点 `op/tk/term/tag/a/b/c` + 头行 `nodes/with_term/bad_term/terms/allow`）；带/不带 flag 的产物与 stdout（剔 dump 节）逐字节同。
- **判据（最终二进制 `1cc18c7d…`）**：构建 rc=0（三面 `error[`=0/undefined=0，两连建逐字节同）· **`check src/compiler` rc=0** · `test_backend_bootstrap` rc=0 + `error[`=0 · `selftest-types` **347 → 355**（`t4.tk_*` 8 例：3 正控 + 4 负控 + 1 计数纪律）· `test_ccr_types` **28 → 34** · **ELF canary `95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475` IDENTICAL**（clean-cache）· `.ccr` 八段逐字节同（`ptr_arith` 90823B `fb4a3b59…` · `generics_test` 134701B `cafb4278…`——**用户程序零扰动**）· `--dump-objects` 逐字节同 · 五 CI job 全 rc=0 · 全枚举 **54/54** · 自举链 `corec2==corec3` cmp IDENTICAL（双 2754918B `55237ec1…`）+ N06=0 + 冒烟 42 + `corec3 --help` rc=1 · 同源对拍 check/shadow **两侧 diff 空**（`decisions=32355=agree`；站点覆盖 assign-node=24561 · fn-body-ret=5747 · if-branch=2013 · struct-field-type=28 · array-elem-type=4 · generic-apply-base=2）· 编译耗时抽样：6000 语句合成源 min **2957 → 2933ms**（噪声内；小语料 26–36ms 两态同）。
- **突变控制（/tmp 侧，仓库零改动）**：A（清单门 + hits 复原移除）= ㉖ 转红 + selftest 4 例转红（351/355）；B（装载侧重派生移除）= ㉙ 转红（暖态 `with_term=1354` vs 冷 `348`）。
- **登记/承接（P5）**：① 单槽化时 `tk` 本身 = 项引用 ⇒ 盘面项槽/`.csr` 消费面另定；**项引用的稳定形态**（内容寻址 / 落盘项 ID / 同款重派生）是 P5 前置裁决项——**不得**直接落进程内索引（本任务 `bad_term=329` 即红证）；② 本批 `tk_term` 无生产消费者（价值由内容断言兑现，不假装有外部消费者）；③ 冷/热 **`cir` 文本 dump** 的渲染差异（变量名 vs 数字）为既有面（TODO #5 末条，baseline 二进制度量 1620 行 diff，非本任务引入）。
- **关联**：#41（Task 3）· #39（P3b 交接附录 C 待裁决 8 = TK 升格）· 计划 `docs/superpowers/plans/2026-09-12-r2-p4-carrier.md` Task 4（D15）· spec `docs/superpowers/specs/2026-09-10-type-interface-unification-design.md` §6.2。

### 43. R2 P4 Task 5：可选运行期表示——解包侧判表示（2026-09-13——B.7 一等条目闭合 + 三根因连带修）
- **交付**：本提交（路径限定 9 文件 = `src/compiler/{ir_gen,globals,main}.cr` + `src/arch/x86_64/instr.cr` + `tests/selfhost/test_optional.py` + `src/ci/run.sh` + 计划 ×2 + 本条目）。详版 = `.superpowers/sdd/p4-task5-report.md`。
- **形态（裁决 5 = 解包侧判表示）**：**表示位 = 普通 int IR 变量**（每个可选槽一个；0 = 裸值「槽内即 T 值，Some 臂载荷 = 槽值本身」/ 1 = 装箱「`IR_MAKE_ENUM` 对象，载荷 = 字段 `fi+1`」）。**写点置位**（`EXPR_LET`/`EXPR_ASSIGN`：静态已知 → 常量、源有表示位 → 拷贝）+ **两解包点分派**（`match` 的 Some/None 臂条件与载荷绑定、`?`）。**无表示位的槽 = 逐字走既有路径**（未覆盖面不静默分歧的结构保证）。**跨函数面 = 隐藏全局信道**（返回点写/调用点读、调用点写/被调序言读；纯 IR）。**纯 IR ⇒ 零 ABI/opcode/帧布局改动 ⇒ ELF 与解释器同源**。
- **零足迹门**：AST 无 `EXPR_OPTIONAL` 且无 `Some`/`None` ⇒ 整面不启用 ⇒ **非可选程序发射面逐字节不变**（ELF canary `95084e7b…d475` **IDENTICAL** + `ptr_arith`/`generics_test` `.ccr` 与基线编译器同源重建**逐字节同** + `--dump-objects` 逐字节同）。
- **根因（5 条；后 4 条为计划未列面，逐条实测定位）**：① 表示位侧表空槽哨兵——`alloc` 零初始化而哨兵 = -1 ⇒ 未写槽读 0（= 「表示位 var 0」）⇒ 全部置位取 0；修 = 新槽填 -1（照 `tag2l.cr` 先例）。② **ELF 后端逐 op 的全局行分派缺口**（同族三处）：(i) `IR_CONST` 无全局行分支（`g2_slot` 对全局返回帧外伪偏移 ⇒ 写栈垃圾 = 静默丢写；解释器直写 `g_ir_vals` ⇒ **双路径分歧**）——本任务首次出现该发射点（形参信道单元）；(ii) **`IR_LOAD_ENUM_TAG` 的 tag 读取源同缺**（全局可选槽 + match ⇒ ELF 0 / 解释器 5 = 静默分歧，**基线同病**，本任务 §未覆盖面实测时发现）；两处均按 `IR_LOAD`/`IR_STORE` 同款修（源走 `e2_load_var` / RIP 直相对 + patch 记录），目的槽的全局行零发射点（注释登记）；`TI_STR` 变体仍零发射点（已注释登记）。③ **负值文件级常量在自举二进制里静默读 0**（= TODO #14 的 live 触发；改用 `oe_bare()/oe_boxed()` 函数）。④ 返回类型判据取 `fi_return_type` **裸码**（`T?` 的类型节点 `type_val` = 0 ⇒ 读成 int 行、判据恒假）⇒ 改走返回类型**节点**（被调序言 + 调用点两侧同改，新增 `callee_ret_optional`）。⑤ 惰性 thunk 把调用推迟到 force 点 ⇒ 返回信道读点悬空 ⇒ **被调返回可选者禁 thunk**（代价仅此一类）。
- **判据**：构建 rc=0（三面 `error[`=0）· `check src/compiler` rc=0 · `test_backend_bootstrap` rc=0 + `error[`=0 · `selftest-types` **355/355**（用例数不变）· `test_optional.py` **12 → 34/34** · **ELF canary IDENTICAL** · `.ccr` 新记录值 `ptr_arith` **90966B** / `generics_test` **134844B**（与 Task 4 记录值的 +143B **非本任务**——同源用基线编译器重建同得该差，= 期间 `arena_globals` 导入引入的 4 全局 + 1 串，逐段点名）· 可选程序冷/热 `.ccr` IDENTICAL · 自举链 `corec2==corec3` cmp IDENTICAL（双 2783750B `5492d9ad…`）+ N06=0 + 冒烟 42 + `corec3 --help` rc=1 · 全枚举 **54/54** · CI {check,bootstrap-tests,suite,selfhost-tests} 全 rc=0 · 同源对拍 check/shadow 两侧 **diff 空**（`decisions=32564=agree`；站点覆盖 assign-node=24709 · fn-body-ret=5793 · if-branch=2028 · struct-field-type=28 · array-elem-type=4 · generic-apply-base=2）· 编译耗时：可选 315→282ms、非可选 55→55ms（无回退）。
- **台账**：放宽 **0** / 收紧 **0**（判定面零变化由对拍反证）；修复 **8 形态**（局部裸值路径 + 返回/形参裸值路径）+ **1 静默错值类**（`?` 解包装箱值：修复前 ELF=8 / interp=200 **各错各的**，现 7/7）。
- **未覆盖面（登记，不静默）**：结构体字段 / 数组元素 / 全局槽 / match 结果 / 可选的惰性 thunk（**后者已由 ⑤ 关闭**：返回可选的被调不做 thunk）⇒ 不配表示位 ⇒ 解包回落既有装箱假定：裸值形态 **rc=139 双路径同**（响亮）、装箱形态照常正确；`test_optional.py` 两例分别钉。修复面（对象布局里放 packed 表示位 / 数组 stride）归 P5 与 `MAX_*` 定长槽评估同批。
- **登记面**：⓪ **预存缺陷（实测发现，非本任务引入）**：冷/热缓存下 `corec build src/compiler/main.cr -O 0` **暖态 SIGSEGV**（`load_cir_cache` → `str_len`，gdb 栈实测；**基线二进制同病** 冷 rc=0/暖 rc=139）——本任务「可选面关缓存」顺带规避（仅限可选程序）；归 `.cir` 缓存恢复面（TODO #5 末条同族）转主批。**→ 已闭合（R2 P5 Task 1，本批提交 `fix: R2 P5 Task 1——…`）**：根因 = 装载侧逐函数 `read_file` = `alloc(fsize+1)` 而 bump 分配器不回收 ⇒ 946 个快照读缓冲累计 **1.1674GiB > 1GiB 堆** ⇒ `alloc` 耗尽返回 0（`.Lalloc_oom`）⇒ `str_len(0)` → `load64(0,-8)`；修 = `cir_cache.cr::cir_read_snapshot` **单一复用读缓冲**（与写侧 `g_cir_write_buf` 同构；失败 ⇒ `-1` = miss，三态纪律）+ 新套件 `tests/selfhost/test_cir_warm_path.py`（19 例，自源另开 2 例；RED 对照 15 PASS/1 FAIL）+ 突变控制。判据与证据 = `.superpowers/sdd/p5-task1-report.md`（`CIR_CACHE_VER` 保持 17：写读对称表核 ⇒ 格式零变化）。① **可选面启用即关 `.cir` 缓存**（表示位侧表 = 编译期进程内状态、快照不载 ⇒ 命中恢复与冷路径产物分歧，同 Task 4 `bad_term=329` 教训形态；非可选程序照常缓存；P5 若要收回须给快照加表示位面或装载侧重派生）；② `IR_CONST` 的 `TI_STR`+全局行未分派（零发射点）；③ 影子通道**零覆盖载体面**（正确性证据一律 = 行为探针 + 双路径同值）。
- **关联**：#42（Task 4，`.cir` 快照面）· #14（本轮**触发实证 ②**：负值文件级常量；连带 live 实例 = `CIR_CACHE_MAGIC` 在自举二进制读 0 ⇒ 落盘 `.cir` magic 实测全 0、写/读自洽故不炸测试）· P3 计划附录 B.7（本节顶部已标 ✅ 闭合）· 计划 `docs/superpowers/plans/2026-09-12-r2-p4-carrier.md` Task 5 · spec `2026-09-10-type-interface-unification-design.md` §9 P3 行（未统一条目已划销）。

### 44. R2 P4 收官（2026-09-13——载体批 8 提交链 + 统一台账 + 判据复验 + P5 交接包；**P4 全阶段收官**）
- **提交链（8 提交 + 附带件 1；计划定稿 `3f8885ec`）**：`7c822003`（T0 引擎核纯化拆分：iface 簇 + `iface_kind_of` → `iface_axis.cr`，corearch 链接面开路；零行为变化）→ `97febdbf`（T1 段机制：`TYPE(7)`/`IFACE(8)` 加段 + 版本 7→8 + loader 三闸/必备集；两段空壳）→ `3d604e11`（T2 TYPE 段内容：类型行表 24B + 项 DAG 40B（哈希不落盘）+ D13 确定性装填 + corearch 读回重建）→ `6822102a`（附带件 TF01 收口 = T2 §9-② 路径 (a) 兑现；`check` job 判据自此按 rc=0）→ `8f4af99b`（T3 IFACE 段内容：原生条目扩列 13→16 + 形状命名化 + 签名项化 + impl 边/方法表 + 读回）→ `387abf2e`（T4 DFNode.TK 迁移期双槽：允许清单制 `{IR_CONST,IR_BINARY}`；**计划 D15 被实测推翻**——`.cir` 快照不落项槽、`CIR_CACHE_VER` 保持 17、装载侧 emit 等价时点重派生）→ `2be26cc5` + `cf368259`（T5 可选运行期表示解包侧判表示：B.7 裸值 + `Some` 臂双路径 rc=139 闭合；补 `IR_LOAD_ENUM_TAG` 全局行分派）→ `cc015ae4`（T6 `MAX_*` 写入侧护栏 P022/P023；三上限不解除）。
- **判据（T7 实跑，2026-09-13；无并发构建窗口；五 CI job + 全枚举 + canary + 自举链 + 同源对拍全部由本实例重跑——碰撞窗未背书项一并复现）**：五 CI job 全 rc=0 · 全枚举 **55/55 rc=0**（48 selfhost + 7 bootstrap）· `selftest-types` **355/355** · `check src/compiler` rc=0 · ELF canary `95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475` **IDENTICAL**（28822B）· 自举链 `corec2==corec3` `cmp` **IDENTICAL**（双 2792078B `4919023b…f9034`）+ 构建日志 **N06=0** + 冒烟 **42**（corec/corec2 双通道）+ `corec3 --help` rc=1 · 构建确定性（`build/corec` = `5d2b15ad…` 与 T6 记录值逐字节同）· 段结构断言（version 8 / seg_count 8 / tag 序 1..8 / 连续 `end == fsize`）。
- **同源对拍（pre-P4 二进制 `9a583215…` × 当前源 vs 当前二进制 × 当前源；72 档 × {check, shadow}）**：影子摘要两侧同值（70 档出摘要，`decisions=32620 agree=32620`，`old_stricter`/`old_looser`/`unknown*`/`replace_*` 全 0）；站点覆盖两侧逐项同（assign-node=24721 · fn-body-ret=5828 · if-branch=2037 · struct-field-type=28 · array-elem-type=4 · generic-apply-base=2；Σ = 32620）；日志面唯一差异 = **5 档语料**的 TF01 收口类（5 处 `ty_memo_slot_no_grow` 误报消失 + 3 档 rc 1→0；rc 分布 31/41 → 34/38）= P4 内**有意修复**，非语义回归。**载体面零覆盖声明（继承）**：影子通道对段/读回/TK/表示零覆盖，P4 载体正确性证据 = 结构性断言 + corearch 读回对拍 + 定向探针。
- **`.ccr` 记录值（两套命令口径；T7 复测逐条复现）**：`corec ccr F -o O` = `ptr_arith` **90823B** `fb4a3b59…` / `generics_test` **134701B** `cafb4278…` / 自源 **10661888B** `76c76bb1…`（自源随源变更，不与前批直比）；`corec build F -o O --static` = **90966B** `592afa31…` / **134844B** `ec8413ec…`（差恰 143B = `--static` 前置 `rt.cr`）。**冷/热勘误（本轮确立判据）**：非可选程序冷≠热为**预存**（pre-P4 二进制同病 89086/88954；TODO #5 末条家族）⇒ 「冷/热两态逐字节同」只对**可选面零足迹**程序成立（可选程序 97604B `2bfbbe2b…` 冷≡热）；**TYPE 段「纯函数」承诺项面成立、行面不成立**（T2 §8-③：行表热 12/冷 15，前缀关系）。
- **统一台账（T0-T6 汇总；逐条出处 = 各任务报告）**：收紧 **10 类**（T1 3：缺 TYPE 段 / 缺 IFACE 段 / 版本≠8 整类拒收；T2 2：装填不可译行 save 拒绝 + loader TYPE 结构不变量；T3 2：签名不可建 save 拒绝 + loader IFACE 五小节/跨段引用域；T6 3：P022 变体 / P022 载荷 / P023 字段）· 放宽 **2**（T2/T3 的 T1 空壳闸退役，非语义放宽）· 崩溃/静默修复 **8 形态 + 1 静默错值类**（T5：裸值路径 rc=139 → 正确值；`?` 解包装箱值双路径各错各的）· 全语料命中 **0**（report-only 逐批：T1 72 档、T2 56 档、T3 61 档、T6 139 文件静态扫描 + suite/examples 逐档——失败集与各自基线逐条相同）。
- **实施偏差（实测推翻/修正计划文本者，逐条登记）**：(a) T4 的 `.cir` 快照「入项槽 + `CIR_CACHE_VER` 17→18」被推翻（入槽版暖路径 `bad_term=329` 全悬空 ⇒ 不落槽 + 装载侧重派生）；(b) T2 的「TYPE 段冷/热逐字节同」半成立（项面成立、行面不成立）；(c) T2 spec §3.7 的 `{kind i32…}` 字段宽度与 24B 段体自相矛盾 ⇒ 实施权威 = 8B 字段；(d) T3 方法记录字段序取计划「声明行」序（同块尺寸式两数组次序相反）；(e) T1 计划 Interfaces 的段体缓冲延后到 T2 的内容构造者。
- **P5 交接包** = 计划 **附录 D**（D-1 两套口径 + 冷/热勘误表 · D-2 任务面：单槽化 + 大步删旧路径 + 文档/台账 · D-3 十四项继承项 · D-4 开工前置检查单）；指针链 = 统一设计 spec §9 的 P4 行 → 计划 Task 7 → 附录 D → 本条。**必读三项**：D-3-2（项引用稳定形态先裁——`bad_term=329` 红证）、D-3-4（unknown 清零 (a)/(b) 先裁）、D-3-9-(ii)（预存暖态 SIGSEGV：`corec build src/compiler/main.cr -O 0` 暖态 rc=139，`load_cir_cache` → `str_len` 栈，基线同病）——**已闭合（R2 P5 Task 1，本批首提交**：装载侧读缓冲累计 > 1GiB 堆 ⇒ 单一复用缓冲 + 载入失败 ⇒ miss；判据见 `.superpowers/sdd/p5-task1-report.md`）。
- **关联**：#26（判据重定——P4 继承注见该条）· #40/#41/#42/#43（P4 逐件落地）· #35（T6 划销）· #32（`EXPR_LET` 无检查——未随 P4 收口，P5 继承）· #5 末条（冷/热 `.ccr` 分歧——本轮量化并重定判据）· 报告 = `.superpowers/sdd/p4-task7-report.md`（工作区）。

### 45. R2 P5 Task 2：DFNode.TK **单槽化（α）**（2026-09-13——类型面单源 + 辅码分离 + `atom_of` 契约；**零行为变化**）
- **形态（D19）**：`OFF_DF_TK`(40) 语义 = **类型项引用**（类型面唯一真源）；`OFF_DF_TK_TERM`(64) 更名 **`OFF_DF_AUX`** = 辅码（旗标/宽度/计数/不可逆行的原码；0 = 无）；`ESZ_DFNODE` 保持 72B ⇒ **布局零变化**（`CCR_VERSION=8` / `CIR_CACHE_VER=17` / `.ccr` NOD 36B / `.cir` 快照 64B·节点均不动）。码 = **派生量**：`iri_tk`/盘面一律 `sh_dfn_code_of_slots(项, 辅码)`。
- **分类表（Task 0 表 A 代码化，`ty_shadow.cr`）**：类型行面 = `{IR_CONST, IR_BINARY}` ∪ **P4 六排除项再裁** `{IR_ALLOC, IR_CALL, IR_LOAD, IR_I2F, IR_F2I}`（P4 的「后端不按 ti 分派」= 发射面判据，不适用于语义类型面；`IR_LOAD_ENUM_TAG` 两调用点传字面量 0 ⇒ 仍「无面」）；辅码面 = `{IR_BOUNDS_CHECK(0/1 旗标), IR_DEREF/IR_STORE_PTR(宽度), IR_SPAWN(-1=动态), IR_HOTPATCH_ROUTE}`；其余无面。
- **F1（协调者裁决：修调用点，不把 UB 烘进表）**：`ir_gen.cr:1758` 5 参 `emit` ⇒ op39 的 tk = **r9 残留**（bootstrap 只为实际实参写寄存器；实测 0/4 两态）⇒ 补显式第 6 实参 `0`；**已裁决偏差** = 含 hotpatch 语料该节点码 **4→0**（全语料 3 节点，零消费者；`hotpatch_test.cr` 的 `.ccr` 相应差 3 处）。
- **F2（协调者裁决：分类表只覆盖原子行）**：复合行（ptr/ref/array/slice/optional/null/tuple 行 —— 项不可逆）**不建项**（`atom_of` ⇒ -1，不近似），原码进辅码槽**保真**（Task 0 候选 (iii)+(ii)）⇒ 派生码逐字节 ≡ 旧混用码。**证明**：5 个 `ti` 消费者谓词的值敏感面 = `{TI_STR=3, TI_DEX=1, 宽度, 旗标}`，复合行码（实测仅 `ptr_ref_first` BINARY tk=10 + 夹具 tk=13）永不落入 ⇒ 不变按构造成立（突变 M1 反证该格可抓）。
- **D23 新硬错**：类型面行的可译性闸——**仅 emit 路径**计数（装载侧不计数：暖进程类型表可更小，见下）、`ccr_seg_prepare_save` 入口拒绝落盘（rc=1 + 计数诊断）；**全语料 0 命中**（94 档 `face_fail=0`，report-only 先行）；牙齿 = 突变 M4（越界行 ⇒ rc=1 + 无产物）。
- **判据（本任务实跑；报告 `.superpowers/sdd/p5-task2-report.md`）**：`selftest-types` **367/367**（355+12）· `test_ccr_types` **40/40**（34+6）· `test_cir_warm_path` 19/19 · `test_cache_identity` 5/5（`VER_EXPECTED=17` 未动）· `check src/compiler` rc=0 · `test_backend_bootstrap` rc=0 + `error[`=0 · **ELF canary `95084e7b…d475` IDENTICAL**（28822B）· `.ccr` 两套口径冷态四条与起点基线逐条同 · `--dump-objects` 逐字节同（2427 行）· **派生码不变量**：94 档逐节点 diff = 仅 F1 的 3 节点（非自源 338,207 节点余者 0）· 全枚举 **56/56** · 五 CI job rc=0 · 自举链 `corec2==corec3` cmp IDENTICAL（2821374B）+ N06=0 + 冒烟 42 · 72 档 `check` 同源对拍（rc 同；日志差 2 档自源行号位移）· 影子对拍 `decisions=agree=32767` + 全分类计数 0 · **突变控制 4 条**逐条转红。
- **判据重定（2 处，实测驱动）**：① 冷/暖比对由「索引全等」改为「**派生码面（op,tk,aux）逐行同 + 项内容（tag/a/b/c）等价**」——**暖态类型表/项表可小于冷态**（缓存命中跳过 `ir_gen`，而其自身 `alloc_type` 新行 ⇒ 冷态存在的行暖态不存在 ⇒ 该项不可重建；P4 窄清单掩盖、P5 扩面暴露；派生码与发射面/盘面零影响）；② `--dump-tk-terms` 头新增 `rows=`/`aux_nonzero=`/`face_fail=` 观测列。
- **P6 承接**：暖态项面差异的根治 = **β 盘面项索引**（附录 E-1；D20-② 的许可形态）；本批盘面只承载派生码（进程内项引用零跨进程）。
- **关联**：#42（P4 T4 的「P5 再裁」= 本条）· #24/#30（`g_shadow_map`/影子层 = P5 T5 面）· #44（P5 交接包）· 计划 `docs/superpowers/plans/2026-09-13-r2-p5-cleanup.md` Task 2 实施记录。

### 46. R2 P5 Task 3：unknown 清零——**命名面判定化**（2026-09-13——身份链 + 可判定面加强；裁-2 (a)）
- **形态**：桥接层给命名原子挂**身份链**（`ty_shadow.cr`）：`TYP_NAMED`/`TYP_GENERIC_PARAM` ⇒ `tt_atom(AK_NAMED, 本行, [名字令牌])`；`TYP_GENERIC_APPLY` ⇒ `tt_atom(AK_NAMED, **基型行**, [基名令牌, 实参项…])`（基型行 = **规范形**：两处实例化同型 ⇒ 同节点）；**两构造点**（`sh_term_of_ti` / `sh_sig_term_of_ti`）**逐位同构**（停条件③不触发）。引擎 `type_engine.cr`：`lit_implies` 正原子分支 AK_NAMED 守卫 → `te_named_pair`：**同类 ⇒ 链比较**（令牌位 = 节点同一性 / 实参位 = 引擎 `ty_equiv` 三态）、**混类 ⇒ 0**（命名侧带链 ∧ 异类侧非 NEVER/DYN）、**域外 ⇒ -1 + uncovered**（空链 / 令牌位错位 / 实参位 μ 变元 / NEVER·DYN 混类）。**不接结构性展开**（P3a 反证口径保持：展开项结构相等 1 与桥接项 0 双断并存）。
- **清零判据（实跑）**：语料 72 档 shadow `decisions=agree=32917`、`old_stricter/old_looser/unknown*/replace_*` **全 0**；**探针可判定域 18 档 `unknown_engine`/`replace_unknown` = 0**（RED = 1~2/档：Table D 两形态「异名同形命名」「同实参泛型应用两实例化」+ 异实参应用 / 命名 vs 原生 / 可选异名 / 应用含命名实参 / 嵌套应用 / T 赋 int）；rc/诊断**逐条不变**（清零 ≠ 放宽 ≠ 收紧）。
- **判据**：`selftest-types` **386/386**（367+19；3 处重钉：`t3.named_face_decided_no_fallback` / `unf.nominal_equiv_atomic_decided` / `unf.nominal_type_equal_false`）· 新套件 `tests/selfhost/test_named_face.py` **18/18**（行为断言形态，**不依赖影子通道**——T5 下线后照常）· ELF canary IDENTICAL · `.ccr` `ptr_arith` 逐字节同 / `generics_test` **+640B**（TYPE 段项表 52→68 行；发射面零泄漏：ELF 逐字节同 + `--dump-objects` 同 + `.cir` DOT 同）· check 语料 34×0/38×1 逐档同 · **D26 同源对拍零差异** · 全枚举 57/57 · 五 CI job rc=0 · 自举链 cmp IDENTICAL + N06=0 + 冒烟 42 · **突变控制 3 条**逐条转红 + 精确回滚（报告 `.superpowers/sdd/p5-task3-report.md`）。
- **收紧面（登记，提请复核）**：混类判定从 -1 变 0 ⇒ 约束站点（`gen_constr_satisfied`/`gen_inst_constr_satisfied`）「命名实参 × 原生约束」由**不判**变 **TG02**（`check` rc=1；`build` rc 不变——TG02 非硬名单）。**全语料 0 命中**；唯一命中 = `test_generic_constr.py` 1 例登记面（已重钉 `struct_inst_named_arg_rejected`）。回退面 = 混类分支回 -1（探针 n10/n20/n21 计数将复红）。
- **残留 -1（可判定但本任务不动，计划停条件②）**：参数链**不变槽**元素非同形（`[NA;2]` vs `[NB;2]` / `*NA` vs `*NB` / 元组含异名）——行为面早已正确拒绝，残留仅在计数面；建议修法（不变槽元素比较改三态 `te_elem_cmp`）未落地，待单独裁决（证据 = 探针 n13/n17/n18 + 套件 `residual.*` 两例）。
- **其他登记**：`¬` 面保持 -1（桥接零 TT_NOT ⇒ 不可达）· 链不区分 kind（NAMED vs PARAM 同名 ⇒ 判等；可达性未证实）· APPLY 项 b 槽取基型行 ⇒ DF 载体面该行 face 0→face 1（**派生码不变**）· **预存发现（另单建议）**：非硬名单诊断（TA01/TG02）不阻 `build`（`main.cr:149-170` 硬名单闸；冻结基线同）。
- **关联**：#24/#30（`type_equal_legacy` 删除 + 影子层下线 = **T4/T5 前置已成立**：清零判据达标）· #45（P5 T2 单槽化）· 计划 Task 3 实施记录 · 报告 `.superpowers/sdd/p5-task3-report.md`。

### 47. R2 P5 Task 4：删 `type_equal_legacy` 与全部回落面（2026-09-13——引擎唯一权威 + 残留 -1 政策 **P-A**；桥接副本 + 站点 6 + `ir_gen` 死分支一并删除）
- **政策（Step 1 落纸；计划推荐案 P-A，**待维护者签核**）**：清零后引擎 -1 只剩（a）桥接缺口（行译不成项）、（b）未覆盖面/预算耗尽（Task 0 表 D）⇒ 新码 **`EC_ICE_TY_INDET`（ICE04）**「type judgment indeterminate」+ 反例（两侧项文本）+ **入 `main.cr` 硬名单**（`build` 亦拒绝落盘）。三态纪律：未知不得当 0/1；`return false` 只是 bool 面唯一保守出口（诊断缺席 = 确定 0）。判定点无 AST 位置 ⇒ `--> 0:0`。**回退面 = 删硬名单一行（诊断保留）或整条回 P-B**；report-only 依据 = 全语料 72 档零命中。
- **删除清单（逐件 + 死亡证据）**：`type_equal_legacy`（`checker.cr:497-573`，注记 10 行 + 函数 67 行，含 **7 自调**）· 回落两处（桥接 / 引擎 -1）· `g_replace_unknown`/`g_replace_bridge`（声明 + 复位 + 影子摘要两字段）· `sh_native_ak_legacy`/`sh_base_ak_legacy`（自测 3 例改钉**冻结期望表** `ts_t4_ak_expected`）· **站点 6**（`checker.cr:2459-2470` 12 行含挂点 + `ir_gen.cr:932-996` 65 行发射分支）· `type_equal` 包装层对照计算（改纯转发）+ `sh_compare` 调用点移除。**死亡证据** = 全语料 `replace_*=0` + 站点 6 三面不可达（`tok2op` 零 `OP_ASSIGN` / `T_EQ`→`EXPR_ASSIGN` / `+=` 族 op∈{ADD,SUB,MUL,DIV}）+ 语料 `assign-binary=0`。
- **清零判据复现（删除前置，本任务自跑）**：`check` 34×0/38×1 · shadow **`decisions=agree=32988`**、全桶 0 · 站点 `assign-node=24998 · fn-body-ret=5905 · if-branch=2051 · struct-field-type=28 · array-elem-type=4 · generic-apply-base=2`（`assign-binary=0`）。
- **判据（本实例实跑；报告 `.superpowers/sdd/p5-task4-report.md`，证据 `/tmp/p5t4/`）**：`corec` **`eae13428…`**、构建 rc=0 + `error[`=0 · `selftest-types` **404/404**（401 + `ts_t4_run` 3 例；5 处计数钉重钉「零 ICE04 诊断」）· `check src/compiler` rc=0 · 五 CI job + 全枚举 **57/57** · ELF canary **IDENTICAL**（28822B）· `.ccr` 四条与 T3b 后逐字节同 + `--dump-objects` 同 + `.cir` DOT 同 · 语料日志仅 2 档自源**均匀 −38 行位移** · **冻结基线同源对拍 = 72 档 rc + 日志逐字节零差异** · **探针全集（T3/T3b/T0 三套）pre vs post rc + 日志全同** · 自举链 `corec2==corec3` IDENTICAL + N06=0/0 + 冒烟 42 · **突变控制 3 条**逐条转红 + 精确回滚（M1 去掉 P-A 报告 ⇒ 3 例红；M2 两因措辞合并 ⇒ 1 例红；M3 强制触发 ⇒ `check` rc=1 打印 ICE04、`build` rc=1 无产物 = 硬名单接线证明）。
- **中间态（D24）**：影子判定对拍**停摆**（`sh_compare` 无调用点 ⇒ 摘要 `decisions=0`；站点直方图不再作判据）；判定面回归网 = 冻结基线同源对拍 + 行为探针 + 突变控制；**Task 4/5 必须连续提交**。
- **关联**：#24/#30（本条划销 ①`type_equal_legacy` 删除、③站点 6、④`sh_*_ak_legacy` 删除三项；②unknown 清零 = #46/T3b；影子层与 `replace_*` 残部 = Task 5）· #45/#46（P5 T2/T3）· #44（P5 交接包）· 计划 Task 4 实施记录。

### 48. R2 P5 Task 5：影子层下线 + 回归网切换（2026-09-13——判定面对拍仪器整体退役；替代网 = 冻结基线同源对拍 + 行为探针 + 突变控制）
- **Gate（下线前置，本实例实测）**：`sh_compare` **零调用点**（T4 已移除）⇒ 影子通道判定输出**结构性为空**：起点二进制 × 72 档语料 **70/70 档 `decisions=0 agree=0` + 全差异桶 0**；消费者只剩 `sh_finish`（main.cr，2 调用点）← 两个默认关的 CLI 旗标；无测试驱动。
- **删除面（逐件）**：**12 函数**（`sh_compare` / `sh_record` / `sh_site_begin` / `sh_report` / `sh_dump_write` / `sh_site_name` / `sh_kind_name` / `sh_count_{agree,old_stricter,old_looser,unknown}` / `sh_map_hits`）+ `sh_finish`（main.cr）+ **17 个 `g_shadow_*` 全局**（含 `g_shadow_hits` 调试计数）+ `SHADOW_RING_CAP` + **2 个 CLI 通道**（`--type-shadow` / `--type-shadow-dump`）+ `g_shadow_on` 赋值 + **checker 9 处 `sh_site_begin` 挂点**（站点 1/2/3/4/5/7/8/9/10；**判定点本体一律保留**）+ hits 存-复原 hack（`sh_tk_split_impl` / `sh_tk_term_of_code` / `sh_map_reset`）。**改名**：`g_shadow_map`/`_cap`/`_entries` → **`g_term_map`/`_cap`/`_entries`**（引用 29 ≤ 30 ⇒ 计划择一条件执行）；`SHADOW_MAP_INIT_CAP` → `TERM_MAP_INIT_CAP`。**保留** = 桥接层全族（生产面：判定路径无条件经 `sh_term_of_ti`）+ 展开层全族（生产面）+ `sh_unf_*` 计数（展开层自测读数）。
- **⚠ 偏离计划 D27 一项（**提请维护者复核**）**：`--verify-named-dedup` / `named_dedup_verify` **未删**——理由 ① **非影子面**（零 `g_shadow_*` 耦合）；② **有活消费者** = `tests/selfhost/test_named_dedup.py`（驱动它做「侧表 ↔ `res_type_node`」三组管线内一致性断言）⇒ 删旗标 = 该套件无驱动、杀死既有回归网且违「自测用例只增不减」；③ 边界纪律「不删影子层自身面以外」。**回退面 = 一行**（`main.cr` 旗标 + `run_frontend` 调用块 + 该 py）；若仍要清 #24 同族通道，**须同提交另给该断言的替身载体**（`selftest-types` 不跑 `check_all` 全流水线 ⇒ 现无 in-process 替身）。`--verify-evp-nodes` 同理保留。
- **回归网切换（D26-①；声明落三处）**：`src/ci/run.sh` selfhost-tests 自述块 + `src/compiler/ty_shadow.cr` 文件头 + 本条 ⇒ **判定面回归网（自本任务起）= ① 冻结基线同源对拍（pre-P5 二进制 × 当前源 vs 当前二进制 × 当前源，72 档 `check` rc + 日志逐档 diff）+ ② 行为探针（`tests/selfhost/*.py` + 各批探针语料）+ ③ 突变控制 + ④ 三态纪律（ICE04 硬错）**。**任何后续批次不得引用已下线的影子计数/摘要/站点直方图**；P4 Global Constraints 的「每任务复跑影子对拍」行自此**作废**（以本条替代）。**N 面口径继承（强制）**：影子对 N 面**失明**（同义反复）⇒ **N 面证据只能来自行为探针**（`array_len_*` 判定点 + 异长/同长/嵌套位），不得以「无差异」充当 N 面证据。
- **CI 接线（本任务新增）**：`tests/selfhost/test_named_dedup.py` **新挂** `selfhost-tests`（原仅在全枚举内；同时部分兑现 **#31** 的点名守卫）。`selftest-types` 计数注释同步（404 不变：两例**重钉**——`t4.tk_derivation_not_a_shadow_site` → `t4.tk_query_purity_and_cache_hit`（hits 断言 → **查询纯度**）+ `bridge.hit_delta` → `bridge.cache_hit_same_term_no_new_entry`（hits 计数 → **同项 + 不新增条目**））。
- **判据（本实例实跑；报告 `.superpowers/sdd/p5-task5-report.md`，证据 `/tmp/p5t5/`）**：`corec` **`2342fd03…`**（构建 rc=0 + 真实诊断 `error[` = 0；期间全部构建同 sha = 构建确定性）· `test_backend_bootstrap` rc=0 · `check src/compiler` rc=0 · `selftest-types` **404/404** · 五 CI job 全 rc=0 · 全枚举 **57/57** · **ELF canary `95084e7b…d475` IDENTICAL**（28822B）· `.ccr` 四件（`fb4a3b59…`/`592afa31…`/`ddec1ce6…`/`cd2af565…`）与 T4 逐字节同 · `--dump-objects`（两口径 3521 行）IDENTICAL · `.cir` DOT（165915B）IDENTICAL · **冻结基线同源对拍 72 档 rc + 日志零差异** · **探针全集 30 档 vs T4 记录零差异** · 自举链 `corec2==corec3` IDENTICAL（`75da3610…`）+ N06=0 + 冒烟 42 + `--help` rc=1 · **突变控制 2 条**：M1（派生面 `sh_dfn_code_of_slots` 去辅码 ⇒ 自测 400/404 · `test_ccr_types` 35/40 · `.ccr` sha 变）· M2（判定面 `type_equal_engine` 的 `e==0` 判真 ⇒ `test_named_face` 10/18 · 自测 397/404 · **语料同源对拍 12/12 档 DIFF（3 档 rc 1→0 = 拒绝静默消失）**）——两条均**精确回滚**（源 sha 对拍 + 二进制 sha 复原）。
- **登记（转 P6 / 待裁决）**：① **冻结基线二进制不入库**（`/tmp/p5t0/base/` 为 /tmp 产物）⇒ 该腿跨会话不可复现（复现配方 = `jj` 检出 P4 收官 `9bcb7083` 重建）；**建议落进仓库**（`tools/p5-baseline/`：二进制或「重建配方 + sha 白名单」）。**T7 复核（2026-09-14）**：本轮 `/tmp/p5t0/` 仍在位 ⇒ 对拍腿成立（72 档零差异）；配方 + sha 白名单已登记 **P6 附录 E-13**（维护者裁定 = **重建，不落二进制**）。**→ 已闭合（R2 P6 Task 1，2026-09-14；见 #50）**：配方 + 白名单 + 两条 runner + 探针语料（**29 档**，U-4 收口）入仓 `tools/baseline/` + `tests/probes/`。② 文件名 `ty_shadow.cr` 与 `sh_` 前缀**保留**（改名触三面清单、收益仅命名）⇒ 登记；若改 = 独立小批。③ 突变控制选样教训：突变语料必须选**该突变语义覆盖到的**面（首轮 6 档全 SAME 的教训，配方见报告 §6/`/tmp/p5t5/mut3.sh`）。
- **关联**：#24/#30（本条划销「影子层（`--type-shadow`/`replace_*`）同族下线」残项；`--verify-named-dedup` 面 = 上文偏离登记）· #47（T4 = 前置，中间态）· #45/#46（P5 T2/T3）· #31（CI 挂点缺口——本任务补挂一档）· #44（P5 收官/P6 交接）· 计划 Task 5 实施记录。

### 49. R2 P5 收官（2026-09-14——全量回归 + 判据复验 + 统一台账 + 文档 + P6 交接包；**P5 全阶段收官**）
- **提交链（12 提交；计划 `docs/superpowers/plans/2026-09-13-r2-p5-cleanup.md`）**：`2b9b5463`（T0 前置侦查 + 冻结基线，源码零改动）→ `11913f8a`（T1 `.cir` 暖态 SIGSEGV 根因修复）→ `7f6c38cb`（T2 DFNode.TK 单槽化 α）→ `461d96f3` + `5a333e0c`（T3 unknown 清零 = 命名面判定化 + 收口注）→ `faca94e0`（T3b 不变槽元素三态 `te_elem_cmp`）→ `e6db38b8`（T4 删 legacy + 回落面 + 桥接副本 + 死分支/站点 6；引擎唯一权威 + ICE04 P-A）→ `b6bf33cb` + `d65ff9ad` + `66316751`（T5 影子层下线 + 回归网切换 + 两收口注）→ `04c20487`（T6 `EXPR_LET` 判定点 = TODO #32 收口）→ 本条目（T7 收官）。
- **全量回归（本实例实跑；构建确定性 ×2 逐字节同 = `corec f737e26b…`/`corearch 544e9201…`/`corelsp 4251108b…` ⇒ 提交树 == 被测二进制度）**：五 CI job 全 rc=0 · 全枚举 **58/58 rc=0**（51 selfhost + 7 bootstrap）· `selftest-types` **404/404** · `check src/compiler` rc=0 · 自举链 `corec2==corec3` `cmp` IDENTICAL（`5559beef…`，2854910B）+ N06=0 + 冒烟 42（corec/corec3 双通道）。
- **判据复验（本实例实跑；证据 `/tmp/p5t7/`）**：ELF canary **`95084e7b…d475`（28822B）IDENTICAL** · `.ccr` 两套口径冷态四条（`ptr_arith` 90823B `fb4a3b59…`/90966B `592afa31…`；`generics_test` 135341B `ddec1ce6…`/135484B `cd2af565…`；差恒 143B）· `--dump-objects` 两口径 3521 行 `cmp` IDENTICAL · `.cir` DOT 165915B `b1bdf480…` IDENTICAL · **冻结基线同源对拍 72 档 rc + 日志零差异**（pre-P5 `5d2b15ad…` × 当前源 vs `f737e26b…` × 当前源）· **行为探针全集 30 档零差异** · **突变控制 2 条**：M1 派生面（去辅码 ⇒ 自测 400/404 + `test_ccr_types` 35/40 + `.ccr` sha 变）· M2 判定面（`e==0` 判真 ⇒ `test_named_face` 10/18 + 自测 397/404 + 语料对拍子集 **12/12 档 DIFF**，3 档 rc 1→0 = 拒绝静默消失）——回滚精确、仓库零改动。**冷/热豁免表三类缓存态复测**：缓存启用档（`ptr_arith` 16 条目/`chan_test` 46 条目）真命中、ELF 冷≡暖、`.ccr` 冷≠暖（预存豁免）但各自确定性；含泛型档（`generics_test`）与可选档 `entries=0`（既有策略关缓存）⇒ 冷≡暖。
- **统一台账（T0–T6 汇总；P5 计划「统一台账」节）**：删除/退役 **6 件 + 1 改名族**（`type_equal_legacy` + 7 自调 + 2 回落 · `g_replace_*` 计数 · 桥接 legacy 副本 · 站点 6 + `ir_gen` 死分支 · 影子层 12 函数 + `sh_finish` + 17 全局 + 2 CLI 旗标 + 9 挂点 · hits 存-复原 hack；`g_shadow_map` → `g_term_map`）· 收紧 **5 类**（D23 保存拒绝 · TG02 混类 · `te_elem_cmp` 不变槽 0 · ICE04 硬错 · TA02 硬错）· **放宽 0** · 修复 **4**（暖态 SIGSEGV / F1 r9 残留 UB / 声明位点静默错产物 / 死分支）· 实施偏差 **8 条**（含「`--verify-named-dedup` 未删」与「P4 六排除项再裁」）。全语料命中逐任务 **0**（report-only 先行）。
- **文档**：统一设计 spec **§9 P5 行 ✅** + §3.4（单槽化落地形态）/§6.2（单槽落地 + D20 稳定引用形态规范）/§6.3（corearch 读回承接面 = β/P6）；format spec §3.3（NOD `tk` = **派生码** + D20 禁令）+ 头部 P5 追加注 + `test_ccr_types` 34→40；findings **§16 P5 收官（文件自冻结）**；本计划：实施状态总表 + 收官总述（一页）+ Task 7 实施记录 + 统一台账 + **附录 E 增补 7 条**。
- **P6 交接包 = 计划附录 E（16 条；现状/出处/影响面/建议/前置）**：1 盘面项索引 + `atom_of` 读回（β）· 2 对象布局表示位 · 3 `MAX_*` 解除 · 4 可选程序收回 `.cir` 缓存 · 5 `.csr`/TagNode · 6 命名消费语法/iterable/形状可写视图 · 7 `tt_display` 零 `str_intern` + 改名残项 + `MIN_CASES` · 8 陈旧工具/副本 · 9 纪律继承 · **10 ¬ 面过判（T3b）** · **11 `-> never` 调用面（T6）** · **12 #20/F3 调用位点** · **13 冻结基线复现配方（维护者裁定 = 重建，不落二进制）** · **14 ICE04/P-A 签核 + 非硬名单诊断不阻 `build`** · **15 `string == int` 混比 + >1GiB 分片** · **16 设计先例引用面**。
- **划销/收口**：#24/#30 的 P5 继承项（①②③④）全部落地或注记（`type_equal_legacy`/`sh_*_ak_legacy`/站点 6/unknown 清零）· #32（T6）· #43 ⓪ 暖态 SIGSEGV（T1）· #48 的「回归网切换」已由 T5 落纸、T7 复跑成立。**待维护者签核（本批遗留）**：ICE04/P-A 政策（回退面 = 一行）· `--verify-named-dedup` 偏离 D27 的保留裁决（回退面 = 一行）· 冻结基线配方落位。
- **关联**：#44（P4 收官/P5 交接）· #45–#48（P5 逐件落地）· #5 家族（暖态 SIGSEGV 闭合；冷/热 `.ccr` 分歧本轮量化并豁免）· #26（判据口径）· 计划 `docs/superpowers/plans/2026-09-13-r2-p5-cleanup.md` · 报告 `.superpowers/sdd/p5-task7-report.md`（工作区）。

### 50. R2 P6 Task 1：回归网可复现化（2026-09-14——E-13 配方/白名单/runner/探针语料入仓；U-4「30 档」收口）
- **交付**：本提交（路径限定 8 路径 = `tools/baseline/{REBUILD.md,rebuild.sh,parity_run.sh,probes_run.sh}` + `tests/probes/`（README + 29 档语料）+ `src/ci/run.sh`（自述块改写）+ `TODO.md` + 计划）。详版 = `.superpowers/sdd/p6-task1-report.md`；配方 + 调用方式 = `tools/baseline/REBUILD.md`。
- **形态（E-13 兑现）**：冻结基线 = **源出 pinned revision `9bcb7083`（P4 收官）的三二进制**，白名单 `corec 5d2b15ad…` / `corearch 493dc490…` / `corelsp 18b94bd9…`；**二进制不入库**（维护者裁定），入仓 = 配方（`rebuild.sh`：`jj workspace add --revision` + `build_selfhost_native.py` + sha 硬闸 + 冒烟 rc=42）+ 白名单 + **换代纪律**（不符不得改白名单对齐）+ 两条 runner + 探针语料。**CI 不挂钩**（`.github/workflows/core-ci.yml` = `actions/checkout` + `fetch-depth: 2` 浅检出 + 无 `jj` ⇒ pinned revision 不可得；本腿为手工判据——评估结论落报告）。
- **runner 面**：`parity_run.sh <corec> <outdir>`（72 档 `check`，分层/命名/逐档 `clean-cache` 逐字继承迁移期 `/tmp/p3t0_run.sh`；**影子分支剥除**——旗标已随 P5 T5 删除；`nullglob` + 计数断言 72 硬失败）· `probes_run.sh <corec> <outdir>`（29 档，显式清单 + 计数断言；**不再有字面 glob 伪条目**）。
- **U-4 收口（「30 档」的账）**：正式值 = **29 `.cr`**（`/tmp/p5t0/probes` 11 + `/tmp/p5t3/probes` 18）；P5 台账的「30」= 29 + **1 条字面 glob 伪条目**（`_tmp_p5t3b_probes_*.cr`，rc=1，log = `error: cannot read …/*.cr`——未匹配 glob 被当文件名；两态恒等 ⇒ 该条对拍**空洞**）。`/tmp/p5t3b/probes` = T3b **输出**目录（21 log + 6 dump），**非**语料目录 ⇒ 「探针源已丢」的初判**修正**（源全在位）。**「30」此后不得引用**；入仓 29 档 sha 与 T0 清单 **29/29 逐条同**（实拷保真，源内不加注）。
- **不可复跑面（登记，不假装）**：① T3b 变异态 15 件（`.M{1..4}.log` + `.M2.dump`）需**先重造变异二进制**（配方 = `p5-task3b-report.md` §3.3）；② 42 行 `[type-shadow…]` 摘要**无二进制可产**（通道已删）⇒ 不得引用；③ 红态（pre-T3b）复现须用冻结基线（仍带旗标，T0 §3.3 已实测逐字节同）。
- **关联**：#48 登记①（本条闭合）；计划 `docs/superpowers/plans/2026-09-14-r2-p6-tail.md` Task 1；T0 = `.superpowers/sdd/p6-task0-report.md`；`src/ci/run.sh` 自述块与 `REBUILD.md` 互为指针。

### 51. R2 P6 Task 3：β 盘面项索引 + `CCR_VERSION` 8→9 + corearch `atom_of` 读回（2026-09-14——E-1 收口；U-2 先裁 = L-a / U-3 = (i)）
- **交付**：`.ccr` NOD 记录 **36 → 40B**（+28 = `item i32` = **TYPE 段文件空间项索引**，-1 = 无项；邻接域顺移 +32/+36）+ `CCR_VERSION` **8 → 9**（旧 v8 及更早整类拒收——D10 先例）+ `tt_atom_of_term` 自 `ty_shadow.cr` **迁入共享层 `type_terms.cr`**（corearch 清单不含桥接层）+ corearch `--dump-nod-items` 读回通道（逐节点 `item → 项表取项 → atom_of → 行`）。写侧装填 = `ccr_types.cr:ccr_nod_item_populate`（**保存期**由盘上派生码经既有分类/建项单源重派生——**不得**沿用 emit 期活表索引：`ccr_type_populate` 的 `tt_layer_reset` 在 save 前作废之，D20-③/`bad_term=329` 红证）；读侧 = `load_ccr` 的 TYPE 段后**一致性硬校验**（`item < -1` / `≥ tt_count()` / `atom_of(项) ≠ tk` ⇒ 拒绝 rc=1——**不得**静默当无项）。`.cir` 快照**零改动**（`CIR_CACHE_VER` 保持 17）。
- **D20 合规（L-a 先裁三条论证）**：① 跨边界引用零新增（只引入文件内项索引，D20-② 唯一许可形态）；② 「码 = 派生量」不变（两值同源于单次装填，无第二套建项逻辑）；③ **分歧即硬拒**（消灭「盘面值静默胜出」的危害模型）。**登记未取**：更严单源形态 **L-c**（旧槽改载辅码、码完全装载侧重派生——无并存，但改发射路径输入 ⇒ canary/dump 由构造性降为须实测，须维护者追加裁定）。**L-b 排除**：单槽「项索引 ∪ 辅码」+ 分类表判读 = **读侧不可判定**（分类表恰需被丢弃的派生码；反例 = `tests/suite/ptr_ref_first.cr` 的 `IR_BINARY tk=10` 复合行码与项索引同域）。
- **判据（实测）**：五 CI job 全 rc=0 · 全枚举 **58/58** · `selftest-types` **404/404** · `check src/compiler` rc=0 · **ELF canary `95084e7b…d475`（28822B）IDENTICAL** · **`--dump-objects` 两口径逐字节同**（vs T0 记录 `cmp`·`generics_test` 3521 行）· `.ccr` 两口径四条重锁 + **逐段 delta 归因 = 4B × 节点数**（pa 90823→96015 / 90966→96158；gt 135341→142793 / 135484→142936；口径差恒 143B 不变）· **72 档 `check` 同源对拍零差异**（构造性隔离腿：`check` 在 `main.cr:448/:450` 早退，不读不写 `.ccr`/`.cir`）· 探针 29 档零差异 · 自举链 `corec2==corec3`（2859006B）+ N06=0 + 冒烟 42 + `--help` rc=1 · `test_backend_bootstrap` rc=0 + `error[`=0 · `test_ccr_types` 40→**48** / `test_ccr_v7` 27/27 / `test_region_cfg` 22/22（三处 v8/36B 重锁）· **突变 M1–M5 逐条转红 + 精确回滚**（M1 item 槽写码 ⇒ loader 拒；M2 删整段校验 ⇒ 越界静默接受；**M3 改用 emit 期活表索引 ⇒ loader 拒——save 期重派生的唯一机器抓手**；M4 版本闸放水 ⇒ v8 假文件被接受；M5 只删交叉校验 ⇒ 域内非原子项被接受）。
- **偏差登记**：① 计划 Task 3 Step 3「项索引与派生码同出 emit 期那一次拆分」与实读时序矛盾（`tt_layer_reset` 在 save 前作废 emit 期引用）⇒ 实施取「保存期由码重派生」；② 计划 Files 漏 `regalloc.cr`/`type_terms.cr`/`tests/selfhost/test_region_cfg.py`，且把 corearch 读回挂在 `main.cr`（实为 `corearch.cr:243` + `src/arch/x86_64/regalloc.cr:877`）⇒ 勘误并入计划 Task 3 节；③ 计划锚点 `src/compiler/ent_kernel.cr` 实为 `src/lattice/ent_kernel.cr`。
- **残留（登记，不静默）**：暖态（`.cir` 缓存命中跳过 ir_gen）文件对被缓存函数引用、而暖进程未分配的类型行 ⇒ `item = -1`（码由 `tk` 槽保真）⇒ **暖态项面为部分**（冷态完整；各自确定性不变）；若未来需暖态完整项面 ⇒ 独立设计轮。
- **关联**：附录 E-1 · 先裁 U-2/U-3 · P5 T2 §5-④（暖态项面）· D20/D22/D23 · #45/#46（P5 T2 单槽化）· `docs/superpowers/specs/2026-09-10-type-interface-unification-design.md` §6.3（β ✅）。

### 52. R2 P6 Task 4a：`-> never` 调用返回型（2026-09-14——E-11 收口：两站点误报消除；发射面零变化）
- **根因（前置侦查实读）**：`fn boom() -> never` 的**调用**被推断为 unit——声明注册趟的域守卫（`checker.cr` 的 `rt_mapped != TI_NEVER`）把 NEVER 钳成 unit（`never` 在 parser 侧是 ast-kind-0 基类型节点 ⇒ 走裸码路径）⇒ SYM_FN 符号类型 = unit ⇒ 两站点：① `x : int = boom();` 误发 TA02（声明位豁免 `val_ti == TI_NEVER` 不触发）；② `return boom();` 误发 TF01（块类型 = unit ≠ TI_NEVER ⇒ 返回位豁免不触发）。**实证**：RED 实跑 rc=1 + `error[TA02]: Variable declared as int, got unit` / `error[TF01]: Function return type mismatch`。
- **交付**：`src/compiler/checker.cr` **两站点守卫**（直调 `EXPR_CALL` 非泛型尾 + 方法调用姊妹站点；后者同形判定 = 同 `sym_type(si)` / 同 `fi_return_type` 可取（mangled 名经同一 `parse_body`）/ 同发射面消费者 `ir_gen.cr:1662-1663`）。守卫四条：泛型由既有早退排除 · `sym_type(si) == TI_UNIT` · `fi_return_type(fi) == TY_NEVER` · `ast_kind(fi_ast_node(fi)) == EXPR_FN`（**extern 面按裁④ 不动**——extern 亦在 g_funcs 且 `fi_return_type = TY_NEVER`，无 ④ 则被一并透传并破 `t6_S3_never_unit`）；方法面补 `fi_generic_count == 0` 对齐泛型面。**嵌套 `if` 为硬约束**（bootstrap 构建的二进制对 `&&` 两侧无条件求值，且 `fi_return_type`/`ast_kind` 无护栏）。**只改推断结果**：`sym_type(si)` 值不动 ⇒ `ir_gen` 的调用结果型零耦合。
- **重钉 1 条（裁①）**：`tests/selfhost/test_iface_ops.py` 的 `t6_S1_never_unit` 改前钉的是**误报**（rc=1 + TF01@2）⇒ 改判 rc=0（正确行为：`f()` 发散 ⇒ `return x` 不可达）。
- **用例 +9**：`test_let_check` 23→（实读 24，注释陈旧自纠）→ **28** · `test_tf01_fallthrough` 19→ **22** · `test_iface_ops` 76→ **78**（主判据 5 / 正控 5 / 登记钉 4；见报告）。
- **判据（实测）**：五 CI job rc=0 · 全枚举 58/58 · `selftest-types` 415/415 · `check src/compiler` rc=0 · **canary `95084e7b…d475`（28822B）IDENTICAL** · `.ccr` 四条 = T3 新锁值（96015 / 96158 / 142793 / 142936；差恒 143B）· **72 档对拍零差异**（误报消失类 diff 的载体 = **套件 leg**，不在 72 档语料）· 探针 29 档零差异 · 自举链 + N06=0 + 冒烟 42 + `--help` rc=1 · `test_backend_bootstrap` rc=0 + `error[`=0 · 突变 Mu1–Mu5 逐条转红 + 精确回滚。
- **同族未修（裁④ + 新登记）**：泛型调用（`res_call_type` 的 NEVER 钳位 + 自测 `t6.never_cell_diff`）· extern（注册域守卫）· 模块限定（`g_mod_func_tis`）· **`EXPR_ASSIGN`（赋值位）无 never 豁免**——`busy = boom();` 改前改后**都**报 TA01（既有缺口、非本改动引入；声明位/返回位/if 合并三处已有豁免，赋值位是剩余缺口）⇒ 本条目登记，待排期。
- **E-12 半身（未实施，挂裁-P6-2）**：见附录 E-12 勘误——「非泛型调用位点」**不存在**（已知 SYM_FN 的非泛型调用分支连实参推断都不走）⇒ 实施 = **新增**判定点；锚点与参数型取法已入计划 Task 4 Step 4。
- **关联**：附录 E-11/E-12 · 计划 Task 4 节勘误 · #20（F3）· #32（声明位判定，同族豁免面）· P3 附录 A（「never 在调用位点被当 unit」的 P3 待裁决项 ⇒ 本批收口）。

### 53. R2 P6 Task 5：文档/卫生批（2026-09-14——E-7/E-8/E-16 收口：MIN_CASES 收紧 + 废弃标注 + 陈旧值与先例载体改写；**零行为变化**（重建三二进制逐字节同））
- **交付**：本提交（路径限定 = `tests/selfhost/test_type_engine.py` · `tools/module_to_ccr.py` · 两 spec（`2026-09-11-explain-predict-incremental-design.md` / `2026-09-11-policy-injection-design.md`）· `TODO.md` · 计划）。工作树 = 合流树 `/tmp/p6mrg`（head `9bdbdf16`）；证据 `/tmp/p6t5/`。
- **逐件**：① `MIN_CASES` 32 → **415**（+「只增不减」注：新增/删除用例须同步下界；判据 = `test_type_engine.py` 绿）② `tools/module_to_ccr.py` 头注废弃块（version=1 / `ccr_io.cr:135` `CCR_VERSION = 8` 整类拒收 / 零 in-repo 调用者 / **保留不删**，删除候选登记）③ `explain-predict` **5 处**（`:371` 三陈旧：旧值 14 → **17**、行号 `:16` → **`:51`**、**magic `C1C1…` 分句删去**（该断言与实测不符——自举二进制落盘 magic 全 0，P4 T5 / TODO #14 登记）；`:84`/`:181` 旗标计数 `8 → 7`；`:127`/`:447` 先例载体 → `--verify-*` 家族 + 行为探针）④ `policy-injection:275` 同款改写 ⑤ **`run.sh` 零改动**（逐条实测复核：其全部 `N 例` 注与实测一致——T2/T3/T4a 已各自同步；陈旧「14 档挂点」在**本计划**，不在 `run.sh`）⑥ **计划勘误**（Task 5 节实况化 + 侦查底座陈旧锚（挂点 28 / 自述块行域 / 计数注行号）+ T1 记录里一句不精确）。
- **判据（本实例实跑）**：**重建 ⇒ `corec ae01de75…` / `corearch 228f82e9…` / `corelsp 90eb19c6…` 与编辑前逐字节同**（T5 零 `.cr` 改动 ⇒ 零行为变化的**构造性证据**）· 五 CI job 全 rc=0 · 全枚举 **58/58** · `selftest-types` **415/415** · `check src/compiler` rc=0 · canary **`95084e7b…d475`（28822B）IDENTICAL** · `.ccr` 四条 = T3 新锁值（96015 `680a6f98…` / 96158 `76f36e6a…` / 142793 `41e9d845…` / 142936 `704316c8…`；差恒 143B）· **腿① 同源对拍 72 档零差异**（冻结基线 `/tmp/p6t1/base/corec` × 当前源 vs 当前二进制 × 当前源；rc 34×0/38×1 两侧同）· `test_backend_bootstrap` rc=0 + `error[`=0 · 自举链 `corec2==corec3` IDENTICAL（`0b2e06d0…`）+ N06=0 + 冒烟 42 + `--help` rc=1。
- **grep 复核（实跑）**：`--type-shadow` **无活跃引用**（`src/` 8 条 + `tests/` 3 条**全为**「已下线/历史」注；旗标注册面三处实核 = `main.cr`/`corearch.cr`/`targets/x86_64-linux/main.cr`，`--type-shadow*` 零在位）；陈旧版本值（14）在 `docs/ src/ tests/` **零引用**（修靶后）；`MIN_CASES` = 修靶（`test_type_engine.py:20` = 415）+ 邻域（`test_purity.py:27` = 26）。
- **登记（转 T6 / 待办，本任务不代改他节）**：① `tools/module_to_ccr.py` **删除候选**（本任务只标废弃；删除 = 独立决定）② `test_purity.py` 的 `MIN_CASES = 26`（同形面，未纳入 E-7 点名）③ **T0 缺失实施记录归 T6**（T5 只登记、不动 T0 节——理由：章程边界 / 与 T6「统一台账」同类 / 避免计划文件被两批各改一次）④ **T2 无 TODO 条目**（#50=T1 / #51=T3 / #52=T4a ⇒ 建议 T6 补或 T2 自补）⑤ `pkg/` 非入库面（`.gitignore` 覆盖；仅报告登记，不进提交）。
- **关联**：附录 E-7/E-8/E-16 · 计划 Task 5 实施记录 · T1 报告 §9-5（T0 记录）· T0 报告 §3/表 D-4（探针 29 / 挂点 28）。

### 55. ~~TC02 收口：`if` 分支相容判定的**发散豁免**（2026-09-14——真误报修复；fail-closed 面 TC02 豁免条可撤）~~ —— **已核销（2026-09-16 分类账复核）**：`checker.cr` `stmt_diverges` 在位 + `test_tc02_branch.py` 挂 CI（15/15）
- **现象**（归因 = `/tmp/fct1/tc02_attribution.md`，证据同目录）：`if <cond> { } else { return 1; }`（及镜像形）在 `check` 面恒报 `error[TC02]`，而语义上 else 支**发散**（不产出值）⇒「分支值类型须相容」无对象。**与 float 无关**（纯 int 条件同报）、**预存**（冻结基线 `5d2b15ad…` 同值）、**对称**（then 发散同样命中）。
- **根因**：`EXPR_RETURN` 的推断 = **所返回值类型**（`checker.cr` 的 EXPR_RETURN 分支）⇒ `{ return 1; }` 的块类型 = `int`；而 `if` 的值类型定义为 **then_ti**（`infer_expr` 的 EXPR_IF 合并点 `return then_ti`）⇒ 合并点只看 `then_ti != TI_NEVER && else_ti != TI_NEVER`（`:2907`）⇒ 发散支的幻影类型参与相容判定 ⇒ 误报。
- **修法（P3，维护者 2026-09-14 裁）**：新增发散谓词 `stmt_diverges`（return 族 + 包裹层 + 块内任一句；**只服务本判定点**——**不得**用于 TF01：那里豁免 return 会洗白真错面，见 `stmt_cannot_fall_through` 头注明令），`:2907` 加嵌套 `if` 守卫：**仅 else 支发散 ⇒ 不报**。**不对称是有意的**：then 支发散时 then_ti 本身即幻影（模型面，另案）⇒ 仍报，保留真信号。**明令不做** = 改 `EXPR_RETURN` 推断（会连带关掉 TF01 ⇒ 静默错产物）。
- **判据（本实例实跑）**：新套件 `tests/selfhost/test_tc02_branch.py` **15/15**（挂 `run.sh` selfhost-tests）· 五 CI job 全 rc=0 · 全枚举 **58/58**（`test_native_float` 两正例 `float_normal_cmp`/`float_arith` 在 fail-closed 裸反转口径下**由红转绿**）· **ELF canary `95084e7b…d475`（28822B）IDENTICAL** · `.ccr` 四条 **96015/96158/142793/142936**（差恒 143B，逐字节同）· `--dump-objects` **3521 行** · `.cir` DOT **165915B** `b1bdf480…` · `selftest-types` **415/415** · 自举链 `corec2==corec3` **IDENTICAL**（`c8c63985…`，2880022B）+ N06=0 + 冒烟 42 + `--help` rc=1 · 72 档对拍**零差异**（34×0/38×1）· 探针 29 档零差异 · **report-only 全语料扫面**（590 内联源两态）：**仅 2 处变化、均为 TC02 消失、均在 `test_native_float`**（无新增码、无非 TC02 变化）· 突变 **M1**（去守卫）⇒ 新套件恰 3 例复红（`tc02_else_return_silenced`/`_after_stmt`/`_stmt_position_multi`）+ `c01/c02/c05` 复报；**M2**（放宽为「任一支发散」= P1 形态）⇒ 新套件 `tc02_then_return_kept` 转绿 = **越界信号被抓**（14/15）；两突变均仓库外实拷贝，复位后二进制复原。
- **登记**：`stmt_diverges` 未覆盖面 = `break`/`continue` 收尾的分支（需循环上下文）；`x := if c { } else { return 1; }`（值被用且 else 发散）形态按 P3 不报——if 型 = `then_ti` = unit 是真值 ⇒ 误用由 TA02/TF01 别处兜住（**未构造端到端用例**，实施时登记）。
- **对 fail-closed 线的影响**：`/tmp/fct1/exemption_draft.tsv` 的 **TC02 豁免条可撤**（退出条件「逐例归因后」已达成）——由 FC 批 T2 统一调整。

### 54. R2 P6 收官（2026-09-14——尾批六任务链 + 统一台账 + 尾批终态陈述；**P6 全阶段收官**）
- **提交链**（计划 `docs/superpowers/plans/2026-09-14-r2-p6-tail.md`）：`bc4f0a43`（计划定稿 = 附录 E 16 项分诊：实施 7 / 待裁 7 / 维持登记 1.5）→ **T0** 前置侦查 + 冻结基线重建（pinned `9bcb7083`；源码零改动；四表 + 守门复验）→ `e5ce8f9e`（**T1** 回归网可复现化 = E-13）→ `911c692d`（**T2** ¬ 面过判 = E-10）+ `0819d506`（**T3** β = E-1）**兄弟提交**经合流态由 `9bdbdf16`（**T4a** `-> never` 调用返回型 = E-11；**双亲合并提交**，一次落地）→ `4b909996`（**T5** 文档/卫生 = E-7/E-8/E-16）→ 本条目（**T6** 收官）。
- **判据（本实例实跑；工作树 = 合流树 `/tmp/p6mrg`；证据 `/tmp/p6t6/`）**：构建确定性 ×2 **逐字节同** · 五 CI job 全 rc=0 · 全枚举 **58/58** · `check src/compiler` rc=0 · `selftest-types` **415/415** · canary `95084e7b…d475`（28822B）**IDENTICAL** · **入仓配方重建**（`tools/baseline/rebuild.sh`）三 sha = 白名单（`5d2b15ad…`/`493dc490…`/`18b94bd9…`）+ 冒烟 42 + 零残留 · **腿① 同源对拍 72 档零差异**（两侧 34×0/38×1）· **探针 29 档两态零差异**（17×0/12×1）· `.ccr` 四条 = **T3 新锁值**（96015 `680a6f98…`/96158 `76f36e6a…`/142793 `41e9d845…`/142936 `704316c8…`；差恒 143B）· `--dump-objects` 3521 行 · `.cir` DOT 165915B `b1bdf480…` · 自举链 `corec2==corec3` IDENTICAL（`0b2e06d0…`）+ N06=0 + 冒烟 42 + `--help` rc=1 · `test_backend_bootstrap` rc=0 + `error[`=0。
- **统一台账（KPI）**：实施 **6** · 删除 **0**（+1 候选）· 迁移 **1**（`sh_atom_of_term` → 共享层 `tt_atom_of_term`）· 收紧 **3 类**（¬ 面异身份不交 / `.ccr` 版本闸 v9 整类拒收 / loader 一致性硬校验）· 放宽 **1 类**（`-> never` 调用返回型）· 修复 **1 件**（+1 并记）· 登记 **19** · 偏差 **9** · **未取裁 7**（逐条 = 计划「统一台账」§1–§7 + 「尾批终态陈述」节）。
- **本批特有（记在账上）**：① **事故** = `.superpowers/sdd/p6-incident-2026-09-14-t3-preempt.md`（T3 抢跑：零提交/零还原；护栏 = 「含先裁的任务把护栏写进任务卡正文」）② **提交形态** = T2/T3 兄弟提交 + T4a 双亲合并提交（协调者裁：接受，不拆）③ **T4a 过程事故** = CI job 执行期间改 `run.sh` ⇒ bash 读截断 rc=2 ⇒ 源冻结后重跑五 job。
- **补记**：**T0 实施记录**已由 T6 回填计划 Task 0 节（六步勾选 + 记录块）——T0 当批只出报告（`.superpowers/` 不入库）⇒ 计划内零留痕；归属裁定 = T6。
- **待维护者处置**：① **四裁定门全未取裁** = 裁-P6-1 容量批归属（推荐转独立批）· 裁-P6-2 政策五问（ICE04 签核 / 非硬名单诊断 / 入闸判据 / `*T←0/None` / `--verify-named-dedup`）· 裁-P6-3 `string == int` 混比 · 裁-P6-4 `EXPR_FOR`/iterable；另 U-2 的 **L-c** 备选 + T2 正×正面候选（`lit_empty_pair`）② **主树遗留** = 工作副本 9 未提交文件（T2 过时草稿 + T3 抢跑残留）+ `build/*` 为 T3 味（`aa7bdd5d…`/`28c5d669…` ≠ P6 起点白名单）⇒ 最终整合涉**还原** ⇒ 须维护者明确许可。
- **建议补条目**：**#55 = T2（¬ 面过判，E-10）的落地登记**（#50=T1 / #51=T3 / #52=T4a / #53=T5，**T2 独缺**；内容可自 `.superpowers/sdd/p6-task2-report.md` §2–§5 摘录）。
- **关联**：#49（P5 收官 / P6 交接）· #50–#53（P6 逐件）· 计划附录 E（16 项）· spec §9 **P6 行** · 计划「统一台账」/「尾批终态陈述」· 下一批指向 = **容量批 或 验证切片轮**（按裁-P6-1）。

### 56. ~~⚠ 指针写可选槽 × 表示位/规范化互斥：`*p = Some(9)` **双路径分歧的静默错值**（容量批 T2 登记——**今天就存在 · 预存 · 本批不修**）~~ —— **✅ 已核销（2026-09-16，(A) 批 T1–T3 收官）**

> **处置（按 TODO #56 裁决 (A)「表示位随存储走」）**：T2 实现取址槽恒装箱（裁-REP-1 (iii)：W1 取址预扫 + W2/W3 写点装箱并钉表示位 1 + W4 形参序言 + W5 `IR_STORE_PTR` 按 pointee 装箱）；T3 补写点完备性审计。**实测转正**：`c3` 双路径分歧（ELF 8 / interp 96）⇒ **正确值**（自证式断言：写入载荷 9 ⇒ 解包须 == 9）· `c2` 139 ⇒ 7/7 · `c1` 保持 7/7 · **四形态**（局部 / 数组元素 / 全局 / 形参）经指针写全部双路径正确。**第二根因（计划外，预存）**：ELF 后端 `IR_REF` 全局取址一律 `e2_lb(g2_slot())`（帧外伪偏移）⇒ `&g` 取栈垃圾（与全局槽脱钩）；修法 = 全局源 `lea r10,[rip+rel32]` + RIP 补丁（`src/arch/x86_64/instr.cr:1095`）。**残留转独立条目**：`&s.a` 写入丢失 → **#73** · 指针算术（REP-2）→ **#73** · `&x` 借出后读 x 的 B04 软诊断 → **#73**。**候选 (D)（语言面拒绝 `*p = v`）未取用**——(A) 修法已使该形态**正确**，无需拒绝。证据 = (A) 计划文档 T2/T3 实施记录（`docs/superpowers/plans/2026-09-16-opt-rep-follows-storage.md`）· 报告 `/tmp/capt6/task2-report.md` · `/tmp/capt7/task3-report.md` · 提交 `1e11353c`（#74）· `5d36af98`（#75）。

---
- **现象（本实例实测；证据 `/tmp/capt2/probes_out*/c3_ptr_local_boxed_write.*`）**：`x : int? = 5; p := &x; *p = Some(9); return match x { Some(v) => v, None => 0 };` ⇒ **ELF rc=8 / interp rc=216**（双路径分歧 + 双错值）。成因 = `x` 的表示位为 **0（裸）**而经指针写入的是**装箱值** ⇒ 解包按裸分支把对象指针当载荷。
- **三子形态（同一根因）**：① `c1`（位=0，写裸 `7`）**今天返回 7 = 正确但脆弱**（依赖位与值恰好同态）· ② `c2`（位=1，写裸 `7`）**139 响亮** · ③ `c3`（位=0，写 `Some(9)`）**静默分歧**（本条）。
- **根因链**：表示位只在**直接写点**置位（`emit_rep_set`）⇒ 指针写（`IR_STORE_PTR`，`ir_gen.cr` EXPR_ASSIGN 的 UOP_DEREF 分支）**绕过**表示位；同一 IR 站点同时服务**局部**（权威 = 表示位）与**聚合槽**（容量批 T2 起权威 = 恒装箱）；且「指针指向哪类存储」**别名不可静态闭合**（`q := p` 拷贝即漏判）⇒ 无条件装箱会**新增**静默错值（`c1` 由正确转错）⇒ 容量批 T2 裁 (A)：**登记不修**（彻底闭合需「表示位随存储走」= 布局变更，与裁-CAP-1 (a) 零布局变更互斥）。
- **关联未覆盖面（同批登记）**：数组元素经指针（`p := &a[0]; *p = 7` ⇒ 139/139）· 全局经指针（`p := &g; *p = 5` ⇒ ELF 0 / interp 139 分歧）· **`&s.a` 写入丢失**（`UOP_REF` 无字段分支 ⇒ 取到**临时量**地址，`*p = 5` 静默无效——独立预存缺陷）· 局部经指针 139。**待裁候选 (D)**：语言面拒绝 `*p = v`（pointee 为 `T?`）——已实读影响面：指针路径下的聚合**今天无一正确**（139/0）⇒ (D) 的真实影响 = 拒绝**已错**形态（非拒绝正确代码），留维护者裁定（容量批 T2 报告 §8-4）。
- **出处**：容量批计划 `docs/superpowers/plans/2026-09-15-capacity-batch.md` Task 2 · 报告 `.superpowers/sdd/cap-task2-report.md` §8-1/8-3。

### 57. E-4 可选程序 `.cir` 缓存门：**机制实证证伪 ⇒ 维持现状（裁 (c)）**；「移除门」登记为待裁候选（容量批 T4）
- **现状**：`main.cr:484-490` `if g_optrep_on != 0 { cache_enabled = 0; }` —— 可选程序**关 `.cir` 缓存**（代价 = 每次全量重建）。原依据（R2 P4 Task 5）=「表示位侧表是编译期进程内状态、快照不载 ⇒ 命中恢复路径与冷路径**产物分歧**」。
- **本批实证（裁-CAP-3「先机制实证」）**：沙箱 = 全树副本 + **唯一改动**（注释掉该门三行）；冷/暖（全命中，条目数不变为证）× **16 档**（4 基础可选含跨函数信道/聚合面/条件写 + T2 聚合面 12 档）⇒ **ELF 逐字节全同**；**混态**（删 `main`/被调/全部条目制造 miss）3 态 ×2 程序 ⇒ **ELF 逐字节全同**。⇒ **原机制未能复现**（与静态枚举一致：`irv_rep`/`irv_set_rep` 全部读取点在同函数生成内 ⇒ 命中恢复的函数 IR 自含表示语义）。
- **处置（裁 (c)）**：门**原样保留**（保守，零源码改动）。
- **待裁候选（性能面）**：**移除门**（可选程序恢复缓存）。收益 = 编译耗时；风险 = 依赖「命中路径自含」不变量（本次 16 档 + 6 混态未证伪，但**非全语料**）；若裁可 ⇒ 需补：自源可选程序冷/暖对拍 + `test_optional` 同路径冷/暖对拍 + canary/`.ccr` 判据。
- **出处**：容量批计划 Task 4 · 报告 `.superpowers/sdd/cap-task4-report.md` · 证据 `/tmp/capt4/**`（沙箱 `/tmp/capt4/sbx`）。

### 59. FC 批 T2：fail-closed 闸门落地（2026-09-15——**默认阻断 + 豁免登记表 9 条**；旧正向名单 11 码退役）
- **语义**：任何**不在豁免表内**的类型面诊断 ⇒ `rc=1` + 零产物（判据成文化 =「判定继续 ⇒ 产出静默错产物」，五组先例：R002 / TS01-04+TK02 / TM03 / ICE04 / TA02）。**语法面闸（`main.cr:134/:135`）与安全检查面闸（`:594-603`）本就不变**（后者已是「任意新诊断 ⇒ rc=1」）。
- **落点**：`src/compiler/main.cr`（硬判定循环改为 `diag_gate_exempt(ec, GATE_SCOPE_BUILD) == 0 ⇒ hard = 1`；旧 6 条语句行/11 码名单整体退役）· `src/compiler/diag.cr::diag_gate_exempt`（**豁免表 9 条**：build ×6 = TF01/TF07/TB01/TM04/TK01/B04；check ×3 = N01/N06/N11 **仅登记**——裁-FC-1 = (C) 终局，check 面 rc 规则（`:443-451`）不消费本表 ⇒ 72 档基线不换代）· `src/compiler/globals.cr`（`GATE_SCOPE_BUILD/CHECK` 常量）· `main.cr:702` 后（零产物：corearch 失败 ⇒ 删**本次**写下的 `<out>.ccr`；既有旧文件不删——裁-FC-6）· 新套件 `tests/selfhost/test_diag_gate.py` **17 例** + `run.sh` 挂点。
- **判据（本实例实跑）**：五 CI job 全 rc=0（冻结源后重跑）· 全枚举 **60/60** · `selftest-types` **415/415** · **canary `95084e7b…d475`（28822B）IDENTICAL** · `.ccr` 四条 96015/96158/142793/142936（差恒 143B）· `--dump-objects` 3521 · `.cir` DOT 165915B · 自举链 `corec2==corec3` IDENTICAL（`5154425478…`）+ N06=0 + 冒烟 42 + `--help` rc=1 · `test_backend_bootstrap` rc=0 · **72 档 rc 零差异**（34×0/38×1；日志差异 2 档 = **纯行号偏移 +53**（= 本批编辑编译器自身源码 ⇒ 语料含编译器 ⇒ 行号位移；先例照 P6 T2 的 +146）· 探针 1 档 = 进度行（旧硬名单码档，见下））· 突变 **4 条**逐条咬合（M1 删 B04 条 ⇒ ptr_arith 复红 · M2 scope 失效 ⇒ N01 在 build 面静默放行被抓 · M3 去零产物删除点 ⇒ `.ccr` 残留 · M4 全放行 ⇒ 负控转绿）。
- **report-only 对表（T1 §5）**：**无表外命中**——T1 `would_block.tsv` 的 7 条 build 面行在 T2 下**全部放行**（逐档 rc=0 + 产物实测）；34 条 check 面行**逐条不变**（rc + 诊断同）；T1 的 6 档红套件（ccr_types/interp_float/interp_parity/match_exhaust/native_float/xcut_iface）**全绿**（枚举 60/60）。
- **进度行保真（本批的一处细节修正）**：`[5/5] frontend done` 改在「诊断之后、返回之前」打印（原行仅覆盖 `hard==0` 路径）⇒ 72 档语料日志除行号偏移外零差异；**唯一可见差异 = 探针 `n05_recursive.cr` 多一行**（其诊断 `TS03` 属旧硬名单 ⇒ S0 提前返回无该行）。
- **登记（本批不修）**：① `stmt_diverges` 之外的豁免表**只减不增**纪律（撤条须带根因证据；加条须维护者批）；② `scope=check` 3 条在 (C) 下**惰性**（不得据此实现 (B) 活分支）。

### 62. FC 批收官（2026-09-15——fail-closed 判据线 T1–T6 全阶段收官；**T4/T5 折入 T2**）
- **交付**：闸门反转（默认阻断 + 豁免表 9 条）· 零产物 · 隐藏通道（默认关）· 新套件 17 例 · 统一台账 + 批终态 = 计划 `docs/superpowers/plans/2026-09-15-fail-closed-diagnostics.md`（「统一台账」「批终态陈述」两节）。
- **提交链**：`b01a948c`（T2）→ `3990a0a5`（T3）→ 本条（T6 文档/台账）。
- **判据终值（T6 实测）**：五 CI **5/5 rc=0** · 枚举 **60/60** · `selftest-types` **415/415** · canary **`95084e7b…d475`（28822B）IDENTICAL** · `.ccr` 四条 96015/96158/142793/142936（差恒 143B）· dump 3521 · cir 165915B · 链 `24802386a1…` + N06=0 + 冒烟 42 · `backend_bootstrap` rc=0 · 72 档 rc 零差异 · 探针 29 零差异。
- **KPI**：实施 3 · 收紧 1 类 · 放宽 0 · 修复 1（TC02，前批）· 豁免 9 条（带退出条件）· 登记 4 · 偏差 6 · 环境干扰 1 起。
- **T4/T5 折入声明**（维护者 2026-09-15 批准）：T4（命中面处置）= 由 T2 的豁免表 + 退出条件覆盖；T5（开门 + 零产物 + CI 同步）= 已在 T2 生效/落定；理由见台账 §2（不静默略过）。
- **待维护者**：① TODO #60（预存缓存静默缺陷 + runner 暖态腿建议）→ 独立批候选（**已开跑**：2026-09-15 #60 批，T1 实证 + T2 落地见 #60 条）；② **环境干扰事件**：`build/` 被外部删两次 + `examples/*.{ccr,cir,o}` 等 **12 个 tracked 文件**被删（工作副本 `D`）——**未提交、未还原**（铁律 #3），提请处置。

### 61. FC 批 T3：隐藏通道 `--diag-gate-report`（2026-09-15——report-only 二次核对载体；**默认关、两态零差异**）
- **形态**：`main.cr` 注册 `cli_flag_bool("diag-gate-report", …)`（与 `--verify-*` 家族同址同式）+ 闸门内只读报告：`[diag-gate] face=build blocked=N total=M codes=<用户面码,...>`（用 `error_cat_prefix`/`pad_diag_num` 渲染，覆盖 `g_diag_count > 0` 的前端类型面）。
- **判据（本实例实跑）**：**默认关两态零差异**——72 档 `diff -rq` **零差异** · 探针 29 档零差异（与 T2 基线逐字节同）；**开态**：rc 与产物 sha 逐字节同（ptr_arith canary 两态同 `95084e7b…`、arena_test/ptr_ref_first 同），日志仅多一行标记 ✓。
- **重放对表（vs T1）**：101 档（72 语料 + 29 探针）重放 ⇒ **无表外命中**：语料面 25 档 blocked（= T1 `would_block.tsv` 34 行 − 7 行 build 面豁免 − 2 行 P21[**解析阶段闸**，不属本报告面]）逐条对齐；探针面 11 档（TA01/TS03）为 T1 表**未覆盖面**（口径差，已登记）。
- **判据全套**：五 CI job 5/5 rc=0 · 枚举 60/60 · selftest 415/415 · canary `95084e7b…d475` IDENTICAL · `.ccr` 四条 96015/96158/142793/142936 · dump 3521 · cir 165915B · 链 `24802386a1…` IDENTICAL · `backend_bootstrap` rc=0。
- **登记**：本通道**只读**（不改 rc/产物）；`blocked` 计数含重复码（逐诊断计数，非去重）——同一码多次命中会重复出现（照原样保留，便于定位）。

### 60. **【高危·预存】安全面诊断随 `.cir` 暖缓存静默消失**（2026-09-15 FC 批 T2 施工中发现）
- **现象**：同一源、同一二进制，`clean-cache` 与否是唯一变量——**冷态 `error[TU03]` 报出（rc=1、无产物）；暖态诊断消失 → rc=0 且照常产出 ELF**（28822B）。`build --static` 与 `ccr` **两面同病**。
- **复现源**：`fn main() -> int { p := 4096 as *int; return *p; }`（= `tests/selfhost/test_pointer_safety.py:131-138` 的形态）。
- **性质**：**预存**（P6 期二进制 `ae01de75…` 同值复现 ⇒ 非 TC02/容量批/FC-T2 引入）；后果 = **不安全程序第二次编译起静默通过**（「判定继续 ⇒ 静默错产物」的教科书形态，正落在 FC 线靶心）。
- **根因（#60 批 T1 实证，2026-09-15——推翻本条原「疑似根因」的侧表指向）**：**`g_types` 行内容**。缓存命中跳过 `ir_gen_func` ⇒ ir_gen 期 `alloc_type` 出的类型行（`TYP_PTR extra=1` 等）**不重建** ⇒ `provenance_verify.cr:66` 的判定（`get_type_kind(ti)==TYP_PTR && get_type_extra(ti)!=0`）落空。E1 实锤：冷 13 行 / 暖 11 行，**恰缺** `row 11 (extra 0)` 与 `row 12 (extra 1)`（`.ccr` −174B）。**非** `g_pts`/`ptr_analysis`：TK01 类检查冷/暖均报（不依赖生成期行）。暖态静默面 = **1 类码（TU03）× 2 形态（load/store）**，`build --static` 与 `ccr` 两面同病。报告 = `/tmp/fct4/task1-report.md`。
- **为何至今未暴露（T1 方法学发现）**：语料/探针 101 档冷/暖**码集零差异**——① 语料无 `as *T` 形态；② runner（`parity_run.sh:35` 等）逐档 `clean-cache`；③ 套件用例用**唯一 temp 路径** ⇒ 缓存键唯一 ⇒ **结构性无暖态**。真触发 = **同一路径重复编译**（增量构建场景）。
- **T2 落地（2026-09-15，#60 批）**：**见证式一般化**（裁-W1 = (b) 先行；零格式变更/零发射面变更）= `main.cr` miss 分支以 `tc0 := g_type_count` 见证「本函数 ir_gen 期是否分配过共享类型行」，**有 ⇒ 不写条目**（下跑必 miss ⇒ 重放全部生成期副作用；「宁可 miss 不可静默」）。命中率代价实测 = 语料 101 档 **989→986 条目（0.3%）** · 编译器自源 **110→109（0.9%）**（被抑制者全为分配复合行的 `main`）。用例 = `tests/selfhost/test_warm_cache_gate.py`（6 例：冷/暖同 + 机制钉 + 正控真命中 + TK01 旁面 + `ccr` 面）+ `test_ccr_types.py` ㊳（能力变更钉）+ ㉟ 收口（暖态丢项**归零**，钉死）。
- **T3 落地（2026-09-15）**：**判据网暖态腿**（本缺陷之所以能藏这么久 = 全部 runner 逐档 `clean-cache` ⇒ 判据面对暖态零覆盖）。入仓语料 `tests/probes/warm/`（**7 档**，**定路径**是该语料的设计要点）+ 腿本体 `tools/baseline/warm_leg.sh`（两层：广度层 = 父 runner 清单，牙齿层 = 入仓语料 + 期望值断言）+ 专用入口 `tools/baseline/warm_run.sh`；`parity_run.sh`/`probes_run.sh` 各附广度层（`logs/` 格式不变 ⇒ 历史对拍可比；`WARM_LEG=0` 关）。**实测**：牙齿层 7/7 档暖态生效、0.9s；广度层 72 档 40 档生效（+125s）/29 档 15 档生效（+3.5s）。**CI 决定** = 只挂最小面（`tests/selfhost/test_warm_cache_gate.py`，10 例，0.5s，已入 `selfhost-tests`）；全量扫描留手工判据。
- **(c)/(d) 裁决（2026-09-15 维护者裁，依 T2 报告判据）**：**(c)/(d) = 性能面、非正确性 ⇒ 本批不实施**，挂**两个可证伪触发条件**：① 任一未判共享面（`g_ir_locals`/字符串池/外链重定位/region）构造出暖态消费者；② 缓存命中率成实测瓶颈。触发后**先试「加一行见证」的廉价路径**（`main.cr` miss 分支扩展点），不够再转快照承载类型行（格式变更 + `CIR_CACHE_VER` bump，与 TODO #5 编译器身份字段同批评估）。
- **备选登记见 #64**（W4 = 「对该类程序整体关 `.cir` 缓存」，2026-09-15 落独立条目）。
- **未决/登记（(c)/(d) 待触发，判据见 `.superpowers/sdd/warm-task3-report.md` §(d)）**：见证把「分配行的函数」整体移出缓存 ⇒ **复合 mint 行**（唯一来源 = ir_gen 分配行）**结构上不落盘**（101 档扫描：仅 `ptr_ref_first.cr` 有复合行、全缺 ⇒ ㊲ 重钉）。
- **处置**：**本批**（#60 批：T1 测量 → T2 (b) 落地 → T3 暖态腿入仓 → T4 收官）——**已全阶段收官**，台账/终态见 #63。退出条件 = 冷/暖两态诊断一致 + 全语料对拍（含**定路径**暖态腿）**均已满足**（T4 实跑）。

### 68. 验证切片轮（verification slice）**立项**：`#check`/`#ensure` 最小面 + VC 打印（2026-09-16——草案落仓，**待裁-V1..V6，未实施**）
- **落点**：`docs/superpowers/plans/2026-09-16-verification-slice.md`（全文：切片边界五候选 + 推荐 **C1** · 分诊表逐要素实读 · 与 IR 的关系 · **六裁决门** · 任务总表 T0..T5 · Global Constraints · 停条件 7 条 · 未决项 U-1..U-7 · 自检记录）。
- **范围（一句话）**：兑现「语义保鲜」的规约层 **0→1**——`#check`/`#ensure` 布尔表达式 ⇒ 编入图 ⇒ **可打印 VC 清单**；**不接求解器、不接 CIC 内核、不做 spec fn/量化**；**未证明不拦编译**（仅「常量假」= 硬错）。
- **开工前置（六门）**：裁-V1 第一刀 = C1？ · 裁-V2 载体（dump 先行 vs `.csr` v1） · 裁-V3 消费面（`.ccr` vs `.cir` 对外序列化） · 裁-V4 `#` 零运行时足迹（canary 硬闸的构造性来源） · 裁-V5 表达式子集（是否允许可证纯调用） · 裁-V6「未证明不拦编译」+ 常量假 = 硬错。
- **实读关键事实（草案内已固化，T1 须重取行号）**：lexer/parser/EBNF **零规约面**；`.csr`/TagNode 在 `src/` **零命中**（纯设计）；`.cir` **无对外序列化**（只有 DOT + 私有缓存快照）⇒ 建议消费面 = `.ccr`（v9 八段，有版本闸/段表/读回）；纯度 `compute_all_purity` 的**时序陷阱**（生成期读 = 乐观默认值）。
- **状态**：**立项/草案**（未实施；六门未裁前不得落码）。

### 69. 预存 Bug 分类账落仓（2026-09-16——65 条逐条实读分类：还活着 17 · 部分收口 2 · 已修 16 · 登记/非缺陷 28；**含 11 条划销与 2 条勘误**）
- **落点**：`docs/superpowers/specs/2026-09-16-preexisting-bug-ledger.md`（全文：分类账表逐条带「本轮实读」证据 · 优先级排序 · **建议批 B1..B9** · 划销清单 · 重复项/互引 · 诚实项）。
- **本次已落 TODO 的动作**：**划销 11 条**（#5/#8/#11/#16/#25/#28/#29/#32/#35/#40/#55——逐条按账内证据复核后核销；#23 已在位划销故未重复；#35 转历史口径）· **#17 归档**（登记对象 = 影子层，已随 P5 T5 删除）· **#31 文字勘误**（「`test_backend_bootstrap.py` 早已挂」经实读证伪：`src/ci/run.sh` 命中 0，该守卫只在手工全枚举路径执行）· **#20 锚点勘误**（`:1053` → 定义 `:1912` / 丢弃点 `:2021`）。
- **账内**还活着 17 条 + 部分收口 2 条 + 建议批 **B1..B9**（B4 诊断门/CI 挂点被标「最高性价比」——见账 §2/§3）⇒ **待裁**（本条目只落账 + 已完成的内文核销，不实施任何修复）。
- **空号注记**：`#66` 预留给「P6 T2 落地登记」（账 §6-④ 建议）。
- **出处**：原稿 `/tmp/bugtriage/ledger.md`（2026-09-16；零构建零 jj 只读产出）。
- **状态**：账已落仓 + TODO 内文已同步；**修复批未开**。

### 67. ctl（编译时间线性化）计划**任务级细化**落仓（2026-09-16——纸面细化轮；**未实施任何修法**）
- **落点**：定理清单 → `docs/superpowers/specs/2026-09-16-compile-time-theorems.md`（review checklist，12 行定理 + 机检口径）；任务表 **T1..T10** + **7 裁决门** + 审计勘误 → 并入 `docs/superpowers/plans/2026-09-04-compile-time-linearity.md` §8/§9（状态行改「已细化」，指针互引）。
- **审计复核结论**（实读现址）：28 条审计点中 **仍成立 25**（8 条纯行号漂移 · 2 条位置迁移 · 2 条「疑似」升「确定」）· **已失效 1**（`pass_stack_share` 已停用 ⇒ 计划该行已就地划销）· **须开工首日定位 2**（elf 前向补丁解析循环 · Phase 3 的 O(F²) 回扫）；**后端目录 `src/arch/linux/ld/` 已退役** ⇒ 计划 §2.2 全部路径作废（新址见 §8.1-E4）。
- **开工前置**：**裁-CTL-1..7**（证书形态 · `C_pass` 来源 · scaling 范围 · CI 挂钩面 · 哈希设施 · **先 B 后 A** 的批次顺序 · 定理载体）+ **T1**（冻结基线 + 起点判据 + **修复前 scaling 基线**，数值须实测不得预填）。
- **状态**：细化完成，**未实施**（T1..T10 待裁后开工）；本节随该批收官更新。

### 63. #60 批收官：暖缓存静默缺陷修复（(b) 见证式）+ 判据网**暖态腿**入仓（2026-09-15——**独立批 T1–T4 全阶段收官**）
- **提交链**：`e0e92eef`（T2 = 修复 + 套件 + TODO）→ `227b747e`（T3 = 定路径语料 + 暖态腿 + 文档）→ 本条目（T4 收官：台账 + 终态 + spec/REBUILD 指针）。计划+统一台账 = `docs/superpowers/plans/2026-09-15-warm-cache-diagnostics.md`（§8 台账 / §9 终态）；报告 = `.superpowers/sdd/warm-task{1,3,4}-report.md` + `/tmp/fct4/task{1,2}-report.md`。
- **根因（T1 E1 实锤）**：快照载 var 的 `type` 行**号**不载行**内容** + `alloc_type` 只追加 ⇒ 命中跳过 `ir_gen_func` ⇒ 生成期分配的类型行缺席（实测冷 13 行 / 暖 11 行，恰缺 `TYP_PTR extra 0/1` 两行）⇒ `provenance_verify.cr:66` 判定落空 ⇒ TU03 静默（冷 rc=1 → 暖 rc=0 + 照常出 ELF）。
- **修法**：裁-W1 = (b)（**零格式/零发射面**）——`main.cr` miss 分支以 `tc0 := g_type_count` 见证「生成期是否分配过共享类型行」⇒ 分配过则不写条目（下跑必 miss 重放）。代价实测 **0.3%**（101 档 989→986）/ **0.9%**（自源 110→109）。正确性 = 行号空间守恒（归纳：落盘者零分配 ⇒ 命中零分配；未落盘者重放 ⇒ 逐行恒等）。
- **判据网盲区三因（补齐「为何从未现身」）**：语料无 `as *T` 形态 · runner 逐档 `clean-cache` · 套件唯一 temp 路径（缓存键唯一 ⇒ 结构性无暖态）。**决定性实核**：`check` 面写 **0 条**缓存条目 ⇒ 暖态腿必须走 `ccr` 面。
- **暖态腿（T3）**：入仓语料 `tests/probes/warm/`（7 档，**定路径 = 承重设计**，M3 实证）+ `tools/baseline/warm_leg.sh`（两层）/`warm_run.sh`；CI 只挂最小面（套件 10 例 / 0.5s）；**腿本体手工判据**，「何时该跑」四条见 `tools/baseline/REBUILD.md`。暖态生效档数实测 = 牙齿层 7/7 · parity 广度层 40/72 · probes 广度层 15/29。
- **终态判据（T4 实跑）**：canary `95084e7b…d475`（28822B）IDENTICAL · `.ccr` 四条冷态 96015/96158/142793/142936 · dump 3521 · cir 165915B `b1bdf480…` · 72 档/探针 vs T1 **零差异** · 枚举 **61/61** · selftest 415/415 · 五 CI job 5/5 rc=0 · 链 `corec2==corec3` `006e58e1…` IDENTICAL + N06=0 + 冒烟 42 + `--help` rc=1（链 sha 与批前不同 = 本批改了编译器源码，自洽性不变）；**发射面零泄漏**（canary/四条构造性同）。
- **(c)/(d) 裁决**：性能面、非正确性 ⇒ 本批不实施；两个可证伪触发条件（未判面构造出暖态消费者 / 命中率成瓶颈），触发后先试「加一行见证」。

### 64. W4 登记（备选）：对「生成期分配共享面」的程序**整体关 `.cir` 缓存**（2026-09-15——**备选，不实施**）
- **候选**：照 `g_optrep_on` 先例（`main.cr:488-491`），凡该**编译单元**在 `ir_gen` 期分配过共享面（类型行等）⇒ **整档关缓存**。
- **收益**：强制冷态 ⇒ 「命中跳过生成期副作用」这一类**结构性消失**（比 #60 T2 的见证式修法更彻底：不是「不在暖态读错」，而是**没有暖态**）。
- **代价**：这类程序的**增量编译收益归零**——粒度是「编译单元」而非「函数」（按 #60 T2 实测外推：语料 101 档中 3 档（`ptr_arith`/`ptr_ref_first`/`n19_ref_named`）受影响，按整档粒度这 3 档全部条目（各 15~17 条）失效；编译器**自源**档受影响 ⇒ 自举/自编译增量收益归零（110 条目 → 0））。
- **与已实施修法（(b) 见证式）的关系**：同一不变量（「生成期副作用 ⇒ 不可命中」）的**更粗粒度、更保守**形态（函数 → 编译单元）；现修法代价 0.3%/0.9%。
- **状态**：**备选登记，不实施**；(c)/(d) 与 W4 同挂 `docs/superpowers/plans/2026-09-15-warm-cache-diagnostics.md` §8.3 的两个可证伪触发条件（未判面构造出暖态消费者 / 命中率成实测瓶颈）。
- **出处**：W3/W4 批（报告 `/tmp/fct5/task-report.md` §5）。

### 65. 暖态「名字面」冷/暖分歧：**首次归因** P4 附录 D-1（2026-09-15 W3 批——**已归因，未实施修法，新批须裁**）
- **现象**：`.cir` DOT（`corec cir`）冷/暖差异**全部是变量名标签**（冷 `_arena:arena_new` → 暖 `arena_new`；四探针差异行 324/690/610/648，**非 label 差异 = 0**）；`.ccr` 冷/暖差 −108~117B。
- **根因（实读 + 实测）**：`ir_gen` 期**合成的名字串**在暖态缺席——`new_ir_var("bin", …)`（`ir_gen.cr:1231/1246/1256/1272/1284/1288`）· `new_ir_var("_arena", TI_INT)`（`ir_gen.cr:2008/2044/2102/2618`）等 ⇒ 命中跳过该函数 `ir_gen` ⇒ 这些串从未进入本进程串表；快照只载「函数级字符串常量」（`cir_cache.cr:226/:339/:614-617`），**不载生成期名字串** ⇒ 恢复的 var `name` 索引指向表外（`istr_get` 越域 ⇒ `get_ir_var_name` 返 `""`）⇒ DOT label 掉前缀 + `.ccr` STR 段变小（`strings` 实测：冷 100 → 暖 90 串，缺 `_arena`/`_arg`/`bin`/`call`/`_cat0`/`_cat1`/`const`/`_forced`/`_lazy`/`logic`/`logic_short`/`str`）。
- **风险划界（三条，实核）**：① **非静默面**——诊断码集两态一致，且 `get_ir_var_name` 的消费者只有 `dataflow.cr:556`（DOT）与 `dump.cr:45`（dump），**无诊断消息依赖变量名**；② **不传导产物**——ELF 逐字节同（四探针 + w4 静态/动态两形态），暖态 `.ccr` 经后端消费结果逐字节同；③ **与 TODO #5（编译器身份字段）不同层**——身份字段防**跨二进制**陈旧条目，本面是**同一二进制冷/暖**的名字面漂移。
- **首次归因 P4 附录 D-1**：D-1 原记「非可选程序冷/热 `.ccr` 逐字节同本就不可达」而**未给根因**；本条把差异面推进到「生成期名字串面 + 无产物传导」。
- **判据网限制（同处登记）**：暖态腿（`tools/baseline/warm_leg.sh`）现口径 = **rc + 诊断码集 + 产物 sha**，**不覆盖 label / 日志文本** ⇒ 本类名字面分歧**不会被腿抓住**；若将来要覆盖名字面须扩口径（**本批不实施**）；口径段见 `tools/baseline/REBUILD.md`。
- **状态**：**已归因，未实施修法**（新批须裁）；证据 = `/tmp/fct5/task-report.md` §2 · `/tmp/fct5/out/w*.{c1,c2,d1,d2}*`。

### 58. 容量批（CAP）收官：E-2 表示面聚合 + E-3 记录布局迁侧表 + E-4 缓存门（2026-09-15——**独立批全阶段收官**）
- **提交链**：`4607624c`（T1 白名单换代）+ 报告 → `432c2e40`（T2 = E-2）+ `7c4d6603`（#56）→ `0b0d9aef`（T3 = E-3）→ `15357b04`（T4 = E-4 收口 + #57）→ 本条目（T5 收官）。计划 = `docs/superpowers/plans/2026-09-15-capacity-batch.md`（含**统一台账**与**终态陈述**）。
- **交付**：**E-2**（裁-CAP-1 (a)）可选聚合槽（字段/数组·切片元素/元组元素/枚举载荷/全局槽）**写点装箱**（纯 IR、零布局变更）⇒ 原双路径 139 转正确值；同批修**两条预存根因**（读点常量折叠 + 写点静态度量初值）。**E-3**（裁-CAP-2 (a)）字段/变体/载荷**迁侧表**（记录尺寸与 `OFF_*` 不变 ⇒ 110 访问器零改动）+ 覆盖位**无界位图**（旧态 70 变体 SIGFPE rc=136）+ 三 `MAX_*` 退役 + P022/P023 停发 + 四死镜像删除；**`.ccr` 不 bump**。**E-4**（裁-CAP-3）机制实证**证伪** ⇒ 维持关缓存。
- **判据（T5 实跑）**：canary `95084e7b…d475`（28822B）IDENTICAL · `.ccr` 四条 96015/96158/142793/142936（冷+暖）· **换代基线 × 当前源 72 档零差异** · 探针 29 档零差异 · 五 CI job rc=0 · 枚举 **59/59** · `selftest-types` **415/415** · `check src/compiler` rc=0 · 链 `f69240ae…` + N06=0 + 冒烟 42 + `--help` rc=1 · `test_optional` **48/48** · `test_enum_limit` **18/18** · 突变 7 条（T2 4 + T3 3）全按设计转红。
- **台账 KPI**：实施 **4** · 删除 **3 类** · 迁移 **2 类**（+ selftest 44 处）· 收紧 **0** · 放宽 **2 类** · 修复 **3 件** · 登记 **12** · 偏差 **6** · **未取裁 2**。
- **待裁 2**：(D) 语言面拒绝 `*p = v`（pointee `T?`；已上报；影响面实读 = 拒绝**已错**形态）· T4「移除门」候选（性能面；附补证清单）。
- **关联**：#56（c3 静默错值，高优先预存）· #57（移除门候选）· spec §9 **容量批行** · 计划台账/终态陈述 · 下一批指向 = 验证切片轮 或 按维护者裁定。

### 70. 文档 vs 现实审计 + 修订批（2026-09-16——35 条断言实核：危险 7/陈旧 6/成立 20/无法判定 2；**13 条不成立项全部已修**）
- **交付**：新文档 `docs/superpowers/specs/2026-09-16-doc-reality-audit.md`（全表：断言 · 出处 `file:line` · 实核命令/结果 · 判定 · 修订去向）+ 3 提交修订链 `820648bc`（CLAUDE.md）→ `d2265f7b`（spec-design + ir-schema + ir-op-semantics）→ `43427334`（project-book + onboarding + verifier + errors.md）+ `docs/README.md` 索引登记。
- **危险 7（会让后来者照假前提设计）**：① `spec-design.md` **4 处**称 `variant`/`forall`「EBNF 已有」→ 实为零命中（`grammar/core.ebnf` 无标注槽；`corespec.ebnf` 已退役）· ② `ir-schema` 两文档称 `.csr`「真源 = `ccr_io.cr`」→ 全仓 **0 命中**（零实现却标 active）· ③④ **`CLAUDE.md`** 的 `src/compiler/` 清单 20→**38**、`src/stdlib/` 8→**19**（agent 必读面）· ⑤ `project-book §3.2` 按已退役独立 `.corespec`/`.corespecir` 叙述 → 整段改写 · ⑥ `onboarding.md:57` 把退役 `corespec.ebnf` 列「唯一真源」· ⑦ `verifier/kernel-spec.md:3` 仓外真源 `~/mctt` 无版本锚。
- **陈旧 6**：`ir-op-semantics:46`（`IR_APPROX` 实已入 `ast.cr:568`）· `coreir-schema:255`（`.ccr` v7 → **v9**）· `CLAUDE.md`「corec2 tokenizer 死循环」（**不复现**：full-bootstrap 链 rc=0 + P6 T6 IDENTICAL）· 套件清单不全（selfhost 50+）· `errors.md:297`「~146」→ **150**（+ 三口径注 150/149/137）· `ir-op-semantics §0` 外部真源无锚。
- **审计外新发现（已一并处置）**：`CLAUDE.md` 的 `.ccr` 版本 `v8→v9`（同类陈旧）· `src/compiler/linker.cr` = **0 字节空文件**（零引用；登记为清理候选）· `elf.cr` 死文件（TODO #7）在清单里已显式标注「勿引」。
- **无法判定 2（保留）**：`pass_cse/O1`（须一次 `-O 1` 自举实测；已在 CLAUDE.md 就地标注「未复核」）· `~/compcert` 树存在性/版本（未核）。
- **方法论登记（可复用）**：审计口径 = 「状态词 + 真源 + 计数」筛 → 逐条 `file:line` 实核 → 分级（危险/陈旧/轻微）→ 修复带**原断言原文**（注内引用/删除线），**不静默抹史**；采样本批 **35 条**（危险 7 条逐条给可复现命令）。
- **关联**：验证切片轮规划（本审计的直接缘起 = 其四处实读发现）· #64/#65（同族文档面）· `docs/README.md` 索引（本批登记）· spec `2026-09-16-doc-reality-audit.md`。

### 71. (A) 批 T3 登记：FFI/extern 边界 —— `*T?` 跨 extern 边界会破 INV-1（2026-09-16 (A) T3 审计实证——**绑定 FFI 可用性，本批不改**）
- **现象（本实例实测 5 例；证据 `/tmp/capt7/probes/e1..e5`）**：`extern fn extw(p: *int?) -> int;` 以 `p := &x`（`x : int?`）调用 ⇒ **check rc=0（编译期接受）**；运行期 **ELF 139 · interp 2**。① `*int?` 形参（e1）② `*int` 形参传可选槽地址（e2）③ 按值 `int?`（e3）④ `&g` 全局可选槽（e4）——四条同；**非可选对照 e5（`*int` + `&n`）同样 139/2** ⇒ 运行期失败**与可选性无关**（FFI 静态路径预存阻塞，`tests/suite/ffi_test.cr` 头注已载）⇒ **当前无「可选专属静默错值」**。
- **风险（给 FFI 批）**：FFI 运行期一旦可用，外部代码按原生布局写回**裸值** ⇒ 破 (A) 批 **INV-1**（取址槽恒持装箱值）⇒ 须加边界约束：**禁 `*T?` 形参** 或 **调用点强制重装箱**（二选一，届时裁）。
- **状态**：**登记，未修**（属 FFI 面，越 (A) 批范围）。**判据** = 上列 5 探针 rc 表；**关联** = (A) 计划文档 §裁-T3-2 · 报告 `/tmp/capt7/task3-report.md` §4。

### 72. 推断的**模块级全局数组**：元素写点 139/139（2026-09-16 (A) T3 审计发现——归**全局类型推断**缺陷面，**非可选面**）
- **现象（本实例实测；证据 `/tmp/capt7/probes/i2_global_inferred_arr.cr`）**：`g := [Some(1), None];` + `fn main() -> int { g[0] = 5; return match g[0] { Some(v) => { return v; } None => { return 0; } }; }` ⇒ **check rc=1**（**TK01「Cannot index non-array type」**）+ **build rc=0（软诊断不拦）** + **ELF/interp 139/139**。
- **根因面**：推断的模块级全局（无注解 `g := <聚合字面量>`）在 **checker 侧**即**无类型面**（索引判定无类型可查 ⇒ TK01）⇒ 与 (A) T3 修的「可选元素声明面登记」**不同面**（后者要求 checker 已给类型）。
- **对照（同批实测正确）**：**标注**全局数组写点 `g : [int?;2] = …` 字面量下标 **5/5**（`i4`）· 动态下标 **6/6**（`i5`）。
- **状态**：**登记，未修**（归「全局类型推断」批次）；**建议判据（修复时）**：i2 探针须 **check rc=0 + 双路径正确值**（而非现在的「TK01 + 139」双态）。**关联** = (A) 报告 §5。

### 73. (A) 批（表示位随存储走）**收官**（2026-09-16——独立批 T1–T5 全阶段收官）
- **批交付**：裁-REP-1 (iii)「取址槽恒装箱」（W1 取址预扫 · W2/W3 写点装箱 + **表示位钉 1** · W4 形参序言条件装箱 · W5 `IR_STORE_PTR` 按 pointee 装箱 · W6 零足迹门）· **第二根因** ELF `IR_REF` 全局取址修复（`src/arch/x86_64/instr.cr:1095`；`e2_lb(g2_slot())` 帧外伪偏移 ⇒ 全局源改 `lea r10,[rip+rel32]` + RIP 补丁）· T3 写点完备性审计 + 裁-T3-1 修复（推断可选数组/切片元素写点，7 形态 139/139 → 正确）。
- **判据（两轮全绿；证据 `/tmp/capt6/crit/` 与 `/tmp/capt7/crit2/`、`/tmp/capt7/crit3/`）**：构建确定性 ×2 IDENTICAL · `selftest-types` **415/415** · `check src/compiler` rc=0 · 枚举 **61/61** · 五 CI job **5/5** · **ELF canary `95084e7b…d475`（28822B）IDENTICAL** · `.ccr` 两口径四条命中锁定值（96015 `680a6f98…` / 96158 `76f36e6a…` / 142793 `41e9d845…` / 142936 `704316c8…`）· 腿① 72 档零差异 · 探针 29 档冷态零差异 · 暖态腿 FAIL=0 · 自举链 + N06=0 + `--help` rc=1 + 冒烟 42 · 突变 3+3 条全红 + 精确回滚；用例 `tests/selfhost/test_optional.py` **48 → 66 → 80 例**。
- **批终态一行结论**：(A) 批全阶段完成，判据全绿、canary 无豁免未变、**无新的静默错值**；**TODO #56 核销**；残留四条已拆为独立条目 **#74/#75/#76/#77**，FFI 与全局数组面为 **#71/#72**。
- **提交**：`deab3862`（计划）· `a140340d`（T2 裁）· `1e11353c`（T2 实现，**PR #74** → `d9327ad2`）· `c5056b2d`/`5d36af98`/`7b006ef5`（T3，**PR #75** → `f5345b53`）· T4/T5 文档提交（**PR #76**）。
- **关联**：计划 `docs/superpowers/plans/2026-09-16-opt-rep-follows-storage.md` · 批报告 `docs/superpowers/specs/2026-09-16-opt-rep-batch-report.md` · 日志与证据 `/tmp/capt6/**` · `/tmp/capt7/**`。

### 74. REP-3：`&s.a` 结构体字段**取址写入丢失**（2026-09-16 (A) 批 T1/T2/T3 复核——**维持登记，独立缺陷面**）
- **现象（本实例实测；证据 `/tmp/capt6/probes/f4_field_bare.cr` 等）**：`struct S { a: int? }` + `p := &s.a; *p = 5;` ⇒ 写入**静默无效**（`match s.a` 得初值；ELF/interp 双路径 **0/0 同**——非分歧，是**两路径同错**）。
- **根因（`file:line`）**：`UOP_REF` 无**字段**分支 ⇒ 走 `gen_expr` 先 LOAD ⇒ 取到**临时量**地址而非槽地址（计划 §2.3 引理 1 行 #3）。
- **修法前置**：须新增字段地址路径 `IR_ADDR_FIELD`（后端 `instr.cr` + 解释器 `interp.cr` 同改）⇒ 属**另一缺陷**，本批（(A)）与容量批（E-2）均**未修**。
- **状态**：**登记，未修**；**判据（修复时）**：`f4`/`f4b` 两形态须给**精确值**（裸 5/装箱 5），且 `test_optional.py::a_field_addr_registered` 从「双路径同 rc」升级为精确值断言。

### 75. REP-2：**指针算术**伪造地址（越出「取址面可枚举」边界）（2026-09-16 (A) 批 T2 裁-REP-2——**维持登记，边界面**）
- **现象/边界**：`p ± n`（`src/compiler/ir_gen.cr:1208` `OP_PTR_ADD/SUB/DIFF`）的地址由**运行期**算术派生 ⇒ **不可在 IR-gen 期分类**（(A) 批完备性论证的**唯一非直接取址边界**，另一为 extern = #71）；可落到**未被取址**的可选槽。
- **现状实测（探针记录现实行为）**：`test_optional.py::a_rep2_ptradd_boundary` = `x : int? = 5; y : int? = 6; q := p + 1; *q = 7;` ⇒ 当前布局下 `y` 未受影响（双路径同 6）。
- **修法前置（若将来要做）**：需语言面限制（禁 `*T?` 算术）或运行期表示分派（布局变更）⇒ **本批不引入语言面限制**（裁-REP-2）。
- **状态**：**登记，未修**；判据 = 上列探针 + 变更时须重跑。

### 76. B04 软诊断面：`&x` 借出后再读 `x`（2026-09-16 (A) 批 T3 用例固化为「恰 {B04}」——**未修**）
- **现象**：`p := &x; ...; match x {...}` ⇒ check 面发 **B04**「Cannot use 'x' while it is borrowed」；**软诊断**（`build` 仍 rc=0 + 产物照出）；T1 四形态探针同诊断（**非 (A) 批引入**）。
- **根因面**：borrow checker **无 NLL/liveness 收窄**（借出在末次使用后不释放）⇒ 属既有 borrow 面。
- **本批处置**：新增用例一律以 `case_dual_softdiag` 钉「**恰 {B04}**」（多一条即红）——把现状固化成判据，**未修**。
- **状态**：**登记，未修**；修法 = 引入 NLL（另一批）。

### 77. `IR_REF` 目标侧是否可能为全局（2026-09-16 (A) 批 T2 第二根因修复时的**未实测面**——**仅登记，不写进结论**）
- **内容**：T2 修 ELF `IR_REF` 的**源侧**全局取址（`instr.cr` 全局分支 + RIP 补丁）时，**未实测**「`IR_REF` 的**目标** `d` 是否可能为全局 var」（现 IR 形态下 `d` 恒为 `ir_gen` 新建的临时量 ⇒ 走 `g2_slot` 分支）。
- **状态**：**登记（未实测断言）**；核对面 = `ir_gen.cr` 全部 `emit(IR_REF, …)` 发射点的 dest 来源（若将来出现全局 dest ⇒ 须补 `e2_store_var` 式目标侧分支）。

### 78. **【总闸级】聚合读丢型**：`IR_LOAD_FIELD`/`IR_LOAD_INDEX*` 结果槽硬定型 `TI_INT` ⇒ 「按 IR 值型分派」的下游**连锁失效**（2026-09-16 apx 转换审计发现——**影响面超出 apx**）
- **现象（读码判定；证据 = `docs/superpowers/specs/2026-09-16-apx-conversion-audit.md` §1 ③b/④b/⑤/⑥b/⑧）**：结构体字段读 `ir_gen.cr:2520`（`new_ir_var("field", TI_INT)` + `IR_LOAD_FIELD`）、数组/切片元素读 `:2583`（`IR_LOAD_INDEX`）/`:2591`（`IR_LOAD_INDEX_VAR`）——**读结果的 IR 型恒为 `TI_INT`**，字段/元素的**声明型信息丢失**。
- **为何是「总闸」（不低 apx 批本身）**：任何**按 IR 值型触发**的下游判定都会在「经聚合读入」的值上失效——已知三类：① **dex 形式转换**（apx 审计：转换分支按 `TI_DEX`/`TI_DEX_S` 判 ⇒ 不触发 ⇒ 静默错值，见审计表 A 行 ⑧/③b/④b）；② **(A) 批的可选表示面**（声明面登记 `/` 解包分派若按值型判 ⇒ 同类失效面）；③ 其它「类型驱动」的算子选择（字符串拼接、指针宽度等，未逐一枚举）。⇒ **单点修好可同时收敛多条静默错值线**。
- **修法方向（读码建议，非裁）**：读点定型改取**声明面/元素面**（字段 ⇒ `field_ti_of_node` 同源；元素 ⇒ `elem_ti_of` 同源），或在读点后**补登记**声明型侧表（照 (A) 批 `irv_set_decl_ti` 先例，零布局变更）。
- **状态**：**登记，未修**（本轮**只读审计**，零构建/零源码改动）。**判据（修复时）**：① 审计表 B 的 B-2/B-3/B-4/B-5/B-6/B-8 由「静默错值」转**精确值**；② canary/`.ccr` 四条**不变**（门控面须审）；③ 聚合读的 `irv_type` 断言进自测（新用例 ≥6）。
- **关联**：apx 批次（表 B 的 RED 语料）· (A) 批 T3「声明面登记」修法（**正交**，勿混：T3 修的是**写点**的登记来源，本条修的是**读点**的定型）· `ptr_analysis.cr` 型面消费者（交叉核对面）。
- **【apx 批交叉引用（2026-09-16 裁-APX-8）】**：① **RED 语料** = apx 批探针表 B-3a/B-3b/B-4a/B-4b/B-4c/B-5/B-6/B-8 的子集（现全部转正，**但那是 apx 批的写点漏斗 + 比较点声明面查表做到的，本条未修**）；② **修复本条时须同改点** = `ir_gen.cr:2513`（字段读）/ `:2578`（元素读）/ `:2316`（match 绑定）/ **`:2222`（match 结果槽——apx 批 T2 新增，本条原未列）** + 消费者（二元对齐 `:1249` 邻域 · `ptr_analysis.cr` · `regalloc.cr:680-681` 类型门 · 可选表示面）；③ **注意**：apx 批已用 `dex_decl_form_of_expr`（**节点级零 alloc**）在**比较点**做了作用域替代——修本条时可复用它，但**不得**把 `res_type_node`/`alloc_type` 引入 ir_gen 路径（apx 批 Global Constraint 12 不变量：warm 命中跳过 `ir_gen_func` ⇒ 新增 `alloc_type` 站点会破坏暖缓存不变式）。

### 80. ⚠ **【高危·预存】方法调用的 `apx` 实参不做形式转换**（环门 `EXPR_IDENT` ⇒ `EXPR_FIELD` 整段跳过）——**静默错值 · 双路径同错**（2026-09-16 全局 operand seam 批 T1 实测；**同族见 #81**）

- **最小复现**：`struct S { v: int }` + `impl S { fn m(self: S, x: dex) -> dex { return x * 2.0; } }` + `g : dex, apx, mut = 1.5;` + `y := s.m(g); if y != 3.0 { return 1; } return 7;` ⇒ **实得 rc=1（期望 7）**。
- **双路径实测**：`corec run` rc=1 / `build --static` 产物 rc=1 ⇒ **两条路径一致地错**（**不是** ELF-only 分歧）。
- **局部对照（定性关键）**：`lx : dex, apx, mut = 1.5; y := s.m(lx);` ⇒ **同样 interp 1 / ELF 1** ⇒ **与全局行无关**：根因 = 调用点 dex 形式转换环（`ir_gen.cr:1810-1841`）以 `ast_kind(func_node) == EXPR_IDENT` 为门，方法调用（`EXPR_FIELD`）**整段跳过** ⇒ apx（binary64 bits）实参未转 scaled 直达 callee，而 callee 形参侧按 `TI_DEX_S` 解释（`ir_gen.cr:2866`）。修法须注意**实参/形参对齐差一格**（`arg_vars[0]` = 接收者，被调 `EXPR_PARAM` 链不含 self，`ir_gen.cr:1779-1786`）。
- **为什么比响亮失败更危险**：**无声**（无诊断）+ **两路径一致** ⇒ 「双路径对拍」类判据**抓不到**，只能靠语义断言（值的量纲/期望值）抓。**排队优先级按高危表述，不得写成「低优先登记」。**
- **附注（勿混根因）**：直调 `dbl(g)`（`EXPR_IDENT`）走环内转换，其错值可归因**全局读 seam**（全局 operand seam 批 B1 迁移面）；与本条（非 IDENT 调用形态）根因不同。
- **关联**：#81（同族）· 全局 operand seam 批计划 `docs/superpowers/plans/2026-09-16-global-operand-seams.md` §T1 记录 N-3。
- **✅ 状态：已修（2026-09-16 apx 批 T3）**——门从 `ast_kind(func_node) == EXPR_IDENT` 放宽为「`func_ni ≥ 0` 且 `find_func` 命中 Core/extern 函数」，**逐形态**覆盖直调 / 方法调用 / **模块限定调用**（**不是「凡调用都进环」**）。判据 = `tests/selfhost/test_apx_conversion.py::method_arg_apx`（ELF rc **49→7**）/ `method_arg_self_offset`（**15→7**）+ 突变 M2（环门退回 ⇒ 49/124 红）。**同批实测**：`#81` 的「落位公式不对称」判为**证伪**（直调同形绿 7 vs 方法同形红 0，唯一变量 = 调用形态）⇒ #80 与 #81 **同一修复**。**附带**：模块限定调用同门 ⇒ 同批转正（`module_qualified_call` 例）。**关联**：批报告 `docs/superpowers/specs/2026-09-16-apx-conversion-batch-report.md`。

### 81. ⚠ **【高危·预存】局部 `apx` 量作第 9 个 binary64 栈参**（`cs_stack_args` 面）——**静默错值 · 双路径同错**（2026-09-16 全局 operand seam 批 T1 实测；**与 #80 同族 = `apx` 形式转换缺口族**）

- **最小复现**：方法带 8 个 `dex` 形参（第 9 个 `dex` 实参落栈：SysV 第 9 个 binary64 起走 `cs_stack_args`），第 9 参传 `lx : dex, apx, mut = 1.5`，方法直接 `return` 该形参 ⇒ **期望 1.5（rc=7 形），实得 rc=1**；`corec run` 与 `build --static` **同错**。
- **对照**：第 9 参改用**全局** apx 量 ⇒ 该形态实测 rc=7（因 `need_pack` 打包介入，见 seam 批 §T2-c）⇒ 本条与全局行无关。
- **与 #80 合看 = 面不是点**：`apx` 形式转换缺口在「**非 `EXPR_IDENT` 调用形态**（#80）」与「**栈参位**（本条）」两处共存 ⇒ 建议同批修（转换环覆盖面 + 栈参位形式），单点修必留另一处。
- **关联**：#80 · 全局 operand seam 批计划 §T1 记录 N-1。
- **✅ 状态：已修（2026-09-16 apx 批 T3，与 #80 同一修复）**——机理**已裁定**：T1 用「直调 vs 方法调用**同形只差调用形态**」的行为差分证伪了「落位公式不对称（`frame.cr:133/139` 按形参序号 vs `callseq.cr` 按类型类）」候选，坐实根因 = `#80` 的**同一个门**（故 `frame.cr`/`callseq.cr` **一行未改**）。判据 = `test_apx_conversion.py::stack_arg_9th_method`（ELF rc **0→7**）/ `stack_arg_9th_direct`（对照保持 7）+ 突变 M2（⇒ 0 红）。

### 79. 全局 operand seam 批**收官**（2026-09-16——`g2_slot` 全局行「帧外伪偏移」同族六点收编；**四点 RED 转正** + 两条探针硬约束 + 偏差台账 3 条）

- **根因**：`g2_slot`（`src/arch/x86_64/instr.cr:55-72`）对**全局行**（`v < var_start`）返回**帧外伪 rbp 偏移**（指向调用者帧的合法位移）⇒ 一切直吃 `g2_slot` 的操作数读写点**静默读写调用者帧**；int 面已由 `e2_load_var` 收编，**dex 面五件（`e2_sd_load/load1/load_x/cvt/store`）与写侧从未收编** ⇒ 按 `IR_*` 分支逐个漏。
- **交付**：计划 `docs/superpowers/plans/2026-09-16-global-operand-seams.md`（含 T1 RED 实测、T2 完备性枚举、七门裁决与证伪留痕、探针表、停条件）；提交链 = 计划 → 七门裁决落纸 → T2 枚举 + `need_pack` 掩蔽修正 → **T1 决定性 RED**（B1/B2/B4/B5，`mut` 全局三重隔离）→ 裁-SEAM-3 证伪改判（准 (b) 单列 #80）→ **T3 seam 收编**（新增 `e2_lea_glob`/`e2_is_glob`/`e2_sd_ld_var`/`e2_sd_cvt_var`/`e2_sd_st_var`/`e2_st_var`；迁移 B1 585/586+593 · B2 532+533 · B4 1398-1403 · B5 1411-1416 · B6 `callseq.cr:75`/`:129` · B7 `cs_ret_value` 全局支按型分派 · B8 1886/1921/1952；删死码 `sz_ofs`/`sz_load_var` + 死变量 `o1`）→ T4 套件 `tests/selfhost/test_global_seams.py`（12 例）+ suite 语料 `tests/suite/global_seam_test.cr` + `run.sh` 挂钩 → REX.B 修复 + 判据收紧 → 腿① 计数 72→73 → T5 记录。
- **判据（全绿）**：T4 套件 **12/12** · suite 语料 rc=0 · 冒烟 42 · **canary `95084e7b…d475`（28822B）IDENTICAL** · `.ccr` 两口径四条全同 · `check src/compiler` rc=0（0 条 `error[`）· `selftest-types` 415/415 · 五 CI job 全 rc=0 · 自举链 `corec2==corec3` **IDENTICAL** + N06=0 · 腿① **73 档**对拍零差异 · 探针 29 档 rc/冷日志/暖态零差异 · **突变双向**（全局分支改坏 ⇒ 全局组探针 + 字节判据红；非全局分支改坏 ⇒ 探针 11/12 红 + **canary 变** `a7ef9ddf…`）。
- **登记（本批不修，另单）**：#80/#81（`apx` 形式转换缺口族——B6(c) 方法调用形态经实测**证伪**归此类）· **B8 表实例 disp 参三处**（`hit_st_modrm_disp` 形态，seam 套不上）· **`e2_sd_*` 五件无 `E2_REG_SLOT_BASE` 分支**（现因 regalloc 类型门 `regalloc.cr:680-681` 不可达）· **全局 `string` 行型面**（`reg_one_global` 默认 `TI_INT` ⇒ `g[0]` 走 8 字节元素支、`g == "s"` 不比较内容）。
- **两条探针硬约束（写全局/dex 探针前必读）**：① 必须用 **`mut` 全局**——不可变 + 字面量初值的全局被 `find_global_const_node`（`ir_gen.cr:592-611`）**折叠成 `IR_CONST`**，读点不碰全局行（探针假绿；本批 T1 第一轮即栽在此处）② **`apx` 算术无解释器腿**（`corec run` 显式拒收 rc=255，能力边界非缺陷）⇒ 主判据 = **全局 vs 局部同形 ELF 对拍**（两条均已落 dex/apx 迁移遗留节 + 套件头注）。
- **偏差台账 3 条（本批自曝、全部闭合）**：REX.B 自伤（`[r11]` 缺 REX.B 编码成 `[rbx]` ⇒ 139，T4 套件当场拦）· 弱判据（逐片段独立 `find` 放跑了它 ⇒ 改连续序列正则）· 计数漂移（新增语料 ⇒ 腿① 72→73 显式更新）。详见计划 §T5。

### 82. **`.ccr` 产物依赖 `$HOME/.core/lib/<模块>/index`** ⇒ **跨机不可复现**（2026-09-16 判据载体化批 CI 红档挖出——**可复现性缺陷**，与「缓存键缺编译器身份」同族）
-### 79. **`.ccr` 产物依赖 `$HOME/.core/lib/<模块>/index`** ⇒ **跨机不可复现**（2026-09-16 判据载体化批 CI 红档挖出——**可复现性缺陷**，与「缓存键缺编译器身份」同族）
+### 82. **`.ccr` 产物依赖 `$HOME/.core/lib/<模块>/index`** ⇒ **跨机不可复现**（2026-09-16 判据载体化批 CI 红档挖出——**可复现性缺陷**，与「缓存键缺编译器身份」同族）
- **现象（实锤，非推断）**：同一提交、同一编译器，仅 `$HOME` 内容不同 ⇒ `tests/suite/generics_test.cr`（`import io` / `import fmt`）的 `.ccr` **差 28B**：本机 `~/.core/lib/io/index`（164B）在场 = 142793B `41e9d845…`；CI（`/home/runner`，无该文件）= 142765B `d92a2727…`。段级定位 = 差异**全在 STR 段**（2521→2493），多出的两条串恰 `print_int`(9) + `println_int`(11)（2×4 长度前缀 + 20 = 28B）。本机 `HOME=<空目录>` **精确复现 CI 的 size 与 sha** ⇒ 归因闭合。
- **落点**：`src/compiler/module.cr:523-530`——解析 `import` 时读 `$HOME/.core/lib/<fs_path>/index`，命中即 `reg_so_funcs(so_idx, fs_path)` 把索引里声明的函数名驻留进串表。
- **敏感性面比「多了几个新名字」更大（单列，2026-09-16 实测）**：**良性索引**（内容只列**已被 stdlib 驻留**的名字 `print`/`read_file`）⇒ 产物**尺寸不变**（142765）但 **sha 变**，且差异散布 **STR/SYM/NOD/IFACE 四段**（如 IFACE 仅 1 字节）⇒ 真正的触发因是「**索引是否存在**」本身（注册动作改变了既有条目的序/标记），不是新名数量。**判据的输入面因此比预期大**：任何 `$HOME/.core/lib/*/index` 的在场都足以扰动产物。
- **判据（修复时）**：① 同一提交在两个不同 `$HOME`（空 / 含 `io/index`）下编译同一语料 ⇒ `.ccr` **逐字节同**；② 或静态：`.so` 元数据注册**不得**改变「无 extern 调用」语料的产物面。
- **状态**：**登记，未修**（本批只在**闸门侧**归一化 `HOME`，未动编译器）。**闸门侧缓解**：`tools/baseline/canary_check.sh` 已把 `HOME` 钉到采集目录内的空 `home/`（输出打印实际值），`.ccr` 四条自本批起锁定「环境归一化后」的值（旧值留痕见 `tools/baseline/canary_values.tsv` 头注）。
- **关联**：TODO #5（缓存键缺编译器身份——同族「跨机不可复现」）· 下条 #83（同一段代码的另一面）。

### 83. `module.cr` 家目录**硬编码兜底** `/home/DslsDZC`（2026-09-16 同上挖出——**环境依赖 + 可移植性 + 隐私面**）
- **现象**：`src/compiler/module.cr:525-526` = `home_dir := get_env("HOME"); if str_len(home_dir) == 0 { home_dir = "/home/DslsDZC"; }`——`HOME` 未设或为空时，编译器把家目录兜底成**原开发者**的家目录：他人机器上会去读一个不存在的路径；更糟的情形是读到**别人的** `~/.core/lib`（进而改变产物，见 #82）。
- **判据（修复时）**：`HOME` unset/为空时**不得读取任何家目录路径**——① 静态断言：仓库内不得出现硬编码家目录串；② 行为测试：`HOME` unset 与 `HOME=<空目录>` 编译 `import io` 语料 ⇒ 产物**逐字节同**。
- **状态**：**登记，未修**。
- **关联**：上条 #82（同一段代码的两个面：① 读了会变产物；② 兜底读了谁的家目录）。**编号说明（时序）**：本分支基点（develop `47dde0d8`）**早于 seam 批合入**（seam 批经 squash `e529aba2` 入 develop，且带一条「#79 全局 operand seam 批收官」）⇒ 本批写入时看不到 develop 的 #79–#81，故**按 develop 现状**取 **#82/#83**（避让已占号：`#79` 属 seam 批收官条目、`#80/#81` 属 seam/apx 两条）。

### 84. ⚠ **【判据强度】HIT 表事件 1-4 的字节判据只比前 2 字节**（2026-09-16 判据强度审计 **B2**——**弱判据，本批不修**）
- **现象（【实核】`tests/selfhost/test_hit_table.py:1207-1219`）**：事件 1-4 由 TOML 字段**重装**字节流后，断言是 `chk(stream[:2] == want, …)`——**只比 REX+opcode 两字节**；`modrm`/`sib`/`disp` 及其后字节**无任何判据**。
- **最小坏实现（能骗过它却真坏）**：改 `src/arch/x86_64/core-x86.toml` 的 `modrm_reg_role`/`modrm_rm_role`（或给 `opcode` 尾追加一字节）⇒ 前 2B 不变 ⇒ **判据全绿**而发射字节已坏（seam 批 `REX.B` 事故即此类）。
- **兜底**：若该套件跑产物则有行为腿；否则无（且该套件**未挂 CI**，见 #89）。
- **建议修法（判据侧）**：改**连续序列断言**（整条指令字节，含 `??` 通配位）或**带定长 gap 的正则**（见 `docs/superpowers/specs/2026-09-16-criteria-strength-audit.md` §0）；每条判据须能回答「什么坏实现能骗过它」。
- **状态**：**已修（2026-09-16 判据网加固批 T2）**。新判据形态 = `test_hit_table.py::ev14_template_problems`：① 事件 1-4 step **全字段模板**（键集+取值逐键相等：opcode 全字节 + REX 全位 + modrm 两角色 + rm_mode）；② 重建 legacy 字节流与 M1 模板**全等**（非前缀）；③ **不可达前提显式断言**（注入语料不得覆盖 sub/nand——事件 1/2 对真 IR 不可达（mw 门），本表断言是其唯一字节证据）。**证据**：真实表零问题（正控）；突变自证 3 例（角色换向 / opcode 尾加 1B / rm_mode）= 旧形态绿 ∧ 新形态红（`tests/harness/test_criteria_mutations.py` M1，22/22 总账）。该套件**同批挂上 `selfhost-tests`**（实测 2.3s，24/24）。

### 85. ⚠ **【判据强度】慢路径块体只有 2B 锚**（2026-09-16 判据强度审计 **B6**——**弱判据，本批不修**）
- **现象（【实核】`tests/selfhost/test_mw_task2.py:242`）**：`bad_pre = [t for t in targets if text[t:t+2] != BLK_PREFIX]`——慢路径块只校验**2 字节前缀**（+ 目标序单调），**块体其余字节无判据**。
- **最小坏实现**：改块体长度/尾部字节（保持前缀与顺序）⇒ 锚仍命中 ⇒ **绿**（行为可能已坏）。
- **兜底**：**有行为兜底**（该套件对照 oracle/运行产物）⇒ 危害低于 #84。
- **状态**：**已修（2026-09-16 判据网加固批 T2）**。新判据形态 = `test_mw_task2.py::parse_slow_block` **逐指令模板断言**：除三处站点相关字段（alloc 调用位移 / dest 槽偏移 / 回跳位移）外**全字节钉死**（`4D 19 DB`〔sub 版另加 `49 F7 D3`〕/ `41 52 41 53` / `BF 10 00 00 00` / `41 5B 41 5A` / `4C 89 10` / `4C 89 58 08` / dest 槽三形态 / `C6 45|85 … 01`）+ 独立断言 **tag 立即数 == 1**、**回跳目标落在主区真指令边界**、**块间连续**（块长公式）、**各站点 alloc 目标唯一**。**证据**：t1/t2/t3（250 站点）三档全过 + **新增 `t4_sub_overflow`**（原三例全 add ⇒ `is_sub` 分支从未被走到 = 审计 §0bis 第二类假绿实例，已补语料并写进该 spec）+ 突变自证 3 例（tag 1→0 / 插 `0x90` / `4C 89 10`→`18`）。

### 86. **【判据强度】未用哨兵字段检查 = 4 字面量黑名单**（2026-09-16 判据强度审计 **B3**——**弱判据，本批不修**）
- **现象（【实核】`tests/selfhost/test_hit_table.py:281`；**引文锚** = `bad = [s for s in ("dst=255","s2=255","dst=-1","s2=-1") if s in out]`；旧记 `:284` 系 `if bad:` 分支邻域，以引文为准）**：只排 4 个字面量形态。
- **最小坏实现**：让哨兵以 `0xFFFFFFFF` / `-2` / 带前缀或别字段形态出现 ⇒ 黑名单不命中 ⇒ **绿**（「未用字段恒 0」的命题未被真正断言）。
- **建议**：改为**白名单式**（dump 行必须匹配期望模式）或**结构化解析**（按字段取值判 0），而非黑名单枚举。
- **状态**：**已修（2026-09-16 判据网加固批 T2）**。新判据形态 = `test_hit_table.py::dump_sentinel_problems`：**结构化解析 + 白名单形态**——每条 `ev` 行必须整体匹配 `ev <name> dst=<v> s1=<v> s2=<v>$`（多字段/尾随垃圾/缺字段 ⇒ 不匹配 ⇒ 红），值必须 `\d+` 或 `pool\d+`，**未用字段（store dst / load s2）逐字符 == "0"**（顺带排除 `0x0`/`00`/`-0`）；+ 非空转计数（store/load 行数各 ≥1）。**口径边界（勿夸大）**：**用于**字段取任何 `\d+`（含 255）**不是**哨兵伪影、本判据不主张覆盖。**证据**：真跑实测 10 事件行（store 4 / load 3）全绿；突变自证 5 例（1 / 0xFE / 0xFFFFFFFF / `00` / 行尾随字段）= 旧黑名单绿 ∧ 新判据红。

### 87. **【判据强度】STR 段冷/暖差异 = 预存豁免**（2026-09-16 判据强度审计 **B4**——**弱判据/口径面，本批不修**）
- **现象（【实核】`tests/selfhost/test_cir_warm_path.py:172-175`）**：`.ccr` 段级契约对 **STR 段冷≠暖「预存豁免」**，只登记**尺寸**；STR 段内容的冷/暖差异无判据。
- **最小坏实现**：让暖态 STR 段多写/漏写一条（尺寸同步变化或同尺寸改内容）⇒ 判据不红。
- **兜底**：真产物（ELF）逐字节同（STR 不传导 ELF）。
- **状态**：**已修（2026-09-16 判据网加固批 T2）**。新判据形态 = `test_cir_warm_path.py::str_contract_equal`：**暖 STR 必须是冷 STR 的前缀**——① `n_warm ≤ n_cold`；② `warm == cold[:n_warm]`（同 index 逐条字节相等 ⇒ 同尺寸改内容必红、中间漏条必红〔错位〕）；③ 非空转（两侧 ≥1 条）。**假设先实测后定判据**（不是拍脑袋）：A5 基例 **181 条→169 条**、D4 pad 语料 **574 条→562 条**，逐条字节同的前缀，冷多出的正是 ir_gen 临时名（`_arena`/`bin`/`str`/`call`/`_lazy`…）⇒ 假设成立、判据按实测形态落。**证据**：`test_cir_warm_path` 19/19 PASS；突变自证 3 例（同尺寸改内容 / 中间漏条 / 暖态多一条）+ 正控（暖=冷前缀仍绿）。与 TODO #65「暖态名字面」的关系：**该面（归因）不动，本条（判据面缺口）已闭合**。

### 88. **【判据强度】`--dump-tk-terms` 比对「剔行后」进行**（2026-09-16 判据强度审计 **B5**——**弱判据，本批不修**）
- **现象（【实核】`tests/selfhost/test_ccr_types.py:1760`）**：带/不带 flag 两次运行的产物与 stdout 比对是**剔除若干行后**做的，且**未断言「被剔面必须为空」**。
- **最小坏实现**：让被剔行的内容发生实质变化（仍落在剔除面内）⇒ **绿**。
- **建议**：把剔除面**显式化为白名单 + 计数断言**（剔除行数 = 期望值），或对被剔面单列判据。
- **状态**：**已修（2026-09-16 判据网加固批 T2）**。新判据形态 = `test_ccr_types.py::dump_strip_face_problems`：① 被剔面必须**连续一段**且以唯一 `[df-tk-terms]` 头行起始；② 剔除行数 == 1 + 头行自报 **`nodes=`**；③ 每条数据行 9 个十进制字段且**首字段 == 行序数** 0..nodes-1（重复/乱序/插入 ⇒ 红）；④ 非空转 `nodes ≥ 1`；⑤ 保余面逐行等同无 flag 输出。**口径修正（实测驱动）**：头行 `rows=` 是**类型表行数**（`dump.cr:388 g_type_count`）不是数据行数——判据初版按 `rows` 计数**真跑当场红**（`剔除行数 1355 != 1+rows=16`），按住实测格式改 `nodes=` 并加序数断言（比原设想更强）。**证据**：`test_ccr_types` 49/49 PASS；突变自证 3 例（多印一行未计数 / 非 dump 处混入数据行 / 同数量换行）+ 正控。

### 89. ⚠ **【结构性·高危】最强的若干类字节判据**仍未挂 CI**（2026-09-16 判据强度审计**——**挂点缺失，本批不修**；**标题已按审计修正版收窄**）
- **事实（【实核】`tests/harness/ci_hook_allowlist.txt`）**：**仍未挂**的强字节判据 = `test_backend_bootstrap.py`（**`:19` 自标「最高危」**——N06 静默之门，仓库自述「唯一」但**未独立复核**；已致 **P3a 33×N06 真实漏检**，TODO #36 段）· `test_hit_table.py`（`:25`）· `test_mw_task1..6.py`（`:30-35`）· `test_region_cfg.py`（`:39`，与格式批同族 ⇒ **漏检面最大**）· `test_live_ranges.py`（`:28`）。
- **⚠ 修正（判据强度审计 05:58 后状态）**：原表述「**最强字节判据全部未挂 CI**」**已过宽**——**ELF canary 与 `.ccr` 四条锁定值的机器闸门已于「判据载体化」批挂上** `selfhost-tests`（`tools/baseline/canary_check.sh` + `canary_values.tsv` + `tests/harness/test_canary_carrier.py`；`src/ci/run.sh:137,142`）⇒ **「未挂」集合收了 2 条、仍余 5 类**（上列）。
- **成本估算（allowlist 原文）**：`test_ent_kernel_neutrality.py`（`:23`）**低成本**（纯 python 静态 guard，无构建依赖）· `test_backend_bootstrap.py` 挂点须**先实测时长**（构建面）· `test_mw_task2.py`（`:31`）**中高且属口径换代**（零 diff 腿的基线须在改动前编译器上产 ⇒ CI 参照物结构性不可得；要机器化须「基线入仓」取裁或改「结构断言 + 语义零变化」口径）。
- **建议批序（审计修正版，依据 = allowlist 自述）**：**① 低成本** = `test_ent_kernel_neutrality.py`（`:23` 纯 python 静态 guard）· `test_slice_bounds.py`（`:40` 无二进制依赖）⇒ **先挂**；**② 中成本** = `test_hit_table`（`:25`）· `test_region_cfg`（`:39`，与格式批同族 ⇒ **漏检面最大**）· `test_live_ranges`（`:28`）；**③ 高成本/需先取裁** = `test_mw_task1-6`（`:31` 明写「中高，且属口径换代」）· `test_backend_bootstrap`（时长未测）· `test_lsp`（`:29` 进程级）。
- **状态**：**大部分已修（2026-09-16 判据网加固批 T1）；余项仍登记**。本批按审计 §4 成本序挂上 **6 档**（`run.sh` 挂点 + `ci_hook_allowlist.txt` 同步删条目，**覆盖判据 `test_ci_hook_coverage.py` 全程绿**：`scope=66 hooked=45 allowlisted=21`）：
  - **低**：`test_ent_kernel_neutrality.py`（纯 python，实测 **0.05s**）→ `bootstrap-tests`；`test_slice_bounds.py`（**1.4s**，7/7）→ `selfhost-tests`；
  - **中**：`test_hit_table.py`（**2.3s**，24/24）· `test_region_cfg.py`（**0.9s**，22/22）· `test_live_ranges.py`（**1.4s**，13/13）→ `selfhost-tests`；
  - **高（allowlist 自标「最高危」）**：`test_backend_bootstrap.py` = **N06 唯一门**，**先实测时长（22.5s）后判定可挂** → `selfhost-tests`（挂点理由原文见该行注）。
  - **仍不挂**：`test_mw_task1-6`（**口径换代**：零 diff 腿基线须在改动前编译器上产 ⇒ CI 参照物结构性不可得；机器化需「基线入仓」取裁或改「结构断言 + 语义零变化」口径）· `test_lsp`（进程级，未实测）· 其余历史缺口档。
  - **副产品**：本批新增 `tests/harness/test_criteria_mutations.py`（突变自证 22/22，纯 python）并同批挂 `bootstrap-tests`。

### 90. ⚠ **【判据强度】零 diff 腿的 E8 盲窗：`0xE8` 后 4 字节永不比较**（2026-09-16 判据强度审计 **B1**——**弱判据，本批不修**；审计危害序 **②**）
- **现象（`tests/selfhost/test_mw_task2.py:164`）**：main 区指令流逐字节比对（「untagged 快路径字节不变」零 diff 腿）中有 `if a[i] == 0xE8: i = i + 5  # call rel32` ⇒ **任一 `0xE8` 字节**（含 disp8 = −24 等极常见值）之后 **4 个字节永不比较** = **盲窗**。
- **最小坏实现（能骗过它却真坏）**：把恰落该窗内的立即数/位移常量改掉（帧常数低 4 字节位于某 `0xE8` 之后）⇒ **判据绿、退出码不变**。
- **兜底**：**无**（该腿是「untagged 快路径字节不变」的**唯一**证据）。静默 SKIP 那半**已于 05:58 改 fail-closed**（`--allow-skip` 显式才降级，缺基线默认 FAIL）；**仍未挂 CI**（`tests/harness/ci_hook_allowlist.txt:31`：零 diff 腿的基线须在**改动前**编译器上产 ⇒ CI 参照物结构性不可得，属口径换代）。
- **建议修法（判据侧）**：把「跳 E8」改为**按指令长度表跳**（rel32 段仍参与比较），或对 E8 后的 4 字节做**独立断言**（该窗内落有帧常数时）。
- **状态**：**已修（2026-09-16 判据网加固批 T2；取审计建议的「按指令长度表跳」路）**。新判据形态 = `test_mw_task2.py`：① `x86_insn_len`/`x86_walk` = **判据侧独立 x86-64 长度解码器**（不复用发射器代码；**fail-closed**——未登记形态 ⇒ 判红，绝不静默跳过）；② `region_equal_mask_calls` 改**指令边界锁步**：两侧边界序列必须逐条一致（布局变了直接红），**非 call 指令全字节比较**，call 仅放行 4B rel32（opcode `E8` 本身仍比），且两侧调用目标各自断言落在本 text 内。**盲窗闭合证明**：旧实现「遇 0xE8 即跳 5B」在 `48 C7 45 E8 …`（disp8 = 0xE8 是**数据字节**）后吞掉 4B 立即数——突变自证里同一坏输入 **旧形态绿 / 新形态红**（`tests/harness/test_criteria_mutations.py` M5）。**证据**：z1/z2/z3 × O0/O1/O2 真实二进制 9/9 PASS（豁免面计数 1/1/2 = §0bis 探针触发自证，=0 判红）；对 **2026-09-07 老编译器基线**跨版本对拍亦 9/9 PASS；解码器与 `objdump --insn-width=16` 对拍 17 个真实 region（含 t3 的 3272 条指令）逐指令边界一致。**仍未挂 CI**（零 diff 腿基线须在改动前编译器上产 ⇒ 参照物结构性不可得，属口径换代——见 `tests/harness/ci_hook_allowlist.txt`）。

### 91. ⚠ **【高危·预存】可选 dex（`dex?`）整族：形式转换 × 可选表示的交集面全未覆盖**（2026-09-16 apx 批 T3 前置探针实测——**现状本就错、非本批引入**，无阻塞关系）

- **实测证据（显式 apx 形 + 精确形对照，ELF 运行期读数）**：
  - `u11`：`d : dex, apx = 7.0; x : dex? = d;` + `match x { Some(v) => { return @raw_int(v) / 1000000; } None => { return 0; } };` ⇒ **ELF 15 / interp 15**（**双路径同错**，期望 7）；
  - `u11b`（精确形对照）：`d : dex = 7.0;` 同形 ⇒ **ELF 7 / interp 7**（绿）⇒ 对照成立，缺陷是 apx 形特有。
  - 15 = `4619567317775286272 / 10⁶` 的低 8 位（bits 原样入槽 + 读点定型 `TI_INT` + `@raw_int` 无转换的同一条数值自洽链，与 apx 批 T1 一致）。
- **根因坐标（读码）**：`dex_store_adjust` 的触发门是 **`declared_ti == TI_DEX`**（`src/compiler/ir_gen.cr:2389-2393` 与 `:2423-2424`）；而 `dex?` 的 `declared_ti` = **`TYP_OPTIONAL` 类型索引**（≠ `TI_DEX` = 1）⇒ **可选 dex 的 LET/赋值写点整段跳过形式转换**；随后装箱路径（`emit_box_some` `ir_gen.cr:463`，以及 `:2332` match 裸分支 / `:2348` 结果写）把 **bits 原样**塞进载荷槽 ⇒ 读回按 scaled 解释 ⇒ 静默错值。
- **性质声明**：这是**一条独立正交轴**（形式转换面 × 可选表示 `rep` 面的**交集**），**非「某个写点漏接线」类**；判据网须覆盖 **四态：裸 / 装箱 × bits / scaled**。
- **判据要求（修复时）**：① 上列 **四态全覆盖**（每态有精确值断言，不得只测一态）；② **与 (A) 批 INV-1（取址槽恒持装箱值）交叉核对**——两个面在 `dex?` 上**真有交点**，修时必须一起看（`&x` 取址 + `dex?` + apx 形三者组合）；③ **零足迹哨兵按「显式归因 + 同批重锁 + 旧值留痕」纪律换代**（见下）。
- **零足迹哨兵（⚠ 刺眼标注，防误抄）**：apx 批 T5 套件把 **`u11` 现状值 15/15 钉成哨兵**。**该值 15 不是期望语义，只是零足迹绊线**——作用 = 若 apx 批的漏斗实现**意外**改动了 `dex?` 行为，当场变红。**谁修本条谁负责改它**：修复落地时它**必然变值**，须按 canary 那套「**显式归因 + 同批重锁 + 旧值留痕**」处理，**不得**把 15 当「正确基线」抄走。
- **状态**：**登记，未修**（apx 批 T3 前置探针实测；批内四表已列「本批不做、归 #91」行）。**关联**：apx 批计划 `docs/superpowers/plans/2026-09-16-apx-conversion-fix.md` §7quater + §7ter · 审计 errata **E6** · (A) 批裁-REP-1 (iii) · 容量批 T2 存储边界规范化。

### 92. **apx 字面量的十进制值不精确（lexer 位模式 ~2ulp 截断）⇒ 「同十进制值」在 binary64 下可不相等**（2026-09-16 apx 批 T3 实测——**预存语义，登记备查**）

- **现象（实测，apx 批 T3）**：`d : dex, apx = 1.5;` 与 `s : ., mut = S3 { f = 1.5 };`（`struct S3 { f: dex }`）取同十进制值 1.5，但 `d == s.f` 在 binary64 下**为假**（`b8` 原探针实测 ELF=0，曾误以为「应相等」）。**等价最小形**：`d : dex, apx = 1.5; if d == 1.5 { … }`。
- **根因（`file:line`）**：apx 槽的**字面量**路径走 `dex_scaled_to_bits`（`src/compiler/ir_gen.cr:1016-1022`）——对 `EXPR_DEX` 节点**直接重发射 lexer 存的 binary64 位模式**（`ast_a(node)`），而该位模式由 `str_to_f64_bits` 按 **~2ulp 截断**（`src/compiler/lexer.cr:461` 注释；`tests/selfhost/test_dex_arith.py` 头注亦文档化）；而聚合槽里的 1.5 经 scaled（1500000）是**精确** 1.5。⇒ 二者在 binary64 下差 ~2ulp ⇒ `==` 假。
- **性质**：**预存语义（文档化），非缺陷、非本批引入**。apx 的契约即「精确，或经授权的近似」——字面量转 binary64 时接受 ~2ulp 近似。
- **判据（写 dex/apx 探针时必读）**：
  1. **不得**用「同十进制字面量」做 apx 面的相等断言（会假红）——用 `@raw_int` 锚定 scaled 整数，或两侧都经同一转换路径；
  2. 需要 apx 面精确相等的场合，改用**经精确→apx 转换**（I2F/S）产生的值，或改用 `dex?` 以外的精确形式比较；
  3. 反例驱动自检问句（照判据强度审计 §0）：「**什么坏实现能骗过这条断言？**」——本条的教训是反向的：**断言本身是对的，是期望值错了**（与「探针不触发」同族的假红面，见判据强度审计 §0bis 的姊妹形态）。
- **状态**：**登记，备查**（apx 批 T3 实测 + 归因）。**关联**：apx 批计划 §7quinquies (3) · `tests/selfhost/test_dex_arith.py` 头注「±2ulp 字面量误差下依然鲁棒」· 本批 T5 套件已用 `@raw_int` 锚定（不踩本条）。

### 93. ⚠⚠ **【根因级·预存】已解析直调的实参推断缺失**（139 只是其表现之一；**静默通过面见下**）——2026-09-16 apx 批 T5 实测 + 同日**只读根因侦查**（原题「模块限定调用直接作实参 ⇒ SIGSEGV 139」是**表象**，真面目是实参**从不被推断**）

- **最小复现**：`import fmt\nfn main() -> int { if !str_eq(fmt.int_str(7), "7") { return 3; } return 0; }` ⇒ **产物 rc=139**（期望 0）。**与 dex/apx 无关**（本形纯 int/字符串面）。
- **对照（定性关键）**：**绑定到变量后正常**——`x := fmt.int_str(7); if !str_eq(x, "7") { … }` ⇒ **rc=0** ⇒ 触发条件是「**模块限定调用（`m.f(x)`）直接作实参**」，不是模块调用本身。
- **同族对照**：非模块的嵌套调用作实参**正常**（`str_eq(dex_str(7.0), "7")` ⇒ rc=0；`eqi(inc(6), 7)` ⇒ rc=0）⇒ 差异在**模块限定形态**的实参求值/打包路径。
- **归因（**已排除本批**，证据三条）**：同一探针在 **T3 二进制 / 预变更二进制 / 冻结基线 `97f4394f`** 三者下**同为 139** ⇒ 缺陷在 pinned rev 之前既已存在。
- **影响面（实测一处）**：一切「模块限定调用直接当实参」的写法（`io.println(fmt.int_str(n))` 形同理）。
- **判据（修复时）**：上列最小复现 **rc=0**；对照形（绑定）保持 rc=0；且 `.ccr`/canary 不变（与本批同纪律）。
- **状态**：**登记，未修**（原属 apx 批范围外——本批面 = dex 形式转换；本条目**零 dex**）。**批次位置**：维护者建议插在既有第 3 批位置（普通代码崩溃 + 静默通过面），**待用户定**。**关联**：apx 批计划 §7quinquies 遗留 · `tests/suite/apx_conversion_test.cr` 的 §2 注释（该档已绕开此形）。

#### 【2026-09-16 只读根因侦查】根因 = **实参推断缺失**（原题为表象）

- **根因（`file:line`）**：`src/compiler/checker.cr` 的 `infer_expr` EXPR_CALL 直调分支在**被调解析成已注册 Core `fn`** 时**提前 `return sym_type(si)`（`:2817`）**；而「推实参（for side effects）」循环在**函数尾 `:2833-2839`** ⇒ 该循环**只在 `func_ni < 0` 时可达** ⇒ **对任何有名被调都是死码** ⇒ **实参表达式从不被推断**。
- **139 的产生链**：实参位的内层调用若是 **`EXPR_FIELD` 被调**（方法 / 模块限定），其 `ast_data`（被调名索引）**只能由 checker 的模块/方法分支回填**（`:2584`/`:2645`）——该分支从没跑 ⇒ 保持 parser 初值 **0** ⇒ `ir_gen` 读出 `istr_get(0)` = 文件**首个 interned 串**（有 `import` 时恰为 `"import"`）⇒ 后端查不到 ⇒ 外部位重定位 ⇒ **SIGSEGV 139**。
- **第二种表现（更危险）= 静默通过**：实参里的**未定义函数**（`g(nosuchfn(1))`）**`check` rc=0、零诊断**（运行时亦 139）。**响亮失败至少有人看得见，静默通过不响** ⇒ **本条目的正确批名 = 「实参推断缺失」，不是「修 139」**；只修 139 会漏掉这一类。
- **可达性边界（实测矩阵，同形单变量）**：崩 = **内层 `EXPR_FIELD` 被调** ∧ **外层已解析 Core `fn` 直调**。外层若是**模块限定 / 方法调用**（`checker.cr:2623` 有推实参）或 **extern / 未解析** ⇒ 安全。
  | 内层形态 \ 外层形态 | 已解析直调 | 模块限定调用 | 方法调用 | extern/未解析 |
  |---|---|---|---|---|
  | 模块限定 `m.f(x)` | **139** | 绿 | — | 绿 |
  | 方法调用 `s.m(x)` | **139** | — | 绿 | — |
  | 直调 `f(x)` | 绿 | 绿 | 绿 | 绿 |
  | 泛型实例化 | 绿 | — | — | — |
- **日常形（**反直觉**）**：`println(fmt.int_str(7))` **绿**（外层 stdlib I/O 走 extern/未解析 ⇒ 推实参）；而**包一层自己的 helper**（`show(p.get())` / `log2(fmt.int_str(7))`）⇒ **139**。
- **非本批引入（三方差分）**：apx 批改动前 / apx 批 T3 当前 / **冻结基线 `97f4394f`** 三者同崩同名（`.cir` 内层名 = `import`）⇒ **既有**。apx 批**未改 checker**，其环门读 `find_func(0) = -1` ⇒ 环不进（与改前同行为、不掩盖）。
- **同族历史**：这正是 **I-3**（2026-08-29「模块限定调用生成对伪函数 `"import"` 的调用」）在 **bootstrap** 侧修过的**同族缺陷**（bootstrap 保留导入元数据并按 alias 解析）——**selfhost 侧从未修此面**。
- **修法候选（**不实施，待裁**）**：**(a) 补实参推断（根因，推荐主体）**——把 `:2833-2839` 抽成小函数，在所有「已解析」return 点（含 `:2817`）之前调用；**风险 = 行为放大**（实参一旦被推断，此前静默形态开始出诊断 ⇒ 现有语料 `check` 可能由绿转红）⇒ **必须腿① 全语料逐档对拍 + 每条新诊断逐条归因**（**不许把新增诊断一律当「修好的证据」**；归因不清 ⇒ 停下上报）。**(b) fail-closed 护栏（兜底，建议同批）**——`ir_gen` 处 callee 是 `EXPR_FIELD` 且 `ast_data <= 0` ⇒ 硬错 + 拒绝产物（只把静默 139 变响亮，不修根因）。**(c) parser 预回填名字（退路，前提未实证）**——治标（静默面仍在）。
- **判据网（**两条腿都要**）**：**腿 A（响亮面）**= 139 → 期望值（9 例）；**腿 B（静默面）**= `g(nosuchfn(1))` 由「零诊断」→ **`error[N06]`**（**这一条是「修好了」的正据**，缺了它本批只修了一半）。
- **入仓 RED 语料**：`tests/selfhost/test_arg_inference_gap.py`（**19 例** = 腿A 9 + 腿B 1 + 对照 9；**未挂 CI**，白名单有条目；**修复批次须同时**删条目 + 挂 `run.sh` + 改头注）。**侦查全文**：`docs/superpowers/specs/2026-09-16-arg-inference-gap.md`（含观测矩阵 §5、未决项 U1–U4）。

### 94. **【判据·口径换代】零 diff 腿的基线「须由改动前编译器产出」⇒ CI 参照物结构性不可得**（2026-09-16 判据网加固批登记；**取裁留给后续批**）
- **编号说明（时序）**：本条目由判据网加固批记于 `feature/criteria-harden`（基点 develop `f7798197`）；编号按**实读 develop 现状**（该树最大 = #93）顺延取 **#94/#95**。**⚠ 若并入时 develop 已占 #94+，按实际顺延重编号**（内容与结论不变）。
- **现象（机制）**：`tests/selfhost/test_mw_task{1..6}.py` 的零 diff 腿判据 = 「当前二进制 × 源」与**基线产物**逐字节比；而基线**必须在「改动前」的编译器上产**（`--snapshot`）。CI/新克隆永远只有改动后的树 ⇒ **参照物结构性不可得**：挂上去只有两种死法——恒 FAIL（无基线）或被迫 `--allow-skip`（= 挂了等于没挂，正是 A5 修复要消灭的静默形态）。⇒ 这不是「挂点扩容」，是**判据口径换代**（审计 §4 结构性发现 3 的原话）。
- **两个候选方向**（本条目只登记 + 推荐，**不实施**）：
  - **(A) 基线入仓**：把基线产物（`build/mw_task2_zdiff/*.bin` 一类）提交进仓库，判据 = 与入仓基线逐字节比。**代价**：① 二进制入库（与现行「二进制不入库」纪律冲突，须维护者取裁）；② 基线随编译器代际失效 ⇒ 需要**换代纪律**（同 `canary_values.tsv` 的「显式归因 + 重锁 + 旧值留痕」两级契约）；③ 入库后每次正当的发射面变更都要重锁基线。
  - **(B) 结构断言口径**：不比字节，改断言**结构性不变量**——块间连续（块长公式）· 回跳目标落在真指令边界 · 各站点 alloc 目标唯一 · 模板字节逐指令钉死（除了站点相关字段）· 指令边界序列两侧一致。**零 diff 的语义**从「与历史字节全等」改为「**不变量成立 + 与当前同源二跑一致**」。
- **推荐 (B)**：**本批 #85 的慢路径块体判据正是该方向的现成先例**（`test_mw_task2.py::parse_slow_block`：整块逐指令模板 + 块间连续 + tag 立即数硬判 + 回跳落边界 + alloc 目标唯一，**已在 t1/t2/t3 250 站点 + 新例 t4 上真跑**），且不引入二进制入库。执行时须逐条回答「**换成结构断言后，哪些坏实现不再被抓？**」（审计 §0 反例问句），未被覆盖的面显式登记。
- **状态**：**登记，未实施**（本批已在 allowlist 与批报告 §6 留指针；`test_mw_task1-6` 仍**不挂** CI，直到口径定案）。

### 95. **【判据·静默分歧】腿① 暖广度腿 2/73 档 stats 差异（已归因，但归因未入仓）**（2026-09-16 判据网加固批登记）
- **编号说明**：同 #94（本批取 #95；并入时若冲突按实际顺延）。
- **现象（实测）**：`tools/baseline/parity_run.sh` 的**暖广度腿**（`warm_leg.sh` → `warm/stats.tsv`）在「冻结基线 × 当前源」与「当前二进制 × 当前源」之间有 **2/73 档**差异（**冷态 `check` 面 73 档日志 + `parity.out` 为 `diff -rq` 空 = 零差异**，即腿① 主判据不受影响）：
  - `tests/suite/at_test_mini.cr`：**build 面 rc 0→1**，`.cir` 条目 **17→0**，两态诊断均为 `[error[N06]]`；
  - `tests/suite/global_seam_test.cr`：条目 **16→15**（rc 两态均 0）。
- **归因证据**：
  1. **跨批 delta**：差异两侧都是**当前源**，只有二进制不同（冻结基线 `PINNED 97f4394f`〔P6 终态〕vs 本基点 `f7798197`）⇒ 差异 = **PINNED → 本基点之间各批**的累积行为变更，**与本登记批无关**（该批 `jj diff` 零编译器输入改动）。
  2. `at_test_mini.cr` 的 N06 **build 面阻断** = **fail-closed 批裁-FC-1(A) 的显式登记变更**（「同机制、显式登记差异、check 基线零扰动」——`docs/superpowers/plans/2026-09-15-fail-closed-diagnostics.md:117`；该批计划同时记载 N06 在 **check 面**豁免，见其表 0 行 20）。
  3. `global_seam_test.cr` 条目 16→15：随全局 operand seam 批（该语料 = 该批新增）编译器侧改动而来的 `.cir` 条目数变化。
- **为什么值得登记**：差异**已被归因**，但归因此前只存在于批次对话/台账里，**没有入仓**——这正是「静默分歧」家族（值变了、有人知道、但没有可追溯的落纸）。登记后：任何人重跑暖广度腿看到这 2 档差异，都能在此找到归因与出处，不必重新侦查。
- **状态**：**预存差异，已归因，非本批**（判据网加固批 2026-09-16 实测）。**待办（可选）**：若后续批次要重锁该腿期望值，须按换代纪律（旧值 + 新值 + 归因 + 出处）执行。

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
见 `docs/maintainer/design/pointer-model.md`。裸指针 + HDFG provenance 推导，编译器自动验证，退路 `unsafe`。
三 pass：PointerAnalysis、RegionCheck、ProvenanceVerify — 全部实现。

### Arena 内存模型
见 `docs/maintainer/design/memory-model.md`。已完整实现。堆按 HDFG 子图划分独立 Arena，指针碰撞分配，
游标重置回收。Arena 边界对应 HDFG 子图边界。

### 文档更新
- `docs/maintainer/design/memory-model.md` — 设计文档（待同步实现细节）
- **docs 重组合并时的连带改点（2026-09-11 登记，`feature/docs-reorg` 已推送 `9eab0757` 待合）**：该分支把 `docs/developer/errors.md` → `docs/developer/errors.md`、`docs/archive/compcert-reference.md` → `docs/archive/compcert-reference.md`，故**合并该分支时必须同步两处 src 注释**：`src/compiler/ast.cr:315`、`src/compiler/ptr_analysis.cr:235`（在本线/当前 develop 上这两个路径**仍然正确**，故不在 docs 分支内改——避免把 src/ 拉进 docs 分支，也避免在本线留下悬空引用）。
- `docs/maintainer/design/pointer-model.md` — 指针安全完整设计
- `docs/developer/syntax.md` — 指针、@ 内建语法已更新
- `docs/developer/at-intrinsics.md` — @ 内建原语完整规格

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
- **概率性 pass**（probabilistic-pass，2026-07-30 已批准）：src/ 零实现，仅文档（`docs/maintainer/proposals/probabilistic.md`）——范式相关，优先级低，待排期
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
- **退役（2026-09-05）**：独立 .crasm 格式取消——绑定经典硬件过深（寄存器/寻址/ISA 助记符/私有平台映射表），被**硬件接口表（HIT）**吸收：跨平台 = HIT 事件 + 投影表；MMIO/特权/中断 = `.cr` unsafe + HIT extern 接口事件；事件可读形态 = v6 NOD 文本 dump。正式声明 = `docs/maintainer/design/crasm.md` 状态行（已废弃，保留为历史记录）；依赖解除引用见本文件「硬件映射表」与「宽度类型移出语言」两条。**原里程碑方向全部作废（保留下文备查），无实施计划。**
- （历史）目标：内核路线（project-book 第五阶段）的汇编级能力——MMIO、特权指令、中断。跨平台统一指令集 + 无限虚拟寄存器 + 平台映射表，寄存器分配按 v4 方向（缓存语义映射实例，`docs/regalloc-cache-mapping.md`——无限虚拟寄存器 + 平台映射表正是映射实例形态；现 `alloc_registers` 线性扫描器为升级起点）
- （历史）现状：设计已批准（2026-08-08 brainstorming 逐节确认），2026-08-09 整理为正式文档 `docs/maintainer/design/crasm.md`；实现从未落地（lexer/parser 无 asm 语法）——2026-09-05 整体退役
- ~~方向（按里程碑顺序）：~~
  - ~~1. `.crasm` 词法/解析（结构化指令 → AST 复用）~~
  - ~~2. 寄存器生命周期 pass + 测试（未初始化读/重复写/生命周期逃逸/宽度一致/分支一致性）~~
  - ~~3. 特权约束表 + 用法验证 + unsafe 隔离~~
  - ~~4. x86-64 映射表（翻译器）+ 字节级测试~~
  - ~~5. .cr extern 接口接线 + 端到端~~
  - ~~6. （后补）ARM64/RISC-V 映射表~~
- 明确不做（YAGNI，退役前定案保留）：模拟器/调试器、C 生态兼容、指令级时序验证、特权副作用验证（隔离，人工保证）
- 参考：`docs/maintainer/design/crasm.md`（**已废弃 2026-09-05**）、`docs/superpowers/specs/2026-08-08-crasm-design.md`（批准记录，历史）

### 对照 CompCert 审查发现的未修复 bug（2026-08-11 记，详见 docs/archive/compcert-reference.md）

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
- **`corec run` 不能执行 apx dex 算术（既有能力边界，非缺陷——响亮）**：`IR_I2F/IR_F2I` 遇 apx 路径时解释器显式报错 `interpreter error: IR_I2F/IR_F2I needs binary64 semantics (apx dex) — corec run cannot execute apx dex arithmetic; build & run natively (corec build) instead` 并 rc=255（2026-09-16 全局 operand seam 批 T1 实测复核；与上文「深度守卫超限 interp rc=255」同码不同因）。**影响**：凡 apx 算术探针（`dex, apx` 变量参与运算/转换）**无解释器腿** ⇒ 该面判据只能用「**同形局部 vs 全局 ELF 对拍**」或改写成 scaled 形态（能用 interp 腿）——写 dex/apx 探针前先确认这一条，别把 255 当错值信号。
- **模块级全局的常量折叠陷阱（探针设计）**：`find_global_const_node`（`ir_gen.cr:592-611`，要求 `ast_data(node) == 0` = **非 mut**，接受 `EXPR_INT/EXPR_BOOL/EXPR_DEX`）把「**不可变 + 字面量初值**」的全局折叠成 `IR_CONST` ⇒ **读点根本不碰全局行**。凡针对「全局行寻址/读取」的探针**必须用 `mut` 全局**（否则探针不触达被测面、假绿；2026-09-16 全局 operand seam 批 T1 第一轮即栽在此处，见该批计划 §N-4）。
