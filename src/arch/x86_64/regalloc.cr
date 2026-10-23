// === regalloc.cr ===
// x86-64 register allocation.
//
// Allocation data are live ranges and version entries. CAG allocates
// callee-saved registers, writes OPT_KEY_REG_ASSIGN pairs to g_opt_meta, and
// registers the same locations in the verification registry.
//
// The inject_* and try_inject_* functions are test hooks for the cir debug
// branch. Production builds never call them.

// Test hook for cir --inject-coexist-oob. It checks the upper bound of
// entries_coexist. e1 and e2 are out-of-range entry indices. Without the guard,
// the accessor reads past the entry array; zero-initialized slots [0, 0]
// intersect every range and return 1, and reading past the buffer crashes.
// Output is "coexist-oob-guard: <0|1>"; a nonzero result returns 1.
fn inject_coexist_oob() -> int:
    e1 := g_entry_count
    e2 := g_entry_count + 1
    r := entries_coexist(0, e1, e2)
    print("coexist-oob-guard: ")
    println(int_str(r))
    if r != 0:
        return 1
    return 0

// ===== Test hooks for cir --check-regalloc =====
// These functions only run in the cir debug branch and do not change production
// allocation. Each injection searches all functions for a target instead of
// assuming function 0 is the tested main.
//
// Home-group conflict: pick two coexisting entries for different vars, remove
// both vars from register residency, then set both home slots to 7. The
// verifier reports a home-group violation (rule 1). Vars without a home entry
// have home = -1 and do not participate in the sweep, so there are no side
// effects.
fn try_inject_home_conflict(func_i: int) -> int:
    es := entry_start(func_i)
    ec := entry_count(func_i)
    if ec < 2:
        return 0
    e1i : ., mut = 0
    loop:
        if e1i >= ec:
            break
        e1 := es + e1i
        v1 := ent_var(e1)
        if v1 < 0:
            e1i = e1i + 1
            continue
        e2i : ., mut = e1i + 1
        loop:
            if e2i >= ec:
                break
            e2 := es + e2i
            v2 := ent_var(e2)
            if v1 != v2 && entries_coexist(func_i, e1, e2) != 0:
                meta_remove_var(v1)
                meta_remove_var(v2)
                w32(g_ir_entries, e1 * ESZ_ENTRY + OFF_ENTRY_HOME, 7)
                w32(g_ir_entries, e2 * ESZ_ENTRY + OFF_ENTRY_HOME, 7)
                return 1
            e2i = e2i + 1
        e1i = e1i + 1
    return 0

fn inject_home_conflict() -> int:
    fi : ., mut = 0
    loop:
        if fi >= g_ir_func_count:
            break
        if try_inject_home_conflict(fi) != 0:
            return 1
        fi = fi + 1
    return 0

// 元数据写侧辅助。CAG 真实分配后，注入通过改写真实输出来制造目标状态。
// append 的语义是首匹配生效，因此注入必须原位改写或移除。

// 返回 var 的 reg 字段偏移（g_opt_meta 内；-1 表示没有 pair）。布局与
// instr.cr get_reg_for_var 相同，二者在同一进程内消费。
fn meta_reg_pair_off(var_idx: int) -> int:
    mi : ., mut = 0
    loop:
        if mi >= g_opt_meta_count:
            break
        mo := mi * OPT_META_STRIDE
        if r32(g_opt_meta, mo) == OPT_KEY_REG_ASSIGN:
            cnt := r32(g_opt_meta, mo + 8)
            di : ., mut = 0
            loop:
                if di >= cnt:
                    break
                if r32(g_opt_meta, mo + 12 + di * 8) == var_idx:
                    return mo + 16 + di * 8
                di = di + 1
        mi = mi + 1
    return -1

// Registry pairing.
// The verifier reads the location registry through kern_loc_assign,
// kern_loc_clear, and kern_loc_of (ent_kernel.cr). Every write to g_opt_meta
// must update the registry for the same var. The projection is equivalent to
// the verifier's meta_reg_for_var: any registered entry means the var is
// resident. Pairing points are meta_set_reg, meta_remove_var, and phase 5 of
// alloc_registers. Injection hooks change the meta only through the first two
// functions.
// Entry-to-function ownership is unknown because var_idx is a global var id, so
// these helpers scan the whole table. Injections run only in the cir debug
// channel on small tables; production allocation uses the phase 5 range scan.
fn reg_assign_var_entries(var_idx: int, loc: int):
    e : ., mut = 0
    loop:
        if e >= g_entry_count:
            break
        if ent_var(e) == var_idx:
            kern_loc_assign(e, loc)
        e = e + 1

fn reg_clear_var_entries(var_idx: int):
    e : ., mut = 0
    loop:
        if e >= g_entry_count:
            break
        if ent_var(e) == var_idx:
            kern_loc_clear(e)
        e = e + 1

// Force var -> reg. If a pair exists, rewrite it in place; otherwise append a
// pair. Append takes effect only when no earlier pair matches.
fn meta_set_reg(var_idx: int, reg: int):
    po := meta_reg_pair_off(var_idx)
    if po >= 0:
        w32(g_opt_meta, po, reg)
    else:
        meta_append_reg_assign(var_idx, reg)
    reg_assign_var_entries(var_idx, reg)   // 登记表配对（判定逻辑同步）

