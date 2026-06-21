// === backend/x86_64/elf.cr ===
// Direct ELF binary output for x86-64 using the new resolve+emit interface.
// Depends on: x86_64/instr.cr (instr_size, emit_instr, g2_*)
// Depends on: backend/resolve.cr (res_labels)

// ── ELF constants (x86-64) ──
ET_EXEC : int = 2;
EM_X86_64 : int = 62;
PT_LOAD : int = 1;
PF_RX : int = 5;
PF_RW : int = 6;

fn r16(buf: string, pos: int) -> int { return bu8(buf,pos) + bu8(buf,pos+1)*256; }

TEXT_BASE : int = 4194304;  // 0x400000 - base address of code segment

fn w8_signed(buf: string, pos: int, val: int) {
    uv : ., mut = val;
    if uv < 0 { uv = uv + 4294967296; }
    w8(buf, pos, uv % 256); w8(buf, pos+1, (uv/256) % 256);
    w8(buf, pos+2, (uv/65536) % 256); w8(buf, pos+3, (uv/16777216) % 256);
}

// Emit alloc bump allocator function body
// Returns bytes written (always 65)
fn emit_alloc_body(buf: string, pos: int, bss_va: int) -> int {
    cp := 0;
    fva := TEXT_BASE + pos;

    // add rdi, 7     — align size to 8
    w8(buf, pos+cp, 72); w8(buf, pos+cp+1, 131); w8(buf, pos+cp+2, 199); w8(buf, pos+cp+3, 7); cp = cp + 4;
    // and rdi, -8
    w8(buf, pos+cp, 72); w8(buf, pos+cp+1, 131); w8(buf, pos+cp+2, 231); w8(buf, pos+cp+3, 248); cp = cp + 4;

    // mov r11, [rip + heap_ptr]
    rel := bss_va - (fva + cp + 7);
    w8(buf, pos+cp, 76); w8(buf, pos+cp+1, 139); w8(buf, pos+cp+2, 29); w8_signed(buf, pos+cp+3, rel); cp = cp + 7;
    // test r11, r11
    w8(buf, pos+cp, 77); w8(buf, pos+cp+1, 133); w8(buf, pos+cp+2, 219); cp = cp + 3;
    // jne +14 (skip init if heap_ptr already set)
    w8(buf, pos+cp, 117); w8(buf, pos+cp+1, 14); cp = cp + 2;

    // lea r11, [rip + heap_start]
    rel2 := (bss_va + 8) - (fva + cp + 7);
    w8(buf, pos+cp, 76); w8(buf, pos+cp+1, 141); w8(buf, pos+cp+2, 29); w8_signed(buf, pos+cp+3, rel2); cp = cp + 7;
    // mov [rip + heap_ptr], r11
    rel3 := bss_va - (fva + cp + 7);
    w8(buf, pos+cp, 76); w8(buf, pos+cp+1, 137); w8(buf, pos+cp+2, 29); w8_signed(buf, pos+cp+3, rel3); cp = cp + 7;

    // mov r8, r11
    w8(buf, pos+cp, 77); w8(buf, pos+cp+1, 137); w8(buf, pos+cp+2, 216); cp = cp + 3;
    // add r11, rdi
    w8(buf, pos+cp, 73); w8(buf, pos+cp+1, 1); w8(buf, pos+cp+2, 251); cp = cp + 3;
    // mov [rip + heap_ptr], r11
    rel4 := bss_va - (fva + cp + 7);
    w8(buf, pos+cp, 76); w8(buf, pos+cp+1, 137); w8(buf, pos+cp+2, 29); w8_signed(buf, pos+cp+3, rel4); cp = cp + 7;

    // mov rdi, r8
    w8(buf, pos+cp, 76); w8(buf, pos+cp+1, 137); w8(buf, pos+cp+2, 199); cp = cp + 3;
    // mov rcx, r11
    w8(buf, pos+cp, 76); w8(buf, pos+cp+1, 137); w8(buf, pos+cp+2, 217); cp = cp + 3;
    // sub rcx, rdi
    w8(buf, pos+cp, 72); w8(buf, pos+cp+1, 41); w8(buf, pos+cp+2, 249); cp = cp + 3;
    // xor eax, eax
    w8(buf, pos+cp, 49); w8(buf, pos+cp+1, 192); cp = cp + 2;
    // cld
    w8(buf, pos+cp, 252); cp = cp + 1;
    // rep stosb
    w8(buf, pos+cp, 243); w8(buf, pos+cp+1, 170); cp = cp + 2;
    // mov rax, r8
    w8(buf, pos+cp, 76); w8(buf, pos+cp+1, 137); w8(buf, pos+cp+2, 192); cp = cp + 3;
    // ret
    w8(buf, pos+cp, 195); cp = cp + 1;

    return cp;
}

