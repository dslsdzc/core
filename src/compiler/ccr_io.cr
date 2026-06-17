// === ccr_io.cr ===
// .ccr binary serialization — the interface between corec (frontend)
// and corearch (backend).
//
// Format (all integers little-endian):
//   [magic: "CCR1" = 4 bytes]
//   [version: u32 = 1]
//   [func_count, instr_count, var_count, str_count, str_const_count, struct_count, enum_count: u32 ×7]
//   [strings: str_count × [len: u32] [data: len bytes]]
//   [func_meta: func_count × [name_idx, param_count, ret_type, instr_start, instr_count, var_start, var_count: u32 ×7]]
//   [instrs: instr_count × [opcode, dest, src1, src2, src3, type_kind: i32 ×6]]
//   [vars: var_count × [name_idx, id, type_kind: u32 ×3]]
//   [str_consts: str_const_count × [str_idx: u32]]
//   [structs: struct_count × [name_idx: u32] [field_count: u32] fields[field_count]×[name_idx, type: u32 ×2]]
//   [enums: enum_count × [name_idx: u32] [variant_count: u32] variants[variant_count]×[name_idx: u32] [field_count: u32] fields[field_count]×[type: u32]]

// --- Byte buffer helpers ---
// No bitwise ops in Core — use arithmetic instead.

CCR_MAGIC : int = 827474755;  // "CCR1" (0x31524343)

fn bw_byte(val: int, shift: int) -> int {
    if shift == 0 { return val % 256; }
    if shift >= 24 { return (val / 16777216) % 256; }
    if shift >= 16 { return (val / 65536) % 256; }
    if shift >= 8 { return (val / 256) % 256; }
    return 0;
}

fn buf_write_u32(buf: string, pos: int, val: int) {
    __builtin_store8(buf, pos,     bw_byte(val, 0));
    __builtin_store8(buf, pos + 1, bw_byte(val, 8));
    __builtin_store8(buf, pos + 2, bw_byte(val, 16));
    __builtin_store8(buf, pos + 3, bw_byte(val, 24));
}

fn buf_write_i32(buf: string, pos: int, val: int) {
    if val < 0 { val = val + 4294967296; }  // two's complement
    buf_write_u32(buf, pos, val);
}

fn buf_read_u32(buf: string, pos: int) -> int {
    b0 := __builtin_load8(buf, pos);
    b1 := __builtin_load8(buf, pos + 1);
    b2 := __builtin_load8(buf, pos + 2);
    b3 := __builtin_load8(buf, pos + 3);
    return b0 + b1 * 256 + b2 * 65536 + b3 * 16777216;
}

fn buf_read_i32(buf: string, pos: int) -> int {
    val := buf_read_u32(buf, pos);
    if val >= 2147483648 { return val - 4294967296; }
    return val;
}

// --- Size calculation ---

fn calc_ccr_size() -> int {
    sz : ., mut = 36;  // header + counts

    // strings
    si : ., mut = 0;
    loop {
        if si >= g_str_count { break; }
        sl := str_len(si);
        sz = sz + 4 + sl;
        si = si + 1;
    }

    sz = sz + g_ir_func_count * 28;       // func meta
    sz = sz + g_ir_instr_count * 24;       // instrs
    sz = sz + g_ir_var_count * 12;         // vars
    sz = sz + g_ir_str_const_count * 4;    // str_consts

    // structs
    sti : ., mut = 0;
    loop {
        if sti >= g_struct_count { break; }
        fc := si_field_count(sti);
        sz = sz + 8 + fc * 8;
        sti = sti + 1;
    }

    // enums
    ei : ., mut = 0;
    loop {
        if ei >= g_enum_count { break; }
        vc := ei_variant_count(ei);
        sz = sz + 8;  // name_idx + variant_count
        vi : ., mut = 0;
        loop {
            if vi >= vc { break; }
            tc := ei_variant_type_count(ei, vi);
            sz = sz + 8;  // variant_name_idx + field_count
            sz = sz + tc * 4;
            vi = vi + 1;
        }
        ei = ei + 1;
    }

    return sz;
}

