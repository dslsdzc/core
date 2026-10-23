// === ent_kernel.cr ===
// Architecture-neutral kernel for entry and live-range data, the location
// registry, and register-allocation consistency checks.
//
// The kernel works on entry classes: a live interval, an opaque location, and an
// optional home slot. It does not read values and has no register names, ABI
// constants, or encoding knowledge. The x86 instance in regalloc.cr owns those
// concepts and writes its decisions into the location registry.
//
// Data:
//   grow_live_ranges, live_range_slot, live_first, live_last, compute_live_ranges
//   grow_entries, grow_func_entry_meta, ent_*, entry_start, entry_count,
//   compute_entries
//
// Location registry:
//   kern_loc_assign, kern_loc_clear, kern_loc_of, loc_registry_reset.
//   Stores one opaque location per entry. The instance registers after writing
//   its own metadata and clears when entries are rebuilt.
//
// Checks:
//   entries_coexist, coexist_version_conflicts, coexist_home_conflicts,
//   verify_regalloc_consistency, regalloc_verify_all, and the rl_report_* helpers.
//   Rule 1 is same-location mutual exclusion. Rule 2 is read coverage by an
//   active version. Violation text is neutral.
//
// Debug output:
//   dump_entries_summary, dump_coexist_summary, ir_op_kind_name.
//
// Instance side:
//   regalloc.cr owns CAG allocation, g_opt_meta writes, and the injection hooks.
//   It calls the registry API at the same points where it writes metadata.
//   The instance declaration table in corearch.cr describes capabilities such as
//   eviction and call-site handling; the kernel does not implement those checks.
//
// Live-range layout:
//   One segment per function, two i64 values per function-local var
//   (first_ref and last_ref). Coordinates are function-local node indexes.
//   The segment start is the sum of var_count[0..func_i), with no fixed dense
//   factor. Unused vars have -1 in both values. Records are 16 bytes.

fn grow_live_ranges(needed: int):
    if needed < g_live_range_cap:
        return
    nc := g_live_range_cap * 2
    if nc < 64:
        nc = 64
    if nc < needed:
        nc = needed + 64
    nb := alloc(nc * 16)
    _dyncpy(g_ir_live_ranges, g_live_range_cap * 16, nb)
    g_ir_live_ranges = nb
    g_live_range_cap = nc

fn live_range_slot(func_i: int, var_i: int) -> int:
    // 函数内 var 索引 = var_i − var_start[func_i]；func_i 段起始 = 前缀 var_count 累计
    off : ., mut = 0
    fi : ., mut = 0
    loop:
        if fi >= func_i:
            break
        off = off + cell_load(g_ir_func_var_count, fi * 8)
        fi = fi + 1
    return (off + (var_i - cell_load(g_ir_func_var_start, func_i * 8))) * 16

fn live_first(func_i: int, var_i: int) -> int:
    if func_i < 0 || var_i < 0:
        return -1
    return cell_load(g_ir_live_ranges, live_range_slot(func_i, var_i))

fn live_last(func_i: int, var_i: int) -> int:
    if func_i < 0 || var_i < 0:
        return -1
    return cell_load(g_ir_live_ranges, live_range_slot(func_i, var_i) + 8)

// Build g_ir_live_ranges. Scan each function's nodes through nod_*. If dest, s1,
// or s2 falls in [vs, vs+vc), extend [first_ref, last_ref]: first sight sets
// first_ref, later uses advance last_ref. An unused variable has -1 for both.
fn compute_live_ranges():
    total : ., mut = 0
    fi : ., mut = 0
    loop:
        if fi >= g_ir_func_count:
            break
        total = total + cell_load(g_ir_func_var_count, fi * 8)
        fi = fi + 1
    grow_live_ranges(total)
    g_live_range_count = total
    // Initialize every range to -1 (unknown or unused).
    zi : ., mut = 0
    loop:
        if zi >= total:
            break
        cell_store(g_ir_live_ranges, zi * 16, -1)
        cell_store(g_ir_live_ranges, zi * 16 + 8, -1)
        zi = zi + 1
    // Scan each function's node window. The segment offset is the running prefix,
    // matching live_range_slot. g_ir_func_instr_start/count hold NOD node
    // coordinates, and the window is [start, start+count). All node fields are read
    // through the nod_* object accessors.
    seg : ., mut = 0
    fi = 0
    loop:
        if fi >= g_ir_func_count:
            break
        ic := cell_load(g_ir_func_instr_count, fi * 8)
        ist := cell_load(g_ir_func_instr_start, fi * 8)
        vc := cell_load(g_ir_func_var_count, fi * 8)
        vs := cell_load(g_ir_func_var_start, fi * 8)
        if vc > 0:
            ii : ., mut = 0
            loop:
                if ii >= ic:
                    break
                inst := ist + ii
                d := nod_dest(inst)
                s1 := nod_s1(inst)
                s2 := nod_s2(inst)
                if d >= vs && d < vs + vc:
                    lv := d - vs
                    st := (seg + lv) * 16
                    if cell_load(g_ir_live_ranges, st) < 0:
                        cell_store(g_ir_live_ranges, st, ii)
                    cell_store(g_ir_live_ranges, st + 8, ii)
                if s1 >= vs && s1 < vs + vc:
                    lv := s1 - vs
                    st := (seg + lv) * 16
                    if cell_load(g_ir_live_ranges, st) < 0:
                        cell_store(g_ir_live_ranges, st, ii)
                    cell_store(g_ir_live_ranges, st + 8, ii)
                if s2 >= vs && s2 < vs + vc:
                    lv := s2 - vs
                    st := (seg + lv) * 16
                    if cell_load(g_ir_live_ranges, st) < 0:
                        cell_store(g_ir_live_ranges, st, ii)
                    cell_store(g_ir_live_ranges, st + 8, ii)
                ii = ii + 1
        seg = seg + vc
        fi = fi + 1
    // Build version entries for every function in ascending order.
    // compute_entries with func_i == 0 resets the table, so this is idempotent.
    // It runs for --dump-entries and for O2 allocation, independent of the
    // optimization gate.
    ef : ., mut = 0
    loop:
        if ef >= g_ir_func_count:
            break
        compute_entries(ef)
        ef = ef + 1

