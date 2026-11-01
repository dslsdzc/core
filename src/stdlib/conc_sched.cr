// conc_sched — single-thread cooperative activation scheduler for CP-4.
//
// This is the default host CPU mapping for `go`/`chan` in CP-4. It uses the
// backend fiber stubs (fiber_init/fiber_switch) and CP-1 conc channels, but
// remains single-slot: one ready queue, one current activation, no atomics or
// locks. Runtime objects live in activation arenas or the global heap.
import conc
import arena

CONC_SCHED_STACK : int = 16384
CONC_ACT_SIZE : int = 72
CONC_ACT_RUNNABLE : int = 0
CONC_ACT_RUNNING : int = 1
CONC_ACT_WAITING : int = 2
CONC_ACT_DEAD : int = 3

CONC_CH_STATE_SIZE : int = 48
CONC_WAIT_SEND : int = 0
CONC_WAIT_RECV : int = 1

g_conc_inited : int, mut = 0
g_conc_acts : string, mut
g_conc_act_count : int, mut = 0
g_conc_act_cap : int, mut = 0
g_conc_cur : int, mut = -1
g_conc_ready : string, mut
g_conc_ready_head : int, mut = 0
g_conc_ready_tail : int, mut = 0
g_conc_ready_count : int, mut = 0
g_conc_ready_cap : int, mut = 0
g_conc_sched_sp : string, mut
g_conc_global_region : int, mut = -1
g_conc_ch_states : string, mut
g_conc_ch_count : int, mut = 0
g_conc_ch_cap : int, mut = 0

fn _conc_sched_alloc(size: int) -> string:
    saved := rt_current_arena()
    rt_set_current_arena(-1)
    p := alloc(size)
    rt_set_current_arena(saved)
    return p

fn _conc_act_at(id: int) -> string:
    if id < 0 || id >= g_conc_act_count:
        return ""
    return load_str_ptr(g_conc_acts, id * 8)

fn _conc_ready_grow():
    if g_conc_ready_count < g_conc_ready_cap:
        return
    nc : ., mut = g_conc_ready_cap * 2
    if nc < 64:
        nc = 64
    nb := _conc_sched_alloc(nc * 8)
    i : ., mut = 0
    pos : ., mut = g_conc_ready_head
    loop:
        if i >= g_conc_ready_count:
            break
        cell_store(nb, i * 8, cell_load(g_conc_ready, pos * 8))
        pos = pos + 1
        if pos >= g_conc_ready_cap:
            pos = 0
        i = i + 1
    g_conc_ready = nb
    g_conc_ready_head = 0
    g_conc_ready_tail = g_conc_ready_count
    g_conc_ready_cap = nc

fn _conc_ready_push(id: int):
    _conc_ready_grow()
    cell_store(g_conc_ready, g_conc_ready_tail * 8, id)
    g_conc_ready_tail = g_conc_ready_tail + 1
    if g_conc_ready_tail >= g_conc_ready_cap:
        g_conc_ready_tail = 0
    g_conc_ready_count = g_conc_ready_count + 1

fn _conc_ready_pop() -> int:
    if g_conc_ready_count <= 0:
        return -1
    id := cell_load(g_conc_ready, g_conc_ready_head * 8)
    g_conc_ready_head = g_conc_ready_head + 1
    if g_conc_ready_head >= g_conc_ready_cap:
        g_conc_ready_head = 0
    g_conc_ready_count = g_conc_ready_count - 1
    return id

fn _conc_acts_grow():
    if g_conc_act_count < g_conc_act_cap:
        return
    nc : ., mut = g_conc_act_cap * 2
    if nc < 16:
        nc = 16
    nb := _conc_sched_alloc(nc * 8)
    i : ., mut = 0
    loop:
        if i >= g_conc_act_count:
            break
        store_str_ptr(nb, i * 8, _conc_act_at(i))
        i = i + 1
    g_conc_acts = nb
    g_conc_act_cap = nc

