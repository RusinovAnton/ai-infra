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

# Optional in the driver contract. A provider that rents by the hour lists what
# is rentable; one that drives hardware you own has nothing to offer.
# Format per line, tab-separated: <id> <vram_gb> <price_per_hr> <stock> <where>
provider_offers() { :; }

# ------------------------------------------------------------ choosing hardware
#
# This is POLICY, and it is deliberately here rather than in a driver: what makes
# a GPU suitable is a property of the model being served, not of whoever rents
# it. A new provider supplies provider_offers() and inherits all of this.
#
#   - GPU_MIN_VRAM_GB on ONE card. The FP8 checkpoint is ~35 GB; splitting it
#     across smaller cards needs tensor parallelism, and consumer cards have no
#     NVLink, so TP crosses PCIe and costs more than the cheaper rate saves.
#   - FP8 tensor cores. Ampere (A100/A40/A6000) has the VRAM and would serve this
#     checkpoint WITHOUT ERRORING, just far slower — the worst failure mode
#     available, since nothing tells you it happened.
#   - CUDA: the pinned engine image is not ROCm, so AMD is excluded by vendor.
#
# ⚠️ FP8 support is NOT knowable from the provider. There is no compute-capability
# field (cudaCores reads 0 for every card), so this matches ARCHITECTURE NAMES,
# which is a heuristic dressed as a rule.
#
# It is therefore an ALLOWLIST, not a denylist, and that direction is the whole
# point: an unrecognised card is excluded rather than silently rented. A denylist
# would have to predict every future Ampere-class part, and would fail by
# renting one — the failure you cannot see. This fails by not renting something
# you could have, which you find out immediately.
#
# FP8 tensor cores start at compute capability 8.9: Ada, Hopper, Blackwell.
# Add a family here when a new one ships; the list is meant to be edited.
GPU_MIN_VRAM_GB="${GPU_MIN_VRAM_GB:-48}"
# L40/L40S are Ada (AD102) but carry no "Ada" in their names — the first version
# of this list excluded them, which is exactly the false negative an allowlist
# produces and why gpu_rejected() prints what was dropped.
GPU_FP8_FAMILIES="${GPU_FP8_FAMILIES:-Ada|Blackwell|L40|H100|H200|H800|B200|B300|GB200|GB300|RTX 40|RTX 50}"

# Suitable offers, cheapest first.
gpu_shortlist() {
  provider_offers | MINV="$GPU_MIN_VRAM_GB" FAM="$GPU_FP8_FAMILIES" MAXP="${GPU_MAX_PRICE:-}" python3 -c "
import sys, os, re
minv = float(os.environ['MINV']); fam = re.compile(os.environ['FAM'])
maxp = float(os.environ['MAXP']) if os.environ.get('MAXP') else None
rows = []
for line in sys.stdin:
    f = line.rstrip('\n').split('\t')
    if len(f) < 4: continue
    gid, mem, price, stock = f[0], f[1], f[2], f[3]
    vendor = f[4] if len(f) > 4 else ''
    where  = f[5] if len(f) > 5 else ''
    try: mem = float(mem); price = float(price)
    except ValueError: continue
    if mem < minv: continue
    if vendor and vendor.lower() not in ('nvidia',): continue   # engine image is CUDA
    if not fam.search(gid): continue                            # allowlist: unknown -> excluded
    if maxp is not None and price > maxp: continue
    rows.append((price, gid, mem, stock, where))
for price, gid, mem, stock, where in sorted(rows):
    print('%s\t%g\t%s\t%s\t%s' % (gid, mem, price, stock, where))
"
}

