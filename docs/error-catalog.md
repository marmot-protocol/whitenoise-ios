# White Noise iOS error catalog

Snapshot: **2026-09-10**. This is an inventory for a later copy review; it does not propose or implement new messages.

## Scope and provenance

- iOS base commit: `8c925775cb11f4ded4b1cb0a96d547e7e6f0ef62`, plus the current uncommitted binding adoption and error-formatting work. This records the working tree, not just that commit.
- Installed MDK source: `fdd398a80f1626f1713787cebe416f7890b5b204`, published MarmotKit 0.9.21 with OTLP and product analytics exporters enabled. The release-preparation commit did not change the cataloged error declarations or bridge mappings.
- Scope: the main iOS app, shared host errors, the entire generated `MarmotKitError` enum, and core MDK error declarations feeding the native bridge. Android UI, macOS UI, server errors, and notification-extension-only presentation are outside this document.
- English strings are source catalog keys/templates. The app can localize host messages. Rust details may contain runtime values and generally are not localized by the host.
- A finite list of every possible **rendered string** is not possible: relay responses, OS errors, nested library errors, identifiers, and formatted values are open-ended. The declared native error list is exhaustive for this snapshot; source templates and presentation call sites are inventories, not proof that every branch can occur on every screen.
- Source links for MDK are pinned to the exact commit. iOS links refer to absolute files in the local working-tree snapshot, with line numbers where available; they require this checkout to open. The message text itself is included here for review without following links.

Inventory counts: **60 native MarmotKit cases**, **75 AppError declarations**, **118 nested core declarations**, **28 iOS error types**, and **109 presentation call sites**.

## Contents

