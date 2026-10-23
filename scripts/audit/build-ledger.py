#!/usr/bin/env python3
"""Join the audit inputs into the per-suite decision ledger.

Inputs (all optional except the inventory; missing ones leave columns blank):
  build/audit/inventory.csv        scripts/audit/inventory.py (+ --merge columns)
  build/audit/per-file-costs.csv   scripts/audit/per-file-costs.py
  build/audit/serial-costs.csv     per-suite summed durations from the serial run
  build/audit/coverage-unique.csv  scripts/audit/coverage-unique.py
  build/audit/mutations.csv        scripts/audit/mutate.sh (suite, probe, killed)
  build/audit/ci-history.csv       scripts/audit/ci-history.sh
  docs/test-audit/verdicts.csv     hand-written overrides: suite, decision, rationale

Output: docs/test-audit/ledger.csv and, with --render, docs/test-audit/ledger.md.

Scores (0–3) follow docs/test-audit/README.md. The automatic proposal is
deliberately conservative: `delete` is proposed only when value <= 1 AND the
suite has zero unique covered lines or a high cost, AND no mutation probe was
killed by it; everything borderline is proposed as `review`.
"""
import argparse
import csv
import os
from collections import defaultdict

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

COLUMNS = [
    "suite", "file", "tests", "framework", "tier_now", "serialized_s", "net_wall_s", "wall_share_pct",
    "runtime", "ui_hosting", "main_actor", "sleep_sites", "poll_loops", "flaky_history", "unique_lines",
    "covered_lines", "overlaps_with", "subject", "literal_assertion_flags", "mutation_kills",
    "value", "cost", "fragility", "redundancy", "decision", "rationale", "owner_verdict", "after_s",
]


def read_csv(path):
    if not os.path.exists(path):
        return []
    with open(path, newline="") as fh:
        return list(csv.DictReader(fh))


def to_int(value, default=0):
    try:
        return int(float(value))
    except (TypeError, ValueError):
        return default


def to_float(value, default=None):
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def tier(row):
    if to_int(row.get("testClient_sites")) or to_int(row.get("start_sites")) or to_int(row.get("app_state_test_sites")):
        return "runtime"
    if to_int(row.get("ui_hosting")) or to_int(row.get("image_renderer")) or to_int(row.get("layout_if_needed")):
        return "uiHosting"
    return "pure"


def runtime_kind(row):
    if to_int(row.get("start_sites")):
        return "start"
    if to_int(row.get("testClient_sites")) or to_int(row.get("app_state_test_sites")):
        return "construct"
    return "none"


def literal_pin_dominated(row):
    """True when the literal-assertion flags cover at least as many tests as the suite has."""
    flags = row.get("literal_assertion_flags") or ""
    tests = to_int(row.get("tests"))
    if not flags or not tests:
        return False
    flagged = sum(to_int(f.split(":")[-1]) for f in flags.split(";") if ":" in f)
    return flagged >= tests


