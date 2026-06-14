// === elf.cr ===
// Direct ELF executable output — no as/ld needed.
// Two-pass assembler: first pass locates labels and measures sizes,
// second pass encodes to machine code bytes.
//
// Depends on: toml.cr (MemLayout)

// ── ELF constants (x86-64) ──
ET_EXEC : int = 2;
EM_X86_64 : int = 62;
PT_LOAD : int = 1;
PF_RX : int = 5;
PF_RW : int = 6;

fn w8(buf: string, pos: int, val: int) { __builtin_store8(buf, pos, val % 256); }

fn w32(buf: string, pos: int, val: int) {
    w8(buf, pos, val % 256); w8(buf, pos+1, (val/256) % 256);
    w8(buf, pos+2, (val/65536) % 256); w8(buf, pos+3, (val/16777216) % 256);
}

fn w64(buf: string, pos: int, val: int) {
    w32(buf, pos, val)); w32(buf, pos+4, val/4294967296));
}

// ── Global: code size (set by asm_to_bytes) ──
g_asm_code_size : int, mut;

// ── Label tracking for jmp/je offset calculation ──
// For labels like .L1, .L2, .L3, .Lret0
// Store position for each label number (0-31)

fn w16(buf: string, off: int, val: int) {
    w8(buf, off, val % 256); w8(buf, off+1, (val/256) % 256);
}

fn align_up(val: int, align: int) -> int { return (val + align - 1) / align * align; }

// ── ELF writer ──
struct ElfCtx { buf: string, pos: int, code_start: int }

fn elf_begin(layout: MemLayout) -> ElfCtx {
    total := 65536; buf := __builtin_alloc(total);
    i : ., mut = 0; loop { if i >= total { break; } __builtin_store8(buf, i, 0); i = i + 1; }
    return ElfCtx { buf = buf, pos = 0, code_start = 0 };
}

fn elf_write_header(ctx: ElfCtx, layout: MemLayout, code_size: int) {
    hoff : ., mut = 0;
    w32(ctx.buf, hoff, 1179403647)); hoff=hoff+4; // magic
    w8(ctx.buf, hoff, 2); hoff=hoff+1; w8(ctx.buf, hoff, 1); hoff=hoff+1;
    w8(ctx.buf, hoff, 1); hoff=hoff+1; w8(ctx.buf, hoff, 0); hoff=hoff+1;
    w64(ctx.buf, hoff, 0); hoff=hoff+8; w32(ctx.buf, hoff, 0)); hoff=hoff+4;
    w8(ctx.buf, hoff, 0); hoff=hoff+1; hoff=16;
    text_base : ., mut = layout.text_base; data_base : ., mut = layout.data_base;
    if text_base == 0 { text_base = 4194304; }
    if data_base == 0 { data_base = text_base + align_up(code_size, 4096); }
    heap_size : ., mut = layout.heap_size;
    if heap_size == 0 { heap_size = 268435456; }
    w16(ctx.buf, hoff, ET_EXEC); hoff=hoff+2; w16(ctx.buf, hoff, EM_X86_64); hoff=hoff+2;
    w32(ctx.buf, hoff, 1)); hoff=hoff+4;
    w64(ctx.buf, hoff, text_base + ctx.code_start); hoff=hoff+8;
    w64(ctx.buf, hoff, 64); hoff=hoff+8; w64(ctx.buf, hoff, 0); hoff=hoff+8;
    w32(ctx.buf, hoff, 0)); hoff=hoff+4; w16(ctx.buf, hoff, 64); hoff=hoff+2;
    w16(ctx.buf, hoff, 56); hoff=hoff+2; w16(ctx.buf, hoff, 2); hoff=hoff+2;
    w16(ctx.buf, hoff, 0); hoff=hoff+2; w16(ctx.buf, hoff, 0); hoff=hoff+2;
    w16(ctx.buf, hoff, 0); hoff=hoff+2;
    // PHDR 1: code RX
    phoff := 64;
    w32(ctx.buf, phoff, PT_LOAD)); phoff=phoff+4; w32(ctx.buf, phoff, PF_RX)); phoff=phoff+4;
    w64(ctx.buf, phoff, 0); phoff=phoff+8;
    w64(ctx.buf, phoff, text_base); phoff=phoff+8; w64(ctx.buf, phoff, text_base); phoff=phoff+8;
    w64(ctx.buf, phoff, code_size); phoff=phoff+8; w64(ctx.buf, phoff, code_size); phoff=phoff+8;
    w64(ctx.buf, phoff, 4096); phoff=phoff+8;
    // PHDR 2: data BSS RW
    w32(ctx.buf, phoff, PT_LOAD)); phoff=phoff+4; w32(ctx.buf, phoff, PF_RW)); phoff=phoff+4;
    w64(ctx.buf, phoff, 0); phoff=phoff+8; w64(ctx.buf, phoff, data_base); phoff=phoff+8;
    w64(ctx.buf, phoff, data_base); phoff=phoff+8;
    w64(ctx.buf, phoff, 0); phoff=phoff+8; w64(ctx.buf, phoff, heap_size); phoff=phoff+8;
    w64(ctx.buf, phoff, 4096); phoff=phoff+8;
    ctx.pos = ctx.code_start;
}

