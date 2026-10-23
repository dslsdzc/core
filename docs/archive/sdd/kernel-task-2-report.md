# Task 2 报告：写侧单源化，消除 compute_entries_v7 镜像

状态：完成（提交 edc70fbe，工作副本干净）

## 迁移（Step 1，Task 1 评审 Important 携带事项）

ir_op_kind_name（regalloc.cr :17-54，注释 3 行加函数体 35 行）迁移到 ent_kernel.cr，放在 dump_entries_summary 区头之前。依据已核实：唯一调用方是内核的 dump_entries_summary（ent_kernel.cr :309 区，跨文件互调），regalloc.cr（机器侧）没有剩余使用。注释和函数体逐字迁移，前面加 2 行出处注记。

RPT_MAX（regalloc.cr :71-77，seam 注记 6 行加声明 1 行）迁移到 ent_kernel.cr，放在 LOC_HOME_BASE 上方。依据已核实：唯一使用方是内核的 rl_rule2_func（:630）和 verify_regalloc_consistency（:708），机器侧没有剩余使用。声明行逐字迁移（含行尾注释），前面加 3 行出处注记。regalloc.cr 原来的“判定 seam 常量注记”整块删除，因为其内容描述的是搬移前状态，注记中预告的迁入已经完成。

## 写侧重接（Step 2）和镜像删除（Step 3）

- save_ccr 直接调用内核：首步 `compute_entries_v7();` 改为 `compute_live_ranges();`（内核函数，尾部逐函数内调 compute_entries，func_i==0 分支整表重置）。调用点位置不变，仍在 EDG 收集之前。
- 删除内容（ccr_io.cr 从 1529 行降到 1372 行）：compute_entries_v7 的区头注释和函数体（:435-579，含局部 16B lr 表机制），以及 ccr_grow_entries/ccr_grow_func_entry_meta（:418-433）。
- 按实际引用保留（controller ruling 3）：ccr_ent_* 访问器（写侧 ENT 写点、REG 区内范围、ccr_param_entry_id 引用）、ccr_param_entry_id（save_ccr 的 SYM func param_ents 回填）。
- loader 收编内核 grow：ccr_grow_* 的 loader 引用（load_ccr ENT 载入 :1417/:1452）改为调用内核 grow_entries/grow_func_entry_meta。函数体与原本地副本逐字节同源，语义零变化。随后 ccr_grow_* 才真正成为死代码并删除，grow 收敛为单实例。
- 半开转换保留：ENT 写点的 live_end+1（原 :867 处）未改动。

差异消解在三处实施：① 表实现方式从局部 lr 改为内核全局 g_ir_live_ranges（corec 侧 globals 零态，首次调用时 grow-on-demand 自举，与 corearch 路径相同）；② 整表重置改为内核 compute_entries 的 func_i==0 分支（镜像原先在函数头清零，现在统一为内核语义）；③ grow 单实例，见上。

## 定位点点变化

计划中的行定位点相对 Task 1 之后的文件普遍偏旧：ir_op_kind_name 现在位于 :20（计划注为“约 :278”），RPT_MAX 现在位于 :77（计划注为“was :487”，Task 1 之后 regalloc.cr 已缩到 844 行）。按计划指示，按名称定位迁移，内容没有歧义。ccr_io.cr 各定位点（compute_entries_v7 :458-579、ccr_grow_* :419-433、写点 :611、ccr_param_entry_id :584-593、ccr_ent_* :411-416）与文件现状全部吻合。

## 行为判据证据

- 基线（Task 1 状态）：test_ccr_v7.py 23/23 PASS（先跑并记录）。
- 改动后：test_ccr_v7.py 23/23 PASS（包含 ENT 手算期望、独立模型 replay、loader 校验、roundtrip，镜像消除后产物 byte-identical 无损）；test_live_ranges.py 13/13 PASS（corearch 侧未改动）。
- 回归子集：test_compile PASS（见下文“回归发现”）；test_backend_bootstrap 全链 PASS（stage1/2/3 byte-identical，smoke 3 次，O2 smoke 2 次）；test_hit_table 24/24；test_region_cfg 22/22。
- 构建 3 次（迁移后、重接后、修复后）：build_selfhost_native.py 全部通过（corec/corearch/corelsp）。

## 回归发现（测试暴露问题，修复根因，没有绕过）

