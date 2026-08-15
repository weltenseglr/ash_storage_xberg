defmodule AshStorageXberg.Result do
  @moduledoc false

  # Reading an xberg `ExtractionResult` envelope.
  #
  # Analyzers and variants do the same three things: run one extraction through
  # the `AshStorageXberg.Xberg` facade, unwrap the envelope to its first
  # per-document result, and normalize both transport-level
  # (`{:error, kind, message}`) and per-file (the envelope's `"errors"`) failures
  # to the `{:error, {kind, message}}` shape ash_storage surfaces. That used to
  # be written twice, with two different fallback errors and — in the case of
  # `word_count/1` and the language readers — two different answers for the same
  # document.
  #
  # Layering: this sits above `AshStorageXberg.Xberg` and below
  # `AshStorageXberg.Analyzers` / `AshStorageXberg.Variants`.

  alias AshStorageXberg.Errors
  alias AshStorageXberg.Xberg

  @type error :: {:error, {atom(), String.t()}}

  @doc "Extract `path` through the configured backend, unwrapped to its first result."
  @spec extract(String.t(), map()) :: {:ok, map()} | error()
  def extract(path, config \\ %{}) do
    [input: %{uri: path}]
    |> put_config(config)
    |> Xberg.extract()
    |> first()
  end

  defp put_config(opts, config) when map_size(config) == 0, do: opts
  defp put_config(opts, config), do: Keyword.put(opts, :config, config)

  @doc "Unwrap an extraction response to its first per-document result."
  @spec first({:ok, map()} | Xberg.error()) :: {:ok, map()} | error()
  def first({:ok, %{"results" => [result | _rest]}}), do: {:ok, result}

  def first({:ok, %{"errors" => [error | _rest]}}) when is_map(error) do
    {:error,
     {Errors.kind(error["error_type"], error["message"], :unknown_error),
      error["message"] || "xberg extraction failed"}}
  end

  def first({:ok, envelope}),
    do: {:error, {:invalid_response, "unexpected xberg envelope: #{inspect(envelope)}"}}

  def first({:error, kind, message}), do: {:error, {kind, message}}

  ## Field readers

  @doc "Document-level metadata (`metadata`)."
  @spec metadata(map()) :: map()
  def metadata(result), do: Map.get(result, "metadata") || %{}

  @doc "Format-specific metadata (`metadata.format`)."
  @spec format_metadata(map()) :: map()
  def format_metadata(result), do: Map.get(metadata(result), "format") || %{}

  @doc "Free-form extras (`metadata.additional`)."
  @spec additional(map()) :: map()
  def additional(result), do: Map.get(metadata(result), "additional") || %{}

  @doc "The extracted content, or `\"\"` when the result carries none."
  @spec content(map()) :: String.t()
  def content(result), do: result["content"] || ""

  @doc """
  Word count of `content`.

  Splits on Unicode whitespace: extracted PDF and Office text is full of
  non-breaking spaces, and an ASCII-only `\\s` silently undercounts them.
  """
  @spec word_count(String.t()) :: non_neg_integer()
  def word_count(content), do: content |> String.split(~r/\s+/u, trim: true) |> length()

  @doc """
  The document's own declared language (`metadata.language`).

  Guarded to a string so a structured value can never reach `blob.metadata`,
  where a plain ISO code is expected.
  """
  @spec declared_language(map()) :: String.t() | nil
  def declared_language(result) do
    case Map.get(metadata(result), "language") do
      language when is_binary(language) -> language
      _other -> nil
    end
  end

  @doc """
  The first detected language, as an ISO code.

  Builds disagree on where the list lives (top level or under `metadata`) and on
  what its entries look like (a bare code, or an object carrying one), so all
  four combinations are accepted.
  """
  @spec detected_language(map()) :: String.t() | nil
  def detected_language(result) do
    languages =
      result["detected_languages"] || get_in(result, ["metadata", "detected_languages"])

    languages |> List.wrap() |> Enum.find_value(&language_code/1)
  end

  defp language_code(code) when is_binary(code), do: code
  defp language_code(%{} = entry), do: entry["language"] || entry["code"] || entry["iso_code"]
  defp language_code(_entry), do: nil

  @doc "Drop `nil` values from a metadata map."
  @spec compact(map()) :: map()
  def compact(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)

  @doc """
  The first value present under any of `keys`.

  Only `nil` counts as absent — a legitimately `false` value is returned rather
  than skipped, which `Enum.find_value/2` would not do.
  """
  @spec first_value(map(), [String.t()]) :: term()
  def first_value(map, keys) do
    Enum.reduce_while(keys, nil, fn key, _acc ->
      case Map.get(map, key) do
        nil -> {:cont, nil}
        value -> {:halt, value}
      end
    end)
  end
end
