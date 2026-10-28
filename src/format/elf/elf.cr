// === elf.cr ===
// ELF container, sections, program headers, elf_gen, and the allocator body for
// x86-64.
//
// The _start emission sequence is in src/os/linux/entry.cr. Function frames
// (size accounting, prologue, epilogue, and tail blocks) are in
// src/arch/x86_64/frame.cr; this file does not compute frame sizes.
//
// Depends on instr.cr for instruction sizes and emission, frame.cr for frame
// layout, and backend/resolve.cr for labels.
// ── ELF constants (x86-64) ──
ET_EXEC : int = 2
EM_X86_64 : int = 62
PT_LOAD : int = 1
PF_RX : int = 5
PF_RW : int = 6

// Avoid the name r16: Intel syntax parses `call r16` as a register operand.
fn read_u16(buf: string, pos: int) -> int:
    return bu8(buf,pos) + bu8(buf,pos+1)*256

TEXT_BASE : int = 4194304  // 0x400000 - base address of code segment

fn w8_signed(buf: string, pos: int, val: int):
    w32(buf, pos, val)

// ── Allocator body encoding primitives ──
// Register numbers follow the x86 encoding (0=rax, 1=rcx, 2=rdx, 3=rbx,
// 4=rsp, 5=rbp, 6=rsi, 7=rdi, 8..15=r8..r15). The allocator body uses only
// caller-saved registers, so no frame setup is needed. Each helper returns the
// number of bytes written.

fn ea_rex(buf: string, pos: int, w: int, r: int, x: int, b: int) -> int:
    w8(buf, pos, 64 + w * 8 + r * 4 + x * 2 + b)
    return 1

fn ea_modrm(buf: string, pos: int, m: int, reg: int, rm: int) -> int:
    w8(buf, pos, m * 64 + reg * 8 + rm)
    return 1

fn ea_mov_rr(buf: string, pos: int, dst: int, src: int) -> int:
    cp := pos
    cp = cp + ea_rex(buf, cp, 1, src / 8, 0, dst / 8)
    w8(buf, cp, 137)
    cp = cp + 1
    cp = cp + ea_modrm(buf, cp, 3, src % 8, dst % 8)
    return cp - pos

fn ea_mov_rip_load(buf: string, pos: int, dst: int, gid: int) -> int:
    cp := pos
    cp = cp + ea_rex(buf, cp, 1, dst / 8, 0, 0)
    w8(buf, cp, 139)
    cp = cp + 1
    cp = cp + ea_modrm(buf, cp, 0, dst % 8, 5)
    rip := cp
    e2_w32(buf, cp, 0)
    cp = cp + 4
    grow_rip_patch(g_x86_rip_patch_count + 1)
    cell_store(g_x86_rip_patch_pos, g_x86_rip_patch_count * 8, rip)
    cell_store(g_x86_rip_patch_globals, g_x86_rip_patch_count * 8, gid)
    g_x86_rip_patch_count = g_x86_rip_patch_count + 1
    return cp - pos

fn ea_mov_rip_store(buf: string, pos: int, src: int, gid: int) -> int:
    cp := pos
    cp = cp + ea_rex(buf, cp, 1, src / 8, 0, 0)
    w8(buf, cp, 137)
    cp = cp + 1
    cp = cp + ea_modrm(buf, cp, 0, src % 8, 5)
    rip := cp
    e2_w32(buf, cp, 0)
    cp = cp + 4
    grow_rip_patch(g_x86_rip_patch_count + 1)
    cell_store(g_x86_rip_patch_pos, g_x86_rip_patch_count * 8, rip)
    cell_store(g_x86_rip_patch_globals, g_x86_rip_patch_count * 8, gid)
    g_x86_rip_patch_count = g_x86_rip_patch_count + 1
    return cp - pos

fn ea_mov_load(buf: string, pos: int, dst: int, base: int) -> int:
    cp := pos
    cp = cp + ea_rex(buf, cp, 1, dst / 8, 0, base / 8)
    w8(buf, cp, 139)
    cp = cp + 1
    cp = cp + ea_modrm(buf, cp, 0, dst % 8, base % 8)
    return cp - pos

fn ea_mov_load_index8(buf: string, pos: int, dst: int, base: int, index: int) -> int:
    cp := pos
    cp = cp + ea_rex(buf, cp, 1, dst / 8, index / 8, base / 8)
    w8(buf, cp, 139)
    cp = cp + 1
    cp = cp + ea_modrm(buf, cp, 0, dst % 8, 4)
    w8(buf, cp, 3 * 64 + (index % 8) * 8 + base % 8)
    cp = cp + 1
    return cp - pos

fn ea_mov_store_index8(buf: string, pos: int, base: int, index: int, src: int) -> int:
    cp := pos
    cp = cp + ea_rex(buf, cp, 1, src / 8, index / 8, base / 8)
    w8(buf, cp, 137)
    cp = cp + 1
    cp = cp + ea_modrm(buf, cp, 0, src % 8, 4)
    w8(buf, cp, 3 * 64 + (index % 8) * 8 + base % 8)
    cp = cp + 1
    return cp - pos

fn ea_lea_rip(buf: string, pos: int, dst: int, gid: int) -> int:
    cp := pos
    cp = cp + ea_rex(buf, cp, 1, dst / 8, 0, 0)
    w8(buf, cp, 141)
    cp = cp + 1
    cp = cp + ea_modrm(buf, cp, 0, dst % 8, 5)
    rip := cp
    e2_w32(buf, cp, 0)
    cp = cp + 4
    grow_rip_patch(g_x86_rip_patch_count + 1)
    cell_store(g_x86_rip_patch_pos, g_x86_rip_patch_count * 8, rip)
    cell_store(g_x86_rip_patch_globals, g_x86_rip_patch_count * 8, gid)
    g_x86_rip_patch_count = g_x86_rip_patch_count + 1
    return cp - pos

fn ea_lea_base_index8(buf: string, pos: int, dst: int, base: int, index: int, disp: int) -> int:
    cp := pos
    cp = cp + ea_rex(buf, cp, 1, dst / 8, index / 8, base / 8)
    w8(buf, cp, 141)
    cp = cp + 1
    cp = cp + ea_modrm(buf, cp, 1, dst % 8, 4)
    w8(buf, cp, (index % 8) * 8 + base % 8)
    cp = cp + 1
    w8(buf, cp, disp % 256)
    cp = cp + 1
    return cp - pos

fn ea_lea_base_disp8(buf: string, pos: int, dst: int, base: int, disp: int) -> int:
    cp := pos
    cp = cp + ea_rex(buf, cp, 1, dst / 8, 0, base / 8)
    w8(buf, cp, 141)
    cp = cp + 1
    cp = cp + ea_modrm(buf, cp, 1, dst % 8, base % 8)
    w8(buf, cp, disp % 256)
    cp = cp + 1
    return cp - pos

fn ea_add_imm8(buf: string, pos: int, dst: int, imm: int) -> int:
    cp := pos
    cp = cp + ea_rex(buf, cp, 1, 0, 0, dst / 8)
    w8(buf, cp, 131)
    cp = cp + 1
    cp = cp + ea_modrm(buf, cp, 3, 0, dst % 8)
    w8(buf, cp, imm % 256)
    cp = cp + 1
    return cp - pos

fn ea_and_imm8(buf: string, pos: int, dst: int, imm: int) -> int:
    cp := pos
    cp = cp + ea_rex(buf, cp, 1, 0, 0, dst / 8)
    w8(buf, cp, 131)
    cp = cp + 1
    cp = cp + ea_modrm(buf, cp, 3, 4, dst % 8)
    w8(buf, cp, imm % 256)
    cp = cp + 1
    return cp - pos

fn ea_add_rr(buf: string, pos: int, dst: int, src: int) -> int:
    cp := pos
    cp = cp + ea_rex(buf, cp, 1, src / 8, 0, dst / 8)
    w8(buf, cp, 1)
    cp = cp + 1
    cp = cp + ea_modrm(buf, cp, 3, src % 8, dst % 8)
    return cp - pos

fn ea_cmp_rr(buf: string, pos: int, left: int, right: int) -> int:
    cp := pos
    cp = cp + ea_rex(buf, cp, 1, right / 8, 0, left / 8)
    w8(buf, cp, 57)
    cp = cp + 1
    cp = cp + ea_modrm(buf, cp, 3, right % 8, left % 8)
    return cp - pos

fn ea_test_rr(buf: string, pos: int, a: int, b: int) -> int:
    cp := pos
    cp = cp + ea_rex(buf, cp, 1, b / 8, 0, a / 8)
    w8(buf, cp, 133)
    cp = cp + 1
    cp = cp + ea_modrm(buf, cp, 3, b % 8, a % 8)
    return cp - pos

fn ea_ja8(buf: string, pos: int, rel: int) -> int:
    w8(buf, pos, 119)
    w8(buf, pos + 1, rel % 256)
    return 2

fn ea_jbe8(buf: string, pos: int, rel: int) -> int:
    w8(buf, pos, 118)
    w8(buf, pos + 1, rel % 256)
    return 2

fn ea_jmp8(buf: string, pos: int, rel: int) -> int:
    w8(buf, pos, 235)
    w8(buf, pos + 1, rel % 256)
    return 2

fn ea_mul(buf: string, pos: int, src: int) -> int:
    cp := pos
    cp = cp + ea_rex(buf, cp, 1, 0, 0, src / 8)
    w8(buf, cp, 247)
    cp = cp + 1
    cp = cp + ea_modrm(buf, cp, 3, 4, src % 8)
    return cp - pos

fn ea_mov_store(buf: string, pos: int, base: int, src: int) -> int:
    cp := pos
    cp = cp + ea_rex(buf, cp, 1, src / 8, 0, base / 8)
    w8(buf, cp, 137)
    cp = cp + 1
    cp = cp + ea_modrm(buf, cp, 0, src % 8, base % 8)
    return cp - pos

fn ea_mov_store_disp8(buf: string, pos: int, base: int, disp: int, src: int) -> int:
    cp := pos
    cp = cp + ea_rex(buf, cp, 1, src / 8, 0, base / 8)
    w8(buf, cp, 137)
    cp = cp + 1
    cp = cp + ea_modrm(buf, cp, 1, src % 8, base % 8)
    w8(buf, cp, disp % 256)
    cp = cp + 1
    return cp - pos

fn ea_cmp_imm32(buf: string, pos: int, dst: int, imm: int) -> int:
    cp := pos
    cp = cp + ea_rex(buf, cp, 1, 0, 0, dst / 8)
    w8(buf, cp, 129)
    cp = cp + 1
    cp = cp + ea_modrm(buf, cp, 3, 7, dst % 8)
    e2_w32(buf, cp, imm)
    cp = cp + 4
    return cp - pos

fn ea_jns8(buf: string, pos: int, rel: int) -> int:
    w8(buf, pos, 121)
    w8(buf, pos + 1, rel % 256)
    return 2

fn ea_jl32(buf: string, pos: int, rel: int) -> int:
    w8(buf, pos, 15)
    w8(buf, pos + 1, 140)
    e2_w32(buf, pos + 2, rel)
    return 6

fn ea_ud2(buf: string, pos: int) -> int:
    w8(buf, pos, 15)
    w8(buf, pos + 1, 11)
    return 2

fn ea_shr_imm8(buf: string, pos: int, dst: int, imm: int) -> int:
    cp := pos
    cp = cp + ea_rex(buf, cp, 1, 0, 0, dst / 8)
    w8(buf, cp, 193)
    cp = cp + 1
    cp = cp + ea_modrm(buf, cp, 3, 5, dst % 8)
    w8(buf, cp, imm % 256)
    cp = cp + 1
    return cp - pos

fn ea_shl_imm8(buf: string, pos: int, dst: int, imm: int) -> int:
    cp := pos
    cp = cp + ea_rex(buf, cp, 1, 0, 0, dst / 8)
    w8(buf, cp, 193)
    cp = cp + 1
    cp = cp + ea_modrm(buf, cp, 3, 4, dst % 8)
    w8(buf, cp, imm % 256)
    cp = cp + 1
    return cp - pos

fn ea_imul_imm8(buf: string, pos: int, dst: int, src: int, imm: int) -> int:
    cp := pos
    cp = cp + ea_rex(buf, cp, 1, dst / 8, 0, src / 8)
    w8(buf, cp, 107)
    cp = cp + 1
    cp = cp + ea_modrm(buf, cp, 3, dst % 8, src % 8)
    w8(buf, cp, imm % 256)
    cp = cp + 1
    return cp - pos

fn ea_mov_imm32(buf: string, pos: int, dst: int, imm: int) -> int:
    cp := pos
    cp = cp + ea_rex(buf, cp, 1, 0, 0, dst / 8)
    w8(buf, cp, 184 + dst % 8)
    cp = cp + 1
    e2_w32(buf, cp, imm)
    cp = cp + 4
    return cp - pos

fn ea_cmp_imm8(buf: string, pos: int, dst: int, imm: int) -> int:
    cp := pos
    cp = cp + ea_rex(buf, cp, 1, 0, 0, dst / 8)
    w8(buf, cp, 131)
    cp = cp + 1
    cp = cp + ea_modrm(buf, cp, 3, 7, dst % 8)
    w8(buf, cp, imm % 256)
    cp = cp + 1
    return cp - pos

fn ea_add_imm32(buf: string, pos: int, dst: int, imm: int) -> int:
    cp := pos
    cp = cp + ea_rex(buf, cp, 1, 0, 0, dst / 8)
    w8(buf, cp, 129)
    cp = cp + 1
    cp = cp + ea_modrm(buf, cp, 3, 0, dst % 8)
    e2_w32(buf, cp, imm)
    cp = cp + 4
    return cp - pos

fn ea_sub_rr(buf: string, pos: int, dst: int, src: int) -> int:
    cp := pos
    cp = cp + ea_rex(buf, cp, 1, src / 8, 0, dst / 8)
    w8(buf, cp, 41)
    cp = cp + 1
    cp = cp + ea_modrm(buf, cp, 3, src % 8, dst % 8)
    return cp - pos

fn ea_jne8(buf: string, pos: int, rel: int) -> int:
    w8(buf, pos, 117)
    w8(buf, pos + 1, rel % 256)
    return 2

fn ea_jae8(buf: string, pos: int, rel: int) -> int:
    w8(buf, pos, 115)
    w8(buf, pos + 1, rel % 256)
    return 2

fn ea_jge32(buf: string, pos: int, rel: int) -> int:
    w8(buf, pos, 15)
    w8(buf, pos + 1, 141)
    e2_w32(buf, pos + 2, rel)
    return 6

fn ea_ja32(buf: string, pos: int, rel: int) -> int:
    w8(buf, pos, 15)
    w8(buf, pos + 1, 135)
    e2_w32(buf, pos + 2, rel)
    return 6

fn ea_jb32(buf: string, pos: int, rel: int) -> int:
    w8(buf, pos, 15)
    w8(buf, pos + 1, 130)
    e2_w32(buf, pos + 2, rel)
    return 6

fn ea_jbe32(buf: string, pos: int, rel: int) -> int:
    w8(buf, pos, 15)
    w8(buf, pos + 1, 134)
    e2_w32(buf, pos + 2, rel)
    return 6

fn ea_jmp32(buf: string, pos: int, rel: int) -> int:
    w8(buf, pos, 233)
    e2_w32(buf, pos + 1, rel)
    return 5

fn ea_inc(buf: string, pos: int, dst: int) -> int:
    cp := pos
    cp = cp + ea_rex(buf, cp, 1, 0, 0, dst / 8)
    w8(buf, cp, 255)
    cp = cp + 1
    cp = cp + ea_modrm(buf, cp, 3, 0, dst % 8)
    return cp - pos




