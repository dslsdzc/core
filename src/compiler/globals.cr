// === globals.cr ===
// ALL arrays are dynamic byte buffers (grow as needed, no MAX_* limits).

// String table (dynamic byte buffer containing `string` pointers)
g_strs : string, mut
g_str_count : int, mut
g_str_cap : int, mut

// String interning hash table: maps a hash to a g_strs index (-1 = empty slot).
// Open addressing with linear probing.
g_str_hash : string, mut
g_str_hash_cap : int, mut

// Dynamic byte buffers (all arrays, no MAX_* limits)
g_funcs : string, mut
g_func_count : int, mut
g_func_cap : int, mut
g_structs : string, mut
g_struct_count : int, mut
g_struct_cap : int, mut
g_enums : string, mut
g_enum_count : int, mut
g_enum_cap : int, mut
g_syms : string, mut
g_sym_count : int, mut
g_sym_cap : int, mut
g_types : string, mut
g_type_count : int, mut
g_type_cap : int, mut
// Type row layout: 24 bytes per row, {kind, data, extra} as three i64 values.
// alloc_type, grow_types, and TYPE-segment serialization all use these constants.
ESZ_TYPE_ROW : int = 24
OFF_TR_KIND : int = 0
OFF_TR_DATA : int = 8
OFF_TR_EXTRA : int = 16

// TYPE segment buffer. Construction lives in ccr_types.cr, which is corec-only
// because it uses the type bridge. ccr_io.cr, which corearch also links, only
// copies and parses the segment. The buffer includes the row_count field, so the
// segment size equals the buffer length.
// These globals must stay in this file because it is first in both concatenated
// builds. Moving them to a corec-only file would leave ccr_io references undefined
// in corearch.
g_ccr_type_seg : string, mut
g_ccr_type_seg_len : int, mut
// IFACE segment buffer. Construction lives in ccr_types.cr; ccr_io.cr only copies
// and parses it. The buffer includes native_count, so the segment size equals the
// buffer length.
g_ccr_iface_seg : string, mut
g_ccr_iface_seg_len : int, mut
// NOD semantic type-id side buffer (v10 NOD `type_id`). Filling happens in
// ccr_types.cr:ccr_nod_type_populate during the save path; the wire writes the
// 40B NOD record with `type_id` at +24 and `flags` at +28.
// Value semantics: >= 0 is a TYPE row (face 0 = the row's item is reversible);
// -1 means no type row. `g_ccr_nod_flags` is the companion semantic-flags word
// (CCR_NOD_FLAG_*): dynamic bounds/spawn markers and the runtime-pointer-bound
// marker. It never carries a width, byte extent, stride, or alignment.
// This file is first in both builds, so these globals must stay here.
g_ccr_nod_type : string, mut
g_ccr_nod_type_count : int, mut
g_ccr_nod_flags : string, mut
g_ccr_nod_flags_count : int, mut
// Semantic v10 CASE model. Rows are 24B records with the same field layout as
// the wire (value, kind, str index, target, flags), but `target` is the IR body
// *label number* rather than a NOD id. ir_gen fills this model; ccr_lower is
// the only step that turns it into g_ccr_case (the wire table), and the CIR
// cache persists this model rather than the derived wire. This file is first in
// both builds, so these globals must stay here.
g_lat_case : string, mut
g_lat_case_count : int, mut
// Capacity of g_lat_case in 24B rows. Compiler-private and never serialized.
g_lat_case_cap : int, mut
// In-memory CASE table for v10 segment tag 9. Rows are 24B records with the
// layout named by CCR_CASE_* (value, kind, str index, target NOD, flags).
// This is a derived buffer: ccr_lower builds it from g_lat_case, and ccr_io /
// interp read it as wire. The empty program keeps count zero and the wire
// writes a bare 4B zero count. The loader rebuilds the same rows from disk.
// This file is first in both builds, so it must stay here.
g_ccr_case : string, mut
g_ccr_case_count : int, mut
// Capacity of g_ccr_case in 24B rows. ccr_lower appends rows while deriving the
// wire; the capacity is compiler-private and never serialized.
g_ccr_case_cap : int, mut
// Set by ir_gen when the current function lowered a match to IR_MATCH. The
// .cir snapshot carries the semantic CASE range, so this is a diagnostic flag,
// not a cache-save gate.
g_cir_has_match : int, mut
g_ast : string, mut
g_ast_count : int, mut
g_ast_cap : int, mut
g_tokens : string, mut
g_token_count : int, mut
g_tok_cap : int, mut
g_errors : string, mut
g_error_count : int, mut
g_err_cap : int, mut
g_block_stmts : string, mut
g_block_stmt_count : int, mut
g_block_stmt_cap : int, mut
g_ir_vars : string, mut
g_ir_var_count : int, mut
g_ir_var_cap : int, mut
g_ir_instrs : string, mut
g_ir_instr_count : int, mut
g_ir_instr_cap : int, mut
g_ir_locals : string, mut
g_ir_local_count : int, mut
g_ir_local_cap : int, mut
g_ir_globals : string, mut
g_ir_global_count : int, mut
g_ir_global_cap : int, mut
g_ir_str_consts : string, mut
g_ir_str_const_count : int, mut
g_ir_str_const_cap : int, mut

