# AshStorageXberg

[AshStorage](https://github.com/ash-project/ash_storage) analyzers and variants backed by
[xberg](https://github.com/xberg-io/xberg), a document-intelligence engine that can run either
as a REST sidecar container (`ghcr.io/xberg-io/xberg`) or as the in-process NIF. The REST
sidecar is the option used in this repository's development setup, but the NIF backend remains
available and is interchangeable through the same client interface.

Attach a file to an Ash resource and get, without adding a single native dependency to your app:

- **Text extraction from ~100 formats** — PDF, Office (OOXML and legacy), ODF, HTML, email,
  archives, LaTeX, notebooks, source code, and images via OCR
- **Document metadata** — title, authors, page count, creation date, detected language
- **Image metadata** — dimensions, format, EXIF
- **MIME sniffing** — the real content type of an upload, independent of what the client claimed
- **Page thumbnails** — first-page (or n-th page) rasters of PDFs, written as a stored variant
- **Full-text sidecar files** and (on media-enabled sidecar builds) **Whisper transcripts**

## Architecture

The heavy lifting — Rust parsers, Tesseract OCR, ONNX models — lives in its own container. The
BEAM application stays pure Elixir and talks to it over HTTP:

```
┌──────────────────────┐        multipart / JSON        ┌──────────────────────┐
│  your Ash app        │  ───────────────────────────▶  │  xberg sidecar       │
│  ash_storage         │                                │  ghcr.io/xberg-io/…  │
│  ash_storage_xberg   │  ◀───────────────────────────  │  `xberg serve`       │
└──────────────────────┘        ExtractionResult        └──────────────────────┘
          │                                                        ▲
          │  presigned URL                                         │
          ▼                                                        │
┌──────────────────────┐   the sidecar downloads the blob itself   │
│  S3 / Azure / disk   │ ──────────────────────────────────────────┘
└──────────────────────┘
```

The sidecar can be scaled, resource-limited, and upgraded independently of the app, and the same
two-container shape works in dev (devcontainer compose), CI (GitHub Actions `services:`), and
production (compose service or Kubernetes sidecar).

### Exchangeable backends

`AshStorageXberg.Xberg` is a behaviour that **mirrors the public API of the `Xberg` module from the
`:xberg` hex package** (the Rustler NIF binding) — same function names, same argument shapes, same
`{:ok, map}` / `{:error, kind, message}` returns. The REST client
(`AshStorageXberg.XbergApi`) is the default implementation; the in-process NIF can be swapped in
without touching any call site:

```elixir
# REST sidecar (default) — no native dependencies
config :ash_storage_xberg, xberg: AshStorageXberg.XbergApi

# in-process NIF — add {:xberg, "~> 1.0"} to your deps
config :ash_storage_xberg, xberg: Xberg
```

Every analyzer and variant in this library goes through that facade, so both backends are supported
by the same code.

## Installation

`ash_storage` is not published on hex.pm yet, so it must be a git dependency:

```elixir
def deps do
  [
    {:ash_storage, github: "ash-project/ash_storage"},
    {:ash_storage_xberg, github: "weltenseglr/ash_storage_xberg"}
  ]
end
```

### The sidecar

Run `ghcr.io/xberg-io/xberg` next to your app. Its default command is already
`serve -H 0.0.0.0 -p 8000`, so no command override is needed:

```yaml
# docker-compose.yml
services:
  app:
    image: hexpm/elixir:1.18.4-erlang-27.3.4-debian-trixie-20250630-slim
    environment:
      XBERG_URL: http://xberg:8000
    depends_on:
      xberg:
        condition: service_healthy

  xberg:
    image: ghcr.io/xberg-io/xberg:latest
    environment:
      XBERG_MAX_MULTIPART_FIELD_BYTES: "209715200"
      XBERG_MAX_REQUEST_BODY_BYTES: "209715200"
    volumes:
      # OCR/Whisper models and the extraction cache survive rebuilds
      - xberg-cache:/app/.xberg
    ports:
      - "8000:8000"
    healthcheck:
      test: ["CMD", "xberg", "--version"]
      interval: 5s
      timeout: 5s
      retries: 12

volumes:
  xberg-cache:
```

`.devcontainer/docker-compose.yml` in this repository — the development environment for the
library itself — is the same setup with one deliberate difference: it runs
`ghcr.io/weltenseglr/xberg:omni`, an "omni" build that bundles the optional media
(audio/video) and office-rasterization support the stock `ghcr.io/xberg-io/xberg:latest`
image leaves out. Use that image too if you need `AshStorageXberg.Analyzers.Audio`,
`AshStorageXberg.Variants.Transcript`, or Office/ODF thumbnails.

### Configuration

```elixir
config :ash_storage_xberg,
  base_url: "http://localhost:8000",  # defaults to $XBERG_URL, then http://localhost:8000
  receive_timeout: 120_000,
  req_options: []                     # merged into every Req request
```

`XBERG_URL` is the usual knob: `http://xberg:8000` in compose, `http://localhost:8000` when the
sidecar's port is published locally.

Pin an image tag (e.g. `ghcr.io/xberg-io/xberg:1.0.14`) rather than tracking `:latest` if API
drift ever bites;
`AshStorageXberg.XbergApi.version/0` reports what the sidecar is running, and
`AshStorageXberg.XbergApi.health/0` is a ready-made health probe. `AshStorageXberg.XbergApi.cache_warm/1`
pre-downloads OCR/Whisper models at deploy time so the first upload does not pay for it.

### The format allowlist is the sidecar's, not ours

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

## Usage

Analyzers and variants are declared inside `has_one_attached` / `has_many_attached` blocks of
ash_storage's `storage` section:

```elixir
defmodule MyApp.Document do
  use Ash.Resource,
    domain: MyApp.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStorage]

  postgres do
    table "documents"
    repo MyApp.Repo
  end

  storage do
    service {AshStorage.Service.Disk, root: "priv/storage", base_url: "/storage"}

    blob_resource MyApp.StorageBlob
    attachment_resource MyApp.StorageAttachment

    has_many_attached :files do
      # cheap: a MIME sniff, no extraction — fine to run eagerly on every upload
      analyzer AshStorageXberg.Analyzers.ContentType

      # bibliographic metadata from the document header
      analyzer AshStorageXberg.Analyzers.Document

      # full text extraction is the expensive one — push it to the background;
      # write_attributes copies the "text" result onto the parent record
      analyzer {AshStorageXberg.Analyzers.Text, output: :markdown, max_bytes: 65_536},
        analyze: :oban,
        write_attributes: [text: :extracted_text]

      # a first-page thumbnail, generated when its URL calculation is first loaded
      variant :thumbnail, {AshStorageXberg.Variants.PageThumbnail, format: :webp}

      # the full text as a stored .md file, for documents too big for blob metadata
      variant :fulltext, AshStorageXberg.Variants.ExtractedText, generate: :oban
    end

    has_one_attached :cover do
      analyzer AshStorageXberg.Analyzers.Image
      variant :preview, {AshStorageXberg.Variants.PageThumbnail, format: :png, max_dimension: 512}
    end

    has_one_attached :recording do
      analyzer AshStorageXberg.Analyzers.Audio
      variant :transcript, {AshStorageXberg.Variants.Transcript, model: :base}, generate: :oban
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :title, :string, public?: true
    attribute :extracted_text, :string
  end

  actions do
    defaults [:read, :destroy, create: [:title], update: [:title]]
  end
end
```

DSL notes, verified against ash_storage:

- `analyzer` takes **one** positional argument — a module or a `{module, opts}` tuple — plus the
  options `analyze: :eager | :oban` (default `:eager`) and `write_attributes:`. There is no
  `analyzer :name, Module` form.
- `variant` takes **two** positional arguments — the variant name and a module or `{module, opts}`
  tuple — plus `generate: :on_demand | :eager | :oban` (default `:on_demand`).
- The `opts` in the tuple are what reach `analyze/2` and `transform/3`; the trailing keyword
  options are consumed by ash_storage itself.
- Each variant adds a URL calculation: `:files_thumbnail_urls` (has_many) or
  `:cover_preview_url` (has_one).
- `analyze: :oban` / `generate: :oban` require AshOban triggers named `:run_pending_analyzers` /
  `:run_pending_variants` on your blob resource — ash_storage has compile-time verifiers that tell
  you exactly what to add.

Reading the results:

```elixir
document = Ash.load!(document, files: [blob: :variants])

hd(document.files).blob.metadata
#=> %{
#     "detected_content_type" => "application/pdf",
#     "title" => "Q3 Report", "authors" => ["Jane Doe"], "page_count" => 12,
#     "language" => "eng", "text" => "…", "word_count" => 4213, "ocr_used" => false
#   }
```

Analyzer results are string-keyed on purpose: ash_storage resolves `write_attributes` with
`Map.fetch(result, to_string(key))`, so `write_attributes: [text: :extracted_text]` copies the
`"text"` result onto the parent record's `:extracted_text` attribute — and string keys are also
what `blob.metadata` contains after a database round-trip.

## Analyzers

All implement `AshStorage.Analyzer`. Results are merged into the blob's `metadata` map; `nil`
values are always dropped rather than stored.

| Module | `accept?/1` | Returns | Options |
|---|---|---|---|
| `AshStorageXberg.Analyzers.ContentType` | everything | `:detected_content_type`, plus `:content_type_verified` when a claimed type is supplied | `:content_type` — the client-claimed type to compare against |
| `AshStorageXberg.Analyzers.Document` | PDF, OOXML, legacy Office, ODF, RTF, EPUB (intersected with the sidecar's format list) | `:title`, `:authors`, `:page_count`, `:language`, `:created_at` | — |
| `AshStorageXberg.Analyzers.Image` | `image/*` | `:width`, `:height`, `:format`, `:exif` | — |
| `AshStorageXberg.Analyzers.Audio` | `audio/*`, `video/*` | `:duration_ms`, `:codec`, `:container`, `:sample_rate_hz`, `:channels`, `:bitrate` | — (needs a media-enabled sidecar, see below) |
| `AshStorageXberg.Analyzers.Text` | everything in `GET /formats` | `:text`, `:language`, `:word_count`, `:ocr_used`, `:text_truncated` | `:output` (`:plain` \| `:markdown`), `:max_bytes` (default `65_536`), `:ocr` (default `false`), `:timeout` (seconds) |

`ContentType` is a cheap header sniff on the REST sidecar (`POST /detect`). The NIF backend has no
such endpoint, so it falls back to a metadata-only extraction there — prefer `analyze: :oban` on a
NIF-only deployment.

`Analyzers.Text` caps the stored text at `:max_bytes` on a UTF-8 character boundary and flags
`text_truncated: true` — blob metadata is a database map column, so the full text of a large
document belongs in the `ExtractedText` variant instead. `:word_count` always counts the *full*
text, not the truncated copy.

`Analyzers.ContentType` can only *report* the sniffed type; analyzers cannot rewrite
`blob.content_type` itself. Also note xberg reports canonical types (`audio/x-wav` for a RIFF WAVE
file), so treat `content_type_verified: false` as "worth a look", not as proof of an attack.

## Variants

All implement `AshStorage.Variant`; `transform/3` writes the derived file and returns its metadata.

| Module | `accept?/1` | Produces | Options |
|---|---|---|---|
| `AshStorageXberg.Variants.PageThumbnail` | `image/*`, plus PDF/Office/ODF/EPUB intersected with the sidecar's format list | a rasterized page image; `%{content_type:, width:, height:, page:}` | `:page` (default `1`), `:format` (`:png` default, `:webp`, `:jpeg`, `:heif`, `:native`), `:dpi` (default `72`), `:max_dimension` |
| `AshStorageXberg.Variants.ExtractedText` | everything in `GET /formats` | `.md` / `.txt` / `.json` sidecar file; `%{content_type:, word_count:, language:, ocr_used:}` | `:format` (`:markdown` default, `:plain`, `:json`), `:ocr` (default `false`), `:timeout` (seconds) |
| `AshStorageXberg.Variants.Transcript` | `audio/*`, `video/*` | Whisper transcript as `.txt` or, with timestamps, `.json`; `%{content_type:, model:, language:}` | `:model` (`:tiny` default, `:base`, `:small`, `:medium`, `:large`), `:language`, `:timestamps` (default `false`), `:max_duration_ms`, `:timeout` |

`ExtractedText` and `Transcript` are both good candidates for `generate: :oban`; so is
`PageThumbnail` on large documents, since rasterization is not free (see limitations below).

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

## Documentation

The full module docs are generated with [ex_doc](https://hexdocs.pm/ex_doc/) and
include HTML, EPUB, and an LLM-friendly text snapshot:

```bash
mix docs
# → doc/index.html          (HTML — open in a browser)
# → doc/ash_storage_xberg.epub
# → doc/llms.txt             (concatenated plain-text docs for LLM context)
# → doc/<Module>.{html,md}   (one page per module)
```

The generated site uses the [README](readme.html) as its landing page and groups
public modules under *Analyzers*, *Variants*, and *Xberg client*. The
[Changelog](CHANGELOG.md) and [License](LICENSE) ship alongside it.

## Testing

```bash
# unit tests only — no sidecar required, HTTP is stubbed with Req.Test
mix test

# add the round-trips against a live sidecar
XBERG_URL=http://127.0.0.1:8000 mix test --include integration

# add the Whisper transcription tests (needs a media-enabled build and a model download)
XBERG_URL=http://127.0.0.1:8000 mix test --include transcript
```

`:integration` and `:transcript` are excluded by default in `test/test_helper.exs`. The unit suite
stubs `AshStorageXberg.XbergApi` through `config :ash_storage_xberg, :req_options, plug: {Req.Test, …}`,
so it never touches the network.

> **Use `127.0.0.1`, not `localhost`, with podman.** A rootless podman published port binds IPv4
> only, while `localhost` on most Linux hosts resolves to `::1` first — so `http://localhost:8000`
> fails with a connection refused while `http://127.0.0.1:8000` works.
> `.github/workflows/test.yml` sets `XBERG_URL: http://127.0.0.1:8000` for the same reason —
> the loopback IP works everywhere, so nothing depends on how a host resolves `localhost`.

Bring a sidecar up for local integration runs with:

```bash
podman run --rm -p 8000:8000 ghcr.io/xberg-io/xberg:latest
```

## License

MIT.
