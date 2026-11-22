#!/bin/bash
# Vectors written by the previous release, read by this one.
#
# LanceDB keeps its tables on the storage volume, and a release can move the
# LanceDB library under them (AnythingLLM 1.20.0 moved it to 0.30.0). A fresh
# stack never shows whether the new library reads the old tables. So the
# upgrade drill runs `seed` against the previous release before it stops it:
# the password gives a session, the session an API key, and a document holding
# a phrase found nowhere else is embedded into a workspace of its own. After
# the upgrade, `check` asks that same workspace, with that same key, for the
# phrase. Both go through Traefik on 127.0.0.1:443, as a client would.
#
#   tests/e2e-vectors-survive.sh seed    # against the previous release
#   tests/e2e-vectors-survive.sh check   # against the upgraded stack
#
# Requires: curl, python3, .env in the repository root. The key, workspace and
# phrase go to $SURVIVE_STATE (mode 600); no value is printed.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

mode="${1:-}"
case "$mode" in seed|check) ;; *) echo "usage: $0 seed|check" >&2; exit 2 ;; esac

[[ -f .env ]] || { echo "error: .env not found at $REPO_ROOT/.env" >&2; exit 2; }
set -o allexport
# shellcheck disable=SC1091
source .env
set +o allexport

HOST="${ANYTHINGLLM_HOSTNAME:?ANYTHINGLLM_HOSTNAME is not set in .env}"
BASE="https://$HOST"
STATE="${SURVIVE_STATE:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/anythingllm-survive.env}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

c() { curl -sk --resolve "$HOST:443:127.0.0.1" "$@"; }
# Credentials never reach a command line: curl reads its headers from a file.
auth_file() { ( umask 077; printf 'header = "Authorization: Bearer %s"\n' "$2" > "$WORK/$1" ); }
# jget <path>: the value at a dotted path in the JSON on stdin; empty when absent.
jget() {
  python3 -c '
import json, sys
try:
    v = json.load(sys.stdin)
    for k in sys.argv[1].split("."):
        v = v[int(k)] if isinstance(v, list) else v.get(k)
except Exception:
    v = None
print("" if v is None else v)' "$1"
}
online() {
  local _
  for _ in $(seq 1 60); do
    c "$BASE/api/ping" | grep -q '"online":true' && return 0
    sleep 5
  done
  return 1
}
search() {  # search <workspace>: the top vector match's text
  c -K "$WORK/api" -H "Content-Type: application/json" \
    -d '{"query":"Which phrase marks the notes kept from before the upgrade?","topN":1}' \
    "$BASE/api/v1/workspace/$1/vector-search" | jget results.0.text
}

if [[ "$mode" == seed ]]; then
  online || { echo "seed: AnythingLLM never answered /api/ping through Traefik" >&2; exit 1; }
  token="$(printf '{"password":"%s"}' "$ANYTHINGLLM_PASSWORD" \
    | c -H "Content-Type: application/json" -d @- "$BASE/api/request-token" | jget token)"
  [[ -n "$token" ]] || { echo "seed: the password gave no session token" >&2; exit 1; }
  auth_file session "$token"
  secret="$(c -K "$WORK/session" -X POST "$BASE/api/system/generate-api-key" | jget apiKey.secret)"
  [[ -n "$secret" ]] || { echo "seed: the session gave no API key" >&2; exit 1; }
  auth_file api "$secret"
  phrase="amber-lantern-$$-$RANDOM"
  doc="$WORK/kept-notes.md"
  printf '# Kept notes\n\nThese notes were embedded before the upgrade.\nThe phrase that marks the notes kept from before the upgrade is %s.\n' "$phrase" > "$doc"
  loc="$(c -K "$WORK/api" -F "file=@$doc" "$BASE/api/v1/document/upload" | jget documents.0.location)"
  [[ -n "$loc" ]] || { echo "seed: the document was not accepted" >&2; exit 1; }
  slug="$(c -K "$WORK/api" -H "Content-Type: application/json" -d '{"name":"before-upgrade"}' "$BASE/api/v1/workspace/new" | jget workspace.slug)"
  [[ -n "$slug" ]] || { echo "seed: no workspace was created" >&2; exit 1; }
  c -K "$WORK/api" -H "Content-Type: application/json" -d "{\"adds\":[\"$loc\"]}" \
    "$BASE/api/v1/workspace/$slug/update-embeddings" >/dev/null
  grep -qF "$phrase" <<<"$(search "$slug")" \
    || { echo "seed: even the release that embedded it does not find the phrase" >&2; exit 1; }
  ( umask 077; printf 'SURVIVE_KEY=%s\nSURVIVE_WORKSPACE=%s\nSURVIVE_PHRASE=%s\n' "$secret" "$slug" "$phrase" > "$STATE" )
  echo "seed: embedded into workspace '$slug' on the release running now; its top match holds the phrase"
  exit 0
fi

[[ -s "$STATE" ]] || { echo "check: no seed state at $STATE; seed did not run" >&2; exit 1; }
key="$(sed -n 's/^SURVIVE_KEY=//p' "$STATE")"
slug="$(sed -n 's/^SURVIVE_WORKSPACE=//p' "$STATE")"
phrase="$(sed -n 's/^SURVIVE_PHRASE=//p' "$STATE")"
[[ -n "$key" && -n "$slug" && -n "$phrase" ]] || { echo "check: the seed state is incomplete" >&2; exit 1; }
auth_file api "$key"
online || { echo "check: AnythingLLM never answered /api/ping through Traefik" >&2; exit 1; }
code="$(c -o /dev/null -w '%{http_code}' -K "$WORK/api" "$BASE/api/v1/auth")"
[[ "$code" == 200 ]] || { echo "check: the API key made before the upgrade is refused after it: HTTP $code" >&2; exit 1; }
top="$(search "$slug")"
if grep -qF "$phrase" <<<"$top"; then
  echo "check: workspace '$slug', embedded before the upgrade, still finds its phrase with the key made before it"
else
  echo "check: workspace '$slug' no longer finds the phrase embedded before the upgrade (top match: ${top:0:80})" >&2
  exit 1
fi
