// === ccr_schema.cr ===
// Record layouts shared by .ccr serialization and the in-memory tables that
// feed it. These constants describe the carrier, not the target machine.

// Type-term entry: six 8-byte fields in memory.
ESZ_TYPE_TERM : int = 48
ESZ_TYPE_TERM_DISK : int = 40
OFF_TT_TAG : int = 0
OFF_TT_A : int = 8
OFF_TT_B : int = 16
OFF_TT_C : int = 24
OFF_TT_D : int = 32
OFF_TT_HASH : int = 40

// Optimization metadata record: header plus up to five register pairs.
OPT_META_STRIDE : int = 64

// ── .ccr v10 wire schema (spec §3) ──────────────────────────────────────
// These constants name wire-format roles and fixed record sizes in the
// carrier file. They are neither language types nor target widths, and they
// imply no machine convention. ccr_io.cr keeps writing v9 (CCR_VERSION)
// until the v10 cutover task.

CCR_V10_VERSION : int = 655360      // 0x000A0000
CCR_V10_SEG_COUNT : int = 9
CCR_V10_SEG_STR : int = 1
CCR_V10_SEG_TYPE : int = 2
CCR_V10_SEG_IFACE : int = 3
CCR_V10_SEG_SYM : int = 4
CCR_V10_SEG_NOD : int = 5
CCR_V10_SEG_ENT : int = 6
CCR_V10_SEG_REG : int = 7
CCR_V10_SEG_EDG : int = 8
CCR_V10_SEG_CASE : int = 9

// Fixed on-disk record sizes for the graph segments.
CCR_V10_NOD_DISK : int = 40
CCR_V10_ENT_DISK : int = 24
CCR_V10_REG_DISK : int = 24
CCR_V10_EDG_DISK : int = 8
CCR_V10_CASE_DISK : int = 24