// Remove the allocation pair for var. Pairs in the block shift left, and an empty
// block is removed. The var becomes stack resident: its entries have home = -1,
// so it does not participate in the rule 1 sweep.
fn meta_remove_var(var_idx: int):
    mi : ., mut = 0
    loop:
        if mi >= g_opt_meta_count:
            break
        mo := mi * OPT_META_STRIDE
        if r32(g_opt_meta, mo) == OPT_KEY_REG_ASSIGN:
            cnt := r32(g_opt_meta, mo + 8)
            di : ., mut = 0
            loop:
                if di >= cnt:
                    break
                if r32(g_opt_meta, mo + 12 + di * 8) == var_idx:
                    // 移除第 di 对：后续对左移 8B（数据区 = count@+8 + 对@+12）
                    sh : ., mut = di
                    loop:
                        if sh + 1 >= cnt:
                            break
                        w32(g_opt_meta, mo + 12 + sh * 8, r32(g_opt_meta, mo + 12 + (sh + 1) * 8))
                        w32(g_opt_meta, mo + 16 + sh * 8, r32(g_opt_meta, mo + 16 + (sh + 1) * 8))
                        sh = sh + 1
                    cnt = cnt - 1
                    w32(g_opt_meta, mo + 8, cnt)
                    w32(g_opt_meta, mo + 4, 4 + cnt * 8)
                    if cnt == 0:
                        // 空块整体移除：后续块左移一个 OPT_META_STRIDE
                        mj : ., mut = mi
                        loop:
                            if mj + 1 >= g_opt_meta_count:
                                break
                            so := (mj + 1) * OPT_META_STRIDE
                            kk : ., mut = 0
                            loop:
                                if kk >= OPT_META_STRIDE / 8:
                                    break
                                cell_store(g_opt_meta, mj * OPT_META_STRIDE + kk * 8, cell_load(g_opt_meta, so + kk * 8))
                                kk = kk + 1
                            mj = mj + 1
                        g_opt_meta_count = g_opt_meta_count - 1
                    reg_clear_var_entries(var_idx)   // 登记表配对（判定逻辑同步）
                    return
                di = di + 1
        mi = mi + 1

// REG_ASSIGN 对总数（--check-regalloc 看检查狗行；rc>0 = 寄存器真实分配实证）
fn meta_reg_assign_total() -> int:
    tot : ., mut = 0
    mi : ., mut = 0
    loop:
        if mi >= g_opt_meta_count:
            break
        mo := mi * OPT_META_STRIDE
        if r32(g_opt_meta, mo) == OPT_KEY_REG_ASSIGN:
            tot = tot + r32(g_opt_meta, mo + 8)
        mi = mi + 1
    return tot

// Append one OPT_KEY_REG_ASSIGN record using the same layout as
// alloc_registers. The first matching pair wins, so an injected target must be a
// var that real allocation did not cover. The backend get_reg_for_var uses the
// same rule.
fn meta_append_reg_assign(var_idx: int, reg: int):
    grow_opt_meta(g_opt_meta_count + 1)
    eo := g_opt_meta_count * OPT_META_STRIDE
    store8(g_opt_meta, eo, 0)
    store8(g_opt_meta, eo + 1, 0)
    store8(g_opt_meta, eo + 2, 0)
    store8(g_opt_meta, eo + 3, 0)  // OPT_KEY_REG_ASSIGN=0
    dl : ., mut = 4 + 8
    store8(g_opt_meta, eo + 4, dl % 256)
    store8(g_opt_meta, eo + 5, (dl / 256) % 256)
    store8(g_opt_meta, eo + 6, (dl / 65536) % 256)
    store8(g_opt_meta, eo + 7, (dl / 16777216) % 256)
    store8(g_opt_meta, eo + 8, 1)
    store8(g_opt_meta, eo + 9, 0)
    store8(g_opt_meta, eo + 10, 0)
    store8(g_opt_meta, eo + 11, 0)  // count = 1
    store8(g_opt_meta, eo + 12, var_idx % 256)
    store8(g_opt_meta, eo + 13, (var_idx / 256) % 256)
    store8(g_opt_meta, eo + 14, (var_idx / 65536) % 256)
    store8(g_opt_meta, eo + 15, (var_idx / 16777216) % 256)
    store8(g_opt_meta, eo + 16, reg % 256)
    store8(g_opt_meta, eo + 17, (reg / 256) % 256)
    store8(g_opt_meta, eo + 18, (reg / 65536) % 256)
    store8(g_opt_meta, eo + 19, (reg / 16777216) % 256)
    g_opt_meta_count = g_opt_meta_count + 1

// Register-group conflict: find two coexisting entries for different vars and
// rewrite both vars to register 3. A pair is rewritten in place when present,
// otherwise appended, so the change takes effect whether or not real allocation
// covered the var. Coexisting entries in the same group then violate rule 1.
// This injection only runs in the cir debug branch.
fn try_inject_reg_conflict(func_i: int) -> int:
    es := entry_start(func_i)
    ec := entry_count(func_i)
    if ec < 2:
        return 0
    e1i : ., mut = 0
    loop:
        if e1i >= ec:
            break
        e1 := es + e1i
        v1 := ent_var(e1)
        if v1 < 0:
            e1i = e1i + 1
            continue
        e2i : ., mut = e1i + 1
        loop:
            if e2i >= ec:
                break
            e2 := es + e2i
            v2 := ent_var(e2)
            if v1 != v2 && entries_coexist(func_i, e1, e2) != 0:
                meta_set_reg(v1, 3)
                meta_set_reg(v2, 3)
                return 1
            e2i = e2i + 1
        e1i = e1i + 1
    return 0

fn inject_reg_conflict() -> int:
    fi : ., mut = 0
    loop:
        if fi >= g_ir_func_count:
            break
        if try_inject_reg_conflict(fi) != 0:
            return 1
        fi = fi + 1
    return 0

