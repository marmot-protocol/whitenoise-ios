# Timeline projection boundary

This is the audit inventory for whitenoise-ios#396. The rule from `docs/thin-shell-refactor.md` still applies: iOS may mirror Marmot projections and layer UI-local optimism on top, but it must not build a competing source of truth for timeline state.

## Binding projection mirrors

These values are copied from Marmot timeline rows and treated as authoritative:

- `TimelineStore.messageById`: loaded-window `AppMessageRecordFfi` mirror.
- `TimelineStore.messageStatusById`: display status derived from row direction for mirrored rows; transient send state is listed under overlays.
- `TimelineStore.replyProjectionKnownMessageIds` + `replyTargetByMessageId`: Rust `replyToMessageIdHex`; known-empty means no reply and must not be recovered from tags.
- `TimelineStore.replyPreviewsByMessageId`: Rust `replyPreview` mirror.
- `ConversationMediaProjectionCache.referencesByMessageId`: Rust row `media` mirror. A present empty array is authoritative and suppresses tag fallback.
- `ConversationReactionProjectionCache.summariesByTarget`: Rust row reaction summaries.
- `ConversationDeletedMessageProjection.projected`: Rust row deletion state.
- Pagination flags: `hasMoreBefore`, `hasMoreAfter`, `isLoading` around Marmot timeline pages.

## UI optimistic overlays

These are allowed because Marmot cannot emit them before the local UI action completes:

- Pending/failed outgoing text/media rows in `TimelineStore.transientTimelineItems`.
- Pending media thumbnails/bytes in `ConversationMediaProjectionCache.pendingByRowId`.
- Optimistic reaction add/remove placeholders in `ConversationReactionProjectionCache`.
- Optimistic tombstones in `ConversationDeletedMessageProjection.optimistic`.
- Session-only system events and stream/debug preview rows.

Overlays must be minimal diffs over the mirrored row. They are cleared or pruned when Marmot confirms the corresponding projection.

## Compatibility fallbacks kept

- Media tag classification is allowed only when `referencesByMessageId` has no entry for the message id. That covers local optimistic/upload records before the timeline row is mirrored. Once a row projection has been captured, even an empty one, iOS must not re-derive media from `imeta` tags.
- Reply target tag parsing is allowed only for transient/local records with no mirrored reply projection. A mirrored nil target is authoritative.
- Reply preview text may fall back to an already-loaded target row when Rust supplied the target id but not a preview. That preserves old-window behavior; full preview hydration still belongs in Marmot.

## UI derivations kept

These are presentation work, not protocol/storage truth:

- Loaded-window sort/reply ordering (`ConversationViewModel.normalizedTimeline`).
- Markdown display blocks built from Rust `contentTokens`; no display-time `parseMarkdown` call.
- `MessageMediaAttachment` display models built from mirrored media references.
- Reaction tally folding of Rust summaries plus local optimistic add/remove overlays.
- Deleted-message set union of Rust tombstones plus local optimistic tombstones.

## Source guards

`TimelineProjectionBoundaryTests` pins the important no-regression rules:

- No conversation timeline `listMedia` call or source-epoch recovery path.
- No display-time markdown parse in the timeline/bubble/cache path.
- Empty Rust media projections beat Swift `imeta` fallback.
- Mirrored nil reply targets beat Swift tag fallback.
