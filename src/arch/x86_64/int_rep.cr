// === int_rep.cr ===
// Tagged mathematical-int helpers for the x86-64 backend.
//
// The backend's public int slot is a tagged value:
//   low bit 0: mathematical value times two (immediate)
//   low bit 1: pointer to a BigInt object plus one
//
// Only user programs run in this mode.  corearch itself, and the BigInt runtime
// blob generated from src/runtime/bigint.cr, use raw machine integers.
// This file owns the encoding helpers and the cold-path jump/call emitters; the
// arithmetic policy lives in instr.cr next to the old 64-bit path.

BI_TAG_IMM_MAX : int = 4611686018427387903   // 2^62 - 1
BI_TAG_IMM_MIN : int = -4611686018427387904  // -2^62

// --big-int state is in backend_globals.cr so both entry points set it once.

fn e2_big_mov_imm64(buf: string, p: int, reg: int, value: int) -> int:
    // movabs reg, imm64 — REX.W (+B for reg>=8), 0xB8+reg, imm64
    cp := p
    cp = cp + emit_rex(buf, cp, 1, 0, 0, reg / 8)
    e2_w8(buf, cp, 184 + reg % 8)
    cp = cp + 1
    cp = cp + e2_w64(buf, cp, value)
    return cp - p

fn e2_big_test_tag(buf: string, p: int, reg: int) -> int:
    // test reg, 1 — REX.W(+B), 0xF7 /0, imm32 1
    cp := p
    cp = cp + emit_rex(buf, cp, 1, 0, 0, reg / 8)
    e2_w8(buf, cp, 247)
    cp = cp + 1
    cp = cp + emit_modrm(buf, cp, 3, 0, reg % 8)
    cp = cp + e2_w32(buf, cp, 1)
    return cp - p

fn e2_big_tag_reg(buf: string, p: int, reg: int) -> int:
    // shl reg, 1 — REX.W(+B), 0xD1 /4
    cp := p
    cp = cp + emit_rex(buf, cp, 1, 0, 0, reg / 8)
    e2_w8(buf, cp, 209)
    cp = cp + 1
    cp = cp + emit_modrm(buf, cp, 3, 4, reg % 8)
    return cp - p

fn e2_big_untag_reg(buf: string, p: int, reg: int) -> int:
    // sar reg, 1 — REX.W(+B), 0xD1 /7
    cp := p
    cp = cp + emit_rex(buf, cp, 1, 0, 0, reg / 8)
    e2_w8(buf, cp, 209)
    cp = cp + 1
    cp = cp + emit_modrm(buf, cp, 3, 7, reg % 8)
    return cp - p

fn e2_big_neg_reg(buf: string, p: int, reg: int) -> int:
    // neg reg — REX.W(+B), 0xF7 /3
    cp := p
    cp = cp + emit_rex(buf, cp, 1, 0, 0, reg / 8)
    e2_w8(buf, cp, 247)
    cp = cp + 1
    cp = cp + emit_modrm(buf, cp, 3, 3, reg % 8)
    return cp - p

fn e2_big_imul_rr(buf: string, p: int, dst: int, src: int) -> int:
    // imul dst, src — REX.WR/B, 0x0F 0xAF, ModRM(3, dst, src)
    cp := p
    cp = cp + emit_rex(buf, cp, 1, dst / 8, 0, src / 8)
    e2_w8(buf, cp, 15)
    cp = cp + 1
    e2_w8(buf, cp, 175)
    cp = cp + 1
    cp = cp + emit_modrm(buf, cp, 3, dst % 8, src % 8)
    return cp - p

fn e2_big_jcc(buf: string, p: int, cond: int) -> int:
    // jcc rel32 — 0x0F 0x80+cond, placeholder rel32
    cp := p
    e2_w8(buf, cp, 15)
    cp = cp + 1
    e2_w8(buf, cp, 128 + cond)
    cp = cp + 1
    cp = cp + e2_w32(buf, cp, 0)
    return cp - p

fn e2_big_jmp(buf: string, p: int) -> int:
    // jmp rel32 — 0xE9, placeholder rel32
    cp := p
    e2_w8(buf, cp, 233)
    cp = cp + 1
    cp = cp + e2_w32(buf, cp, 0)
    return cp - p

