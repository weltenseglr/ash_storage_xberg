defmodule AshStorageXberg.Mime do
  @moduledoc false

  # The one MIME normalization in this library.
  #
  # Content types reach `accept?/1` from three directions — a browser-supplied
  # upload header, ash_storage's `blob.content_type` column, and the sidecar's
  # own `GET /formats` list — so they arrive with parameters (`; charset=utf-8`)
  # and arbitrary casing. Every acceptor and `AshStorageXberg.Formats` compares
  # against the value this returns.

  @doc "The bare MIME type: parameters stripped, trimmed, downcased."
  @spec normalize(String.t()) :: String.t()
  def normalize(content_type) when is_binary(content_type) do
    content_type |> String.split(";") |> hd() |> String.trim() |> String.downcase()
  end
end
