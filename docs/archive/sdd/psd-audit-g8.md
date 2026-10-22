# 伪代码审查报告：组 8（`docs/pseudocode/stdlib/` 全部 18 个 .md）

审查人：只读审查员，组 8
审查日期：2026-08-09
审查对象：`docs/pseudocode/stdlib/` 下的 _import、arena、assert、chan、cli、collections、fmt、goroutine、hotpatch、io、math、os、panic、sched、scheduler、toml、trace、variadic，共 18 个 .md。
对照源：`src/stdlib/` 下的同名 .cr，共 18 个。
方法：逐一核对函数覆盖率；逐文件抽查语义等价，并发语义重点核对通道、协程、唤醒、锁路径，格式化重点核对负数、溢出、边界；检查样式合规、术语一致性、功能性字符串字面量。全程只读，没有修改任何文件。

## 一、覆盖率（通过）

18 个文件的全部函数，共 137 个 fn 加 2 个 struct，都有对应的“## 函数”节，无遗漏：

| 文件 | fn 数 | 覆盖 | 文件 | fn 数 | 覆盖 |
|---|---|---|---|---|---|
| _import | 0（纯引入） | 通过 | math | 10 | 通过 |
| arena | 5 | 通过 | os | 4 | 通过 |
| assert | 15 | 通过 | panic | 4 | 通过 |
| chan | 5 | 通过 | sched | 10 | 通过 |
| cli | 18 | 通过 | scheduler | 12 | 通过 |
| collections | 14 | 通过 | toml | 8 | 通过 |
| fmt | 13 | 通过 | trace | 3 | 通过 |
| goroutine | 3 | 通过 | variadic | 3 | 通过 |
| hotpatch | 4 | 通过 |  |  |  |

## 二、样式合规（通过）

- 每个函数节都有“作用、逻辑、测试要点”三小节，结构齐全。
- 逻辑节没有英文关键字，没有裸英文标识符。机械扫描确认，只有对照表的“原名”列和首次对照括号内允许英文。
- 逻辑节没有 `{`、`}`、`;` 符号。机械扫描确认；cli.md 的花括号已被错误改写，见 Important-2。
- 比较只使用大于等于、小于等于、大于、小于、等于、不等于，没有发现双重否定或条件反转。
- 保持 4 空格缩进和嵌套层级。
- 例外，不是样式红线，但属于表述格式问题：少数文件的签名行参数写成“中文名加另一中文名加（原名）”的双重命名，例如 cli.md 的“所需条目数 需求（needed）”、chan.md 的“通道容量 容量（cap）”，与 assert.md 的单重格式“条件（cond）”不一致。hotpatch.md 全部 4 节和 fmt.md 的 get_char 节缺少“函数 中文名（原名）（…）-> …”签名行。见 Minor 21、4。

## 三、术语一致性（基本通过，例外见 Minor）

对照 `docs/pseudocode/标识符对照表.md`，逐一核对各文件“标识符对照表”中的共享标识符，包括 stdlib 公开函数、g_* 全局、struct 名，绝大多数一致。不一致项有：goroutine.md 的 g_new、g_free 函数名；toml.md 的 4 个公开函数节标题；cli.md 和 toml.md 的 get_char；arena.md 和 scheduler.md 的 _dyncpy；sched.md 的 g_set_curg、g_get_curg 简称。详见 Minor 13 到 20。

## 四、分级问题清单

### Critical（1 条）

1. toml.md，配置获取字符串（toml_get_str）：返回路径不等价。源码内层取值循环中有一条“如果内容结束大于等于字符串总长度，那么返回空串”，缺失闭合双引号时立即返回空串并终止整个函数。文档把该语句改写成循环条件“循环（当内容结束小于字符串总长度时）”，等于把“立即返回”变成“退出内层循环后继续扫描下一行”。后果是，两行内容 `key = "unclosed` 加 `key = "ok"` 的场景下，源码返回空串，文档版本会继续扫描并返回 `"ok"`。这也与本文档自己的测试要点 5“缺失闭合双引号时返回空字符串”自相矛盾。这是典型的“返回路径被循环条件吸收”事故。

### Important（7 条）

