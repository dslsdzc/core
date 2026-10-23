// === entry.cr ===
// Linux process entry and startup integration on the OS axis.
//
// _start sequence: load argc and argv from the initial stack, store them in
// gv_argc and gv_argv with RIP patches, set g_current_arena = -1, write
// compile-time constant global initializers (imm32 or imm64), call main, and exit
// with sys_exit(60).
//
// Shared globals: gv_argc, gv_argv, and gv_current_arena are declared in
// elf.cr and assigned by elf_gen. g_call_main_pos is written here and read by
// the elf.cr patch pass. instr.cr get_arg consumes gv_argv.
//
// Depends on instr.cr for encoding primitives and sizes.cr for sz_start_body and
// sz_start_argv_save.

fn emit_start(buf: string, pos: int) -> int:
    cp : ., mut = pos
    // mov rdi, [rsp], load argc (rdi=7)
    cp = cp + emit_rex(buf, cp, 1, 0, 0, 0)
    e2_w8(buf, cp, 139)
    cp = cp + 1
    cp = cp + emit_modrm(buf, cp, 0, 7, 4)  // [rsp] via SIB
    cp = cp + emit_sib(buf, cp, 0, 4, 4)

    // lea rsi, [rsp+8], pointer to argv (rsi=6, no REX extension)
    cp = cp + emit_rex(buf, cp, 1, 0, 0, 0)
    e2_w8(buf, cp, 141)
    cp = cp + 1
    cp = cp + emit_modrm(buf, cp, 1, 6, 4)  // [rsp+disp8]
    cp = cp + emit_sib(buf, cp, 0, 4, 4)
    e2_w8(buf, cp, 8)
    cp = cp + 1

    if gv_argc >= 0:
        // lea r10, [rip + 0]  (placeholder, patched in Phase 3)
        rip_pos := cp + 3
        cp = cp + e2_lr(buf, cp, 0)
        grow_rip_patch(g_x86_rip_patch_count + 1)
        w64(g_x86_rip_patch_pos, g_x86_rip_patch_count * 8, rip_pos)
        w64(g_x86_rip_patch_globals, g_x86_rip_patch_count * 8, gv_argc)
        g_x86_rip_patch_count = g_x86_rip_patch_count + 1
        // mov [r10], rdi, store argc
        cp = cp + emit_rex(buf, cp, 1, 0, 0, 10/8)
        e2_w8(buf, cp, 137)
        cp = cp + 1
        cp = cp + emit_modrm(buf, cp, 0, 7, 10%8)

    if gv_argv >= 0:
        rip_pos2 := cp + 3
        cp = cp + e2_lr(buf, cp, 0)
        grow_rip_patch(g_x86_rip_patch_count + 1)
        w64(g_x86_rip_patch_pos, g_x86_rip_patch_count * 8, rip_pos2)
        w64(g_x86_rip_patch_globals, g_x86_rip_patch_count * 8, gv_argv)
        g_x86_rip_patch_count = g_x86_rip_patch_count + 1
        // mov [r10], rsi, store argv
        cp = cp + emit_rex(buf, cp, 1, 0, 0, 10/8)
        e2_w8(buf, cp, 137)
        cp = cp + 1
        cp = cp + emit_modrm(buf, cp, 0, 6, 10%8)

    // Initialize g_current_arena = -1 (no arena active)
    if gv_current_arena >= 0:
        rip_ca := cp + 3
        cp = cp + e2_lr(buf, cp, 0)  // lea r10, [rip+0]
        grow_rip_patch(g_x86_rip_patch_count + 1)
        w64(g_x86_rip_patch_pos, g_x86_rip_patch_count * 8, rip_ca)
        w64(g_x86_rip_patch_globals, g_x86_rip_patch_count * 8, gv_current_arena)
        g_x86_rip_patch_count = g_x86_rip_patch_count + 1
        // mov qword [r10], -1, REX.WB + 0xC7 /0
        cp = cp + emit_rex(buf, cp, 1, 0, 0, 10/8)
        e2_w8(buf, cp, 199)
        cp = cp + 1      // 0xC7 MOV r/m64, imm32
        cp = cp + emit_modrm(buf, cp, 0, 0, 10%8)
        e2_w32(buf, cp, -1)
        cp = cp + 4      // immediate = -1 (0xFFFFFFFF)

    // Write compile-time constant global initializers (g_ir_globals[i].
    // init_val, i64 at +16; 0 means none, and BSS is already zero).
    // g_current_arena is also covered by the explicit init above; the
    // LET-based init below writes it again with the same value (harmless).
    gi0 : ., mut = 0
    loop:
        if gi0 >= g_ir_global_count:
            break
        iv := r64(g_ir_globals, gi0 * 24 + 16)
        gvv0 := r64(g_ir_globals, gi0 * 24 + 8)
        if iv != 0 && gvv0 >= 0:
            ivv : ., mut = iv
            if g_x86_big_enabled != 0 && irv_type(gvv0) == TI_INT:
                if ivv >= -4611686018427387904 && ivv <= 4611686018427387903:
                    ivv = ivv * 2
            // lea r10, [rip+0], rip_patch for the global's BSS slot
            rip_pos_g := cp + 3
            cp = cp + e2_lr(buf, cp, 0)
            grow_rip_patch(g_x86_rip_patch_count + 1)
            w64(g_x86_rip_patch_pos, g_x86_rip_patch_count * 8, rip_pos_g)
            w64(g_x86_rip_patch_globals, g_x86_rip_patch_count * 8, gvv0)
            g_x86_rip_patch_count = g_x86_rip_patch_count + 1
            if ivv >= -2147483647 - 1 && ivv <= 2147483647:
                // mov qword [r10], imm32 (sign-extended), 49 C7 02 imm32
                w8(buf, cp, 73)
                w8(buf, cp+1, 199)
                w8(buf, cp+2, 2)
                e2_w32(buf, cp+3, ivv)
                cp = cp + 7
            else:
                // mov rax, imm64; mov [r10], rax
                w8(buf, cp, 72)
                w8(buf, cp+1, 184)
                e2_w64(buf, cp+2, ivv)
                cp = cp + 10
                w8(buf, cp, 73)
                w8(buf, cp+1, 137)
                w8(buf, cp+2, 2)
                cp = cp + 3
        gi0 = gi0 + 1

    g_call_main_pos = cp
    cp = cp + e2_call(buf, cp, 0)  // call main

    if g_x86_big_enabled != 0:
        // main's return value is a tagged mathematical int.  Convert at the
        // process boundary; sys_exit still takes a machine word.
        cp = cp + e2_mov(buf, cp, 7, 0)  // rdi = rax
        g_x86_big_exit_call_pos = cp
        cp = cp + e2_call(buf, cp, 0)  // call bi_to_word_checked (patched later)

    // mov edi, eax
    e2_w8(buf, cp, 137)
    cp = cp + 1
    cp = cp + emit_modrm(buf, cp, 3, 0, 7)

    // mov eax, 60  (sys_exit)
    e2_w8(buf, cp, 184)
    cp = cp + 1  // 0xB8 MOV r, imm32 (rax)
    cp = cp + e2_w32(buf, cp, 60)

    // syscall
    e2_w8(buf, cp, 15)
    cp = cp + 1
    e2_w8(buf, cp, 5)
    cp = cp + 1

    return cp - pos

fn emit_start_size() -> int:
    sz : ., mut = sz_start_body()
    if gv_argc >= 0:
        sz = sz + sz_start_argv_save()
    if gv_argv >= 0:
        sz = sz + sz_start_argv_save()
    // g_current_arena init: lea(7) + rex+mov+modrm+imm32(7) = 14 bytes
    if gv_current_arena >= 0:
        sz = sz + 14
    if g_x86_big_enabled != 0:
        // mov rdi, rax (3) + call bi_to_word_checked (5)
        sz = sz + 8
    // Constant global initializers: lea r10(7) + mov imm32(7) = 14 bytes,
    // or mov rax imm64 + mov [r10],rax = 20 bytes for large values.
    gi0s : ., mut = 0
    loop:
        if gi0s >= g_ir_global_count:
            break
        ivs := r64(g_ir_globals, gi0s * 24 + 16)
        gvvs := r64(g_ir_globals, gi0s * 24 + 8)
        if ivs != 0 && gvvs >= 0:
            if ivs >= -2147483647 - 1 && ivs <= 2147483647:
                sz = sz + 14
            else:
                sz = sz + 20
        gi0s = gi0s + 1
    return sz
