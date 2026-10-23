# HIT M2 Task 0 盘点执行报告

状态：DONE（附 2 条注意项，见「Concerns」）
日期：2026-09-07
提交：jj change `slwknmso`（short SHA `bdd33bcf`），`docs: HIT M2 Task 0 盘点，形态族/schema v2 定稿 + 序列算法边界 + IR op 映射三清单（计划定位点点回填）`
改动文件：`docs/superpowers/plans/2026-09-07-hit-m2.md`（文末「Task 0 盘点结果」节回填，325-327 行占位扩展为 437 行全文件，新增约 110 行三清单）；`docs/superpowers/specs/2026-09-07-hit-m2-design.md`（第 3 节字段集追加一行字段扩展注）

## 一、盘点范围与基源

- instr.cr 全部 2381 行（逐函数、逐 IR 分发支路核对，含字节级抽查：REX 拼装、modrm 常量、opcode 十进制和十六进制互证，e2_alu 对（4D + opcode + modrm(3,3,2)）、cmp = e2_alu(0x39)、setcc sop 表、movzx 44 0F B6 D0、C7/0 与 B8+r movabs 双支、2L 块内链）
- sizes.cr 全部 77 行（sz_* 是 e2_* 的尺寸镜像，随族迁移删除或修改，不单列）
- elf.cr 全部 1793 行（Phase 1-3 发射序、参数保存、ret/jo/oc/alloc/call/fnaddr/rip/rodataref/池回填循环、运行时 stub 族、bss_init/emit_start）
- hit 层：hit.cr（347 行，记录布局、加载、查询）、lower_to_core.cr（270 行，M1 直线子集降低 + 池）、core-x86.toml（4 事件 M1 模板）
- ast.cr 的 IR op 全集 0-51（51 个 op + 空号 40）；IR_PHI/UOP_REF/UOP_DEREF 在发射面不可达，已用 grep 实证（emit_instr 没有处理支路，dump 等只用于显示）
- 测试与规范：test_hit_table.py 11 个测试、design spec 第 1-11 节、plan 的 M2a-d 全任务文（批次命名对齐 Task 9-12）

## 二、三清单全文（与 plan 文末回填节同文）

### 清单 1：形态族到 schema v2 字段定稿（8 组 15 族 + 判定汇总 + 4 批）