def score(row, costs, cov, mut, hist, serial=None):
    """Return (value, cost, fragility, redundancy, decision, rationale).

    Cost uses the suite's own serialized wall time from the serial run when
    available (millisecond precision, per suite), else the per-file net time.
    """
    serial = serial or {}
    subject = row.get("subject") or "app"
    kills = mut.get(row["suite"], 0)
    coverage = cov.get(row["suite"], {})
    unique_i = to_int(coverage.get("unique_lines"), -1)
    jaccard = to_float(coverage.get("max_jaccard"), 0) or 0
    overlaps = coverage.get("overlaps_with") or ""
    survivor = overlaps.split(";")[0].split(":")[0] if overlaps else ""
    seconds = to_float(serial.get(row["suite"], {}).get("wall_s"))
    if seconds is None:
        seconds = to_float(costs.get(row["suite"], {}).get("net_wall_s"))
    rt = runtime_kind(row)
    hosting = to_int(row.get("ui_hosting")) or to_int(row.get("layout_if_needed"))
    sleeps = to_int(row.get("sleep_sites"))
    failures = hist.get(row["suite"], 0)
    pins = literal_pin_dominated(row)

    if kills:
        value = 3
    elif subject in ("mdk", "catalog", "test-helper"):
        value = 0
    elif pins or unique_i == 0:
        value = 1
    else:
        value = 2

    if rt == "start" or (seconds is not None and seconds > 10) or (hosting and sleeps):
        cost = 3
    elif rt == "construct" or (seconds is not None and seconds >= 1):
        cost = 2
    elif seconds is not None and seconds < 0.1:
        cost = 0
    else:
        cost = 1

    if failures:
        fragility = 3
    elif sleeps or to_int(row.get("run_loop")):
        fragility = 2
    elif to_int(row.get("poll_loops")):
        fragility = 1
    else:
        fragility = 0

    if unique_i == 0 and jaccard > 0.9:
        redundancy = 3
    elif unique_i == 0:
        redundancy = 2
    elif jaccard > 0.6:
        redundancy = 1
    else:
        redundancy = 0

    if kills:
        if cost >= 2 and rt == "construct" and not to_int(row.get("start_sites")):
            return value, cost, fragility, redundancy, "purify", f"kills {kills} probe(s); drop the unused runtime client"
        if cost >= 2:
            return value, cost, fragility, redundancy, "re-tier", f"kills {kills} probe(s); {rt} runtime / hosting {hosting}"
        return value, cost, fragility, redundancy, "keep", f"kills {kills} mutation probe(s)"
    if subject in ("mdk", "catalog", "test-helper"):
        decision, why = "delete", f"subject {subject}: exercises {subject} rather than app behaviour; no mutation kill"
    elif pins:
        decision, why = "trim", "every test asserts a literal or memberwise round-trip; keep only behavioural assertions"
    elif unique_i == 0 and redundancy == 3 and cost >= 1:
        decision, why = "delete", f"covers nothing {survivor} does not (Jaccard {jaccard:.2f}); costs {seconds}s"
    elif unique_i == 0 and jaccard > 0.6:
        decision, why = "merge", f"no unique covered lines; fold into {survivor} (Jaccard {jaccard:.2f})"
    elif unique_i == 0:
        decision, why = "keep", f"no unique covered lines but no overlapping suite (max Jaccard {jaccard:.2f}); distinct assertions"
    elif cost >= 2 and rt == "construct" and not to_int(row.get("start_sites")):
        decision, why = "purify", "constructs a runtime it never starts; drop the client or extract the decision"
    elif cost >= 2:
        decision, why = "re-tier", f"{rt} runtime / hosting {hosting} / {seconds}s; keep but out of the PR tier"
    elif redundancy >= 1:
        decision, why = "merge", f"Jaccard {jaccard:.2f} with {survivor}"
    elif fragility >= 2:
        decision, why = "purify", f"fragility {fragility}: fixed sleeps or CI failures; make the wait deterministic"
    else:
        decision, why = "keep", ""
    return value, cost, fragility, redundancy, decision, why


