// ══════════════════════════════════════════════════════════════
// Binary emit interface — state + helpers + emit_instr
// ══════════════════════════════════════════════════════════════

// State globals (set by caller before emit phase)
g_x86_rodata_base : int, mut;
g_x86_func_frame_start : int, mut;  // abs buf pos of current function body (after frame)
g_current_func_var_start : int, mut;  // var_start of current function, set before emit

E2_REG_SLOT_BASE : int = 1000000000;


fn g2_init() {
    g_x86_emit_var_count = 0;
    g_x86_emit_stack_size = 0;
    g_x86_ret_patch_count = 0;
    // g_x86_alloc_patch_count NOT reset: alloc calls are patched after all funcs.
    // g_x86_ext_rel_count NOT reset: extern relocations span all functions.
    // g_x86_rip_patch_count NOT reset
}

// ── Optimization metadata: register assignment lookup ──
// Reads g_opt_meta (saved in .ccr v3+) to find register for a variable.
// Returns -1 if no register assigned.

fn get_reg_for_var(var_idx: int) -> int {
    mi : ., mut = 0;
    loop { if mi >= g_opt_meta_count { break; }
        mo := mi * OPT_META_STRIDE;
        mk := r32(g_opt_meta, mo);
        if mk == OPT_KEY_REG_ASSIGN {
            data_len := r32(g_opt_meta, mo + 4);
            di : ., mut = 4;  // skip count u32, pairs start at +4
            loop { if di >= data_len { break; }
                vi := r32(g_opt_meta, mo + 8 + di);
                if vi == var_idx {
                    return r32(g_opt_meta, mo + 8 + di + 4);
                }
                di = di + 8;
            }
        }
        mi = mi + 1;
    }
    return -1;
}

fn g2_slot(v: int) -> int {
    // Register encoding uses a positive sentinel range so it cannot collide
    // with large negative stack frame offsets.
    if v >= E2_REG_SLOT_BASE { return v; }
    // Check optimization metadata for register assignment (opt_level >= 1)
    if g_opt_level >= 1 && v >= 0 {
        rn := get_reg_for_var(v);
        if rn >= 0 { return E2_REG_SLOT_BASE + rn; }
    }
    // Stack sharing: if this var maps to another, use that var's slot
    if v >= 0 && str_len(g_stack_map) > v * 8 {
        mapped := r64(g_stack_map, v * 8);
        if mapped >= 0 && mapped != v { v = mapped; }
    }
    // Function-relative slot: offset within current function's stack frame
    // Keeps offsets small (disp8 range) for large absolute var indices
    if v >= 0 { return -(v + 1 - g_current_func_var_start) * 8; }
    return 0;
}

fn g2_str_off(si: int) -> int {
    o := 0; i := 0;
    loop {
        if i >= g_x86_str_count { break; }
        if r64(g_x86_str_offs, i * 8) == si { return o + 8; }  // +8 for this string's header
        o = o + 8 + istr_len(r64(g_x86_str_offs, i * 8)) + 1;
        if o % 8 != 0 { o = o + 8 - (o % 8); }
        i = i + 1;
    }
    grow_str_offs(g_x86_str_count + 1); w64(g_x86_str_offs, g_x86_str_count * 8, si); g_x86_str_count = g_x86_str_count + 1;
    return o + 8;  // +8 for this string's header
}

fn g2_rodata_sz() -> int {
    o := 0; i := 0;
    loop { if i >= g_x86_str_count { break; } o = o + 8 + istr_len(r64(g_x86_str_offs, i * 8)) + 1; if o % 8 != 0 { o = o + 8 - (o % 8); } i = i + 1; }
    return o;
}

// ── Byte encoding helpers ──
fn e2_w8(buf: string, pos: int, val: int) { store8(buf, pos, val % 256); }
fn e2_w16(buf: string, off: int, val: int) { w32(buf, off, val); }
fn e2_w32(buf: string, pos: int, val: int) -> int {
    w32(buf, pos, val);
    return 4;
}
fn e2_w64(buf: string, pos: int, val: int) -> int { w64(buf, pos, val); return 8; }

// ── Encoding primitives (computed, no magic numbers) ──
// REX byte: 0100 WRXB — computed from W/R/X/B flags (0 or 1 each)
fn emit_rex(buf: string, pos: int, W: int, R: int, X: int, B: int) -> int {
    e2_w8(buf, pos, 64 + W*8 + R*4 + X*2 + B); return 1;
}

// ModRM byte: mod<6:7> | reg<3:5> | rm<0:2>
fn emit_modrm(buf: string, pos: int, m: int, reg: int, rm: int) -> int {
    e2_w8(buf, pos, m*64 + reg*8 + rm); return 1;
}

// SIB byte: scale<6:7> | index<3:5> | base<0:2>
fn emit_sib(buf: string, pos: int, scale: int, index: int, base: int) -> int {
    e2_w8(buf, pos, scale*64 + index*8 + base); return 1;
}

fn e2_mov(b: string, p: int, d: int, s: int) -> int {
    // mov r64, r64 — opcode 0x89 MOV r/m, r, mod=3 (register)
    // REX: W=1, R=source>>3, B=dest>>3
    cp := p;
    cp = cp + emit_rex(b, cp, 1, s/8, 0, d/8);
    e2_w8(b, cp, 137); cp = cp + 1;  // opcode 0x89 MOV r/m, r
    cp = cp + emit_modrm(b, cp, 3, s%8, d%8);
    return cp - p;
}

fn e2_ld(b: string, p: int, r: int, o: int) -> int {
    // mov r64, [src] — opcode 0x8B MOV r, r/m, 3 addressing modes
    cp := p;
    if o >= E2_REG_SLOT_BASE {
        // Register-to-register: mov r_dest, r_src (copies value from alloc'd reg)
        src_reg := o - E2_REG_SLOT_BASE;
        return e2_mov(b, p, r, src_reg);
    }
    if o >= -128 && o <= 127 {
        // [rbp+disp8] (mod=01, rm=5)
        cp = cp + emit_rex(b, cp, 1, r/8, 0, 0);
        e2_w8(b, cp, 139); cp = cp + 1;
        cp = cp + emit_modrm(b, cp, 1, r%8, 5);
        e2_w8(b, cp, o); cp = cp + 1;
        return cp - p;
    }
    // [rbp+disp32] (mod=02, rm=5)
    cp = cp + emit_rex(b, cp, 1, r/8, 0, 0);
    e2_w8(b, cp, 139); cp = cp + 1;
    cp = cp + emit_modrm(b, cp, 2, r%8, 5);
    cp = cp + e2_w32(b, cp, o);
    return cp - p;
}


fn e2_st(b: string, p: int, r: int, o: int) -> int {
    // mov [dst], r64 — opcode 0x89 MOV r/m, r, 3 addressing modes
    if o >= E2_REG_SLOT_BASE {
        // register destination: use 3-operand mov (mod=3)
        dst_reg := o - E2_REG_SLOT_BASE;
        return e2_mov(b, p, dst_reg, r);
    }
    cp := p;
    cp = cp + emit_rex(b, cp, 1, r/8, 0, 0);  // REX.W + REX.R(if r>=8)
    e2_w8(b, cp, 137); cp = cp + 1;  // opcode 0x89 MOV r/m, r
    if o >= -128 && o <= 127 {
        cp = cp + emit_modrm(b, cp, 1, r%8, 5);
        e2_w8(b, cp, o); cp = cp + 1;
        return cp - p;
    }
    cp = cp + emit_modrm(b, cp, 2, r%8, 5);
    cp = cp + e2_w32(b, cp, o);
    return cp - p;
}

fn e2_li(b: string, p: int, o: int, v: int) -> int {
    cp := p;
    // mov [rbp+disp], imm64 — two-step for values outside signed 32-bit range
    if v < -2147483647 - 1 || v > 2147483647 {
        // Step 1: mov rax, imm64 (REX.W + 0xB8 MOV r, imm + rax + 8B imm)
        cp = cp + emit_rex(b, cp, 1, 0, 0, 0);
        e2_w8(b, cp, 184); cp = cp + 1;  // 0xB8 MOV r, imm (reg=0→rax)
        cp = cp + e2_w64(b, cp, v);
        // Step 2: mov [rbp+disp], rax (REX.W + 0x89 MOV r/m, r)
        cp = cp + emit_rex(b, cp, 1, 0, 0, 0);
        e2_w8(b, cp, 137); cp = cp + 1;
        if o >= -128 && o <= 127 {
            cp = cp + emit_modrm(b, cp, 1, 0, 5);
            e2_w8(b, cp, o); cp = cp + 1;
        } else {
            cp = cp + emit_modrm(b, cp, 2, 0, 5);
            cp = cp + e2_w32(b, cp, o);
        }
        return cp - p;
    }
    // mov [rbp+disp], imm32 — opcode 0xC7 MOV r/m, imm, sign-extended
    cp = cp + emit_rex(b, cp, 1, 0, 0, 0);
    e2_w8(b, cp, 199); cp = cp + 1;  // 0xC7 MOV r/m, imm32
    if o >= -128 && o <= 127 {
        cp = cp + emit_modrm(b, cp, 1, 0, 5);
        e2_w8(b, cp, o); cp = cp + 1;
        cp = cp + e2_w32(b, cp, v);
    } else {
        cp = cp + emit_modrm(b, cp, 2, 0, 5);
        cp = cp + e2_w32(b, cp, o);
        cp = cp + e2_w32(b, cp, v);
    }
    return cp - p;
}

