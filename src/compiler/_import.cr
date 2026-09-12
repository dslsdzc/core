// _import.cr — imports applied to all .cr files in src/compiler/
// Backend files in subdirectories use :: as path separator.
// Legacy ASM backend removed — ELF pipeline is the only path.
import cli
import ast
import globals
import dyn_arr
import lexer
import parser
import checker
import type_terms
import type_engine
// R2 P2b Task 1：本质条目表 + iface_* 查询 API（静态数据表；置于引擎之后、桥接层之前
// ——Task 2 起桥接层（ty_shadow.cr）委托本层，故顺序必须是 引擎 → 注册表 → 影子层）。
import iface_registry
// R2 P4 Task 0：引擎核纯化拆分——iface 满足判定簇 + `iface_kind_of` 移入 corec-only 的
// iface_axis.cr（type_engine.cr 留纯核、iface_registry.cr 除该函数）。**project-mode 面必须
// 同列本行**：src/compiler 目录的文件集 = 本清单（无目录自动发现，仅 import 收编）——
// 漏列 ⇒ corec2/corec3 自举链上 iface_kind_of/iface_satisfies 全族 `error[N06]` 静默未定义
// （rc=0 + 产物照出，B.6 同族）。corearch 清单（src/targets/x86_64-linux/_import.cr）**不列**
// 本文件与引擎簇（本任务不动该文件）。
import iface_axis
import ty_shadow
import type_selftest
import purity_selftest
import diag
import ir_gen
import dataflow
import ccr_io
import ent_kernel
import module
import toml
import project
import os
import fmt
import io
import interp
import dump
import monomorph
import cir_cache
import ext_mgr
import ext_safety
import pass
import opt
import ptr_analysis
import region_check
import provenance_verify
import rt
import main
import entry
