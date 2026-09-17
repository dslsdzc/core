#!/usr/bin/env bash

# Core CI job 分发器——按 $CI_JOB_NAME 执行对应 job 的命令集。
# 本地复现：CI_JOB_NAME=check src/ci/run.sh
# 注意：本地长时间编译请遵守 CLAUDE.md 铁律 6（cpulimit/nice 限速）。
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
build_selfhost() {
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
      # 负例 SKIP（**显式两档**；2026-09-18 suite 清障批由 `*_mini*.cr` 通配收紧而来）：
      # `at_test_mini4.cr` / `at_test_mini6.cr` = **函数体内嵌套 `fn` 声明**（TODO #2026-09-10-12）——
      # 该构造不属语言面（grammar/core.ebnf：Statement 不含 FunctionDecl），corec 以 `error[P21]` 拒收
      # （rc=1）⇒ 属**负例**而非可运行正例。判据 = tests/selfhost/test_nested_fn.py（挂 selfhost-tests，
      # 断言 rc=1 + P21 + 定位行号 + 无 139，且**点名这两档 fixture**）。
      # 收紧理由：原通配把**整族 9 档**一起跳过，其中 `at_test_mini.cr`（`@sizeOf`）与
      # `at_test_mini9.cr`（`@fields`）是**可修好的正例**（前者缺 `import io`、后者断言过期；
      # 已在本批修好）⇒ 移出 skip 列表，让这两个内建在套件腿**真跑**。
      */at_test_mini4.cr|*/at_test_mini6.cr) continue ;;   # 注意：`$f` 是**全路径**，模式必须带 `*/` 前缀（原 `*_mini*.cr` 靠前置 `*` 命中）
    esac
    if [ ! -s "$f" ]; then
      continue
    fi
    # 逐档 clean-cache（2026-09-18 suite 清障批新增）：`.cir` 快照**暖态重放**今日实测会给出
    # **不同的 IR**（同一源、同一文件：冷 build ⇒ `@fields` = `"x,y"`；暖 build ⇒ 取到**别的函数的串**
    # `"arena_reset"` ⇒ 行为 rc 冷 0 / 暖 1、产物逐字节不同）⇒ 不清缓存时**本腿的结论依赖上一轮缓存状态**，
    # 不可复现。做法与 `tools/baseline/parity_run.sh` 的逐档 `clean-cache` 一致（既有先例）。
    # 该缺陷本体另立条目（见 TODO 当日段「`.cir` 暖态重放静默错值」），**不在本批修**。
    ./build/corec clean-cache >/dev/null 2>&1
    echo "suite: $f"
    ./build/corec build "$f" -o /tmp/core_suite_bin --static
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
    python3 tests/bootstrap/test_generics.py
    # TODO #2026-09-11-7：铁律 #2 机械执行钩子的加固判据（BLOCK 19 + ALLOW 11；纯 python，无需编译器）
    python3 tests/harness/test_block_git.py
    # R2 P7 非构建小批（CI 挂点审计 #2026-09-10-5）：**挂点覆盖率机械判据**——枚举
    # tests/{selfhost,bootstrap,harness}/*.py 与 run.sh 挂点做差集，未挂项必须逐条登记
    # 白名单（tests/harness/ci_hook_allowlist.txt，带理由；含范围外登记段）；含**内存内
    # 突变自证**（摘掉一个真挂点 ⇒ 必红）。纯 python、毫秒级、无需编译器 ⇒ 挂本 job。
    # 根因：`test_backend_bootstrap.py` 曾「自称已挂」而 run.sh 零命中——该门是唯一能拦
    # 「清单双注册漂移（project-mode error[N06] 静默）」的守卫，已致 P3a 33×N06 跨 5 任务漏检。
    python3 tests/harness/test_ci_hook_coverage.py
    # 判据网加固批（2026-09-16，TODO #2026-09-16-27 低成本档）：ent_kernel 中立性**静态守卫**——
    # 纯 python 文本扫描（剥注释/字符串后查禁内核实例 token），**无编译器依赖**（实测
    # 0.05s）⇒ 挂本 job（bootstrap-tests 不构建）。挂前缺口登记见 allowlist 原 `:23` 条。
    python3 tests/selfhost/test_ent_kernel_neutrality.py
    # 判据网加固批：**突变自证**（纯 python、内存内、零副作用）——对本批改强的
    # 六条判据（#2026-09-16-22/#2026-09-16-23/#2026-09-16-24/#2026-09-16-25/#2026-09-16-26/#2026-09-16-28）各构造「能骗过旧形态」的坏输入，
    # 断言「旧形态绿 ∧ 新形态红」。这才是「判据够强」的机械证据（不是注释里的
    # 自我声明）。实测 21/21（18 突变体 + 3 正控）。
    python3 tests/harness/test_criteria_mutations.py
    # 2026-09-17 TODO 标识迁移批：**迁移判据**（纯 python、毫秒级、无编译器依赖）——
    # J1 无残留（全仓旧形态 `TODO #N` = 0；防「以后又有人写 #NN」这类回归）· J2 无悬空
    # （新 id ↔ TODO.md 标题双向一致）· J3 映射完备（覆盖 #1..#98 + 空号 #66 注记）·
    # J4 突变自证（把一处新 id 引用还原成旧号 ⇒ J1 必红）。**范围由维护者扩展**：
    # 该判据原按「本批只动文档+注释」登记于白名单，维护者裁示「不挂 = 几周内腐烂成没人跑的
    # 脚本」⇒ 挂本 job（同 test_block_git / test_ci_hook_coverage 的位置与体例）。
    python3 tests/harness/test_todo_id_migration.py
    # 判据接线批（2026-09-18，TODO #2026-09-17-15 / #2026-09-16-15）：两条**静态守卫**（纯 python、
    # 无编译器依赖）——① LSP `@` 内建补全表 ↔ 语言面**双真源**（checker EXPR_AT ∪ `@` 面注解解析器）
    # 双向差集为空；含**真源枚举守卫**（新增注解解析器 ⇒ 必红，防「第三真源」静默失效）+ 四项突变自证。
    # ② `IR_REF` 发射点形状绊线（恒 1 处 + dest 紧邻局部）——**廉价版**：只证形状，语义版（dest 非全局）
    # 需构建 + 新增 dump 通道（`g_x86_is_global` 今日无 dump 打印），见该条。
    python3 tests/harness/test_lsp_builtin_table.py
    python3 tests/harness/test_ir_ref_sites.py
    ;;

  selfhost-tests)
    build_selfhost
    # ─── 判定面回归网（R2 P5 Task 5 起；**影子通道已下线**，不得引用其计数/摘要/站点直方图）───
    # 影子对拍（R2 P1 的迁移期仪器：`--type-shadow` / `[type-shadow]` 摘要 / 差异转储 / 站点直方图）
    # 已随 R2 P5 Task 5 整体删除（对照物 `type_equal_legacy` 在 T4 删除后对拍停摆，全语料
    # `decisions=0`）。判定面回归网 = ① **冻结基线同源对拍**：冻结基线（**由
    # `tools/baseline/rebuild.sh` 从 pinned revision 重建**——配方 + 三 sha 白名单见
    # `tools/baseline/REBUILD.md`；R2 P6 Task 1 起可复现，二进制仍不入库）× 当前源 vs
    # 当前二进制 × 当前源，**75 档**语料（runner `tools/baseline/parity_run.sh`，逐档 clean-cache；
    # 档数 = 实读枚举 35+2+15+19+4（suite/compiler/后端内核/stdlib/examples）= 与 runner 的 `CORPUS_TOTAL=75` 硬断言一致；
    # 2026-09-17 批 6 T6 实测重数）
    # `check` rc + 日志逐档 diff（手工判据，本 job 内不跑——CI 为浅检出且无 jj）；② **行为探针**：
    # 下列套件（test_named_face / test_named_dedup / test_type_engine / test_optional /
    # test_match_exhaust …）+ **入仓探针语料 `tests/probes/`（29 档；runner
    # `tools/baseline/probes_run.sh`；变异态/影子态不可复跑面见该目录 README）**；
    # ③ **突变控制**（改坏派生面 ⇒ 探针/对拍转红）；④ **三态纪律**（引擎 -1 ⇒ ICE04 硬错，
    # 见 main.cr 硬名单）。新批次新增判定面行为**必须**同时给这三类证据之一，不得回退到
    # 「与旧版逐字节同」（TODO #2026-09-11-9 口径）。
    python3 tests/selfhost/test_compile.py
    python3 tests/selfhost/test_type_engine.py   # 类型项引擎自测通道（selftest-types **415 例**——P5 收官 404 + R2 P6 Task 2 增 11（`ts_t2_neg_run`：¬ 面同类原子身份判据的邻域覆盖——同身份 / μ 字面 / ⊤ₖ 双向 / 跨枚举同名 / 同枚举异变体 / 令牌字面 / AK_NAMED / 空链与链元素域外 / 参数化面 / REF mut 标记面；三例 `t3.*_over_claim` 为**重钉**（0→1，不增减）；P0..P6 T2 一路漏挂）
    python3 tests/selfhost/test_iface_ops.py     # R2 P2b Task 4/5/6：接口查表接线（算术/逻辑/条件三门 + 索引兜底门 + TY→TI 单表合一；正控/负控/登记面/站点域 76 例 + R2 P6 Task 4a 增 2（方法调用站点 never 透传 + 泛型方法登记钉）＝ 78 例）
    python3 tests/selfhost/test_purity.py          # 效应/纯度批判据（真纯度 13 例 + 链语义 4 例的自测通道驱动）
    python3 tests/selfhost/test_ccr_v7.py          # 效应/纯度批 Task 3：.ccr 层三条边集语义断言（取代「与旧版逐字节同」）
    python3 tests/selfhost/test_ccr_types.py       # R2 P4 Task 1/2/3/4 + P5 Task 2：段机制（版本 8 + loader 三闸/必备集 + 旧 v7 拒收）8 例 + TYPE 内容面（行表/项 DAG 序列化 + 确定性装填 + corearch 读回对拍 + loader 负分支）10 例 + IFACE 内容面（五小节/条目扩列 16/形状命名化/签名项化/impl 边与方法表/corearch 读回/跨段引用域/确定性）10 例 + DFNode.TK 项槽（逐节点规则 + dex 语料 + NOD 36B/同序 + 冷/暖快照对称 + dump 零产物影响 + .cir 布局未变）6 例 = 34 例 + P5 T2 单槽化 6 例（复合行走辅码 + 互斥不变量 + F1 hotpatch 无面 + 复合行冷/暖对称 + 复合行 NOD 同序 + 快照盘面派生码保真）= 40 例 + R2 P6 Task 3 项索引 8 例（版本闸 v8 拒收 / NOD 40B 字段序 / 项索引落盘读回对拍（非退化）/ 两通道面一致 / 辅码面与复合行保真 / 项索引越界与不一致 ⇒ 拒绝 / 段界检 / D18 纯度静态）= 49 例（**+1 他批新增，本批机械核对同步**：实测 49/49）
    python3 tests/selfhost/test_impl.py
    python3 tests/selfhost/test_borrow.py
    python3 tests/selfhost/test_pointer_safety.py
    python3 tests/selfhost/test_params_limit.py   # TODO #2026-09-10-4 形参上限/≥18 形参静默误编译回归
    python3 tests/selfhost/test_generic_param_erasure.py # (乙) 泛型实例形参擦除（2026-09-18）：A1 形参链具体化 + A2a 第二遍。C1/C2 值判据（bits 三态 255 / scaled 两腿严格）· C3 槽型直读（--dump-params：T 形态 slot=8 decl=1 / T? 形态 slot=8 decl=0）· C4 调用点机械判据（call g1[dex](_dxsc)）· C5 幂等（bits 恰 2、scaled 恰 0 条 dest=_dxsc）· C6 --dump-params rc 中性/零产物 · C7 check 零诊断。**语料零覆盖声明**：全语料无「泛型 × dex」实例 ⇒ 表示面只能由本套件探针触达（见计划 §11）
    python3 tests/selfhost/test_at_rename.py      # `@no_bounds_check` → `@NoBoundsCheck` 更名（维护者 2026-09-17）：旧名**响亮失败**（build/check/run 三面 rc=1 + 定位 + 零产物，绝不静默）+ 新名两形态等价 + 两条入仓语料运行 + `.cir` 显示名（括号形态有行/语句形态零 IR = F4 语义保持）+ 分派点四处同步守门 + IR 常量 35 钉 = 14 例
    python3 tests/selfhost/test_global_seams.py   # 全局行 operand seam（2026-09-16 批）：B1/B2/B4/B5 全局 vs 局部同形对拍（mut 全局 + 期望值）+ B6(b) 发射字节级（静态无 .so 无运行期腿）+ B7 非回归；配套 suite 语料 tests/suite/global_seam_test.cr
    python3 tests/selfhost/test_tuple_slots.py
    python3 tests/selfhost/test_agg_read_type.py # TODO #2026-09-16-16「聚合读丢型」批 2（T3 已修）：腿 A 语义值（LET 中转 / match 载荷 / 局部数组元素 / 写回 apx 槽）· 腿 B 界面见证（`_dxt` 反方向 0 · `_dxdiv` 正方向恰好 1 · extern 调用点前须有转换）· 腿 C 钉子（Core 实参 / apx 已转正形）。**元组数字下标 = 裁-AGG-3登记未覆盖**（[GAP] 只观测不计判据）
    python3 tests/selfhost/test_arg_inference_gap.py # #2026-09-16-31 批（实参推断缺失）：**腿 A**（9 例，原 139 → 精确值）· **腿 B**（`g(nosuchfn(1))` 零诊断 → **error[N06]**，**正据**）· **腿 D**（实参位泛型得**精确键** `idf[P]`，非退化键 `idf[unit]`——TODO #2026-09-16-33 的既有缺陷 = 本批附带修复）· 对照 9 例（含外层模块/方法调用的 **oracle 对照**）。**背景**：门 `checker.cr` 的直调分支曾在「被调已解析为 Core fn」时提前 return ⇒ 实参**从不被推断** ⇒ ① 实参位 `EXPR_FIELD` 被调名未回填 ⇒ 伪名 `import` ⇒ SIGSEGV 139 ② 未定义函数静默通过。修法 = `infer_call_args()` 在**四处**「已解析」return 前统一调用（完备性枚举见计划 §3ter）
    python3 tests/selfhost/test_agg_slots.py      # TODO #2026-09-16-2 姊妹条目：struct/struct 模式/数组字面量槽位（同 F5 契约）
    python3 tests/selfhost/test_agg_checks.py     # TODO #2026-09-11-11 聚合字面量「名/型/同质性」三校验（名字绑定 + TS01-04/TK02 硬错误）
    python3 tests/selfhost/test_apx_conversion.py # apx 形式转换缺口族（2026-09-16 apx 批 T5）：**23 例** = TODO #2026-09-16-17（方法调用实参）/ #2026-09-16-18（第 9 个 binary64 栈参）/ ⑦a（全局运行期初值）+ T2 新增两活点（**模块限定调用 `m.f(x)`** / **指针写 `*p = d`**）+ 聚合四类写点 + 比较点声明面查表（L10）+ 非回归 + **`dex?` 零足迹哨兵**（⚠ 其期望值 15 **不是**期望语义，只是绊线——见套件内刺眼标注与 TODO #2026-09-16-29）+ **两条自证腿**（声明形自证：显式形建 apx 槽/推断形不建 + 解释器拒收反证；C1 双形对拍通用腿）。**判据分工**：本套件是 apx 面载荷判据——ELF canary + `.ccr` 四条对 apx 面**零覆盖**（T3 突变双向实测），详见 `2026-09-16-criteria-strength-audit.md` §0ter；配套 suite 语料 `tests/suite/apx_conversion_test.cr`
    python3 tests/selfhost/test_nested_fn.py      # TODO #2026-09-10-12 嵌套 fn 声明段错误 → 定位诊断回归
    # 2026-09-18 suite 清障批：**suite 语料卫生判据**（`suite` 腿不在 PR 门内 ⇒ 把本批的四处期望搬进门内）——
    # H1 修好的两档正例 build+run rc=0 · H2 两档负例 check rc≠0+P21+**零产物** · H3 正控（断言有辨别力）·
    # H4 run_suite 跳过集合 == 两档负例且模式**全路径锚定** · H5 0 字节档集合钉；**逐档 clean-cache**
    # （理由 = TODO #2026-09-18-9 的暖态重放缺陷 ⇒ 否则结论依赖上一轮缓存状态）。
    python3 tests/selfhost/test_suite_hygiene.py
    python3 tests/selfhost/test_interp_parity.py  # TODO #2026-09-10-7 解释器 callee 内联 ≡ 主循环 ≡ ELF
    python3 tests/selfhost/test_cache_identity.py # TODO #2026-09-10-1 cir 缓存编译器身份（跨重建失效）
    python3 tests/selfhost/test_cir_warm_path.py  # R2 P5 Task 1：.cir 暖态 SIGSEGV 根因修复回归——冷/暖 rc 双 0 + ELF 逐字节同 + .ccr 段级契约（STR 冷≠暖为预存口径）+ 暖态真命中（条目 size/mtime 不变）+ 变体（多串/0 串/大串/多函数）+ 可选面零条目 + **累计装载复现例**（400 条目补零至 3MB ⇒ Σ=1.2GB > 1GB 堆，暖态 rc=0 + 峰值 RSS < 512MB；修复前 rc=139 红态实测）= 19 例（COREC_WARM_SELF=1 另开 2 例自源语料，~3 分钟）
    python3 tests/selfhost/test_cir_cache_narrow.py # 缓存膨胀批（`CIR_CACHE_VER 19→20`，plans/2026-09-17-cir-cache-bloat.md）：段粒度按函数收窄 + 边端点相对 id + 尾部基线见证 trailer——P1 结构性（大累计图语料里 tiny 条目 956B ≤ 4096B；非空转 = 最大条目 ≥10×，实测 60×）/ P2a·P2b 部分 rebuild（单函数编辑 ⇒ 其后条目 **fail-closed 重写** + 图段与冷跑逐段同）/ P2c 命中恢复保真（同源再跑 41/41 真命中 + 图段同冷——钉装载期链重建）/ P4 截断（**16 种长度** ⇒ rc=0 + 图段同冷 + 条目重建）= **5 例**；实测时长 ~3.5 min（含 41 函数夹具多次编译）
    python3 tests/selfhost/test_match_exhaust.py  # R2 P3 Task 3：match 穷尽性（补集空性 + 具体变体反例；TM03 硬门 + TM04 软面）
    python3 tests/selfhost/test_tf01_fallthrough.py # TF01 收口：函数体落空分析（无 break 的 loop 收尾不再误报）+ lits_copy 返回型（真·类型洗白）；正控/负控/端到端 19 例 + R2 P6 Task 4a 增 3（never 调用返回位/传播位 + 死分支端到端）＝ 22 例
    python3 tests/selfhost/test_optional.py       # R2 P3 Task 4：联合/可选（T? = T ∪ null；Some/None 解析 + ? 结构解包 + Option 名退役 + 载荷类型节点列）12 例 + R2 P4 Task 5：解包侧判表示（裁决 5）——B.7「裸值 + Some 臂」双路径 SIGSEGV 闭合 + 表示位运行期分派（写点置位/条件写/两形态改写）+ 返回/形参信道 + `?` 解包装箱值双路径分歧闭合 + 未覆盖面登记 = 34 例 + **容量批 T2（裁-CAP-1 (a) 存储边界规范化）**：聚合面（结构体字段/数组·切片元素/元组元素/枚举载荷/全局槽）写点装箱——A 类 8 写点逐点用例（字段赋值/字面量 · 数组字面量下标/动态下标/字面量元素 · 全局赋值/**初值** · match 结果条件写 · 枚举载荷 · 元组元素）+ 负控 + 原未覆盖面 4 例**重钉**（-11 → 精确值；死亡证据 = 本批能力变更）= 48 例 + **(A) 批 T2（裁-REP-1 (iii) 表示位随存储走）**：取址槽恒装箱——四形态（局部/数组元素/全局/形参）经指针写 × {裸, 装箱, None, 条件写} + `c1/c2/c3` 转正（c3 自证式断言不钉历史数值）+ REP-2 边界探针 + REP-3 登记钉 + 非可选负控 ×2 = 66 例 + **(A) 批 T3（裁-T3-1）**：**推断（无标注）可选数组/切片**的元素写点（修复前 7 形态 139/139）——字面量/切片/继承三来源登记后逐形态正确 + 对照 4（标注动态下标/切片形参/装箱写/只读）+ 切片套切片 + 非可选推断数组负控 = **80 例**
    python3 tests/selfhost/test_generic_constr.py # R2 P3 Task 5：泛型约束（结构/枚举约束保留 + 实例化点 ty_sub 判定 + 反例文本；用户接口面 P3b Task 0 起真判定；F4 形参链；实例键类型项化）
    python3 tests/selfhost/test_iface_satisfies.py # R2 P3b Task 0：iface_satisfies 契约（轴分派/三态/与 check_iface 同源；实例化点 T: I 判定 + 登记面 17 例）
    python3 tests/selfhost/test_xcut_iface.py     # R2 P3b Task 2：横切接口接线（索引兜底门 → 可索引形状 / range 分支 → 序列形状 + 固定性位；行为保持 12 例：三路同证正例 + TK01 软诊断负例 + F2/F11 硬错误钉子）
    python3 tests/selfhost/test_impl_iface.py     # R2 P3b Task 6：impl 契约覆盖集（签名类型项化 + 形状项逐成员判定 + mangling 退役 + 上限钉子；20 例：正向三路/两路同证 + 反向签名五面 + 错误例 + 登记面 + 硬错误）
    python3 tests/selfhost/test_enum_limit.py     # R2 P4 Task 6（TODO #2026-09-12-2）旧态 13 例（16 边界 + 17 定位硬错 P022/P023）→ **容量批 T3 重钉为 15 例**（**本批机械核对同步：实测 18/18**，他批 +3）：字段/变体/载荷**上限解除**（侧表）⇒ 16/17/40/64/70 一律编译+运行值正确（旧 17-拒绝面转正，死亡证据 = 本批能力变更）· 跨记录完整性（宽记录 + 邻记录）· 覆盖位无界（≥63 变体穷尽性正确）· 真错仍拒（TM03 缺臂 / TM04 冗余臂）
    python3 tests/selfhost/test_named_face.py     # R2 P5 Task 3：命名面判定化（身份链：同链 1 / 链异 0 / 域外 -1）行为覆盖集——受 10 例（命名互赋 / 泛型应用两实例化 / 嵌套应用 / 实参含命名 / 容器元组 / 递归 *Node / 形参 T / 别名透明 / 函数边界）+ 拒 8 例（异名同形 / 异实参应用 / 命名 vs 原生 / 命名 vs 应用 / 可选异名 / T 赋 int / 不变槽残留 ×2）；**不依赖影子通道**（影子通道已于 P5 T5 下线 ⇒ 本套件 = 下线后的判定面行为网主力）；18 例
    python3 tests/selfhost/test_named_dedup.py    # R2 P2a Task 3（C-4）：侧表 ↔ res_type_node 管线内断言（`--verify-named-dedup`；**非影子通道**——判据 = 真实流水线上三组一致性，影子期亦无耦合）
    python3 tests/selfhost/test_let_check.py      # R2 P5 Task 6（TODO #2026-09-11-14）：`EXPR_LET` 站点值/注解兼容判定——TA02 定位硬错（值非兼容 + 数组长度档）+ 无产物 + 前端拒绝（不进入 lower/写 .ccr/ELF）+ 全局声明面（check_global_let 同款）+ 批量/丢弃名 + 级联抑制（TI_NEVER 错误标记只发原诊断）+ 正控（无注解/auto/dyn/泛型 T 与 [T;N]/可选注入/无初值）；23 例〔**注释陈旧自纠**：T4a 前实读 = 24（23 为 P5 期旧值，差 1 未同步）〕+ R2 P6 Task 4a 增 5（never 调用声明位 / near-miss 负控 / 强负控调用返回型不符仍拒 / 语句位宽面 / 赋值位登记钉）＝ **29 例**
    python3 tests/selfhost/test_diag_gate.py      # FC 批 T2：fail-closed 闸门（默认阻断 + 豁免登记表 **8 条**——TF01 于批 8 A₂ 撤条）——正控 8（表内 5 个 build 面码仍放行 + scope=check 3 条 check rc=1 不变）+ **TF01 撤条对：根因正控（chan_test check rc=0 无 TF01 + build 干净）+ 负控（真 TF01 ⇒ rc=1 + 零产物，即「撤条 ≠ 放行」）** + 负控 6（语法面 P21 / 类型面 TA02·R02·TM03·TK05 / 安全检查面 TU03：仍阻断 + **零产物**）+ 零产物 3（前端失败无半成品 / corearch 失败删本次 .ccr [stub 仿真] / 旧哨兵原样仍在）＝ **19 例**
    # ─── 批 8 A₂（条目 6）：并发 handle 类型模型对齐 —— **自门内 e2e 判据**（2026-09-18）───
    # **11 例** = 5 档并发语料 × （check 干净且**无 TF01** + build+run rc=0）+ 1 形态自证（`chan_make→string`
    # 赋值 + `chan_send/recv/close(string)`）。
    # ⚠ **为何必须挂这里**：5 档语料在 `tests/suite/`，而 **`suite` 腿不在 PR 门内**（台账「PR 门覆盖域陷阱」条：
    # glob 收编 ≠ 进门）⇒ 本套件把该证据编进 `selfhost-tests`（门内），使其**不悬空**。
    # 根因 = `alloc: () -> string` 模型 vs 3 处 handle 返回型 `-> int`（`chan_make`/`g_new`/`sched_go`）+ 5 处
    # handle 形参；修法 = **(A) 语料/stdlib 向模型对齐**（裁定 (A)；(C) handle 兼容明令禁止）。
    python3 tests/selfhost/test_chan_handle_model.py
    python3 tests/selfhost/test_warm_cache_gate.py # #2026-09-15-5 批 T2+T3：暖缓存两态回归（**CI 暖态最小面**；广度层 = tools/baseline/warm_leg.sh 手工判据）——缓存命中跳过 `ir_gen_func` ⇒ ir_gen 期 `alloc_type` 行不重建（T1 实锤：warm 缺 `TYP_PTR extra=1` ⇒ `provenance_verify.cr:66` TU03 静默失效）。修法 = 生成期对「快照不载的共享面」有副作用 ⇒ 该条目**不可写**（下次必 miss 重放副作用）；判据 ① `as *int` 解引用 load/store **冷/暖同**（都 rc=1 + TU03）② 机制钉：副作用函数 `::main.cir` **无条目** ③ 正控：普通程序条目在 + 二跑真命中（size/mtime 不变）④ TK01 冷/暖同 ⑤ `ccr` 面同判；**同路径重复编译 = 缺陷真触发场景（定路径是本设计的要点）**＝ **10 例**（**本批机械核对同步**：实测 10/10；注释旧值 6）
    python3 tests/selfhost/test_tc02_branch.py    # TC02 收口：`if` 分支相容判定的**发散豁免**（P3 不对称——else 支发散 ⇒ 不报；then 支发散 ⇒ 仍报真信号；谓词 `stmt_diverges`，checker.cr，只服务本判定点）+ 既有 NEVER 豁免（loop{} 收尾）零扰动 + TF01/TA02/TB01 面钉子（TF01 仍报 / 落空豁免不变 / 声明位 TA02 不变 / TB01 真错负控 ×2）+ 端到端 build+run（`test_native_float` 两源同形）＝ **15 例**
    # ─── 判据网加固批（criteria-harden，2026-09-16）：**弱判据改强 + 挂点扩容** ───
    # 审计依据 = docs/superpowers/specs/2026-09-16-criteria-strength-audit.md §4（挂载成本序
    # 低 → 中 → 高）与 §2 表 B（B1-B6 弱判据 → TODO #2026-09-16-22-#2026-09-16-26/#2026-09-16-28）。本批在 #2026-09-16-27 成本序下挂
    # **低/中成本档**（下列四档；各档时长实测见行内注）；`test_mw_task1-6` 属**口径换代**
    # （零 diff 腿的基线须在**改动前**编译器上产 ⇒ CI 参照物结构性不可得）⇒ **本批不挂**，
    # 结论 + 替代口径登记于 tests/harness/ci_hook_allowlist.txt。
    # 注：本批同时把四档的**弱判据改强**：#2026-09-16-22 事件 1-4 全字段模板（test_hit_table）、
    # #2026-09-16-23/#2026-09-16-28 慢路径块体逐指令模板 + 零 diff 腿指令边界锁步（test_mw_task2，#2026-09-16-28 因基线
    # 不可得仍不挂，见 allowlist）、#2026-09-16-24 dump 值域白名单（test_hit_table）、#2026-09-16-25 STR 段冷/暖
    # 前缀契约（test_cir_warm_path，已挂上行）、#2026-09-16-26 剔除面白名单 + 计数（test_ccr_types，已挂上行）。
    python3 tests/selfhost/test_slice_bounds.py   # 低（TODO #2026-09-11-13/#2026-09-16-27 点名档）：F11 切片越界守卫回归钉（越界读/写/变量下标/空切片 trap + 合法访问）；本批实测 1.4s（7/7）
    python3 tests/selfhost/test_hit_table.py      # 中（allowlist:25 + 审计「漏检面最大」同族）：HIT 表模式合成层——v2 walker/夹具拒绝面/事件注入逐字节对照 + **事件 1-4 全字段模板（本批 #2026-09-16-22 改强）** + dump 值域白名单（本批 #2026-09-16-24）；本批实测 2.3s（24/24）
    python3 tests/selfhost/test_region_cfg.py     # 中（allowlist:39）：`.ccr`/`.cir` 区域结构 + **段表/版本断言**（与 test_ccr_v7/ccr_types 同族 ⇒ 格式批的漏检面）；本批实测 0.9s（22/22）
    python3 tests/selfhost/test_live_ranges.py    # 中（allowlist:28）：存在区间 + 条目版本化 + O1/O2 冒烟；本批实测 1.4s（13/13）
    # 高（**allowlist 自标最高危**：唯一拦「清单双注册漂移 ⇒ project-mode `error[N06]`
    # 静默」之门——rc=0 但日志带 error[ 判红；已致 P3a 33×N06 跨 5 任务漏检）。本批
    # 先实测时长 = **22.5s**（stage0→1→2 冒烟 + O2 元数据读回；内含 nice -n 19）⇒ 判定
    # **可挂**（成本远低于审计担心的「构建面」量级）。挂点理由记录：allowlist 原 `:19`。
    python3 tests/selfhost/test_backend_bootstrap.py
    # ─── 判据载体化批（criteria-carrier，2026-09-16）：**ELF canary + `.ccr` 四条 = 机器闸门** ───
    # 缘起（实核）：这两条判据的锁定值——canary `95084e7b…d475`（28822B）与 `.ccr` 四条
    # 96015/96158/142793/142936——此前**只活在 docs/ 与 .superpowers/ 的文字里**，本仓
    # `*.py/*.sh/*.cr/*.toml/*.yml` 命中数为 0（每个批次靠人/代理**手跑**引用）。同类事故本仓
    # 已发生过一次：`test_backend_bootstrap.py` 自称已挂而本文件零命中 ⇒ `error[N06]` 跨 5 任务
    # 33 次静默漏检（见本 job 上方与 tests/harness/test_ci_hook_coverage.py）。本批把它升一层。
    # 载体 = tools/baseline/canary_check.sh（配方 + 锁定值**单一真源** = tools/baseline/
    # canary_values.tsv；fail-closed 四规则：rc≠0 / 值表缩水 / sha 与尺寸逐条比 / 缺工具）。
    # 挂本 job 的理由：闸门需**已构建**编译器（`build` 路径按 main.cr:713-721 用 get_arg(0)
    # 的目录拼 corearch），而本 job 首行即 build_selfhost。成本 = 1 档 canary ELF + 4 次 `.ccr`
    # （2 语料 × 2 口径；语料 240B/2.5KB）⇒ 秒级。**值表换代纪律**见
    # docs/superpowers/plans/2026-09-16-criteria-carrier.md §6（不符 ⇒ 停下上报，勿改值表）。
    bash tools/baseline/canary_check.sh
    # 牙（防「闸门自己也是静默判据」）：A 机械（真挂断言）+ B 合成自证（S1 绿路可达 + S2–S6
    # 五类必红）+ C **真产物篡改必红**（复制载体刚落盘的 build/canary_artifacts/ ⇒ 翻一字节 ⇒
    # `--verify-only` 必须红且指名产物）。载体先跑 ⇒ 本腿**零额外编译**（顺序即契约）。
    # `--require-compiler`：本 job 已构建 ⇒ 缺编译器不得静默跳过真牙腿（fail-closed）。
    python3 tests/harness/test_canary_carrier.py --require-compiler
    # ─── 第 4 批（home-repro，2026-09-17）：`.so` 扩展索引的**可复现性/承重面/内存安全** ───
    # 缘起（TODO #2026-09-16-20）：编译器解析 `import` 时读 `$HOME/.core/lib/<模块>/index` 并把其中的
    # 名字驻留进产物 ⇒ 同一提交同编译器、**换台机器产物就变**（前批判据载体化的 CI 红档即此，
    # `generics_test` ±28B）。本批改「侧表 + 首次引用物化」⇒ 未引用条目零产物足迹。
    # 判据（8 例全绿；**夹具入仓** = 判据自己可复现，两态索引取 tests/fixtures/so_index/）：
    # 两态 `.ccr` 两条口径逐字节同 · 良性索引零足迹 · **承重面**（索引独有名字：有索引 rc=0、
    # 无索引 rc=1 + `error[N06]` 响亮）· **索引行数不再是行为分界**（N=2/200/2000 三档产物同
    # 且进程 rc 正常——TODO #2026-09-17-1 的越界写堆随本批删块消除，**必须留判据证明「已消除」**）·
    # `HOME` unset ≡ 空 HOME（#83）· ELF 跨两态同 · 静态零命中硬编码家目录字面量。
    # 挂本 job 的理由同载体（需已构建编译器）。成本实测 ≈ 12s（含 2000 行大索引档）。
    python3 tests/selfhost/test_so_index_repro.py
    # ─── 批 5（opt-dex，2026-09-17；TODO #2026-09-16-29 = 原 #91）：可选 dex（`dex?`）整族 ───
    # 缘起：四态（裸/装箱 × bits/scaled）与家族面（映射表 9 列）。根因三条（实读）：① 写点门
    # `declared_ti == TI_DEX` 对 `dex?` 不触发 + 槽型「随值」（ir_gen.cr:2525/:2559/:2577-2579）；
    # ② 装箱序倒置 5 处（:1541/:2751/:2788/:2836/:3241 先装箱后规范 ⇒ 漏斗落箱对象 = 空转）；
    # ③ 声明面在 `unpack_type` 塌陷（parser.cr:150-153/1427）⇒ `dex?` 形参槽型 TI_INT + 实参环/返回/
    # 全局门全失效 ⇒ **ABI 失配**（按 XMM 传、按 GP 读）= 垃圾值 + **双路径分歧**（本族最严重形态）。
    # 判据（维护者 2026-09-17 裁决 G10 三条纪律全部写进套件）：① 四态对拍（四格互等 + **锚定格** == 7）；
    # ② **禁第三态**——bits 源的 interp 腿必须是 **255**（= bits→scaled 转换在场时 `IR_I2F/IR_F2I`
    # 的解释器能力边界拒收，255 是**期望值**）；出现第三个值一律判红；③ **不许单腿绿结案**
    # （ELF 绿 ∧ interp 第三态 ⇒ 仍红）。另含：编译期拒绝面（`[dex?;2]` 字面量 ⇒ TK02/TA02 + 零产物）
    # 与 **apx 槽自证腿**（bits 源 `.cir` 必须有 binary64 位模式常量、scaled 源必须没有 ⇒ 防「探针不触发」）。
    # 配套 suite 语料 `tests/suite/opt_dex_test.cr`（常规腿；返回码 1..14 = 首个失败面编号）。
    # 计划 = docs/superpowers/plans/2026-09-17-opt-dex.md · 报告 = 收官批报告。
    python3 tests/selfhost/test_opt_dex.py
    # ─── 批 8 条目 2（静默面收口）：可选值 `==`/`!=` 表示透明（2026-09-17）───
    # **19 例**：判据 ① `Some(x)==Some(x)` 真 · ② `None==None` 真 · ③ `Some(x)==None` 假 ·
    # ④ 同源自比较真（裸/装箱两表示；装箱取 `*p` 形态绕开软诊断 B04，同批 5 体例）·
    # ⑤ 非可选比较逐值钉子（零变化面）。
    # 另有：表示透明三例（裸/装箱/混合同判）· `!=` 两面 · 合成 bool 面 ·
    # **六位位码总钉**（`bit0..bit5` 打包，rc 可读；**修复前 = 24 · 修复后 = 30**，两腿同判）
    # 锚更正留痕（2026-09-18 复核）：本行原文写「修复前 = 8 · 修复后 = 14」= **旧探针形状**读数
    # （bit4 用 `n == 7`、`n = None` ⇒ 0）；`0186427f` 重定 bit4 为 `a == 7`（present 形）+ 补 bit5 后真值 = 24/30
    # （前态二进制实测 24/24；本链 30/30）。
    # · 未覆盖面抽样一例。
    # 判据模型：**以运行退出码为准**（rc 即读数；不依赖 stdout）；两腿同判（ELF 与 interp）。
    # 突变自证（批级留痕；**已接机检**：`tests/harness/test_criteria_mutations.py`）：把新增分派块退回
    # 不触发（= 修复前路径）⇒ 位码回 **24**（两腿；2026-09-18 复核重跑：旧值 8 = 旧探针形状，已更正）。
    # 机理：`==` 通用二元路径逐槽比原始值——裸(rep=0)比载荷 ✓、装箱比指针 ⇒ 恒假；
    # 修复 = 比较点归一 `(absent, payload)` 后按值比（`ir_gen.cr` opt_cmp_* 三函数 + 分派块）。
    python3 tests/selfhost/test_opt_eq.py
    # ─── 批 8 条目 3（静默面收口）：extern 声明含可选（`?`）⇒ 硬错 P24（2026-09-17）───
    # **12 例** = 拒收面 6（`dex?`/`int?` 形参 · `dex?`/`int?` 返回 · 混合形参 · `string?`）+ 非可选对照 4
    # （`dex` / `int` / `never` / `char`——守卫 `test_iface_ops.py` 同形态的编译面）+ 守卫语料 2
    # （`tests/suite/ffi_test.cr` · `tests/probes/p_ffi2.cr` check rc=0）。
    # 判据要件：① 含可选 ⇒ rc=1 + `error[P24]` + 定位 + **零产物**；② 非可选逐字节不变；③ `dex?`/`int?` 同路径。
    # 落点 = parser 的 extern 分支（签名规则位，同 P020 先例；返回类型节点在 parser 内可用）。
    # 突变自证（批级留痕）：撤掉该检查 ⇒ 6 条拒收例回 `check=0`。
    python3 tests/selfhost/test_extern_opt.py
    # ─── 批 8 条目 4（静默面收口）：顶层兜底不再静默吞 token ⇒ P25（2026-09-18）───
    # **12 例** = 拒收 5（顶层多余 `}` / typo 声明 / typo 声明+使用 / 游离 `;` / typo 关键字）+ 合法对照 7
    # （import ×2 / **无初值全局**（= 注入运行时源 `rt.cr:4` 同形）/ 有初值全局 / `mod` / `type` / `@` 注解）。
    # 判据：拒收 ⇒ check rc=1 + `error[P25]` + 定位 + build rc=1 + **零产物**；合法 ⇒ check/build/run 三面 0；
    # **不挂起**（P6：报错路径仍消费 token；套件内每例限时 60s、超时即红——CI 超时不是红）。
    # ⚠ 同批前置修（本轮实测暴露）：`parse_all` 原只吞 `import` 关键字本身，路径/别名 token 一直靠兜底
    # 静默吞（全语料普遍）⇒ 新硬错会误伤**每一条合法 import**（实测 `import io` 的 `io` 与注入源
    # `import arena_globals`）。修复 = 按 res_imports 形状逐字消费 `[@proj] [a(::b)*] [: alias] [;]`。
    # 全语料对拍（212 档 × `check`；前态二进制 vs 本修复）：差异 **7 档且全部本就 rc=1**（spec 负例 5 ·
    # 探针 1 · 旧 fixture 1；期望码 V02/V03 仍在）⇒ 合法语料零差异。
    # 突变自证（批级留痕）：兜底退回裸 `advance_tok()` ⇒ 拒收 5 例回 `check=0`。
    python3 tests/selfhost/test_toplevel_reject.py
    # ─── 批 8 条目 5（静默面收口）：`apx` 标签**适用性白名单** ⇒ P26（2026-09-18）───
    # **7 例** = 拒收 5（`dex?` · `.` 推断 · `auto` · `string` · `bool`）+ 白名单 2（`dex, apx` 表示路径 ·
    # `int, apx` 既有契约纯注解；两者 `.cir` 各恰一条 `approx` = 机制钉）。
    # 判据：拒收 ⇒ check rc=1 + `error[P26]` + 定位 + build rc=1 + **零产物**；白名单 ⇒ check/build/run 三面 0。
    # 裁定依据（lead 2026-09-18 = (B)）：白名单 = 显式 `dex` + 显式 `int`（**有契约**：`test_apx_tag.py`
    # 钉语法合法/语义不变/`.cir` 携 `approx`，bootstrap 同向 ApproxInstr ⇒ 两前端对齐）；其余（`dex?`/`.`/`auto`/
    # `string`/`bool`…）**零文档 / 零测试 / 值面无路** = 静默谎。⛔ 裁 (A)（连 `int, apx` 一并拒）已否：
    # 那会**改契约**（须重定 test_apx_tag + 登记两前端接受集分歧）——判据原则「有契约 ⇒ 有意设计；无契约 ⇒ 静默谎」。
    # 白名单两形的产物**逐字节不变**（前态二进制 vs 本链实测 IDENTICAL）· 契约套件 `test_apx_tag.py` 2/2 复跑绿。
    # 突变自证（批级留痕）：撤掉该检查 ⇒ 拒收 5 例回 `check=0`。
    python3 tests/selfhost/test_apx_tag_scope.py
    # ─── 批 6（验证内核正式接入 = 正式规约语法 `#check`/`#ensure`；2026-09-17）───
    # 四组 48 项：A 语法面（16）· B 检查面（11）· C `--dump-vcs` 通道（15）· D `.ccr` 零足迹三段式（6，含 Δ 公式）。
    # **Δ 公式 = 本批最有价值的判据**（T3 首轮当场抓到实现自身的 `str_intern("result")` 泄漏：两用例 STR Δ 凭空 +10B），
    # 必须留仓。语料 = `tests/spec/`（33 档，独立目录，**不进**腿①/腿②语料——两腿计数不变 = 旧面零扰动的证据）。
    # 时长实测（2026-09-17 本机）：**1.8s（空载）～ 34.5s（机器 swap 抖动时）**——两者相差近 20×，
    # 根因 = 系统级 I/O 饱和（非本套件），故**以区间记**；即便取上界也不影响 CI 关键路径。
    # （同批实测：`loadavg ≈ 11–16`（4 核）· swap 已用 ≈ 5.8GB 时取上界值。）
    python3 tests/selfhost/test_spec_grammar.py
    # ─── 批 8 PR-B（F3）S1′ report-only 打点：**活性自证 + 默认零足迹**（2026-09-18）───
    # 20 断言 = ① 必命中探针逐字段（活性：`9917 4 14 0 0 2 f`）· ② 默认位/`CORE_S1P=0` 零行 ·
    # ③ 无失配程序零行（负控）· ④ extern 形走 `9918` 单列 + 默认位零行 · ⑥ 护栏②③⑥ 各配对照腿 ·
    # ⚠ 方法调用不可达（实测：`s.m(b)` 异型 0 打点 ⇒ ④ 分支在本点死；钉成判据，扩覆盖时翻 ≥1）·
    # ⑤ 全 `tests/suite/*.cr` 默认位零打点（**冷缓存逐档**）。
    # **为什么必须有这一档**：打点扫面两种假信号——假阳（grep 裸标识符命中源码回显：A 批「6 档 30 点」实为 0）
    # 与假阴（打点没装/没生效，「0 点」被当「真干净」：本档 2026-09-18 **当场抓出真假阴**——
    # `globals.cr` 的 `mut = -1` 初值经 Python bootstrap 构建**静默丢成 0** ⇒ 开关恒关、探针 0 命中）。
    # 判据①（只发不阻断）的产物面在批级对拍：前态二进制 vs 本链 **37/37 逐字节 IDENTICAL**（两侧各自 clean-cache）。
    python3 tests/selfhost/test_s1p_liveness.py
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
