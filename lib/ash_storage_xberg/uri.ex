defmodule AshStorageXberg.Uri do
  @moduledoc false

  # Where does an input live?
  #
  # Remote URLs (presigned S3/Azure and friends) are handed to the sidecar as
  # JSON so it downloads them itself; everything else — bare paths and `file://`
  # URLs — is streamed to it as a multipart part. `AshStorageXberg.Xberg` and
  # `AshStorageXberg.XbergApi` both route on this predicate. They used to carry
  # separate copies of the scheme regex which disagreed about `file://`, so a
  # `file://` WAV took the local transport but skipped local input
  # canonicalization.

  @scheme ~r{^[a-z][a-z0-9+.-]*://}i

  @doc """
  Whether `uri` addresses something the sidecar has to fetch over the network.

  `file://` is *not* remote: it names a path on a filesystem both sides share.
  """
  @spec remote?(String.t()) :: boolean()
  def remote?(uri) when is_binary(uri) do
    String.match?(uri, @scheme) and not String.starts_with?(uri, "file://")
  end

  @doc "The filesystem path behind a local URI, with any `file://` prefix removed."
  @spec local_path(String.t()) :: String.t()
  def local_path(uri) when is_binary(uri), do: String.replace_prefix(uri, "file://", "")
end
