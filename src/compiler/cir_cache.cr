// === cir_cache.cr ===
// Incremental compilation cache: per-function .cir snapshot save/load.
// Saves the dataflow graph state (DF nodes, edges, IR instrs, vars, strings)
// for one function. On cache hit, restores the state directly into the
// compiler's global arrays.

// Magic header for .cir cache files
// v12: invalidate older call flags, generic cloning/indexing, and yield ASTs.
// v13: persist nested SG region metadata in per-function cache files.
// v14: 幽灵边播种修复（v7 Task 0 注 A 裁决）——快照内未产出 var 的 producer
//      槽语义随 grow_df_arrays 播种变更为恒 -1；旧快照（含 0 槽幽灵边 + 恢复
//      路径不重播种）必须失效——cache miss = 无害重建。
// 注意：magic 位模式 = C1C1…（bytes）；以 signed 十进制书写——hex 字面量
// 0xC1C1C1C1C1C1C1C1 超 i64 上界，会被词法溢出守卫拒绝（见 lexer P2 修复）。
// v15（效应/纯度修正 Task 1）：state 链（kind=1）不再随函数即时连接——改由
// df_replay_state_chain 在 IR 生成结束后对成品图统一重建 ⇒ 快照里不再需要
// （也不应）持久化链边。旧快照带链边 + 重建再连一次 = 重复链边，必须失效
// （cache miss = 无害重建）。
// v16（TODO #2026-09-10-4 修复）：参数槽区 16→64（dyn_arr.cr OFF_FI_PARAM_TYPES 扩容）——
// 修复前编译 ≥18 形参函数时，越界写把 return_type/ast_node 踩坏，**且该坏
// 状态已被写入 .cir 快照**（IR 体 46→28 instrs 等）。缓存键 = 源路径::函数名 +
// 纯 AST 指纹 ⇒ 同源文件在修复前后指纹相同 → 旧快照会被命中，把坏 IR 原样
// 恢复成活产物（rc=0）——正是本修复要消灭的静默类。bump 使旧条目整体失效
// （cache miss = 无害重建）。注意：本条只治「本仓旧快照」，键缺编译器身份
// 的根因另见 TODO #2026-09-10-1。
// v17（TODO #2026-09-10-1 修复）：头部新增**编译器身份**字段（见下）。布局 = magic/ver/
// identity/fp/sig/name_len/name…（相对 v16 整体后移 8B），旧条目读取即错位 ⇒
// 必须 bump。v16→v17 的手工 bump 本身只覆盖「本仓旧条目」；身份字段起自动
// 覆盖面（重建即失效）。
// [曾议 v18 而未 bump]（R2 P4 Task 4 / D15 的实测修正，见下）：DF 节点内存记录
// 64 → 72B 新增该项槽，但**快照盘记录仍 64B/节点**（第 9 槽不落盘）⇒ 格式
// 与布局零变化 ⇒ 版本位不动。
// 计划 D15 原写「`.cir` 快照入项槽并 CIR_CACHE_VER 17→18」，其前提 = 「不入槽
// 则命中恢复路径与冷路径分歧」。**该前提实测不成立且方向相反**（本任务新增
// `cir --dump-tk-terms` 通道实测，ptr_arith）：
//   冷路径 terms=13 / bad_term=0；暖路径 terms=10 / **bad_term=329**
// ——暖路径所有恢复来的项引用域外。根因 = 项表（g_type_terms）是**进程内**
// 内容寻址表，emit 期按需追加（本语料冷路径 emit 新增 3 项）⇒ 快照里的项索引
// 只在**写侧进程**的索引空间里成立；暖路径若跳过 emit（全命中）则项表更短，
// 恢复出的索引整体悬空——若日后有消费者，读到的就是错项（或越界读）= 正是
// 本批要消灭的静默类。**且**「把 f(tk) 的纯函数值与其入参并存于同一记录」=
// 第二真源（本仓反复治过的病），分歧时盘面值静默胜出。
// 修正（根因级）= **不落盘，装载时按 emit 的等价时点重派生**：load_cir_cache
// 逐节点（节点序 = emit 序）调 sh_tk_split(opcode, tk)——opcode/派生码本就
// 在盘记录内（单源），派生值与冷路径**同项同索引**（项表按同序追加 ⇒ 两进程
// 索引空间对齐，由 T4 用例的冷/暖 dump 逐行相等断言锁住）。
// R2 P5 Task 2（D19 单槽化）后：盘上仍只有**一个** tk 字段（= 派生码，由
// sh_dfn_code_of_slots 产出），装载侧由它同时重派生**两槽**（项引用 + 辅码）——
// 盘面布局/版本位与 P4 逐字节相同（单槽化只在内存语义面）。
CIR_CACHE_MAGIC : int = -4485090715960753727;
// 20：缓存膨胀批（2026-09-17 · `plans/2026-09-17-cir-cache-bloat.md`）——**段粒度按函数收窄 +
//     边端点改相对 id + 尾部基线见证 trailer**（结构变更，非语义变更）：
//       ① **边段只写本函数** `[edge_start, g_df_edge_count)`（写侧 O(1) 取界：df_begin_func 记
//          `g_df_func_edge_start`），盘记录 24B/条 = {rel_from, rel_to, kind}（相对 node_start 的
//          **有符号**偏移；`next` 不落盘，装载期由 df_add_edge_kind 前插重建）。旧格式写**全图边表**
//          ⇒ 全缓存 O(函数数 × 累计图)：实测单条 2.38MB 中 98.6% 是别人的边、全档 97.0% 的字节是边记录。
//       ② 节点盘记录**仍 64B**（裁-4），但 `first_edge/edge_count` **装载期不信任**：归零后由重放重建，
//          盘值降格为**逐节点见证**（不符 ⇒ miss）。
//       ③ 尾部 +16B trailer = {var_start, node_start}（**基线见证**）：装载期**先校验后恢复**
//          （var_start 恒校验；node_start 仅当快照含越界 rel 时条件见证）。trailer 定位于**结构扫描
//          终点**：`p + 16 <= dlen` 才可读（**截断** ⇒ fail-closed miss，P4：不得落 139/垃圾），
//          但**容忍尾随字节**（既有契约：装载历来忽略条目尾随字节；`test_cir_warm_path` D5 补零
//          条目仍须命中——本批首版误用 `dlen−16` 定位曾使 D5 红，既有判据网抓到的）。
//     **为什么必须 bump**：旧条目按「绝对节点 id + 全量覆盖」写 ⇒ 新装载器读到的边段计数/步长与
//     旧格式完全不同（旧计数 = 全图边数、步长 32B/含 next；新 = 本函数边数、24B/无 next）⇒ 命中旧
//     条目即「错图」而非「错值」，且与 #8 事故同族（坏 IR 原样复活成产物 rc=0）。cache miss = 无害重建。
//     与前 19 代同族（每一代都是「快照携带了会随进程态/格式漂移的量」）；`.ccr` 侧不 bump（交付格式）。
// 19：批 5（opt-dex，2026-09-17 · TODO #2026-09-16-29）——**可选 dex（`dex?`）载荷形式规范化**：
//     写点门/槽型/形参槽/返回门/读点定型一律改「按**声明面**定形式」（G1 裁决 = scaled；见
//     ir_gen.cr 的 dex_opt_type_node/dex_opt_slot_ti）。**旧快照里 `dex?` 的槽仍是修复前的形态
//     （未规范化的装箱 bits / 读槽 TI_INT），与新语义不等价** ⇒ 命中旧条目会把「坏 IR」原样
//     复活成产物（rc=0 的静默类）⇒ bump 使旧条目整体失效，cache miss = **无害重建**。
//     与 18 代同族（#2026-09-16-16 批 2 的先例）；`.ccr` 侧仍不 bump（交付格式、段布局与
//     字段序未动，内容仅 `dex?` 程序变）。
// 18：TODO #2026-09-16-16「聚合读丢型」批 2 —— 聚合读结果槽型由 `TI_INT` 改为**声明面形式**
//     （dex 声明 ⇒ `TI_DEX_S`；见 ir_gen.cr 的 agg_*_read_form）。**旧快照里读槽型 = `TI_INT`，
//     与修复后语义不等价** ⇒ 命中旧条目会把「丢型」的坏 IR 原样复活成产物（rc=0 的静默类）
//     ⇒ bump 使旧条目整体失效，cache miss = **无害重建**。与 TODO #2026-09-10-4（缓存键缺编译器身份）
//     同族；`.ccr` 侧不 bump（交付格式、无快照复用语义），但**内容会变**（dex 程序）。
CIR_CACHE_VER   : int = 20;

