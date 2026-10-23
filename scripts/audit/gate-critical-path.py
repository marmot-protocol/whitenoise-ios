#!/usr/bin/env python3
"""Summarize a runtime-gate trace written by `GateTrace` in the test host.

Enable the trace with `TEST_RUNNER_WN_TEST_GATE_TRACE=1` on `xcodebuild test`,
then fetch `gate-trace.jsonl` from the host's temporary directory, e.g.

  xcrun simctl get_app_container <udid> dev.ipf.whitenoise.ios.staging data
  find <container>/tmp -name gate-trace.jsonl

Each line is {"test", "requested", "acquired", "released"} (epoch seconds).
Reports: permits observed, total hold time (the floor for the gated critical
path at one permit), total wait time, hold-time distribution, and the longest
holders. Usage: python3 scripts/audit/gate-critical-path.py <gate-trace.jsonl>
"""
import json
import statistics
import sys


def main(path):
    rows = []
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    if not rows:
        print("empty trace")
        return
    holds = [(r["released"] - r["acquired"], r["test"]) for r in rows]
    waits = [r["acquired"] - r["requested"] for r in rows]
    span = max(r["released"] for r in rows) - min(r["requested"] for r in rows)
    # Max concurrency = max overlapping [acquired, released) intervals.
    events = sorted([(r["acquired"], 1) for r in rows] + [(r["released"], -1) for r in rows])
    depth = peak = 0
    for _, delta in events:
        depth += delta
        peak = max(peak, depth)
    total_hold = sum(h for h, _ in holds)
    print(f"gated tests: {len(rows)}  span {span:.1f}s  permits observed: {peak}")
    print(f"total hold {total_hold:.1f}s (critical-path floor at 1 permit)  total wait {sum(waits):.1f}s")
    hs = sorted(h for h, _ in holds)
    print(f"hold median {statistics.median(hs):.2f}s  p90 {hs[int(len(hs) * 0.9) - 1]:.2f}s  max {hs[-1]:.2f}s")
    print("longest holders:")
    for h, name in sorted(holds, reverse=True)[:15]:
        print(f"  {h:7.2f}s  {name}")


if __name__ == "__main__":
    main(sys.argv[1])
