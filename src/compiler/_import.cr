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
