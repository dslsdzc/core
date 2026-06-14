// === resolve.cr ===
// Generic label→offset resolution pass.
//
// Uses arch_instr_size() provided by the backend to lay out instruction
// bytes, records label positions, then patches IR_BRANCH and IR_JUMP with
// resolved byte offsets directly into src2/src3/src1.
//
// After resolution:
//   IR_BRANCH: src2=true_offset, src3=false_offset, type_kind=IR_RESOLVED
//   IR_JUMP:   src1=offset, type_kind=IR_RESOLVED
//   IR_LABEL:  opcode → IR_NOP
//
// The backend's emit_instr() can then write branch instructions using
// the pre-computed offsets, no label table lookup needed.

fn resolve_labels() {
    fi : ., mut = 0;
    loop {
        if fi >= g_ir_func_count { break; }

        ist := r64(g_ir_func_instr_start, fi * 8);
        ic := r64(g_ir_func_instr_count, fi * 8);

        // ── Pass 1: measure instruction sizes, record label positions ──
        g_label_count = 0;
        off : ., mut = 0;
        ii : ., mut = 0;
        loop {
            if ii >= ic { break; }
            inst_idx := ist + ii;
            if iri_op(inst_idx) == IR_LABEL {
                ln := iri_s1(inst_idx);
                if ln >= 0 && ln < 32 {
                    g_label_poses[ln] = off;
                    if ln + 1 > g_label_count { g_label_count = ln + 1; }
                }
            } else {
                off = off + arch_instr_size(inst_idx);
            }
            ii = ii + 1;
        }

        // ── Pass 2: patch BRANCH/JUMP with resolved offsets ──
        ii = 0;
        loop {
            if ii >= ic { break; }
            inst_idx := ist + ii;
            if iri_op(inst_idx) == IR_BRANCH {
                true_off := g_label_poses[iri_s2(inst_idx)];
                false_off := g_label_poses[iri_s3(inst_idx)];
                iri_set_op(inst_idx, IR_BRANCH); iri_set_s2(inst_idx, true_off); iri_set_s3(inst_idx, false_off); iri_set_tk(inst_idx, IR_RESOLVED);
            }
            if iri_op(inst_idx) == IR_JUMP {
                tgt_off := g_label_poses[iri_s1(inst_idx)];
                iri_set_op(inst_idx, IR_JUMP); iri_set_s1(inst_idx, tgt_off); iri_set_tk(inst_idx, IR_RESOLVED);
            }
            ii = ii + 1;
        }

        // ── Pass 3: turn LABEL into NOP (emit skips NOP) ──
        ii = 0;
        loop {
            if ii >= ic { break; }
            if iri_op(ist + ii) == IR_LABEL {
                iri_set_op(ist + ii, IR_NOP);
            }
            ii = ii + 1;
        }

        fi = fi + 1;
    }
}
