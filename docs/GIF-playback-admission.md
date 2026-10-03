# Remote GIF playback admission

Downloaded GIPHY bytes pass `GIFPlaybackAdmission` before ImageIO inspection or
UIKit playback. URL extensions, advertised rendition dimensions, display size
and encoded byte count are not decoded-resource limits.

The initial policy permits at most 5 MiB encoded bytes, a positive logical
canvas of at most 4096 pixels on either edge and 4 Mi pixels in area, and
2–1000 image frames whose
rectangles fit inside that canvas. Logical canvas area multiplied by frame
count must not exceed 32 Mi pixels; division checks the limit without overflow.
Partial frames still count as a full compositing canvas. The parser walks
bounded color tables and sub-blocks without decompressing pixels, requires a
complete container and trailer, and rejects plaintext/unknown rendering
extensions rather than assigning them an implicit resource budget.

Only admitted bytes reach ImageIO, with inspection caching disabled. ImageIO
must recognize a complete GIF with the same frame count. Playback uses the
logical canvas aspect ratio, not the first partial frame's rectangle. Direct
loading, legacy MP4-to-GIF lookup and retry use the same preparation boundary.
Existing secure transport, encoded limits, visibility/pause behavior, account
identity and playback reservations remain unchanged. This guard concerns
remote GIPHY playback, not attachment playback or still-image search previews.

## Compatibility qualification

Header-only inspection of ordinary vendor renditions on 2026-10-03 produced:

| Rendition | Bytes | Canvas | Frames | Canvas area × frames |
|---|---:|---|---:|---:|
| `JIX9t2j0ZTN9S/giphy.gif` | 1776311 | 480 × 480 | 24 | 5529600 |
| `3o7TKMt1VVNkHV2PaE/200.gif` | 239337 | 200 × 200 | 96 | 3840000 |
| `3o7TKMt1VVNkHV2PaE/giphy.gif` | 639904 | 500 × 500 | 96 | 24000000 |

These small/larger and short/long renditions fit the existing preferred 2 MiB
download budget and the initial resource policy. URLs start with
`https://media.giphy.com/media/`. Their SHA-256 values, in table order, are:

```text
5d53be905f5e3e8c0406a13f4fea74850966e6d356f42caed827b2f015e1e82c
7a126599836d07bd9b556a0e57294ec067065f87050e19909dc45e7b49231d70
943d75e2157f2c610c6d3fc49a404b9d09990df8fe13b0e55095745bb55228cf
```

This sample is not the entire catalog, and header inspection is not native
playback verification. High-resolution or long animations may deliberately
show the existing failed state. Qualify changes against ordinary renditions
and tiny boundary fixtures; never raise a limit just to admit untrusted media.

Native Swift tests cover the admission boundaries without allocating oversized
rasters, logical-canvas geometry and refusal during direct and legacy lookup.
These ceilings do not prove a total UIKit memory ceiling or prevent every
native codec defect. Keep OS codec security updates current.

The separate 4 Mi canvas-area ceiling limits one RGBA frame to 16 MiB of
declared pixels, independently of the total-frame work counter. It is stricter
than the initial Mac policy because the mobile player shares a six-playback
reservation budget. Native decoder buffers and other app allocations still
require runtime qualification; multiplying this number by six is not a
total-process memory bound.
