// src/kernel/term_io.cr —— 共享格式协议实现（Task 5）
// McTT→Core 内核移植 M1 的协议层：S-表达式文本 <-> 扁平 arena 节点。
// 协议（Task 3 定死，tools/mctt_ref/protocol.md）：
//   <exp> ::= (typ N) | (nat) | (zero) | (succ <exp>) | (natrec <exp> <exp> <exp> <exp>)
//           | (pi <exp> <exp>) | (fn <exp> <exp>) | (app <exp> <exp>)
//           | (var N) | (sub <exp> <sub>)
//   <sub> ::= (id) | (weaken) | (compose <sub> <sub>) | (extend <sub> <exp>)
//   N     ::= 非负十进制整数
// de Bruijn 约定（kernel-spec.md §0.1）：var 0 = 上下文最右（最近绑定）元素。
//
// ── 扁平 arena 布局（Task 6 按此 import 常量与布局）──
// g_kernel_nodes：64KB 字节缓冲 = 8192 个 int 槽；节点索引 = 起始槽（0, 5, 10, …）。
//   注意：brief 原稿为 `[int; 8192]` 数组全局——当前 ELF 后端不支持定长数组全局
//   （BSS 槽为 NULL 指针，访问即 SIGSEGV），故改为字节缓冲 + kern_new 惰性 alloc，
//   槽语义完全不变（8192 槽，五槽一组，kern_get(n, slot) = 槽 n+slot）。
// 节点槽（五槽一组 {kind, a, b, c, d}）：
//   K_TYP     {K_TYP,  N, 0, 0, 0}         N = 宇宙层级
//   K_NAT     {K_NAT,  0, 0, 0, 0}
//   K_ZERO    {K_ZERO, 0, 0, 0, 0}
//   K_SUCC    {K_SUCC, e, 0, 0, 0}
//   K_NATREC  {K_NATREC, A, MZ, MS, M}     参数序 = McTT a_natrec A MZ MS M
//   K_PI      {K_PI,   A, B, 0, 0}
//   K_FN      {K_FN,   A, M, 0, 0}
//   K_APP     {K_APP,  M, N, 0, 0}
//   K_VAR     {K_VAR,  N, 0, 0, 0}
//   K_SUB     {K_SUB,  e, s, 0, 0}         (sub e s)：e = exp 子节点，s = sub 节点
// sub 节点（kind 槽同样为 K_SUB，S_kind 存 d 槽）：
//   S_ID      {K_SUB, 0, 0, 0, S_ID}
//   S_WEAKEN  {K_SUB, 0, 0, 0, S_WEAKEN}
//   S_COMPOSE {K_SUB, s1, s2, 0, S_COMPOSE}
//   S_EXTEND  {K_SUB, s, e, 0, S_EXTEND}
// 注意：K_SUB 的 d 槽仅 sub 节点使用；exp 子节点 `(sub e s)` 的 d 槽恒为 0（未用）。
// 遍历约定：从 exp 位置出发的子指针指向 exp 节点；从 sub 位置（K_SUB 的 b 槽、
// S_COMPOSE/S_EXTEND 的 a/b 槽）出发的子指针指向 sub 节点——按位置区分，无歧义。

// ── 常量 ──
K_TYP : int = 0
K_NAT : int = 1
K_ZERO : int = 2
K_SUCC : int = 3
K_NATREC : int = 4
K_PI : int = 5
K_FN : int = 6
K_APP : int = 7
K_VAR : int = 8
K_SUB : int = 9
S_ID : int = 0
S_WEAKEN : int = 1
S_COMPOSE : int = 2
S_EXTEND : int = 3

KERNEL_SLOTS : int = 8192
// 注意：全局常量初始化必须是字面量——表达式（如 8192*8）的 init_val 为 0，
// BSS 槽保持 0（ELF 后端已知限制，曾导致 alloc(0)）。
KERNEL_SLOT_BYTES : int = 65536

