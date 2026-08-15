defmodule AshStorageXberg.Analyzers.Text do
  @moduledoc """
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
  """

  @behaviour AshStorage.Analyzer

  alias AshStorageXberg.Analyzers
  alias AshStorageXberg.Formats
  alias AshStorageXberg.Result

  @default_max_bytes 65_536

  @impl true
  def accept?(content_type), do: Formats.supported?(content_type)

  @impl true
  def analyze(path, opts) do
    with {:ok, result} <- Result.extract(path, config(opts)) do
      content = Result.content(result)
      {text, truncated?} = truncate(content, Keyword.get(opts, :max_bytes, @default_max_bytes))

      {:ok,
       Analyzers.result(%{
         text: text,
         # This analyzer is about the extracted text, so a language detected
         # from the body wins over whatever the container declares.
         language: Result.detected_language(result) || Result.declared_language(result),
         word_count: Result.word_count(content),
         ocr_used: Result.metadata(result)["ocr_used"] == true,
         text_truncated: if(truncated?, do: true)
       })}
    end
  end

  defp config(opts) do
    %{
      output_format: output_format(Keyword.get(opts, :output, :plain)),
      disable_ocr: not Keyword.get(opts, :ocr, false),
      language_detection: %{enabled: true}
    }
    |> put_timeout(Keyword.get(opts, :timeout))
  end

  defp output_format(:markdown), do: "markdown"
  defp output_format(:plain), do: "plain"
  defp output_format(other) when is_binary(other), do: other
  defp output_format(other) when is_atom(other), do: Atom.to_string(other)

  defp put_timeout(config, nil), do: config
  defp put_timeout(config, seconds), do: Map.put(config, :extraction_timeout_secs, seconds)

  defp truncate(content, max_bytes) when not is_integer(max_bytes), do: {content, false}

  defp truncate(content, max_bytes) when byte_size(content) <= max_bytes, do: {content, false}

  defp truncate(content, max_bytes) when max_bytes <= 0, do: {"", content != ""}

  defp truncate(content, max_bytes) do
    {content |> binary_part(0, max_bytes) |> trim_to_utf8_boundary(), true}
  end

  # A hard byte cut can land inside a multi-byte character; drop the partial
  # trailing bytes (at most three) so the result stays valid UTF-8.
  defp trim_to_utf8_boundary(chunk) do
    if String.valid?(chunk) do
      chunk
    else
      trim_to_utf8_boundary(binary_part(chunk, 0, byte_size(chunk) - 1))
    end
  end
end
