# TODO.md「预存 Bug」节 · 可执行分类表

> 定位（受众/状态/出处）：受众 = maintainer（修缺陷者）+ 分诊者；状态 = active（一次性审计产物；后续以 TODO 内文为准）；出处 = 本表（分类与证据）+ `TODO.md`（条目现状）。
> 写入仓库说明（2026-09-16，R0-C）：原稿为 `/tmp/bugtriage/ledger.md`（零构建/零 `jj` 只读产出）；写入仓库时已同步 TODO 内文：标记完成 11 条（#5/#8/#11/#16/#25/#28/#29/#32/#35/#40/#55；#23 已在位标记完成）· #17 归档 · #31 文字勘误 · #20 定位点勘误。修复阶段（B1..B9）未开，见 TODO #2026-09-16-6。

范围：`TODO.md` 预存 Bug（不阻塞开发，待修复） = `:97–662`，含 #1–#65 共 65 个编号条目（其中 28 条自述为「实现登记/非缺陷」）。
方法：逐条读原文 + 实读源码/实跑只读命令核验（零构建、零 jj、主树零写入；行号一律当前实读值）。
日期：2026-09-16 · 证据路径 = 本文件各条「证据」列（源码 file:line 均为本轮实读）。
约定：四态 = 已修 / 仍然存在 / 部分结束 / 无法判定；类别 = 无提示错值·无提示错产物（最高优先）/ 明确崩溃 / 诊断缺失·误报 / 能力缺失项 / 卫生。

---

## 1. 分类表（逐条）

### 1.1 仍然存在（17 条）

