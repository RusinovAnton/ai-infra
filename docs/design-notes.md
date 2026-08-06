# Design notes

Why the system is shaped this way. Read before changing anything structural —
several things that look missing are missing on purpose.

The *Corrections* section below reads oddly out of context: it records where the
build contradicted the design document it was built from. That document is not in
this repo (it carries deployment-specific vendor and cost analysis), so the
corrections are written to stand alone — each states the wrong belief and the
measured reality, which is the part worth keeping anyway.

---

## What is deliberately not here

- **No Caddy or any reverse proxy.** `tailscale serve` already injects
  `Tailscale-User-Login` and strips client-supplied copies. That header is
  trustworthy *only* because serve is the sole path in — adding a proxy, or
  binding `:4000` beyond loopback, is what would make it spoofable.
- **No `coder-fast` tier.** A dense 9B activates 3× the parameters of the
  35B-A3B MoE: slower per token *and* worse at code. Per-GPU-hour billing means a
  second engine on an already-rented box saves nothing and costs VRAM, a second
  cold start and a second failure mode.
- **No fallback that survives a dead node.** Any such fallback is a hosted API,
  which sends prompts to a third-party model provider — the thing this
  architecture exists to avoid. A deliberate omission, not an oversight;
  `error_hook.py` handles the case instead.
- **No `--enable-prefix-caching`** yet. High value for agentic traffic, but
  Mamba-cache prefix caching is experimental on this architecture. Enable later as
  a discrete, separately-verified change.
- **No Tailscale SSH on the GPU node** (`--ssh=false`). Administration of
  untrusted hardware is destroy-and-recreate plus the provider's console.