- [A] 寄存器对算术族：A1 定对 ALU（e2_alu:4D+01/41/21/09/39+modrm(3,3,2)，3B，与 M1 同形）；A2 三字节 ALU（imul 4D 0F AF DA，同形）；A3 移位/乘除定式（C1 /7 sar imm8、D3 /4|/5 + mov rcx,r11、6B /r imul imm8、F7 /3 neg、DIV/MOD = mov rax + cqo 48 99 + F7 /7 idiv，需补① 隐含/字面量寄存器 rcx/rax/rdx）；A4 任意寄存器对移动（e2_mov 89，ABI reg × r10/r11，需补①）
- [B] imm 定值族：B1 imm32 写入槽/reg（C7 /0 mod 01/10/11，同形，另需 /digit 补②）；B2 movabs imm64 写入 reg（48 B8/BF/B9、49 BA/BB，需补③ imm64 回填 kind）；B3 字节 imm（C6 /0，同形，另需补②）
- [C] disp 槽寻址族：C1 64 位槽 ld/st（8B/89 [rbp+disp8/32]，e2_ld/e2_st/e2_load_var，rm_mode 1 已有；规则④ disp.size auto：槽回填按幅度选 1|4，与旧路径一致，M1 固定 disp32 是 auto 的退化实例）；C2 8 位字节槽 op（F6 /0 test、C6/0、8A/88，rex.w=0 可表，另需补② /digit）
- [D] 非 rbp 基 + disp 载荷族：D1 8B/89/0F B6/88 [槽值寄存器+disp8/32]（LOAD_FIELD/STORE_FIELD/LOAD_ENUM_TAG/LOAD_INDEX/STORE_INDEX/DYN_TAG/DYN_VAL/MAKE_ENUM，需补⑤ rm_mode 1 泛化 base_role，缺省 rbp）
- [E] SIB 索引族：E1 lea 8D scale3/8B/0F B6/89/88 scale 0/1/3（ADDR_INDEX/LOAD_INDEX_VAR/STORE_INDEX_VAR/内置体 load8/store8/load64/w64，需补⑥ SIB 字段组 {scale, index_role, base_role}）；E2 get_arg 内联循环是序列算法（R6）
- [F] rip 基族：F1 lea reg,[rip+rel32]（e2_lr/e2_lrb，str/全局/return，需补⑦ base_role=rip）；F2 池/rodata/全局 load/store（4C 8B 15 mod=00 rm=101 = M1 池 mov 模板字节，hit_ev_emit_pool_mov；全局 = lea + [reg] 间接或 lrb+st，需补⑦）
- [G] cond/rel 族：G1 cond 结果原子（cmp+setcc 0F 9x al+movzx 44 0F B6 D0；test+sete；2L xor/or/mov eax，cond {role}+seq 已覆盖）；G2 rel 定长形（E9/E8 5B、0F 84/85/83/80 6B、rel8 74/75/7C/72 + skip imm 字面量，rel32 三角色已有，需补⑧ rel.size {8|32}）
- [H] 栈调整/系统原子：H1 push/pop/add-sub rsp imm/ret C3/ud2/syscall 0F 05/push_xmm0，只存在于序列算法内（R1/R6/R9），表条目非必需，Task 13 终裁
- 判定汇总：已覆盖 = A1/A2/B1/B3/C1/G1/G2(rel32)/F2；待补 = ① 寄存器字面量/隐含 ② /digit + 无 ModRM 标记 ③ imm64 回填 kind ④ disp.size auto（解释器规则）⑤ base_role 泛化 ⑥ SIB 字段组 ⑦ base_role=rip ⑧ rel.size {8|32}
- M2c 批分：批 1（Task 9 数据直通事件族）= A+B+C；批 2（Task 10 cond/rel 族）= G1+G2；批 3（Task 11 寻址扩展族）= D+E（依赖补⑤⑥先实施）；批 4（Task 12 收尾族）= F + H/SSE 汇合裁定（4 批在计划上限内）

### 清单 2：序列算法边界（保留代码调模板，12 项）

- R1 函数帧 prologue/epilogue（elf.cr Phase 3 + g_x86_sub_rsp_pos 回填 + mw_frame_size 对齐；O0 ≡0 mod 16）
- R2 参数拷贝（IR_CALL 参数分派 ir_cnt/fr_cnt 双编号 + elf.cr 参数保存 caller_off/po2/xmm frn/tag 清/O1+ 重载，O1+ 重载恒不触发）
- R3 2L jo 慢路径块（e2_mw_jo + e2_mw_slow_block + g_x86_mw_jo_* 回填）
- R4 2L 操作数块（e2_mw_oc_check + e2_mw_opnd_block + g_x86_mw_oc_*；内含 e2_mw_ld2/e2_mw_sext 原子；2L 快路径进位链走表通道 = adc/sbb 事件）
- R5 tag 卫生与静态标记（mw_setup_tags A/B/B' 定点扫描 + mw_oc_new/oc_check + 4 个定义点 tag_clr/tag_cpy）
- R6 调用点序列 + 内置体（syscall3/4、load8/store8/load64/w64/load_str_ptr/store_str_ptr/r64、get_arg/_dyncpy 循环、goroutine_wrapper_addr、generic；内置转 extern/内部符号事件化 = M2d 清点）
- R7 return 序列（IR_RETURN 块 + e2_store_ret + ret_patch 循环）
- R8 常量池/rodata/rip 回填（e2_lr/lrb + hit_ev_emit_pool_mov + g_hit_pool_patch 回填 + rodata 布局；M2b 事件流回填 = 同族新算法）
- R9 越界/空指针检查序列（e2_ptr_bounds_check/null_check + IR_BOUNDS_CHECK 段；事件化 = M3 挂账候选）
- R10 运行时 stub 发射体（emit_alloc_body(+simple)/emit_heap_expand/emit_sched_call/emit_curg_stubs/emit_goroutine_stubs/emit_m_start_workers/_init_globals 6B + arena_new/arena_reset 后备桩/emit_start/bss_init；call 事件目标，不是事件流内容）
- R11 回填/补丁循环族（g_label_poses/g_pending、ret/call/fnaddr/rip/rodataref/jo/oc/alloc_patch；布局算法保留）
- R12 函数级 label 扫描先例（regalloc.cr stage 2 回边扫描；事件流标签映射同源）
- O0 相容总注：E2_REG_SLOT_BASE/get_reg_for_var 只在 opt≥2 时触发，表模式恒为 O0，因此全是槽 rbp+disp 形态；O1+ 专属序列恒不执行，但代码路径保留（非表模式回归面零变化）

