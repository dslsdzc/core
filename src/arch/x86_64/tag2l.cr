// === tag2l.cr ===
// Tagged int slots and the 2L (two-limb) encoder for x86-64.
//
// A fast int var stores a 64-bit value or a pointer to a 2-limb heap object.
// Potential multiword vars get one tag byte in the frame. The slot offset from
// g2_slot is unchanged; the tag area is below the slot area, and tag byte k is
// at -(vc*8 + 1 + k) relative to rbp. Functions without tagged vars have no tag
// area, so their frame layout is unchanged.
//
// mw_setup_tags scans the function and marks:
//   A. dest of IR_BINARY(OP_ADD/OP_SUB), the only >64-bit producers;
//   B. IR_LOAD d <- s1 when s1 is tagged (as-conversion copies);
//   B'. IR_STORE rho(s1) := rho(s2) when s2 is tagged (assignment copies).
// The mark set is a fixed point because tags can travel around loop backedges.
// Marking is monotone, so it converges in at most vc + 1 passes.
//
// Tag reads and writes go through g2_tag_off, defined in frame.cr. The tag table
// is owned by this file. frame.cr calls e2_mw_slow_block and e2_mw_opnd_block
// from the function epilogue; this file calls g2_tag_off and pf_frame_size.
//
// Boundaries: 2-limb values do not cross function boundaries, are not stored to
// globals, heap, or arrays, and do not enter MUL, DIV, SHL, unary neg, or other
// unimplemented sites. Tests avoid those shapes.
//
// Register allocation is not excluded for tagged vars. A slot or register holds
// either a fast 64-bit value or a 2-limb heap pointer; the 128-bit payload is on
// the heap and the tag is a frame byte. All value reads and writes use g2_slot,
// and all tag reads and writes use g2_tag_off.

// Scan function fi and build tag byte offsets for its var domain [vs, vs+vc).
// This is pure IR work: the input is the final IR after .ccr loading, with no
// format or cross-process state. The tag model and the recognition rules must
// cover the same rows. The four tag writers are:
//   1. add/sub fast path clears the tag after storing the value;
//   2. IR_STORE and IR_LOAD copy or clear the tag;
//   3. prologue parameter saves clear it;
//   4. the 2L slow path writes tag = 1.
// Rules A, B, and B' mark exactly the rows these four sites can write. No frame
// entry clear is needed.
fn mw_setup_tags(fi: int, vs: int, vc: int):
    grow_mw_tag_off(vc)
    z : ., mut = 0
    loop:
        if z >= vc:
            break
        w64(g_x86_mw_tag_off, z * 8, -1)
        z = z + 1
    g_x86_mw_tag_count = 0
    if vc <= 0:
        return
    ic := r64(g_ir_func_instr_count, fi * 8)
    ist := r64(g_ir_func_instr_start, fi * 8)
    ve := vs + vc
    // First pass: fixed-point scan of rules A, B, and B'. The destination and
    // targets must be TI_INT vars in the function domain:
    //   A. IR_BINARY(ADD/SUB) marks dest;
    //   B. IR_LOAD d <- s1 marks d when s1 is marked;
    //   B'. IR_STORE rho(s1) := rho(s2) marks s1 when s2 is marked.
    chg : ., mut = 1
    ii : ., mut = 0
    loop:
        if chg == 0:
            break
        chg = 0
        ii = 0
        loop:
            if ii >= ic:
                break
            ino := ist + ii
            op := iri_op(ino)
            if op == IR_BINARY:
                d := iri_dest(ino)
                if d >= vs && d < ve && irv_type(d) == TI_INT:
                    s3 := iri_s3(ino)
                    if (s3 == OP_ADD || s3 == OP_SUB) && r64(g_x86_mw_tag_off, (d - vs) * 8) == -1:
                        w64(g_x86_mw_tag_off, (d - vs) * 8, 0)  // 0 = 已标记（占位）
                        chg = 1
            else if op == IR_LOAD:
                d := iri_dest(ino)
                if d >= vs && d < ve && irv_type(d) == TI_INT:
                    s1 := iri_s1(ino)
                    if s1 >= vs && s1 < ve && irv_type(s1) == TI_INT && r64(g_x86_mw_tag_off, (s1 - vs) * 8) != -1 && r64(g_x86_mw_tag_off, (d - vs) * 8) == -1:
                        w64(g_x86_mw_tag_off, (d - vs) * 8, 0)
                        chg = 1
            else if op == IR_STORE:
                s1 := iri_s1(ino)
                if s1 >= vs && s1 < ve && irv_type(s1) == TI_INT:
                    s2 := iri_s2(ino)
                    if s2 >= vs && s2 < ve && irv_type(s2) == TI_INT && r64(g_x86_mw_tag_off, (s2 - vs) * 8) != -1 && r64(g_x86_mw_tag_off, (s1 - vs) * 8) == -1:
                        w64(g_x86_mw_tag_off, (s1 - vs) * 8, 0)
                        chg = 1
            ii = ii + 1
    // Second pass: allocate tag bytes in ascending var order. The k-th tagged
    // var is at rbp - (vc*8 + k).
    cnt : ., mut = 0
    k : ., mut = 0
    loop:
        if k >= vc:
            break
        if r64(g_x86_mw_tag_off, k * 8) != -1:
            cnt = cnt + 1
            w64(g_x86_mw_tag_off, k * 8, -(vc * 8 + cnt))
        k = k + 1
    g_x86_mw_tag_count = cnt

