#!/bin/bash
#
# Pre-snapshot hook: quiesce MariaDB/MySQL, Elasticsearch and the filesystem.
#
# Every step is checked. If any step fails, the EXIT trap runs post.sh to undo
# the steps already taken and the hook exits non-zero, so the snapshot is not
# recorded as application-consistent.
#
# Settings can be changed here or overridden from the environment. Set MYSQL,
# ES_INDEX or FREEZE_MOUNT to an empty string to skip that step.
set -euo pipefail

MYSQL=${MYSQL-mysql}                                 # client binary
MYSQL_DEFAULTS_FILE=${MYSQL_DEFAULTS_FILE:-/root/.my.cnf} # [client] credentials; never pass -p on the command line
LOCK_WAIT=${LOCK_WAIT:-30}                           # seconds to wait for FLUSH TABLES WITH READ LOCK
LOCK_MAX=${LOCK_MAX:-600}                            # the lock is dropped after this even if post.sh never runs
ES_URL=${ES_URL:-http://localhost:9200}
ES_INDEX=${ES_INDEX-index_index}
HTTP_TIMEOUT=${HTTP_TIMEOUT:-30}
FREEZE_MOUNT=${FREEZE_MOUNT-/}
STATE_DIR=${STATE_DIR:-/run/gcloud-snapshot}         # must not be on FREEZE_MOUNT; post.sh reads it

POST_SH="$(dirname "$0")/post.sh"
FIFO="$STATE_DIR/mysql.fifo"

log() { echo "pre.sh: $*" >&2; }

completed=0
rollback() {
  local rc=$?
  trap - EXIT
  exec 3>&-
  # Success is decided by the flag set on the last line, not by $? alone: a
  # signal that ends the script (SIGTERM, SIGHUP) runs this trap with $? still 0.
  if (( rc == 0 && completed )); then
    exit 0
  fi
  (( rc != 0 )) || rc=1
  log "failed (exit $rc); undoing completed steps"
  "$POST_SH" || log "rollback incomplete; check $STATE_DIR"
  exit "$rc"
}

# A previous run that never reached post.sh leaves its state behind. Clear it
# (this releases any lock or freeze it still holds) before starting again.
if [[ -e $STATE_DIR ]]; then
  log "stale state in $STATE_DIR; running post.sh first"
  "$POST_SH"
fi
mkdir -m 700 "$STATE_DIR"
trap rollback EXIT

if [[ -n $FREEZE_MOUNT && $(stat -c %d "$STATE_DIR") == "$(stat -c %d "$FREEZE_MOUNT")" ]]; then
  log "STATE_DIR $STATE_DIR is on $FREEZE_MOUNT, which is about to be frozen"
  exit 1
fi

# 1. Take a global read lock and keep it until post.sh runs.
#
# The lock only lasts as long as the session that took it, so it cannot be
# taken with `mysql -e`. Instead a background client reads its SQL from a FIFO,
# and a background `sleep` holds the FIFO's write end open so the session
# stays alive after this script exits. post.sh kills the holder; the client
# then reads EOF and disconnects, which releases the lock. If post.sh never
# runs, the holder exits after LOCK_MAX seconds with the same effect.
if [[ -n $MYSQL ]]; then
  mysql_cmd=("$MYSQL")
  if [[ -r $MYSQL_DEFAULTS_FILE ]]; then
    mysql_cmd+=("--defaults-extra-file=$MYSQL_DEFAULTS_FILE")
  fi
  mysql_cmd+=(--batch --skip-column-names --unbuffered)

  # Open the FIFO read-write first: that never blocks, and it keeps the FIFO
  # (and the SQL written to it) alive however the children are scheduled. The
  # holder inherits its write end at fork time, so there is no open() race.
  mkfifo -m 600 "$FIFO"
  exec 3<>"$FIFO"
  setsid "${mysql_cmd[@]}" >"$STATE_DIR/mysql.out" 2>&1 <"$FIFO" 3>&- &
  echo "$! $(basename "$MYSQL")" >"$STATE_DIR/mysql.pid"
  setsid sleep "$LOCK_MAX" >&3 2>/dev/null </dev/null 3>&- &
  echo "$! sleep" >"$STATE_DIR/holder.pid"
  # wait_timeout: the session sits idle until post.sh, so the server's own idle
  # timeout (often a few minutes) must not drop the lock before LOCK_MAX does.
  printf "SET SESSION lock_wait_timeout = %d;\nSET SESSION wait_timeout = %d;\nFLUSH TABLES WITH READ LOCK;\nSELECT 'LOCKED';\n" \
    "$LOCK_WAIT" "$(( LOCK_MAX + 60 ))" >&3
  exec 3>&-

  read -r mysql_pid _ <"$STATE_DIR/mysql.pid"
  for (( waited = 0; ; waited++ )); do
    if grep -qx LOCKED "$STATE_DIR/mysql.out"; then
      break
    fi
    if ! kill -0 "$mysql_pid" 2>/dev/null; then
      log "FLUSH TABLES WITH READ LOCK failed: $(cat "$STATE_DIR/mysql.out")"
      exit 1
    fi
    if (( waited >= LOCK_WAIT + 5 )); then
      log "timed out waiting for FLUSH TABLES WITH READ LOCK"
      exit 1
    fi
    sleep 1
  done
  log "database read lock held"
fi

# 2. Close the Elasticsearch index. The marker goes first so that a request
# that times out after the close took effect is still undone.
if [[ -n $ES_INDEX ]]; then
  echo "$ES_URL/$ES_INDEX" >"$STATE_DIR/es-closed"
  curl -fsS --max-time "$HTTP_TIMEOUT" -X POST "$ES_URL/$ES_INDEX/_close" >/dev/null
  log "closed index $ES_INDEX"
fi

# 3. Flush and freeze the filesystem. Nothing below may write to FREEZE_MOUNT.
if [[ -n $FREEZE_MOUNT ]]; then
  sync
  xfs_freeze -f "$FREEZE_MOUNT"
  echo "$FREEZE_MOUNT" >"$STATE_DIR/frozen"
  log "froze $FREEZE_MOUNT"
fi

completed=1