// Intern journal for the cache generation window.
// The string table grows during IR generation, but a cache hit skips generation, so
// absolute intern ids in a snapshot can be interpreted with the wrong numbers.
// The journal records the contents of each new string during the window, and the
// loader replays them in order before restoring any id. Record order is insertion
// order because dyn_arr.cr has a single insertion path through str_intern.
g_cir_rec_on      : int, mut   // 1 = 正在记录（仅 corec 的缓存生成窗口内打开）
g_cir_rec_ids     : string, mut // 本窗口新 intern 的 id 序列（8B/条；落盘时解析为内容）
g_cir_rec_count   : int, mut
g_cir_rec_cap     : int, mut
g_cir_rec_base    : int, mut   // g_str_count at window start; stored as the baseline witness
g_cir_skip_journal : int, mut  // 隐藏 debug（仅判据用）：1 = 装载期跳过重放（突变自证）

// Optional runtime representation.
// Some(1) and None use IR_MAKE_ENUM objects ([tag][payload...]), while a bare value
// in a T? slot stays bare. The same T? value can therefore have two representations.
// Each optional slot gets a representation bit, stored as an ordinary int IR
// variable: 0 = bare, 1 = boxed. Write points set it (a constant when statically
// known, otherwise copied from the source slot), and unpack points dispatch on it
// (Some/None arms of match, and ?). This is pure IR: no new opcode and no ABI
// change, so the ELF backend and interpreter share the behavior.
// g_ir_var_rep maps an IR var to its representation variable, or -1 when absent.
// Slots without a representation bit use the existing boxed assumption.
g_ir_var_rep : string, mut
g_ir_var_rep_cap : int, mut
// g_ir_var_decl_ti maps an IR var to its declared type index, or -1 when there is
// no annotation or the type is unknown. It is used when boxing writes to optional
// aggregate slots: an array or slice element type is reliable only from the
// declaration, because literal inference degrades optional elements to an object
// placeholder. This is process-local state; non-optional programs never read it.
g_ir_var_decl_ti : string, mut
g_ir_var_decl_cap : int, mut
// Names whose address is taken: the name indexes of ident operands of
// EXPR_UNARY + UOP_REF, collected by a pre-scan. Matching is by name index, so the
// same name elsewhere is also marked. This is conservative: extra marking only adds
// boxing and cannot lose correctness.
g_addr_taken_names : string, mut
g_addr_taken_cap : int, mut
g_addr_taken_count : int, mut
// Struct field side tables. Field slots moved out of the fixed struct record; the
// record's OFF_SI_FIELD_BASE slot is the starting row here. Record size and offsets
// are unchanged. Three flat tables are indexed by global field row, with high-water
// mark g_si_f_used. This is process-local state; the .ccr on-disk layout is
// unchanged because fields were already variable-length.
g_si_f_names : string, mut
g_si_f_types : string, mut
g_si_f_nodes : string, mut
g_si_f_used : int, mut
g_si_f_cap : int, mut
// Enum variant side tables, the same shape as struct fields. The OFF_EI_VARIANTS
// slot now holds variant_base. Three tables describe variants (name, payload base,
// payload count) and two describe payloads (raw code, type node).
g_ei_v_names : string, mut
g_ei_v_tbase : string, mut
g_ei_v_tcount : string, mut
g_ei_vt_types : string, mut
g_ei_vt_nodes : string, mut
g_ei_v_used : int, mut
g_ei_vt_used : int, mut
g_ei_v_cap : int, mut
g_ei_vt_cap : int, mut
// Match coverage bitmap with no fixed limit. The old single-int bitmap overflowed at
// 63 variants. Bits are addressed by variant index. g_cov_len is the current used
// length. mc_begin saves the length and mc_end clears and restores it, so nested
// matches are safe.
g_cur_lib : int, mut
g_saw_pub : int, mut
g_cov_bits : string, mut
g_cov_cap : int, mut
g_cov_len : int, mut
g_cov_base : int, mut
// g_optrep_on is 1 when this compilation unit uses optional representations. The
// AST pre-scan sets it for EXPR_OPTIONAL, Some, or None. When off, no hidden globals
// are registered and no representation instructions are emitted, so non-optional
// programs produce identical output.
g_optrep_on : int, mut
// g_dump_params_on enables the hidden --dump-params channel. When set, the
// parameter prologue prints one line per parameter:
//   PARAM <function> p<i> <name> slot=<type code> decl=<node type_val>
// The flag is rc-neutral and leaves output unchanged. It only reads irv_type and
// ast_type_val and uses the existing istr_get for the function name.
g_dump_params_on : int, mut
// g_optrep_ret_cell is the return-representation channel (an IR global var, or -1
// when unregistered). Return points write it and call points read it. The read
// immediately follows IR_CALL, so a nested call cannot overwrite it; the write
// happens after the value is evaluated.
g_optrep_ret_cell : int, mut
// g_optrep_arg_cell0 / g_optrep_arg_count：形参表示信道（每形参位一个 IR 全局 var，
//   连续分配）。调用点写、被调序言读（先于任何可能改写信道的调用）。
g_optrep_arg_cell0 : int, mut
g_optrep_arg_count : int, mut
// g_cur_ret_opt：当前函数的返回类型是否可选（ir_gen_func 设置；返回点写信道用）。
g_cur_ret_opt : int, mut
// g_cur_ret_dex_opt is 1 when the current function returns dex?. ir_gen_func sets it
// from the return type node. For `-> dex?`, g_cur_ret_ti and type_val are both 0
// because unpack_type collapses EXPR_OPTIONAL, so this flag supplies the dex
// boundary conversion at return points.
g_cur_ret_dex_opt : int, mut
// Representation codes returned by rep_enc_of_expr: >= 0 means copy from that
// representation slot; oe_bare() = -1 means a bare constant; oe_boxed() = -2 means a
// boxed constant. They are functions, not file-level constants, because the Python
// bootstrap records constant_value only for bare literals. A negative literal such
// as -1 becomes a UnaryOp, loses its initial value, and the backend emits .quad 0.
// Negative file-level constants therefore read as 0 in the bootstrap-built binary.
// Return expressions are not affected.
fn oe_bare() -> int:
    return 0 - 1
