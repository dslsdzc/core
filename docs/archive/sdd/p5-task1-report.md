# R2 P5 任务 1 实施报告：`.cir` 暖态 SIGSEGV 根因修复

计划为 `docs/superpowers/plans/2026-09-13-r2-p5-cleanup.md` 的任务 1，步骤 1 到 5。

本实例接续一个中断的实例。前实例在跑判据前因 API 402 终止，工作区残留它的 3 件改动，本报告第 7 节逐件核对。

证据目录：本实例为 `/tmp/p5t1b/`，全部判据由本实例重跑；前实例为 `/tmp/p5t1/`，只作旁证，逐条标注。

## 0. 摘要

| 项 | 结论 |
|---|---|
| 根因（一句话） | 装载侧逐函数执行 `read_file(path)`，即 `alloc(fsize+1)`，而 bump 分配器不回收。946 个快照读缓冲累计 1.1674 GiB，超过 1 GiB 堆。`alloc` 耗尽返回 0，入口是 `rt.s .Lalloc_oom`。`load_cir_cache` 首行执行 `str_len(0)`，进入 `load64(0,-8)`，触发 SIGSEGV。暖态 rc=139，冷态不读快照所以 rc=0。格式和长度域没有缺陷，写读对称表逐字段核对见第 2 节，因此不升级 `CIR_CACHE_VER`，停条件未触发 |
| 修复 | `src/compiler/cir_cache.cr` 新增 `cir_read_snapshot`，快照读入使用单一复用缓冲。峰值等于最大单文件尺寸 3.99MB，不再是全体累计。失败情况包括 open 失败、空文件、短读、缓冲不可得，统一返回 -1，表示 cache miss，遵守三态纪律：载入失败就拒绝，不得不报错地当作空表。读侧从此与写侧既有的 `g_cir_write_buf/g_cir_write_cap` 同构 |
| 判据 | 19/19，`COREC_WARM_SELF=1` 时为 21/21；`build_selfhost_native.py` rc=0；`check src/compiler` rc=0；`test_backend_bootstrap` rc=0 且 `error[` 为 0；`selftest-types` 355/355；全枚举 56/56，即 48+1 个 selfhost 加 7 个 bootstrap；ELF canary `95084e7b…d475` IDENTICAL；暖态等于冷态，自源 ELF 三跑逐字节相同，`.ccr` 八段全同；自举链 `corec2==corec3` 的 cmp 为 IDENTICAL，N06=0，冒烟 42，`--help` rc=1；突变控制把前路径回灌后，新套件有 15/16 失败 |
| 提交 | `11913f8a`，路径限定 5 个文件：`src/compiler/cir_cache.cr`、`src/ci/run.sh`、`tests/selfhost/test_cir_warm_path.py`、计划、`TODO.md`。报告工作区不入提交，口径同 T0 |

## 1. 失败态复现（步骤 1）

### 1.1 自源语料（真实失败态；冻结基线复证“预存，不是本批引入”）

命令，cwd 为仓库根，全部使用 `nice -n 19`。基线是任务 0 冻结的 `/tmp/p5t0/base/corec`，sha 为 `5d2b15ad746018619b01143cce400e6f3489ae72a962e12283a7afd3dcdb41e7`。

```
/tmp/p5t0/base/corec clean-cache                       # rc=0（"cleaned .core/cache/cir/"）
/tmp/p5t0/base/corec build src/compiler/main.cr -O 0 -o /tmp/p5t1b/base_self_cold --static   # 冷 rc=0
/tmp/p5t0/base/corec build src/compiler/main.cr -O 0 -o /tmp/p5t1b/base_self_warm --static   # 暖 rc=139
```

日志 `/tmp/p5t1b/base_self_warm.log` 共 1265B，止于 `[5/5] frontend done`，另有 shell 的段错误记录。gdb 输出在 `/tmp/p5t1b/base_self_gdb.log`：

```
Program received signal SIGSEGV, Segmentation fault.
0x0000000000521666 in load64 ()
#0  load64 ()      rdi=0x0  rsi=0xfffffffffffffff8 (-8)  rax=0
#1  str_len ()
#2  load_cir_cache ()
#3  then_14095 ()
```

