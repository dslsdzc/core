# 寄存器分配移后端设计（编码层资源决策归位）

日期：2026-09-07
状态：**设计定稿 + 实施完成（2026-09-07——R1-R5 全部拍板落地，见 §6 决策记录与
实施计划执行记录）**
关联：`docs/regalloc-cache-mapping.md`（判定四条/上下文贪心）、`specs/2026-09-05-lattice-ir-v6-format.md`（v6 ENT home）、`specs/2026-09-06-int-multiword-backend-design.md`（多字表示 = 后端）、`specs/2026-09-05-hardware-interface-table.md`（优化不进表——判定/分配在格形态层）、compile-time-linearity 计划（corec 时间分布）。

## 1. 归属论证

**寄存器是物理资源——分配是编码层决策**（与 int 多字表示、指令发射同层）。现状分配器在 corec（opt.cr）纯属历史（v5 时代后端无决策能力）；「g2_slot 负编码 = 纯机械翻译分配结果」的表述把后端钉成执行者——分配归位后此表述取消：后端自己做分配，g2_slot 是后端的槽解析 seam（决策的一部分），非机械翻译。

```
现状：corec（数据面+分配+判定）→ .ccr 传 REG_ASSIGN → corearch 机械消费负编码
目标：corearch（数据面+分配+判定+发射 = 全部编码层决策）
      corec 只产语义（.ccr 无 opt_meta——分配结果不再跨进程传输）
```

## 2. 迁移形态（决策点 R1 —— **R1a 拍板落地**）

opt.cr 相关函数（compute_live_ranges/compute_entries/共存/alloc_registers/verify）——**按层拆分（R1a）**：
- opt.cr 现既在 corec 闭包（优化 pass 含 CSE 等仍属 corec 吗？——CSE/pass_cse 是图优化=语义层？分配是编码层——opt.cr 里两类混居）
- **R1a（拍板）**：opt.cr 拆分——语义优化（AST 常量折叠 + pass_cse 留 corec）与编码决策（数据面/共存/分配/判定/注入）移 corearch（新文件 `src/arch/linux/ld/regalloc.cr`，加入 corearch 闭包）。corec 侧 opt.cr 1940→312 行（剩件 = AST 折叠 + CSE + optimize_all 死码编排入口）；main.cr O2 段/`cir` 调试通道摘除
- R1b（弃）：整文件入 corearch 闭包——CSE 是图优化应留 corec

## 3. .ccr 简化（决策点 R2 —— **D-1=Y 拍板落地**）

- opt_meta（含 REG_ASSIGN）出 .ccr——分配结果不再传输（corearch load 后自算）
- **ENT 段恒空（D-1=Y）**：corec save 不再落条目——SYM func/REG `first_ent/last_ent` 恒 -1、param_ents 恒 -1、ENT 段 0 条、opt_meta 子节 0 块；**格式结构保留**（loader 空表语义已支持：段缺失/0 条 + pcnt==0 ↔ -1 对照），**零 version bump**。ENT home 字段随 ENT 落盘消亡（内存表 home 字段保留——corearch 自算内存态，M1 分配不回填）
- 数据面计算单宿主 corearch：compute_live_ranges/compute_entries 随 regalloc.cr 迁入，载入 NOD 流自算（与 .ccr 载荷同坐标）——corec lower 尾/落盘直写废止

## 4. 判定位置（决策点 R3 —— 拍板落地）

verify_regalloc_consistency/regalloc_verify_all 随分配移 corearch（regalloc.cr）：corearch O2 = load 后自算分配 + 自检（emit 前，违反 = 编译错误，成功静默）。corec build 路径判定触发移除（main.cr）；corec `cir` 通道随迁 corearch 同名隐藏 flag（--dump-entries/--dump-coexist/--check-regalloc/--inject-*/--dump-regassign），红注入用例在 corearch 路径仍红（test_live_ranges 13/13）。

## 5. 多字整合

tagged 识别在 corearch（instr.cr mw_setup_tags）——分配移入后与 tagged 信息同侧（迁移前 Task 5 靠 REG_ASSIGN 元数据跨进程读取——现同进程）。判定消费 ENT（自算）+ tag 表——零通道。test_mw_task5 元断言改经 corearch `--dump-regassign`（O2 自算分配逐对输出）：2L 溢出函数 tagged∩REG_ASSIGN ≠ ∅ 保持（reg 形态裁决在 corearch 自算下成立）。

## 6. 决策点清单（**2026-09-07 全部拍板 + 实施**）

1. **R1** = **R1a**：按层拆——语义优化留 corec（AST 折叠 + CSE）、编码决策（数据面/共存/判定/注入/分配）迁 `src/arch/linux/ld/regalloc.cr`（corearch 闭包）
2. **R2** = **D-1=Y**：opt_meta 子节恒 0 + ENT 段恒空（first/last_ent/param_ents 恒 -1）——格式结构保留、loader 空表语义已支持、零 version bump；home 字段随落盘消亡（内存表保留，corearch 自算）
3. **R3**：verify 触发点 = corearch O2（load 后 alloc + verify，emit 前，违反 = 编译错误）；corec 判定触发与 `cir` 通道移除（注入通道随迁同名 flag）
4. **R4**（注）：编译时间分布——分配/数据面计算移 corearch 进程；compile-time-linearity 的 corec 侧减负面按实测另行记录（未列入本批）
5. **R5** = **拍板**：corec `-O` 门语义——O1 = CSE（corec 进程内，实证：对 .ccr 产物零效果——NOD O0/O1/O2 逐字节同）；O2 分配在 corearch（corec build 透传 `--opt-level`；直接调 corearch 未传 -O = O0 全栈）。CLI 帮助文案已更新（corec/corearch）
6. **D-3**（附加拍板）：pass_stack_share 停用摘除（产物死路径实证——g_stack_map 不落盘、corearch 恒空；恢复 = corearch 内 alloc 同 seam 实现，挂账）

## 7. 受波及面（**均已处置**）

- opt.cr 拆分（1940→312 行——语义 vs 编码切分；纯搬移提交 + 切换提交两步可独立评审）
- ccr_io.cr（ENT/opt_meta save 恒空 + func/REG first/last -1）+ 测试（test_ccr_v6 8/8 重写恒空断言；region_cfg walker 兼容零改）
- corearch 闭包（build_selfhost_native.py + regalloc.cr）+ backend_bootstrap（stage0-2 绿——分配在后端自举语义验证）
- main.cr O2 门/判定触发移除 + `cir` 调试通道摘除
- 「纯机械映射」表述清除（regalloc.cr/instr.cr/globals.cr/regalloc-consistency.cr 注记更新）
- regalloc-consistency.cr（参考实现指针 → regalloc.cr + 停用/缺口注记更新）
- 多字 mw 测试（REG_ASSIGN 元数据通道 → corearch `--dump-regassign`；test_mw_task5 哨兵更新绿）
