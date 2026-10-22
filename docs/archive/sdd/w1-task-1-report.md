# x86 实例化波 1 Task 1，三轴搬迁 + 组合根 + 清单分段守卫（实施报告）

日期：2026-09-10 ｜ 提交：`29d177ac`（change `ppmykoko`，28 文件，一提交）｜
性质：纯搬移（零抽取） ｜ 判据：行为零变化（stage 链 run 内
byte-identical + 判据套件全绿 + 产物级 byte 证据）

裁决：三轴目录（架构 `src/arch/x86_64/` × 格式 `src/format/elf/` × OS `src/os/linux/`）
落位 + 组合根 `src/targets/x86_64-linux/`（target triple 命名）+ `module.cr` 回退链跨轴
通道 + `build_selfhost_native.py` 清单分段（按轴命名组合）+ 双守卫（存在性 / 构建日志诊断）。
未做任何函数抽取（frame/callseq/tag2l/syscall 留 Task 2-6）。

## 1. 改动清单（28 文件，一提交）

### 1.1 搬迁（10 文件，jj 记 `R`）

| 自 | 至 | 轴 |
|---|---|---|
| `src/arch/linux/ld/{elf.cr,resolve.cr,ld.cr}` | `src/format/elf/` | ② 格式轴 |
| `src/arch/linux/ld/{instr.cr,sizes.cr,regalloc.cr}` | `src/arch/x86_64/` | ① 架构轴 |
| `src/arch/hit/core-x86.toml` | `src/arch/x86_64/core-x86.toml` | 表数据归架构轴（引擎 hit.cr/lower_to_core.cr 留原位） |
| `src/arch/linux/ld/{main.cr,_import.cr,Core.toml}` | `src/targets/x86_64-linux/` | 组合根（main.cr + _import.cr 同目录） |

`src/arch/linux/` 迁空后删除（`rmdir`）。新增 `src/os/linux/.gitkeep`（OS 轴目录占位，
jj/git 不追踪空目录；Task 2+ 落 entry/callseq/syscall）。

### 1.2 接线

| 文件 | 改动 |
|---|---|
| `tests/selfhost/test_backend_bootstrap.py:13` | `BACKEND_SOURCE` 改为指向组合根（先改后搬，H6）+ 2 行注释 |
| `src/compiler/module.cr` | 回退链 +4 条（21 行注释 + 4 块；置放序见 第2.1/第2.2）；`ent_kernel`/实例单元注记措辞同步 |
| `build_selfhost_native.py` | corearch 6 行路径改 + 清单分段（`common_files`/`hit_engine_files`/`kernel_files`/`arch_x86_64_files`/`format_elf_files`/`os_linux_files`/`backend_support_files`/`x86_linux_target_files`）+ 守卫①②；corec/corelsp 清单提取为具名列表（顺序逐一保持）；`compile_and_assemble` 拆出 `emit()`；stdout `_LogTee` 分流供守卫扫描 |
| `tests/selfhost/test_hit_table.py:28` | `TABLE` 改为指向 `src/arch/x86_64/core-x86.toml`（HIT_SRC/LOWER_SRC :29/:30 不变） |
| `tools/pseudocode_extract.py:6-9` | `ROOTS`：删 `src/arch/linux/ld`，增三轴 + 组合根四目录 |
| 注释同步（13 处） | `src/arch/x86_64/instr.cr:2189`（表路径）、`src/arch/hit/hit.cr:2-4`、`src/arch/hit/lower_to_core.cr:27,42`、`src/stdlib/toml.cr:163`、`src/arch/x86_64/regalloc.cr:1,864`、`src/format/elf/ld.cr:1`、`src/targets/x86_64-linux/main.cr:1,6,12,15`（H7：仅措辞同步，未做 flag 收敛）、`src/compiler/ccr_io.cr:850`、`src/compiler/main.cr:494`、`src/compiler/opt.cr:3,309`、`src/compiler/regalloc-consistency.cr:33,64`、`src/lattice/ent_kernel.cr:11`、`tests/selfhost/test_mw_task{1,2,3,4}.py:4` |

搬迁文件内容 verbatim（jj diff 逐块核：仅上述注释行；`core-x86.toml`/`sizes.cr`/
`elf.cr`/`resolve.cr`/`Core.toml`/`_import.cr` 零行改动）。

## 2. 判定项与偏差（两处偏离 brief 字面，均为 root cause 修复）

### 2.1 三轴目录置于 `src/compiler/` 之前（brief 原文：追加于 `src/lattice` 之后）

