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

# The engine, reached the only way anything is allowed to reach it.
engine_base() { printf '%s' "${ENGINE_API_BASE%/v1}"; }

engine_ready() {
  curl -fsS -m 10 -o /dev/null \
    -H "Authorization: Bearer ${ENGINE_SECRET:-}" \
    "$(engine_base)/v1/models"
}
