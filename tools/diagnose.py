#!/usr/bin/env python3
"""Core 编译器诊断工具 — 执行编译并给出明确错误信息。

Usage:
  python3 tools/diagnose.py file.cr           # 完整编译+诊断
  python3 tools/diagnose.py file.cr --check   # 只做类型检查
  python3 tools/diagnose.py file.cr --ccr     # 只生成 .ccr
  python3 tools/diagnose.py file.cr -v        # 详细输出
"""

import subprocess, sys, os, struct, signal

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
COREC = os.path.join(BASE, 'build', 'corec')
COREARCH = os.path.join(BASE, 'build', 'corearch')

def red(s): return f'\033[31m{s}\033[0m' if sys.stdout.isatty() else s
def green(s): return f'\033[32m{s}\033[0m' if sys.stdout.isatty() else s
def yellow(s): return f'\033[33m{s}\033[0m' if sys.stdout.isatty() else s
def gray(s): return f'\033[90m{s}\033[0m' if sys.stdout.isatty() else s

def run(cmd, timeout=30):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r
    except subprocess.TimeoutExpired:
        return type('R', (), {'returncode': -1, 'stdout': '', 'stderr': 'TIMEOUT'})()

def diagnose(path, check_only=False, ccr_only=False, verbose=False):
    if not os.path.exists(path):
        print(f'{red("ERROR")}: file not found: {path}')
        return 1
    if not os.path.exists(COREC) or not os.path.exists(COREARCH):
        print(f'{red("ERROR")}: build/corec or build/corearch not found')
        print(f'  Run: python3 build_selfhost_native.py')
        return 1

    with open(path) as f:
        source = f.read()
    source_lines = source.count('\n')

    print(f'{gray("═══ Core Diagnostics ═══════════════════════════════")}')
    print(f'  File: {path} ({source_lines} lines)')
    ccr_path = path.replace('.cr', '.ccr')

    # ── Phase 1: corec ──
    print(f'{gray("── 1. corec ──")}')
    r = run([COREC, path, '-o', ccr_path])

    if r.returncode == -11:
        print(f'  {red("corec CRASH (SIGSEGV)")}')
        print(f'  This is a compiler bug, not a user error.')
        if r.stdout: print(f'  {gray(r.stdout[:200])}')
        return r.returncode

    # Parse output for error codes
    error_lines = [l for l in r.stdout.strip().split('\n') if 'error[' in l]
    for l in error_lines:
        print(f'  {red(l)}')

    # Show non-fatal checker warnings (verbose only)
    if verbose:
        warns = [l for l in r.stdout.strip().split('\n') if 'warning' in l.lower()]
        for w in warns[:5]:
            print(f'  {yellow(w)}')

    # Summary
    if '0 err=0' in r.stdout:
        print(f'  {green("type check passed")}')
    elif r.returncode != 0:
        print(f'  {red("corec failed")} (exit={r.returncode})')
        return r.returncode

    if check_only:
        return 0

    if ccr_only:
        print(f'  → {ccr_path}')
        return 0

    if not os.path.exists(ccr_path):
        print(f'  {red(".ccr not generated")}')
        return 1

    # ── .ccr analysis ──
    with open(ccr_path, 'rb') as f:
        ccr = f.read()
    fc = struct.unpack('<I', ccr[8:12])[0]
    ic = struct.unpack('<I', ccr[12:16])[0]
    sc = struct.unpack('<I', ccr[20:24])[0]
    scc = struct.unpack('<I', ccr[24:28])[0]

    # Check for __builtin_* calls
    builtins_found = []
    pos = 36
    for i in range(sc):
        sl = struct.unpack('<I', ccr[pos:pos+4])[0]
        s = ccr[pos+4:pos+4+sl].decode('utf-8', errors='replace')
        if s.startswith('__builtin_') and s not in ('__builtin_syscall3', '__builtin_alloc'):
            builtins_found.append(s)
        pos += 4 + sl

    # ── Phase 2: corearch ──
    print(f'{gray("── 2. corearch ──")}')
    bin_path = path.replace('.cr', '') + '_bin'
    r = run([COREARCH, ccr_path, '-o', bin_path])

    if r.returncode == -11:
        help_msg = ''
        if builtins_found:
            for b in builtins_found:
                print(f'  {red(f"✗ {b}")} not available in ELF backend')
            print(f'  {yellow("Fix: use __builtin_syscall3 directly, or embed the function")}')
        else:
            print(f'  {red("corearch CRASH (SIGSEGV) — likely a compiler bug")}')
        return r.returncode

    if r.returncode != 0:
        print(f'  {red(f"corearch failed (exit={r.returncode})")}')
        for l in r.stdout.strip().split('\n'):
            if 'error' in l.lower():
                print(f'  {red(l)}')
        return r.returncode

    if not os.path.exists(bin_path):
        print(f'  {red("no output binary")}')
        return 1

    # ── Run binary ──
    os.chmod(bin_path, 0o755)
    try:
        r2 = subprocess.run([bin_path], capture_output=True, timeout=5)
        out = r2.stdout.decode()
        if out:
            print(f'  output: {green(repr(out[:100]))}')
        if r2.returncode == 0:
            print(f'  {green("exit: 0")}')
        else:
            print(f'  exit: {r2.returncode}')
        print(f'{gray("═══ OK ═══════════════════════════════════════════")}')
        return 0
    except Exception as e:
        print(f'  {red(f"runtime error: {e}")}')
        return 1

if __name__ == '__main__':
    import argparse
    ap = argparse.ArgumentParser(description='Core compiler diagnostic tool')
    ap.add_argument('file', help='Source .cr file')
    ap.add_argument('--check', action='store_true', help='Type-check only')
    ap.add_argument('--ccr', action='store_true', help='Stop at .ccr')
    ap.add_argument('-v', '--verbose', action='store_true')
    args = ap.parse_args()
    sys.exit(diagnose(args.file, args.check, args.ccr, args.verbose))