// Emit arena-aware dual-path allocator function body
// Checks g_current_arena: if >=0 uses arena bump, otherwise global bump.
// Returns bytes written.
fn emit_alloc_body(buf: string, pos: int, bss_va: int, globals_size: int) -> int:
    // When arena globals aren't registered (e.g. non-static builds), emit the
    // original simple bump allocator to avoid relying on unpatched rip-relatives.
    if gv_current_arena < 0:
        return emit_alloc_body_simple(buf, pos, bss_va, globals_size)

    // The arena path is straight-line code. Failure is a trap, never a return
    // of 0 and never a fallback to the global heap.
    //
    // The register assignment is computed by StubAllocator. Pins hold the
    // registers required by mul (rax/r10) and keep the base/cursor values out
    // of the registers that rep stosb writes (rdi/rcx/rax).
    a := sr_new(30, 9, 7)
    a.reg(0, 8, CAG_REG_CALLEE)
    a.reg(1, 10, CAG_REG_CALLEE)
    a.reg(2, 0, CAG_REG_CALLEE)
    a.reg(3, 11, CAG_REG_CALLEE)
    a.reg(4, 9, CAG_REG_CALLEE)
    a.reg(6, 6, CAG_REG_CALLEE)
    a.reg(7, 2, CAG_REG_CALLEE)

    // v0 size, v1 arena, v2 max_size, v3 base, v4 class, v5 index,
    // v6 aligned, v7 new cursor, v8 unused. Seven registers: v5 spills.
    a.read(0, 2)
    a.read(0, 6)
    a.read(0, 7)
    a.write(0, 0)
    a.pin(0, 0, 8)
    a.write(1, 1)
    a.pin(1, 1, 10)
    a.read(2, 1)
    a.read(3, 1)
    a.write(4, 2)
    a.pin(4, 2, 0)
    a.read(5, 2)
    a.read(5, 1)
    a.write(6, 3)
    a.pin(6, 3, 11)
    a.read(7, 3)
    a.read(7, 2)
    a.write(7, 3)
    a.write(8, 8)
    a.read(9, 8)
    a.read(9, 1)
    a.write(9, 4)
    a.pin(9, 4, 9)
    a.pin(12, 6, 6)
    a.pin(15, 7, 2)
    a.write(10, 8)
    a.read(11, 8)
    a.read(11, 1)
    a.write(11, 5)
    a.read(12, 0)
    a.write(12, 6)
    a.read(13, 6)
    a.write(13, 6)
    a.read(14, 6)
    a.write(14, 6)
    a.read(15, 4)
    a.write(15, 7)
    a.read(16, 7)
    a.read(16, 6)
    a.write(16, 7)
    a.read(17, 7)
    a.read(17, 5)
    a.read(18, 7)
    a.write(19, 8)
    a.read(20, 8)
    a.read(20, 1)
    a.read(20, 7)
    a.read(21, 3)
    a.read(21, 4)
    a.read(22, 0)
    a.read(26, 3)
    a.read(26, 4)
    a.read(27, 0)
    a.read(28, 3)
    a.read(28, 4)
    if a.run() != SR_OK:
        return emit_alloc_body_simple(buf, pos, bss_va, globals_size)

    r0 := a.assigned(0)
    r1 := a.assigned(1)
    r2 := a.assigned(2)
    r3 := a.assigned(3)
    r4 := a.assigned(4)
    r5 := a.assigned(5)
    r6 := a.assigned(6)
    r7 := a.assigned(7)
    r8 := a.assigned(8)
    r14 := 14
    r15 := 15

    cp : ., mut = 0
    fva := TEXT_BASE + pos

    // Preserve the callee-saved scratch pair used for the home slot. Two pushes
    // keep the stack 16-byte aligned for the heap_expand call.
    w8(buf, pos + cp, 65)
    w8(buf, pos + cp + 1, 86)
    cp = cp + 2
    w8(buf, pos + cp, 65)
    w8(buf, pos + cp + 1, 87)
    cp = cp + 2

    // 0: reject requests above 64MB.
    cp = cp + ea_cmp_imm32(buf, pos + cp, 7, 67108864)
    j0 := cp
    cp = cp + ea_jbe8(buf, pos + cp, 0)
    cp = cp + ea_mov_rr(buf, pos + cp, 0, 7)
    cp = cp + ea_mov_rip_store(buf, pos + cp, 0, gv_alloc_fail_request)
    cp = cp + ea_mov_imm32(buf, pos + cp, 0, -1)
    cp = cp + ea_mov_rip_store(buf, pos + cp, 0, gv_alloc_fail_class)
    cp = cp + ea_mov_imm32(buf, pos + cp, 0, 0)
    cp = cp + ea_mov_rip_store(buf, pos + cp, 0, gv_alloc_fail_cursor)
    cp = cp + ea_mov_rip_store(buf, pos + cp, 0, gv_alloc_fail_limit)
    cp = cp + ea_ud2(buf, pos + cp)
    w8(buf, pos + j0 + 1, (cp - (j0 + 2)) % 256)

    // 1: size, arena index. A missing arena takes the global bump path.
    cp = cp + ea_mov_rr(buf, pos + cp, r0, 7)
    cp = cp + ea_mov_rip_load(buf, pos + cp, r1, gv_current_arena)
    cp = cp + ea_test_rr(buf, pos + cp, r1, r1)
    cp = cp + ea_mov_rr(buf, pos + cp, 7, r0)
    cp = cp + ea_mov_rr(buf, pos + cp, 9, r0)
    j1 := cp
    cp = cp + ea_jl32(buf, pos + cp, 0)

    // 2: base = segment_base[slot / 8] + (slot % 8) * 128KB.
    cp = cp + ea_mov_rip_load(buf, pos + cp, 5, gv_arena_slot)
    cp = cp + ea_mov_load_index8(buf, pos + cp, 5, 5, r1)
    cp = cp + ea_cmp_imm8(buf, pos + cp, 5, 0)
    jslot_bad := cp
    cp = cp + ea_jl32(buf, pos + cp, 0)
    cp = cp + ea_mov_rr(buf, pos + cp, 15, 5)
    cp = cp + ea_shr_imm8(buf, pos + cp, 15, 3)
    cp = cp + ea_and_imm8(buf, pos + cp, 5, 7)
    cp = cp + ea_mov_rip_load(buf, pos + cp, r3, gv_segment_base)
    cp = cp + ea_mov_load_index8(buf, pos + cp, r3, r3, 15)
    cp = cp + ea_shl_imm8(buf, pos + cp, 5, 20)
    cp = cp + ea_add_rr(buf, pos + cp, r3, 5)
    cp = cp + ea_mov_imm32(buf, pos + cp, r2, 1048576)
    cp = cp + ea_add_rr(buf, pos + cp, r2, r3)

    // 3: slot_end = slot_base + max_size.
    cp = cp + ea_mov_rip_load(buf, pos + cp, r2, gv_arena_max_size)
    cp = cp + ea_add_rr(buf, pos + cp, r2, r3)

    // Static-peak arenas bypass size classes and use one bump cursor.
    cp = cp + ea_mov_rip_load(buf, pos + cp, 5, gv_arena_static)
    cp = cp + ea_mov_load_index8(buf, pos + cp, 5, 5, r1)
    cp = cp + ea_cmp_imm8(buf, pos + cp, 5, 0)
    jstatic := cp
    cp = cp + ea_jne8(buf, pos + cp, 0)

    // 4: aligned = align_up(size + 8, 8).
    cp = cp + ea_mov_rr(buf, pos + cp, r6, r0)
    cp = cp + ea_add_imm8(buf, pos + cp, r6, 15)
    cp = cp + ea_and_imm8(buf, pos + cp, r6, 248)

    // 5: class = lookup[min(aligned >> 4, 255)].
    cp = cp + ea_mov_rr(buf, pos + cp, 15, r6)
    cp = cp + ea_shr_imm8(buf, pos + cp, 15, 4)
    cp = cp + ea_cmp_imm8(buf, pos + cp, 15, 255)
    jbe_small := cp
    cp = cp + ea_jbe32(buf, pos + cp, 0)
    cp = cp + ea_mov_imm32(buf, pos + cp, 15, 25)
    jmp_class_done := cp
    cp = cp + ea_jmp32(buf, pos + cp, 0)
    class_small := cp
    cp = cp + ea_mov_rip_load(buf, pos + cp, 14, gv_class_lookup)
    cp = cp + ea_mov_load_index8(buf, pos + cp, 15, 14, 15)
    class_done := cp
    cp = cp + ea_mov_rr(buf, pos + cp, r4, 15)
    w32(buf, pos + jbe_small + 2, class_small - (jbe_small + 6))
    w32(buf, pos + jmp_class_done + 1, class_done - (jmp_class_done + 5))

    // 6: idx = arena * 26 + class; class_base[idx] is the current chunk.
    cp = cp + ea_mov_rr(buf, pos + cp, 14, r1)
    cp = cp + ea_imul_imm8(buf, pos + cp, 14, 14, 26)
    cp = cp + ea_add_rr(buf, pos + cp, 14, r4)
    cp = cp + ea_mov_rip_store(buf, pos + cp, 14, gv_alloc_home_idx)
    cp = cp + ea_mov_rip_load(buf, pos + cp, 15, gv_class_base)
    cp = cp + ea_mov_load_index8(buf, pos + cp, r7, 15, 14)
    cp = cp + ea_cmp_imm8(buf, pos + cp, r7, 0)
    jge_base := cp
    cp = cp + ea_jge32(buf, pos + cp, 0)

    // 7: carve a new 4KB chunk from the current slot.
    chunk_alloc := cp
    // Large objects (28KB..128KB) take the current slot tail. If the tail is
    // too small, allocate a fresh slot first.
    cp = cp + ea_cmp_imm8(buf, pos + cp, r4, 25)
    jne_not_large := cp
    cp = cp + ea_jne8(buf, pos + cp, 0)
    cp = cp + ea_cmp_imm32(buf, pos + cp, r6, 28672)
    jbe_not_large2 := cp
    cp = cp + ea_jbe32(buf, pos + cp, 0)
    cp = cp + ea_mov_rip_load(buf, pos + cp, 5, gv_arena_max_size)
    cp = cp + ea_cmp_rr(buf, pos + cp, r6, 5)
    ja_cap_large := cp
    cp = cp + ea_ja32(buf, pos + cp, 0)
    cp = cp + ea_mov_rip_load(buf, pos + cp, 15, gv_arena_slot_cursor)
    cp = cp + ea_mov_load_index8(buf, pos + cp, 15, 15, r1)
    cp = cp + ea_sub_rr(buf, pos + cp, 5, 15)
    cp = cp + ea_cmp_rr(buf, pos + cp, r6, 5)
    jbe_large_fit := cp
    cp = cp + ea_jbe32(buf, pos + cp, 0)
    jmp_slot_large := cp
    cp = cp + ea_jmp32(buf, pos + cp, 0)
    large_fit := cp
    cp = cp + ea_mov_rr(buf, pos + cp, r7, r3)
    cp = cp + ea_add_rr(buf, pos + cp, r7, 15)
    cp = cp + ea_mov_rr(buf, pos + cp, 5, r2)
    cp = cp + ea_mov_rip_load(buf, pos + cp, 15, gv_class_base)
    cp = cp + ea_mov_store_index8(buf, pos + cp, 15, 14, r7)
    cp = cp + ea_mov_rip_load(buf, pos + cp, 15, gv_class_limit)
    cp = cp + ea_mov_store_index8(buf, pos + cp, 15, 14, 5)
    cp = cp + ea_mov_imm32(buf, pos + cp, 0, 0)
    cp = cp + ea_mov_rip_load(buf, pos + cp, 15, gv_class_cursor)
    cp = cp + ea_mov_store_index8(buf, pos + cp, 15, 14, 0)
    cp = cp + ea_mov_rip_load(buf, pos + cp, 5, gv_arena_max_size)
    cp = cp + ea_mov_rip_load(buf, pos + cp, 15, gv_arena_slot_cursor)
    cp = cp + ea_mov_store_index8(buf, pos + cp, 15, r1, 5)
    jmp_base_large := cp
    cp = cp + ea_jmp32(buf, pos + cp, 0)
    not_large := cp
    w8(buf, pos + jne_not_large + 1, (not_large - (jne_not_large + 2)) % 256)
    w32(buf, pos + jbe_not_large2 + 2, not_large - (jbe_not_large2 + 6))
    cp = cp + ea_mov_rip_load(buf, pos + cp, 15, gv_arena_slot_cursor)
    cp = cp + ea_mov_load_index8(buf, pos + cp, r5, 15, r1)
    cp = cp + ea_mov_rr(buf, pos + cp, r7, r3)
    cp = cp + ea_add_rr(buf, pos + cp, r7, r5)
    cp = cp + ea_mov_rr(buf, pos + cp, r5, r7)
    cp = cp + ea_add_imm32(buf, pos + cp, r5, 4096)
    cp = cp + ea_cmp_rr(buf, pos + cp, r5, r2)
    ja_slot := cp
    cp = cp + ea_ja32(buf, pos + cp, 0)
    cp = cp + ea_sub_rr(buf, pos + cp, r5, r3)
    cp = cp + ea_mov_rip_load(buf, pos + cp, 15, gv_arena_slot_cursor)
    cp = cp + ea_mov_store_index8(buf, pos + cp, 15, r1, r5)
    cp = cp + ea_mov_rip_load(buf, pos + cp, 15, gv_class_base)
    cp = cp + ea_mov_store_index8(buf, pos + cp, 15, r14, r7)
    cp = cp + ea_mov_rr(buf, pos + cp, r5, r7)
    cp = cp + ea_add_imm32(buf, pos + cp, r5, 4096)
    cp = cp + ea_mov_rip_load(buf, pos + cp, 15, gv_class_limit)
    cp = cp + ea_mov_store_index8(buf, pos + cp, 15, r14, r5)
    cp = cp + ea_mov_imm32(buf, pos + cp, 0, 0)
    cp = cp + ea_mov_rip_load(buf, pos + cp, 15, gv_class_cursor)
    cp = cp + ea_mov_store_index8(buf, pos + cp, 15, r14, 0)

    base_ok := cp
    cp = cp + ea_mov_rip_load(buf, pos + cp, 15, gv_class_cursor)
    cp = cp + ea_mov_load_index8(buf, pos + cp, 0, 15, r14)
    cp = cp + ea_mov_rr(buf, pos + cp, 15, r6)
    cp = cp + ea_add_rr(buf, pos + cp, 15, 0)
    cp = cp + ea_mov_rip_load(buf, pos + cp, 5, gv_class_limit)
    cp = cp + ea_mov_load_index8(buf, pos + cp, 5, 5, r14)
    cp = cp + ea_sub_rr(buf, pos + cp, 5, r7)
    cp = cp + ea_cmp_rr(buf, pos + cp, 15, 5)
    ja_class := cp
    cp = cp + ea_ja32(buf, pos + cp, 0)
    cp = cp + ea_mov_rip_load(buf, pos + cp, 5, gv_class_cursor)
    cp = cp + ea_mov_store_index8(buf, pos + cp, 5, r14, 15)
    cp = cp + ea_mov_rr(buf, pos + cp, r6, 0)
    jmp_ready := cp
    cp = cp + ea_jmp32(buf, pos + cp, 0)

    slot_full := cp
    cp = cp + ea_mov_rip_load(buf, pos + cp, 5, gv_arena_slot_free)
    cp = cp + ea_cmp_imm8(buf, pos + cp, 5, 0)
    jl_bump := cp
    cp = cp + ea_jl32(buf, pos + cp, 0)
    cp = cp + ea_mov_rip_load(buf, pos + cp, 15, gv_arena_slot_next)
    cp = cp + ea_mov_load_index8(buf, pos + cp, 15, 15, 5)
    cp = cp + ea_mov_rip_store(buf, pos + cp, 15, gv_arena_slot_free)
    jmp_have := cp
    cp = cp + ea_jmp32(buf, pos + cp, 0)
    slot_bump := cp
    cp = cp + ea_mov_rip_load(buf, pos + cp, 5, gv_arena_slot_count)
    cp = cp + ea_mov_rip_load(buf, pos + cp, 15, gv_arena_pool_slots)
    cp = cp + ea_cmp_rr(buf, pos + cp, 5, 15)
    jb_have_slot := cp
    cp = cp + ea_jb32(buf, pos + cp, 0)
    grow_call := cp
    grow_call_patch(g_x86_call_patch_count + 1)
    cell_store(g_x86_call_patch_pos, g_x86_call_patch_count * 8, pos + cp)
    cell_store(g_x86_call_patch_name, g_x86_call_patch_count * 8, str_intern("arena_grow_pool"))
    g_x86_call_patch_count = g_x86_call_patch_count + 1
    w8(buf, pos + cp, 232)
    e2_w32(buf, pos + cp + 1, 0)
    cp = cp + 5
    cp = cp + ea_mov_rip_load(buf, pos + cp, 5, gv_arena_slot_count)
    slot_have := cp
    w32(buf, pos + jb_have_slot + 2, slot_have - (jb_have_slot + 6))
    cp = cp + ea_mov_rr(buf, pos + cp, 15, 5)
    cp = cp + ea_inc(buf, pos + cp, 15)
    cp = cp + ea_mov_rip_store(buf, pos + cp, 15, gv_arena_slot_count)
    cp = cp + ea_mov_rip_load(buf, pos + cp, 15, gv_arena_slot)
    cp = cp + ea_mov_load_index8(buf, pos + cp, 14, 15, r1)
    cp = cp + ea_mov_rip_load(buf, pos + cp, 15, gv_arena_slot_next)
    cp = cp + ea_mov_store_index8(buf, pos + cp, 15, 14, 5)
    cp = cp + ea_mov_imm32(buf, pos + cp, 0, -1)
    cp = cp + ea_mov_store_index8(buf, pos + cp, 15, 5, 0)
    cp = cp + ea_mov_rip_load(buf, pos + cp, 15, gv_arena_slot)
    cp = cp + ea_mov_store_index8(buf, pos + cp, 15, r1, 5)
    cp = cp + ea_mov_imm32(buf, pos + cp, 0, 0)
    cp = cp + ea_mov_rip_load(buf, pos + cp, 15, gv_arena_slot_cursor)
    cp = cp + ea_mov_store_index8(buf, pos + cp, 15, r1, 0)
    cp = cp + ea_mov_rip_load(buf, pos + cp, 0, gv_arena_max_size)
    cp = cp + ea_mul(buf, pos + cp, 5)
    cp = cp + ea_mov_rip_load(buf, pos + cp, 3, gv_arena_pool_data)
    cp = cp + ea_add_rr(buf, pos + cp, 3, 0)
    cp = cp + ea_mov_rip_load(buf, pos + cp, 2, gv_arena_max_size)
    cp = cp + ea_add_rr(buf, pos + cp, 2, 3)
    cp = cp + ea_mov_rip_load(buf, pos + cp, 14, gv_alloc_home_idx)
    jmp_chunk := cp
    cp = cp + ea_jmp32(buf, pos + cp, 0)

    capacity_full := cp
    cp = cp + ea_mov_rr(buf, pos + cp, 0, r0)
    cp = cp + ea_mov_rip_store(buf, pos + cp, 0, gv_alloc_fail_request)
    cp = cp + ea_mov_imm32(buf, pos + cp, 0, -1)
    cp = cp + ea_mov_rip_store(buf, pos + cp, 0, gv_alloc_fail_class)
    cp = cp + ea_mov_rr(buf, pos + cp, 0, 5)
    cp = cp + ea_mov_rip_store(buf, pos + cp, 0, gv_alloc_fail_cursor)
    cp = cp + ea_mov_rip_load(buf, pos + cp, 0, gv_arena_pool_slots)
    cp = cp + ea_mov_rip_store(buf, pos + cp, 0, gv_alloc_fail_limit)
    cp = cp + ea_ud2(buf, pos + cp)

    w32(buf, pos + ja_cap_large + 2, capacity_full - (ja_cap_large + 6))
    w32(buf, pos + jslot_bad + 2, capacity_full - (jslot_bad + 6))
    w32(buf, pos + jl_bump + 2, slot_bump - (jl_bump + 6))
    w32(buf, pos + jmp_have + 1, slot_have - (jmp_have + 5))
    w32(buf, pos + jmp_chunk + 1, chunk_alloc - (jmp_chunk + 5))
    w32(buf, pos + jmp_slot_large + 1, slot_full - (jmp_slot_large + 5))

    class_full := cp
    cp = cp + ea_mov_rr(buf, pos + cp, 0, r0)
    cp = cp + ea_mov_rip_store(buf, pos + cp, 0, gv_alloc_fail_request)
    cp = cp + ea_mov_imm32(buf, pos + cp, 0, -1)
    cp = cp + ea_mov_rip_store(buf, pos + cp, 0, gv_alloc_fail_class)
    cp = cp + ea_mov_rr(buf, pos + cp, 0, 0)
    cp = cp + ea_mov_rip_store(buf, pos + cp, 0, gv_alloc_fail_cursor)
    cp = cp + ea_mov_rr(buf, pos + cp, 0, 5)
    cp = cp + ea_mov_rip_store(buf, pos + cp, 0, gv_alloc_fail_limit)
    cp = cp + ea_ud2(buf, pos + cp)

    w32(buf, pos + jmp_base_large + 1, base_ok - (jmp_base_large + 5))
    alloc_ready := cp
    w32(buf, pos + jge_base + 2, base_ok - (jge_base + 6))
    w32(buf, pos + ja_slot + 2, slot_full - (ja_slot + 6))
    w32(buf, pos + ja_class + 2, class_full - (ja_class + 6))
    w32(buf, pos + jmp_ready + 1, alloc_ready - (jmp_ready + 5))

    // 9: zero the data bytes and write the hidden length header.
    cp = cp + ea_lea_base_index8(buf, pos + cp, 7, r7, r6, 8)
    cp = cp + ea_mov_rr(buf, pos + cp, 1, r0)
    w8(buf, pos + cp, 49)
    w8(buf, pos + cp + 1, 192)
    cp = cp + 2
    w8(buf, pos + cp, 252)
    cp = cp + 1
    w8(buf, pos + cp, 243)
    w8(buf, pos + cp + 1, 170)
    cp = cp + 2
    cp = cp + ea_lea_base_index8(buf, pos + cp, 1, r7, r6, 0)
    cp = cp + ea_mov_store(buf, pos + cp, 1, r0)
    cp = cp + ea_lea_base_index8(buf, pos + cp, 0, r7, r6, 8)
    w8(buf, pos + cp, 65)
    w8(buf, pos + cp + 1, 94)
    cp = cp + 2
    w8(buf, pos + cp, 65)
    w8(buf, pos + cp + 1, 95)
    cp = cp + 2
    w8(buf, pos + cp, 195)
    cp = cp + 1

    // ── Static peak: one bump cursor, no class lookup. ──
    static_path := cp
    cp = cp + ea_mov_rr(buf, pos + cp, r6, r0)
    cp = cp + ea_add_imm8(buf, pos + cp, r6, 15)
    cp = cp + ea_and_imm8(buf, pos + cp, r6, 248)
    cp = cp + ea_mov_rip_load(buf, pos + cp, 5, gv_arena_cursors)
    cp = cp + ea_mov_load_index8(buf, pos + cp, 5, 5, r1)
    cp = cp + ea_mov_rr(buf, pos + cp, 7, 5)
    cp = cp + ea_add_rr(buf, pos + cp, 7, r6)
    cp = cp + ea_mov_rip_load(buf, pos + cp, 15, gv_arena_sizes)
    cp = cp + ea_mov_load_index8(buf, pos + cp, 15, 15, r1)
    cp = cp + ea_cmp_rr(buf, pos + cp, 7, 15)
    jstatic_ok := cp
    cp = cp + ea_jbe8(buf, pos + cp, 0)
    cp = cp + ea_mov_rr(buf, pos + cp, 0, r0)
    cp = cp + ea_mov_rip_store(buf, pos + cp, 0, gv_alloc_fail_request)
    cp = cp + ea_mov_imm32(buf, pos + cp, 0, -1)
    cp = cp + ea_mov_rip_store(buf, pos + cp, 0, gv_alloc_fail_class)
    cp = cp + ea_mov_rr(buf, pos + cp, 0, 5)
    cp = cp + ea_mov_rip_store(buf, pos + cp, 0, gv_alloc_fail_cursor)
    cp = cp + ea_mov_rr(buf, pos + cp, 0, 15)
    cp = cp + ea_mov_rip_store(buf, pos + cp, 0, gv_alloc_fail_limit)
    cp = cp + ea_ud2(buf, pos + cp)
    static_ok := cp
    w8(buf, pos + jstatic_ok + 1, (static_ok - (jstatic_ok + 2)) % 256)
    w8(buf, pos + jstatic + 1, (static_path - (jstatic + 2)) % 256)
    cp = cp + ea_mov_rip_load(buf, pos + cp, 15, gv_arena_cursors)
    cp = cp + ea_mov_store_index8(buf, pos + cp, 15, r1, 7)
    cp = cp + ea_lea_base_index8(buf, pos + cp, 7, r3, 5, 8)
    cp = cp + ea_mov_rr(buf, pos + cp, 14, 7)
    cp = cp + ea_lea_base_index8(buf, pos + cp, 1, r3, 5, 0)
    cp = cp + ea_mov_store(buf, pos + cp, 1, r0)
    cp = cp + ea_mov_rr(buf, pos + cp, 1, r0)
    w8(buf, pos + cp, 49)
    w8(buf, pos + cp + 1, 192)
    cp = cp + 2
    w8(buf, pos + cp, 252)
    cp = cp + 1
    w8(buf, pos + cp, 243)
    w8(buf, pos + cp + 1, 170)
    cp = cp + 2
    cp = cp + ea_mov_rr(buf, pos + cp, 0, 14)
    w8(buf, pos + cp, 65)
    w8(buf, pos + cp + 1, 94)
    cp = cp + 2
    w8(buf, pos + cp, 65)
    w8(buf, pos + cp + 1, 95)
    cp = cp + 2
    w8(buf, pos + cp, 195)
    cp = cp + 1

    // ── .Lglobal: allocations made before an arena exists ──
    // The arena path and the global path are exclusive. r9 holds the original
    // size for the hidden header because r8 is reused as the saved heap_ptr.
    rel_gl := cp - (j1 + 6)
    w32(buf, pos + j1 + 2, rel_gl)

    // add rdi, 15; and rdi, -8
    w8(buf, pos + cp, 72)
    w8(buf, pos + cp + 1, 131)
    w8(buf, pos + cp + 2, 199)
    w8(buf, pos + cp + 3, 15)
    cp = cp + 4
    w8(buf, pos + cp, 72)
    w8(buf, pos + cp + 1, 131)
    w8(buf, pos + cp + 2, 231)
    w8(buf, pos + cp + 3, 248)
    cp = cp + 4

    // mov r11, [rip + g_heap_ptr]
    if gv_heap_ptr >= 0:
        cp = cp + ea_mov_rip_load(buf, pos + cp, 11, gv_heap_ptr)
    else:
        rel0 := bss_va - (fva + cp + 7)
        w8(buf, pos + cp, 76)
        w8(buf, pos + cp + 1, 139)
        w8(buf, pos + cp + 2, 29)
        w8_signed(buf, pos + cp + 3, rel0)
        cp = cp + 7

    // test r11, r11; jne +14
    w8(buf, pos + cp, 77)
    w8(buf, pos + cp + 1, 133)
    w8(buf, pos + cp + 2, 219)
    cp = cp + 3
    w8(buf, pos + cp, 117)
    w8(buf, pos + cp + 1, 14)
    cp = cp + 2

    // lea r11, [rip + heap_start]
    heap_start_va : ., mut = bss_va + 16 + globals_size
    rel1 := heap_start_va - (fva + cp + 7)
    w8(buf, pos + cp, 76)
    w8(buf, pos + cp + 1, 141)
    w8(buf, pos + cp + 2, 29)
    w8_signed(buf, pos + cp + 3, rel1)
    cp = cp + 7

    // mov [rip + g_heap_ptr], r11
    if gv_heap_ptr >= 0:
        cp = cp + ea_mov_rip_store(buf, pos + cp, 11, gv_heap_ptr)
    else:
        rel2 := bss_va - (fva + cp + 7)
        w8(buf, pos + cp, 76)
        w8(buf, pos + cp + 1, 137)
        w8(buf, pos + cp + 2, 29)
        w8_signed(buf, pos + cp + 3, rel2)
        cp = cp + 7

    // .Lretry: mov r8, r11; lea rdx, [r11 + rdi]
    retry_cp := cp
    w8(buf, pos + cp, 77)
    w8(buf, pos + cp + 1, 137)
    w8(buf, pos + cp + 2, 216)
    cp = cp + 3
    w8(buf, pos + cp, 74)
    w8(buf, pos + cp + 1, 141)
    w8(buf, pos + cp + 2, 20)
    w8(buf, pos + cp + 3, 31)
    cp = cp + 4

    // lea rcx, [rip + g_heap_end]
    if gv_heap_end >= 0:
        cp = cp + ea_lea_rip(buf, pos + cp, 1, gv_heap_end)
    else:
        heap_end_va : ., mut = bss_va + 8
        rel_he := heap_end_va - (fva + cp + 7)
        w8(buf, pos + cp, 72)
        w8(buf, pos + cp + 1, 141)
        w8(buf, pos + cp + 2, 13)
        w8_signed(buf, pos + cp + 3, rel_he)
        cp = cp + 7

    // cmp rdx, [rcx]; jbe +14
    w8(buf, pos + cp, 72)
    w8(buf, pos + cp + 1, 59)
    w8(buf, pos + cp + 2, 17)
    cp = cp + 3
    w8(buf, pos + cp, 118)
    w8(buf, pos + cp + 1, 14)
    cp = cp + 2

    // call heap_expand
    g_heap_expand_call_pos = pos + cp
    w8(buf, pos + cp, 232)
    e2_w32(buf, pos + cp + 1, 0)
    cp = cp + 5

    // mov r11, [rip + g_heap_ptr]
    if gv_heap_ptr >= 0:
        cp = cp + ea_mov_rip_load(buf, pos + cp, 11, gv_heap_ptr)
    else:
        rel_hr := bss_va - (fva + cp + 7)
        w8(buf, pos + cp, 76)
        w8(buf, pos + cp + 1, 139)
        w8(buf, pos + cp + 2, 29)
        w8_signed(buf, pos + cp + 3, rel_hr)
        cp = cp + 7

    // jmp .Lretry
    jmp_off_val := retry_cp - (cp + 2)
    w8(buf, pos + cp, 235)
    w8(buf, pos + cp + 1, jmp_off_val % 256)
    cp = cp + 2

    // add r11, rdi; mov [rip + g_heap_ptr], r11
    w8(buf, pos + cp, 73)
    w8(buf, pos + cp + 1, 1)
    w8(buf, pos + cp + 2, 251)
    cp = cp + 3
    if gv_heap_ptr >= 0:
        cp = cp + ea_mov_rip_store(buf, pos + cp, 11, gv_heap_ptr)
    else:
        rel3 := bss_va - (fva + cp + 7)
        w8(buf, pos + cp, 76)
        w8(buf, pos + cp + 1, 137)
        w8(buf, pos + cp + 2, 29)
        w8_signed(buf, pos + cp + 3, rel3)
        cp = cp + 7

    // mov rdi, r8; mov rcx, r11; sub rcx, rdi
    w8(buf, pos + cp, 76)
    w8(buf, pos + cp + 1, 137)
    w8(buf, pos + cp + 2, 199)
    cp = cp + 3
    w8(buf, pos + cp, 76)
    w8(buf, pos + cp + 1, 137)
    w8(buf, pos + cp + 2, 217)
    cp = cp + 3
    w8(buf, pos + cp, 72)
    w8(buf, pos + cp + 1, 41)
    w8(buf, pos + cp + 2, 249)
    cp = cp + 3

    // xor eax, eax; cld; rep stosb
    w8(buf, pos + cp, 49)
    w8(buf, pos + cp + 1, 192)
    cp = cp + 2
    w8(buf, pos + cp, 252)
    cp = cp + 1
    w8(buf, pos + cp, 243)
    w8(buf, pos + cp + 1, 170)
    cp = cp + 2

    // mov [r8], r9; lea rax, [r8 + 8]; ret
    w8(buf, pos + cp, 77)
    w8(buf, pos + cp + 1, 137)
    w8(buf, pos + cp + 2, 8)
    cp = cp + 3
    w8(buf, pos + cp, 73)
    w8(buf, pos + cp + 1, 141)
    w8(buf, pos + cp + 2, 64)
    w8(buf, pos + cp + 3, 8)
    cp = cp + 4
    w8(buf, pos + cp, 65)
    w8(buf, pos + cp + 1, 94)
    cp = cp + 2
    w8(buf, pos + cp, 65)
    w8(buf, pos + cp + 1, 95)
    cp = cp + 2
    w8(buf, pos + cp, 195)
    cp = cp + 1
    return cp

