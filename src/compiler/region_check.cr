// === region_check.cr ===
// RegionCheck pass — verifies DEREF targets are in live subgraphs.
// Runs after PointerAnalysis (ptr_analysis.cr) which builds g_pts table.

fn subgraph_containing(node_seq: int) -> int {
    // 显式映射：O(1) 归属查询（g_df_node_region 由 df_create_node 写入）
    if node_seq >= 0 && node_seq < g_df_node_count {
        return r64(g_df_node_region, node_seq * 8);
    }
    return -1;
}

fn is_in_unsafe(node_seq: int) -> int {
    si : ., mut = 0;
    loop { if si >= g_sg_count { break; }
        kind := r64(g_sgs, si * ESZ_SG + OFF_SG_KIND);
        if kind == SG_UNSAFE {
            nstart := r64(g_sgs, si * ESZ_SG + OFF_SG_NSTART);
            ncount := r64(g_sgs, si * ESZ_SG + OFF_SG_NCOUNT);
            if node_seq >= nstart && node_seq < nstart + ncount {
                return 1;
            }
        }
        si = si + 1;
    }
    return 0;
}

// ─── 逃逸判定的单源（#2026-09-20-1）───────────────────────────────────────
// 「某分配在节点 ni 已死」⟺ 它在某个**出口真的归还内存**的区域里分配，且 ni 落在该
// 区域关闭之后。悬垂 DEREF / 返回逃逸 / 存储逃逸三条检查共用本判定。
//
// 修前三条各自抄了一份判定（同一缺陷三份副本），且有两处判错：
//
// ① 区间是**半开** [OFF_SG_NSTART, OFF_SG_EXIT)：EXIT 由 sg_pop 写成当时
//    g_df_node_count = **区域关闭后第一个节点**的下标（dataflow.cr:78-82）
//    ⇒「已关闭」判据 = ni >= EXIT。adr-0007 记的判定式正是 cur_seq < exit_seq
//    （引用者使用区间 ⊆ 被引用区域存活区间）⇒ 取非即 >=。修前写 ni > EXIT，漏掉
//    「使用点紧跟区域」这一格 —— 而那恰是最典型的逃逸形状（循环后第一句就解引用/
//    返回/存储；实测该形状 rc=0 静默通过，中间插一句才报）。
//
// ② 只有**出口发射 IR_ARENA_RESET** 的区域才真的归还内存：SG_LOOP / SG_FOR /
//    SG_UNSAFE（ir_gen.cr 的 sg_alloc_push/sg_alloc_pop 与 loop/while/for 的显式
//    arena_new+reset 对；后端 src/arch/x86_64/instr.cr 真调 arena_new/arena_reset）。
//    SG_IF 只 sg_push/sg_pop（ir_gen.cr:2414/2437）、SG_FUNC 的 arena 在函数出口
//    才重置（返回给调用者仍有效）⇒ 两者都不是归还点。修前把「任何区域关闭」当归还
//    ⇒ `if x { arr := [..]; p = &arr[0]; } *p` 被误报 rc=1，而运行期重读仍是原值
//    = 内存根本没释放（实测反证）。分配点在 if 内时按**父链上溯**归到真正归还它的
//    那个区域（下面的 rc_releasing_region）。
//
// ③ 类型门（S6 裁定二，2026-09-20，**同批并入本单源**）：地址型 = `TYP_PTR` ∪
//    `TYP_REF`。裁定二把 `&x` 改判 `TYP_REF` ⇒ 只认 PTR 会让三道门对 `&x` 派生的值
//    静默失效（S6 实测红：`return &x;` 不再报 B010）。本处**只判 kind、不读 `extra`**
//    ⇒ 加 `TYP_REF` 是**等价扩**（不触碰「REF 的 extra = mut 标记」那个坑——那是
//    provenance_verify 独有的问题）。S6 原在三处门各写一份；本批抽单源后**收敛为
//    rc_var_dead 一处**（三条检查同时保持放宽，不得退回 PTR-only）。
//    ⚠ **覆盖面事实（2026-09-20 实测，勿据此加「PTR 形状」的假钉）**：本基上 `&局部` 一律
//    是 `TYP_REF`，且 `&局部 as *T`（REF→PTR cast）**本身即 TF01** ⇒ 由 `&局部` **构造不出**
//    `TYP_PTR` 的区域局部形状。即：**本判定的 PTR 半边在当前基上对这一面是惰性的**，
//    实际活的是 REF 半边；并集保留（PTR 侧对 alloc()/FFI 派生值仍有效）。
fn rc_sg_releases(sg: int) -> int {
    if sg < 0 { return 0; }
    k := r64(g_sgs, sg * ESZ_SG + OFF_SG_KIND);
    if k == SG_LOOP || k == SG_FOR || k == SG_UNSAFE { return 1; }
    return 0;
}

