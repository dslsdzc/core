// === module.cr ===
// File system utilities, fileid management, and import resolution.

// LSP open documents. g_open_docs is a flat array of 24-byte records:
// {path pointer, source pointer, source length}. didOpen and didChange copy paths
// and source text to stable heap strings before registering. module_get_source
// checks open documents first and reads from disk only when absent, so rerunning
// the frontend in-process does not depend on disk.

fn grow_open_docs(needed: int):
    if needed < g_open_doc_cap:
        return
    ncap : ., mut = g_open_doc_cap * 2
    if ncap < 8:
        ncap = 8
    if ncap < needed:
        ncap = needed + 8
    nb := alloc(ncap * 24)
    cell_copy(g_open_docs, g_open_doc_cap * 24, nb)
    g_open_docs = nb
    g_open_doc_cap = ncap

fn module_open_doc_set(path: string, src: string):
    i : ., mut = 0
    loop:
        if i >= g_open_doc_count:
            break
        if str_eq(cell_load_str(g_open_docs, i * 24), path) != 0:
            cell_store_str(g_open_docs, i * 24 + 8, src)
            cell_store(g_open_docs, i * 24 + 16, str_len(src))
            return
        i = i + 1
    grow_open_docs(g_open_doc_count + 1)
    cell_store_str(g_open_docs, g_open_doc_count * 24, path)
    cell_store_str(g_open_docs, g_open_doc_count * 24 + 8, src)
    cell_store(g_open_docs, g_open_doc_count * 24 + 16, str_len(src))
    g_open_doc_count = g_open_doc_count + 1

fn module_open_doc_remove(path: string):
    i : ., mut = 0
    loop:
        if i >= g_open_doc_count:
            break
        if str_eq(cell_load_str(g_open_docs, i * 24), path) != 0:
            j : ., mut = i + 1
            loop:
                if j >= g_open_doc_count:
                    break
                cell_store_str(g_open_docs, (j - 1) * 24, cell_load_str(g_open_docs, j * 24))
                cell_store_str(g_open_docs, (j - 1) * 24 + 8, cell_load_str(g_open_docs, j * 24 + 8))
                cell_store(g_open_docs, (j - 1) * 24 + 16, cell_load(g_open_docs, j * 24 + 16))
                j = j + 1
            g_open_doc_count = g_open_doc_count - 1
            return
        i = i + 1

// Check open documents by exact path, then read from disk. Return "" when neither has the file.
fn module_get_source(path: string) -> string:
    i : ., mut = 0
    loop:
        if i >= g_open_doc_count:
            break
        if str_eq(cell_load_str(g_open_docs, i * 24), path) != 0:
            return cell_load_str(g_open_docs, i * 24 + 8)
        i = i + 1
    return read_file(path)

fn count_newlines(s: string) -> int:
    slen := str_len(s)
    n : ., mut = 0
    i : ., mut = 0
    loop:
        if i >= slen:
            break
        if str_eq(get_char(s, i), "\n") != 0:
            n = n + 1
        i = i + 1
    return n

fn get_fileid(s: string) -> string:
    slen := str_len(s)
    i : ., mut = 0
    loop:
        if i + 6 >= slen:
            return ""
        // Inline "fileid" check — int-based, no str_sub/str_eq
        if cell_load_byte(s, i) == 102 && cell_load_byte(s, i+1) == 105 && cell_load_byte(s, i+2) == 108 && cell_load_byte(s, i+3) == 101 && cell_load_byte(s, i+4) == 105 && cell_load_byte(s, i+5) == 100:
            j : ., mut = i + 6
            loop:
                if j >= slen:
                    return ""
                if cell_load_byte(s, j) == 34:
                    // '"'
                    start := j + 1
                    k : ., mut = start
                    loop:
                        if k >= slen:
                            return ""
                        if cell_load_byte(s, k) == 34:
                            // '"'
                            return str_sub(s, start, k - start)
                        k = k + 1
                j = j + 1
        i = i + 1
    return ""

