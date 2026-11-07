// === targets/x86_64/linux/elf/frontend_target.cr ===
// Frontend-visible target description for the x86_64 / Linux / ELF instance.
//
// The three axes are explicit. The frontend asks this file for import roots,
// the backend command, and runtime source locations; it does not embed target
// directory names or backend flags itself. The layout-introspection functions
// below answer @sizeOf/@alignOf/@field; they are the only place where source
// code reaches a target layout value, and they never feed an IR width, stride,
// or byte extent.

fn target_name() -> string:
    return "x86_64/linux/elf"

fn target_arch_name() -> string:
    return "x86_64"

fn target_system_name() -> string:
    return "linux"

fn target_container_name() -> string:
    return "elf"

fn target_import_root_count() -> int:
    return 11

// Return a search root with its trailing slash. The source directory is
// handled separately by module.cr because it is project-relative.
fn target_import_root(i: int) -> string:
    if i == 0:
        return "src/stdlib/"
    if i == 1:
        return "src/runtime/"
    if i == 2:
        return "src/kernel/"
    if i == 3:
        return "src/format/elf/"
    if i == 4:
        return "src/arch/x86_64/"
    if i == 5:
        return "src/os/linux/"
    if i == 6:
        return "src/os/linux/runtime/"
    if i == 7:
        return "src/compiler/"
    if i == 8:
        return "src/arch/hit/"
    if i == 9:
        return "src/lattice/"
    if i == 10:
        return "src/targets/x86_64/linux/elf/"
    return ""

fn target_so_index_path(home_dir: string, fs_path: string) -> string:
    return home_dir + "/.core/lib/" + fs_path + "/index"

fn target_static_runtime_source() -> string:
    return "src/runtime/rt.cr"

// -- Compile-time target introspection -------------------------------------
// @sizeOf / @alignOf / @field are source-level layout queries: the program asks
// the target for a value, and the frontend emits that value as a program
// constant. They are not frontend layout decisions — no IR opcode, access
// width, element stride, or allocation extent depends on them — so the answer
// lives with the target descriptor, not in the semantic frontend.
fn target_introspect_size(ti: int) -> int:
    sz := layout_type_size(ti, 0)
    if sz < 0:
        return 0
    return sz

fn target_introspect_align(ti: int) -> int:
    return layout_type_align(ti, 0)

fn target_introspect_field_offset(ti: int, field_index: int) -> int:
    return layout_field_offset(ti, field_index)

fn target_introspect_tuple_field_offset(ti: int, field_index: int) -> int:
    return layout_tuple_field_offset(ti, field_index)

fn target_introspect_field_width(ti: int, field_index: int) -> int:
    si := layout_struct_of(ti)
    if si < 0:
        return 0
    return layout_field_width(ti, si, field_index)

fn target_introspect_tuple_field_width(ti: int, field_index: int) -> int:
    if ti < 0 || ti >= g_type_count:
        return 0
    if get_type_kind(ti) != TYP_TUPLE:
        return 0
    cnt := get_type_data(ti)
    start := get_type_extra(ti)
    if field_index < 0 || field_index >= cnt:
        return 0
    et := cell_load(g_gen_apply_data, (start + field_index) * 8)
    sz := layout_type_size(et, 0)
    if sz <= 0:
        return 0
    k := get_type_kind(et)
    if k == TYP_NAMED || k == TYP_GENERIC_APPLY || k == TYP_TUPLE || k == TYP_SLICE || k == TYP_ARRAY || k == TYP_OPTIONAL || k == TYP_DYN:
        return X86_MP_WORD_BYTES
    if sz > X86_MP_WORD_BYTES:
        return X86_MP_WORD_BYTES
    return sz

fn target_introspect_storage_size(ti: int) -> int:
    return layout_storage_size(ti)

fn target_introspect_struct_alloc_size(ti: int) -> int:
    return layout_struct_alloc_size(ti)

fn target_introspect_tuple_alloc_size(ti: int) -> int:
    return layout_tuple_storage_size(ti)