backend_bootstrap（stage1 发射 stage2 时段错误 139）和 test_compile（Undefined name: compute_live_ranges/grow_entries/grow_func_entry_meta）双双失败。用两段隔离做实证（jj workspace 基线加变体构建）：
- 基线（Task 1）全链通过；变体 V2（只做迁移，ent_kernel 进入 corec concat）通过；变体 V3/V4（任何 ccr_io 对内核的引用）失败。触发点是 ccr_io 引用内核函数。
- 根因：`corec build <dir>` 的编译单元由目录 main.cr、_import.cr 闭包和传递 import 组成（load_project/module.cr）。ent_kernel.cr 不在 src/arch/linux/ld 项目的 import 闭包内，没有被任何文件 import。test_compile.py 自有的 concat_sources() 也不含 ent_kernel.cr。ccr_io.cr 引用内核函数后，两个自编译单元出现 N06 Undefined function。自举诊断 F19 非致命，仍会产出二进制，但调用点发射成垃圾，运行期 SIGSEGV。基线日志也有 N01 HIT_EV_* 噪声，来自 hit.cr 死路径，是有害性为零的先例。
- 修复直接针对根因：① src/arch/linux/ld/_import.cr 增加 `import ent_kernel`，把内核收进 ld 项目闭包，用于该目录项目的自编译链；② tests/selfhost/test_compile.py 的 concat_sources() 增加 'src/arch/linux/ld/ent_kernel.cr'，镜像 build_selfhost_native.py 的 corec concat。
- 修复后两个测试全部通过（证据见上）。concat 构建的二进制不受 _import.cr 影响（import 行会被剥离），无需重建。修复只涉及自编译单元的组成。

## 文件改动

- src/arch/linux/ld/regalloc.cr（减少 49 行：ir_op_kind_name 注释和函数、seam 注记加 RPT_MAX 删除）
- src/arch/linux/ld/ent_kernel.cr（增加 46 行：两个声明迁入加出处注记）
- src/compiler/ccr_io.cr（净减少 157 行：镜像机械删除、save_ccr 直调内核、loader 收编内核 grow、6 处注释刷新。头注 ENT 描述、accessor 注、回填注记不再指向已删除的镜像）
- build_selfhost_native.py（增加 1 行：corec concat 加 ent_kernel.cr，位于 ccr_io.cr 之后）
- src/arch/linux/ld/_import.cr（增加 1 行：import ent_kernel，修复自编译单元组成）
- tests/selfhost/test_compile.py（增加 2 行、删除 2 行：concat_sources 加 ent_kernel.cr，原因同上）

## 自检（verification by construction）

- 迁移和删除经过分片脚本的行断言，固定行内容校验，错位即中止；两轮误触发都没有写盘，因为 assert 在 write 之前。
- 全文件残留扫描：compute_entries_v7/ccr_grow_* 零代码引用，只剩文档注记。
- 内核函数名与 corec concat 其余文件零同名冲突（已预先 grep 验证）；双进程同内核，ent_kernel.cr 进入双 concat。
- 行为判据双通道和回归子集全部通过（证据见上）；修复经过变体两段隔离实证（V1 通过，V4 失败，修复后通过）。

## 自评

零语义改动达成，test_ccr_v7 的字节判据和 live_ranges 13/13 双重证明。回归发现是自编译单元组成缺口（ccr_io 新增对 ent_kernel 的依赖），通过修复单元组成直接解决，遵循铁律 #1，没有弯曲判据，也没有回退 loader 引用。纪律方面：ccr_ent_*/ccr_param_entry_id 按 ruling 3 保留；没有顺手做接口抽象；注释只刷新了指向已删除镜像的 6 处。计划中的风险注记已经兑现：计划说“ccr_io 内残留同名函数删除完整性以构建和测试判定”，除了构建通过和测试通过，自编译链（backend_bootstrap/test_compile）是此前未列出的全单元面，已经补上。

---

## Task 2 评审补漏（full-bootstrap 面）：src/compiler 自编译单元 import ent_kernel

问题复现：`./build/corec build src/compiler/main.cr -o /tmp/corec2_pre --static -O 0` 输出 3 条非致命 `error[N06]: Undefined function 'compute_live_ranges'/'grow_entries'/'grow_func_entry_meta'`，产物 /tmp/corec2_pre 在 ENT save（"save .ccr..."）时段错误，exit 139，与评审描述逐字一致。根因是 Task 2 的修复只覆盖了 ld 项目的自编译单元（ld/_import.cr、concat 清单、test_compile 的 concat_sources），corec 链（src/compiler 单源）的同型缺口没有闭合。

