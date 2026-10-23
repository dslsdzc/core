// === frame.cr ===
// x86-64 function frame: size calculation, prologue, epilogue, and the blocks
// appended at the function tail.
//
// Frame size has one source: pf_frame_size(vc). Phase 2 dry-run and the Phase 3
// sub rsp immediate both call it. pf_frame_overhead(ss) is only for the dry-run
// byte count and must agree with the actual emission from pf_prologue and
// pf_epilogue. Encoding sizes come from sizes.cr.
//
// Tag area: tag bytes live below the slot area at -(vc*8 + 1 + k). The formula
// and recognition rules are in tag2l.cr mw_setup_tags. This file reads them
// through g2_tag_off. With zero tags, the frame layout is byte-identical to the
// layout without a tag area.
//
// pf_prologue saves callee-saved registers, sets rbp, reserves the frame, stores
// parameters, clears tags on parameter rows, and loads register-allocated
// parameters. pf_epilogue patches returns, fills the sub rsp immediate, emits the
// epilogue, and appends the jo slow-path blocks and 2L operand blocks.
//
// buf is the byte buffer, pos is the absolute buffer position, and cp is the
// number of bytes already emitted. Returns the new cp.
//
// Depends on instr.cr for encoding primitives, tag2l.cr for the tail blocks,
// sizes.cr for byte sizes, and the shared x86 globals.

// Tag table read. tag2l.cr mw_setup_tags fills the table per function.
fn g2_tag_off(v: int) -> int:
    // var v（当前函数内）的 tag 字节偏移（相对 rbp，恒负）；-1 = 非 tagged。
    // 仅当前函数内有效（表由 mw_setup_tags 按函数填充）。
    if v < 0:
        return -1
    lv := v - g_current_func_var_start
    if lv < 0:
        return -1
    if str_len(g_x86_mw_tag_off) <= lv * 8:
        return -1
    return r64(g_x86_mw_tag_off, lv * 8)

// Total frame bytes, shared by Phase 2 dry-run and Phase 3.
fn pf_frame_size(vc: int) -> int:
    // Frame bytes = vc*8 for var slots + g_x86_mw_tag_count tag bytes, padded
    // to 16-byte alignment. With opt >= 1 (6 pushes) the frame is 8 mod 16;
    // with opt < 1 (1 push) it is 0 mod 16. With zero tags the result is
    // byte-identical to the frame without a tag area.
    sz : ., mut = vc * 8 + g_x86_mw_tag_count
    r := sz % 16
    if g_opt_level >= 1:
        if r != 8:
            pad := 8 - r
            if pad < 0:
                pad = pad + 16
            sz = sz + pad
    else:
        if r != 0:
            sz = sz + (16 - r)
    return sz

// Phase 2 dry-run: frame-related byte count for prologue and epilogue, excluding
// parameter stores and the function body.
// This is the accounting side of the frame. It must agree with the actual
// emission from pf_prologue and pf_epilogue; encoding sizes come from sizes.cr.
// Callee-saved bytes use sz_callee_saved_push and sz_callee_saved_pop.
//
// For opt >= 1 this function counts one extra sz_callee_saved_pop (9 bytes per
// function) beyond the push/pop pair. Phase 2 total_code is temporary: Phase 3
// recomputes total_code from the actual cp before fixing rodata, bss, and
// function offsets. The extra count does not change emitted bytes and is
// conservative.
fn pf_frame_overhead(ss: int) -> int:
    sz : ., mut = sz_push_rbp() + sz_mov_rbp_rsp()
    if g_opt_level >= 1:
        sz = sz + sz_callee_saved_push() + sz_callee_saved_pop()
    // push rbx,r12-r15(9) + pop r15-r12,rbx(9)
    sz = sz + sz_sub_rsp(ss)
    sz = sz + sz_add_rsp(ss) + sz_pop_rbp() + sz_ret()
    if g_opt_level >= 1:
        sz = sz + sz_callee_saved_pop()
    // pop r15,r14,r13,r12,rbx
    return sz

