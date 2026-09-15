# 编译时间线性化计划

日期：2026-09-04
状态：计划（待执行）
范围：corec + corearch 自举主链（`src/compiler/` + `src/arch/linux/ld/`）；时间、内存、IO 一并计入
目标（用户定稿）：**编译时间不出现超线性；且这个保证是数学上界，不是测量结果**

## 1. 目标与判据

### 1.1 排除性保证（主判据）

每 pass 一条**上界定理**：输入规模 N（按 pass 定义：token 数 / AST 节点数 / IR 指令数 / .ccr 字节数）下，耗时 ≤ C·N（C 为 pass 相关常数，hash 表按期望 O(1) 时定理中注明「期望」，翻倍 buffer 写总量界）。**定理成立 ⟹ 该 pass 结构上不可能显现超线性**——这是数学原因，不是测量结果。

定理清单 = 本文 §4；每改一个 pass 必须保持其定理成立（code review 对照项）。

### 1.2 机器证书（次级判据）

计数器插桩（`--emit-ops-cert` 模式）：每 pass 统计原语操作数（迭代次数、str_eq 次数、map 操作数、buffer 搬移字节），输出 `(pass, N, ops ≤ C_pass·N)` 证书。**每次真实编译携带线性证书**——定理人证，常数机器逐次验。普通构建零开销。

### 1.3 scaling 回归（守门判据）

代表性合成样本 ×1/×2/×4，断言时间比 ≤ 阈值（×2 ≤ 2.4、×4 ≤ 6.0，余量含噪声与缓存效应），同机中位数三次。不证明什么，只把「定理与代码脱节」的发现时间压到分钟级。进 CI。

### 1.4 非目标

- 不做常数级优化（上界存在即可，C 大小不承诺）；
- 不做并行编译、不做增量缓存（既有独立计划：`docs/superpowers/specs/2026-07-29-incremental-cache-design.md`、`docs/superpowers/plans/2026-08-15-cache-semantics.md`）；
- 不做 Python bootstrap 审计（用户范围裁定排除）；
- 不做 Coq 全机械化证明（远期选项，不阻塞本计划——上界定理人证 + 结构论证先行，计数器证书是机器检验的中间形态）。

## 2. 审计结论（2026-09-04，只读审计）

已确认线性、无需动的底子：`dyn_arr.cr` grow 全部倍增（append 平摊 O(1)）；`g_str_hash` 倍增 + 全量 rehash（平摊线性）；`ccr_io.cr` 写侧先算总长、单缓冲、一次 syscall（线性）；`resolve.cr res_labels` 是死代码不构成热点。

### 2.1 前端核心（src/compiler/）

| 位置 | 嫌疑 | 触发 | 判定 |
|---|---|---|---|
| checker.cr:215 `find_sym`、:225 `find_gsym` | 每标识符引用全符号表回扫 O(U×S) | 大文件/大函数 | 确定 |
| checker.cr:1502 mod 调用、:1563 方法调用、:845 `find_func` | 每调用点全表扫 O(C×M) | import/impl 方法多 | 确定 |
| checker.cr:265-346 borrow 表 | 每次 use 全表扫 + pop 数组左移 O(U×B) | `&` 借用多的函数 | 确定 |
| ir_gen.cr:672-684 EXPR_IDENT | find_local→global_let→ir_global 逐级全表回扫 | 大函数、全局引用多 | 确定 |
| ir_gen.cr:283 `track_str` | 每字符串字面量全表查重 O(L×S) | 字符串多 | 确定 |
| ir_gen.cr:29-50 `slice_len_*` | 每个赋值两次全表扫 O(A×S_slice)，表全局不清 | 有切片字面量的函数 | 确定 |
| ir_gen.cr:1147-1516 调用发射 | 每调用点 ~6 次 `find_func` 全扫 O(C×F×6) | 调用点多的程序 | 确定 |
| dataflow.cr:160 `df_connect_state` | 每 IR_CALL 一次 `find_func` | 同上 | 确定 |
| ptr_analysis.cr:15 / region_check.cr:13 / provenance_verify.cr:36 `*_is_in_unsafe` | **每 DF 节点扫全 g_sgs** O(N×SG)（ptr 版乘固定点轮数，最多 10 轮） | 任何程序，无条件（总是运行的安全 pass） | 确定 |
| provenance_verify.cr:18 `get_alloc_size` | ALLOC_STRUCT 名称→struct 线性扫 O(D×M_struct) | 结构体分配多 | 确定 |
| opt.cr:258 `alloc_registers` | 每指令扫全函数变量 O(I×V) | -O≥2 大函数 | 确定 |
| opt.cr:367 `pass_stack_share` | 双重循环 O(V²) | -O≥2 | 确定 |
| opt.cr:417 `pass_cse` | seen 线性查 + replace_map 每指令全扫 O(P²) | -O≥1 | 确定 |
| module.cr:442-605 `res_imports` | 每轮全量重扫 token + 重 tokenize 累积 g_source O(pass×T + K²)；:563 逐文件字符串拼接 O(K²) 复制 | 深 import 链 K 层 | 确定（残留） |
| module.cr:177 `reg_fileid` | 每文件注册全表查重 O(K²) | K 个 import | 疑似 |
| monomorph.cr:354 + 172 | 泛型实例缓存线性扫 + clone 逐节点查 dedup 表 | 泛型实例化多 | 确定 |
| lexer.cr:403 | 字符串字面量逐字节 concat O(L²) | 超长字面量 | 确定 |
| diag.cr:7 `read_source_line` | 每条诊断从文件头数行 O(诊断数×源长) | 大量错误（失败路径） | 确定 |
| dump.cr:279 | 每函数扫全 g_sgs O(F×SG) | dump 命令 | 确定 |
| interp.cr:343/410 | IR_JUMP 扫 loop 区域、IR_CALL 全扫函数表 | run/eval 模式 | 确定（次要） |

