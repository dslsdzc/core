// === stub_regalloc.cr ===
// Register assignment for runtime stubs.
//
// A stub is a straight-line instruction list. It is written with virtual
// registers and target positions, never with physical register names. The same
// entry / interval / coexistence model as the compiler register allocator
// applies:
//
//   virtual register  entry
//   [first use, last use]  live interval
//   intersecting intervals  coexistence
//   physical register  location
//   spill slot  home
//
// The target supplies only a register file (a list of physical register
// numbers). The module returns an assignment and a spill count; the target
// encoder turns those into bytes. Nothing here depends on x86-64.
//
// Call sequence:
//
//   sr_begin(instr_count, vreg_count, reg_count)
//   sr_reg(k, phys) / sr_op(i, op) / sr_read(i, v) / sr_write(i, v)
//   sr_pin(i, v, phys)
//   rc = sr_run()
//   sr_assigned(v) / sr_spilled(v) / sr_spills()
//
// sr_run returns SR_OK or one of the SR_ERR_* values below. Pins are hard
// constraints; a pin that cannot be satisfied is an error, never a silent spill.

SR_INSTR_MAX_READS : int = 4
SR_INSTR_MAX_WRITES : int = 2
SR_INSTR_MAX_PINS : int = 2

SR_OK : int = 0
SR_ERR_PIN_DISAGREE : int = -1   // one entry pinned to two registers
SR_ERR_PIN_NOT_IN_FILE : int = -2 // pin outside the target register file
SR_ERR_PIN_CONFLICT : int = -3   // two coexisting entries pinned to one register

g_sr_instr_count : int, mut = 0
g_sr_vreg_count : int, mut = 0
g_sr_reg_count : int, mut = 0

g_sr_regs : string, mut
g_sr_ops : string, mut
g_sr_reads : string, mut
g_sr_read_n : string, mut
g_sr_writes : string, mut
g_sr_write_n : string, mut
g_sr_pin_v : string, mut
g_sr_pin_p : string, mut
g_sr_pin_n : string, mut

g_sr_start : string, mut
g_sr_end : string, mut
g_sr_pin : string, mut
g_sr_assign : string, mut
g_sr_spill : string, mut
g_sr_order : string, mut

g_sr_spill_count : int, mut = 0
g_sr_error : int, mut = SR_OK

fn sr_begin(instr_count: int, vreg_count: int, reg_count: int):
    icap : ., mut = instr_count
    if icap < 1:
        icap = 1
    vcap : ., mut = vreg_count
    if vcap < 1:
        vcap = 1
    rcap : ., mut = reg_count
    if rcap < 1:
        rcap = 1

    g_sr_instr_count = instr_count
    g_sr_vreg_count = vreg_count
    g_sr_reg_count = reg_count
    g_sr_spill_count = 0
    g_sr_error = SR_OK

    g_sr_regs = alloc(rcap * 8)
    g_sr_ops = alloc(icap * 8)
    g_sr_reads = alloc(icap * SR_INSTR_MAX_READS * 8)
    g_sr_read_n = alloc(icap * 8)
    g_sr_writes = alloc(icap * SR_INSTR_MAX_WRITES * 8)
    g_sr_write_n = alloc(icap * 8)
    g_sr_pin_v = alloc(icap * SR_INSTR_MAX_PINS * 8)
    g_sr_pin_p = alloc(icap * SR_INSTR_MAX_PINS * 8)
    g_sr_pin_n = alloc(icap * 8)

    g_sr_start = alloc(vcap * 8)
    g_sr_end = alloc(vcap * 8)
    g_sr_pin = alloc(vcap * 8)
    g_sr_assign = alloc(vcap * 8)
    g_sr_spill = alloc(vcap * 8)
    g_sr_order = alloc(vcap * 8)

    i : ., mut = 0
    loop:
        if i >= icap:
            break
        cell_store(g_sr_ops, i * 8, 0)
        cell_store(g_sr_read_n, i * 8, 0)
        cell_store(g_sr_write_n, i * 8, 0)
        cell_store(g_sr_pin_n, i * 8, 0)
        i = i + 1
    vi : ., mut = 0
    loop:
        if vi >= vcap:
            break
        cell_store(g_sr_start, vi * 8, -1)
        cell_store(g_sr_end, vi * 8, -1)
        cell_store(g_sr_pin, vi * 8, -1)
        cell_store(g_sr_assign, vi * 8, -1)
        cell_store(g_sr_spill, vi * 8, -1)
        cell_store(g_sr_order, vi * 8, vi)
        vi = vi + 1

