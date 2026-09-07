# 寄存器分配移后端设计（编码层资源决策归位）

日期：2026-09-07
状态：设计定稿草案（决策点待拍）
关联：`docs/regalloc-cache-mapping.md`（判定四条/上下文贪心）、`specs/2026-09-05-lattice-ir-v6-format.md`（v6 ENT home）、`specs/2026-09-06-int-multiword-backend-design.md`（多字表示 = 后端）、`specs/2026-09-05-hardware-interface-table.md`（优化不进表——判定/分配在格形态层）、compile-time-linearity 计划（corec 时间分布）。

## 1. 归属论证

**寄存器是物理资源——分配是编码层决策**（与 int 多字表示、指令发射同层）。现状分配器在 corec（opt.cr）纯属历史（v5 时代后端无决策能力）；「g2_slot 负编码 = 纯机械翻译分配结果」的表述把后端钉成执行者——分配归位后此表述取消：后端自己做分配，g2_slot 是后端的槽解析 seam（决策的一部分），非机械翻译。

```
现状：corec（数据面+分配+判定）→ .ccr 传 REG_ASSIGN → corearch 机械消费负编码
目标：corearch（数据面+分配+判定+发射 = 全部编码层决策）
      corec 只产语义（.ccr 无 opt_meta——分配结果不再跨进程传输）
```

## 2. 迁移形态（决策点 R1）

opt.cr 相关函数（compute_live_ranges/compute_entries/共存/alloc_registers/verify）——**文件搬移 vs 闭包调整**：
- opt.cr 现既在 corec 闭包（优化 pass 含 CSE 等仍属 corec 吗？——CSE/pass_cse 是图优化=语义层？分配是编码层——opt.cr 里两类混居）
- R1a：opt.cr 拆分——语义优化（CSE 等留 corec）与编码决策（分配/数据面/判定）移 corearch（新文件 src/arch/linux/ld/regalloc.cr 或 corearch 侧 opt 子集）
- R1b：整文件入 corearch 闭包（corec 无分配——但 CSE 也跟走？CSE 是图优化应留 corec）

倾向 **R1a**（按层拆：语义优化留 corec、编码资源决策移 corearch——与「优化不进表但分层」一致）。

## 3. .ccr 简化（决策点 R2）

- opt_meta（含 REG_ASSIGN）出 .ccr——分配结果不再传输（后端自算）
- ENT home 字段：原设计「分配器回填」——后端 load 后内存态回填（不再落盘传输——home 落盘值恒 -1？或 ENT 出 home？——决策点）
- 数据面（区间/条目）仍需 .ccr 传输（ENT 段——v6 已有）——后端从 ENT 载入重建内存态（ccr_io load 已有）——分配器输入齐备

## 4. 判定位置（决策点 R3）

verify_regalloc_consistency/regalloc_verify_all 随分配移 corearch（O2 后端自检——发射前/后跑，违反即编译错误）。corec build 路径的判定触发点 = corearch 侧（main.cr 的 O2 门移 corearch）。

## 5. 多字整合

tagged 识别已在 corearch（instr.cr mw_setup_tags）——分配移入后与 tagged 信息同侧（现 Task 5 靠 REG_ASSIGN 元数据跨进程——同侧后直接消费 tag 表）。判定消费 ENT + tag——同进程零通道。

## 6. 决策点清单

1. **R1**：拆分形态（R1a 按层拆——语义优化留 corec）
2. **R2**：.ccr 简化度（opt_meta 全出？ENT home 处置？——v6 又一轮格式改）
3. **R3**：判定触发位置（corearch O2 自检）
4. **R4**：编译时间分布（分配移 corearch——compile-time-linearity 的 corec 侧减负）
5. **R5**：corec 的 `-O` 语义（O1 CSE/corec、O2 分配/corearch——CLI 协调）

## 7. 受波及面

- opt.cr 拆分（~1900 行——语义优化 vs 编码决策切分）
- ccr_io.cr（opt_meta 段出/简化 + ENT home）+ 测试（test_ccr_v6 字节走查/region_cfg walker）
- corearch 闭包调整（build_selfhost_native.py）+ backend_bootstrap（分配在后端自举——byte-identical 语义变化）
- main.cr O2 门/判定触发
- 「纯机械映射」表述全仓清除（opt.cr g2_slot 注释等）
- regalloc-consistency.cr（参考实现指针更新）
- 多字 mw 测试（REG_ASSIGN 元数据通道 → 同进程——test_mw_task5 哨兵形态更新）
