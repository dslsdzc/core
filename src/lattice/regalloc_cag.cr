// === regalloc_cag.cr ===
// Context-aware greedy register assignment (CAG), shared by the compiler
// register allocator and runtime-stub register assignment.
//
// The definition is docs/maintainer/design/regalloc-cache-mapping.md section 5.
// The algorithm is First Fit over live intervals with a cost-aware eviction
// rule:
//
//   spill_cost(e) = region_depth(e) * use_count(e) * (store_cost + load_cost)
//   remat_cost(e) = cost of regenerating e
//   evict_cost(e) = min(spill_cost(e), remat_cost(e))
//
// A new entry with no free register evicts the cheapest coexisting entry when
// eviction is enabled. The new entry itself is the eviction target when it is
// not cheaper than the others, which is the interval-order First Fit case.
//
// Calls are cache invalidation boundaries. At a call, every live entry in a
// caller-saved register is evicted; callee-saved entries stay. A pinned entry
// in a caller-saved register across a call is a constraint violation.
//
// The allocator owns its state. It has no register names and no encoding
// knowledge. A target supplies physical register numbers and a class per
// register.

CAG_REG_CALLEE : int = 0
CAG_REG_CALLER : int = 1

CAG_OK : int = 0
CAG_ERR_PIN_DISAGREE : int = -1
CAG_ERR_PIN_NOT_IN_FILE : int = -2
CAG_ERR_PIN_CONFLICT : int = -3
CAG_ERR_CALL_CLOBBER : int = -4

struct CagAllocator:
    count: int
    reg_count: int
    start: string
    end: string
    pin: string
    uses: string
    depth: string
    remat: string
    store: string
    load: string
    regs: string
    reg_class: string
    calls: string
    call_count: int
    assign: string
    spill: string
    remat_flag: string
    order: string
    spill_count: int
    allow_evict: int
    error: int
    pin_bad: int

fn cag_new(count: int, reg_count: int) -> CagAllocator:
    cap : ., mut = count
    if cap < 1:
        cap = 1
    rcap : ., mut = reg_count
    if rcap < 1:
        rcap = 1
    a := CagAllocator {
        count = count,
        reg_count = reg_count,
        start = alloc(cap * 8),
        end = alloc(cap * 8),
        pin = alloc(cap * 8),
        uses = alloc(cap * 8),
        depth = alloc(cap * 8),
        remat = alloc(cap * 8),
        store = alloc(cap * 8),
        load = alloc(cap * 8),
        regs = alloc(rcap * 8),
        reg_class = alloc(rcap * 8),
        calls = alloc(cap * 8),
        call_count = 0,
        assign = alloc(cap * 8),
        spill = alloc(cap * 8),
        remat_flag = alloc(cap * 8),
        order = alloc(cap * 8),
        spill_count = 0,
        allow_evict = 0,
        error = CAG_OK,
        pin_bad = 0,
    }
    i : ., mut = 0
    loop:
        if i >= cap:
            break
        cell_store(a.start, i * 8, -1)
        cell_store(a.end, i * 8, -1)
        cell_store(a.pin, i * 8, -1)
        // Default context: one use, depth 0, no rematerialisation, unit
        // store/load costs. Depth 0 makes the spill cost 0, so an entry is
        // evicted only when the caller supplies a positive depth.
        cell_store(a.uses, i * 8, 1)
        cell_store(a.depth, i * 8, 0)
        cell_store(a.remat, i * 8, -1)
        cell_store(a.store, i * 8, 1)
        cell_store(a.load, i * 8, 1)
        cell_store(a.assign, i * 8, -1)
        cell_store(a.spill, i * 8, -1)
        cell_store(a.remat_flag, i * 8, 0)
        cell_store(a.order, i * 8, i)
        cell_store(a.calls, i * 8, -1)
        i = i + 1
    k : ., mut = 0
    loop:
        if k >= rcap:
            break
        cell_store(a.regs, k * 8, -1)
        cell_store(a.reg_class, k * 8, CAG_REG_CALLEE)
        k = k + 1
    return a

