#!/usr/bin/env bash
# R2 P6 Task 1（E-13）：语料同源对拍 runner —— 72 档 × `check`，逐档 clean-cache。
#
# 用法: bash tools/baseline/parity_run.sh <corec二进制> <outdir>
# 产物: <outdir>/logs/<tag>_<path>.{log,rc}（与迁移期 runner 同名同格式）+ <outdir>/parity.out
#
# 与迁移期 runner（`/tmp/p3t0_run.sh`，sha 12dc571f…）的关系：
#   · 语料分层 / 命名 / 逐档 clean-cache 逐字继承（可 `diff -rq` 互证）；
#   · **影子模式整体剥除**——`--type-shadow` / `--type-shadow-dump` 两旗标已随 R2 P5 Task 5
#     删除，原 `shadow` 分支为死码（不移植）；
#   · `shopt -s nullglob` + 计数断言 72：未匹配 glob 不再产生**字面 glob 伪条目**
#     （R2 P6 T0 §3.2 的 `_tmp_p5t3b_probes_*.cr` 教训）；语料数变化 ⇒ 硬失败（须显式改本文件）。
#
# 判定用法（同源对拍）：同一二进制跑本 runner 与在位的 `/tmp/p3t0_run.sh check`，
# `diff -rq <outdir>/logs <ref>/logs` 与两者 stdout 的 rc 列须为空。**基线二进制**由
# `tools/baseline/rebuild.sh` 产生（配方 = REBUILD.md）。
set -u
shopt -s nullglob

usage() { echo "usage: bash tools/baseline/parity_run.sh <corec-binary> <outdir>" >&2; exit 2; }
[ $# -eq 2 ] || usage
CCBIN="$1"; OUT="$2"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${COREC_REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
cd "$REPO_ROOT" || exit 1
mkdir -p "$OUT/logs"
CC="nice -n 19 $CCBIN"

CORPUS_TOTAL=72   # = t1 32 + t2 2 + t3 15 + t4 19 + t5 4（R2 P6 T0 表 C 实核）

run_one() {   # $1 tier tag, $2 file
  local tag="$1" f="$2" base
  base=$(echo "$f" | tr '/' '_')
  $CC clean-cache >/dev/null 2>&1
  $CC check "$f" >| "$OUT/logs/${tag}_${base}.log" 2>&1
  local rc=$?
  echo "$rc" >| "$OUT/logs/${tag}_${base}.rc"
  printf '%s\t%s\n' "$tag" "$f" >> "$OUT/corpus.tsv"   # 暖态腿清单（单一真源）
  printf '%s\t%s\trc=%s\n' "$tag" "$f" "$rc"
}

: >| "$OUT/corpus.tsv"
{
  echo "=== Tier 1: tests/suite/*.cr ==="
  for f in tests/suite/*.cr; do run_one t1 "$f"; done

  echo "=== Tier 2: compiler self ==="
  run_one t2 src/compiler/main.cr
  run_one t2 src/compiler/_import.cr

  echo "=== Tier 3: backend/kernel units ==="
  run_one t3 src/compiler/ccr_io.cr
  for f in src/format/elf/*.cr src/os/linux/*.cr src/arch/x86_64/*.cr src/lattice/*.cr src/targets/x86_64-linux/*.cr; do
    run_one t3 "$f"
  done

  echo "=== Tier 4: stdlib ==="
  for f in src/stdlib/*.cr; do run_one t4 "$f"; done

  echo "=== Tier 5: examples/*.cr ==="
  for f in examples/*.cr; do run_one t5 "$f"; done
} >| "$OUT/parity.out"

n_rc=0; n0=0; n1=0
for r in "$OUT"/logs/*.rc; do
  n_rc=$((n_rc + 1))
  if [ "$(cat "$r")" = 0 ]; then n0=$((n0 + 1)); else n1=$((n1 + 1)); fi
done
if [ "$n_rc" -ne "$CORPUS_TOTAL" ]; then
  echo "CORPUS COUNT $n_rc != $CORPUS_TOTAL —— 语料构成已变；须显式更新本 runner 的分层清单与计数（硬失败，不得静默）" >&2
  exit 1
fi
echo "PARITY DONE（$OUT）：$n_rc 档 · rc 分布 $n0×0 / $n1×1"

# #60 T3 暖态腿（广度层）：同路径二跑 —— rc/诊断码集一致性 + 暖态生效档数。
# 本层对 pre-fix 冻结基线**预期绿**（既有语料不含 TU03 形态，T1 E4）；缺陷面的「牙齿」在
# `tools/baseline/warm_run.sh`（入仓语料 tests/probes/warm/）。`WARM_LEG=0` 关闭。
if [ "${WARM_LEG:-1}" != "0" ]; then
  bash "$SCRIPT_DIR/warm_leg.sh" "$CCBIN" "$OUT/warm" < "$OUT/corpus.tsv" \
    || { echo "WARM LEG FAILED（暖态腿：冷/暖两态分歧）" >&2; exit 1; }
fi
