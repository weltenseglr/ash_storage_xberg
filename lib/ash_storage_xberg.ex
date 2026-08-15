defmodule AshStorageXberg do
  @moduledoc """
  AshStorage analyzers and variants backed by the
  [xberg](https://github.com/xberg-io/xberg) document intelligence engine.

  The library supports both a REST sidecar (`ghcr.io/xberg-io/xberg`) and the
  in-process NIF through the same facade. The REST sidecar is the option used in
  this repository's development setup, but the NIF backend remains available and
  is interchangeable via configuration.

  ## Architecture

  The xberg engine runs out-of-process as a sidecar container and is reached
  over HTTP. The client interface, `AshStorageXberg.Xberg`, mirrors the `Xberg`
  NIF module from the `:xberg` hex package, so the REST sidecar
  (`AshStorageXberg.XbergApi`, the default) and the in-process NIF are
  exchangeable via configuration:

      config :ash_storage_xberg, xberg: AshStorageXberg.XbergApi  # REST sidecar (default)
      config :ash_storage_xberg, xberg: Xberg                     # NIF ({:xberg, "~> 1.0"})

  The sidecar's base URL comes from `config :ash_storage_xberg, :base_url`, then
  from the `XBERG_URL` environment variable, then from
  `"http://localhost:8000"`.

  ## Quick start

      # local file — streamed to the sidecar as multipart
      AshStorageXberg.Xberg.extract(
        input: %{uri: "/tmp/uploads/report.pdf"},
        config: %{output_format: "markdown"}
      )

      # presigned bucket URL — the sidecar downloads directly from storage,
      # bytes never flow through the application
      AshStorageXberg.Xberg.extract(input: %{uri: presigned_s3_url})

  ## Usage in a resource

  Analyzers and variants are declared inside `has_one_attached` /
  `has_many_attached` blocks of ash_storage's `storage` section. `analyzer`
  takes one positional argument (a module or a `{module, opts}` tuple) plus
  `analyze:`/`write_attributes:`; `variant` takes a name and a module or
  `{module, opts}` tuple plus `generate:`.

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
            # a cheap MIME sniff — no extraction, fine to run on every upload
            analyzer AshStorageXberg.Analyzers.ContentType

            # bibliographic metadata from the document header
            analyzer AshStorageXberg.Analyzers.Document

            # full text extraction is the expensive one — push it to the background;
            # write_attributes copies the "text" result onto the parent record
            analyzer {AshStorageXberg.Analyzers.Text, output: :markdown, max_bytes: 65_536},
              analyze: :oban,
              write_attributes: [text: :extracted_text]

            # generated when `:files_thumbnail_urls` is first loaded
            variant :thumbnail, {AshStorageXberg.Variants.PageThumbnail, format: :webp}

            # the full text as a stored .md file, for documents too big for metadata
            variant :fulltext, AshStorageXberg.Variants.ExtractedText, generate: :oban
          end

          has_one_attached :cover do
            analyzer AshStorageXberg.Analyzers.Image

            variant :preview,
                    {AshStorageXberg.Variants.PageThumbnail, format: :png, max_dimension: 512}
          end

          has_one_attached :recording do
            analyzer AshStorageXberg.Analyzers.Audio

            variant :transcript, {AshStorageXberg.Variants.Transcript, model: :base},
              generate: :oban
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

  Analyzer results land in the blob's `metadata` map (`blob.analyzers` tracks
  per-analyzer status); each variant adds a URL calculation, here
  `:files_thumbnail_urls`, `:files_fulltext_urls`, `:cover_preview_url` and
  `:recording_transcript_url`.

  Using `analyze: :oban` or `generate: :oban` requires AshOban triggers named
  `:run_pending_analyzers` / `:run_pending_variants` on the blob resource;
  ash_storage's compile-time verifiers spell out what to add.

  Analyzer results are string-keyed on purpose: ash_storage resolves
  `write_attributes` with `Map.fetch(result, to_string(key))`, and string keys
  are also what `blob.metadata` contains after a database round-trip.

  ## Modules

  ### Analyzers (metadata merged into `blob.metadata`)

    * `AshStorageXberg.Analyzers.ContentType` — MIME sniffing via `POST /detect`
    * `AshStorageXberg.Analyzers.Document` — title, authors, page count, language, creation date
    * `AshStorageXberg.Analyzers.Image` — dimensions, format, EXIF
    * `AshStorageXberg.Analyzers.Audio` — duration, codec, sample rate, channels, bitrate
    * `AshStorageXberg.Analyzers.Text` — extracted text, language, word count, OCR flag

  ### Variants (derived files)

    * `AshStorageXberg.Variants.PageThumbnail` — a rasterized document page
    * `AshStorageXberg.Variants.ExtractedText` — full text as `.md`/`.txt`/`.json`
    * `AshStorageXberg.Variants.Transcript` — Whisper transcript of audio/video

  ### Client

    * `AshStorageXberg.Xberg` — the exchangeable backend behaviour and its delegating API
    * `AshStorageXberg.XbergApi` — the REST implementation, plus `detect/1`, `health/0`,
      `version/0` and `cache_warm/1`
    * `AshStorageXberg.Formats` — the cached `GET /formats` list behind `accept?/1`

  See the [README](readme.html) for installation and usage, and
  [The xberg sidecar](sidecar.html) for image variants, the runtime format
  allowlist, the presigned-URL flow, and the limitations of the current
  sidecar images.
  """
end
