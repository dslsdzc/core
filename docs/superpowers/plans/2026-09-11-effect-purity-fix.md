# 效应/纯度事实修正 实施计划（P0 提前批）

> 面向执行本计划的 agent：必须使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans，按任务逐项实现。用复选框（`- [ ]`）跟踪进度。

目标：把「函数纯度」从没有实现的默认常量改为实际计算，使「调用」这类效应重新进入 state 链，消除「自动记忆化会缓存掉可观测效应」这条 P0 缺陷。

结构：分三步。1 实际纯度计算，使用保守起点加调用图迭代至不动点，递归和 SCC 保守判为不纯，不可解析调用判为不纯，替换 `checker.cr:1107/1142` 的两个默认写入点，并给 `monomorph` 的新 `FuncInfo` 补该字段。2 补全 state 链分类表，`IR_CALL_EXTERN` 加间接调用和并发效应 opcode 入链，可解析调用按实际纯度决定。3 重定检查，重新固定 `.ccr` 的 EDG/NOD 期望，加边集语义断言。ELF 逐字节不变，因为 lazy 判定解耦而得以保留。

技术栈：Core 自举栈；`src/compiler/checker.cr`（`collect_decls`/`find_func`）、`src/compiler/monomorph.cr`（实例创建）、`src/compiler/dataflow.cr`（`df_connect_state`）、`src/compiler/ir_gen.cr`（lazy 判定，本批不改）、`src/compiler/ccr_io.cr`（EDG/NOD 序列化）、`tests/selfhost/test_ccr_v7.py`（期望表）。

侦查基础（2026-09-11 purity-recon，结论已实测）：

- `fi_ispure` 只有 2 个写入点（`checker.cr:1107/1142`），且都写常量 1，注释为 "optimistic"。读取点只有 2 处：`dataflow.cr:171` 的 state 链和 `ir_gen.cr:1590` 的 lazy。
- 当前四态：普通函数为 1，不入链；extern 为 1，且 `IR_CALL_EXTERN` 不在分类表，属双重缺失；泛型实例为 0，因为 `monomorph.cr` 未写该字段，`rt.s` zero-init 后读到 0，因此意外入链；不可解析 builtin（`find_func<0`）保守入链，正确。
- 实测：`fn effect(){st=1;}` 被 main 调两次，main 的 state 链只有 store 边，两个 CALL 都不在。`dataflow.cr:401` 每函数重置，因此跨函数效应序完全丢失。
- 影响面：state 边消费者为 `ccr_io`（EDG 段加 NOD 邻接字段）、`cir_cache`、`dump.cr`、`ent_kernel.v7_edge_kind`。发射、解释器、regalloc 零消费，因此只改纯度、不动 lazy 时 ELF 逐字节不变。
- 权威语义（`plans/2026-08-08-region-cfg.md:484`）：非纯调用才进链；`find_func` 不可得（外部函数）时保守进链。

## 全局约束

- 只使用 jj（禁用 git，含只读和复合命令）；提交路径限定；命令加 `nice -n 19`；检查前 `clean-cache`；cwd 为仓库根。
- 本批不修改 lazy：`ir_gen.cr:1590` 的 lazy 判定与 `IR_LAZY_THUNK/FORCE` 发射保持原样（其 use_count 时序缺陷已登记 TODO）。这是保住「ELF 逐字节不变」检查的前提。
- 检查：1 运行语义零变化（解释器和 ELF 两侧输出一致）；2 ELF 逐字节不变（`tests/suite/ptr_arith.cr` 与 `/tmp/r1t4_base_bin` 比较，sha `95084e7b…d475`），若变则停下上报（说明纯度改动泄进了发射面）；3 `.ccr` 的 EDG/NOD 预期会变，因此重新固定期望表并新增边集语义断言，取代「字节相同」；4 全回归通过加自举 `corec2/corec3` `cmp` IDENTICAL 加 N06=0 加快速验证 42。
- 检查重定（本批确立，写入 TODO）：凡涉及 state 边或纯度的改动，检查为「语义零变化加边集语义断言加自举稳定（连续两次编译产物一致）」；旧的「.ccr 逐字节同旧版」不再适用。
- 本语言无三元运算符；取模须非负；键比较不得依赖 i64 回绕；noclobber（`>|`）。

