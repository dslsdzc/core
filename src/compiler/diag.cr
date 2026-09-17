// === diag.cr ===
// Rust-style error diagnostics for the Core compiler.
// Uses g_diags, g_diag_count (from ast.cr) and g_errors, g_error_count (from lexer.cr).

// ─── helpers ────────────────────────────────────────────────────

fn read_source_line(line: int) -> string {
    slen := str_len(g_source);
    cur : ., mut = 1;
    start : ., mut = 0;
    i : ., mut = 0;
    loop {
        if i >= slen { break; }
        if cur == line {
            j : ., mut = i;
            loop {
                if j >= slen { break; }
                c := get_char(g_source, j);
                if c == "\n" { break; }
                j = j + 1;
            }
            return str_sub(g_source, i, j - i);
        }
        if load8(g_source, i) == 10 {
            cur = cur + 1;
            start = i + 1;
        }
        i = i + 1;
    }
    return "";
}

fn source_line_count() -> int {
    count : ., mut = 1;
    i : ., mut = 0;
    slen := str_len(g_source);
    loop {
        if i >= slen { break; }
        if load8(g_source, i) == 10 { count = count + 1; }
        i = i + 1;
    }
    return count;
}

fn print_source_line(line: int, col: int, annotation: string) {
    if line <= 0 { return; }
    ltxt := read_source_line(line);
    if str_len(ltxt) == 0 { return; }
    ln_str := int_str(line);
    if line < 10 { ln_str = " " + ln_str; }
    print(ln_str);
    print(" | ");
    println(ltxt);
    // underline: spaces + ^ under the column + annotation
    print("   | ");
    ci : ., mut = 0;
    loop {
        if ci >= col - 1 { break; }
        print(" ");
        ci = ci + 1;
    }
    print("^");
    if str_len(annotation) > 0 {
        print(" ");
        // Short annotation: first line or up to first " — "
        alen := str_len(annotation);
        cutoff : ., mut = alen;
        // Truncate at ' — ' (3 bytes in UTF-8: em dash = 3 bytes)
        ci2 : ., mut = 0;
        loop {
            if ci2 + 3 > alen { break; }
            c := load8(annotation, ci2);
            if c == 226 {  // start of em dash (— = U+2014, 3 bytes)
                cutoff = ci2;
                break;
            }
            ci2 = ci2 + 1;
        }
        // Limit to 48 chars max
        if cutoff > 48 { cutoff = 48; }
        print(str_sub(annotation, 0, cutoff));
    }
    println("");
}

fn error_cat_prefix(cat: int) -> string {
    if cat == 1 { return "P"; }
    if cat == 2 { return "N"; }
    if cat == 3 { return "I"; }
    if cat == 4 { return "TA"; }
    if cat == 5 { return "TF"; }
    if cat == 6 { return "TB"; }
    if cat == 7 { return "TU"; }
    if cat == 8 { return "TC"; }
    if cat == 9 { return "TM"; }
    if cat == 10 { return "TK"; }
    if cat == 11 { return "TS"; }
    if cat == 12 { return "TG"; }
    if cat == 13 { return "B"; }
    if cat == 14 { return "R"; }
    if cat == 15 { return "E"; }
    if cat == 16 { return "ICE"; }
    if cat == 17 { return "V"; }   // 批 6：规约语法/验证面（EC_V_*，17xxx）
    return "E";
}

fn pad_diag_num(num: int) -> string {
    s := int_str(num);
    if num < 10 { s = "0" + s; }
    return s;
}

// ─── diagnostics (g_diags) ─────────────────────────────────────

// 行号 → 所属文件 id（build_line_fileid 的逐行映射）；越界返回 -1
fn diag_fileid_for_line(line: int) -> int {
    if line >= 1 && line <= g_line_count {
        return r64(g_line_fileid, (line - 1) * 8);
    }
    return -1;
}

fn print_diagnostics() {
    if g_diag_count == 0 { return; }
    source_lines := source_line_count();
    di : ., mut = 0;
    loop {
        if di >= g_diag_count { break; }
        ec := r64(g_diags, di * DIAG_REC_SIZE);
        msg := load_str_ptr(g_diags, di * DIAG_REC_SIZE + 8);
        ln := r64(g_diags, di * DIAG_REC_SIZE + 16);
        cl := r64(g_diags, di * DIAG_REC_SIZE + 24);
        cat : ., mut = ec / 1000;
        num : ., mut = ec % 1000;
        print("error[");
        print(error_cat_prefix(cat));
        print(pad_diag_num(num));
        print("]: ");
        println(msg);
        print(" --> ");
        print(int_str(ln));
        print(":");
        println(int_str(cl));
        if ln > 0 && ln <= source_lines {
            println("   |");
            print_source_line(ln, cl, msg);
        }
        println("");
        di = di + 1;
    }
}

// ─── parse errors (g_errors) ────────────────────────────────────