fn dirname(path: string) -> string:
    slen := str_len(path)
    last_slash : ., mut = -1
    i : ., mut = 0
    loop:
        if i >= slen:
            break
        if str_eq(get_char(path, i), "/") != 0:
            last_slash = i
        i = i + 1
    if last_slash >= 0:
        return str_sub(path, 0, last_slash + 1)
    return ""

fn basename(path: string) -> string:
    slen := str_len(path)
    if slen == 0:
        return ""
    end : ., mut = slen
    // strip trailing /
    loop:
        if end <= 0:
            break
        if str_eq(get_char(path, end - 1), "/") != 0:
            end = end - 1
        else:
            break
    if end == 0:
        return "/"
    last_slash : ., mut = -1
    i : ., mut = 0
    loop:
        if i >= end:
            break
        if str_eq(get_char(path, i), "/") != 0:
            last_slash = i
        i = i + 1
    if last_slash >= 0:
        return str_sub(path, last_slash + 1, end - last_slash - 1)
    return str_sub(path, 0, end)

fn parent_dir(dir: string) -> string:
    slen := str_len(dir)
    if slen <= 1:
        return ""
    trimmed : ., mut = dir
    last_ch := get_char(dir, slen - 1)
    if str_eq(last_ch, "/") != 0:
        trimmed = str_sub(dir, 0, slen - 1)
    last_slash : ., mut = -1
    i : ., mut = 0
    tlen := str_len(trimmed)
    loop:
        if i >= tlen:
            break
        if str_eq(get_char(trimmed, i), "/") != 0:
            last_slash = i
        i = i + 1
    if last_slash >= 0:
        return str_sub(trimmed, 0, last_slash + 1)
    return ""

fn load_imports(dir_path: string) -> string:
    imp_path : ., mut = dir_path + "_import.cr"
    content : ., mut = module_get_source(imp_path)
    // Return the _import.cr content when present.
    if str_len(content) > 0:
    return content

fn reg_fileid(fileid_str: string, path: string) -> int:
    return reg_fileid_sm(fileid_str, path, -1)

fn reg_fileid_sm(fileid_str: string, path: string, sm_id: int) -> int:
    fni := str_intern(fileid_str)
    fi : ., mut = 0
    loop:
        if fi >= g_file_count:
            break
        if cell_load(g_files, fi * 24) == fni:
            if sm_id >= 0:
                cell_store(g_files, fi * 24 + 16, sm_id)
            return fni
        fi = fi + 1
    grow_files(g_file_count + 1)
    cell_store(g_files, g_file_count * 24, fni)
    cell_store_str(g_files, g_file_count * 24 + 8, path)
    cell_store(g_files, g_file_count * 24 + 16, sm_id)
    g_file_count = g_file_count + 1
    return fni

fn file_sm_id(fni: int) -> int:
    fi : ., mut = 0
    loop:
        if fi >= g_file_count:
            return -1
        if cell_load(g_files, fi * 24) == fni:
            return cell_load(g_files, fi * 24 + 16)
        fi = fi + 1
    return -1

fn build_line_fileid():
    // The flat line table is the SourceManager line space. Each file owns
    // [line_base, line_base + line_count); no concatenated text is scanned.
    g_line_count = 0
    g_line_cap = 0
    fi : ., mut = 0
    loop:
        if fi >= g_file_count:
            break
        fni := cell_load(g_files, fi * 24)
        sm := cell_load(g_files, fi * 24 + 16)
        if sm >= 0 && sm < sm_file_count():
            base := sm_file_line_base(sm)
            cnt := sm_file_line_count(sm)
            lib_id := sm_file_lib(sm)
            // Manifest lines sit between registered files and have no fileid.
            // Fill those rows explicitly so a stale cell cannot name a real file.
            loop:
                if g_line_count >= base:
                    break
                grow_line_file(g_line_count + 1)
                cell_store(g_line_fileid, g_line_count * 8, -1)
                cell_store(g_line_lib, g_line_count * 8, sm_file_lib(sm_for_line(g_line_count + 1)))
                g_line_count = g_line_count + 1
            l : ., mut = 0
            loop:
                if l >= cnt:
                    break
                grow_line_file(base + l + 1)
                cell_store(g_line_fileid, (base + l) * 8, fni)
                cell_store(g_line_lib, (base + l) * 8, lib_id)
                if base + l + 1 > g_line_count:
                    g_line_count = base + l + 1
                l = l + 1
        fi = fi + 1