fn e2_lr(b: string, p: int, rel: int) -> int {
    // lea r10, [rip + rel] — dest=r10, REX.R=1 since r10>=8
    cp := p;
    cp = cp + emit_rex(b, cp, 1, 1, 0, 0);
    e2_w8(b, cp, 141); cp = cp + 1;  // LEA opcode 0x8D
    cp = cp + emit_modrm(b, cp, 0, 2, 5);  // r10%8=2, rm=5=RIP-relative
    cp = cp + e2_w32(b, cp, rel);
    return cp - p;
}

fn e2_lrb(buf: string, p: int, rel: int) -> int {
    // lea r11, [rip + rel] — dest=r11, REX.R=1 since r11>=8
    cp := p;
    cp = cp + emit_rex(buf, cp, 1, 1, 0, 0);
    e2_w8(buf, cp, 141); cp = cp + 1;
    cp = cp + emit_modrm(buf, cp, 0, 3, 5);  // r11%8=3
    cp = cp + e2_w32(buf, cp, rel);
    return cp - p;
}

fn e2_lb(b: string, p: int, o: int) -> int {
    // lea r10, [rbp + offset]
    cp := p;
    cp = cp + emit_rex(b, cp, 1, 1, 0, 0);  // REX.W + REX.R (r10 >= 8)
    e2_w8(b, cp, 141); cp = cp + 1;  // LEA opcode 0x8D
    if o >= -128 && o <= 127 {
        cp = cp + emit_modrm(b, cp, 1, 2, 5);  // mod=01=[rbp+disp8], reg=2=r10%8, rm=5=rbp
        e2_w8(b, cp, o); cp = cp + 1;
    } else {
        cp = cp + emit_modrm(b, cp, 2, 2, 5);  // mod=10=[rbp+disp32]
        cp = cp + e2_w32(b, cp, o);
    }
    return cp - p;
}

fn e2_call(b: string, p: int, rel: int) -> int {
    // call rel32 — opcode 0xE8
    e2_w8(b, p, 232); e2_w32(b, p+1, rel); return 5;
}

fn e2_jmp(b: string, p: int, rel: int) -> int {
    // jmp rel32 — opcode 0xE9
    e2_w8(b, p, 233); e2_w32(b, p+1, rel); return 5;
}

fn e2_je(b: string, p: int, rel: int) -> int {
    // je rel32 near — 2-byte opcode 0x0F 0x84
    e2_w8(b, p, 15); e2_w8(b, p+1, 132); e2_w32(b, p+2, rel); return 6;
}

fn e2_jae(b: string, p: int, rel: int) -> int {
    // jae rel32 near — 2-byte opcode 0x0F 0x83
    e2_w8(b, p, 15); e2_w8(b, p+1, 131); e2_w32(b, p+2, rel); return 6;
}

fn e2_alu(b: string, p: int, op: int) -> int {
    // ALU r/m, r: REX.W + REX.RB (r11, r10) + opcode + ModRM reg=11, rm=10
    cp := p;
    cp = cp + emit_rex(b, cp, 1, 1, 0, 1);  // W=1, R=1(r11/8), B=1(r10/8)
    e2_w8(b, cp, op); cp = cp + 1;
    cp = cp + emit_modrm(b, cp, 3, 11%8, 10%8);  // mod=3(register), reg=3, rm=2
    return cp - p;
}

// ── emit_instr: write one instruction to buffer, return bytes written ──

fn e2_load_var(buf: string, pos: int, reg: int, var_idx: int) -> int {
    if var_idx >= 0 && r64(g_x86_is_global, var_idx * 8) != 0 {
        grow_rip_patch(g_x86_rip_patch_count + 1);
        w64(g_x86_rip_patch_pos, g_x86_rip_patch_count * 8, pos + 3);
        w64(g_x86_rip_patch_globals, g_x86_rip_patch_count * 8, var_idx);
        g_x86_rip_patch_count = g_x86_rip_patch_count + 1;
        sz := e2_lrb(buf, pos, 0);
        // mov reg, [r11] — memory load (NOT register copy; e2_ld + e2_rslot would misinterpret)
        cp2 := pos + sz;
        cp2 = cp2 + emit_rex(buf, cp2, 1, reg/8, 0, 11/8);
        e2_w8(buf, cp2, 139); cp2 = cp2 + 1;  // 0x8B MOV r, r/m
        cp2 = cp2 + emit_modrm(buf, cp2, 0, reg%8, 11%8);
        sz = cp2 - pos;
        return sz;
    }
    return e2_ld(buf, pos, reg, g2_slot(var_idx));
}

fn e2_rslot(r: int) -> int { return E2_REG_SLOT_BASE + r; }

fn sz_ofs(o: int) -> int {
    if o >= E2_REG_SLOT_BASE { return 3; }
    if o >= -128 && o <= 127 { return 4; }
    return 7;
}
fn sz_load_var(v: int) -> int {
    if v >= 0 && v < g_ir_var_count && g_str_count > 0 {
        if r64(g_x86_is_global, v * 8) != 0 { return sz_lr() + 3; }
    }
    return sz_ld(g2_slot(v));
}

