#!/usr/bin/env bash
# Provision the rented GPU node. Runs ON the node, as root, once per pod.
#
# scripts/gpu-up.sh base64-encodes this file into the pod's env and has the
# pod's entrypoint decode and run it. That keeps provisioning in Git and out of
# a RunPod template that could drift.
#
# Order matters: the tailnet join happens FIRST, because the tag applies at
# registration and the ACL therefore binds before vLLM finishes loading
# weights. There is no window in which the engine is listening but unprotected.
#
# TWO DEPLOYMENT SHAPES, one script:
#   - RunPod (and any container-per-pod provider): the pod IS the container.
#     There is no nested Docker, so vLLM is exec'd directly in the foreground
#     and ../gpu/docker-compose.yml is unused.
#   - A VM provider (one that rents you a whole virtual machine rather than a
#     single container): Docker is available, so the compose file is used and the
#     flags live there.
# The vLLM flags are identical either way; they are built once, below.
set -euo pipefail

log() { printf '[provision %s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { log "FATAL: $*" >&2; exit 1; }

: "${TS_AUTHKEY:?ephemeral tagged auth key required}"
: "${ENGINE_SECRET:?engine api key required}"
: "${MODEL_ID:?}"
: "${MODEL_REVISION:?}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-65536}"
TP="${TP:-1}"
HF_HOME_HOST="${HF_HOME_HOST:-/runpod-volume}"
TS_HOSTNAME="${TS_HOSTNAME:-gpu}"

# ---------------------------------------------------------------- 1. tailnet

log "installing tailscale"
if ! command -v tailscale >/dev/null; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq && apt-get install -y -qq curl ca-certificates iproute2 >/dev/null
  curl -fsSL https://tailscale.com/install.sh | sh
fi
mkdir -p /var/run/tailscale /var/lib/tailscale

# Which mode we get decides where vLLM must bind, so this is not cosmetic.
#
#   TUN present     -> real tailscale0 interface exists; vLLM binds the node's
#                      tailnet address directly.
#   TUN absent      -> userspace networking. There is no interface carrying
#                      100.x.y.z locally, so binding it would fail. tailscaled
#                      itself accepts inbound tailnet connections and forwards
#                      them to 127.0.0.1 on the same port, so vLLM binds
#                      loopback and is still reachable from the gateway — and
#                      only from the tailnet, since loopback is not routable.
if [ -c /dev/net/tun ]; then
  log "TUN available — normal tailscaled"
  tailscaled --state=/var/lib/tailscale/tailscaled.state \
    --socket=/var/run/tailscale/tailscaled.sock >/var/log/tailscaled.log 2>&1 &
  USERSPACE=0
else
  log "no /dev/net/tun — userspace-networking mode (expected on RunPod)"
  tailscaled --tun=userspace-networking \
    --state=/var/lib/tailscale/tailscaled.state \
    --socket=/var/run/tailscale/tailscaled.sock >/var/log/tailscaled.log 2>&1 &
  USERSPACE=1
fi
sleep 3

log "joining tailnet as tag:gpu"
# --ssh=false: administration is over the tailnet with an operator's own
#   credentials, not via a Tailscale SSH grant on untrusted hardware.
# --advertise-tags: the tag is what the ACL binds to. Without it the device is
#   untagged and the `Tags` field is *absent*, not empty — a rule targeting
#   tag:gpu then matches nothing and the gateway cannot connect.
# No --advertise-routes and no --advertise-exit-node, ever: either would turn
#   this rented box into a path into or out of the tailnet.
# NOT --shields-up: it blocks incoming tailnet connections, and the gateway
#   reaching :8000 IS an incoming connection. Egress confinement comes from the
#   ACL's default-deny (no src tag:gpu grant exists), not from shields.
tailscale up \
  --ssh=false \
  --advertise-tags=tag:gpu \
  --hostname="${TS_HOSTNAME}" \
  --accept-dns=true \
  --auth-key="${TS_AUTHKEY}"

TS_IP="$(tailscale ip -4 || true)"
[ -n "$TS_IP" ] || die "no tailnet IPv4 — join failed (auth key expired, or tag not pre-approved in tagOwners?)"
if [ "$USERSPACE" = "1" ]; then VLLM_BIND_HOST=127.0.0.1; else VLLM_BIND_HOST="$TS_IP"; fi
log "tailnet address ${TS_IP}; vLLM will bind ${VLLM_BIND_HOST}"

# A relayed connection would put every prompt and every generated token through
# a DERP hop on the hottest path in the system. This failure hides rather than
# announcing itself, so check from both ends — here and on the gateway.
log "peer status (the gateway must read 'direct', not 'relay'):"
tailscale status || true

# ---------------------------------------------------------------- 2. provenance

log "checking model provenance for ${MODEL_ID}@${MODEL_REVISION}"
meta="$(curl -fsS "https://huggingface.co/api/models/${MODEL_ID}?revision=${MODEL_REVISION}")" \
  || die "cannot fetch model metadata — wrong id or revision?"

author="$(printf '%s' "$meta" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("author",""))')"
[ "$author" = "Qwen" ] || die "publishing org is '${author}', expected 'Qwen' — refusing to download"

sha="$(printf '%s' "$meta" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("sha",""))')"
[ "$sha" = "$MODEL_REVISION" ] || die "resolved sha ${sha} != pinned ${MODEL_REVISION}"

# safetensors only. A .bin or .pth file is pickle, which executes code at load.
bad="$(printf '%s' "$meta" | python3 -c '
import sys,json
f=[s["rfilename"] for s in json.load(sys.stdin).get("siblings",[])]
print(" ".join(x for x in f if x.endswith((".bin",".pth",".pkl",".pickle"))))')"
[ -z "$bad" ] || die "non-safetensors weight files present: ${bad}"
log "provenance OK: org=Qwen, revision matches pin, safetensors only"

# ---------------------------------------------------------------- 3. weights

mkdir -p "$HF_HOME_HOST"
export HF_HOME="$HF_HOME_HOST"
export HF_HUB_ENABLE_HF_TRANSFER=1
log "fetching weights into the persistent volume (${HF_HOME_HOST}) — cached after the first pod"
pip install -q --no-input "huggingface_hub[hf_transfer]" >/dev/null 2>&1 || true
python3 - <<PY
import os
from huggingface_hub import snapshot_download
p = snapshot_download(
    "${MODEL_ID}",
    revision="${MODEL_REVISION}",
    cache_dir=os.environ["HF_HOME"],
    allow_patterns=["*.safetensors","*.json","*.txt","*.py","*.jinja"],
)
print("weights at", p)
PY

# ---------------------------------------------------------------- 4. engine

# Single source of truth for the flags. See gpu/docker-compose.yml for why each
# one is here; the two must not drift.
VLLM_ARGS=(
  --model "$MODEL_ID"
  --revision "$MODEL_REVISION"        # byte-identical weights on every rebuild
  --served-model-name coder
  --host "$VLLM_BIND_HOST"            # never 0.0.0.0
  --port 8000
  --tensor-parallel-size "$TP"
  --max-model-len "$MAX_MODEL_LEN"
  --gpu-memory-utilization 0.90       # fraction of the WHOLE card, not of what remains
  --api-key "$ENGINE_SECRET"          # defence in depth; the ACL is the real control
  --disable-log-requests              # no prompts on disk, on hardware we do not own
  --enable-auto-tool-choice
  --tool-call-parser qwen3_coder      # NOT hermes — wrong parser returns prose, silently
  --reasoning-parser qwen3            # required even on the non-thinking alias
)

if command -v docker >/dev/null && docker info >/dev/null 2>&1; then
  log "docker present — starting vLLM via compose"
  cd "$(dirname "$0")"
  VLLM_BIND_HOST="$VLLM_BIND_HOST" HF_HOME="$HF_HOME_HOST" \
  MODEL_ID="$MODEL_ID" MODEL_REVISION="$MODEL_REVISION" \
  MAX_MODEL_LEN="$MAX_MODEL_LEN" TP="$TP" ENGINE_SECRET="$ENGINE_SECRET" \
    docker compose up -d
  log "vLLM starting under compose. Readiness is /v1/models -> 200, NOT tag:gpu online."
else
  log "no docker (container-per-pod provider) — exec'ing vLLM in the foreground"
  log "readiness is /v1/models -> 200, NOT tag:gpu appearing online"
  # exec so vLLM is PID 1's child and the pod dies with the engine rather than
  # sitting alive with nothing listening.
  exec python3 -m vllm.entrypoints.openai.api_server "${VLLM_ARGS[@]}"
fi
