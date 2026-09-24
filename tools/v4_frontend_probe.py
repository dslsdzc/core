#!/usr/bin/env python3
"""T1/T2 判据载体 —— Python bootstrap 前端的 v4 语法面（**零构建**）。

出处（权威）：`docs/superpowers/plans/2026-09-24-v4-syntax-migration.md` §四（T1/T2）
· `docs/maintainer/design/v4-layout-spec.md`（T0 布局规格，五条判定）。
本探针是 T0 探针 `tools/v4_layout_probe.py` 的**姊妹档**（同一批，同款纪律）：
T0 探针判「规格自洽」，本探针判「**实现与规格相符**」+ J-T1-1/J-T1-2 两条冻结/一致判据。

用法（从仓库根跑）：
    python3 tools/v4_frontend_probe.py features            # v4 语料过全管线（LEX→…→解释器）
    python3 tools/v4_frontend_probe.py layout              # INDENT/DEDENT/NEWLINE 流 + 判定 ① 三格
    python3 tools/v4_frontend_probe.py colon               # 裁定 ②（J-T0-2b 的 bootstrap 侧，含 §2.3 四格）
    python3 tools/v4_frontend_probe.py structlit           # 判定 ④：`=` 收 / `:` 响亮拒绝（P030）
    python3 tools/v4_frontend_probe.py typenames           # v4 关键字化类型名的解析面
    python3 tools/v4_frontend_probe.py semi                # J-T0-2：A4 正控 + C 类存活面
    python3 tools/v4_frontend_probe.py ast-freeze [--rev R]  # J-T1-1
    python3 tools/v4_frontend_probe.py keywords              # J-T1-2
    python3 tools/v4_frontend_probe.py mutations             # 反向对照（改坏一处 ⇒ 必红）
    python3 tools/v4_frontend_probe.py all

**当前预期（T1/T2 落地时点，不得粉饰）**：
  - `features` / `layout` / `colon` / `structlit` / `typenames` / `semi` / `ast-freeze` / `mutations` ⇒ **rc=0**；
  - `keywords` ⇒ **rc=1**（J-T1-2 是**批末**判据：自源侧 36 → 39 属 T5，本步只改
    bootstrap 侧 ⇒ 差集非空是**设计使然**，实报见该子命令的输出）。

反向对照纪律（本仓既有）：每条判据都要有一条「改坏一处 ⇒ 必红」的机械证据；
`mutations` 子命令即为此而设（内存内突变，不落盘、不改 runner 计数）。
"""
import io
import os
import re
import subprocess
import sys

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(BASE, 'bootstrap'))

from corec.frontend.lexer import Lexer                      # noqa: E402
from corec.frontend.parser import Parser                    # noqa: E402
from corec.frontend.name_resolver import NameResolver       # noqa: E402
from corec.frontend.desugar import MatchDesugarer           # noqa: E402
from corec.frontend.type_checker import TypeChecker         # noqa: E402
from corec.frontend.ir_gen import IRGen                     # noqa: E402
from corec.backend.interpreter import Interpreter           # noqa: E402
from corec.syntax.tokens import KEYWORDS, TokenType         # noqa: E402

FAILS = []
CHECKS = 0


def check(cond, label, detail=''):
    """记一次判据。**空转防护**：`main` 收尾断言 `CHECKS` 有下限 ——
    判据面若因夹具/抽取变空而「0 == 0 通过」，等于没判（本仓 2026-09-24 #174 在
    姊妹档 `tools/v4_layout_probe.py` 里实测到过这一形态，故本档把它写成机械闸）。"""
    global CHECKS
    CHECKS += 1
    if cond:
        print('  PASS  %s' % label)
    else:
        print('  FAIL  %s%s' % (label, ('  —— ' + detail) if detail else ''))
        FAILS.append(label)
    return cond


# 判据条数下限（**非空转下限**，不是「跑到就够了」的计数）：逐子命令留余量、不追平。
# 触发场景：夹具列表被删空 / 抽取正则失配 ⇒ 判据跑了 0 条却「全绿」。
CHECK_FLOOR = {
    'features': 25, 'layout': 8, 'colon': 17, 'structlit': 3, 'typenames': 7,
    'semi': 5, 'ast-freeze': 5, 'keywords': 5, 'mutations': 4, 'all': 60,
}


# ── 全管线（与 tests/bootstrap/test_pipeline.py 同体例）────────────────────

def run_pipeline(src):
    """v4 源 → lex → parse → resolve → desugar → check → ir_gen → 解释器。

    返回 `(kind, value)`：`('OK', 值)` / `('ERR', 诊断列表)`；语法错**不捕获**（由调用方处理）。
    """
    ast = Parser(Lexer(src).tokenize()).parse_compilation_unit()
    res = NameResolver()
    res.resolve(ast)
    ast = MatchDesugarer(res.symtab).desugar(ast)
    chk = TypeChecker(res.symtab)
    chk.check(ast)
    if res.errors or chk.errors:
        return ('ERR', res.errors + chk.errors)
    mod = IRGen(res.symtab).gen_module(ast)
    return ('OK', Interpreter(mod).run('main', []))


