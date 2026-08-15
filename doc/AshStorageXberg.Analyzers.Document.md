# `AshStorageXberg.Analyzers.Document`
[🔗](https://github.com/weltenseglr/ash_storage_xberg/blob/main/lib/ash_storage_xberg/analyzers/document.ex#L1)

Bibliographic metadata of documents: PDF, Office (OOXML and legacy), ODF, RTF,
and EPUB.

    analyzer AshStorageXberg.Analyzers.Document

Result (string-keyed; nil values are omitted):

    %{
      "title" => "Fixture Title",
      "authors" => ["Fixture Author"],
      "page_count" => 1,
      "language" => "eng",
      "created_at" => "2026-08-11T10:00:00Z"
    }

OCR is disabled (`disable_ocr: true`) — metadata comes from the document
header, not from pixels. Language detection is enabled so `"language"` can be
filled in from the body text for documents that carry no language property;
it needs a reasonable amount of text and stays absent for very short ones.

`"created_at"` is the ISO 8601 string reported by xberg, ready for an
`:utc_datetime` attribute via `write_attributes: [created_at: :document_date]`
(ash_storage looks result keys up as strings).

---

*Consult [api-reference.md](api-reference.md) for complete listing*