// ── Scheduler call trampolines ──
// Emit sched_call_N(buf, p, n): mov rax,[rdi+rsi*8]; shift N args; jmp rax
// Returns bytes written.
fn emit_sched_call(buf: string, p: int, n: int) -> int {
    w8(buf, p, 72); w8(buf, p+1, 139); w8(buf, p+2, 4); w8(buf, p+3, 240); off : ., mut = 4;
    if n >= 1 { w8(buf, p+off, 72); w8(buf, p+off+1, 137); w8(buf, p+off+2, 215); off = off + 3; }
    if n >= 2 { w8(buf, p+off, 72); w8(buf, p+off+1, 137); w8(buf, p+off+2, 206); off = off + 3; }
    if n >= 3 { w8(buf, p+off, 76); w8(buf, p+off+1, 137); w8(buf, p+off+2, 194); off = off + 3; }
    if n >= 4 { w8(buf, p+off, 76); w8(buf, p+off+1, 137); w8(buf, p+off+2, 201); off = off + 3; }
    w8(buf, p+off, 255); w8(buf, p+off+1, 224); off = off + 2;
    return off;
}
fn sched_tramp_sz(n: int) -> int {
    sz : ., mut = 6;
    if n >= 1 { sz = sz + 3; } if n >= 2 { sz = sz + 3; }
    if n >= 3 { sz = sz + 3; } if n >= 4 { sz = sz + 3; }
    return sz;
}
fn sched_reg_one(name: string, offset: int, cp: int) {
    grow_func_offsets(g_x86_func_off_count * 2 + 2);
    w64(g_x86_func_offsets, g_x86_func_off_count * 16, str_intern(name));
    w64(g_x86_func_offsets, g_x86_func_off_count * 16 + 8, cp - 176);
    g_x86_func_off_count = g_x86_func_off_count + 1;
}

fn w16(buf: string, off: int, val: int) {
    w8(buf, off, val % 256); w8(buf, off+1, (val/256) % 256);
}

fn align_up(val: int, align: int) -> int { return (val + align - 1) / align * align; }

// ── Global ──
g_asm_code_size : int, mut;
g_elf_buf : string, mut;

// ── ELF header writer (x86-64) ──
fn elf2_hdr(buf: string, total_sz: int) {
    i := 0; loop { if i >= 176 { break; } store8(buf, i, 0); i = i + 1; }
    // e_ident
    w8(buf, 0, 127); w8(buf, 1, 69); w8(buf, 2, 76); w8(buf, 3, 70);  // \x7fELF
    w8(buf, 4, 2); w8(buf, 5, 1); w8(buf, 6, 1);  // 64-bit, LE, v1
    // e_type, e_machine, e_version
    w16(buf, 16, 2); w16(buf, 18, 62); w32(buf, 20, 1);
    // e_entry = 0x4000B0  (text_base=0x400000 + header_size=176)
    w64(buf, 24, 4194480);
    // e_phoff = 64, e_shoff = 0
    w64(buf, 32, 64); w64(buf, 40, 0);
    w32(buf, 48, 0); w16(buf, 52, 64);
    w16(buf, 54, 56); w16(buf, 56, 2);  // e_phentsize=56, e_phnum=2
    // PHDR[0]: code segment RX
    w32(buf, 64, 1); w32(buf, 68, 5);
    w64(buf, 72, 0); w64(buf, 80, 4194304); w64(buf, 88, 4194304);
    w64(buf, 96, total_sz); w64(buf, 104, total_sz); w64(buf, 112, 4096);
    // PHDR[1]: data BSS RW
    db := (4194304 + total_sz + 4095) / 4096 * 4096;
    w32(buf, 120, 1); w32(buf, 124, 6);
    w64(buf, 128, 0); w64(buf, 136, db); w64(buf, 144, db);
    w64(buf, 152, 0); w64(buf, 160, 268435456); w64(buf, 168, 4096);
}

