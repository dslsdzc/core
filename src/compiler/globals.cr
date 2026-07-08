// === globals.cr ===
// ALL arrays are dynamic byte buffers (grow as needed, no MAX_* limits).

// String table (dynamic byte buffer containing `string` pointers)
g_strs : string, mut;            g_str_count : int, mut;     g_str_cap : int, mut;

// String interning hash table: maps hash → g_strs index (-1 = empty slot)
// Open addressing with linear probing.
g_str_hash : string, mut;        g_str_hash_cap : int, mut;

// Dynamic byte buffers (all arrays, no MAX_* limits)
g_funcs : string, mut;       g_func_count : int, mut;     g_func_cap : int, mut;
g_structs : string, mut;     g_struct_count : int, mut;   g_struct_cap : int, mut;
g_enums : string, mut;       g_enum_count : int, mut;     g_enum_cap : int, mut;
g_syms : string, mut;        g_sym_count : int, mut;     g_sym_cap : int, mut;
g_types : string, mut;       g_type_count : int, mut;     g_type_cap : int, mut;
g_ast : string, mut;         g_ast_count : int, mut;     g_ast_cap : int, mut;
g_tokens : string, mut;      g_token_count : int, mut;   g_tok_cap : int, mut;
g_errors : string, mut;      g_error_count : int, mut;   g_err_cap : int, mut;
g_block_stmts : string, mut; g_block_stmt_count : int, mut; g_block_stmt_cap : int, mut;
g_ir_vars : string, mut;     g_ir_var_count : int, mut;  g_ir_var_cap : int, mut;
g_ir_instrs : string, mut;   g_ir_instr_count : int, mut; g_ir_instr_cap : int, mut;
g_ir_locals : string, mut;   g_ir_local_count : int, mut; g_ir_local_cap : int, mut;
g_ir_globals : string, mut;  g_ir_global_count : int, mut; g_ir_global_cap : int, mut;
g_ir_str_consts : string, mut; g_ir_str_const_count : int, mut; g_ir_str_const_cap : int, mut;

// Parser/checker dynamic arrays (shared between corec and corearch builds)
g_global_lets : string, mut;         g_global_let_count : int, mut;     g_global_lets_cap : int, mut;
g_loop_stack : string, mut;          g_loop_depth : int, mut;           g_loop_stack_cap : int, mut;
g_type_aliases : string, mut;        g_type_alias_count : int, mut;     g_type_alias_cap : int, mut;
g_methods : string, mut;             g_method_count : int, mut;         g_method_cap : int, mut;
g_scope_bounds : string, mut;        g_scope_depth : int, mut;          g_scope_bounds_cap : int, mut;
g_borrow_scope_markers : string, mut; g_borrow_scope_depth : int, mut;  g_borrow_scope_markers_cap : int, mut;

// Interface system
g_ifaces : string, mut;          g_iface_count : int, mut;     g_iface_cap : int, mut;
g_impl_for : string, mut;        g_impl_for_count : int, mut;  g_impl_for_cap : int, mut;
g_generic_constr : string, mut;  g_generic_constr_count : int, mut; g_generic_constr_cap : int, mut;
g_checker_current_fi : int, mut;
g_borrow_vars : string, mut;          g_borrow_refs : string, mut;       g_borrow_muts : string, mut;
g_borrow_count : int, mut;            g_borrow_cap : int, mut;
g_holder_borrowers : string, mut;     g_holder_borrowed : string, mut;   g_holder_is_mut : string, mut;
g_holder_count : int, mut;            g_holder_cap : int, mut;
g_gen_map_names : string, mut;        g_gen_map_types : string, mut;
g_gen_map_count : int, mut;           g_gen_map_cap : int, mut;
g_stack_map : string, mut;  // IR var index → shared stack slot var (-1 = own slot), set by allocator
g_home_dir : string, mut;           // cached HOME dir for SO index lookup
g_home_dir_ok : int, mut;           // 1 = g_home_dir initialized

