// conc — cross-paradigm concurrency substrate (CP-1).
//
// This module is deliberately independent of sched/chan/arena. It implements:
//   - owner-region bump allocation for runtime objects;
//   - typed MessageRef channels (payload bytes follow a 32-byte header);
//   - a target-neutral fixture plan (bodies, channels, edges);
//   - CPU and host-SIMT executors that consume the same plan.
//
// No source syntax is added here. The plan carries structure only; CPU/SIMT
// are mappings, not semantics.

// ── Constants ──────────────────────────────────────────────────────────────

CONC_BODY_TASK : int, pub = 1
CONC_BODY_DATA_PARALLEL : int, pub = 2
CONC_BODY_PIPELINE : int, pub = 3

CONC_EDGE_SPAWN : int, pub = 1
CONC_EDGE_SEND : int, pub = 2
CONC_EDGE_JOIN : int, pub = 3
CONC_EDGE_RECV : int, pub = 4

// Channel ordering. The CPU runtime supports both; MPMC is validated in the
// plan and executed by the conc scheduler's multi-waiter queues.
CONC_PC_SPSC : int, pub = 1
CONC_PC_MPMC : int, pub = 2

CONC_SLOT_CPU_THREAD : int, pub = 1
CONC_SLOT_CPU_FIBER : int, pub = 2

CONC_TRANSFER_MOVE : int, pub = 1
CONC_TRANSFER_LOAN : int, pub = 2
CONC_TRANSFER_SPLIT : int, pub = 3
CONC_TRANSFER_FILL : int, pub = 4
CONC_TRANSFER_COPY : int, pub = 5

CONC_STAGE_BLOCKING : int, pub = 0
CONC_STAGE_BOUNDED : int, pub = 1

CONC_BUDGET_PROGRESSIVE : int, pub = 1
CONC_BUDGET_COUNT : int, pub = 2
CONC_BUDGET_WAIT : int, pub = 3

// Certificate kinds used by conc_plan_cert_prove. Unknown kinds are accepted
// as opaque certificates, but the known kinds are re-derived from the plan.
CONC_CERT_ACYCLIC : int, pub = 1
CONC_CERT_DETERMINISTIC : int, pub = 2
CONC_CERT_BUDGET : int, pub = 3
CONC_CERT_TRANSFER : int, pub = 4
CONC_CERT_SHARED_MAPPING : int, pub = 5
CONC_CERT_EQUIVALENCE : int, pub = 6

CONC_STATUS_PROVED : int, pub = 1
CONC_STATUS_UNKNOWN : int, pub = 2
CONC_STATUS_VIOLATED : int, pub = 3
CONC_STATUS_MEASURED : int, pub = 4

// Status codes for conc_send/conc_recv and conc_last_error.
CONC_OK : int, pub = 0
CONC_ERR_INVALID : int, pub = -1
CONC_ERR_FULL : int, pub = 1
CONC_ERR_EMPTY : int, pub = 2
CONC_ERR_NOMEM : int, pub = 3

// The same 1 TiB ceiling the arena allocator uses; keeps size arithmetic well
// inside the raw 64-bit range.
CONC_MAX_ALLOC : int = 1099511627776
CONC_MAX_ENTRIES : int = 64
CONC_MAX_BODIES : int = 64
CONC_MAX_CHANNELS : int = 64
CONC_MAX_EDGES : int = 256
CONC_MAX_BINDS : int = 32
CONC_MAX_PARAMS : int = 1048576

CONC_MSG_MAGIC : int = 1129270851       // 0x434F4E43; LE bytes are "CNOC"
CONC_CHANNEL_MAGIC : int = 1129270856   // 0x434F4E48; LE bytes are "HNOC"
CONC_CHANNEL_REF_MAGIC : int = 1129270861 // descriptor-carrying channel
CONC_MSG_HEADER : int = 32
CONC_REF_MAGIC : int = 1129270860
CONC_REF_MOVED_MAGIC : int = 1129270862
CONC_REF_LOAN_MAGIC : int = 1129270863
CONC_REF_SIZE : int = 64
CONC_REF_NONCE : int = 48
CONC_MAX_LAYOUTS : int = 64
CONC_MAX_LAYOUT_FIELDS : int = 16

CONC_SPACE_HOST : int, pub = 0
CONC_SPACE_DEVICE : int, pub = 1
CONC_SPACE_REMOTE : int, pub = 2
CONC_MAX_SPACES : int = 16
CONC_MAX_LOANS : int = 64

// Region table. Each region owns a global-heap block and a bump cursor.
g_conc_region_block : string, mut
g_conc_region_cap : string, mut
g_conc_region_cursor : string, mut
g_conc_region_epoch : string, mut
g_conc_region_count : int, mut = 0
g_conc_region_array_cap : int, mut = 0

// Plan table. A plan record points at three growable descriptor arrays.
g_conc_plans : string, mut
g_conc_plan_count : int, mut = 0
g_conc_plan_array_cap : int, mut = 0

// A single 8-byte table used by sched_call_*. CP-1 executes one body at a
// time; concurrent mappings will eventually own their own call tables.
g_conc_call_table : string, mut

// 0 / CONC_ERR_* for the most recent send/recv. This lets recv distinguish an
// empty queue from an output-allocation failure without changing its string
// return type.
g_conc_last_error : int, mut = 0
g_conc_alloc_fail_after : int, mut = -1
g_conc_alloc_failures : int, mut = 0

// Layout identity table: layout id -> element size + user hash. Populated by
// conc_layout_declare; consumers can check that a descriptor's layout is known
// before crossing a region boundary.
g_conc_layout_size : string, mut
g_conc_layout_hash : string, mut
g_conc_layout_fields : string, mut
g_conc_layout_field_count : string, mut
g_conc_layout_count : int, mut = 0
g_conc_layout_version : int, mut = 1

// Host-simulated memory spaces. A space owns a region and an accounting
// cursor; DEVICE/REMOTE currently use the same local mapping, while the
// transfer executor records the physical byte movement and source/dest space.
g_conc_space_count : int, mut = 0
g_conc_space_kind : string, mut
g_conc_space_capacity : string, mut
g_conc_space_region : string, mut
g_conc_space_used : string, mut
g_conc_space_bytes : string, mut
g_conc_transfer_bytes : int, mut = 0
g_conc_transfer_count : int, mut = 0
g_conc_transfer_failures : int, mut = 0
g_conc_xfer_move_bytes : int, mut = 0
g_conc_xfer_copy_bytes : int, mut = 0
g_conc_xfer_loan_bytes : int, mut = 0
g_conc_xfer_split_bytes : int, mut = 0
g_conc_space_in : string, mut
g_conc_space_out : string, mut
g_conc_loans_src : string, mut
g_conc_loans_ref : string, mut
g_conc_loans_nonce : string, mut
g_conc_loan_count : int, mut = 0
g_conc_loan_seq : int, mut = 0

// Cursor for the plan-text tokenizer. CP-2 loads one plan at a time.
g_conc_plan_parse_pos : int, mut = 0

// ── Raw pointer helpers ───────────────────────────────────────────────────

fn _conc_addr(s: string) -> int:
    v : ., mut = 0
    unsafe:
        v = @ptr_of(s)
    return v

fn _conc_ptr(v: int) -> string:
    p : ., mut = ""
    if v == 0:
        return p
    unsafe:
        p = @str_of(v)
    return p

// In a static ELF, @ptr_of("") is not zero; the empty string is a real rodata
// object. Allocation failure therefore has to be detected by its zero length,
// not only by a null pointer.
fn _conc_is_null(p: string) -> int:
    if _conc_addr(p) == 0:
        return 1
    if str_len(p) <= 0:
        return 1
    return 0

// Allocate outside the current compiler function arena. Runtime objects must
// live in owner regions, never in a function arena.
fn _conc_global_alloc(size: int) -> string:
    // Owner regions are process-wide and must be usable from any worker M. A
    // private anonymous mapping is independent of every arena partition and of
    // the (single-owner) bump heap. Regions live until process exit, matching
    // the previous "never reset" global-heap behavior.
    if size <= 0:
        return _conc_ptr(0)
    if g_conc_alloc_fail_after >= 0:
        if g_conc_alloc_fail_after == 0:
            g_conc_alloc_failures = g_conc_alloc_failures + 1
            return _conc_ptr(0)
        g_conc_alloc_fail_after = g_conc_alloc_fail_after - 1
    // Ask for size + 8 so the payload can carry the Core string length word
    // immediately before its data pointer, like the heap allocator does.
    raw := syscall6(9, 0, size + 8, 3, 34, -1, 0)
    if raw <= 0:
        return _conc_ptr(0)
    base := _conc_ptr(raw)
    cell_store(base, 0, size)
    return _conc_ptr(raw + 8)

// Byte copy. The 8-byte path keeps layout copies cheap; the tail path keeps
// arbitrary element sizes correct instead of assuming every message is 8B.
fn _conc_copy(dst: string, src: string, n: int):
    i : ., mut = 0
    loop:
        if i + 8 > n:
            break
        cell_store(dst, i, cell_load(src, i))
        i = i + 8
    loop:
        if i >= n:
            break
        store8(dst, i, load8(src, i))
        i = i + 1

// ── Owner regions ─────────────────────────────────────────────────────────

fn _conc_region_ensure(needed: int) -> int:
    if needed <= g_conc_region_array_cap:
        return 0
    nc : ., mut = g_conc_region_array_cap * 2
    if nc < 8:
        nc = 8
    if nc < needed:
        nc = needed + 8
    nb := _conc_global_alloc(nc * 8)
    cb := _conc_global_alloc(nc * 8)
    cu := _conc_global_alloc(nc * 8)
    ep := _conc_global_alloc(nc * 8)
    if _conc_is_null(nb) != 0:
        return -1
    if _conc_is_null(cb) != 0:
        return -1
    if _conc_is_null(cu) != 0:
        return -1
    if _conc_is_null(ep) != 0:
        return -1
    if g_conc_region_array_cap > 0:
        _conc_copy(nb, g_conc_region_block, g_conc_region_array_cap * 8)
        _conc_copy(cb, g_conc_region_cap, g_conc_region_array_cap * 8)
        _conc_copy(cu, g_conc_region_cursor, g_conc_region_array_cap * 8)
        _conc_copy(ep, g_conc_region_epoch, g_conc_region_array_cap * 8)
    g_conc_region_block = nb
    g_conc_region_cap = cb
    g_conc_region_cursor = cu
    g_conc_region_epoch = ep
    g_conc_region_array_cap = nc
    return 0

fn _conc_region_valid(region: int) -> int:
    if region < 0:
        return 0
    if region >= g_conc_region_count:
        return 0
    base := load_str_ptr(g_conc_region_block, region * 8)
    if _conc_addr(base) == 0:
        return 0
    return 1

fn conc_region_new(size: int) -> int, pub:
    // A region smaller than one message header is not useful and makes
    // capacity tests confusing.
    if size < 64:
        return -1
    if size > CONC_MAX_ALLOC - 16:
        return -1
    if _conc_region_ensure(g_conc_region_count + 1) != 0:
        return -1
    raw := _conc_global_alloc(size + 16)
    if _conc_is_null(raw) != 0:
        return -1
    // alloc() only guarantees 8-byte data alignment. Payloads are promised
    // 16-byte alignment, so align the region base once, here.
    a := _conc_addr(raw)
    aligned : ., mut = (a + 15) / 16 * 16
    block := _conc_ptr(aligned)
    id := g_conc_region_count
    store_str_ptr(g_conc_region_block, id * 8, block)
    cell_store(g_conc_region_cap, id * 8, size)
    cell_store(g_conc_region_cursor, id * 8, 0)
    cell_store(g_conc_region_epoch, id * 8, 1)
    g_conc_region_count = id + 1
    return id

// Allocate a typed message payload. Header layout (32 bytes):
//   0 magic, 8 region id, 16 epoch, 24 string length (payload size + 1).
// The length word is also the Core string header for the returned payload, so
// str_len(payload) == requested size and normal string ops stay valid.
fn conc_alloc(region: int, size: int) -> string, pub:
    if _conc_region_valid(region) == 0:
        return _conc_ptr(0)
    if size <= 0:
        return _conc_ptr(0)
    if size > CONC_MAX_ALLOC:
        return _conc_ptr(0)
    // Reserve one extra byte for the Core string NUL terminator.
    aligned : ., mut = (size + 1 + 15) / 16 * 16
    total := CONC_MSG_HEADER + aligned
    if total > CONC_MAX_ALLOC:
        return _conc_ptr(0)
    cap := cell_load(g_conc_region_cap, region * 8)
    cursor := cell_load(g_conc_region_cursor, region * 8)
    if cursor < 0:
        return _conc_ptr(0)
    if total > cap:
        return _conc_ptr(0)
    if cursor > cap - total:
        return _conc_ptr(0)
    base := load_str_ptr(g_conc_region_block, region * 8)
    if _conc_addr(base) == 0:
        return _conc_ptr(0)
    hdr := _conc_ptr(_conc_addr(base) + cursor)
    cell_store(hdr, 0, CONC_MSG_MAGIC)
    cell_store(hdr, 8, region)
    cell_store(hdr, 16, cell_load(g_conc_region_epoch, region * 8))
    cell_store(hdr, 24, size + 1)
    store8(hdr, CONC_MSG_HEADER + size, 0)
    cell_store(g_conc_region_cursor, region * 8, cursor + total)
    return _conc_ptr(_conc_addr(hdr) + CONC_MSG_HEADER)

fn conc_region_reset(region: int) -> int, pub:
    if _conc_region_valid(region) == 0:
        return -1
    cell_store(g_conc_region_cursor, region * 8, 0)
    e := cell_load(g_conc_region_epoch, region * 8)
    cell_store(g_conc_region_epoch, region * 8, e + 1)
    return 0

fn conc_region_owner(region: int) -> int, pub:
    if _conc_region_valid(region) == 0:
        return -1
    return 0

// Find the region containing address a, or -1. This is checked before reading
// a payload header, so conc_is_ok("ordinary string") does not read before the
// string's data.
fn _conc_region_of_addr(a: int) -> int:
    i : ., mut = 0
    loop:
        if i >= g_conc_region_count:
            break
        base := load_str_ptr(g_conc_region_block, i * 8)
        lo := _conc_addr(base)
        if lo != 0:
            cap := cell_load(g_conc_region_cap, i * 8)
            if a >= lo + CONC_MSG_HEADER:
                if a < lo + cap:
                    return i
        i = i + 1
    return -1

// Full MessageRef header check: containment, magic, region identity, epoch,
// size, and payload bounds. It deliberately does not recurse through the
// public API.
fn _conc_header_ok(p: string) -> int:
    a := _conc_addr(p)
    if a == 0:
        return 0
    rid := _conc_region_of_addr(a)
    if rid < 0:
        return 0
    if str_len(p) <= 0:
        return 0
    hdr := _conc_ptr(a - CONC_MSG_HEADER)
    if cell_load(hdr, 0) != CONC_MSG_MAGIC:
        return 0
    if cell_load(hdr, 8) != rid:
        return 0
    if cell_load(hdr, 16) != cell_load(g_conc_region_epoch, rid * 8):
        return 0
    sz := cell_load(hdr, 24) - 1
    if sz <= 0:
        return 0
    cap := cell_load(g_conc_region_cap, rid * 8)
    if sz > cap:
        return 0
    base := load_str_ptr(g_conc_region_block, rid * 8)
    lo := _conc_addr(base)
    if a > lo + cap - sz:
        return 0
    return 1

fn conc_is_ok(p: string) -> int, pub:
    return _conc_header_ok(p)

fn conc_is_aligned(p: string, align: int) -> int, pub:
    if align <= 0:
        return 0
    if _conc_is_null(p) != 0:
        return 0
    if _conc_addr(p) % align == 0:
        return 1
    return 0

fn conc_set_alloc_fail_after(n: int) -> int, pub:
    if n < 0:
        n = -1
    g_conc_alloc_fail_after = n
    return 0

fn conc_alloc_failures() -> int, pub:
    return g_conc_alloc_failures

fn conc_last_error() -> int, pub:
    return g_conc_last_error

