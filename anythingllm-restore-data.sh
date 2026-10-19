#!/usr/bin/env bash
# anythingllm-restore-data.sh [timestamp]
#
# Replaces AnythingLLM's storage with one backup set: the data archive (the
# LanceDB vector store, the documents, the embedder's model, the instance's
# keys) and the consistent copy of its SQLite database taken beside it.
#
#   ./anythingllm-restore-data.sh                      list the sets and ask
#   ./anythingllm-restore-data.sh YYYY-MM-DD_hh-mm     restore that one
#
# EVERY PATH AND NAME COMES FROM THE RUNNING BACKUPS CONTAINER, so a backup
# directory or a backup name set differently in .env is still found. The
# storage is CLEARED before the archive is unpacked: tar does not delete, and
# a vector store with a collection added after the backup would otherwise come
# back holding both.
#
# WHAT THE ARCHIVE LEAVES OUT ON PURPOSE IS KEPT. The loop excludes tmp; it is
# set aside, the rest is cleared and unpacked, and it is put back, path by
# path. It used to come back with `cp -a /tmp/restore-keep/. /data/`, which
# copies the directory itself too: the volume's root became root-owned, the
# database was given that owner, and AnythingLLM, which runs as an
# unprivileged user, came back from every restore unable to write anything
# ("attempt to write a readonly database"). Found by the first local run of
# tests/e2e-backup-restore.sh on 2026-10-19.
#
# THE OWNER IS THE APPLICATION'S. The volume root and the restored database
# are given the owner of the files AnythingLLM itself created (comkey), not
# whoever runs this script.
#
# CI runs this exact file.
#
# Set COMPOSE_PROJECT_NAME if the stack was started with a -p other than
# anythingllm.
set -Eeuo pipefail

PROJECT="${COMPOSE_PROJECT_NAME:-anythingllm}"
STOP_SERVICES="anythingllm"             # every service that writes what is restored
ROOT="/data"                            # where the archive unpacks
PARTS="."                          # what it holds, relative to ROOT
KEEP="tmp"                              # what it leaves out on purpose, relative to ROOT
DBS="anythingllm.db"                    # SQLite files in /data, restored from their copies

cid() {  # the container of one compose service in this project
  docker ps -aq --filter "label=com.docker.compose.project=$PROJECT" \
    --filter "label=com.docker.compose.service=$1" | head -n 1
}
BKP="$(cid backups)"
[ -n "$BKP" ] || { echo "error: no backups container in compose project '$PROJECT' (set COMPOSE_PROJECT_NAME)" >&2; exit 1; }
[ "$(docker inspect -f '{{.State.Running}}' "$BKP")" = true ] || { echo "error: the backups container is not running" >&2; exit 1; }
APPS=""
for s in $STOP_SERVICES; do
  c="$(cid "$s")"; [ -n "$c" ] || { echo "error: no $s container in compose project '$PROJECT'" >&2; exit 1; }
  APPS="$APPS $c"
done

env_of() { docker exec "$BKP" printenv "$1"; }
DIR="$(env_of ANYTHINGLLM_BACKUPS_PATH)"; DATA_NAME="$(env_of ANYTHINGLLM_DATA_BACKUP_NAME)"
DB_NAME=""; [ -z "$DBS" ] || DB_NAME="$(env_of ANYTHINGLLM_BACKUP_NAME)"

STAMP="${1:-}"
if [ -z "$STAMP" ]; then
  echo "Backup sets in $DIR:"
  docker exec "$BKP" sh -c "ls -1 '$DIR' | grep -E '^$DATA_NAME-.*\\.tar\\.gz\$'" || { echo "  none found" >&2; exit 1; }
  read -r -p "Timestamp of the set to restore (YYYY-MM-DD_hh-mm): " STAMP
fi
case "$STAMP" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_[0-9][0-9]-[0-9][0-9]) ;;
  *) echo "error: '$STAMP' is not a timestamp like 2026-01-31_04-00" >&2; exit 1 ;;
esac
ARCHIVE="$DIR/$DATA_NAME-$STAMP.tar.gz"
docker exec "$BKP" tar -tzf "$ARCHIVE" > /dev/null \
  || { echo "error: $ARCHIVE is missing or does not open; nothing was changed" >&2; exit 1; }
for db in $DBS; do
  docker exec "$BKP" gunzip -t "$DIR/$DB_NAME-${db%%.*}-$STAMP.sqlite3.gz" \
    || { echo "error: the copy of $db for $STAMP is missing or does not open; nothing was changed" >&2; exit 1; }
done

echo "Stopping $STOP_SERVICES so nothing writes while the data is replaced"
# shellcheck disable=SC2086
docker stop $APPS > /dev/null
# shellcheck disable=SC2086
restart() { docker start $APPS > /dev/null && echo "Started $STOP_SERVICES"; }
trap 'restart' EXIT

echo "Restoring the set $STAMP"
# The exit status is kept and printed: a step that fails says why, but a
# process the kernel kills says nothing, and 137 is then the only clue.
rc=0
docker exec "$BKP" sh -c "set -eu
    cd '$ROOT'
    rm -rf /tmp/restore-keep; mkdir -p /tmp/restore-keep
    for p in $KEEP; do
      [ -e \"\$p\" ] || continue
      mkdir -p \"/tmp/restore-keep/\$(dirname \"\$p\")\"; mv \"\$p\" \"/tmp/restore-keep/\$p\"
    done
    for part in $PARTS; do find \"\$part\" -mindepth 1 -delete; done
    tar -xzpf '$ARCHIVE' -C '$ROOT'
    for p in $KEEP; do
      [ -e \"/tmp/restore-keep/\$p\" ] || continue
      rm -rf \"\$p\"; mkdir -p \"\$(dirname \"\$p\")\"; mv \"/tmp/restore-keep/\$p\" \"\$p\"
    done
    rm -rf /tmp/restore-keep
    owner=\$(stat -c %u:%g /data/comkey 2>/dev/null || stat -c %u:%g /data)
    chown \"\$owner\" /data
    for db in $DBS; do
      rm -f \"/data/\$db\" \"/data/\$db-wal\" \"/data/\$db-shm\"
      gunzip -c \"$DIR/$DB_NAME-\${db%%.*}-$STAMP.sqlite3.gz\" > \"/data/\$db\"
      chown \"\$owner\" \"/data/\$db\"
    done" || rc=$?
if [ "$rc" -ne 0 ]; then
  echo "error: the restore failed part-way (exit $rc); the data may be incomplete. Restore another set before using AnythingLLM." >&2
  exit 1
fi
echo "Restored the set $STAMP"
