#!/usr/bin/env bash
# GPU_PROVIDER=runpod — rented on-demand pods.
# shellcheck shell=bash
#
# Rented hardware you do not control, billed by the hour, destroyed when idle.
# The host operator can read VRAM; the tailnet ACL and a short-lived engine
# secret are what keep the blast radius small. See docs/design-notes.md.

PROVIDER_KIND=ephemeral
PROVIDER_INJECTS_SECRET=1
# Only a network volume outlives the pod, and there is none by default.
if [ -n "${RUNPOD_VOLUME_ID:-}" ]; then
  PROVIDER_BILLS_IDLE="the weights volume still bills while no pod exists"
else
  PROVIDER_BILLS_IDLE="nothing persists, nothing bills"
fi

RP="${RUNPOD_API_BASE:-https://rest.runpod.io/v1}"

# Capacity lives on the GraphQL API only. The REST API exposes no GPU-type and
# no datacenter endpoint at all — every path 400s with "does not exist in the
# specification" — so this is not a stylistic choice. Requires the API key to
# have the api.runpod.io/graphql scope enabled.
RP_GQL="${RUNPOD_GRAPHQL:-https://api.runpod.io/graphql}"

# ONE default, exported, because both the pod request and the messages that
# report what was requested read it. They disagreed once — the request sent
# '13.0' while the failure message named '12.8,13.0' — which sent us looking at
# a filter that had never been applied. `export`: the driver is sourced after
# load_env's `set -a`, so a plain assignment would not reach python.
export RUNPOD_CUDA_VERSIONS="${RUNPOD_CUDA_VERSIONS:-13.0}"

# rp_stock DATACENTER [GPU_ID] -> "<stockStatus> <price>", e.g. "Low 0.99" / "None -"
#
# GPU_ID is explicit rather than read from $RUNPOD_GPU_TYPE, because that may
# hold the sentinel "auto", which is not a gpuTypeId. Asking the provider about
# "auto" answers "no capacity" for every datacenter — a free check that reports
# nothing available while --list-gpus shows stock.
rp_stock() {
  local dc="$1" gpu="${2:-$RUNPOD_GPU_TYPE}" body
  body="$(printf '{"query":"query($id:String!,$dc:String){ gpuTypes(input:{id:$id}) { lowestPrice(input:{gpuCount:%d,dataCenterId:$dc,secureCloud:true}) { stockStatus uninterruptablePrice } } }","variables":{"id":"%s","dc":"%s"}}' \
      "${GPU_COUNT:-1}" "$gpu" "$dc")"
  curl -sS -m 30 -X POST "$RP_GQL" \
    -H "Authorization: Bearer $RUNPOD_API_KEY" -H 'Content-Type: application/json' \
    -d "$body" 2>/dev/null | python3 -c "
import sys, json
try:
    lp = json.load(sys.stdin)['data']['gpuTypes'][0]['lowestPrice']
except Exception:
    print('unknown -'); raise SystemExit
st = lp.get('stockStatus') or 'None'
pr = lp.get('uninterruptablePrice')
print('%s %s' % (st, '-' if pr is None else pr))
" 2>/dev/null || printf 'unknown -'
}

