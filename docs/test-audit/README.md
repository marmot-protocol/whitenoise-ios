# Test suite audit

Why this exists, how the numbers were produced, how to read the ledger, and
what each decision word asks an implementer to do.

## Why

By October 2026 the unit-test target had grown to about 2,970 tests in 265
files (63k lines against ~100k lines of app code), most of it generated during
the summer. A pull request's CI run took 20–55 minutes and master runs had a
median of 35 minutes. The audit measured what each suite costs and protects,
so decisions to keep, simplify, merge, re-tier or delete rest on evidence
rather than on reading test names.

The work runs in three waves, one pull request per phase:

1. **Infrastructure** (no behaviour change): split the 15,904-line monolith
   into one file per suite plus `whitenoise-iosTests/TestSupport/`; CI
   test-phase timing scripts; static inventory and classifiers; a guard so the
   test host app no longer boots the production Marmot runtime.
2. **Evidence**: serialized per-suite costs, coverage overlap, mutation
   probes, CI failure history, joined into `ledger.csv`.
3. **Cleanup**: execute the ledger's verdicts cluster by cluster, then CI
   tiers and guardrails.

## Who decided

The repository owner delegated the per-suite verdicts for wave 2. Every row's
`owner_verdict` is therefore `proposed`, and `decision`/`rationale` are the
auditor's. The automatic proposal is kept beside them (`auto_decision`,
`auto_rationale`) so a reader can see where a hand verdict overrode the
numbers and why. Nothing in the ledger is owner-approved until the owner writes
`approve` into `verdicts.csv`.

## Tools (`scripts/audit/`)

