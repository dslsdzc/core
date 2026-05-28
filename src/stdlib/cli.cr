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
MAX_CLI_CMDS : int = 16;
MAX_CLI_FLAGS : int = 32;
MAX_CLI_ARGS : int = 32;
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
g_cli_cmds : [CliCmd; MAX_CLI_CMDS], mut;
g_cli_cmd_count : int, mut;
g_cli_flags : [CliFlag; MAX_CLI_FLAGS], mut;
g_cli_flag_count : int, mut;
g_cli_args : [string; MAX_CLI_ARGS], mut;
g_cli_arg_count : int, mut;
g_cli_matched_cmd : string, mut;

// --- Init ---

fn cli_init(prog: string, desc: string) {
    g_cli_prog = prog;
    g_cli_desc = desc;
    g_cli_cmd_count = 0;
    g_cli_flag_count = 0;
    g_cli_arg_count = 0;
    g_cli_matched_cmd = "";
}

// --- Registration ---

fn cli_cmd(name: string, desc: string) {
    if g_cli_cmd_count < MAX_CLI_CMDS {
        g_cli_cmds[g_cli_cmd_count] = CliCmd { name = name, desc = desc };
        g_cli_cmd_count = g_cli_cmd_count + 1;
    }
}

fn cli_flag(long_name: string, short_name: string, desc: string) {
    if g_cli_flag_count < MAX_CLI_FLAGS {
        g_cli_flags[g_cli_flag_count] = CliFlag {
            long_name = long_name, short_name = short_name, desc = desc,
            value = "", has_value = 0, is_bool = 0
        };
        g_cli_flag_count = g_cli_flag_count + 1;
    }
}

fn cli_flag_bool(long_name: string, short_name: string, desc: string) {
    if g_cli_flag_count < MAX_CLI_FLAGS {
        g_cli_flags[g_cli_flag_count] = CliFlag {
            long_name = long_name, short_name = short_name, desc = desc,
            value = "", has_value = 0, is_bool = 1
        };
        g_cli_flag_count = g_cli_flag_count + 1;
    }
}

// --- Internal helpers ---

fn _cli_find_flag(name: string) -> int {
    i : ., mut = 0;
    loop {
        if i >= g_cli_flag_count { break; }
        f := g_cli_flags[i];
        // Try long name match: --name
        if __builtin_str_len(f.long_name) > 0 && __builtin_str_eq(f.long_name, name) != 0 {
            return i;
        }
        // Try short name match: -n
        if __builtin_str_len(f.short_name) > 0 && __builtin_str_eq(f.short_name, name) != 0 {
            return i;
        }
        i = i + 1;
    }
    return -1;
}

fn _cli_is_flag(arg: string) -> int {
    slen := __builtin_str_len(arg);
    if slen < 2 { return 0; }
    c0 := __builtin_str_get(arg, 0);
    if __builtin_str_eq(c0, "-") != 0 { return 1; }
    return 0;
}

fn _cli_strip_dashes(arg: string) -> string {
    slen := __builtin_str_len(arg);
    if slen == 0 { return ""; }
    start : ., mut = 0;
    if __builtin_str_get(arg, 0) == "-" {
        start = 1;
        if slen > 1 && __builtin_str_get(arg, 1) == "-" {
            start = 2;
        }
    }
    return __builtin_str_sub(arg, start, slen - start);
}

// --- Parse ---