fn print_parse_errors() {
    if g_error_count == 0 { return; }
    ei2 : ., mut = 0;
    loop {
        if ei2 >= g_error_count { break; }
        println("error: " + istr_get(r64(g_errors, ei2 * 8)));
        ei2 = ei2 + 1;
    }
}
// ─── fail-closed 判据线（FC 批 T2）：豁免登记表 ────────────────────────
// 语义：**默认阻断 + 豁免登记表**——`main.cr` 的硬判定循环对每条诊断调本函数，返回 0 ⇒ 阻断
// （rc=1 + 零产物）。判据 = 「判定继续 ⇒ 产出静默错产物」（R002 / TS01-04+TK02 / TM03 / ICE04 /
// TA02 五组先例；旧正向名单 11 码按新语义默认在闸内，故退役）。
// **换代纪律（只减不增）**：撤条须带根因证据；**加条须维护者批**；每次开新面（新命令/新语料层）
// 必须重跑全语料 report-only 并对表（表外命中 ⇒ 停）。
// 粒度 = 码级；每条附「位点证据 / 理由 / 退出条件」三字段（证据字段不参与判定）。
// **不得**把本表写成「默认放行」形态（那会把静默错产物制度化）。
fn diag_gate_exempt(code: int, scope: int) -> int {
    // ── scope = BUILD（5 条；build/ccr/cir/run 面）────────────────────────
    // **TF01 已于 2026-09-18（批 8 A₂）撤销**——撤条归因（带根因证据，合「只减不增」纪律）：
    //   真因 = 类型模型冲突：`alloc` 的模型是 `() -> string`（`checker.cr` 的 `bi_add("alloc", TI_STR)`），
    //   而 `src/stdlib/{chan,goroutine,sched}.cr` 的 3 处 handle 返回型写作 `-> int`（`chan_make` / `g_new` /
    //   透传的 `sched_go`）⇒ 返回位 `type_compat_strict(string, int) != 1` ⇒ TF01（**不是误报**：上一批
    //   `lits_copy` 同因已修，本次是**同族未清实例**）。修法 = **(A) 语料/stdlib 向模型对齐**（3 处返回型 +
    //   5 处 handle 形参：`chan_send/chan_recv/chan_close(ch: string)` · `sched_enqueue/g_free(g: string)`）。
    //   判据 = 5 档并发语料 `check` **rc=0 且无 TF01**、`build` rc=0、`run` rc=0（前后读数 2→0）；
    //   **负控** = 真 TF01（string 值返 int 声明）仍**阻断**（rc=1 + 零产物）——见 `test_diag_gate.py`。
    //   ⇒ 豁免**不再需要**（撤条 = 「不再用豁免盖住真冲突」；条目 6 的收口形态）。
    // TF07 · 位点 = tests/suite/ptr_ref_first.cr:8（@raw_int）+ tests/selfhost/test_ccr_types.py:1805
    //        理由 = EC_TF_ARG_TYPE 全仓唯一 raise 点在 @raw_int 内建位（checker.cr:3727），非调用位点
    //        退出 = #2026-09-16-1/F3 调用位点收口后撤
    if scope == GATE_SCOPE_BUILD && code == EC_TF_ARG_TYPE { return 1; }
    // TF07 · 位点 = tests/suite/ptr_ref_first.cr:8（@raw_int）+ tests/selfhost/test_ccr_types.py:1805
    //        理由 = EC_TF_ARG_TYPE 全仓唯一 raise 点在 @raw_int 内建位（checker.cr:3727），非调用位点
    //        退出 = #2026-09-16-1/F3 调用位点收口后撤
    if scope == GATE_SCOPE_BUILD && code == EC_TF_ARG_TYPE { return 1; }
    // TB01 · 位点 = ptr_ref_first（TF07 级联）+ t3/t4 库单元 8 档（N 族级联）
    //        理由 = **级联码**：ANY 门（checker.cr:2473-2474）仅在**双侧**非 int/dex 时报，
    //               而错误标记 TI_NEVER 的回传点（:2433/:2810/:3728）先行 ⇒ 连带命中
    //        退出 = 随根因码（N 族划界 / TF07）消失；**真错形态（*T + *T、"a" - "b"）不受影响**
    if scope == GATE_SCOPE_BUILD && code == EC_TB_ADD { return 1; }
    // TM04 · 位点 = tests/selfhost/test_match_exhaust.py:217（case_soft：build rc=0 + 产物照出）
    //        理由 = P3 Task 3 政策（软面登记，同 Rust unreachable-pattern 警告口径）
    //        退出 = 政策改判（引入真 warning 通道）
    if scope == GATE_SCOPE_BUILD && code == EC_TM_REDUNDANT { return 1; }
    // TK01 · 位点 = tests/selfhost/test_xcut_iface.py:234-241（case_reject soft=True：build rc=0 + 产物）
    //        理由 = P3b Task 2 索引兜底门软面政策
    //        退出 = 政策改判
    if scope == GATE_SCOPE_BUILD && code == EC_TK_INDEX { return 1; }
    // B04  · 位点 = tests/suite/ptr_arith.cr:12:8（= ELF canary 载体本人）
    //        理由 = 借用模型无末次使用（NLL 式）收缩——借用只随作用域退出释放
    //               （checker.cr:878 push / :884-915 pop）
    //        退出 = 裁-FC-3 取 (c)（块包裹修法）或 (i)（实现借用收缩）后撤
    if scope == GATE_SCOPE_BUILD && code == EC_B_USE_WHILE_BORROWED { return 1; }
    // ── scope = CHECK（3 条；**本批对 build/gate 无效，仅登记**）────────────
    // 维护者 2026-09-14 裁（裁-FC-1 = (C) 终局）：check 面 rc 规则不消费本表 ⇒ 本 3 条对判定
    // **惰性**；保留 = 登记（T1 would_block.tsv 的 34 条 check 面命中即其证据）+ 若将来另裁 (B)
    // 时的单点开关。**(B) 不是活选项**——不得据此实现活分支。
    // N01/N06/N11 · 位点 = 25 档库单元单独 check（t2 1 + t3 13 + t4 10 + t1 1）
    //        理由 = concat 供货语境缺失（非独立编译单元），check rc=1 为既有语义
    //        退出 = 口径固定
    if scope == GATE_SCOPE_CHECK && code == EC_N_UNDEFINED { return 1; }
    if scope == GATE_SCOPE_CHECK && code == EC_N_FUNC { return 1; }
    if scope == GATE_SCOPE_CHECK && code == EC_N_DUPLICATE { return 1; }
    return 0;   // 默认：不豁免（= 阻断）
}