fn sr_reg(k: int, phys: int):
    if k >= 0 && k < g_sr_reg_count:
        cell_store(g_sr_regs, k * 8, phys)

fn sr_op(i: int, op: int):
    if i >= 0 && i < g_sr_instr_count:
        cell_store(g_sr_ops, i * 8, op)

fn sr_read(i: int, v: int):
    if i < 0 || i >= g_sr_instr_count:
        return
    n := cell_load(g_sr_read_n, i * 8)
    if n >= SR_INSTR_MAX_READS:
        return
    cell_store(g_sr_reads, (i * SR_INSTR_MAX_READS + n) * 8, v)
    cell_store(g_sr_read_n, i * 8, n + 1)

fn sr_write(i: int, v: int):
    if i < 0 || i >= g_sr_instr_count:
        return
    n := cell_load(g_sr_write_n, i * 8)
    if n >= SR_INSTR_MAX_WRITES:
        return
    cell_store(g_sr_writes, (i * SR_INSTR_MAX_WRITES + n) * 8, v)
    cell_store(g_sr_write_n, i * 8, n + 1)

fn sr_pin(i: int, v: int, phys: int):
    if i < 0 || i >= g_sr_instr_count:
        return
    n := cell_load(g_sr_pin_n, i * 8)
    if n >= SR_INSTR_MAX_PINS:
        return
    cell_store(g_sr_pin_v, (i * SR_INSTR_MAX_PINS + n) * 8, v)
    cell_store(g_sr_pin_p, (i * SR_INSTR_MAX_PINS + n) * 8, phys)
    cell_store(g_sr_pin_n, i * 8, n + 1)

fn sr_assigned(v: int) -> int:
    if v < 0 || v >= g_sr_vreg_count:
        return -1
    return cell_load(g_sr_assign, v * 8)

fn sr_spilled(v: int) -> int:
    if v < 0 || v >= g_sr_vreg_count:
        return -1
    return cell_load(g_sr_spill, v * 8)

fn sr_spills() -> int:
    return g_sr_spill_count

fn sr_error_code() -> int:
    return g_sr_error

// Extend the interval of v to instruction i. A read-only entry starts at its
// first use; the encoder must define it before that instruction.
fn sr_touch(v: int, i: int):
    if v < 0 || v >= g_sr_vreg_count:
        return
    if cell_load(g_sr_start, v * 8) < 0:
        cell_store(g_sr_start, v * 8, i)
    cell_store(g_sr_end, v * 8, i)

fn sr_overlap(a: int, b: int) -> int:
    sa := cell_load(g_sr_start, a * 8)
    ea := cell_load(g_sr_end, a * 8)
    sb := cell_load(g_sr_start, b * 8)
    eb := cell_load(g_sr_end, b * 8)
    if sa < 0 || sb < 0:
        return 0
    if sa <= eb && sb <= ea:
        return 1
    return 0

// True when physical register ph is already held by a coexisting entry. Pins
// count even before their entry is assigned: they are hard constraints.
fn sr_location_taken(v: int, ph: int) -> int:
    w : ., mut = 0
    loop:
        if w >= g_sr_vreg_count:
            break
        if w != v && sr_overlap(v, w) != 0:
            if cell_load(g_sr_pin, w * 8) == ph:
                return 1
            if cell_load(g_sr_assign, w * 8) == ph:
                return 1
        w = w + 1
    return 0

fn sr_reg_index(ph: int) -> int:
    k : ., mut = 0
    loop:
        if k >= g_sr_reg_count:
            break
        if cell_load(g_sr_regs, k * 8) == ph:
            return k
        k = k + 1
    return -1

// Pick the first free physical register for v, in target order.
fn sr_pick(v: int) -> int:
    k : ., mut = 0
    loop:
        if k >= g_sr_reg_count:
            break
        ph := cell_load(g_sr_regs, k * 8)
        if sr_location_taken(v, ph) == 0:
            return ph
        k = k + 1
    return -1