---

## Task 1：实际纯度计算（根因修复）

文件：
- 修改：`src/compiler/checker.cr`（删除两处默认写入；新增 `compute_purity`/`compute_all_purity`；在 `check_all()` 尾部调用）
- 修改：`src/compiler/monomorph.cr`（新实例继承源函数纯度）
- 修改：`src/compiler/globals.cr`（如需侧表：调用图邻接和迭代标记）

接口：
```
// 保守纯度判定（不动点迭代；返回 1 = 可证纯，0 = 不纯/未知）
fn compute_purity(fi: int) -> int
fn compute_all_purity()          // check_all() 尾部调用：全部函数一次算完
// 自测辅助（供 type_selftest / 新测试断言）
fn fi_ispure_of(name: str_ni: int) -> int
```

语义（按 `plans/2026-08-08-region-cfg.md:484`）：纯定义为：1 函数体无 store 族（`IR_STORE/STORE_FIELD/STORE_INDEX/STORE_INDEX_VAR`），无 `unsafe`/volatile；2 无 IO/FFI/extern 效应，出现 `IR_CALL_EXTERN` 即不纯；3 传递闭包内被调者全纯（`find_func(s3)` 解析，不可解析则不纯）；4 递归或 SCC 保守判为不纯。

- [ ] Step 1: 失败用例（此时失败）。新增自测（`type_selftest.cr` 或独立 `tests/selfhost/test_purity.py`）
  - 正控：`fn pure_add(a:int,b:int)->int{return a+b;}` 应得到 `fi_ispure == 1`
  - 负控1（store）：`fn effect(){st:.,mut=0; st=1;}` 应得到 0
  - 负控2（传递）：`fn call_effect(){effect();}` 应得到 0
  - 负控3（extern）：含 `IR_CALL_EXTERN` 的函数应得到 0
  - 负控4（不可解析）：调用 runtime builtin 的函数应得到 0
  - 负控5（递归）：自递归函数应得到 0（保守）
  - 负控6（泛型实例）：`fn id[T](x:T)->T{return x;}` 的实例应与源函数同值（当前恒为 0，本任务须修正为「继承源纯度」）
- [ ] Step 2: 确认失败（现值是常量 1，负控1-6 全部失败）
- [ ] Step 3: 实现
  - 写侧：`checker.cr:1107`/`:1142` 两处 `fi_set_ispure(...,1)` 删除，改由 `compute_all_purity()` 统一写。
  - `compute_all_purity()`：扫描每个函数的 IR 体（`g_ir_func_instr_start/instr_count`）取 opcode 集；对 `IR_CALL` 用 `find_func(s3)` 建调用边；`IR_CALL_EXTERN`、不可解析、递归 SCC 判为不纯；从「全不纯」起点迭代升为纯，直到不动点（保守单调）。
  - 时点：`check_all()` 尾部，此时全部声明与 IR 体就绪、`df_connect_state` 之前。注意 `collect_decls` 期不可用。
  - `monomorph.cr:414-428`：`fi_set_ispure(new_fi, fi_ispure(func_ni))`。
- [ ] Step 4: 检查：`selftest-types` 加新用例全部通过；ELF 逐字节不变；`.ccr` 变化实测（预期变）；回归抽样；自举 `cmp` IDENTICAL。
- [ ] Step 5: 提交：`feat: 效应纯度修正 Task 1：实际纯度计算（保守起点 + 调用图不动点 + SCC 保守）替换默认常量；monomorph 继承源纯度`

## Task 2：state 链分类表补全

文件：
- 修改：`src/compiler/dataflow.cr:160-177`（`df_connect_state` 分类表）

