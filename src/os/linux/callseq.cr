// === callseq.cr ===
// SysV AMD64 call sequences for the Linux OS axis.
//
// Entry points:
//   1. cs_args_dispatch: register argument dispatch. int args use rdi, rsi, rdx,
//      rcx, r8, r9; binary64 args use xmm0-xmm7. Each class is numbered
//      independently. Used by IR_CALL, IR_CALL_EXTERN, and IR_SPAWN.
//   2. cs_arg_on_stack, cs_stack_count, cs_stack_args: stack argument test, count,
//      and push. Int args from the 7th and binary64 from the 9th go on the stack,
//      pushed right to left. The test and count share cs_arg_on_stack.
//   3. cs_stack_cleanup: add rsp after a call. It uses a 4-byte immediate when the
//      byte count is at most 127, otherwise a 7-byte form.
//   4. cs_ret_value: IR_RETURN value sequence, ret_patch registration, and jump
//      placeholder. TI_DEX returns in xmm0; a tagged local goes through tag read
//      path A.
//   5. cs_call_direct: direct call by name through g_x86_func_offsets, or external
//      relocation when not found; stores the return value when d >= 0.
//
// IR_CALL and IR_SPAWN use the stack helpers. IR_CALL_EXTERN only dispatches
// registers and does not push stack arguments or clean the stack. This is
// existing behavior; more than six integer extern arguments remain unsupported.
// IR_HOTPATCH_ROUTE keeps its own external placeholder and does not use
// cs_call_direct.
//
// buf is the byte buffer, pos is the absolute buffer position of this IR
// instruction, and cp is the number of bytes already emitted relative to pos.
// Each function returns the new cp. Calls look like
// cp = cs_xxx(buf, pos, cp, ...).
//
// Depends on instr.cr for encoding primitives and g2_slot, and the shared x86
// patch and global arrays.

// Register argument dispatch, shared by IR_CALL, IR_CALL_EXTERN, and IR_SPAWN.
// SysV AMD64 assigns int args to rdi, rsi, rdx, rcx, r8, r9 and binary64 args to
// xmm0-xmm7. Each class has its own index. The first pass emits register loads in
// left-to-right order. Arguments above the limit (7th int or 9th binary64) are
// not emitted here; cs_stack_args decides whether to push them. IR_CALL and
// IR_SPAWN push them, IR_CALL_EXTERN does not.
// Returns the new cp.
fn cs_args_dispatch(buf: string, pos: int, cp: int, fa: int, ac: int) -> int:
    ir_cnt : ., mut = 0
    fr_cnt : ., mut = 0
    ai := 0
    loop:
        if ai >= ac:
            break
        pt := irv_type(fa + ai)
        if pt == TI_DEX:
            if fr_cnt < 8:
                // Global arguments go through e2_sd_ld_var. A single-argument
                // call is never packed, so a global argument can reach here;
                // g2_slot would read outside the current frame.
                cp = cp + e2_sd_ld_var(buf, pos+cp, fr_cnt, fa + ai)
                fr_cnt = fr_cnt + 1
        else:
            if ir_cnt < 6:
                r := -1
                if ir_cnt == 0:
                    r = 7
                if ir_cnt == 1:
                    r = 6
                if ir_cnt == 2:
                    r = 2
                if ir_cnt == 3:
                    r = 1
                if ir_cnt == 4:
                    r = 8
                if ir_cnt == 5:
                    r = 9
                cp = cp + e2_load_var(buf, pos+cp, r, fa + ai)
                ir_cnt = ir_cnt + 1
        ai = ai + 1
    return cp

// Stack arguments: test, count, and push. IR_CALL and IR_SPAWN share them.
// cs_arg_on_stack returns 1 when the i-th argument goes on the stack: int from
// the 7th and binary64 from the 9th. The test counts earlier arguments of the
// same class. 1 means stack, 0 means register.
fn cs_arg_on_stack(fa: int, i: int) -> int:
    ic2 : ., mut = 0
    fc2 : ., mut = 0
    j2 : ., mut = 0
    loop:
        if j2 >= i:
            break
        if irv_type(fa + j2) == TI_DEX:
            fc2 = fc2 + 1
        else:
            ic2 = ic2 + 1
        j2 = j2 + 1
    if irv_type(fa + i) == TI_DEX:
        if fc2 >= 8:
            return 1
    else:
        if ic2 >= 6:
            return 1
    return 0

// Number of stack arguments. cs_stack_cleanup uses count*8 as the add rsp
// immediate. This function and cs_stack_args use the same cs_arg_on_stack rule,
// so their counts always agree.
fn cs_stack_count(fa: int, ac: int) -> int:
    n : ., mut = 0
    i : ., mut = 0
    loop:
        if i >= ac:
            break
        if cs_arg_on_stack(fa, i) > 0:
            n = n + 1
        i = i + 1
    return n

// Push stack arguments right to left, so at the call [rsp] is the 7th int or
// 9th binary64. Int: load into r10 and push r10 (41 52). Binary64: load into
// xmm0 and call e2_push_xmm0 (sub rsp,8; movsd [rsp],xmm0). Returns the new cp.
fn cs_stack_args(buf: string, pos: int, cp: int, fa: int, ac: int) -> int:
    stack_ai : ., mut = ac - 1
    loop:
        if stack_ai < 0:
            break
        if cs_arg_on_stack(fa, stack_ai) > 0:
            if irv_type(fa + stack_ai) == TI_DEX:
                // 栈参 dex 装载同样走 seam（与寄存器支同规约）
                cp = cp + e2_sd_ld_var(buf, pos+cp, 0, fa + stack_ai)
                cp = cp + e2_push_xmm0(buf, pos+cp)
            else:
                cp = cp + e2_load_var(buf, pos+cp, 10, fa + stack_ai)
                e2_w8(buf, pos+cp, 65)
                e2_w8(buf, pos+cp+1, 82)
                cp = cp + 2  // push r10
        stack_ai = stack_ai - 1
    return cp

