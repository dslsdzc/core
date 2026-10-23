// === src/arch/hit/hit.cr ===
// Hardware interface table (HIT) loader: core-x86.toml to in-memory tables.
// The table data belongs to the architecture layer
// (src/arch/x86_64/core-x86.toml). This file is the engine and leaves the path to
// --table.
// Design and format are documented under docs/superpowers/specs and
// docs/superpowers/plans.
//
// The table is corearch's only platform dependency. load_hit_table reads the TOML
// into three compact buffers (events, projections, steps) plus runtime entries;
// the table-driven encoder reads them directly.
//
// Step templates describe prefix, REX, opcode, ModRM role or digit, SIB, disp,
// imm, rel, and condition. An event can have multiple projections; each
// [[event.proj.step]] section describes one step in a sequence; [runtime.x86]
// holds runtime entries. The older flat single-projection event form is a subset
// and still loads. Invalid values or associations reject the whole table.
//
// This file is part of the corearch build only; corec does not need it. The import
// lines let `corec check src/arch/hit/hit.cr` resolve symbols; concat builds strip
// them.
import io
import toml
import fmt

// ------------------------------------------------------------------
// In-memory table layout. Read directly; hit_w32 and hit_r32 handle
// little-endian fields.
// ------------------------------------------------------------------

// g_hit_events: 40 bytes per event, 10 i32 fields.
HIT_EVENT_REC : int = 40
HIT_EV_OFF_ID         : int = 0   // core event id: 1-4 data, 5-9 control, call, and system
HIT_EV_OFF_NAME       : int = 4   // name string index into g_hit_names
HIT_EV_OFF_INPUTS     : int = 8   // event signature; the minimal core has no width, register, or addressing fields
HIT_EV_OFF_OUTPUTS    : int = 12  // number of outputs
HIT_EV_OFF_SIDE       : int = 16  // 0 = pure, 1 = effect
// Fields 20, 24, and 28 mirror projection 0 for existing consumers, which read
// only the first projection through hit_proj_step(es, 0, st). Other projections
// use fields 32 and 36. The layout seen by the normal path is unchanged.
HIT_EV_OFF_ISA        : int = 20  // projection 0 ISA code (1 = x86-64)
HIT_EV_OFF_STEP_COUNT : int = 24  // projection 0 step count
HIT_EV_OFF_STEP_OFF   : int = 28  // byte offset of projection 0 first step in g_hit_steps
HIT_EV_OFF_PROJ_OFF   : int = 32  // first projection record index in g_hit_projs; 12 bytes each
HIT_EV_OFF_PROJ_COUNT : int = 36  // number of projections

// g_hit_projs: 12 bytes per projection, 3 i32 fields. Event fields 32 and 36 index this table.
HIT_PROJ_REC : int = 12
HIT_PJ_OFF_ISA        : int = 0   // projection ISA code
HIT_PJ_OFF_STEP_COUNT : int = 4   // step count for this projection
HIT_PJ_OFF_STEP_OFF   : int = 8   // byte offset of this projection first step in g_hit_steps

// g_hit_steps: 108 bytes per step. The first 20 bytes keep the older layout
// (OP0, OP1, REG_ROLE, RM_ROLE, RM_MODE) at the same offsets. Fields from byte 20
// are the current schema. Template bytes are prefix, REX, and opcode in that fixed
// order. ModRM, SIB, disp, imm, and rel are filled from roles and operands, not
// from template bytes.
HIT_STEP_REC : int = 108
HIT_ST_OFF_OP0      : int = 0    // first byte of the template stream (prefix, REX, opcode)
HIT_ST_OFF_OP1      : int = 4    // second template byte; 0 means none
HIT_ST_OFF_REG_ROLE : int = 8    // modrm.reg role code (1-6, or 16 + regno); 0 means none or a digit form
HIT_ST_OFF_RM_ROLE  : int = 12   // modrm.rm role code; same encoding, 0 means none
HIT_ST_OFF_RM_MODE  : int = 16   // 0 = rm is a register; 1 = base + disp with default base rbp; 2 = SIB
// Current schema fields from byte 20; unused fields are 0.
HIT_ST_OFF_PFX0        : int = 20  // prefix byte 0, such as 0x66 or 0x0F
HIT_ST_OFF_PFX1        : int = 24  // prefix byte 1
HIT_ST_OFF_REX         : int = 28  // REX byte: 0x40 | w<<3 | r<<2 | x<<1 | b; 0 means none
HIT_ST_OFF_OPB0        : int = 32  // opcode byte 0
HIT_ST_OFF_OPB1        : int = 36  // opcode byte 1
HIT_ST_OFF_OPB2        : int = 40  // opcode byte 2
HIT_ST_OFF_OPN         : int = 44  // opcode byte count, 1 to 3
HIT_ST_OFF_REG_IS_DIGIT : int = 48 // 1 when reg is a /digit instead of a role
HIT_ST_OFF_REG_DIGIT   : int = 52  // digit value, 0 to 7
HIT_ST_OFF_BASE_ROLE   : int = 56  // base role code: modrm base for rm_mode 1, 0 for default rbp;
                                    // SIB base for rm_mode 2; rip = 32 for pool, rodata, and global forms
HIT_ST_OFF_SIB_SCALE   : int = 60  // SIB scale 0 to 3; 0 outside rm_mode 2
HIT_ST_OFF_SIB_INDEX   : int = 64  // SIB index role code
HIT_ST_OFF_DISP_SIZE   : int = 68  // disp width: 0 = auto, 1 or 4 for a literal size
HIT_ST_OFF_DISP_SRC    : int = 72  // disp source role code; 0 means none or implied by the slot
HIT_ST_OFF_IMM_SIZE    : int = 76  // imm width 1, 2, 4, or 8; 0 means none
HIT_ST_OFF_IMM_ROLE    : int = 80  // imm operand role code; literal lit = 100
HIT_ST_OFF_IMM_KIND    : int = 84  // imm patch kind: 0 none, 1 fnaddr
HIT_ST_OFF_IMM_LIT     : int = 88  // imm literal value when imm_role is lit
HIT_ST_OFF_REL_ROLE    : int = 92  // rel patch operand role code; 0 means none
HIT_ST_OFF_REL_KIND    : int = 96  // rel table: 1 event position, 2 function, 3 external symbol
HIT_ST_OFF_REL_SIZE    : int = 100 // rel width, 8 or 32
HIT_ST_OFF_COND_ROLE   : int = 104 // branch condition source slot role code

// Role, effect, and ISA codes.
HIT_ROLE_DST  : int = 1
HIT_ROLE_SRC1 : int = 2
HIT_ROLE_SRC2 : int = 3
HIT_ROLE_ADDR : int = 4
HIT_ROLE_VAL  : int = 5
HIT_ROLE_COND : int = 6          // branch condition source
HIT_SIDE_PURE : int = 0
HIT_SIDE_EFFECT : int = 1
HIT_ISA_X86 : int = 1
// Additional operand codes; disjoint from role codes.
HIT_REG_BASE : int = 16          // register literal = 16 + regno (rax=0 through r15=15)
HIT_CODE_RIP : int = 32          // rip base; valid only in a base field
HIT_CODE_LIT : int = 100         // imm literal when imm_role is lit
// Relocation kind codes.
HIT_REL_EVENT : int = 1
HIT_REL_FUNC  : int = 2
HIT_REL_EXTERN : int = 3
// Immediate kind codes.
HIT_IMM_FNADDR : int = 1
// [runtime.x86] entry slots, 4 bytes each; see hit_parse_runtime_chunk.
HIT_RT_CALL_MECHANISM  : int = 0
HIT_RT_CALL_RET_ADDR   : int = 1
HIT_RT_CALL_STACK_GROW : int = 2
HIT_RT_PARAM_MODE      : int = 3
HIT_RT_PARAM_MASK      : int = 4
HIT_RT_SAVE_MASK       : int = 5
HIT_RT_EXTERN_ENTRY    : int = 6
HIT_RT_EXTERN_RESOLVE  : int = 7

