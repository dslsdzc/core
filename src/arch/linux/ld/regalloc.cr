// === regalloc.cr ===
// 编码层资源决策（corearch 侧）：寄存器分配数据面（存在区间/版本条目/共存）
// + CAG 分配（alloc_registers）+ 一致性判定（verify/注入钩子）。
// 2026-09-07 自 opt.cr 按层拆分迁入（迁移段于 corec 侧 opt.cr 切换提交删除；
// 本文件保真搬移——实现与核心注释未改，表述清理见 regalloc-backend 计划 Task 5）。
// 归位后同进程消费：g_opt_meta 内存态自算 + g_ir_entries 自 corearch 自建
// （.ccr ENT/opt_meta 不再传输——D-1=Y 拍板，见计划 Task 1 盘点）。

// ------------------------------------------------------------------
// v6 数据基础：存在区间推导（指令序 [first_ref, last_ref]）
// ------------------------------------------------------------------
// compute_live_ranges 填充全局 g_ir_live_ranges（表全局声明在 globals.cr），
// alloc_registers 改读本表——与原内联 iv_buf 构建逻辑逐行一致（行为不变）。
// 表布局：每函数一段，段内每「函数内 var」16B（first_ref/last_ref 各 8B，
// 函数内指令序）；func_i 段起始 = Σ var_count[0..func_i)，不乘固定稠密系数
// （live_range_slot 即该前缀累计；16B 记录 + grow 风格同 g_ir_slice_lens）。

fn grow_live_ranges(needed: int) {
    if needed < g_live_range_cap { return; }
    nc := g_live_range_cap * 2; if nc < 64 { nc = 64; } if nc < needed { nc = needed + 64; }
    nb := alloc(nc * 16); _dyncpy(g_ir_live_ranges, g_live_range_cap * 16, nb);
    g_ir_live_ranges = nb; g_live_range_cap = nc;
}

fn live_range_slot(func_i: int, var_i: int) -> int {
    // 函数内 var 索引 = var_i − var_start[func_i]；func_i 段起始 = 前缀 var_count 累计
    off : ., mut = 0;
    fi : ., mut = 0;
    loop { if fi >= func_i { break; }
        off = off + r64(g_ir_func_var_count, fi * 8);
        fi = fi + 1; }
    return (off + (var_i - r64(g_ir_func_var_start, func_i * 8))) * 16;
}

fn live_first(func_i: int, var_i: int) -> int {
    if func_i < 0 || var_i < 0 { return -1; }
    return r64(g_ir_live_ranges, live_range_slot(func_i, var_i));
}

fn live_last(func_i: int, var_i: int) -> int {
    if func_i < 0 || var_i < 0 { return -1; }
    return r64(g_ir_live_ranges, live_range_slot(func_i, var_i) + 8);
}

// 存在区间推导：填充 g_ir_live_ranges。语义 = 原 alloc_registers 内联 iv_buf
// 构建（:210-241）：逐函数逐指令扫描，dest/s1/s2 落在 [vs, vs+vc) 内则扩展
// [first_ref,last_ref]（首见写 first，之后推进 last）；未使用 var 两条均为 -1。
fn compute_live_ranges() {
    total : ., mut = 0;
    fi : ., mut = 0;
    loop { if fi >= g_ir_func_count { break; }
        total = total + r64(g_ir_func_var_count, fi * 8);
        fi = fi + 1; }
    grow_live_ranges(total);
    g_live_range_count = total;
    // 首遍写 -1（区间未知 = -1，同 alloc_registers 的 iv_buf 初始化语义）
    zi : ., mut = 0;
    loop { if zi >= total { break; }
        w64(g_ir_live_ranges, zi * 16, -1);
        w64(g_ir_live_ranges, zi * 16 + 8, -1);
        zi = zi + 1; }
    // 逐函数逐指令扫描：段偏移 = 运行中前缀累计（与 live_range_slot 前缀一致）
    seg : ., mut = 0;
    fi = 0;
    loop {
        if fi >= g_ir_func_count { break; }
        ic := r64(g_ir_func_instr_count, fi * 8);
        ist := r64(g_ir_func_instr_start, fi * 8);
        vc := r64(g_ir_func_var_count, fi * 8);
        vs := r64(g_ir_func_var_start, fi * 8);
        if vc > 0 {
            ii : ., mut = 0;
            loop {
                if ii >= ic { break; }
                inst := ist + ii;
                d := iri_dest(inst); s1 := iri_s1(inst); s2 := iri_s2(inst);
                if d >= vs && d < vs + vc {
                    lv := d - vs;
                    st := (seg + lv) * 16;
                    if r64(g_ir_live_ranges, st) < 0 { w64(g_ir_live_ranges, st, ii); }
                    w64(g_ir_live_ranges, st + 8, ii);
                }
                if s1 >= vs && s1 < vs + vc {
                    lv := s1 - vs;
                    st := (seg + lv) * 16;
                    if r64(g_ir_live_ranges, st) < 0 { w64(g_ir_live_ranges, st, ii); }
                    w64(g_ir_live_ranges, st + 8, ii);
                }
                if s2 >= vs && s2 < vs + vc {
                    lv := s2 - vs;
                    st := (seg + lv) * 16;
                    if r64(g_ir_live_ranges, st) < 0 { w64(g_ir_live_ranges, st, ii); }
                    w64(g_ir_live_ranges, st + 8, ii);
                }
                ii = ii + 1;
            }
        }
        seg = seg + vc;
        fi = fi + 1;
    }
    // v6 Task 2：条目版本化——对全部函数切分版本条目（逐函数升序，
    // compute_entries 的 func_i==0 分支负责整表重建；本函数幂等可重跑）。
    // 与 opt 门控解耦：compute_live_ranges 自身在 cir --dump-entries 与
    // alloc_registers（O2）两处被调，条目表随算随新。
    ef : ., mut = 0;
    loop {
        if ef >= g_ir_func_count { break; }
        compute_entries(ef);
        ef = ef + 1;
    }
}

// ------------------------------------------------------------------
// v6 条目版本化：变量 × 定值点切分版本条目
// ------------------------------------------------------------------
// Core IR 非 SSA——变量可多次定值。定值识别（GC 批 2 扩权，格式定稿 §4.1
// 「dest ≥ 0 = 定值点」）：
//   · 每个写变量槽的指令 = 该变量的定值点——IR_ALLOC（局部槽初定值，interp
//     置零）、IR_ALLOC_ARRAY/IR_ALLOC_STRUCT（数组/结构变量诞生，无初值声明
//     不发 IR_ALLOC，如 `a : [int; N];`——见 ir_gen EXPR_LET 路径）、以及全部
//     producer（CONST/BINARY/CALL/LOAD 族/DEREF/…，dest = 产出变量）。
//   · IR_STORE 形态 ρ(s1):=ρ(s2)——定值目标在 s1 不在 dest（dest 恒 -1，见
//     docs/ir-op-semantics.md §2.1），单列规则。
//   · 例外（dest ≥ 0 但非变量定值，扫 IR 全集勘定 GC 批 2）：
//       IR_STORE_INDEX_VAR —— dest = 被存值源（M[s1+8·s2] := ρ(dest)，值槽不写）
//       IR_STORE_PTR      —— dest = runtime base 标注（provenance_verify.cr
//                             改写：无结果指令用 dest 携带基址变量，源语义）
//       IR_DYN_DISPATCH   —— dest = _dyncall 占位 var（分发不写槽）
// 每个定值切分一个新版本条目。
// 版本存在区间（全局指令序闭区间，与 Task 1 区间表同语义、坐标 +instr_start）：
//   版本 j = [def_j, min(def_{j+1}−1, last_ref)]（末版 = [def_k, last_ref]；
//   last_ref 恒 ≥ 末定值——定值写自身计入引用）。
// 无定值但有引用的变量（函数参数、无写临时值等）→ 单条目 def_instr=−1、
// 区间 = [first_ref, last_ref]；从未引用（first_ref=−1）跳过。
// 版本号不落盘：同 var 条目按 def_instr 升序（单遍扫描即升序），版本序 = 组内序号。
// 调用前置：compute_live_ranges() 已先行（截断用 last_ref），func_i 升序调用
// （func_i==0 重置全局计数——整表重建，重复调用幂等）。

fn grow_entries(needed: int) {
    if needed < g_entry_cap { return; }
    nc : ., mut = g_entry_cap * 2; if nc < 64 { nc = 64; } if nc < needed { nc = needed + 64; }
    nb := alloc(nc * ESZ_ENTRY); _dyncpy(g_ir_entries, g_entry_cap * ESZ_ENTRY, nb);
    g_ir_entries = nb; g_entry_cap = nc;
}

fn grow_func_entry_meta(needed: int) {
    if needed < g_ir_func_entry_cap { return; }
    nc : ., mut = g_ir_func_entry_cap * 2; if nc < 64 { nc = 64; } if nc < needed { nc = needed + 64; }
    sz := nc * 8;
    n1 := alloc(sz); _dyncpy(g_ir_func_entry_start, g_ir_func_entry_cap * 8, n1); g_ir_func_entry_start = n1;
    n2 := alloc(sz); _dyncpy(g_ir_func_entry_count, g_ir_func_entry_cap * 8, n2); g_ir_func_entry_count = n2;
    g_ir_func_entry_cap = nc;
}

// 条目表字段访问器（24B/条、4B 字段 LE；字段布局注释见 globals.cr）。
// 读统一走 buf_read_i32（ccr_io.cr，真实函数体带符号扩展）——不能调 r32：
// Python bootstrap 的 StackAsmGen 把名为 r32 的调用内联成 `mov eax,[rdi+rsi]`
// （零扩展 32 位读），bootstrap 产物里负值（-1 home/def）会读成 4294967295
// （x86_64_stack_asm.py:242；r32 源码里的符号修正逻辑只在自举产物中生效）。
// 写侧 w32 内联为 `mov [rdi+rsi],edx`（低 32 位存储）——补码语义正确，可用。
fn ent_off(e: int) -> int { return e * ESZ_ENTRY; }
fn ent_var(e: int) -> int { return buf_read_i32(g_ir_entries, ent_off(e) + OFF_ENTRY_VAR); }
fn ent_def(e: int) -> int { return buf_read_i32(g_ir_entries, ent_off(e) + OFF_ENTRY_DEF); }
fn ent_live_start(e: int) -> int { return buf_read_i32(g_ir_entries, ent_off(e) + OFF_ENTRY_LS); }
fn ent_live_end(e: int) -> int { return buf_read_i32(g_ir_entries, ent_off(e) + OFF_ENTRY_LE); }
fn ent_home(e: int) -> int { return buf_read_i32(g_ir_entries, ent_off(e) + OFF_ENTRY_HOME); }
fn ent_flags(e: int) -> int { return buf_read_i32(g_ir_entries, ent_off(e) + OFF_ENTRY_FLAGS); }