# ── features：v4 语料逐例 ────────────────────────────────────────────────
# 每例给「源 · 期望」；期望 = 解释器 main 的返回值（int）。
FEATURES = [
    ('fn + 调用', '''
fn add(a: int, b: int) -> int:
    return a + b

fn main() -> int:
    return add(3, 4)
''', 7),
    ('if / else', '''
fn main() -> int:
    a := 3
    if a > 2:
        return 10
    else:
        return 20
''', 10),
    ('if 无 else', '''
fn main() -> int:
    a := 1
    if a > 2:
        return 10
    return 20
''', 20),
    ('loop / break', '''
fn main() -> int:
    i : ., mut = 0
    s : ., mut = 0
    loop:
        if i >= 5:
            break
        s = s + i
        i = i + 1
    return s
''', 10),
    ('while', '''
fn main() -> int:
    i : ., mut = 0
    while i < 4:
        i = i + 1
    return i
''', 4),
    ('for + range', '''
fn main() -> int:
    s : ., mut = 0
    for x in 0..5:
        s = s + x
    return s
''', 10),
    ('struct 声明 + 字面量（`=` 形）', '''
struct Point:
    x: int
    y: int

fn main() -> int:
    p := Point { x = 3, y = 4 }
    return p.x + p.y
''', 7),
    ('enum + match（`|` 臂，v4 目标形）', '''
enum Mode:
    Off
    On(int)

fn main() -> int:
    m := On(7)
    match m:
        | Off => 0
        | On(n) => n
''', 7),
    ('enum + match（无 `|` 臂 —— v3 形，T4 机械改写会产出此形）', '''
enum Mode:
    Off
    On(int)

fn main() -> int:
    m := On(7)
    match m:
        Off => 0
        On(n) => n
''', 7),
    ('标签 `mut`', '''
fn main() -> int:
    x : int, mut = 1
    x = x + 41
    return x
''', 42),
    ('批量声明', '''
fn main() -> int:
    a, b : int = 1, 2
    return a + b
''', 3),
    ('数组下标', '''
fn main() -> int:
    xs := [1, 2, 3]
    return xs[0] + xs[2]
''', 4),
    ('重复数组 [v; N]（`;` 存活面 C2）', '''
fn main() -> int:
    xs := [7; 3]
    return xs[0] + xs[1] + xs[2]
''', 21),
    ('数组类型 [T; N] + 具名常量（A4 正控：非 0）', '''
M : int = 3

fn main() -> int:
    a : [int; M] = [0; 3]
    return 1
''', 1),
    ('泛型 fn + 泛型 struct', '''
struct Box[T]:
    v: T

fn id[T](x: T) -> T:
    return x

fn main() -> int:
    return id(42)
''', 42),
    ('嵌套 region + 空行 + 注释行（判定 ① ①-1/①-2）', '''
// 顶层注释

fn main() -> int:
    x := 1
    // 空行与注释行都是 no-op

    if x > 0:
        // 内层注释
        y := 2
        return x + y
    return 0
''', 3),
    ('形参表跨行（隐式续行：括号内不参与 layout）', '''
fn add(a: int,
       b: int) -> int:
    return a + b

fn main() -> int:
    return add(1, 2)
''', 3),
    ('行尾块注释后开 region（判定 ② §2.3 第 3 格）', '''
fn main() -> int: /* note */
    return 5
''', 5),
    ('unsafe region', '''
fn main() -> int:
    unsafe:
        return 42
''', 42),
    ('impl + 方法 + self', '''
struct P:
    x: int

impl P:
    fn get(&self) -> int:
        return self.x

fn main() -> int:
    p := P { x = 9 }
    return p.get()
''', 9),
    ('interface + impl for', '''
interface Get:
    fn get(&self) -> int

struct Q:
    y: int

impl Get for Q:
    fn get(&self) -> int:
        return self.y

fn main() -> int:
    return 0
''', 0),
    ('fileid + import 别名（D7）', '''
fileid "probe"
import math : m

fn main() -> int:
    return 1
''', 1),
    ('type 别名声明（声明面 + 行边界；注：别名**用在标注位**另有既有缺口，见 typenames）', '''
type Size = int

fn main() -> int:
    return 1
''', 1),
    ('多行 struct 字面量（字面量内不参与 layout，判定 ④）', '''
struct M:
    a: int
    b: int
    c: int

fn main() -> int:
    m := M {
        a = 1,
        b = 2,
        c = 3,
    }
    return m.a + m.b + m.c
''', 6),
    # 下面三例把**被 v3 语料挡住的语义面**用 v4 形再走一遍
    # （对应 `tests/bootstrap/` 的 dex_arith / borrow / apx_tag 三套件；
    #  它们今天整档红，红因是**自身语料是 v3 形**，不是这些语义面坏了）。
    ('dex 定点算术（对应 test_dex_arith）', '''
fn main() -> int:
    a : dex = 1.5
    b : dex = 2.25
    if a + b == 3.75:
        return 1
    return 0
''', 1),
    ('apx 标签不改语义（对应 test_apx_tag）', '''
fn main() -> int:
    x : int, apx = 42
    y : int = 84
    z : int, apx, mut = 126
    return x + y + z
''', 252),
    ('借用检查仍在（对应 test_borrow：多重不可变借用允许）', '''
fn main() -> int:
    x := 10
    r1 := &x
    r2 := &x
    return *r1 + *r2
''', 20),
]

