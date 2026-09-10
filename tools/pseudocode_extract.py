#!/usr/bin/env python3
"""提取 Core 源码中的共享标识符，供生成伪代码术语表。用法：python3 tools/pseudocode_extract.py"""
import re, collections
from pathlib import Path

ROOTS = [Path("src/compiler"), Path("src/stdlib"),
         Path("src/runtime"), Path("src/arch/linux/ld"), Path("src/lattice")]
RE_FN = re.compile(r'(?<![A-Za-z0-9_])fn[ \t]+([a-zA-Z_][a-zA-Z0-9_]*)')
RE_STRUCT = re.compile(r'(?<![A-Za-z0-9_])struct[ \t]+([A-Za-z_][a-zA-Z0-9_]*)')
RE_ENUM = re.compile(r'(?<![A-Za-z0-9_])enum[ \t]+([A-Za-z_][a-zA-Z0-9_]*)')
RE_GLOBAL = re.compile(r'\bg_([a-zA-Z_][a-zA-Z0-9_]*)\b')

def strip_comments_strings(text: str) -> str:
    """逐行剥离 // 注释与双引号字符串字面量，避免把注释/字符串中的英文词当作声明。"""
    out = []
    for line in text.split("\n"):
        line = re.sub(r'"[^"]*"', '', line)
        idx = line.find('//')
        if idx >= 0:
            line = line[:idx]
        out.append(line)
    return "\n".join(out)

def main():
    counts = collections.Counter()
    per_file = collections.defaultdict(list)
    for root in ROOTS:
        for f in sorted(root.glob("*.cr")):
            text = f.read_text(encoding="utf-8")
            text = strip_comments_strings(text)  # 剥离注释与字符串，防误匹配
            names = set()
            for m in RE_FN.finditer(text):       names.add(("fn", m.group(1)))
            for m in RE_STRUCT.finditer(text):   names.add(("struct", m.group(1)))
            for m in RE_ENUM.finditer(text):     names.add(("enum", m.group(1)))
            for m in RE_GLOBAL.finditer(text):   names.add(("global", "g_" + m.group(1)))
            for kind, n in names:
                counts[(kind, n)] += 1
                per_file[(kind, n)].append(str(f))
    for (kind, n), c in sorted(counts.items(), key=lambda kv: (-kv[1], kv[0][0], kv[0][1])):
        print(f"{kind}\t{n}\t{c}\t{' '.join(per_file[(kind, n)])}")

if __name__ == "__main__":
    main()
