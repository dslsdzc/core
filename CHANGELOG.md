# 更新日志

> 说明：本文档记录里程碑级变更。近期每日开发流水、预存 bug 与架构规划以 `TODO.md` 为准。
> 2026-06-21 至 2026-07-23 之间曾存在文档缺失期，以下条目按提交历史与 TODO.md 补齐。

## 2026-09-17
### [change] `@no_bounds_check` 更名为 `@NoBoundsCheck`
- 维护者 2026-09-17 指示的重命名。**干净重命名，不留别名**：旧名 `@no_bounds_check` 从此**不是内建**——
  必须**响亮失败**（`error[N01] unknown @ builtin`：rc=1 + 文件:行:列定位 + 零产物），**不得静默接受**。
- 名分派四处同步：`src/compiler/checker.cr`（EXPR_AT 名分派）· `src/compiler/ir_gen.cr`（注解发射）·
  `src/compiler/dataflow.cr`（`.cir` 显示名）· `src/lsp/analysis.cr`（`@` 补全表）。语料/探针同步：
  `tests/suite/at_test.cr` · `tests/suite/at_test_mini7.cr` · `tests/probes/p_annots{,2}.cr`（+ 探针 README 表）。
- **IR 操作码常量 `IR_NO_BOUNDS_CHECK(35)` 不变**（内部标识、非语言面名字；改名 = 无谓 churn）。
  发射面零变化：改名前后的语料 ELF **逐字节同**（仅 `.ccr` 的 STR 段因源文本标识符驻留而变）。
- 回归判据 = `tests/selfhost/test_at_rename.py`（14 例，已挂 `selfhost-tests`）：旧名三面（build/check/run）
  响亮失败 + 新名两形态等价 + 两条入仓语料运行 + `.cir` 显示名（括号形态有行 / 语句形态零 IR = F4 语义保持）
  + 分派点四处同步守门 + 操作码 35 钉。

## 2026-07-31
### [feat] concurrency end-to-end — goroutine spawn, function address, result channels
- `go f(args)` 端到端打通：`sched_go(@addr(f), arg)` → g_new 存 saved_fn/saved_arg → ELF 后端内联发射 fiber_init/fiber_switch/goroutine_entry_wrapper → wrapper 调用 saved_fn(saved_arg) → 结果经 result_ch 回传。
- 函数地址支持：IR_FNADDR + `@addr` 内建（checker/ir_gen/ELF 后端全链路）。
- 并发集成：g_set_curg/g_get_curg 桥接 + M worker 线程池接线。
- 主线程注册为 G 0，可经 channel 阻塞/唤醒；sched_yield 不再重排 Gwaiting。
- 多 M 线程完整验证仍待补（见 TODO.md 预存 bug 第 2 条）。

## 2026-07-30
### [fix] restore directory builds
- Use the `Core.toml` project name for default ELF, CCR, and CIR outputs, with a safe directory-name fallback for unnamed projects.
- Reject missing project directories instead of silently compiling `main.cr` from the working directory.
- Resolve the static runtime relative to the running compiler when building outside the compiler source directory.
- Include the hotpatch runtime in clean self-hosted `corec` and `corearch` builds so `hp_load_config` resolves.
- Add native regressions for named, unnamed, and missing directory inputs.
### [fix] self-host bootstrap dependency & value-semantics fixes
- 自举依赖补全：bootstrap 构建纳入并发运行时依赖、共享 arena 全局和 fiber 声明。
- 增量缓存修复：缓存指纹纳入完整解析源，导入文件变化不再复用过期 `.cir`；快照改为内存组包后单次写入（完整自举不再产生数百万次微小系统调用）。
- 调用返回值修复：普通调用不再因局部 `dest` 遮蔽写入变量 0，实际返回类型传播到 IR。
- lazy 值传递修复：ELF 后端和解释器中的 thunk/force 保留已计算值及其类型。
- 原生字符串长度修复：整数局部变量不再误判为指针，`str_len("hello") == 5`、`str_len(@fields(Point)) == 3`。
- Python bootstrap 词法修复：`old` 不再被错误保留，可作为普通标识符。

