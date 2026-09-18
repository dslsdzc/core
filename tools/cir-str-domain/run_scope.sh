#!/bin/bash
# 冷/暖对照 runner（串域跨进程 id 缺陷的证据复现 + 判据；见
# docs/superpowers/plans/2026-09-18-cir-cache-str-domain.md）。
#
# 用法：
#   CORE_BIN=./build/corec bash tools/cir-str-domain/run_scope.sh            # 报告矩阵（默认；恒 rc=0）
#   CORE_BIN=./build/corec bash tools/cir-str-domain/run_scope.sh --assert   # 判据模式：凡冷≠暖即 rc=1
#
# 纪律：每档**独立目录、先冷后暖**（同一二进制、同一源、不 clean）；
#       暖态读数的可信度依赖缓存状态，正是本缺陷的由来。
# 基线既有红：`known-baseline-red.txt` 列出的档在判据模式下**只上报不判红**
#       （其红先于本修复存在；证据与触发器见该文件头注）。
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
BIN="${CORE_BIN:-$REPO/build/corec}"
WORK="${WORK_DIR:-/tmp/cir-str-domain-run}"
MODE="${1:-report}"
RED_FILE="$HERE/known-baseline-red.txt"

if [ ! -x "$BIN" ]; then echo "缺编译器：$BIN（用 CORE_BIN=... 指定）" >&2; exit 2; fi
rm -rf "$WORK"; mkdir -p "$WORK"

printf '%-14s %-10s %-10s %s\n' PROBE BUILD_RC RUN_RC VERDICT
fail=0
for probe in "$HERE"/probes/scope_*.cr; do
    name="$(basename "$probe" .cr)"; name="${name#scope_}"
    d="$WORK/$name"; mkdir -p "$d/probes"
    ln -sfn "$REPO/src" "$d/src"
    cp "$probe" "$d/probes/probe.cr"
    ( cd "$d" || exit 9
      nice -n 19 "$BIN" build probes/probe.cr -o out_cold --static > cold_build.txt 2>&1; crc=$?
      ./out_cold > cold_run.txt 2>&1; crrc=$?
      nice -n 19 "$BIN" build probes/probe.cr -o out_warm --static > warm_build.txt 2>&1; wrc=$?
      ./out_warm > warm_run.txt 2>&1; wrrc=$?
      if cmp -s cold_run.txt warm_run.txt && cmp -s out_cold out_warm; then verdict=SAME; else verdict=DIFF; fi
      printf '%-14s %-10s %-10s %s\n' "$name" "$crc/$wrc" "$crrc/$wrrc" "$verdict"
      if [ "$verdict" = "DIFF" ]; then
          if [ -f "$RED_FILE" ] && grep -q "^$name|" "$RED_FILE"; then
              echo "    [基线既有红·非本缺陷面] $(grep -m1 "^$name|" "$RED_FILE" | cut -d'|' -f2-)"
              exit 0
          fi
          echo "    cold: $(tr '\n' '|' < cold_run.txt)"
          echo "    warm: $(tr '\n' '|' < warm_run.txt)"
          exit 1
      fi
      exit 0 )
    if [ $? -ne 0 ]; then fail=1; fi
done

if [ "$MODE" = "--assert" ]; then
    # 判据模式 = 修复后行为（冷=暖）。缺陷未修时必然 rc=1——这是**判据**，不是脚本故障。
    if [ "$fail" != "0" ]; then echo "ASSERT 失败：存在冷/暖分歧档（缺陷未修时为预期红）"; exit 1; fi
    echo "ASSERT 通过：全部档冷/暖一致"; exit 0
fi
echo "（report-only：分歧档见上；判据模式加 --assert）"
exit 0