// ------------------------------------------------------------------
// Entry versioning: split each variable at its definition points
// ------------------------------------------------------------------
// Core IR is not SSA; a variable can be defined many times. A definition is:
//   - IR_ALLOC, IR_ALLOC_ARRAY, IR_ALLOC_STRUCT, or any producer with dest >= 0;
//   - IR_STORE, where the target is s1 and dest is -1.
// These instructions have dest >= 0 but do not define the destination variable:
//   IR_STORE_INDEX_VAR: dest is the stored value source;
//   IR_STORE_PTR: dest carries a runtime base annotation;
//   IR_DYN_DISPATCH: dest is a placeholder, and dispatch does not write the slot.
// Each definition starts a new version.
// A version range is [def_j, min(def_{j+1}-1, last_ref)] in global instruction
// coordinates. The last version ends at last_ref. A variable with references but
// no definition gets one entry with def_instr = -1 and range
// [first_ref, last_ref]. A variable never referenced is skipped.
// Version numbers are not stored: entries for one variable are ordered by
// def_instr, and the version is the 1-based position in the group.
// compute_live_ranges must run first. Functions are processed in ascending order;
// func_i == 0 resets the table, and repeated calls are idempotent.

fn grow_entries(needed: int):
    if needed < g_entry_cap:
        return
    nc : ., mut = g_entry_cap * 2
    if nc < 64:
        nc = 64
    if nc < needed:
        nc = needed + 64
    nb := alloc(nc * ESZ_ENTRY)
    _dyncpy(g_ir_entries, g_entry_cap * ESZ_ENTRY, nb)
    g_ir_entries = nb
    g_entry_cap = nc

fn grow_func_entry_meta(needed: int):
    if needed < g_ir_func_entry_cap:
        return
    nc : ., mut = g_ir_func_entry_cap * 2
    if nc < 64:
        nc = 64
    if nc < needed:
        nc = needed + 64
    sz := nc * 8
    n1 := alloc(sz)
    _dyncpy(g_ir_func_entry_start, g_ir_func_entry_cap * 8, n1)
    g_ir_func_entry_start = n1
    n2 := alloc(sz)
    _dyncpy(g_ir_func_entry_count, g_ir_func_entry_cap * 8, n2)
    g_ir_func_entry_count = n2
    g_ir_func_entry_cap = nc

// Entry accessors. Each record is 24 bytes with 4-byte little-endian fields.
// Reads use buf_read_i32, which sign-extends. Do not use r32: the bootstrap
// StackAsmGen inlines r32 as an unsigned 32-bit load, so -1 would read as
// 4294967295. Writes use w32, which stores the low 32 bits and preserves two's
// complement.
fn ent_off(e: int) -> int:
    return e * ESZ_ENTRY
fn ent_var(e: int) -> int:
    return buf_read_i32(g_ir_entries, ent_off(e) + OFF_ENTRY_VAR)
fn ent_def(e: int) -> int:
    return buf_read_i32(g_ir_entries, ent_off(e) + OFF_ENTRY_DEF)
fn ent_live_start(e: int) -> int:
    return buf_read_i32(g_ir_entries, ent_off(e) + OFF_ENTRY_LS)
fn ent_live_end(e: int) -> int:
    return buf_read_i32(g_ir_entries, ent_off(e) + OFF_ENTRY_LE)
fn ent_runtime_home(e: int) -> int:
    return buf_read_i32(g_ir_entries, ent_off(e) + OFF_ENTRY_RUNTIME_HOME)
fn ent_flags(e: int) -> int:
    return buf_read_i32(g_ir_entries, ent_off(e) + OFF_ENTRY_FLAGS)

// 函数条目段界（全局条目下标；compute_entries 已跑过才有效）
fn entry_start(func_i: int) -> int:
    if func_i < 0 || func_i >= g_ir_func_count:
        return 0
    return cell_load(g_ir_func_entry_start, func_i * 8)

fn entry_count(func_i: int) -> int:
    if func_i < 0 || func_i >= g_ir_func_count:
        return 0
    return cell_load(g_ir_func_entry_count, func_i * 8)

