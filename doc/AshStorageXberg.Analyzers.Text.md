# `AshStorageXberg.Analyzers.Text`
[🔗](https://github.com/weltenseglr/ash_storage_xberg/blob/main/lib/ash_storage_xberg/analyzers/text.ex#L1)

Extracted text of any format the sidecar supports — the headline feature:
PDF, Office/ODF, HTML, email, archives, notebooks, source code, and (with
`ocr: true`) images.

    analyzer {AshStorageXberg.Analyzers.Text, output: :markdown, max_bytes: 65_536},
      analyze: :oban,
      write_attributes: [text: :extracted_text]

Result (string-keyed; nil values are omitted):

    %{
      "text" => "Hello from AshStorage Xberg",
      "language" => "eng",
      "word_count" => 4,
      "ocr_used" => false,
      "text_truncated" => true    # only when `:max_bytes` clipped the text
    }

String keys are what makes the `write_attributes: [text: :extracted_text]`
above work: ash_storage resolves each result key with
`Map.fetch(result, to_string(key))`, and metadata read back from the database
is string-keyed too.

## Options

  * `:output` — `:plain` (default) or `:markdown`; maps to xberg's
    `output_format`.
  * `:max_bytes` — cap for the stored text, default `65_536`. Blob metadata is
    a database map column, so full text of large documents belongs in the
    `AshStorageXberg.Variants.ExtractedText` variant (or in a
    `write_attributes` target column). Truncation happens on a UTF-8
    character boundary and sets `"text_truncated" => true`; `"word_count"`
    always counts the *full* text.
  * `:ocr` — run OCR on images and scanned pages, default `false`
    (`disable_ocr: true`). OCR is slow and model-backed; enable it
    deliberately, ideally with `analyze: :oban`.
  * `:timeout` — extraction timeout in seconds (xberg's
    `extraction_timeout_secs`); unset means the sidecar's own default.

Language detection is always requested, so `"language"` carries the first
detected ISO 639 code (falling back to the document's own language property).
Very short documents are not detectable and simply have no `"language"`.

---

*Consult [api-reference.md](api-reference.md) for complete listing*