// 分配点 → 最近一个「出口归还内存」的区域（含自身；沿 OFF_SG_PARENT 上溯）。
// -1 = 无此祖先（函数级/无区域）⇒ 该分配在函数内不会死 ⇒ 不构成逃逸。
fn rc_releasing_region(alloc_node: int) -> int {
    sg := subgraph_containing(alloc_node);
    loop {
        if sg < 0 { return -1; }
        if rc_sg_releases(sg) != 0 { return sg; }
        sg = r64(g_sgs, sg * ESZ_SG + OFF_SG_PARENT);
    }
}

// 第 bi 位（= 全局 alloc 序号，经 g_pa_alloc_nodes 映射到 DF 节点）的释放点。
// 返回 EXIT 序数；-1 = 该分配不被任何区域归还（或区域未关闭 = 仍存活）。
fn rc_bit_exit(bi: int) -> int {
    alloc_node := r64(g_pa_alloc_nodes, bi * 8);
    sg := rc_releasing_region(alloc_node);
    if sg < 0 { return -1; }
    return r64(g_sgs, sg * ESZ_SG + OFF_SG_EXIT);
}

fn rc_bit_dead(bi: int, ni: int) -> int {
    ex := rc_bit_exit(bi);
    if ex < 0 { return 0; }
    if ni < ex { return 0; }
    return 1;
}

// pts 中是否已有分配在节点 ni 死亡（纯判定，不含重赋值清除规则）
fn rc_pts_dead(pts: int, ni: int) -> int {
    mask : int, mut = 1;
    bi : ., mut = 0;
    loop { if bi >= 64 { break; }
        if (pts / mask) % 2 == 1 {
            if rc_bit_dead(bi, ni) != 0 { return 1; }
        }
        mask = mask * 2;
        bi = bi + 1;
    }
    return 0;
}

// 重赋值清除：pts 是**流不敏感并集**，[lo, hi) 内一旦对该变量重赋值，并集就不再描述
// 它此刻持有什么 —— 拿失效的并集当事实用会误报（实测：循环里取 &arr[0]、循环后
// `p = &seed` 再 `*p` 被报 rc=1，而运行期合法）。
// 判据：该区间内对 ptr_var 的写，只要每处写入的值都「明确不逃逸」（pts 空 = 无受跟踪
// 堆分配，或 pts 中的分配都还活着），且至少有一处这样的写 ⇒ 清除。任一写「可能逃逸」
// 或值未知（s2 < 0）⇒ 不清除，保守照报。
// 已知不完整（登记）：值为**跨调用结果**时 pts 为空（ptr_analysis.cr 的 CALL 分支
// 不做摘要传播，头注声称的 summary propagation 未实现）⇒ 会被当作「明确不逃逸」而
// 清除；该类真阳性转漏检，根因 = pts 流不敏感，非本批引入。
fn rc_reassign_clears(ptr_var: int, lo: int, hi: int) -> int {
    saw_safe : int, mut = 0;
    i : ., mut = lo;
    loop { if i >= hi { break; }
        op := r64(g_df_nodes, i * ESZ_DFNODE + OFF_DF_OPCODE);
        d  := r64(g_df_nodes, i * ESZ_DFNODE + OFF_DF_DEST);
        s1 := r64(g_df_nodes, i * ESZ_DFNODE + OFF_DF_S1);
        s2 := r64(g_df_nodes, i * ESZ_DFNODE + OFF_DF_S2);
        if op == IR_STORE && s1 == ptr_var {
            if s2 < 0 { return 0; }
            if rc_pts_dead(r64(g_pts, s2 * 8), i) != 0 { return 0; }
            saw_safe = 1;
        }
        if op == IR_PHI && d == ptr_var {
            if s1 < 0 || s2 < 0 { return 0; }
            if rc_pts_dead(r64(g_pts, s1 * 8), i) != 0 { return 0; }
            if rc_pts_dead(r64(g_pts, s2 * 8), i) != 0 { return 0; }
            saw_safe = 1;
        }
        i = i + 1;
    }
    return saw_safe;
}