fn _conc_space_ensure() -> int:
    if _conc_is_null(g_conc_space_kind) != 0:
        g_conc_space_kind = _conc_global_alloc(CONC_MAX_SPACES * 8)
        g_conc_space_capacity = _conc_global_alloc(CONC_MAX_SPACES * 8)
        g_conc_space_region = _conc_global_alloc(CONC_MAX_SPACES * 8)
        g_conc_space_used = _conc_global_alloc(CONC_MAX_SPACES * 8)
        g_conc_space_bytes = _conc_global_alloc(CONC_MAX_SPACES * 8)
        g_conc_space_in = _conc_global_alloc(CONC_MAX_SPACES * 8)
        g_conc_space_out = _conc_global_alloc(CONC_MAX_SPACES * 8)
        if _conc_is_null(g_conc_space_kind) != 0:
            return -1
        if _conc_is_null(g_conc_space_capacity) != 0:
            return -1
        if _conc_is_null(g_conc_space_region) != 0:
            return -1
        if _conc_is_null(g_conc_space_used) != 0:
            return -1
        if _conc_is_null(g_conc_space_bytes) != 0:
            return -1
        if _conc_is_null(g_conc_space_in) != 0:
            return -1
        if _conc_is_null(g_conc_space_out) != 0:
            return -1
    return 0

fn conc_space_create(kind: int, capacity: int) -> int, pub:
    if kind != CONC_SPACE_HOST && kind != CONC_SPACE_DEVICE && kind != CONC_SPACE_REMOTE:
        return -1
    if capacity <= 0:
        return -1
    if _conc_space_ensure() != 0:
        return -1
    if g_conc_space_count >= CONC_MAX_SPACES:
        return -1
    region := conc_region_new(capacity)
    if region < 0:
        return -1
    id := g_conc_space_count
    cell_store(g_conc_space_kind, id * 8, kind)
    cell_store(g_conc_space_capacity, id * 8, capacity)
    cell_store(g_conc_space_region, id * 8, region)
    cell_store(g_conc_space_used, id * 8, 0)
    cell_store(g_conc_space_bytes, id * 8, 0)
    cell_store(g_conc_space_in, id * 8, 0)
    cell_store(g_conc_space_out, id * 8, 0)
    g_conc_space_count = id + 1
    return id

fn conc_space_ok(space: int) -> int, pub:
    if space < 0 || space >= g_conc_space_count:
        return 0
    if _conc_is_null(g_conc_space_kind) != 0:
        return 0
    return 1

fn conc_space_kind(space: int) -> int, pub:
    if conc_space_ok(space) == 0:
        return -1
    return cell_load(g_conc_space_kind, space * 8)

fn conc_space_capacity(space: int) -> int, pub:
    if conc_space_ok(space) == 0:
        return -1
    return cell_load(g_conc_space_capacity, space * 8)

fn conc_space_used(space: int) -> int, pub:
    if conc_space_ok(space) == 0:
        return -1
    return cell_load(g_conc_space_used, space * 8)

fn conc_space_bytes(space: int) -> int, pub:
    if conc_space_ok(space) == 0:
        return -1
    return cell_load(g_conc_space_bytes, space * 8)

fn conc_space_region(space: int) -> int, pub:
    if conc_space_ok(space) == 0:
        return -1
    return cell_load(g_conc_space_region, space * 8)

fn conc_space_of_region(region: int) -> int, pub:
    if _conc_is_null(g_conc_space_region) != 0:
        return -1
    i : ., mut = 0
    loop:
        if i >= g_conc_space_count:
            break
        if cell_load(g_conc_space_region, i * 8) == region:
            return i
        i = i + 1
    return -1

fn conc_transfer_bytes() -> int, pub:
    return g_conc_transfer_bytes

fn conc_transfer_count() -> int, pub:
    return g_conc_transfer_count

fn conc_transfer_failures() -> int, pub:
    return g_conc_transfer_failures

fn conc_loan_count() -> int, pub:
    return g_conc_loan_count

fn conc_xfer_move_bytes() -> int, pub:
    return g_conc_xfer_move_bytes

fn conc_xfer_copy_bytes() -> int, pub:
    return g_conc_xfer_copy_bytes

fn conc_xfer_loan_bytes() -> int, pub:
    return g_conc_xfer_loan_bytes

fn conc_xfer_split_bytes() -> int, pub:
    return g_conc_xfer_split_bytes

fn conc_space_in(space: int) -> int, pub:
    if conc_space_ok(space) == 0:
        return -1
    return cell_load(g_conc_space_in, space * 8)

fn conc_space_out(space: int) -> int, pub:
    if conc_space_ok(space) == 0:
        return -1
    return cell_load(g_conc_space_out, space * 8)

fn _conc_xfer_fail() -> string:
    g_conc_transfer_failures = g_conc_transfer_failures + 1
    return _conc_ptr(0)

fn _conc_xfer_fail_i() -> int:
    g_conc_transfer_failures = g_conc_transfer_failures + 1
    return -1

fn _conc_loans_ensure() -> int:
    if _conc_is_null(g_conc_loans_src) != 0:
        g_conc_loans_src = _conc_global_alloc(CONC_MAX_LOANS * 8)
        g_conc_loans_ref = _conc_global_alloc(CONC_MAX_LOANS * 8)
        g_conc_loans_nonce = _conc_global_alloc(CONC_MAX_LOANS * 8)
        if _conc_is_null(g_conc_loans_src) != 0:
            return -1
        if _conc_is_null(g_conc_loans_ref) != 0:
            return -1
        if _conc_is_null(g_conc_loans_nonce) != 0:
            return -1
    return 0

fn _conc_loan_can() -> int:
    if _conc_loans_ensure() != 0:
        return 0
    if g_conc_loan_count >= CONC_MAX_LOANS:
        return 0
    return 1

fn _conc_loan_add(src: string, loan: string) -> int:
    if _conc_loan_can() == 0:
        return 0
    g_conc_loan_seq = g_conc_loan_seq + 1
    nonce := g_conc_loan_seq
    cell_store(src, CONC_REF_NONCE, nonce)
    cell_store(loan, CONC_REF_NONCE, nonce)
    i := g_conc_loan_count
    cell_store(g_conc_loans_src, i * 8, _conc_addr(src))
    cell_store(g_conc_loans_ref, i * 8, _conc_addr(loan))
    cell_store(g_conc_loans_nonce, i * 8, nonce)
    g_conc_loan_count = i + 1
    return nonce

fn _conc_loan_take(src: string, loan: string) -> int:
    if _conc_loans_ensure() != 0:
        return 0
    sa := _conc_addr(src)
    la := _conc_addr(loan)
    nonce := cell_load(src, CONC_REF_NONCE)
    if nonce <= 0:
        return 0
    if cell_load(loan, CONC_REF_NONCE) != nonce:
        return 0
    i : ., mut = 0
    loop:
        if i >= g_conc_loan_count:
            return 0
        if cell_load(g_conc_loans_src, i * 8) == sa:
            if cell_load(g_conc_loans_ref, i * 8) == la:
                if cell_load(g_conc_loans_nonce, i * 8) == nonce:
                    last := g_conc_loan_count - 1
                    if i != last:
                        cell_store(g_conc_loans_src, i * 8,
                                   cell_load(g_conc_loans_src, last * 8))
                        cell_store(g_conc_loans_ref, i * 8,
                                   cell_load(g_conc_loans_ref, last * 8))
                        cell_store(g_conc_loans_nonce, i * 8,
                                   cell_load(g_conc_loans_nonce, last * 8))
                    g_conc_loan_count = last
                    cell_store(src, CONC_REF_NONCE, 0)
                    cell_store(loan, CONC_REF_NONCE, 0)
                    return 1
        i = i + 1
    return 0

fn conc_ref_space(ref: string) -> int, pub:
    if conc_ref_ok(ref) == 0:
        return -1
    return conc_space_of_region(cell_load(ref, 8))

fn conc_ref_alloc_space(space: int, size: int, layout: int) -> string, pub:
    if conc_space_ok(space) == 0:
        return _conc_ptr(0)
    region := cell_load(g_conc_space_region, space * 8)
    ref := conc_ref_alloc(region, size, layout)
    if _conc_is_null(ref) == 0:
        cell_store(g_conc_space_used, space * 8,
                   cell_load(g_conc_space_used, space * 8) + size)
    return ref

fn _conc_space_note_xfer(src_space: int, dst_space: int, size: int,
                         kind: int):
    g_conc_transfer_bytes = g_conc_transfer_bytes + size
    g_conc_transfer_count = g_conc_transfer_count + 1
    if kind == CONC_TRANSFER_MOVE:
        g_conc_xfer_move_bytes = g_conc_xfer_move_bytes + size
    else:
        if kind == CONC_TRANSFER_COPY:
            g_conc_xfer_copy_bytes = g_conc_xfer_copy_bytes + size
        else:
            if kind == CONC_TRANSFER_LOAN:
                g_conc_xfer_loan_bytes = g_conc_xfer_loan_bytes + size
            else:
                if kind == CONC_TRANSFER_SPLIT:
                    g_conc_xfer_split_bytes = g_conc_xfer_split_bytes + size
    if conc_space_ok(dst_space) != 0:
        cell_store(g_conc_space_bytes, dst_space * 8,
                   cell_load(g_conc_space_bytes, dst_space * 8) + size)
        cell_store(g_conc_space_in, dst_space * 8,
                   cell_load(g_conc_space_in, dst_space * 8) + size)
    if conc_space_ok(src_space) != 0:
        cell_store(g_conc_space_bytes, src_space * 8,
                   cell_load(g_conc_space_bytes, src_space * 8) + size)
        cell_store(g_conc_space_out, src_space * 8,
                   cell_load(g_conc_space_out, src_space * 8) + size)

fn _conc_ref_space_xfer(ref: string, dst_space: int, mode: int) -> string:
    if conc_ref_ok(ref) == 0:
        return _conc_xfer_fail()
    if conc_space_ok(dst_space) == 0:
        return _conc_xfer_fail()
    src_space := conc_space_of_region(cell_load(ref, 8))
    if src_space < 0:
        return _conc_xfer_fail()
    size := cell_load(ref, 24)
    layout := cell_load(ref, 32)
    dst := conc_ref_alloc_space(dst_space, size, layout)
    if _conc_is_null(dst) != 0:
        return _conc_xfer_fail()
    _conc_copy(conc_ref_payload(dst), conc_ref_payload(ref), size)
    if mode == CONC_TRANSFER_MOVE || mode == CONC_TRANSFER_LOAN:
        magic : ., mut = CONC_REF_LOAN_MAGIC
        if mode == CONC_TRANSFER_MOVE:
            magic = CONC_REF_MOVED_MAGIC
        _conc_ref_invalidate(ref, magic)
    _conc_space_note_xfer(src_space, dst_space, size, mode)
    return dst

fn conc_space_move(ref: string, dst_space: int) -> string, pub:
    return _conc_ref_space_xfer(ref, dst_space, CONC_TRANSFER_MOVE)

fn conc_space_copy(ref: string, dst_space: int) -> string, pub:
    return _conc_ref_space_xfer(ref, dst_space, CONC_TRANSFER_COPY)

fn conc_space_loan(ref: string, dst_space: int) -> string, pub:
    if _conc_loan_can() == 0:
        return _conc_xfer_fail()
    out := _conc_ref_space_xfer(ref, dst_space, CONC_TRANSFER_LOAN)
    if _conc_is_null(out) != 0:
        return _conc_ptr(0)
    if _conc_loan_add(ref, out) == 0:
        // The transfer already invalidated the source. Keep the loan usable
        // rather than losing the payload, but report the bookkeeping failure.
        g_conc_transfer_failures = g_conc_transfer_failures + 1
    return out

fn conc_space_return(src_ref: string, loan: string) -> int, pub:
    // Return a loan from its device/remote space to the source space.
    if _conc_is_null(src_ref) != 0:
        return _conc_xfer_fail_i()
    if cell_load(src_ref, 0) != CONC_REF_LOAN_MAGIC:
        return _conc_xfer_fail_i()
    if conc_ref_ok(loan) == 0:
        return _conc_xfer_fail_i()
    size := cell_load(src_ref, 24)
    if cell_load(loan, 24) != size:
        return _conc_xfer_fail_i()
    rid := cell_load(src_ref, 8)
    if _conc_region_valid(rid) == 0:
        return _conc_xfer_fail_i()
    if cell_load(src_ref, 40) != cell_load(g_conc_region_epoch, rid * 8):
        return _conc_xfer_fail_i()
    if _conc_loan_take(src_ref, loan) == 0:
        return _conc_xfer_fail_i()
    base := load_str_ptr(g_conc_region_block, rid * 8)
    dst := _conc_ptr(_conc_addr(base) + cell_load(src_ref, 16))
    _conc_copy(dst, conc_ref_payload(loan), size)
    cell_store(src_ref, 0, CONC_REF_MAGIC)
    src_space := conc_space_of_region(rid)
    loan_space := conc_space_of_region(cell_load(loan, 8))
    _conc_space_note_xfer(loan_space, src_space, size, CONC_TRANSFER_LOAN)
    return 0

fn conc_space_fill(space: int, size: int, layout: int) -> string, pub:
    return conc_ref_alloc_space(space, size, layout)

fn conc_space_copy_set(ref: string, dst_space: int) -> string, pub:
    // Cross-space CopySet: allocate the destination in the target space, zero
    // fields outside the declared layout, then copy only declared fields.
    if conc_ref_ok(ref) == 0:
        return _conc_xfer_fail()
    if conc_space_ok(dst_space) == 0:
        return _conc_xfer_fail()
    size := cell_load(ref, 24)
    layout := cell_load(ref, 32)
    src_space := conc_space_of_region(cell_load(ref, 8))
    dst := conc_ref_alloc_space(dst_space, size, layout)
    if _conc_is_null(dst) != 0:
        return _conc_xfer_fail()
    sp := conc_ref_payload(ref)
    dp := conc_ref_payload(dst)
    nf : ., mut = 0
    if conc_layout_ok(layout) != 0:
        nf = cell_load(g_conc_layout_field_count, layout * 8)
    if nf <= 0:
        _conc_copy(dp, sp, size)
        _conc_space_note_xfer(src_space, dst_space, size, CONC_TRANSFER_COPY)
        return dst
    zi : ., mut = 0
    loop:
        if zi >= size:
            break
        store8(dp, zi, 0)
        zi = zi + 1
    copied : ., mut = 0
    i : ., mut = 0
    loop:
        if i >= nf:
            break
        off := conc_layout_field_offset(layout, i)
        fsz := conc_layout_field_size(layout, i)
        if off >= 0 && fsz > 0:
            _conc_copy(_conc_ptr(_conc_addr(dp) + off),
                       _conc_ptr(_conc_addr(sp) + off), fsz)
            copied = copied + fsz
        i = i + 1
    _conc_space_note_xfer(src_space, dst_space, copied, CONC_TRANSFER_COPY)
    return dst

fn conc_space_move_set(ref: string, dst_space: int) -> string, pub:
    if conc_ref_ok(ref) == 0:
        return _conc_xfer_fail()
    if conc_space_ok(dst_space) == 0:
        return _conc_xfer_fail()
    size := cell_load(ref, 24)
    layout := cell_load(ref, 32)
    src_space := conc_space_of_region(cell_load(ref, 8))
    dst := conc_ref_alloc_space(dst_space, size, layout)
    if _conc_is_null(dst) != 0:
        return _conc_xfer_fail()
    sp := conc_ref_payload(ref)
    dp := conc_ref_payload(dst)
    nf : ., mut = 0
    if conc_layout_ok(layout) != 0:
        nf = cell_load(g_conc_layout_field_count, layout * 8)
    copied : ., mut = 0
    if nf <= 0:
        _conc_copy(dp, sp, size)
        copied = size
    else:
        zi : ., mut = 0
        loop:
            if zi >= size:
                break
            store8(dp, zi, 0)
            zi = zi + 1
        i : ., mut = 0
        loop:
            if i >= nf:
                break
            off := conc_layout_field_offset(layout, i)
            fsz := conc_layout_field_size(layout, i)
            if off >= 0 && fsz > 0:
                _conc_copy(_conc_ptr(_conc_addr(dp) + off),
                           _conc_ptr(_conc_addr(sp) + off), fsz)
                copied = copied + fsz
            i = i + 1
    _conc_ref_invalidate(ref, CONC_REF_MOVED_MAGIC)
    _conc_space_note_xfer(src_space, dst_space, copied, CONC_TRANSFER_MOVE)
    return dst

