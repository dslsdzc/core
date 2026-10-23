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
// Tag area for potentially multiword int variables, appended to the stack frame.
// g_x86_mw_tag_off maps a function-local variable to its tag byte offset: an i64
// array indexed by v - var_start, with negative rbp-relative offsets; -1 means not
// tagged. g_x86_mw_tag_count is the number of tagged variables in the current
// function, one tag byte each. See the multiword backend design documents.
g_x86_mw_tag_off : string, mut
g_x86_mw_tag_off_cap : int, mut
g_x86_mw_tag_count : int, mut
// Overflow-jump sites for tagged int add and sub fast paths. emit_instr records each
// jo site. At the end of the function, frame.cr emits the 2-limb slow block and
// patches the recorded sites.
// Four parallel i64 arrays share one capacity and grow together. Index is site
// order, which is instruction order; one instruction has at most one site:
//   g_x86_mw_jo_pos: absolute jo position; rel32 is at pos+2 and jo is 6 bytes.
//   g_x86_mw_jo_dest: destination var index for the fast-path store. The slot form
//     is computed at block emission, so register-allocated forms need no extra
//     record.
//   g_x86_mw_jo_is_sub: 1 for sub. The high-limb correction differs: for add it is
//     CF ? -1 : 0; for sub it is CF ? 0 : -1. See e2_mw_slow_block in tag2l.cr.
//   g_x86_mw_jo_resume: absolute instruction after the fast-path store, where the
//     slow block jumps back. elf.cr fills it once the instruction is emitted.
g_x86_mw_jo_pos : string, mut
g_x86_mw_jo_cap : int, mut
g_x86_mw_jo_count : int, mut
g_x86_mw_jo_dest : string, mut
g_x86_mw_jo_is_sub : string, mut
g_x86_mw_jo_resume : string, mut
// Tag-check sites for consumers of tagged operands. Add, sub, and comparison fast
// paths first emit a tag check (test byte + jne rel32; tag=1 means a 2-limb
// operand). The jne target is the function's 2-limb block, whose position is known
// only at the end, so it is patched like the jo sites.
// Eight parallel i64 arrays share one capacity; index is site order, which is
// instruction order:
//   g_x86_mw_oc_pos1/pos2: absolute positions of the first and second check jne,
//     or -1 when absent (operand untagged, or s1 == s2).
//   g_x86_mw_oc_s1/s2/dest: operand rows and destination; slot forms are computed
//     at block emission.
//   g_x86_mw_oc_op: OP_ADD/OP_SUB select the arithmetic block; OP_EQ..OP_GE select
//     the comparison block.
//   g_x86_mw_oc_resume: instruction end, where the block jumps back.
// See e2_mw_opnd_block in tag2l.cr.
g_x86_mw_oc_pos1 : string, mut
g_x86_mw_oc_pos2 : string, mut
g_x86_mw_oc_cap : int, mut
g_x86_mw_oc_count : int, mut
g_x86_mw_oc_s1 : string, mut
g_x86_mw_oc_s2 : string, mut
g_x86_mw_oc_dest : string, mut
g_x86_mw_oc_op : string, mut
g_x86_mw_oc_resume : string, mut
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
