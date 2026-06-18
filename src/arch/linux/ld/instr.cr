// ══════════════════════════════════════════════════════════════
// Binary emit interface — state + helpers + instr_size + emit_instr
// ══════════════════════════════════════════════════════════════

// State globals (set by caller before emit phase)
g_x86_rodata_base : int, mut;
g_x86_func_frame_start : int, mut;  // abs buf pos of current function body (after frame)


fn g2_init() {
    g_x86_emit_var_count = 0;
    g_x86_emit_stack_size = 0;
    g_x86_ret_patch_count = 0;
    g_x86_alloc_patch_count = 0;
    g_x86_ext_rel_count = 0;
    g_x86_rip_patch_count = 0;
}

fn g2_slot(v: int) -> int {
    // Register encoding: v < -500 means register, with reg = -(v+1000)-1
    if v < -500 { return v; }
    // Stack sharing: if this var maps to another, use that var's slot
    // g_stack_map is "" (0-length) when not allocated, which is safe to str_len
    if v >= 0 && str_len(g_stack_map) > v * 8 {
        mapped := r64(g_stack_map, v * 8);
        if mapped >= 0 && mapped != v { v = mapped; }
    }
    i := 0;
    loop { if i >= g_x86_emit_var_count { break; } if r64(g_x86_emit_vars, i * 8) == v { return -(i+1)*8; } i = i + 1; }
    dyn_grow_x86_emit_vars(g_x86_emit_var_count + 1);
    w64(g_x86_emit_vars, g_x86_emit_var_count * 8, v);
    g_x86_emit_var_count = g_x86_emit_var_count + 1;
    g_x86_emit_stack_size = g_x86_emit_var_count * 8;
    return -g_x86_emit_var_count * 8;
}

fn g2_str_off(si: int) -> int {
    o := 0; i := 0;
    loop { if i >= g_x86_str_count { break; } if r64(g_x86_str_offs, i * 8) == si { return o; } o = o + istr_len(r64(g_x86_str_offs, i * 8)) + 1; i = i + 1; }
    dyn_grow_x86_str_offs(g_x86_str_count + 1); w64(g_x86_str_offs, g_x86_str_count * 8, si); g_x86_str_count = g_x86_str_count + 1;
    return o;
}

fn g2_rodata_sz() -> int {
    o := 0; i := 0;
    loop { if i >= g_x86_str_count { break; } o = o + istr_len(r64(g_x86_str_offs, i * 8)) + 1; i = i + 1; }
    return o;
}

// ── Byte encoding helpers ──
fn e2_w8(buf: string, pos: int, val: int) { store8(buf, pos, val % 256); }
fn e2_w16(buf: string, off: int, val: int) { e2_w8(buf, off, val % 256); e2_w8(buf, off+1, (val/256) % 256); }
fn e2_w32(buf: string, pos: int, val: int) {
    uv : ., mut = val;
    if uv < 0 { uv = uv + 4294967296; }  // two's complement for negative rel32
    e2_w8(buf, pos, uv % 256); e2_w8(buf, pos+1, (uv/256) % 256);
    e2_w8(buf, pos+2, (uv/65536) % 256); e2_w8(buf, pos+3, (uv/16777216) % 256);
}
fn e2_w64(buf: string, pos: int, val: int) { e2_w32(buf, pos, val); e2_w32(buf, pos+4, val/4294967296); }

fn e2_mov(b: string, p: int, d: int, s: int) -> int {
    hd := 0; if d >= 8 { hd = 1; }
    hs := 0; if s >= 8 { hs = 1; }
    e2_w8(b, p, 72 + hs*4 + hd);
    e2_w8(b, p+1, 137);
    e2_w8(b, p+2, 192 + (s%8)*8 + (d%8));
    return 3;
}

fn e2_ld(b: string, p: int, r: int, o: int) -> int {
    // o < -500: load from register (reg = -(o+1000)-1)
    if o < -500 {
        src_reg := -(o + 1000) - 1;
        return e2_mov(b, p, r, src_reg);
    }
    h := 0; if r >= 8 { h = 1; }
    if o >= -128 && o <= 127 {
        e2_w8(b, p, 72 + h*4); e2_w8(b, p+1, 139);
        e2_w8(b, p+2, 64 + (r%8)*8 + 5); e2_w8(b, p+3, o); return 4;
    }
    // Large offset: use [rbp+disp32] (7 bytes)
    e2_w8(b, p, 72 + h*4); e2_w8(b, p+1, 139);
    e2_w8(b, p+2, 128 + (r%8)*8 + 5); e2_w32(b, p+3, o); return 7;
}