fn conc_space_split_part(ref: string, dst_space: int, index: int,
                         count: int) -> string, pub:
    if conc_ref_ok(ref) == 0:
        return _conc_xfer_fail()
    if conc_space_ok(dst_space) == 0:
        return _conc_xfer_fail()
    if index < 0 || count <= 0 || index >= count:
        return _conc_xfer_fail()
    total := cell_load(ref, 24)
    part : ., mut = total / count
    if index == count - 1:
        part = total - part * (count - 1)
    layout := cell_load(ref, 32)
    src := conc_ref_payload(ref)
    dst := conc_ref_alloc_space(dst_space, part, layout)
    if _conc_is_null(dst) != 0:
        return _conc_xfer_fail()
    s := _conc_ptr(_conc_addr(src) + index * (total / count))
    _conc_copy(conc_ref_payload(dst), s, part)
    if index == count - 1:
        _conc_ref_invalidate(ref, CONC_REF_MOVED_MAGIC)
    src_space := conc_space_of_region(cell_load(ref, 8))
    _conc_space_note_xfer(src_space, dst_space, part, CONC_TRANSFER_SPLIT)
    return dst

fn conc_ref_alloc(region: int, size: int, layout: int) -> string, pub:
    if _conc_region_valid(region) == 0:
        return _conc_ptr(0)
    p := conc_alloc(region, size)
    if _conc_is_null(p) != 0:
        return _conc_ptr(0)
    base := load_str_ptr(g_conc_region_block, region * 8)
    off := _conc_addr(p) - _conc_addr(base)
    ref := _conc_global_alloc(CONC_REF_SIZE)
    if _conc_is_null(ref) != 0:
        return _conc_ptr(0)
    cell_store(ref, 0, CONC_REF_MAGIC)
    cell_store(ref, 8, region)
    cell_store(ref, 16, off)
    cell_store(ref, 24, size)
    cell_store(ref, 32, layout)
    cell_store(ref, 40, cell_load(g_conc_region_epoch, region * 8))
    return ref

fn conc_ref_ok(ref: string) -> int, pub:
    if _conc_is_null(ref) != 0:
        return 0
    if cell_load(ref, 0) != CONC_REF_MAGIC:
        return 0
    rid := cell_load(ref, 8)
    if _conc_region_valid(rid) == 0:
        return 0
    if cell_load(ref, 40) != cell_load(g_conc_region_epoch, rid * 8):
        return 0
    off := cell_load(ref, 16)
    sz := cell_load(ref, 24)
    if off < CONC_MSG_HEADER:
        return 0
    if sz <= 0:
        return 0
    cap := cell_load(g_conc_region_cap, rid * 8)
    if sz > cap:
        return 0
    if off > cap - sz:
        return 0
    base := load_str_ptr(g_conc_region_block, rid * 8)
    p := _conc_ptr(_conc_addr(base) + off)
    if _conc_header_ok(p) == 0:
        return 0
    if _conc_msg_size(p) != sz:
        return 0
    return 1

fn conc_ref_payload(ref: string) -> string, pub:
    if conc_ref_ok(ref) == 0:
        return _conc_ptr(0)
    rid := cell_load(ref, 8)
    off := cell_load(ref, 16)
    base := load_str_ptr(g_conc_region_block, rid * 8)
    return _conc_ptr(_conc_addr(base) + off)

fn conc_ref_region(ref: string) -> int, pub:
    if _conc_is_null(ref) != 0:
        return -1
    return cell_load(ref, 8)

fn conc_ref_offset(ref: string) -> int, pub:
    if _conc_is_null(ref) != 0:
        return -1
    return cell_load(ref, 16)

fn conc_ref_size(ref: string) -> int, pub:
    if _conc_is_null(ref) != 0:
        return -1
    return cell_load(ref, 24)

fn conc_ref_layout(ref: string) -> int, pub:
    if _conc_is_null(ref) != 0:
        return -1
    return cell_load(ref, 32)

fn conc_layout_declare(layout: int, size: int, hash: int) -> int, pub:
    if layout < 0 || layout >= CONC_MAX_LAYOUTS:
        return -1
    if size <= 0:
        return -1
    if _conc_is_null(g_conc_layout_size) != 0:
        g_conc_layout_size = _conc_global_alloc(CONC_MAX_LAYOUTS * 8)
        g_conc_layout_hash = _conc_global_alloc(CONC_MAX_LAYOUTS * 8)
        g_conc_layout_fields = _conc_global_alloc(CONC_MAX_LAYOUTS * CONC_MAX_LAYOUT_FIELDS * 16)
        g_conc_layout_field_count = _conc_global_alloc(CONC_MAX_LAYOUTS * 8)
        if _conc_is_null(g_conc_layout_size) != 0:
            return -1
        if _conc_is_null(g_conc_layout_hash) != 0:
            return -1
        if _conc_is_null(g_conc_layout_fields) != 0:
            return -1
        if _conc_is_null(g_conc_layout_field_count) != 0:
            return -1
    cell_store(g_conc_layout_size, layout * 8, size)
    cell_store(g_conc_layout_hash, layout * 8, hash)
    if layout >= g_conc_layout_count:
        g_conc_layout_count = layout + 1
    return layout

fn conc_layout_ok(layout: int) -> int, pub:
    if layout < 0 || layout >= CONC_MAX_LAYOUTS:
        return 0
    if _conc_is_null(g_conc_layout_size) != 0:
        return 0
    if cell_load(g_conc_layout_size, layout * 8) <= 0:
        return 0
    return 1

fn conc_layout_size(layout: int) -> int, pub:
    if conc_layout_ok(layout) == 0:
        return -1
    return cell_load(g_conc_layout_size, layout * 8)

fn conc_layout_hash(layout: int) -> int, pub:
    if conc_layout_ok(layout) == 0:
        return -1
    return cell_load(g_conc_layout_hash, layout * 8)

fn conc_layout_count() -> int, pub:
    return g_conc_layout_count

fn conc_layout_table_version() -> int, pub:
    return g_conc_layout_version

fn conc_layout_set_version(v: int) -> int, pub:
    if v < g_conc_layout_version:
        return -1
    g_conc_layout_version = v
    return v

fn conc_layout_add_field(layout: int, offset: int, size: int) -> int, pub:
    if conc_layout_ok(layout) == 0:
        return -1
    if offset < 0 || size <= 0:
        return -1
    if offset + size > conc_layout_size(layout):
        return -1
    n := cell_load(g_conc_layout_field_count, layout * 8)
    if n >= CONC_MAX_LAYOUT_FIELDS:
        return -1
    base := (layout * CONC_MAX_LAYOUT_FIELDS + n) * 16
    cell_store(g_conc_layout_fields, base, offset)
    cell_store(g_conc_layout_fields, base + 8, size)
    cell_store(g_conc_layout_field_count, layout * 8, n + 1)
    return n

fn conc_layout_field_count(layout: int) -> int, pub:
    if conc_layout_ok(layout) == 0:
        return -1
    return cell_load(g_conc_layout_field_count, layout * 8)

fn conc_layout_field_offset(layout: int, i: int) -> int, pub:
    if conc_layout_ok(layout) == 0:
        return -1
    n := cell_load(g_conc_layout_field_count, layout * 8)
    if i < 0 || i >= n:
        return -1
    return cell_load(g_conc_layout_fields, (layout * CONC_MAX_LAYOUT_FIELDS + i) * 16)

fn conc_layout_field_size(layout: int, i: int) -> int, pub:
    if conc_layout_ok(layout) == 0:
        return -1
    n := cell_load(g_conc_layout_field_count, layout * 8)
    if i < 0 || i >= n:
        return -1
    return cell_load(g_conc_layout_fields, (layout * CONC_MAX_LAYOUT_FIELDS + i) * 16 + 8)

fn conc_ref_copy_set(ref: string, dst_region: int) -> string, pub:
    // Copy only the declared CopySet fields. A layout with no fields falls back
    // to a full payload copy (the conservative behavior).
    if conc_ref_ok(ref) == 0:
        return _conc_ptr(0)
    if _conc_region_valid(dst_region) == 0:
        return _conc_ptr(0)
    size := cell_load(ref, 24)
    layout := cell_load(ref, 32)
    src := conc_ref_payload(ref)
    dst := conc_ref_alloc(dst_region, size, layout)
    if _conc_is_null(dst) != 0:
        return _conc_ptr(0)
    dp := conc_ref_payload(dst)
    nf : ., mut = 0
    if conc_layout_ok(layout) != 0:
        nf = cell_load(g_conc_layout_field_count, layout * 8)
    if nf <= 0:
        _conc_copy(dp, src, size)
        return dst
    // CopySet semantics leave non-copied fields undefined; this CPU mapping
    // zeroes them so the result is deterministic.
    zi : ., mut = 0
    loop:
        if zi >= size:
            break
        store8(dp, zi, 0)
        zi = zi + 1
    i : ., mut = 0
    loop:
        if i >= nf:
            break
        off := conc_layout_field_offset(layout, i)
        fsz := conc_layout_field_size(layout, i)
        if off >= 0 && fsz > 0:
            _conc_copy(_conc_ptr(_conc_addr(dp) + off),
                       _conc_ptr(_conc_addr(src) + off), fsz)
        i = i + 1
    return dst

fn conc_ref_move_set(ref: string, dst_region: int) -> string, pub:
    dst := conc_ref_copy_set(ref, dst_region)
    if _conc_is_null(dst) != 0:
        return _conc_ptr(0)
    _conc_ref_invalidate(ref, CONC_REF_MOVED_MAGIC)
    return dst

fn conc_ref_layout_check(ref: string) -> int, pub:
    if conc_ref_ok(ref) == 0:
        return 0
    layout := cell_load(ref, 32)
    if conc_layout_ok(layout) == 0:
        return 0
    if conc_layout_size(layout) != cell_load(ref, 24):
        return 0
    return 1

fn _conc_ref_invalidate(ref: string, magic: int):
    cell_store(ref, 0, magic)

fn conc_ref_move(ref: string, dst_region: int) -> string, pub:
    if conc_ref_ok(ref) == 0:
        return _conc_ptr(0)
    if _conc_region_valid(dst_region) == 0:
        return _conc_ptr(0)
    size := cell_load(ref, 24)
    layout := cell_load(ref, 32)
    src := conc_ref_payload(ref)
    dst := conc_ref_alloc(dst_region, size, layout)
    if _conc_is_null(dst) != 0:
        return _conc_ptr(0)
    _conc_copy(conc_ref_payload(dst), src, size)
    _conc_ref_invalidate(ref, CONC_REF_MOVED_MAGIC)
    return dst

fn conc_ref_copy(ref: string, dst_region: int) -> string, pub:
    if conc_ref_ok(ref) == 0:
        return _conc_ptr(0)
    if _conc_region_valid(dst_region) == 0:
        return _conc_ptr(0)
    size := cell_load(ref, 24)
    layout := cell_load(ref, 32)
    src := conc_ref_payload(ref)
    dst := conc_ref_alloc(dst_region, size, layout)
    if _conc_is_null(dst) != 0:
        return _conc_ptr(0)
    _conc_copy(conc_ref_payload(dst), src, size)
    return dst

fn conc_ref_loan(ref: string, dst_region: int) -> string, pub:
    if conc_ref_ok(ref) == 0:
        return _conc_xfer_fail()
    if _conc_region_valid(dst_region) == 0:
        return _conc_xfer_fail()
    if _conc_loan_can() == 0:
        return _conc_xfer_fail()
    size := cell_load(ref, 24)
    layout := cell_load(ref, 32)
    src := conc_ref_payload(ref)
    dst := conc_ref_alloc(dst_region, size, layout)
    if _conc_is_null(dst) != 0:
        return _conc_ptr(0)
    _conc_copy(conc_ref_payload(dst), src, size)
    _conc_ref_invalidate(ref, CONC_REF_LOAN_MAGIC)
    if _conc_loan_add(ref, dst) == 0:
        g_conc_transfer_failures = g_conc_transfer_failures + 1
    return dst

fn conc_ref_return(src_ref: string, loan: string) -> int, pub:
    if _conc_is_null(src_ref) != 0:
        return _conc_xfer_fail_i()
    if cell_load(src_ref, 0) != CONC_REF_LOAN_MAGIC:
        return _conc_xfer_fail_i()
    if conc_ref_ok(loan) == 0:
        return _conc_xfer_fail_i()
    size := cell_load(src_ref, 24)
    if cell_load(loan, 24) != size:
        return _conc_xfer_fail_i()
    rid := cell_load(src_ref, 8)
    if _conc_region_valid(rid) == 0:
        return _conc_xfer_fail_i()
    if cell_load(src_ref, 40) != cell_load(g_conc_region_epoch, rid * 8):
        return _conc_xfer_fail_i()
    if _conc_loan_take(src_ref, loan) == 0:
        return _conc_xfer_fail_i()
    base := load_str_ptr(g_conc_region_block, rid * 8)
    dst := _conc_ptr(_conc_addr(base) + cell_load(src_ref, 16))
    _conc_copy(dst, conc_ref_payload(loan), size)
    cell_store(src_ref, 0, CONC_REF_MAGIC)
    return 0

fn conc_ref_split_part(ref: string, dst_region: int, index: int,
                       count: int) -> string, pub:
    if conc_ref_ok(ref) == 0:
        return _conc_ptr(0)
    if index < 0 || count <= 0 || index >= count:
        return _conc_ptr(0)
    if _conc_region_valid(dst_region) == 0:
        return _conc_ptr(0)
    total := cell_load(ref, 24)
    part : ., mut = total / count
    if index == count - 1:
        part = total - part * (count - 1)
    layout := cell_load(ref, 32)
    src := conc_ref_payload(ref)
    dst := conc_ref_alloc(dst_region, part, layout)
    if _conc_is_null(dst) != 0:
        return _conc_ptr(0)
    s := _conc_ptr(_conc_addr(src) + index * (total / count))
    _conc_copy(conc_ref_payload(dst), s, part)
    if index == count - 1:
        _conc_ref_invalidate(ref, CONC_REF_MOVED_MAGIC)
    return dst

fn conc_ref_fill(dst_region: int, size: int, layout: int) -> string, pub:
    // Reserve the target; the producer constructs the payload through
    // conc_ref_payload(ref).
    return conc_ref_alloc(dst_region, size, layout)

fn conc_same(a: string, b: string) -> int, pub:
    if _conc_addr(a) == _conc_addr(b):
        return 1
    return 0

fn _conc_msg_size(p: string) -> int:
    // Only called after _conc_header_ok/_conc_msg_valid has accepted p.
    a := _conc_addr(p)
    if a < CONC_MSG_HEADER:
        return -1
    hdr := _conc_ptr(a - CONC_MSG_HEADER)
    return cell_load(hdr, 24) - 1

// A message is valid only while its owner region is live, its epoch matches,
// and its stated size fits inside that region. region_reset advances the
// epoch, so stale payload pointers stop being accepted by send/recv.
fn _conc_msg_valid(p: string) -> int:
    return _conc_header_ok(p)

// ── Typed channel ─────────────────────────────────────────────────────────
//
// Channel header (64 bytes):
//   0 magic, 8 buf, 16 cap, 24 len, 32 head, 40 esize,
//   48 owner_region, 56 owner_epoch.
// The buffer is the payload tail after the 64-byte header.

fn _conc_channel_valid_magic(ch: string, magic: int) -> int:
    if _conc_msg_valid(ch) == 0:
        return 0
    if cell_load(ch, 0) != magic:
        return 0
    rid := cell_load(ch, 48)
    if _conc_region_valid(rid) == 0:
        return 0
    if cell_load(ch, 56) != cell_load(g_conc_region_epoch, rid * 8):
        return 0
    esize := cell_load(ch, 40)
    if esize <= 0:
        return 0
    cap := cell_load(ch, 16)
    if cap < 0:
        return 0
    n := cell_load(ch, 24)
    if n < 0:
        return 0
    if n > cap:
        return 0
    head := cell_load(ch, 32)
    if head < 0:
        return 0
    if cap > 0:
        if head >= cap:
            return 0
    else:
        if head != 0:
            return 0
    buf := load_str_ptr(ch, 8)
    b := _conc_addr(buf)
    if b == 0:
        return 0
    if b != _conc_addr(ch) + 64:
        return 0
    total := _conc_msg_size(ch)
    if total < 64:
        return 0
    if cap > (total - 64) / esize:
        return 0
    return 1

fn _conc_channel_valid(ch: string) -> int:
    return _conc_channel_valid_magic(ch, CONC_CHANNEL_MAGIC)

fn _conc_ref_channel_valid(ch: string) -> int:
    return _conc_channel_valid_magic(ch, CONC_CHANNEL_REF_MAGIC)

