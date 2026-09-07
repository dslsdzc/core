// === regalloc-consistency.cr ===
// 分配器（贪心放置 CAG）逻辑正确性契约——文档载体（2026-09-06 定位修正重写）。
//
// 【本文件是什么 / 不是什么】
//   ✗ 不是规约（.corespec = 程序逻辑验证语言；寄存器分配一致性不是「程序逻辑」——
//     它属于编译器自身正确性：自举闭环后编译器是 Core 程序，分配器是其一段代码）
//   ✗ 不是规约语言文档（无 (* *) 语法——原 .corespec 形态已废弃）
//   ✗ 不是编译单元（不在 build concat 清单；verify 实现在 regalloc.cr，DRY）
//   ✓ 是分配器逻辑契约的注释文档：四条判定（regalloc-cache-mapping.md §四）在
//     Core 数据模型（条目/区间/共存）上的精确陈述 + 与实现的映射
//   ✓ 三层正确性各有其位（2026-09-06 澄清）：
//       程序逻辑规约  —— #check/#ensure（.corespec + 验证器）
//       分配器逻辑契约 —— 本文件（可验证对象；证书层 = 最优性证明，远期）
//       运行自检       —— verify_regalloc_consistency（regalloc.cr，corearch
//                         O2 路径实证——2026-09-07 regalloc 移后端后自算自检）

// 【语义出处】
//   条目/存在区间/共存 = v6 格式定稿 specs/2026-09-05-lattice-ir-v6-format.md
//     §3.4/§4（内存态闭区间 [ls,le]；落盘半开 le_disk = le_mem + 1）
//   判定四条 = docs/regalloc-cache-mapping.md §四（可判定、局部、条目泛型）
//   上下文贪心 = regalloc-cache-mapping.md（唯一分配算法定案）

// 【数据模型（Core 编译器内存态）】
//   条目 entry     = IR 变量 × 版本（每次定值 = 新版本；def=-1 = 参数/无定值单条）
//   存在区间       = 条目指令序存活闭区间 [live_start, live_end]（全局指令序）
//   共存 coexist   = 两条目区间相交（对称、无传递性——无格承诺，最弱理论）
//   位置 location  = 条目材料物理承载：寄存器（分配结果 = g_opt_meta REG_ASSIGN
//                    对 var→reg，后端 g2_slot 以 E2_REG_SLOT_BASE+reg 哨兵解析）
//                    或 home 槽（条目表 home 字段，分配器回填 seam——M1 未回填）
//   分配结果       = g_opt_meta REG_ASSIGN 对（var→reg）——corearch 进程内自算
//                    （2026-09-07 移后端；负编码写 IR 操作数是已废弃旧设计）

// 【四条判定（逻辑契约）——实现映射 src/arch/linux/ld/regalloc.cr】
//   ① 共存互斥：同位置（寄存器/home）的条目不共存
//      —— verify_regalloc_consistency 规则①（sweep：归并排序 O(k log k) +
//         组内最大 live_end 单遍——消费端门禁，不复用 O(E²) 两两）
//   ② 读点无陈旧：每个读点所在版本须为活跃版本
//      —— 规则②框架（rl_rule2_func；覆盖义务边界 = 首版本化定值后——
//         GC 批 2 已按格式定稿 §4.1 升级 dest≥0 定值建模（含 ALLOC_ARRAY/
//         STRUCT 内存对象诞生）——自动扩权，代码零改动，承诺已验证）
//   ③ 驱逐配对：被驱逐条目须有配对写回（未来：spill 机制落地后验）
//      —— 规约已述，代码 TODO——当前无驱逐（>5 共存 = 栈驻留），无事件可验
//   ④ 调用失效：调用点处 caller-saved 条目须失效/保存
//      —— 同上（caller-saved 标注落地后验）
//   注入红测试（--inject-* 通道）实证 verify 真消费数据：rules 1/1/2 诊断
//   （2026-09-06 定位修正注：R3/R4 不是独立「待实现挂账」——验证体系已闭环；
//    它们待验的数据源（驱逐机制/caller-saved 标注）属分配器演进，落地时规则②的
//    sweep/框架结构直接扩接，无架构改动）

// 【已知缺口（挂账）】
//   - 判定/条目表与分配器同为文字区间模型（非 CFG 活性）——RegionCheck 图层
//     接线时健全化（衔接决策 b 预留；行为语义锚兜底检测）
//   - pass_stack_share：已停用（2026-09-07 regalloc 移后端 D-3=b——原实现产物
//     死路径、corearch 恒空跑；恢复 = corearch 内以 alloc 同 seam 实现）
//   - param_ents=-1（重定值参数无入参版本条目：尾部 def=-1 补条 pass 条件
//     prev[lv]<0 = 从未定值才补，重定值参数全 def'd 条目 → 无入参版本条目；
//     未引用参数同形）= 数据面既有缺口（compute_entries 尾部补条逻辑——
//     regalloc.cr；.ccr 已不落 param_ents（恒 -1），原定向测试随 ENT 载体
//     消亡删除；入参版本条目建模 = 后续若判定②扩权需要）
//   - M-5：entries_coexist 无上界校验——已修（GC-1 守卫在 entries_coexist，
//     2026-09-06；探针 --inject-coexist-oob 随迁 corearch）

// 参考实现（唯一真源，勿在此复制代码）：
//   src/arch/linux/ld/regalloc.cr —— compute_live_ranges / compute_entries /
//             entries_coexist / coexist_version_conflicts /
//             verify_regalloc_consistency / alloc_registers（CAG 上下文贪心）
//             （2026-09-07 自 opt.cr 迁入 corearch——corec 侧不再含分配实现）
//   语法家 —— grammar/corespec.ebnf（程序逻辑规约用；SpecImplies 产生式为
//             corespec 语法演进保留，与本文件无绑定）
