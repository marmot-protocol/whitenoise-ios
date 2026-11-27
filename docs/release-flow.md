# Release flow and MarmotKit channels

MDK publishes MarmotKit on two channels:

- **Release Candidates** (`marmotkit-vX.Y.Z-rc.N`), one a day at most, each written to
  `rc-meta:rc/latest.json` only after Canary, simulator-nightly, convergence-hardening and every
  artifact build pass. They are GitHub pre-releases and **upstream deletes them after 30 days**.
- **Stable** (`marmotkit-vX.Y.Z`), promoted by hand from one verified RC (MDK's
  `promote-release.yml`): built from a release commit whose parent is that RC's source commit and
  which changes only release metadata. Stable releases are permanent.

White Noise for iOS keeps each one on its own branch.

| Branch | Pins | Builds |
| --- | --- | --- |
| `develop` | the latest RC, bumped daily | `Whitenoise (Staging)` for testers |
| `master` | Stable only (CI enforces it) | `Whitenoise (Production)` (TestFlight / App Store) |

## Day to day: `develop`

- Feature branches start from `develop` and merge back into it.
- The **MarmotKit RC bump** workflow (`.github/workflows/marmotkit-rc-bump.yml`) runs
  `scripts/sync-rc.sh` daily. When `rc/latest.json` names a new RC it opens, or refreshes, one PR
  into `develop` (`automation/marmotkit-rc`), with the impact, the breaking UniFFI changes, the
  storage migrations and a link to MDK's integration notes. A rerun with no new RC changes nothing.
- A `patch` RC with no breaking UniFFI changes should merge as is once CI is green. A `minor` RC
  may not compile: check out `automation/marmotkit-rc`, read
  [rc/integration-notes.md](https://github.com/marmot-protocol/mdk/blob/rc-meta/rc/integration-notes.md),
  fix the call sites on that branch, then merge. Once the branch holds hand-made commits (without
  the `MarmotKit-RC-Bump: true` trailer), the workflow stops replacing it and comments on the PR
  when a newer RC is out.
- `just sync-rc` (or `./scripts/sync-rc.sh`) locally does the same thing by hand. It refuses to
  run on `master`, and refuses an RC older than the current pin.

## Staging builds

Cut staging builds (`Whitenoise (Staging)`) from `develop` and tag each one you hand out, for
example `staging/2026.11.27-1`. The tag records the exact RC pinned
(`Packages/MarmotKit/MARMOT_VERSION`).

A staging tag can only be rebuilt while its RC exists (30 days). Keep the built archive; don't
plan on rebuilding an old staging tag.

## Shipping to production: `master`

1. Choose the staging tag to ship, and note its RC (say `0.20.0-rc.4`).
2. Ask MDK to promote **that** RC to Stable, or confirm they already have. If MDK promoted a
   different RC, the Stable binary isn't the one testers ran: pin that RC on `develop`, cut and
   test a new staging build, and start again. If `develop` has already moved past the promoted RC
   (for example `develop` pins `rc.5` while MDK promoted `rc.4`), `sync-rc` only moves forward and
   a staging database migrated by `rc.5` may reject the older build — cut and test the promoted RC
   from a staging tag that pinned it (or an isolated branch and clean staging install) rather than
   downgrading migrated staging data.
3. Branch from the staging tag (`release/X.Y.Z`), bump `MARKETING_VERSION` and
   `CURRENT_PROJECT_VERSION` if needed (see [docs/releases.md](releases.md)), run
   `just promote-stable` (`./scripts/promote-stable.sh`), and open a PR into `master`.
   `promote-stable` pins Stable `X.Y.Z`, and refuses it unless its source is the RC's source or
   the single release-metadata commit on top of it. It prints how many generated Swift lines
   changed; expect version strings at most.
4. CI (`MarmotKit release channel`, in both `Lint` and `Tests`) fails any push to `master` or PR
   into `master` that pins anything but Stable.
5. Merge, create the immutable annotated release tag on `master` (see
   [docs/releases.md](releases.md)), and build the production archive from that tag.
6. Merge `master` back into `develop`. The next RC bump moves `develop` back onto RCs, and is
   never older than the Stable it replaces: `sync-rc` refuses a downgrade.

A production hotfix branches from the `v` tag on `master`, keeps the Stable pin, merges into
`master` (with a new annotated tag), then merges back into `develop`.

## Data

Production and Staging use separate App Group containers (`group.dev.ipf.whitenoise.ios` vs.
`group.dev.ipf.whitenoise.ios.staging`), bundle identifiers, and URL schemes, so an RC's one-way
account database migration in Staging never touches Production data. Production only ever opens
a database with a Stable release.

## Repository setup

- `develop` is the default branch, so pull requests target it and GitHub runs the scheduled RC
  bump from its copy of the workflow.
- The "safe master" ruleset targets `refs/heads/master` and `refs/heads/develop` explicitly: no
  deletion or force-push, pull requests only, `Lint result` and `Tests result` required. Keep the
  branch names explicit: a ruleset targeting `~DEFAULT_BRANCH` would leave `master` unprotected
  when the default moves.
- Every branch requires signed commits. The bump workflow commits through GitHub's API
  (`scripts/ci/signed-commit.py`), which GitHub signs, and marks its commits with a
  `MarmotKit-RC-Bump: true` trailer so it can tell them from people's.
- The `MARMOTKIT_BUMP_TOKEN` secret holds a fine-grained token (`whitenoise-ios` only, Contents
  and Pull requests read/write). A pull request opened with the default `GITHUB_TOKEN` starts no
  other workflows, so without it the bump pull request gets no CI.