fn elf_write_code(ctx: ElfCtx, code: string) {
    i : ., mut = 0;
    loop { if i >= g_asm_code_size { break; } __builtin_store8(ctx.buf, ctx.pos+i, __builtin_load8(code, i); i = i + 1); }
    ctx.pos = ctx.pos + g_asm_code_size;
}

fn elf_finish(ctx: ElfCtx, path: string, total_size: int) -> int {
    fd := __builtin_syscall3(2, path, 577, 420);  // O_WRONLY|O_CREAT|O_TRUNC, 0644
    if fd < 0 { return -1; }
    nw := __builtin_syscall3(1, fd, ctx.buf, total_size);  // write(fd, buf, size)
    __builtin_syscall3(3, fd, 0, 0);  // close(fd)
    return nw;
}

// ── Two-pass assembler ──
// Pass 1: measure instruction sizes, record label positions
// Pass 2: encode to bytes with correct jump offsets

struct LineInfo {
    line: string,
    size: int,
    is_label: int,
    label_name: string,
}

fn parse_line(op: string, args: string) {
    // Placeholder for line parsing
}

fn is_label_line(line: string) -> int {
    slen := __builtin_str_len(line);
    ci : ., mut = 0;
    loop { if ci >= slen { return 0; } if __builtin_str_get(line, ci) == ":" { return 1; } ci = ci + 1; }
    return 0;
}

fn skip_dir(line: string) -> int {
    // Returns 1 if line is a directive/label we skip
    if __builtin_str_len(line) == 0 { return 1; }
    c0 := __builtin_str_get(line, 0);
    if c0 == "." || c0 == "/" || c0 == "_" { return 1; }
    return 0;
}

