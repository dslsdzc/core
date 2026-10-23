# 任务 6 报告：syscall.cr 抽取（syscall3 和 syscall4 内置体，第 1 波最后的抽取任务）

状态：完成，全部判据通过，单提交 `wlpusnlo 94d1cac1`。

提交信息：`refactor: x86 实例化波 1 Task 6——syscall.cr 抽取（syscall3/4 内置体,Linux syscall 约定;扫描段留位加注）`。
变更规模：5 files changed，98 insertions，22 deletions。

| 文件 | 动作 |
|---|---|
| `src/os/linux/syscall.cr` | 新建，70 行：`sys_syscall3_stub`(42) 和 `sys_syscall4_stub`(60)。保留 r10 第四参注记和 I-2（wait4 rusage EFAULT）修复历史。头注说明 OS 轴定位，即 Linux syscall 约定：rax 号为系统调用号，参数顺序为 rdi、rsi、rdx、r10，指令为 `0F 05`，rax 回存；同时说明抽取纪律，cp、pos、buf 显式传递，返回新 cp，与 callseq 同一约定；另有扫描段预留位置声明 |
| `src/arch/x86_64/instr.cr` | 内置体分派链的两个分支改为调用，位置 681-688：`cp = sys_syscall3_stub(buf, pos, cp, d)` 和 `sys_syscall4_stub(...)`，各带指向注。头注 106-110 的归属同步，syscall3 和 syscall4 移出，保留 load8、store8 等 |
| `build_selfhost_native.py` | `os_linux_files` 增加 `src/os/linux/syscall.cr`，文件数从 30 变为 31，并加段注释 |
| `src/targets/x86_64-linux/_import.cr` | 增加 `import syscall`，project-mode 纳入；构建日志实证命中 `-> src/os/linux/syscall.cr` |
| `src/format/elf/elf.cr` | 内置体名索引扫描段加注，位置 877-882，代码零改动。“名字到索引”与发射面解耦；整段参数化属于第 2 波，见设计第 5.2 节 |

抽取边界：`d`，即返回值目标，随函数签名显式化。`if d >= 0 { e2_store_ret }` 的回存留在函数内，与 `cs_call_direct` 同形。发射字节逐字节保持原样。`emit_instr_tabled` 即 HIT 表路径，没有内置体分派，已核对，不在抽取边界内。

## 1. 判据结果（全部通过）

| 判据 | 结果 |
|---|---|
| 重建（清 `.core/cache`，`nice -n 19`） | BUILD SUCCESS；四段守卫全部 OK，corec 37、corearch 31、target 3、corelsp 26；`error[` 为 0，`undefined` 为 0 |
| `test_backend_bootstrap.py` | 11/11 通过，stage1 等于 stage2 等于 stage3，byte-identical；O0 和 O2 冒烟 rc=7 |
| `test_hit_table.py` | 24/24 通过 |
| `test_live_ranges.py` | 13/13 通过 |
| full-bootstrap 守卫 | `corec` 到 `corec2`，`corec2` 到 `corec3`，`corec2 == corec3` 逐字节相同，两段 `error[` 为 0 |
| 含 syscall 程序的冒烟 | probe_sys3 使用 print、println 和 read_file，syscall3 号为 1、2、0、3，rc=0，输出逐字同基线；probe_sys4 走 os.cr 的 `system()`，包括 fork、execve 和 wait4，wait4 为 syscall4 号 61，输出 `3`，rc=0，与基线相同 |
| 回归快子集 | `test_compile.py` 全部通过；`test_directory_build.py` 4/4；`test_ccr_v7.py` 24/24 |

## 2. 行为零变化证据（跨树逐字节，基线为改动前构建的工具链）

方法沿用任务 5 的先例。改动前清理并构建基线，留档 `/tmp/w1t6_corearch_base`、`/tmp/w1t6_corec_base`、编译器自身的 `.ccr`（`/tmp/w1t6/self_base.ccr`，5.4MB、550 个函数），以及探针和 suite 的 `.ccr`。改动后由同一份 `.ccr` 重新发射，再用 `cmp` 比较。

| 对照对象 | 结果 |
|---|---|
| 编译器自身 `.ccr`，550 个函数，覆盖 io.cr 和 ccr_io.cr 的 syscall3 调用 | 逐字节相同 |
| probe_sys3.ccr，覆盖 syscall3 号 1、2、0、3 全路径 | 逐字节相同 |
| probe_sys4.ccr，覆盖 syscall4 和 wait4 号 61，走第 4 参 r10 | 逐字节相同 |
| tests/suite：go_e2e、dex、ptr_arith、generics、at、chan、arena，O0 | 7/7 逐字节相同 |
| `build/corec` 二进制 | 与基线逐字节相同，corec 清单未触及，前端零变化 |
| `build/corearch` 二进制 | 按预期不同，新增两个函数导致偏移平移；阶段链自洽即为判据 |

## 3. 发现和遗留（均为已有问题或越界问题，不是本任务引入）

1. `elf.cr` 仍有三处手写 syscall 序列，不在内置体路径内：`emit_heap_expand` 的 mmap 序列，`elf.cr:460`；`emit_m_start_workers` 内两处，`elf.cr:680` 和 `:720`，属于 goroutine 和 clone 机制。本任务按任务说明“只抽发射两个函数”未动。如果第 2 波扩展 syscall.cr 的覆盖面，可以作为候选，遵守 H1 纪律，不与本次抽取混合。
2. 编译器自身的 `.ccr` 没有 syscall4 IR，因为 project import 表不包含 `src/stdlib/os.cr`。syscall4 的 byte-identical 覆盖由 probe_sys4 承担，走 os.cr 的 `system()`，已完成。
3. `tests/suite` 的部分程序构建日志带有已有 `error[`，go_e2e 2 条、ptr_arith 1 条、chan 2 条，任务 5 报告已记录同类。与本改动无关；判据套件的日志 `error[` 为 0。

## 4. 复现命令

```bash
cd /home/DslsDZC/core
rm -rf .core/cache && nice -n 19 python3 build_selfhost_native.py
nice -n 19 python3 tests/selfhost/test_backend_bootstrap.py
nice -n 19 python3 tests/selfhost/test_hit_table.py
nice -n 19 python3 tests/selfhost/test_live_ranges.py
nice -n 19 python3 tests/selfhost/test_ccr_v7.py
nice -n 19 python3 tests/selfhost/test_compile.py
nice -n 19 build/corec build src/compiler/main.cr -o build/w1t6_corec2 --static -O 0
nice -n 19 build/w1t6_corec2 build src/compiler/main.cr -o build/w1t6_corec3 --static -O 0
cmp build/w1t6_corec2 build/w1t6_corec3 && rm -f build/w1t6_corec2* build/w1t6_corec3*
# syscall 冒烟（探针源码 /tmp/w1t6/probe_sys3.cr、probe_sys4.cr）
nice -n 19 build/corec build /tmp/w1t6/probe_sys3.cr -o /tmp/w1t6/p3_new --static -O 0 && /tmp/w1t6/p3_new; echo rc=$?
```

证据留在仓库外，评审后可以清理：`/tmp/w1t6_corearch_base`、`/tmp/w1t6_corec_base`、`/tmp/w1t6/`，内含 self_base.ccr 基线、探针、batch suite 的 `.ccr` 和 ELF；还有 `/tmp/w1t6_{base,new}_build.log`。
