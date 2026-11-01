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

CONC_EDGE_SPAWN : int, pub = 1
CONC_EDGE_SEND : int, pub = 2
CONC_EDGE_JOIN : int, pub = 3

CONC_MSG_MAGIC : int = 1129270851       // "CONC"
CONC_CHANNEL_MAGIC : int = 1129270856   // "CONH"
CONC_MSG_HEADER : int = 32

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

// A single 8-byte table used by sched_call_1. CP-1 executes one body at a
// time; concurrent mappings will eventually own their own call tables.
g_conc_call_table : string, mut

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

// Allocate outside the current compiler function arena. Runtime objects must
// live in owner regions, never in a function arena.
fn _conc_global_alloc(size: int) -> string:
    saved := rt_current_arena()
    rt_set_current_arena(-1)
    p := alloc(size)
    rt_set_current_arena(saved)
    return p

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
    if _conc_addr(nb) == 0:
        return -1
    if _conc_addr(cb) == 0:
        return -1
    if _conc_addr(cu) == 0:
        return -1
    if _conc_addr(ep) == 0:
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
    if size <= 1:
        return -1
    if _conc_region_ensure(g_conc_region_count + 1) != 0:
        return -1
    block := _conc_global_alloc(size)
    if _conc_addr(block) == 0:
        return -1
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
    aligned : ., mut = (size + 15) / 16 * 16
    total := CONC_MSG_HEADER + aligned
    cursor := cell_load(g_conc_region_cursor, region * 8)
    cap := cell_load(g_conc_region_cap, region * 8)
    if cursor + total > cap:
        return _conc_ptr(0)
    base := load_str_ptr(g_conc_region_block, region * 8)
    if _conc_addr(base) == 0:
        return _conc_ptr(0)
    hdr := _conc_ptr(_conc_addr(base) + cursor)
    cell_store(hdr, 0, CONC_MSG_MAGIC)
    cell_store(hdr, 8, region)
    cell_store(hdr, 16, cell_load(g_conc_region_epoch, region * 8))
    cell_store(hdr, 24, size + 1)
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

fn conc_is_ok(p: string) -> int, pub:
    if str_len(p) <= 0:
        return 0
    a := _conc_addr(p)
    if a < CONC_MSG_HEADER:
        return 0
    hdr := _conc_ptr(a - CONC_MSG_HEADER)
    if cell_load(hdr, 0) != CONC_MSG_MAGIC:
        return 0
    return 1

fn conc_same(a: string, b: string) -> int, pub:
    if _conc_addr(a) == _conc_addr(b):
        return 1
    return 0

fn _conc_msg_hdr(p: string) -> string:
    a := _conc_addr(p)
    if a < CONC_MSG_HEADER:
        return _conc_ptr(0)
    return _conc_ptr(a - CONC_MSG_HEADER)

fn _conc_msg_size(p: string) -> int:
    hdr := _conc_msg_hdr(p)
    if _conc_addr(hdr) == 0:
        return -1
    return cell_load(hdr, 24) - 1

fn _conc_msg_region(p: string) -> int:
    hdr := _conc_msg_hdr(p)
    if _conc_addr(hdr) == 0:
        return -1
    return cell_load(hdr, 8)

fn _conc_msg_epoch(p: string) -> int:
    hdr := _conc_msg_hdr(p)
    if _conc_addr(hdr) == 0:
        return -1
    return cell_load(hdr, 16)

// A message is valid only while its owner region is live and its epoch
// matches. region_reset advances the epoch, so stale payload pointers stop
// being accepted by send/recv without needing a free list.
fn _conc_msg_valid(p: string) -> int:
    if conc_is_ok(p) == 0:
        return 0
    rid := _conc_msg_region(p)
    if _conc_region_valid(rid) == 0:
        return 0
    if _conc_msg_epoch(p) != cell_load(g_conc_region_epoch, rid * 8):
        return 0
    base := load_str_ptr(g_conc_region_block, rid * 8)
    lo := _conc_addr(base)
    hi := lo + cell_load(g_conc_region_cap, rid * 8)
    a := _conc_addr(p)
    sz := _conc_msg_size(p)
    if sz <= 0:
        return 0
    if a < lo + CONC_MSG_HEADER:
        return 0
    if a + sz > hi:
        return 0
    return 1

