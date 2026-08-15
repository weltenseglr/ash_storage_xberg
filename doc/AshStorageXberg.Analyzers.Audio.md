# `AshStorageXberg.Analyzers.Audio`
[🔗](https://github.com/weltenseglr/ash_storage_xberg/blob/main/lib/ash_storage_xberg/analyzers/audio.ex#L1)

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

---

*Consult [api-reference.md](api-reference.md) for complete listing*
