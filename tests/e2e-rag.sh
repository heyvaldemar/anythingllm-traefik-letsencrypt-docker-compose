#!/bin/bash
# End-to-end test of what this template is for: a private document, asked
# about, answered from that document, on this host. Through Traefik, as a
# browser or a client reaches it.
#
#   1. nothing is reachable without the password: no API key for the asking,
#      no workspace list, and a wrong password is refused
#   2. the password gives a session, and the session an API key
#   3. a document goes in, is embedded by the built-in embedder and stored in
#      LanceDB, and a vector search for a phrase only that document holds
#      finds it
#   4. a question about it is answered by the Ollama model with that document
#      named as the source
#
# Requires: docker, curl, python3, and the stack up with .env in the
# repository root. The API key and the workspace it creates are written to
# $E2E_STATE (mode 600) for tests/e2e-backup-restore.sh, which runs next.
#
#   ./tests/e2e-rag.sh
#
# Tests are dispatched indirectly via run_test "$name"; shellcheck cannot
# trace that and flags every function as unused (SC2329).
# shellcheck disable=SC2329

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

[[ -f .env ]] || { echo "error: .env not found at $REPO_ROOT/.env" >&2; exit 1; }
set -o allexport
# shellcheck disable=SC1091
source .env
set +o allexport

BASE="${E2E_BASE_URL:-https://${ANYTHINGLLM_HOSTNAME}}"
E2E_STATE="${E2E_STATE:-${TMPDIR:-/tmp}/anythingllm-e2e.env}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# The phrase exists in the test document and nowhere else, so finding it is
# finding the document.
PHRASE="copper-heron-$$"

PASSED=0
FAILED=0
FAILURES=()
run_test() {
  local name="$1"
  echo
  echo "=== $name ==="
  if "$name"; then
    echo "  PASS: $name"
    PASSED=$((PASSED + 1))
  else
    echo "  FAIL: $name" >&2
    FAILED=$((FAILED + 1))
    FAILURES+=("$name")
  fi
}
fail() { echo "  ASSERT: $*" >&2; return 1; }

# Credentials never reach a command line: curl reads its headers from a file.
auth_file() {  # auth_file <name> <bearer value>
  ( umask 077; printf 'header = "Authorization: Bearer %s"\n' "$2" > "$WORK/$1" )
}
code() { curl -sk -o /dev/null -w '%{http_code}' "$@"; }
# jget <path>: the value at a dotted path in the JSON on stdin (list indexes
# as numbers), "len" for the length of what is there; empty when absent.
jget() {
  python3 -c '
import json, sys
v = json.load(sys.stdin)
for k in sys.argv[1].split("."):
    if k == "len":
        v = len(v or [])
    elif isinstance(v, list):
        v = v[int(k)] if k.isdigit() and int(k) < len(v) else None
    elif isinstance(v, dict):
        v = v.get(k)
    else:
        v = None
print("" if v is None else v)' "$1"
}
# titles: the titles of the sources an answer used, space-separated.
titles() { python3 -c 'import json,sys; print(" ".join(s.get("title", "") for s in (json.load(sys.stdin).get("sources") or [])))'; }

test_closed_without_the_password() {
  local c
  c="$(code -X POST "$BASE/api/system/generate-api-key")"
  [[ "$c" == 401 ]] || { fail "an API key was offered without a password: HTTP $c"; return 1; }
  echo "  no credentials, POST /api/system/generate-api-key: $c"
  c="$(code "$BASE/api/workspaces")"
  [[ "$c" == 401 ]] || { fail "workspaces listed without a password: HTTP $c"; return 1; }
  echo "  no credentials, GET /api/workspaces: $c"
}

test_wrong_password_refused() {
  local valid
  valid="$(printf '{"password":"%s"}' "not-the-password-$$" \
    | curl -sk -H "Content-Type: application/json" -d @- "$BASE/api/request-token" | jget valid)"
  [[ "$valid" == "False" ]] || { fail "a wrong password was accepted: valid=$valid"; return 1; }
}

