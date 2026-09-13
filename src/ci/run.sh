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
    ;;

  selfhost-tests)
    build_selfhost
    # ─── 判定面回归网（R2 P5 Task 5 起；**影子通道已下线**，不得引用其计数/摘要/站点直方图）───
    # 影子对拍（R2 P1 的迁移期仪器：`--type-shadow` / `[type-shadow]` 摘要 / 差异转储 / 站点直方图）
    # 已随 R2 P5 Task 5 整体删除（对照物 `type_equal_legacy` 在 T4 删除后对拍停摆，全语料
    # `decisions=0`）。判定面回归网 = ① **冻结基线同源对拍**：冻结基线（**由
    # `tools/baseline/rebuild.sh` 从 pinned revision 重建**——配方 + 三 sha 白名单见
    # `tools/baseline/REBUILD.md`；R2 P6 Task 1 起可复现，二进制仍不入库）× 当前源 vs
    # 当前二进制 × 当前源，72 档语料（runner `tools/baseline/parity_run.sh`，逐档 clean-cache）
    # `check` rc + 日志逐档 diff（手工判据，本 job 内不跑——CI 为浅检出且无 jj）；② **行为探针**：
    # 下列套件（test_named_face / test_named_dedup / test_type_engine / test_optional /
    # test_match_exhaust …）+ **入仓探针语料 `tests/probes/`（29 档；runner
    # `tools/baseline/probes_run.sh`；变异态/影子态不可复跑面见该目录 README）**；
    # ③ **突变控制**（改坏派生面 ⇒ 探针/对拍转红）；④ **三态纪律**（引擎 -1 ⇒ ICE04 硬错，
    # 见 main.cr 硬名单）。新批次新增判定面行为**必须**同时给这三类证据之一，不得回退到
    # 「与旧版逐字节同」（TODO #26 口径）。
    python3 tests/selfhost/test_compile.py
    python3 tests/selfhost/test_type_engine.py   # 类型项引擎自测通道（selftest-types **404 例**——P5 Task 3b 后 401 + P5 T4 新增 3（ts_t4_run：ICE04 硬错——桥接缺口 / 引擎未覆盖面 / 决定面零误报）＝ 404，P5 T5 两例重钉（hits 计数断言 → 查询纯度 / 缓存命中同项）不增减；P0/P1/P2a/P2b-T1..T6/P3-T0..T5/P3b-T0..T2/T6/P4-T2/T3/T4/P5-T2/T3/T3b/T4/T5/T6 一路漏挂；T6 不增减）
    python3 tests/selfhost/test_iface_ops.py     # R2 P2b Task 4/5/6：接口查表接线（算术/逻辑/条件三门 + 索引兜底门 + TY→TI 单表合一；正控/负控/登记面/站点域 76 例）
    python3 tests/selfhost/test_purity.py          # 效应/纯度批判据（真纯度 13 例 + 链语义 4 例的自测通道驱动）
    python3 tests/selfhost/test_ccr_v7.py          # 效应/纯度批 Task 3：.ccr 层三条边集语义断言（取代「与旧版逐字节同」）
    python3 tests/selfhost/test_ccr_types.py       # R2 P4 Task 1/2/3/4 + P5 Task 2：段机制（版本 8 + loader 三闸/必备集 + 旧 v7 拒收）8 例 + TYPE 内容面（行表/项 DAG 序列化 + 确定性装填 + corearch 读回对拍 + loader 负分支）10 例 + IFACE 内容面（五小节/条目扩列 16/形状命名化/签名项化/impl 边与方法表/corearch 读回/跨段引用域/确定性）10 例 + DFNode.TK 项槽（逐节点规则 + dex 语料 + NOD 36B/同序 + 冷/暖快照对称 + dump 零产物影响 + .cir 布局未变）6 例 = 34 例 + P5 T2 单槽化 6 例（复合行走辅码 + 互斥不变量 + F1 hotpatch 无面 + 复合行冷/暖对称 + 复合行 NOD 同序 + 快照盘面派生码保真）= 40 例
    python3 tests/selfhost/test_impl.py
    python3 tests/selfhost/test_borrow.py
    python3 tests/selfhost/test_pointer_safety.py
    python3 tests/selfhost/test_params_limit.py   # TODO #8 形参上限/≥18 形参静默误编译回归
    python3 tests/selfhost/test_tuple_slots.py
    python3 tests/selfhost/test_agg_slots.py      # TODO #25 姊妹条目：struct/struct 模式/数组字面量槽位（同 F5 契约）
    python3 tests/selfhost/test_agg_checks.py     # TODO #29 聚合字面量「名/型/同质性」三校验（名字绑定 + TS01-04/TK02 硬错误）
    python3 tests/selfhost/test_nested_fn.py      # TODO #16 嵌套 fn 声明段错误 → 定位诊断回归
    python3 tests/selfhost/test_interp_parity.py  # TODO #11 解释器 callee 内联 ≡ 主循环 ≡ ELF
    python3 tests/selfhost/test_cache_identity.py # TODO #5 cir 缓存编译器身份（跨重建失效）
    python3 tests/selfhost/test_cir_warm_path.py  # R2 P5 Task 1：.cir 暖态 SIGSEGV 根因修复回归——冷/暖 rc 双 0 + ELF 逐字节同 + .ccr 段级契约（STR 冷≠暖为预存口径）+ 暖态真命中（条目 size/mtime 不变）+ 变体（多串/0 串/大串/多函数）+ 可选面零条目 + **累计装载复现例**（400 条目补零至 3MB ⇒ Σ=1.2GB > 1GB 堆，暖态 rc=0 + 峰值 RSS < 512MB；修复前 rc=139 红态实测）= 19 例（COREC_WARM_SELF=1 另开 2 例自源语料，~3 分钟）
    python3 tests/selfhost/test_match_exhaust.py  # R2 P3 Task 3：match 穷尽性（补集空性 + 具体变体反例；TM03 硬门 + TM04 软面）
    python3 tests/selfhost/test_tf01_fallthrough.py # TF01 收口：函数体落空分析（无 break 的 loop 收尾不再误报）+ lits_copy 返回型（真·类型洗白）；正控/负控/端到端 19 例
    python3 tests/selfhost/test_optional.py       # R2 P3 Task 4：联合/可选（T? = T ∪ null；Some/None 解析 + ? 结构解包 + Option 名退役 + 载荷类型节点列）12 例 + R2 P4 Task 5：解包侧判表示（裁决 5）——B.7「裸值 + Some 臂」双路径 SIGSEGV 闭合 + 表示位运行期分派（写点置位/条件写/两形态改写）+ 返回/形参信道 + `?` 解包装箱值双路径分歧闭合 + 未覆盖面（结构体字段裸/装箱 + 全局槽装箱/None）登记 = 34 例
    python3 tests/selfhost/test_generic_constr.py # R2 P3 Task 5：泛型约束（结构/枚举约束保留 + 实例化点 ty_sub 判定 + 反例文本；用户接口面 P3b Task 0 起真判定；F4 形参链；实例键类型项化）
    python3 tests/selfhost/test_iface_satisfies.py # R2 P3b Task 0：iface_satisfies 契约（轴分派/三态/与 check_iface 同源；实例化点 T: I 判定 + 登记面 17 例）
    python3 tests/selfhost/test_xcut_iface.py     # R2 P3b Task 2：横切接口接线（索引兜底门 → 可索引形状 / range 分支 → 序列形状 + 固定性位；行为保持 12 例：三路同证正例 + TK01 软诊断负例 + F2/F11 硬错误钉子）
    python3 tests/selfhost/test_impl_iface.py     # R2 P3b Task 6：impl 契约覆盖集（签名类型项化 + 形状项逐成员判定 + mangling 退役 + 上限钉子；20 例：正向三路/两路同证 + 反向签名五面 + 错误例 + 登记面 + 硬错误）
    python3 tests/selfhost/test_enum_limit.py     # R2 P4 Task 6（TODO #35）：枚举变体/载荷与结构体字段写入侧护栏（MAX_ENUM_VARIANTS/MAX_VARIANT_TYPES/MAX_STRUCT_FIELDS）——定位硬错 P022/P023 + 无产物 + 16 边界三面正控；13 例
    python3 tests/selfhost/test_named_face.py     # R2 P5 Task 3：命名面判定化（身份链：同链 1 / 链异 0 / 域外 -1）行为覆盖集——受 10 例（命名互赋 / 泛型应用两实例化 / 嵌套应用 / 实参含命名 / 容器元组 / 递归 *Node / 形参 T / 别名透明 / 函数边界）+ 拒 8 例（异名同形 / 异实参应用 / 命名 vs 原生 / 命名 vs 应用 / 可选异名 / T 赋 int / 不变槽残留 ×2）；**不依赖影子通道**（影子通道已于 P5 T5 下线 ⇒ 本套件 = 下线后的判定面行为网主力）；18 例
    python3 tests/selfhost/test_named_dedup.py    # R2 P2a Task 3（C-4）：侧表 ↔ res_type_node 管线内断言（`--verify-named-dedup`；**非影子通道**——判据 = 真实流水线上三组一致性，影子期亦无耦合）
    python3 tests/selfhost/test_let_check.py      # R2 P5 Task 6（TODO #32）：`EXPR_LET` 站点值/注解兼容判定——TA02 定位硬错（值非兼容 + 数组长度档）+ 无产物 + 前端拒绝（不进入 lower/写 .ccr/ELF）+ 全局声明面（check_global_let 同款）+ 批量/丢弃名 + 级联抑制（TI_NEVER 错误标记只发原诊断）+ 正控（无注解/auto/dyn/泛型 T 与 [T;N]/可选注入/无初值）；23 例
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
