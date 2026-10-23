# x86 实例化：执行记录与批次 1 注记

> 对应设计：[2026-09-10-x86-instance-design.md](../specs/2026-09-10-x86-instance-design.md)

本文保存三轴迁移的执行注记、批次 1 提交链、挂账和检查记录。设计正文只保留三轴组合、目录归属、构建分段、寄存器分配切分和演进批次。

# x86 实例化设计（三轴组合：架构、格式、OS）

日期：2026-09-10
状态：已实施（批次 1 结构批次 2026-09-10 Task 1-7 完成，plan `2026-09-10-x86-instance-wave1.md`：三轴目录迁移加组合根 `src/targets/x86_64-linux/` 加序列算法文件化（entry/frame/tag2l/callseq/syscall）加表数据迁架构轴加构建清单分段守卫；检查 = 行为零变化全通过）。批次 2 参数化、批次 3 能力未启动；执行注记见第 8 节（步骤 3，目标架构演进序第 3 步）
性质：实例层设计裁决：把 x86/ELF/Linux 的全部定制内容按三轴归位到实例边界内（内核零改动，规则封闭）；检查按边界 C4 = 行为等价加投影正确性方向。实施分批次（结构批次先，能力批次后）。

关联：
- `docs/superpowers/specs/2026-09-09-corearch-rewrite-design.md`（目标架构：第 1.2 节实例组成/第 2 节裁决表/第 3 节演进序步骤 3，本设计对应这个步骤；“实例边界内的数据化/参数化 = M2 复启的接续形态”）
- `docs/superpowers/specs/2026-09-09-lattice-encoding-boundary-design.md`（边界：C2 输出实例形态/C3 核心只含通用机制/C4 检查裁决，逐字节复刻废止，改为行为等价和投影正确性）
- `docs/superpowers/specs/2026-09-10-corearch-kernel-completion-design.md`（内核完备化：三组件完成态；本设计消费其契约面：登记 API/对象面/声明表）
- `docs/regalloc-cache-mapping.md`（寄存器分配 = 缓存语义映射实例，切分的已定稿基线）
- `docs/superpowers/specs/2026-09-05-hardware-interface-table.md`（HIT：表 = 实例数据形态；M2 挂起中，本设计的表归属规则为其复启前提）

---

## 0. 定位与商讨结论（2026-09-10 用户裁决）

目标架构第 3 节步骤 3 = 实例边界内的数据化/参数化。商讨结论如下：

1. 实例 = 三轴组合：架构（x86_64）× 格式（ELF）× OS（Linux）。前两个轴大体通用（架构目录跨 OS 复用、格式目录跨架构复用），OS 轴最薄。三轴都遵循同一模式：通用机制加特化参数（与 `hit` 的引擎/表数据同构）。
2. 寄存器分配切分原则：需求推导（哪些条目要位置、窗口、可共享，语义侧）与物理选择、搜索、编码（机器侧）分开，切分表见第 4 节；先结构后能力。
3. spill/驱逐 = 独立能力批次：设计预留契约形状（`needs_eviction` 激活后判定34 引擎扩展 = 注册契约演进的正式验证），实施后置。

## 1. 实例的三轴组合

```
架构（src/arch/x86_64/）   ×   格式（src/format/elf/）   ×   OS（src/os/linux/）
   指令/寄存器/编码/序列          容器/段/重定位/链接           syscall/入口/ABI 约定
        └── 构建设置选择组合 = 一个实例配置（x86_64 × elf × linux）
```

- 组合选择机制：构建时（`build_selfhost_native.py` / `Core.toml`）声明三轴选择加交叉适配参数（如 ELF 的 machine ID / reloc 类型 = 格式层的架构特化参数位，由架构轴提供）
- 换实例 = 换轴组合（arm64 × elf × linux = 换架构轴；x86_64 × pe × windows = 换格式和 OS 轴），内核与其余轴零改动（规则封闭的实例级验收）
- ABI = 交叉轴：机器寄存器集（架构轴）× 调用约定（OS 轴）。callseq 归 OS 轴，参数寄存器表引用架构轴

## 2. 三轴目录与文件归属

