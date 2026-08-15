# `AshStorageXberg.Analyzers.Image`
[🔗](https://github.com/weltenseglr/ash_storage_xberg/blob/main/lib/ash_storage_xberg/analyzers/image.ex#L1)

Image dimensions, format, and EXIF tags.

    analyzer AshStorageXberg.Analyzers.Image

Result (string-keyed, like every analyzer in this library):

    %{"width" => 3, "height" => 2, "format" => "PNG", "exif" => %{}}

OCR is disabled for this analyzer (`disable_ocr: true`): the metadata lives in
the image header, so there is no reason to pay for a Tesseract pass. Use
`AshStorageXberg.Analyzers.Text` when the *text inside* an image is wanted.

---

*Consult [api-reference.md](api-reference.md) for complete listing*
