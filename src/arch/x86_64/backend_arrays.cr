// === backend_arrays.cr ===
// Growth functions for x86-64 backend arrays. Loaded only by corearch.

fn grow_x86_vars(needed: int):
    if needed < g_x86_var_cap:
        return
    nc : ., mut = g_x86_var_cap * 2
    if nc < 128:
        nc = 128
    if nc < needed:
        nc = needed + 128
    nb := alloc(nc * 8)
    _dyncpy(g_x86_vars, g_x86_var_cap * 8, nb)
    g_x86_vars = nb
    g_x86_var_cap = nc

fn grow_is_enum(needed: int):
    if needed < g_x86_is_enum_cap:
        return
    nc : ., mut = g_x86_is_enum_cap * 2
    if nc < 128:
        nc = 128
    if nc < needed:
        nc = needed + 128
    nb := alloc(nc * 8)
    _dyncpy(g_x86_is_enum, g_x86_is_enum_cap * 8, nb)
    g_x86_is_enum = nb
    g_x86_is_enum_cap = nc

fn grow_is_global(needed: int):
    if needed < g_x86_global_cap:
        return
    nc : ., mut = g_x86_global_cap * 2
    if nc < 128:
        nc = 128
    if nc < needed:
        nc = needed + 128
    nb := alloc(nc * 8)
    _dyncpy(g_x86_is_global, g_x86_global_cap * 8, nb)
    g_x86_is_global = nb
    g_x86_global_cap = nc

fn grow_global_off(needed: int):
    if needed < g_x86_global_off_cap:
        return
    nc : ., mut = g_x86_global_off_cap * 2
    if nc < 128:
        nc = 128
    if nc < needed:
        nc = needed + 128
    nb := alloc(nc * 8)
    _dyncpy(g_x86_global_off, g_x86_global_off_cap * 8, nb)
    g_x86_global_off = nb
    g_x86_global_off_cap = nc

fn grow_str_offs(needed: int):
    if needed < g_x86_str_cap:
        return
    nc : ., mut = g_x86_str_cap * 2
    if nc < 64:
        nc = 64
    if nc < needed:
        nc = needed + 64
    nb := alloc(nc * 8)
    _dyncpy(g_x86_str_offs, g_x86_str_cap * 8, nb)
    g_x86_str_offs = nb
    g_x86_str_cap = nc

fn grow_rip_patch(needed: int):
    if needed < g_x86_rip_patch_cap:
        return
    nc : ., mut = g_x86_rip_patch_cap * 2
    if nc < 128:
        nc = 128
    if nc < needed:
        nc = needed + 128
    nb1 := alloc(nc * 8)
    _dyncpy(g_x86_rip_patch_pos, g_x86_rip_patch_cap * 8, nb1)
    g_x86_rip_patch_pos = nb1
    nb2 := alloc(nc * 8)
    _dyncpy(g_x86_rip_patch_globals, g_x86_rip_patch_cap * 8, nb2)
    g_x86_rip_patch_globals = nb2
    g_x86_rip_patch_cap = nc

// .so extension index side tables. They grow dynamically, following the rule that
// all arrays are dynamic byte buffers with no fixed limits.

fn grow_ext_rel(needed: int):
    if needed < g_x86_ext_rel_cap:
        return
    nc : ., mut = g_x86_ext_rel_cap * 2
    if nc < 32:
        nc = 32
    if nc < needed:
        nc = needed + 32
    sz := nc * 8
    n1 := alloc(sz)
    _dyncpy(g_x86_ext_rel_pos, g_x86_ext_rel_cap*8, n1)
    g_x86_ext_rel_pos = n1
    n2 := alloc(sz)
    _dyncpy(g_x86_ext_rel_name, g_x86_ext_rel_cap*8, n2)
    g_x86_ext_rel_name = n2
    g_x86_ext_rel_cap = nc

