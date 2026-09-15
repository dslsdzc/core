# 文档 vs 现实审计（2026-09-16）——「声称了但不成立」的文档断言全表

> 定位：受众 = 维护者 / 后续 agent（**改文档或照文档设计之前先查此表**）；状态 = **记录（审计产物，快照）**；真源 = 本表的**实核命令**（每条带命令 + 结果；行号为 2026-09-16 实读值）。
> 缘起：验证切片侦查（`/tmp/verslice/plan-draft.md`）戳破四处「文档称已定义、实为零实现」；本表为全仓系统扫描 + 逐条实核的结果，并**逐条登记修订去向**。
> 纪律：本次审计**零构建/零编译/零测试**（`ps` 实查后仅只读 grep/sed/Read）· 未跑 `jj`（故本表行号无提交锚，复跑以文本/符号为准）。

---

## 0. 摘要

| 项 | 数 | 备注 |
|---|---|---|
| 审计断言 | **35** | 只收「可被源码证伪」的现状断言（已实现/已定义/真源是 X/由 Y 提供/当前为 Z） |
| **成立** | **20** | 见 §3（含 5 条**诚实样板**：显式标「设计态/未实现/需要」） |
| **不成立** | **13** | 危险 **7**（§1）+ 陈旧 **6**（§2） |
| 无法判定 | **2** | §4（须实跑 / 仓外树未核） |
| **修订去向** | 13 条**全部已修** | 本批 3 提交：`820648bc`（CLAUDE.md）· `d2265f7b`（spec-design + ir-schema + ir-op-semantics）· `43427334`（project-book + onboarding + verifier + errors.md）；**0 条「不改」**（无审计误判） |

**失真集中面（四类文件）**：`ir-op-semantics`（迁移期快照）· `ir-schema`（`.csr` 纯设计标 active）· `CLAUDE.md`（清单 + Known Issues；**agent 必读**）· `project-book`/`onboarding`（已退役格式残留）。
**同期新增发现（审计外，已一并修）**：`CLAUDE.md` 的 `.ccr` 版本 `v8 → v9`（同类）；`src/compiler/linker.cr` = **0 字节空文件**（新登记）。

---

## 1. 危险 7 条（会误导设计/实现；逐条 = 断言 / 实核 / 修订去向）

### D1 `spec-design.md` 称变体/量词「EBNF 已有」（4 处）

- **断言**：`:46`「变体标注（EBNF 已有）」· `:260`「EBNF 已定义（2026-09 起归口 grammar/core.ebnf；corespec.ebnf 为迁移期残留）」· `:283`「变体标注（EBNF 已有）」· `:301`「loop variant，EBNF 已有」。
- **实核**：`grep -nE "variant|forall|exists|#check|#ensure|spec " grammar/core.ebnf` → **0 命中**；`grammar/core.ebnf:12` `FunctionDecl = [ 'pub' ] 'fn' IDENT [ GenericParams ] '(' [ ParamList ] ')' '->' Type ( FunctionBody | '=' Expr ';' )`（**无标注槽**）；`grammar/corespec.ebnf:1` 自述「**2026-09-06 退役**…规约语法并入 `grammar/core.ebnf`（**迁移事项**）」。
- **修订去向**：4 处改「**EBNF 尚未定义——待实现**」；`:260` 处改为修订块（含两条实核 + 「量词属待实现语法」）；原文以引用形式保留在注内。→ `d2265f7b`。

### D2 `.csr` 的「真源」声称不成立（两处 schema 文档）

- **断言**：`docs/ir-schema/corespecir-schema.md:3`「状态 = active；真源 = `src/compiler/ccr_io.cr`（.csr 读写）」；`docs/ir-schema/coreir-schema.md:36/38`（同族叙述）。
- **实核**：`grep -c "csr\|CSR1\|TagNode" src/compiler/ccr_io.cr` → **0**；`grep -rn "csr\|TagNode\|CSR1" --include='*.cr' src/` → **0**（零实现）。
- **修订去向**：`corespecir-schema.md` 状态改 **设计态（未实现）** + 「（拟）…当前零实现」 + 前置裁决提示；`coreir-schema.md` 头部加「真源效力分半」注（`.cir/.ccr` 半成立、`.csr` 半不成立）。→ `d2265f7b`。

### D3 `CLAUDE.md` 的 `src/compiler/` 清单缺 8+ 文件