fn conc_channel_new(region: int, elem_size: int, cap: int) -> string, pub:
    if _conc_region_valid(region) == 0:
        return _conc_ptr(0)
    if elem_size <= 0:
        return _conc_ptr(0)
    if cap < 0:
        return _conc_ptr(0)
    if cap > CONC_MAX_ALLOC:
        return _conc_ptr(0)
    total : ., mut = 64
    if cap > 0:
        if elem_size > CONC_MAX_ALLOC / cap:
            return _conc_ptr(0)
        total = 64 + cap * elem_size
    if total > CONC_MAX_ALLOC:
        return _conc_ptr(0)
    ch := conc_alloc(region, total)
    if _conc_is_null(ch) != 0:
        return _conc_ptr(0)
    buf := _conc_ptr(_conc_addr(ch) + 64)
    cell_store(ch, 0, CONC_CHANNEL_MAGIC)
    store_str_ptr(ch, 8, buf)
    cell_store(ch, 16, cap)
    cell_store(ch, 24, 0)
    cell_store(ch, 32, 0)
    cell_store(ch, 40, elem_size)
    cell_store(ch, 48, region)
    cell_store(ch, 56, cell_load(g_conc_region_epoch, region * 8))
    return ch

fn conc_channel_len(ch: string) -> int, pub:
    if _conc_channel_valid(ch) == 0:
        return -1
    return cell_load(ch, 24)

fn conc_channel_elemsize(ch: string) -> int, pub:
    if _conc_channel_valid(ch) == 0:
        return -1
    return cell_load(ch, 40)

fn conc_channel_new_ref(region: int, cap: int) -> string, pub:
    ch := conc_channel_new(region, CONC_REF_SIZE, cap)
    if _conc_is_null(ch) != 0:
        return _conc_ptr(0)
    cell_store(ch, 0, CONC_CHANNEL_REF_MAGIC)
    return ch

fn conc_channel_is_ref(ch: string) -> int, pub:
    if _conc_ref_channel_valid(ch) != 0:
        return 1
    return 0

fn conc_send_ref(ch: string, ref: string) -> int, pub:
    g_conc_last_error = CONC_ERR_INVALID
    if _conc_ref_channel_valid(ch) == 0:
        return CONC_ERR_INVALID
    if conc_ref_ok(ref) == 0:
        return CONC_ERR_INVALID
    cap := cell_load(ch, 16)
    n := cell_load(ch, 24)
    if n >= cap:
        g_conc_last_error = CONC_ERR_FULL
        return CONC_ERR_FULL
    head := cell_load(ch, 32)
    buf := load_str_ptr(ch, 8)
    slot : ., mut = head + n
    if slot >= cap:
        slot = slot - cap
    dst := _conc_ptr(_conc_addr(buf) + slot * CONC_REF_SIZE)
    _conc_copy(dst, ref, CONC_REF_SIZE)
    cell_store(ch, 24, n + 1)
    g_conc_last_error = CONC_OK
    return CONC_OK

fn conc_recv_ref(ch: string) -> string, pub:
    g_conc_last_error = CONC_ERR_INVALID
    if _conc_ref_channel_valid(ch) == 0:
        return _conc_ptr(0)
    n := cell_load(ch, 24)
    if n <= 0:
        g_conc_last_error = CONC_ERR_EMPTY
        return _conc_ptr(0)
    out := _conc_global_alloc(CONC_REF_SIZE)
    if _conc_is_null(out) != 0:
        g_conc_last_error = CONC_ERR_NOMEM
        return _conc_ptr(0)
    head : ., mut = cell_load(ch, 32)
    buf := load_str_ptr(ch, 8)
    src := _conc_ptr(_conc_addr(buf) + head * CONC_REF_SIZE)
    _conc_copy(out, src, CONC_REF_SIZE)
    head = head + 1
    if head >= cell_load(ch, 16):
        head = 0
    cell_store(ch, 32, head)
    cell_store(ch, 24, n - 1)
    if conc_ref_ok(out) == 0:
        g_conc_last_error = CONC_ERR_INVALID
        return _conc_ptr(0)
    g_conc_last_error = CONC_OK
    return out

fn conc_send(ch: string, msg: string) -> int, pub:
    g_conc_last_error = CONC_ERR_INVALID
    if _conc_channel_valid(ch) == 0:
        return CONC_ERR_INVALID
    if _conc_msg_valid(msg) == 0:
        return CONC_ERR_INVALID
    esize := cell_load(ch, 40)
    if _conc_msg_size(msg) != esize:
        return CONC_ERR_INVALID
    cap := cell_load(ch, 16)
    n := cell_load(ch, 24)
    if n >= cap:
        g_conc_last_error = CONC_ERR_FULL
        return CONC_ERR_FULL
    head := cell_load(ch, 32)
    buf := load_str_ptr(ch, 8)
    slot : ., mut = head + n
    if slot >= cap:
        slot = slot - cap
    dst := _conc_ptr(_conc_addr(buf) + slot * esize)
    _conc_copy(dst, msg, esize)
    cell_store(ch, 24, n + 1)
    g_conc_last_error = CONC_OK
    return CONC_OK

fn conc_recv(ch: string) -> string, pub:
    g_conc_last_error = CONC_ERR_INVALID
    if _conc_channel_valid(ch) == 0:
        return _conc_ptr(0)
    n := cell_load(ch, 24)
    if n <= 0:
        g_conc_last_error = CONC_ERR_EMPTY
        return _conc_ptr(0)
    esize := cell_load(ch, 40)
    rid := cell_load(ch, 48)
    out := conc_alloc(rid, esize)
    if _conc_is_null(out) != 0:
        g_conc_last_error = CONC_ERR_NOMEM
        return _conc_ptr(0)
    head : ., mut = cell_load(ch, 32)
    buf := load_str_ptr(ch, 8)
    src := _conc_ptr(_conc_addr(buf) + head * esize)
    _conc_copy(out, src, esize)
    head = head + 1
    if head >= cell_load(ch, 16):
        head = 0
    cell_store(ch, 32, head)
    cell_store(ch, 24, n - 1)
    g_conc_last_error = CONC_OK
    return out

// ── Fixture plan ──────────────────────────────────────────────────────────
//
// Plan record (80 bytes):
//   0 body_count, 8 channel_count, 16 edge_count,
//   24 body_cap, 32 channel_cap, 40 edge_cap,
//   48 body_base, 56 channel_base, 64 edge_base, 72 reserved.
// Body/channel/edge records are 32 bytes each and contain structure only:
// no CPU/GPU/slot/memory values.

fn _conc_plan_ensure(needed: int) -> int:
    if needed <= g_conc_plan_array_cap:
        return 0
    nc : ., mut = g_conc_plan_array_cap * 2
    if nc < 8:
        nc = 8
    if nc < needed:
        nc = needed + 8
    nb := _conc_global_alloc(nc * 8)
    if _conc_is_null(nb) != 0:
        return -1
    if g_conc_plan_array_cap > 0:
        _conc_copy(nb, g_conc_plans, g_conc_plan_array_cap * 8)
    g_conc_plans = nb
    g_conc_plan_array_cap = nc
    return 0

fn _conc_plan_valid(plan: int) -> int:
    if plan < 0:
        return 0
    if plan >= g_conc_plan_count:
        return 0
    p := load_str_ptr(g_conc_plans, plan * 8)
    if _conc_is_null(p) != 0:
        return 0
    return 1

fn _conc_plan_at(plan: int) -> string:
    if _conc_plan_valid(plan) == 0:
        return _conc_ptr(0)
    return load_str_ptr(g_conc_plans, plan * 8)

fn _conc_plan_grow_bodies(p: string, cap: int) -> int:
    nc : ., mut = cap * 2
    if nc < 8:
        nc = 8
    nb := _conc_global_alloc(nc * 32)
    if _conc_is_null(nb) != 0:
        return -1
    old := load_str_ptr(p, 48)
    if _conc_is_null(old) == 0:
        _conc_copy(nb, old, cell_load(p, 0) * 32)
    store_str_ptr(p, 48, nb)
    cell_store(p, 24, nc)
    return 0

fn _conc_plan_grow_channels(p: string, cap: int) -> int:
    nc : ., mut = cap * 2
    if nc < 8:
        nc = 8
    nb := _conc_global_alloc(nc * 32)
    if _conc_is_null(nb) != 0:
        return -1
    old := load_str_ptr(p, 56)
    if _conc_is_null(old) == 0:
        _conc_copy(nb, old, cell_load(p, 8) * 32)
    store_str_ptr(p, 56, nb)
    cell_store(p, 32, nc)
    return 0

fn _conc_plan_grow_edges(p: string, cap: int) -> int:
    nc : ., mut = cap * 2
    if nc < 8:
        nc = 8
    nb := _conc_global_alloc(nc * 32)
    if _conc_is_null(nb) != 0:
        return -1
    old := load_str_ptr(p, 64)
    if _conc_is_null(old) == 0:
        _conc_copy(nb, old, cell_load(p, 16) * 32)
    store_str_ptr(p, 64, nb)
    cell_store(p, 40, nc)
    return 0

fn conc_plan_new() -> int, pub:
    if _conc_plan_ensure(g_conc_plan_count + 1) != 0:
        return -1
    // v2 record: the v1 fields stay at 0..72, new sidecar fields follow.
    p := _conc_global_alloc(256)
    if _conc_is_null(p) != 0:
        return -1
    bodies := _conc_global_alloc(8 * 32)
    channels := _conc_global_alloc(8 * 32)
    edges := _conc_global_alloc(8 * 32)
    binds := _conc_global_alloc(16 + CONC_MAX_BINDS * 24)
    ranges := _conc_global_alloc(64 * 32)
    slots := _conc_global_alloc(64 * 32)
    transfers := _conc_global_alloc(64 * 40)
    budgets := _conc_global_alloc(64 * 40)
    certs := _conc_global_alloc(64 * 32)
    stages := _conc_global_alloc(64 * 32)
    plan_layouts := _conc_global_alloc(64 * 32)
    plan_spaces := _conc_global_alloc(CONC_MAX_SPACES * 32)
    plan_xfers := _conc_global_alloc(64 * 56)
    if _conc_is_null(bodies) != 0:
        return -1
    if _conc_is_null(channels) != 0:
        return -1
    if _conc_is_null(edges) != 0:
        return -1
    if _conc_is_null(binds) != 0:
        return -1
    if _conc_is_null(ranges) != 0:
        return -1
    if _conc_is_null(slots) != 0:
        return -1
    if _conc_is_null(transfers) != 0:
        return -1
    if _conc_is_null(budgets) != 0:
        return -1
    if _conc_is_null(certs) != 0:
        return -1
    if _conc_is_null(stages) != 0:
        return -1
    if _conc_is_null(plan_layouts) != 0:
        return -1
    if _conc_is_null(plan_spaces) != 0:
        return -1
    if _conc_is_null(plan_xfers) != 0:
        return -1
    store_str_ptr(p, 48, bodies)
    store_str_ptr(p, 56, channels)
    store_str_ptr(p, 64, edges)
    store_str_ptr(p, 72, binds)
    store_str_ptr(p, 88, "")
    store_str_ptr(p, 136, ranges)
    store_str_ptr(p, 144, slots)
    store_str_ptr(p, 152, transfers)
    store_str_ptr(p, 160, budgets)
    store_str_ptr(p, 168, certs)
    store_str_ptr(p, 200, stages)
    store_str_ptr(p, 216, plan_layouts)
    store_str_ptr(p, 232, plan_spaces)
    store_str_ptr(p, 248, plan_xfers)
    cell_store(p, 192, 0)     // stage_count
    cell_store(p, 208, 0)     // plan layout_count
    cell_store(p, 224, 0)     // plan space_count
    cell_store(p, 240, 0)     // plan xfer_count
    cell_store(p, 80, 1)      // version
    cell_store(p, 96, 0)      // slot_count
    cell_store(p, 104, 0)     // range_count
    cell_store(p, 112, 0)     // transfer_count
    cell_store(p, 120, 0)     // budget_count
    cell_store(p, 128, 0)     // cert_count
    cell_store(p, 176, 0)     // target slots
    cell_store(p, 184, 0)     // target memory spaces
    cell_store(p, 24, 8)
    cell_store(p, 32, 8)
    cell_store(p, 40, 8)
    cell_store(binds, 0, 0)
    cell_store(binds, 8, CONC_MAX_BINDS)
    id := g_conc_plan_count
    store_str_ptr(g_conc_plans, id * 8, p)
    g_conc_plan_count = id + 1
    return id

fn conc_plan_add_body(plan: int, kind: int, entry: int, params: int) -> int, pub:
    if _conc_plan_valid(plan) == 0:
        return -1
    if kind != CONC_BODY_TASK && kind != CONC_BODY_DATA_PARALLEL && kind != CONC_BODY_PIPELINE:
        return -1
    if entry < 0:
        return -1
    if params < 0:
        return -1
    // CP-1 host TASK entries take zero or one argument. More parameters need
    // a param layout/lowering step that belongs to CP-2.
    if kind == CONC_BODY_TASK && params > 1:
        return -1
    if kind == CONC_BODY_PIPELINE && params > 1:
        return -1
    p := _conc_plan_at(plan)
    n := cell_load(p, 0)
    cap := cell_load(p, 24)
    if n >= cap:
        if _conc_plan_grow_bodies(p, cap) != 0:
            return -1
    base := load_str_ptr(p, 48)
    off := n * 32
    cell_store(base, off, kind)
    cell_store(base, off + 8, entry)
    cell_store(base, off + 16, params)
    cell_store(base, off + 24, 0)
    cell_store(p, 0, n + 1)
    return n

fn conc_plan_add_channel(plan: int, elem_size: int, cap: int, pc: int) -> int, pub:
    if _conc_plan_valid(plan) == 0:
        return -1
    if elem_size <= 0:
        return -1
    if cap < 0:
        return -1
    if pc == CONC_PC_SPSC && cap <= 0:
        return -1
    if pc != CONC_PC_SPSC && pc != CONC_PC_MPMC:
        return -1
    if elem_size > CONC_MAX_ALLOC:
        return -1
    if cap > CONC_MAX_ALLOC:
        return -1
    p := _conc_plan_at(plan)
    n := cell_load(p, 8)
    cc := cell_load(p, 32)
    if n >= cc:
        if _conc_plan_grow_channels(p, cc) != 0:
            return -1
    base := load_str_ptr(p, 56)
    off := n * 32
    cell_store(base, off, elem_size)
    cell_store(base, off + 8, cap)
    cell_store(base, off + 16, pc)
    cell_store(base, off + 24, 0)
    cell_store(p, 8, n + 1)
    return n

fn _conc_plan_add_edge_ch(plan: int, from_body: int, to_body: int, kind: int, channel: int) -> int:
    if _conc_plan_valid(plan) == 0:
        return -1
    p := _conc_plan_at(plan)
    n := cell_load(p, 16)
    if from_body < 0 || from_body >= cell_load(p, 0):
        return -1
    if to_body < 0 || to_body >= cell_load(p, 0):
        return -1
    if kind != CONC_EDGE_SPAWN && kind != CONC_EDGE_SEND && kind != CONC_EDGE_JOIN && kind != CONC_EDGE_RECV:
        return -1
    if channel < -1:
        return -1
    ec := cell_load(p, 40)
    if n >= ec:
        if _conc_plan_grow_edges(p, ec) != 0:
            return -1
    base := load_str_ptr(p, 64)
    off := n * 32
    cell_store(base, off, from_body)
    cell_store(base, off + 8, to_body)
    cell_store(base, off + 16, kind)
    cell_store(base, off + 24, channel)
    cell_store(p, 16, n + 1)
    return n

fn conc_plan_add_edge(plan: int, from_body: int, to_body: int, kind: int) -> int, pub:
    return _conc_plan_add_edge_ch(plan, from_body, to_body, kind, -1)

fn conc_plan_add_edge_ch(plan: int, from_body: int, to_body: int, kind: int, channel: int) -> int, pub:
    return _conc_plan_add_edge_ch(plan, from_body, to_body, kind, channel)

fn conc_plan_edge_channel(plan: int, edge: int) -> int, pub:
    if _conc_plan_valid(plan) == 0:
        return -1
    p := _conc_plan_at(plan)
    if edge < 0 || edge >= cell_load(p, 16):
        return -1
    base := load_str_ptr(p, 64)
    return cell_load(base, edge * 32 + 24)

