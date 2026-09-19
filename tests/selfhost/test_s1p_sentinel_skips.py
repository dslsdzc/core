#!/usr/bin/env python3
"""S1P 台账「哨兵/不可判定值族」三条 skip 的判据（批 8 (甲) 刀 3 小刀，2026-09-19）。

**这一刀加的是什么**：`checker.cr::s1p_arg_one` 的跳过条件原本只有
`pti < 0` / `ati == TI_UNIT` / 整型字面量 / `None→T?` 四条。本刀加**三条同族**：

    if ati == TI_NEVER { skip = 1; }                            // 类型**不可得** ⇒ 未知 ≠ 异型
    if ati == TI_DYN   { skip = 1; }                            // dyn = ⊤，与一切相容
    if ati > TI_DEX_S && get_type_kind(ati) == TYP_GENERIC_PARAM { skip = 1; }  // 泛型形参：声明期不可验证

**为什么必须落在「环」上而不是只登记**：硬错与台账**共用同一条环**（`s1p_arg_one` 是两面的公共
谓词）。只登记不改环 ⇒ **硬错一打开，这两类会红**。（TODO `#2026-09-19-8` 的处置表 E 行。）

## ⚠ 本套件存在的核心理由：**索引空间 vs kind 空间**

`TI_DYN`（**下标常量**，值 7）与 `TYP_GENERIC_PARAM`（**kind 码**，值 7）**数值相同、空间不同**：

  · `ati == TI_DYN`                      —— 判**实参的类型项下标**
  · `get_type_kind(ati) == TYP_GENERIC_PARAM` —— 判**它的 kind**

**同值 7 只是让写错的那一行「看起来合理且编得过」** ⇒ 危险不是「两个常量同值」，而是
**两个空间被混用**。⇒ **判据的任务是区分空间，不是区分数字。**

⇒ 因此本套件含 **⑤ 空间守卫**：读源码断言两条规则**各在自己的空间里**，并**自带突变自证**
（把泛型规则改成错空间写法 ⇒ 守卫必红）。**只靠行为钉子区分不了**：两条 skip 在同一屏、
都让同一批输入不再报 ⇒ 「少一条」与「写错空间」在行为上可能同形。

## 判据（`CORE_S1P=1` 下，逐条独立）

  ① **A**：`dyn` 变量作实参 ⇒ **0 行**（pre = 1 行）
  ② **B**：泛型形参作实参 ⇒ **0 行**（pre = 1 行）
  ③ **C（非真空锚，最重要）**：**真异型**（`string` 形参 ← **已定义的 int 变量**）⇒ **必须仍记 1 行**
  ④ **D**：**未定义名**作实参 ⇒ **0 行**（pre = 1 行；`TI_NEVER` 被跳）
  ⑤ **空间守卫**（源码级）+ 其**突变自证**（错空间写法 ⇒ 必红）
  ⑥ **语料面**：`tests/suite/{dyn_test,generics_test}.cr` 在开位下各 **0 行**

**⚠ ③ 是无真空的唯一锚**：没有它，A/B/D 的「0 行」与「打点根本没装/整条环坏了」不可区分。
**⚠ 所有阳性对照一律用「已定义的 int 变量」，绝不用未定义名**——④ 落地后未定义名类输入
**已不可见**，拿它当正控会**当场变真空绿**（本刀引出的新盲区，见 TODO `#2026-09-19-3`）。
"""

import os
import re
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
COREC = BASE / "build" / "corec"
LEDGER = re.compile(r"^991[78] ")


def ledger_lines(path, s1p=True):
    """跑 check，返回台账行（锚定打印格式：只认行首 `9917|9918 `）。"""
    env = dict(os.environ)
    env["CORE_S1P"] = "1" if s1p else "0"
    p = subprocess.run([str(COREC), "check", str(path)],
                       cwd=str(BASE), env=env, capture_output=True, text=True)
    return [ln for ln in (p.stdout + p.stderr).splitlines() if LEDGER.match(ln)]


def write_probe(text):
    d = Path(tempfile.gettempdir()) / ("eskip-" + uuid.uuid4().hex[:8])
    d.mkdir(parents=True, exist_ok=True)
    f = d / "p.cr"
    f.write_text(text, encoding="utf-8")
    return f


A_DYN = """import fmt
fn takes(s: string) -> int { return str_len(s); }
fn main() -> int {
    x : dyn = 42;
    x = "hello";
    takes(x);
    return 0;
}
"""

B_GENERIC = """import fmt
fn pair[A, B](a: A, b: B) -> int {
    if a != 1 { return 1; }
    if str_len(b) < 1 { return 1; }
    return 0;
}
fn main() -> int { return pair(1, "x") - 1; }
"""

# ③ 非真空锚：**已定义的 int 变量**（绝不用未定义名——见模块注释末的警告）
C_REAL = """import fmt
fn takes(s: string) -> int { return str_len(s); }
fn main() -> int {
    n : int = 7;
    takes(n);
    return 0;
}
"""