// Table loader globals. This file is part of the corearch build only.
g_hit_events : string, mut
g_hit_event_count : int, mut
g_hit_event_cap : int, mut
g_hit_steps  : string, mut
g_hit_step_count : int, mut
g_hit_step_cap : int, mut
g_hit_projs  : string, mut
g_hit_proj_count : int, mut
g_hit_proj_cap : int, mut
g_hit_names  : string, mut
g_hit_name_count : int, mut
g_hit_name_cap : int, mut
g_hit_runtime : string, mut
g_hit_runtime_present : int, mut

// ------------------------------------------------------------------
// Buffer helpers. They use only the runtime builtins load8, store8, and alloc.
// ------------------------------------------------------------------

fn hit_copy_bytes(src: string, n: int, dst: string):
    i : int, mut = 0
    loop:
        if i >= n:
            break
        store8(dst, i, load8(src, i))
        i = i + 1

// 4-byte little-endian write and read. Stored ids, bytes, and codes are
// non-negative. Byte extraction uses division and modulo; this file has no
// bitwise and. hit_bit uses doubling because the language has no shift operator.
fn hit_w32(buf: string, pos: int, v: int):
    store8(buf, pos + 0, v % 256)
    store8(buf, pos + 1, (v / 256) % 256)
    store8(buf, pos + 2, (v / 65536) % 256)
    store8(buf, pos + 3, (v / 16777216) % 256)

fn hit_r32(buf: string, pos: int) -> int:
    return load8(buf, pos) + load8(buf, pos + 1) * 256 + load8(buf, pos + 2) * 65536 + load8(buf, pos + 3) * 16777216

fn hit_zero_bytes(buf: string, from: int, n: int):
    i : int, mut = 0
    loop:
        if i >= n:
            break
        store8(buf, from + i, 0)
        i = i + 1

fn hit_grow_events(needed: int):
    if needed < g_hit_event_cap:
        return
    nc : int, mut = g_hit_event_cap * 2
    if nc < 16:
        nc = 16
    if nc < needed:
        nc = needed + 4
    nb := alloc(nc * HIT_EVENT_REC)
    hit_copy_bytes(g_hit_events, g_hit_event_cap * HIT_EVENT_REC, nb)
    g_hit_events = nb
    g_hit_event_cap = nc

fn hit_grow_steps(needed: int):
    if needed < g_hit_step_cap:
        return
    nc : int, mut = g_hit_step_cap * 2
    if nc < 16:
        nc = 16
    if nc < needed:
        nc = needed + 4
    nb := alloc(nc * HIT_STEP_REC)
    hit_copy_bytes(g_hit_steps, g_hit_step_cap * HIT_STEP_REC, nb)
    g_hit_steps = nb
    g_hit_step_cap = nc

fn hit_grow_projs(needed: int):
    if needed < g_hit_proj_cap:
        return
    nc : int, mut = g_hit_proj_cap * 2
    if nc < 16:
        nc = 16
    if nc < needed:
        nc = needed + 4
    nb := alloc(nc * HIT_PROJ_REC)
    hit_copy_bytes(g_hit_projs, g_hit_proj_cap * HIT_PROJ_REC, nb)
    g_hit_projs = nb
    g_hit_proj_cap = nc

fn hit_grow_names(needed: int):
    if needed < g_hit_name_cap:
        return
    nc : int, mut = g_hit_name_cap * 2
    if nc < 16:
        nc = 16
    if nc < needed:
        nc = needed + 4
    nb := alloc(nc * 8)
    hit_copy_bytes(g_hit_names, g_hit_name_cap * 8, nb)
    g_hit_names = nb
    g_hit_name_cap = nc

// ------------------------------------------------------------------
// TOML text scanning for table structure. Scalar parsing uses stdlib toml.cr.
// ------------------------------------------------------------------

// Scan lines from pos and return the offset of the first line whose tag matches,
// or -1. Leading whitespace is allowed. The tag must be followed by end of line,
// whitespace, carriage return, or a comment. This accepts a hand-written
// "[[event.proj]]   # comment" and prevents "[[event]]" from matching the prefix
// of "[[event.proj]]".
fn hit_find_tag(content: string, pos: int, tag: string) -> int:
    slen := str_len(content)
    tlen := str_len(tag)
    p : int, mut = pos
    loop:
        if p >= slen:
            break
        s : int, mut = p
        loop:
            if s >= slen:
                break
            c := load8(content, s)
            if c == 32 || c == 9:
                s = s + 1
            else:
                break
        e : int, mut = s
        loop:
            if e >= slen:
                break
            if load8(content, e) == 10:
                break
            e = e + 1
        if s + tlen <= e:
            m : int, mut = 0
            ok : int, mut = 1
            loop:
                if m >= tlen:
                    break
                if load8(content, s + m) != load8(tag, m):
                    ok = 0
                    break
                m = m + 1
            if ok == 1:
                if s + tlen == e:
                    return s
                // tag 到行尾（\n 或 EOF）
                c2 := load8(content, s + tlen)
                if c2 == 13 || c2 == 32 || c2 == 9 || c2 == 35:
                    return s
        p = e + 1
    return -1

// Offset just after the line containing pos, or the text length at end of file.
fn hit_line_after(content: string, pos: int) -> int:
    slen := str_len(content)
    i : int, mut = pos
    loop:
        if i >= slen:
            break
        if load8(content, i) == 10:
            return i + 1
        i = i + 1
    return slen

// Whether text has a line whose first token equals key. Token terminators are
// whitespace, '=', or end of line. Comment lines are skipped.
fn hit_has_key(text: string, key: string) -> int:
    slen := str_len(text)
    klen := str_len(key)
    p : int, mut = 0
    loop:
        if p >= slen:
            break
        s : int, mut = p
        loop:
            if s >= slen:
                break
            c := load8(text, s)
            if c == 32 || c == 9:
                s = s + 1
            else:
                break
        e : int, mut = s
        loop:
            if e >= slen:
                break
            if load8(text, e) == 10:
                break
            e = e + 1
        if s < e && load8(text, s) == 35:
            p = e + 1
            continue
        // '#' 注释行
        t : int, mut = s
        loop:
            if t >= e:
                break
            c := load8(text, t)
            if c == 32 || c == 9 || c == 61:
                break
            t = t + 1
        if t - s == klen:
            m : int, mut = 0
            ok : int, mut = 1
            loop:
                if m >= klen:
                    break
                if load8(text, s + m) != load8(key, m):
                    ok = 0
                    break
                m = m + 1
            if ok == 1:
                return 1
        p = e + 1
    return 0

// Whether the space-separated allowed list contains key as a whole token.
fn hit_key_allowed(allowed: string, key: string) -> int:
    alen := str_len(allowed)
    klen := str_len(key)
    p : int, mut = 0
    loop:
        if p >= alen:
            break
        loop:
            if p >= alen:
                break
            if load8(allowed, p) == 32:
                p = p + 1
            else:
                break
        if p >= alen:
            break
        e : int, mut = p
        loop:
            if e >= alen:
                break
            if load8(allowed, e) == 32:
                break
            e = e + 1
        if e - p == klen:
            m : int, mut = 0
            ok : int, mut = 1
            loop:
                if m >= klen:
                    break
                if load8(allowed, p + m) != load8(key, m):
                    ok = 0
                    break
                m = m + 1
            if ok == 1:
                return 1
        p = e
    return 0