// 函数条目段界（全局条目下标；compute_entries 已跑过才有效）
fn entry_start(func_i: int) -> int {
    if func_i < 0 || func_i >= g_ir_func_count { return 0; }
    return r64(g_ir_func_entry_start, func_i * 8);
}

fn entry_count(func_i: int) -> int {
    if func_i < 0 || func_i >= g_ir_func_count { return 0; }
    return r64(g_ir_func_entry_count, func_i * 8);
}

fn compute_entries(func_i: int) -> int {
    if func_i == 0 { g_entry_count = 0; }
    ic := r64(g_ir_func_instr_count, func_i * 8);
    ist := r64(g_ir_func_instr_start, func_i * 8);
    vc := r64(g_ir_func_var_count, func_i * 8);
    vs := r64(g_ir_func_var_start, func_i * 8);
    cnt : ., mut = 0;
    if ic > 0 && vc > 0 {
        // 每「函数内 var」一条最近打开条目（-1 = 未打开）：定值序列切割 O(1) 收口
        prev : string, mut = alloc(vc * 8);
        pz : ., mut = 0;
        loop {
            if pz >= vc { break; }
            w64(prev, pz * 8, -1);
            pz = pz + 1;
        }
        // 单遍扫描：定值点 = IR_STORE 的目标槽（s1=var）∪ 其余指令 dest≥0
        // 命中函数段（格式定稿 §4.1——GC 批 2 扩权，见本区头：ALLOC_ARRAY/
        // ALLOC_STRUCT 等内存对象诞生 + 全部 producer 直写并入版本切分；
        // STORE_INDEX_VAR/STORE_PTR/DYN_DISPATCH 的 dest 非定值，不判）
        ii : ., mut = 0;
        loop {
            if ii >= ic { break; }
            inst := ist + ii;
            op := iri_op(inst);
            dv : ., mut = -1;
            if op == IR_STORE {
                s1 := iri_s1(inst);
                if s1 >= vs && s1 < vs + vc { dv = s1; }
            } else if op != IR_STORE_INDEX_VAR && op != IR_STORE_PTR && op != IR_DYN_DISPATCH {
                d := iri_dest(inst);
                if d >= vs && d < vs + vc { dv = d; }
            }
            if dv >= 0 {
                lv := dv - vs;
                last_global : ., mut = -1;
                ll := live_last(func_i, dv);
                if ll >= 0 { last_global = ist + ll; }
                // 收口上一版本：end = min(def−1, last_ref)（last_ref ≥ 次定值，恒取 def−1）
                pe := r64(prev, lv * 8);
                if pe >= 0 {
                    pend : ., mut = inst - 1;
                    if last_global >= 0 && last_global < pend { pend = last_global; }
                    w32(g_ir_entries, pe * ESZ_ENTRY + OFF_ENTRY_LE, pend);
                }
                // 开新版本：区间端点暂定 = 定值点..last_ref，末版直接成立
                grow_entries(g_entry_count + 1);
                eo := g_entry_count * ESZ_ENTRY;
                w32(g_ir_entries, eo + OFF_ENTRY_VAR, dv);
                w32(g_ir_entries, eo + OFF_ENTRY_DEF, inst);
                w32(g_ir_entries, eo + OFF_ENTRY_LS, inst);
                w32(g_ir_entries, eo + OFF_ENTRY_LE, last_global);
                w32(g_ir_entries, eo + OFF_ENTRY_HOME, -1);
                w32(g_ir_entries, eo + OFF_ENTRY_FLAGS, 0);
                w64(prev, lv * 8, g_entry_count);
                g_entry_count = g_entry_count + 1;
                cnt = cnt + 1;
            }
            ii = ii + 1;
        }
        // 无定值但有引用的 var（参数/单写临时值等）：单条目 def=-1
        lv2 : ., mut = 0;
        loop {
            if lv2 >= vc { break; }
            if r64(prev, lv2 * 8) < 0 {
                gv := vs + lv2;
                ff := live_first(func_i, gv);
                ll := live_last(func_i, gv);
                if ff >= 0 && ll >= 0 {
                    grow_entries(g_entry_count + 1);
                    eo := g_entry_count * ESZ_ENTRY;
                    w32(g_ir_entries, eo + OFF_ENTRY_VAR, gv);
                    w32(g_ir_entries, eo + OFF_ENTRY_DEF, -1);
                    w32(g_ir_entries, eo + OFF_ENTRY_LS, ist + ff);
                    w32(g_ir_entries, eo + OFF_ENTRY_LE, ist + ll);
                    w32(g_ir_entries, eo + OFF_ENTRY_HOME, -1);
                    w32(g_ir_entries, eo + OFF_ENTRY_FLAGS, 0);
                    g_entry_count = g_entry_count + 1;
                    cnt = cnt + 1;
                }
            }
            lv2 = lv2 + 1;
        }
    }
    grow_func_entry_meta(func_i + 1);
    w64(g_ir_func_entry_start, func_i * 8, g_entry_count - cnt);
    w64(g_ir_func_entry_count, func_i * 8, cnt);
    return cnt;
}

// --dump-entries 调试通道输出（cir 命令调用，Task 2 测试载体）：
// 每函数一段、一行一条目；坐标 = 全局指令序/全局变量索引（与表内一致），
// v = 组内版本序（1-based），kind = 定值指令种类（def≥0 = producer opcode
// 名，GC 批 2 后不再止于 ALLOC/STORE；def=-1 → "-"）。

// 定值指令种类名（--dump-entries kind= 字段）：定值点 = dest≥0 producer
// opcode ∪ IR_STORE(s1)（本区头规则）——只列会作为定值点出现的 opcode，
// 未列 opcode 回退数字（不该出现；出现即探明新定值形态的信号）。
fn ir_op_kind_name(op: int) -> string {
    if op == IR_ALLOC { return "ALLOC"; }
    if op == IR_ALLOC_STRUCT { return "ALLOC_STRUCT"; }
    if op == IR_ALLOC_ARRAY { return "ALLOC_ARRAY"; }
    if op == IR_STORE { return "STORE"; }
    if op == IR_CONST { return "CONST"; }
    if op == IR_LOAD { return "LOAD"; }
    if op == IR_LOAD_FIELD { return "LOAD_FIELD"; }
    if op == IR_LOAD_INDEX { return "LOAD_INDEX"; }
    if op == IR_LOAD_INDEX_VAR { return "LOAD_INDEX_VAR"; }
    if op == IR_BINARY { return "BINARY"; }
    if op == IR_UNARY { return "UNARY"; }
    if op == IR_CALL { return "CALL"; }
    if op == IR_CALL_EXTERN { return "CALL_EXTERN"; }
    if op == IR_HOTPATCH_ROUTE { return "HOTPATCH_ROUTE"; }
    if op == IR_MAKE_ENUM { return "MAKE_ENUM"; }
    if op == IR_REF { return "REF"; }
    if op == IR_DEREF { return "DEREF"; }
    if op == IR_LOAD_ENUM_TAG { return "LOAD_ENUM_TAG"; }
    if op == IR_SLICE { return "SLICE"; }
    if op == IR_ADDR_INDEX { return "ADDR_INDEX"; }
    if op == IR_SPAWN { return "SPAWN"; }
    if op == IR_AWAIT { return "AWAIT"; }
    if op == IR_ARENA_NEW { return "ARENA_NEW"; }
    if op == IR_DYN_PACK { return "DYN_PACK"; }
    if op == IR_DYN_TAG { return "DYN_TAG"; }
    if op == IR_DYN_VAL { return "DYN_VAL"; }
    if op == IR_LAZY_THUNK { return "LAZY_THUNK"; }
    if op == IR_LAZY_FORCE { return "LAZY_FORCE"; }
    if op == IR_FNADDR { return "FNADDR"; }
    if op == IR_I2F { return "I2F"; }
    if op == IR_F2I { return "F2I"; }
    if op == IR_PHI { return "PHI"; }
    return "OP" + int_str(op);
}

fn dump_entries_summary() {
    fi : ., mut = 0;
    loop {
        if fi >= g_ir_func_count { break; }
        es := entry_start(fi);
        ec := entry_count(fi);
        print("== entries func "); print(int_str(fi)); print(" (");
        print(istr_get(r64(g_ir_func_name_idx, fi * 8))); print("): ");
        println(int_str(ec));
        ei : ., mut = 0;
        loop {
            if ei >= ec { break; }
            e := es + ei;
            gv := ent_var(e);
            ord : ., mut = 1;
            ej : ., mut = es;
            loop {
                if ej >= e { break; }
                if ent_var(ej) == gv { ord = ord + 1; }
                ej = ej + 1;
            }
            print(" e "); print(int_str(e));
            print(" var "); print(int_str(gv));
            vn := get_ir_var_name(gv);
            if str_len(vn) > 0 { print(" name="); print(vn); }
            print(" v "); print(int_str(ord));
            print(" def "); print(int_str(ent_def(e)));
            d := ent_def(e);
            if d >= 0 {
                print(" kind="); print(ir_op_kind_name(iri_op(d)));
            } else {
                print(" kind=-");
            }
            print(" live "); print(int_str(ent_live_start(e))); print("..");
            print(int_str(ent_live_end(e)));
            print(" home "); print(int_str(ent_home(e)));
            print(" flags "); println(int_str(ent_flags(e)));
            ei = ei + 1;
        }
        fi = fi + 1;
    }
}

