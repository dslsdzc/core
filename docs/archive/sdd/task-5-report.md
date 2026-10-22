# R1 Task 5 收尾报告（语言面收窄 波 R1）

日期：2026-09-10
Brief：`docs/archive/sdd/task-5-brief.md`（唯一需求来源）
计划：`docs/superpowers/plans/2026-09-10-language-surface-narrowing-r1.md`
提交：31471d26（路径限定 8 文件；父 = aaa08303）（初提 ce8b6bd0，随后用 `jj squash` 并入一条 TODO 补充，哈希更新为 31471d26）
结论：DONE ，全部判据都由我实际运行并通过，没有采信项、跳过项或隐瞒项。

---

## 0. 判据链顺序（关键：判据跑在最终树上）

最终树的构成性保证 = 先改全部 src/test，再重建，清缓存，跑判据。顺序：

1. 开工重建（build1，改 src 前），通过（见第 1 节）
2. 编辑 `src/compiler/parser.cr`（Task 2 遗留 M1 注释恢复）+ `tests/selfhost/test_compile.py` + `tests/selfhost/test_global_init.py`
3. 二次重建（build2），得到最终树二进制
4. `clean-cache`（TODO #5）
5. 全量回归 11 套（第 2 节），作为最终树判据
6. 自举全链加冒烟（第 3 节），作为最终树判据
7. 之后只改文档（spec/TODO/伪代码/盘点），不再触碰 src/test，回归结论对最终树成立

（注：首次回归曾在 build1 上跑过一遍，同样 11/11 rc=0；本报告只以 build2 最终树一轮为准，前一轮不充当证据。）

---

## 1. 重建（`nice -n 19 python3 build_selfhost_native.py`，两次）

build1（开工基线，rc=0）：

```
[GUARD] corec: manifest OK (37 files)
[GUARD] corec: build log clean (error[ = 0, undefined = 0)
[GUARD] corearch: manifest OK (31 files)
[GUARD] x86_64-linux target: manifest OK (3 files)
[GUARD] corearch: build log clean (error[ = 0, undefined = 0)
[GUARD] corelsp: manifest OK (26 files)
[GUARD] corelsp: build log clean (error[ = 0, undefined = 0)
=== BUILD SUCCESS ===
```

build2（最终树，rc=0）：同上逐行一致（BUILD SUCCESS + 三处 manifest OK + 三处 build log clean）。

日志：`/tmp/r1t5/build.log`（build1）、`/tmp/r1t5/build2.log`（build2）。
说明：brief 写「两处 [GUARD] OK」，实际为三对（corec / corearch+target / corelsp），manifest 三处 + 日志守卫三处，全部 OK。

## 2. 判据前清缓存

```
$ nice -n 19 ./build/corec clean-cache
cleaned .core/cache/cir/
rc=0
```

两轮各清一次（第二次在 build2 之后、最终回归之前）。依据 TODO #5：缓存键不含编译器身份、跨重建不失效。

## 3. 全量回归（brief Step 1 清单逐条，最终树）

命令均 `nice -n 19 python3 <suite>`；逐套件完整日志 = `/tmp/r1t5/logs/<name>.log`；汇总 = `/tmp/r1t5/summary.txt`。

| # | 命令 | rc | 末行摘要 |
|---|---|---|---|
| 1 | `tests/selfhost/test_compile.py` | 0 | `All selfhost compile tests passed.` |
| 2 | `tests/selfhost/test_backend_bootstrap.py` | 0 | `[PASS] stage0 and stage1 O2 smoke ELFs return 7` |
| 3 | `tests/selfhost/test_hit_table.py` | 0 | `24/24 passed` |
| 4 | `tests/selfhost/test_ccr_v7.py` | 0 | `24/24 passed` |
| 5 | `tests/selfhost/test_live_ranges.py` | 0 | `13/13 passed` |
| 6 | `tests/selfhost/test_slice_bounds.py` | 0 | `7/7 passed` |
| 7 | `tests/selfhost/test_global_init.py` | 0 | `15/15 global-init cases passed (dual path)` |
| 8 | `tests/selfhost/test_lexer_parity.py` | 0 | `PASS test_legal_forms_unchanged` |
| 9 | `tests/bootstrap/test_pipeline.py` | 0 | `29/29 passed` |
| 10 | `tests/bootstrap/test_borrow.py` | 0 | `4/4 passed` |
| 11 | `tests/bootstrap/test_generics.py` | 0 | `3/3 passed` |