| # | 一句话 | 现状 | 证据（本轮实读） | 类别 | 建议阶段 |
|---|---|---|---|---|---|
| #56 | 指针写可选槽 × 表示位：`*p = Some(9)` 双路径分歧无提示错值（ELF rc=8 / interp rc=216） | 已修（2026-09-16 (A) 阶段，TODO #2026-09-16-4 核销）：裁-REP-1 (iii) 取址槽恒装箱（W1–W6）+ ELF `IR_REF` 全局取址第二根因修复；c3 转正（自校验式断言）· c2 139 改为 7/7 · c1 保持 · 四形态全转正（`test_optional` 80 例）；canary `95084e7b…d475` IDENTICAL | 提交 `1e11353c`（#74）/ `5d36af98`（#75）；证据 `/tmp/capt6/` 及以下文件、`/tmp/capt7/` 及以下文件；残留转独立条目 TODO #2026-09-16-12（REP-3）/ #75（REP-2）/ #76（B04）/ #77（IR_REF 目标侧） | 已消除（无提示错值类） | B2（核心已消） |
| #14 | bootstrap 后端：全局初值非字面量（含一元负号） 会无提示降级为 0 | 仍然存在（有 live 实例在位） | `bootstrap/corec/frontend/ir_gen.py:70` `isinstance(decl.values[i], Literal)` 才赋 `constant_value`（非字面量，因此无值，因此后端 `.quad 0`）；live 实例：`cir_cache.cr:50` `CIR_CACHE_MAGIC : int = -4485090715960753727`，因此自举二进制写入磁盘 magic 实测全 0（T5 已把 spec 里 `C1C1…` 断言改为「magic 值不作承诺」= 文档按缺陷现状修改） | 无提示错值 | B1 |
| #9 | `extern >6 int 参`：`IR_CALL_EXTERN` 只做 6 寄存器分派，无栈参/清理，因此无提示语义缺失项 | 仍然存在 | `src/os/linux/callseq.cr:43-45` 文件头明载「IR_CALL_EXTERN 不调用二者（预存行为…>6 int 参 extern 调用的语义缺失项见 TODO 待实现，属波 2 参数化面）」 | 无提示错值（语义） | B3 |
| #13 | lexer 诊断前缀不一致（`error:` 无码 vs `error[XX]`）+ 重复打印 ×4 + 边缘形态分歧，因此既有守卫/测试门对 lexer 诊断零覆盖 | 仍然存在 | `lexer.cr:39-44` `add_error` 只存串；打印分两路：`diag.cr:159` `println("error: " + …)`（无码）vs `diag.cr:134` `print("error[")`，因此门扫 `error[` 时 lexer 面盲 | 诊断缺失/检查未检查范围 | B4 |
| #20 | F3：调用位点实参类型不匹配无诊断（`unify_types` 返回值被丢弃） | 仍然存在（P6 裁-P6-2 未决定，因此 E-12 未实施） | `checker.cr:1912` 定义 / `:2021` 丢弃点（`unify_types(pattern_ti, concrete_ti);` 无接收）/ `:3505` 使用点；定位点不一致：TODO 写 `:1053` | 诊断缺失 | B8 |
| #31 | CI 接入点缺失项（`selfhost-tests` / `bootstrap-tests` 未挂齐；点名守卫 `test_backend_bootstrap` / `test_lsp` / `test_slice_bounds`） | 仍然存在·部分改善（接入点 28 改为 31/54；`bootstrap-tests` 仍 3/7；缺失项未解决） | `grep -c 'python3 tests/selfhost/' src/ci/run.sh` = 31；`ls tests/selfhost/test_*.py` = 54；`test_backend_bootstrap.py` 在 run.sh 命中 = 0，且全仓无任何 runner/CI 调用它（`grep -rn` 仅命中 `build_selfhost_native.py` 的注释 4 处），因此该条自己点名的最高优先守卫至今只在手工全枚举里跑（注意：条目正文「早已挂」与实读矛盾） | 卫生/门覆盖（已致一次真实漏检：P3a 33×N06） | B4 |
| #6 | 双入口能力分歧：`src/targets/x86_64-linux/main.cr` 只注册 6 旗标 vs `corearch.cr` 全超集（22 处 `cli_flag`），因此 project-mode 无 `--table`/`--dump-*` 调试通道 | 仍然存在 | `src/targets/x86_64-linux/main.cr:33-38`（6 条：elf/shared/static/link/output/opt-level）；`src/compiler/corearch.cr` `cli_flag` 计数 22 | 能力缺失项/无提示面 | B3 |
| #7 | 无引用文件 `src/compiler/elf.cr`（26KB，零 importer、三面清单皆无）以同名符号与有引用文件碰撞；第二实例 = 同名两个有引用文件 `src/compiler/entry.cr`(73B) vs `src/os/linux/entry.cr`(6317B) 依靠回退链槽序维持可用 | 仍然存在（两面均在位） | `ls -l src/compiler/elf.cr` = 26054B；`grep -c 'compiler/elf.cr'` 在 `build_selfhost_native.py`/`src/compiler/_import.cr`/`src/targets/x86_64-linux/_import.cr` 三面全 0；`entry.cr` 两文件皆在 | 卫生（到可致无提示 N06） | B5 |
| #22 | 仓库卫生：suite 空 fixture ×2（`test_control_flow.cr`/`test_generics.cr`）+ `src/compiler/linker.cr` 0 字节 | 仍然存在 | `ls -l`：两 suite 文件 0B（4 月24 日）、`linker.cr` 0B，因此三件均在位 | 卫生 | B5 |
| #4 | 自举编译器巨型函数尾代码生成缺陷（`src/format/elf/elf.cr` 回填循环读未初始化栈槽，因此 dir 构建确定性 segv） | 仍然存在（带规避） | `src/format/elf/elf.cr:1173-1175` 注记「守卫重构（v7 Task 1 注记，编译器巨型函数尾既有代码生成缺陷规避）」，因此规避在位 = 非修复 | 明确崩溃（确定性 rc=139） | B7 |
| #12 | 类型别名仅一层解析（`type A=[int;2]; type B=A; g:B;`，因此双路径 rc=139） | 仍然存在 | `ir_gen.cr:2865-2877` `agg_elem_count_of`：命中别名行后 `if ast_kind(rt)==EXPR_ARRAY {return …} break;`，因此不递归至底 | 明确崩溃 | B7 |
| #10 | `src/format/elf/elf.cr` 三处手写 raw syscall 序列（mmap / clone / worker exit）= OS 轴纳入面；证伪「换轴零改动」承诺 | 仍然存在 | `elf.cr:457-463`（`mov eax,9` mmap 形）/`:663`（`mov eax,56` clone）/`:678`（`mov eax,60` exit） | 卫生/架构问题 | B3 |
| #65 | 有缓存状态「名字面」空缓存/有缓存分歧（`.cir` DOT 变量名掉前缀 + `.ccr` −108~117B） | 仍然存在（已归因，未实施修法；新阶段须裁） | 使用者实读 = `dataflow.cr:556`（DOT）+ `dump.cr:45`（dump）仅此两处；条目自陈「非无提示（诊断码集两态一致）+ 不传导产物」 | 卫生（非无提示） | B9 |
| #57 | E-4 可选程序 `.cir` 缓存门：机制实证证伪，因此维持现状；「移除门」为待确定候选 | 仍然存在（维持现状） | 条目自陈 + 门在位（`main.cr` 的 `g_optrep_on，因此 cache_enabled=0`；T0 复核定位点 `:484-490`） | 性能面/登记 | B9 |
| #64 | W4 备选：对「生成期分配共享面」的程序整体关 `.cir` 缓存（不实施，备选登记） | 仍然存在（备选） | 条目自陈（与 #60 阶段 (b) 修法同不变量、更粗粒度）；触发条件与 #57 同挂 | 登记 | B9 |
| #1 | 并发集成：多 M 未验证（worker loop 未连调度器完整测试；channel 等待队列多线程未验；G 结构 offset 56 字段语义重叠） | 仍然存在（能力/覆盖缺失项） | `src/format/elf/elf.cr:652-667` `m_start_workers` 仍为纯静态 stub（`emit_m_start_workers`）；条目自陈 | 能力缺失项 | B6 |
| #2 | 解释器局限（`for` label/branch 与顺序执行不兼容；无条件执行不支持 `IR_CALL`） | 仍然存在（设计边界） | 条目自陈（P6 T4a 报告亦称「`corec run` 解析面不支持方法调用语句」= 同族） | 能力缺失项 | B6 |
| #3 | 标准库补全（`math.cr`/`collections.cr` 为 stub；通用字符串/JSON 序列化待补） | 仍然存在 | `wc -l src/stdlib/math.cr` = 77 · `collections.cr` = 126（薄/stub） | 能力缺失项 | B6 |