根因：`src/compiler/elf.cr`（566 行留守遗留文件）是一个同名遮蔽源，`src/format/elf/elf.cr`
迁出同目录后，若轴目录晚于 `src/compiler/` 命中，`import elf` 会命中该遗留文件。实证
（决定性）：把 `src/format/elf/elf.cr` 从 /tmp 副本移除后以同 corec 构建目标单元，加载迹
第 21 行为 `-> src/compiler/elf.cr`，构建 rc=1（`error: Unexpected token in expression`），
即 brief 原置放序会选中同一文件、同样失败。该遗留文件 = 零 importer + 不入任何 concat 清单
（grep 实证）到 属预存 landmine，本次由其暴露。

置放序（最终）：`g_source_dir 到 src/stdlib 到 src/runtime 到 src/format/elf 到 src/arch/x86_64
到 src/os/linux 到 src/compiler 到 src/arch/hit 到 src/lattice 到 src/targets/x86_64-linux 到 cwd`。

「既有条目命中不漂」核验：三轴目录为新建，其文件名（instr/sizes/regalloc/elf/resolve/ld）在
前三级（g_source_dir / src/stdlib / src/runtime）无同名文件；既有 `src/compiler/elf.cr`
命中面无 importer（全仓 `import elf` 仅一处 = 目标单元 `_import.cr`，原先靠同目录命中）。

### 2.2 组合根条目置于 `src/lattice` 之后（按 brief 原序）

根因：该目录含 `main.cr`/`_import.cr`，而 `src/compiler/_import.cr` 有 `import main` /
`import entry`，组合根目录前置会遮蔽这两条既有命中。组合根条目对目标单元本身是冗余面
（其 main.cr/_import.cr 由 `load_project`/`load_imports` 直读，非 import 目标），故后置零损失。

### 2.3 `x86_linux_target_files` 不入 concat

`main.cr` 的 `fn main` 与 concat 追加的 wrapper 冲突（corearch 入口仍是 `src/compiler/corearch.cr`）
到 该段只纳入存在性守卫（main.cr/_import.cr/Core.toml 三件），并注释说明。

### 2.4 守卫②加宽（超出字面 `error[` 单一 marker）

Python bootstrap 面诊断不带 `error[` 前缀（`error[` 仅由 self-hosted corec `diag.cr:134`
发射；baseline 日志实证 0 命中），单 marker 守卫在该路径上结构恒 0 = 空转。故守卫②同时计数
bootstrap 侧等价未定义符号面（`Undefined name:` / `Undefined function`），正是 TODO #6 ③
要抓的 N06/N01 不报错地类。当前两 path 均 0/0。守卫自测口已实证（见 第3.4）。

## 3. 验证证据（全部在重建后的二进制上；每轮先清 `.core/cache`；全部 `nice -n 19`）

### 3.1 构建

- baseline（改动前）：BUILD SUCCESS，corec 1118992 / corearch 984144 / corelsp 737944 B，`error[` = 0。
- 改动后：BUILD SUCCESS（rc=0）；守卫输出 `corec: manifest OK (37 files)` /
  `corearch: manifest OK (26 files)` / `x86_64-linux target: manifest OK (3 files)` /
  `corelsp: manifest OK (26 files)` + 三段 `build log clean (error[ = 0, undefined = 0)`。
  尺寸 corec 1123376 / corearch 984144（与 baseline 同） / corelsp 738232。
  （corec/corelsp 变化 = `module.cr` 入其 concat，真实代码改动；corearch 面 = 纯注释。）

### 3.2 产物级零变化证据（纯搬移证明）

| 证据 | 结果 |
|---|---|
| corearch concat token 流（父修订清单+父修订文件内容 vs 新分段） | 完全一致（119174 tokens），注释零语义 |
| concat 段序（AST 提取逐一比对） | corearch：新组合 == 旧顺序（仅 6 条路径改名）；corec 37 / corelsp 26 清单逐条相同 |
| 目标单元 `.ccr`（旧布局 /tmp 树 vs 新布局，同 corec 同 flags） | byte-identical（2075886 B，sha256 `833a1e40…f21486` 同） |
| 目标单元加载迹 diff | 差异 恰为 6 条搬迁路径（19 条 `-> src/` 不变），无其他解析变化 |

### 3.3 判据套件（逐项 rc=0）