fn compute_entries(func_i: int) -> int:
    if func_i == 0:
        g_entry_count = 0
        // A full table rebuild invalidates all location registrations. Entry slots
        // are reused by the new generation, so stale locations must be cleared.
        // The instance registers only after this generation is built.
        loc_registry_reset()
    // The function window uses the same g_ir_func_instr_start/count values as
    // compute_live_ranges: NOD node coordinates, read through nod_*.
    ic := cell_load(g_ir_func_instr_count, func_i * 8)
    ist := cell_load(g_ir_func_instr_start, func_i * 8)
    vc := cell_load(g_ir_func_var_count, func_i * 8)
    vs := cell_load(g_ir_func_var_start, func_i * 8)
    cnt : ., mut = 0
    if ic > 0 && vc > 0:
        // One open-entry slot per function-local variable, initialized to -1.
        // This makes definition splitting O(1) per definition.
        prev : string, mut = alloc(vc * 8)
        pz : ., mut = 0
        loop:
            if pz >= vc:
                break
            cell_store(prev, pz * 8, -1)
            pz = pz + 1
        // Single scan for definitions: IR_STORE uses s1 as the target; every other
        // definition uses dest >= 0. STORE_INDEX_VAR, STORE_PTR, and DYN_DISPATCH
        // are excluded because their dest is not a variable definition.
        ii : ., mut = 0
        loop:
            if ii >= ic:
                break
            inst := ist + ii
            op := nod_op(inst)
            dv : ., mut = -1
            if op == IR_STORE:
                s1 := nod_s1(inst)
                if s1 >= vs && s1 < vs + vc:
                    dv = s1
            else if op != IR_STORE_INDEX_VAR && op != IR_STORE_PTR && op != IR_DYN_DISPATCH:
                d := nod_dest(inst)
                if d >= vs && d < vs + vc:
                    dv = d
            if dv >= 0:
                lv := dv - vs
                last_global : ., mut = -1
                ll := live_last(func_i, dv)
                if ll >= 0:
                    last_global = ist + ll
                // Close the previous version at min(def-1, last_ref).
                pe := cell_load(prev, lv * 8)
                if pe >= 0:
                    pend : ., mut = inst - 1
                    if last_global >= 0 && last_global < pend:
                        pend = last_global
                    w32(g_ir_entries, pe * ESZ_ENTRY + OFF_ENTRY_LE, pend)
                // Open a new version. The initial range is [def, last_ref].
                grow_entries(g_entry_count + 1)
                eo := g_entry_count * ESZ_ENTRY
                w32(g_ir_entries, eo + OFF_ENTRY_VAR, dv)
                w32(g_ir_entries, eo + OFF_ENTRY_DEF, inst)
                w32(g_ir_entries, eo + OFF_ENTRY_LS, inst)
                w32(g_ir_entries, eo + OFF_ENTRY_LE, last_global)
                w32(g_ir_entries, eo + OFF_ENTRY_RUNTIME_HOME, -1)
                w32(g_ir_entries, eo + OFF_ENTRY_FLAGS, 0)
                cell_store(prev, lv * 8, g_entry_count)
                g_entry_count = g_entry_count + 1
                cnt = cnt + 1
            ii = ii + 1
        // Variables with references but no definition get one entry with def = -1.
        lv2 : ., mut = 0
        loop:
            if lv2 >= vc:
                break
            if cell_load(prev, lv2 * 8) < 0:
                gv := vs + lv2
                ff := live_first(func_i, gv)
                ll := live_last(func_i, gv)
                if ff >= 0 && ll >= 0:
                    grow_entries(g_entry_count + 1)
                    eo := g_entry_count * ESZ_ENTRY
                    w32(g_ir_entries, eo + OFF_ENTRY_VAR, gv)
                    w32(g_ir_entries, eo + OFF_ENTRY_DEF, -1)
                    w32(g_ir_entries, eo + OFF_ENTRY_LS, ist + ff)
                    w32(g_ir_entries, eo + OFF_ENTRY_LE, ist + ll)
                    w32(g_ir_entries, eo + OFF_ENTRY_RUNTIME_HOME, -1)
                    w32(g_ir_entries, eo + OFF_ENTRY_FLAGS, 0)
                    g_entry_count = g_entry_count + 1
                    cnt = cnt + 1
            lv2 = lv2 + 1
    grow_func_entry_meta(func_i + 1)
    cell_store(g_ir_func_entry_start, func_i * 8, g_entry_count - cnt)
    cell_store(g_ir_func_entry_count, func_i * 8, cnt)
    return cnt

// Name of a definition opcode for the --dump-entries kind= field. The list covers
// opcodes that can define a variable: producers with dest >= 0 and IR_STORE(s1).
// An unlisted opcode falls back to its number; seeing one means a new definition
// form exists.
fn ir_op_kind_name(op: int) -> string:
    if op == IR_ALLOC:
        return "ALLOC"
    if op == IR_ALLOC_STRUCT:
        return "ALLOC_STRUCT"
    if op == IR_ALLOC_ARRAY:
        return "ALLOC_ARRAY"
    if op == IR_STORE:
        return "STORE"
    if op == IR_CONST:
        return "CONST"
    if op == IR_LOAD:
        return "LOAD"
    if op == IR_LOAD_FIELD:
        return "LOAD_FIELD"
    if op == IR_LOAD_INDEX:
        return "LOAD_INDEX"
    if op == IR_LOAD_INDEX_VAR:
        return "LOAD_INDEX_VAR"
    if op == IR_BINARY:
        return "BINARY"
    if op == IR_UNARY:
        return "UNARY"
    if op == IR_CALL:
        return "CALL"
    if op == IR_CALL_EXTERN:
        return "CALL_EXTERN"
    if op == IR_HOTPATCH_ROUTE:
        return "HOTPATCH_ROUTE"
    if op == IR_MAKE_ENUM:
        return "MAKE_ENUM"
    if op == IR_REF:
        return "REF"
    if op == IR_DEREF:
        return "DEREF"
    if op == IR_LOAD_ENUM_TAG:
        return "LOAD_ENUM_TAG"
    if op == IR_SLICE:
        return "SLICE"
    if op == IR_ADDR_INDEX:
        return "ADDR_INDEX"
    if op == IR_SPAWN:
        return "SPAWN"
    if op == IR_AWAIT:
        return "AWAIT"
    if op == IR_ARENA_NEW:
        return "ARENA_NEW"
    if op == IR_DYN_PACK:
        return "DYN_PACK"
    if op == IR_DYN_TAG:
        return "DYN_TAG"
    if op == IR_DYN_VAL:
        return "DYN_VAL"
    if op == IR_LAZY_THUNK:
        return "LAZY_THUNK"
    if op == IR_LAZY_FORCE:
        return "LAZY_FORCE"
    if op == IR_FNADDR:
        return "FNADDR"
    if op == IR_I2F:
        return "I2F"
    if op == IR_F2I:
        return "F2I"
    if op == IR_PHI:
        return "PHI"
    return "OP" + int_str(op)