稳定可重复：本实例 1 次，前实例 2 次，`/tmp/p5t1/gdb.log` 是同一栈和同一寄存器值 `rdi=0/rsi=-8`，合计 3/3 同栈。

### 1.2 缓存清点（根因量化；本实例实测）

冷跑后清点 `src_compiler_main.cr::*.cir`，用 Python 统计，本实例执行：

```
entries=946  total=1253453548 B = 1.1674 GiB   （> rt.s heap_start .space 1024*1024*1024 = 1 GiB）
max 单条目 = 3987879 B（3.80 MiB，type_selftest_run）· 次大 3415814（gen_expr）· 3317558（gen_clone_tree）
```

因此修复前的暖路径按函数各执行 `alloc(fsize+1)`，仅读缓冲一项就有 1.1674 GiB，超过 1 GiB 堆，还不含前端常规驻留，必然 OOM。`rt.s` 侧证据：`alloc` 尾部的 OOM 分支为 `.Lalloc_oom: xor eax,eax; ret`，返回 0，不 trap；堆为 `heap_start: .space 1024*1024*1024`。

### 1.3 廉价复现（不依赖自源语料；新套件 D 节就是此例）

```
COREC_BIN=/tmp/p5t0/base/corec python3 tests/selfhost/test_cir_warm_path.py
→ 15 PASS / 1 FAIL：[FAIL] D3_pad_warm_rc0 — rc=-11（SIGSEGV）
   （416 条目补零至 3MB ⇒ Σ=1,308,622,848 B > 1 GiB 堆；D1 冷 rc=0 / D2 Σ>堆 均 PASS）
```

同一套件对冻结基线运行时，D3 失败，其余 A、B、C、D1、D2 通过。这是“失败态由累计装载单独解释”的最小反证。

## 2. 归因（步骤 2：写读对称表）

写侧是 `save_cir_cache`（`cir_cache.cr:184-347`），读侧是 `load_cir_cache`（`:428-616`）加入场检查，包括版本、身份、指纹。逐字段如下：

| 字段 | 写侧（偏移推进） | 读侧（偏移推进） | 长度来源 |
|---|---|---|---|
| magic / ver | 8+8 | 8+8，不匹配返回 -1 | 常量 |
| identity（v17） | 8 | 8，`cid==0 || entry_cid!=cid` 时返回 -1 | `/proc/self/exe` 内容哈希，memoized |
| fp / sig | 8+8 | 8+8，不匹配返回 -1 | 纯 AST 指纹 |
| name_len + name | `8 + name_len` | `8` 加跳过 `name_len` | 写侧同一 `name` 的 `str_len` |
| var_count + 记录 | `8 + 24×n` | `8 + 3×8×n` | 写侧循环计数 |
| node_count + 记录 | `8 + 64×n`，第 9 槽不写入磁盘 | `8 + 8×8×n`，项槽重派生，P4 T4 裁定 | 同上 |
| sg_count + 记录 | `8 + 48×n` | `8 + 6×8×n` | 同上 |
| edge_count + 记录 | `8 + 32×n` | `8 + 4×8×n` | 同上 |
| instr_count + 记录 | `8 + 48×n` | `8 + 6×8×n` | 同上 |
| str_count + 串 | `8 + Σ(8+len)` | `8 + Σ(8+len)` | 写侧同一 `istr_get` |

结论：逐字段对称，`pos` 推进同源，没有长度域读偏或越界。候选根因逐条排除：长度字段读偏、0 长与空串混淆、函数计数不一致、身份检查后残余旧条目。本崩溃与盘面内容无关，同一份盘面在冷态可以正常写入，在暖态读出就崩溃。根因链如下：

```
① 读侧逐函数 read_file ⇒ alloc(fsize+1)，bump 分配器不回收（rt.s alloc 只前进 heap_ptr）
② 单文件尺寸是 O(程序) 而非 O(函数)：快照含全程序边表（写侧 :301 写 g_df_edge_count 全量）+ 全程序串表
   ⇒ 946 条目 Σ=1.1674 GiB > 1 GiB 堆
③ alloc 耗尽返回 0（.Lalloc_oom）⇒ read_file 把 0 当 string 返回
④ load_cir_cache 首行 str_len(0) → load64(0,-8) ⇒ SIGSEGV（冷态不走该路径 ⇒ rc=0）
```

