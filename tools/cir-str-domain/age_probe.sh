#!/bin/bash
# 年龄判定：同一探针对**历史二进制**跑冷/暖对照，并读回该二进制**自写的** CIR_CACHE_VER
# （用于回答「缺陷是哪一代引入的」——实测结论见计划 §1 F7：VER 17/18/19/20 全复现）。
#
# 用法： bash tools/cir-str-domain/age_probe.sh <bin_dir> [tag]
#        <bin_dir> 需含 corec + corearch（同目录）。
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
BINDIR="${1:?用法: age_probe.sh <含 corec/corearch 的目录> [tag]}"
TAG="${2:-$(basename "$BINDIR")}"
WORK="${WORK_DIR:-/tmp/cir-str-domain-age}/$TAG"
rm -rf "$WORK"; mkdir -p "$WORK/probes"
ln -sfn "$REPO/src" "$WORK/src"
cp "$HERE/probes/scope_fields.cr" "$WORK/probes/probe.cr"
cd "$WORK" || exit 9
cp "$BINDIR/corec" ./corec; cp "$BINDIR/corearch" ./corearch; chmod +x ./corec ./corearch
nice -n 19 ./corec build probes/probe.cr -o out_cold --static > cold_build.txt 2>&1; crc=$?
[ -f out_cold ] && { ./out_cold > cold_run.txt 2>&1; crrc=$?; } || crrc=-
nice -n 19 ./corec build probes/probe.cr -o out_warm --static > warm_build.txt 2>&1; wrc=$?
[ -f out_warm ] && { ./out_warm > warm_run.txt 2>&1; wrrc=$?; } || wrrc=-
if [ -f cold_run.txt ] && [ -f warm_run.txt ] && cmp -s cold_run.txt warm_run.txt; then same=OUT_SAME; else same=OUT_DIFF; fi
ver=$(python3 - "$WORK" <<'PY'
import glob, struct, sys, os
fs = sorted(glob.glob(os.path.join(sys.argv[1], '.core/cache/cir/*.cir')))
print("NO_CACHE" if not fs else "VER=%d" % struct.unpack_from('<q', open(fs[0],'rb').read(16), 8)[0])
PY
)
echo "== $TAG ($(date -r "$BINDIR/corec" '+%m-%d %H:%M') sha=$(sha256sum "$BINDIR/corec" | cut -c1-16) $ver)"
echo "   build_rc=$crc/$wrc run_rc=$crrc/$wrrc $same"
echo "   cold: $(head -c 200 cold_run.txt 2>/dev/null | tr '\n' '|')"
echo "   warm: $(head -c 200 warm_run.txt 2>/dev/null | tr '\n' '|')"
[ "$crc" != "0" ] && echo "   cold_build_tail: $(tail -2 cold_build.txt | tr '\n' '|')"
[ "$wrc" != "0" ] && echo "   warm_build_tail: $(tail -2 warm_build.txt | tr '\n' '|')"
exit 0
