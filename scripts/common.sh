#!/usr/bin/env bash
# Shared helpers for the lifecycle scripts. Sourced, not executed.
# shellcheck shell=bash

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATEWAY_DIR="$REPO_ROOT/gateway"
SCRIPTS_DIR="$REPO_ROOT/scripts"

log()  { printf '[%s %s] %s\n' "$(basename "${0}")" "$(date -u +%H:%M:%S)" "$*"; }
die()  { printf '[%s] FATAL: %s\n' "$(basename "${0}")" "$*" >&2; exit 1; }

# Exported, not just assigned: drivers build their request in an inline python3
# that reads this from os.environ. Without an explicit export the JSON build
# dies with KeyError: 'NODE_NAME'.
export NODE_NAME="${NODE_NAME:-${POD_NAME:-ai-infra-gpu}}"

# The engine image, here rather than in a driver: every provider must run the
# same one, or the rented and owned paths stop being comparable.
export ENGINE_IMAGE="${ENGINE_IMAGE:-vllm/vllm-openai@sha256:770fe65b2c73ee74a5c42165cf3433de4048cc2cd9c57a937ca4e35aba5aa87b}"

load_env() {
  # scripts/.env holds provider credentials; gateway/.env holds gateway secrets.
  # Kept apart so a host can run the gateway without ever holding a credential
  # that creates billable instances. (The scheduler container is the deliberate
  # exception — see docs/design-notes.md.)
  [ -f "$SCRIPTS_DIR/.env" ] || die "missing $SCRIPTS_DIR/.env — copy .env.example"
  set -a; . "$SCRIPTS_DIR/.env"; set +a
  [ -f "$GATEWAY_DIR/.env" ] && { set -a; . "$GATEWAY_DIR/.env"; set +a; }

  # ---------------------------------------------------------- provider driver
  #
  # Exactly one driver is loaded. Nothing outside scripts/providers/ may name a
  # provider — that is what keeps "swap the GPU supplier" a one-line change
  # rather than an audit of every script.
  GPU_PROVIDER="${GPU_PROVIDER:-runpod}"
  local drv="$SCRIPTS_DIR/providers/${GPU_PROVIDER}.sh"
  [ -f "$drv" ] || die "unknown GPU_PROVIDER='$GPU_PROVIDER' — available: $(cd "$SCRIPTS_DIR/providers" && ls -1 *.sh 2>/dev/null | sed 's/\.sh$//' | tr '\n' ' ')"
  # shellcheck disable=SC1090
  . "$drv"

  : "${PROVIDER_KIND:?driver $GPU_PROVIDER must set PROVIDER_KIND}"

  provider_preflight
}

# A placeholder is not a value. `${VAR:?}` only catches empty or unset, so an
# untouched CHANGE-ME sails through every guard and fails much later, as a
# provider API error about an id that never existed.
#
# Deliberately NOT called from load_env, for two reasons that both bite:
#   - `gpu-up.sh --create-storage` exists to PRODUCE the value that is still a
#     placeholder. Guarding it there makes the fix unreachable.
#   - gpu-down.sh and idle-check.sh must never be blocked by configuration.
#     Refusing to stop a running node because some unrelated field is unfilled
#     turns a cosmetic problem into an unbounded bill.
# So only the paths that CREATE something call this.
check_placeholders() {
  local names
  # `|| true` is load-bearing: grep exits 1 when it matches nothing, pipefail
  # propagates that, and set -e then kills the script — silently, because here
  # "no matches" is the SUCCESS case. Without it this function aborts every
  # caller precisely when the config is correct.
  names="$(grep -hE '^[A-Z_]+=CHANGE-ME[[:space:]]*$' "$SCRIPTS_DIR/.env" "$GATEWAY_DIR/.env" 2>/dev/null | cut -d= -f1 | tr '\n' ' ' || true)"
  [ -z "$names" ] || die "unfilled placeholder(s): ${names}— set them in scripts/.env (or gateway/.env) before running this"
}

# A node that costs money by the hour should be destroyed when idle; one you own
# should only ever be stopped. Callers branch on this rather than on the
# provider's name.
provider_is_ephemeral() { [ "${PROVIDER_KIND:-}" = ephemeral ]; }

# Optional in the driver contract: hardware you own has no "capacity" to check.
provider_capacity() { log "provider '$GPU_PROVIDER' has no capacity concept — the machine either exists or it does not"; return 0; }

# ------------------------------------------------------------ portability
#
# These scripts run in two places: on the gateway host, and inside the optional
# scheduler container (gateway/docker-compose.yml, profile `scheduler`). The
# helpers below are the only three things that differ between them.

# The gateway's own API. Loopback on the host; a compose service name in the
# container, where "localhost" is the container itself.
GW="${GATEWAY_URL:-http://localhost:4000}"

# macOS ships shasum, Debian ships sha256sum, and the scheduler image is Debian.
sha256_hex() { # reads stdin, prints the hex digest
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1
  else shasum -a 256 | cut -d' ' -f1
  fi
}

# Postgres client access to the gateway database.
#
# Two paths, deliberately. On the host, `docker compose exec` needs no password
# on the wire and no published port. Inside the scheduler container there is no
# Docker socket — mounting one would hand a container that also holds
# RUNPOD_API_KEY root-equivalent control of the host's Docker daemon — so it
# connects over the compose network instead, selected by PGHOST being set.
#
# The same arguments work either way: -U and -d are ordinary client flags, while
# host and password come from the environment.
pgx() { # pgx PROGRAM [ARGS...]
  if [ -n "${PGHOST:-}" ]; then
    PGPASSWORD="${LITELLM_DB_PASS:?set in gateway/.env}" "$@"
  else
    ( cd "$GATEWAY_DIR" && docker compose exec -T litellm-db "$@" )
  fi
}

# The engine, reached the only way anything is allowed to reach it.
engine_base() { printf '%s' "${ENGINE_API_BASE%/v1}"; }

engine_ready() {
  curl -fsS -m 10 -o /dev/null \
    -H "Authorization: Bearer ${ENGINE_SECRET:-}" \
    "$(engine_base)/v1/models"
}