// Check every non-comment line against the allowed key list and report
// "unknown key" for the first unmatched key. Returns 0 when clean and 1 after
// reporting an unknown key.
fn hit_scan_keys_ok(text: string, allowed: string) -> int:
    slen := str_len(text)
    p : int, mut = 0
    loop:
        if p >= slen:
            break
        s : int, mut = p
        loop:
            if s >= slen:
                break
            c := load8(text, s)
            if c == 32 || c == 9:
                s = s + 1
            else:
                break
        e : int, mut = s
        loop:
            if e >= slen:
                break
            if load8(text, e) == 10:
                break
            e = e + 1
        if s < e && load8(text, s) != 35:
            // Non-comment line.
            t : int, mut = s
            loop:
                if t >= e:
                    break
                c := load8(text, t)
                if c == 32 || c == 9 || c == 61:
                    break
                t = t + 1
            if t > s:
                tok := str_sub(text, s, t - s)
                if hit_key_allowed(allowed, tok) == 0:
                    print("error: HIT table: unknown key '")
                    print(tok)
                    println("'")
                    return 1
        p = e + 1
    return 0

// Raw value after key=, trimmed and before a trailing comment. Quotes are preserved.
fn hit_raw_str(text: string, key: string) -> string:
    slen := str_len(text)
    klen := str_len(key)
    p : int, mut = 0
    loop:
        if p >= slen:
            return ""
        s : int, mut = p
        loop:
            if s >= slen:
                break
            c := load8(text, s)
            if c == 32 || c == 9:
                s = s + 1
            else:
                break
        e : int, mut = s
        loop:
            if e >= slen:
                break
            if load8(text, e) == 10:
                break
            e = e + 1
        if s < e && load8(text, s) != 35 && s + klen <= e:
            m : int, mut = 0
            ok : int, mut = 1
            loop:
                if m >= klen:
                    break
                if load8(text, s + m) != load8(key, m):
                    ok = 0
                    break
                m = m + 1
            if ok == 1:
                q : int, mut = s + klen
                loop:
                    if q >= e:
                        break
                    if load8(text, q) == 32 || load8(text, q) == 9:
                        q = q + 1
                    else:
                        break
                if q < e && load8(text, q) == 61:
                    v0 : int, mut = q + 1
                    loop:
                        if v0 >= e:
                            break
                        if load8(text, v0) == 32 || load8(text, v0) == 9:
                            v0 = v0 + 1
                        else:
                            break
                    v1 : int, mut = v0
                    loop:
                        if v1 >= e:
                            break
                        if load8(text, v1) == 35:
                            break
                        // Trailing comment starts here.
                        v1 = v1 + 1
                    loop:
                        if v1 <= v0:
                            break
                        c := load8(text, v1 - 1)
                        if c == 32 || c == 9 || c == 13:
                            v1 = v1 - 1
                        else:
                            break
                    return str_sub(text, v0, v1 - v0)
        p = e + 1
    return ""

// Event name to role code 1 through 6. 0 means unknown or absent.
fn hit_role_code(name: string) -> int:
    if str_eq(name, "dst") != 0:
        return HIT_ROLE_DST
    if str_eq(name, "src1") != 0:
        return HIT_ROLE_SRC1
    if str_eq(name, "src2") != 0:
        return HIT_ROLE_SRC2
    if str_eq(name, "addr") != 0:
        return HIT_ROLE_ADDR
    if str_eq(name, "val") != 0:
        return HIT_ROLE_VAL
    if str_eq(name, "cond") != 0:
        return HIT_ROLE_COND
    return 0

// Register name to regno 0 through 15. -1 means not a register.
fn hit_reg_code(name: string) -> int:
    if str_eq(name, "rax") != 0:
        return 0
    if str_eq(name, "rcx") != 0:
        return 1
    if str_eq(name, "rdx") != 0:
        return 2
    if str_eq(name, "rbx") != 0:
        return 3
    if str_eq(name, "rsp") != 0:
        return 4
    if str_eq(name, "rbp") != 0:
        return 5
    if str_eq(name, "rsi") != 0:
        return 6
    if str_eq(name, "rdi") != 0:
        return 7
    if str_eq(name, "r8") != 0:
        return 8
    if str_eq(name, "r9") != 0:
        return 9
    if str_eq(name, "r10") != 0:
        return 10
    if str_eq(name, "r11") != 0:
        return 11
    if str_eq(name, "r12") != 0:
        return 12
    if str_eq(name, "r13") != 0:
        return 13
    if str_eq(name, "r14") != 0:
        return 14
    if str_eq(name, "r15") != 0:
        return 15
    return -1

// Operand code: role 1 through 6, or 16 + regno for a register literal. 0 means unknown.
fn hit_operand_code(name: string) -> int:
    rc := hit_role_code(name)
    if rc != 0:
        return rc
    rn := hit_reg_code(name)
    if rn >= 0:
        return HIT_REG_BASE + rn
    return 0

// Base code: an operand code or rip (32). 0 means unknown.
fn hit_base_code(name: string) -> int:
    oc := hit_operand_code(name)
    if oc != 0:
        return oc
    if str_eq(name, "rip") != 0:
        return HIT_CODE_RIP
    return 0

// Compute 2^n by doubling; the language has no shift or bitwise operators.
fn hit_bit(n: int) -> int:
    b : int, mut = 1
    i : int, mut = 0
    loop:
        if i >= n:
            break
        b = b * 2
        i = i + 1
    return b

fn hit_err_ev(ev_id: int):
    print("error: HIT table: event ")
    print_i(ev_id)
    print(": ")

fn hit_err_step(ev_id: int, step_no: int):
    print("error: HIT table: event ")
    print_i(ev_id)
    print(" step ")
    print_i(step_no)
    print(": ")

