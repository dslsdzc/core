# 10K 以上 Markdown 文件清单与处理分类

统计时间：2026-10-23。范围：仓库内大于 10 KiB 的 Markdown 文件，不含 `.git`、`.jj`、`node_modules`、`vendor` 和 `pkg`。

## 分类规则

- 现行文档：开发者文档、维护者设计、学术参考、验证器、IR schema、项目入口和基线重建说明。按 `docs/doc-style.md` 重写。
- 设计规格：`docs/superpowers/specs/`。正文保留设计；决定历史、审计和证据移到 `docs/superpowers/implementation/`。
- 计划：`docs/superpowers/plans/`。保留执行步骤和验收条件，整理标题、状态和链接。
- 实施记录：`docs/superpowers/implementation/`。保留结果、数据和提交哈希，整理标题和链接。
- 执行日志：`docs/archive/sdd/`。原始会话记录，不重写，只建索引。
- 生成伪代码：`docs/pseudocode/`。由源码和测试生成，不重写。
- 档案：`docs/archive/`。历史材料，保留原样。

## 数量

| 类别 | 文件数 |
|---|---:|
| 现行文档 | 23 |
| 设计规格 | 25 |
| 计划 | 61 |
| 实施记录 | 32 |
| 生成伪代码 | 52 |
| 档案 | 99 |
| 合计 | 291 |

## 现行文档

| 大小 (KiB) | 文件 | 处理 |
|---:|---|---|
| 557 | `TODO.md` | 任务台账，保留格式 |
| 167 | `docs/maintainer/design/ccr-v8-open-relational-lattice.md` | 按规范重写 |
| 152 | `docs/maintainer/design/execution-mapping-design.md` | 按规范重写 |
| 96 | `docs/maintainer/design/coi-optimization-knowledge-sidecar.md` | 按规范重写 |
| 83 | `docs/superpowers/implementation/2026-09-23-comptime-feasibility.md` | 已移入实施记录（一次性评估） |
| 67 | `docs/maintainer/design/materialization-space.md` | 按规范重写 |
| 59 | `docs/superpowers/implementation/2026-09-24-v4-layout-t0.md` | 已移入实施记录（T0 产物） |
| 46 | `docs/verifier/kernel-spec.md` | 按规范重写 |
| 45 | `docs/maintainer/design/ir-op-semantics.md` | 按规范重写 |
| 28 | `CLAUDE.md` | 代理说明，保留 |
| 27 | `docs/maintainer/design/spec-design.md` | 按规范重写 |
| 23 | `docs/developer/errors.md` | 按规范重写 |
| 21 | `CHANGELOG.md` | 变更台账，保留格式 |
| 20 | `docs/project-book.md` | 按规范重写 |
| 18 | `docs/ir-schema/coreir-schema.md` | 按规范重写 |
| 18 | `docs/developer/syntax.md` | 按规范重写 |
| 16 | `tools/baseline/REBUILD.md` | 按规范重写 |
| 11 | `docs/maintainer/design/execution-model.md` | 按规范重写 |
| 11 | `docs/academic/cache-semantics.md` | 按规范重写 |
| 11 | `docs/developer/tutorial.md` | 按规范重写 |
| 11 | `docs/maintainer/design/pointer-model.md` | 按规范重写 |
| 10 | `docs/maintainer/design/regalloc-cache-mapping.md` | 按规范重写 |

## 设计规格

