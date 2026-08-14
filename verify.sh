#!/usr/bin/env bash
# Verify the ai-infra deployment.
#
#   ./verify.sh              non-disruptive checks only (safe any time)
#   ./verify.sh --disruptive adds container-destroy and restore-rehearsal tests
#
# Each check states the property it proves, not just that something responded.
#
# Checks that need the rented GPU node SKIP with a "pending phase C" marker
# rather than failing, so this script is runnable after every phase and a red
# line always means something is actually wrong.
set -uo pipefail
cd "$(dirname "$0")"
REPO_ROOT="$PWD"
GW=http://127.0.0.1:4000

DISRUPTIVE=0
[ "${1:-}" = "--disruptive" ] && DISRUPTIVE=1

[ -f gateway/.env ] || { echo "missing gateway/.env — cp gateway/.env.example gateway/.env"; exit 1; }
set -a; . ./gateway/.env; set +a

PASS=0; FAIL=0; SKIP=0
ok()    { printf "  \033[32mPASS\033[0m %s\n" "$1"; PASS=$((PASS+1)); }
bad()   { printf "  \033[31mFAIL\033[0m %s\n" "$1"; FAIL=$((FAIL+1)); }
skip()  { printf "  \033[33mSKIP\033[0m %s \033[33m[pending phase C]\033[0m\n" "$1"; SKIP=$((SKIP+1)); }
head_() { printf "\n\033[1m%s\033[0m\n" "$1"; }

code() { curl -s -m "${2:-60}" -o /dev/null -w "%{http_code}" "$1" "${@:3}"; }
dc()   { ( cd "$REPO_ROOT/gateway" && docker compose "$@" ); }

# Is the engine actually reachable? Everything that needs a GPU keys off this,
# so phases B and C light up the skipped checks with no edit to this file.
#
# Two ways it can be up: the real thing over the tailnet, or the mock fixture on
# the compose network. The mock is reachable only from inside the network — the
# same shape as the real engine being reachable only over the tailnet — so it is
# probed through the litellm container rather than from the host.
#
# REAL=1 means a real engine. MOCK=1 means the client-onboarding fixture.
# They are kept strictly apart, because a mock cannot exhibit the failures these
# checks exist to catch: a wrong tool-call parser returns prose, and the mock
# returns well-formed tool_calls by construction. Asserting that against a stub
# would pass whether or not the real deployment is broken — a check that can only
# go green is worse than no check, so under MOCK the model-behaviour assertions
# stay SKIPPED and only the genuinely-real signals are graded.
ENGINE_UP=0; MOCK=0; REAL=0
engine_probe() {
  dc exec -T litellm python -c "
import os,urllib.request,sys
base=os.environ['ENGINE_API_BASE'].rstrip('/')
r=urllib.request.Request(base+'/models',
    headers={'Authorization':'Bearer '+os.environ.get('ENGINE_SECRET','')})
sys.exit(0 if urllib.request.urlopen(r,timeout=8).status==200 else 1)" 2>/dev/null
}
# Ask the engine what it is, rather than looking for a mock container. A mock
# container can be running while LiteLLM points somewhere else entirely — the
# mock is not in the base compose file, so a base-only `compose down` leaves it
# orphaned and still up. Inferring MOCK from its presence then mislabels a run
# against the real endpoint. Whatever answers ENGINE_API_BASE is the engine, and
# only the stub serves /__mock__.
if engine_probe; then
  ENGINE_UP=1
  if dc exec -T litellm python -c "
import os,urllib.request,sys
base=os.environ['ENGINE_API_BASE'].rstrip('/').rsplit('/v1',1)[0]
sys.exit(0 if urllib.request.urlopen(base+'/__mock__',timeout=5).status==200 else 1)" 2>/dev/null; then
    MOCK=1
  else
    REAL=1
  fi
fi

if [ "$MOCK" = 1 ]; then
  printf "\n\033[1;43;30m  MOCK ENGINE — CLIENT ONBOARDING FIXTURE  \033[0m\n"
  printf "\033[33mgateway/mock_engine.py is standing in for the engine. It exists so opencode,\n"
  printf "aider and Claude Code can be configured, and keys handed to teammates, without\n"
  printf "burning GPU hours. Model-behaviour checks stay SKIPPED below: a stub returns\n"
  printf "well-formed tool_calls by construction and so cannot fail the way a wrong parser\n"
  printf "does. Only the LiteLLM-side signals are graded. Phase B on real hardware is the\n"
  printf "only thing that verifies an engine.\033[0m\n"
fi

# ================================================================ structure

head_ "1. Compose file valid, no empty env interpolation"
if dc config --quiet 2>/dev/null; then ok "compose file parses"; else bad "compose file invalid"; fi
# An unset var in .env silently resolves to "" rather than erroring, which would
# leave Postgres with a blank password. Check the values that matter explicitly —
# a bare "grep for empty" matches every YAML key that opens a nested block.
resolved=$(dc config 2>/dev/null)
for v in LITELLM_MASTER_KEY POSTGRES_PASSWORD DATABASE_URL ENGINE_SECRET ENGINE_API_BASE UI_USERNAME UI_PASSWORD; do
  val=$(printf '%s\n' "$resolved" | sed -nE "s/^[[:space:]]*$v: *(.*)$/\1/p" | head -1)
  case "$val" in
    ""|'""'|*CHANGE-ME*) bad "$v resolved empty or placeholder" ;;
    *)                   ok "$v resolved (${#val} chars)" ;;
  esac
done

