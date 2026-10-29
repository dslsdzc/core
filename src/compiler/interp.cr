// === interp.cr ===
// Dataflow graph interpreter for -c (eval) mode.
// It interprets g_df_nodes (the .cir graph) instead of linear g_ir_instrs (.ccr).
// The dataflow graph preserves type and semantic information during execution.
//
// Limitations:
// - String helpers: the interpreter does not call syscall3; allocation, printing,
//   and syscall helpers return 0.
// - Recursion and cross-function calls: callee graphs run inline through
//   ir_interp_run_fn, including nested and mutual recursion. The depth limit is
//   IR_INTERP_MAX_DEPTH; exceeding it reports an error instead of hanging.
// - Dynamic dispatch, external functions, and binary64 conversions have no
//   interpreter semantics. They report an error and return a non-zero code.
// - The main loop and the callee path share one opcode dispatch in
//   ir_interp_call and ir_interp_run_fn. tests/selfhost/test_interp_parity.py
//   checks both paths against the ELF oracle.

g_ir_vals : string, mut
g_ir_vals_cap : int, mut
g_interp_big : int, mut = 1
g_interp_current_arena_var : int, mut = -1
g_interp_suspend_var : int, mut = -1
g_interp_ready_var : int, mut = -1
g_interp_scalars_var : int, mut = -1
g_interp_arena_active : int, mut = 0
g_interp_scratch : int, mut = 0

// Bool -> int without a bool argument crossing an int boundary. The S1P
// liveness ledger treats `bool` passed to an `int` parameter as a mismatch
// (the liveness probe relies on that), so the interpreter's own comparisons
// materialize 0/1 here.
fn interp_b2i(x: bool) -> int:
    if x:
        return 1
    return 0

fn ir_interp_word(v: int) -> int:
    if g_interp_big != 0:
        return bi_to_word_checked(v)
    return v

fn ir_interp_tag(v: int) -> int:
    if g_interp_big != 0:
        return bi_from_word(v)
    return v

fn ir_interp_const(ti: int, raw: int) -> int:
    if ti == TI_INT:
        return ir_interp_tag(raw)
    return raw

fn ir_interp_find_func(name: string) -> int:
    i : ., mut = 0
    loop:
        if i >= g_ir_func_count:
            break
        if str_eq(istr_get(cell_load(g_ir_func_name_idx, i * 8)), name) != 0:
            return i
        i = i + 1
    return -1

fn ir_interp_global_var(name: string) -> int:
    i : ., mut = 0
    loop:
        if i >= g_ir_global_count:
            break
        if str_eq(istr_get(cell_load(g_ir_globals, i * 24)), name) != 0:
            return cell_load(g_ir_globals, i * 24 + 8)
        i = i + 1
    return -1

fn ir_interp_arena_new(d: int, peak: int):
    if d < 0:
        return
    // s1 == 0 means the scope has no allocations: native stores the no-arena
    // sentinel instead of calling arena_new. Calling it here would recurse
    // through arena infrastructure.
    r : ., mut = ir_interp_tag(-1)
    if peak > 0:
        cfi := ir_interp_find_func("arena_new_sized")
        if cfi >= 0:
            cell_store(g_ir_vals, g_interp_scratch * 8, ir_interp_tag(peak))
            r = ir_interp_run_fn(cfi, g_interp_scratch, 1)
    else if peak < 0:
        cfi := ir_interp_find_func("arena_new")
        if cfi >= 0:
            r = ir_interp_run_fn(cfi, 0, 0)
    cell_store(g_ir_vals, d * 8, r)

fn ir_interp_arena_reset(ai_var: int):
    if ai_var < 0:
        return
    aid := ir_interp_word(cell_load(g_ir_vals, ai_var * 8))
    if aid < 0:
        return
    cfi := ir_interp_find_func("arena_reset")
    if cfi < 0:
        return
    cell_store(g_ir_vals, g_interp_scratch * 8,
               cell_load(g_ir_vals, ai_var * 8))
    ir_interp_run_fn(cfi, g_interp_scratch, 1)

// Call dispatch and inline callee execution. This is the only implementation for
// both the main loop and callee paths.
// Interpreter abort code. 0 means continue; a non-zero value is what ir_interpret
// should return. Errors inside callees propagate up the call stack: a bounds
// failure returns -1, dynamic dispatch or an external call returns 2, and a
// binary64 conversion returns -1.
g_interp_abort : int, mut
// Nested inline depth. A callee that calls another user function enters another
// level. Exceeding IR_INTERP_MAX_DEPTH reports an error instead of hanging.
g_interp_call_depth : int, mut
IR_INTERP_MAX_DEPTH : int = 400
// Active function stack. g_interp_stack[d] is the function index at depth d.
// Re-entry of the same function requires saving and restoring its slot range:
// the flat slot model has one range per function, so an inner call would
// overwrite the outer frame.
g_interp_stack : string, mut

fn ir_interp_binary_raw(d: int, s1: int, s2: int, s3: int):
    if d < 0:
        return
    lv := cell_load(g_ir_vals, s1 * 8)
    rv := cell_load(g_ir_vals, s2 * 8)
    if s3 == 1:
        cell_store(g_ir_vals, d * 8, lv + rv)
    else if s3 == 2:
        cell_store(g_ir_vals, d * 8, lv - rv)
    else if s3 == 3:
        cell_store(g_ir_vals, d * 8, lv * rv)
    else if s3 == 4:
        cell_store(g_ir_vals, d * 8, lv / rv)
    else if s3 == 5:
        cell_store(g_ir_vals, d * 8, lv % rv)
    else if s3 == 6:
        cell_store(g_ir_vals, d * 8, interp_b2i(lv == rv))
    else if s3 == 7:
        cell_store(g_ir_vals, d * 8, interp_b2i(lv != rv))
    else if s3 == 8:
        cell_store(g_ir_vals, d * 8, interp_b2i(lv < rv))
    else if s3 == 9:
        cell_store(g_ir_vals, d * 8, interp_b2i(lv > rv))
    else if s3 == 10:
        cell_store(g_ir_vals, d * 8, interp_b2i(lv <= rv))
    else if s3 == 11:
        cell_store(g_ir_vals, d * 8, interp_b2i(lv >= rv))
    else if s3 == 12:
        cell_store(g_ir_vals, d * 8, interp_b2i(lv != 0 && rv != 0))
    else if s3 == 13:
        cell_store(g_ir_vals, d * 8, interp_b2i(lv != 0 || rv != 0))
    else if s3 == 17:
        cell_store(g_ir_vals, d * 8, lv + interp_ptr_offset(rv))
    else if s3 == 18:
        cell_store(g_ir_vals, d * 8, lv - interp_ptr_offset(rv))
    else if s3 == 19:
        cell_store(g_ir_vals, d * 8, (lv - rv) / interp_ptr_stride())
    else if s3 == 20:
        cell_store(g_ir_vals, d * 8, lv + rv)
    else if s3 == 21:
        cell_store(g_ir_vals, d * 8, lv - rv)
    else if s3 == 22:
        cell_store(g_ir_vals, d * 8, lv + rv)

// Raw shifts for dex-scaled words. The frontend has no shift emitter today,
// but the ELF generic path handles OP_SHL/OP_SHR, so the interpreter must not
// drop them if one appears. SHR is logical on the 64-bit word; negative values
// use the floor correction plus 2^(64-n).
fn ir_interp_shl(v: int, n: int) -> int:
    r : ., mut = v
    i : ., mut = 0
    loop:
        if i >= n:
            break
        r = r * 2
        i = i + 1
    return r

fn ir_interp_shr(v: int, n: int) -> int:
    if n <= 0:
        return v
    q : ., mut = v
    i : ., mut = 0
    loop:
        if i >= n:
            break
        q = q / 2
        i = i + 1
    if v < 0:
        back : ., mut = q
        i = 0
        loop:
            if i >= n:
                break
            back = back * 2
            i = i + 1
        if back != v:
            q = q - 1
        z : ., mut = 1
        i = 0
        loop:
            if i >= 64 - n:
                break
            z = z * 2
            i = i + 1
        q = q + z
    return q