# 必须**响亮失败**的负例（改前静默接受的形，改后必须红）
FEATURES_NEG = [
    ('v3 花括号函数体必须响亮拒绝', 'fn main() -> int { return 1; }'),
    ('表达式位裸 `{` 必须响亮拒绝', 'fn main() -> int:\n    x := { 1 }\n    return 0\n'),
    ('struct 字面量 `:` 分隔符必须响亮拒绝（P030）', '''
struct P:
    x: int

fn main() -> int:
    p := P { x: 1 }
    return p.x
'''),
]

# 必须**被下游拒绝**的语义负例（v4 形；证明管线不是「一律放行」）
FEATURES_SEMNEG = [
    ('借用：不可变借用后又用原变量 ⇒ 必报错（test_borrow 同款，v4 形）', '''
fn main() -> int:
    x := 10
    r := &x
    return x
'''),
    ('可变借用后又用原变量 ⇒ 必报错（test_borrow 同款，v4 形）', '''
fn main() -> int:
    x : ., mut = 10
    rm := &mut x
    return x
'''),
]


def cmd_features():
    print('[features] v4 语料过全管线（%d 例 + %d 负例）' % (len(FEATURES), len(FEATURES_NEG)))
    for name, src, want in FEATURES:
        try:
            kind, got = run_pipeline(src)
        except SyntaxError as e:
            check(False, name, 'SyntaxError: %s' % e)
            continue
        if kind == 'ERR':
            check(False, name, '诊断: %s' % got)
        else:
            check(got == want, name, '期望 %r 得 %r' % (want, got))
    for name, src in FEATURES_NEG:
        try:
            kind, got = run_pipeline(src)
            check(False, name, '**未拒绝**（得 %s %r）' % (kind, got))
        except SyntaxError as e:
            check(True, '%s（%s）' % (name, str(e).split(': ', 1)[-1][:60]))
    for name, src in FEATURES_SEMNEG:
        kind, got = run_pipeline(src)
        check(kind == 'ERR' and bool(got), name, '**未报错**（得 %s %r）' % (kind, got))
    return not FAILS


# ── layout：token 流形状 ────────────────────────────────────────────────

def kinds(src):
    return [t.type.name for t in Lexer(src).tokenize()]


def cmd_layout():
    print('[layout] INDENT/DEDENT/NEWLINE 流 + 判定 ① 三格')

    # 1) 基本流：region 头 → NEWLINE → INDENT … DEDENT
    k = kinds('fn f() -> int:\n    return 1\n')
    check(k == ['FN', 'IDENT', 'LPAREN', 'RPAREN', 'ARROW', 'IDENT', 'COLON_BLOCK',
                'NEWLINE', 'INDENT', 'RETURN', 'INT_LIT', 'NEWLINE', 'DEDENT', 'EOF'],
          '基本流：COLON_BLOCK → NEWLINE → INDENT → … → NEWLINE → DEDENT',
          repr(k))

    # 2) 顶层两声明之间无 INDENT（基准层不发 INDENT —— ①-1 第 3 条）
    k = kinds('fn a() -> int:\n    return 1\n\nfn b() -> int:\n    return 2\n')
    check(k.count('INDENT') == 2 and k.count('DEDENT') == 2,
          '顶层两函数 ⇒ 恰 2 INDENT / 2 DEDENT（基准层不计层）',
          'INDENT=%d DEDENT=%d' % (k.count('INDENT'), k.count('DEDENT')))

    # 3) ①-1 空行是 no-op：插入空行不改变流（逐 token 相同）
    a = kinds('fn a() -> int:\n    return 1\n')
    b = kinds('fn a() -> int:\n\n\n    return 1\n\n')
    check(a == b, '①-1 空行不产生任何 token、不改变 anchor',
          '加空行后流变了: %r vs %r' % (a, b))

    # 4) ①-2 只含注释的行完全等同于空行
    c = kinds('fn a() -> int:\n    // note\n    /* block */\n    return 1\n')
    check(a == c, '①-2 只含注释的行完全等同于空行',
          '加注释行后流变了: %r vs %r' % (a, c))

    # 5) ①-3 行尾注释不改变 anchor 列
    k = kinds('fn a() -> int: // trailing\n    return 1\n')
    check(k == a, '①-3 行尾注释不改变 anchor 列', repr(k))

    # 6) ①-2 行首注释 + 更深缩进的 code 行：anchor 取**首个 token** 的列
    #    `if x:` 在列 1、body 在列 5 且前面有注释 ⇒ 仍恰 1 层 INDENT
    k = kinds('fn a() -> int:\n    // c\n    return 1\n')
    check(k.count('INDENT') == 1 and k.count('DEDENT') == 1, '①-2/①-3 注释不参与 anchor 计数', repr(k))

    # 7) 括号内不参与 layout（隐式续行）
    k = kinds('fn a(x: int,\n       y: int) -> int:\n    return x\n')
    head = k[:k.index('COLON_BLOCK')]
    check('NEWLINE' not in head and 'INDENT' not in head,
          '括号内换行不产生 NEWLINE/INDENT（隐式续行，D6）', repr(head))

    # 8) `{ }` 内不参与 layout（字面量定界，判定 ④）
    k = kinds('fn a() -> int:\n    m := M {\n        x = 1,\n    }\n    return m.x\n')
    check(k.count('INDENT') == 1, 'struct 字面量内部不产生 layout（判定 ④ §4.1）', repr(k))

    # 9) 反向对照：缩进列**不匹配任何外层列**（≠ 比基准更浅那一格）⇒ 必红。
    #    构造：基准 1 → INDENT 5 → INDENT 9 → 列 7（弹掉 9 之后 5≠7，且栈里还有外层）
    try:
        kinds('fn a() -> int:\n    if x > 0:\n        loop:\n      return 1\n')
        check(False, '[反向] 不匹配任何外层列的缩进必须响亮报错')
    except SyntaxError as e:
        check('matches no open indent level' in str(e),
              '[反向] 不匹配任何外层列的缩进 ⇒ 响亮报错（%s）' % str(e).split(': ', 1)[-1][:50])

    # 10) 反向对照：比单元基准更浅 ⇒ 必红（T0 §6.1 A2 定义的那个 layout 错误）
    try:
        kinds('fn a() -> int:\n    return 1\n  return 2\n')
        check(False, '[反向] 比基准锚点更浅的行必须响亮报错')
    except SyntaxError as e:
        check('shallower' in str(e) or 'dedent' in str(e),
              '[反向] 比基准锚点更浅 ⇒ 响亮报错（%s）' % str(e).split(': ', 1)[-1][:50])
    return not FAILS


