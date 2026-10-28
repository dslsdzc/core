// _import.cr: imports applied to all .cr files in src/compiler.
// Backend files in subdirectories use :: as a path separator.
// The ELF pipeline is the only backend.
import cli
import ast
import ccr_schema
import globals
import bytes
import dyn_arr
import source
import lib_manager
import literal
import big_lit
import lexer
import parser
import checker
import mapping
import x86_mapping
import prelude
import x86_frontend_abi
import linux_frontend_abi
import runtime_frontend_abi
import target_abi
import frontend_target
import type_terms
import type_engine
// Interface registry: the entry table and iface_* query API. It is placed after
// the engine and before the bridge. ty_shadow.cr delegates to this layer, so the
// order is engine, registry, bridge.
import iface_registry
// Interface satisfaction checks and iface_kind_of live in iface_axis.cr, which is
// corec-only. Project mode must import this file because the src/compiler file set
// is exactly this import list; a missing import leaves iface_kind_of and the
// iface_satisfies family undefined in the bootstrap chain. The corearch import
// list does not include this file or the engine set.
import iface_axis
import ty_shadow
// TYPE segment construction. It uses the sh_term_of_ti bridge and is corec-only.
// Project mode must import this file for ccr_type_prepare_save; the corearch list
// does not include it.
import ccr_types
import type_selftest
import purity_selftest
import stub_regalloc
import stub_regalloc_selftest
import diag
import ir_gen
import dataflow
import ccr_lower
import ccr_io
import ent_kernel
import regalloc_cag
import module
import toml
import project
import os
import fmt
import io
import bigint
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