// 变量级判定：ptr_var 在节点 ni 是否持有已死指针。
// 类型门（S6）：地址型 = TYP_PTR ∪ TYP_REF（只判 kind、不读 extra）。解引用读出的
// int 是普通数据、不是又一个指针 ⇒ 非地址型直接放行。
fn rc_var_dead(ptr_var: int, ni: int) -> int {
    if ptr_var < 0 { return 0; }
    ti := irv_type(ptr_var);
    if ti < 0 || (get_type_kind(ti) != TYP_PTR && get_type_kind(ti) != TYP_REF) { return 0; }
    pts := r64(g_pts, ptr_var * 8);
    if pts == 0 { return 0; }
    mask : int, mut = 1;
    bi : ., mut = 0;
    loop { if bi >= 64 { break; }
        if (pts / mask) % 2 == 1 {
            ex := rc_bit_exit(bi);
            if ex >= 0 && ni >= ex {
                if rc_reassign_clears(ptr_var, ex, ni) == 0 { return 1; }
            }
        }
        mask = mask * 2;
        bi = bi + 1;
    }
    return 0;
}

// 返回逃逸：返回的指针指向已退出的子图分配。
// 错误码 = B010 EC_B_ESCAPE（errors.md:245「Reference to local escapes the
// function」，例子即 `return &x`）；修前误用 B011（码位错配）。
// 函数级（SG_FUNC）分配由 rc_releasing_region 自然放行 —— 无需特例。
fn rc_return_escape(ni: int, s1: int) {
    if rc_var_dead(s1, ni) != 0 {
        check_error(EC_B_ESCAPE,
            "region escape: returning pointer to exited subgraph allocation",
            0, 0);
    }
}

// 存储逃逸：*ptr = val 存入的指针指向已退出的子图分配 ⇒ 写出的引用悬垂。
// 修前本函数体的判定值被整行丢弃（`rc_pts_has_escaped(val_pts, ni, 0);` 同行注
// `// simplified check`），rc_pts_has_escaped 体内又无 check_error ⇒ 该检查从不可
// 触发（引入提交 92eec5a7 起即如此）。此处接回 check_error，范式同 DEREF/返回两处。
// ptr_var（存储目标）本批未用：其双边 outlives 比较（注释所述「val 的目标分配寿命
// ≥ ptr 的」）需要目标侧区域比较，属未实现设计，另登记（勿当作已实现）。
fn rc_store_escape(ni: int, ptr_var: int, val_var: int) {
    if rc_var_dead(val_var, ni) != 0 {
        check_error(EC_B_LIFETIME,
            "store escape: storing pointer to exited subgraph allocation",
            0, 0);
    }
}

fn region_check_func(nstart: int, ncount: int) {
    ni : ., mut = nstart;
    loop { if ni >= nstart + ncount { break; }
        op := r64(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_OPCODE);
        d  := r64(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_DEST);
        s1 := r64(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S1);
        s2 := r64(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S2);

        if is_in_unsafe(ni) != 0 { ni = ni + 1; continue; }

        if op == IR_DEREF && d >= 0 && s1 >= 0 {
            if rc_var_dead(s1, ni) != 0 {
                check_error(EC_B_LIFETIME,
                    "dangling pointer: allocation subgraph exited before deref",
                    0, 0);
            }
        }

        // Siebert: interprocedural escape via return
        if op == IR_RETURN && s1 >= 0 {
            rc_return_escape(ni, s1);
        }

        // Siebert: interprocedural escape via store
        if op == IR_STORE_PTR {
            rc_store_escape(ni, s1, s2);
        }

        ni = ni + 1;
    }
}

fn region_check_all() {
    // Safety pass — always runs
    fi : ., mut = 0;
    loop { if fi >= g_ir_func_count { break; }
        nstart := r64(g_df_func_node_start, fi * 8);
        ncount := r64(g_df_func_node_count, fi * 8);
        region_check_func(nstart, ncount);
        fi = fi + 1;
    }
}