impl CagAllocator:
    fn cand(&mut self, id: int, start: int, end: int):
        if id < 0 || id >= self.count:
            return
        cell_store(self.start, id * 8, start)
        cell_store(self.end, id * 8, end)

    fn reg(&mut self, k: int, phys: int, cls: int):
        if k < 0 || k >= self.reg_count:
            return
        cell_store(self.regs, k * 8, phys)
        cell_store(self.reg_class, k * 8, cls)

    fn context(&mut self, id: int, uses: int, depth: int, remat_cost: int, store_cost: int, load_cost: int):
        if id < 0 || id >= self.count:
            return
        cell_store(self.uses, id * 8, uses)
        cell_store(self.depth, id * 8, depth)
        cell_store(self.remat, id * 8, remat_cost)
        cell_store(self.store, id * 8, store_cost)
        cell_store(self.load, id * 8, load_cost)

    fn pin_entry(&mut self, id: int, phys: int):
        if id < 0 || id >= self.count:
            return
        old := cell_load(self.pin, id * 8)
        if old >= 0 && old != phys:
            self.pin_bad = 1
        cell_store(self.pin, id * 8, phys)

    fn call_at(&mut self, at: int):
        if self.call_count >= self.count:
            return
        cell_store(self.calls, self.call_count * 8, at)
        self.call_count = self.call_count + 1

    fn allow_eviction(&mut self, on: int):
        self.allow_evict = on

    fn assigned(&self, id: int) -> int:
        if id < 0 || id >= self.count:
            return -1
        return cell_load(self.assign, id * 8)

    fn spilled(&self, id: int) -> int:
        if id < 0 || id >= self.count:
            return -1
        return cell_load(self.spill, id * 8)

    fn rematted(&self, id: int) -> int:
        if id < 0 || id >= self.count:
            return 0
        return cell_load(self.remat_flag, id * 8)

    fn spills(&self) -> int:
        return self.spill_count

    fn error_code(&self) -> int:
        return self.error

    fn reg_index(&self, ph: int) -> int:
        k : ., mut = 0
        loop:
            if k >= self.reg_count:
                break
            if cell_load(self.regs, k * 8) == ph:
                return k
            k = k + 1
        return -1

    fn overlap(&self, a: int, b: int) -> int:
        sa := cell_load(self.start, a * 8)
        ea := cell_load(self.end, a * 8)
        sb := cell_load(self.start, b * 8)
        eb := cell_load(self.end, b * 8)
        if sa < 0 || sb < 0:
            return 0
        if sa <= eb && sb <= ea:
            return 1
        return 0

    // True when physical register ph is held by a coexisting entry. Pins count
    // before their entry is assigned.
    fn location_taken(&self, id: int, ph: int) -> int:
        w : ., mut = 0
        loop:
            if w >= self.count:
                break
            if w != id && self.overlap(id, w) != 0:
                if cell_load(self.pin, w * 8) == ph:
                    return 1
                if cell_load(self.assign, w * 8) == ph:
                    return 1
            w = w + 1
        return 0

    fn pick(&self, id: int) -> int:
        k : ., mut = 0
        loop:
            if k >= self.reg_count:
                break
            ph := cell_load(self.regs, k * 8)
            if self.location_taken(id, ph) == 0:
                return ph
            k = k + 1
        return -1

    fn spill_cost(&self, id: int) -> int:
        uses := cell_load(self.uses, id * 8)
        d := cell_load(self.depth, id * 8)
        s := cell_load(self.store, id * 8)
        l := cell_load(self.load, id * 8)
        return d * uses * (s + l)

    // Eviction cost. A negative remat cost means the entry has no generation
    // method, so only the spill cost is available.
    fn cost(&self, id: int) -> int:
        sp := self.spill_cost(id)
        rc := cell_load(self.remat, id * 8)
        if rc >= 0 && rc < sp:
            return rc
        return sp

    // Remove id from its register. A generation method cheaper than the spill is
    // recorded as remat; otherwise the entry gets a home slot.
    fn evict(&mut self, id: int):
        cell_store(self.assign, id * 8, -1)
        sp := self.spill_cost(id)
        rc := cell_load(self.remat, id * 8)
        if rc >= 0 && rc < sp:
            cell_store(self.remat_flag, id * 8, 1)
            return
        cell_store(self.spill, id * 8, self.spill_count)
        self.spill_count = self.spill_count + 1

    // Invalidate every live entry in a caller-saved register at a call. A pinned
    // entry cannot be evicted, so the constraint set is unsatisfiable.
    fn expire_calls(&mut self, at: int) -> int:
        w : ., mut = 0
        loop:
            if w >= self.count:
                break
            ph := cell_load(self.assign, w * 8)
            if ph >= 0:
                s := cell_load(self.start, w * 8)
                e := cell_load(self.end, w * 8)
                if s <= at && at <= e:
                    k := self.reg_index(ph)
                    if k >= 0 && cell_load(self.reg_class, k * 8) == CAG_REG_CALLER:
                        if cell_load(self.pin, w * 8) >= 0:
                            self.error = CAG_ERR_CALL_CLOBBER
                            return self.error
                        self.evict(w)
            w = w + 1
        return CAG_OK

    fn order_before(&self, a: int, b: int) -> int:
        sa := cell_load(self.start, a * 8)
        sb := cell_load(self.start, b * 8)
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

    fn sort_order(&mut self):
        i : ., mut = 1
        loop:
            if i >= self.count:
                break
            key := cell_load(self.order, i * 8)
            j : ., mut = i - 1
            loop:
                if j < 0:
                    break
                cur := cell_load(self.order, j * 8)
                if self.order_before(key, cur) == 0:
                    break
                cell_store(self.order, (j + 1) * 8, cur)
                j = j - 1
            cell_store(self.order, (j + 1) * 8, key)
            i = i + 1

    fn sort_calls(&mut self):
        i : ., mut = 1
        loop:
            if i >= self.call_count:
                break
            key := cell_load(self.calls, i * 8)
            j : ., mut = i - 1
            loop:
                if j < 0:
                    break
                cur := cell_load(self.calls, j * 8)
                if cur <= key:
                    break
                cell_store(self.calls, (j + 1) * 8, cur)
                j = j - 1
            cell_store(self.calls, (j + 1) * 8, key)
            i = i + 1

    fn run(&mut self) -> int:
        self.spill_count = 0
        self.error = CAG_OK

        if self.pin_bad != 0:
            self.error = CAG_ERR_PIN_DISAGREE
            return self.error

        vi : ., mut = 0
        loop:
            if vi >= self.count:
                break
            cell_store(self.assign, vi * 8, -1)
            cell_store(self.spill, vi * 8, -1)
            cell_store(self.remat_flag, vi * 8, 0)
            cell_store(self.order, vi * 8, vi)
            vi = vi + 1

        vi = 0
        loop:
            if vi >= self.count:
                break
            ph := cell_load(self.pin, vi * 8)
            if ph >= 0 && self.reg_index(ph) < 0:
                self.error = CAG_ERR_PIN_NOT_IN_FILE
                return self.error
            vi = vi + 1

        self.sort_order()
        self.sort_calls()

        call_i : ., mut = 0
        oi : ., mut = 0
        loop:
            if oi >= self.count:
                break
            id := cell_load(self.order, oi * 8)
            s := cell_load(self.start, id * 8)
            if s >= 0:
                // Calls at or before this start invalidate caller-saved entries
                // that were live at the call.
                loop:
                    if call_i >= self.call_count:
                        break
                    at := cell_load(self.calls, call_i * 8)
                    if at > s:
                        break
                    if self.expire_calls(at) != CAG_OK:
                        return self.error
                    call_i = call_i + 1

                pin := cell_load(self.pin, id * 8)
                if pin >= 0:
                    if self.location_taken(id, pin) != 0:
                        self.error = CAG_ERR_PIN_CONFLICT
                        return self.error
                    cell_store(self.assign, id * 8, pin)
                else:
                    got : ., mut = self.pick(id)
                    if got >= 0:
                        cell_store(self.assign, id * 8, got)
                    else:
                        target : ., mut = id
                        if self.allow_evict != 0:
                            best : ., mut = self.cost(id)
                            w : ., mut = 0
                            loop:
                                if w >= self.count:
                                    break
                                if w != id && cell_load(self.assign, w * 8) >= 0 && self.overlap(id, w) != 0:
                                    c := self.cost(w)
                                    if c < best:
                                        best = c
                                        target = w
                                w = w + 1
                        if target == id:
                            self.evict(id)
                        else:
                            self.evict(target)
                            got = self.pick(id)
                            if got >= 0:
                                cell_store(self.assign, id * 8, got)
                            else:
                                self.evict(id)
            oi = oi + 1

        // Calls after the last start still invalidate entries that span them.
        loop:
            if call_i >= self.call_count:
                break
            at := cell_load(self.calls, call_i * 8)
            if self.expire_calls(at) != CAG_OK:
                return self.error
            call_i = call_i + 1

        return self.error
