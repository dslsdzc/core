// === corearch.cr ===
// Backend: .ccr to ELF, assembly, or shared object.
// Supports: --elf (static), --shared (DSO), --link (dynamic linking)

// ------------------------------------------------------------------
// Instance declaration table
// ------------------------------------------------------------------
// The instance declaration is the only coupling between the kernel and an
// instance. The language has no higher-order functions, so capabilities are data
// fields and dispatch queries the active instance row.
// Each row is 10 i32 fields, 40 bytes:
//   id, name index, opt_min, opt_max, allow_table, allow_link,
//   needs_alloc, needs_verify, needs_eviction, needs_call_sites.
// x86 instance:
//   option window 0..3, link allowed, allocation and verification required.
//   Eviction and call-site checks are declared 0 because static placement has no
//   eviction events and callee-saved registers satisfy call-site contracts.
// table instance:
//   option window 0..0, table input allowed, link rejected, no allocation or
//   verification. The table path is straight-line O0.
// instance_select reads --table, looks up the instance name, and falls back to
// x86. The debug dispatch queries the same row fields.
INST_X86 : int = 0
INST_TABLE : int = 1
INST_DECL_STRIDE : int = 40    // 行 = 10 × i32（LE）
INST_OFF_ID : int = 0
INST_OFF_NAME : int = 4
INST_OFF_OPT_MIN : int = 8
INST_OFF_OPT_MAX : int = 12
INST_OFF_ALLOW_TABLE : int = 16
INST_OFF_ALLOW_LINK : int = 20
INST_OFF_NEEDS_ALLOC : int = 24
INST_OFF_NEEDS_VERIFY : int = 28
INST_OFF_NEEDS_EVICTION : int = 32     // eviction capability declaration; kernel does not implement it
INST_OFF_NEEDS_CALL_SITES : int = 36   // call-site capability declaration; kernel does not implement it

g_instance_decl : string, mut  // 实例声明表（行 × INST_DECL_STRIDE 字节）
g_instance_count : int, mut
g_instance_cap : int, mut
g_active_instance : int, mut   // 引导选中实例行（= id；instance_select 设定）

fn grow_instance_decl(needed: int):
    if needed < g_instance_cap:
        return
    nc : ., mut = g_instance_cap * 2
    if nc < 2:
        nc = 2
    if nc < needed:
        nc = needed
    nb := alloc(nc * INST_DECL_STRIDE)
    _dyncpy(g_instance_decl, g_instance_cap * INST_DECL_STRIDE, nb)
    g_instance_decl = nb
    g_instance_cap = nc

fn instance_decl_add(id: int, name_idx: int, opt_min: int, opt_max: int,
    allow_table: int, allow_link: int, needs_alloc: int,
    needs_verify: int, needs_eviction: int, needs_call_sites: int):
    grow_instance_decl(g_instance_count + 1)
    off : ., mut = g_instance_count * INST_DECL_STRIDE
    w32(g_instance_decl, off + INST_OFF_ID, id)
    w32(g_instance_decl, off + INST_OFF_NAME, name_idx)
    w32(g_instance_decl, off + INST_OFF_OPT_MIN, opt_min)
    w32(g_instance_decl, off + INST_OFF_OPT_MAX, opt_max)
    w32(g_instance_decl, off + INST_OFF_ALLOW_TABLE, allow_table)
    w32(g_instance_decl, off + INST_OFF_ALLOW_LINK, allow_link)
    w32(g_instance_decl, off + INST_OFF_NEEDS_ALLOC, needs_alloc)
    w32(g_instance_decl, off + INST_OFF_NEEDS_VERIFY, needs_verify)
    w32(g_instance_decl, off + INST_OFF_NEEDS_EVICTION, needs_eviction)
    w32(g_instance_decl, off + INST_OFF_NEEDS_CALL_SITES, needs_call_sites)
    g_instance_count = g_instance_count + 1

