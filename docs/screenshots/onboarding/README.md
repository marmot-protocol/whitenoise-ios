# Imported-account onboarding screenshots

These 320-pixel-wide PNGs (694–696 pixels tall) render the actual SwiftUI views with sample MDK snapshots
on an iPhone 17 Pro simulator. The sheets use their real presentation containers.
Screens are scrolled where needed to keep the active decision visible.
No real account data or live relay publication was used for these captures.

The UI source is the onboarding checkpoint `6007d98` plus the presentation
refinements in this PR. Temporary fixture injection and capture code are excluded
from the app and this PR. The profile values are
examples. These images document presentation, not end-to-end network validation.

Localization coverage was audited against 142 nonempty compiler-extracted keys from the
changed app files: English source strings plus complete translations for German,
Spanish, French, Italian, Portuguese, Russian, Turkish, Simplified Chinese, and
Traditional Chinese. The catalog tests also check translated values and format
placeholders across the shared catalog.

Validation: 1,702 tests in 212 suites passed on the Production scheme,
including runtime refresh failures, cancellation against quiet real MDK state,
and multiple unfinished identities. SwiftLint 0.63.2 passed in strict mode with
zero violations across 357 files. The plain-text resume action was rendered in
light/dark mode, accessibility text size 3, and with no pending setup. The unsafe
relay proposal capture verifies that publication is disabled and no unsafe address
is rendered. Signed-device/live-relay and accessibility manual checks remain pending.

## Progress and completion

- [Checks running](checking.png) — The active step shows a spinner while later steps wait.
- [Optional follows skipped](follows-skipped.png) — Missing or unreadable follows are skipped without publishing a replacement list.
- [KeyPackage publication](keypackage-publishing.png) — Initial publication runs after the single-device acknowledgment.
- [Ready to open Chats](ready.png) — MDK reports ready; optional skipped steps remain visibly distinct from passed checks.
- [Setup deferred](later.png) — Later returns to the existing app route with Sign Up above secondary Sign In and a plain-text Finish account setup action underneath, visible only when setup is pending.

## Optional profile setup

- [Profile prompt](profile-missing.png) — Update profile opens the shared sign-up form; Not now continues without changing the profile.
- [Profile editor sheet](profile-editor.png) — Example name and about text in the real presented sheet. Save publishes the entered details.
- [Profile save failure](profile-save-failed.png) — The sheet and entered values remain visible after a failed save.
- [Profile lookup failure](profile-lookup-failed.png) — Retry or continue without replacing an unreadable profile.

## Relay discovery and defaults

- [Relay-list recovery](relays-missing.png) — Look on another relay or explicitly publish the two White Noise defaults.
- [Inbox-relay recovery](inbox-missing.png) — The same choices with an explanation of inbox relay publication.
- [Discovery relay sheet](discovery-editor.png) — A discovery source is used only to find existing settings.
- [Invalid discovery URL](discovery-invalid.png) — Invalid input stays in the sheet with an error, before any lookup starts.
- [Inconclusive relay lookup](relay-lookup-failed.png) — Only another lookup or retry is offered; replacement publication stays unavailable.
- [Inconclusive inbox lookup](inbox-lookup-failed.png) — Inbox settings receive the same protection after a failed lookup.

## Single-device acknowledgment

- [No other installation found](device-none.png) — The button says Continue.
- [Possible other installation](device-possible.png) — The button says Continue anyway.
- [Discovery inconclusive](device-unknown.png) — Uncertainty is explained and the button says Continue anyway.

## Saved repairs and recovery

- [Invalid relay proposal](invalid-relay-proposal.png) — Any unsafe address blocks the whole publication; Back lets the user discard the proposal.

- [Restored relay proposal](relay-proposal-restored.png) — An unapproved saved proposal shows its exact destinations and requires an explicit action.
- [Restored inbox proposal](inbox-proposal-restored.png) — An unapproved inbox proposal is never automatically approved on restart.
- [Previously approved relay repair](relay-repair-retry.png) — Retry finishes the saved publication rather than generating a new proposal.
- [Previously approved profile repair](profile-repair-retry.png) — The checklist offers recovery for a saved profile update.
- [Frozen profile retry sheet](profile-retry-sheet.png) — Already-approved fields stay fixed while retrying the saved publication.
- [KeyPackage publication failure](keypackage-failed.png) — The failing step offers a retry without another initial-publication approval.
- [Signer unavailable](signer-unavailable.png) — Defensive error presentation; nsec imports normally use a local signer.
- [Setup connection failure](connection-failed.png) — The last snapshot stays visible with a reconnect action.
- [Cancellation in progress](cancelling.png) — Interrupted cancellation is resumed; the UI explains that the saved identity is retained.

