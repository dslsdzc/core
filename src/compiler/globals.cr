// === globals.cr ===
// ALL arrays are dynamic byte buffers (grow as needed, no MAX_* limits).

// String table (dynamic byte buffer containing `string` pointers)
g_strs : string, mut;            g_str_count : int, mut;     g_str_cap : int, mut;

// String interning hash table: maps hash → g_strs index (-1 = empty slot)
// Open addressing with linear probing.
g_str_hash : string, mut;        g_str_hash_cap : int, mut;

// Dynamic byte buffers (all arrays, no MAX_* limits)
g_funcs : string, mut;       g_func_count : int, mut;     g_func_cap : int, mut;
g_structs : string, mut;     g_struct_count : int, mut;   g_struct_cap : int, mut;
g_enums : string, mut;       g_enum_count : int, mut;     g_enum_cap : int, mut;
g_syms : string, mut;        g_sym_count : int, mut;     g_sym_cap : int, mut;
g_types : string, mut;       g_type_count : int, mut;     g_type_cap : int, mut;
// 类型行表布局单源（R2 P4 Task 2）：24B/条 {kind,data,extra}（i64×3）——
// alloc_type（checker.cr）/grow_types（dyn_arr.cr）/TYPE 段序列化与 dump（ccr_io.cr）
// 三方共用，改一处即全改（此前为三处字面量 24/8/16 并行）。
ESZ_TYPE_ROW : int = 24;
OFF_TR_KIND : int = 0;  OFF_TR_DATA : int = 8;  OFF_TR_EXTRA : int = 16;

// R2 P4 Task 2：TYPE(7) 段体缓冲（D18 解耦——段体**构造**在 corec-only 的
// ccr_types.cr（引用桥接层 sh_term_of_ti：corearch 无此层），本文件只声明载体，
// ccr_io.cr（corearch 也链接）只按段表搬运/解析）。缓冲**含段体首字段**
// （row_count u32），故段体大小 ≡ 缓冲长度（ccr_type_seg_size 单源）。
// 声明位置约束：本文件恒在最前（双 concat 共享面）——若把两件挪进 ccr_types.cr
// （corearch 清单不含），ccr_io.cr 的引用即 corearch 侧 N06 静默未定义（B.6 同族）。
g_ccr_type_seg : string, mut;   g_ccr_type_seg_len : int, mut;
// R2 P4 Task 3：IFACE(8) 段体缓冲（同 TYPE 的 D18 解耦——段体**构造**在 corec-only 的
// ccr_types.cr（引用桥接层 sh_iface_sig_*/形状构造点），ccr_io.cr 只按段表搬运/解析）。
// 缓冲**含段体首字段**（native_count u32）⇒ 段体大小 ≡ 缓冲长度（ccr_iface_seg_size 单源）。
g_ccr_iface_seg : string, mut;  g_ccr_iface_seg_len : int, mut;
// R2 P6 Task 3（β）：NOD 项索引装填缓冲（同 TYPE/IFACE 的 D18 解耦——**装填**在
// corec-only 的 ccr_types.cr（引用桥接层 sh_tk_face_of_code/sh_term_of_ti），本文件
// 只声明载体，ccr_io.cr 保存侧按节点序搬运落盘（盘记录 +28 i32 槽）。
// 语义 = TYPE 段**文件空间**的项索引：-1 = 无项（非 face-0 节点 / 暖态缺行——
// 辅码槽保真码）；≥0 = 该节点原子行对应的项 DAG 行号（写侧与盘上派生码同源，
// 读侧 load_ccr 在 TYPE 段解析后做**一致性硬校验**：域外或 atom_of ≠ 码 ⇒ 拒绝）。
// 声明位置约束同上方两件：本文件恒在最前（双 concat 共享面）——挪进 ccr_types.cr
// 即 corearch 侧 N06 静默未定义（B.6 同族）。
g_ccr_nod_item : string, mut;   g_ccr_nod_item_count : int, mut;
g_ast : string, mut;         g_ast_count : int, mut;     g_ast_cap : int, mut;
g_tokens : string, mut;      g_token_count : int, mut;   g_tok_cap : int, mut;
g_errors : string, mut;      g_error_count : int, mut;   g_err_cap : int, mut;
g_block_stmts : string, mut; g_block_stmt_count : int, mut; g_block_stmt_cap : int, mut;
g_ir_vars : string, mut;     g_ir_var_count : int, mut;  g_ir_var_cap : int, mut;
g_ir_instrs : string, mut;   g_ir_instr_count : int, mut; g_ir_instr_cap : int, mut;
g_ir_locals : string, mut;   g_ir_local_count : int, mut; g_ir_local_cap : int, mut;
g_ir_globals : string, mut;  g_ir_global_count : int, mut; g_ir_global_cap : int, mut;
g_ir_str_consts : string, mut; g_ir_str_const_count : int, mut; g_ir_str_const_cap : int, mut;