fn measure_instr(line: string) -> int {
    // Determine instruction size in bytes for pass 1
    // Fixed-size instructions
    if __builtin_str_eq(line, "    push rbp") != 0 { return 1; }
    if __builtin_str_eq(line, "    pop rbp") != 0 { return 1; }
    if __builtin_str_eq(line, "    push rbx") != 0 { return 1; }
    if __builtin_str_eq(line, "    pop rbx") != 0 { return 1; }
    if __builtin_str_eq(line, "    push r15") != 0 { return 2; }
    if __builtin_str_eq(line, "    pop r15") != 0 { return 2; }
    if __builtin_str_eq(line, "    ret") != 0 { return 1; }
    if __builtin_str_eq(line, "    cqo") != 0 { return 2; }
    if __builtin_str_eq(line, "    mov rbp, rsp") != 0 { return 3; }
    if __builtin_str_eq(line, "    mov rsp, rbp") != 0 { return 3; }
    if __builtin_str_eq(line, "    mov rax, r10") != 0 { return 3; }
    if __builtin_str_eq(line, "    mov r10, rax") != 0 { return 3; }
    if __builtin_str_eq(line, "    mov r10, rdx") != 0 { return 3; }
    if __builtin_str_eq(line, "    add r10, r11") != 0 { return 3; }
    if __builtin_str_eq(line, "    sub r10, r11") != 0 { return 3; }
    if __builtin_str_eq(line, "    imul r10, r11") != 0 { return 4; }
    if __builtin_str_eq(line, "    xor r10, r11") != 0 { return 3; }
    if __builtin_str_eq(line, "    and r10, r11") != 0 { return 3; }
    if __builtin_str_eq(line, "    or r10, r11") != 0 { return 3; }
    if __builtin_str_eq(line, "    neg r10") != 0 { return 3; }
    if __builtin_str_eq(line, "    xor eax, eax") != 0 { return 2; }
    if __builtin_str_eq(line, "    idiv r11") != 0 { return 3; }
    if __builtin_str_eq(line, "    cmp r10, 0") != 0 { return 4; }
    if __builtin_str_eq(line, "    cmp r10, 1") != 0 { return 4; }
    if __builtin_str_eq(line, "    cmp r10, r11") != 0 { return 3; }
    if __builtin_str_eq(line, "    mov [r10], r11") != 0 { return 3; }
    if __builtin_str_eq(line, "    mov [r10], r12") != 0 { return 3; }
    if __builtin_str_eq(line, "    mov [r10], r13") != 0 { return 3; }
    if __builtin_str_eq(line, "    mov r11, [r10]") != 0 { return 3; }
    if __builtin_str_eq(line, "    mov r11, [r10 + 0]") != 0 { return 4; }
    if __builtin_str_eq(line, "    shl r11, 3") != 0 { return 4; }
    if __builtin_str_eq(line, "    mov r10, rax") != 0 { return 3; }
    if __builtin_str_eq(line, "    mov r10, rdx") != 0 { return 3; }
    if __builtin_str_eq(line, "    sete al") != 0 { return 3; }  // 0f 94 c0
    if __builtin_str_eq(line, "    setg al") != 0 { return 3; }
    if __builtin_str_eq(line, "    setge al") != 0 { return 3; }
    if __builtin_str_eq(line, "    setl al") != 0 { return 3; }
    if __builtin_str_eq(line, "    setle al") != 0 { return 3; }
    if __builtin_str_eq(line, "    setne al") != 0 { return 3; }

    // sub rsp, N
    slen := __builtin_str_len(line);
    if slen > 13 {
        if __builtin_str_eq(__builtin_str_sub(line, 0, 13), "    sub rsp, ") != 0 { return 4; }
    }
    // add rsp, N
    if slen > 13 {
        if __builtin_str_eq(__builtin_str_sub(line, 0, 13), "    add rsp, ") != 0 { return 4; }
    }
    // mov edi, N
    if slen > 12 {
        if __builtin_str_eq(__builtin_str_sub(line, 0, 13), "    mov edi, ") != 0 { return 5; }
    }
    // mov qword ptr [rbp+N], VAL
    if slen > 24 {
        if __builtin_str_eq(__builtin_str_sub(line, 0, 22), "    mov qword ptr [rbp") != 0 {
            // 8 bytes for disp8 form, 11 for disp32
            return 8;  // Assume disp8 for now
        }
    }
    // mov r10, [rbp+N] / mov r11, [rbp+N] / mov rax, [rbp+N] / mov r12, [rbp+N]
    if slen > 19 {
        pre := __builtin_str_sub(line, 0, 19);
        if __builtin_str_eq(pre, "    mov r10, [rbp") != 0 { return 4; }
        if __builtin_str_eq(pre, "    mov r11, [rbp") != 0 { return 4; }
        if __builtin_str_eq(pre, "    mov r12, [rbp") != 0 { return 4; }
        if __builtin_str_eq(pre, "    mov rax, [rbp") != 0 { return 4; }
    }
    // mov [rbp+N], r10 / mov [rbp+N], r11
    if slen > 18 {
        pre := __builtin_str_sub(line, 0, 18);
        if __builtin_str_eq(pre, "    mov [rbp") != 0 { return 4; }
    }
    // mov [r10 + N], r11 / mov [r10 + N], r12
    if slen > 16 {
        pre := __builtin_str_sub(line, 0, 16);
        if __builtin_str_eq(pre, "    mov [r10 + ") != 0 { return 4; }
        if __builtin_str_eq(pre, "    mov r11, [r10") != 0 { return 4; }
    }
    // mov [r10 + r11 * 8], r12 → 4 bytes
    if slen > 26 {
        if __builtin_str_eq(__builtin_str_sub(line, 0, 26), "    mov [r10 + r11 * 8], r12") != 0 { return 4; }
    }
    // mov r12, [r10 + r11 * 8] → 4 bytes
    if slen > 26 {
        if __builtin_str_eq(__builtin_str_sub(line, 0, 26), "    mov r12, [r10 + r11 * 8]") != 0 { return 4; }
    }
    // lea r10, [rbp+N] → 4 bytes
    if slen > 18 {
        if __builtin_str_eq(__builtin_str_sub(line, 0, 17), "    lea r10, [rbp") != 0 { return 4; }
    }
    // setX al + movzx r10, al → 6 bytes total
    if slen > 14 {
        if __builtin_str_eq(__builtin_str_sub(line, 0, 14), "    movzx r10") != 0 { return 3; }
    }
    // jmp .LretN → 2 bytes short
    if slen > 12 {
        if __builtin_str_eq(__builtin_str_sub(line, 0, 12), "    jmp .Lret") != 0 { return 2; }
    }
    // je .LretN → 2 bytes short
    if slen > 12 {
        if __builtin_str_eq(__builtin_str_sub(line, 0, 12), "    je  .Lret") != 0 { return 2; }
    }
    // call (NOP placeholder)
    if slen > 9 {
        if __builtin_str_eq(__builtin_str_sub(line, 0, 9), "    call ") != 0 { return 1; }
    }
    // Unknown → 1 byte NOP
    return 1;
}

