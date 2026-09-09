// === corearch.cr ===
// Backend: .ccr → ELF/assembly/SO
// Supports: --elf (static), --shared (DSO), --link (dynamic linking)

// ═══════════════════════════════════════════════════════════════════
// 注册契约最小面（内核抽取 Task 3，2026-09-10）——实例声明表 + 表驱动引导
// ═══════════════════════════════════════════════════════════════════
// 蓝图（docs/superpowers/specs/2026-09-09-corearch-rewrite-design.md §1.1③）：
// 实例 = {能力声明、资源域/代数参数、请求分派形态}，注册契约 = 内核与实例的
// 唯一耦合面（本文件 = 内核引导 + 实例注册侧）。Core 无高阶函数 → 能力声明 =
// 数据表（g_instance_decl，行 = 声明字段），表驱动分派 = 引导决策逐点查询活动
// 实例行（不设虚表/回调——查询即分派）。本任务 = 最小面：声明表 + 引导收敛
// （资源域代数参数化（判定读 g_opt_meta 的耦合）/双向契约（home 回填）= 蓝图
// 后续步骤——范围克制注，本任务不做）。
//
// 声明行字段（8 × i32；INST_DECL_STRIDE = 32，行序 = id 序）：
//   id            实例标识（INST_X86 = 0 默认实例；INST_TABLE = 1）
//   name          str_idx（str_intern 内联名——instance_lookup 查表键；有效期 =
//                  装载前引导选择期：load_ccr 会重置 g_strs 重载 .ccr STR 段，
//                  本任务无装载后读名路径——见 instance_decl_init 注）
//   opt_min/opt_max  声明优化级别窗口（语义侧职责窗口）
//   allow_table   是否接受 HIT 表输入（表管线业务门）
//   allow_link    是否允许 --link/--shared（M2-1 拒绝门）
//   needs_alloc   生产路径是否执行寄存器分配职责（级别 ≥ 2 时）
//   needs_verify  生产路径是否执行一致性自检职责（alloc 后）
//
// 表数据 = x86 实例声明 + 表模式路径声明：
//   · x86（原生路径）   ：窗口 [0,3]（现 CLI 钳制常数即该窗口值），allow_link
//                          = 1，O2 职责全声明（级别 ≥ 2 → alloc + verify——
//                          旧直写条件）。
//   · table（表模式路径雏形）：M1 表驱动直线路径 = 独立实例路径雏形（蓝图 §2
//     表裁决）。恒 O0 语义/无 O2 组合验证 = needs_alloc/needs_verify = 0 →
//     O2 职责永不执行（旧 hit_table_active 门的声明化）；--table ×
//     --link/--shared 显式拒绝保持 = allow_link = 0。注：CLI 优化级别值透传
//     （不按表窗口 [0,0] 钳制——发射侧 O1+ 帧布局沿 g_opt_level 现状保持；
//     值域钳制按实例参数化 = 蓝图后续）。
//
// 引导收敛（现三路分派 = --table×opt 门 / --opt-level / 调试 flag → 声明查询）：
// corearch_main 读 flag → instance_select()（查表选实例）→ g_active_instance
// 固定 → 拒绝门/表管线门/O2 职责门逐点查询活动实例行字段。调试 flag 通道
// （regalloc_debug_dispatch）= 请求分派形态（实例消费内核判定服务的方式）——
// 六分支顺序与输出保持（--check-regalloc 顺序保序：强制 O2 → alloc →
// 看门狗 meta_reg_assign_total → 注入钩子×3 → regalloc_verify_all → 摘要/rc）。

INST_X86 : int = 0;
INST_TABLE : int = 1;
INST_DECL_STRIDE : int = 32;    // 行 = 8 × i32（LE）
INST_OFF_ID : int = 0;
INST_OFF_NAME : int = 4;
INST_OFF_OPT_MIN : int = 8;
INST_OFF_OPT_MAX : int = 12;
INST_OFF_ALLOW_TABLE : int = 16;
INST_OFF_ALLOW_LINK : int = 20;
INST_OFF_NEEDS_ALLOC : int = 24;
INST_OFF_NEEDS_VERIFY : int = 28;

