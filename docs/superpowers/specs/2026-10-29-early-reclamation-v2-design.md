# 区域 v2：自动提前回收（split / merge / share + IR 回收点）

> 状态：V2.0、V2.1（含 V2.1b 后支配版）、V2.2、V2.3 与 V2.4 已实现（2026-10-30）
> 日期：2026-10-29
> 关联：`docs/maintainer/design/region-model.md`、`docs/maintainer/adr/adr-0007-graph-anchored-regions.md`、`docs/superpowers/specs/2026-10-28-arena-size-classes.md`

## 一、问题

v1 的区域生命周期等于子图生命周期：LOOP、FOR、UNSAFE 在出口 `IR_ARENA_RESET`；IF 不建 arena；函数级分配活到函数出口。这个模型正确，但只在一个子图整体结束时回收。长循环体或长函数中，前面分配的字节即使已经全部死亡，也要等到区域出口才能复用，峰值内存偏高。

v2 的目标是让编译器从图活性推导更早的回收点，并把“一块字节沿图边划给子区域”落成可执行语义，而不是新增用户语法。用户仍然只写普通 Core 代码。

## 二、目标与非目标

目标：

1. 不改变可观察语义。所有 v1 可运行的程序在 v2 下仍可运行，指针值、别名关系、字节内容保持一致。
2. 在 RegionCheck 能证明安全时，提前回收字节；不能证明时保持 v1 行为。
3. 复用现有 arena 运行时：嵌套 arena、slot 池、size class、reset 语义都不重写。
4. 回收点由编译器生成，不提供显式 free/reset 语法。
5. 失败必须响亮：分析不确定时选择不优化，不选择放宽检查。

非目标：

- 对象级 free、引用计数、GC。
- 并发区域（每 G 独立 arena）本轮不做。
- 用户自定义分配器/回收器。
- 跨进程或持久内存。

## 三、v1 事实

- 区域树 = SG 树。SG 类型：FUNC、LOOP、FOR、FLOW、UNSAFE、IF。`rc_sg_releases` 目前只把 LOOP、FOR、UNSAFE 视为释放区域。
- 运行时 arena 已经支持嵌套：`arena_new_sized` 记录 parent 并切换 current；`arena_reset` 归还 slot、解映射 extent、恢复 parent。
- 动态分配走 size class；静态大小走精确 bump。回收只有整体 reset，没有对象级释放。
- `IR_ARENA_NEW`/`IR_ARENA_RESET` 已在 LOOP/FOR 的入口/出口发射；IF 只做 `sg_push`/`sg_pop`。
- RegionCheck 已有每个 allocation bit 的释放区域、退出序号、pts 和四种逃逸判定；BytePermission 已有只读/可写位。
- `ir_gen_all` 开头显式重置 IR 计数和 case 表，具备重新生成 IR 的基础；SG 计数和 plan 表需要补一个完整重置入口。

## 四、v2 语义

### 4.1 名词

- **槽（slot）**：运行时 arena 实例，拥有自己的游标、size class 子区域和 slot 链。
- **区域（region）**：SG 子树。一个区域可以拥有一个槽，也可以使用父区域的槽。
- **归属**：每个 allocation bit 属于唯一槽；归属由分配节点所在区域和 plan 决定。
- **回收点**：一条 `IR_ARENA_RESET`，释放一个槽当前占用的全部字节。
- **生命周期**：从槽创建到回收点。v1 的生命周期是区域出口；v2 允许更短。

### 4.2 安全条件

v2 的优化只在以下条件全部成立时启用：

1. 被提前释放的 allocation 在回收点之后没有任何读、写、取址、比较身份或传给外部的使用。
2. 回收点之后不存在指向该 allocation 的活指针变量。
3. 回收点之后不存在把该 allocation 存入更长寿命目标的操作。
4. 回收点不跨越 `unsafe` 边界；`unsafe` 域内的分配保持 v1 生命周期。
5. 固定地址放置（`IR_ALLOC_AT`）不参与 split/early clear，生命周期仍是程序级。

