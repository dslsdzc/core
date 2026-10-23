// === regalloc-consistency.cr ===
// Register allocator correctness contract.
//
// This file is a documentation comment, not a compilation unit. It states the
// allocator's logical obligations over Core's entry, live-interval, and coexist
// model and maps each obligation to its implementation. The verifier lives in
// regalloc.cr and is not duplicated here.
//
// Three separate concerns:
// - program logic: #check and #ensure in .corespec files, checked by a verifier;
// - allocator correctness: this contract, with optimality proofs left for later;
// - run-time self-check: verify_regalloc_consistency in regalloc.cr, run by
//   corearch in the O2 path.
//
// Definitions:
// - entry: one IR variable and one version; each definition creates a version.
//   def = -1 marks a parameter or an entry with no definition.
// - live interval: the closed instruction range [live_start, live_end] in global
//   instruction order.
// - coexist: two entries whose intervals intersect. The relation is symmetric
//   and not transitive.
// - location: the physical home of an entry, either a register or a home slot.
//   Allocation results are REG_ASSIGN var-to-register pairs in g_opt_meta. The
//   backend resolves a register through the E2_REG_SLOT_BASE + reg sentinel.
// - allocation result: REG_ASSIGN pairs computed by corearch in-process.
//
// Correctness obligations, mapped to src/arch/x86_64/regalloc.cr:
// 1. Coexist exclusion: entries in the same location do not coexist.
//    Rule 1 in verify_regalloc_consistency sorts entries and tracks the maximum
//    live_end per location in one pass, avoiding a quadratic pairwise check.
// 2. No stale read: every read sees the live version.
//    Rule 2 uses rl_rule2_func. Its coverage obligation begins after the first
//    versioned definition and includes memory objects created by ALLOC_ARRAY and
//    ALLOC_STRUCT.
// 3. Eviction pairing: an evicted entry needs a matching write-back. The rule is
//    stated but not yet implemented; there is no eviction today, because more
//    than five coexisting entries stay on the stack, so there are no events to
//    check.
// 4. Call invalidation: caller-saved entries at a call site must be invalidated
//    or saved. This also waits for caller-saved annotations.
//
// The --inject-* channels prove that verification consumes real data: rules 1
// and 2 produce diagnostics. Eviction and caller-saved checks depend on allocator
// features, not on a separate deferred layer.
//
// Known gaps:
// - Entries and intervals use textual ranges, not CFG liveness. RegionCheck will
//   tighten this when it is connected.
// - pass_stack_share is disabled. The original implementation produced dead
//   output and corearch always ran it empty. Restoring it requires an alloc-based
//   implementation at the same seam.
// - param_ents is -1. Redefined parameters have no incoming-version entry
//   because the tail pass only adds an entry when prev[lv] < 0. The .ccr no
//   longer stores param_ents, and the old targeted tests were removed with the
//   ENT carrier. Incoming-version entries can return if rule 2 needs them.
// - entries_coexist now rejects an out-of-range upper bound; the check was added
//   in entries_coexist and the --inject-coexist-oob probe moved to corearch.
//
// Reference implementation, the only source of truth; do not copy code here:
//   src/arch/x86_64/regalloc.cr contains compute_live_ranges, compute_entries,
//   entries_coexist, coexist_version_conflicts, verify_regalloc_consistency, and
//   alloc_registers (context-greedy allocation).
//   grammar/corespec.ebnf defines the program-logic specification language. Its
//   SpecImplies production is unrelated to this file.