fn e2_big_patch_jcc(buf: string, jump_pos: int, target_pos: int):
    w32(buf, jump_pos + 2, target_pos - (jump_pos + 6))

fn e2_big_patch_jmp(buf: string, jump_pos: int, target_pos: int):
    w32(buf, jump_pos + 1, target_pos - (jump_pos + 5))

fn e2_big_call_name(buf: string, p: int, name_idx: int) -> int:
    // E8 rel32 placeholder; resolved by the existing call-patch table in elf.cr.
    grow_call_patch(g_x86_call_patch_count + 1)
    w64(g_x86_call_patch_pos, g_x86_call_patch_count * 8, p)
    w64(g_x86_call_patch_name, g_x86_call_patch_count * 8, name_idx)
    g_x86_call_patch_count = g_x86_call_patch_count + 1
    e2_w8(buf, p, 232)
    e2_w32(buf, p + 1, 0)
    return 5

fn e2_big_setcc(buf: string, p: int, cond: int) -> int:
    // setcc al — 0x0F 0x90+cond, ModRM(3,0,0)
    cp := p
    e2_w8(buf, cp, 15)
    cp = cp + 1
    e2_w8(buf, cp, 144 + cond)
    cp = cp + 1
    cp = cp + emit_modrm(buf, cp, 3, 0, 0)
    return cp - p

fn e2_big_bool_to_r10(buf: string, p: int) -> int:
    // movzx r10d, al — REX.R + 0x0F 0xB6, ModRM(3,r10,al)
    cp := p
    cp = cp + emit_rex(buf, cp, 0, 10 / 8, 0, 0)
    e2_w8(buf, cp, 15)
    cp = cp + 1
    e2_w8(buf, cp, 182)
    cp = cp + 1
    cp = cp + emit_modrm(buf, cp, 3, 10 % 8, 0)
    return cp - p

fn e2_big_test_rr(buf: string, p: int, a: int, b: int) -> int:
    // test a, b — REX.WR/B, 0x85, ModRM(3,a,b)
    cp := p
    cp = cp + emit_rex(buf, cp, 1, a / 8, 0, b / 8)
    e2_w8(buf, cp, 133)
    cp = cp + 1
    cp = cp + emit_modrm(buf, cp, 3, a % 8, b % 8)
    return cp - p

fn e2_big_test_rax(buf: string, p: int) -> int:
    return e2_big_test_rr(buf, p, 0, 0)

// Convert an int variable to a raw machine word through the checked runtime
// boundary.  The value remains tagged in its slot; only the temporary register
// is raw.  Used by index, slice, and bounds-check paths.
fn e2_big_word_var(buf: string, p: int, reg: int, var_idx: int) -> int:
    cp : ., mut = 0
    cp = cp + e2_load_var(buf, p + cp, 7, var_idx)
    cp = cp + e2_big_call_name(buf, p + cp, str_intern("bi_to_word_checked"))
    cp = cp + e2_mov(buf, p + cp, reg, 0)
    return cp

fn e2_big_push_r11(buf: string, p: int) -> int:
    e2_w8(buf, p, 65)
    e2_w8(buf, p + 1, 83)
    return 2

fn e2_big_pop_r11(buf: string, p: int) -> int:
    e2_w8(buf, p, 65)
    e2_w8(buf, p + 1, 91)
    return 2

