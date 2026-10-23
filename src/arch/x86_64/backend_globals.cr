// === backend_globals.cr ===
// x86-64 backend state. Loaded only by corearch.

// Interned names for the syscall builtins resolved by the backend.
g_ni_syscall3 : int, mut
g_ni_syscall4 : int, mut

// IR variable index to shared stack slot variable (-1 = own slot).
g_stack_map : string, mut

// Backend arrays (all dynamic byte buffers)
g_x86_str_offs : string, mut
g_x86_str_count : int, mut
g_x86_str_cap : int, mut
g_x86_ext_rel_pos : string, mut
g_x86_ext_rel_name : string, mut
g_x86_ext_rel_count : int, mut
g_x86_ext_rel_cap : int, mut

g_x86_rip_patch_pos : string, mut
g_x86_rip_patch_globals : string, mut
g_x86_rip_patch_count : int, mut
g_x86_rip_patch_cap : int, mut
g_x86_vars : string, mut
g_x86_var_count : int, mut
g_x86_var_cap : int, mut
g_x86_stack_size : int, mut
g_x86_func_idx : int, mut
g_x86_is_enum : string, mut
g_x86_is_enum_count : int, mut
g_x86_is_enum_cap : int, mut
g_x86_rodataref_pos : string, mut
g_x86_rodataref_ro : string, mut
g_x86_func_cp : string, mut
g_x86_func_cp_cap : int, mut
g_x86_func_code_sz : string, mut
g_x86_func_code_sz_cap : int, mut
g_x86_rodataref_count : int, mut
g_x86_rodataref_cap : int, mut
g_x86_is_global : string, mut
g_x86_global_cnt : int, mut
g_x86_global_cap : int, mut
g_x86_global_off : string, mut
g_x86_global_off_cnt : int, mut
g_x86_global_off_cap : int, mut
g_x86_func_offsets : string, mut
g_x86_func_offsets_cap : int, mut
g_x86_func_off_count : int, mut
g_x86_emit_vars : string, mut
g_x86_emit_vars_cap : int, mut
g_x86_emit_var_count : int, mut
g_x86_emit_stack_size : int, mut
g_x86_ret_patch_pos : string, mut
g_x86_ret_patch_cap : int, mut
g_x86_ret_patch_count : int, mut
g_x86_call_patch_pos : string, mut
g_x86_call_patch_name : string, mut
g_x86_call_patch_count : int, mut
g_x86_call_patch_cap : int, mut
g_x86_fnaddr_patch_pos : string, mut
g_x86_fnaddr_patch_name : string, mut
g_x86_fnaddr_patch_count : int, mut
g_x86_fnaddr_patch_cap : int, mut
g_x86_sub_rsp_pos : int, mut
g_x86_alloc_patch_pos : string, mut
g_x86_alloc_patch_cap : int, mut
g_x86_alloc_patch_count : int, mut
g_x86_emit_rt_stubs : int, mut         // 1 = pure-static: backend emits g_set_curg/g_get_curg stubs
// Count of IR_MATCH nodes that actually entered e2_emit_match_binary. This is a
// verification counter, not a strategy predicate: a scratch-only emitter pass in
// --dump-match-plan and the real Phase 3 emission both increment it.
g_match_bin_emits : int, mut
// --big-int: user int slots hold tagged values (immediate v*2 or BigInt pointer+1).
// The compiler itself and the BigInt runtime blob stay raw.  See int_rep.cr.
g_x86_big_enabled : int, mut
g_x86_big_blob_start : int, mut
g_x86_big_exit_call_pos : int, mut