// Shared IR_BINARY dispatch for the main loop and callee loops.
// g_ir_vals int slots hold tagged mathematical integers. Char/bool/dex and
// pointer values remain raw machine words, so the operand variable types select
// the representation. Pointer arithmetic converts its int offset through the
// same checked boundary as the ELF backend.
fn ir_interp_binary(d: int, s1: int, s2: int, s3: int, ti: int):
    if g_interp_big == 0:
        ir_interp_binary_raw(d, s1, s2, s3)
        return
    if d < 0:
        return
    lv := cell_load(g_ir_vals, s1 * 8)
    rv := cell_load(g_ir_vals, s2 * 8)
    if s3 == 17 || s3 == 18 || s3 == 19:
        // Pointer add/sub/diff: the pointer is raw; the offset is mathematical.
        off := ir_interp_word(rv)
        if s3 == 17:
            cell_store(g_ir_vals, d * 8, lv + interp_ptr_offset(off))
        else if s3 == 18:
            cell_store(g_ir_vals, d * 8, lv - interp_ptr_offset(off))
        else:
            cell_store(g_ir_vals, d * 8, ir_interp_tag((lv - rv) / interp_ptr_stride()))
        return
    if s3 == 20 || s3 == 21:
        // Byte buffer arithmetic: untag the offset, no element scaling.
        off := ir_interp_word(rv)
        if s3 == 20:
            cell_store(g_ir_vals, d * 8, lv + off)
        else:
            cell_store(g_ir_vals, d * 8, lv - off)
        return
    if s3 == 22:
        // Raw pointer add: untag both operands, return the raw word.
        cell_store(g_ir_vals, d * 8, ir_interp_word(lv) + ir_interp_word(rv))
        return
    if s3 == 12 || s3 == 13:
        // Boolean and/or store raw 0/1.
        if s3 == 12:
            cell_store(g_ir_vals, d * 8, interp_b2i(lv != 0 && rv != 0))
        else:
            cell_store(g_ir_vals, d * 8, interp_b2i(lv != 0 || rv != 0))
        return

    lhs_char := irv_type(s1) == TI_CHAR
    rhs_char := irv_type(s2) == TI_CHAR
    if lhs_char || rhs_char:
        // Char comparisons are raw. An int operand is still tagged.
        l : ., mut = lv
        r : ., mut = rv
        if !lhs_char && s1 >= 0:
            l = ir_interp_word(lv)
        if !rhs_char && s2 >= 0:
            r = ir_interp_word(rv)
        if s3 == 6:
            cell_store(g_ir_vals, d * 8, interp_b2i(l == r))
        else if s3 == 7:
            cell_store(g_ir_vals, d * 8, interp_b2i(l != r))
        else if s3 == 8:
            cell_store(g_ir_vals, d * 8, interp_b2i(l < r))
        else if s3 == 9:
            cell_store(g_ir_vals, d * 8, interp_b2i(l > r))
        else if s3 == 10:
            cell_store(g_ir_vals, d * 8, interp_b2i(l <= r))
        else if s3 == 11:
            cell_store(g_ir_vals, d * 8, interp_b2i(l >= r))
        return

    lhs_dex := irv_type(s1) == TI_DEX || irv_type(s1) == TI_DEX_S
    rhs_dex := irv_type(s2) == TI_DEX || irv_type(s2) == TI_DEX_S
    if ti == TI_DEX || ti == TI_DEX_S || lhs_dex || rhs_dex:
        // Native IR_BINARY uses the big-int path only when the result and both
        // operands are TI_INT. Dex slots hold raw words (scaled ints for
        // TI_DEX_S, binary64 bits for TI_DEX), and ir_gen inserts the
        // int->scaled conversion before the node. Keep those words raw here and
        // never untag them: dex_scale_int relies on the raw divide by 2 to
        // strip the big-int tag.
        if s3 == 1:
            cell_store(g_ir_vals, d * 8, lv + rv)
        else if s3 == 2:
            cell_store(g_ir_vals, d * 8, lv - rv)
        else if s3 == 3:
            cell_store(g_ir_vals, d * 8, lv * rv)
        else if s3 == 4:
            cell_store(g_ir_vals, d * 8, lv / rv)
        else if s3 == 5:
            cell_store(g_ir_vals, d * 8, lv % rv)
        else if s3 == 6:
            cell_store(g_ir_vals, d * 8, interp_b2i(lv == rv))
        else if s3 == 7:
            cell_store(g_ir_vals, d * 8, interp_b2i(lv != rv))
        else if s3 == 8:
            cell_store(g_ir_vals, d * 8, interp_b2i(lv < rv))
        else if s3 == 9:
            cell_store(g_ir_vals, d * 8, interp_b2i(lv > rv))
        else if s3 == 10:
            cell_store(g_ir_vals, d * 8, interp_b2i(lv <= rv))
        else if s3 == 11:
            cell_store(g_ir_vals, d * 8, interp_b2i(lv >= rv))
        else if s3 == 15:
            cell_store(g_ir_vals, d * 8, ir_interp_shl(lv, rv))
        else if s3 == 16:
            cell_store(g_ir_vals, d * 8, ir_interp_shr(lv, rv))
        return

    if ti == TI_BOOL || irv_type(s1) == TI_BOOL || irv_type(s2) == TI_BOOL:
        // Bool slots are raw 0/1, not big-int tagged. ELF's emit_big_binary is
        // gated on both operands being TI_INT, so the interpreter must also
        // compare these raw instead of calling bi_cmp. `ti` is the result code:
        // a bool-returning comparison can still take int operands (for example
        // the optional-equality `eqi != _cz`).
        if s3 == 6:
            cell_store(g_ir_vals, d * 8, interp_b2i(lv == rv))
        else if s3 == 7:
            cell_store(g_ir_vals, d * 8, interp_b2i(lv != rv))
        else if s3 == 8:
            cell_store(g_ir_vals, d * 8, interp_b2i(lv < rv))
        else if s3 == 9:
            cell_store(g_ir_vals, d * 8, interp_b2i(lv > rv))
        else if s3 == 10:
            cell_store(g_ir_vals, d * 8, interp_b2i(lv <= rv))
        else if s3 == 11:
            cell_store(g_ir_vals, d * 8, interp_b2i(lv >= rv))
        return

    if s3 == 1:
        cell_store(g_ir_vals, d * 8, bi_add(lv, rv))
    else if s3 == 2:
        cell_store(g_ir_vals, d * 8, bi_sub(lv, rv))
    else if s3 == 3:
        cell_store(g_ir_vals, d * 8, bi_mul(lv, rv))
    else if s3 == 4:
        cell_store(g_ir_vals, d * 8, bi_div(lv, rv))
    else if s3 == 5:
        cell_store(g_ir_vals, d * 8, bi_mod(lv, rv))
    else if s3 >= 6 && s3 <= 11:
        c := bi_cmp(lv, rv)
        if s3 == 6:
            cell_store(g_ir_vals, d * 8, interp_b2i(c == 0))
        else if s3 == 7:
            cell_store(g_ir_vals, d * 8, interp_b2i(c != 0))
        else if s3 == 8:
            cell_store(g_ir_vals, d * 8, interp_b2i(c < 0))
        else if s3 == 9:
            cell_store(g_ir_vals, d * 8, interp_b2i(c > 0))
        else if s3 == 10:
            cell_store(g_ir_vals, d * 8, interp_b2i(c <= 0))
        else:
            cell_store(g_ir_vals, d * 8, interp_b2i(c >= 0))

// Pointer read and write.
// A pointer in [0, g_ir_var_count) is a stack slot address produced by REF; read
// or write that slot. Any other value is a heap pointer from alloc or
// ALLOC_ARRAY; read or write memory.
fn ir_interp_deref_read(ptr: int) -> int:
    if ptr >= 0 && ptr < g_ir_var_count:
        return cell_load(g_ir_vals, ptr * 8)
    unsafe:
        return cell_load(@str_of(ptr), 0)
fn ir_interp_deref_write(ptr: int, val: int):
    if ptr >= 0 && ptr < g_ir_var_count:
        cell_store(g_ir_vals, ptr * 8, val)
    else:
        unsafe:
            cell_store(@str_of(ptr), 0, val)

// Interpreter string values are intern-table indices (IR_CONST stores the
// index, while native ELF stores a pointer). Keep string builtins in that same
// representation instead of passing the index to pointer-based helpers.
fn ir_interp_str_concat(a: int, b: int) -> int:
    out : string, mut = ""
    out = out + istr_get(a)
    out = out + istr_get(b)
    return str_intern(out)

fn ir_interp_str_char(a: int, i: int) -> int:
    return str_intern(get_char(istr_get(a), i))

fn ir_interp_str_sub(a: int, start: int, len: int) -> int:
    return str_intern(str_sub(istr_get(a), start, len))

// Dispatch for IR_CALL and IR_SPAWN. d is the result slot, s1 the first argument
// slot, s2 the argument count, and s3 the interned function name. Builtins mirror
// the previous main-loop branches. User functions run inline through
// ir_interp_run_fn; nested calls use the same depth check.
// Interpreter-side string equality over intern indexes. It must not call the
// AOT-compiled `str_eq`: in the interpreter's flat frame model that call crashed
// on interned strings. istr_len/str_load8 are the interpreter's own primitives.
fn ir_interp_str_eq_idx(a: int, b: int) -> int:
    la := istr_len(a)
    lb := istr_len(b)
    if la != lb:
        return 0
    i : ., mut = 0
    loop:
        if i >= la:
            return 1
        if str_load8(a, i) != str_load8(b, i):
            return 0
        i = i + 1
    return 1

// Compare an interned call name by index, not via the AOT str_eq function:
// the latter crashed when the interpreter compared equal interned strings.
fn ir_interp_name_is(fn_ni: int, name: string) -> int:
    if fn_ni < 0:
        return 0
    if fn_ni == str_intern(name):
        return 1
    return 0