# ④ TI_NEVER：未定义名作实参（pre 记 1 行、post 应 0 行）
D_UNDEF = """import fmt
fn takes(s: string) -> int { return str_len(s); }
fn main() -> int {
    n := undef_fn();
    takes(n);
    return 0;
}
"""


def strip_comments(text):
    """剥 `//` 行注释与 `/* */` 块注释（**保留字符串字面量内的内容**）。

    ⚠ **必需**：本守卫按源码文本判形态，而**规则自身的注释里正举着「错空间写法」的例子**
    ⇒ 不剥注释 ⇒ 守卫在**自己的说明文字**上假阳（本套件首跑实测命中，失败项 = ⑤）。
    这正是「扫面必须锚定形态、且不要扫到源码回显」那一族教训（判据网失效形态·假阳）。
    """
    out, i, n = [], 0, len(text)
    in_str = False
    while i < n:
        c = text[i]
        if in_str:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(text[i + 1]); i += 2; continue
            if c == '"':
                in_str = False
            i += 1; continue
        if c == '"':
            in_str = True; out.append(c); i += 1; continue
        if c == "/" and i + 1 < n and text[i + 1] == "/":
            while i < n and text[i] != "\n":
                i += 1
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "*":
            i += 2
            while i + 1 < n and not (text[i] == "*" and text[i + 1] == "/"):
                i += 1
            i += 2
            continue
        out.append(c); i += 1
    return "".join(out)


def space_guard(src, strip=True):
    """⑤ 空间守卫：两条规则是否**各在自己的空间里**。

    返回 (ok, detail)。**注意它判的是「空间」不是「数字」**：
      · dyn 规则必须写成下标比较 `ati == TI_DYN`；
      · 泛型规则必须写成 kind 查询 `get_type_kind(ati) == TYP_GENERIC_PARAM`，且带 `ati > TI_DEX_S` 前缀条。
    """
    # 取 s1p_arg_one 函数体（到下一个顶层 fn 为止）
    m = re.search(r"fn s1p_arg_one\(.*?\n(?=fn |\Z)", src, re.S)
    if not m:
        return False, "s1p_arg_one 未找到"
    body = m.group(0)
    if strip:
        body = strip_comments(body)

    has_dyn = re.search(r"if\s+ati\s*==\s*TI_DYN\s*\{", body) is not None
    has_gen_kind = re.search(r"get_type_kind\(ati\)\s*==\s*TYP_GENERIC_PARAM", body) is not None
    has_prefix = re.search(r"ati\s*>\s*TI_DEX_S\s*&&\s*get_type_kind\(ati\)\s*==\s*TYP_GENERIC_PARAM", body) is not None
    has_never = re.search(r"if\s+ati\s*==\s*TI_NEVER\s*\{", body) is not None

    # 错空间写法（本守卫要能抓到的形态）
    wrong_gen_space = re.search(r"ati\s*==\s*TYP_GENERIC_PARAM", body) is not None
    wrong_dyn_space = re.search(r"get_type_kind\(ati\)\s*==\s*TI_DYN", body) is not None

    if not has_dyn:
        return False, "缺 dyn 规则（`ati == TI_DYN`）"
    if not has_never:
        return False, "缺 never 规则（`ati == TI_NEVER`）"
    if wrong_gen_space:
        return False, "⚠ 空间写错：泛型规则写成了下标比较 `ati == TYP_GENERIC_PARAM`（应为 kind 查询）"
    if wrong_dyn_space:
        return False, "⚠ 空间写错：dyn 规则写成了 kind 查询 `get_type_kind(ati) == TI_DYN`（应为下标比较）"
    if not has_gen_kind:
        return False, "缺泛型形参规则（`get_type_kind(ati) == TYP_GENERIC_PARAM`）"
    if not has_prefix:
        return False, "泛型规则缺 `ati > TI_DEX_S` 前缀条（下标 0..8 是标量/占位 ⇒ 会读到占位行 kind = 假阳来源）"
    return True, "三条规则各在其空间 + 前缀条齐"