# Returns 0 if at least one configured datacenter has stock. Prints a report.
#
# "auto" is resolved to the same shortlist a launch would try, not passed through
# as a gpu id. The check costs nothing and is the one people run BEFORE deciding
# whether to launch, so answering "no capacity anywhere" when eight datacenters
# hold stock is the most expensive kind of wrong this file can be.
provider_capacity() {
  local dc st pr any=1 gpu gpus
  case "$(rp_write_check)" in
    yes) log "API key: writes permitted" ;;
    no)  log "API key: READ-ONLY on ${RP} — every write returns HTTP 403, empty body."
         log "  A launch gets as far as rotating the engine secret and then fails."
         log "  If this is a scoped key, check WHICH HOST the write grant landed on."
         log "  Three different hosts, and only two of them are this repo's business:"
         log "    ${RP_GQL}   read  — gpu types, prices, stock"
         log "    ${RP}       WRITE — pods and volumes; this is the one that matters"
         log "    api.runpod.ai                   serverless invocation; unused here"
         log "  Granting write on the serverless host reads exactly like this." ;;
    *)   log "API key: could not determine write permission (no answer from the API)" ;;
  esac
  gpus="$(rp_candidate_ids)" || return 1
  while read -r gpu; do
    [ -n "$gpu" ] || continue
    log "${GPU_COUNT:-1} × ${gpu}, secure cloud:"
    for dc in ${RUNPOD_DATACENTERS//,/ }; do
      read -r st pr <<<"$(rp_stock "$dc" "$gpu")"
      case "$st" in
        None|unknown) log "  $dc  no capacity" ;;
        *)            log "  $dc  stock=$st  \$$pr/hr"; any=0 ;;
      esac
    done
  done <<EOF
$gpus
EOF
  return $any
}

# The gpu ids this configuration would actually try, cheapest first. Which cards
# are SUITABLE is a property of the model, so the policy stays in common.sh
# (gpu_shortlist); this only translates the "auto" sentinel into ids.
rp_candidate_ids() {
  case "${RUNPOD_GPU_TYPE:-auto}" in
    ""|auto)
      local list; list="$(gpu_shortlist | cut -f1)"
      [ -n "$list" ] || {
        log "nothing rentable meets the constraints (>=${GPU_MIN_VRAM_GB}GB, FP8-capable${GPU_MAX_PRICE:+, <= \$$GPU_MAX_PRICE/hr})" >&2
        return 1
      }
      printf '%s\n' "$list"
      ;;
    *) printf '%s\n' "$RUNPOD_GPU_TYPE" ;;
  esac
}

# Body on stdout, HTTP status in RP_HTTP.
#
# The status is not a nicety. This API answers some refusals with a status code
# and NOTHING ELSE: a write the account is not permitted to make comes back 403
# with a zero-byte body. A helper that returns only the body turns that into a
# blank line, and the caller's "see the provider response above" then points at
# nothing — which is how a permissions problem reads exactly like a malformed
# request. Malformed requests, by contrast, get a long JSON 400 naming the
# field, so "no body at all" is itself the signal.
RP_HTTP=""
rp() { # rp METHOD PATH [JSON_BODY]
  local method="$1" path="$2" body="${3:-}" out rc=0
  out="$(mktemp)"
  if [ -n "$body" ]; then
    RP_HTTP="$(curl -sS -m 120 -X "$method" "$RP$path" \
      -H "Authorization: Bearer $RUNPOD_API_KEY" \
      -H 'Content-Type: application/json' -d "$body" \
      -o "$out" -w '%{http_code}')" || rc=$?
  else
    RP_HTTP="$(curl -sS -m 120 -X "$method" "$RP$path" \
      -H "Authorization: Bearer $RUNPOD_API_KEY" \
      -o "$out" -w '%{http_code}')" || rc=$?
  fi
  cat "$out"
  rm -f "$out"
  return $rc
}

# Prints yes / no / unknown: may this key WRITE? Free, and it touches no real
# resource — a DELETE against an id that cannot exist.
#
# The discrimination is the point. GET on the same bogus id answers 404 with a
# JSON body, so the read reached the lookup. A key without write scope answers
# 403 with ZERO bytes, rejected before the lookup happens. The pair separates
# "not allowed" from "not there", and costs nothing to ask.
#
# Worth asking because the alternative is finding out at pod-creation time, after
# the engine secret has been rotated and a launch is half done — and because the
# provider console can show a key as read/write while the API disagrees. That is
# not hypothetical; it is what sent us hunting through billing for an hour.
#
# LIMIT, and it matters if you are scoping a key down: this probes DELETE /pods,
# not POST /pods. A key restricted per-operation could permit one and refuse the
# other, and this would call it green. A full-access key gives a truthful answer;
# a scoped one is only confirmed by an actual launch.
rp_write_check() {
  rp DELETE "/pods/rp-write-probe-nonexistent" >/dev/null 2>&1 || true
  case "$RP_HTTP" in
    403)      printf 'no' ;;
    2*|4*|5*) printf 'yes' ;;   # 404 is the expected pass: allowed, nothing there
    *)        printf 'unknown' ;;   # no answer at all — network, not permission
  esac
}