条件 1–3 是 RegionCheck 的扩展；条件 4–5 是 plan 的硬门。

### 4.3 split

`split(S)` 为子图 S 创建一个独立槽：

- S 的入口发射 `IR_ARENA_NEW`，S 的出口发射 `IR_ARENA_RESET`。
- S 内新分配的字节进入子槽；S 内对父区域已有对象的引用不受影响。
- 只有 S 内全部 allocation 都不逃逸 S 时，才允许 split。逃逸判定包括：S 外使用、存入 S 外目标、返回、作为参数传给可能保存它的被调函数、身份观察。身份观察包括 `@raw_int`、指针相等比较、`@ptr_of`、FFI 和 `unsafe`；`g_current_arena` 的可读值也视为可观察状态。
- 有逃逸时保持 v1：S 使用父槽，不创建子槽。
- 逃逸判定覆盖所有实际落入 S 子槽的 allocation，包括嵌套在非释放 IF 内的 allocation。嵌套 loop/for/unsafe 或已规划 split/merge 的 IF 拥有自己的字节，不由 S 的槽承担。
- split 不改变 S 的类型、控制流或返回值；只改变分配落在哪个槽。

### 4.4 merge

`merge(J)` 处理“子槽中的值需要活到汇合点之后”的情况。v2 分两级：

1. **无逃逸**：V2.0 不做 merge，split 条件已经排除。
2. **可拷贝逃逸**：V2.2 在汇合点把逃逸值复制到父槽，后续使用改指向副本。

可拷贝类型：

- 标量：int、bool、char、dex。
- 字符串：复制字节；副本拥有独立字节序列。
- 数组、结构体、元组：逐元素复制，前提是所有叶子可拷贝且不含指向 split 数据的指针。
- 指针字段、引用字段、含内部指针的聚合：不可拷贝，保持父槽，不 split。

指针身份是硬门：如果逃逸值被 `@ptr_of`、指针相等比较、FFI 或 `unsafe` 观察，禁止 split，因为复制会改变身份。

实现（2026-10-30，V2.2 窄切片）：

- 只接受一个 `IR_ALLOC_ARRAY`，元素为 int/bool/char/dex，长度 1..64，且该分配在 IF 顶层直接 `IR_STORE` 到一个外层局部槽。
- IF 内不得有 call/return/unsafe/非局部跳转；IF 不得位于 loop/for/unsafe 内。赋值分支必须无控制流地到达分支出口。
- IF 子槽中的其他 allocation（包括嵌套非释放 IF 内的 allocation）必须留在 IF 内；任何一个逃逸就拒绝 merge。只有被选中的数组允许经复制逃逸到父槽。
- 子数组只允许元素读（`IR_LOAD_INDEX`/`IR_LOAD_INDEX_VAR`）与元素写（`IR_STORE_INDEX`/`IR_STORE_INDEX_VAR`）。写入别的对象、形成切片、指针比较、取址或任何身份观察都拒绝；IF 外的使用必须经该外层槽。
- 复制在**赋值分支的出口**执行：逐元素复制到父槽预分配的副本，再把外层槽重绑到副本。未走赋值分支的路径保留旧值，因此不需要汇合 phi。
- 副本在 IF 入口按 plan 给出的元素数分配，大小计入父槽 peak；元素类型行在赋值分支出口补齐。
- merge IF 不得位于 loop/for/unsafe 或已规划 split/merge 的 IF 内，保证副本只落在函数槽；否则副本可能随外层 IF 子槽 reset 而失效。
- 子槽在 IF 汇合标签 reset；副本在父槽，活到父区域出口。

### 4.5 share

`share(S)` 表示一个槽的数据被多个消费者只读共享：