// Read gap: find a var whose last version entry has def >= 0 and
// live_end > def, meaning there are reads after the definition. Make the var
// register resident and truncate that entry's live_end to def. Later reads have
// no live version, which violates rule 2.
// If the var is already allocated, keep its register and truncate directly.
// Otherwise force register 3 and first remove coexisting allocated vars to avoid
// a rule 1 side effect. Removed vars have no location and do not enter the sweep.
fn try_inject_read_gap(func_i: int) -> int:
    vc := cell_load(g_ir_func_var_count, func_i * 8)
    vs := cell_load(g_ir_func_var_start, func_i * 8)
    es := entry_start(func_i)
    ec := entry_count(func_i)
    lv : ., mut = 0
    loop:
        if lv >= vc:
            break
        gv := vs + lv
        // 该 var 最后一条 def >= 0 条目。表内定值点升序，末条即 def 最大。
        last : ., mut = -1
        ei : ., mut = 0
        loop:
            if ei >= ec:
                break
            e := es + ei
            if ent_var(e) == gv && ent_def(e) >= 0:
                last = e
            ei = ei + 1
        if last >= 0 && ent_live_end(last) > ent_def(last):
            // Probe through meta_reg_for_var, the same registry view the verifier
            // reads. The registry is kept in sync with g_opt_meta by phase 5 and
            // by meta_set_reg/meta_remove_var, so no private scan is needed.
            if meta_reg_for_var(gv) < 0:
                // 强制驻留路径：撤销与 gv 任何版本条目共存的已分配 var
                ej : ., mut = 0
                loop:
                    if ej >= ec:
                        break
                    e2 := es + ej
                    v2 := ent_var(e2)
                    if v2 != gv && meta_reg_for_var(v2) >= 0:
                        ek : ., mut = 0
                        loop:
                            if ek >= ec:
                                break
                            if ent_var(es + ek) == gv && entries_coexist(func_i, es + ek, e2) != 0:
                                meta_remove_var(v2)
                                break
                            ek = ek + 1
                    ej = ej + 1
                meta_set_reg(gv, 3)
            w32(g_ir_entries, last * ESZ_ENTRY + OFF_ENTRY_LE, ent_def(last))
            return 1
        lv = lv + 1
    return 0

fn inject_read_gap() -> int:
    // Iterate functions 1..n-1 before function 0, so the injection prefers a
    // non-main target. The rule 2 coordinate-blind case only appears in functions
    // with ist > 0. Every function now has a first def, so starting at 0 would
    // always inject into main and leave the non-function-0 case untested.
    fi : ., mut = 1
    loop:
        if fi >= g_ir_func_count:
            break
        if try_inject_read_gap(fi) != 0:
            return 1
        fi = fi + 1
    return try_inject_read_gap(0)

// ------------------------------------------------------------------
// Register allocation: CAG (context-aware greedy)
// ------------------------------------------------------------------
// Registers form the cache layer and frame slots are home. Allocation is first
// fit over existence intervals with context fixes:
//   - coexisting vars cannot share a register;
//   - loop-carried values get a whole-function window;
//   - only callee-saved registers are used;
//   - type and emitter hazards exclude some vars.
// Results are OPT_KEY_REG_ASSIGN pairs in g_opt_meta. instr.cr get_reg_for_var
// reads the pairs at emission and maps the var to a physical register with the
// E2_REG_SLOT_BASE sentinel. Allocation runs in the corearch process, so there
// is no cross-process .ccr image.
//
// Allocation granularity is the var, not the version. compute_entries produces
// version entries, but the emit seam has one location per var and the backend
// queries by var without instruction context. A var window is the union of its
// version intervals, [first_ref, last_ref]. The verifier projects a var to its
// version entries. Raising allocation to version level would need per-instruction
// operand rewriting and context-aware slot resolution; the verifier is already
// entry-based and would not change.
//
// Gating: every read and write of a register-resident var must use BASE-aware
// loads and stores (e2_ld, e2_st, e2_load_var). Direct memory operands, slot
// addresses, and dual-slot offsets encode garbage on a register sentinel slot.
// Excluded vars:
//   - TI_DEX and TI_DEX_S use XMM memory paths e2_sd_* and e2_sd_cvt;
//   - TI_DYN uses a 16-byte value+tag pair and e2_ld(o +/- 8) would misalign;
//   - TI_UNIT is never allocated;
//   - IR_CONST dest uses e2_li without a register slot;
//   - IR_REF s1 uses e2_lb to take the home slot address and must stay in home;
//   - IR_I2F s1 is a memory source for e2_sd_cvt;
//   - vars referenced by TI_DEX or TI_DEX_S instructions are defensive exclusions.
// An excluded var stays in its frame slot for the whole window. If more than 5
// vars coexist, allocation fails statically and leaves the var unallocated.
// There is no dynamic eviction and no spill instruction. Since no var is placed
// without a home slot, the capability requirement "must have home" holds
// trivially; eviction rule 3 has no events, and the callee-saved call contract
// makes rule 4 trivially true.
//
// Loop-carried values: a plain lexical window [first_ref, last_ref] is unsafe in
// functions with backedges. A value read before its redefinition in the loop body
// (for example cond reads i before i = i + 1) stays live across the backedge. A
// window ending at the last lexical reference could give the register to a var
// whose lexical range does not overlap at the loop tail, causing def pollution.
// For each backedge span [label_pos, branch_pos], if the first reference to a var
// in the span is a read, the var is carried and its window expands to the whole
// function.
//
// Conditional definitions: a def-form first reference does not guarantee a
// refresh on every iteration. If the definition point d can be skipped by a
// branch inside the span while the loop continues, the old value survives the
// backedge. Such definitions are treated as carried. A self-read in the same
// instruction (s1 or s2 equals the destination, read before write) is also
// carried.
//
// Residual approximation: reads outside the first-reference position and complex
// paths across spans need real CFG liveness. The RegionCheck layer in
// docs/regalloc-cache-mapping.md is not wired yet; allocation and verification
// share the lexical interval model.

