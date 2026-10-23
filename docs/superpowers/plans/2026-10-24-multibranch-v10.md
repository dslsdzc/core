# v10 多路分支 / match 决策 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 v10 `.ccr` 上实现多路 `MATCH` 节点和 CASE 表：corec 把 `match` 降为多路分支，corearch 映射为比较链/二分/跳转表，interp 与 ELF 语义一致。

**Architecture:** 保留 `IR_BRANCH` 作为 `if`/`while` 的二元分支；新增 `IR_MATCH` 和 CASE 记录。CASE 是 v10 第 9 段，记录为 24B `{value, kind, str_index, target_nod, flags}`。先做整数/bool/enum 标签的多路分派；字符串/struct/ident 模式在后续任务补齐。

**Spec:** `docs/superpowers/specs/2026-10-23-pattern-matching-ir-design.md`（v9.1 设计，本计划适配 v10）+ `docs/superpowers/specs/2026-10-23-lattice-ccr-v10-design.md` §11 CASE。

## 全局约束

- 不改变 `IR_BRANCH` 的二元编码；`if`/`while` 继续走现有路径。
- `MATCH` 只表示多路分派；`CASE` 不存宽度、偏移、ABI 或机器码。
- CASE 值只进入 v10 CASE 段；字符串模式后续归一化为 `str_eq`，不把字符串指针放进 CASE。
- 每个任务单独提交；先 CASE/IR_MATCH 读写，再 corec，再 corearch/interp。
- 自举要求 stage2/stage3 逐字节一致；`test_bootstrap` 和 canary 不因中间态长时间红。
- `jj` only；子代理每个任务新开，禁止并行实现同一文件。
- 所有长命令 `nice -n 19`。

---

### Task 1: IR_MATCH/CASE schema 与 v10 读写

**Files:**
- Modify: `src/compiler/ast.cr`
- Modify: `src/compiler/globals.cr`
- Modify: `src/compiler/ccr_schema.cr`
- Modify: `src/compiler/ccr_io.cr`
- Test: `tests/selfhost/test_multibranch_v10.py`

**Interfaces:**
- Consumes: v10 CASE 段 tag 9，24B 记录。
- Produces:
  - `IR_MATCH : int = 54`
  - `g_ccr_case : string`, `g_ccr_case_count : int`
  - CASE record offsets/stride:
    - `CCR_CASE_VALUE=0` (8B signed)
    - `CCR_CASE_KIND=8` (4B)
    - `CCR_CASE_STR=12` (4B signed)
    - `CCR_CASE_TARGET=16` (4B signed NOD label id)
    - `CCR_CASE_FLAGS=20` (4B)
    - `CCR_CASE_DISK=24`
  - `CCR_CASE_KIND_VALUE=0`, `KIND_ENUM=1`, `KIND_STRING=2`, `KIND_DEFAULT=3`

- [ ] **Step 1: failing test**

Create a Python test that builds a `.ccr` with an `IR_MATCH` node and 3 CASE records, parses the CASE segment independently, and asserts count/order/value/target. Also assert a v10 file with CASE count > 0 is not rejected by the container (once implemented).

- [ ] **Step 2: implement schema**

Add `IR_MATCH`; `ccr_op_is_known` includes it; CASE segment writer reads `g_ccr_case`; loader rebuilds it. For now `g_ccr_case_count=0` unless corec populates. CASE segment size = `4 + count*24`. Add bounds/str/target checks; default exactly one optional.

- [ ] **Step 3: verify**

```bash
python3 tests/selfhost/test_multibranch_v10.py
python3 tests/selfhost/test_ccr_v10_format.py
python3 tests/selfhost/test_ccr_v10_stream.py
nice -n 19 python3 build_selfhost_native.py
```

- [ ] **Step 4: commit**

`jj commit -m "ccr: add v10 match and case schema"`

---

### Task 2: corec `match` 降为 MATCH

**Files:**
- Modify: `src/compiler/ir_gen.cr`
- Modify: `src/compiler/dump.cr`
- Modify: `src/compiler/ccr_types.cr`
- Modify: `src/compiler/cir_cache.cr`
- Test: `tests/selfhost/test_multibranch_v10.py`

**Interfaces:**
- Consumes: Task 1 `IR_MATCH`, `g_ccr_case`.
- Produces: one `IR_MATCH` for a match whose arms are int/bool/enum/wildcard; body labels are existing labels; default is a `KIND_DEFAULT` case.
- Unsupported patterns keep the existing sequential lowering until Task 4; do not silently change semantics.

- [ ] **Step 1: RED fixture**

4-way int match and enum match; assert exactly one `MATCH` in the function and CASE count = arms + default; old code produces zero.

- [ ] **Step 2: implement**

Collect cases in arm order, dedupe by value keeping first, `KIND_DEFAULT` for `_`; emit `MATCH` with `src1=scrutinee`, `src2=case_start`, `src3=case_count`. Keep optional representation special path unchanged for now. If a match has string/struct/ident patterns, fall back to existing code and mark a TODO; do not emit a wrong MATCH.

- [ ] **Step 3: CIR cache**

Disable CIR cache for functions containing `MATCH` in this task (simplest correct); add a per-function `g_cir_has_match` reset and check. Task 5 may replace with CASE range persistence.

- [ ] **Step 4: dump**

