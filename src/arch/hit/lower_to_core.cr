// === src/arch/hit/lower_to_core.cr ===
// Lowering layer for HIT: a straight-line IR subset to a four-event core stream
// and a constant pool.
//
// Pipeline in table mode inside corearch: IR, lowering in this file, event
// stream, table projection, bytes.
//
// Event record, 20 bytes:
//   [event id i32, dst i32, src1 i32, src2 i32, flags i32]
// Event ids: sub=1, nand=2, load=3, store=4. The table loader checks that the id
// exists. dst is the result variable; store uses 0. src1 and src2 hold variable
// numbers or pool slots; flags bit 0 marks src1 as a pool slot, bit 1 marks src2.
// Unused operand fields hold 0, never -1: hit_w32 defines only non-negative
// values, because byte extraction with x86 truncating division and Python floor
// division disagree on negative inputs.
//
// Lowering rules for the straight-line subset:
//   IR_CONST n: load event with the address in a pool slot; the pool value is
//     written to ELF rodata during emission.
//   IR_BINARY OP_SUB: one sub event.
//   IR_BINARY OP_ADD: sub(a, sub(0, b)). Event 1 computes sub(d, pool0, b);
//     event 2 computes sub(d, a, d). The encoder reads before writing, so the
//     intermediate value can live in d. The destination must differ from a;
//     otherwise no event is emitted and the instruction uses the normal path.
//   IR_LOAD and IR_STORE: load or store event. The encoder rejects globals and
//     unsupported shapes before emission.
//   Other IR_BINARY operations: print "needs more events" and exit 1.
// Unmapped instructions (RET, ALLOC, ARENA_*, and others) emit no event and use
// the normal path, giving mixed mode.
//
// Constant pool: 8 bytes per slot, deduplicated by value. Values are written to
// .rodata after emission. Pool references are recorded in g_hit_pool_patch by the
// encoder and patched by elf.cr after emission.
//
// This file is part of two builds: the corearch concat list, after common and
// before the kernel and architecture files, and the project-mode unit
// src/targets/x86_64/linux/elf/_import.cr. The import lines also let standalone
// `corec check` and project mode resolve symbols; concat builds strip them.

import io
import fmt
import ast
import globals
import dyn_arr
import ccr_schema
import bytes
import hit

// ------------------------------------------------------------------
// Event stream, pool layout, and state
// ------------------------------------------------------------------

// Event ids shared with core-x86.toml. The table loader matches by id and falls back to the normal path when an id is absent.
HIT_EV_SUB   : int = 1
HIT_EV_NAND  : int = 2
HIT_EV_LOAD  : int = 3
HIT_EV_STORE : int = 4
HIT_EV_JUMP  : int = 5    // jump; the rel32 field is patched from the event position
HIT_EV_BRANCH: int = 6    // branch template; emitted by the table encoder
HIT_EV_CALL  : int = 7    // call template
HIT_EV_RET   : int = 8    // return template
HIT_EV_EXTERN: int = 9    // external call template

HIT_ES_REC    : int = 20  // 5 × i32
HIT_ES_OFF_ID    : int = 0
HIT_ES_OFF_DST   : int = 4
HIT_ES_OFF_S1    : int = 8
HIT_ES_OFF_S2    : int = 12
HIT_ES_OFF_FLAGS : int = 16
HIT_ES_S1_POOL : int = 1   // src1 is a pool slot instead of a variable
HIT_ES_S2_POOL : int = 2   // src2 is a pool slot instead of a variable

g_hit_ev_stream : string, mut
g_hit_ev_count : int, mut
g_hit_ev_cap : int, mut
g_hit_ev_map : string, mut
g_hit_ev_map_size : int, mut  // 8 bytes per IR instruction: {start u32, count u32}
g_hit_pool : string, mut
g_hit_pool_count : int, mut
g_hit_pool_cap : int, mut
g_hit_pool_patch : string, mut
g_hit_pool_patch_count : int, mut
g_hit_pool_patch_cap : int, mut  // 16 bytes per record: {pos i64, k i64}

