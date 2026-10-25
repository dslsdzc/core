// === iface_registry.cr ===
// Intrinsic interface entry table and iface_* query API.
//
// 16 entries: 8 primitive atoms, then product, sequence, ref, ptr, named, null,
// sum, and fn. Table content is static: atom id, canonical type row, registered
// name, literal code, and operation bit set. It does not allocate g_types rows and
// does not cache row numbers.
//
// AK and TI indices are not 1:1: AK_STRING=2 while TI_STR=3, and AK_BOOL=3 while
// TI_BOOL=2. Every entry writes both columns by semantic mapping; never pass one
// index as the other.
//
// Declaration order: this file is after checker.cr in the manifest. Functions can
// be referenced forward from checker.cr; variables and constants cannot. ESZ_ and
// OFF_ constants here are visible only to this file and files after it. IP_*
// constants used by checker.cr live in globals.cr.
//
// Layout constants ESZ_IFACE_ENTRY, OFF_IE_*, and IFACE_ENTRY_COUNT live in
// dyn_arr.cr because the corearch IFACE loader rebuilds this table.

// Entry layout: 40B, five i64 fields {ak, ti_row, name_ni, lit_code, ops}.
//   ak: atom class (AK_* in type_engine.cr).
//   ti_row: canonical checker type row (TI_INT..TI_DYN for primitives; -1 for
//   structural or named atoms).
//   name_ni: registered name intern index, or -1 if absent.
//   lit_code: AST literal kind (EXPR_INT, EXPR_DEX, EXPR_STRING, EXPR_BOOL,
//   EXPR_CHAR) or -1 when the atom has no literal.
//   ops: operation permission bits.
// The table is a flat i64 buffer, like g_types and type terms.
// 位构造（乘 2 循环，照既有 dyn_set_type 惯例，本语言无移位运算符）。下标语义见 globals.cr
// 的 IP_* 块；n ≥ 63 时 i64 负号翻转（= 全位命中）由 `iface_permits` 的越界检查拒绝，本函数只
// 供表内已知常量使用，不做校验（表内容 = 常量，n 恒 < 32）。
fn iface_bit(n: int) -> int:
    b : ., mut = 1
    k : ., mut = n
    loop:
        if k <= 0:
            break
        b = b * 2
        k = k - 1
    return b