fn conc_plan_edge_from(plan: int, edge: int) -> int, pub:
    if _conc_plan_valid(plan) == 0:
        return -1
    p := _conc_plan_at(plan)
    if edge < 0 || edge >= cell_load(p, 16):
        return -1
    return cell_load(load_str_ptr(p, 64), edge * 32)

fn conc_plan_edge_to(plan: int, edge: int) -> int, pub:
    if _conc_plan_valid(plan) == 0:
        return -1
    p := _conc_plan_at(plan)
    if edge < 0 || edge >= cell_load(p, 16):
        return -1
    return cell_load(load_str_ptr(p, 64), edge * 32 + 8)

fn conc_plan_acyclic(plan: int) -> int, pub:
    // Kahn over SPAWN edges. A cycle means the mapping has no legal schedule.
    if _conc_plan_valid(plan) == 0:
        return 0
    p := _conc_plan_at(plan)
    n := cell_load(p, 0)
    if n <= 0:
        return 1
    indeg := alloc(n * 8)
    i : ., mut = 0
    loop:
        if i >= n:
            break
        cell_store(indeg, i * 8, 0)
        i = i + 1
    ne := cell_load(p, 16)
    ebase := load_str_ptr(p, 64)
    e : ., mut = 0
    loop:
        if e >= ne:
            break
        if cell_load(ebase, e * 32 + 16) == CONC_EDGE_SPAWN:
            to := cell_load(ebase, e * 32 + 8)
            if to >= 0 && to < n:
                cell_store(indeg, to * 8, cell_load(indeg, to * 8) + 1)
        e = e + 1
    q := alloc(n * 8)
    head : ., mut = 0
    tail : ., mut = 0
    i = 0
    loop:
        if i >= n:
            break
        if cell_load(indeg, i * 8) == 0:
            cell_store(q, tail * 8, i)
            tail = tail + 1
        i = i + 1
    seen : ., mut = 0
    loop:
        if head >= tail:
            break
        v := cell_load(q, head * 8)
        head = head + 1
        seen = seen + 1
        e = 0
        loop:
            if e >= ne:
                break
            if cell_load(ebase, e * 32 + 16) == CONC_EDGE_SPAWN:
                if cell_load(ebase, e * 32) == v:
                    to := cell_load(ebase, e * 32 + 8)
                    if to >= 0 && to < n:
                        d := cell_load(indeg, to * 8) - 1
                        cell_store(indeg, to * 8, d)
                        if d == 0:
                            cell_store(q, tail * 8, to)
                            tail = tail + 1
            e = e + 1
    if seen == n:
        return 1
    return 0

fn conc_plan_validate(plan: int) -> int, pub:
    if _conc_plan_valid(plan) == 0:
        return 0
    p := _conc_plan_at(plan)
    ver := cell_load(p, 80)
    if ver != 1 && ver != 2:
        return 0
    n := cell_load(p, 0)
    if n <= 0:
        return 0
    if n > CONC_MAX_BODIES:
        return 0
    if cell_load(p, 8) > CONC_MAX_CHANNELS:
        return 0
    if cell_load(p, 16) > CONC_MAX_EDGES:
        return 0
    bbase := load_str_ptr(p, 48)
    i : ., mut = 0
    loop:
        if i >= n:
            break
        kind := cell_load(bbase, i * 32)
        params := cell_load(bbase, i * 32 + 16)
        if kind < CONC_BODY_TASK || kind > CONC_BODY_PIPELINE:
            return 0
        if kind != CONC_BODY_DATA_PARALLEL && params > 1:
            return 0
        if params < 0:
            return 0
        i = i + 1
    nch := cell_load(p, 8)
    chbase := load_str_ptr(p, 56)
    c : ., mut = 0
    loop:
        if c >= nch:
            break
        elem := cell_load(chbase, c * 32)
        cap := cell_load(chbase, c * 32 + 8)
        pc := cell_load(chbase, c * 32 + 16)
        if elem <= 0 || cap < 0:
            return 0
        if pc != CONC_PC_SPSC && pc != CONC_PC_MPMC:
            return 0
        if pc == CONC_PC_SPSC && cap <= 0:
            return 0
        if ver == 1 && pc == CONC_PC_MPMC:
            return 0
        c = c + 1
    if _conc_plan_validate_edges(plan) != 0:
        return 0
    nr := cell_load(p, 104)
    if nr > 64:
        return 0
    rbase := load_str_ptr(p, 136)
    r : ., mut = 0
    loop:
        if r >= nr:
            break
        if cell_load(rbase, r * 32) < 0 || cell_load(rbase, r * 32) >= n:
            return 0
        if cell_load(rbase, r * 32 + 16) <= 0:
            return 0
        r = r + 1
    ns := cell_load(p, 96)
    sbase := load_str_ptr(p, 144)
    s : ., mut = 0
    loop:
        if s >= ns:
            break
        kind := cell_load(sbase, s * 32)
        parent := cell_load(sbase, s * 32 + 8)
        count := cell_load(sbase, s * 32 + 16)
        if kind != CONC_SLOT_CPU_THREAD && kind != CONC_SLOT_CPU_FIBER:
            return 0
        if parent < -1 || parent >= s:
            return 0
        if count <= 0:
            return 0
        s = s + 1
    nt := cell_load(p, 112)
    tbase := load_str_ptr(p, 152)
    t : ., mut = 0
    loop:
        if t >= nt:
            break
        kind := cell_load(tbase, t * 40)
        src := cell_load(tbase, t * 40 + 8)
        dst := cell_load(tbase, t * 40 + 16)
        size := cell_load(tbase, t * 40 + 24)
        if kind < CONC_TRANSFER_MOVE || kind > CONC_TRANSFER_COPY:
            return 0
        if src < 0 || src >= n || dst < 0 || dst >= n || size <= 0:
            return 0
        t = t + 1
    nb := cell_load(p, 120)
    bbase2 := load_str_ptr(p, 160)
    b : ., mut = 0
    loop:
        if b >= nb:
            break
        kind := cell_load(bbase2, b * 40)
        st := cell_load(bbase2, b * 40 + 16)
        if kind < CONC_BUDGET_PROGRESSIVE || kind > CONC_BUDGET_WAIT:
            return 0
        if st < CONC_STATUS_PROVED || st > CONC_STATUS_MEASURED:
            return 0
        bd := cell_load(bbase2, b * 40 + 32)
        if bd < -1 || bd >= n:
            return 0
        b = b + 1
    nc := cell_load(p, 128)
    cbase := load_str_ptr(p, 168)
    cc : ., mut = 0
    loop:
        if cc >= nc:
            break
        st := cell_load(cbase, cc * 32 + 8)
        if st < CONC_STATUS_PROVED || st > CONC_STATUS_MEASURED:
            return 0
        cc = cc + 1
    nsp := cell_load(p, 224)
    spbase := load_str_ptr(p, 232)
    sp : ., mut = 0
    loop:
        if sp >= nsp:
            break
        kind := cell_load(spbase, sp * 32)
        cap := cell_load(spbase, sp * 32 + 8)
        if kind != CONC_SPACE_HOST && kind != CONC_SPACE_DEVICE && kind != CONC_SPACE_REMOTE:
            return 0
        if cap <= 0:
            return 0
        sp = sp + 1
    nx := cell_load(p, 240)
    xbase := load_str_ptr(p, 248)
    x : ., mut = 0
    loop:
        if x >= nx:
            break
        kind := cell_load(xbase, x * 56)
        src := cell_load(xbase, x * 56 + 8)
        dst := cell_load(xbase, x * 56 + 16)
        size := cell_load(xbase, x * 56 + 24)
        ss := cell_load(xbase, x * 56 + 32)
        ds := cell_load(xbase, x * 56 + 40)
        if kind < CONC_TRANSFER_MOVE || kind > CONC_TRANSFER_COPY:
            return 0
        if src < 0 || src >= n || dst < 0 || dst >= n || size <= 0:
            return 0
        if ss < -1 || ss >= nsp || ds < -1 || ds >= nsp:
            return 0
        x = x + 1
    nl := cell_load(p, 208)
    lbase := load_str_ptr(p, 216)
    l : ., mut = 0
    loop:
        if l >= nl:
            break
        if cell_load(lbase, l * 32) != l:
            return 0
        if cell_load(lbase, l * 32 + 8) <= 0:
            return 0
        l = l + 1
    nst := cell_load(p, 192)
    stbase := load_str_ptr(p, 200)
    st : ., mut = 0
    loop:
        if st >= nst:
            break
        body := cell_load(stbase, st * 32)
        in_ch := cell_load(stbase, st * 32 + 8)
        out_ch := cell_load(stbase, st * 32 + 16)
        policy := cell_load(stbase, st * 32 + 24)
        if body < 0 || body >= n:
            return 0
        if conc_plan_body_kind(plan, body) != CONC_BODY_PIPELINE:
            return 0
        if conc_plan_body_params(plan, body) != 1:
            return 0
        if in_ch < -1 || in_ch >= nch:
            return 0
        if out_ch < -1 || out_ch >= nch:
            return 0
        if policy != CONC_STAGE_BLOCKING && policy != CONC_STAGE_BOUNDED:
            return 0
        st = st + 1
    if conc_plan_acyclic(plan) == 0:
        return 0
    return 1

fn _conc_num_str(n: int) -> string:
    if n == 0:
        return "0"
    buf := alloc(24)
    v : ., mut = n
    neg : ., mut = 0
    if v < 0:
        neg = 1
        v = 0 - v
    pos : ., mut = 23
    store8(buf, pos, 0)
    loop:
        if v <= 0:
            break
        pos = pos - 1
        store8(buf, pos, 48 + v % 10)
        v = v / 10
    if neg != 0:
        pos = pos - 1
        store8(buf, pos, 45)
    return str_sub(buf, pos, 23 - pos)

fn conc_plan_explain(plan: int) -> string, pub:
    if _conc_plan_valid(plan) == 0:
        return "invalid plan"
    p := _conc_plan_at(plan)
    out : ., mut = "v" + _conc_num_str(cell_load(p, 80))
    out = out + " bodies " + _conc_num_str(cell_load(p, 0))
    out = out + " channels " + _conc_num_str(cell_load(p, 8))
    out = out + " edges " + _conc_num_str(cell_load(p, 16))
    out = out + " slots " + _conc_num_str(cell_load(p, 96))
    out = out + " stages " + _conc_num_str(cell_load(p, 192))
    out = out + " layouts " + _conc_num_str(cell_load(p, 208))
    out = out + " spaces " + _conc_num_str(cell_load(p, 224))
    out = out + " xfers " + _conc_num_str(cell_load(p, 240))
    out = out + " ranges " + _conc_num_str(cell_load(p, 104))
    out = out + " transfers " + _conc_num_str(cell_load(p, 112))
    out = out + " budgets " + _conc_num_str(cell_load(p, 120))
    out = out + " certs " + _conc_num_str(cell_load(p, 128))
    out = out + " legal " + _conc_num_str(conc_plan_validate(plan))
    out = out + " budget_ok " + _conc_num_str(conc_plan_budget_ok(plan))
    out = out + " cert_ok " + _conc_num_str(conc_plan_cert_ok(plan))
    out = out + " deterministic " + _conc_num_str(conc_plan_deterministic(plan))
    return out

fn conc_plan_body_count(plan: int) -> int, pub:
    if _conc_plan_valid(plan) == 0:
        return -1
    return cell_load(_conc_plan_at(plan), 0)

fn conc_plan_channel_count(plan: int) -> int, pub:
    if _conc_plan_valid(plan) == 0:
        return -1
    return cell_load(_conc_plan_at(plan), 8)

fn conc_plan_edge_count(plan: int) -> int, pub:
    if _conc_plan_valid(plan) == 0:
        return -1
    return cell_load(_conc_plan_at(plan), 16)

fn conc_plan_bind_count(plan: int) -> int, pub:
    if _conc_plan_valid(plan) == 0:
        return -1
    binds := load_str_ptr(_conc_plan_at(plan), 72)
    if _conc_is_null(binds) != 0:
        return 0
    return cell_load(binds, 0)

fn conc_plan_bind_param(plan: int, body: int, param: int, channel: int) -> int, pub:
    if _conc_plan_valid(plan) == 0:
        return -1
    p := _conc_plan_at(plan)
    if body < 0 || body >= cell_load(p, 0):
        return -1
    b := _conc_body_at(plan, body)
    if param < 0 || param >= cell_load(b, 16):
        return -1
    if channel < 0 || channel >= cell_load(p, 8):
        return -1
    binds := load_str_ptr(p, 72)
    if _conc_is_null(binds) != 0:
        return -1
    n := cell_load(binds, 0)
    cap := cell_load(binds, 8)
    if n < 0 || n >= cap:
        return -1
    i : ., mut = 0
    loop:
        if i >= n:
            break
        off := 16 + i * 24
        if cell_load(binds, off) == body:
            if cell_load(binds, off + 8) == param:
                return -1
        i = i + 1
    off2 := 16 + n * 24
    cell_store(binds, off2, body)
    cell_store(binds, off2 + 8, param)
    cell_store(binds, off2 + 16, channel)
    cell_store(binds, 0, n + 1)
    return n

fn conc_plan_param_channel(plan: int, body: int, param: int) -> int, pub:
    if _conc_plan_valid(plan) == 0:
        return -1
    binds := load_str_ptr(_conc_plan_at(plan), 72)
    if _conc_is_null(binds) != 0:
        return -1
    n := cell_load(binds, 0)
    i : ., mut = 0
    loop:
        if i >= n:
            break
        off := 16 + i * 24
        if cell_load(binds, off) == body:
            if cell_load(binds, off + 8) == param:
                return cell_load(binds, off + 16)
        i = i + 1
    return -1

fn _conc_global_str(s: string) -> string:
    n := str_len(s)
    p := _conc_global_alloc(n + 1)
    if _conc_is_null(p) != 0:
        return _conc_ptr(0)
    _conc_copy(p, s, n)
    store8(p, n, 0)
    return p

fn conc_plan_version(plan: int) -> int, pub:
    if _conc_plan_valid(plan) == 0:
        return -1
    return cell_load(_conc_plan_at(plan), 80)

fn conc_plan_set_version(plan: int, ver: int) -> int, pub:
    if _conc_plan_valid(plan) == 0:
        return -1
    if ver != 1 && ver != 2:
        return -1
    cell_store(_conc_plan_at(plan), 80, ver)
    return 0

fn conc_plan_set_target(plan: int, name: string, slots: int, memory: int) -> int, pub:
    if _conc_plan_valid(plan) == 0:
        return -1
    p := _conc_plan_at(plan)
    copy := _conc_global_str(name)
    if _conc_is_null(copy) != 0:
        return -1
    store_str_ptr(p, 88, copy)
    cell_store(p, 176, slots)
    cell_store(p, 184, memory)
    return 0

fn conc_plan_target_name(plan: int) -> string, pub:
    if _conc_plan_valid(plan) == 0:
        return _conc_ptr(0)
    return load_str_ptr(_conc_plan_at(plan), 88)

fn conc_plan_target_slots(plan: int) -> int, pub:
    if _conc_plan_valid(plan) == 0:
        return -1
    return cell_load(_conc_plan_at(plan), 176)

fn conc_plan_target_memory(plan: int) -> int, pub:
    if _conc_plan_valid(plan) == 0:
        return -1
    return cell_load(_conc_plan_at(plan), 184)

fn conc_plan_add_range(plan: int, body: int, start: int, count: int) -> int, pub:
    if _conc_plan_valid(plan) == 0:
        return -1
    p := _conc_plan_at(plan)
    if body < 0 || body >= cell_load(p, 0):
        return -1
    if start < 0 || count <= 0:
        return -1
    n := cell_load(p, 104)
    if n >= 64:
        return -1
    base := load_str_ptr(p, 136)
    off := n * 32
    cell_store(base, off, body)
    cell_store(base, off + 8, start)
    cell_store(base, off + 16, count)
    cell_store(p, 104, n + 1)
    return n

fn conc_plan_range_count(plan: int) -> int, pub:
    if _conc_plan_valid(plan) == 0:
        return -1
    return cell_load(_conc_plan_at(plan), 104)

fn conc_plan_range_body(plan: int, i: int) -> int, pub:
    if _conc_plan_valid(plan) == 0:
        return -1
    p := _conc_plan_at(plan)
    if i < 0 || i >= cell_load(p, 104):
        return -1
    return cell_load(load_str_ptr(p, 136), i * 32)