// Phase 3 prologue: frame setup, parameter stores, and register parameter loads.
// Emission order with opt >= 1: save six callee-saved registers, push rbp, mov
// rbp,rsp, reserve the frame with a placeholder sub rsp immediate, store
// parameters (XMM, int, stack), clear tags on parameter rows, then load
// register-allocated parameters. Returns the new cp.
// pf_epilogue fills the sub rsp immediate with the actual frame size.
// g_x86_sub_rsp_pos records the immediate field. ss is passed in explicitly and
// equals pf_frame_size(vc).
fn pf_prologue(vs: int, pc: int, ss: int, buf: string, pos: int) -> int:
    cp : ., mut = pos
    // Save callee-saved registers before rbp setup. They are at [rbp+8..48].
    if g_opt_level >= 1:
        w8(buf, cp, 83)
        cp = cp + 1  // push rbx
        w8(buf, cp, 65)
        w8(buf, cp+1, 84)
        cp = cp + 2  // push r12
        w8(buf, cp, 65)
        w8(buf, cp+1, 85)
        cp = cp + 2  // push r13
        w8(buf, cp, 65)
        w8(buf, cp+1, 86)
        cp = cp + 2  // push r14
        w8(buf, cp, 65)
        w8(buf, cp+1, 87)
        cp = cp + 2  // push r15
    // frame
    w8(buf, cp, 85)
    cp = cp + 1  // push rbp
    w8(buf, cp, 72)
    w8(buf, cp+1, 137)
    w8(buf, cp+2, 229)
    cp = cp + 3  // mov rbp, rsp
    g_x86_sub_rsp_pos = cp
    if ss > 0:
        if ss > 127:
            w8(buf, cp, 72)
            w8(buf, cp+1, 129)
            w8(buf, cp+2, 236)
            e2_w32(buf, cp+3, 0)
            cp = cp + 7
        else:
            w8(buf, cp, 72)
            w8(buf, cp+1, 131)
            w8(buf, cp+2, 236)
            w8(buf, cp+3, 0)
            cp = cp + 4
    // Save register and caller-stack params into this function's slots.
    pi := 0
    loop:
        if pi >= pc:
            break
        po2 := -(vs + pi + 1 - g_current_func_var_start) * 8  // force stack slot, ignore reg alloc
        pty := irv_type(vs + pi)
        if pty == TI_DEX && pi < 6:
            // float 参数在 XMM：movsd [rbp+po2], xmm{frn}（SysV）
            // frn = 第 pi 个参数前的 float 参数数
            frn : ., mut = 0
            fj : ., mut = 0
            loop:
                if fj >= pi:
                    break
                if irv_type(vs + fj) == TI_DEX:
                    frn = frn + 1
                fj = fj + 1
            if frn < 8:
                // movsd [rbp+po2], xmm{frn}, F2 0F 11 /rn（mod=01, rm=5）
                w8(buf, cp, 242)
                w8(buf, cp+1, 15)
                w8(buf, cp+2, 17)
                w8(buf, cp+3, 64 + frn * 8 + 5)
                w8(buf, cp+4, po2)
                cp = cp + 5
            else:
                // 9+ binary64 参数在栈上（边缘场景，位置布局简化处理）
                caller_off := 16 + (pi - 6) * 8
                if g_opt_level >= 1:
                    caller_off = caller_off + 40
                cp = cp + e2_sd_load(buf, cp, caller_off)
                cp = cp + e2_sd_store(buf, cp, po2)
        else if pi >= 6:
            caller_off := 16 + (pi - 6) * 8
            if g_opt_level >= 1:
                caller_off = caller_off + 40
            if pty == TI_DEX:
                cp = cp + e2_sd_load(buf, cp, caller_off)
                cp = cp + e2_sd_store(buf, cp, po2)
            else:
                cp = cp + e2_ld(buf, cp, 10, caller_off)
                cp = cp + e2_st(buf, cp, 10, po2)
        else:
            if pi == 0:
                cp = cp + e2_st(buf, cp, 7, po2)
            if pi == 1:
                w8(buf, cp, 72)
                w8(buf, cp+1, 137)
                w8(buf, cp+2, 117)
                w8(buf, cp+3, po2)
                cp = cp + 4
            if pi == 2:
                w8(buf, cp, 72)
                w8(buf, cp+1, 137)
                w8(buf, cp+2, 85)
                w8(buf, cp+3, po2)
                cp = cp + 4
            if pi == 3:
                w8(buf, cp, 72)
                w8(buf, cp+1, 137)
                w8(buf, cp+2, 77)
                w8(buf, cp+3, po2)
                cp = cp + 4
            if pi == 4:
                w8(buf, cp, 76)
                w8(buf, cp+1, 137)
                w8(buf, cp+2, 69)
                w8(buf, cp+3, po2)
                cp = cp + 4
            if pi == 5:
                w8(buf, cp, 76)
                w8(buf, cp+1, 137)
                w8(buf, cp+2, 77)
                w8(buf, cp+3, po2)
                cp = cp + 4
        // Tag hygiene for tagged parameter rows: clear the tag in the prologue.
        // A parameter can be read before its first definition in the function,
        // and the tag closure can include parameter rows (for example the B'
        // copy p = p + k). Without this clear, a consumer can read the tag from
        // a previous call or garbage. Parameters are saved to a forced stack slot
        // po2, and the tag byte is in the same frame.
        if pty == TI_INT:
            ptg := g2_tag_off(vs + pi)
            if ptg != -1:
                if ptg >= -128 && ptg <= 127:
                    w8(buf, cp, 198)
                    w8(buf, cp+1, 69)
                    w8(buf, cp+2, ptg)
                    w8(buf, cp+3, 0)
                    cp = cp + 4
                else:
                    w8(buf, cp, 198)
                    w8(buf, cp+1, 133)
                    e2_w32(buf, cp+2, ptg)
                    w8(buf, cp+6, 0)
                    cp = cp + 7
        pi = pi + 1

    // Load register-allocated parameters from stack to callee-saved regs
    if g_opt_level >= 1:
        pi2 : ., mut = 0
        loop:
            if pi2 >= pc || pi2 >= 6:
                break
            pri := get_reg_for_var(vs + pi2)
            if pri >= 0:
                pso2 := -(vs + pi2 + 1 - g_current_func_var_start) * 8  // force stack slot
                // mov reg, [rbp+offset], load from stack to allocated register
                cp = cp + emit_rex(buf, cp, 1, pri/8, 0, 0)
                e2_w8(buf, cp, 139)
                cp = cp + 1  // 0x8B MOV r64, r/m64
                cp = cp + emit_modrm(buf, cp, 1, pri%8, 5)  // [rbp+disp8]
                e2_w8(buf, cp, pso2)
                cp = cp + 1
            pi2 = pi2 + 1
    return cp