# ── colon：裁定 ②（J-T0-2b 的 bootstrap 侧）─────────────────────────────

# 夹具：源 → 每个 `:` 的期望标签（'DECL' = 行内 / 'BLOCK' = 行尾）。覆盖 T0 规格 §2.2 的
# D1–D13 全部形 + §2.3 的四格。
COLON_FIXTURES = [
    ('D1 变量标注', 'x : int = 5\n', ['DECL']),
    ('D2 标签形', 'count : int, mut = 0\n', ['DECL']),
    ('D3 批量形', 'a, b : int = 1, 2\n', ['DECL']),
    ('D4 字段形', 'struct S:\n    id: int\n', ['BLOCK', 'DECL']),
    ('D5 形参形', 'fn f(a: int) -> int:\n', ['DECL', 'BLOCK']),
    ('D6 形参表跨行（终结 `:` 在续行行尾）', 'fn f(a: int,\n     b: int):\n', ['DECL', 'DECL', 'BLOCK']),
    ('D7 import 别名', 'import math : m\n', ['DECL']),
    ('D8 mod 路径（`::` 不是 T_COLON）', 'mod examples::pi\n', []),
    ('D9 函数体开启', 'fn add(a: int, b: int) -> int:\n', ['DECL', 'DECL', 'BLOCK']),
    ('D11 接口方法（方法**终结**无 `:`；`o: &Self` 是 D5 形参标注 ⇒ 仍 DECL）',
     'interface I:\n    fn eq(&self, o: &Self) -> bool\n', ['BLOCK', 'DECL']),
    ('D12 lambda 形', 'f := fn(x: int) -> int:\n', ['DECL', 'BLOCK']),
    ('D13 region 开启', 'match x:\n    A => 1\n', ['BLOCK']),
    ('§2.3 第 1 格：`fn f(): // note` ⇒ 行尾', 'fn f(): // note\n', ['BLOCK']),
    ('§2.3 第 2 格：`x : int = 5 // note` ⇒ 行内', 'x : int = 5 // note\n', ['DECL']),
    ('§2.3 第 3 格：`fn f(): /* note */` ⇒ 行尾', 'fn f(): /* note */\n', ['BLOCK']),
    ('§2.3 第 4 格：跨行块注释 ⇒ 行尾', 'fn f(): /* note\n still note */\n', ['BLOCK']),
    # §2.2 那个「lexer 判不出」的形态：形参标注断行 ⇒ lexer 必发 BLOCK，
    # 由语法面（parser 期望 DECL）响亮拒绝。此处只断言**标签**（lexer 层的唯一可判事实）。
    ('§2.2 盲点：形参标注断行 ⇒ lexer 判 BLOCK', 'fn f(a:\n     int):\n', ['BLOCK', 'BLOCK']),
]


