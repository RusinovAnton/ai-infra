#!/usr/bin/env bash
# The cost guards and backups, as a long-running loop instead of cron.
#
# WHY NOT CRON. The gateway may be a laptop, and a laptop sleeps. cron does not
# fire while the machine is asleep and does not catch up afterwards: a window
# that passes during sleep is simply lost, silently, which is the exact failure
# mode the nightly stop exists to prevent. This loop compares wall-clock time
# against a state file, so a job whose window passed during sleep runs once,
# late, on wake. Late is recoverable. Never is a bill.
#
# It does NOT keep the machine awake. Nothing here runs while the host sleeps —
# see docs/devops-setup.md for why the provider-side spend alert remains the
# only guard that survives a closed lid.
#
# Runs on the host or inside the scheduler container; the only difference is
# PGHOST/GATEWAY_URL, handled by common.sh.
set -euo pipefail

. "$(dirname "$0")/common.sh"

STATE_DIR="${SCHEDULER_STATE_DIR:-/var/lib/ai-infra-scheduler}"
mkdir -p "$STATE_DIR"

TICK="${SCHEDULER_TICK:-60}"           # seconds between evaluations
IDLE_EVERY="${SCHEDULER_IDLE_EVERY:-600}"
NIGHTLY_AT="${SCHEDULER_NIGHTLY_AT:-22:00}"
BACKUP_AT="${SCHEDULER_BACKUP_AT:-03:30}"
VERIFY_AT="${SCHEDULER_VERIFY_AT:-04:30}"
VERIFY_DOW="${SCHEDULER_VERIFY_DOW:-0}" # 0 = Sunday

now_epoch() { date +%s; }
today()     { date +%F; }
hhmm()      { date +%H:%M; }
dow()       { date +%w; }

# --- interval jobs: run when enough wall-clock time has passed -------------
due_interval() { # due_interval NAME SECONDS
  local f="$STATE_DIR/$1.last" every="$2" last=0
  [ -f "$f" ] && last="$(cat "$f" 2>/dev/null || echo 0)"
  [ "$(( $(now_epoch) - last ))" -ge "$every" ]
}

# --- daily jobs: run once per day, on or after the target time ------------
# Comparing dates rather than sleeping until a timestamp is what makes this
# sleep-safe: waking at 09:00 with a 03:30 backup unrun still fires it.
due_daily() { # due_daily NAME HH:MM
  local f="$STATE_DIR/$1.day"
  [ "$(hhmm)" \< "$2" ] && return 1
  [ -f "$f" ] && [ "$(cat "$f" 2>/dev/null)" = "$(today)" ] && return 1
  return 0
}

mark_interval() { now_epoch > "$STATE_DIR/$1.last"; }
mark_daily()    { today     > "$STATE_DIR/$1.day"; }

run() { # run NAME COMMAND...
  local name="$1"; shift
  log "running $name"
  # Never let one failing job kill the loop — that would silently disarm every
  # other guard, which is worse than the failure being reported and retried.
  if "$@"; then log "$name ok"; else log "$name FAILED (rc=$?) — continuing"; fi
}

log "scheduler up: idle every ${IDLE_EVERY}s, nightly $NIGHTLY_AT, backup $BACKUP_AT, verify $VERIFY_AT (dow=$VERIFY_DOW), TZ=$(date +%Z)"

while :; do
  if due_interval idle "$IDLE_EVERY"; then
    mark_interval idle
    run idle-check "$SCRIPTS_DIR/idle-check.sh"
  fi

  if due_daily nightly "$NIGHTLY_AT"; then
    mark_daily nightly
    run nightly-stop "$SCRIPTS_DIR/idle-check.sh" --nightly
  fi

  if due_daily backup "$BACKUP_AT"; then
    mark_daily backup
    run pg-backup "$SCRIPTS_DIR/pg-backup.sh"
  fi

  if [ "$(dow)" = "$VERIFY_DOW" ] && due_daily verify "$VERIFY_AT"; then
    mark_daily verify
    run pg-verify "$SCRIPTS_DIR/pg-backup.sh" --verify
  fi

  sleep "$TICK"
done