fn oe_boxed() -> int:
    return 0 - 2

// Parser/checker dynamic arrays (shared between corec and corearch builds)
g_global_lets : string, mut
g_global_let_count : int, mut
g_global_lets_cap : int, mut
g_loop_stack : string, mut
g_loop_depth : int, mut
g_loop_stack_cap : int, mut
g_type_aliases : string, mut
g_type_alias_count : int, mut
g_type_alias_cap : int, mut
g_methods : string, mut
g_method_count : int, mut
g_method_cap : int, mut
g_scope_bounds : string, mut
g_scope_depth : int, mut
g_scope_bounds_cap : int, mut
g_borrow_scope_markers : string, mut
g_borrow_scope_depth : int, mut
g_borrow_scope_markers_cap : int, mut

// Interface system
g_ifaces : string, mut
g_iface_count : int, mut
g_iface_cap : int, mut
g_impl_for : string, mut
g_impl_for_count : int, mut
g_impl_for_cap : int, mut
g_generic_constr : string, mut
g_generic_constr_count : int, mut
g_generic_constr_cap : int, mut
// Struct and enum generic constraint side tables. They use a separate index space
// from g_generic_constr, whose key is fi * MAX_GENERICS + gi; sharing one buffer
// would let struct, enum, and function row numbers overwrite each other.
// Keys are si * MAX_GENERICS + gi for structs and ei * MAX_GENERICS + gi for enums.
// The value is a constraint name index, or -1 for no constraint. The table is
// sparse; unwritten slots are not read.
// Whether T satisfies a constraint goes through iface_satisfies. The instantiation
// point calls gen_inst_constr_satisfied and reports TG02 for a provable violation.
// Function call sites still use check_iface. See the gen_constr_* section in
// checker.cr.
g_sgen_constr : string, mut
g_sgen_constr_count : int, mut
g_sgen_constr_cap : int, mut
g_egen_constr : string, mut
g_egen_constr_count : int, mut
g_egen_constr_cap : int, mut
// Cross-cutting shape table: name index to shape type term. This is route A of
// iface_satisfies. It is parallel to g_ifaces, which holds user interfaces as method
// sets. Each entry here is one type term, such as sequence -> top_k(AK_SEQUENCE),
// and satisfaction is one containment check.
// iface_shape_register adds entries. Registered names must already be interned
// source identifiers; the initialization path must not call str_intern, because the
// .ccr STR segment is checked byte for byte.
g_iface_shape_names : string, mut
g_iface_shape_terms : string, mut
g_iface_shape_count : int, mut
g_iface_shape_cap : int, mut
// Call-site generic bindings, used to build monomorph instance keys from types.
// infer_gen_call records one slot per callee generic parameter in declaration
// order. The value is the inferred type row, or -1 when unbound. The start index is
// stored in the call node's ast_int_val. ir_gen uses these rows to build canonical
// instance keys through inst_key_of_ti and to substitute types through
// g_gen_subst_tis instead of replacing names as text.
g_gen_binds : string, mut
g_gen_binds_count : int, mut
g_gen_binds_cap : int, mut
// Deduplication table for constraint-violation diagnostics. Open addressing,
// 16 bytes per entry {key, 1}; key = node * MAX_GENERICS + gi. Its lifetime matches
// g_named_dedup: init_types sets cap to 0 and the table is rebuilt lazily. The key
// contains an AST node index, so it must not survive a compilation. See
// gen_constr_seen_* in checker.cr.
g_constr_seen : string, mut
g_constr_seen_cap : int, mut
g_constr_seen_count : int, mut
g_gen_params : string, mut
g_gen_param_count : int, mut
g_gen_param_cap : int, mut
g_checker_current_fi : int, mut
// S1' tracing switch, default 0. main.cr sets it when CORE_S1P=1. When on, checker
// call sites print line, column, parameter index, parameter type, argument type,
// and callee name. The trace calls int_str and println, which create strings and
// change the .ccr STR segment, so it must stay off by default to keep output
// byte-identical.
g_s1p_on : int, mut        // S1′ 打点开关：0 = 关（默认行为）· 1 = 开（`CORE_S1P=1`）
g_int_big : int, mut       // set by str_int_literal when the literal does not fit a machine word
g_s1p_seen : int, mut      // 0 = environment variable not read yet. The sentinel must be
                            // zero: non-literal global initializers are stored as 0 by the
                            // Python bootstrap build, so `= -1` cannot be relied on.

