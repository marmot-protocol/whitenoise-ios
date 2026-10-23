#!/usr/bin/env bash
# Mutation probe runner for the test audit.
#
# A probe is a JSON file under scripts/audit/mutations/ with
#   {"name": "...", "path": "Shared/Foo.swift", "old": "exact text", "new": "replacement",
#    "grep": "symbol", "why": "which AGENTS.md invariant this breaks"}
# and optionally "suites": [...] as a hand override of the suite selection.
#
# For each probe: require a clean tracked tree for `path`, apply the
# replacement (the `old` text must occur exactly once), rebuild for testing,
# select suites with scripts/audit/probe-suites.py (coverage-based when the
# per-file coverage sets exist, else files mentioning the symbol), run them in
# one `test-without-building`, record one row per selected suite in
# build/audit/mutations.csv, and revert the file with `git checkout --`. A trap
# reverts on any exit, including Ctrl-C during the build.
#
# `killed` is 1 when the suite had a failing case, 0 when it ran a case that
# passed and its selection shows it executed the mutated lines, `unverified`
# when it passed but was selected only by file-level evidence (see
# probe-suites.py), `na` when no case of it ran (all skipped, host crash,
# launch failure, no bundle): never read `na`, `unverified` or an unselected
# suite as "survived". On exit (also after Ctrl-C) the source is reverted and,
# if a mutant was built, the clean tree is rebuilt; a failed rebuild fails the
# script. The probe files are not modified by a run.
#
# Usage: scripts/audit/mutate.sh scripts/audit/mutations/<probe>.json [...]
#        scripts/audit/mutate.sh --all
set -euo pipefail

cd "$(dirname "$0")/../.."
DESTINATION="${WN_TEST_DESTINATION:-$(scripts/pick-simulator.sh)}"
OUT="${WN_AUDIT_DIR:-build/audit}"
mkdir -p "$OUT/mutations"
CSV="$OUT/mutations.csv"
[ -s "$CSV" ] || echo "suite,probe,killed,selection,result_bundle" > "$CSV"

xcodebuild_args=(
  -project whitenoise-ios.xcodeproj
  -scheme "Whitenoise (Staging)"
  -destination "$DESTINATION"
  -skipPackagePluginValidation
  -skipMacroValidation
)
build_settings=(
  ONLY_ACTIVE_ARCH=YES CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" PROVISIONING_PROFILE_SPECIFIER=""
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_ALLOWED=YES
)