// ── 可选运行期表示面（R2 P4 Task 5；裁决 5「解包侧判表示」，附录 B.7）──
// 事实：`Some(1)`/`None` 走 IR_MAKE_ENUM 对象（[tag][payload…]），而 `T?` 槽里的
// **裸值**仍是裸值 ⇒ 同一 `T?` 值两种表示；`Some` 臂的载荷解包把裸值当对象解引用
// （双路径 SIGSEGV，check/build rc=0 零诊断）。
// 机制：**表示位** = 每个可选槽（局部/形参/调用结果）配一个普通 int IR 变量的
// **运行期值**（0 = 裸值、1 = 装箱）。写点置位（静态已知则常量、否则从源槽表示位
// 拷贝）、**解包点分派**（`match` 的 Some/None 臂、`?`）——纯 IR，无新 opcode、
// 无 ABI 改动，故 ELF 后端与解释器天然同源。
// g_ir_var_rep：IR var → 表示位变量索引（i64 数组；-1 = 无表示位）。无表示位的槽
//   走既有装箱假定（未覆盖面：结构体字段/数组元素/全局槽/match 结果/惰性 thunk，
//   逐形态实测入报告——响亮失败或既有正确值，不新增静默错值）。
g_ir_var_rep : string, mut;     g_ir_var_rep_cap : int, mut;
// g_ir_var_decl_ti（容量批 T2）：IR var → **声明类型索引**（i64 数组；-1 = 无注解/未知）。
//   用途 = 可选聚合槽写点装箱的「目标槽类型」判定：数组/切片元素类型只能由**声明**
//   （`a : [int?;2]`）忠实给出（字面量推出的元素类型对可选元素退化为对象占位）。
//   仅进程内状态，零布局变更；非可选程序不读取本表（零足迹）。
g_ir_var_decl_ti : string, mut; g_ir_var_decl_cap : int, mut;
// (A) 批（TODO #2026-09-16-4 / 裁-REP-1 (iii)）：**取址名侧表**——`EXPR_UNARY+UOP_REF` 的 ident 操作数
// 的**名字索引**集合（预扫收集；进程内、零布局）。标记面按名字索引判 ⇒ **同名字在别处出现
// 会被一并标记 = 保守方向**（多标记只增装箱、不损失正确性；不会欠标记）。
g_addr_taken_names : string, mut; g_addr_taken_cap : int, mut; g_addr_taken_count : int, mut;
// 容量批 T3（E-3 / 裁-CAP-2 (a)）：结构体字段**侧表**——字段槽区自定长内嵌记录迁出
// （记录内 `OFF_SI_FIELD_BASE` 槽 = 本表起始行；记录尺寸与既有 OFF_* 不变）。
// 三条扁平表按「全局字段行」索引（高水位 = g_si_f_used）。仅进程内状态；`.ccr` 盘面
// 不变（盘面本就逐字段变长，见 ccr_io.cr 的 SYM 布局注）。
g_si_f_names : string, mut;  g_si_f_types : string, mut;  g_si_f_nodes : string, mut;
g_si_f_used : int, mut;      g_si_f_cap : int, mut;
// 容量批 T3：枚举变体**侧表**（同 struct 形态）——`OFF_EI_VARIANTS` 槽改义为 `variant_base`；
// 变体面三条（名/载荷基址/载荷计数）+ 载荷面两条（裸码/类型节点）。
g_ei_v_names : string, mut;  g_ei_v_tbase : string, mut;  g_ei_v_tcount : string, mut;
g_ei_vt_types : string, mut; g_ei_vt_nodes : string, mut;
g_ei_v_used : int, mut;      g_ei_vt_used : int, mut;     g_ei_v_cap : int, mut;
g_ei_vt_cap : int, mut;
// 容量批 T3：match 覆盖位**无界位图**（旧态 = 单 int 的 2^vi 位图 ⇒ ≥63 变体溢出，
// e70 实测 SIGFPE）。位图按「位下标 vi」寻址；`g_cov_len` = 当前已用位数，**栈纪律**：
// mc_begin 存长度、mc_end 清零并回退（嵌套 match 安全）。
g_cov_bits : string, mut;  g_cov_cap : int, mut;  g_cov_len : int, mut;
// g_optrep_on：本编译单元是否启用表示面（AST 预扫：EXPR_OPTIONAL / `Some` / `None`）。
//   关 = **零足迹**（不注册隐藏全局、不发任何表示指令）⇒ 非可选程序的发射面逐字节不变。
g_optrep_on : int, mut;
// g_dump_params_on：(乙) A1 判据通道（`--dump-params`，隐藏调试）：形参序言创建槽时打一行
//   `PARAM <函数名> p<i> <形参名> slot=<槽型码> decl=<节点 type_val>` 到 **stdout**。
//   **rc 中性 + 零产物**（用不用该 flag，rc 与产物逐字节不变；不新增 alloc/str_intern 副作用——
//   只读 `irv_type` 与 `ast_type_val` 两个纯表读，函数名走既有 `istr_get`）。
g_dump_params_on : int, mut;
// g_optrep_ret_cell：返回表示的信道单元（IR 全局 var；-1 = 未注册）。返回点写、
//   调用点读（读点紧跟 IR_CALL ⇒ 跨嵌套调用不被覆写；写点为值求值完成后 → 语义确定）。
g_optrep_ret_cell : int, mut;
// g_optrep_arg_cell0 / g_optrep_arg_count：形参表示信道（每形参位一个 IR 全局 var，
//   连续分配）。调用点写、被调序言读（先于任何可能改写信道的调用）。
g_optrep_arg_cell0 : int, mut;  g_optrep_arg_count : int, mut;
// g_cur_ret_opt：当前函数的返回类型是否可选（ir_gen_func 设置；返回点写信道用）。
g_cur_ret_opt : int, mut;
// g_cur_ret_dex_opt：当前函数的返回类型是否 `dex?`（ir_gen_func 按**返回类型节点**设置，
//   批 5 · R3）。`-> dex?` 的 `g_cur_ret_ti` 与 `type_val` 均为 0（`unpack_type(EXPR_OPTIONAL)`
//   塌陷）⇒ 返回点的 dex 边界转换需本标志补位（否则 apx 源经 `-> dex?` 返回不转换）。
g_cur_ret_dex_opt : int, mut;
// 表示码（rep_enc_of_expr 的返回）：>= 0 = 从该表示位槽**拷贝**；oe_bare() = -1 = 裸值
// 常量；oe_boxed() = -2 = 装箱常量。**用函数而非文件级常量**：Python bootstrap 的
// gen_let_decl 只对**裸字面量**记 constant_value（`-1` 解析成 UnaryOp ⇒ 丢初值 ⇒
// StackAsmGen 发 `.quad 0`）⇒ 自举链二进制里的负值文件级常量**静默读 0**（实测踩过：
// 两常量读 0 后 `Some` 初值表示位与裸值同码；同类既存面 = cir_cache.cr 的
// CIR_CACHE_MAGIC，其在自举二进制里同读 0——已登记报告）。返回值表达式不受该限制。
fn oe_bare() -> int { return 0 - 1; }
fn oe_boxed() -> int { return 0 - 2; }

// Parser/checker dynamic arrays (shared between corec and corearch builds)
g_global_lets : string, mut;         g_global_let_count : int, mut;     g_global_lets_cap : int, mut;
g_loop_stack : string, mut;          g_loop_depth : int, mut;           g_loop_stack_cap : int, mut;
g_type_aliases : string, mut;        g_type_alias_count : int, mut;     g_type_alias_cap : int, mut;
g_methods : string, mut;             g_method_count : int, mut;         g_method_cap : int, mut;
g_scope_bounds : string, mut;        g_scope_depth : int, mut;          g_scope_bounds_cap : int, mut;
g_borrow_scope_markers : string, mut; g_borrow_scope_depth : int, mut;  g_borrow_scope_markers_cap : int, mut;

