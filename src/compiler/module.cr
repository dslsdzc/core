// === module.cr ===
// File system utilities, fileid management, and import resolution.

fn count_newlines(s: string) -> int {
    slen := __builtin_str_len(s);
    n : ., mut = 0;
    i : ., mut = 0;
    loop {
        if i >= slen { break; }
        if __builtin_str_eq(__builtin_str_get(s, i), "\n") != 0 { n = n + 1; }
        i = i + 1;
    }
    return n;
}

fn extract_fileid(s: string) -> string {
    slen := __builtin_str_len(s);
    i : ., mut = 0;
    loop {
        if i + 6 >= slen { return ""; }
        sub := __builtin_str_sub(s, i, 6);
        if __builtin_str_eq(sub, "fileid") != 0 {
            j : ., mut = i + 6;
            loop {
                if j >= slen { return ""; }
                if __builtin_str_eq(__builtin_str_get(s, j), "\"") != 0 {
                    start := j + 1;
                    k : ., mut = start;
                    loop {
                        if k >= slen { return ""; }
                        if __builtin_str_eq(__builtin_str_get(s, k), "\"") != 0 {
                            return __builtin_str_sub(s, start, k - start);
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
    slen := __builtin_str_len(path);
    last_slash : ., mut = -1;
    i : ., mut = 0;
    loop {
        if i >= slen { break; }
        if __builtin_str_eq(__builtin_str_get(path, i), "/") != 0 { last_slash = i; }
        i = i + 1;
    }
    if last_slash >= 0 {
        return __builtin_str_sub(path, 0, last_slash + 1);
    }
    return "";
}

fn parent_dir(dir: string) -> string {
    slen := __builtin_str_len(dir);
    if slen <= 1 { return ""; }
    trimmed : ., mut = dir;
    last_ch := __builtin_str_get(dir, slen - 1);
    if __builtin_str_eq(last_ch, "/") != 0 {
        trimmed = __builtin_str_sub(dir, 0, slen - 1);
    }
    last_slash : ., mut = -1;
    i : ., mut = 0;
    tlen := __builtin_str_len(trimmed);
    loop {
        if i >= tlen { break; }
        if __builtin_str_eq(__builtin_str_get(trimmed, i), "/") != 0 { last_slash = i; }
        i = i + 1;
    }
    if last_slash >= 0 {
        return __builtin_str_sub(trimmed, 0, last_slash + 1);
    }
    return "";
}

fn load_import_core(dir_path: string) -> string {
    imp_path : ., mut = dir_path + "_import.cr";
    content := __builtin_read_file(imp_path);
    if __builtin_str_len(content) > 0 {
    }
    return content;
}

fn register_fileid(fileid_str: string, path: string) -> int {
    fni := str_intern(fileid_str);
    fi : ., mut = 0;
    loop {
        if fi >= g_file_count { break; }
        if g_files[fi].fileid_ni == fni {
            return fni;
        }
        fi = fi + 1;
    }
    if g_file_count < MAX_FILES {
        g_files[g_file_count] = FileEntry { fileid_ni = fni, path = path };
        g_file_count = g_file_count + 1;
    }
    return fni;
}

fn build_line_fileid() {
    g_line_count = 0;
    slen := __builtin_str_len(g_source);
    seg_idx : ., mut = 0;
    g_line_fileid[g_line_count] = g_seg_fileids[0];
    g_line_count = g_line_count + 1;
    pos : ., mut = 0;
    loop {
        if pos >= slen { break; }
        if __builtin_str_eq(__builtin_str_get(g_source, pos), "\n") != 0 {
            next_start := 0;
            next_fileid := -1;
            if seg_idx + 1 < g_seg_count {
                next_start = g_seg_starts[seg_idx + 1];
                next_fileid = g_seg_fileids[seg_idx + 1];
            }
            if next_fileid >= 0 && pos + 1 >= next_start {
                seg_idx = seg_idx + 1;
            }
            g_line_fileid[g_line_count] = g_seg_fileids[seg_idx];
            g_line_count = g_line_count + 1;
        }
        pos = pos + 1;
    }
}

fn resolve_imports() {
    g_file_count = 0;
    g_mod_count = 0;
    g_seg_count = 0;

    // Step 1: collect _import.cr from source directory and ancestors
    import_core_acc : ., mut = "";
    search_dir : ., mut = g_source_dir;
    loop {
        ic := load_import_core(search_dir);
        if __builtin_str_len(ic) > 0 {
            import_core_acc = ic + "\n" + import_core_acc;
        }
        pd := parent_dir(search_dir);
        if __builtin_str_len(pd) == 0 { break; }
        if __builtin_str_eq(pd, search_dir) != 0 { break; }
        search_dir = pd;
    }
    if __builtin_str_len(import_core_acc) > 0 {
        g_source = import_core_acc + "\n" + g_source;
        tokenize();
    }

    // Determine main file's fileid
    main_fileid_str : ., mut = extract_fileid(g_source);
    if __builtin_str_len(main_fileid_str) == 0 { main_fileid_str = "main"; }
    main_fni := register_fileid(main_fileid_str, "");
    main_len := __builtin_str_len(g_source);

    // First segment: main source
    g_seg_starts[g_seg_count] = 0;
    g_seg_fileids[g_seg_count] = main_fni;
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
                    project_name = str_get(r64(g_tokens, pos * ESZ_TOKEN + OFF_TK_LEXEME));
                    pos = pos + 1;
                }
            }
            import_fileid : ., mut = "";
            if pos < g_token_count && r64(g_tokens, pos * ESZ_TOKEN + OFF_TK_KIND) == T_IDENT {
                import_fileid = str_get(r64(g_tokens, pos * ESZ_TOKEN + OFF_TK_LEXEME));
                pos = pos + 1;
            }
            alias_str : ., mut = "";
            if pos < g_token_count && r64(g_tokens, pos * ESZ_TOKEN + OFF_TK_KIND) == T_COLON {
                pos = pos + 1;
                if pos < g_token_count && r64(g_tokens, pos * ESZ_TOKEN + OFF_TK_KIND) == T_IDENT {
                    alias_str = str_get(r64(g_tokens, pos * ESZ_TOKEN + OFF_TK_LEXEME));
                    pos = pos + 1;
                }
            }
            path : ., mut = "";
            content : ., mut = "";
            if __builtin_str_len(import_fileid) > 0 {
                if is_project {
                    proj_toml : ., mut = "src/" + project_name + "/Core.toml";
                    ptc := __builtin_read_file(proj_toml);
                    if __builtin_str_len(ptc) > 0 {
                        pn := extract_toml_name(ptc);
                        if __builtin_str_len(pn) > 0 && __builtin_str_eq(pn, project_name) == 0 {
                            __builtin_print("  warning: @");
                            __builtin_print(project_name);
                            __builtin_print(" toml name='");
                            __builtin_print(pn);
                            __builtin_println("' mismatch");
                        }
                    }
                    path = "src/" + project_name + "/" + import_fileid + ".cr";
                    content = __builtin_read_file(path);
                } else {
                    path = g_source_dir + import_fileid + ".cr";
                    content = __builtin_read_file(path);
                    if __builtin_str_len(content) == 0 {
                        path = "src/stdlib/" + import_fileid + ".cr";
                        content = __builtin_read_file(path);
                    }
                    if __builtin_str_len(content) == 0 {
                        path = import_fileid + ".cr";
                        content = __builtin_read_file(path);
                    }
                }
            }
            if __builtin_str_len(content) > 0 {
                content_len := __builtin_str_len(content);
                loaded_fid : ., mut = extract_fileid(content);
                if __builtin_str_len(loaded_fid) == 0 { loaded_fid = import_fileid; }
                loaded_fni := register_fileid(loaded_fid, path);
                seg_byte := main_len + extra_bytes + 1;
                g_seg_starts[g_seg_count] = seg_byte;
                g_seg_fileids[g_seg_count] = loaded_fni;
                g_seg_count = g_seg_count + 1;
                extra_bytes = extra_bytes + 1 + content_len;
                alias_ni : ., mut = -1;
                if __builtin_str_len(alias_str) > 0 {
                    alias_ni = str_intern(alias_str);
                } else {
                    alias_ni = loaded_fni;
                }
                if g_mod_count < MAX_MODS {
                    g_mods[g_mod_count] = ModEntry { alias_ni = alias_ni, fileid_ni = loaded_fni, path = path };
                    g_mod_count = g_mod_count + 1;
                }
                extra_src = extra_src + "\n" + content;
            }
        }
        i = i + 1;
    }
    if __builtin_str_len(extra_src) > 0 {
        g_source = g_source + extra_src;
        tokenize();
    }
    build_line_fileid();
}