// Overflow check emission for the fast path.
// Emit jo for IR_BINARY add/sub when the dest is a tagged var in the current
// function. g2_tag_off returns -1 for globals, other functions, dest=-1, and
// copy rows, so untagged int arithmetic and dex (SSE branch) emit no bytes.
// This function is also the table-path exclusion gate: comparisons OP_EQ..OP_GE
// with any tagged operand need the 2L check, which the HIT table path does not
// model, so the whole instruction falls back to emit_instr. Add/sub tagged
// operands are covered by the tagged dest (rule A guarantees that a tagged
// operand implies a tagged dest).
fn mw_int_arith_jo_needed(instr_idx: int) -> int:
    if iri_op(instr_idx) != IR_BINARY:
        return 0
    s3 := iri_s3(instr_idx)
    if s3 >= OP_EQ && s3 <= OP_GE:
        s1 := iri_s1(instr_idx)
        if g2_tag_off(s1) != -1:
            return 1
        s2 := iri_s2(instr_idx)
        if s1 != s2 && g2_tag_off(s2) != -1:
            return 1
        return 0
    if s3 != OP_ADD && s3 != OP_SUB:
        return 0
    if g2_tag_off(iri_dest(instr_idx)) == -1:
        return 0
    return 1

// Emit jo rel32 (0F 80, 6 bytes) to the slow-path block. The block is placed at
// the function tail after epilogue, so its position is not known yet. Record
// pos, dest, and is_sub in g_x86_mw_jo_*; pf_epilogue emits the block and patches
// the rel32. elf.cr writes the resume offset after this instruction.
// rel32 is required because the block is at the function tail and the body can
// exceed the rel8 range.
fn e2_mw_jo(b: string, p: int, d: int, is_sub: int) -> int:
    grow_mw_jo_patch(g_x86_mw_jo_count + 1)
    w64(g_x86_mw_jo_pos, g_x86_mw_jo_count * 8, p)
    w64(g_x86_mw_jo_dest, g_x86_mw_jo_count * 8, d)
    w64(g_x86_mw_jo_is_sub, g_x86_mw_jo_count * 8, is_sub)
    g_x86_mw_jo_count = g_x86_mw_jo_count + 1
    w8(b, p, 15)
    w8(b, p + 1, 128)  // 0F 80 = jo rel32
    e2_w32(b, p + 2, 0)              // 占位，frame.cr pf_epilogue 块位置已知后回填
    return 6