g_cir_write_buf : string, mut;
g_cir_write_pos : int, mut;
g_cir_write_cap : int, mut;

// === 编译器身份（TODO #2026-09-10-1）===
// 现象：缓存键 = 源路径::函数名 + 纯 AST 指纹（func_fingerprint/sig_fingerprint
// 只覆盖目标源），**无编译器身份分量**。编译器二进制重建后，字符串驻留序
// （g_strs 的 intern 序）与快照内索引（var 的 irv_name / 指令 s1..s3 / 名字
// 索引）不再一致，而键与指纹一字未变 ⇒ 旧条目被命中，旧序索引被当活产物
// 使用（dump 变量名缺失/错位，rc=0 静默）。CIR_CACHE_VER 的手工 bump 是
// 现状兜底，已经忘记过两次（14→15、15→16）——本字段即为其自动化。
//
// 修复 = 头部写入**运行中编译器自身 ELF 的内容哈希**（/proc/self/exe 全文件
// 单趟哈希），装载时比对：不等 = cache miss = 无害重建。不变量：**任何改变
// 前端语义的重建都改变身份**（二进制变了，哈希必变）。
//
// 为什么是「运行中二进制自哈希」而非「构建期源哈希常量」：
//   * 自哈希捕获**全部**决定编译器语义的输入——src/compiler 清单 + 其顺序 +
//     bootstrap Python 工具链 + rt.s + as/ld——源哈希只是其中一部分的代理，
//     漏掉任何一项就复现本单要消灭的静默类；
//   * 无需构建管道改动/生成文件：其它编译路径（tests 直编 src/compiler、
//     full-bootstrap 的 corec2/corec3）不因缺一个生成文件而断；
//   * 自哈希取内容而非路径 ⇒ 「同内容二进制」判为同身份（正确：语义同）。
// 依赖（实测成立，判据在案）：本仓 ELF 构建逐字节确定（两连建 cmp IDENTICAL
// ——本单修复前后两侧均实测；run.sh full-bootstrap 亦以 cmp 为判据）⇒ 同源
// 重建身份不变，缓存命中面不退化。若某日构建变为非确定，症状 = 缓存恒 miss
// （性能面，非正确性面），由该判据暴露。
// 退化路径（无 procfs / 读取失败）：身份 = 0 ⇒ 两端点均关缓存，每次全量重建
// ——绝不落「身份 0」条目（否则两个同样取不到身份的编译器互相当作同身份命中，
// 正是本单静默类复活）。实测：`unshare -rm` 把 tmpfs 挂到 /proc 掩掉 procfs 后
// 编译 rc=0 且 **零条目落盘**；已删除（unlink）的编译器二进制反而仍可经
// /proc/self/exe 打开取到原 inode 内容（身份照常成立）。
//
// 与 CIR_CACHE_VER 的分工：VER = 手工粗粒度（格式/语义生成代，例如「快照里
// 不该有链边」这类**格式**变更）；身份 = 自动细粒度（编译器内容驱动，覆盖
// 「同格式、不同前端行为」）。两者都必须匹配才命中——格式变更手工 bump，
// 行为变更由身份自动接管，不必再记得 bump。
g_cir_compiler_id       : int, mut = 0;
g_cir_compiler_id_ready : int, mut = 0;

