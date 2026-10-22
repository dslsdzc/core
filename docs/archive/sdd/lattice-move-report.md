# 语义内核目录分层：ent_kernel.cr 迁入 src/lattice/（实施报告）

日期：2026-09-10。裁决：语义内核，即格层，包含语义对象面、判定引擎、登记表、注册契约，迁到 `src/lattice/ent_kernel.cr`，与 x86 实例目录 `src/arch/linux/ld/` 分离。`src/kernel/` 是 CIC 验证内核，未触碰，jj diff 没有该目录的任何文件。

## 1. 改动清单（8 个文件，一次提交）

| 文件 | 改动 |
|---|---|
| `src/arch/linux/ld/ent_kernel.cr` 迁到 `src/lattice/ent_kernel.cr` | 纯文件移动，jj 记为 `R src/{arch/linux/ld => lattice}/ent_kernel.cr`；文件头补 3 行目录分层注记，说明格层是图、格、编码三层链的层名，附原路径和回退链解析注记 |
| `build_selfhost_native.py` | 两处 concat 路径同步：corec 表 `:149`，在 ccr_io 后；corearch 表 `:183`，在 regalloc 前。相对位置保持原样 |
| `src/compiler/module.cr` | 回退链第 6 条从 `src/arch/linux/ld/` 改为 `src/lattice/`（`:552-560`），注释改写，注明内核属于格层，含迁出日期和双侧用途 |
| `tests/selfhost/test_compile.py` | concat 清单 `:29` 路径同步 |
| `tests/selfhost/test_ent_kernel_neutrality.py` | guard 路径修正：docstring `:5` 和 `KERNEL` 常量 `:40` 改为 `src/lattice/ent_kernel.cr` |
| `tests/selfhost/test_ccr_v7.py` | `:990` 内核源码读取路径同步，用于 nod_inputs 结构定位点 |
| `src/arch/linux/ld/regalloc.cr` | `:12` 注释路径同步为 `src/lattice/ent_kernel.cr`，注明格层 |
| `tools/pseudocode_extract.py` | `ROOTS` 增加 `Path("src/lattice")`，判断项见 §3.3 |

`src/compiler/_import.cr:15` 和 `src/arch/linux/ld/_import.cr:12` 的 `import ent_kernel` 文本零改动，jj diff 未列出这两个文件。解析改由新回退条目命中，两侧均已实证，见 §2.3。

## 2. 验证证据（全部在重建后的二进制上）

### 2.1 全量重建

`rm -rf .core/cache`，然后 `nice -n 19 python3 build_selfhost_native.py`，得到 BUILD SUCCESS，rc=0。产出 `build/corec`、`build/corearch`、`build/corelsp`，全部在 13:29 重建。

### 2.2 回归面（`nice -n 19`，逐项 rc=0）

| 面 | 结果 |
|---|---|
| 中立性 guard `test_ent_kernel_neutrality.py` | `[PASS] A clean / [PASS] B clean / PASS`。路径修正后按新路径扫描；未修正前会报 `[FAIL] missing kernel file` |
| `test_ccr_v7.py` | 24/24 passed |
| `test_live_ranges.py` | 13/13 passed |
| `test_backend_bootstrap.py` | 11/11 PASS，包含 stage1/2/3 byte-identical，O2 metadata 链同样通过 |
| `test_compile.py` | 通过。native corec 编译 .cr 为可运行 ELF，Binary exit code 为 42 |
| `test_hit_table.py` | 24/24 passed |
| `test_region_cfg.py` | 22/22 passed |

### 2.3 解析实证（加载迹 `-> path` 直接证据）

- 编译器单元：`./build/corec build src/compiler/main.cr -o corec2 --static -O 0`，rc=0，轨迹包含 `-> src/lattice/ent_kernel.cr`。
- ld 实例单元，独立工程 `corec build src/arch/linux/ld`，rc=0，轨迹包含 `-> src/lattice/ent_kernel.cr`。这证明 ld 的 `_import.cr` 中 `import ent_kernel` 经新回退条目命中，不再依赖原同目录直接命中。

### 2.4 full-bootstrap guard

`corec build src/compiler/main.cr` 得到 `corec2`，`corec2 build src/compiler/main.cr` 得到 `corec3`：

- stage1 rc=0，stage2 rc=0。
- `cmp corec2 corec3` rc=0，逐字节相同。
- stage1/stage2 输出 `error[N*] = 0`，即 N06=0。逐段 grep 计数，1-680 行为 0，681-1360 行为 0。
- 冒烟：corec3 编译 `return 42` 程序，运行 rc=42。
- 注：corec2/corec3 必须与 corearch 同目录。corec 按自身可执行文件目录定位 corearch，不走 PATH。guard 命令落在 `build/`，跑完已删净，包含 .ccr 副产物。