fn reg_so_funcs(index_content: string, so_name: string):
    sl := str_len(index_content)
    line_start : ., mut = 0
    loop:
        if line_start >= sl:
            break
        // Find end of line
        line_end : ., mut = line_start
        loop:
            if line_end >= sl:
                break
            c := cell_load_byte(index_content, line_end)
            if c == 10:
                break
            // \n
            line_end = line_end + 1
        line := str_sub(index_content, line_start, line_end - line_start)
        line_start = line_end + 1

        // Skip empty lines and comments
        if str_len(line) == 0:
            continue
        c0 := cell_load_byte(line, 0)
        if c0 == 35 || c0 == 10 || c0 == 13:
            continue
        // #, \n, \r

        // Parse: func_name: rest
        colon_pos : ., mut = -1
        ci : ., mut = 0
        loop:
            if ci >= str_len(line):
                break
            if cell_load_byte(line, ci) == 58:
                colon_pos = ci
                break
            // :
            ci = ci + 1
        if colon_pos < 0:
            continue
        func_name := str_sub(line, 0, colon_pos)
        rest := str_sub(line, colon_pos + 1, str_len(line) - colon_pos - 1)
        if str_len(func_name) == 0:
            continue

        // Parse rest into params and tags (comma-separated)
        param_types : ., mut = ""
        ret_type : ., mut = "unit"
        tag_flags : ., mut = 0

        // Split rest by -> to get ret type
        arrow_pos : ., mut = -1
        ai : ., mut = 0
        rl := str_len(rest)
        loop:
            if ai + 2 > rl:
                break
            if cell_load_byte(rest, ai) == 45 && ai + 1 < rl && cell_load_byte(rest, ai+1) == 62:
                // ->
                arrow_pos = ai
                break
            ai = ai + 1

        params_str : ., mut = ""
        tags_str : ., mut = ""
        if arrow_pos >= 0:
            params_str = str_sub(rest, 0, arrow_pos)
            ret_str := str_sub(rest, arrow_pos + 2, rl - arrow_pos - 2)
            // ret_str might have tags too after comma
            ret_comma : ., mut = -1
            rci : ., mut = 0
            loop:
                if rci >= str_len(ret_str):
                    break
                if cell_load_byte(ret_str, rci) == 44:
                    ret_comma = rci
                    break
                rci = rci + 1
            if ret_comma >= 0:
                ret_type = str_sub(ret_str, 0, ret_comma)
                tags_str = str_sub(ret_str, ret_comma + 1, str_len(ret_str) - ret_comma - 1)
            else:
                ret_type = ret_str
                // trim whitespace
                trim_rt : ., mut = ""
                tri : ., mut = 0
                loop:
                    if tri >= str_len(ret_type):
                        break
                    tc := cell_load_byte(ret_type, tri)
                    if tc != 32:
                        trim_rt = trim_rt + get_char(ret_type, tri)
                    tri = tri + 1
                ret_type = trim_rt
        else:
            params_str = rest

        // Split params_str and tags_str by comma
        // Params are before the first recognized tag name
        pi : ., mut = 0
        pl := str_len(params_str)
        loop:
            if pi >= pl:
                break
            // Skip whitespace
            while pi < pl && cell_load_byte(params_str, pi) == 32:
                pi = pi + 1
            if pi >= pl:
                break
            // Find comma or end
            item_end : ., mut = pi
            while item_end < pl && cell_load_byte(params_str, item_end) != 44:
                item_end = item_end + 1
            item : ., mut = str_sub(params_str, pi, item_end - pi)
            // Trim whitespace
            while str_len(item) > 0 && cell_load_byte(item, 0) == 32:
                item = str_sub(item, 1, str_len(item)-1)
            while str_len(item) > 0 && cell_load_byte(item, str_len(item)-1) == 32:
                item = str_sub(item, 0, str_len(item)-1)

            if str_len(item) > 0:
                if item == "variadic":
                    tag_flags = tag_flags + TAG_VARIADIC
                else if item == "auto_str":
                    tag_flags = tag_flags + TAG_AUTO_STR
                else:
                    // It's a param type name
                    if str_len(param_types) > 0:
                        param_types = param_types + ","
                    param_types = param_types + item
            pi = item_end + 1

        // Same for tags_str
        ti : ., mut = 0
        tl := str_len(tags_str)
        loop:
            if ti >= tl:
                break
            while ti < tl && cell_load_byte(tags_str, ti) == 32:
                ti = ti + 1
            if ti >= tl:
                break
            item_end2 : ., mut = ti
            while item_end2 < tl && cell_load_byte(tags_str, item_end2) != 44:
                item_end2 = item_end2 + 1
            item2 : ., mut = str_sub(tags_str, ti, item_end2 - ti)
            while str_len(item2) > 0 && cell_load_byte(item2, 0) == 32:
                item2 = str_sub(item2, 1, str_len(item2)-1)
            while str_len(item2) > 0 && cell_load_byte(item2, str_len(item2)-1) == 32:
                item2 = str_sub(item2, 0, str_len(item2)-1)
            if item2 == "variadic":
                tag_flags = tag_flags + TAG_VARIADIC
            else if item2 == "auto_str":
                tag_flags = tag_flags + TAG_AUTO_STR
            ti = item_end2 + 1

        // Build type encoding for sym_node: param_count + param_types (3 bits each) + ret_type (3 bits)
        param_count : ., mut = 0
        param_type_bits : ., mut = 0
        pti : ., mut = 0
        loop:
            if pti >= str_len(param_types):
                break
            // Skip to next param (comma-separated)
            pn_start : ., mut = pti
            while pti < str_len(param_types) && cell_load_byte(param_types, pti) != 44:
                pti = pti + 1
            pname : ., mut = str_sub(param_types, pn_start, pti - pn_start)
            while str_len(pname) > 0 && cell_load_byte(pname, 0) == 32:
                pname = str_sub(pname, 1, str_len(pname)-1)
            while str_len(pname) > 0 && cell_load_byte(pname, str_len(pname)-1) == 32:
                pname = str_sub(pname, 0, str_len(pname)-1)
            if str_len(pname) > 0 && param_count < 8:
                // Encode type: int=0, string=1, unit=2, dex=3（binary64 跨 C 边界 = apx 授权）, bool=4, other=5
                ptype_code : ., mut = 5
                if pname == "int":
                    ptype_code = 0
                else if pname == "string":
                    ptype_code = 1
                else if pname == "unit":
                    ptype_code = 2
                else if pname == "dex":
                    ptype_code = 3
                else if pname == "bool":
                    ptype_code = 4
                // Decimal encoding: packed positionally
                param_type_bits = param_type_bits * 100 + ptype_code
                param_count = param_count + 1
            if pti < str_len(param_types) && cell_load_byte(param_types, pti) == 44:
                pti = pti + 1

        // Encode return type
        ret_code : ., mut = 5
        if ret_type == "int":
            ret_code = 0
        else if ret_type == "string":
            ret_code = 1
        else if ret_type == "unit" || str_eq(ret_type, "") != 0:
            ret_code = 2
        else if ret_type == "dex":
            ret_code = 3
        else if ret_type == "bool":
            ret_code = 4
        type_encoding : ., mut = param_count * 1000000000000 + param_type_bits * 100 + ret_code

        // Record the function in the side table. Do not add it to the string or
        // symbol table yet: import resolution runs before the checker knows
        // whether the program references the name. Interning it now would add host
        // home-directory metadata to output even for an unused function and shift
        // later string and symbol indexes.
        // Referenced names are materialized by so_materialize on first lookup, so
        // names that exist only in the index still work. The side table grows
        // dynamically, so no fixed 128-entry buffer is needed.
        ssi : ., mut = g_so_side_count
        grow_so_side(ssi + 1)
        cell_store_str(g_so_side_name, ssi * 8, func_name)
        cell_store(g_so_side_tags, ssi * 8, tag_flags)
        cell_store(g_so_side_type, ssi * 8, type_encoding)
        g_so_side_count = ssi + 1