fn e2_mov_size(d: int, s: int) -> int { return 3; }
fn e2_ld_size(r: int, o: int) -> int { if o >= -128 && o <= 127 { return 4; } return 7; }
fn e2_st_size(r: int, o: int) -> int { if o >= -128 && o <= 127 { return 4; } return 7; }
fn e2_alu_size(op: int) -> int { return 3; }
fn e2_li_size(v: int) -> int { return 8; }
fn e2_lr_size(rel: int) -> int { return 7; }
fn e2_lrb_size(rel: int) -> int { return 7; }
fn e2_lb_size(r: int, o: int) -> int { return 4; }
fn e2_call_size(rel: int) -> int { return 5; }
fn e2_jmp_size(rel: int) -> int { return 5; }
fn e2_je_size(rel: int) -> int { return 6; }

fn e2_st(b: string, p: int, r: int, o: int) -> int {
    // o < -500: store to register (reg = -(o+1000)-1)
    if o < -500 {
        dst_reg := -(o + 1000) - 1;
        return e2_mov(b, p, dst_reg, r);
    }
    h := 0; if r >= 8 { h = 1; }
    if o >= -128 && o <= 127 {
        e2_w8(b, p, 72 + h*4); e2_w8(b, p+1, 137);
        e2_w8(b, p+2, 64 + (r%8)*8 + 5); e2_w8(b, p+3, o); return 4;
    }
    // Large offset: use [rbp+disp32] (7 bytes)
    e2_w8(b, p, 72 + h*4); e2_w8(b, p+1, 137);
    e2_w8(b, p+2, 128 + (r%8)*8 + 5); e2_w32(b, p+3, o); return 7;
}

fn e2_li(b: string, p: int, o: int, v: int) -> int {
    e2_w8(b, p, 72); e2_w8(b, p+1, 199); e2_w8(b, p+2, 69); e2_w8(b, p+3, o);
    e2_w32(b, p+4, v); return 8;
}

fn e2_lr(b: string, p: int, rel: int) -> int {
    e2_w8(b, p, 76); e2_w8(b, p+1, 141); e2_w8(b, p+2, 21); e2_w32(b, p+3, rel); return 7;
}

fn e2_lrb(b: string, p: int, rel: int) -> int {
    e2_w8(b, p, 73); e2_w8(b, p+1, 141); e2_w8(b, p+2, 29); e2_w32(b, p+3, rel); return 7;
}

fn e2_lb(b: string, p: int, o: int) -> int {
    if o >= -128 && o <= 127 {
        e2_w8(b, p, 76); e2_w8(b, p+1, 141); e2_w8(b, p+2, 85); e2_w8(b, p+3, o); return 4;
    }
    e2_w8(b, p, 76); e2_w8(b, p+1, 141); e2_w8(b, p+2, 133); e2_w32(b, p+3, o); return 7;
}

fn e2_call(b: string, p: int, rel: int) -> int {
    e2_w8(b, p, 232); e2_w32(b, p+1, rel); return 5;
}

fn e2_jmp(b: string, p: int, rel: int) -> int {
    e2_w8(b, p, 233); e2_w32(b, p+1, rel); return 5;
}

fn e2_je(b: string, p: int, rel: int) -> int {
    e2_w8(b, p, 15); e2_w8(b, p+1, 132); e2_w32(b, p+2, rel); return 6;
}

fn e2_alu(b: string, p: int, op: int) -> int {
    e2_w8(b, p, 77); e2_w8(b, p+1, op); e2_w8(b, p+2, 192 + (11%8)*8 + (10%8)); return 3;
}