### 1.2 部分结束（2 条）

| # | 一句话 | 现状 | 已收 / 剩余 | 类别 | 建议阶段 |
|---|---|---|---|---|---|
| #15 | R2 P0 类型项引擎实现登记 + 未覆盖面 1–6 | 部分结束 | 已收：1参数化原子变型（P3 T1）· 2 `AK_NAMED` 不展开（P5 T3 命名面判定化，改为身份链）· 5 `g_ty_uncovered` 上抛面（P5 T4 legacy 删除后 = ICE04 硬错）。剩余：3空递归（`inh_any_at` 深度守卫 512，因此-1，仍保守）· 4预算默认 200000（`ty_budget_reset`，未变）· 6 `ty_memo_rehash` 与「进行中」交互无实测覆盖（需运行，无法纸面判定） | 引擎未覆盖面 | B9（346 与判定面同族） |
| #17 | R2 P1 影子对照实现登记（开关/站点/决定归属） | 已失效（被 P5 T5 整体下线） | 并行的对照实现 12 函数 + 17 全局 + 2 CLI 通道已删（`--type-shadow` 注册面三处实核 = 零在位，见 #53 记录）；条目所登记的机制不存在，因此归档 | 登记（历史） | 归档 |

### 1.3 已修（16 条；均给可核证据）