// ── Simple bump allocator (no arena): used when gv_current_arena < 0 ──
// Original 84-byte alloc body: no arena check, no rip_patches for arena globals.
// This avoids relying on unpatched RIP-relative addresses for g_current_arena
// when the variable isn't registered in the output binary (non-static builds).
fn emit_alloc_body_simple(buf: string, pos: int, bss_va: int, globals_size: int) -> int:
    cp : ., mut = 0
    fva := TEXT_BASE + pos

    // 64MB sanity check
    w8(buf, pos+cp, 72)
    w8(buf, pos+cp+1, 129)
    w8(buf, pos+cp+2, 255)
    e2_w32(buf, pos+cp+3, 67108864)
    cp = cp + 7
    w8(buf, pos+cp, 118)
    w8(buf, pos+cp+1, 3)
    cp = cp + 2
    w8(buf, pos+cp, 49)
    w8(buf, pos+cp+1, 192)
    cp = cp + 2
    w8(buf, pos+cp, 195)
    cp = cp + 1

    // mov r9, rdi (save size for header)
    w8(buf, pos+cp, 73)
    w8(buf, pos+cp+1, 137)
    w8(buf, pos+cp+2, 249)
    cp = cp + 3

    // add rdi, 15; and rdi, -8
    w8(buf, pos+cp, 72)
    w8(buf, pos+cp+1, 131)
    w8(buf, pos+cp+2, 199)
    w8(buf, pos+cp+3, 15)
    cp = cp + 4
    w8(buf, pos+cp, 72)
    w8(buf, pos+cp+1, 131)
    w8(buf, pos+cp+2, 231)
    w8(buf, pos+cp+3, 248)
    cp = cp + 4

    // mov r11, [rip + g_heap_ptr]: load via rip_patch
    if gv_heap_ptr >= 0:
        rip_hp_l := pos + cp + 3
        w8(buf, pos+cp, 76)
        w8(buf, pos+cp+1, 139)
        w8(buf, pos+cp+2, 29)
        e2_w32(buf, pos+cp+3, 0)
        cp = cp + 7
        grow_rip_patch(g_x86_rip_patch_count + 1)
        cell_store(g_x86_rip_patch_pos, g_x86_rip_patch_count * 8, rip_hp_l)
        cell_store(g_x86_rip_patch_globals, g_x86_rip_patch_count * 8, gv_heap_ptr)
        g_x86_rip_patch_count = g_x86_rip_patch_count + 1
    else:
        rel0 := bss_va - (fva + cp + 7)
        w8(buf, pos+cp, 76)
        w8(buf, pos+cp+1, 139)
        w8(buf, pos+cp+2, 29)
        w8_signed(buf, pos+cp+3, rel0)
        cp = cp + 7
    // test r11, r11; jne +14 (skip lazy init)
    w8(buf, pos+cp, 77)
    w8(buf, pos+cp+1, 133)
    w8(buf, pos+cp+2, 219)
    cp = cp + 3
    w8(buf, pos+cp, 117)
    w8(buf, pos+cp+1, 14)
    cp = cp + 2

    // lea r11, [rip + heap_start]
    heap_start_va : ., mut = bss_va + 16 + globals_size
    rel1 := heap_start_va - (fva + cp + 7)
    w8(buf, pos+cp, 76)
    w8(buf, pos+cp+1, 141)
    w8(buf, pos+cp+2, 29)
    w8_signed(buf, pos+cp+3, rel1)
    cp = cp + 7
    // mov [rip + g_heap_ptr], r11: store via rip_patch
    if gv_heap_ptr >= 0:
        rip_hp_s1 := pos + cp + 3
        w8(buf, pos+cp, 76)
        w8(buf, pos+cp+1, 137)
        w8(buf, pos+cp+2, 29)
        e2_w32(buf, pos+cp+3, 0)
        cp = cp + 7
        grow_rip_patch(g_x86_rip_patch_count + 1)
        cell_store(g_x86_rip_patch_pos, g_x86_rip_patch_count * 8, rip_hp_s1)
        cell_store(g_x86_rip_patch_globals, g_x86_rip_patch_count * 8, gv_heap_ptr)
        g_x86_rip_patch_count = g_x86_rip_patch_count + 1
    else:
        rel2 := bss_va - (fva + cp + 7)
        w8(buf, pos+cp, 76)
        w8(buf, pos+cp+1, 137)
        w8(buf, pos+cp+2, 29)
        w8_signed(buf, pos+cp+3, rel2)
        cp = cp + 7

    // Bounds check: new = heap_ptr + size. Expand once if needed; if the
    // expanded heap still cannot hold the request, trap with a witness.
    cp = cp + ea_mov_rr(buf, pos+cp, 8, 11)
    cp = cp + ea_lea_base_index8(buf, pos+cp, 2, 11, 7, 0)
    if gv_heap_end >= 0:
        cp = cp + ea_lea_rip(buf, pos+cp, 1, gv_heap_end)
    else:
        rel_he_s := bss_va + 8 - (fva + cp + 7)
        w8(buf, pos+cp, 72)
        w8(buf, pos+cp+1, 141)
        w8(buf, pos+cp+2, 13)
        w8_signed(buf, pos+cp+3, rel_he_s)
        cp = cp + 7
    w8(buf, pos+cp, 72)
    w8(buf, pos+cp+1, 59)
    w8(buf, pos+cp+2, 17)
    cp = cp + 3
    jbe_ok := cp
    cp = cp + ea_jbe32(buf, pos+cp, 0)
    g_heap_expand_call_pos = pos + cp
    w8(buf, pos+cp, 232)
    e2_w32(buf, pos+cp+1, 0)
    cp = cp + 5
    if gv_heap_ptr >= 0:
        cp = cp + ea_mov_rip_load(buf, pos+cp, 11, gv_heap_ptr)
    else:
        rel_hp_s := bss_va - (fva + cp + 7)
        w8(buf, pos+cp, 76)
        w8(buf, pos+cp+1, 139)
        w8(buf, pos+cp+2, 29)
        w8_signed(buf, pos+cp+3, rel_hp_s)
        cp = cp + 7
    cp = cp + ea_mov_rr(buf, pos+cp, 8, 11)
    cp = cp + ea_lea_base_index8(buf, pos+cp, 2, 11, 7, 0)
    if gv_heap_end >= 0:
        cp = cp + ea_lea_rip(buf, pos+cp, 1, gv_heap_end)
    else:
        rel_he_s2 := bss_va + 8 - (fva + cp + 7)
        w8(buf, pos+cp, 72)
        w8(buf, pos+cp+1, 141)
        w8(buf, pos+cp+2, 13)
        w8_signed(buf, pos+cp+3, rel_he_s2)
        cp = cp + 7
    w8(buf, pos+cp, 72)
    w8(buf, pos+cp+1, 59)
    w8(buf, pos+cp+2, 17)
    cp = cp + 3
    jbe_ok2 := cp
    cp = cp + ea_jbe32(buf, pos+cp, 0)
    // fail witness: request, class = -1, cursor = heap_ptr, limit = heap_end
    cp = cp + ea_mov_rip_store(buf, pos+cp, 9, gv_alloc_fail_request)
    cp = cp + ea_mov_imm32(buf, pos+cp, 0, -1)
    cp = cp + ea_mov_rip_store(buf, pos+cp, 0, gv_alloc_fail_class)
    cp = cp + ea_mov_rip_store(buf, pos+cp, 11, gv_alloc_fail_cursor)
    cp = cp + ea_mov_load(buf, pos+cp, 0, 1)
    cp = cp + ea_mov_rip_store(buf, pos+cp, 0, gv_alloc_fail_limit)
    cp = cp + ea_ud2(buf, pos+cp)
    ok_s := cp
    w32(buf, pos+jbe_ok+2, ok_s - (jbe_ok + 6))
    w32(buf, pos+jbe_ok2+2, ok_s - (jbe_ok2 + 6))
    // bump: r11 = r11 + rdi; store g_heap_ptr
    cp = cp + ea_add_rr(buf, pos+cp, 11, 7)
    if gv_heap_ptr >= 0:
        cp = cp + ea_mov_rip_store(buf, pos+cp, 11, gv_heap_ptr)
    else:
        rel3 := bss_va - (fva + cp + 7)
        w8(buf, pos+cp, 76)
        w8(buf, pos+cp+1, 137)
        w8(buf, pos+cp+2, 29)
        w8_signed(buf, pos+cp+3, rel3)
        cp = cp + 7

    // Zero-init: mov rdi, r8; mov rcx, r11; sub rcx, rdi; xor eax, eax; cld; rep stosb
    w8(buf, pos+cp, 76)
    w8(buf, pos+cp+1, 137)
    w8(buf, pos+cp+2, 199)
    cp = cp + 3
    w8(buf, pos+cp, 76)
    w8(buf, pos+cp+1, 137)
    w8(buf, pos+cp+2, 217)
    cp = cp + 3
    w8(buf, pos+cp, 72)
    w8(buf, pos+cp+1, 41)
    w8(buf, pos+cp+2, 249)
    cp = cp + 3
    w8(buf, pos+cp, 49)
    w8(buf, pos+cp+1, 192)
    cp = cp + 2
    w8(buf, pos+cp, 252)
    cp = cp + 1
    w8(buf, pos+cp, 243)
    w8(buf, pos+cp+1, 170)
    cp = cp + 2

    // Store header: mov [r8], r9; lea rax, [r8+8]; ret
    w8(buf, pos+cp, 77)
    w8(buf, pos+cp+1, 137)
    w8(buf, pos+cp+2, 8)
    cp = cp + 3
    w8(buf, pos+cp, 73)
    w8(buf, pos+cp+1, 141)
    w8(buf, pos+cp+2, 64)
    w8(buf, pos+cp+3, 8)
    cp = cp + 4
    w8(buf, pos+cp, 195)
    cp = cp + 1

    return cp