fn instance_decl_init():
    // Idempotent. All declaration fields are non-negative, so unsigned r32 reads
    // are safe. Names are interned before load_ccr; load_ccr later reloads the
    // string table from the .ccr STR segment, so these indexes are only valid
    // during boot. instance_select consumes them before loading.
    if g_instance_count > 0:
        return
    // Eviction and call-site fields are 0 for both instances. They declare
    // capability only; this kernel does not implement those checks.
    instance_decl_add(INST_X86, str_intern("x86"), 0, 3, 0, 1, 1, 1, 0, 0)
    instance_decl_add(INST_TABLE, str_intern("table"), 0, 0, 1, 0, 0, 0, 0, 0)

fn inst_id(i: int) -> int:
    return r32(g_instance_decl, i * INST_DECL_STRIDE + INST_OFF_ID)
fn inst_name(i: int) -> int:
    return r32(g_instance_decl, i * INST_DECL_STRIDE + INST_OFF_NAME)
fn inst_opt_min(i: int) -> int:
    return r32(g_instance_decl, i * INST_DECL_STRIDE + INST_OFF_OPT_MIN)
fn inst_opt_max(i: int) -> int:
    return r32(g_instance_decl, i * INST_DECL_STRIDE + INST_OFF_OPT_MAX)
fn inst_allow_table(i: int) -> int:
    return r32(g_instance_decl, i * INST_DECL_STRIDE + INST_OFF_ALLOW_TABLE)
fn inst_allow_link(i: int) -> int:
    return r32(g_instance_decl, i * INST_DECL_STRIDE + INST_OFF_ALLOW_LINK)
fn inst_needs_alloc(i: int) -> int:
    return r32(g_instance_decl, i * INST_DECL_STRIDE + INST_OFF_NEEDS_ALLOC)
fn inst_needs_verify(i: int) -> int:
    return r32(g_instance_decl, i * INST_DECL_STRIDE + INST_OFF_NEEDS_VERIFY)
fn inst_needs_eviction(i: int) -> int:
    return r32(g_instance_decl, i * INST_DECL_STRIDE + INST_OFF_NEEDS_EVICTION)
fn inst_needs_call_sites(i: int) -> int:
    return r32(g_instance_decl, i * INST_DECL_STRIDE + INST_OFF_NEEDS_CALL_SITES)

fn instance_lookup(name_idx: int) -> int:
    // Look up by interned name index. Returns -1 when absent.
    i : ., mut = 0
    loop:
        if i >= g_instance_count:
            break
        if inst_name(i) == name_idx:
            return i
        i = i + 1
    return -1

fn instance_select() -> int:
    // Select an instance from --table. Row order equals id order. Fall back to the
    // x86 instance if the lookup misses.
    nm : ., mut = "x86"
    if str_len(cli_get("table")) > 0:
        nm = "table"
    r := instance_lookup(str_intern(nm))
    if r < 0:
        return INST_X86
    return r

fn init_backend_arrays():
    g_x86_var_count = 0
    g_x86_stack_size = 0
    g_x86_func_idx = 0
    g_x86_is_enum_count = 0
    g_x86_var_cap = 0
    g_x86_is_enum_cap = 0
    g_stack_map = ""

fn split_links(val: string):
    sl := str_len(val)
    start : ., mut = 0
    i : ., mut = 0
    loop:
        if i > sl:
            break
        if i == sl || load8(val, i) == 44:
            if i > start:
                p := str_sub(val, start, i - start)
                ctx_add_so(p)
            start = i + 1
        i = i + 1