provider_preflight() {
  : "${RUNPOD_API_KEY:?set in scripts/.env}"
  : "${RUNPOD_DATACENTERS:?set in scripts/.env}"
  # RUNPOD_GPU_TYPE may be empty or "auto" — choose_gpu() in common.sh fills it.
}

# The driver's entire contribution to choosing hardware: what is rentable, right
# now, as data. No policy — which of these is SUITABLE is a property of the model
# we are serving, not of this provider, so it lives in common.sh.
#
# Format, one offer per line, tab-separated:
#   <id>  <vram_gb>  <price_per_hr>  <stock>  <vendor>  <location>
provider_offers() {
  local ids id out st pr mem
  ids="$(curl -sS -m 30 -X POST "$RP_GQL" \
      -H "Authorization: Bearer $RUNPOD_API_KEY" -H 'Content-Type: application/json' \
      -d '{"query":"query { gpuTypes { id memoryInGb manufacturer } }"}' 2>/dev/null | python3 -c "
import sys, json
try: gs = json.load(sys.stdin)['data']['gpuTypes']
except Exception: raise SystemExit
for g in gs:
    print('%s\t%s\t%s' % (g.get('id') or '', g.get('memoryInGb') or 0, g.get('manufacturer') or ''))
" 2>/dev/null || true)"

  while IFS="$(printf '\t')" read -r id mem vendor; do
    [ -n "$id" ] || continue
    out="$(rp_stock_global "$id")"
    st="${out%% *}"; pr="${out##* }"
    case "$st" in None|unknown) continue ;; esac
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$mem" "$pr" "$st" "$vendor" "${RUNPOD_DATACENTERS%%,*}+"
  done <<EOF
$ids
EOF
}

# Same as rp_stock but without pinning a datacenter.
rp_stock_global() {
  local body
  body="$(printf '{"query":"query($id:String!){ gpuTypes(input:{id:$id}) { lowestPrice(input:{gpuCount:%d,secureCloud:true}) { stockStatus uninterruptablePrice } } }","variables":{"id":"%s"}}' \
      "${GPU_COUNT:-1}" "$1")"
  curl -sS -m 20 -X POST "$RP_GQL" \
    -H "Authorization: Bearer $RUNPOD_API_KEY" -H 'Content-Type: application/json' \
    -d "$body" 2>/dev/null | python3 -c "
import sys, json
try: lp = json.load(sys.stdin)['data']['gpuTypes'][0]['lowestPrice']
except Exception: print('unknown -'); raise SystemExit
print('%s %s' % (lp.get('stockStatus') or 'None', lp.get('uninterruptablePrice') if lp.get('uninterruptablePrice') is not None else '-'))
" 2>/dev/null || printf 'unknown -'
}

provider_find() {
  rp GET "/pods" | python3 -c "
import sys,json
try: pods=json.load(sys.stdin)
except Exception: sys.exit(0)
pods = pods if isinstance(pods,list) else pods.get('data',[]) or pods.get('pods',[])
for p in pods:
    if p.get('name')=='$NODE_NAME': print(p['id']); break
"
}

provider_status() { # provider_status ID
  rp GET "/pods/$1" | python3 -c "
import sys,json
d=json.load(sys.stdin)
v=d.get('desiredStatus')
print('' if v is None else v)
" 2>/dev/null || true
}