// ── 扁平 arena ──
g_kernel_nodes : string, mut          // 64KB 字节缓冲（8192 个 int 槽），惰性分配
g_kernel_buf_ready : int, mut = 0     // 缓冲是否已分配（不能用 str_len 探测 NULL）
g_kernel_count : int, mut = 0         // 已分配节点数（节点 = 五槽一组）

fn kern_ensure_buf():
    if g_kernel_buf_ready == 0:
        g_kernel_nodes = alloc(KERNEL_SLOT_BYTES)
        g_kernel_buf_ready = 1

// 新建节点，返回节点索引（起始槽）；arena 满时返回 -1
fn kern_new(k: int) -> int:
    kern_ensure_buf()
    if g_kernel_count * 5 + 5 > KERNEL_SLOTS:
        return -1
    i := g_kernel_count * 5
    w64(g_kernel_nodes, i * 8, k)
    w64(g_kernel_nodes, (i + 1) * 8, 0)
    w64(g_kernel_nodes, (i + 2) * 8, 0)
    w64(g_kernel_nodes, (i + 3) * 8, 0)
    w64(g_kernel_nodes, (i + 4) * 8, 0)
    g_kernel_count = g_kernel_count + 1
    return i

fn kern_set(n: int, slot: int, v: int):
    if n < 0:
        return
    // arena 满（kern_new = -1）时防静默覆盖节点 0
    w64(g_kernel_nodes, (n + slot) * 8, v)

fn kern_get(n: int, slot: int) -> int:
    if n < 0:
        return -1
    return r64(g_kernel_nodes, (n + slot) * 8)

// ── 解析状态 ──
g_kernel_parse_pos : int, mut = 0
g_kernel_parse_text : string, mut

fn kp_len() -> int:
    return str_len(g_kernel_parse_text)

fn kp_skip_ws():
    loop:
        if g_kernel_parse_pos >= kp_len():
            break
        c := load8(g_kernel_parse_text, g_kernel_parse_pos)
        if c == 32 || c == 9 || c == 10 || c == 13:
            g_kernel_parse_pos = g_kernel_parse_pos + 1
        else:
            break

// 当前位置的记号名与 name 逐字节比较（不移动位置）
fn kp_name_is(name: string) -> int:
    nl := str_len(name)
    if g_kernel_parse_pos + nl > kp_len():
        return 0
    i : int, mut = 0
    loop:
        if i >= nl:
            break
        if load8(g_kernel_parse_text, g_kernel_parse_pos + i) != load8(name, i):
            return 0
        i = i + 1
    // 名字后必须是分隔符（空白 / ( / ) / 结束），防止 (natx) 误匹配 (nat)
    if g_kernel_parse_pos + nl >= kp_len():
        return 1
    c := load8(g_kernel_parse_text, g_kernel_parse_pos + nl)
    if c == 32 || c == 9 || c == 10 || c == 13 || c == 40 || c == 41:
        return 1
    return 0

// 解析非负十进制整数；无数字返回 -1
fn kp_num() -> int:
    start := g_kernel_parse_pos
    loop:
        if g_kernel_parse_pos >= kp_len():
            break
        c := load8(g_kernel_parse_text, g_kernel_parse_pos)
        if c >= 48 && c <= 57:
            g_kernel_parse_pos = g_kernel_parse_pos + 1
        else:
            break
    if g_kernel_parse_pos == start:
        return -1
    v : int, mut = 0
    i : int, mut = start
    loop:
        if i >= g_kernel_parse_pos:
            break
        v = v * 10 + (load8(g_kernel_parse_text, i) - 48)
        i = i + 1
    return v

// 期望当前位置是 'c'（消费它）；否则返回 0
fn kp_expect(c: int) -> int:
    if g_kernel_parse_pos < kp_len() && load8(g_kernel_parse_text, g_kernel_parse_pos) == c:
        g_kernel_parse_pos = g_kernel_parse_pos + 1
        return 1
    return 0

