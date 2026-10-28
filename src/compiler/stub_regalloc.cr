// === stub_regalloc.cr ===
// Register assignment for runtime stubs, expressed with the shared CAG
// allocator (src/lattice/regalloc_cag.cr).
//
// A stub is a straight-line instruction list. It is written with virtual
// registers and target positions, never with physical register names. The
// adapter builds one live interval per virtual register from the instruction
// list, then delegates the assignment to CagAllocator.
//
// Call sequence:
//
//   a := sr_new(instr_count, vreg_count, reg_count)
//   a.reg(k, phys) / a.op(i, op) / a.read(i, v) / a.write(i, v)
//   a.pin(i, v, phys)
//   rc := a.run()
//   a.assigned(v) / a.spilled(v) / a.spills()
//
// Pins are hard constraints. A pinned register is never given to a coexisting
// entry, and an unsatisfiable pin is an error rather than a silent spill.

SR_INSTR_MAX_READS : int = 4
SR_INSTR_MAX_WRITES : int = 2
SR_INSTR_MAX_PINS : int = 2

// The error values are literals, not aliases of CAG_ERR_*: the bootstrap build
// does not fold a constant initialised from another constant, so an alias would
// read as 0. The values must stay equal to CAG_ERR_*.
SR_OK : int = 0
SR_ERR_PIN_DISAGREE : int = -1
SR_ERR_PIN_NOT_IN_FILE : int = -2
SR_ERR_PIN_CONFLICT : int = -3

struct StubAllocator:
    cag: CagAllocator
    instr_count: int
    vreg_count: int
    reg_count: int
    ops: string
    reads: string
    read_n: string
    writes: string
    write_n: string
    pin_v: string
    pin_p: string
    pin_n: string
    regs: string
    v_start: string
    v_end: string
    v_pin: string
    assign: string
    spill: string
    spill_count: int
    error: int

fn sr_new(instr_count: int, vreg_count: int, reg_count: int) -> StubAllocator:
    icap : ., mut = instr_count
    if icap < 1:
        icap = 1
    vcap : ., mut = vreg_count
    if vcap < 1:
        vcap = 1
    rcap : ., mut = reg_count
    if rcap < 1:
        rcap = 1

    a := StubAllocator {
        cag = cag_new(vreg_count, reg_count),
        instr_count = instr_count,
        vreg_count = vreg_count,
        reg_count = reg_count,
        ops = alloc(icap * 8),
        reads = alloc(icap * SR_INSTR_MAX_READS * 8),
        read_n = alloc(icap * 8),
        writes = alloc(icap * SR_INSTR_MAX_WRITES * 8),
        write_n = alloc(icap * 8),
        pin_v = alloc(icap * SR_INSTR_MAX_PINS * 8),
        pin_p = alloc(icap * SR_INSTR_MAX_PINS * 8),
        pin_n = alloc(icap * 8),
        regs = alloc(rcap * 8),
        v_start = alloc(vcap * 8),
        v_end = alloc(vcap * 8),
        v_pin = alloc(vcap * 8),
        assign = alloc(vcap * 8),
        spill = alloc(vcap * 8),
        spill_count = 0,
        error = SR_OK,
    }
    i : ., mut = 0
    loop:
        if i >= icap:
            break
        cell_store(a.ops, i * 8, 0)
        cell_store(a.read_n, i * 8, 0)
        cell_store(a.write_n, i * 8, 0)
        cell_store(a.pin_n, i * 8, 0)
        i = i + 1
    vi : ., mut = 0
    loop:
        if vi >= vcap:
            break
        cell_store(a.v_start, vi * 8, -1)
        cell_store(a.v_end, vi * 8, -1)
        cell_store(a.v_pin, vi * 8, -1)
        cell_store(a.assign, vi * 8, -1)
        cell_store(a.spill, vi * 8, -1)
        vi = vi + 1
    k : ., mut = 0
    loop:
        if k >= rcap:
            break
        cell_store(a.regs, k * 8, -1)
        k = k + 1
    return a