// Relocation tables, event emission positions, and injection state.
// g_hit_rel stores {kind, pos, target}, 24 bytes per record. kind 0 targets an
// event position, 1 a function start, and 2 an external symbol ordinal. instr.cr
// adds records; elf.cr patches them after emission.
// g_hit_ev_pos maps event ordinals to emission byte positions, 8 bytes each. The
// emitter records positions as it writes, and jump patching reads them.
// g_hit_inject_active marks the test-only --hit-events-file path. A failed check
// or a count mismatch exits 1 instead of falling back to the normal path.
g_hit_rel : string, mut
g_hit_rel_count : int, mut
g_hit_rel_cap : int, mut
g_hit_ev_pos : string, mut
g_hit_ev_pos_count : int, mut
g_hit_ev_pos_cap : int, mut
g_hit_inject_active : int, mut

fn hit_grow_ev(needed: int):
    if needed < g_hit_ev_cap:
        return
    nc : ., mut = g_hit_ev_cap * 2
    if nc < 64:
        nc = 64
    if nc < needed:
        nc = needed + 8
    nb := alloc(nc * HIT_ES_REC)
    hit_copy_bytes(g_hit_ev_stream, g_hit_ev_cap * HIT_ES_REC, nb)
    g_hit_ev_stream = nb
    g_hit_ev_cap = nc

fn hit_grow_pool(needed: int):
    if needed < g_hit_pool_cap:
        return
    nc : ., mut = g_hit_pool_cap * 2
    if nc < 8:
        nc = 8
    if nc < needed:
        nc = needed + 4
    nb := alloc(nc * 8)
    hit_copy_bytes(g_hit_pool, g_hit_pool_cap * 8, nb)
    g_hit_pool = nb
    g_hit_pool_cap = nc

fn hit_grow_pool_patch(needed: int):
    if needed < g_hit_pool_patch_cap:
        return
    nc : ., mut = g_hit_pool_patch_cap * 2
    if nc < 8:
        nc = 8
    if nc < needed:
        nc = needed + 4
    nb := alloc(nc * 16)
    hit_copy_bytes(g_hit_pool_patch, g_hit_pool_patch_cap * 16, nb)
    g_hit_pool_patch = nb
    g_hit_pool_patch_cap = nc

fn hit_grow_rel(needed: int):
    if needed < g_hit_rel_cap:
        return
    nc : ., mut = g_hit_rel_cap * 2
    if nc < 8:
        nc = 8
    if nc < needed:
        nc = needed + 4
    nb := alloc(nc * 24)
    hit_copy_bytes(g_hit_rel, g_hit_rel_cap * 24, nb)
    g_hit_rel = nb
    g_hit_rel_cap = nc

fn hit_grow_ev_pos(needed: int):
    if needed < g_hit_ev_pos_cap:
        return
    nc : ., mut = g_hit_ev_pos_cap * 2
    if nc < 8:
        nc = 8
    if nc < needed:
        nc = needed + 4
    nb := alloc(nc * 8)
    hit_copy_bytes(g_hit_ev_pos, g_hit_ev_pos_cap * 8, nb)
    g_hit_ev_pos = nb
    g_hit_ev_pos_cap = nc

// Add a relocation record. kind 0 targets an event ordinal; kinds 1 and 2 are
// reserved for function starts and external symbol ordinals.
fn hit_rel_add(kind: int, pos: int, target: int):
    hit_grow_rel(g_hit_rel_count + 1)
    slot : ., mut = g_hit_rel_count
    g_hit_rel_count = slot + 1
    cell_store(g_hit_rel, slot * 24, kind)
    cell_store(g_hit_rel, slot * 24 + 8, pos)
    cell_store(g_hit_rel, slot * 24 + 16, target)

// Record the emission byte position of an event ordinal before its bytes are written.
fn hit_ev_pos_set(ord: int, pos: int):
    hit_grow_ev_pos(ord + 1)
    cell_store(g_hit_ev_pos, ord * 8, pos)
    if ord + 1 > g_hit_ev_pos_count:
        g_hit_ev_pos_count = ord + 1