// ─── 建表（由 init_types() 尾部调用；幂等）───
// Build the table once, idempotently. Contents are constants plus registered
// names; no type table reads and no cached row numbers. Long-lived processes call
// init_types per request, and str_intern is idempotent for the same string.
fn iface_registry_init():
    if g_iface_registry_ok != 0:
        return
    // 幂等（内容恒定，无需重建）
    g_iface_entries = alloc(IFACE_ENTRY_COUNT * ESZ_IFACE_ENTRY)
    g_iface_entry_count = IFACE_ENTRY_COUNT
    // Operation bit sets.
    // Arithmetic is only int and dex. The checker handles string concatenation and
    // pointer arithmetic in earlier result rules, so those classes are not in this
    // set.
    o_arith := iface_bit(OP_ADD) + iface_bit(OP_SUB) + iface_bit(OP_MUL) + iface_bit(OP_DIV) + iface_bit(OP_MOD)
    // Logic is int and bool. Dex is rejected.
    o_logic := iface_bit(OP_AND) + iface_bit(OP_OR)
    // Comparison, unary, and conversion are permitted for all original classes
    // because the checker has no rejection path there. These are audit bits, not
    // gates.
    o_cmp := iface_bit(OP_EQ) + iface_bit(OP_NE) + iface_bit(OP_LT) + iface_bit(OP_GT) + iface_bit(OP_LE) + iface_bit(OP_GE)
    o_un := iface_bit(IP_UOP_BIAS + UOP_NEG) + iface_bit(IP_UOP_BIAS + UOP_NOT) + iface_bit(IP_UOP_BIAS + UOP_REF) + iface_bit(IP_UOP_BIAS + UOP_DEREF)
    o_base := o_cmp + o_un + iface_bit(IP_AS)
    // if and while both accept bool only.
    o_cond := iface_bit(IP_COND)
    // 8 primitive atoms. ti_row uses TI_* constants; bool and string are written
    // by semantic mapping, not by index order.
    // INT: arithmetic and logic. No condition.
    iface_put(0, AK_INT, TI_INT, str_intern("int"), EXPR_INT, o_base + o_arith + o_logic)
    // DEX: arithmetic only. No logic or condition.
    iface_put(1, AK_DEX, TI_DEX, str_intern("dex"), EXPR_DEX, o_base + o_arith)
    // STRING: no arithmetic, logic, or condition. Index is permitted.
    iface_put(2, AK_STRING, TI_STR, str_intern("string"), EXPR_STRING, o_base + iface_bit(IP_INDEX))
    // BOOL: logic and the condition gate.
    iface_put(3, AK_BOOL, TI_BOOL, str_intern("bool"), EXPR_BOOL, o_base + o_logic + o_cond)
    iface_put(4, AK_UNIT, TI_UNIT, str_intern("unit"), -1, o_base)
    iface_put(5, AK_NEVER, TI_NEVER, str_intern("never"), -1, o_base)
    iface_put(6, AK_CHAR, TI_CHAR, str_intern("char"), EXPR_CHAR, o_base)
    // DYN: base plus a method audit bit. The method path is not wired to this bit.
    iface_put(7, AK_DYN, TI_DYN, str_intern("dyn"), -1, o_base + iface_bit(IP_METHOD))
    // Structural and named atoms use ti_row = -1 (class level, no canonical row).
    // PRODUCT: base plus a field audit bit. The field path is not wired.
    iface_put(8, AK_PRODUCT, -1, str_intern("product"), -1, o_base + iface_bit(IP_FIELD))
    // SEQUENCE: base plus index and index-range bits. Index is wired; range is an
    // audit bit because the non-array range fallthrough has no diagnostic.
    iface_put(9, AK_SEQUENCE, -1, str_intern("sequence"), -1, o_base + iface_bit(IP_INDEX) + iface_bit(IP_INDEX_RANGE))
    // REF and PTR: base only. Pointer arithmetic is handled by earlier result
    // rules in the checker.
    iface_put(10, AK_REF, -1, str_intern("ref"), -1, o_base)
    iface_put(11, AK_PTR, -1, str_intern("ptr"), -1, o_base)
    // NAMED: base plus field and method audit bits. Neither path is wired.
    iface_put(12, AK_NAMED, -1, str_intern("named"), -1, o_base + iface_bit(IP_FIELD) + iface_bit(IP_METHOD))
    // NULL, SUM, and FN are class-level atoms with no canonical row, no literal,
    // and no operation permissions. They add queryability, not new row mapping.
    iface_put(13, AK_NULL, -1, str_intern("null"), -1, 0)
    iface_put(14, AK_SUM, -1, str_intern("sum"), -1, 0)
    iface_put(15, AK_FN, -1, str_intern("fn"), -1, 0)
    g_iface_registry_ok = 1

// Write one entry row. All table writes go through this function.
fn iface_put(e: int, ak: int, ti: int, name_ni: int, lit_code: int, ops: int):
    cell_store(g_iface_entries, e * ESZ_IFACE_ENTRY + OFF_IE_AK, ak)
    cell_store(g_iface_entries, e * ESZ_IFACE_ENTRY + OFF_IE_TI, ti)
    cell_store(g_iface_entries, e * ESZ_IFACE_ENTRY + OFF_IE_NAME, name_ni)
    cell_store(g_iface_entries, e * ESZ_IFACE_ENTRY + OFF_IE_LIT, lit_code)
    cell_store(g_iface_entries, e * ESZ_IFACE_ENTRY + OFF_IE_OPS, ops)

