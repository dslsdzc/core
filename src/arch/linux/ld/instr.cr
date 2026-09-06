// ══════════════════════════════════════════════════════════════
// Binary emit interface — state + helpers + emit_instr
// ══════════════════════════════════════════════════════════════

// State globals (set by caller before emit phase)
g_x86_rodata_base : int, mut;
g_x86_func_frame_start : int, mut;  // abs buf pos of current function body (after frame)
g_current_func_var_start : int, mut;  // var_start of current function, set before emit
g_hit_tabled_count : int, mut;  // 表驱动实际发射事件条数（诊断：corearch 表模式总结）

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

fn e2_ptr_bounds_check(b: string, p: int, base_var: int, alloc_sz: int, access_width: int) -> int {
    if base_var < 0 || alloc_sz <= 0 { return 0; }
    width : ., mut = access_width;
    if width <= 0 { width = 8; }
    limit : ., mut = alloc_sz - width + 1;
    if limit < 0 { limit = 0; }

    cp : ., mut = 0;
    cp = cp + e2_load_var(b, p+cp, 11, base_var);
    // rax = pointer - allocation base; keep r10 intact for the access.
    cp = cp + emit_rex(b, p+cp, 1, 10/8, 0, 0);
    e2_w8(b, p+cp, 137); cp = cp + 1;
    cp = cp + emit_modrm(b, p+cp, 3, 10%8, 0);
    cp = cp + emit_rex(b, p+cp, 1, 11/8, 0, 0);
    e2_w8(b, p+cp, 41); cp = cp + 1;
    cp = cp + emit_modrm(b, p+cp, 3, 11%8, 0);
    // F17：limit ≥ 2³¹ 时 cmp imm32 符号扩展会把 limit 变负——无符号比较永不陷阱。
    // 改为 movabs rcx, imm64 + cmp rax, rcx（64 位无符号比较正确）。
    // movabs rcx, imm64 — REX.W 0x48 + 0xB9 + imm64
    e2_w8(b, p+cp, 72); e2_w8(b, p+cp+1, 185);
    e2_w64(b, p+cp+2, limit); cp = cp + 10;
    // cmp rax, rcx — REX.W 0x48 + 0x39 + ModRM(3, reg=1, rm=0)
    cp = cp + emit_rex(b, p+cp, 1, 0, 0, 0);
    e2_w8(b, p+cp, 57); cp = cp + 1;
    cp = cp + emit_modrm(b, p+cp, 3, 1, 0);
    crash_jmp_pos := p+cp;
    cp = cp + e2_jae(b, p+cp, 0);
    cp = cp + emit_rex(b, p+cp, 1, 10/8, 0, 10/8);
    e2_w8(b, p+cp, 133); cp = cp + 1;
    cp = cp + emit_modrm(b, p+cp, 3, 10%8, 10%8);
    safe_jmp_pos := p+cp;
    e2_w8(b, p+cp, 117); e2_w8(b, p+cp+1, 0); cp = cp + 2;
    e2_w8(b, p+cp, 15); e2_w8(b, p+cp+1, 11); cp = cp + 2;
    e2_w32(b, crash_jmp_pos + 2, (p+cp) - (crash_jmp_pos + 6) - 2);
    w8(b, safe_jmp_pos + 1, (p+cp) - (safe_jmp_pos + 2));
    return cp;
}

// F6：仅 null 陷阱（无分配信息时——s3=0 快速路径）。
// test r10, r10（REX.WRB 0x4D 0x85 0xD2）；null → ud2（SIGILL）
fn e2_ptr_null_check(b: string, p: int) -> int {
    cp := p;
    cp = cp + emit_rex(b, cp, 1, 10/8, 0, 10/8);
    e2_w8(b, cp, 133); cp = cp + 1;
    cp = cp + emit_modrm(b, cp, 3, 10%8, 10%8);
    e2_w8(b, cp, 117); e2_w8(b, cp+1, 2); cp = cp + 2;  // jne +2 (skip ud2)
    e2_w8(b, cp, 15); e2_w8(b, cp+1, 11); cp = cp + 2;  // ud2 (SIGILL)
    return cp - p;
}

// F14：movabs rdi, imm64 — REX.W 0x48 + 0xBF + imm64（64 位尺寸语义；
// 修复前 mov edi, imm32 对 ≥2³² 尺寸按 mod 2³² 回绕）
fn e2_movabs_rdi(b: string, p: int, v: int) -> int {
    e2_w8(b, p, 72); e2_w8(b, p+1, 191); e2_w64(b, p+2, v); return 10;
}
fn e2_alu(b: string, p: int, op: int) -> int {
    // ALU r/m, r: REX.W + REX.RB (r11, r10) + opcode + ModRM reg=11, rm=10
    cp := p;
    cp = cp + emit_rex(b, cp, 1, 1, 0, 1);  // W=1, R=1(r11/8), B=1(r10/8)
    e2_w8(b, cp, op); cp = cp + 1;
    cp = cp + emit_modrm(b, cp, 3, 11%8, 10%8);  // mod=3(register), reg=3, rm=2
    return cp - p;
}

