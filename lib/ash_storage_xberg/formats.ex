defmodule AshStorageXberg.Formats do
  @moduledoc """
  Supported-format lookup for `accept?/1` callbacks, backed by the sidecar's
  `GET /formats` endpoint.

  The format list is fetched once and cached in `:persistent_term`. If the
  sidecar is unreachable when the first lookup happens — or reports an empty
  format list — a conservative built-in list of core MIME types is used instead
  (and a warning is logged), so `accept?/1` never raises during attach flows.
  """

  require Logger

  @key {__MODULE__, :mime_types}

  # Conservative fallback when the sidecar can't be reached: formats every xberg
  # build supports. Keep this a strict *subset* of what a real sidecar reports —
  # a fallback that over-claims makes `accept?/1` accept work that extraction
  # then rejects. (`text/xml` and `audio/x-wav` were listed here but are not in
  # the live `GET /formats` response; xberg reports `application/xml` and
  # `audio/wav` for those.)
  @fallback ~w(
    application/pdf
    application/vnd.openxmlformats-officedocument.wordprocessingml.document
    application/vnd.openxmlformats-officedocument.spreadsheetml.sheet
    application/vnd.openxmlformats-officedocument.presentationml.presentation
    application/vnd.oasis.opendocument.text
    application/vnd.oasis.opendocument.spreadsheet
    application/vnd.oasis.opendocument.presentation
    application/msword
    application/vnd.ms-excel
    application/vnd.ms-powerpoint
    application/epub+zip
    application/zip
    application/json
    application/xml
    text/plain
    text/markdown
    text/html
    text/csv
    image/png
    image/jpeg
    image/gif
    image/webp
    image/tiff
    image/bmp
    audio/mpeg
    audio/wav
    audio/mp4
    video/mp4
  )

  @doc "Whether the given MIME type is extractable."
  @spec supported?(String.t() | nil) :: boolean()
  def supported?(nil), do: false

  def supported?(content_type) when is_binary(content_type) do
    MapSet.member?(mime_types(), AshStorageXberg.Mime.normalize(content_type))
  end

  @doc "All supported MIME types, as a set."
  @spec mime_types() :: MapSet.t(String.t())
  def mime_types do
    # Check-then-act race on first use: concurrent callers can each miss the key,
    # each run load/0 and each write it. Accepted without locking — load/0 is
    # idempotent, so the worst case is a duplicate fetch and one extra
    # :persistent_term write, never a wrong set.
    case :persistent_term.get(@key, nil) do
      nil ->
        set = load()
        :persistent_term.put(@key, set)
        set

      set ->
        set
    end
  end

  @doc "Drop the cached format list (e.g. after pointing at a different sidecar)."
  @spec reset() :: :ok
  def reset do
    # `erase/1` returns false when the key was never cached; that is still a
    # successful reset, so don't let it leak out as the return value.
    _ = :persistent_term.erase(@key)
    :ok
  end

  defp load do
    formats = AshStorageXberg.Xberg.list_supported_formats()
    set = MapSet.new(formats, fn %{"mime_type" => mime} -> String.downcase(mime) end)

    if Enum.empty?(set) do
      # An empty list would be cached permanently and make every accept?/1
      # reject everything. A backend that claims to support nothing is as
      # unusable as one that is down, so treat it the same way.
      fallback("the backend reported no supported formats")
    else
      Logger.info(fn ->
        "AshStorageXberg: the xberg sidecar reports #{MapSet.size(set)} extractable MIME types"
      end)

      Logger.debug(fn ->
        "AshStorageXberg: extractable MIME types: #{set |> Enum.sort() |> Enum.join(", ")}"
      end)

      set
    end
  rescue
    error -> fallback(Exception.message(error))
  catch
    # A backend can exit rather than raise (a NIF crash, a caller-linked
    # transport process going down). `accept?/1` still must not blow up.
    :exit, reason -> fallback("exited: #{inspect(reason)}")
  end

  defp fallback(reason) do
    Logger.warning(
      "AshStorageXberg: could not load formats from the xberg backend " <>
        "(#{reason}); using the built-in fallback list of " <>
        "#{length(@fallback)} MIME types"
    )

    MapSet.new(@fallback)
  end
end