// ===== v6 Task 3：共存推导（存在区间相交；不落盘——D3 判定现算）=====
// 格层语义：共存 = 对称关系（无传递性，最弱理论）。条目的 live 区间为
// 闭区间 [ls, le]（全局指令序坐标——v6 NOD 坐标同源）。

// 单对查询：两条目存在区间相交 ⟺ ls1 ≤ le2 && ls2 ≤ le1（闭区间）。
// e1/e2 = 全局条目索引；func_i 保留兼容调用约定（跨函数指令区间天然
// 不重叠，无需按函数过滤）。判定四条之共存互斥的输入。
fn entries_coexist(func_i: int, e1: int, e2: int) -> int {
    // GC-1（M-5）：无上界校验收口——e1/e2 ≥ g_entry_count 属越界索引
    // （条目表容量 ≥ 计数：槽后区域读到零填充/缓冲外 → 判定垃圾或崩溃），
    // 防御性返回 0，风格与访问器约定一致（判定原语化前补）。
    if e1 < 0 || e2 < 0 || e1 >= g_entry_count || e2 >= g_entry_count { return 0; }
    if e1 == e2 { return 0; }
    s1 := ent_live_start(e1); n1 := ent_live_end(e1);
    s2 := ent_live_start(e2); n2 := ent_live_end(e2);
    if s1 < 0 || s2 < 0 { return 0; }
    if s1 <= n2 && s2 <= n1 { return 1; }
    return 0;
}

// 同 var 跨版本冲突数（数据自检）：版本按定值点切割，构造保证
// 版本 j 区间终点 = 版本 j+1 定值点 −1 < 其起点 → 相邻版本必不交。
// 返回 0 = 版本化正确（任何 >0 = 版本切割 bug）。O(n) 每 var 组。
fn coexist_version_conflicts(func_i: int) -> int {
    es := entry_start(func_i);
    ec := entry_count(func_i);
    conflicts : ., mut = 0;
    ei : ., mut = 0;
    loop {
        if ei >= ec { break; }
        e := es + ei;
        gv := ent_var(e);
        // 找同 var 的下一版本条目（版本按定值序相邻）
        ej : ., mut = ei + 1;
        loop {
            if ej >= ec { break; }
            if ent_var(es + ej) == gv {
                if entries_coexist(func_i, e, es + ej) != 0 {
                    conflicts = conflicts + 1;
                }
                break;
            }
            ej = ej + 1;
        }
        ei = ei + 1;
    }
    return conflicts;
}

// 同 home 组内冲突数（判定输入雏形——共存互斥：同槽条目不共存）。
// home = -1（未分配）不参与。真实成本注记（评审 I-2）：home ≥ 0 时对每函数
// 做 O(E²) 相等探测（与组大小 k 无关；当前无回填路径 = 内层不进入 = O(E)）。
// 触发点 = 判定进入消费端（分配器/自检回填 home 后）——届时须按 v6 格式定稿
// §4.2 per-group sweep O(k log k) 重写，不得直接复用本函数（ledger 门禁注记）。
fn coexist_home_conflicts(func_i: int) -> int {
    es := entry_start(func_i);
    ec := entry_count(func_i);
    conflicts : ., mut = 0;
    ei : ., mut = 0;
    loop {
        if ei >= ec { break; }
        e1 := es + ei;
        h1 := ent_home(e1);
        if h1 >= 0 {
            ej : ., mut = ei + 1;
            loop {
                if ej >= ec { break; }
                e2 := es + ej;
                if ent_home(e2) == h1 {
                    if entries_coexist(func_i, e1, e2) != 0 {
                        conflicts = conflicts + 1;
                    }
                }
                ej = ej + 1;
            }
        }
        ei = ei + 1;
    }
    return conflicts;
}

// --dump-coexist 调试通道（cir 命令调用，Task 3 测试载体）：
// 每函数输出版本冲突数（应 0）与同 home 组内冲突数（未分配时应 0）。
fn dump_coexist_summary() {
    fi : ., mut = 0;
    loop {
        if fi >= g_ir_func_count { break; }
        print("== coexist func "); print(int_str(fi)); print(" (");
        print(istr_get(r64(g_ir_func_name_idx, fi * 8))); print("):");
        print(" ver_conf "); print(int_str(coexist_version_conflicts(fi)));
        print(" home_conf "); println(int_str(coexist_home_conflicts(fi)));
        fi = fi + 1;
    }
}

// GC-1 测试探针（cir --inject-coexist-oob 载体；真实构建路径永不调用）：
// entries_coexist 上界防御——e1/e2 = 首/次个越界条目索引（≥ g_entry_count）。
// 守卫缺失时 accessor 对槽后区域越界读：条目表容量 ≥ 计数、alloc 零初始化
// → 全零槽 [ls=0, le=0] 与任何区间相交 → 误判共存返回 1（读穿缓冲则崩溃）。
// 输出 "coexist-oob-guard: <0|1>"，r != 0 → 退出码 1（测试断言 rc + 数值）。
fn inject_coexist_oob() -> int {
    e1 := g_entry_count;
    e2 := g_entry_count + 1;
    r := entries_coexist(0, e1, e2);
    print("coexist-oob-guard: "); println(int_str(r));
    if r != 0 { return 1; }
    return 0;
}

// ===== v6 Task 5：判定消费最小闭环（一致性自检——共 specs/
// regalloc-consistency.corespec 规约）=====
// 分配结果真相源 = g_opt_meta 的 OPT_KEY_REG_ASSIGN 对（var_idx → x86 寄存器号）：
// instr.cr 的 g2_slot/get_reg_for_var 在发射时按此把 var 落寄存器（regalloc 移
// 后端后 = corearch 进程内自算自消费——.ccr 不再传输这份 meta）——判定消费它
// 就是消费「实际编码的分配」。
// （注：本文件旧区头「IR 操作数改写为负编码」是过时设计残留——实现已改为
// 元数据表 + 后端 g2_slot 查询，判定按实现走。）
// 版本级 vs 变量级对齐（衔接决策 b）：alloc_registers（CAG 升级后仍）是变量级
// 单位置分配（粒度论证见 alloc 区头：meta/后端/.ccr seam = var 级单位置），条目
// 是版本级。判定把分配结果按「条目所属 var」投影到版本条目上——同 var 多版本 =
// 同位置组内多条（版本按定值切割互不共存，sweep 自然校验）；两条目同位置且共存
// = 违反。变量级表述（同寄存器两 var 的窗口相交）与条目级表述在变量级分配下
// 等价（一 var 的版本区间并 = 其整活跃窗口），但条目级表述在分配器将来升级为
// 条目级（版本各自落位置）后无需改动——判定原样消费。③④（驱逐配对/调用点
// 失效）按 CAG 范围控制留 TODO：本分配器无动态驱逐（静态放置失败 = 栈驻留
// home 保留，判定③无事件）、只用 callee-saved（调用点契约 ④ 平凡满足）——
// 随 CAG 批次裁定：③④ 的判定实现留待 spill/调用点解锁引入时，规约已先行落
// 文档（spec/regalloc-consistency.corespec R3/R4）。

LOC_HOME_BASE : int = 1000000;  // 位置编码：寄存器号直用（0..15）；home 槽偏移本常量
RPT_MAX : int = 8;              // 规则违反诊断每函数每规则打印上限（计数不封顶）

// 分配结果解析：与 instr.cr get_reg_for_var 同进程、同 g_opt_meta 布局
// （regalloc 移后端前 corec 侧镜像已随迁收敛——本函数为判定侧独立访问）。
fn meta_reg_for_var(var_idx: int) -> int {
    mi : ., mut = 0;
    loop {
        if mi >= g_opt_meta_count { break; }
        mo := mi * OPT_META_STRIDE;
        mk := r32(g_opt_meta, mo);
        if mk == OPT_KEY_REG_ASSIGN {
            data_len := r32(g_opt_meta, mo + 4);
            di : ., mut = 4;  // skip count u32, pairs start at +4
            loop {
                if di >= data_len { break; }
                vi := r32(g_opt_meta, mo + 8 + di);
                if vi == var_idx {
                    return r32(g_opt_meta, mo + 8 + di + 4);
                }
                di = di + 8;
            }
        }
        mi = mi + 1;
    }
    return -1;
}

// 16B 记录比较（归并用）：key = (loc, entry 的 live_start)，均升序
fn rl_rec_lt(buf: string, a: int, b: int) -> int {
    la := r64(buf, a * 16); lb := r64(buf, b * 16);
    if la != lb { if la < lb { return 1; } return 0; }
    ea := r64(buf, a * 16 + 8); eb := r64(buf, b * 16 + 8);
    if ent_live_start(ea) < ent_live_start(eb) { return 1; }
    return 0;
}

// 自底向上归并排序（16B 记录 {loc:8, entry:8}）——O(k log k)，
// v6 格式定稿 §4.2 sweep 门禁（同位置组内检查不得逐对 O(E²)）。
fn rl_merge_sort(buf: string, n: int) {
    if n <= 1 { return; }
    tmp := alloc(n * 16);
    width : ., mut = 1;
    loop {
        if width >= n { break; }
        left : ., mut = 0;
        loop {
            if left >= n { break; }
            mid : ., mut = left + width; if mid > n { mid = n; }
            right : ., mut = left + width * 2; if right > n { right = n; }
            i : ., mut = left; j : ., mut = mid; k : ., mut = left;
            loop {
                if i >= mid || j >= right { break; }
                if rl_rec_lt(buf, i, j) != 0 {
                    w64(tmp, k * 16, r64(buf, i * 16));
                    w64(tmp, k * 16 + 8, r64(buf, i * 16 + 8));
                    i = i + 1;
                } else {
                    w64(tmp, k * 16, r64(buf, j * 16));
                    w64(tmp, k * 16 + 8, r64(buf, j * 16 + 8));
                    j = j + 1;
                }
                k = k + 1;
            }
            loop {
                if i >= mid { break; }
                w64(tmp, k * 16, r64(buf, i * 16));
                w64(tmp, k * 16 + 8, r64(buf, i * 16 + 8));
                i = i + 1; k = k + 1;
            }
            loop {
                if j >= right { break; }
                w64(tmp, k * 16, r64(buf, j * 16));
                w64(tmp, k * 16 + 8, r64(buf, j * 16 + 8));
                j = j + 1; k = k + 1;
            }
            left = right;
        }
        zi : ., mut = 0;
        loop {
            if zi >= n { break; }
            w64(buf, zi * 16, r64(tmp, zi * 16));
            w64(buf, zi * 16 + 8, r64(tmp, zi * 16 + 8));
            zi = zi + 1;
        }
        width = width * 2;
    }
}

