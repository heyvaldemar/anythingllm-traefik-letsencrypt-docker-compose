# AnythingLLM + Ollama + Traefik + Let's Encrypt on Docker Compose

[![Deployment Verification](https://github.com/heyvaldemar/anythingllm-traefik-letsencrypt-docker-compose/actions/workflows/deployment-verification.yml/badge.svg?branch=main)](https://github.com/heyvaldemar/anythingllm-traefik-letsencrypt-docker-compose/actions/workflows/deployment-verification.yml?query=branch%3Amain)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

## Contents

- [What this is](#what-this-is)
- [Three decisions the defaults make for you](#three-decisions-the-defaults-make-for-you)
- [Prerequisites](#prerequisites)
- [Getting started](#getting-started)
- [What leaves the host](#what-leaves-the-host)
- [Supply chain trust](#supply-chain-trust)
- [Production checklist](#production-checklist)
- [Unattended updates](#unattended-updates)
- [Backups](#backups)
- [Container hardening](#container-hardening)
- [Testing](#testing)
- [Security notes](#security-notes)
- [About the maintainer](#about-the-maintainer)

## What this is

[AnythingLLM](https://github.com/Mintplex-Labs/anything-llm) answers questions from your own documents: you upload them, it splits and embeds them, and a question is answered by a language model from the passages it finds, with those passages named as the sources. This repository runs it on one host behind Traefik with automatic Let's Encrypt TLS, with [Ollama](https://ollama.com) as the model, AnythingLLM's built-in embedder for the vectors and LanceDB on the storage volume for search. The documents, the vectors, the questions and the answers stay on the host.

A fresh AnythingLLM with no password hands an API key to anyone who asks for one. Behind a public hostname, that is anyone at all. This template does not start without a password.

That is the documented single-user default, not a flaw found around the documentation: AnythingLLM's [Security and Access](https://docs.anythingllm.com/features/security-and-access) page has the password as a switch that starts off ("Password Protect Instance"), and its [API Access & Keys](https://docs.anythingllm.com/features/api) page warns that anyone holding a key can use the API. What neither page says is what the measurement below shows: with the switch off, a request carrying no credentials is handed a key.

## Three decisions the defaults make for you

**A password, always.** `ANYTHINGLLM_PASSWORD` and `ANYTHINGLLM_JWT_SECRET` are required: `docker compose up` stops and names the missing one. Measured on 1.18.0 with no password set, `POST /api/system/generate-api-key` answers 200 with a working key to a request that carries no credentials at all. With one, the same request is a 401, and so is listing the workspaces. CI checks both refusals, and that a wrong password is refused, on every run.

**Ollama is never published.** Ollama's API has no authentication. Published, its port is your machine's compute and every model on it, for whoever finds it. Here Ollama sits on an internal network that only AnythingLLM shares, and CI fails if anything answers on the host's port 11434. The [Ollama template](https://github.com/heyvaldemar/ollama-traefik-letsencrypt-docker-compose) this one descends from publishes that port; this one does not.

**No `SYS_ADMIN`.** AnythingLLM's own Docker guide adds `SYS_ADMIN`, so the Chromium it uses to read web links can start its sandbox. Here the AnythingLLM container drops every Linux capability. See [Reading web links](#reading-web-links) for what that costs.

### Reading web links

Without `SYS_ADMIN`, Chromium refuses to start ("No usable sandbox"), and AnythingLLM falls back to a plain fetch of the page. Measured on 1.18.0: a static page (`https://example.com`) is imported in full, 26 words. A page that only exists once its JavaScript has run comes back empty. Uploaded files, which is what most people embed, do not use Chromium at all.

`SYS_ADMIN` is most of root. If you need JavaScript pages, add it to the `anythingllm` service on purpose, knowing what it grants:

```yaml
    cap_add:
      - SYS_ADMIN
```

## Prerequisites

- Docker Engine with Compose v2.5 or newer.
- A host with at least 4 GB of RAM for the default 3B chat model, more for larger ones. A GPU is optional (see the commented block on the `ollama` service).
- A DNS record for `ANYTHINGLLM_HOSTNAME` pointing at the host, and ports 80 and 443 reachable for Let's Encrypt's TLS challenge.

## Getting started

```bash
# 1. Clone
git clone https://github.com/heyvaldemar/anythingllm-traefik-letsencrypt-docker-compose.git
cd anythingllm-traefik-letsencrypt-docker-compose

# 2. Create the two Docker networks the stack expects
docker network create traefik-network
docker network create anythingllm-network

# 3. Copy the environment template and fill in required values
cp .env.example .env
# ^ Required: ANYTHINGLLM_HOSTNAME, ANYTHINGLLM_PASSWORD, ANYTHINGLLM_JWT_SECRET,
#   TRAEFIK_HOSTNAME, TRAEFIK_ACME_EMAIL, TRAEFIK_BASIC_AUTH.
#   See .env.example for generation commands.

# 4. Deploy
docker compose -f anythingllm-traefik-letsencrypt-docker-compose.yml -p anythingllm up -d
```

### What success looks like

```bash
# Every service healthy or up:
docker compose -p anythingllm ps

# AnythingLLM answers through Traefik:
curl -s https://anythingllm.example.com/api/ping
# Expected: {"online":true}

# Ollama pulled the chat model (about 2 GB for the default llama3.2:3b):
docker compose -p anythingllm logs ollama | grep "All models installed"
```

Then open `https://anythingllm.example.com`, sign in with the password, create a workspace and upload a document.

## What leaves the host

The documents, their vectors, the questions and the answers do not. Some requests do, and you should know which:

- **Ollama pulls the chat model** from the Ollama registry on every start (`OLLAMA_INSTALL_MODELS`, set it empty to manage models yourself).
- **The built-in embedder downloads its model once** (`Xenova/all-MiniLM-L6-v2`, 24 MB in the storage volume on 1.18.0) from Hugging Face, the first time a document is embedded. It is kept in the storage volume and backed up with it.
- **AnythingLLM fetches a model catalogue and a price list** when it starts, observed in its logs on 1.18.0. They carry no document content.
- **Telemetry is off** (`DISABLE_TELEMETRY=true` is set in the compose file).

## Supply chain trust

This repository is a deployment template, not a custom Docker image. It orchestrates four upstream images:

- [`traefik`](https://hub.docker.com/_/traefik): reverse proxy, Docker Hub official image
- [`ollama/ollama`](https://hub.docker.com/r/ollama/ollama): Ollama upstream
- [`mintplexlabs/anythingllm`](https://hub.docker.com/r/mintplexlabs/anythingllm): AnythingLLM upstream
- [`python`](https://hub.docker.com/_/python) (alpine): the backups loop, Docker Hub official image

The first three are pinned to `tag@sha256:<digest>` as interpolation defaults in the compose file's `x-images` block, and the backups image by digest on its service. Compose pulls by digest, not by tag, and `git pull` alone delivers the version combination this repository has tested, because the pins live in the tracked compose file rather than in your `.env`. `<PREFIX>_IMAGE_VERSION` in `.env` swaps only the version of one image and leaves every other pin as tested; `<PREFIX>_IMAGE_TAG` replaces the whole reference, digest included. Nested defaults need Docker Compose v2.5 or newer.

The daily Pin Freshness workflow re-resolves each pinned tag against its registry and compares the pinned AnythingLLM, Ollama and Traefik versions against the latest upstream releases: any drift fails the run and notifies the maintainer. GitHub Actions are pinned by commit SHA; Dependabot keeps those fresh.

### Verify what you deploy

Every release carries three files made on GitHub's runner with a short-lived identity and no stored key: `anythingllm-traefik-letsencrypt-docker-compose-<tag>.tar.gz`, a `git archive` of exactly the tree the tag points at; `anythingllm-traefik-letsencrypt-docker-compose-<tag>.tar.gz.sigstore.json`, a keyless [Sigstore](https://www.sigstore.dev/) signature over it; and `anythingllm-traefik-letsencrypt-docker-compose-<tag>.intoto.jsonl`, [SLSA](https://slsa.dev/) build provenance from the SLSA generator. To check them with nothing from this repository trusted:

```bash
cosign verify-blob anythingllm-traefik-letsencrypt-docker-compose-<tag>.tar.gz \
  --bundle anythingllm-traefik-letsencrypt-docker-compose-<tag>.tar.gz.sigstore.json \
  --certificate-identity-regexp '^https://github.com/heyvaldemar/anythingllm-traefik-letsencrypt-docker-compose/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com

slsa-verifier verify-artifact anythingllm-traefik-letsencrypt-docker-compose-<tag>.tar.gz \
  --provenance-path anythingllm-traefik-letsencrypt-docker-compose-<tag>.intoto.jsonl \
  --source-uri github.com/heyvaldemar/anythingllm-traefik-letsencrypt-docker-compose \
  --source-tag <tag>
```

The workflow that makes them is [`release-assets.yml`](.github/workflows/release-assets.yml).

## Production checklist

- [ ] **A long password and a separate signing secret.** Generate both (commands in `.env.example`). Anyone with the password has every document in the instance.
- [ ] **Multi-user mode if more than one person signs in.** One password is one identity. AnythingLLM's multi-user mode gives each person an account and roles; turn it on in its settings before sharing the URL.
- [ ] **Size the chat model to the host's RAM.** A model that does not fit forces swapping or an OOM kill. `ANYTHINGLLM_CHAT_MODEL` must be one of the models in `OLLAMA_INSTALL_MODELS`.
- [ ] **Strong Traefik dashboard hash.** Regenerate `TRAEFIK_BASIC_AUTH` per deployment.
- [ ] **Verify Let's Encrypt certificate issuance** in the Traefik logs on first start.
- [ ] **Keep the backups as carefully as the `.env`.** They hold the instance's API keys and signing keys (see [Backups](#backups)).

## Unattended updates

Releases are the update channel: a tag is cut only after CI has booted the pinned images, answered a question from a document through Traefik, and restored a backup. `update.sh` moves a deployment to the newest tag and nothing else:

```bash
./update.sh --dry-run   # show what would be applied
./update.sh             # update within the current major and redeploy
```

Put it on a timer for hands-off minor and patch updates:

```bash
# crontab -e
17 5 * * *  /opt/anythingllm-traefik-letsencrypt-docker-compose/update.sh >> /var/log/anythingllm-update.log 2>&1
```

The script refuses to cross a major template version on its own, refuses to touch a checkout with local modifications, and names any new required variable before anything moves. It is a host-side script on purpose: an in-stack updater needs the Docker socket, which is root on the host.

## Backups

The `backups` container runs on a loop: an initial delay (`ANYTHINGLLM_BACKUP_INIT_SLEEP`, default 30m), then every `ANYTHINGLLM_BACKUP_INTERVAL` (default 24h) it takes a consistent copy of AnythingLLM's SQLite database (`anythingllm.db`) through Python's `sqlite3` backup API, with no application stop, and a `tar.gz` of the rest of the storage volume, into the `anythingllm-backups` volume. Files older than `ANYTHINGLLM_BACKUP_PRUNE_DAYS` (default 7) are pruned. Each artefact logs `... backup OK: <file> (<bytes> bytes)` or `FAILED` (kept as `<file>.failed`). Grep the log for `FAILED` from your monitoring.

**What a backup set holds:** the database (workspaces, chats, users, API keys), the LanceDB vector store, the uploaded documents, the embedder's model and the instance's signing keys (`comkey`). Restored together they bring back an instance that answers from the same documents with the same keys. The keys are why the backups are secrets.

```bash
docker compose -p anythingllm logs backups | tail -5
docker compose -p anythingllm exec backups ls -la /srv/anythingllm/backups/
```

**Restore** a backup set with the script (`chmod +x anythingllm-restore-data.sh` once): it stops AnythingLLM, clears the storage volume, unpacks the archive, restores the database from its consistent copy, and starts AnythingLLM again. Clearing comes first because `tar` does not delete: a workspace made after the backup would otherwise survive the restore.

```bash
./anythingllm-restore-data.sh                    # list the sets and ask
./anythingllm-restore-data.sh 2026-10-19_04-00   # restore that set
```

It reads every path and name from the running backups container, and CI runs it on every push.

**Off-host replication.** Backups live in a named volume on the same host. Bind-mount `ANYTHINGLLM_BACKUPS_PATH` to a directory covered by your off-host backup (restic, rclone, Borg, S3 sync).

## Container hardening

Every service runs with `security_opt: no-new-privileges:true`. Traefik and the backups container drop every Linux capability and add back only what their entrypoints need. AnythingLLM drops every capability and adds none: it runs as its image's unprivileged user, and CI boots it, embeds, answers and restores under exactly that. Ollama keeps the default set and ships with no memory ceiling, because its working set is the model you choose (the compose file says how to add one).

## Testing

The [Deployment Verification](https://github.com/heyvaldemar/anythingllm-traefik-letsencrypt-docker-compose/actions/workflows/deployment-verification.yml?query=branch%3Amain) workflow runs on every push, pull request, and every day at 06:00 UTC:

1. **Lint**: shellcheck on every script, actionlint on the workflows.
2. **Trivy scans** of the three pinned images (CRITICAL/HIGH, SARIF to the Security tab).
3. **Deploy**: the full stack with a password and signing secret new on every run, the previous release first when there is one, then the upgrade.
4. **Ollama stays inside**: nothing answers on the host's port 11434, and AnythingLLM reaches Ollama on the internal network.
5. **RAG, end to end** (`tests/e2e-rag.sh`): no API key and no workspace list without the password, a wrong password refused; the password gives a session and the session an API key; a document goes in, is embedded and stored in LanceDB, and a vector search for a phrase only that document holds finds it; a question about it is answered by the model with that document named as the source.
6. **Backup and restore** (`tests/e2e-backup-restore.sh`): a backup set produced and valid, a failed cycle detected, and the restore round trip: a workspace made after the backup is gone, the RAG workspace is back, its vectors still find the phrase, and the API key from the restored database still works.

The Pin Freshness workflow runs separately, daily: digest drift against the registries, and release lag for AnythingLLM, Ollama and Traefik.

To run the tests yourself, on a staging copy and never on production (the restore stops AnythingLLM and replaces its storage), set short intervals in `.env` (`ANYTHINGLLM_BACKUP_INIT_SLEEP=15s`, `ANYTHINGLLM_BACKUP_INTERVAL=60s`) and a small model (`ANYTHINGLLM_CHAT_MODEL=qwen2.5:0.5b`, `OLLAMA_INSTALL_MODELS=qwen2.5:0.5b`), then:

```bash
./tests/e2e-rag.sh
./tests/e2e-backup-restore.sh
```

## Security notes

- Credentials are read from `.env` at deploy time; `.env` is gitignored, and the compose file stops on a missing password or signing secret.
- The tests pass credentials to `curl` through a file, never on a command line, and print none of them.
- Ollama's API is unauthenticated upstream; it is reachable only from the internal network here.
- Backups hold the instance's API keys and signing keys.
- Upstream image digests are pinned; the daily freshness job flags drift.

---

## About the maintainer

<div align="center">

**Maintained by [Vladimir Mikhalev](https://github.com/heyvaldemar)** · Docker Captain · IBM Champion · AWS Community Builder

[YouTube](https://www.youtube.com/channel/UCf85kQ0u1sYTTTyKVpxrlyQ?sub_confirmation=1) · [Blog](https://heyvaldemar.com) · [LinkedIn](https://www.linkedin.com/in/heyvaldemar/)

</div>