// --dump-entries output. One section per function and one line per entry.
// Coordinates are global instruction order and global variable index. v is the
// 1-based version within the variable group. kind is the definition opcode, or
// "-" when def is -1.
fn dump_entries_summary():
    fi : ., mut = 0
    loop:
        if fi >= g_ir_func_count:
            break
        es := entry_start(fi)
        ec := entry_count(fi)
        print("== entries func ")
        print(int_str(fi))
        print(" (")
        print(istr_get(cell_load(g_ir_func_name_idx, fi * 8)))
        print("): ")
        println(int_str(ec))
        ei : ., mut = 0
        loop:
            if ei >= ec:
                break
            e := es + ei
            gv := ent_var(e)
            ord : ., mut = 1
            ej : ., mut = es
            loop:
                if ej >= e:
                    break
                if ent_var(ej) == gv:
                    ord = ord + 1
                ej = ej + 1
            print(" e ")
            print(int_str(e))
            print(" var ")
            print(int_str(gv))
            vn := get_ir_var_name(gv)
            if str_len(vn) > 0:
                print(" name=")
                print(vn)
            print(" v ")
            print(int_str(ord))
            print(" def ")
            print(int_str(ent_def(e)))
            d := ent_def(e)
            if d >= 0:
                // d is a global node coordinate; read its opcode through nod_op.
                print(" kind=")
                print(ir_op_kind_name(nod_op(d)))
            else:
                print(" kind=-")
            print(" live ")
            print(int_str(ent_live_start(e)))
            print("..")
            print(int_str(ent_live_end(e)))
            print(" home ")
            print(int_str(ent_runtime_home(e)))
            print(" flags ")
            println(int_str(ent_flags(e)))
            ei = ei + 1
        fi = fi + 1

// Coexistence: two entries coexist when their closed live intervals
// [ls, le] intersect in global node coordinates. Coexistence is symmetric and
// not transitive. It is computed on demand and never stored.

// Single-pair query: intervals intersect iff ls1 <= le2 and ls2 <= le1.
// e1 and e2 are global entry indexes. func_i is kept for call compatibility;
// intervals from different functions do not overlap, so no function filter is
// needed.
fn entries_coexist(func_i: int, e1: int, e2: int) -> int:
    // Reject out-of-range entry indexes. Reading past the count could hit zero
    // fill or memory outside the buffer, so return 0.
    if e1 < 0 || e2 < 0 || e1 >= g_entry_count || e2 >= g_entry_count:
        return 0
    if e1 == e2:
        return 0
    s1 := ent_live_start(e1)
    n1 := ent_live_end(e1)
    s2 := ent_live_start(e2)
    n2 := ent_live_end(e2)
    if s1 < 0 || s2 < 0:
        return 0
    if s1 <= n2 && s2 <= n1:
        return 1
    return 0

// Count conflicts between consecutive versions of the same variable. Version j
// ends at version j+1's definition minus 1, which is before j+1's start, so
// adjacent versions must not coexist. Zero means versioning is correct. O(n) per
// variable group.
fn coexist_version_conflicts(func_i: int) -> int:
    es := entry_start(func_i)
    ec := entry_count(func_i)
    conflicts : ., mut = 0
    ei : ., mut = 0
    loop:
        if ei >= ec:
            break
        e := es + ei
        gv := ent_var(e)
        // 找同 var 的下一版本条目（版本按定值序相邻）
        ej : ., mut = ei + 1
        loop:
            if ej >= ec:
                break
            if ent_var(es + ej) == gv:
                if entries_coexist(func_i, e, es + ej) != 0:
                    conflicts = conflicts + 1
                break
            ej = ej + 1
        ei = ei + 1
    return conflicts

// Count conflicts among entries with the same home slot. home = -1 is ignored.
// This is a simple pairwise check; when home assignment is enabled, replace it
// with a per-group sweep instead of reusing this function.
fn coexist_home_conflicts(func_i: int) -> int:
    es := entry_start(func_i)
    ec := entry_count(func_i)
    conflicts : ., mut = 0
    ei : ., mut = 0
    loop:
        if ei >= ec:
            break
        e1 := es + ei
        h1 := ent_runtime_home(e1)
        if h1 >= 0:
            ej : ., mut = ei + 1
            loop:
                if ej >= ec:
                    break
                e2 := es + ej
                if ent_runtime_home(e2) == h1:
                    if entries_coexist(func_i, e1, e2) != 0:
                        conflicts = conflicts + 1
                ej = ej + 1
        ei = ei + 1
    return conflicts

// --dump-coexist output: per function, version conflicts (expected 0) and home
// conflicts (expected 0 while home is unassigned).
fn dump_coexist_summary():
    fi : ., mut = 0
    loop:
        if fi >= g_ir_func_count:
            break
        print("== coexist func ")
        print(int_str(fi))
        print(" (")
        print(istr_get(cell_load(g_ir_func_name_idx, fi * 8)))
        print("):")
        print(" ver_conf ")
        print(int_str(coexist_version_conflicts(fi)))
        print(" home_conf ")
        println(int_str(coexist_home_conflicts(fi)))
        fi = fi + 1
