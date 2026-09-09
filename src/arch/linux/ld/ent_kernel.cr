// === ent_kernel.cr ===
// corearch 范式无关内核——语义判定引擎 + 条目/区间数据面（内核抽取 Task 1，
// 2026-09-10 自 regalloc.cr 逐函数纯搬——函数体零改动；计划：
// docs/superpowers/plans/2026-09-10-corearch-kernel-extraction.md）。
// 范式无关：不读值内容、无寄存器名/ABI 常量/编码知识——判定作用于条目类别
// （位置 + 配方 + 存在）；资源域（寄存器/槽的代数）= 实例侧声明。
// 机器侧（x86 实例）= regalloc.cr：CAG alloc_registers + g_opt_meta 写入
// （meta_set/append/remove/meta_reg_assign_total）+ 注入钩子（cir debug 测试通道）。
// 同 concat 单编译单元（corearch concat）互调——跨文件引用无需声明头。
// B 通道中立化（内核完备 Task 3，2026-09-10）：判定输入真相源 = 位置登记表
// {entry→loc}（kern_loc_assign/clear/of——实例写 g_opt_meta 后经 kern API 成对
// 登记/清除——双份同步责任在实例）；本文件读通道 = 登记表（meta_reg_for_var
// = 登记表查询——var 级驻留，历史名保留——调用点 = rl_rule2_func + regalloc.cr
// 注入探针）。g_opt_meta 本身 = 实例 emit 面私有结构（instr.cr get_reg_for_var
// 消费），本文件零代码引用（中立性 guard B 组绿判据）。
//
// 本文件函数集 = 内核接口面（现名即 API——不加 kern_ 包装层，YAGNI 裁决，
// 内核抽取 Task 3）。内核 API 面按职责族：
//   数据面  ：grow_live_ranges/live_range_slot/live_first/live_last/compute_live_ranges
//            grow_entries/grow_func_entry_meta/ent_off/ent_var/ent_def/ent_live_start/
//            ent_live_end/ent_home/ent_flags/entry_start/entry_count/compute_entries
//   位置登记：kern_loc_assign/kern_loc_clear/kern_loc_of（{entry→loc} 不透明位置
//            登记表——判定输入统一形态，实例经 API 写入；loc_registry_reset =
//            条目重建同点清表）
//   判定服务：entries_coexist/coexist_version_conflicts/coexist_home_conflicts/
//            verify_regalloc_consistency/regalloc_verify_all（规则①②合成——
//            regalloc_verify_all = 设计 spec §3.3 输出 API kern_verify_all 的
//            现名，注记见函数位；违反诊断措辞 = 中性文本层（Task 4））+ 判定
//            诊断（rl_rec_lt/rl_merge_sort/rl_print_loc/rl_func_name/rl_report_*）
//   诊断通道：dump_entries_summary/dump_coexist_summary（cir 调试 dump 载体）
//            + ir_op_kind_name（--dump-entries kind= 定值种类名，Task 2 迁入）
// 实例侧（x86 实例机器函数）= regalloc.cr：CAG alloc_registers + g_opt_meta 写入
// （meta_set/append/remove/meta_reg_assign_total）+ 注入钩子（cir debug 测试通道）
// ——写入点成对调 kern 登记/清除（双份同步纪律，Task 3 配对点 = phase 5 +
// meta_set_reg/meta_remove_var，见 regalloc.cr 注记）。
// 注册契约最小面（2026-09-10 内核抽取 Task 3 + 内核完备 Task 4）：实例声明表
// g_instance_decl（corearch.cr 声明——corearch 侧数据）——行 = {id, name
// str_idx, opt_min, opt_max, allow_table, allow_link, needs_alloc, needs_verify,
// needs_eviction, needs_call_sites} × n（x86 实例 + 表模式路径声明，行数据 = 0/0）；
// needs_eviction/needs_call_sites = 判定③④ 的**形式声明字段**——引擎不实现
// （用户裁决，设计 spec §3.2：静态放置无驱逐事件 + callee-saved 平凡满足；
// 字段存在 + 文档即契约完整性，needs_* = 1 的未来实例出现时 = 引擎扩展的
// 注册契约演进点）；引导 = corearch_main 读 flag → instance_select() 查表选
// 实例 → 决策逐点查询活动实例行（拒绝门/表管线门/O2 职责门）。判定输入
// 中立化（B 通道——位置登记表 + home 字段独立遍，2026-09-10 完成，见登记表
// 节）/ 双向契约输出面（kern_verify_all 现名即 API 注记）/ home 回填生产 =
// 蓝图后续步骤（范围克制）。
// 区头注随搬逐字保留（其中「判定区」「alloc 区」互指现分居本文件/regalloc.cr）。
// ------------------------------------------------------------------
// v6 数据基础：存在区间推导（NOD 节点序 [first_ref, last_ref]——节点序 =
// 指令序 index-aligned（F5），坐标语义同前；A 通道中立化 2026-09-10）
// ------------------------------------------------------------------
// compute_live_ranges 填充全局 g_ir_live_ranges（表全局声明在 globals.cr），
// alloc_registers 改读本表——与原内联 iv_buf 构建逻辑逐行一致（行为不变）。
// 表布局：每函数一段，段内每「函数内 var」16B（first_ref/last_ref 各 8B，
// 函数内节点序 = 节点窗口内坐标）；func_i 段起始 = Σ var_count[0..func_i)，
// 不乘固定稠密系数（live_range_slot 即该前缀累计；16B 记录 + grow 风格同
// g_ir_slice_lens）。

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
// 构建（:210-241）：逐函数逐节点扫描（节点字段读 = 对象面 nod_*——A 通道
// 中立化 2026-09-10，同 index 数值与线性流时代 iri_* 逐字节同），dest/s1/s2
// 落在 [vs, vs+vc) 内则扩展 [first_ref,last_ref]（首见写 first，之后推进
// last）；未使用 var 两条均为 -1。
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
    // 逐函数逐节点扫描：段偏移 = 运行中前缀累计（与 live_range_slot 前缀一致）。
    // 函数窗口源 = g_ir_func_instr_start/count——值 = NOD 节点坐标（v7 节点序
    // = 指令序 index-aligned，窗口 = 函数节点范围 [start, start+count)；
    // loader 侧 REG root span 派生、构建侧区域快照，双进程同值——F3 注记，
    // A 通道中立化 2026-09-10）。节点字段读全走对象面 nod_*（同 index——
    // 数值与线性流时代 iri_* 逐字节同，见语义对象节）。
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
                d := nod_dest(inst); s1 := nod_s1(inst); s2 := nod_s2(inst);
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
    if func_i == 0 {
        g_entry_count = 0;
        // 条目表整代重建——旧登记全失效（B 通道中立化 2026-09-10：登记 =
        // 本代条目语义——新代条目复用旧槽位，不清 = 陈旧 loc 误读；实例登记
        // 只发生在本代 compute 完成之后 = phase 5/注入，时序安全）
        loc_registry_reset();
    }
    // 函数窗口源同 compute_live_ranges（F3 注记，2026-09-10）：ist/ic =
    // g_ir_func_instr_start/count——值 = NOD 节点坐标（节点序 = 指令序
    // index-aligned）；节点字段读 = 对象面 nod_*（A 通道中立化）。
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
            op := nod_op(inst);
            dv : ., mut = -1;
            if op == IR_STORE {
                s1 := nod_s1(inst);
                if s1 >= vs && s1 < vs + vc { dv = s1; }
            } else if op != IR_STORE_INDEX_VAR && op != IR_STORE_PTR && op != IR_DYN_DISPATCH {
                d := nod_dest(inst);
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

// （2026-09-10 内核抽取 Task 2 自 regalloc.cr 迁入——本函数唯一调用方 =
// dump_entries_summary（--dump-entries kind= 字段映射）；机器侧零引用。
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

// --dump-entries 调试通道输出（cir 命令调用，Task 2 测试载体）：
// 每函数一段、一行一条目；坐标 = 全局指令序/全局变量索引（与表内一致），
// v = 组内版本序（1-based），kind = 定值指令种类（def≥0 = producer opcode
// 名，GC 批 2 后不再止于 ALLOC/STORE；def=-1 → "-"）。
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
                // d = 定值点 = 全局节点坐标（A 通道中立化：对象面 nod_op 同
                // index——线性流读点 F2 清，2026-09-10）
                print(" kind="); print(ir_op_kind_name(nod_op(d)));
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
// ===== v6 Task 5：判定消费最小闭环（一致性自检——共 specs/
// regalloc-consistency.corespec 规约）=====
// 分配结果：实例侧 g_opt_meta 的 OPT_KEY_REG_ASSIGN 对（var_idx → 位置——x86
// 寄存器号；instr.cr g2_slot/get_reg_for_var 发射时按对落寄存器 = emit 面）。
// 判定消费 = 位置登记表（B 通道中立化 2026-09-10：实例写 g_opt_meta 后经
// kern_loc_* 登记——判定经登记表消费「实际编码的分配」的一致视图——本文件
// 零 g_opt_meta 代码引用，布局知识留实例侧）。
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
// 文档（spec/regalloc-consistency.corespec R3/R4——文件名引用保留注记）。
// ③④ 形式声明（内核完备 Task 4，2026-09-10）：判定引擎不实现（用户裁决，
// 设计 spec §3.2 引用）——能力承载 = 实例声明表 needs_eviction/
// needs_call_sites 字段（corearch.cr g_instance_decl 行扩展，x86/表模式路径
// 行 = {0, 0}——静态放置无驱逐事件 + callee-saved 平凡满足）。

// 规则违反诊断打印上限（rl_report_rule1/2 防病理刷屏，计数不封顶）——唯一
// 使用方 = 本文件判定函数（rl_rule2_func/verify_regalloc_consistency）；机器
// 侧零引用（2026-09-10 内核抽取 Task 2 自 regalloc.cr 迁入）。
RPT_MAX : int = 8;              // 规则违反诊断每函数每规则打印上限（计数不封顶）

// ===== 位置登记表（B 通道中立化——内核完备 Task 3，2026-09-10）=====
// 判定输入 = 实例分配结果的统一形态——{entry → loc} 登记。loc = 不透明整数：
// 内核只做相等/排序/同值互斥，无寄存器号/域分类/编码合成概念（设计 spec
// §2.2 修正——home 面 = 条目 home 字段独立遍，不复用合成，见 verify 规则①）。
// 写侧 = 实例（alloc_registers phase 5 + 注入钩子——写 g_opt_meta 后经本 API
// 成对登记/清除——双份同步责任在实例，配对点注记见 regalloc.cr）；读侧 =
// 判定（规则① 登记表遍 kern_loc_of + meta_reg_for_var var 级驻留查询）。
// 生命周期：条目表整代重建（compute_entries func_i==0）使全部登记失效 → 同点
// loc_registry_reset()。表 = 每条目 4B 槽（entry_idx * 4；-1 = 未登记），按
// 条目下标 O(1) 寻址（读走 buf_read_i32 带符号扩展——w32/buf_read_i32 同
// ent_* 族约定，见 ent_var 注）。
// 命名注记（Task 4 措辞批——Task 3 评审 Minor 2 候选）：旧名 g_loc_reg_buf
// 的 "reg" 缩写 = 寄存器时代措辞（内核零经典概念原则）——改全词 registry
// （登记表——与 loc_registry_reset 命名族一致；registry 无寄存器语义）。
g_loc_registry_buf : string, mut;   // 登记表缓冲（4B/槽——槽 e = 条目 e 的 loc 或 -1）
g_loc_registry_cap : int, mut;      // 登记表容量（槽数）

fn loc_registry_reset() {
    // 条目重建点调用（compute_entries func_i==0）——已登记区整清 -1
    // （O(cap) 一次/代；新增长槽已在 kern_loc_assign -1 初始化）
    zi : ., mut = 0;
    loop {
        if zi >= g_loc_registry_cap { break; }
        w32(g_loc_registry_buf, zi * 4, -1);
        zi = zi + 1;
    }
}

fn kern_loc_assign(entry_idx: int, loc: int) {
    if entry_idx < 0 { return; }
    if entry_idx >= g_loc_registry_cap {
        nc : ., mut = g_loc_registry_cap * 2;
        if nc < 64 { nc = 64; }
        if nc <= entry_idx { nc = entry_idx + 64; }
        nb := alloc(nc * 4);
        _dyncpy(g_loc_registry_buf, g_loc_registry_cap * 4, nb);
        zi : ., mut = g_loc_registry_cap;
        loop {
            if zi >= nc { break; }
            w32(nb, zi * 4, -1);   // 新槽 -1 初始化（未登记 = -1 哨兵）
            zi = zi + 1;
        }
        g_loc_registry_buf = nb;
        g_loc_registry_cap = nc;
    }
    w32(g_loc_registry_buf, entry_idx * 4, loc);
}

fn kern_loc_clear(entry_idx: int) {
    if entry_idx < 0 || entry_idx >= g_loc_registry_cap { return; }
    w32(g_loc_registry_buf, entry_idx * 4, -1);
}

fn kern_loc_of(entry_idx: int) -> int {
    if entry_idx < 0 || entry_idx >= g_loc_registry_cap { return -1; }
    return buf_read_i32(g_loc_registry_buf, entry_idx * 4);
}

// var 级驻留查询（判定读通道——B 通道中立化 2026-09-10 函数体等价改写：旧 =
// 直读 g_opt_meta 实例布局 → 现 = 登记表查询——kern_loc_of 逐条目）。var 级
// 单位置分配（regalloc.cr 分配粒度决策）⇒ 同 var 全版本条目同 loc 登记——
// 任一已登记条目 = 驻留、loc = 该条目 loc（与旧投影语义精确等价：var 分配
// ⇔ 全条目登记，配对点见 regalloc.cr phase 5 注记）。历史函数名保留（现名
// 即 API）：调用点 = rl_rule2_func 驻留过滤 + regalloc.cr 注入探针
// try_inject_read_gap（探针读同一内核函数 = 经登记表读——判定与探针单真源，
// 注入路径配对保持登记与 g_opt_meta 同步，红路径测试 = test_live_ranges
// check_regalloc_violations/read_gap_nonfunc0）。
// 窗口搜索注记：var 的条目只存在于所属函数的条目段——先按 var 窗口定位函数
// 再扫该段（避免全表扫描；与 rl_rule2_func 既有 per-var 条目收集同界）。
fn meta_reg_for_var(var_idx: int) -> int {
    fi : ., mut = 0;
    loop {
        if fi >= g_ir_func_count { break; }
        vs := r64(g_ir_func_var_start, fi * 8);
        vc := r64(g_ir_func_var_count, fi * 8);
        if var_idx >= vs && var_idx < vs + vc {
            es := entry_start(fi);
            ec := entry_count(fi);
            ei : ., mut = 0;
            loop {
                if ei >= ec { break; }
                e := es + ei;
                if ent_var(e) == var_idx {
                    loc := kern_loc_of(e);
                    if loc >= 0 { return loc; }
                }
                ei = ei + 1;
            }
            return -1;   // 窗口内无登记条目 = 非驻留
        }
        fi = fi + 1;
    }
    return -1;   // 不在任何函数 var 窗口（全局 var 等）——恒非驻留
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

// 打印位置值（Task 4 措辞中性化——不透明 loc 直印，去 "reg N"/"home slot N"
// 分类措辞：值域分类 = 实例事务，内核只印不透明整数）。规则① 两遍（登记表遍/
// 条目 home 字段遍）= 两条独立同值互斥遍（B 通道中立化 2026-09-10）——报告
// 格式相同、遍来源不印（Task 3 遍来源标记参数 = 仅诊断措辞面，Task 4 随分类
// 措辞同撤）；判据只消费规则号/条目/loc 值，诊断可读性由 entries/var/区间/
// loc 全量信息承载。无域偏移合成。
fn rl_print_loc(loc: int) {
    print("loc "); print(int_str(loc));
}

fn rl_func_name(fi: int) {
    print("func "); print(int_str(fi)); print(" (");
    print(istr_get(r64(g_ir_func_name_idx, fi * 8))); print(")");
}

// 规则 ① 违反诊断（打印上限 RPT_MAX 防病理刷屏，计数不封顶）。
// 前缀措辞中性化（Task 4 输出面批）：旧前缀 "regalloc-consistency" = x86 时代
// 检查名——改检查域语义名 "entry-consistency"（条目版本表一致性——规则①
// 同值互斥 + 规则② 读覆盖）；spec 文件名引用保留于本文件判定区头注
// （spec/regalloc-consistency.corespec R3/R4——规约文档名不变）。
fn rl_report_rule1(func_i: int, loc: int, e1: int, e2: int) {
    print("entry-consistency: "); rl_func_name(func_i);
    print(": rule 1 violation: entries "); print(int_str(e1));
    print(" (var "); print(int_str(ent_var(e1))); print(") and "); print(int_str(e2));
    print(" (var "); print(int_str(ent_var(e2))); print(") both at ");
    rl_print_loc(loc);
    print(", coexist ["); print(int_str(ent_live_start(e1))); print("..");
    print(int_str(ent_live_end(e1))); print("] x ["); print(int_str(ent_live_start(e2)));
    print(".."); print(int_str(ent_live_end(e2))); println("]");
}

// 规则① 同值互斥遍（归并段扫——sweep 门禁）：rec = {loc:8, entry:8} 记录按
// (loc, live_start) 归并排序（rl_merge_sort）——同 loc 连续段内维持最大
// live_end：max_end ≥ 当前 ls ⟹ 区间相交 = 违反（rl_report_rule1 报告）。
// cap_base = 前遍已打印数——RPT_MAX 按规则合并封顶（两遍共享 = 与单遍合成
// 打印同界；Task 3 遍来源标记参数随 Task 4 措辞批同撤——两遍同报告格式）。
fn rl_rule1_sweep(func_i: int, rec: string, cnt: int, cap_base: int) -> int {
    viol : ., mut = 0;
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
                    if cap_base + viol < RPT_MAX {
                        rl_report_rule1(func_i, r64(rec, zi * 16), mej, e);
                    }
                    viol = viol + 1;
                }
            }
            if maxj < 0 || ent_live_end(e) > ent_live_end(r64(rec, maxj * 16 + 8)) {
                maxj = zi;
            }
            zi = zi + 1;
        }
        run_start = run_end;
    }
    return viol;
}