// 打印位置描述（loc < LOC_HOME_BASE = 寄存器号；否则 home 槽）
fn rl_print_loc(loc: int) {
    if loc >= LOC_HOME_BASE {
        print("home slot "); print(int_str(loc - LOC_HOME_BASE));
    } else {
        print("reg "); print(int_str(loc));  // x86 寄存器枚举号（3=rbx, 12-15=r12-r15）
    }
}

fn rl_func_name(fi: int) {
    print("func "); print(int_str(fi)); print(" (");
    print(istr_get(r64(g_ir_func_name_idx, fi * 8))); print(")");
}

// 规则 ① 违反诊断（打印上限 RPT_MAX 防病理刷屏，计数不封顶）
fn rl_report_rule1(func_i: int, loc: int, e1: int, e2: int) {
    print("regalloc-consistency: "); rl_func_name(func_i);
    print(": rule 1 violation: entries "); print(int_str(e1));
    print(" (var "); print(int_str(ent_var(e1))); print(") and "); print(int_str(e2));
    print(" (var "); print(int_str(ent_var(e2))); print(") both at ");
    rl_print_loc(loc);
    print(", coexist ["); print(int_str(ent_live_start(e1))); print("..");
    print(int_str(ent_live_end(e1))); print("] x ["); print(int_str(ent_live_start(e2)));
    print(".."); print(int_str(ent_live_end(e2))); println("]");
}

// 规则 ② 违反诊断
fn rl_report_rule2(func_i: int, gv: int, inst: int) {
    print("regalloc-consistency: "); rl_func_name(func_i);
    print(": rule 2 violation: read of var "); print(int_str(gv));
    vn := get_ir_var_name(gv);
    if str_len(vn) > 0 { print(" name="); print(vn); }
    print(" at instr "); print(int_str(inst));
    println(" not covered by any active version entry");
}

// 规则 ②（框架）：寄存器驻留变量的读点必须有活跃版本覆盖。
// 读点 = 指令 i 以 v 为源操作数（IR_STORE 的 s1 是写目标，排除）——只扫 s1/s2
// 源列。dest 列不入扫，两层理由：
//   · 定值指令的 dest = 本指令产出（版本起点），无读旧值语义；
//   · 例外（GC 批 2 勘定，见本区头）：STORE_INDEX_VAR/STORE_PTR/DYN_DISPATCH 的
//     dest ≥ 0 是真实读点（被存值源/基址标注/占位，非定值）——其值 var 的
//     last_ref 已含本指令（compute_live_ranges 三列同扫），版本区间止于
//     last_ref 恒覆盖，义务内无缺口（注入截断只落被扫读点；dest 独读的漏报 =
//     框架边界，驱逐机制落地时按需扩列）。
// 覆盖义务边界 = 首个版本化定值之后——GC 批 2 已按格式定稿 §4.1 把定值识别
// 扩为 dest≥0 全定值（含 ALLOC_ARRAY/ALLOC_STRUCT 内存对象诞生），义务前读
// 窗口（旧「非版本化定值供给」区）自动纳入：版本区间自定值点起连续覆盖至
// last_ref，义务内读点恒有版本（构造不变量）——本检查零改动，承诺已验证。
fn rl_rule2_func(func_i: int, vs: int, vc: int, ist: int, ic: int, es: int, ec: int) -> int {
    violations : ., mut = 0;
    lv : ., mut = 0;
    loop {
        if lv >= vc { break; }
        gv := vs + lv;
        if meta_reg_for_var(gv) < 0 { lv = lv + 1; continue; }
        // 收集该 var 的版本条目（def ≥ 0；表内按定值点升序）——先数再收集
        m : ., mut = 0;
        ei : ., mut = 0;
        loop {
            if ei >= ec { break; }
            e := es + ei;
            if ent_var(e) == gv && ent_def(e) >= 0 { m = m + 1; }
            ei = ei + 1;
        }
        if m <= 0 { lv = lv + 1; continue; }  // 无版本化定值：义务范围为空
        vers : string, mut = alloc(m * 8);
        vj : ., mut = 0;
        ei = 0;
        loop {
            if ei >= ec { break; }
            e := es + ei;
            if ent_var(e) == gv && ent_def(e) >= 0 {
                w64(vers, vj * 8, e);
                vj = vj + 1;
            }
            ei = ei + 1;
        }
        // 逐指令升序扫读点；版本游标单调推进（版本区间自 def 起无缝相接）。
        // 坐标注意（评审 F1 修复）：ent_def/ent_live_end 存全局指令坐标（ist+局部，
        // compute_entries 写入 inst = ist + ii）——比较必须用 inst 不得用局部 ii；
        // func 0 上 ist=0 使 ii == inst 掩盖该错配，非 func 0 函数上规则 ② 会失明
        // （只漏报不误报；回归 = test_live_ranges check_regalloc_read_gap_nonfunc0）。
        cursor : ., mut = 0;
        first_def := r64(vers, 0 * 8);
        ii : ., mut = 0;
        loop {
            if ii >= ic { break; }
            inst := ist + ii;
            op := iri_op(inst);
            rd : ., mut = 0;
            s1 := iri_s1(inst);
            s2 := iri_s2(inst);
            if s1 == gv && op != IR_STORE { rd = 1; }
            if s2 == gv { rd = 1; }
            if rd != 0 && inst >= ent_def(first_def) {
                // 推进游标至最后一个 def ≤ inst 的版本
                loop {
                    if cursor + 1 >= m { break; }
                    nx := r64(vers, (cursor + 1) * 8);
                    if ent_def(nx) > inst { break; }
                    cursor = cursor + 1;
                }
                cv := r64(vers, cursor * 8);
                if ent_live_end(cv) < inst {
                    if violations < RPT_MAX { rl_report_rule2(func_i, gv, inst); }
                    violations = violations + 1;
                }
            }
            ii = ii + 1;
        }
        lv = lv + 1;
    }
    return violations;
}

// 判定实现（0 = 一致 1 = 违反）——消费条目表（存在区间/home）+ 分配结果
// （g_opt_meta 投影）。precondition：alloc_registers() 已跑（条目表随算随新）。
fn verify_regalloc_consistency(func_i: int) -> int {
    if func_i < 0 || func_i >= g_ir_func_count { return 0; }
    es := entry_start(func_i);
    ec := entry_count(func_i);
    if ec <= 0 { return 0; }
    ic := r64(g_ir_func_instr_count, func_i * 8);
    ist := r64(g_ir_func_instr_start, func_i * 8);
    vc := r64(g_ir_func_var_count, func_i * 8);
    vs := r64(g_ir_func_var_start, func_i * 8);

    // 规则 ①：位置组 = 寄存器（meta 投影，loc = 寄存器号）∪ home（回填 seam，
    // loc = LOC_HOME_BASE + home）。收集有位置条目 → 按 (loc, live_start) 归并
    // 排序 → 同 loc 段内 ls 升序单遍维持最大 live_end：max_end ≥ 当前 ls ⟹ 相交。
    cnt : ., mut = 0;
    ei : ., mut = 0;
    loop {
        if ei >= ec { break; }
        e := es + ei;
        if ent_live_start(e) >= 0 && ent_live_end(e) >= 0 {
            v := ent_var(e);
            if meta_reg_for_var(v) >= 0 { cnt = cnt + 1; }
            else if ent_home(e) >= 0 { cnt = cnt + 1; }
        }
        ei = ei + 1;
    }
    rule1_viol : ., mut = 0;
    if cnt > 1 {
        rec : string, mut = alloc(cnt * 16);
        ci : ., mut = 0;
        ei = 0;
        loop {
            if ei >= ec { break; }
            e := es + ei;
            if ent_live_start(e) >= 0 && ent_live_end(e) >= 0 {
                v := ent_var(e);
                loc : ., mut = -1;
                rn := meta_reg_for_var(v);
                if rn >= 0 { loc = rn; }
                else if ent_home(e) >= 0 { loc = LOC_HOME_BASE + ent_home(e); }
                if loc >= 0 {
                    w64(rec, ci * 16, loc);
                    w64(rec, ci * 16 + 8, e);
                    ci = ci + 1;
                }
            }
            ei = ei + 1;
        }
        rl_merge_sort(rec, cnt);
        run_start : ., mut = 0;
        loop {
            if run_start >= cnt { break; }
            run_end : ., mut = run_start + 1;
            loop {
                if run_end >= cnt { break; }
                if r64(rec, run_end * 16) != r64(rec, run_start * 16) { break; }
                run_end = run_end + 1;
            }
            maxj : ., mut = -1;
            zi : ., mut = run_start;
            loop {
                if zi >= run_end { break; }
                e := r64(rec, zi * 16 + 8);
                if maxj >= 0 {
                    mej := r64(rec, maxj * 16 + 8);
                    if ent_live_end(mej) >= ent_live_start(e) {
                        if rule1_viol < RPT_MAX {
                            rl_report_rule1(func_i, r64(rec, zi * 16), mej, e);
                        }
                        rule1_viol = rule1_viol + 1;
                    }
                }
                if maxj < 0 || ent_live_end(e) > ent_live_end(r64(rec, maxj * 16 + 8)) {
                    maxj = zi;
                }
                zi = zi + 1;
            }
            run_start = run_end;
        }
    }

    // 规则 ②（框架）：寄存器驻留变量的读点活跃版本覆盖
    rule2_viol : ., mut = 0;
    if vc > 0 && ic > 0 {
        rule2_viol = rl_rule2_func(func_i, vs, vc, ist, ic, es, ec);
    }

    if rule1_viol > 0 || rule2_viol > 0 { return 1; }
    return 0;
}