fn cli_parse() -> int {
    argc := __builtin_get_arg(0);
    argc_int : ., mut = 0;
    // Count args by scanning until we get empty string
    loop {
        a := __builtin_get_arg(argc_int);
        if __builtin_str_len(a) == 0 { break; }
        argc_int = argc_int + 1;
    }
    if argc_int < 2 { return 0; }  // no subcommand

    // Determine subcommand from argv[1]
    first := __builtin_get_arg(1);
    if _cli_is_flag(first) == 0 && g_cli_cmd_count > 0 {
        // First non-flag arg — check if it's a valid subcommand
        ci : ., mut = 0;
        found_cmd : ., mut = 0;
        loop {
            if ci >= g_cli_cmd_count { break; }
            if __builtin_str_eq(g_cli_cmds[ci].name, first) != 0 {
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
    if __builtin_str_len(g_cli_matched_cmd) == 0 {
        // No command, start from argv[1]
        // But also handle --help
        if __builtin_str_eq(first, "--help") != 0 || __builtin_str_eq(first, "-h") != 0 {
            cli_help();
            return -1;
        }
        ai = 1;
    }

    loop {
        if ai >= argc_int { break; }
        arg := __builtin_get_arg(ai);
        if __builtin_str_len(arg) == 0 { break; }

        // --help or -h anywhere
        if __builtin_str_eq(arg, "--help") != 0 || __builtin_str_eq(arg, "-h") != 0 {
            cli_help();
            return -1;
        }

        if _cli_is_flag(arg) != 0 {
            name := _cli_strip_dashes(arg);
            fi := _cli_find_flag(name);
            if fi < 0 {
                __builtin_print("unknown flag: ");
                __builtin_println(arg);
                cli_help();
                return -1;
            }
            if g_cli_flags[fi].is_bool != 0 {
                g_cli_flags[fi].has_value = 1;
                g_cli_flags[fi].value = "1";
            } else {
                // Next arg is the value
                ai = ai + 1;
                if ai >= argc_int {
                    __builtin_print("flag ");
                    __builtin_print(arg);
                    __builtin_println(" requires a value");
                    return -1;
                }
                val := __builtin_get_arg(ai);
                g_cli_flags[fi].value = val;
                g_cli_flags[fi].has_value = 1;
            }
        } else {
            // Positional argument
            if g_cli_arg_count < MAX_CLI_ARGS {
                g_cli_args[g_cli_arg_count] = arg;
                g_cli_arg_count = g_cli_arg_count + 1;
            }
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
    return __builtin_str_eq(cmd, expected);
}

fn cli_get(name: string) -> string {
    fi := _cli_find_flag(name);
    if fi >= 0 && g_cli_flags[fi].has_value != 0 {
        return g_cli_flags[fi].value;
    }
    return "";
}

fn cli_has(name: string) -> int {
    fi := _cli_find_flag(name);
    if fi >= 0 {
        return g_cli_flags[fi].has_value;
    }
    return 0;
}

fn cli_arg(n: int) -> string {
    if n >= 0 && n < g_cli_arg_count {
        return g_cli_args[n];
    }
    return "";
}

fn cli_arg_count() -> int {
    return g_cli_arg_count;
}

// --- Help ---

fn cli_help() {
    // usage: prog [-h] {cmd1,cmd2,...} [options]
    __builtin_print("usage: ");
    __builtin_print(g_cli_prog);
    __builtin_print(" [-h]");
    if g_cli_cmd_count > 0 {
        __builtin_print(" {");
        ci : ., mut = 0;
        first : ., mut = 1;
        loop {
            if ci >= g_cli_cmd_count { break; }
            if first == 0 { __builtin_print(","); }
            __builtin_print(g_cli_cmds[ci].name);
            first = 0;
            ci = ci + 1;
        }
        __builtin_print("}");
    }
    __builtin_println(" [options]");
    __builtin_println("");

    if __builtin_str_len(g_cli_desc) > 0 {
        __builtin_println(g_cli_desc);
        __builtin_println("");
    }

    // Positional arguments (commands)
    if g_cli_cmd_count > 0 {
        __builtin_println("positional arguments:");
        __builtin_print("  {");
        ci : ., mut = 0;
        first : ., mut = 1;
        loop {
            if ci >= g_cli_cmd_count { break; }
            if first == 0 { __builtin_print(","); }
            __builtin_print(g_cli_cmds[ci].name);
            first = 0;
            ci = ci + 1;
        }
        __builtin_println("}");
        ci = 0;
        loop {
            if ci >= g_cli_cmd_count { break; }
            cmd := g_cli_cmds[ci];
            __builtin_print("    ");
            __builtin_print(cmd.name);
            pad := __builtin_str_len(cmd.name);
            loop {
                if pad >= 12 { break; }
                __builtin_print(" ");
                pad = pad + 1;
            }
            __builtin_println(cmd.desc);
            ci = ci + 1;
        }
        __builtin_println("");
    }

    // Flags / options
    __builtin_println("options:");
    // Built-in -h, --help
    __builtin_println("  -h, --help            show this help message and exit");
    fi : ., mut = 0;
    loop {
        if fi >= g_cli_flag_count { break; }
        f := g_cli_flags[fi];
        __builtin_print("  ");
        if __builtin_str_len(f.short_name) > 0 {
            __builtin_print("-");
            __builtin_print(f.short_name);
            __builtin_print(", ");
        } else {
            __builtin_print("    ");
        }
        __builtin_print("--");
        __builtin_print(f.long_name);
        // Pad to 24 chars total
        total : ., mut = 4;
        if __builtin_str_len(f.short_name) > 0 {
            total = 8;
        }
        total = total + __builtin_str_len(f.long_name);
        loop {
            if total >= 24 { break; }
            __builtin_print(" ");
            total = total + 1;
        }
        __builtin_println(f.desc);
        fi = fi + 1;
    }
}
