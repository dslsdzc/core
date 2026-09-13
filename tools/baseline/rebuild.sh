#!/usr/bin/env bash
# R2 P6 Task 1（E-13）：冻结基线重建 —— 从 pinned revision 重建三二进制并核 sha 白名单。
#
# 用法: bash tools/baseline/rebuild.sh <outdir>
# 产物: <outdir>/{corec,corearch,corelsp}（**不入库**——维护者裁定「重建，不落二进制」，
#       配方 + 白名单入仓 = tools/baseline/REBUILD.md）
#
# 语义：判定面回归网 ① 的「冻结基线」= 源出 pinned revision 的三二进制。本脚本 = 该腿
#       唯一被许可的产生方式（手抄 /tmp 副本不算）。sha 不符白名单 ⇒ **失败退出**，
#       绝不改白名单对齐（停条件，见计划 Task 1）。
set -euo pipefail

# ── 白名单（来源修订 + 三 sha；换代纪律见 REBUILD.md）──
PINNED_REV="9bcb7083"          # P4 收官（R2 P4 Task 7）
WS_NAME="p6-baseline-build"    # 临时 workspace 名（收工 forget）

WHITELIST_COREC="5d2b15ad746018619b01143cce400e6f3489ae72a962e12283a7afd3dcdb41e7"
WHITELIST_COREARCH="493dc490dfaed7774b46b74ccf1cfeca9fe5f61620e34229afb8991b1628a2a7"
WHITELIST_CORELSP="18b94bd955fa204accf0753095a28f6499871566254d846333a7496c99109d49"

usage() { echo "usage: bash tools/baseline/rebuild.sh <outdir>" >&2; exit 2; }
[ $# -eq 1 ] || usage
OUTDIR="$1"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${COREC_REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
TMPBASE="$(mktemp -d /tmp/p6-baseline.XXXXXX)"
WS_DIR="$TMPBASE/src"

cleanup() {
  ( cd "$REPO_ROOT" && jj workspace forget "$WS_NAME" >/dev/null 2>&1 ) || true
  rm -rf "$TMPBASE"
}
trap cleanup EXIT

echo "[1/4] 检出 pinned revision $PINNED_REV → $WS_DIR"
cd "$REPO_ROOT"
jj workspace add "$WS_DIR" --name "$WS_NAME" --revision "$PINNED_REV"

echo "[2/4] 构建（nice -n 19；日志 $TMPBASE/build.log）"
cd "$WS_DIR"
nice -n 19 python3 build_selfhost_native.py 2>&1 | tee "$TMPBASE/build.log"
# 构建日志面（非硬闸——硬闸 = 下方 sha）：GUARD clean 行计数
echo "[info] build log 'error[ = 0' 行数 = $(grep -c 'error\[ = 0' "$TMPBASE/build.log" || true)"

echo "[3/4] sha256 对白名单"
check_sha() {  # $1 文件名, $2 期望 sha, $3 展示名
  local got
  got="$(sha256sum "$WS_DIR/build/$1" | cut -d' ' -f1)"
  if [ "$got" != "$2" ]; then
    echo "MISMATCH $3" >&2
    echo "  got      = $got" >&2
    echo "  expected = $2" >&2
    echo "  ⇒ 白名单不符 = 停条件；不得改白名单对齐（见 REBUILD.md）。" >&2
    exit 1
  fi
  echo "  OK $3 $got"
}
check_sha corec    "$WHITELIST_COREC"    corec
check_sha corearch "$WHITELIST_COREARCH" corearch
check_sha corelsp  "$WHITELIST_CORELSP"  corelsp

echo "[4/4] 拷贝到 $OUTDIR + 冒烟"
mkdir -p "$OUTDIR"
cp "$WS_DIR/build/corec" "$WS_DIR/build/corearch" "$WS_DIR/build/corelsp" "$OUTDIR/"

set +e
nice -n 19 "$OUTDIR/corec" run 'fn main()->int{return 42;}' >"$TMPBASE/smoke.out" 2>&1
smoke_rc=$?
set -e
if [ "$smoke_rc" -ne 42 ]; then
  echo "SMOKE FAIL rc=$smoke_rc（期望 42；输出见下）" >&2
  cat "$TMPBASE/smoke.out" >&2
  exit 1
fi
echo "  OK smoke rc=42"

echo "DONE 冻结基线 = $OUTDIR（三 sha 与白名单逐条同；源修订 $PINNED_REV）"