fn emit_big_neg(buf: string, pos: int, d: int, s1: int) -> int:
    cp : ., mut = 0
    cp = cp + e2_load_var(buf, pos + cp, 10, s1)
    cp = cp + e2_mov(buf, pos + cp, 8, 10)
    cp = cp + e2_big_test_tag(buf, pos + cp, 10)
    j1 := pos + cp
    cp = cp + e2_big_jcc(buf, pos + cp, 5)  // jne slow
    cp = cp + e2_big_untag_reg(buf, pos + cp, 10)
    cp = cp + e2_big_neg_reg(buf, pos + cp, 10)
    cp = cp + e2_big_mov_imm64(buf, pos + cp, 11, BI_TAG_IMM_MAX)
    cp = cp + e2_alu(buf, pos + cp, 57)
    r1 := pos + cp
    cp = cp + e2_big_jcc(buf, pos + cp, 15)  // jg slow
    cp = cp + e2_big_mov_imm64(buf, pos + cp, 11, BI_TAG_IMM_MIN)
    cp = cp + e2_alu(buf, pos + cp, 57)
    r2 := pos + cp
    cp = cp + e2_big_jcc(buf, pos + cp, 12)  // jl slow
    cp = cp + e2_big_tag_reg(buf, pos + cp, 10)
    cp = cp + e2_st_var(buf, pos + cp, 10, d)
    fast_jmp := pos + cp
    cp = cp + e2_big_jmp(buf, pos + cp)
    slow_pos := pos + cp
    cp = cp + e2_mov(buf, pos + cp, 7, 8)
    cp = cp + e2_big_call_name(buf, pos + cp, str_intern("bi_neg"))
    cp = cp + e2_st_var(buf, pos + cp, 0, d)
    done_pos := pos + cp
    e2_big_patch_jcc(buf, j1, slow_pos)
    e2_big_patch_jcc(buf, r1, slow_pos)
    e2_big_patch_jcc(buf, r2, slow_pos)
    e2_big_patch_jmp(buf, fast_jmp, done_pos)
    return cp