// Debug dispatch for allocation data and checks. The flags are the corearch
// versions of the old corec hidden flags; they compute from the loaded .ccr.
// Returns 0 when no flag was requested, 1 when handled successfully, and 2 when a
// check failed.
// The --check-regalloc order is fixed: force O2, allocate, read
// meta_reg_assign_total, run the three injection hooks, verify, then print the
// summary and return.
fn regalloc_debug_dispatch() -> int:
    if cli_has("dump-entries") != 0:
        compute_live_ranges()
        dump_entries_summary()
        return 1
    if cli_has("inject-coexist-oob") != 0:
        compute_live_ranges()
        if inject_coexist_oob() != 0:
            return 2
        return 1
    if cli_has("dump-coexist") != 0:
        compute_live_ranges()
        dump_coexist_summary()
        return 1
    if cli_has("dump-regassign") != 0:
        // After allocation, print var-to-register pairs. Allocation runs only at O2; O0/O1 produce none.
        if g_opt_level >= 2:
            alloc_registers()
        mi : ., mut = 0
        loop:
            if mi >= g_opt_meta_count:
                break
            mo := mi * OPT_META_STRIDE
            if r32(g_opt_meta, mo) == OPT_KEY_REG_ASSIGN:
                cnt := r32(g_opt_meta, mo + 8)
                di : ., mut = 0
                loop:
                    if di >= cnt:
                        break
                    print("regassign: ")
                    print(int_str(r32(g_opt_meta, mo + 12 + di * 8)))
                    print(" ")
                    println(int_str(r32(g_opt_meta, mo + 16 + di * 8)))
                    di = di + 1
            mi = mi + 1
        return 1
    if cli_has("check-regalloc") != 0:
        saved_opt := g_opt_level
        g_opt_level = 2
        alloc_registers()
        // Watchdog line: total REG_ASSIGN pairs. A positive count proves real
        // register allocation. The .ccr no longer carries corec allocation results.
        print("regalloc-assign: ")
        print(int_str(meta_reg_assign_total()))
        println(" pairs")
        if cli_has("inject-home-conflict") != 0:
            inject_home_conflict()
        if cli_has("inject-reg-conflict") != 0:
            inject_reg_conflict()
        if cli_has("inject-read-gap") != 0:
            inject_read_gap()
        nv := regalloc_verify_all()
        g_opt_level = saved_opt
        print("regalloc-consistency: funcs ")
        print(int_str(g_ir_func_count))
        print(" violations ")
        println(int_str(nv))
        if nv != 0:
            return 2
        return 1
    return 0

// --dump-objects: print the loaded object image through the kernel accessors in
// ent_kernel.cr. Each node prints its semantic fields, adjacency, and outgoing
// edges. Edge traversal uses nod_inputs. The line format is parsed by
// tests/selfhost/test_ccr_v7.py:parse_object_dump.
// --dump-alloc-strides: expose the element-type-driven IR_ALLOC_ARRAY stride.
// Read-only test channel. It runs after the TYPE segment is rebuilt, before
// linear reconstruction, and returns without emitting.
fn dump_alloc_strides():
    print("alloc-strides: ")
    print_i(g_v7_nod_count)
    println("")
    ni : ., mut = 0
    loop:
        if ni >= g_v7_nod_count:
            break
        if nod_op(ni) == IR_ALLOC_ARRAY:
            dv := nod_dest(ni)
            ti : ., mut = -1
            if dv >= 0:
                ti = irv_type(dv)
            kind : ., mut = -1
            elem : ., mut = -1
            if ti >= 0 && ti < g_type_count:
                kind = get_type_kind(ti)
                if kind == TYP_ARRAY:
                    elem = get_type_data(ti)
            print("alloc ")
            print_i(ni)
            print(" dest ")
            print_i(dv)
            print(" ti ")
            print_i(ti)
            print(" kind ")
            print_i(kind)
            print(" elem ")
            print_i(elem)
            print(" stride ")
            print_i(corearch_nod_alloc_stride(ni, dv))
            println("")
        ni = ni + 1