// ── Emit _start code, return total bytes ──
g_call_main_pos : int, mut;  // set by emit_start, used for patching call main
gv_argc : int, mut;   // IR var index for g_rt_argc (or -1)
gv_argv : int, mut;   // IR var index for g_rt_argv_ptr (or -1)

fn emit_start(buf: string, pos: int) -> int {
    cp : ., mut = pos;
    w8(buf, cp, 72); w8(buf, cp+1, 139); w8(buf, cp+2, 60); w8(buf, cp+3, 36); cp = cp + 4;  // mov rdi,[rsp]
    w8(buf, cp, 72); w8(buf, cp+1, 141); w8(buf, cp+2, 116); w8(buf, cp+3, 36); w8(buf, cp+4, 8); cp = cp + 5;  // lea rsi,[rsp+8]
    if gv_argc >= 0 { w8(buf, cp, 76); w8(buf, cp+1, 141); w8(buf, cp+2, 21); cp = cp + 3;
        grow_rip_patch(g_x86_rip_patch_count + 1);
        w64(g_x86_rip_patch_pos, g_x86_rip_patch_count * 8, cp);
        w64(g_x86_rip_patch_globals, g_x86_rip_patch_count * 8, gv_argc);
        g_x86_rip_patch_count = g_x86_rip_patch_count + 1;
        w32(buf, cp, 0); cp = cp + 4; w8(buf, cp, 77); w8(buf, cp+1, 137); w8(buf, cp+2, 58); cp = cp + 3; }
    if gv_argv >= 0 { w8(buf, cp, 76); w8(buf, cp+1, 141); w8(buf, cp+2, 21); cp = cp + 3;
        grow_rip_patch(g_x86_rip_patch_count + 1);
        w64(g_x86_rip_patch_pos, g_x86_rip_patch_count * 8, cp);
        w64(g_x86_rip_patch_globals, g_x86_rip_patch_count * 8, gv_argv);
        g_x86_rip_patch_count = g_x86_rip_patch_count + 1;
        w32(buf, cp, 0); cp = cp + 4; w8(buf, cp, 77); w8(buf, cp+1, 137); w8(buf, cp+2, 58); cp = cp + 3; }
    g_call_main_pos = cp;
    cp = cp + e2_call(buf, cp, 0);  // call main
    w8(buf, cp, 137); w8(buf, cp+1, 199); cp = cp + 2;  // mov edi, eax
    w8(buf, cp, 184); w32(buf, cp+1, 60); cp = cp + 5;  // mov eax, 60
    w8(buf, cp, 15); w8(buf, cp+1, 5); cp = cp + 2;     // syscall
    return cp - pos;
}

fn emit_start_size() -> int {
    sz : ., mut = sz_start_body();
    if gv_argc >= 0 { sz = sz + sz_start_argv_save(); }
    if gv_argv >= 0 { sz = sz + sz_start_argv_save(); }
    return sz;
}

