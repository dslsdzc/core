// Imports for the corearch backend project.
import cli
import backend_flags
import fmt
import io
import toml
import ast
import ccr_schema
import globals
import bytes
import dyn_arr
import backend_schema
import backend_globals
import backend_arrays
import hit
// HIT lowering layer. instr.cr's table encoder consumes the event stream and pool
// patch records defined here.
import lower_to_core
// Monomorphization belongs to the frontend IR generation pass and is deliberately
// absent here. It depends on checker and parser symbols that this backend project
// does not include.
// The type-term layer must precede ccr_io: the load path rebuilds the type-term
// table and reads ESZ_TYPE_TERM, OFF_TT_*, and TT_* constants. type_engine follows
// type_terms and precedes ccr_io so the type judgment primitives are available.
import type_terms
import type_engine
import ccr_io
import ent_kernel
// The backend rebuilds the linear schedule after loading through
// build_linear_schedule in regalloc.cr.
import regalloc
import sizes
import int_rep
import bigint_blob
import instr
// Function frame layout: pf_frame_size, pf_prologue, pf_epilogue.
import frame
import resolve
import elf
import ld
// Linux entry sequence: emit_start and emit_start_size.
import entry
// SysV AMD64 call sequences: cs_args_dispatch, cs_stack_args, cs_stack_cleanup,
// cs_ret_value, and cs_call_direct.
import callseq
// Linux syscall emission: sys_syscall3_stub uses rax for the number and rdi, rsi,
// and rdx for arguments. sys_syscall4_stub passes the fourth argument in r10.
import syscall