### 2.2 ELF 后端（src/arch/linux/ld/，无条件路径）

| 位置 | 嫌疑 | 触发 | 判定 |
|---|---|---|---|
| elf.cr:1475 前向 call 补丁 | 每 call 全扫 name_idx（str_eq）+ func_offsets O(C×F) | 任何构建 | 确定 |
| instr.cr:802 IR_CALL 发射 | 每 call 全表 str_eq 找偏移 O(C×F) | 任何构建 | 确定 |
| elf.cr:1200 Phase 3 | 每发射一函数回扫全部更新偏移 O(F²) str_eq | 函数多 | 确定 |
| instr.cr:67 `g2_str_off` + elf.cr:1024 | 从 0 累积重算偏移 O(S²×len) | 字符串常量多 | 确定 |
| instr.cr:26 `get_reg_for_var` | 每操作数扫全 g_opt_meta O(I×R_total) | --opt-level ≥ 1 | 确定 |
| instr.cr:1260 IR_LABEL | 每 label 扫全部 pending 前向跳转 | 大函数多前向分支 | 疑似 |
| ld.cr:328 `patch_relocs`、:448 `so_find` | 每重定位扫 PLT 表、每符号重扫 symtab | 动态/静态链接 | 确定/疑似（表小） |

### 2.3 最可能先踩雷（修复顺序依据）

1. `find_sym`/`find_gsym` 名称解析全表回扫——贯穿所有程序，大文件最先放大；
2. 三个总是运行的安全 pass 的 per-DF-node 全 g_sgs unsafe 扫描——输入越大越接近平方；
3. ELF 后端 name-based 补丁链（call 补丁 ×函数表、Phase 3 每函数回扫）——自举编译无条件触发。

## 3. 修复顺序（五批，每批自带上界定理更新）

护栏先行（§5 harness + 基线测量）→ 逐批修复 → 每批过证书断言 + scaling 比。

### Phase A：名称解析 id 化 + 哈希（雷区 1）

- checker：`find_sym`/`find_gsym`/`find_func`/方法表/mod 函数表 → 编译期一次建 hash（名→序号）或 AST 期符号编号；borrow 表改栈式按作用域分区 + pop O(1)（借用按作用域成批弹出）；
- ir_gen：`find_local` 按函数作用域链缓存；`track_str`/`slice_len_*` → hash；调用发射 6 次 find_func → 每函数一次解析结果缓存；
- monomorph：实例缓存 hash；clone dedup 表 hash；
- ELF：函数名 → id 直寻（call 补丁/发射/Phase 3 全链改 id 表 + 一次 name→id 建表）；`g2_str_off` 改一次 pass 建偏移表。
- 定理：以上全部 ≤ C·N。

### Phase B：unsafe 判定 O(1)/节点（雷区 2）

- ptr_analysis / region_check / provenance_verify 共享：unsafe 嵌套信息已存于 DFNode→region 显式映射，编译期一次线性预计算「节点是否在 unsafe 内」标志，三个 pass 改为 O(1) 查标志；
- provenance `get_alloc_size`：struct 名→序号 hash。
- 定理：每安全 pass ≤ C·N（指针分析含固定点轮数常量）。

### Phase C：opt 家族