fn conc_plan_range_start(plan: int, i: int) -> int, pub:
    if _conc_plan_valid(plan) == 0:
        return -1
    p := _conc_plan_at(plan)
    if i < 0 || i >= cell_load(p, 104):
        return -1
    return cell_load(load_str_ptr(p, 136), i * 32 + 8)

fn conc_plan_range_len(plan: int, i: int) -> int, pub:
    if _conc_plan_valid(plan) == 0:
        return -1
    p := _conc_plan_at(plan)
    if i < 0 || i >= cell_load(p, 104):
        return -1
    return cell_load(load_str_ptr(p, 136), i * 32 + 16)

fn conc_plan_add_slot(plan: int, kind: int, parent: int, count: int) -> int, pub:
    if _conc_plan_valid(plan) == 0:
        return -1
    if kind != CONC_SLOT_CPU_THREAD && kind != CONC_SLOT_CPU_FIBER:
        return -1
    if count <= 0:
        return -1
    p := _conc_plan_at(plan)
    n := cell_load(p, 96)
    if parent < -1 || parent >= n:
        return -1
    if n >= 64:
        return -1
    base := load_str_ptr(p, 144)
    off := n * 32
    cell_store(base, off, kind)
    cell_store(base, off + 8, parent)
    cell_store(base, off + 16, count)
    cell_store(p, 96, n + 1)
    return n

fn conc_plan_slot_count(plan: int) -> int, pub:
    if _conc_plan_valid(plan) == 0:
        return -1
    return cell_load(_conc_plan_at(plan), 96)

fn conc_plan_slot_kind(plan: int, i: int) -> int, pub:
    if _conc_plan_valid(plan) == 0:
        return -1
    p := _conc_plan_at(plan)
    if i < 0 || i >= cell_load(p, 96):
        return -1
    return cell_load(load_str_ptr(p, 144), i * 32)

fn conc_plan_slot_parent(plan: int, i: int) -> int, pub:
    if _conc_plan_valid(plan) == 0:
        return -1
    p := _conc_plan_at(plan)
    if i < 0 || i >= cell_load(p, 96):
        return -1
    return cell_load(load_str_ptr(p, 144), i * 32 + 8)

fn conc_plan_slot_len(plan: int, i: int) -> int, pub:
    if _conc_plan_valid(plan) == 0:
        return -1
    p := _conc_plan_at(plan)
    if i < 0 || i >= cell_load(p, 96):
        return -1
    return cell_load(load_str_ptr(p, 144), i * 32 + 16)

fn conc_plan_add_transfer(plan: int, kind: int, src: int, dst: int, size: int) -> int, pub:
    if _conc_plan_valid(plan) == 0:
        return -1
    if kind < CONC_TRANSFER_MOVE || kind > CONC_TRANSFER_COPY:
        return -1
    p := _conc_plan_at(plan)
    if src < 0 || src >= cell_load(p, 0):
        return -1
    if dst < 0 || dst >= cell_load(p, 0):
        return -1
    if size <= 0:
        return -1
    n := cell_load(p, 112)
    if n >= 64:
        return -1
    base := load_str_ptr(p, 152)
    off := n * 40
    cell_store(base, off, kind)
    cell_store(base, off + 8, src)
    cell_store(base, off + 16, dst)
    cell_store(base, off + 24, size)
    cell_store(base, off + 32, 0)
    cell_store(p, 112, n + 1)
    return n

fn conc_plan_transfer_count(plan: int) -> int, pub:
    if _conc_plan_valid(plan) == 0:
        return -1
    return cell_load(_conc_plan_at(plan), 112)

fn conc_plan_transfer_kind(plan: int, i: int) -> int, pub:
    if _conc_plan_valid(plan) == 0:
        return -1
    p := _conc_plan_at(plan)
    if i < 0 || i >= cell_load(p, 112):
        return -1
    return cell_load(load_str_ptr(p, 152), i * 40)

fn conc_plan_transfer_src(plan: int, i: int) -> int, pub:
    if _conc_plan_valid(plan) == 0:
        return -1
    p := _conc_plan_at(plan)
    if i < 0 || i >= cell_load(p, 112):
        return -1
    return cell_load(load_str_ptr(p, 152), i * 40 + 8)

fn conc_plan_transfer_dst(plan: int, i: int) -> int, pub:
    if _conc_plan_valid(plan) == 0:
        return -1
    p := _conc_plan_at(plan)
    if i < 0 || i >= cell_load(p, 112):
        return -1
    return cell_load(load_str_ptr(p, 152), i * 40 + 16)

fn conc_plan_transfer_size(plan: int, i: int) -> int, pub:
    if _conc_plan_valid(plan) == 0:
        return -1
    p := _conc_plan_at(plan)
    if i < 0 || i >= cell_load(p, 112):
        return -1
    return cell_load(load_str_ptr(p, 152), i * 40 + 24)

fn conc_plan_add_budget(plan: int, kind: int, bound: int, status: int) -> int, pub:
    return _conc_plan_add_budget_body(plan, kind, bound, status, -1)

fn _conc_plan_add_budget_body(plan: int, kind: int, bound: int, status: int,
                              body: int) -> int:
    if _conc_plan_valid(plan) == 0:
        return -1
    if kind < CONC_BUDGET_PROGRESSIVE || kind > CONC_BUDGET_WAIT:
        return -1
    if bound < 0:
        return -1
    if status < CONC_STATUS_PROVED || status > CONC_STATUS_MEASURED:
        return -1
    p := _conc_plan_at(plan)
    if body < -1 || body >= cell_load(p, 0):
        return -1
    n := cell_load(p, 120)
    if n >= 64:
        return -1
    base := load_str_ptr(p, 160)
    off := n * 40
    cell_store(base, off, kind)
    cell_store(base, off + 8, bound)
    cell_store(base, off + 16, status)
    cell_store(base, off + 24, 0)
    cell_store(base, off + 32, body)
    cell_store(p, 120, n + 1)
    return n

fn conc_plan_add_budget_body(plan: int, kind: int, bound: int, status: int,
                             body: int) -> int, pub:
    return _conc_plan_add_budget_body(plan, kind, bound, status, body)

fn conc_plan_budget_body(plan: int, i: int) -> int, pub:
    if _conc_plan_valid(plan) == 0:
        return -1
    p := _conc_plan_at(plan)
    if i < 0 || i >= cell_load(p, 120):
        return -1
    return cell_load(load_str_ptr(p, 160), i * 40 + 32)

fn conc_plan_budget_count(plan: int) -> int, pub:
    if _conc_plan_valid(plan) == 0:
        return -1
    return cell_load(_conc_plan_at(plan), 120)

fn conc_plan_budget_kind(plan: int, i: int) -> int, pub:
    if _conc_plan_valid(plan) == 0:
        return -1
    p := _conc_plan_at(plan)
    if i < 0 || i >= cell_load(p, 120):
        return -1
    return cell_load(load_str_ptr(p, 160), i * 40)

fn conc_plan_budget_bound(plan: int, i: int) -> int, pub:
    if _conc_plan_valid(plan) == 0:
        return -1
    p := _conc_plan_at(plan)
    if i < 0 || i >= cell_load(p, 120):
        return -1
    return cell_load(load_str_ptr(p, 160), i * 40 + 8)

fn conc_plan_budget_status(plan: int, i: int) -> int, pub:
    if _conc_plan_valid(plan) == 0:
        return -1
    p := _conc_plan_at(plan)
    if i < 0 || i >= cell_load(p, 120):
        return -1
    return cell_load(load_str_ptr(p, 160), i * 40 + 16)

fn conc_plan_budget_measure(plan: int, i: int, value: int) -> int, pub:
    if _conc_plan_valid(plan) == 0:
        return -1
    p := _conc_plan_at(plan)
    if i < 0 || i >= cell_load(p, 120):
        return -1
    if value < 0:
        return -1
    base := load_str_ptr(p, 160)
    cell_store(base, i * 40 + 24, value)
    cell_store(base, i * 40 + 16, CONC_STATUS_MEASURED)
    return 0

fn conc_plan_budget_value(plan: int, i: int) -> int, pub:
    if _conc_plan_valid(plan) == 0:
        return -1
    p := _conc_plan_at(plan)
    if i < 0 || i >= cell_load(p, 120):
        return -1
    return cell_load(load_str_ptr(p, 160), i * 40 + 24)

fn conc_plan_add_cert(plan: int, kind: int, status: int) -> int, pub:
    if _conc_plan_valid(plan) == 0:
        return -1
    if kind < 0:
        return -1
    if status < CONC_STATUS_PROVED || status > CONC_STATUS_MEASURED:
        return -1
    p := _conc_plan_at(plan)
    n := cell_load(p, 128)
    if n >= 64:
        return -1
    base := load_str_ptr(p, 168)
    off := n * 32
    cell_store(base, off, kind)
    cell_store(base, off + 8, status)
    cell_store(base, off + 16, 0)
    cell_store(base, off + 24, 0)
    cell_store(p, 128, n + 1)
    return n

fn conc_plan_cert_count(plan: int) -> int, pub:
    if _conc_plan_valid(plan) == 0:
        return -1
    return cell_load(_conc_plan_at(plan), 128)

fn conc_plan_cert_kind(plan: int, i: int) -> int, pub:
    if _conc_plan_valid(plan) == 0:
        return -1
    p := _conc_plan_at(plan)
    if i < 0 || i >= cell_load(p, 128):
        return -1
    return cell_load(load_str_ptr(p, 168), i * 32)

fn conc_plan_cert_status(plan: int, i: int) -> int, pub:
    if _conc_plan_valid(plan) == 0:
        return -1
    p := _conc_plan_at(plan)
    if i < 0 || i >= cell_load(p, 128):
        return -1
    return cell_load(load_str_ptr(p, 168), i * 32 + 8)

fn _conc_plan_cert_find(plan: int, kind: int) -> int:
    n := conc_plan_cert_count(plan)
    i : ., mut = 0
    loop:
        if i >= n:
            return -1
        if conc_plan_cert_kind(plan, i) == kind:
            return i
        i = i + 1
    return -1

fn conc_plan_cert_prove(plan: int, kind: int) -> int, pub:
    // Re-derive a known certificate from the plan. Unknown/unimplemented
    // certificate kinds stay UNKNOWN; they are never silently accepted.
    if _conc_plan_valid(plan) == 0:
        return -1
    if kind < 0:
        return -1
    st : ., mut = CONC_STATUS_UNKNOWN
    if kind == CONC_CERT_ACYCLIC:
        if conc_plan_acyclic(plan) != 0:
            st = CONC_STATUS_PROVED
        else:
            st = CONC_STATUS_VIOLATED
    else:
        if kind == CONC_CERT_DETERMINISTIC:
            if conc_plan_deterministic(plan) != 0:
                st = CONC_STATUS_PROVED
            else:
                st = CONC_STATUS_VIOLATED
        else:
            if kind == CONC_CERT_BUDGET:
                if conc_plan_budget_ok(plan) != 0:
                    st = CONC_STATUS_PROVED
                else:
                    st = CONC_STATUS_VIOLATED
            else:
                if kind == CONC_CERT_TRANSFER:
                    if conc_plan_validate(plan) != 0 && conc_plan_xfer_bytes(plan) >= 0:
                        st = CONC_STATUS_PROVED
                    else:
                        st = CONC_STATUS_VIOLATED
    i := _conc_plan_cert_find(plan, kind)
    if i >= 0:
        p := _conc_plan_at(plan)
        cell_store(load_str_ptr(p, 168), i * 32 + 8, st)
        return i
    return conc_plan_add_cert(plan, kind, st)

fn conc_plan_obligations_ok(plan: int) -> int, pub:
    // Scoped budgets are execution obligations. Global budgets remain
    // advisory metadata. A scoped obligation passes only when its status is
    // PROVED or MEASURED and its structural bound is satisfied.
    if _conc_plan_valid(plan) == 0:
        return 0
    n := conc_plan_budget_count(plan)
    i : ., mut = 0
    loop:
        if i >= n:
            break
        body := conc_plan_budget_body(plan, i)
        if body >= 0:
            st := conc_plan_budget_status(plan, i)
            if st != CONC_STATUS_PROVED && st != CONC_STATUS_MEASURED:
                return 0
            kind := conc_plan_budget_kind(plan, i)
            bound := conc_plan_budget_bound(plan, i)
            if kind == CONC_BUDGET_COUNT:
                if bound < conc_plan_body_params(plan, body):
                    return 0
            else:
                if bound < 0:
                    return 0
        i = i + 1
    return 1

fn conc_plan_explain_full(plan: int) -> string, pub:
    out : ., mut = conc_plan_explain(plan)
    out = out + " budget_ok " + _conc_num_str(conc_plan_budget_ok(plan))
    out = out + " cert_ok " + _conc_num_str(conc_plan_cert_ok(plan))
    out = out + " deterministic " + _conc_num_str(conc_plan_deterministic(plan))
    out = out + " obligations " + _conc_num_str(conc_plan_obligations_ok(plan))
    nb := conc_plan_budget_count(plan)
    b : ., mut = 0
    loop:
        if b >= nb:
            break
        out = out + "\nbudget " + _conc_num_str(b)
        out = out + " kind " + _conc_num_str(conc_plan_budget_kind(plan, b))
        out = out + " bound " + _conc_num_str(conc_plan_budget_bound(plan, b))
        out = out + " status " + _conc_num_str(conc_plan_budget_status(plan, b))
        out = out + " value " + _conc_num_str(conc_plan_budget_value(plan, b))
        out = out + " body " + _conc_num_str(conc_plan_budget_body(plan, b))
        b = b + 1
    nc := conc_plan_cert_count(plan)
    c : ., mut = 0
    loop:
        if c >= nc:
            break
        out = out + "\ncert " + _conc_num_str(c)
        out = out + " kind " + _conc_num_str(conc_plan_cert_kind(plan, c))
        out = out + " status " + _conc_num_str(conc_plan_cert_status(plan, c))
        c = c + 1
    nx := conc_plan_xfer_count(plan)
    x : ., mut = 0
    loop:
        if x >= nx:
            break
        out = out + "\nxfer " + _conc_num_str(x)
        out = out + " kind " + _conc_num_str(conc_plan_xfer_kind(plan, x))
        out = out + " size " + _conc_num_str(conc_plan_xfer_size(plan, x))
        out = out + " src " + _conc_num_str(conc_plan_xfer_src_space(plan, x))
        out = out + " dst " + _conc_num_str(conc_plan_xfer_dst_space(plan, x))
        x = x + 1
    return out

fn conc_plan_add_space(plan: int, kind: int, capacity: int) -> int, pub:
    if _conc_plan_valid(plan) == 0:
        return -1
    if kind != CONC_SPACE_HOST && kind != CONC_SPACE_DEVICE && kind != CONC_SPACE_REMOTE:
        return -1
    if capacity <= 0:
        return -1
    p := _conc_plan_at(plan)
    n := cell_load(p, 224)
    if n >= CONC_MAX_SPACES:
        return -1
    base := load_str_ptr(p, 232)
    off := n * 32
    cell_store(base, off, kind)
    cell_store(base, off + 8, capacity)
    cell_store(base, off + 16, 0)
    cell_store(base, off + 24, 0)
    cell_store(p, 224, n + 1)
    return n

fn conc_plan_space_count(plan: int) -> int, pub:
    if _conc_plan_valid(plan) == 0:
        return -1
    return cell_load(_conc_plan_at(plan), 224)

fn conc_plan_space_kind(plan: int, i: int) -> int, pub:
    if _conc_plan_valid(plan) == 0:
        return -1
    p := _conc_plan_at(plan)
    if i < 0 || i >= cell_load(p, 224):
        return -1
    return cell_load(load_str_ptr(p, 232), i * 32)

fn conc_plan_space_capacity(plan: int, i: int) -> int, pub:
    if _conc_plan_valid(plan) == 0:
        return -1
    p := _conc_plan_at(plan)
    if i < 0 || i >= cell_load(p, 224):
        return -1
    return cell_load(load_str_ptr(p, 232), i * 32 + 8)

