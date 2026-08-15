# Changelog

All notable changes to this project will be documented in this file. The format
is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `AshStorageXberg.Xberg` behaviour mirroring the `:xberg` hex NIF API, so the
  REST sidecar (`AshStorageXberg.XbergApi`, the default) and the in-process NIF
  are exchangeable via `config :ash_storage_xberg, xberg: …`. `detect/1` is an
  optional callback: backends without a sniffing endpoint fall back to a
  metadata-only extraction.
- `AshStorageXberg.XbergApi` REST client with multipart upload for local files
  and bytes, presigned-URL JSON transport (the sidecar downloads directly from
  storage), and `/detect`, `/health`, `/version`, `/cache/warm` helpers. Only
  read-only endpoints retry; `POST /extract` is never retried, so a failed OCR
  or Whisper pass is not silently re-run.
- Analyzers: `ContentType`, `Document`, `Image`, `Audio`, `Text`. Results are
  string-keyed with `nil` values dropped, matching ash_storage's
  `write_attributes` lookup and the database round-trip of `blob.metadata`.
  `Analyzers.Text` truncates to `:max_bytes` on a UTF-8 character boundary.
- Variants: `PageThumbnail`, `ExtractedText`, `Transcript` (the latter needs a
  media-enabled xberg build such as `ghcr.io/weltenseglr/xberg:omni`).
- `AshStorageXberg.Formats` — cached `GET /formats` lookup behind every
  `accept?/1`, with a conservative built-in fallback used when the backend is
  unreachable, crashes, or reports an empty format list, so `accept?/1` never
  raises during attach flows.
- Sidecar failures map onto a finite set of error-kind atoms; unrecognized
  error types become `:unknown_error` rather than interning response-controlled
  strings as BEAM atoms.
- Devcontainer compose and GitHub Actions workflow running the xberg sidecar
  next to the test suite.
- `mix docs` configuration with grouped modules, README extra, and `llms.txt`
  output for LLM agents.

[Unreleased]: https://github.com/weltenseglr/ash_storage_xberg/commits/main