// ── SSE2 double 运算（IEEE 754 标准，float 支持）──
// movsd xmm0, [rbp+disp] — F2 0F 10 /0
fn e2_sd_load(b: string, p: int, o: int) -> int {
    cp := p;
    w8(b, cp, 242); w8(b, cp+1, 15); w8(b, cp+2, 16); cp = cp + 3;
    if o >= -128 && o <= 127 {
        w8(b, cp, 69); w8(b, cp+1, o); cp = cp + 2;      // ModRM 01 000 101
    } else {
        w8(b, cp, 133); cp = cp + 1;                     // ModRM 10 000 101
        cp = cp + e2_w32(b, cp, o);
    }
    return cp - p;
}
// movsd xmm1, [rbp+disp] — F2 0F 10 /1
fn e2_sd_load1(b: string, p: int, o: int) -> int {
    cp := p;
    w8(b, cp, 242); w8(b, cp+1, 15); w8(b, cp+2, 16); cp = cp + 3;
    if o >= -128 && o <= 127 {
        w8(b, cp, 77); w8(b, cp+1, o); cp = cp + 2;      // ModRM 01 001 101
    } else {
        w8(b, cp, 141); cp = cp + 1;                     // ModRM 10 001 101
        cp = cp + e2_w32(b, cp, o);
    }
    return cp - p;
}
// movsd xmm{rn}, [rbp+disp] — F2 0F 10 /rn（rn=0..7，SysV float 参数）
fn e2_sd_load_x(b: string, p: int, o: int, rn: int) -> int {
    cp := p;
    w8(b, cp, 242); w8(b, cp+1, 15); w8(b, cp+2, 16); cp = cp + 3;
    if o >= -128 && o <= 127 {
        w8(b, cp, 64 + rn * 8 + 5); w8(b, cp+1, o); cp = cp + 2;
    } else {
        w8(b, cp, 128 + rn * 8 + 5); cp = cp + 1;
        cp = cp + e2_w32(b, cp, o);
    }
    return cp - p;
}

// 存返回值到 dest：dex（binary64，apx 快路径）→ movsd [slot], xmm0（SysV XMM0 返回）；int → rax
fn e2_store_ret(b: string, p: int, d: int) -> int {
    if d >= 0 && irv_type(d) == TI_DEX {
        return e2_sd_store(b, p, g2_slot(d));
    }
    return e2_st(b, p, 0, g2_slot(d));
}

// 压栈 binary64 值（8 字节，apx 快路径）：sub rsp,8 + movsd [rsp],xmm0
fn e2_push_xmm0(b: string, p: int) -> int {
    cp := p;
    w8(b, cp, 72); w8(b, cp+1, 131); w8(b, cp+2, 236); w8(b, cp+3, 8); cp = cp + 4;
    w8(b, cp, 242); w8(b, cp+1, 15); w8(b, cp+2, 17); w8(b, cp+3, 4); w8(b, cp+4, 36); cp = cp + 5;
    return cp - p;
}

fn e2_sd_cvt(b: string, p: int, o: int) -> int {
    cp := p;
    w8(b, cp, 242); w8(b, cp+1, 72); w8(b, cp+2, 15); w8(b, cp+3, 42); cp = cp + 4;
    if o >= -128 && o <= 127 {
        w8(b, cp, 69); w8(b, cp+1, o); cp = cp + 2;      // ModRM 01 000 101
    } else {
        w8(b, cp, 133); cp = cp + 1;                     // ModRM 10 000 101
        cp = cp + e2_w32(b, cp, o);
    }
    return cp - p;
}

