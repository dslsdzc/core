// ══════════════════════════════════════════════════════════════
// src/arch/x86_64/tag2l.cr —— 架构轴：int 多字 M1 的 tag 表 + 2L 编码族
//
// x86 实例化波 1 Task 4 整搬（自 src/arch/x86_64/instr.cr 整函数搬迁——发射序
// 逐字节 verbatim；波 1 判据 = stage 链 byte-identical）：
//   - **tag 表 owner = 本文件**：mw_setup_tags（规则 A/B/B' 不动点扫描 → tag
//     字节分配——per 函数，由 elf.cr Phase 2 dry-run 与 Phase 3 各调一次）+
//     消费接口 g2_tag_off（定义在 frame.cr——H3 帧布局面，见下双向引用）；
//   - mw 族纯编码：jo 快路径溢出跳（e2_mw_jo）、函数尾慢路径块
//     （e2_mw_slow_block）、tag 卫生字节助手（e2_mw_t8/b8/ld8/st8/tag_clr/
//     tag_cpy）、消费者站点（mw_oc_new/e2_mw_oc_check）、2L 装载与 2L 块
//     （e2_mw_ld2/e2_mw_sext/e2_mw_opnd_block）；
//   - 发射门 mw_int_arith_jo_needed（HIT 表路径排除门——elf.cr 汇合点调用）。
// 通用编码原语（e2_w8/e2_mov/e2_ld/e2_st/e2_alu/emit_rex/…）留 instr.cr——
// 本文件是它们的消费者；本段原为 instr.cr 的 mw 章节（自 mw_setup_tags 起）。
//
// **frame ↔ tag2l 同轴双向引用**（波 1 Task 4 评审裁定②：可接受——同轴、
// 两构建路径均容忍：concat 扁平单元 + 组合根清单）：
//   本文件 → frame.cr：g2_tag_off（tag 表读取；表 owner 在本文件）；
//   frame.cr → 本文件：pf_epilogue 函数尾按站点发射慢路径块/2L 块
//   （e2_mw_slow_block/e2_mw_opnd_block）；pf_prologue 的 tag 卫生③读
//   g2_tag_off（表由本文件 mw_setup_tags 填充）。
// 解析 = concat（build_selfhost_native.py arch_x86_64_files）+ module.cr 三轴
// 回退链（组合根 _import.cr `import tag2l`）；函数可见性不受段内顺序约束，
// 顺序按「被依赖者先」惯例：regalloc → sizes → instr → tag2l → frame。
// ══════════════════════════════════════════════════════════════

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
//     tag（Task 3）、消费者读 tag（Task 4）均走它；**x86 实例化波 1 Task 3
//     起定义迁 src/arch/x86_64/frame.cr（H3 裁决：帧布局面归 frame——本文件
//     依赖 frame；instr.cr/frame.cr 的 mw 族消费点经扁平单元解析不变）**；
//   - pf_frame_size(vc)：含 tag 区的帧总字节（已按 SysV 16 对齐规则取整）——
//     同迁 frame.cr（H2 单源：Phase 2 dry-run 与 Phase 3 sub rsp 立即数共用
//     ——此前名字 mw_frame_size）。
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
// g_x86_mw_jo_{pos,dest,is_sub}（g2_init 清零、frame.cr pf_epilogue 函数尾统一
// 发射块并回填；resume 由 elf.cr 于该指令发射完后按序补写）。
// rel32（非 rel8）：块附函数尾——函数体 >127B 时 rel8 不可达（编译器自身
// 的大函数在自举回归里必然命中；Task 2 用 t3 大函数用例锁定该编码）。
fn e2_mw_jo(b: string, p: int, d: int, is_sub: int) -> int {
    grow_mw_jo_patch(g_x86_mw_jo_count + 1);
    w64(g_x86_mw_jo_pos, g_x86_mw_jo_count * 8, p);
    w64(g_x86_mw_jo_dest, g_x86_mw_jo_count * 8, d);
    w64(g_x86_mw_jo_is_sub, g_x86_mw_jo_count * 8, is_sub);
    g_x86_mw_jo_count = g_x86_mw_jo_count + 1;
    w8(b, p, 15); w8(b, p + 1, 128);  // 0F 80 = jo rel32
    e2_w32(b, p + 2, 0);              // 占位——frame.cr pf_epilogue 块位置已知后回填
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
//   ③ 本函数 prologue 参数保存（frame.cr pf_prologue——tagged 参数行在函数内首次定值
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
