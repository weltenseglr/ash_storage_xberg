defmodule AshStorageXberg.Variants.PageThumbnail do
  @moduledoc """
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
  """

  @behaviour AshStorage.Variant

  alias AshStorageXberg.Formats
  alias AshStorageXberg.Mime
  alias AshStorageXberg.Result
  alias AshStorageXberg.Variants

  @default_dpi 72
  @default_page 1
  @default_format :png

  @document_types ~w(
    application/pdf
    application/vnd.openxmlformats-officedocument.wordprocessingml.document
    application/vnd.openxmlformats-officedocument.spreadsheetml.sheet
    application/vnd.openxmlformats-officedocument.presentationml.presentation
    application/msword
    application/vnd.ms-excel
    application/vnd.ms-powerpoint
    application/vnd.oasis.opendocument.text
    application/vnd.oasis.opendocument.spreadsheet
    application/vnd.oasis.opendocument.presentation
    application/vnd.oasis.opendocument.graphics
    application/epub+zip
  )

  @content_types %{
    "png" => "image/png",
    "jpeg" => "image/jpeg",
    "jpg" => "image/jpeg",
    "webp" => "image/webp",
    "heif" => "image/heif",
    "gif" => "image/gif",
    "tiff" => "image/tiff",
    "bmp" => "image/bmp",
    "svg" => "image/svg+xml"
  }

  @impl true
  def accept?(content_type) when is_binary(content_type) do
    mime = Mime.normalize(content_type)

    String.starts_with?(mime, "image/") or
      (mime in @document_types and Formats.supported?(mime))
  end

  def accept?(_content_type), do: false

  @impl true
  def transform(source_path, dest_path, opts) do
    page = Keyword.get(opts, :page, @default_page)
    format = Keyword.get(opts, :format, @default_format)

    with {:ok, result} <- Result.extract(source_path, config(opts)),
         {:ok, image} <- page_raster(result["images"] || [], page),
         {:ok, bytes} <- image_bytes(image),
         :ok <- Variants.write(dest_path, bytes) do
      {:ok,
       Result.compact(%{
         content_type: content_type(image, format),
         width: image["width"],
         height: image["height"],
         page: image["page_number"] || page
       })}
    end
  end

  defp config(opts) do
    images =
      %{
        extract_images: true,
        include_page_rasters: true,
        include_data_base64: true,
        target_dpi: Keyword.get(opts, :dpi, @default_dpi),
        output_format: %{type: format_name(Keyword.get(opts, :format, @default_format))}
      }
      |> Variants.put_unless_nil(:max_image_dimension, Keyword.get(opts, :max_dimension))

    # Rasterization rides along with the page-rendering pass of forced OCR.
    %{force_ocr: true, images: images}
  end

  defp format_name(:jpg), do: "jpeg"
  defp format_name(format), do: to_string(format)

  defp page_raster(images, page) do
    candidates =
      case Enum.filter(images, &(&1["image_kind"] == "page_raster")) do
        [] -> images
        rasters -> rasters
      end

    image =
      Enum.find(candidates, &(&1["page_number"] == page)) ||
        Enum.find(candidates, &(is_nil(&1["page_number"]) and page == @default_page))

    case image do
      nil ->
        {:error, {:no_page_raster, "the xberg sidecar returned no page raster for page #{page}"}}

      image ->
        {:ok, image}
    end
  end

  defp image_bytes(%{"data_base64" => base64}) when is_binary(base64) do
    case Base.decode64(base64) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, {:invalid_raster, "page raster data_base64 is not valid base64"}}
    end
  end

  defp image_bytes(%{"data" => data}) when is_binary(data), do: {:ok, data}

  defp image_bytes(%{"data" => data}) when is_list(data) do
    {:ok, :binary.list_to_bin(data)}
  rescue
    ArgumentError -> {:error, {:invalid_raster, "page raster data is not a byte list"}}
  end

  defp image_bytes(_image),
    do: {:error, {:invalid_raster, "the page raster carried no image data"}}

  defp content_type(image, requested_format) do
    content_type_for(image["format"]) || content_type_for(requested_format) ||
      "application/octet-stream"
  end

  defp content_type_for(nil), do: nil

  defp content_type_for(format),
    do: Map.get(@content_types, format |> to_string() |> String.downcase())
end