// ------------------------------------------------------------------
// Step field parsing for the table template language
// ------------------------------------------------------------------
// text is one [[event.proj.step]] section, or the projection body of an older
// flat projection when isa_ok = 1. On success, append one 108-byte step record.
// Returns 0 on success and 1 after printing an error.
fn hit_parse_step(text: string, ev_id: int, step_no: int, isa_ok: int) -> int:
    if isa_ok == 1:
        if hit_scan_keys_ok(text, "isa prefix opcode rex_w rex_r rex_x rex_b modrm_reg_role modrm_reg_digit modrm_rm_role rm_mode modrm_base_role sib_scale sib_index_role sib_base_role disp_size disp_src imm_size imm_role imm_lit imm_kind rel_role rel_kind rel_size cond_role") != 0:
            return 1
    else:
        if hit_scan_keys_ok(text, "prefix opcode rex_w rex_r rex_x rex_b modrm_reg_role modrm_reg_digit modrm_rm_role rm_mode modrm_base_role sib_scale sib_index_role sib_base_role disp_size disp_src imm_size imm_role imm_lit imm_kind rel_role rel_kind rel_size cond_role") != 0:
            return 1
    // Output record fields. Each group overwrites its defaults.
    op0 : int, mut = 0
    op1 : int, mut = 0
    reg_code : int, mut = 0
    is_digit : int, mut = 0
    digit_val : int, mut = 0
    rm_code : int, mut = 0
    rm_mode : int, mut = 0
    base_code : int, mut = 0
    scl_val : int, mut = 0
    idx_code : int, mut = 0
    dsz_code : int, mut = 0
    dsrc_code : int, mut = 0
    isz_val : int, mut = 0
    iro_code : int, mut = 0
    ik_val : int, mut = 0
    ilit_val : int, mut = 0
    rro_code : int, mut = 0
    rk_val : int, mut = 0
    rs_val : int, mut = 0
    cond_code : int, mut = 0
    rex_byte : int, mut = 0
    npf : int, mut = 0
    pfx0 : int, mut = 0
    pfx1 : int, mut = 0
    // REX bits must be 0 or 1. A REX byte is emitted when at least one bit is set.
    rwp := hit_has_key(text, "rex_w")
    rrp := hit_has_key(text, "rex_r")
    rxp := hit_has_key(text, "rex_x")
    rbp := hit_has_key(text, "rex_b")
    rw : int, mut = 0
    rr : int, mut = 0
    rx : int, mut = 0
    rb : int, mut = 0
    if rwp == 1:
        rw = toml_get_int(text, "rex_w")
    if rrp == 1:
        rr = toml_get_int(text, "rex_r")
    if rxp == 1:
        rx = toml_get_int(text, "rex_x")
    if rbp == 1:
        rb = toml_get_int(text, "rex_b")
    if rwp == 1 && (rw < 0 || rw > 1):
        hit_err_step(ev_id, step_no)
        println("bad rex bit")
        return 1
    if rrp == 1 && (rr < 0 || rr > 1):
        hit_err_step(ev_id, step_no)
        println("bad rex bit")
        return 1
    if rxp == 1 && (rx < 0 || rx > 1):
        hit_err_step(ev_id, step_no)
        println("bad rex bit")
        return 1
    if rbp == 1 && (rb < 0 || rb > 1):
        hit_err_step(ev_id, step_no)
        println("bad rex bit")
        return 1
    if (rwp == 1 && rw == 1) || (rrp == 1 && rr == 1) || (rxp == 1 && rx == 1) || (rbp == 1 && rb == 1):
        rex_byte = 0x40
        if rwp == 1 && rw == 1:
            rex_byte = rex_byte + 8
        if rrp == 1 && rr == 1:
            rex_byte = rex_byte + 4
        if rxp == 1 && rx == 1:
            rex_byte = rex_byte + 2
        if rbp == 1 && rb == 1:
            rex_byte = rex_byte + 1
    // Prefix: at most two bytes, each 0 to 255.
    if hit_has_key(text, "prefix") == 1:
        pfb := alloc(16)
        npf = toml_get_int_list(text, "prefix", pfb, 3)
        if npf < 0:
            hit_err_step(ev_id, step_no)
            println("prefix missing/malformed")
            return 1
        if npf > 2:
            hit_err_step(ev_id, step_no)
            println("prefix >2 bytes")
            return 1
        j : int, mut = 0
        loop:
            if j >= npf:
                break
            if hit_r32(pfb, j * 4) > 255:
                hit_err_step(ev_id, step_no)
                println("prefix byte >255 (not a byte)")
                return 1
            j = j + 1
        if npf >= 1:
            pfx0 = hit_r32(pfb, 0)
        if npf >= 2:
            pfx1 = hit_r32(pfb, 4)
    // Opcode: required, one to three bytes, each 0 to 255.
    opc_p := hit_has_key(text, "opcode")
    opb := alloc(16)
    nop := toml_get_int_list(text, "opcode", opb, 4)
    if opc_p == 0 || nop < 1:
        hit_err_step(ev_id, step_no)
        println("opcode missing/malformed")
        return 1
    if nop > 3:
        hit_err_step(ev_id, step_no)
        println("opcode >3 bytes")
        return 1
    j : int, mut = 0
    loop:
        if j >= nop:
            break
        if hit_r32(opb, j * 4) > 255:
            hit_err_step(ev_id, step_no)
            println("opcode byte >255 (not a byte)")
            return 1
        j = j + 1
    // ModRM field groups. A group is present only when at least one key appears.
    h_role  := hit_has_key(text, "modrm_reg_role")
    h_digit := hit_has_key(text, "modrm_reg_digit")
    h_rm    := hit_has_key(text, "modrm_rm_role")
    h_mode  := hit_has_key(text, "rm_mode")
    h_base  := hit_has_key(text, "modrm_base_role")
    h_scl   := hit_has_key(text, "sib_scale")
    h_sidx  := hit_has_key(text, "sib_index_role")
    h_sbas  := hit_has_key(text, "sib_base_role")
    h_dsz   := hit_has_key(text, "disp_size")
    h_dsrc  := hit_has_key(text, "disp_src")
    grp := h_role + h_digit + h_rm + h_mode + h_base + h_scl + h_sidx + h_sbas + h_dsz + h_dsrc
    if grp > 0:
        if h_role == 1 && h_digit == 1:
            hit_err_step(ev_id, step_no)
            println("modrm reg role and digit both present")
            return 1
        if h_role == 0 && h_digit == 0:
            hit_err_step(ev_id, step_no)
            println("modrm reg role/digit missing")
            return 1
        if h_role == 1:
            reg_code = hit_operand_code(toml_get_str(text, "modrm_reg_role"))
            if reg_code == 0:
                hit_err_step(ev_id, step_no)
                println("unknown modrm role")
                return 1
        else:
            digit_val = toml_get_int(text, "modrm_reg_digit")
            if digit_val < 0 || digit_val > 7:
                hit_err_step(ev_id, step_no)
                println("bad reg digit")
                return 1
            is_digit = 1
        if h_rm == 0:
            hit_err_step(ev_id, step_no)
            println("modrm rm role missing")
            return 1
        rm_code = hit_operand_code(toml_get_str(text, "modrm_rm_role"))
        if rm_code == 0:
            hit_err_step(ev_id, step_no)
            println("unknown modrm role")
            return 1
        if h_mode == 1:
            rm_mode = toml_get_int(text, "rm_mode")
            if rm_mode < 0 || rm_mode > 2:
                hit_err_step(ev_id, step_no)
                println("bad rm_mode")
                return 1
        if h_scl + h_sidx + h_sbas > 0 && rm_mode != 2:
            hit_err_step(ev_id, step_no)
            println("sib fields need rm_mode 2")
            return 1
        if rm_mode == 2 && (h_scl == 0 || h_sbas == 0):
            hit_err_step(ev_id, step_no)
            println("rm_mode 2 needs sib_scale and sib_base_role")
            return 1
        if h_base == 1 && rm_mode == 0:
            hit_err_step(ev_id, step_no)
            println("modrm_base_role needs rm_mode 1/2")
            return 1
        if h_base == 1 && rm_mode == 1:
            base_code = hit_base_code(toml_get_str(text, "modrm_base_role"))
            if base_code == 0:
                hit_err_step(ev_id, step_no)
                println("bad modrm_base_role")
                return 1
        if (h_dsz + h_dsrc > 0) && rm_mode == 0:
            hit_err_step(ev_id, step_no)
            println("disp needs rm_mode 1/2")
            return 1
        if rm_mode == 2:
            scl_val = toml_get_int(text, "sib_scale")
            if scl_val < 0 || scl_val > 3:
                hit_err_step(ev_id, step_no)
                println("bad sib_scale")
                return 1
            if h_sidx == 1:
                idx_code = hit_operand_code(toml_get_str(text, "sib_index_role"))
                if idx_code == 0:
                    hit_err_step(ev_id, step_no)
                    println("bad sib_index_role")
                    return 1
            base_code = hit_base_code(toml_get_str(text, "sib_base_role"))
            if base_code == 0:
                hit_err_step(ev_id, step_no)
                println("bad sib_base_role")
                return 1
        if h_dsz == 1:
            dv := hit_raw_str(text, "disp_size")
            if str_len(dv) >= 2 && load8(dv, 0) == 34 && load8(dv, str_len(dv) - 1) == 34:
                dv = str_sub(dv, 1, str_len(dv) - 2)
            dv_ok : int, mut = 0
            if str_eq(dv, "auto") != 0:
                dsz_code = 0
                dv_ok = 1
            if str_eq(dv, "1") != 0:
                dsz_code = 1
                dv_ok = 1
            if str_eq(dv, "4") != 0:
                dsz_code = 4
                dv_ok = 1
            if dv_ok == 0:
                hit_err_step(ev_id, step_no)
                println("bad disp_size")
                return 1
        if h_dsrc == 1:
            dsrc_code = hit_operand_code(toml_get_str(text, "disp_src"))
            if dsrc_code == 0:
                hit_err_step(ev_id, step_no)
                println("bad disp_src")
                return 1
    // Immediate fields, independent of the ModRM group.
    h_isz  := hit_has_key(text, "imm_size")
    h_iro  := hit_has_key(text, "imm_role")
    h_ik   := hit_has_key(text, "imm_kind")
    h_ilit := hit_has_key(text, "imm_lit")
    if h_isz == 1:
        isz_val = toml_get_int(text, "imm_size")
        if isz_val != 1 && isz_val != 2 && isz_val != 4 && isz_val != 8:
            hit_err_step(ev_id, step_no)
            println("bad imm_size")
            return 1
        if h_iro == 0 && h_ik == 0:
            hit_err_step(ev_id, step_no)
            println("imm_size without imm_role/imm_kind")
            return 1
    if h_iro == 1:
        inm := toml_get_str(text, "imm_role")
        if str_eq(inm, "lit") != 0:
            iro_code = HIT_CODE_LIT
        else:
            iro_code = hit_operand_code(inm)
            if iro_code == 0:
                hit_err_step(ev_id, step_no)
                println("bad imm_role")
                return 1
    if h_ik == 1:
        if str_eq(toml_get_str(text, "imm_kind"), "fnaddr") == 0:
            hit_err_step(ev_id, step_no)
            println("bad imm_kind")
            return 1
        if h_isz == 0 || isz_val != 8:
            hit_err_step(ev_id, step_no)
            println("imm_kind fnaddr needs imm_size 8")
            return 1
        ik_val = HIT_IMM_FNADDR
    if h_ilit == 1:
        ilit_val = toml_get_int(text, "imm_lit")
        if ilit_val < 0:
            hit_err_step(ev_id, step_no)
            println("bad imm_lit (negative unsupported)")
            return 1
    // Relocation fields must appear together. kind is event, func, or extern; size is 8 or 32.
    h_rro := hit_has_key(text, "rel_role")
    h_rk  := hit_has_key(text, "rel_kind")
    h_rs  := hit_has_key(text, "rel_size")
    if h_rro + h_rk + h_rs > 0:
        if h_rro == 0 || h_rk == 0 || h_rs == 0:
            hit_err_step(ev_id, step_no)
            println("rel fields incomplete (role/kind/size)")
            return 1
        rkn := toml_get_str(text, "rel_kind")
        if str_eq(rkn, "event") == 0 && str_eq(rkn, "func") == 0 && str_eq(rkn, "extern") == 0:
            hit_err_step(ev_id, step_no)
            println("bad rel kind")
            return 1
        if str_eq(rkn, "event") != 0:
            rk_val = HIT_REL_EVENT
        if str_eq(rkn, "func") != 0:
            rk_val = HIT_REL_FUNC
        if str_eq(rkn, "extern") != 0:
            rk_val = HIT_REL_EXTERN
        rs_val = toml_get_int(text, "rel_size")
        if rs_val != 8 && rs_val != 32:
            hit_err_step(ev_id, step_no)
            println("bad rel size")
            return 1
        rro_code = hit_operand_code(toml_get_str(text, "rel_role"))
        if rro_code == 0:
            hit_err_step(ev_id, step_no)
            println("bad rel role")
            return 1
    // Condition field for a branch source slot.
    if hit_has_key(text, "cond_role") == 1:
        cond_code = hit_operand_code(toml_get_str(text, "cond_role"))
        if cond_code == 0:
            hit_err_step(ev_id, step_no)
            println("bad cond_role")
            return 1
    // Assemble template bytes in prefix, REX, opcode order and append the step record.
    stb := alloc(8)
    nst : int, mut = 0
    if npf >= 1:
        store8(stb, nst, pfx0)
        nst = nst + 1
    if npf >= 2:
        store8(stb, nst, pfx1)
        nst = nst + 1
    if rex_byte != 0:
        store8(stb, nst, rex_byte)
        nst = nst + 1
    j = 0
    loop:
        if j >= nop:
            break
        store8(stb, nst, hit_r32(opb, j * 4))
        nst = nst + 1
        j = j + 1
    if nst > 0:
        op0 = load8(stb, 0)
    if nst > 1:
        op1 = load8(stb, 1)
    hit_grow_steps(g_hit_step_count + 1)
    sb := g_hit_step_count * HIT_STEP_REC
    g_hit_step_count = g_hit_step_count + 1
    hit_zero_bytes(g_hit_steps, sb, HIT_STEP_REC)
    hit_w32(g_hit_steps, sb + HIT_ST_OFF_OP0, op0)
    hit_w32(g_hit_steps, sb + HIT_ST_OFF_OP1, op1)
    hit_w32(g_hit_steps, sb + HIT_ST_OFF_REG_ROLE, reg_code)
    hit_w32(g_hit_steps, sb + HIT_ST_OFF_RM_ROLE, rm_code)
    hit_w32(g_hit_steps, sb + HIT_ST_OFF_RM_MODE, rm_mode)
    hit_w32(g_hit_steps, sb + HIT_ST_OFF_PFX0, pfx0)
    hit_w32(g_hit_steps, sb + HIT_ST_OFF_PFX1, pfx1)
    hit_w32(g_hit_steps, sb + HIT_ST_OFF_REX, rex_byte)
    hit_w32(g_hit_steps, sb + HIT_ST_OFF_OPB0, hit_r32(opb, 0))
    hit_w32(g_hit_steps, sb + HIT_ST_OFF_OPB1, hit_r32(opb, 4))
    hit_w32(g_hit_steps, sb + HIT_ST_OFF_OPB2, hit_r32(opb, 8))
    hit_w32(g_hit_steps, sb + HIT_ST_OFF_OPN, nop)
    hit_w32(g_hit_steps, sb + HIT_ST_OFF_REG_IS_DIGIT, is_digit)
    hit_w32(g_hit_steps, sb + HIT_ST_OFF_REG_DIGIT, digit_val)
    hit_w32(g_hit_steps, sb + HIT_ST_OFF_BASE_ROLE, base_code)
    hit_w32(g_hit_steps, sb + HIT_ST_OFF_SIB_SCALE, scl_val)
    hit_w32(g_hit_steps, sb + HIT_ST_OFF_SIB_INDEX, idx_code)
    hit_w32(g_hit_steps, sb + HIT_ST_OFF_DISP_SIZE, dsz_code)
    hit_w32(g_hit_steps, sb + HIT_ST_OFF_DISP_SRC, dsrc_code)
    hit_w32(g_hit_steps, sb + HIT_ST_OFF_IMM_SIZE, isz_val)
    hit_w32(g_hit_steps, sb + HIT_ST_OFF_IMM_ROLE, iro_code)
    hit_w32(g_hit_steps, sb + HIT_ST_OFF_IMM_KIND, ik_val)
    hit_w32(g_hit_steps, sb + HIT_ST_OFF_IMM_LIT, ilit_val)
    hit_w32(g_hit_steps, sb + HIT_ST_OFF_REL_ROLE, rro_code)
    hit_w32(g_hit_steps, sb + HIT_ST_OFF_REL_KIND, rk_val)
    hit_w32(g_hit_steps, sb + HIT_ST_OFF_REL_SIZE, rs_val)
    hit_w32(g_hit_steps, sb + HIT_ST_OFF_COND_ROLE, cond_code)
    return 0

