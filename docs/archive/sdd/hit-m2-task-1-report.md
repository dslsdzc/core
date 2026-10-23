# HIT M2 任务 1 执行报告：core-x86.toml schema v2 和表加载扩展（hit.cr）

状态：完成（DONE）
日期：2026-09-07
提交：jj change，在 qqlzvupq 之上新建，描述为 `feat: HIT schema v2——投影模板语言扩展 + 运行时核事件声明（M2a Task 1）`。

改动文件：

- `src/arch/hit/core-x86.toml`：v1 迁移到 v2，事件 1 到 4 增加结构化 REX 字段，事件 5 到 9 增加控制、调用、系统核声明，并增加 `[runtime.x86]` 小节。
- `src/arch/hit/hit.cr`：记录布局加宽，增加 v2 解析器、runtime 小节和新接口。
- `tests/selfhost/test_hit_table.py`：步骤 2 追加 5 个测试，包括真实表 walker、F1、F2、F3 夹具和坏文件拒绝面。

## 一、实施内容

### hit.cr（记录布局和解析扩展，M1 契约零破坏）

- 记录布局，只改常量定义，消费方 `instr.cr`、`elf.cr`、`lower_to_core.cr` 未动：
  - 事件记录 40B，等于 10 个 i32：id、name、inputs、outputs、side 之后，20/24/28 是 proj0 镜像，即 isa、步数、首步偏移。M1 消费面 `hit_proj_step(es,0,st)` 的视区与 M1 逐字段一致。32/36 是首投影记录下标和投影形态数，支持多个 proj。
  - 投影记录 12B，等于 3 个 i32：isa、步数、首步在 `g_hit_steps` 中的字节偏移，使用新的 buffer 表。
  - 步记录从 20B 改为 108B。前 20B 是 M1 布局视区原样，包含 OP0、OP1、REG_ROLE、RM_ROLE、RM_MODE，`instr.cr` 只读 0 到 16，字节级不变。20B 起是 v2 规范字段：prefix 两个、REX、opcode 三个加 OPN、digit、SIB 三个、disp 两个、imm 四个、rel 三个、cond。
- 解析，schema v2 模板语言，逐字段值域和关联校验，错误全部拒绝加载：
  - 层级允许清单扫描，未知键报 `unknown key 'X'`；rex_w/r/x/b 逐位检查 0 或 1，错误为 `bad rex bit`；REX 字节只在任一位出现且为 1 时产生，判据与 walker 的 `rb != 0x40` 同构；prefix 最多 2 字节；opcode 必选 1 到 3 字节，每字节不超过 255。`toml_get_int_list` 的 cap 语义区分“超过 3 字节”和 4 项清单。
  - modrm 族，键出现才算族：reg 侧角色和 `/digit` 0 到 7 必须二选一；`rm_role` 必须有；rm_mode 为 0 到 2；sib 键要求 rm_mode 2；rm_mode 2 要求 `sib_scale` 和 `sib_base_role`；`modrm_base_role` 要求 rm_mode 1 或 2；disp 键要求 rm_mode 1 或 2。角色和寄存器字面量支持 16 加 regno，以及 rip 基码空间。
  - imm 族，与 modrm 族正交：size 属于 {1,2,4,8}；role 或 kind 至少一个；lit 到 100 码；fnaddr 要求 size 8。rel 族三个字段同时出现，kind 为 event、func、extern，size 属于 {8,32}；另有 cond_role。
  - 平铺 v1 形，等于 v2 的子集：没有步小节时，proj 层字段除 isa 外就是单步字段，允许清单为步层全表，`isa_ok`。M1 表形态可以原样加载。
  - 事件和步记录先零初始化再写入，未用字段恒为 0，保持 M2-2a 的哨兵约定。
