// === x86_mapping.cr ===
// Classic x86-64 mapping for value extents and slot strides.
// This file is target-owned; the semantic front end only calls the mp_*
// interface in src/compiler/mapping.cr. A non-classic target replaces this
// implementation without changing the IR passes.

X86_MP_WORD_BYTES : int = 8
X86_MP_SLICE_BYTES : int = 16

// Value size in bytes.
fn x86_mp_size(ti: int) -> int:
    if ti == TI_DEX_S:
        return X86_MP_WORD_BYTES
    // TI_DEX_S uses an 8-byte slot and is not in the type table. Row 8 is a
    // placeholder; user types start at 9.
    if ti == TI_CHAR:
        return 4
    // not in type table
    if ti < 0 || ti >= g_type_count:
        return X86_MP_WORD_BYTES
    k := get_type_kind(ti)
    if k == TYP_BASE:
        d := get_type_data(ti)
        if d == TY_INT:
            return X86_MP_WORD_BYTES
        if d == TY_DEX:
            return X86_MP_WORD_BYTES
        if d == TY_BOOL:
            return 1
        if d == TY_STRING:
            return X86_MP_WORD_BYTES
        if d == TY_UNIT:
            return 0
        if d == TY_CHAR:
            return 4
        return X86_MP_WORD_BYTES
    if k == TYP_ARRAY:
        elem := get_type_data(ti)
        cnt := get_type_extra(ti)
        return x86_mp_size(elem) * cnt
    if k == TYP_PTR || k == TYP_REF:
        return X86_MP_WORD_BYTES
    if k == TYP_SLICE:
        return X86_MP_SLICE_BYTES
    if k == TYP_NAMED:
        name_ni := get_type_data(ti)
        si : ., mut = 0
        loop:
            if si >= g_struct_count:
                break
            if si_name(si) == name_ni:
                return x86_mp_extent(si_field_count(si), TI_INT)
            si = si + 1
        return X86_MP_WORD_BYTES
    return X86_MP_WORD_BYTES

// Value alignment in bytes.
fn x86_mp_align(ti: int) -> int:
    if ti == TI_DEX_S:
        return X86_MP_WORD_BYTES
    // TI_DEX_S has 8-byte alignment and is not in the type table. Row 8 is a
    // placeholder.
    if ti == TI_CHAR:
        return 4
    if ti < 0 || ti >= g_type_count:
        return X86_MP_WORD_BYTES
    k := get_type_kind(ti)
    if k == TYP_BASE:
        d := get_type_data(ti)
        if d == TY_INT:
            return X86_MP_WORD_BYTES
        if d == TY_DEX:
            return X86_MP_WORD_BYTES
        if d == TY_BOOL:
            return 1
        if d == TY_STRING:
            return X86_MP_WORD_BYTES
        if d == TY_CHAR:
            return 4
        return X86_MP_WORD_BYTES
    if k == TYP_ARRAY:
        return x86_mp_align(get_type_data(ti))
    if k == TYP_PTR || k == TYP_REF:
        return X86_MP_WORD_BYTES
    if k == TYP_SLICE:
        return X86_MP_WORD_BYTES
    if k == TYP_NAMED:
        return X86_MP_WORD_BYTES
    return X86_MP_WORD_BYTES

// Slot stride for an array element or an indexed pointer.
fn x86_mp_stride(ti: int) -> int:
    return X86_MP_WORD_BYTES

// Size of a block containing count slots.
fn x86_mp_extent(count: int, ti: int) -> int:
    return count * x86_mp_stride(ti)

// Byte offset of an indexed slot.
fn x86_mp_offset(index: int, ti: int) -> int:
    return index * x86_mp_stride(ti)

// Byte offset of a struct field.
fn x86_mp_field_offset(field_index: int) -> int:
    return field_index * X86_MP_WORD_BYTES