g_unsafe_depth : int, mut
g_alloc_pts : string, mut
g_alloc_pts_cap : int, mut
g_borrow_vars : string, mut
g_borrow_refs : string, mut
g_borrow_muts : string, mut
g_borrow_count : int, mut
g_borrow_cap : int, mut
g_holder_borrowers : string, mut
g_holder_borrowed : string, mut
g_holder_is_mut : string, mut
g_holder_count : int, mut
g_holder_cap : int, mut
g_gen_map_names : string, mut
g_gen_map_types : string, mut
g_gen_map_count : int, mut
// Per-function inferred return row (-2 = explicit/not inferred, >= 0 = type row).
// The parser synthesizes a `__ret` generic parameter when `->` is omitted; the
// checker stores the body-derived row here and call inference substitutes it.
g_func_ret_ti : string, mut
g_func_ret_count : int, mut
g_func_ret_cap : int, mut
g_infer_ret_active : int, mut
g_infer_ret_ti : int, mut
// Globally unique suffix for synthesized `__inferN` / `__retN` names. Function
// and struct parameters share g_gen_map, so per-declaration numbering collides
// during nested inference (e.g. a generic struct literal inside a generic call).
g_infer_name_seq : int, mut
g_gen_map_cap : int, mut
g_dyn_type_sets : string, mut
g_dyn_type_set_count : int, mut
g_dyn_type_set_cap : int, mut

g_ir_func_name_idx : string, mut
g_ir_func_name_idx_cap : int, mut
g_ir_func_ret_type : string, mut
g_ir_func_ret_type_cap : int, mut
g_ir_func_instr_start : string, mut
g_ir_func_instr_start_cap : int, mut
g_ir_func_instr_count : string, mut
g_ir_func_instr_count_cap : int, mut
g_ir_func_var_start : string, mut
g_ir_func_var_start_cap : int, mut
g_ir_func_var_count : string, mut
g_ir_func_var_count_cap : int, mut
g_ir_func_param_count : string, mut
g_ir_func_param_count_cap : int, mut
g_ir_func_count : int, mut

// Live-range table, filled by compute_live_ranges in ent_kernel.cr and read by
// alloc_registers. corec calls compute_live_ranges and compute_entries while saving
// a .ccr; corearch reads the table during allocation.
// Each function has one segment. Each function-local var has two i64 values,
// first_ref and last_ref, in function-local instruction coordinates
// (0 .. instr_count-1). The segment start for func_i is the sum of var_count[0..i),
// with no fixed dense factor. An unused var is -1.
// Records are 16 bytes; grow_live_ranges is in ent_kernel.cr.
g_ir_live_ranges : string, mut
g_live_range_count : int, mut
g_live_range_cap : int, mut

