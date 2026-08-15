defmodule AshStorageXberg.Errors do
  @moduledoc false

  # Every mapping from an xberg failure to one of this library's error kinds.
  #
  # There are two routes in, because the backends report failures differently:
  # the REST sidecar and the envelope's per-file `errors` carry a structured
  # `error_type` (`kind/2`, `kind/3`), while some NIF builds return only a
  # human-readable message (`from_message/1`). Both live here so the atom set
  # stays finite and is maintained in one place.

  @error_kinds %{
    "ValidationError" => :validation_error,
    "validation_error" => :validation_error,
    "ParsingError" => :parsing_error,
    "parsing_error" => :parsing_error,
    "OcrError" => :ocr_error,
    "ocr_error" => :ocr_error,
    "TimeoutError" => :timeout,
    "timeout" => :timeout,
    "TranscriptionError" => :transcription_error,
    "transcription_error" => :transcription_error,
    "InternalError" => :internal_error,
    "internal_error" => :internal_error,
    "UnsupportedFormat" => :unsupported_format,
    "unsupported_format" => :unsupported_format
  }

  @doc "Classify a structured `error_type`, falling back to `fallback`."
  @spec kind(term(), atom()) :: atom()
  def kind(type, fallback) when is_binary(type), do: Map.get(@error_kinds, type, fallback)
  def kind(_type, fallback), do: fallback

  @doc """
  Classify a structured `error_type`, consulting `message` where the type alone
  is not specific enough.

  Deliberately conservative: an unrecognized `error_type` yields `fallback`
  rather than being sniffed out of the message, so an attacker-controlled
  message cannot widen the atom set.
  """
  @spec kind(term(), term(), atom()) :: atom()
  def kind("other", "Transcription error:" <> _rest, _fallback), do: :transcription_error
  def kind(type, _message, fallback), do: kind(type, fallback)

  @doc """
  Classify a bare error message, for backends that report no structured type.

  The prefixes match the messages the NIF formats its error variants with.
  """
  @spec from_message(String.t()) :: atom()
  def from_message("Unsupported format" <> _rest), do: :unsupported_format
  def from_message("Validation" <> _rest), do: :validation_error
  def from_message("Parsing" <> _rest), do: :parsing_error
  def from_message("OCR" <> _rest), do: :ocr_error
  def from_message("Transcription error" <> _rest), do: :transcription_error

  def from_message(message) when is_binary(message) do
    if String.contains?(String.downcase(message), ["timeout", "timed out"]),
      do: :timeout,
      else: :extraction_error
  end
end