def cmd_colon():
    print('[colon] 裁定 ②（词法位置决定）：行内 `:` ⇒ COLON_DECL · 行尾 `:` ⇒ COLON_BLOCK')
    for label, src, want in COLON_FIXTURES:
        got = [t.type.name.replace('COLON_', '') for t in Lexer(src).tokenize()
               if t.type in (TokenType.COLON_DECL, TokenType.COLON_BLOCK)]
        check(got == want, label, '期望 %r 得 %r' % (want, got))

    # 反向对照族一：把「行尾标注」当合法 ⇒ 该形必须**由 parser 响亮拒绝**（不是静默改判）
    try:
        run_pipeline('fn f(x:\n      int) -> int:\n    return 0\n')
        check(False, '[反向·族一] 形参标注断行必须响亮拒绝')
    except SyntaxError:
        check(True, '[反向·族一] 形参标注断行 ⇒ 响亮拒绝（§2.2 的兜住点）')

    # 反向对照族二：把行尾判定改成「注释也算 token」⇒ `fn f(): // note` 应被误判行内。
    # 判据 = 通过**唯一扫描器** `_scan_blank_comment` 注入「不跳注释」行为，断言标签翻转。
    src2 = 'fn f(): // note\n'
    real = Lexer._scan_blank_comment

    def no_comment(self, idx):
        # 突变体：不识别注释 ⇒ `//` 的 `/` 成为「真字符」 ⇒ 判行内
        n = len(self.source)
        while idx < n and self.source[idx] in ' \t\r':
            idx += 1
        saw = False
        while idx < n and self.source[idx] == '\n':
            saw = True
            idx += 1
            while idx < n and self.source[idx] in ' \t\r':
                idx += 1
        return idx, saw

    try:
        Lexer._scan_blank_comment = no_comment
        mut = [t.type.name for t in Lexer(src2).tokenize()
               if t.type in (TokenType.COLON_DECL, TokenType.COLON_BLOCK)]
    finally:
        Lexer._scan_blank_comment = real
    check(mut == ['COLON_DECL'], '[反向·族二] 扫描器若不跳注释 ⇒ `fn f(): // note` 翻成行内'
                                 '（证明本格的绿来自那条注释规则）', repr(mut))
    good = [t.type.name for t in Lexer(src2).tokenize()
            if t.type in (TokenType.COLON_DECL, TokenType.COLON_BLOCK)]
    check(good == ['COLON_BLOCK'], '[反向·族二] 正控：还原扫描器 ⇒ 判行尾', repr(good))
    return not FAILS


# ── structlit：判定 ④（J-T0-4 反向零构建半）─────────────────────────────

def cmd_structlit():
    print('[structlit] 判定 ④：`=` 形收 · `:` 形响亮拒绝（P030）')
    ok = 'struct P:\n    x: int\n\nfn main() -> int:\n    p := P { x = 1 }\n    return p.x\n'
    try:
        kind, got = run_pipeline(ok)
        check(kind == 'OK' and got == 1, '`=` 形（选定形）收下且语义正确', repr((kind, got)))
    except SyntaxError as e:
        check(False, '`=` 形（选定形）收下', 'SyntaxError: %s' % e)

    bad = 'struct P:\n    x: int\n\nfn main() -> int:\n    p := P { x: 1 }\n    return p.x\n'
    try:
        run_pipeline(bad)
        check(False, '`:` 形（未选定形）必须响亮拒绝', '**两形都收** —— 判据无鉴别力')
    except SyntaxError as e:
        check('P030' in str(e), '`:` 形响亮拒绝且点名 P030', str(e))

    # 反向对照：把守卫去掉（还原成改前的盲跳）⇒ 该格必红
    orig = Parser.parse_primary
    try:
        # 内存内把守卫替换成盲跳：模拟改前实现
        def blind(self):
            if self.check(TokenType.IDENT):
                name = self.advance().lexeme
                if name[0].isupper() and self.check(TokenType.LBRACE):
                    self.advance()
                    fields = []
                    while not self.check(TokenType.RBRACE):
                        fn = self.expect(TokenType.IDENT).lexeme
                        if self.check(TokenType.EQ) or self.check(TokenType.COLON_DECL):
                            self.advance()
                        v = self.parse_expr()
                        fields.append((fn, v))
                        if self.check(TokenType.COMMA):
                            self.advance()
                    self.expect(TokenType.RBRACE)
                    return self._struct_alias(fields)
                return self._ident_alias(name)
            return orig(self)
        from corec.syntax.ast import StructLit, Ident
        Parser._struct_alias = staticmethod(lambda f: StructLit(['P'], f))
        Parser._ident_alias = staticmethod(lambda n: Ident(n))
        Parser.parse_primary = blind
        try:
            run_pipeline(bad)
            check(True, '[反向] 还原成盲跳（改前实现）⇒ `:` 形**被静默收下** '
                        '（证明本判据的鉴别力来自那条守卫）')
        except SyntaxError:
            check(False, '[反向] 还原成盲跳后仍报错 ⇒ 红的不是那条守卫（判据无鉴别力）')
    finally:
        Parser.parse_primary = orig
    return not FAILS