- **断言**：树形清单 **20 条 `.cr`**（`CLAUDE.md` §Self-Hosted Compiler）。
- **实核**：`ls src/compiler/*.cr | wc -l` → **38**；缺 `ty_shadow/type_engine/type_terms/ccr_types/cir_cache/iface_axis/iface_registry/monomorph/ptr_analysis/provenance_verify/region_check/ext_mgr/ext_safety/type_selftest/purity_selftest/regalloc-consistency/dump/interp/opt/pass` 等（原 20 条之外共 **18 个**）。
- **修订去向**：**全 38 条**重写（每条带**单元归属**，按全路径核 `corec_files(45)/corelsp_files(31)/backend_support_files(9)/common_files(9)`）+ 死件显式标注（`elf.cr` 死文件 TODO #7；`linker.cr` **0 字节空文件**；`regalloc-consistency.cr` 文档载体不入清单）。→ `820648bc`。

### D4 `CLAUDE.md` 的 `src/stdlib/` 清单缺 11 文件

- **断言**：8 文件 + `_import.cr`。
- **实核**：`ls src/stdlib/*.cr` → **19**（缺 `arena/assert/chan/dex/goroutine/hotpatch/sched/scheduler/trace/variadic`）。
- **修订去向**：**全 19 条**重写 + 标注「不在任何清单」的 7 件 + 「单元归属真源」指引。→ `820648bc`。

### D5 `project-book.md §3.2` 按已退役的独立 `.corespec`/`.corespecir` 叙述

- **断言**：`:70-82`「形式规约…是独立的源文件」「规约文件（`.corespec`）」「规约层 IR（`.corespecir`）」。
- **实核**：`adr-0001-corespec-crasm-retired.md:16`「**.corespec 退役**（2026-09-06, `582a1e1`）：规约 = `.cr` 语法唯一表达」；`spec/*.corespec` ×4 仅剩 7 行退役标注。
- **修订去向**：§3.2 **整段改写**为「规约层：行为约束的图上标注」（`.cr` 内联 → 图 TagNode；`.csr` 标零实现）；原叙述以删除线保留。→ `43427334`。

### D6 `onboarding.md:57` 把已退役 `corespec.ebnf` 列为「语法唯一真源」

- **实核**：该行原文列 `core.ebnf`（全语言）/`corespec.ebnf`（规约）/`tokens.ebnf`；`grammar/corespec.ebnf` 头部自述已退役。
- **修订去向**：改「`core.ebnf`（唯一真源）/`tokens.ebnf`；`corespec.ebnf` = **已退役**（ADR-0001）…归**未完成的迁移事项** ⇒ **勿引**」。→ `43427334`。

### D7 仓外真源：`verifier/kernel-spec.md:3`「真源 = `~/mctt` 源文件」

- **实核**：`ls -d ~/mctt` → **存在**（本机可达）⇒ 断言本机成立；但**无版本锚**（仅「`icfp25` 分支」）⇒ 行号对照跨机/跨会话不可复现、外部树变动后静默漂移。
- **修订去向**：加修订注（无版本锚 + 补锚要求 + 跨机复核前置 + 同类问题互引 `ir-op-semantics §0`）。→ `43427334`。

---

## 2. 陈旧 6 条