// 运行中编译器 ELF 的内容哈希（memoized）。0 = 取不到身份（无 procfs /
// 读取失败 / 空文件）——调用方按「身份不可证」处理（关缓存，见两端点）。
fn cir_compiler_identity() -> int {
    if g_cir_compiler_id_ready != 0 { return g_cir_compiler_id; }
    g_cir_compiler_id_ready = 1;
    g_cir_compiler_id = cir_hash_running_binary();
    return g_cir_compiler_id;
}

// 单趟乘加哈希（FNV-1 64-bit 常数；本语言无 XOR 运算符——与 ir_gen.cr
// func_fingerprint 同族写法）。8 字节字一步（load64 = 单条未对齐小端读；
// corec 目标面即 x86-64 小端，字节序不影响「确定性」这一唯一要求）+ 余尾
// 逐字节 + 末尾混入总长（长度不同必不同）。
// 采样（本单判据，热身缓存，build/corec 1.32MB）：逐字节形中位 +11.6ms/次
// （小文件编译 17→29ms）→ 8 字节字粒度后 min 基准 +2~3ms/次（同件 15→17ms；
// 大件 src/compiler/main.cr 热身 5.5s 下不可分——采样噪声大于该值）。代价只在
// **真正走到缓存**的进程里付一次（memoized：strace 实测热身全量编译 1 次
// open("/proc/self/exe")），身份不可得/无条目可查时不付。
// 非密码学用途（对侧不设敌手）：它要区分的是「同一编译器的两次构建」，随机
// 差异撞上 2^-64 忽略；能写缓存文件的对手本来就能写任意载荷。
fn cir_hash_running_binary() -> int {
    fd := syscall3(2, "/proc/self/exe", 0, 0);  // open(O_RDONLY)
    if fd < 0 { return 0; }
    buf := alloc(65536);
    h : ., mut = -3750763034362895579;  // FNV-1 64 offset basis（signed i64）
    total : ., mut = 0;
    loop {
        n := syscall3(0, fd, buf, 65536);  // read(fd, buf, 65536)
        if n <= 0 { break; }
        i : ., mut = 0;
        loop {
            if i + 8 > n { break; }
            h = h * 1099511628211 + load64(buf, i);
            i = i + 8;
        }
        loop {
            if i >= n { break; }
            h = h * 1099511628211 + load8(buf, i);
            i = i + 1;
        }
        total = total + n;
    }
    r1 := syscall3(3, fd, 0, 0);  // close(fd)
    if total == 0 { return 0; }
    h = h * 1099511628211 + total;
    return h;
}

// Count non-function regions belonging to one function. The function SG is
// recreated by df_begin_func on a cache hit, so only nested records are stored.
fn cir_cache_sg_count(node_start: int, node_count: int) -> int {
    count : ., mut = 0;
    si : ., mut = 0;
    loop {
        if si >= g_sg_count { break; }
        kind := r64(g_sgs, si * ESZ_SG + OFF_SG_KIND);
        nstart := r64(g_sgs, si * ESZ_SG + OFF_SG_NSTART);
        if kind != SG_FUNC && nstart >= node_start && nstart < node_start + node_count {
            count = count + 1;
        }
        si = si + 1;
    }
    return count;
}

// Encode a region parent as an index within the serialized nested-region
// list. -1 denotes the function SG recreated by df_begin_func.
fn cir_cache_sg_parent(sg_idx: int, node_start: int, node_count: int) -> int {
    parent := r64(g_sgs, sg_idx * ESZ_SG + OFF_SG_PARENT);
    if parent < 0 { return -1; }
    parent_kind := r64(g_sgs, parent * ESZ_SG + OFF_SG_KIND);
    parent_start := r64(g_sgs, parent * ESZ_SG + OFF_SG_NSTART);
    if parent_kind == SG_FUNC && parent_start == node_start { return -1; }

    local : ., mut = 0;
    si : ., mut = 0;
    loop {
        if si >= sg_idx { break; }
        kind := r64(g_sgs, si * ESZ_SG + OFF_SG_KIND);
        nstart := r64(g_sgs, si * ESZ_SG + OFF_SG_NSTART);
        if kind != SG_FUNC && nstart >= node_start && nstart < node_start + node_count {
            if si == parent { return local; }
            local = local + 1;
        }
        si = si + 1;
    }
    return -1;
}