g_ir_func_name_idx : string, mut;   g_ir_func_name_idx_cap : int, mut;
g_ir_func_ret_type : string, mut;   g_ir_func_ret_type_cap : int, mut;
g_ir_func_instr_start : string, mut; g_ir_func_instr_start_cap : int, mut;
g_ir_func_instr_count : string, mut; g_ir_func_instr_count_cap : int, mut;
g_ir_func_var_start : string, mut;  g_ir_func_var_start_cap : int, mut;
g_ir_func_var_count : string, mut;  g_ir_func_var_count_cap : int, mut;
g_ir_func_param_count : string, mut; g_ir_func_param_count_cap : int, mut;
g_ir_func_count : int, mut;

// Module system arrays (dynamic byte buffers)
g_diags : string, mut;           g_diag_count : int, mut;     g_diag_cap : int, mut;
g_files : string, mut;           g_file_count : int, mut;     g_file_cap : int, mut;
g_mods : string, mut;            g_mod_count : int, mut;      g_mod_cap : int, mut;
g_mod_func_fileids : string, mut; g_mod_func_names : string, mut;
g_mod_func_tis : string, mut;    g_mod_func_count : int, mut; g_mod_func_cap : int, mut;
g_mod_path_names : string, mut;  g_mod_path_count : int, mut; g_mod_path_cap : int, mut;

// Dynamic stacks (byte buffers)
g_ir_local_scopes : string, mut;    g_ir_local_scopes_cap : int, mut;
g_ir_local_depth : int, mut;
g_ir_loop_header : string, mut;     g_ir_loop_exit : string, mut;
g_ir_loop_depth : int, mut;         g_ir_loop_stacks_cap : int, mut;
g_label_poses : string, mut;        g_label_cap : int, mut;
g_label_count : int, mut;
// Pre-computed interned string indices for builtin function name matching
g_ni_syscall3 : int, mut;  g_ni_load8 : int, mut;  g_ni_store8 : int, mut;
g_ni_load64 : int, mut;    g_ni_load_str_ptr : int, mut;
g_ni_store_str_ptr : int, mut;  g_ni_get_arg : int, mut;
g_ni_w64 : int, mut;  g_ni_dyncpy : int, mut;
// Single-pass backpatching: pending forward jumps
g_pending_pos : string, mut;        // rel32 buffer positions to patch
g_pending_label : string, mut;      // target label indices
g_pending_count : int, mut;         g_pending_cap : int, mut;
g_next_label : int, mut;

// Backend arrays (all dynamic byte buffers)
g_x86_str_offs : string, mut;           g_x86_str_count : int, mut;     g_x86_str_cap : int, mut;
g_x86_ext_rel_pos : string, mut;        g_x86_ext_rel_name : string, mut;
g_x86_ext_rel_count : int, mut;         g_x86_ext_rel_cap : int, mut;
g_x86_rip_patch_pos : string, mut;      g_x86_rip_patch_globals : string, mut;
g_x86_rip_patch_count : int, mut;       g_x86_rip_patch_cap : int, mut;
g_x86_vars : string, mut;               g_x86_var_count : int, mut;     g_x86_var_cap : int, mut;
g_x86_stack_size : int, mut;            g_x86_func_idx : int, mut;
g_x86_is_enum : string, mut;            g_x86_is_enum_count : int, mut; g_x86_is_enum_cap : int, mut;
g_x86_rodataref_pos : string, mut;       g_x86_rodataref_ro : string, mut;
g_x86_func_cp : string, mut;            g_x86_func_cp_cap : int, mut;
g_x86_func_code_sz : string, mut;       g_x86_func_code_sz_cap : int, mut;
g_x86_rodataref_count : int, mut;       g_x86_rodataref_cap : int, mut;
g_x86_is_global : string, mut;
g_x86_global_cnt : int, mut;
g_x86_global_cap : int, mut;
g_x86_global_off : string, mut;         g_x86_global_off_cnt : int, mut; g_x86_global_off_cap : int, mut;
g_x86_func_offsets : string, mut;       g_x86_func_offsets_cap : int, mut; g_x86_func_off_count : int, mut;
g_x86_emit_vars : string, mut;          g_x86_emit_vars_cap : int, mut; g_x86_emit_var_count : int, mut; g_x86_emit_stack_size : int, mut;
g_x86_ret_patch_pos : string, mut;      g_x86_ret_patch_cap : int, mut; g_x86_ret_patch_count : int, mut;
g_x86_call_patch_pos : string, mut;     g_x86_call_patch_name : string, mut;
g_x86_call_patch_count : int, mut;      g_x86_call_patch_cap : int, mut;
g_x86_sub_rsp_pos : int, mut;
g_x86_alloc_patch_pos : string, mut;    g_x86_alloc_patch_cap : int, mut; g_x86_alloc_patch_count : int, mut;
// Optimization levels and metadata (extensible key-value store)
g_opt_level : int, mut;     // 0=none, 1=regalloc, 2=stackshare, 3=cse
g_opt_meta : string, mut;   // metadata buffer for .ccr v3+
g_opt_meta_count : int, mut;

