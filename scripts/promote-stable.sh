#!/usr/bin/env bash
# Swap the pinned MarmotKit Release Candidate for the Stable release MDK promoted
# from it: the step that turns a tested staging build into a production one.
#
# MDK's promotion (promote-release.yml) builds Stable `marmotkit-vX.Y.Z` from a
# release commit whose only parent is the RC's verified source commit and whose
# only change is release metadata. This script pins that Stable release and
# refuses it unless its source is the pinned RC's source, or one commit on it that
# touches only the paths MDK's promotion allows, so production ships the code
# staging tested.
#
# Usage:
#   scripts/promote-stable.sh [X.Y.Z]
#
# The version defaults to the pinned RC's base version (0.20.0-rc.2 -> 0.20.0).
# Pass one when MDK promoted with an override version.

set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION_FILE="$APP_DIR/Packages/MarmotKit/MARMOT_VERSION"

rc_tag="$(sed -nE 's/^mdk-tag: (.*)$/\1/p' "$VERSION_FILE")"
rc_sha="$(sed -nE 's/^mdk-sha: (.*)$/\1/p' "$VERSION_FILE")"
if [[ ! "$rc_tag" =~ ^marmotkit-v([0-9]+\.[0-9]+\.[0-9]+)-rc\.[0-9]+$ ]]; then
    echo "error: the pin is $rc_tag, not a Release Candidate; nothing to promote" >&2
    exit 1
fi
stable="${1:-${BASH_REMATCH[1]}}"
if [[ ! "$stable" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: $stable is not a Stable X.Y.Z version" >&2
    exit 2
fi

TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT
cp "$APP_DIR/Packages/MarmotKit/Sources/MarmotKit/MarmotKit.swift" "$TEMP_DIR/rc.swift"

# Check provenance before touching the pin.
manifest="marmotkit-ios-$stable.manifest.json"
curl --fail --location --retry 3 --silent --show-error \
    "https://github.com/marmot-protocol/mdk/releases/download/marmotkit-v$stable/$manifest" \
    --output "$TEMP_DIR/$manifest" \
    || { echo "error: no Stable marmotkit-v$stable release is published yet" >&2; exit 1; }
stable_sha="$(plutil -extract source_sha raw -o - "$TEMP_DIR/$manifest")"
if [[ "$stable_sha" != "$rc_sha" ]]; then
    curl --fail --location --retry 3 --silent --show-error \
        "https://api.github.com/repos/marmot-protocol/mdk/compare/$rc_sha...$stable_sha" \
        --output "$TEMP_DIR/compare.json"
    # Fail closed unless Stable is one commit on the RC that changes release metadata only: the
    # paths MDK's own promotion allows (scripts/promote_release.py, is_allowed_metadata_path).
    python3 -I - "$TEMP_DIR/compare.json" "$rc_tag" "$rc_sha" "$stable" "$stable_sha" <<'PYCOMPARE' || exit 1
import json, re, sys
compare, rc_tag, rc_sha, stable, stable_sha = json.load(open(sys.argv[1])), *sys.argv[2:]

def fail(reason):
    print(f"error: Stable {stable} ({stable_sha}) is not {rc_tag} ({rc_sha}) plus release metadata: {reason}.", file=sys.stderr)
    print("       MDK promoted a different RC, or changed code: pin that RC on develop, cut and test", file=sys.stderr)
    print("       a staging build from it, then promote again.", file=sys.stderr)
    sys.exit(1)

if compare.get("status") != "ahead" or compare.get("behind_by") != 0 or compare.get("ahead_by") != 1:
    fail(f"it is {compare.get('ahead_by')} commit(s) ahead and {compare.get('behind_by')} behind, not one release commit on it")
exact = {
    "Cargo.toml", "Cargo.lock", "README.md", "release.md", "docs/integration/README.md",
    "integrations/README.md", "integrations/claude/marmot/README.md", "integrations/codex/marmot/README.md",
    "integrations/goose/marmot/README.md", "integrations/hermes/marmot/README.md",
    "integrations/openclaw/marmot/README.md", "integrations/opencode/marmot/README.md",
    "integrations/pi/marmot/README.md",
}
installers = {"scripts/install-hermes-marmot.sh", "scripts/install-openclaw-marmot.sh"}
patterns = [
    r"crates/cgka-conformance-simulator/vectors/.*\.json",
    r"(?:.*/)?CHANGELOG\.md",
    r"(?:.*/)?changelog\.d/[^/]+\.md",
    r"docs/(?:release|integration)/\d+\.\d+\.\d+\.md",
]
pin_line = re.compile(r"[+-]  base_url=https://github\.com/marmot-protocol/mdk/releases/download/wn-agent-v\d+\.\d+\.\d+")
files = compare.get("files") or []
if not files:
    fail("the comparison lists no files")
for f in files:
    path = f.get("filename", "")
    if path in installers:
        changed = [l for l in (f.get("patch") or "").splitlines() if l[:1] in "+-" and not l.startswith(("+++", "---"))]
        if not changed or not all(pin_line.fullmatch(l) for l in changed):
            fail(f"{path} changes more than its release pin")
    elif path not in exact and not any(re.fullmatch(p, path) for p in patterns):
        fail(f"it changes {path}")
PYCOMPARE
fi
echo "==> Stable $stable comes from $rc_tag ($rc_sha)"

"$APP_DIR/scripts/sync-bindings.sh" "$stable"

# The generated Swift should differ by version strings at most.
changed="$(diff "$TEMP_DIR/rc.swift" "$APP_DIR/Packages/MarmotKit/Sources/MarmotKit/MarmotKit.swift" | grep -c '^[<>]' || true)"
echo ""
echo "Generated Swift lines changed from $rc_tag: $changed"
