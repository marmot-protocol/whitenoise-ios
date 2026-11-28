# Release workflow

Each shipped app version/build must map to an immutable annotated Git tag on
its exact `master` commit. Build the distribution archive from that commit so
the tag identifies the source that shipped. See [docs/release-flow.md](release-flow.md)
for the `develop` RC → staging tag → `release/X.Y.Z` → Stable promotion flow.

## Prepare the commit

1. Choose the tested staging tag from `develop` and branch `release/X.Y.Z` from
   it (or branch from the `v` tag on `master` for a production hotfix). Inspect
   the worktree and preserve unrelated edits and the user's chosen marketing
   version.
2. Set `MARKETING_VERSION` and increment `CURRENT_PROJECT_VERSION` consistently
   for the app and Notification Service Extension, in production and staging.
   Unit-test target versions are independent.
3. For an RC-based release branched from a staging tag, swap the staging RC pin
   for the Stable MarmotKit release MDK promoted from it using
   `just promote-stable` (`./scripts/promote-stable.sh`), and commit its
   generated Swift source, package binary pin/checksum, and provenance together.
   `promote-stable` refuses any Stable release not promoted from the tested RC.
   (For a hotfix branched from a Stable `master` tag, keep the existing Stable
   pin and skip `promote-stable`.) If the release advances the account storage
   schema (see the release's MDK integration guide), run "In-place MarmotKit
   upgrade" in `docs/manual-tests.md` on a device before release, and record its
   results in the release issue or PR.
4. Run `just precommit` (lint, MarmotKit provenance and channel checks, and the
   simulator test suite), a production Release device build, and
   `git diff --check` as described in `AGENTS.md`. Record results and whether
   code signing was enabled. Review `docs/manual-tests.md`; record pending
   checks explicitly and complete the relevant device checks before shipping.
5. Open a PR from `release/X.Y.Z` into `master`. CI enforces that `master` pins
   Stable MarmotKit only. After merging into `master`, create the annotated tag
   below and merge `master` back into `develop`. Do not tag an unmerged
   feature-branch commit.

## Publish the source checkpoint

- First shipment of a marketing version: `v<MARKETING_VERSION>` (for example,
  `v2026.9.5`).
- Later shipment with the same marketing version:
  `v<MARKETING_VERSION>-build.<CURRENT_PROJECT_VERSION>`.
- Create an annotated tag on the exact release commit. Its annotation records
  the app version/build, MarmotKit version, automated validation, and any pending
  signed-device/manual checks.
- Never move, delete, or overwrite a published release tag to point at a new
  build. Increment the build number and create a new tag instead.
- Push master and the specific tag, preferably with
  `git push --atomic origin master <tag>` so both refs publish together. Avoid
  `git push --tags`, which can publish unrelated local tags.
- Verify GitHub's master SHA and the annotated tag's peeled commit SHA match
  the intended release commit. A release bump is not finished until its tag
  is present on GitHub.

## Ship the tagged build

Archive and upload from the tagged source with the production signing settings.
For Ad Hoc device validation, use the production app and NSE provisioning
profiles. Check the archive's version/build and complete the relevant manual
checks before distributing it.

A source tag is a reproducibility checkpoint, not proof of upload or approval.
When publishing a GitHub Release or recording a TestFlight/App Store shipment,
reference the tag and record the actual distribution status, build number, and
device validation. Creating a tag does not itself require creating a GitHub
Release or uploading an app binary.
