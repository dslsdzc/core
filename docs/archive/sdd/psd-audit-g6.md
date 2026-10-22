# 组 6 审查报告：main / corearch / module / project / diag / globals / entry / _import / elf / linker（psd-audit-g6）

> 只读审查，未修改 docs/pseudocode/、src/、tools/ 任何文件（本报告为唯一写入物）。
> 审查日期：2026-08-09
> 对照基准：docs/pseudocode/标识符对照表.md、docs/pseudocode/README.md、docs/archive/sdd/psd-translation-conventions.md、各组 .cr 源文件

## 审查范围与方法

| 文档 | 源文件 | 源 fn 数 | 文档函数节 |
|------|--------|---------|-----------|
| main.md（773 行） | src/compiler/main.cr（587 行） | 12 | 12/12 |
| corearch.md（352 行） | src/compiler/corearch.cr（149 行） | 3 | 3/3 |
| module.md（755 行） | src/compiler/module.cr（552 行） | 10 | 10/10 |
| project.md（91 行） | src/compiler/project.cr（56 行） | 1 | 1/1 |
| diag.md（269 行） | src/compiler/diag.cr（154 行） | 7 | 7/7 |
| globals.md（463 行） | src/compiler/globals.cr（182 行） | 5 | 5/5 |
| entry.md（23 行） | src/compiler/entry.cr（2 行） | 1 | 1/1 |
| _import.md（14 行） | src/compiler/_import.cr（34 行） | 0 | 说明节 |
| elf.md（881 行） | src/compiler/elf.cr（566 行） | 15 | 15/15（+2 结构节） |
| linker.md（9 行） | src/compiler/linker.cr（0 行，空文件） | 0 | 空文件说明 |

方法：全量逐函数节对照源码核对条件方向/边界值/返回路径/实参位（覆盖全部 55 个函数节，超过要求的 6 个抽查量）；样式合规按金标准逐节扫描；标识符对照表与全局对照表逐条比对；功能性字符串字面量逐条核对。

## 各维度结论

### 1. 覆盖率，通过
10 份文档与源码 fn 一一对应，无遗漏。linker.md（空源文件）与 _import.md（纯引入）按 README 约定简述，合规。

### 2. 语义等价，未通过（3 个 Critical、2 个 Important）
逻辑骨架保真度高的亮点：elf.md 的 measure_instr/encode_instr 全部 15 个指令族字节码（含 0F 94/9F/9D/9C/9E/95 条件码、jmp/je rel8 偏移 target-(cpos+2) 公式）、asm_to_bytes 两遍流程与 _start 14 字节；module.md 的 res_imports 全部 20+ 分支（@ 项目引用、:: 路径、别名、去重、段偏移 main_len+total_accumulated+pass_bytes+1、前导剥离 skip=len+1）；globals.md 的 find_plugin_entry/register_plugin_* 双条件匹配与 -2/-3 返回；diag.md 的 7 个函数逐条等价；main.md 的 is_decl_stmt/detect_imports/run 子命令包装分支结构（is_decl_stmt到return 0、has_lcall/has_call 判定）均与源码逐条一致，未发现条件反转或边界差一。
但 3 个文件的「逻辑」节存在整行碎裂/参数丢失（见 C-1~C-3），2 处实参与字面量错误（I-1、I-7）。

### 3. 样式合规，基本通过（仅 Minor）
所有函数节均含 作用/逻辑/测试要点 三小节；比较词只用 大于等于/小于等于/大于/小于/等于/不等于；逻辑节无英文关键字。个别作用节/注释碎裂见 Minor。

### 4. 术语一致性，基本通过（仅 Minor）
各文档标识符对照表与全局对照表的共享标识符映射全部一致（含 corearch 主入口/corearch_main、初始化后端数组/init_backend_arrays、拆分链接参数/split_links、加载项目/load_project、判断 .cr 文件/is_cr_file、ELF 写头/elf_write_header 等），未发现 cmd_ir/cmd_cir 式中文名↔原名对调。仅 module.md 函数节标题与自身对照表不一致（M-3）及若干共享名碎裂（M-4）。

### 5. 功能性字符串字面量，未通过（Important 多项）
大量程序实际输出/匹配用的字符串字面量被「汉译」或机械改写，且同一文档内自相矛盾（如 main.md 中 "ok" 一处保留一处译为（ok））。详见 I-2~I-6、I-8。

## 分级问题清单

### Critical（语义错误 / 信息丢失不可恢复）