fn sr_order_before(a: int, b: int) -> int:
    sa := cell_load(g_sr_start, a * 8)
    sb := cell_load(g_sr_start, b * 8)
    if sa < 0:
        return 0
    if sb < 0:
        return 1
    if sa < sb:
        return 1
    if sa > sb:
        return 0
    if a < b:
        return 1
    return 0

// Insertion sort of entry indexes by (live_start, index). Entries without an
// interval go last and are skipped during assignment.
fn sr_sort_order():
    i : ., mut = 1
    loop:
        if i >= g_sr_vreg_count:
            break
        key := cell_load(g_sr_order, i * 8)
        j : ., mut = i - 1
        loop:
            if j < 0:
                break
            cur := cell_load(g_sr_order, j * 8)
            if sr_order_before(key, cur) == 0:
                break
            cell_store(g_sr_order, (j + 1) * 8, cur)
            j = j - 1
        cell_store(g_sr_order, (j + 1) * 8, key)
        i = i + 1

fn sr_run() -> int:
    g_sr_spill_count = 0
    g_sr_error = SR_OK

    vi : ., mut = 0
    loop:
        if vi >= g_sr_vreg_count:
            break
        cell_store(g_sr_start, vi * 8, -1)
        cell_store(g_sr_end, vi * 8, -1)
        cell_store(g_sr_pin, vi * 8, -1)
        cell_store(g_sr_assign, vi * 8, -1)
        cell_store(g_sr_spill, vi * 8, -1)
        cell_store(g_sr_order, vi * 8, vi)
        vi = vi + 1

    ii : ., mut = 0
    loop:
        if ii >= g_sr_instr_count:
            break
        ri : ., mut = 0
        loop:
            if ri >= cell_load(g_sr_read_n, ii * 8):
                break
            v := cell_load(g_sr_reads, (ii * SR_INSTR_MAX_READS + ri) * 8)
            sr_touch(v, ii)
            ri = ri + 1
        wi : ., mut = 0
        loop:
            if wi >= cell_load(g_sr_write_n, ii * 8):
                break
            v := cell_load(g_sr_writes, (ii * SR_INSTR_MAX_WRITES + wi) * 8)
            sr_touch(v, ii)
            wi = wi + 1
        pi : ., mut = 0
        loop:
            if pi >= cell_load(g_sr_pin_n, ii * 8):
                break
            v := cell_load(g_sr_pin_v, (ii * SR_INSTR_MAX_PINS + pi) * 8)
            ph := cell_load(g_sr_pin_p, (ii * SR_INSTR_MAX_PINS + pi) * 8)
            sr_touch(v, ii)
            old := cell_load(g_sr_pin, v * 8)
            if old >= 0 && old != ph:
                g_sr_error = SR_ERR_PIN_DISAGREE
                return g_sr_error
            cell_store(g_sr_pin, v * 8, ph)
            pi = pi + 1
        ii = ii + 1

    // Every pin must name a register that the target actually has.
    vi = 0
    loop:
        if vi >= g_sr_vreg_count:
            break
        ph := cell_load(g_sr_pin, vi * 8)
        if ph >= 0 && sr_reg_index(ph) < 0:
            g_sr_error = SR_ERR_PIN_NOT_IN_FILE
            return g_sr_error
        vi = vi + 1

    sr_sort_order()

    oi : ., mut = 0
    loop:
        if oi >= g_sr_vreg_count:
            break
        v := cell_load(g_sr_order, oi * 8)
        if cell_load(g_sr_start, v * 8) >= 0:
            ph := cell_load(g_sr_pin, v * 8)
            if ph >= 0:
                // A pinned entry keeps its register for the whole interval.
                // Coexistence with another pin or an assigned entry is an error.
                if sr_location_taken(v, ph) != 0:
                    g_sr_error = SR_ERR_PIN_CONFLICT
                    return g_sr_error
                cell_store(g_sr_assign, v * 8, ph)
            else:
                got := sr_pick(v)
                if got >= 0:
                    cell_store(g_sr_assign, v * 8, got)
                else:
                    cell_store(g_sr_spill, v * 8, g_sr_spill_count)
                    g_sr_spill_count = g_sr_spill_count + 1
        oi = oi + 1

    return g_sr_error