# What the allowlist threw away, so a card missing from it is discoverable rather
# than invisible. An unrecognised new architecture shows up here, not nowhere.
gpu_rejected() {
  provider_offers | MINV="$GPU_MIN_VRAM_GB" FAM="$GPU_FP8_FAMILIES" python3 -c "
import sys, os, re
minv = float(os.environ['MINV']); fam = re.compile(os.environ['FAM'])
for line in sys.stdin:
    f = line.rstrip('\n').split('\t')
    if len(f) < 4: continue
    gid, mem = f[0], f[1]
    vendor = f[4] if len(f) > 4 else ''
    try: mem = float(mem)
    except ValueError: continue
    if mem < minv: continue
    if vendor and vendor.lower() != 'nvidia': print('%s\t%s' % (gid, 'not CUDA'))
    elif not fam.search(gid):                 print('%s\t%s' % (gid, 'no known FP8 support'))
"
}

show_offers() {
  local n=0 gid mem price stock where
  log "suitable and rentable now (>=${GPU_MIN_VRAM_GB}GB, FP8-capable${GPU_MAX_PRICE:+, <= \$$GPU_MAX_PRICE/hr}):"
  while IFS="$(printf '\t')" read -r gid mem price stock where; do
    n=$((n+1))
    log "  $n) \$$price/hr  ${mem}GB  stock=$stock  $gid"
  done <<EOF
$(gpu_shortlist)
EOF
  [ "$n" = 0 ] && log "  (nothing — lower GPU_MIN_VRAM_GB, raise GPU_MAX_PRICE, or wait)"

  local rid rwhy any=0
  while IFS="$(printf '\t')" read -r rid rwhy; do
    [ -n "$rid" ] || continue
    [ "$any" = 0 ] && { log "excluded, big enough but unsuitable:"; any=1; }
    log "  - $rid ($rwhy)"
  done <<EOF
$(gpu_rejected)
EOF
  [ "$any" = 1 ] && log "  FP8 support is matched by architecture name (GPU_FP8_FAMILIES) — the"
  [ "$any" = 1 ] && log "  provider exposes no capability field. Add a family there if one is missing."
  return 0
}

# Sets GPU_CHOICE, and GPU_SHORTLIST to the whole list it saw (cheapest first,
# one GPU id per line). A driver wanting fallbacks after the chosen card must
# reuse that instead of calling gpu_shortlist() again: provider_offers() is a
# live API call, ~20 s, and is not cached anywhere.
#
# Honours an explicit choice, otherwise takes the cheapest — or asks, when
# --pick was passed AND this is a terminal. It must never block waiting for
# input it cannot receive: gpu-up runs from the scheduler too.
choose_gpu() {
  GPU_CHOICE=""
  GPU_SHORTLIST=""
  case "${GPU_SELECT:-auto}" in
    ""|auto) ;;
    *) GPU_CHOICE="$GPU_SELECT"; log "using the GPU named in the environment: $GPU_CHOICE"; return 0 ;;
  esac

  local list; list="$(gpu_shortlist)"
  [ -n "$list" ] || { show_offers; die "nothing available meeting the constraints"; }
  GPU_SHORTLIST="$(printf '%s\n' "$list" | cut -f1)"

  if [ "${GPU_PICK:-0}" = 1 ] && [ -t 0 ]; then
    show_offers
    printf 'choose [1]: ' >&2
    local n; read -r n </dev/tty || n=""
    [ -n "$n" ] || n=1
    GPU_CHOICE="$(printf '%s\n' "$list" | sed -n "${n}p" | cut -f1)"
    [ -n "$GPU_CHOICE" ] || die "no such option: $n"
  else
    GPU_CHOICE="$(printf '%s\n' "$list" | head -1 | cut -f1)"
  fi

  local row; row="$(printf '%s\n' "$list" | grep -F "$GPU_CHOICE" | head -1)"
  log "GPU: $GPU_CHOICE  ($(printf '%s' "$row" | cut -f2)GB, \$$(printf '%s' "$row" | cut -f3)/hr, stock=$(printf '%s' "$row" | cut -f4))"
}

# ------------------------------------------------------------ portability
#
# These scripts run in two places: on the gateway host, and inside the optional
# scheduler container (gateway/docker-compose.yml, profile `scheduler`). The
# helpers below are the only three things that differ between them.

