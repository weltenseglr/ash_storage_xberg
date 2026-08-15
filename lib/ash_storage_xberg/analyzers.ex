defmodule AshStorageXberg.Analyzers do
  @moduledoc false

  # Analyzer-specific plumbing for the `AshStorage.Analyzer` implementations in
  # `AshStorageXberg.Analyzers.*`.
  #
  # Everything about *reading* an xberg result — running the extraction,
  # unwrapping the envelope, normalizing errors, pulling metadata out — lives in
  # `AshStorageXberg.Result`, shared with the variants. What is left here is the
  # one thing only analyzers do: shaping the result map ash_storage merges into
  # `blob.metadata`.

  @doc """
  Build an analyzer result: string keys, and no entry for a `nil` value
  (analyzers never write nil metadata).

  String keys are load-bearing. ash_storage resolves `write_attributes:` with
  `Map.fetch(result, to_string(key))`, and metadata round-trips through the
  database as JSON, so it comes back string-keyed regardless.
  """
  @spec result(Enumerable.t()) :: map()
  def result(pairs) do
    for {key, value} <- pairs, not is_nil(value), into: %{}, do: {to_string(key), value}
  end
end
