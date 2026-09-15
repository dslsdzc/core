# 编译时间线性化计划

日期：2026-09-04
状态：~~计划（待执行）~~ → **已细化（2026-09-16：T1..T10 任务级拆解 + 7 裁决门 + §8 审计勘误）**——本文 §1–§7 保持原样（历史审计），**实施请以 §8/§9 + `specs/2026-09-16-compile-time-theorems.md` 为准**；§2/§3 的失效项已就地划销。
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
| opt.cr:258 `alloc_registers` | 每指令扫全函数变量 O(I×V) | -O≥2 大函数 | 确定（**已迁**：`src/arch/x86_64/regalloc.cr:406`，触发面 = corearch opt 路径——见 §8.1-E3） |
| ~~opt.cr:367 `pass_stack_share`~~ | ~~双重循环 O(V²)~~ | ~~-O≥2~~ | **已失效（2026-09-16 复核）**：该 pass **已停用/删除**（`opt.cr:345` 注 + `regalloc-consistency.cr:53`「2026-09-07 regalloc 移后端 D-3=b 已停用」）⇒ 本行划销 |
| opt.cr:417 `pass_cse` | seen 线性查 + replace_map 每指令全扫 O(P²) | -O≥1 | 确定（现址 `opt.cr:231`——见 §8.1-E2） |
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

- `alloc_registers`：按活性区间事件排序扫描；~~`pass_stack_share`：排序/按槽分组~~（**已失效**，见 §8.1-E1）；`pass_cse`：seen 哈希化（opcode+操作数键）+ replace_map 版本化索引。
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

> **2026-09-16 注**：本表的**现行权威副本 = `specs/2026-09-16-compile-time-theorems.md`**（含机检口径与「改动须同步」纪律）；本表保留为历史审计原貌（其 `pass_stack_share` 行已失效，见 §8.1-E1）。

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

---

## 8. 任务级细化（2026-09-16；纸面细化轮产出；**只读复核，未构建**）

> 输入 = 本计划 §1–§7 + 2026-09-16 逐条实读复核。**§8.1 勘误是开工前必读**（8 条行号漂移 / 2 条位置迁移 / 1 条已失效 / 后端目录退役）——照 §2 原文行号开工必错。
> 配套：**定理清单** = `specs/2026-09-16-compile-time-theorems.md`（review checklist）；**裁决门** = §9。

### 8.1 审计点勘误（逐条实读，2026-09-16）

| 类别 | 计划原文 | 现址（实读） | 处置 |
|---|---|---|---|
| **E1 已失效** | `opt.cr:367 pass_stack_share`（O(V²)） | **不存在**（`opt.cr:345` 注 + `regalloc-consistency.cr:53`「2026-09-07 regalloc 移后端 D-3=b 已停用」） | §2.1/§3 已就地划销；定理表不含它 |
| **E2 行号漂移（8 条）** | `checker.cr:215 find_sym` · `:225 find_gsym` · `:845 find_func` · `ir_gen.cr:283 track_str` · `ir_gen.cr:672-684 EXPR_IDENT` · `opt.cr:417 pass_cse` · `module.cr:442-605 res_imports` · `instr.cr:67 g2_str_off` / `:26 get_reg_for_var` | `checker.cr:805` · `:815` · `:1685` · `ir_gen.cr:678` · `ir_gen.cr:535-556`（find_local/find_global） · `opt.cr:231` · `module.cr:397+`（重 tokenize `:424/:649/:660`） · `instr.cr:75` · `:34` | 开工按**现址**定位；O(·) 结论全部仍成立 |
| **E3 位置迁移（2 条）** | `instr.cr:802 IR_CALL 发射` · `opt.cr:258 alloc_registers` | **`src/os/linux/callseq.cr:202`**（`cs_call_direct` 一行 `str_eq` 全表扫） · **`src/arch/x86_64/regalloc.cr:406`**（触发面 = corearch opt 路径，非 corec） | 修法落点改新址；scaling 样本**必须含 corearch 腿** |
| **E4 后端目录退役** | §2.2 全部 7 行写 `src/arch/linux/ld/{elf,instr,ld}.cr` | 现为 **`src/format/elf/{elf,ld,resolve}.cr`** + **`src/arch/x86_64/instr.cr`** + **`src/os/linux/{callseq,entry,syscall}.cr`**（三轴布局） | §2.2 路径**全部作废**，按新址复核（`patch_relocs` `ld.cr:328` 行号恰好未漂） |
| **E5 疑似升确定（2 条）** | `module.cr:177 reg_fileid`「疑似」 · `instr.cr:1260 IR_LABEL`「疑似」 | `module.cr:177-189` 全表扫；`instr.cr:1196-1211` 每 label 全扫 `g_pending_count` | 两条**均为确定**（O(K²) / O(L×P)），纳入相应 phase |
| **E6 须开工首日定位（2 条）** | `elf.cr:1475 前向 call 补丁` · `elf.cr:1200 Phase 3 回扫 O(F²)` | 前者：`src/format/elf/elf.cr` 内未见独立循环（`elf.cr:559` 注释证明「Phase 3 patch loop」存在） · 后者：未读到显式 O(F²)；但 `instr.cr:486 → g2_str_off` 的累积 O(S²) 已确认 | **T1 精确定位后再改**（不许按原文行号猜改） |
| **E7 头部「已确认线性」4 条** | `dyn_arr` 倍增 / `g_str_hash` rehash / `ccr_io` 单缓冲 / `resolve.cr res_labels` 死码 | 死码复核**确认**（`resolve.cr:17` 定义，无调用者）；`dyn_arr` 抽检成立；**`g_str_hash` 与 `ccr_io` 本轮未逐行读** | 后两条**须 T1 复核**（不得当成已核） |

