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
    g_x86_ext_rel_count = 0;
    // g_x86_rip_patch_count NOT reset
}

// ── Optimization metadata: register assignment lookup ──
// Reads g_opt_meta (saved in .ccr v3+) to find register for a variable.
// Returns -1 if no register assigned.

fn get_reg_for_var(var_idx: int) -> int {
    mi : ., mut = 0;
    loop { if mi >= g_opt_meta_count { break; }
        mk := r32(g_opt_meta, mi * 16);
        if mk == OPT_KEY_REG_ASSIGN {
            data_len := r32(g_opt_meta, mi * 16 + 4);
            di : ., mut = 4;  // skip count u32, pairs start at +4
            loop { if di >= data_len { break; }
                vi := r32(g_opt_meta, mi * 16 + 8 + di);
                if vi == var_idx {
                    return r32(g_opt_meta, mi * 16 + 8 + di + 4);
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
fn e2_w16(buf: string, off: int, val: int) { e2_w8(buf, off, val % 256); e2_w8(buf, off+1, (val/256) % 256); }
fn e2_w32(buf: string, pos: int, val: int) -> int {
    uv : ., mut = val;
    if uv < 0 { uv = uv + 4294967296; }  // two's complement for negative rel32
    e2_w8(buf, pos, uv % 256); e2_w8(buf, pos+1, (uv/256) % 256);
    e2_w8(buf, pos+2, (uv/65536) % 256); e2_w8(buf, pos+3, (uv/16777216) % 256);
    return 4;
}
fn e2_w64(buf: string, pos: int, val: int) -> int { e2_w32(buf, pos, val); e2_w32(buf, pos+4, val/4294967296); return 8; }

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
    if v < -2147483648 || v >= 2147483648 {
        // Step 1: mov rax, imm64 (REX.W + 0xB8 MOV r, imm + rax + 8B imm)
        cp = cp + emit_rex(b, cp, 1, 0, 0, 0);
        e2_w8(b, cp, 184); cp = cp + 1;  // 0xB8 MOV r, imm (reg=0→rax)
        cp = cp + e2_w32(b, cp, v);
        cp = cp + e2_w32(b, cp, v/4294967296);
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
    if v >= 0 {
        if g_x86_global_cap > v {
            if r64(g_x86_is_global, v * 8) != 0 { return sz_lr() + 3; }
        }
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
        } else if s3 == g_ni_load64 || s3 == g_ni_load_str_ptr {
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
            cp = cp + e2_jmp(buf, pos+cp, 43);

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
            grow_alloc_patch(g_x86_alloc_patch_count + 1); w64(g_x86_alloc_patch_pos, g_x86_alloc_patch_count * 8, pos + cp);
            g_x86_alloc_patch_count = g_x86_alloc_patch_count + 1;
            e2_w8(buf, pos+cp, 232); e2_w32(buf, pos+cp+1, 0); cp = cp + 5;  // call alloc
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

    if op == IR_LOAD && d >= 0 {
        do2 := g2_slot(d);
        if s1 >= 0 {
            if r64(g_x86_is_global, s1 * 8) != 0 {
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
            cp = cp + emit_modrm(buf, pos+cp, 2, 10%8, 10%8); cp = cp + e2_w32(buf, cp, fo);
        cp = cp + e2_st(buf, pos+cp, 10, do2);
        return cp;
    }

    if op == IR_STORE_FIELD {
        o1 := g2_slot(s1); o2 := g2_slot(s2); fi2 := s3;
        fo : ., mut = fi2 * 8;
        cp = cp + e2_ld(buf, pos+cp, 10, o1); cp = cp + e2_ld(buf, pos+cp, 11, o2);
        // mov [r10 + disp32], r11 — REX.WRB + 0x89
            cp = cp + emit_rex(buf, pos+cp, 1, 11/8, 0, 10/8); e2_w8(buf, pos+cp, 137); cp = cp + 1;
            cp = cp + emit_modrm(buf, pos+cp, 2, 11%8, 10%8); cp = cp + e2_w32(buf, cp, fo);
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
        // mov r10, [r10] — REX.WRB + 0x8B
            cp = cp + emit_rex(buf, pos+cp, 1, 10/8, 0, 10/8); e2_w8(buf, pos+cp, 139); cp = cp + 1; cp = cp + emit_modrm(buf, pos+cp, 0, 10%8, 10%8);
        cp = cp + e2_st(buf, pos+cp, 10, do2);
        return cp;
    }

    if op == IR_STORE_PTR {
        o1 := g2_slot(s1); o2 := g2_slot(s2);
        cp = cp + e2_ld(buf, pos+cp, 10, o1); cp = cp + e2_ld(buf, pos+cp, 11, o2);
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
            cp = cp + emit_modrm(buf, pos+cp, 2, 10%8, 10%8); cp = cp + e2_w32(buf, cp, 0);
        cp = cp + e2_st(buf, pos+cp, 10, do2);
        return cp;
    }

    if op == IR_LOAD_INDEX && d >= 0 {
        do2 := g2_slot(d); o1 := g2_slot(s1); idx := s3;
        cp = cp + e2_ld(buf, pos+cp, 10, o1);
        // mov r10, [r10 + disp32]
        // mov r10, [r10 + idx*8]
            cp = cp + emit_rex(buf, pos+cp, 1, 10/8, 0, 10/8); e2_w8(buf, pos+cp, 139); cp = cp + 1;
            cp = cp + emit_modrm(buf, pos+cp, 2, 10%8, 10%8); cp = cp + e2_w32(buf, cp, idx * 8);
        cp = cp + e2_st(buf, pos+cp, 10, do2);
        return cp;
    }

    if op == IR_STORE_INDEX {
        o1 := g2_slot(s1); o2 := g2_slot(s2); idx := s3;
        cp = cp + e2_ld(buf, pos+cp, 10, o1); cp = cp + e2_ld(buf, pos+cp, 11, o2);
        // mov [r10 + disp32], r11
        // mov [r10 + idx*8], r11
            cp = cp + emit_rex(buf, pos+cp, 1, 11/8, 0, 10/8); e2_w8(buf, pos+cp, 137); cp = cp + 1;
            cp = cp + emit_modrm(buf, pos+cp, 2, 11%8, 10%8); cp = cp + e2_w32(buf, cp, idx * 8);
        return cp;
    }

    if op == IR_LOAD_INDEX_VAR && d >= 0 {
        do2 := g2_slot(d); o1 := g2_slot(s1); oi := g2_slot(s2);
        cp = cp + e2_ld(buf, pos+cp, 10, o1); cp = cp + e2_ld(buf, pos+cp, 11, oi);
        // mov r10, [r10 + r11*8] — SIB(scale=3, index=r11%8, base=r10%8)
            cp = cp + emit_rex(buf, pos+cp, 1, 10/8, 0, 10/8); e2_w8(buf, pos+cp, 139); cp = cp + 1;
            cp = cp + emit_modrm(buf, pos+cp, 0, 10%8, 4); cp = cp + emit_sib(buf, pos+cp, 3, 11%8, 10%8);
        cp = cp + e2_st(buf, pos+cp, 10, do2);
        return cp;
    }

    if op == IR_STORE_INDEX_VAR && d >= 0 {
        o1 := g2_slot(s1); oi := g2_slot(s2); ov := g2_slot(d);
        cp = cp + e2_ld(buf, pos+cp, 10, o1); cp = cp + e2_ld(buf, pos+cp, 11, oi); cp = cp + e2_ld(buf, pos+cp, 12, ov);
        // mov [r12 + r11*8], r10 — SIB(scale=3, index=r11%8, base=r12%8)
            cp = cp + emit_rex(buf, pos+cp, 1, 10/8, 0, 12/8); e2_w8(buf, pos+cp, 137); cp = cp + 1;
            cp = cp + emit_modrm(buf, pos+cp, 0, 10%8, 4); cp = cp + emit_sib(buf, pos+cp, 3, 11%8, 12%8);
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
            cp = cp + emit_modrm(buf, pos+cp, 0, 0, 10%8); cp = cp + e2_w32(buf, cp, s1);
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


    return 0;
}