| # | 一句话 | 证据（源码/已提交检查） |
|---|---|---|
| #5 | `.cir` 缓存跨编译器重建不失效（无提示重新生效坏产物） | `cir_cache.cr:95` `cir_compiler_identity()` 在位 + 头部 identity 字段（`:27`/`:214`）+ `test_cache_identity.py` 5/5（提交 `3be4cb48`） |
| #8 | 前端 ≥18 形参无提示误编译 | `dyn_arr.cr:89` `MAX_FN_PARAMS : int = 64` + `:467/:473` 读写护栏 + P020 硬错（提交 `d7ad71d3`/`68ffa1e8`） |
| #11 | 解释器 callee 内联缺 18 opcode（双路径分叉） | `tests/selfhost/test_interp_parity.py` 存在且挂 CI（run.sh 31 接入点内）；分派统一为单实现（提交 `9068629c`） |
| #16 | 函数体内嵌套 `fn`，因此 rc=139 | `parser.cr` P021 标记 3 处（`grep -c` = 3）+ `test_nested_fn.py` 17/17（提交 `f417d345`） |
| #18 | F1：同名 named 多行未规范化 | 条目已标记完成（…）+ `alloc_named_type` 去重侧表（提交 `3c8402e8`/`8c9d773f`） |
| #19 | F2：数组长度 N 判定放宽 | 条目已标记完成 + `array_len_constraint_ok` 六位下钻 + P3a T1 结束（`b36d8e76`） |
| #21 | F4：泛型后续形参声明类型不生效 | 条目已标记完成 + `infer_gen_call` 前扫 EXPR_PARAM（#34 P3a T5 记录） |
| #23 | harness 缺失项：`block-git.py` 可被复合命令绕过 | 条目自陈 2026-09-16 已修 + `tests/harness/test_block_git.py` 30/30 挂 `bootstrap-tests` |
| #25 | F5：元组元素连续槽位假设 | 两趟 wrapper 契约 + `test_tuple_slots.py` 14/14（提交 `0390f0f4`） |
| #28 | F5 同族：struct/structpat/array 字面量槽位 | 三分支两趟 + `test_agg_slots.py` 13/13（条目所在提交） |
| #29 | F5 同族剩余：名字绑定/三校验/同质性 | `test_agg_checks.py` 17/17 + TS01-04/TK02 入硬门（条目所在提交）；4 struct 模式绑定仍未实现（登记在 #29 正文，属新特性非缺陷） |
| #32 | `EXPR_LET` 无兼容检查 | `checker.cr:522` `check_let_annot_compat` + `:526` 豁免3 在位；`test_let_check.py` 挂 CI（P5 T6） |
| #35 | 枚举/结构体写入侧无护栏（≥17 越界写） | T0 守门复验实跑：17 变体，因此 `error[P22]` rc=1 无产物；17 字段，因此 `error[P23]`；`test_enum_limit.py` 13/13（P4 T6；容量阶段 E-3 起三 MAX_* 退役） |
| #40 | TF01 结束（`lits_copy` 洗白 + `ty_memo_slot_no_grow` 误报） | `checker.cr:728` `stmt_cannot_fall_through` 在位 + `check src/compiler` rc=0（T0 实测） |
| #55 | TC02 `if` 分支发散豁免 | `checker.cr:759` `stmt_diverges` 在位 + `test_tc02_branch.py` 挂 CI（15/15） |
| #60 (+#63) | 安全面诊断随 `.cir` 暖缓存无提示消失（冷 rc=1 到暖 rc=0 + 出 ELF） | `main.cr:564` `tc0 := g_type_count` 见证 + `:570` `if g_type_count == tc0 { save_cir_cache(…) }` 在位；`test_warm_cache_gate.py` 挂 CI；T3 暖缓存检查组入仓（`tools/baseline/warm_leg.sh`） |

### 1.4 实现登记 / 非缺陷（28 条；维持，不构成待修项）