// Phase 3 epilogue and function-tail blocks.
// Patch returns to the epilogue start, fill the sub rsp immediate with the actual
// frame size, emit the epilogue (add rsp, reverse callee-saved pops, pop rbp,
// ret), then append the jo slow-path blocks and 2L operand blocks. Each site gets
// its own block in the cold tail. Returns the new cp.
// ss is the frame size used by the prologue.
fn pf_epilogue(ss: int, buf: string, pos: int) -> int:
    cp : ., mut = pos
    // patch RETURNs to epilogue
    epi_pos := cp
    print("  rets: ")
    print(int_str(g_x86_ret_patch_count))
    println("")
    rpi := 0
    loop:
        if rpi >= g_x86_ret_patch_count:
            break
        jmp_pos := r64(g_x86_ret_patch_pos, rpi * 8)
        rel := epi_pos - (jmp_pos + 5)
        w32(buf, jmp_pos + 1, rel)
        rpi = rpi + 1
    g_x86_ret_patch_count = 0

    // Patch prologue sub rsp with actual stack size
    if ss > 0:
        ss3 := ss
        if ss3 > 127:
            e2_w32(buf, g_x86_sub_rsp_pos + 3, ss3)
        else:
            w8(buf, g_x86_sub_rsp_pos + 3, ss3)

    // epilogue (emit with correct stack size, no placeholder)
    if ss > 0:
        if ss > 127:
            w8(buf, cp, 72)
            w8(buf, cp+1, 129)
            w8(buf, cp+2, 196)
            e2_w32(buf, cp+3, ss)
            cp = cp + 7
        else:
            w8(buf, cp, 72)
            w8(buf, cp+1, 131)
            w8(buf, cp+2, 196)
            w8(buf, cp+3, ss)
            cp = cp + 4
    if g_opt_level >= 1:
        // Pops in REVERSE order: rbp, r15, r14, r13, r12, rbx
        w8(buf, cp, 93)
        cp = cp + 1  // pop rbp
        w8(buf, cp, 65)
        w8(buf, cp+1, 95)
        cp = cp + 2  // pop r15
        w8(buf, cp, 65)
        w8(buf, cp+1, 94)
        cp = cp + 2  // pop r14
        w8(buf, cp, 65)
        w8(buf, cp+1, 93)
        cp = cp + 2  // pop r13
        w8(buf, cp, 65)
        w8(buf, cp+1, 92)
        cp = cp + 2  // pop r12
        w8(buf, cp, 91)
        cp = cp + 1  // pop rbx
    else:
        w8(buf, cp, 93)
        cp = cp + 1  // pop rbp
    w8(buf, cp, 195)
    cp = cp + 1  // ret

    // Function-tail slow-path blocks for tagged add/sub.
    // Each jo site gets its own block. The block emits the 128-bit correction
    // (e2_mw_slow_block), allocates 16 bytes, writes the 2-limb object, stores
    // the pointer in the value slot, sets tag = 1, and jumps back after the
    // fast-path store. jo records are emitted in site order. Functions without
    // jo sites emit no bytes.
    if g_x86_mw_jo_count > 0:
        mw_ji : ., mut = 0
        loop:
            if mw_ji >= g_x86_mw_jo_count:
                break
            jo_pos := r64(g_x86_mw_jo_pos, mw_ji * 8)
            jo_d := r64(g_x86_mw_jo_dest, mw_ji * 8)
            jo_sub := r64(g_x86_mw_jo_is_sub, mw_ji * 8)
            jo_res := r64(g_x86_mw_jo_resume, mw_ji * 8)
            mw_blk := cp
            w32(buf, jo_pos + 2, mw_blk - (jo_pos + 6))
            cp = cp + e2_mw_slow_block(buf, cp, jo_d, jo_sub, jo_res)
            mw_ji = mw_ji + 1
        g_x86_mw_jo_count = 0
    // Function-tail 2L operand blocks, after the jo blocks.
    // Each consumer site gets its own block (e2_mw_opnd_block). The fast-path tag
    // check reaches it with jne rel32. The block does 128-bit arithmetic or
    // comparison and a common result store. Its shape is specialized statically
    // by whether operand rows are tagged. Blocks that allocate use the same alloc
    // patch table as the function body. No consumer sites means no bytes.
    if g_x86_mw_oc_count > 0:
        mw_oi : ., mut = 0
        loop:
            if mw_oi >= g_x86_mw_oc_count:
                break
            oc_p1 := r64(g_x86_mw_oc_pos1, mw_oi * 8)
            oc_p2 := r64(g_x86_mw_oc_pos2, mw_oi * 8)
            oc_s1 := r64(g_x86_mw_oc_s1, mw_oi * 8)
            oc_s2 := r64(g_x86_mw_oc_s2, mw_oi * 8)
            oc_d := r64(g_x86_mw_oc_dest, mw_oi * 8)
            oc_op := r64(g_x86_mw_oc_op, mw_oi * 8)
            oc_res := r64(g_x86_mw_oc_resume, mw_oi * 8)
            oc_blk := cp
            if oc_p1 >= 0:
                w32(buf, oc_p1 + 2, oc_blk - (oc_p1 + 6))
            if oc_p2 >= 0:
                w32(buf, oc_p2 + 2, oc_blk - (oc_p2 + 6))
            cp = cp + e2_mw_opnd_block(buf, cp, oc_s1, oc_s2, oc_d, oc_op, oc_res)
            mw_oi = mw_oi + 1
        g_x86_mw_oc_count = 0
    return cp
