#!/usr/bin/env bash
# R2 P6 Task 1（E-13）：冻结基线重建 —— 从 pinned revision 重建三二进制并核 sha 白名单。
#
# 用法: bash tools/baseline/rebuild.sh <outdir>
# 产物: <outdir>/{corec,corearch,corelsp}（**不入库**——维护者裁定「重建，不落二进制」，
#       配方 + 白名单入仓 = tools/baseline/REBUILD.md）
#
# 语义：判定面回归网 ① 的「冻结基线」= 源出 pinned revision 的三二进制。本脚本 = 该路径
#       唯一被许可的产生方式（手抄 /tmp 副本不算）。sha 不符白名单 ⇒ **失败退出**，
#       绝不改白名单对齐（停条件，见计划 Task 1）。
set -euo pipefail

# ── 白名单（来源修订 + 三 sha；换代纪律见 REBUILD.md）──
# 换代（2026-09-14，容量阶段 CAP Task 1）：PINNED_REV 9bcb7083（P4 收官）→ 97f4394f（P6 终态 /
# 本次起点）。依据 = `REBUILD.md`「换代纪律」1/2（下一组以本次收官为 pre-侧；旧值留痕）。
# 旧代三 sha（9bcb7083）：corec 5d2b15ad… · corearch 493dc490… · corelsp 18b94bd9…（全值见 REBUILD.md 历史表）。
#
# 换代（2026-10-11，v4 语法迁移 T7）：PINNED_REV 97f4394f → **25e70197**（v4 迁移 T6 收官 / T7 起点）。
# **依据 = v4 可读性硬约束**（本次与历次换代不同，必须写清）：`97f4394f` 是 **v4 之前**的修订，
# 其 corec **只认 v3 形**；而本脚本第 71 行起的冒烟已改 **v4 形**（T6b）⇒ 换代前该步**必红**（已知窗口态）。
# 新 rev 的唯一硬要求 = **含本次 v4 工作的提交**（能读 v4 形）。取 `25e70197`（= 迁移阶段 T6 收官，
# = 本 T7 的起点）承接「下一组以本次收官为 pre-侧」的既有规则。
# ⚠ **启用条件（换代纪律 3）**：本条生效时其源修订须**在仓内可达**——本次经 develop 合入时**若为
# squash**，`25e70197` 这条 jj 提交不进 develop 历史（仅本地 object store 暂存）⇒ 换人/换机重建会失败。
# 故合入方式若非「保留提交」（merge commit / rebase-merge），须**同阶段把 PINNED_REV 重指到 develop 上
# 含 v4 工作的提交**并同阶段重锁三 sha（**留痕**：本条即旧值出处）。
# 旧代三 sha（97f4394f = v3 末代）：corec `ae01de75…` · corearch `228f82e9…` · corelsp `90eb19c6…`
#   （全值见 `REBUILD.md` 历史表）。
#
# 换代（2026-10-25，v4 迁移 T7 收尾）：PINNED_REV 25e70197 → **7eb9669d**。
# **依据**（v4 计划 T7 的启用条件）：v4 迁移阶段 #183 已以 squash 方式合入 develop，
# `7eb9669d`（`qyntvyq`）在 develop 历史内可达；旧的 `25e70197` 只是本地 jj 提交，
# 不进入 develop 历史，换人或换机重建会失败。新修订可读 v4 形，冒烟步通过。
# 旧代三 sha（25e70197）：corec `701a319f…` · corearch `bd6b1c6a…` · corelsp `2c1da86f…`
#   （全值见 `REBUILD.md` 历史表）。
PINNED_REV="7eb9669d"          # v4 迁移 #183 合入 develop 的提交（首枚 develop 可达的 v4 基线）
WS_NAME="p6-baseline-build"    # 临时 workspace 名（收工 forget）

WHITELIST_COREC="4234b7a6254ad3b7a890268c462dbe3dbd269a991f0deaa12832e154dbe26265"
WHITELIST_COREARCH="3786eb4a8a500158d22a0193b9174c2f4228b5c8d379a4d992ef920b28a9c421"
WHITELIST_CORELSP="845ac0485f2fede878f18bdbacb49e9c24b62ddf4c3180e2b5d411e60467c0eb"

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
# v4 迁移 T6b：内联 Core 冒烟改 v4 形（`:` + layout 缩进 + 换行分隔）。旧形
# `fn main()->int{return 42;}` 在 v4 前端下是 `error[P03]`（`{` 只作结构体字面量定界符）。
# ⚠ 与 `PINNED_REV` 的**换代耦合**：白名单里的三 sha 出自 `97f4394f`（2026-09-14，
# **v4 之前**）⇒ 那枚 corec 只认 v3 形。本行改 v4 后，**必须**由 T7 把 `PINNED_REV`
# 一并换到 v4 可读的修订（计划 §九 J-T7-2/J-T7-3 的重锁对象 #4），否则重建的冒烟步会红。
nice -n 19 "$OUTDIR/corec" run 'fn main() -> int:
    return 42
' >"$TMPBASE/smoke.out" 2>&1
smoke_rc=$?
set -e
if [ "$smoke_rc" -ne 42 ]; then
  echo "SMOKE FAIL rc=$smoke_rc（期望 42；输出见下）" >&2
  cat "$TMPBASE/smoke.out" >&2
  exit 1
fi
echo "  OK smoke rc=42"

echo "DONE 冻结基线 = $OUTDIR（三 sha 与白名单逐条同；源修订 $PINNED_REV）"
