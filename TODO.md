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

### 5. cir cache 跨编译器重建不失效（2026-09-10 内核抽取 Task 3 评审确认——预存,待修）
- **现象**：`.core/cache/cir` 以「源路径::函数名」为键缓存每函数 CIR 快照；缓存命中时旧条目跨编译器重建存活 → 复用的 CIR 与新版字符串表（g_strs 驻留序）错位 → dump 通道（如 corearch --dump-entries）输出部分变量名缺失/错位——实证：806→381 个 `name=` 的翻转（Task 3 验证中复现，同源重建即触发，与具体代码改动无关）
- **机制**：指纹 = magic/格式版本/完整解析源 AST，无编译器身份分量；源未变则键/指纹不变 → 二进制重建后字符串驻留序漂移不反映到键上 → 陈旧条目静默污染 dump-channel var 名输出
- **证据**：内核抽取 Task 3 评审 concern ①（.superpowers/sdd/kernel-task-3-report.md）——Task 3 diff 仅 corearch + 注释，base↔head corec cmp 相同；清 .core/cache 后逐字节复现判据成立（计划 Global Constraints 的「清 cache 跑测试」即为规避）
- **修复方向**：cir_cache.cr 缓存键 += 编译器指纹（产物内容哈希或编译器身份分量）——重建后旧条目自动失效；现状兜底 = CIR_CACHE_VER 手工 bump + 测试前清 cache

### 6. 双入口能力分歧：ld project-mode 后端缺 HIT/表旗标（2026-09-10 ld 导入集修复评审确认——预存,待修）
- **现象**：`src/arch/linux/ld/main.cr` 的 corearch_main 只注册 **6** 个旗标（elf/shared/static/link/output/opt-level，:31-36；评审修正——原文计数 7 误），而 `src/compiler/corearch.cr` 的 corearch_main 同段注册其全部超集（:260-273）：`--table` / `--hit-events-file` / `--dump-events` / `--dump-table` 与全族 `--dump-entries`/`--dump-coexist`/`--dump-regassign`/`--check-regalloc`/`--inject-*`/`--dump-objects` 调试通道。ld/main.cr 全文零处引用 `table`/`instance_decl_init`/`instance_select`/`g_active_instance`/`g_hit_table`——即 ld project-mode 构建出的后端（`corec build src/arch/linux/ld`，test_backend_bootstrap 的 stage1/2/3 即此产物）**HIT lowering 层与表编码器已编译在内但惰性**（评审修正——原文「整体不含 HIT/表机制」过度表述；精确缺面 = CLI/分派接线：旗标注册 + 实例声明引导 + 表装载），`:15`「两入口行为同构」括注对表模式为假。
- **实证**：`./build/corearch --dump-table` → 正常解析（打印 usage）；ld project-mode 产物 `--dump-table` / `--table` → `unknown flag: --dump-table` / `unknown flag: --table`（cli_parse 拒绝，非 usage 兜底）。故 `src/arch/linux/ld/main.cr` 头注「入口二元性…两入口…（现 load 后行为同构）」（:11-15）对表模式（及全部调试通道）**为假**——同构仅限 ELF 发射主路径。
- **机制**：入口二元性（concat 入口 = src/compiler/corearch.cr wrapper；project-mode 入口 = ld/main.cr）靠人工双份维护 corearch_main——旗标注册与 load 后接线分散两处，无共享注册函数、无一致性守卫；《内核完备》抽取后 src/compiler/corearch.cr 单侧长表模式（M2 系列），ld/main.cr 未同步。
- **影响**：ld 自举 stage 链（及任何经 ld 工程构建的后端）无法经 --table 走表投影路径——表模式回归只在 concat corearch 面被覆盖；`--hit-events-file` 注入测试通道对 ld 产物同样缺席。当前无测试经此入口断言表模式，故静默。
- **证据**：本次 ld 导入集修复（N06/N01 静默未定义闭合）评审 trace —— .superpowers/sdd/lattice-move-report.md 与本文 #6 挂账；同类先例 = c138c44c（init 单元缺 import → 静默未定义 + SIGSEGV，N06 类静默失败反复出现于「入口/单元维护面不同步」）。
- **修复方向**：①旗标注册收敛——两入口共调一个 `register_backend_flags()`（或 ld/main.cr 直接复用 corearch.cr 的注册段），保留双 wrapper 前提下的单份真源；②或显式 documented divergence 留档——ld/main.cr 头注改为「表模式/调试通道仅 concat 入口支持」并加守卫（如 ld 产物遇 --table 报明确「此入口不支持表模式」而非 unknown flag）。①优先（同构主张才是原本设计意图）。**③静默未定义类守卫（2026-09-10 修复评审残留建议）**：project-mode 构建（`corec build src/arch/linux/ld` 等单元）的 `error[` 计数无任何自动断言——N06 类静默失败在 rc=0 + 产物正常 + 全部互测 byte-identical 的情况下完全不可见（pre-fix 状态即如此通过全套）；建议加「build log error 计数非零 = 失败」的构建/测试门（或 tools/diagnose.py 类收集纳入套件）。
- **注意**：修①会改 ld project-mode 单元内容 → stage 链产物字节变（expected，非缺陷）；须同步跑 test_backend_bootstrap 判据（stage1==stage2==stage3 全程同源，仍成立）。