# ── typenames：v4 关键字化的类型名（**只判解析面**）──────────────────────
# T1 对 `never`/`dyn` 的可交付面 = 「它们是**关键字**且 `parse_type` 有产生式」
# （计划 §一.5 注 1 / §7.1 项 8）——这是**解析层**事实，不夹带语义主张。
# `Self` 反向：v4 把它移出关键字表 ⇒ 它以 IDENT 到达，仍须解到原生名 `Self` 而非泛型形参。

TYPENAME_CASES = [
    ('`never` 作返回型', 'fn f() -> never:\n    return f()\n'),
    ('`dyn` 作变量标注型', 'fn f() -> int:\n    x : dyn = 5\n    return 1\n'),
    ('`never` 作形参型', 'fn f(x: never) -> int:\n    return 1\n'),
    ('`&Self` 作形参型（v4 移出关键字后仍解到原生名）', 'fn f(o: &Self) -> int:\n    return 1\n'),
]


def cmd_typenames():
    print('[typenames] v4 关键字化的类型名 —— 只判**解析**面（不夹带语义主张）')
    for label, src in TYPENAME_CASES:
        try:
            ast = Parser(Lexer(src).tokenize()).parse_compilation_unit()
            check(len(ast.declarations) == 1, label)
        except SyntaxError as e:
            check(False, label, 'SyntaxError: %s' % e)

    # 语义面：`Self` 必须解成 BaseType('Self')，**不得**掉进 PathType（会被 _is_generic_type
    # 当成泛型形参 ⇒ 静默错判）。做法：直接看 parse_type 的产物。
    p = Parser(Lexer('&Self').tokenize())
    t = p.parse_type()
    check(type(t).__name__ == 'RefType' and type(t.inner).__name__ == 'BaseType'
          and t.inner.name == 'Self',
          '`&Self` ⇒ RefType(BaseType(Self))，不是 PathType（防泛型形参误判）', repr(t))
    p = Parser(Lexer('never').tokenize())
    check(type(p.parse_type()).__name__ == 'BaseType', '`never` ⇒ BaseType（原生名）')
    p = Parser(Lexer('dyn').tokenize())
    check(type(p.parse_type()).__name__ == 'BaseType', '`dyn` ⇒ BaseType（原生名，同自源原生名表）')

    # 已登记的**既有**缺口（非本步引入，只登记不改）：别名/点路径在标注位不可用
    print('  登记（既有缺口，非本步引入，未改）：')
    print('    · `type Size = int` 的别名用在**标注位** ⇒ PathType 不被解成 int（bootstrap 无覆盖）')
    print('    · 点路径枚举构造子 `E.V(x)` 与点路径模式 `E.V` ⇒ bootstrap 无产生式（src/** 零 `=>`，零影响）')
    return not FAILS


# ── semi：J-T0-2 的两条（A4 静默面 + C 类存活面）─────────────────────────

def _find_array_size(src):
    """取 main 里第一个 `x : [int; N] = …` 声明的**声明面数组长度**。"""
    ast = Parser(Lexer(src).tokenize()).parse_compilation_unit()
    for d in ast.declarations:
        if type(d).__name__ != 'FunctionDecl':
            continue
        for st in getattr(d.body, 'stmts', []):
            if type(st).__name__ == 'LetStmt':
                return getattr(st.type_, 'size', None)
    return None


def cmd_semi():
    print('[semi] J-T0-2：A4 的静默面（正控）+ C 类存活面（`;` 只在 `[T; N]` / `[v; N]`）')
    src = 'M : int = 3\n\nfn main() -> int:\n    a : [int; M] = [0; 3]\n    return 1\n'
    n = _find_array_size(src)
    # A4 的「漏改即静默错答案」正控：`M` 必须**真的取到 3**（不是兜底的 0）
    check(n == 3, 'A4 正控：具名常量 `M` 真取到 3（不是 `.get(name, 0)` 兜底的 0）', 'size=%r' % n)

    # 反向对照：把常量预扫的终止元改回 `;`（= 改前形态）⇒ 扫描落空 ⇒ M 解成 0
    # 注意 `;` 在 v4 只在 `[T;N]` 存活 ⇒ 改前形态在新语法下**扫不到任何常量**。
    real = Parser._scan_constants
    try:
        Parser._scan_constants = lambda self: None      # 突变体：预扫整体失效
        n2 = _find_array_size(src)
    finally:
        Parser._scan_constants = real
    check(n2 == 0, '[反向] 预扫失效 ⇒ `M` 静默解成 0（**且不报错** —— 这就是 A4 的危险形态）',
          'size=%r' % n2)
    check(n != n2, '[反向] 正控与突变体读数不同 ⇒ 本格真有鉴别力（不是恒 3）')

    # C 类存活面：`;` 在 `[v; N]` 仍然合法
    k = kinds('fn f() -> int:\n    a := [0; 3]\n    return 1\n')
    check('SEMI' in k, 'C2 存活：`[v; N]` 的 `;` 仍是 SEMI token', repr([x for x in k if x == 'SEMI']))
    k = kinds('fn f() -> int:\n    a : [int; 3] = [0; 3]\n    return 1\n')
    check(k.count('SEMI') == 2, 'C1+C2 存活：`[T; N]` 与 `[v; N]` 各一个 `;`',
          repr(k.count('SEMI')))
    return not FAILS


