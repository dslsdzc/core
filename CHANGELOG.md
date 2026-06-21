# 更新日志

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