| 大小 (KiB) | 文件 | 处理 |
|---:|---|---|
| 72 | `docs/superpowers/specs/2026-09-11-semantic-safety-obligations-design.md` | 重写正文，证据另放 |
| 65 | `docs/superpowers/specs/2026-09-11-explain-predict-incremental-design.md` | 重写正文，证据另放 |
| 58 | `docs/superpowers/specs/2026-09-11-merge-semantics-design.md` | 重写正文，证据另放 |
| 52 | `docs/superpowers/specs/2026-09-10-type-interface-unification-design.md` | 重写正文，证据另放 |
| 49 | `docs/superpowers/specs/2026-09-11-policy-injection-design.md` | 重写正文，证据另放 |
| 37 | `docs/superpowers/specs/2026-09-11-policy-authorization-design.md` | 重写正文，证据另放 |
| 36 | `docs/superpowers/specs/2026-09-11-performance-without-commitment-design.md` | 重写正文，证据另放 |
| 22 | `docs/superpowers/specs/2026-09-09-lattice-ir-v7-format.md` | 重写正文，证据另放 |
| 22 | `docs/superpowers/specs/2026-09-10-corearch-kernel-completion-design.md` | 重写正文，证据另放 |
| 20 | `docs/superpowers/specs/2026-09-11-policy-information-flow-design.md` | 重写正文，证据另放 |
| 19 | `docs/superpowers/specs/2026-09-09-lattice-encoding-boundary-design.md` | 重写正文，证据另放 |
| 19 | `docs/superpowers/specs/2026-09-11-semantic-safety-roadmap.md` | 重写正文，证据另放 |
| 18 | `docs/superpowers/specs/2026-09-09-corearch-rewrite-design.md` | 重写正文，证据另放 |
| 17 | `docs/superpowers/specs/2026-09-10-x86-instance-design.md` | 重写正文，证据另放 |
| 16 | `docs/archive/2026-09-05-lattice-ir-v6-format.md` | 已移入档案（被 v7 取代） |
| 14 | `docs/superpowers/specs/2026-08-30-type-system-direction-design.md` | 重写正文，证据另放 |
| 13 | `docs/superpowers/specs/2026-07-28-arena-model-design.md` | 重写正文，证据另放 |
| 13 | `docs/superpowers/specs/2026-09-07-hit-m2-design.md` | 重写正文，证据另放 |
| 13 | `docs/superpowers/specs/2026-09-09-lattice-ir-v7-carrier-design.md` | 重写正文，证据另放 |
| 13 | `docs/superpowers/specs/2026-09-06-int-unbounded-semantics.md` | 重写正文，证据另放 |
| 12 | `docs/superpowers/specs/2026-08-09-repo-governance-design.md` | 重写正文，证据另放 |
| 11 | `docs/archive/2026-07-28-bare-ptr-model-design.md` | 已移入档案（早期实现设计） |
| 11 | `docs/superpowers/specs/2026-09-04-message-copy-elision-design.md` | 重写正文，证据另放 |
| 10 | `docs/archive/2026-08-13-graph-anchored-regions-design.md` | 已移入档案（历史设计） |
| 10 | `docs/superpowers/specs/2026-08-08-lsp-design.md` | 重写正文，证据另放 |

## 计划