### 7. 死文件 `src/compiler/elf.cr`（566 行，零 importer，不入任何清单）——符号遮蔽/归属误导（2026-09-10 x86 实例化波 1 Task 1 评审登记）
- **现象**：`src/compiler/elf.cr` 无任何 importer、不入任何 concat 清单（build_selfhost_native.py / Core.toml / _import.cr 三面皆无），但以**同名符号**与活文件碰撞：`w8/w16/w32/w64`（= src/compiler/dyn_arr.cr 的字节写函数）与 `elf_write_code/elf_begin/elf_finish/parse_line/encode_instr/measure_instr/asm_to_bytes/skip_dir/is_label_line/align_up/ElfCtx/LineInfo/g_asm_code_size`（= src/format/elf/elf.cr 的原实现面）。
- **机制/隐患**：`module.cr` 回退链序当前**恰好**保护它——三轴目录（`src/format/elf` 等）置于 `src/compiler/` **之前**（module.cr:544-553 注释明言：否则本文件遮蔽 `src/format/elf/elf.cr` → 目标单元解析漂移 → elf_gen 等 N06 静默未定义）。但这是**顺序依赖**而非结构保证：任何回退链重排或新增目录（波 1 Task 2-6 正在改 import 集与命中面）都可能翻转命中，而翻转后果 = `error[` 静默未定义类故障（先例见 #6 ③ / c138c44c）。
- **实证**：波 1 Task 1 评审（.superpowers/sdd/w1-task-1-report.md §2.1、§6.1）+ module.cr:548-553 注释推理；全仓 grep 唯一引用 = 自身 + `docs/pseudocode/`（生成产物）——`tools/pseudocode_extract.py` ROOTS 含 `src/compiler` 整目录 glob，仍从该死文件抽取 ELF 写侧符号 → `docs/pseudocode/标识符对照表.md` **20 行**归属误导（与 `src/format/elf/elf.cr` 双源并存，无法分辨活面）。
- **修复方向**：**删除**（首选——零 importer、零功能贡献；删除需用户明确许可，铁律 #3）并重生成伪代码对照表；备选 = 迁出活树（`legacy/` 等，避开 ROOTS glob）保留历史。删除后复跑 test_backend_bootstrap + full-bootstrap guard（预期零影响、byte-identical）。

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
- **宽度类型移出语言**（width-out-of-language，2026-08-30 定案）：设计决定——int 无上限为默认（已定）；宽度（i64/u32/w32 等）不进入语言类型/标签体系，避免第二标签范式（单标签单范式原则）；机器形状全部归 hw-map/硬件接口表（`docs/superpowers/specs/2026-08-23-hw-map-design.md` 设备层 + `specs/2026-09-05-hardware-interface-table.md` 指令/运行层；crasm 退役后链式阻塞解除）；apx 保持单一语义 = 精度降级开关，不扩张为宽度标签。三层映射对应：图/格 = 纯数学，编码 = hw-map 领域。语言侧清理（不阻塞，可立即做）：ast.cr `T_INT_I8..T_INT_U64` / `T_FLOAT_F32/F64` 死条目移除（勿重编号）、`_f32/_f64` 后缀死路径处理、`1_000` 两编译器分歧复核；v6 规格影响：编码层宽度由目标自动决定，hw-map 为未来显式控制通道（v6 格式规格先行更新）
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
- **自动记忆化**（auto-memo，2026-08-30）：图显式纯度判定（无副作用边）→ 多次使用的纯节点自动缓存结果。与自动惰性同机制（惰性 = 延迟执行，memo = 缓存结果），可共用判定/下沉基础设施
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

### .crasm 统一汇编抽象层（2026-08-09 记）
- 目标：内核路线（project-book 第五阶段）的汇编级能力——MMIO、特权指令、中断。跨平台统一指令集 + 无限虚拟寄存器 + 平台映射表，寄存器分配按 v4 方向（缓存语义映射实例，`docs/regalloc-cache-mapping.md`——无限虚拟寄存器 + 平台映射表正是映射实例形态；现 `alloc_registers` 线性扫描器为升级起点）
- 现状：设计已批准（2026-08-08 brainstorming 逐节确认），2026-08-09 整理为正式文档 `docs/crasm.md`；**尚未实现**——lexer/parser 无 asm 语法，汇编仅存在于 rt.s 手工汇编与 ELF 后端机器码发射
- 方向（按里程碑顺序）：
  1. `.crasm` 词法/解析（结构化指令 → AST 复用）
  2. 寄存器生命周期 pass + 测试（未初始化读/重复写/生命周期逃逸/宽度一致/分支一致性）
  3. 特权约束表 + 用法验证 + unsafe 隔离
  4. x86-64 映射表（翻译器）+ 字节级测试
  5. .cr extern 接口接线 + 端到端
  6. （后补）ARM64/RISC-V 映射表
- 明确不做（YAGNI）：模拟器/调试器、C 生态兼容、指令级时序验证、特权副作用验证（隔离，人工保证）
- 参考：`docs/crasm.md`（正式文档）、`docs/superpowers/specs/2026-08-08-crasm-design.md`（批准记录）

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