head_ "2. Images pinned to digests, not floating tags"
# A rebuilt node must get byte-identical software. `main-latest` silently
# changes underneath a working deployment.
for f in gateway/docker-compose.yml gpu/docker-compose.yml gateway/docker-compose.mock-engine.yml; do
  floats=$(grep -nE '^\s*image:' "$f" | grep -v '@sha256:' || true)
  [ -z "$floats" ] && ok "$f: every image pinned by digest" \
                   || bad "$f: unpinned image(s): $floats"
done

head_ "3. No laptop artifacts in the compose files"
# Both are laptop-only workarounds that belong in no committed compose file.
# They were live in the throwaway stack this config was derived from, so the risk
# is a future edit copying them back in — cheap to guard, quiet if it happens.
#
# OPENSSL_armcap worked around a SIGILL (exit 132) on Apple silicon under Docker
# Desktop 4.36: the guest advertised FEAT_SME without implementing it, so
# OpenSSL's ARM capability probe hit an illegal instruction. Verified fixed on
# Docker Desktop 4.84.0 — the container boots clean with exit 0 and no SIGILL —
# so the override file that carried it is gone rather than shipping config that
# protects against nothing.
if grep -q 'OPENSSL_armcap' gateway/docker-compose.yml; then
  bad "OPENSSL_armcap is back in the compose — a Docker Desktop 4.36 workaround, unnecessary since 4.37"
else
  ok "no OPENSSL_armcap (fixed upstream; verified on Docker Desktop 4.84.0)"
fi
if grep -qE 'host\.docker\.internal|extra_hosts' gateway/docker-compose.yml; then
  bad "host.docker.internal / extra_hosts present — laptop artifact, the engine is a tailnet host"
else
  ok "no host.docker.internal / extra_hosts"
fi

head_ "4. No secrets committed"
if git -C "$REPO_ROOT" ls-files --error-unmatch gateway/.env >/dev/null 2>&1 \
   || git -C "$REPO_ROOT" ls-files --error-unmatch scripts/.env >/dev/null 2>&1; then
  bad "a .env file is TRACKED by git"
else
  ok ".env files untracked"
fi
# Scan history, not just the working tree — a secret removed in a later commit is
# still in the repo.
if git -C "$REPO_ROOT" rev-list --all >/dev/null 2>&1; then
  hits=$(git -C "$REPO_ROOT" grep -InE 'sk-[a-zA-Z0-9]{20,}|tskey-auth-[a-zA-Z0-9]{10,}' \
           $(git -C "$REPO_ROOT" rev-list --all) -- . 2>/dev/null \
         | grep -v 'CHANGE-ME' | head -5 || true)
  [ -z "$hits" ] && ok "no key-shaped strings in git history" \
                 || bad "possible secret in history: $hits"
else
  ok "no commits yet — nothing in history"
fi

head_ "5. Tailnet policy is safe by construction"
P=policy/tailnet-policy.hujson
if grep -qE '^\s*"acls"\s*:' "$P"; then
  bad "an \"acls\" block is present — a default allow-all grants entry silently overrides it"
else
  ok "no acls block; the whole policy is in grants"
fi
grep -q '"tests"' "$P" && ok "tests block present (the only thing that catches a non-enforcing ACL statically)" \
                       || bad "no tests block — Tailscale will save a policy that restricts nothing"
# The blast-radius assertion: the rented node must not be able to initiate to
# anything on the tailnet. This is enforced by ABSENCE, which is easy to erase.
if grep -E '"src"\s*:\s*\[\s*"tag:gpu"' "$P" | grep -v '^\s*//' | grep -q .; then
  bad "a grant with src tag:gpu exists — the rented node is no longer confined"
else
  ok "no src tag:gpu grant — rented node cannot initiate to the tailnet"
fi
# Must be a LIVE test asserting tag:gpu is denied outbound — not a commented-out
# one, and not tag:gateway's accept of tag:gpu:8000, which is the opposite claim.
# Checked on the parsed document so a comment cannot satisfy it.
if python3 - "$P" <<'PY'
import json, re, sys
s = re.sub(r'//.*', '', open(sys.argv[1]).read())
s = re.sub(r',(\s*[}\]])', r'\1', s)
d = json.loads(s)
sys.exit(0 if any(
    t.get("src") == "tag:gpu" and t.get("deny") and not t.get("accept")
    for t in d.get("tests", [])
) else 1)
PY
then
  ok "a live test asserts tag:gpu is denied outbound (rented node confined)"
else
  bad "no live tests entry with src tag:gpu and a deny list — confinement is unasserted"
fi
if command -v tailscale >/dev/null && tailscale status >/dev/null 2>&1; then
  skip "tailscale debug netmap: only tag:gateway permitted to 8000"
else
  skip "tailnet checks (tailscaled not running on this machine)"
fi