- C-1 corearch.md「（corearch） 主入口（corearch_main）」：系统调用与关键写入的参数被机械碎裂，系统调用号/操作数丢失
  - 源码事实（corearch.cr）：`syscall3(2, src_path, 0, 0)`（open）、`syscall3(8, fd, 0, 2)`（lseek SEEK_END）、`syscall3(8, fd, 0, 0)`（lseek SEEK_SET）、`syscall3(0, fd, buf, fsize)`（read）、`syscall3(3, fd, 0, 0)`（close）、`w16(g_elf_buf, 16, 3)`、`syscall3(2, out_path, 577, 420)`、`syscall3(1, fd, g_elf_buf, sz)`。
  - 文档现状：逻辑节第 171 行「系统调用3（（sy）（open）（l3））（2，源路径，0，0）」、第 177 行「系统调用3（lseek）描（fd），0，2）」（数字 8 丢失）、第 178 行「系统调用3（lseek）（fd）」（参数全丢）、第 181 行「系统调用3（read）件（fd）符，（buf）冲区（size）小」、第 182 行「系统调用3（close）（fd）」（参数全丢）、第 215 行「写 16 位（ELF 输出缓冲区（e_type）」（偏移 16 与值 3 丢失）、第 217 行「系统调用3（2，输出字符串路径（open），420）」（577 丢失）、第 223 行「系统调用3（1，文件描述（write） 输出字符串缓冲区，ELF 总大小）」（fd 丢失）。另第 253 行「令 库路径（libp） = 字符（core_rt）径，0，最后斜杠位置 + 1）+ "（core_rt）.so"」为 str_sub(sp,0,last_sl+1)+"core_rt.so" 的碎裂残骸，函数名与实参均不可读。
  - 影响：系统调用号（2/8/0/3/1）是程序行为的关键常量，TDD 读者无法从文档复原；按文档实现会得到错误的文件操作序列。

- C-2 main.md「（corec） 主入口（corec_main）」与「编译源码（compile_source）」：三处初始化行碎裂，字符串字面量整体丢失
  - 第 569 行「令 缓存文件路径（（cach）（core）（t）（cache）"（cir）（re）/（cache）/（数据流图）/"」，源码 `.core/cache/cir/` 的初始化 `cache_path : ., mut = ".core/cache/cir/";` 碎裂，字面量不可复原；
  - 第 682 行「令 后端命令（（cmd）（corearch）（rearch） "」，源码 `cmd2 : ., mut = "corearch ";` 中 "corearch " 字面量丢失（后续 683-690 行对 --elf/--opt-level/--static/--link auto/-o 的拼接同样被改写）；
  - 第 745 行「令 错误消息（（err）（check） （errors）（ck） （errors）:"」，源码 `err_msg : ., mut = "check errors:";` 字面量丢失。
  - 影响：build 子命令实际执行的 shell 命令字符串与编译错误消息前缀均无法回源。

- C-3 module.md「解析引入（res_imports）」：home_dir 回退字面量与 so_idx_path 构造行碎裂
  - 第 637 行「令 用户主（home） （DslsDZC）（DslsDZC）"」，源码 `if str_len(home_dir) == 0 { home_dir = "/home/DslsDZC"; }` 的回退路径字面量丢失；
  - 第 638 行「令 扩展索引路径（so_idx_path） （core）主（lib）+ "/.（核心）/（lib）/" （index）统路径 + "/（index）"」，源码 `so_idx_path = home_dir + "/.core/lib/" + fs_path + "/index"` 碎裂，拼接结构不可读。
  - 影响：.so 扩展索引查找路径是模块系统功能行为，无法按文档复原。

### Important（字符串被汉译/改写、实参错误、值丢失）

- I-1 main.md「（corec） 主入口（corec_main）」run 子命令：dirname 实参错误
  - 第 360 行「令 源码目录 = 取目录名（0）」，源码 `g_source_dir = dirname(cli_arg(0))`（main.cr 第 213 行），实参应为「CLI：获取位置参数（0）」而非字面量 0。同节第 359 行写法正确，可作修复样板。

- I-2 main.md：功能字符串被系统化汉译/改写（20+ 处）
  - 子命令名与扩展名：第 320-321 行注册命令字面量 "cir"/"ccr"到「"数据流图（cir）"/"线性指令流（ccr）"」、第 611/649 行匹配字面量同步改写、第 615/652 行默认扩展名 ".cir"/".ccr"到".数据流图（cir）"/".线性指令流（ccr）"、第 674 行 ".ccr"到".线性指令流"；
  - 路径/命令：第 499/501 行 "rm -rf .core/cache/cir/" 中 core到核心（core）、cir到数据流图（cir）；第 508 行 " requires a source file or directory" 中 a到变量甲（a）；第 518 行 "error: cannot locate src/runtime/rt.cr" 与第 521 行 "\n" 拼接被改写；
  - 帮助与回显：第 319 行 "Type-check only"到"类型（Type）-check only"、第 347-348 行 examples 中 cir/ccr 被汉译、第 618/655/677 行 "write"到写入（write）、第 640 行 "lower to ccr..."到"lower to 线性指令流（ccr）..."；
  - run 子命令包装源码（第 447/462/465/468/472/487/490 行）：`"fn main() -> int {\n"` 丢失花括号、`";\nreturn 0;\n}\n"` 碎裂为「\（nreturn） 0\（数量）\（数量）」（分号与右花括号丢失）、第 425/437 行 `get_char == ";"` 的字面量 ";" 被改写为空字符串 "";
  - 第 685/687/689/690 行 "--opt-level"/"--static"/"--link auto"/"-o" 全部被改写；compile_source 节 "ok"到"（ok）"（第 734/756/759/762 行）与第 527 行保留的 "ok" 自相矛盾。

