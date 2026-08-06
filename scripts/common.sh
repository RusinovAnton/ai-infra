#!/usr/bin/env bash
# Shared helpers for the lifecycle scripts. Sourced, not executed.
# shellcheck shell=bash

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATEWAY_DIR="$REPO_ROOT/gateway"
SCRIPTS_DIR="$REPO_ROOT/scripts"

log()  { printf '[%s %s] %s\n' "$(basename "${0}")" "$(date -u +%H:%M:%S)" "$*"; }
die()  { printf '[%s] FATAL: %s\n' "$(basename "${0}")" "$*" >&2; exit 1; }

load_env() {
  # scripts/.env holds provider credentials; gateway/.env holds gateway secrets.
  # Kept apart so the office server can run the gateway without ever holding a
  # RunPod API key that can create billable instances.
  [ -f "$SCRIPTS_DIR/.env" ] || die "missing $SCRIPTS_DIR/.env — copy .env.example"
  set -a; . "$SCRIPTS_DIR/.env"; set +a
  [ -f "$GATEWAY_DIR/.env" ] && { set -a; . "$GATEWAY_DIR/.env"; set +a; }
  : "${RUNPOD_API_KEY:?set in scripts/.env}"
}

RP="https://rest.runpod.io/v1"

rp() { # rp METHOD PATH [JSON_BODY]
  local method="$1" path="$2" body="${3:-}"
  if [ -n "$body" ]; then
    curl -sS -m 120 -X "$method" "$RP$path" \
      -H "Authorization: Bearer $RUNPOD_API_KEY" \
      -H 'Content-Type: application/json' -d "$body"
  else
    curl -sS -m 120 -X "$method" "$RP$path" \
      -H "Authorization: Bearer $RUNPOD_API_KEY"
  fi
}

# Exported, not just assigned: gpu-up.sh builds the pod request in an inline
# python3 that reads this from os.environ. Everything else it needs comes from
# `set -a; . .env`, which auto-exports — this one is defined here, so without an
# explicit export the JSON build dies with KeyError: 'POD_NAME'.
export POD_NAME="${POD_NAME:-ai-infra-gpu}"

# Empty output means no such pod. Callers must treat "not found" and "found but
# stopped" differently — a stopped pod still bills its container disk.
find_pod_id() {
  rp GET "/pods" | python3 -c "
import sys,json
try: pods=json.load(sys.stdin)
except Exception: sys.exit(0)
pods = pods if isinstance(pods,list) else pods.get('data',[]) or pods.get('pods',[])
for p in pods:
    if p.get('name')=='$POD_NAME': print(p['id']); break
"
}

pod_field() { # pod_field POD_ID FIELD
  rp GET "/pods/$1" | python3 -c "
import sys,json
d=json.load(sys.stdin)
v=d.get('$2')
print('' if v is None else (json.dumps(v) if isinstance(v,(dict,list)) else v))
"
}

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
