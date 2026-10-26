// src/kernel/kernel_main.cr: kernel command-line interface.
// Usage: kernel QUERY_FILE...  Input is a list of files, matching the reference
// harness. Core has no stdin API.
// Line handling: skip empty lines and # comments, including leading whitespace.
// Reset g_kernel_count, g_ctx_len, and g_env_len for every line; otherwise the
// arena fills and later queries falsely reject.
// A malformed line (parse failure or unknown command) produces no output so
// stdout stays clean. It increments the malformed count, and the process exits 1.
//
// Interfaces:
//   check.cr: type_check(a, m) returns 1 for accept and 0 or negative for reject.
//   Arguments are (type, term); protocol lines put the term first, so the caller
//   swaps them. type_infer(m) returns an inferred nf node or -1.
//   subtype.cr: subtyping(a, b) returns 1 for yes and 0 or negative for no.
//   Context comes from mctt.cr globals; nbe uses kern_nbe and kern_nbe_ty.
// Depends on mctt.cr, nbe.cr, term_io.cr, fmt.cr, io.cr, and rt.cr.

// Structural equality for nf and ne nodes, used by convert.
fn nf_sub_eq(a: int, b: int) -> int:
    if a < 0 || b < 0:
        return 0
    ka := kern_get(a, 0)
    kb := kern_get(b, 0)
    if ka != K_SUB || kb != K_SUB:
        return 0
    sa := kern_get(a, 4)
    sb := kern_get(b, 4)
    if sa != sb:
        return 0
    if sa == S_ID || sa == S_WEAKEN:
        return 1
    if sa == S_COMPOSE:
        return nf_sub_eq(kern_get(a, 1), kern_get(b, 1)) != 0 && nf_sub_eq(kern_get(a, 2), kern_get(b, 2)) != 0
    if sa == S_EXTEND:
        return nf_sub_eq(kern_get(a, 1), kern_get(b, 1)) != 0 && nf_eq(kern_get(a, 2), kern_get(b, 2)) != 0
    return 0

fn nf_eq(a: int, b: int) -> int:
    if a < 0 || b < 0:
        return 0
    ka := kern_get(a, 0)
    kb := kern_get(b, 0)
    if ka != kb:
        return 0
    if ka == K_TYP:
        return kern_get(a, 1) == kern_get(b, 1)
    if ka == K_NAT || ka == K_ZERO:
        return 1
    if ka == K_SUCC:
        return nf_eq(kern_get(a, 1), kern_get(b, 1))
    if ka == K_VAR:
        return kern_get(a, 1) == kern_get(b, 1)
    if ka == K_NATREC:
        return nf_eq(kern_get(a, 1), kern_get(b, 1)) != 0 && nf_eq(kern_get(a, 2), kern_get(b, 2)) != 0 && nf_eq(kern_get(a, 3), kern_get(b, 3)) != 0 && nf_eq(kern_get(a, 4), kern_get(b, 4)) != 0
    if ka == K_PI || ka == K_FN || ka == K_APP:
        return nf_eq(kern_get(a, 1), kern_get(b, 1)) != 0 && nf_eq(kern_get(a, 2), kern_get(b, 2)) != 0
    if ka == K_SUB:
        return nf_eq(kern_get(a, 1), kern_get(b, 1)) != 0 && nf_sub_eq(kern_get(a, 2), kern_get(b, 2)) != 0
    return 0

// Line handling.
g_kernel_malformed : int, mut = 0

// Parse (ctx exp*) and push bindings in order. The first expression is the newest
// binding. Return -1 on failure.
fn kern_parse_ctx() -> int:
    kp_skip_ws()
    if kp_expect(40) == 0:
        return -1
    kp_skip_ws()
    if kp_take_name("ctx") == 0:
        return -1
    loop:
        kp_skip_ws()
        if g_kernel_parse_pos < kp_len() && load8(g_kernel_parse_text, g_kernel_parse_pos) == 41:
            kp_expect(41)
            return 1
        e := parse_exp()
        if e < 0:
            return -1
        ctx_extend(e)
    return 1

// Check that the line has no trailing content.
fn kern_line_end_ok() -> int:
    kp_skip_ws()
    if g_kernel_parse_pos < kp_len():
        return 0
    return 1