impl StubAllocator:
    fn reg(&mut self, k: int, phys: int):
        if k >= 0 && k < self.reg_count:
            cell_store(self.regs, k * 8, phys)

    fn op(&mut self, i: int, op: int):
        if i >= 0 && i < self.instr_count:
            cell_store(self.ops, i * 8, op)

    fn read(&mut self, i: int, v: int):
        if i < 0 || i >= self.instr_count:
            return
        n := cell_load(self.read_n, i * 8)
        if n >= SR_INSTR_MAX_READS:
            return
        cell_store(self.reads, (i * SR_INSTR_MAX_READS + n) * 8, v)
        cell_store(self.read_n, i * 8, n + 1)

    fn write(&mut self, i: int, v: int):
        if i < 0 || i >= self.instr_count:
            return
        n := cell_load(self.write_n, i * 8)
        if n >= SR_INSTR_MAX_WRITES:
            return
        cell_store(self.writes, (i * SR_INSTR_MAX_WRITES + n) * 8, v)
        cell_store(self.write_n, i * 8, n + 1)

    fn pin(&mut self, i: int, v: int, phys: int):
        if i < 0 || i >= self.instr_count:
            return
        n := cell_load(self.pin_n, i * 8)
        if n >= SR_INSTR_MAX_PINS:
            return
        cell_store(self.pin_v, (i * SR_INSTR_MAX_PINS + n) * 8, v)
        cell_store(self.pin_p, (i * SR_INSTR_MAX_PINS + n) * 8, phys)
        cell_store(self.pin_n, i * 8, n + 1)

    fn assigned(&self, v: int) -> int:
        if v < 0 || v >= self.vreg_count:
            return -1
        return cell_load(self.assign, v * 8)

    fn spilled(&self, v: int) -> int:
        if v < 0 || v >= self.vreg_count:
            return -1
        return cell_load(self.spill, v * 8)

    fn spills(&self) -> int:
        return self.spill_count

    fn error_code(&self) -> int:
        return self.error

    // Extend the interval of v to instruction i. A read-only entry starts at its
    // first use; the encoder must define it before that instruction.
    fn touch(&mut self, v: int, i: int):
        if v < 0 || v >= self.vreg_count:
            return
        if cell_load(self.v_start, v * 8) < 0:
            cell_store(self.v_start, v * 8, i)
        cell_store(self.v_end, v * 8, i)

    fn run(&mut self) -> int:
        self.spill_count = 0
        self.error = SR_OK
        self.cag = cag_new(self.vreg_count, self.reg_count)

        k : ., mut = 0
        loop:
            if k >= self.reg_count:
                break
            self.cag.reg(k, cell_load(self.regs, k * 8), CAG_REG_CALLEE)
            k = k + 1

        vi : ., mut = 0
        loop:
            if vi >= self.vreg_count:
                break
            cell_store(self.v_start, vi * 8, -1)
            cell_store(self.v_end, vi * 8, -1)
            cell_store(self.v_pin, vi * 8, -1)
            cell_store(self.assign, vi * 8, -1)
            cell_store(self.spill, vi * 8, -1)
            vi = vi + 1

        ii : ., mut = 0
        loop:
            if ii >= self.instr_count:
                break
            ri : ., mut = 0
            loop:
                if ri >= cell_load(self.read_n, ii * 8):
                    break
                v := cell_load(self.reads, (ii * SR_INSTR_MAX_READS + ri) * 8)
                self.touch(v, ii)
                ri = ri + 1
            wi : ., mut = 0
            loop:
                if wi >= cell_load(self.write_n, ii * 8):
                    break
                v := cell_load(self.writes, (ii * SR_INSTR_MAX_WRITES + wi) * 8)
                self.touch(v, ii)
                wi = wi + 1
            pi : ., mut = 0
            loop:
                if pi >= cell_load(self.pin_n, ii * 8):
                    break
                v := cell_load(self.pin_v, (ii * SR_INSTR_MAX_PINS + pi) * 8)
                ph := cell_load(self.pin_p, (ii * SR_INSTR_MAX_PINS + pi) * 8)
                self.touch(v, ii)
                old := cell_load(self.v_pin, v * 8)
                if old >= 0 && old != ph:
                    self.error = SR_ERR_PIN_DISAGREE
                    return self.error
                cell_store(self.v_pin, v * 8, ph)
                pi = pi + 1
            ii = ii + 1

        vi = 0
        loop:
            if vi >= self.vreg_count:
                break
            s := cell_load(self.v_start, vi * 8)
            if s >= 0:
                self.cag.cand(vi, s, cell_load(self.v_end, vi * 8))
            ph := cell_load(self.v_pin, vi * 8)
            if ph >= 0:
                self.cag.pin_entry(vi, ph)
            vi = vi + 1

        rc := self.cag.run()
        self.error = rc
        if rc != CAG_OK:
            return rc

        vi = 0
        loop:
            if vi >= self.vreg_count:
                break
            cell_store(self.assign, vi * 8, self.cag.assigned(vi))
            cell_store(self.spill, vi * 8, self.cag.spilled(vi))
            vi = vi + 1
        self.spill_count = self.cag.spills()
        return self.error