### 8.2 任务表（T1..T10）

通则：每任务收尾 = 判据全绿 + 定理清单对应行复核 + 台账一行；改 pass ⇒ 同批改定理行（§5.3）。铁律 6 与 canary 硬闸（无豁免）全程适用。**行号一律取 §8.1 现址**。

| 任务 | 关键 Files | 步骤（摘要） | 判据 | 停条件 | 依赖 |
|---|---|---|---|---|---|
| **T1 前置** | 只读 + `tools/baseline/`；定理清单（**已落** spec） | ① 复核 §8.1-E6/E7；② 冻结基线重建（`rebuild.sh`，白名单换代）；③ 起点判据；④ 定理清单落纸（已落）；⑤ **修复前 scaling 基线**（×1/×2/×4 时间 + 峰值 RSS，×3 中位数） | 三 sha 入白名单 · canary `95084e7b…d475`(28822B) · `.ccr` 四条冷态 · 五 CI job rc=0 · 枚举（计数以实读为准）· 定理 12 行齐 · **基线数值入台账（须实测，不得预填）** | 起点判据任一红；基线三次离散 >20% | — |
| **T2 护栏①证书** | `globals.cr`/`main.cr`（flag）+ 插桩点 + `tools/cert/check_cert.py` | ① `--emit-ops-cert`（默认关）；② 先「零开销可得」类；③ TSV `(pass,N,ops,bounds,ok)`；④ 判定器；⑤ **开销实测** | 证书代表样本全绿 · 开关两态时间差 ≤1% · canary/四条零变化 | 开销 >1% 且退化被否 ⇒ 停（重开裁-CTL-1） | T1 |
| **T3 护栏②scaling** | `tools/complexity/{gen_scaled.py,run_scaling.sh}` | ① 六维同源缩放生成器；② runner（×3 中位数 + RSS）；③ 修复后/前比值表；④ 断言 ×2≤2.4 / ×4≤6.0 | 脚手架可复现 · 修复前基线比入台账（若不超线性须**如实标注**）· CI 时长实测 | 样本不稳（>20% 离散） | T1 |
| **T4 Phase A-前端** | `checker.cr`（find_sym/find_gsym/find_func/borrow）· `ir_gen.cr`（find_local/find_global/track_str/slice_len_*/调用发射）· `monomorph.cr` · `dataflow.cr` | 逐点 hash/缓存化，逐点保语义（遮蔽顺序/mangled 名/dedup） | 五 CI job rc=0 · canary/四条/DOT/dump 同锁值 · 证书 scan_steps ≤ C·N · scaling 该维 ×4 ≤6.0 · 枚举全绿 · 自举链 IDENTICAL | canary/四条变化（语义泄漏）；单点 >300 行 ⇒ 拆 | T2,T3 |
| **T5 Phase A-后端** | `callseq.cr:202` · `instr.cr:75/:1196/:34` · `format/elf/elf.cr`（Phase 3 + 补丁解析，**先定位**）· `format/elf/ld.cr:328/:108` | ① name→id 表；② call 补丁/发射/Phase 3 改直寻；③ g2_str_off 单遍偏移表；④ IR_LABEL pending 建桶；⑤ get_reg_for_var 直查 | **ELF 逐字节 canary IDENTICAL（硬闸）** · `.ccr` 四条不变 · 冻结基线 72 档零差异 · 证书 ≤ C·N · 自举链 IDENTICAL | ELF 任一字节变化 ⇒ 停 | T4 |
| **T6 Phase B** | `ptr_analysis.cr:15` · `region_check.cr:13` · `provenance_verify.cr:36/:6` · `dataflow.cr`（映射预计算点） | ① 线性预计算 unsafe 位图（复用 `g_df_node_region`）；② 三 pass O(1) 查；③ get_alloc_size struct 名→序号 hash | 三 pass `sg_scan_steps` 归零 · canary/四条/枚举全绿 · 安全类套件全绿 · 证书 ≤ C·N（指针 ≤ C·轮数·N） | 任一安全类诊断集合变化 ⇒ 停（语义面） | T2,T3 |
| **T7 Phase C** | `opt.cr:231 pass_cse` · `arch/x86_64/regalloc.cr:406` | ① 定位 replace_map 全部应用点；② CSE seen 哈希化 + replace 版本化；③ regalloc 活性区间排序（后端） | `-O0` 产物逐字节不变（零扰动）· 证书 cse_* ≤ C·N | `-O1/-O2` 产物非预期变化 ⇒ 停 | T2,T3 |
| **T8 Phase D** | `module.cr:397+ res_imports` · `:177 reg_fileid` | ① 单轮收集 + 每文件独立 tokenize + 已加载 hash set；② 累积缓冲预分配；③ reg_fileid hash | **import 解析语义零变化**（72 档 + 29 探针零差异 · `corec build <dir>` 逐字节同）· 证书 ≤ C·T_total | 任一档 import 计数/顺序变化 ⇒ 停 | T2,T3 |
| **T9 Phase E** | `lexer.cr:472-524` · `diag.cr:7` · `dump.cr:281-284` · `interp.cr:520/:91` | 逐点小改（char buffer 倍增 / 行偏移表 / 一次分区 / 顺手） | lexer 逐字节等价 · dump 同值 · canary/四条不变 | lexer 语义差异 ⇒ 停 | T2,T3 |
| **T10 收官** | `src/ci/run.sh` · 本计划 · 台账 | ① 全量回归（五 CI job + 枚举 + 自举链 + canary + 四条 + 72/29 + 暖态腿）；② 定理逐条复核；③ scaling 进 CI（时长而定）；④ 台账 + 终态 + TODO | 判据全套与批前逐项比对（**逐项标同/异 + 原因**）· scaling 全绿 · 证书全绿 · 内存比 ≤2.4/6.0 | 任一判据红 ⇒ 收官不成立 | T1..T9 |

