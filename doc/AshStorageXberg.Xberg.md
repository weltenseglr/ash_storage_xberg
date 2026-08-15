# `AshStorageXberg.Xberg`
[🔗](https://github.com/weltenseglr/ash_storage_xberg/blob/main/lib/ash_storage_xberg/xberg.ex#L1)

The exchangeable xberg interface.

Mirrors the public extraction API of the `Xberg` module from the `:xberg` hex
package (the Rustler NIF binding), so that the in-process NIF and the REST
sidecar client can be swapped without touching call sites:

  * `extract/1` — `Xberg.extract(input: ..., config: ...)`
  * `extract_batch/1` — `Xberg.extract_batch(inputs: ..., config: ...)`
  * `list_supported_formats/0`

plus `detect/1`, which is optional: backends that have a cheap MIME-sniffing
endpoint implement it, and for those that do not the facade derives the type
from a metadata-only extraction instead. That keeps
`AshStorageXberg.Analyzers.ContentType` working on either backend — the
choice of backend is exclusive, so an analyzer that reached past this facade
into the REST client would simply fail on a NIF-only deployment.

Inputs and configs are accepted in the same shapes the NIF accepts: an already
JSON-encoded binary, or any Jason-encodable term (map, keyword-built struct such
as `Xberg.ExtractInput`/`Xberg.ExtractionConfig` when the `:xberg` package is
present). Returns are `{:ok, result_map}` or `{:error, kind, message}` — the
NIF's three-element error tuple.

## Choosing the implementation

    # default — REST sidecar (ghcr.io/xberg-io/xberg, `xberg serve`)
    config :ash_storage_xberg, xberg: AshStorageXberg.XbergApi

    # in-process NIF — add {:xberg, "~> 1.0"} to deps
    config :ash_storage_xberg, xberg: Xberg

Call sites use this module's delegating functions:

    AshStorageXberg.Xberg.extract(
      input: %{uri: "/tmp/upload/document.pdf"},
      config: %{output_format: "markdown"}
    )

# `detect_input`

```elixir
@type detect_input() :: String.t() | {binary(), String.t()}
```

What `detect/1` accepts: a local path, or in-memory bytes with a filename.

# `error`

```elixir
@type error() :: {:error, atom(), String.t()}
```

The NIF-style error tuple: kind atom plus human-readable message.

# `legacy_error`

```elixir
@type legacy_error() :: {:error, String.t()}
```

The two-element error some NIF builds return instead of the three-element one.
`extract/1` and `extract_batch/1` classify its message and normalize it to
`t:error/0`, so call sites only ever see the three-element shape.

# `detect`
*optional* 

```elixir
@callback detect(input :: detect_input()) :: {:ok, map()} | error() | legacy_error()
```

Detect an input's MIME type without extracting it.

Optional: implement it when the backend has a dedicated sniffing endpoint.
`AshStorageXberg.Xberg.detect/1` falls back to a metadata-only extraction for
backends that do not.

# `extract`

```elixir
@callback extract(opts :: keyword()) :: {:ok, map()} | error() | legacy_error()
```

Extract content from a single bytes or URI input.

# `extract_batch`

```elixir
@callback extract_batch(opts :: keyword()) :: {:ok, map()} | error() | legacy_error()
```

Extract content from multiple bytes or URI inputs.

# `list_supported_formats`

```elixir
@callback list_supported_formats() :: [map()]
```

List all supported document formats.

# `detect`

```elixir
@spec detect(detect_input()) :: {:ok, map()} | error()
```

Detect the MIME type of `input`, returning `{:ok, %{"mime_type" => type}}`.

Uses the backend's own `c:detect/1` when it has one — the REST sidecar's
`POST /detect` is a cheap header sniff. Backends without one (the NIF) fall
back to a metadata-only extraction, which is correct but costs a full parse;
prefer `analyze: :oban` on `AshStorageXberg.Analyzers.ContentType` there.

# `extract`

```elixir
@spec extract(keyword()) :: {:ok, map()} | error()
```

# `extract_batch`

```elixir
@spec extract_batch(keyword()) :: {:ok, map()} | error()
```

# `impl`

```elixir
@spec impl() :: module()
```

The configured implementation module.

# `list_supported_formats`

```elixir
@spec list_supported_formats() :: [map()]
```

---

*Consult [api-reference.md](api-reference.md) for complete listing*