11/11 rc=0，没有 FAIL 行。套件 2 内部含 stage0 到 stage3 byte-identical + smoke 7 + O2 链（project-mode `error[` 门 run_checked 全程生效）。

## 4. 自举全链 + 冒烟（Task 5 亲跑，补齐计划口径缺口）

口径修正（诚实披露）：计划 Step 2 写「corec2/corec3 链与 cmp/N06 保护由 test_backend_bootstrap.py（Step 1 已跑）覆盖」，不准确：`test_backend_bootstrap.py` 覆盖的是 corearch stage 链（stage1/2/3 产物 byte-identical），corec 前端的 corec2/corec3 链不在其中（该链在 `src/ci/run.sh` 的 `full-bootstrap` job）。故本任务按 run.sh 同款亲跑补上，不留判据空档。

```
$ nice -n 19 ./build/corec build src/compiler/main.cr -o /tmp/corec2 --static -O 0     # rc=0
$ cp ./build/corearch /tmp/corearch ; chmod +x /tmp/corec2 /tmp/corearch
$ nice -n 19 /tmp/corec2 build src/compiler/main.cr -o /tmp/corec3 --static -O 0       # rc=0
$ cmp /tmp/corec2 /tmp/corec3                                                          # rc=0，结果 IDENTICAL
$ /tmp/corec3 --help                                                                   # rc=1（CI 期望形 `|| [ "$?" -eq 1 ]`）
```

| 项 | 结果 |
|---|---|
| corec2 build | rc=0 |
| corec3 build | rc=0 |
| `cmp corec2 corec3` | rc=0 = IDENTICAL |
| corec3 --help | rc=1（CI 期望形；usage 正常打印） |
| corec2 日志 `error[` 行数 | 0 |
| corec3 日志 `error[` 行数 | 0 |
| corec2 日志 N06 计数 | 0 |
| corec3 日志 N06 计数 | 0 |

冒烟：

```
$ nice -n 19 ./build/corec run 'fn main()->int{return 42;}'
rc=42        ，期望 42，通过（stdout 为 5 阶段进度行，无诊断）
```

日志：`/tmp/r1t5/fullboot.txt`、`/tmp/r1t5/fb_corec{2,3}.log`、`/tmp/r1t5/smoke.log`。

## 5. 本任务除 brief 外的两件事

### 5.1 测试卫生修复（Task 4 评审 Minor）

`tests/selfhost/test_global_init.py`：
- `clean_cache()` 现检查返回码，`rc != 0` 时打印 `[FAIL] clean-cache failed (rc=N)`，输出前 10 行，然后执行 `SystemExit(1)`（依据：清缓存失败 + TODO #5 旧缓存 = 判据被不报错地污染，这是本项目的严重问题）。
- 删除未使用的 `import sys`。
- 判据：最终回归中该套件 15/15 双路径通过（含 clean-cache 路径被执行）。

### 5.2 TODO.md 两条新登记（既有缺口，本批不修）

亲自复现（不是转述，第 6 节有原始 rc）：

- #11 解释器 callee 内联路径缺枚举族 opcode（Important）：`p14_enum_in_callee.cr` interp rc=0 vs ELF rc=33；`p15_enum_split.cr` interp rc=139 vs ELF rc=33。
- #12 类型别名仅一层解析（Minor）：`type A = [int;2]; type B = A; g : B;` interp/ELF 双 rc=139；一层别名对照 rc=7。