g_instance_decl : string, mut;  // 实例声明表（行 × INST_DECL_STRIDE 字节）
g_instance_count : int, mut;
g_instance_cap : int, mut;
g_active_instance : int, mut;   // 引导选中实例行（= id；instance_select 设定）

fn grow_instance_decl(needed: int) {
    if needed < g_instance_cap { return; }
    nc : ., mut = g_instance_cap * 2; if nc < 2 { nc = 2; } if nc < needed { nc = needed; }
    nb := alloc(nc * INST_DECL_STRIDE);
    _dyncpy(g_instance_decl, g_instance_cap * INST_DECL_STRIDE, nb);
    g_instance_decl = nb; g_instance_cap = nc;
}

fn instance_decl_add(id: int, name_idx: int, opt_min: int, opt_max: int,
                     allow_table: int, allow_link: int, needs_alloc: int, needs_verify: int) {
    grow_instance_decl(g_instance_count + 1);
    off : ., mut = g_instance_count * INST_DECL_STRIDE;
    w32(g_instance_decl, off + INST_OFF_ID, id);
    w32(g_instance_decl, off + INST_OFF_NAME, name_idx);
    w32(g_instance_decl, off + INST_OFF_OPT_MIN, opt_min);
    w32(g_instance_decl, off + INST_OFF_OPT_MAX, opt_max);
    w32(g_instance_decl, off + INST_OFF_ALLOW_TABLE, allow_table);
    w32(g_instance_decl, off + INST_OFF_ALLOW_LINK, allow_link);
    w32(g_instance_decl, off + INST_OFF_NEEDS_ALLOC, needs_alloc);
    w32(g_instance_decl, off + INST_OFF_NEEDS_VERIFY, needs_verify);
    g_instance_count = g_instance_count + 1;
}

fn instance_decl_init() {
    // 幂等（防重复调用——引导只调一次，注册函数最小面）。声明字段恒非负
    // （0/1/3/str idx）——r32 零扩展读安全（符号修正歧义只涉及负值）。
    // name 内联时机注：本函数跑在 load_ccr 前（引导期）——str idx 依当时
    // g_strs 内容（等值串恒同 idx——str_intern 去重，位置无关）；load_ccr
    // 重置 g_strs 重载 .ccr STR 段后这些 idx 不再指向内联名。本任务消费面
    // （instance_select）全在选择期（装载前），无装载后读名路径——届时注册
    // 校验若读名须装载后重内联（蓝图后续）。
    if g_instance_count > 0 { return; }
    instance_decl_add(INST_X86, str_intern("x86"), 0, 3, 0, 1, 1, 1);
    instance_decl_add(INST_TABLE, str_intern("table"), 0, 0, 1, 0, 0, 0);
}

fn inst_id(i: int) -> int { return r32(g_instance_decl, i * INST_DECL_STRIDE + INST_OFF_ID); }
fn inst_name(i: int) -> int { return r32(g_instance_decl, i * INST_DECL_STRIDE + INST_OFF_NAME); }
fn inst_opt_min(i: int) -> int { return r32(g_instance_decl, i * INST_DECL_STRIDE + INST_OFF_OPT_MIN); }
fn inst_opt_max(i: int) -> int { return r32(g_instance_decl, i * INST_DECL_STRIDE + INST_OFF_OPT_MAX); }
fn inst_allow_table(i: int) -> int { return r32(g_instance_decl, i * INST_DECL_STRIDE + INST_OFF_ALLOW_TABLE); }
fn inst_allow_link(i: int) -> int { return r32(g_instance_decl, i * INST_DECL_STRIDE + INST_OFF_ALLOW_LINK); }
fn inst_needs_alloc(i: int) -> int { return r32(g_instance_decl, i * INST_DECL_STRIDE + INST_OFF_NEEDS_ALLOC); }
fn inst_needs_verify(i: int) -> int { return r32(g_instance_decl, i * INST_DECL_STRIDE + INST_OFF_NEEDS_VERIFY); }