// Write an 8-byte two's-complement little-endian value. The borrow sequence supports negative pool values.
fn hit_pool_w64(buf: string, pos: int, v: int):
    b0 : ., mut = v % 256
    t1 : ., mut = v / 256
    b1 : ., mut = t1 % 256
    t2 : ., mut = t1 / 256
    b2 : ., mut = t2 % 256
    t3 : ., mut = t2 / 256
    b3 : ., mut = t3 % 256
    t4 : ., mut = t3 / 256
    b4 : ., mut = t4 % 256
    t5 : ., mut = t4 / 256
    b5 : ., mut = t5 % 256
    t6 : ., mut = t5 / 256
    b6 : ., mut = t6 % 256
    t7 : ., mut = t6 / 256
    b7 : ., mut = t7 % 256
    if b0 < 0:
        b0 = b0 + 256
        b1 = b1 - 1
    if b1 < 0:
        b1 = b1 + 256
        b2 = b2 - 1
    if b2 < 0:
        b2 = b2 + 256
        b3 = b3 - 1
    if b3 < 0:
        b3 = b3 + 256
        b4 = b4 - 1
    if b4 < 0:
        b4 = b4 + 256
        b5 = b5 - 1
    if b5 < 0:
        b5 = b5 + 256
        b6 = b6 - 1
    if b6 < 0:
        b6 = b6 + 256
        b7 = b7 - 1
    if b7 < 0:
        b7 = b7 + 256
    store8(buf, pos + 0, b0)
    store8(buf, pos + 1, b1)
    store8(buf, pos + 2, b2)
    store8(buf, pos + 3, b3)
    store8(buf, pos + 4, b4)
    store8(buf, pos + 5, b5)
    store8(buf, pos + 6, b6)
    store8(buf, pos + 7, b7)

fn hit_lower_reset():
    g_hit_ev_count = 0
    g_hit_pool_count = 0
    g_hit_pool_patch_count = 0
    // Clear relocation and event position tables for each emission.
    g_hit_rel_count = 0
    g_hit_ev_pos_count = 0

fn hit_ev_map_init(n: int):
    g_hit_ev_map_size = n
    g_hit_ev_map = alloc(n * 8 + 8)

fn hit_ev_map_set(i: int, start: int, cnt: int):
    w32(g_hit_ev_map, i * 8, start)
    w32(g_hit_ev_map, i * 8 + 4, cnt)

fn hit_ev_map_cnt(i: int) -> int:
    if i < 0 || i >= g_hit_ev_map_size:
        return 0
    return r32(g_hit_ev_map, i * 8 + 4)

fn hit_ev_map_start(i: int) -> int:
    if i < 0 || i >= g_hit_ev_map_size:
        return 0
    return r32(g_hit_ev_map, i * 8)

// Append one 20-byte event. Unused operands are 0, never -1.
fn hit_ev_append(ev_id: int, d: int, s1: int, s2: int, flags: int):
    hit_grow_ev(g_hit_ev_count + 1)
    slot : ., mut = g_hit_ev_count
    g_hit_ev_count = slot + 1
    hit_w32(g_hit_ev_stream, slot * HIT_ES_REC + HIT_ES_OFF_ID, ev_id)
    hit_w32(g_hit_ev_stream, slot * HIT_ES_REC + HIT_ES_OFF_DST, d)
    hit_w32(g_hit_ev_stream, slot * HIT_ES_REC + HIT_ES_OFF_S1, s1)
    hit_w32(g_hit_ev_stream, slot * HIT_ES_REC + HIT_ES_OFF_S2, s2)
    hit_w32(g_hit_ev_stream, slot * HIT_ES_REC + HIT_ES_OFF_FLAGS, flags)

// Event stream accessors for dumps and the encoder; i is the stream index.
fn hit_ev_id(i: int) -> int:
    return hit_r32(g_hit_ev_stream, i * HIT_ES_REC + HIT_ES_OFF_ID)
fn hit_ev_dst(i: int) -> int:
    return hit_r32(g_hit_ev_stream, i * HIT_ES_REC + HIT_ES_OFF_DST)
fn hit_ev_s1(i: int) -> int:
    return hit_r32(g_hit_ev_stream, i * HIT_ES_REC + HIT_ES_OFF_S1)
fn hit_ev_s2(i: int) -> int:
    return hit_r32(g_hit_ev_stream, i * HIT_ES_REC + HIT_ES_OFF_S2)
fn hit_ev_flags(i: int) -> int:
    return hit_r32(g_hit_ev_stream, i * HIT_ES_REC + HIT_ES_OFF_FLAGS)
fn hit_ev_total() -> int:
    return g_hit_ev_count