// Process one query. Return 0 after output and 1 for a malformed line with no output.
fn kern_process_line(line: string) -> int:
    // Skip leading whitespace, empty lines, and # comments.
    pos : ., mut = 0
    loop:
        if pos >= str_len(line):
            break
        c := load8(line, pos)
        if c == 32 || c == 9 || c == 13:
            pos = pos + 1
        else:
            break
    if pos >= str_len(line):
        return 0
    if load8(line, pos) == 35:
        return 0
    // Comment byte.

    // Reset the arena, context, and environment for every line. Call parse_exp
    // and parse_sub directly; kernel_parse resets the arena and expects one
    // expression for the whole text.
    g_kernel_count = 0
    g_ctx_len = 0
    g_kernel_parse_text = line
    g_kernel_parse_pos = pos

    if kp_take_name("check") != 0:
        if kern_parse_ctx() < 0:
            g_kernel_malformed = g_kernel_malformed + 1
            return 1
        m := parse_exp()
        a := parse_exp()
        if m < 0 || a < 0:
            g_kernel_malformed = g_kernel_malformed + 1
            return 1
        if kern_line_end_ok() == 0:
            g_kernel_malformed = g_kernel_malformed + 1
            return 1
        r := type_check(a, m)                       // protocol order is term then type, so swap
        if r > 0:
            println("check: accept")
        else:
            println("check: reject")
        return 0
    if kp_take_name("infer") != 0:
        if kern_parse_ctx() < 0:
            g_kernel_malformed = g_kernel_malformed + 1
            return 1
        m := parse_exp()
        if m < 0:
            g_kernel_malformed = g_kernel_malformed + 1
            return 1
        if kern_line_end_ok() == 0:
            g_kernel_malformed = g_kernel_malformed + 1
            return 1
        r := type_infer(m)
        if r >= 0:
            println("infer: type: " + kernel_print(r))
        else:
            println("infer: reject")
        return 0
    if kp_take_name("convert") != 0:
        if kern_parse_ctx() < 0:
            g_kernel_malformed = g_kernel_malformed + 1
            return 1
        t1 := parse_exp()
        t2 := parse_exp()
        tv := parse_exp()
        if t1 < 0 || t2 < 0 || tv < 0:
            g_kernel_malformed = g_kernel_malformed + 1
            return 1
        if kern_line_end_ok() == 0:
            g_kernel_malformed = g_kernel_malformed + 1
            return 1
        n1 := kern_nbe(t1, tv)
        n2 := kern_nbe(t2, tv)
        if n1 >= 0 && n2 >= 0 && nf_eq(n1, n2) != 0:
            println("convert: yes")
        else:
            println("convert: no")
        return 0
    if kp_take_name("subtype") != 0:
        if kern_parse_ctx() < 0:
            g_kernel_malformed = g_kernel_malformed + 1
            return 1
        a := parse_exp()
        b := parse_exp()
        if a < 0 || b < 0:
            g_kernel_malformed = g_kernel_malformed + 1
            return 1
        if kern_line_end_ok() == 0:
            g_kernel_malformed = g_kernel_malformed + 1
            return 1
        r := subtyping(a, b)
        if r > 0:
            println("subtype: yes")
        else:
            println("subtype: no")
        return 0
    g_kernel_malformed = g_kernel_malformed + 1
    return 1

// Entry point.
fn kernel_main() -> int:
    // get_arg is a builtin: get_arg(0) is argc as a string, get_arg(i) is argument
    // i for i >= 1, and an empty string ends the list.
    n : ., mut = 1
    files : ., mut = 0
    loop:
        a := get_arg(n)
        if str_len(a) == 0:
            break
        txt := read_file(a)
        tl := str_len(txt)
        pos : ., mut = 0
        loop:
            if pos >= tl:
                break
            end : ., mut = pos
            loop:
                if end >= tl:
                    break
                if load8(txt, end) == 10:
                    break
                end = end + 1
            line := str_sub(txt, pos, end - pos)
            kern_process_line(line)
            if end >= tl:
                break
            pos = end + 1
        files = files + 1
        n = n + 1
    if files <= 0:
        return 1
    // No file arguments.
    if g_kernel_malformed > 0:
        return 1
    return 0
