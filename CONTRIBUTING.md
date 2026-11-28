# Contributing to White Noise for iOS

How a change gets from an idea to TestFlight and the App Store. The [README](README.md) covers
building and testing; [AGENTS.md](AGENTS.md) holds the rules the code follows (architecture,
MarmotKit boundary, privacy, localization, tests) and is worth reading whether or not you are an
agent.

## Branches

| Branch | What it is | MarmotKit |
| --- | --- | --- |
| `develop` | Where work lands. Staging builds are cut from here. | the latest Release Candidate, bumped daily |
| `master` | What production ships. Changes only through releases and hotfixes. | Stable only |
| `feature/…`, `fix/…`, any name | Your work, branched from `develop` | whatever `develop` has |
| `release/X.Y.Z` | A staging tag on its way to production | Stable, after `just promote-stable` |
| `automation/marmotkit-rc` | The daily RC bump, opened by a workflow | the new RC |

So, for nearly everything:

```sh
git switch develop && git pull
git switch -c fix/composer-paste
# …work…
just precommit
git push -u origin fix/composer-paste   # then open a pull request into develop
```

## Pull requests

- **Target `develop`.** A pull request into `master` that pins a Release Candidate fails CI's
  "MarmotKit release channel" check; that is on purpose.
- **Sign your commits.** Every branch in this repository requires signed commits.
- **Run `just precommit` before you push.** It runs lint and localization catalog checks,
  MarmotKit provenance and channel checks, and the full test suite (`scripts/test.sh`).
  `just lint` and `just check-marmotkit` take seconds and catch most slips.
- **`Lint result` and `Tests result` must be green.** They are the required status checks on both
  `develop` and `master`.
- **Describe the problem and the fix** in a few plain sentences: what was wrong for a person
  using the app, and why this change fixes it.
- Keep `Shared/` extension-safe, avoid source-text assertions in tests, and follow
  [docs/ios-design.md](docs/ios-design.md) for UI changes. [AGENTS.md](AGENTS.md) lists the rest.

## The daily MarmotKit bump

MDK publishes at most one verified Release Candidate a day. The **MarmotKit RC bump** workflow
pins it on `automation/marmotkit-rc` and opens (or refreshes) one pull request into `develop`,
with the RC's impact, its breaking binding changes and its database migrations.

- A **`patch`** RC with no breaking changes merges once CI is green.
- A **`minor`** RC may not compile. Check out `automation/marmotkit-rc`, read MDK's
  [integration notes](https://github.com/marmot-protocol/mdk/blob/rc-meta/rc/integration-notes.md),
  fix the call sites there, and merge. Once the branch has your commits the workflow stops
  replacing it and comments on the pull request when a newer RC is out; `just sync-rc` on the
  branch moves it along.
- `just sync-rc` does the same on your machine.

RCs are deleted upstream after 30 days and may migrate account databases one way. Test them with
`Whitenoise (Staging)`, whose App Group container never touches production data.

## Staging and production

Cut staging builds from `develop` and tag each one you hand out. To ship one, branch
`release/X.Y.Z` from its tag, run `just promote-stable`, and open a pull request into `master`.
Tag the release commit on `master` (see [docs/releases.md](docs/releases.md)) and merge `master`
back into `develop` afterwards. [docs/release-flow.md](docs/release-flow.md) has every step,
including hotfixes and what to do when MDK promoted a different RC from the one you tested.

## Privacy

White Noise is a private messenger. Never log message text, keys, group ids or other content,
in the app, in tests or in scripts.
