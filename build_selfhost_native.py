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

清单分段（x86 实例化设计 §3——三轴组合；波 1 结构波已实施，Task 1-7 收官）：
  段内/段间**相对顺序 = 行为定义面**（平铺编译单元的声明序/全局序），分段只做
  命名与按序组合，顺序与拆分前逐一对应，不可乱序。
  架构轴 `arch_x86_64_files` × 格式轴 `format_elf_files` × OS 轴 `os_linux_files`
  （波 1 落位：Task 1 三轴搬迁 + 组合根 / Task 3/4 frame·tag2l 入架构轴 /
  Task 2/5/6 entry·callseq·syscall 入 OS 轴——**全轴已就位**）+ 组合根
  `x86_linux_target_files`（target triple 命名：project-mode 入口链，不入
  concat——见段注释）。
"""
import sys, os, subprocess, io, contextlib

sys.path.insert(0, 'bootstrap')

BASE = os.path.dirname(__file__)


# ── 清单分段（按三轴组织——concat = 按确定顺序组合）────────────────────

# 与轴无关的公共面：runtime + stdlib + 前端共享数据结构。
common_files = [
    'src/runtime/arena_globals.cr',
    'src/runtime/rt.cr',
    'src/stdlib/io.cr',
    'src/stdlib/fmt.cr',
    'src/stdlib/cli.cr',
    'src/stdlib/toml.cr',
    'src/compiler/ast.cr',
    'src/compiler/globals.cr',
    'src/compiler/dyn_arr.cr',
]

# HIT 表引擎段：引擎留 src/arch/hit/（未来实例可复用的框架），
# 表数据 core-x86.toml 归架构轴 src/arch/x86_64/（波 1 Task 1 迁移裁决）。
hit_engine_files = [
    'src/arch/hit/hit.cr',
    'src/arch/hit/lower_to_core.cr',
]

# 语义内核段（lattice——范式无关，corec/corearch 双 concat 共享）。
kernel_files = [
    'src/lattice/ent_kernel.cr',
]

# ① 架构轴 x86_64：寄存器分配 CAG + 指令编码 + 字节尺寸单源（sizes.cr）
# + int 多字 M1 tag/2L 编码族（tag2l.cr——波 1 Task 4 自 instr.cr 整搬）。
# 段内顺序 = 「被依赖者先」惯例（函数可见性与顺序无关）：tag2l 消费 instr 的
# 编码原语 → instr 之后；frame.cr → tag2l（pf_epilogue 函数尾块调 e2_mw_*；
# tag2l 反向消费 frame 的 g2_tag_off——同轴双向引用，波 1 Task 4 裁定可接受）。
arch_x86_64_files = [
    'src/arch/x86_64/regalloc.cr',
    'src/arch/x86_64/sizes.cr',
    'src/arch/x86_64/instr.cr',
    'src/arch/x86_64/tag2l.cr',
    'src/arch/x86_64/frame.cr',
]

# ② 格式轴 ELF：重定位 + 容器/段/phdr + 链接机制。
format_elf_files = [
    'src/format/elf/resolve.cr',
    'src/format/elf/elf.cr',
    'src/format/elf/ld.cr',
]

# ③ OS 轴 Linux：syscall/callseq/entry（波 1 Task 2/5/6 已全部落位——波 2 参数化待启）。
# entry.cr（Task 2 落位）= _start 发射序 emit_start/emit_start_size——
# 自 src/format/elf/elf.cr 整函数搬迁；跨轴调用经本 concat 扁平单元解析。
# callseq.cr（Task 5 落位）= SysV AMD64 调用约定序列（参数分派/栈参/栈清理/
# 返回值/直接调用——自 instr.cr emit_instr 内联段落抽出；三处同源合流见文件
# 头注）；跨轴消费 x86_64/instr.cr 编码原语。
# syscall.cr（Task 6 落位）= Linux syscall 约定发射序（syscall3/syscall4 内置
# 体——自 instr.cr 内置体分派链抽出；rax 号 + rdi/rsi/rdx(/r10) 参数序 + 0F 05
# + rax 回存；内置体名索引扫描段留 elf.cr 原位）；跨轴消费 x86_64/instr.cr
# 编码原语（e2_mov/e2_w8/e2_store_ret）。
os_linux_files = [
    'src/os/linux/entry.cr',
    'src/os/linux/callseq.cr',
    'src/os/linux/syscall.cr',
]

# 后端收尾段：ccr 载入 + 单态化 + 运行时 stdlib 桥 + corearch 入口。
backend_support_files = [
    'src/compiler/ccr_io.cr',
    'src/compiler/monomorph.cr',
    'src/stdlib/hotpatch.cr',
    'src/stdlib/arena.cr',
    'src/stdlib/goroutine.cr',
    'src/stdlib/chan.cr',
    'src/stdlib/sched.cr',
    'src/compiler/corearch.cr',
]

# 组合根（x86_64-linux target triple）：project-mode 入口链——`corec build
# src/targets/x86_64-linux` 的入口 = 该目录 main.cr（load_project 直读）+
# _import.cr（load_imports 直读）+ Core.toml（工程名）。**不入 concat**：
# main.cr 的 fn main 与 concat 追加的 wrapper 冲突，且其 .cr 经 project-mode
# 独立收编（stage0/stage 链即此入口）。仅纳入清单存在性守卫。
x86_linux_target_files = [
    'src/targets/x86_64-linux/main.cr',
    'src/targets/x86_64-linux/_import.cr',
    'src/targets/x86_64-linux/Core.toml',
]


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


# ── 构建守卫（x86 实例化设计 §3——吸收 ld 单元静默缺陷教训）──────────────

def guard_manifest(files, label):
    """守卫①：清单文件存在性断言——缺失 = 构建早失败（防路径漂/搬迁漏改）。"""
    missing = [f for f in files if not os.path.exists(os.path.join(BASE, f))]
    if missing:
        print(f"[GUARD FAIL] {label}: {len(missing)} manifest entr(y|ies) missing:")
        for f in missing:
            print(f"  - {f}")
        sys.exit(1)
    print(f"[GUARD] {label}: manifest OK ({len(files)} files)")


# 守卫②：**bootstrap-concat 日志**诊断计数非零 = 失败门（TODO #6 建议③的
# concat 面落地）。背景：project-mode 单元曾以 rc=0 + 产物正常 + 全套互测
# byte-identical 通过而**静默吞掉** 34 行 error[（N06 未定义函数 / N01 未定义名）。
# 计数面 = `error[`（self-hosted corec 诊断前缀，src/compiler/diag.cr:134）
# + Python bootstrap 面的等价未定义符号消息（bootstrap 诊断不带 `error[`
# 前缀，其 checker 的未定义名消息 = 同一类静默未定义信号）。
# **作用域限制**：本门只见本文件 concat 源经 Python bootstrap 管线的日志
# （compile_and_assemble 的 _LogTee 缓冲）——self-hosted corec 的 project-mode
# 构建（`corec build <dir>`，**TODO #6 ③ 的真正事发层**）不走此路径，故本门
# 对它零覆盖；该面的同类门 = tests/selfhost/test_backend_bootstrap.py 的
# run_checked（rc=0 时扫 stdout+stderr 的 `error[`）——test_backend_bootstrap
# 的 stage 链（含各核心单元 project-mode 构建）正是该门的被执行面。两门互补，
# 改一处须同步另一处。
BOOTSTRAP_UNDEFINED_MARKERS = ("Undefined name:", "Undefined function")


def guard_build_log(log_text, label):
    """守卫②：本阶段（bootstrap-concat 面）构建日志 error[/未定义符号计数必须为 0。

    project-mode 面（`corec build <dir>` 的 self-hosted 构建日志）不经此函数——
    见 tests/selfhost/test_backend_bootstrap.py run_checked 内的对应门。
    """
    hits = [ln for ln in log_text.splitlines() if "error[" in ln]
    undef = sum(log_text.count(m) for m in BOOTSTRAP_UNDEFINED_MARKERS)
    if hits or undef != 0:
        print(f"[GUARD FAIL] {label}: build log diagnostics — "
              f"error[ lines = {len(hits)}, undefined-symbol marks = {undef}")
        for ln in hits[:40]:
            print(f"  {ln}")
        sys.exit(1)
    print(f"[GUARD] {label}: build log clean (error[ = 0, undefined = 0)")


class _LogTee:
    """stdout 分流：终端（实时可见）+ 内存缓冲（供守卫②扫描本阶段日志）。"""

    def __init__(self, stream, buf):
        self._stream = stream
        self._buf = buf

    def write(self, s):
        self._buf.write(s)
        return self._stream.write(s)

    def flush(self):
        self._stream.flush()


def emit(asm, out_name):
    """Assemble + link the generated assembly into build/{out_name}."""
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

    log = io.StringIO()
    with contextlib.redirect_stdout(_LogTee(sys.__stdout__, log)):
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

    # 守卫②：诊断面（error[/未定义符号）在本阶段日志内必须为零。
    guard_build_log(log.getvalue(), label)

    asm_gen = X86_64StackAsmGen(mod)
    asm = asm_gen.generate()
    print(f"  Assembly: {len(asm)} bytes")

    emit(asm, out_name)


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
    corec_files = [
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
        # R2 P0 类型项引擎（建层）：类型项 DAG 表 + 构造去重 → 判定引擎（桩）→ 自测通道。
        # 置于 checker 之后（计划 Step 9 指定位置）；引擎尚无 checker 侧消费者，
        # 本批为纯增量（checker/ir_gen/后端零改动 = 产物零变化）。
        'src/compiler/type_terms.cr',
        'src/compiler/type_engine.cr',
        'src/compiler/type_selftest.cr',
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
        'src/lattice/ent_kernel.cr',
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
    ]
    guard_manifest(corec_files, 'corec')
    compile_and_assemble(
        concat(corec_files, wrapper_fn='compiler_main'),
        label='corec',
        out_name='corec',
    )

    # corearch — backend: .ccr → binary/asm
    # 段顺序 = 行为定义面：common → hit → kernel → 架构轴 → 格式轴 → OS 轴
    # → 后端收尾（与拆分前清单逐一对应）。组合根 x86_linux_target_files 不入
    # concat（见段注释）——单独纳入存在性守卫。
    corearch_files = (common_files + hit_engine_files + kernel_files +
                      arch_x86_64_files + format_elf_files + os_linux_files +
                      backend_support_files)
    guard_manifest(corearch_files, 'corearch')
    guard_manifest(x86_linux_target_files, 'x86_64-linux target')
    compile_and_assemble(
        concat(corearch_files, wrapper_fn='corearch_main'),
        label='corearch',
        out_name='corearch',
    )

    # corelsp — LSP server: frontend modules + src/lsp
    # 文件清单 = corec 段的编译器前端依赖闭包（剔除 IR 生成/后端/优化模块），
    # 保留 lsp 需要的 lexer/parser/checker/diag/module/globals + 其依赖
    # （ast/dyn_arr/toml/os/hotpatch——hotpatch 为 rt.s 的 SIGHUP 处理器必需）。
    # 注意：不含 src/compiler/main.cr 与 entry.cr——corec_main 未被 lsp 使用，
    # 且 entry.cr 的 fn main() 与 concat 追加的 wrapper 冲突。
    corelsp_files = [
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
    ]
    guard_manifest(corelsp_files, 'corelsp')
    compile_and_assemble(
        concat(corelsp_files, wrapper_fn='lsp_main'),
        label='corelsp',
        out_name='corelsp',
    )

    print("=== BUILD SUCCESS ===")
    print("  build/corec     — frontend:  .cr → .ccr/.cir")
    print("  build/corearch  — backend:   .ccr → binary")
    print("  build/corelsp   — LSP server: frontend + json")


if __name__ == '__main__':
    main()