fn label_pos_of(id: int, lab_id: string, lab_ps: string, n: int) -> int:
    i : ., mut = 0
    loop:
        if i >= n:
            break
        if cell_load(lab_id, i * 8) == id:
            return cell_load(lab_ps, i * 8)
        i = i + 1
    return -1

fn alloc_registers():
    if g_opt_level < 1:
        return
    // 先计算存在区间表，尾部重建版本条目表，判定消费同源数据。
    compute_live_ranges()
    MAX_REGS : int = 5
    // callee-saved 物理寄存器（rbx, r12-r15；x86 枚举号，e2_mov/e2_ld REX 编码）
    reg_phys : string, mut = alloc(5 * 8)
    cell_store(reg_phys, 0, 3)
    cell_store(reg_phys, 8, 12)
    cell_store(reg_phys, 16, 13)
    cell_store(reg_phys, 24, 14)
    cell_store(reg_phys, 32, 15)
    fi : ., mut = 0
    loop:
        if fi >= g_ir_func_count:
            break
        ic := cell_load(g_ir_func_instr_count, fi * 8)
        ist := cell_load(g_ir_func_instr_start, fi * 8)
        vc := cell_load(g_ir_func_var_count, fi * 8)
        vs := cell_load(g_ir_func_var_start, fi * 8)
        pc := cell_load(g_ir_func_param_count, fi * 8)
        if vc <= 0 || ic <= 0:
            fi = fi + 1
            continue

        // ── 阶段 1：检查控扫描（并行 hazard 标志）──
        haz_const : string, mut = alloc(vc * 8)   // IR_CONST dest（e2_li 写路径）
        haz_ref   : string, mut = alloc(vc * 8)   // IR_REF s1（槽地址泄漏）
        haz_i2f   : string, mut = alloc(vc * 8)   // IR_I2F s1（sd_cvt 内存源）
        haz_dyn   : string, mut = alloc(vc * 8)   // IR_DYN_*（16B 双槽布局）
        haz_dex   : string, mut = alloc(vc * 8)   // ti==TI_DEX/S 指令引用
        iz : ., mut = 0
        loop:
            if iz >= vc:
                break
            cell_store(haz_const, iz * 8, 0)
            cell_store(haz_ref, iz * 8, 0)
            cell_store(haz_i2f, iz * 8, 0)
            cell_store(haz_dyn, iz * 8, 0)
            cell_store(haz_dex, iz * 8, 0)
            iz = iz + 1
        ii : ., mut = 0
        loop:
            if ii >= ic:
                break
            inst := ist + ii
            op := iri_op(inst)
            d := iri_dest(inst)
            s1 := iri_s1(inst)
            s2 := iri_s2(inst)
            if d >= vs && d < vs + vc:
                dl := d - vs
                if op == IR_CONST:
                    cell_store(haz_const, dl * 8, 1)
                if op == IR_DYN_PACK || op == IR_DYN_TAG || op == IR_DYN_VAL || op == IR_DYN_DISPATCH:
                    cell_store(haz_dyn, dl * 8, 1)
            if op == IR_REF && s1 >= vs && s1 < vs + vc:
                cell_store(haz_ref, (s1 - vs) * 8, 1)
            if op == IR_I2F && s1 >= vs && s1 < vs + vc:
                cell_store(haz_i2f, (s1 - vs) * 8, 1)
            if op == IR_DYN_PACK || op == IR_DYN_TAG || op == IR_DYN_VAL || op == IR_DYN_DISPATCH:
                if s1 >= vs && s1 < vs + vc:
                    cell_store(haz_dyn, (s1 - vs) * 8, 1)
                if s2 >= vs && s2 < vs + vc:
                    cell_store(haz_dyn, (s2 - vs) * 8, 1)
            tk := iri_tk(inst)
            if tk == TI_DEX || tk == TI_DEX_S:
                if d >= vs && d < vs + vc:
                    cell_store(haz_dex, (d - vs) * 8, 1)
                if s1 >= vs && s1 < vs + vc:
                    cell_store(haz_dex, (s1 - vs) * 8, 1)
                if s2 >= vs && s2 < vs + vc:
                    cell_store(haz_dex, (s2 - vs) * 8, 1)
            ii = ii + 1

        // ── 阶段 2：回边探测 + 携带值标记（region 生命周期上下文）──
        ln : ., mut = 0
        ii = 0
        loop:
            if ii >= ic:
                break
            if iri_op(ist + ii) == IR_LABEL:
                if iri_s1(ist + ii) >= 0:
                    ln = ln + 1
            ii = ii + 1
        lab_id : string, mut = alloc(ln * 8)
        lab_ps : string, mut = alloc(ln * 8)
        li : ., mut = 0
        ii = 0
        loop:
            if ii >= ic:
                break
            if iri_op(ist + ii) == IR_LABEL && iri_s1(ist + ii) >= 0:
                cell_store(lab_id, li * 8, iri_s1(ist + ii))
                cell_store(lab_ps, li * 8, ii)
                li = li + 1
            ii = ii + 1
        // 回边 span 收集（16B {label_pos, branch_pos}；上限 = 指令数）
        bt : string, mut = alloc(ic * 16)
        bn : ., mut = 0
        has_loop : ., mut = 0
        ii = 0
        loop:
            if ii >= ic:
                break
            inst := ist + ii
            op := iri_op(inst)
            if op == IR_JUMP:
                tp := label_pos_of(iri_s1(inst), lab_id, lab_ps, ln)
                if tp >= 0 && tp < ii:
                    cell_store(bt, bn * 16, tp)
                    cell_store(bt, bn * 16 + 8, ii)
                    bn = bn + 1
                    has_loop = 1
            else if op == IR_BRANCH:
                tp := label_pos_of(iri_s2(inst), lab_id, lab_ps, ln)
                if tp >= 0 && tp < ii:
                    cell_store(bt, bn * 16, tp)
                    cell_store(bt, bn * 16 + 8, ii)
                    bn = bn + 1
                    has_loop = 1
                tp = label_pos_of(iri_s3(inst), lab_id, lab_ps, ln)
                if tp >= 0 && tp < ii:
                    cell_store(bt, bn * 16, tp)
                    cell_store(bt, bn * 16 + 8, ii)
                    bn = bn + 1
                    has_loop = 1
            ii = ii + 1
        car : string, mut = alloc(vc * 8)
        iz = 0
        loop:
            if iz >= vc:
                break
            cell_store(car, iz * 8, 0)
            iz = iz + 1
        if has_loop != 0:
            // 扫描 span 内的指令。var 的首个引用是读时，值跨回边存活，标记为携带。
            // 首引用是定值（dest 或 STORE s1）且每轮都执行时，不携带。
            // 状态：0 未见，1 首引用是定值，2 首引用是读。
            // 若定值点可被 span 内条件分支跳过，则未必每轮刷新，按携带处理；差分标记
            // 和前缀累计见下。
            st : string, mut = alloc(vc * 8)
            st_def : string, mut = alloc(vc * 8)      // state-1 var 的定值位置
            skp : string, mut = alloc((ic + 2) * 8)   // 可跳过位置差分（span 局部序）
            bi : ., mut = 0
            loop:
                if bi >= bn:
                    break
                t0 := cell_load(bt, bi * 16)
                b0 := cell_load(bt, bi * 16 + 8)
                iz = 0
                loop:
                    if iz >= vc:
                        break
                    cell_store(st, iz * 8, 0)
                    cell_store(st_def, iz * 8, -1)
                    iz = iz + 1
                pp : ., mut = t0
                loop:
                    if pp > b0:
                        break
                    inst := ist + pp
                    op := iri_op(inst)
                    d := iri_dest(inst)
                    s1 := iri_s1(inst)
                    s2 := iri_s2(inst)
                    if d >= vs && d < vs + vc:
                        lvd := d - vs
                        if cell_load(st, lvd * 8) == 0:
                            // dest 定值同指令自读（s1/s2 == d）：读先于写，该读
                            // 可能取上一轮值，按读首引用（携带）处理
                            if s1 == d || s2 == d:
                                cell_store(st, lvd * 8, 2)
                                cell_store(car, lvd * 8, 1)
                            else:
                                cell_store(st, lvd * 8, 1)
                                cell_store(st_def, lvd * 8, pp)
                    if op == IR_STORE && s1 >= vs && s1 < vs + vc:
                        lvs := s1 - vs
                        if cell_load(st, lvs * 8) == 0:
                            if s2 == s1:
                                cell_store(st, lvs * 8, 2)
                                cell_store(car, lvs * 8, 1)
                            else:
                                cell_store(st, lvs * 8, 1)
                                cell_store(st_def, lvs * 8, pp)
                    if s1 >= vs && s1 < vs + vc && op != IR_STORE:
                        lv1 := s1 - vs
                        if cell_load(st, lv1 * 8) == 0:
                            cell_store(st, lv1 * 8, 2)
                            cell_store(car, lv1 * 8, 1)
                    if s2 >= vs && s2 < vs + vc:
                        lv2 := s2 - vs
                        if cell_load(st, lv2 * 8) == 0:
                            cell_store(st, lv2 * 8, 2)
                            cell_store(car, lv2 * 8, 1)
                    pp = pp + 1
                // 条件定值差分标记：BRANCH 的前向目标 t 在 (pp, b0] 时，位置 (pp, t)
                // 可被跳过且循环仍继续。区间 [pp+1, t-1] 加 1，终点 t 减 1；前缀累计
                // 大于 0 表示该位置落在可跳过区域内。回跳和外跳目标不计，它们不构成
                // 跳过仍继续循环。
                //
                // if-else 布局中，else 体 B 会被 then 尾的无条件 JUMP 结构性跳过。
                // B 内的定值位于 BRANCH 的 else 目标标号处，区间 [pp+1, t-1] 不含终点 t。
                // 只扫 IR_BRANCH 会漏掉 IR_JUMP，把 B 内定值误判为每轮必执行，造成同
                // 寄存器值被破坏。因此对 span 内前向 IR_JUMP 也生成 [pp+1, t-1] 差分。
                // continue 的前向形态同理；回跳的 continue 和 break 外跳目标不计。
                // over-mark 只降低利用率，方向安全。
                zz : ., mut = 0
                spn := b0 - t0 + 1
                loop:
                    if zz >= spn:
                        break
                    cell_store(skp, zz * 8, 0)
                    zz = zz + 1
                pp = t0
                loop:
                    if pp > b0:
                        break
                    if iri_op(ist + pp) == IR_BRANCH:
                        t2 := label_pos_of(iri_s2(ist + pp), lab_id, lab_ps, ln)
                        t3 := label_pos_of(iri_s3(ist + pp), lab_id, lab_ps, ln)
                        if t2 > pp && t2 <= b0:
                            cell_store(skp, (pp + 1 - t0) * 8, cell_load(skp, (pp + 1 - t0) * 8) + 1)
                            cell_store(skp, (t2 - t0) * 8, cell_load(skp, (t2 - t0) * 8) - 1)
                        if t3 > pp && t3 <= b0:
                            cell_store(skp, (pp + 1 - t0) * 8, cell_load(skp, (pp + 1 - t0) * 8) + 1)
                            cell_store(skp, (t3 - t0) * 8, cell_load(skp, (t3 - t0) * 8) - 1)
                    else if iri_op(ist + pp) == IR_JUMP:
                        t1 := label_pos_of(iri_s1(ist + pp), lab_id, lab_ps, ln)
                        if t1 > pp && t1 <= b0:
                            cell_store(skp, (pp + 1 - t0) * 8, cell_load(skp, (pp + 1 - t0) * 8) + 1)
                            cell_store(skp, (t1 - t0) * 8, cell_load(skp, (t1 - t0) * 8) - 1)
                    pp = pp + 1
                // 前缀累计：skp[p−t0] > 0 ⟺ 位置 p 可被某条件分支跳过
                acc : ., mut = 0
                pp = t0
                loop:
                    if pp > b0:
                        break
                    acc = acc + cell_load(skp, (pp - t0) * 8)
                    if acc != 0:
                        cell_store(skp, (pp - t0) * 8, 1)
                    else:
                        cell_store(skp, (pp - t0) * 8, 0)
                    pp = pp + 1
                // state 1 表示首引用是定值。若定值点可被跳过，则是条件定值，每轮
                // 未必刷新，旧值跨回边存活，标记为携带，窗口扩至整函数。
                iz = 0
                loop:
                    if iz >= vc:
                        break
                    if cell_load(st, iz * 8) == 1:
                        dd := cell_load(st_def, iz * 8)
                        if dd >= t0 && cell_load(skp, (dd - t0) * 8) != 0:
                            cell_store(car, iz * 8, 1)
                    iz = iz + 1
                bi = bi + 1

        // ── 阶段 3：候选构建（窗口 = [first_ref,last_ref] + 上下文修正）──
        var_reg : string, mut = alloc(vc * 8)  // 活跃集：函数内 var 到 reg 序 (0..4)
        var_end : string, mut = alloc(vc * 8)  // 活跃集窗口终点（free 判据，
                                              // 携带值扩窗后 ≠ live_last，须存）
        var_asg : string, mut = alloc(vc * 8)  // 终分配：函数内 var 到物理 reg
        reg_occ : string, mut = alloc(MAX_REGS * 8)
        cand_st : string, mut = alloc(vc * 8)
        cand_en : string, mut = alloc(vc * 8)
        cand_lv : string, mut = alloc(vc * 8)
        lv : ., mut = 0
        loop:
            if lv >= vc:
                break
            cell_store(var_reg, lv * 8, -1)
            cell_store(var_end, lv * 8, 0)
            cell_store(var_asg, lv * 8, -1)
            lv = lv + 1
        lv = 0
        loop:
            if lv >= MAX_REGS:
                break
            cell_store(reg_occ, lv * 8, -1)
            lv = lv + 1
        cc : ., mut = 0
        lv = 0
        loop:
            if lv >= vc:
                break
            gv := vs + lv
            f := live_first(fi, gv)
            l := live_last(fi, gv)
            if f < 0 || l <= f:
                lv = lv + 1
                continue
            // 未用 / 单指令引用
            ty := irv_type(gv)
            if ty == TI_DEX || ty == TI_DEX_S || ty == TI_DYN || ty == TI_UNIT:
                lv = lv + 1
                continue
            if cell_load(haz_const, lv * 8) != 0 || cell_load(haz_ref, lv * 8) != 0 || cell_load(haz_i2f, lv * 8) != 0 || cell_load(haz_dyn, lv * 8) != 0 || cell_load(haz_dex, lv * 8) != 0:
                lv = lv + 1
                continue
            st : ., mut = f
            en : ., mut = l
            if lv < pc:
                st = 0
            // 参数入口装载，窗口自函数头
            if cell_load(car, lv * 8) != 0:
                st = 0
                en = ic - 1
            // 携带值，扩至整函数
            cell_store(cand_st, cc * 8, st)
            cell_store(cand_en, cc * 8, en)
            cell_store(cand_lv, cc * 8, lv)
            cc = cc + 1
            lv = lv + 1
        // 候选按 (start, lv) 稳定升序（插入排序；起点 = 指令位置，C ≤ vc 小集）
        ci2 : ., mut = 1
        loop:
            if ci2 >= cc:
                break
            ks := cell_load(cand_st, ci2 * 8)
            kl := cell_load(cand_lv, ci2 * 8)
            ke := cell_load(cand_en, ci2 * 8)
            jj : ., mut = ci2
            loop:
                if jj <= 0:
                    break
                pj := jj - 1
                ps := cell_load(cand_st, pj * 8)
                pl := cell_load(cand_lv, pj * 8)
                if ps < ks || (ps == ks && pl < kl):
                    break
                cell_store(cand_st, jj * 8, ps)
                cell_store(cand_en, jj * 8, cell_load(cand_en, pj * 8))
                cell_store(cand_lv, jj * 8, pl)
                jj = jj - 1
            cell_store(cand_st, jj * 8, ks)
            cell_store(cand_en, jj * 8, ke)
            cell_store(cand_lv, jj * 8, kl)
            ci2 = ci2 + 1

        // ── 阶段 4：位置扫描 First Fit（同位置先 free 后分配）──
        ci : ., mut = 0
        p : ., mut = 0
        loop:
            if p >= ic:
                break
            // 释放窗口终点已过的 var，归还寄存器。分配时把窗口终点记入 var_end；
            // 携带值扩窗后它不等于 live_last。free 发生在末引用之后，同位置先 free
            // 后分配，因此寄存器可以复用。
            lv2 : ., mut = 0
            loop:
                if lv2 >= vc:
                    break
                rr := cell_load(var_reg, lv2 * 8)
                if rr >= 0 && cell_load(var_end, lv2 * 8) < p:
                    cell_store(var_reg, lv2 * 8, -1)
                    cell_store(reg_occ, rr * 8, -1)
                lv2 = lv2 + 1
            // 分配起点等于 p 的候选。窗口终点为 p-1 的 var 已先释放，可以复用同一
            // 寄存器；终点恰为 p 的 var 仍活跃于 p，不能释放。同指令的共存条目不得
            // 使用同一寄存器。
            loop:
                if ci >= cc:
                    break
                if cell_load(cand_st, ci * 8) != p:
                    break
                lvv := cell_load(cand_lv, ci * 8)
                eend := cell_load(cand_en, ci * 8)
                ci = ci + 1
                rj : ., mut = 0
                tk : ., mut = -1
                loop:
                    if rj >= MAX_REGS:
                        break
                    if cell_load(reg_occ, rj * 8) < 0:
                        tk = rj
                        break
                    rj = rj + 1
                if tk >= 0:
                    cell_store(var_reg, lvv * 8, tk)
                    cell_store(var_end, lvv * 8, eend)
                    cell_store(reg_occ, tk * 8, lvv)
                    cell_store(var_asg, lvv * 8, cell_load(reg_phys, tk * 8))
            p = p + 1

        // ── 阶段 5：终分配写 g_opt_meta ──
        // 块格式：ast.cr OPT_META_STRIDE = 64，头部 8 字节，数据不超过 56 字节。
        // 每块最多 5 对，data_len = 4 + n*8 <= 44；ccr 加载器校验
        // md_len <= STRIDE-8。分配对数超过 5 时按 5 切块。reader 和
        // get_reg_for_var 扫描所有块，首匹配生效；同一 var 恒在同一块内有一对。
        rc : ., mut = 0
        lv = 0
        loop:
            if lv >= vc:
                break
            if cell_load(var_asg, lv * 8) >= 0:
                rc = rc + 1
            lv = lv + 1
        if rc > 0:
            // 预收集已分配 var（函数内下标），切块时按序取
            asg_lv : string, mut = alloc(rc * 8)
            ai : ., mut = 0
            lv = 0
            loop:
                if lv >= vc:
                    break
                if cell_load(var_asg, lv * 8) >= 0:
                    cell_store(asg_lv, ai * 8, lv)
                    ai = ai + 1
                lv = lv + 1
            pb : ., mut = 0
            loop:
                if pb >= rc:
                    break
                n_in : ., mut = rc - pb
                if n_in > 5:
                    n_in = 5
                ei : ., mut = g_opt_meta_count
                grow_opt_meta(ei + 1)
                // Write key(u32) + data_len(u32) header using store8
                eo := ei * OPT_META_STRIDE
                store8(g_opt_meta, eo, 0)
                store8(g_opt_meta, eo+1, 0)
                store8(g_opt_meta, eo+2, 0)
                store8(g_opt_meta, eo+3, 0)  // OPT_KEY_REG_ASSIGN=0
                dl : ., mut = 4 + n_in * 8
                store8(g_opt_meta, eo+4, dl%256)
                store8(g_opt_meta, eo+5, (dl/256)%256)
                store8(g_opt_meta, eo+6, (dl/65536)%256)
                store8(g_opt_meta, eo+7, (dl/16777216)%256)
                // Write count
                store8(g_opt_meta, eo+8, n_in%256)
                store8(g_opt_meta, eo+9, (n_in/256)%256)
                store8(g_opt_meta, eo+10, (n_in/65536)%256)
                store8(g_opt_meta, eo+11, (n_in/16777216)%256)
                // Write pairs: [var_idx(u32), reg(u32)]...（对 @+12 起，8B 步进）
                di : ., mut = 12
                pi : ., mut = 0
                loop:
                    if pi >= n_in:
                        break
                    lvp := cell_load(asg_lv, (pb + pi) * 8)
                    vw := vs + lvp
                    rn := cell_load(var_asg, lvp * 8)
                    store8(g_opt_meta, eo+di, vw%256)
                    store8(g_opt_meta, eo+di+1, (vw/256)%256)
                    store8(g_opt_meta, eo+di+2, (vw/65536)%256)
                    store8(g_opt_meta, eo+di+3, (vw/16777216)%256)
                    store8(g_opt_meta, eo+di+4, rn%256)
                    store8(g_opt_meta, eo+di+5, (rn/256)%256)
                    store8(g_opt_meta, eo+di+6, (rn/65536)%256)
                    store8(g_opt_meta, eo+di+7, (rn/16777216)%256)
                    di = di + 8
                    pi = pi + 1
                g_opt_meta_count = ei + 1
                pb = pb + n_in
            // 阶段 5 尾：写位置登记表。g_opt_meta 是发射路径私有结构，由 instr.cr
            // get_reg_for_var 消费；判定逻辑读取 kern_loc_assign 写入的登记表。每个
            // g_opt_meta 写点都必须成对登记。分配粒度是 var 级单位置，因此同一 var
            // 的全部版本条目登记同一个 loc：对每个已分配 var vw，遍历
            // [entry_start(fi), entry_start + entry_count) 中 ent_var(e) == vw 的条目，
            // 调用 kern_loc_assign。这与判定侧 meta_reg_for_var 的投影语义等价。
            // 分配器将来升到条目级时按条目登记，判定零改动。
            es := entry_start(fi)
            ec := entry_count(fi)
            ai = 0
            loop:
                if ai >= rc:
                    break
                lvp := cell_load(asg_lv, ai * 8)
                vw := vs + lvp
                rn := cell_load(var_asg, lvp * 8)
                ej : ., mut = 0
                loop:
                    if ej >= ec:
                        break
                    e := es + ej
                    if ent_var(e) == vw:
                        kern_loc_assign(e, rn)
                    ej = ej + 1
                ai = ai + 1
        fi = fi + 1