provider_storage() {
  local dc="${RUNPOD_DATACENTERS%%,*}"

  # Idempotent, because it is not: a second run creates a SECOND 200 GB volume
  # that bills 24/7 forever and is indistinguishable from the first. There is no
  # error to notice — you find out on the invoice. Creating storage is the one
  # operation here where "run it again" is expensive rather than harmless.
  local existing
  existing="$(rp GET /networkvolumes | python3 -c "
import sys,json
try: v=json.load(sys.stdin)
except Exception: sys.exit(0)
v = v if isinstance(v,list) else v.get('data',[])
for x in v:
    if x.get('name')=='ai-infra-weights':
        print('%s %s' % (x.get('id'), x.get('dataCenterId')))
" 2>/dev/null || true)"
  if [ -n "$existing" ]; then
    log "a volume named ai-infra-weights already exists — NOT creating another:"
    printf '%s\n' "$existing" | while read -r id vdc; do log "  $id in $vdc"; done
    log "put its id in scripts/.env as RUNPOD_VOLUME_ID, or delete it first if you want a new one"
    return 0
  fi

  # Capacity BEFORE storage. A volume is pinned to one datacenter forever and
  # bills 24/7 from creation, so creating one where the GPU is unavailable buys
  # a monthly cost for hardware you cannot rent. This is the single most
  # expensive ordering mistake available here.
  # Same "auto" trap as provider_capacity, with worse consequences: a false
  # "no capacity" here refuses to create the volume, and a false "capacity" pins
  # one to a datacenter forever. Ask about the card a launch would actually pick.
  local st pr gpu
  gpu="$(rp_candidate_ids | head -1)" || return 1
  read -r st pr <<<"$(rp_stock "$dc" "$gpu")"
  case "$st" in
    None|unknown)
      log "$gpu has NO capacity in $dc right now (stock=$st)"
      log "check other regions first:  ./scripts/gpu-up.sh --check-capacity"
      die "refusing to create a volume pinned to a datacenter that cannot run your GPU"
      ;;
    *) log "capacity check: $dc has $gpu at stock=$st, \$$pr/hr" ;;
  esac

  log "creating a 200 GB network volume in $dc"
  # Sized for the primary (~35 GB) plus the 27B A/B (~54 GB). Pinned to one
  # datacenter and billing continuously — see docs/devops-setup.md §4.3 for why
  # you may not want one at all outside a measurement phase.
  # Built with printf, not an inline python dict. `{'a':1,'b':2}` contains no
  # spaces, so bash BRACE-EXPANDS it into three words before python ever sees
  # it — the request then goes out with an empty body and the provider replies
  # about a missing content type, which points nowhere near the cause. The
  # larger request in provider_create escapes this only because its braces
  # contain newlines.
  local body
  body="$(printf '{"name":"ai-infra-weights","dataCenterId":"%s","size":%d}' "$dc" 200)"
  rp POST /networkvolumes "$body" | python3 -m json.tool
  log "put the returned id in scripts/.env as RUNPOD_VOLUME_ID"
}

