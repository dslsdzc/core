// === module.cr ===
// File system utilities, fileid management, and import resolution.

fn count_newlines(s: string) -> int {
    slen := str_len(s);
    n : ., mut = 0;
    i : ., mut = 0;
    loop {
        if i >= slen { break; }
        if str_eq(get_char(s, i), "\n") != 0 { n = n + 1; }
        i = i + 1;
    }
    return n;
}

fn get_fileid(s: string) -> string {
    slen := str_len(s);
    i : ., mut = 0;
    loop {
        if i + 6 >= slen { return ""; }
        // Inline "fileid" check — int-based, no str_sub/str_eq
        if load8(s, i) == 102 && load8(s, i+1) == 105 && load8(s, i+2) == 108 &&
           load8(s, i+3) == 101 && load8(s, i+4) == 105 && load8(s, i+5) == 100 {
            j : ., mut = i + 6;
            loop {
                if j >= slen { return ""; }
                if load8(s, j) == 34 {  // '"'
                    start := j + 1;
                    k : ., mut = start;
                    loop {
                        if k >= slen { return ""; }
                        if load8(s, k) == 34 {  // '"'
                            return str_sub(s, start, k - start);
                        }
                        k = k + 1;
                    }
                }
                j = j + 1;
            }
        }
        i = i + 1;
    }
    return "";
}

fn dirname(path: string) -> string {
    slen := str_len(path);
    last_slash : ., mut = -1;
    i : ., mut = 0;
    loop {
        if i >= slen { break; }
        if str_eq(get_char(path, i), "/") != 0 { last_slash = i; }
        i = i + 1;
    }
    if last_slash >= 0 {
        return str_sub(path, 0, last_slash + 1);
    }
    return "";
}

fn basename(path: string) -> string {
    slen := str_len(path);
    if slen == 0 { return ""; }
    end : ., mut = slen;
    // 去掉末尾的 /
    loop {
        if end <= 0 { break; }
        if str_eq(get_char(path, end - 1), "/") != 0 { end = end - 1; }
        else { break; }
    }
    if end == 0 { return "/"; }
    last_slash : ., mut = -1;
    i : ., mut = 0;
    loop {
        if i >= end { break; }
        if str_eq(get_char(path, i), "/") != 0 { last_slash = i; }
        i = i + 1;
    }
    if last_slash >= 0 {
        return str_sub(path, last_slash + 1, end - last_slash - 1);
    }
    return str_sub(path, 0, end);
}

fn parent_dir(dir: string) -> string {
    slen := str_len(dir);
    if slen <= 1 { return ""; }
    trimmed : ., mut = dir;
    last_ch := get_char(dir, slen - 1);
    if str_eq(last_ch, "/") != 0 {
        trimmed = str_sub(dir, 0, slen - 1);
    }
    last_slash : ., mut = -1;
    i : ., mut = 0;
    tlen := str_len(trimmed);
    loop {
        if i >= tlen { break; }
        if str_eq(get_char(trimmed, i), "/") != 0 { last_slash = i; }
        i = i + 1;
    }
    if last_slash >= 0 {
        return str_sub(trimmed, 0, last_slash + 1);
    }
    return "";
}

fn load_imports(dir_path: string) -> string {
    imp_path : ., mut = dir_path + "_import.cr";
    content := read_file(imp_path);
    if str_len(content) > 0 {
    }
    return content;
}

fn reg_fileid(fileid_str: string, path: string) -> int {
    fni := str_intern(fileid_str);
    fi : ., mut = 0;
    loop {
        if fi >= g_file_count { break; }
        if r64(g_files, fi * 16) == fni {
            return fni;
        }
        fi = fi + 1;
    }
    grow_files(g_file_count + 1);
    w64(g_files, g_file_count * 16, fni);
    store_str_ptr(g_files, g_file_count * 16 + 8, path);
    g_file_count = g_file_count + 1;
    return fni;
}