| # | 主题 | 判定 |
|---|---|---|
| #24 / #30 / #33 / #34 / #36 / #37 / #38 / #39 | P2a / P2b / P3(T5) / P3a / P3b T0 / T2 / T6 / P3b 完成 | 登记（其「P5 继承项」四项已由 #47/#46/#48 全部实现，条目正文自注） |
| #41 / #42 / #43 / #44 | P4 T3 / T4 / T5 / 完成 | 登记（含 3 条实施偏差与未覆盖面） |
| #45 / #46 / #47 / #48 / #49 | P5 T2 / T3 / T4 / T5 / 完成 | 登记 |
| #50 / #51 / #52 / #53 / #54 | P6 T1 / T3 / T4a / T5 / 完成 | 登记（T2 = 本轮补记，见 6 节-4） |
| #26 / #27 | 检查重新确定 / 效应纯度阶段实现 | 登记（检查标准） |
| #58 / #59 / #61 / #62 | 容量阶段完成 / FC T2 / FC T3 / FC 完成 | 登记 |

---

## 2. 优先级排序（无提示类在最前）

P0 · 无提示错值/无提示错产物（最高）
1. #56 指针写可选槽 c3（双路径分歧 + 双错值，无诊断），已修（2026-09-16，(A) 阶段；见上表行）；残留四条 = TODO #2026-09-16-12（REP-3 `&s.a`）/ #75（REP-2 指针算术）/ #76（B04 借出后读）/ #77（`IR_REF` 目标侧）
2. #14 bootstrap 全局初值无提示 0（live 实例在位：`CIR_CACHE_MAGIC`，因此 `.cir` magic 实测全 0，格式与 spec 无提示不符；写读自洽故不炸测试）
3. #9 extern >6 int 参无提示语义缺失项（代码头注自称预存）

P1 · 门/诊断未检查范围（会让上面那类长期不可见）
4. #13 lexer 诊断前缀，因此全部既有门对 lexer 面盲
5. #31 CI 接入点（`test_backend_bootstrap` 至今未挂，已致 P3a 33×N06 无提示未定义逃逸一次）
6. #20 调用位点无诊断（F3；裁-P6-2 未决定）
7. #7 无引用文件同名碰撞 + 两个有引用的 `entry.cr`（链序重排即翻转，因此 N06 无提示类）

P2 · 明确崩溃（可控但真错）
8. #4 巨型函数尾 codegen（确定性 rc=139，带规避）
9. #12 别名一层解析（rc=139）

P3 · 能力缺失项
10. #6 双入口旗标分歧（project-mode 无表模式/调试通道）
11. #1 多 M 并发未验证 · #2 解释器局限 · #3 stdlib stub

P4 · 卫生/架构问题/登记
12. #10 手写 syscall 未纳入 · #22 空 fixture/linker.cr · #65 有缓存状态名字面（非无提示）· #57/#64 缓存门候选（性能面）· #15 引擎未覆盖面 346

---

## 3. 建议阶段清单（9 阶段）