| 大小 (KiB) | 文件 | 处理 |
|---:|---|---|
| 105 | `docs/superpowers/plans/2026-09-11-r2-p3-capabilities.md` | 整理标题、状态与链接 |
| 76 | `docs/superpowers/plans/2026-09-24-v4-syntax-migration.md` | 整理标题、状态与链接 |
| 71 | `docs/superpowers/plans/2026-09-12-r2-p4-carrier.md` | 整理标题、状态与链接 |
| 70 | `docs/superpowers/plans/2026-09-23-compile-cost-and-recheck.md` | 整理标题、状态与链接 |
| 65 | `docs/superpowers/plans/2026-09-13-r2-p5-cleanup.md` | 整理标题、状态与链接 |
| 61 | `docs/superpowers/plans/2026-09-14-r2-p6-tail.md` | 整理标题、状态与链接 |
| 58 | `docs/superpowers/plans/2026-09-15-capacity-batch.md` | 整理标题、状态与链接 |
| 56 | `docs/superpowers/plans/2026-09-17-cir-cache-bloat.md` | 整理标题、状态与链接 |
| 55 | `docs/superpowers/plans/2026-09-11-r2-p2b-iface-ops.md` | 整理标题、状态与链接 |
| 54 | `docs/superpowers/plans/2026-09-15-fail-closed-diagnostics.md` | 整理标题、状态与链接 |
| 52 | `docs/superpowers/plans/2026-09-16-apx-conversion-fix.md` | 整理标题、状态与链接 |
| 51 | `docs/superpowers/plans/2026-09-07-hit-m2.md` | 整理标题、状态与链接 |
| 49 | `docs/superpowers/plans/2026-09-19-blade4-argface-harderror.md` | 整理标题、状态与链接 |
| 46 | `docs/superpowers/plans/2026-09-16-global-operand-seams.md` | 整理标题、状态与链接 |
| 45 | `docs/superpowers/plans/2026-09-17-spec-grammar.md` | 整理标题、状态与链接 |
| 45 | `docs/superpowers/plans/2026-09-10-r2-p0-type-engine.md` | 整理标题、状态与链接 |
| 44 | `docs/superpowers/plans/2026-09-20-safety-verification-plan.md` | 整理标题、状态与链接 |
| 44 | `docs/superpowers/plans/2026-09-17-silence-closure.md` | 整理标题、状态与链接 |
| 40 | `docs/superpowers/plans/2026-09-10-language-surface-narrowing-r1.md` | 整理标题、状态与链接 |
| 40 | `docs/superpowers/plans/2026-09-17-opt-dex.md` | 整理标题、状态与链接 |
| 38 | `docs/superpowers/plans/2026-09-23-coi-implementation.md` | 整理标题、状态与链接 |
| 38 | `docs/superpowers/plans/2026-09-18-generic-param-erasure.md` | 整理标题、状态与链接 |
| 34 | `docs/superpowers/plans/2026-09-16-opt-rep-follows-storage.md` | 整理标题、状态与链接 |
| 33 | `docs/superpowers/plans/2026-08-08-region-cfg.md` | 整理标题、状态与链接 |
| 33 | `docs/superpowers/plans/2026-08-08-pseudocode-tdd.md` | 整理标题、状态与链接 |
| 32 | `docs/superpowers/plans/2026-07-28-bare-ptr-model.md` | 整理标题、状态与链接 |
| 28 | `docs/superpowers/plans/2026-07-28-arena-model.md` | 整理标题、状态与链接 |
| 28 | `docs/superpowers/plans/2026-09-10-corearch-kernel-completion.md` | 整理标题、状态与链接 |
| 28 | `docs/superpowers/plans/2026-08-15-mctt-core-kernel.md` | 整理标题、状态与链接 |
| 28 | `docs/superpowers/plans/2026-09-16-agg-read-type.md` | 整理标题、状态与链接 |
| 26 | `docs/superpowers/plans/2026-09-09-lattice-ir-v7.md` | 整理标题、状态与链接 |
| 26 | `docs/superpowers/plans/2026-08-16-corelsp.md` | 整理标题、状态与链接 |
| 24 | `docs/superpowers/plans/2026-09-16-criteria-carrier.md` | 整理标题、状态与链接 |
| 24 | `docs/superpowers/plans/2026-09-17-todo-id-migration.md` | 整理标题、状态与链接 |
| 24 | `docs/superpowers/plans/2026-09-10-r2-p1-shadow-parity.md` | 整理标题、状态与链接 |
| 23 | `docs/superpowers/plans/2026-09-16-arg-inference-fix.md` | 整理标题、状态与链接 |
| 23 | `docs/superpowers/plans/2026-09-06-core-maintainer-docs-reorg.md` | 整理标题、状态与链接 |
| 23 | `docs/superpowers/plans/2026-09-15-warm-cache-diagnostics.md` | 整理标题、状态与链接 |
| 22 | `docs/superpowers/plans/2026-09-18-b8-e1-t0.md` | 整理标题、状态与链接 |
| 22 | `docs/superpowers/plans/2026-09-05-lattice-ir-v6.md` | 整理标题、状态与链接 |
| 22 | `docs/superpowers/plans/2026-09-20-mapping-layer-separation.md` | 整理标题、状态与链接 |
| 21 | `docs/superpowers/plans/2026-09-04-compile-time-linearity.md` | 整理标题、状态与链接 |
| 21 | `docs/superpowers/plans/2026-09-16-verification-slice.md` | 整理标题、状态与链接 |
| 20 | `docs/superpowers/plans/2026-09-05-hit-minimal-core-m1.md` | 整理标题、状态与链接 |
| 20 | `docs/superpowers/plans/2026-08-09-repo-governance.md` | 整理标题、状态与链接 |
| 19 | `docs/superpowers/plans/2026-09-17-home-repro.md` | 整理标题、状态与链接 |
| 18 | `docs/superpowers/plans/2026-07-29-incremental-cache.md` | 整理标题、状态与链接 |
| 17 | `docs/superpowers/plans/2026-08-16-numeric-types.md` | 整理标题、状态与链接 |
| 17 | `docs/superpowers/plans/2026-08-15-cache-semantics.md` | 整理标题、状态与链接 |
| 17 | `docs/superpowers/plans/2026-09-18-view-builtins-2a.md` | 整理标题、状态与链接 |
| 16 | `docs/superpowers/plans/2026-09-01-language-syntax-rewrite.md` | 整理标题、状态与链接 |
| 15 | `docs/superpowers/plans/2026-07-28-at-intrinsics.md` | 整理标题、状态与链接 |
| 15 | `docs/superpowers/plans/2026-09-10-corearch-kernel-extraction.md` | 整理标题、状态与链接 |
| 15 | `docs/superpowers/plans/2026-09-06-int-multiword-m1.md` | 整理标题、状态与链接 |
| 14 | `docs/superpowers/plans/2026-09-10-r2-p2-replace.md` | 整理标题、状态与链接 |
| 14 | `docs/superpowers/plans/2026-09-18-cir-cache-str-domain.md` | 整理标题、状态与链接 |
| 13 | `docs/superpowers/plans/2026-09-07-regalloc-backend.md` | 整理标题、状态与链接 |
| 12 | `docs/superpowers/plans/2026-09-10-x86-instance-wave1.md` | 整理标题、状态与链接 |
| 11 | `docs/superpowers/plans/2026-07-30-concurrency.md` | 整理标题、状态与链接 |
| 11 | `docs/superpowers/plans/2026-07-30-dynamic-typing.md` | 整理标题、状态与链接 |
| 10 | `docs/superpowers/plans/2026-07-29-hotpatch.md` | 整理标题、状态与链接 |