// ── Typed channel ─────────────────────────────────────────────────────────
//
// Channel header (64 bytes):
//   0 magic, 8 buf, 16 cap, 24 len, 32 head, 40 esize,
//   48 owner_region, 56 owner_epoch.
// The buffer is the payload tail after the 64-byte header.

fn _conc_channel_valid(ch: string) -> int:
    if _conc_msg_valid(ch) == 0:
        return 0
    if cell_load(ch, 0) != CONC_CHANNEL_MAGIC:
        return 0
    rid := cell_load(ch, 48)
    if _conc_region_valid(rid) == 0:
        return 0
    if cell_load(ch, 56) != cell_load(g_conc_region_epoch, rid * 8):
        return 0
    if cell_load(ch, 40) <= 0:
        return 0
    if cell_load(ch, 16) <= 0:
        return 0
    n := cell_load(ch, 24)
    if n < 0:
        return 0
    if n > cell_load(ch, 16):
        return 0
    if _conc_addr(load_str_ptr(ch, 8)) == 0:
        return 0
    return 1

fn conc_channel_new(region: int, elem_size: int, cap: int) -> string, pub:
    if _conc_region_valid(region) == 0:
        return _conc_ptr(0)
    if elem_size <= 0:
        return _conc_ptr(0)
    if cap <= 0:
        return _conc_ptr(0)
    total := 64 + cap * elem_size
    ch := conc_alloc(region, total)
    if _conc_addr(ch) == 0:
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
        return 0
    return cell_load(ch, 24)

fn conc_channel_elemsize(ch: string) -> int, pub:
    if _conc_channel_valid(ch) == 0:
        return 0
    return cell_load(ch, 40)

fn conc_send(ch: string, msg: string) -> int, pub:
    if _conc_channel_valid(ch) == 0:
        return -1
    if _conc_msg_valid(msg) == 0:
        return -1
    esize := cell_load(ch, 40)
    if _conc_msg_size(msg) != esize:
        return -1
    cap := cell_load(ch, 16)
    n := cell_load(ch, 24)
    if n >= cap:
        return 1
    head := cell_load(ch, 32)
    buf := load_str_ptr(ch, 8)
    slot : ., mut = head + n
    if slot >= cap:
        slot = slot - cap
    dst := _conc_ptr(_conc_addr(buf) + slot * esize)
    _conc_copy(dst, msg, esize)
    cell_store(ch, 24, n + 1)
    return 0

fn conc_recv(ch: string) -> string, pub:
    if _conc_channel_valid(ch) == 0:
        return _conc_ptr(0)
    n := cell_load(ch, 24)
    if n <= 0:
        return _conc_ptr(0)
    esize := cell_load(ch, 40)
    rid := cell_load(ch, 48)
    out := conc_alloc(rid, esize)
    if _conc_addr(out) == 0:
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
    if _conc_addr(nb) == 0:
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
    if _conc_addr(p) == 0:
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
    if _conc_addr(nb) == 0:
        return -1
    old := load_str_ptr(p, 48)
    if _conc_addr(old) != 0:
        _conc_copy(nb, old, cell_load(p, 0) * 32)
    store_str_ptr(p, 48, nb)
    cell_store(p, 24, nc)
    return 0

fn _conc_plan_grow_channels(p: string, cap: int) -> int:
    nc : ., mut = cap * 2
    if nc < 8:
        nc = 8
    nb := _conc_global_alloc(nc * 32)
    if _conc_addr(nb) == 0:
        return -1
    old := load_str_ptr(p, 56)
    if _conc_addr(old) != 0:
        _conc_copy(nb, old, cell_load(p, 8) * 32)
    store_str_ptr(p, 56, nb)
    cell_store(p, 32, nc)
    return 0

