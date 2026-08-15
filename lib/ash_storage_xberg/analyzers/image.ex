defmodule AshStorageXberg.Analyzers.Image do
  @moduledoc """
  Image dimensions, format, and EXIF tags.

      analyzer AshStorageXberg.Analyzers.Image

  Result (string-keyed, like every analyzer in this library):

      %{"width" => 3, "height" => 2, "format" => "PNG", "exif" => %{}}

  OCR is disabled for this analyzer (`disable_ocr: true`): the metadata lives in
  the image header, so there is no reason to pay for a Tesseract pass. Use
  `AshStorageXberg.Analyzers.Text` when the *text inside* an image is wanted.
  """

  @behaviour AshStorage.Analyzer

  alias AshStorageXberg.Analyzers
  alias AshStorageXberg.Mime
  alias AshStorageXberg.Result

  @config %{disable_ocr: true}

  @impl true
  def accept?(content_type) when is_binary(content_type),
    do: content_type |> Mime.normalize() |> String.starts_with?("image/")

  def accept?(_content_type), do: false

  @impl true
  def analyze(path, _opts) do
    with {:ok, result} <- Result.extract(path, @config) do
      format = Result.format_metadata(result)

      {:ok,
       Analyzers.result(%{
         width: format["width"],
         height: format["height"],
         format: format["format"],
         exif: format["exif"] || %{}
       })}
    end
  end
end