```
src/arch/x86_64/ 架构轴
│ instr.cr / sizes.cr 指令编码（自 ld/ 迁）
│ regalloc.cr 寄存器分配 CAG（自 ld/ 迁，实例算法）
│ frame.cr 帧布局（自 elf.cr 抽取，序列算法文件化）
│ tag2l.cr tag/2L 编码选择（自 instr.cr/序列面抽取）
│ core-x86.toml 表数据（自 src/arch/hit/ 迁入，目标架构裁决：表 = 实例数据）
src/format/elf/ 格式轴
│ elf.cr 容器/段/phdr（通用结构，自 ld/ 迁）
│ resolve.cr 重定位（自 ld/ 迁）
│ ld.cr 链接机制（自 ld/ 迁；动态链接的 Linux 特有面属于 OS 轴交叉）
│ （架构特化参数位：machine/reloc 类型 = 架构轴提供的数据，交叉适配）
src/os/linux/ OS 轴
│ syscall.cr syscall 约定（自序列面抽取）
│ callseq.cr 参数传递/调用序列（SysV ABI，自 instr.cr 序列面抽取）
│ entry.cr 入口/启动集成（自 elf.cr emit_start 面抽取）
src/arch/hit/ 表引擎（保持，未来实例可复用的框架：hit.cr 加载查询
│ + lower_to_core + 注入通道；模板解释器在 instr.cr = 实例内）
src/lattice/ / src/kernel/ 语义内核 / 验证内核（已落，本设计不动）
src/runtime/ 运行时（rt.s，OS 轴补充）
```

- 序列算法文件化 = 本设计的实质内容之一（现散在 `elf.cr`/`instr.cr` 巨型文件里的帧、调用、syscall 序列显式成文件，即 C2/C3“实例算法”的目录化）
- 平铺不设子目录（文件规模 10 级，concat/导入机制成本不划算；文件增多再分）
- ld project-mode 入口（`main.cr`）随迁 OS 轴或架构轴，实施计划确定（其 flag 注册分歧 = TODO #2026-09-10-2 的处置并入本设计实施批次）

## 3. 构建清单分段（按轴组织）

- `build_selfhost_native.py` 清单重构为分段组合：`common_files`（shared：`globals`/`dyn_arr`/`ast`/`ccr_io` 等）加 `kernel_files`（lattice 内核）加 `non_x86` 无关面（corec 前端）加 `arch_x86_64_files` 加 `format_elf_files` 加 `os_linux_files` 加 `hit` 引擎段，concat = 按确定顺序组合
- 守卫（吸收 ld 单元不报错地缺陷教训）：1 清单文件存在性断言（防止路径变化）；2“目录新文件未入清单”检查（构建设置期提示）；3 构建日志 `error[` 计数非零 = 失败门（TODO #2026-09-10-2 建议3的实施）
- corelsp 等其余 concat = 同一分段机制复用

## 4. 寄存器分配切分（CAG 五阶段侧归属）与能力演进预留

### 4.1 切分判定表（原则，实施批次按需）

| 阶段 | 内容 | 侧归属 | 依据 |
|---|---|---|---|
| 1 门控扫描（DEX/DYN/UNIT/CONST/REF/I2F 排除） | XMM 路径/imm 编码理由 | 实例 | e2_* 发射器能力反射 |
| 2 回边探测加携带值标记 | 跨回边存在性/条件定值差分 | 内核候选（需求推导） | 条目/区域语义，跨范式通用 |
| 3 候选窗口构建 | 区间加扩窗 | 内核候选（需求推导） | 存在区间推导 |
| 4 First Fit 搜索 | 不透明位置的搜索 | 待定区：搜索泛型，可用位置集 = 实例域 | 实施按需（YAGNI：单一实例时留实例侧） |
| 5 终分配 ≤5 对/块写 meta | 块格式编码 | 实例 | 编码 |

- 实施节奏：需求推导上收 = 原则记录加按需（实例 B 出现前的实际收益低）；本设计批次先做物理侧归位和参数化

### 4.2 能力演进预留（spill/驱逐，契约形状预先验证，实施后置）

- 激活点：`needs_eviction=1` 的实例声明，触发判定3（驱逐配对）引擎扩展
- 双向契约三段形状（定稿）：
  1. 实例到内核：登记（`kern_loc_*`，已立）加驱逐/替换事件登记（预留 API 位）
  2. 内核到实例：判定输出（violations/共存证据，已立）加持久条目 home 需求查询（规则 4b：无方法条目必须 home 保真，预留接口位，现 IR 面无实例 = 空槽）
  3. 判定34 引擎实现：`needs_*` = 1 时的契约演进点（现 {0,0}，静态放置无事件，callee-saved 平凡满足）