// Interface system
g_ifaces : string, mut;          g_iface_count : int, mut;     g_iface_cap : int, mut;
g_impl_for : string, mut;        g_impl_for_count : int, mut;  g_impl_for_cap : int, mut;
g_generic_constr : string, mut;  g_generic_constr_count : int, mut; g_generic_constr_cap : int, mut;
// R2 P3 Task 5：结构/枚举泛型约束侧表（**索引空间与函数侧分家**——g_generic_constr 的键 =
// `fi * MAX_GENERICS + gi`，若共用同一缓冲，struct/enum 行号与函数行号会互相覆盖）。
// 键 = `si * MAX_GENERICS + gi`（struct）/ `ei * MAX_GENERICS + gi`（enum），值 = 约束名 ni
// （-1 = 无约束；稀疏：未写槽不读）。**语义边界**（P3 计划 Task 5）：保留（本表）归 P3a；
// `T: I` 的**满足判定**走统一入口 `iface_satisfies`（**R2 P3b Task 0 已交付**，type_engine.cr
// 的轴 C）——实例化点由 `gen_inst_constr_satisfied` 直取真值（本批起**真判定**：可证违反 ⇒
// TG02 软诊断），函数调用点仍回落既有 check_iface 路径（措辞逐字不动，切换归 Task 6 Step 3）。
// 见 checker.cr 的 gen_constr_* 段。
g_sgen_constr : string, mut;     g_sgen_constr_count : int, mut;  g_sgen_constr_cap : int, mut;
g_egen_constr : string, mut;     g_egen_constr_count : int, mut;  g_egen_constr_cap : int, mut;
// R2 P3b Task 0（P2b 交接面回补）：**横切轴形状条目表**（名字 ni → 形状类型项），
// `iface_satisfies` 的轴 A。与 `g_ifaces`（用户接口 = 方法集）平行：本表条目 = 一个**类型项**
// （如 `sequence` ⇒ `⊤_SEQUENCE`），满足判定 = 一条包含判定（spec §2.2）。
// 条目由 Task 2 注册（`iface_shape_register`）——**本批零条目**（空表 ⇒ 轴 A 恒 -1 = 不判，
// 三态纪律不破）。⚠ 注册名须来自**已驻留**的名字 ni（lexer 已 intern 的源码标识符）；
// 本表初始化路径**不得** `str_intern`（.ccr STR 段硬判据，照 iface_registry.cr 的 name_ni 注）。
g_iface_shape_names : string, mut;  g_iface_shape_terms : string, mut;
g_iface_shape_count : int, mut;     g_iface_shape_cap : int, mut;
// R2 P3 Task 5（Step 4）：调用点泛型绑定侧表（monomorph 实例键类型项化）。
// 由 checker 的 infer_gen_call 按**被调方泛型形参声明序**登记：每调用点 gc 个槽，值 = 实参
// 推断出的**类型行 ti**（-1 = 未绑定）。起始下标写入调用节点 `ast_int_val`（调用节点的该槽
// 在本批之前只被**死码** `ir_gen.cr find_or_create_mono_func` 读——该函数零调用者，登记见
// 报告）。ir_gen 侧据 ti 生成规范实例键 `inst_key_of_ti`，并以 ti 型替换（`g_gen_subst_tis`）
// 取代纯名字文本替换（旧法：非原生实参一律塌缩 "int" ⇒ 异型实例折叠 + 错替换）。
g_gen_binds : string, mut;       g_gen_binds_count : int, mut;    g_gen_binds_cap : int, mut;
// R2 P3 Task 5：约束违反诊断去重侧表（开放寻址，16B/条 {key, 1}；key = node*MAX_GENERICS+gi）。
// 生命周期同 g_named_dedup（init_types → gen_constr_seen_reset 置 cap=0 惰性重建；键含 AST
// 节点下标 ⇒ 跨编译期复用即失效）。见 checker.cr 的 gen_constr_seen_* 段。
g_constr_seen : string, mut;     g_constr_seen_cap : int, mut;    g_constr_seen_count : int, mut;
g_gen_params : string, mut;     g_gen_param_count : int, mut;     g_gen_param_cap : int, mut;
g_checker_current_fi : int, mut;
// 批 8 PR-B · S1′ 打点开关（**默认 0 = 关**）：由 `main.cr` 读 `CORE_S1P=1` 置位；
// 打开时 checker 的直调点打**数值**行（行/列/形参序/形参 TI/实参 TI/被调名）。
// **为何要开关**：该打点会 `int_str`/`println` 生成新字符串 ⇒ 写进输出 `.ccr` 的 STR 段
// ⇒ 破「产物逐字节不变」（实测 `opt_dex_test.cr` 的 `.ccr` 变而 ELF 同）。默认关 ⇒ 零足迹。
g_s1p_on : int, mut;        // S1′ 打点开关：0 = 关（默认行为）· 1 = 开（`CORE_S1P=1`）
g_s1p_seen : int, mut;      // 0 = 尚未读环境变量 —— **哨兵必须用零值**：全局的**非 Literal 初值**
                            //   经 Python bootstrap 构建会被**静默丢成 0**（2026-09-18 实测，
                            //   机理见 checker.cr S1′ 注）⇒ `= -1` 这类写法不可依赖。

g_unsafe_depth : int, mut;
g_alloc_pts : string, mut;     g_alloc_pts_cap : int, mut;
g_borrow_vars : string, mut;          g_borrow_refs : string, mut;       g_borrow_muts : string, mut;
g_borrow_count : int, mut;            g_borrow_cap : int, mut;
g_holder_borrowers : string, mut;     g_holder_borrowed : string, mut;   g_holder_is_mut : string, mut;
g_holder_count : int, mut;            g_holder_cap : int, mut;
g_gen_map_names : string, mut;        g_gen_map_types : string, mut;
g_gen_map_count : int, mut;           g_gen_map_cap : int, mut;
g_dyn_type_sets : string, mut;        g_dyn_type_set_count : int, mut;  g_dyn_type_set_cap : int, mut;
g_stack_map : string, mut;  // IR var index → shared stack slot var (-1 = own slot), set by allocator
g_home_dir : string, mut;           // cached HOME dir for SO index lookup
g_home_dir_ok : int, mut;           // 1 = g_home_dir initialized

g_ir_func_name_idx : string, mut;   g_ir_func_name_idx_cap : int, mut;
g_ir_func_ret_type : string, mut;   g_ir_func_ret_type_cap : int, mut;
g_ir_func_instr_start : string, mut; g_ir_func_instr_start_cap : int, mut;
g_ir_func_instr_count : string, mut; g_ir_func_instr_count_cap : int, mut;
g_ir_func_var_start : string, mut;  g_ir_func_var_start_cap : int, mut;
g_ir_func_var_count : string, mut;  g_ir_func_var_count_cap : int, mut;
g_ir_func_param_count : string, mut; g_ir_func_param_count_cap : int, mut;
g_ir_func_count : int, mut;

// v6 数据基础：存在区间表（compute_live_ranges 填充，alloc_registers 读本表——
// 填充方 = 内核 ent_kernel.cr（双 concat 共享：corec 写侧 save_ccr 直调
// compute_live_ranges/compute_entries，corearch alloc_registers 读本表）。
// 布局：每函数一段，段内每「函数内 var」两条 i64（first_ref/last_ref，函数内指令序
// ——坐标限定：0..instr_count-1 的函数内下标，见 ent_kernel.cr live_range_slot）；
// func_i 段起始 = Σ var_count[0..func_i)，不乘固定稠密系数。未使用 var 为 -1。
// 与 g_ir_slice_lens 同风格：16B 记录 + grow 函数（grow_live_ranges 在 ent_kernel.cr）。
g_ir_live_ranges : string, mut;
g_live_range_count : int, mut;
g_live_range_cap : int, mut;