停条件核对：不指向格式缺陷，无需升级版本；不与“快照面语义”纠缠，修复只在读入方式。因此按任务 1 原方案执行。

## 3. 修复（步骤 3）

`src/compiler/cir_cache.cr:386-423` 新增 30 行，`:429-435` 让 `load_cir_cache` 入场改走新函数。

```
g_cir_read_buf : string, mut;
g_cir_read_cap : int, mut;     // 数据区容量（不含 -8 处 8B 长度头）
fn cir_read_snapshot(path: string) -> int
//   open(O_RDONLY) → lseek(END) 取 fsize → 复用缓冲（不足才 alloc，翻倍增长）
//   → lseek(SET) → read(fsize) → close → 写长度头 w64(buf,-8,fsize+1) → 返回 fsize
```

要点：

1. 复用缓冲：`if fsize + 1 > g_cir_read_cap { … g_cir_read_buf = alloc(new_cap + 8); … }`，峰值内存等于最大单条目，本语料为 3.99MB，不再随函数数累计。与写侧同构，写侧早有 `g_cir_write_buf/g_cir_write_cap`，在 `save_cir_cache` 中复用单缓冲。本次修复消除了“读侧是唯一逐调用新分配方”的不对称。
2. 消费面零改动：`w64(buf,-8,fsize+1)` 使 `str_len(g_cir_read_buf) == fsize`，与 `read_file` 的 `alloc(fsize+1)` 口径逐位相同。`load_cir_cache` 内既有的 `r64/str_sub` 消费面 `:438-613` 一行未改。`dlen` 只是 `str_len(data)` 的等价前置量，该行原先也没有别的语义。
3. 三态纪律，载入失败就拒绝：open 失败、`fsize<=0`（空文件或伪文件）、短读（`nread != fsize`，包括 `alloc` 耗尽导致 `buf=0` 从而 read 返回 EFAULT）、长度不足 56，统一返回 -1，表示 cache miss。调用方 `main.cr:526` 走 miss 分支，执行全量重建并重写快照。绝不把载入失败不报错地当空表。miss 是正确路径，crash 和不报错地错值都不是。
4. 为什么不用 `buf == 0` 形式做空判断，这是刻意规避，登记在第 6 节第①项：这种字符串和整型混比在 Python bootstrap 侧的 `x86_64_stack_asm.py:164` 中，`_is_string_var(left/right)` 会调用 `str_eq`，因此 `buf == 0` 被编成 `str_eq(buf,0)`，进入 `str_len(0)` 后自崩溃，与本缺陷同一栈：`load64 ← str_len ← str_eq`。前实例 `/tmp/p5t1/gdb4.log` 是旁证。read 的 EFAULT 面效果相同而且更稳，也不依赖该语言面的修复。
5. 不写盘，不升级版本：盘面零变化，`CIR_CACHE_VER` 保持 17；旧条目照常命中，身份检查语义不变。

## 4. 用例（步骤 3：新套件 19 例加 2 例可选自源）

`tests/selfhost/test_cir_warm_path.py` 是新增文件，已挂到 `src/ci/run.sh` 的 selfhost-tests，并加了计数注记。

| 组 | 例 | 判据 |
|---|---|---|
| A（7） | A1-A7 | 冷态和暖态 rc 都是 0；条目写入磁盘至少 3 条；ELF 逐字节相同；`.ccr` 按段级契约，SYM、NOD、ENT、REG、EDG、TYPE、IFACE 七段相同，STR 冷态不等于暖态是预存口径，P4 T1 已固定，暖态不重放 ir_gen 临时名的 intern；暖态真命中，条目的 size 和 mtime_ns 全等；再次暖态结果确定 |
| B（4） | B1-B4 | 多串、0 串、大串（4KB）、多函数（24） |
| C（2） | C1-C2 | 可选程序两跑产物相同，且零条目，可选面关闭缓存，本修复不牵动 |
| D（6） | D1-D6 | 累计装载复现例：416 条目补零到 3MB，合计 1.31GB，超过 1GiB 堆；暖态 rc=0；产物与冷态相同；补零条目仍然命中，未重写；峰值 RSS 为 19.9MB，小于 512MB，这是“不累计”的直接证据，修复前必然 OOM，Σ 载荷为 1.22GB |
| E（2） | E1-E2 | `COREC_WARM_SELF=1`：自源冷态和暖态 rc 都是 0，ELF 逐字节相同，真实失败态语料转为通过 |

