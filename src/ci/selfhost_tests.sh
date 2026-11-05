#!/usr/bin/env bash
# Full selfhost test corpus, one command per line. run.sh decides the shard.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
mapfile -t commands < "$here/selfhost_tests.list"
total="${CI_SHARD_TOTAL:-1}"
index="${CI_SHARD_INDEX:-0}"
if ! [[ "$total" =~ ^[0-9]+$ ]] || ! [[ "$index" =~ ^[0-9]+$ ]] || (( total < 1 )) || (( index < 0 )) || (( index >= total )); then
  echo "invalid shard index/total: $index/$total" >&2
  exit 2
fi
for ((i=0; i<${#commands[@]}; i++)); do
  if (( i % total == index )); then
    echo "[selfhost shard $index/$total] $((i+1))/${#commands[@]}: ${commands[$i]}"
    eval "${commands[$i]}"
  fi
done