- 所有通过指针到达该槽的写操作必须不存在；BytePermission 的写位检查作为判据。
- 每个消费者的退出点必须早于共享槽的回收点。
- 共享槽的回收点 = 所有消费者退出点的最小公共后支配点（LCPD）；没有 LCPD 时取父区域出口。
- 共享槽不复用于其它分配；reset 之后整个槽归还 slot 池。
- 需要写入的消费者不进入 share；它们要么各自持有副本，要么保持父槽。

### 4.6 提前回收点（early clear）

采用 clear-and-keep，运行时性能优先。`early_clear(S, Q)` 在槽 S 的生命周期内、区域出口之前，于程序点 Q 发射 `IR_ARENA_CLEAR`：

- 清空槽的 slot 游标、size class 的 base/cursor/limit，并 `munmap` 该槽的专用大对象 extent。
- 槽 id 保持 live，current 不切回 parent；Q 之后的分配继续复用同一槽，从游标 0 重新 bump。
- 区域出口仍发射 `IR_ARENA_RESET`，做最终 close：归还 slot、恢复 parent。
- 不把 slot 放回 free list，因此不存在早 clear 与出口 close 之间的 arena id 复用；clear 幂等。
- Q 必须后支配 S 内每个 allocation 的每个使用点。
- Q 之后没有任何 S 的 allocation 是活的。
- Q 位于基本块边界或标签处，保证所有路径都经过同一个 clear。
- 若 Q 之后还有 S 的 allocation 被使用，则不插入，保持 v1 出口 close。
- 循环体已有的出口 close 保留；提前 clear 只在能减少同一迭代内峰值时插入，不替代出口 close。

性能理由：clear 不触碰 arena 池的 free list，不做 slot 申请/归还，不切换 current；只重置元数据并按需解映射大对象。Q 之后的分配仍在同一 1MB slot 内，cache 局部性最好。clear 前是否清零已用前缀由 V2.4 配置决定，默认关闭。

### 4.7 清零与复用

- `arena_reset` 清空游标、size class 元数据和 slot 链；新分配仍按现有 `zero_alloc` 清零本次请求的字节。
- V2.4 增加部署配置 `arena_zero_on_reset`：开启时 reset 前把该槽已用前缀清零，防止敏感数据留在空闲 slot；默认关闭，保持现有性能和字节行为。
- 清零配置只影响 reset 路径，不改变分配路径和指针语义。

## 五、IR 表示与 pass 顺序

### 5.1 IR

不新增回收 opcode。复用：

- `IR_ARENA_NEW`：创建子槽。
- `IR_ARENA_CLEAR`（opcode 56）：提前回收，清空游标/档位/大对象 extent，保留槽 id。
- `IR_ARENA_RESET`：区域出口 close，归还 slot 并恢复 parent。
- `IR_ALLOC_ARRAY`/`IR_ALLOC_STRUCT` + `IR_STORE`/`IR_LOAD`：merge 的复制序列。

新增编译期 plan 表（不进入 `.ccr`）：

| 表 | 含义 |
|---|---|
| `g_plan_split` | 每个 SG 一项：0 = 使用父槽，1 = 独立子槽 |
| `g_plan_clear` | 扁平静态表，每项 = (函数, 标签, 槽变量)：该标签后发射提前 clear；同一标签可有多项 |
| `g_plan_share` | 每个 SG 一项：0 = 不共享，1 = 只读共享 |
| `g_plan_slot` | 每个 SG 的槽变量/父槽变量映射 |

plan 表只在编译期使用；`.ccr` 仍只携带 `IR_ARENA_NEW/RESET` 和 SG 表。

### 5.2 两阶段生成

V2.0 采用两阶段 IR 生成，避免在已建好的 DF 图上插入节点：