fn ir_interp_call(d: int, s1: int, s2: int, s3: int):
    fn_ni := s3
    fn_name := istr_get(fn_ni)
    sfi := find_so_fn(fn_ni)
    if sfi >= 0 && s2 >= 1:
        tf := sym_type(sfi)
          // TAG_VARIADIC: print and println are no-ops; syscall3 returns 0.
           // TAG_AUTO_STR: print_i and println_i are no-ops; syscall3 returns 0.

    // syscall3 and syscall4 return 0 in the interpreter.
    if ir_interp_name_is(fn_ni, "syscall3") != 0 || ir_interp_name_is(fn_ni, "syscall4") != 0 || ir_interp_name_is(fn_ni, "syscall6") != 0:
        if d >= 0:
            cell_store(g_ir_vals, d * 8, 0)
        return
    if ir_interp_name_is(fn_ni, "cell_load") != 0:
        if d >= 0 && s2 >= 2:
            cb := cell_load(g_ir_vals, s1 * 8)
            cp := ir_interp_word(cell_load(g_ir_vals, (s1 + 1) * 8))
            cbs : ., mut = ""
            unsafe:
                cbs = @str_of(cb)
            cell_store(g_ir_vals, d * 8, ir_interp_tag(cell_load(cbs, cp)))
        return
    if ir_interp_name_is(fn_ni, "cell_store") != 0:
        if s2 >= 3:
            cb := cell_load(g_ir_vals, s1 * 8)
            cp := ir_interp_word(cell_load(g_ir_vals, (s1 + 1) * 8))
            cv := ir_interp_word(cell_load(g_ir_vals, (s1 + 2) * 8))
            cbs : ., mut = ""
            unsafe:
                cbs = @str_of(cb)
            cell_store(cbs, cp, cv)
        if d >= 0:
            cell_store(g_ir_vals, d * 8, 0)
        return
    if ir_interp_name_is(fn_ni, "alloc") != 0:
        if d >= 0 && s2 >= 1:
            sz := ir_interp_word(cell_load(g_ir_vals, s1 * 8))
            ca : ., mut = -1
            suspend : ., mut = 0
            ready : ., mut = 0
            scalars_raw : ., mut = 0
            if g_interp_current_arena_var >= 0:
                ca = ir_interp_word(cell_load(g_ir_vals, g_interp_current_arena_var * 8))
            if g_interp_suspend_var >= 0:
                suspend = ir_interp_word(cell_load(g_ir_vals, g_interp_suspend_var * 8))
            if g_interp_ready_var >= 0:
                ready = ir_interp_word(cell_load(g_ir_vals, g_interp_ready_var * 8))
            if g_interp_scalars_var >= 0:
                scalars_raw = cell_load(g_ir_vals, g_interp_scalars_var * 8)
            cfa := ir_interp_find_func("arena_alloc")
            p : ., mut = 0
            if g_interp_arena_active != 0:
                // arena_alloc is already running; its metadata/extent allocs
                // must use the host heap, not recurse into arena_alloc.
                hp := alloc(sz)
                unsafe:
                    p = @ptr_of(hp)
            else if cfa >= 0:
                // The program has an arena body. Its native body rejects
                // negative and >1TB requests before the suspend/current
                // fallback; positive requests go to the global heap when no
                // arena is active.
                if sz < 0 || sz > 1099511627776:
                    println("interpreter error: arena allocation failed (pool limit or invalid size)")
                    g_interp_abort = -1
                else if ca >= 0 && suspend == 0 && ready != 0 && scalars_raw != 0:
                    g_interp_arena_active = 1
                    p = ir_interp_run_fn(cfa, s1, 1)
                    g_interp_arena_active = 0
                    if g_interp_abort == 0 && p == 0:
                        println("interpreter error: arena allocation failed (pool limit or invalid size)")
                        g_interp_abort = -1
                else:
                    hp := alloc(sz)
                    unsafe:
                        p = @ptr_of(hp)
                    if p == 0:
                        println("interpreter error: arena allocation failed (global heap)")
                        g_interp_abort = -1
            else if sz < 0 || sz > 67108864:
                // Native alloc_simple returns 0 for these requests.
                p = 0
            else:
                hp := alloc(sz)
                unsafe:
                    p = @ptr_of(hp)
            if g_interp_abort == 0:
                cell_store(g_ir_vals, d * 8, p)
        return
    if ir_interp_name_is(fn_ni, "load64") != 0:
        if d >= 0 && s2 >= 2:
            b64 := cell_load(g_ir_vals, s1 * 8)
            p64 := ir_interp_word(cell_load(g_ir_vals, (s1 + 1) * 8))
            bs64 : ., mut = ""
            unsafe:
                bs64 = @str_of(b64)
            cell_store(g_ir_vals, d * 8, ir_interp_tag(cell_load(bs64, p64)))
        return
    if ir_interp_name_is(fn_ni, "load_str_ptr") != 0:
        if d >= 0 && s2 >= 2:
            bsp := cell_load(g_ir_vals, s1 * 8)
            psp := ir_interp_word(cell_load(g_ir_vals, (s1 + 1) * 8))
            bs2 : ., mut = ""
            unsafe:
                bs2 = @str_of(bsp)
            cell_store(g_ir_vals, d * 8, cell_load(bs2, psp))
        return
    if ir_interp_name_is(fn_ni, "store_str_ptr") != 0:
        if s2 >= 3:
            bss := cell_load(g_ir_vals, s1 * 8)
            pss := ir_interp_word(cell_load(g_ir_vals, (s1 + 1) * 8))
            vss := cell_load(g_ir_vals, (s1 + 2) * 8)
            bs3 : ., mut = ""
            unsafe:
                bs3 = @str_of(bss)
            cell_store(bs3, pss, vss)
        if d >= 0:
            cell_store(g_ir_vals, d * 8, 0)
        return
    if ir_interp_name_is(fn_ni, "_memzero") != 0 && g_interp_arena_active != 0:
        if s2 >= 2:
            mzb := cell_load(g_ir_vals, s1 * 8)
            mzn := ir_interp_word(cell_load(g_ir_vals, (s1 + 1) * 8))
            mzs : ., mut = ""
            unsafe:
                mzs = @str_of(mzb)
            // Compiled loop: the interpreter's own arena path calls this for
            // every fresh cell block, so per-byte interpretation is too slow.
            mi : ., mut = 0
            loop:
                if mi >= mzn:
                    break
                store8(mzs, mi, 0)
                mi = mi + 1
        if d >= 0:
            cell_store(g_ir_vals, d * 8, 0)
        return
    if ir_interp_name_is(fn_ni, "store8") != 0:
        if s2 >= 3:
            b8 := cell_load(g_ir_vals, s1 * 8)
            p8 := ir_interp_word(cell_load(g_ir_vals, (s1 + 1) * 8))
            v8 := ir_interp_word(cell_load(g_ir_vals, (s1 + 2) * 8))
            sb8 : ., mut = ""
            unsafe:
                sb8 = @str_of(b8)
            store8(sb8, p8, v8)
        if d >= 0:
            cell_store(g_ir_vals, d * 8, 0)
        return
    if ir_interp_name_is(fn_ni, "str_len") != 0:
        if d >= 0 && s2 >= 1:
            cell_store(g_ir_vals, d * 8, ir_interp_tag(istr_len(cell_load(g_ir_vals, s1 * 8))))
    if ir_interp_name_is(fn_ni, "str_eq") != 0:
        if d >= 0 && s2 >= 2:
            // The result is an int: tag it under BigInt mode like every other
            // interpreter-int production.
            cell_store(g_ir_vals, d * 8, ir_interp_tag(ir_interp_str_eq_idx(
                cell_load(g_ir_vals, s1 * 8),
                cell_load(g_ir_vals, (s1 + 1) * 8))))
    if ir_interp_name_is(fn_ni, "concat") != 0:
        if d >= 0 && s2 >= 2:
            cell_store(g_ir_vals, d * 8, ir_interp_str_concat(
                    cell_load(g_ir_vals, s1 * 8), cell_load(g_ir_vals, (s1 + 1) * 8)))
    if ir_interp_name_is(fn_ni, "int_str") != 0:
        if d >= 0 && s2 >= 1:
            if g_interp_big != 0:
                cell_store(g_ir_vals, d * 8, str_intern(bi_to_dec(cell_load(g_ir_vals, s1 * 8))))
            else:
                cell_store(g_ir_vals, d * 8, str_intern(int_str(cell_load(g_ir_vals, s1 * 8))))
    if ir_interp_name_is(fn_ni, "chr") != 0:
        if d >= 0 && s2 >= 1:
            cell_store(g_ir_vals, d * 8, str_intern(chr(ir_interp_word(cell_load(g_ir_vals, s1 * 8)))))
    if ir_interp_name_is(fn_ni, "get_char") != 0:
        if d >= 0 && s2 >= 2:
            cell_store(g_ir_vals, d * 8, ir_interp_str_char(
                cell_load(g_ir_vals, s1 * 8),
                ir_interp_word(cell_load(g_ir_vals, (s1 + 1) * 8))))
    if ir_interp_name_is(fn_ni, "str_sub") != 0:
        if d >= 0 && s2 >= 3:
            cell_store(g_ir_vals, d * 8, ir_interp_str_sub(
                cell_load(g_ir_vals, s1 * 8),
                ir_interp_word(cell_load(g_ir_vals, (s1 + 1) * 8)),
                ir_interp_word(cell_load(g_ir_vals, (s1 + 2) * 8))))
    if ir_interp_name_is(fn_ni, "load8") != 0:
        if d >= 0 && s2 >= 2:
            base8 := cell_load(g_ir_vals, s1 * 8)
            idx8 := ir_interp_word(cell_load(g_ir_vals, s1 + 1 * 8))
            if base8 >= 0 && base8 < g_str_count:
                cell_store(g_ir_vals, d * 8, ir_interp_tag(str_load8(base8, idx8)))
            else:
                bs8 : ., mut = ""
                unsafe:
                    bs8 = @str_of(base8)
                cell_store(g_ir_vals, d * 8, ir_interp_tag(cell_load_byte(bs8, idx8)))
        return
    if x86_frontend_builtin_is_str_ptr_load(fn_name) != 0:
        if d >= 0 && s2 >= 2:
            b := cell_load(g_ir_vals, s1 * 8)
            p := ir_interp_word(cell_load(g_ir_vals, s1 + 1 * 8))
            // `b` is a raw address word; the byte helpers take a string view.
            bs : ., mut = ""
            unsafe:
                bs = @str_of(b)
            lo : ., mut = cell_load_byte(bs, p) + cell_load_byte(bs, p+1)*256 + cell_load_byte(bs, p+2)*65536 + cell_load_byte(bs, p+3)*16777216
            hi : ., mut = cell_load_byte(bs, p+4) + cell_load_byte(bs, p+5)*256 + cell_load_byte(bs, p+6)*65536 + cell_load_byte(bs, p+7)*16777216
            if hi < 0:
                hi = hi + 4294967296
            cell_store(g_ir_vals, d * 8, ir_interp_tag(lo + hi * 4294967296))
    if x86_frontend_builtin_is_str_ptr_store(fn_name) != 0:
        if s2 >= 3:
            b := cell_load(g_ir_vals, s1 * 8)
            p := ir_interp_word(cell_load(g_ir_vals, s1 + 1 * 8))
            v := ir_interp_word(cell_load(g_ir_vals, s1 + 2 * 8))
            // `b` is a raw address word; the byte helpers take a string view.
            bs : ., mut = ""
            unsafe:
                bs = @str_of(b)
            lo : ., mut = v % 4294967296
            hi : ., mut = v / 4294967296
            if v < 0:
                lo = v
                hi = -1
            cell_store_byte(bs, p, lo%256)
            cell_store_byte(bs, p+1, (lo/256)%256)
            cell_store_byte(bs, p+2, (lo/65536)%256)
            cell_store_byte(bs, p+3, (lo/16777216)%256)
            cell_store_byte(bs, p+4, hi%256)
            cell_store_byte(bs, p+5, (hi/256)%256)
            cell_store_byte(bs, p+6, (hi/65536)%256)
            cell_store_byte(bs, p+7, (hi/16777216)%256)
        if d >= 0:
            cell_store(g_ir_vals, d * 8, 0)
    // String builtins are handled; do not fall through to the user-function lookup.
    if ir_interp_name_is(fn_ni, "str_len") != 0 || ir_interp_name_is(fn_ni, "str_eq") != 0 || ir_interp_name_is(fn_ni, "concat") != 0 || ir_interp_name_is(fn_ni, "int_str") != 0 || ir_interp_name_is(fn_ni, "chr") != 0 || ir_interp_name_is(fn_ni, "get_char") != 0 || ir_interp_name_is(fn_ni, "str_sub") != 0:
        return
    // 用户函数内联执行（单层 / 嵌套递归）
    if d < 0:
        return
    cfi : ., mut = 0
    loop:
        if cfi >= g_ir_func_count:
            break
        if cell_load(g_ir_func_name_idx, cfi * 8) == fn_ni:
            f_start := cell_load(g_df_func_node_start, cfi * 8)
            f_count := cell_load(g_df_func_node_count, cfi * 8)
            if f_start >= 0 && f_count > 0:
                rval : ., mut = ir_interp_run_fn(cfi, s1, s2)
                if g_interp_abort == 0:
                    cell_store(g_ir_vals, d * 8, rval)
            break
        cfi = cfi + 1