// Ensure the table exists. init_types builds it, but a query may run earlier in a
// self-test or future call site; reading an empty table would walk out of bounds.
fn iface_ensure():
    if g_iface_registry_ok == 0:
        iface_registry_init()

// ─── 查询 API（spec 2.5）───
fn iface_count() -> int:
    return IFACE_ENTRY_COUNT

// 原子类 -> 条目记录号（-1 = 无此原子）
fn iface_entry(ak: int) -> int:
    iface_ensure()
    i : ., mut = 0
    loop:
        if i >= g_iface_entry_count:
            break
        if cell_load(g_iface_entries, i * ESZ_IFACE_ENTRY + OFF_IE_AK) == ak:
            return i
        i = i + 1
    return -1

// 操作许可位集（spec 2.5 的签名）；-1/未知原子 -> 全 0 = 无许可
fn iface_ops(ak: int) -> int:
    e := iface_entry(ak)
    if e < 0:
        return 0
    return cell_load(g_iface_entries, e * ESZ_IFACE_ENTRY + OFF_IE_OPS)

// Bit test. op already includes the UOP or IP bias. Out-of-range indices return 0;
// they must not wrap, because the multiply-by-two construction would make a
// negative i64 with all bits set.
fn iface_permits(ak: int, op: int) -> int:
    if op < 0:
        return 0
    if op > 62:
        return 0
    ops := iface_ops(ak)
    if ops == 0:
        return 0
    bit : ., mut = 1
    k : ., mut = op
    loop:
        if k <= 0:
            break
        bit = bit * 2
        k = k - 1
    if (ops / bit) % 2 != 0:
        return 1
    return 0

// 字面量 AST kind -> 条目记录号（-1 = 非字面量 kind）。查表键 = 条目的 lit_code 列
// （13 条线性扫；AST kind 范围只有 5 个命中项）。lit_kind < 0 = 条目的无字面量哨兵，
// 必须先行拒绝（否则 -1 会把无字面量的条目当成命中）。
fn iface_lit_entry(lit_kind: int) -> int:
    if lit_kind < 0:
        return -1
    iface_ensure()
    i : ., mut = 0
    loop:
        if i >= g_iface_entry_count:
            break
        if cell_load(g_iface_entries, i * ESZ_IFACE_ENTRY + OFF_IE_LIT) == lit_kind:
            return i
        i = i + 1
    return -1

// Literal AST kind to TI_* (return -1 for non-literal kinds). This table is the
// single source for the five literal branches in infer_expr.
fn iface_lit_ti(lit_kind: int) -> int:
    e := iface_lit_entry(lit_kind)
    if e < 0:
        return -1
    return cell_load(g_iface_entries, e * ESZ_IFACE_ENTRY + OFF_IE_TI)

// 字面量 AST kind -> AK_*（同上；交叉断言/引擎侧用）
fn iface_lit_ak(lit_kind: int) -> int:
    e := iface_lit_entry(lit_kind)
    if e < 0:
        return -1
    return cell_load(g_iface_entries, e * ESZ_IFACE_ENTRY + OFF_IE_AK)

// TY_* base type code to AK_* atom class. This is the single implementation.
// TY_DEX_S maps to AK_DEX: the representation difference is not part of type
// identity. TY_GENERIC_PARAM maps to AK_NAMED and is not expanded.
fn iface_by_ty_code(ty: int) -> int:
    if ty == TY_INT:
        return AK_INT
    if ty == TY_DEX:
        return AK_DEX
    if ty == TY_DEX_S:
        return AK_DEX
    if ty == TY_BOOL:
        return AK_BOOL
    if ty == TY_STRING:
        return AK_STRING
    if ty == TY_UNIT:
        return AK_UNIT
    if ty == TY_NEVER:
        return AK_NEVER
    if ty == TY_CHAR:
        return AK_CHAR
    if ty == TY_GENERIC_PARAM:
        return AK_NAMED
    return -1