- `alloc_registers`：按活性区间事件排序扫描；`pass_stack_share`：排序/按槽分组；`pass_cse`：seen 哈希化（opcode+操作数键）+ replace_map 版本化索引。
- 定理：O1/O2 各 pass ≤ C·N（pass_cse 的 seen 桶总量 ≤ C·N 需在定理中论证哈希键分布或退化为每桶常数级比对）。

### Phase D：module / import

- `res_imports`：单轮收集 + 每文件独立 tokenize + 已加载 hash set；累积 g_source 用预分配缓冲（总量线性）；链式 import 显式队列一次通过；`reg_fileid` hash。
- 定理：import 解析 ≤ C·T_total（T = 全部文件 token 总量）。

### Phase E：杂项收尾

- lexer 长字符串字面量：char buffer 倍增或预分配目标长度；
- diag `read_source_line`：行起始偏移索引表（错误路径一次建表）；
- dump：一次全表分区替代每函数全扫；interp 次要热点顺手修。
- 定理：各 ≤ C·N。

## 4. 上界定理清单（承诺升级版——code review 对照）

形式：每行一条定理。N 按 pass 定义；「期望」= hash 表随机种子假设；总量界 = 平摊严格线性。

| Pass | N | 定理 | 关键论证点 |
|---|---|---|---|
| lexer | 源字符数 | ≤ C·N | 每字符常数工作（含长字面量修复后） |
| parser | token 数 | ≤ C·N | 无回溯全扫 |
| checker（全部解析函数） | token/符号数 | ≤ C·N | Phase A 哈希 + borrow 分区 |
| ir_gen | AST 节点数 | ≤ C·N | Phase A 缓存 |
| dataflow（HDFG 构建） | IR 指令数 | ≤ C·N | 每指令常数边 |
| ptr/region/provenance | DF 节点数 | ≤ C·N | Phase B 标志（指针分析 ≤ C·轮数·N，轮数常数） |
| monomorph | 泛型调用 × 体节点 | ≤ C·N_total | Phase A 哈希 |
| opt（CSE/栈共享/分配） | IR 指令数 | ≤ C·N | Phase C |
| module/import | 全部文件 token 总量 | ≤ C·T | Phase D |
| ccr_io（写/读） | .ccr 字节数 | ≤ C·B | 已有单缓冲线性（维持定理） |
| ELF 发射 | IR 指令数 + 函数数 | ≤ C·N | Phase A id 直寻 |
| 内存 | 输入规模 | ≤ C·N | 翻倍总量界，禁止字符串逐字节 concat 类回归 |

## 5. 护栏落地

### 5.1 scaling 测试（tests/complexity/）

- 样本生成器（脚本合成 .cr）：大函数（N 语句 × 1/2/4）、多 import（K 文件 ×1/2/4）、大结构体、深泛型实例化、长字符串字面量、链式 import、ELF 发射（大 .ccr ×1/2/4）；
- 命令：`./build/corec build` 全链 + `./build/corearch` 各跑一遍；同机三次取中位数；
- 断言：×2 ≤ 2.4、×4 ≤ 6.0（首轮基线校准后可收紧）；
- 长任务遵守铁律 6：`cpulimit -l 10` 或 `nice -n 19`。

### 5.2 证书模式（--emit-ops-cert）

- 插桩点：pass 级迭代计数、str_eq 次数、map 操作数、buffer 搬移字节；
- 输出 JSON：`{pass, N, ops, C_pass}`；检查脚本 `check_cert.py` 断言 ops ≤ C_pass·N（C 常量表随修复更新）；
- 普通构建零开销（flag 关闭）。

### 5.3 承诺清单的强制

- 本文 §4 表 = code review checklist：改 pass 必须保持定理成立，破坏定理的改动需先改定理并说明；
- scaling 测试进 CI（develop 门槛已有 CI，直接并入）。

## 6. 验收

1. §4 全部定理成立（人证 + code review）；
2. `--emit-ops-cert` 在代表性样本上全绿；
3. scaling 回归全绿（修复前基线先测量留档，修复后 ×4 时间比 ≤ 6.0）；
4. 内存无超线性（样本峰值 RSS ×2/×4 比 ≤ 2.4/6.0）。

## 7. 关联

- 上游上下文：`docs/project-book.md` §二.1（编译时间膨胀）；历史已修：res_imports O(n²)（2026-06-30 会话）；
- 不并入：incremental-cache（07-29 spec / 08-15 plan）、lazy/概率 pass 的既有计划；
- 审计由只读子代理完成（2026-09-04），行号以当时 HEAD 为准，修复前逐条复核。
