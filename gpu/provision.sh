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

# Leave the tailnet CLEANLY on shutdown. An ephemeral node is only reaped some
# minutes after it goes offline, and until then it squats the MagicDNS name —
# the next pod then joins as gpu-1, gpu-2, ... and the gateway must chase the
# rename. `tailscale logout` removes an ephemeral node IMMEDIATELY, so the name
# is free before gpu-up can possibly relaunch. The platform delivers SIGTERM to
# PID 1 on pod delete, and PID 1 is this script (deliberately — see the engine
# failure-reporting section below), so the trap actually fires.
cleanup() {
  log "shutting down: leaving the tailnet so the node name frees immediately"
  [ -n "${ENGINE_PID:-}" ] && kill "$ENGINE_PID" 2>/dev/null || true
  tailscale logout 2>/dev/null || true
  exit 0
}
trap cleanup TERM INT
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
  --gpu-memory-utilization "${GPU_MEM_UTIL:-0.90}"   # fraction of the WHOLE card, not of what remains
  # Hybrid-attention models (Gated DeltaNet) need one Mamba cache block per
  # concurrent decode sequence, carved from the same memory as KV cache. vLLM's
  # default of 256 sequences does not fit beside a 65k context on 48 GB -- init
  # fails with 'max_num_seqs (256) exceeds available Mamba cache blocks'. 64 is
  # ample for a small team and leaves cache headroom.
  --max-num-seqs "${MAX_NUM_SEQS:-64}"
  --api-key "$ENGINE_SECRET"          # defence in depth; the ACL is the real control
  --no-enable-log-requests            # no prompts on disk, on hardware we do not own
                                      # (was --disable-log-requests; vLLM renamed it to a
                                      #  --enable/--no-enable pair, and an unknown flag is
                                      #  fatal: argparse exits 1, so the container restarts
                                      #  forever while the pod still reports RUNNING)
  --enable-auto-tool-choice
  --tool-call-parser qwen3_coder      # NOT hermes — wrong parser returns prose, silently
  --reasoning-parser qwen3            # required even on the non-thinking alias
)

# Every checkpoint in this family is a vision-language model, and vLLM profiles
# multimodal memory using a dummy image at MAXIMUM resolution. That reservation
# lands directly against KV cache and can exceed the vision tower's own weights,
# so on a 48 GB card it is a plausible cause of "engine core initialization
# failed" with no obvious culprit.
#
# We never send images. Setting this to zero reclaims the reservation.
# Off by default because it can affect whether the chat template applies
# cleanly — verify a normal completion after enabling it.
#
#   VLLM_LIMIT_MM='{"image":0,"video":0}' ./scripts/gpu-up.sh
if [ -n "${VLLM_LIMIT_MM:-}" ]; then
  log "limiting multimodal inputs: $VLLM_LIMIT_MM"
  VLLM_ARGS+=( --limit-mm-per-prompt "$VLLM_LIMIT_MM" )
fi

if command -v docker >/dev/null && docker info >/dev/null 2>&1; then
  log "docker present — starting vLLM via compose"
  cd "$(dirname "$0")"
  VLLM_BIND_HOST="$VLLM_BIND_HOST" HF_HOME="$HF_HOME_HOST" \
  MODEL_ID="$MODEL_ID" MODEL_REVISION="$MODEL_REVISION" \
  MAX_MODEL_LEN="$MAX_MODEL_LEN" TP="$TP" ENGINE_SECRET="$ENGINE_SECRET" \
    docker compose up -d
  log "vLLM starting under compose. Readiness is /v1/models -> 200, NOT tag:gpu online."
else
  log "no docker (container-per-pod provider) — running vLLM in the foreground"
  log "readiness is /v1/models -> 200, NOT tag:gpu appearing online"

  # NOT exec. The engine's exit code is the most valuable diagnostic this system
  # produces, and exec'ing throws it away: vLLM becomes PID 1, dies, the platform
  # restarts the container, and the operator sees an endless "starting" that is
  # indistinguishable from a slow load. Twice now that has cost a GPU-hour and
  # the evidence, because destroying the pod also destroys its logs.
  #
  # So: keep the output, and if the engine dies, SERVE the reason on the one port
  # the gateway is allowed to reach. gpu-up.sh then reports the root cause in
  # seconds instead of polling for thirty minutes at $1/hr.
  set +e
  # Backgrounded + wait, rather than a plain foreground pipeline: bash only runs
  # signal traps between commands, so a foreground vLLM would make the SIGTERM
  # trap wait for the engine to exit on its own — precisely when it must not.
  python3 -m vllm.entrypoints.openai.api_server "${VLLM_ARGS[@]}" > >(tee /tmp/engine.log) 2>&1 &
  ENGINE_PID=$!
  wait "$ENGINE_PID"
  rc=$?
  set -e

  log "ENGINE EXITED rc=$rc — serving the failure on :8000 so it is visible from the gateway"
  RC="$rc" python3 - <<'PYEOF'
import json, os, re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

rc = os.environ.get("RC", "?")
try:
    lines = open("/tmp/engine.log", errors="replace").read().splitlines()
except OSError:
    lines = []

# The wrapper traceback is never the cause — vLLM says "See root cause above".
# Surface the FIRST error-level line. Lessons from a live misfire: "CUDA" as a
# pattern matches `device_config=cuda` inside a giant INFO config line, so
# INFO/DEBUG/WARNING lines are excluded outright, and the pattern requires an
# actual error shape rather than a hardware word.
pat   = re.compile(r"\b[A-Za-z]+Error\b|\bERROR\b|error:|Exception:|OutOfMemory|out of memory|assert(ion)? ?failed", re.I)
info  = re.compile(r"\b(INFO|DEBUG|WARNING)\b")
noise = re.compile(r"raise |Traceback|self\.|return |\^\^\^|File \"|See root cause above")
errs  = [l.strip() for l in lines if pat.search(l) and not info.search(l) and not noise.search(l)]
cause = errs[0] if errs else ""

body = json.dumps({
    "error": "engine_failed_to_start",
    "exit_code": rc,
    "root_cause": cause,
    # Every error-shaped line, not just the first: the EngineCore's real error
    # sits far above the APIServer wrapper, outside any fixed-size tail.
    "error_lines": errs[:20],
    "tail": lines[-40:],
    "hint": "the engine process exited; this is not a slow cold start",
}, indent=2).encode()

class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def do_GET(self):  self._send()
    def do_POST(self): self._send()
    def _send(self):
        self.send_response(503)
        self.send_header("Content-Type", "application/json")
        self.send_header("X-Engine-Failed", "1")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

print("[provision] failure endpoint listening on %s:8000" % os.environ.get("VLLM_BIND_HOST", "0.0.0.0"), flush=True)
ThreadingHTTPServer((os.environ.get("VLLM_BIND_HOST") or "0.0.0.0", 8000), H).serve_forever()
PYEOF
fi
