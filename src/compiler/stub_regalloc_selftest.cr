// === stub_regalloc_selftest.cr ===
// Case table for corec selftest-stub-regalloc.
//
// Each case fixes one obligation of the stub allocator. A case counts as one
// entry in the final "N/M stub-regalloc cases passed" line; individual
// assertions print FAIL with their own name.
//
// Cases:
//   disjoint_share           disjoint intervals reuse one register
//   overlap_needs_two        coexisting intervals get distinct registers
//   exhaustion_spills        register exhaustion spills, it does not fail
//   spill_slots_distinct     two spills get two home slots
//   pin_reserved             a pinned register is not given to a coexisting entry
//   pin_disagree             one entry pinned to two registers is rejected
//   pin_not_in_file          a pin outside the target register file is rejected
//   read_only_starts_at_use  a read-only entry starts at its first use
//   pin_conflict             two coexisting pins on one register are rejected

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
    sr_begin(4, 2, 1)
    sr_reg(0, 11)
    sr_write(0, 0)
    sr_read(1, 0)
    sr_write(2, 1)
    sr_read(3, 1)
    rc := sr_run()
    f : ., mut = 0
    f = f + srs_expect("disjoint.rc", rc, SR_OK)
    f = f + srs_expect("disjoint.v0", sr_assigned(0), 11)
    f = f + srs_expect("disjoint.v1", sr_assigned(1), 11)
    f = f + srs_expect("disjoint.spills", sr_spills(), 0)
    return f

fn srs_overlap_needs_two() -> int:
    sr_begin(3, 2, 2)
    sr_reg(0, 11)
    sr_reg(1, 12)
    sr_write(0, 0)
    sr_read(1, 0)
    sr_write(1, 1)
    sr_read(2, 1)
    rc := sr_run()
    a0 := sr_assigned(0)
    a1 := sr_assigned(1)
    f : ., mut = 0
    f = f + srs_expect("overlap.rc", rc, SR_OK)
    f = f + srs_expect("overlap.v0_assigned", srs_bool(a0 >= 0), 1)
    f = f + srs_expect("overlap.v1_assigned", srs_bool(a1 >= 0), 1)
    f = f + srs_expect("overlap.distinct", srs_bool(a0 != a1), 1)
    f = f + srs_expect("overlap.spills", sr_spills(), 0)
    return f

fn srs_exhaustion_spills() -> int:
    sr_begin(4, 2, 1)
    sr_reg(0, 0)
    sr_write(0, 0)
    sr_read(1, 0)
    sr_write(1, 1)
    sr_read(2, 0)
    sr_read(3, 1)
    rc := sr_run()
    f : ., mut = 0
    f = f + srs_expect("exhaust.rc", rc, SR_OK)
    f = f + srs_expect("exhaust.v0", sr_assigned(0), 0)
    f = f + srs_expect("exhaust.v1_spill", sr_spilled(1), 0)
    f = f + srs_expect("exhaust.v1_no_reg", sr_assigned(1), -1)
    f = f + srs_expect("exhaust.spills", sr_spills(), 1)
    return f

fn srs_spill_slots_distinct() -> int:
    sr_begin(4, 3, 1)
    sr_reg(0, 0)
    sr_write(0, 0)
    sr_write(1, 1)
    sr_write(2, 2)
    sr_read(3, 0)
    sr_read(3, 1)
    sr_read(3, 2)
    rc := sr_run()
    s0 := sr_spilled(0)
    s1 := sr_spilled(1)
    s2 := sr_spilled(2)
    f : ., mut = 0
    f = f + srs_expect("slots.rc", rc, SR_OK)
    f = f + srs_expect("slots.count", sr_spills(), 2)
    f = f + srs_expect("slots.distinct", srs_bool(s0 != s1 && s1 != s2 && s0 != s2), 1)
    return f

fn srs_pin_reserved() -> int:
    sr_begin(3, 2, 2)
    sr_reg(0, 10)
    sr_reg(1, 11)
    sr_write(0, 0)
    sr_read(1, 0)
    sr_write(1, 1)
    sr_pin(1, 1, 11)
    sr_read(2, 1)
    rc := sr_run()
    f : ., mut = 0
    f = f + srs_expect("pin.rc", rc, SR_OK)
    f = f + srs_expect("pin.v1", sr_assigned(1), 11)
    f = f + srs_expect("pin.v0", sr_assigned(0), 10)
    f = f + srs_expect("pin.spills", sr_spills(), 0)
    return f

fn srs_pin_disagree() -> int:
    sr_begin(2, 1, 2)
    sr_reg(0, 0)
    sr_reg(1, 1)
    sr_write(0, 0)
    sr_pin(0, 0, 0)
    sr_read(1, 0)
    sr_pin(1, 0, 1)
    rc := sr_run()
    f : ., mut = 0
    f = f + srs_expect("pin_disagree.rc", rc, SR_ERR_PIN_DISAGREE)
    return f

fn srs_pin_not_in_file() -> int:
    sr_begin(1, 1, 1)
    sr_reg(0, 0)
    sr_write(0, 0)
    sr_pin(0, 0, 7)
    rc := sr_run()
    f : ., mut = 0
    f = f + srs_expect("pin_outside.rc", rc, SR_ERR_PIN_NOT_IN_FILE)
    return f

fn srs_read_only_starts_at_use() -> int:
    sr_begin(3, 2, 1)
    sr_reg(0, 5)
    sr_write(0, 1)
    sr_read(1, 1)
    sr_read(2, 0)
    rc := sr_run()
    f : ., mut = 0
    f = f + srs_expect("readonly.rc", rc, SR_OK)
    f = f + srs_expect("readonly.v1", sr_assigned(1), 5)
    f = f + srs_expect("readonly.v0", sr_assigned(0), 5)
    f = f + srs_expect("readonly.spills", sr_spills(), 0)
    return f

fn srs_pin_conflict() -> int:
    sr_begin(2, 2, 2)
    sr_reg(0, 10)
    sr_reg(1, 11)
    sr_write(0, 0)
    sr_pin(0, 0, 10)
    sr_write(0, 1)
    sr_pin(0, 1, 10)
    sr_read(1, 0)
    sr_read(1, 1)
    rc := sr_run()
    f : ., mut = 0
    f = f + srs_expect("pin_conflict.rc", rc, SR_ERR_PIN_CONFLICT)
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

    print(int_str(g_srs_total - g_srs_fails))
    print("/")
    print(int_str(g_srs_total))
    println(" stub-regalloc cases passed")
    if g_srs_fails > 0:
        return 1
    return 0
