# 更新日志

## 2026-04-24
### init
### ✨ ARM64 native backend & full pipeline
### folat
### ✨ add float, string, and array support
  - Float type: mixed int/float arithmetic, type promotion
### 🗑️ Remove temporary fix script
### ➕ Add tests for borrowing, built-in optimizations, for loops, generics, and references; implement language configuration and syntax highlighting for Core language in VSCode
### editor

## 2026-05-07
### ➕ Add Core execution model documentation and implement self-hosted compiler tests
  - Introduced a comprehensive design document for the Core execution model, detailing principles, graph structures, resource allocation, and execution strategies.

## 2026-05-19
### Clean up repo, move docs to docs/, update language reference
  - Add .gitignore for __pycache__/, *.pyc, build/*
### 🗑️ Remove design philosophy section from README

## 2026-05-20
### Implement references & module system for self-hosted compiler
  - Add reference support: &T / &mut T in parser, checker, ir_gen, x86-64

## 2026-05-28
### ✏️ Rename .core→.cr, split compiler into corec (frontend) + corearch (backend)
  Breaking changes:
### Update CLAUDE.md to reflect corec/corearch split
### ➕ Add .ccr binary format specification and spec IR schema docs
### ➕ Add .cir dataflow graph format description
### ➕ Add CIR dataflow graph IR module, CI config, and update .gitignore

## 2026-06-07
### ✨ full self-hosted compiler, ELF output, stdlib, diagnostics, -c interpreter, Arch PKGBUILD
  - Add None/Some keyword support to self-hosted parser
### ✨ dataflow interpreter, Rust-style diagnostics, error codes, Neovim IDE, hang fixes
  - Rewrite interpreter to read g_df_nodes[] (dataflow graph, .cir) instead of g_ir_instrs[]

## 2026-06-08
### 🔧 backend directory split, resolve pass, main.cr split, parser fix
  - Split x86_64 backend into x86_64/instr.cr + x86_64/elf.cr directory

## 2026-06-09
### 🐛 mark TODO items 1-2 as resolved, add regression tests
  - Item 1 (if-without-else codegen): already fixed by parser struct-literal
### 🐛 build_selfhost.py now works, use compile_source instead of compiler_main
  - build_selfhost.py: switch from compiler_main (needs file I/O via
### 🐛 bump MAX_* limits to handle full token stream, fix interpreter int division and store8 for lists
  - Bump all MAX_* constants to generous values (MAX_TOKENS 8192→65536,

## 2026-06-13
### 🐛 global var stack size, REX/SIB codegen, resolve_labels copy semantics, text assembly path removed, Chunk linker restored
  - parser.cr: values[0] = -1 (global var without initializer no longer crashes)
### ⬆️ all MAX_* limits 4-16x for self-compilation headroom
  MAX_FUNCS: 1024 -> 16384

## 2026-06-14
### 🚧 full dynamic array conversion + string pool
  - All arrays converted to dynamic byte buffers (no MAX_* limits)
### 🐛 remaining paren issues in dump.cr, corec + corearch build success
  - Rewrite ir_instr_str function with proper paren balancing
### 🐛 rename r8→bu8 to avoid x86 register conflict, ELF now produces binaries
  Known issue: name_idx in .ccr is off by 1 (first string index mismatch)
### 🐛 use index comparison for main lookup
  - Replace str_get() comparison with direct index comparison in elf.cr
### 🐛 pipeline from source to binary now works!
  Root cause: g_str_count = 0 after tokenize() reset the string table,
### ✨ BSS global variable support in ELF backend
  - Add g_x86_is_global/g_x86_global_off arrays to track BSS vars
### ✨ dynamic linking - external call relocation recording
  - IR_CALL to unknown functions now records ext_rel entries instead of
### ✨ dynamic linking with PLT/GOT works!
  Bug fix: PLT j loop missing 'break' caused infinite loop in emit().
### ✨ standard library .so files
  - Build core_io.so and core_math.so from src/stdlib/*.cr
### 🐛 handle __builtin_print/println as inline no-ops in ELF backend
  __builtin_print and __builtin_println are not available in the ELF
### 🚧 embed __builtin_print/println function bodies in ELF output
  - Add emit_print_body / emit_println_body functions to elf.cr
### 🐛 add missing g_is_project_mode declaration + include os.cr in build
  Build was failing because main.cr used g_is_project_mode without declaring it.

## 2026-06-15
### ✨ add diagnostic tool + __builtin_print/println ELF support
  tools/diagnose.py — Python diagnostic tool that:
### 🐛 reduce MAX_STRS to 131072, add diagnostic tool
  tools/diagnose.py - Python diagnostic wrapper for compilation pipeline.
### 🔍 identify that g_ir_func_name_idx is allocated but then NULL at crash
  Allocation in dyn_grow_ir_func_meta succeeds (n1=42788152) but
### 🔍 add stack alignment check, fix nested calls in load_ccr
  Root cause analysis of the __builtin_print crash in load_ccr:
### ✨ add asm_check.py - Python bootstrap assembly analyzer
### 🐛 add missing dyn_grow_ir_str_consts in load_ccr
  Root cause: load_ccr's grow section was missing dyn_grow_ir_str_consts().
### 🔧 replace all static [int; MAX_*] arrays with dynamic byte buffers
  All compiler arrays now grow dynamically instead of using MAX_* fixed limits:
### 🐛 P1-P4 crashes, g_x86_is_global bounds, inline hot functions
  Bug fixes:
### ✨ fix Option::Some(42) parsing, match subpatterns, project mode
  Parser fixes:
### 🐛 Python bootstrap fixes and module_to_ccr tool
  Python bootstrap:

## 2026-06-16
### ✨ add linear-scan register allocation to assembly generator
  Assigns callee-saved registers (r12-r15) and caller-saved (r8,r9) to
### 🐛 ELF enum field offset, register allocation improvements
  - ELF LOAD_FIELD/STORE_FIELD: add runtime g_x86_is_enum check for +8 offset
### ↩️ Revert "fix: ELF enum field offset, register allocation improvements"
  This reverts commit 5f38fe9be744266217bb28b44c1b08e2346835eb.
### 🐛 MAKE_ENUM arch_instr_size, ELF enum offset check, reg alloc revert
  - arch_instr_size: MAKE_ENUM 18→26 (fixes SIGILL in match)
### 🐛 ELF enum field offset works (match returns 42)
  Replace per-variable g_x86_is_enum check with global g_x86_is_enum_cap > 0.
### 🐛 enum field offset driven by frontend, backend is pure translator
  Frontend (ir_gen.cr): add +1 to field index for enum field access.
### ✨ add interface declaration parsing and impl for syntax
  - Parser: handle interface Name { fn method(); ... }
### ✨ implement interface/trait system with generic constraints
  - Interface declarations with full method signature storage (name, param types, return type)
### 🐛 emit external relocations for __builtin_* functions in ELF backend
  Previously the ELF backend silently no-oped IR_CALL to __builtin_*
### 🐛 -h segfault by removing broken struct buffer access pattern in cli.cr
  The code used g_cli_cmds[ci] then cmd.name pattern which is a type
### 🔧 ELF backend _start with argc/argv, add --static flag
  - ELF backend _start now saves argc/argv to globals (g_rt_argc/g_rt_argv_ptr)
### 🐛 core syntax highlighting - comment priority, identifier color
### ✨ static linking from .so (--static --link)
  - Add ctx_emit_static: reads .so .text section, embeds after user code
### ✨ CFIR passes - const fold, algebraic, branch fold, jump chain, DCE
  feat: linear scan register allocator (frontend, rewrites CFIR)
### ✨ stack slot reuse (O2) - disjoint live ranges share stack vars

## 2026-06-17
### 🐛 init g_stack_map to empty string to prevent null ptr crash
  - corearch --shared now works: builds core_rt.so from rt.cr + stdlib
### ✨ stdlib .so build + dynamic linker path
  - corearch --shared produces core_rt.so from rt.cr + stdlib
### 🐛 register encoding overlap with stack offsets, _start size in total_code
  - Register encoding -(reg+1) overlapped with stack slot offsets (-8,-16...)
### 🔧 measure _start size via emit_start_size() instead of hardcoded 22
  - Extract _start emission into emit_start() function
### 🔧 instruction sizes via _size() functions (Hexagon pessimistic)
### 🐛 massive landmine cleanup — dynamic arrays, dynamic linking, instr fixes, va/offset bugs
  - Converted all [int; N]/[string; N] arrays to dynamic string buffers
### 📝 add hard rules — ban git, use jj, no bypassing, no reverting

## 2026-06-18
### 🐛 扫清全部隐患 — CLI 子命令 + 6 个未初始化数组 + batch:= 解析 + 边界校验
  CLI 重构:
### 🐛 3 parser fixes — parse_primary advance_tok, local_stmts 256-limit, parse_for_expr C-style guard
### 🐛 string interpolation parser infinite loop on unterminated { — cli.cr crash root cause
### 🐛 string interpolation infinite loop when { without }
### 🐛 remove bogus string interpolation code + add multi-arg print/println to stdlib
### 📦 io.cr with int_to_str, concat, print — prepare for string interpolation expansion
### 📦 split io.cr → fmt.cr (pure) + io.cr (side effects)
### 🔧 remove __builtin_ prefix, split io.cr/fmt.cr, restructure runtime
### 🐛 get_char/istr_get confusion, remove stale __builtin_ refs in fmt.cr
### 🐛 tok_lx get_char→istr_get (root cause of all SIGSEGV)
### ✨ variadic function syntax ...name:type + T_DOTDOTDOT token
### ✨ .so extension interface with SYM_SO_FN + variadic print expansion
### 🐛 alloc heap init (init_globals offset bug) + str_intern vs ccr index mismatch
### ✨ .so extension interface, variadic print, alloc fix
### 🐛 load8/store8/syscall3 size calc + string-based lookups + e2_ld/st large offset
### 🐛 resolve_labels dry-run + Phase 2 per-function sizing + stack frame accounting
### 🐛 print function offset tracking + g2_init at Phase 2 start
### 🐛 call recording + ld.cr decls reorder + Phase 3 position override
### 🐛 alloc_ni string lookup + call recording infrastructure
### 🐛 reverse Phase 3 emission order + position override for backward calls
### 🐛 Python parser (ld.cr revert) + cp tracking for call patches + last-resort fix

## 2026-06-19
### 🐛 alloc_size 58 (was 65) + Phase 2 stack size from g_ir_var_count
### 🐛 stateless g2_slot + stack size set before prologue in both phases
### 🐛 emit_start lea rsi encoding (was rbx, should be rsp)
### 🔧 single source of truth for instruction sizes (sizes.cr)
  - Create src/arch/linux/ld/sizes.cr with all sz_* size helpers
### 🐛 replace hardcoded variadic/auto_str name checks with SYM_SO_FN tag queries
  - Variadic expansion now checks sym_kind==SYM_SO_FN && (TAG_VARIADIC)!=0
### 🐛 EXPR_ARG linked list + SYM_SO_FN survive check_all reset
  EXPR_ARG (parser):
### 📝 fix markdown rendering issues
  - Add missing # headings to all doc files
### 📝 replace Chinese bullets (·) with markdown standard (-)
  Markdown only recognizes -, *, + for unordered lists.
### 📝 fix remaining rendering issues
  - project-book.md: space-aligned route table → pipe table
### 📝 tone down chuunibyou conclusions
  - dataflow-design.md: over-long dramatic conclusion → concise
### 📝 remove redundant 预期成果 section (duplicates language features)
### 📝 remove conversational/promotional language, maintain professional tone
  - language-syntax.md: rewrite 设计哲学 from casual bullet points to factual statements; rename '为什么极其容易学习' → '设计要点'; reword all 7 points professionally
### ✨ add Zed extension as submodule (zed → core-plugin-zed)
  Core language support for Zed editor:
### 🐛 replace hardcoded fn_name checks in interpreter with SYM_SO_FN lookup

## 2026-06-21
### 🐛 remove hardcoded function name checks for stdlib functions
  checker.cr had hardcoded return types for 19+ functions.
### ⚡ cache HOME dir in import resolution, avoid per-import read
  - get_env('HOME') reads /proc/self/environ every call
### 🐛 remove all hardcoded builtin names except syscall3
  - load8/store8/alloc/get_arg/load_str_ptr/store_str_ptr now registered
### 🔧 shorten verbose function names across codebase
  - dyn_grow_* → grow_* (60+ functions)
### 🐛 SO type_enc2 mod 100 loop was O(10^10) for encoded params
  The 'mod 100' loop subtracted 100 per iteration.
### 🔧 separate variadic and auto_str into independent handlers
  handle_variadic: pure N-args→N-calls expansion, no type conversion
### 🔧 remove variadic and auto_str from compiler, move to stdlib
  dispatch_call now returns -1 for all calls — the compiler does
### ✨ add runtime scheduler (dispatch table + trampolines)
  - src/scheduler/sched.cr: DispatchTable struct, create/set/get/dump
### ✨ runtime scheduler (dispatch table)
  - src/stdlib/scheduler.cr: sched_create/sched_set32/sched_get32
### 🐛 unlimited 64-bit scheduler + e2_li large immediate support
  scheduler.cr:
### ✨ sched_call_N trampolines emitted in ELF
  - emit_sched_call: generates mov rax,[rdi+rsi*8]; shift N args; jmp rax
### 📝 add CHANGELOG.md
### 📝 full CHANGELOG.md with all 123 commits