fn conc_sched_init():
    if g_conc_inited != 0:
        return
    g_conc_acts = _conc_sched_alloc(16 * 8)
    g_conc_act_cap = 16
    g_conc_ready = _conc_sched_alloc(64 * 8)
    g_conc_ready_cap = 64
    g_conc_sched_sp = _conc_sched_alloc(8)
    g_conc_ch_states = _conc_sched_alloc(16 * CONC_CH_STATE_SIZE)
    g_conc_ch_cap = 16
    g_conc_inited = 1

fn _conc_act_new(entry: int, arg: int, result_ch: string) -> int:
    conc_sched_init()
    _conc_acts_grow()
    saved := arena_current_unchecked()
    aid := arena_new()
    if aid < 0:
        arena_set_current_unchecked(saved)
        return -1
    stack := alloc(CONC_SCHED_STACK)
    a := alloc(CONC_ACT_SIZE)
    arena_set_current_unchecked(saved)
    if _conc_word(stack) == 0 || _conc_word(a) == 0:
        return -1
    id := g_conc_act_count
    sp := fiber_init(stack + CONC_SCHED_STACK - 8, @addr(_conc_activation_entry))
    cell_store(a, 0, id)
    cell_store(a, 8, CONC_ACT_RUNNABLE)
    cell_store(a, 16, sp)
    cell_store(a, 24, stack)
    cell_store(a, 32, entry)
    cell_store(a, 40, arg)
    store_str_ptr(a, 48, result_ch)
    cell_store(a, 56, -1)
    cell_store(a, 64, aid)
    store_str_ptr(g_conc_acts, id * 8, a)
    g_conc_act_count = id + 1
    return id

fn _conc_word(s: string) -> int:
    v : ., mut = 0
    unsafe:
        v = @ptr_of(s)
    return v

fn conc_spawn(entry: int, arg: int, result_ch: string) -> int, pub:
    id := _conc_act_new(entry, arg, result_ch)
    if id < 0:
        return -1
    _conc_ready_push(id)
    return id

fn conc_sched_curg() -> int, pub:
    return g_conc_cur

fn conc_schedule() -> int, pub:
    ran : ., mut = 0
    if g_conc_cur < 0:
        saved := arena_current_unchecked()
        loop:
            id := _conc_ready_pop()
            if id < 0:
                return ran
            a := _conc_act_at(id)
            if _conc_word(a) == 0:
                continue
            ran = 1
            g_conc_cur = id
            cell_store(a, 8, CONC_ACT_RUNNING)
            arena_set_current_unchecked(cell_load(a, 64))
            fiber_switch(_conc_ptr_addr(g_conc_sched_sp), cell_load(a, 16))
            arena_set_current_unchecked(saved)
            g_conc_cur = -1
    else:
        a := _conc_act_at(g_conc_cur)
        if _conc_word(a) == 0:
            g_conc_cur = -1
            return 0
        cell_store(a, 64, arena_current_unchecked())
        fiber_switch(@ptr_add(a, 16), cell_load(g_conc_sched_sp, 0))
    return ran

fn _conc_ptr_addr(s: string) -> int:
    v : ., mut = 0
    unsafe:
        v = @ptr_of(s)
    return v

fn conc_yield(), pub:
    if g_conc_cur < 0:
        return
    a := _conc_act_at(g_conc_cur)
    if _conc_word(a) == 0:
        return
    cell_store(a, 8, CONC_ACT_RUNNABLE)
    _conc_ready_push(g_conc_cur)
    conc_schedule()

fn _conc_activation_entry():
    id := g_conc_cur
    a := _conc_act_at(id)
    if _conc_word(a) == 0:
        return
    entry := cell_load(a, 32)
    arg := cell_load(a, 40)
    tbl := _conc_sched_alloc(8)
    cell_store(tbl, 0, entry)
    rc := sched_call_1(tbl, 0, arg)
    ch := load_str_ptr(a, 48)
    if _conc_word(ch) != 0:
        conc_sched_send_int(ch, rc)
    cell_store(a, 8, CONC_ACT_DEAD)
    loop:
        conc_schedule()
    return

