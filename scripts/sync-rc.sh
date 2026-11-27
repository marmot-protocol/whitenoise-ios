#!/usr/bin/env bash
# Pin the latest verified MarmotKit Release Candidate (develop / staging only).
#
# MDK publishes one RC a day to its `rc-meta` branch, written by GitHub-signed
# commits only after Canary, simulator-nightly, convergence-hardening and every
# artifact build pass. RCs are GitHub pre-releases that upstream deletes after 30
# days, so master and production never pin one: master takes the Stable release
# promoted from an RC (scripts/promote-stable.sh). See docs/release-flow.md.
#
# Usage:
#   scripts/sync-rc.sh [--summary FILE] [--force]
#
#   --summary FILE  write a Markdown bump summary (impact, breaking UniFFI
#                   changes, migrations, links) for a PR description
#   --force         reinstall even when the pin already matches, and allow a
#                   run on master or an older RC than the current pin
#
# Exit status 0 with no changes when rc/latest.json names the RC already pinned.
# When run in GitHub Actions it also writes `changed`, `version`, `impact` and
# `source_sha` to $GITHUB_OUTPUT.

set -euo pipefail

RC_META="https://raw.githubusercontent.com/marmot-protocol/mdk/rc-meta"
SUMMARY=""
FORCE=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --summary) SUMMARY="${2:?--summary needs a file}"; shift 2 ;;
        --force) FORCE=1; shift ;;
        *) echo "usage: $0 [--summary FILE] [--force]" >&2; exit 2 ;;
    esac
done

APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION_FILE="$APP_DIR/Packages/MarmotKit/MARMOT_VERSION"

output() {
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"
    fi
}

branch="${GITHUB_HEAD_REF:-$(git -C "$APP_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || true)}"
if [[ "$branch" == "master" && $FORCE -eq 0 ]]; then
    echo "error: master pins Stable MarmotKit only; run this on develop (or pass --force)" >&2
    exit 1
fi

TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

fetch() {
    curl --fail --location --retry 3 --silent --show-error "$RC_META/rc/$1" --output "$TEMP_DIR/$1"
}

echo "==> Reading $RC_META/rc/latest.json"
fetch latest.json

# Validate the whole contract before trusting any of it, and write the asset
# digests sync-bindings.sh must match.
PLAN="$(python3 -I - "$TEMP_DIR/latest.json" "$TEMP_DIR/expected-assets.json" <<'PYPLAN'
import json, pathlib, re, sys

def fail(message):
    print(f"error: rc/latest.json: {message}", file=sys.stderr)
    sys.exit(1)

doc = json.loads(pathlib.Path(sys.argv[1]).read_text())
if doc.get("schema") != 2:
    fail(f"unsupported schema {doc.get('schema')!r} (expected 2)")
if doc.get("channel") != "rc":
    fail(f"channel is {doc.get('channel')!r}, not 'rc'")
version = doc.get("version")
if not isinstance(version, str) or not re.fullmatch(r"\d+\.\d+\.\d+-rc\.\d+", version):
    fail(f"version {version!r} is not a SemVer RC")
source_sha = doc.get("source_sha")
if not isinstance(source_sha, str) or not re.fullmatch(r"[0-9a-f]{40}", source_sha):
    fail("source_sha is not a 40-character commit SHA")
impact = doc.get("impact")
if impact not in ("patch", "minor"):
    fail(f"impact {impact!r} is neither 'patch' nor 'minor'")
triggers = doc.get("impact_triggers")
if not isinstance(triggers, list) or not all(isinstance(t, str) for t in triggers):
    fail("impact_triggers is not a list of strings")
baseline = doc.get("baseline_tag")
if not isinstance(baseline, str) or not baseline:
    fail("baseline_tag is missing")
track = (doc.get("tracks") or {}).get("marmotkit") or {}
if track.get("tag") != f"marmotkit-v{version}":
    fail(f"tracks.marmotkit.tag {track.get('tag')!r} does not name marmotkit-v{version}")

assets = {}
prefix = f"https://github.com/marmot-protocol/mdk/releases/download/marmotkit-v{version}/"
for asset in track.get("assets") or []:
    name, url, sha = asset.get("name"), asset.get("url"), asset.get("sha256")
    if not (isinstance(name, str) and isinstance(sha, str) and re.fullmatch(r"[0-9a-f]{64}", sha)):
        fail(f"asset {name!r} has no valid sha256")
    if url != prefix + name:
        fail(f"asset {name} is not served from the marmotkit-v{version} release")
    assets[name] = sha

# Every input comes from this one version: mixing versions breaks UniFFI's ABI
# checks or drops the SDK's privacy declarations.
required = [
    f"MarmotKit-{version}.swift",
    f"MarmotKitFFI-{version}.xcframework.zip",
    f"MarmotKitFFI-{version}.xcframework.zip.swiftpm-checksum",
    f"PrivacyInfo-ios-{version}.xcprivacy",
]
missing = [name for name in required if name not in assets]
if missing:
    fail("missing iOS assets: " + ", ".join(missing))
pathlib.Path(sys.argv[2]).write_text(json.dumps(assets, indent=2, sort_keys=True))
print(version, source_sha, impact, baseline, doc.get("date", ""))
PYPLAN
)"
read -r VERSION SOURCE_SHA IMPACT BASELINE RC_DATE <<< "$PLAN"
echo "    $VERSION ($IMPACT vs $BASELINE) from $SOURCE_SHA"

pinned_tag="$(sed -nE 's/^mdk-tag: (.*)$/\1/p' "$VERSION_FILE")"
pinned_sha="$(sed -nE 's/^mdk-sha: (.*)$/\1/p' "$VERSION_FILE")"
if [[ "$pinned_tag" == "marmotkit-v$VERSION" && "$pinned_sha" == "$SOURCE_SHA" && $FORCE -eq 0 ]]; then
    echo "MarmotKit is already pinned to $VERSION ($SOURCE_SHA); nothing to do."
    output changed false
    exit 0
