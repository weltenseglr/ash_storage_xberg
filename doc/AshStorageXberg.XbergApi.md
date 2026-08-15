# `AshStorageXberg.XbergApi`
[🔗](https://github.com/weltenseglr/ash_storage_xberg/blob/main/lib/ash_storage_xberg/xberg_api.ex#L1)

REST implementation of `AshStorageXberg.Xberg`, backed by an xberg sidecar
(`ghcr.io/xberg-io/xberg`, `xberg serve`).

Signature- and return-compatible with the `Xberg` NIF module from the `:xberg`
hex package, so the two can be exchanged via configuration — see
`AshStorageXberg.Xberg`.

## Configuration

    config :ash_storage_xberg,
      base_url: "http://localhost:8000",   # or XBERG_URL env var
      receive_timeout: 120_000,
      req_options: []                       # merged into every request (e.g. Req.Test plug)

## Input translation

The NIF reads inputs in place; the sidecar receives them over HTTP. Inputs are
translated as follows:

  * `%{bytes: binary}` — uploaded as a multipart file part (with `filename`
    and `mime_type` when given)
  * `%{uri: path}` pointing at a local file — streamed from disk as a
    multipart file part
  * `%{uri: url}` with a URL scheme (e.g. a presigned S3/Azure URL) — sent as
    a JSON request so the **sidecar downloads the file directly from the
    bucket**; the bytes never pass through the application. Note the sidecar's
    SSRF policy denies private/link-local hosts by default — for dev setups
    fetching from non-public endpoints, override via
    `config: %{url: %{crawl: %{ssrf: %{deny_private: false}}}}`.

A batch must be all-remote or all-local/bytes; mixing both in one
`extract_batch/1` call returns a validation error (they use different
transports). Per-input `config` (the NIF's `FileExtractionConfig`) rides along
in remote-URI requests; for multipart requests it is merged into the
request-level config on single `extract/1` calls and rejected in batches
(multipart cannot address configs to individual files).

# `cache_warm`

```elixir
@spec cache_warm(map()) :: {:ok, map()} | AshStorageXberg.Xberg.error()
```

Pre-download models into the sidecar cache (`POST /cache/warm`).

# `detect`

```elixir
@spec detect(AshStorageXberg.Xberg.detect_input()) ::
  {:ok, map()} | AshStorageXberg.Xberg.error()
```

Detect the MIME type of a file (local path or `{bytes, filename}`) via the
sidecar's dedicated `POST /detect` endpoint, without running extraction.

This is the REST backend's implementation of the optional `c:AshStorageXberg.Xberg.detect/1`
callback. Prefer `AshStorageXberg.Xberg.detect/1` from library code so the
call keeps working on a NIF-only deployment.

# `health`

```elixir
@spec health() :: {:ok, map()} | AshStorageXberg.Xberg.error()
```

Sidecar health status (`GET /health`).

# `version`

```elixir
@spec version() :: {:ok, map()} | AshStorageXberg.Xberg.error()
```

Sidecar version (`GET /version`).

---

*Consult [api-reference.md](api-reference.md) for complete listing*
