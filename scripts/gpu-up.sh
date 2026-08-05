#!/usr/bin/env bash
# Start the inference node. This is the command a developer runs when they hit
# the "inference node is stopped" 503, so it has to be a one-liner and it has to
# say what is happening while it waits.
#
#   ./gpu-up.sh                  create the pod and wait for the engine
#   ./gpu-up.sh --create-volume  one-time: create the 200 GB network volume
#   ./gpu-up.sh --dry-run        print the pod request without spending anything
set -euo pipefail
. "$(dirname "$0")/common.sh"
load_env

MODE=run
case "${1:-}" in
  --create-volume) MODE=volume ;;
  --dry-run)       MODE=dry ;;
  "")              ;;
  *)               die "unknown argument: $1" ;;
esac

# ------------------------------------------------------------ network volume

if [ "$MODE" = volume ]; then
  dc="${RUNPOD_DATACENTERS%%,*}"
  log "creating a 200 GB network volume in $dc"
  # Sized for the primary (~35 GB) plus the Qwen3.6-27B A/B (~54 GB). The volume
  # is pinned to one datacenter and bills continuously, pod or no pod.
  rp POST /networkvolumes "$(python3 -c "
import json;print(json.dumps({'name':'ai-infra-weights','dataCenterId':'$dc','size':200}))")" \
    | python3 -m json.tool
  log "put the returned id in scripts/.env as RUNPOD_VOLUME_ID"
  exit 0
fi

: "${RUNPOD_VOLUME_ID:?set in scripts/.env — run ./gpu-up.sh --create-volume first}"
: "${TS_AUTHKEY:?set in scripts/.env}"

# ------------------------------------------------------------ idempotence

existing="$(find_pod_id || true)"
if [ -n "$existing" ]; then
  status="$(pod_field "$existing" desiredStatus)"
  log "pod $POD_NAME already exists (id=$existing, status=$status)"
  if engine_ready 2>/dev/null; then
    log "engine already answering at $(engine_base) — nothing to do"
    exit 0
  fi
  log "pod exists but the engine is not answering yet; waiting rather than creating a second one"
else
  # ------------------------------------------------------------ rotate secret
  #
  # The engine secret has to reach a machine that is rebuilt nightly, and every
  # route to it writes the value into provider instance metadata — on the exact
  # host named as the threat in the trust model. Rather than building the
  # fetch-over-tailnet dance on day one, treat the secret as low value (the ACL
  # is the real control) and rotate it on every launch, so what sits in metadata
  # is a credential that dies with the pod.
  if [ "$MODE" != dry ]; then
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
  fi

  # ------------------------------------------------------------ create pod

  # provision.sh travels in the pod's env, base64-encoded, so the node is built
  # from what is in Git rather than from a RunPod template that can drift.
  PROVISION_B64="$(base64 < "$REPO_ROOT/gpu/provision.sh" | tr -d '\n')"

  body="$(PROVISION_B64="$PROVISION_B64" python3 -c "
import json, os
env = {
    'PROVISION_B64':  os.environ['PROVISION_B64'],
    'TS_AUTHKEY':     os.environ['TS_AUTHKEY'],
    'TS_HOSTNAME':    'gpu',
    'ENGINE_SECRET':  os.environ['ENGINE_SECRET'],
    'MODEL_ID':       os.environ['MODEL_ID'],
    'MODEL_REVISION': os.environ['MODEL_REVISION'],
    'MAX_MODEL_LEN':  os.environ.get('MAX_MODEL_LEN','65536'),
    'TP':             os.environ.get('TP','1'),
    'HF_HOME_HOST':   '/runpod-volume',
}
print(json.dumps({
    'name':               os.environ['POD_NAME'],
    # SECURE, never COMMUNITY. The names are near-identical and the trust models
    # are opposite: on Community Cloud the host has root on your machine.
    'cloudType':          'SECURE',
    'computeType':        'GPU',
    'gpuTypeIds':         [os.environ['RUNPOD_GPU_TYPE']],
    'gpuTypePriority':    'custom',
    'gpuCount':           int(os.environ.get('GPU_COUNT','1')),
    'dataCenterIds':      os.environ['RUNPOD_DATACENTERS'].split(','),
    'dataCenterPriority': 'custom',
    'networkVolumeId':    os.environ['RUNPOD_VOLUME_ID'],
    'volumeMountPath':    '/runpod-volume',
    'containerDiskInGb':  60,
    'imageName':          'vllm/vllm-openai@sha256:770fe65b2c73ee74a5c42165cf3433de4048cc2cd9c57a937ca4e35aba5aa87b',
    # No published ports and no public IP. Reachability comes from the tailnet
    # only; the engine socket does not exist on any public interface.
    'ports':              [],
    'supportPublicIp':    False,
    # Override the image's entrypoint (which is the API server) so provisioning
    # runs first: tailnet join, provenance check, weights, then exec vLLM.
    'dockerEntrypoint':   ['bash','-lc',
                           'set -e; echo \"\$PROVISION_B64\" | base64 -d > /provision.sh; exec bash /provision.sh'],
    'dockerStartCmd':     [],
    'env':                env,
    'interruptible':      False,
    'minVCPUPerGPU':      8,
    'minRAMPerGPU':       32,
}, indent=2))
")"

  if [ "$MODE" = dry ]; then
    log "dry run — pod request below, nothing created (secrets redacted)"
    printf '%s\n' "$body" | python3 -c "
import sys,json
d=json.load(sys.stdin)
for k in ('TS_AUTHKEY','ENGINE_SECRET','PROVISION_B64'):
    if k in d['env']: d['env'][k]='<redacted %d chars>' % len(d['env'][k])
print(json.dumps(d,indent=2))"
    exit 0
  fi

  log "creating pod: ${GPU_COUNT:-1} × ${RUNPOD_GPU_TYPE} in ${RUNPOD_DATACENTERS}"
  resp="$(rp POST /pods "$body")"
  pod_id="$(printf '%s' "$resp" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("id",""))' 2>/dev/null || true)"
  if [ -z "$pod_id" ]; then
    printf '%s\n' "$resp" >&2
    # On-demand capacity is not contractual. This is the single biggest
    # availability difference from bare metal, and it fails at the least
    # convenient moment.
    die "pod creation failed. If this is a capacity error, try the next region in RUNPOD_DATACENTERS (note: the network volume is pinned to one datacenter, so a different region means re-downloading weights)."
  fi
  log "pod created: $pod_id"
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
    log "  2. RunPod pod logs         — auth key expired? tag not in tagOwners?"
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
if tailscale status 2>/dev/null | grep -q "$POD_NAME\|gpu"; then
  tailscale status 2>/dev/null | grep -iE 'gpu' || true
  tailscale status 2>/dev/null | grep -iE 'gpu.*relay' >/dev/null \
    && log "WARNING: relayed connection — UDP 41641/3478 blocked outbound. Every token takes a relay hop." \
    || log "path looks direct"
else
  log "note: could not read tailscale status from here — check manually"
fi

log "done. Aliases 'coder' and 'coder-max' are live on the gateway."
