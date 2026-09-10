// ══════════════════════════════════════════════════════════════
// Binary emit interface — state + helpers + emit_instr
// ══════════════════════════════════════════════════════════════

// State globals (set by caller before emit phase)
g_x86_rodata_base : int, mut;
g_x86_func_frame_start : int, mut;  // abs buf pos of current function body (after frame)
g_current_func_var_start : int, mut;  // var_start of current function, set before emit
g_hit_tabled_count : int, mut;  // 表驱动实际发射事件条数（诊断：corearch 表模式总结）

E2_REG_SLOT_BASE : int = 1000000000;


fn g2_init() {
    g_x86_emit_var_count = 0;
    g_x86_emit_stack_size = 0;
    g_x86_ret_patch_count = 0;
    // g_x86_mw_jo_count: reset per function — jo rel32s are patched to the
    // function-tail slow-path block right after each function's epilogue.
    g_x86_mw_jo_count = 0;
    // g_x86_mw_oc_count (Task 4): reset per function — 2L 操作数检查
    // （jne 0F 85）同款回填到函数尾 2L 块。
    g_x86_mw_oc_count = 0;
    // g_x86_alloc_patch_count NOT reset: alloc calls are patched after all funcs.
    // g_x86_ext_rel_count NOT reset: extern relocations span all functions.
    // g_x86_rip_patch_count NOT reset
}

// ── Optimization metadata: register assignment lookup ──
// Reads g_opt_meta to find register for a variable. regalloc 移后端（2026-09-07）
// 后 g_opt_meta 由 corearch O2 自算填充（load 后 alloc_registers，不再经 .ccr
// 传输）；O0/O1 恒空 → 全栈发射。Returns -1 if no register assigned.