- I-3 corearch.md：功能字符串被汉译/改写 + w16 参数丢失
  - 第 160 行 "usage: corearch <file.ccr> [options]" 中 ccr到线性指令流（ccr）、第 164 行 "link ~/.core/lib/*.so (default)" 中 core到核心（core）、第 144 行 "or 'auto' for ~/.core/lib/" 中 "for" 被误作关键字译成 遍历（for）；第 211 行默认输出名 "core_lib.so"到"（core_lib）.so"；第 232 行 "a.out"到"（a）.（out）"（与 project.md 同类，见 I-5）；第 253/263 行 "core_rt.so"到"（core_rt）.so"；第 219/303/328 行 "write"到写入（write）；
  - 第 215 行「写 16 位（ELF 输出缓冲区（e_type）」丢失偏移 16 与值 3（源码 `w16(g_elf_buf, 16, 3)`，ET_DYN 修改依赖此值）。

- I-4 diag.md：错误类别前缀与换行符字面量被汉译
  - 错误类别前缀（error_cat_prefix）逻辑节：类别 2 的返回字面量 "N"到「"次数（N）"」（第 165 行）、类别 15 与默认分支的 "E"到「"错误（E）"」（第 178/180 行），程序实际输出 "error[N…]"、"error[E…]" 前缀；同一函数内 "P"/"TA"/"TB"/"ICE" 等保留原文，自相矛盾；
  - 读取源码行（read_source_line）第 63 行：换行符字面量 "\n"到「"\数量（n）"」，而第 66/88 行同义比较又保留数字 10，前后不一致。

- I-5 project.md「加载项目（load_project）」：回退输出名 "a.out" 被改写为「"变量甲（a）.out"」
  - 源码第 37 行 `fallback_name = "a.out";`（无任何名为 a 的变量），文档第 67 行写作「令 回退名称 =（字符串 "变量甲（a）.out"）」，自造标识符 变量甲 不在本文档标识符对照表与全局对照表中，且改变程序实际输出的默认二进制名。按文档实现会产出错误文件名。

- I-6 module.md：功能字符串被汉译/改写（15+ 处）
  - 第 195 行 "_import.cr"到"（_import.cr）"、第 527 行 "main"到"（main）"、第 607 行 "Core.toml"到"Core.（toml）"（且 项目配置路径 局部名碎裂为（pro）（src）（oml））、第 620/644-657 行 ".cr"到".（cr）"、第 660 行 "!! import fail: "到"!! 引入（import） fail: "、第 712/503/510 行 "\n" 拼接字面量碎裂为「\（n）」、「\（数量）」；
  - 注册 .so 函数（reg_so_funcs）逻辑节：索引格式关键字 "variadic"/"auto_str"到"（variadic）"/"（auto_str）"、类型名字面量 "int"/"string"/"unit"/"float"/"bool" 全部改写、第 315 行返回类型默认值 "unit"到"（单元类型）"，这些字符串是索引文件逐字节匹配的对象，改写后 TDD 无法比对。
  - 注意：逻辑结构本身（编码公式、分支、符号表写入）与源码逐条等价，仅字面量被改写。

- I-7 elf.md「ELF 结束（elf_finish）」与「ELF 写头（elf_write_header）」：参数/值丢失
  - elf_finish 逻辑节（第 280/282/283 行）：`syscall3(2, path, 577, 420)` 的 path 实参丢失（被（open）注释顶替）、`syscall3(1, fd, ctx.buf, total_size)` 的 fd 丢失、`syscall3(3, fd, 0, 0)` 参数全丢；
  - elf_write_header 逻辑节：第 198 行「写 16 位（e_phentsize）」丢失值 56（程序头条目大小，关键常量）、第 202 行 e_shentsize 丢失值 0、第 206 行 e_shstrndx 丢失值 0。

