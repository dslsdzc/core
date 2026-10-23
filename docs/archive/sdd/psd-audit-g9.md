# 伪代码审查报告：组 9（arch/linux/ld：elf-1~4、instr-1~3、ld、main、resolve、sizes、_import）

- 审查日期：2026-08-09
- 审查对象（12 个文档）：
  - docs/pseudocode/arch/linux/ld/elf-1.md（源：src/arch/linux/ld/elf.cr 第 1-430 行）
  - docs/pseudocode/arch/linux/ld/elf-2.md（源：第 432-775 行，实含至 829 行函数）
  - docs/pseudocode/arch/linux/ld/elf-3.md（源：第 776-970 行）
  - docs/pseudocode/arch/linux/ld/elf-4.md（源：第 972-1643 行）
  - docs/pseudocode/arch/linux/ld/instr-1.md（源：src/arch/linux/ld/instr.cr 第 1-298 行）
  - docs/pseudocode/arch/linux/ld/instr-2.md（源：第 299-700 行，实为 IR_NOP~IR_CALL）
  - docs/pseudocode/arch/linux/ld/instr-3.md（源：第 603-1203 行，emit_instr 续）
  - docs/pseudocode/arch/linux/ld/ld.md（源：src/arch/linux/ld/ld.cr，477 行）
  - docs/pseudocode/arch/linux/ld/main.md（源：src/arch/linux/ld/main.cr，136 行）
  - docs/pseudocode/arch/linux/ld/resolve.md（源：src/arch/linux/ld/resolve.cr，91 行）
  - docs/pseudocode/arch/linux/ld/sizes.md（源：src/arch/linux/ld/sizes.cr，75 行）
  - docs/pseudocode/arch/linux/ld/_import.md（源：src/arch/linux/ld/_import.cr，15 行）