1. **Phase A**：正常 `ir_gen_all`，但不发射 split/early clear；运行 PointerAnalysis、RegionCheck。
2. **Plan**：`region_plan_analyze()` 读取 pts、RegionCheck 的 allocation 生命周期、BytePermission 的读写位、控制邻接上的后支配关系，填充 plan 表。
3. **Phase B**：若 plan 非空，调用完整 `reset_ir_state()`，再跑 `ir_gen_all`；IR 生成在 SG 入口/出口和 plan 标签处读取 plan，发射 `IR_ARENA_NEW`/`IR_ARENA_CLEAR`/`IR_ARENA_RESET` 和 merge 复制序列。
4. Phase B 后重新运行四个 pass（ptr/region/byte/provenance），确认 plan 没有引入新的逃逸或越界。

`reset_ir_state()` 必须重置：IR 变量/指令/函数/全局计数、DF 图、SG 计数和 SG 表、label 计数、case 表、pts/RegionCheck 缓存、plan 表。若 plan 为空，Phase B 跳过，编译成本与 v1 相同。

两阶段是 V2.0 的实现选择，不是语义要求。后续若需要降低编译成本，可用“重建指令数组 + 重建 DF 图”的 rewrite pass 替换 Phase B，语义不变。

### 5.3 merge 复制的 IR

对每个逃逸值：

1. 在父槽分配同类型对象（标量用 `IR_ALLOC_ARRAY` count=1；聚合按字段/元素展开）。
2. 逐字段/元素 `IR_LOAD`/`IR_STORE` 复制。
3. 用新变量替换汇合点之后的所有使用。
4. 复制点的源值必须在子槽 reset 之前读取。

复制的 IR 由 plan 阶段生成，Phase B 的 IR 生成器在汇合标签处展开。复制序列不进入源语言 AST。

## 六、分析算法

### 6.1 split 候选

候选 = SG_IF，以及后续阶段开放的 LOOP/FOR 体。FUNC 不 split（函数出口已经是回收点）。UNSAFE 不 split。

对候选 S：

```text
for each allocation a in S:
    if used_outside_subtree(a, S): reject
    if stored_to_target_outliving(a, S.exit): reject
    if returned_or_passed_to_unsummarized_call(a): reject
    if identity_observed(a): reject
if all allocations pass: split(S) = 1
```

`used_outside_subtree` 用 allocation bit 的 pts 反查所有使用节点，判断使用节点是否在 S 的 SG 子树内。`stored_to_target_outliving` 复用 RegionCheck 的 `rc_store_outlives`，把 S 的 exit 作为边界；目标寿命未知（`rc_dest_max_exit` 返回 -2）一律视为逃逸，不得按“安全”放行。

### 6.2 early clear

1. 对每个槽 S，收集 allocation 集合 A_S。
2. 在 S 的控制邻接上做指针变量活跃性：变量 v 在节点 n 之后活跃，当且仅当存在一条从 n 出发的路径在 v 被重新定义前使用 v。
3. allocation a 在 n 之后活跃 = 存在活跃变量 v 且 `pa_pts_has(v, a)`。
4. 候选 Q = 基本块结束/label。若 Q 后支配 A_S 的每个使用点且 A_S 在 Q 后不活跃，则 Q 可 clear。
5. 目标寿命未知时一律不 clear；只有明确证明无活 allocation 才插入。
6. 选择最早的可 clear Q；若 Q 与区域出口重合，不插入（出口 close 已足够）。
7. 插入的 clear 使用 S 的槽变量；同一槽可以有多条 clear，clear 幂等。

后支配用控制邻接的后向固定点计算；控制邻接由 HDFG 的 `IR_JUMP`/`IR_MATCH`/`IR_LABEL` 派生，`rc_ctl_prepare` 只是按函数缓存。

### 6.3 share

1. 收集槽 S 的全部指针使用点。
2. 若任一使用是写（`IR_STORE_PTR`、`IR_STORE_INDEX`、`IR_STORE_FIELD`、`cell_store` 等），share 失败。
3. 收集消费者退出点；计算最小公共后支配点。
4. 共享槽的 reset 放在 LCPD；若 LCPD 在 S 的父区域出口之后，取父出口。
5. RegionCheck 验证每个消费者对 S 的引用在 LCPD 之前结束。

## 七、正确性条件