// --- Save ---

fn save_ccr(path: string) -> int {
    tsz := calc_ccr_size();
    buf := __builtin_alloc(tsz);
    pos : ., mut = 0;

    // Magic + version
    buf_write_u32(buf, pos, CCR_MAGIC); pos = pos + 4;
    buf_write_u32(buf, pos, 1); pos = pos + 4;

    // Counts
    buf_write_u32(buf, pos, g_ir_func_count); pos = pos + 4;
    buf_write_u32(buf, pos, g_ir_instr_count); pos = pos + 4;
    buf_write_u32(buf, pos, g_ir_var_count); pos = pos + 4;
    buf_write_u32(buf, pos, g_str_count); pos = pos + 4;
    buf_write_u32(buf, pos, g_ir_str_const_count); pos = pos + 4;
    buf_write_u32(buf, pos, g_struct_count); pos = pos + 4;
    buf_write_u32(buf, pos, g_enum_count); pos = pos + 4;

    // Strings
    si : ., mut = 0;
    loop {
        if si >= g_str_count { break; }
        sl := str_len(si);
        buf_write_u32(buf, pos, sl); pos = pos + 4;
        ci : ., mut = 0;
        loop {
            if ci >= sl { break; }
            ch := str_load8(si, ci);
            __builtin_store8(buf, pos, ch);
            pos = pos + 1;
            ci = ci + 1;
        }
        si = si + 1;
    }

    // Func metadata
    fi : ., mut = 0;
    loop {
        if fi >= g_ir_func_count { break; }
        buf_write_u32(buf, pos, r64(g_ir_func_name_idx, fi * 8)); pos = pos + 4;
        buf_write_u32(buf, pos, r64(g_ir_func_param_count, fi * 8)); pos = pos + 4;
        buf_write_u32(buf, pos, r64(g_ir_func_ret_type, fi * 8)); pos = pos + 4;
        buf_write_u32(buf, pos, r64(g_ir_func_instr_start, fi * 8)); pos = pos + 4;
        buf_write_u32(buf, pos, r64(g_ir_func_instr_count, fi * 8)); pos = pos + 4;
        buf_write_u32(buf, pos, r64(g_ir_func_var_start, fi * 8)); pos = pos + 4;
        buf_write_u32(buf, pos, r64(g_ir_func_var_count, fi * 8)); pos = pos + 4;
        fi = fi + 1;
    }

    // Instructions
    ii : ., mut = 0;
    loop {
        if ii >= g_ir_instr_count { break; }
        buf_write_u32(buf, pos, iri_op(ii)); pos = pos + 4;
        buf_write_i32(buf, pos, iri_dest(ii)); pos = pos + 4;
        buf_write_i32(buf, pos, iri_s1(ii)); pos = pos + 4;
        buf_write_i32(buf, pos, iri_s2(ii)); pos = pos + 4;
        buf_write_i32(buf, pos, iri_s3(ii)); pos = pos + 4;
        buf_write_u32(buf, pos, iri_tk(ii)); pos = pos + 4;
        ii = ii + 1;
    }

    // IR variables
    vi : ., mut = 0;
    loop {
        if vi >= g_ir_var_count { break; }
        buf_write_u32(buf, pos, irv_name(vi)); pos = pos + 4;
        buf_write_u32(buf, pos, irv_id(vi)); pos = pos + 4;
        buf_write_u32(buf, pos, irv_type(vi)); pos = pos + 4;
        vi = vi + 1;
    }

    // String constants
    sci : ., mut = 0;
    loop {
        if sci >= g_ir_str_const_count { break; }
        buf_write_u32(buf, pos, r64(g_ir_str_consts, sci * 8)); pos = pos + 4;
        sci = sci + 1;
    }

    // Structs
    sti : ., mut = 0;
    loop {
        if sti >= g_struct_count { break; }
        fc := si_field_count(sti);
        buf_write_u32(buf, pos, si_name(sti)); pos = pos + 4;
        buf_write_u32(buf, pos, fc); pos = pos + 4;
        fii : ., mut = 0;
        loop {
            if fii >= fc { break; }
            buf_write_u32(buf, pos, si_field_name(sti, fii)); pos = pos + 4;
            buf_write_u32(buf, pos, si_field_type(sti, fii)); pos = pos + 4;
            fii = fii + 1;
        }
        sti = sti + 1;
    }

    // Enums
    ei : ., mut = 0;
    loop {
        if ei >= g_enum_count { break; }
        vc := ei_variant_count(ei);
        buf_write_u32(buf, pos, ei_name(ei)); pos = pos + 4;
        buf_write_u32(buf, pos, vc); pos = pos + 4;
        vi2 : ., mut = 0;
        loop {
            if vi2 >= vc { break; }
            tcnt := ei_variant_type_count(ei, vi2);
            buf_write_u32(buf, pos, ei_variant_name(ei, vi2)); pos = pos + 4;
            buf_write_u32(buf, pos, tcnt); pos = pos + 4;
            tf : ., mut = 0;
            loop {
                if tf >= tcnt { break; }
                buf_write_u32(buf, pos, ei_variant_type(ei, vi2, tf)); pos = pos + 4;
                tf = tf + 1;
            }
            vi2 = vi2 + 1;
        }
        ei = ei + 1;
    }

    // Use syscall directly (__builtin_write_file uses str_len which stops at null)
    fd := __builtin_syscall3(2, path, 577, 420);  // open(O_WRONLY|O_CREAT|O_TRUNC, 0644)
    if fd < 0 { return -1; }
    written : ., mut = 0;
    written = __builtin_syscall3(1, fd, buf, tsz);  // write(fd, buf, tsz)
    r2 := __builtin_syscall3(3, fd, 0, 0);  // close(fd)
    if written != tsz { return -1; }
    return 0;
}

