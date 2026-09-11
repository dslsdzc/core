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
    python3 tests/selfhost/test_compile.py
    python3 tests/selfhost/test_purity.py          # 效应/纯度批判据（真纯度 13 例 + 链语义 4 例的自测通道驱动）
    python3 tests/selfhost/test_ccr_v7.py          # 效应/纯度批 Task 3：.ccr 层三条边集语义断言（取代「与旧版逐字节同」）
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
