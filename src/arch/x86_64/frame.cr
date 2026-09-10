// ══════════════════════════════════════════════════════════════
// src/arch/x86_64/frame.cr —— 架构轴：x86-64 函数帧
//
// x86 实例化波 1 Task 3 抽取（帧公式双源合流——H2 波 1 最大风险之一）：
//   - 帧尺寸/帧相关字节核算自 src/format/elf/elf.cr（Phase 2 dry-run 核算 +
//     Phase 3 sub rsp 立即数）与 src/arch/x86_64/instr.cr（g2_tag_off /
//     mw_frame_size——H3 归属裁决：帧布局面归 frame，tag2l 依赖 frame）迁入；
//   - 序言/尾声/函数尾附加块（jo 慢路径块 + 2L 操作数块）自 elf.cr Phase 3
//     抽为本文件 pf_prologue/pf_epilogue（发射序逐字节 verbatim——波 1 判据
//     = stage 链 byte-identical）。
//
// **H2 帧公式单源**（三处入口，各自唯一）：
//   ① 帧总字节     = pf_frame_size(vc)      —— Phase 2 dry-run 与 Phase 3
//                    sub rsp 立即数两处**调用同一函数**（此前双源 = 唯一风险面;
//                    test_mw_task1.py 的 sub rsp 立即数断言 = 帧专项判据）；
//   ② 帧字节总数   = pf_frame_overhead(ss)  —— dry-run 只核算，须与 ③ 的
//                    实际发射逐字节一致（尺寸原语 sz_* 由 sizes.cr 单源）；
//   ③ 实际发射     = pf_prologue/pf_epilogue —— 帧相关段的唯一发射器
//                    （elf.cr 零残留帧尺寸计算/帧发射序）。
// tag 区（int 多字 M1）：tag 字节位于槽区之下，偏移 -(vc*8+1+k)——公式与
// 识别规则见 instr.cr mw_setup_tags 注释块；tag 数为 0 时帧公式与旧布局
// 逐字节一致（快路径零变化硬约束）。
//
// 抽取纪律（H1）：cp/pos/buf 三参数显式传递（无环境态假设）；调用点 = elf.cr
// Phase 2 dry-run 与 Phase 3 函数发射序。
//
// Depends on: x86_64/instr.cr（e2_*/e2_mw_slow_block/e2_mw_opnd_block/
//             emit_rex/emit_modrm/get_reg_for_var/w8/w32/r64）、
//             x86_64/sizes.cr（sz_* 编码尺寸单源）、共享全局（g_opt_level/
//             g_current_func_var_start/g_x86_sub_rsp_pos/g_x86_mw_* 站点表）。
// 跨文件引用经 concat 扁平单元（build_selfhost_native.py arch_x86_64_files）
// / module.cr 三轴回退链（组合根 _import.cr `import frame`）解析。
// ══════════════════════════════════════════════════════════════

// ── tag 表读取（H3 自 instr.cr 迁入；表由 instr.cr mw_setup_tags 按函数填充）──
fn g2_tag_off(v: int) -> int {
    // var v（当前函数内）的 tag 字节偏移（相对 rbp，恒负）；-1 = 非 tagged。
    // 仅当前函数内有效（表由 mw_setup_tags 按函数填充）。
    if v < 0 { return -1; }
    lv := v - g_current_func_var_start;
    if lv < 0 { return -1; }
    if str_len(g_x86_mw_tag_off) <= lv * 8 { return -1; }
    return r64(g_x86_mw_tag_off, lv * 8);
}

// ── 帧总字节（H2 ①：Phase 2 dry-run 与 Phase 3 共用）──
fn pf_frame_size(vc: int) -> int {
    // 帧总字节 = var 槽 vc*8 + tag 区（g_x86_mw_tag_count 字节）再按现 SysV
    // 规则补 16 对齐：opt≥1（6 pushes）帧 ≡ 8 (mod 16)；opt<1（1 push）≡ 0。
    // tag 数为 0 时对任意 vc 的结果与旧公式逐字节一致（快路径零变化）。
    sz : ., mut = vc * 8 + g_x86_mw_tag_count;
    r := sz % 16;
    if g_opt_level >= 1 {
        if r != 8 {
            pad := 8 - r;
            if pad < 0 { pad = pad + 16; }
            sz = sz + pad;
        }
    } else {
        if r != 0 { sz = sz + (16 - r); }
    }
    return sz;
}