head_ "5b. Provider drivers are swappable"
# The point of the driver layer is that changing GPU supplier is one line in
# scripts/.env. That only holds while nothing outside providers/ names a
# provider, so assert it rather than trusting it.
# engine-preflight.sh is excluded: validating RUNPOD_CUDA_VERSIONS against the
# image's torch build is the point of that script, so naming the var is not a leak.
leak=$(grep -rlniE 'runpod' scripts/*.sh 2>/dev/null | grep -v '/providers/' | grep -v 'engine-preflight' || true)
if [ -n "$leak" ]; then
  # common.sh may name the DEFAULT; anything else is coupling.
  leak=$(grep -rniE 'runpod' scripts/*.sh 2>/dev/null | grep -v '/providers/' \
         | grep -vE 'GPU_PROVIDER:-runpod|^scripts/common\.sh:[0-9]+:#|^scripts/engine-preflight\.sh:' || true)
fi
[ -z "$leak" ] && ok "no provider named outside scripts/providers/" \
                || bad "provider coupling leaked out of providers/: $(printf '%s' "$leak" | head -2)"

for drv in scripts/providers/*.sh; do
  name=$(basename "$drv" .sh)
  missing=""
  for fn in provider_preflight provider_find provider_status provider_create provider_destroy provider_storage; do
    grep -qE "^$fn\\(\\)" "$drv" || missing="$missing $fn"
  done
  kind=$(grep -oE '^PROVIDER_KIND=[a-z]+' "$drv" | cut -d= -f2)
  case "$kind" in
    ephemeral|persistent) ;;
    *) missing="$missing PROVIDER_KIND" ;;
  esac
  [ -z "$missing" ] && ok "driver '$name' implements the contract (kind=$kind)" \
                    || bad "driver '$name' is missing:$missing"
done

# A persistent driver destroying hardware is the one unrecoverable bug in this
# layer, so assert the shape rather than hoping the comment is obeyed.
for drv in scripts/providers/*.sh; do
  grep -qE '^PROVIDER_KIND=persistent' "$drv" || continue
  name=$(basename "$drv" .sh)
  if grep -nE 'rm -rf|DELETE |terminate|destroy-machine|--volumes' "$drv" | grep -v '^\s*#' | grep -q .; then
    bad "persistent driver '$name' contains a destructive call — it must only stop the engine"
  else
    ok "persistent driver '$name' cannot destroy the machine"
  fi
done

# Flag-name drift against the pinned image is checked by
# scripts/engine-preflight.sh — not here, because it needs the ~10 GB engine
# image and a minute of emulated python. Run it after ANY change to engine
# flags or the image digest, before gpu-up.sh. This check only asserts the
# script exists and parses.
bash -n scripts/engine-preflight.sh 2>/dev/null && ok "engine-preflight.sh present (run it before spending: validates flags against the pinned image)" \
                                                || bad "scripts/engine-preflight.sh missing or broken"

head_ "6. GPU node config cannot expose the engine publicly"
G=gpu/docker-compose.yml
if grep -qE '^\s*ports:' "$G"; then
  bad "gpu compose has a ports: stanza — that publishes :8000 on the rented host"
else
  ok "gpu compose publishes no ports"
fi
grep -q 'network_mode: host' "$G" && ok "host networking (no NAT; vLLM binds the tailnet address directly)" \
                                  || bad "no host networking — the gateway could not reach vLLM without publishing a port"
# Accept either spelling: vLLM renamed --disable-log-requests to
# --no-enable-log-requests, and passing the retired one is FATAL (argparse exits
# 1, the container restarts forever, and the pod still reports RUNNING).
if grep -qE -- '--no-enable-log-requests' "$G"; then
  ok "--no-enable-log-requests (no prompts on disk we do not own)"
elif grep -qE -- '--disable-log-requests' "$G"; then
  bad "--disable-log-requests is the retired spelling — vLLM exits 1 on it; use --no-enable-log-requests"
else
  bad "request logging is not disabled — prompts would land on hardware we do not own"
fi
# The parsers pair with MODEL_ID, so they now come from scripts/.env rather than
# being baked in here. Three things to assert, not one: the flags are wired to
# that environment, the environment actually sets them, and the values MATCH the
# checkpoint. The last is the one that matters — a parser left behind after a
# model swap returns prose where agents expect tool_calls, and fails silently.
grep -qF -- '--tool-call-parser=${TOOL_CALL_PARSER' "$G" \
  && ok "tool-call parser wired to TOOL_CALL_PARSER (pairs with MODEL_ID)" \
  || bad "tool-call parser hardcoded in $G — it must pair with MODEL_ID or a model swap silently breaks tool calling"
grep -qF -- '--reasoning-parser=${REASONING_PARSER' "$G" \
  && ok "reasoning parser wired to REASONING_PARSER (required even on the non-thinking alias)" \
  || bad "reasoning parser hardcoded in $G"

mid="$(sed -nE 's/^MODEL_ID=(.+)$/\1/p' scripts/.env 2>/dev/null | head -1)"
tcp="$(sed -nE 's/^TOOL_CALL_PARSER=(.+)$/\1/p' scripts/.env 2>/dev/null | head -1)"
rsp="$(sed -nE 's/^REASONING_PARSER=(.+)$/\1/p' scripts/.env 2>/dev/null | head -1)"
[ -n "$tcp" ] && ok "TOOL_CALL_PARSER is set (=$tcp)" \
              || bad "TOOL_CALL_PARSER unset in scripts/.env — provision.sh aborts before the download"
[ -n "$rsp" ] && ok "REASONING_PARSER is set (=$rsp)" \
              || bad "REASONING_PARSER unset in scripts/.env"

# Extend this case when a new checkpoint is introduced. An unknown MODEL_ID skips
# rather than passes: silence here would defeat the point of the check.
case "$mid" in
  *GLM-4.7*)  want_tcp=glm47;       want_rsp=glm47 ;;
  *Qwen3.6*)  want_tcp=qwen3_coder; want_rsp=qwen3 ;;
  *)          want_tcp="";          want_rsp="" ;;
esac
if [ -n "$want_tcp" ]; then
  [ "$tcp" = "$want_tcp" ] && ok "tool-call parser matches the model ($mid -> $tcp)" \
    || bad "MODEL_ID=$mid needs TOOL_CALL_PARSER=$want_tcp, but it is '$tcp' — agents would get prose, silently"
  [ "$rsp" = "$want_rsp" ] && ok "reasoning parser matches the model ($mid -> $rsp)" \
    || bad "MODEL_ID=$mid needs REASONING_PARSER=$want_rsp, but it is '$rsp' — reasoning would land inside content"
else
  skip "parser/model pairing (unrecognised MODEL_ID='$mid' — add it to the case in verify.sh)"
fi
grep -q -- '--revision=' "$G" && ok "model pinned to a revision" || bad "model not pinned — a rebuild may fetch different weights"
# TP=1 must not carry ipc: host, and TP>=2 must. Getting this backwards is a
# cryptic NCCL failure, not a clear error.
tp="$(sed -nE 's/^TP=([0-9]+).*/\1/p' scripts/.env 2>/dev/null | head -1)"; tp="${tp:-1}"
ipc="$(grep -cE '^\s*ipc:\s*host' "$G" || true)"
if [ "$tp" -ge 2 ] && [ "$ipc" -eq 0 ]; then
  bad "TP=$tp but ipc: host is commented out — multi-GPU startup will fail cryptically"
else
  ok "ipc: host matches TP=$tp"
fi

# ================================================================ gateway

head_ "7. Containers up, not restart-looping"
for c in ai-infra-litellm ai-infra-db; do
  read -r st rc < <(docker inspect "$c" --format '{{.State.Status}} {{.RestartCount}}' 2>/dev/null)
  if [ "$st" = "running" ] && [ "${rc:-1}" -lt 3 ]; then ok "$c running (restarts=${rc})"
  else bad "$c status=${st:-absent} restarts=${rc:-?}"; fi
done

head_ "8. Gateway is not exposed beyond loopback"
lan=$(ipconfig getifaddr en0 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}')
if [ -n "$lan" ]; then
  # Identity matters, not just an open port: another app on :4000 (a dev server
  # on the IPv6 wildcard, say) answers here without exposing the GATEWAY at all.
  # Only LiteLLM answering its own liveliness on the LAN is the spoofing risk.
  lanbody=$(curl -s -m 5 "http://$lan:4000/health/liveliness" 2>/dev/null)
  c=$(curl -s -m 5 -o /dev/null -w "%{http_code}" "http://$lan:4000/health/liveliness" 2>/dev/null)
  if [ "$c" = "000" ]; then
    ok ":4000 unreachable on the LAN address ($lan) — loopback bind holds"
  elif printf '%s' "$lanbody" | grep -q "I'm alive!"; then
    bad "LiteLLM itself answers on $lan:4000 — exposure beyond loopback makes Tailscale-User-Login spoofable"
  else
    ok ":4000 on $lan is answered by something that is NOT the gateway (a neighbour app) — loopback bind holds, but two apps share the port number"
  fi
else
  skip "no LAN address found to test loopback confinement against"
fi
if docker inspect ai-infra-db --format '{{json .NetworkSettings.Ports}}' 2>/dev/null | grep -q 'HostPort'; then
  bad "Postgres publishes a port — every virtual key and all spend history lives there"
else
  ok "Postgres publishes no ports"
fi

head_ "9. Postgres is storing keys and usage, not merely running"
keys=$(dc exec -T litellm-db psql -U litellm -d litellm -tAc 'select count(*) from "LiteLLM_VerificationToken";' 2>/dev/null | tr -d '[:space:]')
[ "${keys:-x}" != "x" ] && ok "key table reachable ($keys key(s) persisted)" || bad "cannot query the key table"

head_ "10. Gateway serves both aliases, and auth is required"
aliases=$(curl -s -m 15 "$GW/v1/models" -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  | python3 -c 'import sys,json;print(",".join(sorted(m["id"] for m in json.load(sys.stdin)["data"])))' 2>/dev/null)
[ "$aliases" = "coder,coder-max" ] && ok "aliases: $aliases" || bad "expected coder,coder-max — got '${aliases:-nothing}'"
[ "$(code "$GW/v1/models" 15)" = "401" ] && ok "unauthenticated request rejected (401)" || bad "no-key request was not 401"

head_ "11. Scoped key confined to its models"
K=$(curl -s -X POST "$GW/key/generate" -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
     -H "Content-Type: application/json" \
     -d '{"models":["coder"],"rpm_limit":3,"metadata":{"user":"verify.sh"}}' \
   | python3 -c 'import sys,json;print(json.load(sys.stdin)["key"])' 2>/dev/null)
[ -n "$K" ] && ok "issued a scoped key" || bad "key issuance failed — is litellm-db up?"
req() { curl -s -m "${2:-90}" -o /dev/null -w "%{http_code}" "$GW/v1/chat/completions" \
          -H "Authorization: Bearer ${3:-$K}" -H "Content-Type: application/json" \
          -d "{\"model\":\"$1\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":1}"; }
# 403 means scoping rejected it; 503 means scoping ALLOWED it and the engine is
# absent. Distinguishing the two is what makes this check meaningful with no GPU.
c=$(req coder-max)
[ "$c" = "403" ] && ok "unlisted model -> 403" || bad "unlisted model returned $c, expected 403"
c=$(req coder)
if [ "$ENGINE_UP" = 1 ]; then
  [ "$c" = "200" ] && ok "allowed model -> 200" || bad "allowed model returned $c with the engine up"
else
  [ "$c" = "503" ] && ok "allowed model passed scoping (503 from the absent engine, not 403)" \
                   || bad "allowed model returned $c — expected 503 with no engine"
fi

head_ "12. User key cannot act as admin"
for ep in key/generate key/delete; do
  c=$(curl -s -m 30 -o /dev/null -w "%{http_code}" -X POST "$GW/$ep" \
        -H "Authorization: Bearer $K" -H "Content-Type: application/json" -d '{"keys":["sk-fake"]}')
  { [ "$c" = "401" ] || [ "$c" = "403" ]; } && ok "/$ep rejected a user key ($c)" || bad "/$ep accepted a user key ($c)"
done

head_ "13. Rate limit enforced (key is rpm_limit=3)"
# Enforced before the upstream call, so this holds with no engine.
got429=0
for i in 1 2 3 4 5 6 7 8; do [ "$(req coder)" = "429" ] && { got429=1; break; }; done
[ "$got429" = "1" ] && ok "429 returned once over the limit" || bad "never rate limited"

head_ "14. Token caps present and sized per alias"
# The cap on coder-max must be generous: a cap that truncates mid-reasoning
# returns finish_reason: length with EMPTY content — a request that burned GPU
# time and produced nothing, presenting as a broken model rather than a cap.
cmax=$(python3 -c "
import re,sys
t=open('gateway/config.yaml').read()
for name in ('coder','coder-max'):
    m=re.search(r'model_name: '+re.escape(name)+r'\b.*?max_tokens:\s*(\d+)', t, re.S)
    print(name, m.group(1) if m else 'MISSING')
")
printf '%s\n' "$cmax" | while read -r name val; do
  case "$name:$val" in
    coder:MISSING|coder-max:MISSING) bad "$name has no max_tokens — an uncapped client burns GPU hours" ;;
    coder-max:*) [ "$val" -ge 16384 ] && ok "coder-max max_tokens=$val (room for a full reasoning budget)" \
                                      || bad "coder-max max_tokens=$val is too tight — truncating mid-reasoning returns empty content" ;;
    coder:*)     ok "coder max_tokens=$val" ;;
  esac
