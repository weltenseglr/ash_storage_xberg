# AGENTS.md

Project-specific primer for coding agents working in `ash_storage_xberg`.
Read this before editing. It complements (does not duplicate) the
[README](README.md) and [PLAN](PLAN.md).

## What this repo is

An **Elixir library**, not an application. It plugs the
[xberg](https://github.com/xberg-io/xberg) document-intelligence engine into
[ash_storage](https://github.com/ash-project/ash_storage)'s `Analyzer` and
`Variant` behaviours via a REST sidecar. No native deps in the BEAM app; all
Rust/OCR/ML work lives in `ghcr.io/xberg-io/xberg`.

There is no OTP app, no `Application.start/2`, no runtime process — only
modules that ash_storage calls back into. Don't add an `application/0`
`mod:` or `start/2`.

## Architecture in one paragraph

Every analyzer and variant calls `AshStorageXberg.Xberg` (a behaviour +
delegating API), whose implementation is selected by
`config :ash_storage_xberg, xberg: <module>` — `AshStorageXberg.XbergApi`
(REST sidecar, default) or `Xberg` (in-process NIF if `:xberg` is in deps).
The choice is **exclusive**: a deployment has one backend or the other, never
both, so anything reaching past the facade into `XbergApi` simply fails on a
NIF-only deployment. `detect/1` is an optional callback for exactly this
reason — the REST backend has `POST /detect`, the NIF does not, and the facade
falls back to a metadata-only extraction rather than letting the caller pick a
backend. Both backends return the same `{:ok, map}` /
`{:error, kind, message}` shape.
Inputs route automatically: `%{bytes: …}` and `%{uri: "/local/path"}` go
multipart; URL-scheme `%{uri: …}` (e.g. presigned S3) go as JSON so the
sidecar fetches directly from storage.

## Module map

```
lib/ash_storage_xberg.ex                    # library moduledoc + usage guide
lib/ash_storage_xberg/
├── xberg.ex              # behaviour + delegating API (the facade)
├── xberg_api.ex          # REST implementation, /detect, /health, /version, /cache/warm
├── formats.ex            # cached GET /formats list backing every accept?/1
├── errors.ex             # @moduledoc false — every failure → error-kind mapping
├── mime.ex               # @moduledoc false — the one MIME normalization
├── uri.ex                # @moduledoc false — the one local-vs-remote predicate
├── result.ex             # @moduledoc false — envelope unwrap + field readers
├── analyzers.ex          # @moduledoc false — analyzer result shaping only
├── analyzers/
│   ├── content_type.ex   # MIME sniff via POST /detect
│   ├── document.ex       # title, authors, page_count, language, created_at
│   ├── image.ex          # width, height, format, exif
│   ├── audio.ex          # duration_ms, codec, sample_rate_hz, channels, bitrate
│   └── text.ex           # text, language, word_count, ocr_used, text_truncated
├── variants.ex           # @moduledoc false — variant file writing only
└── variants/
    ├── page_thumbnail.ex # force_ocr:true + include_page_rasters:true
    ├── extracted_text.ex # .md / .txt / .json sidecar
    └── transcript.ex     # Whisper transcription (needs media-enabled sidecar)
```

`errors.ex`, `mime.ex`, `uri.ex`, `result.ex`, `analyzers.ex` and `variants.ex`
carry `@moduledoc false` on purpose — they are internal plumbing, not part of
the public surface. The four single-purpose ones exist because their logic was
previously copy-pasted across call sites and the copies drifted apart: MIME
normalization lived in four places, the URI scheme regex in two (which
disagreed about `file://`), and the envelope readers in two (which disagreed
about `word_count` and about language shapes). Add to them rather than
re-deriving.

## Conventions (do not break)

- **Go through the facade.** Analyzers and variants call
  `AshStorageXberg.Xberg` (and `AshStorageXberg.Result`, which wraps it), never
  `AshStorageXberg.XbergApi`. Backend choice is XOR; a direct `XbergApi` call
  is a REST-only feature that will fail on a NIF deployment. If the NIF has no
  equivalent, add an **optional** callback plus a facade fallback, the way
  `detect/1` does.
- **One implementation per concept.** MIME normalization is
  `AshStorageXberg.Mime.normalize/1`; local-vs-remote is
  `AshStorageXberg.Uri.remote?/1`; reading an extraction envelope is
  `AshStorageXberg.Result`. Don't inline a second copy — every one of these was
  a duplicate that drifted into a bug.
- **String keys in analyzer results.** `Analyzers.result/1` stringifies keys
  and drops `nil`s. ash_storage resolves `write_attributes:` via
  `Map.fetch(result, to_string(key))`, and metadata round-trips through the DB
  as JSON. Never return atom keys.
- **`{:error, {kind, message}}` from analyzers/variants**,
  **`{:error, kind, message}` from `Xberg`/`XbergApi`**. The two layers
  unwrap and re-shape; don't collapse them.
- **`@moduledoc` + `@doc` + `@spec` on every public function.** ex_doc is a
  first-class output; the docs site is regenerated in CI. New public surface
  without docs is a regression.
- **`accept?/1` MUST NOT raise.** It runs during attach flows.
  `Formats.supported?/1` already falls back to a built-in MIME list if the
  sidecar is unreachable or reports an empty format list — keep that property
  for any new acceptor.
- **UTF-8 truncation on a character boundary.** See
  `Analyzers.Text.truncate/2` + `trim_to_utf8_boundary/1`. Don't `binary_part`
  raw without validating.
- **No type suppressions** (`as any`, `@spec ... :: term()` to silence), no
  empty catch, no `Code.eval_string` on inputs. Trust boundary is the xberg
  response; everything reachable from the BEAM is untrusted.

## Sidecar facts

Originally verified against `ghcr.io/xberg-io/xberg:1.0.14`; re-checked
2026-08-15 against `ghcr.io/weltenseglr/xberg:omni` (reports **1.1.0**), which
is what the devcontainer and CI actually run. All still hold.

These shape real behaviour. Don't document around them — code already does.

- **No audio/media in the *stock* image.** `Analyzers.Audio` and
  `Variants.Transcript` are implemented tolerantly; they surface
  `{:error, {:unsupported_format, _}}` on it. The `:omni` build does have media
  support, which is why the `:transcript` tests can run at all.
- **Page rasters require `force_ocr: true`.** `include_page_rasters` alone
  yields nothing. `Variants.PageThumbnail` always sets both. Thumbnails are
  not free — recommend `generate: :oban`.
- **`target_dpi` / `max_image_dimension` are accepted but ignored.** PDF pages
  render at the fixed OCR DPI of 150 — requesting 72 and 300 for the same A4
  page both return 1241×1754. Trust returned `width`/`height`, don't compute
  from `:dpi`.
- **`GET /formats` reports 94 MIME types on 1.1.0**, and does *not* include
  `audio/x-wav`, `text/xml` or ODF Graphics. `Formats.@fallback` must stay a
  strict subset of it: a fallback that over-claims makes `accept?/1` accept
  work extraction then rejects.
- **SSRF policy denies private/link-local by default.** For dev MinIO, override
  per request via `config: %{url: %{crawl: %{ssrf: %{deny_private: false}}}}`.
- **Batches must be all-remote or all-local.** Mixing returns
  `{:error, :validation_error, …}` because transports differ.

## Verification commands

All commands run inside the devcontainer — host has no Erlang/Elixir.

```bash
devcontainer up --workspace-folder <repo>      # bring up app + xberg sidecar
devcontainer exec --workspace-folder <repo> bash -lc '<cmd>'

  mix compile                                  # warnings from upstream ash_storage are normal
  mix test                                     # unit tests, network stubbed via Req.Test
  XBERG_URL=http://127.0.0.1:8000 mix test --include integration
  XBERG_URL=http://127.0.0.1:8000 mix test --include transcript  # needs media build + model
  mix docs                                     # → doc/index.html, .epub, llms.txt
  mix format --check-formatted
  mix credo 2>/dev/null || true                # not in deps yet; do not add unprompted
```

`:integration` and `:transcript` are excluded by default in
`test/test_helper.exs`.

> Use `127.0.0.1`, not `localhost`, when pointing `XBERG_URL` at a published
> port on a rootless podman host — IPv6 `::1` resolution will fail.

## Things explicitly out of scope

- Resizing images or grabbing video frames — xberg extracts, it does not
  transform. Use `image` / `ffmpex` next to this library.
- Rewriting `blob.content_type` from analyzers — analyzers can only merge into
  `metadata`. Correcting the attribute itself needs an upstream ash_storage
  change; document it as such, don't try to hack around it.
- An in-app process supervisor for the sidecar — the sidecar is operated
  (compose, k8s sidecar, GitHub Actions `services:`), not embedded.

## Devcontainer gotcha

`.devcontainer/docker-compose.yml` pins a hexpm/elixir trixie-slim tag.
hexpm **retires dated tags** when the underlying Debian image is republished,
so a pinned date like `trixie-20250630` can disappear with a 404. Pick the
current latest matching `<elixir>-erlang-<otp>-debian-trixie-<date>-slim` and
bump in lockstep. The `ponytail:` comment at the tag marks this.

## When editing

- Options or return keys changed → the moduledoc of the affected module is the
  source of truth for users; update it. The README only lists modules with
  one-liners — keep those in sync, but no option detail there.
- Sidecar behaviour changed (image variants, format list, presigned flow,
  limitations) → update `guides/sidecar.md`, the operational reference.
- mix.exs `docs/0` `groups_for_modules` → add any new public module to the
  right group so it doesn't land under "Uncategorized"; new guide files go
  into `extras`/`groups_for_extras`.
- CHANGELOG.md `Unreleased` → note any user-visible addition/change/fix.
- The README stays a quick start: pitch, install, one usage example, links.
  Deep reference lives in moduledocs and guides — don't grow it back.

## Useful entry points when investigating

| Question | Start at |
|---|---|
| How does an input reach the sidecar? | `AshStorageXberg.XbergApi.extract/1` → `remote?/1`, `file_part/1` |
| Why is X key missing from `blob.metadata`? | The relevant `Analyzers.*` module + `Analyzers.result/1` (nil values dropped) |
| Why does my analyzer always reject? | `Formats.supported?/1` and `AshStorageXberg.Xberg.list_supported_formats/0` |
| Page raster is empty? | `Variants.PageThumbnail` — sidecar needs `force_ocr: true`, build needs an office renderer |
| Presigned URL flow / SSRF? | `XbergApi.normalize_input/1` + `AshStorageXberg.Uri.remote?/1` |
| Why does an analyzer work on REST but not the NIF? | It bypassed the facade — see "Go through the facade" above |