if [ "${1:-}" = "--all" ]; then
  set -- scripts/audit/mutations/*.json
fi

mutated_path=""
mutant_built=0
revert() {
  if [ -n "$mutated_path" ]; then
    git checkout -- "$mutated_path"
    mutated_path=""
  fi
}

# The source is reverted after each probe but the built products are not;
# after a mutant build DerivedData holds that mutant. Rebuild, with coverage
# instrumentation, so later test-without-building runs (measurements,
# per-file coverage) match the tree.
restore_build() {
  echo "==> restoring built products from the clean tree"
  if xcodebuild build-for-testing "${xcodebuild_args[@]}" "${build_settings[@]}" -enableCodeCoverage YES \
    > "$OUT/mutations/restore-build.log" 2>&1; then
    mutant_built=0
    return 0
  fi
  echo "mutate: restore build failed; the built products may still be a mutant; see $OUT/mutations/restore-build.log" >&2
  return 1
}

cleanup() {
  local code=$?
  trap - EXIT
  revert || code=1
  if [ "$mutant_built" -ne 0 ]; then
    restore_build || code=1
  fi
  exit "$code"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

for probe in "$@"; do
  name="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["name"])' "$probe")"
  path="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["path"])' "$probe")"
  if [ -n "$(git status --porcelain -- "$path")" ]; then
    echo "mutate: $path has local changes; refusing" >&2
    exit 2
  fi
  echo "==> probe $name ($path)"

  # Decide the suites before touching the tree, so a probe with no reachable
  # suite never mutates anything.
  python3 scripts/audit/probe-suites.py "$probe" > "$OUT/mutations/$name.suites"
  method="$(sed -n 's/^# method: //p' "$OUT/mutations/$name.suites")"
  only=()
  while read -r suite; do
    case "$suite" in \#*|"") continue ;; esac
    only+=("-only-testing:whitenoise-iosTests/$suite")
  done < "$OUT/mutations/$name.suites"
  if [ "${#only[@]}" -eq 0 ]; then
    echo "mutate: no suite reaches $name ($method); skipping" >&2
    continue
  fi

  mutated_path="$path"
  python3 - "$probe" <<'EOF'
import json, sys
probe = json.load(open(sys.argv[1]))
src = open(probe["path"]).read()
count = src.count(probe["old"])
if count != 1:
    raise SystemExit(f"mutate: `old` text occurs {count} times in {probe['path']} (need exactly 1)")
open(probe["path"], "w").write(src.replace(probe["old"], probe["new"]))
EOF

  bundle="$OUT/mutations/$name.xcresult"
  rm -rf "$bundle"
  status=0
  mutant_built=1
  if xcodebuild build-for-testing "${xcodebuild_args[@]}" "${build_settings[@]}" > "$OUT/mutations/$name.build.log" 2>&1; then
    xcodebuild test-without-building "${xcodebuild_args[@]}" -resultBundlePath "$bundle" "${only[@]}" \
      > "$OUT/mutations/$name.test.log" 2>&1 || status=$?
  else
    echo "mutate: build failed for $name (mutant does not compile); see $OUT/mutations/$name.build.log" >&2
    status=build
  fi
  revert

  python3 - "$bundle" "$name" "$CSV" "$OUT/mutations/$name.suites" "$method" "$status" <<'EOF'
import csv, json, subprocess, sys
bundle, name, csv_path, suites_path, method, status = sys.argv[1:7]
suites = [l.strip() for l in open(suites_path) if l.strip() and not l.startswith("#")]
results = None
if status != "build":
    try:
        results = json.loads(subprocess.run(["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", bundle],
                                            check=True, capture_output=True, text=True).stdout)
    except Exception as exc:
        print(f"mutate: no results for {name}: {exc}", file=sys.stderr)
unverified = set()
for line in open(suites_path):
    if line.startswith("# unverified:"):
        unverified |= set(line.split(":", 1)[1].split())
ran, failed = set(), set()
def walk(node, suite):
    kind = node.get("nodeType"); nm = node.get("name", "")
    if kind == "Test Suite": suite = nm
    if kind == "Test Case":
        result = node.get("result")
        # A skipped case checked nothing; Expected Failure is a pass.
        if result not in ("Skipped", None): ran.add(suite)
        if result == "Failed": failed.add(suite)
    for c in node.get("children") or []: walk(c, suite)
if results:
    for root in results.get("testNodes", []): walk(root, None)
# Replace any earlier rows for this probe so a rerun does not double count.
rows = []
if csv_path and open(csv_path).read().strip():
    with open(csv_path, newline="") as fh:
        rows = [r for r in csv.DictReader(fh) if r.get("probe") != name]
with open(csv_path, "w", newline="") as fh:
    w = csv.DictWriter(fh, lineterminator="\n", fieldnames=["suite", "probe", "killed", "selection", "result_bundle"])
    w.writeheader()
    w.writerows(rows)
    for suite in suites:
        if suite in failed:
            killed = "1"
        elif suite not in ran:
            killed = "na"
        else:
            killed = "unverified" if suite in unverified else "0"
        w.writerow({"suite": suite, "probe": name, "killed": killed, "selection": method, "result_bundle": bundle})
print(f"probe {name} [{method}]: killed by {sorted(failed) or 'nobody'}; ran {len(ran & set(suites))} of {len(suites)} selected suites")
EOF
done

# cleanup (the EXIT trap) restores the built products when a mutant was built.
