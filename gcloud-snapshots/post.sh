#!/bin/bash
#
# Post-snapshot hook: undo whatever pre.sh recorded in STATE_DIR.
#
# Every step is attempted even if an earlier one fails, and the hook exits
# non-zero if any of them failed. pre.sh also runs this to roll back after a
# failure, and running it again when there is nothing to undo is a no-op.
set -euo pipefail

HTTP_TIMEOUT=${HTTP_TIMEOUT:-30}
STATE_DIR=${STATE_DIR:-/run/gcloud-snapshot}         # must match pre.sh

log() { echo "post.sh: $*" >&2; }

# alive PID COMM: true if PID still runs COMM, so a recycled PID is never killed.
alive() {
  [[ -r /proc/$1/comm && $(<"/proc/$1/comm") == "$2" ]]
}

# 1. Thaw the filesystem first; the steps below may need to write to it.
thaw() {
  local mount
  [[ -e $STATE_DIR/frozen ]] || return 0
  mount=$(<"$STATE_DIR/frozen")
  if ! xfs_freeze -u "$mount"; then
    log "failed to unfreeze $mount"
    return 1
  fi
  rm -f "$STATE_DIR/frozen"
  log "unfroze $mount"
}

# 2. Release the database lock. Killing the holder closes the FIFO's last
# writer, so the client reads EOF, disconnects and the server drops the lock.
unlock_db() {
  local pid comm _
  [[ -e $STATE_DIR/mysql.pid || -e $STATE_DIR/holder.pid ]] || return 0
  if [[ -e $STATE_DIR/holder.pid ]]; then
    read -r pid comm <"$STATE_DIR/holder.pid"
    if alive "$pid" "$comm"; then
      kill "$pid" || true
    fi
  fi
  if [[ -e $STATE_DIR/mysql.pid ]]; then
    read -r pid comm <"$STATE_DIR/mysql.pid"
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      alive "$pid" "$comm" || break
      sleep 1
    done
    if alive "$pid" "$comm"; then
      kill "$pid" || true
      sleep 1
    fi
    if alive "$pid" "$comm"; then
      log "database lock session $pid did not exit"
      return 1
    fi
  fi
  rm -f "$STATE_DIR/mysql.pid" "$STATE_DIR/holder.pid" "$STATE_DIR/mysql.fifo" "$STATE_DIR/mysql.out"
  log "released database read lock"
}

# 3. Reopen the Elasticsearch index.
reopen_index() {
  local index_url
  [[ -e $STATE_DIR/es-closed ]] || return 0
  index_url=$(<"$STATE_DIR/es-closed")
  if ! curl -fsS --max-time "$HTTP_TIMEOUT" -X POST "$index_url/_open" >/dev/null; then
    log "failed to reopen $index_url"
    return 1
  fi
  rm -f "$STATE_DIR/es-closed"
  log "reopened $index_url"
}

[[ -d $STATE_DIR ]] || exit 0

failed=0
thaw || failed=1
unlock_db || failed=1
reopen_index || failed=1

if (( failed )); then
  log "one or more steps failed; state kept in $STATE_DIR"
  exit 1
fi
rmdir "$STATE_DIR"