// Intern a pool value by value and return its slot.
fn hit_pool_intern(v: int) -> int:
    k : ., mut = 0
    loop:
        if k >= g_hit_pool_count:
            break
        if cell_load(g_hit_pool, k * 8) == v:
            return k
        k = k + 1
    hit_grow_pool(g_hit_pool_count + 1)
    pk : ., mut = g_hit_pool_count
    g_hit_pool_count = pk + 1
    hit_pool_w64(g_hit_pool, pk * 8, v)
    return pk

fn hit_pool_total() -> int:
    return g_hit_pool_count
fn hit_pool_val(k: int) -> int:
    return cell_load(g_hit_pool, k * 8)

// Record a pool reference at a byte position. elf.cr patches it after rodata is final.
fn hit_pool_patch_add(pos: int, k: int):
    hit_grow_pool_patch(g_hit_pool_patch_count + 1)
    slot : ., mut = g_hit_pool_patch_count
    g_hit_pool_patch_count = slot + 1
    cell_store(g_hit_pool_patch, slot * 16, pos)
    cell_store(g_hit_pool_patch, slot * 16 + 8, k)

// ------------------------------------------------------------------
// Lowering rules: straight-line IR to event stream
// ------------------------------------------------------------------

// Lower one IR instruction and append events. Returns 0 on success, possibly with
// no event and therefore the normal path; returns 1 for an unsupported operation
// after printing an error, and the caller exits 1.
fn hit_lower_instr(j: int) -> int:
    op := iri_op(j)
    d := iri_dest(j)
    s1 := iri_s1(j)
    s2 := iri_s2(j)
    s3 := iri_s3(j)
    ti := iri_tk(j)
    if op == IR_CONST:
        // String constants use the normal string path. Other constants become a
        // pool load event; the 8-byte value is written to rodata during emission.
        if ti == TI_STR:
            return 0
        if d < 0:
            return 0
        k := hit_pool_intern(s1)
        hit_ev_append(HIT_EV_LOAD, d, k, 0, HIT_ES_S1_POOL)   // load event: src1 is the pool slot, src2 is unused
        return 0
    if op == IR_BINARY:
        if ti == TI_DEX:
            return 0
        // binary64 operations use the normal SSE path.
        if s3 == OP_SUB:
            if d < 0 || s1 < 0 || s2 < 0:
                return 0
            hit_ev_append(HIT_EV_SUB, d, s1, s2, 0)
            return 0
        if s3 == OP_ADD:
            if d < 0 || s1 < 0 || s2 < 0:
                return 0
            // The destination must differ from src1. Event 1 writes 0-b into d;
            // if d == a, event 2 would read the intermediate value instead of a.
            // Emitting no event uses the normal path.
            if d == s1:
                return 0
            k0 := hit_pool_intern(0)   // synthesized zero; the minimal core has no const event
            // add(a, b) = sub(a, sub(0, b)). Event 1 writes 0-b to d; event 2
            // writes a-d to d. The encoder reads before writing.
            hit_ev_append(HIT_EV_SUB, d, k0, s2, HIT_ES_S1_POOL)
            hit_ev_append(HIT_EV_SUB, d, s1, d, 0)
            return 0
        // Other suboperations (mul, div, mod, shifts, bitwise and, or, and others) are outside the straight-line subset.
        print("error: HIT lower: instr ")
        print_i(j)
        print(" op=")
        print_i(op)
        print(" sub=")
        print_i(s3)
        println(" needs more events (M1 straight-line subset: const/load/store/add/sub)")
        return 1
    if op == IR_LOAD:
        if d >= 0 && s1 >= 0:
            // Slot read to slot write. The encoder rejects globals and unsupported
            // shapes and uses the normal path for the whole instruction. src2 is
            // unused, so store 0.
            hit_ev_append(HIT_EV_LOAD, d, s1, 0, 0)
        return 0
    if op == IR_STORE:
        if s1 >= 0 && s2 >= 0:
            // Slot write: src1 is the address slot and src2 the value. dst is unused.
            hit_ev_append(HIT_EV_STORE, 0, s1, s2, 0)
        return 0
    return 0

