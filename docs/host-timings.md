# Host timings (draft)

Depends on iOS #951 and [MDK #1760](https://github.com/marmot-protocol/mdk/pull/1760).
The draft calls the unreleased `recordHostTiming` API directly. The inherited
MarmotKit pin does not expose it yet: compilation and simulator validation remain
blocked until matching bindings and binaries are installed. Do not hand-edit the
generated bindings. Install a published snapshot containing #1760 before merge.

All stages are registered aggregate product events. MDK receives unsigned
milliseconds from `ContinuousClock`, buckets them, and exports only `elapsed`
and `outcome` through the consent-gated Aptabase pipeline. Custom stages do not
add OTLP series or app-performance snapshot fields. No IDs, content, filenames,
URLs, counts, or error strings are attached.

| Event | Measured boundary |
| --- | --- |
| `app_timeline_window` | Apply a timeline window/page, including projections and ordering. |
| `app_timeline_tail` | Apply a tail refresh to the loaded window. |
| `app_timeline_delta` | Apply an accepted group delta batch. |
| `app_timeline_rebuild` | Rebuild and assign the merged timeline, including markdown/media caches. |
| `app_timeline_profiles` | Refresh profile-dependent reply, system-text, and mention projections. |
| `app_outgoing_projection` | Insert the optimistic outgoing row into the timeline. |
| `app_outgoing_confirmation` | Reconcile an outgoing row with the send response. |
| `app_markdown_rebuild` | Rebuild/check markdown cache entries during a full timeline rebuild. |
| `app_media_rebuild` | Rebuild/check media cache entries during a full timeline rebuild. |
| `app_inbox_snapshot` | Apply the inbox snapshot, including cache enrichment scheduling. |
| `app_inbox_batch` | Apply a nonempty coalesced inbox batch; excludes the coalescing wait. |
| `app_inbox_refresh` | Refresh display projections for the nonempty inbox. |
| `app_inbox_publish` | Sort, compare, and publish visible/archived inbox arrays. |
| `app_composer_markdown` | Await optimistic composer markdown parsing, including actor scheduling. |
| `app_camera_prepare` | Queue camera image/video preparation through draft insertion. |
| `app_library_prepare` | Queue one selected photo-library batch through prepared-draft insertion. |

Synchronous projection stages report completion as success, including unchanged
results/cache hits. Camera/library preparation reports failure on errors or
cancellation; a partially prepared library batch also reports failure. These
measurements include their stated preparation paths, not picker dwell time.

Consent tickets are captured at stage entry. Work begun before consent, or
completed after consent/profile/runtime invalidation, is discarded. Elapsed time
is captured before entering the bounded recorder queue. A rejected recorder sink
is disabled and its queued tickets invalidated; normal activation can retry it.
Registering these stages changes MDK's registry revision and requires renewed
consent under the existing #951 flow.

Compare bucket distributions by event, outcome, app version, OS major version,
and device class. Parent timings include child timings; do not sum them or their
percentiles. Full cache passes differ from individual cache misses. No per-row
timings are emitted from bubble bodies. Capacity limits can drop observations.

These stages do not establish a rendered frame, relay acceptance, or recipient
delivery. In particular, outgoing projection/confirmation must not be relabeled
as `host_outbound_message_visible`. MDK #1760's built-in send/ingest phases become
available after the binding update; its visible-message milestones require
separate frame-boundary instrumentation.

## Verification after the binding update

Run `ProductAnalyticsTests`, including the real Rust registry/consent test, then
the conversation timeline, composer, and chat-list suites. Exercise camera and
library preparation (success, partial failure, cancellation), and revoke consent
during preparation. Verify exported staging events contain only registered
bucket/outcome properties and stop after revocation. Existing #951 endpoint,
key, retention, lifecycle, and release gates still apply.
