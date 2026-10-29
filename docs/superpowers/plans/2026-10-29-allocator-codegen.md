# Allocator 代码生成实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 `alloc` 的机器码从手写字节改成由 Core 源码编译出的 raw blob，并用 clang/LLVM 参考实现做差分验证。

**Architecture:** `src/runtime/alloc_body.cr` 写 raw Core allocator；`tools/gen_alloc_blob.py` 用 Python bootstrap 编译成 `.o`，抽取 `.text/.rodata/.data` 并生成字节 + 全局/调用重定位表；`elf_gen` 发射一个 `movabs rsi, heap_start; jmp body` trampoline，拷贝 blob，回填重定位。C/LLVM 参考实现只用于测试，不进入构建依赖。

**Tech Stack:** Core（自托管编译器）、Python bootstrap、GNU as/ld、clang/LLVM 23、jj。

**Spec:** `docs/superpowers/specs/2026-10-29-allocator-codegen-design.md`

## Global Constraints

- 用 `jj` 管理提交，不用 `git` 直接提交。
- 文档遵循 `docs/doc-style.md`：不用比喻、行话、emoji，不压缩词语。
- allocator body 不得调用 `alloc`、`println`、`str_*` 或任何可能分配的函数。
- allocator body 编译为 raw 语义；不得依赖 tagged BigInt 转换。
- 生成器遇到未定义全局、未定义调用、绝对重定位、TLS、GOT 必须失败，不能静默跳过。
- 不为变绿放宽判据；失败路径必须 trap 并保留 `g_alloc_fail_*` 见证。
- canary 只按编译器身份位移重新锁定，并在值表记录旧值、新值、归因、提交出处。
- 旧的手写 allocator body 在 Task 5 之前保留为 fallback；切换默认前必须完成 simple 和 arena 两套差分测试。

## Review Focus

- `alloc(0)`、`alloc(8)`、`alloc(4088)`、`alloc(4096)`、`alloc(1MB)`、`alloc(64MB)` 的返回地址、隐藏长度头和首尾可写性。
- 1TB 边界：`1TB-1` 走正常路径；`1TB` 和 `1TB+1` 必须 trap，不得返回 0。
- arena 的 pool 上限、slot 64/128 边界、三个以上 mmap extent 的 reset。
- tagged 用户程序中的 BigInt 值经过 allocator 返回的指针和 cell_store/cell_load 后仍保持数学语义。
- trampoline 的 `rsi=heap_start` 和 `jmp body` 在第二次发射后必须指向最终地址；任何一条路径不得少弹或多弹寄存器。

---

### Task 1: Blob 生成器和重定位表

**Files:**
- Create: `tools/gen_alloc_blob.py`
- Create: `tests/selfhost/test_alloc_blob_relocs.py`
- Test: `tests/selfhost/test_alloc_blob_relocs.py`

**Interfaces:**
- Produces: `python3 tools/gen_alloc_blob.py --source FILE --out FILE --summary-json FILE`
- Produces: generated Core file with `ALLOC_BLOB_SIZE`, `ALLOC_BLOB_SIMPLE_OFF`, `ALLOC_BLOB_ARENA_OFF`, `alloc_blob_bytes()`, `alloc_blob_call_count()`, `alloc_blob_call_name(i)`, `alloc_blob_call_off(i)`, `alloc_blob_global_count()`, `alloc_blob_global_name(i)`, `alloc_blob_global_off(i)`.
- Consumes: `bootstrap/corec/frontend/*` and the ELF parser from `tools/gen_bigint_blob.py`.

- [ ] **Step 1: Write the failing generator test**

`tests/selfhost/test_alloc_blob_relocs.py` creates a temp `probe.cr`:

```core
g_heap_ptr : string, mut
fn probe(x: int) -> int:
    g_heap_ptr = ""
    return heap_expand()
```

The generator predeclares `heap_expand` and `arena_grow_pool` as external
functions, so the probe can call `heap_expand` without a Core body.