// Lower the whole program in table mode before emission.
// The subset covers the main function's instruction stream. Standard library
// helpers pulled in by fmt and io contain comparisons, branches, and division;
// those emit no event and use the normal path. An unsupported operation inside
// main reports "needs more events" and exits 1. Clear the map for every
// instruction and lower only main.
// Returns 0 on success and 1 for an unsupported operation after printing an
// error; the caller exits 1.
fn hit_lower_program() -> int:
    hit_lower_reset()
    hit_ev_map_init(g_ir_instr_count)
    mi : ., mut = 0
    loop:
        if mi >= g_ir_instr_count:
            break
        hit_ev_map_set(mi, 0, 0)
        mi = mi + 1
    entry : ., mut = -1
    fi : ., mut = 0
    loop:
        if fi >= g_ir_func_count:
            break
        if str_eq(istr_get(cell_load(g_ir_func_name_idx, fi * 8)), "main") != 0:
            entry = fi
            break
        fi = fi + 1
    if entry < 0:
        return 0
    // No main means there is nothing to lower; use the normal path.
    ist := cell_load(g_ir_func_instr_start, entry * 8)
    ic := cell_load(g_ir_func_instr_count, entry * 8)
    ii : ., mut = 0
    loop:
        if ii >= ic:
            break
        j := ist + ii
        base : ., mut = g_hit_ev_count
        if hit_lower_instr(j) != 0:
            return 1
        hit_ev_map_set(j, base, g_hit_ev_count - base)
        ii = ii + 1
    return 0

// ------------------------------------------------------------------
// Event stream injection for tests
// ------------------------------------------------------------------
// The hidden corearch flag --hit-events-file <path> replaces hit_lower_program.
// The text file is the inverse of --dump-events. It builds g_hit_ev_stream,
// g_hit_pool, and the per-instruction event map, then skips lowering. Template
// comparison and dump tests can therefore run before the lowering layer supports
// an operation.
//
// File format; lines beginning with # are comments:
//   ev <name> [dst=N] [s1=[pool]N] [s2=[pool]N]   one event per line; name is a
//                                                table event name
//   pool <v0> <v1> ...                           pool values in slot order; may
//                                                span multiple lines
// Missing operands take the attached IR instruction's value: dst from iri_dest,
// s1 from iri_s1, s2 from iri_s2. A negative instruction field becomes 0.
// Authors do not need to know .ccr global numbers. Explicit fields override the
// default; a jump's s1 is a target event ordinal and a pool reference uses
// s1=poolN.
//
// Attachment rules matching the lowering layer:
//   event 1 sub <- IR_BINARY(OP_SUB)
//   event 3 load <- IR_LOAD with a variable operand, or IR_CONST with a
//                    non-string pool operand
//   event 4 store <- IR_STORE
//   event 5 jump <- IR_JUMP; s1 must be the explicit target event ordinal
//   event 11 cst <- IR_CONST with a non-string immediate operand; this is the
//                    cst fixture event, and its immediate is the event's s1
// Other events have no instruction expectation and are rejected with
// "no instruction expects". Parse and attachment errors return 1.
//
// Parsed event lines are buffered for a second pass because the target
// instruction is unknown during parsing. Each line is 20 bytes:
// {id i32, flags i32, dst i32, s1 i32, s2 i32}.
g_hit_inj : string, mut
g_hit_inj_count : int, mut
g_hit_inj_cap : int, mut

HIT_INJ_HAS_DST : int = 1   // dst is explicit; otherwise use the instruction dest
HIT_INJ_HAS_S1  : int = 2   // s1 is explicit
HIT_INJ_HAS_S2  : int = 4   // s2 is explicit
HIT_INJ_S1_POOL : int = 8   // s1 is a pool reference
HIT_INJ_S2_POOL : int = 16  // s2 is a pool reference

fn hit_grow_inj(needed: int):
    if needed < g_hit_inj_cap:
        return
    nc : ., mut = g_hit_inj_cap * 2
    if nc < 8:
        nc = 8
    if nc < needed:
        nc = needed + 4
    nb := alloc(nc * 20)
    hit_copy_bytes(g_hit_inj, g_hit_inj_cap * 20, nb)
    g_hit_inj = nb
    g_hit_inj_cap = nc

fn hit_inj_line_id(i: int) -> int:
    return hit_r32(g_hit_inj, i * 20 + 0)
fn hit_inj_line_flags(i: int) -> int:
    return hit_r32(g_hit_inj, i * 20 + 4)
fn hit_inj_line_dst(i: int) -> int:
    return hit_r32(g_hit_inj, i * 20 + 8)
fn hit_inj_line_s1(i: int) -> int:
    return hit_r32(g_hit_inj, i * 20 + 12)