### 清单 3：IR op 到事件/合成映射初稿（0-51 全分类，36 行表）

分类：(a) 直通候选（数据事件 id 10+）；(b) 4 核合成后备；(c) 控制调用事件 id 5-9；(d) 序列算法；(e) 保留旧路径候选（行内汇合裁定/挂账条件）。
要点：直通 = BINARY TI_INT 快值全算子（ADD..GE/DIV/MOD，x86 大表全量声明 = M2c 批 1 产物）、CONST（imm 直载/池宽值）、LOAD/STORE local（M1 已有）、FIELD/INDEX/DYN 载荷（D/E 补字段后）、UNARY NEG/NOT、REF（lea）；合成后备 = ADD 反减（M1 已有）/AND=nand 两步/OR 德摩根/EQ=sub+判别/NOT=sub(1,x)/const 负宽值；控制调用 = BRANCH(6)/JUMP(5)/CALL(7)/RET(8)/CALL_EXTERN(9)/LABEL 定位点；序列 = ALLOC 0 字节/ALLOC_STRUCT+ARRAY(alloc call)/MAKE_ENUM/SLICE/DEREF/STORE_PTR/SPAWN/YIELD/AWAIT/BOUNDS_CHECK/ADDR_INDEX/ARENA_NEW+RESET/属性六 op（34-38，51 零字节）/HOTPATCH_ROUTE/DYN_DISPATCH/DYN_PACK/FNADDR/LAZY_THUNK+FORCE；保留旧路径 = BINARY TI_DEX SSE 面 + I2F/F2I（挂账条件 = Task 8 自举语料零浮点实证，否则 xmm 角色表化）；表外注记 = PHI(22)/UOP_REF/DEREF/空号 40（后端不可达，Task 6 覆盖清单显式排除以防回归）；tagged/2L 口径 = 快值 64 位原子 + tag 字节原子表化，块序 R3-R5 不动；M1 偏差 #0 实现方式注（无源码运算符的 op 用 IR 层测试实现方式验证）。

## 三、spec 第 3 节字段扩展注（回填一行）

modrm 增加 base_role（rm_mode 1 泛化，缺省 rbp/槽值寄存器/rip）；rm_mode 2 细化为 SIB {scale, index_role, base_role}；modrm 可缺，reg_role 可用 /digit；rel.size {8|32}；imm lit + imm64 回填 kind；操作数角色补寄存器字面量/隐含（rcx/rax/rdx:rax/ABI/xmm0-7 预留）；disp.size auto（解释器规则）；字节拼接序为 prefix、REX、opcode、ModRM、SIB、disp、imm（固定序，非字段）。Task 1 Step 1 按此行实施字段。

## 四、分析注记