// ── heap_expand: mmap(0, 1GB, 3, 0x22, -1, 0) for OOM recovery ──
// Called when global bump heap reaches heap_end. Uses mmap syscall to
// allocate a new 1GiB region, then updates heap_ptr and heap_end.
fn emit_heap_expand(buf: string, pos: int, bss_va: int) -> int:
    cp : ., mut = 0
    fva := TEXT_BASE + pos
    // Private allocator helper: preserve the live allocation span, original
    // request size, and current arena index across mmap argument setup.
    w8(buf, pos+cp, 87)
    cp = cp + 1  // push rdi
    w8(buf, pos+cp, 65)
    w8(buf, pos+cp+1, 81)
    cp = cp + 2  // push r9
    w8(buf, pos+cp, 65)
    w8(buf, pos+cp+1, 82)
    cp = cp + 2  // push r10
    // xor edi, edi. 31 FF (addr = NULL, let kernel choose)
    w8(buf, pos+cp, 49)
    w8(buf, pos+cp+1, 255)
    cp = cp + 2
    // mov esi, 1073741824. BE xx xx xx xx (length = 1 GiB)
    e2_w8(buf, pos+cp, 190)
    e2_w32(buf, pos+cp+1, 1073741824)
    cp = cp + 5
    // mov edx, 3. BA 03 00 00 00 (prot = PROT_READ|PROT_WRITE)
    w8(buf, pos+cp, 186)
    e2_w32(buf, pos+cp+1, 3)
    cp = cp + 5
    // mov r10d, 0x22. 41 BA 22 00 00 00 (flags = MAP_PRIVATE|MAP_ANONYMOUS)
    w8(buf, pos+cp, 65)
    w8(buf, pos+cp+1, 186)
    e2_w32(buf, pos+cp+2, 34)
    cp = cp + 6
    // mov r8d, -1. 41 B8 FF FF FF FF (fd = -1)
    w8(buf, pos+cp, 65)
    w8(buf, pos+cp+1, 184)
    e2_w32(buf, pos+cp+2, -1)
    cp = cp + 6
    // xor r9d, r9d. 45 31 C9 (offset = 0)
    w8(buf, pos+cp, 69)
    w8(buf, pos+cp+1, 49)
    w8(buf, pos+cp+2, 201)
    cp = cp + 3
    // mov eax, 9. B8 09 00 00 00 (sys_mmap)
    w8(buf, pos+cp, 184)
    e2_w32(buf, pos+cp+1, 9)
    cp = cp + 5
    // syscall. 0F 05
    w8(buf, pos+cp, 15)
    w8(buf, pos+cp+1, 5)
    cp = cp + 2
    // test rax, rax. 48 85 C0 (check if mmap returned negative error)
    w8(buf, pos+cp, 72)
    w8(buf, pos+cp+1, 133)
    w8(buf, pos+cp+2, 192)
    cp = cp + 3
    // js .Lhf. 78 XX (skip success path if mmap failed, rax has -errno)
    // Success path: 7+7+7+2+5+1 = 29 bytes
    w8(buf, pos+cp, 120)
    w8(buf, pos+cp+1, 29)
    cp = cp + 2
    // mov [rip + g_heap_ptr], rax: store via rip_patch
    if gv_heap_ptr >= 0:
        rip_hp_ex := pos + cp + 3
        w8(buf, pos+cp, 72)
        w8(buf, pos+cp+1, 137)
        w8(buf, pos+cp+2, 5)
        e2_w32(buf, pos+cp+3, 0)
        cp = cp + 7
        grow_rip_patch(g_x86_rip_patch_count + 1)
        cell_store(g_x86_rip_patch_pos, g_x86_rip_patch_count * 8, rip_hp_ex)
        cell_store(g_x86_rip_patch_globals, g_x86_rip_patch_count * 8, gv_heap_ptr)
        g_x86_rip_patch_count = g_x86_rip_patch_count + 1
    else:
        rel_hp_s := bss_va - (fva + cp + 7)
        w8(buf, pos+cp, 72)
        w8(buf, pos+cp+1, 137)
        w8(buf, pos+cp+2, 5)
        w8_signed(buf, pos+cp+3, rel_hp_s)
        cp = cp + 7
    // lea r11, [rax + 1073741824]. 4C 8D 98 xx xx xx xx (heap_end = new base + 1GB)
    w8(buf, pos+cp, 76)
    w8(buf, pos+cp+1, 141)
    w8(buf, pos+cp+2, 152)
    e2_w32(buf, pos+cp+3, 1073741824)
    cp = cp + 7
    // mov [rip + g_heap_end], r11: store via rip_patch
    if gv_heap_end >= 0:
        rip_he_ex := pos + cp + 3
        w8(buf, pos+cp, 76)
        w8(buf, pos+cp+1, 137)
        w8(buf, pos+cp+2, 29)
        e2_w32(buf, pos+cp+3, 0)
        cp = cp + 7
        grow_rip_patch(g_x86_rip_patch_count + 1)
        cell_store(g_x86_rip_patch_pos, g_x86_rip_patch_count * 8, rip_he_ex)
        cell_store(g_x86_rip_patch_globals, g_x86_rip_patch_count * 8, gv_heap_end)
        g_x86_rip_patch_count = g_x86_rip_patch_count + 1
    else:
        rel_hp_e := (bss_va + 8) - (fva + cp + 7)
        w8(buf, pos+cp, 76)
        w8(buf, pos+cp+1, 137)
        w8(buf, pos+cp+2, 29)
        w8_signed(buf, pos+cp+3, rel_hp_e)
        cp = cp + 7
    // xor eax, eax. 31 C0 (return 0 for success)
    w8(buf, pos+cp, 49)
    w8(buf, pos+cp+1, 192)
    cp = cp + 2
    // Restore allocator state.
    w8(buf, pos+cp, 65)
    w8(buf, pos+cp+1, 90)
    cp = cp + 2  // pop r10
    w8(buf, pos+cp, 65)
    w8(buf, pos+cp+1, 89)
    cp = cp + 2  // pop r9
    w8(buf, pos+cp, 95)
    cp = cp + 1  // pop rdi
    // ret. C3
    w8(buf, pos+cp, 195)
    cp = cp + 1
    // .Lhf: mmap failed, return -1
    // mov rax, -1. 48 C7 C0 FF FF FF FF
    w8(buf, pos+cp, 72)
    w8(buf, pos+cp+1, 199)
    w8(buf, pos+cp+2, 192)
    e2_w32(buf, pos+cp+3, -1)
    cp = cp + 7
    w8(buf, pos+cp, 65)
    w8(buf, pos+cp+1, 90)
    cp = cp + 2  // pop r10
    w8(buf, pos+cp, 65)
    w8(buf, pos+cp+1, 89)
    cp = cp + 2  // pop r9
    w8(buf, pos+cp, 95)
    cp = cp + 1  // pop rdi
    // ret. C3
    w8(buf, pos+cp, 195)
    cp = cp + 1
    return cp

// ── Scheduler call trampolines ──
// Emit sched_call_N(buf, p, n): mov rax,[rdi+rsi*8]; shift N args; jmp rax
// Returns bytes written.
fn emit_sched_call(buf: string, p: int, n: int) -> int:
    w8(buf, p, 72)
    w8(buf, p+1, 139)
    w8(buf, p+2, 4)
    w8(buf, p+3, 240)
    off : ., mut = 4
    if n >= 1:
        w8(buf, p+off, 72)
        w8(buf, p+off+1, 137)
        w8(buf, p+off+2, 215)
        off = off + 3
    if n >= 2:
        w8(buf, p+off, 72)
        w8(buf, p+off+1, 137)
        w8(buf, p+off+2, 206)
        off = off + 3
    if n >= 3:
        w8(buf, p+off, 76)
        w8(buf, p+off+1, 137)
        w8(buf, p+off+2, 194)
        off = off + 3
    if n >= 4:
        w8(buf, p+off, 76)
        w8(buf, p+off+1, 137)
        w8(buf, p+off+2, 201)
        off = off + 3
    w8(buf, p+off, 255)
    w8(buf, p+off+1, 224)
    off = off + 2
    return off
fn sched_tramp_sz(n: int) -> int:
    sz : ., mut = 6
    if n >= 1:
        sz = sz + 3
    if n >= 2:
        sz = sz + 3
    if n >= 3:
        sz = sz + 3
    if n >= 4:
        sz = sz + 3
    return sz

// ── g_set_curg / g_get_curg bridge stubs ──
// Pure-static ELFs don't link rt.s, so the backend emits equivalent
// implementations that read/write a dedicated BSS slot (current_g).
// In .so-linked builds (g_x86_emit_rt_stubs == 0) these stay external
// relocations resolved from rt.s at link time.
// Size: 11 bytes each: must match Phase 2 estimate.
fn emit_curg_stubs(buf: string, pos: int, curg_va: int) -> int:
    cp : ., mut = 0
    // g_set_curg: lea rax, [rip + curg_va]; mov [rax], rdi; ret
    fva := TEXT_BASE + pos + cp
    w8(buf, pos+cp, 72)
    w8(buf, pos+cp+1, 141)
    w8(buf, pos+cp+2, 5)  // lea rax, [rip+disp32]
    e2_w32(buf, pos+cp+3, curg_va - (fva + 7))
    cp = cp + 7
    w8(buf, pos+cp, 72)
    w8(buf, pos+cp+1, 137)
    w8(buf, pos+cp+2, 56)
    cp = cp + 3  // mov [rax], rdi
    w8(buf, pos+cp, 195)
    cp = cp + 1  // ret
    // g_get_curg: lea rax, [rip + curg_va]; mov rax, [rax]; ret
    fva2 := TEXT_BASE + pos + cp
    w8(buf, pos+cp, 72)
    w8(buf, pos+cp+1, 141)
    w8(buf, pos+cp+2, 5)  // lea rax, [rip+disp32]
    e2_w32(buf, pos+cp+3, curg_va - (fva2 + 7))
    cp = cp + 7
    w8(buf, pos+cp, 72)
    w8(buf, pos+cp+1, 139)
    w8(buf, pos+cp+2, 0)
    cp = cp + 3  // mov rax, [rax]
    w8(buf, pos+cp, 195)
    cp = cp + 1  // ret
    return cp