| # | 出处（file:line） | 断言（摘） | 实核 | 修订去向 |
|---|---|---|---|---|
| S1 | `maintainer/design/ir-op-semantics.md:46`（+ `:102` 表行） | 「规划中的 `IR_APPROX = 51`（**尚未入 ast.cr**）」/「50 已定义 + 1 规划」 | `grep -n IR_APPROX src/compiler/ast.cr` → `:568 IR_APPROX : int = 51;`（含注释） | 改「**51 条全部已定义**」+ `:102` 表行改「注解 / —（零发射点；已定义）」→ `d2265f7b` |
| S2 | `ir-schema/coreir-schema.md:255`（+ `:283`） | 「`.ccr` 二进制序列化（**v7**…）」/「load 校验 `version==7`」 | `ccr_io.cr:135` `CCR_VERSION = 9`；`:138` `CCR_SEG_COUNT = 8` | 节内加版本修订注（**现行 version = 9**、8 段、P4 T1 +TYPE/IFACE、P6 T3 8→9；「v7」= **段表架构代号**）+ `:283` 改 `version==9` → `d2265f7b` |
| S3 | `CLAUDE.md` §Known Issues「corec2 tokenizer 死循环」 | 「`./build/corec2 check` 卡在 tokenizer…」 | `src/ci/run.sh:127-131` full-bootstrap 构 corec2→corec3 并 `cmp`；R2 P6 T7 实测 **rc=0 + IDENTICAL + N06=0 + 冒烟 42** | 叠删除线 + 现状块（「历史条目，当前不复现，不再作阻塞项」）→ `820648bc` |
| S4 | `CLAUDE.md` §Test suites | 只列 bootstrap 3 + selfhost 3 | `tests/selfhost/test_*.py` **50+**；`tests/bootstrap/*.py` **7** | 加清单口径注（全集真源 = `ls` + `src/ci/run.sh` 挂点）→ `820648bc` |
| S5 | `developer/errors.md:297` | 族表「总计 **~146**」 | 族表 **17 族加和 = 150**（脚本核）；明细码行 **149**；`ast.cr` `EC_*` 定义 **137** | 总计改 **150** + 加「三口径注」（150/149/137 + 成因：L 族 11 无码常量等 + 真源关系）→ `43427334` |
| S6 | `maintainer/design/ir-op-semantics.md §0` | 真源 = `~/compcert/…`（仓外） | 本审计**未核** `~/compcert` 存在性（同 D7 类）；行号引用无锚 | §0 加修订注（仓外无版本锚 ⇒ 结论面/行号面分开判）→ `d2265f7b` |

---

## 3. 成立 20 条（抽样；含 5 条诚实样板）

| # | 出处 | 断言 | 实核 |
|---|---|---|---|
| ✓1 | `design/pointer-model.md:3` | 三 pass 为真源、描述已实现行为 | 三文件在位 + `src/compiler/main.cr:614-615` 调 `region_check_all(); provenance_verify_all();` |
| ✓2 | `design/pointer-model.md:118` | 权限机制 = **设计态**（自洽标注） | 未夸大 ✓（**样板**） |
| ✓3 | `design/region-model.md:77-90` | Arena **已实现**（`stdlib arena.cr` 全生命周期） | `src/stdlib/arena.cr` 在位；`IR_ARENA_NEW=32`/`IR_ARENA_RESET=33` |
| ✓4 | `design/execution-model.md:157` | go 端到端**已实现**（chan 同步/result/G0） | `chan/goroutine/sched/scheduler.cr` 在位 + `chan_test/conc_test/go_e2e_test.cr` 语料；「多 M = 设计态」同句已标 |
| ✓5 | `design/regalloc-cache-mapping.md:104` | 契约 = `regalloc-consistency.cr` | 该文件在位；`alloc_registers` = `src/arch/x86_64/regalloc.cr:406` |
| ✓6 | `design/corelsp.md:3` | 真源 = `src/lsp/` + build 脚本 corelsp 段 | `src/lsp/` 7 文件在位 |
| ✓7 | `maintainer/testing.md:64` | `test_borrow.py` **7 规则** | `CASES` 元组计数 = 7 |
| ✓8 | `maintainer/testing.md:89` | 自举链固定 `-O 0` | `src/ci/run.sh:127/131` 均 `-O 0` |
| ✓9 | `developer/errors.md:4` | 真源 = `ast.cr` `EC_*`；L 族例外 | `EC_*` 定义 **137**；`lexer.cr:39 add_error(msg: string)` **单参**（无码）✓ |
| ✓10 | `developer/errors.md:5-12` | fail-closed 默认阻断 + 豁免表 **9 条** | `src/compiler/diag.cr::diag_gate_exempt` 在位；体内码常量恰 **9** |
| ✓11 | `design/ir-op-semantics.md:47` | 51 条目 | `ast.cr` `IR_*` 定义 = **50**（+`IR_APPROX` 见 S1）|
| ✓12 | `design/ir-op-semantics.md:189` | BC6 `CORE_SAFE` 默认开启 | `src/compiler/ext_mgr.cr:40-41` |
| ✓13 | `design/ir-op-semantics.md:194` | BC10 `e2_ptr_null_check` | `instr.cr` 5 处 |
| ✓14 | `developer/syntax.md:501` | 归口 core.ebnf = **迁移事项**；实现状态 **设计态** | 与源码一致 ✓（**样板**） |
| ✓15 | `developer/tutorial.md:161` | 「**未实现**：本节为设计预览」 | 一致 ✓（**样板**） |
| ✓16 | `coq/README.md:3` | 真源 = 本文件（`coq/` 证明**待建**） | `docs/coq/` 仅 README ✓（**样板**） |
| ✓17 | `design/spec-design.md:445` | 「`.csr` 现在只服务外部验证器——**需要**编译器内部回读通道」 | 一致（诚实：未声称已建）✓（**样板**） |
| ✓18 | `design/crasm.md:3` | 状态 = deprecated | 与 ADR-0001 一致 |
| ✓19 | `spec/*.corespec` ×4 | ADR 称「4 文件退役标注」 | 4 × **7 行**，头部即退役声明 ✓ |
| ✓20 | `design/dataflow-design.md:192` | `SG_LOOP` = 迭代语义（现状） | `SG_LOOP = 1`（`SG_FUNC=0`/`SG_FOR=2`…）常量在位 |