// v10 MATCH dispatch. Returns the NOD id of the selected CASE target, or -1
// when the table has no default and no value matched. The runtime forms follow
// the existing IR ops: enum scrutinees are pointers whose tag word is the
// variant-name index; int scrutinees are tagged when big-int mode is on; bool
// scrutinees stay raw.
fn interp_match_target(scrutinee: int, scrutinee_ti: int, case_start: int, case_count: int) -> int:
    if scrutinee < 0 || case_start < 0 || case_count < 0:
        return -1
    cv := cell_load(g_ir_vals, scrutinee * 8)
    default_t : ., mut = -1
    ci : ., mut = 0
    loop:
        if ci >= case_count:
            break
        base := (case_start + ci) * CCR_V10_CASE_DISK
        kind := cell_load32(g_ccr_case, base + CCR_CASE_KIND)
        val := cell_load(g_ccr_case, base + CCR_CASE_VALUE)
        target := cell_load_i32(g_ccr_case, base + CCR_CASE_TARGET)
        if kind == CCR_CASE_KIND_DEFAULT:
            default_t = target
        else if kind == CCR_CASE_KIND_ENUM:
            tag : ., mut = 0
            if cv != 0:
                unsafe:
                    tag = cell_load(@str_of(cv), 0)
            if g_interp_big != 0:
                if ir_interp_tag(tag) == ir_interp_tag(val):
                    return target
            else:
                if tag == val:
                    return target
        else:
            rv : ., mut = val
            if g_interp_big != 0 && scrutinee_ti == TI_INT:
                rv = ir_interp_tag(val)
            if cv == rv:
                return target
        ci = ci + 1
    return default_t