fn instance_lookup(name_idx: int) -> int {
    // 按名查行（name = str_idx，str_intern 去重 → 等值串恒同 idx）。
    // 未找到返回 -1（构造保证不触发——两行两名）。
    i : ., mut = 0;
    loop {
        if i >= g_instance_count { break; }
        if inst_name(i) == name_idx { return i; }
        i = i + 1;
    }
    return -1;
}

fn instance_select() -> int {
    // 引导选择：读 flag → 实例名 → 查表 → 行 idx（行序 = id 序 → 行 = id）。
    // 选择旗标 = --table 值存在性（与装载条件同源）；兜底 INST_X86 = 默认
    // 实例（防御性——lookup 未命中不掩构造错误，退默认路径）。
    nm : ., mut = "x86";
    if str_len(cli_get("table")) > 0 { nm = "table"; }
    r := instance_lookup(str_intern(nm));
    if r < 0 { return INST_X86; }
    return r;
}

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

// regalloc 移后端（2026-09-07）：数据面/判定调试通道随编码决策层迁入——
// 载体 = corec cir 原隐藏标志的 corearch 同名版本（load .ccr 后内存态自算，
// 载入 NOD 流 = pre-CSE 流，与 corec 原 dump 语义同源）。返回：0 = 未请求
// （正常发射路径继续）；1 = 已处理且通过；2 = 已处理且违反/失败。
// 注册契约角色（Task 3）：本函数 = 请求分派形态——实例经 flag 通道消费内核
// 判定服务（dump-entries/dump-coexist = 诊断通道；check-regalloc/inject-* =
// 判定服务 + 机器侧注入钩子）的入口。分支顺序与输出保持（行为不变）：
// --check-regalloc 保序 = 强制 O2 → alloc_registers → 看门狗
// meta_reg_assign_total → 注入钩子×3 → regalloc_verify_all → 摘要/rc。
fn regalloc_debug_dispatch() -> int {
    if cli_has("dump-entries") != 0 {
        compute_live_ranges();
        dump_entries_summary();
        return 1;
    }
    if cli_has("inject-coexist-oob") != 0 {
        compute_live_ranges();
        if inject_coexist_oob() != 0 { return 2; }
        return 1;
    }
    if cli_has("dump-coexist") != 0 {
        compute_live_ranges();
        dump_coexist_summary();
        return 1;
    }
    if cli_has("dump-regassign") != 0 {
        // 自算后逐对输出 var→reg（尊重 --opt-level 门：分配 = O2，O0/O1 → 空）
        if g_opt_level >= 2 { alloc_registers(); }
        mi : ., mut = 0;
        loop {
            if mi >= g_opt_meta_count { break; }
            mo := mi * OPT_META_STRIDE;
            if r32(g_opt_meta, mo) == OPT_KEY_REG_ASSIGN {
                cnt := r32(g_opt_meta, mo + 8);
                di : ., mut = 0;
                loop {
                    if di >= cnt { break; }
                    print("regassign: "); print(int_str(r32(g_opt_meta, mo + 12 + di * 8)));
                    print(" "); println(int_str(r32(g_opt_meta, mo + 16 + di * 8)));
                    di = di + 1;
                }
            }
            mi = mi + 1;
        }
        return 1;
    }
    if cli_has("check-regalloc") != 0 {
        saved_opt := g_opt_level;
        g_opt_level = 2;
        alloc_registers();
        // 看门狗行：REG_ASSIGN 对总数（rc>0 = 寄存器真实分配实证，防回退——
        // 分配在 corearch 自算后计数 = 自算块；.ccr 不再带 corec 分配结果）
        print("regalloc-assign: "); print(int_str(meta_reg_assign_total()));
        println(" pairs");
        if cli_has("inject-home-conflict") != 0 { inject_home_conflict(); }
        if cli_has("inject-reg-conflict") != 0 { inject_reg_conflict(); }
        if cli_has("inject-read-gap") != 0 { inject_read_gap(); }
        nv := regalloc_verify_all();
        g_opt_level = saved_opt;
        print("regalloc-consistency: funcs "); print(int_str(g_ir_func_count));
        print(" violations "); println(int_str(nv));
        if nv != 0 { return 2; }
        return 1;
    }
    return 0;
}

