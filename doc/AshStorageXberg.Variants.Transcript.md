# `AshStorageXberg.Variants.Transcript`
[🔗](https://github.com/weltenseglr/ash_storage_xberg/blob/main/lib/ash_storage_xberg/variants/transcript.ex#L1)

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

---

*Consult [api-reference.md](api-reference.md) for complete listing*