| 编号 | 条件 | 验证点 |
|---|---|---|
| I1 | reset 之后没有对槽内字节的解引用或写入 | RegionCheck 扩展：按槽边界判定，不只看 SG exit |
| I2 | 逃逸值在父槽有副本，且副本活到使用点 | merge 复制 + RegionCheck |
| I3 | 共享槽对所有消费者只读 | BytePermission 写位 |
| I4 | clear 只在无活 allocation 的点执行 | 活跃性 + 后支配 |
| I5 | 身份被观察的值不 split、不复制；`@raw_int` 与 `g_current_arena` 计入身份观察 | plan 硬门 |
| I6 | 固定地址和 unsafe 分配不参与 | plan 硬门 |
| I7 | clear 幂等；slot 只在区域出口 close 时归还一次 | `arena_clear` 只重置元数据，`arena_reset` 保留 `g_arena_live` 检查 |
| I8 | 非局部出口（return/break/continue）关闭仍 live 的子槽 | 出口边 cleanup |

## 八、实施阶段

### V2.0 split（无逃逸）

- 只对 SG_IF。
- 候选无逃逸才建子槽；有逃逸保持 v1。
- 两阶段 IR 生成 + `region_plan_analyze`。
- 验收：R2（if 内分配逃逸到 if 外）保持 v1，运行结果不变；新增“if 内分配不逃逸”用例，`IR_ARENA_NEW/RESET` 成对出现；canary 若因现有语料触发 split 而变化，逐项归因并按换代纪律更新值表，不得静默改判据。
- 实现（2026-10-29）：`src/compiler/region_plan.cr` 负责 Phase A 的保守 plan；`ir_gen` 在 Phase B 为标记的 IF 发射子 arena。当前只接受“直接分配、无逃逸、无 return/call/unsafe/非局部跳转、无 `g_current_arena` 读、无取址局部槽中转”的 IF。Phase B 用 `ir_gen_all` 全量重生成，不读写 `.cir` 缓存；缓存 plan 留到后续。

### V2.1 early clear

- 对 LOOP/FOR/FUNC 的槽做活跃性 + 后支配。
- 只在基本块边界插入 `IR_ARENA_CLEAR`；区域出口仍 `IR_ARENA_RESET`。
- 非局部出口（return/break/continue）为仍 live 的子槽插入 cleanup close；或将该候选排除。
- 验收：构造长直线函数，前面分配死亡后 clear，同一槽后续分配复用；slot 计数不增加；有后续使用时 clear 不插入。
- 实现（2026-10-30，V2.1b）：控制邻接上构建后支配集合（worklist，超过 2000 节点或迭代上限则该函数不 clear）。候选 label 必须后支配该槽所有“位于候选点之前”的分配的全部使用点；仍要求候选点之后同一基本块内有同槽分配，且后方不得有回边到 ≤ 候选点。这样跨分支/循环出口的 merge label 也能成为 clear 点，而分支内提前返回、候选点后仍有使用、回边等情况保持 v1。指针使用扫描同时接受“IR 类型为 unit 但 pts 非空”的栈槽；此前的类型门会漏掉 `a := [..]` 这类经槽中转的使用。

### V2.2 merge 复制