// v6 条目表（条目版本化，compute_entries 填充——compute_live_ranges 尾部对全部
// 函数运行；v7 ENT 主干化后 .ccr ENT = 实记录，corec 写侧 save_ccr 直调内核
// 填充再落盘——填充方 = 内核 ent_kernel.cr，双 concat 共享）。24B/条（六字段各 4B，
// LE 存取：写 w32、读 buf_read_i32——r32 读在 bootstrap 产物中丢符号扩展，
// 见 ent_kernel.cr ent_* 访问器注记；与 v6 格式记录逐字节一致），字段偏移见 dyn_arr.cr：
//   var_idx(0)   u32 = 全局 IR 变量索引（g_ir_vars 序）
//   def_instr(4) i32 = 定值指令全局索引——IR_ALLOC(dest=var) 或 IR_STORE(s1=var)
//                      （IR_STORE 定值形态 = ρ(s1):=ρ(s2)，目标在 s1、dest 恒 -1，
//                       见 docs/ir-op-semantics.md §2.1）；-1 = 无定值条目
//   live_start(8)/live_end(12) i32 = 版本存在区间：全局指令序闭区间
//                      [def_j, min(def_{j+1}−1, last_ref)]（与 Task 1 区间表同
//                      闭区间语义，坐标转全局）；无定值条目 = [first_ref, last_ref]
//   home(16) i32 = 分配器回填的槽位（-1 = 未分配，Task 5 回填）
//   flags(20) u32 = 0（位 0 预留：无配方，条款 4b）
// 布局：每函数一段（func_i 升序追加），段界在 g_ir_func_entry_start/count（8B/条）。
// 版本号不落盘：同 var 条目按 def_instr 升序（扫描序即升序），版本序 = 组内 1-based 序号。
g_ir_entries : string, mut;    g_entry_count : int, mut;    g_entry_cap : int, mut;
g_ir_func_entry_start : string, mut;  g_ir_func_entry_count : string, mut;
g_ir_func_entry_cap : int, mut;

// Module system arrays (dynamic byte buffers)
DIAG_REC_SIZE : int = 40;   // g_diags 记录字节数：[ec(8) msg(8) line(8) col(8) file_id(8)]
// fail-closed 判据线（FC 批 T2）：豁免表的**生效面**标签（消费点 = main.cr 的硬判定循环
// 经 diag_gate_exempt(ec, scope)；表 = diag.cr）。裁-FC-1 = (C)：run_frontend 只以
// GATE_SCOPE_BUILD 调用；check 面的 rc 规则（计数 > 0）不消费本表 ⇒ check 基线零变化。
GATE_SCOPE_BUILD : int = 1;   // build/ccr/cir/run 面（经 run_frontend 的 hard 判定）
GATE_SCOPE_CHECK : int = 2;   // check 面（**本批不消费**：仅登记；见 diag_gate_exempt 表注）
g_diags : string, mut;           g_diag_count : int, mut;     g_diag_cap : int, mut;
g_files : string, mut;           g_file_count : int, mut;     g_file_cap : int, mut;
g_mods : string, mut;            g_mod_count : int, mut;      g_mod_cap : int, mut;
// LSP open documents: path → source text. 24-byte records:
// {path_ptr(8), src_ptr(8), src_len(8)}（路径与源文本均为调用方提供的稳定堆字符串）
g_open_docs : string, mut;       g_open_doc_count : int, mut; g_open_doc_cap : int, mut;
// LSP 静默模式：1 = 抑制非诊断的进度/警告 stdout 输出（保护协议通道）
g_silent_stdout : int, mut;      // 默认 0：corec 命令行行为不变
g_mod_func_fileids : string, mut; g_mod_func_names : string, mut;
g_mod_func_tis : string, mut;    g_mod_func_count : int, mut; g_mod_func_cap : int, mut;
g_mod_path_names : string, mut;  g_mod_path_count : int, mut; g_mod_path_cap : int, mut;

// Dynamic stacks (byte buffers)
g_ir_local_scopes : string, mut;    g_ir_local_scopes_cap : int, mut;
g_ir_local_depth : int, mut;
g_ir_loop_header : string, mut;     g_ir_loop_exit : string, mut;
g_ir_loop_depth : int, mut;         g_ir_loop_stacks_cap : int, mut;
g_label_poses : string, mut;        g_label_cap : int, mut;
g_label_count : int, mut;
// Interpreter loop-region table: per SG_LOOP/SG_FOR region, the enter/exit
// DF-node offsets (function-relative).  Loop iteration in the interpreter is
// driven by these region boundaries, not by label-table back-jumps.
g_loop_region_enter : string, mut;  g_loop_region_exit : string, mut;
g_loop_region_count : int, mut;     g_loop_region_cap : int, mut;
// Pre-computed interned string indices for builtin function name matching
g_ni_syscall3 : int, mut;  g_ni_syscall4 : int, mut;  g_ni_load8 : int, mut;  g_ni_store8 : int, mut;
g_ni_load64 : int, mut;    g_ni_load_str_ptr : int, mut;
g_ni_store_str_ptr : int, mut;  g_ni_get_arg : int, mut;
g_ni_w64 : int, mut;  g_ni_dyncpy : int, mut;  g_ni_r64 : int, mut;
g_ni_goroutine_wrapper_addr : int, mut;
// Single-pass backpatching: pending forward jumps
g_pending_pos : string, mut;        // rel32 buffer positions to patch
g_pending_label : string, mut;      // target label indices
g_pending_count : int, mut;         g_pending_cap : int, mut;
g_next_label : int, mut;

// Backend arrays (all dynamic byte buffers)
g_x86_str_offs : string, mut;           g_x86_str_count : int, mut;     g_x86_str_cap : int, mut;
g_x86_ext_rel_pos : string, mut;        g_x86_ext_rel_name : string, mut;
g_x86_ext_rel_count : int, mut;         g_x86_ext_rel_cap : int, mut;

