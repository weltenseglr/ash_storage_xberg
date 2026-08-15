# `AshStorageXberg.Analyzers.ContentType`
[🔗](https://github.com/weltenseglr/ash_storage_xberg/blob/main/lib/ash_storage_xberg/analyzers/content_type.ex#L1)

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

---

*Consult [api-reference.md](api-reference.md) for complete listing*