// TY_* base type code to TI_* type-row constant. Return -1 when there is no
// mapping; callers choose their own fallback.
// Indices are written by semantic mapping, never by value: AK and TI indices are
// not 1:1. The TY_GENERIC_PARAM code 7 collides numerically with TI_DYN 7; the
// dyn branch is reachable and maps to TI_DYN. TY_DEX_S is not in the table and
// falls through to the caller's fallback.
fn ty_code_to_ti(ty: int) -> int:
    if ty == TY_INT:
        return TI_INT
    if ty == TY_DEX:
        return TI_DEX
    if ty == TY_BOOL:
        return TI_BOOL
    if ty == TY_STRING:
        return TI_STR
    if ty == TY_UNIT:
        return TI_UNIT
    if ty == TY_NEVER:
        return TI_NEVER
    if ty == TY_CHAR:
        return TI_CHAR
    if ty == TI_DYN:
        return TI_DYN
    // ← 现状原样：7 = TY_GENERIC_PARAM 的数值撞车格（见头注）
    return -1

// iface_kind_of lives in iface_axis.cr to keep the linkage surface clean.

// 原子类 -> 规范行（8 原生 = TI_*；结构/命名条目 ti_row = -1 -> 恒 -1）
fn iface_ti_of(ak: int) -> int:
    e := iface_entry(ak)
    if e < 0:
        return -1
    return cell_load(g_iface_entries, e * ESZ_IFACE_ENTRY + OFF_IE_TI)

// Atom class to registered name intern index (-1 if absent). This is a read-only
// query; it never calls str_intern, so the judgment and query paths add no new
// strings.
fn iface_name_of(ak: int) -> int:
    e := iface_entry(ak)
    if e < 0:
        return -1
    return cell_load(g_iface_entries, e * ESZ_IFACE_ENTRY + OFF_IE_NAME)

// Cross-cutting shape entries for iface_satisfies axis A.
// Each shape entry maps an interned name to a type term. Satisfaction is the
// inclusion judgment ty_sub(term, shape), using the same engine as the intrinsic
// and user axes.
// The table is the single data source for shape entries. It does not allocate
// g_types rows and is not serialized into .ccr. Registration takes an already
// interned name; lookup never calls str_intern.
// The count is cleared by reset_frontend_state and capacity is reused. Registering
// the same name again overwrites the term and does not grow the table.
// Register a shape entry and return its row, or -1 for invalid arguments.
// Negative names and terms are rejected; they are not valid sentinels because
// lookup would confuse them with an empty slot.
fn iface_shape_register(name_ni: int, term: int) -> int:
    if name_ni < 0:
        return -1
    if term < 0:
        return -1
    i : ., mut = 0
    loop:
        if i >= g_iface_shape_count:
            break
        if cell_load(g_iface_shape_names, i * 8) == name_ni:
            cell_store(g_iface_shape_terms, i * 8, term)   // 覆盖（幂等重注册）
            return i
        i = i + 1
    iface_shape_grow(g_iface_shape_count + 1)
    cell_store(g_iface_shape_names, g_iface_shape_count * 8, name_ni)
    cell_store(g_iface_shape_terms, g_iface_shape_count * 8, term)
    g_iface_shape_count = g_iface_shape_count + 1
    return g_iface_shape_count - 1

// 查询：名字 ni -> 形状项（-1 = 未注册/参数非法）
fn iface_shape_lookup(name_ni: int) -> int:
    if name_ni < 0:
        return -1
    i : ., mut = 0
    loop:
        if i >= g_iface_shape_count:
            return -1
        if cell_load(g_iface_shape_names, i * 8) == name_ni:
            return cell_load(g_iface_shape_terms, i * 8)
        i = i + 1
    return -1

fn iface_shape_count() -> int:
    return g_iface_shape_count

// Clear the shape table. This is for self-tests: registrations are process-wide
// globals, and tests reset them so entries do not leak into later cases or
// compilations. Production resets through reset_frontend_state.
fn iface_shape_reset():
    g_iface_shape_count = 0