// Slow path block: one per site, appended after the function epilogue.
// Site state on entry:
//   - r10 = wrapped 64-bit add/sub result (low limb);
//   - OF = 1; CF still holds the e2_alu result;
//   - rsp is 16-byte aligned (the site is inside IR_BINARY emission, with no call
//     stack arguments in flight).
// Only caller-saved registers are touched (rax, rcx, rdx, rdi, r10, r11), and
// push/pop keep the block balanced. Callee-saved registers used by O1/O2
// allocation (rbx, r12-r15) pass through unchanged.
//
// 128-bit correction:
//   add: high limb = CF ? -1 : 0;
//   sub: high limb = CF ? 0 : -1.
// The wrapped low limb stays in r10. The implementation forms -CF with
// sbb r11,r11 and adds not r11 for sub.
// Boundary check: a = b = -2^63 for add gives L = 0, CF = 1, so [lo=0, hi=-1].
fn e2_mw_slow_block(b: string, p: int, d: int, is_sub: int, resume: int) -> int:
    cp : ., mut = 0
    // 1. 高 limb -> r11（add：sbb r11,r11 = -CF；sub：+not -> CF?0:-1）。
    //    须为块内首操作，CF 其后随时可能被写。
    w8(b, p + cp, 77)
    w8(b, p + cp + 1, 25)
    w8(b, p + cp + 2, 219)
    cp = cp + 3  // sbb r11, r11 (4D 19 DB)
    if is_sub != 0:
        w8(b, p + cp, 73)
        w8(b, p + cp + 1, 247)
        w8(b, p + cp + 2, 211)
        cp = cp + 3  // not r11 (49 F7 D3, REX.WB: rm=r11 需 B 位)
    // 2. 保存 lo/hi（alloc 调用会摧毁 caller-saved r10/r11）：两 push 后
    //    rsp == 0 (mod 16)，满足 SysV call 对齐（进入块时 rsp == 0）。
    w8(b, p + cp, 65)
    w8(b, p + cp + 1, 82)
    cp = cp + 2  // push r10 (41 52)
    w8(b, p + cp, 65)
    w8(b, p + cp + 1, 83)
    cp = cp + 2  // push r11 (41 53)
    // 3. alloc(16)，16B 2-limb 对象；与 IR_ALLOC_* 同款补丁表注册
    //    （g_x86_alloc_patch_count 逐函数不重置，函数尾块与函数体一起回填）。
    //    mov edi, 16（BF imm32，16 为合法 imm32）
    w8(b, p + cp, 191)
    e2_w32(b, p + cp + 1, 16)
    cp = cp + 5
    grow_alloc_patch(g_x86_alloc_patch_count + 1)
    w64(g_x86_alloc_patch_pos, g_x86_alloc_patch_count * 8, p + cp)
    g_x86_alloc_patch_count = g_x86_alloc_patch_count + 1
    w8(b, p + cp, 232)
    e2_w32(b, p + cp + 1, 0)
    cp = cp + 5  // call alloc（占位回填）
    // 4. 恢复 lo/hi
    w8(b, p + cp, 65)
    w8(b, p + cp + 1, 91)
    cp = cp + 2  // pop r11 (41 5B)
    w8(b, p + cp, 65)
    w8(b, p + cp + 1, 90)
    cp = cp + 2  // pop r10 (41 5A)
    // 5. 写 2-limb 对象（rax = alloc 返回的数据指针）：[+0] = lo（环绕值）、
    //    [+8] = hi（符号扩展修正）。注意 REX：rm=rax 无需 B 位，仅 R（源
    //    r10/r11）-> 4C（对照 elf.cr alloc 内 mov [rax], r9 = 4C 89 08）。
    w8(b, p + cp, 76)
    w8(b, p + cp + 1, 137)
    w8(b, p + cp + 2, 16)
    cp = cp + 3  // mov [rax], r10 (4C 89 10)
    w8(b, p + cp, 76)
    w8(b, p + cp + 1, 137)
    w8(b, p + cp + 2, 88)
    w8(b, p + cp + 3, 8)
    cp = cp + 4  // mov [rax+8], r11 (4C 89 58 08)
    // 6. 值槽存指针（跳过快路径 e2_st，本块自回存 dest；g2_slot 含
    //    O1/O2 reg 形态：E2_REG_SLOT_BASE 编码 -> e2_mov reg, rax）
    cp = cp + e2_st(b, p + cp, 0, g2_slot(d))
    // 7. tag 字节置位（g2_tag_off(d) != -1 由 jo 发射条件保证）：槽内现为
    //    2-limb 指针 当且仅当 tag = 1（tag 不变量慢路径侧）。
    tago := g2_tag_off(d)
    if tago >= -128 && tago <= 127:
        w8(b, p + cp, 198)
        w8(b, p + cp + 1, 69)
        w8(b, p + cp + 2, tago)
        w8(b, p + cp + 3, 1)
        cp = cp + 4
    else:
        w8(b, p + cp, 198)
        w8(b, p + cp + 1, 133)
        e2_w32(b, p + cp + 2, tago)
        w8(b, p + cp + 6, 1)
        cp = cp + 7
    // 8. 跳回快路径 store 之后（resume = 该站点指令尾，elf.cr 填）
    w8(b, p + cp, 233)  // E9 jmp rel32
    e2_w32(b, p + cp + 1, resume - (p + cp + 5))
    return cp + 5

