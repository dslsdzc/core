// === backend/x86_64/elf.cr ===
// Direct ELF binary output for x86-64 using the new resolve+emit interface.
// Depends on: x86_64/instr.cr (arch_instr_size, x86_emit_instr, g2_*)
// Depends on: backend/resolve.cr (resolve_labels)

// ── ELF constants (x86-64) ──
ET_EXEC : int = 2;
EM_X86_64 : int = 62;
PT_LOAD : int = 1;
PF_RX : int = 5;
PF_RW : int = 6;

fn r16(buf: string, pos: int) -> int { return r8(buf,pos) + r8(buf,pos+1)*256; }

TEXT_BASE : int = 4194304;  // 0x400000 - base address of code segment

fn w8_signed(buf: string, pos: int, val: int) {
    uv : ., mut = val;
    if uv < 0 { uv = uv + 4294967296; }
    w8(buf, pos, uv % 256); w8(buf, pos+1, (uv/256) % 256);
    w8(buf, pos+2, (uv/65536) % 256); w8(buf, pos+3, (uv/16777216) % 256);
}

// Emit __builtin_alloc bump allocator function body
// Returns bytes written (always 65)
fn emit_builtin_alloc_body(buf: string, pos: int, bss_va: int) -> int {
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

fn w16(buf: string, off: int, val: int) {
    w8(buf, off, val % 256); w8(buf, off+1, (val/256) % 256);
}

fn align_up(val: int, align: int) -> int { return (val + align - 1) / align * align; }

// ── Global ──
g_asm_code_size : int, mut;
g_elf_buf : string, mut;

// ── ELF header writer (x86-64) ──
fn elf2_hdr(buf: string, total_sz: int) {
    i := 0; loop { if i >= 176 { break; } __builtin_store8(buf, i, 0); i = i + 1; }
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

// ── Main ELF generation ──
fn x86_64_elf_generate(buf: string) -> int {
    // Phase 0: resolve labels (uses arch_instr_size from instr.cr)
    resolve_labels();

    // Phase 1: rodata layout — collect string constants
    g_x86_str_count = 0;
    si := 0; loop { if si >= g_ir_str_const_count { break; } g2_str_off(g_ir_str_consts[si]); si = si + 1; }

    // Phase 2: measure total code size and build function offset table
    g_x86_func_off_count = 0;
    total_code : ., mut = 14;  // _start stub

    fi := 0; loop { if fi >= g_ir_func_count { break; }
        ni := r64(g_ir_func_name_idx, fi * 8);
        g_x86_func_offsets[g_x86_func_off_count * 2] = ni;
        g_x86_func_offsets[g_x86_func_off_count * 2 + 1] = total_code;
        g_x86_func_off_count = g_x86_func_off_count + 1;

        ic := r64(g_ir_func_instr_count, fi * 8);
        vc := g_ir_var_count;
        pc := r64(g_ir_func_param_count, fi * 8);

        // frame: push rbp(1) + mov rbp,rsp(3) + sub rsp(4) + params(pc*4)
        total_code = total_code + 1 + 3;
        if vc > 0 { total_code = total_code + 4; }
        total_code = total_code + pc * 4;

        // instructions (skip NOPs = old LABELs)
        ii := 0; loop { if ii >= ic { break; }
            inst_idx := r64(g_ir_func_instr_start, fi * 8)+ ii;
            if iri_op(inst_idx) != IR_NOP {
                total_code = total_code + arch_instr_size(inst_idx);
            }
        ii = ii + 1; }

        // epilogue: add rsp(4, if vc>0) + pop rbp(1) + ret(1)
        if vc > 0 { total_code = total_code + 4; }
        total_code = total_code + 1 + 1;
    fi = fi + 1; }

    // __builtin_alloc: bump allocator for heap allocation in ELF output
    alloc_ni := str_intern("__builtin_alloc");
    g_x86_func_offsets[g_x86_func_off_count * 2] = alloc_ni;
    g_x86_func_offsets[g_x86_func_off_count * 2 + 1] = total_code;
    g_x86_func_off_count = g_x86_func_off_count + 1;
    total_code = total_code + 65;

    rd_sz := g2_rodata_sz();
    total_code = total_code + 6;  // _init_globals
    rodata_base := total_code;  // relative to code section start
    g_x86_rodata_base = rodata_base;  // for x86_emit_instr string LEA

    // Phase 3: emit to buffer
    cp := 176;  // skip ELF header

    // ── _start ──
    call_main_pos := cp;
    cp = cp + e2_call(buf, cp, 0);  // call main (rel=0 placeholder, patched later)
    w8(buf, cp, 137); w8(buf, cp+1, 199); cp = cp + 2;  // mov edi, eax
    w8(buf, cp, 184); w32(buf, cp+1, 60); cp = cp + 5;  // mov eax, 60
    w8(buf, cp, 15); w8(buf, cp+1, 5); cp = cp + 2;  // syscall

    // ── All functions ──
    g_x86_ret_patch_count = 0;
    fi = 0; loop { if fi >= g_ir_func_count { break; }
        ni := r64(g_ir_func_name_idx, fi * 8);
        ist := r64(g_ir_func_instr_start, fi * 8);
        ic := r64(g_ir_func_instr_count, fi * 8);
        vc := g_ir_var_count;
        vs := r64(g_ir_func_var_start, fi * 8);
        pc := r64(g_ir_func_param_count, fi * 8);

        g2_init();
        vi := 0; loop { if vi >= vc { break; } g2_slot(vs + vi); vi = vi + 1; }

        // frame
        w8(buf, cp, 85); cp = cp + 1;  // push rbp
        w8(buf, cp, 72); w8(buf, cp+1, 137); w8(buf, cp+2, 229); cp = cp + 3;  // mov rbp, rsp
        if g_x86_emit_stack_size > 0 {
            w8(buf, cp, 72); w8(buf, cp+1, 131); w8(buf, cp+2, 236); w8(buf, cp+3, g_x86_emit_stack_size); cp = cp + 4;
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

        ii := 0; loop { if ii >= ic { break; }
            inst_idx := ist + ii;
            sz := x86_emit_instr(inst_idx, buf, cp);
            cp = cp + sz;
        ii = ii + 1; }

        // patch RETURNs to epilogue
        epi_pos := cp;
        rpi := 0; loop { if rpi >= g_x86_ret_patch_count { break; }
            jmp_pos := g_x86_ret_patch_pos[rpi];
            rel := epi_pos - (jmp_pos + 5);
            w32(buf, jmp_pos + 1, rel);
        rpi = rpi + 1; }
        g_x86_ret_patch_count = 0;

        // epilogue
        if g_x86_emit_stack_size > 0 {
            w8(buf, cp, 72); w8(buf, cp+1, 131); w8(buf, cp+2, 196); w8(buf, cp+3, g_x86_emit_stack_size); cp = cp + 4;
        }
        w8(buf, cp, 93); cp = cp + 1;  // pop rbp
        w8(buf, cp, 195); cp = cp + 1;  // ret
    fi = fi + 1; }

    // ── _init_globals ──
    w8(buf, cp, 85); cp = cp + 1;
    w8(buf, cp, 72); w8(buf, cp+1, 137); w8(buf, cp+2, 229); cp = cp + 3;
    w8(buf, cp, 93); cp = cp + 1;
    w8(buf, cp, 195); cp = cp + 1;

    // ── __builtin_alloc (bump allocator) ──
    // Compute BSS VA for heap_ptr placement
    rodata_sz := g2_rodata_sz();
    final_est := cp + 65 + rodata_sz;
    bss_va := (TEXT_BASE + final_est + 4095) / 4096 * 4096;

    alloc_sz := emit_builtin_alloc_body(buf, cp, bss_va);
    alloc_start := cp;
    cp = cp + alloc_sz;

    // Patch all IR_ALLOC_STRUCT/ARRAY/MAKE_ENUM call sites to point to __builtin_alloc
    // alloc_patch_pos entries are buffer positions of the 5-byte call instruction
    // __builtin_alloc offset = alloc_start - 176 (relative to code section start)
    alloc_code_off := alloc_start - 176;
    api := 0;
    loop { if api >= g_x86_alloc_patch_count { break; }
        call_pos := g_x86_alloc_patch_pos[api];
        rel := (176 + alloc_code_off) - (call_pos + 5);
        w32(buf, call_pos + 1, rel);
        api = api + 1; }
    g_x86_alloc_patch_count = 0;

    // ── .rodata ──
    si = 0; loop { if si >= g_x86_str_count { break; }
        s := str_get(g_x86_str_offs[si]);
        sl := __builtin_str_len(s);
        ci := 0; loop { if ci >= sl { break; } w8(buf, cp, __builtin_load8(s, ci)); ci = ci + 1; cp = cp + 1; }
        w8(buf, cp, 0); cp = cp + 1;
    si = si + 1; }

    // ── Patch _start's call to main ──
    mo := -1; fi = 0; loop { if fi >= g_ir_func_count { break; }
        if __builtin_str_eq(str_get(r64(g_ir_func_name_idx, fi * 8)), "main") != 0 { mo = g_x86_func_offsets[fi*2+1]; break; }
    fi = fi + 1; }
    if mo >= 0 {
        rel := mo - 5;
        w32(buf, call_main_pos + 1, rel);
    }

    // ── Write ELF header ──
    total_sz := cp;
    elf2_hdr(buf, total_sz);
    g_asm_code_size = total_sz;
    return total_sz;
}
