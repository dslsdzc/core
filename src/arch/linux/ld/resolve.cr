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

        ist := g_ir_func_instr_start[fi];
        ic := g_ir_func_instr_count[fi];

        // ── Pass 1: measure instruction sizes, record label positions ──
        g_label_count = 0;
        off : ., mut = 0;
        ii : ., mut = 0;
        loop {
            if ii >= ic { break; }
            inst_idx := ist + ii;
            inst := g_ir_instrs[inst_idx];
            if inst.opcode == IR_LABEL {
                ln := inst.src1;
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
            inst2 := g_ir_instrs[inst_idx];
            if inst2.opcode == IR_BRANCH {
                true_off := g_label_poses[inst2.src2];
                false_off := g_label_poses[inst2.src3];
                g_ir_instrs[inst_idx] = IRInstr { opcode = IR_BRANCH, dest = inst2.dest, src1 = inst2.src1, src2 = true_off, src3 = false_off, type_kind = IR_RESOLVED };
            }
            if inst2.opcode == IR_JUMP {
                tgt_off := g_label_poses[inst2.src1];
                g_ir_instrs[inst_idx] = IRInstr { opcode = IR_JUMP, dest = inst2.dest, src1 = tgt_off, src2 = inst2.src2, src3 = inst2.src3, type_kind = IR_RESOLVED };
            }
            ii = ii + 1;
        }

        // ── Pass 3: turn LABEL into NOP (emit skips NOP) ──
        ii = 0;
        loop {
            if ii >= ic { break; }
            if g_ir_instrs[ist + ii].opcode == IR_LABEL {
                g_ir_instrs[ist + ii].opcode = IR_NOP;
            }
            ii = ii + 1;
        }

        fi = fi + 1;
    }
}