# Build the pod request JSON. Reads RUNPOD_GPU_TYPE (and everything else) from
# the environment so the candidate loop can retry with a different card.
rp_pod_body() {
  # provision.sh travels in the pod's env, base64-encoded, so the node is built
  # from what is in Git rather than from a provider template that can drift.
  local provision_b64
  provision_b64="$(base64 < "$REPO_ROOT/gpu/provision.sh" | tr -d '\n')"

  # Prints the JSON — the caller captures it.
  PROVISION_B64="$provision_b64" python3 -c "
import json, os
env = {
    'PROVISION_B64':  os.environ['PROVISION_B64'],
    'TS_AUTHKEY':     os.environ['TS_AUTHKEY'],
    'TS_HOSTNAME':    os.environ.get('TS_HOSTNAME','gpu'),
    'ENGINE_SECRET':  os.environ['ENGINE_SECRET'],
    'MODEL_ID':       os.environ['MODEL_ID'],
    'MODEL_REVISION': os.environ['MODEL_REVISION'],
    # Required, not .get() with a default: the parsers pair with MODEL_ID, and a
    # default here would silently serve prose to every agent. KeyError before the
    # pod exists is the cheap failure.
    'TOOL_CALL_PARSER':  os.environ['TOOL_CALL_PARSER'],
    'REASONING_PARSER':  os.environ['REASONING_PARSER'],
    'MAX_MODEL_LEN':  os.environ.get('MAX_MODEL_LEN','65536'),
    'TP':             os.environ.get('TP','1'),
    'GPU_MEM_UTIL':   os.environ.get('GPU_MEM_UTIL','0.90'),
    'MAX_NUM_SEQS':   os.environ.get('MAX_NUM_SEQS','64'),
    'VLLM_LIMIT_MM':  os.environ.get('VLLM_LIMIT_MM',''),
    # Empty for FP8/BF16, where vLLM reads the method out of config.json. Named
    # only for the GPTQ MoE checkpoint, which needs moe_wna16 — and this env is an
    # explicit allowlist, so a var missing from it does not reach provision.sh at
    # all: the pod would fetch 65 GB and serve the dense-GPTQ path silently.
    # verify.sh asserts the value against MODEL_ID, which is why '' is tolerable
    # here where the parsers above are not.
    'VLLM_QUANTIZATION': os.environ.get('VLLM_QUANTIZATION',''),
    'HF_HOME_HOST':   '/runpod-volume' if os.environ.get('RUNPOD_VOLUME_ID','').strip() else '/root/.cache/huggingface',
}
req = {
    'name':               os.environ['NODE_NAME'],
    # SECURE, never COMMUNITY. The names are near-identical and the trust models
    # are opposite: on Community Cloud the host has root on your machine.
    'cloudType':          'SECURE',
    'computeType':        'GPU',
    'gpuTypeIds':         [os.environ['RUNPOD_GPU_TYPE']],
    'gpuTypePriority':    'custom',
    'gpuCount':           int(os.environ.get('GPU_COUNT','1')),
    'dataCenterIds':      os.environ['RUNPOD_DATACENTERS'].split(','),
    'dataCenterPriority': 'custom',
    'imageName':          os.environ['ENGINE_IMAGE'],
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
    # Host driver filter. Without it, placement is a lottery on driver age:
    # torch refuses drivers older than its CUDA build -- 'The NVIDIA driver on
    # your system is too old' -- the engine exits 1, and it presents as an
    # inscrutable init failure. Four launches died on this. NOTE this comment
    # sits inside a shell double-quoted string: a double quote here truncates
    # the python source at that character.
    # Default derived from the image, not guessed: the pinned torch is a
    # cu130 build (torch.version.cuda == 13.0), and torch refuses any older
    # driver -- a 12.8 host fails with 'driver too old (found version 12080)'.
    # engine-preflight.sh prints the image's build so this stays honest when
    # the digest changes.
    'allowedCudaVersions': os.environ['RUNPOD_CUDA_VERSIONS'].split(','),
    'interruptible':      False,
    'minVCPUPerGPU':      8,
    'minRAMPerGPU':       32,
}

vol = os.environ.get('RUNPOD_VOLUME_ID','').strip()
if vol:
    req['networkVolumeId']   = vol
    req['volumeMountPath']   = '/runpod-volume'
    req['containerDiskInGb'] = 60
else:
    # No volume: the weights live on container disk, so it must hold the image
    # plus the checkpoint plus room to unpack. Container disk is billed only
    # while the pod exists, unlike a network volume.
    req['containerDiskInGb'] = int(os.environ.get('RUNPOD_DISK_GB','120'))

print(json.dumps(req, indent=2))
"
}

