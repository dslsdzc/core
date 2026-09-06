// === corearch.cr ===
// Backend: .ccr → ELF/assembly/SO
// Supports: --elf (static), --shared (DSO), --link (dynamic linking)

fn init_backend_arrays() {
    g_x86_var_count = 0; g_x86_stack_size = 0; g_x86_func_idx = 0; g_x86_is_enum_count = 0;
    g_x86_var_cap = 0; g_x86_is_enum_cap = 0; g_stack_map = ""; }

fn split_links(val: string) {
    sl := str_len(val); start : ., mut = 0; i : ., mut = 0;
    loop { if i > sl { break; }
        if i == sl || load8(val, i) == 44 {
            if i > start { p := str_sub(val, start, i - start); ctx_add_so(p); }
            start = i + 1; }
        i = i + 1; } }

fn corearch_main() -> int {
    cli_init("corearch", "Core architecture backend");
    cli_flag_bool("elf", "", "Output ELF binary (default)");
    cli_flag_bool("shared", "", "Output shared library (.so)");
    cli_flag_bool("static", "", "Static linking (embed runtime)");
    cli_flag("link", "l", "Comma-sep .so files, or 'auto' for ~/.core/lib/");
    cli_flag("output", "o", "Output path");
    cli_flag("opt-level", "O", "Optimization level (0-3, default=0)");
    cli_flag("table", "", "HIT table file (load & emit mapped ops through it)");
    cli_flag_bool("dump-events", "", "Dump lowered HIT event stream + const pool");

    if cli_parse() != 0 { return 1; }
    // M2-1：--table × --link/--shared 显式拒绝——表模式池 mov [rip+disp] 的 disp
    // 由 elf.cr 按池槽回填，链接路径（ctx 重布局重定位用户代码段）下指向未经
    // 测试（M1 计划偏差 #2）。显式拒绝（stderr + exit 1）优于未测组合。
    // 测试断言见 tests/selfhost/test_hit_table.py:test_reject_table_with_link_shared。
    if str_len(cli_get("table")) > 0 {
        if cli_has("shared") != 0 || cli_has("link") != 0 || str_len(cli_get("link")) > 0 {
            em := "error: --table cannot be combined with --link/--shared (pool mov rip disp untested under ctx relayout)\n";
            syscall3(1, 2, em, str_len(em));
            return 1; } }
    g_opt_level = 0;
    ol : ., mut = cli_get("opt-level");
    if str_len(ol) > 0 { g_opt_level = str_int(ol); if g_opt_level > 3 { g_opt_level = 3; } if g_opt_level < 0 { g_opt_level = 0; } }
    // --table（M1 Task 2）：load 成功 → 表模式继续（表映射 op 走 emit_instr_tabled，
    // 未映射落旧路径 = 混合模式）；失败即退出。load 成功打印计数供测试断言。
    tbl : ., mut = cli_get("table");
    if str_len(tbl) > 0 {
        if load_hit_table(tbl) != 0 { return 1; }
        g_hit_tabled_count = 0;
        print("hit table loaded: ");
        print_i(g_hit_event_count);
        println(" events");
    }
    if cli_arg_count() < 1 {
        println("usage: corearch <file.ccr> [options]");
        println("  --elf           ELF binary (default: dynamic)");
        println("  --static        static linking (embed runtime)");
        println("  --shared        shared library (.so)");
        println("  --link auto     link ~/.core/lib/*.so (default)");
        println("  --link s1,s2   link specific .so files");
        println("  -o FILE         output path");
        println("  --table FILE    load HIT table; emit mapped ops through it (M1: int sub)");
        println("  --dump-events   dump lowered HIT event stream + const pool");
        return 1; }

    src_path := cli_arg(0);
    fd := syscall3(2, src_path, 0, 0);
    if fd < 0 { print("error: cannot open "); println(src_path); return 1; }
    fsize := syscall3(8, fd, 0, 2);
    syscall3(8, fd, 0, 0);
    if fsize < 36 { syscall3(3, fd, 0, 0); println("error: invalid .ccr file size"); return 1; }
    buf := alloc(fsize + 1);
    nread := syscall3(0, fd, buf, fsize);
    syscall3(3, fd, 0, 0);
    if nread != fsize { println("error: cannot read"); return 1; }
    r := load_ccr(buf, fsize);
    if r != 0 { println("error: invalid .ccr file"); return 1; }
    init_backend_arrays();

    // --table（M1 Task 3）：表模式 → 先降低（IR 直线子集 → 事件流 + 常量池）。
    // 超子集 op → 'needs more events' 错误 exit 1（发射前拒绝）；成功 → 事件流
    // 供 emit_instr_tabled 消费（elf.cr 发射循环不变）。--dump-events 调试 dump。
    dump_ev : ., mut = cli_has("dump-events");
    if hit_table_active() != 0 {
        if hit_lower_program() != 0 { return 1; }
        if dump_ev != 0 {
            print("hit events lowered: "); print_i(g_hit_ev_count); println("");
            ei : ., mut = 0;
            loop {
                if ei >= g_hit_ev_count { break; }
                ev_id := hit_ev_id(ei);
                es := hit_event_lookup(ev_id);
                print("  ev ");
                if es < 0 { print("?"); } else { print(hit_event_name(es)); }
                print(" dst="); print_i(hit_ev_dst(ei));
                print(" s1=");
                if hit_ev_flags(ei) % 2 == 1 { print("pool"); print_i(hit_ev_s1(ei)); }
                else { print_i(hit_ev_s1(ei)); }
                print(" s2=");
                if hit_ev_flags(ei) / 2 % 2 == 1 { print("pool"); print_i(hit_ev_s2(ei)); }
                else { print_i(hit_ev_s2(ei)); }
                println("");
                ei = ei + 1; }
            print("hit pool entries: "); print_i(g_hit_pool_count); println("");
        }
    }

    emit_so := cli_has("shared");
    link_val := cli_get("link");
    out_path := cli_get("output");

    // Pure-static (no --link, not --shared): the binary must be self-contained,
    // so the backend emits g_set_curg/g_get_curg bridge stubs (rt.s is not linked).
    // With --link, the stubs stay external and resolve from core_rt.so (rt.s).
    g_x86_emit_rt_stubs = 0;
    if str_len(link_val) == 0 && emit_so == 0 { g_x86_emit_rt_stubs = 1; }

    // --shared: emit as ET_DYN
    if emit_so != 0 {
        if str_len(out_path) == 0 { out_path = "core_lib.so"; }
        g_elf_buf = alloc(16777216);
        sz := elf_gen(g_elf_buf);
        w16(g_elf_buf, 16, 3);
        fd := syscall3(2, out_path, 577, 493);
        if fd < 0 { print("error: cannot write "); println(out_path); return 1; }
        syscall3(1, fd, g_elf_buf, sz);
        syscall3(3, fd, 0, 0);
        print(" -> "); println(out_path);
        return 0; }

    // Default: ELF (static or dynamic)
    if str_len(out_path) == 0 { out_path = "a.out"; }
    g_elf_buf = alloc(16777216);

    is_static := cli_has("static");

    if str_len(link_val) > 0 {
        ctx_init();
        if str_eq(link_val, "auto") != 0 {
            // Look for core_rt.so relative to compiler binary
            sp := get_arg(0);
            sllen := str_len(sp);
            last_sl : ., mut = -1;
            sli : ., mut = 0;
            loop { if sli >= sllen { break; }
                if load8(sp, sli) == 47 { last_sl = sli; }
                sli = sli + 1; }
            if last_sl >= 0 {
                libp := str_sub(sp, 0, last_sl + 1) + "core_rt.so";
                if str_len(read_file(libp)) > 0 { ctx_add_so(libp); } }
            // Also try ./build/, ./, and ~/.core/lib/
            if str_len(read_file("./build/core_rt.so")) > 0 {
                ctx_add_so("./build/core_rt.so"); }
            else if str_len(read_file("./core_rt.so")) > 0 {
                ctx_add_so("./core_rt.so"); }
            if str_len(read_file("~/.core/lib/core_rt.so")) > 0 {
                ctx_add_so("~/.core/lib/core_rt.so"); }
        } else {
            split_links(link_val);
        }
        sz := elf_gen(g_elf_buf);
        cs : ., mut = sz - 176;
        if cs <= 0 { println("error: empty code"); return 1; }
        cd := alloc(cs);
        ci : ., mut = 0; loop { if ci >= cs { break; }
            store8(cd, ci, load8(g_elf_buf, 176+ci)); ci = ci + 1; }
        // Clear rip-relative patches in user code (they point to original BSS)
        // NOP the mov [r10],rXX that follows each lea r10,[rip+...]
        rpi : ., mut = 0;
        loop { if rpi >= g_x86_rip_patch_count { break; }
            ppos := r64(g_x86_rip_patch_pos, rpi * 8);
            if ppos >= 176 && ppos - 176 + 4 <= cs {
                w32(cd, ppos - 176, 0);
                w8(cd, ppos + 4 - 176, 144); w8(cd, ppos + 5 - 176, 144); w8(cd, ppos + 6 - 176, 144); }
            rpi = rpi + 1; }


        if is_static != 0 {
            if g_so_count > 0 {
                ctx_set_user_code(cd, cs);
                sz = ctx_emit_static(g_elf_buf, out_path);
                if sz == -2 {
                    println("error: 静态链接失败——存在无法解析的外部符号（见上方列表）");
                    return 1;
                }
            } else {
                // F16②：纯静态构建（无 .so 可查）下 extern 符号无法解析——
                // 修复前静默保留 call rel32=0 → 运行时跳入 ELF 头崩溃（rc=139）。
                if g_x86_ext_rel_count > 0 {
                    println("error: 无法解析外部符号（静态构建未链接任何运行库）：");
                    ri2 : ., mut = 0;
                    loop { if ri2 >= g_x86_ext_rel_count { break; }
                        println("  " + istr_get(r64(g_x86_ext_rel_name, ri2 * 8)));
                        ri2 = ri2 + 1; }
                    return 1;
                }
                // Pure static: write directly (rt.cr prepended by frontend)
                // 0755（493）：ELF 输出必须可执行——修复 `corec build` 输出 0644 的
                // 既有怪癖（2026-08-16 Task 6：所有测试曾被迫 chmod 兜底；.so 输出保持 0644）
                fd := syscall3(2, out_path, 577, 493);
                if fd < 0 { print("error: cannot write "); println(out_path); return 1; }                syscall3(1, fd, g_elf_buf, sz);
                syscall3(3, fd, 0, 0); }
        } else {
            // Dynamic linking: PLT/GOT
            ri : ., mut = 0; loop { if ri >= g_x86_ext_rel_count { break; }
                fn_name := istr_get(r64(g_x86_ext_rel_name, ri * 8));
                ctx_add_plt(fn_name, 0); ri = ri + 1; }
            ctx_set_user_code(cd, cs);
            sz = ctx_emit_dyn(g_elf_buf, out_path);
        }
        if sz <= 0 { println("error: linking failed"); return 1; }
    } else {
        sz := elf_gen(g_elf_buf);
        fd := syscall3(2, out_path, 577, 493);  // 0755：可执行输出（同静态路径修复）        if fd < 0 { print("error: cannot write "); println(out_path); return 1; }
        syscall3(1, fd, g_elf_buf, sz);
        syscall3(3, fd, 0, 0); }
    print(" -> "); println(out_path);
    // 表模式总结：g_hit_tabled_count = 表驱动实际发射事件条数（instr.cr 计数——
    // add 反减 = 2 事件/指令）——「events emitted」语义准确（M2-2b 改名）。
    if str_len(tbl) > 0 {
        print("hit table: "); print_i(g_hit_tabled_count); println(" events emitted");
    }
    return 0; }
