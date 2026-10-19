# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/heyvaldemar/anythingllm-traefik-letsencrypt-docker-compose/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/heyvaldemar/anythingllm-traefik-letsencrypt-docker-compose/releases/tag/v1.0.0