// Tag hygiene: write tags at definition points, with no frame-entry clear.
// Every definition of a tagged row belongs to one of four sets:
//   1. add/sub fast path stores a value and clears tag to 0;
//   2. IR_STORE and IR_LOAD copy the source tag, or clear it when the source is
//      untagged;
//   3. prologue parameter saves clear the tag;
//   4. 2-limb definitions write a pointer and set tag = 1.
// User vars are defined only by IR_STORE. Constants and arithmetic go through a
// temporary row first. IR_CONST, IR_UNARY, IR_CALL, and similar dests are
// single-use temporaries outside the tag closure, so the four sets are complete.
//
// Consumers:
//   A. IR_RETURN dereferences a 2L pointer and returns the low limb in rax.
//   B. Integer comparisons OP_EQ..OP_GE with a tagged operand use a 128-bit
//      comparison: signed high limb, then unsigned low limb.
//   C. Add/sub chains with a tagged operand use 128-bit arithmetic. If the result
//      fits in 64 bits, it is stored as a fast value with tag 0; otherwise a new
//      2-limb object is allocated and tag = 1. The result bound is below 2^66, so
//      the 128-bit domain is not exceeded.
//   D. Not implemented: 2L operands in MUL, DIV, SHL, unary neg, or shifts;
//      writes to globals, heap, or arrays; function boundaries. Tests avoid these
//      shapes.
// ══════════════════════════════════════════════════════════════

// 字节级小助手（rbp 相对偏移，disp8/disp32 自动）：
// test byte [rbp+off], 0xFF，F6 /0（ZF 当且仅当字节 == 0；只写标志）
fn e2_mw_t8(b: string, p: int, off: int) -> int:
    if off >= -128 && off <= 127:
        w8(b, p, 246)
        w8(b, p+1, 69)
        w8(b, p+2, off)
        w8(b, p+3, 255)
        return 4
    w8(b, p, 246)
    w8(b, p+1, 133)
    e2_w32(b, p+2, off)
    w8(b, p+6, 255)
    return 7
// mov byte [rbp+off], imm，C6 /0
fn e2_mw_b8(b: string, p: int, off: int, imm: int) -> int:
    if off >= -128 && off <= 127:
        w8(b, p, 198)
        w8(b, p+1, 69)
        w8(b, p+2, off)
        w8(b, p+3, imm)
        return 4
    w8(b, p, 198)
    w8(b, p+1, 133)
    e2_w32(b, p+2, off)
    w8(b, p+6, imm)
    return 7
// mov al, [rbp+off]，8A /0（rax 低字节 scratch，发射点 rax 无 live）
fn e2_mw_ld8(b: string, p: int, off: int) -> int:
    if off >= -128 && off <= 127:
        w8(b, p, 138)
        w8(b, p+1, 69)
        w8(b, p+2, off)
        return 3
    w8(b, p, 138)
    w8(b, p+1, 133)
    e2_w32(b, p+2, off)
    return 6
// mov [rbp+off], al，88 /0
fn e2_mw_st8(b: string, p: int, off: int) -> int:
    if off >= -128 && off <= 127:
        w8(b, p, 136)
        w8(b, p+1, 69)
        w8(b, p+2, off)
        return 3
    w8(b, p, 136)
    w8(b, p+1, 133)
    e2_w32(b, p+2, off)
    return 6

// 定值点 tag 清 0：变量 v 的槽刚被 64 位快值定值（v tagged 时发 mov byte 0）。
fn e2_mw_tag_clr(b: string, p: int, v: int) -> int:
    tg := g2_tag_off(v)
    if tg == -1:
        return 0
    return e2_mw_b8(b, p, tg, 0)

// 拷贝定值 tag 传播：dst 的槽 ← src 的值（拷贝后 dst 的 tag = src 的 tag；
// src 无 tag 字节（恒快）-> dst 清 0）。dst untagged -> 零字节。
fn e2_mw_tag_cpy(b: string, p: int, dst: int, src: int) -> int:
    dtg := g2_tag_off(dst)
    if dtg == -1:
        return 0
    stg := g2_tag_off(src)
    if stg == -1:
        return e2_mw_b8(b, p, dtg, 0)
    c : ., mut = e2_mw_ld8(b, p, stg)
    c = c + e2_mw_st8(b, p + c, dtg)
    return c

