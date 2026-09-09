// _import.cr — imports for the corearch backend project
import cli
import fmt
import io
import toml
import ast
import globals
import dyn_arr
import hit
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
