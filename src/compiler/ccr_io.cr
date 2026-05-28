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
        sl := __builtin_str_len(g_strs[si]);
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
        s := g_structs[sti];
        sz = sz + 8 + s.field_count * 8;
        sti = sti + 1;
    }

    // enums
    ei : ., mut = 0;
    loop {
        if ei >= g_enum_count { break; }
        e := g_enums[ei];
        sz = sz + 8;  // name_idx + variant_count
        vi : ., mut = 0;
        loop {
            if vi >= e.variant_count { break; }
            sz = sz + 8;  // variant_name_idx + field_count
            sz = sz + e.variants[vi].type_count * 4;
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
        sl := __builtin_str_len(g_strs[si]);
        buf_write_u32(buf, pos, sl); pos = pos + 4;
        ci : ., mut = 0;
        loop {
            if ci >= sl { break; }
            ch := __builtin_load8(g_strs[si], ci);
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
        buf_write_u32(buf, pos, g_ir_func_name_idx[fi]); pos = pos + 4;
        buf_write_u32(buf, pos, g_ir_func_param_count[fi]); pos = pos + 4;
        buf_write_u32(buf, pos, g_ir_func_ret_type[fi]); pos = pos + 4;
        buf_write_u32(buf, pos, g_ir_func_instr_start[fi]); pos = pos + 4;
        buf_write_u32(buf, pos, g_ir_func_instr_count[fi]); pos = pos + 4;
        buf_write_u32(buf, pos, g_ir_func_var_start[fi]); pos = pos + 4;
        buf_write_u32(buf, pos, g_ir_func_var_count[fi]); pos = pos + 4;
        fi = fi + 1;
    }

    // Instructions
    ii : ., mut = 0;
    loop {
        if ii >= g_ir_instr_count { break; }
        inst := g_ir_instrs[ii];
        buf_write_u32(buf, pos, inst.opcode); pos = pos + 4;
        buf_write_i32(buf, pos, inst.dest); pos = pos + 4;
        buf_write_i32(buf, pos, inst.src1); pos = pos + 4;
        buf_write_i32(buf, pos, inst.src2); pos = pos + 4;
        buf_write_i32(buf, pos, inst.src3); pos = pos + 4;
        buf_write_u32(buf, pos, inst.type_kind); pos = pos + 4;
        ii = ii + 1;
    }

    // IR variables
    vi : ., mut = 0;
    loop {
        if vi >= g_ir_var_count { break; }
        v := g_ir_vars[vi];
        buf_write_u32(buf, pos, str_intern(v.name)); pos = pos + 4;
        buf_write_u32(buf, pos, v.id); pos = pos + 4;
        buf_write_u32(buf, pos, v.type_kind); pos = pos + 4;
        vi = vi + 1;
    }

    // String constants
    sci : ., mut = 0;
    loop {
        if sci >= g_ir_str_const_count { break; }
        buf_write_u32(buf, pos, g_ir_str_consts[sci]); pos = pos + 4;
        sci = sci + 1;
    }

    // Structs
    sti : ., mut = 0;
    loop {
        if sti >= g_struct_count { break; }
        s := g_structs[sti];
        buf_write_u32(buf, pos, str_intern(s.name)); pos = pos + 4;
        buf_write_u32(buf, pos, s.field_count); pos = pos + 4;
        fii : ., mut = 0;
        loop {
            if fii >= s.field_count { break; }
            buf_write_u32(buf, pos, str_intern(s.field_names[fii])); pos = pos + 4;
            buf_write_u32(buf, pos, s.field_types[fii]); pos = pos + 4;
            fii = fii + 1;
        }
        sti = sti + 1;
    }

    // Enums
    ei : ., mut = 0;
    loop {
        if ei >= g_enum_count { break; }
        e := g_enums[ei];
        buf_write_u32(buf, pos, str_intern(e.name)); pos = pos + 4;
        buf_write_u32(buf, pos, e.variant_count); pos = pos + 4;
        vi2 : ., mut = 0;
        loop {
            if vi2 >= e.variant_count { break; }
            buf_write_u32(buf, pos, str_intern(e.variants[vi2].name)); pos = pos + 4;
            buf_write_u32(buf, pos, e.variants[vi2].type_count); pos = pos + 4;
            tf : ., mut = 0;
            loop {
                if tf >= e.variants[vi2].type_count { break; }
                buf_write_u32(buf, pos, e.variants[vi2].types[tf]); pos = pos + 4;
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

    // Guard: stay within array bounds
    if func_cnt > MAX_FUNCS { return -1; }
    if instr_cnt > MAX_IRINSTRUCTIONS { return -1; }
    if var_cnt > MAX_IREXPRS { return -1; }
    if str_cnt > MAX_STRS { return -1; }
    if struct_cnt > MAX_STRUCTS { return -1; }
    if enum_cnt > MAX_ENUMS { return -1; }

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
        g_strs[g_str_count] = s;
        g_str_count = g_str_count + 1;
        si = si + 1;
    }

    // Func metadata
    fi : ., mut = 0;
    loop {
        if fi >= func_cnt { break; }
        g_ir_func_name_idx[fi] = buf_read_u32(data, pos); pos = pos + 4;
        g_ir_func_param_count[fi] = buf_read_u32(data, pos); pos = pos + 4;
        g_ir_func_ret_type[fi] = buf_read_u32(data, pos); pos = pos + 4;
        g_ir_func_instr_start[fi] = buf_read_u32(data, pos); pos = pos + 4;
        g_ir_func_instr_count[fi] = buf_read_u32(data, pos); pos = pos + 4;
        g_ir_func_var_start[fi] = buf_read_u32(data, pos); pos = pos + 4;
        g_ir_func_var_count[fi] = buf_read_u32(data, pos); pos = pos + 4;
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
        g_ir_instrs[ii] = IRInstr { opcode = opcode, dest = dest, src1 = s1, src2 = s2, src3 = s3, type_kind = tk };
        g_ir_instr_count = ii + 1;
        ii = ii + 1;
    }

    // IR variables
    vi : ., mut = 0;
    loop {
        if vi >= var_cnt { break; }
        name := buf_read_u32(data, pos); pos = pos + 4;
        id := buf_read_u32(data, pos); pos = pos + 4;
        tk := buf_read_u32(data, pos); pos = pos + 4;
        g_ir_vars[vi] = IRVar { name = g_strs[name], id = id, type_kind = tk };
        g_ir_var_count = vi + 1;
        vi = vi + 1;
    }

    // String constants
    sci : ., mut = 0;
    loop {
        if sci >= str_const_cnt { break; }
        g_ir_str_consts[sci] = buf_read_u32(data, pos); pos = pos + 4;
        g_ir_str_const_count = sci + 1;
        sci = sci + 1;
    }

    // Structs
    sti : ., mut = 0;
    loop {
        if sti >= struct_cnt { break; }
        name_ni := buf_read_u32(data, pos); pos = pos + 4;
        name_str := g_strs[name_ni];
        fc := buf_read_u32(data, pos); pos = pos + 4;
        field_names : [string; 16] = [""; 16];
        field_types : [int; 16] = [0; 16];
        fi2 : ., mut = 0;
        loop {
            if fi2 >= fc { break; }
            field_names[fi2] = g_strs[buf_read_u32(data, pos)]; pos = pos + 4;
            field_types[fi2] = buf_read_u32(data, pos); pos = pos + 4;
            fi2 = fi2 + 1;
        }
        g_structs[sti] = StructInfo { name = name_str, field_names = field_names, field_types = field_types, field_type_nodes = [0;16], field_count = fc, generic_names = ["";4], generic_count = 0 };
        sti = sti + 1;
    }

    // Enums
    ei : ., mut = 0;
    loop {
        if ei >= enum_cnt { break; }
        ename_ni := buf_read_u32(data, pos); pos = pos + 4;
        ename_str := g_strs[ename_ni];
        vc := buf_read_u32(data, pos); pos = pos + 4;
        variants : [EnumVariant; 16] = [EnumVariant { name = "", types = [0;16], type_count = 0 }; 16];
        vi3 : ., mut = 0;
        loop {
            if vi3 >= vc { break; }
            vname := g_strs[buf_read_u32(data, pos)]; pos = pos + 4;
            tc := buf_read_u32(data, pos); pos = pos + 4;
            vtypes : [int; 16] = [0; 16];
            tf : ., mut = 0;
            loop {
                if tf >= tc { break; }
                vtypes[tf] = buf_read_u32(data, pos); pos = pos + 4;
                tf = tf + 1;
            }
            variants[vi3] = EnumVariant { name = vname, types = vtypes, type_count = tc };
            vi3 = vi3 + 1;
        }
        g_enums[ei] = EnumInfo { name = ename_str, variants = variants, variant_count = vc };
        ei = ei + 1;
    }

    return 0;
}
