#!/usr/bin/env bash
# #60 批 T3：**暖态腿** runner —— 「同一路径二跑」两态一致性 + 暖态生效档数（命中实证）。
#
# 背景（T1 实锤，`/tmp/fct4/task1-report.md`）：`.cir` 缓存命中会跳过 `ir_gen_func` 的全部
# 生成期副作用；缺口（类型行不随快照）曾使安全检查诊断**暖态静默消失**（冷 rc=1 TU03 →
# 暖 rc=0 + 照常出 ELF）。既有 runner 逐档 `clean-cache` ⇒ 判据面对暖态**结构性零覆盖**；
# 且**既有语料不含 TU03 形态**（全仓 `as *T` 零命中）⇒ 只把二跑加进 72/29 档会**恒绿而空洞**。
# 故本腿分两层（见 `--with-corpus`）：
#   · 广度层（默认）：父 runner 传进来的清单（`<tag>\t<file>` 行）逐档二跑 —— 抓**广谱**
#     暖态回归（任一类码在暖态变脸都红）；对 pre-fix 冻结基线**预期绿**（T1 E4：码集零差异）。
#   · 牙齿层（`--with-corpus`）：入仓语料 `tests/probes/warm/*.cr`（**定路径**是该语料的设计
#     要点）—— 缺陷面（TU03）与旁面（TK01）**期望值逐档断言**；pre-fix 二进制在本层**必红**
#     （这就是「腿有牙」的判据，见 warm-task3-report.md 突变 M1）。
#
# 用法:
#   printf '%s\t%s\n' tag file | bash tools/baseline/warm_leg.sh <corec二进制> <outdir> [--with-corpus]
#   bash tools/baseline/warm_run.sh <corec二进制> <outdir>          # 牙齿层专用入口（等价 --with-corpus 空清单）
#
# 判据（任一不满足 ⇒ 记 FAIL；全部跑完后 rc=1）:
#   ① 冷/暖 **rc 一致**；② 冷/暖 **诊断码集一致**（`error[XX]` 去重排序）；
#   ③ 牙齿层：期望值逐档命中（`tu03_*` ⇒ rc=1 且含 TU03；`tk01_*` ⇒ rc=1 且含 TK01；正控 ⇒ rc=0）。
# 产物: <outdir>/<tag>_<base>.{cold.log,warm.log} · <outdir>/stats.tsv · <outdir>/warm.out
# 暖态生效档数 = 冷跑后有条目、且暖跑后**至少 1 条条目 size/mtime 未变**（= 真命中）的档数。
#   `%y` 取到纳秒：同秒重写不会被误判为命中。
set -u
shopt -s nullglob

