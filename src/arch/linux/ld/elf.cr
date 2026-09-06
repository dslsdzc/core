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

// Avoid the name r16: Intel syntax parses `call r16` as a register operand.
fn read_u16(buf: string, pos: int) -> int { return bu8(buf,pos) + bu8(buf,pos+1)*256; }

TEXT_BASE : int = 4194304;  // 0x400000 - base address of code segment

fn w8_signed(buf: string, pos: int, val: int) {
    w32(buf, pos, val);
}

// Emit arena-aware dual-path allocator function body
// Checks g_current_arena: if >=0 uses arena bump, otherwise global bump.
// Returns bytes written.
fn emit_alloc_body(buf: string, pos: int, bss_va: int, globals_size: int) -> int {
    // When arena globals aren't registered (e.g. non-static builds), emit the
    // original simple bump allocator to avoid relying on unpatched rip-relatives.
    if gv_current_arena < 0 { return emit_alloc_body_simple(buf, pos, bss_va, globals_size); }

    cp := 0;
    fva := TEXT_BASE + pos;

    // ── Part 0: 64MB sanity check (12 bytes) ──
    // cmp rdi, 67108864
    w8(buf, pos+cp, 72); w8(buf, pos+cp+1, 129); w8(buf, pos+cp+2, 255);
    e2_w32(buf, pos+cp+3, 67108864); cp = cp + 7;
    // jbe +3
    w8(buf, pos+cp, 118); w8(buf, pos+cp+1, 3); cp = cp + 2;
    // xor eax, eax; ret
    w8(buf, pos+cp, 49); w8(buf, pos+cp+1, 192); cp = cp + 2;
    w8(buf, pos+cp, 195); cp = cp + 1;

    // ── Part 1: Save original size + check arena (53 bytes) ──
    // mov r9, rdi — 49 89 F9
    w8(buf, pos+cp, 73); w8(buf, pos+cp+1, 137); w8(buf, pos+cp+2, 249); cp = cp + 3;
    // lea r10, [rip + g_current_arena] — 4C 8D 15 (dest r10, not r8!)
    rip_pos_ca := pos + cp + 3;
    w8(buf, pos+cp, 76); w8(buf, pos+cp+1, 141); w8(buf, pos+cp+2, 21);
    e2_w32(buf, pos+cp+3, 0); cp = cp + 7;
    grow_rip_patch(g_x86_rip_patch_count + 1);
    w64(g_x86_rip_patch_pos, g_x86_rip_patch_count * 8, rip_pos_ca);
    w64(g_x86_rip_patch_globals, g_x86_rip_patch_count * 8, gv_current_arena);
    g_x86_rip_patch_count = g_x86_rip_patch_count + 1;
    // mov r10, [r10] — 4D 8B 12 (modrm 0x12: reg=010+R -> r10, rm=010+B -> [r10];
    // old 0x10 had rm=100 which consumed a SIB byte and desynced the stream)
    w8(buf, pos+cp, 77); w8(buf, pos+cp+1, 139); w8(buf, pos+cp+2, 18); cp = cp + 3;
    // test r10, r10 — 4D 85 D2
    w8(buf, pos+cp, 77); w8(buf, pos+cp+1, 133); w8(buf, pos+cp+2, 210); cp = cp + 3;
    // jl .Lglobal (no active arena → global bump path) — 0F 8C rel32, patched at Part 8
    g_alloc_gl_jmp_pos = pos + cp;
    w8(buf, pos+cp, 15); w8(buf, pos+cp+1, 140); e2_w32(buf, pos+cp+2, 0); cp = cp + 6;

    // ── Compute chunk_start BEFORE loading the cursors pointer ──
    // mul r10 clobbers rdx:rax — if rdx already held the cursors pointer
    // (loaded below), the commit at Part 5 would write to garbage. Order matters.
    // lea r11, [rip + g_arena_pool_data] — e2_lrb, rip_patch
    rip_pos3 := pos + cp + 3;
    cp = cp + e2_lrb(buf, pos + cp, 0);
    grow_rip_patch(g_x86_rip_patch_count + 1);
    w64(g_x86_rip_patch_pos, g_x86_rip_patch_count * 8, rip_pos3);
    w64(g_x86_rip_patch_globals, g_x86_rip_patch_count * 8, gv_arena_pool_data);
    g_x86_rip_patch_count = g_x86_rip_patch_count + 1;
    // mov r11, [r11] — 4D 8B 1B
    w8(buf, pos+cp, 77); w8(buf, pos+cp+1, 139); w8(buf, pos+cp+2, 27); cp = cp + 3;
    // lea rax, [rip + g_arena_max_size] — 48 8D 05 xx xx xx xx, rip_patch
    rip_pos4 := pos + cp + 3;
    w8(buf, pos+cp, 72); w8(buf, pos+cp+1, 141); w8(buf, pos+cp+2, 5);
    e2_w32(buf, pos+cp+3, 0); cp = cp + 7;
    grow_rip_patch(g_x86_rip_patch_count + 1);
    w64(g_x86_rip_patch_pos, g_x86_rip_patch_count * 8, rip_pos4);
    w64(g_x86_rip_patch_globals, g_x86_rip_patch_count * 8, gv_arena_max_size);
    g_x86_rip_patch_count = g_x86_rip_patch_count + 1;
    // mov rax, [rax] — 48 8B 00 (load g_arena_max_size value)
    w8(buf, pos+cp, 72); w8(buf, pos+cp+1, 139); w8(buf, pos+cp+2, 0); cp = cp + 3;
    // mul r10 — 49 F7 E2 (rax = g_arena_max_size * ai)
    w8(buf, pos+cp, 73); w8(buf, pos+cp+1, 247); w8(buf, pos+cp+2, 226); cp = cp + 3;
    // add r11, rax — 49 01 C3 (r11 = pool_base + offset = chunk_start)
    w8(buf, pos+cp, 73); w8(buf, pos+cp+1, 1); w8(buf, pos+cp+2, 195); cp = cp + 3;

    // ── Load cursors + sizes (rdx must not be clobbered after this) ──
    // NB: r11 MUST keep chunk_start (pool_data + max_size*ai) — Part 5b/6
    // depend on it. Load the cursors array into rdx directly.
    // lea rdx, [rip + g_arena_cursors] — 48 8D 15, rip_patch
    rip_pos1 := pos + cp + 3;
    w8(buf, pos+cp, 72); w8(buf, pos+cp+1, 141); w8(buf, pos+cp+2, 21); e2_w32(buf, pos+cp+3, 0); cp = cp + 7;
    grow_rip_patch(g_x86_rip_patch_count + 1);
    w64(g_x86_rip_patch_pos, g_x86_rip_patch_count * 8, rip_pos1);
    w64(g_x86_rip_patch_globals, g_x86_rip_patch_count * 8, gv_arena_cursors);
    g_x86_rip_patch_count = g_x86_rip_patch_count + 1;
    // mov rdx, [rdx] — 48 8B 12
    w8(buf, pos+cp, 72); w8(buf, pos+cp+1, 139); w8(buf, pos+cp+2, 18); cp = cp + 3;
    // mov rcx, [rdx + r10*8] — 4A 8B 0C D2 (SIB: scale=3, index=r10, base=rdx)
    w8(buf, pos+cp, 74); w8(buf, pos+cp+1, 139); w8(buf, pos+cp+2, 12); w8(buf, pos+cp+3, 210); cp = cp + 4;
    // lea rsi, [rip + g_arena_sizes] — preserve r11 as chunk_start
    rip_pos2 := pos + cp + 3;
    w8(buf, pos+cp, 72); w8(buf, pos+cp+1, 141); w8(buf, pos+cp+2, 53); e2_w32(buf, pos+cp+3, 0); cp = cp + 7;
    grow_rip_patch(g_x86_rip_patch_count + 1);
    w64(g_x86_rip_patch_pos, g_x86_rip_patch_count * 8, rip_pos2);
    w64(g_x86_rip_patch_globals, g_x86_rip_patch_count * 8, gv_arena_sizes);
    g_x86_rip_patch_count = g_x86_rip_patch_count + 1;
    // mov rsi, [rsi] — 48 8B 36
    w8(buf, pos+cp, 72); w8(buf, pos+cp+1, 139); w8(buf, pos+cp+2, 54); cp = cp + 3;
    // mov r8, [rsi + r10*8] — 4E 8B 04 D6
    w8(buf, pos+cp, 78); w8(buf, pos+cp+1, 139); w8(buf, pos+cp+2, 4); w8(buf, pos+cp+3, 214); cp = cp + 4;

    // ── Part 4: Align size + bump check (22 bytes) ──
    // mov rdi, r9 — 49 8B F9 (restore original size for alignment)
    w8(buf, pos+cp, 73); w8(buf, pos+cp+1, 139); w8(buf, pos+cp+2, 249); cp = cp + 3;
    // add rdi, 15 — 48 83 C7 0F
    w8(buf, pos+cp, 72); w8(buf, pos+cp+1, 131); w8(buf, pos+cp+2, 199); w8(buf, pos+cp+3, 15); cp = cp + 4;
    // and rdi, -8 — 48 83 E7 F8
    w8(buf, pos+cp, 72); w8(buf, pos+cp+1, 131); w8(buf, pos+cp+2, 231); w8(buf, pos+cp+3, 248); cp = cp + 4;
    // mov rax, rcx — 48 89 C8 (rax = old_cursor)
    w8(buf, pos+cp, 72); w8(buf, pos+cp+1, 137); w8(buf, pos+cp+2, 200); cp = cp + 3;
    // add rcx, rdi — 48 01 F9 (rcx = new_cursor)
    w8(buf, pos+cp, 72); w8(buf, pos+cp+1, 1); w8(buf, pos+cp+2, 249); cp = cp + 3;
    // cmp rcx, r8 — 4C 39 C1
    w8(buf, pos+cp, 76); w8(buf, pos+cp+1, 57); w8(buf, pos+cp+2, 193); cp = cp + 3;
    // ja .Lchain — 77 22 (rel8=34)
    w8(buf, pos+cp, 119); w8(buf, pos+cp+1, 34); cp = cp + 2;

    // ── Part 5: Commit cursor update (4 bytes) ──
    // mov [rdx + r10*8], rcx — 4A 89 0C D2
    w8(buf, pos+cp, 74); w8(buf, pos+cp+1, 137); w8(buf, pos+cp+2, 12); w8(buf, pos+cp+3, 210); cp = cp + 4;

    // ── Part 5b: Zero-init newly allocated arena block (18 bytes) ──
    // Zero only the newly allocated data bytes.
    // rax=old_cursor, r11=chunk_start, rdx=cursors_ptr (no longer needed)
    // mov rdx, rax (save old_cursor) — 48 89 C2
    w8(buf, pos+cp, 72); w8(buf, pos+cp+1, 137); w8(buf, pos+cp+2, 194); cp = cp + 3;
    // lea rdi, [r11 + rax + 8] — allocation data after its header
    w8(buf, pos+cp, 73); w8(buf, pos+cp+1, 141); w8(buf, pos+cp+2, 124); w8(buf, pos+cp+3, 3); w8(buf, pos+cp+4, 8); cp = cp + 5;
    // mov rcx, r9 (requested data size) — 4C 89 C9
    w8(buf, pos+cp, 76); w8(buf, pos+cp+1, 137); w8(buf, pos+cp+2, 201); cp = cp + 3;
    // xor eax, eax — 31 C0
    w8(buf, pos+cp, 49); w8(buf, pos+cp+1, 192); cp = cp + 2;
    // cld — FC
    w8(buf, pos+cp, 252); cp = cp + 1;
    // rep stosb — F3 AA
    w8(buf, pos+cp, 243); w8(buf, pos+cp+1, 170); cp = cp + 2;
    // mov rax, rdx (restore old_cursor) — 48 89 D0
    w8(buf, pos+cp, 72); w8(buf, pos+cp+1, 137); w8(buf, pos+cp+2, 208); cp = cp + 3;

    // ── Part 6: Return arena pointer (11 bytes) ──
    // add rax, r11 — 4C 01 D8 (rax = chunk_start + old_cursor = data ptr before header)
    w8(buf, pos+cp, 76); w8(buf, pos+cp+1, 1); w8(buf, pos+cp+2, 216); cp = cp + 3;
    // mov [rax], r9 — 4C 89 08 (store hidden length header)
    w8(buf, pos+cp, 76); w8(buf, pos+cp+1, 137); w8(buf, pos+cp+2, 8); cp = cp + 3;
    // lea rax, [rax + 8] — 48 8D 40 08
    w8(buf, pos+cp, 72); w8(buf, pos+cp+1, 141); w8(buf, pos+cp+2, 64); w8(buf, pos+cp+3, 8); cp = cp + 4;
    // ret
    w8(buf, pos+cp, 195); cp = cp + 1;

    // ── Part 7: .Lchain — arena OOM → chain expand + mark full (41 bytes) ──
    // lea r8, [rip + g_current_arena] — 4C 8D 05 xx xx xx xx, rip_patch #6
    rip_pos5 := pos + cp + 3;
    w8(buf, pos+cp, 76); w8(buf, pos+cp+1, 141); w8(buf, pos+cp+2, 5);
    e2_w32(buf, pos+cp+3, 0); cp = cp + 7;
    grow_rip_patch(g_x86_rip_patch_count + 1);
    w64(g_x86_rip_patch_pos, g_x86_rip_patch_count * 8, rip_pos5);
    w64(g_x86_rip_patch_globals, g_x86_rip_patch_count * 8, gv_current_arena);
    g_x86_rip_patch_count = g_x86_rip_patch_count + 1;
    // mov qword [r8], -1 — 49 C7 00 FF FF FF FF (set g_current_arena = -1;
    // REX.W+B — a 32-bit store would leave the slot = 0x00000000ffffffff,
    // which is positive and re-enters the arena path with a garbage index)
    w8(buf, pos+cp, 73); w8(buf, pos+cp+1, 199); w8(buf, pos+cp+2, 0);
    e2_w32(buf, pos+cp+3, -1); cp = cp + 7;

    // ── Bug 2 fix: Advance arena cursor to limit (mark full) ──
    // rdx = cursors array pointer (from Part 2), r10 = arena index (from Part 1)
    // Load sizes[ai] again (r8 was overwritten by g_current_arena LEA above)
    // lea rsi, [rip + g_arena_sizes] — 48 8D 35 xx xx xx xx, rip_patch #8
    rip_pos_sizes := pos + cp + 3;
    w8(buf, pos+cp, 72); w8(buf, pos+cp+1, 141); w8(buf, pos+cp+2, 53);
    e2_w32(buf, pos+cp+3, 0); cp = cp + 7;
    grow_rip_patch(g_x86_rip_patch_count + 1);
    w64(g_x86_rip_patch_pos, g_x86_rip_patch_count * 8, rip_pos_sizes);
    w64(g_x86_rip_patch_globals, g_x86_rip_patch_count * 8, gv_arena_sizes);
    g_x86_rip_patch_count = g_x86_rip_patch_count + 1;
    // mov rsi, [rsi] — 48 8B 36 (deref to get sizes array pointer)
    w8(buf, pos+cp, 72); w8(buf, pos+cp+1, 139); w8(buf, pos+cp+2, 54); cp = cp + 3;
    // mov r8, [rsi + r10*8] — 4E 8B 04 D6 (r8 = sizes[ai] = limit)
    w8(buf, pos+cp, 78); w8(buf, pos+cp+1, 139); w8(buf, pos+cp+2, 4); w8(buf, pos+cp+3, 214); cp = cp + 4;
    // mov [rdx + r10*8], r8 — 4E 89 04 D2 (cursors[ai] = limit, mark full)
    w8(buf, pos+cp, 78); w8(buf, pos+cp+1, 137); w8(buf, pos+cp+2, 4); w8(buf, pos+cp+3, 210); cp = cp + 4;
    // Set r10d = -1 to skip arena restore at .Lglobal's end — 41 BA FF FF FF FF
    w8(buf, pos+cp, 65); w8(buf, pos+cp+1, 186); e2_w32(buf, pos+cp+2, -1); cp = cp + 6;

    // mov rdi, r9 — 49 8B F9 (restore original size for global path alignment)
    w8(buf, pos+cp, 73); w8(buf, pos+cp+1, 139); w8(buf, pos+cp+2, 249); cp = cp + 3;

    // ── Part 8: .Lglobal — global bump alloc path + arena restore (84 bytes) ──
    // Patch Part 1's jl .Lglobal to here
    if g_alloc_gl_jmp_pos >= 0 {
        rel_gl := (pos + cp) - (g_alloc_gl_jmp_pos + 6);
        w32(buf, g_alloc_gl_jmp_pos + 2, rel_gl);
        g_alloc_gl_jmp_pos = -1;
    }
    // add rdi, 15 — 48 83 C7 0F (align)
    w8(buf, pos+cp, 72); w8(buf, pos+cp+1, 131); w8(buf, pos+cp+2, 199); w8(buf, pos+cp+3, 15); cp = cp + 4;
    // and rdi, -8 — 48 83 E7 F8
    w8(buf, pos+cp, 72); w8(buf, pos+cp+1, 131); w8(buf, pos+cp+2, 231); w8(buf, pos+cp+3, 248); cp = cp + 4;
    // mov r11, [rip + g_heap_ptr] — load via rip_patch
    if gv_heap_ptr >= 0 {
        rip_hp0 := pos + cp + 3;
        w8(buf, pos+cp, 76); w8(buf, pos+cp+1, 139); w8(buf, pos+cp+2, 29); e2_w32(buf, pos+cp+3, 0); cp = cp + 7;
        grow_rip_patch(g_x86_rip_patch_count + 1);
        w64(g_x86_rip_patch_pos, g_x86_rip_patch_count * 8, rip_hp0);
        w64(g_x86_rip_patch_globals, g_x86_rip_patch_count * 8, gv_heap_ptr);
        g_x86_rip_patch_count = g_x86_rip_patch_count + 1;
    } else {
        rel0 := bss_va - (fva + cp + 7);
        w8(buf, pos+cp, 76); w8(buf, pos+cp+1, 139); w8(buf, pos+cp+2, 29); w8_signed(buf, pos+cp+3, rel0); cp = cp + 7;
    }
    // test r11, r11 — 4D 85 DB
    w8(buf, pos+cp, 77); w8(buf, pos+cp+1, 133); w8(buf, pos+cp+2, 219); cp = cp + 3;
    // jne +14 (skip init if already set) — 75 0E
    w8(buf, pos+cp, 117); w8(buf, pos+cp+1, 14); cp = cp + 2;
    // lea r11, [rip + heap_start] (after globals)
    // BSS globals area: starts at rip_patch bss_va+16; globals_size covers all slots
    heap_start_va : ., mut = bss_va + 16 + globals_size;
    rel1 := heap_start_va - (fva + cp + 7);
    w8(buf, pos+cp, 76); w8(buf, pos+cp+1, 141); w8(buf, pos+cp+2, 29); w8_signed(buf, pos+cp+3, rel1); cp = cp + 7;
    // mov [rip + g_heap_ptr], r11 — store via rip_patch
    if gv_heap_ptr >= 0 {
        rip_hp_s1 := pos + cp + 3;
        w8(buf, pos+cp, 76); w8(buf, pos+cp+1, 137); w8(buf, pos+cp+2, 29); e2_w32(buf, pos+cp+3, 0); cp = cp + 7;
        grow_rip_patch(g_x86_rip_patch_count + 1);
        w64(g_x86_rip_patch_pos, g_x86_rip_patch_count * 8, rip_hp_s1);
        w64(g_x86_rip_patch_globals, g_x86_rip_patch_count * 8, gv_heap_ptr);
        g_x86_rip_patch_count = g_x86_rip_patch_count + 1;
    } else {
        rel2 := bss_va - (fva + cp + 7);
        w8(buf, pos+cp, 76); w8(buf, pos+cp+1, 137); w8(buf, pos+cp+2, 29); w8_signed(buf, pos+cp+3, rel2); cp = cp + 7;
    }
    // ── OOM bounds check: .Lretry block ──
    // Save original heap_ptr, check against heap_end, call heap_expand if OOM.
    // retry_cp must start BEFORE mov r8, r11: heap_expand clobbers r8
    // (r8d = fd = -1), so the retry has to re-save the (possibly new) heap_ptr.
    // mov r8, r11 -- 4D 89 D8 (save original heap_ptr)
    retry_cp := cp;
    w8(buf, pos+cp, 77); w8(buf, pos+cp+1, 137); w8(buf, pos+cp+2, 216); cp = cp + 3;
    // lea rdx, [r11 + rdi] -- 4A 8D 14 1F (compute new end = r11 + rdi)
    // REX 0x4A = W=1, X=1 (index 011 -> r11), B=0 (base 111 -> rdi); modrm reg=010 (rdx).
    w8(buf, pos+cp, 74); w8(buf, pos+cp+1, 141); w8(buf, pos+cp+2, 20); w8(buf, pos+cp+3, 31); cp = cp + 4;
    // lea rcx, [rip + g_heap_end] — rip_patch for gv_heap_end
    if gv_heap_end >= 0 {
        rip_he := pos + cp + 3;
        w8(buf, pos+cp, 72); w8(buf, pos+cp+1, 141); w8(buf, pos+cp+2, 13); e2_w32(buf, pos+cp+3, 0); cp = cp + 7;
        grow_rip_patch(g_x86_rip_patch_count + 1);
        w64(g_x86_rip_patch_pos, g_x86_rip_patch_count * 8, rip_he);
        w64(g_x86_rip_patch_globals, g_x86_rip_patch_count * 8, gv_heap_end);
        g_x86_rip_patch_count = g_x86_rip_patch_count + 1;
    } else {
        heap_end_va : ., mut = bss_va + 8;
        rel_he := heap_end_va - (fva + cp + 7);
        w8(buf, pos+cp, 72); w8(buf, pos+cp+1, 141); w8(buf, pos+cp+2, 13); w8_signed(buf, pos+cp+3, rel_he); cp = cp + 7;
    }
    // cmp rdx, [rcx] -- 48 3B 11
    w8(buf, pos+cp, 72); w8(buf, pos+cp+1, 59); w8(buf, pos+cp+2, 17); cp = cp + 3;
    // jbe +14 (skip call+reload+jmp if within bounds)
    w8(buf, pos+cp, 118); w8(buf, pos+cp+1, 14); cp = cp + 2;
    // call heap_expand -- E8 xx xx xx xx (patched in elf_gen after heap_expand emitted)
    g_heap_expand_call_pos = pos + cp;
    e2_w8(buf, pos+cp, 232); e2_w32(buf, pos+cp+1, 0); cp = cp + 5;
    // mov r11, [rip + g_heap_ptr] — reload via rip_patch after heap_expand
    if gv_heap_ptr >= 0 {
        rip_hp_rl := pos + cp + 3;
        w8(buf, pos+cp, 76); w8(buf, pos+cp+1, 139); w8(buf, pos+cp+2, 29); e2_w32(buf, pos+cp+3, 0); cp = cp + 7;
        grow_rip_patch(g_x86_rip_patch_count + 1);
        w64(g_x86_rip_patch_pos, g_x86_rip_patch_count * 8, rip_hp_rl);
        w64(g_x86_rip_patch_globals, g_x86_rip_patch_count * 8, gv_heap_ptr);
        g_x86_rip_patch_count = g_x86_rip_patch_count + 1;
    } else {
        rel_hr := bss_va - (fva + cp + 7);
        w8(buf, pos+cp, 76); w8(buf, pos+cp+1, 139); w8(buf, pos+cp+2, 29); w8_signed(buf, pos+cp+3, rel_hr); cp = cp + 7;
    }
    // jmp .Lretry -- EB xx (short backwards jump to mov r8, r11)
    jmp_off_val := retry_cp - (cp + 2);
    w8(buf, pos+cp, 235); w8(buf, pos+cp+1, jmp_off_val % 256); cp = cp + 2;
    // add r11, rdi -- 49 01 FB (bump r11, only reached when within bounds)
    w8(buf, pos+cp, 73); w8(buf, pos+cp+1, 1); w8(buf, pos+cp+2, 251); cp = cp + 3;
    // mov [rip + g_heap_ptr], r11 — store via rip_patch
    if gv_heap_ptr >= 0 {
        rip_hp_s2 := pos + cp + 3;
        w8(buf, pos+cp, 76); w8(buf, pos+cp+1, 137); w8(buf, pos+cp+2, 29); e2_w32(buf, pos+cp+3, 0); cp = cp + 7;
        grow_rip_patch(g_x86_rip_patch_count + 1);
        w64(g_x86_rip_patch_pos, g_x86_rip_patch_count * 8, rip_hp_s2);
        w64(g_x86_rip_patch_globals, g_x86_rip_patch_count * 8, gv_heap_ptr);
        g_x86_rip_patch_count = g_x86_rip_patch_count + 1;
    } else {
        rel3 := bss_va - (fva + cp + 7);
        w8(buf, pos+cp, 76); w8(buf, pos+cp+1, 137); w8(buf, pos+cp+2, 29); w8_signed(buf, pos+cp+3, rel3); cp = cp + 7;
    }
    // mov rdi, r8 — 4C 89 C7
    w8(buf, pos+cp, 76); w8(buf, pos+cp+1, 137); w8(buf, pos+cp+2, 199); cp = cp + 3;
    // mov rcx, r11 — 4C 89 D9
    w8(buf, pos+cp, 76); w8(buf, pos+cp+1, 137); w8(buf, pos+cp+2, 217); cp = cp + 3;
    // sub rcx, rdi — 48 29 F9
    w8(buf, pos+cp, 72); w8(buf, pos+cp+1, 41); w8(buf, pos+cp+2, 249); cp = cp + 3;
    // xor eax, eax — 31 C0
    w8(buf, pos+cp, 49); w8(buf, pos+cp+1, 192); cp = cp + 2;
    // cld — FC
    w8(buf, pos+cp, 252); cp = cp + 1;
    // rep stosb — F3 AA
    w8(buf, pos+cp, 243); w8(buf, pos+cp+1, 170); cp = cp + 2;
    // mov [r8], r9 — 4D 89 08 (store header)
    w8(buf, pos+cp, 77); w8(buf, pos+cp+1, 137); w8(buf, pos+cp+2, 8); cp = cp + 3;
    // lea rax, [r8+8] — 49 8D 40 08
    w8(buf, pos+cp, 73); w8(buf, pos+cp+1, 141); w8(buf, pos+cp+2, 64); w8(buf, pos+cp+3, 8); cp = cp + 4;
    // ── Arena restore (before ret) ──
    // test r10d, r10d — 45 85 D2 (was arena active? r10d ≥ 0 at entry)
    w8(buf, pos+cp, 69); w8(buf, pos+cp+1, 133); w8(buf, pos+cp+2, 210); cp = cp + 3;
    // js .Lret (skip restore if r10d < 0, i.e. normal global alloc) — 78 0A
    w8(buf, pos+cp, 120); w8(buf, pos+cp+1, 10); cp = cp + 2;
    // lea r8, [rip + g_current_arena] — 4C 8D 05 xx xx xx xx, rip_patch #7
    rip_pos6 := pos + cp + 3;
    w8(buf, pos+cp, 76); w8(buf, pos+cp+1, 141); w8(buf, pos+cp+2, 5);
    e2_w32(buf, pos+cp+3, 0); cp = cp + 7;
    grow_rip_patch(g_x86_rip_patch_count + 1);
    w64(g_x86_rip_patch_pos, g_x86_rip_patch_count * 8, rip_pos6);
    w64(g_x86_rip_patch_globals, g_x86_rip_patch_count * 8, gv_current_arena);
    g_x86_rip_patch_count = g_x86_rip_patch_count + 1;
    // mov [r8], r10d — 45 89 10 (restore arena index: r8 = g_current_arena addr)
    // objdump 验证：45 89 10 = mov %r10d,(%r8) ✓；44 89 00 = mov %r8d,(%rax) ✗
    w8(buf, pos+cp, 69); w8(buf, pos+cp+1, 137); w8(buf, pos+cp+2, 16); cp = cp + 3;
    // ret
    w8(buf, pos+cp, 195); cp = cp + 1;

    return cp;
}