- 对照基准：src/arch/linux/ld/*.cr 全部源码、docs/pseudocode/标识符对照表.md、docs/archive/sdd/psd-translation-conventions.md（基准格式）
- 审查方式：只读；未修改 docs/pseudocode/、src/、tools/ 任何文件；未运行任何 jj/git 命令

---

## 一、覆盖率（fn 改为 「## 函数」节）

通过。

- elf.cr 共 18 个函数，4 个拆分文档合计 18 个函数节，一一对应无遗漏：
  - elf-1（4）：r16、w8_signed、emit_alloc_body、emit_alloc_body_simple
  - elf-2（11）：emit_heap_expand、emit_sched_call、sched_tramp_sz、emit_curg_stubs、emit_goroutine_stubs、emit_m_start_workers、sched_reg_one、w16、align_up、write_phdr、elf2_hdr
  - elf-3（2）：emit_start、emit_start_size
  - elf-4（1）：elf_gen
- instr.cr 共 29 个函数，3 个拆分文档合计 29 个函数节（小函数合并成节），无遗漏：
  - instr-1（22 节，含合并）：g2_init、get_reg_for_var、g2_slot、g2_str_off、g2_rodata_sz、e2_w8/w16/w32/w64、emit_rex/modrm/sib、e2_mov、e2_ld、e2_st、e2_li、e2_lr、e2_lrb、e2_lb、e2_call、e2_jmp/je/jae、e2_alu、e2_load_var、e2_rslot、sz_ofs、sz_load_var
  - instr-2/instr-3（1 节拆分两文）：emit_instr（IR_NOP~IR_CALL；IR_CALL_EXTERN~IR_DYN_DISPATCH + 后备）
- ld.cr 共 19 个函数，ld.md 有 19 个函数节，一一对应无遗漏：dyn_grow_so、dyn_grow_plts、grow_chunks、cnew、cby、so_find、so_find_any、layout、w32s、emit、patch_relocs、ctx_init、ctx_set_user_code、ctx_add_so、ctx_add_plt、ctx_emit_dyn、ctx_emit_so、so_parse_text、ctx_emit_static
- main.cr 共 4 个函数，main.md 有 4 个函数节：init_backend_arrays、split_links、corearch_main、main
- resolve.cr 共 1 个函数（res_labels），resolve.md 有 1 个函数节
- sizes.cr 共 23 个函数，sizes.md 全部覆盖（sz_mov…sz_start_argv_save + instr_size）
- _import.cr 为纯引入文件，_import.md 按约定以功能说明代替函数节，14 条引入语句全部列出且顺序与源码一致

拆分文档标注的行号范围与源码基本吻合；个别文档行号标注与内容错位（见 Minor-23）。

## 二、语义等价抽查（条件方向 / 边界值 / 字节值 / 返回路径 / 寄存器与操作数位）

抽查了 45+ 个函数节全文逐条对照（含全部字节级发射函数）：emit_alloc_body、emit_alloc_body_simple、emit_heap_expand、emit_sched_call、sched_tramp_sz、emit_curg_stubs、emit_goroutine_stubs、emit_m_start_workers、sched_reg_one、w16、align_up、write_phdr、elf2_hdr、emit_start、emit_start_size、elf_gen（全部 30 步）、g2_init、g2_slot、g2_str_off、g2_rodata_sz、e2_mov/ld/st/li/lr/lrb/lb/call/jmp/je/jae/alu、e2_load_var、e2_rslot、sz_ofs、sz_load_var、emit_instr（IR_CONST/BINARY/UNARY/CALL 内建 11 个/get_arg 全序列/DEREF/BRANCH/JUMP/LABEL/DYN_DISPATCH 等）、emit 全部 9 类块、patch_relocs、ctx_*、so_find、so_parse_text、ctx_emit_static、res_labels、sz_* 全部、corearch_main、split_links。

- 所有指令编码字节值（REX/ModRM/SIB/imm/rel8/rel32/opcode）、条件方向（>= / <= / > / < 的差一）、边界值（-128/127、-2147483648/2147483647、64MB、127/128 栈帧、BSS_ZERO_SIZE=131072、0x400000、176、E2_REG_SLOT_BASE=1000000000 等）、相对位移计算（rel32 基准 +4/+5/+6、rel8、jae/jne 自修补公式、rip_patch 位置 pos+3、target_va = bss_va+16+off 等）、修补位置（+1/+2/+3 偏移）均与源码逐条等价。
- 未发现条件反转或边界差一。

### Important-1　instr-1.md　发射 ALU 指令（e2_alu），运算结果寄存器方向误述（同一错误跨 3 处）

- 文档（instr-1.md 作用）：`发射双操作数 ALU 指令 op r11, r10 … 结果写回 r11`；测试要点 3 亦写 `add r11, r10 改为 1；sub r11, r10 改为 41`。
- 源码（instr.cr e2_alu）：opcode 0x01/0x29/0x39 均为 `r/m, r` 形式，ModRM rm=10%8=2（r10）是目的、reg=3（r11）是源，实际语义为 `r10 = r10 ± r11`、`cmp r10, r11`，结果在 r10。emit_instr 中 IR_BINARY 末尾 `e2_st(…, 10, do2)` 也从 r10 取结果，可证。
- instr-2.md 同错：IR_BINARY 加法分支注释 `此指令效果为 r11 = r11 + r10`、减法分支 `r11 = r11 - r10`、比较分支注释 `cmp r11, r10`；而同一节的收尾注释 `将运算结果（现在在 r10 中）存回栈帧目标槽位` 与自身矛盾。
- 影响：字节发射步骤全部忠实（照抄即正确），但「作用/注释」误导实现者与后续形式化读者；按注释理解会得出结果在 r11 的错误结论。

### Important-2　instr-2.md　IR_BINARY 右移分支，逻辑右移被误标为算术右移（sar / /7）

- 文档（OP_SHR 分支注释）：`第二步：sar r10, cl（操作码 0xD3，/7 扩展码，算术右移）`。
- 源码（instr.cr 第 344-352 行）：`emit_modrm(buf, pos+cp, 3, 5, 10%8)`，reg=5 即 /5 = SHR（逻辑右移），源码注释为 `shr r10, cl`。
- 文档同一分支的编码步骤又写 `寄存器字段=5（/5 扩展码表示 SHR）`，节内自相矛盾；按「sar /7」注释实现会发出 SAR（reg=7）而非 SHR（reg=5），产生不同指令。

### Important-3　instr-1.md　偏移量大小（sz_ofs）节标题标错

- 文档第 555 行节标题：`## 函数 发射加载字节（sz_ofs）`，「发射加载字节」是 e2_lb 的中文名（同文档第 430 行 `## 函数 发射加载字节（e2_lb）` 已占用），全局术语表中 sz_ofs 的中文名为「偏移量大小」（对照表第 36 行也正确写作「偏移量大小 | sz_ofs」）。同一文档出现两个同名的函数节标题，且其一对应错函数。

### Important-4　elf-2/elf-3/elf-4.md　gv_argc 中文名误标为「argv 全局变量索引」

- 三个文档的「全局状态」表（elf-2 第 69 行、elf-3 第 49 行、elf-4 第 149 行）均写作 `| argv 全局变量索引 | gv_argc |`，而 gv_argc 对应 g_rt_argc（argc，命令行参数个数），与 gv_argv（g_rt_argv_ptr）不是同一变量；语义正确的名字「命令行参数个数索引（gv_argc）」在同文档其他位置（elf-3 逻辑第 111 行、测试要点第 239 行；elf-4 逻辑第 287 行）又在使用，同文件内 gv_argc 两个中文名，且其一为错名，属于标识符标错。

### Important-5　ld.md　发射指令（emit）块类型 1，功能性字符串 .interp 解释器路径被完全改写

- 文档：`令 解释器字符串（is） = "动态链接器路径"`。
- 源码（ld.cr 第 222 行）：`is := "/lib64/ld-linux-x86-64.so.2";`，这是写入 ELF .interp 段的功能性字符串字面量，原始值在文档中完全丢失（无括号保留原名），按文档实现会产出无法启动的动态链接 ELF。违反审查维度 5「功能性字符串字面量（ELF 段名、错误消息）不应被翻译改写」。

## 三、样式合规（基准格式：作用/逻辑/测试要点三小节；逻辑节无英文关键字、无裸英文标识符；比较只用 大于等于/小于等于/大于/小于/等于/不等于）

- 三小节结构：全部 69 个函数/分支节均有 作用/逻辑/测试要点（合并节亦然），通过。
- 比较词：逻辑节未发现「不小于/不大于」等双重否定或非标准比较词，通过。
- 英文残留：逻辑节未发现裸英文关键字/标识符（x86 寄存器名 rax/r10、助记符 mov/lea 等符号记法属允许清单；首次对照括号内原名合规），通过。
- 发现问题：

### Minor-6　instr-1/2/3.md　循环叙述式写法偏离基准格式格式

- 大量使用「进入外层循环，每次迭代执行以下操作：如果 元数据索引 大于等于 优化元数据计数，则跳出循环」叙述式，而非基准格式「循环（当 条件 时）：」缩进式（elf-4 进度行还出现 `如果 函数索引 % 50 == 0：输出…` 的概括式写法，含 % 与 == 符号）。语义完整无缺，属格式偏离。

### Minor-7　instr-1.md　偏移量大小（sz_ofs）逻辑节注释未定稿

- 逻辑节含半成品注释：「返回 4（ModRM 1 + disp8 1 + 其他？不，实际为…但此处返回 4 是因为……）」「返回 7（ModRM 1 + disp32 4 = 5？实际对应……）」，带「？」「……」的未完语句混入正文；最终返回值 3/4/7 正确。

### Minor-8　instr-1.md　发射传送指令（e2_mov）中文名前后不一

- 标识符对照表与节标题用「发射 MOV」，逻辑与测试要点又用「发射传送指令（e2_mov）」（第 304、565 行），同一函数两个中文名。

### Minor-9　instr-2/3.md　「全局状态」节为内容为空

- 两文档「## 全局状态」均写「（本部分未单独列出全局变量；涉及的全局变量含义见「标识符对照表」）」，未说明含义与初始值（与组 1 报告的 Minor-4 同类）。

### Minor-10　instr-3.md　测试要点笔误/未定稿语句

- IR_DYN_DISPATCH 测试要点 5「全部跳转都是短 rel8（2 字节 je + 1 字节偏移量）」，je rel8 总长 2 字节；要点 6 含「额外？实际上是 4 处修补」的未定稿括注。IR_DEREF 测试要点 5 称「三处跳转修补（jae改为crash, jne改为safe, …）」，实际跳转修补仅 jae、jne 两处。

### Minor-11　elf-4.md　标识符对照表质量问题

- 重复行：「发射存储 | e2_st」（第 36、64 行）、「发射加载双字 | e2_ld」（第 37、65 行）、「向上对齐 | align_up」（第 62、87 行）各出现两次；「读 8 位 | r8 / load8」原名混入寄存器名；「带符号扩展的缓冲区读取 | bu8_signed_expand」为源码中不存在的虚构标识符（读回验证是内联代码，非函数）。

### Minor-12　elf-2.md　常量表与全局变量表不完整

- 常量表缺 E_PAD(8)、E_FLAGS(48)、E_SHENTSIZE(58)、E_SHNUM(60)、E_SHSTRNDX(62)、P_PADDR(24)（P_PADDR 在 write_phdr 逻辑中被使用却未列表）；全局变量表缺 gv_arena_cursors/gv_arena_sizes/gv_arena_pool_data/gv_arena_max_size、gv_hp_config/gv_hp_inflight、g_alloc_gl_jmp_pos（部分在 elf-1 表中已列，跨文档信息分散）。

### Minor-13　elf-2.md　curg 桩与 rt.s 语义翻译偏差

- 「设置当前协程函数索引（g_set_curg）」，g_set_curg 设置的是当前协程（G）指针，不是「函数索引」；「运行时（rt）.状态（s）」将汇编文件扩展名 .s 误译为「状态」。

### Minor-14　elf-1.md / ld.md　标识符对照表「首次出现函数」列错误

- elf-1.md「写 16 位 | w16 | emit_alloc_body」，w16 未在 emit_alloc_body 中出现（首次用于 elf2_hdr/write_phdr）；ld.md「ELF 输出缓冲区 | g_elf_buf | ctx_emit_dyn」，ld.cr 全文未使用 g_elf_buf。

### Minor-15　elf-1/2.md　个别指令解释的 REX 演算自相矛盾（照抄源码注释，字节忠实）

- elf-1.md 第 661-662 行 mov [r8], r10d（REX=68=0x44 无 B 位却称 rm改为r8）、elf-2.md 第 708-711 行 mov [r15-8], r12（REX=76=0x4C，B=0 却称 rm=7改为r15）：文档的字节值与源码完全一致（忠实），但 REX 位演算与其声称的寄存器解释矛盾（源码注释本身如此，源码可能存在潜在编码问题，不属文档引入的错误）。另 elf-2.md 发射调度调用 第 227 行 SIB=240（base=0）的推导同样先矛盾后以「按源码接受」收尾。

## 四、术语一致性（文档「标识符对照表」vs docs/pseudocode/标识符对照表.md）

- 共享标识符逐一比对：生成 ELF（elf_gen）、解析标签（res_labels）、发射单条指令（emit_instr）、全局变量初始化（g2_init）、全局变量槽位（g2_slot）、全局变量字符串偏移（g2_str_off）、全局变量只读数据大小（g2_rodata_sz）、发射 _start/_start 大小、发射分配函数体/简单分配函数体/堆扩展代码/协程桩代码/curg 桩代码/m_start_workers/调度调用、调度跳板大小、调度：注册一个、初始化链接上下文、链接上下文：添加 .so/添加 PLT 条目/发射动态链接/发射 .so/发射静态链接、扩展 .so 数组/扩展 PLT 数组/扩展块数组、新增通道/按种类查找通道、查找 .so 符号/查找任意 .so 符号/解析 .so 文本段、修补重定位、发射指令（emit）、写 32 位有符号（w32s）、写单字节有符号（w8_signed）、写程序头、ELF2 头写入、向上对齐、读 16 位、偏移量大小、加载变量大小、获取变量寄存器、发射 REX 前缀/ModRM/SIB、发射 MOV/存储/加载双字/加载立即数/加载寄存器/加载寄存器字节/加载字节/调用/JMP/JE/JAE/ALU/寄存器槽/写 8/16/32/64 位、加载 .ccr 文件、corearch 主入口、初始化后端数组、拆分链接参数、指令大小（instr_size）、加载立即数大小（sz_li）、_start 函数体大小、_start argv 保存大小、寄存器槽基址常量（E2_REG_SLOT_BASE）等，均与全局术语表一致。
- 发现的问题：

### Minor-16　ld.md　布局（layout）中文名偏离术语表

- 全局术语表为「布局计算 | layout」，ld.md 节标题与对照表均用「布局」。

### Minor-17　ld.md　标识符对照表将 load8 记为 str_load8

- ld.cr 实际调用的是内建 `load8`（如 emit 块类型 1），文档对照表写作「字符串按字节读取 | str_load8」；str_load8 是 src/compiler/dyn_arr.cr 中另一个函数（按驻留索引取字节）。main.md 同一函数写作「按字节读取 | load8」，两文档对同一源码标识符命名不一致，且 ld.md 的 原名 与源码不符。

### Minor-18　ld.md　取字符串第 N 字符（get_char）中文名偏离术语表

- so_find 逻辑中写作「取字符串第 总个数（N） 字符（" ", 0）」，术语表为「取字符串第 N 字符」；「总个数」为误译。

### Minor-19　ld.md　常量表含源码未声明的常量、SHT_PROGBITS 行表述混乱

- SHT_STRTAB（3）、SHT_PROGBITS（1）在 ld.cr 中未声明为常量（源码用字面量 3/1）；SHT_PROGBITS 行中文名「程序位节类型」与其原名单元格内的「程序数据节类型常量（SHT_PROGBITS）」互相矛盾。

### Minor-20　ld.md　cnew/cby 中文名「通道」与全文档「块」概念不一致

- 函数标题/对照表用「新增通道」「按种类查找通道」，而正文（作用/逻辑）及 grow_chunks 一律用「块」，同一概念两种命名。

## 五、功能性字符串字面量（ELF 段名、错误消息等）

- 大部分保留良好：ld.md 的动态段条目（DT_* 标签值）、动态符号表 st_info=18、PLT 编码字节、main.md 的 "error: cannot open "/"error: cannot read"/"error: empty code"/"error: linking failed"、emit_goroutine_stubs 中 str_intern("g_get_curg"/"chan_send"/"g_free"/"sched_schedule"/"sched_worker_run"/"alloc")、elf_gen 中 11 个内建名称比对串（syscall3/load8/store8/load64/r64/load_str_ptr/store_str_ptr/get_arg/w64/_dyncpy/goroutine_wrapper_addr）均原样保留。
- 发现的问题：

### Important-5　ld.md　.interp 解释器路径 "/lib64/ld-linux-x86-64.so.2" 被改写为「动态链接器路径」（原文丢失，详见二）

### Minor-21　ld.md / elf-2.md　ELF 魔数字符 'E' 注释误译为「'错误（E）'」

- 三处（ld.md emit 块 0、ctx_emit_static；elf-2.md elf2_hdr）：字节值 69（0x45）正确，但注释把魔数字符 'E' 译作「错误（E）」（E 是 \x7fELF 的字母，非 error），与同句 'L'/'F' 裸写不一致。

### Minor-22　main.md　错误消息与文件名局部改写（原文均保留在括号内，可还原）

- "error: invalid .ccr file"改为「error: invalid .线性指令流（ccr） file」；"error: cannot write "改为「error: cannot 写入（write） 」（×3）；"core_lib.so"改为「核心库（core_lib）.so」；"a.out"改为「默认输出（变量甲（a）.out）」，其中 "a.out" 的字母 a 被译作「变量甲（a）」（a 不是变量名，同模式还出现在测试要点 7 的 --link 变量甲（a）.so,变量乙（b）.so）；usage 帮助文本（7 行 println）被概括为「输出使用帮助信息（六行）」（行数也不准确，实为 7 行），且 "~/.core/lib/" 被译作「~/.核心（core）/lib/」。

### Minor-23　resolve.md / elf-4.md　调试输出字符串被改写

- resolve.md：「    res_labels: 」改为「    （res_labels）: 」、「 funcs, 」改为「 （funcs）, 」、「 instrs」改为「 （instrs） 」；elf-4.md：「  ni: syscall3=」改为「  原生内建索引（ni）: 三参系统调用（syscall3）=」等。信息可还原，但实际打印内容与源码不一致。

### Minor-24　拆分文档行号标注错位

- elf-2.md 标注「第 432-775 行」却含 write_phdr（源码 777 行）与 elf2_hdr（源码 792 行）；elf-3.md 标注「第 776-970 行」又称 write_phdr 已含于 elf-2，两文档范围互相错位。instr-2.md 标注「第 299-700 行」与 instr-3.md「第 603-1203 行」重叠（603-700）。elf-4.md 源文件路径写作「src/arch/linux/ld/可执行文件格式（elf）.cr」（文件名被翻译）。

### Minor-25　elf-4.md / sizes.md　零散细节

- elf-4.md Phase 2 第五步标题「累加 rodata 和 _init_globals 的大小」，正文忠实（rd_sz 读出后并未累加，仅 +6 _init_globals），标题有误导；instr-2.md 测试要点 3「8 个参数…约额外 11 字节」实际约 8 字节（2×push r10 4B + add rsp 4B）；sizes.md 标识符对照表「首次出现函数」列实际填的是原名；sizes.md sz_li 逻辑的 8 字节构成注释（「REX + opcode（2）…除去 SIB…」）计算说明自相矛盾，但返回值 8/11/14/17 全部正确。

---

## 分级问题清单汇总

| 级别 | 编号 | 文件 | 函数节/位置 | 问题 |
|------|------|------|-------------|------|
| Important | 1 | instr-1.md / instr-2.md | 发射 ALU 指令（e2_alu）；IR_BINARY 加/减/比较分支 | ALU 结果寄存器方向误述：「结果写回 r11」「r11 = r11 + r10」「cmp r11, r10」，实际 rm=r10 为目的（r10 = r10 ± r11、cmp r10, r11），与同节「结果在 r10 中」自相矛盾（跨 4 处） |
| Important | 2 | instr-2.md | IR_BINARY OP_SHR 分支 | 注释「sar r10, cl（/7 扩展码，算术右移）」与同节实际发射 reg=5（/5=SHR 逻辑右移）矛盾；按注释实现会发 SAR |
| Important | 3 | instr-1.md | 偏移量大小（sz_ofs）节标题 | 标题「发射加载字节（sz_ofs）」标错（「发射加载字节」是 e2_lb 的中文名，术语表 sz_ofs 为「偏移量大小」） |
| Important | 4 | elf-2/3/4.md | 全局状态表 + 逻辑行 | gv_argc 误标中文名「argv 全局变量索引」（应为命令行参数个数索引），与同文档其他处正确译名并存 |
| Important | 5 | ld.md | 发射指令（emit）块类型 1 | 功能性字符串 "/lib64/ld-linux-x86-64.so.2"（.interp 内容）被改写为「动态链接器路径」，原文丢失 |
| Minor | 6 | instr-1/2/3.md | 逻辑节 | 「进入外层循环，每次迭代执行以下操作」叙述式循环偏离「循环（当 条件 时）」基准格式；elf-4 进度行含 %/== 符号的概括式 |
| Minor | 7 | instr-1.md | 偏移量大小（sz_ofs）逻辑 | 注释含「？」「……」未定稿语句 |
| Minor | 8 | instr-1.md | e2_mov | 中文名「发射 MOV」与「发射传送指令」混用 |
| Minor | 9 | instr-2/3.md | 全局状态节 | 内容为空（未列全局变量含义与初始值） |
| Minor | 10 | instr-3.md | IR_DYN_DISPATCH/IR_DEREF 测试要点 | 「2 字节 je + 1 字节偏移量」笔误；「额外？实际上…」未定稿；「三处跳转修补」实为两处 |
| Minor | 11 | elf-4.md | 标识符对照表 | e2_st/e2_ld/align_up 重复行；「r8 / load8」混淆；虚构标识符 bu8_signed_expand |
| Minor | 12 | elf-2.md | 常量表/全局变量表 | 缺 E_PAD/E_FLAGS/E_SHENTSIZE/E_SHNUM/E_SHSTRNDX/P_PADDR 及 6 个 gv_* 全局 |
| Minor | 13 | elf-2.md | 发射 curg 桩代码 | g_set_curg 译作「设置当前协程函数索引」（实为指针）；rt.s 的 .s 误译「状态」 |
| Minor | 14 | elf-1.md / ld.md | 标识符对照表 | w16 首次出现函数标错；g_elf_buf 在 ld.cr 中未使用却列入 |
| Minor | 15 | elf-1/2.md | emit_alloc_body / emit_m_start_workers | 个别指令 REX 演算与其寄存器解释自相矛盾（照抄源码注释，字节忠实） |
| Minor | 16 | ld.md | 布局（layout） | 中文名「布局」偏离术语表「布局计算」 |
| Minor | 17 | ld.md | 标识符对照表 | load8 记为 str_load8（与源码及 main.md 的「按字节读取（load8）」不符） |
| Minor | 18 | ld.md | 查找 .so 符号（so_find） | get_char 写作「取字符串第 总个数（N） 字符」，偏离术语表「取字符串第 N 字符」 |
| Minor | 19 | ld.md | 常量表 | SHT_STRTAB/SHT_PROGBITS 源码未声明；SHT_PROGBITS 行中文名自相矛盾 |
| Minor | 20 | ld.md | cnew/cby | 「通道」与正文「块」概念命名不一致 |
| Minor | 21 | ld.md / elf-2.md | emit 块 0 / ctx_emit_static / elf2_hdr | 魔数字符 'E' 注释误译「'错误（E）'」（3 处） |
| Minor | 22 | main.md | corearch_main | 错误消息/文件名局部改写（.ccr、write、core_lib.so、a.out改为变量甲（a）.out、~/.core/lib/）；usage 概括为「六行」（实 7 行）且未逐字保留 |
| Minor | 23 | resolve.md / elf-4.md | 调试输出 | "    res_labels: "/" funcs, "/"  ni: syscall3=" 等调试字符串被改写（可还原） |
| Minor | 24 | elf-2/3.md、instr-2/3.md、elf-4.md | 头部行号/路径 | 行号范围错位重叠（elf-2 含 777/792 行函数但标注止于 775）；源文件路径写成「可执行文件格式（elf）.cr」 |
| Minor | 25 | elf-4.md / instr-2.md / sizes.md | 细节 | Phase 2 第五步标题误导（rd_sz 未累加）；「8 参数约额外 11 字节」实约 8 字节；sizes 对照表「首次出现函数」列填原名；sz_li 注释演算混乱（返回值正确） |

## 各维度结论

- 覆盖率：通过（elf.cr 18/18、instr.cr 29/29、ld.cr 19/19、main.cr 4/4、resolve.cr 1/1、sizes.cr 23/23，无遗漏）
- 语义等价抽查：有条件通过（字节值/条件/边界/返回路径全部逐条等价；Important-1/2 为注释级语义误述，Important-3/4 为命名问题，均不改变所发射字节）
- 样式合规：有条件通过（三小节与比较词合规；Minor-6~10 为格式/未定稿问题）
- 术语一致性：有条件通过（共享标识符与术语表一致；Minor-16~20 为 5 处局部偏离）
- 功能性字符串字面量：有条件通过（大部分保留；Important-5 原文丢失，Minor-21~23 局部改写）

## 一句话总结论

组 9（arch/linux/ld 12 个文档）覆盖率完整、所有指令编码字节值与边界计算逐条忠实于源码、无 Critical 级错误，但存在 5 项 Important（e2_alu 结果寄存器方向误述、OP_SHR 误标为 sar、sz_ofs 节标题标错、gv_argc 误标 argv、.interp 解释器路径字符串改写丢失原文）及 20 项 Minor（术语/样式/字符串细节），建议按清单修正后重跑归一化与 QA。