fi

# Never step back: an RC older than the pin (say rc-meta still names 0.20.0-rc.3
# after master took Stable 0.20.0) would downgrade the account schema.
if [[ $FORCE -eq 0 ]]; then
    python3 -I - "${pinned_tag#marmotkit-v}" "$VERSION" <<'PYORDER'
import re, sys
def key(v):
    m = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)(?:-(nightly|rc)\.(\d+))?", v)
    if not m:
        return None
    major, minor, patch, pre, n = m.groups()
    # A nightly of X.Y.Z predates its RCs; a Stable outranks both.
    rank = {"nightly": 0, "rc": 1, None: 2}[pre]
    return (int(major), int(minor), int(patch), rank, int(n or 0))
pinned, latest = key(sys.argv[1]), key(sys.argv[2])
if pinned is not None and latest < pinned:
    print(f"error: the latest RC {sys.argv[2]} is older than the pinned {sys.argv[1]}; pass --force to downgrade", file=sys.stderr)
    sys.exit(1)
PYORDER
fi

echo "==> Reading rc/signature_delta.json and rc/integration-notes.md"
fetch signature_delta.json
fetch integration-notes.md

BREAKING_COUNT="$(python3 -I - "$TEMP_DIR/signature_delta.json" "$VERSION" "$SOURCE_SHA" <<'PYDELTA'
import json, pathlib, sys
delta = json.loads(pathlib.Path(sys.argv[1]).read_text())
target = delta.get("target_sha")
if target and target != sys.argv[3]:
    print(f"error: signature_delta.json describes {target}, not {sys.argv[3]}", file=sys.stderr)
    sys.exit(1)
print(len((delta.get("uniffi") or {}).get("breaking") or []))
PYDELTA
)"

if [[ "$IMPACT" == "patch" && "$BREAKING_COUNT" == "0" ]]; then
    echo "    patch RC with no breaking UniFFI changes: expected to be a drop-in update"
else
    echo "    $IMPACT RC with $BREAKING_COUNT breaking UniFFI change(s) since $BASELINE:"
    echo "    read $RC_META/rc/integration-notes.md and fix call sites before merging"
fi

if [[ -n "$SUMMARY" ]]; then
    python3 -I - "$TEMP_DIR/latest.json" "$TEMP_DIR/signature_delta.json" "$pinned_tag" > "$SUMMARY" <<'PYSUMMARY'
import json, pathlib, sys
doc = json.loads(pathlib.Path(sys.argv[1]).read_text())
delta = json.loads(pathlib.Path(sys.argv[2]).read_text())
pinned = sys.argv[3]
v = doc["version"]
uniffi = delta.get("uniffi") or {}
breaking = uniffi.get("breaking") or []
fns = uniffi.get("functions") or {}
types = uniffi.get("types") or {}
notes = "https://github.com/marmot-protocol/mdk/blob/rc-meta/rc/integration-notes.md"
lines = [
    f"Moves the staging MarmotKit pin from `{pinned}` to `marmotkit-v{v}`.",
    "",
    f"- **Source:** [`{doc['source_sha'][:12]}`](https://github.com/marmot-protocol/mdk/commit/{doc['source_sha']}) (verified `origin/canary`)",
    f"- **Impact:** `{doc['impact']}` against `{doc['baseline_tag']}`",
    f"- **Release:** {doc['tracks']['marmotkit']['release_url']}",
    f"- **Integration notes:** {notes}",
    "",
    "RCs are deleted upstream after 30 days. This pin is for develop and staging builds only;",
    "master takes the Stable release promoted from the RC (`just promote-stable`).",
]
if doc.get("impact_triggers"):
    lines += ["", "### Impact triggers", ""] + [f"- {t}" for t in doc["impact_triggers"]]
if breaking:
    lines += ["", f"### Breaking UniFFI changes since {doc['baseline_tag']}", ""] + [f"- {b}" for b in breaking]
    lines += ["", "Adapt the affected Swift call sites in this PR before merging; CI shows what no longer compiles."]
added = [f["name"] for f in fns.get("added") or []]
removed = [f["name"] for f in fns.get("removed") or []]
changed = [f["name"] for f in fns.get("changed") or []]
for title, names in (("Added functions", added), ("Changed functions", changed), ("Removed functions", removed)):
    if names:
        lines += ["", f"### {title}", ""] + [f"- `{n}`" for n in names]
added_types = [t.get("name") or t.get("definition", "").split("{")[0].strip() for t in types.get("added") or []]
if added_types:
    lines += ["", "### Added types", ""] + [f"- `{n}`" for n in added_types]
migrations = [m.rsplit("/", 1)[-1] for m in delta.get("storage_migrations") or [] if "/migrations/" in m]
if migrations:
    lines += ["", "### Storage migrations (one-way)", ""] + [f"- `{m}`" for m in migrations]
    lines += ["", "An older build refuses an upgraded account database. Test with the staging flavor."]
print("\n".join(lines))
PYSUMMARY
    echo "    summary written to $SUMMARY"
fi

MARMOTKIT_EXPECTED_ASSETS="$TEMP_DIR/expected-assets.json" \
MARMOTKIT_EXTRA_STAMPS="rc-date: $RC_DATE
rc-impact: $IMPACT
rc-baseline-tag: $BASELINE" \
    "$APP_DIR/scripts/sync-bindings.sh" "$VERSION"

output changed true
output version "$VERSION"
output impact "$IMPACT"
output source_sha "$SOURCE_SHA"
output breaking "$BREAKING_COUNT"