fn _conc_plan_grow_edges(p: string, cap: int) -> int:
    nc : ., mut = cap * 2
    if nc < 8:
        nc = 8
    nb := _conc_global_alloc(nc * 32)
    if _conc_addr(nb) == 0:
        return -1
    old := load_str_ptr(p, 64)
    if _conc_addr(old) != 0:
        _conc_copy(nb, old, cell_load(p, 16) * 32)
    store_str_ptr(p, 64, nb)
    cell_store(p, 40, nc)
    return 0

fn conc_plan_new() -> int, pub:
    if _conc_plan_ensure(g_conc_plan_count + 1) != 0:
        return -1
    p := _conc_global_alloc(80)
    if _conc_addr(p) == 0:
        return -1
    bodies := _conc_global_alloc(8 * 32)
    channels := _conc_global_alloc(8 * 32)
    edges := _conc_global_alloc(8 * 32)
    if _conc_addr(bodies) == 0:
        return -1
    if _conc_addr(channels) == 0:
        return -1
    if _conc_addr(edges) == 0:
        return -1
    store_str_ptr(p, 48, bodies)
    store_str_ptr(p, 56, channels)
    store_str_ptr(p, 64, edges)
    cell_store(p, 24, 8)
    cell_store(p, 32, 8)
    cell_store(p, 40, 8)
    id := g_conc_plan_count
    store_str_ptr(g_conc_plans, id * 8, p)
    g_conc_plan_count = id + 1
    return id

fn conc_plan_add_body(plan: int, kind: int, entry: int, params: int) -> int, pub:
    if _conc_plan_valid(plan) == 0:
        return -1
    if kind != CONC_BODY_TASK && kind != CONC_BODY_DATA_PARALLEL:
        return -1
    if params < 0:
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
    if pc <= 0:
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

fn conc_plan_add_edge(plan: int, from_body: int, to_body: int, kind: int) -> int, pub:
    if _conc_plan_valid(plan) == 0:
        return -1
    p := _conc_plan_at(plan)
    n := cell_load(p, 16)
    if from_body < 0 || from_body >= cell_load(p, 0):
        return -1
    if to_body < 0 || to_body >= cell_load(p, 0):
        return -1
    if kind != CONC_EDGE_SPAWN && kind != CONC_EDGE_SEND && kind != CONC_EDGE_JOIN:
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
    cell_store(base, off + 24, 0)
    cell_store(p, 16, n + 1)
    return n

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

fn _conc_body_at(plan: int, idx: int) -> string:
    p := _conc_plan_at(plan)
    base := load_str_ptr(p, 48)
    return _conc_ptr(_conc_addr(base) + idx * 32)

// ── Executors ─────────────────────────────────────────────────────────────
//
// Both executors consume the same plan. CPU is a single logical slot with a
// serial fallback for DATA_PARALLEL; SIMT is a host-side index-domain mapping.
// Neither executor invents target capabilities.

fn _conc_call_ready() -> int:
    if _conc_addr(g_conc_call_table) == 0:
        g_conc_call_table = _conc_global_alloc(8)
        if _conc_addr(g_conc_call_table) == 0:
            return 0
    return 1

fn _conc_call_str(entry: int, arg: string) -> int:
    if entry == 0:
        return -1
    if _conc_call_ready() == 0:
        return -1
    cell_store(g_conc_call_table, 0, entry)
    return sched_call_1(_conc_addr(g_conc_call_table), 0, _conc_addr(arg))

fn _conc_call_int(entry: int, arg: int) -> int:
    if entry == 0:
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
        if kind == CONC_BODY_TASK:
            rc := _conc_call_str(entry, arg)
            if rc != 0:
                return rc
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