| 阶段 | 范围 | 量级 | 前置 |
|---|---|---|---|
| B1 bootstrap 无提示初值族 | `bootstrap/corec/frontend/ir_gen.py` 初值提取扩展到一元负号/可折叠常量（或对不可判定初值发诊断，禁止无提示 0）+ `CIR_CACHE_MAGIC` 类负值常量迁「函数返回」形态 + `tests/bootstrap/` 用例 | 小（1 文件 + 2-3 例） | 与 `CIR_CACHE_VER` bump 同阶段（#14 正文要求） |
| B2 指针/别名写面无提示错值 | `*p = Some(9)` 及同族（数组元素/全局）的表示位缺失项主体已修（2026-09-16 (A) 阶段，#56 核销）；残留 = `&s.a` 写入丢失（TODO #2026-09-16-12，须 `IR_ADDR_FIELD`）· 指针算术边界（TODO #2026-09-16-13）；(D)「语言面拒绝」未取用（修法已使该形态正确，无需拒绝） | 低（残留为独立缺陷面）| 无（(D) 不再需要）|
| B3 ABI/入口/OS 轴纳入 | #9 extern 栈参分派（补齐或显式拒绝 rc=1）+ #6 旗标注册收敛（单注册函数或明确 divergence 守卫）+ #10 三处 raw syscall 纳入 `src/os/linux/` | 中 | 波 2 / 实例 B 前置；改 ld 单元，因此跑 `test_backend_bootstrap` |
| B4 诊断门与 CI 接入点 | #13 前缀统一（或门扫面扩，得到 `error:`）+ #31 至少挂 `test_backend_bootstrap`/`test_lsp`/`test_slice_bounds` + 全枚举回退办法 | 小-中（run.sh 数行 + lexer 打印 1 处） | 无；建议最高性价比（B4 是 B1/B2 类缺陷的可见性前提） |
| B5 仓库卫生 | #7 删/迁无引用文件 `src/compiler/elf.cr`（删除须用户许可，规则 3）+ 两个有引用的 `entry.cr` 改名或独立 fileid + #22 空 fixture/`linker.cr` 处置 + 伪代码对照表重生成 | 小（但删件须许可） | 用户许可（#7 正文自陈） |
| B6 能力缺失项（长线） | #1 多 M 并发端到端 · #2 解释器 for/IR_CALL · #3 stdlib math/collections | 大（独立路线） | 各自设计轮 |
| B7 遗留崩溃 | #4 巨型函数尾 codegen（修复后须还原 `elf.cr` 规避代码验证）+ #12 `agg_elem_count_of` 递归化（防环） | 中 | 独立于 v7 链（#4 正文注：仓促同修危及 byte-identical） |
| B8 调用位点判定 | #20 F3（`checker.cr:2021` 接线 + 非泛型调用位点新增判定点）+ 同族「`EXPR_ASSIGN` 无 never 豁免」（#52 登记） | 中 | 裁-P6-2(c)（纳入检查的检查成文化）+ report-only 先行 |
| B9 判定面残留与缓存面 | #15 346 · #57 移除门候选 · #64 W4 · #65 名字面（新阶段须裁） | 中 | 各自待确定；#60 阶段已挂两个可证伪触发条件 |

---

## 4. 建议标记完成清单（12 条 + 1 归档）

依据：标题未带 `删除线` 但正文/源码已证「已修」（标记完成 = 只改 TODO.md 标记，不动代码）。

| # | 标记完成依据（可核） |
|---|---|
| #5 | `cir_cache.cr:95` identity 函数在位 + 套件挂 CI（提交 `3be4cb48`） |
| #8 | `dyn_arr.cr:89` `MAX_FN_PARAMS=64` + 护栏 + P020（`d7ad71d3`/`68ffa1e8`） |
| #11 | `test_interp_parity.py` 挂 CI（`9068629c`） |
| #16 | `parser.cr` P021 三处 + `test_nested_fn.py`（`f417d345`） |
| #23 | 条目自陈 + `tests/harness/test_block_git.py` 30/30 挂 CI |
| #25 | `test_tuple_slots.py` 14/14（`0390f0f4`） |
| #28 | `test_agg_slots.py` 13/13 |
| #29 | `test_agg_checks.py` 17/17（注：4 struct 模式绑定 = 新特性，宜拆为独立登记项而非留在缺陷条目内） |
| #32 | `checker.cr:522` `check_let_annot_compat` + `test_let_check.py`（P5 T6） |
| #35 | T0 守门复验实跑（P22/P23 硬错）+ `test_enum_limit.py` 13/13；容量阶段 E-3 已把三 MAX_\* 退役，因此条目宜改「历史」 |
| #40 | `checker.cr:728` 落空分析 + `check src/compiler` rc=0（T0 实测） |
| #55 | `checker.cr:759` `stmt_diverges` + `test_tc02_branch.py` |
| #17 | 归档（其登记对象 = 并行的对照实现，已由 P5 T5 整体删除；`--type-shadow` 三注册面零在位） |

不建议标记完成：#15（346 剩余面开放）· #31（未解决）· #57/#64/#65（各自的待确定/触发条件未达）。

---

## 5. 重复项与互引（登记）

