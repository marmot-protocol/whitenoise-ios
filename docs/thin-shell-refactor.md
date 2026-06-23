# Thin-Shell Refactor Plan

Goal: make the iOS app the thinnest possible UI layer over the Marmot/MarmotKit
bindings. The bindings own storage, state, and projection. iOS owns only
rendering, lifecycle, navigation, and genuinely UI-local state (optimistic
sends, decoded media, scroll/geometry).

This is a sequencing plan, not a rewrite. Each phase ships independently. We do
**not** do classic MVVM/repository layering, and we do **not** aim for
zero-cache. We aim for *no logic in the iOS layer that the bindings can own*.

---

## Principles (the rubric every change is measured against)

1. **One seam.** All Marmot access goes through `MarmotClient`'s async,
   off-main wrappers. Views and stores never call synchronous FFI on the
   MainActor and never hold the raw `Marmot` handle.
2. **Push derivation down.** Where iOS re-derives data the bindings could
   project (reaction tallies, reply order, media references, `sourceEpoch`),
   move it into Rust. Each pushdown deletes iOS code.
3. **Caches are dumb mirrors.** A cache may hold the last projection the
   bindings emitted. It may **not** merge, sort, aggregate, or interpret. A
   cache with logic is a second source of truth.
4. **No second storage path** for data Marmot already owns (per AGENTS.md).
5. **Strangler, not big-bang.** Binding changes are additive first (new
   optional fields), iOS switches to read them, then the old iOS path is
   deleted once parity is confirmed. No long-lived refactor branch.

### State taxonomy — apply to every piece of state

| Bucket | Rule | Examples |
|--------|------|----------|
| **Genuine UI state** | Keep in iOS. Marmot can't model it. | optimistic send/fail status, decrypted-media plaintext cache, decoded thumbnails/avatars, scroll/geometry/toast/nav, recent-reactions pref, in-flight download dedup, draft media processing |
| **Binding gaps** | Push the projection into Rust. | `sourceEpoch` missing from timeline records, reaction tallies incl. "mine", reply-order normalization, media classification from `imeta` |
| **Dumb mirrors** | Keep, but strip all logic. | `messageById` window, profile projection cache, unread index, chat-list row/item caches |

---

## Current state (baseline, measured)

- `MarmotClient` (481 lines) is already a stateless async-offload wrapper —
  **this is the target shape**, keep it.
- Bindings expose ~125 methods with durable projections (chat-list rows,
  timeline pages w/ pagination, reaction summaries, reply previews, unread
  aggregates). Marmot already does most projection work.
- `AppState.swift` is ~1,340 lines / 55KB owning 11+ concerns; every view
  injects the whole object via `@Environment(AppState.self)`.
- `ConversationViewModel.swift` is 3,179 lines — mostly re-derivation of
  binding-owned data.
- **39** direct `appState.marmot.<sync FFI>` call sites across 10 files (the
  MainActor-blocking path) vs **21** correct `currentMarmotClient()` sites.
- Only 2 of ~21 screens use a view model; 19 embed Marmot calls in `body`.

Cross-repo: the Rust source of truth is `/Users/jeff/code/darkmatter`.
Bindings regenerate via `scripts/sync-bindings.sh` into `Vendored/MarmotKit`.

---

## Phase dependency graph

```
Phase 0 (guardrails) ──> Phase 1 (one seam) ──> Phase 2 (decompose AppState)
                                  │
                                  ├──> Phase 3 (push projections into Rust) ─┐
                                  │                                          ├──> Phase 5 (shrink ConversationVM)
                                  └──> Phase 4 (screen-store template) ──────┘
```

Phases 1 and 2 are mostly mechanical and low-risk. Phase 3 (cross-repo) and
Phase 4 can run in parallel. **Phase 5 must come last** — reorganizing the big
view model before the pushdowns just relocates the bloat instead of deleting
it. This is the single most important sequencing rule.

---

## Phase 0 — Guardrails

**Goal:** pin the behavior we're about to move, so Rust parity and store
extraction are verifiable.

**Scope / approach**
- Extract the re-derivation decision points into pure, `nonisolated` helpers
  (several already are static: `normalizedReplyOrdering`, the
  `recomputeReactions` aggregation, media classification in `MessageSemantics`).
