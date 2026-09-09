#!/usr/bin/env python3
"""
Build native x86-64 binaries of the self-hosted Core compiler.

Produces three binaries:
  build/corec      — frontend: .cr → .ccr/.cir
  build/corearch   — backend:  .ccr → binary/asm
  build/corelsp    — LSP server: frontend + json + rpc

Pipeline (fast path — no interpreter bottleneck, no gcc dependency):
1. Concatenate sources for each binary
2. Run through bootstrap Lexer → Parser → NameResolver → TypeChecker → IRGen
3. Generate x86-64 assembly via X86_64StackAsmGen
4. Assemble + link with rt.s using as + ld
"""
import sys, os, subprocess

sys.path.insert(0, 'bootstrap')

BASE = os.path.dirname(__file__)


def concat(files, wrapper_fn=None):
    """Concatenate .cr files, optionally appending a main wrapper."""
    parts = []
    for f in files:
        path = os.path.join(BASE, f)
        if os.path.exists(path):
            with open(path, encoding='utf-8') as fh:
                content = fh.read().strip()
                if content:
                    # This build creates one flat compilation unit from an explicit
                    # dependency closure, so per-file imports would appear after
                    # declarations and are both invalid and redundant.
                    content = '\n'.join(
                        line for line in content.splitlines()
                        if not line.strip().startswith('import ')
                    )
                    parts.append(f"// === {f} ===\n{content}")
    src = '\n\n'.join(parts)
    if wrapper_fn:
        src += f'\n\nfn main() -> int {{ return {wrapper_fn}(); }}\n'
    return src


def compile_and_assemble(src, label, out_name):
    """Run full pipeline on src, produce binary at build/{out_name}."""
    from corec.frontend.lexer import Lexer
    from corec.frontend.parser import Parser
    from corec.frontend.name_resolver import NameResolver
    from corec.frontend.desugar import MatchDesugarer
    from corec.frontend.type_checker import TypeChecker
    from corec.frontend.ir_gen import IRGen
    from corec.backend.x86_64_stack_asm import X86_64StackAsmGen
    from corec.utils.module_loader import resolve_imports

    print(f"--- {label} ---")

    lex = Lexer(src)
    tokens = lex.tokenize()
    print(f"  Tokens: {len(tokens)}")
    ast = Parser(tokens).parse_compilation_unit()
    resolve_imports(ast)
    resolver = NameResolver()
    resolver.resolve(ast)
    desugarer = MatchDesugarer(resolver.symtab)
    ast = desugarer.desugar(ast)
    checker = TypeChecker(resolver.symtab)
    checker.check(ast)
    if resolver.errors:
        print("  Errors:", resolver.errors)
        sys.exit(1)
    if checker.errors:
        print("  Checker warnings (non-fatal):", checker.errors)
    print("  Type check passed")

    ir_gen = IRGen(resolver.symtab)
    mod = ir_gen.gen_module(ast)
    print(f"  Functions: {len(mod.functions)}")

    asm_gen = X86_64StackAsmGen(mod)
    asm = asm_gen.generate()
    print(f"  Assembly: {len(asm)} bytes")

    os.makedirs('build', exist_ok=True)
    asm_path = f'build/{out_name}.s'
    with open(asm_path, 'w', encoding='utf-8') as f:
        f.write(asm)

    result = subprocess.run(['as', '-o', f'build/{out_name}.o', asm_path],
                            capture_output=True, text=True)
    if result.returncode != 0:
        print(f"  Assembly failed: {result.stderr}")
        sys.exit(1)

    result = subprocess.run(['ld', '-o', f'build/{out_name}',
                             f'build/{out_name}.o', 'build/runtime.o'],
                            capture_output=True, text=True)
    if result.returncode != 0:
        print(f"  Link failed: {result.stderr}")
        sys.exit(1)

    print(f"  -> build/{out_name}")
    print()


def build_runtime():
    """Build the shared runtime .o once."""
    print("--- Runtime (rt.s) ---")
    result = subprocess.run(['as', '-o', 'build/runtime.o', 'src/runtime/rt.s'],
                            capture_output=True, text=True)
    if result.returncode != 0:
        print(f"  Assembly failed: {result.stderr}")
        sys.exit(1)
    print("  -> build/runtime.o\n")


