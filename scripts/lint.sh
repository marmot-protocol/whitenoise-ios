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
#   - swiftlint version below required floor
#   - any lint violation (--strict)

set -euo pipefail

REQUIRED_SWIFTLINT_VERSION="0.57.0"   # bump in lockstep with .github/workflows/lint.yml

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

# ── precheck: swiftlint installed ────────────────────────────────────
if ! command -v swiftlint >/dev/null 2>&1; then
    echo "error: swiftlint not on PATH." >&2
    echo "       Install with: brew install swiftlint" >&2
    exit 127
fi

# ── precheck: swiftlint version floor ────────────────────────────────
ACTUAL_VERSION="$(swiftlint version 2>/dev/null || echo 0.0.0)"
if [[ "$(printf '%s\n%s\n' "$REQUIRED_SWIFTLINT_VERSION" "$ACTUAL_VERSION" | sort -V | head -n1)" \
      != "$REQUIRED_SWIFTLINT_VERSION" ]]; then
    echo "error: swiftlint $ACTUAL_VERSION is below required floor $REQUIRED_SWIFTLINT_VERSION." >&2
    echo "       Upgrade with: brew upgrade swiftlint" >&2
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