fn dump_object_surface():
    print("objects: ")
    print_i(g_v7_nod_count)
    println("")
    ni : ., mut = 0
    loop:
        if ni >= g_v7_nod_count:
            break
        print("nod ")
        print_i(ni)
        print(" op ")
        print_i(nod_op(ni))
        print(" dest ")
        print_i(nod_dest(ni))
        print(" s1 ")
        print_i(nod_s1(ni))
        print(" s2 ")
        print_i(nod_s2(ni))
        print(" s3 ")
        print_i(nod_s3(ni))
        print(" tk ")
        print_i(nod_tk(ni))
        print(" fe ")
        print_i(nod_edge_first(ni))
        print(" ec ")
        print_i(nod_edge_count(ni))
        println("")
        if nod_op(ni) == IR_MATCH:
            // CASE rows are part of the match node's dumped surface. The range
            // comes from the MATCH operands; targets are NOD ids of LABEL nodes.
            mstart := nod_s2(ni)
            mcount := nod_s3(ni)
            mi3 : ., mut = 0
            loop:
                if mi3 >= mcount:
                    break
                cbase := (mstart + mi3) * CCR_V10_CASE_DISK
                print("case ")
                print_i(mstart + mi3)
                print(" value ")
                print_i(cell_load(g_ccr_case, cbase + CCR_CASE_VALUE))
                print(" kind ")
                print_i(cell_load32(g_ccr_case, cbase + CCR_CASE_KIND))
                print(" str ")
                print_i(cell_load_i32(g_ccr_case, cbase + CCR_CASE_STR))
                print(" target ")
                print_i(cell_load_i32(g_ccr_case, cbase + CCR_CASE_TARGET))
                print(" flags ")
                print_i(cell_load32(g_ccr_case, cbase + CCR_CASE_FLAGS))
                println("")
                mi3 = mi3 + 1
        nod_inputs(ni)   // print outgoing edge records through the kernel helper
        ni = ni + 1

// --dump-match-plan: per IR_MATCH, report the CASE row count, the strategy
// predicate, and how many MATCH nodes actually entered e2_emit_match_binary.
// `binary_emits` is the verification channel: it is incremented inside the real
// emitter, not in the predicate, so a strategy/path mismatch shows up as
// `strategy binary` with `binary_emits 0`.
//
// The read-only guarantee is about artifacts: this runs the real emitter once
// per MATCH into a throwaway buffer and writes no ELF, no .ccr, and no source.
// A label table of -1 forces every case hit through pending backpatching, so no
// absolute target needs to exist yet.
fn dump_match_plan():
    g_match_bin_emits = 0
    g_match_table_emits = 0
    g_match_table_cursor = 0
    g_match_table_ref_count = 0
    g_pending_count = 0
    // Mirror elf_gen's pre-emission global marking so e2_load_var's global/local
    // dispatch reads an initialized table during the scratch pass.
    grow_is_global(g_ir_var_count)
    gi : ., mut = 0
    loop:
        if gi >= g_ir_global_count:
            break
        gv := cell_load(g_ir_globals, gi * 24 + 8)
        if gv >= 0:
            grow_is_global(gv + 1)
            cell_store(g_x86_is_global, gv * 8, 1)
        gi = gi + 1
    max_lbl : ., mut = 0
    ni : ., mut = 0
    loop:
        if ni >= g_v7_nod_count:
            break
        if nod_op(ni) == IR_MATCH:
            ms := nod_s2(ni)
            mc := nod_s3(ni)
            cj : ., mut = 0
            loop:
                if cj >= mc:
                    break
                ct := cell_load_i32(g_ccr_case, (ms + cj) * CCR_V10_CASE_DISK + CCR_CASE_TARGET)
                if ct >= 0 && ct < g_v7_nod_count:
                    if nod_op(ct) == IR_LABEL:
                        ln := nod_s1(ct)
                        if ln + 1 > max_lbl:
                            max_lbl = ln + 1
                cj = cj + 1
        ni = ni + 1
    if max_lbl > 0:
        grow_label_poses(max_lbl)
        lj : ., mut = 0
        loop:
            if lj >= max_lbl:
                break
            cell_store(g_label_poses, lj * 8, -1)
            lj = lj + 1

    ni = 0
    loop:
        if ni >= g_v7_nod_count:
            break
        if nod_op(ni) == IR_MATCH:
            ms := nod_s2(ni)
            mc := nod_s3(ni)
            // Scratch-only real-emitter pass: the returned byte count is not
            // used, only the side effects that the channel reports.
            scratch := alloc(mc * 32 + 256)
            emit_instr(ni, scratch, 0)
            print("match ")
            print_i(ni)
            print(" cases ")
            print_i(mc)
            print(" nondefault ")
            print_i(e2_match_nondefault_count(ms, mc))
            print(" strategy ")
            if e2_match_table_span(ms, mc) > 0:
                print("table")
            else if e2_match_use_binary(ms, mc) != 0:
                print("binary")
            else:
                print("linear")
            println("")
        ni = ni + 1
    print("binary_emits ")
    print_i(g_match_bin_emits)
    println("")
    print("table_emits ")
    print_i(g_match_table_emits)
    println("")
    // Scratch pass records refs but never patches them; drop them.
    g_match_table_ref_count = 0

