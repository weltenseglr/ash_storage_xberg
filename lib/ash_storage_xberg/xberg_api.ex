defmodule AshStorageXberg.XbergApi do
  @moduledoc """
  REST implementation of `AshStorageXberg.Xberg`, backed by an xberg sidecar
  (`ghcr.io/xberg-io/xberg`, `xberg serve`).

  Signature- and return-compatible with the `Xberg` NIF module from the `:xberg`
  hex package, so the two can be exchanged via configuration — see
  `AshStorageXberg.Xberg`.

  ## Configuration

      config :ash_storage_xberg,
        base_url: "http://localhost:8000",   # or XBERG_URL env var
        receive_timeout: 120_000,
        req_options: []                       # merged into every request (e.g. Req.Test plug)

  ## Input translation

  The NIF reads inputs in place; the sidecar receives them over HTTP. Inputs are
  translated as follows:

    * `%{bytes: binary}` — uploaded as a multipart file part (with `filename`
      and `mime_type` when given)
    * `%{uri: path}` pointing at a local file — streamed from disk as a
      multipart file part
    * `%{uri: url}` with a URL scheme (e.g. a presigned S3/Azure URL) — sent as
      a JSON request so the **sidecar downloads the file directly from the
      bucket**; the bytes never pass through the application. Note the sidecar's
      SSRF policy denies private/link-local hosts by default — for dev setups
      fetching from non-public endpoints, override via
      `config: %{url: %{crawl: %{ssrf: %{deny_private: false}}}}`.

  A batch must be all-remote or all-local/bytes; mixing both in one
  `extract_batch/1` call returns a validation error (they use different
  transports). Per-input `config` (the NIF's `FileExtractionConfig`) rides along
  in remote-URI requests; for multipart requests it is merged into the
  request-level config on single `extract/1` calls and rejected in batches
  (multipart cannot address configs to individual files).
  """

  @behaviour AshStorageXberg.Xberg

  @default_base_url "http://localhost:8000"
  @default_receive_timeout 120_000

  @impl true
  def extract(opts \\ []) do
    with {:ok, input} <- normalize_input(Keyword.get(opts, :input)),
         {:ok, config} <- normalize_config(Keyword.get(opts, :config)) do
      if remote?(input) do
        post_extract_json([input], config)
      else
        with {:ok, config} <- merge_input_config(config, input),
             {:ok, part} <- file_part(input) do
          post_extract_multipart([part], config)
        end
      end
    end
  end

  @impl true
  def extract_batch(opts \\ []) do
    with {:ok, inputs} <- normalize_inputs(Keyword.get(opts, :inputs)),
         {:ok, config} <- normalize_config(Keyword.get(opts, :config)) do
      case Enum.split_with(inputs, &remote?/1) do
        {[], []} ->
          {:error, :validation_error, ":inputs must not be empty"}

        {remote, []} ->
          post_extract_json(remote, config)

        {[], local} ->
          with :ok <- reject_per_input_configs(local),
               {:ok, parts} <- file_parts(local) do
            post_extract_multipart(parts, config)
          end

        {_remote, _local} ->
          {:error, :validation_error,
           "cannot mix remote-URI and local/bytes inputs in one batch; " <>
             "issue separate extract_batch/1 calls"}
      end
    end
  end

  @impl true
  def list_supported_formats do
    case request(:get, "/formats") do
      {:ok, formats} when is_list(formats) ->
        formats

      {:error, kind, message} ->
        raise "xberg sidecar /formats failed: #{kind}: #{message}"
    end
  end

  @doc """
  Detect the MIME type of a file (local path or `{bytes, filename}`) via the
  sidecar's dedicated `POST /detect` endpoint, without running extraction.

  This is the REST backend's implementation of the optional `c:AshStorageXberg.Xberg.detect/1`
  callback. Prefer `AshStorageXberg.Xberg.detect/1` from library code so the
  call keeps working on a NIF-only deployment.
  """
  @impl true
  @spec detect(AshStorageXberg.Xberg.detect_input()) ::
          {:ok, map()} | AshStorageXberg.Xberg.error()
  def detect(path) when is_binary(path) do
    with {:ok, part} <- file_part(%{"uri" => path}) do
      request(:post, "/detect", form_multipart: [files: part])
    end
  end

  def detect({bytes, filename}) when is_binary(bytes) and is_binary(filename) do
    request(:post, "/detect", form_multipart: [files: {bytes, filename: filename}])
  end

  ## REST-only conveniences (no NIF equivalent)

  @doc "Sidecar health status (`GET /health`)."
  @spec health() :: {:ok, map()} | AshStorageXberg.Xberg.error()
  def health, do: request(:get, "/health")

  @doc "Sidecar version (`GET /version`)."
  @spec version() :: {:ok, map()} | AshStorageXberg.Xberg.error()
  def version, do: request(:get, "/version")

  @doc "Pre-download models into the sidecar cache (`POST /cache/warm`)."
  @spec cache_warm(map()) :: {:ok, map()} | AshStorageXberg.Xberg.error()
  def cache_warm(body \\ %{}), do: request(:post, "/cache/warm", json: body)

  ## Request plumbing

  defp post_extract_json(inputs, config) do
    body =
      case config do
        nil -> %{"inputs" => inputs}
        config -> %{"inputs" => inputs, "config" => config}
      end

    request(:post, "/extract", json: body)
  end

  defp post_extract_multipart(parts, config) do
    form = Enum.map(parts, &{:files, &1}) ++ config_field(config)
    request(:post, "/extract", form_multipart: form)
  end

  defp config_field(nil), do: []
  defp config_field(config), do: [config: Jason.encode!(config)]

  defp request(method, path, req_opts \\ []) do
    [
      method: method,
      url: path,
      base_url: base_url(),
      receive_timeout: receive_timeout(),
      retry: retry(method)
    ]
    |> Keyword.merge(req_opts)
    |> Keyword.merge(Application.get_env(:ash_storage_xberg, :req_options, []))
    |> Req.request()
    |> handle_response()
  end

  # Only the read-only endpoints retry. `POST /extract` is neither cheap nor
  # idempotent — Req's `:transient` retries 5xx and timeouts, and a 120s OCR or
  # Whisper pass that failed *after* doing the work would simply be run again,
  # three times over. Re-enable per deployment via `:req_options` if you want it.
  defp retry(:get), do: :transient
  defp retry(_method), do: false

  defp handle_response({:ok, %Req.Response{status: status, body: body}})
       when status in 200..299,
       do: {:ok, body}

  defp handle_response({:ok, %Req.Response{body: %{"error_type" => type, "message" => message}}}),
    do: {:error, AshStorageXberg.Errors.kind(type, message, :unknown_error), message}

  defp handle_response({:ok, %Req.Response{status: status, body: body}}),
    do: {:error, :http_error, "unexpected HTTP #{status}: #{inspect(body)}"}

  defp handle_response({:error, %{__exception__: true} = exception}),
    do: {:error, :transport_error, Exception.message(exception)}

  defp base_url do
    Application.get_env(:ash_storage_xberg, :base_url) ||
      System.get_env("XBERG_URL", @default_base_url)
  end

  defp receive_timeout do
    Application.get_env(:ash_storage_xberg, :receive_timeout, @default_receive_timeout)
  end

  ## Input normalization — accepts the same shapes the NIF accepts

  defp normalize_input(nil), do: {:error, :validation_error, "missing :input"}

  defp normalize_input(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> {:error, :validation_error, ":input binary must be a JSON-encoded object"}
    end
  end

  defp normalize_input(%_{} = struct), do: normalize_input(Map.from_struct(struct))

  defp normalize_input(map) when is_map(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new(fn {k, v} -> {to_string(k), stringify(v)} end)
    |> then(&{:ok, &1})
  end

  defp normalize_input(keyword) when is_list(keyword) do
    if Keyword.keyword?(keyword) do
      normalize_input(Map.new(keyword))
    else
      {:error, :validation_error, "invalid :input"}
    end
  end

  defp normalize_input(_), do: {:error, :validation_error, "invalid :input"}

  defp normalize_inputs(nil), do: {:error, :validation_error, "missing :inputs"}

  defp normalize_inputs(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> normalize_inputs(list)
      _ -> {:error, :validation_error, ":inputs binary must be a JSON-encoded array"}
    end
  end

  defp normalize_inputs(list) when is_list(list) do
    if Keyword.keyword?(list) and list != [] do
      {:error, :validation_error, ":inputs must be a list of inputs"}
    else
      collect(list, &normalize_input/1)
    end
  end

  defp normalize_inputs(_), do: {:error, :validation_error, "invalid :inputs"}

  # Atoms (e.g. kind: :uri) must become strings for JSON transport.
  defp stringify(value) when is_atom(value) and not is_boolean(value), do: to_string(value)
  defp stringify(value), do: value

  ## Config normalization → plain data (map) or nil

  defp normalize_config(nil), do: {:ok, nil}

  defp normalize_config(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> {:error, :validation_error, ":config binary must be a JSON-encoded object"}
    end
  end

  defp normalize_config(other) do
    {:ok, other |> Jason.encode!() |> Jason.decode!()}
  rescue
    e in [Jason.EncodeError, Protocol.UndefinedError] ->
      {:error, :validation_error, "config is not JSON-encodable: #{Exception.message(e)}"}
  end

  defp merge_input_config(config, %{"config" => input_config})
       when not is_nil(input_config) do
    with {:ok, override} <- normalize_config(input_config) do
      {:ok, Map.merge(config || %{}, override)}
    end
  end

  defp merge_input_config(config, _input), do: {:ok, config}

  defp reject_per_input_configs(inputs) do
    if Enum.any?(inputs, &(not is_nil(&1["config"]))) do
      {:error, :validation_error,
       "per-input config is not supported for local/bytes batches (multipart transport)"}
    else
      :ok
    end
  end

  ## Input routing

  defp remote?(%{"bytes" => bytes}) when is_binary(bytes), do: false
  defp remote?(%{"uri" => uri}) when is_binary(uri), do: AshStorageXberg.Uri.remote?(uri)
  defp remote?(_), do: false

  ## Multipart parts

  defp file_part(%{"bytes" => bytes} = input) when is_binary(bytes) do
    filename = input["filename"] || "upload.bin"
    {:ok, {bytes, filename: filename, content_type: input["mime_type"]}}
  end

  defp file_part(%{"uri" => uri} = input) when is_binary(uri) do
    path = AshStorageXberg.Uri.local_path(uri)

    if File.regular?(path) do
      filename = input["filename"] || Path.basename(path)

      {:ok, {File.stream!(path, 64 * 1024), filename: filename, content_type: input["mime_type"]}}
    else
      {:error, :validation_error, "file not found: #{inspect(path)}"}
    end
  end

  defp file_part(_input),
    do: {:error, :validation_error, "input requires either :bytes or a :uri"}

  defp file_parts(inputs), do: collect(inputs, &file_part/1)

  defp collect(items, fun) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end
end
