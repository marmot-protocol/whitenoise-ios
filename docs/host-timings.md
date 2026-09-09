# Host timings

Uses the formal MarmotKit 0.9.20 release, which includes
[MDK #1760](https://github.com/marmot-protocol/mdk/pull/1760), and the merged
first-launch consent integration. No local or unreleased bindings are required.

All stages are registered aggregate product events. MDK receives unsigned
milliseconds from `ContinuousClock`, buckets them, and aggregates `elapsed`
and `outcome` through the consent-gated Aptabase pipeline, adding its bounded
`count_bucket` and standard product metadata. Custom stages do not
add OTLP series or app-performance snapshot fields. No IDs, content, filenames,
URLs, exact counts, or error strings are supplied by these host observations.

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
| `app_inbox_snapshot` | Apply the complete presented inbox snapshot, including selected title/avatar mapping and cache enrichment scheduling. |
| `app_inbox_batch` | Apply a nonempty coalesced inbox batch; excludes the coalescing wait. |
| `app_inbox_refresh` | Refresh display projections for the nonempty inbox. |
| `app_inbox_publish` | Sort, compare, and publish visible/archived inbox arrays. |
| `app_composer_markdown` | Await optimistic composer markdown parsing for new sends and message edits, including actor scheduling. |
| `app_camera_prepare` | Queue camera image/video preparation through draft insertion. |
| `app_library_prepare` | Queue one selected photo-library batch through prepared-draft insertion. |

Synchronous projection stages report completion as success, including unchanged
results/cache hits. Camera/library preparation reports failure on errors or
cancellation; a partially prepared or partially inserted library batch also
reports failure. Empty library selections create no preparation observation. These
measurements include their stated preparation paths, not picker dwell time.

Consent tickets are captured at stage entry. Work begun before consent, or
completed after consent/profile/runtime invalidation, is discarded. Elapsed time
is captured before entering the bounded recorder queue. Timing calls use a
dedicated sink with raw milliseconds; MDK owns their bucketing. A rejected timing
sink disables recording and invalidates queued tickets; normal activation can
retry it. Existing product-event errors remain isolated to the individual event.
Registering these stages changes MDK's registry revision and requires renewed
consent under the existing #951 flow. Until accepted, all usage reporting is
disabled, including previously registered events. The stage set is installed
together to avoid repeated prompts while establishing a baseline.

Compare bucket distributions by event, outcome, app version, OS major version,
and device class. Parent timings include child timings; do not sum them or their
percentiles. Full cache passes differ from individual cache misses. No per-row
timings are emitted from bubble bodies. Capacity limits can drop observations.

The stages distinguish total update cost from markdown, media, and inbox
publication work across deployed device classes. Small operations may remain in
the lowest bucket; use the existing local signposts when finer resolution is
needed. Nested stages increase recorder work and can increase admission drops
during bursts. There is no host overflow signal, so these are best-effort
distributions of admitted observations, not an unbiased census or a latency SLO.
Confirm suspected tail regressions with local traces before drawing conclusions.
MainActor ticket reads share the recorder mutex with native recording. This
relies on the pinned MDK recorder remaining memory-only and short; investigate
contention in local traces if instrumentation itself affects frame time.

These stages do not establish a rendered frame, relay acceptance, or recipient
delivery. In particular, outgoing projection/confirmation must not be relabeled
as `host_outbound_message_visible`. MDK's built-in send/ingest phases remain
automatic. The separate visible-message instrumentation already measures first visible layout and discards samples older
than five seconds; these preparation stages do not replace those measurements.

## Verification

Run `ProductAnalyticsTests`, including the real Rust registry/consent test, then
the conversation timeline, composer, and chat-list suites. Exercise camera and
library preparation (success, partial failure, cancellation), and revoke consent
during preparation. Verify exported staging events contain only registered
bucket/outcome properties plus MDK metadata, and stop after revocation. Existing #951 endpoint,
key, retention, lifecycle, and release gates still apply.