// ── Main ELF generation ──
fn elf_gen(buf: string) -> int {
    // Phase 0: resolve labels (uses instr_size from instr.cr)
    res_labels();
    g_x86_ext_rel_count = 0;  // reset external relocations

    // Phase 1: rodata layout — collect string constants
    g_x86_str_count = 0;
    si := 0; loop { if si >= g_ir_str_const_count { break; } g2_str_off(r64(g_ir_str_consts, si * 8)); si = si + 1; }

    // Find g_rt_argc/g_rt_argv_ptr globals for _start emission
    g_x86_sub_rsp_pos = -1;
    gv_argc = -1; gv_argv = -1;
    gvsi : ., mut = 0;
    loop { if gvsi >= g_ir_global_count { break; }
        gv_val := r64(g_ir_globals, gvsi * 16 + 8);
        if gv_val >= 0 {
            gni2 : ., mut = 0;
            loop { if gni2 >= g_str_count { break; }
                gn := istr_get(gni2);
                if str_eq(gn, "g_rt_argc") != 0 { gv_argc = gv_val; break; }
                if str_eq(gn, "g_rt_argv_ptr") != 0 { gv_argv = gv_val; break; }
                gni2 = gni2 + 1; }
        }
    gvsi = gvsi + 1; }
    // Phase 2: compute _start size using same constants as emit_start
    total_code : ., mut = emit_start_size();

        fi := 0; g2_init(); loop { if fi >= g_ir_func_count { break; }
        ni := r64(g_ir_func_name_idx, fi * 8);
        grow_func_offsets(g_x86_func_off_count * 2 + 2);
        w64(g_x86_func_offsets, g_x86_func_off_count * 16, ni);
        w64(g_x86_func_offsets, g_x86_func_off_count * 16 + 8, total_code);
        g_x86_func_off_count = g_x86_func_off_count + 1;

        ic := r64(g_ir_func_instr_count, fi * 8);
        vc2 := r64(g_ir_func_var_count, fi * 8);
        vs2 := r64(g_ir_func_var_start, fi * 8);
        pc2 := r64(g_ir_func_param_count, fi * 8);

        // Dry-run: pre-allocate + emit to measure exact size
        g2_init();
        g_current_func_var_start = vs2;
        vi3 := 0; loop { if vi3 >= vc2 { break; } g2_slot(vs2 + vi3); vi3 = vi3 + 1; }
        pi3 := 0; loop { if pi3 >= pc2 && pi3 < 6 { break; } g2_slot(vs2 + pi3); pi3 = pi3 + 1; }
        g_x86_emit_stack_size = vc2 * 8;

        fsz := 0;
        ii := 0; loop { if ii >= ic { break; }
            inst_idx := r64(g_ir_func_instr_start, fi * 8) + ii;
            if iri_op(inst_idx) != IR_NOP {
                fsz = fsz + emit_instr(inst_idx, alloc(512), fsz); }
        ii = ii + 1; }

        // Set stack size from per-function var_count
        g_x86_emit_stack_size = vc2 * 8;
        total_code = total_code + sz_push_rbp() + sz_mov_rbp_rsp();
        ss_dry := g_x86_emit_stack_size;
        total_code = total_code + sz_sub_rsp(ss_dry);
        total_code = total_code + pc2 * sz_save_param();
        total_code = total_code + fsz;
        total_code = total_code + sz_add_rsp(ss_dry) + sz_pop_rbp() + sz_ret();
    fi = fi + 1; }

    rd_sz := g2_rodata_sz();
    total_code = total_code + 6;  // _init_globals

    // alloc: bump allocator for heap allocation in ELF output
    // Find alloc's name index in .ccr string table (not runtime str_intern)
    alloc_ni : ., mut = -1;
    asi : ., mut = 0;
    loop { if asi >= g_str_count { break; }
        if str_eq(istr_get(asi), "alloc") != 0 { alloc_ni = asi; break; }
        asi = asi + 1; }
    if alloc_ni < 0 { alloc_ni = str_intern("alloc"); }
    grow_func_offsets(g_x86_func_off_count * 2 + 2);
    w64(g_x86_func_offsets, g_x86_func_off_count * 16, alloc_ni);
    w64(g_x86_func_offsets, g_x86_func_off_count * 16 + 8, total_code);
    g_x86_func_off_count = g_x86_func_off_count + 1;
    total_code = total_code + 65;
    // sched_call trampolines (0..4)
    grow_func_offsets(g_x86_func_off_count * 2 + 2);
    w64(g_x86_func_offsets, g_x86_func_off_count * 16, str_intern("sched_call_0"));
    w64(g_x86_func_offsets, g_x86_func_off_count * 16 + 8, total_code);
    g_x86_func_off_count = g_x86_func_off_count + 1;
    total_code = total_code + sched_tramp_sz(0);
    grow_func_offsets(g_x86_func_off_count * 2 + 2);
    w64(g_x86_func_offsets, g_x86_func_off_count * 16, str_intern("sched_call_1"));
    w64(g_x86_func_offsets, g_x86_func_off_count * 16 + 8, total_code);
    g_x86_func_off_count = g_x86_func_off_count + 1;
    total_code = total_code + sched_tramp_sz(1);
    grow_func_offsets(g_x86_func_off_count * 2 + 2);
    w64(g_x86_func_offsets, g_x86_func_off_count * 16, str_intern("sched_call_2"));
    w64(g_x86_func_offsets, g_x86_func_off_count * 16 + 8, total_code);
    g_x86_func_off_count = g_x86_func_off_count + 1;
    total_code = total_code + sched_tramp_sz(2);
    grow_func_offsets(g_x86_func_off_count * 2 + 2);
    w64(g_x86_func_offsets, g_x86_func_off_count * 16, str_intern("sched_call_3"));
    w64(g_x86_func_offsets, g_x86_func_off_count * 16 + 8, total_code);
    g_x86_func_off_count = g_x86_func_off_count + 1;
    total_code = total_code + sched_tramp_sz(3);
    grow_func_offsets(g_x86_func_off_count * 2 + 2);
    w64(g_x86_func_offsets, g_x86_func_off_count * 16, str_intern("sched_call_4"));
    w64(g_x86_func_offsets, g_x86_func_off_count * 16 + 8, total_code);
    g_x86_func_off_count = g_x86_func_off_count + 1;
    total_code = total_code + sched_tramp_sz(4);

    rodata_base := total_code;
    g_x86_rodata_base = 176 + rodata_base;

    // Mark global variables for BSS allocation
    gi := 0; loop { if gi >= g_ir_global_count { break; }
        gv := r64(g_ir_globals, gi * 16 + 8);
        if gv >= 0 { grow_is_global(gv + 1); w64(g_x86_is_global, gv * 8, 1); }
    gi = gi + 1; }

    // Phase 3: emit to buffer
    cp := 176;  // skip ELF header

    // ── _start (measured size from Phase 2) ──
    cp = cp + emit_start(buf, cp);

    // ── All functions ──
    g_x86_ret_patch_count = 0;
    g_x86_call_patch_count = 0;
    g_x86_rodataref_count = 0;
    g_x86_alloc_patch_count = 0;
    g_x86_rip_patch_count = 0;
    g_x86_ext_rel_count = 0;
fi = 0; loop { if fi >= g_ir_func_count { break; }
        ni := r64(g_ir_func_name_idx, fi * 8);
        grow_func_cp(fi + 1); w64(g_x86_func_cp, fi * 8, cp);
        // Override with actual position for backward calls
        fi3 := 0; loop { if fi3 >= g_x86_func_off_count { break; }
            if str_eq(istr_get(r64(g_x86_func_offsets, fi3*16)), istr_get(ni)) != 0 {
                w64(g_x86_func_offsets, fi3*16+8, cp - 176);
                break; }
        fi3 = fi3 + 1; }
        ist := r64(g_ir_func_instr_start, fi * 8);
        ic := r64(g_ir_func_instr_count, fi * 8);
        vc := r64(g_ir_func_var_count, fi * 8);
        vs := r64(g_ir_func_var_start, fi * 8);
        pc := r64(g_ir_func_param_count, fi * 8);

        g2_init();
        g_current_func_var_start = vs;
        vi := 0; loop { if vi >= vc { break; } g2_slot(vs + vi); vi = vi + 1; }
        g_x86_emit_stack_size = vc * 8;

        // frame
        w8(buf, cp, 85); cp = cp + 1;  // push rbp
        w8(buf, cp, 72); w8(buf, cp+1, 137); w8(buf, cp+2, 229); cp = cp + 3;  // mov rbp, rsp
        g_x86_sub_rsp_pos = cp;
        if g_x86_emit_stack_size > 0 {
            if g_x86_emit_stack_size > 127 {
                w8(buf, cp, 72); w8(buf, cp+1, 129); w8(buf, cp+2, 236);
                e2_w32(buf, cp+3, 0); cp = cp + 7;
            } else {
                w8(buf, cp, 72); w8(buf, cp+1, 131); w8(buf, cp+2, 236); w8(buf, cp+3, 0); cp = cp + 4;
            }
        }
        // save register params to stack
        pi := 0; loop { if pi >= pc { break; } if pi >= 6 { break; }
            po := g2_slot(vs + pi);
            if pi == 0 { cp = cp + e2_st(buf, cp, 7, po); }
            if pi == 1 { w8(buf, cp, 72); w8(buf, cp+1, 137); w8(buf, cp+2, 117); w8(buf, cp+3, po); cp = cp + 4; }
            if pi == 2 { w8(buf, cp, 72); w8(buf, cp+1, 137); w8(buf, cp+2, 85); w8(buf, cp+3, po); cp = cp + 4; }
            if pi == 3 { w8(buf, cp, 72); w8(buf, cp+1, 137); w8(buf, cp+2, 77); w8(buf, cp+3, po); cp = cp + 4; }
            if pi == 4 { w8(buf, cp, 76); w8(buf, cp+1, 137); w8(buf, cp+2, 69); w8(buf, cp+3, po); cp = cp + 4; }
            if pi == 5 { w8(buf, cp, 76); w8(buf, cp+1, 137); w8(buf, cp+2, 77); w8(buf, cp+3, po); cp = cp + 4; }
        pi = pi + 1; }

        // function body — emit instructions
        g_x86_func_frame_start = cp;  // absolute buffer pos of body start
        save_ss := g_x86_emit_stack_size;  // save frame size before emission

        ii := 0; loop { if ii >= ic { break; }
            inst_idx := ist + ii;
            sz := emit_instr(inst_idx, buf, cp);
            cp = cp + sz;
        ii = ii + 1; }

        // patch RETURNs to epilogue
        epi_pos := cp;
        rpi := 0; loop { if rpi >= g_x86_ret_patch_count { break; }
            jmp_pos := r64(g_x86_ret_patch_pos, rpi * 8);
            rel := epi_pos - (jmp_pos + 5);
            w32(buf, jmp_pos + 1, rel);
        rpi = rpi + 1; }
        g_x86_ret_patch_count = 0;

        // Patch prologue sub rsp with actual stack size
        if save_ss > 0 {
            ss3 := save_ss;
            if ss3 > 127 {
                e2_w32(buf, g_x86_sub_rsp_pos + 3, ss3);
            } else {
                w8(buf, g_x86_sub_rsp_pos + 3, ss3);
            }
        }

        // epilogue (emit with correct stack size, no placeholder)
        if save_ss > 0 {
            if save_ss > 127 {
                w8(buf, cp, 72); w8(buf, cp+1, 129); w8(buf, cp+2, 196);
                e2_w32(buf, cp+3, save_ss); cp = cp + 7;
            } else {
                w8(buf, cp, 72); w8(buf, cp+1, 131); w8(buf, cp+2, 196); w8(buf, cp+3, save_ss); cp = cp + 4;
            }
        }
        w8(buf, cp, 93); cp = cp + 1;  // pop rbp
        w8(buf, cp, 195); cp = cp + 1;  // ret
        fi = fi + 1; }

    // ── Patch forward calls using actual cp positions ──
    // Phase 3 stored cp at start of each function in g_x86_func_cp
    cpi := 0; loop { if cpi >= g_x86_call_patch_count { break; }
        call_pos := r64(g_x86_call_patch_pos, cpi * 8);
        fn_ni := r64(g_x86_call_patch_name, cpi * 8);
        // Find function index by scanning .ccr string table
        cfi2 : ., mut = 0;
        loop { if cfi2 >= g_ir_func_count { break; }
            name_at := r64(g_ir_func_name_idx, cfi2 * 8);
            if str_eq(istr_get(name_at), istr_get(fn_ni)) != 0 {
                func_cp := r64(g_x86_func_cp, cfi2 * 8);
                if func_cp > 0 {
                    rel := func_cp - (call_pos + 5);
                    w32(buf, call_pos + 1, rel);
                }
                break; }
        cfi2 = cfi2 + 1; }
    cpi = cpi + 1; }
    g_x86_call_patch_count = 0;

    // ── _init_globals ──
    w8(buf, cp, 85); cp = cp + 1;
    w8(buf, cp, 72); w8(buf, cp+1, 137); w8(buf, cp+2, 229); cp = cp + 3;
    w8(buf, cp, 93); cp = cp + 1;
    w8(buf, cp, 195); cp = cp + 1;

    // ── alloc (bump allocator) ──
    // Compute BSS VA for heap_ptr placement
    rodata_sz := g2_rodata_sz();
    final_est := cp + 65 + rodata_sz;
    bss_va := (TEXT_BASE + final_est + 4095) / 4096 * 4096;

    alloc_sz := emit_alloc_body(buf, cp, bss_va);
    alloc_start := cp;
    cp = cp + alloc_sz;

    // Patch all IR_ALLOC_STRUCT/ARRAY/MAKE_ENUM call sites to point to alloc
    // alloc_patch_pos entries are buffer positions of the 5-byte call instruction
    // alloc offset = alloc_start - 176 (relative to code section start)
    alloc_code_off := alloc_start - 176;
    api := 0;
    loop { if api >= g_x86_alloc_patch_count { break; }
        call_pos := r64(g_x86_alloc_patch_pos, api * 8);
        rel := (176 + alloc_code_off) - (call_pos + 5);
        w32(buf, call_pos + 1, rel);
        api = api + 1; }
    g_x86_alloc_patch_count = 0;

    // ── scheduler call trampolines ──
    sched_reg_one("sched_call_0", 0, cp);
    cp = cp + emit_sched_call(buf, cp, 0);
    sched_reg_one("sched_call_1", 1, cp);
    cp = cp + emit_sched_call(buf, cp, 1);
    sched_reg_one("sched_call_2", 2, cp);
    cp = cp + emit_sched_call(buf, cp, 2);
    sched_reg_one("sched_call_3", 3, cp);
    cp = cp + emit_sched_call(buf, cp, 3);
    sched_reg_one("sched_call_4", 4, cp);
    cp = cp + emit_sched_call(buf, cp, 4);

    // Set rodata base from actual emission position
    g_x86_rodata_base = cp;

    // Patch LEA rodata references (recorded during instr emission)
    rri : ., mut = 0;
    loop { if rri >= g_x86_rodataref_count { break; }
        lea_pos := r64(g_x86_rodataref_pos, rri * 8);
        ro_off := r64(g_x86_rodataref_ro, rri * 8);
        rel := g_x86_rodata_base + ro_off - (lea_pos + 7);
        w32(buf, lea_pos + 3, rel);
        rri = rri + 1; }
    g_x86_rodataref_count = 0;

    // ── .rodata ──
    si = 0; loop { if si >= g_x86_str_count { break; }
        s := istr_get(r64(g_x86_str_offs, si * 8));
        sl := str_len(s);
        ci := 0; loop { if ci >= sl { break; } w8(buf, cp, load8(s, ci)); ci = ci + 1; cp = cp + 1; }
        w8(buf, cp, 0); cp = cp + 1;
    si = si + 1; }

    // ── Allocate BSS for globals ──
    gi2 := 0; goff : ., mut = 0;
    loop { if gi2 >= g_ir_global_count { break; }
        gv2 := r64(g_ir_globals, gi2 * 16 + 8);
        if gv2 >= 0 { grow_global_off(gv2 + 1); w64(g_x86_global_off, gv2 * 8, goff); goff = goff + 8; }
    gi2 = gi2 + 1; }

    // ── Patch global variable RIP-relative references ──
    rpi2 := 0;
    loop { if rpi2 >= g_x86_rip_patch_count { break; }
        ppos := r64(g_x86_rip_patch_pos, rpi2 * 8);
        gvi := r64(g_x86_rip_patch_globals, rpi2 * 8);
        if gvi >= 0 {
            lea_end_va := TEXT_BASE + ppos + 4 - 176;
            target_va := bss_va + 16 + r64(g_x86_global_off, gvi * 8);  // +16 to skip heap_ptr(8) + heap_start(8)
            rel := target_va - lea_end_va;
            w32(buf, ppos, rel); }
    rpi2 = rpi2 + 1; }
    g_x86_rip_patch_count = 0;

    // ── Patch _start's call to main ──
    // Find main's offset by searching .ccr string table
    mo := -1; fi = 0; loop { if fi >= g_ir_func_count { break; }
        fn_ni := r64(g_ir_func_name_idx, fi * 8);
        fn_name := istr_get(fn_ni);
        if str_eq(fn_name, "main") != 0 { mo = r64(g_x86_func_offsets, fi*16+8); break; }
    fi = fi + 1; }
    if mo >= 0 {
        rel := mo + 176 - g_call_main_pos - 5;
        w32(buf, g_call_main_pos + 1, rel);
    }

    // ── Write ELF header ──
    total_sz := cp;
    elf2_hdr(buf, total_sz);
    g_asm_code_size = total_sz;
    return total_sz;
}