// ── Goroutine runtime stubs (pure-static self-contained runtime) ──
// rt.s equivalents emitted into the binary so `go f()` works without
// linking rt.s: fiber_init, fiber_switch, goroutine_entry_wrapper.
// The wrapper is the fiber entry for every G (g_new sets it via @addr);
// it reads saved_fn/saved_arg from the G struct (offsets 56/64), calls
// saved_fn(saved_arg), sends the result to result_ch (G+40), then yields
// forever. chan_send/sched_yield are Core functions: recorded as call
// patches resolved by the Phase 3 patch loop (user function names).
fn emit_goroutine_stubs(buf: string, pos: int) -> int:
    cp : ., mut = 0

    // fiber_init(stack_bottom, entry_fn) -> int: fake frame on the new stack.
    // Layout: fiber_switch pops 6 regs (48 bytes) then ret reads
    // [stack_bottom-8]: entry_fn MUST be at [stack_bottom-8]:
    //   mov rax, rdi; sub rax, 8; mov [rax], rsi; sub rax, 48;
    //   xor ecx, ecx; mov [rax], rcx; ret
    w8(buf, pos+cp, 72)
    w8(buf, pos+cp+1, 137)
    w8(buf, pos+cp+2, 248)
    cp = cp + 3  // mov rax, rdi
    w8(buf, pos+cp, 72)
    w8(buf, pos+cp+1, 131)
    w8(buf, pos+cp+2, 232)
    w8(buf, pos+cp+3, 8)
    cp = cp + 4  // sub rax, 8
    w8(buf, pos+cp, 72)
    w8(buf, pos+cp+1, 137)
    w8(buf, pos+cp+2, 48)
    cp = cp + 3  // mov [rax], rsi
    w8(buf, pos+cp, 72)
    w8(buf, pos+cp+1, 131)
    w8(buf, pos+cp+2, 232)
    w8(buf, pos+cp+3, 48)
    cp = cp + 4  // sub rax, 48
    w8(buf, pos+cp, 49)
    w8(buf, pos+cp+1, 201)
    cp = cp + 2  // xor ecx, ecx
    w8(buf, pos+cp, 72)
    w8(buf, pos+cp+1, 137)
    w8(buf, pos+cp+2, 8)
    cp = cp + 3  // mov [rax], rcx
    w8(buf, pos+cp, 195)
    cp = cp + 1  // ret
    // 20 bytes

    // fiber_switch(current_sp_addr, next_sp) -> int: save/restore context:
    //   push rbx,r12-r15,rbp; mov [rdi], rsp; mov rsp, rsi; pop rbp,r15-r12,rbx; ret
    w8(buf, pos+cp, 83)
    cp = cp + 1  // push rbx
    w8(buf, pos+cp, 65)
    w8(buf, pos+cp+1, 84)
    cp = cp + 2  // push r12
    w8(buf, pos+cp, 65)
    w8(buf, pos+cp+1, 85)
    cp = cp + 2  // push r13
    w8(buf, pos+cp, 65)
    w8(buf, pos+cp+1, 86)
    cp = cp + 2  // push r14
    w8(buf, pos+cp, 65)
    w8(buf, pos+cp+1, 87)
    cp = cp + 2  // push r15
    w8(buf, pos+cp, 85)
    cp = cp + 1  // push rbp
    w8(buf, pos+cp, 72)
    w8(buf, pos+cp+1, 137)
    w8(buf, pos+cp+2, 39)
    cp = cp + 3  // mov [rdi], rsp
    w8(buf, pos+cp, 72)
    w8(buf, pos+cp+1, 137)
    w8(buf, pos+cp+2, 244)
    cp = cp + 3  // mov rsp, rsi
    w8(buf, pos+cp, 93)
    cp = cp + 1  // pop rbp
    w8(buf, pos+cp, 65)
    w8(buf, pos+cp+1, 95)
    cp = cp + 2  // pop r15
    w8(buf, pos+cp, 65)
    w8(buf, pos+cp+1, 94)
    cp = cp + 2  // pop r14
    w8(buf, pos+cp, 65)
    w8(buf, pos+cp+1, 93)
    cp = cp + 2  // pop r13
    w8(buf, pos+cp, 65)
    w8(buf, pos+cp+1, 92)
    cp = cp + 2  // pop r12
    w8(buf, pos+cp, 91)
    cp = cp + 1  // pop rbx
    w8(buf, pos+cp, 195)
    cp = cp + 1  // ret
    // 27 bytes

    // goroutine_entry_wrapper: fiber entry, no prologue (runs on the G's stack):
    //   call g_get_curg; rdi = [rax+64] (saved_arg: first param, SysV rdi);
    //   rax = [rax+56] (saved_fn); call rax; push rax; call g_get_curg;
    //   rdi = [rax+40] (result_ch); pop rsi; call chan_send;
    //   then exit: call g_get_curg; mov rdi, rax; call g_free (arena_reset +
    //   mark _Gdead); call sched_schedule (switch to next, no re-enqueue);
    //   ret (fiber dead if no work)
    call_pos0 := pos + cp
    grow_call_patch(g_x86_call_patch_count + 1)
    cell_store(g_x86_call_patch_pos, g_x86_call_patch_count * 8, call_pos0)
    cell_store(g_x86_call_patch_name, g_x86_call_patch_count * 8, str_intern("g_get_curg"))
    g_x86_call_patch_count = g_x86_call_patch_count + 1
    e2_w8(buf, pos+cp, 232)
    e2_w32(buf, pos+cp+1, 0)
    cp = cp + 5  // call g_get_curg
    w8(buf, pos+cp, 72)
    w8(buf, pos+cp+1, 139)
    w8(buf, pos+cp+2, 120)
    w8(buf, pos+cp+3, 64)
    cp = cp + 4  // mov rdi, [rax+64]
    w8(buf, pos+cp, 72)
    w8(buf, pos+cp+1, 139)
    w8(buf, pos+cp+2, 64)
    w8(buf, pos+cp+3, 56)
    cp = cp + 4  // mov rax, [rax+56]  (modrm 01 000 000 = 0x40 + disp8)
    w8(buf, pos+cp, 255)
    w8(buf, pos+cp+1, 208)
    cp = cp + 2  // call rax
    w8(buf, pos+cp, 80)
    cp = cp + 1  // push rax
    call_pos1 := pos + cp
    grow_call_patch(g_x86_call_patch_count + 1)
    cell_store(g_x86_call_patch_pos, g_x86_call_patch_count * 8, call_pos1)
    cell_store(g_x86_call_patch_name, g_x86_call_patch_count * 8, str_intern("g_get_curg"))
    g_x86_call_patch_count = g_x86_call_patch_count + 1
    e2_w8(buf, pos+cp, 232)
    e2_w32(buf, pos+cp+1, 0)
    cp = cp + 5  // call g_get_curg
    w8(buf, pos+cp, 72)
    w8(buf, pos+cp+1, 139)
    w8(buf, pos+cp+2, 120)
    w8(buf, pos+cp+3, 40)
    cp = cp + 4  // mov rdi, [rax+40]
    w8(buf, pos+cp, 94)
    cp = cp + 1  // pop rsi
    call_pos2 := pos + cp
    grow_call_patch(g_x86_call_patch_count + 1)
    cell_store(g_x86_call_patch_pos, g_x86_call_patch_count * 8, call_pos2)
    cell_store(g_x86_call_patch_name, g_x86_call_patch_count * 8, str_intern("chan_send"))
    g_x86_call_patch_count = g_x86_call_patch_count + 1
    e2_w8(buf, pos+cp, 232)
    e2_w32(buf, pos+cp+1, 0)
    cp = cp + 5  // call chan_send
    // exit: call g_get_curg; mov rdi, rax; call g_free; call sched_schedule; ret
    call_pos3 := pos + cp
    grow_call_patch(g_x86_call_patch_count + 1)
    cell_store(g_x86_call_patch_pos, g_x86_call_patch_count * 8, call_pos3)
    cell_store(g_x86_call_patch_name, g_x86_call_patch_count * 8, str_intern("g_get_curg"))
    g_x86_call_patch_count = g_x86_call_patch_count + 1
    e2_w8(buf, pos+cp, 232)
    e2_w32(buf, pos+cp+1, 0)
    cp = cp + 5  // call g_get_curg
    w8(buf, pos+cp, 72)
    w8(buf, pos+cp+1, 137)
    w8(buf, pos+cp+2, 248)
    cp = cp + 3  // mov rdi, rax
    call_pos4 := pos + cp
    grow_call_patch(g_x86_call_patch_count + 1)
    cell_store(g_x86_call_patch_pos, g_x86_call_patch_count * 8, call_pos4)
    cell_store(g_x86_call_patch_name, g_x86_call_patch_count * 8, str_intern("g_free"))
    g_x86_call_patch_count = g_x86_call_patch_count + 1
    e2_w8(buf, pos+cp, 232)
    e2_w32(buf, pos+cp+1, 0)
    cp = cp + 5  // call g_free
    call_pos5 := pos + cp
    grow_call_patch(g_x86_call_patch_count + 1)
    cell_store(g_x86_call_patch_pos, g_x86_call_patch_count * 8, call_pos5)
    cell_store(g_x86_call_patch_name, g_x86_call_patch_count * 8, str_intern("sched_schedule"))
    g_x86_call_patch_count = g_x86_call_patch_count + 1
    e2_w8(buf, pos+cp, 232)
    e2_w32(buf, pos+cp+1, 0)
    cp = cp + 5  // call sched_schedule
    w8(buf, pos+cp, 195)
    cp = cp + 1  // ret

    return cp

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
fn emit_m_start_workers(buf: string, pos: int) -> int:
    cp : ., mut = 0

    // worker_entry (15 bytes):
    w8(buf, pos+cp, 95)
    cp = cp + 1  // pop rdi
    call_pos_we := pos + cp
    grow_call_patch(g_x86_call_patch_count + 1)
    cell_store(g_x86_call_patch_pos, g_x86_call_patch_count * 8, call_pos_we)
    cell_store(g_x86_call_patch_name, g_x86_call_patch_count * 8, str_intern("sched_worker_run"))
    g_x86_call_patch_count = g_x86_call_patch_count + 1
    e2_w8(buf, pos+cp, 232)
    e2_w32(buf, pos+cp+1, 0)
    cp = cp + 5  // call sched_worker_run
    w8(buf, pos+cp, 184)
    w8(buf, pos+cp+1, 60)
    w8(buf, pos+cp+2, 0)
    w8(buf, pos+cp+3, 0)
    w8(buf, pos+cp+4, 0)
    cp = cp + 5  // mov eax, 60
    w8(buf, pos+cp, 49)
    w8(buf, pos+cp+1, 255)
    cp = cp + 2  // xor edi, edi
    w8(buf, pos+cp, 15)
    w8(buf, pos+cp+1, 5)
    cp = cp + 2  // syscall

    // m_start_workers (111 bytes, starts at pos+15)
    w8(buf, pos+cp, 83)
    cp = cp + 1  // push rbx
    w8(buf, pos+cp, 65)
    w8(buf, pos+cp+1, 84)
    cp = cp + 2  // push r12
    w8(buf, pos+cp, 65)
    w8(buf, pos+cp+1, 85)
    cp = cp + 2  // push r13
    w8(buf, pos+cp, 65)
    w8(buf, pos+cp+1, 87)
    cp = cp + 2  // push r15
    w8(buf, pos+cp, 72)
    w8(buf, pos+cp+1, 137)
    w8(buf, pos+cp+2, 251)
    cp = cp + 3  // mov rbx, rdi
    w8(buf, pos+cp, 69)
    w8(buf, pos+cp+1, 49)
    w8(buf, pos+cp+2, 228)
    cp = cp + 3  // xor r12d, r12d
    // .Lworker_loop (offset 13)
    w8(buf, pos+cp, 73)
    w8(buf, pos+cp+1, 255)
    w8(buf, pos+cp+2, 196)
    cp = cp + 3  // inc r12
    w8(buf, pos+cp, 73)
    w8(buf, pos+cp+1, 57)
    w8(buf, pos+cp+2, 220)
    cp = cp + 3  // cmp r12, rbx
    w8(buf, pos+cp, 125)
    w8(buf, pos+cp+1, 83)
    cp = cp + 2  // jge .Ldone (+83)
    w8(buf, pos+cp, 65)
    w8(buf, pos+cp+1, 84)
    cp = cp + 2  // push r12
    w8(buf, pos+cp, 72)
    w8(buf, pos+cp+1, 199)
    w8(buf, pos+cp+2, 199)
    cp = cp + 3  // mov rdi, 65536
    w8(buf, pos+cp, 0)
    w8(buf, pos+cp+1, 0)
    w8(buf, pos+cp+2, 1)
    w8(buf, pos+cp+3, 0)
    cp = cp + 4
    call_pos_al := pos + cp
    grow_call_patch(g_x86_call_patch_count + 1)
    cell_store(g_x86_call_patch_pos, g_x86_call_patch_count * 8, call_pos_al)
    cell_store(g_x86_call_patch_name, g_x86_call_patch_count * 8, str_intern("alloc"))
    g_x86_call_patch_count = g_x86_call_patch_count + 1
    e2_w8(buf, pos+cp, 232)
    e2_w32(buf, pos+cp+1, 0)
    cp = cp + 5  // call alloc
    w8(buf, pos+cp, 65)
    w8(buf, pos+cp+1, 92)
    cp = cp + 2  // pop r12
    w8(buf, pos+cp, 72)
    w8(buf, pos+cp+1, 133)
    w8(buf, pos+cp+2, 192)
    cp = cp + 3  // test rax, rax
    w8(buf, pos+cp, 116)
    w8(buf, pos+cp+1, 54)
    cp = cp + 2  // jz .Lnext_worker (+54)
    w8(buf, pos+cp, 73)
    w8(buf, pos+cp+1, 137)
    w8(buf, pos+cp+2, 199)
    cp = cp + 3  // mov r15, rax
    w8(buf, pos+cp, 73)
    w8(buf, pos+cp+1, 129)
    w8(buf, pos+cp+2, 199)
    cp = cp + 3  // add r15, 65536
    w8(buf, pos+cp, 0)
    w8(buf, pos+cp+1, 0)
    w8(buf, pos+cp+2, 1)
    w8(buf, pos+cp+3, 0)
    cp = cp + 4
    // lea r13, [rip + worker_entry]: worker_entry at stub base (pos+0), this lea
    // is 7 bytes ending at (pos+58): disp = (pos+0) - (pos+58) = -58
    w8(buf, pos+cp, 76)
    w8(buf, pos+cp+1, 141)
    w8(buf, pos+cp+2, 45)
    cp = cp + 3
    e2_w32(buf, pos+cp, -58)
    cp = cp + 4
    w8(buf, pos+cp, 77)
    w8(buf, pos+cp+1, 137)
    w8(buf, pos+cp+2, 111)
    w8(buf, pos+cp+3, 240)
    cp = cp + 4  // mov [r15-16], r13
    w8(buf, pos+cp, 76)
    w8(buf, pos+cp+1, 137)
    w8(buf, pos+cp+2, 71)
    w8(buf, pos+cp+3, 248)
    cp = cp + 4  // mov [r15-8], r12
    w8(buf, pos+cp, 191)
    w8(buf, pos+cp+1, 0)
    w8(buf, pos+cp+2, 15)
    w8(buf, pos+cp+3, 1)
    w8(buf, pos+cp+4, 0)
    cp = cp + 5  // mov edi, 0x10F00
    w8(buf, pos+cp, 73)
    w8(buf, pos+cp+1, 141)
    w8(buf, pos+cp+2, 119)
    w8(buf, pos+cp+3, 240)
    cp = cp + 4  // lea rsi, [r15-16]
    w8(buf, pos+cp, 49)
    w8(buf, pos+cp+1, 210)
    cp = cp + 2  // xor edx, edx
    w8(buf, pos+cp, 69)
    w8(buf, pos+cp+1, 49)
    w8(buf, pos+cp+2, 210)
    cp = cp + 3  // xor r10d, r10d
    w8(buf, pos+cp, 69)
    w8(buf, pos+cp+1, 49)
    w8(buf, pos+cp+2, 192)
    cp = cp + 3  // xor r8d, r8d
    w8(buf, pos+cp, 184)
    w8(buf, pos+cp+1, 56)
    w8(buf, pos+cp+2, 0)
    w8(buf, pos+cp+3, 0)
    w8(buf, pos+cp+4, 0)
    cp = cp + 5  // mov eax, 56
    w8(buf, pos+cp, 15)
    w8(buf, pos+cp+1, 5)
    cp = cp + 2  // syscall
    w8(buf, pos+cp, 72)
    w8(buf, pos+cp+1, 133)
    w8(buf, pos+cp+2, 192)
    cp = cp + 3  // test rax, rax
    w8(buf, pos+cp, 116)
    w8(buf, pos+cp+1, 5)
    cp = cp + 2  // jz .Lchild (+5)
    // .Lnext_worker (offset 95)
    w8(buf, pos+cp, 73)
    w8(buf, pos+cp+1, 255)
    w8(buf, pos+cp+2, 196)
    cp = cp + 3  // inc r12
    w8(buf, pos+cp, 235)
    w8(buf, pos+cp+1, 169)
    cp = cp + 2  // jmp .Lworker_loop (-87)
    // .Lchild (offset 100)
    w8(buf, pos+cp, 49)
    w8(buf, pos+cp+1, 237)
    cp = cp + 2  // xor ebp, ebp
    w8(buf, pos+cp, 195)
    cp = cp + 1  // ret
    // .Ldone (offset 103)
    w8(buf, pos+cp, 65)
    w8(buf, pos+cp+1, 95)
    cp = cp + 2  // pop r15
    w8(buf, pos+cp, 65)
    w8(buf, pos+cp+1, 93)
    cp = cp + 2  // pop r13
    w8(buf, pos+cp, 65)
    w8(buf, pos+cp+1, 92)
    cp = cp + 2  // pop r12
    w8(buf, pos+cp, 91)
    cp = cp + 1  // pop rbx
    w8(buf, pos+cp, 195)
    cp = cp + 1  // ret

    return cp

fn sched_reg_one(name: string, offset: int, cp: int):
    grow_func_offsets(g_x86_func_off_count * 2 + 2)
    cell_store(g_x86_func_offsets, g_x86_func_off_count * 16, str_intern(name))
    cell_store(g_x86_func_offsets, g_x86_func_off_count * 16 + 8, cp - 176)
    g_x86_func_off_count = g_x86_func_off_count + 1

fn w16(buf: string, off: int, val: int):
    store8(buf, off, val % 256)
    store8(buf, off+1, (val/256) % 256)

fn align_up(val: int, align: int) -> int:
    return (val + align - 1) / align * align

// ── Global ──
g_asm_code_size : int, mut
g_elf_buf : string, mut

// ── ELF64 struct layout offsets (used by elf2_hdr) ──
// ELF64 Ehdr
E_EHDR_MAGIC : int = 0    // 4B: \x7fELF
E_CLASS : int = 4          // 1B: 2=64-bit
E_DATA : int = 5           // 1B: 1=LE
E_VER : int = 6            // 1B: 1=current
E_OSABI : int = 7          // 1B: 0=UNIX System V
E_PAD : int = 8            // 8B padding
E_TYPE : int = 16          // 2B: 2=ET_EXEC
E_MACH : int = 18          // 2B: 62=EM_X86_64
E_VERSION : int = 20       // 4B: 1
E_ENTRY : int = 24         // 8B: entry point VA
E_PHOFF : int = 32         // 8B: program header offset
E_SHOFF : int = 40         // 8B: section header offset
E_FLAGS : int = 48         // 4B
E_EHSIZE : int = 52        // 2B: sizeof(Elf64_Ehdr)=64
E_PHENTSIZE : int = 54     // 2B: sizeof(Elf64_Phdr)=56
E_PHNUM : int = 56         // 2B: number of phdrs
E_SHENTSIZE : int = 58     // 2B
E_SHNUM : int = 60         // 2B
E_SHSTRNDX : int = 62      // 2B
EHDR_SIZE : int = 64       // sizeof(Elf64_Ehdr)