It runs the generator with `--summary-json`, then asserts:
- summary globals contain `g_heap_ptr`;
- summary calls contain `heap_expand`;
- the generated file contains `ALLOC_BLOB_SIZE`;
- a body containing a local `.bss` global not in the external allowlist fails nonzero.

- [ ] **Step 2: Run the test to verify it fails**

Run: `python3 tests/selfhost/test_alloc_blob_relocs.py`
Expected: FAIL because `tools/gen_alloc_blob.py` does not exist.

- [ ] **Step 3: Implement the generator**

Copy the ELF parser and `build_blob` structure from `tools/gen_bigint_blob.py`. Differences:
- prepend raw `cell_load` / `cell_store` helpers to the source, same as `gen_bigint_blob.py`;
- add `heap_expand` and `arena_grow_pool` to the resolver builtins without definitions;
- treat every `.bss` symbol as an external global, strip the bootstrap `_g_`
  prefix, and record `(name, rel32_offset)`;
- record unresolved function symbols as call relocations;
- reject any other unresolved symbol, absolute relocation, TLS, or GOT;
- emit the generated Core file and the JSON summary.

- [ ] **Step 4: Run the test to verify it passes**

Run: `python3 tests/selfhost/test_alloc_blob_relocs.py`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
jj commit -m "alloc: add blob generator with global and call relocations"
```

---

### Task 2: Simple allocator body 和差分测试

**Files:**
- Create: `src/runtime/alloc_body.cr`
- Create: `tests/harness/alloc_simple_ref.c`
- Create: `tests/harness/alloc_state.c`
- Create: `tests/selfhost/test_alloc_simple_parity.py`
- Test: `tests/selfhost/test_alloc_simple_parity.py`

**Interfaces:**
- Produces: `fn alloc_simple(size: int, heap_start: string, heap_end: string) -> string` in `src/runtime/alloc_body.cr`.
- Produces: generator output `src/runtime/alloc_blob.cr` with a valid `ALLOC_BLOB_SIMPLE_OFF`.
- Consumes: existing globals `g_heap_ptr`, `g_heap_end`; external `heap_expand`.

- [ ] **Step 1: Write the failing parity test**

`tests/selfhost/test_alloc_simple_parity.py`:
- links `tests/harness/alloc_state.c`, which defines `g_heap_ptr`, `g_heap_end`,
  `g_alloc_fail_*`, and `heap_expand` over a 2MB `mmap`;
- compiles `src/runtime/alloc_body.cr` to `.o` via the bootstrap helper;
- links the Core `.o` and `tests/harness/alloc_simple_ref.c` with `clang -O2 -no-pie`;
- runs the size list `0, 1, 7, 8, 15, 16, 3361, 3362, 4088, 4089, 4096, 1MB-8, 1MB, 1MB+8, 64MB-8, 64MB, 64MB+1, 1TB-1, 1TB, 1TB+1, -1`;
- asserts both implementations return the same offset, header, first/last byte behavior, and failure code;
- asserts the generated assembly has no `call alloc`.

- [ ] **Step 2: Run the test to verify it fails**

Run: `python3 tests/selfhost/test_alloc_simple_parity.py`
Expected: FAIL because `alloc_simple` and the reference do not exist.

- [ ] **Step 3: Implement `alloc_simple` and the C reference**

Translate `emit_alloc_body_simple` from `src/format/elf/elf.cr` into raw Core:
- reject `size > 64MB` with a null return;
- align `(size + 15) & -8`;
- load `g_heap_ptr`; if null, set it to `heap_start` and set `g_heap_end` to `heap_start + 1GB`;
- if the new pointer exceeds `g_heap_end`, call `heap_expand`; on failure write the fail witness and `ud2`;
- bump `g_heap_ptr`;
- zero the data bytes with a `store8` loop;
- write the hidden length header at `p - 8`;
- return `p`.

The C reference implements the same algorithm with `unsigned char *`.

- [ ] **Step 4: Run the test to verify it passes**

Run: `python3 tests/selfhost/test_alloc_simple_parity.py`
Expected: PASS for all sizes.

- [ ] **Step 5: Commit**

```bash
jj commit -m "alloc: add raw Core simple allocator body and parity test"
```

---

### Task 3: 把 simple body 接入 elf_gen

**Files:**
- Modify: `src/format/elf/elf.cr`
- Modify: `src/arch/x86_64/backend_globals.cr` if a flag is needed
- Modify: `src/arch/x86_64/corearch.cr` for `--alloc-blob`
- Test: `tests/selfhost/test_alloc_simple_elf.py`

**Interfaces:**
- Consumes: `ALLOC_BLOB_SIMPLE_OFF`, `alloc_blob_bytes()`, `alloc_blob_*` metadata.
- Produces: `--alloc-blob` corearch flag; default off until Task 5.

- [ ] **Step 1: Write the failing ELF test**

`tests/selfhost/test_alloc_simple_elf.py` compiles a program with `corec ccr` and `corearch --alloc-blob --raw-int`; it runs the ELF and checks a sequence of `alloc` calls and header bytes. It also runs the same program without the flag and asserts both return the same exit code.

- [ ] **Step 2: Run the test to verify it fails**

Run: `python3 tests/selfhost/test_alloc_simple_elf.py`
Expected: FAIL because `--alloc-blob` is unknown.

- [ ] **Step 3: Implement the trampoline and blob copy**

In `elf.cr`:
- add `g_alloc_use_blob` and parse `--alloc-blob`;
- update the Phase 2 `total_code` reservation from the old fixed allocator size
  to `trampoline_size + ALLOC_BLOB_SIZE`;
- emit `movabs rsi, heap_start; jmp rel32` at `alloc_start`;
- copy the blob after the trampoline;
- register `alloc`, `alloc_simple` in `g_x86_func_offsets`;
- patch trampoline `heap_start` and `jmp`;
- patch global relocations to `bss_va + 16 + global_off[gv]`;
- patch call relocations to `heap_expand_start`;
- keep the old `emit_alloc_body_simple` when the flag is off.

- [ ] **Step 4: Run the test and the simple canary path**

Run: `python3 tests/selfhost/test_alloc_simple_elf.py`
Run: `bash tools/baseline/canary_check.sh` (old path, must stay green)
Expected: both PASS.

- [ ] **Step 5: Commit**

```bash
jj commit -m "alloc: wire the Core simple allocator blob behind --alloc-blob"
```

---

### Task 4: Arena allocator body 和差分测试

**Files:**
- Modify: `src/runtime/alloc_body.cr`
- Create: `tests/harness/alloc_arena_ref.c`
- Modify: `tests/harness/alloc_state.c` to define the arena globals and `arena_grow_pool`
- Create: `tests/selfhost/test_alloc_arena_parity.py`
- Test: `tests/selfhost/test_alloc_arena_parity.py`

**Interfaces:**
- Produces: `fn alloc_arena(size: int, heap_start: string, heap_end: string) -> string`.
- Produces: `ALLOC_BLOB_ARENA_OFF`.
- Consumes: all arena globals listed in the design, `arena_grow_pool`.

- [ ] **Step 1: Write the failing arena parity test**

The test covers:
- size classes 0, 3361, 3362, 4088, 4089, 4096;
- 1MB, 1MB+8, 64MB-8, 64MB, 64MB+1;
- 70 slots, three 100MB extents, duplicate reset, free-list reuse;
- pool limit 64MB/128MB/192MB, and zero limit;
- `g_alloc_fail_*` witness values for capacity full and mmap failure.

- [ ] **Step 2: Run the test to verify it fails**

Run: `python3 tests/selfhost/test_alloc_arena_parity.py`
Expected: FAIL because `alloc_arena` does not exist.

- [ ] **Step 3: Implement `alloc_arena`**

Translate `emit_alloc_body` from `src/format/elf/elf.cr` into raw Core:
- suspend/ready/scalars gate;
- slot base / slot end / static path;
- class lookup, class chunk carve, bump;
- slot full → `arena_grow_pool` → new slot;
- capacity full witness + `ud2`;
- >1MB contiguous slots;
- >64MB mmap extent and `munmap` chain;
- zero data + hidden header;
- static peak path;
- global bump fallback.

Use `cell_load`/`cell_store` for all metadata. Use `syscall3` for mmap/munmap. Do not call `alloc`.

- [ ] **Step 4: Run the test and the arena suite**

Run: `python3 tests/selfhost/test_alloc_arena_parity.py`
Run: `./build/corec ccr tests/suite/arena_test.cr -o /tmp/a.ccr && ./build/corearch /tmp/a.ccr --alloc-blob -o /tmp/a && /tmp/a`
Run: the same for `arena_boundary_test.cr`, `chunks.cr`, `many_slots.cr`, `static_peak.cr`.
Expected: all 0 / ALL PASS.

- [ ] **Step 5: Commit**

```bash
jj commit -m "alloc: add raw Core arena allocator body and parity test"
```

---

### Task 5: 切换默认并删除手写 body

**Files:**
- Modify: `src/format/elf/elf.cr`
- Modify: `tools/baseline/canary_values.tsv`
- Test: full suite

**Interfaces:**
- Consumes: Task 3/4 blob integration.
- Produces: default `g_alloc_use_blob = 1`; old hand-written functions removed or only reachable by an explicit legacy flag.

- [ ] **Step 1: Flip the default and remove the legacy path**

Set the default to the blob for both simple and arena. Delete `emit_alloc_body` and `emit_alloc_body_simple` if no caller remains; otherwise keep a `--alloc-legacy` debug flag for one commit.

- [ ] **Step 2: Run the full validation**

Run:
```bash
python3 tests/selfhost/test_alloc_simple_parity.py
python3 tests/selfhost/test_alloc_arena_parity.py
./build/corec selftest-stub-regalloc
./build/corec check src/compiler
bash tools/baseline/canary_check.sh
```
Expected: parity tests PASS, stub-regalloc 14/14, check ok, canary 5/5 after re-lock.

- [ ] **Step 3: Re-lock canary if the ELF changed**

Record old hash/size, new hash/size, attribution to the blob codegen, and the commit id. Do not change the four `.ccr` values.

- [ ] **Step 4: Commit**

```bash
jj commit -m "alloc: use the Core allocator blob by default"
```

---

### Task 6: LLVM 差分和结构检查接入 CI

**Files:**
- Create: `tests/selfhost/test_alloc_llvm_parity.py`
- Modify: `src/ci/run.sh` or the existing selfhost test entry
- Test: `tests/selfhost/test_alloc_llvm_parity.py`

**Interfaces:**
- Consumes: `clang` 23, `objdump`, `tools/asm_check.py`.
- Produces: CI-visible test that fails on a behavioral mismatch or a structural regression.

- [ ] **Step 1: Write the failing test**

The test:
- generates 200 deterministic random allocation sequences;
- runs the Core blob and the clang reference;
- compares returned offsets, headers, state, and failure witnesses;
- disassembles the blob with `objdump -d` and asserts the trampoline is `movabs rsi; jmp` and no `ud2` appears before the first failure label;
- runs `python3 tools/asm_check.py` on the generated `.s`.

- [ ] **Step 2: Run it to verify it fails**

Run: `python3 tests/selfhost/test_alloc_llvm_parity.py`
Expected: FAIL because the random generator/CI hook does not exist.

- [ ] **Step 3: Implement and wire into CI**

Add the test to the selfhost test list or `src/ci/run.sh`. Keep it skipped with a clear message if `clang` is absent; the project build must not depend on LLVM.

- [ ] **Step 4: Run the test and CI entry**

Run: `python3 tests/selfhost/test_alloc_llvm_parity.py`
Run: the CI command that includes it.
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
jj commit -m "alloc: add LLVM differential and structural checks"
```

