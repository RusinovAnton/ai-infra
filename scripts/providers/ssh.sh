#!/usr/bin/env bash
# GPU_PROVIDER=ssh — a GPU machine you already have.
# shellcheck shell=bash
#
# Your own hardware, a colocated box, or a VPS rented by the month. Anything
# with a GPU, Docker, the NVIDIA container runtime, and an SSH login.
#
# PERSISTENT, so `down` STOPS the engine and never destroys the machine. Idle
# shutdown still runs — it frees VRAM and power — but nothing here can lose you
# a box, which is the difference that matters against the rented case.
#
# Reuses gpu/docker-compose.yml, so the vLLM flags are the same file the rented
# path uses. They cannot drift apart.
#
# Required in scripts/.env:
#   GPU_SSH_HOST=gpu-box            (a tailnet name is ideal — no public SSH)
#   GPU_SSH_USER=ubuntu
# Optional:
#   GPU_SSH_KEY=~/.ssh/id_ed25519
#   GPU_SSH_DIR=/opt/ai-infra       (where the compose project lives on the box)

PROVIDER_KIND=persistent
PROVIDER_INJECTS_SECRET=1
PROVIDER_BILLS_IDLE="the machine itself keeps costing whatever it costs — stopping the engine frees VRAM and power, not rent"

GPU_SSH_DIR="${GPU_SSH_DIR:-/opt/ai-infra}"

_ssh() {
  local key=()
  [ -n "${GPU_SSH_KEY:-}" ] && key=(-i "$GPU_SSH_KEY")
  ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "${key[@]}" \
      "${GPU_SSH_USER}@${GPU_SSH_HOST}" "$@"
}

provider_preflight() {
  : "${GPU_SSH_HOST:?set in scripts/.env}"
  : "${GPU_SSH_USER:?set in scripts/.env}"
  command -v ssh >/dev/null || die "ssh not found on this host"
  _ssh true 2>/dev/null || die "cannot ssh to ${GPU_SSH_USER}@${GPU_SSH_HOST} — check the key, the host, and that it is on the tailnet"
}

# The compose project is the node. Its id is the container id, so "exists" and
# "running" mean the same thing they do for a pod.
provider_find() {
  _ssh "cd '$GPU_SSH_DIR' 2>/dev/null && docker compose ps -q 2>/dev/null | head -1" 2>/dev/null || true
}

provider_status() { # provider_status ID
  _ssh "docker inspect -f '{{.State.Status}}' '$1' 2>/dev/null" 2>/dev/null || true
}

provider_storage() {
  # Weights live on the box's own disk. Nothing to rent, nothing billing when
  # idle — the single biggest operational difference from the rented path.
  log "provider=ssh keeps weights on the machine's own disk at $GPU_SSH_DIR/hf-cache"
  log "nothing to create; ensure that filesystem has ~100 GB free"
  _ssh "df -h '$GPU_SSH_DIR' 2>/dev/null || df -h /" 2>/dev/null || true
}

provider_create() {
  : "${TS_AUTHKEY:?set in scripts/.env}"

  if [ "${MODE:-run}" = dry ]; then
    log "dry run — would rsync gpu/ to ${GPU_SSH_USER}@${GPU_SSH_HOST}:$GPU_SSH_DIR and run:" >&2
    log "  docker compose up -d   (image ${ENGINE_IMAGE}, model ${MODEL_ID}@${MODEL_REVISION})" >&2
    return 0
  fi

  log "syncing gpu/ to ${GPU_SSH_USER}@${GPU_SSH_HOST}:$GPU_SSH_DIR" >&2
  _ssh "mkdir -p '$GPU_SSH_DIR'"
  local key=()
  [ -n "${GPU_SSH_KEY:-}" ] && key=(-i "$GPU_SSH_KEY")
  tar -C "$REPO_ROOT" -cf - gpu \
    | _ssh "tar -C '$GPU_SSH_DIR' --strip-components=1 -xf -"

  # The engine's environment. Written 0600 on the far side and never echoed.
  _ssh "cat > '$GPU_SSH_DIR/.env' && chmod 600 '$GPU_SSH_DIR/.env'" <<EOF
TS_AUTHKEY=${TS_AUTHKEY}
TS_HOSTNAME=${TS_HOSTNAME:-gpu}
ENGINE_SECRET=${ENGINE_SECRET}
ENGINE_IMAGE=${ENGINE_IMAGE}
MODEL_ID=${MODEL_ID}
MODEL_REVISION=${MODEL_REVISION}
MAX_MODEL_LEN=${MAX_MODEL_LEN:-65536}
TP=${TP:-1}
HF_HOME_HOST=${GPU_SSH_DIR}/hf-cache
EOF

  log "starting the engine on ${GPU_SSH_HOST}" >&2
  _ssh "cd '$GPU_SSH_DIR' && docker compose up -d" >&2 \
    || die "docker compose up failed on ${GPU_SSH_HOST} — check Docker and the NVIDIA container runtime there"

  provider_find
}

provider_destroy() { # provider_destroy ID
  # `down`, never anything destructive to the host. On hardware you own, the
  # cost of a wrong shutdown is minutes; the cost of a wrong deletion is a
  # rebuild. The asymmetry is the whole reason PROVIDER_KIND exists.
  log "stopping the engine on ${GPU_SSH_HOST} (the machine itself is untouched)"
  _ssh "cd '$GPU_SSH_DIR' && docker compose down" >/dev/null 2>&1 \
    || die "could not stop the engine on ${GPU_SSH_HOST} — check it by hand before assuming it is down"
}