// ── arch_instr_size: instruction byte count for resolve_labels ──
fn arch_instr_size(instr_idx: int) -> int {
    op := iri_op(instr_idx); s3 := iri_s3(instr_idx); ti := iri_tk(instr_idx); d := iri_dest(instr_idx);

    if op == IR_CONST {
        if ti == TI_STR { return 11; }
        return 8;
    }
    if op == IR_BINARY {
        sz := e2_ld_size(10, 0) + e2_ld_size(11, 0) + e2_st_size(10, 0);
        if s3 == OP_DIV || s3 == OP_MOD {
            sz = sz + 3 + 2 + 3 + 3;
        } else {
            sz = sz + 3;
            if s3 == OP_MUL { sz = sz + 1; }
            if s3 == OP_SHL || s3 == OP_SHR { sz = sz + 3; }
            if s3 >= OP_EQ && s3 <= OP_GE { sz = sz + 3 + 4; }
        }
        return sz;
    }
    if op == IR_UNARY {
        sz := e2_ld_size(10, 0) + e2_st_size(10, 0);
        if s3 == UOP_NOT {
            sz = sz + 3 + 3 + 4;
        } else {
            sz = sz + 3;
        }
        return sz;
    }
    if op == IR_CALL {
        fn2 := ""; if s3 >= 0 { fn2 = istr_get(s3); }
        if str_eq(fn2, "syscall3") != 0 {
            sz := iri_s2(instr_idx) * 4 + 14; if d >= 0 { sz = sz + 4; } return sz;
        }
        if str_eq(fn2, "load8") != 0 {
            sz := iri_s2(instr_idx) * 4 + 5; if d >= 0 { sz = sz + 4; } return sz;
        }
        if str_eq(fn2, "store8") != 0 {
            sz := iri_s2(instr_idx) * 4 + 3; return sz;
        }
        if s3 >= 0 {
            sz := iri_s2(instr_idx) * 4 + 5; if d >= 0 { sz = sz + 4; } return sz;
        }
        sz := 2; if d >= 0 { sz = sz + 4; } return sz;
    }
    if op == IR_RETURN {
        if iri_s1(instr_idx) >= 0 { return 9; }
        return 5;
    }
    if op == IR_ALLOC { return 0; }
    if op == IR_ALLOC_STRUCT || op == IR_ALLOC_ARRAY { return 14; }
    if op == IR_LOAD || op == IR_STORE {
        // Check if global: 13 bytes for lea+mov+st/ld, else 8 for local
        s1v := iri_s1(instr_idx);
        if s1v >= 0 && s1v < g_x86_global_cap {
            if r64(g_x86_is_global, s1v * 8) != 0 { return 13; }
        }
        return 8;
    }
    if op == IR_LOAD_FIELD { return 15; }
    if op == IR_STORE_FIELD { return 15; }
    if op == IR_REF { return 8; }
    if op == IR_DEREF { return 11; }
    if op == IR_STORE_PTR { return 11; }
    if op == IR_BRANCH { return 18; }
    if op == IR_JUMP { return 5; }
    if op == IR_LOAD_ENUM_TAG { return 15; }
    if op == IR_LOAD_INDEX || op == IR_STORE_INDEX { return 15; }
    if op == IR_LOAD_INDEX_VAR || op == IR_STORE_INDEX_VAR { return 16; }
    if op == IR_MAKE_ENUM { return 26; }
    if op == IR_SLICE { return 19; }
    return 0;
}