fn conc_plan_add_xfer(plan: int, kind: int, src: int, dst: int, size: int,
                      src_space: int, dst_space: int) -> int, pub:
    if _conc_plan_valid(plan) == 0:
        return -1
    if kind < CONC_TRANSFER_MOVE || kind > CONC_TRANSFER_COPY:
        return -1
    p := _conc_plan_at(plan)
    if src < 0 || src >= cell_load(p, 0):
        return -1
    if dst < 0 || dst >= cell_load(p, 0):
        return -1
    if size <= 0:
        return -1
    ns := cell_load(p, 224)
    if src_space < -1 || src_space >= ns:
        return -1
    if dst_space < -1 || dst_space >= ns:
        return -1
    n := cell_load(p, 240)
    if n >= 64:
        return -1
    base := load_str_ptr(p, 248)
    off := n * 56
    cell_store(base, off, kind)
    cell_store(base, off + 8, src)
    cell_store(base, off + 16, dst)
    cell_store(base, off + 24, size)
    cell_store(base, off + 32, src_space)
    cell_store(base, off + 40, dst_space)
    cell_store(base, off + 48, 0)
    cell_store(p, 240, n + 1)
    return n

fn conc_plan_xfer_count(plan: int) -> int, pub:
    if _conc_plan_valid(plan) == 0:
        return -1
    return cell_load(_conc_plan_at(plan), 240)

fn conc_plan_xfer_kind(plan: int, i: int) -> int, pub:
    if _conc_plan_valid(plan) == 0:
        return -1
    p := _conc_plan_at(plan)
    if i < 0 || i >= cell_load(p, 240):
        return -1
    return cell_load(load_str_ptr(p, 248), i * 56)

fn conc_plan_xfer_size(plan: int, i: int) -> int, pub:
    if _conc_plan_valid(plan) == 0:
        return -1
    p := _conc_plan_at(plan)
    if i < 0 || i >= cell_load(p, 240):
        return -1
    return cell_load(load_str_ptr(p, 248), i * 56 + 24)

fn conc_plan_xfer_src_space(plan: int, i: int) -> int, pub:
    if _conc_plan_valid(plan) == 0:
        return -1
    p := _conc_plan_at(plan)
    if i < 0 || i >= cell_load(p, 240):
        return -1
    return cell_load(load_str_ptr(p, 248), i * 56 + 32)

fn conc_plan_xfer_dst_space(plan: int, i: int) -> int, pub:
    if _conc_plan_valid(plan) == 0:
        return -1
    p := _conc_plan_at(plan)
    if i < 0 || i >= cell_load(p, 240):
        return -1
    return cell_load(load_str_ptr(p, 248), i * 56 + 40)

fn conc_plan_xfer_bytes(plan: int) -> int, pub:
    n := conc_plan_xfer_count(plan)
    total : ., mut = 0
    i : ., mut = 0
    loop:
        if i >= n:
            break
        total = total + conc_plan_xfer_size(plan, i)
        i = i + 1
    return total

fn conc_plan_apply_spaces(plan: int) -> int, pub:
    if _conc_plan_valid(plan) == 0:
        return -1
    n := conc_plan_space_count(plan)
    if n < 0:
        return -1
    i : ., mut = 0
    loop:
        if i >= n:
            break
        kind := conc_plan_space_kind(plan, i)
        cap := conc_plan_space_capacity(plan, i)
        sid := conc_space_create(kind, cap)
        if sid != i:
            return -1
        i = i + 1
    return n

fn conc_plan_add_stage(plan: int, body: int, in_ch: int, out_ch: int,
                        policy: int) -> int, pub:
    if _conc_plan_valid(plan) == 0:
        return -1
    p := _conc_plan_at(plan)
    if body < 0 || body >= cell_load(p, 0):
        return -1
    if conc_plan_body_kind(plan, body) != CONC_BODY_PIPELINE:
        return -1
    if conc_plan_body_params(plan, body) != 1:
        return -1
    nch := cell_load(p, 8)
    if in_ch < -1 || in_ch >= nch:
        return -1
    if out_ch < -1 || out_ch >= nch:
        return -1
    if policy != CONC_STAGE_BLOCKING && policy != CONC_STAGE_BOUNDED:
        return -1
    n := cell_load(p, 192)
    if n >= 64:
        return -1
    base := load_str_ptr(p, 200)
    off := n * 32
    cell_store(base, off, body)
    cell_store(base, off + 8, in_ch)
    cell_store(base, off + 16, out_ch)
    cell_store(base, off + 24, policy)
    cell_store(p, 192, n + 1)
    return n

fn conc_plan_stage_count(plan: int) -> int, pub:
    if _conc_plan_valid(plan) == 0:
        return -1
    return cell_load(_conc_plan_at(plan), 192)

fn conc_plan_stage_body(plan: int, i: int) -> int, pub:
    if _conc_plan_valid(plan) == 0:
        return -1
    p := _conc_plan_at(plan)
    if i < 0 || i >= cell_load(p, 192):
        return -1
    return cell_load(load_str_ptr(p, 200), i * 32)

fn conc_plan_stage_in(plan: int, i: int) -> int, pub:
    if _conc_plan_valid(plan) == 0:
        return -1
    p := _conc_plan_at(plan)
    if i < 0 || i >= cell_load(p, 192):
        return -1
    return cell_load(load_str_ptr(p, 200), i * 32 + 8)

fn conc_plan_stage_out(plan: int, i: int) -> int, pub:
    if _conc_plan_valid(plan) == 0:
        return -1
    p := _conc_plan_at(plan)
    if i < 0 || i >= cell_load(p, 192):
        return -1
    return cell_load(load_str_ptr(p, 200), i * 32 + 16)

fn conc_plan_stage_policy(plan: int, i: int) -> int, pub:
    if _conc_plan_valid(plan) == 0:
        return -1
    p := _conc_plan_at(plan)
    if i < 0 || i >= cell_load(p, 192):
        return -1
    return cell_load(load_str_ptr(p, 200), i * 32 + 24)

fn conc_plan_add_layout(plan: int, layout: int, size: int, hash: int) -> int, pub:
    if _conc_plan_valid(plan) == 0:
        return -1
    if layout < 0 || layout >= CONC_MAX_LAYOUTS || size <= 0:
        return -1
    p := _conc_plan_at(plan)
    n := cell_load(p, 208)
    if n >= 64:
        return -1
    if n != layout:
        return -1
    base := load_str_ptr(p, 216)
    off := n * 32
    cell_store(base, off, layout)
    cell_store(base, off + 8, size)
    cell_store(base, off + 16, hash)
    cell_store(base, off + 24, 0)
    cell_store(p, 208, n + 1)
    return n

fn conc_plan_layout_count(plan: int) -> int, pub:
    if _conc_plan_valid(plan) == 0:
        return -1
    return cell_load(_conc_plan_at(plan), 208)

fn conc_plan_layout_id(plan: int, i: int) -> int, pub:
    if _conc_plan_valid(plan) == 0:
        return -1
    p := _conc_plan_at(plan)
    if i < 0 || i >= cell_load(p, 208):
        return -1
    return cell_load(load_str_ptr(p, 216), i * 32)

fn conc_plan_layout_size(plan: int, i: int) -> int, pub:
    if _conc_plan_valid(plan) == 0:
        return -1
    p := _conc_plan_at(plan)
    if i < 0 || i >= cell_load(p, 208):
        return -1
    return cell_load(load_str_ptr(p, 216), i * 32 + 8)

fn conc_plan_layout_hash(plan: int, i: int) -> int, pub:
    if _conc_plan_valid(plan) == 0:
        return -1
    p := _conc_plan_at(plan)
    if i < 0 || i >= cell_load(p, 208):
        return -1
    return cell_load(load_str_ptr(p, 216), i * 32 + 16)

fn conc_plan_apply_layouts(plan: int) -> int, pub:
    if _conc_plan_valid(plan) == 0:
        return -1
    n := conc_plan_layout_count(plan)
    i : ., mut = 0
    loop:
        if i >= n:
            break
        lid := conc_plan_layout_id(plan, i)
        sz := conc_plan_layout_size(plan, i)
        h := conc_plan_layout_hash(plan, i)
        if conc_layout_declare(lid, sz, h) != lid:
            return -1
        i = i + 1
    return n

fn conc_plan_body_kind(plan: int, body: int) -> int, pub:
    if _conc_plan_valid(plan) == 0:
        return -1
    p := _conc_plan_at(plan)
    if body < 0 || body >= cell_load(p, 0):
        return -1
    return cell_load(load_str_ptr(p, 48), body * 32)

fn conc_plan_body_entry(plan: int, body: int) -> int, pub:
    if _conc_plan_valid(plan) == 0:
        return -1
    p := _conc_plan_at(plan)
    if body < 0 || body >= cell_load(p, 0):
        return -1
    return cell_load(load_str_ptr(p, 48), body * 32 + 8)

fn conc_plan_body_params(plan: int, body: int) -> int, pub:
    if _conc_plan_valid(plan) == 0:
        return -1
    p := _conc_plan_at(plan)
    if body < 0 || body >= cell_load(p, 0):
        return -1
    return cell_load(load_str_ptr(p, 48), body * 32 + 16)

fn conc_plan_channel_elemsize(plan: int, channel: int) -> int, pub:
    if _conc_plan_valid(plan) == 0:
        return -1
    p := _conc_plan_at(plan)
    if channel < 0 || channel >= cell_load(p, 8):
        return -1
    base := load_str_ptr(p, 56)
    return cell_load(base, channel * 32)

fn conc_plan_channel_cap(plan: int, channel: int) -> int, pub:
    if _conc_plan_valid(plan) == 0:
        return -1
    p := _conc_plan_at(plan)
    if channel < 0 || channel >= cell_load(p, 8):
        return -1
    base := load_str_ptr(p, 56)
    return cell_load(base, channel * 32 + 8)

fn conc_plan_edge_kind(plan: int, edge: int) -> int, pub:
    if _conc_plan_valid(plan) == 0:
        return -1
    p := _conc_plan_at(plan)
    if edge < 0 || edge >= cell_load(p, 16):
        return -1
    base := load_str_ptr(p, 64)
    return cell_load(base, edge * 32 + 16)

fn _conc_plan_validate_edges(plan: int) -> int:
    p := _conc_plan_at(plan)
    n := cell_load(p, 16)
    chn := cell_load(p, 8)
    base := load_str_ptr(p, 64)
    i : ., mut = 0
    loop:
        if i >= n:
            break
        kind := cell_load(base, i * 32 + 16)
        ch := cell_load(base, i * 32 + 24)
        if kind == CONC_EDGE_SEND || kind == CONC_EDGE_RECV:
            if ch < 0 || ch >= chn:
                return -1
        else:
            if kind == CONC_EDGE_SPAWN || kind == CONC_EDGE_JOIN:
                if ch != -1:
                    return -1
            else:
                return -1
        i = i + 1
    return 0

fn _conc_body_at(plan: int, idx: int) -> string:
    p := _conc_plan_at(plan)
    base := load_str_ptr(p, 48)
    return _conc_ptr(_conc_addr(base) + idx * 32)

// ── Executors ─────────────────────────────────────────────────────────────
//
// Both executors consume the same plan's body list. Channel/edge descriptors
// are validated by the fixture but are not executed in CP-1. CPU is a single
// logical slot with a serial fallback for DATA_PARALLEL; SIMT is a host-side
// index-domain mapping. Neither executor invents target capabilities.

fn _conc_call_ready() -> int:
    if _conc_is_null(g_conc_call_table) != 0:
        g_conc_call_table = _conc_global_alloc(8)
        if _conc_is_null(g_conc_call_table) != 0:
            return 0
    return 1

fn _conc_call0(entry: int) -> int:
    if entry <= 0:
        return -1
    if _conc_call_ready() == 0:
        return -1
    cell_store(g_conc_call_table, 0, entry)
    return sched_call_0(_conc_addr(g_conc_call_table), 0)

fn _conc_call_str(entry: int, arg: string) -> int:
    if entry <= 0:
        return -1
    if _conc_call_ready() == 0:
        return -1
    cell_store(g_conc_call_table, 0, entry)
    return sched_call_1(_conc_addr(g_conc_call_table), 0, _conc_addr(arg))

fn _conc_call_int(entry: int, arg: int) -> int:
    if entry <= 0:
        return -1
    if _conc_call_ready() == 0:
        return -1
    cell_store(g_conc_call_table, 0, entry)
    return sched_call_1(_conc_addr(g_conc_call_table), 0, arg)

fn conc_run_cpu(plan: int, arg: string) -> int, pub:
    if _conc_plan_valid(plan) == 0:
        return -1
    n := cell_load(_conc_plan_at(plan), 0)
    i : ., mut = 0
    loop:
        if i >= n:
            break
        b := _conc_body_at(plan, i)
        kind := cell_load(b, 0)
        entry := cell_load(b, 8)
        params := cell_load(b, 16)
        if kind == CONC_BODY_TASK || kind == CONC_BODY_PIPELINE:
            if params == 0:
                rc := _conc_call0(entry)
                if rc != 0:
                    return rc
            else:
                if params == 1:
                    rc := _conc_call_str(entry, arg)
                    if rc != 0:
                        return rc
                else:
                    return -1
        else:
            if kind == CONC_BODY_DATA_PARALLEL:
                j : ., mut = 0
                loop:
                    if j >= params:
                        break
                    rc := _conc_call_int(entry, j)
                    if rc != 0:
                        return rc
                    j = j + 1
            else:
                return -1
        i = i + 1
    return 0

fn conc_run_body(plan: int, body: int, arg: string) -> int, pub:
    if _conc_plan_valid(plan) == 0:
        return -1
    n := cell_load(_conc_plan_at(plan), 0)
    if body < 0 || body >= n:
        return -1
    b := _conc_body_at(plan, body)
    kind := cell_load(b, 0)
    entry := cell_load(b, 8)
    params := cell_load(b, 16)
    if kind == CONC_BODY_TASK || kind == CONC_BODY_PIPELINE:
        if params == 0:
            return _conc_call0(entry)
        if params == 1:
            return _conc_call_str(entry, arg)
        return -1
    if kind == CONC_BODY_DATA_PARALLEL:
        j : ., mut = 0
        loop:
            if j >= params:
                break
            rc := _conc_call_int(entry, j)
            if rc != 0:
                return rc
            j = j + 1
        return 0
    return -1

fn conc_run_body_bound(plan: int, body: int, channels: string) -> int, pub:
    if _conc_plan_valid(plan) == 0:
        return -1
    n := cell_load(_conc_plan_at(plan), 0)
    if body < 0 || body >= n:
        return -1
    if _conc_is_null(channels) != 0:
        return -1
    b := _conc_body_at(plan, body)
    kind := cell_load(b, 0)
    entry := cell_load(b, 8)
    params := cell_load(b, 16)
    if kind == CONC_BODY_TASK || kind == CONC_BODY_PIPELINE:
        if params == 0:
            return _conc_call0(entry)
        if params == 1:
            ch := conc_plan_param_channel(plan, body, 0)
            if ch < 0:
                return -1
            handle := load_str_ptr(channels, ch * 8)
            if _conc_is_null(handle) != 0:
                return -1
            return _conc_call_str(entry, handle)
        return -1
    if kind == CONC_BODY_DATA_PARALLEL:
        j : ., mut = 0
        loop:
            if j >= params:
                break
            rc := _conc_call_int(entry, j)
            if rc != 0:
                return rc
            j = j + 1
        return 0
    return -1

fn conc_run_simt(plan: int, start: int, end: int) -> int, pub:
    if _conc_plan_valid(plan) == 0:
        return -1
    if start < 0:
        return -1
    if end < start:
        return -1
    n := cell_load(_conc_plan_at(plan), 0)
    i : ., mut = 0
    loop:
        if i >= n:
            break
        b := _conc_body_at(plan, i)
        kind := cell_load(b, 0)
        if kind != CONC_BODY_DATA_PARALLEL:
            return -1
        params := cell_load(b, 16)
        if end > params:
            return -1
        entry := cell_load(b, 8)
        j : ., mut = start
        loop:
            if j >= end:
                break
            rc := _conc_call_int(entry, j)
            if rc != 0:
                return rc
            j = j + 1
        i = i + 1
    return 0

fn conc_plan_budget_ok(plan: int) -> int, pub:
    // A budget is a pass only when every entry is proved or measured.
    // UNKNOWN/VIOLATED are visible failures, never silently accepted.
    if _conc_plan_valid(plan) == 0:
        return 0
    n := conc_plan_budget_count(plan)
    i : ., mut = 0
    loop:
        if i >= n:
            break
        st := conc_plan_budget_status(plan, i)
        if st != CONC_STATUS_PROVED && st != CONC_STATUS_MEASURED:
            return 0
        i = i + 1
    return 1