// Consistency checks. The instance writes allocation results to the location
// registry and to its own metadata at the same points. The kernel reads only the
// registry, so it has no layout knowledge of the instance metadata.
// Allocation is variable-level: one location per variable. Entries are
// version-level, so a variable's location is projected onto each of its versions.
// Rule 1: two coexisting entries must not share a location.
// Rule 2: every read of a resident variable must be covered by an active version.
// Eviction and call-site checks are declared in the instance table through
// needs_eviction and needs_call_sites, but this kernel does not implement them.

RPT_MAX : int = 8              // 规则违反诊断每函数每规则打印上限（计数不封顶）

// Location registry: entry to opaque location. The kernel only compares, sorts,
// and checks equality of these values; it has no register names or domain
// encoding. The instance registers and clears entries after writing its own
// metadata. A full entry-table rebuild resets the registry. Each slot is 4 bytes;
// -1 means unregistered.
g_loc_registry_buf : string, mut   // 4 bytes per slot; slot e is entry e location or -1
g_loc_registry_cap : int, mut      // number of slots

fn loc_registry_reset():
    // Called when the entry table is rebuilt. Clear all registered slots to -1.
    // Newly grown slots are initialized by kern_loc_assign.
    zi : ., mut = 0
    loop:
        if zi >= g_loc_registry_cap:
            break
        w32(g_loc_registry_buf, zi * 4, -1)
        zi = zi + 1

fn kern_loc_assign(entry_idx: int, loc: int):
    if entry_idx < 0:
        return
    if entry_idx >= g_loc_registry_cap:
        nc : ., mut = g_loc_registry_cap * 2
        if nc < 64:
            nc = 64
        if nc <= entry_idx:
            nc = entry_idx + 64
        nb := alloc(nc * 4)
        _dyncpy(g_loc_registry_buf, g_loc_registry_cap * 4, nb)
        zi : ., mut = g_loc_registry_cap
        loop:
            if zi >= nc:
                break
            w32(nb, zi * 4, -1)   // -1 means unregistered
            zi = zi + 1
        g_loc_registry_buf = nb
        g_loc_registry_cap = nc
    w32(g_loc_registry_buf, entry_idx * 4, loc)

fn kern_loc_clear(entry_idx: int):
    if entry_idx < 0 || entry_idx >= g_loc_registry_cap:
        return
    w32(g_loc_registry_buf, entry_idx * 4, -1)

fn kern_loc_of(entry_idx: int) -> int:
    if entry_idx < 0 || entry_idx >= g_loc_registry_cap:
        return -1
    return buf_read_i32(g_loc_registry_buf, entry_idx * 4)

// Variable-level residency query. Allocation is one location per variable, so
// every version entry of a variable has the same location. Any registered entry
// means the variable is resident, and its location is that entry's location.
// The query locates the function's variable window first, then scans that entry
// segment instead of the whole table.
fn meta_reg_for_var(var_idx: int) -> int:
    fi : ., mut = 0
    loop:
        if fi >= g_ir_func_count:
            break
        vs := cell_load(g_ir_func_var_start, fi * 8)
        vc := cell_load(g_ir_func_var_count, fi * 8)
        if var_idx >= vs && var_idx < vs + vc:
            es := entry_start(fi)
            ec := entry_count(fi)
            ei : ., mut = 0
            loop:
                if ei >= ec:
                    break
                e := es + ei
                if ent_var(e) == var_idx:
                    loc := kern_loc_of(e)
                    if loc >= 0:
                        return loc
                ei = ei + 1
            return -1   // no registered entry in this window: not resident
        fi = fi + 1
    return -1   // outside every function variable window: not resident

// Compare two 16-byte records for sorting by (loc, live_start).
fn rl_rec_lt(buf: string, a: int, b: int) -> int:
    la := cell_load(buf, a * 16)
    lb := cell_load(buf, b * 16)
    if la != lb:
        if la < lb:
            return 1
        return 0
    ea := cell_load(buf, a * 16 + 8)
    eb := cell_load(buf, b * 16 + 8)
    if ent_live_start(ea) < ent_live_start(eb):
        return 1
    return 0

// Bottom-up merge sort for 16-byte {loc, entry} records. O(k log k), so the
// same-location sweep does not compare every pair.
fn rl_merge_sort(buf: string, n: int):
    if n <= 1:
        return
    tmp := alloc(n * 16)
    width : ., mut = 1
    loop:
        if width >= n:
            break
        left : ., mut = 0
        loop:
            if left >= n:
                break
            mid : ., mut = left + width
            if mid > n:
                mid = n
            right : ., mut = left + width * 2
            if right > n:
                right = n
            i : ., mut = left
            j : ., mut = mid
            k : ., mut = left
            loop:
                if i >= mid || j >= right:
                    break
                if rl_rec_lt(buf, i, j) != 0:
                    cell_store(tmp, k * 16, cell_load(buf, i * 16))
                    cell_store(tmp, k * 16 + 8, cell_load(buf, i * 16 + 8))
                    i = i + 1
                else:
                    cell_store(tmp, k * 16, cell_load(buf, j * 16))
                    cell_store(tmp, k * 16 + 8, cell_load(buf, j * 16 + 8))
                    j = j + 1
                k = k + 1
            loop:
                if i >= mid:
                    break
                cell_store(tmp, k * 16, cell_load(buf, i * 16))
                cell_store(tmp, k * 16 + 8, cell_load(buf, i * 16 + 8))
                i = i + 1
                k = k + 1
            loop:
                if j >= right:
                    break
                cell_store(tmp, k * 16, cell_load(buf, j * 16))
                cell_store(tmp, k * 16 + 8, cell_load(buf, j * 16 + 8))
                j = j + 1
                k = k + 1
            left = right
        zi : ., mut = 0
        loop:
            if zi >= n:
                break
            cell_store(buf, zi * 16, cell_load(tmp, zi * 16))
            cell_store(buf, zi * 16 + 8, cell_load(tmp, zi * 16 + 8))
            zi = zi + 1
        width = width * 2

