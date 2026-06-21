// === globals.cr ===
// ALL arrays are dynamic byte buffers (grow as needed, no MAX_* limits).

// String table (dynamic byte buffer containing `string` pointers)
g_strs : string, mut;            g_str_count : int, mut;     g_str_cap : int, mut;

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
g_home_dir : string, mut = "";      // cached HOME dir for SO index lookup

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
g_x86_rodataref_count : int, mut;       g_x86_rodataref_cap : int, mut;
g_x86_is_global : string, mut;          g_x86_global_cnt : int, mut;    g_x86_global_cap : int, mut;
g_x86_global_off : string, mut;         g_x86_global_off_cnt : int, mut; g_x86_global_off_cap : int, mut;
g_x86_func_offsets : string, mut;       g_x86_func_offsets_cap : int, mut; g_x86_func_off_count : int, mut;
g_x86_emit_vars : string, mut;          g_x86_emit_vars_cap : int, mut; g_x86_emit_var_count : int, mut; g_x86_emit_stack_size : int, mut;
g_x86_ret_patch_pos : string, mut;      g_x86_ret_patch_cap : int, mut; g_x86_ret_patch_count : int, mut;
g_x86_call_patch_pos : string, mut;     g_x86_call_patch_name : string, mut;
g_x86_call_patch_count : int, mut;      g_x86_call_patch_cap : int, mut;
g_x86_sub_rsp_pos : int, mut;
g_x86_alloc_patch_pos : string, mut;    g_x86_alloc_patch_cap : int, mut; g_x86_alloc_patch_count : int, mut;