- **No prompt logging anywhere.** The cost is real and shows up during an
  incident — see
  [incident-response.md](incident-response.md#what-evidence-exists).
- **No `acls` block in the tailnet policy.** A default allow-all `grants` entry
  silently overrides `acls` restrictions with no warning, and new tailnets ship
  exactly that. The whole policy lives in `grants`.

## Corrections to the original design

Found while building, against the design document this was built from. Each
states a belief that turned out to be wrong and what is actually true — kept
because the wrong version is the one a reader is likely to arrive with.

1. **Every Qwen3.6 candidate is a vision-language model, so "not VL" was never a
   discriminator.** `Qwen3.6-35B-A3B`, its FP8 checkpoint, *and* the
   `Qwen3.6-27B` A/B candidate are all `...ForConditionalGeneration` with a
   `vision_config`, `image_token_id` and `video_token_id`. Rejecting a candidate
   for being VL, while treating the others as text-only, does not survive
   contact with the configs. **There is no text-only variant in this family to
   swap to** — so this changes nothing about the choice, only about the stated
   reasoning. Qwen3.5-27B is still the weaker pick on its other ground:
   Qwen3.6-27B beats it on every coding metric.

   The KV arithmetic survives — `text_config` confirms 40 layers, 2 KV heads,
   `head_dim` 256 and a 1-in-4 full-attention pattern, so ~20 KB/token holds. The
   vision tower is small: 27 blocks at hidden 1152 / intermediate 4304 is ~0.4B
   params, ~0.9 GB unquantized (it sits in `modules_to_not_convert`), against a
   43.2 GB budget. Arithmetic, not measured.

   The unknown worth measuring is vLLM's **multimodal profiling reservation** — it
   profiles memory using a dummy image at maximum resolution, which can reserve
   more than the tower weights do, and that lands directly against KV cache. Peak
   VRAM on first boot decides whether
   `--limit-mm-per-prompt={"image":0,"video":0}` is worth setting; the flag is
   written out and commented in `gpu/docker-compose.yml`. Verify the chat template
   still applies cleanly if you set it.

2. **A RunPod pod is a single container, so there is no nested Docker.**
   `gpu/docker-compose.yml` cannot run there. `provision.sh` detects this and
   execs vLLM directly, using compose only on a provider that rents a whole VM.
   The flags are identical on both paths — and must not drift, since they exist
   in two files.

3. **"vLLM binds loopback" is right for RunPod and wrong for a VM.** Without
   `/dev/net/tun` — the RunPod case — tailscaled runs userspace-networking and
   forwards inbound tailnet connections to `127.0.0.1`, so loopback is correct and
   still unreachable publicly. With TUN, no interface forwards anything and vLLM
   must bind the node's tailnet address; `network_mode: host` is what makes that
   possible without publishing a port. `provision.sh` picks per mode.

4. **A RunPod network volume is pinned to one datacenter.** "Two regions
   pre-configured" is the obvious mitigation for on-demand capacity failures,
   and it is not free here: falling back to a second region means either a second 200 GB volume billing
   continuously or re-downloading 35 GB of weights. `RUNPOD_DATACENTERS` is
   ordered and honest about this; the cost of a real second region is a decision
   still to make.

5. **`docker compose restart` does not pick up a rotated `ENGINE_SECRET`** — it
   reuses the old environment. `gpu-up.sh` uses `up -d --force-recreate`.

6. **2 × A6000 is cheaper per hour than 1 × L40S**, not more expensive. Live
   pricing at the time of writing: A6000 $0.33, L40S $0.79 — so the two-card
   option is $0.66. "A second card doubles steady-state cost" is the intuitive
   objection to multi-GPU, and on these prices it is simply false. The decision still stands on a
   different ground: the A6000 is Ampere, so **no FP8 tensor cores** — serving the
   FP8 checkpoint on it is a silent performance loss, not an error you'd see, and
   the BF16 alternative needs ~70 GB against 48 GB. Worth re-examining if a
   cheaper Ada-or-newer pair appears. 2 × 3090 cannot run this model at all: no
   FP8, and 35 GB/card exceeds 24 GB even sharded.

## The provider boundary

The gateway knows one thing about the engine: a URL. That is the whole coupling,
and it is why swapping GPU supplier is a line in `scripts/.env` rather than a
migration.

`scripts/providers/*.sh` is the only place a provider may be named, and
`verify.sh` asserts that rather than trusting it — coupling leaks back in through
one convenient reference at a time.

The distinction that carries real weight is `PROVIDER_KIND`. An `ephemeral`
node is destroyed when idle, because a stopped rented pod still bills. A
`persistent` one is only ever stopped: on hardware you own, a wrong shutdown
costs minutes and a wrong deletion costs a rebuild. `verify.sh` greps persistent
drivers for destructive calls, because that asymmetry is the one bug in this
layer you cannot undo.

## Accepted risks

**The host operator can read prompts.** Inference decrypts in RAM and VRAM, and no
firewall rule changes that. Prompts here are internal source code, so contractual
trust in a datacenter-operated provider is the trade. If that stops being
acceptable, the answer is confidential computing (H100 CC + attestation), not more
hardening. Developers are told this in
[developer-guide.md](developer-guide.md#rules-of-use).

**The rented node is a tailnet member**, confined only by `grants` default-deny —
which is enforced by the *absence* of a `src: ["tag:gpu"]` rule. Absence is easy
to erase by accident, so `policy/tailnet-policy.hujson` asserts it in `tests` and
`verify.sh` greps for it.

**The cost guards need both halves of the credential split.** `scripts/.env` is
kept apart from `gateway/.env` so the gateway host need never hold a key that can
create billable instances. `idle-check.sh` breaks that: it needs the spend log,
which only exists on the gateway, *and* the provider API, to stop the pod. One
host must hold both. The scheduler container makes that explicit rather than
accidental, and deliberately mounts no Docker socket — otherwise a container
holding `RUNPOD_API_KEY` would also control the host's Docker daemon. The
separation still buys something real: the *engine* node never holds either.

**Nothing guards a sleeping host.** The scheduler recovers missed windows on
wake, which cron does not, but neither runs while the machine is asleep. On a
laptop the provider-side spend alert is the only guard that actually holds, and
[incident-response.md](incident-response.md) treats a runaway pod as a live
scenario rather than a theoretical one.

**Backups live on the machine they protect.** A backup that only exists on the
machine it protects is not one. Offsite is an open item; until it exists, a dead
office server means re-issuing every key.

**On-demand GPU capacity is not contractual.** A launch can fail at the least
convenient moment, and the network volume's datacenter pinning limits how usefully
you can fall back.

## Rough edges found by verification

Real, unfixed, and worth knowing before they confuse someone:

- ⚠️ **A wrong `ENGINE_API_BASE` port makes `error_hook.py` misdiagnose.** It
  reports "the gateway is healthy, the GPU is not — run `gpu-up.sh`" while the
  node is up. Technically the engine is unreachable; practically it's the same
  misdiagnosis the hook exists to prevent, inverted. Distinguishing
  connection-refused from a protocol error would fix it.
- ⚠️ **`.env` overrides the caller's environment** in the `scripts/` helpers —
  the opposite of Docker Compose. `FOO=x ./scripts/whatever.sh` is silently
  ignored because `load_env` re-sources the file afterwards.
- **The 503's top-level `error.type` is the literal string `"None"`**;
  `engine_unavailable` is nested in `provider_specific_fields`. Clients should
  match on the status code.
- **`RP` (the RunPod API base) is a plain assignment in `scripts/common.sh`**, not
  overridable, so the RunPod code paths cannot be pointed at a test double. They
  are unverifiable without spending money.
- **`"max retries exceeded"` is in `error_hook.py`'s unreachable-substring list.**
  It didn't false-positive in testing, but it's the entry most likely to misfire
  on an engine that *is* up.
- ⚠️ **`gpu-up.sh` hard-requires a network volume**, so the cheapest operating
  mode is unavailable. The volume bills ~$0.47/day idle while re-downloading the
  weights costs cents of GPU time per launch — it buys cold-start latency, not
  money — yet `${RUNPOD_VOLUME_ID:?}` means you cannot simply run without one
  during wiring or bursty use. Supporting a volume-less launch needs the weights
  pointed at container disk and `containerDiskInGb` re-sized, which is a real
  change rather than a config tweak.
- **`idle-check.sh`'s DB-failure fail-safe and `gpu-down.sh`'s drain loop are
  unexercised.** Both need a live pod; `find_pod_id` returns empty first, so
  neither path can be reached without real spend.

## Verification

```bash
./verify.sh --disruptive
```

**69 passed, 0 failed, 18 skipped** with provider credentials present;
**65 / 0 / 20** on a fresh clone. The total varies because the engine/mock triage
adds or drops checks depending on what is running. Every skip is GPU- or
tailnet-dependent and clears as [devops-setup.md](devops-setup.md) is worked
through.

`verify.sh` deliberately grades almost nothing under the mock engine. A stub
returns well-formed `tool_calls` by construction, so it cannot fail the way a
wrong `--tool-call-parser` does — and a check that can only pass is worse than no
check.