fn encode_instr(line: string, code: string, cpos: int) -> int {
    // ── Fixed patterns (exact match) ──
    // push/pop rbp, rbx, r15
    t := line;
    if __builtin_str_eq(t, "    push rbp") != 0 { __builtin_store8(code, cpos, 85); return 1; }
    if __builtin_str_eq(t, "    pop rbp") != 0 { __builtin_store8(code, cpos, 93); return 1; }
    if __builtin_str_eq(t, "    push rbx") != 0 { __builtin_store8(code, cpos, 83); return 1; }
    if __builtin_str_eq(t, "    pop rbx") != 0 { __builtin_store8(code, cpos, 91); return 1; }
    if __builtin_str_eq(t, "    push r15") != 0 { __builtin_store8(code, cpos, 65); __builtin_store8(code, cpos+1, 87); return 2; }
    if __builtin_str_eq(t, "    pop r15") != 0 { __builtin_store8(code, cpos, 65); __builtin_store8(code, cpos+1, 95); return 2; }
    if __builtin_str_eq(t, "    ret") != 0 { __builtin_store8(code, cpos, 195); return 1; }
    if __builtin_str_eq(t, "    cqo") != 0 { __builtin_store8(code, cpos, 72); __builtin_store8(code, cpos+1, 153); return 2; }
    if __builtin_str_eq(t, "    xor eax, eax") != 0 { __builtin_store8(code, cpos, 49); __builtin_store8(code, cpos+1, 192); return 2; }
    if __builtin_str_eq(t, "    neg r10") != 0 { __builtin_store8(code, cpos, 73); __builtin_store8(code, cpos+1, 217); return 2; }
    // mov reg, reg
    if __builtin_str_eq(t, "    mov rbp, rsp") != 0 { __builtin_store8(code, cpos, 72); __builtin_store8(code, cpos+1, 137); __builtin_store8(code, cpos+2, 229); return 3; }
    if __builtin_str_eq(t, "    mov rsp, rbp") != 0 { __builtin_store8(code, cpos, 72); __builtin_store8(code, cpos+1, 137); __builtin_store8(code, cpos+2, 236); return 3; }
    if __builtin_str_eq(t, "    mov rax, r10") != 0 { __builtin_store8(code, cpos, 76); __builtin_store8(code, cpos+1, 137); __builtin_store8(code, cpos+2, 208); return 3; }
    if __builtin_str_eq(t, "    mov r10, rax") != 0 { __builtin_store8(code, cpos, 73); __builtin_store8(code, cpos+1, 137); __builtin_store8(code, cpos+2, 194); return 3; }
    if __builtin_str_eq(t, "    mov r10, rdx") != 0 { __builtin_store8(code, cpos, 73); __builtin_store8(code, cpos+1, 137); __builtin_store8(code, cpos+2, 210); return 3; }
    // ALU
    if __builtin_str_eq(t, "    add r10, r11") != 0 { __builtin_store8(code, cpos, 77); __builtin_store8(code, cpos+1, 1); __builtin_store8(code, cpos+2, 218); return 3; }
    if __builtin_str_eq(t, "    sub r10, r11") != 0 { __builtin_store8(code, cpos, 77); __builtin_store8(code, cpos+1, 41); __builtin_store8(code, cpos+2, 218); return 3; }
    if __builtin_str_eq(t, "    imul r10, r11") != 0 { __builtin_store8(code, cpos, 77); __builtin_store8(code, cpos+1, 15); __builtin_store8(code, cpos+2, 175); __builtin_store8(code, cpos+3, 211); return 4; }
    if __builtin_str_eq(t, "    xor r10, r11") != 0 { __builtin_store8(code, cpos, 77); __builtin_store8(code, cpos+1, 49); __builtin_store8(code, cpos+2, 218); return 3; }
    if __builtin_str_eq(t, "    and r10, r11") != 0 { __builtin_store8(code, cpos, 77); __builtin_store8(code, cpos+1, 33); __builtin_store8(code, cpos+2, 218); return 3; }
    if __builtin_str_eq(t, "    or r10, r11") != 0 { __builtin_store8(code, cpos, 77); __builtin_store8(code, cpos+1, 9); __builtin_store8(code, cpos+2, 218); return 3; }
    if __builtin_str_eq(t, "    idiv r11") != 0 { __builtin_store8(code, cpos, 73); __builtin_store8(code, cpos+1, 247); __builtin_store8(code, cpos+2, 251); return 3; }
    if __builtin_str_eq(t, "    shl r11, 3") != 0 { __builtin_store8(code, cpos, 73); __builtin_store8(code, cpos+1, 193); __builtin_store8(code, cpos+2, 227); __builtin_store8(code, cpos+3, 3); return 4; }
    // cmp
    if __builtin_str_eq(t, "    cmp r10, 0") != 0 { __builtin_store8(code, cpos, 77); __builtin_store8(code, cpos+1, 131); __builtin_store8(code, cpos+2, 250); __builtin_store8(code, cpos+3, 0); return 4; }
    if __builtin_str_eq(t, "    cmp r10, 1") != 0 { __builtin_store8(code, cpos, 77); __builtin_store8(code, cpos+1, 131); __builtin_store8(code, cpos+2, 250); __builtin_store8(code, cpos+3, 1); return 4; }
    if __builtin_str_eq(t, "    cmp r10, r11") != 0 { __builtin_store8(code, cpos, 77); __builtin_store8(code, cpos+1, 57); __builtin_store8(code, cpos+2, 218); return 3; }
    // mem direct
    if __builtin_str_eq(t, "    mov [r10], r11") != 0 { __builtin_store8(code, cpos, 77); __builtin_store8(code, cpos+1, 137); __builtin_store8(code, cpos+2, 26); return 3; }
    if __builtin_str_eq(t, "    mov [r10], r12") != 0 { __builtin_store8(code, cpos, 77); __builtin_store8(code, cpos+1, 137); __builtin_store8(code, cpos+2, 34); return 3; }
    if __builtin_str_eq(t, "    mov [r10], r13") != 0 { __builtin_store8(code, cpos, 77); __builtin_store8(code, cpos+1, 137); __builtin_store8(code, cpos+2, 42); return 3; }
    if __builtin_str_eq(t, "    mov r11, [r10]") != 0 { __builtin_store8(code, cpos, 77); __builtin_store8(code, cpos+1, 139); __builtin_store8(code, cpos+2, 26); return 3; }
    if __builtin_str_eq(t, "    mov r11, [r10 + 0]") != 0 { __builtin_store8(code, cpos, 77); __builtin_store8(code, cpos+1, 139); __builtin_store8(code, cpos+2, 90); __builtin_store8(code, cpos+3, 0); return 4; }
    if __builtin_str_eq(t, "    mov r10, rdx") != 0 { __builtin_store8(code, cpos, 73); __builtin_store8(code, cpos+1, 137); __builtin_store8(code, cpos+2, 210); return 3; }
    // setX al
    if __builtin_str_eq(t, "    sete al") != 0 { __builtin_store8(code, cpos, 15); __builtin_store8(code, cpos+1, 148); __builtin_store8(code, cpos+2, 192); return 3; }
    if __builtin_str_eq(t, "    setg al") != 0 { __builtin_store8(code, cpos, 15); __builtin_store8(code, cpos+1, 159); __builtin_store8(code, cpos+2, 192); return 3; }
    if __builtin_str_eq(t, "    setge al") != 0 { __builtin_store8(code, cpos, 15); __builtin_store8(code, cpos+1, 157); __builtin_store8(code, cpos+2, 192); return 3; }
    if __builtin_str_eq(t, "    setl al") != 0 { __builtin_store8(code, cpos, 15); __builtin_store8(code, cpos+1, 156); __builtin_store8(code, cpos+2, 192); return 3; }
    if __builtin_str_eq(t, "    setle al") != 0 { __builtin_store8(code, cpos, 15); __builtin_store8(code, cpos+1, 158); __builtin_store8(code, cpos+2, 192); return 3; }
    if __builtin_str_eq(t, "    setne al") != 0 { __builtin_store8(code, cpos, 15); __builtin_store8(code, cpos+1, 149); __builtin_store8(code, cpos+2, 192); return 3; }
    // movzx r10, al
    if __builtin_str_len(t) > 14 {
        if __builtin_str_eq(__builtin_str_sub(t, 0, 14), "    movzx r10") != 0 {
            __builtin_store8(code, cpos, 73); __builtin_store8(code, cpos+1, 15);
            __builtin_store8(code, cpos+2, 182); __builtin_store8(code, cpos+3, 194); return 4;
        }
    }
    // mov rax, [rbp+N] — REX.W 8B 45 disp8
    if __builtin_str_len(t) > 19 {
        if __builtin_str_eq(__builtin_str_sub(t, 0, 17), "    mov rax, [rbp") != 0 {
            off_str := __builtin_str_sub(t, 17, __builtin_str_len(t) - 18);
            off := __builtin_str_to_int(off_str);
            __builtin_store8(code, cpos, 72); __builtin_store8(code, cpos+1, 139);
            __builtin_store8(code, cpos+2, 69); __builtin_store8(code, cpos+3, off % 256);
            return 4;
        }
    }
    // mov r10, [rbp+N]
    if __builtin_str_len(t) > 19 {
        if __builtin_str_eq(__builtin_str_sub(t, 0, 17), "    mov r10, [rbp") != 0 {
            off_str := __builtin_str_sub(t, 17, __builtin_str_len(t) - 18);
            off := __builtin_str_to_int(off_str);
            __builtin_store8(code, cpos, 76); __builtin_store8(code, cpos+1, 139);
            __builtin_store8(code, cpos+2, 85); __builtin_store8(code, cpos+3, off % 256);
            return 4;
        }
    }
    // mov r11, [rbp+N]
    if __builtin_str_len(t) > 19 {
        if __builtin_str_eq(__builtin_str_sub(t, 0, 17), "    mov r11, [rbp") != 0 {
            off_str := __builtin_str_sub(t, 17, __builtin_str_len(t) - 18);
            off := __builtin_str_to_int(off_str);
            __builtin_store8(code, cpos, 76); __builtin_store8(code, cpos+1, 139);
            __builtin_store8(code, cpos+2, 93); __builtin_store8(code, cpos+3, off % 256);
            return 4;
        }
    }
    // mov r12, [rbp+N]
    if __builtin_str_len(t) > 19 {
        if __builtin_str_eq(__builtin_str_sub(t, 0, 17), "    mov r12, [rbp") != 0 {
            off_str := __builtin_str_sub(t, 17, __builtin_str_len(t) - 18);
            off := __builtin_str_to_int(off_str);
            __builtin_store8(code, cpos, 76); __builtin_store8(code, cpos+1, 139);
            __builtin_store8(code, cpos+2, 101); __builtin_store8(code, cpos+3, off % 256);
            return 4;
        }
    }
    // mov [rbp+N], r10
    if __builtin_str_len(t) > 18 {
        if __builtin_str_eq(__builtin_str_sub(t, 0, 12), "    mov [rbp") != 0 {
            // Extract r10/r11 from end
            rname := __builtin_str_get(t, __builtin_str_len(t) - 3);
            rn : ., mut = 10;
            if __builtin_str_eq(rname, "1") != 0 { rn = 11; }
            // Find offset: between [rbp and ]
            off_start : ., mut = 12;  // after "    mov [rbp"
            off_end : ., mut = off_start;
            plen := __builtin_str_len(t);
            loop { if off_end >= plen { break; } c := __builtin_str_get(t, off_end); if c == "]" { break; } off_end=off_end+1; }
            off_str := __builtin_str_sub(t, off_start, off_end - off_start);
            off := __builtin_str_to_int(off_str);
            if rn == 10 {
                __builtin_store8(code, cpos, 76); __builtin_store8(code, cpos+1, 137);
                __builtin_store8(code, cpos+2, 85); __builtin_store8(code, cpos+3, off % 256);
            } else {
                __builtin_store8(code, cpos, 76); __builtin_store8(code, cpos+1, 137);
                __builtin_store8(code, cpos+2, 93); __builtin_store8(code, cpos+3, off % 256);
            }
            return 4;
        }
    }
    // mov qword ptr [rbp+N], VAL
    if __builtin_str_len(t) > 24 {
        if __builtin_str_eq(__builtin_str_sub(t, 0, 22), "    mov qword ptr [rbp") != 0 {
            off_str : ., mut = ""; val_str : ., mut = ""; phase : ., mut = 0;
            pi : ., mut = 22; plen := __builtin_str_len(t);
            loop { if pi >= plen { break; } pc := __builtin_str_get(t, pi); if pc == "]" { phase=1; pi=pi+1; continue; } if phase==0 { off_str=off_str+pc; pi=pi+1; continue; } if phase==1 { if pc=="," { phase=2; pi=pi+1; continue; } } if phase==2 { if pc!=" " { val_str=val_str+pc; } pi=pi+1; } }
            off := __builtin_str_to_int(off_str); val := __builtin_str_to_int(val_str);
            __builtin_store8(code, cpos, 72); __builtin_store8(code, cpos+1, 199);
            __builtin_store8(code, cpos+2, 69); __builtin_store8(code, cpos+3, off % 256);
            w32(code, cpos+4, val)); return 8;
        }
    }
    // sub/add rsp, N
    if __builtin_str_len(t) > 13 {
        if __builtin_str_eq(__builtin_str_sub(t, 0, 13), "    sub rsp, ") != 0 {
            n := __builtin_str_to_int(__builtin_str_sub(t, 13, __builtin_str_len(t)-13));
            __builtin_store8(code, cpos, 72); __builtin_store8(code, cpos+1, 131);
            __builtin_store8(code, cpos+2, 236); __builtin_store8(code, cpos+3, n % 256); return 4;
        }
        if __builtin_str_eq(__builtin_str_sub(t, 0, 13), "    add rsp, ") != 0 {
            n := __builtin_str_to_int(__builtin_str_sub(t, 13, __builtin_str_len(t)-13));
            __builtin_store8(code, cpos, 72); __builtin_store8(code, cpos+1, 131);
            __builtin_store8(code, cpos+2, 196); __builtin_store8(code, cpos+3, n % 256); return 4;
        }
    }
    // mov edi, N
    if __builtin_str_len(t) > 12 {
        if __builtin_str_eq(__builtin_str_sub(t, 0, 13), "    mov edi, ") != 0 {
            n := __builtin_str_to_int(__builtin_str_sub(t, 12, __builtin_str_len(t)-12));
            __builtin_store8(code, cpos, 191); w32(code, cpos+1, n)); return 5;
        }
    }
    // jmp/je .Lxxx — extract label number from line, look up position
    tlen := __builtin_str_len(t);
    if tlen > 10 {
        // Check for "    jmp .L" or "    je  .L"
        pre := __builtin_str_sub(t, 0, 10);
        is_jmp : ., mut = 0;
        if __builtin_str_eq(pre, "    jmp .L") != 0 { is_jmp = 1; }
        if __builtin_str_eq(pre, "    je  .L") != 0 { is_jmp = 1; }
        if is_jmp != 0 {
            // Extract number from end of line (after .Lxxx)
            // Find the last digit before line end
            digit_end : ., mut = tlen - 1;
            loop {
                c := __builtin_str_get(t, digit_end);
                if c >= "0" && c <= "9" { digit_end = digit_end - 1; } else { break; }
            }
            num_str := __builtin_str_sub(t, digit_end + 1, tlen - digit_end - 1);
            ln := __builtin_str_to_int(num_str);
            target : ., mut = -1;
            if ln >= 0 && ln < g_label_count { target = g_label_poses[ln]; }
            off : ., mut = 0;
            if target >= 0 { off = target - (cpos + 2); }
            if __builtin_str_eq(__builtin_str_sub(t, 4, 3), "jmp") != 0 { __builtin_store8(code, cpos, 235); }
            else { __builtin_store8(code, cpos, 116); }
            __builtin_store8(code, cpos+1, off % 256);
            return 2;
        }
    }
    // mov [r10 + r11 * 8], r12
    if __builtin_str_len(t) > 26 {
        if __builtin_str_eq(__builtin_str_sub(t, 0, 26), "    mov [r10 + r11 * 8], r12") != 0 {
            __builtin_store8(code, cpos, 75); __builtin_store8(code, cpos+1, 137);
            __builtin_store8(code, cpos+2, 4); __builtin_store8(code, cpos+3, 216); return 4;
        }
        if __builtin_str_eq(__builtin_str_sub(t, 0, 26), "    mov r12, [r10 + r11 * 8]") != 0 {
            __builtin_store8(code, cpos, 75); __builtin_store8(code, cpos+1, 139);
            __builtin_store8(code, cpos+2, 4); __builtin_store8(code, cpos+3, 216); return 4;
        }
    }
    // mov [r10 + N], r11
    if __builtin_str_len(t) > 16 {
        if __builtin_str_eq(__builtin_str_sub(t, 0, 16), "    mov [r10 + ") != 0 {
            // Extract N and register
            rest := __builtin_str_sub(t, 16, __builtin_str_len(t)-16);
            off_str : ., mut = ""; rn : ., mut = 11; ph : ., mut = 0;
            ri : ., mut = 0; rlen := __builtin_str_len(rest);
            loop { if ri >= rlen { break; } rc := __builtin_str_get(rest, ri); if rc=="]" { break; } if rc=="," { ph=1; ri=ri+1; continue; } if ph==0 { off_str=off_str+rc; } if ph==1 { if rc=="r" && ri+2 < rlen { if __builtin_str_get(rest, ri+1)=="1" && __builtin_str_get(rest, ri+2)=="2" { rn=12; } break; } } ri=ri+1; }
            off := __builtin_str_to_int(off_str);
            if rn == 12 {
                __builtin_store8(code, cpos, 75); __builtin_store8(code, cpos+1, 137);
                __builtin_store8(code, cpos+2, 66); __builtin_store8(code, cpos+3, off % 256); return 4;
            }
            __builtin_store8(code, cpos, 75); __builtin_store8(code, cpos+1, 137);
            __builtin_store8(code, cpos+2, 90); __builtin_store8(code, cpos+3, off % 256); return 4;
        }
    }
    // mov r11, [r10 + N]
    if __builtin_str_len(t) > 19 {
        if __builtin_str_eq(__builtin_str_sub(t, 0, 19), "    mov r11, [r10 + ") != 0 {
            n_str := __builtin_str_sub(t, 19, __builtin_str_len(t)-20);
            n := __builtin_str_to_int(n_str);
            __builtin_store8(code, cpos, 75); __builtin_store8(code, cpos+1, 139);
            __builtin_store8(code, cpos+2, 90); __builtin_store8(code, cpos+3, n % 256); return 4;
        }
    }
    // lea r10, [rbp+N]
    if __builtin_str_len(t) > 18 {
        if __builtin_str_eq(__builtin_str_sub(t, 0, 17), "    lea r10, [rbp") != 0 {
            off_str := __builtin_str_sub(t, 18, __builtin_str_len(t)-19);
            off := __builtin_str_to_int(off_str);
            __builtin_store8(code, cpos, 76); __builtin_store8(code, cpos+1, 141);
            __builtin_store8(code, cpos+2, 85); __builtin_store8(code, cpos+3, off % 256); return 4;
        }
    }
    // call __builtin_alloc (placeholder)
    if __builtin_str_len(t) > 9 {
        if __builtin_str_eq(__builtin_str_sub(t, 0, 9), "    call ") != 0 {
            __builtin_store8(code, cpos, 144); return 1; // NOP placeholder
        }
    }

    // Fallback: NOP
    __builtin_store8(code, cpos, 144);
    return 1;
}