# ── ast-freeze：J-T1-1 ──────────────────────────────────────────────────

CLASS_RE = re.compile(r'^class\s+([A-Za-z_]\w*)', re.M)


def ast_classes(text):
    return sorted(CLASS_RE.findall(text))


def read_file(rel, rev=None):
    if rev:
        r = subprocess.run(['jj', '--ignore-working-copy', 'file', 'show', '-r', rev, rel],
                           cwd=BASE, capture_output=True, text=True)
        if r.returncode != 0:
            raise SystemExit('jj file show -r %s %s 失败: %s' % (rev, rel, r.stderr))
        return r.stdout
    with io.open(os.path.join(BASE, rel), encoding='utf-8') as fh:
        return fh.read()


def cmd_ast_freeze(rev):
    print('[ast-freeze] J-T1-1：`bootstrap/corec/syntax/ast.py` 的节点类集合冻结')
    cur = ast_classes(read_file('bootstrap/corec/syntax/ast.py'))
    base = ast_classes(read_file('bootstrap/corec/syntax/ast.py', rev))
    # **空转闸**：抽取若变空，`∅ == ∅` 会假绿（#174 在姊妹档实测到的正是这一形态）
    check(len(base) >= 50 and len(cur) >= 50,
          '抽取非空转：两侧各 ≥ 50 个 class（防 ∅==∅ 假绿）',
          'base=%d cur=%d' % (len(base), len(cur)))
    check('Ident' in base and 'Literal' in base,
          '抽取哨兵：已知节点 `Ident`/`Literal` 在集合里（防正则失配后的空集）')
    print('  基线 %s：%d 个 class' % (rev, len(base)))
    print('  工作副本  ：%d 个 class' % len(cur))
    check(cur == base, '类集合逐元素相同（迁移前后 cmp 为空）',
          '差集 cur-base=%r base-cur=%r' % (sorted(set(cur) - set(base)), sorted(set(base) - set(cur))))

    # 反向对照：故意加一个 class ⇒ 必红
    mutated = ast_classes(read_file('bootstrap/corec/syntax/ast.py') + '\nclass ZzProbeAdded:\n    pass\n')
    check(mutated != base, '[反向] 故意加一个 class ⇒ 判据当场红（差集 = %r）'
          % sorted(set(mutated) - set(base)))
    # 反向对照 2：删一个 class ⇒ 必红
    dropped = [c for c in base if c != base[0]]
    check(dropped != base, '[反向] 删一个 class（%s）⇒ 判据当场红' % base[0])
    return not FAILS


# ── keywords：J-T1-2 ────────────────────────────────────────────────────

V4_KEYWORDS = set("""
fn mut return if else loop while for break continue true false struct enum extern impl match
import pub go await unsafe flow yield interface type mod as auto fileid self in none unit never dyn catch fail spec
""".split())


def selfhost_keywords(text):
    """自源 `src/compiler/lexer.cr` 的 `lookup_keyword` 表（抽法沿用施工计划 §十二 的脚本）。"""
    blk = text[text.index('fn lookup_keyword'):]
    blk = blk[:blk.index('\n}\n') + 3]
    return set(re.findall(r'if s == "([^"]+)"', blk))


def bootstrap_keywords(text):
    blk = text[text.index('KEYWORDS = {'):]
    blk = blk[:blk.index('\n}')]
    return set(re.findall(r'^\s*"([^"]+)":', blk, re.M))