// 名字匹配并前进：当前位置的记号名 == name 则消费并返回 1
fn kp_take_name(name: string) -> int:
    if kp_name_is(name) == 0:
        return 0
    g_kernel_parse_pos = g_kernel_parse_pos + str_len(name)
    return 1

// <exp> ::= (typ N) | (nat) | (zero) | (succ <exp>) | (natrec <exp> <exp> <exp> <exp>)
//         | (pi <exp> <exp>) | (fn <exp> <exp>) | (app <exp> <exp>)
//         | (var N) | (sub <exp> <sub>)
// 注意：if-else 链各分支必须以同类型语句收尾（赋值），统一在链后检查 n < 0。
fn parse_exp() -> int:
    kp_skip_ws()
    if kp_expect(40) == 0:
        return -1
    // '('
    kp_skip_ws()
    n : int, mut = -1
    if kp_take_name("typ") != 0:
        kp_skip_ws()
        v := kp_num()
        if v >= 0:
            n = kern_new(K_TYP)
        if n >= 0:
            kern_set(n, 1, v)
    else if kp_take_name("natrec") != 0:
        e1 := parse_exp()
        e2 := parse_exp()
        e3 := parse_exp()
        e4 := parse_exp()
        if e1 >= 0 && e2 >= 0 && e3 >= 0 && e4 >= 0:
            n = kern_new(K_NATREC)
        if n >= 0:
            kern_set(n, 1, e1)
            kern_set(n, 2, e2)
            kern_set(n, 3, e3)
            kern_set(n, 4, e4)
    else if kp_take_name("nat") != 0:
        n = kern_new(K_NAT)
    else if kp_take_name("zero") != 0:
        n = kern_new(K_ZERO)
    else if kp_take_name("succ") != 0:
        e := parse_exp()
        if e >= 0:
            n = kern_new(K_SUCC)
        if n >= 0:
            kern_set(n, 1, e)
    else if kp_take_name("pi") != 0:
        e1 := parse_exp()
        e2 := parse_exp()
        if e1 >= 0 && e2 >= 0:
            n = kern_new(K_PI)
        if n >= 0:
            kern_set(n, 1, e1)
            kern_set(n, 2, e2)
    else if kp_take_name("fn") != 0:
        e1 := parse_exp()
        e2 := parse_exp()
        if e1 >= 0 && e2 >= 0:
            n = kern_new(K_FN)
        if n >= 0:
            kern_set(n, 1, e1)
            kern_set(n, 2, e2)
    else if kp_take_name("app") != 0:
        e1 := parse_exp()
        e2 := parse_exp()
        if e1 >= 0 && e2 >= 0:
            n = kern_new(K_APP)
        if n >= 0:
            kern_set(n, 1, e1)
            kern_set(n, 2, e2)
    else if kp_take_name("var") != 0:
        kp_skip_ws()
        v := kp_num()
        if v >= 0:
            n = kern_new(K_VAR)
        if n >= 0:
            kern_set(n, 1, v)
    else if kp_take_name("sub") != 0:
        e := parse_exp()
        s := parse_sub()
        if e >= 0 && s >= 0:
            n = kern_new(K_SUB)
        if n >= 0:
            kern_set(n, 1, e)
            kern_set(n, 2, s)
    else:
        n = -1
    if n < 0:
        return -1
    kp_skip_ws()
    if kp_expect(41) == 0:
        return -1
    // ')'
    return n