// Build the backend command for this target. The caller prefixes the sibling
// corearch directory; the target owns the backend name and ABI flags.
fn target_backend_command(ccr_path: string, out_path: string, is_static: int, opt_level: int) -> string:
    cmd : ., mut = "corearch " + ccr_path + " --elf"
    if opt_level > 0:
        cmd = cmd + " --opt-level " + int_str(opt_level)
    if is_static != 0:
        cmd = cmd + " --static"
    else:
        cmd = cmd + " --link auto"
    cmd = cmd + " -o " + out_path
    return cmd

// ── Layout semantics ───────────────────────────────────────────────────────
// size(T) is target-dependent but unique per target. Named structs are packed:
// offset(field0) = 0 and offset(fieldi) = sum of the sizes of the preceding
// fields. A declaration-level `layout(..., align(n))` rounds each field offset
// and the total size up to n. A generic-parameter field that is never read or
// written is a witness: its size is zero and construction omits it.
//
// These functions are the target descriptor's layout evaluator. IR generation
// bakes the resulting offsets, widths, and allocation extents into IR, so the
// backend does not need the checker's generic tables to recover them.

fn layout_struct_of(ti: int) -> int:
    if ti < 0 || ti >= g_type_count:
        return -1
    k := get_type_kind(ti)
    base : ., mut = ti
    if k == TYP_GENERIC_APPLY:
        base = get_type_data(ti)
        if base < 0 || base >= g_type_count:
            return -1
    if get_type_kind(base) != TYP_NAMED:
        return -1
    name_ni := get_type_data(base)
    si : ., mut = 0
    loop:
        if si >= g_struct_count:
            return -1
        if si_name(si) == name_ni:
            return si
        si = si + 1
    return -1

fn layout_generic_index(si: int, name_ni: int) -> int:
    gi : ., mut = 0
    loop:
        if gi >= si_generic_count(si):
            return -1
        if si_generic_name(si, gi) == name_ni:
            return gi
        gi = gi + 1
    return -1

fn layout_apply_arg(ti: int, gi: int) -> int:
    if gi < 0:
        return -1
    if ti < 0 || ti >= g_type_count:
        return -1
    if get_type_kind(ti) != TYP_GENERIC_APPLY:
        return -1
    start := get_type_extra(ti)
    cnt := cell_load(g_gen_apply_data, start * 8)
    if gi >= cnt:
        return -1
    return cell_load(g_gen_apply_data, (start + 1 + gi) * 8)

// Substitute the declared type of a field in a concrete generic application.
// Unbound parameters return -1: they have no size and cannot participate in a
// layout.
fn layout_subst(ti: int, origin: int, si: int, depth: int) -> int:
    if ti < 0 || depth > 32:
        return -1
    k := get_type_kind(ti)
    if k < 0:
        return ti
    if k == TYP_GENERIC_PARAM:
        gi := layout_generic_index(si, get_type_data(ti))
        arg := layout_apply_arg(origin, gi)
        if arg < 0:
            return -1
        return arg
    if k == TYP_ARRAY:
        inner := layout_subst(get_type_data(ti), origin, si, depth + 1)
        if inner < 0:
            return -1
        return alloc_type(TYP_ARRAY, inner, get_type_extra(ti))
    if k == TYP_SLICE:
        inner := layout_subst(get_type_data(ti), origin, si, depth + 1)
        if inner < 0:
            return -1
        return alloc_type(TYP_SLICE, inner, 0)
    if k == TYP_REF:
        inner := layout_subst(get_type_data(ti), origin, si, depth + 1)
        if inner < 0:
            return -1
        return alloc_type(TYP_REF, inner, get_type_extra(ti))
    if k == TYP_PTR:
        inner := layout_subst(get_type_data(ti), origin, si, depth + 1)
        if inner < 0:
            return -1
        return alloc_type(TYP_PTR, inner, get_type_extra(ti))
    if k == TYP_OPTIONAL:
        inner := layout_subst(get_type_data(ti), origin, si, depth + 1)
        if inner < 0:
            return -1
        return alloc_type(TYP_OPTIONAL, inner, 0)
    if k == TYP_GENERIC_APPLY:
        start := get_type_extra(ti)
        cnt := cell_load(g_gen_apply_data, start * 8)
        subs : string, mut
        if cnt > 0:
            subs = alloc(cnt * 8)
        i : ., mut = 0
        loop:
            if i >= cnt:
                break
            sub := layout_subst(cell_load(g_gen_apply_data, (start + 1 + i) * 8), origin, si, depth + 1)
            if sub < 0:
                return -1
            cell_store(subs, i * 8, sub)
            i = i + 1
        ns := g_gen_apply_data_count
        grow_gen_apply_data(ns + 1 + cnt)
        cell_store(g_gen_apply_data, ns * 8, cnt)
        j : ., mut = 0
        loop:
            if j >= cnt:
                break
            cell_store(g_gen_apply_data, (ns + 1 + j) * 8, cell_load(subs, j * 8))
            j = j + 1
        g_gen_apply_data_count = ns + 1 + cnt
        return alloc_type(TYP_GENERIC_APPLY, get_type_data(ti), ns)
    return ti