// 规则 ② 违反诊断（前缀中性化同 rl_report_rule1——"entry-consistency"；
// 正文语义词 = 读覆盖（read ... not covered by any active version entry），
// Task 4 措辞批保留）。
fn rl_report_rule2(func_i: int, gv: int, inst: int) {
    print("entry-consistency: "); rl_func_name(func_i);
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
fn rl_rule2_func(func_i: int, vs: int, vc: int, nst: int, nc: int, es: int, ec: int) -> int {
    // 签名措辞中性化（Task 2 F3，2026-09-10——值不变）：窗口参数 = 语义对象
    // 空间切片——vs/vc = 变量窗口（全局 var 命名空间 [vs, vs+vc)）、nst/nc =
    // 节点窗口（函数在 NOD 节点坐标空间的 [nst, nst+nc)，源 = 函数窗口表
    // g_ir_func_instr_start/count——节点序 = 指令序 index-aligned，见
    // compute_live_ranges F3 注记）。调用方位置传参，重命名零行为影响。
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
        // 逐节点升序扫读点（读点 = 节点坐标——F1：判定② 读点扫描点，A 通道
        // 中立化 2026-09-10 后 = 对象面 nod_op/nod_s1/nod_s2 同 index 读取，
        // 数值与线性流时代 iri_* 逐字节同）；版本游标单调推进（版本区间自 def
        // 起无缝相接）。
        // 坐标注意（评审 F1 修复）：ent_def/ent_live_end 存全局节点坐标
        // （nst+局部，compute_entries 写入 inst = nst + ii）——比较必须用
        // inst 不得用局部 ii；func 0 上 nst=0 使 ii == inst 掩盖该错配，非
        // func 0 函数上规则 ② 会失明（只漏报不误报；回归 = test_live_ranges
        // check_regalloc_read_gap_nonfunc0）。
        cursor : ., mut = 0;
        first_def := r64(vers, 0 * 8);
        ii : ., mut = 0;
        loop {
            if ii >= nc { break; }
            inst := nst + ii;
            op := nod_op(inst);
            rd : ., mut = 0;
            s1 := nod_s1(inst);
            s2 := nod_s2(inst);
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

// 判定实现（0 = 一致 1 = 违反）——消费条目表（存在区间/home 字段）+ 位置
// 登记表（分配结果统一形态——B 通道中立化 2026-09-10，见登记表节）。
// precondition：alloc_registers() 已跑（条目表随算随新、登记已配对）。
fn verify_regalloc_consistency(func_i: int) -> int {
    if func_i < 0 || func_i >= g_ir_func_count { return 0; }
    es := entry_start(func_i);
    ec := entry_count(func_i);
    if ec <= 0 { return 0; }
    // 函数窗口源同 compute_live_ranges（F3 注记，2026-09-10）：g_ir_func_instr_*
    // 值 = NOD 节点坐标（节点序 = 指令序 index-aligned）；ic/ist 传 rl_rule2_func
    // 的 nst/nc 节点窗口参数（位置传参）。规则② 节点字段读 = 对象面 nod_*。
    ic := r64(g_ir_func_instr_count, func_i * 8);
    ist := r64(g_ir_func_instr_start, func_i * 8);
    vc := r64(g_ir_func_var_count, func_i * 8);
    vs := r64(g_ir_func_var_start, func_i * 8);

    // 规则 ①：同值互斥两遍（B 通道中立化 2026-09-10——设计 spec §2.2 修正：
    // 位置 = 不透明整数，内核无 reg/home 值域分类与编码合成概念）——
    //   (1) 登记表遍：kern_loc_of(e) ≥ 0 的条目按 loc 分组（实例分配输出的
    //       统一登记——现 = 寄存器面；实例若把 home 也登记，合成发生在实例
    //       登记动作内，内核只见不透明值）；
    //   (2) home 字段遍：ent_home ≥ 0 条目按 home 值分组（条目字段独立遍，
    //       -1 未分配哨兵跳过——不复用合成）。
    // 遍序 = 登记表遍先（与现合成排序同序：reg loc 段升序全部先于 home 段——
    // 输出逐字节同）；两遍各自 (loc, live_start) 归并排序后同值互斥 sweep。
    // 排他注记（与现 else-if 合成语义逐条等价）：已登记条目不进 home 遍——
    // 双态条目（已登记 + home ≥ 0）不可达（注入路径先清登记再写 home；真实
    // 分配不回填 home），排他 = 现语义 reg 优先的保持（防双态假冲突）。
    reg_cnt : ., mut = 0;
    home_cnt : ., mut = 0;
    ei : ., mut = 0;
    loop {
        if ei >= ec { break; }
        e := es + ei;
        if ent_live_start(e) >= 0 && ent_live_end(e) >= 0 {
            if kern_loc_of(e) >= 0 { reg_cnt = reg_cnt + 1; }
            else if ent_home(e) >= 0 { home_cnt = home_cnt + 1; }
        }
        ei = ei + 1;
    }
    rule1_viol : ., mut = 0;
    // 登记表遍（先）
    if reg_cnt > 1 {
        rec : string, mut = alloc(reg_cnt * 16);
        ci : ., mut = 0;
        ei = 0;
        loop {
            if ei >= ec { break; }
            e := es + ei;
            if ent_live_start(e) >= 0 && ent_live_end(e) >= 0 {
                loc := kern_loc_of(e);
                if loc >= 0 {
                    w64(rec, ci * 16, loc);
                    w64(rec, ci * 16 + 8, e);
                    ci = ci + 1;
                }
            }
            ei = ei + 1;
        }
        rule1_viol = rl_rule1_sweep(func_i, rec, reg_cnt, 0);
    }
    // home 字段遍（独立遍——cap_base = 登记表遍已打印数（RPT_MAX 合并封顶））
    if home_cnt > 1 {
        rec : string, mut = alloc(home_cnt * 16);
        ci : ., mut = 0;
        ei = 0;
        loop {
            if ei >= ec { break; }
            e := es + ei;
            if ent_live_start(e) >= 0 && ent_live_end(e) >= 0 {
                h := ent_home(e);
                if h >= 0 {
                    w64(rec, ci * 16, h);
                    w64(rec, ci * 16 + 8, e);
                    ci = ci + 1;
                }
            }
            ei = ei + 1;
        }
        rule1_viol = rule1_viol + rl_rule1_sweep(func_i, rec, home_cnt, rule1_viol);
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
// 判定结果输出 API 注记（设计 spec §3.3 双向输出面——Task 4 注释层确认）：
// 本函数 = 文档名 kern_verify_all()——violations 计数 + 违反诊断打印（实例
// 自取）。现名 regalloc_verify_all = x86 时代历史名保留（现名即 API 裁决——
// 不加 kern_ 包装层，YAGNI）；"判定结果回传实例" = 本函数 + 证据查询面
// （entries_coexist/coexist_version_conflicts/coexist_home_conflicts——实例
// 自取），内核不写实例结构。
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

// ==================================================================
// 语义对象模型（内核完备 Task 1，2026-09-10）：对象面 API + NOD 对象留存。
// 对象集 = v7 载体内容的进程内形态（内核持有——配方可读承诺的载体：对象面
// 访问器读内核缓冲而非文件重扫；裁决注：对象存储 (a) 而非文件重扫 (b)——
// 内存成本 28B(语义) + 16B(邻接) 每节点，见 Task 1 报告）：
//   图节点：g_v7_nod_sem（28B 语义字段——盘 36B 记录剥离邻接的镜像，offset
//           布局同盘）+ g_v7_nod_meta（邻接域 {first_edge, edge_count}，
//           16B/节点——EDG 段载入守卫与对象面 nod_edge_first/count 同源）
//   图边：  g_v7_edges/g_v7_edge_count（EDG 段载入缓冲——声明见 ccr_io.cr，
//           8B/条 {to_nod, kind} 打包，文件序 = 节点运行序）
//   条目面：ent_* 族（本文件既有）；区域面 = REG 行（g_sgs）遍历——Task 0
//           定夺：对象面不含 region_of_nod（区域面仅 REG 行遍历）。
// loader（load_ccr，ccr_io.cr）载入对象 + 守卫；NOD→g_ir_instrs 线性重建
// 移实例（build_linear_schedule——regalloc.cr，调度 = 实例事务）。
// A 通道中立化（内核完备 Task 2，2026-09-10）：本文件零线性流 accessor
// （iri_*/g_ir_instrs）代码引用——compute_live_ranges/compute_entries/
// dump_entries_summary/rl_rule2_func 的节点字段读（原 4 使用点）全走本对象
// 面 nod_*（同 index 机械替换——F5 节点序 = 指令序）。节点面喂入 =
// loader（corearch 侧）或 populate_nod_objects（ccr_io.cr corec 写侧——
// compute 前单遍 g_ir_instrs → g_v7_nod_sem 镜像，与 loader 解析逐字节对称；
// 写侧载体裁决 2026-09-10）。本文件访问器 = 内核接口面（读缓冲；调用方
// 保证界内——ent_* 同约）。字段读走 buf_read_*（ccr_io.cr 真实函数体带符号
// 扩展——r32 在 bootstrap 产物里零扩展，负值会读错，见 ent_var 注）；无界
// 检查与 ent_* 约定一致。
ESZ_NOD_SEM : int = 28;    // 内存对象记录 28B（= 盘 36B 剥离 first_edge/edge_count）
ESZ_NOD_META : int = 16;   // 邻接域记录 16B {first_edge i64 @0, edge_count i64 @8}
OFF_NS_OP : int = 0;       // 语义字段 offset（布局镜像盘记录：s1 = 8B 占 +8..+16）
OFF_NS_DEST : int = 4;
OFF_NS_S1 : int = 8;
OFF_NS_S2 : int = 16;
OFF_NS_S3 : int = 20;
OFF_NS_TK : int = 24;

g_v7_nod_sem : string, mut;   // NOD 语义字段对象缓冲（ESZ_NOD_SEM/节点——loader 载入）
g_v7_nod_meta : string, mut;  // NOD 邻接域缓冲（ESZ_NOD_META/节点——EDG 守卫暂存同源）
g_v7_nod_count : int, mut;    // 对象缓冲记录数（= NOD 段节点数——load 后可用）

// 节点面访问器（n = NOD 节点坐标 0..g_v7_nod_count-1）：语义字段读
// g_v7_nod_sem、邻接索引读 g_v7_nod_meta——数值与 loader 解析（buf_read_*）
// 逐字节同（u32 字段 buf_read_u32 / 有符号 buf_read_i32 / s1 buf_read_i64）。
fn nod_op(n: int) -> int { return buf_read_u32(g_v7_nod_sem, n * ESZ_NOD_SEM + OFF_NS_OP); }
fn nod_dest(n: int) -> int { return buf_read_i32(g_v7_nod_sem, n * ESZ_NOD_SEM + OFF_NS_DEST); }
fn nod_s1(n: int) -> int { return buf_read_i64(g_v7_nod_sem, n * ESZ_NOD_SEM + OFF_NS_S1); }
fn nod_s2(n: int) -> int { return buf_read_i32(g_v7_nod_sem, n * ESZ_NOD_SEM + OFF_NS_S2); }
fn nod_s3(n: int) -> int { return buf_read_i32(g_v7_nod_sem, n * ESZ_NOD_SEM + OFF_NS_S3); }
fn nod_tk(n: int) -> int { return buf_read_u32(g_v7_nod_sem, n * ESZ_NOD_SEM + OFF_NS_TK); }
fn nod_edge_first(n: int) -> int { return r64(g_v7_nod_meta, n * ESZ_NOD_META); }
fn nod_edge_count(n: int) -> int { return r64(g_v7_nod_meta, n * ESZ_NOD_META + 8); }

// 边面访问器（e = 全局边下标 0..g_v7_edge_count-1）：读 EDG 缓冲 8B 记录
// {to_nod u32 @0, kind u32 @4}（loader 打包 {to, kind×2^32} 的低/高 32 位）。
fn v7_edge_to(e: int) -> int { return buf_read_u32(g_v7_edges, e * 8); }
fn v7_edge_kind(e: int) -> int { return buf_read_u32(g_v7_edges, e * 8 + 4); }

// 配方查询（薄封装）：节点 n 的配方输入集 = 出边遍历——邻接索引区间
// [nod_edge_first(n), nod_edge_first(n) + nod_edge_count(n))（v7 邻接约定：
// 节点 i 出边连续段，first_edge = 前缀累计），区间内逐边读
// v7_edge_to/v7_edge_kind → 目标节点。节点无出边 = 空区间（count = 0）。
// 补体注记（内核完备 Task 4——Task 1 评审 M-1 悬空注落实）：Core 无闭包/
// 迭代器——遍历动作封装在函数体内，现消费动作 = 配方边记录行输出（对象面
// 诊断通道 dump_object_surface 调用方——函数化收敛：该通道内联遍历 = 本函数
// 体搬移，dump 输出逐字节同，判据 = test_ccr_v7 对象面断言 + --dump-objects
// 语料 byte-compare）。纯值消费方（未来验证器）= 访问器直读模式（M-1 注记：
// 访问器齐备后遍历即查询）。
fn nod_inputs(n: int) {
    last : ., mut = nod_edge_first(n) + nod_edge_count(n);
    ej : ., mut = nod_edge_first(n);
    loop {
        if ej >= last { break; }
        print("edge "); print(int_str(n));
        print(" to "); print(int_str(v7_edge_to(ej)));
        print(" kind "); println(int_str(v7_edge_kind(ej)));
        ej = ej + 1;
    }
}