// Entry table, filled by compute_entries, which compute_live_ranges calls after
// processing all functions. Each .ccr ENT record is one entry. corec calls the fill
// functions before saving; corearch reads the table.
// Each record is 24 bytes: six 4-byte fields, read and written little-endian. Read
// with buf_read_i32 because r32 reads lose sign extension in the bootstrap build.
// Field offsets:
//   var_idx(0)    u32: global IR variable index, in g_ir_vars order.
//   def_instr(4)  i32: global index of the defining instruction, either
//                 IR_ALLOC(dest=var) or IR_STORE(s1=var). For the store form,
//                 rho(s1) := rho(s2), the destination is s1 and dest is -1.
//                 -1 means there is no defining entry.
//   live_start(8) / live_end(12) i32: version live range as a closed interval in
//                 global instruction order, [def_j, min(def_{j+1}-1, last_ref)].
//                 Without a defining entry, [first_ref, last_ref].
//   runtime_home(16) i32: allocator/instance slot, or -1 if unassigned. Never
//                 serialized into `.ccr`; v10 ENT has no home field.
//   flags(20)     u32: 0; bit 0 is reserved.
// Each function has one segment, appended in func_i order. Segment bounds are in
// g_ir_func_entry_start and g_ir_func_entry_count (8 bytes each).
// Version numbers are not stored: entries for the same var are ordered by
// def_instr, and the version is the 1-based position within the group.
g_ir_entries : string, mut
g_entry_count : int, mut
g_entry_cap : int, mut
// 1 = the entry table came from the v10 ENT segment. compute_live_ranges keeps
// those entries instead of rebuilding them, so allocation and diagnostics consume
// the loaded existence lattice rather than a recomputed mirror. The corec save
// path leaves this 0 and computes entries from the IR.
g_ent_loaded : int, mut
g_ir_func_entry_start : string, mut
g_ir_func_entry_count : string, mut
g_ir_func_entry_cap : int, mut

// Module system arrays (dynamic byte buffers)
DIAG_REC_SIZE : int = 64   // g_diags 记录字节数：[ec(8) msg(8) line(8) col(8) module_fid(8) sm_file(8) sm_lo(8) sm_hi(8)]
// 前 40 字节为历史布局，LSP 仍按这些偏移读取。sm_file/lo/hi 是 SourceManager
// 的归属与范围；sm_file < 0 表示该诊断没有可归属的源文件，渲染时回退到 line/col。
// Scope labels for the diagnostic exemption table. The hard-decision loop in main.cr
// calls diag_gate_exempt(ec, scope); the table itself is in diag.cr. run_frontend
// uses GATE_SCOPE_BUILD only. The check path uses its own count > 0 rule and does
// not consult this table.
GATE_SCOPE_BUILD : int = 1   // build, ccr, cir, and run paths (through run_frontend)
GATE_SCOPE_CHECK : int = 2   // check path; registered but not consumed by the exemption table
g_diags : string, mut
g_diag_count : int, mut
g_diag_cap : int, mut
g_files : string, mut
g_file_count : int, mut
g_file_cap : int, mut
g_mods : string, mut
g_mod_count : int, mut
g_mod_cap : int, mut
// LSP open documents: path to source text. Records are 24 bytes:
// {path_ptr, src_ptr, src_len}. Both strings are stable heap strings supplied by
// the caller.
g_open_docs : string, mut
g_open_doc_count : int, mut
g_open_doc_cap : int, mut
// LSP silent mode: 1 suppresses progress and warning output on stdout so the
// protocol channel stays clean.
g_silent_stdout : int, mut      // 默认 0：corec 命令行行为不变
g_mod_func_fileids : string, mut
g_mod_func_names : string, mut
g_mod_func_tis : string, mut
g_mod_func_count : int, mut
g_mod_func_cap : int, mut
g_mod_path_names : string, mut
g_mod_path_count : int, mut
g_mod_path_cap : int, mut

// Dynamic stacks (byte buffers)
g_ir_local_scopes : string, mut
g_ir_local_scopes_cap : int, mut
g_ir_local_depth : int, mut
g_ir_loop_header : string, mut
g_ir_loop_exit : string, mut
g_ir_loop_depth : int, mut
g_ir_loop_stacks_cap : int, mut
g_label_poses : string, mut
g_label_cap : int, mut
g_label_count : int, mut
// Interpreter loop-region table: per SG_LOOP/SG_FOR region, the enter/exit
// DF-node offsets (function-relative).  Loop iteration in the interpreter is
// driven by these region boundaries, not by label-table back-jumps.
g_loop_region_enter : string, mut
g_loop_region_exit : string, mut
g_loop_region_count : int, mut
g_loop_region_cap : int, mut
// Pre-computed interned string indices for builtin function name matching
g_ni_load8 : int, mut
g_ni_store8 : int, mut
g_ni_load64 : int, mut
g_ni_load_str_ptr : int, mut
g_ni_store_str_ptr : int, mut
g_ni_get_arg : int, mut
g_ni_cell_store : int, mut
g_ni_dyncpy : int, mut
g_ni_cell_load : int, mut
g_ni_goroutine_wrapper_addr : int, mut
// Single-pass backpatching: pending forward jumps
g_pending_pos : string, mut        // rel32 buffer positions to patch
g_pending_label : string, mut      // target label indices
g_pending_count : int, mut
g_pending_cap : int, mut
g_next_label : int, mut