// ── Phase 2 dry-run：帧相关字节总数（序言 + 尾声；不含形参落槽与函数体）──
// H2 ②：dry-run 核算（本函数）与 H2 ③ 实际发射（pf_prologue/pf_epilogue）必须
// 一致——尺寸原语 sz_* 单源 sizes.cr；本函数 = 帧的核算侧唯一入口。
fn pf_frame_overhead(ss: int) -> int {
    sz : ., mut = sz_push_rbp() + sz_mov_rbp_rsp();
    if g_opt_level >= 1 { sz = sz + 18; }  // push rbx,r12-r15(9) + pop r15-r12,rbx(9)
    sz = sz + sz_sub_rsp(ss);
    sz = sz + sz_add_rsp(ss) + sz_pop_rbp() + sz_ret();
    if g_opt_level >= 1 { sz = sz + 9; }  // pop r15,r14,r13,r12,rbx
    return sz;
}

// ── Phase 3 序言（帧 setup + 形参落槽 + 寄存器参数装载）──
// 发射序（opt≥1 六寄存器保存 → push rbp/mov rbp,rsp → sub rsp 占位（立即数
// 由 pf_epilogue 回填实际帧字节）→ 形参落槽（XMM/int/栈参 + tag 卫生③参数行
// 清 tag）→ 寄存器分配参数装载）；返回新 cp。g_x86_sub_rsp_pos = sub rsp
// 立即数字段位置（供 pf_epilogue 回填）；帧尺寸 ss 显式传入（= pf_frame_size
// 结果——H2 单源，本函数不再自行计算帧尺寸）。
fn pf_prologue(vs: int, pc: int, ss: int, buf: string, pos: int) -> int {
    cp : ., mut = pos;
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
    if ss > 0 {
        if ss > 127 {
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
        // int 多字 M1（Task 4）tag 卫生③：tagged 参数行的 prologue 定值
        // 清 tag——参数在函数内首次定值前可能被消费者读取（tag 闭包可含
        // 参数行：p = p + k 的 B' 定值拷贝），无本清则读到上次调用/垃圾
        // tag。参数行按强制栈槽保存（po2），tag 字节同在帧内。
        if pty == TI_INT {
            ptg := g2_tag_off(vs + pi);
            if ptg != -1 {
                if ptg >= -128 && ptg <= 127 {
                    w8(buf, cp, 198); w8(buf, cp+1, 69); w8(buf, cp+2, ptg); w8(buf, cp+3, 0); cp = cp + 4;
                } else {
                    w8(buf, cp, 198); w8(buf, cp+1, 133); e2_w32(buf, cp+2, ptg); w8(buf, cp+6, 0); cp = cp + 7;
                }
            }
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
    return cp;
}


// ── Phase 3 尾声 + 函数尾附加块 ——
// RETURN patch（回填至 epilogue 起点）→ sub rsp 立即数回填（实际帧字节）→
// epilogue 发射（add rsp / opt≥1 六寄存器逆序 pop / pop rbp / ret）→ 函数尾
// 附加块（jo 慢路径块 + 2L 操作数块；逐站点独立块，冷区）。返回新 cp。
// ss 显式传入（= 序言所用帧尺寸；H2 单源）。
fn pf_epilogue(ss: int, buf: string, pos: int) -> int {
    cp : ., mut = pos;
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
    if ss > 0 {
        ss3 := ss;
        if ss3 > 127 {
            e2_w32(buf, g_x86_sub_rsp_pos + 3, ss3);
        } else {
            w8(buf, g_x86_sub_rsp_pos + 3, ss3);
        }
    }

    // epilogue (emit with correct stack size, no placeholder)
    if ss > 0 {
        if ss > 127 {
            w8(buf, cp, 72); w8(buf, cp+1, 129); w8(buf, cp+2, 196);
            e2_w32(buf, cp+3, ss); cp = cp + 7;
        } else {
            w8(buf, cp, 72); w8(buf, cp+1, 131); w8(buf, cp+2, 196); w8(buf, cp+3, ss); cp = cp + 4;
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

    // ── int 多字 M1（Task 3）：慢路径块（函数尾附加）+ jo rel32 回填 ──
    // 每 jo 站点独立块（块形状决策：jo 现场 = dest 槽/回跳点逐站点而异，
    // 共享块需逐站分发 = 复杂度不值；块 ≈ 45B × 站点数，函数尾冷区，M1
    // 保守 tagged 集代价的一部分——与 Task 2 已付的每站 jo 6B 同族）。
    // 块 = 真实 2-limb 修正代码（e2_mw_slow_block，instr.cr）：
    //   修正 128 位值 → alloc(16)（alloc_patch 注册——计数逐函数不重置，
    //   与函数体 alloc 调用同批回填）→ 写 2-limb → 值槽存指针（含
    //   O1/O2 reg 形态——g2_slot 于当前函数上下文现算，与函数体发射
    //   同源同值）→ tag 置位 → jmp 回该站点快路径 store 之后。
    // jo 记录（pos/dest/is_sub/resume——g2_init 清零逐函数段）此处按站
    // 点点序发射；无 jo 的函数不发块、零字节影响（untagged 快路径零变化）。
    if g_x86_mw_jo_count > 0 {
        mw_ji : ., mut = 0;
        loop { if mw_ji >= g_x86_mw_jo_count { break; }
            jo_pos := r64(g_x86_mw_jo_pos, mw_ji * 8);
            jo_d := r64(g_x86_mw_jo_dest, mw_ji * 8);
            jo_sub := r64(g_x86_mw_jo_is_sub, mw_ji * 8);
            jo_res := r64(g_x86_mw_jo_resume, mw_ji * 8);
            mw_blk := cp;
            w32(buf, jo_pos + 2, mw_blk - (jo_pos + 6));
            cp = cp + e2_mw_slow_block(buf, cp, jo_d, jo_sub, jo_res);
            mw_ji = mw_ji + 1; }
        g_x86_mw_jo_count = 0;
    }
    // ── int 多字 M1（Task 4）：2L 操作数块（函数尾附加，jo 块之后）──
    // 每消费者站点独立块（快路径 tag 检查 jne → 块首；块 = 128 位算术
    // 或比较 + 公共落值——e2_mw_opnd_block，instr.cr）。块形状按站点
    // 静态参数化（操作数行 tagged 与否决定分派形态），含 alloc(16) 的
    // 块与函数体同批回填（alloc_patch 计数逐函数不重置）。jne rel32
    // 位置在 oc 记录（pos1/pos2，-1 = 无第二个检查），块位置 = 发射时
    // cp。无消费者站点的函数零字节（untagged 快路径零变化保持）。
    if g_x86_mw_oc_count > 0 {
        mw_oi : ., mut = 0;
        loop { if mw_oi >= g_x86_mw_oc_count { break; }
            oc_p1 := r64(g_x86_mw_oc_pos1, mw_oi * 8);
            oc_p2 := r64(g_x86_mw_oc_pos2, mw_oi * 8);
            oc_s1 := r64(g_x86_mw_oc_s1, mw_oi * 8);
            oc_s2 := r64(g_x86_mw_oc_s2, mw_oi * 8);
            oc_d := r64(g_x86_mw_oc_dest, mw_oi * 8);
            oc_op := r64(g_x86_mw_oc_op, mw_oi * 8);
            oc_res := r64(g_x86_mw_oc_resume, mw_oi * 8);
            oc_blk := cp;
            if oc_p1 >= 0 { w32(buf, oc_p1 + 2, oc_blk - (oc_p1 + 6)); }
            if oc_p2 >= 0 { w32(buf, oc_p2 + 2, oc_blk - (oc_p2 + 6)); }
            cp = cp + e2_mw_opnd_block(buf, cp, oc_s1, oc_s2, oc_d, oc_op, oc_res);
            mw_oi = mw_oi + 1; }
        g_x86_mw_oc_count = 0;
    }
    return cp;
}