- 标量、字符串、POD 聚合、多分支汇合。
- 指针身份观察硬门。
- 验收：if 内分配标量并逃逸到 if 外，split 后副本值正确；指针相等/FFI 用例不 split。
- 实现（2026-10-30，多分支）：if/else 两个分支各分配一个同元素类型、同长度的常量标量数组，并各自直接存入同一个外层局部槽时，只分配一个父槽 `_merge_copy`；每个赋值分支在自己的出口把分支数组复制进该副本并重绑外层槽。eligibility 用指向 IF 汇合 label 的两个 jump 切分 then/else 范围，要求两个分配各居一支、各只绑定一次；外层槽的其他写入、别名逃逸、嵌套分配逃逸仍拒绝。
- 实现（2026-10-30，POD 聚合）：结构体字面量（`IR_ALLOC_STRUCT`）与元组字面量（`IR_ALLOC_ARRAY` 且无数组类型行）可作为 merge 候选。结构体逐字段 `IR_LOAD_FIELD`/`IR_STORE_FIELD` 复制，字段类型必须全部是 int/bool/char/dex；元组按元素槽复制，要求每个元素槽写入的值类型为标量。含数组、字符串、结构体、指针或 optional 字段的聚合保持 v1；if/else 双分支的结构体必须是同一 struct 名，元组必须同元素数。父槽副本在 IF 入口分配，结构体用同一 struct 名，元组用数组分配并复用同一元素数。
- 验收：`test_merge_copy.py` 35 例。标量/双分支（30 例）；POD 结构体、元组及分支内改写的真路径/假路径；结构体指针字段、结构体字符串字段、元组指针元素全部拒绝 merge 并保持运行结果。

### V2.3 share

- 只读共享 + LCPD reset。
- 验收：两个消费者只读同一槽，reset 在两者都退出之后；有写消费者时退回父槽。
- 实现（2026-10-30，广义切片）：
  - 候选 S 是顶层 IF（SG parent = FUNC），与 V2.2 merge 同形的单个常量长度标量数组，存入外层局部槽。
  - IF 之后只允许元素读（`IR_LOAD_INDEX`/`IR_LOAD_INDEX_VAR`）经该外层槽；写、切片、取址、指针比较、FFI 或身份观察都拒绝。
  - Q = 最后一个使用之后最早的、可作为 current-S 点的 label：函数级/普通 IF 的 label 用 label reset（mode 1，要求 Q 后支配 IF 汇合点）；顶层 loop/for/split-IF 的退出 label 用 after-SG reset（mode 0，退出后先 reset 该区域 arena 再 reset S）。顶层结构化退出不依赖后支配（无限循环路径不继续执行，因此无需 reset）。
  - 消费者可以是 LOOP/FOR、split IF、嵌套 loop（无 break/return/unsafe），也可以是普通 IF 后的 parent-level 读；窗口内不得有 call/spawn（跨函数证明除外）、`g_current_arena` 读、return、跳出窗口的 jump、跳到任一 loop/for 出口标签的 break、unsafe SG，或实际落入 S 槽的 allocation。allocation 归属按最近的、其 `IR_ARENA_NEW` 已在该节点之前的释放子图判定；Phase A 中 split/merge IF 的 arena 还未生成，按 SG 入口计。窗口内任何 merge IF 都拒绝（Phase B copy 会落入 S）。
  - 多个 share 按 SG 降序（内层先）启用；若更晚的 merge 候选落在较早候选的窗口内，较早候选保持 merge/v1。share 槽允许嵌套重叠：外层 share 的实际 reset 延后到内层 share 的有效 reset 点，同一事件按 SG 降序（内层先）发射 `IR_ARENA_RESET`，形成 LIFO。多个不重叠 share 也合法，各自 reset。
  - 跨函数只读证明是传递的：每个函数计算 hazard 位（1=unsafe，2=`g_current_arena` 读写，4=arena/spawn/yield/await/未知调用，8=heap/array/field/pointer store），沿调用图做固定点传播。窗口内 `IR_CALL` 的 callee 必须清零 1/2/4；若实参包含共享数组，还须清零 8，且参数写/逃逸/返回别名/FFI 摘要位必须全空。非 arena infra、可解析的 callee 即可，允许调用链。
  - 同一函数内的 merge plan 若在 share 窗口内则阻止该 share。
  - early clear 与 share 共存：父槽 clear 在 share reset 之前的同一 label 发射，`arena_clear` 只重置父槽元数据、不切换 current，不影响共享槽。
  - S 的 arena 在 IF 入口创建，IF 汇合标签**不 reset**；Q 处发射 `IR_ARENA_RESET`（label hook 或 consumer SG reset 之后）。外层槽继续指向 S 内的数组，不复制。`RegionCheck` 的 lifetime exit 对该 SG 使用 Q 的 label id（`rc_sg_lexit` 在 Phase B 重新解析），而不是 IF 汇合点。
  - 验收覆盖 `test_share.py` 30 例：两个/单个/for/嵌套 loop 消费者、IF 消费者、wider label LCPD、多个顺序 share、重叠 share 的 LIFO reset、false path、写/直读/窗口分配/嵌套 IF/break/unsafe/消费者后读拒绝、跨函数（含传递调用链）只读/写入/逃逸/current/arena/无数组叶调用，以及 share 与 early clear 共存；受 `src/ci/run.sh` selfhost-tests 挂钩。