- Write golden/characterization tests over those helpers with realistic
  fixtures (reply chains, mixed reactions incl. own, media `imeta` variants,
  optimistic overlays). These become the **parity oracle** for Phase 3 — the
  Rust projection must reproduce the same outputs.
- Capture a fixture set that can be shared with the Rust repo
  (`crates/marmot-app/src/projection/tests.rs` already exists).

**Validation:** new Swift Testing files (auto-included in the synchronized
test group); `xcodebuild test` on iPhone 17 Pro.

**Done when:** reply-order, reaction-aggregation, and media-projection logic
each have behavior tests that we can run against both the current Swift impl
and (later) the Rust output.

**Size:** S–M.

---

## Phase 1 — One seam (unify the Marmot access path)

> **Reconciled against the code (2026-06-22).** The "39 MainActor-blocking
> sites" premise was wrong. Classifying the 27 directly-called methods against
> the generated bindings: **26 are already `async`** (they suspend, not block),
> and the one remaining sync call, `npub`, is a trivial bech32 encode
> (microseconds, no I/O) — blocking on it is harmless, and making it `async`
> would push async churn into 4 view sites for zero benefit. The heavy sync
> reads that genuinely blocked (chatList, timelineMessages, accountUnreadSummary,
> notificationSettings, parseMarkdown, normalizeMemberRef, accountIdHex, …) were
> **already wrapped** in `MarmotClient`. So Phase 1's correctness work is
> effectively **done**. The remaining value is pure seam *discipline* (route the
> async calls through `MarmotClient`, then make the raw handle inaccessible) —
> and since the handle can't be locked down until the Phase 4/5 screens/VM stop
> using it, that routing is best **folded into the Phase 4/5 rewrites** rather
> than churning the same files twice. Net: no standalone Phase 1; lock the handle
> down as the final step after 4/5.

**Original goal:** eliminate MainActor-blocking FFI and make `MarmotClient` the
only way to reach Marmot.

**Scope (measured):** 39 direct `appState.marmot.` sites in:
GroupDetailsView (12), ConversationViewModel (11), DiagnosticsView (5),
KeyPackagesView (3), ChatsListView (3), ProfileEditView (1), ProfileView (1),
ComposerMentionSupport (1), NewChatSheet (1), ChatsListViewModel (1).

**Approach**
1. Classify each site: **synchronous FFI** (npub, displayName, parseMarkdown,
   normalizeMemberRef, accountIdHex, …) vs **already-async** (`subscribe*`
   returning subscription handles). Only the synchronous ones are bugs.
2. Add any missing async wrappers to `MarmotClient` (mirror the existing
   `Task.detached` pattern). Subscription setup legitimately needs the handle —
   route it through a single `MarmotClient` method so the raw handle never
   escapes to the view layer.
3. Convert all 39 sites; for subscriptions, expose a `MarmotClient` factory.
4. **Enforce:** make the raw `Marmot` handle inaccessible from views/stores —
   `private`/`internal` to `MarmotClient`, or mark `appState.marmot` deprecated
   so new sync-on-main calls fail review. Add a lightweight test/lint that the
   view layer references only `MarmotClient`.

**Risks:** a couple of these calls are hot (mention rendering, markdown) — make
sure async conversion doesn't introduce visible flicker; cache the result in
the dumb-mirror bucket where needed.

**Validation:** `xcodebuild test`; manual scroll/markdown/mention smoke; watch
for main-thread hangs.

**Done when:** zero synchronous-FFI-on-MainActor call sites; the raw handle is
not reachable from the view layer.

**Size:** M.

---

## Phase 2 — Decompose AppState into services

**Goal:** turn the 1,340-line god object into a thin composition root over
focused, individually testable services.

**Scope:** `AppState.swift` (+`AppState+Profiles.swift` 18KB,
`+Routing.swift`, `+Toasts.swift`). Existing MARK regions: Bootstrap,
Notifications, Identity management.

