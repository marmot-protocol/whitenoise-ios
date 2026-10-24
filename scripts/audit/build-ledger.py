#!/usr/bin/env python3
"""Join the audit inputs into the per-suite decision ledger.

Inputs under --audit-dir (the committed copies live in docs/test-audit/data):
  inventory.csv        scripts/audit/inventory.py (+ --merge columns)
  serial-costs.csv     scripts/audit/serial-costs.py --log  (per-suite wall_s)
  per-file-costs.csv   scripts/audit/per-file-costs.py      (file-level, informational)
  coverage-unique.csv  scripts/audit/coverage-unique.py
  mutations.csv        scripts/audit/mutate.sh (killed: 1 / 0 / unverified / na; only 1 counts)
  ci-history.csv       scripts/audit/ci-attribute.py (failures, master_failures, branches, kinds)
  assertions.csv       scripts/audit/assertion-heuristics.py (per-test flags)
Hand verdicts: --verdicts (default docs/test-audit/verdicts.csv) with columns
  suite, decision, merge_into, rationale, owner_verdict.

Output: <out-dir>/ledger.csv and, with --render, <out-dir>/ledger.md.

Decision words (see docs/test-audit/README.md for the implementer actions):
  keep · trim (remove the named tests; the suite stays unless the rationale
  moves the rest elsewhere) · merge (move every test
  into `merge_into`; delete nothing) · purify (drop an unused runtime client,
  or make a wait deterministic; the rationale says which) · re-tier (keep, out
  of the PR tier) · script (replace with a lint-job script, keep the named
  in-process tests) · delete (whole suite) · review (not confident).

The automatic proposal is conservative: a suite that killed a mutation probe is
never proposed for deletion; zero unique coverage becomes a merge only when one
overlapping suite is a clear survivor; a non-app subject label alone yields
`review`, not `delete`; literal-pin-dominated suites are trimmed, not deleted.
`merge` survivors are resolved so no survivor is itself removed and mutual
pairs pick the suite with more unique coverage. Every row keeps the automatic
proposal next to the final decision (`auto_decision`), and `owner_verdict` says
who decided; nothing here is owner-approved until the owner writes `approve`.
"""
import argparse
import csv
import os
from collections import defaultdict

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
REMOVING = {"delete", "merge", "script"}
DECISIONS = ["delete", "script", "trim", "merge", "purify", "re-tier", "review", "keep"]
# Scoring evidence and the hand verdicts: a missing file would silently turn
# into "no kills", "no failures" or "no verdicts" and change the proposals.
REQUIRED_INPUTS = ["inventory.csv", "serial-costs.csv", "coverage-unique.csv", "mutations.csv",
                   "ci-history.csv", "assertions.csv"]

COLUMNS = [
    "suite", "file", "tests", "framework", "tier_now", "serialized_s", "wall_share_pct", "file_net_wall_s",
    "shared_file", "runtime", "ui_hosting", "main_actor", "sleep_sites", "poll_loops", "ci_failures",
    "ci_master_failures", "ci_branches", "ci_kinds", "unique_lines", "covered_lines", "overlaps_with", "subject",
    "literal_assertion_flags", "flagged_tests", "mutation_kills", "value", "cost", "fragility", "redundancy",
    "auto_decision", "auto_rationale", "decision", "merge_into", "rationale", "owner_verdict", "after_s",
]


def read_csv(path, required=False):
    if not os.path.exists(path):
        if required:
            raise SystemExit(f"{path} missing; the ledger needs it (see docs/test-audit/README.md)")
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


def runtime_kind(row):
    """`start` when the suite starts a runtime, `construct` when it builds a
    MarmotClient it never starts, else `none`. `AppState.test()` without a
    client is not a runtime."""
    if to_int(row.get("start_sites")):
        return "start"
    if to_int(row.get("testClient_sites")):
        return "construct"
    return "none"


def tier(row):
    kind = runtime_kind(row)
    if kind != "none":
        return "runtime"
    if to_int(row.get("ui_hosting")) or to_int(row.get("image_renderer")) or to_int(row.get("layout_if_needed")):
        return "uiHosting"
    return "pure"


