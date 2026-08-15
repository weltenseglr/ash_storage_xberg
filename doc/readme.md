# AshStorageXberg

[AshStorage](https://github.com/ash-project/ash_storage) analyzers and variants backed by
[xberg](https://github.com/xberg-io/xberg), a document-intelligence engine that runs as a REST
sidecar container (or, interchangeably, as the in-process NIF).

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

The sidecar runs isolated and can be scaled, resource-limited, and upgraded independently of the app; the same
two-container shape works in dev, CI, and production. `AshStorageXberg.Xberg` mirrors the API of
the `Xberg` NIF module from the `:xberg` hex package, so the REST client (the default) and the
in-process NIF are exchangeable without touching any call site:

```elixir
# REST sidecar (default) — no native dependencies
config :ash_storage_xberg, xberg: AshStorageXberg.XbergApi

# in-process NIF — add {:xberg, "~> 1.0"} to your deps
config :ash_storage_xberg, xberg: Xberg
```

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

Run `ghcr.io/xberg-io/xberg` next to your app (its default command is already
`serve -H 0.0.0.0 -p 8000`):

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

```elixir
config :ash_storage_xberg,
  base_url: "http://localhost:8000",  # defaults to $XBERG_URL, then http://localhost:8000
  receive_timeout: 120_000,
  req_options: []                     # merged into every Req request
```

`XBERG_URL` is the usual knob: `http://xberg:8000` in compose, `http://localhost:8000` when the
sidecar's port is published locally. The stock image has no audio/media or office-rasterization
support — the [sidecar guide](guides/sidecar.md) covers image variants, model warming, and the
limitations of current builds.

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
`Map.fetch(result, to_string(key))`, and string keys are also what `blob.metadata` contains after
a database round-trip.

## Analyzers and variants

Accepted content types, returned keys, and options are documented per module — the moduledocs are
the reference:

- `AshStorageXberg.Analyzers.ContentType` — MIME sniffing via the sidecar's `POST /detect`
- `AshStorageXberg.Analyzers.Document` — title, authors, page count, language, creation date
- `AshStorageXberg.Analyzers.Image` — dimensions, format, EXIF
- `AshStorageXberg.Analyzers.Audio` — duration, codec, sample rate, channels, bitrate
- `AshStorageXberg.Analyzers.Text` — extracted text, language, word count, OCR flag
- `AshStorageXberg.Variants.PageThumbnail` — a rasterized document page
- `AshStorageXberg.Variants.ExtractedText` — full text as a stored `.md`/`.txt`/`.json` file
- `AshStorageXberg.Variants.Transcript` — Whisper transcript of audio/video

## Going deeper

- **[The xberg sidecar](guides/sidecar.md)** — choosing an image, the runtime format allowlist,
  the presigned-URL flow (bytes never enter the BEAM), SSRF policy, and the limitations of
  current sidecar builds.
- **`mix docs`** builds the full documentation site (HTML, EPUB, and a `doc/llms.txt` snapshot
  for LLM context), with the README as landing page and modules grouped under *Analyzers*,
  *Variants*, and *Xberg client*.

## Testing

```bash
mix test                                                        # unit tests, HTTP stubbed
XBERG_URL=http://127.0.0.1:8000 mix test --include integration  # live sidecar round-trips
XBERG_URL=http://127.0.0.1:8000 mix test --include transcript   # Whisper (media build + model)
```

Bring a sidecar up with `podman run --rm -p 8000:8000 ghcr.io/xberg-io/xberg:latest`. Use
`127.0.0.1`, not `localhost`: a rootless podman published port binds IPv4 only, while `localhost`
often resolves to `::1` first. CI (`.github/workflows/test.yml`) runs the same tiers against a
sidecar service container.

## License

MIT.