// Resolve a field's declared type node in the context of its struct. The
// checker's res_type_node treats an unknown identifier as a named type; in a
// generic field list the identifier is a type variable instead.
fn layout_resolve_field_node(node: int, si: int) -> int:
    if node < 0:
        return -1
    k := ast_kind(node)
    if k == 0:
        return ty_code_to_ti(ast_type_val(node))
    if k == EXPR_IDENT:
        ni := ast_int_val(node)
        if is_struct_generic(si, ni) != 0:
            return alloc_type(TYP_GENERIC_PARAM, ni, 0)
        return res_type_node(node)
    if k == EXPR_ARRAY:
        inner := layout_resolve_field_node(ast_a(node), si)
        if inner < 0:
            return -1
        sz := ast_int_val(node)
        if sz == 0:
            return alloc_type(TYP_SLICE, inner, 0)
        return alloc_type(TYP_ARRAY, inner, sz)
    if k == EXPR_REFTYPE:
        inner := layout_resolve_field_node(ast_a(node), si)
        if inner < 0:
            return -1
        return alloc_type(TYP_REF, inner, ast_int_val(node))
    if k == EXPR_PTRTYPE:
        inner := layout_resolve_field_node(ast_a(node), si)
        if inner < 0:
            return -1
        return alloc_type(TYP_PTR, inner, 0)
    if k == EXPR_OPTIONAL:
        inner := layout_resolve_field_node(ast_a(node), si)
        if inner < 0:
            return -1
        return alloc_type(TYP_OPTIONAL, inner, 0)
    return res_type_node(node)

fn layout_field_ti(ti: int, si: int, fi: int) -> int:
    tn := si_field_type_node(si, fi)
    // A direct type-variable field can be resolved without allocating an
    // unbound TYP_GENERIC_PARAM row. Unbound rows must not reach the .ccr TYPE
    // segment, and an unbound field has no layout anyway.
    if tn >= 0 && ast_kind(tn) == EXPR_IDENT:
        ni := ast_int_val(tn)
        if is_struct_generic(si, ni) != 0:
            gi := layout_generic_index(si, ni)
            arg := layout_apply_arg(ti, gi)
            if arg >= 0:
                return arg
            if get_type_kind(ti) == TYP_GENERIC_APPLY:
                return -1
            // A bare struct name in a parameter position is a monomorphized
            // template. The value slot still holds one concrete value, so its
            // representation is one machine word when the instance's type
            // argument is not carried on this row.
            return TI_INT
    ft := layout_resolve_field_node(tn, si)
    if ft < 0:
        return -1
    return layout_subst(ft, ti, si, 0)

fn layout_round_up(v: int, n: int) -> int:
    if n <= 1:
        return v
    r := v % n
    if r == 0:
        return v
    return v + n - r