| Script | Produces | Notes |
|---|---|---|
| `suite-names.py` | stdout | Suite type names per file (and `--map` display→type names for `@Suite("…")`) via the shared scanner; the shell loops use it so no script carries its own declaration regex. |
| `inventory.py` | `inventory.csv`, tier lists | One row per suite: runtime construction/start/shutdown sites (including helpers the suite reaches), UI hosting, sleeps, polls, traits. Works on any file layout; keyed by suite name. |
| `subject-classify.py --merge` | `subjects.csv` + `subject` column | `app`, `mdk` (tests MarmotKit behaviour), `catalog` (reads string catalogs / plists), `test-helper`. A heuristic: a non-`app` label yields `review`, never `delete`, and the test must be read before acting. |
| `assertion-heuristics.py --merge` | `assertions.csv` + `literal_assertion_flags` | Flags literal pins (`constant == 16`), memberwise round-trips and tests with no assertion. A flag means "asserts a literal", not "cannot fail"; persistence keys and security build flags are legitimate pins. |
| `timed-xcodebuild.sh`, `phases.py`, `report-run.sh`, `simlog-capture.sh` | `phases.csv`, CI step summary | Decompose `test-without-building` into simulator boot, host launch, XCTest and Swift Testing phases from xcodebuild's own markers. `WN_TEST_RAW_LOG=1 scripts/test.sh` runs a measurement run. |
| `Whitenoise (Audit)` scheme + `TestPlans/AuditSerial.xctestplan` → `serial-costs.py --log` | `serial.xcresult`, `serial-costs.csv` | Whole suite with parallel execution off and coverage on (the plan also enables Xcode's default per-test timeout, which the Staging scheme does not). Run with `WN_AUDIT_LOG=build/audit/serial-run.log scripts/audit/timed-xcodebuild.sh test-without-building -scheme "Whitenoise (Audit)" -testPlan AuditSerial -resultBundlePath build/audit/serial.xcresult …`. Per-suite `wall_s` comes from the log: Swift Testing suite lines (millisecond precision, display names mapped back to type names) and XCTest class start/end clocks. This is the cost the ledger scores. |
| gate trace (`TEST_RUNNER_WN_TEST_GATE_TRACE=1`) → `gate-critical-path.py` | `gate-trace-<pid>.jsonl` in the host app's `tmp/` (`xcrun simctl get_app_container <udid> dev.ipf.whitenoise.ios.staging data`) | Hold and wait times of the `marmotRuntimeConcurrencyLimit` gate. In a serial run it is a per-case breakdown of the gated suite; the hold sum is the CI critical-path floor at one permit. |
| `measure-per-file.sh` → `per-file-costs.py` | `per-file/*.xcresult`, `per-file-costs.csv` | One `test-without-building` per test file with coverage on, minus the fixed per-process overhead measured with an empty selection. File-level at ±1 s resolution (suites sharing a file repeat the numbers; `shared_file` says so); its purpose is the coverage bundles, not per-suite cost. About an hour; rerun touched files with arguments (`WN_AUDIT_FORCE=1` re-measures, `WN_AUDIT_PER_FILE_DIR` relocates). |
| `coverage-unique.py` | `coverage-unique.csv` | Per-file covered-line sets from `xccov --archive` on the per-file bundles, with the host-launch baseline (the empty-selection bundle) subtracted and lines covered by more than 15% of files (L10n lookups, hex/npub helpers, build-config reads) excluded; unique lines and pairwise Jaccard. Suites sharing a file share its set. |
| `probe-suites.py`, `mutate.sh` + `mutations/*.json` | `mutations.csv` | One deliberate production bug per probe. Suites are selected by coverage of the mutated lines (fallbacks: file, then symbol grep), the probe is applied, built, run, recorded (`killed` 1 / 0 / `na` when no bundle could be read) and reverted from a trap; a final rebuild restores the clean products. A kill is evidence; a surviving or unselected suite is not. |
| `ci-history.sh` → `ci-attribute.py` | `ci-runs.csv`, `ci-history.csv`, `ci-unattributed.csv` | Which suites failed in the last N GitHub Actions runs: Swift Testing suite lines, XCTest methods mapped to their class, and the host-crash signature in xcbeautify logs (a class starts and a `Selected tests` restart follows). Failures on master are counted separately from failures on PR branches, where the test may have caught the PR's own regression; build failures are listed as unattributed. |
| `build-ledger.py --render` | `docs/test-audit/ledger.csv`, `ledger.md` | Joins everything above with the hand verdicts in `verdicts.csv`. |

All scripts are Python 3.9+ standard library or bash; unit tests live in
`scripts/tests/` (`python3 -m unittest discover -s scripts/tests`).

## Reading the ledger

Scores 0–3 per suite, as implemented in `build-ledger.py`:

- **value** — 3 killed a mutation probe; 0 the subject is MarmotKit, a string
  catalog or a test helper; 1 every test is a literal pin, or no covered line
  is unique to the suite; 2 otherwise.
- **cost** — from the serial run's per-suite wall time: 3 starts a runtime,
  over 10 s, or hosts UIKit with fixed sleeps; 2 constructs a runtime or
  1–10 s; 0 under 0.1 s; 1 otherwise.
- **fragility** — 3 failed on master, on two or more branches, or crashed the
  CI host; 2 fixed sleeps, a run-loop spin, or one PR-branch failure; 1 bounded
  polling; 0 none.
- **redundancy** — 3 zero unique lines and Jaccard > 0.9 with one file; 2 zero
  unique lines; 1 Jaccard > 0.6; 0 otherwise.

| decision | the implementer does | done when |
|---|---|---|
| `keep` | nothing | — |
| `trim` | deletes exactly the tests the rationale names; the suite stays | suite green; the named tests are gone; nothing else changed |
| `merge` | moves every test into `merge_into`, then deletes the empty file; drops a test only when the rationale says it duplicates a named survivor test | survivor green with the moved tests; the survivor still kills the probes it killed |
| `purify` | the rationale says which: removes a `MarmotClient.testClient()` the suite never starts (check no test reads the client first), or replaces a fixed sleep / polling loop with a callback or injected clock | suite green; `inventory.py` shows `testClient_sites` at 0 for a removed client, and `inventory.py --check` reports no `sleep` or `unowned-runtime` line for the suite (sleeps inside `TestSupport/` helpers do not count); serialized time not worse |
| `re-tier` | tags the suite (or only the tests that need it) `.runtime` or `.uiHosting` so PRs skip it; an XCTest class goes into the PR plan's `skippedTests`; no code change | the PR plan skips it; full suite still green on master |
| `script` | moves the catalog checks to a Python script in the lint job; keeps the named in-process tests | script fails on a deliberately broken catalog; the kept tests are green |
| `delete` | deletes the suite (not the file, when the file holds other suites) | full suite green; the rationale's named replacement coverage still exists |
| `review` | reads the suite before deciding; the numbers alone were not conclusive | a verdict row is added |

`delete` is proposed automatically only for a suite with no mutation kill, zero
unique coverage, Jaccard > 0.9 with one file and at least 1 s of cost; a
non-app subject label alone yields `review`. `merge` survivors are resolved so
none is itself removed; mutual pairs keep the suite with more unique coverage.
Kills are recorded per suite: after trimming a suite that killed a probe, rerun
the probe.

## Tiers

| plan | runs | CI |
|---|---|---|
| `TestPlans/PR.xctestplan` | everything except tests tagged `.runtime` or `.uiHosting` and the hosting XCTest classes | pull requests (`scripts/test.sh --tier pr`) |
| `TestPlans/Full.xctestplan` | everything; the Staging scheme's default plan | master pushes, nightly `schedule`, manual runs (`--tier full`) |

The policy is one line in `.github/workflows/tests.yml` (`--tier` on the Run
tests step). Tags (`whitenoise-iosTests/TestSupport/Tags.swift`) go on the
suite or on single tests. Xcode 27.1's xcodebuild ignores a plan's
`skippedTags`, and applies `skippedTests` only to XCTest, so the PR plan lists
every tagged suite and test by identifier and `scripts/test.sh --tier pr`
repeats that list as `-skip-testing:` flags for Swift Testing. Regenerate the
list with `python3 scripts/audit/inventory.py --write-pr-plan` after tagging;
it keeps the XCTest classes already listed (`ProfileShareCardLocalizationTests`
runs Vision OCR on a rendered card and is listed by hand).

`python3 scripts/audit/inventory.py --check` (in `scripts/lint.sh`) enforces,
per suite (`scripts/audit/guardrails.py`, fixtures in
`scripts/tests/test_audit_guardrails.py`):

- `runtime-tag`: a test reaching `MarmotClient.testClient(`,
  `MarmotClient(rootPath:`, `withTestClient`, `OwnedTestClient(` or
  `TestRuntimeScope.own(` is tagged `.runtime` (test or suite; suite-wide code
  needs the suite tag);
- `ui-tag`: the same for `UIWindow`/`UIHostingController` and `.uiHosting`
  (`ImageRenderer` does not count); an XCTest class must be in the PR plan
  instead;
- `sleep`: no `Task.sleep` outside `TestSupport/` helpers;
- `unowned-runtime`: a direct `testClient()`/`MarmotClient(rootPath:)` is
  wrapped in `TestRuntimeScope.own` or `closing`;
- `timelimit-gate`: no `.timeLimit` on a test under
  `.marmotRuntimeConcurrencyLimit` (the limit would count gate queue time);
- `pr-plan`: the PR plan skips exactly the tagged suites and tests.

`scripts/audit/guardrail-baseline.txt` holds the violations present when the
check landed; they print as `baselined` and do not fail. Remove a line when its
suite is fixed (stale lines are reported).

The runtime gate has `max(2, cores/4)` permits (2 on the 3-vCPU CI runner, 4
on a 16-core Mac); `TEST_RUNNER_WN_TEST_GATE_CORES=3` reproduces CI locally.
On 16 cores 8 permits passed but ran the full suite about 50 s slower than 4.

Known flake, not yet fixed: `AppStateBootstrapTests.signOutClearsSigningOutGuardBeforeReturning`
failed once on the wave 3 integration branch (`activeAccountRef` still set
after sign-out).

## Rerunning the measurements

```sh
python3 scripts/audit/inventory.py --emit-tier-lists
python3 scripts/audit/subject-classify.py --merge
python3 scripts/audit/assertion-heuristics.py --merge
scripts/audit/ci-history.sh 200
# serial run: see the table above, then
python3 scripts/audit/serial-costs.py build/audit/serial.xcresult --log build/audit/serial-run.log
python3 scripts/audit/gate-critical-path.py <gate-trace-*.jsonl>
scripts/audit/measure-per-file.sh            # about an hour; add file names to redo a subset
python3 scripts/audit/per-file-costs.py
python3 scripts/audit/coverage-unique.py
scripts/audit/mutate.sh --all                # about an hour
cp build/audit/*.csv build/audit/gate-summary.txt docs/test-audit/data/
python3 scripts/audit/build-ledger.py --render   # reads docs/test-audit/data and verdicts.csv
```

Measurements are machine-specific; compare runs from the same Mac, and treat
CI numbers (3-vCPU runner) as a separate series produced by the step summary.
`docs/test-audit/data/` holds the inputs the committed ledger was built from;
`inventory.csv`, `subjects.csv` and `assertions.csv` are static and regenerate
in a second, the rest cost simulator time.

## Measured findings

Provenance: 2026-10-23, Apple Silicon Mac (16 cores), Xcode 27.1, iPhone SE
(3rd generation) iOS 26.2 simulator, tree at the wave 1 integration merge.

- **Serialized cost of the whole suite: 232 s** (2,977 tests, 378 suites,
  parallel execution off; 211 s of Swift Testing suites plus 21 s of XCTest
  classes). `AppStateBootstrapTests` alone is **141 s, 61%**; the next suites
  are `ConversationWindowBindingTests` 10.2 s, `RuntimeOwnershipTests` 9.4 s,
  `ControlLayoutTests` 6.5 s, `OnboardingRecoveryRemovalTests` 6.4 s,
  `AccountExitSheetTests` 5.7 s, `WNQRCodeCardRenderingTests` 5.4 s.
  Everything else together is about 45 s.
- **Per-file processes** (325 files, 11 s fixed overhead each at ±1 s): same
  ranking; `AppStateBootstrapTests` 139 s net. Used for coverage, not cost.
- **Runtime gate**: 95 gated test cases hold the permit for 139.9 s in total
  (median 1.2 s, p90 3.3 s, max 8.0 s). That hold time is real work (each test
  boots a runtime and creates an identity), so on the 3-vCPU CI runner, where
  the gate has one permit, it becomes the 300–650 s critical path seen in CI
  logs. On this 16-core Mac the gate has 4 permits; the serial plan ran one
  test at a time, so the trace measures hold, not contention.
- **Open-only runtime constructions** (~300 tests that call
  `MarmotClient.testClient()` and never start it) cost little here:
  `ChatsListProjectionTests` with 30 of them runs in 0.09 s. They still leak
  ~190 unclosed runtimes per run and are removed by `purify` for hygiene.
- **Coverage overlap**: after subtracting the 966 host-launch lines and
  excluding 341 ubiquitous lines, 38 of 325 files cover no line that another
  file does not also cover, and 4 files covered no app line at all (disabled
  or catalog-only suites). Zero unique lines is a redundancy input, never a
  deletion by itself; for pure policy suites the value is in the enumerated
  inputs, which line coverage cannot see.
- **Mutation probes**: 9 of 9 killed by at least one suite. See
  `data/mutations.csv` for which suites were selected (by coverage of the
  mutated lines) and which killed each probe; the selection is broad, so most
  selected suites passing a mutant says only that they do not assert that
  line.
- **CI failure history (last 200 runs, 27 failed, 44 cancelled)**: 7 runs name
  no suite (`data/ci-unattributed.csv`: 5 build failures, one host crash
  before any test ran, one manual dispatch). Of the rest,
  `Marmot0104BindingTests` failed 4 times on 4 branches (1 on master),
  `AccountExitSheetTests` was in 4 failed runs on 2 branches (host crashes
  during its XCTest class, one plain failure), `PrivateKeyAutoFillTests` 3 on 3
  branches, `CustomEmojiSendingFixtureTests` 3 (2 on master),
  `ProfileFormLayoutTests` crashed the host 3 times on one branch,
  `LocalizationCatalogTests` failed twice on one PR branch when copy changed,
  and `ControlLayoutTests`, `MediaImageZoomTests` (one crashed run together),
  `GroupModerationBindingTests`, `AccountExitPresentationTests`,
  `ContinuousQRScannerTests` once each. `ci-runs.csv` durations include
  queue time.
- **Ledger** (`ledger.csv`): counts by decision are in the header of
  `ledger.md`; 86 suites carry a hand verdict from `verdicts.csv`, the rest are
  the automatic proposal.