// ------------------------------------------------------------------
// Parse one [[event.proj]] section at ph. It may be a multi-step projection or
// a flat single-step projection.
// ------------------------------------------------------------------
// Returns 0 on success and 1 after printing an error.
fn hit_parse_proj_section(chunk: string, ph: int, ev_id: int) -> int:
    pl := hit_line_after(chunk, ph)
    // Projection text ends at the next [[event.proj]] for a flat projection, or
    // at the first step header. A step header counts only when it precedes the
    // next projection header.
    nxt_pr := hit_find_tag(chunk, pl, "[[event.proj]]")
    st_hdr := hit_find_tag(chunk, pl, "[[event.proj.step]]")
    sectioned : int, mut = 0
    pend : int, mut = str_len(chunk)
    if st_hdr >= 0 && (nxt_pr < 0 || st_hdr < nxt_pr):
        sectioned = 1
        pend = st_hdr
    else if nxt_pr >= 0:
        pend = nxt_pr
    pfields := str_sub(chunk, pl, pend - pl)
    // isa is required and must be x86-64. In a flat projection it shares the step fields.
    if str_eq(toml_get_str(pfields, "isa"), "x86-64") == 0:
        hit_err_ev(ev_id)
        println("unknown isa")
        return 1
    first_step := g_hit_step_count
    scnt : int, mut = 0
    if sectioned == 0:
        // Flat single step. Fields other than isa are step fields.
        if hit_parse_step(pfields, ev_id, 0, 1) != 0:
            return 1
        scnt = 1
    else:
        if hit_scan_keys_ok(pfields, "isa") != 0:
            return 1
        // Parse each step section. Step text ends at the next step header, the next projection header, or the chunk end.
        sp : int, mut = st_hdr
        loop:
            if sp < 0:
                break
            sl := hit_line_after(chunk, sp)
            ns := hit_find_tag(chunk, sl, "[[event.proj.step]]")
            np2 := hit_find_tag(chunk, sl, "[[event.proj]]")
            send : int, mut = str_len(chunk)
            if ns >= 0 && ns < send:
                send = ns
            if np2 >= 0 && np2 < send:
                send = np2
            stext := str_sub(chunk, sl, send - sl)
            if hit_parse_step(stext, ev_id, scnt, 0) != 0:
                return 1
            scnt = scnt + 1
            // A next step header after the next projection header belongs to a
            // later projection and must not continue this one. Without this
            // boundary, later steps would be counted here and inserted twice.
            if ns >= 0 && (np2 < 0 || ns < np2):
                sp = ns
            else:
                sp = -1
        if scnt == 0:
            hit_err_ev(ev_id)
            println("projection has no steps")
            return 1
    // Append the projection record: ISA, step count, and first-step byte offset.
    hit_grow_projs(g_hit_proj_count + 1)
    ps := g_hit_proj_count
    g_hit_proj_count = ps + 1
    hit_w32(g_hit_projs, ps * HIT_PROJ_REC + HIT_PJ_OFF_ISA, HIT_ISA_X86)
    hit_w32(g_hit_projs, ps * HIT_PROJ_REC + HIT_PJ_OFF_STEP_COUNT, scnt)
    hit_w32(g_hit_projs, ps * HIT_PROJ_REC + HIT_PJ_OFF_STEP_OFF, first_step * HIT_STEP_REC)
    return 0