// Stack cleanup, shared by IR_CALL and IR_SPAWN.
// Restore rsp after the call with add rsp, stack_count*8. Use the 4-byte form
// (48 83 C4 imm8) when the byte count is at most 127, otherwise the 7-byte form
// (48 81 C4 imm32). Returns the new cp.
fn cs_stack_cleanup(buf: string, pos: int, cp: int, stack_count: int) -> int:
    if stack_count > 0:
        stack_bytes := stack_count * 8
        if stack_bytes <= 127:
            e2_w8(buf, pos+cp, 72)
            e2_w8(buf, pos+cp+1, 131)
            e2_w8(buf, pos+cp+2, 196)
            e2_w8(buf, pos+cp+3, stack_bytes)
            cp = cp + 4
        else:
            e2_w8(buf, pos+cp, 72)
            e2_w8(buf, pos+cp+1, 129)
            e2_w8(buf, pos+cp+2, 196)
            e2_w32(buf, pos+cp+3, stack_bytes)
            cp = cp + 7
    return cp

// IR_RETURN value sequence, ret_patch registration, and jump placeholder.
// When s1 < 0 there is no value; only ret_patch is registered, and the epilogue
// patches the jmp. Returns the new cp.
fn cs_ret_value(buf: string, pos: int, cp: int, s1: int) -> int:
    if s1 >= 0:
        if e2_is_glob(s1) != 0:
            // The global branch dispatches by type. Do not move the dex test
            // earlier: a global dex return uses xmm0, not rax. Global dex returns
            // are currently unreachable because return sites are scaled and s1 is
            // always a temporary; this ordering is an invariant guard.
            if irv_type(s1) == TI_DEX:
                cp = cp + e2_sd_ld_var(buf, pos+cp, 0, s1)   // movsd xmm0, [rip 槽]
            else:
                // Global: load via RIP-relative into rax
                grow_rip_patch(g_x86_rip_patch_count + 1)
                w64(g_x86_rip_patch_pos, g_x86_rip_patch_count * 8, pos + cp + 3)
                w64(g_x86_rip_patch_globals, g_x86_rip_patch_count * 8, s1)
                g_x86_rip_patch_count = g_x86_rip_patch_count + 1
                cp = cp + e2_lr(buf, pos+cp, 0)       // lea r10, [rip+0]
                // mov rax, [r10], REX.WB with 0x8B
                cp = cp + emit_rex(buf, pos+cp, 1, 0, 0, 10/8)
                e2_w8(buf, pos+cp, 139)
                cp = cp + 1
                cp = cp + emit_modrm(buf, pos+cp, 0, 0, 10%8)
        else if irv_type(s1) == TI_DEX:
            // binary64 返回：movsd xmm0, [slot]（SysV 返回值在 XMM0，apx 快路径）
            cp = cp + e2_sd_load(buf, pos+cp, g2_slot(s1))
        else:
            cp = cp + e2_ld(buf, pos+cp, 0, g2_slot(s1))
    // Record the jump position for the caller to patch to the epilogue.
    grow_ret_patch(g_x86_ret_patch_count + 1)
    w64(g_x86_ret_patch_pos, g_x86_ret_patch_count * 8, pos + cp)
    g_x86_ret_patch_count = g_x86_ret_patch_count + 1
    cp = cp + e2_jmp(buf, pos+cp, 0)
    return cp

// Direct call path for IR_CALL.
// Look up the function name (interned string index) in g_x86_func_offsets:
//   hit: e2_call direct relative call (target = code base 176 + body offset).
//   miss: register an external relocation (g_x86_ext_rel_*, resolved by the
//   dynamic linker) and emit a call placeholder.
// Both register a call patch first (g_x86_call_patch_*), then the post-emission
// pass fills in the actual cp. When d >= 0, store the return value with
// e2_store_ret (int in rax, dex in xmm0). Returns the new cp.
fn cs_call_direct(buf: string, pos: int, cp: int, s3: int, d: int) -> int:
    fn2 := istr_get(s3)
    to := -1
    tf := 0
    loop:
        if tf >= g_x86_func_off_count:
            break
        if str_eq(istr_get(r64(g_x86_func_offsets, tf*16)), fn2) != 0:
            to = r64(g_x86_func_offsets, tf*16+8)
            break
        tf = tf + 1
                // Record call position for post-emission patching
    grow_call_patch(g_x86_call_patch_count + 1)
    w64(g_x86_call_patch_pos, g_x86_call_patch_count * 8, pos + cp)
    w64(g_x86_call_patch_name, g_x86_call_patch_count * 8, str_intern(fn2))
    g_x86_call_patch_count = g_x86_call_patch_count + 1
    if to >= 0:
        cp = cp + e2_call(buf, pos+cp, (176 + to) - (pos + cp + 5))
    else:
        // Unknown function: emit external relocation (for dynamic linking)
        grow_ext_rel(g_x86_ext_rel_count + 1)
        w64(g_x86_ext_rel_pos, g_x86_ext_rel_count * 8, pos + cp + 1)
        w64(g_x86_ext_rel_name, g_x86_ext_rel_count * 8, s3)
        g_x86_ext_rel_count = g_x86_ext_rel_count + 1
        cp = cp + e2_call(buf, pos+cp, 0)
    if d >= 0:
        cp = cp + e2_store_ret(buf, pos+cp, d)
    return cp