## 实施记录

| 大小 (KiB) | 文件 | 处理 |
|---:|---|---|
| 78 | `docs/superpowers/implementation/2026-09-23-fn-value-lambda-evidence.md` | 整理标题、结果与链接 |
| 72 | `docs/superpowers/implementation/2026-09-17-concurrency-model-evidence.md` | 整理标题、结果与链接 |
| 52 | `docs/superpowers/implementation/2026-09-13-r2-p5-cleanup.md` | 整理标题、结果与链接 |
| 47 | `docs/superpowers/implementation/2026-09-11-policy-information-flow-evidence.md` | 整理标题、结果与链接 |
| 46 | `docs/superpowers/implementation/2026-09-10-type-shadow-findings.md` | 整理标题、结果与链接 |
| 40 | `docs/superpowers/implementation/2026-09-14-r2-p6-tail.md` | 整理标题、结果与链接 |
| 37 | `docs/superpowers/implementation/2026-09-17-spec-grammar.md` | 整理标题、结果与链接 |
| 32 | `docs/superpowers/implementation/2026-09-11-policy-state-version-toctou-evidence.md` | 整理标题、结果与链接 |
| 30 | `docs/superpowers/implementation/2026-09-11-policy-resource-confinement-evidence.md` | 整理标题、结果与链接 |
| 28 | `docs/superpowers/implementation/2026-09-16-criteria-strength-audit.md` | 整理标题、结果与链接 |
| 27 | `docs/superpowers/implementation/2026-09-18-stale-criteria-scan-evidence.md` | 整理标题、结果与链接 |
| 27 | `docs/superpowers/implementation/2026-09-17-opt-dex-batch-report.md` | 整理标题、结果与链接 |
| 25 | `docs/superpowers/implementation/2026-09-16-agg-read-type.md` | 整理标题、结果与链接 |
| 23 | `docs/superpowers/implementation/2026-09-16-apx-conversion-fix.md` | 整理标题、结果与链接 |
| 22 | `docs/superpowers/implementation/2026-09-17-cir-cache-bloat.md` | 整理标题、结果与链接 |
| 21 | `docs/superpowers/implementation/2026-09-16-preexisting-bug-ledger.md` | 整理标题、结果与链接 |
| 21 | `docs/superpowers/implementation/2026-09-12-r2-p4-carrier.md` | 整理标题、结果与链接 |
| 21 | `docs/superpowers/implementation/2026-09-16-apx-conversion-audit.md` | 整理标题、结果与链接 |
| 18 | `docs/superpowers/implementation/2026-09-16-global-operand-seams.md` | 整理标题、结果与链接 |
| 17 | `docs/superpowers/implementation/2026-09-15-fail-closed-diagnostics.md` | 整理标题、结果与链接 |
| 17 | `docs/superpowers/implementation/2026-09-16-criteria-carrier.md` | 整理标题、结果与链接 |
| 16 | `docs/superpowers/implementation/2026-09-16-arg-inference-batch-report.md` | 整理标题、结果与链接 |
| 16 | `docs/superpowers/implementation/2026-09-16-arg-inference-fix.md` | 整理标题、结果与链接 |
| 15 | `docs/superpowers/implementation/2026-09-16-opt-rep-follows-storage.md` | 整理标题、结果与链接 |
| 14 | `docs/superpowers/implementation/2026-09-15-capacity-batch.md` | 整理标题、结果与链接 |
| 14 | `docs/superpowers/implementation/2026-09-19-builtin-table-evidence.md` | 整理标题、结果与链接 |
| 13 | `docs/superpowers/implementation/2026-09-17-opt-dex.md` | 整理标题、结果与链接 |
| 13 | `docs/superpowers/implementation/2026-09-16-agg-read-type-batch-report.md` | 整理标题、结果与链接 |
| 13 | `docs/superpowers/implementation/2026-09-16-doc-reality-audit.md` | 整理标题、结果与链接 |
| 13 | `docs/superpowers/implementation/2026-09-18-interp-expansion.md` | 整理标题、结果与链接 |
| 10 | `docs/superpowers/implementation/2026-09-17-silence-closure-t0-report.md` | 整理标题、结果与链接 |
| 10 | `docs/superpowers/implementation/2026-09-15-warm-cache-diagnostics.md` | 整理标题、结果与链接 |