fn grow_func_offsets(needed: int):
    if needed < g_x86_func_offsets_cap:
        return
    nc : ., mut = g_x86_func_offsets_cap * 2
    if nc < 64:
        nc = 64
    if nc < needed:
        nc = needed + 64
    nb := alloc(nc * 16)
    _dyncpy(g_x86_func_offsets, g_x86_func_offsets_cap * 16, nb)
    g_x86_func_offsets = nb
    g_x86_func_offsets_cap = nc

fn grow_emit_vars(needed: int):
    if needed < g_x86_emit_vars_cap:
        return
    nc : ., mut = g_x86_emit_vars_cap * 2
    if nc < 128:
        nc = 128
    if nc < needed:
        nc = needed + 128
    nb := alloc(nc * 8)
    _dyncpy(g_x86_emit_vars, g_x86_emit_vars_cap * 8, nb)
    g_x86_emit_vars = nb
    g_x86_emit_vars_cap = nc

fn grow_ret_patch(needed: int):
    if needed < g_x86_ret_patch_cap:
        return
    nc : ., mut = g_x86_ret_patch_cap * 2
    if nc < 64:
        nc = 64
    if nc < needed:
        nc = needed + 64
    nb := alloc(nc * 8)
    _dyncpy(g_x86_ret_patch_pos, g_x86_ret_patch_cap * 8, nb)
    g_x86_ret_patch_pos = nb
    g_x86_ret_patch_cap = nc

fn grow_call_patch(needed: int):
    if needed < g_x86_call_patch_cap:
        return
    nc : ., mut = g_x86_call_patch_cap * 2
    if nc < 64:
        nc = 64
    if nc < needed:
        nc = needed + 64
    n1 := alloc(nc * 8)
    _dyncpy(g_x86_call_patch_pos, g_x86_call_patch_cap * 8, n1)
    g_x86_call_patch_pos = n1
    n2 := alloc(nc * 8)
    _dyncpy(g_x86_call_patch_name, g_x86_call_patch_cap * 8, n2)
    g_x86_call_patch_name = n2
    g_x86_call_patch_cap = nc

fn grow_fnaddr_patch(needed: int):
    if needed < g_x86_fnaddr_patch_cap:
        return
    nc : ., mut = g_x86_fnaddr_patch_cap * 2
    if nc < 64:
        nc = 64
    if nc < needed:
        nc = needed + 64
    n1 := alloc(nc * 8)
    _dyncpy(g_x86_fnaddr_patch_pos, g_x86_fnaddr_patch_cap * 8, n1)
    g_x86_fnaddr_patch_pos = n1
    n2 := alloc(nc * 8)
    _dyncpy(g_x86_fnaddr_patch_name, g_x86_fnaddr_patch_cap * 8, n2)
    g_x86_fnaddr_patch_name = n2
    g_x86_fnaddr_patch_cap = nc

fn grow_func_cp(needed: int):
    if needed < g_x86_func_cp_cap:
        return
    nc : ., mut = g_x86_func_cp_cap * 2
    if nc < 64:
        nc = 64
    if nc < needed:
        nc = needed + 64
    nb := alloc(nc * 8)
    _dyncpy(g_x86_func_cp, g_x86_func_cp_cap * 8, nb)
    g_x86_func_cp = nb
    g_x86_func_cp_cap = nc

fn grow_mw_tag_off(needed: int):
    if needed < g_x86_mw_tag_off_cap:
        return
    nc : ., mut = g_x86_mw_tag_off_cap * 2
    if nc < 128:
        nc = 128
    if nc < needed:
        nc = needed + 128
    nb := alloc(nc * 8)
    _dyncpy(g_x86_mw_tag_off, g_x86_mw_tag_off_cap * 8, nb)
    g_x86_mw_tag_off = nb
    g_x86_mw_tag_off_cap = nc

