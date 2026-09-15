// ══════════════════════════════════════════════════════════════
// src/os/linux/callseq.cr —— OS 轴：SysV AMD64 调用约定序列
//   （寄存器参数分派 / 栈参压栈 / 栈清理 / 返回值 / 直接调用）
//
// x86 实例化波 1 Task 5 抽取（H1 波 1 最大风险之一——emit_instr 内联段落）：
// emit_instr（src/arch/x86_64/instr.cr）中 IR_CALL / IR_CALL_EXTERN /
// IR_SPAWN / IR_RETURN 四分支的调用序列此前全部内联在巨函数里，本文件把它们
// 抽为 5 个入口（发射序逐字节 verbatim——波 1 判据 = stage 链 byte-identical）：
//   ① cs_args_dispatch  —— 寄存器参数分派（int: rdi,rsi,rdx,rcx,r8,r9；
//      binary64: xmm0-7，int/float 各自独立编号）。**三处同源合流**：IR_CALL
//      主路径 / IR_CALL_EXTERN / IR_SPAWN 三处逐字节相同的分派段（差异核对
//      见下），抽取后三调用点共用本入口。
//   ② cs_arg_on_stack / cs_stack_count / cs_stack_args —— 栈参判定 + 压栈
//      （右到左压；第 7 个 int / 第 9 个 binary64 起才压）。判定单入口
//      （cs_arg_on_stack）——计数（cs_stack_count，供清理立即数）与发射
//      （cs_stack_args）共用同一规则，防判定/计数双源漂移。
//   ③ cs_stack_cleanup  —— call 后 add rsp 恢复（≤127B 用 4B 立即数形，
//      否则 7B 形）。
//   ④ cs_ret_value      —— IR_RETURN 值序列（TI_DEX → xmm0；global → RIP
//      读 rax；局部 → rax 装载 + int 多字 tag 读路径 A）+ ret_patch 登记 +
//      jmp 占位（尾声回填）。
//   ⑤ cs_call_direct    —— 通用调用路径（按名查 g_x86_func_offsets → e2_call；
//      未找到 → g_x86_ext_rel_* 外部位）+ 返回值存（d ≥ 0）。
//
// 归属裁决（设计 §1 "ABI = 交叉轴"）：ABI = 架构轴寄存器集 × OS 轴调用约定
// ——本文件 = 调用约定的 OS 轴落点；寄存器名/编码原语（e2_*/emit_*/g2_slot/
// irv_type/TI_DEX）经架构轴 src/arch/x86_64/instr.cr（concat 扁平单元 /
// module.cr 三轴回退链解析，见组合根 _import.cr `import callseq`）。
// 与 x86_64/instr.cr 的关系：instr.cr = 指令编码原语 + emit_instr 分派；
// 本文件 = 序列算法（多指令粘合序）——不新增任何编码原语。
//
// 抽取纪律（H1）：cp/pos/buf 三参数显式传递（无环境态假设）——buf = 字节
// 缓冲、pos = 本 IR 指令的绝对缓冲起点、cp = 相对 pos 的已发字节数；返回
// **新 cp**（相对量）。调用点形如 `cp = cs_xxx(buf, pos, cp, ...)`（与
// emit_instr 内部约定一致；注：同波 frame.cr pf_* 取绝对位置约定，两者按
// 各自宿主函数风格定形，见 frame.cr 头注）。
//
// **三处同源合流差异核对结论**（抽取时逐处比对——不得静默合并）：
//   ✔ cs_args_dispatch：IR_CALL / IR_CALL_EXTERN / IR_SPAWN 三处发射字节
//     逐字节相同（同一 e2_sd_load_x 序号 + e2_load_var 序列 + 同一 int 寄存器
//     映射表 rdi(7),rsi(6),rdx(2),rcx(1),r8(8),r9(9)），合并等价。
//   ✔ cs_stack_args / cs_stack_cleanup：IR_CALL 与 IR_SPAWN 两处逐字节相同，
//     合并等价；**IR_CALL_EXTERN 不调用二者**（预存行为：extern 路径只做寄存器
//     分派，无栈参压栈/栈清理——波 1 逐字节保持，不改判据；>6 int 参 extern
//     调用的语义缺口见 TODO 挂账，属波 2 参数化面）。
//   ✔ cs_call_direct：IR_CALL 专有（IR_HOTPATCH_ROUTE 形式近似但语义不同——
//     恒外部位占位、无 g_x86_func_offsets 查名——保持分立原位）。
//   ✔ cs_ret_value：IR_RETURN 值序列专有；IR_CALL/IR_HOTPATCH_ROUTE 用
//     e2_store_ret（d ≥ 0 门）、IR_SPAWN 另有 TI_DEX/整数两分派、
//     IR_CALL_EXTERN 恒 e2_st(rax)（无 dex 分支、无 d 门）——差异面各自保留
//     原位，不在本任务抽界内。
//
// Depends on: x86_64/instr.cr（e2_*/emit_rex/emit_modrm/g2_slot/istr_get/
//             str_eq/str_intern）、x86_64/frame.cr（g2_tag_off——tag 读路径 A
//             的 tag 字节偏移）、x86_64/tag2l.cr（e2_mw_t8——tag 测试字节）、
//             共享全局（g_x86_func_offsets/g_x86_call_patch_*/g_x86_ext_rel_*/
//             g_x86_ret_patch_*/g_x86_rip_patch_*/g_x86_is_global）。
// ══════════════════════════════════════════════════════════════