## 执行日志

| 大小 (KiB) | 文件 | 处理 |
|---:|---|---|
| 187 | `docs/superpowers/implementation/2026-09-11-sdd-progress.md` | 保留原样，建索引 |
| 39 | `docs/archive/sdd/r2p2-task-3-report.md` | 保留原样，建索引 |
| 39 | `docs/superpowers/implementation/2026-09-11-sdd-safety-review-a.md` | 保留原样，建索引 |
| 36 | `docs/superpowers/implementation/2026-09-11-sdd-decisions-sheet.md` | 保留原样，建索引 |
| 33 | `docs/archive/sdd/p5-task0-report.md` | 保留原样，建索引 |
| 32 | `docs/superpowers/implementation/2026-09-11-sdd-safety-review-b.md` | 保留原样，建索引 |
| 30 | `docs/archive/sdd/p3b-task6-report.md` | 保留原样，建索引 |
| 29 | `docs/archive/sdd/p3-task5-report.md` | 保留原样，建索引 |
| 28 | `docs/archive/sdd/p3-task4-report.md` | 保留原样，建索引 |
| 27 | `docs/archive/sdd/p4-task2-report.md` | 保留原样，建索引 |
| 26 | `docs/archive/sdd/p5-task2-report.md` | 保留原样，建索引 |
| 26 | `docs/archive/sdd/p4-task3-report.md` | 保留原样，建索引 |
| 25 | `docs/archive/sdd/p6-task0-report.md` | 保留原样，建索引 |
| 25 | `docs/archive/sdd/p3b-task0-report.md` | 保留原样，建索引 |
| 25 | `docs/archive/sdd/p5-task3-report.md` | 保留原样，建索引 |
| 25 | `docs/archive/sdd/p4-task7-report.md` | 保留原样，建索引 |
| 24 | `docs/archive/sdd/p2b-task5-report.md` | 保留原样，建索引 |
| 24 | `docs/archive/sdd/p3b-task2-report.md` | 保留原样，建索引 |
| 23 | `docs/archive/sdd/psd-audit-g9.md` | 保留原样，建索引 |
| 23 | `docs/archive/sdd/p3-task7-report.md` | 保留原样，建索引 |
| 23 | `docs/archive/sdd/p2b-task4-report.md` | 保留原样，建索引 |
| 22 | `docs/archive/sdd/cap-task1-report.md` | 保留原样，建索引 |
| 22 | `docs/archive/sdd/purity-task-1-report.md` | 保留原样，建索引 |
| 22 | `docs/archive/sdd/p2b-task6-report.md` | 保留原样，建索引 |
| 21 | `docs/archive/sdd/p3-task3-report.md` | 保留原样，建索引 |
| 21 | `docs/archive/sdd/p3-task1-report.md` | 保留原样，建索引 |
| 21 | `docs/archive/sdd/p3-task0-report.md` | 保留原样，建索引 |
| 20 | `docs/archive/sdd/r2p1-task-4-report.md` | 保留原样，建索引 |
| 20 | `docs/archive/sdd/r2p1-task-3-report.md` | 保留原样，建索引 |
| 20 | `docs/archive/sdd/cag-report.md` | 保留原样，建索引 |
| 20 | `docs/archive/sdd/r2p0-task-1-report.md` | 保留原样，建索引 |
| 20 | `docs/archive/sdd/r2p2-task-4-report.md` | 保留原样，建索引 |
| 20 | `docs/archive/sdd/kc-task-0-report.md` | 保留原样，建索引 |
| 20 | `docs/archive/sdd/p3b-task7-report.md` | 保留原样，建索引 |
| 19 | `docs/archive/sdd/p4-task4-report.md` | 保留原样，建索引 |
| 19 | `docs/archive/sdd/p5-task1-report.md` | 保留原样，建索引 |
| 19 | `docs/archive/sdd/p5-task5-report.md` | 保留原样，建索引 |
| 18 | `docs/archive/sdd/r2p2-task-2-report.md` | 保留原样，建索引 |
| 18 | `docs/archive/sdd/p2b-task7-report.md` | 保留原样，建索引 |
| 18 | `docs/archive/sdd/p5-task3b-report.md` | 保留原样，建索引 |
| 18 | `docs/archive/sdd/p4-task6-report.md` | 保留原样，建索引 |
| 17 | `docs/archive/sdd/p4-task1-report.md` | 保留原样，建索引 |
| 17 | `docs/archive/sdd/numeric-task-4-report.md` | 保留原样，建索引 |
| 17 | `docs/archive/sdd/r2p1-task-2-report.md` | 保留原样，建索引 |
| 16 | `docs/archive/sdd/cag-review-full.md` | 保留原样，建索引 |
| 16 | `docs/archive/sdd/p6-task2-report.md` | 保留原样，建索引 |
| 16 | `docs/archive/sdd/psd-audit-g1.md` | 保留原样，建索引 |
| 16 | `docs/archive/sdd/purity-task-4-report.md` | 保留原样，建索引 |
| 16 | `docs/archive/sdd/psd-audit-g6.md` | 保留原样，建索引 |
| 16 | `docs/archive/sdd/mw-m1-task-4-report.md` | 保留原样，建索引 |
| 16 | `docs/archive/sdd/p4-task0-report.md` | 保留原样，建索引 |
| 16 | `docs/archive/sdd/p4-task5-report.md` | 保留原样，建索引 |
| 15 | `docs/archive/sdd/p5-task7-report.md` | 保留原样，建索引 |
| 15 | `docs/archive/sdd/p5-task4-report.md` | 保留原样，建索引 |
| 15 | `docs/archive/sdd/mw-m1-task-1-report.md` | 保留原样，建索引 |
| 15 | `docs/archive/sdd/v6-task-5-report.md` | 保留原样，建索引 |
| 14 | `docs/archive/sdd/psd-audit-g7.md` | 保留原样，建索引 |
| 14 | `docs/archive/sdd/psd-task-3-report.md` | 保留原样，建索引 |
| 14 | `docs/archive/sdd/w1-task-1-report.md` | 保留原样，建索引 |
| 13 | `docs/archive/sdd/tf01-cleanup-report.md` | 保留原样，建索引 |
| 13 | `docs/archive/sdd/p6-task4-report.md` | 保留原样，建索引 |
| 13 | `docs/archive/sdd/psd-audit-g2.md` | 保留原样，建索引 |
| 13 | `docs/archive/sdd/hit-m2-task-1-report.md` | 保留原样，建索引 |
| 13 | `docs/archive/sdd/numeric-task-7-report.md` | 保留原样，建索引 |
| 13 | `docs/archive/sdd/r2p1-task-1-report.md` | 保留原样，建索引 |
| 13 | `docs/archive/sdd/cap-task2-report.md` | 保留原样，建索引 |
| 13 | `docs/archive/sdd/psd-audit-g3.md` | 保留原样，建索引 |
| 13 | `docs/archive/sdd/numeric-task-3-report.md` | 保留原样，建索引 |
| 12 | `docs/archive/sdd/p5-task6-report.md` | 保留原样，建索引 |
| 12 | `docs/archive/sdd/r2p2-task-1-report.md` | 保留原样，建索引 |
| 12 | `docs/archive/sdd/p2b-task3-report.md` | 保留原样，建索引 |
| 12 | `docs/archive/sdd/task-4-report.md` | 保留原样，建索引 |
| 12 | `docs/archive/sdd/p2b-task1-report.md` | 保留原样，建索引 |
| 12 | `docs/archive/sdd/task-5-report.md` | 保留原样，建索引 |
| 12 | `docs/archive/sdd/task-3-report.md` | 保留原样，建索引 |
| 12 | `docs/archive/sdd/numeric-task-5-report.md` | 保留原样，建索引 |
| 12 | `docs/archive/sdd/psd-audit-g8.md` | 保留原样，建索引 |
| 12 | `docs/archive/sdd/fc-task2-report.md` | 保留原样，建索引 |
| 11 | `docs/archive/sdd/p6-task1-report.md` | 保留原样，建索引 |
| 11 | `docs/archive/sdd/lsp-task-3-report.md` | 保留原样，建索引 |
| 11 | `docs/archive/sdd/hit-m2-task-0-report.md` | 保留原样，建索引 |
| 11 | `docs/archive/sdd/lsp-task-8-report.md` | 保留原样，建索引 |
| 11 | `docs/archive/sdd/task-1-report.md` | 保留原样，建索引 |
| 11 | `docs/archive/sdd/kernel-task-2-report.md` | 保留原样，建索引 |
| 11 | `docs/archive/sdd/lattice-move-report.md` | 保留原样，建索引 |
| 10 | `docs/archive/sdd/p2b-task2-report.md` | 保留原样，建索引 |
| 10 | `docs/archive/sdd/w1-task-4-report.md` | 保留原样，建索引 |
| 10 | `docs/archive/sdd/psd-audit-g4.md` | 保留原样，建索引 |
| 10 | `docs/archive/sdd/numeric-task-2-report.md` | 保留原样，建索引 |
| 10 | `docs/archive/sdd/p6-task3-report.md` | 保留原样，建索引 |
| 10 | `docs/archive/sdd/kc-task-1-report.md` | 保留原样，建索引 |
| 10 | `docs/archive/sdd/numeric-task-1-report.md` | 保留原样，建索引 |
| 10 | `docs/archive/sdd/lsp-task-6-report.md` | 保留原样，建索引 |
| 10 | `docs/archive/sdd/psd-audit-g5.md` | 保留原样，建索引 |
| 10 | `docs/archive/sdd/task-2-report.md` | 保留原样，建索引 |