## 2026-07-28
### [feat] arena memory model, @ builtins, incremental cache, hotpatch, pointer-model passes
- Arena 内存模型完整实现（`src/stdlib/arena.cr`）：init/new/reset 生命周期、动态元数据、free list、嵌套；IR 子图绑定（函数/loop/for/unsafe 自动 arena）；ELF 双路径 alloc（arena 感知 + 全局 bump 回退）；IR_ARENA_NEW(32)/IR_ARENA_RESET(33) 编码；mmap 堆扩展（BSS 打满自动 mmap 1GB）。
- `@` 内建原语 12 个全部完整：`@sizeOf/@alignOf/@fields/@hasField/@field/@typeInfo/@comptime/@inline/@no_bounds_check/@fast/@unroll/@section`（后增 `@addr`、`@hotpatch`，见 07-31/07-30）。
- 增量缓存（函数级 .cir，默认开启）：`cir_cache.cr` save/load 每函数快照，`clean-cache` 子命令。
- `@hotpatch` 滚动更新：IR_HOTPATCH_ROUTE(39) + parser `@hotpatch(ver=N)` + checker 多版本签名校验 + ELF 编码 + SIGHUP 信号处理。
- 指针模型三 pass 实现（PointerAnalysis/RegionCheck/ProvenanceVerify）：DEREF 后端 cmp+jae+ud2 边界检查（s3 编码 alloc_size）、运行时 prov_table 堆边界检查 patch、arena BSS 全局。

## 2026-07-27
### [fix] complete self-hosted corearch backend
- Remove out-of-range 2^31/2^32 literals from backend encoding and use signed-safe 32/64-bit byte writers.
- Fix signed CCR operand decoding so sentinel values remain negative across bootstrap stages.
- Include v3 optimization metadata in CCR size calculation and validate metadata bounds while loading.
- Give optimization metadata independent 64-byte slots with capacity tracking and copy-on-grow.
- Add a three-stage corearch bootstrap regression with byte-identical output, O0/O2 CCR loading, and native ELF execution.

## 2026-07-23
### [fix] complete P0 native aggregate and self-host regressions
- Fix disp32 emission to use the current instruction base for struct fields, constant array indices, enum tags, and enum construction.
- Fix REX/ModRM/SIB encoding for variable array index loads and stores.
- Add native ELF regression coverage for aggregate access at O0/O1.
- Verify clean corec -> corec2 -> corec3 bootstrap at O0 and O1.
- **corec2 自举阻塞解除**：corec2 --help、tokenizer/check 和 corec2→corec3 均正常；O0/O1 自举均成功。

## 2026-07-26
### [fix] global variable registration fixes
- `g_global_lets` 注册全局变量，不再扫描局部 EXPR_LET（修复全局变量丢失导致的静默赋值丢弃）。

## 2026-07-21
### [fix] local lets out of global IR
- 局部 EXPR_LET 不再泄漏到全局 IR（配合 07-26 的 g_global_lets 修复，消除全局/局部变量混淆）。

## 2026-07-09
### [fix] tokenizer parameterization + local-variable rewrite for self-hosted ELF compat
- tokenizer 参数化（`tokenize(_src: string)`），规避 `g_source` 全局变量依赖（PR #9）。
- local-variable rewrite：自举 ELF 兼容的局部变量重写。

## 2026-07-05
### [fix] get_arg inline path
- `get_arg` 内联路径带 gv_argv >= 0，防止未 patch 的 LEA displacement 触发 GPF。

## 2026-07-27
### [fix] complete self-hosted corearch backend
- Remove out-of-range 2^31/2^32 literals from backend encoding and use signed-safe 32/64-bit byte writers.
- Fix signed CCR operand decoding so sentinel values remain negative across bootstrap stages.
- Include v3 optimization metadata in CCR size calculation and validate metadata bounds while loading.
- Give optimization metadata independent 64-byte slots with capacity tracking and copy-on-grow.
- Add a three-stage corearch bootstrap regression with byte-identical output, O0/O2 CCR loading, and native ELF execution.

## 2026-07-23
### [fix] complete P0 native aggregate and self-host regressions
- Fix disp32 emission to use the current instruction base for struct fields, constant array indices, enum tags, and enum construction.
- Fix REX/ModRM/SIB encoding for variable array index loads and stores.
- Add native ELF regression coverage for aggregate access at O0/O1.
- Verify clean corec -> corec2 -> corec3 bootstrap at O0 and O1.

## 2026-04-24
### init
### [feat] ARM64 native backend & full pipeline
### folat
### [feat] add float, string, and array support
  - Float type: mixed int/float arithmetic, type promotion
### [remove] Remove temporary fix script
### [add] Add tests for borrowing, built-in optimizations, for loops, generics, and references; implement language configuration and syntax highlighting for Core language in VSCode
### editor

## 2026-05-07
### [add] Add Core execution model documentation and implement self-hosted compiler tests
  - Introduced a comprehensive design document for the Core execution model, detailing principles, graph structures, resource allocation, and execution strategies.