**顺序建议（裁-CTL-6）**：**先 B（T6）后 A（T4/T5）**——T6 是**无条件**安全 pass（任何程序都踩），收益最快；T4 依赖点最多、风险最大。

**与 §3「五批」的映射**：Phase A → T4+T5（拆前后端）；Phase B → T6；Phase C → T7（**范围缩小**：`pass_stack_share` 已失效）；Phase D → T8；Phase E → T9；§5 护栏 → T2+T3。

---

## 9. 裁决门（**开工前置**；逐条 = 问句 / 影响 / 推荐 / 未取裁时）

| # | 问句 | 影响 | 推荐 | 未取裁时 |
|---|---|---|---|---|
| 裁-CTL-1 | 证书计数形态：①flag 门控单构建 ②双构建 ③只做零开销类 | T2 全部实现 | **①**（T2 实测开销 >1% 再退 ②） | 只做 ③（证书退化为趋势观察） |
| 裁-CTL-2 | `C_pass` 常数表来源：①人工定 + 实测校准 ②不设常数只做缩放比值 | 证书判定力 | **①** | ②（无「≤C·N」断言） |
| 裁-CTL-3 | scaling 入 CI 范围：①D1–D5 ×2 ②仅 D1 ③全维 ×4 | CI 时长 vs 覆盖 | **①**（D6/×4 手工） | ③ 或 ② |
| 裁-CTL-4 | CI 挂钩面：①新 job `complexity` ②并入 `selfhost-tests` ③手工 | 回归网形态 | **①**（时长实测后定死；超预算降级） | ③ |
| 裁-CTL-5 | 哈希基础设施：①复用 `g_str_hash`/`str_intern` ②新 side table（开放寻址） ③链地址 | T4/T5/T7 实现 | **①优先** | ② |
| 裁-CTL-6 | 批次顺序：①A→B→C→D→E（原文） ②**先 B 后 A** | 风险与收益次序 | **②** | ① |
| 裁-CTL-7 | 定理清单载体：①独立 spec + PR 模板勾选 ②留在本计划 §4 | 长期 review 强制 | **①**（已落 `specs/2026-09-16-compile-time-theorems.md`） | ② |

**停条件（全局）**：① canary 非 `95084e7b…d475`(28822B) 或 `.ccr` 四条冷态变值 ⇒ 立即停（发射面/盘面泄漏）；② 冻结基线同源对拍非预期差异 ⇒ 停（逐档归因后才可继续）；③ scaling 某维 ×4 >6.0 且修复后未改善 ⇒ 停该维回读；④ 证书开销 >1% 且退化被否 ⇒ 停（重开裁-CTL-1）；⑤ 单任务 >800 行或 >6 文件 ⇒ 拆；⑥ 任一 pass 语义面（诊断集合/产物字节）非预期变化 ⇒ 停（**性能批不得改语义**）。
