// === stub_regalloc_selftest.cr ===
// Case table for corec selftest-stub-regalloc.
//
// Each case fixes one obligation of the stub allocator. A case counts as one
// entry in the final "N/M stub-regalloc cases passed" line; individual
// assertions print FAIL with their own name.

g_srs_total : int, mut = 0
g_srs_fails : int, mut = 0

fn srs_bool(b: bool) -> int:
    if b:
        return 1
    return 0

fn srs_expect(name: string, got: int, want: int) -> int:
    if got == want:
        return 0
    print("FAIL ")
    print(name)
    print(": got ")
    print(int_str(got))
    print(" want ")
    println(int_str(want))
    return 1

fn srs_case(name: string, fails: int):
    g_srs_total = g_srs_total + 1
    if fails == 0:
        print("PASS ")
        println(name)
    else:
        g_srs_fails = g_srs_fails + 1

fn srs_disjoint_share() -> int:
    a := sr_new(4, 2, 1)
    a.reg(0, 11)
    a.write(0, 0)
    a.read(1, 0)
    a.write(2, 1)
    a.read(3, 1)
    rc := a.run()
    f : ., mut = 0
    f = f + srs_expect("disjoint.rc", rc, SR_OK)
    f = f + srs_expect("disjoint.v0", a.assigned(0), 11)
    f = f + srs_expect("disjoint.v1", a.assigned(1), 11)
    f = f + srs_expect("disjoint.spills", a.spills(), 0)
    return f

fn srs_overlap_needs_two() -> int:
    a := sr_new(3, 2, 2)
    a.reg(0, 11)
    a.reg(1, 12)
    a.write(0, 0)
    a.read(1, 0)
    a.write(1, 1)
    a.read(2, 1)
    rc := a.run()
    a0 := a.assigned(0)
    a1 := a.assigned(1)
    f : ., mut = 0
    f = f + srs_expect("overlap.rc", rc, SR_OK)
    f = f + srs_expect("overlap.v0_assigned", srs_bool(a0 >= 0), 1)
    f = f + srs_expect("overlap.v1_assigned", srs_bool(a1 >= 0), 1)
    f = f + srs_expect("overlap.distinct", srs_bool(a0 != a1), 1)
    f = f + srs_expect("overlap.spills", a.spills(), 0)
    return f

fn srs_exhaustion_spills() -> int:
    a := sr_new(4, 2, 1)
    a.reg(0, 0)
    a.write(0, 0)
    a.read(1, 0)
    a.write(1, 1)
    a.read(2, 0)
    a.read(3, 1)
    rc := a.run()
    f : ., mut = 0
    f = f + srs_expect("exhaust.rc", rc, SR_OK)
    f = f + srs_expect("exhaust.v0", a.assigned(0), 0)
    f = f + srs_expect("exhaust.v1_spill", a.spilled(1), 0)
    f = f + srs_expect("exhaust.v1_no_reg", a.assigned(1), -1)
    f = f + srs_expect("exhaust.spills", a.spills(), 1)
    return f

fn srs_spill_slots_distinct() -> int:
    a := sr_new(4, 3, 1)
    a.reg(0, 0)
    a.write(0, 0)
    a.write(1, 1)
    a.write(2, 2)
    a.read(3, 0)
    a.read(3, 1)
    a.read(3, 2)
    rc := a.run()
    s0 := a.spilled(0)
    s1 := a.spilled(1)
    s2 := a.spilled(2)
    f : ., mut = 0
    f = f + srs_expect("slots.rc", rc, SR_OK)
    f = f + srs_expect("slots.count", a.spills(), 2)
    f = f + srs_expect("slots.distinct", srs_bool(s0 != s1 && s1 != s2 && s0 != s2), 1)
    return f

fn srs_pin_reserved() -> int:
    a := sr_new(3, 2, 2)
    a.reg(0, 10)
    a.reg(1, 11)
    a.write(0, 0)
    a.read(1, 0)
    a.write(1, 1)
    a.pin(1, 1, 11)
    a.read(2, 1)
    rc := a.run()
    f : ., mut = 0
    f = f + srs_expect("pin.rc", rc, SR_OK)
    f = f + srs_expect("pin.v1", a.assigned(1), 11)
    f = f + srs_expect("pin.v0", a.assigned(0), 10)
    f = f + srs_expect("pin.spills", a.spills(), 0)
    return f

fn srs_pin_disagree() -> int:
    a := sr_new(2, 1, 2)
    a.reg(0, 0)
    a.reg(1, 1)
    a.write(0, 0)
    a.pin(0, 0, 0)
    a.read(1, 0)
    a.pin(1, 0, 1)
    rc := a.run()
    f : ., mut = 0
    f = f + srs_expect("pin_disagree.rc", rc, SR_ERR_PIN_DISAGREE)
    return f

fn srs_pin_not_in_file() -> int:
    a := sr_new(1, 1, 1)
    a.reg(0, 0)
    a.write(0, 0)
    a.pin(0, 0, 7)
    rc := a.run()
    f : ., mut = 0
    f = f + srs_expect("pin_outside.rc", rc, SR_ERR_PIN_NOT_IN_FILE)
    return f