`--dump-objects` prints `match` with case range and cases.

- [ ] **Step 5: verify**

```bash
python3 tests/selfhost/test_multibranch_v10.py
nice -n 19 python3 tests/selfhost/test_ccr_types.py
nice -n 19 python3 build_selfhost_native.py
./build/corec check src/compiler
```

- [ ] **Step 6: commit**

`jj commit -m "ccr: lower integer and enum matches to v10 MATCH"`

---

### Task 3: corearch / interp / dataflow support

**Files:**
- Modify: `src/arch/x86_64/instr.cr`
- Modify: `src/arch/x86_64/regalloc.cr`
- Modify: `src/arch/x86_64/sizes.cr` if present
- Modify: `src/compiler/dataflow.cr`
- Modify: `src/compiler/interp.cr`
- Modify: `src/compiler/ccr_io.cr` validation
- Test: `tests/selfhost/test_multibranch_v10.py`

**Interfaces:**
- `MATCH` successors = all case targets (plus default); regalloc handles multiple successors.
- corearch emits:
  - count 0 -> default jump/trap
  - count 1..2 -> cmp/jcc chain
  - count >2 -> binary search by sorted value (Task 4 can replace with jump table)
- interp reads the loaded case table and jumps to the target; default on no hit.
- `MATCH` target labels must be valid NOD labels and in function span; loader validates.

- [ ] **Step 1: RED** 4-way int match ELF and interp; both must return the selected arm; current no MATCH path fails.
- [ ] **Step 2: implement**; keep `IR_BRANCH` code untouched.
- [ ] **Step 3: verify**:
```bash
python3 tests/selfhost/test_multibranch_v10.py
python3 tests/selfhost/test_interp_parity.py
python3 tests/selfhost/test_native_memory.py
python3 tests/selfhost/test_backend_bootstrap.py
```
- [ ] **Step 4: commit**
`jj commit -m "backend: lower v10 MATCH to compare chains"`

---

### Task 4: dense jump table / sparse binary search

**Files:**
- Modify: `src/arch/x86_64/instr.cr`
- Modify: `src/arch/x86_64/regalloc.cr`
- Modify: `src/arch/x86_64/sizes.cr`
- Test: `tests/selfhost/test_multibranch_v10.py`

**Interfaces:**
- Dense: `count >= 8 && max-min+1 <= 2*count` -> 32-bit relative table in rodata; range check; default out-of-range.
- Sparse: sorted binary comparison tree.
- `s3==1` with value 1 and default remains same machine shape as existing `IR_BRANCH` if possible.
- Add 16/64-way benchmarks and assert no linear chain on dense case.

- [ ] **Step 1: RED** 64-way dense fixture; assert ELF contains table path / bounded comparisons.
- [ ] **Step 2: implement** with label patch mechanism; no PIE/dynamic relocations.
- [ ] **Step 3: verify and commit**
`ccr: add jump-table lowering for dense match`

---

### Task 5: pattern coverage

**Files:**
- Modify: `src/compiler/parser.cr` (tuple pattern if missing)
- Modify: `src/compiler/checker.cr`
- Modify: `src/compiler/ir_gen.cr`
- Modify: `bootstrap/corec/frontend/desugar.py`
- Test: `tests/selfhost/test_multibranch_v10.py`

**Interfaces:**
- string/char patterns normalize to `str_eq` and binary MATCH/default.
- struct/tuple fields load then recursively dispatch.
- ident binds; wildcard default.
- literal exhaustiveness: `_` or irrefutable arm else `EC_TM_EXHAUST`.
- corec source must avoid unsupported bootstrap match patterns; extend desugar if needed.

- [ ] **Steps** TDD per pattern: string, char, struct, tuple, ident; behavior parity; no silent first-arm.
- [ ] **Commit** `ccr: cover string struct and ident match patterns`

---

### Task 6: cleanup, cache, canary

**Files:**
- Modify: `src/compiler/cir_cache.cr` (persist CASE range or keep disable)
- Modify: `tools/baseline/canary_values.tsv`
- Modify: `docs/superpowers/specs/2026-10-23-pattern-matching-ir-design.md` (v10 adaptation)
- Test: `tests/selfhost/test_multibranch_v10.py`

- [ ] Replace temporary cache disable with CASE-range persistence if feasible; otherwise document.
- [ ] Update bootstrap parser for V4 syntax tests if CI still red.
- [ ] Run full gate and relock only affected `.ccr`/ELF with attribution.
- [ ] Commit.

## Final Gate

```bash
nice -n 19 python3 build_selfhost_native.py
./build/corec check src/compiler
python3 tests/selfhost/test_multibranch_v10.py
python3 tests/selfhost/test_ccr_v10_format.py
python3 tests/selfhost/test_ccr_v10_stream.py
python3 tests/selfhost/test_ccr_types.py
python3 tests/selfhost/test_backend_bootstrap.py
python3 tests/selfhost/test_interp_parity.py
python3 tests/selfhost/test_native_memory.py
python3 tests/harness/test_ci_hook_coverage.py
bash tools/baseline/canary_check.sh
./build/corec build src/compiler/main.cr -o build/corec2 --static -O 0
./build/corec2 build src/compiler/main.cr -o build/corec3 --static -O 0
cmp build/corec2 build/corec3
```