// Inline execution of a callee graph. Both the main loop and nested callees use
// this function. It builds the label table, copies arguments, executes f_count
// nodes, restores the label table, and returns the IR_RETURN value. A function
// with no return value returns 0.
// Depth check: exceeding IR_INTERP_MAX_DEPTH reports an error and aborts.
fn ir_interp_run_fn(cfi: int, arg_base: int, argc: int) -> int:
    f_start := cell_load(g_df_func_node_start, cfi * 8)
    f_count := cell_load(g_df_func_node_count, cfi * 8)
    if f_start < 0 || f_count <= 0:
        return 0
    if g_interp_call_depth >= IR_INTERP_MAX_DEPTH:
        println("interpreter error: IR_INTERP_MAX_DEPTH exceeded — corec run cannot execute this recursion; build & run natively (corec build) instead")
        g_interp_abort = -1
        return 0
    // Re-entry detection for recursion and mutual recursion. If this function is
    // already active, it shares one slot range with the outer frame in the flat
    // slot model. Save the range on entry and restore it on exit.
    reentrant : ., mut = 0
    si3 : ., mut = 0
    loop:
        if si3 >= g_interp_call_depth:
            break
        if cell_load(g_interp_stack, si3 * 8) == cfi:
            reentrant = 1
            break
        si3 = si3 + 1
    vs := cell_load(g_ir_func_var_start, cfi * 8)
    vc := cell_load(g_ir_func_var_count, cfi * 8)
    frame : string, mut = ""
    has_frame : ., mut = 0
    if reentrant != 0 && vc > 0 && vs >= 0:
        frame = alloc(vc * 8)
        has_frame = 1
        fi4 : ., mut = 0
        loop:
            if fi4 >= vc:
                break
            cell_store(frame, fi4 * 8, cell_load(g_ir_vals, (vs + fi4) * 8))
            fi4 = fi4 + 1
    // Copy arguments to a buffer before writing parameter slots. In a recursive
    // call the argument and parameter slots belong to the same function range, so
    // a direct copy could overwrite an argument that has not been read yet.
    args_buf : string, mut = ""
    if argc > 0:
        args_buf = alloc(argc * 8)
        pai : ., mut = 0
        loop:
            if pai >= argc:
                break
            cell_store(args_buf, pai * 8, cell_load(g_ir_vals, (arg_base + pai) * 8))
            pai = pai + 1
    // Push the frame. Re-entry detection and the depth check already ran.
    cell_store(g_interp_stack, g_interp_call_depth * 8, cfi)
    g_interp_call_depth = g_interp_call_depth + 1
    rval : ., mut = 0  // a callee with no value (IR_RETURN s1 < 0) returns 0
    // Save label state in locals so each recursion level restores its own state.
    old_lc := g_label_count
    old_poses := g_label_poses
    old_poses_cap := g_label_cap
    g_label_poses = alloc(64 * 8)
    g_label_cap = 64
    // Build label map for callee
    li2 : ., mut = 0
    loop:
        if li2 >= f_count:
            break
        n_op := cell_load(g_df_nodes, (f_start + li2) * ESZ_DFNODE + OFF_DF_OPCODE)
        n_s1 := cell_load(g_df_nodes, (f_start + li2) * ESZ_DFNODE + OFF_DF_S1)
        if n_op == 21:
            if n_s1 >= 0:
                grow_label_poses(n_s1 + 1)
                cell_store(g_label_poses, n_s1 * 8, li2)
                if n_s1 + 1 > g_label_count:
                    g_label_count = n_s1 + 1
        li2 = li2 + 1
    // Copy args from buffer to callee param vars
    pstart := vs
    pai2 : ., mut = 0
    loop:
        if pai2 >= argc:
            break
        cell_store(g_ir_vals, (pstart + pai2) * 8, cell_load(args_buf, pai2 * 8))
        pai2 = pai2 + 1
    // Execute callee graph (inline)
    ip2 : ., mut = 0
    loop:
        if ip2 >= f_count:
            break
        if g_interp_abort != 0:
            break
        op2 := cell_load(g_df_nodes, (f_start + ip2) * ESZ_DFNODE + OFF_DF_OPCODE)
        d2 := cell_load(g_df_nodes, (f_start + ip2) * ESZ_DFNODE + OFF_DF_DEST)
        t1 := cell_load(g_df_nodes, (f_start + ip2) * ESZ_DFNODE + OFF_DF_S1)
        t2 := cell_load(g_df_nodes, (f_start + ip2) * ESZ_DFNODE + OFF_DF_S2)
        t3 := cell_load(g_df_nodes, (f_start + ip2) * ESZ_DFNODE + OFF_DF_S3)
        // Derived code, not a slot. After the single-slot change, slot 40 holds a
        // type-term reference. ir_interp_binary does not consume this argument
        // today; the operation code in s3 selects the operation.
        t4 := sh_dfn_code_of_slots(cell_load(g_df_nodes, (f_start + ip2) * ESZ_DFNODE + OFF_DF_TK),
            cell_load(g_df_nodes, (f_start + ip2) * ESZ_DFNODE + OFF_DF_AUX))
        if op2 == 1 && d2 >= 0:
            cell_store(g_ir_vals, d2 * 8, ir_interp_const(t4, t1))
        if op2 == 40 && d2 >= 0 && t1 >= 0:
            cell_store(g_ir_vals, d2 * 8, bi_from_dec(istr_get(t1)))
        if op2 == 2 && t1 >= 0 && t2 >= 0:
            ir_interp_binary(d2, t1, t2, t3, t4)
        if op2 == 49 || op2 == 50:
            println("interpreter error: IR_I2F/IR_F2I needs binary64 semantics (apx dex) — `corec run` cannot execute apx dex arithmetic; build & run natively (corec build) instead")
            g_interp_abort = -1
            break
        if op2 == 3 && t1 >= 0:
            ov2 := cell_load(g_ir_vals, t1 * 8)
            if t3 == 1:
                if g_interp_big != 0 && irv_type(t1) == TI_INT:
                    cell_store(g_ir_vals, d2 * 8, bi_neg(ov2))
                else:
                    cell_store(g_ir_vals, d2 * 8, -ov2)
            else if t3 == 2:
                if ov2 == 0:
                    cell_store(g_ir_vals, d2 * 8, 1)
                else:
                    cell_store(g_ir_vals, d2 * 8, 0)
        // Keep callee locals in the shared value store. Skipping these opcodes
        // would leave loop-carried assignments unchanged.
        if op2 == 6 && d2 >= 0:
            cell_store(g_ir_vals, d2 * 8, 0)
        // IR_STORE
        if op2 == 9 && t1 >= 0 && t2 >= 0:
            v2 : ., mut = cell_load(g_ir_vals, t2 * 8)
            if g_interp_big != 0 && irv_type(t1) == TI_INT && (irv_type(t2) == TI_DEX_S || irv_type(t2) == TI_CHAR || irv_type(t2) == TI_BOOL || get_type_kind(irv_type(t2)) == TYP_REF || get_type_kind(irv_type(t2)) == TYP_PTR):
                v2 = ir_interp_tag(v2)
            if g_interp_big != 0 && irv_type(t1) == TI_CHAR && irv_type(t2) == TI_INT:
                v2 = ir_interp_word(v2)
            cell_store(g_ir_vals, t1 * 8, v2)
        // IR_LOAD
        if op2 == 10 && d2 >= 0 && t1 >= 0:
            v2 : ., mut = cell_load(g_ir_vals, t1 * 8)
            if g_interp_big != 0 && irv_type(d2) == TI_INT && (irv_type(t1) == TI_CHAR || irv_type(t1) == TI_BOOL || get_type_kind(irv_type(t1)) == TYP_REF || get_type_kind(irv_type(t1)) == TYP_PTR):
                v2 = ir_interp_tag(v2)
            if g_interp_big != 0 && irv_type(d2) == TI_CHAR && irv_type(t1) == TI_INT:
                v2 = ir_interp_word(v2)
            cell_store(g_ir_vals, d2 * 8, v2)
        // Aggregate operations: ALLOC_ARRAY, ALLOC_STRUCT, LOAD_INDEX,
        // STORE_INDEX, LOAD_FIELD, STORE_FIELD, and ADDR_INDEX. The callee path
        // must implement them too, or an aggregate global read inside a callee
        // would return 0 while the main path works.
        if op2 == 8 && d2 >= 0:
            // IR_ALLOC_ARRAY. The element stride is a target fact; the wire no
            // longer carries it, so an absent s2 asks the target hook. The
            // trailing slot reserves the same target-sized header word.
            cnt2 := t1
            esz2 : ., mut = t2
            if esz2 <= 0:
                esz2 = interp_ptr_stride()
            need3 := cnt2 * esz2 + interp_ptr_stride()
            bp2 := alloc(need3)
            vi3 : ., mut = 0
            loop:
                if vi3 >= need3:
                    break
                cell_store_byte(bp2, vi3, 0)
                vi3 = vi3 + 1
            unsafe:
                cell_store(g_ir_vals, d2 * 8, @ptr_of(bp2))
        if op2 == 13 && d2 >= 0 && t1 >= 0:
            // IR_LOAD_INDEX: t1=arr_var, t3=literal_idx
            av2 := cell_load(g_ir_vals, t1 * 8)
            if irv_type(t1) == TI_STR:
                cell_store(g_ir_vals, d2 * 8, str_load8(av2, t3))
            else:
                unsafe:
                    cell_store(g_ir_vals, d2 * 8, cell_load(@str_of(av2), t3 * interp_ptr_stride()))
        if op2 == 14 && t1 >= 0 && t2 >= 0:
            // IR_STORE_INDEX: t1=arr_var, t2=val_var
            av2 := cell_load(g_ir_vals, t1 * 8)
            if irv_type(t1) == TI_STR:
                cell_store_byte(istr_get(av2), t3, cell_load(g_ir_vals, t2 * 8))
            else:
                unsafe:
                    cell_store(@str_of(av2), t3 * interp_ptr_stride(), cell_load(g_ir_vals, t2 * 8))
        if op2 == 15 && d2 >= 0 && t1 >= 0 && t2 >= 0:
            // IR_LOAD_INDEX_VAR: t1=arr_var, t2=idx_var
            av2 := cell_load(g_ir_vals, t1 * 8)
            ix2 := ir_interp_word(cell_load(g_ir_vals, t2 * 8))
            if irv_type(t1) == TI_STR:
                cell_store(g_ir_vals, d2 * 8, str_load8(av2, ix2))
            else:
                unsafe:
                    cell_store(g_ir_vals, d2 * 8, cell_load(@str_of(av2), ix2 * interp_ptr_stride()))
        if op2 == 16 && d2 >= 0 && t1 >= 0 && t2 >= 0:
            // IR_STORE_INDEX_VAR: d2=val_var, t1=arr_var, t2=idx_var
            av2 := cell_load(g_ir_vals, t1 * 8)
            ix2 := ir_interp_word(cell_load(g_ir_vals, t2 * 8))
            if irv_type(t1) == TI_STR:
                cell_store_byte(istr_get(av2), ix2, cell_load(g_ir_vals, d2 * 8))
            else:
                unsafe:
                    cell_store(@str_of(av2), ix2 * interp_ptr_stride(), cell_load(g_ir_vals, d2 * 8))
        if op2 == 31 && d2 >= 0 && t1 >= 0 && t2 >= 0:
            // IR_ADDR_INDEX: &arr[i]. The element scale is a target fact.
            cell_store(g_ir_vals, d2 * 8, cell_load(g_ir_vals, t1 * 8) + ir_interp_word(cell_load(g_ir_vals, t2 * 8)) * interp_ptr_stride())
        if op2 == 11 && d2 >= 0 && t1 >= 0:
            // IR_LOAD_FIELD: t1=struct_var, t3=field_idx. Field offsets use the
            // target field stride, not an inlined x86 constant.
            pf2 := cell_load(g_ir_vals, t1 * 8)
            if pf2 != 0:
                unsafe:
                    cell_store(g_ir_vals, d2 * 8, cell_load(@str_of(pf2), t3 * interp_field_stride()))
            else:
                cell_store(g_ir_vals, d2 * 8, cell_load(g_ir_vals, t1 * 8))
        if op2 == 12 && t1 >= 0 && t2 >= 0:
            // IR_STORE_FIELD: t1=struct_var, t2=val_var, t3=field_idx
            pf2 := cell_load(g_ir_vals, t1 * 8)
            if pf2 != 0:
                unsafe:
                    cell_store(@str_of(pf2), t3 * interp_field_stride(), cell_load(g_ir_vals, t2 * 8))
            else:
                cell_store(g_ir_vals, t1 * 8, cell_load(g_ir_vals, t2 * 8))
        if op2 == 7 && d2 >= 0:
            // IR_ALLOC_STRUCT. Fields are target-stride spaced; the trailing
            // word is the enum/tag header slot.
            si2 := find_struct(t3)
            fc2 : ., mut = 0
            if si2 >= 0:
                fc2 = si_field_count(si2)
            need3 := fc2 * interp_field_stride() + interp_ptr_stride()
            bp2 := alloc(need3)
            vi3 : ., mut = 0
            loop:
                if vi3 >= need3:
                    break
                cell_store_byte(bp2, vi3, 0)
                vi3 = vi3 + 1
            unsafe:
                cell_store(g_ir_vals, d2 * 8, @ptr_of(bp2))
        if op2 == 32:
            ir_interp_arena_new(d2, t1)
        if op2 == 33:
            ir_interp_arena_reset(t1)
        if op2 == 46 || op2 == 47:
            if d2 >= 0 && t1 >= 0:
                cell_store(g_ir_vals, d2 * 8, cell_load(g_ir_vals, t1 * 8))
        // The following opcode families mirror the main loop.
        // IR_MAKE_ENUM: allocate one tag slot plus s2 payload fields and store s1
        // (the variant-name index) in the first word. This matches the ELF layout
        // [tag][payload]; IR_STORE_FIELD writes the payload.
        if op2 == 17:
            if d2 >= 0:
                need3 := interp_ptr_stride() + t2 * interp_field_stride()
                bp2 := alloc(need3)
                vi3 : ., mut = 0
                loop:
                    if vi3 >= need3:
                        break
                    cell_store_byte(bp2, vi3, 0)
                    vi3 = vi3 + 1
                cell_store(bp2, 0, t1)
                unsafe:
                    cell_store(g_ir_vals, d2 * 8, @ptr_of(bp2))
        // IR_LOAD_ENUM_TAG: d = tag word at the pointer in slot s1.
        if op2 == 23:
            if d2 >= 0 && t1 >= 0:
                p23 := cell_load(g_ir_vals, t1 * 8)
                if p23 != 0:
                    unsafe:
                        cell_store(g_ir_vals, d2 * 8, ir_interp_tag(cell_load(@str_of(p23), 0)))
        // IR_REF: d = s1. The slot number is the stack address used by the deref helpers.
        if op2 == 18:
            if d2 >= 0 && t1 >= 0:
                cell_store(g_ir_vals, d2 * 8, t1)
        // IR_DEREF: read through the pointer in slot s1.
        if op2 == 25:
            if d2 >= 0 && t1 >= 0:
                cell_store(g_ir_vals, d2 * 8, ir_interp_deref_read(cell_load(g_ir_vals, t1 * 8)))
        // IR_SLICE: d = arr + low elements, matching the ELF encoding. The
        // element scale comes from the target hook.
        if op2 == 24:
            if d2 >= 0 && t1 >= 0 && t2 >= 0:
                cell_store(g_ir_vals, d2 * 8, cell_load(g_ir_vals, t1 * 8) + ir_interp_word(cell_load(g_ir_vals, t2 * 8)) * interp_ptr_stride())
        // IR_BOUNDS_CHECK: s1 is the index variable and s2 the limit. A dynamic
        // limit uses ti = 1. An index below 0 or at least the limit aborts with -1.
        if op2 == 30 && t2 >= 0:
            iv30 := ir_interp_word(cell_load(g_ir_vals, t1 * 8))
            lim30 : ., mut = t2
            if t4 == 1:
                lim30 = ir_interp_word(cell_load(g_ir_vals, t2 * 8))
            if iv30 < 0 || iv30 >= lim30:
                g_interp_abort = -1
                break
        // IR_STORE_PTR: write the value in slot s2 through the pointer in slot s1.
        if op2 == 26:
            if t1 >= 0 && t2 >= 0:
                ir_interp_deref_write(cell_load(g_ir_vals, t1 * 8), cell_load(g_ir_vals, t2 * 8))
        // IR_YIELD: pass the value in slot s1 eagerly, like IR_AWAIT.
        if op2 == 28:
            if d2 >= 0 && t1 >= 0:
                cell_store(g_ir_vals, d2 * 8, cell_load(g_ir_vals, t1 * 8))
        // IR_AWAIT. (29)
        if op2 == 29:
            if d2 >= 0:
                cell_store(g_ir_vals, d2 * 8, cell_load(g_ir_vals, t1 * 8))
        // IR_PTR_OF / IR_STR_OF: raw address <-> mathematical int view.
        if op2 == 52:
            if d2 >= 0 && t1 >= 0:
                if g_interp_big != 0:
                    cell_store(g_ir_vals, d2 * 8, bi_from_uword(cell_load(g_ir_vals, t1 * 8)))
                else:
                    cell_store(g_ir_vals, d2 * 8, cell_load(g_ir_vals, t1 * 8))
        if op2 == 53:
            if d2 >= 0 && t1 >= 0:
                if g_interp_big != 0:
                    cell_store(g_ir_vals, d2 * 8, bi_to_uword_checked(cell_load(g_ir_vals, t1 * 8)))
                else:
                    cell_store(g_ir_vals, d2 * 8, cell_load(g_ir_vals, t1 * 8))
        // IR_FNADDR: no real addresses in the interpreter; store 0.
        if op2 == 48:
            if d2 >= 0:
                cell_store(g_ir_vals, d2 * 8, 0)
        // IR_APPROX is a pure annotation; skip it.

        // IR_DYN_PACK: a dyn value uses two slots, value at d and tag at d+1.
        if op2 == 43:
            if d2 >= 0 && t1 >= 0:
                cell_store(g_ir_vals, d2 * 8, cell_load(g_ir_vals, t1 * 8))
                cell_store(g_ir_vals, (d2 + 1) * 8, t2)
        // IR_DYN_TAG: d = tag at slot s1 + 1.
        if op2 == 41:
            if d2 >= 0 && t1 >= 0:
                cell_store(g_ir_vals, d2 * 8, cell_load(g_ir_vals, (t1 + 1) * 8))
        // IR_DYN_VAL: d = value at slot s1.
        if op2 == 42:
            if d2 >= 0 && t1 >= 0:
                cell_store(g_ir_vals, d2 * 8, cell_load(g_ir_vals, t1 * 8))
        // IR_DYN_DISPATCH has no interpreter implementation; report an error.
        if op2 == 44:
            println("error: interp 不支持动态分发（IR_DYN_DISPATCH）")
            g_interp_abort = 2
            break
        // IR_CALL_EXTERN has no interpreter implementation; report an error.
        if op2 == 45:
            print("error: interp 无法调用外部函数：")
            println(istr_get(t1))
            g_interp_abort = 2
            break
        // Fixed-address placement is an ELF/deployment fact; the interpreter
        // must not fake a host pointer and silently read/write process memory.
        if op2 == 55:
            println("error: interp 不支持固定地址放置（IR_ALLOC_AT）")
            g_interp_abort = 2
            break
        // IR_CALL and IR_SPAWN use the shared dispatch for builtins and inline calls.
        if op2 == 4 || op2 == 27:
            ir_interp_call(d2, t1, t2, t3)
        if op2 == 5:
            if t1 >= 0:
                rval = cell_load(g_ir_vals, t1 * 8)
            ip2 = f_count  // return exits the callee immediately
        // IR_RETURN
        if op2 == 19 && t1 >= 0:
            cv2 := cell_load(g_ir_vals, t1 * 8)
            if cv2 != 0:
                if t2 >= 0 && t2 < g_label_count:
                    ip2 = cell_load(g_label_poses, t2 * 8)
            else:
                if t3 >= 0 && t3 < g_label_count:
                    ip2 = cell_load(g_label_poses, t3 * 8)
        if op2 == 20:
            if t1 >= 0 && t1 < g_label_count:
                ip2 = cell_load(g_label_poses, t1 * 8)
        // v10 IR_MATCH: dispatch on the scrutinee and jump to the CASE target.
        // The callee loop increments ip2 at the bottom, so point one before the
        // target NOD (the target is itself a LABEL node). A miss with no
        // DEFAULT and an out-of-span target both trap.
        if op2 == 54:
            mt2 := interp_match_target(t1, irv_type(t1), t2, t3)
            if mt2 < 0:
                g_interp_abort = -1
                ip2 = f_count
            else if mt2 >= f_start && mt2 < f_start + f_count:
                ip2 = mt2 - f_start - 1
            else:
                g_interp_abort = -1
                ip2 = f_count
        ip2 = ip2 + 1
    // Restore label state
    g_label_count = old_lc
    g_label_poses = old_poses
    g_label_cap = old_poses_cap
    // Restore the outer frame after a re-entrant call. The return value travels in
    // the local rval, not in this slot range, so restoring does not lose it.
    if has_frame != 0:
        fi5 : ., mut = 0
        loop:
            if fi5 >= vc:
                break
            cell_store(g_ir_vals, (vs + fi5) * 8, cell_load(frame, fi5 * 8))
            fi5 = fi5 + 1
    g_interp_call_depth = g_interp_call_depth - 1
    if g_interp_abort != 0:
        return 0
    return rval

