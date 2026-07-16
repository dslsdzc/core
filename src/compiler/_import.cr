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
import diag
import ir_gen
import dataflow
import ccr_io
import module
import toml
import project
import os
import io
import interp
import dump
import ext_mgr
import ext_safety
import pass
import entry
