defmodule AshStorageXberg.Xberg do
  @moduledoc """
  The exchangeable xberg interface.

  Mirrors the public extraction API of the `Xberg` module from the `:xberg` hex
  package (the Rustler NIF binding), so that the in-process NIF and the REST
  sidecar client can be swapped without touching call sites:

    * `extract/1` — `Xberg.extract(input: ..., config: ...)`
    * `extract_batch/1` — `Xberg.extract_batch(inputs: ..., config: ...)`
    * `list_supported_formats/0`

  plus `detect/1`, which is optional: backends that have a cheap MIME-sniffing
  endpoint implement it, and for those that do not the facade derives the type
  from a metadata-only extraction instead. That keeps
  `AshStorageXberg.Analyzers.ContentType` working on either backend — the
  choice of backend is exclusive, so an analyzer that reached past this facade
  into the REST client would simply fail on a NIF-only deployment.

  Inputs and configs are accepted in the same shapes the NIF accepts: an already
  JSON-encoded binary, or any Jason-encodable term (map, keyword-built struct such
  as `Xberg.ExtractInput`/`Xberg.ExtractionConfig` when the `:xberg` package is
  present). Returns are `{:ok, result_map}` or `{:error, kind, message}` — the
  NIF's three-element error tuple.

  ## Choosing the implementation

      # default — REST sidecar (ghcr.io/xberg-io/xberg, `xberg serve`)
      config :ash_storage_xberg, xberg: AshStorageXberg.XbergApi

      # in-process NIF — add {:xberg, "~> 1.0"} to deps
      config :ash_storage_xberg, xberg: Xberg

  Call sites use this module's delegating functions:

      AshStorageXberg.Xberg.extract(
        input: %{uri: "/tmp/upload/document.pdf"},
        config: %{output_format: "markdown"}
      )
  """

  @typedoc "The NIF-style error tuple: kind atom plus human-readable message."
  @type error :: {:error, atom(), String.t()}

  @typedoc """
  The two-element error some NIF builds return instead of the three-element one.
  `extract/1` and `extract_batch/1` classify its message and normalize it to
  `t:error/0`, so call sites only ever see the three-element shape.
  """
  @type legacy_error :: {:error, String.t()}

  @typedoc "What `detect/1` accepts: a local path, or in-memory bytes with a filename."
  @type detect_input :: String.t() | {binary(), String.t()}

  @doc "Extract content from a single bytes or URI input."
  @callback extract(opts :: keyword()) :: {:ok, map()} | error() | legacy_error()

  @doc "Extract content from multiple bytes or URI inputs."
  @callback extract_batch(opts :: keyword()) :: {:ok, map()} | error() | legacy_error()

  @doc "List all supported document formats."
  @callback list_supported_formats() :: [map()]

  @doc """
  Detect an input's MIME type without extracting it.

  Optional: implement it when the backend has a dedicated sniffing endpoint.
  `AshStorageXberg.Xberg.detect/1` falls back to a metadata-only extraction for
  backends that do not.
  """
  @callback detect(input :: detect_input()) :: {:ok, map()} | error() | legacy_error()

  @optional_callbacks detect: 1

  @doc "The configured implementation module."
  @spec impl() :: module()
  def impl do
    Application.get_env(:ash_storage_xberg, :xberg, AshStorageXberg.XbergApi)
  end

  @spec extract(keyword()) :: {:ok, map()} | error()
  def extract(opts \\ []) do
    opts |> normalize_input_option(:input) |> impl().extract() |> normalize_response()
  end

  @spec extract_batch(keyword()) :: {:ok, map()} | error()
  def extract_batch(opts \\ []) do
    opts |> normalize_input_option(:inputs) |> impl().extract_batch() |> normalize_response()
  end

  @spec list_supported_formats() :: [map()]
  def list_supported_formats, do: impl().list_supported_formats() |> normalize_json()

  @doc """
  Detect the MIME type of `input`, returning `{:ok, %{"mime_type" => type}}`.

  Uses the backend's own `c:detect/1` when it has one — the REST sidecar's
  `POST /detect` is a cheap header sniff. Backends without one (the NIF) fall
  back to a metadata-only extraction, which is correct but costs a full parse;
  prefer `analyze: :oban` on `AshStorageXberg.Analyzers.ContentType` there.
  """
  @spec detect(detect_input()) :: {:ok, map()} | error()
  def detect(input) do
    implementation = impl()

    if Code.ensure_loaded?(implementation) and function_exported?(implementation, :detect, 1) do
      input |> implementation.detect() |> normalize_response()
    else
      detect_via_extract(input)
    end
  end

  defp detect_via_extract(input) do
    case extract(input: detect_input(input), config: %{disable_ocr: true}) do
      {:ok, %{"results" => [%{"mime_type" => mime} | _rest]}} when is_binary(mime) ->
        {:ok, %{"mime_type" => mime}}

      {:ok, %{"errors" => [error | _rest]}} when is_map(error) ->
        {:error,
         AshStorageXberg.Errors.kind(error["error_type"], error["message"], :unknown_error),
         error["message"] || "xberg extraction failed"}

      {:ok, _envelope} ->
        {:error, :invalid_response, "the xberg backend reported no mime_type"}

      {:error, _kind, _message} = error ->
        error
    end
  end

  defp detect_input({bytes, filename}) when is_binary(bytes) and is_binary(filename),
    do: %{bytes: bytes, filename: filename}

  defp detect_input(path) when is_binary(path), do: %{uri: path}

  defp normalize_input_option(opts, :input) do
    Keyword.update(opts, :input, nil, &canonicalize_local_input/1)
  end

  defp normalize_input_option(opts, :inputs) do
    Keyword.update(opts, :inputs, nil, fn
      inputs when is_list(inputs) -> Enum.map(inputs, &canonicalize_local_input/1)
      inputs -> inputs
    end)
  end

  # Some NIF builds reject the detected `audio/x-wav` alias during transcription,
  # so local .wav inputs are canonicalized to `audio/wav` and given a filename
  # before backend dispatch.
  defp canonicalize_local_input(%{uri: uri} = input) when is_binary(uri),
    do: canonicalize_local_wav(input, uri, :filename, :mime_type)

  defp canonicalize_local_input(%{"uri" => uri} = input) when is_binary(uri),
    do: canonicalize_local_wav(input, uri, "filename", "mime_type")

  defp canonicalize_local_input(input), do: input

  defp canonicalize_local_wav(input, uri, filename_key, mime_key) do
    if local_wav?(uri) do
      input
      |> Map.put_new(filename_key, uri |> AshStorageXberg.Uri.local_path() |> Path.basename())
      |> Map.update(mime_key, "audio/wav", &canonical_wav_mime/1)
    else
      input
    end
  end

  defp local_wav?(uri) do
    not AshStorageXberg.Uri.remote?(uri) and String.downcase(Path.extname(uri)) == ".wav"
  end

  defp canonical_wav_mime("audio/x-wav"), do: "audio/wav"
  defp canonical_wav_mime(mime_type), do: mime_type

  defp normalize_response({:ok, result}), do: {:ok, normalize_json(result)}

  defp normalize_response({:error, message}) when is_binary(message),
    do: {:error, AshStorageXberg.Errors.from_message(message), message}

  defp normalize_response(error), do: error

  defp normalize_json(%_{} = struct), do: struct |> Map.from_struct() |> normalize_json()

  defp normalize_json(map) when is_map(map) do
    map
    |> Map.new(fn {key, value} -> {to_string(key), normalize_json(value)} end)
    |> flatten_tagged_format()
  end

  defp normalize_json(list) when is_list(list), do: Enum.map(list, &normalize_json/1)

  defp normalize_json(value) when is_atom(value) and value not in [true, false, nil],
    do: to_string(value)

  defp normalize_json(value), do: value

  defp flatten_tagged_format(%{"format_type" => type} = format) when is_binary(type) do
    case Map.get(format, type) do
      subtype when is_map(subtype) -> format |> Map.delete(type) |> Map.merge(subtype)
      _subtype -> format
    end
  end

  defp flatten_tagged_format(map), do: map
end