fn hit_inj_line_s2(i: int) -> int:
    return hit_r32(g_hit_inj, i * 20 + 16)

// Event name to table slot for dump names and injected files. -1 means unknown.
fn hit_inj_event_by_name(name: string) -> int:
    ei : ., mut = 0
    loop:
        if ei >= g_hit_event_count:
            break
        if str_eq(hit_event_name(ei), name) != 0:
            return ei
        ei = ei + 1
    return -1

// Whether instruction (op, subop, ti) expects event line (l_id, l_pool).
// Events with no expectation reject the line.
fn hit_inj_line_expected(op: int, subop: int, ti: int, l_id: int, l_pool: int) -> int:
    if l_id == HIT_EV_JUMP:
        if op == IR_JUMP && l_pool == 0:
            return 1
        return 0
    if l_id == HIT_EV_SUB:
        if op == IR_BINARY && subop == OP_SUB:
            return 1
        return 0
    if l_id == HIT_EV_STORE:
        if op == IR_STORE:
            return 1
        return 0
    if l_id == HIT_EV_LOAD:
        if op == IR_LOAD && l_pool == 0:
            return 1
        if op == IR_CONST && ti != TI_STR && l_pool == 1:
            return 1
        return 0
    if l_id == 11:
        // cst fixture event for a direct immediate const; see the header.
        if op == IR_CONST && ti != TI_STR && l_pool == 0:
            return 1
        return 0
    return 0

// Dispatch a pool line, an event line, or a bad line. 0 handled, 1 error.
fn hit_inj_parse_line(line: string) -> int:
    llen := str_len(line)
    if llen >= 4 && load8(line, 0) == 112 && load8(line, 1) == 111 && load8(line, 2) == 111 && load8(line, 3) == 108 && (llen == 4 || load8(line, 4) == 32):
        return hit_inj_parse_pool_line(line)
    if llen >= 2 && load8(line, 0) == 101 && load8(line, 1) == 118 && (llen == 2 || load8(line, 2) == 32):
        return hit_inj_parse_ev_line(line)
    print("error: HIT events: bad event line: ")
    println(line)
    return 1

// Parse a pool line: whitespace-separated values appended to the pool. 0 success, 1 error.
fn hit_inj_parse_pool_line(line: string) -> int:
    llen := str_len(line)
    vp : ., mut = 4
    loop:
        loop:
            if vp >= llen:
                break
            if load8(line, vp) == 32:
                vp = vp + 1
            else:
                break
        if vp >= llen:
            break
        vv := hit_inj_parse_int(line, vp)
        if vv < 0:
            print("error: HIT events: bad pool value at line: ")
            println(line)
            return 1
        hit_grow_pool(g_hit_pool_count + 1)
        hit_pool_w64(g_hit_pool, g_hit_pool_count * 8, vv)
        g_hit_pool_count = g_hit_pool_count + 1
        loop:
            // Skip all digits of the value; a leading minus was already validated.
            if vp >= llen:
                break
            c := load8(line, vp)
            if c >= 48 && c <= 57 || c == 45:
                vp = vp + 1
            else:
                break
    return 0