## 6. Step 5：test_compile.py 清单陈旧路径核对（含 fallback 分支判定）

发现：`concat_sources()` 原用 `if os.path.exists(path)` 不报错地跳过缺失条目，三条 `src/compiler/backend/`（`x86_64.cr` / `x86_64/instr.cr` / `resolve.cr`）自波 1 三轴搬迁之前即已不存在（追溯：最后一次触碰这些路径的提交属自举 phase 3 时期），清单长期条目缺失，测试却一直显示通过。

实证（为何不补入三轴文件）：按 brief 首选路径把条目更新为三轴现状路径（`src/arch/x86_64/*` + `src/format/elf/*` + `src/os/linux/*`）后，Test 2 失败：

```
Compiler source errors: [...]      ，有 68 个唯一未定义符号，全部来自 HIT 引擎段
（HIT_ROLE_*/HIT_EV_*/HIT_ST_OFF_*/hit_r32/hit_event_lookup/g_hit_*/hit_table_active …）
```

即：三轴文件归属 corearch 编译单元（`src/arch/hit/*` 为独立清单段），本清单等于 corec 前端单元闭包，原本就是刻意裁剪，不是遗漏。故按 brief 的 fallback 分支处理：

- 三条死条目删除（原本就被不报错地跳过，拼接内容零变化）。实证：以父版 `test_compile.py`（`jj file show -r aaa08303`）的旧清单按旧语义（跳过缺失）拼接，与新版全存在拼接逐字节比对，sha256 同为 96096b101807250f，722974 字节相同（旧 33 条目缺 3 / 新 30 条目缺 0）
- `exists` 不报错地跳过改为存在性断言（`build_selfhost_native.py:144-152` guard_manifest 同款：缺失即打印条目名 + `sys.exit(1)`）
- 就地注释写明裁剪意图与归属（三轴文件属 corearch 单元）与本次实证
- 负对照（守卫有效证明）：临时副本注入伪条目 `src/compiler/backend/NOSUCH.cr`，得到 rc=1 且精确报出该条目名（探针文件已删，原件未被污染）
- 复跑 `test_compile.py` rc=0 `All selfhost compile tests passed.`

偏差说明（对 brief 字面）：fallback 原文提到「保 `exists` 语义」，本实现选择全清单严格断言（宁可更强）。理由：条目现已全部现存，无任何合法跳过场景；保留通配式不报错地跳过正是本条缺陷的成因。已登记 TODO.md 备查。

## 7. Task 2 评审遗留清账（M1 / M3）

- M1（注释恢复）：`src/compiler/parser.cr:408` 行尾注释恢复 `// 词素串下标（-1 = 无）`（注释-only，零行为；改动后二次重建 + 全量回归 = 最终树判据）。
- M3（文档面随迁，Task 2 只动 src/）：
  - `docs/pseudocode/compiler/ast.md`：40 行逐条标注（`T_INT_I8..T_FLOAT_F64` ×10 + `W_I8..W_F64` ×10，标识符表与数值表各一组）+ 2 处表头注（后缀类别不再发射 / `W_*` 已删、`data` 槽恒 0）。
  - `docs/pseudocode/compiler/parser-2.md`：`parse_primary`（原 167-206）与 `parse_pattern`（原 729-741）两处宽度分支按现源删除 + 作用段更新 + 变更注记。
  - `docs/numeric-migration-inventory.md`：行首追记（R1 改判覆盖原 `保留` 结论）+ 7 处逐点标注（29/32/51/148/190/230-231/244，含争议点 7 结案）。
    - `:148` 实测修正：原称 `src/lsp/analysis.cr:895` 有 `(k >= T_INT_I8 && k <= T_FLOAT_F64)` 区间，实测不存在：`src/lsp/analysis.cr` 中 `T_INT_I8`/`T_FLOAT_F32`/`T_FLOAT_F64` 零出现（grep 实证），该处实际只有 `(k >= T_INT_TYPE && k <= T_AUTO_TYPE)`（analysis.cr:981）；原称的 864 行注释块亦不存在。按实测改写为「不适用/结案」。
  - Info（不处理，仅记录）：`build/all.cr`、`build/bootstrap_self.cr`、`build/selfhost_compiler.cr` = 陈旧拼接产物（忽略项，不入树）。

