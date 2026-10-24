// === mapping.cr ===
// Target-neutral mapping interface for value extents and slot strides.
// The classic x86-64 implementation lives in
// src/arch/x86_64/x86_mapping.cr. This is the projection-side interface:
// corearch and the target descriptor call it. The semantic frontend
// (ir_gen / ptr_analysis / provenance_verify / ccr_lower) must not call it and
// does not carry widths, strides, or byte extents in the v10 wire.

fn mp_size(ti: int) -> int:
    return x86_mp_size(ti)

fn mp_align(ti: int) -> int:
    return x86_mp_align(ti)

fn mp_stride(ti: int) -> int:
    return x86_mp_stride(ti)

fn mp_extent(count: int, ti: int) -> int:
    return x86_mp_extent(count, ti)

fn mp_offset(index: int, ti: int) -> int:
    return x86_mp_offset(index, ti)

fn mp_field_offset(field_index: int) -> int:
    return x86_mp_field_offset(field_index)