// 全函数自检（O2 构建路径调用点）：0 = 全部一致；违反时打印诊断并返回违反
// 函数数。成功静默（自检通过 = 不打扰构建输出）。
fn regalloc_verify_all() -> int {
    bad : ., mut = 0;
    fi : ., mut = 0;
    loop {
        if fi >= g_ir_func_count { break; }
        bad = bad + verify_regalloc_consistency(fi);
        fi = fi + 1;
    }
    return bad;
}

// ===== Task 5 测试钩子（cir --check-regalloc 载体专用注入；真实构建路径
// 永不调用——注入只存在于 cir debug 分支，不触碰生产分配器行为）=====
// 各注入在全部函数范围找目标（不假设 func 0 = 被测 main——按 cwd 解析差异，
// 标准库函数可能并入 IR 使 func 序移位；找「首个满足形状的函数」保证确定性）。

// 注入 ①-home 组冲突：取两条不同 var 的共存条目 (e1,e2)，先撤销两 var 的
// 寄存器驻留（meta_remove_var——真实分配已覆盖时 append 伪造对会被既有对遮蔽，
// 撤销使位置判定退化到 home/栈 seam），再置 home = 同一槽 7 → 规则 ① home 组
// 违反。撤销的 var 无 home 条目（home=-1）不参与 sweep，无侧伤。
fn try_inject_home_conflict(func_i: int) -> int {
    es := entry_start(func_i);
    ec := entry_count(func_i);
    if ec < 2 { return 0; }
    e1i : ., mut = 0;
    loop {
        if e1i >= ec { break; }
        e1 := es + e1i;
        v1 := ent_var(e1);
        if v1 < 0 { e1i = e1i + 1; continue; }
        e2i : ., mut = e1i + 1;
        loop {
            if e2i >= ec { break; }
            e2 := es + e2i;
            v2 := ent_var(e2);
            if v1 != v2 && entries_coexist(func_i, e1, e2) != 0 {
                meta_remove_var(v1);
                meta_remove_var(v2);
                w32(g_ir_entries, e1 * ESZ_ENTRY + OFF_ENTRY_HOME, 7);
                w32(g_ir_entries, e2 * ESZ_ENTRY + OFF_ENTRY_HOME, 7);
                return 1;
            }
            e2i = e2i + 1;
        }
        e1i = e1i + 1;
    }
    return 0;
}

fn inject_home_conflict() -> int {
    fi : ., mut = 0;
    loop {
        if fi >= g_ir_func_count { break; }
        if try_inject_home_conflict(fi) != 0 { return 1; }
        fi = fi + 1;
    }
    return 0;
}

// ── 元数据写侧辅助（CAG 真实分配后注入以改写真实输出为手段——
//    append 首匹配语义会被既有对遮蔽，注入须原位改写/移除）──

// 返回 var 的 reg 字段偏移（g_opt_meta 内；-1 = 无对）。与 instr.cr
// get_reg_for_var 同布局（随迁后同进程——见判定区头注）。
fn meta_reg_pair_off(var_idx: int) -> int {
    mi : ., mut = 0;
    loop {
        if mi >= g_opt_meta_count { break; }
        mo := mi * OPT_META_STRIDE;
        if r32(g_opt_meta, mo) == OPT_KEY_REG_ASSIGN {
            cnt := r32(g_opt_meta, mo + 8);
            di : ., mut = 0;
            loop {
                if di >= cnt { break; }
                if r32(g_opt_meta, mo + 12 + di * 8) == var_idx {
                    return mo + 16 + di * 8;
                }
                di = di + 1;
            }
        }
        mi = mi + 1;
    }
    return -1;
}

// 强制 var → reg（已有对原位改写；无对追加——append 语义 = 首匹配生效，
// 无对时追加必然生效）
fn meta_set_reg(var_idx: int, reg: int) {
    po := meta_reg_pair_off(var_idx);
    if po >= 0 { w32(g_opt_meta, po, reg); return; }
    meta_append_reg_assign(var_idx, reg);
}

// 移除 var 的分配对（块内左移收拢；空块整体移除）——「撤销寄存器驻留」=
// 位置判定退化为 home/栈（entries home=-1 → 不参与规则① sweep，无侧伤）
fn meta_remove_var(var_idx: int) {
    mi : ., mut = 0;
    loop {
        if mi >= g_opt_meta_count { break; }
        mo := mi * OPT_META_STRIDE;
        if r32(g_opt_meta, mo) == OPT_KEY_REG_ASSIGN {
            cnt := r32(g_opt_meta, mo + 8);
            di : ., mut = 0;
            loop {
                if di >= cnt { break; }
                if r32(g_opt_meta, mo + 12 + di * 8) == var_idx {
                    // 移除第 di 对：后续对左移 8B（数据区 = count@+8 + 对@+12）
                    sh : ., mut = di;
                    loop { if sh + 1 >= cnt { break; }
                        w32(g_opt_meta, mo + 12 + sh * 8, r32(g_opt_meta, mo + 12 + (sh + 1) * 8));
                        w32(g_opt_meta, mo + 16 + sh * 8, r32(g_opt_meta, mo + 16 + (sh + 1) * 8));
                        sh = sh + 1; }
                    cnt = cnt - 1;
                    w32(g_opt_meta, mo + 8, cnt);
                    w32(g_opt_meta, mo + 4, 4 + cnt * 8);
                    if cnt == 0 {
                        // 空块整体移除：后续块左移一个 OPT_META_STRIDE
                        mj : ., mut = mi;
                        loop { if mj + 1 >= g_opt_meta_count { break; }
                            so := (mj + 1) * OPT_META_STRIDE;
                            kk : ., mut = 0;
                            loop { if kk >= OPT_META_STRIDE / 8 { break; }
                                w64(g_opt_meta, mj * OPT_META_STRIDE + kk * 8, r64(g_opt_meta, so + kk * 8));
                                kk = kk + 1; }
                            mj = mj + 1; }
                        g_opt_meta_count = g_opt_meta_count - 1;
                    }
                    return;
                }
                di = di + 1;
            }
        }
        mi = mi + 1;
    }
}

// REG_ASSIGN 对总数（--check-regalloc 看门狗行；rc>0 = 寄存器真实分配实证）
fn meta_reg_assign_total() -> int {
    tot : ., mut = 0;
    mi : ., mut = 0;
    loop {
        if mi >= g_opt_meta_count { break; }
        mo := mi * OPT_META_STRIDE;
        if r32(g_opt_meta, mo) == OPT_KEY_REG_ASSIGN { tot = tot + r32(g_opt_meta, mo + 8); }
        mi = mi + 1;
    }
    return tot;
}

// 追加一条 OPT_KEY_REG_ASSIGN 记录（格式同 alloc_registers 写侧；首个匹配即
// 生效——故伪造目标须是真实分配未覆盖的 var，后端 get_reg_for_var 同语义）
fn meta_append_reg_assign(var_idx: int, reg: int) {
    grow_opt_meta(g_opt_meta_count + 1);
    eo := g_opt_meta_count * OPT_META_STRIDE;
    store8(g_opt_meta, eo, 0); store8(g_opt_meta, eo + 1, 0);
    store8(g_opt_meta, eo + 2, 0); store8(g_opt_meta, eo + 3, 0);  // OPT_KEY_REG_ASSIGN=0
    dl : ., mut = 4 + 8;
    store8(g_opt_meta, eo + 4, dl % 256); store8(g_opt_meta, eo + 5, (dl / 256) % 256);
    store8(g_opt_meta, eo + 6, (dl / 65536) % 256); store8(g_opt_meta, eo + 7, (dl / 16777216) % 256);
    store8(g_opt_meta, eo + 8, 1); store8(g_opt_meta, eo + 9, 0);
    store8(g_opt_meta, eo + 10, 0); store8(g_opt_meta, eo + 11, 0);  // count = 1
    store8(g_opt_meta, eo + 12, var_idx % 256); store8(g_opt_meta, eo + 13, (var_idx / 256) % 256);
    store8(g_opt_meta, eo + 14, (var_idx / 65536) % 256); store8(g_opt_meta, eo + 15, (var_idx / 16777216) % 256);
    store8(g_opt_meta, eo + 16, reg % 256); store8(g_opt_meta, eo + 17, (reg / 256) % 256);
    store8(g_opt_meta, eo + 18, (reg / 65536) % 256); store8(g_opt_meta, eo + 19, (reg / 16777216) % 256);
    g_opt_meta_count = g_opt_meta_count + 1;
}

// 注入 ①-寄存器组冲突：找一对不同 var 的共存条目 (e1, e2)，把两 var 的
// REG_ASSIGN 原位改写为同一 reg 3（已有对改写 / 无对追加——真实分配覆盖与否
// 均确定生效；共存条目同组同寄存器 → 规则 ① 寄存器组违反）。
// 注入仅存在于 cir debug 分支（真实构建路径永不注入）。
fn try_inject_reg_conflict(func_i: int) -> int {
    es := entry_start(func_i);
    ec := entry_count(func_i);
    if ec < 2 { return 0; }
    e1i : ., mut = 0;
    loop {
        if e1i >= ec { break; }
        e1 := es + e1i;
        v1 := ent_var(e1);
        if v1 < 0 { e1i = e1i + 1; continue; }
        e2i : ., mut = e1i + 1;
        loop {
            if e2i >= ec { break; }
            e2 := es + e2i;
            v2 := ent_var(e2);
            if v1 != v2 && entries_coexist(func_i, e1, e2) != 0 {
                meta_set_reg(v1, 3);
                meta_set_reg(v2, 3);
                return 1;
            }
            e2i = e2i + 1;
        }
        e1i = e1i + 1;
    }
    return 0;
}

fn inject_reg_conflict() -> int {
    fi : ., mut = 0;
    loop {
        if fi >= g_ir_func_count { break; }
        if try_inject_reg_conflict(fi) != 0 { return 1; }
        fi = fi + 1;
    }
    return 0;
}

