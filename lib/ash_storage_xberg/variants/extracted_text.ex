defmodule AshStorageXberg.Variants.ExtractedText do
  @moduledoc """
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
  """

  @behaviour AshStorage.Variant

  alias AshStorageXberg.Formats
  alias AshStorageXberg.Result
  alias AshStorageXberg.Variants

  @default_format :markdown

  @content_types %{
    markdown: "text/markdown",
    plain: "text/plain",
    json: "application/json"
  }

  @impl true
  def accept?(content_type) when is_binary(content_type), do: Formats.supported?(content_type)
  def accept?(_content_type), do: false

  @impl true
  def transform(source_path, dest_path, opts) do
    format = Keyword.get(opts, :format, @default_format)

    with {:ok, config} <- config(format, opts),
         {:ok, result} <- Result.extract(source_path, config),
         :ok <- Variants.write(dest_path, render(format, result)) do
      {:ok, metadata(format, result)}
    end
  end

  defp config(format, opts) when is_map_key(@content_types, format) do
    ocr? = Keyword.get(opts, :ocr, false)

    config =
      %{output_format: output_format(format), disable_ocr: not ocr?}
      |> Variants.put_unless_nil(:extraction_timeout_secs, Keyword.get(opts, :timeout))

    {:ok, config}
  end

  defp config(format, _opts) do
    {:error,
     {:invalid_format,
      "unknown :format #{inspect(format)}; expected one of #{inspect(Map.keys(@content_types))}"}}
  end

  defp output_format(:plain), do: "plain"
  defp output_format(_markdown_or_json), do: "markdown"

  defp render(:json, result) do
    Jason.encode!(%{
      "content" => Result.content(result),
      "metadata" => Result.metadata(result),
      "tables" => result["tables"] || []
    })
  end

  defp render(_text_format, result), do: Result.content(result)

  defp metadata(format, result) do
    Result.compact(%{
      content_type: @content_types[format],
      word_count: result |> Result.content() |> Result.word_count(),
      language: Result.declared_language(result) || Result.detected_language(result),
      ocr_used: Result.metadata(result)["ocr_used"]
    })
  end
end
