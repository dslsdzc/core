#!/usr/bin/env bash

# Core CI job 分发器——按 $CI_JOB_NAME 执行对应 job 的命令集。
# 本地复现：CI_JOB_NAME=check src/ci/run.sh
# 注意：本地长时间编译请遵守 CLAUDE.md 的硬性规则 6（cpulimit/nice 限速）。
#
# 模板来源：rust-lang/rust src/ci/run.sh（configure/make 部分替换为 Core 构建命令）。
#
# 编号约定（2026-09-17 起）：下方注释里的 `TODO #YYYY-MM-DD-N` = 「日期 + 序号」新标识
# （旧全局单调号 `#NN` 已废弃、永久封存）。规则与旧号对照表（旧号解析真源）见
# `TODO.md` 头部「编号约定」/「编号迁移对照表」；迁移计划与分类依据见
# `docs/superpowers/plans/2026-09-17-todo-id-migration.md`。新增引用一律用新格式。

CI_JOB_NAME="${CI_JOB_NAME:-}"
set -euo pipefail
IFS=$'\n\t'

# TODO:125（临时处理）：禁用 core dump——桌面 core_pattern 为 systemd-coredump
# 管道时，陷阱程序（SIGILL）在 core dump 写入会挂起；CI 无诊断价值。根治方向
# 见 TODO「图推导边界判定 pass」（检查前移编译期，缩小运行时 trap 面）。
ulimit -c 0 2>/dev/null || true

if [ -n "$CI_JOB_NAME" ]; then
  echo "[CI_JOB_NAME=$CI_JOB_NAME]"
fi

ci_dir="$(cd "$(dirname "$0")" && pwd)"
source "$ci_dir/shared.sh"

# 自举构建：Python bootstrap → 原生 corec/corearch
# CI 的 build job 只构建一次，后续 job 下载产物后设 CI_SKIP_BUILD=1。
build_selfhost() {
  if [ "${CI_SKIP_BUILD:-0}" = "1" ]; then
    echo "build_selfhost skipped (CI_SKIP_BUILD=1)"
    return 0
  fi
  python3 build_selfhost_native.py
}

# src/compiler 项目检查（check 不触发 ELF 后端）
check_compiler_sources() {
  ./build/corec check src/compiler
}

# 集成套件：每个 .cr 编译成 ELF 并运行，main 返回 0 为通过
run_suite() {
  for f in tests/suite/*.cr; do
    case "$f" in
      # 负例 SKIP（**显式两档**；2026-09-18 suite 清障阶段由 `*_mini*.cr` 通配收紧而来）：
      # `at_test_mini4.cr` / `at_test_mini6.cr` = **函数体内嵌套 `fn` 声明**（TODO #2026-09-10-12）——
      # 该构造不属语言面（grammar/core.ebnf：Statement 不含 FunctionDecl），corec 以 `error[P21]` 拒收
      # （rc=1）⇒ 属**负例**而非可运行正例。对应的测试是 tests/selfhost/test_nested_fn.py（挂在 selfhost-tests，
      # 断言 rc=1 + P21 + 定位行号 + 无 139，且**点名这两档 fixture**）。
      # 收紧理由：原通配把**整族 9 档**一起跳过，其中 `at_test_mini.cr`（`@sizeOf`）与
      # `at_test_mini9.cr`（`@fields`）是**可修好的正例**（前者缺 `import io`、后者断言过期；
      # 已在本次修好）⇒ 移出 skip 列表，让这两个内建在套件运行中真正执行。
      */at_test_mini4.cr|*/at_test_mini6.cr) continue ;;   # 注意：`$f` 是**全路径**，模式必须带 `*/` 前缀（原 `*_mini*.cr` 靠前置 `*` 命中）
    esac
    if [ ! -s "$f" ]; then
      continue
    fi
    # 逐档 clean-cache（2026-09-18 suite 清障阶段新增）：`.cir` 快照**暖态重放**今日实测会给出
    # **不同的 IR**（同一源、同一文件：冷 build ⇒ `@fields` = `"x,y"`；暖 build ⇒ 取到**别的函数的串**
    # `"arena_reset"` ⇒ 行为 rc 冷 0 / 暖 1、产物逐字节不同）⇒ 不清缓存时，本轮结果依赖上一轮的缓存状态，
    # 不可复现。做法与 `tools/baseline/parity_run.sh` 的逐档 `clean-cache` 一致（既有先例）。
    # 该缺陷本体另立条目（见 TODO 当日段「`.cir` 暖态重放静默错值」），**不在本次修**。
    ./build/corec clean-cache >/dev/null 2>&1
    echo "suite: $f"
    case "$f" in
      # Scheduler/channel/arena corpora are the SYSTEM raw-word ABI (G/channel
      # cells mix pointers and ints in int slots; arena syscalls return raw
      # addresses). Compile them raw; ordinary user programs keep tagged
      # big-int semantics.
      */chan_test.cr|*/conc_test.cr|*/go_*.cr|*/arena_*.cr)
        ./build/corec ccr "$f" -o /tmp/core_suite_bin.ccr
        ./build/corearch --raw-int --elf /tmp/core_suite_bin.ccr -o /tmp/core_suite_bin
        ;;
      *)
        ./build/corec build "$f" -o /tmp/core_suite_bin --static
        ;;
    esac
    chmod +x /tmp/core_suite_bin
    /tmp/core_suite_bin
  done
}