> **First slice scoped (2026-06-22): `ProfileStore` — ready to execute.**
> `toastState`/`navigation` are already extracted (the app entry injects them
> separately), so `ProfileStore` is the cleanest remaining seam: it already lives
> in its own `AppState+Profiles.swift` and is a dumb-mirror cache + two queues.
>
> *Mechanics:*
> - New `darkmatter-ios/Core/ProfileStore.swift`: a `@MainActor` class (NOT
>   `@Observable` — see observation note) with `weak var appState: AppState?`.
>   Move both structs (`ProfileProjectionRequest`, `ProfileDisplayProjection`)
>   and all the machinery from `AppState+Profiles.swift` into it.
> - Move these 11 stored props off `AppState` (currently L248–257) into
>   `ProfileStore`: `profileFetchQueueTask`, `queuedProfileFetchIDs`,
>   `scheduledProfileFetchIDs`, `activeProfileFetchID`, `profileProjectionCache`,
>   `profileProjectionLoadTask`, `queuedProfileProjectionLoadIDs`,
>   `scheduledProfileProjectionLoadIDs`, `profileProjectionRefreshAfterLoadIDs`,
>   `profileProjectionLoadVersions`. **Keep `profileRefreshGeneration` (L279) on
>   `AppState`** so SwiftUI observation is unchanged; `ProfileStore` reads it via
>   `appState?.profileRefreshGeneration` and bumps via
>   `appState?.noteProfileRefreshCompleted()`.
> - Rewire the 7 deps through `appState?.`: `marmot`, `canRefreshProfiles`,
>   `accounts`, `activeAccountRef`, `relayBootstrapRelays(for:)`,
>   `noteProfileRefreshCompleted()`, `profileRefreshGeneration`.
> - `AppState+Profiles.swift` becomes thin forwarders (`appState.profile(...)`
>   etc. → `profileStore.…`) so external call sites are untouched. `npub` /
>   `shortNpub` stay on `AppState` (they use `marmot`, not the cache).
> - `AppState` gets `let profileStore = ProfileStore()` wired in init
>   (`profileStore.appState = self`); update internal refs at L356–361 (cancel +
>   bump), L788–797 (sign-out clears cache + versions), L1105
>   (`resumeProfileFetchQueueIfNeeded`), L1156 (`cancelProfileFetchQueue`),
>   L1188–1189 (`updateProfileProjectionLocalAccountLabels` +
>   `warmLocalAccountProfileProjections`).
> - Tests: `darkmatter_iosTests.swift` L927/L937 access
>   `appState.profileProjectionCache` directly → repoint to
>   `appState.profileStore.profileProjectionCache`; DEBUG hooks
>   (`runProfileFetchQueueForTesting`, `pruneProfileProjectionLoadVersionIfSettledForTesting`)
>   forward to `profileStore`; check the source-scrape at L820
>   (`resumeProfileFetchQueueIfNeeded\(\)`) still matches.
>
> *Observation note:* keep `profileRefreshGeneration` on `AppState`. With
> `@Observable`, a view calling `appState.displayName(id)` that reads
> `appState.profileRefreshGeneration` still tracks that access, so live
> profile-name updates survive the move — but this is a SwiftUI runtime behavior
> unit tests won't catch, so **verify by running the app** (open a chat, confirm
> peer names/avatars resolve and update live) before considering it done.
>
> *Preserve the ABA invariant* in `pruneProfileProjectionLoadVersionIfSettled` /
> `cancelProfileFetchQueue` verbatim — do not reset the version map wholesale.

**Target services** (each `@MainActor @Observable`, owned by `AppState`):
- `RuntimeLifecycle` — bootstrap, suspend/resume, runtime generation, the
  foreground/suspension gates, background-task ownership. (Already the most
  self-contained machinery.)
- `AccountStore` — `accounts`, active account ref, unread index, create /
  import / sign-out / nsec reveal/export.
- `NotificationCoordinator` — subscription runner (extends the existing
  `NotificationDriver`), native-push registration sync, foreground catch-up.
- `ProfileStore` — the entire `AppState+Profiles` machinery (load queue,
  version tokens, refresh queue, projection cache). This is a dumb-mirror cache
  by definition; keep it, just isolate it.
- `Navigation` / `ToastCenter` — already partly extracted.

`AppState` keeps only: composition wiring, phase routing, and cross-service
glue. Views inject the specific service they need, not the whole `AppState`
(reduces the fat-injector coupling), though `AppState` can stay the
environment entry point during migration.

**Approach:** extract one service at a time behind its current public surface;
move state + methods, leave a thin forwarding shim on `AppState` until call
sites migrate, then delete the shim. Preserve the documented lifecycle
invariants in AGENTS.md (bootstrap clearing gates + incrementing generation,
MainActor-owned background task ids, telemetry build-config fallback, etc.) —
add tests for each as it moves.