### V2.4 清零配置

- `arena_zero_on_reset` 部署配置。
- 验收：开启时 reset 后 slot 前缀为零；关闭时字节行为与 v1 一致；两种模式的 canary 分别记录。
- 实现（2026-10-30）：运行时新增 `g_arena_zero_on_reset`（默认 0）与 `arena_set_zero_on_reset(v)`；`arena_reset` 在归还 slot 前按配置清零。当前 slot 清已用前缀（静态槽 = `g_arena_cursors`，动态槽 = `g_arena_slot_cursor`），链上更老的槽按整 1MB 清；大对象 extent 仍 `munmap`。编译器新增 `--arena-zero-on-reset`，在 `main` 的全局初始化后把运行时全局置 1；未加 flag 时字节行为与 v1 一致。覆盖 `test_arena_interp.py` 的 setter-on、默认 off、compiler-flag 三组（解释器 + ELF）。

## 九、测试计划

- 单元/IR 探针：SG 树、arena 节点配对、reset 位置、plan 表。
- 负例：逃逸 if、返回 split 值、存入全局、传给会保存参数的函数、身份比较、unsafe、alloc_at。
- 运行时：slot 计数、reset 次数、峰值 slot 数、值一致性。
- 回归：region_escape、byte_permission、alloc_at、pointer_safety、region_cfg、borrow、suite、canary。
- 解释器：split/reset 在解释器中不改变值语义；如果解释器无法表达 slot 复用，明确跳过并记录。

## 十、风险与未决

1. **两阶段编译成本**：Phase B 使 IR 生成和四个 pass 各跑两次。若某个程序的 plan 非空，编译时间约翻倍；需要测量并设阈值。
2. **merge 复制语义**：指针身份、别名、聚合内部指针是主要风险；V2.2 只做可拷贝类型。
3. **share 的写检测**：BytePermission 当前按值/分配推断，跨函数只读证明可能不足；不足时不 share。
4. **early clear 的后支配成本**：大函数上后支配固定点可能较慢；按函数缓存。
5. **canary 换代**：任何实际 split/reset 都会改变 `.ccr`/ELF；需要按阶段更新值表，不能静默改判据。
6. **并发**：每 G 独立 arena 不在本轮；split 只在单线程区域树上定义。

## 十一、已定与待批决策

已定（2026-10-29）：早回收采用 **clear-and-keep**。理由 = 运行时性能最优，且避免 arena id 在早回收与出口 close 之间被复用。V2.1 按此实现，不再把“提前 reset = 关闭槽”作为候选。

待批：

1. **Phase B 实现**：两阶段 IR 生成（推荐，先保证正确性）还是直接做 post-gen rewrite（编译成本低，但需要重建 DF 图和节点编号）。
2. **merge 复制范围**：只做标量/字符串/POD 聚合（推荐），还是一开始就做含指针聚合的深拷贝。
3. **share 范围**：只做只读共享（推荐），还是允许写共享 + copy-on-write。
4. **清零默认**：`arena_zero_on_reset` 默认关闭（推荐，保持性能和字节行为），还是默认开启。

批准后按 V2.0 → V2.1 → V2.2 → V2.3 → V2.4 的顺序落计划；每一阶段独立验收，不把未验证的阶段混入同一次提交。
