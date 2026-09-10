// === interp.cr ===
// Dataflow graph interpreter for -c (eval) mode.
// Interprets g_df_nodes[] (the .cir graph) instead of linear g_ir_instrs[] (.ccr).
// The DFG preserves type/semantic information throughout execution.
//
// Limitations:
// - String constants: 解释器不调用 syscall3，alloc/print/syscall 相关函数返回 0
// - 递归/跨函数调用：inline 执行不支持 IR_CALL，只处理 main→callee 的单层调用
// - for 循环：dataflow 图按顺序执行，label/branch 机制不与 for 循环兼容

g_ir_vals : string, mut;    g_ir_vals_cap : int, mut;

// IR_BINARY 统一分派（主循环与 callee 内联循环共用）：
// 整数路径（模 2⁶⁴）。dex 为缩放整数——同走整数路径（数值迁移 #48 定稿）；
// IR_I2F/IR_F2I 在 dispatch 入口显式报错（interp 无 binary64 语义）。
fn ir_interp_binary(d: int, s1: int, s2: int, s3: int, ti: int) {
    if d < 0 { return; }
    lv := r64(g_ir_vals, s1 * 8); rv := r64(g_ir_vals, s2 * 8);
    if s3 == 1  { w64(g_ir_vals, d * 8, lv + rv); }
    if s3 == 2  { w64(g_ir_vals, d * 8, lv - rv); }
    if s3 == 3  { w64(g_ir_vals, d * 8, lv * rv); }
    if s3 == 4  { w64(g_ir_vals, d * 8, lv / rv); }
    if s3 == 5  { w64(g_ir_vals, d * 8, lv % rv); }
    if s3 == 6  { if lv == rv { w64(g_ir_vals, d * 8, 1); } else { w64(g_ir_vals, d * 8, 0); } }
    if s3 == 7  { if lv != rv { w64(g_ir_vals, d * 8, 1); } else { w64(g_ir_vals, d * 8, 0); } }
    if s3 == 8  { if lv < rv  { w64(g_ir_vals, d * 8, 1); } else { w64(g_ir_vals, d * 8, 0); } }
    if s3 == 9  { if lv > rv  { w64(g_ir_vals, d * 8, 1); } else { w64(g_ir_vals, d * 8, 0); } }
    if s3 == 10 { if lv <= rv { w64(g_ir_vals, d * 8, 1); } else { w64(g_ir_vals, d * 8, 0); } }
    if s3 == 11 { if lv >= rv { w64(g_ir_vals, d * 8, 1); } else { w64(g_ir_vals, d * 8, 0); } }
    if s3 == 12 { if lv != 0 && rv != 0 { w64(g_ir_vals, d * 8, 1); } else { w64(g_ir_vals, d * 8, 0); } }
    if s3 == 13 { if lv != 0 || rv != 0 { w64(g_ir_vals, d * 8, 1); } else { w64(g_ir_vals, d * 8, 0); } }
    if s3 == 17 { w64(g_ir_vals, d * 8, lv + rv * 8); }   // OP_PTR_ADD
    if s3 == 18 { w64(g_ir_vals, d * 8, lv - rv * 8); }   // OP_PTR_SUB
    if s3 == 19 { w64(g_ir_vals, d * 8, (lv - rv) / 8); }  // OP_PTR_DIFF
}

// 指针间接读写（近似，对照 ELF 语义）：
// 槽号（0 ≤ ptr < g_ir_var_count）= 栈变量的「地址」（REF 给的槽索引）→ 读写该槽；
// 其余 = 堆地址（alloc/ALLOC_ARRAY 产出的真实指针）→ 读写内存。
fn ir_interp_deref_read(ptr: int) -> int {
    if ptr >= 0 && ptr < g_ir_var_count { return r64(g_ir_vals, ptr * 8); }
    return r64(ptr, 0);
}
fn ir_interp_deref_write(ptr: int, val: int) {
    if ptr >= 0 && ptr < g_ir_var_count { w64(g_ir_vals, ptr * 8, val); }
    else { w64(ptr, 0, val); }
}

// Interpreter string values are intern-table indices (IR_CONST stores the
// index, while native ELF stores a pointer). Keep string builtins in that same
// representation instead of passing the index to pointer-based helpers.
fn ir_interp_str_concat(a: int, b: int) -> int {
    out : string, mut = "";
    out = out + istr_get(a);
    out = out + istr_get(b);
    return str_intern(out);
}

fn ir_interp_str_char(a: int, i: int) -> int {
    return str_intern(get_char(istr_get(a), i));
}

fn ir_interp_str_sub(a: int, start: int, len: int) -> int {
    return str_intern(str_sub(istr_get(a), start, len));
}