**Validation:** `xcodebuild test`; the lifecycle/notification manual tests in
`docs/manual-tests.md` (suspend/resume, background push, sign-out).

**Done when:** `AppState` is a composition root (target < ~300 lines); each
service has focused tests; lifecycle invariants are test-pinned.

**Size:** L (do it service-by-service, ship each).

---

## Phase 3 — Push projections down into the bindings (cross-repo)

**Goal:** delete iOS re-derivation by making the bindings emit display-ready
data. This is the phase that actually achieves "thin shell."

> **Reconciled against the actual Rust code (2026-06-22).** The library is far
> richer than first assumed. `TimelineMessageRecordFfi` already carries
> `reply_to_message_id_hex`, `reply_preview`, `reactions` (`by_emoji` → senders
> + `user_reactions`), `deleted`/`deleted_by`, `content_tokens` (pre-parsed
> markdown AST), and `media_json` (raw `imeta`). `MediaAttachmentReferenceFfi`
> already carries `source_epoch`. The subscription already emits fine-grained
> `Upsert`/`Remove` deltas. **Three of the four originally-imagined pushdowns
> are already done or belong in iOS.** Net required Rust work is ~one change.
> Full spec lives in `docs/thin-shell-rust-prompt.md` (hand to the Rust repo).

**Rust targets** (`/Users/jeff/code/darkmatter`):
- FFI structs + resolution: `crates/marmot-uniffi/src/conversions/{timeline,media}.rs`
- App-layer record (if resolution lives there): `crates/marmot-app/src/lib.rs`,
  internal record in `crates/storage-sqlite/src/timeline.rs`
- Tests: `crates/marmot-uniffi/src/conversions/` (+ `marmot-app/src/projection/tests.rs`)
- Regenerate: `OTLP_EXPORT=1 ./crates/marmot-uniffi/xcframework.sh`, then iOS
  `DARKMATTER_DIR=/Users/jeff/code/darkmatter ./scripts/sync-bindings.sh`

**Required change (additive-then-delete):**

