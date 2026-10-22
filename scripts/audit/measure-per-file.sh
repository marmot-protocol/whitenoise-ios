#!/usr/bin/env bash
# Measure the true, uncontended cost of every test file by running each file's
# suites in its own `xcodebuild test-without-building` invocation, with code
# coverage on, through scripts/audit/timed-xcodebuild.sh.
#
# Swift Testing runs tests in parallel inside one process and reports per-test
# wall time that includes waiting on the MainActor and on the runtime gate, so a
# single full run cannot say what a suite costs. One process per file keeps
# intra-file contention small; the fixed per-process overhead (simulator attach,
# host launch, discovery) is measured once with an empty selection and
# subtracted by scripts/audit/per-file-costs.py.
#
# Uses the "Whitenoise (Audit)" scheme and its AuditSerial test plan (parallel
# execution off, coverage on), so a file's tests do not contend with each other
# either and the xcresult carries coverage for scripts/audit/coverage-unique.py.
#
# Usage:
#   scripts/audit/measure-per-file.sh                 # all suite files
#   scripts/audit/measure-per-file.sh AppStateBootstrapTests ChatMuteTests
#   WN_AUDIT_SKIP_BUILD=1 scripts/audit/measure-per-file.sh   # reuse last build
#
# Outputs under build/audit/per-file/: <File>.xcresult, <File>.log, and
# overhead.xcresult/.log for the empty-selection baseline. Nothing is committed.
set -euo pipefail

cd "$(dirname "$0")/../.."

DESTINATION="${WN_TEST_DESTINATION:-$(scripts/pick-simulator.sh)}"
OUT="${WN_AUDIT_PER_FILE_DIR:-build/audit/per-file}"
TESTS_DIR="whitenoise-iosTests"
mkdir -p "$OUT"

xcodebuild_args=(
  -project whitenoise-ios.xcodeproj
  -scheme "Whitenoise (Audit)"
  -testPlan AuditSerial
  -destination "$DESTINATION"
  -skipPackagePluginValidation
  -skipMacroValidation
  -enableCodeCoverage YES
)
if [ -n "${WN_TEST_DERIVED_DATA:-}" ]; then
  xcodebuild_args+=(-derivedDataPath "$WN_TEST_DERIVED_DATA")
fi

build_settings=(
  ONLY_ACTIVE_ARCH=YES
  CODE_SIGN_STYLE=Manual
  DEVELOPMENT_TEAM=""
  PROVISIONING_PROFILE_SPECIFIER=""
  CODE_SIGN_IDENTITY="-"
  CODE_SIGNING_ALLOWED=YES
)

# Suites declared in a file: top-level `struct|class|enum <Name>Tests`.
suites_in() {
  grep -oE '^(@MainActor[[:space:]]+)?(final[[:space:]]+)?(struct|class|enum)[[:space:]]+[A-Za-z0-9_]+Tests\b' "$1" \
    | awk '{print $NF}'
}

if [ -z "${WN_AUDIT_SKIP_BUILD:-}" ]; then
  echo "==> build-for-testing (coverage on)"
  xcodebuild build-for-testing "${xcodebuild_args[@]}" "${build_settings[@]}" \
    | { command -v xcbeautify >/dev/null 2>&1 && xcbeautify || cat; }
fi

run_selection() {
  local label="$1"; shift
  local bundle="$OUT/$label.xcresult"
  rm -rf "$bundle"
  local start=$SECONDS
  local status=0
  WN_AUDIT_LOG="$OUT/$label.log" scripts/audit/timed-xcodebuild.sh test-without-building \
    "${xcodebuild_args[@]}" -resultBundlePath "$bundle" "$@" >/dev/null || status=$?
  echo "$(date +%Y-%m-%dT%H:%M:%S) ==> $label: $((SECONDS - start))s status=$status" | tee -a "$OUT/$label.log" >> "$OUT/runs.log"
  return 0
}

# Fixed overhead: a selection that matches nothing still attaches, installs and
# launches the host twice (discovery + run).
if [ ! -e "$OUT/overhead.xcresult" ]; then
  run_selection overhead "-only-testing:whitenoise-iosTests/NoSuchSuiteForOverheadMeasurement"
fi

if [ "$#" -gt 0 ]; then
  files=()
  for name in "$@"; do files+=("$TESTS_DIR/$name.swift"); done
else
  files=("$TESTS_DIR"/*.swift)
fi

for file in "${files[@]}"; do
  label="$(basename "$file" .swift)"
  suites=()
  while IFS= read -r suite; do
    [ -n "$suite" ] && suites+=("$suite")
  done < <(suites_in "$file")
  if [ "${#suites[@]}" -eq 0 ]; then
    continue
  fi
  if [ -e "$OUT/$label.xcresult" ] && [ -z "${WN_AUDIT_FORCE:-}" ]; then
    echo "skip $label (exists)"; continue
  fi
  only=()
  for s in "${suites[@]}"; do only+=("-only-testing:whitenoise-iosTests/$s"); done
  echo "==> $label (${#suites[@]} suite(s))"
  run_selection "$label" "${only[@]}"
done

echo "done; results under $OUT (see runs.log)"