// 注入 ②-读点空洞：找 var——其最后一个版本条目（def ≥ 0 中 def 最大）
// live_end > def（定值后仍有读）——把该 var 置为寄存器驻留并把该版本 live_end
// 截断为 def → 其后的读点无活跃版本覆盖 → 规则 ② 违反。
// 真实分配下：目标 var 已被分配 → 保持其原 reg（规则① 零扰动）直接截断即红；
// 未分配（rc=0 时代/栈驻留 var）→ 强制 reg 3——先把与目标共存且已分配的 var
// 全部撤销（防强制 reg 引发规则① 侧伤；撤销 var 无位置参与 sweep，无新违反）。
fn try_inject_read_gap(func_i: int) -> int {
    vc := r64(g_ir_func_var_count, func_i * 8);
    vs := r64(g_ir_func_var_start, func_i * 8);
    es := entry_start(func_i);
    ec := entry_count(func_i);
    lv : ., mut = 0;
    loop {
        if lv >= vc { break; }
        gv := vs + lv;
        // 该 var 最后一条 def ≥ 0 条目（表内定值点升序 → 末条即 def 最大）
        last : ., mut = -1;
        ei : ., mut = 0;
        loop {
            if ei >= ec { break; }
            e := es + ei;
            if ent_var(e) == gv && ent_def(e) >= 0 { last = e; }
            ei = ei + 1;
        }
        if last >= 0 && ent_live_end(last) > ent_def(last) {
            if meta_reg_for_var(gv) < 0 {
                // 强制驻留路径：撤销与 gv 任何版本条目共存的已分配 var
                ej : ., mut = 0;
                loop {
                    if ej >= ec { break; }
                    e2 := es + ej;
                    v2 := ent_var(e2);
                    if v2 != gv && meta_reg_for_var(v2) >= 0 {
                        ek : ., mut = 0;
                        loop {
                            if ek >= ec { break; }
                            if ent_var(es + ek) == gv &&
                               entries_coexist(func_i, es + ek, e2) != 0 {
                                meta_remove_var(v2);
                                break;
                            }
                            ek = ek + 1;
                        }
                    }
                    ej = ej + 1;
                }
                meta_set_reg(gv, 3);
            }
            w32(g_ir_entries, last * ESZ_ENTRY + OFF_ENTRY_LE, ent_def(last));
            return 1;
        }
        lv = lv + 1;
    }
    return 0;
}

fn inject_read_gap() -> int {
    // 函数迭代序 = 1..n-1 再 0：优先注入非 func 0 目标（F1 回归前提——规则 ② 的
    // 坐标失明面只在 ist > 0 的函数上显形）。GC 批 2 后 _arena 等每函数首条
    // def 使 func 0 恒可注入——若仍从 0 扫起，注入恒落 main，非 func 0 面失守。
    fi : ., mut = 1;
    loop {
        if fi >= g_ir_func_count { break; }
        if try_inject_read_gap(fi) != 0 { return 1; }
        fi = fi + 1;
    }
    return try_inject_read_gap(0);
}

// ------------------------------------------------------------------
// Register allocation — CAG 上下文贪心（docs/regalloc-cache-mapping.md §五 定案）
// ------------------------------------------------------------------
// 语义：寄存器文件 = 缓存层、栈槽 = home 的映射实例（缓存语义条款 7）。
// 本实现 = 存在结构上 First Fit（指令序扫描 = CFG 退化实例）+ 上下文修正：
// 共存（窗口互斥）、region 生命周期（回边携带值整函数窗口）、调用点
// （callee-saved 专用——ABI 保留契约，判定 ④ 平凡满足）、使用次数/门控。
// 结果写 g_opt_meta 的 OPT_KEY_REG_ASSIGN 对（var_idx → 物理 reg）；同进程
// instr.cr g2_slot/get_reg_for_var 在发射时按对把 var 落寄存器（E2_REG_SLOT_BASE
// 正哨兵）——判定侧解析同布局同源消费（regalloc 移后端后无跨进程镜像）。
// 旧「负编码改写 IR 操作数」是过时设计（见判定区头注记），现 seam = meta 表
// + 后端查询。
//
// 分配粒度决策（var 级）：条目表（compute_entries）是版本级，但消费 seam 是
// var 级单位置——meta 每 var 一条对、后端按 var 无指令上下文查询（迁移前
// .ccr 同构传输，现 corearch 进程内自算）。版本级分配（同 var 不同版本不同
// 位置）在该 seam 不可表达（需逐指令
// 操作数改写 + 后端带指令上下文的槽解析，为未来升级点）。故分配粒度 = var
// 全窗口 [first_ref,last_ref]——该 var 各版本条目存在区间之并（版本按定值点
// 无缝切割，见 compute_entries）；判定按 var 投影到版本条目（衔接决策 b），
// 分配器将来升版本级时判定零改动。
//
// rc=0 缺陷根因（评审披露，本重写修复）：旧实现 free 遍（每次指令迭代前
// last_ref < ii 复位）+ reg_idx 单调不复用 + 循环末只把「末指令仍活跃」var 写
// meta → 实测 g_opt_meta 恒无 REG_ASSIGN 对 → 后端全栈发射（正确但零加速）。
// 本实现：活跃集合按窗口终点正确归还（末引用之后释放、同位置先 free 后分配，
// 允许寄存器复用）、全部已分配对函数末一次性落 meta。
//
// 门控（发射器路径审计——寄存器驻留 var 的每次读写必须走 BASE-aware 装载
// e2_ld/e2_st/e2_load_var；直接内存操作数/槽地址/双槽偏移发射在 reg 哨兵槽上
// 编码垃圾）：
//  - 类型门：TI_DEX / TI_DEX_S（XMM 内存路径 e2_sd_*/e2_sd_cvt）、TI_DYN
//    （16B 双槽 value+tag，e2_ld(o±8) 偏移错位）、TI_UNIT 不分配；
//  - IR_CONST 的 dest（e2_li 无 reg 槽分支）；
//  - IR_REF 的 s1（e2_lb 取 home 槽地址——地址泄漏 = 别名入口，必须留 home）；
//  - IR_I2F 的 s1（e2_sd_cvt 内存源操作数）；
//  - ti==TI_DEX/S 指令的引用 var（防御，类型门已覆盖）。
// 排除 var = 全窗口栈驻留（frame slot home 保留）。寄存器不足（>5 共存）时
// 静态放置失败 = 不放置（无动态驱逐代码、无 spill 指令）：无配方条目条款
// （memory-model-capability-lattice §5.3「必须有 home」）因从未放置而平凡满足
// ——判定 ③ 驱逐配对无事件、④ 调用点契约 = callee-saved 保留平凡成立。
// caller-saved 解锁（调用点失效 + 跨调用点 spill/重载）留注记下批（§五 谱系
// 调用点上下文项）：现仅用 callee-saved，调用点判定平凡真。
//
// region 生命周期上下文（回边携带值）：朴素文字窗口 [first_ref,last_ref] 在
// 含回边函数上不安全——循环携带值（读点文字序先于其重定值，如 cond 读 i 在
// i=i+1 前）跨回边存活，窗口止于末引用会把 reg 让给循环尾文字区间不交的 var
// → 定值污染（test_live_ranges LOOP_CARRY_SRC 语义锚）。判定：对每个回边
// span [label_pos, branch_pos]，var 在 span 内首个引用为读（非定值形式）→
// 携带 → 窗口扩至整函数。
// 条件定值健全化（复审 Critical，2026-09-06 修复）：def-form 首引用 ≠ 每轮
// 必刷新——「首引用为定值 ⇒ 不携带」只在定值无条件每轮执行时成立。定值点 d
// 位于 span 内条件区域（∃ BRANCH b ∈ [t0, d)，目标 label t ∈ (d, b0]——跳过
// d 后仍在 span 内继续循环）时，跳过路径上旧值跨回边存活（下轮读污染值，
// v_noz/conddef_repro3 确定性误编译，O2 专属）。此类定值按携带处理（窗口
// 扩至整函数）。另：dest/STORE-s1 定值若同指令自读（s1/s2 == 目标，读先于
// 写）→ 该读本身就是跨回边读 → 亦按携带（防御性统一，现 IR 未见此形态——
// x=x+1 的读在独立 BINARY 指令上，首引用已是读形式）。
// 残余近似：非 span 首引用读点 + 跨 span 复杂路径需真 CFG 活性（RegionCheck
// 图层 = docs/regalloc-cache-mapping.md §三 定案升级点，未接线；判定与分配器
// 同文字区间模型——条件定值携带语义的判定侧同步 = 该升级点前的一贯挂账，
// 回归语义锚 = test_live_ranges COND_DEF_CARRY 源，见报告 cag-report.md）。

fn label_pos_of(id: int, lab_id: string, lab_ps: string, n: int) -> int {
    i : ., mut = 0;
    loop {
        if i >= n { break; }
        if r64(lab_id, i * 8) == id { return r64(lab_ps, i * 8); }
        i = i + 1;
    }
    return -1;
}

