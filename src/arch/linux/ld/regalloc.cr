// === regalloc.cr ===
// 编码层资源决策（corearch 侧）：寄存器分配数据面（存在区间/版本条目/共存）
// + CAG 分配（alloc_registers）+ 一致性判定（verify/注入钩子）。
// 2026-09-07 自 opt.cr 按层拆分迁入（迁移段于 corec 侧 opt.cr 切换提交删除；
// 本文件保真搬移——实现与核心注释未改，表述清理见 regalloc-backend 计划 Task 5）。
// 归位后同进程消费：g_opt_meta 内存态自算 + g_ir_entries 自 corearch 自建
// （.ccr ENT/opt_meta 不再传输——D-1=Y 拍板，见计划 Task 1 盘点）。


//
// 2026-09-10 内核抽取 Task 1：存在区间/条目数据面 + 共存 + 规则①② 判定 +
// 判定诊断已随判定搬入 src/lattice/ent_kernel.cr（范式无关内核，格层）——
// 本文件余下 = x86 实例机器侧：CAG alloc_registers（调用内核
// compute_live_ranges）+ g_opt_meta 写入 + 注入钩子（cir debug 测试通道）。


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

// ── 登记表配对辅助（双份同步纪律——内核完备 Task 3）──
// 判定面输入 = 位置登记表（kern_loc_assign/clear/of，ent_kernel.cr）；本文件
// 每 g_opt_meta 写点成对调 kern API——var 级分配/撤销 → 该 var 全部版本条目
// 逐条登记/清除（与判定侧 meta_reg_for_var「任一已登记条目 = 驻留」投影语义
// 等价）。配对点全集 = meta_set_reg/meta_remove_var（注入钩子只经此二函数
// 改写 meta——全部注入路径覆盖，红路径测试 = test_live_ranges
// check_regalloc_violations/read_gap_nonfunc0 经登记通道仍红）+ alloc_registers
// phase 5（原语直写不经辅助函数——单独配对，见 alloc 区尾注记）。
// 条目的所属函数未知（var_idx = 全局 var id）→ 全表扫描（注入 = cir debug
// 通道，低频小表；生产路径 = phase 5 段界扫描不经本辅助）。
fn reg_assign_var_entries(var_idx: int, loc: int) {
    e : ., mut = 0;
    loop {
        if e >= g_entry_count { break; }
        if ent_var(e) == var_idx { kern_loc_assign(e, loc); }
        e = e + 1;
    }
}

fn reg_clear_var_entries(var_idx: int) {
    e : ., mut = 0;
    loop {
        if e >= g_entry_count { break; }
        if ent_var(e) == var_idx { kern_loc_clear(e); }
        e = e + 1;
    }
}

// 强制 var → reg（已有对原位改写；无对追加——append 语义 = 首匹配生效，
// 无对时追加必然生效）
fn meta_set_reg(var_idx: int, reg: int) {
    po := meta_reg_pair_off(var_idx);
    if po >= 0 { w32(g_opt_meta, po, reg); }
    else { meta_append_reg_assign(var_idx, reg); }
    reg_assign_var_entries(var_idx, reg);   // 登记表配对（判定面同步）
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
                    reg_clear_var_entries(var_idx);   // 登记表配对（判定面同步）
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
            // 探针 = 读 meta_reg_for_var（内核完备 Task 3 后 = 登记表读——探针
            // 与 verify 读同一判定输入通道——单真源选择，理由注记：registry 由
            // 实例配对写点（alloc phase 5 + meta_set_reg/meta_remove_var）保持
            // 与 g_opt_meta 同步——本注入的撤销/强制驻留经配对辅助，探针读 =
            // g_opt_meta 的一致视图，无需实例侧私有直扫）
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
            // ── 阶段 5 尾：登记表配对（双份同步纪律——内核完备 Task 3）──
            // g_opt_meta = emit 面私有结构（instr.cr get_reg_for_var 消费）；判定
            // 面输入 = 位置登记表（kern_loc_assign——每 g_opt_meta 写点成对登记，
            // 实例责任）。分配粒度 = var 级单位置（见上分配粒度决策）→ 同 var
            // 全部版本条目登记同 loc：对每个已分配 var vw，对 e ∈ [entry_start(fi),
            // +entry_count(fi)) 且 ent_var(e) == vw 逐一 kern_loc_assign(e, rn)——
            // 与判定侧 meta_reg_for_var 投影语义精确等价的前提（var 分配 ⇔ 全
            // 条目登记；分配器将来升条目级时按条目登记，判定零改动）。
            es := entry_start(fi);
            ec := entry_count(fi);
            ai = 0;
            loop {
                if ai >= rc { break; }
                lvp := r64(asg_lv, ai * 8);
                vw := vs + lvp;
                rn := r64(var_asg, lvp * 8);
                ej : ., mut = 0;
                loop {
                    if ej >= ec { break; }
                    e := es + ej;
                    if ent_var(e) == vw { kern_loc_assign(e, rn); }
                    ej = ej + 1;
                }
                ai = ai + 1;
            }
        }
        fi = fi + 1;
    }
}

// ===== 语义对象模型（内核完备 Task 1）：调度重建 = 实例事务 =====
// NOD→g_ir_instrs 线性重建自 ccr_io.cr load_ccr 移出（原 NOD 段重建循环函数
// 体纯搬移——零改动）：从内核对象缓冲（nod_* 访问器读 g_v7_nod_sem——28B
// 语义字段载入镜像 + nod_edge_first/count 读邻接域）顺序直出 48B 线性流
// （g_ir_instrs + g_ir_instr_count）。重建产物与移出前逐字节一致（判据 =
// backend_bootstrap stage 链 byte-identical——纯搬移证明）。REG 展开/函数
// 边界回填（root span → g_ir_func_instr_start/count）留在 loader（GC-3 守卫
// 消费——Task 0 确认零线性流依赖）。调用方：corearch.cr / arch/linux/ld/
// main.cr（自举 stage 链入口）——load_ccr 成功后、分派/发射前调用一次。
fn build_linear_schedule() {
    grow_ir_instrs(g_v7_nod_count);
    ni : ., mut = 0;
    loop {
        if ni >= g_v7_nod_count { break; }
        iri_set_op(ni, nod_op(ni));
        iri_set_dest(ni, nod_dest(ni));
        iri_set_s1(ni, nod_s1(ni));
        iri_set_s2(ni, nod_s2(ni));
        iri_set_s3(ni, nod_s3(ni));
        iri_set_tk(ni, nod_tk(ni));
        g_ir_instr_count = ni + 1;
        ni = ni + 1;
    }
}
