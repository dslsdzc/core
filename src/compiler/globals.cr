// === globals.cr ===
// ALL arrays are dynamic byte buffers (grow as needed, no MAX_* limits).

// String pool (replaces g_strs)
g_str_pool : string, mut;
g_str_pool_len : int, mut;
g_str_pool_cap : int, mut;
g_str_offsets : string, mut;
g_str_offsets_cap : int, mut;
g_str_count : int, mut;

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

g_ir_func_name_idx : string, mut;   g_ir_func_name_idx_cap : int, mut;
g_ir_func_ret_type : string, mut;   g_ir_func_ret_type_cap : int, mut;
g_ir_func_instr_start : string, mut; g_ir_func_instr_start_cap : int, mut;
g_ir_func_instr_count : string, mut; g_ir_func_instr_count_cap : int, mut;
g_ir_func_var_start : string, mut;  g_ir_func_var_start_cap : int, mut;
g_ir_func_var_count : string, mut;  g_ir_func_var_count_cap : int, mut;
g_ir_func_param_count : string, mut; g_ir_func_param_count_cap : int, mut;
g_ir_func_count : int, mut;

// Fixed-size stacks
g_ir_local_scopes : [int; 256], mut;
g_ir_local_depth : int, mut;
g_ir_loop_header : [int; 256], mut;
g_ir_loop_exit : [int; 256], mut;
g_ir_loop_depth : int, mut;
g_label_poses : [int; 32], mut;
g_label_count : int, mut;
g_next_label : int, mut;

// Backend arrays (still fixed size for now)
g_x86_str_offs : [int; MAX_STRS], mut;  g_x86_str_count : int, mut;
g_x86_ext_rel_pos : [int; 64], mut;     g_x86_ext_rel_name : [int; 64], mut;
g_x86_ext_rel_count : int, mut;
g_x86_rip_patch_pos : [int; 64], mut;   g_x86_rip_patch_globals : [int; 64], mut;
g_x86_rip_patch_count : int, mut;
g_x86_vars : [int; 32768], mut;         g_x86_var_count : int, mut;
g_x86_stack_size : int, mut;            g_x86_func_idx : int, mut;
g_x86_is_enum : [int; 32768], mut;      g_x86_is_enum_count : int, mut;