// ── ① 寄存器参数分派（IR_CALL 主路径 / IR_CALL_EXTERN / IR_SPAWN 三处同源）──
// SysV AMD64：int 用 ir（0-5 → rdi,rsi,rdx,rcx,r8,r9），binary64 用 fr
// （0-7 → xmm0-7），各自独立编号（标准答案）。第一遍按位置顺序（左到右）发
// 寄存器装载；超限者（第 7 int / 第 9 binary64 起）不在此处发射——留待
// cs_stack_args（调用点自行决定是否压栈：IR_CALL/IR_SPAWN 压，EXTERN 不压）。
// 返回新 cp。
fn cs_args_dispatch(buf: string, pos: int, cp: int, fa: int, ac: int) -> int {
    ir_cnt : ., mut = 0; fr_cnt : ., mut = 0;
    ai := 0;
    loop { if ai >= ac { break; }
        pt := irv_type(fa + ai);
        if pt == TI_DEX {
            if fr_cnt < 8 {
                cp = cp + e2_sd_load_x(buf, pos+cp, g2_slot(fa + ai), fr_cnt);
                fr_cnt = fr_cnt + 1;
            }
        } else {
            if ir_cnt < 6 {
                r := -1;
                if ir_cnt == 0 { r = 7; } if ir_cnt == 1 { r = 6; } if ir_cnt == 2 { r = 2; }
                if ir_cnt == 3 { r = 1; } if ir_cnt == 4 { r = 8; } if ir_cnt == 5 { r = 9; }
                cp = cp + e2_load_var(buf, pos+cp, r, fa + ai);
                ir_cnt = ir_cnt + 1;
            }
        }
    ai = ai + 1; }
    return cp;
}

// ── ② 栈参：判定 / 计数 / 压栈（IR_CALL + IR_SPAWN 两处同源）──
// 第 i 个实参是否超限落栈（SysV：int 第 7 个起、binary64 第 9 个起）。
// 判定 = 类型 × 该类型在 i 之前的实参个数（与提取前内联段同一规则）。
// 1 = 落栈，0 = 走寄存器。
fn cs_arg_on_stack(fa: int, i: int) -> int {
    ic2 : ., mut = 0; fc2 : ., mut = 0;
    j2 : ., mut = 0;
    loop { if j2 >= i { break; }
        if irv_type(fa + j2) == TI_DEX { fc2 = fc2 + 1; } else { ic2 = ic2 + 1; }
        j2 = j2 + 1; }
    if irv_type(fa + i) == TI_DEX {
        if fc2 >= 8 { return 1; }
    } else {
        if ic2 >= 6 { return 1; }
    }
    return 0;
}