// Save one function's DFG state to a .cir cache file.
// path: full file path (including .core/cache/cir/ prefix)
// source_fi: source FuncInfo index used for AST fingerprints
// ir_fi: compact IR function index used for IR/DFG ranges
// Returns 0 on success, -1 on failure.
fn save_cir_cache(path: string, source_fi: int, ir_fi: int) -> int {
    // 身份不可证（无 procfs 等）⇒ 绝不落盘：否则身份 0 的条目会被另一个同样
    // 取不到身份的编译器当作「同身份」命中——即本单的静默类在退化路径复活。
    // 关缓存 = 每次都全量重建 = 正确性优先（见 cir_compiler_identity 头注）。
    cid := cir_compiler_identity();
    if cid == 0 { return -1; }

    fd := syscall3(2, path, 577, 420);  // O_WRONLY|O_CREAT|O_TRUNC, 0644
    if fd < 0 { return -1; }

    // Compute fingerprint
    fn_node := fi_ast_node(source_fi);
    fp := func_fingerprint(fn_node);
    sig := sig_fingerprint(fn_node);
    name_ni := r64(g_ir_func_name_idx, ir_fi * 8);
    name := istr_get(name_ni);
    name_len := str_len(name);

    var_start := r64(g_ir_func_var_start, ir_fi * 8);
    var_count := r64(g_ir_func_var_count, ir_fi * 8);
    node_start := r64(g_df_func_node_start, ir_fi * 8);
    node_count := r64(g_df_func_node_count, ir_fi * 8);
    instr_start := r64(g_ir_func_instr_start, ir_fi * 8);
    instr_count := r64(g_ir_func_instr_count, ir_fi * 8);

    // Serialize in memory and issue one write. The previous per-field writes
    // made a full self-host build perform millions of syscalls on its cache.
    total_size : ., mut = 48 + name_len;  // v17 头部 = magic/ver/identity/fp/sig/name_len
    total_size = total_size + 8 + var_count * 24;
    // 节点盘记录 = 8 字段 × 8B = 64B（R2 P5 Task 2 起 = {op,dest,s1,s2,s3,**派生码**,
    // first_edge,edge_count}；第 9 槽 OFF_DF_AUX 不落盘——两槽装载时按派生码重派生，
    // 见文件头 v18 注）。
    total_size = total_size + 8 + node_count * 64;
    // 缓存收窄批（CIR_CACHE_VER 20）：**只写本函数的边**（[edge_start, g_df_edge_count)），
    // 盘记录 24B/条 = {rel_from, rel_to, kind}（相对 node_start 的**有符号**偏移；`next` 不落盘，
    // 装载期由 df_add_edge_kind 前插重建）。旧格式写**全图边表** ⇒ 全缓存 O(函数数 × 累计图)
    // = 二次膨胀（实测 97.0% 的缓存字节是边记录、其中 99.70% 属于别的函数）。
    edge_start := r64(g_df_func_edge_start, ir_fi * 8);
    own_edge_count : ., mut = g_df_edge_count - edge_start;
    if own_edge_count < 0 { own_edge_count = 0; }
    total_size = total_size + 8 + own_edge_count * 24;
    total_size = total_size + 8 + instr_count * 48;
    total_size = total_size + 8;
    size_si : ., mut = 0;
    loop {
        if size_si >= g_ir_str_const_count { break; }
        size_ni := r64(g_ir_str_consts, size_si * 8);
        total_size = total_size + 8 + str_len(istr_get(size_ni));
        size_si = size_si + 1;
    }
    // v13: nested SG records (kind/enter/exit/parent/nstart/ncount).
    sg_count := cir_cache_sg_count(node_start, node_count);
    total_size = total_size + 8 + sg_count * 48;
    // v20 尾部 trailer = {var_start, node_start}（**基线见证**；装载期先校验后恢复）
    total_size = total_size + 16;
    if total_size > g_cir_write_cap {
        new_cap := g_cir_write_cap * 2;
        if new_cap < 4096 { new_cap = 4096; }
        if new_cap < total_size { new_cap = total_size; }
        g_cir_write_buf = alloc(new_cap);
        g_cir_write_cap = new_cap;
    }
    g_cir_write_pos = 0;

    // Write header
    w64_cir(fd, CIR_CACHE_MAGIC);
    w64_cir(fd, CIR_CACHE_VER);
    w64_cir(fd, cid);  // v17: 编译器身份（重建即失效）
    w64_cir(fd, fp);
    w64_cir(fd, sig);
    w64_cir(fd, name_len);
    write_fd(fd, name, name_len);

    // Determine var range for this function
    w64_cir(fd, var_count);
    vi : ., mut = 0;
    loop {
        if vi >= var_count { break; }
        v_idx := var_start + vi;
        w64_cir(fd, irv_name(v_idx));
        w64_cir(fd, irv_id(v_idx));
        w64_cir(fd, irv_type(v_idx));
        vi = vi + 1;
    }

    // Write function's node range
    w64_cir(fd, node_count);
    ni2 : ., mut = 0;
    loop {
        if ni2 >= node_count { break; }
        n := node_start + ni2;
        w64_cir(fd, r64(g_df_nodes, n * ESZ_DFNODE + OFF_DF_OPCODE));
        w64_cir(fd, r64(g_df_nodes, n * ESZ_DFNODE + OFF_DF_DEST));
        w64_cir(fd, r64(g_df_nodes, n * ESZ_DFNODE + OFF_DF_S1));
        w64_cir(fd, r64(g_df_nodes, n * ESZ_DFNODE + OFF_DF_S2));
        w64_cir(fd, r64(g_df_nodes, n * ESZ_DFNODE + OFF_DF_S3));
        // R2 P5 Task 2（D19）：盘记录承载**派生码**（不是 40 槽——单槽化后 40 槽 =
        // 进程内类型项引用，不得跨进程/跨复位，D20；辅码槽同理不入盘）。派生码逐节点
        // ≡ 单槽化前的混用码 ⇒ 盘面逐字节不变（布局与版本位零改动）。
        w64_cir(fd, sh_dfn_code_of_slots(r64(g_df_nodes, n * ESZ_DFNODE + OFF_DF_TK),
                                          r64(g_df_nodes, n * ESZ_DFNODE + OFF_DF_AUX)));
        w64_cir(fd, r64(g_df_nodes, n * ESZ_DFNODE + OFF_DF_FIRST_EDGE));
        w64_cir(fd, r64(g_df_nodes, n * ESZ_DFNODE + OFF_DF_EDGE_COUNT));
        // 项槽/辅码槽**不写盘**：两槽都是 (opcode, 派生码) 的纯函数，装载侧按 emit 的
        // 等价时点重派生（文件头 v18 注——实测快照携带进程内索引会在暖路径整体悬空）。
        ni2 = ni2 + 1;
    }

    // Persist nested SG metadata with offsets relative to this function's
    // node range. Parent indices are local to this serialized section.
    w64_cir(fd, sg_count);
    sg_i : ., mut = 0;
    loop {
        if sg_i >= g_sg_count { break; }
        kind := r64(g_sgs, sg_i * ESZ_SG + OFF_SG_KIND);
        nstart := r64(g_sgs, sg_i * ESZ_SG + OFF_SG_NSTART);
        if kind != SG_FUNC && nstart >= node_start && nstart < node_start + node_count {
            w64_cir(fd, kind);
            w64_cir(fd, r64(g_sgs, sg_i * ESZ_SG + OFF_SG_ENTER) - node_start);
            w64_cir(fd, r64(g_sgs, sg_i * ESZ_SG + OFF_SG_EXIT) - node_start);
            w64_cir(fd, cir_cache_sg_parent(sg_i, node_start, node_count));
            w64_cir(fd, nstart - node_start);
            w64_cir(fd, r64(g_sgs, sg_i * ESZ_SG + OFF_SG_NCOUNT));
        }
        sg_i = sg_i + 1;
    }

    // Write this function's edges only (v20)。
    // 历史注（v5–v19）：此处写的是**全图边表**，注释原文「For simplicity, write ALL edges
    // (they're few compared to nodes)」——该「边比节点少」的前提**早已失效**（实测 4,314 万条边
    // 记录 vs 20.6 万节点记录），它正是本条二次膨胀的起点（见计划 §1.1 的「假设已失效」注）。
    // v20：只写 [edge_start, g_df_edge_count) 且端点存**相对 node_start 的有符号偏移**。
    w64_cir(fd, own_edge_count);
    ei : ., mut = 0;
    loop {
        if ei >= own_edge_count { break; }
        e := edge_start + ei;
        w64_cir(fd, r64(g_df_edges, e * ESZ_DFEDGE + OFF_DFE_FROM) - node_start);
        w64_cir(fd, r64(g_df_edges, e * ESZ_DFEDGE + OFF_DFE_TO) - node_start);
        w64_cir(fd, r64(g_df_edges, e * ESZ_DFEDGE + OFF_DFE_KIND));
        ei = ei + 1;
    }

    // Write function's instruction range
    w64_cir(fd, instr_count);
    ii : ., mut = 0;
    loop {
        if ii >= instr_count { break; }
        inst := instr_start + ii;
        w64_cir(fd, iri_op(inst));
        w64_cir(fd, iri_dest(inst));
        w64_cir(fd, iri_s1(inst));
        w64_cir(fd, iri_s2(inst));
        w64_cir(fd, iri_s3(inst));
        w64_cir(fd, iri_tk(inst));
        ii = ii + 1;
    }

    // Write string constants used by this function
    w64_cir(fd, g_ir_str_const_count);
    si : ., mut = 0;
    loop {
        if si >= g_ir_str_const_count { break; }
        ni3 := r64(g_ir_str_consts, si * 8);
        s := istr_get(ni3);
        sl := str_len(s);
        w64_cir(fd, sl);
        vi = 0;
        loop { if vi >= sl { break; }
            w8_cir(fd, load8(s, vi));
        vi = vi + 1; }
        si = si + 1;
    }

    // v20 尾部 trailer（**基线见证**）：{var_start, node_start}。装载期**先校验后恢复**：
    // var 域恒校验（唯一不可低成本重映射的镜像域）；node 域仅在快照含越界 rel 时作条件见证。
    w64_cir(fd, var_start);
    w64_cir(fd, node_start);

    written := syscall3(1, fd, g_cir_write_buf, g_cir_write_pos);
    syscall3(3, fd, 0, 0);
    if written != g_cir_write_pos { return -1; }
    return 0;
}