// `.so` 扩展索引**侧表**（第 4 批 #82/#83）：索引解析结果先落此处，**不**直接进串表/符号表。
// 只有被程序**引用**的名字才由 `so_materialize`（module.cr）物化 ⇒ 未引用条目零产物足迹。
// name 存**原始串**（不能存 intern 索引——注册期 intern 正是 #82 的泄漏本身）；
// tags/type 存 int（与符号表 SO_FN 条目的 sym_type/sym_node 同义）。
g_so_side_name : string, mut;           g_so_side_tags : string, mut;
g_so_side_type : string, mut;
g_so_side_count : int, mut;             g_so_side_cap : int, mut;
// 批 6（T2）**规约标注侧表**：`#check(expr)` / `#ensure(expr)` 的登记面（源序追加；8B/条）。
// 设计要点（裁-S2/S3）：① 标注**不挤 `EXPR_FN` 的 a/b/c 槽**（parser.cr:1451 槽语义不变）；
// ② 表达式 AST 节点落 `g_ast` 但**不被 body 引用** ⇒ ir_gen 走不到它 ⇒ 发射面零足迹；
// ③ 侧表随前端复位（与 `g_func_count` 同生命周期——fi/ni 下标跨编译复用，不清会命中陈旧条目）。
g_spec_fn : string, mut;                // 函数名 str idx（= parse_body 的 fn_ni；仅用于消息）
g_spec_fnode : string, mut;             // **EXPR_FN 节点索引**（唯一键：同名函数/方法不串台；
                                        // 由 parser 在 alloc_node 之后回填，见 parse_body 的 spec_start 补丁）
g_spec_kind : string, mut;              // 0=#check  1=#ensure（留宽：C2 的 #pure/#tag 等）
g_spec_expr : string, mut;              // 标注表达式的 AST 节点索引
g_spec_line : string, mut;              // 标注 `#` 所在行
g_spec_col : string, mut;               // 标注 `#` 所在列
g_spec_status : string, mut;            // 三态：0=yellow（未证，默认）  1=green（常量真）  2=red（有硬错）
                                        // **red 粘性**（spec_set_status）：红色不被后续 green 覆盖
g_spec_count : int, mut;                g_spec_cap : int, mut;
g_x86_rip_patch_pos : string, mut;      g_x86_rip_patch_globals : string, mut;
g_x86_rip_patch_count : int, mut;       g_x86_rip_patch_cap : int, mut;
g_x86_vars : string, mut;               g_x86_var_count : int, mut;     g_x86_var_cap : int, mut;
g_x86_stack_size : int, mut;            g_x86_func_idx : int, mut;
g_x86_is_enum : string, mut;            g_x86_is_enum_count : int, mut; g_x86_is_enum_cap : int, mut;
g_x86_rodataref_pos : string, mut;       g_x86_rodataref_ro : string, mut;
g_x86_func_cp : string, mut;            g_x86_func_cp_cap : int, mut;
g_x86_func_code_sz : string, mut;       g_x86_func_code_sz_cap : int, mut;
g_x86_rodataref_count : int, mut;       g_x86_rodataref_cap : int, mut;
g_x86_is_global : string, mut;
g_x86_global_cnt : int, mut;
g_x86_global_cap : int, mut;
g_x86_global_off : string, mut;         g_x86_global_off_cnt : int, mut; g_x86_global_off_cap : int, mut;
g_x86_func_offsets : string, mut;       g_x86_func_offsets_cap : int, mut; g_x86_func_off_count : int, mut;
g_x86_emit_vars : string, mut;          g_x86_emit_vars_cap : int, mut; g_x86_emit_var_count : int, mut; g_x86_emit_stack_size : int, mut;
// int 多字 M1（tagged 槽，D1a）：潜在多字变量的旁路 tag 区（栈帧尾附加）。
// 见 docs/superpowers/plans/2026-09-06-int-multiword-m1.md Task 1 与
// docs/superpowers/specs/2026-09-06-int-multiword-backend-design.md（D1a/D3）。
// g_x86_mw_tag_off：当前函数的 per-局部-变量 tag 字节偏移表（i64 数组，按
// 局部位置 v-var_start 索引；值 = 相对 rbp 的负字节偏移；-1 = 非 tagged）。
// g_x86_mw_tag_count：当前函数 tagged 变量数（tag 区字节数 = 每变量 1 字节）。
g_x86_mw_tag_off : string, mut;     g_x86_mw_tag_off_cap : int, mut;
g_x86_mw_tag_count : int, mut;
// g_x86_mw_jo_*：int 多字 M1 Task 2/3——tagged int add/sub 快路径溢出跳
// （jo 0F 80 rel32）站点记录表：emit_instr 发射 jo 时记录站点现场，frame.cr
// pf_epilogue 于该函数尾声（慢路径块位置后知）按站点发射真实 2-limb 修正块
// 并统一回填（波 1 Task 3 起帧尾声/函数尾块归 frame.cr）
// （g2_init 清零——ret_patch 同款）。记录 = 4 条并行 i64 数组（共享 cap，
// 同步增长，索引 = 站点点序 = 指令序，单指令至多 1 站点）：
//   g_x86_mw_jo_pos     — jo 指令绝对缓冲位置（rel32 字段 = pos+2、jo 长 6）；
//   g_x86_mw_jo_dest    — 快路径 store 的 dest 变量索引（块内回存目标：
//                         发射块时经 g2_slot(dest) 现算——含 O1/O2 reg 形态，
//                         无需入录槽形态本身）；
//   g_x86_mw_jo_is_sub  — 1 = 该站点为 sub（高 limb 修正规则不同：add 溢出
//                         高 limb = CF ? -1 : 0；sub = CF ? 0 : -1——CF/符号
//                         关系见 e2_mw_slow_block（tag2l.cr）注释推演）；
//   g_x86_mw_jo_resume  — 块处理完成后跳回点（= 该站点快路径 store e2_st
//                         之后的绝对位置——elf.cr 于指令发射完、块位置已知
//                         时填写，块发射时直接回填 jmp rel32）。
// 见 plan Task 2/3 与 specs/2026-09-06-int-multiword-backend-design.md（D1a/D3）。
g_x86_mw_jo_pos : string, mut;      g_x86_mw_jo_cap : int, mut; g_x86_mw_jo_count : int, mut;
g_x86_mw_jo_dest : string, mut;     g_x86_mw_jo_is_sub : string, mut;
g_x86_mw_jo_resume : string, mut;
// g_x86_mw_oc_*：int 多字 M1 Task 4——消费者站点（tagged 操作数读 tag）记录表：
// add/sub/比较站点在快路径前发 tag 检查（test byte + jne 0F 85 rel32——tag=1
// = 操作数为 2-limb），jne 目标 = 该站点函数尾 2L 块（位置后知——jo 同款
// 回填机制）。记录 = 8 条并行 i64 数组（共享 cap，索引 = 站点序 = 指令序，
// 单指令至多 1 站点）：
//   g_x86_mw_oc_pos1/pos2 — 该站点第 1/2 个检查 jne 的绝对缓冲位置
//                           （-1 = 无——操作数行 untagged 或 s1==s2）；
//   g_x86_mw_oc_s1/s2/dest — 站点操作数行与 dest（块内现算槽形态/回存目标）；
//   g_x86_mw_oc_op        — 站点 op（OP_ADD/OP_SUB = 128 算术块；
//                           OP_EQ..OP_GE = 128 比较块）；
//   g_x86_mw_oc_resume    — 块完成后跳回点（= 该站点指令尾，同 jo）。
// 见 plan Task 4 与 e2_mw_opnd_block（tag2l.cr——波 1 Task 4 自 instr.cr 整搬）。
g_x86_mw_oc_pos1 : string, mut;     g_x86_mw_oc_pos2 : string, mut;
g_x86_mw_oc_cap : int, mut;         g_x86_mw_oc_count : int, mut;
g_x86_mw_oc_s1 : string, mut;       g_x86_mw_oc_s2 : string, mut;
g_x86_mw_oc_dest : string, mut;     g_x86_mw_oc_op : string, mut;
g_x86_mw_oc_resume : string, mut;
g_x86_ret_patch_pos : string, mut;      g_x86_ret_patch_cap : int, mut; g_x86_ret_patch_count : int, mut;
g_x86_call_patch_pos : string, mut;     g_x86_call_patch_name : string, mut;
g_x86_call_patch_count : int, mut;      g_x86_call_patch_cap : int, mut;
g_x86_fnaddr_patch_pos : string, mut;   g_x86_fnaddr_patch_name : string, mut;
g_x86_fnaddr_patch_count : int, mut;    g_x86_fnaddr_patch_cap : int, mut;
g_x86_sub_rsp_pos : int, mut;
g_x86_alloc_patch_pos : string, mut;    g_x86_alloc_patch_cap : int, mut; g_x86_alloc_patch_count : int, mut;
g_x86_emit_rt_stubs : int, mut;         // 1 = pure-static: backend emits g_set_curg/g_get_curg stubs
// Optimization levels and metadata (extensible key-value store)
g_opt_level : int, mut;     // 0=none, 1=regalloc, 2=stackshare, 3=cse
g_opt_meta : string, mut;   // metadata buffer for .ccr v3+
g_opt_meta_count : int, mut; g_opt_meta_cap : int, mut;

