defmodule AshStorageXberg.Variants.Transcript do
  @moduledoc """
  `AshStorage.Variant` that stores the Whisper transcript of an audio or video
  file, produced by the xberg sidecar.

      variant :transcript, {AshStorageXberg.Variants.Transcript, model: :base},
        generate: :oban

  ## Options

    * `:model` — Whisper model, `:tiny` (default), `:base`, `:small`,
      `:medium`, `:large`
    * `:language` — source language hint (e.g. `"en"`); omitted for
      auto-detection
    * `:timestamps` — when `true`, write a JSON document with the transcript
      and its segments instead of plain text (default `false`)
    * `:max_duration_ms` — stop transcribing after this much audio
    * `:timeout` — extraction timeout in **seconds** (sent as
      `extraction_timeout_secs`)

  Returns `{:ok, %{content_type: "text/plain" | "application/json", model: ...}}`,
  plus `:language` when the sidecar reported one.

  ## Sidecar requirements

  Transcription needs an xberg build with the audio/Whisper feature enabled.
  The stock `ghcr.io/xberg-io/xberg` image does not have one: it rejects audio
  input with `{:error, {:unsupported_format, _}}` and does not accept the
  `transcription` config key. A media-enabled build (this repo's devcontainer
  and CI use `ghcr.io/weltenseglr/xberg:omni`) is required.

  Models are downloaded into the sidecar's cache volume on first use — warm them
  with `AshStorageXberg.XbergApi.cache_warm/1` at deploy time and always prefer
  `generate: :oban`.
  """

  @behaviour AshStorage.Variant

  alias AshStorageXberg.Mime
  alias AshStorageXberg.Result
  alias AshStorageXberg.Variants

  @default_model :tiny

  @impl true
  def accept?(content_type) when is_binary(content_type),
    do: content_type |> Mime.normalize() |> String.starts_with?(["audio/", "video/"])

  def accept?(_content_type), do: false

  @impl true
  def transform(source_path, dest_path, opts) do
    timestamps? = Keyword.get(opts, :timestamps, false)

    with {:ok, result} <- Result.extract(source_path, config(opts)),
         :ok <- Variants.write(dest_path, render(result, timestamps?, opts)) do
      {:ok,
       Result.compact(%{
         content_type: content_type(timestamps?),
         model: to_string(Keyword.get(opts, :model, @default_model)),
         language: language(result, opts)
       })}
    end
  end

  defp config(opts) do
    transcription =
      %{
        enabled: true,
        model: to_string(Keyword.get(opts, :model, @default_model)),
        timestamps: Keyword.get(opts, :timestamps, false)
      }
      |> Variants.put_unless_nil(:language, Keyword.get(opts, :language))
      |> Variants.put_unless_nil(:max_duration_ms, Keyword.get(opts, :max_duration_ms))

    %{transcription: transcription}
    |> Variants.put_unless_nil(:extraction_timeout_secs, Keyword.get(opts, :timeout))
  end

  defp render(result, false, _opts), do: Result.content(result)

  # The written document and the returned variant metadata must agree on the
  # language, so both resolve it through language/2 with the caller's opts.
  defp render(result, true, opts) do
    Jason.encode!(%{
      "content" => Result.content(result),
      "segments" => segments(result),
      "language" => language(result, opts)
    })
  end

  defp segments(result) do
    result["segments"] || get_in(result, ["metadata", "transcription", "segments"]) || []
  end

  defp content_type(true), do: "application/json"
  defp content_type(false), do: "text/plain"

  defp language(result, opts) do
    get_in(result, ["metadata", "transcription", "language"]) ||
      get_in(result, ["metadata", "language"]) ||
      case Keyword.get(opts, :language) do
        language when is_binary(language) -> language
        _other -> nil
      end
  end
end