---

### Task 7: 文档收尾

**Files:**
- Modify: `docs/superpowers/specs/2026-10-29-allocator-codegen-design.md`
- Modify: `docs/superpowers/specs/2026-10-29-arena-boundaries-design.md`
- Modify: `docs/superpowers/specs/2026-10-28-stub-regalloc.md` if it references the hand-written body

- [ ] **Step 1: Record the final state**

Update the design status to “已实施”，list the new files, the blob metadata, the trampoline, the relocation rules, the parity test commands, and the canary values.

- [ ] **Step 2: Remove stale statements**

Delete any statement that `alloc` is emitted only by hand-written bytes, or that the allocator stub is the only implementation.

- [ ] **Step 3: Verify docs**

Run: `python3 tools/doc_protected_surface.py` if applicable.
Expected: PASS or no protected-surface change.

- [ ] **Step 4: Commit**

```bash
jj commit -m "docs: record allocator blob codegen"
```

---

## Self-Review

- Spec coverage: blob pipeline, trampoline, global/call relocations, simple/arena bodies, LLVM parity, CI, canary, docs are each assigned to a task.
- Step scan: each task has a failing test, an implementation step, a verification command, and a commit.
- Type consistency: `alloc_simple` / `alloc_arena` signatures and `alloc_blob_*` interfaces are used consistently across tasks.
- Review focus: the size/trap/arena/tagged/trampoline cases are pinned in Task 2, 4, and 6 tests.
- Proportion: the plan leaves the allocator body translation to the implementer, with the current `emit_alloc_body` as the behavioral spec.