- `[runtime.x86]` 小节：8 个键齐备并校验枚举值，包括 stack、pushed、down、regs、call_rel32、ext_rel。param_regs 和 save_regs 是空格分隔的寄存器名，转成位掩码，例如 rdi 是第 7 位。小节可选，出现则键必须齐备。顶级加载循环按 `[[event]]` 和 `[runtime.x86]` 的出现顺序任意交错切块，runtime 之后追加事件也可以。坏值域测试把 v1 事件 50 追加在 runtime 之后。
- 新接口：`hit_proj_count`、`hit_proj_step_count`、`hit_proj_step_get`，proj_i 或 step_i 越界返回 -1，整条 108B 复制；`hit_runtime_get`，key 到槽值或掩码，没有小节或未知键返回 -1。`hit_proj_step` 保留为 proj0 视图别名，事件 24/28 字段是 proj0 镜像，语义与 M1 等价。`load_hit_table`、`hit_table_active`、`hit_event_lookup`、`hit_event_name` 契约不变，名字表 `g_hit_names` 存 str 指针，每项 8B。
- 常量零冲突：没有定义 HIT_EV_SUB、NAND、LOAD、STORE，HIT_EV_LOAD 等归 `lower_to_core.cr`；没有同名函数或全局变量与核心表文件集合冲突，已用全 `src/arch` 和 `src/compiler` 的 grep 互证。

### core-x86.toml（v2 迁移）

- `[table]` 的 `events = 9`，从 M1 的 4 个改为运行时核的 9 个，即 M1 数据事件 1 到 4，加控制、调用、系统事件 5 到 9。
- 事件 1 到 4 迁移为结构化 v2 表达，使用步小节和 rex_w/r(/b) 逐位。legacy 字节视区与 M1 模板逐字节等价：sub 为 `4D 29`（w+r+b），nand 为 `4D 21`（w+r+b），load 为 `4C 8B`（w+r），store 为 `4C 89`（w+r）。角色和 rm_mode 与 M1 相同，load 和 store 都使用 rm_mode 1 加 addr 角色，`hit_ev_emit_pool_mov` 的特判面不变。
- 事件 5 到 9 声明真实 x86 投影：5 是 jump `E9 rel32`，kind=event；6 是 branch 两步，cmp r/m64, imm8 为 `83 /7`，加 jne `0F 85 rel32`；7 是 call `E8 rel32`，kind=func；8 是 ret `C3`，没有 modrm 和 rel 键；9 是 extern `E8 rel32`，kind=extern。发射器消费之前只要求加载通过，沿用 M1 的 "needs more events" 通道。计划任务 4 的降低对照会定稿语义绑定。
- `[runtime.x86]` 小节有 8 个键：参数传递使用 regs，param_regs 为 rdi、rsi、rdx、rcx、r8、r9；save_regs 为 rbx、r12 到 r15；extern 为 call_rel32 和 ext_rel，对应 spec 第 6 节 x86-64 一档。

## 二、验证（16/16 通过）

- 真实表 walker，独立 Python 双实现互证：core-x86.toml v2 全字段校验零问题；id 为 1 到 9；事件 1 到 4 的 legacy 流为 `4D 29`、`4D 21`、`4C 8B`、`4C 89`，检查了 REX 组装和 opcode 拼接顺序；5 到 9 的形态逐项检查；ret 没有 modrm 和 rel 键；save 集为 rbx 和 r12 到 r15。
- 夹具加载：FD 的 F1 是 v1 子集事件 1 到 4 加 v2 事件 5 到 9 和 runtime，加载为 9 个事件，sub 运行 exit 2；F2 是事件 3 的多 proj 条目，加载通过，proj0 发射运行不变；F3 是 v2 全字段，包含 prefix、rex 全位、3 字节 opcode、SIB、digit、imm、rel8、cond、fnaddr，加载为 10 个事件，逐字段解析通过。
- 坏文件拒绝面 14 个变体：rex bit、rel kind、rel size、disp_size、opcode 超过 3 字节、prefix 超过 2 字节、imm_size、reg digit、side_effect、sib 字段要求 rm_mode 2、未知键、call_mechanism、重复事件 id、计数不符。全部 exit 1，并输出期望消息。
- M1 全量回归：sub、add、mem 的旧路径和 `--table` 双 ELF exit 一致，分别为 2、12、5；事件流 dump 正常，sub 事件加常量池 3 条目；越子集 op 被拒绝，报 "needs more events"；冒烟 smoke_add 和 smoke_mem；缺表文件拒绝；opcode 超过 255 拒绝，做法是在表尾追加 v1 事件 50；`--table` 与 `--link` 或 `--shared` 组合拒绝；未用哨兵字段没有 255 或 -1 伪影；`hit.cr` 和 `lower_to_core.cr` 单独 `corec check` 干净。
- 旧路径零变化：`corec build` 不带 `--table` 时冒烟 exit 2，符合期望。改动面只在 `--table` 模式，`hit.cr` 不进入 corec 构建，只在 `--table` 时载入；corearch 加载打印的变化只有事件计数从 4 变为 9。