- spill 引入同时解锁：判定4（调用点失效，被调用者保存集与调用点未维护条目的配对检查）

### 4.3 检查

- 结构批次（批次 1-2）：行为零变化，全回归加 `backend_bootstrap` stage 链 byte-identical 加 `ccr_v7` 产物 byte-identical 加 `full-bootstrap` guard（纯搬移/文件化证明）
- 能力批次（批次 3，后置）：行为等价按边界 C4（非逐字节复刻，实例算法可自由设计，正确性检查 = 投影正确性方向），M2 复启的检查修订同步实施

## 5. 演进批次（实施另立）

1. 批次 1 结构：三轴目录重组（文件迁移）加序列算法文件化（frame/callseq/tag2l/syscall/entry 抽取）加表数据迁架构轴加构建清单分段加守卫。检查 = 行为零变化（纯搬移）。完成（2026-09-10，plan `2026-09-10-x86-instance-wave1.md` Tasks 1-7，提交 29d177ac49a5 / b23f008000cf / b0ba8c1c9b01 / d65fc1b8f3c3 / 3ab39f6eaa16 / 94d1cac15359 加各自 docs 提交；执行注记 = 第 8 节）。三轴目录（`src/arch/x86_64/` 加 `src/format/elf/` 加 `src/os/linux/`）加组合根 `src/targets/x86_64-linux/` 落位；序列算法文件化五件（entry 整搬 / frame 抽取含帧公式双源合流 / tag2l 整搬 / callseq 抽取含 SysV 三处同源合流 / syscall 抽取）；表数据 `core-x86.toml` 迁架构轴（hit 引擎留原位）；清单八段化加存在性守卫加 `error[` 计数门。检查：行为零变化全通过（每任务 stage 链 byte-identical 加完成全量回归逐套计数加 full-bootstrap guard corec2/corec3 cmp 同加 N06=0）加自举重建快速验证加 syscall4 套件持久覆盖（`tests/suite/syscall4_test.cr`）
2. 批次 2 参数化：序列算法按实例边界参数化/整理（C2/C3 实例算法形态，含 TODO #2026-09-10-2 双入口处置）
3. 批次 3 能力（后置独立）：spill/驱逐加判定34 激活加双向契约第三段实施加 M2 复启（检查按 C4 修订）
4. 远期：实例 B（arm64 或非经典），三轴组合验证（换轴零内核改动 = 规则封闭验收）

## 6. 挂账与风险

- M2 交互：HIT 表数据迁架构轴（批次 1）与 M2 挂起状态。搬迁检查 = 全回归（表路径测试 `hit_table` 24/24 保持）；M2 复启时表定位（引擎/数据分离）已由本设计解决。批次 1 已实施：表数据 `src/arch/x86_64/core-x86.toml` 加引擎 `src/arch/hit/` 分离落位，`hit_table` 24/24 保持（M2 挂起态未动，本批次只搬定位面）
- rc/cmp 检查：文件移动不改产物（asm 后端无 `.loc`，评审曾实测注释变化 asm byte-identical）；stage 链 run 内 byte-identical 检查保持
- `main.cr` 双入口（TODO #2026-09-10-2）：批次 2 处置（注册收敛或显式分歧留档）。批次 1 已搬未收敛：双入口之一随 Task 1 迁入组合根（`src/arch/linux/ld/main.cr` 改为 `src/targets/x86_64-linux/main.cr`），分歧本体（ld project-mode 入口缺 HIT/表旗标注册）逐字保持，`test_backend_bootstrap` stage 链仍走该入口；按 H7 纪律，批次 1 只同步注记措辞，flag 面收敛留批次 2
- 架构特化参数位（格式层的 machine/reloc）：批次 1 只搬迁不建参数机制；交叉适配机制 = 批次 2 或实例 B 时确定
- 批次 1 评审裁决遗留（全部登记 TODO，均不改批次 1 结构面）：TODO #2026-09-10-4 = 前端 ≥18 形参不报错地误编译类（高优先级，根因在前端参数表/AST bookkeeping，本批次零接触；其 4 项“22 参 runtime 用例入 `tests/suite/`” = 该项缺陷修复后才可达，非批次 1 结束条件）；TODO #2026-09-10-5 = `IR_CALL_EXTERN` >6 int 参语义缺口（`callseq.cr` 指针实施，批次 1 按“零变化”逐字保留预存不对称，修复 = 批次 2 FFI 面）；TODO #2026-09-10-6 = `src/format/elf/elf.cr` 三处手写 syscall 序列（mmap/clone/exit，syscall1/5/6 形）留在格式轴 = 实例 B“换轴零改动”承诺的反例，迁移到 `src/os/linux/` = 批次 2 或实例 B 前置（Task 6 只抽 syscall3/4 内置体发射面，未扩面）
- 本设计不承诺：需求推导上收（第 4.1 节内核候选，按需）、spill/驱逐实施（第 4.2 节预留）、格式轴跨 OS 全面参数化（PE 出现前 YAGNI）