// Print an opaque location. The kernel does not classify values as registers or
// home slots; that belongs to the instance. Rule 1 has two passes, the registry
// pass and the home-field pass, but they print the same report format.
fn rl_print_loc(loc: int):
    print("loc ")
    print(int_str(loc))

fn rl_func_name(fi: int):
    print("func ")
    print(int_str(fi))
    print(" (")
    print(istr_get(cell_load(g_ir_func_name_idx, fi * 8)))
    print(")")

// Rule 1 violation report. Printing is capped by RPT_MAX; the count is not
// capped. The prefix "entry-consistency" names the checked property, not the x86
// allocator.
fn rl_report_rule1(func_i: int, loc: int, e1: int, e2: int):
    print("entry-consistency: ")
    rl_func_name(func_i)
    print(": rule 1 violation: entries ")
    print(int_str(e1))
    print(" (var ")
    print(int_str(ent_var(e1)))
    print(") and ")
    print(int_str(e2))
    print(" (var ")
    print(int_str(ent_var(e2)))
    print(") both at ")
    rl_print_loc(loc)
    print(", coexist [")
    print(int_str(ent_live_start(e1)))
    print("..")
    print(int_str(ent_live_end(e1)))
    print("] x [")
    print(int_str(ent_live_start(e2)))
    print("..")
    print(int_str(ent_live_end(e2)))
    println("]")

// Rule 1 same-location sweep. Sort {loc, entry} records by (loc, live_start),
// then scan each equal-loc run while tracking the maximum live_end. If max_end
// reaches the next start, the intervals intersect and rule 1 is violated.
// cap_base is the number already printed in the other pass, so RPT_MAX applies
// across both passes.
fn rl_rule1_sweep(func_i: int, rec: string, cnt: int, cap_base: int) -> int:
    viol : ., mut = 0
    rl_merge_sort(rec, cnt)
    run_start : ., mut = 0
    loop:
        if run_start >= cnt:
            break
        run_end : ., mut = run_start + 1
        loop:
            if run_end >= cnt:
                break
            if cell_load(rec, run_end * 16) != cell_load(rec, run_start * 16):
                break
            run_end = run_end + 1
        maxj : ., mut = -1
        zi : ., mut = run_start
        loop:
            if zi >= run_end:
                break
            e := cell_load(rec, zi * 16 + 8)
            if maxj >= 0:
                mej := cell_load(rec, maxj * 16 + 8)
                if ent_live_end(mej) >= ent_live_start(e):
                    if cap_base + viol < RPT_MAX:
                        rl_report_rule1(func_i, cell_load(rec, zi * 16), mej, e)
                    viol = viol + 1
            if maxj < 0 || ent_live_end(e) > ent_live_end(cell_load(rec, maxj * 16 + 8)):
                maxj = zi
            zi = zi + 1
        run_start = run_end
    return viol

// Rule 2 violation report: a read is not covered by any active version entry.
fn rl_report_rule2(func_i: int, gv: int, inst: int):
    print("entry-consistency: ")
    rl_func_name(func_i)
    print(": rule 2 violation: read of var ")
    print(int_str(gv))
    vn := get_ir_var_name(gv)
    if str_len(vn) > 0:
        print(" name=")
        print(vn)
    print(" at instr ")
    print(int_str(inst))
    println(" not covered by any active version entry")

// Rule 2: every read of a resident variable must be covered by an active version.
// Reads are source operands in s1 or s2. IR_STORE s1 is a write target, so it is
// excluded. The dest column is not scanned: a defining instruction writes a new
// value and does not read the old one. The three exceptional opcodes with dest >= 0
// but no definition have their reads covered by last_ref.
// The coverage obligation starts at the first versioned definition. Version ranges
// run from the definition to last_ref, so every read in the obligation window has
// a version by construction.
fn rl_rule2_func(func_i: int, vs: int, vc: int, nst: int, nc: int, es: int, ec: int) -> int:
    // vs/vc is the variable window [vs, vs+vc). nst/nc is the node window
    // [nst, nst+nc), taken from g_ir_func_instr_start/count.
    violations : ., mut = 0
    lv : ., mut = 0
    loop:
        if lv >= vc:
            break
        gv := vs + lv
        if meta_reg_for_var(gv) < 0:
            lv = lv + 1
            continue
        // Collect this variable's version entries with def >= 0. Count first, then collect.
        m : ., mut = 0
        ei : ., mut = 0
        loop:
            if ei >= ec:
                break
            e := es + ei
            if ent_var(e) == gv && ent_def(e) >= 0:
                m = m + 1
            ei = ei + 1
        if m <= 0:
            lv = lv + 1
            continue
        // No versioned definition: the obligation range is empty.
        vers : string, mut = alloc(m * 8)
        vj : ., mut = 0
        ei = 0
        loop:
            if ei >= ec:
                break
            e := es + ei
            if ent_var(e) == gv && ent_def(e) >= 0:
                cell_store(vers, vj * 8, e)
                vj = vj + 1
            ei = ei + 1
        // Scan reads in ascending node order through nod_op/nod_s1/nod_s2. The
        // version cursor advances monotonically. ent_def and ent_live_end store
        // global node coordinates, so comparisons must use inst, not the local ii.
        cursor : ., mut = 0
        first_def := cell_load(vers, 0 * 8)
        ii : ., mut = 0
        loop:
            if ii >= nc:
                break
            inst := nst + ii
            op := nod_op(inst)
            rd : ., mut = 0
            s1 := nod_s1(inst)
            s2 := nod_s2(inst)
            if s1 == gv && op != IR_STORE:
                rd = 1
            if s2 == gv:
                rd = 1
            if rd != 0 && inst >= ent_def(first_def):
                // 推进游标至最后一个 def ≤ inst 的版本
                loop:
                    if cursor + 1 >= m:
                        break
                    nx := cell_load(vers, (cursor + 1) * 8)
                    if ent_def(nx) > inst:
                        break
                    cursor = cursor + 1
                cv := cell_load(vers, cursor * 8)
                if ent_live_end(cv) < inst:
                    if violations < RPT_MAX:
                        rl_report_rule2(func_i, gv, inst)
                    violations = violations + 1
            ii = ii + 1
        lv = lv + 1
    return violations