用例自身的三态判据，包括失败态、负控和突变：

| 运行 | 命令 | 结果 |
|---|---|---|
| 基线失败态 | `COREC_BIN=/tmp/p5t0/base/corec python3 tests/selfhost/test_cir_warm_path.py` | 15 PASS / 1 FAIL，D3 rc=-11 |
| 突变失败态（本实例，第 5 节第⑨项） | 同套件，使用突变编译器 | 15 PASS / 1 FAIL，D3 rc=-11 |
| 修复后 | `python3 tests/selfhost/test_cir_warm_path.py` | 19/19 |
| 修复后加自源 | `COREC_WARM_SELF=1 python3 …` | 21/21 |

## 5. 判据（步骤 4；全部由本实例实跑，避开并发构建窗口）

| # | 判据 | 命令 | 结果 |
|---|---|---|---|
| ① | 构建 | `nice -n 19 python3 build_selfhost_native.py` | rc=0；三面 `error[` 为 0；corec `8edb967f…`，两次构建逐字节相同；corearch `493dc490…` 等于 T0 值，后端源未动；corelsp `18b94bd9…` 等于 T0 值 |
| ② | 自源 check | `./build/corec check src/compiler` | rc=0，输出 `ok`，诊断 0 |
| ③ | 后端自举 | `python3 tests/selfhost/test_backend_bootstrap.py` | rc=0，`error[` 为 0，11 项 PASS 全部通过 |
| ④ | 类型自测 | `./build/corec selftest-types` | 355/355，至少 355 达标；计数未变，本修复对类型面零扰动 |
| ⑤ | 全枚举 | `for f in tests/selfhost/test_*.py tests/bootstrap/*.py`，56 档，即 48+1 个 selfhost 加 7 个 bootstrap | 56/56 rc=0。T0 基线 55 档，增加 1 档即本任务新套件，见第 9 节计数同步 |
| ⑥ | ELF canary | `clean-cache`，然后 `build tests/suite/ptr_arith.cr -o /tmp/pa_p5t1 --static` | `95084e7bc68d6550d21d3d96fa3afd89c67a5d89edce5656a3d2e74fc923d475`，IDENTICAL |
| ⑦ | 暖态等于冷态，自源 | `clean-cache`，冷跑，然后不清缓存暖跑 2 次，命令为 `build src/compiler/main.cr -O 0` | 冷 rc=0，暖 1 rc=0，暖 2 rc=0；ELF 三跑同 sha `13230542f79da591c4ea…`，`cmp` IDENTICAL 两次；`.ccr` 全文件逐字节相同，八段冷态等于暖 1 等于暖 2；条目戳 `entries=946 stamp_sha=7b8753f93c361c5e` 三跑全等，说明 946 次装载真命中，不是退化为 miss 后重写 |
| ⑧ | 零发射面变化，跨编译器交叉证 | 冻结基线二进制冷跑同源，得到 `/tmp/p5t1b/base_self_cold` | sha 与第⑦项三跑相同，为 `13230542…`，说明基线编译器的冷产物等于修复编译器的冷态和暖态产物 |
| ⑨ | 突变控制 | M1 把 `load_cir_cache` 换回修复前的读路径，即 `read_file` 加无失败检查；重建；跑套件；精确回滚；重建 | 突变构建 rc=0，corec 为 `a49239ec…`；套件 15 PASS/1 FAIL，D3 rc=-11；回滚后 `src/compiler/cir_cache.cr` 的 sha 为 `1220742f…`，与突变前同值；重建三个二进制的 sha 逐字节回到原值，即 `8edb967f/493dc490/18b94bd9` |
| ⑩ | 自举链 | `build … -o corec2 --static -O 0`，`corearch` 放同目录，然后 corec2 用同样命令产出 corec3，再 `cmp` | 两段 rc=0；`corec2 == corec3 = 13230542f79da591c4ea…`，cmp IDENTICAL |
| ⑪ | N06 | `grep -c -F 'error[N06]' /tmp/p5t1b/chain_corec{2,3}.log` | 0 / 0 |
| ⑫ | 冒烟和 CLI 约定 | `corec3 run 'fn main()->int{return 42;}'` 和 `corec3 --help` | rc=42 和 rc=1 |
| ⑬ | CI 的 `suite` job，run_suite 逐档 | `for f in tests/suite/*.cr`，与 `run.sh:44-62` 相同：跳过 `*_mini*` 和 0 字节档，逐档 build 并运行产物 | 21 档 build 和 run 的 rc 全为 0；2 档跳过，即 0 字节的 `test_control_flow.cr` 和 `test_generics.cr`，属于 T0 第 1.2 节已登记的既有面；`at_test_mini4/6` 按既有跳过规则处理 |