// Emit one tagged integer binary operation.  Returns the number of bytes, or 0
// when the opcode is not an integer arithmetic/comparison op and the caller must
// keep the legacy path.
//
// Fast path: both operands have low bit 0.  They are untagged with sar, the
// machine op runs, and the result is re-tagged when it fits the immediate range.
// Anything else (odd tag, arithmetic overflow, out-of-range result, division by
// zero) calls the raw BigInt runtime with the original tagged operands.
fn emit_big_binary(buf: string, pos: int, d: int, s1: int, s2: int, op: int) -> int:
    is_arith := op == OP_ADD || op == OP_SUB || op == OP_MUL || op == OP_DIV || op == OP_MOD
    is_cmp := op >= OP_EQ && op <= OP_GE
    if !is_arith && !is_cmp:
        return 0

    cp : ., mut = 0
    cp = cp + e2_load_var(buf, pos + cp, 10, s1)
    cp = cp + e2_load_var(buf, pos + cp, 11, s2)
    // Keep the original tagged operands for every cold call.  r8/r9 are
    // caller-saved and the register allocator only assigns rbx/r12-r15.
    cp = cp + e2_mov(buf, pos + cp, 8, 10)
    cp = cp + e2_mov(buf, pos + cp, 9, 11)

    j1 : ., mut = -1
    j2 : ., mut = -1
    cp = cp + e2_big_test_tag(buf, pos + cp, 10)
    j1 = pos + cp
    cp = cp + e2_big_jcc(buf, pos + cp, 5)  // jne slow
    if s1 != s2:
        cp = cp + e2_big_test_tag(buf, pos + cp, 11)
        j2 = pos + cp
        cp = cp + e2_big_jcc(buf, pos + cp, 5)
    cp = cp + e2_big_untag_reg(buf, pos + cp, 10)
    cp = cp + e2_big_untag_reg(buf, pos + cp, 11)

    slow_name : ., mut = ""
    mul_j : ., mut = -1
    div_j : ., mut = -1
    if op == OP_ADD:
        slow_name = "bi_add"
        cp = cp + e2_alu(buf, pos + cp, 1)
    else if op == OP_SUB:
        slow_name = "bi_sub"
        cp = cp + e2_alu(buf, pos + cp, 41)
    else if op == OP_MUL:
        slow_name = "bi_mul"
        cp = cp + e2_big_imul_rr(buf, pos + cp, 10, 11)
        // imul overflow means the 64-bit raw product is unusable; take the
        // runtime path with the original tagged values.
        mul_j = pos + cp
        cp = cp + e2_big_jcc(buf, pos + cp, 0)  // jo slow
    else if op == OP_DIV || op == OP_MOD:
        slow_name = "bi_div"
        if op == OP_MOD:
            slow_name = "bi_mod"
        // Divisor zero must go through the runtime's unified error path.
        cp = cp + e2_big_test_rr(buf, pos + cp, 11, 11)
        div_j = pos + cp
        cp = cp + e2_big_jcc(buf, pos + cp, 4)  // je slow
        cp = cp + e2_mov(buf, pos + cp, 0, 10)
        cp = cp + emit_rex(buf, pos + cp, 1, 0, 0, 0)
        e2_w8(buf, pos + cp, 153)  // cqo
        cp = cp + 1
        cp = cp + emit_rex(buf, pos + cp, 1, 0, 0, 11 / 8)
        e2_w8(buf, pos + cp, 247)  // idiv r11
        cp = cp + 1
        cp = cp + emit_modrm(buf, pos + cp, 3, 7, 11 % 8)
        if op == OP_DIV:
            cp = cp + e2_mov(buf, pos + cp, 10, 0)
        else:
            cp = cp + e2_mov(buf, pos + cp, 10, 2)
    else:
        // comparison
        slow_name = "bi_cmp"
        cp = cp + e2_alu(buf, pos + cp, 57)  // cmp r10, r11
        cond : ., mut = 4
        if op == OP_NE:
            cond = 5
        else if op == OP_LT:
            cond = 12
        else if op == OP_GT:
            cond = 15
        else if op == OP_LE:
            cond = 14
        else if op == OP_GE:
            cond = 13
        cp = cp + e2_big_setcc(buf, pos + cp, cond)
        cp = cp + e2_big_bool_to_r10(buf, pos + cp)
        cp = cp + e2_st_var(buf, pos + cp, 10, d)
        fast_jmp := pos + cp
        cp = cp + e2_big_jmp(buf, pos + cp)
        slow_pos := pos + cp
        cp = cp + e2_mov(buf, pos + cp, 7, 8)
        cp = cp + e2_mov(buf, pos + cp, 6, 9)
        cp = cp + e2_big_call_name(buf, pos + cp, str_intern(slow_name))
        cp = cp + e2_big_test_rax(buf, pos + cp)
        cp = cp + e2_big_setcc(buf, pos + cp, cond)
        cp = cp + e2_big_bool_to_r10(buf, pos + cp)
        cp = cp + e2_st_var(buf, pos + cp, 10, d)
        done_pos := pos + cp
        e2_big_patch_jcc(buf, j1, slow_pos)
        if j2 >= 0:
            e2_big_patch_jcc(buf, j2, slow_pos)
        e2_big_patch_jmp(buf, fast_jmp, done_pos)
        return cp

    // Arithmetic fast path: reject results outside the immediate range.  For
    // add/sub this is a range check, not a machine overflow: both inputs are
    // already in [-2^62, 2^62-1], and the sum fits signed 64-bit.
    cp = cp + e2_big_mov_imm64(buf, pos + cp, 11, BI_TAG_IMM_MAX)
    cp = cp + e2_alu(buf, pos + cp, 57)  // cmp r10, r11
    range_j1 := pos + cp
    cp = cp + e2_big_jcc(buf, pos + cp, 15)  // jg slow
    cp = cp + e2_big_mov_imm64(buf, pos + cp, 11, BI_TAG_IMM_MIN)
    cp = cp + e2_alu(buf, pos + cp, 57)  // cmp r10, r11
    range_j2 := pos + cp
    cp = cp + e2_big_jcc(buf, pos + cp, 12)  // jl slow
    cp = cp + e2_big_tag_reg(buf, pos + cp, 10)
    cp = cp + e2_st_var(buf, pos + cp, 10, d)
    fast_jmp2 := pos + cp
    cp = cp + e2_big_jmp(buf, pos + cp)
    slow_pos2 := pos + cp
    cp = cp + e2_mov(buf, pos + cp, 7, 8)
    cp = cp + e2_mov(buf, pos + cp, 6, 9)
    cp = cp + e2_big_call_name(buf, pos + cp, str_intern(slow_name))
    cp = cp + e2_mov(buf, pos + cp, 10, 0)
    cp = cp + e2_st_var(buf, pos + cp, 10, d)
    done_pos2 := pos + cp
    e2_big_patch_jcc(buf, j1, slow_pos2)
    if j2 >= 0:
        e2_big_patch_jcc(buf, j2, slow_pos2)
    if mul_j >= 0:
        e2_big_patch_jcc(buf, mul_j, slow_pos2)
    if div_j >= 0:
        e2_big_patch_jcc(buf, div_j, slow_pos2)
    e2_big_patch_jcc(buf, range_j1, slow_pos2)
    e2_big_patch_jcc(buf, range_j2, slow_pos2)
    e2_big_patch_jmp(buf, fast_jmp2, done_pos2)
    return cp

