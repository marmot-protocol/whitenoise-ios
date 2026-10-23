#!/bin/bash
# Benchmark-only: sample memory every 5 s until killed.
# Columns: epoch, test-host RSS (MB), swap used (MB), free memory (MB), memory_pressure free %.
out=${1:-build/audit/memory.csv}
mkdir -p "$(dirname "$out")"
echo "epoch,host_rss_mb,swap_used_mb,free_mb,free_pct" > "$out"
page=$(sysctl -n hw.pagesize)
while true; do
  rss=$(ps -axo rss=,comm= | awk '$2 ~ /whitenoise-ios(\.app\/whitenoise-ios)?$/ {s += $1} END {printf "%.0f", s / 1024}')
  swap=$(sysctl -n vm.swapusage | sed -E 's/.*used = ([0-9.]+)M.*/\1/')
  free=$(vm_stat | awk -v p="$page" '/Pages free/ {gsub("\\.", "", $3); printf "%.0f", $3 * p / 1048576}')
  pct=$(memory_pressure -Q 2>/dev/null | awk -F': ' '/free percentage/ {gsub("%", "", $2); print $2}')
  echo "$(date +%s),${rss:-0},${swap:-0},${free:-0},${pct:-}" >> "$out"
  sleep 5
done
