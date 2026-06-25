# Darkmatter (Marmot) binding work — iOS thin-shell refactor

Copy this whole file as the task prompt in a `darkmatter` repo session
(your local checkout root, e.g. `$DARKMATTER_DIR`). It is self-contained.

---

## Context

The iOS app (`whitenoise-ios`) is being refactored into a thin UI shell over
these bindings. The library already projects almost everything iOS needs on each
timeline row. This task closes the **one** real gap so iOS can stop
reconstructing data through a secondary call, plus one optional polish item.

Read this whole prompt before starting — the "already exists" and "do NOT build"
sections matter as much as the change itself.

## What already exists — do NOT rebuild it

`TimelineMessageRecordFfi`
(`crates/marmot-uniffi/src/conversions/timeline.rs:124`) already carries, per
row:

- `reply_to_message_id_hex: Option<String>` and
  `reply_preview: Option<TimelineReplyPreviewFfi>`
- `reactions: TimelineReactionSummaryFfi` — `by_emoji: Vec<{ emoji, senders }>`
  plus `user_reactions: Vec<…>`
- `deleted: bool`, `deleted_by_message_id_hex: Option<String>`
- `content_tokens: MarkdownDocumentFfi` — markdown is **already parsed** server-side
- `media_json: Option<String>` — raw NIP-92 `imeta` tags as JSON
- `agent_text_stream_json`, `group_system`, `invalidation_status`

`MediaAttachmentReferenceFfi` (`conversions/media.rs:36`) already carries
`source_epoch: u64`. The timeline subscription already emits fine-grained
`TimelineMessageChangeFfi::Upsert`/`Remove` deltas plus a `chat_list_row`, and
pagination via `paginate_backwards`/`paginate_forwards`. None of this needs
changing.

---

## Core change (required): resolved media references on timeline rows

**Problem.** The row exposes media only as `media_json` (raw `imeta` tags).
`source_epoch` is **not** an `imeta` field — the runtime carries it as record
metadata. So iOS cannot build a downloadable `MediaAttachmentReferenceFfi` from
`media_json` alone. Today iOS calls `list_media()` separately and maintains two
index maps purely to recover each attachment's `source_epoch`. That whole detour
exists only because the row's media isn't fully resolved.

**Change.** Project fully-resolved media references onto the timeline row (and
reply preview), built from the message's `imeta` tags + the message's own
`source_epoch`.

- `crates/marmot-uniffi/src/conversions/timeline.rs`
  - Add to `TimelineMessageRecordFfi`: `pub media: Vec<MediaAttachmentReferenceFfi>`
    (empty when the message has no media). **Keep `media_json` for now** — this
    is additive; a follow-up removes it once iOS has migrated.
  - Add the same `media: Vec<MediaAttachmentReferenceFfi>` to
    `TimelineReplyPreviewFfi` (a reply can target a media message).
- Build each reference with the existing `imeta` → reference helper used by
  `list_media` (`crates/marmot-uniffi/src/conversions/media.rs`, the
  `media_attachment_from_imeta_tag(tag, source_epoch)` path around line 213),
  passing the message's `source_epoch`. The internal records already have it:
  `TimelineMessageRecord.source_epoch` (`crates/storage-sqlite/src/timeline.rs`)
  and `AppMessageRecord.source_epoch` (`crates/marmot-app/src/lib.rs`).
- **Match `list_media`'s validation exactly**, and on a malformed `imeta` tag
  **drop only that attachment, keeping the other valid ones** (per-attachment,
  not all-or-nothing). DECIDED 2026-06-22 — this is the intended behavior even
  though the legacy iOS timeline parser currently degrades the whole message to
  text; iOS will adopt drop-bad when it switches to this field. A bad `imeta`
  must never hide a kind-9 message. Concretely: a message with one valid + one
  malformed `imeta` yields `media.len() == 1` (the valid one), not 0.
- Choose where resolution lives:
  - Simplest: resolve in the `marmot-app` → FFI conversion layer (it has both
    the `imeta` tags and `source_epoch`).
  - If the app-layer projection is the cleaner home, add a resolved
    `Vec<MediaAttachmentReference>` to the app-layer record and map it through
    the `From` impl. Prefer whichever keeps a single source of truth for the
    `imeta` → reference logic shared with `list_media`.

**Acceptance criteria.**
- A kind-9 message with N `imeta` attachments yields `media.len() == N`, each
  with the correct `source_epoch`, `locators`, `ciphertext_sha256`,
  `plaintext_sha256`, `nonce_hex`, `file_name`, `media_type`, `version`, `dim`,
  `thumbhash`.
- Malformed `imeta` → that attachment is dropped, **other valid attachments on
  the same message survive**; a message whose every `imeta` is bad appears as
  text with no media.
- A reply preview targeting a media message carries its resolved `media`.
- `list_media` and the new row `media` produce identical references for the
  same message (shared helper — assert this in a test).

**Tests.** Add conversion tests beside the existing ones in
`conversions/timeline.rs` (and a projection parity test in
`crates/marmot-app/src/projection/tests.rs` if resolution lives in `marmot-app`).
Fixtures: single image; multi-attachment; malformed `imeta`; reply-to-media.

---

## Optional polish (low priority): reaction tally

Already sufficient — `by_emoji` carries `senders`, so iOS derives `count` and
"did I react" trivially and overlays its own optimistic react/unreact (which
**must** stay in iOS). Only if convenient:

- Add `count: u32` per emoji and emit `by_emoji` pre-sorted (count desc, then
  emoji asc) so iOS skips a sort.

Do **not** compute a "mine" flag or fold in optimistic state in Rust — that is
viewer/UI state and belongs in iOS.

---

## Explicitly NOT needed — keep in iOS

- **Reply-order / threading.** Keep emitting rows chronologically. iOS applies
  presentation-level reply ordering over its loaded window; moving it into Rust
  would complicate pagination (replies whose parents sit on another page) for no
  real gain.
- **Optimistic send/react/delete state, decoded media bytes, thumbnails,
  markdown *display* blocks.** Inherently UI-side. (`content_tokens` already
  gives iOS the parsed AST; turning that into render blocks stays in iOS.)

---

## Compatibility & sequencing

- Every addition is additive (new field defaults to empty). Ship it; iOS
  switches to reading `media`, confirms parity against `list_media`, then a
  follow-up PR removes `media_json` and the iOS `list_media`-for-timeline path.
- Workspace version is `0.2.0` (`Cargo.toml`); there is no ABI pin between the
  repos. After merge, iOS picks the change up with:
  `DARKMATTER_DIR=<your darkmatter checkout> ./scripts/sync-bindings.sh`.

## Build / test / regenerate

```sh
# Build + regenerate the Swift xcframework & bindings (OTLP on, as iOS uses)
OTLP_EXPORT=1 ./crates/marmot-uniffi/xcframework.sh

# Tests
cargo test -p marmot-uniffi --lib conversions
cargo test -p marmot-app   --lib projection
cargo test -p marmot-uniffi --test smoke

# Lint / typecheck
just check && just clippy
```

Generated files (`crates/marmot-uniffi/output/MarmotKit.swift`, the `*FFI.h`
headers) carry "do not edit" markers — change the Rust types/conversions and
regenerate; never hand-edit generated output.

---

## One-line summary for the PR

> Project fully-resolved `media: Vec<MediaAttachmentReferenceFfi>` (with
> `source_epoch`) onto `TimelineMessageRecordFfi` and `TimelineReplyPreviewFfi`,
> sharing `list_media`'s `imeta` resolution + validation, so the iOS client can
> render and download timeline media without a separate `list_media()` call.
