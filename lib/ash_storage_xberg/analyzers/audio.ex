defmodule AshStorageXberg.Analyzers.Audio do
  @moduledoc """
  Technical metadata of audio and video files.

      analyzer AshStorageXberg.Analyzers.Audio

  Result (string-keyed; only the keys the sidecar actually reports are written):

      %{
        "duration_ms" => 1_800_000,
        "codec" => "mp3",
        "container" => "mp3",
        "sample_rate_hz" => 44_100,
        "channels" => 2,
        "bitrate" => 128_000
      }

  ## Sidecar support

  Media metadata comes from the media-aware xberg builds; the values are read
  from the result's format metadata and its `additional` extras, tolerating the
  spelling differences between builds (`duration_ms` vs `duration_seconds`,
  `sample_rate` vs `sample_rate_hz`, ...).

  Backends that require transcription for all audio/video extraction reject
  metadata-only requests with `{:error, {:transcription_error, message}}`;
  builds without media support may instead return `:unsupported_format`. Both
  surface as normal analyzer errors.

  Transcription of the audio itself is the job of
  `AshStorageXberg.Variants.Transcript`, not of this analyzer; this analyzer
  never enables or downloads a Whisper model.
  """

  @behaviour AshStorage.Analyzer

  alias AshStorageXberg.Analyzers
  alias AshStorageXberg.Mime
  alias AshStorageXberg.Result

  @config %{disable_ocr: true}

  @duration_ms_keys ~w(duration_ms duration_millis)
  @duration_secs_keys ~w(duration_seconds duration_secs duration)
  @codec_keys ~w(codec audio_codec codec_name)
  @container_keys ~w(container format_name container_format format)
  @sample_rate_keys ~w(sample_rate_hz sample_rate sample_rate_hertz)
  @channels_keys ~w(channels channel_count num_channels)
  @bitrate_keys ~w(bitrate bit_rate bitrate_bps bits_per_second)

  @impl true
  def accept?(content_type) when is_binary(content_type),
    do: content_type |> Mime.normalize() |> String.starts_with?(["audio/", "video/"])

  def accept?(_content_type), do: false

  @impl true
  def analyze(path, _opts) do
    with {:ok, result} <- Result.extract(path, @config) do
      fields = Map.merge(Result.additional(result), Result.format_metadata(result))

      {:ok,
       Analyzers.result(%{
         duration_ms: duration_ms(fields),
         codec: Result.first_value(fields, @codec_keys),
         container: Result.first_value(fields, @container_keys),
         sample_rate_hz: Result.first_value(fields, @sample_rate_keys),
         channels: Result.first_value(fields, @channels_keys),
         bitrate: Result.first_value(fields, @bitrate_keys)
       })}
    end
  end

  defp duration_ms(fields) do
    case Result.first_value(fields, @duration_ms_keys) do
      nil -> fields |> Result.first_value(@duration_secs_keys) |> to_ms()
      milliseconds -> milliseconds
    end
  end

  defp to_ms(nil), do: nil
  defp to_ms(seconds) when is_number(seconds), do: round(seconds * 1000)
  defp to_ms(_seconds), do: nil
end