provider_create() {
  : "${TS_AUTHKEY:?set in scripts/.env}"

  # choose_gpu() is generic and lives in common.sh; it sets GPU_CHOICE. The
  # driver only translates that into its own request field.
  # An explicitly configured RUNPOD_GPU_TYPE is an explicit choice; otherwise
  # try shortlist candidates IN ORDER until one places. Stock is reported
  # globally but creation is constrained to RUNPOD_DATACENTERS plus the CUDA
  # filter, so the cheapest candidate often cannot actually be placed -- dying
  # on it turns transient placement mismatch into a hard failure.
  # --pick means "start HERE", not "only here". A picked card that cannot be
  # placed is the common case (stock is reported globally, placement is not),
  # and treating the pick as the whole list turned that into a hard failure
  # while the rest of the shortlist sat unused.
  local candidates
  case "${GPU_SELECT:-${RUNPOD_GPU_TYPE:-auto}}" in
    ""|auto)
      if [ "${GPU_PICK:-0}" = 1 ] && [ -t 0 ]; then
        # choose_gpu also publishes GPU_SHORTLIST, so the fallbacks cost no
        # second listing call.
        GPU_SELECT="${GPU_SELECT:-auto}" choose_gpu >&2
        # `|| true`: with a one-entry shortlist grep matches nothing and exits 1,
        # which under set -e is the assignment's status and would abort the launch.
        candidates="$(printf '%s\n' "$GPU_CHOICE"; printf '%s\n' "$GPU_SHORTLIST" | grep -Fxv "$GPU_CHOICE" || true)"
      else
        candidates="$(gpu_shortlist | cut -f1)"
        [ -n "$candidates" ] || { show_offers >&2; die "nothing available meeting the constraints"; }
      fi
      ;;
    *) candidates="${GPU_SELECT:-$RUNPOD_GPU_TYPE}" ;;
  esac

  # RUNPOD_VOLUME_ID is OPTIONAL, and empty is usually the better choice.
  #
  # A network volume bills 24/7 and pins the pod to ONE datacenter — and only
  # 17 datacenters support volumes at all, which in practice excludes wherever
  # the cheap 48 GB Ada cards currently have stock. What it buys is measured, not
  # assumed: 35 GB of weights fetched in 34 s on a live pod, versus ~1 s from
  # cache. Half a minute per cold start, against a monthly bill and a hard
  # constraint on which GPUs you can rent.
  #
  # So: no volume by default. Weights land on container disk, sized below.
  if [ -n "${RUNPOD_VOLUME_ID:-}" ]; then
    log "using network volume $RUNPOD_VOLUME_ID (pins this pod to its datacenter)" >&2
  fi

  local body

  if [ "${MODE:-run}" = dry ]; then
    # Dry mode builds the request for the FIRST candidate only — enough to
    # inspect the shape without touching the provider.
    export RUNPOD_GPU_TYPE="$(printf '%s\n' "$candidates" | head -1)"
    body="$(rp_pod_body)"
    log "dry run — pod request below, nothing created (secrets redacted)" >&2
    printf '%s\n' "$body" | python3 -c "
import sys,json
d=json.load(sys.stdin)
for k in ('TS_AUTHKEY','ENGINE_SECRET','PROVISION_B64'):
    if k in d['env']: d['env'][k]='<redacted %d chars>' % len(d['env'][k])
