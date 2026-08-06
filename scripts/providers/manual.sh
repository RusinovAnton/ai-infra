#!/usr/bin/env bash
# GPU_PROVIDER=manual — you start the engine, the scripts only observe.
# shellcheck shell=bash
#
# The smallest complete driver, and the reference for writing a new one. Also
# the right choice on day one with unfamiliar hardware: bring the engine up by
# hand, confirm the gateway sees it, and automate afterwards.
#
# Everything above the driver still works — the gateway, aliases, keys, spend
# tracking, backups, the 503 when the engine is down. Only create/destroy are
# yours to perform.

PROVIDER_KIND=persistent
# Cannot deliver a secret to a node it does not create, so gpu-up.sh will skip
# rotation rather than silently change a value the engine never receives.
PROVIDER_INJECTS_SECRET=0
PROVIDER_BILLS_IDLE="whatever the machine costs — nothing here can stop it"

provider_preflight() {
  : "${ENGINE_API_BASE:?set in gateway/.env}"
}

# There is no API to ask, so existence is defined by the only thing that
# actually matters: does the engine answer on the path the ACL permits.
provider_find() {
  if engine_ready 2>/dev/null; then printf 'manual'; fi
}

provider_status() {
  if engine_ready 2>/dev/null; then printf 'answering'; else printf 'unreachable'; fi
}

provider_storage() {
  log "provider=manual: storage is wherever you put the weights on that machine"
}

provider_create() {
  log "provider=manual — start the engine yourself on the GPU machine:" >&2
  log "" >&2
  log "  1. join the tailnet as tag:gpu, BEFORE the engine listens:" >&2
  log "       tailscale up --authkey=\$TS_AUTHKEY --advertise-tags=tag:gpu --hostname=${TS_HOSTNAME:-gpu} --ssh=false" >&2
  log "  2. run vLLM with:" >&2
  log "       image      ${ENGINE_IMAGE}" >&2
  log "       model      ${MODEL_ID}@${MODEL_REVISION}" >&2
  log "       --api-key  the ENGINE_SECRET in gateway/.env" >&2
  log "       --port 8000, bound so only the tailnet reaches it" >&2
  log "" >&2
  log "  gpu/provision.sh does all of this; copy it to the machine and run it." >&2
  log "  gpu-up.sh will now wait for the engine to answer at $(engine_base)." >&2
  return 0
}

provider_destroy() {
  log "provider=manual — stop the engine yourself on the GPU machine."
  log "gpu-down.sh has already drained in-flight requests, so it is safe to stop now."
}