fn layout_type_size(ti: int, depth: int) -> int:
    if ti < 0 || depth > 32:
        return -1
    if ti == TI_DEX_S:
        return X86_MP_WORD_BYTES
    if ti == TI_CHAR:
        return 4
    if ti < 0 || ti >= g_type_count:
        return X86_MP_WORD_BYTES
    k := get_type_kind(ti)
    if k == TYP_BASE:
        return x86_mp_size(ti)
    if k == TYP_ARRAY:
        elem := layout_type_size(get_type_data(ti), depth + 1)
        if elem < 0:
            return -1
        return elem * get_type_extra(ti)
    if k == TYP_SLICE:
        return X86_MP_SLICE_BYTES
    if k == TYP_PTR || k == TYP_REF:
        return X86_MP_WORD_BYTES
    if k == TYP_NAMED || k == TYP_GENERIC_APPLY:
        if layout_struct_of(ti) < 0:
            // A named type that is not a struct is an enum (or an opaque named
            // atom); its value representation is one machine word.
            return X86_MP_WORD_BYTES
        return layout_struct_size(ti, depth + 1)
    if k == TYP_TUPLE:
        cnt := get_type_data(ti)
        start := get_type_extra(ti)
        total : ., mut = 0
        i : ., mut = 0
        loop:
            if i >= cnt:
                break
            es := layout_type_size(cell_load(g_gen_apply_data, (start + i) * 8), depth + 1)
            if es < 0:
                return -1
            total = total + es
            i = i + 1
        return total
    if k == TYP_OPTIONAL:
        inner := layout_type_size(get_type_data(ti), depth + 1)
        if inner < 0:
            return -1
        return inner + X86_MP_WORD_BYTES
    if k == TYP_GENERIC_PARAM:
        return -1
    if k == TYP_NULL:
        return 0
    if k == TYP_DYN:
        return X86_MP_WORD_BYTES * 2
    return X86_MP_WORD_BYTES

// Storage stride for an array element or a field slot. Scalar values occupy
// their semantic size; aggregates are references today, so a slot never falls
// below one machine word.
fn layout_storage_size(ti: int) -> int:
    sz := layout_type_size(ti, 0)
    if sz < 0:
        return X86_MP_WORD_BYTES
    k := get_type_kind(ti)
    if k == TYP_NAMED || k == TYP_GENERIC_APPLY || k == TYP_TUPLE || k == TYP_SLICE || k == TYP_ARRAY || k == TYP_OPTIONAL || k == TYP_DYN:
        if sz < X86_MP_WORD_BYTES:
            return X86_MP_WORD_BYTES
    if sz <= 0:
        return 0
    return sz

fn layout_field_width(ti: int, si: int, fi: int) -> int:
    if si_field_witness(si, fi) != 0:
        return 0
    ft := layout_field_ti(ti, si, fi)
    if ft < 0:
        return 0
    sz := layout_type_size(ft, 0)
    if sz <= 0:
        return 0
    k := get_type_kind(ft)
    if k == TYP_NAMED || k == TYP_GENERIC_APPLY || k == TYP_TUPLE || k == TYP_SLICE || k == TYP_ARRAY || k == TYP_OPTIONAL || k == TYP_DYN:
        return X86_MP_WORD_BYTES
    if sz > X86_MP_WORD_BYTES:
        return X86_MP_WORD_BYTES
    return sz

fn layout_struct_size(ti: int, depth: int) -> int:
    si := layout_struct_of(ti)
    if si < 0:
        return -1
    al := si_layout_align(si)
    running : ., mut = 0
    fc := si_field_count(si)
    fi : ., mut = 0
    loop:
        if fi >= fc:
            break
        fs : ., mut = 0
        if si_field_witness(si, fi) == 0:
            ft := layout_field_ti(ti, si, fi)
            if ft < 0:
                fs = 0
            else:
                fs = layout_type_size(ft, depth + 1)
                if fs < 0:
                    fs = 0
        if al > 0:
            running = layout_round_up(running, al)
        running = running + fs
        fi = fi + 1
    if al > 0:
        running = layout_round_up(running, al)
    return running

// Allocation extent: semantic size plus enough room for the reference-width
// storage of the last field when that field is an aggregate.
fn layout_struct_alloc_size(ti: int) -> int:
    si := layout_struct_of(ti)
    if si < 0:
        return layout_storage_size(ti)
    al := si_layout_align(si)
    running : ., mut = 0
    end : ., mut = 0
    fc := si_field_count(si)
    fi : ., mut = 0
    loop:
        if fi >= fc:
            break
        fs : ., mut = 0
        fw : ., mut = 0
        if si_field_witness(si, fi) == 0:
            ft := layout_field_ti(ti, si, fi)
            if ft >= 0:
                fs = layout_type_size(ft, 0)
                if fs < 0:
                    fs = 0
                fw = layout_field_width(ti, si, fi)
        if al > 0:
            running = layout_round_up(running, al)
        if running + fw > end:
            end = running + fw
        running = running + fs
        fi = fi + 1
    if al > 0:
        running = layout_round_up(running, al)
        end = layout_round_up(end, al)
    if end < running:
        end = running
    if end <= 0:
        return X86_MP_WORD_BYTES
    return end