// ------------------------------------------------------------------
// Parse one [[event]] section and all of its projections.
// ------------------------------------------------------------------
// chunk starts at the [[event]] line and ends before the next section.
// Returns 0 on success and 1 after printing an error.
fn hit_parse_event_chunk(chunk: string) -> int:
    // Event fields span from the header line to the first projection or step section. A step before a projection is a structural error.
    fe := hit_line_after(chunk, 0)
    p_off := hit_find_tag(chunk, fe, "[[event.proj]]")
    s_off := hit_find_tag(chunk, fe, "[[event.proj.step]]")
    if s_off >= 0 && (p_off < 0 || s_off < p_off):
        println("error: HIT table: stray [[event.proj.step]] before [[event.proj]]")
        return 1
    fend : int, mut = str_len(chunk)
    if p_off >= 0 && p_off < fend:
        fend = p_off
    if s_off >= 0 && s_off < fend:
        fend = s_off
    ev_text := str_sub(chunk, fe, fend - fe)
    if hit_scan_keys_ok(ev_text, "id name arith inputs outputs side_effect") != 0:
        return 1
    id := toml_get_int(ev_text, "id")
    if id <= 0:
        println("error: HIT table: event missing or invalid id")
        return 1
    // Reject duplicate ids.
    k : int, mut = 0
    loop:
        if k >= g_hit_event_count:
            break
        if hit_r32(g_hit_events, k * HIT_EVENT_REC + HIT_EV_OFF_ID) == id:
            print("error: HIT table: duplicate event id ")
            print_i(id)
            println("")
            return 1
        k = k + 1
    name := toml_get_str(ev_text, "name")
    if str_len(name) == 0:
        hit_err_ev(id)
        println("missing name")
        return 1
    inputs := toml_get_int(ev_text, "inputs")
    outputs := toml_get_int(ev_text, "outputs")
    se := toml_get_str(ev_text, "side_effect")
    side : int, mut = -1
    if str_eq(se, "pure") != 0:
        side = HIT_SIDE_PURE
    if str_eq(se, "effect") != 0:
        side = HIT_SIDE_EFFECT
    if side < 0:
        hit_err_ev(id)
        println("bad side_effect")
        return 1
    // Add the name to the name table; each entry stores a string pointer.
    hit_grow_names(g_hit_name_count + 1)
    name_ni : int, mut = g_hit_name_count
    g_hit_name_count = name_ni + 1
    store_str_ptr(g_hit_names, name_ni * 8, name)
    // Append the event record. Projection range fields are filled after parsing.
    hit_grow_events(g_hit_event_count + 1)
    slot := g_hit_event_count
    g_hit_event_count = slot + 1
    hit_zero_bytes(g_hit_events, slot * HIT_EVENT_REC, HIT_EVENT_REC)
    hit_w32(g_hit_events, slot * HIT_EVENT_REC + HIT_EV_OFF_ID, id)
    hit_w32(g_hit_events, slot * HIT_EVENT_REC + HIT_EV_OFF_NAME, name_ni)
    hit_w32(g_hit_events, slot * HIT_EVENT_REC + HIT_EV_OFF_INPUTS, inputs)
    hit_w32(g_hit_events, slot * HIT_EVENT_REC + HIT_EV_OFF_OUTPUTS, outputs)
    hit_w32(g_hit_events, slot * HIT_EVENT_REC + HIT_EV_OFF_SIDE, side)
    // Parse projections. Fields 32 and 36 record the range; fields 20, 24, and 28 mirror projection 0.
    first_proj : int, mut = g_hit_proj_count
    pcount : int, mut = 0
    hpos : int, mut = fend
    loop:
        ph := hit_find_tag(chunk, hpos, "[[event.proj]]")
        if ph < 0:
            break
        pcount = pcount + 1
        if hit_parse_proj_section(chunk, ph, id) != 0:
            return 1
        hpos = ph + 1
    if pcount == 0:
        hit_err_ev(id)
        println("missing [[event.proj]]")
        return 1
    hit_w32(g_hit_events, slot * HIT_EVENT_REC + HIT_EV_OFF_PROJ_OFF, first_proj)
    hit_w32(g_hit_events, slot * HIT_EVENT_REC + HIT_EV_OFF_PROJ_COUNT, pcount)
    // Mirror projection 0: ISA, step count, and first-step byte offset.
    p0 := first_proj * HIT_PROJ_REC
    hit_w32(g_hit_events, slot * HIT_EVENT_REC + HIT_EV_OFF_ISA,
        hit_r32(g_hit_projs, p0 + HIT_PJ_OFF_ISA))
    hit_w32(g_hit_events, slot * HIT_EVENT_REC + HIT_EV_OFF_STEP_COUNT,
        hit_r32(g_hit_projs, p0 + HIT_PJ_OFF_STEP_COUNT))
    hit_w32(g_hit_events, slot * HIT_EVENT_REC + HIT_EV_OFF_STEP_OFF,
        hit_r32(g_hit_projs, p0 + HIT_PJ_OFF_STEP_OFF))
    return 0

