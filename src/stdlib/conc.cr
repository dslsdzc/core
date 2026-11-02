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

CONC_BUDGET_PROGRESSIVE : int, pub = 1
CONC_BUDGET_COUNT : int, pub = 2
CONC_BUDGET_WAIT : int, pub = 3

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
CONC_REF_SIZE : int = 48
CONC_MAX_LAYOUTS : int = 64

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

// Layout identity table: layout id -> element size + user hash. Populated by
// conc_layout_declare; consumers can check that a descriptor's layout is known
// before crossing a region boundary.
g_conc_layout_size : string, mut
g_conc_layout_hash : string, mut
g_conc_layout_count : int, mut = 0

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

fn conc_last_error() -> int, pub:
    return g_conc_last_error

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
        if _conc_is_null(g_conc_layout_size) != 0:
            return -1
        if _conc_is_null(g_conc_layout_hash) != 0:
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
    _conc_ref_invalidate(ref, CONC_REF_LOAN_MAGIC)
    return dst

fn conc_ref_return(src_ref: string, loan: string) -> int, pub:
    if _conc_is_null(src_ref) != 0:
        return -1
    if cell_load(src_ref, 0) != CONC_REF_LOAN_MAGIC:
        return -1
    if conc_ref_ok(loan) == 0:
        return -1
    size := cell_load(src_ref, 24)
    if cell_load(loan, 24) != size:
        return -1
    rid := cell_load(src_ref, 8)
    if _conc_region_valid(rid) == 0:
        return -1
    if cell_load(src_ref, 40) != cell_load(g_conc_region_epoch, rid * 8):
        return -1
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
    p := _conc_global_alloc(192)
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
    if _conc_plan_valid(plan) == 0:
        return -1
    if kind < CONC_BUDGET_PROGRESSIVE || kind > CONC_BUDGET_WAIT:
        return -1
    if bound < 0:
        return -1
    if status < CONC_STATUS_PROVED || status > CONC_STATUS_MEASURED:
        return -1
    p := _conc_plan_at(plan)
    n := cell_load(p, 120)
    if n >= 64:
        return -1
    base := load_str_ptr(p, 160)
    off := n * 40
    cell_store(base, off, kind)
    cell_store(base, off + 8, bound)
    cell_store(base, off + 16, status)
    cell_store(base, off + 24, 0)
    cell_store(base, off + 32, 0)
    cell_store(p, 120, n + 1)
    return n

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