fn conc_plan_cert_ok(plan: int) -> int, pub:
    if _conc_plan_valid(plan) == 0:
        return 0
    n := conc_plan_cert_count(plan)
    i : ., mut = 0
    loop:
        if i >= n:
            break
        st := conc_plan_cert_status(plan, i)
        if st != CONC_STATUS_PROVED && st != CONC_STATUS_MEASURED:
            return 0
        i = i + 1
    return 1

fn conc_plan_deterministic(plan: int) -> int, pub:
    // SPSC with one producer and one consumer is deterministic. MPMC has no
    // global order, and a second SEND/RECV edge on one channel would make the
    // observable order mapping-dependent, so both are rejected.
    if _conc_plan_valid(plan) == 0:
        return 0
    p := _conc_plan_at(plan)
    nch := cell_load(p, 8)
    chbase := load_str_ptr(p, 56)
    c : ., mut = 0
    loop:
        if c >= nch:
            break
        pc := cell_load(chbase, c * 32 + 16)
        if pc == CONC_PC_MPMC:
            return 0
        sends : ., mut = 0
        recvs : ., mut = 0
        ne := cell_load(p, 16)
        ebase := load_str_ptr(p, 64)
        e : ., mut = 0
        loop:
            if e >= ne:
                break
            kind := cell_load(ebase, e * 32 + 16)
            ch := cell_load(ebase, e * 32 + 24)
            if ch == c:
                if kind == CONC_EDGE_SEND:
                    sends = sends + 1
                if kind == CONC_EDGE_RECV:
                    recvs = recvs + 1
            e = e + 1
        if sends > 1:
            return 0
        if recvs > 1:
            return 0
        c = c + 1
    return 1

fn conc_run_range(plan: int, body: int, start: int, end: int,
                  out: string) -> int, pub:
    // Execute one PAR body over [start, end) and write entry(i) into out.
    // This is the CPU executor used by the v2 range record.
    if _conc_plan_valid(plan) == 0:
        return -1
    if body < 0 || body >= conc_plan_body_count(plan):
        return -1
    b := _conc_body_at(plan, body)
    if cell_load(b, 0) != CONC_BODY_DATA_PARALLEL:
        return -1
    params := cell_load(b, 16)
    if start < 0 || end < start || end > params:
        return -1
    entry := cell_load(b, 8)
    j : ., mut = start
    loop:
        if j >= end:
            break
        rc := _conc_call_int(entry, j)
        cell_store(out, (j - start) * 8, rc)
        j = j + 1
    // A scoped COUNT obligation on this body becomes a measured budget.
    nb := conc_plan_budget_count(plan)
    bi : ., mut = 0
    loop:
        if bi >= nb:
            break
        if conc_plan_budget_body(plan, bi) == body:
            if conc_plan_budget_kind(plan, bi) == CONC_BUDGET_COUNT:
                conc_plan_budget_measure(plan, bi, end - start)
        bi = bi + 1
    return 0

// ── Plan text loader (CP-2) ───────────────────────────────────────────────
//
// v1 format (whitespace separated):
//   v 1
//   entries <entry_table_size>
//   body <id> TASK|PAR <entry_index> <params>
//   channel <id> <elem_size> <cap> SPSC
//   edge <from> <to> SPAWN|SEND|JOIN|RECV <channel_id|-1>
//
// `entries` is a raw table: cell_load(entries, i * 8) is body i's entry
// address. Unsupported or malformed input returns -1; the caller must not
// execute a partially loaded plan.

fn _conc_int_token(t: string) -> int:
    n := str_len(t)
    if n <= 0:
        return 0
    i : ., mut = 0
    c : ., mut = get_char(t, 0)
    if c == "-":
        if n <= 1:
            return 0
        i = 1
    loop:
        if i >= n:
            return 1
        c = get_char(t, i)
        if str_cmp(c, "0") < 0:
            return 0
        if str_cmp(c, "9") > 0:
            return 0
        i = i + 1
    return 1

fn _conc_plan_next(text: string) -> string:
    n := str_len(text)
    p : ., mut = g_conc_plan_parse_pos
    loop:
        if p >= n:
            break
        c := get_char(text, p)
        if c == " " || c == "\n" || c == "\t" || c == "\r":
            p = p + 1
        else:
            break
    start := p
    loop:
        if p >= n:
            break
        c := get_char(text, p)
        if c == " " || c == "\n" || c == "\t" || c == "\r":
            break
        p = p + 1
    g_conc_plan_parse_pos = p
    if p <= start:
        return ""
    return str_sub(text, start, p - start)

fn _conc_plan_read_int(text: string) -> int:
    t := _conc_plan_next(text)
    if _conc_int_token(t) == 0:
        return -1
    return str_int(t)

fn _conc_plan_v2_token(p: int, text: string, tok: string) -> int:
    if tok == "target":
        name := _conc_plan_next(text)
        slots := _conc_plan_read_int(text)
        memory := _conc_plan_read_int(text)
        if str_len(name) <= 0 || slots < 0 || memory < 0:
            return -1
        if conc_plan_set_target(p, name, slots, memory) != 0:
            return -1
        return 0
    if tok == "slot":
        id := _conc_plan_read_int(text)
        ks := _conc_plan_next(text)
        kind : ., mut = -1
        if ks == "THREAD":
            kind = CONC_SLOT_CPU_THREAD
        else:
            if ks == "FIBER":
                kind = CONC_SLOT_CPU_FIBER
        parent := _conc_plan_read_int(text)
        count := _conc_plan_read_int(text)
        if id < 0 || kind < 0 || parent < -1 || count <= 0:
            return -1
        if id != conc_plan_slot_count(p):
            return -1
        if conc_plan_add_slot(p, kind, parent, count) != id:
            return -1
        return 0
    if tok == "range":
        body := _conc_plan_read_int(text)
        start := _conc_plan_read_int(text)
        count := _conc_plan_read_int(text)
        if conc_plan_add_range(p, body, start, count) < 0:
            return -1
        return 0
    if tok == "layout":
        id := _conc_plan_read_int(text)
        size := _conc_plan_read_int(text)
        hash := _conc_plan_read_int(text)
        if conc_plan_add_layout(p, id, size, hash) < 0:
            return -1
        return 0
    if tok == "space":
        id := _conc_plan_read_int(text)
        ks := _conc_plan_next(text)
        kind : ., mut = -1
        if ks == "HOST":
            kind = CONC_SPACE_HOST
        else:
            if ks == "DEVICE":
                kind = CONC_SPACE_DEVICE
            else:
                if ks == "REMOTE":
                    kind = CONC_SPACE_REMOTE
        cap := _conc_plan_read_int(text)
        if id < 0 || kind < 0 || cap <= 0:
            return -1
        if conc_plan_add_space(p, kind, cap) != id:
            return -1
        return 0
    if tok == "xfer":
        id := _conc_plan_read_int(text)
        ks := _conc_plan_next(text)
        kind : ., mut = -1
        if ks == "MOVE":
            kind = CONC_TRANSFER_MOVE
        else:
            if ks == "LOAN":
                kind = CONC_TRANSFER_LOAN
            else:
                if ks == "SPLIT":
                    kind = CONC_TRANSFER_SPLIT
                else:
                    if ks == "FILL":
                        kind = CONC_TRANSFER_FILL
                    else:
                        if ks == "COPY":
                            kind = CONC_TRANSFER_COPY
        src := _conc_plan_read_int(text)
        dst := _conc_plan_read_int(text)
        size := _conc_plan_read_int(text)
        ss := _conc_plan_read_int(text)
        ds := _conc_plan_read_int(text)
        if id < 0 || kind < 0:
            return -1
        if conc_plan_add_xfer(p, kind, src, dst, size, ss, ds) != id:
            return -1
        return 0
    if tok == "stage":
        id := _conc_plan_read_int(text)
        body := _conc_plan_read_int(text)
        in_ch := _conc_plan_read_int(text)
        out_ch := _conc_plan_read_int(text)
        ps := _conc_plan_next(text)
        policy : ., mut = -1
        if ps == "BLOCKING":
            policy = CONC_STAGE_BLOCKING
        else:
            if ps == "BOUNDED":
                policy = CONC_STAGE_BOUNDED
        if id < 0 || policy < 0:
            return -1
        if id != conc_plan_stage_count(p):
            return -1
        if conc_plan_add_stage(p, body, in_ch, out_ch, policy) != id:
            return -1
        return 0
    if tok == "transfer":
        id := _conc_plan_read_int(text)
        ks := _conc_plan_next(text)
        kind : ., mut = -1
        if ks == "MOVE":
            kind = CONC_TRANSFER_MOVE
        else:
            if ks == "LOAN":
                kind = CONC_TRANSFER_LOAN
            else:
                if ks == "SPLIT":
                    kind = CONC_TRANSFER_SPLIT
                else:
                    if ks == "FILL":
                        kind = CONC_TRANSFER_FILL
                    else:
                        if ks == "COPY":
                            kind = CONC_TRANSFER_COPY
        src := _conc_plan_read_int(text)
        dst := _conc_plan_read_int(text)
        size := _conc_plan_read_int(text)
        if id < 0 || kind < 0:
            return -1
        if id != conc_plan_transfer_count(p):
            return -1
        if conc_plan_add_transfer(p, kind, src, dst, size) != id:
            return -1
        return 0
    if tok == "budget":
        id := _conc_plan_read_int(text)
        ks := _conc_plan_next(text)
        kind : ., mut = -1
        if ks == "PROGRESSIVE":
            kind = CONC_BUDGET_PROGRESSIVE
        else:
            if ks == "COUNT":
                kind = CONC_BUDGET_COUNT
            else:
                if ks == "WAIT":
                    kind = CONC_BUDGET_WAIT
        bound := _conc_plan_read_int(text)
        ss := _conc_plan_next(text)
        status : ., mut = -1
        if ss == "PROVED":
            status = CONC_STATUS_PROVED
        else:
            if ss == "UNKNOWN":
                status = CONC_STATUS_UNKNOWN
            else:
                if ss == "VIOLATED":
                    status = CONC_STATUS_VIOLATED
                else:
                    if ss == "MEASURED":
                        status = CONC_STATUS_MEASURED
        if id < 0 || kind < 0 || status < 0:
            return -1
        if id != conc_plan_budget_count(p):
            return -1
        if conc_plan_add_budget(p, kind, bound, status) != id:
            return -1
        return 0
    if tok == "obligation":
        id := _conc_plan_read_int(text)
        ks := _conc_plan_next(text)
        kind : ., mut = -1
        if ks == "PROGRESSIVE":
            kind = CONC_BUDGET_PROGRESSIVE
        else:
            if ks == "COUNT":
                kind = CONC_BUDGET_COUNT
            else:
                if ks == "WAIT":
                    kind = CONC_BUDGET_WAIT
        bound := _conc_plan_read_int(text)
        ss := _conc_plan_next(text)
        status : ., mut = -1
        if ss == "PROVED":
            status = CONC_STATUS_PROVED
        else:
            if ss == "UNKNOWN":
                status = CONC_STATUS_UNKNOWN
            else:
                if ss == "VIOLATED":
                    status = CONC_STATUS_VIOLATED
                else:
                    if ss == "MEASURED":
                        status = CONC_STATUS_MEASURED
        body := _conc_plan_read_int(text)
        if id < 0 || kind < 0 || status < 0 || body < 0:
            return -1
        if id != conc_plan_budget_count(p):
            return -1
        if conc_plan_add_budget_body(p, kind, bound, status, body) != id:
            return -1
        return 0
    if tok == "cert":
        id := _conc_plan_read_int(text)
        kind := _conc_plan_read_int(text)
        ss := _conc_plan_next(text)
        status : ., mut = -1
        if ss == "PROVED":
            status = CONC_STATUS_PROVED
        else:
            if ss == "UNKNOWN":
                status = CONC_STATUS_UNKNOWN
            else:
                if ss == "VIOLATED":
                    status = CONC_STATUS_VIOLATED
                else:
                    if ss == "MEASURED":
                        status = CONC_STATUS_MEASURED
        if id < 0 || kind < 0 || status < 0:
            return -1
        if id != conc_plan_cert_count(p):
            return -1
        if conc_plan_add_cert(p, kind, status) != id:
            return -1
        return 0
    return -1

fn conc_plan_load(text: string, entries: string) -> int, pub:
    g_conc_plan_parse_pos = 0
    if _conc_plan_next(text) != "v":
        return -1
    ver := _conc_plan_read_int(text)
    if ver != 1 && ver != 2:
        return -1
    if _conc_plan_next(text) != "entries":
        return -1
    ec := _conc_plan_read_int(text)
    if ec <= 0:
        return -1
    if ec > CONC_MAX_ENTRIES:
        return -1
    if str_len(entries) + 1 < ec * 8:
        return -1
    p := conc_plan_new()
    if p < 0:
        return -1
    loop:
        tok := _conc_plan_next(text)
        if str_len(tok) == 0:
            break
        if tok == "body":
            id := _conc_plan_read_int(text)
            ks := _conc_plan_next(text)
            kind : ., mut = -1
            if ks == "TASK":
                kind = CONC_BODY_TASK
            else:
                if ks == "PAR":
                    kind = CONC_BODY_DATA_PARALLEL
                else:
                    if ks == "PIPE":
                        kind = CONC_BODY_PIPELINE
            if kind < 0:
                return -1
            ei := _conc_plan_read_int(text)
            params := _conc_plan_read_int(text)
            if id < 0 || ei < 0 || params < 0:
                return -1
            if id >= CONC_MAX_BODIES:
                return -1
            if params > CONC_MAX_PARAMS:
                return -1
            if ei >= ec:
                return -1
            if id != conc_plan_body_count(p):
                return -1
            entry := cell_load(entries, ei * 8)
            if entry <= 0:
                return -1
            if conc_plan_add_body(p, kind, entry, params) != id:
                return -1
        else:
            if tok == "channel":
                id := _conc_plan_read_int(text)
                elem := _conc_plan_read_int(text)
                cap := _conc_plan_read_int(text)
                pc := _conc_plan_next(text)
                if id < 0 || elem <= 0:
                    return -1
                if id >= CONC_MAX_CHANNELS:
                    return -1
                pcv : ., mut = -1
                if pc == "SPSC":
                    if cap <= 0:
                        return -1
                    pcv = CONC_PC_SPSC
                else:
                    if pc == "MPMC":
                        if cap < 0:
                            return -1
                        pcv = CONC_PC_MPMC
                    else:
                        return -1
                if ver == 1 && pcv != CONC_PC_SPSC:
                    return -1
                if id != conc_plan_channel_count(p):
                    return -1
                if conc_plan_add_channel(p, elem, cap, pcv) != id:
                    return -1
            else:
                if tok == "bind":
                    body := _conc_plan_read_int(text)
                    param := _conc_plan_read_int(text)
                    channel := _conc_plan_read_int(text)
                    if conc_plan_bind_param(p, body, param, channel) < 0:
                        return -1
                else:
                    if tok == "edge":
                        from_body := _conc_plan_read_int(text)
                        to_body := _conc_plan_read_int(text)
                        ks := _conc_plan_next(text)
                        kind : ., mut = -1
                        if ks == "SPAWN":
                            kind = CONC_EDGE_SPAWN
                        else:
                            if ks == "SEND":
                                kind = CONC_EDGE_SEND
                            else:
                                if ks == "JOIN":
                                    kind = CONC_EDGE_JOIN
                                else:
                                    if ks == "RECV":
                                        kind = CONC_EDGE_RECV
                        if kind < 0:
                            return -1
                        ct := _conc_plan_next(text)
                        if _conc_int_token(ct) == 0:
                            return -1
                        ch := str_int(ct)
                        if conc_plan_edge_count(p) >= CONC_MAX_EDGES:
                            return -1
                        if conc_plan_add_edge_ch(p, from_body, to_body, kind, ch) < 0:
                            return -1
                    else:
                        if ver != 2:
                            return -1
                        if _conc_plan_v2_token(p, text, tok) != 0:
                            return -1
    if _conc_plan_validate_edges(p) != 0:
        return -1
    cell_store(_conc_plan_at(p), 80, ver)
    return p

fn conc_plan_measure_xfers(plan: int, i: int) -> int, pub:
    bytes := conc_plan_xfer_bytes(plan)
    if bytes < 0:
        return -1
    if conc_plan_budget_measure(plan, i, bytes) != 0:
        return -1
    return bytes
