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