fn layout_field_offset(ti: int, field_index: int) -> int:
    si := layout_struct_of(ti)
    if si < 0 || field_index < 0 || field_index >= si_field_count(si):
        return -1
    al := si_layout_align(si)
    running : ., mut = 0
    fi : ., mut = 0
    loop:
        if fi >= field_index:
            break
        fs : ., mut = 0
        if si_field_witness(si, fi) == 0:
            ft := layout_field_ti(ti, si, fi)
            if ft >= 0:
                fs = layout_type_size(ft, 0)
                if fs < 0:
                    fs = 0
        if al > 0:
            running = layout_round_up(running, al)
        running = running + fs
        fi = fi + 1
    if al > 0:
        running = layout_round_up(running, al)
    return running

fn layout_tuple_field_offset(ti: int, field_index: int) -> int:
    if ti < 0 || ti >= g_type_count:
        return -1
    if get_type_kind(ti) != TYP_TUPLE:
        return -1
    cnt := get_type_data(ti)
    start := get_type_extra(ti)
    if field_index < 0 || field_index >= cnt:
        return -1
    running : ., mut = 0
    i : ., mut = 0
    loop:
        if i >= field_index:
            break
        sz := layout_type_size(cell_load(g_gen_apply_data, (start + i) * 8), 0)
        if sz > 0:
            running = running + sz
        i = i + 1
    return running

fn layout_tuple_storage_size(ti: int) -> int:
    if ti < 0 || ti >= g_type_count:
        return X86_MP_WORD_BYTES
    if get_type_kind(ti) != TYP_TUPLE:
        return X86_MP_WORD_BYTES
    cnt := get_type_data(ti)
    start := get_type_extra(ti)
    total : ., mut = 0
    i : ., mut = 0
    loop:
        if i >= cnt:
            break
        et := cell_load(g_gen_apply_data, (start + i) * 8)
        sz := layout_storage_size(et)
        if sz > 0:
            total = total + sz
        i = i + 1
    if total <= 0:
        return X86_MP_WORD_BYTES
    return total

fn layout_type_align(ti: int, depth: int) -> int:
    if ti < 0 || depth > 32:
        return 8
    if ti == TI_DEX_S || ti == TI_CHAR:
        return 4
    if ti < 0 || ti >= g_type_count:
        return 8
    k := get_type_kind(ti)
    if k == TYP_BASE:
        if ti == TI_UNIT:
            return 1
        return x86_mp_align(ti)
    if k == TYP_ARRAY:
        return layout_type_align(get_type_data(ti), depth + 1)
    if k == TYP_TUPLE:
        cnt := get_type_data(ti)
        start := get_type_extra(ti)
        best : ., mut = 1
        i : ., mut = 0
        loop:
            if i >= cnt:
                break
            a := layout_type_align(cell_load(g_gen_apply_data, (start + i) * 8), depth + 1)
            if a > best:
                best = a
            i = i + 1
        return best
    if k == TYP_NAMED || k == TYP_GENERIC_APPLY:
        si := layout_struct_of(ti)
        if si < 0:
            return X86_MP_WORD_BYTES
        declared := si_layout_align(si)
        best2 : ., mut = 1
        fc := si_field_count(si)
        fi : ., mut = 0
        loop:
            if fi >= fc:
                break
            if si_field_witness(si, fi) == 0:
                ft := layout_field_ti(ti, si, fi)
                if ft >= 0:
                    a2 := layout_type_align(ft, depth + 1)
                    if a2 > best2:
                        best2 = a2
            fi = fi + 1
        if declared > best2:
            return declared
        return best2
    if k == TYP_GENERIC_PARAM:
        return 1
    if k == TYP_NULL:
        return 1
    return 8