fn build_line_fileid() {
    g_line_count = 0; g_line_cap = 0;
    slen := str_len(g_source);
    seg_idx : ., mut = 0;
    grow_line_file(g_line_count + 1); w64(g_line_fileid, g_line_count * 8, r64(g_seg_fileids, 0));
    g_line_count = g_line_count + 1;
    pos : ., mut = 0;
    loop {
        if pos >= slen { break; }
        if str_eq(get_char(g_source, pos), "\n") != 0 {
            next_start := 0;
            next_fileid := -1;
            if seg_idx + 1 < g_seg_count {
                next_start = r64(g_seg_starts, (seg_idx + 1) * 8);
                next_fileid = r64(g_seg_fileids, (seg_idx + 1) * 8);
            }
            if next_fileid >= 0 && pos + 1 >= next_start {
                seg_idx = seg_idx + 1;
            }
            grow_line_file(g_line_count + 1); w64(g_line_fileid, g_line_count * 8, r64(g_seg_fileids, seg_idx * 8));
            g_line_count = g_line_count + 1;
        }
        pos = pos + 1;
    }
}

// Register functions from a .so extension index file.
// Index format (one function per line):
//   func_name: param_types [-> ret_type] [, tags...]
// Examples:
//   print: string, variadic, auto_str
//   read_file: string -> string
fn reg_so_funcs(index_content: string, so_name: string) {
    sl := str_len(index_content);
    line_start : ., mut = 0;
    loop {
        if line_start >= sl { break; }
        // Find end of line
        line_end : ., mut = line_start;
        loop {
            if line_end >= sl { break; }
            c := load8(index_content, line_end);
            if c == 10 { break; }  // \n
            line_end = line_end + 1;
        }
        line := str_sub(index_content, line_start, line_end - line_start);
        line_start = line_end + 1;

        // Skip empty lines and comments
        if str_len(line) == 0 { continue; }
        c0 := load8(line, 0);
        if c0 == 35 || c0 == 10 || c0 == 13 { continue; }  // #, \n, \r

        // Parse: func_name: rest
        colon_pos : ., mut = -1;
        ci : ., mut = 0;
        loop {
            if ci >= str_len(line) { break; }
            if load8(line, ci) == 58 { colon_pos = ci; break; }  // :
            ci = ci + 1;
        }
        if colon_pos < 0 { continue; }
        func_name := str_sub(line, 0, colon_pos);
        rest := str_sub(line, colon_pos + 1, str_len(line) - colon_pos - 1);
        if str_len(func_name) == 0 { continue; }

        // Parse rest into params and tags (comma-separated)
        param_types : ., mut = "";
        ret_type : ., mut = "unit";
        tag_flags : ., mut = 0;

        // Split rest by -> to get ret type
        arrow_pos : ., mut = -1;
        ai : ., mut = 0; rl := str_len(rest);
        loop {
            if ai + 2 > rl { break; }
            if load8(rest, ai) == 45 && ai + 1 < rl && load8(rest, ai+1) == 62 {  // ->
                arrow_pos = ai; break; }
            ai = ai + 1;
        }

        params_str : ., mut = "";
        tags_str : ., mut = "";
        if arrow_pos >= 0 {
            params_str = str_sub(rest, 0, arrow_pos);
            ret_str := str_sub(rest, arrow_pos + 2, rl - arrow_pos - 2);
            // ret_str might have tags too after comma
            ret_comma : ., mut = -1;
            rci : ., mut = 0;
            loop { if rci >= str_len(ret_str) { break; }
                if load8(ret_str, rci) == 44 { ret_comma = rci; break; }
                rci = rci + 1; }
            if ret_comma >= 0 {
                ret_type = str_sub(ret_str, 0, ret_comma);
                tags_str = str_sub(ret_str, ret_comma + 1, str_len(ret_str) - ret_comma - 1);
            } else {
                ret_type = ret_str;
                // trim whitespace
                trim_rt : ., mut = "";
                tri : ., mut = 0;
                loop { if tri >= str_len(ret_type) { break; }
                    tc := load8(ret_type, tri);
                    if tc != 32 { trim_rt = trim_rt + get_char(ret_type, tri); }
                    tri = tri + 1; }
                ret_type = trim_rt;
            }
        } else {
            params_str = rest;
        }

        // Split params_str and tags_str by comma
        // Params are before the first recognized tag name
        pi : ., mut = 0; pl := str_len(params_str);
        loop {
            if pi >= pl { break; }
            // Skip whitespace
            while pi < pl && load8(params_str, pi) == 32 { pi = pi + 1; }
            if pi >= pl { break; }
            // Find comma or end
            item_end : ., mut = pi;
            while item_end < pl && load8(params_str, item_end) != 44 { item_end = item_end + 1; }
            item := str_sub(params_str, pi, item_end - pi);
            // Trim whitespace
            while str_len(item) > 0 && load8(item, 0) == 32 { item = str_sub(item, 1, str_len(item)-1); }
            while str_len(item) > 0 && load8(item, str_len(item)-1) == 32 { item = str_sub(item, 0, str_len(item)-1); }

            if str_len(item) > 0 {
                if item == "variadic" { tag_flags = tag_flags + TAG_VARIADIC; }
                else if item == "auto_str" { tag_flags = tag_flags + TAG_AUTO_STR; }
                else {
                    // It's a param type name
                    if str_len(param_types) > 0 { param_types = param_types + ","; }
                    param_types = param_types + item;
                }
            }
            pi = item_end + 1;
        }

        // Same for tags_str
        ti : ., mut = 0; tl := str_len(tags_str);
        loop {
            if ti >= tl { break; }
            while ti < tl && load8(tags_str, ti) == 32 { ti = ti + 1; }
            if ti >= tl { break; }
            item_end2 : ., mut = ti;
            while item_end2 < tl && load8(tags_str, item_end2) != 44 { item_end2 = item_end2 + 1; }
            item2 := str_sub(tags_str, ti, item_end2 - ti);
            while str_len(item2) > 0 && load8(item2, 0) == 32 { item2 = str_sub(item2, 1, str_len(item2)-1); }
            while str_len(item2) > 0 && load8(item2, str_len(item2)-1) == 32 { item2 = str_sub(item2, 0, str_len(item2)-1); }
            if item2 == "variadic" { tag_flags = tag_flags + TAG_VARIADIC; }
            else if item2 == "auto_str" { tag_flags = tag_flags + TAG_AUTO_STR; }
            ti = item_end2 + 1;
        }

        // Build type encoding for sym_node: param_count + param_types (3 bits each) + ret_type (3 bits)
        param_count : ., mut = 0;
        param_type_bits : ., mut = 0;
        pti : ., mut = 0;
        loop {
            if pti >= str_len(param_types) { break; }
            // Skip to next param (comma-separated)
            pn_start : ., mut = pti;
            while pti < str_len(param_types) && load8(param_types, pti) != 44 { pti = pti + 1; }
            pname := str_sub(param_types, pn_start, pti - pn_start);
            while str_len(pname) > 0 && load8(pname, 0) == 32 { pname = str_sub(pname, 1, str_len(pname)-1); }
            while str_len(pname) > 0 && load8(pname, str_len(pname)-1) == 32 { pname = str_sub(pname, 0, str_len(pname)-1); }
            if str_len(pname) > 0 && param_count < 8 {
                // Encode type: int=0, string=1, float=2, bool=3, unit=4, other=5
                ptype_code : ., mut = 5;
                if pname == "int" { ptype_code = 0; }
                else if pname == "string" { ptype_code = 1; }
                else if pname == "unit" { ptype_code = 2; }
                else if pname == "float" { ptype_code = 3; }
                else if pname == "bool" { ptype_code = 4; }
                // Decimal encoding: packed positionally
                param_type_bits = param_type_bits * 100 + ptype_code;
                param_count = param_count + 1;
            }
            if pti < str_len(param_types) && load8(param_types, pti) == 44 { pti = pti + 1; }
        }

        // Encode return type
        ret_code : ., mut = 5;
        if ret_type == "int" { ret_code = 0; }
        else if ret_type == "string" { ret_code = 1; }
        else if ret_type == "unit" || str_eq(ret_type, "") != 0 { ret_code = 2; }
        else if ret_type == "float" { ret_code = 3; }
        else if ret_type == "bool" { ret_code = 4; }
        type_encoding : ., mut = param_count * 1000000000000 + param_type_bits * 100 + ret_code;

        // Register in symbol table
        fni := str_intern(func_name);
        // Manually set symbol entry
        si := g_sym_count;
        grow_syms(si + 1);
        sym_set_name(si, fni);
        sym_set_kind(si, SYM_SO_FN);
        sym_set_type(si, tag_flags);
        sym_set_node(si, type_encoding);
        g_sym_count = si + 1;
    }
}