// ── v10 target-fact reconstruction ────────────────────────────────────────
// The .ccr carries semantic facts only. Access widths, array strides, and
// runtime allocation sizes are target facts; the instance rebuilds them from
// type ids/variable types and the x86-64 layout (mapping.cr/x86_mapping.cr).
// These helpers live here because both backend entries (the concat corearch
// entry and the project-mode target entry) import regalloc.cr.
fn corearch_ptr_pointee(var: int) -> int:
    if var < 0:
        return TI_INT
    ti := irv_type(var)
    if ti >= 0:
        k := get_type_kind(ti)
        if k == TYP_PTR || k == TYP_REF:
            return get_type_data(ti)
    return TI_INT

// Access width for IR_DEREF/IR_STORE_PTR. Mirrors the front-end derivation
// ptr_access_width: pointee value size, falling back to one target slot.
fn corearch_nod_access_width(n: int) -> int:
    w := mp_size(corearch_ptr_pointee(nod_s1(n)))
    if w <= 0:
        return mp_stride(TI_INT)
    return w

// Element stride for IR_ALLOC_ARRAY. IR values occupy one target slot.
fn corearch_nod_alloc_stride() -> int:
    return mp_stride(TI_INT)

// Byte extent of the allocation a runtime pointer bound refers to. The base
// variable is the destination of an ALLOC_ARRAY/ALLOC_STRUCT node, and that
// node's semantic count/struct name plus the target layout determine the size.
fn corearch_alloc_size_of_var(v: int) -> int:
    if v < 0:
        return 0
    ni : ., mut = 0
    loop:
        if ni >= g_v7_nod_count:
            break
        if nod_dest(ni) == v:
            aop := nod_op(ni)
            if aop == IR_ALLOC_ARRAY:
                return mp_extent(nod_s1(ni), TI_INT)
            if aop == IR_ALLOC_STRUCT:
                nm := nod_s3(ni)
                si : ., mut = 0
                loop:
                    if si >= g_struct_count:
                        break
                    if si_name(si) == nm:
                        return mp_extent(si_field_count(si), TI_INT)
                    si = si + 1
                return mp_stride(TI_INT)
        ni = ni + 1
    return 0

