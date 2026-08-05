#!/usr/bin/env bash
# Two independent cost guards. Runs on the OFFICE MACHINE, never on the GPU node
# — it has to survive the GPU being unreachable, which is the state it exists to
# detect.
#
#   ./idle-check.sh            shut down if idle longer than IDLE_MINUTES
#   ./idle-check.sh --nightly  shut down unconditionally, idle or not
#   ./idle-check.sh --dry-run  report the decision, change nothing
#
# The top cost failure is not an expensive instance. It is a forgotten gpu-down
# over a weekend. max_tokens caps a request; nothing else here caps a month.
#
# Install both (crontab -e):
#   */10 * * * * /path/to/ai-infra/scripts/idle-check.sh          >> /tmp/idle-check.log 2>&1
#   0 22  * * *  /path/to/ai-infra/scripts/idle-check.sh --nightly >> /tmp/idle-check.log 2>&1
#
# The nightly stop matters MORE than the threshold value, and the reason is not
# obvious: the failure that actually produces a surprise bill is not a threshold
# tuned slightly wrong, it is this check silently not running — dead cron, a
# query that errors, a provider API change. A fixed nightly stop bounds the
# worst case to one day regardless of whether any of the logic above it works.
# Do not tune the threshold in place of the nightly stop; only one of them is
# guaranteed to fire.
#
# Pair both with a provider-side spend alert. Cron dying is exactly the case
# neither script can report on.
set -euo pipefail
. "$(dirname "$0")/common.sh"
load_env

NIGHTLY=0; DRY=0
case "${1:-}" in
  --nightly) NIGHTLY=1 ;;
  --dry-run) DRY=1 ;;
  "")        ;;
  *)         die "unknown argument: $1" ;;
esac

IDLE_MINUTES="${IDLE_MINUTES:-45}"

pod_id="$(find_pod_id || true)"
if [ -z "$pod_id" ]; then
  log "no pod running — nothing to do"
  exit 0
fi

shutdown() {
  if [ "$DRY" = 1 ]; then log "DRY RUN: would run gpu-down.sh ($1)"; exit 0; fi
  log "shutting down: $1"
  exec "$SCRIPTS_DIR/gpu-down.sh"
}

if [ "$NIGHTLY" = 1 ]; then
  # Interrupting a genuine late-night session is the accepted cost. gpu-up is a
  # one-liner, so restarting is cheap; an unbounded bill is not.
  shutdown "hard nightly stop"
fi

# Last request timestamp comes from LiteLLM's spend log. This is a concrete
# reason not to set disable_spend_logs: turn_off_message_logging redacts prompt
# and response content while keeping exactly the rows this query needs.
last="$(cd "$GATEWAY_DIR" && docker compose exec -T litellm-db \
  psql -tAqU litellm -d litellm \
  -c 'SELECT COALESCE(MAX("startTime"), to_timestamp(0)) FROM "LiteLLM_SpendLogs";' 2>/dev/null \
  | tr -d '\r' | xargs || true)"

if [ -z "$last" ]; then
  # Fail loud and do NOT shut down. A broken query must not become an outage
  # generator; the nightly stop is the backstop for the cost side.
  die "could not read LiteLLM_SpendLogs (is the gateway up? was disable_spend_logs set?) — not shutting down; the nightly stop still applies"
fi

idle_min="$(python3 -c "
import datetime, sys
s='''$last'''.strip()
try:
    t=datetime.datetime.fromisoformat(s)
except ValueError:
    sys.exit('unparseable timestamp: '+s)
if t.tzinfo is None: t=t.replace(tzinfo=datetime.timezone.utc)
now=datetime.datetime.now(datetime.timezone.utc)
print(int((now-t).total_seconds()//60))
")"

log "last request ${idle_min} min ago (threshold ${IDLE_MINUTES})"

# Belt and braces: a request that arrived after the query but is still
# generating would not be in SpendLogs yet. Ask the engine directly.
running="$(curl -fsS -m 10 "$(engine_base)/metrics" 2>/dev/null \
  | awk '/^vllm:num_requests_running/ {print $2}' | head -1 || true)"
if [ -n "$running" ] && python3 -c "import sys;sys.exit(0 if float('$running')>0 else 1)"; then
  log "engine reports ${running} request(s) in flight — not idle"
  exit 0
fi

if [ "$idle_min" -ge "$IDLE_MINUTES" ]; then
  shutdown "idle ${idle_min} min >= ${IDLE_MINUTES}"
fi

log "not idle — leaving the pod running"