fn srs_read_only_starts_at_use() -> int:
    a := sr_new(3, 2, 1)
    a.reg(0, 5)
    a.write(0, 1)
    a.read(1, 1)
    a.read(2, 0)
    rc := a.run()
    f : ., mut = 0
    f = f + srs_expect("readonly.rc", rc, SR_OK)
    f = f + srs_expect("readonly.v1", a.assigned(1), 5)
    f = f + srs_expect("readonly.v0", a.assigned(0), 5)
    f = f + srs_expect("readonly.spills", a.spills(), 0)
    return f

fn srs_pin_conflict() -> int:
    a := sr_new(2, 2, 2)
    a.reg(0, 10)
    a.reg(1, 11)
    a.write(0, 0)
    a.pin(0, 0, 10)
    a.write(0, 1)
    a.pin(0, 1, 10)
    a.read(1, 0)
    a.read(1, 1)
    rc := a.run()
    f : ., mut = 0
    f = f + srs_expect("pin_conflict.rc", rc, SR_ERR_PIN_CONFLICT)
    return f

fn srs_cag_evict_cheaper() -> int:
    a := cag_new(3, 2)
    a.reg(0, 10, CAG_REG_CALLEE)
    a.reg(1, 11, CAG_REG_CALLEE)
    a.cand(0, 0, 2)
    a.cand(1, 0, 2)
    a.cand(2, 0, 2)
    a.context(0, 10, 10, -1, 1, 1)  // spill cost 200
    a.context(1, 1, 1, -1, 1, 1)    // spill cost 2
    a.context(2, 5, 1, -1, 1, 1)    // spill cost 10
    a.allow_eviction(1)
    rc := a.run()
    f : ., mut = 0
    f = f + srs_expect("cag_evict.rc", rc, CAG_OK)
    f = f + srs_expect("cag_evict.cheap_spilled", srs_bool(a.spilled(1) >= 0), 1)
    f = f + srs_expect("cag_evict.new_assigned", srs_bool(a.assigned(2) >= 0), 1)
    return f

fn srs_cag_remat() -> int:
    a := cag_new(2, 1)
    a.reg(0, 10, CAG_REG_CALLEE)
    a.cand(0, 0, 1)
    a.cand(1, 0, 1)
    a.context(0, 10, 10, 1, 1, 1)  // spill 200, remat 1
    a.context(1, 5, 1, -1, 1, 1)   // spill 10
    a.allow_eviction(1)
    rc := a.run()
    f : ., mut = 0
    f = f + srs_expect("cag_remat.rc", rc, CAG_OK)
    f = f + srs_expect("cag_remat.no_register", a.assigned(0), -1)
    f = f + srs_expect("cag_remat.flag", a.rematted(0), 1)
    f = f + srs_expect("cag_remat.no_home", a.spilled(0), -1)
    f = f + srs_expect("cag_remat.new_assigned", a.assigned(1), 10)
    return f

fn srs_cag_call_clobber() -> int:
    a := cag_new(2, 2)
    a.reg(0, 10, CAG_REG_CALLEE)
    a.reg(1, 11, CAG_REG_CALLER)
    a.cand(0, 0, 2)
    a.cand(1, 0, 2)
    a.call_at(1)
    rc := a.run()
    f : ., mut = 0
    f = f + srs_expect("cag_call.rc", rc, CAG_OK)
    f = f + srs_expect("cag_call.callee_kept", srs_bool(a.assigned(0) >= 0), 1)
    f = f + srs_expect("cag_call.caller_evicted", a.assigned(1), -1)
    f = f + srs_expect("cag_call.caller_home", srs_bool(a.spilled(1) >= 0), 1)
    return f

fn srs_cag_pin_call_clobber() -> int:
    a := cag_new(1, 1)
    a.reg(0, 10, CAG_REG_CALLER)
    a.cand(0, 0, 2)
    a.pin_entry(0, 10)
    a.call_at(1)
    rc := a.run()
    f : ., mut = 0
    f = f + srs_expect("cag_pin_call.rc", rc, CAG_ERR_CALL_CLOBBER)
    return f

fn stub_regalloc_selftest_run() -> int:
    g_srs_total = 0
    g_srs_fails = 0

    srs_case("disjoint_share", srs_disjoint_share())
    srs_case("overlap_needs_two", srs_overlap_needs_two())
    srs_case("exhaustion_spills", srs_exhaustion_spills())
    srs_case("spill_slots_distinct", srs_spill_slots_distinct())
    srs_case("pin_reserved", srs_pin_reserved())
    srs_case("pin_disagree", srs_pin_disagree())
    srs_case("pin_not_in_file", srs_pin_not_in_file())
    srs_case("read_only_starts_at_use", srs_read_only_starts_at_use())
    srs_case("pin_conflict", srs_pin_conflict())
    srs_case("cag_evict_cheaper", srs_cag_evict_cheaper())
    srs_case("cag_remat", srs_cag_remat())
    srs_case("cag_call_clobber", srs_cag_call_clobber())
    srs_case("cag_pin_call_clobber", srs_cag_pin_call_clobber())

    print(int_str(g_srs_total - g_srs_fails))
    print("/")
    print(int_str(g_srs_total))
    println(" stub-regalloc cases passed")
    if g_srs_fails > 0:
        return 1
    return 0
