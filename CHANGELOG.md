# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

_(no unreleased changes yet)_

## [1.0.3] - 2026-10-22

### Changed

- **`ollama/ollama:0.40.7` moved to `ollama/ollama:0.40.8`.** The freshness check reported the lag; the deploy job booted the stack on the new image before this landed.

## [1.0.2] - 2026-10-21

### Changed

- **`ollama/ollama:0.40.6` moved to `ollama/ollama:0.40.7`.** The freshness check reported the lag; the deploy job booted the stack on the new image before this landed.

### Security

- **`traefik:3.7` was rebuilt upstream**; the pin moved from `sha256:0f6150202bc1…` to `sha256:6d3e069ee484…`. Same version, same tag, a rebuilt base image — the usual shape of a security fix in a base layer.

## [1.0.1] - 2026-10-20

### Changed

- **The README links AnythingLLM's own documentation** for the password default (Security and Access) and API keys (API Access & Keys), so the password requirement reads as what it is: a documented default made safe, not a flaw found around the documentation.

### Fixed

- **The data archive is read back before it is called a backup.** The loop renamed the `.partial` archive after `gzip -t`, which tests the compression and nothing inside it: a tar stream tar cannot read, compressed without error, passes. It now lists the whole archive with `tar -tzf` first, and one that does not list is kept as `.failed`. The fleet's conformance rule asks for this read-back and had not been reading this repository's backup loop at all: it did not recognise `tar -C … -zcpf`.
- **What a restore sets aside stays inside the volume.** Here that is `tmp`. Moved through the backups container's `/tmp`, each kept path was copied into the container's own layer and out again; inside the volume a move is a rename and nothing is copied, however large the kept paths are.

## [1.0.0] - 2026-10-19

### Added

- **AnythingLLM behind Traefik, answering from your documents on your own host.** `mintplexlabs/anythingllm` 1.18.0, Ollama 0.40.6 and Traefik 3.7, pinned by digest. Ollama is the model (default `llama3.2:3b`), AnythingLLM's built-in embedder makes the vectors and LanceDB on the storage volume searches them.
- **A password the stack cannot start without.** `ANYTHINGLLM_PASSWORD` and `ANYTHINGLLM_JWT_SECRET` are required. Measured on 1.18.0 with neither set, a request with no credentials at all is handed a working API key.
- **Ollama on an internal network only.** Its API has no authentication; nothing publishes it, and CI fails if anything answers on the host's port 11434.
- **AnythingLLM with every Linux capability dropped, `SYS_ADMIN` included**, where its own Docker guide adds `SYS_ADMIN` for the Chromium that reads web links. Measured without it: Chromium does not start, AnythingLLM falls back to a plain fetch, a static page is imported in full and a page built by JavaScript comes back empty. The README says how to add it back on purpose.
- **Backups of the whole instance**: a consistent online copy of the SQLite database and an archive of the storage volume (the LanceDB vector store, the documents, the embedder's model, the signing keys), with `anythingllm-restore-data.sh` clearing the volume before it unpacks, so a workspace made after the backup does not survive the restore.
- **`tests/e2e-rag.sh`**, through Traefik: no API key and no workspace list without the password, a wrong password refused, a document embedded and found by a vector search for a phrase only it holds, and a question about it answered by the model with that document as the source.
- **`tests/e2e-backup-restore.sh`**: a backup set produced and valid, a failed cycle detected, and a restore after which the post-backup workspace is gone, the RAG workspace and its vectors are back, and the API key from the restored database works.
- **`update.sh`**: moves between release tags, refuses to cross a major version unattended, refuses to run over local changes, names any new required variable before anything has moved.

[Unreleased]: https://github.com/heyvaldemar/anythingllm-traefik-letsencrypt-docker-compose/compare/v1.0.3...HEAD
[1.0.3]: https://github.com/heyvaldemar/anythingllm-traefik-letsencrypt-docker-compose/compare/v1.0.2...v1.0.3
[1.0.2]: https://github.com/heyvaldemar/anythingllm-traefik-letsencrypt-docker-compose/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/heyvaldemar/anythingllm-traefik-letsencrypt-docker-compose/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/heyvaldemar/anythingllm-traefik-letsencrypt-docker-compose/releases/tag/v1.0.0