// --dump-objects 调试通道（内核完备 Task 1 测试载体）：实例侧薄通道——
// 经内核对象面访问器（nod_op/nod_dest/nod_s1-3/nod_tk + nod_edge_first/count
// + v7_edge_to/v7_edge_kind——ent_kernel.cr，内核零新增）输出载入对象：逐
// 节点语义字段 + 邻接域 + 配方出边遍历（邻接索引区间
// [first, first+count) 内逐边——v7_edge_to/kind 读 EDG 缓冲）。
// 行格式契约见 tests/selfhost/test_ccr_v7.py:parse_object_dump。
fn dump_object_surface() {
    print("objects: "); print_i(g_v7_nod_count); println("");
    ni : ., mut = 0;
    loop {
        if ni >= g_v7_nod_count { break; }
        print("nod "); print_i(ni);
        print(" op "); print_i(nod_op(ni));
        print(" dest "); print_i(nod_dest(ni));
        print(" s1 "); print_i(nod_s1(ni));
        print(" s2 "); print_i(nod_s2(ni));
        print(" s3 "); print_i(nod_s3(ni));
        print(" tk "); print_i(nod_tk(ni));
        print(" fe "); print_i(nod_edge_first(ni));
        print(" ec "); print_i(nod_edge_count(ni));
        println("");
        last : ., mut = nod_edge_first(ni) + nod_edge_count(ni);
        ej : ., mut = nod_edge_first(ni);
        loop {
            if ej >= last { break; }
            print("edge "); print_i(ni);
            print(" to "); print_i(v7_edge_to(ej));
            print(" kind "); println_i(v7_edge_kind(ej));
            ej = ej + 1;
        }
        ni = ni + 1;
    }
}