// .so extension index side tables. Parsed entries land here first, not directly in
// the string or symbol table. Only names referenced by the program are materialized
// by so_materialize in module.cr, so unreferenced entries leave no output trace.
// name holds the original string, not an intern index: interning during
// registration was the leak this table avoids. tags and type hold ints with the
// same meaning as sym_type and sym_node in an SO_FN symbol entry.
g_so_side_name : string, mut
g_so_side_tags : string, mut
g_so_side_type : string, mut
g_so_side_count : int, mut
g_so_side_cap : int, mut
// Spec annotation side table for #check(expr) and #ensure(expr), appended in source
// order, 8 bytes per row.
// Annotations do not use EXPR_FN's a/b/c slots. Their expression nodes land in
// g_ast but are not referenced by the body, so IR generation never reaches them and
// output is unchanged. The table resets with frontend state because fi and ni
// indexes are reused across compilations; stale rows would otherwise be hit.
g_spec_fn : string, mut                // function name index (parse_body fn_ni; used in messages)
g_spec_fnode : string, mut             // EXPR_FN node index (unique key; same-named
                                        // functions or methods do not collide; parser backfills it)
g_spec_kind : string, mut              // 0 = #check, 1 = #ensure
g_spec_expr : string, mut              // AST node index of the annotation expression
g_spec_line : string, mut              // line of the annotation `#`
g_spec_col : string, mut               // column of the annotation `#`
g_spec_status : string, mut            // 0 = yellow (unproved, default), 1 = green (constant true),
                                        // 2 = red (hard error). Red is sticky and is not overwritten by green.
g_spec_count : int, mut
g_spec_cap : int, mut

// Optimization levels and metadata (extensible key-value store)
g_opt_level : int, mut     // 0=none, 1=regalloc, 2=stackshare, 3=cse
g_opt_meta : string, mut   // metadata buffer for .ccr v3+
g_opt_meta_count : int, mut
g_opt_meta_cap : int, mut

// Subgraph table (for RegionCheck pass lifetime tracking)
g_sgs : string, mut
g_sg_count : int, mut
g_sg_cap : int, mut
g_df_node_region : string, mut
g_df_node_region_cap : int, mut  // per DFNode: owning region id (-1 = none)
g_cur_sg : int, mut              // currently open region id (-1 = none)
g_cur_ret_ti : int, mut          // current function return type index, used for dex conversion
g_last_state_node : int, mut     // last side-effect DFNode id in the VSDG state chain; -1 = none
g_df_state_finalized : int, mut  // df_state_finalize idempotence flag; 0 = not run

// Plugin extension registry: tags and return types from .so/stdlib plugins
// Each entry: 24 bytes = [ns_ni, name_ni, data_ni]
g_plugin_tags : string, mut
g_plugin_tag_count : int, mut
g_plugin_tag_cap : int, mut
g_plugin_rtypes : string, mut
g_plugin_rtype_count : int, mut
g_plugin_rtype_cap : int, mut

// Pointer analysis storage
g_pts : string, mut
g_pts_count : int, mut
g_pts_cap : int, mut
g_offsets : string, mut
g_offsets_count : int, mut
g_offsets_cap : int, mut
// Allocation sequence number to DF node index. The provenance pass uses it to look
// up the allocation size.
g_pa_alloc_count : int, mut
g_pa_alloc_nodes : string, mut
g_pa_alloc_nodes_cap : int, mut
g_node_unsafe : string, mut

// Type-term engine: DAG table, structural hash index, judgment memo, and budget
// state. Each term is 48 bytes: {tag, a, b, c, d, hash}; see type_terms.cr.
// grow_type_terms and grow_tt_index are also there.
// g_tt_top and g_tt_nil are lazy memo slots. Their ready flags use zero as
// "not built" because the bootstrap backend stores non-literal global initializers,
// including `= -1`, as 0.
g_type_terms : string, mut
g_type_term_count : int, mut
g_type_term_cap : int, mut
g_tt_index : string, mut
g_tt_index_cap : int, mut
g_tt_index_count : int, mut
g_tt_nil : int, mut
g_tt_nil_ok : int, mut
g_tt_top : int, mut
g_tt_top_ok : int, mut
g_ty_memo_keys : string, mut
g_ty_memo_vals : string, mut
g_ty_memo_count : int, mut
g_ty_memo_cap : int, mut
g_ty_memo_ok : int, mut
g_ty_steps : int, mut
g_ty_budget_max : int, mut
g_ty_exhausted : int, mut
g_ty_lits : string, mut
g_ty_lits_cap : int, mut
g_ty_lits_count : int, mut
g_ty_uncovered : int, mut         // set when an unimplemented case is hit, such as an unexpanded named row

// Native interface entry table. Each entry is 40 bytes with five fields:
// {ak, ti_row, name_ni, lit_code, ops}. The layout constants, the table itself, and
// the iface_* query API are in iface_registry.cr. These globals must be declared
// here because bootstrap name resolution is declaration-order and does not allow
// forward references across files.
// The table does not allocate g_types rows or consume type row numbers, so the .ccr
// type segment is unaffected. g_iface_registry_ok marks lazy initialization.
g_iface_entries : string, mut
g_iface_entry_count : int, mut
g_iface_registry_ok : int, mut