1. cli.md，CLI：解析（cli_parse）：功能性字符串字面量被改写。源码 `println(" requires a value")` 被写成 `输出行（println）（" requires 变量甲（a） 值（value）"）`。“a value”被当作标识符翻译，实际输出内容改变，错误信息不再是 " requires a value"。
2. cli.md，CLI：输出帮助（cli_help）：功能性字符串字面量 `" {"`、`"}"` 被改写为“左花括号”“右花括号”，共 4 处。用法行为 `print(" {")` 和 `print("}")`，位置参数列表为 `print("   {")` 和 `println("}")`。实际帮助输出会打印“左花括号”，而不是花括号字符，用户可见行为改变。
3. io.md，输出行（println）：功能性字符串字面量 `"\n"` 被改写为 `"\数量（n）"`，位置在 `syscall3(1, 1, "\n", 1)`。写入标准输出的字节序列改变，本应是 1 字节换行，变成 7 字节中文字符。注释还写“长度 1”，与字面量自相矛盾。
4. os.md，获取可执行文件路径（get_exe_path）：功能性字符串字面量 `/proc/self/exe` 被改写为 `/proc/自身（self）/exe`，逻辑和作用各 1 处。这是实际传给 readlink 系统调用的路径，改写后非法。
5. os.md，获取环境变量（get_env）：功能性字符串字面量 `/proc/self/environ` 被改写为 `/proc/自身（self）/environ`，作用、逻辑、测试要点共 3 处。同上，路径被破坏。
6. os.md，执行系统命令（system）：功能性字符串字面量 `"-c"` 被改写为 `"-变量丙（c）"`，这是传给 /bin/sh 的参数，逻辑和作用各 1 处。shell 实际收到的参数改变。同一函数里 `/bin/sh` 却保留原文，处理标准自相矛盾。
7. fmt.md，字符构造（chr）：语句缺操作数。源码 `store8(res, 0, c)` 被写成“写单字节（c）”，丢失了缓冲区和偏移参数。下一行“写单字节（结果字符串，1，0）”是完整的，只有第一行残缺。伪代码语句不完整，无法形式化。

### Minor（22 条）