// Write helpers for the in-memory cache serializer.
fn w64_cir(fd: int, val: int) {
    w64(g_cir_write_buf, g_cir_write_pos, val);
    g_cir_write_pos = g_cir_write_pos + 8;
}

fn w8_cir(fd: int, val: int) {
    store8(g_cir_write_buf, g_cir_write_pos, val);
    g_cir_write_pos = g_cir_write_pos + 1;
}

fn write_fd(fd: int, data: string, len: int) {
    write_pos : ., mut = 0;
    loop {
        if write_pos >= len { break; }
        store8(g_cir_write_buf, g_cir_write_pos, load8(data, write_pos));
        g_cir_write_pos = g_cir_write_pos + 1;
        write_pos = write_pos + 1;
    }
}

// === 快照装载读缓冲（R2 P5 Task 1：暖态 SIGSEGV 根因修复）===
// 根因链（实测，自源语料 src/compiler/main.cr -O 0，seed 见报告 §1）：
//   ① 每函数快照的读侧原先 = read_file(path) = alloc(fsize+1)，而 bump 分配器
//      （rt.s alloc）**不回收** ⇒ 946 个文件的读缓冲**累计驻留**（1,253,453,548B
//      = 1.1674GiB）；
//   ② 单文件尺寸是 O(程序) 而非 O(函数)（快照含全程序边表 + 全程序字符串表，
//      实测 nod_s3（13 节点）文件 = 2.48MB，其中 98.7% 是 80100 条全程序边），
//      累计 1.1674GiB > 1GiB 堆（rt.s heap_start .space 1024*1024*1024）；
//   ③ alloc 耗尽返回 0（.Lalloc_oom）⇒ read_file 把 0 当 string 返回；
//   ④ load_cir_cache 首行 str_len(0) → load64(0, -8) = SIGSEGV（暖态 rc=139；
//      冷态不读快照故 rc=0）——预存缺陷（P4 T5 §7-5 登记）。
// 修法（根因级，非给长度加钳位）：快照内容对装载是**瞬态**的——装完即弃，
// 无指针被保留（var 名以索引入表、字符串经 str_sub 拷贝后 str_intern、
// 节点/指令字段逐值拷入全局数组）⇒ 单个复用缓冲按需增长，峰值 = 最大单文件
// 尺寸（本语料实测最大 3,987,879B = 3.80MiB）而非全体累计。布局语义 = 与 read_file 返回的字符串
// 逐位同：alloc(cap+8) 的长度头在 buf-8，每次读取后改写为 fsize+1 ⇒
// str_len(g_cir_read_buf) == fsize，既有消费面（r64/str_sub）零改动。
g_cir_read_buf : string, mut;
g_cir_read_cap : int, mut;   // 数据区容量（不含 -8 处的 8B 长度头）

