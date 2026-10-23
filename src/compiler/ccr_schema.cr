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
// imply no machine convention. ccr_io.cr writes this schema; v9 is rejected.

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

// v10 header flags (spec §3.1). They describe program properties only; no bit
// carries raw-int, external-binary-interface, or target identity.
//   bit 0 PORTABLE   no raw/FFI/external-binary boundary
//   bit 1 SYSTEM     contains a system boundary node (or raw-int build mode)
//   bit 2 CONCURRENT contains concurrency/execution-policy nodes
//   bit 3+ reserved, must be zero
CCR_FLAG_PORTABLE : int = 1
CCR_FLAG_SYSTEM : int = 2
CCR_FLAG_CONCURRENT : int = 4
CCR_FLAG_KNOWN_MASK : int = 7

// v10 NOD semantic flags. These are node features, not target facts: no bit
// carries a machine extent or physical location. corearch reconstructs those
// from the semantic type and the active target layout.
//   bit 0  IR_BOUNDS_CHECK: bound is a runtime value (legacy tk == 1)
//   bit 1  IR_SPAWN: dynamic spawn (legacy tk == -1)
//   bit 2  IR_DEREF/IR_STORE_PTR: runtime allocation bound is present
CCR_NOD_FLAG_DYNAMIC_LIMIT : int = 1
CCR_NOD_FLAG_DYNAMIC_SPAWN : int = 2
CCR_NOD_FLAG_RUNTIME_PTR_BOUNDS : int = 4
CCR_NOD_FLAG_KNOWN_MASK : int = 7