// movsd [rbp+disp], xmm0 — F2 0F 11 /0
fn e2_sd_store(b: string, p: int, o: int) -> int {
    cp := p;
    w8(b, cp, 242); w8(b, cp+1, 15); w8(b, cp+2, 17); cp = cp + 3;
    if o >= -128 && o <= 127 {
        w8(b, cp, 69); w8(b, cp+1, o); cp = cp + 2;
    } else {
        w8(b, cp, 133); cp = cp + 1;
        cp = cp + e2_w32(b, cp, o);
    }
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

    if op == IR_I2F && d >= 0 {
        // int → binary64：cvtsi2sd xmm0, [rbp+disp] — F2 0F 2A /0，然后 movsd 存回
        do2 := g2_slot(d);
        cp = cp + e2_sd_cvt(buf, pos+cp, g2_slot(s1));   // cvtsi2sd xmm0, [s1]
        cp = cp + e2_sd_store(buf, pos+cp, do2);
        return cp;
    }

    if op == IR_F2I && d >= 0 {
        // binary64 → int：movsd xmm0, [s1]；cvttsd2si rax, xmm0（F2 48 0F 2C C0，截断）；存回
        do2 := g2_slot(d);
        cp = cp + e2_sd_load(buf, pos+cp, g2_slot(s1));
        w8(buf, pos+cp, 242); w8(buf, pos+cp+1, 72); w8(buf, pos+cp+2, 15);
        w8(buf, pos+cp+3, 44); w8(buf, pos+cp+4, 192); cp = cp + 5;
        cp = cp + e2_st(buf, pos+cp, 0, do2);
        return cp;
    }

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
        if ti == TI_DEX {
            // binary64 运算（SSE2 double，IEEE 754）——apx 快路径标准答案实现
            cp = cp + e2_sd_load(buf, pos+cp, g2_slot(s1));   // xmm0 = s1
            cp = cp + e2_sd_load1(buf, pos+cp, g2_slot(s2));  // xmm1 = s2
            // F2 0F 5x C1：addsd/subsd/mulsd/divsd xmm0, xmm1
            if s3 == OP_ADD { w8(buf, pos+cp, 242); w8(buf, pos+cp+1, 15); w8(buf, pos+cp+2, 88); w8(buf, pos+cp+3, 193); cp = cp + 4; }
            else if s3 == OP_SUB { w8(buf, pos+cp, 242); w8(buf, pos+cp+1, 15); w8(buf, pos+cp+2, 92); w8(buf, pos+cp+3, 193); cp = cp + 4; }
            else if s3 == OP_MUL { w8(buf, pos+cp, 242); w8(buf, pos+cp+1, 15); w8(buf, pos+cp+2, 89); w8(buf, pos+cp+3, 193); cp = cp + 4; }
            else if s3 == OP_DIV { w8(buf, pos+cp, 242); w8(buf, pos+cp+1, 15); w8(buf, pos+cp+2, 94); w8(buf, pos+cp+3, 193); cp = cp + 4; }
            if s3 >= OP_ADD && s3 <= OP_DIV {
                cp = cp + e2_sd_store(buf, pos+cp, do2);
            } else if s3 >= OP_EQ && s3 <= OP_GE {
                w8(buf, pos+cp, 102); w8(buf, pos+cp+1, 15); w8(buf, pos+cp+2, 47); w8(buf, pos+cp+3, 193); cp = cp + 4;
                if s3 == OP_EQ {
                    // setnp al（0F 9B C0）；sete cl（0F 94 C1）；and al, cl（20 C8）
                    w8(buf, pos+cp, 15); w8(buf, pos+cp+1, 155); w8(buf, pos+cp+2, 192); cp = cp + 3;
                    w8(buf, pos+cp, 15); w8(buf, pos+cp+1, 148); w8(buf, pos+cp+2, 193); cp = cp + 3;
                    w8(buf, pos+cp, 32); w8(buf, pos+cp+1, 200); cp = cp + 2;
                } else if s3 == OP_NE {
                    // setp al（0F 9A C0）；setne cl（0F 95 C1）；or al, cl（08 C8）
                    w8(buf, pos+cp, 15); w8(buf, pos+cp+1, 154); w8(buf, pos+cp+2, 192); cp = cp + 3;
                    w8(buf, pos+cp, 15); w8(buf, pos+cp+1, 149); w8(buf, pos+cp+2, 193); cp = cp + 3;
                    w8(buf, pos+cp, 8); w8(buf, pos+cp+1, 200); cp = cp + 2;
                } else {
                    // LT/GT/LE/GE 不动——硬件标志语义已正确（含无序时 LT/LE 为真）
                    sop : ., mut = 146;
                    if s3 == OP_GT { sop = 151; }   // seta（CF=0 && ZF=0）
                    else if s3 == OP_LE { sop = 150; }   // setbe
                    else if s3 == OP_GE { sop = 147; }   // setae
                    w8(buf, pos+cp, 15); w8(buf, pos+cp+1, sop); w8(buf, pos+cp+2, 192); cp = cp + 3;
                }
                // movzx r10d, al — 44 0F B6 D0
                w8(buf, pos+cp, 68); w8(buf, pos+cp+1, 15); w8(buf, pos+cp+2, 182); w8(buf, pos+cp+3, 208); cp = cp + 4;
                cp = cp + e2_st(buf, pos+cp, 10, do2);
            }
            return cp;
        }
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
        // SysV AMD64 参数分派：int 用 ir（0-5 → rdi,rsi,rdx,rcx,r8,r9），
        // binary64 参数用 fr（0-7 → xmm0-7），各自独立编号（标准答案）
        // 第一遍：寄存器参数（位置顺序，左到右）
        ir_cnt : ., mut = 0; fr_cnt : ., mut = 0;
        ai := 0;
        loop { if ai >= ac { break; }
            pt := irv_type(fa + ai);
            if pt == TI_DEX {
                if fr_cnt < 8 {
                    cp = cp + e2_sd_load_x(buf, pos+cp, g2_slot(fa + ai), fr_cnt);
                    fr_cnt = fr_cnt + 1;
                }
            } else {
                if ir_cnt < 6 {
                    r := -1;
                    if ir_cnt == 0 { r = 7; } if ir_cnt == 1 { r = 6; } if ir_cnt == 2 { r = 2; }
                    if ir_cnt == 3 { r = 1; } if ir_cnt == 4 { r = 8; } if ir_cnt == 5 { r = 9; }
                    cp = cp + e2_load_var(buf, pos+cp, r, fa + ai);
                    ir_cnt = ir_cnt + 1;
                }
            }
        ai = ai + 1; }
        // 第二遍：栈参数（右到左压，第 7 个 int / 第 9 个 binary64 超限才压）
        stack_total : ., mut = 0;
        stack_ai : ., mut = ac - 1;
        loop {
            if stack_ai < 0 { break; }
            ic2 : ., mut = 0; fc2 : ., mut = 0;
            j2 : ., mut = 0;
            loop { if j2 >= stack_ai { break; }
                if irv_type(fa + j2) == TI_DEX { fc2 = fc2 + 1; } else { ic2 = ic2 + 1; }
                j2 = j2 + 1; }
            if irv_type(fa + stack_ai) == TI_DEX {
                if fc2 >= 8 {
                    cp = cp + e2_sd_load_x(buf, pos+cp, g2_slot(fa + stack_ai), 0);
                    cp = cp + e2_push_xmm0(buf, pos+cp);
                    stack_total = stack_total + 1;
                }
            } else {
                if ic2 >= 6 {
                    cp = cp + e2_load_var(buf, pos+cp, 10, fa + stack_ai);
                    e2_w8(buf, pos+cp, 65); e2_w8(buf, pos+cp+1, 82); cp = cp + 2;  // push r10
                    stack_total = stack_total + 1;
                }
            }
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
            if d >= 0 { cp = cp + e2_store_ret(buf, pos+cp, d); }
        } else if s3 == g_ni_syscall4 {
            // syscall4(num, a, b, c, d)——第 4 参 d 经 r10 传递（x86-64 syscall
            // 约定：第 4 参在 r10；rcx 被 syscall 指令用作返回地址）。
            // I-2：wait4 的 rusage 此前无第 4 参通道——通用装载器把第 4 参放
            // rcx（ir_cnt=3）、第 5 参放 r8（ir_cnt=4），syscall 读 r10 = 残留
            // 垃圾 → 内核 EFAULT 或写错地址 → 退出码传播不可靠。
            cp = cp + e2_mov(buf, pos+cp, 0, 7);   // rax = rdi — syscall number
            cp = cp + e2_mov(buf, pos+cp, 7, 6);   // rdi = rsi — arg1
            cp = cp + e2_mov(buf, pos+cp, 6, 2);   // rsi = rdx — arg2
            cp = cp + e2_mov(buf, pos+cp, 2, 1);   // rdx = rcx — arg3
            cp = cp + e2_mov(buf, pos+cp, 10, 8);  // r10 = r8  — arg4
            // syscall: 2-byte 0x0F 0x05
            e2_w8(buf, pos+cp, 15); e2_w8(buf, pos+cp+1, 5); cp = cp + 2;
            if d >= 0 { cp = cp + e2_store_ret(buf, pos+cp, d); }
        } else if s3 == g_ni_load8 {
            // movzx rax, byte [rdi+rsi] — REX.W + 0x0FB6 + SIB
            cp = cp + emit_rex(buf, pos+cp, 1, 0, 0, 0); e2_w8(buf, pos+cp, 15); cp = cp + 1; e2_w8(buf, pos+cp, 182); cp = cp + 1;
            cp = cp + emit_modrm(buf, pos+cp, 0, 0, 4); cp = cp + emit_sib(buf, pos+cp, 0, 6, 7);
            if d >= 0 { cp = cp + e2_store_ret(buf, pos+cp, d); }
        } else if s3 == g_ni_store8 {
            // mov [rdi+rsi], dl — 0x88 + SIB (3rd arg in rdx = register 2)
            e2_w8(buf, pos+cp, 136); cp = cp + 1; cp = cp + emit_modrm(buf, pos+cp, 0, 2, 4); cp = cp + emit_sib(buf, pos+cp, 0, 6, 7);
        } else if s3 == g_ni_load64 || s3 == g_ni_load_str_ptr || s3 == g_ni_r64 {
            // mov rax, [rdi + rsi]
            // mov rax, [rdi+rsi] — REX.W + 0x8B + SIB
            cp = cp + emit_rex(buf, pos+cp, 1, 0, 0, 0); e2_w8(buf, pos+cp, 139); cp = cp + 1;
            cp = cp + emit_modrm(buf, pos+cp, 0, 0, 4); cp = cp + emit_sib(buf, pos+cp, 0, 6, 7);
            if d >= 0 { cp = cp + e2_store_ret(buf, pos+cp, d); }
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
            if d >= 0 { cp = cp + e2_store_ret(buf, pos+cp, d); }
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
            if d >= 0 { cp = cp + e2_store_ret(buf, pos+cp, d); }
        } else {
            // xor eax, eax
            e2_w8(buf, pos+cp, 49); e2_w8(buf, pos+cp+1, 192); cp = cp + 2;
            if d >= 0 { cp = cp + e2_store_ret(buf, pos+cp, d); }
        }
        stack_count := stack_total;   // 实际压栈数（int 超 6 + float 超 8）
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
        // F16①：装载参数（s2=首参、s3=参数个数，SysV AMD64 约定：
        // int rdi,rsi,rdx,rcx,r8,r9；float xmm0-7）——修复前 call 前无任何装载。
        fa2 := s2; ac2 := s3;
        ir_cnt2 : ., mut = 0; fr_cnt2 : ., mut = 0;
        ai2 : ., mut = 0;
        loop { if ai2 >= ac2 { break; }
            pt2 := irv_type(fa2 + ai2);
            if pt2 == TI_DEX {
                if fr_cnt2 < 8 {
                    cp = cp + e2_sd_load_x(buf, pos+cp, g2_slot(fa2 + ai2), fr_cnt2);
                    fr_cnt2 = fr_cnt2 + 1;
                }
            } else {
                if ir_cnt2 < 6 {
                    r2 := -1;
                    if ir_cnt2 == 0 { r2 = 7; } if ir_cnt2 == 1 { r2 = 6; } if ir_cnt2 == 2 { r2 = 2; }
                    if ir_cnt2 == 3 { r2 = 1; } if ir_cnt2 == 4 { r2 = 8; } if ir_cnt2 == 5 { r2 = 9; }
                    cp = cp + e2_load_var(buf, pos+cp, r2, fa2 + ai2);
                    ir_cnt2 = ir_cnt2 + 1;
                }
            }
            ai2 = ai2 + 1;
        }
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
        // F4：操作数约定对齐——s1=首参、s2=参数个数、s3=函数名 ni
        // （ir_gen L939 发射 `emit(IR_SPAWN, dest2, val_var, 1, func_ni, -1)`；
        //  interp 同用 s3 查函数名。修复前 `name_ni := s1` 拿参数变量索引当
        //  函数名查表 → 补丁失败 → call rel32=0 → 栈不平衡 → SIGSEGV 139。）
        name_ni := s3;
        // F4：补参数装载——与 IR_CALL 完全相同的 SysV AMD64 分派
        // （int: rdi,rsi,rdx,rcx,r8,r9 + 栈超限；float: xmm0-7）。
        fa := s1; ac := s2;
        ir_cnt : ., mut = 0; fr_cnt : ., mut = 0;
        ai := 0;
        loop { if ai >= ac { break; }
            pt := irv_type(fa + ai);
            if pt == TI_DEX {
                if fr_cnt < 8 {
                    cp = cp + e2_sd_load_x(buf, pos+cp, g2_slot(fa + ai), fr_cnt);
                    fr_cnt = fr_cnt + 1;
                }
            } else {
                if ir_cnt < 6 {
                    r := -1;
                    if ir_cnt == 0 { r = 7; } if ir_cnt == 1 { r = 6; } if ir_cnt == 2 { r = 2; }
                    if ir_cnt == 3 { r = 1; } if ir_cnt == 4 { r = 8; } if ir_cnt == 5 { r = 9; }
                    cp = cp + e2_load_var(buf, pos+cp, r, fa + ai);
                    ir_cnt = ir_cnt + 1;
                }
            }
        ai = ai + 1; }
        // 栈参数（右到左压，第 7 个 int / 第 9 个 float 超限才压）——同 IR_CALL
        stack_total : ., mut = 0;
        stack_ai : ., mut = ac - 1;
        loop {
            if stack_ai < 0 { break; }
            ic2 : ., mut = 0; fc2 : ., mut = 0;
            j2 : ., mut = 0;
            loop { if j2 >= stack_ai { break; }
                if irv_type(fa + j2) == TI_DEX { fc2 = fc2 + 1; } else { ic2 = ic2 + 1; }
                j2 = j2 + 1; }
            if irv_type(fa + stack_ai) == TI_DEX {
                if fc2 >= 8 {
                    cp = cp + e2_sd_load_x(buf, pos+cp, g2_slot(fa + stack_ai), 0);
                    cp = cp + e2_push_xmm0(buf, pos+cp);
                    stack_total = stack_total + 1;
                }
            } else {
                if ic2 >= 6 {
                    cp = cp + e2_load_var(buf, pos+cp, 10, fa + stack_ai);
                    e2_w8(buf, pos+cp, 65); e2_w8(buf, pos+cp+1, 82); cp = cp + 2;  // push r10
                    stack_total = stack_total + 1;
                }
            }
            stack_ai = stack_ai - 1;
        }
        // Emit call to function + store result (single-threaded approximation)
        grow_call_patch(g_x86_call_patch_count + 1);
        w64(g_x86_call_patch_pos, g_x86_call_patch_count * 8, pos + cp);
        w64(g_x86_call_patch_name, g_x86_call_patch_count * 8, name_ni);
        g_x86_call_patch_count = g_x86_call_patch_count + 1;
        e2_w8(buf, pos+cp, 232); e2_w32(buf, pos+cp+1, 0); cp = cp + 5;
        // 栈清理（call 后恢复 rsp）——同 IR_CALL
        stack_count := stack_total;
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
        if d >= 0 && irv_type(d) == TI_DEX {
            cp = cp + e2_sd_store(buf, pos+cp, do2);
        } else {
            cp = cp + e2_st(buf, pos+cp, 0, do2);
        }
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
            if irv_type(s1) == TI_DEX {
                // binary64 返回：movsd xmm0, [slot]（SysV 返回值在 XMM0，apx 快路径）
                cp = cp + e2_sd_load(buf, pos+cp, g2_slot(s1));
            } else if r64(g_x86_is_global, s1 * 8) != 0 {
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
                    cp = cp + e2_movabs_rdi(buf, pos+cp, fc * 8);
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
            cp = cp + e2_movabs_rdi(buf, pos+cp, sz);
            grow_alloc_patch(g_x86_alloc_patch_count + 1); w64(g_x86_alloc_patch_pos, g_x86_alloc_patch_count * 8, pos + cp);
            g_x86_alloc_patch_count = g_x86_alloc_patch_count + 1;
            e2_w8(buf, pos+cp, 232); e2_w32(buf, pos+cp+1, 0); cp = cp + 5;  // call placeholder
            cp = cp + e2_st(buf, pos+cp, 0, do2);
        } else if s1 > 0 {
            // F14：s1*8 在 64 位内溢出为负（s1 > 2⁶¹）——不静默不发射；
            // 按 OOM 处理（alloc(-1) → null），后续访问由 null 陷阱捕获。
            cp = cp + e2_movabs_rdi(buf, pos+cp, -1);
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
        cp = cp + e2_load_var(buf, pos+cp, 10, s1);
        if s3 != 0 {
            n := e2_ptr_bounds_check(buf, pos+cp, s2, s3, ti);
            if n <= 0 { cp = cp + e2_ptr_null_check(buf, pos+cp); } else { cp = cp + n; }
        } else {
            // F6：无分配信息（s3=0）时至少保留 null 陷阱
            cp = cp + e2_ptr_null_check(buf, pos+cp);
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
        if s3 != 0 {
            n := e2_ptr_bounds_check(buf, pos+cp, d, s3, ti);
            if n <= 0 { cp = cp + e2_ptr_null_check(buf, pos+cp); } else { cp = cp + n; }
        } else {
            // F6：s3=0（provenance 未填充/unsafe）时至少保留 null 陷阱——
            // 修复前整个检查序列（含 null 陷阱）被跳过（instr.cr 旧 L1051）。
            cp = cp + e2_ptr_null_check(buf, pos+cp);
        }
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
        if irv_type(s1) == TI_STR {
            // Strings are byte sequences, unlike arrays of 8-byte values.
            cp = cp + emit_rex(buf, pos+cp, 1, 10/8, 0, 10/8); e2_w8(buf, pos+cp, 15); cp = cp + 1;
            e2_w8(buf, pos+cp, 182); cp = cp + 1;
            cp = cp + emit_modrm(buf, pos+cp, 2, 10%8, 10%8); cp = cp + e2_w32(buf, pos+cp, idx);
        } else {
            cp = cp + emit_rex(buf, pos+cp, 1, 10/8, 0, 10/8); e2_w8(buf, pos+cp, 139); cp = cp + 1;
            cp = cp + emit_modrm(buf, pos+cp, 2, 10%8, 10%8); cp = cp + e2_w32(buf, pos+cp, idx * 8);
        }
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
        if irv_type(s1) == TI_STR {
            // String assignment stores one byte, not a full machine word.
            cp = cp + emit_rex(buf, pos+cp, 0, 11/8, 0, 10/8); e2_w8(buf, pos+cp, 136); cp = cp + 1;
            cp = cp + emit_modrm(buf, pos+cp, 2, 11%8, 10%8); cp = cp + e2_w32(buf, pos+cp, idx);
        } else {
            // mov [r10 + idx*8], r11
            cp = cp + emit_rex(buf, pos+cp, 1, 11/8, 0, 10/8); e2_w8(buf, pos+cp, 137); cp = cp + 1;
            cp = cp + emit_modrm(buf, pos+cp, 2, 11%8, 10%8); cp = cp + e2_w32(buf, pos+cp, idx * 8);
        }
        return cp;
    }

    if op == IR_LOAD_INDEX_VAR && d >= 0 {
        do2 := g2_slot(d);
        // load array pointer (handles local and global)
        cp = cp + e2_load_var(buf, pos+cp, 10, s1);
        // load index (handles local and global)
        cp = cp + e2_load_var(buf, pos+cp, 11, s2);
        // Strings use byte indexing; arrays use 8-byte element indexing.
        if irv_type(s1) == TI_STR {
            cp = cp + emit_rex(buf, pos+cp, 1, 10/8, 11/8, 10/8); e2_w8(buf, pos+cp, 15); cp = cp + 1; e2_w8(buf, pos+cp, 182); cp = cp + 1;
            cp = cp + emit_modrm(buf, pos+cp, 0, 10%8, 4); cp = cp + emit_sib(buf, pos+cp, 0, 11%8, 10%8);
        } else {
            cp = cp + emit_rex(buf, pos+cp, 1, 10/8, 11/8, 10/8); e2_w8(buf, pos+cp, 139); cp = cp + 1;
            cp = cp + emit_modrm(buf, pos+cp, 0, 10%8, 4); cp = cp + emit_sib(buf, pos+cp, 3, 11%8, 10%8);
        }
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
        if irv_type(s1) == TI_STR {
            // String assignment stores one byte at the runtime byte index.
            cp = cp + emit_rex(buf, pos+cp, 0, 12/8, 0, 10/8); e2_w8(buf, pos+cp, 136); cp = cp + 1;
            cp = cp + emit_modrm(buf, pos+cp, 0, 12%8, 4); cp = cp + emit_sib(buf, pos+cp, 0, 11%8, 10%8);
        } else {
            // mov [r10 + r11*8], r12 — SIB(scale=3, index=r11%8, base=r10%8)
            cp = cp + emit_rex(buf, pos+cp, 1, 12/8, 11/8, 10/8); e2_w8(buf, pos+cp, 137); cp = cp + 1;
            cp = cp + emit_modrm(buf, pos+cp, 0, 12%8, 4); cp = cp + emit_sib(buf, pos+cp, 3, 11%8, 10%8);
        }
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
        // s1 = index var, s2 = max_len 字面量 — index < 0 或 index >= max_len → ud2
        // F1c：s2 是字面量长度（发射约定），修复前按变量槽加载（e2_load_var）——
        // 把长度当变量索引读，检查恒错。
        cp = cp + e2_load_var(buf, pos+cp, 10, s1);  // index
        if ti != 0 {
            // Dynamic upper bound: load len_var into r11.
            cp = cp + e2_load_var(buf, pos+cp, 11, s2);
        } else {
            // Constant upper bound: movabs r11, imm64.
            e2_w8(buf, pos+cp, 73); e2_w8(buf, pos+cp+1, 187);
            e2_w64(buf, pos+cp+2, s2); cp = cp + 10;
        }
        cp = cp + e2_alu(buf, pos+cp, 57);           // cmp r10, r11
        // jb +2: if index < max (unsigned below), skip the 2-byte ud2 → continue
        e2_w8(buf, pos+cp, 114);                      // 0x72 = jb rel8
        e2_w8(buf, pos+cp+1, 2);                     // skip past ud2
        cp = cp + 2;
        // 注意：必须用 pos+cp（Phase 3 的 pos 为绝对基址）——修复前写 cp（相对
        // 偏移）→ ud2 落到缓冲区开头（后被 ELF 头覆盖）→ 检查恒不陷阱。
        e2_w8(buf, pos+cp, 15); e2_w8(buf, pos+cp+1, 11); cp = cp + 2;  // ud2 (SIGILL)
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
    if op == IR_APPROX {
        // No-op — annotation only (apx: approved for approximate arithmetic)
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
        // F5b：eager 单线程近似——与 IR_AWAIT 一致的槽转移（d ← ρ(s1)），
        // 与 interp 一致（语义表 2.7：eager 近似，D 设计族）。
        // 原实现 `call sched_yield()` 且忽略 s1：① 与定义语义（向 flow 消费者
        // 通道发射值）不符；② sched_yield 未导入 → call rel32 补丁悬空 → 崩溃；
        // 导入后无 goroutine 上下文（fiber_switch 无栈可切）同样崩溃（139）。
        // 发射侧 dest=-1（ir_gen L1569）→ 本近似为 no-op（yield 值被丢弃）。
        if d >= 0 && s1 >= 0 {
            cp = cp + e2_ld(buf, pos+cp, 10, g2_slot(s1));
            cp = cp + e2_st(buf, pos+cp, 10, g2_slot(d));
        }
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

        // 3. .type_error: 未知 tag——静默产 0（语义表 2.6 BC9 的占位设计意图：
        // 「未知 tag 静默返回 0」；s2 方法名当前未用，占位）。
        //    F3：原实现 `xor eax,eax; ret` 在函数体中间发射 ret——有栈帧
        //    （push rbp; sub rsp）时弹出局部槽 → SIGSEGV；改 xor r10d,r10d +
        //    jmp .done（值级 d := 0，无中间 ret，不崩溃）。注意：本段必须位于
        //    compare-chain 之后（落空即到此）、.case_common 之前。
        e2_w8(buf, pos+cp, 69); e2_w8(buf, pos+cp+1, 49); e2_w8(buf, pos+cp+2, 210); cp = cp + 3;  // xor r10d, r10d (45 31 D2)
        type_jmp_off := cp;
        e2_w8(buf, pos+cp, 235); e2_w8(buf, pos+cp+1, 0); cp = cp + 2;  // 0xEB = jmp rel8 .done

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
        //    F3：写入位置加 pos 基——原实现用指令内相对偏移（j1_off 等，cp 系）
        //    当绝对缓冲区偏移 → 补丁写错地址 → 三个 je rel8 恒 0 → 已知 tag 也
        //    坠错误路径 → SIGSEGV（139）。对照全文件其他补丁的 `pos + cp` 惯例。
        e2_w8(buf, pos + j1_off + 1, case_pos - (j1_off + 2));
        e2_w8(buf, pos + j2_off + 1, case_pos - (j2_off + 2));
        e2_w8(buf, pos + j3_off + 1, case_pos - (j3_off + 2));
        e2_w8(buf, pos + jmp_done_off + 1, done_pos - (jmp_done_off + 2));
        e2_w8(buf, pos + type_jmp_off + 1, done_pos - (type_jmp_off + 2));

        return cp;
    }

    return 0;
}

// ══════════════════════════════════════════════════════════════
// HIT 表驱动发射（M1 Task 2/3）——事件流编码器（emit_instr 的并行路径）
// ══════════════════════════════════════════════════════════════
// 表模式下 corearch 内部 = IR →（lower_to_core.cr 降低）→ 事件流 →（本编码器
// 表投影）→ 字节。数据 = core-x86.toml（src/arch/hit/，load_hit_table 已载入
// g_hit_events/steps）。降低在发射前一次性完成（hit_lower_program，
// lower_to_core.cr：IR 直线子集 → 事件流 + 常量池）；每条 IR 指令在
// g_hit_ev_map 记 [事件流起点, 条数]（0 条 = 非子集 → 落旧路径）。
// 调用方（elf.cr 发射循环）：hit_table_active() 时先调 emit_instr_tabled，
// 返回 -1 = 无事件/形态不支持 → 落旧路径 emit_instr（M1 混合模式）。
// 正确性契约：事件字节 = 模板投影（opcode 与 modrm 角色取自表数据——表 = 数据，
// 错在数据不在代码）+ 操作数装载/回存 glue（复用 e2_* 槽机制，与旧路径同语义；
// 逐字节对照仅 Task 2 直通形严格，Task 3 起 const → 池 load 字节有意不同）。
// 事件记录布局/访问器/常量池：lower_to_core.cr（构建清单中位于本文件之前）；
// 布局常量 hit.cr（HIT_*）。

// 角色 → M1 寄存器对低 3 位（modrm 字段编码；r10=2 主累加 / r11=3 第二操作数）
fn hit_role_reg_low(role: int) -> int {
    if role == HIT_ROLE_DST { return 2; }
    if role == HIT_ROLE_SRC1 { return 2; }
    if role == HIT_ROLE_SRC2 { return 3; }
    if role == HIT_ROLE_VAL { return 2; }
    return -1; }   // addr/未知：无寄存器惯例（M1 addr 走 rbp+disp 形态）

// 角色 → 绝对寄存器号（M1 惯例 r10/r11：低 3 位 + REX.R 位含在表 opcode 内）
fn hit_role_reg(role: int) -> int {
    low := hit_role_reg_low(role);
    if low < 0 { return -1; }
    return 8 + low; }

// 槽/池寻址形态的 addr 变量可用性：须为当前函数真内存槽变量
// （表模板 = rbp+disp32：寄存器分配变量/全局走旧路径——e2 族已有其语义）
fn hit_ev_slot_addr_ok(v: int) -> int {
    if v < 0 { return 0; }
    if v >= g_ir_var_count { return 0; }
    if r64(g_x86_is_global, v * 8) != 0 { return 0; }
    if v < g_current_func_var_start { return 0; }
    o := g2_slot(v);
    if o >= E2_REG_SLOT_BASE { return 0; }
    return 1; }

// 取事件模板步（20B 记录入 st）；-1 = 表无此事件/步非法
fn hit_ev_step_of(ev_id: int, st: string) -> int {
    es := hit_event_lookup(ev_id);
    if es < 0 { return -1; }
    if hit_proj_step(es, 0, st) != 0 { return -1; }
    return 0; }

// 单条事件预检（发射前整条指令全过才落字节；任一不支持 → 整条落旧路径，
// 不产生半写）。Returns 0 = 可发射；1 = 不支持。
fn hit_ev_preflight_ok(ev_i: int) -> int {
    ev_id := hit_ev_id(ev_i);
    d := hit_ev_dst(ev_i);
    s1 := hit_ev_s1(ev_i);
    s2 := hit_ev_s2(ev_i);
    fl := hit_ev_flags(ev_i);
    st := alloc(HIT_STEP_REC);
    if hit_ev_step_of(ev_id, st) != 0 { return 1; }   // 表在但事件缺 → 保守落旧路径
    rm_mode := hit_r32(st, HIT_ST_OFF_RM_MODE);
    rr := hit_r32(st, HIT_ST_OFF_REG_ROLE);
    mr := hit_r32(st, HIT_ST_OFF_RM_ROLE);
    if rm_mode == 0 {
        // 双寄存器累加形（sub/nand…）：rm = dst 累加（r10）、reg = src2（r11）
        if mr != HIT_ROLE_DST { return 1; }
        if rr != HIT_ROLE_SRC2 { return 1; }
        if d < 0 { return 1; }
        if fl % 2 == 0 && s1 < 0 { return 1; }       // var 操作数须非负
        if fl / 2 % 2 == 0 && s2 < 0 { return 1; }
        if fl / 2 % 2 == 1 { return 1; }             // M1：仅首操作数可为池（r10 与 load 模板 reg 位同）
        return 0; }
    if rm_mode == 1 {
        // rbp+disp32（槽）寻址 / 池 rip 引用：reg 角色 = dst（load）或 val（store）
        if mr != HIT_ROLE_ADDR { return 1; }
        if rr == HIT_ROLE_DST {                    // load：读 [addr] → dst 槽
            if d < 0 { return 1; }
            if fl % 2 == 1 {
                if s1 < 0 || s1 >= g_hit_pool_count { return 1; }
            } else {
                if hit_ev_slot_addr_ok(s1) == 0 { return 1; }
            }
            return 0; }
        if rr == HIT_ROLE_VAL {                    // store：写 [addr] ← val
            if fl % 2 == 1 { return 1; }           // 写池 = 无意义（池只读）——保守
            if hit_ev_slot_addr_ok(s1) == 0 { return 1; }
            if s2 < 0 { return 1; }
            return 0; }
        return 1; }
    return 1; }   // M1 形态集外

// 池值 → 寄存器：mov r64, [rip+disp32]——load 事件模板字节 + mod=00（rm=101 =
// rip 相对；disp 由 elf.cr 于 rodata 定稿后按池槽回填）。reg 低 3 位 = 目标。
// 返回写入字节数（恒 7）；load 事件形态不符 = -1（调用方整条落旧路径）。
fn hit_ev_emit_pool_mov(buf: string, pos: int, reg_low: int, k: int) -> int {
    st := alloc(HIT_STEP_REC);
    if hit_ev_step_of(HIT_EV_LOAD, st) != 0 { return -1; }
    rm_mode := hit_r32(st, HIT_ST_OFF_RM_MODE);
    rr := hit_r32(st, HIT_ST_OFF_REG_ROLE);
    mr := hit_r32(st, HIT_ST_OFF_RM_ROLE);
    if rm_mode != 1 || rr != HIT_ROLE_DST || mr != HIT_ROLE_ADDR { return -1; }
    rl := hit_role_reg_low(rr);
    if rl != reg_low { return -1; }   // 目标寄存器须与 load 模板 reg 角色一致
    cp : ., mut = pos;
    e2_w8(buf, cp, hit_r32(st, HIT_ST_OFF_OP0)); cp = cp + 1;
    op1 := hit_r32(st, HIT_ST_OFF_OP1);
    if op1 != 0 { e2_w8(buf, cp, op1); cp = cp + 1; }
    cp = cp + emit_modrm(buf, cp, 0, reg_low, 5);
    e2_w32(buf, cp, 0); cp = cp + 4;
    hit_pool_patch_add(pos, k);
    return cp - pos; }

// 编码单条事件 → 字节（预检已过；此处仍防御性 -1）。
fn hit_ev_emit_one(ev_i: int, buf: string, pos: int) -> int {
    ev_id := hit_ev_id(ev_i);
    d := hit_ev_dst(ev_i);
    s1 := hit_ev_s1(ev_i);
    s2 := hit_ev_s2(ev_i);
    fl := hit_ev_flags(ev_i);
    st := alloc(HIT_STEP_REC);
    if hit_ev_step_of(ev_id, st) != 0 { return -1; }
    rm_mode := hit_r32(st, HIT_ST_OFF_RM_MODE);
    rr := hit_r32(st, HIT_ST_OFF_REG_ROLE);
    mr := hit_r32(st, HIT_ST_OFF_RM_ROLE);
    cp : ., mut = 0;
    if rm_mode == 0 {
        // 双寄存器累加形：rm = dst 累加器（首输入驻）、reg = src2
        r_acc := hit_role_reg(mr);   // dst → 10
        r_sec := hit_role_reg(rr);   // src2 → 11
        if r_acc < 0 || r_sec < 0 { return -1; }
        if fl % 2 == 1 {
            // 首输入 = 池：mov r10, [rip+池槽]（load 模板字节；预检已验形态）
            n := hit_ev_emit_pool_mov(buf, pos, hit_role_reg_low(mr), s1);
            if n < 0 { return -1; }
            cp = cp + n; }
        else {
            cp = cp + e2_load_var(buf, pos+cp, r_acc, s1); }
        cp = cp + e2_load_var(buf, pos+cp, r_sec, s2);
        // 指令字节：opcode ≤2 字节逐字发射（REX 位含在表数据：r10/r11 对需
        // W+R+B——reg 字段 r11 用 R 位、rm 字段 r10 用 B 位；如 sub = 4D 29）
        e2_w8(buf, pos+cp, hit_r32(st, HIT_ST_OFF_OP0)); cp = cp + 1;
        op1 := hit_r32(st, HIT_ST_OFF_OP1);
        if op1 != 0 { e2_w8(buf, pos+cp, op1); cp = cp + 1; }
        // modrm：mod=3（寄存器）；reg/rm 低 3 位来自角色（src2→r11=3、dst→r10=2）
        cp = cp + emit_modrm(buf, pos+cp, 3, hit_role_reg_low(rr), hit_role_reg_low(mr));
        // 结果回存（先读后写——dst 兼作操作数（add 反减中间值）时读先于写）
        cp = cp + e2_st(buf, pos+cp, r_acc, g2_slot(d));
        return cp; }
    if rm_mode == 1 {
        r_val := hit_role_reg(rr);
        if r_val < 0 { return -1; }
        if rr == HIT_ROLE_DST {
            // load：读 [addr] → dst。addr = 池槽 → rip 相对；槽 → rbp+disp32
            if fl % 2 == 1 {
                n := hit_ev_emit_pool_mov(buf, pos, hit_role_reg_low(rr), s1);
                if n < 0 { return -1; }
                cp = cp + n; }
            else {
                e2_w8(buf, pos+cp, hit_r32(st, HIT_ST_OFF_OP0)); cp = cp + 1;
                op2 := hit_r32(st, HIT_ST_OFF_OP1);
                if op2 != 0 { e2_w8(buf, pos+cp, op2); cp = cp + 1; }
                cp = cp + emit_modrm(buf, pos+cp, 2, hit_role_reg_low(rr), 5);
                cp = cp + e2_w32(buf, pos+cp, g2_slot(s1)); }
            cp = cp + e2_st(buf, pos+cp, r_val, g2_slot(d));
            return cp; }
        if rr == HIT_ROLE_VAL {
            // store：写 [addr槽] ← val（val 槽值先载入角色寄存器）
            cp = cp + e2_load_var(buf, pos+cp, r_val, s2);
            e2_w8(buf, pos+cp, hit_r32(st, HIT_ST_OFF_OP0)); cp = cp + 1;
            op3 := hit_r32(st, HIT_ST_OFF_OP1);
            if op3 != 0 { e2_w8(buf, pos+cp, op3); cp = cp + 1; }
            cp = cp + emit_modrm(buf, pos+cp, 2, hit_role_reg_low(rr), 5);
            cp = cp + e2_w32(buf, pos+cp, g2_slot(s1));
            return cp; }
        return -1; }
    return -1; }

// 表驱动单指令发射。与 emit_instr 同签名；返回写入字节数；-1 = 无事件/不支持。
// 消费 lower_to_core.cr 的事件流：0 事件 = 非子集指令（旧路径）；
// 有事件 = 预检整条 → 逐事件表投影发射（g_hit_tabled_count 计事件条数）。
fn emit_instr_tabled(instr_idx: int, buf: string, pos: int) -> int {
    cnt := hit_ev_map_cnt(instr_idx);
    if cnt <= 0 { return -1; }
    start := hit_ev_map_start(instr_idx);
    e : ., mut = 0;
    loop {
        if e >= cnt { break; }
        if hit_ev_preflight_ok(start + e) != 0 { return -1; }   // 整条落旧路径（不半写）
        e = e + 1; }
    cp : ., mut = 0;
    e2 : ., mut = 0;
    loop {
        if e2 >= cnt { break; }
        n := hit_ev_emit_one(start + e2, buf, pos + cp);
        if n < 0 { return -1; }   // 预检后不可达（防御）
        cp = cp + n;
        g_hit_tabled_count = g_hit_tabled_count + 1;
        e2 = e2 + 1; }
    return cp; }