fn get_reg_for_var(var_idx: int) -> int {
    mi : ., mut = 0;
    loop { if mi >= g_opt_meta_count { break; }
        mo := mi * OPT_META_STRIDE;
        mk := r32(g_opt_meta, mo);
        if mk == OPT_KEY_REG_ASSIGN {
            data_len := r32(g_opt_meta, mo + 4);
            di : ., mut = 4;  // skip count u32, pairs start at +4
            loop { if di >= data_len { break; }
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

fn g2_slot(v: int) -> int {
    // Register encoding uses a positive sentinel range so it cannot collide
    // with large negative stack frame offsets.
    if v >= E2_REG_SLOT_BASE { return v; }
    // Check optimization metadata for register assignment (opt_level >= 1)
    if g_opt_level >= 1 && v >= 0 {
        rn := get_reg_for_var(v);
        if rn >= 0 { return E2_REG_SLOT_BASE + rn; }
    }
    // Stack sharing: if this var maps to another, use that var's slot
    if v >= 0 && str_len(g_stack_map) > v * 8 {
        mapped := r64(g_stack_map, v * 8);
        if mapped >= 0 && mapped != v { v = mapped; }
    }
    // Function-relative slot: offset within current function's stack frame
    // Keeps offsets small (disp8 range) for large absolute var indices
    if v >= 0 { return -(v + 1 - g_current_func_var_start) * 8; }
    return 0;
}

fn g2_str_off(si: int) -> int {
    o := 0; i := 0;
    loop {
        if i >= g_x86_str_count { break; }
        if r64(g_x86_str_offs, i * 8) == si { return o + 8; }  // +8 for this string's header
        o = o + 8 + istr_len(r64(g_x86_str_offs, i * 8)) + 1;
        if o % 8 != 0 { o = o + 8 - (o % 8); }
        i = i + 1;
    }
    grow_str_offs(g_x86_str_count + 1); w64(g_x86_str_offs, g_x86_str_count * 8, si); g_x86_str_count = g_x86_str_count + 1;
    return o + 8;  // +8 for this string's header
}

fn g2_rodata_sz() -> int {
    o := 0; i := 0;
    loop { if i >= g_x86_str_count { break; } o = o + 8 + istr_len(r64(g_x86_str_offs, i * 8)) + 1; if o % 8 != 0 { o = o + 8 - (o % 8); } i = i + 1; }
    return o;
}

// ══════════════════════════════════════════════════════════════
// int 多字 M1 tagged 槽（D1a）——潜在多字变量识别 + tag 区（Task 1）
//
// 值表示（plan 拍板）：快路径 int 变量槽仍 64 位（快值或 2-limb 堆指针）；
// 潜在多字变量（运行时可持有 |v| ≥ 2^63 的值）在栈帧尾附加 1 字节 tag。
// var 槽偏移（g2_slot）不变；tag 区位于槽区之下：k-th tagged（变量索引升序）
// 的 tag 字节偏移 = -(vc*8 + 1 + k)（相对 rbp）。无 tagged 变量的函数 tag 区
// 为空 → 帧公式与现状逐字节一致（快路径零变化硬约束）。
//
// 识别规则（保守最小正确集——M1 无区间证明，D1c 静态免 tag = M2 后置）：
//   函数局部值流闭包（per 函数 [vs, vs+vc) 的 TI_INT 变量行——含表达式临时行，
//   ir_gen 的赋值形态 = 临时行算值 + IR_STORE 定值拷贝落变量行）：
//     A. IR_BINARY(OP_ADD/OP_SUB) 的 dest —— add/sub 溢出是 M1 中唯一的
//        >64 位值生产者（mul/div 溢出链 = M2；>64 字面量 lexer 拒 = D4 推迟 M2）；
//     B. IR_LOAD 值拷贝 d ← s1：s1 已 tagged（TI_INT）→ d tagged —— as 转换等
//        拷贝形态（后端 IR_LOAD = e2_load_var 直拷槽值，无解引用）；
//     B'. IR_STORE 定值拷贝 ρ(s1) := ρ(s2)（ir_gen 赋值形态；后端 = 槽值直拷）：
//        s2 已 tagged → s1 tagged —— 2-limb 值经拷贝进入消费槽（return/比较读
//        的是 s1 槽，只标 add 临时行不够——变量行才是跨语句/跨迭代的携带者）。
//    闭包 = 不动点扫描（见 mw_setup_tags）：tag 态可沿循环回边携带（拷贝点线性
//    先于其 tag 源的定值时，迭代 ≥2 拷贝的是 2-limb 值）——定义先于使用的线性
//    论证只对无环成立；标记单调递增 ⇒ 至多 vc+1 遍收敛。
// 保守性：集合外变量行运行时不可能是 2-limb 态（唯一生产者 = A 的溢出慢路径落
// dest 槽与 B/B' 的槽拷贝）；A 无溢出只是运行时事实（付 1 字节栈 + 之后任务的
// tag 初值写）。
//
// M1 边界（tag 不做传播，后续任务/文档挂账）：
//   - 跨函数：2-limb 值经调用实参/返回值传递（含 goroutine 通道）——无协议；
//   - 出逃：IR_STORE 的全局 s1 / STORE_PTR/STORE_INDEX 把 tagged 值写入
//     全局/堆/数组（STORE 的局部 s1 = 函数内定值拷贝，属 B' 闭包）；
//   - globals/BSS：dest 为全局的算术（现 IR 中函数体 dest 均为局部）。
// 上述场景若 tagged 值真的超 64 = M1 已知边界（正确性由测试套件规避）。
//
// 消费方接口（Task 2-5）：
//   - mw_setup_tags(fi, vs, vc)：per 函数识别 + 填表（elf.cr 两阶段各一次）；
//   - g_x86_mw_tag_count：tagged 数 = tag 区字节数；
//   - g2_tag_off(var_idx)：var 的 tag 字节偏移（-1 = 非 tagged）——慢路径写
//     tag（Task 3）、消费者读 tag（Task 4）均走它；
//   - mw_frame_size(vc)：含 tag 区的帧总字节（已按 SysV 16 对齐规则取整）。
// Task 5（D6「tagged 只栈」）定案：**不排除寄存器分配**——plan 原案的排除
// 动机（多字值不可驻单寄存器）被本表示消解：槽/寄存器驻留的是 64 位快值或
// 2-limb 堆对象指针，128 位载荷在堆上，tag 在帧字节——reg 形态状态完整。
// 全部值读写单 seam g2_slot（含 jo 慢路径回存 e2_mov(dst_reg,rax) 与 2L 块
// 装载），tag 读写单 seam g2_tag_off，与值形态无关；O2 下 tagged 变量确实
// 被 CAG 分配寄存器（含运行时 2L 态）且行为全绿——test_mw_task5.py 元断言
// （oracle tagged ∩ REG_ASSIGN ≠ ∅ @O2 + O1 全栈）+ 16B 通道 = 裁决的实证
// 形态。排除零收益（无独立 reg/栈发射路径可删）有代价（tagged = 最常见 add
// 循环行，O2 性能）。若将来引入 reg 形态不完整的机制（动态 spill 等）再议。
// ══════════════════════════════════════════════════════════════

fn mw_setup_tags(fi: int, vs: int, vc: int) {
    // 识别函数 fi（var 域 [vs, vs+vc)）的潜在多字变量并建立 tag 字节偏移表。
    // 纯 IR 函数——输入即 .ccr 载入后的最终 IR（发射所见），无格式/无跨进程态。
    // 卫生锚：tag 读写模型与识别规则必须同域——tagged 行定值点全集 = ①add/sub
    // 快路径落值清 0 ②IR_STORE/IR_LOAD 拷贝定值传播/清 0 ③prologue 参数保存清 0
    // ④2L 慢路径块写 tag=1（四类由发射侧逐一维护 ⇒ 无帧入口清零——论证全文见
    // 本文件 e2_mw_opnd_block 前「Task 4：tag 卫生」注释块；规则 A/B/B' 只标
    // 这四类会写的行——闭包 ⊇ 2L 可能态由唯一生产者论证闭合）。
    grow_mw_tag_off(vc);
    z : ., mut = 0;
    loop { if z >= vc { break; } w64(g_x86_mw_tag_off, z * 8, -1); z = z + 1; }
    g_x86_mw_tag_count = 0;
    if vc <= 0 { return; }
    ic := r64(g_ir_func_instr_count, fi * 8);
    ist := r64(g_ir_func_instr_start, fi * 8);
    ve := vs + vc;
    // Pass 1：不动点扫描（规则 A/B/B' 单调，重复全扫至某遍无新标收敛；
    // ≤ vc+1 遍——回边携带：循环体内拷贝点可线性先于其 tag 源的定值，
    // 单遍前向（定义先于使用）论证只对无环成立）。dest/目标在函数域内且
    // 为 TI_INT 时：
    //   A. IR_BINARY(ADD/SUB) → 标 dest；
    //   B. IR_LOAD d←s1（as 转换拷贝）且 s1 已标 → 标 d；
    //   B'. IR_STORE ρ(s1):=ρ(s2)（赋值定值拷贝）且 s2 已标 → 标 s1。
    chg : ., mut = 1;
    ii : ., mut = 0;
    loop {
        if chg == 0 { break; }
        chg = 0;
        ii = 0;
        loop {
            if ii >= ic { break; }
            ino := ist + ii;
            op := iri_op(ino);
            if op == IR_BINARY {
                d := iri_dest(ino);
                if d >= vs && d < ve && irv_type(d) == TI_INT {
                    s3 := iri_s3(ino);
                    if (s3 == OP_ADD || s3 == OP_SUB) && r64(g_x86_mw_tag_off, (d - vs) * 8) == -1 {
                        w64(g_x86_mw_tag_off, (d - vs) * 8, 0);  // 0 = 已标记（占位）
                        chg = 1;
                    }
                }
            } else if op == IR_LOAD {
                d := iri_dest(ino);
                if d >= vs && d < ve && irv_type(d) == TI_INT {
                    s1 := iri_s1(ino);
                    if s1 >= vs && s1 < ve && irv_type(s1) == TI_INT && r64(g_x86_mw_tag_off, (s1 - vs) * 8) != -1 && r64(g_x86_mw_tag_off, (d - vs) * 8) == -1 {
                        w64(g_x86_mw_tag_off, (d - vs) * 8, 0);
                        chg = 1;
                    }
                }
            } else if op == IR_STORE {
                s1 := iri_s1(ino);
                if s1 >= vs && s1 < ve && irv_type(s1) == TI_INT {
                    s2 := iri_s2(ino);
                    if s2 >= vs && s2 < ve && irv_type(s2) == TI_INT && r64(g_x86_mw_tag_off, (s2 - vs) * 8) != -1 && r64(g_x86_mw_tag_off, (s1 - vs) * 8) == -1 {
                        w64(g_x86_mw_tag_off, (s1 - vs) * 8, 0);
                        chg = 1;
                    }
                }
            }
            ii = ii + 1;
        }
    }
    // Pass 2：变量索引升序分配 tag 字节（k-th → rbp - (vc*8 + k)）。
    cnt : ., mut = 0;
    k : ., mut = 0;
    loop {
        if k >= vc { break; }
        if r64(g_x86_mw_tag_off, k * 8) != -1 {
            cnt = cnt + 1;
            w64(g_x86_mw_tag_off, k * 8, -(vc * 8 + cnt));
        }
        k = k + 1;
    }
    g_x86_mw_tag_count = cnt;
}

fn g2_tag_off(v: int) -> int {
    // var v（当前函数内）的 tag 字节偏移（相对 rbp，恒负）；-1 = 非 tagged。
    // 仅当前函数内有效（表由 mw_setup_tags 按函数填充）。
    if v < 0 { return -1; }
    lv := v - g_current_func_var_start;
    if lv < 0 { return -1; }
    if str_len(g_x86_mw_tag_off) <= lv * 8 { return -1; }
    return r64(g_x86_mw_tag_off, lv * 8);
}

fn mw_frame_size(vc: int) -> int {
    // 帧总字节 = var 槽 vc*8 + tag 区（g_x86_mw_tag_count 字节）再按现 SysV
    // 规则补 16 对齐：opt≥1（6 pushes）帧 ≡ 8 (mod 16)；opt<1（1 push）≡ 0。
    // tag 数为 0 时对任意 vc 的结果与旧公式逐字节一致（快路径零变化）。
    sz : ., mut = vc * 8 + g_x86_mw_tag_count;
    r := sz % 16;
    if g_opt_level >= 1 {
        if r != 8 {
            pad := 8 - r;
            if pad < 0 { pad = pad + 16; }
            sz = sz + pad;
        }
    } else {
        if r != 0 { sz = sz + (16 - r); }
    }
    return sz;
}

// ── Task 2：快路径溢出检测发射（jo → 函数尾慢路径块）──
// 发射条件 = 规则 A 的 add/sub 指令（emit 侧与 mw_setup_tags 同源判定）：
// IR_BINARY、dest 为当前函数 tagged 变量（g2_tag_off ≠ -1——域外/非 int 恒
// -1，天然过滤 globals/其他函数/dest=-1 与拷贝行）即溢出可能 → jo。untagged
// 的 int 算术（cmp/shl/mul/div…）与 dex（TI_DEX SSE 先行分支）恒不发射——
// 真快路径对 untagged 代码零字节影响。
// Task 4 扩展（本函数 = 表路径排除门——需旧路径（tag 检查/2L 块）的站点
// 整条落旧路径）：比较（OP_EQ..OP_GE）且任一操作数行 tagged → 同样需旧路
// 径（2L 比较读 tag——表路径不知 tag）。add/sub 的 tagged 操作数已由 dest
// tagged 覆盖（规则 A 保证操作数 tagged ⟹ dest tagged）。
fn mw_int_arith_jo_needed(instr_idx: int) -> int {
    if iri_op(instr_idx) != IR_BINARY { return 0; }
    s3 := iri_s3(instr_idx);
    if s3 >= OP_EQ && s3 <= OP_GE {
        s1 := iri_s1(instr_idx);
        if g2_tag_off(s1) != -1 { return 1; }
        s2 := iri_s2(instr_idx);
        if s1 != s2 && g2_tag_off(s2) != -1 { return 1; }
        return 0;
    }
    if s3 != OP_ADD && s3 != OP_SUB { return 0; }
    if g2_tag_off(iri_dest(instr_idx)) == -1 { return 0; }
    return 1; }

// jo rel32（0F 80 cd，6B）→ 慢路径块，位置后知：记录站点现场到
// g_x86_mw_jo_{pos,dest,is_sub}（g2_init 清零、elf.cr 函数尾统一发射块并回填；
// resume 由 elf.cr 于该指令发射完后按序补写）。
// rel32（非 rel8）：块附函数尾——函数体 >127B 时 rel8 不可达（编译器自身
// 的大函数在自举回归里必然命中；Task 2 用 t3 大函数用例锁定该编码）。
fn e2_mw_jo(b: string, p: int, d: int, is_sub: int) -> int {
    grow_mw_jo_patch(g_x86_mw_jo_count + 1);
    w64(g_x86_mw_jo_pos, g_x86_mw_jo_count * 8, p);
    w64(g_x86_mw_jo_dest, g_x86_mw_jo_count * 8, d);
    w64(g_x86_mw_jo_is_sub, g_x86_mw_jo_count * 8, is_sub);
    g_x86_mw_jo_count = g_x86_mw_jo_count + 1;
    w8(b, p, 15); w8(b, p + 1, 128);  // 0F 80 = jo rel32
    e2_w32(b, p + 2, 0);              // 占位——elf.cr 于块位置已知后回填
    return 6;
}

// ── Task 3：慢路径块（每站点独立块，附于函数尾 epilogue 之后）──
// 站点状态（jo 到达块时）：
//   - r10 = 快路径 add/sub 的环绕 64 位结果（低 limb）；
//   - OF = 1（jo 前提）；CF 仍为 e2_alu 所置（jo 不改标志——块内首条指令
//     前无任何写标志指令可再被读）；
//   - rsp ≡ 0 (mod 16)（jo 站点位于 IR_BINARY 发射内——帧级 rsp，无 call
//     栈参推送段在途；opt≥1 帧 ≡ 8 与 opt<1 帧 ≡ 0 的对齐规则保证）。
//   其余现场：O1/O2 寄存器分配只用 callee-saved（rbx/r12-r15，opt.cr
//   CAG）——块只碰 caller-saved（rax/rcx/rdx/rdi/r10/r11 等）+ push/pop
//   自平衡，callee-saved 原样穿越（“块内 call 自平衡”约束）。
//
// 128 位修正（数学推演——溢出下真值 = 环绕 L + 高 limb·2^64，高 limb ∈
// {0, −1} 恒成立，因 add 真值 S ∈ [−2^64, 2^64−2]、sub 真值 S ∈
// [−2^64+1, 2^64−1]）：
//   add：S = a+b 溢出 ⇔ a、b 同号。S ≥ 2^63（正溢出）→ 两操作数 ≥ 0 →
//     无符号和 = S < 2^64 → CF=0 → 高 limb = 0；S < 0（负溢出，S ∈
//     [−2^64, −2^63−1]）→ 两操作数 < 0 → 无符号和 = S+2^65 ≥ 2^64 →
//     CF=1 → 高 limb = −1。∴ add 溢出高 limb = CF ? −1 : 0。
//   sub：S = a−b 溢出。S ≥ 2^63（正溢出）→ a ≥ 0 > b → a_u < b_u →
//     借位 CF=1 → 高 limb = 0；S ≤ −2^63−1（负溢出）→ a < 0 ≤ b →
//     a_u > b_u → CF=0 → 高 limb = −1（混合符号无借位——a=−2^63、b=1
//     即 S=−2^63−1、CF=0）。∴ sub 溢出高 limb = CF ? 0 : −1。
//   实现：CF → r11：sbb r11, r11 = −CF（0 或 −1——add 直接可用）；
//   sub 再 not r11（~(−CF) = CF ? 0 : −1）。低 limb = r10 环绕值照存。
//   两者合一叙述（溢出 = 符号翻转）：高 limb = −1 ⇔ 环绕结果符号位 = 0
//   （r10 ≥ 0）——add/sub 同式，CF 式只是其标志实现。
// 边界核对（brute-force 全样本验证 + 逐用例，见 mw-m1-task-3 报告）：
//   a=b=−2^63（add，S=−2^64 恰在 128 域内）：L=0、CF=1 → [lo=0, hi=−1] ✓。
fn e2_mw_slow_block(b: string, p: int, d: int, is_sub: int, resume: int) -> int {
    cp : ., mut = 0;
    // 1. 高 limb → r11（add：sbb r11,r11 = −CF；sub：+not → CF?0:−1）。
    //    须为块内首操作——CF 其后随时可能被写。
    w8(b, p + cp, 77); w8(b, p + cp + 1, 25); w8(b, p + cp + 2, 219); cp = cp + 3;  // sbb r11, r11 (4D 19 DB)
    if is_sub != 0 {
        w8(b, p + cp, 73); w8(b, p + cp + 1, 247); w8(b, p + cp + 2, 211); cp = cp + 3;  // not r11 (49 F7 D3—REX.WB: rm=r11 需 B 位)
    }
    // 2. 保存 lo/hi（alloc 调用会摧毁 caller-saved r10/r11）：两 push 后
    //    rsp ≡ 0 (mod 16)——满足 SysV call 对齐（进入块时 rsp ≡ 0）。
    w8(b, p + cp, 65); w8(b, p + cp + 1, 82); cp = cp + 2;  // push r10 (41 52)
    w8(b, p + cp, 65); w8(b, p + cp + 1, 83); cp = cp + 2;  // push r11 (41 53)
    // 3. alloc(16)——16B 2-limb 对象；与 IR_ALLOC_* 同款补丁表注册
    //    （g_x86_alloc_patch_count 逐函数不重置——函数尾块与函数体同批回填）。
    //    mov edi, 16（BF imm32——16 为合法 imm32）
    w8(b, p + cp, 191); e2_w32(b, p + cp + 1, 16); cp = cp + 5;
    grow_alloc_patch(g_x86_alloc_patch_count + 1);
    w64(g_x86_alloc_patch_pos, g_x86_alloc_patch_count * 8, p + cp);
    g_x86_alloc_patch_count = g_x86_alloc_patch_count + 1;
    w8(b, p + cp, 232); e2_w32(b, p + cp + 1, 0); cp = cp + 5;  // call alloc（占位回填）
    // 4. 恢复 lo/hi
    w8(b, p + cp, 65); w8(b, p + cp + 1, 91); cp = cp + 2;  // pop r11 (41 5B)
    w8(b, p + cp, 65); w8(b, p + cp + 1, 90); cp = cp + 2;  // pop r10 (41 5A)
    // 5. 写 2-limb 对象（rax = alloc 返回的数据指针）：[+0] = lo（环绕值）、
    //    [+8] = hi（符号扩展修正）。注意 REX：rm=rax 无需 B 位——仅 R（源
    //    r10/r11）→ 4C（对照 elf.cr alloc 内 mov [rax], r9 = 4C 89 08）。
    w8(b, p + cp, 76); w8(b, p + cp + 1, 137); w8(b, p + cp + 2, 16); cp = cp + 3;  // mov [rax], r10 (4C 89 10)
    w8(b, p + cp, 76); w8(b, p + cp + 1, 137); w8(b, p + cp + 2, 88); w8(b, p + cp + 3, 8); cp = cp + 4;  // mov [rax+8], r11 (4C 89 58 08)
    // 6. 值槽存指针（跳过快路径 e2_st——本块自回存 dest；g2_slot 含
    //    O1/O2 reg 形态：E2_REG_SLOT_BASE 编码 → e2_mov reg, rax）
    cp = cp + e2_st(b, p + cp, 0, g2_slot(d));
    // 7. tag 字节置位（g2_tag_off(d) ≠ −1 由 jo 发射条件保证）：槽内现为
    //    2-limb 指针 ⇔ tag = 1（tag 不变量慢路径侧）。
    tago := g2_tag_off(d);
    if tago >= -128 && tago <= 127 {
        w8(b, p + cp, 198); w8(b, p + cp + 1, 69); w8(b, p + cp + 2, tago); w8(b, p + cp + 3, 1); cp = cp + 4;
    } else {
        w8(b, p + cp, 198); w8(b, p + cp + 1, 133); e2_w32(b, p + cp + 2, tago);
        w8(b, p + cp + 6, 1); cp = cp + 7;
    }
    // 8. 跳回快路径 store 之后（resume = 该站点指令尾，elf.cr 填）
    w8(b, p + cp, 233);  // E9 jmp rel32
    e2_w32(b, p + cp + 1, resume - (p + cp + 5));
    return cp + 5;
}

// ── Task 4：tag 卫生（定值点写 tag）+ 消费者读路径 ──
// 值表示：槽 64 位 = 快值 或 2-limb 堆对象指针；旁路 tag 字节 0/1。
//
// tag 卫生策略 = 定值点写 tag（无帧入口清零——论证：tagged 行的每个定值点
// 都属于以下集合之一，消费者只读「本调用内已执行的定值」之后的 tag）：
//   ① add/sub 快路径落值（emit_instr IR_BINARY 尾 e2_st 后 tag 清 0）；
//   ② 拷贝定值 IR_STORE/IR_LOAD（源 tagged → 运行时 tag 拷贝；源 untagged
//      → 清 0——e2_mw_tag_copy）；
//   ③ 本函数 prologue 参数保存（elf.cr——tagged 参数行在函数内首次定值
//      前的读取需要确定性 tag=0）；
//   ④ 2-limb 定值 = 慢路径块/2L 块写指针 + tag=1（Task 3/本任务）。
// 行模型事实（.ccr 实证）：用户变量行只经 IR_STORE 得到真定值（常量/算术
// 都经临时行 + STORE）；IR_CONST/IR_UNARY/IR_CALL 等的 dest 恒为一次性
// 临时行（tag 闭包外）——因此定值点全集 = 上述四类，无遗漏。
//
// 消费者读路径（tag=1 → 槽 = 指针 → 解 2-limb）：
//   A. IR_RETURN：解指针取低 limb → rax（exit 低 8 位 = 数学值低字节）；
//   B. int 比较（IR_BINARY OP_EQ..OP_GE，任一操作数 tagged）：128 位比较
//      ——高 limb 带符号、同则低 limb 无符号（两补语义）；结果 0/1 快值；
//   C. add/sub 链（dest tagged，任一操作数 tagged）：128 位混合算术
//      （快操作数符号扩展 + 低+低进位链 + 高+高/借位链），结果可装 64 位 →
//      降级快值 + tag 0（保持「2L ⟹ |v| ≥ 2^63 ⟹ 非零」不变量——IR_BRANCH
//      对 2L 指针的真值测试因此天然正确，无需改动）；否则新 2-limb 对象
//      + tag 1。结果界：|加数| ≤ 2^64−1 + |2L| ≤ 2^65 → |和| < 2^66 ≪
//      2^127——128 位码域永不越界（无码域错误路径；链长 ~2^63 步才可能
//      触界 = 理论，M2 动态增长）。
//   D. M2 边界（保持 Task 1 报告边界）：2L 操作数进入 MUL/DIV/SHL/一元
//      neg/移位等未实现站点、出逃写（STORE 全局/堆/数组）、跨函数——
//      本任务不改，测试规避。
// ══════════════════════════════════════════════════════════════

// 字节级小助手（rbp 相对偏移，disp8/disp32 自动）：
// test byte [rbp+off], 0xFF——F6 /0（ZF ⇔ 字节==0；只写标志）
fn e2_mw_t8(b: string, p: int, off: int) -> int {
    if off >= -128 && off <= 127 {
        w8(b, p, 246); w8(b, p+1, 69); w8(b, p+2, off); w8(b, p+3, 255); return 4;
    }
    w8(b, p, 246); w8(b, p+1, 133); e2_w32(b, p+2, off); w8(b, p+6, 255); return 7;
}
// mov byte [rbp+off], imm——C6 /0
fn e2_mw_b8(b: string, p: int, off: int, imm: int) -> int {
    if off >= -128 && off <= 127 {
        w8(b, p, 198); w8(b, p+1, 69); w8(b, p+2, off); w8(b, p+3, imm); return 4;
    }
    w8(b, p, 198); w8(b, p+1, 133); e2_w32(b, p+2, off); w8(b, p+6, imm); return 7;
}
// mov al, [rbp+off]——8A /0（rax 低字节 scratch——发射点 rax 无 live）
fn e2_mw_ld8(b: string, p: int, off: int) -> int {
    if off >= -128 && off <= 127 {
        w8(b, p, 138); w8(b, p+1, 69); w8(b, p+2, off); return 3;
    }
    w8(b, p, 138); w8(b, p+1, 133); e2_w32(b, p+2, off); return 6;
}
// mov [rbp+off], al——88 /0
fn e2_mw_st8(b: string, p: int, off: int) -> int {
    if off >= -128 && off <= 127 {
        w8(b, p, 136); w8(b, p+1, 69); w8(b, p+2, off); return 3;
    }
    w8(b, p, 136); w8(b, p+1, 133); e2_w32(b, p+2, off); return 6;
}

// 定值点 tag 清 0：变量 v 的槽刚被 64 位快值定值（v tagged 时发 mov byte 0）。
fn e2_mw_tag_clr(b: string, p: int, v: int) -> int {
    tg := g2_tag_off(v);
    if tg == -1 { return 0; }
    return e2_mw_b8(b, p, tg, 0);
}

// 拷贝定值 tag 传播：dst 的槽 ← src 的值（拷贝后 dst 的 tag = src 的 tag；
// src 无 tag 字节（恒快）→ dst 清 0）。dst untagged → 零字节。
fn e2_mw_tag_cpy(b: string, p: int, dst: int, src: int) -> int {
    dtg := g2_tag_off(dst);
    if dtg == -1 { return 0; }
    stg := g2_tag_off(src);
    if stg == -1 { return e2_mw_b8(b, p, dtg, 0); }
    c : ., mut = e2_mw_ld8(b, p, stg);
    c = c + e2_mw_st8(b, p + c, dtg);
    return c;
}

// ── 消费者站点记录（oc = operand-check）：位置后知（函数尾块），jo 同款 ──
fn mw_oc_new(s1: int, s2: int, d: int, op: int) -> int {
    grow_mw_oc_patch(g_x86_mw_oc_count + 1);
    w64(g_x86_mw_oc_pos1, g_x86_mw_oc_count * 8, -1);
    w64(g_x86_mw_oc_pos2, g_x86_mw_oc_count * 8, -1);
    w64(g_x86_mw_oc_s1, g_x86_mw_oc_count * 8, s1);
    w64(g_x86_mw_oc_s2, g_x86_mw_oc_count * 8, s2);
    w64(g_x86_mw_oc_dest, g_x86_mw_oc_count * 8, d);
    w64(g_x86_mw_oc_op, g_x86_mw_oc_count * 8, op);
    g_x86_mw_oc_count = g_x86_mw_oc_count + 1;
    return g_x86_mw_oc_count - 1;
}

// 站点检查：test tag(v), 0xFF；jne rel32（0F 85）→ 该站点函数尾 2L 块。
// rel32 恒选：块附函数尾，函数体 >127B 时 rel8 不可达（jo 同理由）。chk =
// 0/1 → pos1/pos2（站点至多 2 个检查——s1、s2 各行一个，s1==s2 只发 1 个）。
// 记录位置 = jne 起始（p+c——test 前缀 4/7B 后；rel32 字段在 jne 起 +2——
// 若误记 test 起，回填会覆写 test 的 disp/imm 字节）。
fn e2_mw_oc_check(b: string, p: int, oc: int, chk: int, v: int) -> int {
    c : ., mut = e2_mw_t8(b, p, g2_tag_off(v));
    if chk == 0 { w64(g_x86_mw_oc_pos1, oc * 8, p + c); }
    else { w64(g_x86_mw_oc_pos2, oc * 8, p + c); }
    w8(b, p + c, 15); w8(b, p + c + 1, 133); e2_w32(b, p + c + 2, 0);
    return c + 6;
}

// ── 2L 操作数装载（解 2-limb 对象到寄存器对）──
// regs: A = (r8=lo, r9=hi)，B = (r10=lo, r11=hi)；rax = 指针 scratch；
// 快值 → hi = sar 63 符号扩展（两补 128 语义）。快值载入 r8/r10；2L = 槽值
// （指针）入 rax 后解 [rax+0]/[rax+8]（对象布局 [+0]=lo [+8]=hi）。
//   mov r8, [rax]     4C 8B 00      mov r9, [rax+8]   4C 8B 48 08
//   mov r10, [rax]    4C 8B 10      mov r11, [rax+8]  4C 8B 58 08
fn e2_mw_ld2(b: string, p: int, lo_r: int, hi_r: int) -> int {
    w8(b, p, 76); w8(b, p+1, 139); w8(b, p+2, (lo_r % 8) * 8);       // mov r{lo}, [rax]
    w8(b, p+3, 76); w8(b, p+4, 139);
    w8(b, p+5, 64 + (hi_r % 8) * 8); w8(b, p+6, 8);                  // mov r{hi}, [rax+8]
    return 7;
}
// mov r{hi}, r{lo}; sar r{hi}, 63——快值 64→128 符号扩展（hi = sext）
fn e2_mw_sext(b: string, p: int, lo_r: int, hi_r: int) -> int {
    c : ., mut = e2_mov(b, p, hi_r, lo_r);
    w8(b, p+c, 73); w8(b, p+c+1, 193);   // REX.WB + C1 /7
    w8(b, p+c+2, 248 + (hi_r % 8));      // modrm 11 111 rm（/7 = SAR）
    w8(b, p+c+3, 63);
    return c + 4;
}

// ── 2L 操作数块（每消费者站点独立，附于函数尾 jo 块之后）──
// 入口：≥1 操作数 2L（快路径 tag 检查 jne rel32 → 块首）。现场：无 live
// 值（检查在操作数装载后、运算前——块内重载全部操作数，r10/r11 装载值
// 废弃）；rsp ≡ 0 (mod 16)（站点帧级 rsp——同 jo 块论证；块内唯一 call
// （alloc）由双 push/pop 自平衡）。只碰 caller-saved（rax/rdx/r8-r11）+
// push/pop；callee-saved（O1/O2 reg 分配 rbx/r12-15）原样穿越。
// 静态参数化：操作数行 untagged（恒快）→ 不发该行 tag 测试/2L 装载——
// 块入口条件（≥1 2L）在单 tagged 站点下唯一确定装载路径；双 tagged 站点
// 内部分派（测试 s1 → A 快则 B 必 2L；A 2L 再测 s2）。s1==s2 时两测试同
// 字节（单检查站点：入口即 2L → A 2L → 同字节测试恒取 L_both，自洽）。
// 块内 jcc/jmp 全部 rel8（块全长最坏 ~160B——双 tagged + sub + 2L 落值尾；
// 但 rel8 只跨发射点后的局部子区，最远前向 = je → L_fit 越过 2L 存储尾
// ≤ ~60B——±127 恒足；跨块长距跳恒 rel32：tag 检查 jne → 块首、块尾 jmp →
// resume）。rel8 目标在块内顺序发射中即时回填（目标 = 已到达的后续位置）。
fn e2_mw_opnd_block(b: string, p: int, s1: int, s2: int, d: int, op: int, resume: int) -> int {
    cp : ., mut = 0;
    t1 := g2_tag_off(s1);
    t2 : ., mut = t1;
    if s1 != s2 { t2 = g2_tag_off(s2); }
    is_cmp : ., mut = 0;
    if op >= OP_EQ && op <= OP_GE { is_cmp = 1; }
    is_sub : ., mut = 0;
    if is_cmp == 0 && op == OP_SUB { is_sub = 1; }

    if t1 != -1 && t2 != -1 {
        // ── 双 tagged 分派：测 t1——0 → A 快 + B 必 2L；1 → A 2L 再测 t2 ──
        cp = cp + e2_mw_t8(b, p+cp, t1);
        j_a2l : ., mut = cp; w8(b, p+cp, 117); w8(b, p+cp+1, 0); cp = cp + 2;  // jne L_a2l
        // A 快
        cp = cp + e2_load_var(b, p+cp, 8, s1);
        cp = cp + e2_mw_sext(b, p+cp, 8, 9);
        // B 必 2L
        cp = cp + e2_load_var(b, p+cp, 0, s2);
        cp = cp + e2_mw_ld2(b, p+cp, 10, 11);
        j_op1 : ., mut = cp; w8(b, p+cp, 235); w8(b, p+cp+1, 0); cp = cp + 2;  // jmp L_op
        // L_a2l：A 2L
        w8(b, p + j_a2l + 1, cp - (j_a2l + 2));
        cp = cp + e2_load_var(b, p+cp, 0, s1);
        cp = cp + e2_mw_ld2(b, p+cp, 8, 9);
        cp = cp + e2_mw_t8(b, p+cp, t2);
        j_both : ., mut = cp; w8(b, p+cp, 117); w8(b, p+cp+1, 0); cp = cp + 2;  // jne L_both
        // B 快
        cp = cp + e2_load_var(b, p+cp, 10, s2);
        cp = cp + e2_mw_sext(b, p+cp, 10, 11);
        j_op2 : ., mut = cp; w8(b, p+cp, 235); w8(b, p+cp+1, 0); cp = cp + 2;  // jmp L_op
        // L_both：B 2L
        w8(b, p + j_both + 1, cp - (j_both + 2));
        cp = cp + e2_load_var(b, p+cp, 0, s2);
        cp = cp + e2_mw_ld2(b, p+cp, 10, 11);
        // L_op = 当前 cp——回填两个 jmp
        w8(b, p + j_op1 + 1, cp - (j_op1 + 2));
        w8(b, p + j_op2 + 1, cp - (j_op2 + 2));
    } else if t1 != -1 {
        // 仅 s1 tagged：入口 ⟹ s1 2L → A 2L；B 恒快
        cp = cp + e2_load_var(b, p+cp, 0, s1);
        cp = cp + e2_mw_ld2(b, p+cp, 8, 9);
        cp = cp + e2_load_var(b, p+cp, 10, s2);
        cp = cp + e2_mw_sext(b, p+cp, 10, 11);
    } else {
        // 仅 s2 tagged：入口 ⟹ s2 2L → A 恒快；B 2L
        cp = cp + e2_load_var(b, p+cp, 8, s1);
        cp = cp + e2_mw_sext(b, p+cp, 8, 9);
        cp = cp + e2_load_var(b, p+cp, 0, s2);
        cp = cp + e2_mw_ld2(b, p+cp, 10, 11);
    }

    // ── L_op：128 位运算（A=(r8,r9) B=(r10,r11)）──
    if is_cmp == 0 {
        // 算术：结果 (r10 = lo, r11 = hi)
        if is_sub == 0 {
            w8(b, p+cp, 77); w8(b, p+cp+1, 1); w8(b, p+cp+2, 194); cp = cp + 3;   // add r10, r8（lo + CF）
            w8(b, p+cp, 77); w8(b, p+cp+1, 17); w8(b, p+cp+2, 203); cp = cp + 3;  // adc r11, r9（hi 进位链）
        } else {
            w8(b, p+cp, 77); w8(b, p+cp+1, 41); w8(b, p+cp+2, 208); cp = cp + 3;  // sub r8, r10（lo，CF=借位）
            w8(b, p+cp, 76); w8(b, p+cp+1, 137); w8(b, p+cp+2, 216); cp = cp + 3;  // mov rax, r11（暂存 bh）
            w8(b, p+cp, 77); w8(b, p+cp+1, 137); w8(b, p+cp+2, 203); cp = cp + 3;  // mov r11, r9（ah）
            w8(b, p+cp, 73); w8(b, p+cp+1, 25); w8(b, p+cp+2, 195); cp = cp + 3;   // sbb r11, rax（ah−bh−CF）
            w8(b, p+cp, 77); w8(b, p+cp+1, 137); w8(b, p+cp+2, 194); cp = cp + 3;  // mov r10, r8（lo）
        }
        // 公共落值：fits-64 ⇔ hi == signmask(lo) → 降级快值；否则 2L 对象
        // （结果界：|加数| ≤ 2^64−1 + 2^65 → |和| < 2^66 ≪ 2^127——M1 码域
        // 内恒可表示，无需码域错误路径——见块注释）。
        cp = cp + e2_mov(b, p+cp, 2, 10);                                        // mov rdx, r10
        w8(b, p+cp, 72); w8(b, p+cp+1, 193); w8(b, p+cp+2, 250); w8(b, p+cp+3, 63); cp = cp + 4;  // sar rdx, 63（signmask）
        w8(b, p+cp, 73); w8(b, p+cp+1, 57); w8(b, p+cp+2, 211); cp = cp + 3;     // cmp r11, rdx（0x49 39 D3：REX.W+B——reg=rdx；错编 0x4D = reg r10 = cmp r11,r10——假 fit 截断，d1/d2 判别）
        j_fit : ., mut = cp; w8(b, p+cp, 116); w8(b, p+cp+1, 0); cp = cp + 2;    // je L_fit
        // 2L 存储：alloc(16) + 2-limb 写 + 槽存指针 + tag=1（同 Task 3 块）
        w8(b, p+cp, 65); w8(b, p+cp+1, 82); cp = cp + 2;                         // push r10
        w8(b, p+cp, 65); w8(b, p+cp+1, 83); cp = cp + 2;                         // push r11
        w8(b, p+cp, 191); e2_w32(b, p+cp+1, 16); cp = cp + 5;                    // mov edi, 16
        grow_alloc_patch(g_x86_alloc_patch_count + 1);
        w64(g_x86_alloc_patch_pos, g_x86_alloc_patch_count * 8, p + cp);
        g_x86_alloc_patch_count = g_x86_alloc_patch_count + 1;
        w8(b, p+cp, 232); e2_w32(b, p+cp+1, 0); cp = cp + 5;                     // call alloc
        w8(b, p+cp, 65); w8(b, p+cp+1, 91); cp = cp + 2;                         // pop r11
        w8(b, p+cp, 65); w8(b, p+cp+1, 90); cp = cp + 2;                         // pop r10
        w8(b, p+cp, 76); w8(b, p+cp+1, 137); w8(b, p+cp+2, 16); cp = cp + 3;     // mov [rax], r10
        w8(b, p+cp, 76); w8(b, p+cp+1, 137); w8(b, p+cp+2, 88); w8(b, p+cp+3, 8); cp = cp + 4;  // mov [rax+8], r11
        cp = cp + e2_st(b, p+cp, 0, g2_slot(d));                                // 值槽存指针
        cp = cp + e2_mw_b8(b, p+cp, g2_tag_off(d), 1);                          // tag = 1
        w8(b, p+cp, 233); e2_w32(b, p+cp+1, resume - (p+cp+5)); cp = cp + 5;    // jmp rel32 → resume
        l_fit := cp;
        w8(b, p + j_fit + 1, l_fit - (j_fit + 2));                              // 回填 je → L_fit
        cp = cp + e2_st(b, p+cp, 10, g2_slot(d));                               // 降级：快值落槽
        cp = cp + e2_mw_tag_clr(b, p+cp, d);                                    // tag = 0
        w8(b, p+cp, 233); e2_w32(b, p+cp+1, resume - (p+cp+5)); cp = cp + 5;    // jmp rel32 → resume
        return cp;
    }

    // ── 比较：结果 0/1（128 位语义——高 limb 带符号、同则低 limb 无符号）──
    if op == OP_EQ || op == OP_NE {
        w8(b, p+cp, 77); w8(b, p+cp+1, 49); w8(b, p+cp+2, 208); cp = cp + 3;     // xor r8, r10（al^bl）
        w8(b, p+cp, 77); w8(b, p+cp+1, 49); w8(b, p+cp+2, 217); cp = cp + 3;    // xor r9, r11（ah^bh）
        w8(b, p+cp, 77); w8(b, p+cp+1, 9); w8(b, p+cp+2, 193); cp = cp + 3;     // or r9, r8（ZF ⇔ 全等）
        if op == OP_EQ { w8(b, p+cp, 15); w8(b, p+cp+1, 148); w8(b, p+cp+2, 192); cp = cp + 3; }   // sete al
        else { w8(b, p+cp, 15); w8(b, p+cp+1, 149); w8(b, p+cp+2, 192); cp = cp + 3; }            // setne al
    } else {
        // LT/GT/LE/GE：eax 缺省 0（假）；决定性 jcc → L_t（真）/L_d（假，
        // 前向）；hi 同 → lo 无符号再判。布局：
        //   xor eax; cmphi; j_ht L_t; j_hf L_d; cmplo; j_lf L_d;
        //   L_t: mov eax,1;  L_d: 落值（j_ht 落 L_t、其余落 L_d——全前向）
        w8(b, p+cp, 49); w8(b, p+cp+1, 192); cp = cp + 2;                       // xor eax, eax
        w8(b, p+cp, 77); w8(b, p+cp+1, 57); w8(b, p+cp+2, 217); cp = cp + 3;    // cmp r9, r11（hi 符号）
        hi_t : ., mut = 124; hi_f : ., mut = 127;   // 缺省 LT/LE：jl → 真、jg → 假
        if op == OP_GT || op == OP_GE { hi_t = 127; hi_f = 124; }              // GT/GE：jg → 真、jl → 假
        j_ht : ., mut = cp; w8(b, p+cp, hi_t); w8(b, p+cp+1, 0); cp = cp + 2;
        j_hf : ., mut = cp; w8(b, p+cp, hi_f); w8(b, p+cp+1, 0); cp = cp + 2;
        w8(b, p+cp, 77); w8(b, p+cp+1, 57); w8(b, p+cp+2, 208); cp = cp + 3;    // cmp r8, r10（lo 无符号）
        lo_f : ., mut = 115;   // 缺省 LT：jae（lo ≥u → 假）
        if op == OP_LE { lo_f = 119; } else if op == OP_GT { lo_f = 118; } else if op == OP_GE { lo_f = 114; }
        // LE: ja / GT: jbe / GE: jb（lo 不满足 → 假——L_d 前向）
        j_lf : ., mut = cp; w8(b, p+cp, lo_f); w8(b, p+cp+1, 0); cp = cp + 2;
        // L_t: mov eax, 1（落入 L_d 共享落值——全前向布局）
        l_t := cp; w8(b, p+cp, 184); e2_w32(b, p+cp+1, 1); cp = cp + 5;
        // L_d = 当前 cp——回填（j_ht → L_t；j_hf/j_lf → L_d）
        w8(b, p + j_ht + 1, l_t - (j_ht + 2));
        w8(b, p + j_hf + 1, cp - (j_hf + 2));
        w8(b, p + j_lf + 1, cp - (j_lf + 2));
    }
    // L_d：movzx + 落值（0/1 恒快；dest 若静态 tagged 防御性清 0——结果行
    // 实际恒 untagged，见 mw_setup_tags 规则域）
    w8(b, p+cp, 68); w8(b, p+cp+1, 15); w8(b, p+cp+2, 182); w8(b, p+cp+3, 208); cp = cp + 4;  // movzx r10d, al
    cp = cp + e2_st(b, p+cp, 10, g2_slot(d));
    cp = cp + e2_mw_tag_clr(b, p+cp, d);
    w8(b, p+cp, 233); e2_w32(b, p+cp+1, resume - (p+cp+5)); cp = cp + 5;        // jmp rel32 → resume
    return cp;
}

// ── Byte encoding helpers ──
fn e2_w8(buf: string, pos: int, val: int) { store8(buf, pos, val % 256); }
fn e2_w16(buf: string, off: int, val: int) { w32(buf, off, val); }
fn e2_w32(buf: string, pos: int, val: int) -> int {
    w32(buf, pos, val);
    return 4;
}
fn e2_w64(buf: string, pos: int, val: int) -> int { w64(buf, pos, val); return 8; }

// ── Encoding primitives (computed, no magic numbers) ──
// REX byte: 0100 WRXB — computed from W/R/X/B flags (0 or 1 each)
fn emit_rex(buf: string, pos: int, W: int, R: int, X: int, B: int) -> int {
    e2_w8(buf, pos, 64 + W*8 + R*4 + X*2 + B); return 1;
}

// ModRM byte: mod<6:7> | reg<3:5> | rm<0:2>
fn emit_modrm(buf: string, pos: int, m: int, reg: int, rm: int) -> int {
    e2_w8(buf, pos, m*64 + reg*8 + rm); return 1;
}

// SIB byte: scale<6:7> | index<3:5> | base<0:2>
fn emit_sib(buf: string, pos: int, scale: int, index: int, base: int) -> int {
    e2_w8(buf, pos, scale*64 + index*8 + base); return 1;
}

fn e2_mov(b: string, p: int, d: int, s: int) -> int {
    // mov r64, r64 — opcode 0x89 MOV r/m, r, mod=3 (register)
    // REX: W=1, R=source>>3, B=dest>>3
    cp := p;
    cp = cp + emit_rex(b, cp, 1, s/8, 0, d/8);
    e2_w8(b, cp, 137); cp = cp + 1;  // opcode 0x89 MOV r/m, r
    cp = cp + emit_modrm(b, cp, 3, s%8, d%8);
    return cp - p;
}

fn e2_ld(b: string, p: int, r: int, o: int) -> int {
    // mov r64, [src] — opcode 0x8B MOV r, r/m, 3 addressing modes
    cp := p;
    if o >= E2_REG_SLOT_BASE {
        // Register-to-register: mov r_dest, r_src (copies value from alloc'd reg)
        src_reg := o - E2_REG_SLOT_BASE;
        return e2_mov(b, p, r, src_reg);
    }
    if o >= -128 && o <= 127 {
        // [rbp+disp8] (mod=01, rm=5)
        cp = cp + emit_rex(b, cp, 1, r/8, 0, 0);
        e2_w8(b, cp, 139); cp = cp + 1;
        cp = cp + emit_modrm(b, cp, 1, r%8, 5);
        e2_w8(b, cp, o); cp = cp + 1;
        return cp - p;
    }
    // [rbp+disp32] (mod=02, rm=5)
    cp = cp + emit_rex(b, cp, 1, r/8, 0, 0);
    e2_w8(b, cp, 139); cp = cp + 1;
    cp = cp + emit_modrm(b, cp, 2, r%8, 5);
    cp = cp + e2_w32(b, cp, o);
    return cp - p;
}


fn e2_st(b: string, p: int, r: int, o: int) -> int {
    // mov [dst], r64 — opcode 0x89 MOV r/m, r, 3 addressing modes
    if o >= E2_REG_SLOT_BASE {
        // register destination: use 3-operand mov (mod=3)
        dst_reg := o - E2_REG_SLOT_BASE;
        return e2_mov(b, p, dst_reg, r);
    }
    cp := p;
    cp = cp + emit_rex(b, cp, 1, r/8, 0, 0);  // REX.W + REX.R(if r>=8)
    e2_w8(b, cp, 137); cp = cp + 1;  // opcode 0x89 MOV r/m, r
    if o >= -128 && o <= 127 {
        cp = cp + emit_modrm(b, cp, 1, r%8, 5);
        e2_w8(b, cp, o); cp = cp + 1;
        return cp - p;
    }
    cp = cp + emit_modrm(b, cp, 2, r%8, 5);
    cp = cp + e2_w32(b, cp, o);
    return cp - p;
}

fn e2_li(b: string, p: int, o: int, v: int) -> int {
    cp := p;
    // mov [rbp+disp], imm64 — two-step for values outside signed 32-bit range
    if v < -2147483647 - 1 || v > 2147483647 {
        // Step 1: mov rax, imm64 (REX.W + 0xB8 MOV r, imm + rax + 8B imm)
        cp = cp + emit_rex(b, cp, 1, 0, 0, 0);
        e2_w8(b, cp, 184); cp = cp + 1;  // 0xB8 MOV r, imm (reg=0→rax)
        cp = cp + e2_w64(b, cp, v);
        // Step 2: mov [rbp+disp], rax (REX.W + 0x89 MOV r/m, r)
        cp = cp + emit_rex(b, cp, 1, 0, 0, 0);
        e2_w8(b, cp, 137); cp = cp + 1;
        if o >= -128 && o <= 127 {
            cp = cp + emit_modrm(b, cp, 1, 0, 5);
            e2_w8(b, cp, o); cp = cp + 1;
        } else {
            cp = cp + emit_modrm(b, cp, 2, 0, 5);
            cp = cp + e2_w32(b, cp, o);
        }
        return cp - p;
    }
    // mov [rbp+disp], imm32 — opcode 0xC7 MOV r/m, imm, sign-extended
    cp = cp + emit_rex(b, cp, 1, 0, 0, 0);
    e2_w8(b, cp, 199); cp = cp + 1;  // 0xC7 MOV r/m, imm32
    if o >= -128 && o <= 127 {
        cp = cp + emit_modrm(b, cp, 1, 0, 5);
        e2_w8(b, cp, o); cp = cp + 1;
        cp = cp + e2_w32(b, cp, v);
    } else {
        cp = cp + emit_modrm(b, cp, 2, 0, 5);
        cp = cp + e2_w32(b, cp, o);
        cp = cp + e2_w32(b, cp, v);
    }
    return cp - p;
}

fn e2_lr(b: string, p: int, rel: int) -> int {
    // lea r10, [rip + rel] — dest=r10, REX.R=1 since r10>=8
    cp := p;
    cp = cp + emit_rex(b, cp, 1, 1, 0, 0);
    e2_w8(b, cp, 141); cp = cp + 1;  // LEA opcode 0x8D
    cp = cp + emit_modrm(b, cp, 0, 2, 5);  // r10%8=2, rm=5=RIP-relative
    cp = cp + e2_w32(b, cp, rel);
    return cp - p;
}

fn e2_lrb(buf: string, p: int, rel: int) -> int {
    // lea r11, [rip + rel] — dest=r11, REX.R=1 since r11>=8
    cp := p;
    cp = cp + emit_rex(buf, cp, 1, 1, 0, 0);
    e2_w8(buf, cp, 141); cp = cp + 1;
    cp = cp + emit_modrm(buf, cp, 0, 3, 5);  // r11%8=3
    cp = cp + e2_w32(buf, cp, rel);
    return cp - p;
}

fn e2_lb(b: string, p: int, o: int) -> int {
    // lea r10, [rbp + offset]
    cp := p;
    cp = cp + emit_rex(b, cp, 1, 1, 0, 0);  // REX.W + REX.R (r10 >= 8)
    e2_w8(b, cp, 141); cp = cp + 1;  // LEA opcode 0x8D
    if o >= -128 && o <= 127 {
        cp = cp + emit_modrm(b, cp, 1, 2, 5);  // mod=01=[rbp+disp8], reg=2=r10%8, rm=5=rbp
        e2_w8(b, cp, o); cp = cp + 1;
    } else {
        cp = cp + emit_modrm(b, cp, 2, 2, 5);  // mod=10=[rbp+disp32]
        cp = cp + e2_w32(b, cp, o);
    }
    return cp - p;
}

fn e2_call(b: string, p: int, rel: int) -> int {
    // call rel32 — opcode 0xE8
    e2_w8(b, p, 232); e2_w32(b, p+1, rel); return 5;
}

fn e2_jmp(b: string, p: int, rel: int) -> int {
    // jmp rel32 — opcode 0xE9
    e2_w8(b, p, 233); e2_w32(b, p+1, rel); return 5;
}

fn e2_je(b: string, p: int, rel: int) -> int {
    // je rel32 near — 2-byte opcode 0x0F 0x84
    e2_w8(b, p, 15); e2_w8(b, p+1, 132); e2_w32(b, p+2, rel); return 6;
}

fn e2_jae(b: string, p: int, rel: int) -> int {
    // jae rel32 near — 2-byte opcode 0x0F 0x83
    e2_w8(b, p, 15); e2_w8(b, p+1, 131); e2_w32(b, p+2, rel); return 6;
}

fn e2_ptr_bounds_check(b: string, p: int, base_var: int, alloc_sz: int, access_width: int) -> int {
    if base_var < 0 || alloc_sz <= 0 { return 0; }
    width : ., mut = access_width;
    if width <= 0 { width = 8; }
    limit : ., mut = alloc_sz - width + 1;
    if limit < 0 { limit = 0; }

    cp : ., mut = 0;
    cp = cp + e2_load_var(b, p+cp, 11, base_var);
    // rax = pointer - allocation base; keep r10 intact for the access.
    cp = cp + emit_rex(b, p+cp, 1, 10/8, 0, 0);
    e2_w8(b, p+cp, 137); cp = cp + 1;
    cp = cp + emit_modrm(b, p+cp, 3, 10%8, 0);
    cp = cp + emit_rex(b, p+cp, 1, 11/8, 0, 0);
    e2_w8(b, p+cp, 41); cp = cp + 1;
    cp = cp + emit_modrm(b, p+cp, 3, 11%8, 0);
    // F17：limit ≥ 2³¹ 时 cmp imm32 符号扩展会把 limit 变负——无符号比较永不陷阱。
    // 改为 movabs rcx, imm64 + cmp rax, rcx（64 位无符号比较正确）。
    // movabs rcx, imm64 — REX.W 0x48 + 0xB9 + imm64
    e2_w8(b, p+cp, 72); e2_w8(b, p+cp+1, 185);
    e2_w64(b, p+cp+2, limit); cp = cp + 10;
    // cmp rax, rcx — REX.W 0x48 + 0x39 + ModRM(3, reg=1, rm=0)
    cp = cp + emit_rex(b, p+cp, 1, 0, 0, 0);
    e2_w8(b, p+cp, 57); cp = cp + 1;
    cp = cp + emit_modrm(b, p+cp, 3, 1, 0);
    crash_jmp_pos := p+cp;
    cp = cp + e2_jae(b, p+cp, 0);
    cp = cp + emit_rex(b, p+cp, 1, 10/8, 0, 10/8);
    e2_w8(b, p+cp, 133); cp = cp + 1;
    cp = cp + emit_modrm(b, p+cp, 3, 10%8, 10%8);
    safe_jmp_pos := p+cp;
    e2_w8(b, p+cp, 117); e2_w8(b, p+cp+1, 0); cp = cp + 2;
    e2_w8(b, p+cp, 15); e2_w8(b, p+cp+1, 11); cp = cp + 2;
    e2_w32(b, crash_jmp_pos + 2, (p+cp) - (crash_jmp_pos + 6) - 2);
    w8(b, safe_jmp_pos + 1, (p+cp) - (safe_jmp_pos + 2));
    return cp;
}

// F6：仅 null 陷阱（无分配信息时——s3=0 快速路径）。
// test r10, r10（REX.WRB 0x4D 0x85 0xD2）；null → ud2（SIGILL）
fn e2_ptr_null_check(b: string, p: int) -> int {
    cp := p;
    cp = cp + emit_rex(b, cp, 1, 10/8, 0, 10/8);
    e2_w8(b, cp, 133); cp = cp + 1;
    cp = cp + emit_modrm(b, cp, 3, 10%8, 10%8);
    e2_w8(b, cp, 117); e2_w8(b, cp+1, 2); cp = cp + 2;  // jne +2 (skip ud2)
    e2_w8(b, cp, 15); e2_w8(b, cp+1, 11); cp = cp + 2;  // ud2 (SIGILL)
    return cp - p;
}

// F14：movabs rdi, imm64 — REX.W 0x48 + 0xBF + imm64（64 位尺寸语义；
// 修复前 mov edi, imm32 对 ≥2³² 尺寸按 mod 2³² 回绕）
fn e2_movabs_rdi(b: string, p: int, v: int) -> int {
    e2_w8(b, p, 72); e2_w8(b, p+1, 191); e2_w64(b, p+2, v); return 10;
}
fn e2_alu(b: string, p: int, op: int) -> int {
    // ALU r/m, r: REX.W + REX.RB (r11, r10) + opcode + ModRM reg=11, rm=10
    cp := p;
    cp = cp + emit_rex(b, cp, 1, 1, 0, 1);  // W=1, R=1(r11/8), B=1(r10/8)
    e2_w8(b, cp, op); cp = cp + 1;
    cp = cp + emit_modrm(b, cp, 3, 11%8, 10%8);  // mod=3(register), reg=3, rm=2
    return cp - p;
}

// ── SSE2 double 运算（IEEE 754 标准，float 支持）──
// movsd xmm0, [rbp+disp] — F2 0F 10 /0
fn e2_sd_load(b: string, p: int, o: int) -> int {
    cp := p;
    w8(b, cp, 242); w8(b, cp+1, 15); w8(b, cp+2, 16); cp = cp + 3;
    if o >= -128 && o <= 127 {
        w8(b, cp, 69); w8(b, cp+1, o); cp = cp + 2;      // ModRM 01 000 101
    } else {
        w8(b, cp, 133); cp = cp + 1;                     // ModRM 10 000 101
        cp = cp + e2_w32(b, cp, o);
    }
    return cp - p;
}
// movsd xmm1, [rbp+disp] — F2 0F 10 /1
fn e2_sd_load1(b: string, p: int, o: int) -> int {
    cp := p;
    w8(b, cp, 242); w8(b, cp+1, 15); w8(b, cp+2, 16); cp = cp + 3;
    if o >= -128 && o <= 127 {
        w8(b, cp, 77); w8(b, cp+1, o); cp = cp + 2;      // ModRM 01 001 101
    } else {
        w8(b, cp, 141); cp = cp + 1;                     // ModRM 10 001 101
        cp = cp + e2_w32(b, cp, o);
    }
    return cp - p;
}
// movsd xmm{rn}, [rbp+disp] — F2 0F 10 /rn（rn=0..7，SysV float 参数）
fn e2_sd_load_x(b: string, p: int, o: int, rn: int) -> int {
    cp := p;
    w8(b, cp, 242); w8(b, cp+1, 15); w8(b, cp+2, 16); cp = cp + 3;
    if o >= -128 && o <= 127 {
        w8(b, cp, 64 + rn * 8 + 5); w8(b, cp+1, o); cp = cp + 2;
    } else {
        w8(b, cp, 128 + rn * 8 + 5); cp = cp + 1;
        cp = cp + e2_w32(b, cp, o);
    }
    return cp - p;
}

// 存返回值到 dest：dex（binary64，apx 快路径）→ movsd [slot], xmm0（SysV XMM0 返回）；int → rax
fn e2_store_ret(b: string, p: int, d: int) -> int {
    if d >= 0 && irv_type(d) == TI_DEX {
        return e2_sd_store(b, p, g2_slot(d));
    }
    return e2_st(b, p, 0, g2_slot(d));
}

// 压栈 binary64 值（8 字节，apx 快路径）：sub rsp,8 + movsd [rsp],xmm0
fn e2_push_xmm0(b: string, p: int) -> int {
    cp := p;
    w8(b, cp, 72); w8(b, cp+1, 131); w8(b, cp+2, 236); w8(b, cp+3, 8); cp = cp + 4;
    w8(b, cp, 242); w8(b, cp+1, 15); w8(b, cp+2, 17); w8(b, cp+3, 4); w8(b, cp+4, 36); cp = cp + 5;
    return cp - p;
}

fn e2_sd_cvt(b: string, p: int, o: int) -> int {
    cp := p;
    w8(b, cp, 242); w8(b, cp+1, 72); w8(b, cp+2, 15); w8(b, cp+3, 42); cp = cp + 4;
    if o >= -128 && o <= 127 {
        w8(b, cp, 69); w8(b, cp+1, o); cp = cp + 2;      // ModRM 01 000 101
    } else {
        w8(b, cp, 133); cp = cp + 1;                     // ModRM 10 000 101
        cp = cp + e2_w32(b, cp, o);
    }
    return cp - p;
}

// movsd [rbp+disp], xmm0 — F2 0F 11 /0
fn e2_sd_store(b: string, p: int, o: int) -> int {
    cp := p;
    w8(b, cp, 242); w8(b, cp+1, 15); w8(b, cp+2, 17); cp = cp + 3;
    if o >= -128 && o <= 127 {
        w8(b, cp, 69); w8(b, cp+1, o); cp = cp + 2;
    } else {
        w8(b, cp, 133); cp = cp + 1;
        cp = cp + e2_w32(b, cp, o);
    }
    return cp - p;
}

// ── emit_instr: write one instruction to buffer, return bytes written ──

fn e2_load_var(buf: string, pos: int, reg: int, var_idx: int) -> int {
    if var_idx >= 0 && r64(g_x86_is_global, var_idx * 8) != 0 {
        grow_rip_patch(g_x86_rip_patch_count + 1);
        w64(g_x86_rip_patch_pos, g_x86_rip_patch_count * 8, pos + 3);
        w64(g_x86_rip_patch_globals, g_x86_rip_patch_count * 8, var_idx);
        g_x86_rip_patch_count = g_x86_rip_patch_count + 1;
        sz := e2_lrb(buf, pos, 0);
        // mov reg, [r11] — memory load (NOT register copy; e2_ld + e2_rslot would misinterpret)
        cp2 := pos + sz;
        cp2 = cp2 + emit_rex(buf, cp2, 1, reg/8, 0, 11/8);
        e2_w8(buf, cp2, 139); cp2 = cp2 + 1;  // 0x8B MOV r, r/m
        cp2 = cp2 + emit_modrm(buf, cp2, 0, reg%8, 11%8);
        sz = cp2 - pos;
        return sz;
    }
    return e2_ld(buf, pos, reg, g2_slot(var_idx));
}

fn e2_rslot(r: int) -> int { return E2_REG_SLOT_BASE + r; }

fn sz_ofs(o: int) -> int {
    if o >= E2_REG_SLOT_BASE { return 3; }
    if o >= -128 && o <= 127 { return 4; }
    return 7;
}
fn sz_load_var(v: int) -> int {
    if v >= 0 && v < g_ir_var_count && g_str_count > 0 {
        if r64(g_x86_is_global, v * 8) != 0 { return sz_lr() + 3; }
    }
    return sz_ld(g2_slot(v));
}

fn emit_instr(instr_idx: int, buf: string, pos: int) -> int {
    op := iri_op(instr_idx); d := iri_dest(instr_idx); s1 := iri_s1(instr_idx); s2 := iri_s2(instr_idx); s3 := iri_s3(instr_idx); ti := iri_tk(instr_idx);
    cp := 0;

    if op == IR_NOP { return 0; }

    if op == IR_I2F && d >= 0 {
        // int → binary64：cvtsi2sd xmm0, [rbp+disp] — F2 0F 2A /0，然后 movsd 存回
        do2 := g2_slot(d);
        cp = cp + e2_sd_cvt(buf, pos+cp, g2_slot(s1));   // cvtsi2sd xmm0, [s1]
        cp = cp + e2_sd_store(buf, pos+cp, do2);
        return cp;
    }

    if op == IR_F2I && d >= 0 {
        // binary64 → int：movsd xmm0, [s1]；cvttsd2si rax, xmm0（F2 48 0F 2C C0，截断）；存回
        do2 := g2_slot(d);
        cp = cp + e2_sd_load(buf, pos+cp, g2_slot(s1));
        w8(buf, pos+cp, 242); w8(buf, pos+cp+1, 72); w8(buf, pos+cp+2, 15);
        w8(buf, pos+cp+3, 44); w8(buf, pos+cp+4, 192); cp = cp + 5;
        cp = cp + e2_st(buf, pos+cp, 0, do2);
        return cp;
    }

    if op == IR_CONST && d >= 0 {
        do2 := g2_slot(d);
        if ti == TI_STR {
            ro := g2_str_off(s1);
            // Record for post-emission patching (rodata position from Phase 3)
            grow_rodataref(g_x86_rodataref_count + 1);
            w64(g_x86_rodataref_pos, g_x86_rodataref_count * 8, pos + cp);
            w64(g_x86_rodataref_ro, g_x86_rodataref_count * 8, ro);
            g_x86_rodataref_count = g_x86_rodataref_count + 1;
            cp = cp + e2_lr(buf, pos+cp, 0);  // placeholder, patched later
            cp = cp + e2_st(buf, pos+cp, 10, do2);
        } else {
            cp = cp + e2_li(buf, pos+cp, do2, s1);
        }
        return cp;
    }

    if op == IR_BINARY {
        do2 := g2_slot(d);
        if ti == TI_DEX {
            // binary64 运算（SSE2 double，IEEE 754）——apx 快路径标准答案实现
            cp = cp + e2_sd_load(buf, pos+cp, g2_slot(s1));   // xmm0 = s1
            cp = cp + e2_sd_load1(buf, pos+cp, g2_slot(s2));  // xmm1 = s2
            // F2 0F 5x C1：addsd/subsd/mulsd/divsd xmm0, xmm1
            if s3 == OP_ADD { w8(buf, pos+cp, 242); w8(buf, pos+cp+1, 15); w8(buf, pos+cp+2, 88); w8(buf, pos+cp+3, 193); cp = cp + 4; }
            else if s3 == OP_SUB { w8(buf, pos+cp, 242); w8(buf, pos+cp+1, 15); w8(buf, pos+cp+2, 92); w8(buf, pos+cp+3, 193); cp = cp + 4; }
            else if s3 == OP_MUL { w8(buf, pos+cp, 242); w8(buf, pos+cp+1, 15); w8(buf, pos+cp+2, 89); w8(buf, pos+cp+3, 193); cp = cp + 4; }
            else if s3 == OP_DIV { w8(buf, pos+cp, 242); w8(buf, pos+cp+1, 15); w8(buf, pos+cp+2, 94); w8(buf, pos+cp+3, 193); cp = cp + 4; }
            if s3 >= OP_ADD && s3 <= OP_DIV {
                cp = cp + e2_sd_store(buf, pos+cp, do2);
            } else if s3 >= OP_EQ && s3 <= OP_GE {
                w8(buf, pos+cp, 102); w8(buf, pos+cp+1, 15); w8(buf, pos+cp+2, 47); w8(buf, pos+cp+3, 193); cp = cp + 4;
                if s3 == OP_EQ {
                    // setnp al（0F 9B C0）；sete cl（0F 94 C1）；and al, cl（20 C8）
                    w8(buf, pos+cp, 15); w8(buf, pos+cp+1, 155); w8(buf, pos+cp+2, 192); cp = cp + 3;
                    w8(buf, pos+cp, 15); w8(buf, pos+cp+1, 148); w8(buf, pos+cp+2, 193); cp = cp + 3;
                    w8(buf, pos+cp, 32); w8(buf, pos+cp+1, 200); cp = cp + 2;
                } else if s3 == OP_NE {
                    // setp al（0F 9A C0）；setne cl（0F 95 C1）；or al, cl（08 C8）
                    w8(buf, pos+cp, 15); w8(buf, pos+cp+1, 154); w8(buf, pos+cp+2, 192); cp = cp + 3;
                    w8(buf, pos+cp, 15); w8(buf, pos+cp+1, 149); w8(buf, pos+cp+2, 193); cp = cp + 3;
                    w8(buf, pos+cp, 8); w8(buf, pos+cp+1, 200); cp = cp + 2;
                } else {
                    // LT/GT/LE/GE 不动——硬件标志语义已正确（含无序时 LT/LE 为真）
                    sop : ., mut = 146;
                    if s3 == OP_GT { sop = 151; }   // seta（CF=0 && ZF=0）
                    else if s3 == OP_LE { sop = 150; }   // setbe
                    else if s3 == OP_GE { sop = 147; }   // setae
                    w8(buf, pos+cp, 15); w8(buf, pos+cp+1, sop); w8(buf, pos+cp+2, 192); cp = cp + 3;
                }
                // movzx r10d, al — 44 0F B6 D0
                w8(buf, pos+cp, 68); w8(buf, pos+cp+1, 15); w8(buf, pos+cp+2, 182); w8(buf, pos+cp+3, 208); cp = cp + 4;
                cp = cp + e2_st(buf, pos+cp, 10, do2);
            }
            return cp;
        }
        cp = cp + e2_load_var(buf, pos+cp, 10, s1);
        cp = cp + e2_load_var(buf, pos+cp, 11, s2);
        // int 多字 M1（Task 4）：消费者站点 tag 检查——操作数行 tagged 且站点
        // 属 2L 消费面（add/sub dest tagged = jo 同条件；比较任一操作数
        // tagged）→ 快路径前查 tag：任一操作数 2L（tag=1）→ 函数尾 2L 块
        // （128 位算术/比较，e2_mw_opnd_block）。untagged 行/站点零字节。
        // （tag 检查在操作数装载后——检查只写标志，不扰 r10/r11。）
        mw_oc : ., mut = -1;
        if (s3 == OP_ADD || s3 == OP_SUB) && g2_tag_off(d) != -1 || (s3 >= OP_EQ && s3 <= OP_GE) {
            if g2_tag_off(s1) != -1 {
                if mw_oc == -1 { mw_oc = mw_oc_new(s1, s2, d, s3); }
                cp = cp + e2_mw_oc_check(buf, pos+cp, mw_oc, 0, s1);
            }
            if s1 != s2 && g2_tag_off(s2) != -1 {
                if mw_oc == -1 { mw_oc = mw_oc_new(s1, s2, d, s3); }
                cp = cp + e2_mw_oc_check(buf, pos+cp, mw_oc, 1, s2);
            }
        }
        if s3 == OP_ADD         {
            cp = cp + e2_alu(buf, pos+cp, 1);
            // int 多字 M1（Task 2/3）：tagged dest 的 add/sub 后紧跟溢出跳
            // （e2_alu 的 OF 其后无任何写标志指令可再被读）→ 函数尾慢路径
            // 块。慢路径在快路径 store 之前跳走（块内自回存 dest 值 + 置 tag
            // 并跳回 store 之后继续——e2_mw_slow_block，elf.cr 函数尾按站点
            // 发射）。站点记录 dest 与 op（is_sub——高 limb 修正规则因 op 异）。
            if g2_tag_off(d) != -1 { cp = cp + e2_mw_jo(buf, pos+cp, d, 0); }
        }
        else if s3 == OP_SUB    {
            cp = cp + e2_alu(buf, pos+cp, 41);
            if g2_tag_off(d) != -1 { cp = cp + e2_mw_jo(buf, pos+cp, d, 1); }
        }
        else if s3 == OP_MUL    {
            // imul r10, r11 — 2-byte opcode 0x0F 0xAF
            cp = cp + emit_rex(buf, pos+cp, 1, 10/8, 0, 11/8);
            e2_w8(buf, pos+cp, 15); cp = cp + 1;
            e2_w8(buf, pos+cp, 175); cp = cp + 1;
            cp = cp + emit_modrm(buf, pos+cp, 3, 10%8, 11%8);
        }
        else if s3 == OP_SHL    {
            // mov rcx, r11; shl r10, cl
            cp = cp + emit_rex(buf, pos+cp, 1, 11/8, 0, 0);
            e2_w8(buf, pos+cp, 137); cp = cp + 1;
            cp = cp + emit_modrm(buf, pos+cp, 3, 11%8, 1);
            cp = cp + emit_rex(buf, pos+cp, 1, 0, 0, 10/8);
            e2_w8(buf, pos+cp, 211); cp = cp + 1;
            cp = cp + emit_modrm(buf, pos+cp, 3, 4, 10%8);
        }
        else if s3 == OP_SHR    {
            // mov rcx, r11; shr r10, cl
            cp = cp + emit_rex(buf, pos+cp, 1, 11/8, 0, 0);
            e2_w8(buf, pos+cp, 137); cp = cp + 1;
            cp = cp + emit_modrm(buf, pos+cp, 3, 11%8, 1);
            cp = cp + emit_rex(buf, pos+cp, 1, 0, 0, 10/8);
            e2_w8(buf, pos+cp, 211); cp = cp + 1;
            cp = cp + emit_modrm(buf, pos+cp, 3, 5, 10%8);
        }
        else if s3 == OP_PTR_ADD {  // p + n: scale n by element size (8), add to p
            // imul r11, 8, r11 — REX.WRB + 0x6B + ModRM(3, r11, r11) + imm8
            //（0x4D：reg 字段与 rm 同为 r11——R（reg）与 B（rm）都需置位）
            cp = cp + emit_rex(buf, pos+cp, 1, 11/8, 0, 11/8);
            e2_w8(buf, pos+cp, 107); cp = cp + 1;
            cp = cp + emit_modrm(buf, pos+cp, 3, 11%8, 11%8);
            e2_w8(buf, pos+cp, 8); cp = cp + 1;
            // add r10, r11
            cp = cp + e2_alu(buf, pos+cp, 1);
        }
        else if s3 == OP_PTR_SUB {  // p - n: scale n by element size (8), sub from p
            // imul r11, 8, r11
            cp = cp + emit_rex(buf, pos+cp, 1, 11/8, 0, 11/8);
            e2_w8(buf, pos+cp, 107); cp = cp + 1;
            cp = cp + emit_modrm(buf, pos+cp, 3, 11%8, 11%8);
            e2_w8(buf, pos+cp, 8); cp = cp + 1;
            // sub r10, r11
            cp = cp + e2_alu(buf, pos+cp, 41);
        }
        else if s3 == OP_PTR_DIFF {  // p - q: diff in bytes, then /8 → element count
            // sub r10, r11
            cp = cp + e2_alu(buf, pos+cp, 41);
            // sar r10, 3 — divide by 8
            cp = cp + emit_rex(buf, pos+cp, 1, 0, 0, 10/8);
            e2_w8(buf, pos+cp, 193); cp = cp + 1;  // 0xC1 SHIFT r/m, imm8
            cp = cp + emit_modrm(buf, pos+cp, 3, 7, 10%8);  // /7 = SAR
            e2_w8(buf, pos+cp, 3); cp = cp + 1;    // shift by 3
        }
        else if s3 == OP_DIV || s3 == OP_MOD {
            cp = cp + e2_mov(buf, pos+cp, 0, 10);
            // cqo: REX.W + 0x99
            cp = cp + emit_rex(buf, pos+cp, 1, 0, 0, 0); e2_w8(buf, pos+cp, 153); cp = cp + 1;
            // idiv r11: REX.WB + 0xF7 + /7
            cp = cp + emit_rex(buf, pos+cp, 1, 0, 0, 11/8); e2_w8(buf, pos+cp, 247); cp = cp + 1; cp = cp + emit_modrm(buf, pos+cp, 3, 7, 11%8);
            if s3 == OP_DIV { cp = cp + e2_mov(buf, pos+cp, 10, 0); } else { cp = cp + e2_mov(buf, pos+cp, 10, 2); }
        }
        else if s3 >= OP_EQ && s3 <= OP_GE {
            cp = cp + e2_alu(buf, pos+cp, 57);  // cmp
            sop := 148; if s3 == OP_NE { sop = 149; } else if s3 == OP_LT { sop = 156; } else if s3 == OP_GT { sop = 159; } else if s3 == OP_LE { sop = 158; } else if s3 == OP_GE { sop = 157; }
            // SETcc al — 2-byte opcode 0x0F 0x9x
            e2_w8(buf, pos+cp, 15); cp = cp + 1; e2_w8(buf, pos+cp, sop); cp = cp + 1; cp = cp + emit_modrm(buf, pos+cp, 3, 0, 0);
            // movzx r10d, al — REX.R + 0x0FB6（rm=al 无需 B——R 只因 reg=r10）
            cp = cp + emit_rex(buf, pos+cp, 0, 10/8, 0, 0); e2_w8(buf, pos+cp, 15); cp = cp + 1; e2_w8(buf, pos+cp, 182); cp = cp + 1; cp = cp + emit_modrm(buf, pos+cp, 3, 10%8, 0);
        }
        else if s3 == OP_AND { cp = cp + e2_alu(buf, pos+cp, 33); }
        else if s3 == OP_OR  { cp = cp + e2_alu(buf, pos+cp, 9); }
        cp = cp + e2_st(buf, pos+cp, 10, do2);
        // int 多字 M1（Task 4）tag 卫生①：快路径 64 位定值点 tag 清 0——
        // 快值落 tagged 槽后 tag 必须为 0（否则回边再执行时 stale tag=1 会
        // 把快值当 2-limb 指针读）。jo/2L 块跳 resume 在此之后——慢路径自
        // 写 tag=1，不被本条清除（resume 位于本条之后）。dest untagged →
        // 零字节（mul/shl/…/非 add-sub 的 tagged dest 不存在——防御兜底）。
        cp = cp + e2_mw_tag_clr(buf, pos+cp, d);
        return cp;
    }

    if op == IR_UNARY && d >= 0 {
        do2 := g2_slot(d);
        cp = cp + e2_load_var(buf, pos+cp, 10, s1);
        if s3 == UOP_NEG {
            // neg r10: REX.WB + 0xF7 + /3
            cp = cp + emit_rex(buf, pos+cp, 1, 0, 0, 10/8); e2_w8(buf, pos+cp, 247); cp = cp + 1; cp = cp + emit_modrm(buf, pos+cp, 3, 3, 10%8);
        }
        else if s3 == UOP_NOT {
            // test r10, r10 (REX.WRB + 0x85)
            cp = cp + emit_rex(buf, pos+cp, 1, 10/8, 0, 10/8); e2_w8(buf, pos+cp, 133); cp = cp + 1; cp = cp + emit_modrm(buf, pos+cp, 3, 10%8, 10%8);
            // sete al (0x0F 0x94)
            e2_w8(buf, pos+cp, 15); cp = cp + 1; e2_w8(buf, pos+cp, 148); cp = cp + 1; cp = cp + emit_modrm(buf, pos+cp, 3, 0, 0);
            // movzx r10, al
            cp = cp + emit_rex(buf, pos+cp, 0, 10/8, 0, 0); e2_w8(buf, pos+cp, 15); cp = cp + 1; e2_w8(buf, pos+cp, 182); cp = cp + 1; cp = cp + emit_modrm(buf, pos+cp, 3, 10%8, 0);
        }
        cp = cp + e2_st(buf, pos+cp, 10, do2);
        return cp;
    }

    if op == IR_CALL {
        fa := s1; ac := s2;
        // SysV AMD64 参数分派：int 用 ir（0-5 → rdi,rsi,rdx,rcx,r8,r9），
        // binary64 参数用 fr（0-7 → xmm0-7），各自独立编号（标准答案）
        // 第一遍：寄存器参数（位置顺序，左到右）
        ir_cnt : ., mut = 0; fr_cnt : ., mut = 0;
        ai := 0;
        loop { if ai >= ac { break; }
            pt := irv_type(fa + ai);
            if pt == TI_DEX {
                if fr_cnt < 8 {
                    cp = cp + e2_sd_load_x(buf, pos+cp, g2_slot(fa + ai), fr_cnt);
                    fr_cnt = fr_cnt + 1;
                }
            } else {
                if ir_cnt < 6 {
                    r := -1;
                    if ir_cnt == 0 { r = 7; } if ir_cnt == 1 { r = 6; } if ir_cnt == 2 { r = 2; }
                    if ir_cnt == 3 { r = 1; } if ir_cnt == 4 { r = 8; } if ir_cnt == 5 { r = 9; }
                    cp = cp + e2_load_var(buf, pos+cp, r, fa + ai);
                    ir_cnt = ir_cnt + 1;
                }
            }
        ai = ai + 1; }
        // 第二遍：栈参数（右到左压，第 7 个 int / 第 9 个 binary64 超限才压）
        stack_total : ., mut = 0;
        stack_ai : ., mut = ac - 1;
        loop {
            if stack_ai < 0 { break; }
            ic2 : ., mut = 0; fc2 : ., mut = 0;
            j2 : ., mut = 0;
            loop { if j2 >= stack_ai { break; }
                if irv_type(fa + j2) == TI_DEX { fc2 = fc2 + 1; } else { ic2 = ic2 + 1; }
                j2 = j2 + 1; }
            if irv_type(fa + stack_ai) == TI_DEX {
                if fc2 >= 8 {
                    cp = cp + e2_sd_load_x(buf, pos+cp, g2_slot(fa + stack_ai), 0);
                    cp = cp + e2_push_xmm0(buf, pos+cp);
                    stack_total = stack_total + 1;
                }
            } else {
                if ic2 >= 6 {
                    cp = cp + e2_load_var(buf, pos+cp, 10, fa + stack_ai);
                    e2_w8(buf, pos+cp, 65); e2_w8(buf, pos+cp+1, 82); cp = cp + 2;  // push r10
                    stack_total = stack_total + 1;
                }
            }
            stack_ai = stack_ai - 1;
        }
        // Match builtins by interned string index (integer compare, no str_eq)
        if s3 == g_ni_syscall3 {
            cp = cp + e2_mov(buf, pos+cp, 0, 7);
            cp = cp + e2_mov(buf, pos+cp, 7, 6);
            cp = cp + e2_mov(buf, pos+cp, 6, 2);
            cp = cp + e2_mov(buf, pos+cp, 2, 1);
            // syscall: 2-byte 0x0F 0x05
            e2_w8(buf, pos+cp, 15); e2_w8(buf, pos+cp+1, 5); cp = cp + 2;
            if d >= 0 { cp = cp + e2_store_ret(buf, pos+cp, d); }
        } else if s3 == g_ni_syscall4 {
            // syscall4(num, a, b, c, d)——第 4 参 d 经 r10 传递（x86-64 syscall
            // 约定：第 4 参在 r10；rcx 被 syscall 指令用作返回地址）。
            // I-2：wait4 的 rusage 此前无第 4 参通道——通用装载器把第 4 参放
            // rcx（ir_cnt=3）、第 5 参放 r8（ir_cnt=4），syscall 读 r10 = 残留
            // 垃圾 → 内核 EFAULT 或写错地址 → 退出码传播不可靠。
            cp = cp + e2_mov(buf, pos+cp, 0, 7);   // rax = rdi — syscall number
            cp = cp + e2_mov(buf, pos+cp, 7, 6);   // rdi = rsi — arg1
            cp = cp + e2_mov(buf, pos+cp, 6, 2);   // rsi = rdx — arg2
            cp = cp + e2_mov(buf, pos+cp, 2, 1);   // rdx = rcx — arg3
            cp = cp + e2_mov(buf, pos+cp, 10, 8);  // r10 = r8  — arg4
            // syscall: 2-byte 0x0F 0x05
            e2_w8(buf, pos+cp, 15); e2_w8(buf, pos+cp+1, 5); cp = cp + 2;
            if d >= 0 { cp = cp + e2_store_ret(buf, pos+cp, d); }
        } else if s3 == g_ni_load8 {
            // movzx rax, byte [rdi+rsi] — REX.W + 0x0FB6 + SIB
            cp = cp + emit_rex(buf, pos+cp, 1, 0, 0, 0); e2_w8(buf, pos+cp, 15); cp = cp + 1; e2_w8(buf, pos+cp, 182); cp = cp + 1;
            cp = cp + emit_modrm(buf, pos+cp, 0, 0, 4); cp = cp + emit_sib(buf, pos+cp, 0, 6, 7);
            if d >= 0 { cp = cp + e2_store_ret(buf, pos+cp, d); }
        } else if s3 == g_ni_store8 {
            // mov [rdi+rsi], dl — 0x88 + SIB (3rd arg in rdx = register 2)
            e2_w8(buf, pos+cp, 136); cp = cp + 1; cp = cp + emit_modrm(buf, pos+cp, 0, 2, 4); cp = cp + emit_sib(buf, pos+cp, 0, 6, 7);
        } else if s3 == g_ni_load64 || s3 == g_ni_load_str_ptr || s3 == g_ni_r64 {
            // mov rax, [rdi + rsi]
            // mov rax, [rdi+rsi] — REX.W + 0x8B + SIB
            cp = cp + emit_rex(buf, pos+cp, 1, 0, 0, 0); e2_w8(buf, pos+cp, 139); cp = cp + 1;
            cp = cp + emit_modrm(buf, pos+cp, 0, 0, 4); cp = cp + emit_sib(buf, pos+cp, 0, 6, 7);
            if d >= 0 { cp = cp + e2_store_ret(buf, pos+cp, d); }
        } else if s3 == g_ni_store_str_ptr {
            // mov [rdi + rsi], rdx
            // mov [rdi+rsi], rdx — REX.W + 0x89 + SIB
            cp = cp + emit_rex(buf, pos+cp, 1, 0, 0, 0); e2_w8(buf, pos+cp, 137); cp = cp + 1;
            cp = cp + emit_modrm(buf, pos+cp, 0, 2, 4); cp = cp + emit_sib(buf, pos+cp, 0, 6, 7);
        } else if s3 == g_ni_get_arg && gv_argv >= 0 {
            // Convert C argv[n] into a Core string with the hidden length header.
            // NB: gv_argv must be >= 0 (g_rt_argv_ptr registered as a global).
            // If it's -1, fall through to regular call path — the LEA displacement
            // would be registered as a rip_patch with gvi=-1 and SKIPPED by the
            // patch loop, leaving displacement=0 and causing GPF on dereference.
            grow_rip_patch(g_x86_rip_patch_count + 1);
            w64(g_x86_rip_patch_pos, g_x86_rip_patch_count * 8, pos + cp + 3);
            w64(g_x86_rip_patch_globals, g_x86_rip_patch_count * 8, gv_argv);
            g_x86_rip_patch_count = g_x86_rip_patch_count + 1;
            cp = cp + e2_lr(buf, pos+cp, 0);  // lea r10, [rip+0] placeholder
            // mov r10, [r10] — REX.WRB + 0x8B
            cp = cp + emit_rex(buf, pos+cp, 1, 10/8, 0, 10/8); e2_w8(buf, pos+cp, 139); cp = cp + 1; cp = cp + emit_modrm(buf, pos+cp, 0, 10%8, 10%8);  // mov r10, [r10]
            // mov r10, [r10 + rdi*8] — SIB(scale=3, index=rdi%8, base=r10%8)
            cp = cp + emit_rex(buf, pos+cp, 1, 10/8, 0, 10/8); e2_w8(buf, pos+cp, 139); cp = cp + 1;
            cp = cp + emit_modrm(buf, pos+cp, 0, 10%8, 4); cp = cp + emit_sib(buf, pos+cp, 3, 7, 10%8);
            // test r10, r10 — REX.WRB + 0x85
            cp = cp + emit_rex(buf, pos+cp, 1, 10/8, 0, 10/8); e2_w8(buf, pos+cp, 133); cp = cp + 1; cp = cp + emit_modrm(buf, pos+cp, 3, 10%8, 10%8);
            e2_w8(buf, pos+cp, 117); e2_w8(buf, pos+cp+1, 18); cp = cp + 2;  // jne valid

            e2_w8(buf, pos+cp, 191); e2_w32(buf, pos+cp+1, 1); cp = cp + 5;  // mov edi, 1
            grow_alloc_patch(g_x86_alloc_patch_count + 1); w64(g_x86_alloc_patch_pos, g_x86_alloc_patch_count * 8, pos + cp);
            g_x86_alloc_patch_count = g_x86_alloc_patch_count + 1;
            e2_w8(buf, pos+cp, 232); e2_w32(buf, pos+cp+1, 0); cp = cp + 5;  // call alloc
            // mov byte [rax], 0 — 0xC6 /0
            e2_w8(buf, pos+cp, 198); cp = cp + 1; cp = cp + emit_modrm(buf, pos+cp, 0, 0, 0); e2_w8(buf, pos+cp, 0); cp = cp + 1;
            cp = cp + e2_jmp(buf, pos+cp, 47);

            // xor edi, edi
            e2_w8(buf, pos+cp, 49); e2_w8(buf, pos+cp+1, 255); cp = cp + 2;
            // cmp byte [r10+rdi], 0 — 0x80 /7 + SIB
            cp = cp + emit_rex(buf, pos+cp, 0, 0, 0, 10/8); e2_w8(buf, pos+cp, 128); cp = cp + 1;
            cp = cp + emit_modrm(buf, pos+cp, 0, 7, 4); cp = cp + emit_sib(buf, pos+cp, 0, 7, 10%8); e2_w8(buf, pos+cp, 0); cp = cp + 1;
            e2_w8(buf, pos+cp, 116); e2_w8(buf, pos+cp+1, 8); cp = cp + 2;  // je len_done
            // inc rdi — REX.W + 0xFF /0
            cp = cp + emit_rex(buf, pos+cp, 1, 0, 0, 0); e2_w8(buf, pos+cp, 255); cp = cp + 1; cp = cp + emit_modrm(buf, pos+cp, 3, 0, 7);
            cp = cp + e2_jmp(buf, pos+cp, -15);
            // inc rdi (null terminator) — REX.W + 0xFF /0
            cp = cp + emit_rex(buf, pos+cp, 1, 0, 0, 0); e2_w8(buf, pos+cp, 255); cp = cp + 1; cp = cp + emit_modrm(buf, pos+cp, 3, 0, 7);
            // alloc clobbers caller-saved r10; preserve the argv[n] source pointer.
            e2_w8(buf, pos+cp, 65); e2_w8(buf, pos+cp+1, 82); cp = cp + 2;  // push r10
            grow_alloc_patch(g_x86_alloc_patch_count + 1); w64(g_x86_alloc_patch_pos, g_x86_alloc_patch_count * 8, pos + cp);
            g_x86_alloc_patch_count = g_x86_alloc_patch_count + 1;
            e2_w8(buf, pos+cp, 232); e2_w32(buf, pos+cp+1, 0); cp = cp + 5;  // call alloc
            e2_w8(buf, pos+cp, 65); e2_w8(buf, pos+cp+1, 90); cp = cp + 2;  // pop r10
            // xor r11d, r11d — REX.RB + 0x31
            cp = cp + emit_rex(buf, pos+cp, 0, 11/8, 0, 11/8); e2_w8(buf, pos+cp, 49); cp = cp + 1; cp = cp + emit_modrm(buf, pos+cp, 3, 11%8, 11%8);
            // mov dl, [r10+r11] — 0x8A + SIB (REX.X=1 for r11 index)
            cp = cp + emit_rex(buf, pos+cp, 0, 0, 11/8, 10/8); e2_w8(buf, pos+cp, 138); cp = cp + 1;
            cp = cp + emit_modrm(buf, pos+cp, 0, 2, 4); cp = cp + emit_sib(buf, pos+cp, 0, 11%8, 10%8);
            // mov [rax+r11], dl — 0x88 + SIB (REX.X=1 for r11 index)
            cp = cp + emit_rex(buf, pos+cp, 0, 0, 11/8, 0); e2_w8(buf, pos+cp, 136); cp = cp + 1;
            cp = cp + emit_modrm(buf, pos+cp, 0, 2, 4); cp = cp + emit_sib(buf, pos+cp, 0, 11%8, 0);
            // inc r11 — REX.WB + 0xFF /0
            cp = cp + emit_rex(buf, pos+cp, 0, 0, 0, 11/8); e2_w8(buf, pos+cp, 255); cp = cp + 1; cp = cp + emit_modrm(buf, pos+cp, 3, 0, 11%8);
            // test dl, dl
            e2_w8(buf, pos+cp, 132); cp = cp + 1; cp = cp + emit_modrm(buf, pos+cp, 3, 2, 2);
            e2_w8(buf, pos+cp, 117); e2_w8(buf, pos+cp+1, 241); cp = cp + 2;  // jne copy_loop
            if d >= 0 { cp = cp + e2_store_ret(buf, pos+cp, d); }
        } else if s3 == g_ni_w64 {
            // w64(buf, pos, val) → mov [rsi+rdi??], rdx
            // Actually args: rdi=buf, rsi=pos, rdx=val
            // Just: mov [rdi+rsi], rdx
            cp = cp + emit_rex(buf, pos+cp, 1, 0, 0, 0); e2_w8(buf, pos+cp, 137); cp = cp + 1;
            cp = cp + emit_modrm(buf, pos+cp, 0, 2, 4); cp = cp + emit_sib(buf, pos+cp, 0, 6, 7);
        } else if s3 == g_ni_dyncpy {
            // _dyncpy(src, n, dst) → memcpy(dst, src, n)
            // rdi=src, rsi=n, rdx=dst
            // Loop: for(i=0; i<n; i++) store8(dst,i,load8(src,i))
            // i in rcx
            e2_w8(buf, pos+cp, 49); e2_w8(buf, pos+cp+1, 201); cp = cp + 2;  // xor ecx, ecx
            // loop:
            //   cmp rcx, rsi → jae done
            e2_w8(buf, pos+cp, 72); e2_w8(buf, pos+cp+1, 57); e2_w8(buf, pos+cp+2, 241); cp = cp + 3;  // cmp rcx, rsi
            e2_w8(buf, pos+cp, 115); e2_w8(buf, pos+cp+1, 11); cp = cp + 2;  // jae done (+11)
            //   mov al, [rdi+rcx]   (load8)
            e2_w8(buf, pos+cp, 138); cp = cp + 1;  // 0x8A MOV r8, r/m8
            cp = cp + emit_modrm(buf, pos+cp, 0, 0, 4);  // [SIB]
            cp = cp + emit_sib(buf, pos+cp, 0, 1, 7);  // [rcx][rdi]
            //   mov [rdx+rcx], al   (store8)
            e2_w8(buf, pos+cp, 136); cp = cp + 1;  // 0x88 MOV r/m8, r8
            cp = cp + emit_modrm(buf, pos+cp, 0, 0, 4);
            cp = cp + emit_sib(buf, pos+cp, 0, 1, 2);  // [rcx][rdx]
            //   inc rcx → jmp loop
            e2_w8(buf, pos+cp, 72); e2_w8(buf, pos+cp+1, 255); e2_w8(buf, pos+cp+2, 193); cp = cp + 3;  // inc rcx
            e2_w8(buf, pos+cp, 235); e2_w8(buf, pos+cp+1, 240); cp = cp + 2;  // jmp -16 (back to cmp rcx,rsi)
            // done:
        } else if s3 == g_ni_goroutine_wrapper_addr {
            // goroutine_wrapper_addr() — the address of goroutine_entry_wrapper
            // (backend-emitted stub / rt.s). Same encoding as IR_FNADDR:
            // movabs r10, imm64 + store; imm64 patched in elf.cr Phase 3.
            do2 := g2_slot(d);
            grow_fnaddr_patch(g_x86_fnaddr_patch_count + 1);
            w64(g_x86_fnaddr_patch_pos, g_x86_fnaddr_patch_count * 8, pos + cp);
            w64(g_x86_fnaddr_patch_name, g_x86_fnaddr_patch_count * 8, str_intern("goroutine_entry_wrapper"));
            g_x86_fnaddr_patch_count = g_x86_fnaddr_patch_count + 1;
            // movabs r10, imm64: REX.W+B = 0x49, opcode 0xBA (0xB8 + reg 2)
            e2_w8(buf, pos+cp, 73); e2_w8(buf, pos+cp+1, 186);
            e2_w64(buf, pos+cp+2, 0);  // placeholder — patched in elf.cr Phase 3
            cp = cp + 10;
            cp = cp + e2_st(buf, pos+cp, 10, do2);
        } else if s3 >= 0 {
            fn2 := istr_get(s3);
            to := -1; tf := 0;
            loop { if tf >= g_x86_func_off_count { break; } if str_eq(istr_get(r64(g_x86_func_offsets, tf*16)), fn2) != 0 { to = r64(g_x86_func_offsets, tf*16+8); break; } tf = tf + 1; }
                        // Record call position for post-emission patching
            grow_call_patch(g_x86_call_patch_count + 1);
            w64(g_x86_call_patch_pos, g_x86_call_patch_count * 8, pos + cp);
            w64(g_x86_call_patch_name, g_x86_call_patch_count * 8, str_intern(fn2));
            g_x86_call_patch_count = g_x86_call_patch_count + 1;
            if to >= 0 {
                cp = cp + e2_call(buf, pos+cp, (176 + to) - (pos + cp + 5));
            } else {
                // Unknown function: emit external relocation (for dynamic linking)
                grow_ext_rel(g_x86_ext_rel_count + 1);
                w64(g_x86_ext_rel_pos, g_x86_ext_rel_count * 8, pos + cp + 1);
                w64(g_x86_ext_rel_name, g_x86_ext_rel_count * 8, s3);
                g_x86_ext_rel_count = g_x86_ext_rel_count + 1;
                cp = cp + e2_call(buf, pos+cp, 0);
            }
            if d >= 0 { cp = cp + e2_store_ret(buf, pos+cp, d); }
        } else {
            // xor eax, eax
            e2_w8(buf, pos+cp, 49); e2_w8(buf, pos+cp+1, 192); cp = cp + 2;
            if d >= 0 { cp = cp + e2_store_ret(buf, pos+cp, d); }
        }
        stack_count := stack_total;   // 实际压栈数（int 超 6 + float 超 8）
        if stack_count > 0 {
            stack_bytes := stack_count * 8;
            if stack_bytes <= 127 {
                e2_w8(buf, pos+cp, 72); e2_w8(buf, pos+cp+1, 131);
                e2_w8(buf, pos+cp+2, 196); e2_w8(buf, pos+cp+3, stack_bytes); cp = cp + 4;
            } else {
                e2_w8(buf, pos+cp, 72); e2_w8(buf, pos+cp+1, 129); e2_w8(buf, pos+cp+2, 196);
                e2_w32(buf, pos+cp+3, stack_bytes); cp = cp + 7;
            }
        }
        return cp;
    }

    if op == IR_CALL_EXTERN {
        do2 := g2_slot(d);
        name_ni := s1;
        // F16①：装载参数（s2=首参、s3=参数个数，SysV AMD64 约定：
        // int rdi,rsi,rdx,rcx,r8,r9；float xmm0-7）——修复前 call 前无任何装载。
        fa2 := s2; ac2 := s3;
        ir_cnt2 : ., mut = 0; fr_cnt2 : ., mut = 0;
        ai2 : ., mut = 0;
        loop { if ai2 >= ac2 { break; }
            pt2 := irv_type(fa2 + ai2);
            if pt2 == TI_DEX {
                if fr_cnt2 < 8 {
                    cp = cp + e2_sd_load_x(buf, pos+cp, g2_slot(fa2 + ai2), fr_cnt2);
                    fr_cnt2 = fr_cnt2 + 1;
                }
            } else {
                if ir_cnt2 < 6 {
                    r2 := -1;
                    if ir_cnt2 == 0 { r2 = 7; } if ir_cnt2 == 1 { r2 = 6; } if ir_cnt2 == 2 { r2 = 2; }
                    if ir_cnt2 == 3 { r2 = 1; } if ir_cnt2 == 4 { r2 = 8; } if ir_cnt2 == 5 { r2 = 9; }
                    cp = cp + e2_load_var(buf, pos+cp, r2, fa2 + ai2);
                    ir_cnt2 = ir_cnt2 + 1;
                }
            }
            ai2 = ai2 + 1;
        }
        // Record external relocation
        grow_ext_rel(g_x86_ext_rel_count + 1);
        w64(g_x86_ext_rel_pos, g_x86_ext_rel_count * 8, pos + cp);
        w64(g_x86_ext_rel_name, g_x86_ext_rel_count * 8, name_ni);
        g_x86_ext_rel_count = g_x86_ext_rel_count + 1;
        // Emit call placeholder (E8 + rel32 = 0, patched later)
        e2_w8(buf, pos+cp, 232); e2_w32(buf, pos+cp+1, 0); cp = cp + 5;
        // Store return value from rax
        cp = cp + e2_st(buf, pos+cp, 0, do2);
        return cp;
    }

    if op == IR_HOTPATCH_ROUTE {
        do2 := g2_slot(d);
        name_ni := s1;
        grow_call_patch(g_x86_call_patch_count + 1);
        w64(g_x86_call_patch_pos, g_x86_call_patch_count * 8, pos + cp);
        w64(g_x86_call_patch_name, g_x86_call_patch_count * 8, name_ni);
        g_x86_call_patch_count = g_x86_call_patch_count + 1;
        e2_w8(buf, pos+cp, 232); e2_w32(buf, pos+cp+1, 0); cp = cp + 5;
        cp = cp + e2_st(buf, pos+cp, 0, do2);
        return cp;
    }

    if op == IR_SPAWN {
        do2 := g2_slot(d);
        // F4：操作数约定对齐——s1=首参、s2=参数个数、s3=函数名 ni
        // （ir_gen L939 发射 `emit(IR_SPAWN, dest2, val_var, 1, func_ni, -1)`；
        //  interp 同用 s3 查函数名。修复前 `name_ni := s1` 拿参数变量索引当
        //  函数名查表 → 补丁失败 → call rel32=0 → 栈不平衡 → SIGSEGV 139。）
        name_ni := s3;
        // F4：补参数装载——与 IR_CALL 完全相同的 SysV AMD64 分派
        // （int: rdi,rsi,rdx,rcx,r8,r9 + 栈超限；float: xmm0-7）。
        fa := s1; ac := s2;
        ir_cnt : ., mut = 0; fr_cnt : ., mut = 0;
        ai := 0;
        loop { if ai >= ac { break; }
            pt := irv_type(fa + ai);
            if pt == TI_DEX {
                if fr_cnt < 8 {
                    cp = cp + e2_sd_load_x(buf, pos+cp, g2_slot(fa + ai), fr_cnt);
                    fr_cnt = fr_cnt + 1;
                }
            } else {
                if ir_cnt < 6 {
                    r := -1;
                    if ir_cnt == 0 { r = 7; } if ir_cnt == 1 { r = 6; } if ir_cnt == 2 { r = 2; }
                    if ir_cnt == 3 { r = 1; } if ir_cnt == 4 { r = 8; } if ir_cnt == 5 { r = 9; }
                    cp = cp + e2_load_var(buf, pos+cp, r, fa + ai);
                    ir_cnt = ir_cnt + 1;
                }
            }
        ai = ai + 1; }
        // 栈参数（右到左压，第 7 个 int / 第 9 个 float 超限才压）——同 IR_CALL
        stack_total : ., mut = 0;
        stack_ai : ., mut = ac - 1;
        loop {
            if stack_ai < 0 { break; }
            ic2 : ., mut = 0; fc2 : ., mut = 0;
            j2 : ., mut = 0;
            loop { if j2 >= stack_ai { break; }
                if irv_type(fa + j2) == TI_DEX { fc2 = fc2 + 1; } else { ic2 = ic2 + 1; }
                j2 = j2 + 1; }
            if irv_type(fa + stack_ai) == TI_DEX {
                if fc2 >= 8 {
                    cp = cp + e2_sd_load_x(buf, pos+cp, g2_slot(fa + stack_ai), 0);
                    cp = cp + e2_push_xmm0(buf, pos+cp);
                    stack_total = stack_total + 1;
                }
            } else {
                if ic2 >= 6 {
                    cp = cp + e2_load_var(buf, pos+cp, 10, fa + stack_ai);
                    e2_w8(buf, pos+cp, 65); e2_w8(buf, pos+cp+1, 82); cp = cp + 2;  // push r10
                    stack_total = stack_total + 1;
                }
            }
            stack_ai = stack_ai - 1;
        }
        // Emit call to function + store result (single-threaded approximation)
        grow_call_patch(g_x86_call_patch_count + 1);
        w64(g_x86_call_patch_pos, g_x86_call_patch_count * 8, pos + cp);
        w64(g_x86_call_patch_name, g_x86_call_patch_count * 8, name_ni);
        g_x86_call_patch_count = g_x86_call_patch_count + 1;
        e2_w8(buf, pos+cp, 232); e2_w32(buf, pos+cp+1, 0); cp = cp + 5;
        // 栈清理（call 后恢复 rsp）——同 IR_CALL
        stack_count := stack_total;
        if stack_count > 0 {
            stack_bytes := stack_count * 8;
            if stack_bytes <= 127 {
                e2_w8(buf, pos+cp, 72); e2_w8(buf, pos+cp+1, 131);
                e2_w8(buf, pos+cp+2, 196); e2_w8(buf, pos+cp+3, stack_bytes); cp = cp + 4;
            } else {
                e2_w8(buf, pos+cp, 72); e2_w8(buf, pos+cp+1, 129); e2_w8(buf, pos+cp+2, 196);
                e2_w32(buf, pos+cp+3, stack_bytes); cp = cp + 7;
            }
        }
        if d >= 0 && irv_type(d) == TI_DEX {
            cp = cp + e2_sd_store(buf, pos+cp, do2);
        } else {
            cp = cp + e2_st(buf, pos+cp, 0, do2);
        }
        return cp;
    }

    if op == IR_FNADDR {
        // Load function address into dest: movabs r10, imm64 + store.
        // The imm64 is a placeholder patched in Phase 3 (after all functions
        // are placed) with the function's absolute VA (TEXT_BASE + buf pos).
        do2 := g2_slot(d);
        name_ni := s1;
        grow_fnaddr_patch(g_x86_fnaddr_patch_count + 1);
        w64(g_x86_fnaddr_patch_pos, g_x86_fnaddr_patch_count * 8, pos + cp);
        w64(g_x86_fnaddr_patch_name, g_x86_fnaddr_patch_count * 8, name_ni);
        g_x86_fnaddr_patch_count = g_x86_fnaddr_patch_count + 1;
        // movabs r10, imm64: REX.W+B = 0x49, opcode 0xBA (0xB8 + reg 2,
        // REX.B extends to 10 = r10). 0x49 0xBB would encode r11 — the
        // following e2_st(..., 10, ...) stores r10, so the register MUST be r10.
        e2_w8(buf, pos+cp, 73); e2_w8(buf, pos+cp+1, 186);  // movabs r10, imm64
        e2_w64(buf, pos+cp+2, 0);  // placeholder — patched in elf.cr Phase 3
        cp = cp + 10;
        cp = cp + e2_st(buf, pos+cp, 10, do2);
        return cp;
    }

    if op == IR_RETURN {
        if s1 >= 0 {
            if irv_type(s1) == TI_DEX {
                // binary64 返回：movsd xmm0, [slot]（SysV 返回值在 XMM0，apx 快路径）
                cp = cp + e2_sd_load(buf, pos+cp, g2_slot(s1));
            } else if r64(g_x86_is_global, s1 * 8) != 0 {
                // Global: load via RIP-relative into rax
                grow_rip_patch(g_x86_rip_patch_count + 1);
                w64(g_x86_rip_patch_pos, g_x86_rip_patch_count * 8, pos + cp + 3);
                w64(g_x86_rip_patch_globals, g_x86_rip_patch_count * 8, s1);
                g_x86_rip_patch_count = g_x86_rip_patch_count + 1;
                cp = cp + e2_lr(buf, pos+cp, 0);       // lea r10, [rip+0]
                // mov rax, [r10] — REX.WB + 0x8B
            cp = cp + emit_rex(buf, pos+cp, 1, 0, 0, 10/8); e2_w8(buf, pos+cp, 139); cp = cp + 1; cp = cp + emit_modrm(buf, pos+cp, 0, 0, 10%8);
            } else {
                cp = cp + e2_ld(buf, pos+cp, 0, g2_slot(s1));
                // int 多字 M1（Task 4）tag 读路径 A：return 的 tagged 局部值
                // ——tag=1（槽 = 2-limb 指针）→ 解指针取低 limb → rax（exit
                // 低 8 位 = 数学值低字节；不解 = 指针低字节 = 错值）。tag=0
                // → 快值原样。行内（je rel8 跨 3B deref——tag 字节测试）。
                tg := g2_tag_off(s1);
                if tg != -1 {
                    cp = cp + e2_mw_t8(buf, pos+cp, tg);
                    w8(buf, pos+cp, 116); w8(buf, pos+cp+1, 3); cp = cp + 2;  // je +3
                    w8(buf, pos+cp, 72); w8(buf, pos+cp+1, 139); w8(buf, pos+cp+2, 0); cp = cp + 3;  // mov rax, [rax]
                }
            }
        }
        // record position for caller to patch jmp → epilogue
        grow_ret_patch(g_x86_ret_patch_count + 1); w64(g_x86_ret_patch_pos, g_x86_ret_patch_count * 8, pos + cp);
        g_x86_ret_patch_count = g_x86_ret_patch_count + 1;
        cp = cp + e2_jmp(buf, pos+cp, 0);
        return cp;
    }

    if op == IR_ALLOC {
        return 0;
    }

    if op == IR_ALLOC_STRUCT {
        do2 := g2_slot(d);
        name_ni := s3;
        if name_ni >= 0 {
            si := -1; sfi := 0;
            loop { if sfi >= g_struct_count { break; } if si_name(sfi) == name_ni { si = sfi; break; } sfi = sfi + 1; }
            if si >= 0 {
                fc := si_field_count(si);
                if fc > 0 {
                    cp = cp + e2_movabs_rdi(buf, pos+cp, fc * 8);
                    grow_alloc_patch(g_x86_alloc_patch_count + 1); w64(g_x86_alloc_patch_pos, g_x86_alloc_patch_count * 8, pos + cp);
                    g_x86_alloc_patch_count = g_x86_alloc_patch_count + 1;
                    e2_w8(buf, pos+cp, 232); e2_w32(buf, pos+cp+1, 0); cp = cp + 5;  // call placeholder
                    cp = cp + e2_st(buf, pos+cp, 0, do2);
                }
            }
        }
        return cp;
    }

    if op == IR_ALLOC_ARRAY {
        do2 := g2_slot(d); sz := s1 * 8;
        if sz > 0 {
            cp = cp + e2_movabs_rdi(buf, pos+cp, sz);
            grow_alloc_patch(g_x86_alloc_patch_count + 1); w64(g_x86_alloc_patch_pos, g_x86_alloc_patch_count * 8, pos + cp);
            g_x86_alloc_patch_count = g_x86_alloc_patch_count + 1;
            e2_w8(buf, pos+cp, 232); e2_w32(buf, pos+cp+1, 0); cp = cp + 5;  // call placeholder
            cp = cp + e2_st(buf, pos+cp, 0, do2);
        } else if s1 > 0 {
            // F14：s1*8 在 64 位内溢出为负（s1 > 2⁶¹）——不静默不发射；
            // 按 OOM 处理（alloc(-1) → null），后续访问由 null 陷阱捕获。
            cp = cp + e2_movabs_rdi(buf, pos+cp, -1);
            grow_alloc_patch(g_x86_alloc_patch_count + 1); w64(g_x86_alloc_patch_pos, g_x86_alloc_patch_count * 8, pos + cp);
            g_x86_alloc_patch_count = g_x86_alloc_patch_count + 1;
            e2_w8(buf, pos+cp, 232); e2_w32(buf, pos+cp+1, 0); cp = cp + 5;  // call placeholder
            cp = cp + e2_st(buf, pos+cp, 0, do2);
        }
        return cp;
    }

    if op == IR_ARENA_NEW {
        do2 := g2_slot(d);
        if s1 > 0 {
            // Scope actually allocates: create a fresh arena via arena_new().
            ni_arena_new := str_intern("arena_new");
            grow_call_patch(g_x86_call_patch_count + 1);
            w64(g_x86_call_patch_pos, g_x86_call_patch_count * 8, pos + cp);
            w64(g_x86_call_patch_name, g_x86_call_patch_count * 8, ni_arena_new);
            g_x86_call_patch_count = g_x86_call_patch_count + 1;
            e2_w8(buf, pos+cp, 232); e2_w32(buf, pos+cp+1, 0); cp = cp + 5;  // call placeholder
            cp = cp + e2_st(buf, pos+cp, 0, do2);  // store returned arena_id from rax
        } else {
            // No allocations in this scope: no arena. dest = -1 (none).
            // Avoids calling arena_new from arena infrastructure itself
            // (arena_new/arena_reset/_grow_arena_meta), which would recurse.
            // IR_ARENA_RESET with id < 0 is a safe no-op in arena_reset.
            w8(buf, pos+cp, 72); w8(buf, pos+cp+1, 199); w8(buf, pos+cp+2, 192);
            e2_w32(buf, pos+cp+3, -1); cp = cp + 7;  // mov rax, -1
            cp = cp + e2_st(buf, pos+cp, 0, do2);
        }
        return cp;
    }

    if op == IR_ARENA_RESET {
        // Load arena_id into edi (register 7 = rdi for first arg)
        cp = cp + e2_load_var(buf, pos+cp, 7, s1);
        // Skip the call when no arena was created (id < 0). Without this,
        // arena_reset's own exit marker would call arena_reset(-1), whose
        // early return still runs its exit marker → infinite recursion.
        // test rdi, rdi — 48 85 FF
        w8(buf, pos+cp, 72); w8(buf, pos+cp+1, 133); w8(buf, pos+cp+2, 255); cp = cp + 3;
        // jl +5 (skip the 5-byte call) — 7C 05
        w8(buf, pos+cp, 124); w8(buf, pos+cp+1, 5); cp = cp + 2;
        ni_arena_reset := str_intern("arena_reset");
        grow_call_patch(g_x86_call_patch_count + 1);
        w64(g_x86_call_patch_pos, g_x86_call_patch_count * 8, pos + cp);
        w64(g_x86_call_patch_name, g_x86_call_patch_count * 8, ni_arena_reset);
        g_x86_call_patch_count = g_x86_call_patch_count + 1;
        e2_w8(buf, pos+cp, 232); e2_w32(buf, pos+cp+1, 0); cp = cp + 5;  // call placeholder
        return cp;
    }

    if op == IR_LOAD && d >= 0 {
        do2 := g2_slot(d);
        if s1 >= 0 {
            isg : ., mut = r64(g_x86_is_global, s1 * 8);
            if isg != 0 {
                grow_rip_patch(g_x86_rip_patch_count + 1);
                w64(g_x86_rip_patch_pos, g_x86_rip_patch_count * 8, pos + cp + 3);
                w64(g_x86_rip_patch_globals, g_x86_rip_patch_count * 8, s1);
                g_x86_rip_patch_count = g_x86_rip_patch_count + 1;
                cp = cp + e2_lr(buf, pos+cp, 0);
                // mov r10, [r10] — REX.WRB + 0x8B
            cp = cp + emit_rex(buf, pos+cp, 1, 10/8, 0, 10/8); e2_w8(buf, pos+cp, 139); cp = cp + 1; cp = cp + emit_modrm(buf, pos+cp, 0, 10%8, 10%8);
                cp = cp + e2_st(buf, pos+cp, 10, do2);
                // 全局源（恒 64 位值）→ d tagged 时防御性清 tag
                cp = cp + e2_mw_tag_clr(buf, pos+cp, d);
            } else {
                cp = cp + e2_load_var(buf, pos+cp, 10, s1); cp = cp + e2_st(buf, pos+cp, 10, do2);
                // 拷贝定值 tag 传播（源 tagged → 运行时 tag 拷贝；源 untagged
                // → 清 0）——d 为 as 转换/拷贝链行（规则 B 闭包成员）
                cp = cp + e2_mw_tag_cpy(buf, pos+cp, d, s1);
            }
        } else { cp = cp + e2_load_var(buf, pos+cp, 10, s1); cp = cp + e2_st(buf, pos+cp, 10, do2); }
        // s1<0 尾分支（域外行——现 IR 形态防御兜底）：mw_setup_tags 规则 B 只扫
        // 函数域 [vs, ve)（s1 ∈ 域 且 tagged 才标 d）→ d 恒 untagged——快值原样
        // 直拷，无 e2_mw_tag_cpy/清 0 字节（tag 拷贝只对有 tag 字节的域内行发）。
        return cp;
    }

    if op == IR_STORE {
        o1 := g2_slot(s1);
        if s1 >= 0 {
            if r64(g_x86_is_global, s1 * 8) != 0 {
                cp = cp + e2_load_var(buf, pos+cp, 10, s2);
                grow_rip_patch(g_x86_rip_patch_count + 1);
                w64(g_x86_rip_patch_pos, g_x86_rip_patch_count * 8, pos + cp + 3);
                w64(g_x86_rip_patch_globals, g_x86_rip_patch_count * 8, s1);
                g_x86_rip_patch_count = g_x86_rip_patch_count + 1;
                cp = cp + e2_lrb(buf, pos+cp, 0);
                // mov [r11], r10 — REX.WRB + 0x89
                cp = cp + emit_rex(buf, pos+cp, 1, 10/8, 0, 11/8); e2_w8(buf, pos+cp, 137); cp = cp + 1; cp = cp + emit_modrm(buf, pos+cp, 0, 10%8, 11%8);
            } else {
                cp = cp + e2_load_var(buf, pos+cp, 10, s2); cp = cp + e2_st(buf, pos+cp, 10, o1);
                // 拷贝定值 tag 传播（规则 B' 闭包成员：s2 tagged → 运行时 tag
                // 拷贝；untagged/全局源 → 清 0）——变量行真定值载体
                cp = cp + e2_mw_tag_cpy(buf, pos+cp, s1, s2);
            }
        } else { cp = cp + e2_load_var(buf, pos+cp, 10, s2); cp = cp + e2_st(buf, pos+cp, 10, o1); }
        // s1<0 尾分支（域外目标行——现 IR 形态防御兜底）：规则 B' 只标函数域内
        // [vs, ve) 的 s1（且 s2 tagged）→ 域外 s1 恒 untagged——快值原样直拷，
        // 无 tag 拷贝/清 0（g2_tag_off 域外恒 -1，拷贝源 s2 的 tag 无需落地）。
        return cp;
    }

    if op == IR_LOAD_FIELD && d >= 0 {
        o1 := g2_slot(s1); do2 := g2_slot(d); fi2 := s3;
        fo : ., mut = fi2 * 8;
        cp = cp + e2_ld(buf, pos+cp, 10, o1);
        // mov r10, [r10 + disp32] — REX.WRB + 0x8B
            cp = cp + emit_rex(buf, pos+cp, 1, 10/8, 0, 10/8); e2_w8(buf, pos+cp, 139); cp = cp + 1;
            cp = cp + emit_modrm(buf, pos+cp, 2, 10%8, 10%8); cp = cp + e2_w32(buf, pos+cp, fo);
        cp = cp + e2_st(buf, pos+cp, 10, do2);
        return cp;
    }

    if op == IR_STORE_FIELD {
        o1 := g2_slot(s1); o2 := g2_slot(s2); fi2 := s3;
        fo : ., mut = fi2 * 8;
        cp = cp + e2_ld(buf, pos+cp, 10, o1); cp = cp + e2_ld(buf, pos+cp, 11, o2);
        // mov [r10 + disp32], r11 — REX.WRB + 0x89
            cp = cp + emit_rex(buf, pos+cp, 1, 11/8, 0, 10/8); e2_w8(buf, pos+cp, 137); cp = cp + 1;
            cp = cp + emit_modrm(buf, pos+cp, 2, 11%8, 10%8); cp = cp + e2_w32(buf, pos+cp, fo);
        return cp;
    }

    if op == IR_REF && d >= 0 {
        do2 := g2_slot(d); o1 := g2_slot(s1);
        cp = cp + e2_lb(buf, pos+cp, o1); cp = cp + e2_st(buf, pos+cp, 10, do2);
        return cp;
    }

    if op == IR_DEREF && d >= 0 {
        do2 := g2_slot(d);
        cp = cp + e2_load_var(buf, pos+cp, 10, s1);
        if s3 != 0 {
            n := e2_ptr_bounds_check(buf, pos+cp, s2, s3, ti);
            if n <= 0 { cp = cp + e2_ptr_null_check(buf, pos+cp); } else { cp = cp + n; }
        } else {
            // F6：无分配信息（s3=0）时至少保留 null 陷阱
            cp = cp + e2_ptr_null_check(buf, pos+cp);
        }
        // mov r10, [r10]
        cp = cp + emit_rex(buf, pos+cp, 1, 10/8, 0, 10/8); e2_w8(buf, pos+cp, 139); cp = cp + 1; cp = cp + emit_modrm(buf, pos+cp, 0, 10%8, 10%8);
        cp = cp + e2_st(buf, pos+cp, 10, do2);
        return cp;
    }

    if op == IR_ADDR_INDEX && d >= 0 {
        do2 := g2_slot(d);
        // load array pointer from arr base slot (handles both local and global)
        cp = cp + e2_load_var(buf, pos+cp, 10, s1);
        // load index (handles both local and global)
        cp = cp + e2_load_var(buf, pos+cp, 11, s2);
        // lea r10, [r10 + r11*8] = address of arr[i] on heap
        cp = cp + emit_rex(buf, pos+cp, 1, 10/8, 11/8, 10/8);
        e2_w8(buf, pos+cp, 141); cp = cp + 1;  // 0x8D LEA
        cp = cp + emit_modrm(buf, pos+cp, 0, 10%8, 4);  // mod=0, reg=r10, rm=4(SIB)
        cp = cp + emit_sib(buf, pos+cp, 3, 11%8, 10%8);  // scale=3, index=r11, base=r10
        cp = cp + e2_st(buf, pos+cp, 10, do2);
        return cp;
    }

    if op == IR_STORE_PTR {
        // load pointer (handles local and global)
        cp = cp + e2_load_var(buf, pos+cp, 10, s1);
        if s3 != 0 {
            n := e2_ptr_bounds_check(buf, pos+cp, d, s3, ti);
            if n <= 0 { cp = cp + e2_ptr_null_check(buf, pos+cp); } else { cp = cp + n; }
        } else {
            // F6：s3=0（provenance 未填充/unsafe）时至少保留 null 陷阱——
            // 修复前整个检查序列（含 null 陷阱）被跳过（instr.cr 旧 L1051）。
            cp = cp + e2_ptr_null_check(buf, pos+cp);
        }
        // load value to store (handles local and global)
        cp = cp + e2_load_var(buf, pos+cp, 11, s2);
        // mov [r10], r11 — REX.WRB + 0x89
            cp = cp + emit_rex(buf, pos+cp, 1, 11/8, 0, 10/8); e2_w8(buf, pos+cp, 137); cp = cp + 1; cp = cp + emit_modrm(buf, pos+cp, 0, 11%8, 10%8);
        return cp;
    }

    if op == IR_BRANCH {
        cp = cp + e2_load_var(buf, pos+cp, 10, s1);
        // test r10, r10
        cp = cp + emit_rex(buf, pos+cp, 1, 10/8, 0, 10/8); e2_w8(buf, pos+cp, 133); cp = cp + 1; cp = cp + emit_modrm(buf, pos+cp, 3, 10%8, 10%8);
        // je → false_label (s3), jmp → true_label (s2)
        // Single-pass backpatching: known labels emit immediately, unknown record pending
        je_rel_pos := pos+cp + 2;
        cp = cp + e2_je(buf, pos+cp, 0);
        if s3 >= 0 && r64(g_label_poses, s3 * 8) >= 0 {
            target := r64(g_label_poses, s3 * 8);
            e2_w32(buf, je_rel_pos, target - (je_rel_pos + 4));
        } else if s3 >= 0 {
            grow_pending(g_pending_count + 1);
            w64(g_pending_pos, g_pending_count*8, je_rel_pos);
            w64(g_pending_label, g_pending_count*8, s3);
            g_pending_count = g_pending_count + 1;
        }
        jmp_rel_pos := pos+cp + 1;
        cp = cp + e2_jmp(buf, pos+cp, 0);
        if s2 >= 0 && r64(g_label_poses, s2 * 8) >= 0 {
            target := r64(g_label_poses, s2 * 8);
            e2_w32(buf, jmp_rel_pos, target - (jmp_rel_pos + 4));
        } else if s2 >= 0 {
            grow_pending(g_pending_count + 1);
            w64(g_pending_pos, g_pending_count*8, jmp_rel_pos);
            w64(g_pending_label, g_pending_count*8, s2);
            g_pending_count = g_pending_count + 1;
        }
        return cp;
    }

    if op == IR_JUMP {
        jmp_rel_pos := pos+cp + 1;
        cp = cp + e2_jmp(buf, pos+cp, 0);
        if s1 >= 0 && r64(g_label_poses, s1 * 8) >= 0 {
            target := r64(g_label_poses, s1 * 8);
            e2_w32(buf, jmp_rel_pos, target - (jmp_rel_pos + 4));
        } else if s1 >= 0 {
            grow_pending(g_pending_count + 1);
            w64(g_pending_pos, g_pending_count*8, jmp_rel_pos);
            w64(g_pending_label, g_pending_count*8, s1);
            g_pending_count = g_pending_count + 1;
        }
        return cp;
    }

    if op == IR_LABEL {
        li := iri_s1(instr_idx);
        if li >= 0 {
            grow_label_poses(li + 1);
            w64(g_label_poses, li * 8, pos);
            if li + 1 > g_label_count { g_label_count = li + 1; }
            // Patch all pending forward jumps targeting this label
            pi : ., mut = 0;
            loop { if pi >= g_pending_count { break; }
                if r64(g_pending_label, pi * 8) == li {
                    rp := r64(g_pending_pos, pi * 8);
                    e2_w32(buf, rp, pos - (rp + 4));
                    w64(g_pending_label, pi * 8, -1);
                }
            pi = pi + 1; }
        }
        return 0;
    }

    if op == IR_LOAD_ENUM_TAG && d >= 0 {
        o1 := g2_slot(s1); do2 := g2_slot(d);
        cp = cp + e2_ld(buf, pos+cp, 10, o1);
        // mov r10, [r10 + disp32] — tag at offset 0
        // mov r10, [r10 + 0] (enum tag)
            cp = cp + emit_rex(buf, pos+cp, 1, 10/8, 0, 10/8); e2_w8(buf, pos+cp, 139); cp = cp + 1;
            cp = cp + emit_modrm(buf, pos+cp, 2, 10%8, 10%8); cp = cp + e2_w32(buf, pos+cp, 0);
        cp = cp + e2_st(buf, pos+cp, 10, do2);
        return cp;
    }

    if op == IR_LOAD_INDEX && d >= 0 {
        do2 := g2_slot(d); idx := s3;
        // load array pointer (handles local and global)
        cp = cp + e2_load_var(buf, pos+cp, 10, s1);
        if irv_type(s1) == TI_STR {
            // Strings are byte sequences, unlike arrays of 8-byte values.
            cp = cp + emit_rex(buf, pos+cp, 1, 10/8, 0, 10/8); e2_w8(buf, pos+cp, 15); cp = cp + 1;
            e2_w8(buf, pos+cp, 182); cp = cp + 1;
            cp = cp + emit_modrm(buf, pos+cp, 2, 10%8, 10%8); cp = cp + e2_w32(buf, pos+cp, idx);
        } else {
            cp = cp + emit_rex(buf, pos+cp, 1, 10/8, 0, 10/8); e2_w8(buf, pos+cp, 139); cp = cp + 1;
            cp = cp + emit_modrm(buf, pos+cp, 2, 10%8, 10%8); cp = cp + e2_w32(buf, pos+cp, idx * 8);
        }
        cp = cp + e2_st(buf, pos+cp, 10, do2);
        return cp;
    }

    if op == IR_STORE_INDEX {
        idx := s3;
        // load array pointer (handles local and global)
        cp = cp + e2_load_var(buf, pos+cp, 10, s1);
        // load value to store (handles local and global)
        cp = cp + e2_load_var(buf, pos+cp, 11, s2);
        // mov [r10 + disp32], r11
        if irv_type(s1) == TI_STR {
            // String assignment stores one byte, not a full machine word.
            cp = cp + emit_rex(buf, pos+cp, 0, 11/8, 0, 10/8); e2_w8(buf, pos+cp, 136); cp = cp + 1;
            cp = cp + emit_modrm(buf, pos+cp, 2, 11%8, 10%8); cp = cp + e2_w32(buf, pos+cp, idx);
        } else {
            // mov [r10 + idx*8], r11
            cp = cp + emit_rex(buf, pos+cp, 1, 11/8, 0, 10/8); e2_w8(buf, pos+cp, 137); cp = cp + 1;
            cp = cp + emit_modrm(buf, pos+cp, 2, 11%8, 10%8); cp = cp + e2_w32(buf, pos+cp, idx * 8);
        }
        return cp;
    }

    if op == IR_LOAD_INDEX_VAR && d >= 0 {
        do2 := g2_slot(d);
        // load array pointer (handles local and global)
        cp = cp + e2_load_var(buf, pos+cp, 10, s1);
        // load index (handles local and global)
        cp = cp + e2_load_var(buf, pos+cp, 11, s2);
        // Strings use byte indexing; arrays use 8-byte element indexing.
        if irv_type(s1) == TI_STR {
            cp = cp + emit_rex(buf, pos+cp, 1, 10/8, 11/8, 10/8); e2_w8(buf, pos+cp, 15); cp = cp + 1; e2_w8(buf, pos+cp, 182); cp = cp + 1;
            cp = cp + emit_modrm(buf, pos+cp, 0, 10%8, 4); cp = cp + emit_sib(buf, pos+cp, 0, 11%8, 10%8);
        } else {
            cp = cp + emit_rex(buf, pos+cp, 1, 10/8, 11/8, 10/8); e2_w8(buf, pos+cp, 139); cp = cp + 1;
            cp = cp + emit_modrm(buf, pos+cp, 0, 10%8, 4); cp = cp + emit_sib(buf, pos+cp, 3, 11%8, 10%8);
        }
        cp = cp + e2_st(buf, pos+cp, 10, do2);
        return cp;
    }

    if op == IR_STORE_INDEX_VAR && d >= 0 {
        // load array pointer (handles local and global)
        cp = cp + e2_load_var(buf, pos+cp, 10, s1);
        // load index (handles local and global)
        cp = cp + e2_load_var(buf, pos+cp, 11, s2);
        // load value to store (handles local and global)
        cp = cp + e2_load_var(buf, pos+cp, 12, d);
        if irv_type(s1) == TI_STR {
            // String assignment stores one byte at the runtime byte index.
            cp = cp + emit_rex(buf, pos+cp, 0, 12/8, 0, 10/8); e2_w8(buf, pos+cp, 136); cp = cp + 1;
            cp = cp + emit_modrm(buf, pos+cp, 0, 12%8, 4); cp = cp + emit_sib(buf, pos+cp, 0, 11%8, 10%8);
        } else {
            // mov [r10 + r11*8], r12 — SIB(scale=3, index=r11%8, base=r10%8)
            cp = cp + emit_rex(buf, pos+cp, 1, 12/8, 11/8, 10/8); e2_w8(buf, pos+cp, 137); cp = cp + 1;
            cp = cp + emit_modrm(buf, pos+cp, 0, 12%8, 4); cp = cp + emit_sib(buf, pos+cp, 3, 11%8, 10%8);
        }
        return cp;
    }

    if op == IR_MAKE_ENUM && d >= 0 {
        do2 := g2_slot(d); alloc_size := 8 + s2 * 8;
        e2_w8(buf, pos+cp, 191); e2_w32(buf, pos+cp+1, alloc_size); cp = cp + 5;  // mov edi, size
        grow_alloc_patch(g_x86_alloc_patch_count + 1); w64(g_x86_alloc_patch_pos, g_x86_alloc_patch_count * 8, pos + cp);
        g_x86_alloc_patch_count = g_x86_alloc_patch_count + 1;
        e2_w8(buf, pos+cp, 232); e2_w32(buf, pos+cp+1, 0); cp = cp + 5;  // call placeholder
        cp = cp + e2_st(buf, pos+cp, 0, do2);
        cp = cp + e2_ld(buf, pos+cp, 10, do2);
        // mov qword [r10 + 0], s1 — 0xC7 + REX.WB
            cp = cp + emit_rex(buf, pos+cp, 1, 0, 0, 10/8); e2_w8(buf, pos+cp, 199); cp = cp + 1;
            cp = cp + emit_modrm(buf, pos+cp, 0, 0, 10%8); cp = cp + e2_w32(buf, pos+cp, s1);
        return cp;
    }

    if op == IR_SLICE && d >= 0 {
        do2 := g2_slot(d); o1 := g2_slot(s1); o2 := g2_slot(s2);
        cp = cp + e2_ld(buf, pos+cp, 10, o1); cp = cp + e2_ld(buf, pos+cp, 11, o2);
        // shl r11, 3 — REX.WB + 0xC1, /4
            cp = cp + emit_rex(buf, pos+cp, 1, 0, 0, 11/8); e2_w8(buf, pos+cp, 193); cp = cp + 1;
            cp = cp + emit_modrm(buf, pos+cp, 3, 4, 11%8); e2_w8(buf, pos+cp, 3); cp = cp + 1;
        // add r10, r11 — REX.WRB + 0x01
            cp = cp + emit_rex(buf, pos+cp, 1, 11/8, 0, 10/8); e2_w8(buf, pos+cp, 1); cp = cp + 1; cp = cp + emit_modrm(buf, pos+cp, 3, 11%8, 10%8);
        cp = cp + e2_st(buf, pos+cp, 10, do2);
        return cp;
    }
    if op == IR_AWAIT && d >= 0 && s1 >= 0 {
        cp = cp + e2_ld(buf, pos+cp, 10, g2_slot(s1));
        cp = cp + e2_st(buf, pos+cp, 10, g2_slot(d));
        return cp;
    }

    if op == IR_BOUNDS_CHECK && s2 >= 0 {
        // s1 = index var, s2 = max_len 字面量 — index < 0 或 index >= max_len → ud2
        // F1c：s2 是字面量长度（发射约定），修复前按变量槽加载（e2_load_var）——
        // 把长度当变量索引读，检查恒错。
        cp = cp + e2_load_var(buf, pos+cp, 10, s1);  // index
        if ti != 0 {
            // Dynamic upper bound: load len_var into r11.
            cp = cp + e2_load_var(buf, pos+cp, 11, s2);
        } else {
            // Constant upper bound: movabs r11, imm64.
            e2_w8(buf, pos+cp, 73); e2_w8(buf, pos+cp+1, 187);
            e2_w64(buf, pos+cp+2, s2); cp = cp + 10;
        }
        cp = cp + e2_alu(buf, pos+cp, 57);           // cmp r10, r11
        // jb +2: if index < max (unsigned below), skip the 2-byte ud2 → continue
        e2_w8(buf, pos+cp, 114);                      // 0x72 = jb rel8
        e2_w8(buf, pos+cp+1, 2);                     // skip past ud2
        cp = cp + 2;
        // 注意：必须用 pos+cp（Phase 3 的 pos 为绝对基址）——修复前写 cp（相对
        // 偏移）→ ud2 落到缓冲区开头（后被 ELF 头覆盖）→ 检查恒不陷阱。
        e2_w8(buf, pos+cp, 15); e2_w8(buf, pos+cp+1, 11); cp = cp + 2;  // ud2 (SIGILL)
        return cp;
    }

    if op == IR_INLINE {
        // No-op at runtime — just a compile hint
        return 0;
    }
    if op == IR_NO_BOUNDS_CHECK {
        // No-op — consumed by ProvenanceVerify pass
        return 0;
    }
    if op == IR_FAST {
        // No-op — consumed by optimization passes
        return 0;
    }
    if op == IR_APPROX {
        // No-op — annotation only (apx: approved for approximate arithmetic)
        return 0;
    }
    if op == IR_UNROLL {
        // No-op — consumed by loop unrolling pass
        return 0;
    }
    if op == IR_SECTION {
        // No-op — consumed by section assignment pass
        return 0;
    }
    if op == IR_LAZY_THUNK {
        // Calls are currently emitted eagerly before the thunk wrapper, so
        // lowering the wrapper is a typed value transfer.
        cp = cp + e2_load_var(buf, pos+cp, 10, s1);
        cp = cp + e2_st(buf, pos+cp, 10, g2_slot(d));
        return cp;
    }
    if op == IR_LAZY_FORCE {
        cp = cp + e2_load_var(buf, pos+cp, 10, s1);
        cp = cp + e2_st(buf, pos+cp, 10, g2_slot(d));
        return cp;
    }

    if op == IR_YIELD {
        // F5b：eager 单线程近似——与 IR_AWAIT 一致的槽转移（d ← ρ(s1)），
        // 与 interp 一致（语义表 2.7：eager 近似，D 设计族）。
        // 原实现 `call sched_yield()` 且忽略 s1：① 与定义语义（向 flow 消费者
        // 通道发射值）不符；② sched_yield 未导入 → call rel32 补丁悬空 → 崩溃；
        // 导入后无 goroutine 上下文（fiber_switch 无栈可切）同样崩溃（139）。
        // 发射侧 dest=-1（ir_gen L1569）→ 本近似为 no-op（yield 值被丢弃）。
        if d >= 0 && s1 >= 0 {
            cp = cp + e2_ld(buf, pos+cp, 10, g2_slot(s1));
            cp = cp + e2_st(buf, pos+cp, 10, g2_slot(d));
        }
        return cp;
    }

    // ── Dynamic type opcodes ──
    if op == IR_DYN_PACK && d >= 0 {
        // Pack value (s1) + tag (s2) into 16-byte dyn_var slot
        do2 := g2_slot(d);
        cp = cp + e2_load_var(buf, pos+cp, 10, s1);
        cp = cp + e2_st(buf, pos+cp, 10, do2);      // low 8: value
        cp = cp + e2_li(buf, pos+cp, do2 + 8, s2);  // high 8: tag (type index)
        return cp;
    }

    if op == IR_DYN_TAG && d >= 0 {
        // Extract tag from dyn_var (offset +8)
        do2 := g2_slot(d);
        s1do := g2_slot(s1);
        cp = cp + e2_ld(buf, pos+cp, 10, s1do + 8);
        cp = cp + e2_st(buf, pos+cp, 10, do2);
        return cp;
    }

    if op == IR_DYN_VAL && d >= 0 {
        // Extract value from dyn_var (offset +0)
        do2 := g2_slot(d);
        s1do := g2_slot(s1);
        cp = cp + e2_ld(buf, pos+cp, 10, s1do);
        cp = cp + e2_st(buf, pos+cp, 10, do2);
        return cp;
    }

    if op == IR_DYN_DISPATCH {
        // Tag dispatch table: load tag from dyn_var, compare against known types,
        // jump to common handler that extracts value, or type_error on mismatch.
        do2 := g2_slot(d);
        s1do := g2_slot(s1);
        ti_int : int = 0; ti_bool : int = 2; ti_str : int = 3;

        // 1. Load tag from dyn_var offset +8: mov r10, [rbp + s1do + 8]
        cp = cp + e2_ld(buf, pos+cp, 10, s1do + 8);

        // 2. Compare-and-jump chain using short rel8 jumps
        // cmp r10d, TI_INT (0) — REX.RB + 0x83 + ModRM(/7,r10%8) + imm8
        cp = cp + emit_rex(buf, pos+cp, 0, 0, 0, 10/8);
        e2_w8(buf, pos+cp, 131); cp = cp + 1;
        cp = cp + emit_modrm(buf, pos+cp, 3, 7, 10%8);
        e2_w8(buf, pos+cp, ti_int); cp = cp + 1;
        j1_off := cp;  // position of the je rel8 offset byte
        e2_w8(buf, pos+cp, 116); e2_w8(buf, pos+cp+1, 0); cp = cp + 2;  // 0x74 = je rel8

        // cmp r10d, TI_BOOL (2)
        cp = cp + emit_rex(buf, pos+cp, 0, 0, 0, 10/8);
        e2_w8(buf, pos+cp, 131); cp = cp + 1;
        cp = cp + emit_modrm(buf, pos+cp, 3, 7, 10%8);
        e2_w8(buf, pos+cp, ti_bool); cp = cp + 1;
        j2_off := cp;
        e2_w8(buf, pos+cp, 116); e2_w8(buf, pos+cp+1, 0); cp = cp + 2;

        // cmp r10d, TI_STR (3)
        cp = cp + emit_rex(buf, pos+cp, 0, 0, 0, 10/8);
        e2_w8(buf, pos+cp, 131); cp = cp + 1;
        cp = cp + emit_modrm(buf, pos+cp, 3, 7, 10%8);
        e2_w8(buf, pos+cp, ti_str); cp = cp + 1;
        j3_off := cp;
        e2_w8(buf, pos+cp, 116); e2_w8(buf, pos+cp+1, 0); cp = cp + 2;

        // 3. .type_error: 未知 tag——静默产 0（语义表 2.6 BC9 的占位设计意图：
        // 「未知 tag 静默返回 0」；s2 方法名当前未用，占位）。
        //    F3：原实现 `xor eax,eax; ret` 在函数体中间发射 ret——有栈帧
        //    （push rbp; sub rsp）时弹出局部槽 → SIGSEGV；改 xor r10d,r10d +
        //    jmp .done（值级 d := 0，无中间 ret，不崩溃）。注意：本段必须位于
        //    compare-chain 之后（落空即到此）、.case_common 之前。
        e2_w8(buf, pos+cp, 69); e2_w8(buf, pos+cp+1, 49); e2_w8(buf, pos+cp+2, 210); cp = cp + 3;  // xor r10d, r10d (45 31 D2)
        type_jmp_off := cp;
        e2_w8(buf, pos+cp, 235); e2_w8(buf, pos+cp+1, 0); cp = cp + 2;  // 0xEB = jmp rel8 .done

        // 4. .case_common: extract value from dyn_var offset +0
        case_pos := cp;
        cp = cp + e2_ld(buf, pos+cp, 10, s1do);
        // jmp rel8 .done
        jmp_done_off := cp;
        e2_w8(buf, pos+cp, 235); e2_w8(buf, pos+cp+1, 0); cp = cp + 2;  // 0xEB = jmp rel8

        // 5. .done: store extracted value in destination slot
        done_pos := cp;
        if d >= 0 {
            cp = cp + e2_st(buf, pos+cp, 10, do2);
        }

        // 6. Patch all forward jump offsets (rel8)
        //    F3：写入位置加 pos 基——原实现用指令内相对偏移（j1_off 等，cp 系）
        //    当绝对缓冲区偏移 → 补丁写错地址 → 三个 je rel8 恒 0 → 已知 tag 也
        //    坠错误路径 → SIGSEGV（139）。对照全文件其他补丁的 `pos + cp` 惯例。
        e2_w8(buf, pos + j1_off + 1, case_pos - (j1_off + 2));
        e2_w8(buf, pos + j2_off + 1, case_pos - (j2_off + 2));
        e2_w8(buf, pos + j3_off + 1, case_pos - (j3_off + 2));
        e2_w8(buf, pos + jmp_done_off + 1, done_pos - (jmp_done_off + 2));
        e2_w8(buf, pos + type_jmp_off + 1, done_pos - (type_jmp_off + 2));

        return cp;
    }

    return 0;
}

// ══════════════════════════════════════════════════════════════
// HIT 表驱动发射（M1 Task 2/3）——事件流编码器（emit_instr 的并行路径）
// ══════════════════════════════════════════════════════════════
// 表模式下 corearch 内部 = IR →（lower_to_core.cr 降低）→ 事件流 →（本编码器
// 表投影）→ 字节。数据 = core-x86.toml（表数据归架构轴 src/arch/x86_64/，
// load_hit_table 已载入
// g_hit_events/steps）。降低在发射前一次性完成（hit_lower_program，
// lower_to_core.cr：IR 直线子集 → 事件流 + 常量池）；每条 IR 指令在
// g_hit_ev_map 记 [事件流起点, 条数]（0 条 = 非子集 → 落旧路径）。
// 调用方（elf.cr 发射循环）：hit_table_active() 时先调 emit_instr_tabled，
// 返回 -1 = 无事件/形态不支持 → 落旧路径 emit_instr（M1 混合模式）。
// 正确性契约：事件字节 = 模板投影（opcode 与 modrm 角色取自表数据——表 = 数据，
// 错在数据不在代码）+ 操作数装载/回存 glue（复用 e2_* 槽机制，与旧路径同语义；
// 逐字节对照仅 Task 2 直通形严格，Task 3 起 const → 池 load 字节有意不同）。
// 事件记录布局/访问器/常量池：lower_to_core.cr（构建清单中位于本文件之前）；
// 布局常量 hit.cr（HIT_*）。

// 角色 → M1 寄存器对低 3 位（modrm 字段编码；r10=2 主累加 / r11=3 第二操作数）
fn hit_role_reg_low(role: int) -> int {
    if role == HIT_ROLE_DST { return 2; }
    if role == HIT_ROLE_SRC1 { return 2; }
    if role == HIT_ROLE_SRC2 { return 3; }
    if role == HIT_ROLE_VAL { return 2; }
    return -1; }   // addr/未知：无寄存器惯例（M1 addr 走 rbp+disp 形态）

// 角色 → 绝对寄存器号（M1 惯例 r10/r11：低 3 位 + REX.R 位含在表 opcode 内）
fn hit_role_reg(role: int) -> int {
    low := hit_role_reg_low(role);
    if low < 0 { return -1; }
    return 8 + low; }

// 槽/池寻址形态的 addr 变量可用性：须为当前函数真内存槽变量
// （表模板 = rbp+disp32：寄存器分配变量/全局走旧路径——e2 族已有其语义）
fn hit_ev_slot_addr_ok(v: int) -> int {
    if v < 0 { return 0; }
    if v >= g_ir_var_count { return 0; }
    if r64(g_x86_is_global, v * 8) != 0 { return 0; }
    if v < g_current_func_var_start { return 0; }
    o := g2_slot(v);
    if o >= E2_REG_SLOT_BASE { return 0; }
    return 1; }

// 取事件模板步（proj0 视图整条 108B 记录复制入 st；本文件 M1 消费面只读
// 前 20B 视区——schema v2 记录加宽后偏移 0-16 语义未变，见 hit.cr 布局注释）；
// -1 = 表无此事件/步非法
fn hit_ev_step_of(ev_id: int, st: string) -> int {
    es := hit_event_lookup(ev_id);
    if es < 0 { return -1; }
    if hit_proj_step(es, 0, st) != 0 { return -1; }
    return 0; }

// ── v2 步模板发射/预检（M2a Task 2——模板解释器字段发射）──
// 形态族字段（hit.cr HIT_ST_OFF_* v2 区）按解释器固定序组装：prefix → rex →
// opcode → modrm → disp → imm → rel（= loader 字节视区拼接序同源）。本任务
// 消费面：modrm 双角色（rm_mode 0 寄存器对 = 清单 A 族 / rm_mode 1 rbp+disp =
// C 族）/digit 操作码扩展（C7 系）/disp auto|1|4（auto = 槽偏移幅度选 disp8/32
// ——与旧路径 e2_ld/e2_st 同规则 ④）/imm 字面量与操作数原值/rel32 回填登记
// （kind 0 = 事件流位置）。SIB（rm_mode 2）/rip 基/寄存器字面量角色/imm_kind/
// rel8/cond/多步序列 = 后续批与 Task 3/6 消费——预检拒（保守落旧路径）。

// 事件语义类（运行时核事件 id = 语义锚：粘合序列 = 保留代码，模板字节 = 表数据）：
//   ALU（sub=1/nand=2）：rm_mode 0 双寄存器累加形（rm = dst r10、reg = src2 r11）
//   MEM（load=3/store=4 槽寻址）：rm_mode 1 [rbp+disp]（reg = dst|val r10）
//   POOL：load 事件 s1 = 池槽——池 mov（[rip+disp] 硬编码辅助——M1 通道，非模板）
//   JUMP（5）：无 modrm rel32 步（E9——目标 = 事件序）
//   IMM（11 cst——注入夹具）：/digit + [rbp+disp] + imm（imm 值 = 事件 s1 原值）
HIT_EV_CLS_ALU  : int = 0;
HIT_EV_CLS_MEM  : int = 1;
HIT_EV_CLS_POOL : int = 2;
HIT_EV_CLS_JUMP : int = 3;
HIT_EV_CLS_IMM  : int = 4;

fn hit_ev_class(ev_id: int, fl: int) -> int {
    if ev_id == HIT_EV_SUB || ev_id == HIT_EV_NAND { return HIT_EV_CLS_ALU; }
    if ev_id == HIT_EV_LOAD && fl % 2 == 1 { return HIT_EV_CLS_POOL; }
    if ev_id == HIT_EV_LOAD || ev_id == HIT_EV_STORE { return HIT_EV_CLS_MEM; }
    if ev_id == HIT_EV_JUMP { return HIT_EV_CLS_JUMP; }
    if ev_id == 11 { return HIT_EV_CLS_IMM; }   // cst 夹具（注入测试载体）
    return -1; }   // 事件 6-9 = Task 3 前拒绝（无语义类 → 落旧路径）

// 形态（proj）选择：类按所需形态逐 proj 选首个匹配（条目序 = 优先序——
// 槽寻址 = rm_mode 1/2 形态、寄存器对 = 0；jump 取首个投影）。st = 选中
// proj 的步 0 记录（108B）。返回 proj 下标；-1 = 无匹配形态（'no projection
// for shape'——预检落旧路径）。
fn hit_ev_proj_pick(es: int, cls: int, st: string) -> int {
    pc := hit_proj_count(es);
    pi : ., mut = 0;
    loop {
        if pi >= pc { break; }
        if hit_proj_step_get(es, pi, 0, st) != 0 { return -1; }
        rm_mode := hit_r32(st, HIT_ST_OFF_RM_MODE);
        if cls == HIT_EV_CLS_ALU && rm_mode == 0 { return pi; }
        if cls == HIT_EV_CLS_MEM && (rm_mode == 1 || rm_mode == 2) { return pi; }
        if cls == HIT_EV_CLS_IMM && rm_mode == 1 { return pi; }
        if cls == HIT_EV_CLS_JUMP { return pi; }
        pi = pi + 1; }
    return -1; }

// 模板字节头：prefix → rex → opcode（v2 字段区逐段；st = 108B 步记录）。
// 返回字节数。
fn hit_st_head(st: string, buf: string, pos: int) -> int {
    cp : ., mut = 0;
    p0 := hit_r32(st, HIT_ST_OFF_PFX0);
    if p0 != 0 { e2_w8(buf, pos + cp, p0); cp = cp + 1; }
    p1 := hit_r32(st, HIT_ST_OFF_PFX1);
    if p1 != 0 { e2_w8(buf, pos + cp, p1); cp = cp + 1; }
    rx := hit_r32(st, HIT_ST_OFF_REX);
    if rx != 0 { e2_w8(buf, pos + cp, rx); cp = cp + 1; }
    nop := hit_r32(st, HIT_ST_OFF_OPN);
    j : ., mut = 0;
    loop {
        if j >= nop { break; }
        if j == 0 { e2_w8(buf, pos + cp, hit_r32(st, HIT_ST_OFF_OPB0)); }
        if j == 1 { e2_w8(buf, pos + cp, hit_r32(st, HIT_ST_OFF_OPB1)); }
        if j == 2 { e2_w8(buf, pos + cp, hit_r32(st, HIT_ST_OFF_OPB2)); }
        cp = cp + 1;
        j = j + 1; }
    return cp; }

// rm_mode 1（base = rbp）的 modrm + disp 发射：宽度按步 disp_size 字段
//（0 = auto——槽偏移幅度选 disp8|32，与旧路径 e2_ld/e2_st 同规则 ④）。
// 返回字节数；宽度不符（disp8 越界）= -1。
fn hit_st_modrm_disp(st: string, buf: string, pos: int, reg_lo: int, disp_val: int) -> int {
    dsz := hit_r32(st, HIT_ST_OFF_DISP_SIZE);
    cp : ., mut = 0;
    if dsz == 1 {
        if disp_val < -128 || disp_val > 127 { return -1; }
        cp = cp + emit_modrm(buf, pos + cp, 1, reg_lo, 5);
        e2_w8(buf, pos + cp, disp_val);
        cp = cp + 1; }
    else if dsz == 4 {
        cp = cp + emit_modrm(buf, pos + cp, 2, reg_lo, 5);
        cp = cp + e2_w32(buf, pos + cp, disp_val); }
    else {
        if disp_val >= -128 && disp_val <= 127 {
            cp = cp + emit_modrm(buf, pos + cp, 1, reg_lo, 5);
            e2_w8(buf, pos + cp, disp_val);
            cp = cp + 1; }
        else {
            cp = cp + emit_modrm(buf, pos + cp, 2, reg_lo, 5);
            cp = cp + e2_w32(buf, pos + cp, disp_val); } }
    return cp; }

// 步 imm 发射（imm_size 1/2/4/8；值由调用方解析——lit 取模板字面量、操作数
// 角色取事件域原值）。返回字节数。
fn hit_st_imm(st: string, buf: string, pos: int, imm_val: int) -> int {
    isz := hit_r32(st, HIT_ST_OFF_IMM_SIZE);
    if isz == 0 { return 0; }
    if isz == 1 { e2_w8(buf, pos, imm_val); return 1; }
    if isz == 2 { e2_w8(buf, pos, imm_val); e2_w8(buf, pos + 1, imm_val / 256); return 2; }
    if isz == 4 { e2_w32(buf, pos, imm_val); return 4; }
    e2_w64(buf, pos, imm_val);
    return 8; }

// 步 rel 发射 + 回填登记（kind 0 = 事件流位置——pos = rel 字段偏移；宽 = 32）。
// 返回字节数；kind/宽度非本任务面 = -1（预检已拦——防御）。
fn hit_st_rel_emit(st: string, buf: string, pos: int, target: int) -> int {
    rk := hit_r32(st, HIT_ST_OFF_REL_KIND);
    if rk == 0 { return 0; }
    rs := hit_r32(st, HIT_ST_OFF_REL_SIZE);
    if rk == HIT_REL_EVENT && rs == 32 {
        e2_w32(buf, pos, 0);   // 占位——elf.cr 发射后按事件位置表回填
        hit_rel_add(0, pos, target);
        return 4; }
    return -1; }

// 单条事件预检（发射前整条指令全过才落字节；任一不支持 → 整条落旧路径，
// 不产生半写）。Returns 0 = 可发射；1 = 不支持。
fn hit_ev_preflight_ok(ev_i: int) -> int {
    ev_id := hit_ev_id(ev_i);
    d := hit_ev_dst(ev_i);
    s1 := hit_ev_s1(ev_i);
    s2 := hit_ev_s2(ev_i);
    fl := hit_ev_flags(ev_i);
    es := hit_event_lookup(ev_id);
    if es < 0 { return 1; }   // 表在但事件缺 → 保守落旧路径
    cls := hit_ev_class(ev_id, fl);
    if cls < 0 { return 1; }  // 事件 6-9 等 = 无语义类 → 拒绝（Task 3 前保持）
    if cls == HIT_EV_CLS_POOL {
        // 池载入：load 模板 proj0 视区（= hit_ev_emit_pool_mov 同源形态）
        if d < 0 { return 1; }
        if s1 < 0 || s1 >= g_hit_pool_count { return 1; }
        stx := alloc(HIT_STEP_REC);
        if hit_ev_step_of(ev_id, stx) != 0 { return 1; }
        rm_mode := hit_r32(stx, HIT_ST_OFF_RM_MODE);
        rr := hit_r32(stx, HIT_ST_OFF_REG_ROLE);
        mr := hit_r32(stx, HIT_ST_OFF_RM_ROLE);
        if rm_mode != 1 || rr != HIT_ROLE_DST || mr != HIT_ROLE_ADDR { return 1; }
        if hit_role_reg_low(rr) < 0 { return 1; }
        return 0; }
    st := alloc(HIT_STEP_REC);
    pj := hit_ev_proj_pick(es, cls, st);
    if pj < 0 { return 1; }   // 'no projection for shape'
    if hit_proj_step_count(es, pj) != 1 { return 1; }   // 多步序列 = Task 3/6
    rm_mode := hit_r32(st, HIT_ST_OFF_RM_MODE);
    rr := hit_r32(st, HIT_ST_OFF_REG_ROLE);
    mr := hit_r32(st, HIT_ST_OFF_RM_ROLE);
    // ── 步字段支持门（本任务发射面外 → 保守落旧路径）──
    if hit_r32(st, HIT_ST_OFF_OPN) < 1 { return 1; }   // opcode 必选（loader 已验——防御）
    if hit_r32(st, HIT_ST_OFF_SIB_SCALE) != 0 || rm_mode == 2 { return 1; }  // SIB = M2c 批 3
    if hit_r32(st, HIT_ST_OFF_BASE_ROLE) != 0 { return 1; }   // 非 rbp 基（rip/槽值寄存器 = 批 4/3）
    if hit_r32(st, HIT_ST_OFF_REG_ROLE) >= HIT_REG_BASE { return 1; }   // 寄存器字面量角色 = M2c
    if hit_r32(st, HIT_ST_OFF_RM_ROLE) >= HIT_REG_BASE { return 1; }
    if hit_r32(st, HIT_ST_OFF_IMM_KIND) != 0 { return 1; }   // imm64 fnaddr 回填 = M2c 批 2
    if hit_r32(st, HIT_ST_OFF_REL_SIZE) == 8 { return 1; }   // rel8 = Task 12（批 2 G2）
    if hit_r32(st, HIT_ST_OFF_COND_ROLE) != 0 { return 1; }  // cond 发射 = Task 3
    if hit_r32(st, HIT_ST_OFF_REL_KIND) == HIT_REL_FUNC ||
       hit_r32(st, HIT_ST_OFF_REL_KIND) == HIT_REL_EXTERN { return 1; }  // Task 4/5
    if cls == HIT_EV_CLS_JUMP {
        // 无条件转移：E9 rel32——目标 = 事件序（s1）；dst/s2 未用（恒 0）
        if d != 0 || s2 != 0 { return 1; }
        if fl != 0 { return 1; }
        if s1 < 0 || s1 >= g_hit_ev_count { return 1; }
        if rr != 0 || mr != 0 { return 1; }   // 无 modrm 形态
        if hit_r32(st, HIT_ST_OFF_REL_KIND) != HIT_REL_EVENT { return 1; }
        return 0; }
    if cls == HIT_EV_CLS_ALU {
        // 双寄存器累加形（sub/nand…）：rm = dst 累加（r10）、reg = src2（r11）
        if mr != HIT_ROLE_DST { return 1; }
        if rr != HIT_ROLE_SRC2 { return 1; }
        if hit_role_reg_low(rr) < 0 || hit_role_reg_low(mr) < 0 { return 1; }
        if d < 0 { return 1; }
        if fl % 2 == 0 && s1 < 0 { return 1; }       // var 操作数须非负
        if fl / 2 % 2 == 0 && s2 < 0 { return 1; }
        if fl / 2 % 2 == 1 { return 1; }             // M1：仅首操作数可为池
        return 0; }
    if cls == HIT_EV_CLS_IMM {
        // cst（注入夹具）：/digit + [rbp+disp] + imm——rm = dst 槽、值 = s1 原值
        if d < 0 || s1 < 0 { return 1; }
        if fl != 0 { return 1; }
        if hit_r32(st, HIT_ST_OFF_REG_IS_DIGIT) != 1 { return 1; }
        if hit_r32(st, HIT_ST_OFF_REG_DIGIT) > 7 { return 1; }
        if mr != HIT_ROLE_DST { return 1; }
        if hit_r32(st, HIT_ST_OFF_IMM_SIZE) == 0 { return 1; }
        if hit_r32(st, HIT_ST_OFF_REL_KIND) != 0 { return 1; }
        return 0; }
    // MEM（load/store 槽寻址）：reg 角色 = dst（load）或 val（store）——rm 侧 = addr
    if mr != HIT_ROLE_ADDR { return 1; }
    if hit_role_reg_low(rr) < 0 { return 1; }
    if rr == HIT_ROLE_DST {                    // load：读 [addr槽] → dst 槽
        if d < 0 { return 1; }
        if fl % 2 == 1 { return 1; }           // 池 load = C_POOL（上已走）
        if hit_ev_slot_addr_ok(s1) == 0 { return 1; }
        return 0; }
    if rr == HIT_ROLE_VAL {                    // store：写 [addr槽] ← val
        if fl % 2 == 1 { return 1; }           // 写池 = 无意义（池只读）——保守
        if hit_ev_slot_addr_ok(s1) == 0 { return 1; }
        if s2 < 0 { return 1; }
        return 0; }
    return 1; }

// 池值 → 寄存器：mov r64, [rip+disp32]——load 事件模板字节 + mod=00（rm=101 =
// rip 相对；disp 由 elf.cr 于 rodata 定稿后按池槽回填）。reg 低 3 位 = 目标。
// 返回写入字节数（恒 7）；load 事件形态不符 = -1（调用方整条落旧路径）。
fn hit_ev_emit_pool_mov(buf: string, pos: int, reg_low: int, k: int) -> int {
    st := alloc(HIT_STEP_REC);
    if hit_ev_step_of(HIT_EV_LOAD, st) != 0 { return -1; }
    rm_mode := hit_r32(st, HIT_ST_OFF_RM_MODE);
    rr := hit_r32(st, HIT_ST_OFF_REG_ROLE);
    mr := hit_r32(st, HIT_ST_OFF_RM_ROLE);
    if rm_mode != 1 || rr != HIT_ROLE_DST || mr != HIT_ROLE_ADDR { return -1; }
    rl := hit_role_reg_low(rr);
    if rl != reg_low { return -1; }   // 目标寄存器须与 load 模板 reg 角色一致
    cp : ., mut = pos;
    e2_w8(buf, cp, hit_r32(st, HIT_ST_OFF_OP0)); cp = cp + 1;
    op1 := hit_r32(st, HIT_ST_OFF_OP1);
    if op1 != 0 { e2_w8(buf, cp, op1); cp = cp + 1; }
    cp = cp + emit_modrm(buf, cp, 0, reg_low, 5);
    e2_w32(buf, cp, 0); cp = cp + 4;
    hit_pool_patch_add(pos, k);
    return cp - pos; }

// 编码单条事件 → 字节（预检已过；此处仍防御性 -1）。
fn hit_ev_emit_one(ev_i: int, buf: string, pos: int) -> int {
    ev_id := hit_ev_id(ev_i);
    d := hit_ev_dst(ev_i);
    s1 := hit_ev_s1(ev_i);
    s2 := hit_ev_s2(ev_i);
    fl := hit_ev_flags(ev_i);
    es := hit_event_lookup(ev_id);
    if es < 0 { return -1; }
    cls := hit_ev_class(ev_id, fl);
    if cls < 0 { return -1; }
    st := alloc(HIT_STEP_REC);
    cp : ., mut = 0;
    if cls == HIT_EV_CLS_POOL {
        // 池载入：mov r10, [rip+池槽]（load 模板字节 + rip 回填——M1 通道）
        n := hit_ev_emit_pool_mov(buf, pos, hit_role_reg_low(HIT_ROLE_DST), s1);
        if n < 0 { return -1; }
        cp = cp + n;
        cp = cp + e2_st(buf, pos + cp, 10, g2_slot(d));
        return cp; }
    if hit_ev_proj_pick(es, cls, st) < 0 { return -1; }
    rm_mode := hit_r32(st, HIT_ST_OFF_RM_MODE);
    rr := hit_r32(st, HIT_ST_OFF_REG_ROLE);
    mr := hit_r32(st, HIT_ST_OFF_RM_ROLE);
    if cls == HIT_EV_CLS_JUMP {
        // E9 rel32（模板头）+ rel 登记（目标 = 事件序 s1——elf.cr 按位置表回填）
        hd := hit_st_head(st, buf, pos + cp);
        if hd < 0 { return -1; }
        cp = cp + hd;
        n2 := hit_st_rel_emit(st, buf, pos + cp, s1);
        if n2 < 0 { return -1; }
        cp = cp + n2;
        return cp; }
    if cls == HIT_EV_CLS_ALU {
        // 双寄存器累加形：rm = dst 累加器（首输入驻）、reg = src2
        r_acc := hit_role_reg(mr);   // dst → 10
        r_sec := hit_role_reg(rr);   // src2 → 11
        if r_acc < 0 || r_sec < 0 { return -1; }
        if fl % 2 == 1 {
            // 首输入 = 池：mov r10, [rip+池槽]（load 模板字节；预检已验形态）
            n3 := hit_ev_emit_pool_mov(buf, pos, hit_role_reg_low(mr), s1);
            if n3 < 0 { return -1; }
            cp = cp + n3; }
        else {
            cp = cp + e2_load_var(buf, pos + cp, r_acc, s1); }
        cp = cp + e2_load_var(buf, pos + cp, r_sec, s2);
        // 指令字节：prefix → rex → opcode 三段（v2 字段区——legacy 视区同源）
        hd2 := hit_st_head(st, buf, pos + cp);
        if hd2 < 0 { return -1; }
        cp = cp + hd2;
        // modrm：mod=3（寄存器）；reg/rm 低 3 位来自角色（src2→r11=3、dst→r10=2）
        cp = cp + emit_modrm(buf, pos + cp, 3, hit_role_reg_low(rr), hit_role_reg_low(mr));
        // 结果回存（先读后写——dst 兼作操作数（add 反减中间值）时读先于写）
        cp = cp + e2_st(buf, pos + cp, r_acc, g2_slot(d));
        return cp; }
    if cls == HIT_EV_CLS_IMM {
        // cst：/digit + [rbp+disp(auto)] + imm——rm = dst 槽、imm 值 = s1 原值
        hd3 := hit_st_head(st, buf, pos + cp);
        if hd3 < 0 { return -1; }
        cp = cp + hd3;
        n4 := hit_st_modrm_disp(st, buf, pos + cp,
                                hit_r32(st, HIT_ST_OFF_REG_DIGIT), g2_slot(d));
        if n4 < 0 { return -1; }
        cp = cp + n4;
        iv : ., mut = s1;
        if hit_r32(st, HIT_ST_OFF_IMM_ROLE) == HIT_CODE_LIT {
            iv = hit_r32(st, HIT_ST_OFF_IMM_LIT); }
        n5 := hit_st_imm(st, buf, pos + cp, iv);
        if n5 < 0 { return -1; }
        cp = cp + n5;
        return cp; }
    // MEM：reg 角色（dst/val）→ r10（glue 寄存器对同 M1）；rm = [rbp+disp 槽]
    reg_lo := hit_role_reg_low(rr);
    if reg_lo < 0 { return -1; }
    r_val := hit_role_reg(rr);
    if r_val < 0 { return -1; }
    if rr == HIT_ROLE_DST {
        // load：读 [addr槽] → dst（disp = addr 槽偏移——auto/1/4 按步字段）
        hd4 := hit_st_head(st, buf, pos + cp);
        if hd4 < 0 { return -1; }
        cp = cp + hd4;
        n6 := hit_st_modrm_disp(st, buf, pos + cp, reg_lo, g2_slot(s1));
        if n6 < 0 { return -1; }
        cp = cp + n6;
        cp = cp + e2_st(buf, pos + cp, r_val, g2_slot(d));
        return cp; }
    if rr == HIT_ROLE_VAL {
        // store：写 [addr槽] ← val（val 槽值先载入角色寄存器）
        cp = cp + e2_load_var(buf, pos + cp, r_val, s2);
        hd5 := hit_st_head(st, buf, pos + cp);
        if hd5 < 0 { return -1; }
        cp = cp + hd5;
        n7 := hit_st_modrm_disp(st, buf, pos + cp, reg_lo, g2_slot(s1));
        if n7 < 0 { return -1; }
        cp = cp + n7;
        return cp; }
    return -1; }

// 表驱动单指令发射。与 emit_instr 同签名；返回写入字节数；-1 = 无事件/不支持。
// 消费 lower_to_core.cr 的事件流：0 事件 = 非子集指令（旧路径）；
// 有事件 = 预检整条 → 逐事件表投影发射（g_hit_tabled_count 计事件条数）。
fn emit_instr_tabled(instr_idx: int, buf: string, pos: int) -> int {
    cnt := hit_ev_map_cnt(instr_idx);
    if cnt <= 0 { return -1; }
    start := hit_ev_map_start(instr_idx);
    e : ., mut = 0;
    loop {
        if e >= cnt { break; }
        if hit_ev_preflight_ok(start + e) != 0 {
            // 注入通道（测试专用）：预检拒绝 = 文件事件无法经表发射——大声错误
            // （corearch 于发射后按事件计数不符 exit 1——不静默落旧路径掩盖）；
            // 真实降低路径 = 整条落旧路径（M1 混合模式，不半写）。
            if g_hit_inject_active != 0 {
                print("error: HIT events: event ");
                print_i(start + e);
                print(" ("); print(hit_event_name(hit_event_lookup(hit_ev_id(start + e))));
                println(") not emittable (shape/operands)");
            }
            return -1; }
        e = e + 1; }
    cp : ., mut = 0;
    e2 : ., mut = 0;
    loop {
        if e2 >= cnt { break; }
        // 事件序 → 字节位置（M2a Task 2：rel 回填表 kind 0 的目标解析表——
        // 边发射边记；位置 = 事件首字节的绝对 buf 偏移）
        hit_ev_pos_set(start + e2, pos + cp);
        n := hit_ev_emit_one(start + e2, buf, pos + cp);
        if n < 0 { return -1; }   // 预检后不可达（防御）
        cp = cp + n;
        g_hit_tabled_count = g_hit_tabled_count + 1;
        e2 = e2 + 1; }
    return cp; }