fn asm_to_bytes(asm_text: string) -> string {
    tal := __builtin_str_len(asm_text);
    // Pass 1: find labels and measure sizes
    total_size : ., mut = 0;
    g_label_count = 0;
    li : ., mut = 0;
    loop {
        if li >= tal { break; }
        lstart := li;
        loop { if li >= tal { break; } if __builtin_str_get(asm_text, li) == "\n" { break; } li = li + 1; }
        if li >= tal && lstart < tal { li = tal; }
        line := __builtin_str_sub(asm_text, lstart, li - lstart);
        if is_label_line(line) != 0 {
            // Record any .Lxxx: label — extract number from name
            // ".L1:" → number = 1, ".Lret0:" → parse number after "ret"
            llen := __builtin_str_len(line);
            if llen > 3 {
                // Find the number at the end (before :)
                digit_start : ., mut = llen - 2;  // position before ':'
                loop {
                    if digit_start < 2 { break; }
                    c := __builtin_str_get(line, digit_start - 1);
                    if c >= "0" && c <= "9" { digit_start = digit_start - 1; }
                    else { break; }
                }
                num_str := __builtin_str_sub(line, digit_start, llen - 1 - digit_start);
                label_num := __builtin_str_to_int(num_str);
                if label_num >= 0 && label_num < 32 { g_label_poses[label_num] = total_size; if label_num + 1 > g_label_count { g_label_count = label_num + 1; } }
            }
        } else {
            if skip_dir(line) == 0 { total_size = total_size + measure_instr(line); }
        }
        li = li + 1;
    }

    // Allocate code buffer
    buf_size : ., mut = total_size + 256;
    code := __builtin_alloc(buf_size);
    // Zero it
    zi : ., mut = 0; loop { if zi >= buf_size { break; } __builtin_store8(code, zi, 0); zi = zi + 1; }

    // Pass 2: encode
    cpos : ., mut = 0;
    li = 0;
    loop {
        if li >= tal { break; }
        lstart := li;
        loop { if li >= tal { break; } if __builtin_str_get(asm_text, li) == "\n" { break; } li = li + 1; }
        if li >= tal && lstart < tal { li = tal; }
        line := __builtin_str_sub(asm_text, lstart, li - lstart);
        if is_label_line(line) == 0 {
            if skip_dir(line) == 0 { cpos = cpos + encode_instr(line, code, cpos); }
        }
        li = li + 1;
    }

    // Build result: _start (14 bytes) + generated code
    total := cpos + 14;
    g_asm_code_size = total;
    res_buf := __builtin_alloc(total + 1);

    // Write _start directly into result:
    //  call main (relative offset +9)
    //  mov edi, eax
    //  mov eax, 60 (sys_exit)
    //  syscall
    __builtin_store8(res_buf, 0, 232);
    __builtin_store8(res_buf, 1, 9);
    __builtin_store8(res_buf, 2, 0);
    __builtin_store8(res_buf, 3, 0);
    __builtin_store8(res_buf, 4, 0);
    __builtin_store8(res_buf, 5, 137);
    __builtin_store8(res_buf, 6, 199);
    __builtin_store8(res_buf, 7, 184);
    __builtin_store8(res_buf, 8, 60);
    __builtin_store8(res_buf, 9, 0);
    __builtin_store8(res_buf, 10, 0);
    __builtin_store8(res_buf, 11, 0);
    __builtin_store8(res_buf, 12, 15);
    __builtin_store8(res_buf, 13, 5);

    // Copy generated code after _start
    ri : ., mut = 0; loop { if ri >= cpos { break; } __builtin_store8(res_buf, ri + 14, __builtin_load8(code, ri); ri = ri + 1); }

    __builtin_store8(res_buf, total, 0);

    return res_buf;
}
