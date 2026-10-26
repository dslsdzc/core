// test_term_io.cr: protocol-layer tests.
// Build: ./build/corec build src/kernel/test_term_io.cr -o build/test_term_io --static
// Run ./build/test_term_io from the repository root.
// Cases:
// 1. three fixed strings parse and print back unchanged;
// 2. round-trip every protocol kind (typ, pi, app, sub-extend, natrec, ...);
// 3. invalid input returns -1;
// 4. the first three lines and infer case 16 of corpus_manual.txt parse and
//    round-trip.

import io
import term_io

g_fail_count : int, mut = 0

fn check_roundtrip(s: string) -> int:
    idx := kernel_parse(s)
    if idx < 0:
        g_fail_count = g_fail_count + 1
        println("FAIL parse(-1): " + s)
        return 1
    out := kernel_print(idx)
    if str_eq(out, s) == 0:
        g_fail_count = g_fail_count + 1
        println("FAIL roundtrip: [" + s + "] -> [" + out + "]")
        return 1
    return 0

// 空白容忍：输入可含任意空白，打印结果须等于规范紧凑形式
fn check_roundtrip_compact(s: string, canonical: string) -> int:
    idx := kernel_parse(s)
    if idx < 0:
        g_fail_count = g_fail_count + 1
        println("FAIL parse(-1): " + s)
        return 1
    out := kernel_print(idx)
    if str_eq(out, canonical) == 0:
        g_fail_count = g_fail_count + 1
        println("FAIL compact: [" + s + "] -> [" + out + "]")
        return 1
    return 0

fn check_parse_fail(s: string) -> int:
    idx := kernel_parse(s)
    if idx >= 0:
        g_fail_count = g_fail_count + 1
        println("FAIL expect -1: " + s)
        return 1
    return 0

// 给定一行查询文本与 '(' 起始位置，返回匹配 ')' 之后的位置（深度计数）
fn exp_end_at(text: string, start: int) -> int:
    depth : int, mut = 0
    i : int, mut = start
    len := str_len(text)
    loop:
        if i >= len:
            break
        c := load8(text, i)
        if c == 40:
            depth = depth + 1
        else if c == 41:
            depth = depth - 1
            if depth == 0:
                return i + 1
        i = i + 1
    return -1

// 解析一行查询中的全部 <exp>（跳过 <cmd> 与 <ctx>），逐个 kernel_parse
fn check_line_exps(line: string) -> int:
    // 跳过 # 注释行
    l0 : int, mut = 0
    ln := str_len(line)
    loop:
        if l0 >= ln:
            break
        if load8(line, l0) != 32:
            break
        l0 = l0 + 1
    if l0 < ln && load8(line, l0) == 35:
        return 0
    // '#'
    // 找 ctx 起点（第一个 '('）与其结束位置
    p : int, mut = 0
    ctx_start : int, mut = -1
    loop:
        if p >= ln:
            break
        if load8(line, p) == 40:
            ctx_start = p
            break
        p = p + 1
    if ctx_start < 0:
        return 0
    // 无 exp，跳过
    rest : ., mut = exp_end_at(line, ctx_start)
    if rest < 0:
        return 0
    // 逐个解析剩余 exp
    loop:
        if rest >= ln:
            break
        // 跳过空白
        loop:
            if rest >= ln:
                break
            c := load8(line, rest)
            if c == 32 || c == 9 || c == 10 || c == 13:
                rest = rest + 1
            else:
                break
        if rest >= ln:
            break
        if load8(line, rest) != 40:
            break
        e_end := exp_end_at(line, rest)
        if e_end < 0:
            g_fail_count = g_fail_count + 1
            println("FAIL unclosed exp in line: " + line)
            return 1
        exp_text := str_sub(line, rest, e_end - rest)
        idx := kernel_parse(exp_text)
        if idx < 0:
            g_fail_count = g_fail_count + 1
            println("FAIL corpus exp: " + exp_text)
            return 1
        out := kernel_print(idx)
        if str_eq(out, exp_text) == 0:
            g_fail_count = g_fail_count + 1
            println("FAIL corpus roundtrip: [" + exp_text + "] -> [" + out + "]")
            return 1
        rest = e_end
    return 0