test_password_gives_an_api_key() {
  local token secret
  token="$(printf '{"password":"%s"}' "$ANYTHINGLLM_PASSWORD" \
    | curl -sk -H "Content-Type: application/json" -d @- "$BASE/api/request-token" | jget token)"
  [[ -n "$token" ]] || { fail "the password did not give a session token"; return 1; }
  auth_file session "$token"
  secret="$(curl -sk -K "$WORK/session" -X POST "$BASE/api/system/generate-api-key" | jget apiKey.secret)"
  [[ -n "$secret" ]] || { fail "the session did not give an API key"; return 1; }
  auth_file api "$secret"
  ( umask 077; printf 'E2E_API_KEY=%s\n' "$secret" > "$E2E_STATE" )
  echo "  session token and API key issued (values not printed)"
}

test_document_embedded_and_found() {
  local doc loc slug n top
  doc="$WORK/drill-notes.md"
  cat > "$doc" <<EOF
# Drill notes

The restore drill for this instance runs every Sunday at four in the morning.
The phrase that proves a restore brought back the right documents is $PHRASE.
Nobody but the operator holds the backups.
EOF
  loc="$(curl -sk -K "$WORK/api" -F "file=@$doc" "$BASE/api/v1/document/upload" | jget documents.0.location)"
  [[ -n "$loc" ]] || { fail "the document was not accepted"; return 1; }
  slug="$(curl -sk -K "$WORK/api" -H "Content-Type: application/json" -d '{"name":"e2e"}' "$BASE/api/v1/workspace/new" | jget workspace.slug)"
  [[ -n "$slug" ]] || { fail "no workspace was created"; return 1; }
  n="$(curl -sk -K "$WORK/api" -H "Content-Type: application/json" -d "{\"adds\":[\"$loc\"]}" \
    "$BASE/api/v1/workspace/$slug/update-embeddings" | jget workspace.documents.len)"
  [[ "$n" == 1 ]] || { fail "the workspace holds $n documents after embedding, expected 1"; return 1; }
  top="$(curl -sk -K "$WORK/api" -H "Content-Type: application/json" -d '{"query":"Which phrase proves a restore brought back the right documents?","topN":1}' \
    "$BASE/api/v1/workspace/$slug/vector-search" | jget results.0.text)"
  grep -qF "$PHRASE" <<<"$top" || { fail "the vector search did not find the document's phrase"; return 1; }
  printf 'E2E_WORKSPACE=%s\nE2E_PHRASE=%s\n' "$slug" "$PHRASE" >> "$E2E_STATE"
  echo "  embedded into workspace '$slug'; the top vector match holds $PHRASE"
}

test_answered_from_the_document() {
  local slug out sources answer
  slug="$(sed -n 's/^E2E_WORKSPACE=//p' "$E2E_STATE")"
  [[ -n "$slug" ]] || { fail "no workspace from the previous test"; return 1; }
  # Query mode answers only from the workspace's documents and returns the
  # ones it used. The answer's wording is the model's; the source is not.
  out="$(curl -sk -K "$WORK/api" -H "Content-Type: application/json" --max-time 600 \
    -d '{"message":"Which phrase proves a restore brought back the right documents?","mode":"query"}' \
    "$BASE/api/v1/workspace/$slug/chat")"
  sources="$(titles <<<"$out")"
  answer="$(jget textResponse <<<"$out")"
  grep -q "drill-notes" <<<"$sources" || { fail "the answer named no source from the document (sources: '$sources', error: $(jget error <<<"$out"))"; return 1; }
  [[ -n "$answer" ]] || { fail "the model returned no answer"; return 1; }
  echo "  answered by ${ANYTHINGLLM_CHAT_MODEL:-llama3.2:3b}, source: $sources"
  echo "  the answer began: ${answer:0:120}"
}

echo "=== anythingllm: RAG end-to-end, through Traefik at $BASE ==="
run_test test_closed_without_the_password
run_test test_wrong_password_refused
run_test test_password_gives_an_api_key
run_test test_document_embedded_and_found
run_test test_answered_from_the_document

echo
echo "==============================="
echo "Passed: $PASSED  Failed: $FAILED"
if [[ ${#FAILURES[@]} -gt 0 ]]; then
  echo "Failures:"
  for f in "${FAILURES[@]}"; do echo "  - $f"; done
fi
[[ $FAILED -eq 0 ]]