1. collections.md，头部：“源文件：源数组（src）/stdlib/collections.cr（127 行）”，目录名 src 被误译为“源数组”；行数应为 126，差一。
2. assert.md、panic.md、sched.md、hotpatch.md，头部：源路径写成“断言（assert）.cr”“恐慌（panic）.cr”“调度（sched）.cr”“热补丁（hotpatch）.cr”等非字面路径。其余 14 个文件使用纯原名，风格不一致。
3. panic.md，全部 4 个函数节：功能性字符串字面量“panicked at ”“panicked at:”“:”被替换为描述性占位“恐慌标记字符串”“冒号字符串”，丢失精确字面量。panic_at 的 "panicked at " 和 panic 的 "panicked at:" 两个不同标记串被合并为同一占位，无法区分。
4. hotpatch.md，热补丁加载配置（hp_load_config）：文件名字面量 `.hotpatch.toml` 被替换为描述“热补丁配置文件路径”，实际打开的文件名丢失。该节及其余 3 节都缺签名行。
5. math.md，取最大值（max）作用：“若两者相等则返回第一个参数值”。源码相等时执行 `return b;`，即第二个参数。作用描述与源码及自身测试要点 3“返回第二个值”矛盾。两值相等时观察结果相同，因此列为 Minor。
6. io.md，读取文件（read_file）作用：“读取后内容为空，均返回空字符串”。源码在 `nread` 不大于 0 时直接 `return buf;`，不写终止符，也不返回空串，与自身测试要点 3 矛盾。
7. fmt.md，取字符串第次数（N）字符（get_char）：节标题混入“次数”，应为“取字符串第 N 字符”，与术语表一致。该节逻辑缺签名行，参数字符索引（idx）未列入文件标识符对照表。
8. fmt.md，字符串比较（str_cmp）：字符串变量 b 被命名为“字符串第二子节点（变量乙）”。“第二子节点”是术语表中 AST 访问器 ast_b 的名字，变量名与编译器 AST 访问器名冲突。
9. fmt.md，字符串相等比较（str_eq）、字符串拼接（concat）等：正文大量使用“长度变量甲（a）（la）”“字符串变量甲（a）”式双层命名，先给中文名再给占位名再给原名，冗余，且与对照表条目 la/lb、lena/lenb 不一致。
10. cli.md，标识符对照表：残留一行“| 布尔 | bool | 包含判断（contains）|”。bool 和 contains 都不是 cli.cr 的内容，疑似跨文件复制粘贴。
11. scheduler.md，标识符对照表：残留一行“| 工作线程数 | n | 调度启动工作线程（sched_spawn_workers）|”。该函数属于 sched.cr。
12. goroutine.md，分配函数索引（g_new）、释放函数索引（g_free）：术语表中 fn g_new、g_free 的名字是“协程分配”“协程释放”，“分配函数 __builtin_new 索引”“释放函数 __builtin_free 索引”是全局变量条目名。文档把全局条目名用到了函数节上。sched.md 的调度启动协程（sched_go）正确使用“协程分配”，两个文档不一致。注：术语表本身对 g_new、g_free 有 fn 和 global 双条目，建议协调者裁决或消歧。
13. toml.md，4 个公开函数节标题：使用“配置获取字符串”“配置获取整数”“配置读取内存布局”“提取配置名称”，与术语表及本文件对照表条目“TOML：获取字符串”“TOML：获取整数”“TOML：读取内存布局”“提取 TOML 键名”不一致，文件内表头与正文自相矛盾。
14. toml.md，功能概要：TOML 全称被改写为“Tom'状态（s） Obvious Minimal Language”，应为 Tom's Obvious Minimal Language，“Tom's”被当作标识符翻译。
15. sched.md，调度让出（sched_yield）等：g_set_curg、g_get_curg 写作“设置当前协程”“获取当前协程”，术语表为“设置当前协程函数索引”“获取当前协程函数索引”，简称丢字。节标题“调度获取当前协程（sched_get_curg）”与文件对照表条目“调度获取当前 G”不一致。
16. sched.md，调度工作线程运行（sched_worker_run）：“令当前 M 索引 = 当前 M 索引（参数值）”。全局变量与参数同名，都译作“当前 M 索引”，该行语义虽正确，但表述不可读。
17. cli.md，CLI：获取布尔标志（cli_flag_bool）作用：示例“-值（v）”应为“-v”。
18. cli.md，内部：判断 CLI 标志、内部：剥离 CLI 破折号：get_char 写作“取字符串指定字符”，toml.md 写作“读取指定位置字符”，术语表为“取字符串第 N 字符”，fmt.md 使用正确。同一函数有三种译名。
19. arena.md、scheduler.md：_dyncpy 写作“内部动态拷贝”，术语表为“内部：动态拷贝”。
20. chan.md，创建通道、通道发送签名行：“通道容量 容量（cap）”“待发送值 值（val）”。签名参数为“中文名加另一中文名加（原名）”的三重命名，与文件对照表条目“通道容量”“待发送值”不一致。
21. cli.md，三个 grow 函数签名行：“所需条目数 需求（needed）”同第 20 条的三重命名问题。签名格式应统一为“中文名（原名）：类型”。
22. variadic.md，可变参数：函数是否有行号（va_fn_has_ln）测试要点：“单字符名 '变量甲（a）'”。示例函数名用“变量甲”作占位，风格异常。该例应直接使用 "a"。

## 五、逐维度结论

- 覆盖率：通过，137 个函数全部有对应节。
- 语义等价：不合格。1 处 Critical，toml_get_str 返回路径不等价；1 处 Important，fmt.md 的 chr 语句缺操作数。其余抽查函数，包括通道发送、接收、关闭，调度入队、出队、让出、调度，纤程全生命周期，int_str 负数和移位，str_int 溢出和负号，cli_parse 命令识别和缺值分支，TOML 整数和负号解析等，条件方向、边界值、分支顺序都与源码一致，没有发现条件反转或边界差一。
- 样式合规：通过。三小节齐全，无英文残留，无禁止符号，比较用词合规。
- 术语一致性：基本通过，例外见 Minor 12 到 19，涉及 goroutine.md、toml.md 标题、get_char、_dyncpy、g_set_curg 的译名。
- 功能性字符串字面量：不合格。7 处被翻译改写，集中在 cli.md、io.md、os.md，另有 panic.md 和 hotpatch.md 的描述性占位。

## 六、总结论

组 8 文档的覆盖率和样式全部达标，多数语义核对通过。但存在 1 处 Critical 语义偏差，即 toml_get_str 缺失“缺失闭合引号立即返回”的返回路径；另有 7 处 Important，包括 cli、io、os 三个文件的 7 个功能性字符串字面量被翻译改写，以及 fmt.md 的 chr 语句缺操作数。返工修复后可以通过本轮审查。
