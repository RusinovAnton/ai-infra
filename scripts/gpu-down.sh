#!/usr/bin/env bash
# Drain, then bring the inference node down.
#
#   ./gpu-down.sh            drain up to 120 s, then stop
#   ./gpu-down.sh --force    stop now, dropping in-flight requests
#   ./gpu-down.sh --dry-run  report what it would do
#
# What "down" MEANS is the provider's decision, and the difference is the point:
# an ephemeral rented node is destroyed, because a stopped one still bills. A
# machine you own is only stopped — nothing here can destroy hardware.
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

node_id="$(provider_find || true)"
if [ -z "$node_id" ]; then
  log "no node named $NODE_NAME — nothing to do${PROVIDER_BILLS_IDLE:+ ($PROVIDER_BILLS_IDLE)}"
  exit 0
fi
log "found node $node_id (provider=$GPU_PROVIDER, kind=$PROVIDER_KIND)"

if [ "$DRY" = 1 ]; then
  running="$(curl -fsS -m 10 "$(engine_base)/metrics" 2>/dev/null \
    | awk '/^vllm:num_requests_running/ {print $2}' | head -1)"
  if provider_is_ephemeral; then act="destroy"; else act="stop the engine on"; fi
  log "dry run: would drain (in flight: ${running:-unknown}) then $act $node_id"
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

# ------------------------------------------------------------ down

provider_destroy "$node_id"

if provider_is_ephemeral; then
  log "done. The ephemeral tailnet node removes itself.${PROVIDER_BILLS_IDLE:+ Note: $PROVIDER_BILLS_IDLE.}"
else
  log "done. The machine is untouched.${PROVIDER_BILLS_IDLE:+ Note: $PROVIDER_BILLS_IDLE.}"
fi