case "$CI_JOB_NAME" in
  check)
    build_selfhost
    check_compiler_sources
    ;;

  bootstrap-tests)
    python3 tests/bootstrap/test_pipeline.py
    python3 tests/bootstrap/test_borrow.py
    # TODO #2026-09-11-7：硬性规则 #2 机械执行钩子的加固检查（BLOCK 19 + ALLOW 11；纯 python，无需编译器）
    python3 tests/harness/test_block_git.py
    # R2 P7 非构建的小型阶段（CI 挂点审计 #2026-09-10-5）：**挂点覆盖率的自动检查**——枚举
    # tests/{selfhost,bootstrap,harness}/*.py 与 run.sh 挂点做差集，未挂项必须逐条登记
    # 白名单（tests/harness/ci_hook_allowlist.txt，带理由；含范围外登记段）；含**内存内
    # 突变自证**（摘掉一个真挂点 ⇒ 必红）。纯 python、毫秒级、无需编译器 ⇒ 挂本 job。
    # 根因：`test_backend_bootstrap.py` 曾「自称已挂」而 run.sh 零命中——该检查是唯一能拦住
    # 「清单双注册漂移（project-mode error[N06] 静默）」的守卫，已致 P3a 33×N06 跨 5 任务漏检。
    python3 tests/harness/test_ci_hook_coverage.py
    # 检查体系加固阶段（2026-09-16，TODO #2026-09-16-27 低成本档）：ent_kernel 中立性**静态守卫**——
    # 纯 python 文本扫描（剥注释/字符串后查禁内核实例 token），**无编译器依赖**（实测
    # 0.05s）⇒ 挂本 job（bootstrap-tests 不构建）。挂前缺口登记见 allowlist 原 `:23` 条。
    python3 tests/selfhost/test_ent_kernel_neutrality.py
    # 检查体系加固阶段：**突变自证**（纯 python、内存内、零副作用）——对本次改严的
    # 六条检查（#2026-09-16-22/#2026-09-16-23/#2026-09-16-24/#2026-09-16-25/#2026-09-16-26/#2026-09-16-28）各构造「能骗过旧形态」的坏输入，
    # 断言「旧形态绿 ∧ 新形态红」。这才是「检查足够严格」的自动证据（不是注释里的
    # 自我声明）。实测 21/21（18 突变体 + 3 正控）。
    python3 tests/harness/test_criteria_mutations.py
    # 2026-09-17 TODO 标识迁移阶段：**迁移检查**（纯 python、毫秒级、无编译器依赖）——
    # J1 无残留（全仓旧形态 `TODO #N` = 0；防「以后又有人写 #NN」这类回归）· J2 无悬空
    # （新 id ↔ TODO.md 标题双向一致）· J3 映射完备（覆盖 #1..#98 + 空号 #66 注记）·
    # J4 突变自证（把一处新 id 引用还原成旧号 ⇒ J1 必红）。**范围由维护者扩展**：
    # 该检查原先按「本次只改文档和注释」登记于白名单，维护者裁示「不挂 = 几周内腐烂成没人跑的
    # 脚本」⇒ 挂本 job（同 test_block_git / test_ci_hook_coverage 的位置与体例）。
    python3 tests/harness/test_todo_id_migration.py
    # 检查接线阶段（2026-09-18，TODO #2026-09-17-15 / #2026-09-16-15）：两条**静态守卫**（纯 python、
    # 无编译器依赖）——① LSP `@` 内建补全表 ↔ 语言面**双真源**（checker EXPR_AT ∪ `@` 面注解解析器）
    # 双向差集为空；含**真源枚举守卫**（新增注解解析器 ⇒ 必红，防「第三真源」静默失效）+ 四项突变自证。
    # ② `IR_REF` 发射点形状绊线（恒 1 处 + dest 紧邻局部）——**廉价版**：只证形状，语义版（dest 非全局）
    # 需构建 + 新增 dump 通道（`g_x86_is_global` 今日无 dump 打印），见该条。
    python3 tests/harness/test_lsp_builtin_table.py
    python3 tests/harness/test_ir_ref_sites.py
    # 文档风格审查阶段（2026-09-24）：**受保护面检查的有效性用例**（纯 python、毫秒级、零编译器、零 jj、
    # 零网络 ⇒ 挂本 job）。被验对象 = `tools/doc_protected_surface.py`（文档编辑的「非散文面」
    # 抽取 + 多重集对拍）。理由同 test_criteria_mutations：该脚本自己「PASS」只说明两侧抽取相同，
    # **不说明它能检出问题**——一条恒 PASS 的空检查与真正有效的检查读数一样（本仓「空壳绿」前科：
    # 析取断言里一个分支恒假，通过全部来自另一个分支）。本档逐类打突变，实测 9 类受保护面**逐类必真红**
    # + 散文自检（改散文不入面）+ fail-closed（围栏不成对 ⇒ 拒绝出数）+ 下限检查（削减语料必被拦下）。
    # 刻意不读 jj 修订（只读文档目录）⇒ CI 浅检出 + 无 jj 亦可行（对比 parity_run.sh 因需 jj
    # 而登记为不可挂）。突变从 manifest **自动派生**（非写死串）⇒ 文档改动不致本档腐烂。
    python3 tests/harness/test_doc_protected_surface.py
    ;;

  selfhost-fast)
    # PR fast layer: the concurrency happy paths plus the compiler type/purity
    # gates. The full 120-file selfhost corpus runs in the merge/manual layer.
    build_selfhost
    python3 tests/gate.py fast
    ;;

  selfhost-tests)
    build_selfhost
    # ─── 判定面回归网（R2 P5 Task 5 起；**影子通道已下线**，不得引用其计数/摘要/站点直方图）───
    # 影子对拍（R2 P1 的迁移期仪器：`--type-shadow` / `[type-shadow]` 摘要 / 差异转储 / 站点直方图）
    # 已随 R2 P5 Task 5 整体删除（对照物 `type_equal_legacy` 在 T4 删除后对拍停摆，全语料
    # `decisions=0`）。判定面回归网 = ① **冻结基线同源对拍**：冻结基线（**由
    # `tools/baseline/rebuild.sh` 从 pinned revision 重建**——配方 + 三 sha 白名单见
    # `tools/baseline/REBUILD.md`；R2 P6 Task 1 起可复现，二进制仍不入库）× 当前源 vs
    # 当前二进制 × 当前源，**85 档**语料（runner `tools/baseline/parity_run.sh`，逐档 clean-cache；
    # 档数 = 实读枚举 34+2+26+19+4（suite/compiler/后端内核/stdlib/examples）= 与 runner 的 `CORPUS_TOTAL=85` 硬断言一致。
    # 2026-09-24 的统计是 76 档（36+2+15+19+4）。v4 迁移删除了 2 档空 fixture，并把架构轴、OS 轴、
    # target 轴的文件纳入 t3（15→26），所以 2026-10-25 起改为 85 档）
    # `check` rc + 日志逐档 diff（人工判断，本 job 内不跑——CI 为浅检出且无 jj）；② **行为探针**：
    # 下列套件（test_named_face / test_named_dedup / test_type_engine / test_optional /
    # test_match_exhaust …）+ **入仓探针语料 `tests/probes/`（29 档；runner
    # `tools/baseline/probes_run.sh`；变异态/影子态不可复跑面见该目录 README）**；
    # ③ **突变控制**（改坏派生面 ⇒ 探针/对拍转红）；④ **三态纪律**（引擎 -1 ⇒ ICE04 硬错，
    # 见 main.cr 硬名单）。新的工作阶段新增判定面行为**必须**同时给这三类证据之一，不得回退到
    # 「与旧版逐字节同」（TODO #2026-09-11-9 的规定）。
    # CP-1 runtime substrate gate. Keep this before test_merge_copy.py: that
    # suite currently has a pre-existing p41 SIGSEGV (recorded in the CP-1
    # report), and `set -e` would otherwise prevent this gate from running.
    # 2026-09-18 suite 清障阶段：**suite 语料卫生检查**（`suite` 路径不在 PR 检查范围内 ⇒ 把本次的四处期望搬进检查范围）——
    # H1 修好的两档正例 build+run rc=0 · H2 两档负例 check rc≠0+P21+**零产物** · H3 正控（断言有辨别力）·
    # H4 run_suite 跳过集合 == 两档负例且模式**全路径锚定** · H5 0 字节档集合固定；**逐档 clean-cache**
    # （理由 = TODO #2026-09-18-9 的暖态重放缺陷 ⇒ 否则结论依赖上一轮缓存状态）。
    # ─── 阶段 8 A₂（条目 6）：并发 handle 类型模型对齐 —— **检查范围内的端到端用例**（2026-09-18）───
    # **11 例** = 5 档并发语料 × （check 干净且**无 TF01** + build+run rc=0）+ 1 形态自证（`chan_make→string`
    # 赋值 + `chan_send/recv/close(string)`）。
    # 警告：**为何必须挂这里**：5 档语料在 `tests/suite/`，而 **`suite` 路径不在 PR 检查范围内**（台账「PR 门覆盖域陷阱」条：
    # glob 匹配不等于进入检查范围）⇒ 本套件把该证据编进 `selfhost-tests`（检查范围内），使其**不悬空**。
    # 根因 = `alloc: () -> string` 模型 vs 3 处 handle 返回型 `-> int`（`chan_make`/`g_new`/`sched_go`）+ 5 处
    # handle 形参；修法 = **(A) 语料/stdlib 向模型对齐**（裁定 (A)；(C) handle 兼容明令禁止）。
    # ─── 判定依据网加固阶段（criteria-harden，2026-09-16）：**弱判定依据改强 + 挂点扩容** ───
    # 审计依据 = docs/superpowers/specs/2026-09-16-criteria-strength-audit.md §4（挂载成本序
    # 低 → 中 → 高）与 §2 表 B（B1-B6 弱检查 → TODO #2026-09-16-22-#2026-09-16-26/#2026-09-16-28）。本次在 #2026-09-16-27 成本序下挂
    # **低/中成本档**（下列四档；各档时长实测见行内注）；旧 `test_mw_task1-6`
    # 随 v9.1 默认 BigInt 切换删除（2-limb 路径已移除），不再有未挂档。
    # 注：本次同时把四档的**把弱检查改严**：#2026-09-16-22 事件 1-4 全字段模板（test_hit_table）、
    # #2026-09-16-24 dump 值域白名单（test_hit_table）、#2026-09-16-25 STR 段冷/暖
    # 前缀契约（test_cir_warm_path，已挂上行）、#2026-09-16-26 剔除面白名单 + 计数（test_ccr_types，已挂上行）。
    # 高（**allowlist 自标最高危**：唯一拦「清单双注册漂移 ⇒ project-mode `error[N06]`
    # 静默」之门——rc=0 但日志带 error[ 判红；已致 P3a 33×N06 跨 5 任务漏检）。本次
    # 先实测时长 = **22.5s**（stage0→1→2 冒烟 + O2 元数据读回；内含 nice -n 19）⇒ 判定
    # **可挂**（成本远低于审计担心的「构建面」量级）。挂点理由记录：allowlist 原 `:19`。
    # ─── 判定依据文件化阶段（criteria-carrier，2026-09-16）：**ELF canary + `.ccr` 四条 = 机器检查** ───
    # 缘起（实核）：这两项检查的锁定值——canary `95084e7b…d475`（28822B）与 `.ccr` 四条
    # 96015/96158/142793/142936——此前**只活在 docs/ 与 .superpowers/ 的文字里**，本仓
    # `*.py/*.sh/*.cr/*.toml/*.yml` 命中数为 0（每个阶段靠人/代理**手跑**引用）。同类事故本仓
    # 已发生过一次：`test_backend_bootstrap.py` 自称已挂而本文件零命中 ⇒ `error[N06]` 跨 5 任务
    # 33 次静默漏检（见本 job 上方与 tests/harness/test_ci_hook_coverage.py）。本次把它升一层。
    # 执行文件是 tools/baseline/canary_check.sh（配方 + 锁定值**单一真源** = tools/baseline/
    # canary_values.tsv；fail-closed 四规则：rc≠0 / 值表缩水 / sha 与尺寸逐条比 / 缺工具）。
    # 挂本 job 的理由：检查需要**已构建**的编译器（`build` 路径按 main.cr:713-721 用 get_arg(0)
    # 的目录拼 corearch），而本 job 首行即 build_selfhost。成本 = 1 档 canary ELF + 4 次 `.ccr`
    # （2 语料 × 2 规则；语料 240B/2.5KB）⇒ 秒级。**值表更新规则**见
    # docs/superpowers/plans/2026-09-16-criteria-carrier.md §6（不符 ⇒ 停下上报，勿改值表）。
    # 有效性用例（防止检查本身也静默通过）：A 机械（真挂断言）+ B 合成自证（S1 绿路可达 + S2–S6
    # 五类必红）+ C **真产物篡改必红**（复制文件刚落盘的 build/canary_artifacts/ ⇒ 翻一字节 ⇒
    # `--verify-only` 必须红且指名产物）。执行文件先跑 ⇒ 本轮**零额外编译**（顺序即契约）。
    # `--require-compiler`：本 job 已构建 ⇒ 缺编译器时不得静默跳过真实路径（fail-closed）。
    # ─── 第 4 阶段（home-repro，2026-09-17）：`.so` 扩展索引的**可复现性/承重面/内存安全** ───
    # 缘起（TODO #2026-09-16-20）：编译器解析 `import` 时读 `$HOME/.core/lib/<模块>/index` 并把其中的
    # 名字驻留进产物 ⇒ 同一提交同编译器、**换台机器产物就变**（前阶段把检查落成执行文件时的 CI 失败即此，
    # `generics_test` ±28B）。本次改「侧表 + 首次引用物化」⇒ 未引用条目零产物足迹。
    # 检查项（8 例全绿；**夹具入仓** = 判定依据自己可复现，两态索引取 tests/fixtures/so_index/）：
    # 两态 `.ccr` 两条规则下逐字节相同 · 良性索引零足迹 · **承重面**（索引独有名字：有索引 rc=0、
    # 无索引 rc=1 + `error[N06]` 响亮）· **索引行数不再是行为分界**（N=2/200/2000 三档产物同
    # 且进程 rc 正常——TODO #2026-09-17-1 的越界写堆随本次删块消除，**必须留判定依据证明「已消除」**）·
    # `HOME` unset ≡ 空 HOME（#83）· ELF 跨两态同 · 静态零命中硬编码家目录字面量。
    # 挂本 job 的理由同文件（需已构建编译器）。成本实测 ≈ 12s（含 2000 行大索引档）。
    # ─── 阶段 5（opt-dex，2026-09-17；TODO #2026-09-16-29 = 原 #91）：可选 dex（`dex?`）整族 ───
    # 缘起：四态（裸/装箱 × bits/scaled）与家族面（映射表 9 列）。根因三条（实读）：① 写点门
    # `declared_ti == TI_DEX` 对 `dex?` 不触发 + 槽型「随值」（ir_gen.cr:2525/:2559/:2577-2579）；
    # ② 装箱序倒置 5 处（:1541/:2751/:2788/:2836/:3241 先装箱后规范 ⇒ 漏斗落箱对象 = 空转）；
    # ③ 声明面在 `unpack_type` 塌陷（parser.cr:150-153/1427）⇒ `dex?` 形参槽型 TI_INT + 实参环/返回/
    # 全局门全失效 ⇒ **ABI 失配**（按 XMM 传、按 GP 读）= 垃圾值 + **双路径分歧**（本族最严重形态）。
    # 判定依据（维护者 2026-09-17 裁决 G10 三条纪律全部写进套件）：① 四态对拍（四格互等 + **锚定格** == 7）；
    # ② **禁第三态**——bits 源的 interp 路径必须是 **255**（= bits→scaled 转换在场时 `IR_I2F/IR_F2I`
    # 的解释器能力边界拒收，255 是**期望值**）；出现第三个值一律判红；③ **不许单路径绿结案**
    # （ELF 绿 ∧ interp 第三态 ⇒ 仍红）。另含：编译期拒绝面（`[dex?;2]` 字面量 ⇒ TK02/TA02 + 零产物）
    # 与 **apx 槽自证路径**（bits 源 `.cir` 必须有 binary64 位模式常量、scaled 源必须没有 ⇒ 防「探针不触发」）。
    # 配套 suite 语料 `tests/suite/opt_dex_test.cr`（常规路径；返回码 1..14 = 首个失败面编号）。
    # 计划 = docs/superpowers/plans/2026-09-17-opt-dex.md · 报告 = 收官阶段报告。
    # ─── 阶段 8 条目 2（静默面处理）：可选值 `==`/`!=` 表示透明（2026-09-17）───
    # **19 例**：判定依据 ① `Some(x)==Some(x)` 真 · ② `None==None` 真 · ③ `Some(x)==None` 假 ·
    # ④ 同源自比较真（裸/装箱两表示；装箱取 `*p` 形态绕开软诊断 B04，同阶段 5 体例）·
    # ⑤ 非可选比较逐值固定用例（零变化面）。
    # 另有：表示透明三例（裸/装箱/混合同判）· `!=` 两面 · 合成 bool 面 ·
    # **六位位码总固定**（`bit0..bit5` 打包，rc 可读；**修复前 = 24 · 修复后 = 30**，两路径同判）
    # 锚更正留痕（2026-09-18 复核）：本行原文写「修复前 = 8 · 修复后 = 14」= **旧探针形状**读数
    # （bit4 用 `n == 7`、`n = None` ⇒ 0）；`0186427f` 重定 bit4 为 `a == 7`（present 形）+ 补 bit5 后真值 = 24/30
    # （前态二进制实测 24/24；本链 30/30）。
    # · 未覆盖面抽样一例。
    # 判定依据模型：**以运行退出码为准**（rc 即读数；不依赖 stdout）；两路径同判（ELF 与 interp）。
    # 突变自证（阶段级留痕；**已接机检**：`tests/harness/test_criteria_mutations.py`）：把新增分派块退回
    # 不触发（= 修复前路径）⇒ 位码回 **24**（两路径；2026-09-18 复核重跑：旧值 8 = 旧探针形状，已更正）。
    # 机理：`==` 通用二元路径逐槽比原始值——裸(rep=0)比载荷 通过、装箱比指针 ⇒ 恒假；
    # 修复 = 比较点归一 `(absent, payload)` 后按值比（`ir_gen.cr` opt_cmp_* 三函数 + 分派块）。
    # ─── 阶段 8 条目 3（静默面处理）：extern 声明含可选（`?`）⇒ 硬错 P24（2026-09-17）───
    # **12 例** = 拒收面 6（`dex?`/`int?` 形参 · `dex?`/`int?` 返回 · 混合形参 · `string?`）+ 非可选对照 4
    # （`dex` / `int` / `never` / `char`——守卫 `test_iface_ops.py` 同形态的编译面）+ 守卫语料 2
    # （`tests/suite/ffi_test.cr` · `tests/probes/p_ffi2.cr` check rc=0）。
    # 判定依据要件：① 含可选 ⇒ rc=1 + `error[P24]` + 定位 + **零产物**；② 非可选逐字节不变；③ `dex?`/`int?` 同路径。
    # 位置 = parser 的 extern 分支（签名规则位，同 P020 先例；返回类型节点在 parser 内可用）。
    # 突变自证（阶段级留痕）：撤掉该检查 ⇒ 6 条拒收例回 `check=0`。
    # ─── 阶段 8 条目 4（静默面处理）：顶层兜底不再静默吞 token ⇒ P25（2026-09-18）───
    # **12 例** = 拒收 5（顶层多余 `}` / typo 声明 / typo 声明+使用 / 游离 `;` / typo 关键字）+ 合法对照 7
    # （import ×2 / **无初值全局**（= 注入运行时源 `rt.cr:4` 同形）/ 有初值全局 / `mod` / `type` / `@` 注解）。
    # 判定依据：拒收 ⇒ check rc=1 + `error[P25]` + 定位 + build rc=1 + **零产物**；合法 ⇒ check/build/run 三面 0；
    # **不挂起**（P6：报错路径仍消费 token；套件内每例限时 60s、超时即红——CI 超时不是红）。
    # 警告：同阶段前置修（本轮实测暴露）：`parse_all` 原只吞 `import` 关键字本身，路径/别名 token 一直靠兜底
    # 静默吞（全语料普遍）⇒ 新硬错会误伤**每一条合法 import**（实测 `import io` 的 `io` 与注入源
    # `import arena_globals`）。修复 = 按 res_imports 形状逐字消费 `[@proj] [a(::b)*] [: alias] [;]`。
    # 全语料对拍（212 档 × `check`；前态二进制 vs 本修复）：差异 **7 档且全部本就 rc=1**（spec 负例 5 ·
    # 探针 1 · 旧 fixture 1；期望码 V02/V03 仍在）⇒ 合法语料零差异。
    # 突变自证（阶段级留痕）：兜底退回裸 `advance_tok()` ⇒ 拒收 5 例回 `check=0`。
    # ─── 阶段 8 条目 5（静默面处理）：`apx` 标签**适用性白名单** ⇒ P26（2026-09-18）───
    # **7 例** = 拒收 5（`dex?` · `.` 推断 · `auto` · `string` · `bool`）+ 白名单 2（`dex, apx` 表示路径 ·
    # `int, apx` 既有契约纯注解；两者 `.cir` 各恰一条 `approx` = 机制固定）。
    # 判定依据：拒收 ⇒ check rc=1 + `error[P26]` + 定位 + build rc=1 + **零产物**；白名单 ⇒ check/build/run 三面 0。
    # 裁定依据（lead 2026-09-18 = (B)）：白名单 = 显式 `dex` + 显式 `int`（**有契约**：`test_apx_tag.py`
    # 固定语法合法/语义不变/`.cir` 携 `approx`，bootstrap 同向 ApproxInstr ⇒ 两前端对齐）；其余（`dex?`/`.`/`auto`/
    # `string`/`bool`…）**零文档 / 零测试 / 值面无路** = 静默谎。禁止：裁 (A)（连 `int, apx` 一并拒）已否：
    # 那会**改契约**（须重定 test_apx_tag + 登记两前端接受集分歧）——判定依据原则「有契约 ⇒ 有意设计；无契约 ⇒ 静默谎」。
    # 白名单两形的产物**逐字节不变**（前态二进制 vs 本链实测 IDENTICAL）· 契约套件 `test_apx_tag.py` 2/2 复跑绿。
    # 突变自证（阶段级留痕）：撤掉该检查 ⇒ 拒收 5 例回 `check=0`。
    # ─── 阶段 6（验证内核正式接入 = 正式规约语法 `#check`/`#ensure`；2026-09-17）───
    # 四组 48 项：A 语法面（16）· B 检查面（11）· C `--dump-vcs` 通道（15）· D `.ccr` 零足迹三段式（6，含 Δ 公式）。
    # **Δ 公式 = 本次最有价值的判定依据**（T3 首轮当场抓到实现自身的 `str_intern("result")` 泄漏：两用例 STR Δ 凭空 +10B），
    # 必须留仓。语料 = `tests/spec/`（33 档，独立目录，**不进**路径①/路径②语料——两路径计数不变 = 旧面零扰动的证据）。
    # 时长实测（2026-09-17 本机）：**1.8s（空载）～ 34.5s（机器 swap 抖动时）**——两者相差近 20×，
    # 根因 = 系统级 I/O 饱和（非本套件），故**以区间记**；即便取上界也不影响 CI 关键路径。
    # （同阶段实测：`loadavg ≈ 11–16`（4 核）· swap 已用 ≈ 5.8GB 时取上界值。）
    # ─── 阶段 8 PR-B（F3）S1′ report-only 打点：**活性自证 + 默认零足迹**（2026-09-18）───
    # 20 断言 = ① 必命中探针逐字段（活性：`9917 4 14 0 0 2 f`）· ② 默认位/`CORE_S1P=0` 零行 ·
    # ③ 无失配程序零行（负控）· ④ extern 形走 `9918` 单列 + 默认位零行 · ⑥ 护栏②③⑥ 各配对照路径 ·
    # 警告：方法调用不可达（实测：`s.m(b)` 异型 0 打点 ⇒ ④ 分支在本点死；固定成判定依据，扩覆盖时翻 ≥1）·
    # ⑤ 全 `tests/suite/*.cr` 默认位零打点（**冷缓存逐档**）。
    # **为什么必须有这一档**：打点扫面两种假信号——假阳（grep 裸标识符命中源码回显：A 阶段「6 档 30 点」实为 0）
    # 与假阴（打点没装/没生效，「0 点」被当「真干净」：本档 2026-09-18 **当场抓出真假阴**——
    # `globals.cr` 的 `mut = -1` 初值经 Python bootstrap 构建**静默丢成 0** ⇒ 开关恒关、探针 0 命中）。
    # 判定依据①（只发不阻断）的产物面在阶段级对拍：前态二进制 vs 本链 **37/37 逐字节 IDENTICAL**（两侧各自 clean-cache）。
    # ─── 台账「哨兵/不可判定值族」三条 skip（2026-09-19 小刀）：`TI_NEVER` / `TI_DYN` / 泛型形参 ───
    # 为什么必须门内：硬错与台账**共用同一条环**（`s1p_arg_one` 是两面公共谓词）⇒ 只登记不改环
    #   ⇒ 硬错一打开这两类会红。本档固定：A dyn 不记 · B 泛型形参不记 · **C 真异型仍记（非真空锚）**
    #   · D 未定义名不记；并含 **⑤ 空间守卫**（`TI_DYN` 下标 vs `TYP_GENERIC_PARAM` kind **数值同为 7
    #   而空间不同**）+ 其**突变自证**（错空间写法必红、删前缀条必红、剥注释承重、防「一律红」反向固定）。
    # 警告：阳性对照一律用**已定义的 int 变量**——D 落地后「未定义名」类输入已不可见，拿它当正控会真空绿。
    # ─── 字符串插值 `${...}`：词法契约 + **展开语义**（2026-09-18 插队修复 + 裁定 (b) 同阶段）───
    # **本特性此前全域零覆盖**：`tests/` 与 `examples/` 里 `grep '\${'` = **0 命中**，`src/` 唯一命中是
    # `src/lsp/analysis.cr` 的注释 ⇒ 它烂掉约两个月没人知道（**这条判定依据存在的理由**）。
    # 修复前根因：lexer 插值分支**双推进**（skip 循环已到 `}` 之后，循环尾通用 `_pos += 1` 又吃一字节）
    # ⇒ ① `}` 后首字符静默丢；② 收尾引号被吞 ⇒ 串吞到行尾 ⇒ 同行 `;`/**`}`** 进串 ⇒ 顶层 `fn` **P21 级联**。
    # 展开（裁定 (b)）：lexer 拆 part token（段 T_STRING / 洞 T_INTERP，**洞内 `{}` 配平**）· parser 串链 ·
    # checker 按洞类型**就地改写**：string 恒等 · int→`int_str` · bool→`bool_str`（**不经 int**）·
    # char/dex/其它 ⇒ **P028 硬错**；畸形插值 ⇒ **P027 硬错**。
    # 判定依据 = A 解析完整性（同行含 `}`/后续语句 ⇒ 无 P21 + rc）· B 值 10 形态（含洞内配平、实参位、`\${` 字面）·
    # C 错误面 4 例（P027×2 + P028×2：check rc=1 + 码 + build rc=1 + **零产物**）· D bootstrap 面事实
    # （bootstrap lexer 仍**原文保留** ⇒ 两前端分歧，已登记）· E 回退守卫 4 条。
    # **突变自证（可复跑）**：`COREC_BIN=<展开前二进制> …` ⇒ B 组按「原文保留」全红；`<修复前二进制>` ⇒ A/B 皆红。
    # 2(a) 视图内建（`@ptr_of`/`@str_of`）：**两面一致性**（硬要求①：同一探针在 corec 与 bootstrap
    # 两面的 rc/运行值一致）· **零代码生成**（②：往返写法与直写的 ELF **逐字节一致**）·
    # **未知名 fail-closed**（③：两面都报错）· **安全面 (ii)**（视图在 `unsafe` 块外 ⇒ 两面硬错）·
    # 实参类型两面拒绝。对照必须同处 `unsafe` 包络内（`unsafe` 本身带 +158B 区域元数据，与视图无关）。
    # (i) 小阶段：`@raw_int` 放宽接受**指针**（两向固定用例）——正控 = ptr_ref_first 诊断面转绿 + 两路径值面；
    # 负控 = 6 类仍拒（string/bool/array/slice/ref_type/struct，check 面 rc=1 + TF07 + 文案含 or pointer）+ 既有 dex/int 仍受；
    # **负控只写 check 面**：TF07 是 build-scope 豁免码 ⇒ 「build 面零产物」在本次恒假（豁免未撤，撤条归 (甲) 刀 4）。
    # Allocator blob: generator relocations, simple/arena parity, ELF wiring,
    # trap paths, stale-blob check, and clang reference parity. The clang-based
    # tests skip only when clang is absent.
    # Per-thread TLS state and atomic runtime primitives.
    # Stub register allocator contract (corec selftest-stub-regalloc).
    # BigInt machine-word and FFI boundary: rawbuf byte access, cell_store
    # word-range traps, and the --link --static layout (user code keeps its
    # original offset so BigInt BSS references stay valid).
    bash src/ci/selfhost_tests.sh
    ;;

  selfhost-tests-*)
    export CI_SHARD_INDEX="${CI_JOB_NAME##*-}"
    export CI_SHARD_TOTAL="${CI_SHARD_TOTAL:-4}"
    build_selfhost
    # Criteria carrier runs once, on shard 0, after the compiler exists. The
    # harness test validates that these two executable hooks stay present and
    # that the locked values still fail closed when tampered with.
    if [ "$CI_SHARD_INDEX" = "0" ]; then
      bash tools/baseline/canary_check.sh
      python3 tests/harness/test_canary_carrier.py --require-compiler
    fi
    bash src/ci/selfhost_tests.sh
    ;;

  suite)
    build_selfhost
    run_suite
    ;;

  full-bootstrap)
    # Three-stage frontend bootstrap. corec2 and corec3 must be byte-identical.
    build_selfhost
    ./build/corec build src/compiler/main.cr -o /tmp/corec2 --static -O 0
    cp ./build/corearch /tmp/corearch
    chmod +x /tmp/corec2
    chmod +x /tmp/corearch
    /tmp/corec2 build src/compiler/main.cr -o /tmp/corec3 --static -O 0
    chmod +x /tmp/corec3
    cmp /tmp/corec2 /tmp/corec3
    /tmp/corec3 --help || [ "$?" -eq 1 ]
    ;;

  *)
    echo "error: unknown CI_JOB_NAME: $CI_JOB_NAME" >&2
    exit 1
    ;;
esac