// Plugin extension registry: tags and return types from .so/stdlib plugins
// Each entry: 24 bytes = [ns_ni, name_ni, data_ni]
g_plugin_tags : string, mut;   g_plugin_tag_count : int, mut;   g_plugin_tag_cap : int, mut;
g_plugin_rtypes : string, mut; g_plugin_rtype_count : int, mut; g_plugin_rtype_cap : int, mut;

fn grow_plugin_tags(needed: int) {
    if needed < g_plugin_tag_cap { return; }
    ncap : ., mut = g_plugin_tag_cap * 2; if ncap < 8 { ncap = 8; } if ncap < needed { ncap = needed + 8; }
    nb := alloc(ncap * 24); _dyncpy(g_plugin_tags, g_plugin_tag_cap * 24, nb); g_plugin_tags = nb; g_plugin_tag_cap = ncap; }

fn grow_plugin_rtypes(needed: int) {
    if needed < g_plugin_rtype_cap { return; }
    ncap : ., mut = g_plugin_rtype_cap * 2; if ncap < 8 { ncap = 8; } if ncap < needed { ncap = needed + 8; }
    nb := alloc(ncap * 24); _dyncpy(g_plugin_rtypes, g_plugin_rtype_cap * 24, nb); g_plugin_rtypes = nb; g_plugin_rtype_cap = ncap; }

fn find_plugin_entry(table: string, count: int, name_ni: int, ns_ni: int) -> int {
    if count <= 0 { return -1; }
    // Linear scan: match (ns, name) pair
    i : ., mut = 0;
    loop { if i >= count { break; }
        if r64(table, i*24+8) == name_ni && r64(table, i*24) == ns_ni { return i; }
        if r64(table, i*24+8) == name_ni && ns_ni < 0 && r64(table, i*24) < 0 { return i; }
    i = i + 1; }
    return -1; }

fn register_plugin_tag(ns_ni: int, name_ni: int, data: int) -> int {
    // Conflict: same (ns, name) can't be registered twice
    if find_plugin_entry(g_plugin_tags, g_plugin_tag_count, name_ni, ns_ni) >= 0 { return -2; }
    // Plugin with namespace can't shadow an unqualified entry
    if ns_ni >= 0 && find_plugin_entry(g_plugin_tags, g_plugin_tag_count, name_ni, -1) >= 0 { return -3; }
    grow_plugin_tags(g_plugin_tag_count + 1);
    w64(g_plugin_tags, g_plugin_tag_count*24, ns_ni);
    w64(g_plugin_tags, g_plugin_tag_count*24+8, name_ni);
    w64(g_plugin_tags, g_plugin_tag_count*24+16, data);
    g_plugin_tag_count = g_plugin_tag_count + 1;
    return 0; }

fn register_plugin_rtype(ns_ni: int, name_ni: int, data: int) -> int {
    if find_plugin_entry(g_plugin_rtypes, g_plugin_rtype_count, name_ni, ns_ni) >= 0 { return -2; }
    if ns_ni >= 0 && find_plugin_entry(g_plugin_rtypes, g_plugin_rtype_count, name_ni, -1) >= 0 { return -3; }
    grow_plugin_rtypes(g_plugin_rtype_count + 1);
    w64(g_plugin_rtypes, g_plugin_rtype_count*24, ns_ni);
    w64(g_plugin_rtypes, g_plugin_rtype_count*24+8, name_ni);
    w64(g_plugin_rtypes, g_plugin_rtype_count*24+16, data);
    g_plugin_rtype_count = g_plugin_rtype_count + 1;
    return 0; }