fn corearch_main() -> int {
    cli_init("corearch", "Core architecture backend");
    cli_flag_bool("elf", "", "Output ELF binary (default)");
    cli_flag_bool("shared", "", "Output shared library (.so)");
    cli_flag_bool("static", "", "Static linking (embed runtime)");
    cli_flag("link", "l", "Comma-sep .so files, or 'auto' for ~/.core/lib/");
    cli_flag("output", "o", "Output path");
    cli_flag("opt-level", "O", "Optimization level (0-3, default=0) — O2: load 后自算寄存器分配 + 一致性自检（emit 前，违反 = 编译错误）");
    cli_flag("table", "", "HIT table file (load & emit mapped ops through it)");
    cli_flag("hit-events-file", "", "Hidden debug: inject text event stream file (dump-events inverse; skips lowering — template compare test channel, M2a Task 2)");
    cli_flag_bool("dump-events", "", "Dump lowered HIT event stream + const pool");
    cli_flag_bool("dump-table", "", "Hidden debug: dump loaded HIT event/proj/step/runtime state (schema v2 read-back test channel)");
    // regalloc 移后端：数据面/判定调试通道（corec cir 原载体随迁——同名 flag）
    cli_flag_bool("dump-entries", "", "Hidden debug: versioned entries summary (regalloc 移后端 test channel)");
    cli_flag_bool("dump-coexist", "", "Hidden debug: coexistence summary (regalloc 移后端 test channel)");
    cli_flag_bool("dump-regassign", "", "Hidden debug: per-pair var->reg dump after O2 self-alloc (regalloc 移后端 test channel)");
    cli_flag_bool("check-regalloc", "", "Hidden debug: O2-forced alloc + regalloc consistency self-check (regalloc 移后端 test channel)");
    cli_flag_bool("inject-home-conflict", "", "Hidden debug: inject coexisting entries onto same home slot, then verify (test hook)");
    cli_flag_bool("inject-reg-conflict", "", "Hidden debug: inject fake var->reg pair colliding with a real one, then verify (test hook)");
    cli_flag_bool("inject-read-gap", "", "Hidden debug: truncate last version interval to def point, then verify (test hook)");
    cli_flag_bool("inject-coexist-oob", "", "Hidden debug: probe entries_coexist with OOB indices (GC-1 test hook)");
    cli_flag_bool("dump-objects", "", "Hidden debug: dump loaded NOD/EDG semantic objects via object-surface accessors (内核完备 Task 1 test channel)");

    if cli_parse() != 0 { return 1; }
    // 注册契约引导（Task 3）：读 flag → 查表选实例（--table 值存在 → 表模式
    // 路径实例；否则 x86 原生实例）——后续拒绝门/表管线门/O2 职责门逐点查询
    // g_active_instance 声明行字段（表驱动分派，行为不变）。
    instance_decl_init();
    g_active_instance = instance_select();
    // 拒绝门（M2-1 显式拒绝保持——声明化）：表实例声明 allow_link = 0 →
    // 不接受 --link/--shared。表模式池 mov [rip+disp] 的 disp 由 elf.cr 按池槽
    // 回填，链接路径（ctx 重布局重定位用户代码段）下指向未经测试（M1 计划
    // 偏差 #2）。显式拒绝（stderr + exit 1）优于未测组合。消息/顺序不变。
    // 测试断言见 tests/selfhost/test_hit_table.py:test_reject_table_with_link_shared。
    if inst_allow_link(g_active_instance) == 0 {
        if cli_has("shared") != 0 || cli_has("link") != 0 || str_len(cli_get("link")) > 0 {
            em := "error: --table cannot be combined with --link/--shared (pool mov rip disp untested under ctx relayout)\n";
            syscall3(1, 2, em, str_len(em));
            return 1; } }
    g_opt_level = 0;
    ol : ., mut = cli_get("opt-level");
    if str_len(ol) > 0 {
        g_opt_level = str_int(ol);
        // 值域钳制窗口 = x86 实例声明窗口 [0,3]（默认实例——旧钳制常数即该
        // 窗口值；级别消毒与实例选择正交）。表实例声明窗口 [0,0] = 语义侧
        // 职责窗口（恒 O0——经 needs_alloc/needs_verify = 0 的职责门强制），
        // CLI 级别值透传发射侧（O1+ 帧布局沿 g_opt_level 现状保持）。
        if g_opt_level > inst_opt_max(INST_X86) { g_opt_level = inst_opt_max(INST_X86); }
        if g_opt_level < inst_opt_min(INST_X86) { g_opt_level = inst_opt_min(INST_X86); }
    }
    // --table（M1 Task 2）：load 成功 → 表模式继续（表映射 op 走 emit_instr_tabled，
    // 未映射落旧路径 = 混合模式）；失败即退出。load 成功打印计数供测试断言。
    // 装载条件 = 实例选择同源旗标（选择已把表实例置活动——allow_table = 1）。
    tbl : ., mut = cli_get("table");
    if str_len(tbl) > 0 {
        if load_hit_table(tbl) != 0 { return 1; }
        g_hit_tabled_count = 0;
        print("hit table loaded: ");
        print_i(g_hit_event_count);
        println(" events");
        // --dump-table（schema v2 读回测试通道）：加载态 proj/步/runtime 结构
        // dump（hit.cr helper 只读表状态）。测试断言见
        // tests/selfhost/test_hit_table.py:test_v2_fixture_multi_step_sections。
        if cli_has("dump-table") != 0 { hit_dump_table_state(); }
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

    // 内核完备 Task 1（调度重建移实例）：loader 只产语义对象——线性流
    // （g_ir_instrs）重建 = 实例事务（build_linear_schedule，regalloc.cr——
    // 重建段自 load_ccr 纯搬移，产物逐字节一致），load 成功后、分派/发射前
    // 必须调用（ELF 发射/dump-entries/check-regalloc 全消费线性流）。
    build_linear_schedule();

    // --dump-objects（Task 1 测试通道——对象面配方可读断言载体，见
    // tests/selfhost/test_ccr_v7.py:test_v7_object_surface_recipe_readable）：
    // dump 分支在重建后、发射前（返回 0——不触发 O2 职责门/发射路径）。
    if cli_has("dump-objects") != 0 {
        dump_object_surface();
        return 0;
    }

    // regalloc 移后端（R1a/R3，2026-09-07）：O2 分配 + 一致性判定归位 corearch
    // ——load 后自算自检（.ccr 不再传 REG_ASSIGN/ENT，D-1=Y）。违反 = 编译错误。
    // O2 职责门（Task 3 声明化）：alloc + verify = 实例声明能力——needs_alloc/
    // needs_verify（x86 = 1/1 → 级别 ≥ 2 时执行；表实例 = 0/0 → O2 组合验证
    // 永不执行——M1 表驱动直线路径恒 O0 语义，与旧 hit_table_active 门等价：
    // 此刻实例 = 装载态恒等——--table 装载成功才达此处）。
    dd := regalloc_debug_dispatch();
    if dd == 1 { return 0; }
    if dd == 2 { return 1; }
    if g_opt_level >= 2 && inst_needs_alloc(g_active_instance) != 0 {
        alloc_registers();
        if inst_needs_verify(g_active_instance) != 0 {
            // 判定：成功静默（自检通过不打扰构建输出）；违反 = 诊断已打印 + 拦截
            if regalloc_verify_all() != 0 { return 1; }
        }
    }

    // --table（M1 Task 3）：表模式 → 先降低（IR 直线子集 → 事件流 + 常量池）。
    // 超子集 op → 'needs more events' 错误 exit 1（发射前拒绝）；成功 → 事件流
    // 供 emit_instr_tabled 消费（elf.cr 发射循环不变）。--dump-events 调试 dump。
    // --hit-events-file（M2a Task 2 注入测试通道）：文本事件流文件取代降低——
    // 构造 g_hit_ev_stream/g_hit_pool + 指令映射，跳过 lower 直接 emit。测试专用
    // （真实构建路径不启用；与 --inject-* 通道同哲学）。须与 --table 同用。
    // 表管线业务门（Task 3 声明化）= 活动实例声明 allow_table（表实例 = 1）：
    // 此刻实例与装载态恒等（--table 装载成功才达此处——load 失败已提前退出，
    // 未给 --table 则实例 = x86 且无任何装载路径）——旧 hit_table_active() 门
    // 的声明等价物。
    dump_ev : ., mut = cli_has("dump-events");
    inj_path : ., mut = cli_get("hit-events-file");
    if str_len(inj_path) > 0 && inst_allow_table(g_active_instance) == 0 {
        println("error: --hit-events-file needs --table (events emit through table projections)");
        return 1; }
    g_hit_inject_active = 0;
    if inst_allow_table(g_active_instance) != 0 {
        if str_len(inj_path) > 0 {
            g_hit_inject_active = 1;
            if hit_inject_events(inj_path) != 0 { return 1; }
        } else {
            if hit_lower_program() != 0 { return 1; }
        }
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
            // 池值行（M2a Task 2：注入文件 pool 行的 dump 逆面——值域随槽序）
            print("hit pool entries: "); print_i(g_hit_pool_count); println("");
            if g_hit_pool_count > 0 {
                print("hit pool:");
                hpi : ., mut = 0;
                loop {
                    if hpi >= g_hit_pool_count { break; }
                    print(" "); print_i(r64(g_hit_pool, hpi * 8));
                    hpi = hpi + 1; }
                println(""); }
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
    // 注入通道（测试专用）：事件须全部经表发射——预检拒绝（已打印）会使计数
    // 短于注入行数 = 注入文件错误 → exit 1（不静默落旧路径掩盖）。
    if g_hit_inject_active != 0 && g_hit_tabled_count != g_hit_ev_count {
        print("error: HIT events: "); print_i(g_hit_tabled_count);
        print(" of "); print_i(g_hit_ev_count);
        println(" events emitted via table (injection file event not emittable)");
        return 1; }
    return 0; }
