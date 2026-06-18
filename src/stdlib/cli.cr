// === cli.cr ===
// Command-line argument parsing standard library.
//
// Usage:
//   cli_init("corec", "Core compiler");
//   cli_cmd("build", "Compile .cr to binary");
//   cli_cmd("cir",    "Output dataflow graph");
//   cli_flag("output", "o", "Output binary path");
//   cli_flag_bool("verbose", "v", "Verbose output");
//   if cli_parse() != 0 { return 1; }
//   cmd := cli_cmd_name();
//   if cli_eq(cmd, "build") {
//       src := cli_arg(0);
//       out := cli_get("output");
//   }
//
// Limits (flat-array compatible):
//   MAX_CLI_CMDS  = 16
//   MAX_CLI_FLAGS = 32
//   MAX_CLI_ARGS  = 32

// --- Limits ---
CLI_LONG_NAME_SIZE : int = 32;

// --- Internal structs ---
struct CliCmd {
    name: string,
    desc: string,
}

struct CliFlag {
    long_name: string,
    short_name: string,
    desc: string,
    value: string,
    has_value: int,
    is_bool: int,
}

// --- Global state ---
g_cli_prog : string, mut;
g_cli_desc : string, mut;
g_cli_cmds : string, mut;             g_cli_cmd_count : int, mut;     g_cli_cmd_cap : int, mut;
g_cli_flags : string, mut;            g_cli_flag_count : int, mut;    g_cli_flag_cap : int, mut;
g_cli_args : string, mut;             g_cli_arg_count : int, mut;    g_cli_arg_cap : int, mut;

fn dyn_grow_cli_cmds(needed: int) {
    if needed < g_cli_cmd_cap { return; }
    nc : ., mut = g_cli_cmd_cap * 2; if nc < 8 { nc = 8; } if nc < needed { nc = needed + 8; }
    nb := alloc(nc * 16); _dyncpy(g_cli_cmds, g_cli_cmd_cap * 16, nb); g_cli_cmds = nb; g_cli_cmd_cap = nc; }
fn dyn_grow_cli_flags(needed: int) {
    if needed < g_cli_flag_cap { return; }
    nc : ., mut = g_cli_flag_cap * 2; if nc < 8 { nc = 8; } if nc < needed { nc = needed + 8; }
    nb := alloc(nc * 48); _dyncpy(g_cli_flags, g_cli_flag_cap * 48, nb); g_cli_flags = nb; g_cli_flag_cap = nc; }
fn dyn_grow_cli_args(needed: int) {
    if needed < g_cli_arg_cap { return; }
    nc : ., mut = g_cli_arg_cap * 2; if nc < 8 { nc = 8; } if nc < needed { nc = needed + 8; }
    nb := alloc(nc * 8); _dyncpy(g_cli_args, g_cli_arg_cap * 8, nb); g_cli_args = nb; g_cli_arg_cap = nc; }
g_cli_matched_cmd : string, mut;

// --- Init ---

fn cli_init(prog: string, desc: string) {
    g_cli_prog = prog;
    g_cli_desc = desc;
    g_cli_cmd_count = 0; g_cli_cmd_cap = 0;
    g_cli_flag_count = 0; g_cli_flag_cap = 0;
    g_cli_arg_count = 0; g_cli_arg_cap = 0;
    g_cli_matched_cmd = "";
}

// --- Registration ---

fn cli_cmd(name: string, desc: string) {
    dyn_grow_cli_cmds(g_cli_cmd_count + 1);
    w64(g_cli_cmds, g_cli_cmd_count * 16, name);
    w64(g_cli_cmds, g_cli_cmd_count * 16 + 8, desc);
    g_cli_cmd_count = g_cli_cmd_count + 1;
}

fn cli_flag(long_name: string, short_name: string, desc: string) {
    dyn_grow_cli_flags(g_cli_flag_count + 1);
    w64(g_cli_flags, g_cli_flag_count * 48, long_name);
    w64(g_cli_flags, g_cli_flag_count * 48 + 8, short_name);
    w64(g_cli_flags, g_cli_flag_count * 48 + 16, desc);
    w64(g_cli_flags, g_cli_flag_count * 48 + 24, "");       // value
    w64(g_cli_flags, g_cli_flag_count * 48 + 32, 0);         // has_value
    w64(g_cli_flags, g_cli_flag_count * 48 + 40, 0);         // is_bool
    g_cli_flag_count = g_cli_flag_count + 1;
}

