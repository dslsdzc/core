#!/usr/bin/env bash
# #60 批 T3：入仓暖态语料专用 runner（**牙齿层**）—— 等价 `warm_leg.sh --with-corpus`（空清单）。
#
# 用法: bash tools/baseline/warm_run.sh <corec二进制> <outdir>
# 语料: `tests/probes/warm/*.cr`（7 档；**定路径** = 本语料的设计要点，见其 README）
# 判据: 逐档「同路径二跑」冷/暖 rc + 诊断码集一致 ∧ 期望值命中（tu03 ⇒ rc=1 TU03 · tk01 ⇒
#       rc=1 TK01 · 正控 ⇒ rc=0）；任一 FAIL ⇒ rc=1。
# 注: pre-fix 二进制（本缺陷修复前）在本腿**必红** —— 这正是「腿有牙」的判据（突变 M1）。
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$SCRIPT_DIR/warm_leg.sh" "$1" "$2" --with-corpus < /dev/null