| 关系 | 说明 |
|---|---|
| #20 ⇄ #52 的 E-12 半身 | 同一条目（F3 调用位点）；#52 明载「E-12 半身未实施，挂裁-P6-2」+ 勘误「非泛型调用位点不存在（需新增判定点）」，因此实施时以 #52 勘误为准，#20 的定位点 `:1053` 已不一致（实读 `:2021`） |
| #56 ⇄ 容量阶段（#58 关联）⇄ (A) 阶段（#74/#75/#76/#77） | #56 是本条作者阶段的登记面；#58 完成点名「待确定 (D)」；(A) 阶段 2026-09-16 核销 #56（(D) 未取用）并把残留拆为 #74–#77 |
| #60 ⇄ #63 ⇄ #64 | 同一组（#60 = 发现+T2 实现，#63 = 完成，#64 = 同不变量的备选粒度） |
| #57 ⇄ #64 ⇄ #65 | 同属「缓存面残留」族（门候选 / 粒度候选 / 名字面归因） |
| #5 ⇄ #26 ⇄ #44/#45 | 「冷/热缓存态检查」族的多次重新确定（引用链：`#5` 末条，得到 `#26`，得到 `#44` 勘误，得到 `#45` 检查重新确定） |
| #31 ⇄ #34 ⇄ #48 | #31 的「代价实证」= #34 正文的 P3a 33×N06；#48 补挂 `test_named_dedup` 一档 |
| #14 ⇄ #43/#45 | #43 正文「触发实证 2」= #14 的 live 实例（`OE_BARE/OE_BOXED`）；修复方式（改函数返回）已推广，得到 `oe_bare()/oe_boxed()` |
| #8 ⇄ #35 ⇄ #33 登记2 | 同族「定长槽区越界写」（#8 形参区 16 改为 64 / #35 枚举区护栏 / MAX_GENERICS=4 另登记） |

已被后续阶段实质修掉但未标记完成：#5 · #8 · #11 · #16 · #23 · #25 · #28 · #29 · #32 · #35 · #40 · #55（12 条，见 4 节），#35 尤甚（其条目正文的「未解除（三上限仍为 16）」已被容量阶段 E-3 的「三 MAX_\* 退役 + P022/P023 停发」实质取代，但条目未标历史）。

---

## 6. 准确项（不会无提示）

1. 条数约定：节内 65 个编号条目（非 40），多出部分主要是 28 条「实现登记/非缺陷」记录。凡「仍然存在」判定均附本轮实读证据；凡依赖运行的（#1/#2/#15 6 等）只判「覆盖/设计缺失项」，不判运行时行为。
2. #31 的条目文字与实读矛盾（强化证据）：其 2026-09-13 进展句称 `test_backend_bootstrap.py`「早已挂」；实读：`src/ci/run.sh` 命中 0，且全仓 `grep -rn 'test_backend_bootstrap'` 除自身文件外只命中 `build_selfhost_native.py` 的 4 处注释，因此该守卫无任何 runner/CI 调用（只在「手工全枚举 58 档」路径里被执行）。本次按实读记为「未挂」，列入 B4 首阶段。
3. 未做实测（零构建约束）：#4 的 repro（需还原规避代码构建）· #1 多 M 端到端 · #12 别名崩溃复现 · #15 346 的可达性，一律标「需运行」。
4. T2（本轮任务）无 TODO 条目：#50=T1 / #51=T3 / #52=T4a / #53=T5，#55 已被 TC02 占用，因此建议 T6 以 #66 补 T2 实现登记（内容 = `docs/archive/sdd/p6-task2-report.md` 2 节–5 节摘录），本轮不代写（避免与 T6 清单冲突）。
5. 行号全部为当前实读（TODO 内文行号多已不一致，例：#20 的 `checker.cr:1053`，因此实读 `:1912` 定义 / `:2021` 丢弃点；#6 的 `src/arch/linux/ld/main.cr`，因此实读 `src/targets/x86_64-linux/main.cr`）。
6. 未触碰：主树零写入（本文件在 `/tmp/bugtriage/`）· 未跑 jj · 未构建/编译/测试（开工前 `ps` 实查：在场者为他 agent 的 `parity_run.sh`/`warm_leg.sh`/`corec ccr`，与本任务无关）。
