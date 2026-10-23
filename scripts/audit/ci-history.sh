#!/usr/bin/env bash
# Per-suite CI failure history from recent GitHub Actions runs of tests.yml.
#
# Lists the last N runs (default 200), fetches the failed-step log of every
# failed run, and attributes each to suites with scripts/audit/ci-attribute.py
# (Swift Testing suite lines, XCTest method and crash/restart signatures).
# Writes under build/audit/:
#   ci-runs.csv          run id, conclusion, event, branch, created, elapsed minutes
#                        (createdAt→updatedAt, so queue time is included)
#   ci-history.csv       suite, failures, master_failures, branches, kinds, runs
#   ci-unattributed.csv  failed runs no suite explains, by kind (build failure,
#                        execute failure, other)
# Cancelled runs are listed in ci-runs.csv but their logs are not fetched.
#
# Requires `gh` authenticated for the repository. Usage:
#   scripts/audit/ci-history.sh [LIMIT]
set -euo pipefail

cd "$(dirname "$0")/../.."
LIMIT="${1:-200}"
OUT_DIR="${WN_AUDIT_DIR:-build/audit}"
mkdir -p "$OUT_DIR/ci-logs"

gh run list --workflow=tests.yml --limit "$LIMIT" \
  --json databaseId,conclusion,event,headBranch,createdAt,updatedAt > "$OUT_DIR/ci-runs.json"

python3 - "$OUT_DIR" <<'EOF'
import csv, json, sys
from datetime import datetime
out = sys.argv[1]
runs = json.load(open(f"{out}/ci-runs.json"))
with open(f"{out}/ci-runs.csv", "w", newline="") as fh:
    w = csv.writer(fh, lineterminator="\n")
    w.writerow(["run_id", "conclusion", "event", "branch", "created", "elapsed_min_incl_queue"])
    for r in runs:
        c = datetime.fromisoformat(r["createdAt"].replace("Z", "+00:00"))
        u = datetime.fromisoformat(r["updatedAt"].replace("Z", "+00:00"))
        w.writerow([r["databaseId"], r["conclusion"], r["event"], r["headBranch"], r["createdAt"],
                    round((u - c).total_seconds() / 60, 1)])
failed = [str(r["databaseId"]) for r in runs if r["conclusion"] == "failure"]
open(f"{out}/ci-failed-ids.txt", "w").write("\n".join(failed) + ("\n" if failed else ""))
print(f"{len(runs)} runs, {len(failed)} failed, {sum(1 for r in runs if r['conclusion'] == 'cancelled')} cancelled")
EOF

while read -r run_id; do
  [ -n "$run_id" ] || continue
  log="$OUT_DIR/ci-logs/$run_id.log"
  if [ ! -s "$log" ]; then
    if ! gh run view "$run_id" --log-failed > "$log" 2>/dev/null; then
      echo "ci-history: could not fetch the failed-step log of run $run_id (expired?)" >&2
      rm -f "$log"
    fi
  fi
done < "$OUT_DIR/ci-failed-ids.txt"

python3 scripts/audit/ci-attribute.py --out-dir "$OUT_DIR"