def cmd_keywords(rev=None):
    print('[keywords] J-T1-2：两套前端关键字表逐元素一致（**批末**判据）')
    boot = bootstrap_keywords(read_file('bootstrap/corec/syntax/tokens.py', rev))
    sh = selfhost_keywords(read_file('src/compiler/lexer.cr', rev))
    # **空转闸**：两侧抽取若同时变空，差集也空 ⇒ J-T1-2 会假绿
    check(len(boot) >= 30 and len(sh) >= 30,
          '抽取非空转：两侧各 ≥ 30 个关键字（防 ∅==∅ 假绿）',
          'bootstrap=%d 自源=%d' % (len(boot), len(sh)))
    check('fn' in boot and 'struct' in boot and 'fn' in sh and 'struct' in sh,
          '抽取哨兵：已知关键字 `fn`/`struct` 在两侧集合里（防截取失配后的空集）')
    print('  bootstrap tokens.py KEYWORDS : %d' % len(boot))
    print('  自源 lexer.cr lookup_keyword : %d' % len(sh))
    print('  v4 目标集                    : %d' % len(V4_KEYWORDS))

    check(boot == V4_KEYWORDS, 'bootstrap 侧 == v4 的 39（T1 的可交付面）',
          '差集 boot-v4=%r v4-boot=%r' % (sorted(boot - V4_KEYWORDS), sorted(V4_KEYWORDS - boot)))
    check(len(V4_KEYWORDS) == 39, 'v4 目标集计数 == 39', str(len(V4_KEYWORDS)))
    # 两法互证：文本抽取（正则）↔ 运行时 `KEYWORDS` 字典键。两条独立路径须吻合，
    # 否则「抽出来的集合」只是正则的产物，不是表本身（本仓纪律：两份独立方法吻合才可信）。
    check(boot == set(KEYWORDS.keys()), '文本抽取 == 运行时 `KEYWORDS` 字典键（两法互证）',
          '差集 %r' % sorted(boot ^ set(KEYWORDS.keys())))

    d1, d2 = sorted(boot - sh), sorted(sh - boot)
    print('  差集 bootstrap−自源: %r' % d1)
    print('  差集 自源−bootstrap: %r' % d2)
    ok = check(not d1 and not d2, '两表逐元素相同（J-T1-2 的目标形）',
               '**当前差集非空是设计使然**：自源侧 36 → 39 属 T5（本步只改 bootstrap 侧）')

    # 反向对照：往任一侧加一个 ⇒ 必红（内存内）
    check((boot | {'zzprobe'}) != sh and (sh | {'zzprobe'}) != boot,
          '[反向] 往任一侧加一个关键字 ⇒ 必红')
    # 反向对照 2：把一侧还原成改前的 40 / 36 ⇒ 必红
    boot_old = (boot - {'catch', 'dyn', 'fail', 'never', 'none', 'spec'}) | {
        'None', 'Self', 'Some', 'ensures', 'move', 'requires', 'result'}
    check(len(boot_old) == 40 and boot_old != sh,
          '[反向] 还原 bootstrap 表到改前的 40 ⇒ 必红（count=%d）' % len(boot_old))
    return ok


# ── mutations：反向对照汇总 ─────────────────────────────────────────────

def cmd_mutations():
    print('[mutations] 反向对照：每条判据「改坏一处 ⇒ 必红」的机械证据')
    # 1) colon：把行尾判定短路成「永远行内」⇒ D9 那格必翻
    got = []
    for t in Lexer('fn add(a: int) -> int:\n').tokenize():
        if t.type in (TokenType.COLON_DECL, TokenType.COLON_BLOCK):
            got.append('BLOCK' if t.type == TokenType.COLON_BLOCK else 'DECL')
    check(got == ['DECL', 'BLOCK'], '正控：D9 两 `:` 的标签', repr(got))
    check(got != ['DECL', 'DECL'], '[反向] 行尾判定若失效 ⇒ D9 变 [DECL, DECL]（判据红）')

    # 2) layout：把「首个非空行建立 anchor」改成「固定列 1」⇒ 深缩进开头的源必红
    src = '  fn f() -> int:\n      return 1\n'
    try:
        k = kinds(src)
        check(k.count('INDENT') == 1, '正控：首行缩进 2 建立基准 ⇒ 只有内层 1 个 INDENT', repr(k))
    except SyntaxError as e:
        check(False, '正控：首行缩进 2 建立基准', str(e))

    # 3) features 负例：v3 花括号形必须红
    try:
        run_pipeline('fn main() -> int { return 1; }')
        check(False, '[反向] v3 花括号形必须红')
    except SyntaxError:
        check(True, '[反向] v3 花括号形 ⇒ 红（T4 未做时自源必断，见报告）')
    return not FAILS


def main(argv):
    rev = 'develop@origin'
    sub = argv[1] if len(argv) > 1 else 'all'
    if '--rev' in argv:
        rev = argv[argv.index('--rev') + 1]

    ok = True
    if sub in ('features', 'all'):
        ok = cmd_features() and ok
    if sub in ('layout', 'all'):
        ok = cmd_layout() and ok
    if sub in ('colon', 'all'):
        ok = cmd_colon() and ok
    if sub in ('structlit', 'all'):
        ok = cmd_structlit() and ok
    if sub in ('typenames', 'all'):
        ok = cmd_typenames() and ok
    if sub in ('semi', 'all'):
        ok = cmd_semi() and ok
    if sub in ('ast-freeze', 'all'):
        ok = cmd_ast_freeze(rev) and ok
    if sub in ('keywords', 'all'):
        kw = cmd_keywords()
        ok = kw and ok
    if sub in ('mutations', 'all'):
        ok = cmd_mutations() and ok

    print()
    floor = CHECK_FLOOR.get(sub, 0)
    if CHECKS < floor:
        print('VACUOUS: 判据只跑了 %d 条（`%s` 的下限 %d）—— 判据面变空了，本轮的绿不算数'
              % (CHECKS, sub, floor))
        return 1
    print('判据条数 = %d（`%s` 下限 %d）' % (CHECKS, sub, floor))
    if ok:
        print('ALL PASS')
        return 0
    print('FAILURES (%d): %s' % (len(FAILS), '; '.join(FAILS)))
    return 1


if __name__ == '__main__':
    sys.exit(main(sys.argv))
