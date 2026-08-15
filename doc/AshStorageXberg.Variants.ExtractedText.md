# `AshStorageXberg.Variants.ExtractedText`
[🔗](https://github.com/weltenseglr/ash_storage_xberg/blob/main/lib/ash_storage_xberg/variants/extracted_text.ex#L1)

`AshStorage.Variant` that stores the full extracted text of a document as a
sidecar file — the right home for text too large for the blob metadata map
(see `AshStorageXberg.Analyzers.Text` and its `:max_bytes` cap).

    variant :fulltext, AshStorageXberg.Variants.ExtractedText, generate: :oban

## Options

  * `:format` — `:markdown` (default), `:plain` or `:json`. `:markdown` and
    `:plain` map to the sidecar's `output_format` and write the extracted
    content verbatim; `:json` writes a JSON document with `content`,
    `metadata` and `tables` (content rendered as markdown).
  * `:ocr` — run OCR on scanned pages (default `false`, sent as
    `disable_ocr: true`)
  * `:timeout` — extraction timeout in **seconds** (sent as
    `extraction_timeout_secs`)

Returns `{:ok, %{content_type: ..., word_count: ..., ocr_used: ...}}`, plus
`:language` when the sidecar reported one.

`accept?/1` is backed by `AshStorageXberg.Formats.supported?/1`, i.e. the
sidecar's `GET /formats` list (~100 formats), so this variant accepts
anything xberg can extract.

---

*Consult [api-reference.md](api-reference.md) for complete listing*