// ── Simple bump allocator (no arena) — used when gv_current_arena < 0 ──
// Original 84-byte alloc body: no arena check, no rip_patches for arena globals.
// This avoids relying on unpatched RIP-relative addresses for g_current_arena
// when the variable isn't registered in the output binary (non-static builds).
fn emit_alloc_body_simple(buf: string, pos: int, bss_va: int, globals_size: int) -> int {
    cp := 0;
    fva := TEXT_BASE + pos;

    // 64MB sanity check
    w8(buf, pos+cp, 72); w8(buf, pos+cp+1, 129); w8(buf, pos+cp+2, 255);
    e2_w32(buf, pos+cp+3, 67108864); cp = cp + 7;
    w8(buf, pos+cp, 118); w8(buf, pos+cp+1, 3); cp = cp + 2;
    w8(buf, pos+cp, 49); w8(buf, pos+cp+1, 192); cp = cp + 2;
    w8(buf, pos+cp, 195); cp = cp + 1;

    // mov r9, rdi (save size for header)
    w8(buf, pos+cp, 73); w8(buf, pos+cp+1, 137); w8(buf, pos+cp+2, 249); cp = cp + 3;

    // add rdi, 15; and rdi, -8
    w8(buf, pos+cp, 72); w8(buf, pos+cp+1, 131); w8(buf, pos+cp+2, 199); w8(buf, pos+cp+3, 15); cp = cp + 4;
    w8(buf, pos+cp, 72); w8(buf, pos+cp+1, 131); w8(buf, pos+cp+2, 231); w8(buf, pos+cp+3, 248); cp = cp + 4;

    // mov r11, [rip + g_heap_ptr] — load via rip_patch
    if gv_heap_ptr >= 0 {
        rip_hp_l := pos + cp + 3;
        w8(buf, pos+cp, 76); w8(buf, pos+cp+1, 139); w8(buf, pos+cp+2, 29); e2_w32(buf, pos+cp+3, 0); cp = cp + 7;
        grow_rip_patch(g_x86_rip_patch_count + 1);
        w64(g_x86_rip_patch_pos, g_x86_rip_patch_count * 8, rip_hp_l);
        w64(g_x86_rip_patch_globals, g_x86_rip_patch_count * 8, gv_heap_ptr);
        g_x86_rip_patch_count = g_x86_rip_patch_count + 1;
    } else {
        rel0 := bss_va - (fva + cp + 7);
        w8(buf, pos+cp, 76); w8(buf, pos+cp+1, 139); w8(buf, pos+cp+2, 29); w8_signed(buf, pos+cp+3, rel0); cp = cp + 7;
    }
    // test r11, r11; jne +14 (skip lazy init)
    w8(buf, pos+cp, 77); w8(buf, pos+cp+1, 133); w8(buf, pos+cp+2, 219); cp = cp + 3;
    w8(buf, pos+cp, 117); w8(buf, pos+cp+1, 14); cp = cp + 2;

    // lea r11, [rip + heap_start]
    heap_start_va : ., mut = bss_va + 16 + globals_size;
    rel1 := heap_start_va - (fva + cp + 7);
    w8(buf, pos+cp, 76); w8(buf, pos+cp+1, 141); w8(buf, pos+cp+2, 29); w8_signed(buf, pos+cp+3, rel1); cp = cp + 7;
    // mov [rip + g_heap_ptr], r11 — store via rip_patch
    if gv_heap_ptr >= 0 {
        rip_hp_s1 := pos + cp + 3;
        w8(buf, pos+cp, 76); w8(buf, pos+cp+1, 137); w8(buf, pos+cp+2, 29); e2_w32(buf, pos+cp+3, 0); cp = cp + 7;
        grow_rip_patch(g_x86_rip_patch_count + 1);
        w64(g_x86_rip_patch_pos, g_x86_rip_patch_count * 8, rip_hp_s1);
        w64(g_x86_rip_patch_globals, g_x86_rip_patch_count * 8, gv_heap_ptr);
        g_x86_rip_patch_count = g_x86_rip_patch_count + 1;
    } else {
        rel2 := bss_va - (fva + cp + 7);
        w8(buf, pos+cp, 76); w8(buf, pos+cp+1, 137); w8(buf, pos+cp+2, 29); w8_signed(buf, pos+cp+3, rel2); cp = cp + 7;
    }

    // mov r8, r11 (old ptr); add r11, rdi (bump); mov [rip + g_heap_ptr], r11
    w8(buf, pos+cp, 77); w8(buf, pos+cp+1, 137); w8(buf, pos+cp+2, 216); cp = cp + 3;
    w8(buf, pos+cp, 73); w8(buf, pos+cp+1, 1); w8(buf, pos+cp+2, 251); cp = cp + 3;
    if gv_heap_ptr >= 0 {
        rip_hp_s2 := pos + cp + 3;
        w8(buf, pos+cp, 76); w8(buf, pos+cp+1, 137); w8(buf, pos+cp+2, 29); e2_w32(buf, pos+cp+3, 0); cp = cp + 7;
        grow_rip_patch(g_x86_rip_patch_count + 1);
        w64(g_x86_rip_patch_pos, g_x86_rip_patch_count * 8, rip_hp_s2);
        w64(g_x86_rip_patch_globals, g_x86_rip_patch_count * 8, gv_heap_ptr);
        g_x86_rip_patch_count = g_x86_rip_patch_count + 1;
    } else {
        rel3 := bss_va - (fva + cp + 7);
        w8(buf, pos+cp, 76); w8(buf, pos+cp+1, 137); w8(buf, pos+cp+2, 29); w8_signed(buf, pos+cp+3, rel3); cp = cp + 7;
    }

    // Zero-init: mov rdi, r8; mov rcx, r11; sub rcx, rdi; xor eax, eax; cld; rep stosb
    w8(buf, pos+cp, 76); w8(buf, pos+cp+1, 137); w8(buf, pos+cp+2, 199); cp = cp + 3;
    w8(buf, pos+cp, 76); w8(buf, pos+cp+1, 137); w8(buf, pos+cp+2, 217); cp = cp + 3;
    w8(buf, pos+cp, 72); w8(buf, pos+cp+1, 41); w8(buf, pos+cp+2, 249); cp = cp + 3;
    w8(buf, pos+cp, 49); w8(buf, pos+cp+1, 192); cp = cp + 2;
    w8(buf, pos+cp, 252); cp = cp + 1;
    w8(buf, pos+cp, 243); w8(buf, pos+cp+1, 170); cp = cp + 2;

    // Store header: mov [r8], r9; lea rax, [r8+8]; ret
    w8(buf, pos+cp, 77); w8(buf, pos+cp+1, 137); w8(buf, pos+cp+2, 8); cp = cp + 3;
    w8(buf, pos+cp, 73); w8(buf, pos+cp+1, 141); w8(buf, pos+cp+2, 64); w8(buf, pos+cp+3, 8); cp = cp + 4;
    w8(buf, pos+cp, 195); cp = cp + 1;

    return cp;
}

