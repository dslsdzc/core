// ══════════════════════════════════════════════════════════════
// Single source of truth for all x86-64 instruction byte sizes.
//
// Every instruction size in the backend comes from here:
//   - instr_size() calls these helpers
//   - Phase 2 prologue/epilogue uses these helpers
//   - emit_instr() returns sizes via e2_* return values (must match)
//
// NEVER hardcode byte counts in elf.cr, instr.cr, or resolve.cr.
// Change a size here → all phases automatically agree.
// ══════════════════════════════════════════════════════════════

// ── Basic encoding sizes (one per e2_* helper in instr.cr) ──
fn sz_mov() -> int { return 3; }
fn sz_ld(o: int) -> int { if o >= -128 && o <= 127 { return 4; } return 7; }
fn sz_st(o: int) -> int { if o >= -128 && o <= 127 { return 4; } return 7; }
fn sz_li(o: int) -> int { if o >= -128 && o <= 127 { return 8; } return 11; }
fn sz_lr() -> int { return 7; }
fn sz_lrb() -> int { return 7; }
fn sz_lb(o: int) -> int { if o >= -128 && o <= 127 { return 4; } return 7; }
fn sz_call() -> int { return 5; }
fn sz_jmp() -> int { return 5; }
fn sz_je() -> int { return 6; }
fn sz_alu() -> int { return 3; }
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

// ── _start size (simple case, no argc/argv globals) ──
fn sz_start_body() -> int { return 4 + 5 + sz_call() + 2 + 5 + sz_syscall(); }
fn sz_start_argv_save() -> int { return sz_lr() + 3; }