// 实际压栈参数个数（cs_stack_cleanup 的 add rsp 立即数 = count*8）。
// 与 cs_stack_args 同规则（cs_arg_on_stack）——两处计数恒等。
fn cs_stack_count(fa: int, ac: int) -> int {
    n : ., mut = 0; i : ., mut = 0;
    loop { if i >= ac { break; }
        if cs_arg_on_stack(fa, i) > 0 { n = n + 1; }
        i = i + 1; }
    return n;
}

// 栈参压栈（右到左压——保持栈上实参位置顺序：调用时 [rsp] = 第 7 int / 第 9
// binary64）。int → r10 装载 + push r10（41 52）；binary64 → xmm0 装载 +
// e2_push_xmm0（sub rsp,8 + movsd [rsp],xmm0）。返回新 cp。
fn cs_stack_args(buf: string, pos: int, cp: int, fa: int, ac: int) -> int {
    stack_ai : ., mut = ac - 1;
    loop {
        if stack_ai < 0 { break; }
        if cs_arg_on_stack(fa, stack_ai) > 0 {
            if irv_type(fa + stack_ai) == TI_DEX {
                cp = cp + e2_sd_load_x(buf, pos+cp, g2_slot(fa + stack_ai), 0);
                cp = cp + e2_push_xmm0(buf, pos+cp);
            } else {
                cp = cp + e2_load_var(buf, pos+cp, 10, fa + stack_ai);
                e2_w8(buf, pos+cp, 65); e2_w8(buf, pos+cp+1, 82); cp = cp + 2;  // push r10
            }
        }
        stack_ai = stack_ai - 1;
    }
    return cp;
}

// ── ③ 栈清理（IR_CALL + IR_SPAWN 两处同源）──
// call 后恢复 rsp：add rsp, stack_count*8——字节数 ≤127 → 4B 立即数形
// （48 83 C4 imm8），否则 7B 形（48 81 C4 imm32）。返回新 cp。
fn cs_stack_cleanup(buf: string, pos: int, cp: int, stack_count: int) -> int {
    if stack_count > 0 {
        stack_bytes := stack_count * 8;
        if stack_bytes <= 127 {
            e2_w8(buf, pos+cp, 72); e2_w8(buf, pos+cp+1, 131);
            e2_w8(buf, pos+cp+2, 196); e2_w8(buf, pos+cp+3, stack_bytes); cp = cp + 4;
        } else {
            e2_w8(buf, pos+cp, 72); e2_w8(buf, pos+cp+1, 129); e2_w8(buf, pos+cp+2, 196);
            e2_w32(buf, pos+cp+3, stack_bytes); cp = cp + 7;
        }
    }
    return cp;
}