print(json.dumps(d,indent=2))" >&2
    return 0
  fi

  local resp http pod_id gpu tried respfile
  respfile="$(mktemp)"
  pod_id=""
  tried=""
  while read -r gpu; do
    [ -n "$gpu" ] || continue
    export RUNPOD_GPU_TYPE="$gpu"
    tried="${tried:+$tried, }$gpu"
    body="$(rp_pod_body)"
    log "creating pod: ${GPU_COUNT:-1} × ${RUNPOD_GPU_TYPE} in ${RUNPOD_DATACENTERS}" >&2
    # Redirect, NOT resp="$(rp ...)". Command substitution runs rp in a subshell,
    # so the status it records in RP_HTTP is discarded along with that subshell —
    # the caller reads an empty string and the whole point is lost.
    rp POST /pods "$body" > "$respfile"
    resp="$(cat "$respfile")"; http="$RP_HTTP"
    pod_id="$(printf '%s' "$resp" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("id",""))' 2>/dev/null || true)"
    [ -n "$pod_id" ] && break
    # 403 with an empty body is the account refusing the write, not the fleet
    # being full — retrying the next card repeats it 8 times and then blames
    # capacity. Distinguishable only by the status, which is why rp() keeps it.
    if [ "$http" = 403 ]; then
      log "HTTP 403 from POST /pods, empty body" >&2
      die "the provider refused to create a pod: authenticated, but not permitted to.
  Reads work with this same key (GET /pods returns 200), and the request itself is
  well-formed — a malformed one gets a 400 naming the field. Ordered by what this
  has actually turned out to be:
    1. the API key cannot write. A key scoped read-only, or scoped to the wrong
       resource, reads fine and 403s every write. THE CONSOLE MAY SHOW IT AS
       READ/WRITE ANYWAY — do not treat that as evidence. Confirm with
       './scripts/gpu-up.sh --check-capacity', which reports it for free.
    2. billing — no payment method, zero balance, or a spend limit reached
    3. the account is restricted (region/verification hold)
  A second opinion in words: the GraphQL deploy mutation answers 'UNAUTHORIZED'
  where this endpoint sends nothing at all."
    fi
    case "$resp" in
      *"no instances"*|*"not available"*|*capacity*)
        # Global stock does not imply stock in OUR datacenters with OUR CUDA
        # filter. Not fatal: the next candidate may place.
        log "no capacity for $gpu in ${RUNPOD_DATACENTERS} (with CUDA ${RUNPOD_CUDA_VERSIONS}) — trying next candidate" >&2
        continue
        ;;
    esac
    printf 'HTTP %s\n%s\n' "${http:-?}" "${resp:-<empty response body>}" >&2
    if [ -n "${RUNPOD_VOLUME_ID:-}" ]; then
      die "pod creation failed. Note a network volume pins this pod to one datacenter, so the other entries in RUNPOD_DATACENTERS cannot be used while RUNPOD_VOLUME_ID is set."
    fi
    die "pod creation failed — see the provider response above"
  done <<EOF
$candidates
EOF
  rm -f "$respfile"
  if [ -z "$pod_id" ]; then
    show_offers >&2
    # Name what was actually tried, and only suggest knobs that are in play.
    # The old message named GPU_MAX_PRICE unconditionally, which sent us
    # looking at a limit that was not set.
    local hint="widen RUNPOD_DATACENTERS, lower GPU_MIN_VRAM_GB (now ${GPU_MIN_VRAM_GB:-48}), or wait"
    [ -n "${GPU_MAX_PRICE:-}" ] && hint="raise GPU_MAX_PRICE (now \$$GPU_MAX_PRICE/hr), $hint"
    die "no candidate could be placed in ${RUNPOD_DATACENTERS} (with CUDA ${RUNPOD_CUDA_VERSIONS}). Tried, in order: ${tried:-none} — $hint"
  fi
  printf '%s' "$pod_id"
}

provider_destroy() { # provider_destroy ID
  # DELETE, not /stop. A stopped pod keeps billing its container disk and holds
  # the GPU reservation; the whole point of on-demand is that nothing but the
  # volume survives.
  rp DELETE "/pods/$1" >/dev/null \
    || die "terminate call failed — check the provider console before assuming it is down"
  # A refused DELETE returns no body, so without the status this reads as success
  # and then merely "still listed after 60 s". The pod goes on billing either
  # way; the difference is whether the operator is told to go and kill it.
  case "$RP_HTTP" in
    2*) ;;
    *)  die "terminate refused: HTTP $RP_HTTP. The pod is STILL RUNNING AND BILLING — kill it in the provider console now." ;;
  esac
  local i
  for i in $(seq 1 20); do
    [ -z "$(provider_find || true)" ] && { log "pod gone"; return 0; }
    sleep 3
  done
  log "pod still listed after 60 s — verify in the console"
}