// 读取快照文件到复用缓冲。返回文件长度；< 0 = 不可用（open 失败/空文件/短读/
// 缓冲分配失败）——调用方按 cache miss 处理（三态纪律：载入失败 ⇒ 拒绝，
// 不得静默当空表）。快照恒为 save_cir_cache 单次 write 产出的常规文件 ⇒
// fsize <= 0（空文件或伪文件）= 不可用，不做 read_file 的伪文件循环回退。
fn cir_read_snapshot(path: string) -> int {
    fd := syscall3(2, path, 0, 0);  // open(O_RDONLY)
    if fd < 0 { return -1; }
    fsize := syscall3(8, fd, 0, 2);  // lseek(fd, 0, SEEK_END)
    if fsize <= 0 {
        r0 := syscall3(3, fd, 0, 0);  // close
        return -1;
    }
    if fsize + 1 > g_cir_read_cap {
        new_cap : ., mut = g_cir_read_cap;
        if new_cap < 4096 { new_cap = 4096; }
        loop {
            if new_cap >= fsize + 1 { break; }
            new_cap = new_cap * 2;
        }
        g_cir_read_buf = alloc(new_cap + 8);
        g_cir_read_cap = new_cap;
    }
    r2 := syscall3(8, fd, 0, 0);  // lseek(fd, 0, SEEK_SET)
    nread := syscall3(0, fd, g_cir_read_buf, fsize);  // read(fd, buf, fsize)
    r3 := syscall3(3, fd, 0, 0);  // close(fd)
    // 缓冲不可得（alloc 耗尽 ⇒ g_cir_read_buf 仍为 0 ⇒ read 取 EFAULT）或短读
    // （并发截断等）⇒ 均**不可用** ⇒ miss：绝不拿半份/空载荷继续解析（静默错值
    // 类）。⚠ 此处刻意**不写** `buf == 0` 形态的空判——该字符串-整型混比在
    // Python bootstrap 侧（x86_64_stack_asm.py:168 按 _is_string_var 分派）会编成
    // `str_eq(buf, 0)` → `str_len(0)` 解引用 NULL-8 = 崩溃（与自举侧 int 比较
    // 语义不一致，登记见报告 §6）；read 的 EFAULT 面已是同效且更稳的判据。
    if nread != fsize { return -1; }
    w64(g_cir_read_buf, -8, fsize + 1);  // 长度头 = fsize（str_len 口径同 read_file）
    return fsize;
}

