#!/usr/bin/env bash
# Hold each branch to the MarmotKit channel it may pin (docs/release-flow.md).
#
#   master (production)       Stable `marmotkit-vX.Y.Z` only
#   anything else (develop,   any published release; warns when a pre-release
#   staging, feature work)    nears upstream's 30-day deletion
#
# Usage: scripts/ci/check-marmotkit-channel.sh [branch]
# The branch defaults to the PR's base branch, then the pushed branch, then the
# checked-out one: a PR into master is held to master's rule.

set -euo pipefail

cd "$(dirname "$0")/../.."
VERSION_FILE="Packages/MarmotKit/MARMOT_VERSION"

branch="${1:-${GITHUB_BASE_REF:-${GITHUB_REF_NAME:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)}}}"
tag="$(sed -nE 's/^mdk-tag: (.*)$/\1/p' "$VERSION_FILE")"
published="$(sed -nE 's/^published-at: (.*)$/\1/p' "$VERSION_FILE")"

if [[ "$tag" =~ ^marmotkit-v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "MarmotKit $tag is Stable; fine on '$branch'."
    exit 0
fi

if [[ "$branch" == "master" ]]; then
    echo "error: master ships to production and must pin a Stable MarmotKit release, not $tag." >&2
    echo "       Run \`just promote-stable\` to swap the RC for the Stable release promoted from it." >&2
    exit 1
fi

# Pre-releases are deleted upstream 30 days after publication, and a build that
# cannot fetch its binary fails. Say so a week ahead.
if [[ -n "$published" ]]; then
    age_days="$(python3 -I -c '
import datetime, sys
published = datetime.datetime.fromisoformat(sys.argv[1].replace("Z", "+00:00"))
print((datetime.datetime.now(datetime.timezone.utc) - published).days)
' "$published")"
    if (( age_days >= 23 )); then
        echo "warning: pre-release MarmotKit $tag is $age_days days old; upstream deletes it at 30. Run \`just sync-rc\`." >&2
    fi
fi
echo "MarmotKit $tag is a pre-release; allowed on '$branch', never on master."