// Check one function: 0 = consistent, 1 = violation. It consumes the entry table
// and the location registry. alloc_registers must have run first, and registry
// writes must be paired with metadata writes.
fn verify_regalloc_consistency(func_i: int) -> int:
    if func_i < 0 || func_i >= g_ir_func_count:
        return 0
    es := entry_start(func_i)
    ec := entry_count(func_i)
    if ec <= 0:
        return 0
    // The node window comes from g_ir_func_instr_start/count and is passed to
    // rl_rule2_func as nst/nc. Node fields are read through nod_*.
    ic := cell_load(g_ir_func_instr_count, func_i * 8)
    ist := cell_load(g_ir_func_instr_start, func_i * 8)
    vc := cell_load(g_ir_func_var_count, func_i * 8)
    vs := cell_load(g_ir_func_var_start, func_i * 8)

    // Rule 1 has two passes:
    //   1. Registry pass: entries with kern_loc_of(e) >= 0 grouped by location.
    //   2. Runtime-home pass: entries with ent_runtime_home >= 0 grouped by the
    //      instance-side slot value, skipping -1.
    // The registry pass runs first. Entries already registered are excluded from
    // the runtime-home pass; an entry with both is not produced by the current
    // paths.
    reg_cnt : ., mut = 0
    home_cnt : ., mut = 0
    ei : ., mut = 0
    loop:
        if ei >= ec:
            break
        e := es + ei
        if ent_live_start(e) >= 0 && ent_live_end(e) >= 0:
            if kern_loc_of(e) >= 0:
                reg_cnt = reg_cnt + 1
            else if ent_runtime_home(e) >= 0:
                home_cnt = home_cnt + 1
        ei = ei + 1
    rule1_viol : ., mut = 0
    // Registry pass.
    if reg_cnt > 1:
        rec : string, mut = alloc(reg_cnt * 16)
        ci : ., mut = 0
        ei = 0
        loop:
            if ei >= ec:
                break
            e := es + ei
            if ent_live_start(e) >= 0 && ent_live_end(e) >= 0:
                loc := kern_loc_of(e)
                if loc >= 0:
                    cell_store(rec, ci * 16, loc)
                    cell_store(rec, ci * 16 + 8, e)
                    ci = ci + 1
            ei = ei + 1
        rule1_viol = rl_rule1_sweep(func_i, rec, reg_cnt, 0)
    // Runtime-home pass. cap_base carries the number already printed so RPT_MAX
    // applies across both passes.
    if home_cnt > 1:
        rec : string, mut = alloc(home_cnt * 16)
        ci : ., mut = 0
        ei = 0
        loop:
            if ei >= ec:
                break
            e := es + ei
            if ent_live_start(e) >= 0 && ent_live_end(e) >= 0:
                h := ent_runtime_home(e)
                if h >= 0:
                    cell_store(rec, ci * 16, h)
                    cell_store(rec, ci * 16 + 8, e)
                    ci = ci + 1
            ei = ei + 1
        rule1_viol = rule1_viol + rl_rule1_sweep(func_i, rec, home_cnt, rule1_viol)

    // Rule 2: active-version coverage for resident variables.
    rule2_viol : ., mut = 0
    if vc > 0 && ic > 0:
        rule2_viol = rl_rule2_func(func_i, vs, vc, ist, ic, es, ec)

    if rule1_viol > 0 || rule2_viol > 0:
        return 1
    return 0

// Check all functions: 0 = all consistent, otherwise the number of violating
// functions. Diagnostics are printed for violations; success is silent.
// The instance can also query entries_coexist, coexist_version_conflicts, and
// coexist_home_conflicts for evidence. The kernel does not write instance
// structures.
fn regalloc_verify_all() -> int:
    bad : ., mut = 0
    fi : ., mut = 0
    loop:
        if fi >= g_ir_func_count:
            break
        bad = bad + verify_regalloc_consistency(fi)
        fi = fi + 1
    return bad