def flagged_test_count(suite, assertions):
    """Distinct tests of the suite with at least one literal/memberwise flag."""
    return sum(1 for r in assertions.get(suite, []) if r.get("flags"))


def score(row, serial, cov, mut, hist, flagged_tests):
    """Return (value, cost, fragility, redundancy, decision, rationale, survivor)."""
    subject = row.get("subject") or "app"
    kills = mut.get(row["suite"], 0)
    coverage = cov.get(row["suite"], {})
    unique_i = to_int(coverage.get("unique_lines"), -1)
    jaccard = to_float(coverage.get("max_jaccard"), 0) or 0
    overlaps = coverage.get("overlaps_with") or ""
    survivor = overlaps.split(";")[0].split(":")[0] if overlaps else ""
    seconds = to_float(serial.get(row["suite"], {}).get("wall_s"))
    rt = runtime_kind(row)
    hosting = to_int(row.get("ui_hosting")) or to_int(row.get("layout_if_needed"))
    sleeps = to_int(row.get("sleep_sites"))
    tests = to_int(row.get("tests"))
    pins = tests > 0 and flagged_tests >= tests
    ci = hist.get(row["suite"], {})
    failures = to_int(ci.get("failures"))
    master_failures = to_int(ci.get("master_failures"))
    branches = to_int(ci.get("branches"))
    crashed = "crashed" in (ci.get("kinds") or "")

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

    # A failure on master, on two or more branches, or a host crash is
    # fragility; a single failure on one PR branch is usually the test catching
    # that PR's regression and counts as timing-shaped only if it also sleeps.
    if master_failures or branches >= 2 or crashed:
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
        if cost >= 2 and rt == "construct":
            return value, cost, fragility, redundancy, "purify", f"kills {kills} probe(s); drop the unused runtime client", ""
        if cost >= 2:
            return value, cost, fragility, redundancy, "re-tier", f"kills {kills} probe(s); {rt} runtime / hosting {hosting}", ""
        if fragility >= 2:
            return value, cost, fragility, redundancy, "purify", f"kills {kills} probe(s); make the wait deterministic", ""
        return value, cost, fragility, redundancy, "keep", f"kills {kills} mutation probe(s)", ""
    if subject in ("mdk", "catalog", "test-helper"):
        decision, why, target = "review", f"classified {subject}; read the test before deciding (the label is a heuristic)", ""
    elif pins:
        decision, why, target = "trim", "every test asserts a literal or a memberwise round-trip; keep only behavioural assertions", ""
    elif unique_i == 0 and redundancy == 3 and seconds is not None and seconds >= 1:
        decision, why, target = "delete", f"covers nothing {survivor} does not (Jaccard {jaccard:.2f}); costs {seconds}s", survivor
    elif unique_i == 0 and jaccard > 0.6:
        decision, why, target = "merge", f"no unique covered lines; move its tests into {survivor} (Jaccard {jaccard:.2f})", survivor
    elif unique_i == 0:
        decision, why, target = "keep", f"no unique covered lines but no overlapping suite (max Jaccard {jaccard:.2f}); distinct assertions", ""
    elif cost >= 2 and rt == "construct":
        decision, why, target = "purify", "constructs a runtime it never starts; drop the client (verify no test reads it)", ""
    elif cost >= 2:
        decision, why, target = "re-tier", f"{rt} runtime / hosting {hosting} / {seconds}s; keep but out of the PR tier", ""
    elif redundancy >= 1:
        decision, why, target = "review", f"Jaccard {jaccard:.2f} with {survivor} but {unique_i} unique lines; coverage similarity, not proven duplication", ""
    elif fragility >= 2:
        decision, why, target = "purify", f"fragility {fragility}: fixed sleeps or a run-loop spin; make the wait deterministic", ""
    else:
        decision, why, target = "keep", "", ""
    return value, cost, fragility, redundancy, decision, why, target