// Operation-permission bit indexes. The table data is the ops column in
// iface_registry.cr; checker.cr consumes it at three gates.
// Bit assignments:
//   OP_* 1..14 use their own values directly. OP_AND is 12 and OP_OR is 13, so
//   there is no separate IP_LOGIC constant; logic checks call
//   iface_permits(kind, OP_AND). OP_ASSIGN (14) is unused because assignment
//   compatibility goes through type_compat_strict.
//   UOP_* 1..4 are offset by IP_UOP_BIAS: UOP_NEG=21, UOP_NOT=22, UOP_REF=23,
//   UOP_DEREF=24.
//   New families start at 25: IP_INDEX=25, IP_INDEX_RANGE=26, IP_FIELD=27,
//   IP_METHOD=28, IP_AS=29, IP_COND=30. IP_COND accepts bool only and gates
//   both if and while conditions.
// These constants must be declared here because checker.cr is earlier in the
// concatenated build and cannot reference constants from a later file. Functions
// may be forward-referenced.
IP_UOP_BIAS : int = 20
IP_INDEX : int = 25
IP_INDEX_RANGE : int = 26
IP_FIELD : int = 27
IP_METHOD : int = 28
IP_AS : int = 29
IP_COND : int = 30

// Bridge cache from checker type row to type term. Each entry is 16 bytes
// {ti, term}. ty_shadow.cr owns probing, load-factor checks, and rehash replay.
// This is production state: the judgment path always calls sh_term_of_ti.
// entries counts occupied slots. It never decreases and doubles as the load factor
// input, so there is no separate count.
g_term_map : string, mut
g_term_map_cap : int, mut
g_term_map_entries : int, mut

// Output slots for DFNode type splitting plus the build-failure counter.
// The language has no multiple return values, so sh_tk_split writes the term
// reference and auxiliary code through these globals after setting defaults.
// ir_gen's emit and cir_cache's loader are the consumers.
// g_tk_face_fail increments when a type-op tk cannot be translated (row out of
// range or a bridge gap). The save path then refuses to write a snapshot and emits
// a diagnostic. A composite row that is translatable but not reversible does not
// set it. init_types resets it.
g_sh_slot_term : int, mut
g_sh_slot_aux : int, mut
g_tk_face_fail : int, mut



// Deduplication table for named types. Open addressing, 16 bytes per entry
// {name_idx, ti}. alloc_named_type is the only allocation point: a name already in
// the table reuses its row, so the same type name always occupies one row.
// Two rows for one name would make the bridge create two different named atoms and
// the engine could not judge them equivalent.
// Probing, load-factor checks, rehash replay, and re-probe before insert are in
// checker.cr. init_types sets cap to 0, so the table rebuilds lazily when the type
// table resets and row numbers are reused.
g_named_dedup : string, mut
g_named_dedup_cap : int, mut
g_named_dedup_count : int, mut

// Per-row cache of expanded terms. Open addressing, 16 bytes per entry
// {ti, expanded_term}. It has the same key space as g_term_map but different values:
// this table stores structural terms (struct to AK_PRODUCT, enum to AK_SUM), while
// the bridge table stores nominal atoms. They must not share one table, because
// expanded terms entering equivalence checks would make structurally equal but
// differently named types compare equal.
// Its lifecycle matches g_term_map: init_types resets cap to 0 and the table
// rebuilds lazily. ty_shadow.cr owns probing and rehash replay.
g_unf_map : string, mut
g_unf_map_cap : int, mut
g_unf_entries : int, mut
g_unf_hits : int, mut

// Generic instance to source mapping. Each entry is 24 bytes
// {src_fi, type_args_ni, inst_fi}, with the same layout as g_gen_instances in
// monomorph.cr. gen_create_instance appends an entry, and compute_all_purity reads
// it to fill the purity of the generic source function from its instances.
// This table must be declared here because checker.cr uses it and bootstrap name
// resolution does not allow forward references across files. Grow helpers live in
// monomorph.cr, where function forward references are allowed.
g_purity_inst : string, mut
g_purity_inst_count : int, mut
g_purity_inst_cap : int, mut

// The old fallback counters g_replace_unknown and g_replace_bridge were removed.
// Unknown judgments now report EC_ICE_TY_INDET; see ty_indeterminate_report in
// checker.cr.

fn grow_plugin_tags(needed: int):
    if needed < g_plugin_tag_cap:
        return
    ncap : ., mut = g_plugin_tag_cap * 2
    if ncap < 8:
        ncap = 8
    if ncap < needed:
        ncap = needed + 8
    nb := alloc(ncap * 24)
    cell_copy(g_plugin_tags, g_plugin_tag_cap * 24, nb)
    g_plugin_tags = nb
    g_plugin_tag_cap = ncap