usage() { echo "usage: bash tools/baseline/warm_leg.sh <corec-binary> <outdir> [--with-corpus]" >&2; exit 2; }
[ $# -ge 2 ] || usage
CCBIN="$1"; OUT="$2"; WITH_CORPUS=0
[ "${3:-}" = "--with-corpus" ] && WITH_CORPUS=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${COREC_REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
cd "$REPO_ROOT" || exit 1
CACHE=".core/cache/cir"
CC="nice -n 19 $CCBIN"
WARM_TOTAL=7   # tests/probes/warm/*.cr 档数（**只增不减**；语料变化须显式更新本计数）

mkdir -p "$OUT"
TMPD="$(mktemp -d /tmp/warm_leg.XXXXXX)"
trap 'rm -rf "$TMPD"' EXIT

snap() { # $1 = 本档源路径的 munged 前缀（缓存键 = 源路径::函数名）；条目指纹排序后可比
  local pref; pref=$(echo "$1" | tr '/' '_')
  for e in "$CACHE"/"$pref"::*.cir; do [ -e "$e" ] || continue; stat -c '%n %s %y' "$e"; done | sort
}
codes_of() { grep -o 'error\[[A-Z0-9]*\]' "$1" 2>/dev/null | sort -u | tr '\n' ' '; }

run_one() { # $1 tag, $2 file, $3 expect("" | "<rc>:<CODE>")
  local tag="$1" f="$2" expect="${3:-}" base
  base=$(echo "$f" | tr '/' '_')
  $CC clean-cache >/dev/null 2>&1
  $CC ccr "$f" -o "$TMPD/o1.ccr" > "$OUT/${tag}_${base}.cold.log" 2>&1; local rc1=$?
  snap "$f" > "$OUT/.snap1"   # 冷跑**后**取快照（冷跑写条目；**只认本档前缀**）
  local n1 hits
  n1=$(wc -l < "$OUT/.snap1")
  $CC ccr "$f" -o "$TMPD/o2.ccr" > "$OUT/${tag}_${base}.warm.log" 2>&1; local rc2=$?
  snap "$f" > "$OUT/.snap2"   # 暖跑后：size/mtime 未变者 = 真命中（唯一 temp 路径会在此现形）
  hits=$(comm -12 "$OUT/.snap1" "$OUT/.snap2" | wc -l)
  local c1 c2 verdict="ok" note=""
  c1=$(codes_of "$OUT/${tag}_${base}.cold.log"); c2=$(codes_of "$OUT/${tag}_${base}.warm.log")
  if [ "$rc1" != "$rc2" ]; then verdict=FAIL; note="rc 冷=$rc1 暖=$rc2"; fi
  if [ "$c1" != "$c2" ]; then verdict=FAIL; note="$note 码集 冷=[$c1] 暖=[$c2]"; fi
  if [ -n "$expect" ]; then
    local er="${expect%%:*}" ec="${expect##*:}"
    if [ "$rc1" != "$er" ]; then verdict=FAIL; note="$note 期望冷 rc=$er 实=$rc1"; fi
    if [ -n "$ec" ] && [ "${c1// /}" != "error[$ec]" ]; then
      verdict=FAIL; note="$note 期望冷码=$ec 实=[$c1]"
    fi
  fi
  [ "$verdict" != ok ] && nfail=$((nfail + 1))
  [ "$hits" -gt 0 ] && nhit=$((nhit + 1))
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$tag" "$f" "$rc1" "$rc2" "[${c1% }]" "[${c2% }]" "$n1" "$hits" "$verdict${note:+ ($note)}" >> "$OUT/stats.tsv"
  printf '%-8s %-42s 冷 rc=%s 暖 rc=%s 条目=%s 命中=%s %s%s\n' \
    "$tag" "$f" "$rc1" "$rc2" "$n1" "$hits" "$verdict" "${note:+ ($note)}"
}

: > "$OUT/stats.tsv"
nfail=0; nhit=0; ntot=0
{
  echo "=== 广度层（父 runner 清单）==="
  while IFS=$'\t' read -r tag f; do
    [ -n "${f:-}" ] || continue
    ntot=$((ntot + 1)); run_one "$tag" "$f"
  done
  if [ "$WITH_CORPUS" = 1 ]; then
    echo "=== 牙齿层（入仓语料 tests/probes/warm/，**期望值逐档断言**）==="
    nc=0
    for f in tests/probes/warm/*.cr; do
      nc=$((nc + 1)); ntot=$((ntot + 1))
      base=$(basename "$f" .cr)
      case "$base" in
        tu03_load|tu03_store) run_one warm "$f" "1:TU03" ;;
        tk01_*)               run_one warm "$f" "1:TK01" ;;
        plain|alloc_witness)  run_one warm "$f" "0:" ;;
        *)                    run_one warm "$f" "" ;;
      esac
    done
    if [ "$nc" -ne "$WARM_TOTAL" ]; then
      echo "WARM CORPUS COUNT $nc != $WARM_TOTAL —— 语料构成已变；须显式更新本文件与 tests/probes/warm/README.md（硬失败）" >&2
      nfail=$((nfail + 1))
    fi
  fi
} >| "$OUT/warm.out"
rm -f "$OUT/.snap1" "$OUT/.snap2"

cat "$OUT/warm.out"
echo "WARM LEG DONE（$OUT）：$ntot 档 · **暖态生效（≥1 真命中）档数 = $nhit** · FAIL=$nfail"
[ "$nfail" -eq 0 ] || exit 1