五个 CI job 的覆盖关系：`check` 为①加②；`bootstrap-tests` 为枚举内的 7 档 bootstrap；`selfhost-tests` 为枚举内的 49 档 selfhost；`suite` 为⑬；`full-bootstrap` 为⑩、⑪、⑫，逐命令与 `run.sh:98-110` 相同，包含 `cp ./build/corearch` 到同目录。逐档 rc 原始记录见证据索引。

口径，继承 D28：`.ccr` 引用要带命令口径和缓存态。本报告第⑦项的 `.ccr` 是 `build … --static` 口径的冷态和暖态三态；基线失败态的 `.ccr` 不产生判据。

## 6. 登记和未决项（不不报错地）

① `string == int` 混比在本语言中不可移植。本修复绕开它，没有修它。Python bootstrap 的 `x86_64_stack_asm.py:164` 对“任一侧为 string 型 var”的 `==/!=/</…` 一律分派 `str_eq/str_cmp`，因此 `buf == 0` 被编成 `str_eq(buf, 0)`，进入 `str_len(0)` 后崩溃；自举侧，即自编译的 corec，按 int 比较。两条路径语义分歧，所以本次用 read-EFAULT 判据替代空指针判据。建议另开单项。本批边界是收尾，不改语言和编译面。旁证是前实例 `/tmp/p5t1/gdb4.log`，`load64 ← str_len ← str_eq` 崩在同一测试面。

② `g_cir_read_cap` 在 alloc 失败时仍会前进，这是良性且确定性的行为。此后每次装载走 EFAULT，返回 -1，即 miss，结果正确，可以恢复，只是变慢，绝不不报错地返回错值。这与写侧同名问题的现行口径一致，`save_cir_cache:229-235` 同形。如果日后要做到“失败即粘滞拒绝”，必须先解决第①项的空判断形态。

③ `read_file` 对伪文件 `fsize==0` 的循环回退不适用。快照始终是 `save_cir_cache` 单次 `write` 产出的常规文件；`fsize<=0` 一律判为不可用，不引入 `/proc` 式回退。

④ `.cir` 面的其余口径不动：`CIR_CACHE_VER` 保持 17，盘面零变化；身份检查、指纹检查、项槽重派生（P4 T4 裁定）逐字未动；`save_cir_cache` 未改。

⑤ 读侧内存面已经单一来源。本修复后 `.cir` 装载的驻留是单缓冲，不超过最大条目，加 `str_sub` 和 `str_intern` 拷贝；后者是有意驻留，intern 表按设计持有串指针。如果日后快照单条目超过 1GiB，当前最大为 3.99MB，仍然会 OOM，那属于“格式分片”议题，不在本任务面内，登记。

⑥ 交叉引用：TODO #43 登记面第⓪项是本缺陷首次登记，#44 交接包 D-3-9-(ii) 由本任务闭合，第 9 节已改。

## 7. 对中断实例工作区残留的核对和修正

接续时工作区为 `M src/compiler/cir_cache.cr`、`M src/ci/run.sh`、`A tests/selfhost/test_cir_warm_path.py`，`jj status` 显示父提交为 T0 `2b9b5463`。逐件核对：