fn res_imports() {
    g_file_count = 0; g_file_cap = 0;
    g_mod_count = 0; g_mod_cap = 0;
    g_seg_count = 0; g_seg_cap = 0;

    // Step 1: collect _import.cr from source directory and ancestors
    import_core_acc : ., mut = "";
    // Also collect stdlib _import.cr (provides import fmt for stdlib files)
    sic := load_imports("src/stdlib/");
    if str_len(sic) > 0 { import_core_acc = sic + "\n"; }
    search_dir : ., mut = g_source_dir;
    loop {
        ic := load_imports(search_dir);
        if str_len(ic) > 0 {
            import_core_acc = ic + "\n" + import_core_acc;
        }
        pd := parent_dir(search_dir);
        if str_len(pd) == 0 { break; }
        if str_eq(pd, search_dir) != 0 { break; }
        search_dir = pd;
    }
    if str_len(import_core_acc) > 0 {
        g_source = import_core_acc + "\n" + g_source;
        tokenize(g_source);
    }

    // Determine main file's fileid
    main_fileid_str : ., mut = get_fileid(g_source);
    if str_len(main_fileid_str) == 0 { main_fileid_str = "main"; }
    main_fni := reg_fileid(main_fileid_str, "");
    main_len := str_len(g_source);

    // First segment: main source
    grow_segs(g_seg_count + 1); w64(g_seg_starts, g_seg_count * 8, 0);
    w64(g_seg_fileids, g_seg_count * 8, main_fni);
    g_seg_count = g_seg_count + 1;

    extra_src : ., mut = "";
    extra_bytes : ., mut = 0;

    // Scan imports
    i : ., mut = 0;
    loop {
        if i >= g_token_count { break; }
        tk := r64(g_tokens, i * ESZ_TOKEN + OFF_TK_KIND);

        if tk == T_IMPORT {
            pos : ., mut = i + 1;
            is_project : ., mut = false;
            project_name : ., mut = "";
            if pos < g_token_count && r64(g_tokens, pos * ESZ_TOKEN + OFF_TK_KIND) == T_AT {
                is_project = true;
                pos = pos + 1;
                if pos < g_token_count && r64(g_tokens, pos * ESZ_TOKEN + OFF_TK_KIND) == T_IDENT {
                    project_name = istr_get(r64(g_tokens, pos * ESZ_TOKEN + OFF_TK_LEXEME));
                    pos = pos + 1;
                }
            }
            import_fileid : ., mut = "";
            if pos < g_token_count && r64(g_tokens, pos * ESZ_TOKEN + OFF_TK_KIND) == T_IDENT {
                import_fileid = istr_get(r64(g_tokens, pos * ESZ_TOKEN + OFF_TK_LEXEME));
                pos = pos + 1;
                // Handle :: segments: backend::x86_64 → backend::x86_64
                loop {
                    if pos + 1 < g_token_count &&
                       r64(g_tokens, pos * ESZ_TOKEN + OFF_TK_KIND) == T_PATHSEP &&
                       r64(g_tokens, (pos + 1) * ESZ_TOKEN + OFF_TK_KIND) == T_IDENT {
                        import_fileid = import_fileid + "::" + istr_get(r64(g_tokens, (pos + 1) * ESZ_TOKEN + OFF_TK_LEXEME));
                        pos = pos + 2;
                    } else { break; }
                }
            }
            alias_str : ., mut = "";
            if pos < g_token_count && r64(g_tokens, pos * ESZ_TOKEN + OFF_TK_KIND) == T_COLON {
                pos = pos + 1;
                if pos < g_token_count && r64(g_tokens, pos * ESZ_TOKEN + OFF_TK_KIND) == T_IDENT {
                    alias_str = istr_get(r64(g_tokens, pos * ESZ_TOKEN + OFF_TK_LEXEME));
                    pos = pos + 1;
                }
            }
            path : ., mut = "";
            content : ., mut = "";
            if str_len(import_fileid) > 0 {
                if is_project {
                    proj_toml : ., mut = "src/" + project_name + "/Core.toml";
                    ptc := read_file(proj_toml);
                    if str_len(ptc) > 0 {
                        pn := extract_toml_name(ptc);
                        if str_len(pn) > 0 && str_eq(pn, project_name) == 0 {
                            print("  warning: @");
                            print(project_name);
                            print(" toml name='");
                            print(pn);
                            println("' mismatch");
                        }
                    }
                    path = "src/" + project_name + "/" + import_fileid + ".cr";
                    content = read_file(path);
                } else {
                    // Convert :: to / for subdirectory paths (e.g. backend::x86_64::instr → backend/x86_64/instr)
                    fs_path : ., mut = import_fileid;
                    pi : ., mut = 0;
                    loop {
                        if pi >= str_len(fs_path) { break; }
                        if load8(fs_path, pi) == 58 && pi + 1 < str_len(fs_path) && load8(fs_path, pi+1) == 58 {
                            fs_path = str_sub(fs_path, 0, pi) + "/" + str_sub(fs_path, pi+2, str_len(fs_path)-pi-2);
                        }
                        pi = pi + 1;
                    }
                    // Try .so extension index: $HOME/.core/lib/<name>/index
                    // Loads metadata (tags). The .cr file still provides runtime implementation.
                    home_dir : ., mut = get_env("HOME");
                    if str_len(home_dir) == 0 { home_dir = "/home/DslsDZC"; }
                    so_idx_path : ., mut = home_dir + "/.core/lib/" + fs_path + "/index";
                    so_idx := read_file(so_idx_path);
                    if str_len(so_idx) > 0 {
                        reg_so_funcs(so_idx, fs_path);
                    }
                    // Always load .cr for runtime implementation
                    path = g_source_dir + fs_path + ".cr";
                    content = read_file(path);
                    if str_len(content) == 0 {
                        path = "src/stdlib/" + fs_path + ".cr";
                        content = read_file(path);
                    }
                    if str_len(content) == 0 {
                        path = fs_path + ".cr";
                        content = read_file(path);
                    }
                    if str_len(content) == 0 {
                        print("!! import fail: "); println(import_fileid);
                    }
                }
            }
            if str_len(content) > 0 {
                print("  -> "); println(path);
                content_len := str_len(content);
                loaded_fid : ., mut = get_fileid(content);
                if str_len(loaded_fid) == 0 { loaded_fid = import_fileid; }
                loaded_fni := reg_fileid(loaded_fid, path);
                seg_byte := main_len + extra_bytes + 1;
                grow_segs(g_seg_count + 1); w64(g_seg_starts, g_seg_count * 8, seg_byte);
                w64(g_seg_fileids, g_seg_count * 8, loaded_fni);
                g_seg_count = g_seg_count + 1;
                extra_bytes = extra_bytes + 1 + content_len;
                alias_ni : ., mut = -1;
                if str_len(alias_str) > 0 {
                    alias_ni = str_intern(alias_str);
                } else {
                    alias_ni = loaded_fni;
                }
                grow_mods(g_mod_count + 1);
                w64(g_mods, g_mod_count * 24, alias_ni);
                w64(g_mods, g_mod_count * 24 + 8, loaded_fni);
                store_str_ptr(g_mods, g_mod_count * 24 + 16, path);
                g_mod_count = g_mod_count + 1;
                extra_src = extra_src + "\n" + content;
            }
        }
        i = i + 1;
    }
    if str_len(extra_src) > 0 {
        g_source = g_source + extra_src;
        tokenize(g_source);
    }
    build_line_fileid();
}