// Subgraph table (for RegionCheck pass lifetime tracking)
g_sgs : string, mut;             g_sg_count : int, mut;     g_sg_cap : int, mut;
g_df_node_region : string, mut;   g_df_node_region_cap : int, mut;  // per DFNode: owning region id (-1 = none)
g_cur_sg : int, mut;              // currently open region id (-1 = none)
g_cur_ret_ti : int, mut;          // 当前函数的返回 TI（dex 边界转换用，数值迁移 Task 4）
g_last_state_node : int, mut;     // last side-effect DFNode id (VSDG state chain; -1 = none)
g_df_state_finalized : int, mut;  // df_state_finalize 幂等旗标（0 = 未跑；数据流图重建每编译恰一次——见 dataflow.cr）

// Plugin extension registry: tags and return types from .so/stdlib plugins
// Each entry: 24 bytes = [ns_ni, name_ni, data_ni]
g_plugin_tags : string, mut;   g_plugin_tag_count : int, mut;   g_plugin_tag_cap : int, mut;
g_plugin_rtypes : string, mut; g_plugin_rtype_count : int, mut; g_plugin_rtype_cap : int, mut;

// Pointer analysis storage
g_pts : string, mut;       g_pts_count : int, mut;     g_pts_cap : int, mut;
g_offsets : string, mut;   g_offsets_count : int, mut; g_offsets_cap : int, mut;
// Alloc 序号 → DF 节点序号映射（修复 3：alloc pts 需要递增位号，provenance 按位号查 alloc 大小）
g_pa_alloc_count : int, mut;
g_pa_alloc_nodes : string, mut;   g_pa_alloc_nodes_cap : int, mut;

// R2 P0 类型项引擎：类型项 DAG 表 + 结构哈希索引 + 判定 memo + 预算守卫
// （表 = 48B/条 {tag,a,b,c,d,hash}，见 type_terms.cr；扩容 grow_type_terms/
//  grow_tt_index 亦在该文件——引擎自持，共享面 dyn_arr.cr 零改动；P0 只建层
//  ——checker/ir_gen/后端零消费者）。
// 惰性 memo 槽（g_tt_top/g_tt_nil）+ 零初值 ready 位：bootstrap 后端只认字面量
// 常量初值（`= -1` 会被降级为 0，见 bootstrap x86_64_stack_asm 的 .quad 0 路径），
// 故以 0 = 未建 + ready 位表达「未初始化」，与本仓库 g_home_dir_ok/g_ext_inited 同式。
g_type_terms : string, mut;        g_type_term_count : int, mut;   g_type_term_cap : int, mut;
g_tt_index : string, mut;          g_tt_index_cap : int, mut;      g_tt_index_count : int, mut;
g_tt_nil : int, mut;               g_tt_nil_ok : int, mut;
g_tt_top : int, mut;               g_tt_top_ok : int, mut;
g_ty_memo_keys : string, mut;      g_ty_memo_vals : string, mut;
g_ty_memo_count : int, mut;        g_ty_memo_cap : int, mut;      g_ty_memo_ok : int, mut;
g_ty_steps : int, mut;             g_ty_budget_max : int, mut;     g_ty_exhausted : int, mut;
g_ty_lits : string, mut;           g_ty_lits_cap : int, mut;       g_ty_lits_count : int, mut;
g_ty_uncovered : int, mut;         // 未覆盖面命中位（如 AK_NAMED 具体行不展开）——P0 只登记不消费

// R2 P2b Task 1：本质条目表（native interface entries，spec §2）——40B/条 × 5 字段
// {ak, ti_row, name_ni, lit_code, ops}，布局常量与表本体（iface_registry.cr）+ 查询 API
// （iface_*）同文件；此处只声明全局（**声明位置约束**：bootstrap 名字解析对变量按声明序、
// 跨文件前向引用不成立——g_purity_inst 先例，globals.cr:290-292；消费者在 checker.cr 之后
// 的层，且本文件恒在最前）。
// **不 alloc g_types 行、不占类型行号**（先例 init_builtins 的 g_rt_builtin_* 旁表）
// ⇒ `.ccr` 类型段/行号零扰动。ok 位 = 惰性建表旗标（0 初值惯例，见上方 g_tt_nil_ok 注记）。
g_iface_entries : string, mut;   g_iface_entry_count : int, mut;   g_iface_registry_ok : int, mut;