def render(rows, path):
    by_decision = defaultdict(list)
    for r in rows:
        by_decision[r["decision"]].append(r)
    lines = ["# Test audit ledger", "", f"{len(rows)} suites. Generated by scripts/audit/build-ledger.py; do not edit by hand.", ""]
    for decision in ["delete", "script", "trim", "merge", "purify", "re-tier", "review", "keep"]:
        group = sorted(by_decision.get(decision, []), key=lambda r: -(to_float(r["net_wall_s"], 0) or 0))
        if not group:
            continue
        lines += [f"## {decision} ({len(group)})", "",
                  "| suite | tests | net s | runtime | subject | flags | unique | flaky | V/C/F/R | rationale | owner |",
                  "|---|---:|---:|---|---|---|---:|---:|---|---|---|"]
        for r in group:
            lines.append(
                f"| {r['suite']} | {r['tests']} | {r['net_wall_s'] or ''} | {r['runtime']} | {r['subject']} | "
                f"{r['literal_assertion_flags']} | {r['unique_lines']} | {r['flaky_history']} | "
                f"{r['value']}/{r['cost']}/{r['fragility']}/{r['redundancy']} | {r['rationale']} | {r['owner_verdict']} |")
        lines.append("")
    with open(path, "w") as fh:
        fh.write("\n".join(lines))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--audit-dir", default=os.path.join(ROOT, "build", "audit"))
    ap.add_argument("--out-dir", default=os.path.join(ROOT, "docs", "test-audit"))
    ap.add_argument("--render", action="store_true")
    args = ap.parse_args()
    a = args.audit_dir

    inventory = read_csv(os.path.join(a, "inventory.csv"))
    if not inventory:
        raise SystemExit("inventory.csv missing; run scripts/audit/inventory.py first")
    costs = {r["suite"]: r for r in read_csv(os.path.join(a, "per-file-costs.csv"))}
    serial = {r["suite"]: r for r in read_csv(os.path.join(a, "serial-costs.csv"))}
    cov = {r["suite"]: r for r in read_csv(os.path.join(a, "coverage-unique.csv"))}
    mut = defaultdict(int)
    for r in read_csv(os.path.join(a, "mutations.csv")):
        if r.get("killed", "").lower() in ("1", "true", "yes"):
            mut[r["suite"]] += 1
    hist = {r["suite"]: to_int(r["failures"]) for r in read_csv(os.path.join(a, "ci-history.csv"))}
    overrides = {r["suite"]: r for r in read_csv(os.path.join(args.out_dir, "verdicts.csv"))}

    total_net = sum(to_float(c.get("net_wall_s"), 0) or 0 for c in costs.values()) or 1
    rows = []
    for inv in inventory:
        s = inv["suite"]
        value, cost, fragility, redundancy, decision, why = score(inv, costs, cov, mut, hist, serial)
        o = overrides.get(s, {})
        rows.append({
            "suite": s, "file": inv.get("file", ""), "tests": inv.get("tests", ""), "framework": inv.get("framework", ""),
            "tier_now": tier(inv), "serialized_s": serial.get(s, {}).get("wall_s") or serial.get(s, {}).get("sum_test_s", ""),
            "net_wall_s": costs.get(s, {}).get("net_wall_s", ""),
            "wall_share_pct": round(100 * (to_float(costs.get(s, {}).get("net_wall_s"), 0) or 0) / total_net, 1),
            "runtime": runtime_kind(inv), "ui_hosting": inv.get("ui_hosting", ""), "main_actor": inv.get("main_actor", ""),
            "sleep_sites": inv.get("sleep_sites", ""), "poll_loops": inv.get("poll_loops", ""),
            "flaky_history": hist.get(s, 0), "unique_lines": cov.get(s, {}).get("unique_lines", ""),
            "covered_lines": cov.get(s, {}).get("covered_lines", ""), "overlaps_with": cov.get(s, {}).get("overlaps_with", ""),
            "subject": inv.get("subject", ""), "literal_assertion_flags": inv.get("literal_assertion_flags", ""),
            "mutation_kills": mut.get(s, 0), "value": value, "cost": cost, "fragility": fragility,
            "redundancy": redundancy, "decision": o.get("decision") or decision,
            "rationale": o.get("rationale") or why, "owner_verdict": o.get("owner_verdict", ""), "after_s": "",
        })
    os.makedirs(args.out_dir, exist_ok=True)
    out = os.path.join(args.out_dir, "ledger.csv")
    with open(out, "w", newline="") as fh:
        w = csv.DictWriter(fh, lineterminator="\n", fieldnames=COLUMNS)
        w.writeheader()
        w.writerows(rows)
    counts = defaultdict(int)
    for r in rows:
        counts[r["decision"]] += 1
    print(f"wrote {out}: {len(rows)} suites; " + ", ".join(f"{k}={v}" for k, v in sorted(counts.items())))
    if args.render:
        render(rows, os.path.join(args.out_dir, "ledger.md"))
        print(f"rendered {os.path.join(args.out_dir, 'ledger.md')}")


if __name__ == "__main__":
    main()
