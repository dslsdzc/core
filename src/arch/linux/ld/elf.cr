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
fn emit_alloc_body(buf: string, pos: int, bss_va: int, globals_size: int) -> int {
    cp := 0;
    fva := TEXT_BASE + pos;

    // Sanity check: if size > 64MB, return 0 to prevent runaway alloc
    // (catches count*element_size cascade before it corrupts BSS)
    w8(buf, pos+cp, 72); w8(buf, pos+cp+1, 129); w8(buf, pos+cp+2, 255);
    e2_w32(buf, pos+cp+3, 67108864); cp = cp + 7;  // cmp rdi, 64MB
    w8(buf, pos+cp, 118); w8(buf, pos+cp+1, 3); cp = cp + 2;  // jbe +3 (skip xor+ret if <= 64MB)
    w8(buf, pos+cp, 49); w8(buf, pos+cp+1, 192); cp = cp + 2;  // xor eax, eax (return 0)
    w8(buf, pos+cp, 195); cp = cp + 1;  // ret (abort alloc)
    // Save requested size for the hidden Core object length header.
    w8(buf, pos+cp, 73); w8(buf, pos+cp+1, 137); w8(buf, pos+cp+2, 249); cp = cp + 3;  // mov r9, rdi
    // add rdi, 15    — requested size + 8-byte header, then align to 8
    w8(buf, pos+cp, 72); w8(buf, pos+cp+1, 131); w8(buf, pos+cp+2, 199); w8(buf, pos+cp+3, 15); cp = cp + 4;
    // and rdi, -8
    w8(buf, pos+cp, 72); w8(buf, pos+cp+1, 131); w8(buf, pos+cp+2, 231); w8(buf, pos+cp+3, 248); cp = cp + 4;

    // mov r11, [rip + heap_ptr]
    rel := bss_va - (fva + cp + 7);
    w8(buf, pos+cp, 76); w8(buf, pos+cp+1, 139); w8(buf, pos+cp+2, 29); w8_signed(buf, pos+cp+3, rel); cp = cp + 7;
    // test r11, r11
    w8(buf, pos+cp, 77); w8(buf, pos+cp+1, 133); w8(buf, pos+cp+2, 219); cp = cp + 3;
    // jne +14 (skip init if heap_ptr already set)
    w8(buf, pos+cp, 117); w8(buf, pos+cp+1, 14); cp = cp + 2;

    // lea r11, [rip + heap_start] — start AFTER globals so rep stosb doesn't zero them
    heap_start_va : ., mut = bss_va + 16 + globals_size;
    rel2 := heap_start_va - (fva + cp + 7);
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
    // Store hidden length header and return the data pointer after it.
    w8(buf, pos+cp, 77); w8(buf, pos+cp+1, 137); w8(buf, pos+cp+2, 8); cp = cp + 3;  // mov [r8], r9
    w8(buf, pos+cp, 73); w8(buf, pos+cp+1, 141); w8(buf, pos+cp+2, 64); w8(buf, pos+cp+3, 8); cp = cp + 4;  // lea rax, [r8+8]
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

// ── ELF64 struct layout offsets (used by elf2_hdr) ──
// ELF64 Ehdr
E_EHDR_MAGIC : int = 0;    // 4B: \x7fELF
E_CLASS : int = 4;          // 1B: 2=64-bit
E_DATA : int = 5;           // 1B: 1=LE
E_VER : int = 6;            // 1B: 1=current
E_OSABI : int = 7;          // 1B: 0=UNIX System V
E_PAD : int = 8;            // 8B padding
E_TYPE : int = 16;          // 2B: 2=ET_EXEC
E_MACH : int = 18;          // 2B: 62=EM_X86_64
E_VERSION : int = 20;       // 4B: 1
E_ENTRY : int = 24;         // 8B: entry point VA
E_PHOFF : int = 32;         // 8B: program header offset
E_SHOFF : int = 40;         // 8B: section header offset
E_FLAGS : int = 48;         // 4B
E_EHSIZE : int = 52;        // 2B: sizeof(Elf64_Ehdr)=64
E_PHENTSIZE : int = 54;     // 2B: sizeof(Elf64_Phdr)=56
E_PHNUM : int = 56;         // 2B: number of phdrs
E_SHENTSIZE : int = 58;     // 2B
E_SHNUM : int = 60;         // 2B
E_SHSTRNDX : int = 62;      // 2B
EHDR_SIZE : int = 64;       // sizeof(Elf64_Ehdr)

// ELF64 Phdr (per-entry offsets, base = 64 + entry_idx * 56)
P_TYPE : int = 0;           // 4B: 1=PT_LOAD
P_FLAGS : int = 4;          // 4B: PF_{R,W,X}
P_OFFSET : int = 8;         // 8B: file offset
P_VADDR : int = 16;         // 8B: virtual address
P_PADDR : int = 24;         // 8B: physical address
P_FILESZ : int = 32;        // 8B: size in file
P_MEMSZ : int = 40;         // 8B: size in memory
P_ALIGN : int = 48;         // 8B: alignment
PHDR_SIZE : int = 56;       // sizeof(Elf64_Phdr)

// Write one ELF64 program header entry
fn write_phdr(buf: string, idx: int, p_type: int, p_flags: int,
    p_offset: int, p_vaddr: int, p_paddr: int,
    p_filesz: int, p_memsz: int, p_align: int) {
    base : ., mut = EHDR_SIZE + idx * PHDR_SIZE;
    w32(buf, base + P_TYPE, p_type);
    w32(buf, base + P_FLAGS, p_flags);
    w64(buf, base + P_OFFSET, p_offset);
    w64(buf, base + P_VADDR, p_vaddr);
    w64(buf, base + P_PADDR, p_paddr);
    w64(buf, base + P_FILESZ, p_filesz);
    w64(buf, base + P_MEMSZ, p_memsz);
    w64(buf, base + P_ALIGN, p_align);
}

// ── ELF header writer (x86-64) ──
fn elf2_hdr(buf: string, code_end: int, total_sz: int) {
    hdr_sz : ., mut = EHDR_SIZE + 2 * PHDR_SIZE;  // 64+112=176
    i := 0; loop { if i >= hdr_sz { break; } store8(buf, i, 0); i = i + 1; }
    // e_ident
    w8(buf, E_EHDR_MAGIC, 127); w8(buf, E_EHDR_MAGIC+1, 69);
    w8(buf, E_EHDR_MAGIC+2, 76); w8(buf, E_EHDR_MAGIC+3, 70);  // \x7fELF
    w8(buf, E_CLASS, 2);   // EI_CLASS = ELFCLASS64
    w8(buf, E_DATA, 1);    // EI_DATA = ELFDATA2LSB
    w8(buf, E_VER, 1);     // EI_VERSION = EV_CURRENT
    // e_type, e_machine, e_version
    w16(buf, E_TYPE, 2);    // ET_EXEC
    w16(buf, E_MACH, 62);   // EM_X86_64
    w32(buf, E_VERSION, 1); // EV_CURRENT
    w64(buf, E_ENTRY, 0x400000 + EHDR_SIZE + 2 * PHDR_SIZE);  // entry = text_base + 176
    w64(buf, E_PHOFF, EHDR_SIZE);              // phdrs start right after ehdr
    w16(buf, E_EHSIZE, EHDR_SIZE);             // sizeof(Elf64_Ehdr) = 64
    w16(buf, E_PHENTSIZE, PHDR_SIZE);          // sizeof(Elf64_Phdr) = 56
    w16(buf, E_PHNUM, 2);                      // 2 program headers

    // PHDR[0]: code segment (RX, file offset 0, VA = TEXT_BASE)
    write_phdr(buf, 0,
        1,     // PT_LOAD
        5,     // PF_R | PF_X
        0,                               // file offset
        4194304,                         // TEXT_BASE
        4194304,                         // phys addr = TEXT_BASE
        code_end, code_end, 4096);

    // PHDR[1]: rodata+BSS (RW, starts at page after code)
    rodata_va : ., mut = 4194304 + code_end;
    data_sz : ., mut = total_sz - code_end;
    write_phdr(buf, 1,
        1,     // PT_LOAD
        6,     // PF_R | PF_W
        code_end,
        rodata_va, rodata_va,
        data_sz, 1073741824, 4096);  // memsz = 1 GiB virtual bump heap
}

// ── Emit _start code, return total bytes ──
g_call_main_pos : int, mut;  // set by emit_start, used for patching call main
gv_argc : int, mut;   // IR var index for g_rt_argc (or -1)
gv_argv : int, mut;   // IR var index for g_rt_argv_ptr (or -1)

fn emit_start(buf: string, pos: int) -> int {
    cp : ., mut = pos;
    // mov rdi, [rsp]  — load argc (rdi=7)
    cp = cp + emit_rex(buf, cp, 1, 0, 0, 0);
    e2_w8(buf, cp, 139); cp = cp + 1;
    cp = cp + emit_modrm(buf, cp, 0, 7, 4);  // [rsp] via SIB
    cp = cp + emit_sib(buf, cp, 0, 4, 4);

    // lea rsi, [rsp+8]  — pointer to argv (rsi=6, no REX extension)
    cp = cp + emit_rex(buf, cp, 1, 0, 0, 0);
    e2_w8(buf, cp, 141); cp = cp + 1;
    cp = cp + emit_modrm(buf, cp, 1, 6, 4);  // [rsp+disp8]
    cp = cp + emit_sib(buf, cp, 0, 4, 4);
    e2_w8(buf, cp, 8); cp = cp + 1;

    if gv_argc >= 0 {
        // lea r10, [rip + 0]  (placeholder, patched in Phase 3)
        rip_pos := cp + 3;
        cp = cp + e2_lr(buf, cp, 0);
        grow_rip_patch(g_x86_rip_patch_count + 1);
        w64(g_x86_rip_patch_pos, g_x86_rip_patch_count * 8, rip_pos);
        w64(g_x86_rip_patch_globals, g_x86_rip_patch_count * 8, gv_argc);
        g_x86_rip_patch_count = g_x86_rip_patch_count + 1;
        // mov [r10], rdi — store argc
        cp = cp + emit_rex(buf, cp, 1, 0, 0, 10/8);
        e2_w8(buf, cp, 137); cp = cp + 1;
        cp = cp + emit_modrm(buf, cp, 0, 7, 10%8);
    }

    if gv_argv >= 0 {
        rip_pos2 := cp + 3;
        cp = cp + e2_lr(buf, cp, 0);
        grow_rip_patch(g_x86_rip_patch_count + 1);
        w64(g_x86_rip_patch_pos, g_x86_rip_patch_count * 8, rip_pos2);
        w64(g_x86_rip_patch_globals, g_x86_rip_patch_count * 8, gv_argv);
        g_x86_rip_patch_count = g_x86_rip_patch_count + 1;
        // mov [r10], rsi — store argv
        cp = cp + emit_rex(buf, cp, 1, 0, 0, 10/8);
        e2_w8(buf, cp, 137); cp = cp + 1;
        cp = cp + emit_modrm(buf, cp, 0, 6, 10%8);
    }

    g_call_main_pos = cp;
    cp = cp + e2_call(buf, cp, 0);  // call main

    // mov edi, eax
    e2_w8(buf, cp, 137); cp = cp + 1;
    cp = cp + emit_modrm(buf, cp, 3, 0, 7);

    // mov eax, 60  (sys_exit)
    e2_w8(buf, cp, 184); cp = cp + 1;  // 0xB8 MOV r, imm32 (rax)
    cp = cp + e2_w32(buf, cp, 60);

    // syscall
    e2_w8(buf, cp, 15); cp = cp + 1;
    e2_w8(buf, cp, 5); cp = cp + 1;

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
    // Mark global variables for RIP-relative addressing
    gi := 0; loop { if gi >= g_ir_global_count { break; }
        gv := r64(g_ir_globals, gi * 16 + 8);
        if gv >= 0 { grow_is_global(gv + 1); w64(g_x86_is_global, gv * 8, 1); }
    gi = gi + 1; }
    grow_is_global(g_ir_var_count);

    g_ni_syscall3 = -1; g_ni_load8 = -1; g_ni_store8 = -1; g_ni_load64 = -1;
    g_ni_load_str_ptr = -1; g_ni_store_str_ptr = -1; g_ni_get_arg = -1;
    g_ni_w64 = -1; g_ni_dyncpy = -1;
    ni_i : ., mut = 0;
    loop { if ni_i >= g_str_count { break; }
        ns := istr_get(ni_i);
        if str_eq(ns, "syscall3") != 0 { g_ni_syscall3 = ni_i; }
        if str_eq(ns, "load8") != 0 { g_ni_load8 = ni_i; }
        if str_eq(ns, "store8") != 0 { g_ni_store8 = ni_i; }
        if str_eq(ns, "load64") != 0 { g_ni_load64 = ni_i; }
        if str_eq(ns, "load_str_ptr") != 0 { g_ni_load_str_ptr = ni_i; }
        if str_eq(ns, "store_str_ptr") != 0 { g_ni_store_str_ptr = ni_i; }
        if str_eq(ns, "get_arg") != 0 { g_ni_get_arg = ni_i; }
        if str_eq(ns, "w64") != 0 { g_ni_w64 = ni_i; }
        if str_eq(ns, "_dyncpy") != 0 { g_ni_dyncpy = ni_i; }
    ni_i = ni_i + 1; }

    print("  ni: syscall3="); print(int_str(g_ni_syscall3));
    print(" load8="); print(int_str(g_ni_load8));
    print(" w64="); print(int_str(g_ni_w64));
    print(" dyncpy="); println(int_str(g_ni_dyncpy));

    // Reset scratch-emission garbage (res_labels -> emit_instr -> pollutes rip_patch arrays)
    g_x86_rip_patch_count = 0;
    g_x86_rodataref_count = 0;
    g_x86_alloc_patch_count = 0;

    println("  elf: Phase 1 (rodata layout)...");
    // Phase 1: rodata layout — collect string constants
    g_x86_str_count = 0;
    si := 0; loop { if si >= g_ir_str_const_count { break; } g2_str_off(r64(g_ir_str_consts, si * 8)); si = si + 1; }

    // Find g_rt_argc/g_rt_argv_ptr via name_idx (no str_eq loop)
    gv_argc = -1; gv_argv = -1;
    argc_ni := str_intern("g_rt_argc"); argv_ni := str_intern("g_rt_argv_ptr");
    gvsi : ., mut = 0;
    loop { if gvsi >= g_ir_global_count { break; }
        ni := r64(g_ir_globals, gvsi * 16);
        if ni == argc_ni { gv_argc = r64(g_ir_globals, gvsi * 16 + 8); }
        if ni == argv_ni { gv_argv = r64(g_ir_globals, gvsi * 16 + 8); }
    gvsi = gvsi + 1; }

    // Phase 2: compute sizes for all functions
    println("  elf: Phase 2 (size calc)...");
    // Estimate function code sizes (~8B/inst average). Correct BSS position
    // computed after Phase 3 emit (see rip_patch fixup below).
    max_labels : ., mut = 0;
    sfi : ., mut = 0;
    loop { if sfi >= g_ir_func_count { break; }
        ist2 := r64(g_ir_func_instr_start, sfi * 8);
        ic2 := r64(g_ir_func_instr_count, sfi * 8);
        // Count label indices for g_label_poses allocation
        cur_labels : ., mut = 0;
        ii2 : ., mut = 0;
        loop { if ii2 >= ic2 { break; }
            op := iri_op(ist2 + ii2);
            if op == IR_LABEL { lx := iri_s1(ist2 + ii2); if lx >= 0 && lx + 1 > cur_labels { cur_labels = lx + 1; } }
            if op == IR_BRANCH { lx := iri_s2(ist2 + ii2); if lx + 1 > cur_labels { cur_labels = lx + 1; }
                                 ly := iri_s3(ist2 + ii2); if ly + 1 > cur_labels { cur_labels = ly + 1; } }
            if op == IR_JUMP { lz := iri_s1(ist2 + ii2); if lz + 1 > cur_labels { cur_labels = lz + 1; } }
        ii2 = ii2 + 1; }
        if cur_labels > max_labels { max_labels = cur_labels; }
        grow_func_code_sz(sfi + 1); w64(g_x86_func_code_sz, sfi * 8, ic2 * 5);
    sfi = sfi + 1; }
    g_label_count = max_labels;

    total_code : ., mut = emit_start_size();
    fi := 0; g2_init(); loop { if fi >= g_ir_func_count { break; }
        if fi % 50 == 0 { print("    func "); print(int_str(fi)); print("/"); println(int_str(g_ir_func_count)); }
        ni := r64(g_ir_func_name_idx, fi * 8);
        grow_func_offsets(g_x86_func_off_count * 2 + 2);
        w64(g_x86_func_offsets, g_x86_func_off_count * 16, ni);
        w64(g_x86_func_offsets, g_x86_func_off_count * 16 + 8, total_code);
        g_x86_func_off_count = g_x86_func_off_count + 1;

        vc2 := r64(g_ir_func_var_count, fi * 8);
        pc2 := r64(g_ir_func_param_count, fi * 8);

        fsz := r64(g_x86_func_code_sz, fi * 8);
        g_x86_emit_stack_size = vc2 * 8;
        total_code = total_code + sz_push_rbp() + sz_mov_rbp_rsp();
        if g_opt_level >= 1 { total_code = total_code + 18; }  // push rbx,r12-r15(9) + pop r15-r12,rbx(9)
        ss_dry := g_x86_emit_stack_size;
        total_code = total_code + sz_sub_rsp(ss_dry);
        reg_pc2 : ., mut = pc2;
        if reg_pc2 > 6 { reg_pc2 = 6; }
        stack_pc2 : ., mut = pc2 - 6;
        if stack_pc2 < 0 { stack_pc2 = 0; }
        total_code = total_code + reg_pc2 * sz_save_param();
        total_code = total_code + stack_pc2 * sz_save_stack_param();
        total_code = total_code + fsz;
        total_code = total_code + sz_add_rsp(ss_dry) + sz_pop_rbp() + sz_ret();
        if g_opt_level >= 1 { total_code = total_code + 9; }  // pop r15,r14,r13,r12,rbx
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
    total_code = total_code + 84;  // alloc body with bounds check and hidden length header
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

    hdr_total : ., mut = EHDR_SIZE + 2 * PHDR_SIZE;
    rodata_base := total_code;
    g_x86_rodata_base = hdr_total + rodata_base;

    println("  elf: Phase 3 (emit)...");
    // Phase 3: emit to buffer
    cp := hdr_total;  // skip ELF header + program headers

    // NB: g_x86_is_global already marked before Phase 0 — no need to redo

    // ── _start (measured size from Phase 2) ──
    cp = cp + emit_start(buf, cp);

    // ── All functions ──
    g_x86_ret_patch_count = 0;
    g_x86_call_patch_count = 0;
    g_x86_rodataref_count = 0;
    g_x86_alloc_patch_count = 0;
    g_x86_ext_rel_count = 0;
fi = 0; loop { if fi >= g_ir_func_count { break; }
        if fi % 50 == 0 { print("    emit func "); print(int_str(fi)); print("/"); println(int_str(g_ir_func_count)); }
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

        // Init label state for single-pass backpatching (-1 = not yet seen)
        li2 : ., mut = 0;
        loop { if li2 >= g_label_count { break; } grow_label_poses(li2 + 1); w64(g_label_poses, li2*8, -1); li2 = li2 + 1; }
        g_pending_count = 0;

        // Save callee-saved registers (pushed before rbp setup → at [rbp+8..48])
        if g_opt_level >= 1 {
            w8(buf, cp, 83); cp = cp + 1;  // push rbx
            w8(buf, cp, 65); w8(buf, cp+1, 84); cp = cp + 2;  // push r12
            w8(buf, cp, 65); w8(buf, cp+1, 85); cp = cp + 2;  // push r13
            w8(buf, cp, 65); w8(buf, cp+1, 86); cp = cp + 2;  // push r14
            w8(buf, cp, 65); w8(buf, cp+1, 87); cp = cp + 2;  // push r15
        }
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
        // Save register and caller-stack params into this function's slots.
        pi := 0; loop { if pi >= pc { break; }
            po2 := -(vs + pi + 1 - g_current_func_var_start) * 8;  // force stack slot, ignore reg alloc
            if pi == 0 { cp = cp + e2_st(buf, cp, 7, po2); }
            if pi == 1 { w8(buf, cp, 72); w8(buf, cp+1, 137); w8(buf, cp+2, 117); w8(buf, cp+3, po2); cp = cp + 4; }
            if pi == 2 { w8(buf, cp, 72); w8(buf, cp+1, 137); w8(buf, cp+2, 85); w8(buf, cp+3, po2); cp = cp + 4; }
            if pi == 3 { w8(buf, cp, 72); w8(buf, cp+1, 137); w8(buf, cp+2, 77); w8(buf, cp+3, po2); cp = cp + 4; }
            if pi == 4 { w8(buf, cp, 76); w8(buf, cp+1, 137); w8(buf, cp+2, 69); w8(buf, cp+3, po2); cp = cp + 4; }
            if pi == 5 { w8(buf, cp, 76); w8(buf, cp+1, 137); w8(buf, cp+2, 77); w8(buf, cp+3, po2); cp = cp + 4; }
            if pi >= 6 {
                caller_off := 16 + (pi - 6) * 8;
                if g_opt_level >= 1 { caller_off = caller_off + 40; }
                cp = cp + e2_ld(buf, cp, 10, caller_off);
                cp = cp + e2_st(buf, cp, 10, po2);
            }
        pi = pi + 1; }

        // Load register-allocated parameters from stack to callee-saved regs
        if g_opt_level >= 1 {
            pi2 : ., mut = 0;
            loop { if pi2 >= pc || pi2 >= 6 { break; }
                pri := get_reg_for_var(vs + pi2);
                if pri >= 0 {
                    pso2 := -(vs + pi2 + 1 - g_current_func_var_start) * 8;  // force stack slot
                    // mov reg, [rbp+offset] — load from stack to allocated register
                    cp = cp + emit_rex(buf, cp, 1, pri/8, 0, 0);
                    e2_w8(buf, cp, 139); cp = cp + 1;  // 0x8B MOV r64, r/m64
                    cp = cp + emit_modrm(buf, cp, 1, pri%8, 5);  // [rbp+disp8]
                    e2_w8(buf, cp, pso2); cp = cp + 1;
                }
            pi2 = pi2 + 1; }
        }

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
        print("  rets: "); print(int_str(g_x86_ret_patch_count)); println("");
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
        if g_opt_level >= 1 {
            // Pops in REVERSE order: rbp, r15, r14, r13, r12, rbx
            w8(buf, cp, 93); cp = cp + 1;  // pop rbp
            w8(buf, cp, 65); w8(buf, cp+1, 95); cp = cp + 2;  // pop r15
            w8(buf, cp, 65); w8(buf, cp+1, 94); cp = cp + 2;  // pop r14
            w8(buf, cp, 65); w8(buf, cp+1, 93); cp = cp + 2;  // pop r13
            w8(buf, cp, 65); w8(buf, cp+1, 92); cp = cp + 2;  // pop r12
            w8(buf, cp, 91); cp = cp + 1;  // pop rbx
        } else {
            w8(buf, cp, 93); cp = cp + 1;  // pop rbp
        }
        w8(buf, cp, 195); cp = cp + 1;  // ret
        fi = fi + 1; }

    // ── _init_globals ──
    w8(buf, cp, 85); cp = cp + 1;
    w8(buf, cp, 72); w8(buf, cp+1, 137); w8(buf, cp+2, 229); cp = cp + 3;
    w8(buf, cp, 93); cp = cp + 1;
    w8(buf, cp, 195); cp = cp + 1;

    // ── alloc (bump allocator) ──
    // BSS VA will be computed after all code emitted — placeholder for now
    bss_va := ((TEXT_BASE + cp + 4096 + 4095) / 4096) * 4096;

    max_gv : ., mut = 0;
    gsi : ., mut = 0;
    loop { if gsi >= g_ir_global_count { break; }
        gvv := r64(g_ir_globals, gsi * 16 + 8);
        if gvv >= 0 && gvv > max_gv { max_gv = gvv; }
    gsi = gsi + 1; }
    // globals_size = (max_var_idx + 1) * 8 ensures BSS covers all globals
    globals_size : ., mut = (max_gv + 1) * 8;
    if globals_size < 256 { globals_size = 256; }
    alloc_sz := emit_alloc_body(buf, cp, bss_va, globals_size);
    alloc_start := cp;
    cp = cp + alloc_sz;

    // Update alloc's offset in func_offsets to real position (Phase 3 value)
    afi2 := 0;
    loop { if afi2 >= g_x86_func_off_count { break; }
        if str_eq(istr_get(r64(g_x86_func_offsets, afi2*16)), istr_get(alloc_ni)) != 0 {
            w64(g_x86_func_offsets, afi2*16+8, alloc_start - 176);
            break; }
    afi2 = afi2 + 1; }

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

    // ── Patch forward calls using actual cp positions ──
    // Phase 3 stored cp at start of each function in g_x86_func_cp
    // Must run after ALL code emitted (incl alloc + sched_call) so func_offsets are final
    cpi := 0; loop { if cpi >= g_x86_call_patch_count { break; }
        call_pos := r64(g_x86_call_patch_pos, cpi * 8);
        fn_ni := r64(g_x86_call_patch_name, cpi * 8);
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
        // Fallback: search g_x86_func_offsets for builtins
        if cfi2 >= g_ir_func_count {
            bfi2 : ., mut = 0;
            loop { if bfi2 >= g_x86_func_off_count { break; }
                if str_eq(istr_get(r64(g_x86_func_offsets, bfi2*16)), istr_get(fn_ni)) != 0 {
                    func_off := r64(g_x86_func_offsets, bfi2*16+8);
                    // Safety check: target must be within emitted code
                    target_pos := 176 + func_off;
                    if target_pos > 0 && target_pos < cp {
                        rel := target_pos - (call_pos + 5);
                        w32(buf, call_pos + 1, rel);
                    }
                    break; }
            bfi2 = bfi2 + 1; }
        }
    cpi = cpi + 1; }
    g_x86_call_patch_count = 0;

    // Pad code to page boundary so RW segment doesn't share a page with RX
    // (kernel maps shared page with RW permissions → code becomes non-executable)
    code_pad_end := (cp + 4095) / 4096 * 4096;
    loop { if cp >= code_pad_end { break; } w8(buf, cp, 0); cp = cp + 1; }

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
        // Write 8-byte length header (sl + null) so str_len via load64(s,-8) works
        w64(buf, cp, sl + 1); cp = cp + 8;
        ci := 0; loop { if ci >= sl { break; } w8(buf, cp, load8(s, ci)); ci = ci + 1; cp = cp + 1; }
        w8(buf, cp, 0); cp = cp + 1;
        loop { if cp % 8 == 0 { break; } w8(buf, cp, 0); cp = cp + 1; }
    si = si + 1; }

    // ── Recompute bss_va after all code emitted ──
    // total_code from Phase 2 underestimates; use actual cp for precise calculation.
    // +1 ensures BSS is on a different page from code.
    bss_va = ((TEXT_BASE + cp + 4096 + 4095) / 4096) * 4096;

    // The allocator was emitted earlier with a provisional BSS address.
    // Re-emit it in place now that the final data-segment VA is known.
    emit_alloc_body(buf, alloc_start, bss_va, globals_size);

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
        // Verify: buffer at ppos-3 should contain LEA prefix (0x4C or 0x4D for REX.WR/WRB)
        lea_check := bu8(buf, ppos - 3);
        if lea_check != 76 && lea_check != 77 && lea_check != 73 && lea_check != 79 {
            print("  BAD rip["); print(int_str(rpi2)); print("] ppos="); print(int_str(ppos));
            print(" gvi="); print(int_str(gvi));
            print(" byte="); println(int_str(lea_check));
        }
        if gvi >= 0 {
            lea_end_va := TEXT_BASE + ppos + 4;
            off := r64(g_x86_global_off, gvi * 8);
            target_va := bss_va + 16 + off;
            rel := target_va - lea_end_va;
            w32(buf, ppos, rel);
            // Verify write: read back and check
            rbv := bu8(buf,ppos) + bu8(buf,ppos+1)*256 + bu8(buf,ppos+2)*65536 + bu8(buf,ppos+3)*16777216;
            if rbv >= 2147483648 { rbv = rbv - 4294967296; }
            if rbv != rel && gvi >= 0 && gvi < 10 {
                print("  MISMATCH ppos="); print(int_str(ppos));
                print(" rel="); print(int_str(rel));
                print(" rbv="); println(int_str(rbv));
            }
            }
    rpi2 = rpi2 + 1; }
    g_x86_rip_patch_count = 0;

    // ── Patch _start's call to main ──
    // Search g_x86_func_offsets by name (indices differ from g_ir_func_name_idx)
    mo := -1; bfi3 := 0; loop { if bfi3 >= g_x86_func_off_count { break; }
        if str_eq(istr_get(r64(g_x86_func_offsets, bfi3*16)), "main") != 0 {
            mo = r64(g_x86_func_offsets, bfi3*16+8); break; }
    bfi3 = bfi3 + 1; }
    // Debug: find ALL entries named "main"
    bfi4 := 0; loop { if bfi4 >= g_x86_func_off_count { break; }
        nm := istr_get(r64(g_x86_func_offsets, bfi4*16));
        if str_eq(nm, "main") != 0 {
            off := r64(g_x86_func_offsets, bfi4*16+8);
            print("  main at ["); print(int_str(bfi4)); print("] off="); print(int_str(off)); print(" cp="); println(int_str(off + 176));
        }
    bfi4 = bfi4 + 1; }
    if mo >= 0 {
        rel := mo + 176 - g_call_main_pos - 5;
        w32(buf, g_call_main_pos + 1, rel);
    }

    // ── bss_init: zero BSS globals area before _start ──
    // WSL2 (and possibly other kernels) do not reliably zero BSS,
    // so we explicitly clear the first BSS_ZERO_SIZE bytes with
    // rep stosb. This stub becomes the new entry point; after
    // zeroing it jumps to the real _start.
    bss_init_cp := cp;
    BSS_ZERO_SIZE : int = 131072;  // 128 KB — covers all globals

    // lea rdi, [rip + rel]  → rdi = bss_va
    rel_di := bss_va - (TEXT_BASE + cp + 7);
    w8(buf, cp, 72); w8(buf, cp+1, 141); w8(buf, cp+2, 61);
    w8_signed(buf, cp+3, rel_di); cp = cp + 7;

    // mov ecx, BSS_ZERO_SIZE
    w8(buf, cp, 185); e2_w32(buf, cp+1, BSS_ZERO_SIZE); cp = cp + 5;

    // xor eax, eax; cld; rep stosb
    w8(buf, cp, 49); w8(buf, cp+1, 192); cp = cp + 2;
    w8(buf, cp, 252); cp = cp + 1;
    w8(buf, cp, 243); w8(buf, cp+1, 170); cp = cp + 2;

    // jmp _start  (TEXT_BASE + 176)
    jmp_rel := TEXT_BASE + 176 - (TEXT_BASE + cp + 5);
    w8(buf, cp, 233); e2_w32(buf, cp+1, jmp_rel); cp = cp + 5;

    // ── Write ELF header ──
    total_sz := cp;
    // Use actual total_sz as code_end so code segment covers all emitted content
    elf2_hdr(buf, total_sz, total_sz);
    // Override entry point to bss_init (which zeroes heap then jumps to _start)
    w64(buf, E_ENTRY, TEXT_BASE + bss_init_cp);
    // Patch data segment VA to match bss_va (page after code+rodata)
    data_phdr_base := EHDR_SIZE + PHDR_SIZE;
    w64(buf, data_phdr_base + P_OFFSET, bss_va - TEXT_BASE);
    w64(buf, data_phdr_base + P_VADDR, bss_va);
    w64(buf, data_phdr_base + P_PADDR, bss_va);
    g_asm_code_size = total_sz;
    return total_sz;
}
