// === globals.cr ===
// Shared global variable declarations for both corec and corearch.
// Must be included after ast.cr, before any file that uses these globals.

// String table
g_strs : [string; MAX_STRS], mut;
g_str_count : int, mut;

// Function/struct/enum tables
g_funcs : [FuncInfo; MAX_FUNCS], mut;
g_func_count : int, mut;
g_structs : [StructInfo; MAX_STRUCTS], mut;
g_struct_count : int, mut;
g_enums : [EnumInfo; MAX_ENUMS], mut;
g_enum_count : int, mut;

// IR data
g_ir_func_name_idx : [int; MAX_FUNCS], mut;
g_ir_func_ret_type : [int; MAX_FUNCS], mut;
g_ir_func_instr_start : [int; MAX_FUNCS], mut;
g_ir_func_instr_count : [int; MAX_FUNCS], mut;
g_ir_func_var_start : [int; MAX_FUNCS], mut;
g_ir_func_var_count : [int; MAX_FUNCS], mut;
g_ir_func_param_count : [int; MAX_FUNCS], mut;
g_ir_func_count : int, mut;
g_ir_vars : [IRVar; MAX_IREXPRS], mut;
g_ir_var_count : int, mut;
g_ir_instrs : [IRInstr; MAX_IRINSTRUCTIONS], mut;
g_ir_instr_count : int, mut;
g_ir_locals : [int; MAX_IREXPRS * 2], mut;
g_ir_local_count : int, mut;
g_ir_local_scopes : [int; MAX_SCOPES], mut;
g_ir_local_depth : int, mut;
g_ir_globals : [int; MAX_SYMS * 2], mut;
g_ir_global_count : int, mut;
g_next_label : int, mut;
g_ir_loop_header : [int; MAX_LOOPS], mut;
g_ir_loop_exit : [int; MAX_LOOPS], mut;
g_ir_loop_depth : int, mut;
g_ir_str_consts : [int; MAX_STRS], mut;
g_ir_str_const_count : int, mut;

// Label tracking for jump offset calculation (shared by elf.cr and interp.cr)
g_label_poses : [int; 32], mut;
g_label_count : int, mut;