fn _conc_ch_grow():
    if g_conc_ch_count < g_conc_ch_cap:
        return
    nc : ., mut = g_conc_ch_cap * 2
    if nc < 16:
        nc = 16
    nb := _conc_sched_alloc(nc * CONC_CH_STATE_SIZE)
    i : ., mut = 0
    loop:
        if i >= g_conc_ch_count * CONC_CH_STATE_SIZE:
            break
        store8(nb, i, load8(g_conc_ch_states, i))
        i = i + 1
    g_conc_ch_states = nb
    g_conc_ch_cap = nc

fn _conc_ch_slot(ch: string) -> int:
    conc_sched_init()
    i : ., mut = 0
    loop:
        if i >= g_conc_ch_count:
            break
        p := load_str_ptr(g_conc_ch_states, i * CONC_CH_STATE_SIZE)
        if _conc_word(p) == _conc_word(ch):
            return i
        i = i + 1
    _conc_ch_grow()
    slot := g_conc_ch_count
    store_str_ptr(g_conc_ch_states, slot * CONC_CH_STATE_SIZE, ch)
    cell_store(g_conc_ch_states, slot * CONC_CH_STATE_SIZE + 8, 0)
    cell_store(g_conc_ch_states, slot * CONC_CH_STATE_SIZE + 16, -1)
    cell_store(g_conc_ch_states, slot * CONC_CH_STATE_SIZE + 24, -1)
    cell_store(g_conc_ch_states, slot * CONC_CH_STATE_SIZE + 32, -1)
    cell_store(g_conc_ch_states, slot * CONC_CH_STATE_SIZE + 40, -1)
    g_conc_ch_count = slot + 1
    return slot

fn _conc_wait_push(slot: int, kind: int, id: int):
    base := slot * CONC_CH_STATE_SIZE
    head_off : ., mut = 16
    if kind == CONC_WAIT_RECV:
        head_off = 32
    tail_off := head_off + 8
    head := cell_load(g_conc_ch_states, base + head_off)
    tail := cell_load(g_conc_ch_states, base + tail_off)
    a := _conc_act_at(id)
    cell_store(a, 56, -1)
    if head < 0:
        cell_store(g_conc_ch_states, base + head_off, id)
        cell_store(g_conc_ch_states, base + tail_off, id)
    else:
        t := _conc_act_at(tail)
        cell_store(t, 56, id)
        cell_store(g_conc_ch_states, base + tail_off, id)

fn _conc_wait_pop(slot: int, kind: int) -> int:
    base := slot * CONC_CH_STATE_SIZE
    head_off : ., mut = 16
    if kind == CONC_WAIT_RECV:
        head_off = 32
    tail_off := head_off + 8
    head := cell_load(g_conc_ch_states, base + head_off)
    if head < 0:
        return -1
    a := _conc_act_at(head)
    nxt : ., mut = -1
    if _conc_word(a) != 0:
        nxt = cell_load(a, 56)
    cell_store(g_conc_ch_states, base + head_off, nxt)
    if nxt < 0:
        cell_store(g_conc_ch_states, base + tail_off, -1)
    return head

fn _conc_wake_one(slot: int, kind: int):
    id := _conc_wait_pop(slot, kind)
    if id < 0:
        return
    a := _conc_act_at(id)
    if _conc_word(a) == 0:
        return
    cell_store(a, 8, CONC_ACT_RUNNABLE)
    _conc_ready_push(id)

fn _conc_wake_all(slot: int, kind: int):
    loop:
        id := _conc_wait_pop(slot, kind)
        if id < 0:
            return
        a := _conc_act_at(id)
        if _conc_word(a) != 0:
            cell_store(a, 8, CONC_ACT_RUNNABLE)
            _conc_ready_push(id)

fn _conc_ch_closed(slot: int) -> int:
    return cell_load(g_conc_ch_states, slot * CONC_CH_STATE_SIZE + 8)

fn _conc_ch_set_closed(slot: int):
    cell_store(g_conc_ch_states, slot * CONC_CH_STATE_SIZE + 8, 1)

