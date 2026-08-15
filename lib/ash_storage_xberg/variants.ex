defmodule AshStorageXberg.Variants do
  @moduledoc false

  # Variant-specific plumbing for the `AshStorage.Variant` implementations under
  # `AshStorageXberg.Variants.*`.
  #
  # Everything about *reading* an xberg result — running the extraction,
  # unwrapping the envelope, normalizing errors — lives in
  # `AshStorageXberg.Result`, shared with the analyzers. What is left here is the
  # one thing only variants do: writing the derived file, and building the
  # request configs that produce it.

  @type error :: {:error, {atom(), String.t()}}

  @doc "Write variant output, converting posix errors to the variant error shape."
  @spec write(String.t(), iodata()) :: :ok | error()
  def write(dest_path, content) do
    case File.write(dest_path, content) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error,
         {:write_failed,
          "could not write #{dest_path}: #{List.to_string(:file.format_error(reason))}"}}
    end
  end

  @doc "Put `key` only when `value` is not `nil` (config maps stay minimal)."
  @spec put_unless_nil(map(), atom(), term()) :: map()
  def put_unless_nil(map, _key, nil), do: map
  def put_unless_nil(map, key, value), do: Map.put(map, key, value)
end