// ── heap_expand: mmap(0, 1GB, 3, 0x22, -1, 0) for OOM recovery ──
// Called when global bump heap reaches heap_end. Uses mmap syscall to
// allocate a new 1GiB region, then updates heap_ptr and heap_end.
fn emit_heap_expand(buf: string, pos: int, bss_va: int) -> int {
    cp := 0;
    fva := TEXT_BASE + pos;
    // Private allocator helper: preserve the live allocation span, original
    // request size, and current arena index across mmap argument setup.
    w8(buf, pos+cp, 87); cp = cp + 1;  // push rdi
    w8(buf, pos+cp, 65); w8(buf, pos+cp+1, 81); cp = cp + 2;  // push r9
    w8(buf, pos+cp, 65); w8(buf, pos+cp+1, 82); cp = cp + 2;  // push r10
    // xor edi, edi -- 31 FF (addr = NULL, let kernel choose)
    w8(buf, pos+cp, 49); w8(buf, pos+cp+1, 255); cp = cp + 2;
    // mov esi, 1073741824 -- BE xx xx xx xx (length = 1 GiB)
    e2_w8(buf, pos+cp, 190); e2_w32(buf, pos+cp+1, 1073741824); cp = cp + 5;
    // mov edx, 3 -- BA 03 00 00 00 (prot = PROT_READ|PROT_WRITE)
    w8(buf, pos+cp, 186); e2_w32(buf, pos+cp+1, 3); cp = cp + 5;
    // mov r10d, 0x22 -- 41 BA 22 00 00 00 (flags = MAP_PRIVATE|MAP_ANONYMOUS)
    w8(buf, pos+cp, 65); w8(buf, pos+cp+1, 186); e2_w32(buf, pos+cp+2, 34); cp = cp + 6;
    // mov r8d, -1 -- 41 B8 FF FF FF FF (fd = -1)
    w8(buf, pos+cp, 65); w8(buf, pos+cp+1, 184); e2_w32(buf, pos+cp+2, -1); cp = cp + 6;
    // xor r9d, r9d -- 45 31 C9 (offset = 0)
    w8(buf, pos+cp, 69); w8(buf, pos+cp+1, 49); w8(buf, pos+cp+2, 201); cp = cp + 3;
    // mov eax, 9 -- B8 09 00 00 00 (sys_mmap)
    w8(buf, pos+cp, 184); e2_w32(buf, pos+cp+1, 9); cp = cp + 5;
    // syscall -- 0F 05
    w8(buf, pos+cp, 15); w8(buf, pos+cp+1, 5); cp = cp + 2;
    // test rax, rax -- 48 85 C0 (check if mmap returned negative error)
    w8(buf, pos+cp, 72); w8(buf, pos+cp+1, 133); w8(buf, pos+cp+2, 192); cp = cp + 3;
    // js .Lhf -- 78 XX (skip success path if mmap failed, rax has -errno)
    // Success path: 7+7+7+2+5+1 = 29 bytes
    w8(buf, pos+cp, 120); w8(buf, pos+cp+1, 29); cp = cp + 2;
    // mov [rip + g_heap_ptr], rax — store via rip_patch
    if gv_heap_ptr >= 0 {
        rip_hp_ex := pos + cp + 3;
        w8(buf, pos+cp, 72); w8(buf, pos+cp+1, 137); w8(buf, pos+cp+2, 5); e2_w32(buf, pos+cp+3, 0); cp = cp + 7;
        grow_rip_patch(g_x86_rip_patch_count + 1);
        w64(g_x86_rip_patch_pos, g_x86_rip_patch_count * 8, rip_hp_ex);
        w64(g_x86_rip_patch_globals, g_x86_rip_patch_count * 8, gv_heap_ptr);
        g_x86_rip_patch_count = g_x86_rip_patch_count + 1;
    } else {
        rel_hp_s := bss_va - (fva + cp + 7);
        w8(buf, pos+cp, 72); w8(buf, pos+cp+1, 137); w8(buf, pos+cp+2, 5); w8_signed(buf, pos+cp+3, rel_hp_s); cp = cp + 7;
    }
    // lea r11, [rax + 1073741824] -- 4C 8D 98 xx xx xx xx (heap_end = new base + 1GB)
    w8(buf, pos+cp, 76); w8(buf, pos+cp+1, 141); w8(buf, pos+cp+2, 152); e2_w32(buf, pos+cp+3, 1073741824); cp = cp + 7;
    // mov [rip + g_heap_end], r11 — store via rip_patch
    if gv_heap_end >= 0 {
        rip_he_ex := pos + cp + 3;
        w8(buf, pos+cp, 76); w8(buf, pos+cp+1, 137); w8(buf, pos+cp+2, 29); e2_w32(buf, pos+cp+3, 0); cp = cp + 7;
        grow_rip_patch(g_x86_rip_patch_count + 1);
        w64(g_x86_rip_patch_pos, g_x86_rip_patch_count * 8, rip_he_ex);
        w64(g_x86_rip_patch_globals, g_x86_rip_patch_count * 8, gv_heap_end);
        g_x86_rip_patch_count = g_x86_rip_patch_count + 1;
    } else {
        rel_hp_e := (bss_va + 8) - (fva + cp + 7);
        w8(buf, pos+cp, 76); w8(buf, pos+cp+1, 137); w8(buf, pos+cp+2, 29); w8_signed(buf, pos+cp+3, rel_hp_e); cp = cp + 7;
    }
    // xor eax, eax -- 31 C0 (return 0 for success)
    w8(buf, pos+cp, 49); w8(buf, pos+cp+1, 192); cp = cp + 2;
    // Restore allocator state.
    w8(buf, pos+cp, 65); w8(buf, pos+cp+1, 90); cp = cp + 2;  // pop r10
    w8(buf, pos+cp, 65); w8(buf, pos+cp+1, 89); cp = cp + 2;  // pop r9
    w8(buf, pos+cp, 95); cp = cp + 1;  // pop rdi
    // ret -- C3
    w8(buf, pos+cp, 195); cp = cp + 1;
    // .Lhf: mmap failed, return -1
    // mov rax, -1 -- 48 C7 C0 FF FF FF FF
    w8(buf, pos+cp, 72); w8(buf, pos+cp+1, 199); w8(buf, pos+cp+2, 192); e2_w32(buf, pos+cp+3, -1); cp = cp + 7;
    w8(buf, pos+cp, 65); w8(buf, pos+cp+1, 90); cp = cp + 2;  // pop r10
    w8(buf, pos+cp, 65); w8(buf, pos+cp+1, 89); cp = cp + 2;  // pop r9
    w8(buf, pos+cp, 95); cp = cp + 1;  // pop rdi
    // ret -- C3
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

// ── g_set_curg / g_get_curg bridge stubs ──
// Pure-static ELFs don't link rt.s, so the backend emits equivalent
// implementations that read/write a dedicated BSS slot (current_g).
// In .so-linked builds (g_x86_emit_rt_stubs == 0) these stay external
// relocations resolved from rt.s at link time.
// Size: 11 bytes each — must match Phase 2 estimate.
fn emit_curg_stubs(buf: string, pos: int, curg_va: int) -> int {
    cp : ., mut = 0;
    // g_set_curg: lea rax, [rip + curg_va]; mov [rax], rdi; ret
    fva := TEXT_BASE + pos + cp;
    w8(buf, pos+cp, 72); w8(buf, pos+cp+1, 141); w8(buf, pos+cp+2, 5);  // lea rax, [rip+disp32]
    e2_w32(buf, pos+cp+3, curg_va - (fva + 7)); cp = cp + 7;
    w8(buf, pos+cp, 72); w8(buf, pos+cp+1, 137); w8(buf, pos+cp+2, 56); cp = cp + 3;  // mov [rax], rdi
    w8(buf, pos+cp, 195); cp = cp + 1;  // ret
    // g_get_curg: lea rax, [rip + curg_va]; mov rax, [rax]; ret
    fva2 := TEXT_BASE + pos + cp;
    w8(buf, pos+cp, 72); w8(buf, pos+cp+1, 141); w8(buf, pos+cp+2, 5);  // lea rax, [rip+disp32]
    e2_w32(buf, pos+cp+3, curg_va - (fva2 + 7)); cp = cp + 7;
    w8(buf, pos+cp, 72); w8(buf, pos+cp+1, 139); w8(buf, pos+cp+2, 0); cp = cp + 3;  // mov rax, [rax]
    w8(buf, pos+cp, 195); cp = cp + 1;  // ret
    return cp;
}
// ── Goroutine runtime stubs (pure-static self-contained runtime) ──
// rt.s equivalents emitted into the binary so `go f()` works without
// linking rt.s: fiber_init, fiber_switch, goroutine_entry_wrapper.
// The wrapper is the fiber entry for every G (g_new sets it via @addr);
// it reads saved_fn/saved_arg from the G struct (offsets 56/64), calls
// saved_fn(saved_arg), sends the result to result_ch (G+40), then yields
// forever. chan_send/sched_yield are Core functions — recorded as call
// patches resolved by the Phase 3 patch loop (user function names).
fn emit_goroutine_stubs(buf: string, pos: int) -> int {
    cp : ., mut = 0;

    // fiber_init(stack_bottom, entry_fn) -> int — fake frame on the new stack.
    // Layout: fiber_switch pops 6 regs (48 bytes) then ret reads
    // [stack_bottom-8] — entry_fn MUST be at [stack_bottom-8]:
    //   mov rax, rdi; sub rax, 8; mov [rax], rsi; sub rax, 48;
    //   xor ecx, ecx; mov [rax], rcx; ret
    w8(buf, pos+cp, 72); w8(buf, pos+cp+1, 137); w8(buf, pos+cp+2, 248); cp = cp + 3;  // mov rax, rdi
    w8(buf, pos+cp, 72); w8(buf, pos+cp+1, 131); w8(buf, pos+cp+2, 232); w8(buf, pos+cp+3, 8); cp = cp + 4;  // sub rax, 8
    w8(buf, pos+cp, 72); w8(buf, pos+cp+1, 137); w8(buf, pos+cp+2, 48); cp = cp + 3;  // mov [rax], rsi
    w8(buf, pos+cp, 72); w8(buf, pos+cp+1, 131); w8(buf, pos+cp+2, 232); w8(buf, pos+cp+3, 48); cp = cp + 4;  // sub rax, 48
    w8(buf, pos+cp, 49); w8(buf, pos+cp+1, 201); cp = cp + 2;  // xor ecx, ecx
    w8(buf, pos+cp, 72); w8(buf, pos+cp+1, 137); w8(buf, pos+cp+2, 8); cp = cp + 3;  // mov [rax], rcx
    w8(buf, pos+cp, 195); cp = cp + 1;  // ret
    // 20 bytes

    // fiber_switch(current_sp_addr, next_sp) -> int — save/restore context:
    //   push rbx,r12-r15,rbp; mov [rdi], rsp; mov rsp, rsi; pop rbp,r15-r12,rbx; ret
    w8(buf, pos+cp, 83); cp = cp + 1;  // push rbx
    w8(buf, pos+cp, 65); w8(buf, pos+cp+1, 84); cp = cp + 2;  // push r12
    w8(buf, pos+cp, 65); w8(buf, pos+cp+1, 85); cp = cp + 2;  // push r13
    w8(buf, pos+cp, 65); w8(buf, pos+cp+1, 86); cp = cp + 2;  // push r14
    w8(buf, pos+cp, 65); w8(buf, pos+cp+1, 87); cp = cp + 2;  // push r15
    w8(buf, pos+cp, 85); cp = cp + 1;  // push rbp
    w8(buf, pos+cp, 72); w8(buf, pos+cp+1, 137); w8(buf, pos+cp+2, 39); cp = cp + 3;  // mov [rdi], rsp
    w8(buf, pos+cp, 72); w8(buf, pos+cp+1, 137); w8(buf, pos+cp+2, 244); cp = cp + 3;  // mov rsp, rsi
    w8(buf, pos+cp, 93); cp = cp + 1;  // pop rbp
    w8(buf, pos+cp, 65); w8(buf, pos+cp+1, 95); cp = cp + 2;  // pop r15
    w8(buf, pos+cp, 65); w8(buf, pos+cp+1, 94); cp = cp + 2;  // pop r14
    w8(buf, pos+cp, 65); w8(buf, pos+cp+1, 93); cp = cp + 2;  // pop r13
    w8(buf, pos+cp, 65); w8(buf, pos+cp+1, 92); cp = cp + 2;  // pop r12
    w8(buf, pos+cp, 91); cp = cp + 1;  // pop rbx
    w8(buf, pos+cp, 195); cp = cp + 1;  // ret
    // 27 bytes

    // goroutine_entry_wrapper — fiber entry, no prologue (runs on the G's stack):
    //   call g_get_curg; rdi = [rax+64] (saved_arg — first param, SysV rdi);
    //   rax = [rax+56] (saved_fn); call rax; push rax; call g_get_curg;
    //   rdi = [rax+40] (result_ch); pop rsi; call chan_send;
    //   then exit: call g_get_curg; mov rdi, rax; call g_free (arena_reset +
    //   mark _Gdead); call sched_schedule (switch to next, no re-enqueue);
    //   ret (fiber dead if no work)
    call_pos0 := pos + cp;
    grow_call_patch(g_x86_call_patch_count + 1);
    w64(g_x86_call_patch_pos, g_x86_call_patch_count * 8, call_pos0);
    w64(g_x86_call_patch_name, g_x86_call_patch_count * 8, str_intern("g_get_curg"));
    g_x86_call_patch_count = g_x86_call_patch_count + 1;
    e2_w8(buf, pos+cp, 232); e2_w32(buf, pos+cp+1, 0); cp = cp + 5;  // call g_get_curg
    w8(buf, pos+cp, 72); w8(buf, pos+cp+1, 139); w8(buf, pos+cp+2, 120); w8(buf, pos+cp+3, 64); cp = cp + 4;  // mov rdi, [rax+64]
    w8(buf, pos+cp, 72); w8(buf, pos+cp+1, 139); w8(buf, pos+cp+2, 64); w8(buf, pos+cp+3, 56); cp = cp + 4;  // mov rax, [rax+56]  (modrm 01 000 000 = 0x40 + disp8)
    w8(buf, pos+cp, 255); w8(buf, pos+cp+1, 208); cp = cp + 2;  // call rax
    w8(buf, pos+cp, 80); cp = cp + 1;  // push rax
    call_pos1 := pos + cp;
    grow_call_patch(g_x86_call_patch_count + 1);
    w64(g_x86_call_patch_pos, g_x86_call_patch_count * 8, call_pos1);
    w64(g_x86_call_patch_name, g_x86_call_patch_count * 8, str_intern("g_get_curg"));
    g_x86_call_patch_count = g_x86_call_patch_count + 1;
    e2_w8(buf, pos+cp, 232); e2_w32(buf, pos+cp+1, 0); cp = cp + 5;  // call g_get_curg
    w8(buf, pos+cp, 72); w8(buf, pos+cp+1, 139); w8(buf, pos+cp+2, 120); w8(buf, pos+cp+3, 40); cp = cp + 4;  // mov rdi, [rax+40]
    w8(buf, pos+cp, 94); cp = cp + 1;  // pop rsi
    call_pos2 := pos + cp;
    grow_call_patch(g_x86_call_patch_count + 1);
    w64(g_x86_call_patch_pos, g_x86_call_patch_count * 8, call_pos2);
    w64(g_x86_call_patch_name, g_x86_call_patch_count * 8, str_intern("chan_send"));
    g_x86_call_patch_count = g_x86_call_patch_count + 1;
    e2_w8(buf, pos+cp, 232); e2_w32(buf, pos+cp+1, 0); cp = cp + 5;  // call chan_send
    // exit: call g_get_curg; mov rdi, rax; call g_free; call sched_schedule; ret
    call_pos3 := pos + cp;
    grow_call_patch(g_x86_call_patch_count + 1);
    w64(g_x86_call_patch_pos, g_x86_call_patch_count * 8, call_pos3);
    w64(g_x86_call_patch_name, g_x86_call_patch_count * 8, str_intern("g_get_curg"));
    g_x86_call_patch_count = g_x86_call_patch_count + 1;
    e2_w8(buf, pos+cp, 232); e2_w32(buf, pos+cp+1, 0); cp = cp + 5;  // call g_get_curg
    w8(buf, pos+cp, 72); w8(buf, pos+cp+1, 137); w8(buf, pos+cp+2, 248); cp = cp + 3;  // mov rdi, rax
    call_pos4 := pos + cp;
    grow_call_patch(g_x86_call_patch_count + 1);
    w64(g_x86_call_patch_pos, g_x86_call_patch_count * 8, call_pos4);
    w64(g_x86_call_patch_name, g_x86_call_patch_count * 8, str_intern("g_free"));
    g_x86_call_patch_count = g_x86_call_patch_count + 1;
    e2_w8(buf, pos+cp, 232); e2_w32(buf, pos+cp+1, 0); cp = cp + 5;  // call g_free
    call_pos5 := pos + cp;
    grow_call_patch(g_x86_call_patch_count + 1);
    w64(g_x86_call_patch_pos, g_x86_call_patch_count * 8, call_pos5);
    w64(g_x86_call_patch_name, g_x86_call_patch_count * 8, str_intern("sched_schedule"));
    g_x86_call_patch_count = g_x86_call_patch_count + 1;
    e2_w8(buf, pos+cp, 232); e2_w32(buf, pos+cp+1, 0); cp = cp + 5;  // call sched_schedule
    w8(buf, pos+cp, 195); cp = cp + 1;  // ret

    return cp;
}

// ── m_start_workers runtime stub (pure-static self-contained runtime) ──
// rt.s equivalent: launches n-1 worker threads via clone; each worker runs
// sched_worker_run(m_idx). worker_entry (15 bytes) precedes the public
// entry so `lea r13, [rip + worker_entry]` has a backward displacement.
// Layout (worker_entry at 0, m_start_workers at 15, 111 bytes):
//   worker_entry: pop rdi; call sched_worker_run; mov eax,60; xor edi,edi; syscall
//   m_start_workers: push rbx,r12,r13,r15; mov rbx,rdi; xor r12d,r12d
//     .Lloop: inc r12; cmp r12,rbx; jge .Ldone; push r12; mov rdi,65536;
//     call alloc; pop r12; test rax,rax; jz .Lnext; mov r15,rax; add r15,65536;
//     lea r13,[rip+worker_entry]; mov [r15-16],r13; mov [r15-8],r12;
//     mov edi,0x10F00; lea rsi,[r15-16]; xor edx,edx; xor r10d,r10d; xor r8d,r8d;
//     mov eax,56; syscall; test rax,rax; jz .Lchild
//     .Lnext: inc r12; jmp .Lloop
//     .Lchild: xor ebp,ebp; ret
//     .Ldone: pop r15,r13,r12,rbx; ret
fn emit_m_start_workers(buf: string, pos: int) -> int {
    cp : ., mut = 0;

    // worker_entry (15 bytes):
    w8(buf, pos+cp, 95); cp = cp + 1;  // pop rdi
    call_pos_we := pos + cp;
    grow_call_patch(g_x86_call_patch_count + 1);
    w64(g_x86_call_patch_pos, g_x86_call_patch_count * 8, call_pos_we);
    w64(g_x86_call_patch_name, g_x86_call_patch_count * 8, str_intern("sched_worker_run"));
    g_x86_call_patch_count = g_x86_call_patch_count + 1;
    e2_w8(buf, pos+cp, 232); e2_w32(buf, pos+cp+1, 0); cp = cp + 5;  // call sched_worker_run
    w8(buf, pos+cp, 184); w8(buf, pos+cp+1, 60); w8(buf, pos+cp+2, 0); w8(buf, pos+cp+3, 0); w8(buf, pos+cp+4, 0); cp = cp + 5;  // mov eax, 60
    w8(buf, pos+cp, 49); w8(buf, pos+cp+1, 255); cp = cp + 2;  // xor edi, edi
    w8(buf, pos+cp, 15); w8(buf, pos+cp+1, 5); cp = cp + 2;  // syscall

    // m_start_workers (111 bytes, starts at pos+15)
    w8(buf, pos+cp, 83); cp = cp + 1;  // push rbx
    w8(buf, pos+cp, 65); w8(buf, pos+cp+1, 84); cp = cp + 2;  // push r12
    w8(buf, pos+cp, 65); w8(buf, pos+cp+1, 85); cp = cp + 2;  // push r13
    w8(buf, pos+cp, 65); w8(buf, pos+cp+1, 87); cp = cp + 2;  // push r15
    w8(buf, pos+cp, 72); w8(buf, pos+cp+1, 137); w8(buf, pos+cp+2, 251); cp = cp + 3;  // mov rbx, rdi
    w8(buf, pos+cp, 69); w8(buf, pos+cp+1, 49); w8(buf, pos+cp+2, 228); cp = cp + 3;  // xor r12d, r12d
    // .Lworker_loop (offset 13)
    w8(buf, pos+cp, 73); w8(buf, pos+cp+1, 255); w8(buf, pos+cp+2, 196); cp = cp + 3;  // inc r12
    w8(buf, pos+cp, 73); w8(buf, pos+cp+1, 57); w8(buf, pos+cp+2, 220); cp = cp + 3;  // cmp r12, rbx
    w8(buf, pos+cp, 125); w8(buf, pos+cp+1, 83); cp = cp + 2;  // jge .Ldone (+83)
    w8(buf, pos+cp, 65); w8(buf, pos+cp+1, 84); cp = cp + 2;  // push r12
    w8(buf, pos+cp, 72); w8(buf, pos+cp+1, 199); w8(buf, pos+cp+2, 199); cp = cp + 3;  // mov rdi, 65536
    w8(buf, pos+cp, 0); w8(buf, pos+cp+1, 0); w8(buf, pos+cp+2, 1); w8(buf, pos+cp+3, 0); cp = cp + 4;
    call_pos_al := pos + cp;
    grow_call_patch(g_x86_call_patch_count + 1);
    w64(g_x86_call_patch_pos, g_x86_call_patch_count * 8, call_pos_al);
    w64(g_x86_call_patch_name, g_x86_call_patch_count * 8, str_intern("alloc"));
    g_x86_call_patch_count = g_x86_call_patch_count + 1;
    e2_w8(buf, pos+cp, 232); e2_w32(buf, pos+cp+1, 0); cp = cp + 5;  // call alloc
    w8(buf, pos+cp, 65); w8(buf, pos+cp+1, 92); cp = cp + 2;  // pop r12
    w8(buf, pos+cp, 72); w8(buf, pos+cp+1, 133); w8(buf, pos+cp+2, 192); cp = cp + 3;  // test rax, rax
    w8(buf, pos+cp, 116); w8(buf, pos+cp+1, 54); cp = cp + 2;  // jz .Lnext_worker (+54)
    w8(buf, pos+cp, 73); w8(buf, pos+cp+1, 137); w8(buf, pos+cp+2, 199); cp = cp + 3;  // mov r15, rax
    w8(buf, pos+cp, 73); w8(buf, pos+cp+1, 129); w8(buf, pos+cp+2, 199); cp = cp + 3;  // add r15, 65536
    w8(buf, pos+cp, 0); w8(buf, pos+cp+1, 0); w8(buf, pos+cp+2, 1); w8(buf, pos+cp+3, 0); cp = cp + 4;
    // lea r13, [rip + worker_entry] — worker_entry at stub base (pos+0), this lea
    // is 7 bytes ending at (pos+58): disp = (pos+0) - (pos+58) = -58
    w8(buf, pos+cp, 76); w8(buf, pos+cp+1, 141); w8(buf, pos+cp+2, 45); cp = cp + 3;
    e2_w32(buf, pos+cp, -58); cp = cp + 4;
    w8(buf, pos+cp, 77); w8(buf, pos+cp+1, 137); w8(buf, pos+cp+2, 111); w8(buf, pos+cp+3, 240); cp = cp + 4;  // mov [r15-16], r13
    w8(buf, pos+cp, 76); w8(buf, pos+cp+1, 137); w8(buf, pos+cp+2, 71); w8(buf, pos+cp+3, 248); cp = cp + 4;  // mov [r15-8], r12
    w8(buf, pos+cp, 191); w8(buf, pos+cp+1, 0); w8(buf, pos+cp+2, 15); w8(buf, pos+cp+3, 1); w8(buf, pos+cp+4, 0); cp = cp + 5;  // mov edi, 0x10F00
    w8(buf, pos+cp, 73); w8(buf, pos+cp+1, 141); w8(buf, pos+cp+2, 119); w8(buf, pos+cp+3, 240); cp = cp + 4;  // lea rsi, [r15-16]
    w8(buf, pos+cp, 49); w8(buf, pos+cp+1, 210); cp = cp + 2;  // xor edx, edx
    w8(buf, pos+cp, 69); w8(buf, pos+cp+1, 49); w8(buf, pos+cp+2, 210); cp = cp + 3;  // xor r10d, r10d
    w8(buf, pos+cp, 69); w8(buf, pos+cp+1, 49); w8(buf, pos+cp+2, 192); cp = cp + 3;  // xor r8d, r8d
    w8(buf, pos+cp, 184); w8(buf, pos+cp+1, 56); w8(buf, pos+cp+2, 0); w8(buf, pos+cp+3, 0); w8(buf, pos+cp+4, 0); cp = cp + 5;  // mov eax, 56
    w8(buf, pos+cp, 15); w8(buf, pos+cp+1, 5); cp = cp + 2;  // syscall
    w8(buf, pos+cp, 72); w8(buf, pos+cp+1, 133); w8(buf, pos+cp+2, 192); cp = cp + 3;  // test rax, rax
    w8(buf, pos+cp, 116); w8(buf, pos+cp+1, 5); cp = cp + 2;  // jz .Lchild (+5)
    // .Lnext_worker (offset 95)
    w8(buf, pos+cp, 73); w8(buf, pos+cp+1, 255); w8(buf, pos+cp+2, 196); cp = cp + 3;  // inc r12
    w8(buf, pos+cp, 235); w8(buf, pos+cp+1, 169); cp = cp + 2;  // jmp .Lworker_loop (-87)
    // .Lchild (offset 100)
    w8(buf, pos+cp, 49); w8(buf, pos+cp+1, 237); cp = cp + 2;  // xor ebp, ebp
    w8(buf, pos+cp, 195); cp = cp + 1;  // ret
    // .Ldone (offset 103)
    w8(buf, pos+cp, 65); w8(buf, pos+cp+1, 95); cp = cp + 2;  // pop r15
    w8(buf, pos+cp, 65); w8(buf, pos+cp+1, 93); cp = cp + 2;  // pop r13
    w8(buf, pos+cp, 65); w8(buf, pos+cp+1, 92); cp = cp + 2;  // pop r12
    w8(buf, pos+cp, 91); cp = cp + 1;  // pop rbx
    w8(buf, pos+cp, 195); cp = cp + 1;  // ret

    return cp;
}

fn sched_reg_one(name: string, offset: int, cp: int) {
    grow_func_offsets(g_x86_func_off_count * 2 + 2);
    w64(g_x86_func_offsets, g_x86_func_off_count * 16, str_intern(name));
    w64(g_x86_func_offsets, g_x86_func_off_count * 16 + 8, cp - 176);
    g_x86_func_off_count = g_x86_func_off_count + 1;
}

fn w16(buf: string, off: int, val: int) {
    store8(buf, off, val % 256); store8(buf, off+1, (val/256) % 256);
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

// Arena global variable indices (set by elf_gen before emit_alloc_body calls)
gv_current_arena : int, mut = -1;
gv_arena_cursors : int, mut = -1;
gv_arena_sizes : int, mut = -1;
gv_arena_pool_data : int, mut = -1;
gv_arena_max_size : int, mut = -1;
gv_heap_ptr : int, mut = -1;
gv_heap_end : int, mut = -1;
gv_hp_config : int, mut = -1;
gv_hp_inflight : int, mut = -1;
g_heap_expand_call_pos : int, mut = -1;
g_alloc_gl_jmp_pos : int, mut = -1;  // Part 1 jl .Lglobal displacement position (patched at Part 8)

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

    // Initialize g_current_arena = -1 (no arena active)
    if gv_current_arena >= 0 {
        rip_ca := cp + 3;
        cp = cp + e2_lr(buf, cp, 0);  // lea r10, [rip+0]
        grow_rip_patch(g_x86_rip_patch_count + 1);
        w64(g_x86_rip_patch_pos, g_x86_rip_patch_count * 8, rip_ca);
        w64(g_x86_rip_patch_globals, g_x86_rip_patch_count * 8, gv_current_arena);
        g_x86_rip_patch_count = g_x86_rip_patch_count + 1;
        // mov qword [r10], -1  — REX.WB + 0xC7 /0
        cp = cp + emit_rex(buf, cp, 1, 0, 0, 10/8);
        e2_w8(buf, cp, 199); cp = cp + 1;      // 0xC7 MOV r/m64, imm32
        cp = cp + emit_modrm(buf, cp, 0, 0, 10%8);
        e2_w32(buf, cp, -1); cp = cp + 4;      // immediate = -1 (0xFFFFFFFF)
    }

    // Write compile-time constant global initializers (g_ir_globals[i].
    // init_val, i64 at +16; 0 = none — BSS is already zero).
    // g_current_arena is also covered by the explicit init above; the
    // LET-based init below writes it again with the same value (harmless).
    gi0 : ., mut = 0;
    loop { if gi0 >= g_ir_global_count { break; }
        iv := r64(g_ir_globals, gi0 * 24 + 16);
        gvv0 := r64(g_ir_globals, gi0 * 24 + 8);
        if iv != 0 && gvv0 >= 0 {
            // lea r10, [rip+0] — rip_patch for the global's BSS slot
            rip_pos_g := cp + 3;
            cp = cp + e2_lr(buf, cp, 0);
            grow_rip_patch(g_x86_rip_patch_count + 1);
            w64(g_x86_rip_patch_pos, g_x86_rip_patch_count * 8, rip_pos_g);
            w64(g_x86_rip_patch_globals, g_x86_rip_patch_count * 8, gvv0);
            g_x86_rip_patch_count = g_x86_rip_patch_count + 1;
            if iv >= -2147483647 - 1 && iv <= 2147483647 {
                // mov qword [r10], imm32 (sign-extended) — 49 C7 02 imm32
                w8(buf, cp, 73); w8(buf, cp+1, 199); w8(buf, cp+2, 2);
                e2_w32(buf, cp+3, iv); cp = cp + 7;
            } else {
                // mov rax, imm64; mov [r10], rax
                w8(buf, cp, 72); w8(buf, cp+1, 184); e2_w64(buf, cp+2, iv); cp = cp + 10;
                w8(buf, cp, 73); w8(buf, cp+1, 137); w8(buf, cp+2, 2); cp = cp + 3;
            }
        }
    gi0 = gi0 + 1; }

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
    // g_current_arena init: lea(7) + rex+mov+modrm+imm32(7) = 14 bytes
    if gv_current_arena >= 0 { sz = sz + 14; }
    // Constant global initializers: lea r10(7) + mov imm32(7) = 14 bytes,
    // or mov rax imm64 + mov [r10],rax = 20 bytes for large values.
    gi0s : ., mut = 0;
    loop { if gi0s >= g_ir_global_count { break; }
        ivs := r64(g_ir_globals, gi0s * 24 + 16);
        gvvs := r64(g_ir_globals, gi0s * 24 + 8);
        if ivs != 0 && gvvs >= 0 {
            if ivs >= -2147483647 - 1 && ivs <= 2147483647 { sz = sz + 14; }
            else { sz = sz + 20; }
        }
    gi0s = gi0s + 1; }
    return sz;
}

// ── Main ELF generation ──
fn elf_gen(buf: string) -> int {
    // Mark global variables for RIP-relative addressing
    gi := 0; loop { if gi >= g_ir_global_count { break; }
        gv := r64(g_ir_globals, gi * 24 + 8);
        if gv >= 0 { grow_is_global(gv + 1); w64(g_x86_is_global, gv * 8, 1); }
    gi = gi + 1; }
    grow_is_global(g_ir_var_count);

    g_ni_syscall3 = -1; g_ni_syscall4 = -1; g_ni_load8 = -1; g_ni_store8 = -1; g_ni_load64 = -1;
    g_ni_load_str_ptr = -1; g_ni_store_str_ptr = -1; g_ni_get_arg = -1;
    g_ni_w64 = -1; g_ni_dyncpy = -1; g_ni_r64 = -1;
    g_ni_goroutine_wrapper_addr = -1;
    ni_i : ., mut = 0;
    loop { if ni_i >= g_str_count { break; }
        ns := istr_get(ni_i);
        if str_eq(ns, "syscall3") != 0 { g_ni_syscall3 = ni_i; }
        if str_eq(ns, "syscall4") != 0 { g_ni_syscall4 = ni_i; }
        if str_eq(ns, "load8") != 0 { g_ni_load8 = ni_i; }
        if str_eq(ns, "store8") != 0 { g_ni_store8 = ni_i; }
        if str_eq(ns, "load64") != 0 { g_ni_load64 = ni_i; }
        if str_eq(ns, "r64") != 0 { g_ni_r64 = ni_i; }
        if str_eq(ns, "load_str_ptr") != 0 { g_ni_load_str_ptr = ni_i; }
        if str_eq(ns, "store_str_ptr") != 0 { g_ni_store_str_ptr = ni_i; }
        if str_eq(ns, "get_arg") != 0 { g_ni_get_arg = ni_i; }
        if str_eq(ns, "w64") != 0 { g_ni_w64 = ni_i; }
        if str_eq(ns, "_dyncpy") != 0 { g_ni_dyncpy = ni_i; }
        if str_eq(ns, "goroutine_wrapper_addr") != 0 { g_ni_goroutine_wrapper_addr = ni_i; }
    ni_i = ni_i + 1; }

    print("  ni: syscall3="); print(int_str(g_ni_syscall3));
    print(" load8="); print(int_str(g_ni_load8));
    print(" w64="); print(int_str(g_ni_w64));
    print(" dyncpy="); println(int_str(g_ni_dyncpy));

    // Reset scratch-emission garbage (res_labels -> emit_instr -> pollutes rip_patch arrays)
    g_x86_rip_patch_count = 0;
    g_x86_rodataref_count = 0;
    g_x86_alloc_patch_count = 0;
    g_x86_fnaddr_patch_count = 0;

    println("  elf: Phase 1 (rodata layout)...");
    // Phase 1: rodata layout — collect string constants
    g_x86_str_count = 0;
    si := 0; loop { if si >= g_ir_str_const_count { break; } g2_str_off(r64(g_ir_str_consts, si * 8)); si = si + 1; }

    // Find g_rt_argc/g_rt_argv_ptr via name_idx (no str_eq loop)
    gv_argc = -1; gv_argv = -1;
    argc_ni := str_intern("g_rt_argc"); argv_ni := str_intern("g_rt_argv_ptr");
    // Arena global variable indices
    gv_current_arena = -1; gv_arena_cursors = -1; gv_arena_sizes = -1;
    gv_arena_pool_data = -1; gv_arena_max_size = -1;
    cur_ni := str_intern("g_current_arena"); cur_ni2 := str_intern("g_arena_cursors");
    cur_ni3 := str_intern("g_arena_sizes"); cur_ni4 := str_intern("g_arena_pool_data");
    cur_ni5 := str_intern("g_arena_max_size");
    cur_ni6 := str_intern("g_heap_ptr"); cur_ni7 := str_intern("g_heap_end");
    cur_ni8 := str_intern("g_hp_config"); cur_ni9 := str_intern("g_hp_inflight");
    gvsi : ., mut = 0;
    loop { if gvsi >= g_ir_global_count { break; }
        ni := r64(g_ir_globals, gvsi * 24);
        if ni == argc_ni { gv_argc = r64(g_ir_globals, gvsi * 24 + 8); }
        if ni == argv_ni { gv_argv = r64(g_ir_globals, gvsi * 24 + 8); }
        if ni == cur_ni { gv_current_arena = r64(g_ir_globals, gvsi * 24 + 8); }
        if ni == cur_ni2 { gv_arena_cursors = r64(g_ir_globals, gvsi * 24 + 8); }
        if ni == cur_ni3 { gv_arena_sizes = r64(g_ir_globals, gvsi * 24 + 8); }
        if ni == cur_ni4 { gv_arena_pool_data = r64(g_ir_globals, gvsi * 24 + 8); }
        if ni == cur_ni5 { gv_arena_max_size = r64(g_ir_globals, gvsi * 24 + 8); }
        if ni == cur_ni6 { gv_heap_ptr = r64(g_ir_globals, gvsi * 24 + 8); }
        if ni == cur_ni7 { gv_heap_end = r64(g_ir_globals, gvsi * 24 + 8); }
        if ni == cur_ni8 { gv_hp_config = r64(g_ir_globals, gvsi * 24 + 8); }
        if ni == cur_ni9 { gv_hp_inflight = r64(g_ir_globals, gvsi * 24 + 8); }
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
        vs2 := r64(g_ir_func_var_start, fi * 8);
        pc2 := r64(g_ir_func_param_count, fi * 8);

        // int 多字 M1（Task 1）：识别潜在多字变量并计入帧尺寸（tag 区）。
        // tag 数为 0 → mw_frame_size 与旧公式逐字节一致（快路径零变化）。
        mw_setup_tags(fi, vs2, vc2);
        fsz := r64(g_x86_func_code_sz, fi * 8);
        // SysV 16 字节对齐（发现 11）：call 后 rsp%16=8；
        // opt≥1 有 6 个 push（rbx,r12-15,rbp）→ rsp%16=8 → size 需 ≡8 (mod 16)；
        // opt<1 有 1 个 push（rbp）→ rsp%16=0 → size 需 ≡0 (mod 16)。
        // mw_frame_size 已含 tag 区并按上述规则取整（与 Phase 3 同源）。
        g_x86_emit_stack_size = mw_frame_size(vc2);
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
    total_code = total_code + 330;  // arena-aware dual-path alloc body (~323 bytes with OOM check + zero-init + chain-expand + current-arena check)
    // heap_expand
    grow_func_offsets(g_x86_func_off_count * 2 + 2);
    w64(g_x86_func_offsets, g_x86_func_off_count * 16, str_intern("heap_expand"));
    w64(g_x86_func_offsets, g_x86_func_off_count * 16 + 8, total_code);
    g_x86_func_off_count = g_x86_func_off_count + 1;
    total_code = total_code + 86;  // heap_expand with allocator-state save/restore
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
    if g_x86_emit_rt_stubs != 0 {
        // g_set_curg / g_get_curg bridges (11 bytes each) — pure-static self-containment
        grow_func_offsets(g_x86_func_off_count * 2 + 2);
        w64(g_x86_func_offsets, g_x86_func_off_count * 16, str_intern("g_set_curg"));
        w64(g_x86_func_offsets, g_x86_func_off_count * 16 + 8, total_code);
        g_x86_func_off_count = g_x86_func_off_count + 1;
        total_code = total_code + 11;
        grow_func_offsets(g_x86_func_off_count * 2 + 2);
        w64(g_x86_func_offsets, g_x86_func_off_count * 16, str_intern("g_get_curg"));
        w64(g_x86_func_offsets, g_x86_func_off_count * 16 + 8, total_code);
        g_x86_func_off_count = g_x86_func_off_count + 1;
        total_code = total_code + 11;
    }

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
    g_x86_fnaddr_patch_count = 0;
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
        // int 多字 M1（Task 1）：潜在多字变量识别 + tag 字节偏移表（g2_tag_off）。
        // 帧尺寸 = mw_frame_size(vc)（含 tag 区，16 对齐规则与 Phase 2 dry run
        // 同源）；tag 数为 0 → 与旧布局逐字节一致。
        mw_setup_tags(fi, vs, vc);
        // SysV 16 字节对齐（发现 11）：与 dry run 相同的对齐规则
        g_x86_emit_stack_size = mw_frame_size(vc);

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
            pty := irv_type(vs + pi);
            if pty == TI_DEX && pi < 6 {
                // float 参数在 XMM：movsd [rbp+po2], xmm{frn}（SysV）
                // frn = 第 pi 个参数前的 float 参数数
                frn : ., mut = 0;
                fj : ., mut = 0;
                loop { if fj >= pi { break; }
                    if irv_type(vs + fj) == TI_DEX { frn = frn + 1; }
                    fj = fj + 1; }
                if frn < 8 {
                    // movsd [rbp+po2], xmm{frn} — F2 0F 11 /rn（mod=01, rm=5）
                    w8(buf, cp, 242); w8(buf, cp+1, 15); w8(buf, cp+2, 17);
                    w8(buf, cp+3, 64 + frn * 8 + 5); w8(buf, cp+4, po2); cp = cp + 5;
                } else {
                    // 9+ binary64 参数在栈上（边缘场景，位置布局简化处理）
                    caller_off := 16 + (pi - 6) * 8;
                    if g_opt_level >= 1 { caller_off = caller_off + 40; }
                    cp = cp + e2_sd_load(buf, cp, caller_off);
                    cp = cp + e2_sd_store(buf, cp, po2);
                }
            } else if pi >= 6 {
                caller_off := 16 + (pi - 6) * 8;
                if g_opt_level >= 1 { caller_off = caller_off + 40; }
                if pty == TI_DEX {
                    cp = cp + e2_sd_load(buf, cp, caller_off);
                    cp = cp + e2_sd_store(buf, cp, po2);
                } else {
                    cp = cp + e2_ld(buf, cp, 10, caller_off);
                    cp = cp + e2_st(buf, cp, 10, po2);
                }
            } else {
                if pi == 0 { cp = cp + e2_st(buf, cp, 7, po2); }
                if pi == 1 { w8(buf, cp, 72); w8(buf, cp+1, 137); w8(buf, cp+2, 117); w8(buf, cp+3, po2); cp = cp + 4; }
                if pi == 2 { w8(buf, cp, 72); w8(buf, cp+1, 137); w8(buf, cp+2, 85); w8(buf, cp+3, po2); cp = cp + 4; }
                if pi == 3 { w8(buf, cp, 72); w8(buf, cp+1, 137); w8(buf, cp+2, 77); w8(buf, cp+3, po2); cp = cp + 4; }
                if pi == 4 { w8(buf, cp, 76); w8(buf, cp+1, 137); w8(buf, cp+2, 69); w8(buf, cp+3, po2); cp = cp + 4; }
                if pi == 5 { w8(buf, cp, 76); w8(buf, cp+1, 137); w8(buf, cp+2, 77); w8(buf, cp+3, po2); cp = cp + 4; }
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
            // HIT 表模式（M1 Task 2）：表映射 op 走 emit_instr_tabled；
            // -1（未映射/形态不支持/无表）落旧路径 emit_instr——混合模式。
            // int 多字 M1（Task 2）：tagged int add/sub 需溢出跳（jo）——
            // 表路径（hit_ev 降低不知 tag/无 jo 事件）整条排除落旧路径。
            sz : ., mut = -1;
            if hit_table_active() != 0 && mw_int_arith_jo_needed(inst_idx) == 0 {
                sz = emit_instr_tabled(inst_idx, buf, cp);
            }
            if sz < 0 { sz = emit_instr(inst_idx, buf, cp); }
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

        // ── int 多字 M1（Task 2）：慢路径块（函数尾附加）+ jo rel32 回填 ──
        // jo 目标 = 本函数尾声之后——emit_instr 记录位置（g2_init 清零、
        // 逐函数段），此处（块位置已知后）统一回填。块骨架 = ud2：溢出到达
        // = 确定性 SIGILL（本任务跳转可达性验证载体）；Task 3 以真实 2-limb
        // 修正代码替换块内容（届时 jo 记录也需扩展 dest 等现场信息）。
        // 无 jo 的函数不发块、零字节影响（untagged 快路径零变化）。
        if g_x86_mw_jo_count > 0 {
            mw_blk := cp;
            w8(buf, cp, 15); w8(buf, cp + 1, 11); cp = cp + 2;  // ud2（占位）
            mw_ji : ., mut = 0;
            loop { if mw_ji >= g_x86_mw_jo_count { break; }
                jo_pos := r64(g_x86_mw_jo_pos, mw_ji * 8);
                w32(buf, jo_pos + 2, mw_blk - (jo_pos + 6));
                mw_ji = mw_ji + 1; }
            g_x86_mw_jo_count = 0;
        }
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
        gvv := r64(g_ir_globals, gsi * 24 + 8);
        if gvv >= 0 && gvv > max_gv { max_gv = gvv; }
    gsi = gsi + 1; }
    // globals_size = (max_var_idx + 1) * 8 ensures BSS covers all globals
    globals_size : ., mut = (max_gv + 1) * 8;
    if globals_size < 256 { globals_size = 256; }
    if g_x86_emit_rt_stubs != 0 { globals_size = globals_size + 8; }  // + current_g slot
    alloc_sz := emit_alloc_body(buf, cp, bss_va, globals_size);
    alloc_start := cp;
    g_curg_stub_start : ., mut = -1;
    cp = cp + alloc_sz;

    // ── heap_expand ──
    heap_expand_start : ., mut = cp;
    cp = cp + emit_heap_expand(buf, cp, bss_va);
    // Update heap_expand's offset in func_offsets to real position (Phase 3 value)
    hefi := 0;
    loop { if hefi >= g_x86_func_off_count { break; }
        if str_eq(istr_get(r64(g_x86_func_offsets, hefi*16)), "heap_expand") != 0 {
            w64(g_x86_func_offsets, hefi*16+8, heap_expand_start - 176);
            break; }
    hefi = hefi + 1; }

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

    // ── arena_new/arena_reset stubs (fallback when arena.cr not imported) ──
    // These are only used when the functions aren't compiled from user code.
    // If the user imports arena, the compiled versions in g_ir_func_name_idx take priority.
    grow_func_offsets(g_x86_func_off_count * 2 + 2);
    w64(g_x86_func_offsets, g_x86_func_off_count * 16, str_intern("arena_new"));
    w64(g_x86_func_offsets, g_x86_func_off_count * 16 + 8, cp - 176);
    g_x86_func_off_count = g_x86_func_off_count + 1;
    w8(buf, cp, 195); cp = cp + 1;  // ret

    grow_func_offsets(g_x86_func_off_count * 2 + 2);
    w64(g_x86_func_offsets, g_x86_func_off_count * 16, str_intern("arena_reset"));
    w64(g_x86_func_offsets, g_x86_func_off_count * 16 + 8, cp - 176);
    g_x86_func_off_count = g_x86_func_off_count + 1;
    w8(buf, cp, 195); cp = cp + 1;  // ret

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

    // ── g_set_curg / g_get_curg bridge stubs (pure-static self-contained runtime) ──
    // Provisional BSS VA (0); re-emitted in place after final bss_va is known.
    if g_x86_emit_rt_stubs != 0 {
        g_curg_stub_start = cp;
        cp = cp + emit_curg_stubs(buf, cp, 0);
        // Update func_offsets entries to real positions (call_patch fallback uses these)
        gsi2 : ., mut = 0;
        loop { if gsi2 >= g_x86_func_off_count { break; }
            nm2 := istr_get(r64(g_x86_func_offsets, gsi2*16));
            if str_eq(nm2, "g_set_curg") != 0 { w64(g_x86_func_offsets, gsi2*16+8, g_curg_stub_start - 176); }
            if str_eq(nm2, "g_get_curg") != 0 { w64(g_x86_func_offsets, gsi2*16+8, g_curg_stub_start - 176 + 11); }
        gsi2 = gsi2 + 1; }
    }

    // ── Goroutine runtime stubs (fiber_init / fiber_switch / goroutine_entry_wrapper) ──
    // Required by g_new → go f(): the wrapper is the fiber entry, fiber_init
    // builds the fake frame, fiber_switch performs the context switch.
    // Registered in func_offsets so IR_CALL (fiber_init/fiber_switch from
    // Core) and IR_FNADDR (@addr(goroutine_entry_wrapper)) resolve here.
    if g_x86_emit_rt_stubs != 0 {
        sched_reg_one("fiber_init", 0, cp);
        sched_reg_one("fiber_switch", 0, cp + 20);
        sched_reg_one("goroutine_entry_wrapper", 0, cp + 47);
        cp = cp + emit_goroutine_stubs(buf, cp);
        // m_start_workers — worker thread launcher (clone). worker_entry
        // (15 bytes) precedes the public entry so its RIP-relative LEA stays
        // backward; register the public symbol at cp + 15.
        sched_reg_one("m_start_workers", 0, cp + 15);
        cp = cp + emit_m_start_workers(buf, cp);
    }

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

    // ── Patch function addresses (IR_FNADDR movabs placeholders) ──
    // Each placeholder is a movabs r10, imm64 at an absolute buffer position.
    // Resolve the same way as call patches: user functions by name in
    // g_ir_func_name_idx/g_x86_func_cp, builtins via g_x86_func_offsets.
    fpi := 0; loop { if fpi >= g_x86_fnaddr_patch_count { break; }
        fp_pos := r64(g_x86_fnaddr_patch_pos, fpi * 8);
        fn_ni := r64(g_x86_fnaddr_patch_name, fpi * 8);
        fn_va : ., mut = 0;
        fcfi : ., mut = 0;
        loop { if fcfi >= g_ir_func_count { break; }
            name_at := r64(g_ir_func_name_idx, fcfi * 8);
            if str_eq(istr_get(name_at), istr_get(fn_ni)) != 0 {
                func_cp := r64(g_x86_func_cp, fcfi * 8);
                if func_cp > 0 { fn_va = TEXT_BASE + func_cp; }
                break; }
        fcfi = fcfi + 1; }
        // Fallback: search g_x86_func_offsets for builtins
        if fn_va == 0 {
            bfi3 : ., mut = 0;
            loop { if bfi3 >= g_x86_func_off_count { break; }
                if str_eq(istr_get(r64(g_x86_func_offsets, bfi3*16)), istr_get(fn_ni)) != 0 {
                    func_off := r64(g_x86_func_offsets, bfi3*16+8);
                    target_pos := 176 + func_off;
                    if target_pos > 0 && target_pos < cp { fn_va = TEXT_BASE + target_pos; }
                    break; }
            bfi3 = bfi3 + 1; }
        }
        if fn_va > 0 { w64(buf, fp_pos + 2, fn_va); }  // imm64 placeholder starts after the 49 BB opcode
    fpi = fpi + 1; }
    g_x86_fnaddr_patch_count = 0;

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

    // ── HIT const pool（M1 Task 3 合成层：lower 常量池 → rodata）──
    // 池引用（mov r64, [rip+disp32] 占位）在函数发射期间记录（instr.cr 编码器）；
    // 字符串区定稿后回填 disp（池区紧随字符串，8B/槽、8 对齐不破）。
    hpr : ., mut = 0;
    loop { if hpr >= g_hit_pool_patch_count { break; }
        pp := r64(g_hit_pool_patch, hpr * 16);
        pk := r64(g_hit_pool_patch, hpr * 16 + 8);
        rel := cp + pk * 8 - (pp + 7);
        w32(buf, pp + 3, rel);
        hpr = hpr + 1; }
    g_hit_pool_patch_count = 0;
    hpk : ., mut = 0;
    loop { if hpk >= g_hit_pool_count { break; }
        w64(buf, cp + hpk * 8, r64(g_hit_pool, hpk * 8));
        hpk = hpk + 1; }
    cp = cp + g_hit_pool_count * 8;

    // ── Recompute bss_va after all code emitted ──
    // total_code from Phase 2 underestimates; use actual cp for precise calculation.
    // +1 ensures BSS is on a different page from code.
    bss_va = ((TEXT_BASE + cp + 4096 + 4095) / 4096) * 4096;

    // The allocator was emitted earlier with a provisional BSS address.
    // Re-emit it in place now that the final data-segment VA is known.
    emit_alloc_body(buf, alloc_start, bss_va, globals_size);

    // Re-emit heap_expand with correct BSS VA
    emit_heap_expand(buf, heap_expand_start, bss_va);

    // Re-emit g_set_curg/g_get_curg stubs with the final current_g BSS VA.
    // Slot sits at the end of the globals region (globals_size includes +8).
    if g_x86_emit_rt_stubs != 0 && g_curg_stub_start >= 0 {
        curg_va := bss_va + 16 + globals_size - 8;
        emit_curg_stubs(buf, g_curg_stub_start, curg_va);
    }

    // Patch call to heap_expand inside alloc body (re-emit wrote placeholder offset 0)
    if g_heap_expand_call_pos >= 0 {
        rel_he_call := heap_expand_start - (g_heap_expand_call_pos + 5);
        w32(buf, g_heap_expand_call_pos + 1, rel_he_call);
        g_heap_expand_call_pos = -1;
    }

    // ── Allocate BSS for globals ──
    gi2 := 0; goff : ., mut = 0;
    loop { if gi2 >= g_ir_global_count { break; }
        gv2 := r64(g_ir_globals, gi2 * 24 + 8);
        if gv2 >= 0 { grow_global_off(gv2 + 1); w64(g_x86_global_off, gv2 * 8, goff); goff = goff + 8; }
    gi2 = gi2 + 1; }

    // ── Patch global variable RIP-relative references ──
    rpi2 := 0;
    loop { if rpi2 >= g_x86_rip_patch_count { break; }
        ppos := r64(g_x86_rip_patch_pos, rpi2 * 8);
        gvi := r64(g_x86_rip_patch_globals, rpi2 * 8);
        // Verify: buffer at ppos-3 should contain LEA prefix (0x4C or 0x4D for REX.WR/WRB)
        lea_check := bu8(buf, ppos - 3);
        if lea_check != 72 && lea_check != 73 && lea_check != 76 && lea_check != 77 && lea_check != 74 && lea_check != 78 && lea_check != 79 && lea_check != 75 {
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
            rb0 := bu8(buf, ppos); rb1 := bu8(buf, ppos + 1);
            rb2 := bu8(buf, ppos + 2); rb3 := bu8(buf, ppos + 3);
            rbv : ., mut = rb0 + rb1 * 256 + rb2 * 65536;
            if rb3 >= 128 { rbv = rbv + (rb3 - 256) * 16777216; }
            else { rbv = rbv + rb3 * 16777216; }
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