---

## 4. 无法判定 2 条

| # | 出处 | 断言 | 缺什么 | 本批处置 |
|---|---|---|---|---|
| U1 | `CLAUDE.md` §Known Issues（`pass_cse/O1`） | 「`--opt-level 1` **可能**崩溃」 | 须一次 `-O 1` 自举链实测（审计零构建） | 就地标注「**未复核**；不得据它推断 O1 可用/不可用」→ `820648bc` |
| U2 | `design/ir-op-semantics.md §0` | 真源 = `~/compcert/…` | 未核该树存在性/版本（同 D7 类） | 加锚注（§2-S6）→ `d2265f7b` |

---

## 5. 复现命令（只读；可整体复制）

```bash
cd <repo>
# 断言抽取
grep -rn "已实现\|已定义\|已落地\|已接线\|真源\|已退役\|已修" docs/maintainer/design docs/developer docs/ir-schema docs/project-book.md docs/maintainer/*.md
# D1
grep -nE "variant|forall|exists|#check|#ensure|spec " grammar/core.ebnf      # → 0
# D2
grep -c "csr\|CSR1\|TagNode" src/compiler/ccr_io.cr                          # → 0
grep -rn "csr\|TagNode\|CSR1" --include='*.cr' src/                          # → 0
# D3/D4
ls src/compiler/*.cr | wc -l ; ls src/stdlib/*.cr | wc -l                    # → 38 / 19
# S1/S2
grep -n "IR_APPROX" src/compiler/ast.cr ; grep -n "CCR_VERSION\|CCR_SEG_COUNT" src/compiler/ccr_io.cr
# S3/S4
sed -n '127,131p' src/ci/run.sh ; ls tests/selfhost/test_*.py | wc -l
# ✓10
sed -n "$(grep -n 'fn diag_gate_exempt' src/compiler/diag.cr | cut -d: -f1),+40p" src/compiler/diag.cr | grep -oE "EC_[A-Z_]+" | sort -u | wc -l   # → 9
# S5
python3 - <<'EOF'
import re
s=n=0
for l in open('docs/developer/errors.md',encoding='utf-8'):
    m=re.match(r'\| ([A-Z]+) \| [A-Z0-9–]+ \| (\d+) \|', l)
    if m and m.group(1)!='总计': s+=int(m.group(2)); n+=1
print(n, s)   # → 17 150
EOF
```

## 6. 诚实边界

1. **零构建/零测试**（`ps` 实查时他方在编译 ⇒ 明确不占构建面）⇒ 行为类断言只到**静态证据级**：S3 的「不复现」由「CI 链会挂死 vs P6 T6 实测 rc=0」推理得出，未本地重跑 corec2 链；U1 明确标未复核。
2. **未跑 `jj`**（审计期纪律）⇒ 本表行号为 2026-09-16 快照，无提交锚。
3. **取样口径**：状态词 + 真源 + 计数筛；`docs/archive/`、`docs/pseudocode/`、`docs/superpowers/**` 的历史快照**未逐条审**（按仓例不追改）——若需要把 `superpowers/specs/**` 的「现状」段也纳入，另开一轮。
4. **零「不改」**：13 条不成立项**全部已修**（无一条因「实核后发现其实成立」而撤回）⇒ 本审计**无已知误判**；若后续发现误判，按本文件头部「状态 = 记录」追加勘误段，**勿静默改写历史**。
5. **修订风格**：全部按仓内勘误惯例——**保留原断言原文**（注内引用/删除线）+ 标注「谁改的（2026-09-16 文档审计）/为何改/实核证据」；**不静默抹掉旧断言**。