## 生成伪代码

| 大小 (KiB) | 文件 | 处理 |
|---:|---|---|
| 131 | `docs/pseudocode/compiler/dyn_arr.md` | 保留原样 |
| 108 | `docs/pseudocode/compiler/checker-5.md` | 保留原样 |
| 100 | `docs/pseudocode/标识符对照表.md` | 保留原样 |
| 88 | `docs/pseudocode/arch/linux/ld/elf-4.md` | 保留原样 |
| 86 | `docs/pseudocode/arch/linux/ld/elf-1.md` | 保留原样 |
| 86 | `docs/pseudocode/arch/linux/ld/instr-3.md` | 保留原样 |
| 83 | `docs/pseudocode/compiler/ir_gen-4.md` | 保留原样 |
| 76 | `docs/pseudocode/arch/linux/ld/elf-2.md` | 保留原样 |
| 73 | `docs/pseudocode/compiler/parser-2.md` | 保留原样 |
| 70 | `docs/pseudocode/compiler/monomorph.md` | 保留原样 |
| 67 | `docs/pseudocode/arch/linux/ld/instr-2.md` | 保留原样 |
| 64 | `docs/pseudocode/compiler/lexer.md` | 保留原样 |
| 64 | `docs/pseudocode/arch/linux/ld/ld.md` | 保留原样 |
| 61 | `docs/pseudocode/compiler/elf.md` | 保留原样 |
| 60 | `docs/pseudocode/compiler/ast.md` | 保留原样 |
| 60 | `docs/pseudocode/compiler/opt.md` | 保留原样 |
| 58 | `docs/pseudocode/compiler/ccr_io.md` | 保留原样 |
| 52 | `docs/pseudocode/compiler/dataflow.md` | 保留原样 |
| 50 | `docs/pseudocode/compiler/checker-3.md` | 保留原样 |
| 48 | `docs/pseudocode/compiler/checker-4.md` | 保留原样 |
| 45 | `docs/pseudocode/compiler/parser-4.md` | 保留原样 |
| 45 | `docs/pseudocode/compiler/module.md` | 保留原样 |
| 44 | `docs/pseudocode/arch/linux/ld/instr-1.md` | 保留原样 |
| 44 | `docs/pseudocode/compiler/ir_gen-3.md` | 保留原样 |
| 42 | `docs/pseudocode/compiler/main.md` | 保留原样 |
| 40 | `docs/pseudocode/compiler/interp.md` | 保留原样 |
| 40 | `docs/pseudocode/compiler/ir_gen-2.md` | 保留原样 |
| 38 | `docs/pseudocode/compiler/parser-1.md` | 保留原样 |
| 35 | `docs/pseudocode/compiler/cir_cache.md` | 保留原样 |
| 33 | `docs/pseudocode/compiler/dump.md` | 保留原样 |
| 32 | `docs/pseudocode/compiler/ir_gen-1.md` | 保留原样 |
| 30 | `docs/pseudocode/compiler/parser-3.md` | 保留原样 |
| 30 | `docs/pseudocode/compiler/ptr_analysis.md` | 保留原样 |
| 29 | `docs/pseudocode/arch/linux/ld/elf-3.md` | 保留原样 |
| 29 | `docs/pseudocode/stdlib/cli.md` | 保留原样 |
| 28 | `docs/pseudocode/compiler/globals.md` | 保留原样 |
| 25 | `docs/pseudocode/compiler/checker-1.md` | 保留原样 |
| 25 | `docs/pseudocode/compiler/region_check.md` | 保留原样 |
| 24 | `docs/pseudocode/compiler/checker-2.md` | 保留原样 |
| 19 | `docs/pseudocode/compiler/corearch.md` | 保留原样 |
| 18 | `docs/pseudocode/arch/linux/ld/main.md` | 保留原样 |
| 17 | `docs/pseudocode/stdlib/fmt.md` | 保留原样 |
| 15 | `docs/pseudocode/stdlib/chan.md` | 保留原样 |
| 15 | `docs/pseudocode/stdlib/sched.md` | 保留原样 |
| 15 | `docs/pseudocode/stdlib/scheduler.md` | 保留原样 |
| 15 | `docs/pseudocode/stdlib/toml.md` | 保留原样 |
| 13 | `docs/pseudocode/stdlib/os.md` | 保留原样 |
| 13 | `docs/pseudocode/arch/linux/ld/sizes.md` | 保留原样 |
| 12 | `docs/pseudocode/compiler/provenance_verify.md` | 保留原样 |
| 12 | `docs/pseudocode/compiler/diag.md` | 保留原样 |
| 11 | `docs/pseudocode/stdlib/collections.md` | 保留原样 |
| 10 | `docs/pseudocode/compiler/ext_mgr.md` | 保留原样 |

## 档案

| 大小 (KiB) | 文件 | 处理 |
|---:|---|---|
| 33 | `docs/archive/numeric-migration-inventory.md` | 保留原样 |
| 32 | `docs/archive/memory-model-capability-lattice.md` | 保留原样 |
| 18 | `docs/archive/compcert-reference.md` | 保留原样 |
| 18 | `docs/archive/compcert-round4-findings.md` | 保留原样 |