// Load a .cir cache file and restore DFG state.
// func_idx is the function index used to verify the cached fingerprints
// against the current AST. Returns 0 on success, -1 on failure (cache miss).
fn load_cir_cache(path: string, func_idx: int) -> int {
    // 快照读入**复用缓冲**（不逐函数新分配——见 cir_read_snapshot 头注）。
    dlen := cir_read_snapshot(path);
    if dlen < 0 { return -1; }
    data := g_cir_read_buf;
    // v17 头部 = 48B + 函数名（再至少 8B 载荷段头）。
    if dlen < 56 { return -1; }
    pos : ., mut = 0;

    // Validate header
    magic := r64(data, pos); pos = pos + 8;
    if magic != CIR_CACHE_MAGIC { return -1; }
    ver := r64(data, pos); pos = pos + 8;
    if ver != CIR_CACHE_VER { return -1; }

    // v17: 编译器身份——条目由另一个（或旧版）编译器二进制写入 ⇒ 其字符串
    // 驻留序/索引与本次运行不一致，而 fp/sig 只覆盖目标源（同源必同）⇒ 必须
    // 在此拒绝，否则下面恢复出的旧序索引即成活产物（TODO #2026-09-10-1 静默类）。
    // 身份取不到（0）同样拒绝（save 侧对称地不落盘）：身份不可证 = 不可命中。
    cid := cir_compiler_identity();
    entry_cid := r64(data, pos); pos = pos + 8;
    if cid == 0 || entry_cid != cid { return -1; }

    fp := r64(data, pos); pos = pos + 8;
    sig := r64(data, pos); pos = pos + 8;

    // Verify fingerprints against current AST.
    // If the function body or signature changed, the cache is stale.
    fn_node := fi_ast_node(func_idx);
    current_fp := func_fingerprint(fn_node);
    if fp != current_fp { return -1; }
    current_sig := sig_fingerprint(fn_node);
    if sig != current_sig { return -1; }

    // Verify function identity (name)
    name_len := r64(data, pos); pos = pos + 8;
    // Skip name string (we already know which function we tried to load)
    pos = pos + name_len;

    // === v20 尾部 trailer = 基线见证（**先校验后恢复**）===
    // 最短合法条目 = 头 48 + trailer 16（上方 dlen < 56 的粗检已过 ⇒ 此处再按 64 收紧）。
    if dlen < 64 { return -1; }

    // === 结构预扫（**只读，不动全局**）===
    // 为什么先扫后恢复：装载的破坏性写在半途失败会污染全局数组（随后回归生成会**叠加**到
    // 半恢复的图上）⇒ 所有校验必须在**任何写之前**完成（P4：截断/越界 ⇒ rc=0/miss，不得 139/垃圾）。
    p : ., mut = pos;
    var_p := p;
    p_var_count := r64(data, p); p = p + 8 + p_var_count * 24;
    if p > dlen { return -1; }
    node_p := p;
    p_node_count := r64(data, p); p = p + 8 + p_node_count * 64;
    if p > dlen { return -1; }
    sg_p := p;
    p_sg_count := r64(data, p); p = p + 8 + p_sg_count * 48;
    if p > dlen { return -1; }
    edge_p := p;
    p_edge_count := r64(data, p); p = p + 8 + p_edge_count * 24;
    if p > dlen { return -1; }
    instr_p := p;
    p_instr_count := r64(data, p); p = p + 8 + p_instr_count * 48;
    if p > dlen { return -1; }
    str_p := p;
    p_str_count := r64(data, p); p = p + 8;
    p_si : ., mut = 0;
    loop {
        if p_si >= p_str_count { break; }
        sl_p := r64(data, p); p = p + 8 + sl_p;
        if p > dlen { return -1; }
        p_si = p_si + 1;
    }
    // trailer 定位于**扫描终点 p**（而非 dlen−16）：**尾随字节容忍**——装载历来忽略条目尾随字节
    // （既有契约：`test_cir_warm_path.py` 的 D5 用例即其钉子——补零条目仍须**命中**），故只要求
    // `p + 16 <= dlen`；**截断**（p+16 > dlen，含「恰缺 trailer」「trailer 半截」）仍 fail-closed miss。
    if p + 16 > dlen { return -1; }
    var_start_w := r64(data, p);
    node_start_w := r64(data, p + 8);
    // var 域是**唯一无法低成本重映射**的镜像域（var 下标出现在节点 dest/s1..s3 与指令 s1..s3）
    // ⇒ 恒校验：不符 = 读者与写者不同态 ⇒ miss（无害重建；「宁可 miss 不可静默」）。
    if g_ir_var_count != var_start_w { return -1; }

    // 边端点合法性 + **条件见证**：常态（rel 全在 [0, node_count)）下节点基线平移**不**影响相对 id
    // 的正确性 ⇒ 不校验 node_start（否则每次编辑都会让「被编辑函数之后的所有条目」集体 miss）；
    // 仅当出现**越界 rel**（全档实测 1/1618 档：from 指向更早函数/全局的节点）时，才要求节点基线一致。
    base_node_v := g_df_node_count;
    need_node_witness : ., mut = 0;
    ei_v : ., mut = 0;
    loop {
        if ei_v >= p_edge_count { break; }
        eo_v := edge_p + 8 + ei_v * 24;
        rf_v := r64(data, eo_v);
        rt_v := r64(data, eo_v + 8);
        if rf_v >= p_node_count { return -1; }   // 前向引用 = 异常（写侧 from 恒 ≤ 当前节点）⇒ 拒
        if rt_v >= p_node_count { return -1; }   // to 越界 = 异常 ⇒ 拒
        if rf_v < 0 || rt_v < 0 {
            need_node_witness = 1;
            if base_node_v + rf_v < 0 { return -1; }
            if base_node_v + rt_v < 0 { return -1; }
        }
        ei_v = ei_v + 1;
    }
    if need_node_witness != 0 { if g_df_node_count != node_start_w { return -1; } }

    // **逐节点见证**（v20；盘值降格为校验）：盘上 node.edge_count 必须等于「该节点在边表里的
    // 出边条数」——链由重放重建，重建前先把盘值与重放应得值对齐，不符即拒（半恢复不允许）。
    // 缓冲区按 p_node_count 现取（bump 分配器不回收；全档累计 Σnode ≈ 20.6 万槽 ≈ 1.6MB，可忽略）。
    if p_node_count > 0 {
        tally := alloc(p_node_count * 8);
        tz : ., mut = 0;
        loop { if tz >= p_node_count { break; } w64(tally, tz * 8, 0); tz = tz + 1; }
        ei_t : ., mut = 0;
        loop {
            if ei_t >= p_edge_count { break; }
            rf_t := r64(data, edge_p + 8 + ei_t * 24);
            if rf_t >= 0 { w64(tally, rf_t * 8, r64(tally, rf_t * 8) + 1); }
            ei_t = ei_t + 1;
        }
        nj : ., mut = 0;
        loop {
            if nj >= p_node_count { break; }
            ec_disk := r64(data, node_p + 8 + nj * 64 + 56);
            if ec_disk != r64(tally, nj * 8) { return -1; }
            nj = nj + 1;
        }
    }

    // Restore vars
    var_count := r64(data, pos); pos = pos + 8;
    vi : ., mut = 0;
    loop {
        if vi >= var_count { break; }
        name_ni := r64(data, pos); pos = pos + 8;
        v_id := r64(data, pos); pos = pos + 8;
        v_type := r64(data, pos); pos = pos + 8;
        // Ensure var array is large enough
        if v_id >= g_ir_var_count {
            grow_ir_vars(v_id + 1);
            g_ir_var_count = v_id + 1;
        }
        irv_set_name(v_id, name_ni);
        irv_set_id(v_id, v_id);
        irv_set_type(v_id, v_type);
        vi = vi + 1;
    }

    // Restore nodes
    node_count := r64(data, pos); pos = pos + 8;
    base_node := g_df_node_count;
    grow_df_nodes(g_df_node_count + node_count);
    // RegionCheck 显式映射：恢复的节点没有经过 df_create_node，须在此同步写入
    // node→region 映射，否则 subgraph_containing 在缓存命中路径读到未初始化
    // 的 g_df_node_region（null → SIGSEGV）。缓存不保存内层 region（Minor #4），
    // 以当前 open 的 func region（df_begin_func 已 sg_push）为归属——与旧的
    // 线性扫 g_sgs 在缓存命中路径得到的结果一致。
    grow_df_node_region(base_node + node_count);
    ni : ., mut = 0;
    loop {
        if ni >= node_count { break; }
        n := base_node + ni;
        w64(g_df_node_region, n * 8, g_cur_sg);
        w64(g_df_nodes, n * ESZ_DFNODE + OFF_DF_OPCODE, r64(data, pos)); pos = pos + 8;
        w64(g_df_nodes, n * ESZ_DFNODE + OFF_DF_DEST, r64(data, pos)); pos = pos + 8;
        w64(g_df_nodes, n * ESZ_DFNODE + OFF_DF_S1, r64(data, pos)); pos = pos + 8;
        w64(g_df_nodes, n * ESZ_DFNODE + OFF_DF_S2, r64(data, pos)); pos = pos + 8;
        w64(g_df_nodes, n * ESZ_DFNODE + OFF_DF_S3, r64(data, pos)); pos = pos + 8;
        // R2 P5 Task 2（D19）：盘上只有**一个** tk 字段（派生码）；两槽皆由它**重派生**
        // ——时点 = emit 的等价点（逐函数、逐节点序），拆分器单源 = sh_tk_split，故项表
        // 追加序与冷路径一致 ⇒ 冷/暖两态同项**同索引**（T4 用例逐行对拍）。项引用/辅码
        // **不读盘**（进程内项引用跨进程必悬空；盘上不存第二份 f(tk) 值 = 无第二真源）。
        tk_disk := r64(data, pos); pos = pos + 8;
        // 装载侧变体（不置 D23 失败位——盘码可能落在暖进程更小的类型表之外，见
        // ty_shadow.cr 的 sh_tk_split_load 注；缓存命中绝不因此让编译失败）。
        sh_tk_split_load(r64(g_df_nodes, n * ESZ_DFNODE + OFF_DF_OPCODE), tk_disk);
        w64(g_df_nodes, n * ESZ_DFNODE + OFF_DF_TK, g_sh_slot_term);
        w64(g_df_nodes, n * ESZ_DFNODE + OFF_DF_AUX, g_sh_slot_aux);
        // v20：盘上 first_edge/edge_count **不信任**（边下标随新基线平移）——两槽归零后由
        // 下方的 df_add_edge_kind 重放**重建**；盘值已在预扫中作**逐节点见证**校验过。
        w64(g_df_nodes, n * ESZ_DFNODE + OFF_DF_FIRST_EDGE, -1);
        w64(g_df_nodes, n * ESZ_DFNODE + OFF_DF_EDGE_COUNT, 0);
        pos = pos + 16;   // 跳过盘上两字段
        // Record var producer. 幽灵边修复（v7 注 A 裁决）缓存面：grow_df_arrays
        // 对新增长区播种 -1（dyn_arr.cr 同款注释）——快照内未产出 var（参数等）
        // 的 producer 槽恒 -1（修复前零页 = 0 =「节点 0」→ 缓存命中函数保留
        // 幽灵边）；本处只覆写快照内真实定值的 var。旧快照由 CIR_CACHE_VER
        // 13→14 失效。
        dest := r64(g_df_nodes, n * ESZ_DFNODE + OFF_DF_DEST);
        if dest >= 0 {
            grow_df_arrays(dest + 1);
            w64(g_df_var_producer, dest * 8, n);
        }
        ni = ni + 1;
    }
    g_df_node_count = base_node + node_count;

    // Restore nested SG metadata (v13). The current function SG was opened by
    // df_begin_func; cached parent=-1 refers to that SG.
    sg_count := r64(data, pos); pos = pos + 8;
    sg_base := g_sg_count;
    sg_i : ., mut = 0;
    loop {
        if sg_i >= sg_count { break; }
        new_sg := g_sg_count;
        grow_sg(new_sg + 1);
        kind := r64(data, pos); pos = pos + 8;
        enter_rel := r64(data, pos); pos = pos + 8;
        exit_rel := r64(data, pos); pos = pos + 8;
        parent_rel := r64(data, pos); pos = pos + 8;
        nstart_rel := r64(data, pos); pos = pos + 8;
        ncount := r64(data, pos); pos = pos + 8;
        parent := g_cur_sg;
        if parent_rel >= 0 { parent = sg_base + parent_rel; }
        f := new_sg * ESZ_SG;
        w64(g_sgs, f + OFF_SG_KIND, kind);
        w64(g_sgs, f + OFF_SG_ENTER, base_node + enter_rel);
        w64(g_sgs, f + OFF_SG_EXIT, base_node + exit_rel);
        w64(g_sgs, f + OFF_SG_PARENT, parent);
        w64(g_sgs, f + OFF_SG_NSTART, base_node + nstart_rel);
        w64(g_sgs, f + OFF_SG_NCOUNT, ncount);
        g_sg_count = new_sg + 1;

        // Later (inner) records overwrite the enclosing region mapping.
        rn : ., mut = base_node + nstart_rel;
        rend := rn + ncount;
        loop {
            if rn >= rend { break; }
            w64(g_df_node_region, rn * 8, new_sg);
            rn = rn + 1;
        }
        sg_i = sg_i + 1;
    }

    // Restore this function's edges (v20): 3×8B = {rel_from, rel_to, kind}，`next` 不落盘。
    // 逐条经 **df_add_edge_kind** 重放（与冷路径同一函数、同一前插序）⇒ 逐节点链序与
    // edge_count 与写者同态；且相对 id 在**节点基线平移**（部分 rebuild）时仍指向正确节点
    // ——这正是 R3（绝对 id + 全量覆盖的「未声明同态」）的根因级闭合。
    own_edge_count := r64(data, pos); pos = pos + 8;
    ei : ., mut = 0;
    loop {
        if ei >= own_edge_count { break; }
        rel_from := r64(data, pos); pos = pos + 8;
        rel_to := r64(data, pos); pos = pos + 8;
        e_kind := r64(data, pos); pos = pos + 8;
        // 有符号映射（rel<0 = 指向更早函数/全局的节点；界与基线见证已在预扫校验）
        df_add_edge_kind(base_node + rel_from, base_node + rel_to, e_kind);
        ei = ei + 1;
    }

    // Restore instructions
    instr_count := r64(data, pos); pos = pos + 8;
    base_instr := g_ir_instr_count;
    grow_ir_instrs(g_ir_instr_count + instr_count);
    ii : ., mut = 0;
    loop {
        if ii >= instr_count { break; }
        inst := base_instr + ii;
        iri_set_op(inst, r64(data, pos)); pos = pos + 8;
        iri_set_dest(inst, r64(data, pos)); pos = pos + 8;
        iri_set_s1(inst, r64(data, pos)); pos = pos + 8;
        iri_set_s2(inst, r64(data, pos)); pos = pos + 8;
        iri_set_s3(inst, r64(data, pos)); pos = pos + 8;
        iri_set_tk(inst, r64(data, pos)); pos = pos + 8;
        ii = ii + 1;
    }
    g_ir_instr_count = base_instr + instr_count;

    // Restore string constants (used by nodes/instrs)
    str_count := r64(data, pos); pos = pos + 8;
    si : ., mut = 0;
    loop {
        if si >= str_count { break; }
        sl := r64(data, pos); pos = pos + 8;
        s := str_sub(data, pos, sl);
        pos = pos + sl;
        track_str(str_intern(s));
        si = si + 1;
    }

    return 0;
}

// Ensure cache directory exists.
fn make_cir_cache_dir() {
    // Create .core/ directory hierarchy for cache.
    // mkdir syscall = 83 on x86-64 Linux: mkdir(path, mode)
    // Ignore EEXIST errors (directory may already exist).
    syscall3(83, ".core", 448, 0);
    syscall3(83, ".core/cache", 448, 0);
    syscall3(83, ".core/cache/cir", 448, 0);
}