// R2 P2b Task 4：操作许可位集的**位下标常量**（spec §2.1「操作许可」；表数据在
// iface_registry.cr 的 ops 列，消费点在 checker.cr 的三个门）。
// 位下标约定（写死，跨 Task 一致）：
//   OP_*  1..14 → **直接用其值**（OP_ADD=1 … OP_ASSIGN=14；OP_AND=12/OP_OR=13 同理，
//                故**不另设** IP_LOGIC——逻辑族的谓词就写 iface_permits(kind, OP_AND)）。
//                注：OP_ASSIGN(14) 位**不使用**——赋值兼容 = type_compat_strict（P2a 引擎面）。
//   UOP_* 1..4  → 经 +IP_UOP_BIAS 偏置（UOP_NEG→21 / UOP_NOT→22 / UOP_REF→23 / UOP_DEREF→24）。
//   新族  25.. → IP_INDEX=25 / IP_INDEX_RANGE=26 / IP_FIELD=27 / IP_METHOD=28 / IP_AS=29
//                / IP_COND=30（真值性：`if` 现状收 bool|int）/ IP_COND_BOOL=31（严格 bool：
//                `while` 现状**只收 bool**——两条规则现状不同，**不得合并成一个「更统一」的位**：
//                合并 = 收紧 `if` 或放宽 `while`）。
// **声明位置约束**（Task 1 实测登记）：bootstrap 名字解析对变量/常量按声明序、跨文件前向引用
// 不成立 —— checker.cr 位于 iface_registry.cr **之前**，故 IP_* 必须声明在本文件（checker.cr 可直接
// 引用 `IP_COND` 等）；**函数**不受此限（checker.cr 可前向引用 iface_* 函数）。
IP_UOP_BIAS : int = 20;
IP_INDEX : int = 25;  IP_INDEX_RANGE : int = 26;  IP_FIELD : int = 27;
IP_METHOD : int = 28; IP_AS : int = 29;  IP_COND : int = 30;  IP_COND_BOOL : int = 31;

// R2 P1：checker ti → 类型项**桥接缓存**（16B/条 {ti, term}；探测/装填因子守卫/扩容重放见
// ty_shadow.cr——桥接层自持，与引擎 g_tt_index 同式）。**这是生产面**（判定路径无条件
// 调用 sh_term_of_ti），非影子调试面。
// **R2 P5 Task 5：原名 `g_shadow_map`/`g_shadow_map_cap`/`g_shadow_entries` 改名**（影子
// 判定通道已随本任务下线；`sh_` 前缀现为历史前缀，语义 = 「桥接/类型项层」）。影子期的
// 调试计数 `g_shadow_hits` 一并删除（其唯一用途 = 影子对账的命中统计）。
// entries 只增不减、恒等于占用槽数 → 兼作扩容判据（不另设 count 全局）。
g_term_map : string, mut;          g_term_map_cap : int, mut;
g_term_map_entries : int, mut;

// R2 P5 Task 2（D19/D23）：DFNode 类型面单槽化的拆分出参 + 建项失败位。
// 出参（Core 无多返回值）：`sh_tk_split` 先置默认（-1 / 0）再写 ⇒ 无残留状态；
// 读点 = ir_gen.cr 的 emit 与 cir_cache.cr 的装载侧（唯一两个分流出参消费面）。
// g_tk_face_fail：类型面 op 的 tk **不可译**（越出类型表 / 桥接缺口，D23）⇒ 计数 +1，
// save 侧拒绝落盘（rc=1 + 诊断，计数入消息）；复合行（域内可译、项不可逆）= 正常
// 路径**不置位**。复位 = init_types()（同 g_replace_* 的生命周期）。
g_sh_slot_term : int, mut;         g_sh_slot_aux : int, mut;
g_tk_face_fail : int, mut;

// **R2 P5 Task 5 删除**（本处 = 影子判定通道的全局态）：`g_shadow_on` / `g_shadow_site` /
// 四分类桶（total/agree/old_stricter/old_looser/unknown + bridge·engine·uncovered·budget
// 拆因）/ 差异环形缓冲（ring/cap/count）/ 站点直方图（site_counts/cap）。影子层 = P1 的
// 迁移期对拍仪器（对照物 = `type_equal_legacy`）：对照物已在 P5 Task 4 删除 ⇒ 对拍停摆
// （全语料 `decisions=0`，见 p5-task5-report 的 gate 节）⇒ 本任务整体下线。
// 判定面回归网自此 = 冻结基线同源对拍 + 行为探针 + 突变控制（见 src/ci/run.sh 的自述）。

// R2 P2a Task 1（F1）：同名 TYP_NAMED 建表去重侧表（开放寻址，16B/条 {name_idx, ti}）。
// 唯一分配点 alloc_named_type 查表命中即复用存量行 → 同一类型名（struct 字面量/泛型
// 应用基型在多处出现）恒占一行。P1 影子对拍 9/9 差异的根因正是「同名多行」：桥接层按行
// 建原子（AK_NAMED 的 b 槽 = 行号）→ 引擎把两行当互异命名类型 → 判不了（unknown）。
// 探测/装填因子守卫/重建重放/回写前重探见 checker.cr（与 ty_shadow.cr 的 g_term_map
// 同式同因——P0/P1 三件套缺一即可能挂死）。count 只增不减、恒等于占用槽数 → 兼作扩容
// 判据（不另设 count 之外的全局）。init_types() 置 cap=0 → 类型表重置（行号空间作废）
// 时侧表随之惰性重建，防「陈旧 name→ti 复用」把已失效行号当命中（silent miscompile）。
g_named_dedup : string, mut;      g_named_dedup_cap : int, mut;   g_named_dedup_count : int, mut;

// R2 P3 Task 0：引擎展开层的 per-ti 缓存（开放寻址，16B/条 {ti, 展开项}）。
// **第二张表**（与 g_term_map 键空间相同 = ti，但**值语义不同**）：本表存**展开项**
// （struct → AK_PRODUCT / enum → AK_SUM 域，见 ty_shadow.cr 展开段），桥接表存**原子名义项**
// （命名类型的等价面身份）。同一 ti 两值不同 ⇒ **不得**共用一张表——共用即让展开项进入
// 等价判定 = 同形不同名类型被判等价 = 语义漂移（裁错边界，见 ty_shadow.cr 头注）。
// 生命周期同 g_term_map：init_types() 置 cap=0（sh_unf_map_reset）→ 类型表重置（行号空间
// 作废）时惰性重建，防陈旧 ti→展开项跨请求复用。探测/装填守卫/重建重放/回写重探见
// ty_shadow.cr（与桥接缓存同式同因；count 只增不减、恒等于占用槽数）。
g_unf_map : string, mut;          g_unf_map_cap : int, mut;
g_unf_entries : int, mut;         g_unf_hits : int, mut;

