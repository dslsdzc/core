#!/usr/bin/env bash
# R2 P6 Task 1（E-13）：行为探针 runner —— `tests/probes/*.cr` 全集（**29 档**），逐档 clean-cache。
#
# 用法: bash tools/baseline/probes_run.sh <corec二进制> <outdir>
# 产物: <outdir>/<path转下划线>.log · <outdir>/rc.txt · <outdir>/probes.out
#
# 与迁移期 runner（`/tmp/p5t4/run_probes.sh`）的两处**纠正**（R2 P6 T0 §3.2）：
#   ① 语料由 `/tmp` 三目录改为**入仓**路径 `tests/probes/`（29 档；源 = `/tmp/p5t0/probes`(11)
#      + `/tmp/p5t3/probes`(18)，见 `tests/probes/README.md` 的逐档来源表）；
#   ② 显式清单 + `shopt -s nullglob` + 计数断言：原版 `for f in /tmp/p5t3b/probes/*.cr`
#      （零匹配目录）产生**字面 glob 伪条目** `_tmp_p5t3b_probes_*.cr`（rc=1）——两态恒等
#      ⇒ 该条对拍是**空洞证据**，并会把「30 档」写进台账。本 runner 不再有此形态。
#
# 注：`n13/n17/n18` 三档是 T3b 残留面探针（`[NA;2]`/`*NA`/元组含异名）——其**变异态**
#     证据需重造变异二进制，不随语料入仓（见 README「运行条件」节）。
set -u
shopt -s nullglob

usage() { echo "usage: bash tools/baseline/probes_run.sh <corec-binary> <outdir>" >&2; exit 2; }
[ $# -eq 2 ] || usage
CCBIN="$1"; OUT="$2"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${COREC_REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
cd "$REPO_ROOT" || exit 1
mkdir -p "$OUT"
CC="nice -n 19 $CCBIN"

PROBE_TOTAL=29   # = p5t0 11 + p5t3 18（R2 P6 T0 表 C / U-4 正式清点值）

: >| "$OUT/rc.txt"
: >| "$OUT/corpus.tsv"
{
  for f in tests/probes/*.cr; do
    tag=$(echo "$f" | tr '/' '_')
    $CC clean-cache >/dev/null 2>&1
    $CC check "$f" >| "$OUT/${tag}.log" 2>&1
    rc=$?
    printf '%s\trc=%s\n' "$tag" "$rc" >> "$OUT/rc.txt"
    printf 'probe\t%s\n' "$f" >> "$OUT/corpus.tsv"   # 暖态腿清单（单一真源）
    printf '%s\trc=%s\n' "$tag" "$rc"
  done
} >| "$OUT/probes.out"

n=$(wc -l < "$OUT/rc.txt")
if [ "$n" -ne "$PROBE_TOTAL" ]; then
  echo "PROBE COUNT $n != $PROBE_TOTAL —— 探针语料构成已变；须显式更新本文件与 README（硬失败）" >&2
  exit 1
fi
n0=$(grep -c 'rc=0$' "$OUT/rc.txt" || true)
n1=$(grep -c 'rc=1$' "$OUT/rc.txt" || true)
echo "PROBES DONE（$OUT）：$n 档 · rc 分布 $n0×0 / $n1×1"

# #2026-09-15-5 T3 暖态腿（广度层）：同路径二跑 —— rc/诊断码集一致性 + 暖态生效档数（见 warm_leg.sh 头注）。
if [ "${WARM_LEG:-1}" != "0" ]; then
  bash "$SCRIPT_DIR/warm_leg.sh" "$CCBIN" "$OUT/warm" < "$OUT/corpus.tsv" \
    || { echo "WARM LEG FAILED（暖态腿：冷/暖两态分歧）" >&2; exit 1; }
fi