## 3. grep 清账（`arch/linux/ld/ent_kernel` / `ld/ent_kernel`）

### 3.1 已更新（代码、构建、测试、tooling）

`build_selfhost_native.py` 两处、`src/compiler/module.cr`、`src/arch/linux/ld/regalloc.cr` 注释、`tests/selfhost/test_compile.py`、`tests/selfhost/test_ccr_v7.py`、`tests/selfhost/test_ent_kernel_neutrality.py`，含 guard 路径常量、`tools/pseudocode_extract.py`，见 §3.3。

### 3.2 有意未改（历史记录，按裁决留档）

4 个文件共 6 行，都是已完成任务的计划或设计记录，记录的是当时事实，例如“Create/Modify `src/arch/linux/ld/ent_kernel.cr`”。改写会篡改历史记录：

- `docs/superpowers/plans/2026-09-10-corearch-kernel-extraction.md` `:29` / `:58`
- `docs/superpowers/plans/2026-09-10-corearch-kernel-completion.md` `:44` / `:67` / `:87` / `:110`
- `docs/superpowers/specs/2026-09-10-corearch-kernel-completion-design.md`，只有裸文件名和 `:122` 判据叙述，没有路径限定
- `docs/superpowers/specs/2026-09-09-corearch-rewrite-design.md` `:110`

裸 `ent_kernel.cr`，不带目录的注释引用，在 globals.cr/ccr_io.cr/corearch.cr 等 10 多处，不受影响，保持有效。CI（`.github/workflows/core-ci.yml`）、`PKGBUILD`、`build_kernel.py`（CIC 内核）、`vscode-core/`、`editor/`、`spec/`、`grammar/` 都没有该路径引用。

### 3.3 判断项（超出字面 grep 命中，低风险）

`tools/pseudocode_extract.py` 的 `ROOTS` 目录清单原先包含 `src/arch/linux/ld`，内核在其中，ent_kernel 的标识符会进入术语表。迁移后如果不改，该文件会不报错地掉出提取面，因此补 `Path("src/lattice")`。该清单本身已经是旧快照，同样缺 `src/arch/hit`、`src/lsp`、`src/kernel`，未做其他扩面。

## 4. 观察和挂账（不在本次范围，未改）

1. ld 独立工程构建的 N06/N01 预警是预存问题，与本次迁移无关，已取证。`corec build src/arch/linux/ld` 报 15 次 N06 加 16 次 N01。N06 是 `HIT_EV_*` 未定义名，以及 `hit_rel_add`/`hit_ev_*` 未定义函数；引用方是 `ld/instr.cr:2257/2346`，定义方是 `src/arch/hit/lower_to_core.cr`，而 `ld/_import.cr` 只 import `hit`，从不 import `lower_to_core`。对照实验：把 src/ 复制到 /tmp，还原迁移前布局，ent_kernel.cr 放回 ld/，轨迹为 `-> src/arch/linux/ld/ent_kernel.cr`，即旧回退或同目录路径，同二进制同命令仍得到 15 次 N06 加 16 次 N01，rc 同为 0。前后逐数一致，说明是预存状态，迁移零增减。根因不在本任务范围，即 `ld/_import.cr` 导入集缺 `lower_to_core`，未动。ld 工程构建 rc=0，产物可用，`test_backend_bootstrap` 全部通过可以佐证。2026-09-10 已修，评审裁决为 must-fix，见 §6。
2. `PKGBUILD` 源安装只装 `src/compiler`/`src/stdlib`/`src/runtime`，从不装 `src/arch/linux/ld/`。迁移后 `src/lattice/` 同样不在安装面内，即“从安装树重建”的预存缺口性质不变，不是新增。未扩面。
3. `CLAUDE.md` 的“Module/Import System”只写 `g_source_dir` 到 `src/stdlib/` 再到 current directory 三段，早已不含 `src/compiler/` 和 `src/arch/hit/` 两段，属于预存陈旧。本次未动，仅注记。
4. `src/compiler/regalloc-consistency.cr` 等文件仍以 `src/arch/linux/ld/regalloc.cr` 叙述 compute_live_ranges/compute_entries 的归属，而该函数族早在内核抽取时已迁走。这是预存陈旧叙述，与本次迁移同向，但不是本次引入，未动。

## 5. 约束遵守

全程 jj，没有 git；`jj status` 只列 8 个文件，以 `R` 记录重命名。构建和测试全部 `nice -n 19`。`.core/cache` 在重建前清空。未触碰 `src/kernel/`。未做其他结构调整。

## 6. 后续修复（2026-09-10 追加）：ld 自举单元补 `import lower_to_core`