// --dump-nod-types: print each node's semantic type_id and feature flags. The
// disk has no term-index field in v10, so this channel exposes the actual wire
// semantics. It returns before emission.
fn dump_nod_types():
    with_type : ., mut = 0
    ni : ., mut = 0
    loop:
        if ni >= g_v7_nod_count:
            break
        if nod_type_id(ni) >= 0:
            with_type = with_type + 1
        ni = ni + 1
    print("[nod-types] nodes=")
    print_i(g_v7_nod_count)
    print(" with_type=")
    print_i(with_type)
    print(" flags=")
    fl : ., mut = 0
    ni2 : ., mut = 0
    loop:
        if ni2 >= g_v7_nod_count:
            break
        if nod_type_flags(ni2) != 0:
            fl = fl + 1
        ni2 = ni2 + 1
    print_i(fl)
    print(" rows=")
    print_i(g_type_count)
    println("")
    nj : ., mut = 0
    loop:
        if nj >= g_v7_nod_count:
            break
        print("nodtype ")
        print_i(nj)
        print(" op ")
        print_i(nod_op(nj))
        print(" tid ")
        print_i(nod_type_id(nj))
        print(" flags ")
        print_i(nod_type_flags(nj))
        println("")
        nj = nj + 1

fn corearch_main() -> int:
    cli_init("corearch", "Core architecture backend")
    register_backend_flags()

    if cli_parse() != 0:
        return 1
    // Boot: select the instance from the flags, then query its declaration row at
    // each reject, table, and O2 gate.
    instance_decl_init()
    g_active_instance = instance_select()
    // The table instance rejects --link and --shared. Its pool mov [rip+disp]
    // displacements are filled by elf.cr and have not been tested under the linker's
    // code-section relayout. Reject the combination explicitly.
    if inst_allow_link(g_active_instance) == 0:
        if cli_has("shared") != 0 || cli_has("link") != 0 || str_len(cli_get("link")) > 0:
            em := "error: --table cannot be combined with --link/--shared (pool mov rip disp untested under ctx relayout)\n"
            syscall3(1, 2, em, str_len(em))
            return 1
    g_opt_level = 0
    ol : ., mut = cli_get("opt-level")
    if str_len(ol) > 0:
        g_opt_level = str_int(ol)
        // Clamp the option level to the x86 declaration window 0..3. The table
        // instance's 0..0 window is enforced by its needs_alloc/needs_verify
        // fields; the CLI value still reaches emission.
        if g_opt_level > inst_opt_max(INST_X86):
            g_opt_level = inst_opt_max(INST_X86)
        if g_opt_level < inst_opt_min(INST_X86):
            g_opt_level = inst_opt_min(INST_X86)
    // Load the HIT table when --table is present. Mapped ops go through
    // emit_instr_tabled; unmapped ops use the normal path. A load failure returns
    // immediately.
    tbl : ., mut = cli_get("table")
    if str_len(tbl) > 0:
        if load_hit_table(tbl) != 0:
            return 1
        g_hit_tabled_count = 0
        print("hit table loaded: ")
        print_i(g_hit_event_count)
        println(" events")
        // Hidden channel: dump the loaded table's projections, steps, and runtime
        // state. The helper is read-only.
        if cli_has("dump-table") != 0:
            hit_dump_table_state()
    if cli_arg_count() < 1:
        println("usage: corearch <file.ccr> [options]")
        println("  --elf           ELF binary (default: dynamic)")
        println("  --static        static linking (embed runtime)")
        println("  --shared        shared library (.so)")
        println("  --link auto     link ~/.core/lib/*.so (default)")
        println("  --link s1,s2   link specific .so files")
        println("  -o FILE         output path")
        println("  --table FILE    load HIT table; emit mapped ops through it (M1: int sub)")
        println("  --dump-events   dump lowered HIT event stream + const pool")
        return 1

    src_path := cli_arg(0)
    fd := syscall3(2, src_path, 0, 0)
    if fd < 0:
        print("error: cannot open ")
        println(src_path)
        return 1
    fsize := syscall3(8, fd, 0, 2)
    syscall3(8, fd, 0, 0)
    if fsize < 36:
        syscall3(3, fd, 0, 0)
        println("error: invalid .ccr file size")
        return 1
    buf := alloc(fsize + 1)
    nread := syscall3(0, fd, buf, fsize)
    syscall3(3, fd, 0, 0)
    if nread != fsize:
        println("error: cannot read")
        return 1
    r := load_ccr(buf, fsize)
    if r != 0:
        println("error: invalid .ccr file")
        return 1
    backend_select_int_mode()
    init_backend_arrays()

    // Hidden channel: dump the TYPE segment after load. It uses the same print path
    // as corec's --dump-types. It returns before linear reconstruction.
    if cli_has("dump-types") != 0:
        ccr_type_surface_dump()
        return 0

    // Hidden channel: dump the IFACE segment after load, using the same print path
    // as corec's --dump-ifaces. It returns before linear reconstruction.
    if cli_has("dump-ifaces") != 0:
        ccr_iface_surface_dump()
        return 0

    // Hidden channel: print NOD semantic type ids and feature flags. It runs after
    // the TYPE segment is rebuilt and before build_linear_schedule, so it does not
    // trigger emission.
    if cli_has("dump-nod-types") != 0:
        dump_nod_types()
        return 0

    // Hidden channel: element type and reconstructed stride for each
    // IR_ALLOC_ARRAY node. It returns before linear reconstruction.
    if cli_has("dump-alloc-strides") != 0:
        dump_alloc_strides()
        return 0

    // The loader produces semantic objects only. The instance rebuilds the linear
    // g_ir_instrs stream with build_linear_schedule after a successful load and
    // before dispatch or emission. ELF emission and the allocation dumps all read
    // the linear stream.
    if build_linear_schedule() != 0:
        println("error: invalid .ccr file")
        return 1

    // Hidden channel: dump the object image after linear reconstruction and before
    // emission. It returns without entering the O2 or emission paths.
    if cli_has("dump-objects") != 0:
        dump_object_surface()
        return 0

    // Hidden channel: per-MATCH dispatch strategy. It shares the emitter's
    // predicate and returns before O2 allocation or emission.
    if cli_has("dump-match-plan") != 0:
        dump_match_plan()
        return 0

    // O2 allocation and consistency checks run here, not in corec. The .ccr no
    // longer carries REG_ASSIGN or ENT. A violation is a compile error.
    // The instance declaration controls this: x86 has needs_alloc/needs_verify = 1
    // and runs at level >= 2; the table instance has 0/0 and never runs O2.
    dd := regalloc_debug_dispatch()
    if dd == 1:
        return 0
    if dd == 2:
        return 1
    if g_opt_level >= 2 && inst_needs_alloc(g_active_instance) != 0:
        alloc_registers()
        if inst_needs_verify(g_active_instance) != 0:
            // Success is silent; a violation has already printed diagnostics and is
            // rejected here.
            if regalloc_verify_all() != 0:
                return 1

    // Table mode lowers the straight-line IR subset to an event stream and constant
    // pool, which emit_instr_tabled consumes. An out-of-subset op fails before
    // emission. --hit-events-file replaces lowering with a text event stream for
    // tests and requires --table. allow_table on the active instance is the table
    // pipeline gate.
    dump_ev : ., mut = cli_has("dump-events")
    inj_path : ., mut = cli_get("hit-events-file")
    if str_len(inj_path) > 0 && inst_allow_table(g_active_instance) == 0:
        println("error: --hit-events-file needs --table (events emit through table projections)")
        return 1
    g_hit_inject_active = 0
    if inst_allow_table(g_active_instance) != 0:
        if str_len(inj_path) > 0:
            g_hit_inject_active = 1
            if hit_inject_events(inj_path) != 0:
                return 1
        else:
            if hit_lower_program() != 0:
                return 1
        if dump_ev != 0:
            print("hit events lowered: ")
            print_i(g_hit_ev_count)
            println("")
            ei : ., mut = 0
            loop:
                if ei >= g_hit_ev_count:
                    break
                ev_id := hit_ev_id(ei)
                es := hit_event_lookup(ev_id)
                print("  ev ")
                if es < 0:
                    print("?")
                else:
                    print(hit_event_name(es))
                print(" dst=")
                print_i(hit_ev_dst(ei))
                print(" s1=")
                if hit_ev_flags(ei) % 2 == 1:
                    print("pool")
                    print_i(hit_ev_s1(ei))
                else:
                    print_i(hit_ev_s1(ei))
                print(" s2=")
                if hit_ev_flags(ei) / 2 % 2 == 1:
                    print("pool")
                    print_i(hit_ev_s2(ei))
                else:
                    print_i(hit_ev_s2(ei))
                println("")
                ei = ei + 1
            // Pool values in slot order.
            print("hit pool entries: ")
            print_i(g_hit_pool_count)
            println("")
            if g_hit_pool_count > 0:
                print("hit pool:")
                hpi : ., mut = 0
                loop:
                    if hpi >= g_hit_pool_count:
                        break
                    print(" ")
                    print_i(cell_load(g_hit_pool, hpi * 8))
                    hpi = hpi + 1
                println("")

    emit_so := cli_has("shared")
    link_val := cli_get("link")
    out_path := cli_get("output")

    // Pure-static (no --link, not --shared): the binary must be self-contained,
    // so the backend emits g_set_curg/g_get_curg bridge stubs (rt.s is not linked).
    // With --link, the stubs stay external and resolve from core_rt.so (rt.s).
    g_x86_emit_rt_stubs = 0
    if str_len(link_val) == 0 && emit_so == 0:
        g_x86_emit_rt_stubs = 1

    // --shared: emit as ET_DYN
    if emit_so != 0:
        if str_len(out_path) == 0:
            out_path = "core_lib.so"
        g_elf_buf = alloc(16777216)
        sz := elf_gen(g_elf_buf)
        w16(g_elf_buf, 16, 3)
        fd := syscall3(2, out_path, 577, 493)
        if fd < 0:
            print("error: cannot write ")
            println(out_path)
            return 1
        syscall3(1, fd, g_elf_buf, sz)
        syscall3(3, fd, 0, 0)
        print(" -> ")
        println(out_path)
        return 0

    // Default: ELF (static or dynamic)
    if str_len(out_path) == 0:
        out_path = "a.out"
    g_elf_buf = alloc(16777216)

    is_static := cli_has("static")

    if str_len(link_val) > 0:
        ctx_init()
        if str_eq(link_val, "auto") != 0:
            // Look for core_rt.so relative to compiler binary
            sp := get_arg(0)
            sllen := str_len(sp)
            last_sl : ., mut = -1
            sli : ., mut = 0
            loop:
                if sli >= sllen:
                    break
                if load8(sp, sli) == 47:
                    last_sl = sli
                sli = sli + 1
            if last_sl >= 0:
                libp := str_sub(sp, 0, last_sl + 1) + "core_rt.so"
                if str_len(read_file(libp)) > 0:
                    ctx_add_so(libp)
            // Also try ./build/, ./, and ~/.core/lib/
            if str_len(read_file("./build/core_rt.so")) > 0:
                ctx_add_so("./build/core_rt.so")
            else if str_len(read_file("./core_rt.so")) > 0:
                ctx_add_so("./core_rt.so")
            if str_len(read_file("~/.core/lib/core_rt.so")) > 0:
                ctx_add_so("~/.core/lib/core_rt.so")
        else:
            split_links(link_val)
        sz := elf_gen(g_elf_buf)
        cs : ., mut = sz - 176
        if cs <= 0:
            println("error: empty code")
            return 1
        cd := alloc(cs)
        ci : ., mut = 0
        loop:
            if ci >= cs:
                break
            store8(cd, ci, load8(g_elf_buf, 176+ci))
            ci = ci + 1
        // Clear rip-relative patches in user code (they point to original BSS)
        // NOP the mov [r10],rXX that follows each lea r10,[rip+...]
        rpi : ., mut = 0
        loop:
            if rpi >= g_x86_rip_patch_count:
                break
            ppos := cell_load(g_x86_rip_patch_pos, rpi * 8)
            if ppos >= 176 && ppos - 176 + 4 <= cs:
                w32(cd, ppos - 176, 0)
                w8(cd, ppos + 4 - 176, 144)
                w8(cd, ppos + 5 - 176, 144)
                w8(cd, ppos + 6 - 176, 144)
            rpi = rpi + 1


        if is_static != 0:
            if g_so_count > 0:
                ctx_set_user_code(cd, cs)
                sz = ctx_emit_static(g_elf_buf, out_path)
                if sz == -2:
                    println("error: 静态链接失败——存在无法解析的外部符号（见上方列表）")
                    return 1
            else:
                // A pure static build has no .so to resolve extern symbols. Report
                // them instead of leaving call rel32=0, which would crash at run time.
                if g_x86_ext_rel_count > 0:
                    println("error: 无法解析外部符号（静态构建未链接任何运行库）：")
                    ri2 : ., mut = 0
                    loop:
                        if ri2 >= g_x86_ext_rel_count:
                            break
                        println("  " + istr_get(cell_load(g_x86_ext_rel_name, ri2 * 8)))
                        ri2 = ri2 + 1
                    return 1
                // Pure static: write directly; the frontend prepends rt.cr. ELF output
                // is executable (0755); .so output stays 0644.
                fd := syscall3(2, out_path, 577, 493)
                if fd < 0:
                    print("error: cannot write ")
                    println(out_path)
                    return 1
                syscall3(1, fd, g_elf_buf, sz)
                syscall3(3, fd, 0, 0)
        else:
            // Dynamic linking: PLT/GOT
            ri : ., mut = 0
            loop:
                if ri >= g_x86_ext_rel_count:
                    break
                fn_name := istr_get(cell_load(g_x86_ext_rel_name, ri * 8))
                ctx_add_plt(fn_name, 0)
                ri = ri + 1
            ctx_set_user_code(cd, cs)
            sz = ctx_emit_dyn(g_elf_buf, out_path)
        if sz <= 0:
            println("error: linking failed")
            return 1
    else:
        sz := elf_gen(g_elf_buf)
        fd := syscall3(2, out_path, 577, 493)  // 0755：可执行输出（同静态路径修复）        if fd < 0 { print("error: cannot write "); println(out_path); return 1; }
        syscall3(1, fd, g_elf_buf, sz)
        syscall3(3, fd, 0, 0)
    print(" -> ")
    println(out_path)
    // Table summary: g_hit_tabled_count is the number of events actually emitted
    // through table mappings.
    if str_len(tbl) > 0:
        print("hit table: ")
        print_i(g_hit_tabled_count)
        println(" events emitted")
    // Injection channel: every event must be emitted through the table. A shorter
    // count means the injection file contains an event that cannot be emitted, so
    // return an error instead of silently using the fallback path.
    if g_hit_inject_active != 0 && g_hit_tabled_count != g_hit_ev_count:
        print("error: HIT events: ")
        print_i(g_hit_tabled_count)
        print(" of ")
        print_i(g_hit_ev_count)
        println(" events emitted via table (injection file event not emittable)")
        return 1
    return 0
