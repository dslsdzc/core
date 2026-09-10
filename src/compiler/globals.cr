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
g_ast : string, mut;         g_ast_count : int, mut;     g_ast_cap : int, mut;
g_tokens : string, mut;      g_token_count : int, mut;   g_tok_cap : int, mut;
g_errors : string, mut;      g_error_count : int, mut;   g_err_cap : int, mut;
g_block_stmts : string, mut; g_block_stmt_count : int, mut; g_block_stmt_cap : int, mut;
g_ir_vars : string, mut;     g_ir_var_count : int, mut;  g_ir_var_cap : int, mut;
g_ir_instrs : string, mut;   g_ir_instr_count : int, mut; g_ir_instr_cap : int, mut;
g_ir_locals : string, mut;   g_ir_local_count : int, mut; g_ir_local_cap : int, mut;
g_ir_globals : string, mut;  g_ir_global_count : int, mut; g_ir_global_cap : int, mut;
g_ir_str_consts : string, mut; g_ir_str_const_count : int, mut; g_ir_str_const_cap : int, mut;

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
g_gen_params : string, mut;     g_gen_param_count : int, mut;     g_gen_param_cap : int, mut;
g_checker_current_fi : int, mut;
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
g_ty_memo_count : int, mut;        g_ty_memo_cap : int, mut;
g_ty_steps : int, mut;             g_ty_budget_max : int, mut;     g_ty_exhausted : int, mut;
g_ty_lits : string, mut;           g_ty_lits_cap : int, mut;       g_ty_lits_count : int, mut;
g_ty_uncovered : int, mut;         // 未覆盖面命中位（如 AK_NAMED 具体行不展开）——P0 只登记不消费

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
    g_global_let_count = 0;
    g_loop_depth = 0; g_scope_depth = 0;
    g_borrow_count = 0; g_holder_count = 0;
    g_borrow_scope_depth = 0;
    g_gen_map_count = 0; g_dyn_type_set_count = 0;
    g_mod_func_count = 0; g_mod_path_count = 0;
    g_file_count = 0; g_mod_count = 0;
    g_seg_count = 0; g_line_count = 0;
    g_unsafe_depth = 0;
    g_alloc_pts_cap = 0;
    g_checker_current_fi = 0;
}