// Parse an ev line and buffer it for attachment. Missing operands take the
// instruction's values; see hit_inj_line_expected for attachment rules. The
// buffered record is 20 bytes. 0 success, 1 error.
fn hit_inj_parse_ev_line(line: string) -> int:
    llen := str_len(line)
    np : ., mut = 2
    loop:
        if np >= llen:
            break
        if load8(line, np) == 32:
            np = np + 1
        else:
            break
    ne : ., mut = np
    loop:
        if ne >= llen:
            break
        if load8(line, ne) == 32:
            break
        ne = ne + 1
    if ne <= np:
        print("error: HIT events: bad event line: ")
        println(line)
        return 1
    es := hit_inj_event_by_name(str_sub(line, np, ne - np))
    if es < 0:
        print("error: HIT events: unknown event '")
        print(str_sub(line, np, ne - np))
        println("'")
        return 1
    ev_id := hit_r32(g_hit_events, es * HIT_EVENT_REC + HIT_EV_OFF_ID)
    fl : ., mut = 0
    dv : ., mut = 0
    s1v : ., mut = 0
    s2v : ., mut = 0
    dpos := hit_inj_field_of(line, ne, "dst", 0)
    if dpos == -2:
        print("error: HIT events: bad dst at line: ")
        println(line)
        return 1
    if dpos >= 0:
        dv = hit_inj_parse_int(line, dpos)
        if dv < 0:
            print("error: HIT events: bad dst at line: ")
            println(line)
            return 1
        fl = fl + HIT_INJ_HAS_DST
    s1pos := hit_inj_field_of(line, ne, "s1", 1)
    if s1pos == -2:
        print("error: HIT events: bad s1 at line: ")
        println(line)
        return 1
    if s1pos >= 0:
        if load8(line, s1pos) == 112:
            // poolN reference
            s1v = str_int(str_sub(line, s1pos + 4, str_len(line) - s1pos - 4))
            fl = fl + HIT_INJ_HAS_S1 + HIT_INJ_S1_POOL
        else:
            s1v = hit_inj_parse_int(line, s1pos)
            if s1v < 0:
                print("error: HIT events: bad s1 at line: ")
                println(line)
                return 1
            fl = fl + HIT_INJ_HAS_S1
    s2pos := hit_inj_field_of(line, ne, "s2", 1)
    if s2pos == -2:
        print("error: HIT events: bad s2 at line: ")
        println(line)
        return 1
    if s2pos >= 0:
        if load8(line, s2pos) == 112:
            s2v = str_int(str_sub(line, s2pos + 4, str_len(line) - s2pos - 4))
            fl = fl + HIT_INJ_HAS_S2 + HIT_INJ_S2_POOL
        else:
            s2v = hit_inj_parse_int(line, s2pos)
            if s2v < 0:
                print("error: HIT events: bad s2 at line: ")
                println(line)
                return 1
            fl = fl + HIT_INJ_HAS_S2
    hit_grow_inj(g_hit_inj_count + 1)
    hit_w32(g_hit_inj, g_hit_inj_count * 20 + 0, ev_id)
    hit_w32(g_hit_inj, g_hit_inj_count * 20 + 4, fl)
    hit_w32(g_hit_inj, g_hit_inj_count * 20 + 8, dv)
    hit_w32(g_hit_inj, g_hit_inj_count * 20 + 12, s1v)
    hit_w32(g_hit_inj, g_hit_inj_count * 20 + 16, s2v)
    g_hit_inj_count = g_hit_inj_count + 1
    return 0