fn grow_mw_jo_patch(needed: int):
    if needed < g_x86_mw_jo_cap:
        return
    nc : ., mut = g_x86_mw_jo_cap * 2
    if nc < 64:
        nc = 64
    if nc < needed:
        nc = needed + 64
    nb := alloc(nc * 8)
    _dyncpy(g_x86_mw_jo_pos, g_x86_mw_jo_cap * 8, nb)
    g_x86_mw_jo_pos = nb
    nb2 := alloc(nc * 8)
    _dyncpy(g_x86_mw_jo_dest, g_x86_mw_jo_cap * 8, nb2)
    g_x86_mw_jo_dest = nb2
    nb3 := alloc(nc * 8)
    _dyncpy(g_x86_mw_jo_is_sub, g_x86_mw_jo_cap * 8, nb3)
    g_x86_mw_jo_is_sub = nb3
    nb4 := alloc(nc * 8)
    _dyncpy(g_x86_mw_jo_resume, g_x86_mw_jo_cap * 8, nb4)
    g_x86_mw_jo_resume = nb4
    g_x86_mw_jo_cap = nc

fn grow_mw_oc_patch(needed: int):
    if needed < g_x86_mw_oc_cap:
        return
    nc : ., mut = g_x86_mw_oc_cap * 2
    if nc < 64:
        nc = 64
    if nc < needed:
        nc = needed + 64
    nb := alloc(nc * 8)
    _dyncpy(g_x86_mw_oc_pos1, g_x86_mw_oc_cap * 8, nb)
    g_x86_mw_oc_pos1 = nb
    nb2 := alloc(nc * 8)
    _dyncpy(g_x86_mw_oc_pos2, g_x86_mw_oc_cap * 8, nb2)
    g_x86_mw_oc_pos2 = nb2
    nb3 := alloc(nc * 8)
    _dyncpy(g_x86_mw_oc_s1, g_x86_mw_oc_cap * 8, nb3)
    g_x86_mw_oc_s1 = nb3
    nb4 := alloc(nc * 8)
    _dyncpy(g_x86_mw_oc_s2, g_x86_mw_oc_cap * 8, nb4)
    g_x86_mw_oc_s2 = nb4
    nb5 := alloc(nc * 8)
    _dyncpy(g_x86_mw_oc_dest, g_x86_mw_oc_cap * 8, nb5)
    g_x86_mw_oc_dest = nb5
    nb6 := alloc(nc * 8)
    _dyncpy(g_x86_mw_oc_op, g_x86_mw_oc_cap * 8, nb6)
    g_x86_mw_oc_op = nb6
    nb7 := alloc(nc * 8)
    _dyncpy(g_x86_mw_oc_resume, g_x86_mw_oc_cap * 8, nb7)
    g_x86_mw_oc_resume = nb7
    g_x86_mw_oc_cap = nc

fn grow_func_code_sz(needed: int):
    if needed < g_x86_func_code_sz_cap:
        return
    nc : ., mut = g_x86_func_code_sz_cap * 2
    if nc < 64:
        nc = 64
    if nc < needed:
        nc = needed + 64
    nb := alloc(nc * 8)
    _dyncpy(g_x86_func_code_sz, g_x86_func_code_sz_cap * 8, nb)
    g_x86_func_code_sz = nb
    g_x86_func_code_sz_cap = nc

fn grow_rodataref(needed: int):
    if needed < g_x86_rodataref_cap:
        return
    nc : ., mut = g_x86_rodataref_cap * 2
    if nc < 64:
        nc = 64
    if nc < needed:
        nc = needed + 64
    n1 := alloc(nc * 8)
    _dyncpy(g_x86_rodataref_pos, g_x86_rodataref_cap * 8, n1)
    g_x86_rodataref_pos = n1
    n2 := alloc(nc * 8)
    _dyncpy(g_x86_rodataref_ro, g_x86_rodataref_cap * 8, n2)
    g_x86_rodataref_ro = n2
    g_x86_rodataref_cap = nc

fn grow_alloc_patch(needed: int):
    if needed < g_x86_alloc_patch_cap:
        return
    nc : ., mut = g_x86_alloc_patch_cap * 2
    if nc < 64:
        nc = 64
    if nc < needed:
        nc = needed + 64
    nb := alloc(nc * 8)
    _dyncpy(g_x86_alloc_patch_pos, g_x86_alloc_patch_cap * 8, nb)
    g_x86_alloc_patch_pos = nb
    g_x86_alloc_patch_cap = nc