## 三、自审（逐项）

- `instr.cr` 消费面逐字节核对：`hit_ev_step_of` 改为 `hit_proj_step(es,0,st)`，走 proj0 镜像通路，只读 0 到 16，即 OP0、OP1、REG_ROLE、RM_ROLE、RM_MODE。M1 事件 1 到 4 记录的前 20B 与此逐字段一致。pool mov 特判保持，load 为 rm_mode 1、reg 为目标、rm 为地址。
- 常量和函数交叉引用 grep 互证：消费方引用的 `hit_*` 函数和 `HIT_ST_OFF_*`、`HIT_ROLE_*` 常量全部由新 `hit.cr` 提供，或者各文件自持，没有重复定义。
- 记录写入采用零初始化后置字段，`w32` 只存非负值，id、字节、码全非负由校验前置保证。
- `toml.cr` 语义实证，逐行读实现：`get_int` 遇到首个非数字截断，行内注释可以；`get_int_list` 超过 max 返回 -1，恰好 max 返回 count，因此能区分“超过 3 字节”和 4 项；支持 `0x` 十六进制解析。
- 语言构造实证：loop、else if、&&、||、多语句行、同名重声明都是代码库既有惯例，`cir_cache.cr`、`instr.cr`、`elf.cr`、`opt.cr` 可以互证；`corec check hit.cr` 干净，import io、toml、fmt 闭包解析通过。

## 四、待说明的问题（非阻塞）

1. TC02 分支类型约束：if 和 else 两个分支必须同型，赋值或调用与 return 混合会报“If branches have different types”。已按守卫早退风格重构，先错误 return，后无 else 的独立 if，这是代码库既有惯例，无行为影响。
2. 事件 5 到 9 目前只做到“加载通过”：模板是真实 x86 形态，但消费语义，包括条件判定、rel 回填表、调用序列，留到任务 4 及以后定稿，与本任务范围“表加载扩展”一致。加载器已经为消费面准备好全部字段。
3. `[runtime.x86]` 尚无消费方：`hit_runtime_get` 已就绪，绑定 `elf.cr` 运行时 stub 族属于任务 9 及以后，见任务 0 清单 R2/R10 行。本任务只做声明和加载校验。
4. flat 形多 proj 混排：事件可以平铺，也可以使用步小节，两种形态可以混排，proj 级逐条判定，F2 已实证。walker 只支持无注释表头，夹具表头带行尾注释时不经过 walker，而经过加载器，两者各自通过。

## 五、交付物

- 报告：`/home/DslsDZC/core/docs/archive/sdd/hit-m2-task-1-report.md`
- 提交：三个文件，即 `hit.cr`、`core-x86.toml`、`test_hit_table.py`。未跟踪的 `docs/superpowers/plans/2026-09-07-regalloc-backend.md` 不入提交；不动 bookmark。

---

## 修复轮：oysvkvspksrz（任务 1 评审修复，复审完整流程）

状态：完成（DONE）。评审的 1 条 Important、3 条 Minor、1 条记录项全部处置。
日期：2026-09-08
改动文件：`src/arch/hit/hit.cr`，修正循环边界、评审注记和 `--dump-table` 读回 helper；`src/arch/linux/ld/instr.cr`，修正一行注释；`src/compiler/corearch.cr`，注册 `--dump-table` 标志和调用点；`tests/selfhost/test_hit_table.py`，增加 F4 夹具和固定测试。

### 逐项处置

