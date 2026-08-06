#!/usr/bin/env bash
# Validate the engine flags against the pinned image BEFORE renting a GPU.
#
# The failure this exists for: vLLM renamed --disable-log-requests, argparse
# treats an unknown flag as fatal, and the result was a crash-looping pod that
# looked exactly like a slow cold start while billing by the hour.
#
#   ./scripts/engine-preflight.sh
#
# HOW, because it is not the obvious way: `--help` inside the image also dies
# without a GPU — vLLM builds its parser from config dataclasses and computing
# their defaults runs device inference. But the flag NAMES are dataclass
# fields, and dataclasses.fields() never invokes a default factory. So the
# field names come out cleanly on any machine with Docker, GPU or not.
#
# One-time cost: pulling the engine image if not local (~10 GB). It is the same
# image the pod runs, byte-identical by digest — which is the point.
# Catches: unknown/retired flag names in both files that pass engine flags.
# Cannot catch: bad flag VALUES, OOM, or anything needing a real GPU.
set -euo pipefail
. "$(dirname "$0")/common.sh"

# On Apple silicon the image is amd64-only; emulation is slow (~1 min) but fine.
PLATFORM=()
[ "$(uname -m)" = "arm64" ] && PLATFORM=(--platform linux/amd64)

log "extracting the accepted flag list from the pinned image (slow under emulation)"
KNOWN="$(docker run --rm "${PLATFORM[@]}" --entrypoint python3 "$ENGINE_IMAGE" -c '
import dataclasses
names = set()
from vllm.engine.arg_utils import AsyncEngineArgs
names |= {f.name for f in dataclasses.fields(AsyncEngineArgs)}
try:
    from vllm.entrypoints.openai.cli_args import FrontendArgs
    names |= {f.name for f in dataclasses.fields(FrontendArgs)}
except Exception:
    pass
for n in sorted(names):
    print(n)
' 2>/dev/null)" || die "could not run the image — is Docker up? (first run pulls ~10 GB)"

[ -n "$KNOWN" ] || die "flag extraction returned nothing — the image layout may have changed; see the HOW comment above"
log "$(printf '%s\n' "$KNOWN" | wc -l | tr -d ' ') flags known to the image"

# Our flags: from provision.sh's VLLM_ARGS block and the compose command list.
flags_from() { grep -oE '^\s*(- )?--[a-z0-9-]+' "$1" | grep -oE -- '--[a-z0-9-]+' | sort -u; }

fail=0
check_file() { # check_file PATH
  local f name
  log "flags in ${1#"$REPO_ROOT"/}:"
  for f in $(flags_from "$1"); do
    case "$f" in
      # tailscale/system flags in provision.sh are not vLLM's problem
      --ssh|--advertise-tags|--hostname|--accept-dns|--auth-key|--socket|--state|--statedir|--tun) continue ;;
    esac
    # --foo-bar -> foo_bar; boolean pairs surface as --foo / --no-foo for field foo
    name="$(printf '%s' "${f#--}" | tr '-' '_')"
    if printf '%s\n' "$KNOWN" | grep -qx -e "$name" -e "${name#no_}"; then
      printf '  ok      %s\n' "$f"
    else
      printf '  UNKNOWN %s  <- the engine will exit 1 on this and the pod will crash-loop\n' "$f"
      fail=1
    fi
  done
}

check_file "$REPO_ROOT/gpu/provision.sh"
check_file "$REPO_ROOT/gpu/docker-compose.yml"

[ "$fail" = 0 ] || die "at least one flag is unknown to the pinned engine image — fix before spending money"
log "all engine flags are accepted by the pinned image"

# The other pre-pod fact the image holds: which CUDA its torch is built for.
# torch refuses any HOST driver older than this, so every entry in
# RUNPOD_CUDA_VERSIONS below it buys a placement that cannot boot.
TORCH_CUDA="$(docker run --rm "${PLATFORM[@]}" --entrypoint python3 "$ENGINE_IMAGE" \
  -c 'import torch; print(torch.version.cuda)' 2>/dev/null | tail -1)"
log "image torch is built for CUDA ${TORCH_CUDA:-unknown}"
if [ -n "${TORCH_CUDA:-}" ]; then
  bad_v=""
  for v in $(printf '%s' "${RUNPOD_CUDA_VERSIONS:-13.0}" | tr ',' ' '); do
    python3 -c "import sys; sys.exit(0 if tuple(map(int,'$v'.split('.'))) >= tuple(map(int,'$TORCH_CUDA'.split('.'))) else 1)" \
      || bad_v="$bad_v $v"
  done
  [ -z "$bad_v" ] || die "RUNPOD_CUDA_VERSIONS allows$bad_v — older than the image's CUDA $TORCH_CUDA build; torch will refuse those hosts ('driver too old')"
  log "RUNPOD_CUDA_VERSIONS is consistent with the image"
fi
