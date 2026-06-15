// _import.cr — imports applied to all .cr files in src/compiler/
// Backend files in subdirectories use :: as path separator.
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
import backend::x86_64
import backend::x86_64::instr
import module
import backend::resolve
import toml
import project
import os
import interp
import dump
import entry