def main():
    print("=== Building Core native binaries ===\n")

    os.makedirs('build', exist_ok=True)
    build_runtime()

    # corec — frontend: .cr → .ccr/.cir
    compile_and_assemble(
        concat([
            'src/runtime/arena_globals.cr',
            'src/runtime/rt.cr',
            'src/stdlib/io.cr',
            'src/stdlib/fmt.cr',
            'src/stdlib/cli.cr',
            'src/compiler/ast.cr',
            'src/compiler/globals.cr',
            'src/compiler/dyn_arr.cr',
            'src/compiler/lexer.cr',
            'src/compiler/parser.cr',
            'src/compiler/checker.cr',
            'src/compiler/opt.cr',
            'src/compiler/ptr_analysis.cr',
            'src/compiler/region_check.cr',
            'src/compiler/provenance_verify.cr',
            'src/compiler/diag.cr',
            'src/compiler/ext_mgr.cr',
            'src/compiler/ext_safety.cr',
            'src/compiler/ir_gen.cr',
            'src/compiler/pass.cr',
            'src/compiler/dataflow.cr',
            'src/compiler/ccr_io.cr',
            'src/arch/linux/ld/ent_kernel.cr',
            'src/compiler/module.cr',
            'src/stdlib/toml.cr',
            'src/stdlib/hotpatch.cr',
            'src/stdlib/arena.cr',
            'src/stdlib/goroutine.cr',
            'src/stdlib/chan.cr',
            'src/stdlib/sched.cr',
            'src/compiler/project.cr',
            'src/stdlib/os.cr',
            'src/compiler/interp.cr',
            'src/compiler/dump.cr',
            'src/compiler/cir_cache.cr',
            'src/compiler/monomorph.cr',
            'src/compiler/main.cr',
        ], wrapper_fn='compiler_main'),
        label='corec',
        out_name='corec',
    )

    # corearch — backend: .ccr → binary/asm
    compile_and_assemble(
        concat([
            'src/runtime/arena_globals.cr',
            'src/runtime/rt.cr',
            'src/stdlib/io.cr',
            'src/stdlib/fmt.cr',
            'src/stdlib/cli.cr',
            'src/stdlib/toml.cr',
            'src/compiler/ast.cr',
            'src/compiler/globals.cr',
            'src/compiler/dyn_arr.cr',
            'src/arch/hit/hit.cr',
            'src/arch/hit/lower_to_core.cr',
            'src/arch/linux/ld/ent_kernel.cr',
            'src/arch/linux/ld/regalloc.cr',
            'src/arch/linux/ld/sizes.cr',
            'src/arch/linux/ld/instr.cr',
            'src/arch/linux/ld/resolve.cr',
            'src/arch/linux/ld/elf.cr',
            'src/arch/linux/ld/ld.cr',
            'src/compiler/ccr_io.cr',
            'src/compiler/monomorph.cr',
            'src/stdlib/hotpatch.cr',
            'src/stdlib/arena.cr',
            'src/stdlib/goroutine.cr',
            'src/stdlib/chan.cr',
            'src/stdlib/sched.cr',
            'src/compiler/corearch.cr',
        ], wrapper_fn='corearch_main'),
        label='corearch',
        out_name='corearch',
    )

    # corelsp — LSP server: frontend modules + src/lsp
    # 文件清单 = corec 段的编译器前端依赖闭包（剔除 IR 生成/后端/优化模块），
    # 保留 lsp 需要的 lexer/parser/checker/diag/module/globals + 其依赖
    # （ast/dyn_arr/toml/os/hotpatch——hotpatch 为 rt.s 的 SIGHUP 处理器必需）。
    # 注意：不含 src/compiler/main.cr 与 entry.cr——corec_main 未被 lsp 使用，
    # 且 entry.cr 的 fn main() 与 concat 追加的 wrapper 冲突。
    compile_and_assemble(
        concat([
            'src/runtime/arena_globals.cr',
            'src/runtime/rt.cr',
            'src/stdlib/io.cr',
            'src/stdlib/fmt.cr',
            'src/stdlib/toml.cr',
            'src/stdlib/os.cr',
            'src/stdlib/hotpatch.cr',
            'src/stdlib/panic.cr',
            'src/stdlib/arena.cr',
            'src/stdlib/goroutine.cr',
            'src/stdlib/chan.cr',
            'src/stdlib/sched.cr',
            'src/compiler/ast.cr',
            'src/compiler/globals.cr',
            'src/compiler/dyn_arr.cr',
            'src/compiler/lexer.cr',
            'src/compiler/parser.cr',
            'src/compiler/checker.cr',
            'src/compiler/diag.cr',
            'src/compiler/module.cr',
            'src/lsp/_import.cr',
            'src/lsp/json.cr',
            'src/lsp/rpc.cr',
            'src/lsp/lsp.cr',
            'src/lsp/analysis.cr',
            'src/lsp/main.cr',
        ], wrapper_fn='lsp_main'),
        label='corelsp',
        out_name='corelsp',
    )

    print("=== BUILD SUCCESS ===")
    print("  build/corec     — frontend:  .cr → .ccr/.cir")
    print("  build/corearch  — backend:   .ccr → binary")
    print("  build/corelsp   — LSP server: frontend + json")


if __name__ == '__main__':
    main()
