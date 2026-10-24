// src/kernel/term_io.cr: shared S-expression format protocol between text and the
// flat arena.
// Grammar:
//   <exp> ::= (typ N) | (nat) | (zero) | (succ <exp>)
//           | (natrec <exp> <exp> <exp> <exp>)
//           | (pi <exp> <exp>) | (fn <exp> <exp>) | (app <exp> <exp>)
//           | (var N) | (sub <exp> <sub>)
//   <sub> ::= (id) | (weaken) | (compose <sub> <sub>) | (extend <sub> <exp>)
//   N     ::= non-negative decimal integer
// de Bruijn: var 0 is the newest binding at the right end of the context.
//
// Arena layout: g_kernel_nodes is a 64 KiB byte buffer with 8192 int slots. A
// node index is its first slot (0, 5, 10, ...). The backend does not support
// fixed-size array globals, so the buffer is allocated lazily. Slot semantics are
// unchanged: 8192 slots, five per node, and kern_get(n, slot) reads slot n+slot.
// Nodes: {kind, a, b, c, d}.
//   K_TYP     {K_TYP, N, 0, 0, 0}           N is the universe level
//   K_NAT     {K_NAT, 0, 0, 0, 0}
//   K_ZERO    {K_ZERO, 0, 0, 0, 0}
//   K_SUCC    {K_SUCC, e, 0, 0, 0}
//   K_NATREC  {K_NATREC, A, MZ, MS, M}      parameter order from McTT
//   K_PI      {K_PI, A, B, 0, 0}
//   K_FN      {K_FN, A, M, 0, 0}
//   K_APP     {K_APP, M, N, 0, 0}
//   K_VAR     {K_VAR, N, 0, 0, 0}
//   K_SUB     {K_SUB, e, s, 0, 0}           sub expression: e is exp, s is sub
// Sub nodes use K_SUB as kind and store the sub kind in slot d:
//   S_ID      {K_SUB, 0, 0, 0, S_ID}
//   S_WEAKEN  {K_SUB, 0, 0, 0, S_WEAKEN}
//   S_COMPOSE {K_SUB, s1, s2, 0, S_COMPOSE}
//   S_EXTEND  {K_SUB, s, e, 0, S_EXTEND}
// Slot d is used only by sub nodes. A (sub e s) expression leaves d as 0.
// Child pointers from an expression position point to expression nodes; child
// pointers from a sub position point to sub nodes.

// Constants.
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
// Global constant initializers must be literals. An expression such as 8192*8
// reads as 0 in a BSS slot and would allocate zero bytes.
KERNEL_SLOT_BYTES : int = 65536

// Flat arena.
g_kernel_nodes : string, mut          // 64 KiB byte buffer with 8192 int slots, allocated lazily
g_kernel_buf_ready : int, mut = 0     // buffer allocation flag; str_len cannot detect a null pointer
g_kernel_count : int, mut = 0         // allocated node count; each node uses five slots

fn kern_ensure_buf():
    if g_kernel_buf_ready == 0:
        g_kernel_nodes = alloc(KERNEL_SLOT_BYTES)
        g_kernel_buf_ready = 1

// Create a node and return its first slot, or -1 when the arena is full.
fn kern_new(k: int) -> int:
    kern_ensure_buf()
    if g_kernel_count * 5 + 5 > KERNEL_SLOTS:
        return -1
    i := g_kernel_count * 5
    cell_store(g_kernel_nodes, i * 8, k)
    cell_store(g_kernel_nodes, (i + 1) * 8, 0)
    cell_store(g_kernel_nodes, (i + 2) * 8, 0)
    cell_store(g_kernel_nodes, (i + 3) * 8, 0)
    cell_store(g_kernel_nodes, (i + 4) * 8, 0)
    g_kernel_count = g_kernel_count + 1
    return i

fn kern_set(n: int, slot: int, v: int):
    if n < 0:
        return
    // Return early for a failed allocation; writing would overwrite node 0.
    cell_store(g_kernel_nodes, (n + slot) * 8, v)

fn kern_get(n: int, slot: int) -> int:
    if n < 0:
        return -1
    return cell_load(g_kernel_nodes, (n + slot) * 8)

// Parse state.
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

// Compare the token at the current position with name without moving.
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
    // The name must be followed by whitespace, a parenthesis, or end of input, so (natx) does not match (nat).
    if g_kernel_parse_pos + nl >= kp_len():
        return 1
    c := load8(g_kernel_parse_text, g_kernel_parse_pos + nl)
    if c == 32 || c == 9 || c == 10 || c == 13 || c == 40 || c == 41:
        return 1
    return 0

// Parse a non-negative decimal integer. Return -1 when there are no digits.
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

// Consume byte c when present; otherwise return 0.
fn kp_expect(c: int) -> int:
    if g_kernel_parse_pos < kp_len() && load8(g_kernel_parse_text, g_kernel_parse_pos) == c:
        g_kernel_parse_pos = g_kernel_parse_pos + 1
        return 1
    return 0

// Consume name when the token at the current position matches it.
fn kp_take_name(name: string) -> int:
    if kp_name_is(name) == 0:
        return 0
    g_kernel_parse_pos = g_kernel_parse_pos + str_len(name)
    return 1

// Parse one expression. Each branch ends with an assignment so the if-else chain
// has a uniform type; n < 0 is checked after the chain.
fn parse_exp() -> int:
    kp_skip_ws()
    if kp_expect(40) == 0:
        return -1
    // Opening parenthesis.
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
    // Closing parenthesis.
    return n

// Parse one substitution.
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

// Public interface.

// Parse one S-expression and return its root node index, or -1 on failure. Each
// call resets the arena.
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
    // Trailing content after the expression.
    return idx

// Print a sub node in protocol form.
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

// Print an expression node in protocol form.
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

// Print a node as protocol S-expression text.
fn kernel_print(idx: int) -> string:
    return kern_print_rec(idx)

