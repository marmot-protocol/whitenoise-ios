#!/usr/bin/env bash
#
# scripts/lint.sh — single source of truth for Swift linting in this repo.
#
# Used by:
#   - `just lint`            (manual local invocation)
#   - `just precommit`       (full local gate before push)
#   - `.github/workflows/lint.yml` (CI gate)
#
# Reads the CI env var to switch reporter:
#   CI=true        → github-actions-logging   (inline PR annotations)
#   CI unset/false → emoji (default)          (human-readable terminal output)
#
# Exits non-zero on:
#   - swiftlint not installed
#   - swiftlint version not the exact pin (must match CI)
#   - any lint violation (--strict)

set -euo pipefail

REQUIRED_SWIFTLINT_VERSION="0.63.2"   # bump in lockstep with .github/workflows/lint.yml

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

# ── precheck: swiftlint installed ────────────────────────────────────
if ! command -v swiftlint >/dev/null 2>&1; then
    echo "error: swiftlint not on PATH." >&2
    echo "       Install with: brew install swiftlint" >&2
    exit 127
fi

# ── precheck: swiftlint version pin ──────────────────────────────────
# Pinned exactly (not a floor) so local results match the version CI installs;
# SwiftLint rule sets drift between releases, so a newer local version can pass
# locally yet fail the CI gate.
ACTUAL_VERSION="$(swiftlint version 2>/dev/null || echo 0.0.0)"
if [[ "$ACTUAL_VERSION" != "$REQUIRED_SWIFTLINT_VERSION" ]]; then
    echo "error: swiftlint $ACTUAL_VERSION does not match the pinned $REQUIRED_SWIFTLINT_VERSION." >&2
    echo "       CI runs exactly $REQUIRED_SWIFTLINT_VERSION; a different local version can pass here but fail CI." >&2
    echo "       Get it from: https://github.com/realm/SwiftLint/releases/tag/$REQUIRED_SWIFTLINT_VERSION" >&2
    exit 2
fi

# ── reporter selection ───────────────────────────────────────────────
REPORTER="emoji"
if [[ "${CI:-false}" == "true" ]]; then
    REPORTER="github-actions-logging"
fi

# ── run ──────────────────────────────────────────────────────────────
echo "==> swiftlint $ACTUAL_VERSION (reporter=$REPORTER, strict)"
swiftlint lint \
    --config "$ROOT_DIR/.swiftlint.yml" \
    --reporter "$REPORTER" \
    --strict