// ── 消费者站点记录（oc = operand-check）：位置后知（函数尾块），jo 同款 ──
fn mw_oc_new(s1: int, s2: int, d: int, op: int) -> int:
    grow_mw_oc_patch(g_x86_mw_oc_count + 1)
    w64(g_x86_mw_oc_pos1, g_x86_mw_oc_count * 8, -1)
    w64(g_x86_mw_oc_pos2, g_x86_mw_oc_count * 8, -1)
    w64(g_x86_mw_oc_s1, g_x86_mw_oc_count * 8, s1)
    w64(g_x86_mw_oc_s2, g_x86_mw_oc_count * 8, s2)
    w64(g_x86_mw_oc_dest, g_x86_mw_oc_count * 8, d)
    w64(g_x86_mw_oc_op, g_x86_mw_oc_count * 8, op)
    g_x86_mw_oc_count = g_x86_mw_oc_count + 1
    return g_x86_mw_oc_count - 1

// 站点检查：test tag(v), 0xFF；jne rel32（0F 85）-> 该站点函数尾 2L 块。
// rel32 恒选：块附函数尾，函数体 >127B 时 rel8 不可达（jo 同理由）。chk =
// 0/1 -> pos1/pos2（站点至多 2 个检查，s1、s2 各行一个，s1==s2 只发 1 个）。
// 记录位置 = jne 起始（p+c，test 前缀 4/7B 后；rel32 字段在 jne 起 +2，
// 若误记 test 起，回填会覆写 test 的 disp/imm 字节）。
fn e2_mw_oc_check(b: string, p: int, oc: int, chk: int, v: int) -> int:
    c : ., mut = e2_mw_t8(b, p, g2_tag_off(v))
    if chk == 0:
        w64(g_x86_mw_oc_pos1, oc * 8, p + c)
    else:
        w64(g_x86_mw_oc_pos2, oc * 8, p + c)
    w8(b, p + c, 15)
    w8(b, p + c + 1, 133)
    e2_w32(b, p + c + 2, 0)
    return c + 6

// ── 2L 操作数装载（解 2-limb 对象到寄存器对）──
// regs: A = (r8=lo, r9=hi)，B = (r10=lo, r11=hi)；rax = 指针 scratch；
// 快值 -> hi = sar 63 符号扩展（两补 128 语义）。快值载入 r8/r10；2L = 槽值
// （指针）入 rax 后解 [rax+0]/[rax+8]（对象布局 [+0]=lo [+8]=hi）。
//   mov r8, [rax]     4C 8B 00      mov r9, [rax+8]   4C 8B 48 08
//   mov r10, [rax]    4C 8B 10      mov r11, [rax+8]  4C 8B 58 08
fn e2_mw_ld2(b: string, p: int, lo_r: int, hi_r: int) -> int:
    w8(b, p, 76)
    w8(b, p+1, 139)
    w8(b, p+2, (lo_r % 8) * 8)       // mov r{lo}, [rax]
    w8(b, p+3, 76)
    w8(b, p+4, 139)
    w8(b, p+5, 64 + (hi_r % 8) * 8)
    w8(b, p+6, 8)                  // mov r{hi}, [rax+8]
    return 7
// mov r{hi}, r{lo}; sar r{hi}, 63，快值 64->128 符号扩展（hi = sext）
fn e2_mw_sext(b: string, p: int, lo_r: int, hi_r: int) -> int:
    c : ., mut = e2_mov(b, p, hi_r, lo_r)
    w8(b, p+c, 73)
    w8(b, p+c+1, 193)   // REX.WB + C1 /7
    w8(b, p+c+2, 248 + (hi_r % 8))      // modrm 11 111 rm（/7 = SAR）
    w8(b, p+c+3, 63)
    return c + 4