// ------------------------------------------------------------------
// [runtime.x86] runtime section. It is optional, but when present all eight keys
// are required.
// ------------------------------------------------------------------
// chunk starts at the [runtime.x86] line and ends before the next section.
// Returns 0 on success and 1 after printing an error.
fn hit_parse_runtime_chunk(chunk: string) -> int:
    fe := hit_line_after(chunk, 0)
    text := str_sub(chunk, fe, str_len(chunk) - fe)
    if hit_scan_keys_ok(text, "call_mechanism call_ret_addr call_stack_grow param_mode param_regs save_regs extern_entry extern_resolve") != 0:
        return 1
    // Require all eight keys.
    if hit_has_key(text, "call_mechanism") == 0:
        println("error: HIT table: runtime section missing call_mechanism")
        return 1
    if hit_has_key(text, "call_ret_addr") == 0:
        println("error: HIT table: runtime section missing call_ret_addr")
        return 1
    if hit_has_key(text, "call_stack_grow") == 0:
        println("error: HIT table: runtime section missing call_stack_grow")
        return 1
    if hit_has_key(text, "param_mode") == 0:
        println("error: HIT table: runtime section missing param_mode")
        return 1
    if hit_has_key(text, "param_regs") == 0:
        println("error: HIT table: runtime section missing param_regs")
        return 1
    if hit_has_key(text, "save_regs") == 0:
        println("error: HIT table: runtime section missing save_regs")
        return 1
    if hit_has_key(text, "extern_entry") == 0:
        println("error: HIT table: runtime section missing extern_entry")
        return 1
    if hit_has_key(text, "extern_resolve") == 0:
        println("error: HIT table: runtime section missing extern_resolve")
        return 1
    rt := alloc(32)
    // Check the enumeration values for the call mechanism.
    if str_eq(toml_get_str(text, "call_mechanism"), "stack") == 0:
        println("error: HIT table: bad call_mechanism")
        return 1
    hit_w32(rt, HIT_RT_CALL_MECHANISM * 4, 1)
    if str_eq(toml_get_str(text, "call_ret_addr"), "pushed") == 0:
        println("error: HIT table: bad call_ret_addr")
        return 1
    hit_w32(rt, HIT_RT_CALL_RET_ADDR * 4, 1)
    if str_eq(toml_get_str(text, "call_stack_grow"), "down") == 0:
        println("error: HIT table: bad call_stack_grow")
        return 1
    hit_w32(rt, HIT_RT_CALL_STACK_GROW * 4, 1)
    pm := toml_get_str(text, "param_mode")
    if str_eq(pm, "regs") == 0 && str_eq(pm, "stack") == 0:
        println("error: HIT table: bad param_mode")
        return 1
    if str_eq(pm, "regs") != 0:
        hit_w32(rt, HIT_RT_PARAM_MODE * 4, 1)
    if str_eq(pm, "stack") != 0:
        hit_w32(rt, HIT_RT_PARAM_MODE * 4, 2)
    if str_eq(toml_get_str(text, "extern_entry"), "call_rel32") == 0:
        println("error: HIT table: bad extern_entry")
        return 1
    hit_w32(rt, HIT_RT_EXTERN_ENTRY * 4, 1)
    if str_eq(toml_get_str(text, "extern_resolve"), "ext_rel") == 0:
        println("error: HIT table: bad extern_resolve")
        return 1
    hit_w32(rt, HIT_RT_EXTERN_RESOLVE * 4, 1)
    // Register masks: space-separated names become a bit set of register numbers.
    if hit_parse_reg_mask(toml_get_str(text, "param_regs"), rt, HIT_RT_PARAM_MASK * 4) != 0:
        return 1
    if hit_parse_reg_mask(toml_get_str(text, "save_regs"), rt, HIT_RT_SAVE_MASK * 4) != 0:
        return 1
    g_hit_runtime = rt
    g_hit_runtime_present = 1
    return 0

// Parse a space-separated register list into a bit mask at rt+pos. Returns 0 on success and 1 for an unknown name after printing it.
fn hit_parse_reg_mask(raw: string, rt: string, pos: int) -> int:
    rlen := str_len(raw)
    mask : int, mut = 0
    p : int, mut = 0
    loop:
        if p >= rlen:
            break
        loop:
            if p >= rlen:
                break
            if load8(raw, p) == 32:
                p = p + 1
            else:
                break
        if p >= rlen:
            break
        e : int, mut = p
        loop:
            if e >= rlen:
                break
            if load8(raw, e) == 32:
                break
            e = e + 1
        rn := hit_reg_code(str_sub(raw, p, e - p))
        if rn < 0:
            print("error: HIT table: runtime unknown register '")
            print(str_sub(raw, p, e - p))
            println("'")
            return 1
        mask = mask + hit_bit(rn)
        p = e
    hit_w32(rt, pos, mask)
    return 0

// ------------------------------------------------------------------
// Public interface
// ------------------------------------------------------------------

// Load a HIT table and fill g_hit_events, g_hit_projs, and g_hit_steps. Counters
// reset, so a repeated call replaces the previous table. [[event]] and
// [runtime.x86] sections may appear in any order, including runtime between
// events. Returns 0 on success and 1 after printing an error; the table is then
// unusable.
fn load_hit_table(path: string) -> int:
    content := read_file(path)
    if str_len(content) == 0:
        print("error: cannot open HIT table: ")
        println(path)
        return 1
    g_hit_event_count = 0
    g_hit_step_count = 0
    g_hit_proj_count = 0
    g_hit_name_count = 0
    g_hit_runtime_present = 0
    expected := toml_get_int(content, "events")  // [table] events; the final count check uses 0 when absent
    pos : int, mut = 0
    loop:
        ev := hit_find_tag(content, pos, "[[event]]")
        rt := hit_find_tag(content, pos, "[runtime.x86]")
        if ev < 0 && rt < 0:
            break
        if ev < 0 || (rt >= 0 && rt < ev):
            // [runtime.x86] 小节：到下一 [[event]] / 再一 runtime 头 / EOF 为止
            end : int, mut = str_len(content)
            e2 := hit_find_tag(content, rt + 1, "[[event]]")
            r2 := hit_find_tag(content, rt + 1, "[runtime.x86]")
            if e2 >= 0 && e2 < end:
                end = e2
            if r2 >= 0 && r2 < end:
                end = r2
            chunk := str_sub(content, rt, end - rt)
            if hit_parse_runtime_chunk(chunk) != 0:
                return 1
            pos = end
        else:
            end : int, mut = str_len(content)
            e2 := hit_find_tag(content, ev + 1, "[[event]]")
            r2 := hit_find_tag(content, ev + 1, "[runtime.x86]")
            if e2 >= 0 && e2 < end:
                end = e2
            if r2 >= 0 && r2 < end:
                end = r2
            chunk := str_sub(content, ev, end - ev)
            if hit_parse_event_chunk(chunk) != 0:
                return 1
            pos = end
    if g_hit_event_count == 0:
        println("error: HIT table: no [[event]] sections")
        return 1
    // This loader does not require every core event id to be present. Consumers
    // look up ids and expose a missing event naturally. It rejects an empty table
    // and a count that differs from [table] events.
    if g_hit_event_count != expected:
        print("error: HIT table: [table] events=")
        print_i(expected)
        print(" parsed=")
        print_i(g_hit_event_count)
        println(" mismatch")
        return 1
    return 0

// Whether table mode is active. A positive g_hit_event_count enables table-first emission.
fn hit_table_active() -> int:
    if g_hit_event_count > 0:
        return 1
    return 0