// Look up a side-table entry by name and return its index, or -1. Names are
// stored before interning, so compare strings. This runs only when the main
// symbol table misses.
fn find_so_side(name_idx: int) -> int:
    i : ., mut = 0
    loop:
        if i >= g_so_side_count:
            return -1
        if str_eq(istr_get(name_idx), cell_load_str(g_so_side_name, i * 8)) != 0:
            return i
        i = i + 1
    return -1

// Materialize a side-table entry into the symbol table on first lookup and return
// the new symbol index. Call only when the main table has no entry for the name;
// otherwise an index file in the user's home directory could override a
// declaration in user source.
fn so_materialize(side_i: int) -> int:
    fni := str_intern(cell_load_str(g_so_side_name, side_i * 8))
    si := g_sym_count
    grow_syms(si + 1)
    sym_set_name(si, fni)
    sym_set_kind(si, SYM_SO_FN)
    sym_set_type(si, cell_load(g_so_side_tags, side_i * 8))
    sym_set_node(si, cell_load(g_so_side_type, side_i * 8))
    // External packages are imported by the entry unit; their public symbols
    // belong to that unit's library, not to the global namespace.
    sym_set_owner(si, lib_lookup_path(g_source_name))
    sym_set_pub(si, 1)
    g_sym_count = si + 1
    return si