// Type term to AK_* for a single atom (-1 if not a single atom; a top-k term
// returns its k). Reject negative and out-of-range rows first: tt_* accessors have
// no range guard, so -1 would read before the table.
fn iface_of_term(t: int) -> int:
    if t < 0:
        return -1
    if t >= tt_count():
        return -1
    tg := tt_tag(t)
    if tg == TT_ATOM:
        return tt_a(t)
    if tg == TT_TOP_K:
        return tt_a(t)
    return -1                                     // union/inter/not/bot/top/mu/var/nil/cons

// Cross-cutting shape terms.
// Each shape entry is one type term, and satisfaction is T <: shape. These six
// constructors are the single construction point; the name side registers through
// iface_shape_register.
// Do not write sequence<⊤> as a parameter chain: AK_SEQUENCE slot 0 is invariant
// because arrays and slices are writable, so an invariant slot containing ⊤
// returns -1. Use the class form ⊤k(AK_SEQUENCE) instead.
// Constructors never call str_intern; the terms only enter the append-only type
// term DAG.
fn sh_shape_seq() -> int:
    return tt_top_k(AK_SEQUENCE)

// Read-only sequence: the sequence body plus the read-only view &[T].
// Read-only views are covariant, so &[int] satisfies the shape even though its
// element is not ⊤. The mut marker is part of identity: &mut [T] has a different
// marker and does not satisfy the read-only shape. It also does not satisfy the
// writable shape, whose view face is not expressible.
fn sh_shape_seq_ro() -> int:
    view := tt_atom(AK_REF, -1, tt_cons(sh_ref_mut_marker(0), tt_cons(tt_top_k(AK_SEQUENCE), tt_nil())))
    return tt_union(tt_top_k(AK_SEQUENCE), view)

// Writable sequence: the sequence body. Slices are writable in this language, so
// this is the same term as sequence. Read-only views are AK_REF and do not
// satisfy it.
// The writable view &mut [T] is not expressible: AK_REF slot 1 is invariant on the
// writable side, so ⊤ in that slot returns -1. This shape covers only the body;
// the -1 is not treated as 0 or 1.
fn sh_shape_seq_rw() -> int:
    return tt_top_k(AK_SEQUENCE)

// Indexable: sequence ∪ string. String indexing yields a byte value in the
// checker. The set matches IP_INDEX exactly, so replacing the index fallback gate
// preserves behavior.
fn sh_shape_indexable() -> int:
    return tt_union(tt_top_k(AK_SEQUENCE), tt_top_k(AK_STRING))

// Iterable: sequence (arrays and slices). String is not included because the
// iteration path has no type check: EXPR_FOR only infers the source type and
// ir_gen uses it as a numeric bound, so there is no evidence for string
// iteration.
fn sh_shape_iterable() -> int:
    return tt_top_k(AK_SEQUENCE)

// product = 元组行（AK_PRODUCT）。struct 行 = AK_NAMED（结构项经展开层 / 用户轴）-> 不在首版。
fn sh_shape_product() -> int:
    return tt_top_k(AK_PRODUCT)

// Shape name registration. Six ASCII names are registered: sequence,
// sequence_ro, sequence_rw, indexable, iterable, product.
// Registration happens at the end of init_types, after iface_registry_init. The
// names are interned there, and registering the same name again overwrites the
// term without growing the table. ccr_iface_populate reruns this function after
// reset so the segment content depends only on the type and interface tables, not
// on judgment history.
// Named consumption syntax (for example T: indexable) is not implemented; current
// consumers use iface_satisfies_term without names.
fn iface_shape_builtin_init():
    iface_shape_register(str_intern("sequence"), sh_shape_seq())
    iface_shape_register(str_intern("sequence_ro"), sh_shape_seq_ro())
    iface_shape_register(str_intern("sequence_rw"), sh_shape_seq_rw())
    iface_shape_register(str_intern("indexable"), sh_shape_indexable())
    iface_shape_register(str_intern("iterable"), sh_shape_iterable())
    iface_shape_register(str_intern("product"), sh_shape_product())
