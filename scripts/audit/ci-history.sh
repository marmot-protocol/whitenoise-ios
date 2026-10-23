#!/usr/bin/env bash
# Per-suite CI failure history from recent GitHub Actions runs of tests.yml.
#
# Lists the last N runs (default 200), fetches the failed-step log of every
# failed run, and counts which Swift Testing suites / XCTest cases failed,
# with the run ids they failed in. Writes:
#   build/audit/ci-history.csv   suite, failures, runs (semicolon-separated ids)
#   build/audit/ci-runs.csv      run id, conclusion, event, branch, created, minutes
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
    w.writerow(["run_id", "conclusion", "event", "branch", "created", "minutes"])
    for r in runs:
        c = datetime.fromisoformat(r["createdAt"].replace("Z", "+00:00"))
        u = datetime.fromisoformat(r["updatedAt"].replace("Z", "+00:00"))
        w.writerow([r["databaseId"], r["conclusion"], r["event"], r["headBranch"], r["createdAt"],
                    round((u - c).total_seconds() / 60, 1)])
failed = [str(r["databaseId"]) for r in runs if r["conclusion"] == "failure"]
open(f"{out}/ci-failed-ids.txt", "w").write("\n".join(failed) + ("\n" if failed else ""))
print(f"{len(runs)} runs, {len(failed)} failed")
EOF

while read -r run_id; do
  [ -n "$run_id" ] || continue
  log="$OUT_DIR/ci-logs/$run_id.log"
  if [ ! -s "$log" ]; then
    gh run view "$run_id" --log-failed > "$log" 2>/dev/null || true
  fi
done < "$OUT_DIR/ci-failed-ids.txt"

python3 - "$OUT_DIR" <<'EOF'
import csv, glob, os, re, sys
from collections import defaultdict
out = sys.argv[1]
suite_re = re.compile(r"Suite (\S+) failed after")
test_re = re.compile(r"Test (\S+?)\(\S*\) failed after|Test (\S+) recorded an issue|failed: caught error|^\s*\S+\s+\S+\s+\S+\s+(test\w+), failed", re.M)
xctest_re = re.compile(r"##\[error\]\s+(test\w+), failed")
failures = defaultdict(set)
for path in glob.glob(f"{out}/ci-logs/*.log"):
    run_id = os.path.basename(path)[:-4]
    text = open(path, encoding="utf-8", errors="replace").read()
    for m in suite_re.finditer(text):
        failures[m.group(1)].add(run_id)
    for m in xctest_re.finditer(text):
        failures["XCTest/" + m.group(1)].add(run_id)
with open(f"{out}/ci-history.csv", "w", newline="") as fh:
    w = csv.writer(fh, lineterminator="\n")
    w.writerow(["suite", "failures", "runs"])
    for suite, ids in sorted(failures.items(), key=lambda kv: -len(kv[1])):
        w.writerow([suite, len(ids), ";".join(sorted(ids))])
print(f"wrote {out}/ci-history.csv ({len(failures)} failing suites/cases)")
for suite, ids in sorted(failures.items(), key=lambda kv: -len(kv[1]))[:20]:
    print(f"  {len(ids):3d}  {suite}")
EOF