// --- Load ---

fn load_ccr(data: string, fsize: int) -> int {
    if fsize < 36 { return -1; }  // minimum valid size

    pos : ., mut = 0;

    // Magic
    magic := buf_read_u32(data, pos); pos = pos + 4;
    if magic != CCR_MAGIC { return -1; }

    // Version
    ver := buf_read_u32(data, pos); pos = pos + 4;
    if ver != 1 { return -1; }

    // Counts
    func_cnt := buf_read_u32(data, pos); pos = pos + 4;
    instr_cnt := buf_read_u32(data, pos); pos = pos + 4;
    var_cnt := buf_read_u32(data, pos); pos = pos + 4;
    str_cnt := buf_read_u32(data, pos); pos = pos + 4;
    str_const_cnt := buf_read_u32(data, pos); pos = pos + 4;
    struct_cnt := buf_read_u32(data, pos); pos = pos + 4;
    enum_cnt := buf_read_u32(data, pos); pos = pos + 4;

    // Grow dynamic arrays to needed capacity
    dyn_grow_ir_vars(var_cnt);
    dyn_grow_ir_instrs(instr_cnt);
    dyn_grow_ir_func_meta(func_cnt);
    dyn_grow_ir_str_consts(str_const_cnt);
    dyn_grow_structs(struct_cnt);
    dyn_grow_enums(enum_cnt);

    // Reset arrays
    g_str_count = 0;
    g_ir_var_count = 0;
    g_ir_instr_count = 0;
    g_ir_func_count = 0;
    g_ir_str_const_count = 0;
    g_struct_count = struct_cnt;
    g_enum_count = enum_cnt;

    // Strings
    si : ., mut = 0;
    loop {
        if si >= str_cnt { break; }
        sl := buf_read_u32(data, pos); pos = pos + 4;
        // Allocate buffer for string content
        s := __builtin_alloc(sl + 1);
        ci : ., mut = 0;
        loop {
            if ci >= sl { break; }
            ch := __builtin_load8(data, pos);
            __builtin_store8(s, ci, ch);
            pos = pos + 1;
            ci = ci + 1;
        }
        __builtin_store8(s, sl, 0);
        str_intern(s);
        si = si + 1;
    }

    // Func metadata
    fi : ., mut = 0;
    loop {
        if fi >= func_cnt { break; }
        fv0 := buf_read_u32(data, pos); pos = pos + 4; __builtin_syscall3(1, 1, "D:W\n", 4); w64(g_ir_func_name_idx, fi * 8, fv0);
        fv1 := buf_read_u32(data, pos); pos = pos + 4; w64(g_ir_func_param_count, fi * 8, fv1);
        fv2 := buf_read_u32(data, pos); pos = pos + 4; w64(g_ir_func_ret_type, fi * 8, fv2);
        fv3 := buf_read_u32(data, pos); pos = pos + 4; w64(g_ir_func_instr_start, fi * 8, fv3);
        fv4 := buf_read_u32(data, pos); pos = pos + 4; w64(g_ir_func_instr_count, fi * 8, fv4);
        fv5 := buf_read_u32(data, pos); pos = pos + 4; w64(g_ir_func_var_start, fi * 8, fv5);
        fv6 := buf_read_u32(data, pos); pos = pos + 4; w64(g_ir_func_var_count, fi * 8, fv6);
        g_ir_func_count = fi + 1;
        fi = fi + 1;
    }

    // Instructions
    ii : ., mut = 0;
    loop {
        if ii >= instr_cnt { break; }
        opcode := buf_read_u32(data, pos); pos = pos + 4;
        dest := buf_read_i32(data, pos); pos = pos + 4;
        s1 := buf_read_i32(data, pos); pos = pos + 4;
        s2 := buf_read_i32(data, pos); pos = pos + 4;
        s3 := buf_read_i32(data, pos); pos = pos + 4;
        tk := buf_read_u32(data, pos); pos = pos + 4;
        iri_set_op(ii, opcode);
        iri_set_dest(ii, dest);
        iri_set_s1(ii, s1);
        iri_set_s2(ii, s2);
        iri_set_s3(ii, s3);
        iri_set_tk(ii, tk);
        g_ir_instr_count = ii + 1;
        ii = ii + 1;
    }

    // IR variables
    vi : ., mut = 0;
    loop {
        if vi >= var_cnt { break; }
        name_ni := buf_read_u32(data, pos); pos = pos + 4;
        id := buf_read_u32(data, pos); pos = pos + 4;
        tk := buf_read_u32(data, pos); pos = pos + 4;
        irv_set_name(vi, name_ni);
        irv_set_id(vi, id);
        irv_set_type(vi, tk);
        g_ir_var_count = vi + 1;
        vi = vi + 1;
    }

    // String constants
    sci : ., mut = 0;
    loop {
        if sci >= str_const_cnt { break; }
        scv := buf_read_u32(data, pos); pos = pos + 4; w64(g_ir_str_consts, sci * 8, scv);
        g_ir_str_const_count = sci + 1;
        sci = sci + 1;
    }

    // Structs
    sti : ., mut = 0;
    loop {
        if sti >= struct_cnt { break; }
        name_ni := buf_read_u32(data, pos); pos = pos + 4;
        fc := buf_read_u32(data, pos); pos = pos + 4;
        if fc > MAX_STRUCT_FIELDS { __builtin_println("error: .ccr struct field count exceeds max"); return 1; }
        w64(g_structs, sti * ESZ_STRUCTINFO + OFF_SI_NAME, name_ni);
        w64(g_structs, sti * ESZ_STRUCTINFO + OFF_SI_FIELD_COUNT, fc);
        // Zero out all field slots and type nodes
        zfi : ., mut = 0;
        loop {
            if zfi >= 16 { break; }
            w64(g_structs, sti * ESZ_STRUCTINFO + OFF_SI_FIELD_NAMES + zfi * 8, 0);
            w64(g_structs, sti * ESZ_STRUCTINFO + OFF_SI_FIELD_TYPES + zfi * 8, 0);
            w64(g_structs, sti * ESZ_STRUCTINFO + OFF_SI_FIELD_TYPE_NODES + zfi * 8, 0);
            zfi = zfi + 1;
        }
        // Zero generic slots
        w64(g_structs, sti * ESZ_STRUCTINFO + OFF_SI_GENERIC_COUNT, 0);
        zgi : ., mut = 0;
        loop { if zgi >= 4 { break; } w64(g_structs, sti * ESZ_STRUCTINFO + OFF_SI_GENERIC_NAMES + zgi * 8, 0); zgi = zgi + 1; }
        // Write field data
        fi2 : ., mut = 0;
        loop {
            if fi2 >= fc { break; }
            fn_ni := buf_read_u32(data, pos); pos = pos + 4;
            ft := buf_read_u32(data, pos); pos = pos + 4;
            w64(g_structs, sti * ESZ_STRUCTINFO + OFF_SI_FIELD_NAMES + fi2 * 8, fn_ni);
            w64(g_structs, sti * ESZ_STRUCTINFO + OFF_SI_FIELD_TYPES + fi2 * 8, ft);
            fi2 = fi2 + 1;
        }
        sti = sti + 1;
    }

    // Enums
    ei : ., mut = 0;
    loop {
        if ei >= enum_cnt { break; }
        ename_ni := buf_read_u32(data, pos); pos = pos + 4;
        vc := buf_read_u32(data, pos); pos = pos + 4;
        if vc > MAX_ENUM_VARIANTS { __builtin_println("error: .ccr enum variant count exceeds max"); return 1; }
        w64(g_enums, ei * ESZ_ENUMINFO + OFF_EI_NAME, ename_ni);
        w64(g_enums, ei * ESZ_ENUMINFO + OFF_EI_VARIANT_COUNT, vc);
        // Zero all variant slots
        zvi : ., mut = 0;
        loop {
            if zvi >= 16 { break; }
            w64(g_enums, ei * ESZ_ENUMINFO + OFF_EI_VARIANTS + zvi * OFF_EV_SIZE + OFF_EV_NAME, 0);
            w64(g_enums, ei * ESZ_ENUMINFO + OFF_EI_VARIANTS + zvi * OFF_EV_SIZE + OFF_EV_TYPE_COUNT, 0);
            ztj : ., mut = 0;
            loop { if ztj >= 16 { break; } w64(g_enums, ei * ESZ_ENUMINFO + OFF_EI_VARIANTS + zvi * OFF_EV_SIZE + OFF_EV_TYPES + ztj * 8, 0); ztj = ztj + 1; }
            zvi = zvi + 1;
        }
        w64(g_enums, ei * ESZ_ENUMINFO + OFF_EI_GENERIC_COUNT, 0);
        zgi2 : ., mut = 0;
        loop { if zgi2 >= 4 { break; } w64(g_enums, ei * ESZ_ENUMINFO + OFF_EI_GENERIC_NAMES + zgi2 * 8, 0); zgi2 = zgi2 + 1; }
        // Write variant data
        vi3 : ., mut = 0;
        loop {
            if vi3 >= vc { break; }
            vni := buf_read_u32(data, pos); pos = pos + 4;
            tc := buf_read_u32(data, pos); pos = pos + 4;
            if tc > MAX_VARIANT_TYPES { __builtin_println("error: .ccr variant type count exceeds max"); return 1; }
            w64(g_enums, ei * ESZ_ENUMINFO + OFF_EI_VARIANTS + vi3 * OFF_EV_SIZE + OFF_EV_NAME, vni);
            w64(g_enums, ei * ESZ_ENUMINFO + OFF_EI_VARIANTS + vi3 * OFF_EV_SIZE + OFF_EV_TYPE_COUNT, tc);
            tf : ., mut = 0;
            loop {
                if tf >= tc { break; }
                tval := buf_read_u32(data, pos); pos = pos + 4;
                w64(g_enums, ei * ESZ_ENUMINFO + OFF_EI_VARIANTS + vi3 * OFF_EV_SIZE + OFF_EV_TYPES + tf * 8, tval);
                tf = tf + 1;
            }
            vi3 = vi3 + 1;
        }
        ei = ei + 1;
    }

    return 0;
}