fn import_push(sm_id: int):
    grow_import_sms(g_import_count + 1)
    cell_store(g_import_sm, g_import_count * 8, sm_id)
    g_import_count = g_import_count + 1

fn import_known_fid(fni: int) -> int:
    i : ., mut = 0
    loop:
        if i >= g_mod_count:
            return 0
        if cell_load(g_mods, i * 24 + 8) == fni:
            return 1
        i = i + 1
    return 0

fn import_add(path: string, fid_str: string, content: string, alias_str: string) -> int:
    fni := str_intern(fid_str)
    if fni == g_main_fni:
        return -1
    if import_known_fid(fni) != 0:
        return -1
    sm := sm_add_file(path, content)
    reg_fileid_sm(fid_str, path, sm)
    alias_ni : ., mut = fni
    if str_len(alias_str) > 0:
        alias_ni = str_intern(alias_str)
    grow_mods(g_mod_count + 1)
    cell_store(g_mods, g_mod_count * 24, alias_ni)
    cell_store(g_mods, g_mod_count * 24 + 8, fni)
    cell_store_str(g_mods, g_mod_count * 24 + 16, path)
    g_mod_count = g_mod_count + 1
    import_push(sm)
    return sm

// Scan the token stream most recently produced by tokenize() for import edges.
// Resolution paths keep the historical base (main source dir + target roots).
fn import_scan_tokens():
    i : ., mut = 0
    loop:
        if i >= g_token_count:
            break
        tk := cell_load(g_tokens, i * ESZ_TOKEN + OFF_TK_KIND)
        if tk == T_IMPORT:
            pos : ., mut = i + 1
            is_project : ., mut = 0
            project_name : ., mut = ""
            if pos < g_token_count && cell_load(g_tokens, pos * ESZ_TOKEN + OFF_TK_KIND) == T_AT:
                is_project = 1
                pos = pos + 1
                if pos < g_token_count && cell_load(g_tokens, pos * ESZ_TOKEN + OFF_TK_KIND) == T_IDENT:
                    project_name = istr_get(cell_load(g_tokens, pos * ESZ_TOKEN + OFF_TK_LEXEME))
                    pos = pos + 1
            import_fileid : ., mut = ""
            if pos < g_token_count && cell_load(g_tokens, pos * ESZ_TOKEN + OFF_TK_KIND) == T_IDENT:
                import_fileid = istr_get(cell_load(g_tokens, pos * ESZ_TOKEN + OFF_TK_LEXEME))
                pos = pos + 1
                loop:
                    if pos + 1 < g_token_count && cell_load(g_tokens, pos * ESZ_TOKEN + OFF_TK_KIND) == T_PATHSEP && cell_load(g_tokens, (pos + 1) * ESZ_TOKEN + OFF_TK_KIND) == T_IDENT:
                        import_fileid = import_fileid + "::" + istr_get(cell_load(g_tokens, (pos + 1) * ESZ_TOKEN + OFF_TK_LEXEME))
                        pos = pos + 2
                    else:
                        break
            alias_str : ., mut = ""
            if pos < g_token_count && cell_load(g_tokens, pos * ESZ_TOKEN + OFF_TK_KIND) == T_COLON_DECL:
                pos = pos + 1
                if pos < g_token_count && cell_load(g_tokens, pos * ESZ_TOKEN + OFF_TK_KIND) == T_IDENT:
                    alias_str = istr_get(cell_load(g_tokens, pos * ESZ_TOKEN + OFF_TK_LEXEME))
                    pos = pos + 1
            path : ., mut = ""
            content : ., mut = ""
            if str_len(import_fileid) > 0 && str_eq(import_fileid, istr_get(g_main_fni)) != 0:
                i = pos
                continue
            if str_len(import_fileid) > 0:
                if is_project != 0:
                    proj_toml : ., mut = "src/" + project_name + "/Core.toml"
                    ptc := read_file(proj_toml)
                    if str_len(ptc) > 0:
                        pn := extract_toml_name(ptc)
                        if str_len(pn) > 0 && str_eq(pn, project_name) == 0:
                            if g_silent_stdout == 0:
                                print("  warning: @")
                                print(project_name)
                                print(" toml name='")
                                print(pn)
                                println("' mismatch")
                    path = "src/" + project_name + "/" + import_fileid + ".cr"
                    content = module_get_source(path)
                else:
                    fs_path : ., mut = import_fileid
                    pi : ., mut = 0
                    loop:
                        if pi >= str_len(fs_path):
                            break
                        if cell_load_byte(fs_path, pi) == 58 && pi + 1 < str_len(fs_path) && cell_load_byte(fs_path, pi+1) == 58:
                            fs_path = str_sub(fs_path, 0, pi) + "/" + str_sub(fs_path, pi+2, str_len(fs_path)-pi-2)
                        pi = pi + 1
                    home_dir : ., mut = get_env("HOME")
                    if str_len(home_dir) > 0:
                        so_idx_path : ., mut = target_so_index_path(home_dir, fs_path)
                        so_idx := read_file(so_idx_path)
                        if str_len(so_idx) > 0:
                            reg_so_funcs(so_idx, fs_path)
                    path = g_source_dir + fs_path + ".cr"
                    content = module_get_source(path)
                    ri : ., mut = 0
                    loop:
                        if str_len(content) > 0:
                            break
                        if ri >= target_import_root_count():
                            break
                        root := target_import_root(ri)
                        if str_len(root) > 0:
                            path = root + fs_path + ".cr"
                            content = module_get_source(path)
                        ri = ri + 1
                    if str_len(content) == 0:
                        path = fs_path + ".cr"
                        content = module_get_source(path)
                    if str_len(content) == 0:
                        if g_silent_stdout == 0:
                            print("!! import fail: ")
                            println(import_fileid)
                if str_len(content) > 0:
                    // The entry file is identified by its path, not by an
                    // interned fileid: a file without a `fileid` declaration
                    // falls back to the import lexeme, so a cycle back to the
                    // entry would otherwise load a second copy of main.
                    if str_len(g_source_name) > 0 && str_eq(path, g_source_name) != 0:
                        add_error("import cycle: '" + import_fileid + "' resolves to the entry file")
                        content = ""
                if str_len(content) > 0:
                    // Dependency direction is a property of the import edge, not
                    // only of symbol lookup: reject the load itself so a library
                    // cannot pull in code from a layer it may not depend on.
                    from_lib := sm_file_lib(g_source_file)
                    to_lib := lib_for_path(path)
                    if lib_can_import(from_lib, to_lib) == 0:
                        add_error("cannot import '" + import_fileid + "' (" + lib_name(from_lib) + " -> " + lib_name(to_lib) + "): library dependency direction")
                        content = ""
                if str_len(content) > 0:
                    loaded_fid : ., mut = get_fileid(content)
                    if str_len(loaded_fid) == 0:
                        loaded_fid = import_fileid
                    if import_known_fid(str_intern(loaded_fid)) == 0:
                        if g_silent_stdout == 0:
                            print("  -> ")
                            println(path)
                        import_add(path, loaded_fid, content, alias_str)
            i = pos
            continue
        i = i + 1

