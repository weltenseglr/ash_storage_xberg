# `AshStorageXberg.Variants.PageThumbnail`
[🔗](https://github.com/weltenseglr/ash_storage_xberg/blob/main/lib/ash_storage_xberg/variants/page_thumbnail.ex#L1)

`AshStorage.Variant` that renders a page of a document to an image, using the
xberg sidecar's page rasterization.

    variant :thumbnail, {AshStorageXberg.Variants.PageThumbnail, dpi: 150, format: :webp}

## Options

  * `:page` — 1-based page to render (default `1`)
  * `:format` — `:png` (default), `:webp`, `:jpeg`, `:heif` or `:native`;
    sent as the sidecar's `images.output_format`
  * `:dpi` — requested rasterization DPI (default `72`, sent as
    `images.target_dpi`)
  * `:max_dimension` — cap on the longest edge (sent as
    `images.max_image_dimension`)

Returns `{:ok, %{content_type: ..., width: ..., height: ..., page: ...}}`.

## Sidecar behaviour (verified against xberg 1.0.14, re-checked on 1.1.0)

Page rasters are produced by the sidecar's page-rendering pass, which only
runs when OCR is forced, so the request always sets `force_ocr: true`
alongside `images.include_page_rasters: true` — `include_page_rasters` on its
own returns no images. Rendering is therefore not free: prefer
`generate: :oban` for large documents.

`:dpi`/`:max_dimension` are forwarded but still advisory: both 1.0.14 and
1.1.0 render PDF pages at the fixed OCR DPI of 150 regardless (requesting 72
and 300 for the same A4 page both return 1241×1754). Always trust the
`width`/`height` in the returned metadata rather than computing them from
`:dpi`.

The document side of `accept?/1` is the curated list of rasterizable types
*intersected with the sidecar's own `GET /formats` list*
(`AshStorageXberg.Formats`), so a build that cannot extract a format never
gets asked to rasterize it — on both 1.0.14 and 1.1.0 that drops ODF Graphics
(`.odg`), which the sidecar does not report as extractable. The entry is kept
in the curated list on purpose: the intersection lets a build that *does*
support it start working with no code change. Accepted
Office/ODF types are rasterizable in principle, but builds without an office
renderer still return no raster, in which case `transform/3` fails with
`{:error, {:no_page_raster, message}}`.

`image/*` is accepted without that intersection: the sidecar returns the
embedded image itself rather than a page raster, and it handles image types
beyond the ones it lists as extractable documents.

---

*Consult [api-reference.md](api-reference.md) for complete listing*