## 8. 文档改动清单（提交 31471d26 的 8 文件）

| 文件 | 改动 |
|---|---|
| `docs/superpowers/specs/2026-09-10-language-surface-narrowing-design.md` | 状态行改为已实施（R1）；第 1.3 节两项已完成（全局路径按表示语义修 / 注记三项已做）；第 2 节表加「结果」列（三项落点）；第 3 节波 R1 三项已完成 + 三处行为变化；第 4 节挂账结清 |
| `TODO.md` | 宽度三项划销 + 落点；定长裁决条目（挂 R2）；新增「全局初始化机制」（含非 main 入口/库形态约束）；新登记 #11/#12/#13；文档区新增「测试清单陈旧 + exists 不报错地跳过」条 |
| `docs/numeric-migration-inventory.md` | 追记 + 7 处标注（含 :148 实测修正） |
| `docs/pseudocode/compiler/ast.md` | 40 行逐条标注 + 2 处表头注 |
| `docs/pseudocode/compiler/parser-2.md` | 两处宽度分支按现源删除 + 作用段更新 |
| `src/compiler/parser.cr` | M1 行尾注释恢复（注释层，1 行） |
| `tests/selfhost/test_compile.py` | 清单陈旧路径修正 + 存在性断言 + 注释说明 |
| `tests/selfhost/test_global_init.py` | `clean_cache()` rc 检查 + 删 `import sys` |

台账（不入树，`.superpowers/` 忽略项）：`docs/superpowers/implementation/2026-09-11-sdd-progress.md` 追加 R1 收尾段（各任务哈希 + 判据结果）。

计划文件未改：本批计划 `2026-09-10-language-surface-narrowing-r1.md` 的 32 个 `- [ ]` 复选框在 Task 1-4 均未勾选（全批一致），Task 5 亦未触碰（避免单任务破例造成口径不一；台账为本批真相记录）。如需统一勾选，建议由 lead 一次性补。

## 9. 亲测复现记录（新增 TODO 条目证据）

```
$ ./build/corec run    < p14_enum_in_callee.cr >     得到 interp rc=0（错值；应为 33）
$ ./build/corec build  p14 后运行 ELF，得到 elf rc=33
$ ./build/corec run    < p15_enum_split.cr >         得到 interp rc=139（SIGSEGV）
$ ./build/corec build  p15 后运行 ELF，得到 elf rc=33

$ ./build/corec run 'type A=[int;2]; type B=A; g : B; fn main()->int{ g[1]=7; return g[1]; }'
                                                     得到 interp rc=139
$ ./build/corec build 同源后运行，得到 elf rc=139
$ 一层别名对照（g : A）                              得到 interp rc=7（通过）

$ ./build/corec run 'fn main()->int{return 0xZZ;}'
  得到 rc=1，输出 `error: invalid digit in integer literal`（无 `error[`）
  实测日志 `error[` 计数 = 0；同一诊断打印 4 遍（3 条消息 × 4 轮）
```

## 10. 限制与非目标

- 本任务不改 src 行为（唯一 src 改动 = 单行注释）；未新增/删除功能。
- `TODO.md` #11/#12 两条缺口按指示只登记不修。
- lexer 诊断前缀不一致（#13）仅登记；本次未扩守卫扫描面（属后续任务）。
- 未触碰计划文件与 `.superpowers/` 之外的本批其它资产。