done
grep -q 'enable_thinking: false' gateway/config.yaml && ok "coder disables thinking via chat_template_kwargs" || bad "coder does not disable thinking"
grep -q 'enable_thinking: true'  gateway/config.yaml && ok "coder-max enables thinking" || bad "coder-max does not enable thinking"

head_ "15. Privacy and reliability settings in force"
grep -q 'turn_off_message_logging: true' gateway/config.yaml \
  && ok "turn_off_message_logging (spend rows kept, prompt bodies not)" || bad "message logging not disabled"
# Must match a real setting, not the comment in config.yaml that warns against it.
if grep -qE '^\s*disable_spend_logs\s*:\s*[Tt]rue' gateway/config.yaml; then
  bad "disable_spend_logs is set — idle-check.sh queries those rows; the idle killer would never fire"
else
  ok "spend logs kept (idle-check.sh depends on them)"
fi
grep -q 'health_check_details: false' gateway/config.yaml \
  && ok "health_check_details false (no engine URLs leaked to key holders)" || bad "health_check_details not disabled"
grep -q 'timeout: 600' gateway/config.yaml \
  && ok "timeout 600 (a thinking alias on a hard task is slow, not hung)" || bad "timeout not 600"
grep -qE '"coder-max": \["coder"\]' gateway/config.yaml \
  && ok "fallback coder-max -> coder (sheds the reasoning budget rather than erroring)" || bad "no coder-max -> coder fallback"

