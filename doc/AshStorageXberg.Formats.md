# `AshStorageXberg.Formats`
[🔗](https://github.com/weltenseglr/ash_storage_xberg/blob/main/lib/ash_storage_xberg/formats.ex#L1)

Supported-format lookup for `accept?/1` callbacks, backed by the sidecar's
`GET /formats` endpoint.

The format list is fetched once and cached in `:persistent_term`. If the
sidecar is unreachable when the first lookup happens — or reports an empty
format list — a conservative built-in list of core MIME types is used instead
(and a warning is logged), so `accept?/1` never raises during attach flows.

# `mime_types`

```elixir
@spec mime_types() :: MapSet.t(String.t())
```

All supported MIME types, as a set.

# `reset`

```elixir
@spec reset() :: :ok
```

Drop the cached format list (e.g. after pointing at a different sidecar).

# `supported?`

```elixir
@spec supported?(String.t() | nil) :: boolean()
```

Whether the given MIME type is extractable.

---

*Consult [api-reference.md](api-reference.md) for complete listing*