// ELF64 Phdr (per-entry offsets, base = 64 + entry_idx * 56)
P_TYPE : int = 0           // 4B: 1=PT_LOAD
P_FLAGS : int = 4          // 4B: PF_{R,W,X}
P_OFFSET : int = 8         // 8B: file offset
P_VADDR : int = 16         // 8B: virtual address
P_PADDR : int = 24         // 8B: physical address
P_FILESZ : int = 32        // 8B: size in file
P_MEMSZ : int = 40         // 8B: size in memory
P_ALIGN : int = 48         // 8B: alignment
PHDR_SIZE : int = 56       // sizeof(Elf64_Phdr)

// Write one ELF64 program header entry
fn write_phdr(buf: string, idx: int, p_type: int, p_flags: int,
    p_offset: int, p_vaddr: int, p_paddr: int,
    p_filesz: int, p_memsz: int, p_align: int):
    base : ., mut = EHDR_SIZE + idx * PHDR_SIZE
    w32(buf, base + P_TYPE, p_type)
    w32(buf, base + P_FLAGS, p_flags)
    cell_store(buf, base + P_OFFSET, p_offset)
    cell_store(buf, base + P_VADDR, p_vaddr)
    cell_store(buf, base + P_PADDR, p_paddr)
    cell_store(buf, base + P_FILESZ, p_filesz)
    cell_store(buf, base + P_MEMSZ, p_memsz)
    cell_store(buf, base + P_ALIGN, p_align)

// ── ELF header writer (x86-64) ──
fn elf2_hdr(buf: string, code_end: int, total_sz: int):
    hdr_sz : ., mut = EHDR_SIZE + 2 * PHDR_SIZE  // 64+112=176
    i : ., mut = 0
    loop:
        if i >= hdr_sz:
            break
        store8(buf, i, 0)
        i = i + 1
    // e_ident
    w8(buf, E_EHDR_MAGIC, 127)
    w8(buf, E_EHDR_MAGIC+1, 69)
    w8(buf, E_EHDR_MAGIC+2, 76)
    w8(buf, E_EHDR_MAGIC+3, 70)  // \x7fELF
    w8(buf, E_CLASS, 2)   // EI_CLASS = ELFCLASS64
    w8(buf, E_DATA, 1)    // EI_DATA = ELFDATA2LSB
    w8(buf, E_VER, 1)     // EI_VERSION = EV_CURRENT
    // e_type, e_machine, e_version
    w16(buf, E_TYPE, 2)    // ET_EXEC
    w16(buf, E_MACH, 62)   // EM_X86_64
    w32(buf, E_VERSION, 1) // EV_CURRENT
    cell_store(buf, E_ENTRY, 0x400000 + EHDR_SIZE + 2 * PHDR_SIZE)  // entry = text_base + 176
    cell_store(buf, E_PHOFF, EHDR_SIZE)              // phdrs start right after ehdr
    w16(buf, E_EHSIZE, EHDR_SIZE)             // sizeof(Elf64_Ehdr) = 64
    w16(buf, E_PHENTSIZE, PHDR_SIZE)          // sizeof(Elf64_Phdr) = 56
    w16(buf, E_PHNUM, 2)                      // 2 program headers

    // PHDR[0]: code segment (RX, file offset 0, VA = TEXT_BASE)
    write_phdr(buf, 0,
        1,     // PT_LOAD
        5,     // PF_R | PF_X
        0,                               // file offset
        4194304,                         // TEXT_BASE
        4194304,                         // phys addr = TEXT_BASE
        code_end, code_end, 4096)

    // PHDR[1]: rodata+BSS (RW, starts at page after code)
    rodata_va : ., mut = 4194304 + code_end
    data_sz : ., mut = total_sz - code_end
    write_phdr(buf, 1,
        1,     // PT_LOAD
        6,     // PF_R | PF_W
        code_end,
        rodata_va, rodata_va,
        data_sz, 1073741824, 4096)  // memsz = 1 GiB virtual bump heap

// ── _start 共享状态（发射序本体 = OS 轴 src/os/linux/entry.cr）──
g_call_main_pos : int, mut  // set by emit_start (OS 轴 entry.cr), used for patching call main
gv_argc : int, mut   // IR var index for g_rt_argc (or -1)
gv_argv : int, mut   // IR var index for g_rt_argv_ptr (or -1)

// Arena global variable indices (set by elf_gen before emit_alloc_body calls)
gv_current_arena : int, mut = -1
gv_arena_cursors : int, mut = -1
gv_arena_slot_cursor : int, mut = -1
gv_arena_slot : int, mut = -1
gv_arena_static : int, mut = -1
gv_arena_slot_next : int, mut = -1
gv_arena_slot_free : int, mut = -1
gv_arena_slot_count : int, mut = -1
gv_arena_pool_slots : int, mut = -1
gv_segment_base : int, mut = -1
gv_class_base : int, mut = -1
gv_class_cursor : int, mut = -1
gv_class_limit : int, mut = -1
gv_class_sizes : int, mut = -1
gv_class_lookup : int, mut = -1
gv_alloc_fail_request : int, mut = -1
gv_alloc_fail_class : int, mut = -1
gv_alloc_fail_cursor : int, mut = -1
gv_alloc_fail_limit : int, mut = -1
gv_alloc_home_idx : int, mut = -1
gv_arena_sizes : int, mut = -1
gv_arena_pool_data : int, mut = -1
gv_arena_max_size : int, mut = -1
gv_heap_ptr : int, mut = -1
gv_heap_end : int, mut = -1
gv_hp_config : int, mut = -1
gv_hp_inflight : int, mut = -1
g_heap_expand_call_pos : int, mut = -1
g_alloc_gl_jmp_pos : int, mut = -1  // Part 1 jl .Lglobal displacement position (patched at Part 8)

// _start emission (emit_start and emit_start_size) lives in
// src/os/linux/entry.cr. This file keeps the call sites and the shared global
// declarations; the flat compilation unit resolves them once.

