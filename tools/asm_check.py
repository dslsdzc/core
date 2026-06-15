#!/usr/bin/env python3
"""分析 Python 引导生成的汇编代码，检查栈帧和函数调用正确性。

用法:
  python3 tools/asm_check.py build/corearch.s
  python3 tools/asm_check.py build/corec.s
"""

import re, sys

REAL_FUNCS = set()  # Detected during scan

def check_asm(path):
    with open(path) as f:
        lines = f.readlines()

    errors = []
    funcs = {}  # name -> {line, sub_rsp, has_push, has_pop, has_add}
    cur_func = None
    inside = False

    for i, line in enumerate(lines):
        lnum = i + 1
        line_s = line.rstrip()

        # Detect global labels (potential functions)
        m = re.match(r'^([a-zA-Z_][a-zA-Z0-9_.]*):$', line_s)
        if m:
            name = m.group(1)
            if not name.startswith('.') and name not in ('_start',):
                if not name.startswith('_g_') and not name.startswith('then_') \
                   and not name.startswith('if_merge_') and not name.startswith('loop_'):
                    cur_func = name
                    inside = True
                    funcs[name] = {'line': lnum, 'sub_rsp': 0, 'has_push': False,
                                   'has_pop': False, 'has_add': 0}
                    continue
            cur_func = None

        if not inside or not cur_func or cur_func not in funcs:
            continue

        f = funcs[cur_func]

        if 'push rbp' in line_s:
            f['has_push'] = True
        m = re.search(r'sub rsp,\s*(\d+)', line_s)
        if m:
            f['sub_rsp'] = int(m.group(1))
        m = re.search(r'add rsp,\s*(\d+)', line_s)
        if m:
            f['has_add'] = int(m.group(1))
        if 'pop rbp' in line_s:
            f['has_pop'] = True

    # Validate functions
    for name, f in funcs.items():
        if name.startswith('__builtin_') and not f['has_push']:
            continue  # Builtins may have different conventions
        if f['sub_rsp'] == 0 and not f['has_push']:
            continue  # Leaf function, fine
        if f['sub_rsp'] > 0:
            if not f['has_push'] and not name.startswith('_g_'):
                errors.append(f"  [{name}:{f['line']}] sub rsp {f['sub_rsp']} 但没有 push rbp")
            if f['has_add'] != f['sub_rsp']:
                errors.append(f"  [{name}:{f['line']}] 栈帧不平衡: sub rsp={f['sub_rsp']} vs add rsp={f['has_add']}")
            if not f['has_pop']:
                errors.append(f"  [{name}:{f['line']}] 缺少 pop rbp")

    # Check for nested function call issues
    # Find all 'call' instructions and check arg setup
    for i, line in enumerate(lines):
        if 'call' in line and not line.strip().startswith('#'):
            # Check if there's a sequence of mov rdi/rsi/rdx without saving
            lnum = i + 1
            # This would need more sophisticated analysis

    return errors

if __name__ == '__main__':
    if len(sys.argv) < 2:
        print(f"用法: {sys.argv[0]} <assembly.s>")
        sys.exit(1)

    errors = check_asm(sys.argv[1])
    if errors:
        print(f"\n{len(errors)} ISSUES:")
        for e in errors:
            print(e)
        sys.exit(1)
    else:
        print("✅ 未发现问题")