fn main() -> int:
    // Three fixed round-trip strings.
    // The reference lambda example used a three-element form `(fn (nat) (nat) M)`,
    // which does not match the protocol `(fn A M)`. This test uses the two-element
    // form; the three-element form is a negative case.
    if check_roundtrip("(succ (succ (zero)))") != 0:
        println("  ^ case 1")
    if check_roundtrip("(natrec (nat) (zero) (fn (nat) (succ (var 0))) (succ (zero)))") != 0:
        println("  ^ case 2")
    if check_roundtrip("(sub (var 0) (compose (weaken) (id)))") != 0:
        println("  ^ case 3")
    if check_parse_fail("(natrec (nat) (zero) (fn (nat) (nat) (succ (var 0))) (succ (zero)))") != 0:
        println("  ^ brief 3-ary fn (protocol violation)")

    // ── 协议全 kind 覆盖 ──
    if check_roundtrip("(typ 0)") != 0:
        println("  ^ typ")
    if check_roundtrip("(typ 7)") != 0:
        println("  ^ typ7")
    if check_roundtrip("(nat)") != 0:
        println("  ^ nat")
    if check_roundtrip("(zero)") != 0:
        println("  ^ zero")
    if check_roundtrip("(succ (zero))") != 0:
        println("  ^ succ")
    if check_roundtrip("(natrec (nat) (zero) (fn (nat) (succ (var 0))) (succ (zero)))") != 0:
        println("  ^ natrec")
    if check_roundtrip("(pi (nat) (nat))") != 0:
        println("  ^ pi")
    if check_roundtrip("(fn (nat) (var 0))") != 0:
        println("  ^ fn")
    if check_roundtrip("(app (fn (nat) (var 0)) (zero))") != 0:
        println("  ^ app")
    if check_roundtrip("(var 0)") != 0:
        println("  ^ var")
    if check_roundtrip("(var 12)") != 0:
        println("  ^ var12")
    if check_roundtrip("(sub (var 0) (id))") != 0:
        println("  ^ sub-id")
    if check_roundtrip("(sub (var 0) (weaken))") != 0:
        println("  ^ sub-weaken")
    if check_roundtrip("(sub (var 0) (compose (weaken) (id)))") != 0:
        println("  ^ sub-compose")
    if check_roundtrip("(sub (succ (var 0)) (extend (id) (zero)))") != 0:
        println("  ^ sub-extend")
    if check_roundtrip("(sub (sub (var 0) (weaken)) (compose (extend (id) (zero)) (weaken)))") != 0:
        println("  ^ nested sub")
    if check_roundtrip("(app (var 3) (var 0))") != 0:
        println("  ^ app var")
    if check_roundtrip("(pi (typ 1) (var 0))") != 0:
        println("  ^ pi typ")

    // ── 空白容忍（打印器输出规范紧凑形式）──
    if check_roundtrip_compact(" (nat) ", "(nat)") != 0:
        println("  ^ leading/trailing ws")
    if check_roundtrip_compact("( succ ( zero ) )", "(succ (zero))") != 0:
        println("  ^ inner ws")
    if check_roundtrip_compact("(var   7)", "(var 7)") != 0:
        println("  ^ ws before num")

    // ── 非法输入 ──
    if check_parse_fail("") != 0:
        println("  ^ empty")
    if check_parse_fail("(bogus)") != 0:
        println("  ^ bogus")
    if check_parse_fail("(succ)") != 0:
        println("  ^ succ no child")
    if check_parse_fail("(succ (zero)") != 0:
        println("  ^ unclosed")
    if check_parse_fail("(nat) extra") != 0:
        println("  ^ trailing")
    if check_parse_fail("(var x)") != 0:
        println("  ^ var nonnum")

    // Corpus: the first three lines and infer case 16 (1-based).
    data := read_file("tests/kernel/cases/corpus_manual.txt")
    if str_len(data) == 0:
        g_fail_count = g_fail_count + 1
        println("FAIL cannot read corpus_manual.txt (run from repo root)")
    else:
        // Process line by line; the first three lines and case 16 are the
        // acceptance points, and the remaining lines are checked as well.
        line_no : int, mut = 0
        pos : int, mut = 0
        dlen := str_len(data)
        loop:
            if pos >= dlen:
                break
            if line_no >= 25:
                break
            // 取一行
            eol : int, mut = pos
            loop:
                if eol >= dlen:
                    break
                if load8(data, eol) == 10:
                    break
                eol = eol + 1
            line := str_sub(data, pos, eol - pos)
            if line_no < 3 || line_no == 15:
                println("line " + int_str(line_no + 1) + ": " + line)
            if check_line_exps(line) != 0:
                println("  ^ corpus line " + int_str(line_no + 1))
            line_no = line_no + 1
            pos = eol + 1
        println("corpus lines checked: " + int_str(line_no))

    if g_fail_count == 0:
        println("ALL PASS")
        return 0
    println("FAILURES: " + int_str(g_fail_count))
    return 1