import 解析机制的实证（module.cr 的 res_imports，修复前先验证作用域）：
- ent_kernel 从 ld 根解析：g_source_dir = src/arch/linux/ld，同目录直接命中（ld/_import.cr:12）。
- ccr_io 从 ld 根跨树解析：module.cr 硬编码的回退链为 g_source_dir、src/stdlib、src/runtime、src/compiler、src/arch/hit、cwd，src/compiler/ccr_io.cr 命中。同一条链（src/arch/hit 条目是 b67f7f53a7bc 表驱动发射时按同样需要加入的先例）没有 src/arch/linux/ld 条目，所以 src/compiler 单源 import ent_kernel 落空（"import fail" 加 N06）。
- @project 机制（src/<project>/Core.toml 按目录名）和 :: 路径展开都无法到达 src/arch/linux/ld（目录名不等于项目名 corearch）。机制本身无法从 src/compiler 触达该目录，因此按既定模式扩展回退链，镜像 src/compiler 的 src/arch/hit 条目。这不是路径 hack：ent_kernel 与 globals/ccr_io 同为双 concat 共享文件，其目录进入回退链后，共享文件就能被任意编译单元 import，这是既有不变量。

修复（根因）：
1. src/compiler/_import.cr：在 ccr_io 后增加 `import ent_kernel`，镜像 ld/_import.cr:11-12 的顺序。
2. src/compiler/module.cr 的 res_imports 回退链：在 src/arch/hit 后增加 `src/arch/linux/ld/` 条目，并加注释。这是纯增量，编译单元目前没有任何落空 import（实证：修复前日志 0 条 "import fail"），既有解析行为零变化。
3. src/compiler/globals.cr:63-78 的条目表头注同步。ent_kernel 进入双 concat 后，corec 写侧经内核计算。原来有五处指向过时内容：“填充方 = corearch 侧 regalloc.cr，corec 不再计算”“grow_live_ranges 在 opt.cr”“见 opt.cr live_range_slot”“见 opt.cr ent_* 注记”“D-1=Y 后 ENT 恒空”，现在改为 ent_kernel.cr 和 v7 实记录。
4. 计划 docs/superpowers/plans/2026-09-10-corearch-kernel-extraction.md：Task 4 的 Test 行和 Global Constraints 回归面行补上 full-bootstrap stage（src/compiler 单源自编译单元包含内核的保护性断言）。

命令和证据（全部 nice -n 19）：
- 修复后 full-bootstrap 两段链：stage1 `./build/corec build src/compiler/main.cr -o /tmp/corec2 --static -O 0` 得到 exit 0，N06 计数 0，import 迹为 `-> src/arch/linux/ld/ent_kernel.cr`；stage2 用 corec2 复建 corec3，exit 0，N06 为 0；`cmp /tmp/corec2 /tmp/corec3` 结果为 0（byte-identical）。前置 concat 重建 `python3 build_selfhost_native.py` 通过（module.cr 进入 corec/corelsp concat，_import.cr 不进入 concat）。
- /tmp/corec2 冒烟（修复前 exit 139 的 ENT save 点）：`ccr /tmp/ent_smoke.cr` 得到 exit 0（85939B .ccr 落盘）；`build ... --static -O 0` 得到 ELF，运行 exit 42（main 返回值）；两份日志的 N06 均为 0。
- 回归：test_ccr_v7.py 23/23 PASS（ENT 实记录产物判据未动）；test_live_ranges.py 13/13 PASS；test_backend_bootstrap（ld 目录自编译链，module.cr 回退链增量的直接消费面）11/11 PASS，stage1/2/3 byte-identical（exit 0，回退链增量零干扰实证）。
- 行为判据：回退链条目是纯增量，目前没有落空 import，因此其余单元的解析路径逐位不变。

文件改动：
- src/compiler/_import.cr（增加 1 行：import ent_kernel）
- src/compiler/module.cr（增加 6 行：回退链 src/arch/linux/ld 条目加注释）
- src/compiler/globals.cr（净变化为减少 5 行、增加 5 行：表头注五处指向同步）
- docs/superpowers/plans/2026-09-10-corearch-kernel-extraction.md（增加 2 行：Task 4 Test 和 GC 回归面行）
