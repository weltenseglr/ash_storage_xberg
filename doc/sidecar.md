# The xberg sidecar

Everything operational about the sidecar that goes beyond the README's quick start: choosing an
image, the runtime format allowlist, the presigned-URL flow, and the limitations of the current
images.

## Choosing an image

The stock `ghcr.io/xberg-io/xberg:latest` image covers text extraction, OCR, and document
metadata. `.devcontainer/docker-compose.yml` in this repository — the development environment for
the library itself — is the same setup with one deliberate difference: it runs
`ghcr.io/weltenseglr/xberg:omni`, an "omni" build that bundles the optional media (audio/video)
and office-rasterization support the stock image leaves out. Use that image too if you need
`AshStorageXberg.Analyzers.Audio`, `AshStorageXberg.Variants.Transcript`, or Office/ODF
thumbnails.

Pin an image tag (e.g. `ghcr.io/xberg-io/xberg:1.0.14`) rather than tracking `:latest` if API
drift ever bites; `AshStorageXberg.XbergApi.version/0` reports what the sidecar is running, and
`AshStorageXberg.XbergApi.health/0` is a ready-made health probe.
`AshStorageXberg.XbergApi.cache_warm/1` pre-downloads OCR/Whisper models at deploy time so the
first upload does not pay for it.

## The format allowlist is the sidecar's, not ours

Nothing hardcodes "what xberg can read". `AshStorageXberg.Formats` fetches `GET /formats` on the
first `accept?/1` call, caches it in `:persistent_term` for the life of the node, and logs what it
found:

```
[info]  AshStorageXberg: the xberg sidecar reports 120 extractable MIME types
[debug] AshStorageXberg: extractable MIME types: application/epub+zip, application/json, …
```

Set the Logger to `:debug` to see the full list — it is the quickest way to find out whether a
given build handles a format. If the sidecar is unreachable when the first lookup happens, a
conservative built-in list is used instead and the fallback is logged as a warning, so `accept?/1`
never raises during an attach flow. The fallback lands in `:persistent_term` exactly like a real
response, though — a sidecar that was merely down during the first lookup pins the conservative
list for the rest of the node's life. If you see that warning, call
`AshStorageXberg.Formats.reset/0` once the sidecar is back; the same call drops the cache after
pointing at a different sidecar.

`GET /formats` reports MIME type and extension only — there are no capability flags — so it can
answer "can this build extract it?" but not "can it rasterize / transcribe it?". Modules that need
a *subset* (documents, rasterizable pages) therefore keep a curated list and intersect it with the
runtime one; the prefix matchers (`image/*`, `audio/*`, `video/*` in `Analyzers.Image`,
`Analyzers.Audio` and `Variants.Transcript`) deliberately do not intersect, because the endpoint
under-reports aliases xberg itself emits, such as `audio/x-wav` for RIFF WAVE files.

## Presigned-URL flow

Every analyzed byte normally travels app → sidecar as multipart. For blobs living in object
storage there is a shortcut: `POST /extract` also accepts a JSON body
`{"inputs": [{"uri": …}], "config": {…}}`, and the sidecar fetches each URI itself.

`AshStorageXberg.XbergApi` routes inputs automatically:

| Input | Transport |
|---|---|
| `%{bytes: binary}` | multipart upload |
| `%{uri: "/local/path"}` (or `file://…`) | streamed from disk as multipart |
| `%{uri: "https://bucket…?X-Amz-Signature=…"}` | JSON body — **the sidecar downloads straight from the bucket; the bytes never enter the BEAM** |

```elixir
AshStorageXberg.Xberg.extract(input: %{uri: presigned_s3_url})
```

Two things to know before wiring presigned URLs into an analyzer:

- **Encryption caveat.** If blobs are encrypted at rest (by ash_storage or by your app), a presigned
  URL serves *ciphertext* that the sidecar cannot parse. Those attachments must fall back to
  streaming the decrypted bytes through the app as multipart.