def resolve_survivors(rows, cov, inventory_names):
    """Make every `merge` row point at a suite that is not itself removed.

    Follows survivor chains to a terminal suite; for mutual pairs keeps the
    suite with more unique coverage (tie: more tests) and turns the other's
    row into the merge; a survivor outside the inventory becomes `review`.
    """
    by_suite = {r["suite"]: r for r in rows}

    def rewrite(row, why):
        # An approved verdict is the owner's; never replace it with another decision.
        if row.get("owner_verdict") == "approve":
            raise SystemExit(f"approved verdict for {row['suite']} conflicts: {why}; the owner must resolve it")

    def unique(name):
        return to_int(cov.get(name, {}).get("unique_lines"), 0), to_int(by_suite.get(name, {}).get("tests"))

    changed = True
    while changed:
        changed = False
        for r in rows:
            if r["decision"] != "merge":
                continue
            target = r["merge_into"]
            if not target or target not in inventory_names:
                r["decision"], r["merge_into"] = "review", ""
                r["rationale"] = f"merge survivor {target or '(none)'} is not a suite; {r['rationale']}"
                changed = True
                continue
            t = by_suite[target]
            if t["decision"] == "merge" and t["merge_into"] == r["suite"]:
                # mutual pair: the richer one survives
                if unique(target) > unique(r["suite"]):
                    rewrite(t, f"mutual merge with {r['suite']}")
                    t["decision"], t["merge_into"] = "keep", ""
                    t["rationale"] = f"survivor of {r['suite']}; {t['auto_rationale']}"
                else:
                    rewrite(r, f"mutual merge with {target}")
                    r["decision"], r["merge_into"] = "keep", ""
                    r["rationale"] = f"survivor of {target}; {r['auto_rationale']}"
                changed = True
            elif t["decision"] in REMOVING and t["merge_into"] and t["merge_into"] != r["suite"]:
                r["merge_into"] = t["merge_into"]
                r["rationale"] = f"{r['rationale']} (survivor {target} is itself merged into {t['merge_into']})"
                changed = True
            elif t["decision"] in ("delete", "script") or (t["decision"] == "merge" and not t["merge_into"]):
                rewrite(r, f"intended survivor {target} is {t['decision']}d")
                r["decision"], r["merge_into"] = "review", ""
                r["rationale"] = f"intended survivor {target} is {t['decision']}d; {r['rationale']}"
                changed = True