// ── x86_emit_instr: write one instruction to buffer, return bytes written ──
fn x86_emit_instr(instr_idx: int, buf: string, pos: int) -> int {
    op := iri_op(instr_idx); d := iri_dest(instr_idx); s1 := iri_s1(instr_idx); s2 := iri_s2(instr_idx); s3 := iri_s3(instr_idx); ti := iri_tk(instr_idx);
    cp := 0;

    if op == IR_NOP { return 0; }

    if op == IR_CONST && d >= 0 {
        do2 := g2_slot(d);
        if ti == TI_STR {
            ro := g2_str_off(s1);
            rel := g_x86_rodata_base + ro - (pos + cp + 7);
            cp = cp + e2_lr(buf, pos+cp, rel);
            cp = cp + e2_st(buf, pos+cp, 10, do2);
        } else {
            cp = cp + e2_li(buf, pos+cp, do2, s1);
        }
        return cp;
    }

    if op == IR_BINARY {
        do2 := g2_slot(d); o1 := g2_slot(s1); o2 := g2_slot(s2);
        cp = cp + e2_ld(buf, pos+cp, 10, o1);
        cp = cp + e2_ld(buf, pos+cp, 11, o2);
        if s3 == OP_ADD         { cp = cp + e2_alu(buf, pos+cp, 1); }
        else if s3 == OP_SUB    { cp = cp + e2_alu(buf, pos+cp, 41); }
        else if s3 == OP_MUL    { e2_w8(buf, pos+cp, 77); e2_w8(buf, pos+cp+1, 15); e2_w8(buf, pos+cp+2, 175); e2_w8(buf, pos+cp+3, 211); cp = cp + 4; }
        else if s3 == OP_SHL    { e2_w8(buf, pos+cp, 73); e2_w8(buf, pos+cp+1, 137); e2_w8(buf, pos+cp+2, 217); cp = cp + 3; e2_w8(buf, pos+cp, 73); e2_w8(buf, pos+cp+1, 211); e2_w8(buf, pos+cp+2, 226); cp = cp + 3; }
        else if s3 == OP_SHR    { e2_w8(buf, pos+cp, 73); e2_w8(buf, pos+cp+1, 137); e2_w8(buf, pos+cp+2, 217); cp = cp + 3; e2_w8(buf, pos+cp, 73); e2_w8(buf, pos+cp+1, 211); e2_w8(buf, pos+cp+2, 234); cp = cp + 3; }
        else if s3 == OP_DIV || s3 == OP_MOD {
            cp = cp + e2_mov(buf, pos+cp, 0, 10);
            e2_w8(buf, pos+cp, 72); e2_w8(buf, pos+cp+1, 153); cp = cp + 2;
            e2_w8(buf, pos+cp, 73); e2_w8(buf, pos+cp+1, 247); e2_w8(buf, pos+cp+2, 251); cp = cp + 3;
            if s3 == OP_DIV { cp = cp + e2_mov(buf, pos+cp, 10, 0); } else { cp = cp + e2_mov(buf, pos+cp, 10, 2); }
        }
        else if s3 >= OP_EQ && s3 <= OP_GE {
            cp = cp + e2_alu(buf, pos+cp, 57);  // cmp
            sop := 148; if s3 == OP_NE { sop = 149; } else if s3 == OP_LT { sop = 156; } else if s3 == OP_GT { sop = 159; } else if s3 == OP_LE { sop = 158; } else if s3 == OP_GE { sop = 157; }
            e2_w8(buf, pos+cp, 15); e2_w8(buf, pos+cp+1, sop); e2_w8(buf, pos+cp+2, 192); cp = cp + 3;
            e2_w8(buf, pos+cp, 76); e2_w8(buf, pos+cp+1, 15); e2_w8(buf, pos+cp+2, 182); e2_w8(buf, pos+cp+3, 208); cp = cp + 4;
        }
        else if s3 == OP_AND { cp = cp + e2_alu(buf, pos+cp, 33); }
        else if s3 == OP_OR  { cp = cp + e2_alu(buf, pos+cp, 9); }
        cp = cp + e2_st(buf, pos+cp, 10, do2);
        return cp;
    }

    if op == IR_UNARY && d >= 0 {
        do2 := g2_slot(d); o1 := g2_slot(s1);
        cp = cp + e2_ld(buf, pos+cp, 10, o1);
        if s3 == UOP_NEG { e2_w8(buf, pos+cp, 73); e2_w8(buf, pos+cp+1, 247); e2_w8(buf, pos+cp+2, 218); cp = cp + 3; }
        else if s3 == UOP_NOT {
            e2_w8(buf, pos+cp, 77); e2_w8(buf, pos+cp+1, 133); e2_w8(buf, pos+cp+2, 210); cp = cp + 3;
            e2_w8(buf, pos+cp, 15); e2_w8(buf, pos+cp+1, 148); e2_w8(buf, pos+cp+2, 192); cp = cp + 3;
            e2_w8(buf, pos+cp, 76); e2_w8(buf, pos+cp+1, 15); e2_w8(buf, pos+cp+2, 182); e2_w8(buf, pos+cp+3, 208); cp = cp + 4;
        }
        cp = cp + e2_st(buf, pos+cp, 10, do2);
        return cp;
    }

    if op == IR_CALL {
        fn2 := ""; if s3 >= 0 { fn2 = istr_get(s3); }
        fa := s1; ac := s2;
        ai := 0;
        loop { if ai >= ac { break; } if ai >= 6 { break; }
            ao := g2_slot(fa + ai); r := -1;
            if ai == 0 { r = 7; } if ai == 1 { r = 6; } if ai == 2 { r = 2; } if ai == 3 { r = 1; } if ai == 4 { r = 8; } if ai == 5 { r = 9; }
            if r >= 0 { cp = cp + e2_ld(buf, pos+cp, r, ao); }
        ai = ai + 1; }
        if str_eq(fn2, "syscall3") != 0 {
            cp = cp + e2_mov(buf, pos+cp, 0, 7);
            cp = cp + e2_mov(buf, pos+cp, 7, 6);
            cp = cp + e2_mov(buf, pos+cp, 6, 2);
            cp = cp + e2_mov(buf, pos+cp, 2, 1);
            e2_w8(buf, pos+cp, 15); e2_w8(buf, pos+cp+1, 5); cp = cp + 2;
            if d >= 0 { cp = cp + e2_st(buf, pos+cp, 0, g2_slot(d)); }
        } else if str_eq(fn2, "load8") != 0 {
            e2_w8(buf, pos+cp, 72); e2_w8(buf, pos+cp+1, 15); e2_w8(buf, pos+cp+2, 182); e2_w8(buf, pos+cp+3, 4); e2_w8(buf, pos+cp+4, 55); cp = cp + 5;
            if d >= 0 { cp = cp + e2_st(buf, pos+cp, 0, g2_slot(d)); }
        } else if str_eq(fn2, "store8") != 0 {
            e2_w8(buf, pos+cp, 136); e2_w8(buf, pos+cp+1, 20); e2_w8(buf, pos+cp+2, 55); cp = cp + 3;
        } else if str_len(fn2) > 0 {
            to := -1; tf := 0;
            loop { if tf >= g_x86_func_off_count { break; } if str_eq(istr_get(r64(g_x86_func_offsets, tf*16)), fn2) != 0 { to = r64(g_x86_func_offsets, tf*16+8); break; } tf = tf + 1; }
            if to >= 0 {
                cp = cp + e2_call(buf, pos+cp, (176 + to) - (pos + cp + 5));
            } else {
                // Unknown function: emit external relocation (for dynamic linking)
                dyn_grow_x86_ext_rel(g_x86_ext_rel_count + 1);
                w64(g_x86_ext_rel_pos, g_x86_ext_rel_count * 8, pos + cp + 1);
                w64(g_x86_ext_rel_name, g_x86_ext_rel_count * 8, s3);
                g_x86_ext_rel_count = g_x86_ext_rel_count + 1;
                cp = cp + e2_call(buf, pos+cp, 0);
            }
            if d >= 0 { cp = cp + e2_st(buf, pos+cp, 0, g2_slot(d)); }
        } else {
            e2_w8(buf, pos+cp, 49); e2_w8(buf, pos+cp+1, 192); cp = cp + 2;
            if d >= 0 { cp = cp + e2_st(buf, pos+cp, 0, g2_slot(d)); }
        }
        return cp;
    }

    if op == IR_RETURN {
        if s1 >= 0 { cp = cp + e2_ld(buf, pos+cp, 0, g2_slot(s1)); }
        // record position for caller to patch jmp → epilogue
        dyn_grow_x86_ret_patch(g_x86_ret_patch_count + 1); w64(g_x86_ret_patch_pos, g_x86_ret_patch_count * 8, pos + cp);
        g_x86_ret_patch_count = g_x86_ret_patch_count + 1;
        cp = cp + e2_jmp(buf, pos+cp, 0);
        return cp;
    }

    if op == IR_ALLOC {
        return 0;
    }

    if op == IR_ALLOC_STRUCT {
        do2 := g2_slot(d);
        name_ni := s3;
        if name_ni >= 0 {
            si := -1; sfi := 0;
            loop { if sfi >= g_struct_count { break; } if si_name(sfi) == name_ni { si = sfi; break; } sfi = sfi + 1; }
            if si >= 0 {
                fc := si_field_count(si);
                if fc > 0 {
                    e2_w8(buf, pos+cp, 191); e2_w32(buf, pos+cp+1, fc * 8); cp = cp + 5;  // mov edi, size
                    dyn_grow_x86_alloc_patch(g_x86_alloc_patch_count + 1); w64(g_x86_alloc_patch_pos, g_x86_alloc_patch_count * 8, pos + cp);
                    g_x86_alloc_patch_count = g_x86_alloc_patch_count + 1;
                    e2_w8(buf, pos+cp, 232); e2_w32(buf, pos+cp+1, 0); cp = cp + 5;  // call placeholder
                    cp = cp + e2_st(buf, pos+cp, 0, do2);
                }
            }
        }
        return cp;
    }

    if op == IR_ALLOC_ARRAY {
        do2 := g2_slot(d); sz := s1 * 8;
        if sz > 0 {
            e2_w8(buf, pos+cp, 191); e2_w32(buf, pos+cp+1, sz); cp = cp + 5;  // mov edi, size
            dyn_grow_x86_alloc_patch(g_x86_alloc_patch_count + 1); w64(g_x86_alloc_patch_pos, g_x86_alloc_patch_count * 8, pos + cp);
            g_x86_alloc_patch_count = g_x86_alloc_patch_count + 1;
            e2_w8(buf, pos+cp, 232); e2_w32(buf, pos+cp+1, 0); cp = cp + 5;  // call placeholder
            cp = cp + e2_st(buf, pos+cp, 0, do2);
        }
        return cp;
    }

    if op == IR_LOAD && d >= 0 {
        do2 := g2_slot(d);
        if s1 >= 0 && s1 < g_x86_global_cap {
            if r64(g_x86_is_global, s1 * 8) != 0 {
                dyn_grow_x86_rip_patch(g_x86_rip_patch_count + 1);
                w64(g_x86_rip_patch_pos, g_x86_rip_patch_count * 8, pos + cp + 3);
                w64(g_x86_rip_patch_globals, g_x86_rip_patch_count * 8, s1);
                g_x86_rip_patch_count = g_x86_rip_patch_count + 1;
                cp = cp + e2_lr(buf, pos+cp, 0);
                e2_w8(buf, pos+cp, 77); e2_w8(buf, pos+cp+1, 139); e2_w8(buf, pos+cp+2, 18); cp = cp + 3;
                cp = cp + e2_st(buf, pos+cp, 10, do2);
            } else { o1 := g2_slot(s1); cp = cp + e2_ld(buf, pos+cp, 10, o1); cp = cp + e2_st(buf, pos+cp, 10, do2); }
        } else { o1 := g2_slot(s1); cp = cp + e2_ld(buf, pos+cp, 10, o1); cp = cp + e2_st(buf, pos+cp, 10, do2); }
        return cp;
    }

    if op == IR_STORE {
        o1 := g2_slot(s1);
        if s1 >= 0 && s1 < g_x86_global_cap {
            if r64(g_x86_is_global, s1 * 8) != 0 {
                o2 := g2_slot(s2);
                cp = cp + e2_ld(buf, pos+cp, 10, o2);
                dyn_grow_x86_rip_patch(g_x86_rip_patch_count + 1);
                w64(g_x86_rip_patch_pos, g_x86_rip_patch_count * 8, pos + cp + 3);
                w64(g_x86_rip_patch_globals, g_x86_rip_patch_count * 8, s1);
                g_x86_rip_patch_count = g_x86_rip_patch_count + 1;
                cp = cp + e2_lrb(buf, pos+cp, 0);
                e2_w8(buf, pos+cp, 77); e2_w8(buf, pos+cp+1, 137); e2_w8(buf, pos+cp+2, 26); cp = cp + 3;
            } else { o2 := g2_slot(s2); cp = cp + e2_ld(buf, pos+cp, 10, o2); cp = cp + e2_st(buf, pos+cp, 10, o1); }
        } else { o2 := g2_slot(s2); cp = cp + e2_ld(buf, pos+cp, 10, o2); cp = cp + e2_st(buf, pos+cp, 10, o1); }
        return cp;
    }

    if op == IR_LOAD_FIELD && d >= 0 {
        o1 := g2_slot(s1); do2 := g2_slot(d); fi2 := s3;
        fo : ., mut = fi2 * 8;
        cp = cp + e2_ld(buf, pos+cp, 10, o1);
        e2_w8(buf, pos+cp, 77); e2_w8(buf, pos+cp+1, 139); e2_w8(buf, pos+cp+2, 146); e2_w32(buf, pos+cp+3, fo); cp = cp + 7;
        cp = cp + e2_st(buf, pos+cp, 10, do2);
        return cp;
    }

    if op == IR_STORE_FIELD {
        o1 := g2_slot(s1); o2 := g2_slot(s2); fi2 := s3;
        fo : ., mut = fi2 * 8;
        cp = cp + e2_ld(buf, pos+cp, 10, o1); cp = cp + e2_ld(buf, pos+cp, 11, o2);
        e2_w8(buf, pos+cp, 77); e2_w8(buf, pos+cp+1, 137); e2_w8(buf, pos+cp+2, 154); e2_w32(buf, pos+cp+3, fo); cp = cp + 7;
        return cp;
    }

    if op == IR_REF && d >= 0 {
        do2 := g2_slot(d); o1 := g2_slot(s1);
        cp = cp + e2_lb(buf, pos+cp, o1); cp = cp + e2_st(buf, pos+cp, 10, do2);
        return cp;
    }

    if op == IR_DEREF && d >= 0 {
        do2 := g2_slot(d); o1 := g2_slot(s1);
        cp = cp + e2_ld(buf, pos+cp, 10, o1);
        e2_w8(buf, pos+cp, 77); e2_w8(buf, pos+cp+1, 139); e2_w8(buf, pos+cp+2, 26); cp = cp + 3;
        cp = cp + e2_st(buf, pos+cp, 10, do2);
        return cp;
    }

    if op == IR_STORE_PTR {
        o1 := g2_slot(s1); o2 := g2_slot(s2);
        cp = cp + e2_ld(buf, pos+cp, 10, o1); cp = cp + e2_ld(buf, pos+cp, 11, o2);
        e2_w8(buf, pos+cp, 77); e2_w8(buf, pos+cp+1, 137); e2_w8(buf, pos+cp+2, 26); cp = cp + 3;
        return cp;
    }

    if op == IR_BRANCH {
        co := g2_slot(s1);
        cp = cp + e2_ld(buf, pos+cp, 10, co);
        e2_w8(buf, pos+cp, 77); e2_w8(buf, pos+cp+1, 133); e2_w8(buf, pos+cp+2, 210); cp = cp + 3;  // test r10, r10
        // IR_BRANCH: s2=true_offset, s3=false_offset
        // je → false (when condition==0), jmp → true (when condition!=0)
        true_abs := g_x86_func_frame_start + s2;
        false_abs := g_x86_func_frame_start + s3;
        rel_f := false_abs - (pos + cp + 6);
        cp = cp + e2_je(buf, pos+cp, rel_f);
        rel_t := true_abs - (pos + cp + 5);
        cp = cp + e2_jmp(buf, pos+cp, rel_t);
        return cp;
    }

    if op == IR_JUMP {
        tgt_abs := g_x86_func_frame_start + s1;
        rel := tgt_abs - (pos + cp + 5);
        cp = cp + e2_jmp(buf, pos+cp, rel);
        return cp;
    }

    if op == IR_LOAD_ENUM_TAG && d >= 0 {
        o1 := g2_slot(s1); do2 := g2_slot(d);
        cp = cp + e2_ld(buf, pos+cp, 10, o1);
        // mov r10, [r10 + disp32] — tag at offset 0
        e2_w8(buf, pos+cp, 77); e2_w8(buf, pos+cp+1, 139); e2_w8(buf, pos+cp+2, 146); e2_w32(buf, pos+cp+3, 0); cp = cp + 7;
        cp = cp + e2_st(buf, pos+cp, 10, do2);
        return cp;
    }

    if op == IR_LOAD_INDEX && d >= 0 {
        do2 := g2_slot(d); o1 := g2_slot(s1); idx := s3;
        cp = cp + e2_ld(buf, pos+cp, 10, o1);
        // mov r10, [r10 + disp32]
        e2_w8(buf, pos+cp, 77); e2_w8(buf, pos+cp+1, 139); e2_w8(buf, pos+cp+2, 146); e2_w32(buf, pos+cp+3, idx * 8); cp = cp + 7;
        cp = cp + e2_st(buf, pos+cp, 10, do2);
        return cp;
    }

    if op == IR_STORE_INDEX {
        o1 := g2_slot(s1); o2 := g2_slot(s2); idx := s3;
        cp = cp + e2_ld(buf, pos+cp, 10, o1); cp = cp + e2_ld(buf, pos+cp, 11, o2);
        // mov [r10 + disp32], r11
        e2_w8(buf, pos+cp, 77); e2_w8(buf, pos+cp+1, 137); e2_w8(buf, pos+cp+2, 154); e2_w32(buf, pos+cp+3, idx * 8); cp = cp + 7;
        return cp;
    }

    if op == IR_LOAD_INDEX_VAR && d >= 0 {
        do2 := g2_slot(d); o1 := g2_slot(s1); oi := g2_slot(s2);
        cp = cp + e2_ld(buf, pos+cp, 10, o1); cp = cp + e2_ld(buf, pos+cp, 11, oi);
        e2_w8(buf, pos+cp, 79); e2_w8(buf, pos+cp+1, 139); e2_w8(buf, pos+cp+2, 20); e2_w8(buf, pos+cp+3, 218); cp = cp + 4;
        cp = cp + e2_st(buf, pos+cp, 10, do2);
        return cp;
    }

    if op == IR_STORE_INDEX_VAR && d >= 0 {
        o1 := g2_slot(s1); oi := g2_slot(s2); ov := g2_slot(d);
        cp = cp + e2_ld(buf, pos+cp, 10, o1); cp = cp + e2_ld(buf, pos+cp, 11, oi); cp = cp + e2_ld(buf, pos+cp, 12, ov);
        e2_w8(buf, pos+cp, 79); e2_w8(buf, pos+cp+1, 137); e2_w8(buf, pos+cp+2, 36); e2_w8(buf, pos+cp+3, 218); cp = cp + 4;
        return cp;
    }

    if op == IR_MAKE_ENUM && d >= 0 {
        do2 := g2_slot(d); alloc_size := 8 + s2 * 8;
        e2_w8(buf, pos+cp, 191); e2_w32(buf, pos+cp+1, alloc_size); cp = cp + 5;  // mov edi, size
        dyn_grow_x86_alloc_patch(g_x86_alloc_patch_count + 1); w64(g_x86_alloc_patch_pos, g_x86_alloc_patch_count * 8, pos + cp);
        g_x86_alloc_patch_count = g_x86_alloc_patch_count + 1;
        e2_w8(buf, pos+cp, 232); e2_w32(buf, pos+cp+1, 0); cp = cp + 5;  // call placeholder
        cp = cp + e2_st(buf, pos+cp, 0, do2);
        cp = cp + e2_ld(buf, pos+cp, 10, do2);
        e2_w8(buf, pos+cp, 73); e2_w8(buf, pos+cp+1, 199); e2_w8(buf, pos+cp+2, 66); e2_w8(buf, pos+cp+3, 0); e2_w32(buf, pos+cp+4, s1); cp = cp + 8;
        return cp;
    }

    if op == IR_SLICE && d >= 0 {
        do2 := g2_slot(d); o1 := g2_slot(s1); o2 := g2_slot(s2);
        cp = cp + e2_ld(buf, pos+cp, 10, o1); cp = cp + e2_ld(buf, pos+cp, 11, o2);
        e2_w8(buf, pos+cp, 73); e2_w8(buf, pos+cp+1, 193); e2_w8(buf, pos+cp+2, 227); e2_w8(buf, pos+cp+3, 3); cp = cp + 4;
        e2_w8(buf, pos+cp, 77); e2_w8(buf, pos+cp+1, 1); e2_w8(buf, pos+cp+2, 218); cp = cp + 3;
        cp = cp + e2_st(buf, pos+cp, 10, do2);
        return cp;
    }

    return 0;
}
