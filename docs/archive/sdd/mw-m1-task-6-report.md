# int 多字 M1 Task 6 报告：验证、回归、文档（M1 收官验收）

日期：2026-09-07
状态：完成（jj change ozwnqwzq / commit 0f71757a）
测试：`tests/selfhost/test_mw_task6.py`（8 个边界用例 × O0/O1/O2，共 24 组全部通过）加收官全量回归通过，O2 自举重建成功

## 1. 交付物

| 文件 | 改动 |
|---|---|
| `tests/selfhost/test_mw_task6.py` | 新建，溢出程序边界套件，见第 2 节 |
| `docs/superpowers/plans/2026-09-06-int-multiword-m1.md` | 状态行（M1 六个任务全部完成）加 Task 6 执行记录（边界套件、收官回归、文档同步、验收报告）加 M2 挂账清单加已知偏差和风险四项的逐条处置注（第 4 节） |
| `docs/superpowers/specs/2026-09-06-int-multiword-backend-design.md` | 状态行从设计定稿草案改为设计定稿、M1 已实现完成，加第 8 节 M1 完成范围和 M2 挂账 9 条 |
| `docs/superpowers/specs/2026-09-06-int-unbounded-semantics.md` | 第六节挂账条目 2 加注：hw-map 表示策略的 M1 实例已经实施，指向 backend-design spec |
| TODO.md | 新增一节“int 多字 M1（2026-09-07 M1 完成，M2 挂账）”，样式镜像 HIT 节 |

代码语义改动为零。Task 6 只做测试和文档收尾，src 保持 Task 1-5 终态，自举重建后行为不变。

## 2. 溢出程序边界套件（test_mw_task6.py）

task3/4 已经覆盖 CF/op 判别矩阵（m1-m6）和消费者判别（return、比较、链式、卫生、假拟合 d1/d2）。本套件补计划 Task 6 要求的边界值组合，期望值全部由 Python 独立计算，limb_bytes 16B 通道断言不是从编译器输出回读：

| 用例 | 组合 | 判别面 |
|---|---|---|
| e1 | i64max（最大合法字面量）+1，恰好一步越界，得到 2L 2^63 | 16B 流 |
| e2 | 上边界三步连续越界链（2L 加快值），得到 −3 降级回 i64max（fits：hi==signmask(lo)==0），再 +1 越界 | 32B 流往返 |
| e3 | 下边界邻域：−(2^63−1)+−1 = −2^63，快值不溢出（−2^63 字面量被 lexer 拒绝，该构造是唯一可达形态；负 OF 只发生在 < −2^63），然后 add/sub 连续越界，再 +3 降级回快值 | 32B 流加 return 低字节 1 |
| e4 | sub 形式：i64max − −1 = 2^63（CF 判别），然后 −1 降级，再 − −2 快值转溢出 | 32B 流 |
| e5 | 上下边界同函数双站，2L(hi=0) 与 2L(hi=−1) 的高 limb 符号判别 | 32B 流加 exit 33 |
| e6 | i64max 边界 fast 与 2L 比较真值表：LT/GT 双分派（A/B 路）为真，EQ/GE 为假（−10 哨兵，错误实现会给 248） | exit 2 |
| e7 | −2^63 快值与 −2^63−1 的 2L 比较：同 hi(−1)，低 limb 按无符号判别（有符号 lo 会给 101） | exit 2 |
| e8 | 循环携带越过上边界（同站点回边逐轮 2L 化）加独立快计数器 | 16B 流 |

8 个用例 × O0/O1/O2 = 24 组全部通过，首次运行即通过。

## 3. 收官回归（一次性全套），全部通过

用 `bash -c 'ulimit -c 0; …'` 串行全量执行，日志在案：

- mw task1 ALL PASS（帧和 tag 布局不变性）；task2 ALL PASS（jo 形状加 z 零 diff，untagged 快路径逐字节零变化）；task3 ALL PASS（CF/op 判别矩阵）；task4 ALL PASS（60/60，含判别回归 d1/d2）；task5 ALL PASS（D6 裁决元断言）；task6 ALL PASS（24 组）。
- test_hit_table 11/11（表模式门控不破坏）。
- test_compile ALL PASS（自持管线）。
- test_backend_bootstrap 全部 PASS，stage0 到 1 到 2 到 3 byte-identical 加 O2 元数据 smoke（自举完整流程确定性最强的证明，覆盖“O2 自举”条目）。
- test_ccr_v6 9/9，test_region_cfg 22/22，test_slice_bounds 7/7。
- `./build/corec check src/compiler` ok。
- 收官自举重建：`nice -n 19 python3 build_selfhost_native.py` 成功（BUILD_EXIT=0），重建后 smoke 42 正常。

## 4. 计划已知偏差和风险四项的处置（逐条核对）