def render(rows, path):
    def cell(value):
        return str(value if value is not None else "").replace("|", "\\|").replace("\n", " ")

    by_decision = defaultdict(list)
    for r in rows:
        by_decision[r["decision"]].append(r)
    lines = ["# Test audit ledger", "",
             f"{len(rows)} suites. Generated by scripts/audit/build-ledger.py from docs/test-audit/data; do not edit by hand. "
             "`owner_verdict` is `proposed` until the repository owner approves a row.", ""]
    for decision in DECISIONS:
        group = sorted(by_decision.get(decision, []), key=lambda r: -(to_float(r["serialized_s"], 0) or 0))
        if not group:
            continue
        lines += [f"## {decision} ({len(group)})", "",
                  "| suite | tests | serialized s | runtime | subject | flagged tests | unique | shared file | CI (master/all) | V/C/F/R | auto | into | owner | rationale |",
                  "|---|---:|---:|---|---|---:|---:|---:|---|---|---|---|---|---|"]
        for r in group:
            lines.append(
                f"| {cell(r['suite'])} | {r['tests']} | {r['serialized_s']} | {r['runtime']} | {r['subject']} | "
                f"{r['flagged_tests']} | {r['unique_lines']} | {r['shared_file']} | {r['ci_master_failures']}/{r['ci_failures']} | "
                f"{r['value']}/{r['cost']}/{r['fragility']}/{r['redundancy']} | {r['auto_decision']} | {cell(r['merge_into'])} | {cell(r['owner_verdict'])} | {cell(r['rationale'])} |")
        lines.append("")
    with open(path, "w") as fh:
        fh.write("\n".join(lines))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--audit-dir", default=os.path.join(ROOT, "docs", "test-audit", "data"))
    ap.add_argument("--out-dir", default=os.path.join(ROOT, "docs", "test-audit"))
    ap.add_argument("--verdicts", default=os.path.join(ROOT, "docs", "test-audit", "verdicts.csv"))
    ap.add_argument("--render", action="store_true")
    args = ap.parse_args(argv)
    a = args.audit_dir

    for name in REQUIRED_INPUTS:
        read_csv(os.path.join(a, name), required=True)
    inventory = read_csv(os.path.join(a, "inventory.csv"))
    if not inventory:
        raise SystemExit(f"{os.path.join(a, 'inventory.csv')} missing; run scripts/audit/inventory.py first")
    names = {r["suite"] for r in inventory}
    costs = {r["suite"]: r for r in read_csv(os.path.join(a, "per-file-costs.csv"))}
    serial = {r["suite"]: r for r in read_csv(os.path.join(a, "serial-costs.csv"))}
    cov = {r["suite"]: r for r in read_csv(os.path.join(a, "coverage-unique.csv"))}
    mut = defaultdict(int)
    for r in read_csv(os.path.join(a, "mutations.csv")):
        if r.get("killed", "") == "1":
            mut[r["suite"]] += 1
    hist = {r["suite"]: r for r in read_csv(os.path.join(a, "ci-history.csv"))}
    assertions = defaultdict(list)
    for r in read_csv(os.path.join(a, "assertions.csv")):
        assertions[r["suite"]].append(r)
    overrides = {}
    for r in read_csv(args.verdicts, required=True):
        if r["suite"] not in names:
            raise SystemExit(f"verdicts.csv names an unknown suite: {r['suite']}")
        overrides[r["suite"]] = r
    for r in overrides.values():
        if r.get("decision") and r["decision"] not in DECISIONS:
            raise SystemExit(f"verdict for {r['suite']} has unknown decision {r['decision']!r}; "
                             f"use one of {', '.join(DECISIONS)}")
        target = (r.get("merge_into") or "").strip()
        if r.get("decision") == "merge" and target not in names:
            raise SystemExit(f"verdict for {r['suite']} merges into {target or '(none)'}, which is not an inventory suite")

    total_serial = sum(to_float(s.get("wall_s"), 0) or 0 for s in serial.values()) or 1
    rows = []
    for inv in inventory:
        s = inv["suite"]
        flagged = flagged_test_count(s, assertions)
        value, cost, fragility, redundancy, decision, why, target = score(inv, serial, cov, mut, hist, flagged)
        o = overrides.get(s, {})
        ci = hist.get(s, {})
        wall = to_float(serial.get(s, {}).get("wall_s"))
        rows.append({
            "suite": s, "file": inv.get("file", ""), "tests": inv.get("tests", ""), "framework": inv.get("framework", ""),
            "tier_now": tier(inv), "serialized_s": "" if wall is None else wall,
            "wall_share_pct": round(100 * (wall or 0) / total_serial, 1),
            "file_net_wall_s": costs.get(s, {}).get("net_wall_s", ""),
            "shared_file": cov.get(s, {}).get("shared_file") or costs.get(s, {}).get("shared_file", ""),
            "runtime": runtime_kind(inv), "ui_hosting": inv.get("ui_hosting", ""), "main_actor": inv.get("main_actor", ""),
            "sleep_sites": inv.get("sleep_sites", ""), "poll_loops": inv.get("poll_loops", ""),
            "ci_failures": to_int(ci.get("failures")), "ci_master_failures": to_int(ci.get("master_failures")),
            "ci_branches": to_int(ci.get("branches")), "ci_kinds": ci.get("kinds", ""),
            "unique_lines": cov.get(s, {}).get("unique_lines", ""), "covered_lines": cov.get(s, {}).get("covered_lines", ""),
            "overlaps_with": cov.get(s, {}).get("overlaps_with", ""), "subject": inv.get("subject", ""),
            "literal_assertion_flags": inv.get("literal_assertion_flags", ""), "flagged_tests": flagged,
            "mutation_kills": mut.get(s, 0), "value": value, "cost": cost, "fragility": fragility, "redundancy": redundancy,
            "auto_decision": decision, "auto_rationale": why,
            "decision": o.get("decision") or decision, "merge_into": (o.get("merge_into") or "").strip() if o else target,
            "rationale": o.get("rationale") or why, "owner_verdict": o.get("owner_verdict") or "proposed", "after_s": "",
        })
    resolve_survivors(rows, cov, names)
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