| 面 | 结果 |
|---|---|
| `test_backend_bootstrap.py` | 11/11 PASS，含 stage1==stage2==stage3 byte-identical + O2 metadata 链 smoke |
| `test_hit_table.py` | 24/24 passed（表路径改点后） |
| `test_compile.py` | PASS（`Binary exit code: 42`） |
| `test_live_ranges.py` | 13/13 passed |
| `test_ccr_v7.py` | 24/24 passed |
| `test_region_cfg.py`（加测，plan Task 7 面） | 22/22 passed |
| full-bootstrap guard | stage1 rc=0 / stage2 rc=0；`error[` = 0 / 0；`cmp corec2 corec3` rc=0；corec2/3 及 .ccr 副产物已删净 |
| `tools/pseudocode_extract.py` | 运行正常（1347 词条，新轴目录标识符已纳入） |

判据命令注记：full-bootstrap guard 须带 `--static`（默认动态产物缺 `core_rt.so` 时 exec 报
rc=127 = 链接面而非解析面，与本次改动无关），记录为 `corec build src/compiler/main.cr
-o build/corec2 --static -O 0` 及其二阶段。

### 3.4 守卫生效实证（非空转）

对 `guard_build_log`/`guard_manifest` 注入探针：`error[…]` 行 到 `exit=1`；`Undefined name:`
到 `exit=1`；清单缺失 到 `exit=1`；clean 日志 到 `[GUARD] … clean`。

## 4. grep 清账

- `grep -rn "arch/linux" src tests tools build_selfhost_native.py` 到 空（活代码全清）。
- 非 `.md` 面（`*.py`/`*.cr`/`*.sh`/`*.yml`）全仓再无该串；CI workflow / PKGBUILD / `src/kernel/`
  无该路径引用。
- 有意未改（brief 明示 `.md` = docs 留档 + Task 7「文档同步」面）：`CLAUDE.md:160,165`
  （现为陈旧结构描述，建议 Task 7 一并更新）、`TODO.md:25,26,130,131,135,288`（含 #6 挂账原文，
  Task 7 同步）、`CHANGELOG.md:260`，及 `docs/`（compcert-reference / ir-op-semantics /
  numeric-migration-inventory / crasm / project-book / pseudocode 对照表 / plans / specs），
  均为当时事实记录，改写会篡改历史。

## 5. 约束遵守

jj 全程（`jj status` 28 文件；`R` 记名重命名 10 处）；构建/测试全部 `nice -n 19`；每轮清
`.core/cache`；未触碰 `src/kernel/`；未做 flag 收敛（H7）；无函数抽取、无文件内容改写
（除注释同步）；未使用 git。

## 6. 挂账与需评审确认项

1. `src/compiler/elf.cr` 遗留死文件（566 行，零 importer，不入 concat），预存 landmine，
   本次因其暴露（第2.1）。当前由回退链序保证正确命中；建议后续波次清理或加「deleted/legacy」注记
   （非本任务范围，删文件需用户许可）。
2. 回退链序偏离 brief 两处（第2.1/第2.2），请评审确认该 root-fix 与 brief 意图一致
   （brief 的「置放序保持既有命中不漂」意图已逐条核验满足，见 第2.1 末段）。
3. `build/corearch` 尺寸与 token 流双证零变化，但 corec/corelsp 因 `module.cr` 入 concat
   而变化，属预期（回退链是本次唯一实代码改动）。
4. 文档面（CLAUDE.md/TODO.md 结构描述）仍为旧目录，Task 7 文档清账面。
5. `.gitkeep` 为新 OS 轴目录占位；Task 2 落 `entry.cr` 后可删。
6. 本次未跑 mw1-6 / slice_bounds / bootstrap 三套全量（Task 1 判据为快子集；Task 7 收官全量）。
   已加测 `test_region_cfg`（22/22）佐证。

---

# 补正：wave1 Task 1 评审 Important finding 修复（project-mode 构建 error 门）

日期：2026-09-10 ｜ 提交：`c927525b`（change `ukpvmtss`，4 文件，一提交）｜
finding（评审经验性复现）：守卫② 只见 Python-bootstrap concat 构建日志，看不见
self-hosted corec 的 project-mode 构建（TODO #6 ③ 的真正事发层）；且
`test_backend_bootstrap.py` 的 `run_checked` 仅以 returncode 判定 到 不报错地未定义
（`error[N06]`）+ rc=0 + 产物正常 + 互测 byte-identical 全通过。

## A. 修复（4 处，选项 (a)：在事发层闭合）