## 7. 关联同步项

- 目标架构第 1.2/3 节步骤 3 对应本设计（批次 1 已实施，见第 5 节批次 1 和第 8 节）
- TODO #2026-09-10-2（双入口分歧）在批次 2 处置（批次 1 已搬未收敛，见第 6 节）；TODO #2026-09-09-1/#5 不受影响
- TODO #2026-09-10-4/#9/#10（批次 1 评审裁决登记）全属批次 2 或后续专项，本批次只登记不改结构面（见第 6 节末条）
- M2 计划/spec：复启时按本设计表归属加 C4 检查修订执行
- 目录分层先例（`src/lattice` 搬迁 712946a0）机制复用（`module.cr` 回退链/清单/守卫）

## 8. 执行注记（批次 1 完成回填，2026-09-10 Task 1-7）

> 本节约 = 设计实施确认（plan `2026-09-10-x86-instance-wave1.md` Tasks 1-7）。
> 提交落点：Task 0 盘点 327c2cf01af3（设计定稿 6694f358f376）/ Task 1 三轴搬迁加组合根
> 29d177ac49a5（加补正 c927525baf35、docs 58e6be3a1c18）/ Task 2 `entry.cr` 整搬
> b23f008000cf（加 docs 8dcfaeca52b2）/ Task 3 `frame.cr` 抽取 b0ba8c1c9b01 / Task 4
> `tag2l.cr` 整搬 d65fc1b8f3c3（加 docs c6b6cbfe9a75）/ Task 5 `callseq.cr` 抽取
> 3ab39f6eaa16（加 docs 525a872a0ba7）/ Task 6 `syscall.cr` 抽取 94d1cac15359（加 docs
> d2f3e0968d8c）/ Task 7（本状态行随完成提交落盘）。行为零变化检查（第 4.3 节结构批次）
> 全通过：逐任务 stage 链 byte-identical（搬迁任务用 R 重命名，内容保持原样；抽取任务
> 内容进新文件加调用点替换，每步独立构建验证）加完成全量回归逐套计数。

### 8.1 实施位置摘要（三轴加组合根加清单）

- 架构轴 `src/arch/x86_64/`：`instr.cr`（指令编码）/`sizes.cr`（字节尺寸单源）/`regalloc.cr`（CAG）/`core-x86.toml`（HIT 表数据，自 `src/arch/hit/` 迁入），Task 1；
 `frame.cr`（帧布局：`pf_frame_size`/`pf_prologue`/`pf_epilogue` 加 `g2_tag_off`/`mw_frame_size`，H2 帧公式双源合流单入口），Task 3；`tag2l.cr`（mw 族纯编码整搬），Task 4。tag2l 与 frame 同轴双向引用 = 裁定可接受（注记随代码）。
- 格式轴 `src/format/elf/`：`elf.cr`/`resolve.cr`/`ld.cr`，Task 1（纯搬）。
- OS 轴 `src/os/linux/`：`entry.cr`（`emit_start`/`emit_start_size` 整搬），Task 2；
 `callseq.cr`（`cs_args_dispatch`/`cs_arg_on_stack`/`cs_stack_count`/`cs_stack_args`/
 `cs_stack_cleanup`/`cs_ret_value`/`cs_call_direct`，SysV 三处同源合流，per-slice
 字节比对核对后合并；`IR_CALL_EXTERN` 预存不对称未合并、未连带修复 = TODO #2026-09-10-5），Task 5；
 `syscall.cr`（`sys_syscall3_stub`/`sys_syscall4_stub`，r10 第四参约定），Task 6。
