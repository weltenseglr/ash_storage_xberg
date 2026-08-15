defmodule AshStorageXberg.Analyzers.ContentType do
  @moduledoc """
  Sniffs the real MIME type of an upload via the sidecar's dedicated
  `POST /detect` endpoint — no extraction, so this is cheap enough to run
  eagerly on every attachment.

      analyzer AshStorageXberg.Analyzers.ContentType

  Result (string-keyed, like every analyzer in this library):

      %{"detected_content_type" => "application/pdf", "content_type_verified" => true}

  `"content_type_verified"` compares the sniffed type against the type claimed
  by the client, and is therefore only present when that claim is passed in the
  analyzer options:

      analyzer {AshStorageXberg.Analyzers.ContentType, content_type: "application/pdf"}

  Comparison ignores parameters (`; charset=...`) and case. Note that xberg
  reports the canonical type for a format (e.g. `audio/wav` for a RIFF WAVE
  file), which may differ from — but not contradict — a browser-supplied type
  such as `audio/x-wav`; treat a `false` here as "worth a look", not as proof of
  an attack.

  ## Cost

  On the REST sidecar this is a header sniff via `POST /detect` — cheap enough
  to run eagerly on every attachment. The NIF backend has no such endpoint, so
  `AshStorageXberg.Xberg.detect/1` falls back to a metadata-only extraction
  there; on a NIF-only deployment prefer `analyze: :oban`.

  Analyzers can only merge into the blob's metadata, never rewrite
  `blob.content_type`; correcting the attribute itself would need an upstream
  ash_storage change.
  """

  @behaviour AshStorage.Analyzer

  alias AshStorageXberg.Mime
  alias AshStorageXberg.Xberg

  @impl true
  def accept?(_content_type), do: true

  @impl true
  def analyze(path, opts) do
    case Xberg.detect(path) do
      {:ok, %{"mime_type" => mime}} when is_binary(mime) ->
        {:ok, result(mime, expected(opts))}

      {:ok, other} ->
        {:error, {:invalid_response, "xberg detection returned #{inspect(other)}"}}

      {:error, kind, message} ->
        {:error, {kind, message}}
    end
  end

  defp result(mime, nil), do: %{"detected_content_type" => mime}

  defp result(mime, expected) do
    %{
      "detected_content_type" => mime,
      "content_type_verified" => Mime.normalize(mime) == Mime.normalize(expected)
    }
  end

  defp expected(opts) do
    Keyword.get(opts, :content_type) || Keyword.get(opts, :expected_content_type)
  end
end
