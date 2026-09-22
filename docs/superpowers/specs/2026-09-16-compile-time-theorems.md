# 编译时间上界定理清单（code review 对照）

日期：2026-09-16
定位（受众/状态/出处）：**受众 = maintainer（改编译器者）+ reviewer**；**状态 = active（计划配套，随 `plans/2026-09-04-compile-time-linearity.md` 推进而更新）**；**出处 = 本文（定理与论证要点）+ 计划 §4（原表）+ 实施期计数器证书（机器侧）**。
性质：**人证清单**（不是测量结果）。每行一条定理：输入规模 N（按 pass 定义）下，耗时 ≤ C·N（C 为 pass 相关常数；hash 表按**期望** O(1) 时在「论证要点」注明「期望」；总量界 = 平摊严格线性）。
用法：**改任一 pass 必须同步本表**——保持定理成立，或**先改定理并说明**（照计划 §5.3）。破坏定理的改动 = review 阻断项。

---

## 1. 定理表（12 行）

| # | Pass | N（规模定义） | 定理 | 关键论证点（review 时逐条核） |
|---|---|---|---|---|
| 1 | lexer | 源字符数 | ≤ C·N | 每字符常数工作（**含长字面量修复后**：现转义密集字面量为逐字节 concat，见修正计划 Phase E） |
| 2 | parser | token 数 | ≤ C·N | 无回溯全扫 |
| 3 | checker（全部解析函数） | token/符号数 | ≤ C·N | Phase A 哈希化后：`find_sym`/`find_gsym`/`find_func`/borrow 表全部 O(1) 期望；**borrow 的「作用域分区」是语义保持项**（同名遮蔽顺序） |
| 4 | ir_gen | AST 节点数 | ≤ C·N | Phase A 缓存：`find_local`/`find_global`/`track_str`/`slice_len_*`/调用发射的 `find_func` |
| 5 | dataflow（HDFG 构建） | IR 指令数 | ≤ C·N | 每指令常数边；**`df_connect_state` 的每 `IR_CALL` `find_func` 须走缓存**（其纯度值在 `df_state_finalize` 期间会变 ⇒ 缓存生命周期 = 单次 finalize 内） |
| 6 | ptr/region/provenance（三个安全 pass） | DF 节点数 | ≤ C·N（指针分析 ≤ C·轮数·N，轮数常数） | Phase B：一次线性预计算「节点 ∈ unsafe」位图（复用 `g_df_node_region` 显式映射）⇒ 三处 `*_is_in_unsafe` 的 `g_sgs` 全扫归零 |
| 7 | monomorph | 泛型调用 × 体节点 | ≤ C·N_total | Phase A 哈希：实例缓存（现线性扫 `g_gen_instance_count`）+ clone dedup（现线性扫 `g_gen_dedup_count`，**动态增长 ⇒ hash 须可增量插**） |
| 8 | opt（CSE / 分配） | IR 指令数 | ≤ C·N | Phase C：`pass_cse` 的 seen 哈希化（键 = opcode+操作数）+ replace 版本化索引；**`pass_stack_share` 已停用（见计划 §8.1-E1）⇒ 本行不含它** |
| 9 | module/import | 全部文件 token 总量 T | ≤ C·T | Phase D：单轮收集 + 每文件独立 tokenize + 已加载 hash set；累积源用预分配缓冲（总量线性） |
| 10 | ccr_io（写/读） | `.ccr` 字节数 | ≤ C·B | 已有单缓冲线性（维持定理；**改动须复验**） |
| 11 | ELF 发射 | IR 指令数 + 函数数 | ≤ C·N | Phase A-后端：name→id 直寻（call 补丁/发射/Phase 3 全链）+ `g2_str_off` 单遍偏移表 |
| 12 | 内存 | 输入规模 | ≤ C·N | 翻倍总量界；**禁止字符串逐字节 concat 类回归**（lexer 长字面量 / module 累积源即两处现存实例） |

## 2. 机检侧（次级判据）

- 计数器证书（`--emit-ops-cert`，设计见计划 §8.2 的 T2）在真实编译上逐次验：`(pass, N, ops ≤ C_pass·N)`；
- 常数表 `C_pass` 入仓（建议 `tools/cert/c_pass.json`），**只允许在批内显式改动**，改动须给定理依据；
- 判定器建议 `tools/cert/check_cert.py`（任一违例 rc=1）。

## 3. 关联

- `docs/superpowers/plans/2026-09-04-compile-time-linearity.md`（计划本体；§4 = 原定理表，§8 = 任务级细化与审计勘误，§9 = 裁决门）
- `docs/superpowers/plans/2026-09-16-opt-rep-follows-storage.md`（同期的另一条性能相关批：可选表示，**不含时间上界承诺**）
- 审计复核来源（2026-09-16 纸面细化轮）：计划 §8.1 勘误表（**8 条行漂 / 2 条位置迁移 / 后端目录退役 / 1 条已失效**——照原文开工必错）