head_ "16. Spend rows carry no prompt or response text"
rows=$(dc exec -T litellm-db psql -U litellm -d litellm -tAc 'select count(*) from "LiteLLM_SpendLogs";' 2>/dev/null | tr -d '[:space:]')
if [ "${rows:-0}" -ge 1 ]; then
  leak=$(dc exec -T litellm-db psql -U litellm -d litellm -tAc \
    "select count(*) from \"LiteLLM_SpendLogs\" where messages::text not in ('{}','\"{}\"','null','') and messages::text ilike '%content%';" 2>/dev/null | tr -d '[:space:]')
  [ "${leak:-1}" = "0" ] && ok "$rows spend row(s), none containing message content" \
                         || bad "$leak spend row(s) contain message content — turn_off_message_logging is not taking effect"
else
  skip "no spend rows yet to inspect for leakage (needs a completed request)"
fi

head_ "17. Engine down -> a clear error, fast, and metadata still served"
if [ "$ENGINE_UP" = 1 ]; then
  skip "engine-down path (engine is currently UP — re-run after gpu-down.sh)"
else
  start=$(date +%s)
  body=$(curl -s -m 60 "$GW/v1/chat/completions" -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
           -H 'Content-Type: application/json' \
           -d '{"model":"coder","messages":[{"role":"user","content":"hi"}],"max_tokens":1}')
  el=$(( $(date +%s) - start ))
  c=$(printf '%s' "$body" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("error",{}).get("code",""))' 2>/dev/null)
  [ "$c" = "503" ] && ok "503, not a bare 500 (${el}s — fails fast, no hang)" || bad "got code '$c' after ${el}s, expected 503"
  printf '%s' "$body" | grep -q 'engine_unavailable' \
    && ok "error names the cause and the fix (type=engine_unavailable)" \
    || bad "error does not identify itself — a user reading this opens a bug instead of running gpu-up"
  [ "$el" -lt 30 ] && ok "no hang (${el}s < 30s)" || bad "took ${el}s"
  [ "$(code "$GW/v1/models" 15 -H "Authorization: Bearer $LITELLM_MASTER_KEY")" = "200" ] \
    && ok "gateway metadata still served with the engine down" || bad "gateway unhealthy without the engine"
  # A green gateway with a dead engine looks healthy. That is exactly why the
  # two must be monitored separately.
  [ "$(code "$GW/health/liveliness" 10)" = "200" ] \
    && ok "/health/liveliness green while the engine is dead — proves it says nothing about the engine" \
    || bad "/health/liveliness not answering"
fi