// <sub> ::= (id) | (weaken) | (compose <sub> <sub>) | (extend <sub> <exp>)
fn parse_sub() -> int:
    kp_skip_ws()
    if kp_expect(40) == 0:
        return -1
    kp_skip_ws()
    n : int, mut = -1
    if kp_take_name("id") != 0:
        n = kern_new(K_SUB)
        if n >= 0:
            kern_set(n, 4, S_ID)
    else if kp_take_name("weaken") != 0:
        n = kern_new(K_SUB)
        if n >= 0:
            kern_set(n, 4, S_WEAKEN)
    else if kp_take_name("compose") != 0:
        s1 := parse_sub()
        s2 := parse_sub()
        if s1 >= 0 && s2 >= 0:
            n = kern_new(K_SUB)
        if n >= 0:
            kern_set(n, 1, s1)
            kern_set(n, 2, s2)
            kern_set(n, 4, S_COMPOSE)
    else if kp_take_name("extend") != 0:
        s := parse_sub()
        e := parse_exp()
        if s >= 0 && e >= 0:
            n = kern_new(K_SUB)
        if n >= 0:
            kern_set(n, 1, s)
            kern_set(n, 2, e)
            kern_set(n, 4, S_EXTEND)
    else:
        n = -1
    if n < 0:
        return -1
    kp_skip_ws()
    if kp_expect(41) == 0:
        return -1
    return n

// ── 公开接口 ──

// kernel_parse(text) -> int：解析单个 <exp> 的 S-表达式文本，返回根节点索引；
// 失败返回 -1。每次调用重置 arena（g_kernel_count = 0）。
fn kernel_parse(text: string) -> int:
    g_kernel_count = 0
    g_kernel_parse_text = text
    g_kernel_parse_pos = 0
    idx := parse_exp()
    if idx < 0:
        return -1
    kp_skip_ws()
    if g_kernel_parse_pos < kp_len():
        return -1
    // 尾部多余内容
    return idx

// 按协议打印 sub 节点
fn print_sub(n: int) -> string:
    sk := kern_get(n, 4)
    if sk == S_ID:
        return "(id)"
    if sk == S_WEAKEN:
        return "(weaken)"
    if sk == S_COMPOSE:
        return "(compose " + print_sub(kern_get(n, 1)) + " " + print_sub(kern_get(n, 2)) + ")"
    if sk == S_EXTEND:
        return "(extend " + print_sub(kern_get(n, 1)) + " " + kern_print_rec(kern_get(n, 2)) + ")"
    return "(?)"

// 按协议打印 exp 节点
fn kern_print_rec(idx: int) -> string:
    k := kern_get(idx, 0)
    if k == K_TYP:
        return "(typ " + int_str(kern_get(idx, 1)) + ")"
    if k == K_NAT:
        return "(nat)"
    if k == K_ZERO:
        return "(zero)"
    if k == K_SUCC:
        return "(succ " + kern_print_rec(kern_get(idx, 1)) + ")"
    if k == K_NATREC:
        return "(natrec " + kern_print_rec(kern_get(idx, 1)) + " " + kern_print_rec(kern_get(idx, 2)) + " " + kern_print_rec(kern_get(idx, 3)) + " " + kern_print_rec(kern_get(idx, 4)) + ")"
    if k == K_PI:
        return "(pi " + kern_print_rec(kern_get(idx, 1)) + " " + kern_print_rec(kern_get(idx, 2)) + ")"
    if k == K_FN:
        return "(fn " + kern_print_rec(kern_get(idx, 1)) + " " + kern_print_rec(kern_get(idx, 2)) + ")"
    if k == K_APP:
        return "(app " + kern_print_rec(kern_get(idx, 1)) + " " + kern_print_rec(kern_get(idx, 2)) + ")"
    if k == K_VAR:
        return "(var " + int_str(kern_get(idx, 1)) + ")"
    if k == K_SUB:
        return "(sub " + kern_print_rec(kern_get(idx, 1)) + " " + print_sub(kern_get(idx, 2)) + ")"
    return "(?)"

// kernel_print(idx) -> string：节点 → 协议 S-表达式文本
fn kernel_print(idx: int) -> string:
    return kern_print_rec(idx)