1. byte-identical 判据与表形态的耦合：M1 表 load/store 用固定 disp32（mod=2 rm=5），旧路径按偏移幅度选 disp8/32，两者产物天然有差异。盘点口径是判据按「同形等价」应用（数据化迁移块与旧块同形逐字节比较，跨形选择规则 = 解释器规则④，不追求不同形态间字节相等）。plan 现有表述不变，执行 Task 9 时以「双源对照（同形）」实现。
2. 2L 快路径走表需要进位事件：128 位链 add/adc/sub 中的 adc/sbb 无法由 4 核合成，spec 第 4 节「2L 快路径走表」的真实实施通道 = x86 大表声明 adc/sbb 直通事件（批 1 A 族扩展，清单 3 的 tagged 行已注）。未决：是否声明留到 M2b Task 6 直通表定稿时一并裁决。
3. M2b Task 6「直通表」与 M2c 批 1 的关系：直通事件先在 Task 6 以占位模板 + 事件流 dump 断言实施，批 1 以完整 v2 形态 + 对照收口。清单 3 的 (a) 类就是两者的共源清单。
4. op 40 空号与 PHI 等：ast.cr 编号 40 没有常量；IR_PHI 只出现在 dump/dataflow/ptr_analysis/regalloc 的显示中，ir_gen 不产生，emit_instr 没有支路（落空 0 字节）。任务的全 op 覆盖清单必须显式排除并写防回归测试。

## 五、Self-review（逐项核对）

- instr.cr 函数族全覆盖：e2_alu/mov/ld/st/li/lr/lrb/lb/call/jmp/je/jae + movabs_rdi + sd_load/load1/load_x/cvt/store/push_xmm0/store_ret + ptr_bounds/null_check + mw_* 全族（t8/b8/ld8/st8/tag_clr/tag_cpy/jo/slow_block/oc_new/oc_check/ld2/sext/opnd_block/mw_setup_tags/mw_frame_size/mw_int_arith_jo_needed）+ 编码基元（w8-64/emit_rex/emit_modrm/emit_sib，保留代码注）+ hit 层（hit_ev_emit_pool_mov/slot_addr_ok/emit_instr_tabled，gating 与池 mov 点名列）
- elf.cr 全覆盖：prologue/参数保存/ret_patch/jo-oc 块发射/全部 stub（含 _init_globals 6B 与 arena 后备桩）/全部回填循环/emit_start/bss_init
- IR op 0-51 全部入表（36 行），无 TBD 或含糊项；51 个 op + 空号 + 3 项表外注记
- 每个形态族与具体函数/op 交叉引用；抽查字节级事实与源码一致（4D ALU 对、0x39 cmp、0F 94-9F setcc、0F B6 movzx、C7/0、B8+r、F2 0F 10 系、0F 05/0F 0B、E8/E9 5B、0F 84 6B、41 52 push r10、C1/7 sar 等）
- spec 第 3 节的差异为一行注回填（先于 Task 2 实施，与 plan Task 1 Step 1 表述吻合）

## 六、Concerns（注意项，非阻塞）

1. `--table` 模式的「整条 gating」注：清单 3 标注 tagged/2L 面现行的 mw_int_arith_jo_needed 按指令 gating；若 M2 想扩大表直通覆盖，须先解决 tag 字节原子事件化。已注为 M2b Task 6 裁决点，未定案。
2. SSE 面 (e) 类挂账条件依赖实证：Task 8 自举冒烟须产出「语料面是否含 TI_DEX」的明确记录，否则 Task 13 汇合时 SSE 裁定缺少输入。已在清单 3 行内标注依赖。
3. 表模式与旧路径的 disp8/disp32 形差：如分析注记 1，Task 9 双源对照按「同形等价」执行即可，不构成计划偏移（判据表述沿用计划原文）。

## 七、交付物

- plan 回填节：`/home/DslsDZC/core/docs/superpowers/plans/2026-09-07-hit-m2.md` 文末「Task 0 盘点结果（执行时回填）」（表头保留，占位注删除，三清单全文）
- spec 字段注：`/home/DslsDZC/core/docs/superpowers/specs/2026-09-07-hit-m2-design.md` 第 3 节「字段扩展注（Task 0 盘点 2026-09-07 回填，先于 Task 2 实施）」
- 提交：jj `bdd33bcf`（change `slwknmso`）
