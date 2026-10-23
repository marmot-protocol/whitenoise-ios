#!/usr/bin/env bash
# Mutation probe runner for the test audit.
#
# A probe is a JSON file under scripts/audit/mutations/ with
#   {"name": "...", "path": "Shared/Foo.swift", "old": "exact text", "new": "replacement",
#    "suites": ["SuiteA", "SuiteB"], "why": "which AGENTS.md invariant this breaks"}
# The runner requires a clean tracked tree for `path`, applies the replacement
# (the `old` text must occur exactly once), rebuilds for testing, runs the listed
# suites one `test-without-building` per probe, records which suites failed
# (= killed the mutant) in build/audit/mutations.csv, and reverts the file with
# `git checkout --`. A suite that covers the mutated code and still passes is a
# value downgrade in the ledger.
#
# Usage: scripts/audit/mutate.sh scripts/audit/mutations/<probe>.json [...]
#        scripts/audit/mutate.sh --all
set -euo pipefail

cd "$(dirname "$0")/../.."
DESTINATION="${WN_TEST_DESTINATION:-$(scripts/pick-simulator.sh)}"
OUT="${WN_AUDIT_DIR:-build/audit}"
mkdir -p "$OUT/mutations"
CSV="$OUT/mutations.csv"
[ -s "$CSV" ] || echo "suite,probe,killed,result_bundle" > "$CSV"

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

for probe in "$@"; do
  name="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["name"])' "$probe")"
  path="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["path"])' "$probe")"
  if [ -n "$(git status --porcelain -- "$path")" ]; then
    echo "mutate: $path has local changes; refusing" >&2
    exit 2
  fi
  echo "==> probe $name ($path)"
  python3 - "$probe" <<'EOF'
import json, sys
probe = json.load(open(sys.argv[1]))
src = open(probe["path"]).read()
count = src.count(probe["old"])
if count != 1:
    raise SystemExit(f"mutate: `old` text occurs {count} times in {probe['path']} (need exactly 1)")
open(probe["path"], "w").write(src.replace(probe["old"], probe["new"]))
EOF
  status=0
  if xcodebuild build-for-testing "${xcodebuild_args[@]}" "${build_settings[@]}" > "$OUT/mutations/$name.build.log" 2>&1; then
    # Suites to run: the probe's explicit "suites", else every suite declared in
    # a test file that mentions the probe's "grep" symbol.
    python3 - "$probe" > "$OUT/mutations/$name.suites" <<'EOF'
import glob, json, re, sys
probe = json.load(open(sys.argv[1]))
suites = probe.get("suites")
if not suites:
    suites = []
    for f in sorted(glob.glob("whitenoise-iosTests/*.swift")):
        src = open(f).read()
        if probe["grep"] in src:
            suites += re.findall(r"^(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:nonisolated|final|private|fileprivate)\s+)*(?:struct|class|enum) (\w+Tests)\b", src, re.M)
    probe["suites"] = suites
    json.dump(probe, open(sys.argv[1], "w"), indent=2)
print("\n".join(suites))
EOF
    only=()
    while read -r suite; do [ -n "$suite" ] && only+=("-only-testing:whitenoise-iosTests/$suite"); done < "$OUT/mutations/$name.suites"
    if [ "${#only[@]}" -eq 0 ]; then
      echo "mutate: no suites reference $name's symbol" >&2
      git checkout -- "$path"
      continue
    fi
    bundle="$OUT/mutations/$name.xcresult"
    rm -rf "$bundle"
    xcodebuild test-without-building "${xcodebuild_args[@]}" -resultBundlePath "$bundle" "${only[@]}" \
      > "$OUT/mutations/$name.test.log" 2>&1 || status=$?
    python3 - "$bundle" "$name" "$CSV" "$probe" <<'EOF'
import csv, json, subprocess, sys
bundle, name, csv_path, probe_path = sys.argv[1:5]
probe = json.load(open(probe_path))
try:
    data = json.loads(subprocess.run(["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", bundle],
                                     check=True, capture_output=True, text=True).stdout)
except Exception as exc:  # bundle missing: build or launch failed
    print(f"mutate: no results for {name}: {exc}", file=sys.stderr)
    data = {"testNodes": []}
failed = set()
def walk(node, suite):
    kind = node.get("nodeType"); nm = node.get("name", "")
    if kind == "Test Suite": suite = nm
    if kind == "Test Case" and node.get("result") not in ("Passed", "Skipped", None): failed.add(suite)
    for c in node.get("children") or []: walk(c, suite)
for root in data.get("testNodes", []): walk(root, None)
with open(csv_path, "a", newline="") as fh:
    w = csv.writer(fh, lineterminator="\n")
    for suite in probe["suites"]:
        w.writerow([suite, name, "1" if suite in failed else "0", bundle])
print(f"probe {name}: killed by {sorted(failed) or 'nobody'} of {probe['suites']}")
EOF
  else
    echo "mutate: build failed for $name (mutant does not compile); see $OUT/mutations/$name.build.log" >&2
  fi
  git checkout -- "$path"
done