fn import_scan_text(path: string, text: string):
    // Manifests occupy SourceManager lines only. They never enter g_import_sm,
    // so they are never parsed as declarations, and they get no g_files row
    // because fileids are program-visible identifiers. Diagnostics fall back to
    // SourceManager line ranges when a line has no fileid (sm_for_line).
    sm := sm_add_virtual(path, text)
    tokenize(sm, 0)
    import_scan_tokens()

// Walk ancestors root-first so the resulting import order matches the old
// prepended manifest order (outermost ancestor, ..., source dir, stdlib).
fn import_scan_ancestors(dir: string):
    pd := parent_dir(dir)
    if str_len(pd) > 0 && str_eq(pd, dir) == 0:
        import_scan_ancestors(pd)
    ic := load_imports(dir)
    if str_len(ic) > 0:
        import_scan_text(dir + "_import.cr", ic)

fn res_imports():
    lib_export_reset()
    g_mod_count = 0
    g_mod_cap = 0
    g_import_count = 0
    g_import_cap = 0
    g_file_count = 0
    g_file_cap = 0
    g_line_count = 0

    // Main file was registered by the caller as SourceManager file 0.
    g_main_sm = 0
    main_fid : ., mut = get_fileid(g_source)
    if str_len(main_fid) == 0:
        main_fid = "main"
    g_main_fni = reg_fileid_sm(main_fid, g_source_path, g_main_sm)
    import_push(g_main_sm)

    // Manifests contribute import edges only; they are never parsed as code.
    import_scan_ancestors(g_source_dir)
    sic := load_imports("src/stdlib/")
    if str_len(sic) > 0:
        import_scan_text("src/stdlib/_import.cr", sic)

    // Main file edges first after the manifests, then the recursive BFS.
    tokenize(g_main_sm, 0)
    import_scan_tokens()
    idx : ., mut = 1
    loop:
        if idx >= g_import_count:
            break
        sm := cell_load(g_import_sm, idx * 8)
        tokenize(sm, 0)
        import_scan_tokens()
        idx = idx + 1

    g_source = sm_file_text(g_main_sm)
    g_source_len = str_len(g_source)
    g_source_file = g_main_sm
    g_line_base = sm_file_line_base(g_main_sm)
    build_line_fileid()