// Event id to event slot index. -1 means absent.
fn hit_event_lookup(id: int) -> int:
    i : int, mut = 0
    loop:
        if i >= g_hit_event_count:
            break
        if hit_r32(g_hit_events, i * HIT_EVENT_REC + HIT_EV_OFF_ID) == id:
            return i
        i = i + 1
    return -1

// Event name for diagnostics, read from g_hit_names.
fn hit_event_name(slot: int) -> string:
    if slot < 0 || slot >= g_hit_event_count:
        return ""
    ni := hit_r32(g_hit_events, slot * HIT_EVENT_REC + HIT_EV_OFF_NAME)
    if ni < 0 || ni >= g_hit_name_count:
        return ""
    return load_str_ptr(g_hit_names, ni * 8)

// Number of projections for an event. -1 means an invalid event slot.
fn hit_proj_count(event_slot: int) -> int:
    if event_slot < 0 || event_slot >= g_hit_event_count:
        return -1
    return hit_r32(g_hit_events, event_slot * HIT_EVENT_REC + HIT_EV_OFF_PROJ_COUNT)

// Step count for projection proj_i. -1 is out of range.
fn hit_proj_step_count(event_slot: int, proj_i: int) -> int:
    if event_slot < 0 || event_slot >= g_hit_event_count:
        return -1
    po := hit_r32(g_hit_events, event_slot * HIT_EVENT_REC + HIT_EV_OFF_PROJ_OFF)
    pc := hit_r32(g_hit_events, event_slot * HIT_EVENT_REC + HIT_EV_OFF_PROJ_COUNT)
    if proj_i < 0 || proj_i >= pc:
        return -1
    return hit_r32(g_hit_projs, (po + proj_i) * HIT_PROJ_REC + HIT_PJ_OFF_STEP_COUNT)

// Copy step step_i of projection proj_i into out as one 108-byte record. The field
// layout is the HIT_ST_OFF_* order above. The caller provides at least 108 bytes.
// Returns 0 on success and -1 for an invalid event slot, projection, or step.
fn hit_proj_step_get(event_slot: int, proj_i: int, step_i: int, out: string) -> int:
    if event_slot < 0 || event_slot >= g_hit_event_count:
        return -1
    po := hit_r32(g_hit_events, event_slot * HIT_EVENT_REC + HIT_EV_OFF_PROJ_OFF)
    pc := hit_r32(g_hit_events, event_slot * HIT_EVENT_REC + HIT_EV_OFF_PROJ_COUNT)
    if proj_i < 0 || proj_i >= pc:
        return -1
    ps := (po + proj_i) * HIT_PROJ_REC
    sc := hit_r32(g_hit_projs, ps + HIT_PJ_OFF_STEP_COUNT)
    if step_i < 0 || step_i >= sc:
        return -1
    off := hit_r32(g_hit_projs, ps + HIT_PJ_OFF_STEP_OFF)
    j : int, mut = 0
    loop:
        if j >= HIT_STEP_REC:
            break
        store8(out, j, load8(g_hit_steps, off + step_i * HIT_STEP_REC + j))
        j = j + 1
    return 0

// Copy a step from projection 0 into out. The caller provides at least
// HIT_STEP_REC bytes. Existing consumers read only the first 20 bytes, whose
// layout is unchanged. Event fields 24 and 28 mirror projection 0.
// Returns 0 on success and -1 for an invalid event slot or step.
fn hit_proj_step(event_slot: int, step_i: int, out: string) -> int:
    if event_slot < 0 || event_slot >= g_hit_event_count:
        return -1
    sc := hit_r32(g_hit_events, event_slot * HIT_EVENT_REC + HIT_EV_OFF_STEP_COUNT)
    if step_i < 0 || step_i >= sc:
        return -1
    off := hit_r32(g_hit_events, event_slot * HIT_EVENT_REC + HIT_EV_OFF_STEP_OFF)
    j : int, mut = 0
    loop:
        if j >= HIT_STEP_REC:
            break
        store8(out, j, load8(g_hit_steps, off + step_i * HIT_STEP_REC + j))
        j = j + 1
    return 0

// Query a runtime entry by key. The keys are call_mechanism, call_ret_addr,
// call_stack_grow, param_mode, param_regs, save_regs, extern_entry, and
// extern_resolve. Write a 4-byte code or bit mask to out. Returns 0 when written
// and -1 when there is no runtime section or the key is unknown.
fn hit_runtime_get(key: string, out: string) -> int:
    if g_hit_runtime_present == 0:
        return -1
    slot : int, mut = -1
    if str_eq(key, "call_mechanism") != 0:
        slot = HIT_RT_CALL_MECHANISM
    if str_eq(key, "call_ret_addr") != 0:
        slot = HIT_RT_CALL_RET_ADDR
    if str_eq(key, "call_stack_grow") != 0:
        slot = HIT_RT_CALL_STACK_GROW
    if str_eq(key, "param_mode") != 0:
        slot = HIT_RT_PARAM_MODE
    if str_eq(key, "param_regs") != 0:
        slot = HIT_RT_PARAM_MASK
    if str_eq(key, "save_regs") != 0:
        slot = HIT_RT_SAVE_MASK
    if str_eq(key, "extern_entry") != 0:
        slot = HIT_RT_EXTERN_ENTRY
    if str_eq(key, "extern_resolve") != 0:
        slot = HIT_RT_EXTERN_RESOLVE
    if slot < 0:
        return -1
    hit_w32(out, 0, hit_r32(g_hit_runtime, slot * 4))
    return 0

// --dump-table readback, called by corearch after loading. It only reads table
// state. One line per event reports the projection record readback through
// hit_proj_count and hit_proj_step_count. One line per step reports the first
// opcode byte from a full 108-byte copy. Runtime masks are read back too.
fn hit_dump_table_state():
    // Per event, report each projection's step count.
    ei : int, mut = 0
    loop:
        if ei >= g_hit_event_count:
            break
        print("hit proj: ev=")
        print_i(hit_r32(g_hit_events, ei * HIT_EVENT_REC + HIT_EV_OFF_ID))
        pc := hit_proj_count(ei)
        print(" projs=")
        print_i(pc)
        pi : int, mut = 0
        loop:
            if pi >= pc:
                break
            print(" p")
            print_i(pi)
            print("=")
            print_i(hit_proj_step_count(ei, pi))
            pi = pi + 1
        println("")
        ei = ei + 1
    // Per step, report the first opcode byte from the current schema fields.
    st := alloc(HIT_STEP_REC)
    ej : int, mut = 0
    loop:
        if ej >= g_hit_event_count:
            break
        idj := hit_r32(g_hit_events, ej * HIT_EVENT_REC + HIT_EV_OFF_ID)
        pj : int, mut = 0
        loop:
            if pj >= hit_proj_count(ej):
                break
            sj : int, mut = 0
            loop:
                if sj >= hit_proj_step_count(ej, pj):
                    break
                if hit_proj_step_get(ej, pj, sj, st) == 0:
                    print("hit step: ev=")
                    print_i(idj)
                    print(" p=")
                    print_i(pj)
                    print(" s=")
                    print_i(sj)
                    print(" opb=")
                    print_i(hit_r32(st, HIT_ST_OFF_OPB0))
                    println("")
                sj = sj + 1
            pj = pj + 1
        ej = ej + 1
    // Read back runtime masks as decimal values. Param registers are rdi, rsi,
    // rdx, rcx, r8, and r9; saved registers are rbx and r12 through r15.
    if hit_runtime_get("param_regs", st) == 0:
        print("hit rt: param_regs=")
        print_i(hit_r32(st, 0))
        println("")
    if hit_runtime_get("save_regs", st) == 0:
        print("hit rt: save_regs=")
        print_i(hit_r32(st, 0))
        println("")