fn alloc_registers() {
    if g_opt_level < 1 { return; }
    // v6 数据基础：存在区间表先行（尾部重建版本条目表——判定消费同源数据）
    compute_live_ranges();
    MAX_REGS : int = 5;
    // callee-saved 物理寄存器（rbx, r12-r15；x86 枚举号，e2_mov/e2_ld REX 编码）
    reg_phys : string, mut = alloc(5 * 8);
    w64(reg_phys, 0, 3); w64(reg_phys, 8, 12);
    w64(reg_phys, 16, 13); w64(reg_phys, 24, 14); w64(reg_phys, 32, 15);
    fi : ., mut = 0;
    loop {
        if fi >= g_ir_func_count { break; }
        ic := r64(g_ir_func_instr_count, fi * 8);
        ist := r64(g_ir_func_instr_start, fi * 8);
        vc := r64(g_ir_func_var_count, fi * 8);
        vs := r64(g_ir_func_var_start, fi * 8);
        pc := r64(g_ir_func_param_count, fi * 8);
        if vc <= 0 || ic <= 0 { fi = fi + 1; continue; }

        // ── 阶段 1：门控扫描（并行 hazard 标志）──
        haz_const : string, mut = alloc(vc * 8);   // IR_CONST dest（e2_li 写路径）
        haz_ref   : string, mut = alloc(vc * 8);   // IR_REF s1（槽地址泄漏）
        haz_i2f   : string, mut = alloc(vc * 8);   // IR_I2F s1（sd_cvt 内存源）
        haz_dyn   : string, mut = alloc(vc * 8);   // IR_DYN_*（16B 双槽布局）
        haz_dex   : string, mut = alloc(vc * 8);   // ti==TI_DEX/S 指令引用
        iz : ., mut = 0;
        loop {
            if iz >= vc { break; }
            w64(haz_const, iz * 8, 0); w64(haz_ref, iz * 8, 0); w64(haz_i2f, iz * 8, 0);
            w64(haz_dyn, iz * 8, 0); w64(haz_dex, iz * 8, 0);
            iz = iz + 1;
        }
        ii : ., mut = 0;
        loop {
            if ii >= ic { break; }
            inst := ist + ii;
            op := iri_op(inst);
            d := iri_dest(inst); s1 := iri_s1(inst); s2 := iri_s2(inst);
            if d >= vs && d < vs + vc {
                dl := d - vs;
                if op == IR_CONST { w64(haz_const, dl * 8, 1); }
                if op == IR_DYN_PACK || op == IR_DYN_TAG || op == IR_DYN_VAL ||
                   op == IR_DYN_DISPATCH { w64(haz_dyn, dl * 8, 1); }
            }
            if op == IR_REF && s1 >= vs && s1 < vs + vc { w64(haz_ref, (s1 - vs) * 8, 1); }
            if op == IR_I2F && s1 >= vs && s1 < vs + vc { w64(haz_i2f, (s1 - vs) * 8, 1); }
            if op == IR_DYN_PACK || op == IR_DYN_TAG || op == IR_DYN_VAL ||
               op == IR_DYN_DISPATCH {
                if s1 >= vs && s1 < vs + vc { w64(haz_dyn, (s1 - vs) * 8, 1); }
                if s2 >= vs && s2 < vs + vc { w64(haz_dyn, (s2 - vs) * 8, 1); }
            }
            tk := iri_tk(inst);
            if tk == TI_DEX || tk == TI_DEX_S {
                if d >= vs && d < vs + vc { w64(haz_dex, (d - vs) * 8, 1); }
                if s1 >= vs && s1 < vs + vc { w64(haz_dex, (s1 - vs) * 8, 1); }
                if s2 >= vs && s2 < vs + vc { w64(haz_dex, (s2 - vs) * 8, 1); }
            }
            ii = ii + 1;
        }

        // ── 阶段 2：回边探测 + 携带值标记（region 生命周期上下文）──
        ln : ., mut = 0;
        ii = 0;
        loop { if ii >= ic { break; }
            if iri_op(ist + ii) == IR_LABEL { if iri_s1(ist + ii) >= 0 { ln = ln + 1; } }
            ii = ii + 1;
        }
        lab_id : string, mut = alloc(ln * 8);
        lab_ps : string, mut = alloc(ln * 8);
        li : ., mut = 0;
        ii = 0;
        loop {
            if ii >= ic { break; }
            if iri_op(ist + ii) == IR_LABEL && iri_s1(ist + ii) >= 0 {
                w64(lab_id, li * 8, iri_s1(ist + ii));
                w64(lab_ps, li * 8, ii);
                li = li + 1;
            }
            ii = ii + 1;
        }
        // 回边 span 收集（16B {label_pos, branch_pos}；上限 = 指令数）
        bt : string, mut = alloc(ic * 16);
        bn : ., mut = 0;
        has_loop : ., mut = 0;
        ii = 0;
        loop {
            if ii >= ic { break; }
            inst := ist + ii;
            op := iri_op(inst);
            if op == IR_JUMP {
                tp := label_pos_of(iri_s1(inst), lab_id, lab_ps, ln);
                if tp >= 0 && tp < ii {
                    w64(bt, bn * 16, tp); w64(bt, bn * 16 + 8, ii);
                    bn = bn + 1; has_loop = 1;
                }
            } else if op == IR_BRANCH {
                tp := label_pos_of(iri_s2(inst), lab_id, lab_ps, ln);
                if tp >= 0 && tp < ii {
                    w64(bt, bn * 16, tp); w64(bt, bn * 16 + 8, ii);
                    bn = bn + 1; has_loop = 1;
                }
                tp = label_pos_of(iri_s3(inst), lab_id, lab_ps, ln);
                if tp >= 0 && tp < ii {
                    w64(bt, bn * 16, tp); w64(bt, bn * 16 + 8, ii);
                    bn = bn + 1; has_loop = 1;
                }
            }
            ii = ii + 1;
        }
        car : string, mut = alloc(vc * 8);
        iz = 0;
        loop { if iz >= vc { break; } w64(car, iz * 8, 0); iz = iz + 1; }
        if has_loop != 0 {
            // span 内逐指令扫：var 的 span 内首引用若为读形式 → 值跨回边存活
            // （携带）；定值形式（dest / STORE-s1）首引用且每轮必执行 → 每轮
            // 刷新，不携带。状态：0 未见 / 1 首引用 = 定值 / 2 首引用 = 读。
            // 条件定值健全化（评审 Critical）：首引用为定值 d 但 d 可被 span 内
            // 条件分支跳过（仍在 span 继续循环）→ 未必每轮刷新 → 同读形式按
            // 携带处理（差分标记 + 前缀累计见下）。
            st : string, mut = alloc(vc * 8);
            st_def : string, mut = alloc(vc * 8);      // state-1 var 的定值位置
            skp : string, mut = alloc((ic + 2) * 8);   // 可跳过位置差分（span 局部序）
            bi : ., mut = 0;
            loop {
                if bi >= bn { break; }
                t0 := r64(bt, bi * 16);
                b0 := r64(bt, bi * 16 + 8);
                iz = 0;
                loop {
                    if iz >= vc { break; }
                    w64(st, iz * 8, 0);
                    w64(st_def, iz * 8, -1);
                    iz = iz + 1;
                }
                pp : ., mut = t0;
                loop {
                    if pp > b0 { break; }
                    inst := ist + pp;
                    op := iri_op(inst);
                    d := iri_dest(inst); s1 := iri_s1(inst); s2 := iri_s2(inst);
                    if d >= vs && d < vs + vc {
                        lvd := d - vs;
                        if r64(st, lvd * 8) == 0 {
                            // dest 定值同指令自读（s1/s2 == d）：读先于写，该读
                            // 可能取上一轮值 → 按读首引用（携带）处理
                            if s1 == d || s2 == d {
                                w64(st, lvd * 8, 2);
                                w64(car, lvd * 8, 1);
                            } else {
                                w64(st, lvd * 8, 1);
                                w64(st_def, lvd * 8, pp);
                            }
                        }
                    }
                    if op == IR_STORE && s1 >= vs && s1 < vs + vc {
                        lvs := s1 - vs;
                        if r64(st, lvs * 8) == 0 {
                            if s2 == s1 {
                                w64(st, lvs * 8, 2);
                                w64(car, lvs * 8, 1);
                            } else {
                                w64(st, lvs * 8, 1);
                                w64(st_def, lvs * 8, pp);
                            }
                        }
                    }
                    if s1 >= vs && s1 < vs + vc && op != IR_STORE {
                        lv1 := s1 - vs;
                        if r64(st, lv1 * 8) == 0 {
                            w64(st, lv1 * 8, 2);
                            w64(car, lv1 * 8, 1);
                        }
                    }
                    if s2 >= vs && s2 < vs + vc {
                        lv2 := s2 - vs;
                        if r64(st, lv2 * 8) == 0 {
                            w64(st, lv2 * 8, 2);
                            w64(car, lv2 * 8, 1);
                        }
                    }
                    pp = pp + 1;
                }
                // 条件定值健全化——差分标记：BRANCH（pp）的 forward 目标
                // t ∈ (pp, b0] ⇒ 位置 (pp, t) 可被跳过且循环仍继续（区间
                // [pp+1, t−1] 覆盖 +1，终点 t 处 −1）；前缀累计 > 0 ⟺ 该位置
                // 落在某可跳过区域内。回跳/外跳目标（≤ pp 或 > b0）不构成
                // 「跳过仍继续循环」，不计。
                // 第二轮健全化（复审 Critical 残留）：if-else 布局
                //   BRANCH c, L_then, L_else; L_then: A; JUMP L_merge;
                //   L_else: B; JUMP L_merge;
                // 中 else 体 B 被 then 尾无条件 JUMP 结构性跳过——B 内定值
                // 正落在 BRANCH 自身 else 目标的标号处（区间 [pp+1, t−1]
                // 不含终点 t），首轮只扫 IR_BRANCH 漏 IR_JUMP → B 内 def 判
                // 「每轮必执行」→ 同寄存器污染。对 span 内 forward IR_JUMP
                // (pp→t) 同样生成 [pp+1, t−1] 差分：跳过仍继续循环的路径
                // 等价（continue 前向形态同理；回跳 continue/break 外跳因
                // 目标 ≤ pp 或 > b0 不计）。over-mark 只损利用率、方向安全。
                zz : ., mut = 0;
                spn := b0 - t0 + 1;
                loop { if zz >= spn { break; } w64(skp, zz * 8, 0); zz = zz + 1; }
                pp = t0;
                loop {
                    if pp > b0 { break; }
                    if iri_op(ist + pp) == IR_BRANCH {
                        t2 := label_pos_of(iri_s2(ist + pp), lab_id, lab_ps, ln);
                        t3 := label_pos_of(iri_s3(ist + pp), lab_id, lab_ps, ln);
                        if t2 > pp && t2 <= b0 {
                            w64(skp, (pp + 1 - t0) * 8, r64(skp, (pp + 1 - t0) * 8) + 1);
                            w64(skp, (t2 - t0) * 8, r64(skp, (t2 - t0) * 8) - 1);
                        }
                        if t3 > pp && t3 <= b0 {
                            w64(skp, (pp + 1 - t0) * 8, r64(skp, (pp + 1 - t0) * 8) + 1);
                            w64(skp, (t3 - t0) * 8, r64(skp, (t3 - t0) * 8) - 1);
                        }
                    } else if iri_op(ist + pp) == IR_JUMP {
                        t1 := label_pos_of(iri_s1(ist + pp), lab_id, lab_ps, ln);
                        if t1 > pp && t1 <= b0 {
                            w64(skp, (pp + 1 - t0) * 8, r64(skp, (pp + 1 - t0) * 8) + 1);
                            w64(skp, (t1 - t0) * 8, r64(skp, (t1 - t0) * 8) - 1);
                        }
                    }
                    pp = pp + 1;
                }
                // 前缀累计：skp[p−t0] > 0 ⟺ 位置 p 可被某条件分支跳过
                acc : ., mut = 0;
                pp = t0;
                loop {
                    if pp > b0 { break; }
                    acc = acc + r64(skp, (pp - t0) * 8);
                    if acc != 0 { w64(skp, (pp - t0) * 8, 1); }
                    else { w64(skp, (pp - t0) * 8, 0); }
                    pp = pp + 1;
                }
                // state-1（首引用 = 定值）var：定值点可被跳过 → 条件定值，
                // 每轮未必刷新 → 旧值跨回边存活 → 携带（窗口扩至整函数）
                iz = 0;
                loop {
                    if iz >= vc { break; }
                    if r64(st, iz * 8) == 1 {
                        dd := r64(st_def, iz * 8);
                        if dd >= t0 && r64(skp, (dd - t0) * 8) != 0 {
                            w64(car, iz * 8, 1);
                        }
                    }
                    iz = iz + 1;
                }
                bi = bi + 1;
            }
        }

        // ── 阶段 3：候选构建（窗口 = [first_ref,last_ref] + 上下文修正）──
        var_reg : string, mut = alloc(vc * 8);  // 活跃集：函数内 var → reg 序 (0..4)
        var_end : string, mut = alloc(vc * 8);  // 活跃集窗口终点（free 判据——
                                              // 携带值扩窗后 ≠ live_last，须存）
        var_asg : string, mut = alloc(vc * 8);  // 终分配：函数内 var → 物理 reg
        reg_occ : string, mut = alloc(MAX_REGS * 8);
        cand_st : string, mut = alloc(vc * 8);
        cand_en : string, mut = alloc(vc * 8);
        cand_lv : string, mut = alloc(vc * 8);
        lv : ., mut = 0;
        loop { if lv >= vc { break; }
            w64(var_reg, lv * 8, -1); w64(var_end, lv * 8, 0); w64(var_asg, lv * 8, -1);
            lv = lv + 1;
        }
        lv = 0;
        loop { if lv >= MAX_REGS { break; } w64(reg_occ, lv * 8, -1); lv = lv + 1; }
        cc : ., mut = 0;
        lv = 0;
        loop {
            if lv >= vc { break; }
            gv := vs + lv;
            f := live_first(fi, gv);
            l := live_last(fi, gv);
            if f < 0 || l <= f { lv = lv + 1; continue; }  // 未用 / 单指令引用
            ty := irv_type(gv);
            if ty == TI_DEX || ty == TI_DEX_S || ty == TI_DYN || ty == TI_UNIT {
                lv = lv + 1; continue;
            }
            if r64(haz_const, lv * 8) != 0 || r64(haz_ref, lv * 8) != 0 ||
               r64(haz_i2f, lv * 8) != 0 || r64(haz_dyn, lv * 8) != 0 ||
               r64(haz_dex, lv * 8) != 0 {
                lv = lv + 1; continue;
            }
            st : ., mut = f;
            en : ., mut = l;
            if lv < pc { st = 0; }                       // 参数入口装载 → 窗口自函数头
            if r64(car, lv * 8) != 0 { st = 0; en = ic - 1; }  // 携带值 → 整函数
            w64(cand_st, cc * 8, st);
            w64(cand_en, cc * 8, en);
            w64(cand_lv, cc * 8, lv);
            cc = cc + 1;
            lv = lv + 1;
        }
        // 候选按 (start, lv) 稳定升序（插入排序；起点 = 指令位置，C ≤ vc 小集）
        ci2 : ., mut = 1;
        loop {
            if ci2 >= cc { break; }
            ks := r64(cand_st, ci2 * 8);
            kl := r64(cand_lv, ci2 * 8);
            ke := r64(cand_en, ci2 * 8);
            jj : ., mut = ci2;
            loop {
                if jj <= 0 { break; }
                pj := jj - 1;
                ps := r64(cand_st, pj * 8);
                pl := r64(cand_lv, pj * 8);
                if ps < ks || (ps == ks && pl < kl) { break; }
                w64(cand_st, jj * 8, ps);
                w64(cand_en, jj * 8, r64(cand_en, pj * 8));
                w64(cand_lv, jj * 8, pl);
                jj = jj - 1;
            }
            w64(cand_st, jj * 8, ks);
            w64(cand_en, jj * 8, ke);
            w64(cand_lv, jj * 8, kl);
            ci2 = ci2 + 1;
        }

        // ── 阶段 4：位置扫描 First Fit（同位置先 free 后分配）──
        ci : ., mut = 0;
        p : ., mut = 0;
        loop {
            if p >= ic { break; }
            // free：窗口终点（分配时记入 var_end；携带值扩窗 ≠ live_last）已过 →
            // 归还寄存器。rc=0 根因修复点：free 发生在末引用之后、寄存器按窗口
            // 终点正确复用（旧实现 free 后 meta 收集丢失 + reg 序单调不复用）。
            lv2 : ., mut = 0;
            loop {
                if lv2 >= vc { break; }
                rr := r64(var_reg, lv2 * 8);
                if rr >= 0 && r64(var_end, lv2 * 8) < p {
                    w64(var_reg, lv2 * 8, -1);
                    w64(reg_occ, rr * 8, -1);
                }
                lv2 = lv2 + 1;
            }
            // assign：起点 == p 的候选（窗口终点 = p−1 的 var 已先 free → 可复用
            // 同寄存器；终点恰 = p 的 var 仍活跃于 p，不释放——同指令共存条目
            // 不得同寄存器）
            loop {
                if ci >= cc { break; }
                if r64(cand_st, ci * 8) != p { break; }
                lvv := r64(cand_lv, ci * 8);
                eend := r64(cand_en, ci * 8);
                ci = ci + 1;
                rj : ., mut = 0;
                tk : ., mut = -1;
                loop {
                    if rj >= MAX_REGS { break; }
                    if r64(reg_occ, rj * 8) < 0 { tk = rj; break; }
                    rj = rj + 1;
                }
                if tk >= 0 {
                    w64(var_reg, lvv * 8, tk);
                    w64(var_end, lvv * 8, eend);
                    w64(reg_occ, tk * 8, lvv);
                    w64(var_asg, lvv * 8, r64(reg_phys, tk * 8));
                }
            }
            p = p + 1;
        }

        // ── 阶段 5：终分配写 g_opt_meta ──
        // 块格式（ast.cr OPT_META_STRIDE=64 = 头 8B + 数据 ≤56B）：每块 ≤5 对
        // （data_len = 4 + n×8 ≤ 44；ccr 加载器边界校验 md_len ≤ STRIDE−8）——
        // 分配对数超过 5 时按 5 切块多块拼接（reader/get_reg_for_var 全块扫描，
        // 首匹配生效；同 var 恒在同一块内 1 对，无跨块遮蔽问题）。
        // 修复前只收「末指令仍活跃」var → 恒空（rc=0）；现写全部已分配对。
        rc : ., mut = 0;
        lv = 0;
        loop { if lv >= vc { break; }
            if r64(var_asg, lv * 8) >= 0 { rc = rc + 1; }
            lv = lv + 1;
        }
        if rc > 0 {
            // 预收集已分配 var（函数内下标）——切块时按序取
            asg_lv : string, mut = alloc(rc * 8);
            ai : ., mut = 0;
            lv = 0;
            loop { if lv >= vc { break; }
                if r64(var_asg, lv * 8) >= 0 {
                    w64(asg_lv, ai * 8, lv);
                    ai = ai + 1;
                }
                lv = lv + 1;
            }
            pb : ., mut = 0;
            loop {
                if pb >= rc { break; }
                n_in : ., mut = rc - pb;
                if n_in > 5 { n_in = 5; }
                ei : ., mut = g_opt_meta_count;
                grow_opt_meta(ei + 1);
                // Write key(u32) + data_len(u32) header using store8
                eo := ei * OPT_META_STRIDE;
                store8(g_opt_meta, eo, 0); store8(g_opt_meta, eo+1, 0);
                store8(g_opt_meta, eo+2, 0); store8(g_opt_meta, eo+3, 0);  // OPT_KEY_REG_ASSIGN=0
                dl : ., mut = 4 + n_in * 8;
                store8(g_opt_meta, eo+4, dl%256); store8(g_opt_meta, eo+5, (dl/256)%256);
                store8(g_opt_meta, eo+6, (dl/65536)%256); store8(g_opt_meta, eo+7, (dl/16777216)%256);
                // Write count
                store8(g_opt_meta, eo+8, n_in%256); store8(g_opt_meta, eo+9, (n_in/256)%256);
                store8(g_opt_meta, eo+10, (n_in/65536)%256); store8(g_opt_meta, eo+11, (n_in/16777216)%256);
                // Write pairs: [var_idx(u32), reg(u32)]...（对 @+12 起，8B 步进）
                di : ., mut = 12;
                pi : ., mut = 0;
                loop {
                    if pi >= n_in { break; }
                    lvp := r64(asg_lv, (pb + pi) * 8);
                    vw := vs + lvp;
                    rn := r64(var_asg, lvp * 8);
                    store8(g_opt_meta, eo+di, vw%256); store8(g_opt_meta, eo+di+1, (vw/256)%256);
                    store8(g_opt_meta, eo+di+2, (vw/65536)%256); store8(g_opt_meta, eo+di+3, (vw/16777216)%256);
                    store8(g_opt_meta, eo+di+4, rn%256); store8(g_opt_meta, eo+di+5, (rn/256)%256);
                    store8(g_opt_meta, eo+di+6, (rn/65536)%256); store8(g_opt_meta, eo+di+7, (rn/16777216)%256);
                    di = di + 8;
                    pi = pi + 1;
                }
                g_opt_meta_count = ei + 1;
                pb = pb + n_in;
            }
        }
        fi = fi + 1;
    }
}