1. Important：step 小节解析循环越界，`hit.cr:781-798`，原为 781 到 793。续行改为 `if ns >= 0 && (np2 < 0 || ns < np2) { sp = ns; } else { sp = -1; }`。当 ns 落在下一个 `[[event.proj]]` 头之后，说明是后续投影的步小节，不再续入本投影。原先 np2 只截断步文本，不终止循环；旧缺陷是不报错地吸收并让步重复入库。固定测试使用新的 F4 夹具：`V2_F4 = V2_FIX` 加单个事件 10、双 proj、双双步小节，字节 90 到 93 互异，经 `corearch --table --dump-table` 加载读回。修复后 p0=2、p1=2，逐步 opb 为 144 到 147，各归其位，没有 p=0 s=2/3。旧代码下 p0=4，发生错误吸收，并出现 p=0 s=2/3，见逐行推演和表尾注。
2. Minor：`instr.cr` 的“20B 记录”注释陈旧，位置 `instr.cr:2226`。改为“proj0 视图整条 108B 记录复制入 st；本文件 M1 消费面只读前 20B 视区。schema v2 记录加宽后偏移 0 到 16 的语义未变，见 hit.cr 布局注释”。消费方代码零改动，alloc 本来就随 `HIT_STEP_REC` 常量缩放。
3. Minor：运行时核 id 1 到 9 的加载器未强制在场。决定不实现强制，事件绑定在任务 4，届时消费方按 id 查找会自然暴露缺失。已在加载器计数检查位，即 `hit.cr` 核对 `[table] events` 之前，加注记，说明 spec 第 2 节“每个表必须有 9 个事件”和验证项“缺事件拒绝”的强制检查延后到任务 4，缺口在代码中显式化。
4. Minor：v2 字段区没有读回覆盖。借评审项 1 的 fixture 一并关闭。新增 `--dump-table` 通道，由 `hit.cr` 的 `hit_dump_table_state` 和 corearch 标志组成，只读表状态。通过 `hit_proj_step_get` 整条复制 108B 后读取 opcode 区 OPB0，偏移 32，逐事件、投影、步输出，并读回 runtime 槽位掩码，param_regs=966，save_regs=61448。F4 断言这些探针值，作为 108B 布局写读一致的实证。后续任务 4 的消费方仍按计划补正式读回断言。
5. Minor：walker 和加载器对 `disp_size=auto` 的引号容忍存在变化。可达性为零，现表没有裸写 `disp_size = "auto"`，因此不改代码，只记录：walker 的 `_chk_step_fields` 要求 `"auto"` 带引号，加载器的 `hit_parse_step` 去掉引号后也接受裸 auto。未来表如果写裸 auto，walker 会误报，届时再同步。

### 验证（全部通过；编译使用 `nice -n 19` 限制 CPU）

- 重建：`nice -n 19 python3 build_selfhost_native.py` exit 0。
- 聚焦套件 `tests/selfhost/test_hit_table.py`：17/17 通过，原 16 加新 f4。
  - f4：多 proj 步小节归属正确，p0=2、p1=2，没有错误吸收，v2 字段区读回一致。
  - 其余全部通过：sub、add、mem 双路径 exit 2、12、5；dump；越子集拒绝；smoke 双件；缺表、opcode 超过 255、`--link` 和 `--shared` 组合、哨兵伪影；`hit.cr` 和 lower 单独 check；walker 真实表；F1、F2、F3；坏文件拒绝面 14 个变体。
- 回归：`test_compile.py` 全部通过，`test_impl.py` 7/7，`test_borrow.py` 7/7。
- M1 字节等价不受影响：事件 1 到 4 的 legacy 视区和模板字节零触碰。改动面是循环边界、注释和读回 dump；dump 只在 `--dump-table` 标志下输出，既有测试的输出形状零变化。

### 注（固定测试的旧缺陷失败证据）

没有做旧代码反跑，因为仓库铁律禁止还原文件。旧缺陷的失败性按逐行推演：F4 下旧的续行 `sp = ns` 会让 proj0 吸收 92 和 93，导致步数 p0=4、镜像 24 字段等于 4、`g_hit_steps` 有六条，即 A、B、C、D 加重复的 C、D。F4 的断言“projs=2 p0=2 p1=2”和“没有 p=0 s=2”与旧行为直接冲突。