// Parse an injection file and attach events to main, the same entry used by
// lowering. 0 success, 1 error; corearch exits 1 on error.
fn hit_inject_events(path: string) -> int:
    content := read_file(path)
    if str_len(content) == 0:
        print("error: cannot open HIT events file: ")
        println(path)
        return 1
    hit_lower_reset()
    g_hit_inj_count = 0
    // Pass 1: parse lines. Pool lines append values; ev lines are buffered.
    slen := str_len(content)
    ln : ., mut = 0
    loop:
        if ln >= slen:
            break
        s : ., mut = ln
        loop:
            if s >= slen:
                break
            c := load8(content, s)
            if c == 32 || c == 9:
                s = s + 1
            else:
                break
        e : ., mut = s
        loop:
            if e >= slen:
                break
            if load8(content, e) == 10:
                break
            e = e + 1
        if s < e && load8(content, s) != 35:
            // Ignore empty and comment lines.
            line := str_sub(content, s, e - s)
            if hit_inj_parse_line(line) != 0:
                return 1
        ln = e + 1
    // Pass 2: attach buffered lines to main in instruction order. Unmatched lines wait for a later instruction.
    entry : ., mut = -1
    fi : ., mut = 0
    loop:
        if fi >= g_ir_func_count:
            break
        if str_eq(istr_get(cell_load(g_ir_func_name_idx, fi * 8)), "main") != 0:
            entry = fi
            break
        fi = fi + 1
    if entry < 0:
        println("error: HIT events: no main function to attach events to")
        return 1
    hit_ev_map_init(g_ir_instr_count)
    mi : ., mut = 0
    loop:
        if mi >= g_ir_instr_count:
            break
        hit_ev_map_set(mi, 0, 0)
        mi = mi + 1
    ist := cell_load(g_ir_func_instr_start, entry * 8)
    ic := cell_load(g_ir_func_instr_count, entry * 8)
    cur : ., mut = 0   // next unattached line
    ii : ., mut = 0
    loop:
        if ii >= ic:
            break
        j := ist + ii
        if cur < g_hit_inj_count:
            op := iri_op(j)
            ti := iri_tk(j)
            subop : ., mut = -1
            if op == IR_BINARY:
                subop = iri_s3(j)
            l_id := hit_inj_line_id(cur)
            l_fl := hit_inj_line_flags(cur)
            l_pool : ., mut = 0
            if l_fl / 8 % 2 == 1:
                l_pool = 1
            if hit_inj_line_expected(op, subop, ti, l_id, l_pool) == 1:
                if l_id == HIT_EV_JUMP && l_fl / 2 % 2 == 0:
                    println("error: HIT events: jump event needs explicit s1 (target event ordinal)")
                    return 1
                // Attach: event values come from the line, with instruction defaults.
                d : ., mut = hit_inj_line_dst(cur)
                if l_fl % 2 == 0:
                    d = iri_dest(j)
                    if d < 0:
                        d = 0
                s1 : ., mut = hit_inj_line_s1(cur)
                if l_fl / 2 % 2 == 0:
                    s1 = iri_s1(j)
                    if s1 < 0:
                        s1 = 0
                s2 : ., mut = hit_inj_line_s2(cur)
                if l_fl / 4 % 2 == 0:
                    s2 = iri_s2(j)
                    if s2 < 0:
                        s2 = 0
                evfl : ., mut = 0
                if l_fl / 8 % 2 == 1:
                    evfl = evfl + HIT_ES_S1_POOL
                if l_fl / 16 % 2 == 1:
                    evfl = evfl + HIT_ES_S2_POOL
                hit_ev_append(l_id, d, s1, s2, evfl)
                hit_ev_map_set(j, g_hit_ev_count - 1, 1)
                cur = cur + 1
        ii = ii + 1
    // Pass 3: check leftover lines. An unattached line is unsupported or out of order.
    if cur < g_hit_inj_count:
        print("error: HIT events: no instruction expects event ")
        print(hit_event_name(hit_event_lookup(hit_inj_line_id(cur))))
        print(" (line ")
        print_i(cur + 1)
        println(")")
        return 1
    if g_hit_inj_count == 0:
        println("error: HIT events: file has no ev lines")
        return 1
    // Jump targets are event ordinals; check the range.
    ji : ., mut = 0
    loop:
        if ji >= g_hit_ev_count:
            break
        if hit_ev_id(ji) == HIT_EV_JUMP:
            t := hit_ev_s1(ji)
            if t < 0 || t >= g_hit_ev_count:
                print("error: HIT events: jump target event ordinal ")
                print_i(t)
                print(" out of range (0..")
                print_i(g_hit_ev_count - 1)
                println(")")
                return 1
        ji = ji + 1
    return 0

// Parse a numeric token starting at val. -1 means not a number.
fn hit_inj_parse_int(content: string, val: int) -> int:
    slen := str_len(content)
    p : ., mut = val
    if p < slen && load8(content, p) == 45:
        p = p + 1
    // A leading minus is allowed for negative pool values.
    if p >= slen:
        return -1
    if load8(content, p) < 48 || load8(content, p) > 57:
        return -1
    return str_int(str_sub(content, val, str_len(content) - val))

// Find token key= starting at fpos. Returns the value offset, -1 when the key is
// absent, or -2 when the value is not a number or a pool reference.
fn hit_inj_field_of(content: string, fpos: int, key: string, pool_ok: int) -> int:
    slen := str_len(content)
    klen := str_len(key)
    p : ., mut = fpos
    loop:
        if p + klen >= slen:
            return -1
        if load8(content, p + klen) == 61 && (p == fpos || load8(content, p - 1) == 32):
            m : ., mut = 0
            ok : ., mut = 1
            loop:
                if m >= klen:
                    break
                if load8(content, p + m) != load8(key, m):
                    ok = 0
                    break
                m = m + 1
            if ok == 1:
                v0 : ., mut = p + klen + 1
                if v0 >= slen:
                    return -2
                c := load8(content, v0)
                if pool_ok == 1 && c == 112 && v0 + 4 <= slen && load8(content, v0 + 1) == 111 && load8(content, v0 + 2) == 111 && load8(content, v0 + 3) == 108:
                    return v0
                if c >= 48 && c <= 57 || c == 45:
                    return v0
                return -2
        p = p + 1
    return -1