// 2L operand block: one per consumer site, after the jo blocks at the function
// tail.
// Entry: at least one operand is 2L, reached by the fast-path tag check. All
// operands are reloaded; r10/r11 values from the fast path are discarded. rsp is
// 16-byte aligned, and the only call (alloc) is balanced by push/pop. Only
// caller-saved registers are touched.
// Static specialization: untagged operands are known fast, so their tag test and
// 2L load are omitted. For two tagged operands, test s1: fast A means B is 2L;
// 2L A then tests s2. If s1 == s2, both tests are the same byte and the entry
// condition makes the branch self-consistent.
// Internal jumps are rel8. Cross-block jumps (tag check jne to the block, block
// tail jmp to resume) are rel32.
fn e2_mw_opnd_block(b: string, p: int, s1: int, s2: int, d: int, op: int, resume: int) -> int:
    cp : ., mut = 0
    t1 := g2_tag_off(s1)
    t2 : ., mut = t1
    if s1 != s2:
        t2 = g2_tag_off(s2)
    is_cmp : ., mut = 0
    if op >= OP_EQ && op <= OP_GE:
        is_cmp = 1
    is_sub : ., mut = 0
    if is_cmp == 0 && op == OP_SUB:
        is_sub = 1

    if t1 != -1 && t2 != -1:
        // ── 双 tagged 分派：测 t1，0 -> A 快 + B 必 2L；1 -> A 2L 再测 t2 ──
        cp = cp + e2_mw_t8(b, p+cp, t1)
        j_a2l : ., mut = cp
        w8(b, p+cp, 117)
        w8(b, p+cp+1, 0)
        cp = cp + 2  // jne L_a2l
        // A 快
        cp = cp + e2_load_var(b, p+cp, 8, s1)
        cp = cp + e2_mw_sext(b, p+cp, 8, 9)
        // B 必 2L
        cp = cp + e2_load_var(b, p+cp, 0, s2)
        cp = cp + e2_mw_ld2(b, p+cp, 10, 11)
        j_op1 : ., mut = cp
        w8(b, p+cp, 235)
        w8(b, p+cp+1, 0)
        cp = cp + 2  // jmp L_op
        // L_a2l：A 2L
        w8(b, p + j_a2l + 1, cp - (j_a2l + 2))
        cp = cp + e2_load_var(b, p+cp, 0, s1)
        cp = cp + e2_mw_ld2(b, p+cp, 8, 9)
        cp = cp + e2_mw_t8(b, p+cp, t2)
        j_both : ., mut = cp
        w8(b, p+cp, 117)
        w8(b, p+cp+1, 0)
        cp = cp + 2  // jne L_both
        // B 快
        cp = cp + e2_load_var(b, p+cp, 10, s2)
        cp = cp + e2_mw_sext(b, p+cp, 10, 11)
        j_op2 : ., mut = cp
        w8(b, p+cp, 235)
        w8(b, p+cp+1, 0)
        cp = cp + 2  // jmp L_op
        // L_both：B 2L
        w8(b, p + j_both + 1, cp - (j_both + 2))
        cp = cp + e2_load_var(b, p+cp, 0, s2)
        cp = cp + e2_mw_ld2(b, p+cp, 10, 11)
        // L_op = 当前 cp，回填两个 jmp
        w8(b, p + j_op1 + 1, cp - (j_op1 + 2))
        w8(b, p + j_op2 + 1, cp - (j_op2 + 2))
    else if t1 != -1:
        // 仅 s1 tagged：入口即 s1 2L，A 2L，B 恒快
        cp = cp + e2_load_var(b, p+cp, 0, s1)
        cp = cp + e2_mw_ld2(b, p+cp, 8, 9)
        cp = cp + e2_load_var(b, p+cp, 10, s2)
        cp = cp + e2_mw_sext(b, p+cp, 10, 11)
    else:
        // 仅 s2 tagged：入口即 s2 2L，A 恒快，B 2L
        cp = cp + e2_load_var(b, p+cp, 8, s1)
        cp = cp + e2_mw_sext(b, p+cp, 8, 9)
        cp = cp + e2_load_var(b, p+cp, 0, s2)
        cp = cp + e2_mw_ld2(b, p+cp, 10, 11)

    // ── L_op：128 位运算（A=(r8,r9) B=(r10,r11)）──
    if is_cmp == 0:
        // 算术：结果 (r10 = lo, r11 = hi)
        if is_sub == 0:
            w8(b, p+cp, 77)
            w8(b, p+cp+1, 1)
            w8(b, p+cp+2, 194)
            cp = cp + 3   // add r10, r8（lo + CF）
            w8(b, p+cp, 77)
            w8(b, p+cp+1, 17)
            w8(b, p+cp+2, 203)
            cp = cp + 3  // adc r11, r9（高位进位处理）
        else:
            w8(b, p+cp, 77)
            w8(b, p+cp+1, 41)
            w8(b, p+cp+2, 208)
            cp = cp + 3  // sub r8, r10（lo，CF=借位）
            w8(b, p+cp, 76)
            w8(b, p+cp+1, 137)
            w8(b, p+cp+2, 216)
            cp = cp + 3  // mov rax, r11（暂存 bh）
            w8(b, p+cp, 77)
            w8(b, p+cp+1, 137)
            w8(b, p+cp+2, 203)
            cp = cp + 3  // mov r11, r9（ah）
            w8(b, p+cp, 73)
            w8(b, p+cp+1, 25)
            w8(b, p+cp+2, 195)
            cp = cp + 3   // sbb r11, rax（ah-bh-CF）
            w8(b, p+cp, 77)
            w8(b, p+cp+1, 137)
            w8(b, p+cp+2, 194)
            cp = cp + 3  // mov r10, r8（lo）
        // 公共落值：fits-64 当且仅当 hi == signmask(lo) -> 降级快值；否则 2L 对象
        // 结果界：|加数| <= 2^64-1 + 2^65，所以 |和| < 2^66，远小于 2^127。
        // 128 位域内恒可表示，不需要错误路径。
        cp = cp + e2_mov(b, p+cp, 2, 10)                                        // mov rdx, r10
        w8(b, p+cp, 72)
        w8(b, p+cp+1, 193)
        w8(b, p+cp+2, 250)
        w8(b, p+cp+3, 63)
        cp = cp + 4  // sar rdx, 63（signmask）
        w8(b, p+cp, 73)
        w8(b, p+cp+1, 57)
        w8(b, p+cp+2, 211)
        cp = cp + 3     // cmp r11, rdx (0x49 39 D3: REX.W+B, reg=rdx). 0x4D would
                        // encode r10 and compare r11 with r10, causing a false fit.
        j_fit : ., mut = cp
        w8(b, p+cp, 116)
        w8(b, p+cp+1, 0)
        cp = cp + 2    // je L_fit
        // 2L 存储：alloc(16) + 2-limb 写 + 槽存指针 + tag=1（同慢路径块）
        w8(b, p+cp, 65)
        w8(b, p+cp+1, 82)
        cp = cp + 2                         // push r10
        w8(b, p+cp, 65)
        w8(b, p+cp+1, 83)
        cp = cp + 2                         // push r11
        w8(b, p+cp, 191)
        e2_w32(b, p+cp+1, 16)
        cp = cp + 5                    // mov edi, 16
        grow_alloc_patch(g_x86_alloc_patch_count + 1)
        w64(g_x86_alloc_patch_pos, g_x86_alloc_patch_count * 8, p + cp)
        g_x86_alloc_patch_count = g_x86_alloc_patch_count + 1
        w8(b, p+cp, 232)
        e2_w32(b, p+cp+1, 0)
        cp = cp + 5                     // call alloc
        w8(b, p+cp, 65)
        w8(b, p+cp+1, 91)
        cp = cp + 2                         // pop r11
        w8(b, p+cp, 65)
        w8(b, p+cp+1, 90)
        cp = cp + 2                         // pop r10
        w8(b, p+cp, 76)
        w8(b, p+cp+1, 137)
        w8(b, p+cp+2, 16)
        cp = cp + 3     // mov [rax], r10
        w8(b, p+cp, 76)
        w8(b, p+cp+1, 137)
        w8(b, p+cp+2, 88)
        w8(b, p+cp+3, 8)
        cp = cp + 4  // mov [rax+8], r11
        cp = cp + e2_st(b, p+cp, 0, g2_slot(d))                                // 值槽存指针
        cp = cp + e2_mw_b8(b, p+cp, g2_tag_off(d), 1)                          // tag = 1
        w8(b, p+cp, 233)
        e2_w32(b, p+cp+1, resume - (p+cp+5))
        cp = cp + 5    // jmp rel32 -> resume
        l_fit := cp
        w8(b, p + j_fit + 1, l_fit - (j_fit + 2))                              // 回填 je -> L_fit
        cp = cp + e2_st(b, p+cp, 10, g2_slot(d))                               // 降级：快值落槽
        cp = cp + e2_mw_tag_clr(b, p+cp, d)                                    // tag = 0
        w8(b, p+cp, 233)
        e2_w32(b, p+cp+1, resume - (p+cp+5))
        cp = cp + 5    // jmp rel32 -> resume
        return cp

    // ── 比较：结果 0/1（128 位语义，高 limb 带符号、同则低 limb 无符号）──
    if op == OP_EQ || op == OP_NE:
        w8(b, p+cp, 77)
        w8(b, p+cp+1, 49)
        w8(b, p+cp+2, 208)
        cp = cp + 3     // xor r8, r10（al^bl）
        w8(b, p+cp, 77)
        w8(b, p+cp+1, 49)
        w8(b, p+cp+2, 217)
        cp = cp + 3    // xor r9, r11（ah^bh）
        w8(b, p+cp, 77)
        w8(b, p+cp+1, 9)
        w8(b, p+cp+2, 193)
        cp = cp + 3     // or r9, r8（ZF 当且仅当 全等）
        if op == OP_EQ:
            w8(b, p+cp, 15)
            w8(b, p+cp+1, 148)
            w8(b, p+cp+2, 192)
            cp = cp + 3
        // sete al
        else:
            w8(b, p+cp, 15)
            w8(b, p+cp+1, 149)
            w8(b, p+cp+2, 192)
            cp = cp + 3
        // setne al
    else:
        // LT/GT/LE/GE：eax 缺省 0（假）；决定性 jcc -> L_t（真）/L_d（假，
        // 前向）；hi 同 -> lo 无符号再判。布局：
        //   xor eax; cmphi; j_ht L_t; j_hf L_d; cmplo; j_lf L_d;
        //   L_t: mov eax,1;  L_d: 落值（j_ht 落 L_t、其余落 L_d，全前向）
        w8(b, p+cp, 49)
        w8(b, p+cp+1, 192)
        cp = cp + 2                       // xor eax, eax
        w8(b, p+cp, 77)
        w8(b, p+cp+1, 57)
        w8(b, p+cp+2, 217)
        cp = cp + 3    // cmp r9, r11（hi 符号）
        hi_t : ., mut = 124
        hi_f : ., mut = 127   // 缺省 LT/LE：jl -> 真、jg -> 假
        if op == OP_GT || op == OP_GE:
            hi_t = 127
            hi_f = 124
        // GT/GE：jg -> 真、jl -> 假
        j_ht : ., mut = cp
        w8(b, p+cp, hi_t)
        w8(b, p+cp+1, 0)
        cp = cp + 2
        j_hf : ., mut = cp
        w8(b, p+cp, hi_f)
        w8(b, p+cp+1, 0)
        cp = cp + 2
        w8(b, p+cp, 77)
        w8(b, p+cp+1, 57)
        w8(b, p+cp+2, 208)
        cp = cp + 3    // cmp r8, r10（lo 无符号）
        lo_f : ., mut = 115   // 缺省 LT：jae（lo >=u -> 假）
        if op == OP_LE:
            lo_f = 119
        else if op == OP_GT:
            lo_f = 118
        else if op == OP_GE:
            lo_f = 114
        // LE: ja / GT: jbe / GE: jb（lo 不满足 -> 假，L_d 前向）
        j_lf : ., mut = cp
        w8(b, p+cp, lo_f)
        w8(b, p+cp+1, 0)
        cp = cp + 2
        // L_t: mov eax, 1（落入 L_d 共享落值，全前向布局）
        l_t := cp
        w8(b, p+cp, 184)
        e2_w32(b, p+cp+1, 1)
        cp = cp + 5
        // L_d = 当前 cp，回填（j_ht -> L_t；j_hf/j_lf -> L_d）
        w8(b, p + j_ht + 1, l_t - (j_ht + 2))
        w8(b, p + j_hf + 1, cp - (j_hf + 2))
        w8(b, p + j_lf + 1, cp - (j_lf + 2))
    // L_d：movzx + 落值（0/1 恒快；dest 若静态 tagged 防御性清 0，结果行
    // 实际恒 untagged，见 mw_setup_tags 规则域）
    w8(b, p+cp, 68)
    w8(b, p+cp+1, 15)
    w8(b, p+cp+2, 182)
    w8(b, p+cp+3, 208)
    cp = cp + 4  // movzx r10d, al
    cp = cp + e2_st(b, p+cp, 10, g2_slot(d))
    cp = cp + e2_mw_tag_clr(b, p+cp, d)
    w8(b, p+cp, 233)
    e2_w32(b, p+cp+1, resume - (p+cp+5))
    cp = cp + 5        // jmp rel32 -> resume
    return cp
