#!/usr/bin/env bash
# Drain, then destroy the inference node. The volume persists.
#
#   ./gpu-down.sh            drain up to 120 s, then terminate
#   ./gpu-down.sh --force    terminate now, dropping in-flight requests
#   ./gpu-down.sh --dry-run  report what it would do
#
# Draining matters because a coder-max request can legitimately run for minutes.
# Killing mid-generation presents to the user as a flaky gateway, not as a
# shutdown — which is the failure mode worth spending 120 seconds to avoid.
set -euo pipefail
. "$(dirname "$0")/common.sh"
load_env

FORCE=0; DRY=0
case "${1:-}" in
  --force)   FORCE=1 ;;
  --dry-run) DRY=1 ;;
  "")        ;;
  *)         die "unknown argument: $1" ;;
esac

DRAIN_TIMEOUT="${DRAIN_TIMEOUT:-120}"

pod_id="$(find_pod_id || true)"
if [ -z "$pod_id" ]; then
  log "no pod named $POD_NAME — nothing to do (the volume still bills)"
  exit 0
fi
log "found pod $pod_id"

if [ "$DRY" = 1 ]; then
  running="$(curl -fsS -m 10 "$(engine_base)/metrics" 2>/dev/null \
    | awk '/^vllm:num_requests_running/ {print $2}' | head -1)"
  log "dry run: would drain (in flight: ${running:-unknown}) then terminate $pod_id"
  exit 0
fi

# ------------------------------------------------------------ drain

if [ "$FORCE" = 0 ]; then
  log "draining: waiting for in-flight requests to finish (hard timeout ${DRAIN_TIMEOUT}s)"
  deadline=$(( $(date +%s) + DRAIN_TIMEOUT ))
  while :; do
    running="$(curl -fsS -m 10 "$(engine_base)/metrics" 2>/dev/null \
      | awk '/^vllm:num_requests_running/ {print $2}' | head -1)"
    if [ -z "$running" ]; then
      log "engine metrics unreachable — treating as already drained"
      break
    fi
    # The metric is a float ("0.0"), so compare numerically rather than as text.
    if python3 -c "import sys;sys.exit(0 if float('$running')<1 else 1)"; then
      log "drained (0 requests running)"
      break
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      # Say this out loud rather than leaving it undefined. An interrupted agent
      # turn is recoverable; a silent drop that looks like gateway flakiness is
      # what wastes someone's afternoon.
      log "DRAIN TIMEOUT after ${DRAIN_TIMEOUT}s with ${running} request(s) still running — destroying anyway"
      break
    fi
    log "  ${running} in flight, waiting…"
    sleep 5
  done
else
  log "--force: skipping drain, in-flight requests will be dropped"
fi

# ------------------------------------------------------------ terminate

log "terminating pod $pod_id"
# DELETE, not /stop. A stopped pod keeps billing its container disk and holds
# the GPU reservation; the whole point of on-demand is that nothing but the
# volume survives.
rp DELETE "/pods/$pod_id" >/dev/null || die "terminate call failed — check the RunPod console before assuming it is down"

for _ in $(seq 1 20); do
  [ -z "$(find_pod_id || true)" ] && { log "pod gone"; break; }
  sleep 3
done

log "done. The ephemeral tailnet node removes itself; the weights volume persists (and keeps billing)."