fn cli_flag_bool(long_name: string, short_name: string, desc: string) {
    dyn_grow_cli_flags(g_cli_flag_count + 1);
    w64(g_cli_flags, g_cli_flag_count * 48, long_name);
    w64(g_cli_flags, g_cli_flag_count * 48 + 8, short_name);
    w64(g_cli_flags, g_cli_flag_count * 48 + 16, desc);
    w64(g_cli_flags, g_cli_flag_count * 48 + 24, "");       // value
    w64(g_cli_flags, g_cli_flag_count * 48 + 32, 0);         // has_value
    w64(g_cli_flags, g_cli_flag_count * 48 + 40, 1);         // is_bool
    g_cli_flag_count = g_cli_flag_count + 1;
}

// --- Internal helpers ---

fn _cli_find_flag(name: string) -> int {
    i : ., mut = 0;
    loop {
        if i >= g_cli_flag_count { break; }
        ln := r64(g_cli_flags, i * 48);
        sn := r64(g_cli_flags, i * 48 + 8);
        if str_len(ln) > 0 && str_eq(ln, name) != 0 { return i; }
        if str_len(sn) > 0 && str_eq(sn, name) != 0 { return i; }
        i = i + 1;
    }
    return -1;
}

fn _cli_is_flag(arg: string) -> int {
    slen := str_len(arg);
    if slen < 2 { return 0; }
    c0 := get_char(arg, 0);
    if str_eq(c0, "-") != 0 { return 1; }
    return 0;
}

fn _cli_strip_dashes(arg: string) -> string {
    slen := str_len(arg);
    if slen == 0 { return ""; }
    start : ., mut = 0;
    if get_char(arg, 0) == "-" {
        start = 1;
        if slen > 1 && get_char(arg, 1) == "-" {
            start = 2;
        }
    }
    return str_sub(arg, start, slen - start);
}

// --- Parse ---

fn cli_parse() -> int {
    argc := get_arg(0);
    argc_int : ., mut = 0;
    // Count args by scanning until we get empty string
    loop {
        a := get_arg(argc_int);
        if str_len(a) == 0 { break; }
        argc_int = argc_int + 1;
    }
    if argc_int < 2 { return 0; }  // no subcommand

    // Determine subcommand from argv[1]
    first := get_arg(1);
    if _cli_is_flag(first) == 0 && g_cli_cmd_count > 0 {
        // First non-flag arg — check if it's a valid subcommand
        ci : ., mut = 0;
        found_cmd : ., mut = 0;
        loop {
            if ci >= g_cli_cmd_count { break; }
            if str_eq(r64(g_cli_cmds, ci * 16), first) != 0 {
                found_cmd = 1;
                break;
            }
            ci = ci + 1;
        }
        if found_cmd != 0 {
            g_cli_matched_cmd = first;
        } else {
            // Not a command, treat as positional arg
            g_cli_matched_cmd = "";
        }
    } else {
        g_cli_matched_cmd = "";
    }

    // Parse remaining args (after command name)
    ai : ., mut = 2;  // start after prog + cmd
    if str_len(g_cli_matched_cmd) == 0 {
        // No command, start from argv[1]
        // But also handle --help
        if str_eq(first, "--help") != 0 || str_eq(first, "-h") != 0 {
            cli_help();
            return -1;
        }
        ai = 1;
    }

    loop {
        if ai >= argc_int { break; }
        arg := get_arg(ai);
        if str_len(arg) == 0 { break; }

        // --help or -h anywhere
        if str_eq(arg, "--help") != 0 || str_eq(arg, "-h") != 0 {
            cli_help();
            return -1;
        }

        if _cli_is_flag(arg) != 0 {
            name := _cli_strip_dashes(arg);
            fi := _cli_find_flag(name);
            if fi < 0 {
                print("unknown flag: ");
                println(arg);
                cli_help();
                return -1;
            }
            if r64(g_cli_flags, fi * 48 + 40) != 0 {   // is_bool
                w64(g_cli_flags, fi * 48 + 32, 1);       // has_value
                w64(g_cli_flags, fi * 48 + 24, "1");     // value
            } else {
                ai = ai + 1;
                if ai >= argc_int {
                    print("flag ");
                    print(arg);
                    println(" requires a value");
                    return -1;
                }
                val := get_arg(ai);
                w64(g_cli_flags, fi * 48 + 24, val);      // value
                w64(g_cli_flags, fi * 48 + 32, 1);         // has_value
            }
        } else {
            // Positional argument
            dyn_grow_cli_args(g_cli_arg_count + 1);
            w64(g_cli_args, g_cli_arg_count * 8, arg);
            g_cli_arg_count = g_cli_arg_count + 1;
        }
        ai = ai + 1;
    }

    return 0;
}

