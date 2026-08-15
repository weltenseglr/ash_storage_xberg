defmodule AshStorageXberg.Analyzers.Document do
  @moduledoc """
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
  """

  @behaviour AshStorage.Analyzer

  alias AshStorageXberg.Analyzers
  alias AshStorageXberg.Formats
  alias AshStorageXberg.Mime
  alias AshStorageXberg.Result

  @content_types MapSet.new(~w(
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
    application/rtf
    text/rtf
    application/epub+zip
  ))

  @config %{disable_ocr: true, language_detection: %{enabled: true}}

  @impl true
  def accept?(content_type) when is_binary(content_type) do
    mime = Mime.normalize(content_type)

    MapSet.member?(@content_types, mime) and Formats.supported?(mime)
  end

  def accept?(_content_type), do: false

  @impl true
  def analyze(path, _opts) do
    with {:ok, result} <- Result.extract(path, @config) do
      metadata = Result.metadata(result)

      {:ok,
       Analyzers.result(%{
         title: metadata["title"],
         authors: authors(metadata),
         page_count: page_count(result),
         # This analyzer reads the document header, so its declared language
         # wins; detection only fills in for documents that carry none.
         language: Result.declared_language(result) || Result.detected_language(result),
         created_at: metadata["created_at"]
       })}
    end
  end

  defp authors(metadata) do
    case metadata["authors"] || List.wrap(metadata["created_by"]) do
      [] -> nil
      authors -> authors
    end
  end

  # PDFs report the count in their format metadata; other formats only carry the
  # envelope's page/slide/sheet count (0 when the format has no page structure).
  defp page_count(result) do
    case Result.format_metadata(result)["page_count"] do
      nil -> result |> get_in(["counts", "pages"]) |> positive()
      page_count -> page_count
    end
  end

  defp positive(count) when is_integer(count) and count > 0, do: count
  defp positive(_count), do: nil
end