| 风险项 | 处置 | 证据定位点 |
|---|---|---|
| jo 慢路径数学修正（环绕加 ±2^64）的正确性 | 已验证：sbb 推演闭式（add hi = CF?−1:0，正溢出 CF=0，sbb −CF；sub hi = CF?0:−1，sbb 加 not），8 万以上随机和边界样本零偏差，CF/op 判别矩阵 m1-m6（任一规则回退即失败），边界对 brute-force。编码级（jo rel32 回填、块发射逐字节）由 task2/3 断言 | mw-m1-task-3-report 第 2 节、test_mw_task3 |
| M1 的保守 tagged 集可能偏宽（性能） | 代价已记录：tag 使每个 tagged 变量行多 1 字节栈（无 tag 程序的帧公式逐字节不变），每站 jo 6B，函数尾块约 45-160B 冷区线性增长。静态精化属于 M2（D1c，spec 第 8 节条目 5） | task1 报告第 2/4 节、spec 第 8 节 |
| 2-limb 堆对象的 arena 归属（慢路径分配生命周期） | 已核：慢路径经标准 alloc 双路。没有激活 arena 时（纯算术作用域 sg_alloc_total=0，arena 不建）落全局 bump，生命周期为进程生命期，覆盖全部测试形态。arena 激活时与周围分配同 chunk 同生命周期，M1 的 tag 不跨作用域或函数，边界内消费没有新危害。含分配作用域和跨 reset 属于 M2 债（spec 第 8 节条目 8） | task3 报告第 6.2 节、task4 报告第 2.3 节 |
| return 大值验证只能看低 8 位 | 已解决：全 128 验证使用测试钩子 syscall3(1,1,x,16) 原始 16B 通道（x 槽是 2L 对象指针，tag 无关的直接读取面，零 runtime 改动）。spec 第 5 节的 return 出逃边界句已补：M1 内 return 2L 到内部调用方是确定性截断低 64 位环绕，全 128 return 属于 M2 | task3 报告第 4 节、task4 评审、spec 第 5 节 |

## 5. M1 六任务验收汇总（全链证据）

| Task | 提交 | 交付 | 测试证据 |
|---|---|---|---|
| 1 tagged 槽框架 | 2ecb030b（加评审修复 7a6b17b1：不动点闭包加 B′ STORE 边） | mw_setup_tags/g2_tag_off/mw_frame_size（corearch 侧） | test_mw_task1 21 组加帧级 s7 判别 |
| 2 快路径溢出检测发射 | a0d79b57 | jo rel32（rel8 结构性不可达，t3 12KB 判据）加慢路径骨架加 HIT 表模式门控 | test_mw_task2 45 组加 z 零 diff |
| 3 慢路径加 2-limb 运行时 | 8e9c4bfe | CF 数学修正加 alloc(16) 2-limb 加 tag 置位加每站点块 | test_mw_task3 18 组加 8 万样本实证 |
| 4 消费者适配 | a5709dcf（加评审 Critical 9699d813：fits 检查一字节修复 0x4D 改为 0x49，加判别回归 d1/d2 加 spec 第 5 节边界句） | tag 卫生四类定值点加 return 解指针加 128 位比较加 2L 再算术 | test_mw_task4 60 组 |
| 5 分配器适配（D6） | d07a7254（裁决为不改，确认加加固） | D6 不排除定案加元断言测试（O2 tagged∩REG_ASSIGN≠∅ / O1 = 0） | test_mw_task5 15 组 |
| 6 验证加回归加文档（本任务） | 0f71757a | 边界套件加收官全量回归加 plan/spec/TODO 状态加偏差处置 | test_mw_task6 24 组加全套回归加 O2 自举 |

M1 语义承诺已经达成：64 位快路径零开销直算（untagged 程序和函数逐字节零变化，task2 的 z 用例加 backend_bootstrap byte-identical 双通道证明）；add/sub 溢出自动提升为固定 2-limb 128 位（数学精确，CF 闭式加判别矩阵加 8 万样本加边界套件）；语义层（前端、图、格、.ccr 格式）零改动，全部实现位于 corearch 发射侧。

## 6. M2 挂账（已同步 TODO.md、spec 第 8 节、plan Task 6 记录）

mul/div 溢出链和 2L 参与；UOP_NEG 的 −2^63 环绕链；2L 值打印（int_str）；D4 超过 64 位的编译期常量（IR_CONST 64 槽，格层表示需要 v6 常量段，与 dex 精度同族）；超过 128 位的码域动态增长（当前编码层限制错误）；return 全 128 内部传递（当前确定性截断低 64）；出逃写入和跨函数 2L（全局、堆、数组、实参返回值）；D1c 静态区间免 tag（保守集代价已记录）；共享块和模板压缩（jo/2L 块冷区线性增长，不是正确性项）；表（HIT）模式与运行时 2L 的组合验证（tagged 路径整条走旧路径，语义正确，组合未验）；arena 生命周期债（2L 跨 arena_reset 属于 M2，正确方向是永久 bump 或跨 reset 复制）。

## 7. 提交

- `jj commit`，工作副本父提交为 d07a7254（Task 5），未改动任何 bookmark。改动只有 5 个文件（test_mw_task6.py 新建加 plan、spec 两份、TODO 文档）。
- 本报告与任务 1-5 的报告同列 `docs/archive/sdd/`，不入库。

## 8. 待关注项

1. 套件意图边界：task6 的边界用例是值数学和出口真值表回归（e6/e7 哨兵给错误实现即失败）。快慢形态的动态判别（tag 状态、fits 降级去向）已经在 d1/d2/a4/h 系列固定，本套件不重复，这是有意为之，避免脆性重复断言。
2. 回归耗时的常规性：收官全量约 10 分钟以上（串行，每个 spawn 使用 nice 19）。task2 报告挂账的“零 diff CI 基线流程”仍没有 CI 实现方式，目前是本地手工基线，M2 或后续治理挂账。
3. 报告计数口径：task2 报告写 45 个 PASS 组，task4 为 60/60，task5 为 15，task6 为 24，task1 为 21。各组断言粒度不同（组 = 用例 × opt 行为断言组，含帧和元断言），跨任务求和只能作粗略口径，不要逐条对齐。
4. 并行会话共享工作副本的风险同 task1-5。本任务提交前用 `jj status` 核对，只有 5 个文件在案，没有扫入任何并发改动。
