#!/usr/bin/env bash
# Start the inference node. This is the command a developer runs when they hit
# the "inference node is stopped" 503, so it has to be a one-liner and it has to
# say what is happening while it waits.
#
#   ./gpu-up.sh                   bring the node up and wait for the engine
#   ./gpu-up.sh --create-storage  one-time storage setup, if the provider needs it
#   ./gpu-up.sh --check-capacity  is the GPU actually available? costs nothing
#   ./gpu-up.sh --dry-run         print what would be created, spending nothing
#
# Provider-agnostic. Which hardware this talks to is GPU_PROVIDER in
# scripts/.env; see scripts/providers/README.md.
set -euo pipefail
. "$(dirname "$0")/common.sh"
load_env

MODE=run
case "${1:-}" in
  --create-storage|--create-volume) MODE=storage ;;   # --create-volume kept working
  --check-capacity)                 MODE=capacity ;;
  --dry-run)                        MODE=dry ;;
  "")                               ;;
  *)                                die "unknown argument: $1" ;;
esac
export MODE

# ------------------------------------------------------------ storage

if [ "$MODE" = capacity ]; then
  provider_capacity || die "no capacity in any configured datacenter — widen RUNPOD_DATACENTERS or wait"
  exit 0
fi

if [ "$MODE" = storage ]; then
  provider_storage
  exit 0
fi

# Everything below creates something, so the config must be complete. The
# storage branch above deliberately runs before this: it is how you fill in the
# value this check demands.
check_placeholders

# ------------------------------------------------------------ idempotence

existing="$(provider_find || true)"
if [ -n "$existing" ]; then
  log "node $NODE_NAME already exists (id=$existing, status=$(provider_status "$existing"))"
  if engine_ready 2>/dev/null; then
    log "engine already answering at $(engine_base) — nothing to do"
    exit 0
  fi
  log "node exists but the engine is not answering yet; waiting rather than creating a second one"
else
  # ------------------------------------------------------------ rotate secret
  #
  # The engine secret has to reach a machine that is rebuilt nightly, and every
  # route to it writes the value into provider instance metadata — on the exact
  # host named as the threat in the trust model. Rather than building the
  # fetch-over-tailnet dance on day one, treat the secret as low value (the ACL
  # is the real control) and rotate it on every launch, so what sits in metadata
  # is a credential that dies with the pod.
  if [ "$MODE" != dry ] && [ "${PROVIDER_INJECTS_SECRET:-0}" = 1 ]; then
    NEW_SECRET="$(openssl rand -hex 24)"
    log "rotating ENGINE_SECRET (it will be written into pod metadata; short-lived by design)"
    tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
    sed "s|^ENGINE_SECRET=.*|ENGINE_SECRET=${NEW_SECRET}|" "$GATEWAY_DIR/.env" > "$tmp"
    grep -q '^ENGINE_SECRET=' "$tmp" || printf 'ENGINE_SECRET=%s\n' "$NEW_SECRET" >> "$tmp"
    cat "$tmp" > "$GATEWAY_DIR/.env"          # preserves 0600 on the original
    ENGINE_SECRET="$NEW_SECRET"
    # LiteLLM reads ENGINE_SECRET from the environment at start, so the gateway
    # has to be recreated — `restart` keeps the old environment.
    ( cd "$GATEWAY_DIR" && docker compose up -d --force-recreate litellm >/dev/null 2>&1 ) \
      || log "WARNING: could not recreate the litellm container — do it by hand or the gateway will use the old secret"
  elif [ "$MODE" != dry ]; then
    # Rotating a secret the driver cannot deliver would break the engine rather
    # than secure it: the gateway would present a value the node never received.
    log "provider '$GPU_PROVIDER' cannot deliver a secret to the node — keeping the current ENGINE_SECRET"
    log "  rotate it by hand on both sides when you need to (docs/gateway-admin.md)"
  fi

  # ------------------------------------------------------------ create node

  node_id="$(provider_create)"
  [ "$MODE" = dry ] && exit 0
  log "node created: ${node_id:-<no id reported>}"
fi

# ------------------------------------------------------------ wait for ready

# tag:gpu appearing online is NOT readiness — weights still have to load from
# the volume into VRAM. The only honest readiness signal is the engine
# answering, through the tailnet, which is the only path that is allowed.
log "waiting for the engine at $(engine_base) (cold start is minutes, not seconds)"
deadline=$(( $(date +%s) + 1800 ))
until engine_ready 2>/dev/null; do
  if [ "$(date +%s)" -ge "$deadline" ]; then
    log "engine did not answer within 30 min. Check, in this order:"
    log "  1. tailscale status        — is the node online and 'direct', not 'relay'?"
    log "  2. the node's own logs     — auth key expired? tag not in tagOwners?"
    log "  3. KV-cache profiling line — ~262 KB/token means vLLM took the generic"
    log "     attention path instead of the hybrid one, and the whole context"
    log "     sizing is void — see docs/design-notes.md"
    die "timed out waiting for the engine"
  fi
  printf '.'
  sleep 15
done
printf '\n'

log "engine ready. Confirming the tailnet path is direct, not relayed:"
# A DERP fallback silently costs every prompt and every token a relay hop. It
# announces itself only here.
if tailscale status 2>/dev/null | grep -q "$NODE_NAME\|gpu"; then
  tailscale status 2>/dev/null | grep -iE 'gpu' || true
  tailscale status 2>/dev/null | grep -iE 'gpu.*relay' >/dev/null \
    && log "WARNING: relayed connection — UDP 41641/3478 blocked outbound. Every token takes a relay hop." \
    || log "path looks direct"
else
  log "note: could not read tailscale status from here — check manually"
fi

log "done. Aliases 'coder' and 'coder-max' are live on the gateway."