// 效应/纯度修正 Task 1（P0 插队批）：泛型实例 → 源映射侧表（24B/条
// {src_fi, type_args_ni, inst_fi}，布局同 monomorph.cr 的 g_gen_instances）。
// monomorph 于实例创建时追加（gen_create_instance），compute_all_purity 读它回填
// 泛型源函数的纯度（源 = 实例合取 ⇒「实例与源同值」）。
// **声明位置约束**：bootstrap 的名字解析按声明序（跨文件前向引用不成立）——
// checker.cr 的 compute_all_purity 要用本表，故它必须声明在 checker.cr 之前
// （globals.cr）。grow 帮助函数放 monomorph.cr（函数前向引用合法）。
g_purity_inst : string, mut;    g_purity_inst_count : int, mut;   g_purity_inst_cap : int, mut;

// R2 P2a Task 3 的判定回落计数（g_replace_unknown/g_replace_bridge）**R2 P5 Task 4 删除**：
// 清零判据成立（全语料 replace_*=0）⇒ 回落面已删（legacy 一并删除）；未知面改走 P-A 硬错
// （EC_ICE_TY_INDET，见 checker.cr 的 ty_indeterminate_report）。

fn grow_plugin_tags(needed: int) {
    if needed < g_plugin_tag_cap { return; }
    ncap : ., mut = g_plugin_tag_cap * 2; if ncap < 8 { ncap = 8; } if ncap < needed { ncap = needed + 8; }
    nb := alloc(ncap * 24); _dyncpy(g_plugin_tags, g_plugin_tag_cap * 24, nb); g_plugin_tags = nb; g_plugin_tag_cap = ncap; }

fn grow_plugin_rtypes(needed: int) {
    if needed < g_plugin_rtype_cap { return; }
    ncap : ., mut = g_plugin_rtype_cap * 2; if ncap < 8 { ncap = 8; } if ncap < needed { ncap = needed + 8; }
    nb := alloc(ncap * 24); _dyncpy(g_plugin_rtypes, g_plugin_rtype_cap * 24, nb); g_plugin_rtypes = nb; g_plugin_rtype_cap = ncap; }

fn find_plugin_entry(table: string, count: int, name_ni: int, ns_ni: int) -> int {
    if count <= 0 { return -1; }
    // Linear scan: match (ns, name) pair
    i : ., mut = 0;
    loop { if i >= count { break; }
        if r64(table, i*24+8) == name_ni && r64(table, i*24) == ns_ni { return i; }
        if r64(table, i*24+8) == name_ni && ns_ni < 0 && r64(table, i*24) < 0 { return i; }
    i = i + 1; }
    return -1; }

fn register_plugin_tag(ns_ni: int, name_ni: int, data: int) -> int {
    // Conflict: same (ns, name) can't be registered twice
    if find_plugin_entry(g_plugin_tags, g_plugin_tag_count, name_ni, ns_ni) >= 0 { return -2; }
    // Plugin with namespace can't shadow an unqualified entry
    if ns_ni >= 0 && find_plugin_entry(g_plugin_tags, g_plugin_tag_count, name_ni, -1) >= 0 { return -3; }
    grow_plugin_tags(g_plugin_tag_count + 1);
    w64(g_plugin_tags, g_plugin_tag_count*24, ns_ni);
    w64(g_plugin_tags, g_plugin_tag_count*24+8, name_ni);
    w64(g_plugin_tags, g_plugin_tag_count*24+16, data);
    g_plugin_tag_count = g_plugin_tag_count + 1;
    return 0; }

fn register_plugin_rtype(ns_ni: int, name_ni: int, data: int) -> int {
    if find_plugin_entry(g_plugin_rtypes, g_plugin_rtype_count, name_ni, ns_ni) >= 0 { return -2; }
    if ns_ni >= 0 && find_plugin_entry(g_plugin_rtypes, g_plugin_rtype_count, name_ni, -1) >= 0 { return -3; }
    grow_plugin_rtypes(g_plugin_rtype_count + 1);
    w64(g_plugin_rtypes, g_plugin_rtype_count*24, ns_ni);
    w64(g_plugin_rtypes, g_plugin_rtype_count*24+8, name_ni);
    w64(g_plugin_rtypes, g_plugin_rtype_count*24+16, data);
    g_plugin_rtype_count = g_plugin_rtype_count + 1;
    return 0; }

// ─── 前端状态重置（LSP 进程内重复检查）──────────────────────────────
// 清 count 保留 cap（缓冲复用）；g_strs/g_str_hash 驻留表不重置。
// 与 tokenize/res_imports/parse_all/check_all 各自内部的清零互补——防御
// 上次运行残留（尤其是 parse 阶段诊断后跳过 check_all 时 g_diags 不清零
// 导致的"幽灵诊断"）。g_open_docs 是 LSP 文档源（跨检查持久），不在此清。
fn reset_frontend_state() {
    g_token_count = 0;
    g_ast_count = 0;
    g_error_count = 0;
    g_diag_count = 0;
    g_block_stmt_count = 0;
    g_func_count = 0; g_struct_count = 0; g_enum_count = 0;
    g_sym_count = 0; g_type_count = 0;
    g_iface_count = 0; g_impl_for_count = 0; g_method_count = 0;
    g_type_alias_count = 0; g_generic_constr_count = 0; g_gen_param_count = 0;
    // R2 P3 Task 5：三条新侧表与声明表同生命周期（si/ei/调用点下标跨编译复用——不清则
    // 陈旧约束/绑定被新声明命中，静默错判；照 g_generic_constr_count 同址同因）
    g_sgen_constr_count = 0; g_egen_constr_count = 0; g_gen_binds_count = 0;
    // R2 P3b Task 0：形状条目表与声明表同生命周期（注册名 = 驻留 ni，跨编译复用会命中陈旧条目
    // ⇒ 静默错判；照 g_sgen_constr_count 同址同因）。`g_strs` 驻留表本身不重置（名字 ni 稳定）。
    g_iface_shape_count = 0;
    // 批 6 T2：规约标注侧表与声明表同生命周期（函数名 ni/ast 下标跨编译复用 ⇒ 不清会命中
    // 陈旧标注；照 g_iface_shape_count 同址同因；`g_strs` 驻留表不重置——名字 ni 稳定）。
    g_spec_count = 0;
    g_global_let_count = 0;
    g_loop_depth = 0; g_scope_depth = 0;
    g_borrow_count = 0; g_holder_count = 0;
    g_borrow_scope_depth = 0;
    g_gen_map_count = 0; g_dyn_type_set_count = 0;
    g_mod_func_count = 0; g_mod_path_count = 0;
    g_file_count = 0; g_mod_count = 0;
    // Task 1 侧表与 g_func_count 同生命周期（fi 下标会整体复用——不清则陈旧
    // 映射把新函数的纯度算到旧实例上，静默错标）
    g_purity_inst_count = 0;
    g_df_state_finalized = 0;   // 与上同理：链重建每编译恰一次（幂等旗标随前端状态复位）
    g_seg_count = 0; g_line_count = 0;
    g_unsafe_depth = 0;
    g_alloc_pts_cap = 0;
    g_checker_current_fi = 0;
}