fn grow_plugin_rtypes(needed: int):
    if needed < g_plugin_rtype_cap:
        return
    ncap : ., mut = g_plugin_rtype_cap * 2
    if ncap < 8:
        ncap = 8
    if ncap < needed:
        ncap = needed + 8
    nb := alloc(ncap * 24)
    cell_copy(g_plugin_rtypes, g_plugin_rtype_cap * 24, nb)
    g_plugin_rtypes = nb
    g_plugin_rtype_cap = ncap

fn find_plugin_entry(table: string, count: int, name_ni: int, ns_ni: int) -> int:
    if count <= 0:
        return -1
    // Linear scan: match (ns, name) pair
    i : ., mut = 0
    loop:
        if i >= count:
            break
        if cell_load(table, i*24+8) == name_ni && cell_load(table, i*24) == ns_ni:
            return i
        if cell_load(table, i*24+8) == name_ni && ns_ni < 0 && cell_load(table, i*24) < 0:
            return i
        i = i + 1
    return -1

fn register_plugin_tag(ns_ni: int, name_ni: int, data: int) -> int:
    // Conflict: same (ns, name) can't be registered twice
    if find_plugin_entry(g_plugin_tags, g_plugin_tag_count, name_ni, ns_ni) >= 0:
        return -2
    // Plugin with namespace can't shadow an unqualified entry
    if ns_ni >= 0 && find_plugin_entry(g_plugin_tags, g_plugin_tag_count, name_ni, -1) >= 0:
        return -3
    grow_plugin_tags(g_plugin_tag_count + 1)
    cell_store(g_plugin_tags, g_plugin_tag_count*24, ns_ni)
    cell_store(g_plugin_tags, g_plugin_tag_count*24+8, name_ni)
    cell_store(g_plugin_tags, g_plugin_tag_count*24+16, data)
    g_plugin_tag_count = g_plugin_tag_count + 1
    return 0

fn register_plugin_rtype(ns_ni: int, name_ni: int, data: int) -> int:
    if find_plugin_entry(g_plugin_rtypes, g_plugin_rtype_count, name_ni, ns_ni) >= 0:
        return -2
    if ns_ni >= 0 && find_plugin_entry(g_plugin_rtypes, g_plugin_rtype_count, name_ni, -1) >= 0:
        return -3
    grow_plugin_rtypes(g_plugin_rtype_count + 1)
    cell_store(g_plugin_rtypes, g_plugin_rtype_count*24, ns_ni)
    cell_store(g_plugin_rtypes, g_plugin_rtype_count*24+8, name_ni)
    cell_store(g_plugin_rtypes, g_plugin_rtype_count*24+16, data)
    g_plugin_rtype_count = g_plugin_rtype_count + 1
    return 0

// Reset frontend state for repeated checks in one process, such as LSP requests.
// Counts are cleared and capacities are kept for buffer reuse. The string table and
// its hash table are not reset. This complements the resets inside tokenize,
// res_imports, parse_all, and check_all, and removes stale diagnostics when a parse
// failure skips check_all. g_open_docs persists across checks and is not cleared.
fn reset_frontend_state():
    g_token_count = 0
    g_ast_count = 0
    g_error_count = 0
    g_diag_count = 0
    g_block_stmt_count = 0
    g_func_count = 0
    g_struct_count = 0
    g_enum_count = 0
    g_sym_count = 0
    g_type_count = 0
    g_iface_count = 0
    g_impl_for_count = 0
    g_method_count = 0
    g_type_alias_count = 0
    g_generic_constr_count = 0
    g_gen_param_count = 0
    // These side tables share the declaration-table lifetime. Struct, enum, and
    // call-site indexes are reused across compilations, so stale rows must be
    // cleared.
    g_sgen_constr_count = 0
    g_egen_constr_count = 0
    g_gen_binds_count = 0
    // Shape entries share the declaration-table lifetime. Registered names are
    // interned indexes reused across compilations; stale entries must be cleared.
    // The string table itself is not reset.
    g_iface_shape_count = 0
    // Spec annotations share the declaration-table lifetime. Function name and AST
    // indexes are reused across compilations, so stale rows must be cleared.
    g_spec_count = 0
    g_global_let_count = 0
    g_loop_depth = 0
    g_scope_depth = 0
    g_borrow_count = 0
    g_holder_count = 0
    g_borrow_scope_depth = 0
    g_gen_map_count = 0
    g_infer_name_seq = 0
    g_dyn_type_set_count = 0
    g_mod_func_count = 0
    g_mod_path_count = 0
    g_file_count = 0
    g_mod_count = 0
    // The purity instance table shares g_func_count's lifetime. Function indexes are
    // reused, so stale mappings must be cleared.
    g_purity_inst_count = 0
    g_df_state_finalized = 0   // state chain is rebuilt once per compilation
    g_seg_count = 0
    g_line_count = 0
    g_unsafe_depth = 0
    g_alloc_pts_cap = 0
    g_checker_current_fi = 0