fn ir_interpret() -> int:
    // Find main function in the dataflow graph
    main_idx : ., mut = -1
    fi : ., mut = 0
    loop:
        if fi >= g_ir_func_count:
            break
        ni := cell_load(g_ir_func_name_idx, fi * 8)
        if str_eq(istr_get(ni), "main") != 0:
            main_idx = fi
            break
        fi = fi + 1
    if main_idx < 0:
        return -1
    node_start := cell_load(g_df_func_node_start, main_idx * 8)
    node_count := cell_load(g_df_func_node_count, main_idx * 8)
    if node_start < 0 || node_count <= 0:
        return -1

    // Reset interpreter state so ir_interpret can run more than once in one
    // process. Callee results travel through ir_interp_run_fn's local return
    // value instead of a shared temporary slot.
    g_interp_abort = 0
    g_interp_call_depth = 0
    g_interp_big = 1
    if g_ccr_emit_raw_int != 0:
        g_interp_big = 0
    g_interp_stack = alloc(IR_INTERP_MAX_DEPTH * 8)  // 活动函数栈（重入检测）

    // Initialize value store (size = node_count + padding for destinations)
    need := g_ir_var_count + 64
    if g_ir_vals_cap < need:
        g_ir_vals = alloc(need * 8)
        g_ir_vals_cap = need
    vi : ., mut = 0
    loop:
        if vi >= need:
            break
        cell_store(g_ir_vals, vi * 8, 0)
        vi = vi + 1

    // Initialize compile-time scalar globals. This mirrors the constant loop in
    // the ELF entry path and uses the same g_ir_globals rows. Aggregates and
    // globals with run-time initializers are injected as IR at the start of main
    // by ir_gen inject_global_inits and executed by the main loop.
    gi2 : ., mut = 0
    loop:
        if gi2 >= g_ir_global_count:
            break
        iv2 : ., mut = cell_load(g_ir_globals, gi2 * 24 + 16)
        gv2 := cell_load(g_ir_globals, gi2 * 24 + 8)
        if iv2 != 0 && gv2 >= 0 && gv2 < need:
            // Match the ELF entry: int globals hold tagged values in big-int mode.
            if g_interp_big != 0 && irv_type(gv2) == TI_INT:
                iv2 = ir_interp_tag(iv2)
            cell_store(g_ir_vals, gv2 * 8, iv2)
        gi2 = gi2 + 1

    // Arena dispatch state: the global var slot and a scratch slot beyond the
    // program's var range. Both are reused by IR_ARENA_NEW/RESET and alloc().
    g_interp_scratch = g_ir_var_count
    g_interp_current_arena_var = ir_interp_global_var("g_current_arena")
    g_interp_suspend_var = ir_interp_global_var("g_arena_suspend")
    g_interp_ready_var = ir_interp_global_var("g_arena_scalars_ready")
    g_interp_scalars_var = ir_interp_global_var("g_arena_scalars")
    g_interp_arena_active = 0
    if g_interp_current_arena_var >= 0:
        // The ELF entry initializes this runtime global to -1 regardless of
        // the source initializer. Mirror it before the first alloc().
        cell_store(g_ir_vals, g_interp_current_arena_var * 8, ir_interp_tag(-1))

    // Pre-scan: build the label-to-node mapping for branches.
    g_label_count = 0
    li : ., mut = 0
    loop:
        if li >= node_count:
            break
        n_op := cell_load(g_df_nodes, (node_start + li) * ESZ_DFNODE + OFF_DF_OPCODE)
        n_s1 := cell_load(g_df_nodes, (node_start + li) * ESZ_DFNODE + OFF_DF_S1)
        if n_op == 21:
            // IR_LABEL
            ln := n_s1  // label number
            if ln >= 0:
                grow_label_poses(ln + 1)
                cell_store(g_label_poses, ln * 8, li)
                if ln + 1 > g_label_count:
                    g_label_count = ln + 1
        li = li + 1

    // Pre-scan SG_LOOP and SG_FOR region enter and exit offsets for the main
    // function graph.
    g_loop_region_count = 0
    li = 0
    loop:
        if li >= g_sg_count:
            break
        lk := cell_load(g_sgs, li * ESZ_SG + OFF_SG_KIND)
        if lk == SG_LOOP || lk == SG_FOR:
            l_enter := cell_load(g_sgs, li * ESZ_SG + OFF_SG_ENTER)
            l_exit  := cell_load(g_sgs, li * ESZ_SG + OFF_SG_EXIT)
            if l_enter >= node_start && l_enter < node_start + node_count:
                if g_loop_region_count + 1 > g_loop_region_cap:
                    // Grow both arrays using the old capacity. Copying with the new
                    // capacity would over-read the previous buffer.
                    nc : ., mut = g_loop_region_cap * 2
                    if nc < 16:
                        nc = 16
                    nb := alloc(nc * 8)
                    cell_copy(g_loop_region_enter, g_loop_region_cap * 8, nb)
                    nb2 := alloc(nc * 8)
                    cell_copy(g_loop_region_exit, g_loop_region_cap * 8, nb2)
                    g_loop_region_enter = nb
                    g_loop_region_exit = nb2
                    g_loop_region_cap = nc
                cell_store(g_loop_region_enter, g_loop_region_count * 8, l_enter - node_start)
                cell_store(g_loop_region_exit,  g_loop_region_count * 8, l_exit  - node_start)
                g_loop_region_count = g_loop_region_count + 1
        li = li + 1

    // Execute nodes in order (dataflow: sequential order = valid topological order for straight-line)
    ip : ., mut = 0
    loop:
        if ip >= node_count:
            break
        op := cell_load(g_df_nodes, (node_start + ip) * ESZ_DFNODE + OFF_DF_OPCODE)
        d := cell_load(g_df_nodes, (node_start + ip) * ESZ_DFNODE + OFF_DF_DEST)
        s1 := cell_load(g_df_nodes, (node_start + ip) * ESZ_DFNODE + OFF_DF_S1)
        s2 := cell_load(g_df_nodes, (node_start + ip) * ESZ_DFNODE + OFF_DF_S2)
        s3 := cell_load(g_df_nodes, (node_start + ip) * ESZ_DFNODE + OFF_DF_S3)
        // Derived code as above; passed to IR_BINARY and currently unused.
        ti := sh_dfn_code_of_slots(cell_load(g_df_nodes, (node_start + ip) * ESZ_DFNODE + OFF_DF_TK),
            cell_load(g_df_nodes, (node_start + ip) * ESZ_DFNODE + OFF_DF_AUX))

        if op == 1:
            if d >= 0:
                cell_store(g_ir_vals, d * 8, ir_interp_const(ti, s1))
        // IR_CONST; dex uses a scaled integer in s1.
        if op == 40:
            if d >= 0 && s1 >= 0:
                cell_store(g_ir_vals, d * 8, bi_from_dec(istr_get(s1)))
        // IR_CONST_BIG
        if op == 5:
            if s1 >= 0:
                return ir_interp_word(cell_load(g_ir_vals, s1 * 8))
            return 0
        // IR_RETURN

        if op == 2:
            ir_interp_binary(d, s1, s2, s3, ti)
        // IR_BINARY

        if op == 3:
            // IR_UNARY
            ov := cell_load(g_ir_vals, s1 * 8)
            if s3 == 1:
                if g_interp_big != 0 && irv_type(s1) == TI_INT:
                    cell_store(g_ir_vals, d * 8, bi_neg(ov))
                else:
                    cell_store(g_ir_vals, d * 8, -ov)
            if s3 == 2:
                if ov == 0:
                    cell_store(g_ir_vals, d * 8, 1)
                else:
                    cell_store(g_ir_vals, d * 8, 0)

        // Alloc / Store / Load / Field / Index
        if op == 6:
            if d >= 0:
                cell_store(g_ir_vals, d * 8, 0)
        // IR_ALLOC
        if op == 7:
            // IR_ALLOC_STRUCT. Fields use the target field stride; the trailing
            // word is the tag/header slot.
            if d >= 0:
                si := find_struct(s3)
                fc : ., mut = 0
                if si >= 0:
                    fc = si_field_count(si)
                need2 := fc * interp_field_stride() + interp_ptr_stride()
                bp := alloc(need2)
                vi2 : ., mut = 0
                loop:
                    if vi2 >= need2:
                        break
                    cell_store_byte(bp, vi2, 0)
                    vi2 = vi2 + 1
                unsafe:
                    cell_store(g_ir_vals, d * 8, @ptr_of(bp))
        if op == 8:
            // IR_ALLOC_ARRAY. s2 is zero on the wire; the element scale is
            // asked from the target hook.
            if d >= 0:
                cnt := s1
                esz : ., mut = s2
                if esz <= 0:
                    esz = interp_ptr_stride()
                need2 := cnt * esz + interp_ptr_stride()
                bp := alloc(need2)
                vi2 : ., mut = 0
                loop:
                    if vi2 >= need2:
                        break
                    cell_store_byte(bp, vi2, 0)
                    vi2 = vi2 + 1
                unsafe:
                    cell_store(g_ir_vals, d * 8, @ptr_of(bp))
        if op == 9:
            if s1 >= 0 && s2 >= 0:
                v : ., mut = cell_load(g_ir_vals, s2 * 8)
                if g_interp_big != 0 && irv_type(s1) == TI_INT && (irv_type(s2) == TI_DEX_S || irv_type(s2) == TI_CHAR || irv_type(s2) == TI_BOOL || get_type_kind(irv_type(s2)) == TYP_REF || get_type_kind(irv_type(s2)) == TYP_PTR):
                    v = ir_interp_tag(v)
                if g_interp_big != 0 && irv_type(s1) == TI_CHAR && irv_type(s2) == TI_INT:
                    v = ir_interp_word(v)
                cell_store(g_ir_vals, s1 * 8, v)
        // IR_LOAD
        if op == 10:
            if d >= 0:
                v : ., mut = cell_load(g_ir_vals, s1 * 8)
                if g_interp_big != 0 && irv_type(d) == TI_INT && (irv_type(s1) == TI_CHAR || irv_type(s1) == TI_BOOL || get_type_kind(irv_type(s1)) == TYP_REF || get_type_kind(irv_type(s1)) == TYP_PTR):
                    v = ir_interp_tag(v)
                if g_interp_big != 0 && irv_type(d) == TI_CHAR && irv_type(s1) == TI_INT:
                    v = ir_interp_word(v)
                cell_store(g_ir_vals, d * 8, v)
        // IR_LOAD
        if op == 11:
            // IR_LOAD_FIELD: s1=struct_var, s3=field_idx
            if d >= 0 && s1 >= 0:
                ptr := cell_load(g_ir_vals, s1 * 8)
                if ptr != 0:
                    unsafe:
                        cell_store(g_ir_vals, d * 8, cell_load(@str_of(ptr), s3 * interp_field_stride()))
                else:
                    cell_store(g_ir_vals, d * 8, cell_load(g_ir_vals, s1 * 8))
        if op == 12:
            // IR_STORE_FIELD: s1=struct_var, s2=val_var, s3=field_idx
            if s1 >= 0 && s2 >= 0:
                ptr := cell_load(g_ir_vals, s1 * 8)
                if ptr != 0:
                    unsafe:
                        cell_store(@str_of(ptr), s3 * interp_field_stride(), cell_load(g_ir_vals, s2 * 8))
                else:
                    cell_store(g_ir_vals, s1 * 8, cell_load(g_ir_vals, s2 * 8))
        if op == 13:
            // IR_LOAD_INDEX: s1=arr_var, s3=literal_idx
            if d >= 0 && s1 >= 0:
                arr_value := cell_load(g_ir_vals, s1 * 8)
                if irv_type(s1) == TI_STR:
                    cell_store(g_ir_vals, d * 8, str_load8(arr_value, s3))
                else:
                    unsafe:
                        cell_store(g_ir_vals, d * 8, cell_load(@str_of(arr_value), s3 * interp_ptr_stride()))
        if op == 14:
            // IR_STORE_INDEX: s1=arr_var, s2=val_var, s3=literal_idx
            if s1 >= 0 && s2 >= 0:
                arr_value := cell_load(g_ir_vals, s1 * 8)
                if irv_type(s1) == TI_STR:
                    cell_store_byte(istr_get(arr_value), s3, cell_load(g_ir_vals, s2 * 8))
                else:
                    unsafe:
                        cell_store(@str_of(arr_value), s3 * interp_ptr_stride(), cell_load(g_ir_vals, s2 * 8))
        if op == 15:
            // IR_LOAD_INDEX_VAR: s1=arr_var, s2=idx_var
            if d >= 0 && s1 >= 0 && s2 >= 0:
                arr_value := cell_load(g_ir_vals, s1 * 8)
                idx := ir_interp_word(cell_load(g_ir_vals, s2 * 8))
                if irv_type(s1) == TI_STR:
                    cell_store(g_ir_vals, d * 8, str_load8(arr_value, idx))
                else:
                    unsafe:
                        cell_store(g_ir_vals, d * 8, cell_load(@str_of(arr_value), idx * interp_ptr_stride()))
        if op == 16:
            // IR_STORE_INDEX_VAR: d=val_var, s1=arr_var, s2=idx_var
            if d >= 0 && s1 >= 0 && s2 >= 0:
                arr_value := cell_load(g_ir_vals, s1 * 8)
                idx := ir_interp_word(cell_load(g_ir_vals, s2 * 8))
                if irv_type(s1) == TI_STR:
                    cell_store_byte(istr_get(arr_value), idx, cell_load(g_ir_vals, d * 8))
                else:
                    unsafe:
                        cell_store(@str_of(arr_value), idx * interp_ptr_stride(), cell_load(g_ir_vals, d * 8))
        // IR_MAKE_ENUM: allocate one tag slot plus s2 payload fields and store s1
        // (the variant-name index) in the first word. This matches the ELF layout
        // [tag][payload]; IR_STORE_FIELD writes the payload.
        if op == 17:
            if d >= 0:
                need2 := interp_ptr_stride() + s2 * interp_field_stride()
                bp := alloc(need2)
                vi2 : ., mut = 0
                loop:
                    if vi2 >= need2:
                        break
                    cell_store_byte(bp, vi2, 0)
                    vi2 = vi2 + 1
                cell_store(bp, 0, s1)
                unsafe:
                    cell_store(g_ir_vals, d * 8, @ptr_of(bp))
        // IR_LOAD_ENUM_TAG: d = tag word at the pointer in slot s1.
        if op == 23:
            if d >= 0 && s1 >= 0:
                ptr := cell_load(g_ir_vals, s1 * 8)
                if ptr != 0:
                    unsafe:
                        cell_store(g_ir_vals, d * 8, ir_interp_tag(cell_load(@str_of(ptr), 0)))
        // IR_REF: d = s1. The slot number is the stack address used by the deref helpers.
        if op == 18:
            if d >= 0 && s1 >= 0:
                cell_store(g_ir_vals, d * 8, s1)
        // IR_DEREF: read through the pointer in slot s1.
        if op == 25:
            if d >= 0 && s1 >= 0:
                cell_store(g_ir_vals, d * 8, ir_interp_deref_read(cell_load(g_ir_vals, s1 * 8)))

        // IR_SLICE: d = arr + low elements, matching the ELF encoding. The
        // element scale is a target fact.
        if op == 24:
            if d >= 0 && s1 >= 0 && s2 >= 0:
                cell_store(g_ir_vals, d * 8, cell_load(g_ir_vals, s1 * 8) + ir_interp_word(cell_load(g_ir_vals, s2 * 8)) * interp_ptr_stride())

        // IR_BOUNDS_CHECK: s1 is the index variable and s2 the limit. An index
        // below 0 or at least the limit aborts with -1.
        if op == 30 && s2 >= 0:
            iv := ir_interp_word(cell_load(g_ir_vals, s1 * 8))
            limit : ., mut = s2
            if ti == 1:
                limit = ir_interp_word(cell_load(g_ir_vals, s2 * 8))
            if iv < 0 || iv >= limit:
                return -1

        // IR_LAZY_THUNK and IR_LAZY_FORCE. Calls are eager, so both wrappers
        // preserve the computed value.
        if op == 46 || op == 47:
            if d >= 0 && s1 >= 0:
                cell_store(g_ir_vals, d * 8, cell_load(g_ir_vals, s1 * 8))

        // IR_YIELD: pass the value in slot s1 eagerly, like IR_AWAIT. Emission
        // uses dest = -1, so the d >= 0 check prevents a write before the value
        // buffer.
        if op == 28:
            if d >= 0 && s1 >= 0:
                cell_store(g_ir_vals, d * 8, cell_load(g_ir_vals, s1 * 8))

        // IR_PTR_OF / IR_STR_OF: raw address <-> mathematical int view.
        if op == 52:
            if d >= 0 && s1 >= 0:
                if g_interp_big != 0:
                    cell_store(g_ir_vals, d * 8, bi_from_uword(cell_load(g_ir_vals, s1 * 8)))
                else:
                    cell_store(g_ir_vals, d * 8, cell_load(g_ir_vals, s1 * 8))
        if op == 53:
            if d >= 0 && s1 >= 0:
                if g_interp_big != 0:
                    cell_store(g_ir_vals, d * 8, bi_to_uword_checked(cell_load(g_ir_vals, s1 * 8)))
                else:
                    cell_store(g_ir_vals, d * 8, cell_load(g_ir_vals, s1 * 8))

        // IR_FNADDR: the interpreter has no real addresses; store 0.
        if op == 48:
            if d >= 0:
                cell_store(g_ir_vals, d * 8, 0)

        // IR_APPROX is a pure annotation; skip it.
        if op == 51:
            ip = ip + 1
            continue

        // IR_I2F and IR_F2I convert between int and binary64. The interpreter has
        // no binary64 semantics. Report an error instead of skipping: a skipped
        // conversion leaves 0 or a stale value and can cause SIGFPE later.
        if op == 49 || op == 50:
            println("interpreter error: IR_I2F/IR_F2I needs binary64 semantics (apx dex) — `corec run` cannot execute apx dex arithmetic; build & run natively (corec build) instead")
            return -1

        // IR_STORE_PTR: write the value in slot s2 through the pointer in slot s1.
        // The pointer may be a stack slot number or a heap address.
        if op == 26:
            if s1 >= 0 && s2 >= 0:
                ir_interp_deref_write(cell_load(g_ir_vals, s1 * 8), cell_load(g_ir_vals, s2 * 8))

        // IR_ADDR_INDEX: d = slot s1 + stride * slot s2 for &arr[i].
        if op == 31:
            if d >= 0 && s1 >= 0 && s2 >= 0:
                cell_store(g_ir_vals, d * 8, cell_load(g_ir_vals, s1 * 8) + ir_interp_word(cell_load(g_ir_vals, s2 * 8)) * interp_ptr_stride())
        // IR_ARENA_NEW and IR_ARENA_RESET call the interpreted arena library.
        if op == 32:
            ir_interp_arena_new(d, s1)
        if op == 33:
            ir_interp_arena_reset(s1)

        // IR_DYN_PACK: a dyn value uses two slots, value at d and tag at d+1.
        if op == 43:
            if d >= 0 && s1 >= 0:
                cell_store(g_ir_vals, d * 8, cell_load(g_ir_vals, s1 * 8))
                cell_store(g_ir_vals, (d + 1) * 8, s2)
        // IR_DYN_TAG: d = tag at slot s1 + 1.
        if op == 41:
            if d >= 0 && s1 >= 0:
                cell_store(g_ir_vals, d * 8, cell_load(g_ir_vals, (s1 + 1) * 8))
        // IR_DYN_VAL: d = value at slot s1.
        if op == 42:
            if d >= 0 && s1 >= 0:
                cell_store(g_ir_vals, d * 8, cell_load(g_ir_vals, s1 * 8))

        // IR_DYN_DISPATCH has no interpreter implementation; report an error.
        if op == 44:
            println("error: interp 不支持动态分发（IR_DYN_DISPATCH）")
            return 2
        // IR_CALL_EXTERN has no interpreter implementation; report an error.
        if op == 45:
            print("error: interp 无法调用外部函数：")
            println(istr_get(s1))
            return 2
        // Fixed-address placement is an ELF/deployment fact; see the callee
        // dispatch above for the same loud boundary.
        if op == 55:
            println("error: interp 不支持固定地址放置（IR_ALLOC_AT）")
            return 2

        // IR_I2F and IR_F2I are rejected at dispatch entry.

        // Branch by node index.
        if op == 19:
            cv := cell_load(g_ir_vals, s1 * 8)
            if cv != 0:
                if s2 >= 0 && s2 < g_label_count:
                    ip = cell_load(g_label_poses, s2 * 8)
            else:
                if s3 >= 0 && s3 < g_label_count:
                    ip = cell_load(g_label_poses, s3 * 8)
            if ip < node_count:
                continue
            else:
                break
        if op == 20:
            // IR_JUMP
            // A jump to the innermost enclosing loop region's enter is a
            // back-edge. Its target comes from g_loop_region_enter, not from the
            // label table. Other jumps use g_label_poses. The innermost region is
            // the region containing ip with the largest enter offset.
            cur_enter : ., mut = -1
            cur_ri : ., mut = -1
            ri2 : ., mut = 0
            loop:
                if ri2 >= g_loop_region_count:
                    break
                e2 := cell_load(g_loop_region_enter, ri2 * 8)
                x2 := cell_load(g_loop_region_exit,  ri2 * 8)
                if ip >= e2 && ip < x2 && e2 > cur_enter:
                    cur_enter = e2
                    cur_ri = ri2
                ri2 = ri2 + 1
            if s1 >= 0 && s1 < g_label_count:
                target := cell_load(g_label_poses, s1 * 8)
                if target >= 0:
                    if cur_ri >= 0 && target == cur_enter:
                        // Back-edge to the innermost loop region's enter:
                        // ip comes from the region table, not label poses.
                        ip = cell_load(g_loop_region_enter, cur_ri * 8)  // == cur_enter
                    else:
                        ip = target  // plain jump, resolved via label poses
                else:
                    ip = ip + 1
            else:
                ip = ip + 1
            if ip < node_count:
                continue
            else:
                break
        // v10 IR_MATCH: the CASE table selects a LABEL node and control jumps
        // directly there. ip is function-relative; target is a global NOD id.
        // A miss with no DEFAULT and an out-of-span target both trap.
        if op == 54:
            mt := interp_match_target(s1, irv_type(s1), s2, s3)
            if mt < 0:
                g_interp_abort = -1
                return -1
            if mt < node_start || mt >= node_start + node_count:
                g_interp_abort = -1
                return -1
            ip = mt - node_start
            continue
        // IR_LABEL: no operation.

        // IR_AWAIT
        if op == 29:
            if d >= 0:
                cell_store(g_ir_vals, d * 8, cell_load(g_ir_vals, s1 * 8))

        // IR_CALL and IR_SPAWN use the shared dispatch in ir_interp_call. Builtins,
        // inline user functions, nested recursion, and abort propagation all live
        // in that one function.
        if op == 4 || op == 27:
            ir_interp_call(d, s1, s2, s3)
            if g_interp_abort != 0:
                return g_interp_abort

        ip = ip + 1
    return 0