- [ ] Step 1: 补 `IR_CALL_EXTERN` 分支（s1 = 符号名 ni；不可解析则恒入链）
- [ ] Step 2: 补其它效应 opcode（侦查第五类）：`IR_SPAWN`、`IR_YIELD`、`IR_HOTPATCH_ROUTE`、`IR_DYN_DISPATCH`（间接调用属于效应，保守入链）。逐个核对其载荷字段并加断言
- [ ] Step 3: 可解析调用：维持 `fi_ispure(cfi)==0` 则入链（Task 1 后该检查才有真实语义）
- [ ] Step 4: 检查：实测复现侦查的验收例。`fn effect(){st=1;}` 被 main 调两次，main 的 state 链必须出现两个 CALL；`pure_add` 调用不出现；ELF 逐字节不变；`.ccr` 变化实测；回归通过
- [ ] Step 5: 提交：`feat: 效应纯度修正 Task 2：state 链分类表补全（IR_CALL_EXTERN + spawn/yield/hotpatch/dyn_dispatch；外部与间接调用保守入链）`

## Task 3：检查重定与期望更新基准值

文件：
- 修改：`tests/selfhost/test_ccr_v7.py`（`EXPECT_DATA/EXPECT_STATE` 更新基准值；新增边集语义断言）
- 修改：`TODO.md`（检查重定条目：ELD/EDG 类改动的检查 = 语义零变化加边集断言加自举稳定）

- [ ] Step 1: 更新基准值期望表（`test_ccr_v7.py:84-104` 的 EXPECT_DATA(41)/EXPECT_STATE(13)；fixture 含 `pure_add` 调用，Task 1 后应保持「无该调用边」）
- [ ] Step 2: 新增边集语义断言（取代「字节同旧」）：1 可证纯调用没有 kind=1 入边；2 效应调用（store/extern/不可解析/间接）必有 kind=1 入边；3 每函数链独立（跨函数不连）。三条各自带正控和负控
- [ ] Step 3: 检查重定写入 TODO（含产物变更清单：`.ccr` NOD/EDG/`--dump-objects`/`.cir` 缓存；「自举稳定」替代「与旧版逐字节同」）
- [ ] Step 4: 提交：`test: 效应纯度修正 Task 3：检查重定（边集语义断言取代 .ccr 字节同旧）+ test_ccr_v7 期望更新基准值 + TODO 检查条目`

## Task 4：结束

- [ ] Step 1 全量回归（已跑集加全仓 38 套件）
- [ ] Step 2 ELF 逐字节复验加 `.ccr` 变更实测报告加自举稳定（连续两次编译产物一致）
- [ ] Step 3 自举链（`corec2/corec3` `cmp` IDENTICAL 加 N06=0 加快速验证 42）
- [ ] Step 4 文档：TODO #2026-09-16-2 家族更新（fi_ispure 修毕；lazy use_count 时序缺陷保持独立；`IR_DYN_DISPATCH` 间接调用覆盖）；spec（S-C/S-E/S-B5）里「纯度事实不可靠」的措辞改为「已于 <commit> 修复」，切片检查相应恢复
- [ ] Step 5 提交（路径限定）

---

## 自检记录

- 根因与临时修补：Task 1 是根因修复，按 `plans/2026-08-08-region-cfg.md:484` 实现；Task 2 的表补全属于同一根因面（分类表漏 opcode）。没有采用「只补 extern」的窄范围修补，因为那不能解决 print/chan_send 等可解析效应丢失。
- lazy 解耦（关键决策）：本批不修改 `ir_gen.cr:1590` 的 lazy 判定，保住 ELF 逐字节不变。否则每个 call 的 11 字节 thunk 会消失，ELF 与自举链全变。lazy 自身的 use_count 时序缺陷保持已登记状态，留独立批。
- 占位符扫描：无 TBD；`compute_purity` 的算法要点（保守起点、不动点、SCC、不可解析）已写全。
- 风险：1 `find_func` O(F²)，大项目下会变慢，可先测编译耗时，超阈值再换哈希；2 递归 SCC 保守判为不纯，宁可多入链（语义安全方向）；3 `.ccr` 字节变化属于预期，检查已按第 7 节重定。