fn ir_interpret() -> int {
    // Find main function in the dataflow graph
    main_idx : ., mut = -1;
    fi : ., mut = 0;
    loop {
        if fi >= g_ir_func_count { break; }
        ni := r64(g_ir_func_name_idx, fi * 8);
        if str_eq(istr_get(ni), "main") != 0 { main_idx = fi; break; }
        fi = fi + 1;
    }
    if main_idx < 0 { return -1; }
    node_start := r64(g_df_func_node_start, main_idx * 8);
    node_count := r64(g_df_func_node_count, main_idx * 8);
    if node_start < 0 || node_count <= 0 { return -1; }

    // 返回值暂存槽（callee 内联路径的 return 传递）。旧约定用 g_ir_vals[0]：
    // 槽 0 = 第一个 IR 变量，而文件级全局按序注册在最前（ir_gen_globals 先于
    // ir_gen_func）——全局在解释器槽模型里就是 g_ir_vals 的槽，于是每次 callee
    // 返回都静默覆写第一个全局。改为 g_ir_var_count：清零区 need 内的首个填充槽，
    // 不与任何真变量重叠。
    ret_slot := g_ir_var_count;

    // Initialize value store (size = node_count + padding for destinations)
    need := g_ir_var_count + 64;
    if g_ir_vals_cap < need {
        g_ir_vals = alloc(need * 8);
        g_ir_vals_cap = need;
    }
    vi : ., mut = 0;
    loop {
        if vi >= need { break; }
        w64(g_ir_vals, vi * 8, 0);
        vi = vi + 1;
    }

    // 编译期标量常量全局初始化阶段——与 ELF _start 的常量初始化循环
    // （os/linux/entry.cr 的 g_ir_globals +16 环）同语义、同数据源。此前解释器
    // 无此阶段：可变标量全局读回 0（不可变标量因 find_global_const_node 折叠
    // 而侥幸正确）。运行期初始化的聚合/非常量全局不在此——它们在 main 序言以
    // IR 序列注入（ir_gen.cr inject_global_inits，主循环执行）。
    gi2 : ., mut = 0;
    loop {
        if gi2 >= g_ir_global_count { break; }
        iv2 := r64(g_ir_globals, gi2 * 24 + 16);
        gv2 := r64(g_ir_globals, gi2 * 24 + 8);
        if iv2 != 0 && gv2 >= 0 && gv2 < need { w64(g_ir_vals, gv2 * 8, iv2); }
        gi2 = gi2 + 1;
    }

    // Pre-scan: build label→node mapping (for branches)
    g_label_count = 0;
    li : ., mut = 0;
    loop {
        if li >= node_count { break; }
        n_op := r64(g_df_nodes, (node_start + li) * ESZ_DFNODE + OFF_DF_OPCODE);
        n_s1 := r64(g_df_nodes, (node_start + li) * ESZ_DFNODE + OFF_DF_S1);
        if n_op == 21 {  // IR_LABEL
            ln := n_s1;  // label number
            if ln >= 0 {
                grow_label_poses(ln + 1);
                w64(g_label_poses, ln * 8, li);
                if ln + 1 > g_label_count { g_label_count = ln + 1; }
            }
        }
        li = li + 1;
    }

    // Pre-scan: record SG_LOOP/SG_FOR region enter/exit node offsets
    // (main function graph only — filter by node_start..node_start+node_count)
    g_loop_region_count = 0;
    li = 0;
    loop {
        if li >= g_sg_count { break; }
        lk := r64(g_sgs, li * ESZ_SG + OFF_SG_KIND);
        if lk == SG_LOOP || lk == SG_FOR {
            l_enter := r64(g_sgs, li * ESZ_SG + OFF_SG_ENTER);
            l_exit  := r64(g_sgs, li * ESZ_SG + OFF_SG_EXIT);
            if l_enter >= node_start && l_enter < node_start + node_count {
                if g_loop_region_count + 1 > g_loop_region_cap {
                    // Grow both arrays from the OLD cap — copying with the new
                    // cap would over-read the previous (possibly empty) buffer.
                    nc := g_loop_region_cap * 2; if nc < 16 { nc = 16; }
                    nb := alloc(nc * 8); _dyncpy(g_loop_region_enter, g_loop_region_cap * 8, nb);
                    nb2 := alloc(nc * 8); _dyncpy(g_loop_region_exit, g_loop_region_cap * 8, nb2);
                    g_loop_region_enter = nb; g_loop_region_exit = nb2; g_loop_region_cap = nc;
                }
                w64(g_loop_region_enter, g_loop_region_count * 8, l_enter - node_start);
                w64(g_loop_region_exit,  g_loop_region_count * 8, l_exit  - node_start);
                g_loop_region_count = g_loop_region_count + 1;
            }
        }
        li = li + 1;
    }

    // Execute nodes in order (dataflow: sequential order = valid topological order for straight-line)
    ip : ., mut = 0;
    loop {
        if ip >= node_count { break; }
        op := r64(g_df_nodes, (node_start + ip) * ESZ_DFNODE + OFF_DF_OPCODE);
        d := r64(g_df_nodes, (node_start + ip) * ESZ_DFNODE + OFF_DF_DEST);
        s1 := r64(g_df_nodes, (node_start + ip) * ESZ_DFNODE + OFF_DF_S1);
        s2 := r64(g_df_nodes, (node_start + ip) * ESZ_DFNODE + OFF_DF_S2);
        s3 := r64(g_df_nodes, (node_start + ip) * ESZ_DFNODE + OFF_DF_S3);
        ti := r64(g_df_nodes, (node_start + ip) * ESZ_DFNODE + OFF_DF_TK);

        if op == 1  { if d >= 0 { w64(g_ir_vals, d * 8, s1); } }  // IR_CONST（dex 的 s1 为缩放整数）
        if op == 5  { if s1 >= 0 { return r64(g_ir_vals, s1 * 8); } return 0; }  // IR_RETURN

        if op == 2 { ir_interp_binary(d, s1, s2, s3, ti); }  // IR_BINARY

        if op == 3 {  // IR_UNARY
            ov := r64(g_ir_vals, s1 * 8);
            if s3 == 1 { w64(g_ir_vals, d * 8, -ov); }
            if s3 == 2 { if ov == 0 { w64(g_ir_vals, d * 8, 1); } else { w64(g_ir_vals, d * 8, 0); } }
        }

        // Alloc / Store / Load / Field / Index
        if op == 6 { if d >= 0 { w64(g_ir_vals, d * 8, 0); } }  // IR_ALLOC
        if op == 7 {  // IR_ALLOC_STRUCT
            if d >= 0 {
                si := find_struct(s3);
                fc : ., mut = 0;
                if si >= 0 { fc = si_field_count(si); }
                need2 := fc * 8 + 8;
                bp := alloc(need2);
                vi2 : ., mut = 0;
                loop { if vi2 >= need2 { break; } store8(bp, vi2, 0); vi2 = vi2 + 1; }
                w64(g_ir_vals, d * 8, bp);
            }
        }
        if op == 8 {  // IR_ALLOC_ARRAY
            if d >= 0 {
                cnt := s1; esz := s2;
                if esz <= 0 { esz = 8; }
                need2 := cnt * esz + 8;
                bp := alloc(need2);
                vi2 : ., mut = 0;
                loop { if vi2 >= need2 { break; } store8(bp, vi2, 0); vi2 = vi2 + 1; }
                w64(g_ir_vals, d * 8, bp);
            }
        }
        if op == 9 { if s1 >= 0 && s2 >= 0 { w64(g_ir_vals, s1 * 8, r64(g_ir_vals, s2 * 8)); } }  // IR_STORE
        if op == 10 { if d >= 0 { w64(g_ir_vals, d * 8, r64(g_ir_vals, s1 * 8)); } }  // IR_LOAD
        if op == 11 {  // IR_LOAD_FIELD: s1=struct_var, s3=field_idx
            if d >= 0 && s1 >= 0 {
                ptr := r64(g_ir_vals, s1 * 8);
                if ptr != 0 { w64(g_ir_vals, d * 8, r64(ptr, s3 * 8)); }
                else { w64(g_ir_vals, d * 8, r64(g_ir_vals, s1 * 8)); }
            }
        }
        if op == 12 {  // IR_STORE_FIELD: s1=struct_var, s2=val_var, s3=field_idx
            if s1 >= 0 && s2 >= 0 {
                ptr := r64(g_ir_vals, s1 * 8);
                if ptr != 0 { w64(ptr, s3 * 8, r64(g_ir_vals, s2 * 8)); }
                else { w64(g_ir_vals, s1 * 8, r64(g_ir_vals, s2 * 8)); }
            }
        }
        if op == 13 {  // IR_LOAD_INDEX: s1=arr_var, s3=literal_idx
            if d >= 0 && s1 >= 0 {
                arr_value := r64(g_ir_vals, s1 * 8);
                if irv_type(s1) == TI_STR { w64(g_ir_vals, d * 8, str_load8(arr_value, s3)); }
                else { w64(g_ir_vals, d * 8, r64(arr_value, s3 * 8)); }
            }
        }
        if op == 14 {  // IR_STORE_INDEX: s1=arr_var, s2=val_var, s3=literal_idx
            if s1 >= 0 && s2 >= 0 {
                arr_value := r64(g_ir_vals, s1 * 8);
                if irv_type(s1) == TI_STR { store8(istr_get(arr_value), s3, r64(g_ir_vals, s2 * 8)); }
                else { w64(arr_value, s3 * 8, r64(g_ir_vals, s2 * 8)); }
            }
        }
        if op == 15 {  // IR_LOAD_INDEX_VAR: s1=arr_var, s2=idx_var
            if d >= 0 && s1 >= 0 && s2 >= 0 {
                arr_value := r64(g_ir_vals, s1 * 8);
                idx := r64(g_ir_vals, s2 * 8);
                if irv_type(s1) == TI_STR { w64(g_ir_vals, d * 8, str_load8(arr_value, idx)); }
                else { w64(g_ir_vals, d * 8, r64(arr_value, idx * 8)); }
            }
        }
        if op == 16 {  // IR_STORE_INDEX_VAR: d=val_var, s1=arr_var, s2=idx_var
            if d >= 0 && s1 >= 0 && s2 >= 0 {
                arr_value := r64(g_ir_vals, s1 * 8);
                idx := r64(g_ir_vals, s2 * 8);
                if irv_type(s1) == TI_STR { store8(istr_get(arr_value), idx, r64(g_ir_vals, d * 8)); }
                else { w64(arr_value, idx * 8, r64(g_ir_vals, d * 8)); }
            }
        }
        // IR_MAKE_ENUM (17)：d := alloc(8·(1+s2))；M[d+0] := s1（tag = 变体名索引）——
        // 与 ELF 布局 [tag][payload...] 一致的堆镜像（payload 由后续 IR_STORE_FIELD 写堆）
        if op == 17 {
            if d >= 0 {
                need2 := 8 + s2 * 8;
                bp := alloc(need2);
                vi2 : ., mut = 0;
                loop { if vi2 >= need2 { break; } store8(bp, vi2, 0); vi2 = vi2 + 1; }
                w64(bp, 0, s1);
                w64(g_ir_vals, d * 8, bp);
            }
        }
        // IR_LOAD_ENUM_TAG (23)：d := M[ρ(s1)+0]
        if op == 23 {
            if d >= 0 && s1 >= 0 {
                ptr := r64(g_ir_vals, s1 * 8);
                if ptr != 0 { w64(g_ir_vals, d * 8, r64(ptr, 0)); }
            }
        }
        // IR_REF (18)：d := &ρ(s1)——槽模型近似：槽号即「地址」（ir_interp_deref_* 同规则）
        if op == 18 { if d >= 0 && s1 >= 0 { w64(g_ir_vals, d * 8, s1); } }
        // IR_DEREF (25)：d := M[ρ(s1)]（栈槽间接或堆读取，见 ir_interp_deref_read）
        if op == 25 {
            if d >= 0 && s1 >= 0 {
                w64(g_ir_vals, d * 8, ir_interp_deref_read(r64(g_ir_vals, s1 * 8)));
            }
        }

        // IR_SLICE (24): d := arr + low*8（与 ELF 编码一致；BC11 补实现）
        if op == 24 {
            if d >= 0 && s1 >= 0 && s2 >= 0 {
                w64(g_ir_vals, d * 8, r64(g_ir_vals, s1 * 8) + r64(g_ir_vals, s2 * 8) * 8);
            }
        }

        // IR_BOUNDS_CHECK (30): s1=index var, s2=max_len 字面量 —
        // index < 0 或 index >= max → 陷阱（返回 -1 表示中止；BC11 补实现）
        if op == 30 && s2 >= 0 {
            iv := r64(g_ir_vals, s1 * 8);
            limit : ., mut = s2;
            if ti == 1 { limit = r64(g_ir_vals, s2 * 8); }
            if iv < 0 || iv >= limit { return -1; }
        }

        // IR_LAZY_THUNK / IR_LAZY_FORCE. Calls are currently eager, so both
        // wrappers preserve the computed value.
        if op == 46 || op == 47 {
            if d >= 0 && s1 >= 0 { w64(g_ir_vals, d * 8, r64(g_ir_vals, s1 * 8)); }
        }

        // IR_YIELD (28)：eager 值传递近似（d ← ρ(s1)，同 IR_AWAIT）。
        // F5a：补 d >= 0 守卫——发射恒 dest=-1（ir_gen L1569），原代码
        // w64(g_ir_vals, d*8 = -8, ...) 堆下溢写（g_ir_vals[-8]，静默 UB）。
        if op == 28 {
            if d >= 0 && s1 >= 0 { w64(g_ir_vals, d * 8, r64(g_ir_vals, s1 * 8)); }
        }

        // IR_FNADDR — no real addresses in the interpreter; dest = 0
        if op == 48 {
            if d >= 0 { w64(g_ir_vals, d * 8, 0); }
        }

        // IR_APPROX — pure annotation, skip（无运算语义，不能崩）
        if op == 51 { ip = ip + 1; continue; }

        // IR_I2F(49) / IR_F2I(50)——int↔binary64 转换：解释器无 binary64 语义
        // （数值迁移 Task 6 定稿）。apx dex 运算必然经过 bits↔缩放转换（打印/边界），
        // 此处显式报错替代静默跳过——跳过会让目的槽残留 0/脏值，后续除法可能 SIGFPE。
        if op == 49 || op == 50 {
            println("interpreter error: IR_I2F/IR_F2I needs binary64 semantics (apx dex) — `corec run` cannot execute apx dex arithmetic; build & run natively (corec build) instead");
            return -1;
        }

        // IR_STORE_PTR (26)：M[ρ(s1)] := ρ(s2)（与 ELF 操作数一致；d=-1 发射态不再影响）。
        // 栈槽间接（指针 = 槽号）或堆写入，见 ir_interp_deref_write。
        if op == 26 { if s1 >= 0 && s2 >= 0 { ir_interp_deref_write(r64(g_ir_vals, s1 * 8), r64(g_ir_vals, s2 * 8)); } }

        // IR_ADDR_INDEX (31)：d := ρ(s1) + 8·ρ(s2)（&arr[i]；s3=scale 恒 3，与 ELF 一致）
        if op == 31 {
            if d >= 0 && s1 >= 0 && s2 >= 0 {
                w64(g_ir_vals, d * 8, r64(g_ir_vals, s1 * 8) + r64(g_ir_vals, s2 * 8) * 8);
            }
        }
        // IR_ARENA_NEW (32) / IR_ARENA_RESET (33)：interp 无 arena——no-op 近似
        // （对照语义表 2.4 的 D7：ELF 有 arena 句柄/复位；解释器槽模型无作用域内存概念）
        if op == 32 { if d >= 0 { w64(g_ir_vals, d * 8, 0); } }
        if op == 33 { }

        // IR_DYN_PACK (43)：dyn 变量双槽 [value, tag]——slot[d]=值、slot[d+1]=tag（对照 ELF slot+0/+8）
        if op == 43 {
            if d >= 0 && s1 >= 0 {
                w64(g_ir_vals, d * 8, r64(g_ir_vals, s1 * 8));
                w64(g_ir_vals, (d + 1) * 8, s2);
            }
        }
        // IR_DYN_TAG (41)：d := slot[ρ(s1)+1]（读 +8 槽）
        if op == 41 { if d >= 0 && s1 >= 0 { w64(g_ir_vals, d * 8, r64(g_ir_vals, (s1 + 1) * 8)); } }
        // IR_DYN_VAL (42)：d := slot[ρ(s1)]（读 +0 槽）
        if op == 42 { if d >= 0 && s1 >= 0 { w64(g_ir_vals, d * 8, r64(g_ir_vals, s1 * 8)); } }

        // IR_DYN_DISPATCH (44)：显式报错（不再静默跳过；对照 ELF 的占位实现——见语义表 2.6 BC9）
        if op == 44 {
            println("error: interp 不支持动态分发（IR_DYN_DISPATCH）");
            return 2;
        }
        // IR_CALL_EXTERN (45)：显式报错（不再静默错值；ELF 静态构建同样拒绝，见 F16）
        if op == 45 {
            print("error: interp 无法调用外部函数："); println(istr_get(s1));
            return 2;
        }

        // IR_I2F(49)/IR_F2I(50) 在 dispatch 入口已被显式报错拦截（#48 定稿：interp 无 binary64）

        // Branch (node-index based)
        if op == 19 {
            cv := r64(g_ir_vals, s1 * 8);
            if cv != 0 { if s2 >= 0 && s2 < g_label_count { ip = r64(g_label_poses, s2 * 8); } }
            else       { if s3 >= 0 && s3 < g_label_count { ip = r64(g_label_poses, s3 * 8); } }
            if ip < node_count { continue; } else { break; }
        }
        if op == 20 {  // IR_JUMP
            // Region iteration: a jump whose target is the innermost
            // enclosing loop region's enter is a back-edge — loop iteration
            // is driven by the region (SG) table: ip is taken from
            // g_loop_region_enter, NOT from the label table.  Every other
            // jump is a plain label jump resolved via g_label_poses.
            // (The region enter from the SG table equals the label pose of
            // the same node; the point is the code path: back-edges never
            // read g_label_poses.)
            // Innermost loop region enclosing the current ip (if any):
            // among regions containing ip, the one with the largest enter
            // offset is the innermost (e2 > cur_enter selection).
            cur_enter : ., mut = -1;
            cur_ri : ., mut = -1;
            ri2 : ., mut = 0;
            loop {
                if ri2 >= g_loop_region_count { break; }
                e2 := r64(g_loop_region_enter, ri2 * 8);
                x2 := r64(g_loop_region_exit,  ri2 * 8);
                if ip >= e2 && ip < x2 && e2 > cur_enter { cur_enter = e2; cur_ri = ri2; }
                ri2 = ri2 + 1;
            }
            if s1 >= 0 && s1 < g_label_count {
                target := r64(g_label_poses, s1 * 8);
                if target >= 0 {
                    if cur_ri >= 0 && target == cur_enter {
                        // Back-edge to the innermost loop region's enter:
                        // ip comes from the region table, not label poses.
                        ip = r64(g_loop_region_enter, cur_ri * 8);  // == cur_enter
                    } else {
                        ip = target;  // plain jump, resolved via label poses
                    }
                } else { ip = ip + 1; }
            } else { ip = ip + 1; }
            if ip < node_count { continue; } else { break; }
        }
        // IR_LABEL (21) - noop

        // IR_AWAIT
        if op == 29 { if d >= 0 { w64(g_ir_vals, d * 8, r64(g_ir_vals, s1 * 8)); } }

        // IR_CALL or IR_SPAWN — only handles direct calls from main's graph
        // Inline-executed callee graphs do NOT support nested calls.
        if op == 4 || op == 27 {
            fn_ni := s3;
            fn_name := istr_get(fn_ni);
            sfi := find_so_fn(fn_ni);
            if sfi >= 0 && s2 >= 1 {
                tf := sym_type(sfi);
                if tf == 1 || tf == 3 {  // TAG_VARIADIC: print/println — NOOP (syscall3 returns 0)
                } else if tf == 2 || tf == 3 {  // TAG_AUTO_STR: print_i/println_i — NOOP (syscall3 returns 0)
                }
            }
            // syscall3/syscall4 — interpreter returns 0
            if str_eq(fn_name, "syscall3") != 0 || str_eq(fn_name, "syscall4") != 0 {
                if d >= 0 { w64(g_ir_vals, d * 8, 0); }
            }
            if str_eq(fn_name, "str_len") != 0 {
                if d >= 0 && s2 >= 1 { w64(g_ir_vals, d * 8, istr_len(r64(g_ir_vals, s1 * 8))); }
            }
            if str_eq(fn_name, "str_eq") != 0 {
                if d >= 0 && s2 >= 2 {
                    left_s := istr_get(r64(g_ir_vals, s1 * 8));
                    right_s := istr_get(r64(g_ir_vals, (s1 + 1) * 8));
                    w64(g_ir_vals, d * 8, str_eq(left_s, right_s));
                }
            }
            if str_eq(fn_name, "concat") != 0 {
                if d >= 0 && s2 >= 2 {
                    w64(g_ir_vals, d * 8, ir_interp_str_concat(
                        r64(g_ir_vals, s1 * 8), r64(g_ir_vals, (s1 + 1) * 8)));
                }
            }
            if str_eq(fn_name, "int_str") != 0 {
                if d >= 0 && s2 >= 1 { w64(g_ir_vals, d * 8, str_intern(int_str(r64(g_ir_vals, s1 * 8)))); }
            }
            if str_eq(fn_name, "chr") != 0 {
                if d >= 0 && s2 >= 1 { w64(g_ir_vals, d * 8, str_intern(chr(r64(g_ir_vals, s1 * 8)))); }
            }
            if str_eq(fn_name, "get_char") != 0 {
                if d >= 0 && s2 >= 2 { w64(g_ir_vals, d * 8, ir_interp_str_char(r64(g_ir_vals, s1 * 8), r64(g_ir_vals, (s1 + 1) * 8))); }
            }
            if str_eq(fn_name, "str_sub") != 0 {
                if d >= 0 && s2 >= 3 { w64(g_ir_vals, d * 8, ir_interp_str_sub(r64(g_ir_vals, s1 * 8), r64(g_ir_vals, (s1 + 1) * 8), r64(g_ir_vals, (s1 + 2) * 8))); }
            }
            if str_eq(fn_name, "load_str_ptr") != 0 {
                if d >= 0 && s2 >= 2 {
                    b := r64(g_ir_vals, s1 * 8); p := r64(g_ir_vals, s1 + 1 * 8);
                    lo := load8(b, p) + load8(b, p+1)*256 +
                          load8(b, p+2)*65536 + load8(b, p+3)*16777216;
                    hi := load8(b, p+4) + load8(b, p+5)*256 +
                          load8(b, p+6)*65536 + load8(b, p+7)*16777216;
                    if hi < 0 { hi = hi + 4294967296; }
                    w64(g_ir_vals, d * 8, lo + hi * 4294967296);
                }
            }
            if str_eq(fn_name, "store_str_ptr") != 0 {
                if s2 >= 3 {
                    b := r64(g_ir_vals, s1 * 8); p := r64(g_ir_vals, s1 + 1 * 8); v := r64(g_ir_vals, s1 + 2 * 8);
                    lo : ., mut = v % 4294967296; hi : ., mut = v / 4294967296;
                    if v < 0 { lo = v; hi = -1; }
                    store8(b, p, lo%256);     store8(b, p+1, (lo/256)%256);
                    store8(b, p+2, (lo/65536)%256); store8(b, p+3, (lo/16777216)%256);
                    store8(b, p+4, hi%256);   store8(b, p+5, (hi/256)%256);
                    store8(b, p+6, (hi/65536)%256); store8(b, p+7, (hi/16777216)%256);
                }
                if d >= 0 { w64(g_ir_vals, d * 8, 0); }
            }
            if str_eq(fn_name, "str_len") != 0 || str_eq(fn_name, "str_eq") != 0 ||
               str_eq(fn_name, "concat") != 0 || str_eq(fn_name, "int_str") != 0 ||
               str_eq(fn_name, "chr") != 0 || str_eq(fn_name, "get_char") != 0 ||
               str_eq(fn_name, "str_sub") != 0 { ip = ip + 1; continue; }
            // Regular function call (single level — no recursive/nested call support)
            if d >= 0 {
                cfi : ., mut = 0;
                loop {
                    if cfi >= g_ir_func_count { break; }
                    if r64(g_ir_func_name_idx, cfi * 8) == fn_ni {
                        f_start := r64(g_df_func_node_start, cfi * 8);
                        f_count := r64(g_df_func_node_count, cfi * 8);
                        if f_start >= 0 && f_count > 0 {
                            // 暂存槽清零：callee 无值返回（IR_RETURN s1<0，如裸 return/尾
                            // 部隐式返回）时调用方读到的应是 0，而非上次调用的残留。
                            w64(g_ir_vals, ret_slot * 8, 0);
                            // Save label state
                            old_lc := g_label_count;
                            old_poses := g_label_poses;
                            old_poses_cap := g_label_cap;
                            g_label_poses = alloc(64 * 8); g_label_cap = 64;
                            // Build label map for callee
                            li2 : ., mut = 0;
                            loop { if li2 >= f_count { break; }
                                n_op := r64(g_df_nodes, (f_start + li2) * ESZ_DFNODE + OFF_DF_OPCODE);
                                n_s1 := r64(g_df_nodes, (f_start + li2) * ESZ_DFNODE + OFF_DF_S1);
                                if n_op == 21 { if n_s1 >= 0 {
                                    grow_label_poses(n_s1 + 1);
                                    w64(g_label_poses, n_s1 * 8, li2);
                                    if n_s1 + 1 > g_label_count { g_label_count = n_s1 + 1; }
                                }}
                            li2 = li2 + 1; }
                            // Copy args from caller positions to callee param vars
                            pstart := r64(g_ir_func_var_start, cfi * 8);
                            pai : ., mut = 0;
                            loop { if pai >= s2 { break; }
                                w64(g_ir_vals, (pstart + pai) * 8, r64(g_ir_vals, (s1 + pai) * 8));
                            pai = pai + 1; }
                            // Execute callee graph (inline)
                            ip2 : ., mut = 0;
                            loop {
                                if ip2 >= f_count { break; }
                                op2 := r64(g_df_nodes, (f_start + ip2) * ESZ_DFNODE + OFF_DF_OPCODE);
                                d2 := r64(g_df_nodes, (f_start + ip2) * ESZ_DFNODE + OFF_DF_DEST);
                                t1 := r64(g_df_nodes, (f_start + ip2) * ESZ_DFNODE + OFF_DF_S1);
                                t2 := r64(g_df_nodes, (f_start + ip2) * ESZ_DFNODE + OFF_DF_S2);
                                t3 := r64(g_df_nodes, (f_start + ip2) * ESZ_DFNODE + OFF_DF_S3);
                                t4 := r64(g_df_nodes, (f_start + ip2) * ESZ_DFNODE + OFF_DF_TK);
                                if op2 == 1 && d2 >= 0 { w64(g_ir_vals, d2 * 8, t1); }
                                if op2 == 2 && t1 >= 0 && t2 >= 0 { ir_interp_binary(d2, t1, t2, t3, t4); }
                                if op2 == 49 || op2 == 50 { println("interpreter error: IR_I2F/IR_F2I needs binary64 semantics (apx dex)"); return -1; }
                                if op2 == 3 && t1 >= 0 {
                                    ov2 := r64(g_ir_vals, t1 * 8);
                                    if t3 == 1 { w64(g_ir_vals, d2 * 8, -ov2); }
                                    else if t3 == 2 { if ov2 == 0 { w64(g_ir_vals, d2 * 8, 1); } else { w64(g_ir_vals, d2 * 8, 0); } } }
                                // Keep callee locals in the shared value store.
                                // The old inline path skipped these opcodes, so
                                // loop-carried assignments never changed state.
                                if op2 == 6 && d2 >= 0 { w64(g_ir_vals, d2 * 8, 0); }  // IR_ALLOC
                                if op2 == 9 && t1 >= 0 && t2 >= 0 { w64(g_ir_vals, t1 * 8, r64(g_ir_vals, t2 * 8)); }  // IR_STORE
                                if op2 == 10 && d2 >= 0 && t1 >= 0 { w64(g_ir_vals, d2 * 8, r64(g_ir_vals, t1 * 8)); }  // IR_LOAD
                                // 聚合族（与主循环 IR_ALLOC_ARRAY/IR_ALLOC_STRUCT/LOAD|STORE_INDEX
                                // /LOAD|STORE_FIELD/ADDR_INDEX 同语义）：此前外函数内联路径缺这组
                                // opcode——callee 里读写聚合全局（数组/结构体）静默落 0。本批
                                // §1.3 让这类全局在 main 序言获得运行期存储（ir_gen.cr），callee
                                // 侧的读路径必须同批补齐，否则双路径语义仍分叉。
                                if op2 == 8 && d2 >= 0 {  // IR_ALLOC_ARRAY
                                    cnt2 := t1; esz2 := t2;
                                    if esz2 <= 0 { esz2 = 8; }
                                    need3 := cnt2 * esz2 + 8;
                                    bp2 := alloc(need3);
                                    vi3 : ., mut = 0;
                                    loop { if vi3 >= need3 { break; } store8(bp2, vi3, 0); vi3 = vi3 + 1; }
                                    w64(g_ir_vals, d2 * 8, bp2);
                                }
                                if op2 == 13 && d2 >= 0 && t1 >= 0 {  // IR_LOAD_INDEX: t1=arr_var, t3=literal_idx
                                    av2 := r64(g_ir_vals, t1 * 8);
                                    if irv_type(t1) == TI_STR { w64(g_ir_vals, d2 * 8, str_load8(av2, t3)); }
                                    else { w64(g_ir_vals, d2 * 8, r64(av2, t3 * 8)); }
                                }
                                if op2 == 14 && t1 >= 0 && t2 >= 0 {  // IR_STORE_INDEX: t1=arr_var, t2=val_var
                                    av2 := r64(g_ir_vals, t1 * 8);
                                    if irv_type(t1) == TI_STR { store8(istr_get(av2), t3, r64(g_ir_vals, t2 * 8)); }
                                    else { w64(av2, t3 * 8, r64(g_ir_vals, t2 * 8)); }
                                }
                                if op2 == 15 && d2 >= 0 && t1 >= 0 && t2 >= 0 {  // IR_LOAD_INDEX_VAR: t1=arr_var, t2=idx_var
                                    av2 := r64(g_ir_vals, t1 * 8);
                                    ix2 := r64(g_ir_vals, t2 * 8);
                                    if irv_type(t1) == TI_STR { w64(g_ir_vals, d2 * 8, str_load8(av2, ix2)); }
                                    else { w64(g_ir_vals, d2 * 8, r64(av2, ix2 * 8)); }
                                }
                                if op2 == 16 && d2 >= 0 && t1 >= 0 && t2 >= 0 {  // IR_STORE_INDEX_VAR: d2=val_var, t1=arr_var, t2=idx_var
                                    av2 := r64(g_ir_vals, t1 * 8);
                                    ix2 := r64(g_ir_vals, t2 * 8);
                                    if irv_type(t1) == TI_STR { store8(istr_get(av2), ix2, r64(g_ir_vals, d2 * 8)); }
                                    else { w64(av2, ix2 * 8, r64(g_ir_vals, d2 * 8)); }
                                }
                                if op2 == 31 && d2 >= 0 && t1 >= 0 && t2 >= 0 {  // IR_ADDR_INDEX: &arr[i]
                                    w64(g_ir_vals, d2 * 8, r64(g_ir_vals, t1 * 8) + r64(g_ir_vals, t2 * 8) * 8);
                                }
                                if op2 == 11 && d2 >= 0 && t1 >= 0 {  // IR_LOAD_FIELD: t1=struct_var, t3=field_idx
                                    pf2 := r64(g_ir_vals, t1 * 8);
                                    if pf2 != 0 { w64(g_ir_vals, d2 * 8, r64(pf2, t3 * 8)); }
                                    else { w64(g_ir_vals, d2 * 8, r64(g_ir_vals, t1 * 8)); }
                                }
                                if op2 == 12 && t1 >= 0 && t2 >= 0 {  // IR_STORE_FIELD: t1=struct_var, t2=val_var, t3=field_idx
                                    pf2 := r64(g_ir_vals, t1 * 8);
                                    if pf2 != 0 { w64(pf2, t3 * 8, r64(g_ir_vals, t2 * 8)); }
                                    else { w64(g_ir_vals, t1 * 8, r64(g_ir_vals, t2 * 8)); }
                                }
                                if op2 == 7 && d2 >= 0 {  // IR_ALLOC_STRUCT
                                    si2 := find_struct(t3);
                                    fc2 : ., mut = 0;
                                    if si2 >= 0 { fc2 = si_field_count(si2); }
                                    need3 := fc2 * 8 + 8;
                                    bp2 := alloc(need3);
                                    vi3 : ., mut = 0;
                                    loop { if vi3 >= need3 { break; } store8(bp2, vi3, 0); vi3 = vi3 + 1; }
                                    w64(g_ir_vals, d2 * 8, bp2);
                                }
                                if op2 == 32 && d2 >= 0 { w64(g_ir_vals, d2 * 8, 0); }  // IR_ARENA_NEW
                                if op2 == 33 { }  // IR_ARENA_RESET
                                if op2 == 46 || op2 == 47 {
                                    if d2 >= 0 && t1 >= 0 { w64(g_ir_vals, d2 * 8, r64(g_ir_vals, t1 * 8)); }
                                }
                                if op2 == 5 {
                                    if t1 >= 0 { w64(g_ir_vals, ret_slot * 8, r64(g_ir_vals, t1 * 8)); }
                                    ip2 = f_count;  // return exits the callee immediately
                                }  // IR_RETURN
                                if op2 == 19 && t1 >= 0 {
                                    cv2 := r64(g_ir_vals, t1 * 8);
                                    if cv2 != 0 { if t2 >= 0 && t2 < g_label_count { ip2 = r64(g_label_poses, t2 * 8); } }
                                    else { if t3 >= 0 && t3 < g_label_count { ip2 = r64(g_label_poses, t3 * 8); } } }
                                if op2 == 20 { if t1 >= 0 && t1 < g_label_count { ip2 = r64(g_label_poses, t1 * 8); } }
                                ip2 = ip2 + 1;
                            }
                            rval := r64(g_ir_vals, ret_slot * 8);
                            // Restore label state
                            g_label_count = old_lc;
                            g_label_poses = old_poses;
                            g_label_cap = old_poses_cap;
                            w64(g_ir_vals, d * 8, rval);
                        }
                        break;
                    }
                cfi = cfi + 1; }
            }
        }

        ip = ip + 1;
    }
    return 0;
}