| # | 文件 | 改动 |
|---|---|---|
| 1 | `tests/selfhost/test_backend_bootstrap.py:17-45`（`run_checked`） | rc==0 时扫 stdout+stderr 合并 的 `error[` 行；命中 到 `[FAIL]` + 打印违规行（≤40 行）+ 返回 False。事发层闭合，stage 链全部经此函数（stage0 `corec build <组合根>` 即被评的 project-mode 面；后续 Task 2-6 改 import 集即过此门） |
| 2 | `build_selfhost_native.py:135-156`（守卫② 注释 + `guard_build_log` docstring） | 措辞对齐现实：本门 = bootstrap-concat 日志门（计数面 = `error[` + 加宽未定义标记 `Undefined name:`/`Undefined function`，作用域 = `compile_and_assemble` 的 `_LogTee` 缓冲）；明写 project-mode 面不经此路径、交叉引用 `run_checked`（两门互补，改一须同步另一）；删除原「TODO #6 建议③实施」的越界表述 |
| 3 | `CLAUDE.md:160-169` | `### ELF Backend (src/arch/linux/ld/)` + 旧平铺树 到 三轴布局（`src/arch/x86_64/` × `src/format/elf/` × `src/os/linux/`）+ 组合根 `src/targets/x86_64-linux/`，逐轴列文件与职责（Task 2-6 的基线） |
| 4 | `TODO.md:138-142` | 新 #7：死文件 `src/compiler/elf.cr`（566 行 / 零 importer / 不入清单），遮蔽隐患（`w8/w16/w32/w64` 撞 dyn_arr.cr；`elf_*` 面撞 `src/format/elf/elf.cr`）+ `module.cr:544-553` 顺序保护 = 顺序依赖而非结构保证 + pseudocode ROOTS 整目录 glob 致 `标识符对照表.md` 20 行归属误导；修复方向 = 删除（需用户许可，铁律 #3）/ 迁出活树 |

## B. 探针实证（自测齿；/tmp 一次性工程，已清理）

探针工程：`/tmp/w1t1-probe/{Core.toml, main.cr}`，`main.cr` =
`fn main() -> int { return undefined_fn_xyz(); }`（调用未定义函数）。

| 阶段 | 命令 | 观察 |
|---|---|---|
| BEFORE（修复前 rc-only 逻辑） | `nice -n 19 ./build/corec build /tmp/w1t1-probe -o …/out --static -O 0` | rc=0；日志含 `error[N06]: Undefined function 'undefined_fn_xyz'`（本例落 stdout；评审记为 stderr，流口径差异，合并扫描两者兼容）；ELF 照常产出 28822 B 到 旧 `run_checked` 判 [PASS]（复算脚本：`rc=0 -> PASS ; error[ lines = 1`） |
| AFTER（修复后 `run_checked`，直接调用、未改套件） | `run_checked([COREC, 'build', '/tmp/w1t1-probe', …])` | `[FAIL] PROBE project-mode build w/ undefined_fn_xyz: exit 0 but build log carries 1 error[ diagnostic line(s):` + `  error[N06]: Undefined function 'undefined_fn_xyz'` 到 helper 返回 False；同次 ELF 仍产出 28822 B，证明产物存在不可作判据 |

守卫② concat 面非空转复核（注释改动后复跑）：clean 日志 到 `[GUARD] … clean`；
注入 `error[N06]` 到 `[GUARD FAIL]` + `SystemExit 1`。

## C. 判据（全 rc=0）

| 命令 | 结果 |
|---|---|
| `nice -n 19 python3 tests/selfhost/test_backend_bootstrap.py`（先清 `.core/cache`） | 11/11 PASS，suite rc=0，零假阳性；含 O2 metadata 链两阶段与 stage1==stage2==stage3 byte-identical |
| `nice -n 19 python3 tests/selfhost/test_hit_table.py` | 24/24 passed |
| `python3 -m py_compile build_selfhost_native.py tests/selfhost/test_backend_bootstrap.py` | OK |

假阳性风险面已实测覆盖：stage0 的目标单元 project-mode 构建输出、stage1/2 的 .ccr
消费输出、O2 metadata 输出均不含 `error[`，11/11 保持绿。

## D. 约束与注记

- jj 全程（`jj commit`，未用 git）；构建/测试全部 `nice -n 19`；每轮清 `.core/cache`；
  /tmp 探针目录已删除。
- 超 brief 字面的最小必要扩展：CLAUDE.md 除标题行/路径行外，代码限制 5 行条目一并重写
  （否则三轴标题下仍挂着已不存在的 `src/arch/linux/ld/` 条目 = 新误导源）；未重构其他小节。
- 同类残留（本次未改，建议后续波次或 Task 7 收口）：`test_mw_task2.py:169`、
  `test_compile.py:127`、`test_live_ranges.py:52,73` 等驱动仍为 rc-only 判定，文件模式构建
  同属「rc=0 + `error[` 不报错地」类。本次按 finding 范围只闭合 project-mode 事发层
  （test_backend_bootstrap 的 stage 链）。