// --- Query ---

fn cli_cmd_name() -> string {
    return g_cli_matched_cmd;
}

fn cli_eq(cmd: string, expected: string) -> int {
    return str_eq(cmd, expected);
}

fn cli_get(name: string) -> string {
    fi := _cli_find_flag(name);
    if fi >= 0 && r64(g_cli_flags, fi * 48 + 32) != 0 {  // has_value
        return r64(g_cli_flags, fi * 48 + 24);             // value
    }
    return "";
}

fn cli_has(name: string) -> int {
    fi := _cli_find_flag(name);
    if fi >= 0 {
        return r64(g_cli_flags, fi * 48 + 32);  // has_value
    }
    return 0;
}

fn cli_arg(n: int) -> string {
    if n >= 0 && n < g_cli_arg_count {
        return r64(g_cli_args, n * 8);
    }
    return "";
}

fn cli_arg_count() -> int {
    return g_cli_arg_count;
}

// --- Help ---

fn cli_help() {
    // usage: prog [-h] {cmd1,cmd2,...} [options]
    print("usage: ");
    print(g_cli_prog);
    print(" [-h]");
    if g_cli_cmd_count > 0 {
        print(" {");
        ci : ., mut = 0;
        first : ., mut = 1;
        loop {
            if ci >= g_cli_cmd_count { break; }
            if first == 0 { print(","); }
            print(r64(g_cli_cmds, ci * 16));
            first = 0;
            ci = ci + 1;
        }
        print("}");
    }
    println(" [options]");
    println("");

    if str_len(g_cli_desc) > 0 {
        println(g_cli_desc);
        println("");
    }

    // Positional arguments (commands)
    if g_cli_cmd_count > 0 {
        println("positional arguments:");
        print("  {");
        ci : ., mut = 0;
        first : ., mut = 1;
        loop {
            if ci >= g_cli_cmd_count { break; }
            if first == 0 { print(","); }
            print(r64(g_cli_cmds, ci * 16));
            first = 0;
            ci = ci + 1;
        }
        println("}");
        ci = 0;
        loop {
            if ci >= g_cli_cmd_count { break; }
            cmd_name_ni := r64(g_cli_cmds, ci * 16);
            cmd_desc_ni := r64(g_cli_cmds, ci * 16 + 8);
            print("    ");
            print(cmd_name_ni);
            pad := str_len(cmd_name_ni);
            loop {
                if pad >= 12 { break; }
                print(" ");
                pad = pad + 1;
            }
            println(cmd_desc_ni);
            ci = ci + 1;
        }
        println("");
    }

    // Flags / options
    println("options:");
    // Built-in -h, --help
    println("  -h, --help            show this help message and exit");
    fi : ., mut = 0;
    loop {
        if fi >= g_cli_flag_count { break; }
        f_short_ni := r64(g_cli_flags, fi * 48 + 8);
        f_long_ni := r64(g_cli_flags, fi * 48);
        f_desc_ni := r64(g_cli_flags, fi * 48 + 16);
        print("  ");
        if str_len(f_short_ni) > 0 {
            print("-");
            print(f_short_ni);
            print(", ");
        } else {
            print("    ");
        }
        print("--");
        print(f_long_ni);
        // Pad to 24 chars total (prefix = "  " + short/"    " + "--")
        total : ., mut = 8;
        if str_len(f_short_ni) > 0 {
            total = 8;  // "  " + "-X, " + "--" = 2+4+2 = 8
        }
        total = total + str_len(f_long_ni);
        loop {
            if total >= 24 { break; }
            print(" ");
            total = total + 1;
        }
        println(f_desc_ni);
        fi = fi + 1;
    }
}