def main():
    fails = []
    ok = True

    def expect(name, cond, detail=""):
        nonlocal ok
        print(("  PASS  " if cond else "  FAIL  ") + name + ("" if cond else f"  ← {detail}"))
        if not cond:
            ok = False
            fails.append(name)

    if not COREC.exists():
        print(f"  FAIL  build/corec 不存在（{COREC}）——先跑 build_selfhost_native.py")
        return 1

    # ① A：dyn 变量作实参 ⇒ 0 行
    n = len(ledger_lines(write_probe(A_DYN)))
    expect("A dyn 变量作实参 ⇒ 0 行（pre = 1 行）", n == 0, f"实得 {n} 行")

    # ② B：泛型形参作实参 ⇒ 0 行
    n = len(ledger_lines(write_probe(B_GENERIC)))
    expect("B 泛型形参作实参 ⇒ 0 行（pre = 1 行）", n == 0, f"实得 {n} 行")

    # ③ C：真异型（**已定义 int 变量**）⇒ 仍记 1 行 —— **非真空锚**
    n = len(ledger_lines(write_probe(C_REAL)))
    expect("C 真异型（string 形参 ← 已定义 int 变量）⇒ 仍记 1 行【非真空锚】", n == 1,
           f"实得 {n} 行——若为 0，则 A/B/D 的「0」不可信（环可能整条坏了）")

    # ④ D：未定义名作实参 ⇒ 0 行（TI_NEVER 被跳）
    n = len(ledger_lines(write_probe(D_UNDEF)))
    expect("D 未定义名作实参 ⇒ 0 行（pre = 1 行；TI_NEVER 被跳）", n == 0, f"实得 {n} 行")

    # ⑤ 空间守卫 + 突变自证
    src = (BASE / "src" / "compiler" / "checker.cr").read_text(encoding="utf-8")
    g_ok, g_detail = space_guard(src)
    expect("⑤ 空间守卫：三条规则各在其空间 + 前缀条齐", g_ok, g_detail)

    # ⑤-b/⑤-c 的**突变必须在剥过注释的文本上做**，并**断言命中了目标**：
    #   ⚠ 本套件首跑实测：直接在原文上 `count=1` 替换 ⇒ 命中的是**注释里**的同形串
    #   （规则说明里正举着正则要找的那一行）⇒ 真代码未动 ⇒ 守卫仍绿 ⇒ **突变打空**。
    #   ⇒ 纪律 = 「突变必须断言它命中了目标」（判据网失效形态·自证工具给假信号）。
    stripped = strip_comments(src)

    def mutate(text, pat, repl, name):
        new, cnt = re.subn(pat, repl, text)
        return new, cnt, name

    # ⑤-b 把泛型规则改成**错空间**写法 ⇒ 守卫必须红
    m_b, cnt_b, _ = mutate(stripped, r"get_type_kind\(ati\)\s*==\s*TYP_GENERIC_PARAM",
                           "ati == TYP_GENERIC_PARAM", "b")
    expect("⑤-b 突变自证：错空间写法（`ati == TYP_GENERIC_PARAM`）⇒ 守卫必红",
           cnt_b == 1 and m_b != stripped and not space_guard(m_b, strip=False)[0],
           f"命中 {cnt_b} 处（须恰 1 = 命中了代码而非注释）；"
           "若守卫仍绿 ⇒ 无法区分空间 ⇒ 形同虚设")

    # ⑤-c 删掉前缀条 ⇒ 守卫必须红
    m_c, cnt_c, _ = mutate(stripped, r"ati\s*>\s*TI_DEX_S\s*&&\s*", "", "c")
    expect("⑤-c 突变自证：删 `ati > TI_DEX_S` 前缀条 ⇒ 守卫必红",
           cnt_c == 1 and m_c != stripped and not space_guard(m_c, strip=False)[0],
           f"命中 {cnt_c} 处（须恰 1）；若守卫仍绿 ⇒ 前缀条无人守")

    # ⑤-e 反向（防「一律红」）：**正确的**剥注释文本 ⇒ 守卫必须绿
    #      （没有这条，一个「永远返回 False」的守卫也能过 ⑤-b/⑤-c）
    expect("⑤-e 反向钉子：正确的剥注释文本 ⇒ 守卫必绿（防「一律红」守卫）",
           space_guard(stripped, strip=False)[0],
           "正确文本被判红 ⇒ 守卫过严，⑤-b/⑤-c 的红不再有信息量")

    # ⑤-d **剥注释本身是承重的**：不剥注释 ⇒ 守卫必在**规则自身的说明文字**上假阳。
    #      这条同时是「自证工具自身产生假信号」那一族的现成实例（本套件首跑就栽在这里）。
    expect("⑤-d 剥注释承重自证：不剥注释 ⇒ 守卫必假阳（源码注释里举着错空间写法的例子）",
           not space_guard(src, strip=False)[0],
           "不剥注释仍绿 ⇒ 注释里已无该形态 ⇒ 本项失去意义（应据实删掉本项并说明）")

    # ⑥ 语料面：E 类两个载体在开位下各 0 行
    for rel in ("tests/suite/dyn_test.cr", "tests/suite/generics_test.cr"):
        p = BASE / rel
        if p.exists():
            n = len(ledger_lines(p))
            expect(f"⑥ 语料 {rel} ⇒ 0 行（pre = 1 行）", n == 0, f"实得 {n} 行")
        else:
            print(f"  SKIP  {rel} 不存在")

    print(("S1P SENTINEL SKIPS " + ("PASS" if ok else "FAIL")) + f" · 失败项 = {fails}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