- **SSRF policy.** The sidecar refuses to fetch private and link-local addresses by default, which
  is what you want — it stops the fetcher from being used as an SSRF pivot. Public bucket endpoints
  pass. For a MinIO-style private endpoint in development, override it per request with
  `config: %{url: %{crawl: %{ssrf: %{deny_private: false}}}}`.

A batch must be all-remote or all-local: `extract_batch/1` returns a validation error when the two
are mixed, because they use different transports.

## Current sidecar image limitations

Originally verified against `ghcr.io/xberg-io/xberg:latest` = **1.0.14** on 2026-08-11, and
re-checked on 2026-08-15 against `ghcr.io/weltenseglr/xberg:omni` (reports **1.1.0**), the image
this repo's devcontainer and CI actually run. Everything below still holds, except that the
`:omni` build *does* have media support — that is what makes the `:transcript` tests runnable:

- **No audio/media support in the shipped build.** `tone.wav` comes back as `unsupported_format`
  and the extraction config schema rejects a `transcription` section outright, even though wav,
  mp3, and mp4 appear in `GET /formats`. `Analyzers.Audio` and `Variants.Transcript` are
  implemented against the documented shapes and tolerate the naming differences between builds;
  they light up as soon as a media-enabled image is available. Until then they surface a normal
  `{:error, {:unsupported_format, _}}`, which is retryable under `analyze:`/`generate: :oban`.
- **Page rasters require forced OCR.** `images.include_page_rasters: true` on its own returns
  nothing; rasters are a by-product of the page-rendering pass that only runs under
  `force_ocr: true`. `Variants.PageThumbnail` therefore always sets `force_ocr: true` — which is
  why thumbnails cost a real OCR pass and why `generate: :oban` is the right default for big files.
- **DPI is advisory.** `target_dpi` and `max_image_dimension` are accepted but ignored; PDF pages
  render at the fixed OCR DPI of 150 (requesting 72 and 300 for the same A4 page both return
  1241×1754). Trust the `width`/`height` in the returned variant metadata
  rather than computing them from `:dpi`.
- **Office rasterization depends on the build.** `PageThumbnail.accept?/1` intersects its curated
  list of rasterizable document types with the sidecar's `GET /formats`, so formats the build
  cannot extract at all are rejected up front (on both 1.0.14 and 1.1.0 that is ODF Graphics,
  `.odg`; the entry stays in the curated list so a build that gains support needs no code change).
  What survives is still only rasterizable *in principle*: builds without an office renderer
  return no raster and `transform/3` fails with `{:error, {:no_page_raster, _}}`.

## Coverage of ash_storage's "Library options under consideration"

| Roadmap category (candidate libraries) | Covered? | How |
|---|---|---|
| Image metadata extraction (`ex_image_info`, `exexif`, `image`) | Yes | `Analyzers.Image` — dimensions, format, EXIF |
| File type detection / content sniffing (`gen_magic`, `ex_marcel`, `magic_number`) | Yes | `Analyzers.ContentType` — the sidecar's dedicated `POST /detect`, or a metadata-only extraction on the NIF |
| Video/audio metadata (`ffmpex`, `xav`) | Library yes, stock image no | `Analyzers.Audio` is implemented; the stock image has no media support, the `:omni` build does |
| Audio transcription | Library yes, image no | `Variants.Transcript` is implemented; requires a media-enabled xberg build |
| PDF thumbnails (`image`/`vix` + poppler, `thumbnex`) | Yes | `Variants.PageThumbnail` — no system dependencies in the app image |
| Video thumbnails (`ffmpex`, `thumbnex`) | No | xberg transcribes A/V but does not grab video frames — use `ffmpex` |
| Image processing / resize variants (`image`+`vix`, `mogrify`) | No | xberg extracts, it does not resize photos — use `image` |
| **Text extraction from ~100 formats** | Yes (bonus) | `Analyzers.Text` / `Variants.ExtractedText` — nothing on the candidate list offers this |

This library composes with `image` and `ffmpex` rather than replacing them: nothing stops you from
declaring an `image`-based resize variant next to an xberg-based thumbnail on the same attachment.
