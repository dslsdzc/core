#!/usr/bin/env bash

# Core CI job 分发器——按 $CI_JOB_NAME 执行对应 job 的命令集。
# 本地复现：CI_JOB_NAME=check src/ci/run.sh
# 注意：本地长时间编译请遵守 CLAUDE.md 铁律 6（cpulimit/nice 限速）。
#
# 模板来源：rust-lang/rust src/ci/run.sh（configure/make 部分替换为 Core 构建命令）。

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
      # mini* 语料整体 SKIP（历史遗留：其中 at_test_mini4/6 为**函数体内嵌套 fn 声明**，
      # TODO #16 —— 该构造不属语言面（grammar/core.ebnf：Statement 不含 FunctionDecl），
      # 修复前编译 rc=139 段错误；现由 corec 以 error[P21] 定位诊断拒绝（rc=1），
      # 属**负例**而非可运行正例，故仍不进正例套件；回归见 tests/selfhost/test_nested_fn.py
      # （同族扁平正例 at_test_mini5.cr / at_test.cr 已在套件内）。
      *_mini*.cr) continue ;;
    esac
    if [ ! -s "$f" ]; then
      continue
    fi
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
    # TODO #23：铁律 #2 机械执行钩子的加固判据（BLOCK 19 + ALLOW 11；纯 python，无需编译器）
    python3 tests/harness/test_block_git.py
    # R2 P7 非构建小批（CI 挂点审计 #9）：**挂点覆盖率机械判据**——枚举
    # tests/{selfhost,bootstrap,harness}/*.py 与 run.sh 挂点做差集，未挂项必须逐条登记
    # 白名单（tests/harness/ci_hook_allowlist.txt，带理由；含范围外登记段）；含**内存内
    # 突变自证**（摘掉一个真挂点 ⇒ 必红）。纯 python、毫秒级、无需编译器 ⇒ 挂本 job。
    # 根因：`test_backend_bootstrap.py` 曾「自称已挂」而 run.sh 零命中——该门是唯一能拦
    # 「清单双注册漂移（project-mode error[N06] 静默）」的守卫，已致 P3a 33×N06 跨 5 任务漏检。
    python3 tests/harness/test_ci_hook_coverage.py
    ;;

  selfhost-tests)
    build_selfhost
    # ─── 判定面回归网（R2 P5 Task 5 起；**影子通道已下线**，不得引用其计数/摘要/站点直方图）───
    # 影子对拍（R2 P1 的迁移期仪器：`--type-shadow` / `[type-shadow]` 摘要 / 差异转储 / 站点直方图）
    # 已随 R2 P5 Task 5 整体删除（对照物 `type_equal_legacy` 在 T4 删除后对拍停摆，全语料
    # `decisions=0`）。判定面回归网 = ① **冻结基线同源对拍**：冻结基线（**由
    # `tools/baseline/rebuild.sh` 从 pinned revision 重建**——配方 + 三 sha 白名单见
    # `tools/baseline/REBUILD.md`；R2 P6 Task 1 起可复现，二进制仍不入库）× 当前源 vs
    # 当前二进制 × 当前源，73 档语料（runner `tools/baseline/parity_run.sh`，逐档 clean-cache；2026-09-16 全局 seam 批 +1 = `tests/suite/global_seam_test.cr`）
    # `check` rc + 日志逐档 diff（手工判据，本 job 内不跑——CI 为浅检出且无 jj）；② **行为探针**：
    # 下列套件（test_named_face / test_named_dedup / test_type_engine / test_optional /
    # test_match_exhaust …）+ **入仓探针语料 `tests/probes/`（29 档；runner
    # `tools/baseline/probes_run.sh`；变异态/影子态不可复跑面见该目录 README）**；
    # ③ **突变控制**（改坏派生面 ⇒ 探针/对拍转红）；④ **三态纪律**（引擎 -1 ⇒ ICE04 硬错，
    # 见 main.cr 硬名单）。新批次新增判定面行为**必须**同时给这三类证据之一，不得回退到
    # 「与旧版逐字节同」（TODO #26 口径）。
    python3 tests/selfhost/test_compile.py
    python3 tests/selfhost/test_type_engine.py   # 类型项引擎自测通道（selftest-types **415 例**——P5 收官 404 + R2 P6 Task 2 增 11（`ts_t2_neg_run`：¬ 面同类原子身份判据的邻域覆盖——同身份 / μ 字面 / ⊤ₖ 双向 / 跨枚举同名 / 同枚举异变体 / 令牌字面 / AK_NAMED / 空链与链元素域外 / 参数化面 / REF mut 标记面；三例 `t3.*_over_claim` 为**重钉**（0→1，不增减）；P0..P6 T2 一路漏挂）
    python3 tests/selfhost/test_iface_ops.py     # R2 P2b Task 4/5/6：接口查表接线（算术/逻辑/条件三门 + 索引兜底门 + TY→TI 单表合一；正控/负控/登记面/站点域 76 例 + R2 P6 Task 4a 增 2（方法调用站点 never 透传 + 泛型方法登记钉）＝ 78 例）
    python3 tests/selfhost/test_purity.py          # 效应/纯度批判据（真纯度 13 例 + 链语义 4 例的自测通道驱动）
    python3 tests/selfhost/test_ccr_v7.py          # 效应/纯度批 Task 3：.ccr 层三条边集语义断言（取代「与旧版逐字节同」）
    python3 tests/selfhost/test_ccr_types.py       # R2 P4 Task 1/2/3/4 + P5 Task 2：段机制（版本 8 + loader 三闸/必备集 + 旧 v7 拒收）8 例 + TYPE 内容面（行表/项 DAG 序列化 + 确定性装填 + corearch 读回对拍 + loader 负分支）10 例 + IFACE 内容面（五小节/条目扩列 16/形状命名化/签名项化/impl 边与方法表/corearch 读回/跨段引用域/确定性）10 例 + DFNode.TK 项槽（逐节点规则 + dex 语料 + NOD 36B/同序 + 冷/暖快照对称 + dump 零产物影响 + .cir 布局未变）6 例 = 34 例 + P5 T2 单槽化 6 例（复合行走辅码 + 互斥不变量 + F1 hotpatch 无面 + 复合行冷/暖对称 + 复合行 NOD 同序 + 快照盘面派生码保真）= 40 例 + R2 P6 Task 3 项索引 8 例（版本闸 v8 拒收 / NOD 40B 字段序 / 项索引落盘读回对拍（非退化）/ 两通道面一致 / 辅码面与复合行保真 / 项索引越界与不一致 ⇒ 拒绝 / 段界检 / D18 纯度静态）= 49 例（**+1 他批新增，本批机械核对同步**：实测 49/49）
    python3 tests/selfhost/test_impl.py
    python3 tests/selfhost/test_borrow.py
    python3 tests/selfhost/test_pointer_safety.py
    python3 tests/selfhost/test_params_limit.py   # TODO #8 形参上限/≥18 形参静默误编译回归
    python3 tests/selfhost/test_global_seams.py   # 全局行 operand seam（2026-09-16 批）：B1/B2/B4/B5 全局 vs 局部同形对拍（mut 全局 + 期望值）+ B6(b) 发射字节级（静态无 .so 无运行期腿）+ B7 非回归；配套 suite 语料 tests/suite/global_seam_test.cr
    python3 tests/selfhost/test_tuple_slots.py
    python3 tests/selfhost/test_agg_slots.py      # TODO #25 姊妹条目：struct/struct 模式/数组字面量槽位（同 F5 契约）
    python3 tests/selfhost/test_agg_checks.py     # TODO #29 聚合字面量「名/型/同质性」三校验（名字绑定 + TS01-04/TK02 硬错误）
    python3 tests/selfhost/test_apx_conversion.py # apx 形式转换缺口族（2026-09-16 apx 批 T5）：**23 例** = TODO #80（方法调用实参）/ #81（第 9 个 binary64 栈参）/ ⑦a（全局运行期初值）+ T2 新增两活点（**模块限定调用 `m.f(x)`** / **指针写 `*p = d`**）+ 聚合四类写点 + 比较点声明面查表（L10）+ 非回归 + **`dex?` 零足迹哨兵**（⚠ 其期望值 15 **不是**期望语义，只是绊线——见套件内刺眼标注与 TODO #91）+ **两条自证腿**（声明形自证：显式形建 apx 槽/推断形不建 + 解释器拒收反证；C1 双形对拍通用腿）。**判据分工**：本套件是 apx 面载荷判据——ELF canary + `.ccr` 四条对 apx 面**零覆盖**（T3 突变双向实测），详见 `2026-09-16-criteria-strength-audit.md` §0ter；配套 suite 语料 `tests/suite/apx_conversion_test.cr`
    python3 tests/selfhost/test_nested_fn.py      # TODO #16 嵌套 fn 声明段错误 → 定位诊断回归
    python3 tests/selfhost/test_interp_parity.py  # TODO #11 解释器 callee 内联 ≡ 主循环 ≡ ELF
    python3 tests/selfhost/test_cache_identity.py # TODO #5 cir 缓存编译器身份（跨重建失效）
    python3 tests/selfhost/test_cir_warm_path.py  # R2 P5 Task 1：.cir 暖态 SIGSEGV 根因修复回归——冷/暖 rc 双 0 + ELF 逐字节同 + .ccr 段级契约（STR 冷≠暖为预存口径）+ 暖态真命中（条目 size/mtime 不变）+ 变体（多串/0 串/大串/多函数）+ 可选面零条目 + **累计装载复现例**（400 条目补零至 3MB ⇒ Σ=1.2GB > 1GB 堆，暖态 rc=0 + 峰值 RSS < 512MB；修复前 rc=139 红态实测）= 19 例（COREC_WARM_SELF=1 另开 2 例自源语料，~3 分钟）
    python3 tests/selfhost/test_match_exhaust.py  # R2 P3 Task 3：match 穷尽性（补集空性 + 具体变体反例；TM03 硬门 + TM04 软面）
    python3 tests/selfhost/test_tf01_fallthrough.py # TF01 收口：函数体落空分析（无 break 的 loop 收尾不再误报）+ lits_copy 返回型（真·类型洗白）；正控/负控/端到端 19 例 + R2 P6 Task 4a 增 3（never 调用返回位/传播位 + 死分支端到端）＝ 22 例
    python3 tests/selfhost/test_optional.py       # R2 P3 Task 4：联合/可选（T? = T ∪ null；Some/None 解析 + ? 结构解包 + Option 名退役 + 载荷类型节点列）12 例 + R2 P4 Task 5：解包侧判表示（裁决 5）——B.7「裸值 + Some 臂」双路径 SIGSEGV 闭合 + 表示位运行期分派（写点置位/条件写/两形态改写）+ 返回/形参信道 + `?` 解包装箱值双路径分歧闭合 + 未覆盖面登记 = 34 例 + **容量批 T2（裁-CAP-1 (a) 存储边界规范化）**：聚合面（结构体字段/数组·切片元素/元组元素/枚举载荷/全局槽）写点装箱——A 类 8 写点逐点用例（字段赋值/字面量 · 数组字面量下标/动态下标/字面量元素 · 全局赋值/**初值** · match 结果条件写 · 枚举载荷 · 元组元素）+ 负控 + 原未覆盖面 4 例**重钉**（-11 → 精确值；死亡证据 = 本批能力变更）= 48 例 + **(A) 批 T2（裁-REP-1 (iii) 表示位随存储走）**：取址槽恒装箱——四形态（局部/数组元素/全局/形参）经指针写 × {裸, 装箱, None, 条件写} + `c1/c2/c3` 转正（c3 自证式断言不钉历史数值）+ REP-2 边界探针 + REP-3 登记钉 + 非可选负控 ×2 = 66 例 + **(A) 批 T3（裁-T3-1）**：**推断（无标注）可选数组/切片**的元素写点（修复前 7 形态 139/139）——字面量/切片/继承三来源登记后逐形态正确 + 对照 4（标注动态下标/切片形参/装箱写/只读）+ 切片套切片 + 非可选推断数组负控 = **80 例**
    python3 tests/selfhost/test_generic_constr.py # R2 P3 Task 5：泛型约束（结构/枚举约束保留 + 实例化点 ty_sub 判定 + 反例文本；用户接口面 P3b Task 0 起真判定；F4 形参链；实例键类型项化）
    python3 tests/selfhost/test_iface_satisfies.py # R2 P3b Task 0：iface_satisfies 契约（轴分派/三态/与 check_iface 同源；实例化点 T: I 判定 + 登记面 17 例）
    python3 tests/selfhost/test_xcut_iface.py     # R2 P3b Task 2：横切接口接线（索引兜底门 → 可索引形状 / range 分支 → 序列形状 + 固定性位；行为保持 12 例：三路同证正例 + TK01 软诊断负例 + F2/F11 硬错误钉子）
    python3 tests/selfhost/test_impl_iface.py     # R2 P3b Task 6：impl 契约覆盖集（签名类型项化 + 形状项逐成员判定 + mangling 退役 + 上限钉子；20 例：正向三路/两路同证 + 反向签名五面 + 错误例 + 登记面 + 硬错误）
    python3 tests/selfhost/test_enum_limit.py     # R2 P4 Task 6（TODO #35）旧态 13 例（16 边界 + 17 定位硬错 P022/P023）→ **容量批 T3 重钉为 15 例**（**本批机械核对同步：实测 18/18**，他批 +3）：字段/变体/载荷**上限解除**（侧表）⇒ 16/17/40/64/70 一律编译+运行值正确（旧 17-拒绝面转正，死亡证据 = 本批能力变更）· 跨记录完整性（宽记录 + 邻记录）· 覆盖位无界（≥63 变体穷尽性正确）· 真错仍拒（TM03 缺臂 / TM04 冗余臂）
    python3 tests/selfhost/test_named_face.py     # R2 P5 Task 3：命名面判定化（身份链：同链 1 / 链异 0 / 域外 -1）行为覆盖集——受 10 例（命名互赋 / 泛型应用两实例化 / 嵌套应用 / 实参含命名 / 容器元组 / 递归 *Node / 形参 T / 别名透明 / 函数边界）+ 拒 8 例（异名同形 / 异实参应用 / 命名 vs 原生 / 命名 vs 应用 / 可选异名 / T 赋 int / 不变槽残留 ×2）；**不依赖影子通道**（影子通道已于 P5 T5 下线 ⇒ 本套件 = 下线后的判定面行为网主力）；18 例
    python3 tests/selfhost/test_named_dedup.py    # R2 P2a Task 3（C-4）：侧表 ↔ res_type_node 管线内断言（`--verify-named-dedup`；**非影子通道**——判据 = 真实流水线上三组一致性，影子期亦无耦合）
    python3 tests/selfhost/test_let_check.py      # R2 P5 Task 6（TODO #32）：`EXPR_LET` 站点值/注解兼容判定——TA02 定位硬错（值非兼容 + 数组长度档）+ 无产物 + 前端拒绝（不进入 lower/写 .ccr/ELF）+ 全局声明面（check_global_let 同款）+ 批量/丢弃名 + 级联抑制（TI_NEVER 错误标记只发原诊断）+ 正控（无注解/auto/dyn/泛型 T 与 [T;N]/可选注入/无初值）；23 例〔**注释陈旧自纠**：T4a 前实读 = 24（23 为 P5 期旧值，差 1 未同步）〕+ R2 P6 Task 4a 增 5（never 调用声明位 / near-miss 负控 / 强负控调用返回型不符仍拒 / 语句位宽面 / 赋值位登记钉）＝ **29 例**
    python3 tests/selfhost/test_diag_gate.py      # FC 批 T2：fail-closed 闸门（默认阻断 + 豁免登记表 9 条）——正控 9（表内 6 个 build 面码仍放行 + scope=check 3 条 check rc=1 不变）+ 负控 6（语法面 P21 / 类型面 TA02·R02·TM03·TK05 / 安全检查面 TU03：仍阻断 + **零产物**）+ 零产物 3（前端失败无半成品 / corearch 失败删本次 .ccr [stub 仿真] / 旧哨兵原样仍在）＝ **17 例**
    python3 tests/selfhost/test_warm_cache_gate.py # #60 批 T2+T3：暖缓存两态回归（**CI 暖态最小面**；广度层 = tools/baseline/warm_leg.sh 手工判据）——缓存命中跳过 `ir_gen_func` ⇒ ir_gen 期 `alloc_type` 行不重建（T1 实锤：warm 缺 `TYP_PTR extra=1` ⇒ `provenance_verify.cr:66` TU03 静默失效）。修法 = 生成期对「快照不载的共享面」有副作用 ⇒ 该条目**不可写**（下次必 miss 重放副作用）；判据 ① `as *int` 解引用 load/store **冷/暖同**（都 rc=1 + TU03）② 机制钉：副作用函数 `::main.cir` **无条目** ③ 正控：普通程序条目在 + 二跑真命中（size/mtime 不变）④ TK01 冷/暖同 ⑤ `ccr` 面同判；**同路径重复编译 = 缺陷真触发场景（定路径是本设计的要点）**＝ **10 例**（**本批机械核对同步**：实测 10/10；注释旧值 6）
    python3 tests/selfhost/test_tc02_branch.py    # TC02 收口：`if` 分支相容判定的**发散豁免**（P3 不对称——else 支发散 ⇒ 不报；then 支发散 ⇒ 仍报真信号；谓词 `stmt_diverges`，checker.cr，只服务本判定点）+ 既有 NEVER 豁免（loop{} 收尾）零扰动 + TF01/TA02/TB01 面钉子（TF01 仍报 / 落空豁免不变 / 声明位 TA02 不变 / TB01 真错负控 ×2）+ 端到端 build+run（`test_native_float` 两源同形）＝ **15 例**
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