# The gateway's own API. Loopback on the host; a compose service name in the
# container, where "localhost" is the container itself.
#
# 127.0.0.1, never "localhost": macOS resolves localhost to ::1 first, and the
# container publishes on IPv4 only — so any app listening on the IPv6 wildcard
# (*:4000) silently intercepts every "localhost" request. It happened: a dev
# server answered 404 to eighteen verify checks that then read as the gateway
# being broken.
GW="${GATEWAY_URL:-http://127.0.0.1:4000}"

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

# ------------------------------------------------------- engine host discovery
#
# The node's MagicDNS name is assigned by Tailscale, NOT chosen by us. Ask for
# `gpu` while a stale node still holds that name and the new node silently
# becomes `gpu-1` — so ENGINE_API_BASE keeps pointing at a machine that no
# longer exists, and every symptom looks like "the engine never came up".
#
# Generic on purpose: any provider whose node joins the tailnet as tag:gpu gets
# this, because the failure is Tailscale's naming, not the provider's.
engine_host_on_tailnet() {
  command -v tailscale >/dev/null 2>&1 || return 1
  tailscale status --json 2>/dev/null | python3 -c "
import sys, json
try: d = json.load(sys.stdin)
except Exception: raise SystemExit
names = [ (p.get('DNSName') or '').rstrip('.')
          for p in (d.get('Peer') or {}).values()
          if 'tag:gpu' in (p.get('Tags') or []) and p.get('Online') ]
if len(names) > 1:
    sys.stderr.write('MULTIPLE:' + ','.join(names) + '\n')
if names: print(names[0])
" 2>/dev/null
}

# Rewrites ENGINE_API_BASE when the node came up under a different name, and
# recreates the gateway so LiteLLM actually picks it up (`restart` would reuse
# the old environment).
sync_engine_host() {
  local found current
  found="$(engine_host_on_tailnet || true)"
  [ -n "$found" ] || return 0
  current="$(printf '%s' "${ENGINE_API_BASE:-}" | sed -E 's#^https?://##; s#[:/].*##')"
  [ "$found" = "$current" ] && return 0

  log "the node joined as '$found', but ENGINE_API_BASE points at '$current'"
  log "  (a stale tailnet node holding the name makes Tailscale append -1)"
  ENGINE_API_BASE="http://${found}:8000/v1"
  local tmp; tmp="$(mktemp)"
  sed "s|^ENGINE_API_BASE=.*|ENGINE_API_BASE=${ENGINE_API_BASE}|" "$GATEWAY_DIR/.env" > "$tmp"
  cat "$tmp" > "$GATEWAY_DIR/.env"      # preserves 0600
  rm -f "$tmp"
  export ENGINE_API_BASE
  log "ENGINE_API_BASE -> $ENGINE_API_BASE; recreating the gateway"
  ( cd "$GATEWAY_DIR" && docker compose up -d --force-recreate litellm >/dev/null 2>&1 ) \
    || log "WARNING: could not recreate litellm — do it by hand or it keeps the old engine URL"
}

# The engine, reached the only way anything is allowed to reach it.
engine_base() { printf '%s' "${ENGINE_API_BASE%/v1}"; }

# Did the engine die and leave an explanation on :8000? provision.sh serves a
# 503 with X-Engine-Failed when vLLM exits, so a dead engine is distinguishable
# from one still loading — which is the whole difference between "wait" and
# "stop paying".
engine_failed_detail() {
  # No -f: it suppresses the body on 5xx, and the body IS the diagnosis.
  local h b rc=1
  h="$(mktemp)"; b="$(mktemp)"
  curl -sS -m 8 -D "$h" -o "$b" "$(engine_base)/v1/models" >/dev/null 2>&1
  if grep -qi '^x-engine-failed:' "$h" 2>/dev/null && [ -s "$b" ]; then cat "$b"; rc=0; fi
  rm -f "$h" "$b"
  return $rc
}

engine_ready() {
  curl -fsS -m 10 -o /dev/null \
    -H "Authorization: Bearer ${ENGINE_SECRET:-}" \
    "$(engine_base)/v1/models"
}