- **Resolved media references on timeline rows.** Add
  `media: Vec<MediaAttachmentReferenceFfi>` to `TimelineMessageRecordFfi` and
  `TimelineReplyPreviewFfi`, built from each message's `imeta` tags + the
  message's own `source_epoch` (reusing `list_media`'s resolution +
  validation). Today the row carries only `media_json` (raw `imeta`), and
  `source_epoch` is **not** an `imeta` field — so iOS calls `listMedia()`
  separately and maintains `mediaRecordsByMessageId` +
  `mediaRecordReferencesByKey` purely to recover `source_epoch`. → deletes both
  indexes, the extra fetch, **and** the per-rebuild `imeta` classification in
  `mediaItemProjectionsByRowId`. (Merges the original pushdowns #1 + #4.)
  - **Decided behavior change (2026-06-22):** the Rust projection drops only a
    malformed `imeta` and keeps the other valid attachments (drop-bad), where
    today's iOS parser degrades the whole message to text (all-or-nothing). This
    is the one intentional behavior change in the swap; pinned in
    `MediaImetaProjectionParityTests` and flipped at the parity hook. Worth a
    line in `docs/manual-tests.md` when iOS adopts the field.

**Optional polish (low value):** add per-emoji `count` + pre-sorted `by_emoji`
to the reaction summary so iOS skips a sort. The senders list already suffices;
"mine" + optimistic overlay stay in iOS.

**Reclassified — NOT a pushdown, stays in iOS:**
- *Reaction aggregation* — `by_emoji` with senders is already the aggregation;
  only the optimistic overlay (`reactionRecords`, `optimisticReactionRemovals`)
  remains, and that is inherently UI state.
- *Reply-order normalization* — presentation over the loaded window; moving it
  into Rust complicates pagination for no gain. `normalizedReplyOrdering` stays.
- *Markdown* — `content_tokens` is already on the row; iOS should consume it
  rather than re-calling `parseMarkdown` (verify/fix in Phase 5). Display-block
  building stays in iOS.

**Parity:** assert the new row `media` equals `list_media`'s references for the
same message (shared helper). Ship additively, switch iOS to `media` behind a
fallback, confirm, then a follow-up removes `media_json` + the iOS timeline
`listMedia` path.

**Validation:** Rust conversion/projection tests; regenerate bindings; iOS
`xcodebuild test`; Release build for `generic/platform=iOS`.

**Done when:** the timeline renders and downloads media from row `media`, and
`mediaRecordsByMessageId` / `mediaRecordReferencesByKey` / the timeline
`listMedia` path are deleted from `ConversationViewModel`.

**Size:** L (cross-repo; each pushdown is independently shippable).

---

## Phase 4 — Screen-store template + convert view-embedded screens

**Goal:** one consistent, *thin* pattern for the 19 screens that embed Marmot
calls in `body`. Not MVVM-with-services — a "screen store."

**Template (`*Store`, `@MainActor @Observable`):**
- Owns subscription lifecycle (start on appear, cancel in deinit).
- Holds only UI/optimistic state (`isLoading`, `error`, in-flight flags,
  staged input).
- Renders binding projections **directly** — no re-projection in Swift.
- All Marmot access via `MarmotClient` (Phase 1 guarantees this).
- `ChatsListViewModel` is the reference (it's ~80% there already); trim its
  remaining direct `appState.marmot` swipe-action calls as part of this.

**Conversion order (smallest/most-isolated first):**
1. Settings cluster: `ProfileEditView`, `NotificationSettingsView`,
   `RelaysView`, `KeyPackagesView`, `PrivacySecuritySettingsView`,
   `IdentityView`.
2. Group/Profile: `GroupDetailsView` (largest offender, 12 direct calls),
   `NewChatSheet`, `ProfileView`, `AddMembersSheet`.
3. Onboarding: `ImportIdentityView`, `CreateIdentityView`.
4. `DiagnosticsView`.

Each screen: extract its async methods + `@State` into a store, render
projections, add a behavior test for any non-trivial decision (per AGENTS.md,
extract a pure helper rather than scraping source).

**Validation:** `xcodebuild test` per screen; manual walk of the touched
settings/identity flows.

**Done when:** no Marmot calls or business logic remain in a SwiftUI `body`;
every screen with backend interaction has a store following the template.

**Size:** L (per-screen, parallelizable, each ships on its own).

---

## Phase 5 — Shrink ConversationViewModel

**Goal:** reduce the 3,179-line view model to genuine UI state. This lands
*naturally* once Phase 3 deletes the re-derivation and Phase 4 establishes the
store template.

**Approach**
- **Media slice (ready-to-execute design, scoped 2026-06-22).** The row's new
  `media: [MediaAttachmentReferenceFfi]` lives on `TimelineMessageRecordFfi`, but
  the VM stores `AppMessageRecordFfi` in `messageById` (no `media` field). So
  capture it at ingest exactly like the existing reaction/reply-preview pattern:
  - `applyTimelineRecord` (~L1315) already does
    `replyPreviewsByMessageId[id] = record.replyPreview` and
    `projectedReactionSummaries[id] = record.reactions`. Add
    `mediaReferencesByMessageId[id] = record.media` alongside it (and capture in
    `applyTimelinePage`'s record loop).
  - Rewrite `buildMediaItemProjection` (~L1758) to read
    `mediaReferencesByMessageId[record.messageIdHex]` instead of
    `mediaRecordsByMessageId` (listMedia) and the `MessageSemantics.classify`
    tag-classification fallback.
  - `downloadableMediaReference` (~L1809) can drop the `sourceEpoch == 0`
    fallback — row references already carry the real epoch; delete
    `mediaRecordReference(matching:)` + the index.
  - **Delete**: `mediaRecordsByMessageId`, `mediaRecordReferencesByKey`,
    `refreshMediaRecords`, `scheduleMediaRecordsRefresh`,
    `rebuildMediaRecordReferenceIndex`, `replaceMediaRecordsByMessageId`,
    `replaceMediaRecords`, and the `client.listMedia` call for the timeline.
    (`listMedia` may stay in `MarmotClient` for a future media-gallery surface.)
  - **Test fallout**: rewrite the ~4 tests built on `replaceMediaRecordsForTesting`
    / `mediaRecordsByMessageId` (e.g. `timelineMediaItemsUseCachedSortedRecordProjection`,
    `mediaRecordUpdateRefreshesOnlyChangedTimelineProjection`,
    `mediaRecordReferenceLookupUsesIndexedNormalizedIdentity`) to drive
    `mediaReferencesByMessageId` via a timeline record carrying `media`.
  - **Behavior change lands here**: drop-bad (the row drops a malformed `imeta`
    and keeps valid ones). Flip the `MediaImetaProjectionParityTests` corpus's
    malformed-multi case from `nil` to `[valid]` and enable the consumption check.
- After the media slice: reaction aggregation, reply ordering, and markdown
  display-block building stay (reclassified as UI state), but clean up: consume
  row `content_tokens` instead of re-parsing, keep the reaction path to a thin
  optimistic overlay.
- Split the remainder by concern into focused stores:
  - `TimelineStore` — subscription + `messageById` dumb mirror + optimistic
    overlay (pending/failed sends), pagination cursors, coalesced read-marking.
  - `MediaController` — downloads, in-flight dedup, decrypted-media cache
    (already partly isolated as `MediaDownloadInFlightStore`).
  - `ComposerModel` — draft text/media, reply target, mention candidates.
  - `StreamWatcher` — agent text streams (QUIC), debug rows.
- Keep optimistic overlays as the only "merge" logic, and keep it minimal: the
  binding projection is truth, the overlay is a thin diff applied on top.

**Validation:** Phase 0 oracle still green; full conversation manual test
(send/react/reply/media/pagination/streams); `xcodebuild test`.

**Done when:** `ConversationViewModel` is decomposed; the timeline path holds
only UI/optimistic state over binding projections (target ~500–800 lines
total across the split stores).

**Size:** L.

---

## Validation commands (all phases)

```sh
# Unit/behavior tests
xcodebuild test -project darkmatter-ios.xcodeproj -scheme darkmatter-ios \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'

# Release build sanity (binding changes)
xcodebuild build -project darkmatter-ios.xcodeproj -scheme darkmatter-ios \
  -configuration Release -destination 'generic/platform=iOS'

# Format gate
git diff --check

# Regenerate bindings after Rust changes
./scripts/sync-bindings.sh
```

For lifecycle/notification/binding changes, also walk the relevant items in
`docs/manual-tests.md`. Do not babysit the simulator across a long run — prefer
polling over re-running.

---

## Explicit non-goals

- No classic MVVM / repository / service-per-entity abstraction. The bindings
  are the repository.
- No zero-cache. Dumb mirrors are fine; logic in caches is not.
- No new storage path for Marmot-owned data.
- No reorganizing `ConversationViewModel` before Phase 3.

---

## Attack checklist

- [x] Phase 0 — media parity oracle (`MediaImetaProjectionParityTests`); reply-order
      & reaction aggregation already covered by existing tests
- [x] Phase 1 — reconciled: the genuine blocking reads were already wrapped in
      `MarmotClient`; the rest is non-blocking/trivial. Seam routing + handle
      lockdown fold into Phase 4/5 (no standalone phase)
- [x] Phase 3 — merged (darkmatter#570) + bindings synced (127fe17) + fixtures migrated
- [x] **Phase 5a (media slice)** — done (commit `4d46058`, +56/−242): `record.media`
      mirrored at ingest into `mediaReferencesByMessageId`; deleted the `listMedia`
      timeline path + index maps + sourceEpoch recovery. Drop-bad now via the Rust
      row; Swift parser retained as the local/optimistic fallback (oracle unchanged)
- [ ] Phase 2 — extract services from AppState; AppState → composition root
      - [x] `ProfileStore` (commit `8e7f089`): profile cache + load/refresh queues
            → `@MainActor ProfileStore`; `profileRefreshGeneration` stays on AppState
            for observation; AppState+Profiles.swift now thin forwarders
      - [x] `AccountUnreadStore` (commit `0eb5bba`): unread badge index → pure
            `@Observable` store (index methods take `accounts` as a param, no
            back-ref); AppState keeps the Marmot fetch + read forwarder
      - [x] `AccountStore` (commit `fdc88a0`): account list + `activeAccountRef`
            (+ its UserDefaults `didSet`/key) + `activeAccount` → pure `@Observable`
            store; AppState forwarders + still drives refresh/identity lifecycle
      - [ ] `RuntimeLifecycle` (bootstrap, suspend/resume, gates, gen, bg tasks) —
            most entangled; verify suspend/resume by running the app, not just tests
      - [ ] `NotificationCoordinator` (subscription runner, native-push, catch-up)
- [ ] Phase 4 — screen-store template; convert view-embedded screens
      - [x] template established + `RelaysView` → `RelaysViewModel` (commit `1356c5e`):
            `@Observable` store owns load/save/validation + UI state; view is pure
            rendering; store takes `AppState` as a method param (no retain)
      - [x] `KeyPackagesView` → `KeyPackagesViewModel` (commit `42104fb`): CRUD
            shape (list/publish/delete); pure presentation statics stay on the view
      - [x] `PrivacySecuritySettingsView` → `PrivacySecuritySettingsViewModel`
            (commit `9400762`): telemetry/audit settings + actions; dev-mode
            toggles stay bound to AppState
      - [x] `IdentityView` → `IdentityViewModel` (commit `77bdb55`): nsec export
            flow + sheet/confirm flags; identity reads stay on AppState forwarders
      - [x] `NotificationSettingsView` → `NotificationSettingsViewModel`
            (commit `fc90364`): the "entanglement" is in AppState's push methods
            (which stay); the view was a clean state+actions conversion, no coupling
      - [ ] `ProfileEditView` — DEFERRED: worst-coupled, ~6 source-scrape patterns
            (`ProfileEditViewTests`, `ResolvedDisplayNameTests`,
            `MarmotClientStorageReadOffloadTests`, the L10n-key guard) that split
            across view (pictureURL, saveDisabled, the draft structs) and VM
            (publish: relayPublishRelays/relayBootstrapRelays/reloadProfileProjection/
            normalizedMetadata.ffi). Needs the scrape tests split view-vs-VM — do
            it deliberately, not rushed.
      - [x] `ProfileView` → `ProfileViewModel` (commit `bae9530`): reference
            resolution + Message action; `npub`/`dismiss` passed as method params
      - [x] `NewChatSheet` → `NewChatSheetViewModel` (commit `daee487`): recipient
            staging + create; #260/#274 concurrency moved verbatim; tested
            normalization statics stay on the view
      - [x] `ImportIdentityView` → `ImportIdentityViewModel` (commit `ace5a37`): nsec
            import; secret consume/clear order preserved verbatim; clears-secret
            source-scrape repointed to the VM
      - [x] `CreateIdentityView` → `CreateIdentityViewModel` (commit `a80f1ca`)
      - [x] `AddMembersSheet` → `AddMembersSheetViewModel` (commit `ffc44a1`):
            callback-based; parent's `normalize`/`onSubmit` passed as method params;
            #260/#274 concurrency verbatim; AddMembersPresentation helpers stay
      - [x] `DiagnosticsView` → `DiagnosticsViewModel` (commit `8e5affa`): event-stream
            log + send-to-self; view keeps `.task(id: runtimeGeneration)` owning the
            stream lifecycle (calls `runEventStream`); tested `diagnosticText` static +
            `DiagnosticSelfSend` stay; VM added to FFI-guard list
      - [x] `ProfileEditView` → `ProfileEditViewModel` (commit `abe6861`): editable
            kind:0 fields + load/publish + per-field validation messages; pure
            draft/metadata types stay in the view file; `saveDisabled` stays in the
            view (reads `appState.activeAccountRef`). Five source-scrapes across 3 test
            files repointed to follow the moved publish/validation code.
      - [ ] Remaining (large/structural only): GroupDetailsView (1016 lines — large).
            Pure-UI/navigation screens (WelcomeView, AppearanceSettingsView,
            AccountsView, AccountSwitcherSheet) have little/no logic to extract.
            **All bounded screens are now converted (12 screens).**

> **App-run verification (2026-06-22):** built + launched on the iPhone 17 Pro
> sim. App boots healthy to Chats (not onboarding) → persisted account loads,
> confirming `AccountStore`'s relaunch persistence; avatar + chrome render,
> confirming the profile/account observation forwarding. No crash after the
> store extractions. Deep live-update checks (account-switch badges) need a
> populated account.
- [ ] Phase 5b — decompose ConversationViewModel into TimelineStore /
      MediaController / ComposerModel / StreamWatcher