// ── Main ELF generation ──
fn elf_gen(buf: string) -> int:
    g_x86_big_exit_call_pos = -1
    // Mark global variables for RIP-relative addressing
    gi : ., mut = 0
    loop:
        if gi >= g_ir_global_count:
            break
        gv := cell_load(g_ir_globals, gi * 24 + 8)
        if gv >= 0:
            grow_is_global(gv + 1)
            cell_store(g_x86_is_global, gv * 8, 1)
        gi = gi + 1
    grow_is_global(g_ir_var_count)

    // Builtin name scan: assign the g_ni_* indices. This section only maps names
    // to indices and is independent of emission. The syscall3 and syscall4
    // emission sequences are in src/os/linux/syscall.cr and are consumed by the
    // builtin dispatch chain in instr.cr.
    // This is not the full set of syscall sequences. This file still has three
    // handwritten sequences: emit_heap_expand mmap, worker exit, and clone
    // (syscall1, syscall5, and syscall6 shapes, not builtin paths). Moving them to
    // the OS axis is still pending.
    g_ni_syscall3 = -1
    g_ni_syscall4 = -1
    g_ni_load8 = -1
    g_ni_store8 = -1
    g_ni_load64 = -1
    g_ni_load_str_ptr = -1
    g_ni_store_str_ptr = -1
    g_ni_get_arg = -1
    g_ni_cell_store = -1
    g_ni_dyncpy = -1
    g_ni_cell_load = -1
    g_ni_goroutine_wrapper_addr = -1
    ni_i : ., mut = 0
    loop:
        if ni_i >= g_str_count:
            break
        ns := istr_get(ni_i)
        if str_eq(ns, "syscall3") != 0:
            g_ni_syscall3 = ni_i
        if str_eq(ns, "syscall4") != 0:
            g_ni_syscall4 = ni_i
        if str_eq(ns, "load8") != 0:
            g_ni_load8 = ni_i
        if str_eq(ns, "store8") != 0:
            g_ni_store8 = ni_i
        if str_eq(ns, "load64") != 0:
            g_ni_load64 = ni_i
        if str_eq(ns, "cell_load") != 0:
            g_ni_cell_load = ni_i
        if str_eq(ns, "load_str_ptr") != 0:
            g_ni_load_str_ptr = ni_i
        if str_eq(ns, "store_str_ptr") != 0:
            g_ni_store_str_ptr = ni_i
        if str_eq(ns, "get_arg") != 0:
            g_ni_get_arg = ni_i
        if str_eq(ns, "cell_store") != 0:
            g_ni_cell_store = ni_i
        if str_eq(ns, "_dyncpy") != 0:
            g_ni_dyncpy = ni_i
        if str_eq(ns, "goroutine_wrapper_addr") != 0:
            g_ni_goroutine_wrapper_addr = ni_i
        ni_i = ni_i + 1

    print("  ni: syscall3=")
    print(int_str(g_ni_syscall3))
    print(" load8=")
    print(int_str(g_ni_load8))
    print(" w64=")
    print(int_str(g_ni_cell_store))
    print(" dyncpy=")
    println(int_str(g_ni_dyncpy))

    // Reset scratch-emission garbage (res_labels -> emit_instr -> pollutes rip_patch arrays)
    g_x86_rip_patch_count = 0
    g_x86_rodataref_count = 0
    g_x86_alloc_patch_count = 0
    g_x86_fnaddr_patch_count = 0

    println("  elf: Phase 1 (rodata layout)...")
    // Phase 1: rodata layout: collect string constants
    g_x86_str_count = 0
    si : ., mut = 0
    loop:
        if si >= g_ir_str_const_count:
            break
        g2_str_off(cell_load(g_ir_str_consts, si * 8))
        si = si + 1

    // Find g_rt_argc/g_rt_argv_ptr via name_idx (no str_eq loop)
    gv_argc = -1
    gv_argv = -1
    argc_ni := str_intern("g_rt_argc")
    argv_ni := str_intern("g_rt_argv_ptr")
    // Arena global variable indices
    gv_current_arena = -1
    gv_arena_cursors = -1
    gv_arena_slot_cursor = -1
    gv_arena_slot = -1
    gv_arena_static = -1
    gv_arena_slot_next = -1
    gv_arena_slot_free = -1
    gv_arena_slot_count = -1
    gv_arena_pool_slots = -1
    gv_segment_base = -1
    gv_class_base = -1
    gv_class_cursor = -1
    gv_class_limit = -1
    gv_class_sizes = -1
    gv_class_lookup = -1
    gv_alloc_fail_request = -1
    gv_alloc_fail_class = -1
    gv_alloc_fail_cursor = -1
    gv_alloc_fail_limit = -1
    gv_alloc_home_idx = -1
    gv_arena_sizes = -1
    gv_arena_pool_data = -1
    gv_arena_max_size = -1
    cur_ni := str_intern("g_current_arena")
    cur_ni2 := str_intern("g_arena_cursors")
    slot_cur_ni := str_intern("g_arena_slot_cursor")
    slot_ni := str_intern("g_arena_slot")
    static_ni := str_intern("g_arena_static")
    slot_next_ni := str_intern("g_arena_slot_next")
    slot_free_ni := str_intern("g_arena_slot_free")
    slot_count_ni := str_intern("g_arena_slot_count")
    pool_slots_ni := str_intern("g_arena_pool_slots")
    seg_base_ni := str_intern("g_segment_base")
    cls_ni1 := str_intern("g_class_base")
    cls_ni2 := str_intern("g_class_cursor")
    cls_ni3 := str_intern("g_class_limit")
    cls_sz_ni := str_intern("g_class_sizes")
    cls_lk_ni := str_intern("g_class_lookup")
    fail_ni1 := str_intern("g_alloc_fail_request")
    fail_ni2 := str_intern("g_alloc_fail_class")
    fail_ni3 := str_intern("g_alloc_fail_cursor")
    fail_ni4 := str_intern("g_alloc_fail_limit")
    home_ni := str_intern("g_alloc_home_idx")
    cur_ni3 := str_intern("g_arena_sizes")
    cur_ni4 := str_intern("g_arena_pool_data")
    cur_ni5 := str_intern("g_arena_max_size")
    cur_ni6 := str_intern("g_heap_ptr")
    cur_ni7 := str_intern("g_heap_end")
    cur_ni8 := str_intern("g_hp_config")
    cur_ni9 := str_intern("g_hp_inflight")
    gvsi : ., mut = 0
    loop:
        if gvsi >= g_ir_global_count:
            break
        ni := cell_load(g_ir_globals, gvsi * 24)
        if ni == argc_ni:
            gv_argc = cell_load(g_ir_globals, gvsi * 24 + 8)
        if ni == argv_ni:
            gv_argv = cell_load(g_ir_globals, gvsi * 24 + 8)
        if ni == cur_ni:
            gv_current_arena = cell_load(g_ir_globals, gvsi * 24 + 8)
        if ni == cur_ni2:
            gv_arena_cursors = cell_load(g_ir_globals, gvsi * 24 + 8)
        if ni == slot_cur_ni:
            gv_arena_slot_cursor = cell_load(g_ir_globals, gvsi * 24 + 8)
        if ni == slot_ni:
            gv_arena_slot = cell_load(g_ir_globals, gvsi * 24 + 8)
        if ni == static_ni:
            gv_arena_static = cell_load(g_ir_globals, gvsi * 24 + 8)
        if ni == slot_next_ni:
            gv_arena_slot_next = cell_load(g_ir_globals, gvsi * 24 + 8)
        if ni == slot_free_ni:
            gv_arena_slot_free = cell_load(g_ir_globals, gvsi * 24 + 8)
        if ni == slot_count_ni:
            gv_arena_slot_count = cell_load(g_ir_globals, gvsi * 24 + 8)
        if ni == pool_slots_ni:
            gv_arena_pool_slots = cell_load(g_ir_globals, gvsi * 24 + 8)
        if ni == seg_base_ni:
            gv_segment_base = cell_load(g_ir_globals, gvsi * 24 + 8)
        if ni == cls_ni1:
            gv_class_base = cell_load(g_ir_globals, gvsi * 24 + 8)
        if ni == cls_ni2:
            gv_class_cursor = cell_load(g_ir_globals, gvsi * 24 + 8)
        if ni == cls_ni3:
            gv_class_limit = cell_load(g_ir_globals, gvsi * 24 + 8)
        if ni == cls_sz_ni:
            gv_class_sizes = cell_load(g_ir_globals, gvsi * 24 + 8)
        if ni == cls_lk_ni:
            gv_class_lookup = cell_load(g_ir_globals, gvsi * 24 + 8)
        if ni == fail_ni1:
            gv_alloc_fail_request = cell_load(g_ir_globals, gvsi * 24 + 8)
        if ni == fail_ni2:
            gv_alloc_fail_class = cell_load(g_ir_globals, gvsi * 24 + 8)
        if ni == fail_ni3:
            gv_alloc_fail_cursor = cell_load(g_ir_globals, gvsi * 24 + 8)
        if ni == fail_ni4:
            gv_alloc_fail_limit = cell_load(g_ir_globals, gvsi * 24 + 8)
        if ni == home_ni:
            gv_alloc_home_idx = cell_load(g_ir_globals, gvsi * 24 + 8)
        if ni == cur_ni3:
            gv_arena_sizes = cell_load(g_ir_globals, gvsi * 24 + 8)
        if ni == cur_ni4:
            gv_arena_pool_data = cell_load(g_ir_globals, gvsi * 24 + 8)
        if ni == cur_ni5:
            gv_arena_max_size = cell_load(g_ir_globals, gvsi * 24 + 8)
        if ni == cur_ni6:
            gv_heap_ptr = cell_load(g_ir_globals, gvsi * 24 + 8)
        if ni == cur_ni7:
            gv_heap_end = cell_load(g_ir_globals, gvsi * 24 + 8)
        if ni == cur_ni8:
            gv_hp_config = cell_load(g_ir_globals, gvsi * 24 + 8)
        if ni == cur_ni9:
            gv_hp_inflight = cell_load(g_ir_globals, gvsi * 24 + 8)
        gvsi = gvsi + 1

    // Phase 2: compute sizes for all functions
    println("  elf: Phase 2 (size calc)...")
    // Estimate function code sizes (~8B/inst average). Correct BSS position
    // computed after Phase 3 emit (see rip_patch fixup below).
    max_labels : ., mut = 0
    sfi : ., mut = 0
    loop:
        if sfi >= g_ir_func_count:
            break
        ist2 := cell_load(g_ir_func_instr_start, sfi * 8)
        ic2 := cell_load(g_ir_func_instr_count, sfi * 8)
        // Count label indices for g_label_poses allocation
        cur_labels : ., mut = 0
        ii2 : ., mut = 0
        loop:
            if ii2 >= ic2:
                break
            op := iri_op(ist2 + ii2)
            if op == IR_LABEL:
                lx := iri_s1(ist2 + ii2)
                if lx >= 0 && lx + 1 > cur_labels:
                    cur_labels = lx + 1
            if op == IR_JUMP:
                lz := iri_s1(ist2 + ii2)
                if lz + 1 > cur_labels:
                    cur_labels = lz + 1
            ii2 = ii2 + 1
        if cur_labels > max_labels:
            max_labels = cur_labels
        grow_func_code_sz(sfi + 1)
        cell_store(g_x86_func_code_sz, sfi * 8, ic2 * 5)
        sfi = sfi + 1
    g_label_count = max_labels

    total_code : ., mut = emit_start_size()
    fi : ., mut = 0
    g2_init()
    loop:
        if fi >= g_ir_func_count:
            break
        if fi % 50 == 0:
            print("    func ")
            print(int_str(fi))
            print("/")
            println(int_str(g_ir_func_count))
        ni := cell_load(g_ir_func_name_idx, fi * 8)
        grow_func_offsets(g_x86_func_off_count * 2 + 2)
        cell_store(g_x86_func_offsets, g_x86_func_off_count * 16, ni)
        cell_store(g_x86_func_offsets, g_x86_func_off_count * 16 + 8, total_code)
        g_x86_func_off_count = g_x86_func_off_count + 1

        vc2 := cell_load(g_ir_func_var_count, fi * 8)
        vs2 := cell_load(g_ir_func_var_start, fi * 8)
        pc2 := cell_load(g_ir_func_param_count, fi * 8)

        fsz := cell_load(g_x86_func_code_sz, fi * 8)
        // Frame size comes from frame.cr. SysV requires 16-byte alignment: after
        // a call rsp is 8 mod 16. With opt >= 1 there are 6 pushes (rbx, r12-r15,
        // rbp), so the frame size must be 8 mod 16. With opt < 1 there is 1 push
        // (rbp), so the frame size must be 0 mod 16. This dry-run and the Phase 3
        // sub rsp immediate call the same pf_frame_size. The frame byte count is
        // pf_frame_overhead and must match the actual pf_prologue and pf_epilogue
        // emission. This file does not compute frame sizes.
        g_x86_emit_stack_size = pf_frame_size(vc2)
        ss_dry := g_x86_emit_stack_size
        total_code = total_code + pf_frame_overhead(ss_dry)
        reg_pc2 : ., mut = pc2
        if reg_pc2 > 6:
            reg_pc2 = 6
        stack_pc2 : ., mut = pc2 - 6
        if stack_pc2 < 0:
            stack_pc2 = 0
        total_code = total_code + reg_pc2 * sz_save_param()
        total_code = total_code + stack_pc2 * sz_save_stack_param()
        total_code = total_code + fsz
        fi = fi + 1

    rd_sz := g2_rodata_sz()
    total_code = total_code + 6  // _init_globals

    // alloc: bump allocator for heap allocation in ELF output
    // Find alloc's name index in .ccr string table (not runtime str_intern)
    alloc_ni : ., mut = -1
    asi : ., mut = 0
    loop:
        if asi >= g_str_count:
            break
        if str_eq(istr_get(asi), "alloc") != 0:
            alloc_ni = asi
            break
        asi = asi + 1
    if alloc_ni < 0:
        alloc_ni = str_intern("alloc")
    grow_func_offsets(g_x86_func_off_count * 2 + 2)
    cell_store(g_x86_func_offsets, g_x86_func_off_count * 16, alloc_ni)
    cell_store(g_x86_func_offsets, g_x86_func_off_count * 16 + 8, total_code)
    g_x86_func_off_count = g_x86_func_off_count + 1
    total_code = total_code + 330  // arena-aware dual-path alloc body (~323 bytes with OOM check + zero-init + chain-expand + current-arena check)
    // heap_expand
    grow_func_offsets(g_x86_func_off_count * 2 + 2)
    cell_store(g_x86_func_offsets, g_x86_func_off_count * 16, str_intern("heap_expand"))
    cell_store(g_x86_func_offsets, g_x86_func_off_count * 16 + 8, total_code)
    g_x86_func_off_count = g_x86_func_off_count + 1
    total_code = total_code + 86  // heap_expand with allocator-state save/restore
    // sched_call trampolines (0..4)
    grow_func_offsets(g_x86_func_off_count * 2 + 2)
    cell_store(g_x86_func_offsets, g_x86_func_off_count * 16, str_intern("sched_call_0"))
    cell_store(g_x86_func_offsets, g_x86_func_off_count * 16 + 8, total_code)
    g_x86_func_off_count = g_x86_func_off_count + 1
    total_code = total_code + sched_tramp_sz(0)
    grow_func_offsets(g_x86_func_off_count * 2 + 2)
    cell_store(g_x86_func_offsets, g_x86_func_off_count * 16, str_intern("sched_call_1"))
    cell_store(g_x86_func_offsets, g_x86_func_off_count * 16 + 8, total_code)
    g_x86_func_off_count = g_x86_func_off_count + 1
    total_code = total_code + sched_tramp_sz(1)
    grow_func_offsets(g_x86_func_off_count * 2 + 2)
    cell_store(g_x86_func_offsets, g_x86_func_off_count * 16, str_intern("sched_call_2"))
    cell_store(g_x86_func_offsets, g_x86_func_off_count * 16 + 8, total_code)
    g_x86_func_off_count = g_x86_func_off_count + 1
    total_code = total_code + sched_tramp_sz(2)
    grow_func_offsets(g_x86_func_off_count * 2 + 2)
    cell_store(g_x86_func_offsets, g_x86_func_off_count * 16, str_intern("sched_call_3"))
    cell_store(g_x86_func_offsets, g_x86_func_off_count * 16 + 8, total_code)
    g_x86_func_off_count = g_x86_func_off_count + 1
    total_code = total_code + sched_tramp_sz(3)
    grow_func_offsets(g_x86_func_off_count * 2 + 2)
    cell_store(g_x86_func_offsets, g_x86_func_off_count * 16, str_intern("sched_call_4"))
    cell_store(g_x86_func_offsets, g_x86_func_off_count * 16 + 8, total_code)
    g_x86_func_off_count = g_x86_func_off_count + 1
    total_code = total_code + sched_tramp_sz(4)
    if g_x86_emit_rt_stubs != 0:
        // g_set_curg / g_get_curg bridges (11 bytes each): pure-static self-containment
        grow_func_offsets(g_x86_func_off_count * 2 + 2)
        cell_store(g_x86_func_offsets, g_x86_func_off_count * 16, str_intern("g_set_curg"))
        cell_store(g_x86_func_offsets, g_x86_func_off_count * 16 + 8, total_code)
        g_x86_func_off_count = g_x86_func_off_count + 1
        total_code = total_code + 11
        grow_func_offsets(g_x86_func_off_count * 2 + 2)
        cell_store(g_x86_func_offsets, g_x86_func_off_count * 16, str_intern("g_get_curg"))
        cell_store(g_x86_func_offsets, g_x86_func_off_count * 16 + 8, total_code)
        g_x86_func_off_count = g_x86_func_off_count + 1
        total_code = total_code + 11

    hdr_total : ., mut = EHDR_SIZE + 2 * PHDR_SIZE
    rodata_base := total_code
    g_x86_rodata_base = hdr_total + rodata_base

    println("  elf: Phase 3 (emit)...")
    // Phase 3: emit to buffer
    cp : ., mut = hdr_total  // skip ELF header + program headers

    // NB: g_x86_is_global already marked before Phase 0: no need to redo

    // ── _start (measured size from Phase 2) ──
    cp = cp + emit_start(buf, cp)

    // ── All functions ──
    g_x86_ret_patch_count = 0
    g_x86_call_patch_count = 0
    g_x86_fnaddr_patch_count = 0
    g_x86_rodataref_count = 0
    g_x86_alloc_patch_count = 0
    g_x86_ext_rel_count = 0
    // Per-run emission counter: reset before the sizing-result Phase 3 pass so
    // it counts real emission only, not the Phase 2 sizing calls.
    g_match_bin_emits = 0
    g_match_table_emits = 0
    g_match_table_cursor = 0
    g_match_table_ref_count = 0
    // Global label -> absolute position map for the rodata table writer. g_label_poses
    // is overwritten per function; table targets are global label numbers.
    if g_label_abs_cap < g_label_count:
        grow_label_abs(g_label_count)
    lab_abs_i : ., mut = 0
    loop:
        if lab_abs_i >= g_label_count:
            break
        cell_store(g_label_abs, lab_abs_i * 8, -1)
        lab_abs_i = lab_abs_i + 1
    fi = 0
    loop:
        if fi >= g_ir_func_count:
            break
        if fi % 50 == 0:
            print("    emit func ")
            print(int_str(fi))
            print("/")
            println(int_str(g_ir_func_count))
        ni := cell_load(g_ir_func_name_idx, fi * 8)
        grow_func_cp(fi + 1)
        cell_store(g_x86_func_cp, fi * 8, cp)
        // Override with actual position for backward calls
        fi3 : ., mut = 0
        loop:
            if fi3 >= g_x86_func_off_count:
                break
            if str_eq(istr_get(cell_load(g_x86_func_offsets, fi3*16)), istr_get(ni)) != 0:
                cell_store(g_x86_func_offsets, fi3*16+8, cp - 176)
                break
            fi3 = fi3 + 1
        ist := cell_load(g_ir_func_instr_start, fi * 8)
        ic := cell_load(g_ir_func_instr_count, fi * 8)
        vc := cell_load(g_ir_func_var_count, fi * 8)
        vs := cell_load(g_ir_func_var_start, fi * 8)
        pc := cell_load(g_ir_func_param_count, fi * 8)

        g2_init()
        g_current_func_var_start = vs
        vi : ., mut = 0
        loop:
            if vi >= vc:
                break
            g2_slot(vs + vi)
            vi = vi + 1
        // Frame size uses the shared pf_frame_size; SysV 16-byte alignment is
        // the same rule as the Phase 2 dry-run.
        g_x86_emit_stack_size = pf_frame_size(vc)

        // Init label state for single-pass backpatching (-1 = not yet seen)
        li2 : ., mut = 0
        loop:
            if li2 >= g_label_count:
                break
            grow_label_poses(li2 + 1)
            cell_store(g_label_poses, li2*8, -1)
            li2 = li2 + 1
        g_pending_count = 0

        // Prologue, parameter stores, and register parameter loads
        // (frame.cr pf_prologue). With opt >= 1: save six callee-saved registers,
        // push rbp, mov rbp,rsp, reserve the frame with a placeholder immediate,
        // store parameters (XMM, int, stack), clear parameter tags, then load
        // register-allocated parameters. ss is the pf_frame_size result.
        cp = pf_prologue(vs, pc, g_x86_emit_stack_size, buf, cp)

        // Function body: emit instructions.
        g_x86_func_frame_start = cp  // absolute buffer pos of body start
        save_ss := g_x86_emit_stack_size  // save frame size before emission

        ii : ., mut = 0
        loop:
            if ii >= ic:
                break
            inst_idx := ist + ii
            sz : ., mut = -1
            if hit_table_active() != 0:
                sz = emit_instr_tabled(inst_idx, buf, cp)
            if sz < 0:
                sz = emit_instr(inst_idx, buf, cp)
            cp = cp + sz
            ii = ii + 1

        // Epilogue (frame.cr pf_epilogue). Patch returns, fill the sub rsp
        // immediate with save_ss, emit the epilogue (add rsp, reverse
        // callee-saved pops with opt >= 1, pop rbp, ret).
        cp = pf_epilogue(save_ss, buf, cp)
        fi = fi + 1

    // Event-stream rel32 backfill. Kind 0 means an event-stream position.
    // Jump events register during event byte emission (instr.cr hit_rel_add). The
    // target is an event ordinal; resolve it through g_hit_ev_pos and write
    // disp = target - (rel field + 4), the same formula as label backfill.
    // Kind 1 and 2 (function start and external symbol) are not implemented. If
    // they appear, print a diagnostic and reject.
    // The count is read into a local and guarded by an outer if. The loop body
    // does not change the count, and the reset runs unconditionally. This shape
    // avoids an uninitialized boundary read at the tail of a large function when
    // compiled by the self-hosted compiler.
    hri2 : ., mut = g_hit_rel_count
    if hri2 > 0:
        hri : ., mut = 0
        loop:
            if hri >= hri2:
                break
            rk := cell_load(g_hit_rel, hri * 24)
            rp := cell_load(g_hit_rel, hri * 24 + 8)
            rt := cell_load(g_hit_rel, hri * 24 + 16)
            if rk == 0:
                if rt >= 0 && rt < g_hit_ev_pos_count:
                    tp := cell_load(g_hit_ev_pos, rt * 8)
                    w32(buf, rp, tp - (rp + 4))
                else:
                    print("  MISSING event position for rel target ordinal ")
                    println(int_str(rt))
            else:
                print("  BAD rel kind ")
                print(int_str(rk))
                println(" (func/extern backfill not implemented)")
            hri = hri + 1
    g_hit_rel_count = 0

    // ── _init_globals ──
    w8(buf, cp, 85)
    cp = cp + 1
    w8(buf, cp, 72)
    w8(buf, cp+1, 137)
    w8(buf, cp+2, 229)
    cp = cp + 3
    w8(buf, cp, 93)
    cp = cp + 1
    w8(buf, cp, 195)
    cp = cp + 1

    // ── alloc (bump allocator) ──
    // BSS VA will be computed after all code emitted: placeholder for now
    bss_va : ., mut = ((TEXT_BASE + cp + 4096 + 4095) / 4096) * 4096

    max_gv : ., mut = 0
    gsi : ., mut = 0
    loop:
        if gsi >= g_ir_global_count:
            break
        gvv := cell_load(g_ir_globals, gsi * 24 + 8)
        if gvv >= 0 && gvv > max_gv:
            max_gv = gvv
        gsi = gsi + 1
    // globals_size = (max_var_idx + 1) * 8 ensures BSS covers all globals
    globals_size : ., mut = (max_gv + 1) * 8
    if globals_size < 256:
        globals_size = 256
    if g_x86_emit_rt_stubs != 0:
        globals_size = globals_size + 8
    // + current_g slot
    alloc_sz := emit_alloc_body(buf, cp, bss_va, globals_size)
    alloc_start := cp
    g_curg_stub_start : ., mut = -1
    cp = cp + alloc_sz

    // ── heap_expand ──
    heap_expand_start : ., mut = cp
    cp = cp + emit_heap_expand(buf, cp, bss_va)
    // Update heap_expand's offset in func_offsets to real position (Phase 3 value)
    hefi : ., mut = 0
    loop:
        if hefi >= g_x86_func_off_count:
            break
        if str_eq(istr_get(cell_load(g_x86_func_offsets, hefi*16)), "heap_expand") != 0:
            cell_store(g_x86_func_offsets, hefi*16+8, heap_expand_start - 176)
            break
        hefi = hefi + 1

    // Update alloc's offset in func_offsets to real position (Phase 3 value)
    afi2 : ., mut = 0
    loop:
        if afi2 >= g_x86_func_off_count:
            break
        if str_eq(istr_get(cell_load(g_x86_func_offsets, afi2*16)), istr_get(alloc_ni)) != 0:
            cell_store(g_x86_func_offsets, afi2*16+8, alloc_start - 176)
            break
        afi2 = afi2 + 1

    // Patch all IR_ALLOC_STRUCT/ARRAY/MAKE_ENUM call sites to point to alloc
    // alloc_patch_pos entries are buffer positions of the 5-byte call instruction
    // alloc offset = alloc_start - 176 (relative to code section start)
    alloc_code_off := alloc_start - 176
    api : ., mut = 0
    loop:
        if api >= g_x86_alloc_patch_count:
            break
        call_pos := cell_load(g_x86_alloc_patch_pos, api * 8)
        rel := (176 + alloc_code_off) - (call_pos + 5)
        w32(buf, call_pos + 1, rel)
        api = api + 1
    g_x86_alloc_patch_count = 0

    // ── arena_new/arena_reset stubs (fallback when arena.cr not imported) ──
    // These are only used when the functions aren't compiled from user code.
    // If the user imports arena, the compiled versions in g_ir_func_name_idx take priority.
    grow_func_offsets(g_x86_func_off_count * 2 + 2)
    cell_store(g_x86_func_offsets, g_x86_func_off_count * 16, str_intern("arena_new"))
    cell_store(g_x86_func_offsets, g_x86_func_off_count * 16 + 8, cp - 176)
    g_x86_func_off_count = g_x86_func_off_count + 1
    w8(buf, cp, 195)
    cp = cp + 1  // ret

    grow_func_offsets(g_x86_func_off_count * 2 + 2)
    cell_store(g_x86_func_offsets, g_x86_func_off_count * 16, str_intern("arena_reset"))
    cell_store(g_x86_func_offsets, g_x86_func_off_count * 16 + 8, cp - 176)
    g_x86_func_off_count = g_x86_func_off_count + 1
    w8(buf, cp, 195)
    cp = cp + 1  // ret

    // ── scheduler call trampolines ──
    sched_reg_one("sched_call_0", 0, cp)
    cp = cp + emit_sched_call(buf, cp, 0)
    sched_reg_one("sched_call_1", 1, cp)
    cp = cp + emit_sched_call(buf, cp, 1)
    sched_reg_one("sched_call_2", 2, cp)
    cp = cp + emit_sched_call(buf, cp, 2)
    sched_reg_one("sched_call_3", 3, cp)
    cp = cp + emit_sched_call(buf, cp, 3)
    sched_reg_one("sched_call_4", 4, cp)
    cp = cp + emit_sched_call(buf, cp, 4)

    // ── g_set_curg / g_get_curg bridge stubs (pure-static self-contained runtime) ──
    // Provisional BSS VA (0); re-emitted in place after final bss_va is known.
    if g_x86_emit_rt_stubs != 0:
        g_curg_stub_start = cp
        cp = cp + emit_curg_stubs(buf, cp, 0)
        // Update func_offsets entries to real positions (call_patch fallback uses these)
        gsi2 : ., mut = 0
        loop:
            if gsi2 >= g_x86_func_off_count:
                break
            nm2 := istr_get(cell_load(g_x86_func_offsets, gsi2*16))
            if str_eq(nm2, "g_set_curg") != 0:
                cell_store(g_x86_func_offsets, gsi2*16+8, g_curg_stub_start - 176)
            if str_eq(nm2, "g_get_curg") != 0:
                cell_store(g_x86_func_offsets, gsi2*16+8, g_curg_stub_start - 176 + 11)
            gsi2 = gsi2 + 1

    // ── Goroutine runtime stubs (fiber_init / fiber_switch / goroutine_entry_wrapper) ──
    // Required by g_new -> go f(): the wrapper is the fiber entry, fiber_init
    // builds the fake frame, fiber_switch performs the context switch.
    // Registered in func_offsets so IR_CALL (fiber_init/fiber_switch from
    // Core) and IR_FNADDR (@addr(goroutine_entry_wrapper)) resolve here.
    if g_x86_emit_rt_stubs != 0:
        sched_reg_one("fiber_init", 0, cp)
        sched_reg_one("fiber_switch", 0, cp + 20)
        sched_reg_one("goroutine_entry_wrapper", 0, cp + 47)
        cp = cp + emit_goroutine_stubs(buf, cp)
        // m_start_workers: worker thread launcher (clone). worker_entry
        // (15 bytes) precedes the public entry so its RIP-relative LEA stays
        // backward; register the public symbol at cp + 15.
        sched_reg_one("m_start_workers", 0, cp + 15)
        cp = cp + emit_m_start_workers(buf, cp)

    // ── BigInt runtime blob (--big-int) ──
    // The generated blob is raw-core machine code plus its data.  It is placed
    // in the code segment; --big-int marks that segment writable so the runtime's
    // g_bi_error/g_bi_rem slots work.  All intra-blob relocations were resolved
    // by tools/gen_bigint_blob.py; the only external calls are the four alloc
    // sites, which are patched to the allocator emitted above.
    if g_x86_big_enabled != 0:
        blob := bigint_blob_bytes()
        blob_start := cp
        g_x86_big_blob_start = blob_start
        bi : ., mut = 0
        loop:
            if bi >= BIGINT_BLOB_SIZE:
                break
            store8(buf, blob_start + bi, load8(blob, bi))
            bi = bi + 1
        cp = cp + BIGINT_BLOB_SIZE

        // Register every bi_* entry so IR_CALL placeholders and the arithmetic
        // cold paths resolve through the normal func_offsets fallback.
        sci : ., mut = 0
        loop:
            if sci >= bigint_blob_symbol_count():
                break
            sym_name := bigint_blob_symbol_name(sci)
            sym_off := bigint_blob_symbol(sym_name)
            if sym_off >= 0:
                grow_func_offsets(g_x86_func_off_count * 2 + 2)
                cell_store(g_x86_func_offsets, g_x86_func_off_count * 16,
                    str_intern(sym_name))
                cell_store(g_x86_func_offsets, g_x86_func_off_count * 16 + 8,
                    blob_start + sym_off - 176)
                g_x86_func_off_count = g_x86_func_off_count + 1
            sci = sci + 1

        aci : ., mut = 0
        loop:
            if aci >= bigint_blob_alloc_count():
                break
            aoff := bigint_blob_alloc_off(aci)
            call_pos := blob_start + aoff
            // gen_bigint_blob records the relocation offset, i.e. the first byte
            // of the call's rel32 immediate.  The call opcode is at call_pos-1.
            w32(buf, call_pos, alloc_start - (call_pos + 4))
            aci = aci + 1

        // _start's exit conversion call was emitted before the function list
        // reset the general call-patch table.  Resolve it explicitly now that the
        // blob's bi_to_word_checked entry is registered.
        if g_x86_big_exit_call_pos >= 0:
            exi : ., mut = 0
            loop:
                if exi >= g_x86_func_off_count:
                    break
                if str_eq(istr_get(cell_load(g_x86_func_offsets, exi * 16)),
                    "bi_to_word_checked") != 0:
                    ex_off := cell_load(g_x86_func_offsets, exi * 16 + 8)
                    ex_target := 176 + ex_off
                    w32(buf, g_x86_big_exit_call_pos + 1,
                        ex_target - (g_x86_big_exit_call_pos + 5))
                    break
                exi = exi + 1

    // ── Patch forward calls using actual cp positions ──
    // Phase 3 stored cp at start of each function in g_x86_func_cp
    // Must run after ALL code emitted (incl alloc + sched_call) so func_offsets are final
    cpi : ., mut = 0
    loop:
        if cpi >= g_x86_call_patch_count:
            break
        call_pos := cell_load(g_x86_call_patch_pos, cpi * 8)
        fn_ni := cell_load(g_x86_call_patch_name, cpi * 8)
        cfi2 : ., mut = 0
        loop:
            if cfi2 >= g_ir_func_count:
                break
            name_at := cell_load(g_ir_func_name_idx, cfi2 * 8)
            if str_eq(istr_get(name_at), istr_get(fn_ni)) != 0:
                func_cp := cell_load(g_x86_func_cp, cfi2 * 8)
                if func_cp > 0:
                    rel := func_cp - (call_pos + 5)
                    w32(buf, call_pos + 1, rel)
                break
            cfi2 = cfi2 + 1
        // Fallback: search g_x86_func_offsets for builtins
        if cfi2 >= g_ir_func_count:
            bfi2 : ., mut = 0
            loop:
                if bfi2 >= g_x86_func_off_count:
                    break
                if str_eq(istr_get(cell_load(g_x86_func_offsets, bfi2*16)), istr_get(fn_ni)) != 0:
                    func_off := cell_load(g_x86_func_offsets, bfi2*16+8)
                    // Safety check: target must be within emitted code
                    target_pos := 176 + func_off
                    if target_pos > 0 && target_pos < cp:
                        rel := target_pos - (call_pos + 5)
                        w32(buf, call_pos + 1, rel)
                    break
                bfi2 = bfi2 + 1
        cpi = cpi + 1
    g_x86_call_patch_count = 0

    // ── Patch function addresses (IR_FNADDR movabs placeholders) ──
    // Each placeholder is a movabs r10, imm64 at an absolute buffer position.
    // Resolve the same way as call patches: user functions by name in
    // g_ir_func_name_idx/g_x86_func_cp, builtins via g_x86_func_offsets.
    fpi : ., mut = 0
    loop:
        if fpi >= g_x86_fnaddr_patch_count:
            break
        fp_pos := cell_load(g_x86_fnaddr_patch_pos, fpi * 8)
        fn_ni := cell_load(g_x86_fnaddr_patch_name, fpi * 8)
        fn_va : ., mut = 0
        fcfi : ., mut = 0
        loop:
            if fcfi >= g_ir_func_count:
                break
            name_at := cell_load(g_ir_func_name_idx, fcfi * 8)
            if str_eq(istr_get(name_at), istr_get(fn_ni)) != 0:
                func_cp := cell_load(g_x86_func_cp, fcfi * 8)
                if func_cp > 0:
                    fn_va = TEXT_BASE + func_cp
                break
            fcfi = fcfi + 1
        // Fallback: search g_x86_func_offsets for builtins
        if fn_va == 0:
            bfi3 : ., mut = 0
            loop:
                if bfi3 >= g_x86_func_off_count:
                    break
                if str_eq(istr_get(cell_load(g_x86_func_offsets, bfi3*16)), istr_get(fn_ni)) != 0:
                    func_off := cell_load(g_x86_func_offsets, bfi3*16+8)
                    target_pos := 176 + func_off
                    if target_pos > 0 && target_pos < cp:
                        fn_va = TEXT_BASE + target_pos
                    break
                bfi3 = bfi3 + 1
        if fn_va > 0:
            cell_store(buf, fp_pos + 2, fn_va)
        // imm64 placeholder starts after the 49 BB opcode
        fpi = fpi + 1
    g_x86_fnaddr_patch_count = 0

    // Pad code to page boundary so RW segment doesn't share a page with RX
    // (kernel maps shared page with RW permissions -> code becomes non-executable)
    code_pad_end := (cp + 4095) / 4096 * 4096
    loop:
        if cp >= code_pad_end:
            break
        w8(buf, cp, 0)
        cp = cp + 1

    // Set rodata base from actual emission position
    g_x86_rodata_base = cp

    // Patch LEA rodata references (recorded during instr emission)
    rri : ., mut = 0
    loop:
        if rri >= g_x86_rodataref_count:
            break
        lea_pos := cell_load(g_x86_rodataref_pos, rri * 8)
        ro_off := cell_load(g_x86_rodataref_ro, rri * 8)
        rel := g_x86_rodata_base + ro_off - (lea_pos + 7)
        w32(buf, lea_pos + 3, rel)
        rri = rri + 1
    g_x86_rodataref_count = 0

    // ── .rodata ──
    si = 0
    loop:
        if si >= g_x86_str_count:
            break
        s := istr_get(cell_load(g_x86_str_offs, si * 8))
        sl := str_len(s)
        // Write 8-byte length header (sl + null) so str_len via load64(s,-8) works
        cell_store(buf, cp, sl + 1)
        cp = cp + 8
        ci : ., mut = 0
        loop:
            if ci >= sl:
                break
            w8(buf, cp, load8(s, ci))
            ci = ci + 1
            cp = cp + 1
        w8(buf, cp, 0)
        cp = cp + 1
        loop:
            if cp % 8 == 0:
                break
            w8(buf, cp, 0)
            cp = cp + 1
        si = si + 1

    // Dense MATCH jump tables: after strings, before the HIT pool, 4-aligned.
    // The writer rescans functions in emission order with the same predicate, so
    // each table lands at the in-rodata offset recorded by its LEA reference.
    // Strings end 8-aligned, so no pad is needed here.
    cp = cp + e2_match_write_tables(buf, cp)

    // HIT constant pool: lower the constant pool into rodata.
    // 池引用（mov r64, [rip+disp32] 占位）在函数发射期间记录（instr.cr 编码器）；
    // 字符串区定稿后回填 disp（池区紧随字符串，8B/槽、8 对齐不破）。
    hpr : ., mut = 0
    loop:
        if hpr >= g_hit_pool_patch_count:
            break
        pp := cell_load(g_hit_pool_patch, hpr * 16)
        pk := cell_load(g_hit_pool_patch, hpr * 16 + 8)
        rel := cp + pk * 8 - (pp + 7)
        w32(buf, pp + 3, rel)
        hpr = hpr + 1
    g_hit_pool_patch_count = 0
    hpk : ., mut = 0
    loop:
        if hpk >= g_hit_pool_count:
            break
        cell_store(buf, cp + hpk * 8, cell_load(g_hit_pool, hpk * 8))
        hpk = hpk + 1
    cp = cp + g_hit_pool_count * 8

    // ── Recompute bss_va after all code emitted ──
    // total_code from Phase 2 underestimates; use actual cp for precise calculation.
    // +1 ensures BSS is on a different page from code.
    bss_va = ((TEXT_BASE + cp + 4096 + 4095) / 4096) * 4096

    // The allocator was emitted earlier with a provisional BSS address.
    // Re-emit it in place now that the final data-segment VA is known.
    emit_alloc_body(buf, alloc_start, bss_va, globals_size)

    // Re-emit heap_expand with correct BSS VA
    emit_heap_expand(buf, heap_expand_start, bss_va)

    // Re-emit g_set_curg/g_get_curg stubs with the final current_g BSS VA.
    // Slot sits at the end of the globals region (globals_size includes +8).
    if g_x86_emit_rt_stubs != 0 && g_curg_stub_start >= 0:
        curg_va := bss_va + 16 + globals_size - 8
        emit_curg_stubs(buf, g_curg_stub_start, curg_va)

    // Patch call to heap_expand inside alloc body (re-emit wrote placeholder offset 0)
    if g_heap_expand_call_pos >= 0:
        rel_he_call := heap_expand_start - (g_heap_expand_call_pos + 5)
        w32(buf, g_heap_expand_call_pos + 1, rel_he_call)
        g_heap_expand_call_pos = -1

    // ── Allocate BSS for globals ──
    gi2 : ., mut = 0
    goff : ., mut = 0
    loop:
        if gi2 >= g_ir_global_count:
            break
        gv2 := cell_load(g_ir_globals, gi2 * 24 + 8)
        if gv2 >= 0:
            grow_global_off(gv2 + 1)
            cell_store(g_x86_global_off, gv2 * 8, goff)
            goff = goff + 8
        gi2 = gi2 + 1

    // ── Patch global variable RIP-relative references ──
    rpi2 : ., mut = 0
    loop:
        if rpi2 >= g_x86_rip_patch_count:
            break
        ppos := cell_load(g_x86_rip_patch_pos, rpi2 * 8)
        gvi := cell_load(g_x86_rip_patch_globals, rpi2 * 8)
        // Verify: buffer at ppos-3 should contain LEA prefix (0x4C or 0x4D for REX.WR/WRB)
        lea_check := bu8(buf, ppos - 3)
        if lea_check != 72 && lea_check != 73 && lea_check != 76 && lea_check != 77 && lea_check != 74 && lea_check != 78 && lea_check != 79 && lea_check != 75:
            print("  BAD rip[")
            print(int_str(rpi2))
            print("] ppos=")
            print(int_str(ppos))
            print(" gvi=")
            print(int_str(gvi))
            print(" byte=")
            println(int_str(lea_check))
        if gvi >= 0:
            lea_end_va := TEXT_BASE + ppos + 4
            off := cell_load(g_x86_global_off, gvi * 8)
            target_va := bss_va + 16 + off
            rel := target_va - lea_end_va
            w32(buf, ppos, rel)
            // Verify write: read back and check
            rb0 := bu8(buf, ppos)
            rb1 := bu8(buf, ppos + 1)
            rb2 := bu8(buf, ppos + 2)
            rb3 := bu8(buf, ppos + 3)
            rbv : ., mut = rb0 + rb1 * 256 + rb2 * 65536
            if rb3 >= 128:
                rbv = rbv + (rb3 - 256) * 16777216
            else:
                rbv = rbv + rb3 * 16777216
            if rbv != rel && gvi >= 0 && gvi < 10:
                print("  MISMATCH ppos=")
                print(int_str(ppos))
                print(" rel=")
                print(int_str(rel))
                print(" rbv=")
                println(int_str(rbv))
        rpi2 = rpi2 + 1
    g_x86_rip_patch_count = 0

    // ── Patch _start's call to main ──
    // Search g_x86_func_offsets by name (indices differ from g_ir_func_name_idx)
    mo : ., mut = -1
    bfi3 : ., mut = 0
    loop:
        if bfi3 >= g_x86_func_off_count:
            break
        if str_eq(istr_get(cell_load(g_x86_func_offsets, bfi3*16)), "main") != 0:
            mo = cell_load(g_x86_func_offsets, bfi3*16+8)
            break
        bfi3 = bfi3 + 1
    // Debug: find ALL entries named "main"
    bfi4 : ., mut = 0
    loop:
        if bfi4 >= g_x86_func_off_count:
            break
        nm := istr_get(cell_load(g_x86_func_offsets, bfi4*16))
        if str_eq(nm, "main") != 0:
            off := cell_load(g_x86_func_offsets, bfi4*16+8)
            print("  main at [")
            print(int_str(bfi4))
            print("] off=")
            print(int_str(off))
            print(" cp=")
            println(int_str(off + 176))
        bfi4 = bfi4 + 1
    if mo >= 0:
        rel := mo + 176 - g_call_main_pos - 5
        w32(buf, g_call_main_pos + 1, rel)

    // ── bss_init: zero BSS globals area before _start ──
    // WSL2 (and possibly other kernels) do not reliably zero BSS,
    // so we explicitly clear the first BSS_ZERO_SIZE bytes with
    // rep stosb. This stub becomes the new entry point; after
    // zeroing it jumps to the real _start.
    bss_init_cp := cp
    BSS_ZERO_SIZE : int = 131072  // 128 KB: covers all globals

    // lea rdi, [rip + rel]  -> rdi = bss_va
    rel_di := bss_va - (TEXT_BASE + cp + 7)
    w8(buf, cp, 72)
    w8(buf, cp+1, 141)
    w8(buf, cp+2, 61)
    w8_signed(buf, cp+3, rel_di)
    cp = cp + 7

    // mov ecx, BSS_ZERO_SIZE
    w8(buf, cp, 185)
    e2_w32(buf, cp+1, BSS_ZERO_SIZE)
    cp = cp + 5

    // xor eax, eax; cld; rep stosb
    w8(buf, cp, 49)
    w8(buf, cp+1, 192)
    cp = cp + 2
    w8(buf, cp, 252)
    cp = cp + 1
    w8(buf, cp, 243)
    w8(buf, cp+1, 170)
    cp = cp + 2

    // jmp _start  (TEXT_BASE + 176)
    jmp_rel := TEXT_BASE + 176 - (TEXT_BASE + cp + 5)
    w8(buf, cp, 233)
    e2_w32(buf, cp+1, jmp_rel)
    cp = cp + 5

    // ── Write ELF header ──
    total_sz := cp
    // Use actual total_sz as code_end so code segment covers all emitted content
    elf2_hdr(buf, total_sz, total_sz)
    if g_x86_big_enabled != 0:
        // The BigInt blob carries a few writable runtime words in the code
        // segment.  Mark that PT_LOAD RWX instead of adding another segment;
        // user code itself remains the only executable content.
        w32(buf, EHDR_SIZE + 4, 7)
    // Override entry point to bss_init (which zeroes heap then jumps to _start)
    cell_store(buf, E_ENTRY, TEXT_BASE + bss_init_cp)
    // Patch data segment VA to match bss_va (page after code+rodata)
    data_phdr_base := EHDR_SIZE + PHDR_SIZE
    cell_store(buf, data_phdr_base + P_OFFSET, bss_va - TEXT_BASE)
    cell_store(buf, data_phdr_base + P_VADDR, bss_va)
    cell_store(buf, data_phdr_base + P_PADDR, bss_va)
    g_asm_code_size = total_sz
    return total_sz