| 件 | 处置 | 依据 |
|---|---|---|
| `cir_cache.cr` 修复，即 `cir_read_snapshot` 和入场改调用 | 保留。设计正确，与写侧同构，三态纪律到位；本实例没有改它的逻辑 | 第 3 节；第 5 节第⑨项的突变对照以它为基线，回滚后 sha 复原 |
| `test_cir_warm_path.py` | 保留；修正 docstring 计数，从 `22 例` 改为 `19 例（+2 ⇒ 21）`，并修正两处数字口径，从 `945 快照/1.25GB` 改为实测 `946 / 1.1674GiB` | 实跑计数 19/21，见第 4 节；数字逐条实测复核，见第 1.2 节 |
| `cir_cache.cr` 头注数字 | 保留；同上两处口径校正，从 `945/1.25GB/4.0MB` 改为 `946/1.1674GiB/3,987,879B`；`nod_s3` 三项数字实测复核成立：2,595,772B、13 节点、80,100 边 × 32B 等于 98.7% | 第 1.2 节重测 |
| `src/ci/run.sh` 挂点 | 保留。位置在 `test_cache_identity.py` 之后，计数注记为“19 例（…另开 2 例…）”，与套件一致 | 第 5 节第⑤项 |
| 发现的偏差 | 前实例 `/tmp/p5t1` 的 `chain_corec3` 段 rc≠0，原因是脚本漏拷 `corearch`，与 T0 第 1.3 节已登记的同类偏差相同，不是代码缺陷。本实例补齐后链通过 | 前实例 `chain_corec3.log` 尾部为 `/bin/sh: /tmp/p5t1/corearch: No such file or directory` |
| 校正后重建 | 上述数字和计数校正只涉及注释和文档面，重建三个二进制的 sha 逐字节回到原值，即 `8edb967f/493dc490/18b94bd9`，判据全部保持有效，见 `build_comment_only.log` | 注释零扰动实测 |

## 8. 提交

```
fix: R2 P5 Task 1——.cir 暖态 SIGSEGV 根因修复（装载侧逐函数 read_file 累计 > 1GiB 堆 ⇒ alloc 返回 0 ⇒
str_len(0) 解引用；改单一复用读缓冲、载入失败 ⇒ miss）+ 冷/暖两态产物一致回归 + 突变控制
```

路径限定：`src/compiler/cir_cache.cr`、`src/ci/run.sh`、`tests/selfhost/test_cir_warm_path.py`、计划、`TODO.md`。

## 9. 文档同步

- 计划任务 1：步骤 1 到 5 全部勾选，增加“任务 1 实施记录”段，数字与本报告一致。
- TODO #43 登记面第⓪项和 #44 交接包 D-3-9-(ii)：标为闭合，附提交号和判据指针。
- `src/ci/run.sh` 计数注记：19 例，加 2 例自源另开。
- 全枚举计数从 55 变为 56，即 48+1 个 selfhost 加 7 个 bootstrap；新增的是本任务套件。

## 10. 证据索引（`/tmp/p5t1b/`）

| 文件 | 内容 |
|---|---|
| `red_self.sh`、`base_self_{cold,warm}.log`、`base_self_gdb.log` | 第 1.1 节冻结基线的自源失败态，含 rc 和 gdb 栈 |
| `red_dprobe.log` | 第 1.3 节基线配新套件，15 PASS/1 FAIL |
| `build_final.log` | 第 5 节第①项构建，三面 GUARD 的 `error[` 为 0 |
| `crit_check_self.log`、`crit_selftest_types.log`、`crit_backend_bootstrap.log` | 第 5 节第②、③、④项 |
| `crit_canary{,_sha}.txt` | 第 5 节第⑥项 |
| `wc_{cold,warm1,warm2}.log`、`wc_stamp_after_*.txt`、`wc_elf_sha.txt`、`wc_ccr_segments.txt` | 第 5 节第⑦项暖态等于冷态，含三跑、条目戳、八段 |
| `chain_corec{2,3}.log`、`chain_shas.txt`、`chain_n06.txt` | 第 5 节第⑩、⑪项 |
| `mut_src_sha_before.txt`、`mut_bin_sha_{before,mutant}.txt`、`mut_test_red.log`、`mut_revert_build.log` | 第 5 节第⑨项突变控制 |
| `enum_results.txt`、`enum_logs/` | 第 5 节第⑤项全枚举逐档 rc，56 档全为 0 |
| `suite_job.sh`、`suite_results.txt`、`suite_logs/` | 第 5 节第⑬项 CI `suite` job 逐档 rc |

前实例证据 `/tmp/p5t1/` 只在第 3 节第 4 项和第 7 节作为旁证引用。本报告第①到⑫项判据以及第 1.1、1.3 节的失败态，都是本实例独立实跑。