fn _conc_ch_cap(ch: string) -> int:
    return cell_load(ch, 16)

fn _conc_ch_head(ch: string) -> int:
    return cell_load(ch, 32)

fn _conc_ch_len(ch: string) -> int:
    return cell_load(ch, 24)

fn _conc_ch_buf(ch: string) -> string:
    return load_str_ptr(ch, 8)

fn _conc_ch_esize(ch: string) -> int:
    return cell_load(ch, 40)

fn _conc_global_region_get() -> int:
    if g_conc_global_region >= 0:
        return g_conc_global_region
    r := conc_region_new(1048576)
    if r >= 0:
        g_conc_global_region = r
    return r

fn conc_chan_make(elemsize: int, cap: int) -> string, pub:
    conc_sched_init()
    r : ., mut = _conc_global_region_get()
    if r < 0:
        return ""
    ch : ., mut = conc_channel_new(r, elemsize, cap)
    if _conc_word(ch) == 0:
        r = conc_region_new(1048576)
        if r < 0:
            return ""
        g_conc_global_region = r
        ch = conc_channel_new(r, elemsize, cap)
    return ch

fn conc_sched_send_int(ch: string, val: int) -> int, pub:
    conc_sched_init()
    if conc_channel_len(ch) < 0:
        return -1
    esize := _conc_ch_esize(ch)
    if esize < 8:
        return -1
    slot := _conc_ch_slot(ch)
    loop:
        if _conc_ch_closed(slot) != 0:
            return 0
        cap := _conc_ch_cap(ch)
        n := _conc_ch_len(ch)
        if n < cap:
            buf := _conc_ch_buf(ch)
            head := _conc_ch_head(ch)
            pos : ., mut = head + n
            if pos >= cap:
                pos = pos - cap
            cell_store(buf, pos * esize, val)
            cell_store(ch, 24, n + 1)
            _conc_wake_one(slot, CONC_WAIT_RECV)
            return 0
        if g_conc_cur < 0:
            if conc_schedule() == 0:
                return 0
            continue
        _conc_wait_push(slot, CONC_WAIT_SEND, g_conc_cur)
        a := _conc_act_at(g_conc_cur)
        cell_store(a, 8, CONC_ACT_WAITING)
        conc_schedule()

fn conc_sched_recv_int(ch: string) -> int, pub:
    conc_sched_init()
    if conc_channel_len(ch) < 0:
        return 0
    esize := _conc_ch_esize(ch)
    if esize < 8:
        return 0
    slot := _conc_ch_slot(ch)
    loop:
        n := _conc_ch_len(ch)
        if n > 0:
            buf := _conc_ch_buf(ch)
            head : ., mut = _conc_ch_head(ch)
            v := cell_load(buf, head * esize)
            head = head + 1
            if head >= _conc_ch_cap(ch):
                head = 0
            cell_store(ch, 32, head)
            cell_store(ch, 24, n - 1)
            _conc_wake_one(slot, CONC_WAIT_SEND)
            return v
        if _conc_ch_closed(slot) != 0:
            return 0
        if g_conc_cur < 0:
            if conc_schedule() == 0:
                return 0
            continue
        _conc_wait_push(slot, CONC_WAIT_RECV, g_conc_cur)
        a := _conc_act_at(g_conc_cur)
        cell_store(a, 8, CONC_ACT_WAITING)
        conc_schedule()

fn conc_sched_close(ch: string), pub:
    conc_sched_init()
    if conc_channel_len(ch) < 0:
        return
    slot := _conc_ch_slot(ch)
    _conc_ch_set_closed(slot)
    _conc_wake_all(slot, CONC_WAIT_SEND)
    _conc_wake_all(slot, CONC_WAIT_RECV)

fn conc_go(entry: int, arg: int) -> string, pub:
    conc_sched_init()
    r := _conc_global_region_get()
    if r < 0:
        return ""
    ch := conc_channel_new(r, 8, 1)
    if _conc_word(ch) == 0:
        return ""
    if conc_spawn(entry, arg, ch) < 0:
        return ""
    return ch
