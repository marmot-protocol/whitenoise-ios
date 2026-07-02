#!/usr/bin/env bash
# Extract Swift line coverage from an .xcresult and optionally gate on it.
# Ports sloth/scripts/check-coverage.sh to this repo's xccov-based toolchain.
#
# Usage:
#   check-coverage.sh                          # print line-coverage % only
#   check-coverage.sh --min 40                 # exit 1 if below 40%
#   check-coverage.sh --warnings-file out.txt  # dump 0%-covered files to out.txt
#   check-coverage.sh path/to/Foo.xcresult     # read a non-default result bundle
set -euo pipefail

cd "$(dirname "$0")/.."

XCRESULT="build/TestResults.xcresult"
MIN_COVERAGE=""
WARNINGS_FILE=""

# Only first-party source counts; the vendored bindings and test bundle are
# separate targets and drop out on the target/path filters below.
SOURCE_ROOTS_RE="/(whitenoise-ios|Shared|NotificationServiceExtension)/"
IGNORE_MARKER="// coverage:ignore-file"

print_error()   { printf '%b%s%b\n' "\e[31;1m" "$1" "\e[0m" >&2; }
print_success() { printf '%b%s%b\n' "\e[32;1m" "$1" "\e[0m" >&2; }
print_warning() { printf '%b%s%b\n' "\e[33;1m" "$1" "\e[0m" >&2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --min)           MIN_COVERAGE="$2"; shift 2 ;;
    --warnings-file) WARNINGS_FILE="$2"; shift 2 ;;
    *)               XCRESULT="$1"; shift ;;
  esac
done

command -v jq >/dev/null 2>&1 || { print_error "Error: jq not found. Install with 'brew install jq'."; exit 1; }

if [ ! -e "$XCRESULT" ]; then
  print_error "Error: $XCRESULT not found. Run scripts/test.sh first."
  exit 1
fi

if ! REPORT_JSON="$(xcrun xccov view --report --json "$XCRESULT" 2>/dev/null)"; then
  print_error "Error: no coverage in $XCRESULT. Was it built with -enableCodeCoverage YES?"
  exit 1
fi

# path<TAB>coveredLines<TAB>executableLines for first-party files only, with the
# path already reduced to a repo-relative form.
JQ_PROG='
  .targets[]
  | select((.name // "") | ascii_downcase | contains("test") | not)
  | .files[]
  | select(.path | test($roots))
  | select((.path | test("\\.xcassets/")) | not)
  | [ (.path | capture("/(?<rel>(whitenoise-ios|Shared|NotificationServiceExtension)/.*)$").rel),
      (.coveredLines // 0),
      (.executableLines // 0) ]
  | @tsv
'

reported_file="$(mktemp)"
uncovered_file="$(mktemp)"
trap 'rm -f "$reported_file" "$uncovered_file"' EXIT

covered=0
executable=0
while IFS=$'\t' read -r rel cov exe; do
  [ -z "$rel" ] && continue
  if grep -qF "$IGNORE_MARKER" "$rel" 2>/dev/null; then
    continue
  fi
  echo "$rel" >> "$reported_file"
  covered=$((covered + cov))
  executable=$((executable + exe))
  if [ "$cov" -eq 0 ] && [ "$exe" -gt 0 ]; then
    echo "$rel" >> "$uncovered_file"
  fi
done < <(printf '%s' "$REPORT_JSON" | jq -r --arg roots "$SOURCE_ROOTS_RE" "$JQ_PROG")

# Safety net: first-party source xccov never reported is compiled into no
# instrumented target. Warn-only for now; not counted in the denominator.
unreported=0
while IFS= read -r swift; do
  case "$swift" in *.xcassets/*) continue ;; esac
  grep -qF "$IGNORE_MARKER" "$swift" 2>/dev/null && continue
  if ! grep -qxF "$swift" "$reported_file"; then
    [ "$unreported" -eq 0 ] && print_warning "First-party file(s) not instrumented (warn-only, not counted):"
    print_warning "   - $swift"
    unreported=$((unreported + 1))
  fi
done < <(find whitenoise-ios Shared NotificationServiceExtension -name '*.swift' -type f 2>/dev/null | sort)

if [ "$executable" -gt 0 ]; then
  COVERAGE="$(awk "BEGIN{printf \"%.2f\", $covered / $executable * 100}")"
else
  COVERAGE="0.00"
fi

if [ -s "$uncovered_file" ]; then
  print_warning "$(wc -l < "$uncovered_file" | tr -d ' ') file(s) with 0% coverage"
fi
if [ -n "$WARNINGS_FILE" ]; then
  sort "$uncovered_file" > "$WARNINGS_FILE"
fi

if [ -z "$MIN_COVERAGE" ]; then
  echo "$COVERAGE"
  exit 0
fi

if awk "BEGIN{exit !($COVERAGE >= $MIN_COVERAGE)}"; then
  print_success "✅ Coverage: ${COVERAGE}%"
  exit 0
fi

print_error "❌ Coverage: ${COVERAGE}% (below minimum ${MIN_COVERAGE}%)"
exit 1
