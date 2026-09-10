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
import resolve
import elf
import ld