// ── ④ IR_RETURN 值序列 + ret_patch 登记 + jmp 占位 ──
// s1 < 0（无值）→ 只登记 ret_patch（尾声回填 jmp → epilogue）。
// 返回新 cp。
fn cs_ret_value(buf: string, pos: int, cp: int, s1: int) -> int {
    if s1 >= 0 {
        if irv_type(s1) == TI_DEX {
            // binary64 返回：movsd xmm0, [slot]（SysV 返回值在 XMM0，apx 快路径）
            cp = cp + e2_sd_load(buf, pos+cp, g2_slot(s1));
        } else if r64(g_x86_is_global, s1 * 8) != 0 {
            // Global: load via RIP-relative into rax
            grow_rip_patch(g_x86_rip_patch_count + 1);
            w64(g_x86_rip_patch_pos, g_x86_rip_patch_count * 8, pos + cp + 3);
            w64(g_x86_rip_patch_globals, g_x86_rip_patch_count * 8, s1);
            g_x86_rip_patch_count = g_x86_rip_patch_count + 1;
            cp = cp + e2_lr(buf, pos+cp, 0);       // lea r10, [rip+0]
            // mov rax, [r10] — REX.WB + 0x8B
        cp = cp + emit_rex(buf, pos+cp, 1, 0, 0, 10/8); e2_w8(buf, pos+cp, 139); cp = cp + 1; cp = cp + emit_modrm(buf, pos+cp, 0, 0, 10%8);
        } else {
            cp = cp + e2_ld(buf, pos+cp, 0, g2_slot(s1));
            // int 多字 M1（Task 4）tag 读路径 A：return 的 tagged 局部值
            // ——tag=1（槽 = 2-limb 指针）→ 解指针取低 limb → rax（exit
            // 低 8 位 = 数学值低字节；不解 = 指针低字节 = 错值）。tag=0
            // → 快值原样。行内（je rel8 跨 3B deref——tag 字节测试）。
            tg := g2_tag_off(s1);
            if tg != -1 {
                cp = cp + e2_mw_t8(buf, pos+cp, tg);
                w8(buf, pos+cp, 116); w8(buf, pos+cp+1, 3); cp = cp + 2;  // je +3
                w8(buf, pos+cp, 72); w8(buf, pos+cp+1, 139); w8(buf, pos+cp+2, 0); cp = cp + 3;  // mov rax, [rax]
            }
        }
    }
    // record position for caller to patch jmp → epilogue
    grow_ret_patch(g_x86_ret_patch_count + 1); w64(g_x86_ret_patch_pos, g_x86_ret_patch_count * 8, pos + cp);
    g_x86_ret_patch_count = g_x86_ret_patch_count + 1;
    cp = cp + e2_jmp(buf, pos+cp, 0);
    return cp;
}

// ── ⑤ 通用调用路径（IR_CALL 的 s3 ≥ 0 分支）──
// 按函数名（interned string 索引）查 g_x86_func_offsets：
//   命中 → e2_call 直接相对调用（目标 = 代码起点 176 + 函数体偏移）
//   未命中 → 外部位登记（g_x86_ext_rel_*，动态链接期解析）+ call 占位
// 两者都先登记 call 补丁（g_x86_call_patch_*，名字 → 后置回填实际 cp）。
// 末尾 d ≥ 0 → e2_store_ret（int → rax / dex → xmm0）。返回新 cp。
fn cs_call_direct(buf: string, pos: int, cp: int, s3: int, d: int) -> int {
    fn2 := istr_get(s3);
    to := -1; tf := 0;
    loop { if tf >= g_x86_func_off_count { break; } if str_eq(istr_get(r64(g_x86_func_offsets, tf*16)), fn2) != 0 { to = r64(g_x86_func_offsets, tf*16+8); break; } tf = tf + 1; }
                // Record call position for post-emission patching
    grow_call_patch(g_x86_call_patch_count + 1);
    w64(g_x86_call_patch_pos, g_x86_call_patch_count * 8, pos + cp);
    w64(g_x86_call_patch_name, g_x86_call_patch_count * 8, str_intern(fn2));
    g_x86_call_patch_count = g_x86_call_patch_count + 1;
    if to >= 0 {
        cp = cp + e2_call(buf, pos+cp, (176 + to) - (pos + cp + 5));
    } else {
        // Unknown function: emit external relocation (for dynamic linking)
        grow_ext_rel(g_x86_ext_rel_count + 1);
        w64(g_x86_ext_rel_pos, g_x86_ext_rel_count * 8, pos + cp + 1);
        w64(g_x86_ext_rel_name, g_x86_ext_rel_count * 8, s3);
        g_x86_ext_rel_count = g_x86_ext_rel_count + 1;
        cp = cp + e2_call(buf, pos+cp, 0);
    }
    if d >= 0 { cp = cp + e2_store_ret(buf, pos+cp, d); }
    return cp;
}