// Runtime pointer bound size for IR_DEREF/IR_STORE_PTR. The semantic flag says
// a runtime bound exists; the byte size is derived from the allocation node.
fn corearch_nod_runtime_bound_size(n: int) -> int:
    fl := nod_type_flags(n)
    if (fl / CCR_NOD_FLAG_RUNTIME_PTR_BOUNDS) % 2 != 1:
        return 0
    op := nod_op(n)
    base : ., mut = -1
    if op == IR_DEREF:
        base = nod_s2(n)
    else if op == IR_STORE_PTR:
        base = nod_dest(n)
    if base < 0:
        return 0
    return corearch_alloc_size_of_var(base)

// 语义对象模型：从 NOD 重建线性调度。
// ccr_io.cr load_ccr 从内核对象缓冲顺序生成 48 字节线性流 g_ir_instrs。
// nod_* 访问器读 g_v7_nod_sem 的 32 字节语义字段，nod_edge_first 和 nod_edge_count
// 读邻接域。REG 展开和函数边界回填（root span 到 g_ir_func_instr_start 和
// g_ir_func_instr_count）留在 loader。
// 调用方是 corearch.cr 和组合根 src/targets/x86_64/linux/elf/main.cr；load_ccr 成功后、
// 分派和发射前调用一次。
fn build_linear_schedule():
    grow_ir_instrs(g_v7_nod_count)
    ni : ., mut = 0
    loop:
        if ni >= g_v7_nod_count:
            break
        op := nod_op(ni)
        iri_set_op(ni, op)
        iri_set_dest(ni, nod_dest(ni))
        iri_set_s1(ni, nod_s1(ni))
        iri_set_s2(ni, nod_s2(ni))
        iri_set_s3(ni, nod_s3(ni))
        iri_set_tk(ni, nod_tk(ni))
        // v10: the .ccr does not carry target facts. Reconstruct the access
        // width for pointer dereferences and the element stride for allocations
        // from the semantic type plus the x86-64 layout. The runtime-bound size
        // for pointer stores/loads is derived from the allocation node.
        if op == IR_ALLOC_ARRAY:
            iri_set_s2(ni, corearch_nod_alloc_stride())
        else if op == IR_DEREF || op == IR_STORE_PTR:
            iri_set_tk(ni, corearch_nod_access_width(ni))
            iri_set_s3(ni, corearch_nod_runtime_bound_size(ni))
        g_ir_instr_count = ni + 1
        ni = ni + 1