fn emit_instr(instr_idx: int, buf: string, pos: int) -> int {
    op := iri_op(instr_idx); d := iri_dest(instr_idx); s1 := iri_s1(instr_idx); s2 := iri_s2(instr_idx); s3 := iri_s3(instr_idx); ti := iri_tk(instr_idx);
    cp := 0;

    if op == IR_NOP { return 0; }

    if op == IR_CONST && d >= 0 {
        do2 := g2_slot(d);
        if ti == TI_STR {
            ro := g2_str_off(s1);
            // Record for post-emission patching (rodata position from Phase 3)
            grow_rodataref(g_x86_rodataref_count + 1);
            w64(g_x86_rodataref_pos, g_x86_rodataref_count * 8, pos + cp);
            w64(g_x86_rodataref_ro, g_x86_rodataref_count * 8, ro);
            g_x86_rodataref_count = g_x86_rodataref_count + 1;
            cp = cp + e2_lr(buf, pos+cp, 0);  // placeholder, patched later
            cp = cp + e2_st(buf, pos+cp, 10, do2);
        } else {
            cp = cp + e2_li(buf, pos+cp, do2, s1);
        }
        return cp;
    }

    if op == IR_BINARY {
        do2 := g2_slot(d);
        cp = cp + e2_load_var(buf, pos+cp, 10, s1);
        cp = cp + e2_load_var(buf, pos+cp, 11, s2);
        if s3 == OP_ADD         { cp = cp + e2_alu(buf, pos+cp, 1); }
        else if s3 == OP_SUB    { cp = cp + e2_alu(buf, pos+cp, 41); }
        else if s3 == OP_MUL    {
            // imul r10, r11 — 2-byte opcode 0x0F 0xAF
            cp = cp + emit_rex(buf, pos+cp, 1, 10/8, 0, 11/8);
            e2_w8(buf, pos+cp, 15); cp = cp + 1;
            e2_w8(buf, pos+cp, 175); cp = cp + 1;
            cp = cp + emit_modrm(buf, pos+cp, 3, 10%8, 11%8);
        }
        else if s3 == OP_SHL    {
            // mov rcx, r11; shl r10, cl
            cp = cp + emit_rex(buf, pos+cp, 1, 11/8, 0, 0);
            e2_w8(buf, pos+cp, 137); cp = cp + 1;
            cp = cp + emit_modrm(buf, pos+cp, 3, 11%8, 1);
            cp = cp + emit_rex(buf, pos+cp, 1, 0, 0, 10/8);
            e2_w8(buf, pos+cp, 211); cp = cp + 1;
            cp = cp + emit_modrm(buf, pos+cp, 3, 4, 10%8);
        }
        else if s3 == OP_SHR    {
            // mov rcx, r11; shr r10, cl
            cp = cp + emit_rex(buf, pos+cp, 1, 11/8, 0, 0);
            e2_w8(buf, pos+cp, 137); cp = cp + 1;
            cp = cp + emit_modrm(buf, pos+cp, 3, 11%8, 1);
            cp = cp + emit_rex(buf, pos+cp, 1, 0, 0, 10/8);
            e2_w8(buf, pos+cp, 211); cp = cp + 1;
            cp = cp + emit_modrm(buf, pos+cp, 3, 5, 10%8);
        }
        else if s3 == OP_PTR_ADD {  // p + n: scale n by element size (8), add to p
            // imul r11, 8, r11 — REX.WB + 0x6B + ModRM(3, r11, r11) + imm8
            cp = cp + emit_rex(buf, pos+cp, 1, 11/8, 0, 11/8);
            e2_w8(buf, pos+cp, 107); cp = cp + 1;
            cp = cp + emit_modrm(buf, pos+cp, 3, 11%8, 11%8);
            e2_w8(buf, pos+cp, 8); cp = cp + 1;
            // add r10, r11
            cp = cp + e2_alu(buf, pos+cp, 1);
        }
        else if s3 == OP_PTR_SUB {  // p - n: scale n by element size (8), sub from p
            // imul r11, 8, r11
            cp = cp + emit_rex(buf, pos+cp, 1, 11/8, 0, 11/8);
            e2_w8(buf, pos+cp, 107); cp = cp + 1;
            cp = cp + emit_modrm(buf, pos+cp, 3, 11%8, 11%8);
            e2_w8(buf, pos+cp, 8); cp = cp + 1;
            // sub r10, r11
            cp = cp + e2_alu(buf, pos+cp, 41);
        }
        else if s3 == OP_PTR_DIFF {  // p - q: diff in bytes, then /8 → element count
            // sub r10, r11
            cp = cp + e2_alu(buf, pos+cp, 41);
            // sar r10, 3 — divide by 8
            cp = cp + emit_rex(buf, pos+cp, 1, 0, 0, 10/8);
            e2_w8(buf, pos+cp, 193); cp = cp + 1;  // 0xC1 SHIFT r/m, imm8
            cp = cp + emit_modrm(buf, pos+cp, 3, 7, 10%8);  // /7 = SAR
            e2_w8(buf, pos+cp, 3); cp = cp + 1;    // shift by 3
        }
        else if s3 == OP_DIV || s3 == OP_MOD {
            cp = cp + e2_mov(buf, pos+cp, 0, 10);
            // cqo: REX.W + 0x99
            cp = cp + emit_rex(buf, pos+cp, 1, 0, 0, 0); e2_w8(buf, pos+cp, 153); cp = cp + 1;
            // idiv r11: REX.WB + 0xF7 + /7
            cp = cp + emit_rex(buf, pos+cp, 1, 0, 0, 11/8); e2_w8(buf, pos+cp, 247); cp = cp + 1; cp = cp + emit_modrm(buf, pos+cp, 3, 7, 11%8);
            if s3 == OP_DIV { cp = cp + e2_mov(buf, pos+cp, 10, 0); } else { cp = cp + e2_mov(buf, pos+cp, 10, 2); }
        }
        else if s3 >= OP_EQ && s3 <= OP_GE {
            cp = cp + e2_alu(buf, pos+cp, 57);  // cmp
            sop := 148; if s3 == OP_NE { sop = 149; } else if s3 == OP_LT { sop = 156; } else if s3 == OP_GT { sop = 159; } else if s3 == OP_LE { sop = 158; } else if s3 == OP_GE { sop = 157; }
            // SETcc al — 2-byte opcode 0x0F 0x9x
            e2_w8(buf, pos+cp, 15); cp = cp + 1; e2_w8(buf, pos+cp, sop); cp = cp + 1; cp = cp + emit_modrm(buf, pos+cp, 3, 0, 0);
            // movzx r10, al — REX.RB + 0x0FB6
            cp = cp + emit_rex(buf, pos+cp, 0, 10/8, 0, 0); e2_w8(buf, pos+cp, 15); cp = cp + 1; e2_w8(buf, pos+cp, 182); cp = cp + 1; cp = cp + emit_modrm(buf, pos+cp, 3, 10%8, 0);
        }
        else if s3 == OP_AND { cp = cp + e2_alu(buf, pos+cp, 33); }
        else if s3 == OP_OR  { cp = cp + e2_alu(buf, pos+cp, 9); }
        cp = cp + e2_st(buf, pos+cp, 10, do2);
        return cp;
    }

    if op == IR_UNARY && d >= 0 {
        do2 := g2_slot(d);
        cp = cp + e2_load_var(buf, pos+cp, 10, s1);
        if s3 == UOP_NEG {
            // neg r10: REX.WB + 0xF7 + /3
            cp = cp + emit_rex(buf, pos+cp, 1, 0, 0, 10/8); e2_w8(buf, pos+cp, 247); cp = cp + 1; cp = cp + emit_modrm(buf, pos+cp, 3, 3, 10%8);
        }
        else if s3 == UOP_NOT {
            // test r10, r10 (REX.WRB + 0x85)
            cp = cp + emit_rex(buf, pos+cp, 1, 10/8, 0, 10/8); e2_w8(buf, pos+cp, 133); cp = cp + 1; cp = cp + emit_modrm(buf, pos+cp, 3, 10%8, 10%8);
            // sete al (0x0F 0x94)
            e2_w8(buf, pos+cp, 15); cp = cp + 1; e2_w8(buf, pos+cp, 148); cp = cp + 1; cp = cp + emit_modrm(buf, pos+cp, 3, 0, 0);
            // movzx r10, al
            cp = cp + emit_rex(buf, pos+cp, 0, 10/8, 0, 0); e2_w8(buf, pos+cp, 15); cp = cp + 1; e2_w8(buf, pos+cp, 182); cp = cp + 1; cp = cp + emit_modrm(buf, pos+cp, 3, 10%8, 0);
        }
        cp = cp + e2_st(buf, pos+cp, 10, do2);
        return cp;
    }

    if op == IR_CALL {
        fa := s1; ac := s2;
        ai := 0;
        loop { if ai >= ac { break; } if ai >= 6 { break; }
            r := -1;
            if ai == 0 { r = 7; } if ai == 1 { r = 6; } if ai == 2 { r = 2; } if ai == 3 { r = 1; } if ai == 4 { r = 8; } if ai == 5 { r = 9; }
            if r >= 0 { cp = cp + e2_load_var(buf, pos+cp, r, fa + ai); }
        ai = ai + 1; }
        // System V AMD64 passes the 7th and later arguments on the stack,
        // rightmost first, so argument 7 is closest to the return address.
        stack_ai : ., mut = ac - 1;
        loop {
            if stack_ai < 6 { break; }
            cp = cp + e2_load_var(buf, pos+cp, 10, fa + stack_ai);
            e2_w8(buf, pos+cp, 65); e2_w8(buf, pos+cp+1, 82); cp = cp + 2;  // push r10
            stack_ai = stack_ai - 1;
        }
        // Match builtins by interned string index (integer compare, no str_eq)
        if s3 == g_ni_syscall3 {
            cp = cp + e2_mov(buf, pos+cp, 0, 7);
            cp = cp + e2_mov(buf, pos+cp, 7, 6);
            cp = cp + e2_mov(buf, pos+cp, 6, 2);
            cp = cp + e2_mov(buf, pos+cp, 2, 1);
            // syscall: 2-byte 0x0F 0x05
            e2_w8(buf, pos+cp, 15); e2_w8(buf, pos+cp+1, 5); cp = cp + 2;
            if d >= 0 { cp = cp + e2_st(buf, pos+cp, 0, g2_slot(d)); }
        } else if s3 == g_ni_load8 {
            // movzx rax, byte [rdi+rsi] — REX.W + 0x0FB6 + SIB
            cp = cp + emit_rex(buf, pos+cp, 1, 0, 0, 0); e2_w8(buf, pos+cp, 15); cp = cp + 1; e2_w8(buf, pos+cp, 182); cp = cp + 1;
            cp = cp + emit_modrm(buf, pos+cp, 0, 0, 4); cp = cp + emit_sib(buf, pos+cp, 0, 6, 7);
            if d >= 0 { cp = cp + e2_st(buf, pos+cp, 0, g2_slot(d)); }
        } else if s3 == g_ni_store8 {
            // mov [rdi+rsi], dl — 0x88 + SIB (3rd arg in rdx = register 2)
            e2_w8(buf, pos+cp, 136); cp = cp + 1; cp = cp + emit_modrm(buf, pos+cp, 0, 2, 4); cp = cp + emit_sib(buf, pos+cp, 0, 6, 7);
        } else if s3 == g_ni_load64 || s3 == g_ni_load_str_ptr || s3 == g_ni_r64 {
            // mov rax, [rdi + rsi]
            // mov rax, [rdi+rsi] — REX.W + 0x8B + SIB
            cp = cp + emit_rex(buf, pos+cp, 1, 0, 0, 0); e2_w8(buf, pos+cp, 139); cp = cp + 1;
            cp = cp + emit_modrm(buf, pos+cp, 0, 0, 4); cp = cp + emit_sib(buf, pos+cp, 0, 6, 7);
            if d >= 0 { cp = cp + e2_st(buf, pos+cp, 0, g2_slot(d)); }
        } else if s3 == g_ni_store_str_ptr {
            // mov [rdi + rsi], rdx
            // mov [rdi+rsi], rdx — REX.W + 0x89 + SIB
            cp = cp + emit_rex(buf, pos+cp, 1, 0, 0, 0); e2_w8(buf, pos+cp, 137); cp = cp + 1;
            cp = cp + emit_modrm(buf, pos+cp, 0, 2, 4); cp = cp + emit_sib(buf, pos+cp, 0, 6, 7);
        } else if s3 == g_ni_get_arg && gv_argv >= 0 {
            // Convert C argv[n] into a Core string with the hidden length header.
            // NB: gv_argv must be >= 0 (g_rt_argv_ptr registered as a global).
            // If it's -1, fall through to regular call path — the LEA displacement
            // would be registered as a rip_patch with gvi=-1 and SKIPPED by the
            // patch loop, leaving displacement=0 and causing GPF on dereference.
            grow_rip_patch(g_x86_rip_patch_count + 1);
            w64(g_x86_rip_patch_pos, g_x86_rip_patch_count * 8, pos + cp + 3);
            w64(g_x86_rip_patch_globals, g_x86_rip_patch_count * 8, gv_argv);
            g_x86_rip_patch_count = g_x86_rip_patch_count + 1;
            cp = cp + e2_lr(buf, pos+cp, 0);  // lea r10, [rip+0] placeholder
            // mov r10, [r10] — REX.WRB + 0x8B
            cp = cp + emit_rex(buf, pos+cp, 1, 10/8, 0, 10/8); e2_w8(buf, pos+cp, 139); cp = cp + 1; cp = cp + emit_modrm(buf, pos+cp, 0, 10%8, 10%8);  // mov r10, [r10]
            // mov r10, [r10 + rdi*8] — SIB(scale=3, index=rdi%8, base=r10%8)
            cp = cp + emit_rex(buf, pos+cp, 1, 10/8, 0, 10/8); e2_w8(buf, pos+cp, 139); cp = cp + 1;
            cp = cp + emit_modrm(buf, pos+cp, 0, 10%8, 4); cp = cp + emit_sib(buf, pos+cp, 3, 7, 10%8);
            // test r10, r10 — REX.WRB + 0x85
            cp = cp + emit_rex(buf, pos+cp, 1, 10/8, 0, 10/8); e2_w8(buf, pos+cp, 133); cp = cp + 1; cp = cp + emit_modrm(buf, pos+cp, 3, 10%8, 10%8);
            e2_w8(buf, pos+cp, 117); e2_w8(buf, pos+cp+1, 18); cp = cp + 2;  // jne valid

            e2_w8(buf, pos+cp, 191); e2_w32(buf, pos+cp+1, 1); cp = cp + 5;  // mov edi, 1
            grow_alloc_patch(g_x86_alloc_patch_count + 1); w64(g_x86_alloc_patch_pos, g_x86_alloc_patch_count * 8, pos + cp);
            g_x86_alloc_patch_count = g_x86_alloc_patch_count + 1;
            e2_w8(buf, pos+cp, 232); e2_w32(buf, pos+cp+1, 0); cp = cp + 5;  // call alloc
            // mov byte [rax], 0 — 0xC6 /0
            e2_w8(buf, pos+cp, 198); cp = cp + 1; cp = cp + emit_modrm(buf, pos+cp, 0, 0, 0); e2_w8(buf, pos+cp, 0); cp = cp + 1;
            cp = cp + e2_jmp(buf, pos+cp, 47);

            // xor edi, edi
            e2_w8(buf, pos+cp, 49); e2_w8(buf, pos+cp+1, 255); cp = cp + 2;
            // cmp byte [r10+rdi], 0 — 0x80 /7 + SIB
            cp = cp + emit_rex(buf, pos+cp, 0, 0, 0, 10/8); e2_w8(buf, pos+cp, 128); cp = cp + 1;
            cp = cp + emit_modrm(buf, pos+cp, 0, 7, 4); cp = cp + emit_sib(buf, pos+cp, 0, 7, 10%8); e2_w8(buf, pos+cp, 0); cp = cp + 1;
            e2_w8(buf, pos+cp, 116); e2_w8(buf, pos+cp+1, 8); cp = cp + 2;  // je len_done
            // inc rdi — REX.W + 0xFF /0
            cp = cp + emit_rex(buf, pos+cp, 1, 0, 0, 0); e2_w8(buf, pos+cp, 255); cp = cp + 1; cp = cp + emit_modrm(buf, pos+cp, 3, 0, 7);
            cp = cp + e2_jmp(buf, pos+cp, -15);
            // inc rdi (null terminator) — REX.W + 0xFF /0
            cp = cp + emit_rex(buf, pos+cp, 1, 0, 0, 0); e2_w8(buf, pos+cp, 255); cp = cp + 1; cp = cp + emit_modrm(buf, pos+cp, 3, 0, 7);
            // alloc clobbers caller-saved r10; preserve the argv[n] source pointer.
            e2_w8(buf, pos+cp, 65); e2_w8(buf, pos+cp+1, 82); cp = cp + 2;  // push r10
            grow_alloc_patch(g_x86_alloc_patch_count + 1); w64(g_x86_alloc_patch_pos, g_x86_alloc_patch_count * 8, pos + cp);
            g_x86_alloc_patch_count = g_x86_alloc_patch_count + 1;
            e2_w8(buf, pos+cp, 232); e2_w32(buf, pos+cp+1, 0); cp = cp + 5;  // call alloc
            e2_w8(buf, pos+cp, 65); e2_w8(buf, pos+cp+1, 90); cp = cp + 2;  // pop r10
            // xor r11d, r11d — REX.RB + 0x31
            cp = cp + emit_rex(buf, pos+cp, 0, 11/8, 0, 11/8); e2_w8(buf, pos+cp, 49); cp = cp + 1; cp = cp + emit_modrm(buf, pos+cp, 3, 11%8, 11%8);
            // mov dl, [r10+r11] — 0x8A + SIB (REX.X=1 for r11 index)
            cp = cp + emit_rex(buf, pos+cp, 0, 0, 11/8, 10/8); e2_w8(buf, pos+cp, 138); cp = cp + 1;
            cp = cp + emit_modrm(buf, pos+cp, 0, 2, 4); cp = cp + emit_sib(buf, pos+cp, 0, 11%8, 10%8);
            // mov [rax+r11], dl — 0x88 + SIB (REX.X=1 for r11 index)
            cp = cp + emit_rex(buf, pos+cp, 0, 0, 11/8, 0); e2_w8(buf, pos+cp, 136); cp = cp + 1;
            cp = cp + emit_modrm(buf, pos+cp, 0, 2, 4); cp = cp + emit_sib(buf, pos+cp, 0, 11%8, 0);
            // inc r11 — REX.WB + 0xFF /0
            cp = cp + emit_rex(buf, pos+cp, 0, 0, 0, 11/8); e2_w8(buf, pos+cp, 255); cp = cp + 1; cp = cp + emit_modrm(buf, pos+cp, 3, 0, 11%8);
            // test dl, dl
            e2_w8(buf, pos+cp, 132); cp = cp + 1; cp = cp + emit_modrm(buf, pos+cp, 3, 2, 2);
            e2_w8(buf, pos+cp, 117); e2_w8(buf, pos+cp+1, 241); cp = cp + 2;  // jne copy_loop
            if d >= 0 { cp = cp + e2_st(buf, pos+cp, 0, g2_slot(d)); }
        } else if s3 == g_ni_w64 {
            // w64(buf, pos, val) → mov [rsi+rdi??], rdx
            // Actually args: rdi=buf, rsi=pos, rdx=val
            // Just: mov [rdi+rsi], rdx
            cp = cp + emit_rex(buf, pos+cp, 1, 0, 0, 0); e2_w8(buf, pos+cp, 137); cp = cp + 1;
            cp = cp + emit_modrm(buf, pos+cp, 0, 2, 4); cp = cp + emit_sib(buf, pos+cp, 0, 6, 7);
        } else if s3 == g_ni_dyncpy {
            // _dyncpy(src, n, dst) → memcpy(dst, src, n)
            // rdi=src, rsi=n, rdx=dst
            // Loop: for(i=0; i<n; i++) store8(dst,i,load8(src,i))
            // i in rcx
            e2_w8(buf, pos+cp, 49); e2_w8(buf, pos+cp+1, 201); cp = cp + 2;  // xor ecx, ecx
            // loop:
            //   cmp rcx, rsi → jae done
            e2_w8(buf, pos+cp, 72); e2_w8(buf, pos+cp+1, 57); e2_w8(buf, pos+cp+2, 241); cp = cp + 3;  // cmp rcx, rsi
            e2_w8(buf, pos+cp, 115); e2_w8(buf, pos+cp+1, 11); cp = cp + 2;  // jae done (+11)
            //   mov al, [rdi+rcx]   (load8)
            e2_w8(buf, pos+cp, 138); cp = cp + 1;  // 0x8A MOV r8, r/m8
            cp = cp + emit_modrm(buf, pos+cp, 0, 0, 4);  // [SIB]
            cp = cp + emit_sib(buf, pos+cp, 0, 1, 7);  // [rcx][rdi]
            //   mov [rdx+rcx], al   (store8)
            e2_w8(buf, pos+cp, 136); cp = cp + 1;  // 0x88 MOV r/m8, r8
            cp = cp + emit_modrm(buf, pos+cp, 0, 0, 4);
            cp = cp + emit_sib(buf, pos+cp, 0, 1, 2);  // [rcx][rdx]
            //   inc rcx → jmp loop
            e2_w8(buf, pos+cp, 72); e2_w8(buf, pos+cp+1, 255); e2_w8(buf, pos+cp+2, 193); cp = cp + 3;  // inc rcx
            e2_w8(buf, pos+cp, 235); e2_w8(buf, pos+cp+1, 240); cp = cp + 2;  // jmp -16 (back to cmp rcx,rsi)
            // done:
        } else if s3 == g_ni_goroutine_wrapper_addr {
            // goroutine_wrapper_addr() — the address of goroutine_entry_wrapper
            // (backend-emitted stub / rt.s). Same encoding as IR_FNADDR:
            // movabs r10, imm64 + store; imm64 patched in elf.cr Phase 3.
            do2 := g2_slot(d);
            grow_fnaddr_patch(g_x86_fnaddr_patch_count + 1);
            w64(g_x86_fnaddr_patch_pos, g_x86_fnaddr_patch_count * 8, pos + cp);
            w64(g_x86_fnaddr_patch_name, g_x86_fnaddr_patch_count * 8, str_intern("goroutine_entry_wrapper"));
            g_x86_fnaddr_patch_count = g_x86_fnaddr_patch_count + 1;
            // movabs r10, imm64: REX.W+B = 0x49, opcode 0xBA (0xB8 + reg 2)
            e2_w8(buf, pos+cp, 73); e2_w8(buf, pos+cp+1, 186);
            e2_w64(buf, pos+cp+2, 0);  // placeholder — patched in elf.cr Phase 3
            cp = cp + 10;
            cp = cp + e2_st(buf, pos+cp, 10, do2);
        } else if s3 >= 0 {
            fn2 := istr_get(s3);
            to := -1; tf := 0;
            loop { if tf >= g_x86_func_off_count { break; } if str_eq(istr_get(r64(g_x86_func_offsets, tf*16)), fn2) != 0 { to = r64(g_x86_func_offsets, tf*16+8); break; } tf = tf + 1; }
                        // Record call position for post-emission patching
            grow_call_patch(g_x86_call_patch_count + 1);
            w64(g_x86_call_patch_pos, g_x86_call_patch_count * 8, pos + cp);
            w64(g_x86_call_patch_name, g_x86_call_patch_count * 8, str_intern(fn2));
            g_x86_call_patch_count = g_x86_call_patch_count + 1;
            if to >= 0 {
                cp = cp + e2_call(buf, pos+cp, (176 + to) - (pos + cp + 5));
            } else {
                // Unknown function: emit external relocation (for dynamic linking)
                grow_ext_rel(g_x86_ext_rel_count + 1);
                w64(g_x86_ext_rel_pos, g_x86_ext_rel_count * 8, pos + cp + 1);
                w64(g_x86_ext_rel_name, g_x86_ext_rel_count * 8, s3);
                g_x86_ext_rel_count = g_x86_ext_rel_count + 1;
                cp = cp + e2_call(buf, pos+cp, 0);
            }
            if d >= 0 { cp = cp + e2_st(buf, pos+cp, 0, g2_slot(d)); }
        } else {
            // xor eax, eax
            e2_w8(buf, pos+cp, 49); e2_w8(buf, pos+cp+1, 192); cp = cp + 2;
            if d >= 0 { cp = cp + e2_st(buf, pos+cp, 0, g2_slot(d)); }
        }
        stack_count := ac - 6;
        if stack_count > 0 {
            stack_bytes := stack_count * 8;
            if stack_bytes <= 127 {
                e2_w8(buf, pos+cp, 72); e2_w8(buf, pos+cp+1, 131);
                e2_w8(buf, pos+cp+2, 196); e2_w8(buf, pos+cp+3, stack_bytes); cp = cp + 4;
            } else {
                e2_w8(buf, pos+cp, 72); e2_w8(buf, pos+cp+1, 129); e2_w8(buf, pos+cp+2, 196);
                e2_w32(buf, pos+cp+3, stack_bytes); cp = cp + 7;
            }
        }
        return cp;
    }

    if op == IR_CALL_EXTERN {
        do2 := g2_slot(d);
        name_ni := s1;
        // Record external relocation
        grow_ext_rel(g_x86_ext_rel_count + 1);
        w64(g_x86_ext_rel_pos, g_x86_ext_rel_count * 8, pos + cp);
        w64(g_x86_ext_rel_name, g_x86_ext_rel_count * 8, name_ni);
        g_x86_ext_rel_count = g_x86_ext_rel_count + 1;
        // Emit call placeholder (E8 + rel32 = 0, patched later)
        e2_w8(buf, pos+cp, 232); e2_w32(buf, pos+cp+1, 0); cp = cp + 5;
        // Store return value from rax
        cp = cp + e2_st(buf, pos+cp, 0, do2);
        return cp;
    }

    if op == IR_HOTPATCH_ROUTE {
        do2 := g2_slot(d);
        name_ni := s1;
        grow_call_patch(g_x86_call_patch_count + 1);
        w64(g_x86_call_patch_pos, g_x86_call_patch_count * 8, pos + cp);
        w64(g_x86_call_patch_name, g_x86_call_patch_count * 8, name_ni);
        g_x86_call_patch_count = g_x86_call_patch_count + 1;
        e2_w8(buf, pos+cp, 232); e2_w32(buf, pos+cp+1, 0); cp = cp + 5;
        cp = cp + e2_st(buf, pos+cp, 0, do2);
        return cp;
    }

    if op == IR_SPAWN {
        do2 := g2_slot(d);
        name_ni := s1;
        // Emit call to function + store result (single-threaded mode for now)
        grow_call_patch(g_x86_call_patch_count + 1);
        w64(g_x86_call_patch_pos, g_x86_call_patch_count * 8, pos + cp);
        w64(g_x86_call_patch_name, g_x86_call_patch_count * 8, name_ni);
        g_x86_call_patch_count = g_x86_call_patch_count + 1;
        e2_w8(buf, pos+cp, 232); e2_w32(buf, pos+cp+1, 0); cp = cp + 5;
        cp = cp + e2_st(buf, pos+cp, 0, do2);
        return cp;
    }

    if op == IR_FNADDR {
        // Load function address into dest: movabs r10, imm64 + store.
        // The imm64 is a placeholder patched in Phase 3 (after all functions
        // are placed) with the function's absolute VA (TEXT_BASE + buf pos).
        do2 := g2_slot(d);
        name_ni := s1;
        grow_fnaddr_patch(g_x86_fnaddr_patch_count + 1);
        w64(g_x86_fnaddr_patch_pos, g_x86_fnaddr_patch_count * 8, pos + cp);
        w64(g_x86_fnaddr_patch_name, g_x86_fnaddr_patch_count * 8, name_ni);
        g_x86_fnaddr_patch_count = g_x86_fnaddr_patch_count + 1;
        // movabs r10, imm64: REX.W+B = 0x49, opcode 0xBA (0xB8 + reg 2,
        // REX.B extends to 10 = r10). 0x49 0xBB would encode r11 — the
        // following e2_st(..., 10, ...) stores r10, so the register MUST be r10.
        e2_w8(buf, pos+cp, 73); e2_w8(buf, pos+cp+1, 186);  // movabs r10, imm64
        e2_w64(buf, pos+cp+2, 0);  // placeholder — patched in elf.cr Phase 3
        cp = cp + 10;
        cp = cp + e2_st(buf, pos+cp, 10, do2);
        return cp;
    }

    if op == IR_RETURN {
        if s1 >= 0 {
            if r64(g_x86_is_global, s1 * 8) != 0 {
                // Global: load via RIP-relative into rax
                grow_rip_patch(g_x86_rip_patch_count + 1);
                w64(g_x86_rip_patch_pos, g_x86_rip_patch_count * 8, pos + cp + 3);
                w64(g_x86_rip_patch_globals, g_x86_rip_patch_count * 8, s1);
                g_x86_rip_patch_count = g_x86_rip_patch_count + 1;
                cp = cp + e2_lr(buf, pos+cp, 0);       // lea r10, [rip+0]
                // mov rax, [r10] — REX.WB + 0x8B
            cp = cp + emit_rex(buf, pos+cp, 1, 0, 0, 10/8); e2_w8(buf, pos+cp, 139); cp = cp + 1; cp = cp + emit_modrm(buf, pos+cp, 0, 0, 10%8);
            } else { cp = cp + e2_ld(buf, pos+cp, 0, g2_slot(s1)); }
        }
        // record position for caller to patch jmp → epilogue
        grow_ret_patch(g_x86_ret_patch_count + 1); w64(g_x86_ret_patch_pos, g_x86_ret_patch_count * 8, pos + cp);
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
                    grow_alloc_patch(g_x86_alloc_patch_count + 1); w64(g_x86_alloc_patch_pos, g_x86_alloc_patch_count * 8, pos + cp);
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
            grow_alloc_patch(g_x86_alloc_patch_count + 1); w64(g_x86_alloc_patch_pos, g_x86_alloc_patch_count * 8, pos + cp);
            g_x86_alloc_patch_count = g_x86_alloc_patch_count + 1;
            e2_w8(buf, pos+cp, 232); e2_w32(buf, pos+cp+1, 0); cp = cp + 5;  // call placeholder
            cp = cp + e2_st(buf, pos+cp, 0, do2);
        }
        return cp;
    }

    if op == IR_ARENA_NEW {
        do2 := g2_slot(d);
        if s1 > 0 {
            // Scope actually allocates: create a fresh arena via arena_new().
            ni_arena_new := str_intern("arena_new");
            grow_call_patch(g_x86_call_patch_count + 1);
            w64(g_x86_call_patch_pos, g_x86_call_patch_count * 8, pos + cp);
            w64(g_x86_call_patch_name, g_x86_call_patch_count * 8, ni_arena_new);
            g_x86_call_patch_count = g_x86_call_patch_count + 1;
            e2_w8(buf, pos+cp, 232); e2_w32(buf, pos+cp+1, 0); cp = cp + 5;  // call placeholder
            cp = cp + e2_st(buf, pos+cp, 0, do2);  // store returned arena_id from rax
        } else {
            // No allocations in this scope: no arena. dest = -1 (none).
            // Avoids calling arena_new from arena infrastructure itself
            // (arena_new/arena_reset/_grow_arena_meta), which would recurse.
            // IR_ARENA_RESET with id < 0 is a safe no-op in arena_reset.
            w8(buf, pos+cp, 72); w8(buf, pos+cp+1, 199); w8(buf, pos+cp+2, 192);
            e2_w32(buf, pos+cp+3, -1); cp = cp + 7;  // mov rax, -1
            cp = cp + e2_st(buf, pos+cp, 0, do2);
        }
        return cp;
    }

    if op == IR_ARENA_RESET {
        // Load arena_id into edi (register 7 = rdi for first arg)
        cp = cp + e2_load_var(buf, pos+cp, 7, s1);
        // Skip the call when no arena was created (id < 0). Without this,
        // arena_reset's own exit marker would call arena_reset(-1), whose
        // early return still runs its exit marker → infinite recursion.
        // test rdi, rdi — 48 85 FF
        w8(buf, pos+cp, 72); w8(buf, pos+cp+1, 133); w8(buf, pos+cp+2, 255); cp = cp + 3;
        // jl +5 (skip the 5-byte call) — 7C 05
        w8(buf, pos+cp, 124); w8(buf, pos+cp+1, 5); cp = cp + 2;
        ni_arena_reset := str_intern("arena_reset");
        grow_call_patch(g_x86_call_patch_count + 1);
        w64(g_x86_call_patch_pos, g_x86_call_patch_count * 8, pos + cp);
        w64(g_x86_call_patch_name, g_x86_call_patch_count * 8, ni_arena_reset);
        g_x86_call_patch_count = g_x86_call_patch_count + 1;
        e2_w8(buf, pos+cp, 232); e2_w32(buf, pos+cp+1, 0); cp = cp + 5;  // call placeholder
        return cp;
    }

    if op == IR_LOAD && d >= 0 {
        do2 := g2_slot(d);
        if s1 >= 0 {
            isg : ., mut = r64(g_x86_is_global, s1 * 8);
            if isg != 0 {
                grow_rip_patch(g_x86_rip_patch_count + 1);
                w64(g_x86_rip_patch_pos, g_x86_rip_patch_count * 8, pos + cp + 3);
                w64(g_x86_rip_patch_globals, g_x86_rip_patch_count * 8, s1);
                g_x86_rip_patch_count = g_x86_rip_patch_count + 1;
                cp = cp + e2_lr(buf, pos+cp, 0);
                // mov r10, [r10] — REX.WRB + 0x8B
            cp = cp + emit_rex(buf, pos+cp, 1, 10/8, 0, 10/8); e2_w8(buf, pos+cp, 139); cp = cp + 1; cp = cp + emit_modrm(buf, pos+cp, 0, 10%8, 10%8);
                cp = cp + e2_st(buf, pos+cp, 10, do2);
            } else { cp = cp + e2_load_var(buf, pos+cp, 10, s1); cp = cp + e2_st(buf, pos+cp, 10, do2); }
        } else { cp = cp + e2_load_var(buf, pos+cp, 10, s1); cp = cp + e2_st(buf, pos+cp, 10, do2); }
        return cp;
    }

    if op == IR_STORE {
        o1 := g2_slot(s1);
        if s1 >= 0 {
            if r64(g_x86_is_global, s1 * 8) != 0 {
                cp = cp + e2_load_var(buf, pos+cp, 10, s2);
                grow_rip_patch(g_x86_rip_patch_count + 1);
                w64(g_x86_rip_patch_pos, g_x86_rip_patch_count * 8, pos + cp + 3);
                w64(g_x86_rip_patch_globals, g_x86_rip_patch_count * 8, s1);
                g_x86_rip_patch_count = g_x86_rip_patch_count + 1;
                cp = cp + e2_lrb(buf, pos+cp, 0);
                // mov [r11], r10 — REX.WRB + 0x89
                cp = cp + emit_rex(buf, pos+cp, 1, 10/8, 0, 11/8); e2_w8(buf, pos+cp, 137); cp = cp + 1; cp = cp + emit_modrm(buf, pos+cp, 0, 10%8, 11%8);
            } else { cp = cp + e2_load_var(buf, pos+cp, 10, s2); cp = cp + e2_st(buf, pos+cp, 10, o1); }
        } else { cp = cp + e2_load_var(buf, pos+cp, 10, s2); cp = cp + e2_st(buf, pos+cp, 10, o1); }
        return cp;
    }

    if op == IR_LOAD_FIELD && d >= 0 {
        o1 := g2_slot(s1); do2 := g2_slot(d); fi2 := s3;
        fo : ., mut = fi2 * 8;
        cp = cp + e2_ld(buf, pos+cp, 10, o1);
        // mov r10, [r10 + disp32] — REX.WRB + 0x8B
            cp = cp + emit_rex(buf, pos+cp, 1, 10/8, 0, 10/8); e2_w8(buf, pos+cp, 139); cp = cp + 1;
            cp = cp + emit_modrm(buf, pos+cp, 2, 10%8, 10%8); cp = cp + e2_w32(buf, pos+cp, fo);
        cp = cp + e2_st(buf, pos+cp, 10, do2);
        return cp;
    }

    if op == IR_STORE_FIELD {
        o1 := g2_slot(s1); o2 := g2_slot(s2); fi2 := s3;
        fo : ., mut = fi2 * 8;
        cp = cp + e2_ld(buf, pos+cp, 10, o1); cp = cp + e2_ld(buf, pos+cp, 11, o2);
        // mov [r10 + disp32], r11 — REX.WRB + 0x89
            cp = cp + emit_rex(buf, pos+cp, 1, 11/8, 0, 10/8); e2_w8(buf, pos+cp, 137); cp = cp + 1;
            cp = cp + emit_modrm(buf, pos+cp, 2, 11%8, 10%8); cp = cp + e2_w32(buf, pos+cp, fo);
        return cp;
    }

    if op == IR_REF && d >= 0 {
        do2 := g2_slot(d); o1 := g2_slot(s1);
        cp = cp + e2_lb(buf, pos+cp, o1); cp = cp + e2_st(buf, pos+cp, 10, do2);
        return cp;
    }

    if op == IR_DEREF && d >= 0 {
        do2 := g2_slot(d);
        // s3 encodes bounds info from ProvenanceVerify:
        //   s3 == 0: no check needed (provenance known)
        //   s3 != 0: load ptr into r10, then:
        //     1. page_offset = r10 & 0xFFF
        //     2. if page_offset >= alloc_size → crash (SIGILL)
        //     3. if r10 == 0 → crash
        //     4. safe deref: mov r10, [r10]
        cp = cp + e2_load_var(buf, pos+cp, 10, s1);
        if s3 != 0 {
            alloc_sz := s3;  // encoded alloc_size from ProvenanceVerify
            // --- cmp + jae + ud2 sequence (doc §ProvenanceVerify) ---
            // Copy r10 to r11 for offset computation
            cp = cp + emit_rex(buf, pos+cp, 1, 11/8, 0, 10/8);
            e2_w8(buf, pos+cp, 137); cp = cp + 1;  // 0x89 MOV r/m, r
            cp = cp + emit_modrm(buf, pos+cp, 3, 10%8, 11%8);  // mov r11, r10
            // and r11, 0xFFF (page offset)
            cp = cp + emit_rex(buf, pos+cp, 1, 0, 0, 11/8);
            e2_w8(buf, pos+cp, 129); cp = cp + 1;  // 0x81 AND r/m, imm32
            cp = cp + emit_modrm(buf, pos+cp, 3, 4, 11%8);  // /4 = AND
            e2_w32(buf, pos+cp, 4095); cp = cp + 4;  // mask 0xFFF
            // cmp r11, alloc_size
            cp = cp + emit_rex(buf, pos+cp, 1, 0, 0, 11/8);
            e2_w8(buf, pos+cp, 129); cp = cp + 1;  // 0x81 CMP r/m, imm32
            cp = cp + emit_modrm(buf, pos+cp, 3, 7, 11%8);  // /7 = CMP
            e2_w32(buf, pos+cp, alloc_sz); cp = cp + 4;
            // jae .crash (2-byte near jae: 0F 83)
            crash_jmp_pos := pos+cp;
            cp = cp + e2_jae(buf, pos+cp, 0);  // placeholder
            // test r10, r10 (null check)
            cp = cp + emit_rex(buf, pos+cp, 1, 10/8, 0, 10/8); e2_w8(buf, pos+cp, 133); cp = cp + 1; cp = cp + emit_modrm(buf, pos+cp, 3, 10%8, 10%8);
            // jne .safe (skip ud2 if non-null)
            safe_jmp_pos := pos+cp;
            e2_w8(buf, pos+cp, 117); e2_w8(buf, pos+cp+1, 0); cp = cp + 2;  // placeholder
            // .crash: ud2
            w8(buf, cp, 15); w8(buf, cp+1, 11); cp = cp + 2;
            // Patch jae to jump here
            e2_w32(buf, crash_jmp_pos + 2, (pos+cp) - (crash_jmp_pos + 6));
            // Patch jne to jump past ud2 to .safe
            w8(buf, safe_jmp_pos + 1, (pos+cp) - (safe_jmp_pos + 2) + 2);
            // .safe: deref
        }
        // mov r10, [r10]
        cp = cp + emit_rex(buf, pos+cp, 1, 10/8, 0, 10/8); e2_w8(buf, pos+cp, 139); cp = cp + 1; cp = cp + emit_modrm(buf, pos+cp, 0, 10%8, 10%8);
        cp = cp + e2_st(buf, pos+cp, 10, do2);
        return cp;
    }

    if op == IR_ADDR_INDEX && d >= 0 {
        do2 := g2_slot(d);
        // load array pointer from arr base slot (handles both local and global)
        cp = cp + e2_load_var(buf, pos+cp, 10, s1);
        // load index (handles both local and global)
        cp = cp + e2_load_var(buf, pos+cp, 11, s2);
        // lea r10, [r10 + r11*8] = address of arr[i] on heap
        cp = cp + emit_rex(buf, pos+cp, 1, 10/8, 11/8, 10/8);
        e2_w8(buf, pos+cp, 141); cp = cp + 1;  // 0x8D LEA
        cp = cp + emit_modrm(buf, pos+cp, 0, 10%8, 4);  // mod=0, reg=r10, rm=4(SIB)
        cp = cp + emit_sib(buf, pos+cp, 3, 11%8, 10%8);  // scale=3, index=r11, base=r10
        cp = cp + e2_st(buf, pos+cp, 10, do2);
        return cp;
    }

    if op == IR_STORE_PTR {
        // load pointer (handles local and global)
        cp = cp + e2_load_var(buf, pos+cp, 10, s1);
        // load value to store (handles local and global)
        cp = cp + e2_load_var(buf, pos+cp, 11, s2);
        // mov [r10], r11 — REX.WRB + 0x89
            cp = cp + emit_rex(buf, pos+cp, 1, 11/8, 0, 10/8); e2_w8(buf, pos+cp, 137); cp = cp + 1; cp = cp + emit_modrm(buf, pos+cp, 0, 11%8, 10%8);
        return cp;
    }

    if op == IR_BRANCH {
        cp = cp + e2_load_var(buf, pos+cp, 10, s1);
        // test r10, r10
        cp = cp + emit_rex(buf, pos+cp, 1, 10/8, 0, 10/8); e2_w8(buf, pos+cp, 133); cp = cp + 1; cp = cp + emit_modrm(buf, pos+cp, 3, 10%8, 10%8);
        // je → false_label (s3), jmp → true_label (s2)
        // Single-pass backpatching: known labels emit immediately, unknown record pending
        je_rel_pos := pos+cp + 2;
        cp = cp + e2_je(buf, pos+cp, 0);
        if s3 >= 0 && r64(g_label_poses, s3 * 8) >= 0 {
            target := r64(g_label_poses, s3 * 8);
            e2_w32(buf, je_rel_pos, target - (je_rel_pos + 4));
        } else if s3 >= 0 {
            grow_pending(g_pending_count + 1);
            w64(g_pending_pos, g_pending_count*8, je_rel_pos);
            w64(g_pending_label, g_pending_count*8, s3);
            g_pending_count = g_pending_count + 1;
        }
        jmp_rel_pos := pos+cp + 1;
        cp = cp + e2_jmp(buf, pos+cp, 0);
        if s2 >= 0 && r64(g_label_poses, s2 * 8) >= 0 {
            target := r64(g_label_poses, s2 * 8);
            e2_w32(buf, jmp_rel_pos, target - (jmp_rel_pos + 4));
        } else if s2 >= 0 {
            grow_pending(g_pending_count + 1);
            w64(g_pending_pos, g_pending_count*8, jmp_rel_pos);
            w64(g_pending_label, g_pending_count*8, s2);
            g_pending_count = g_pending_count + 1;
        }
        return cp;
    }

    if op == IR_JUMP {
        jmp_rel_pos := pos+cp + 1;
        cp = cp + e2_jmp(buf, pos+cp, 0);
        if s1 >= 0 && r64(g_label_poses, s1 * 8) >= 0 {
            target := r64(g_label_poses, s1 * 8);
            e2_w32(buf, jmp_rel_pos, target - (jmp_rel_pos + 4));
        } else if s1 >= 0 {
            grow_pending(g_pending_count + 1);
            w64(g_pending_pos, g_pending_count*8, jmp_rel_pos);
            w64(g_pending_label, g_pending_count*8, s1);
            g_pending_count = g_pending_count + 1;
        }
        return cp;
    }

    if op == IR_LABEL {
        li := iri_s1(instr_idx);
        if li >= 0 {
            grow_label_poses(li + 1);
            w64(g_label_poses, li * 8, pos);
            if li + 1 > g_label_count { g_label_count = li + 1; }
            // Patch all pending forward jumps targeting this label
            pi : ., mut = 0;
            loop { if pi >= g_pending_count { break; }
                if r64(g_pending_label, pi * 8) == li {
                    rp := r64(g_pending_pos, pi * 8);
                    e2_w32(buf, rp, pos - (rp + 4));
                    w64(g_pending_label, pi * 8, -1);
                }
            pi = pi + 1; }
        }
        return 0;
    }

    if op == IR_LOAD_ENUM_TAG && d >= 0 {
        o1 := g2_slot(s1); do2 := g2_slot(d);
        cp = cp + e2_ld(buf, pos+cp, 10, o1);
        // mov r10, [r10 + disp32] — tag at offset 0
        // mov r10, [r10 + 0] (enum tag)
            cp = cp + emit_rex(buf, pos+cp, 1, 10/8, 0, 10/8); e2_w8(buf, pos+cp, 139); cp = cp + 1;
            cp = cp + emit_modrm(buf, pos+cp, 2, 10%8, 10%8); cp = cp + e2_w32(buf, pos+cp, 0);
        cp = cp + e2_st(buf, pos+cp, 10, do2);
        return cp;
    }

    if op == IR_LOAD_INDEX && d >= 0 {
        do2 := g2_slot(d); idx := s3;
        // load array pointer (handles local and global)
        cp = cp + e2_load_var(buf, pos+cp, 10, s1);
        // mov r10, [r10 + disp32]
        // mov r10, [r10 + idx*8]
            cp = cp + emit_rex(buf, pos+cp, 1, 10/8, 0, 10/8); e2_w8(buf, pos+cp, 139); cp = cp + 1;
            cp = cp + emit_modrm(buf, pos+cp, 2, 10%8, 10%8); cp = cp + e2_w32(buf, pos+cp, idx * 8);
        cp = cp + e2_st(buf, pos+cp, 10, do2);
        return cp;
    }

    if op == IR_STORE_INDEX {
        idx := s3;
        // load array pointer (handles local and global)
        cp = cp + e2_load_var(buf, pos+cp, 10, s1);
        // load value to store (handles local and global)
        cp = cp + e2_load_var(buf, pos+cp, 11, s2);
        // mov [r10 + disp32], r11
        // mov [r10 + idx*8], r11
            cp = cp + emit_rex(buf, pos+cp, 1, 11/8, 0, 10/8); e2_w8(buf, pos+cp, 137); cp = cp + 1;
            cp = cp + emit_modrm(buf, pos+cp, 2, 11%8, 10%8); cp = cp + e2_w32(buf, pos+cp, idx * 8);
        return cp;
    }

    if op == IR_LOAD_INDEX_VAR && d >= 0 {
        do2 := g2_slot(d);
        // load array pointer (handles local and global)
        cp = cp + e2_load_var(buf, pos+cp, 10, s1);
        // load index (handles local and global)
        cp = cp + e2_load_var(buf, pos+cp, 11, s2);
        // mov r10, [r10 + r11*8] — SIB(scale=3, index=r11%8, base=r10%8)
            cp = cp + emit_rex(buf, pos+cp, 1, 10/8, 11/8, 10/8); e2_w8(buf, pos+cp, 139); cp = cp + 1;
            cp = cp + emit_modrm(buf, pos+cp, 0, 10%8, 4); cp = cp + emit_sib(buf, pos+cp, 3, 11%8, 10%8);
        cp = cp + e2_st(buf, pos+cp, 10, do2);
        return cp;
    }

    if op == IR_STORE_INDEX_VAR && d >= 0 {
        // load array pointer (handles local and global)
        cp = cp + e2_load_var(buf, pos+cp, 10, s1);
        // load index (handles local and global)
        cp = cp + e2_load_var(buf, pos+cp, 11, s2);
        // load value to store (handles local and global)
        cp = cp + e2_load_var(buf, pos+cp, 12, d);
        // mov [r10 + r11*8], r12 — SIB(scale=3, index=r11%8, base=r10%8)
            cp = cp + emit_rex(buf, pos+cp, 1, 12/8, 11/8, 10/8); e2_w8(buf, pos+cp, 137); cp = cp + 1;
            cp = cp + emit_modrm(buf, pos+cp, 0, 12%8, 4); cp = cp + emit_sib(buf, pos+cp, 3, 11%8, 10%8);
        return cp;
    }

    if op == IR_MAKE_ENUM && d >= 0 {
        do2 := g2_slot(d); alloc_size := 8 + s2 * 8;
        e2_w8(buf, pos+cp, 191); e2_w32(buf, pos+cp+1, alloc_size); cp = cp + 5;  // mov edi, size
        grow_alloc_patch(g_x86_alloc_patch_count + 1); w64(g_x86_alloc_patch_pos, g_x86_alloc_patch_count * 8, pos + cp);
        g_x86_alloc_patch_count = g_x86_alloc_patch_count + 1;
        e2_w8(buf, pos+cp, 232); e2_w32(buf, pos+cp+1, 0); cp = cp + 5;  // call placeholder
        cp = cp + e2_st(buf, pos+cp, 0, do2);
        cp = cp + e2_ld(buf, pos+cp, 10, do2);
        // mov qword [r10 + 0], s1 — 0xC7 + REX.WB
            cp = cp + emit_rex(buf, pos+cp, 1, 0, 0, 10/8); e2_w8(buf, pos+cp, 199); cp = cp + 1;
            cp = cp + emit_modrm(buf, pos+cp, 0, 0, 10%8); cp = cp + e2_w32(buf, pos+cp, s1);
        return cp;
    }

    if op == IR_SLICE && d >= 0 {
        do2 := g2_slot(d); o1 := g2_slot(s1); o2 := g2_slot(s2);
        cp = cp + e2_ld(buf, pos+cp, 10, o1); cp = cp + e2_ld(buf, pos+cp, 11, o2);
        // shl r11, 3 — REX.WB + 0xC1, /4
            cp = cp + emit_rex(buf, pos+cp, 1, 0, 0, 11/8); e2_w8(buf, pos+cp, 193); cp = cp + 1;
            cp = cp + emit_modrm(buf, pos+cp, 3, 4, 11%8); e2_w8(buf, pos+cp, 3); cp = cp + 1;
        // add r10, r11 — REX.WRB + 0x01
            cp = cp + emit_rex(buf, pos+cp, 1, 11/8, 0, 10/8); e2_w8(buf, pos+cp, 1); cp = cp + 1; cp = cp + emit_modrm(buf, pos+cp, 3, 11%8, 10%8);
        cp = cp + e2_st(buf, pos+cp, 10, do2);
        return cp;
    }
    if op == IR_AWAIT && d >= 0 && s1 >= 0 {
        cp = cp + e2_ld(buf, pos+cp, 10, g2_slot(s1));
        cp = cp + e2_st(buf, pos+cp, 10, g2_slot(d));
        return cp;
    }

    if op == IR_BOUNDS_CHECK && s2 >= 0 {
        // s1 = index var, s2 = max_len literal — crash if index < 0 or index >= max_len
        cp = cp + e2_load_var(buf, pos+cp, 10, s1);  // index
        cp = cp + e2_load_var(buf, pos+cp, 11, s2);  // max_len
        cp = cp + e2_alu(buf, pos+cp, 57);           // cmp r10, r11
        // jb +2: if index < max (unsigned below), skip the 2-byte ud2 → continue
        e2_w8(buf, pos+cp, 114);                      // 0x72 = jb rel8
        e2_w8(buf, pos+cp+1, 2);                     // skip past ud2
        cp = cp + 2;
        w8(buf, cp, 15); w8(buf, cp+1, 11); cp = cp + 2;  // ud2 (SIGILL)
        return cp;
    }

    if op == IR_INLINE {
        // No-op at runtime — just a compile hint
        return 0;
    }
    if op == IR_NO_BOUNDS_CHECK {
        // No-op — consumed by ProvenanceVerify pass
        return 0;
    }
    if op == IR_FAST {
        // No-op — consumed by optimization passes
        return 0;
    }
    if op == IR_UNROLL {
        // No-op — consumed by loop unrolling pass
        return 0;
    }
    if op == IR_SECTION {
        // No-op — consumed by section assignment pass
        return 0;
    }
    if op == IR_LAZY_THUNK {
        // Calls are currently emitted eagerly before the thunk wrapper, so
        // lowering the wrapper is a typed value transfer.
        cp = cp + e2_load_var(buf, pos+cp, 10, s1);
        cp = cp + e2_st(buf, pos+cp, 10, g2_slot(d));
        return cp;
    }
    if op == IR_LAZY_FORCE {
        cp = cp + e2_load_var(buf, pos+cp, 10, s1);
        cp = cp + e2_st(buf, pos+cp, 10, g2_slot(d));
        return cp;
    }

    if op == IR_YIELD {
        // yield: call sched.sched_yield()
        ni_sched_yield := str_intern("sched_yield");
        grow_call_patch(g_x86_call_patch_count + 1);
        w64(g_x86_call_patch_pos, g_x86_call_patch_count * 8, pos + cp);
        w64(g_x86_call_patch_name, g_x86_call_patch_count * 8, ni_sched_yield);
        g_x86_call_patch_count = g_x86_call_patch_count + 1;
        e2_w8(buf, pos+cp, 232); e2_w32(buf, pos+cp+1, 0); cp = cp + 5;
        return cp;
    }

    // ── Dynamic type opcodes ──
    if op == IR_DYN_PACK && d >= 0 {
        // Pack value (s1) + tag (s2) into 16-byte dyn_var slot
        do2 := g2_slot(d);
        cp = cp + e2_load_var(buf, pos+cp, 10, s1);
        cp = cp + e2_st(buf, pos+cp, 10, do2);      // low 8: value
        cp = cp + e2_li(buf, pos+cp, do2 + 8, s2);  // high 8: tag (type index)
        return cp;
    }

    if op == IR_DYN_TAG && d >= 0 {
        // Extract tag from dyn_var (offset +8)
        do2 := g2_slot(d);
        s1do := g2_slot(s1);
        cp = cp + e2_ld(buf, pos+cp, 10, s1do + 8);
        cp = cp + e2_st(buf, pos+cp, 10, do2);
        return cp;
    }

    if op == IR_DYN_VAL && d >= 0 {
        // Extract value from dyn_var (offset +0)
        do2 := g2_slot(d);
        s1do := g2_slot(s1);
        cp = cp + e2_ld(buf, pos+cp, 10, s1do);
        cp = cp + e2_st(buf, pos+cp, 10, do2);
        return cp;
    }

    if op == IR_DYN_DISPATCH {
        // Tag dispatch table: load tag from dyn_var, compare against known types,
        // jump to common handler that extracts value, or type_error on mismatch.
        do2 := g2_slot(d);
        s1do := g2_slot(s1);
        ti_int : int = 0; ti_bool : int = 2; ti_str : int = 3;

        // 1. Load tag from dyn_var offset +8: mov r10, [rbp + s1do + 8]
        cp = cp + e2_ld(buf, pos+cp, 10, s1do + 8);

        // 2. Compare-and-jump chain using short rel8 jumps
        // cmp r10d, TI_INT (0) — REX.RB + 0x83 + ModRM(/7,r10%8) + imm8
        cp = cp + emit_rex(buf, pos+cp, 0, 0, 0, 10/8);
        e2_w8(buf, pos+cp, 131); cp = cp + 1;
        cp = cp + emit_modrm(buf, pos+cp, 3, 7, 10%8);
        e2_w8(buf, pos+cp, ti_int); cp = cp + 1;
        j1_off := cp;  // position of the je rel8 offset byte
        e2_w8(buf, pos+cp, 116); e2_w8(buf, pos+cp+1, 0); cp = cp + 2;  // 0x74 = je rel8

        // cmp r10d, TI_BOOL (2)
        cp = cp + emit_rex(buf, pos+cp, 0, 0, 0, 10/8);
        e2_w8(buf, pos+cp, 131); cp = cp + 1;
        cp = cp + emit_modrm(buf, pos+cp, 3, 7, 10%8);
        e2_w8(buf, pos+cp, ti_bool); cp = cp + 1;
        j2_off := cp;
        e2_w8(buf, pos+cp, 116); e2_w8(buf, pos+cp+1, 0); cp = cp + 2;

        // cmp r10d, TI_STR (3)
        cp = cp + emit_rex(buf, pos+cp, 0, 0, 0, 10/8);
        e2_w8(buf, pos+cp, 131); cp = cp + 1;
        cp = cp + emit_modrm(buf, pos+cp, 3, 7, 10%8);
        e2_w8(buf, pos+cp, ti_str); cp = cp + 1;
        j3_off := cp;
        e2_w8(buf, pos+cp, 116); e2_w8(buf, pos+cp+1, 0); cp = cp + 2;

        // 3. .type_error: no known type matched — fall through from compare chain
        //    xor eax, eax; ret
        e2_w8(buf, pos+cp, 49); e2_w8(buf, pos+cp+1, 192); cp = cp + 2;  // xor eax, eax
        e2_w8(buf, pos+cp, 195); cp = cp + 1;  // ret

        // 4. .case_common: extract value from dyn_var offset +0
        case_pos := cp;
        cp = cp + e2_ld(buf, pos+cp, 10, s1do);
        // jmp rel8 .done
        jmp_done_off := cp;
        e2_w8(buf, pos+cp, 235); e2_w8(buf, pos+cp+1, 0); cp = cp + 2;  // 0xEB = jmp rel8

        // 5. .done: store extracted value in destination slot
        done_pos := cp;
        if d >= 0 {
            cp = cp + e2_st(buf, pos+cp, 10, do2);
        }

        // 6. Patch all forward jump offsets (rel8)
        e2_w8(buf, j1_off + 1, case_pos - (j1_off + 2));
        e2_w8(buf, j2_off + 1, case_pos - (j2_off + 2));
        e2_w8(buf, j3_off + 1, case_pos - (j3_off + 2));
        e2_w8(buf, jmp_done_off + 1, done_pos - (jmp_done_off + 2));

        return cp;
    }

    return 0;
}