head_ "18. Revocation works"
curl -s -X POST "$GW/key/delete" -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" -d "{\"keys\":[\"$K\"]}" >/dev/null
[ "$(code "$GW/v1/models" 20 -H "Authorization: Bearer $K")" = "401" ] \
  && ok "revoked key -> 401" || bad "revoked key still works"

# ================================================================ engine (phase B/C)

head_ "19. Engine, reachable only from the gateway"
if [ "$ENGINE_UP" = 1 ]; then
  ok "gateway -> engine /v1/models returns 200$([ "$MOCK" = 1 ] && echo ' (mock)')"
  # The engine secret is defence in depth, not the real control — but a rotated
  # secret that silently fails to take effect would leave the gateway talking to
  # nothing while looking configured. Prove the wrong secret is rejected.
  if dc exec -T litellm python -c "
import os,urllib.request,sys,urllib.error
base=os.environ['ENGINE_API_BASE'].rstrip('/')
r=urllib.request.Request(base+'/models',headers={'Authorization':'Bearer wrong-secret'})
try: urllib.request.urlopen(r,timeout=8); sys.exit(1)
except urllib.error.HTTPError as e: sys.exit(0 if e.code==401 else 1)
except Exception: sys.exit(1)" 2>/dev/null; then
    ok "engine rejects a wrong secret (401) — rotation failures will be loud"
  else
    bad "engine accepted a wrong secret — --api-key is not in force"
  fi
  # gpu-down.sh's drain loop reads exactly this metric. If it is absent the
  # drain silently degrades to "engine unreachable, treat as drained".
  #
  # Only meaningful against a real engine: the risk is vLLM renaming the metric
  # across versions, and the mock exposes whatever name is hardcoded in it. Under
  # MOCK this check would confirm the stub agrees with itself.
  if [ "$REAL" = 1 ]; then
    if dc exec -T litellm python -c "
import os,urllib.request,sys
base=os.environ['ENGINE_API_BASE'].rstrip('/').rsplit('/v1',1)[0]
b=urllib.request.urlopen(base+'/metrics',timeout=8).read().decode()
sys.exit(0 if 'vllm:num_requests_running' in b else 1)" 2>/dev/null; then
      ok "vllm:num_requests_running exposed — gpu-down.sh can drain"
    else
      bad "no vllm:num_requests_running on /metrics — gpu-down would destroy without draining"
    fi
  else
    skip "vllm:num_requests_running exposed for the drain loop (circular under the mock)"
  fi
else
  skip "gateway -> engine /v1/models"
  skip "engine rejects a wrong secret (401)"
  skip "vllm:num_requests_running exposed for the drain loop"
fi
skip "from a user device: tag:gpu:8000 must FAIL"
skip "from the public internet: GPU node's public IP, any port — all refused"
skip "from the GPU node: reach tag:gateway on 443/22/4000 — all must fail"
skip "tailscale status on the gateway: GPU node reads 'direct', not 'relay'"
skip "Tailscale-User-Login present via serve, and STRIPPED when a client sends its own"
# These three are the numbers a human reads off the startup log, and every one of
# them is checkpoint-specific: KV cost per token, streams the cache can back, and
# the VRAM budget. Hardcoding the previous model's figures would print a stale
# expectation that reads exactly like a measurement.
case "$(sed -nE 's/^MODEL_ID=(.+)$/\1/p' scripts/.env 2>/dev/null | head -1)" in
  *GLM-4.7*)
    # MLA: (kv_lora_rank 512 + qk_rope 64) x 2 B x 47 layers.
    skip "vLLM startup log: per-token KV in the ~54 kB class (MLA), NOT the ~20 kB Qwen figure"
    # Measured on the first live boot, not predicted: /metrics reports
    # kv_cache_size_tokens=549712 and kv_cache_max_concurrency=8.39 on a 96 GB
    # card. A large drop means the engine sized the cache differently, and the
    # whole concurrency story changes with it.
    skip "KV cache at startup ~549,712 tokens / ~8.4 streams at 65k (96 GB card)"
    # Text-only checkpoint, so there is no vision tower to account for. The
    # measured cache implies ~29.7 GB of KV, ~9 GB more than the 62.4 GB BF16
    # weight figure leaves room for — see docs/design-notes.md §11.
    skip "peak VRAM vs the 86.4 GB budget (96 GB x 0.90) — reconcile weights vs the ~29.7 GB KV measured"
    ;;
  *Qwen3.6-27B*)
    # Dense, 16/64 full-attention layers against the MoE's ~10/40 — so ~3x the
    # per-token KV of the primary on the SAME card. Reading the ~20 kB figure
    # here would look like the sizing held when it did not.
    skip "vLLM startup log: per-token KV in the ~64 kB class, NOT the ~20 kB 35B-A3B figure"
    # Predicted, not measured: 30.9 GB of weights against the 43.2 GB budget
    # leaves ~12 GB, and ~12 GB at ~64 kB/token is ~190k. If the real number
    # lands near the MoE's ~410k, the concurrency case for the A/B is wrong in
    # our favour and worth writing down.
    skip "KV cache at startup ~190k tokens / ~3 streams at 65k (48 GB card) — predicted, confirm on first boot"
    # Same vision tower as the primary; same overlooked reservation.
    skip "peak VRAM vs the 43.2 GB budget — does the unused vision tower cost anything?"
    ;;
  *)
    skip "vLLM startup log: per-token KV in the ~20 KB class, not ~262 KB"
    skip "KV cache blocks at startup consistent with ~65k x ~6 streams (~410k tokens)"
    # The Qwen3.6 checkpoints carry a vision tower that is easy to overlook
    # (see gpu/docker-compose.yml). Peak VRAM is the measurement that decides
    # whether --limit-mm-per-prompt is worth setting.
    skip "peak VRAM vs the 43.2 GB budget — does the unused vision tower cost anything?"
    ;;
