// _import.cr — imports for the corearch backend project
import cli
import fmt
import io
import toml
import ast
import globals
import dyn_arr
import hit
// 降低层（HIT M2）：instr.cr 的表编码器消费 lower_to_core.cr 的事件流
// （hit_rel_add/hit_ev_*/hit_pool_patch_add/HIT_EV_*/g_hit_*）——本文件原先只
// import hit 而漏 lower_to_core，致 ld project-mode 单元 15×N06+16×N01 静默未
// 定义（含 TA01 级联；与 c138c44c「compiler 单元缺 ent_kernel」同类）。经
// src/arch/hit/ 跨树回退命中（与 hit 同机制、同目录）。
import lower_to_core
import monomorph
import ccr_io
import ent_kernel
// 内核完备 Task 1（调度重建移实例）：build_linear_schedule（regalloc.cr——
// 实例侧调度重建）须进自举 stage 链编译集——本文件（自举 project 入口
// main.cr 的共享导入）与 build_selfhost_native.py corearch concat 双注册
// （regalloc 原 = concat 独有；main.cr 的 load 后调用依赖本导入）。
import regalloc
import sizes
import instr
// 架构轴 frame（x86 实例化波 1 Task 3 落位）：函数帧单源——pf_frame_size
// （Phase 2 dry-run 与 Phase 3 sub rsp 立即数共用）+ pf_prologue/pf_epilogue
// （帧发射序自 format/elf/elf.cr 抽出）+ g2_tag_off（自 instr.cr 迁入，H3）。
// project-mode 单元须经本清单收编（回退链命中 src/arch/x86_64/；concat 面 =
// arch_x86_64_files）。
import frame
import resolve
import elf
import ld
// OS 轴（x86 实例化波 1 Task 2 落位）：_start 发射序 emit_start/emit_start_size
// 自 format/elf/elf.cr 整函数迁 src/os/linux/entry.cr——elf.cr 的调用点跨轴引它，
// project-mode 单元须经本清单收编（回退链命中 src/os/linux/；concat 面 = os_linux_files）。
import entry
