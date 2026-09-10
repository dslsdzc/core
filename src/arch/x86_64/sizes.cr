// ══════════════════════════════════════════════════════════════
// Single source of truth for all x86-64 instruction byte sizes.
//
// Every instruction size in the backend comes from here:
//   - instr_size() calls these helpers
//   - Phase 2 prologue/epilogue uses these helpers
//   - emit_instr() returns sizes via e2_* return values (must match)
//
// NEVER hardcode byte counts in elf.cr, instr.cr, resolve.cr, or src/os/linux/entry.cr
// (_start 体与 sz_start_body/sz_start_argv_save 必须同步——H2 类双源守护).
// Change a size here → all phases automatically agree.
// ══════════════════════════════════════════════════════════════

// ── Basic encoding sizes (one per e2_* helper in instr.cr) ──
fn sz_mov() -> int { return 3; }
fn sz_ld(o: int) -> int { if o >= E2_REG_SLOT_BASE { return 3; } if o >= -128 && o <= 127 { return 4; } return 7; }
fn sz_st(o: int) -> int { if o >= E2_REG_SLOT_BASE { return 3; } if o >= -128 && o <= 127 { return 4; } return 7; }
fn sz_li(o: int, v: int) -> int {
    if v < -2147483647 - 1 || v > 2147483647 {
        if o >= -128 && o <= 127 { return 14; }  // mov rax,imm64(10) + mov [rbp+disp8],rax(4)
        return 17;  // mov rax,imm64(10) + mov [rbp+disp32],rax(7)
    }
    if o >= -128 && o <= 127 { return 8; }
    return 11;
}
fn sz_lr() -> int { return 7; }
fn sz_lrb() -> int { return 7; }
fn sz_lb(o: int) -> int { if o >= -128 && o <= 127 { return 4; } return 7; }
fn sz_call() -> int { return 5; }
fn sz_jmp() -> int { return 5; }
fn sz_je() -> int { return 6; }
fn sz_alu() -> int { return 3; }
fn sz_jo() -> int { return 6; }  // jo rel32 (0F 80 cd)——慢路径块附函数尾，rel8 ±127 在 >127B 函数体上不可达
fn sz_syscall() -> int { return 2; }

// ── Prologue / epilogue sizes ──
fn sz_push_rbp() -> int { return 1; }
fn sz_mov_rbp_rsp() -> int { return 3; }
fn sz_sub_rsp(ss: int) -> int {
    if ss <= 0 { return 0; }
    if ss > 127 { return 7; }
    return 4;
}
fn sz_add_rsp(ss: int) -> int { return sz_sub_rsp(ss); }
fn sz_pop_rbp() -> int { return 1; }
fn sz_ret() -> int { return 1; }

// Each register param save uses func-relative offsets (always disp8)
fn sz_save_param() -> int { return 4; }
// Stack params need one load from the caller frame and one local store.
fn sz_save_stack_param() -> int { return 8; }

// ── _start size (simple case, no argc/argv globals) ──
fn sz_start_body() -> int { return 4 + 5 + sz_call() + 2 + 5 + sz_syscall(); }
fn sz_start_argv_save() -> int { return sz_lr() + 3; }

// ── per-opcode instruction size estimates (used by Phase 2 layout) ──
fn instr_size(op: int) -> int {
    if op == IR_INLINE         { return 0; }
    if op == IR_NO_BOUNDS_CHECK { return 0; }
    if op == IR_FAST           { return 0; }
    if op == IR_UNROLL         { return 0; }
    if op == IR_SECTION        { return 0; }
    if op == IR_APPROX         { return 0; }
    if op == IR_LAZY_THUNK     { return 11; }
    if op == IR_LAZY_FORCE     { return 11; }
    if op == IR_SPAWN         { return 9; }  // call(5) + store(4)
    if op == IR_YIELD         { return 0; }  // no-op (for now)
    if op == IR_CALL_EXTERN    { return 9; }  // call(5) + store(4) = 9 bytes
    if op == IR_HOTPATCH_ROUTE { return 9; }  // call(5) + store(4) = 9 bytes
    if op == IR_FNADDR        { return 14; }  // movabs(10) + store(4) = 14 bytes
    if op == IR_DYN_PACK      { return 16; }  // load_var + st + li (value+tag pack)
    if op == IR_DYN_TAG       { return 8; }   // ld(off+8) + st
    if op == IR_DYN_VAL       { return 8; }   // ld(off+0) + st
    if op == IR_DYN_DISPATCH  { return 40; }  // tag load + cmp/je chain (common case ~35-44B)
    // Unknown / non-annotation opcodes fall back to caller's heuristic (ic*5)
    return 0;
}