## 2026-05-19
### [cleanup] Clean up repo, move docs to docs/, update language reference
  - Add .gitignore for __pycache__/, *.pyc, build/*
### [remove] Remove design philosophy section from README

## 2026-05-20
### [feat] Implement references & module system for self-hosted compiler
  - Add reference support: &T / &mut T in parser, checker, ir_gen, x86-64

## 2026-05-28
### [rename] Rename .core→.cr, split compiler into corec (frontend) + corearch (backend)
  Breaking changes:
### [docs] Update CLAUDE.md to reflect corec/corearch split
### [add] Add .ccr binary format specification and spec IR schema docs
### [add] Add .cir dataflow graph format description
### [add] Add CIR dataflow graph IR module, CI config, and update .gitignore

## 2026-06-07
### [feat] full self-hosted compiler, ELF output, stdlib, diagnostics, -c interpreter, Arch PKGBUILD
  - Add None/Some keyword support to self-hosted parser
### [feat] dataflow interpreter, Rust-style diagnostics, error codes, Neovim IDE, hang fixes
  - Rewrite interpreter to read g_df_nodes[] (dataflow graph, .cir) instead of g_ir_instrs[]

## 2026-06-08
### [refactor] backend directory split, resolve pass, main.cr split, parser fix
  - Split x86_64 backend into x86_64/instr.cr + x86_64/elf.cr directory

## 2026-06-09
### [fix] mark TODO items 1-2 as resolved, add regression tests
  - Item 1 (if-without-else codegen): already fixed by parser struct-literal
### [fix] build_selfhost.py now works, use compile_source instead of compiler_main
  - build_selfhost.py: switch from compiler_main (needs file I/O via
### [fix] bump MAX_* limits to handle full token stream, fix interpreter int division and store8 for lists
  - Bump all MAX_* constants to generous values (MAX_TOKENS 8192→65536,

## 2026-06-13
### [fix] global var stack size, REX/SIB codegen, resolve_labels copy semantics, text assembly path removed, Chunk linker restored
  - parser.cr: values[0] = -1 (global var without initializer no longer crashes)
### [bump] all MAX_* limits 4-16x for self-compilation headroom
  MAX_FUNCS: 1024 -> 16384

## 2026-06-14
### [wip] full dynamic array conversion + string pool
  - All arrays converted to dynamic byte buffers (no MAX_* limits)
### [fix] remaining paren issues in dump.cr, corec + corearch build success
  - Rewrite ir_instr_str function with proper paren balancing
### [fix] rename r8→bu8 to avoid x86 register conflict, ELF now produces binaries
  Known issue: name_idx in .ccr is off by 1 (first string index mismatch)
### [fix] use index comparison for main lookup
  - Replace str_get() comparison with direct index comparison in elf.cr
### [fix] pipeline from source to binary now works!
  Root cause: g_str_count = 0 after tokenize() reset the string table,
### [feat] BSS global variable support in ELF backend
  - Add g_x86_is_global/g_x86_global_off arrays to track BSS vars
### [feat] dynamic linking - external call relocation recording
  - IR_CALL to unknown functions now records ext_rel entries instead of
### [feat] dynamic linking with PLT/GOT works!
  Bug fix: PLT j loop missing 'break' caused infinite loop in emit().
### [feat] standard library .so files
  - Build core_io.so and core_math.so from src/stdlib/*.cr
### [fix] handle __builtin_print/println as inline no-ops in ELF backend
  __builtin_print and __builtin_println are not available in the ELF
### [wip] embed __builtin_print/println function bodies in ELF output
  - Add emit_print_body / emit_println_body functions to elf.cr
### [fix] add missing g_is_project_mode declaration + include os.cr in build
  Build was failing because main.cr used g_is_project_mode without declaring it.

## 2026-06-15
### [feat] add diagnostic tool + __builtin_print/println ELF support
  tools/diagnose.py — Python diagnostic tool that:
### [fix] reduce MAX_STRS to 131072, add diagnostic tool
  tools/diagnose.py - Python diagnostic wrapper for compilation pipeline.
### [debug] identify that g_ir_func_name_idx is allocated but then NULL at crash
  Allocation in dyn_grow_ir_func_meta succeeds (n1=42788152) but
### [debug] add stack alignment check, fix nested calls in load_ccr
  Root cause analysis of the __builtin_print crash in load_ccr:
### [feat] add asm_check.py - Python bootstrap assembly analyzer
### [fix] add missing dyn_grow_ir_str_consts in load_ccr
  Root cause: load_ccr's grow section was missing dyn_grow_ir_str_consts().
### [refactor] replace all static [int; MAX_*] arrays with dynamic byte buffers
  All compiler arrays now grow dynamically instead of using MAX_* fixed limits:
### [fix] P1-P4 crashes, g_x86_is_global bounds, inline hot functions
  Bug fixes:
### [feat] fix Option::Some(42) parsing, match subpatterns, project mode
  Parser fixes:
### [fix] Python bootstrap fixes and module_to_ccr tool
  Python bootstrap:

## 2026-06-16
### [feat] add linear-scan register allocation to assembly generator
  Assigns callee-saved registers (r12-r15) and caller-saved (r8,r9) to
### [fix] ELF enum field offset, register allocation improvements
  - ELF LOAD_FIELD/STORE_FIELD: add runtime g_x86_is_enum check for +8 offset
### [revert] Revert "fix: ELF enum field offset, register allocation improvements"
  This reverts commit 5f38fe9be744266217bb28b44c1b08e2346835eb.
### [fix] MAKE_ENUM arch_instr_size, ELF enum offset check, reg alloc revert
  - arch_instr_size: MAKE_ENUM 18→26 (fixes SIGILL in match)
### [fix] ELF enum field offset works (match returns 42)
  Replace per-variable g_x86_is_enum check with global g_x86_is_enum_cap > 0.
### [fix] enum field offset driven by frontend, backend is pure translator
  Frontend (ir_gen.cr): add +1 to field index for enum field access.
### [feat] add interface declaration parsing and impl for syntax
  - Parser: handle interface Name { fn method(); ... }
### [feat] implement interface/trait system with generic constraints
  - Interface declarations with full method signature storage (name, param types, return type)
### [fix] emit external relocations for __builtin_* functions in ELF backend
  Previously the ELF backend silently no-oped IR_CALL to __builtin_*
### [fix] -h segfault by removing broken struct buffer access pattern in cli.cr
  The code used g_cli_cmds[ci] then cmd.name pattern which is a type
### [refactor] ELF backend _start with argc/argv, add --static flag
  - ELF backend _start now saves argc/argv to globals (g_rt_argc/g_rt_argv_ptr)
### [fix] core syntax highlighting - comment priority, identifier color
### [feat] static linking from .so (--static --link)
  - Add ctx_emit_static: reads .so .text section, embeds after user code
### [feat] CFIR passes - const fold, algebraic, branch fold, jump chain, DCE
  feat: linear scan register allocator (frontend, rewrites CFIR)
### [feat] stack slot reuse (O2) - disjoint live ranges share stack vars

## 2026-06-17
### [fix] init g_stack_map to empty string to prevent null ptr crash
  - corearch --shared now works: builds core_rt.so from rt.cr + stdlib
### [feat] stdlib .so build + dynamic linker path
  - corearch --shared produces core_rt.so from rt.cr + stdlib
### [fix] register encoding overlap with stack offsets, _start size in total_code
  - Register encoding -(reg+1) overlapped with stack slot offsets (-8,-16...)
### [refactor] measure _start size via emit_start_size() instead of hardcoded 22
  - Extract _start emission into emit_start() function
### [refactor] instruction sizes via _size() functions (Hexagon pessimistic)
### [fix] massive landmine cleanup — dynamic arrays, dynamic linking, instr fixes, va/offset bugs
  - Converted all [int; N]/[string; N] arrays to dynamic string buffers
### [docs] add hard rules — ban git, use jj, no bypassing, no reverting

## 2026-06-18
### [fix] 扫清全部隐患 — CLI 子命令 + 6 个未初始化数组 + batch:= 解析 + 边界校验
  CLI 重构:
### [fix] 3 parser fixes — parse_primary advance_tok, local_stmts 256-limit, parse_for_expr C-style guard
### [fix] string interpolation parser infinite loop on unterminated { — cli.cr crash root cause
### [fix] string interpolation infinite loop when { without }
### [fix] remove bogus string interpolation code + add multi-arg print/println to stdlib
### [stdlib] io.cr with int_to_str, concat, print — prepare for string interpolation expansion
### [stdlib] split io.cr → fmt.cr (pure) + io.cr (side effects)
### [refactor] remove __builtin_ prefix, split io.cr/fmt.cr, restructure runtime
### [fix] get_char/istr_get confusion, remove stale __builtin_ refs in fmt.cr
### [fix] tok_lx get_char→istr_get (root cause of all SIGSEGV)
### [feat] variadic function syntax ...name:type + T_DOTDOTDOT token
### [feat] .so extension interface with SYM_SO_FN + variadic print expansion
### [fix] alloc heap init (init_globals offset bug) + str_intern vs ccr index mismatch
### [feat] .so extension interface, variadic print, alloc fix
### [fix] load8/store8/syscall3 size calc + string-based lookups + e2_ld/st large offset
### [fix] resolve_labels dry-run + Phase 2 per-function sizing + stack frame accounting
### [fix] print function offset tracking + g2_init at Phase 2 start
### [fix] call recording + ld.cr decls reorder + Phase 3 position override
### [fix] alloc_ni string lookup + call recording infrastructure
### [fix] reverse Phase 3 emission order + position override for backward calls
### [fix] Python parser (ld.cr revert) + cp tracking for call patches + last-resort fix

## 2026-06-19
### [fix] alloc_size 58 (was 65) + Phase 2 stack size from g_ir_var_count
### [fix] stateless g2_slot + stack size set before prologue in both phases
### [fix] emit_start lea rsi encoding (was rbx, should be rsp)
### [refactor] single source of truth for instruction sizes (sizes.cr)
  - Create src/arch/linux/ld/sizes.cr with all sz_* size helpers
### [fix] replace hardcoded variadic/auto_str name checks with SYM_SO_FN tag queries
  - Variadic expansion now checks sym_kind==SYM_SO_FN && (TAG_VARIADIC)!=0
### [fix] EXPR_ARG linked list + SYM_SO_FN survive check_all reset
  EXPR_ARG (parser):
### [docs] fix markdown rendering issues
  - Add missing # headings to all doc files
### [docs] replace Chinese bullets (·) with markdown standard (-)
  Markdown only recognizes -, *, + for unordered lists.
### [docs] fix remaining rendering issues
  - project-book.md: space-aligned route table → pipe table
### [docs] tone down chuunibyou conclusions
  - dataflow-design.md: over-long dramatic conclusion → concise
### [docs] remove redundant 预期成果 section (duplicates language features)
### [docs] remove conversational/promotional language, maintain professional tone
  - language-syntax.md: rewrite 设计哲学 from casual bullet points to factual statements; rename '为什么极其容易学习' → '设计要点'; reword all 7 points professionally
### [feat] add Zed extension as submodule (zed → core-plugin-zed)
  Core language support for Zed editor:
### [fix] replace hardcoded fn_name checks in interpreter with SYM_SO_FN lookup

## 2026-06-21
### [fix] remove hardcoded function name checks for stdlib functions
  checker.cr had hardcoded return types for 19+ functions.
### [perf] cache HOME dir in import resolution, avoid per-import read
  - get_env('HOME') reads /proc/self/environ every call
### [fix] remove all hardcoded builtin names except syscall3
  - load8/store8/alloc/get_arg/load_str_ptr/store_str_ptr now registered
### [refactor] shorten verbose function names across codebase
  - dyn_grow_* → grow_* (60+ functions)
### [fix] SO type_enc2 mod 100 loop was O(10^10) for encoded params
  The 'mod 100' loop subtracted 100 per iteration.
### [refactor] separate variadic and auto_str into independent handlers
  handle_variadic: pure N-args→N-calls expansion, no type conversion
### [refactor] remove variadic and auto_str from compiler, move to stdlib
  dispatch_call now returns -1 for all calls — the compiler does
### [feat] add runtime scheduler (dispatch table + trampolines)
  - src/scheduler/sched.cr: DispatchTable struct, create/set/get/dump
### [feat] runtime scheduler (dispatch table)
  - src/stdlib/scheduler.cr: sched_create/sched_set32/sched_get32
### [fix] unlimited 64-bit scheduler + e2_li large immediate support
  scheduler.cr:
### [feat] sched_call_N trampolines emitted in ELF
  - emit_sched_call: generates mov rax,[rdi+rsi*8]; shift N args; jmp rax
### [docs] add CHANGELOG.md
### [docs] full CHANGELOG.md with all 123 commits
### [docs] comprehensive CHANGELOG.md with all 116 commits

## 2026-06-21
### [fix] ext_rel Phase 0/2 contamination in elf_gen
  - external relocation entries from Phase 0 (res_labels) and Phase 2 (size
    calculation) survived into Phase 3, because ext_rel was only reset at the
    start of elf_gen (after Phase 0) but not before Phase 3 emission
  - Phase 2 entries use dry-run buffer positions — when patch_relocs processes
    them alongside Phase 3 entries, they patch wrong code locations and corrupt
    the binary
  - Fix: add `g_x86_ext_rel_count = 0;` to the Phase 3 reset block alongside
    the existing ret/call/rodata/alloc/rip resets
  - All 23/23 bootstrap tests pass, self-hosted compiler verified