- 组合根 `src/targets/x86_64-linux/`：`main.cr` 加 `_import.cr` 加 `Core.toml`
 （target triple 命名；project-mode 入口链，不入 concat），Task 1。stage0 硬编码点
 `test_backend_bootstrap.py:13` 先改后搬（H6）。
- 清单分段加守卫（`build_selfhost_native.py`）：八段化（`common_files`/`hit_engine_files`/
 `kernel_files`/`arch_x86_64_files`/`format_elf_files`/`os_linux_files`/`backend_support_files`/
 `x86_linux_target_files`）；守卫 = 清单文件存在性断言加构建日志 `error[` 计数非零 = 失败门
 （TODO #2026-09-10-2 3 建议的构建面实施）加 project-mode 面 `run_checked` 同门（`test_backend_bootstrap.py`，
 Task 1 补正 c927525baf35）。

### 8.2 完成检查（Task 7，逐套计数）

构建（清 `.core/cache`，`nice -n 19 python3 build_selfhost_native.py`）：BUILD SUCCESS；
四段守卫全 OK（corec 37 文件 / corearch 31 文件 / x86_64-linux target 3 文件 / corelsp 26 文件），
构建日志 `error[` = 0（三产物各 0）。

| 套件 | 计数 |
|---|---|
| `test_compile.py` | 3/3（interp run / lexer 源编译 / 自编译 native） |
| `test_backend_bootstrap.py` | 11/11（stage1=stage2=stage3 byte-identical 加 O0/O2 快速验证 rc=7） |
| `test_hit_table.py` | 24/24（表路径保持，M2 挂起态不动） |
| `test_region_cfg.py` | 22/22 |
| `test_slice_bounds.py` | 7/7 |
| `test_live_ranges.py` | 13/13 |
| `test_ccr_v7.py` | 24/24 |
| `test_ent_kernel_neutrality.py`（中立性 guard A+B） | PASS ×2（A clean / B clean） |
| `test_mw_task1..6.py` | 1-6 全 ALL PASS（1 含 `s7_framediff` 帧差专项，H2 检查） |
| bootstrap 三套 | pipeline 29/29 / borrow 4/4 / generics 3/3 |
| full-bootstrap guard | `corec` 编译 `corec2` rc=0、`corec2` 编译 `corec3` rc=0、cmp byte-identical、两段 `error[N06]=0` / `error[` 总 0；`corec3 --help` rc=1（CI 断言形） |
| 重建快速验证 | `corec run` rc=42 / `corec check` rc=0 / `corec build` rc=0 然后运行 rc=42 / `corec3 check` rc=0 |

syscall4 持久套件覆盖（批次 1 遗留项，原覆盖仅 /tmp 探针）：新增
`tests/suite/syscall4_test.cr`（`import io` 加 `import os`；`system("exit 3")` 得到并断言 rc==3、
`system("exit 42")` 得到并断言 rc==42，以排除常量/陈旧缓冲区回传；suite 惯例 = main 返 0 为通过，
失败回 1/2）。构建日志 `error[` = 0，运行 ALL PASS rc=0（`build/corec` 与 stage 链 `corec3`
两工具链均通过），覆盖 `os.cr` × `wait4` × `syscall4` r10 第四参路径。

### 8.3 本批次未做项（范围克制，批次 2 起）

- `IR_CALL_EXTERN` 栈参/栈清理不对称未修（TODO #2026-09-10-5）；前端 ≥18 形参缺陷未修（TODO #2026-09-10-4）。
 两者都是预存问题，与结构批次正交，按“零变化”纪律不混入。
- `src/format/elf/elf.cr` 三处手写 syscall 序列未迁移（TODO #2026-09-10-6）；内置体名索引扫描段留原位
 加注（`elf.cr` 877-886），整段参数化 = 批次 2。
- `pf_frame_overhead` 预存双计（无发射影响）未清；`sizes.cr` tag2l 同源化声明已弱化（值一致
 但尚未同源），Task 4 评审注记，批次 2 清。
- 架构特化参数位（格式层 machine/reloc）未建机制；spill/驱逐（第 4.2 节）未启动。