- I-8 elf.md：固定模式指令字面量被汉译（精确匹配用功能字符串）
  - measure_instr 第 349 行与 encode_instr 第 463 行："    ret"到「"    返回（ret)"」，这是与汇编文本逐字节精确匹配的模式串，改写后按文档实现永远匹配不上；
  - 第 394/602 行 "    mov qword ptr [rbp" 前缀碎裂为「（qword） （ptr） （qword） （指针） [rbp"」，第 424-425 行 "    jmp .Lret"/"    je  .Lret" 前缀碎裂为「（Lret） jmp .（Lret）」；第 737/741 行「写字节（store8）（x90）缓（NOP）代码当前写入位置，144」缓冲区名碎裂。
  - 除字面量外，measure_instr/encode_instr 的全部字节码数值与返回长度（含 mov edi 的 slen>12+13 前缀怪癖）与源码一致。

### Minor（小瑕疵）

- M-1 全部 10 份文档「源文件：…（N 行）」行数统一 +1（entry 2到3、_import 34到35、project 56到57、diag 154到155、corearch 149到150、globals 182到183、main 587到588、module 552到553、elf 566到567、linker 0 正确）。
- M-2 entry.md 头部「源文件：src/compiler/入口条目（entry）.cr」与 main.md 头部「src/compiler/主入口（main）.cr」，源文件路径被汉化，路径应保持字面量。
- M-3 module.md 函数节标题与本文档对照表/全局对照表不一致：计数换行符 vs 计数newlines；获取文件标识符 vs 获取fileid；加载共享引入文件 vs 加载引入；父目录 vs 父dir；构建行号到文件映射 vs 构建行号fileid（函数节标题用了译名，表格用原名，读者按标题检索会找不到表项）。
- M-4 module.md 逻辑节共享标识符碎裂：「（TOML）（TOML） 键名」（应为 提取 TOML 键名/extract_toml_name，第 610 行）、「主文（main）符串」（第 527 行）、「词法（AT）数组」（第 559 行）；测试要点 11（第 751 行）整体碎裂为「项目引用（@project）（toml） Core（src）（ml）（project）（c）/<（file）（ec）（cr）/<（file）>.（cr）」。
- M-5 main.md 注释/夹注碎裂：is_decl_stmt 第 115-116 行「大于等（a） 97（z）」、detect_imports 第 156-161 行「等（i） 105」「索引（m） 1」「（t）等于 116」、读取静态运行时源码 作用节（第 226 行）与编译器主入口 作用节（第 766 行）语句碎裂不可通读；取目录名（0）同一行内 get_char 对应「取字符串第（N）字符」夹注位置错误。
- M-6 globals.md 标识符对照表双重命名「名称名/名称驻留索引」「命名空间名/命名空间驻留索引」；全局状态表中 g_next_label 初始值标注 1，但 globals.cr 声明无初始化器（实际由 ir_gen.cr:1950 / main.cr:383 在初始化时置 1），与同表其余变量「按声明初始值」的口径不一致。
- M-7 diag.md 打印诊断信息（print_diagnostics）逻辑节局部变量「总行数」未按首次对照规则带原名（source_lines）；对照表「当前字符 | c」与全局对照表「当前字符 | cur_char」重名（局部变量应避免占用共享名）。
- M-8 corearch.md 测试要点 8「纯静态无 --（link） 模式设置 x86 是否需要发射运行时桩标记 = 1」遗漏了「且非 --shared」条件（源码为 link_val 为空 且 emit_so 为 0）；初始化后端数组 作用节「（corearch）次 （corearch） 管线开始时调用」碎裂。
- M-9 main.md 输出字符串中文名不一致：corec_main 节多处「输出字符串（print）」与「输出行（println）」混用（项目级文档中 print 有「输出字符串」与「输出」两种译名），建议统一为总表「输出字符串」。
- M-10 elf.md 测试要点/注释夹注混杂：「测试要点 6（jmp） .（Lret1）」、第 147 行「0（x7f） '（E）' '（L）' '（F）'」（'E' 被译名顶替）等，属机械改写痕迹，不影响语义但不符合「注释译成中文」的整洁标准。

## 总结论

组 6 的 10 份文档覆盖率完整、逻辑骨架（条件方向/边界/返回路径/字节码数值）总体与源码高度等价（elf.md 的指令编码、module.md 的 res_imports、globals.md 的插件注册、diag.md 的诊断输出均逐条吻合，未发现函数名对调或条件反转），但存在 3 个 Critical（corearch_main 系统调用参数碎裂、main.md 三处初始化行字面量丢失、module.md home_dir/so_idx_path 行碎裂）、8 个 Important（功能字符串被汉译/改写贯穿除 globals/linker/entry 外的全部文档、dirname 实参错误、e_phentsize 值丢失）及 10 个 Minor，其中功能字符串的系统性汉译（"cir"/"ccr"/"ret"/"a.out"/"N"/"E" 等）与整行碎裂问题需优先修复后方可合入。