背景：§4 挂账项 1，预存 15 次 N06 加 16 次 N01，经评审裁决属于 must-fix 类，因为存在不报错地未定义和潜在垃圾发射，本次修复。与 §1 到 §5 的迁移无耦合。

### 6.1 缺陷和根因

- 现象：`nice -n 19 ./build/corec build src/arch/linux/ld -o /tmp/ldfix_before` 得到 rc=0，但构建日志有 34 行 `error[`：15 次 N06，未定义函数 `hit_rel_add`/`hit_ev_id`/`hit_ev_dst`/`hit_ev_s1`/`hit_ev_s2`/`hit_ev_flags`/`hit_pool_patch_add`/`hit_ev_map_cnt`/`hit_ev_map_start`/`hit_ev_pos_set`；16 次 N01，未定义名 `HIT_EV_SUB`/`NAND`/`LOAD` 两次/`STORE`/`JUMP` 共 6 个，加 `g_hit_pool_count` 三次 / `g_hit_ev_count` / `g_hit_inject_active` / `g_hit_rel_count` 两次 / `g_hit_ev_pos_count` / `g_hit_pool_patch_count` 两次共 10 个；另有 3 次 TA01 级联，分别是 `iv = hit_r32(...)`、`g_hit_rel_count = 0`、`g_hit_pool_patch_count = 0` 的赋值类型失配，都是未定义符号的下游，不是独立缺陷。引用方是 `ld/instr.cr` 表编码器段。
- 根因：`src/arch/linux/ld/_import.cr:9` 只 `import hit`，从不 `import lower_to_core`。未定义集恰好是 `src/arch/hit/lower_to_core.cr` 的符号全集。同类先例是 c138c44c，src/compiler 单元缺 ent_kernel，导致 N06 加 SIGSEGV。

### 6.2 修复（一次提交）

| 文件 | 改动 |
|---|---|
| `src/arch/linux/ld/_import.cr` | 在 `import hit` 后补 `import lower_to_core`，加 3 行根因注记 |
| `src/arch/hit/lower_to_core.cr` | 文件头“本文件仅进 corearch 构建清单”随修复失效，改写为“进两份构建，即 concat 清单和 ld project-mode 单元”，并注日期和根因。纯注释，无代码位移 |
| `TODO.md` | 预存 Bug 新增 #6，双入口能力分歧，见 §6.4 |

解析机制：回退链第 5 条 `src/arch/hit/` 命中（`module.cr:549`），与 `hit` 同目录、同机制，不需要新回退条目。

### 6.3 验证证据（修复后）

- `nice -n 19 ./build/corec build src/arch/linux/ld -o /tmp/ldfix_stage1` 得到 rc=0，`error[` 行数为 0，修复前为 34，N06/N01/TA01 全为 0。加载迹包含 `-> src/arch/hit/lower_to_core.cr`，修复前没有此行。另建 `--static` 版，rc=0，0 错。
- 全量重建 `nice -n 19 python3 build_selfhost_native.py` 得到 rc=0，BUILD SUCCESS。产物尺寸与修复前 13:29 的二进制完全相同：corec 1118992、corearch 984144、corelsp 737944。这与下述“concat 面零影响”一致。
- 回归，每轮先清 `.core/cache`：test_backend_bootstrap 11/11，包含 stage1 等于 stage2 等于 stage3 的逐字节同判据；test_live_ranges 13/13；test_ccr_v7 24/24；test_hit_table 24/24。全部 rc=0。
- concat 面零影响，论证：① `ld/_import.cr` 不在任何 concat 清单，唯一进入清单的 `_import.cr` 是 src/lsp；② `lower_to_core.cr` 的改动是纯注释，Python bootstrap 的 asm 后端不发射 `.loc`/`.file`/行号，`x86_64_stack_asm.py` 没有使用 `node.line`，注释行位移不进入产物。因此本次改动面只有 ld project-mode 单元一处，即修复面，不是 concat。stage 链同源重建，判据不变。

### 6.4 挂账（TODO.md 预存 Bug #6，未修）

ld project-mode 后端对 `--table` 和 `--dump-table` 报 `unknown flag`，concat corearch 正常解析。`src/arch/linux/ld/main.cr` 头注“两入口…（现 load 后行为同构）”（`:11-15`）对表模式和全部调试通道来说不成立；`ld/main.cr` 全文零处引用 `table`。机制是两份手工维护的 corearch_main 旗标注册不同步，ld `:31-36` 对 `src/compiler/corearch.cr:260-273`。修复方向和完整证据见 `TODO.md` #6。

约束：全程 jj；构建和测试全部 `nice -n 19`；每轮清 `.core/cache`；未触碰 `src/kernel/`。
