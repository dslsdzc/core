// === resolve.cr ===
// Generic label-to-offset resolution pass.
//
// Uses emit_instr() (the real encoder) for sizing — no duplicate size logic.
// A reusable scratch buffer avoids per-instruction allocation.
// Records label positions, then patches IR_JUMP with resolved byte offsets
// directly into src1.
//
// After resolution:
//   IR_JUMP:   src1 = offset, type_kind = IR_RESOLVED
//   IR_LABEL:  opcode becomes IR_NOP
//
// The backend's emit_instr() can then write jumps using the pre-computed
// offsets, no label table lookup needed.

fn res_labels():
    print("    res_labels: ")
    print(int_str(g_ir_func_count))
    print(" funcs, ")
    print(int_str(g_ir_instr_count))
    println(" instrs")
    fi : ., mut = 0
    loop:
        if fi >= g_ir_func_count:
            break

        ist := cell_load(g_ir_func_instr_start, fi * 8)
        ic := cell_load(g_ir_func_instr_count, fi * 8)
        vs_r := cell_load(g_ir_func_var_start, fi * 8)
        vc_r := cell_load(g_ir_func_var_count, fi * 8)
        pc_r := cell_load(g_ir_func_param_count, fi * 8)

        // Init slot state for accurate sizing
        g2_init()
        g_current_func_var_start = vs_r
        vi4 : ., mut = 0
        loop:
            if vi4 >= vc_r:
                break
            g2_slot(vs_r + vi4)
            vi4 = vi4 + 1
        pi4 : ., mut = 0
        loop:
            if pi4 >= pc_r || pi4 >= 6:
                break
            g2_slot(vs_r + pi4)
            pi4 = pi4 + 1

        // ── Pass 1: measure instruction sizes via emit_instr (real encoder) ──
        g_label_count = 0
        off : ., mut = 0
        ii : ., mut = 0
        // The encoder writes at pos=0 while measuring, and backward-label
        // patches write into the same scratch. A sparse MATCH emits a fixed
        // 30-byte block per value row, so size the scratch from the largest
        // MATCH range in this function. The 512-byte floor covers every other
        // single instruction.
        scratch_sz : ., mut = 512
        ii = 0
        loop:
            if ii >= ic:
                break
            if iri_op(ist + ii) == IR_MATCH:
                cand := iri_s3(ist + ii) * 32 + 64
                if cand > scratch_sz:
                    scratch_sz = cand
            ii = ii + 1
        scratch := alloc(scratch_sz)
        ii = 0
        loop:
            if ii >= ic:
                break
            inst_idx := ist + ii
            if iri_op(inst_idx) == IR_LABEL:
                ln := iri_s1(inst_idx)
                if ln >= 0:
                    grow_label_poses(ln + 1)
                    cell_store(g_label_poses, ln * 8, off)
                    if ln + 1 > g_label_count:
                        g_label_count = ln + 1
            else:
                off = off + emit_instr(inst_idx, scratch, 0)
            ii = ii + 1
        // Save per-function code size for Phase 2 reuse
        grow_func_code_sz(fi + 1)
        cell_store(g_x86_func_code_sz, fi * 8, off)

        // ── Pass 2: patch JUMP with resolved offsets ──
        ii = 0
        loop:
            if ii >= ic:
                break
            inst_idx := ist + ii
            if iri_op(inst_idx) == IR_JUMP:
                tgt_off := cell_load(g_label_poses, iri_s1(inst_idx) * 8)
                iri_set_op(inst_idx, IR_JUMP)
                iri_set_s1(inst_idx, tgt_off)
                iri_set_tk(inst_idx, IR_RESOLVED)
            ii = ii + 1

        // ── Pass 3: turn LABEL into NOP (emit skips NOP) ──
        ii = 0
        loop:
            if ii >= ic:
                break
            if iri_op(ist + ii) == IR_LABEL:
                iri_set_op(ist + ii, IR_NOP)
            ii = ii + 1

        fi = fi + 1