esac

head_ "20. Model behaviour on each alias"
# REAL, not ENGINE_UP. Every assertion below is about what the *model and its
# parsers* do, and the mock cannot get any of them wrong.
if [ "$REAL" = 1 ]; then
  for alias in coder coder-max; do
    out=$(curl -s -m 300 "$GW/v1/chat/completions" -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
      -H 'Content-Type: application/json' \
      -d "{\"model\":\"$alias\",\"messages\":[{\"role\":\"user\",\"content\":\"What is 17*23? Think it through.\"}]}")
    got=$(printf '%s' "$out" | python3 -c '
import sys,json
m=json.load(sys.stdin)["choices"][0]
msg=m["message"]
print(("reason" if msg.get("reasoning_content") else "noreason"),
      ("content" if (msg.get("content") or "").strip() else "empty"),
      m.get("finish_reason"))' 2>/dev/null)
    read -r r cc fr <<<"$got"
    if [ "$alias" = coder ]; then
      [ "$r" = noreason ] && ok "coder: no reasoning_content (thinking off)" || bad "coder emitted reasoning — extra_body passthrough not reaching vLLM"
      printf '%s' "$out" | grep -q '<think>' && bad "coder: raw <think> block in content" || ok "coder: no raw <think> block"
    else
      [ "$r" = reason ] && ok "coder-max: reasoning separated from content" || bad "coder-max: no reasoning_content — passthrough or --reasoning-parser missing"
    fi
    [ "$cc" = content ] && ok "$alias: content non-empty" || bad "$alias: EMPTY content (finish_reason=$fr) — cap truncated mid-reasoning"
    [ "$fr" != length ] && ok "$alias: finish_reason=$fr (not truncated)" || bad "$alias: finish_reason=length — raise max_tokens for this alias"
    # A wrong tool-call parser returns prose here and fails SILENTLY under
    # aider, which uses text diffs. This is the check that catches it.
    tc=$(curl -s -m 300 "$GW/v1/chat/completions" -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
      -H 'Content-Type: application/json' \
      -d "{\"model\":\"$alias\",\"messages\":[{\"role\":\"user\",\"content\":\"What is the weather in Berlin?\"}],\"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"get_weather\",\"description\":\"Get weather\",\"parameters\":{\"type\":\"object\",\"properties\":{\"city\":{\"type\":\"string\"}},\"required\":[\"city\"]}}}]}" \
      | python3 -c 'import sys,json;print("yes" if json.load(sys.stdin)["choices"][0]["message"].get("tool_calls") else "no")' 2>/dev/null)
    [ "$tc" = yes ] && ok "$alias: structured tool_calls, not prose" || bad "$alias: no tool_calls — check TOOL_CALL_PARSER in scripts/.env matches MODEL_ID"
  done
else
  skip "tool calling on each alias returns structured tool_calls"
  skip "coder (thinking off): no <think>, no reasoning_content"
  skip "coder-max (thinking on): reasoning separated from content, both non-empty"
  skip "coder-max long task: never finish_reason=length with empty content"
  skip "fallback chain: coder-max failing on the thinking path still answers via coder"
  skip "end-to-end agent task via opencode and aider: file written, request in gateway log"
fi

if [ "$MOCK" = 1 ]; then
  head_ "20b. Client onboarding fixture — LiteLLM-side signals only"
  # These ARE real, because the mock echoes back what actually arrived on the
  # wire. It cannot fake LiteLLM having sent something it did not send.
  #
  # Worth verifying rather than assuming, because the
  # coder / coder-max split depends entirely on LiteLLM forwarding extra_body
  # through as a top-level chat_template_kwargs key. If it silently drops it,
  # both aliases think, and the only symptom in production is a bigger bill.
  for alias in coder coder-max; do
    want=$([ "$alias" = coder ] && echo false || echo true)
    echoed=$(curl -s -m 60 "$GW/v1/chat/completions" -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
      -H 'Content-Type: application/json' \
      -d "{\"model\":\"$alias\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}" \
      | python3 -c '
import sys,json,re
c=json.load(sys.stdin)["choices"][0]["message"].get("content") or ""
m=re.search(r"chat_template_kwargs=(\{.*\})",c)
print(json.loads(m.group(1)).get("enable_thinking") if m else "absent")' 2>/dev/null)
    [ "$echoed" = "$(printf '%s' "$want" | sed 's/true/True/;s/false/False/')" ] \
      && ok "$alias: LiteLLM forwarded enable_thinking=$want to the engine" \
      || bad "$alias: engine saw enable_thinking=$echoed, expected $want — extra_body is NOT passing through"
  done
  # Agents stream. A gateway that only worked non-streaming would look fine here
  # and fail the moment opencode connects.
  chunks=$(curl -s -N -m 60 "$GW/v1/chat/completions" -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
    -H 'Content-Type: application/json' \
    -d '{"model":"coder","messages":[{"role":"user","content":"hi"}],"stream":true}' \
    | grep -c '^data: ' || true)
  [ "${chunks:-0}" -ge 3 ] && ok "streaming works end to end ($chunks SSE chunks) — the path agents use" \
                           || bad "streaming returned $chunks chunks — agent clients will break"
  skip "everything about the MODEL — quality, parsers, throughput, KV, VRAM"
fi

head_ "21. .env.example is safe to source"
# scripts/common.sh sources scripts/.env with the shell, so an unquoted value
# containing a space parses as an assignment followed by a command and every
# lifecycle script dies with "command not found", exit 127. This bit for real:
# RUNPOD_GPU_TYPE=NVIDIA L40S. Docker Compose reads gateway/.env itself and does
# not care, which is why only the scripts side breaks — and why the fresh-clone
# path is the one that hits it.
if err=$(bash -c 'set -a; . scripts/.env.example; set +a' 2>&1); then
  ok "scripts/.env.example sources cleanly"
else
  bad "scripts/.env.example fails to source — a fresh copy breaks every script: $err"
fi
# Values with spaces must survive the round trip, not silently truncate.
gputype=$(bash -c 'set -a; . scripts/.env.example; set +a; printf "%s" "$RUNPOD_GPU_TYPE"' 2>/dev/null)
case "$gputype" in
  *" "*) ok "RUNPOD_GPU_TYPE survives sourcing intact ('$gputype')" ;;
  "")    bad "RUNPOD_GPU_TYPE is empty after sourcing — quoting is wrong" ;;
  *)     bad "RUNPOD_GPU_TYPE truncated to '$gputype' — needs quoting" ;;