1. [Current presentation rules](#current-presentation-rules)
2. [Complete native error list](#complete-native-error-list)
3. [Screen-specific overrides](#screen-specific-overrides)
4. [Runtime details and their origins](#runtime-details-and-their-origins)
5. [iOS-defined errors](#ios-defined-errors)
6. [Presentation call-site index](#presentation-call-site-index)
7. [Static failure messages](#static-failure-messages)
8. [Review boundaries](#review-boundaries)

## Current presentation rules

The shared formatter is [UserFacingError.swift](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Core/UserFacingError.swift).

1. Unwrap `RelaySettingsSaveFailure` to its underlying error.
2. Apply existing duplicate-identity, account-setup, and send-specific messages when matched.
3. Otherwise use an explicit operation fallback when one was supplied; then use a typed MarmotKit `details` value or a non-Marmot error's localized description. If empty or unavailable, show **“Please try again.”**
4. Redact nsec-shaped input and long hexadecimal strings, bound raw text to 4,000 characters before capitalization, trim surrounding whitespace, and capitalize the first letter without changing the rest of the text. Opening punctuation is preserved. Shared toast titles are capitalized too.
5. A shared toast preserves its operation title. A separate expandable diagnostic is omitted when it would repeat the message. Some callers build their own toast from a presentation, so that omission is not universal.
6. Retry/ignore/invite behavior belongs to the caller. A generic fallback in this catalog does **not** establish that retrying the operation is safe.

The generated UniFFI `LocalizedError.errorDescription` still uses `String(reflecting: self)`. iOS now extracts typed details before display; the generated file has not been hand-edited.

## Complete native error list

The following table lists every generated Swift `MarmotKitError` case. **Details** means the supplied `details` string after the shared formatting above. **Fallback** means “Please try again.” unless a caller supplies a message or uses a screen-specific override. The Rust display template is reference material: it is not automatically the message shown by iOS.

| Swift case and fields | Rust display template | Shared iOS display | Declaration |
| --- | --- | --- | --- |
| `ConsentRequired` | usage and diagnostics consent required | Fallback | [crates/marmot-uniffi/src/errors.rs:8](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-uniffi/src/errors.rs#L8) |
| `InvalidProductAnalyticsConfiguration` | invalid product analytics configuration | Fallback | [crates/marmot-uniffi/src/errors.rs:10](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-uniffi/src/errors.rs#L10) |
| `InvalidProductObservation` | unregistered or invalid product observation | Fallback | [crates/marmot-uniffi/src/errors.rs:12](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-uniffi/src/errors.rs#L12) |
| `DuplicateIdentity(account: String)` | identity already exists: {account} | Identity already signed in on this device | [crates/marmot-uniffi/src/errors.rs:14](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-uniffi/src/errors.rs#L14) |
| `UnknownAccount(accountRef: String)` | unknown account: {account_ref} | Fallback | [crates/marmot-uniffi/src/errors.rs:16](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-uniffi/src/errors.rs#L16) |
| `UnknownGroup(groupIdHex: String)` | unknown group: {group_id_hex} | Fallback | [crates/marmot-uniffi/src/errors.rs:18](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-uniffi/src/errors.rs#L18) |
| `GroupInviteNotPending` | group invite is not pending | Fallback | [crates/marmot-uniffi/src/errors.rs:22](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-uniffi/src/errors.rs#L22) |
| `CreatedGroupProjectionUnavailable(groupIdHex: String)` | group was created but its local chat projection is unavailable: {group_id_hex} | Fallback | [crates/marmot-uniffi/src/errors.rs:26](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-uniffi/src/errors.rs#L26) |
| `InvalidGroupMembershipPage(maxGroups: UInt64)` | group membership page exceeds the maximum of {max_groups} groups | Fallback | [crates/marmot-uniffi/src/errors.rs:28](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-uniffi/src/errors.rs#L28) |
| `InvalidCachedIdentityPage(maxAccounts: UInt64)` | cached identity page exceeds the maximum of {max_accounts} accounts | Fallback | [crates/marmot-uniffi/src/errors.rs:30](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-uniffi/src/errors.rs#L30) |
| `GroupHydrationPending(groupIdHex: String)` | group hydration pending: {group_id_hex} | Fallback | [crates/marmot-uniffi/src/errors.rs:37](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-uniffi/src/errors.rs#L37) |
| `DirectConversationIndexNotReady` | direct conversation index is not ready; retry after account hydration | Fallback | [crates/marmot-uniffi/src/errors.rs:43](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-uniffi/src/errors.rs#L43) |
| `ChatPresentationNotReady` | chat presentation preparation is incomplete; retry after local maintenance | Fallback | [crates/marmot-uniffi/src/errors.rs:45](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-uniffi/src/errors.rs#L45) |
| `InvalidChatPin(details: String)` | invalid chat pin: {details} | Details | [crates/marmot-uniffi/src/errors.rs:47](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-uniffi/src/errors.rs#L47) |
| `InvalidMessageDraft(details: String)` | invalid message draft: {details} | Details | [crates/marmot-uniffi/src/errors.rs:50](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-uniffi/src/errors.rs#L50) |
| `InvalidMediaReference(details: String)` | invalid media reference: {details} | Details | [crates/marmot-uniffi/src/errors.rs:54](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-uniffi/src/errors.rs#L54) |
| `InvalidHex(details: String)` | invalid hex: {details} | Details | [crates/marmot-uniffi/src/errors.rs:56](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-uniffi/src/errors.rs#L56) |
| `InvalidIdentity(details: String)` | invalid nostr identity: {details} | Details | [crates/marmot-uniffi/src/errors.rs:58](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-uniffi/src/errors.rs#L58) |
| `InvalidKeyPackageEvent(details: String)` | invalid key package event: {details} | Details | [crates/marmot-uniffi/src/errors.rs:63](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-uniffi/src/errors.rs#L63) |
| `MissingKeyPackage(account: String)` | missing key package for {account} | Fallback | [crates/marmot-uniffi/src/errors.rs:65](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-uniffi/src/errors.rs#L65) |
| `MissingMemberInboxRoute(account: String)` | member {account} has no valid Marmot inbox relay | Fallback | [crates/marmot-uniffi/src/errors.rs:70](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-uniffi/src/errors.rs#L70) |
| `Publish(details: String)` | publish failed: {details} | Details | [crates/marmot-uniffi/src/errors.rs:72](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-uniffi/src/errors.rs#L72) |
| `FollowListUnavailable` | current account follow list is unavailable | Your follow list is unavailable from relays. Check your connection and relay settings, then try again. No follows were changed. | [crates/marmot-uniffi/src/errors.rs:77](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-uniffi/src/errors.rs#L77) |
| `TransportClosed` | transport closed | Fallback | [crates/marmot-uniffi/src/errors.rs:79](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-uniffi/src/errors.rs#L79) |
| `RuntimeBusy` | marmot runtime root is already in use | Fallback | [crates/marmot-uniffi/src/errors.rs:84](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-uniffi/src/errors.rs#L84) |
| `AccountSessionBusy` | marmot account session is already in use | Fallback | [crates/marmot-uniffi/src/errors.rs:88](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-uniffi/src/errors.rs#L88) |
| `AccountSetupRecoveryRequired` | incomplete account setup requires explicit recovery | Incomplete identity setup needs approval to recover. | [crates/marmot-uniffi/src/errors.rs:93](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-uniffi/src/errors.rs#L93) |
| `AccountSetupRetryRequired` | durable account setup can be resumed by retrying | Identity setup can be resumed. Try importing again. | [crates/marmot-uniffi/src/errors.rs:95](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-uniffi/src/errors.rs#L95) |
| `OnboardingActionUnavailable` | onboarding action is unavailable or stale | Setup changed. Review the latest options and try again. | [crates/marmot-uniffi/src/errors.rs:97](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-uniffi/src/errors.rs#L97) |
| `OnboardingRequired` | account must complete interactive onboarding | Finish account setup before using this account. | [crates/marmot-uniffi/src/errors.rs:99](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-uniffi/src/errors.rs#L99) |
| `AccountSetupResetNotApplicable` | account is not eligible for incomplete-setup reset | This incomplete identity setup could not be recovered. | [crates/marmot-uniffi/src/errors.rs:101](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-uniffi/src/errors.rs#L101) |
| `AccountSetupKeyPackageRecoveryAvailable` | recoverable KeyPackage setup state exists; retry instead of resetting | Identity setup can be resumed. Try importing again. | [crates/marmot-uniffi/src/errors.rs:103](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-uniffi/src/errors.rs#L103) |
| `RuntimeStopping` | marmot runtime is shutting down | Fallback | [crates/marmot-uniffi/src/errors.rs:105](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-uniffi/src/errors.rs#L105) |
| `AccountCatchUp(details: String)` | account catch-up failed: {details} | Details | [crates/marmot-uniffi/src/errors.rs:112](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-uniffi/src/errors.rs#L112) |
| `NotGroupAdmin(groupIdHex: String)` | local account is not an admin of group {group_id_hex} | Fallback | [crates/marmot-uniffi/src/errors.rs:114](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-uniffi/src/errors.rs#L114) |
| `AdminCannotSelfRemove(groupIdHex: String)` | admin must self-demote before leaving group {group_id_hex} | Fallback | [crates/marmot-uniffi/src/errors.rs:116](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-uniffi/src/errors.rs#L116) |
| `LeaveAlreadyRequested(groupIdHex: String)` | a leave request is already pending for group {group_id_hex} | Fallback | [crates/marmot-uniffi/src/errors.rs:122](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-uniffi/src/errors.rs#L122) |
| `WouldRemoveLastAdmin(groupIdHex: String)` | operation would remove the last admin from group {group_id_hex} | Fallback | [crates/marmot-uniffi/src/errors.rs:124](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-uniffi/src/errors.rs#L124) |
| `DisbandingUnsupportedMembers(groupIdHex: String, memberIdsHex: [String])` | group {group_id_hex} cannot enable disbanding until all members support it | Fallback | [crates/marmot-uniffi/src/errors.rs:126](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-uniffi/src/errors.rs#L126) |
| `DisbandingNotEnabled(groupIdHex: String)` | group {group_id_hex} has not enabled disbanding | Fallback | [crates/marmot-uniffi/src/errors.rs:131](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-uniffi/src/errors.rs#L131) |
| `GroupDisbanding(groupIdHex: String)` | group {group_id_hex} is disbanding or disbanded | Fallback | [crates/marmot-uniffi/src/errors.rs:133](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-uniffi/src/errors.rs#L133) |
| `GroupRemoved(groupIdHex: String)` | this device was removed from group {group_id_hex} | You were removed from this group and can no longer send messages here. | [crates/marmot-uniffi/src/errors.rs:138](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-uniffi/src/errors.rs#L138) |
| `MemberNotInGroup(groupIdHex: String, memberIdHex: String)` | member {member_id_hex} is not in group {group_id_hex} | Fallback | [crates/marmot-uniffi/src/errors.rs:140](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-uniffi/src/errors.rs#L140) |
| `AlreadyAdmin(groupIdHex: String, memberIdHex: String)` | member {member_id_hex} is already an admin of group {group_id_hex} | Fallback | [crates/marmot-uniffi/src/errors.rs:145](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-uniffi/src/errors.rs#L145) |
| `NotAdmin(groupIdHex: String, memberIdHex: String)` | member {member_id_hex} is not an admin of group {group_id_hex} | Fallback | [crates/marmot-uniffi/src/errors.rs:150](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-uniffi/src/errors.rs#L150) |
| `StorageBusy(details: String)` | storage busy: {details} | Details | [crates/marmot-uniffi/src/errors.rs:161](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-uniffi/src/errors.rs#L161) |
| `StorageClosed(details: String)` | storage closed: {details} | Details | [crates/marmot-uniffi/src/errors.rs:172](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-uniffi/src/errors.rs#L172) |
| `SecretNotFound(details: String)` | account secret not found: {details} | Details | [crates/marmot-uniffi/src/errors.rs:179](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-uniffi/src/errors.rs#L179) |
| `KeystoreUnavailable(details: String)` | account keystore unavailable: {details} | Details | [crates/marmot-uniffi/src/errors.rs:185](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-uniffi/src/errors.rs#L185) |
| `EmptyPassphrase` | passphrase cannot be empty | Fallback | [crates/marmot-uniffi/src/errors.rs:190](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-uniffi/src/errors.rs#L190) |
| `EncryptionFailed(details: String)` | encrypted secret-key export failed: {details} | Details | [crates/marmot-uniffi/src/errors.rs:194](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-uniffi/src/errors.rs#L194) |
| `Io(details: String)` | io error: {details} | Details | [crates/marmot-uniffi/src/errors.rs:200](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-uniffi/src/errors.rs#L200) |
| `ExternalSignerUnavailable(account: String)` | external signer unavailable for account {account} | Fallback | [crates/marmot-uniffi/src/errors.rs:205](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-uniffi/src/errors.rs#L205) |
| `ExternalSignerMismatch` | external signer public key does not match account | Fallback | [crates/marmot-uniffi/src/errors.rs:210](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-uniffi/src/errors.rs#L210) |
| `ExternalSignerRejected` | external signer request was rejected or cancelled | Fallback | [crates/marmot-uniffi/src/errors.rs:215](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-uniffi/src/errors.rs#L215) |
| `GroupSendQueueFull(groupIdHex: String)` | group {group_id_hex} has too many messages waiting to be sent | This chat is still catching up. Wait for it to finish, then resend your message. | [crates/marmot-uniffi/src/errors.rs:228](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-uniffi/src/errors.rs#L228) |
| `GroupUnrecoverableRepairRequired(groupIdHex: String)` | group {group_id_hex} is unrecoverable and needs to be re-joined before sending | This conversation needs to be rejoined before you can send messages. | [crates/marmot-uniffi/src/errors.rs:237](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-uniffi/src/errors.rs#L237) |
| `Runtime(details: String)` | marmot runtime error: {details} | Details | [crates/marmot-uniffi/src/errors.rs:239](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-uniffi/src/errors.rs#L239) |
| `AccountWorkerBusy` | marmot account worker is busy catching up; operation was not started | This account is still catching up. Try again in a moment. | [crates/marmot-uniffi/src/errors.rs:244](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-uniffi/src/errors.rs#L244) |
| `AccountWorkerResponseTimedOut` | marmot account worker response timed out; operation completion is unknown | The operation may have completed. Refreshing the conversation is required before retrying. | [crates/marmot-uniffi/src/errors.rs:248](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-uniffi/src/errors.rs#L248) |

## Screen-specific overrides

These take precedence only on the named path. Other uses of the same typed error may display different text.

| Path | Error / condition | Current English copy or behavior |
| --- | --- | --- |
| Direct chat start | `MissingKeyPackage`, `InvalidKeyPackageEvent`, `InvalidIdentity` | Invite flow: “{name} isn't on White Noise yet. Share the app so you can chat securely.” Without a name: “They aren't on White Noise yet. Share the app so you can chat securely.” |
| Direct chat start | `Runtime(details:)`, other errors | Retryable error prompt using the shared readable message; it does not infer an incompatible KeyPackage classification from the string. |
| New group | `MissingKeyPackage(account:)` | “{short npub} hasn't published a compatible key package, so they can't be added yet.” |
| New group | Other failures | Inline shared message; toast title “Couldn't create chat”; selection remains for retry. |
| Add members | Submission failure | Inline shared message; retain the selection and sheet. |
| Group management | `NotGroupAdmin` | “Only admins can manage group members.” |
| Group management | `AdminCannotSelfRemove` | “Step down as admin before leaving the group.” |
| Group management | `WouldRemoveLastAdmin` | “Make another member an admin before removing the last admin.” |
| Group management | `DisbandingUnsupportedMembers` | “{count} members must update White Noise before you can end this group.” (localized plural) |
| Group management | `DisbandingNotEnabled` | “Group ending isn't ready yet. Try again.” |
| Group management | `LeaveAlreadyRequested`, `GroupDisbanding` | “Leaving group…” / “This group is ending. New messages are disabled.” |
| Group management | `MemberNotInGroup` | “That member is no longer in this group.” |
| Group management | `AlreadyAdmin` / `NotAdmin` | “That member is already an admin.” / “That member is not an admin.” |
| Group management | `MissingKeyPackage(account:)` | “{short identity} hasn't published a compatible key package yet.” |
| Private-key export | `EmptyPassphrase` | “Enter a passphrase.” |
| Private-key export | `SecretNotFound` | “This account cannot export a private key.” |
| Private-key export | `KeystoreUnavailable` | “The account keystore is unavailable right now.” |
| Private-key export | `EncryptionFailed(details:)` | “Encrypted export failed: {shared readable details}” |
| Identity import fallback | `InvalidIdentity` | “That private key isn't valid. Check it and try again.” |
| Identity import fallback | `Publish` | “Identity setup can be resumed. Try importing again.” |
| Identity import fallback | Other, without a higher-priority shared override | “Retry”; readable diagnostics may be available separately. |

Sources: [direct-chat routing](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Recipients/DirectChatStarter.swift), [new-group creation](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Chats/NewChatFlowViewModel.swift), [Add Members](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Group/AddMembersSheetViewModel.swift), [group action messages](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Group/GroupDetailsViewModel.swift), [group progress copy](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Group/GroupManagementPresentation.swift), [key export](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Settings/IdentityKeyExportPresentation.swift), [identity import](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Onboarding/ImportIdentityViewModel.swift).

## Runtime details and their origins

The native bridge first checks whether an `AppError` contains an engine error. It maps recognized conditions to typed cases; unmatched engine errors become `Runtime(details: engineError.to_string())`. Otherwise it maps recognized `AppError` cases and converts unmatched cases into `Runtime(details: appError.to_string())`.

For example, the recently encountered recipient failure is:

- Rust: `EngineError::InvalidKeyPackageCapabilities { member }`.
- Source display: `invalid KeyPackage capabilities: recipient must generate a new conforming KeyPackage`.
- Native case: `Runtime(details:)` in this snapshot.
- Shared iOS display: **“Invalid KeyPackage capabilities: recipient must generate a new conforming KeyPackage”**.
- The native error carries no typed “recipient must upgrade” discriminator here. This is the current message, not a proposed rewrite.

`{0}`, `{details}`, `{name}`, and Rust format markers in the tables below are templates, not literal user text. `transparent` forwards another error's display. A `String` argument may come from a literal validation reason, a formatted message, or another library's error; it has no closed list of values.

Bridge source: [crates/marmot-uniffi/src/errors.rs:251](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-uniffi/src/errors.rs#L251).

### AppError declarations and bridge routing

| AppError variant | Source display template | Native route | Source |
| --- | --- | --- | --- |
| `ProductAnalytics(#[from] crate::ProductAnalyticsError)` | transparent | ConsentRequired / InvalidProductAnalyticsConfiguration / InvalidProductObservation | [crates/marmot-app/src/error.rs:38](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-app/src/error.rs#L38) |
| `Account(#[from] marmot_account::AccountError)` | transparent | Engine-containing errors use engine mapping first; otherwise Runtime | [crates/marmot-app/src/error.rs:40](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-app/src/error.rs#L40) |
| `AccountHome(#[from] AccountHomeError)` | transparent | Conditional: UnknownAccount, DuplicateIdentity, SecretNotFound, KeystoreUnavailable, EmptyPassphrase, EncryptionFailed, Io; other variants → Runtime | [crates/marmot-app/src/error.rs:42](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-app/src/error.rs#L42) |
| `Session(#[from] cgka_session::SessionError)` | transparent | Engine-containing errors use engine mapping first; otherwise Runtime | [crates/marmot-app/src/error.rs:44](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-app/src/error.rs#L44) |
| `Storage(#[from] cgka_traits::storage::StorageError)` | transparent | StorageBusy if transient; StorageClosed if closed; otherwise Runtime | [crates/marmot-app/src/error.rs:46](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-app/src/error.rs#L46) |
| `Transport(TransportAdapterError)` | transparent | Runtime | [crates/marmot-app/src/error.rs:48](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-app/src/error.rs#L48) |
| `Io(#[from] std::io::Error)` | transparent | Io | [crates/marmot-app/src/error.rs:50](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-app/src/error.rs#L50) |
| `Json(#[from] serde_json::Error)` | transparent | Runtime | [crates/marmot-app/src/error.rs:52](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-app/src/error.rs#L52) |
| `Sqlite(#[from] rusqlite::Error)` | transparent | Runtime | [crates/marmot-app/src/error.rs:54](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-app/src/error.rs#L54) |
| `Hex(#[from] hex::FromHexError)` | transparent | InvalidHex | [crates/marmot-app/src/error.rs:56](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-app/src/error.rs#L56) |
| `MissingKeyPackage(String)` | no published key package for account | MissingKeyPackage | [crates/marmot-app/src/error.rs:58](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-app/src/error.rs#L58) |
| `MissingMemberInboxRoute(String)` | member has no valid Marmot inbox relay | MissingMemberInboxRoute | [crates/marmot-app/src/error.rs:63](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-app/src/error.rs#L63) |
| `UnknownGroup(String)` | unknown local group | UnknownGroup | [crates/marmot-app/src/error.rs:65](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-app/src/error.rs#L65) |
| `GroupInviteNotPending` | group invite is not pending | GroupInviteNotPending | [crates/marmot-app/src/error.rs:70](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-app/src/error.rs#L70) |
| `CreatedGroupProjectionUnavailable(String)` | group was created but its local chat projection is unavailable | CreatedGroupProjectionUnavailable | [crates/marmot-app/src/error.rs:75](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-app/src/error.rs#L75) |
| `InvalidGroupMembershipPage(String)` | invalid group membership page: {0} | InvalidGroupMembershipPage | [crates/marmot-app/src/error.rs:77](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-app/src/error.rs#L77) |
| `DirectConversationIndexNotReady` | direct conversation index is not ready; retry after account hydration | DirectConversationIndexNotReady | [crates/marmot-app/src/error.rs:81](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-app/src/error.rs#L81) |
| `ChatPresentationNotReady` | chat presentation preparation is incomplete; retry after local maintenance | ChatPresentationNotReady | [crates/marmot-app/src/error.rs:83](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-app/src/error.rs#L83) |
| `InvalidCachedIdentityPage(String)` | invalid cached identity page: {0} | InvalidCachedIdentityPage | [crates/marmot-app/src/error.rs:85](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-app/src/error.rs#L85) |
| `InvalidChatPin(String)` | invalid chat pin: {0} | InvalidChatPin | [crates/marmot-app/src/error.rs:87](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-app/src/error.rs#L87) |
| `GroupDisbanding(String)` | group is disbanding or disbanded; outbound work is blocked | GroupDisbanding | [crates/marmot-app/src/error.rs:89](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-app/src/error.rs#L89) |
| `GroupRemoved(String)` | this device was removed from the group; outbound work is blocked | GroupRemoved | [crates/marmot-app/src/error.rs:98](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-app/src/error.rs#L98) |
| `InvalidMessageDraft(String)` | invalid message draft: {0} | InvalidMessageDraft | [crates/marmot-app/src/error.rs:101](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-app/src/error.rs#L101) |
| `AgentStreamMissingStart` | no agent text stream start found for this group | Runtime | [crates/marmot-app/src/error.rs:103](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-app/src/error.rs#L103) |
| `AgentStreamPublisher(String)` | agent publisher: {0} | Runtime | [crates/marmot-app/src/error.rs:105](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-app/src/error.rs#L105) |
| `AgentStreamStartNotConfirmed` | agent text stream start has no confirmed message id yet | Runtime | [crates/marmot-app/src/error.rs:107](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-app/src/error.rs#L107) |
| `AgentStreamUnsupportedRoute` | unsupported agent text stream route (only brokered QUIC is supported) | Runtime | [crates/marmot-app/src/error.rs:109](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-app/src/error.rs#L109) |
| `AgentStreamMissingCandidate` | agent text stream start has no usable quic:// candidate | Runtime | [crates/marmot-app/src/error.rs:111](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-app/src/error.rs#L111) |
| `AgentStreamInvalidCandidate(String)` | invalid quic candidate: {0} | Runtime | [crates/marmot-app/src/error.rs:113](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-app/src/error.rs#L113) |
| `Publish(String)` | publish failed: {0} | Publish | [crates/marmot-app/src/error.rs:115](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-app/src/error.rs#L115) |
| `MissingDefaultRelays` | default relays are required to publish account relay lists | Runtime | [crates/marmot-app/src/error.rs:117](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-app/src/error.rs#L117) |
| `MissingRelayLists(Vec<MissingRelayListKind>)` | missing account relay lists: {0:?} | Runtime | [crates/marmot-app/src/error.rs:119](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-app/src/error.rs#L119) |
| `FollowListUnavailable` | current account follow list is unavailable | FollowListUnavailable | [crates/marmot-app/src/error.rs:125](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-app/src/error.rs#L125) |
| `RelayDirectory(String)` | relay directory fetch failed: {0} | Runtime | [crates/marmot-app/src/error.rs:127](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-app/src/error.rs#L127) |
| `AccountCatchUp(AccountCatchUpFailure)` | account catch-up failed: {0} | AccountCatchUp | [crates/marmot-app/src/error.rs:133](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-app/src/error.rs#L133) |
| `InvalidPublicKey` | invalid Nostr public key | InvalidIdentity | [crates/marmot-app/src/error.rs:135](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-app/src/error.rs#L135) |
| `UnexpectedPrivateKey` | this operation does not accept a private key | InvalidIdentity | [crates/marmot-app/src/error.rs:137](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-app/src/error.rs#L137) |
| `IdentityKeyMismatch` | public identity does not match the imported private key | InvalidIdentity | [crates/marmot-app/src/error.rs:139](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-app/src/error.rs#L139) |
| `ExternalSignerUnavailable(String)` | external signer unavailable for account | ExternalSignerUnavailable | [crates/marmot-app/src/error.rs:141](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-app/src/error.rs#L141) |
| `ExternalSignerMismatch` | external signer public key does not match account | ExternalSignerMismatch | [crates/marmot-app/src/error.rs:143](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-app/src/error.rs#L143) |
| `ExternalSignerRejected` | external signer request was rejected or cancelled by the user | ExternalSignerRejected | [crates/marmot-app/src/error.rs:145](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-app/src/error.rs#L145) |
| `InvalidKeyPackageEvent(String)` | invalid Marmot KeyPackage event: {0} | InvalidKeyPackageEvent | [crates/marmot-app/src/error.rs:147](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-app/src/error.rs#L147) |
| `MissingDirectoryEntry(String)` | no directory entry for account | Runtime | [crates/marmot-app/src/error.rs:149](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-app/src/error.rs#L149) |
| `InvalidDirectorySearch(String)` | invalid user directory search: {0} | Runtime | [crates/marmot-app/src/error.rs:151](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-app/src/error.rs#L151) |
| `InvalidGroupProfile(String)` | invalid group profile: {0} | Runtime | [crates/marmot-app/src/error.rs:153](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-app/src/error.rs#L153) |
| `InvalidNostrRouting(String)` | invalid Nostr routing component: {0} | Runtime | [crates/marmot-app/src/error.rs:155](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-app/src/error.rs#L155) |
| `InvalidGroupAvatarUrl(String)` | invalid group avatar URL: {0} | Runtime | [crates/marmot-app/src/error.rs:157](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-app/src/error.rs#L157) |
| `InvalidAgentTextStreamPolicy(String)` | invalid agent text stream policy: {0} | Runtime | [crates/marmot-app/src/error.rs:159](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-app/src/error.rs#L159) |
| `InvalidEncryptedMedia(String)` | invalid encrypted media: {0} | InvalidMediaReference | [crates/marmot-app/src/error.rs:161](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-app/src/error.rs#L161) |
| `BlobStore(String)` | blob store request failed: {0} | Runtime | [crates/marmot-app/src/error.rs:163](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-app/src/error.rs#L163) |
| `MediaUploadTimedOut` | media upload timed out | Runtime | [crates/marmot-app/src/error.rs:168](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-app/src/error.rs#L168) |
| `UnsafeMediaFetch(String)` | unsafe media fetch: {0} | InvalidMediaReference | [crates/marmot-app/src/error.rs:171](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-app/src/error.rs#L171) |
| `InvalidAppMessagePayload(String)` | invalid app message payload: {0} | Runtime | [crates/marmot-app/src/error.rs:173](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-app/src/error.rs#L173) |
| `InvalidPushToken(String)` | invalid push token | Runtime | [crates/marmot-app/src/error.rs:175](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-app/src/error.rs#L175) |
| `InvalidPushServer(String)` | invalid push notification server | Runtime | [crates/marmot-app/src/error.rs:177](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-app/src/error.rs#L177) |
| `InvalidPushGossip(String)` | invalid push token gossip | Runtime | [crates/marmot-app/src/error.rs:179](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-app/src/error.rs#L179) |
| `InvalidRelayTelemetrySettings(String)` | invalid relay telemetry settings: {0} | Runtime | [crates/marmot-app/src/error.rs:181](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-app/src/error.rs#L181) |
| `InvalidAuditLogFile(String)` | invalid audit log file: {0} | Runtime | [crates/marmot-app/src/error.rs:183](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-app/src/error.rs#L183) |
| `AuditLogUpload(String)` | audit log upload failed: {0} | Runtime | [crates/marmot-app/src/error.rs:185](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-app/src/error.rs#L185) |
| `NotificationsDisabled` | local notifications are disabled | Runtime | [crates/marmot-app/src/error.rs:187](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-app/src/error.rs#L187) |
| `SqlcipherKeyDerivation(String)` | SQLCipher key derivation failed: {0} | Runtime | [crates/marmot-app/src/error.rs:189](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-app/src/error.rs#L189) |
| `BlockingTask(String)` | blocking app task failed: {0} | Runtime | [crates/marmot-app/src/error.rs:191](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-app/src/error.rs#L191) |
| `RuntimeBusy` | marmot runtime root is already in use | RuntimeBusy | [crates/marmot-app/src/error.rs:196](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-app/src/error.rs#L196) |
| `AccountSessionBusy` | marmot account session is already in use | AccountSessionBusy | [crates/marmot-app/src/error.rs:200](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-app/src/error.rs#L200) |
| `AccountWorkerBusy` | marmot account worker is busy catching up; operation was not started | AccountWorkerBusy | [crates/marmot-app/src/error.rs:204](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-app/src/error.rs#L204) |
| `AccountWorkerResponseTimedOut` | marmot account worker response timed out; operation completion is unknown | AccountWorkerResponseTimedOut | [crates/marmot-app/src/error.rs:209](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-app/src/error.rs#L209) |
| `AccountSetupRecoveryRequired` | incomplete account setup requires explicit recovery because prior KeyPackage exposure cannot be ruled out | AccountSetupRecoveryRequired | [crates/marmot-app/src/error.rs:217](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-app/src/error.rs#L217) |
| `AccountSetupRetryRequired` | durable account setup can be resumed by retrying the original operation | AccountSetupRetryRequired | [crates/marmot-app/src/error.rs:219](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-app/src/error.rs#L219) |
| `OnboardingActionUnavailable` | onboarding action is unavailable or stale | OnboardingActionUnavailable | [crates/marmot-app/src/error.rs:221](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-app/src/error.rs#L221) |
| `OnboardingRequired` | account must complete interactive onboarding | OnboardingRequired | [crates/marmot-app/src/error.rs:223](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-app/src/error.rs#L223) |
| `AccountSetupResetNotApplicable` | account is not in the legacy incomplete-setup reset state | AccountSetupResetNotApplicable | [crates/marmot-app/src/error.rs:225](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-app/src/error.rs#L225) |
| `AccountSetupKeyPackageRecoveryAvailable` | recoverable KeyPackage setup state exists; retry instead of resetting | AccountSetupKeyPackageRecoveryAvailable | [crates/marmot-app/src/error.rs:227](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-app/src/error.rs#L227) |
| `RuntimeStopping` | marmot runtime is shutting down | RuntimeStopping | [crates/marmot-app/src/error.rs:229](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-app/src/error.rs#L229) |
| `ReactionNotFound` | no matching reaction by this account to retract | Runtime | [crates/marmot-app/src/error.rs:231](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-app/src/error.rs#L231) |
| `TransportClosed` | transport event stream closed | TransportClosed | [crates/marmot-app/src/error.rs:233](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-app/src/error.rs#L233) |

### Core nested error declarations

All `#[error(...)]` declarations found in the production source enums under `marmot-account`, `cgka-session`, `traits`, and additional `marmot-app` error enums are included below. These define possible nested sources; not every variant necessarily reaches a visible iOS error. Engine mappings and storage guards can intercept them before the generic Runtime conversion. The separately declared `InvalidTransition` struct is also described after these enum tables. Third-party dependency error enumerations are not expanded.

#### AccountError

| Variant | Source display template | Handling boundary | Source |
| --- | --- | --- | --- |
| `Session(#[from] SessionError)` | transparent | Nested source; enclosing bridge mapping applies | [crates/marmot-account/src/error.rs:60](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-account/src/error.rs#L60) |
| `Engine(#[from] EngineError)` | transparent | Nested source; enclosing bridge mapping applies | [crates/marmot-account/src/error.rs:62](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-account/src/error.rs#L62) |
| `Transport(#[from] TransportAdapterError)` | transparent | Nested source; enclosing bridge mapping applies | [crates/marmot-account/src/error.rs:64](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-account/src/error.rs#L64) |
| `TransportRouting(#[from] TransportRoutingError)` | transparent | Nested source; enclosing bridge mapping applies | [crates/marmot-account/src/error.rs:66](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-account/src/error.rs#L66) |
| `KeyPackage(#[from] KeyPackagePublishError)` | transparent | Nested source; enclosing bridge mapping applies | [crates/marmot-account/src/error.rs:68](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-account/src/error.rs#L68) |
| `ClockSkewBlocked` | key package replacement is blocked by local clock skew | Nested source; enclosing bridge mapping applies | [crates/marmot-account/src/error.rs:70](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-account/src/error.rs#L70) |
| `KeyPackageRotationInProgress` | key package rotation is already in progress | Nested source; enclosing bridge mapping applies | [crates/marmot-account/src/error.rs:72](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-account/src/error.rs#L72) |
| `WrongAccountDelivery` | transport delivery was addressed to a different account | Nested source; enclosing bridge mapping applies | [crates/marmot-account/src/error.rs:74](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-account/src/error.rs#L74) |

#### AccountHomeError

| Variant | Source display template | Handling boundary | Source |
| --- | --- | --- | --- |
| `Io(#[from] std::io::Error)` | transparent | Nested source; enclosing bridge mapping applies | [crates/marmot-account/src/error.rs:17](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-account/src/error.rs#L17) |
| `Json(#[from] serde_json::Error)` | transparent | Nested source; enclosing bridge mapping applies | [crates/marmot-account/src/error.rs:19](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-account/src/error.rs#L19) |
| `Hex(#[from] hex::FromHexError)` | transparent | Nested source; enclosing bridge mapping applies | [crates/marmot-account/src/error.rs:21](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-account/src/error.rs#L21) |
| `AccountExists(String)` | account already exists: {0} | Nested source; enclosing bridge mapping applies | [crates/marmot-account/src/error.rs:23](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-account/src/error.rs#L23) |
| `AccountIdInUse(String)` | account id is already in use: {0} | Nested source; enclosing bridge mapping applies | [crates/marmot-account/src/error.rs:25](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-account/src/error.rs#L25) |
| `UnknownAccount(String)` | unknown account: {0} | Nested source; enclosing bridge mapping applies | [crates/marmot-account/src/error.rs:27](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-account/src/error.rs#L27) |
| `InvalidSecretKey` | invalid nsec or secret key | Nested source; enclosing bridge mapping applies | [crates/marmot-account/src/error.rs:29](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-account/src/error.rs#L29) |
| `InvalidPublicKey` | invalid Nostr public key | Nested source; enclosing bridge mapping applies | [crates/marmot-account/src/error.rs:31](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-account/src/error.rs#L31) |
| `InvalidAccountLabel(String)` | invalid account label: {0} | Nested source; enclosing bridge mapping applies | [crates/marmot-account/src/error.rs:33](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-account/src/error.rs#L33) |
| `AccountIdMismatch` | stored account id does not match stored secret key | Nested source; enclosing bridge mapping applies | [crates/marmot-account/src/error.rs:35](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-account/src/error.rs#L35) |
| `AccountSetupStateMissing` | durable account setup state is missing | Nested source; enclosing bridge mapping applies | [crates/marmot-account/src/error.rs:37](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-account/src/error.rs#L37) |
| `UnsupportedSecretBackend(String)` | unsupported account secret storage backend: {0} | Nested source; enclosing bridge mapping applies | [crates/marmot-account/src/error.rs:39](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-account/src/error.rs#L39) |
| `SecretStoreNotInitialized(String)` | account secret store is not initialized: {0} | Nested source; enclosing bridge mapping applies | [crates/marmot-account/src/error.rs:41](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-account/src/error.rs#L41) |
| `SecretStoreUnavailable(String)` | account secret store is unavailable: {0} | Nested source; enclosing bridge mapping applies | [crates/marmot-account/src/error.rs:43](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-account/src/error.rs#L43) |
| `SecretStore(String)` | account secret store operation failed: {0} | Nested source; enclosing bridge mapping applies | [crates/marmot-account/src/error.rs:45](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-account/src/error.rs#L45) |
| `SecretNotFound(String)` | account secret was not found | Nested source; enclosing bridge mapping applies | [crates/marmot-account/src/error.rs:47](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-account/src/error.rs#L47) |
| `EmptyPassphrase` | passphrase cannot be empty | Nested source; enclosing bridge mapping applies | [crates/marmot-account/src/error.rs:49](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-account/src/error.rs#L49) |
| `EncryptedSecretExport(String)` | encrypted secret-key export failed: {0} | Nested source; enclosing bridge mapping applies | [crates/marmot-account/src/error.rs:51](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-account/src/error.rs#L51) |
| `EmptySecretStoreService` | account secret store service name cannot be empty | Nested source; enclosing bridge mapping applies | [crates/marmot-account/src/error.rs:53](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-account/src/error.rs#L53) |

#### AgentTextStreamPolicyError

| Variant | Source display template | Handling boundary | Source |
| --- | --- | --- | --- |
| `EmptyRequiredRoles` | required agent text stream roles cannot be empty | Nested source; enclosing bridge mapping applies | [crates/traits/src/agent_text_stream.rs:230](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/traits/src/agent_text_stream.rs#L230) |
| `UnknownRequiredRoleBits(u8)` | required agent text stream role mask contains unknown bits: {0:#04x} | Nested source; enclosing bridge mapping applies | [crates/traits/src/agent_text_stream.rs:232](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/traits/src/agent_text_stream.rs#L232) |
| `UnknownAllowedRoleBits(u8)` | allowed agent text stream role mask contains unknown bits: {0:#04x} | Nested source; enclosing bridge mapping applies | [crates/traits/src/agent_text_stream.rs:234](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/traits/src/agent_text_stream.rs#L234) |
| `RequiredRolesNotAllowed` | required agent text stream roles must be a subset of allowed roles | Nested source; enclosing bridge mapping applies | [crates/traits/src/agent_text_stream.rs:236](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/traits/src/agent_text_stream.rs#L236) |
| `EmptyFrameLimit` | agent text stream plaintext frame limit cannot be zero | Nested source; enclosing bridge mapping applies | [crates/traits/src/agent_text_stream.rs:238](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/traits/src/agent_text_stream.rs#L238) |
| `InvalidComponentStateLength(usize)` | agent text stream component state must be 12 bytes, got {0} | Nested source; enclosing bridge mapping applies | [crates/traits/src/agent_text_stream.rs:240](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/traits/src/agent_text_stream.rs#L240) |
| `FrameLimitTooLarge(u32)` | agent text stream plaintext frame limit exceeds app profile max: {0} | Nested source; enclosing bridge mapping applies | [crates/traits/src/agent_text_stream.rs:242](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/traits/src/agent_text_stream.rs#L242) |
| `ReplayTtlTooLarge(u32)` | agent text stream replay ttl exceeds app profile max: {0} | Nested source; enclosing bridge mapping applies | [crates/traits/src/agent_text_stream.rs:244](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/traits/src/agent_text_stream.rs#L244) |
| `PaddingBucketTooLarge(u16)` | agent text stream padding bucket exceeds app profile max: {0} | Nested source; enclosing bridge mapping applies | [crates/traits/src/agent_text_stream.rs:246](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/traits/src/agent_text_stream.rs#L246) |

#### AgentTextStreamRecordError

| Variant | Source display template | Handling boundary | Source |
| --- | --- | --- | --- |
| `Truncated(&'static str)` | agent text stream record is truncated while reading {0} | Nested source; enclosing bridge mapping applies | [crates/traits/src/agent_text_stream.rs:374](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/traits/src/agent_text_stream.rs#L374) |
| `UnsupportedVersion(u8)` | unsupported agent text stream record version: {0} | Nested source; enclosing bridge mapping applies | [crates/traits/src/agent_text_stream.rs:376](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/traits/src/agent_text_stream.rs#L376) |
| `TrailingBytes(usize)` | agent text stream record contains trailing bytes: {0} | Nested source; enclosing bridge mapping applies | [crates/traits/src/agent_text_stream.rs:378](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/traits/src/agent_text_stream.rs#L378) |
| `LengthDecode { field: &'static str, reason: String }` | agent text stream record length decode failed for {field}: {reason} | Nested source; enclosing bridge mapping applies | [crates/traits/src/agent_text_stream.rs:380](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/traits/src/agent_text_stream.rs#L380) |
| `EmptyStreamId` | agent text stream id cannot be empty | Nested source; enclosing bridge mapping applies | [crates/traits/src/agent_text_stream.rs:382](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/traits/src/agent_text_stream.rs#L382) |
| `StreamIdTooLong(usize)` | agent text stream id is too long: {0} | Nested source; enclosing bridge mapping applies | [crates/traits/src/agent_text_stream.rs:384](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/traits/src/agent_text_stream.rs#L384) |
| `UnknownRecordType(u8)` | unknown agent text stream record type: {0:#04x} | Nested source; enclosing bridge mapping applies | [crates/traits/src/agent_text_stream.rs:389](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/traits/src/agent_text_stream.rs#L389) |
| `PlaintextFrameTooLarge(usize)` | agent text stream plaintext frame is too large: {0} | Nested source; enclosing bridge mapping applies | [crates/traits/src/agent_text_stream.rs:391](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/traits/src/agent_text_stream.rs#L391) |

#### EngineError

| Variant | Source display template | Handling boundary | Source |
| --- | --- | --- | --- |
| `UnknownGroup(GroupId)` | unknown group | UnknownGroup | [crates/traits/src/error.rs:13](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/traits/src/error.rs#L13) |
| `GroupNotHydrated(GroupId)` | group not hydrated yet; retry after hydration | GroupHydrationPending | [crates/traits/src/error.rs:22](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/traits/src/error.rs#L22) |
| `UnknownPending` | unknown pending send reference | Runtime if propagated without another mapping | [crates/traits/src/error.rs:25](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/traits/src/error.rs#L25) |
| `NotAMember { group_id: GroupId }` | local identity is not a member of the group | Runtime if propagated without another mapping | [crates/traits/src/error.rs:28](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/traits/src/error.rs#L28) |
| `NotGroupAdmin { group_id: GroupId }` | local identity is not an admin of the group | NotGroupAdmin | [crates/traits/src/error.rs:31](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/traits/src/error.rs#L31) |
| `UnknownMember { group_id: GroupId, member: MemberId }` | member is not in the group | MemberNotInGroup | [crates/traits/src/error.rs:34](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/traits/src/error.rs#L34) |
| `InvalidCredentialIdentity(String)` | invalid credential identity: {0} | Runtime if propagated without another mapping | [crates/traits/src/error.rs:43](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/traits/src/error.rs#L43) |
| `AdminCannotSelfRemove { group_id: GroupId }` | admin cannot self-remove: leave the admin set first | AdminCannotSelfRemove | [crates/traits/src/error.rs:47](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/traits/src/error.rs#L47) |
| `LeaveAlreadyRequested { group_id: GroupId }` | leave already requested for the current epoch | LeaveAlreadyRequested | [crates/traits/src/error.rs:64](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/traits/src/error.rs#L64) |
| `AdminDepletion { group_id: GroupId }` | commit would deplete group admins | WouldRemoveLastAdmin | [crates/traits/src/error.rs:70](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/traits/src/error.rs#L70) |
| `MissingRequiredCapabilities { required: Box<GroupCapabilities>, had: Box<GroupCapabilities>, }` | missing required capabilities: required={required:?} had={had:?} | Runtime if propagated without another mapping | [crates/traits/src/error.rs:75](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/traits/src/error.rs#L75) |
| `DisbandingUnsupportedMembers { group_id: GroupId, members: Vec<MemberId>, }` | group disbanding is blocked by unsupported member leaves | DisbandingUnsupportedMembers | [crates/traits/src/error.rs:83](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/traits/src/error.rs#L83) |
| `DisbandingNotEnabled { group_id: GroupId }` | group disbanding is not enabled | DisbandingNotEnabled | [crates/traits/src/error.rs:91](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/traits/src/error.rs#L91) |
| `UnsupportedCiphersuite { got: u16, required: u16 }` | unsupported MLS ciphersuite {got:#06x}: Marmot requires {required:#06x} | Runtime if propagated without another mapping | [crates/traits/src/error.rs:98](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/traits/src/error.rs#L98) |
| `InvalidAppMessagePayload(String)` | invalid Marmot app message payload: {0} | Runtime if propagated without another mapping | [crates/traits/src/error.rs:103](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/traits/src/error.rs#L103) |
| `InvalidAccountIdentityProof(String)` | invalid account identity proof: {0} | Runtime if propagated without another mapping | [crates/traits/src/error.rs:108](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/traits/src/error.rs#L108) |
| `InvalidKeyPackageLifetime { not_before: Option<u64>, not_after: Option<u64>, }` | invalid KeyPackage lifetime | Runtime if propagated without another mapping | [crates/traits/src/error.rs:116](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/traits/src/error.rs#L116) |
| `InvalidKeyPackageCapabilities { member: MemberId }` | invalid KeyPackage capabilities: recipient must generate a new conforming KeyPackage | Runtime if propagated without another mapping | [crates/traits/src/error.rs:125](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/traits/src/error.rs#L125) |
| `ForkedEpoch { group_id: GroupId, last_stable: EpochId, conflicting_epoch: EpochId, }` | forked epoch: last stable {last_stable}, conflicting {conflicting_epoch} | Runtime if propagated without another mapping | [crates/traits/src/error.rs:131](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/traits/src/error.rs#L131) |
| `QueuedOutboundAtCapacity { group_id: GroupId }` | queued outbound retention is at capacity for this group | GroupSendQueueFull | [crates/traits/src/error.rs:148](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/traits/src/error.rs#L148) |
| `GroupUnrecoverableRepairRequired { group_id: GroupId }` | group is unrecoverable and needs a verified repair before it can send | GroupUnrecoverableRepairRequired | [crates/traits/src/error.rs:169](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/traits/src/error.rs#L169) |
| `InvalidTransition(#[from] crate::engine_state::InvalidTransition)` | transparent | Runtime if propagated without another mapping | [crates/traits/src/error.rs:174](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/traits/src/error.rs#L174) |
| `Storage(#[from] crate::storage::StorageError)` | transparent | StorageBusy / StorageClosed by guard; otherwise Runtime | [crates/traits/src/error.rs:177](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/traits/src/error.rs#L177) |
| `Peeler(#[from] PeelerError)` | transparent | Runtime if propagated without another mapping | [crates/traits/src/error.rs:180](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/traits/src/error.rs#L180) |
| `Serialize(String)` | serialization failure: {0} | Runtime if propagated without another mapping | [crates/traits/src/error.rs:183](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/traits/src/error.rs#L183) |
| `InvalidWelcome` | invalid welcome | Runtime if propagated without another mapping | [crates/traits/src/error.rs:189](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/traits/src/error.rs#L189) |
| `WelcomeAlreadyProcessed` | welcome already processed | Runtime if propagated without another mapping | [crates/traits/src/error.rs:192](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/traits/src/error.rs#L192) |
| `Backend(String)` | backend failure: {0} | Runtime if propagated without another mapping | [crates/traits/src/error.rs:196](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/traits/src/error.rs#L196) |
| `Other(String)` | other: {0} | Runtime if propagated without another mapping | [crates/traits/src/error.rs:200](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/traits/src/error.rs#L200) |

#### MarmotAppEventError

| Variant | Source display template | Handling boundary | Source |
| --- | --- | --- | --- |
| `Json(String)` | marmot app event JSON: {0} | Nested source; enclosing bridge mapping applies | [crates/traits/src/app_event.rs:144](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/traits/src/app_event.rs#L144) |
| `IdMismatch { expected: String, found: String }` | marmot app event id mismatch | Nested source; enclosing bridge mapping applies | [crates/traits/src/app_event.rs:146](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/traits/src/app_event.rs#L146) |
| `PubkeyMismatch { expected: String, found: String }` | marmot app event pubkey mismatch | Nested source; enclosing bridge mapping applies | [crates/traits/src/app_event.rs:148](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/traits/src/app_event.rs#L148) |
| `MissingAuthenticatedActor` | group-system event requires an authenticated actor | Nested source; enclosing bridge mapping applies | [crates/traits/src/app_event.rs:150](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/traits/src/app_event.rs#L150) |

#### PeelerError

| Variant | Source display template | Handling boundary | Source |
| --- | --- | --- | --- |
| `Malformed(String)` | malformed transport payload: {0} | Nested source; enclosing bridge mapping applies | [crates/traits/src/error.rs:277](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/traits/src/error.rs#L277) |
| `InvalidSignature` | invalid transport signature | Nested source; enclosing bridge mapping applies | [crates/traits/src/error.rs:284](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/traits/src/error.rs#L284) |
| `WrongRecipient` | transport input is addressed to another recipient | Nested source; enclosing bridge mapping applies | [crates/traits/src/error.rs:289](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/traits/src/error.rs#L289) |
| `DecryptFailed` | decrypt failed (likely stale or wrong-epoch exporter secret) | Nested source; enclosing bridge mapping applies | [crates/traits/src/error.rs:292](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/traits/src/error.rs#L292) |
| `StaleEpoch { message_epoch: EpochId, context_epoch: EpochId, }` | message epoch {message_epoch} is older than available context epoch {context_epoch} | Nested source; enclosing bridge mapping applies | [crates/traits/src/error.rs:295](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/traits/src/error.rs#L295) |
| `MissingContext { label: String }` | required context secret missing: {label} | Nested source; enclosing bridge mapping applies | [crates/traits/src/error.rs:301](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/traits/src/error.rs#L301) |
| `WrapFailed(String)` | wrap failed: {0} | Nested source; enclosing bridge mapping applies | [crates/traits/src/error.rs:305](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/traits/src/error.rs#L305) |
| `Backend(String)` | peeler backend failure: {0} | Nested source; enclosing bridge mapping applies | [crates/traits/src/error.rs:309](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/traits/src/error.rs#L309) |

#### ProductAnalyticsError

| Variant | Source display template | Handling boundary | Source |
| --- | --- | --- | --- |
| `ConsentRequired` | usage and diagnostics consent required | Nested source; enclosing bridge mapping applies | [crates/marmot-app/src/product_analytics/mod.rs:55](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-app/src/product_analytics/mod.rs#L55) |
| `InvalidConfiguration` | invalid product analytics configuration | Nested source; enclosing bridge mapping applies | [crates/marmot-app/src/product_analytics/mod.rs:57](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-app/src/product_analytics/mod.rs#L57) |
| `InvalidEvent` | unregistered or invalid product observation | Nested source; enclosing bridge mapping applies | [crates/marmot-app/src/product_analytics/mod.rs:59](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-app/src/product_analytics/mod.rs#L59) |

#### RelayExportError

| Variant | Source display template | Handling boundary | Source |
| --- | --- | --- | --- |
| `MissingEndpoint` | relay telemetry export endpoint is not configured | Nested source; enclosing bridge mapping applies | [crates/marmot-app/src/relay_telemetry_export.rs:1773](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-app/src/relay_telemetry_export.rs#L1773) |
| `MissingResource` | relay telemetry export resource is not configured | Nested source; enclosing bridge mapping applies | [crates/marmot-app/src/relay_telemetry_export.rs:1777](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-app/src/relay_telemetry_export.rs#L1777) |
| `MissingAuthorizationToken` | relay telemetry export authorization token is not configured | Nested source; enclosing bridge mapping applies | [crates/marmot-app/src/relay_telemetry_export.rs:1781](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-app/src/relay_telemetry_export.rs#L1781) |
| `Request` | relay telemetry export request failed to send | Nested source; enclosing bridge mapping applies | [crates/marmot-app/src/relay_telemetry_export.rs:1785](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-app/src/relay_telemetry_export.rs#L1785) |
| `Status(u16)` | relay telemetry export endpoint returned status {0} | Nested source; enclosing bridge mapping applies | [crates/marmot-app/src/relay_telemetry_export.rs:1789](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-app/src/relay_telemetry_export.rs#L1789) |

#### SessionError

| Variant | Source display template | Handling boundary | Source |
| --- | --- | --- | --- |
| `Storage(#[from] StorageError)` | transparent | Nested source; enclosing bridge mapping applies | [crates/cgka-session/src/lib.rs:49](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/cgka-session/src/lib.rs#L49) |
| `Engine(#[from] EngineError)` | transparent | Nested source; enclosing bridge mapping applies | [crates/cgka-session/src/lib.rs:51](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/cgka-session/src/lib.rs#L51) |

#### StorageError

| Variant | Source display template | Handling boundary | Source |
| --- | --- | --- | --- |
| `NotFound` | record not found | Nested source; enclosing bridge mapping applies | [crates/traits/src/storage.rs:36](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/traits/src/storage.rs#L36) |
| `AlreadyExists` | record already exists | Nested source; enclosing bridge mapping applies | [crates/traits/src/storage.rs:38](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/traits/src/storage.rs#L38) |
| `SnapshotMissing(String)` | snapshot not found: {0} | Nested source; enclosing bridge mapping applies | [crates/traits/src/storage.rs:40](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/traits/src/storage.rs#L40) |
| `TimelineCursorExpired` | timeline cursor no longer exists; refresh the timeline | Nested source; enclosing bridge mapping applies | [crates/traits/src/storage.rs:44](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/traits/src/storage.rs#L44) |
| `Busy(String)` | backend busy: {0} | Nested source; enclosing bridge mapping applies | [crates/traits/src/storage.rs:54](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/traits/src/storage.rs#L54) |
| `Corruption(String)` | backend corruption: {0} | Nested source; enclosing bridge mapping applies | [crates/traits/src/storage.rs:58](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/traits/src/storage.rs#L58) |
| `Capacity(String)` | backend capacity exhausted: {0} | Nested source; enclosing bridge mapping applies | [crates/traits/src/storage.rs:61](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/traits/src/storage.rs#L61) |
| `Closed(String)` | backend closed: {0} | Nested source; enclosing bridge mapping applies | [crates/traits/src/storage.rs:73](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/traits/src/storage.rs#L73) |
| `UnsupportedSchemaVersion { found: i64, latest_supported: i64 }` | database schema version {found} is newer than the latest supported version {latest_supported} | Nested source; enclosing bridge mapping applies | [crates/traits/src/storage.rs:82](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/traits/src/storage.rs#L82) |
| `Backend(String)` | backend failure: {0} | Nested source; enclosing bridge mapping applies | [crates/traits/src/storage.rs:84](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/traits/src/storage.rs#L84) |
| `Serialization(String)` | serialization failure: {0} | Nested source; enclosing bridge mapping applies | [crates/traits/src/storage.rs:86](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/traits/src/storage.rs#L86) |

#### TransportAdapterError

| Variant | Source display template | Handling boundary | Source |
| --- | --- | --- | --- |
| `AccountNotActive(MemberId)` | account not active | Nested source; enclosing bridge mapping applies | [crates/traits/src/transport_adapter.rs:1055](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/traits/src/transport_adapter.rs#L1055) |
| `Closed` | transport closed | Nested source; enclosing bridge mapping applies | [crates/traits/src/transport_adapter.rs:1059](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/traits/src/transport_adapter.rs#L1059) |
| `InvalidInboundEncoding` | invalid inbound transport encoding | Nested source; enclosing bridge mapping applies | [crates/traits/src/transport_adapter.rs:1065](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/traits/src/transport_adapter.rs#L1065) |
| `InvalidInboundSignature` | invalid inbound transport signature | Nested source; enclosing bridge mapping applies | [crates/traits/src/transport_adapter.rs:1071](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/traits/src/transport_adapter.rs#L1071) |
| `PublishTargetMismatch { envelope: String, target: String }` | publish target does not match message envelope: envelope={envelope}, target={target} | Nested source; enclosing bridge mapping applies | [crates/traits/src/transport_adapter.rs:1074](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/traits/src/transport_adapter.rs#L1074) |
| `Subscription(String)` | subscription failed: {0} | Nested source; enclosing bridge mapping applies | [crates/traits/src/transport_adapter.rs:1077](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/traits/src/transport_adapter.rs#L1077) |
| `Publish(String)` | publish failed: {0} | Nested source; enclosing bridge mapping applies | [crates/traits/src/transport_adapter.rs:1080](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/traits/src/transport_adapter.rs#L1080) |
| `PublishEndpoints(TransportPublishFailure)` | publish failed: {0} | Nested source; enclosing bridge mapping applies | [crates/traits/src/transport_adapter.rs:1086](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/traits/src/transport_adapter.rs#L1086) |
| `Backend(String)` | transport backend failure: {0} | Nested source; enclosing bridge mapping applies | [crates/traits/src/transport_adapter.rs:1089](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/traits/src/transport_adapter.rs#L1089) |
| `Other(String)` | other transport adapter error: {0} | Nested source; enclosing bridge mapping applies | [crates/traits/src/transport_adapter.rs:1092](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/traits/src/transport_adapter.rs#L1092) |

#### TransportRoutingError

| Variant | Source display template | Handling boundary | Source |
| --- | --- | --- | --- |
| `MissingInboxRoute` | missing inbox route for recipient | Nested source; enclosing bridge mapping applies | [crates/marmot-account/src/routing.rs:25](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-account/src/routing.rs#L25) |
| `MissingGroupRoute` | missing group route for transport group id | Nested source; enclosing bridge mapping applies | [crates/marmot-account/src/routing.rs:27](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-account/src/routing.rs#L27) |

#### InvalidTransition (struct)

The engine’s transparent transition error forwards this template: `illegal {to} transition from {from}: {reason}`. Fields `from`, `to`, and `reason` are static strings. [crates/traits/src/engine_state.rs:458](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/traits/src/engine_state.rs#L458)

### Direct generic Runtime constructions in the UniFFI adapter

These are additional explicit `MarmotKitError::Runtime` constructions in production adapter source. The generic conversion fallback described above is separate. Expressions are shown as source, not fabricated runtime values.

| Expression | Source |
| --- | --- |
| `MarmotKitError::Runtime { details: "generated profile is unavailable".into(), }` | [crates/marmot-uniffi/src/commands/account.rs:154](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-uniffi/src/commands/account.rs#L154) |
| `MarmotKitError::Runtime { details: format!( "member {} cannot be removed from group {}", normalized.account_id_hex, group_id_hex ), }` | [crates/marmot-uniffi/src/commands/group.rs:283](https://github.com/marmot-protocol/mdk/blob/fdd398a80f1626f1713787cebe416f7890b5b204/crates/marmot-uniffi/src/commands/group.rs#L283) |

### Open-ended message families

| Origin | What varies |
| --- | --- |
| `AppError` String payloads | Validation reasons, relay lookup errors, stream problems, upload failures, and formatted operation details. The outer templates are cataloged above. |
| Storage, JSON, SQLite, hex, I/O and keychain dependencies | Their own display implementations, platform status/error codes, resource paths and nested messages. Typed mapping may intercept storage-busy/closed and keychain failures. |
| Transport and cryptographic libraries | Relay responses, network state, MLS validation results, and wrapped library messages. These are not a finite set of English sentences. |
| iOS frameworks | `NSError` / `URLError` / `CocoaError`, Photos, AVFoundation, file providers, and other framework localized descriptions. Language and OS version can change the string. |
| Cancellation and readiness | Often consumed by lifecycle logic, suppressed, or used to retry instead of being displayed. A declared error is not automatically a toast. |

## iOS-defined errors

This inventory includes every explicit `Error`/`LocalizedError` enum or struct declaration found in the main app and `Shared/`. Same-named nested `Failure` types are distinguished by their source path. Plain `Error` types have no custom localized text at the declaration; callers may translate, suppress, or fall back to the system's generic error description.

Exact `errorDescription` implementations are included for copy review. `L10n` arguments are current English catalog keys; interpolation remains a template. The shared formatter subsequently capitalizes and sanitizes them where used.

### AppContainerError — AppContainerConfig

[Shared/AppContainerConfig.swift:4](/Users/jeff/code/whitenoise-ios/Shared/AppContainerConfig.swift:4)

Cases: `appGroupContainerUnavailable`; `storageDirectoryCreationFailed(path: String, reason: String)`.
```swift
switch self {
        case .appGroupContainerUnavailable:
            return "The shared App Group container (\(AppContainerConfig.appGroupIdentifier)) is unavailable, so Marmot storage cannot be opened safely."
        case .storageDirectoryCreationFailed(let path, let reason):
            return "Could not create Marmot storage directory at \(path): \(reason)"
        }
```

### GuardError — HostResolutionGuard

[Shared/HostResolutionGuard.swift:19](/Users/jeff/code/whitenoise-ios/Shared/HostResolutionGuard.swift:19)

Cases: `resolvesToPrivateAddress`; `resolutionFailed`.
No custom `errorDescription` in this declaration.

### FetchError — PinnedHTTPSFetcher

[Shared/PinnedHTTPSFetcher.swift:42](/Users/jeff/code/whitenoise-ios/Shared/PinnedHTTPSFetcher.swift:42)

Cases: `invalidRequest`; `malformedResponse`; `responseHeadersTooLarge`; `tooManyRedirects`.
No custom `errorDescription` in this declaration.

### ProfileFollowActionError — NewChatFlowView

[whitenoise-ios/Chats/NewChatFlowView.swift:436](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Chats/NewChatFlowView.swift:436)

Cases: `noActiveAccount`.
```swift
switch self {
        case .noActiveAccount:
            L10n.string("No active account is selected.")
        }
```

### DirectChatLookupError — NewChatFlowViewModel

[whitenoise-ios/Chats/NewChatFlowViewModel.swift:462](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Chats/NewChatFlowViewModel.swift:462)

Cases: `noActiveAccount`.
```swift
L10n.string("No active account is selected.")
```

### MediaDataError — ConversationMediaDownloader

[whitenoise-ios/Conversation/ConversationMediaDownloader.swift:170](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Conversation/ConversationMediaDownloader.swift:170)

Cases: `missingReference`; `missingAccount`; `unsafeLocator`; `plaintextHashMismatch`.
```swift
switch self {
            case .missingReference:
                return L10n.string("This attachment is not ready yet.")
            case .missingAccount:
                return L10n.string("No active account.")
            case .unsafeLocator:
                return L10n.string("This attachment uses an unsafe download location.")
            case .plaintextHashMismatch:
                return L10n.string("Attachment verification failed.")
            }
```

### Failure — GiphyRemoteMedia

[whitenoise-ios/Conversation/GiphyRemoteMedia.swift:208](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Conversation/GiphyRemoteMedia.swift:208)

Cases: `invalidURL`; `invalidResponse`.
```swift
L10n.string("This GIF couldn't be loaded.")
```

### GiphySearchError — GiphySearchClient

[whitenoise-ios/Conversation/GiphySearchClient.swift:271](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Conversation/GiphySearchClient.swift:271)

Cases: `missingAPIKey`; `queryTooLong`; `invalidRequest`; `badResponse`.
```swift
switch self {
        case .missingAPIKey:
            L10n.string("GIF search isn't configured in this build.")
        case .queryTooLong:
            L10n.string("That GIF search is too long.")
        case .invalidRequest, .badResponse:
            L10n.string("GIF search is temporarily unavailable.")
        }
```

### CameraCaptureError — MediaComposerViews

[whitenoise-ios/Conversation/MediaComposerViews.swift:1505](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Conversation/MediaComposerViews.swift:1505)

Cases: `noCamera`; `cannotAddInput`; `cannotAddOutput`.
No custom `errorDescription` in this declaration.

### PhotoLibraryPickerError — MediaComposerViews

[whitenoise-ios/Conversation/MediaComposerViews.swift:1544](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Conversation/MediaComposerViews.swift:1544)

Cases: `noReadableMedia`.
```swift
switch self {
        case .noReadableMedia:
            return L10n.string("That attachment could not be opened.")
        }
```

### MessageVideoAttachmentError — MessageBubble

[whitenoise-ios/Conversation/MessageBubble.swift:2557](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Conversation/MessageBubble.swift:2557)

Cases: `playbackFileUnavailable`.
No custom `errorDescription` in this declaration.

### FullscreenMediaPreparationError — MessageBubble

[whitenoise-ios/Conversation/MessageBubble.swift:3392](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Conversation/MessageBubble.swift:3392)

Cases: `protectedFileUnavailable`.
No custom `errorDescription` in this declaration.

### Failure — MessageMediaAttachment

[whitenoise-ios/Conversation/MessageMediaAttachment.swift:502](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Conversation/MessageMediaAttachment.swift:502)

Cases: `unsupportedImage`; `unsupportedAttachment`; `encodingFailed`; `attachmentTooLarge(Int)`.
```swift
switch self {
            case .unsupportedImage:
                return L10n.string("That image could not be opened.")
            case .unsupportedAttachment:
                return L10n.string("That file type is not supported.")
            case .encodingFailed:
                return L10n.string("That attachment could not be prepared.")
            case .attachmentTooLarge:
                return L10n.string("That attachment is too large to send.")
            }
```

### Failure — VoiceMessageRecorder

[whitenoise-ios/Conversation/VoiceMessageRecorder.swift:76](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Conversation/VoiceMessageRecorder.swift:76)

Cases: `permissionDenied`; `startFailed`.
```swift
switch self {
            case .permissionDenied:
                return L10n.string("Microphone access is needed to record voice messages.")
            case .startFailed:
                return L10n.string("Voice recording could not start.")
            }
```

### NotificationSettingsActionError — AppNotifications

[whitenoise-ios/Core/AppNotifications.swift:565](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Core/AppNotifications.swift:565)

Cases: `noActiveAccount`; `permissionDenied`; `nativePushNotConfigured`; `missingApnsToken`; `apnsTokenRefreshTimedOut`; `apnsRegistrationFailed(String)`.
```swift
switch self {
        case .noActiveAccount:
            return L10n.string("No active account.")
        case .permissionDenied:
            return L10n.string("Notifications are disabled in system settings.")
        case .nativePushNotConfigured:
            return L10n.string("Native push server configuration is missing.")
        case .missingApnsToken:
            return L10n.string("APNS has not returned a device token yet.")
        case .apnsTokenRefreshTimedOut:
            return L10n.string("APNS did not return a new device token in time. Try again, or check notification permission in Settings.")
        case let .apnsRegistrationFailed(message):
            return L10n.formatted("APNS registration failed: %@", message)
        }
```

### RelaySettingsSaveFailure — MarmotClient

[whitenoise-ios/Core/MarmotClient.swift:1073](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Core/MarmotClient.swift:1073)

Wrapper fields: `underlyingError: Error`; `reloadedLists: AccountRelayListsFfi?`.
```swift
underlyingError.localizedDescription
```

### NotificationActionError — RuntimeLifecycle

[whitenoise-ios/Core/RuntimeLifecycle.swift:36](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Core/RuntimeLifecycle.swift:36)

Cases: `runtimeUnavailable`; `markReadFailed`.
No custom `errorDescription` in this declaration.

### RuntimeOwnershipContentionError — RuntimeLifecycle

[whitenoise-ios/Core/RuntimeLifecycle.swift:41](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Core/RuntimeLifecycle.swift:41)

Cases: `retryWindowExhausted`.
```swift
"White Noise is still finishing another secure background operation. Please try again."
```

### ForegroundRuntimeMutationError — RuntimeLifecycle

[whitenoise-ios/Core/RuntimeLifecycle.swift:64](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Core/RuntimeLifecycle.swift:64)

Cases: `runtimeUnavailable`.
```swift
"The secure runtime isn't ready yet. Try again in a moment."
```

### TelemetrySettingsActionError — TelemetryBuildConfig

[whitenoise-ios/Core/TelemetryBuildConfig.swift:4](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Core/TelemetryBuildConfig.swift:4)

Cases: `telemetryNotConfigured`.
```swift
switch self {
        case .telemetryNotConfigured:
            "Telemetry credentials are not configured for this build."
        }
```

### AuditLogActionError — TelemetryBuildConfig

[whitenoise-ios/Core/TelemetryBuildConfig.swift:15](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Core/TelemetryBuildConfig.swift:15)

Cases: `runtimeNotReady`.
```swift
switch self {
        case .runtimeNotReady:
            "The secure runtime isn't ready yet. Try again in a moment."
        }
```

### GroupDetailsActionError — GroupDetailsView

[whitenoise-ios/Group/GroupDetailsView.swift:1177](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Group/GroupDetailsView.swift:1177)

Cases: `noActiveAccount`; `operationInFlight`.
```swift
switch self {
        case .noActiveAccount:
            L10n.string("No active account is selected.")
        case .operationInFlight:
            L10n.string("Another group update is still in progress.")
        }
```

### DuckDuckGoImageSearchError — GroupImageURLSheet

[whitenoise-ios/Group/GroupImageURLSheet.swift:181](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Group/GroupImageURLSheet.swift:181)

Cases: `emptyQuery`; `missingToken`; `badResponse`.
```swift
switch self {
        case .emptyQuery:
            return L10n.string("Enter a search term.")
        case .missingToken:
            return L10n.string("Image search is temporarily unavailable.")
        case .badResponse:
            return L10n.string("Image search returned an unexpected response.")
        }
```

### GroupMembershipPageResponseError — RecipientDirectory

[whitenoise-ios/Recipients/RecipientDirectory.swift:81](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Recipients/RecipientDirectory.swift:81)

Cases: `invalidRows`.
No custom `errorDescription` in this declaration.

### RecipientUserSearchError — RecipientUserSearch

[whitenoise-ios/Recipients/RecipientUserSearch.swift:9](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Recipients/RecipientUserSearch.swift:9)

Cases: `appStateUnavailable`.
No custom `errorDescription` in this declaration.

### ExportError — DiagnosticLogExport

[whitenoise-ios/Settings/DiagnosticLogExport.swift:28](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Settings/DiagnosticLogExport.swift:28)

Cases: `noLogs`; `fileChangedDuringRead`.
No custom `errorDescription` in this declaration.

### ProfileImageUploadError — ProfileEditViewModel

[whitenoise-ios/Settings/ProfileEditViewModel.swift:243](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Settings/ProfileEditViewModel.swift:243)

Cases: `invalidReturnedURL`; `unavailable`.
```swift
switch self {
        case .invalidReturnedURL:
            L10n.string("The image server returned an invalid URL.")
        case .unavailable:
            L10n.string("Profile image upload is not available right now.")
        }
```

### Rejection — RelaysViewModel

[whitenoise-ios/Settings/RelaysViewModel.swift:44](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Settings/RelaysViewModel.swift:44)

Wrapper fields: `policy: RelayEndpointPolicyFfi?`; `endpoint: String?`.
```swift
let display = endpoint.flatMap {
                ContentSanitizer.relayDisplayLine($0, maxLength: 120)
            }
            switch policy {
            case .retired:
                return display.map { L10n.formatted("%@ is a retired relay.", $0) }
                    ?? L10n.string("That relay is retired.")
            case .unsafe:
                return display.map { L10n.formatted("%@ isn't safe to connect to.", $0) }
                    ?? L10n.string("That relay isn't safe to connect to.")
            case .invalid:
                return display.map { L10n.formatted("%@ isn't a valid relay URL.", $0) }
                    ?? L10n.string("That isn't a valid relay URL.")
            case .allowed, nil:
                return L10n.string("Relay validation returned an incomplete result.")
            }
```

## Presentation call-site index

This source index covers direct calls to the shared formatter and direct localized `.error(...)` calls. It records current operation titles and message expressions, with a link to the surrounding flow. It is not a call-graph proof or an exhaustive inventory of every validation label, empty state, server-supplied message, or error received by a callback. Native error declarations and screen-specific overrides above cover complementary paths.

Calls using `message(for:)` supply inline text; their heading comes from the enclosing screen or prompt. Source expressions are shown literally so variable-driven titles are not guessed.

### Chats

| Current title / message expression | Call site |
| --- | --- |
| `UserFacingError.toast(title: L10n.string("Couldn't archive chat"), error: error)` | [whitenoise-ios/Chats/ChatsListView.swift:1299](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Chats/ChatsListView.swift:1299) |
| `UserFacingError.message(for: error)` | [whitenoise-ios/Chats/ChatsListViewModel.swift:403](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Chats/ChatsListViewModel.swift:403) |
| `.error(L10n.string("That QR code isn't a White Noise profile."))` | [whitenoise-ios/Chats/NewChatFlowView.swift:151](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Chats/NewChatFlowView.swift:151) |
| `UserFacingError.message(for: error)` | [whitenoise-ios/Chats/NewChatFlowViewModel.swift:175](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Chats/NewChatFlowViewModel.swift:175) |
| `UserFacingError.toast(title: L10n.string("Couldn't add this person"), error: error)` | [whitenoise-ios/Chats/NewChatFlowViewModel.swift:345](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Chats/NewChatFlowViewModel.swift:345) |
| `UserFacingError.message(for: marmotError)` | [whitenoise-ios/Chats/NewChatFlowViewModel.swift:450](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Chats/NewChatFlowViewModel.swift:450) |
| `UserFacingError.toast(title: L10n.string("Couldn't create chat"), error: marmotError)` | [whitenoise-ios/Chats/NewChatFlowViewModel.swift:451](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Chats/NewChatFlowViewModel.swift:451) |
| `UserFacingError.message(for: error)` | [whitenoise-ios/Chats/NewChatFlowViewModel.swift:455](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Chats/NewChatFlowViewModel.swift:455) |
| `UserFacingError.toast(title: L10n.string("Couldn't create chat"), error: error)` | [whitenoise-ios/Chats/NewChatFlowViewModel.swift:456](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Chats/NewChatFlowViewModel.swift:456) |

### Conversation

| Current title / message expression | Call site |
| --- | --- |
| `UserFacingError.message(for: error)` | [whitenoise-ios/Conversation/ComposerModel.swift:210](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Conversation/ComposerModel.swift:210) |
| `UserFacingError.toast(title: L10n.string("Send failed"), error: error)` | [whitenoise-ios/Conversation/ComposerModel.swift:213](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Conversation/ComposerModel.swift:213) |
| `UserFacingError.message(for: error)` | [whitenoise-ios/Conversation/ComposerModel.swift:348](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Conversation/ComposerModel.swift:348) |
| `UserFacingError.toast(title: L10n.string("Send failed"), error: error)` | [whitenoise-ios/Conversation/ComposerModel.swift:351](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Conversation/ComposerModel.swift:351) |
| `UserFacingError.toast(title: L10n.string("Couldn't add attachment"), error: error)` | [whitenoise-ios/Conversation/ConversationView.swift:945](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Conversation/ConversationView.swift:945) |
| `UserFacingError.toast(title: L10n.string("Couldn't add contact"), error: error)` | [whitenoise-ios/Conversation/ConversationView.swift:2665](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Conversation/ConversationView.swift:2665) |
| `UserFacingError.toast(title: L10n.string("Couldn't add attachment"), error: error)` | [whitenoise-ios/Conversation/ConversationView.swift:2681](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Conversation/ConversationView.swift:2681) |
| `UserFacingError.toast(title: L10n.string("Couldn't add attachment"), error: error)` | [whitenoise-ios/Conversation/ConversationView.swift:2708](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Conversation/ConversationView.swift:2708) |
| `UserFacingError.toast(title: L10n.string("Couldn't add attachment"), error: error)` | [whitenoise-ios/Conversation/ConversationView.swift:2745](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Conversation/ConversationView.swift:2745) |
| `UserFacingError.toast(title: L10n.string("Couldn't add attachment"), error: error)` | [whitenoise-ios/Conversation/ConversationView.swift:2780](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Conversation/ConversationView.swift:2780) |
| `UserFacingError.toast(title: L10n.string("Couldn't add attachment"), error: error)` | [whitenoise-ios/Conversation/ConversationView.swift:2812](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Conversation/ConversationView.swift:2812) |
| `UserFacingError.toast(title: L10n.string("Couldn't record audio"), error: error)` | [whitenoise-ios/Conversation/ConversationView.swift:2821](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Conversation/ConversationView.swift:2821) |
| `UserFacingError.toast(title: L10n.string("Couldn't add attachment"), error: error)` | [whitenoise-ios/Conversation/ConversationView.swift:2861](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Conversation/ConversationView.swift:2861) |
| `UserFacingError.present( title: L10n.string("Send failed"), error: error )` | [whitenoise-ios/Conversation/ConversationViewModel.swift:1015](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Conversation/ConversationViewModel.swift:1015) |
| `UserFacingError.message(for: error)` | [whitenoise-ios/Conversation/ConversationViewModel.swift:1204](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Conversation/ConversationViewModel.swift:1204) |
| `UserFacingError.message(for: error)` | [whitenoise-ios/Conversation/ConversationViewModel.swift:1260](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Conversation/ConversationViewModel.swift:1260) |
| `UserFacingError.message(for: error)` | [whitenoise-ios/Conversation/ConversationViewModel.swift:1300](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Conversation/ConversationViewModel.swift:1300) |
| `UserFacingError.message(for: error)` | [whitenoise-ios/Conversation/ConversationViewModel.swift:1338](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Conversation/ConversationViewModel.swift:1338) |
| `UserFacingError.message(for: error)` | [whitenoise-ios/Conversation/ConversationViewModel.swift:1515](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Conversation/ConversationViewModel.swift:1515) |
| `UserFacingError.message(for: error)` | [whitenoise-ios/Conversation/ConversationViewModel.swift:1537](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Conversation/ConversationViewModel.swift:1537) |
| `UserFacingError.toast( title: L10n.string("Couldn't accept invitation"), error: error )` | [whitenoise-ios/Conversation/ConversationViewModel.swift:2255](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Conversation/ConversationViewModel.swift:2255) |
| `UserFacingError.toast( title: L10n.string("Couldn't confirm invitation"), error: error )` | [whitenoise-ios/Conversation/ConversationViewModel.swift:2267](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Conversation/ConversationViewModel.swift:2267) |
| `UserFacingError.toast(title: L10n.string("Couldn't accept invitation"), error: error)` | [whitenoise-ios/Conversation/ConversationViewModel.swift:2285](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Conversation/ConversationViewModel.swift:2285) |
| `UserFacingError.toast(title: L10n.string("Couldn't decline invitation"), error: error)` | [whitenoise-ios/Conversation/ConversationViewModel.swift:2350](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Conversation/ConversationViewModel.swift:2350) |
| `UserFacingError.toast(title: L10n.string("Send failed"), error: error)` | [whitenoise-ios/Conversation/ConversationViewModel.swift:2515](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Conversation/ConversationViewModel.swift:2515) |
| `UserFacingError.toast(title: L10n.string("Couldn't delete message"), error: error)` | [whitenoise-ios/Conversation/ConversationViewModel.swift:2589](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Conversation/ConversationViewModel.swift:2589) |
| `UserFacingError.toast(title: L10n.string("Reaction failed"), error: error)` | [whitenoise-ios/Conversation/ConversationViewModel.swift:2702](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Conversation/ConversationViewModel.swift:2702) |
| `UserFacingError.message(for: error)` | [whitenoise-ios/Conversation/GiphySearchView.swift:107](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Conversation/GiphySearchView.swift:107) |

### Core

| Current title / message expression | Call site |
| --- | --- |
| `UserFacingError.message(for: error)` | [whitenoise-ios/Core/AppNotifications.swift:227](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Core/AppNotifications.swift:227) |
| `.error(L10n.string("Couldn’t refresh your accounts. Try again."))` | [whitenoise-ios/Core/AppState.swift:201](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Core/AppState.swift:201) |
| `UserFacingError.toast(title: L10n.string("Couldn't sign in"), error: error)` | [whitenoise-ios/Core/AppState.swift:729](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Core/AppState.swift:729) |
| `.error(L10n.string("Couldn't sign out"))` | [whitenoise-ios/Core/AppState.swift:764](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Core/AppState.swift:764) |
| `.error(L10n.string("Couldn't sign out"))` | [whitenoise-ios/Core/AppState.swift:784](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Core/AppState.swift:784) |
| `.error(L10n.string("Couldn't sign out"), message: message)` | [whitenoise-ios/Core/AppState.swift:811](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Core/AppState.swift:811) |
| `UserFacingError.toast(title: L10n.string("Couldn't sign out"), error: error)` | [whitenoise-ios/Core/AppState.swift:820](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Core/AppState.swift:820) |
| `UserFacingError.message(for: error)` | [whitenoise-ios/Core/AppState.swift:884](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Core/AppState.swift:884) |
| `UserFacingError.toast(title: L10n.string("Couldn't refresh accounts"), error: error)` | [whitenoise-ios/Core/AppState.swift:887](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Core/AppState.swift:887) |
| `.error(L10n.string("Couldn't wipe profile"))` | [whitenoise-ios/Core/AppState.swift:954](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Core/AppState.swift:954) |
| `.error(L10n.string("Couldn't wipe profile"))` | [whitenoise-ios/Core/AppState.swift:967](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Core/AppState.swift:967) |
| `UserFacingError.toast(title: L10n.string("Couldn't wipe profile"), error: error)` | [whitenoise-ios/Core/AppState.swift:996](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Core/AppState.swift:996) |
| `.error(L10n.string("Erasure didn’t finish. Some data may remain. Try again."))` | [whitenoise-ios/Core/AppState.swift:1109](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Core/AppState.swift:1109) |
| `UserFacingError.message(for: error)` | [whitenoise-ios/Core/RuntimeLifecycle.swift:492](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Core/RuntimeLifecycle.swift:492) |
| `UserFacingError.message(for: error)` | [whitenoise-ios/Core/RuntimeLifecycle.swift:838](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Core/RuntimeLifecycle.swift:838) |
| `UserFacingError.message(for: error)` | [whitenoise-ios/Core/RuntimeLifecycle.swift:861](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Core/RuntimeLifecycle.swift:861) |
| `UserFacingError.message(for: error)` | [whitenoise-ios/Core/RuntimeLifecycle.swift:892](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Core/RuntimeLifecycle.swift:892) |

### Diagnostics

| Current title / message expression | Call site |
| --- | --- |
| `UserFacingError.message(for: error)` | [whitenoise-ios/Diagnostics/DiagnosticsViewModel.swift:81](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Diagnostics/DiagnosticsViewModel.swift:81) |

### Group

| Current title / message expression | Call site |
| --- | --- |
| `.error(L10n.string("That QR code isn't a White Noise profile."))` | [whitenoise-ios/Group/AddMembersSheet.swift:249](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Group/AddMembersSheet.swift:249) |
| `UserFacingError.message(for: error)` | [whitenoise-ios/Group/AddMembersSheetViewModel.swift:93](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Group/AddMembersSheetViewModel.swift:93) |
| `UserFacingError.message(for: error)` | [whitenoise-ios/Group/GroupDetailsViewModel.swift:244](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Group/GroupDetailsViewModel.swift:244) |
| `UserFacingError.toast(title: L10n.string("Couldn't update group info"), error: error)` | [whitenoise-ios/Group/GroupDetailsViewModel.swift:245](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Group/GroupDetailsViewModel.swift:245) |
| `UserFacingError.message(for: error)` | [whitenoise-ios/Group/GroupDetailsViewModel.swift:417](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Group/GroupDetailsViewModel.swift:417) |
| `UserFacingError.toast(title: L10n.string("Couldn't update group image"), error: error)` | [whitenoise-ios/Group/GroupDetailsViewModel.swift:419](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Group/GroupDetailsViewModel.swift:419) |
| `UserFacingError.message(for: error)` | [whitenoise-ios/Group/GroupDetailsViewModel.swift:562](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Group/GroupDetailsViewModel.swift:562) |
| `UserFacingError.toast(title: L10n.string("Couldn't update archive"), error: error)` | [whitenoise-ios/Group/GroupDetailsViewModel.swift:563](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Group/GroupDetailsViewModel.swift:563) |
| `UserFacingError.message(for: error)` | [whitenoise-ios/Group/GroupDetailsViewModel.swift:823](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Group/GroupDetailsViewModel.swift:823) |
| `UserFacingError.message(for: marmotError)` | [whitenoise-ios/Group/GroupDetailsViewModel.swift:855](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Group/GroupDetailsViewModel.swift:855) |
| `UserFacingError.message(for: error)` | [whitenoise-ios/Group/GroupDetailsViewModel.swift:913](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Group/GroupDetailsViewModel.swift:913) |
| `UserFacingError.message(for: error)` | [whitenoise-ios/Group/GroupDetailsViewModel.swift:953](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Group/GroupDetailsViewModel.swift:953) |
| `UserFacingError.message(for: error)` | [whitenoise-ios/Group/GroupDetailsViewModel.swift:960](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Group/GroupDetailsViewModel.swift:960) |
| `UserFacingError.message(for: error)` | [whitenoise-ios/Group/GroupImageURLSheet.swift:415](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Group/GroupImageURLSheet.swift:415) |
| `UserFacingError.message(for: error)` | [whitenoise-ios/Group/GroupImageURLSheet.swift:654](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Group/GroupImageURLSheet.swift:654) |
| `UserFacingError.message(for: error)` | [whitenoise-ios/Group/GroupImageURLSheet.swift:689](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Group/GroupImageURLSheet.swift:689) |
| `UserFacingError.message(for: error)` | [whitenoise-ios/Group/GroupImageURLSheet.swift:714](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Group/GroupImageURLSheet.swift:714) |
| `UserFacingError.message(for: error)` | [whitenoise-ios/Group/GroupImageURLSheet.swift:733](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Group/GroupImageURLSheet.swift:733) |
| `UserFacingError.message(for: marmotError)` | [whitenoise-ios/Group/GroupsInCommonSection.swift:211](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Group/GroupsInCommonSection.swift:211) |
| `UserFacingError.message(for: error)` | [whitenoise-ios/Group/GroupsInCommonSection.swift:215](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Group/GroupsInCommonSection.swift:215) |
| `UserFacingError.message(for: error)` | [whitenoise-ios/Group/SharedMediaLibraryView.swift:582](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Group/SharedMediaLibraryView.swift:582) |

### Onboarding

| Current title / message expression | Call site |
| --- | --- |
| `UserFacingError.present( title: L10n.string("Import failed"), error: error, fallbackMessage: Self.importFallbackMessage(for: error) )` | [whitenoise-ios/Onboarding/ImportIdentityViewModel.swift:93](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Onboarding/ImportIdentityViewModel.swift:93) |
| `UserFacingError.message(for: error)` | [whitenoise-ios/Onboarding/OnboardingAvatarWebImagePicker.swift:220](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Onboarding/OnboardingAvatarWebImagePicker.swift:220) |

### Profile

| Current title / message expression | Call site |
| --- | --- |
| `UserFacingError.toast( title: L10n.string("Couldn't update follow status"), error: error, fallbackMessage: L10n.string("Please try again.") )` | [whitenoise-ios/Profile/ProfileViewModel.swift:179](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Profile/ProfileViewModel.swift:179) |

### Recipients

| Current title / message expression | Call site |
| --- | --- |
| `UserFacingError.message(for: error)` | [whitenoise-ios/Recipients/DirectChatStarter.swift:17](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Recipients/DirectChatStarter.swift:17) |
| `UserFacingError.message(for: marmotError)` | [whitenoise-ios/Recipients/DirectChatStarter.swift:23](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Recipients/DirectChatStarter.swift:23) |
| `UserFacingError.message(for: error)` | [whitenoise-ios/Recipients/RecipientDirectory.swift:245](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Recipients/RecipientDirectory.swift:245) |

### Settings

| Current title / message expression | Call site |
| --- | --- |
| `UserFacingError.message(for: error)` | [whitenoise-ios/Settings/IdentityKeyExportPresentation.swift:7](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Settings/IdentityKeyExportPresentation.swift:7) |
| `UserFacingError.message(for: error)` | [whitenoise-ios/Settings/IdentityKeyExportPresentation.swift:17](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Settings/IdentityKeyExportPresentation.swift:17) |
| `UserFacingError.message(for: error)` | [whitenoise-ios/Settings/IdentityKeyExportPresentation.swift:19](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Settings/IdentityKeyExportPresentation.swift:19) |
| `UserFacingError.message(for: error)` | [whitenoise-ios/Settings/KeyPackagesViewModel.swift:88](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Settings/KeyPackagesViewModel.swift:88) |
| `UserFacingError.message(for: error)` | [whitenoise-ios/Settings/KeyPackagesViewModel.swift:99](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Settings/KeyPackagesViewModel.swift:99) |
| `UserFacingError.toast(title: L10n.string("Publish failed"), error: error)` | [whitenoise-ios/Settings/KeyPackagesViewModel.swift:116](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Settings/KeyPackagesViewModel.swift:116) |
| `UserFacingError.toast(title: L10n.string("Delete failed"), error: error)` | [whitenoise-ios/Settings/KeyPackagesViewModel.swift:139](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Settings/KeyPackagesViewModel.swift:139) |
| `UserFacingError.toast( title: L10n.string("Notification failed"), error: error )` | [whitenoise-ios/Settings/NotificationSettingsViewModel.swift:192](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Settings/NotificationSettingsViewModel.swift:192) |
| `UserFacingError.toast( title: L10n.string("Notification failed"), error: error )` | [whitenoise-ios/Settings/NotificationSettingsViewModel.swift:232](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Settings/NotificationSettingsViewModel.swift:232) |
| `UserFacingError.toast( title: L10n.string("Notification failed"), error: error )` | [whitenoise-ios/Settings/NotificationSettingsViewModel.swift:258](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Settings/NotificationSettingsViewModel.swift:258) |
| `UserFacingError.toast( title: L10n.string("Notification failed"), error: error )` | [whitenoise-ios/Settings/NotificationSettingsViewModel.swift:283](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Settings/NotificationSettingsViewModel.swift:283) |
| `UserFacingError.toast( title: L10n.string("Notification failed"), error: error )` | [whitenoise-ios/Settings/NotificationSettingsViewModel.swift:304](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Settings/NotificationSettingsViewModel.swift:304) |
| `UserFacingError.message(for: error)` | [whitenoise-ios/Settings/PrivacySecuritySettingsViewModel.swift:199](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Settings/PrivacySecuritySettingsViewModel.swift:199) |
| `UserFacingError.message(for: error)` | [whitenoise-ios/Settings/PrivacySecuritySettingsViewModel.swift:232](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Settings/PrivacySecuritySettingsViewModel.swift:232) |
| `UserFacingError.toast( title: L10n.string("Delete failed"), error: error )` | [whitenoise-ios/Settings/PrivacySecuritySettingsViewModel.swift:254](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Settings/PrivacySecuritySettingsViewModel.swift:254) |
| `UserFacingError.toast( title: L10n.string("Save failed"), error: error )` | [whitenoise-ios/Settings/PrivacySecuritySettingsViewModel.swift:283](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Settings/PrivacySecuritySettingsViewModel.swift:283) |
| `UserFacingError.message(for: $0)` | [whitenoise-ios/Settings/ProfileEditView.swift:216](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Settings/ProfileEditView.swift:216) |
| `UserFacingError.message(for: error)` | [whitenoise-ios/Settings/ProfileEditView.swift:329](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Settings/ProfileEditView.swift:329) |
| `UserFacingError.message(for: error)` | [whitenoise-ios/Settings/ProfileEditView.swift:349](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Settings/ProfileEditView.swift:349) |
| `UserFacingError.message(for: error)` | [whitenoise-ios/Settings/ProfileEditView.swift:365](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Settings/ProfileEditView.swift:365) |
| `UserFacingError.message(for: error)` | [whitenoise-ios/Settings/ProfileEditView.swift:393](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Settings/ProfileEditView.swift:393) |
| `UserFacingError.message(for: error)` | [whitenoise-ios/Settings/ProfileEditView.swift:410](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Settings/ProfileEditView.swift:410) |
| `UserFacingError.toast(title: L10n.string("Couldn't publish profile"), error: error)` | [whitenoise-ios/Settings/ProfileEditViewModel.swift:238](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Settings/ProfileEditViewModel.swift:238) |
| `UserFacingError.toast( title: L10n.string("Recovery retry failed"), error: error )` | [whitenoise-ios/Settings/QuarantinedGroupsViewModel.swift:192](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Settings/QuarantinedGroupsViewModel.swift:192) |
| `UserFacingError.message(for: error)` | [whitenoise-ios/Settings/RelaysViewModel.swift:205](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Settings/RelaysViewModel.swift:205) |
| `UserFacingError.message(for: error)` | [whitenoise-ios/Settings/RelaysViewModel.swift:308](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Settings/RelaysViewModel.swift:308) |
| `UserFacingError.toast(title: L10n.string("Relay update failed"), error: error)` | [whitenoise-ios/Settings/RelaysViewModel.swift:309](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Settings/RelaysViewModel.swift:309) |

## Static failure messages

These additional localized messages are assigned directly to error, failure, or validation state. They can replace underlying exceptions and may bypass the shared formatter. The list is source-indexed; ordinary empty-state and validation labels outside those explicit assignments are not classified as exceptions.

| Current assignment / English template | Source |
| --- | --- |
| `groupCreateError = L10n.formatted( "%@ hasn't published a compatible key package, so they can't be added yet.", appState.shortNpub(forAccountIdHex: account) )` | [whitenoise-ios/Chats/NewChatFlowViewModel.swift:445](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Chats/NewChatFlowViewModel.swift:445) |
| `errorMessage = L10n.string("Couldn’t check group recovery. Try again.")` | [whitenoise-ios/Conversation/GroupRecoveryModel.swift:44](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Conversation/GroupRecoveryModel.swift:44) |
| `errorMessage = L10n.string("Couldn’t apply this invitation. Review the latest offer and try again.")` | [whitenoise-ios/Conversation/GroupRecoveryModel.swift:75](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Conversation/GroupRecoveryModel.swift:75) |
| `actionError = L10n.string("Couldn't save media.")` | [whitenoise-ios/Conversation/MessageBubble.swift:3575](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Conversation/MessageBubble.swift:3575) |
| `actionError = L10n.string("Couldn't prepare media.")` | [whitenoise-ios/Conversation/MessageBubble.swift:3687](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Conversation/MessageBubble.swift:3687) |
| `errorMessage = L10n.string("Couldn’t close sign-in. Try again when the current update has finished.")` | [whitenoise-ios/Core/AppState.swift:206](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Core/AppState.swift:206) |
| `errorMessage = L10n.string("Couldn’t refresh your accounts. Try again.")` | [whitenoise-ios/Core/AppState.swift:245](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Core/AppState.swift:245) |
| `sharedMediaError = L10n.string("Couldn't load shared media.")` | [whitenoise-ios/Group/GroupDetailsViewModel.swift:282](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Group/GroupDetailsViewModel.swift:282) |
| `actionError = L10n.string("Leave this group before deleting the local copy.")` | [whitenoise-ios/Group/GroupDetailsViewModel.swift:775](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Group/GroupDetailsViewModel.swift:775) |
| `searchError = L10n.string("No usable HTTPS images found.")` | [whitenoise-ios/Group/GroupImageURLSheet.swift:646](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Group/GroupImageURLSheet.swift:646) |
| `error = L10n.formatted( "%@ hasn't published a compatible key package yet.", IdentityFormatter.short(account) )` | [whitenoise-ios/Group/GroupsInCommonSection.swift:206](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Group/GroupsInCommonSection.swift:206) |
| `loadError = L10n.string("Couldn't load shared media.")` | [whitenoise-ios/Group/SharedMediaLibraryView.swift:52](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Group/SharedMediaLibraryView.swift:52) |
| `linksError = L10n.string("Couldn't load links.")` | [whitenoise-ios/Group/SharedMediaLibraryView.swift:110](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Group/SharedMediaLibraryView.swift:110) |
| `error = L10n.string("Enter a valid relay URL, like wss://relay.example.com.")` | [whitenoise-ios/Onboarding/AccountSetupActions.swift:185](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Onboarding/AccountSetupActions.swift:185) |
| `errorMessage = L10n.string("Setup updates stopped. Reconnect to continue.")` | [whitenoise-ios/Onboarding/AccountSetupModel.swift:171](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Onboarding/AccountSetupModel.swift:171) |
| `errorMessage = L10n.string("Couldn’t load sign-in checks. Reconnect to try again.")` | [whitenoise-ios/Onboarding/AccountSetupModel.swift:175](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Onboarding/AccountSetupModel.swift:175) |
| `errorMessage = L10n.string("Setup changed. Reconnect and review the latest options.")` | [whitenoise-ios/Onboarding/AccountSetupModel.swift:194](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Onboarding/AccountSetupModel.swift:194) |
| `errorMessage = L10n.string("Couldn’t finish this step. Try again.")` | [whitenoise-ios/Onboarding/AccountSetupModel.swift:196](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Onboarding/AccountSetupModel.swift:196) |
| `errorMessage = L10n.string("Couldn’t finish this step. Try again.")` | [whitenoise-ios/Onboarding/AccountSetupModel.swift:218](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Onboarding/AccountSetupModel.swift:218) |
| `avatarError = L10n.string("That photo is too large. Choose a different photo.")` | [whitenoise-ios/Onboarding/CreateIdentityViewModel.swift:176](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Onboarding/CreateIdentityViewModel.swift:176) |
| `avatarError = L10n.string("That photo can't be used. Choose a different photo.")` | [whitenoise-ios/Onboarding/CreateIdentityViewModel.swift:178](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Onboarding/CreateIdentityViewModel.swift:178) |
| `searchError = L10n.string("No usable HTTPS images found.")` | [whitenoise-ios/Onboarding/OnboardingAvatarWebImagePicker.swift:213](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Onboarding/OnboardingAvatarWebImagePicker.swift:213) |
| `scanError = L10n.string("That QR code isn't a White Noise profile.")` | [whitenoise-ios/Profile/ProfileQRView.swift:150](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Profile/ProfileQRView.swift:150) |
| `exportError = L10n.string("Couldn’t save diagnostic logs. Try again.")` | [whitenoise-ios/Settings/DeveloperToolsSettingsView.swift:176](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Settings/DeveloperToolsSettingsView.swift:176) |
| `exportError = L10n.string("Couldn’t read diagnostic logs. Try again.")` | [whitenoise-ios/Settings/DeveloperToolsSettingsView.swift:195](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Settings/DeveloperToolsSettingsView.swift:195) |
| `errorMessage = L10n.string("Couldn’t load sharing settings. Try again.")` | [whitenoise-ios/Settings/DeviceDiagnosticsConsent.swift:83](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Settings/DeviceDiagnosticsConsent.swift:83) |
| `errorMessage = L10n.string("Couldn’t save sharing settings. Your change was not confirmed. Try again.")` | [whitenoise-ios/Settings/DeviceDiagnosticsConsent.swift:123](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Settings/DeviceDiagnosticsConsent.swift:123) |
| `error = L10n.string("Erasure didn’t finish. Some data may remain. Try again.")` | [whitenoise-ios/Settings/EraseAppDataView.swift:37](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Settings/EraseAppDataView.swift:37) |
| `auditErrorMessage = L10n.string("Couldn’t save diagnostic logging settings. Try again.")` | [whitenoise-ios/Settings/PrivacySecuritySettingsViewModel.swift:281](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Settings/PrivacySecuritySettingsViewModel.swift:281) |
| `error = L10n.string("Couldn't load your profile. Close and reopen this screen to retry.")` | [whitenoise-ios/Settings/ProfileEditViewModel.swift:135](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Settings/ProfileEditViewModel.swift:135) |
| `saveError = L10n.string("Keep at least one relay.")` | [whitenoise-ios/Settings/RelaysViewModel.swift:261](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Settings/RelaysViewModel.swift:261) |
| `error = L10n.string("Couldn’t sign out. Try again.")` | [whitenoise-ios/Settings/SettingsView.swift:406](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Settings/SettingsView.swift:406) |
| `scanError = L10n.string("That QR code isn't a White Noise profile.")` | [whitenoise-ios/Settings/ShareAndConnectView.swift:155](/Users/jeff/code/whitenoise-ios/whitenoise-ios/Settings/ShareAndConnectView.swift:155) |

## Review boundaries

- Do not assume the Rust display template is the iOS message: typed details omit some Rust prefixes, host overrides replace others, and unhandled fieldless types use the generic fallback.
- The direct-chat “isn't on White Noise yet” route includes unusable KeyPackage errors. That current classification and the generic Runtime recipient-capabilities message are different paths; this document records both without changing them.
- Generic Runtime text does not provide a stable machine-readable classification. Any future typed handling should use a native contract rather than match English substrings.
- Errors such as `CreatedGroupProjectionUnavailable` and worker response timeouts can represent an operation that already completed. Their source semantics matter during a future copy review; a blanket Retry label is not a safety guarantee.
- This inventory was extracted from source only, without opening device audit logs or collecting real user error payloads. No production message examples or secrets were used.
- Updating the MDK pin or host overrides can change the inventory. Regenerate/recheck the finite enum list, conversion tables, local error declarations, and call-site index before treating this as current for a later release.