// ==================================================================
// Semantic object model: object accessors and the in-memory NOD image.
// The kernel holds the object form of the v7 carrier so accessors can read
// kernel buffers instead of rescanning a file.
//   Nodes: g_v7_nod_sem holds 32-byte semantic records with the same field
//          offsets as the on-disk record, minus adjacency. g_v7_nod_meta holds
//          16-byte {first_edge, edge_count} records.
//   Edges: g_v7_edges and g_v7_edge_count hold 8-byte {to_nod, kind} records in
//          node order. The buffer is declared in ccr_io.cr.
//   Entries: the ent_* family in this file. Regions are traversed through REG
//            rows; there is no region_of_nod object.
// load_ccr in ccr_io.cr loads and validates the object image. Linear NOD to
// g_ir_instrs reconstruction belongs to the instance in regalloc.cr.
// This file has no linear-stream accessor references. Node fields are read
// through nod_*; the loader or populate_nod_objects fills the buffers. Accessors
// use buf_read_* so signed values keep their sign; callers guarantee in-range
// indexes.
ESZ_NOD_SEM : int = 32    // 32-byte semantic record, with the on-disk adjacency fields removed
ESZ_NOD_META : int = 16   // 16-byte adjacency record {first_edge, edge_count}
OFF_NS_OP : int = 0       // semantic field offsets mirror the on-disk record
OFF_NS_DEST : int = 4
OFF_NS_S1 : int = 8
OFF_NS_S2 : int = 16
OFF_NS_S3 : int = 20
// v10 NOD semantic fields. type_id is a TYPE row (-1 = none); flags is the
// semantic feature word (CCR_NOD_FLAG_*). Neither carries a width, byte extent,
// stride, or alignment. There is no disk `item` field in v10.
OFF_NS_TYPE_ID : int = 24
OFF_NS_FLAGS : int = 28

g_v7_nod_sem : string, mut   // NOD semantic records, ESZ_NOD_SEM per node, filled by the loader
g_v7_nod_meta : string, mut  // NOD adjacency records, ESZ_NOD_META per node
g_v7_nod_count : int, mut    // number of NOD records, valid after load

// Node accessors. n is a NOD node coordinate in [0, g_v7_nod_count). Semantic
// fields come from g_v7_nod_sem and adjacency from g_v7_nod_meta. Unsigned fields
// use buf_read_u32, signed fields use buf_read_i32, and s1 uses buf_read_i64.
fn nod_op(n: int) -> int:
    return buf_read_u32(g_v7_nod_sem, n * ESZ_NOD_SEM + OFF_NS_OP)
fn nod_dest(n: int) -> int:
    return buf_read_i32(g_v7_nod_sem, n * ESZ_NOD_SEM + OFF_NS_DEST)
fn nod_s1(n: int) -> int:
    return buf_read_i64(g_v7_nod_sem, n * ESZ_NOD_SEM + OFF_NS_S1)
fn nod_s2(n: int) -> int:
    return buf_read_i32(g_v7_nod_sem, n * ESZ_NOD_SEM + OFF_NS_S2)
fn nod_s3(n: int) -> int:
    return buf_read_i32(g_v7_nod_sem, n * ESZ_NOD_SEM + OFF_NS_S3)
// Semantic type-id accessor (v10 NOD `type_id`). >= 0 is a TYPE row; -1 means
// none. It reads i32 so -1 stays -1.
fn nod_type_id(n: int) -> int:
    return buf_read_i32(g_v7_nod_sem, n * ESZ_NOD_SEM + OFF_NS_TYPE_ID)
// Semantic node feature flags (v10 NOD `flags`). Read as unsigned: the word is a
// bitset of CCR_NOD_FLAG_* features, never a width or byte offset.
fn nod_type_flags(n: int) -> int:
    return buf_read_u32(g_v7_nod_sem, n * ESZ_NOD_SEM + OFF_NS_FLAGS)
// Legacy derived-code view for diagnostics and for emit consumers that still
// read a single code word. Bounds/spawn features come from flags. Target facts
// (IR_DEREF/IR_STORE_PTR access width) are reconstructed by the instance, not
// here, so this returns type_id (-1 when the node has no semantic type).
fn nod_tk(n: int) -> int:
    op := nod_op(n)
    fl := nod_type_flags(n)
    if op == IR_BOUNDS_CHECK:
        if fl % 2 == 1:
            return 1
        return 0
    if op == IR_SPAWN:
        if (fl / 2) % 2 == 1:
            return -1
        return 0
    return nod_type_id(n)
fn nod_edge_first(n: int) -> int:
    return cell_load(g_v7_nod_meta, n * ESZ_NOD_META)
fn nod_edge_count(n: int) -> int:
    return cell_load(g_v7_nod_meta, n * ESZ_NOD_META + 8)

// Edge accessors. e is a global edge index in [0, g_v7_edge_count). Each 8-byte
// record packs to_nod in the low 32 bits and kind in the high 32 bits.
fn v7_edge_to(e: int) -> int:
    return buf_read_u32(g_v7_edges, e * 8)
fn v7_edge_kind(e: int) -> int:
    return buf_read_u32(g_v7_edges, e * 8 + 4)

// Query the inputs of node n by walking its outgoing edges. The adjacency
// interval is [nod_edge_first(n), nod_edge_first(n) + nod_edge_count(n)); edges
// are contiguous per node and first_edge is the prefix sum. A node with no
// outgoing edges has an empty interval. This function prints each edge for the
// object-surface dump; future consumers can read the same accessors directly.
fn nod_inputs(n: int):
    last : ., mut = nod_edge_first(n) + nod_edge_count(n)
    ej : ., mut = nod_edge_first(n)
    loop:
        if ej >= last:
            break
        print("edge ")
        print(int_str(n))
        print(" to ")
        print(int_str(v7_edge_to(ej)))
        print(" kind ")
        println(int_str(v7_edge_kind(ej)))
        ej = ej + 1