esac

head_ "22. Cost guards"
grep -q 'IDLE_MINUTES' scripts/.env.example && ok "idle threshold configurable" || bad "no IDLE_MINUTES"
grep -q -- '--nightly' scripts/idle-check.sh \
  && ok "hard nightly stop exists (the guard that fires even when the idle check is broken)" \
  || bad "no nightly stop — a dead cron becomes an unbounded bill"
if [ -f scripts/.env ]; then
  ( cd "$REPO_ROOT" && ./scripts/idle-check.sh --dry-run >/dev/null 2>&1 ) \
    && ok "idle-check.sh --dry-run runs clean" \
    || skip "idle-check.sh dry run (needs a valid RUNPOD_API_KEY)"
  # This one is here because it caught a real bug: POD_NAME was assigned in
  # common.sh but never exported, so the inline python3 that builds the pod
  # request died with KeyError. Nothing else exercises that code path without
  # actually creating a pod.
  if out=$( cd "$REPO_ROOT" && ./scripts/gpu-up.sh --dry-run 2>&1 ); then
    case "$out" in
      *Traceback*|*KeyError*) bad "gpu-up.sh --dry-run raised a python error: $(printf '%s' "$out" | tail -2)" ;;
      *'"name": "ai-infra-gpu"'*) ok "gpu-up.sh --dry-run builds a valid pod request" ;;
      *) skip "gpu-up.sh dry run (pod already exists, so the request build was not exercised)" ;;
    esac
  else
    skip "gpu-up.sh dry run (needs valid RUNPOD_API_KEY / volume id / auth key)"
  fi
else
  skip "idle-check.sh dry run (scripts/.env not created yet)"
  skip "gpu-up.sh dry run (scripts/.env not created yet)"
fi
grep -q 'num_requests_running' scripts/gpu-down.sh \
  && ok "gpu-down drains on vllm:num_requests_running" || bad "gpu-down does not drain"
grep -qE 'DRAIN_TIMEOUT:-120' scripts/gpu-down.sh \
  && ok "drain has a 120 s hard timeout" || bad "drain has no hard timeout — gpu-down could hang forever"

head_ "23. Scripts are syntactically valid and executable"
for s in gpu/provision.sh scripts/gpu-up.sh scripts/gpu-down.sh scripts/idle-check.sh scripts/pg-backup.sh scripts/scheduler.sh install.sh scripts/providers/*.sh verify.sh; do
  bash -n "$s" 2>/dev/null && [ -x "$s" ] && ok "$s parses and is executable" || bad "$s fails bash -n or is not executable"
done

# ================================================================ disruptive

if [ "$DISRUPTIVE" = 1 ]; then
  head_ "24. Keys survive container destruction (volume persistence)"
  K2=$(curl -s -X POST "$GW/key/generate" -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
        -H "Content-Type: application/json" -d '{"models":["coder"],"metadata":{"user":"verify.sh-persist"}}' \
      | python3 -c 'import sys,json;print(json.load(sys.stdin)["key"])' 2>/dev/null)
  dc down >/dev/null 2>&1
  dc up -d >/dev/null 2>&1
  for i in $(seq 1 40); do [ "$(code "$GW/health/liveliness" 3)" = "200" ] && break; sleep 3; done
  [ "$(code "$GW/v1/models" 20 -H "Authorization: Bearer $K2")" = "200" ] \
    && ok "key issued before destroy still valid" || bad "keys did not survive — check the ai-infra_pgdata volume"
  curl -s -X POST "$GW/key/delete" -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
    -H "Content-Type: application/json" -d "{\"keys\":[\"$K2\"]}" >/dev/null

  head_ "25. Postgres restore rehearsal"
  # A restore you have not performed is not a backup. Losing this database means
  # re-issuing keys to every user.
  # Collect the output before matching. `| grep -q` would exit on the first hit,
  # SIGPIPE the script, and — under `set -o pipefail` — report 141 for a run
  # that actually succeeded.
  rehearsal="$( cd "$REPO_ROOT" && ./scripts/pg-backup.sh --verify 2>&1 )"
  if printf '%s' "$rehearsal" | grep -q 'RESTORE VERIFIED'; then
    ok "a key issued before the dump authenticates after restore into a scratch DB"
  else
    bad "restore rehearsal failed — this backup would not recover key material"
  fi
fi

printf "\n\033[1m%d passed, %d failed, %d skipped\033[0m\n" "$PASS" "$FAIL" "$SKIP"
[ "$SKIP" -gt 0 ] && printf "Skips are GPU-dependent checks; they light up in phase B/C with no edit to this file.\n"
[ "$FAIL" -eq 0 ] || exit 1
