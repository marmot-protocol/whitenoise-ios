# Test suite audit

Why this exists, how the numbers were produced, and how to read the ledger.

## Why

By October 2026 the unit-test target had grown to 2,971 tests in 265 files
(63k lines against ~100k lines of app code), most of it generated during the
summer. A pull request's CI run took 20–55 minutes, and master runs had a
median of 35 minutes. The audit measured what each suite costs and protects,
so decisions to keep, simplify, merge, re-tier or delete rest on evidence
rather than on reading test names.

The work ran in three waves, one pull request per phase:

1. **Infrastructure** (no behaviour change): split the 15,904-line monolith
   into one file per suite plus `whitenoise-iosTests/TestSupport/`; CI
   test-phase timing scripts; static inventory and classifiers; a guard so the
   test host app no longer boots the production Marmot runtime.
2. **Evidence**: serialized per-suite costs, coverage overlap, mutation
   probes, CI failure history, joined into `ledger.csv`.
3. **Cleanup**: execute the ledger's verdicts cluster by cluster, then CI
   tiers and guardrails.

## Tools (`scripts/audit/`)

| Script | Produces | Notes |
|---|---|---|
| `suite-names.py` | stdout | Suite type names per file (and `--map` display→type names for `@Suite("…")`) via the shared scanner; used by the shell loops so no script carries its own declaration regex. |
| `inventory.py` | `build/audit/inventory.csv`, tier lists | One row per suite: runtime construction/start/shutdown sites (including helpers the suite reaches), UI hosting, sleeps, polls, traits. Works on any file layout; keyed by suite name. |
| `subject-classify.py --merge` | `subjects.csv` + `subject` column | `app`, `mdk` (tests MarmotKit behaviour), `catalog` (reads string catalogs / plists), `test-helper`. Heuristic; read the test before acting on a non-`app` label. |
| `assertion-heuristics.py --merge` | `assertions.csv` + `literal_assertion_flags` | Flags literal pins (`constant == 16`), memberwise round-trips and tests with no assertion. A flag means "asserts a literal", not "cannot fail"; persistence keys and security build flags are legitimate pins. |
| `timed-xcodebuild.sh`, `phases.py`, `report-run.sh`, `simlog-capture.sh` | `phases.csv`, CI step summary | Decompose `test-without-building` into simulator boot, host launch, XCTest and Swift Testing phases using xcodebuild's own markers. `WN_TEST_RAW_LOG=1 scripts/test.sh` runs a measurement run. |
| `measure-per-file.sh` → `per-file-costs.py` | `per-file/*.xcresult`, `per-file-costs.csv` | One `test-without-building` per test file with coverage on, minus the fixed per-process overhead measured with an empty selection. The numbers are FILE-level at ±1 s resolution (suites sharing a file repeat them; `shared_file` says so); their purpose is the coverage bundles and a sanity check of the serial run, not per-suite cost. About an hour of machine time; rerun touched files with arguments (`WN_AUDIT_FORCE=1` re-measures existing ones; `WN_AUDIT_PER_FILE_DIR` relocates the output). |
| `Whitenoise (Audit)` scheme + `TestPlans/AuditSerial.xctestplan` → `serial-costs.py --log` | `serial.xcresult`, `serial-costs.csv` | Whole suite with parallel execution off, coverage on (the plan also enables Xcode's default per-test timeout, which the Staging scheme does not). Run with `WN_AUDIT_LOG=build/audit/serial-run.log scripts/audit/timed-xcodebuild.sh test-without-building -scheme "Whitenoise (Audit)" -testPlan AuditSerial -resultBundlePath build/audit/serial.xcresult …`; `TEST_RUNNER_WN_TEST_GATE_TRACE=1` also writes `gate-trace-<pid>.jsonl` into the host app's `tmp/` (`xcrun simctl get_app_container <udid> dev.ipf.whitenoise.ios.staging data`). Per-suite `wall_s` comes from the log (Swift Testing suite lines; XCTest classes from their start/end clocks). |
| `gate-critical-path.py` | stdout | Hold and wait times of the `marmotRuntimeConcurrencyLimit` gate; the hold sum is the CI critical-path floor at one permit. |
| `coverage-unique.py` | `coverage-unique.csv` | Per-file covered-line sets from the per-file bundles (`xccov --archive`); unique lines (covered by no other file) and pairwise overlap. Suites sharing a test file share its set. |
| `mutate.sh` + `mutations/*.json` | `mutations.csv` | Applies one deliberate production bug per probe, runs the suites that reference the symbol, records which suites fail (kill it), reverts. A suite that covers the line and stays green is a value downgrade. |
| `ci-history.sh` | `ci-history.csv`, `ci-runs.csv` | Which suites failed in the last N GitHub Actions runs. |
| `build-ledger.py --render` | `docs/test-audit/ledger.csv`, `ledger.md` | Joins everything above with hand overrides from `verdicts.csv`. |

All scripts are Python 3.9+ standard library or bash; unit tests live in
`scripts/tests/` (`python3 -m unittest discover -s scripts/tests`). The
`coverage-unique.py`, `mutate.sh`, `ci-history.sh` and `build-ledger.py` rows
arrive with wave 2 phases 6 and 7; phase 5 ships the measurement rows.

## Reading the ledger

Scores 0–3 per suite:

- **value** — 0 tautological, or the subject is MarmotKit, a string catalog or a
  test helper; 1 real behaviour that is trivially re-covered elsewhere (no
  unique covered lines); 2 guards an app decision; 3 guards an `AGENTS.md`
  invariant or killed a mutation probe.
- **cost** — 0 under 0.1 s serialized; 1 under 1 s; 2 constructs a runtime or
  1–10 s; 3 starts a runtime, hosts UIKit with layout waits, or over 10 s.
- **fragility** — 0 none; 1 bounded polling; 2 fixed sleeps, layout timing or
  wall-clock; 3 failed in CI history or depends on pasteboard, network or
  shared `UserDefaults`.
- **redundancy** — 0 unique covered lines and assertions; 1 overlaps another
  suite; 2 zero unique lines; 3 zero unique lines and nothing another suite
  lacks.

Decisions: `keep`, `purify` (extract the decision into a pure helper and drop
the runtime or hosting), `merge` (into the named survivor), `re-tier` (keep,
but run on master and nightly rather than on every PR), `delete`, `review`
(the automatic proposal is not confident). `delete` is proposed only when
value ≤ 1, no mutation probe was killed, and cost or redundancy is high; the
`owner_verdict` column records the final call. `verdicts.csv` holds hand
overrides and their rationale and is the only hand-edited file; `ledger.md`
is rendered, never edited.

## Rerunning the measurements

```sh
python3 scripts/audit/inventory.py --emit-tier-lists
python3 scripts/audit/subject-classify.py --merge
python3 scripts/audit/assertion-heuristics.py --merge
scripts/audit/ci-history.sh 200
scripts/audit/measure-per-file.sh            # hours; add file names to redo a subset
python3 scripts/audit/per-file-costs.py
python3 scripts/audit/coverage-unique.py
scripts/audit/mutate.sh --all
python3 scripts/audit/build-ledger.py --render
```

Measurements are machine-specific; compare runs from the same Mac, and treat
CI numbers (3-vCPU runner) as a separate series produced by the step summary.