---

## Execution notes (2026-10-29)

Implementation commit: `3c97b41006b6cf883501496493d7f55d9d6019d2`; deviation closure commit: `91ba68f06b96`.

Deviations from the plan, with reasons:

1. The Core body ABI is `alloc_simple(size, heap_start, heap_end)` and
   `alloc_arena(size, heap_start, heap_end)`. The trampoline passes
   `rdx = bss_va + 1 GiB`. Without the third argument the initial heap end was
   `heap_start + 1 GiB`, which exceeded the data segment's `P_MEMSZ`.
2. The generator emits separate simple/arena relocation groups. `elf_gen`
   patches only the selected group and fails hard on a missing global or call.
   Patching both groups made non-arena programs print missing arena globals and
   left the arena body's RIP displacements at zero.
3. `g_alloc_fail_*` is registered for every program, and `g_alloc_home_idx`
   is no longer registered. This changes all four `.ccr` canary values; the
   value table records old/new values and the reason. This is a deliberate
   ruling, not a corpus change.
4. The arena regression is `tests/suite/arena_alloc_regress.cr`; it covers
   class-chunk aliasing after a slot switch and free-list slot linking. The
   trap cases (static >1MiB, >1TB, negative size) are generated by
   `test_alloc_arena_parity.py`.
5. `test_alloc_llvm_parity.py` runs real allocation sequences (state is restored
   before the reference call, then both states must match) and compares
   `g_heap_ptr`; it is no longer a list of independent first allocations.
6. `tools/gen_alloc_blob.py --check` was added and is run by CI so a stale
   `src/runtime/alloc_blob.cr` cannot pass the ELF tests.

7. `syscall6` was added to the Python bootstrap only (the allocator body is
   compiled by the bootstrap). Dynamic arena objects above 1 MiB now use
   `alloc_arena_extent`, with the layout that `arena_reset` already expects:
   next pointer, munmap length, hidden length, payload. The mmap-failure case
   writes class -2 and exits 132.
8. The legacy hand-written body and the `--alloc-legacy` / `--alloc-blob`
   flags were deleted. `emit_alloc_body` emits only the selected blob group;
   the tests and CI were rewritten for the blob-only path.
9. `test_alloc_arena_llvm.py` adds an independent C model for class/slot,
   pool growth, and static arenas. Extents and mmap failure are covered by
   `test_alloc_arena_parity.py`.
