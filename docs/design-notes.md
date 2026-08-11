# Design notes

Why the system is shaped this way. Read before changing anything structural —
several things that look missing are missing on purpose.

For the system as it now stands — topology, model sizing, the provider boundary,
measured numbers — see [architecture.md](architecture.md). This file is the
narrower thing: the reasoning that would otherwise be lost, including where the
build contradicted the plan it was built from.

The *Corrections* section below reads oddly out of context for that reason: the
document being corrected is the original design plan, which is not in this repo.
So each correction is written to stand alone — it states the wrong belief and the
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
   cheaper Ada-or-newer pair appears. (This item originally ended by claiming
   2 × 3090 "cannot run this model at all: no FP8, and 35 GB/card exceeds 24 GB
   even sharded". Both halves are wrong — see correction 8.)

7. **`Qwen3.6-27B` does have an official FP8 checkpoint, and the A/B is a
   same-card swap** (found 2026-08-10, later than the rest of this section — by
   checking the Hugging Face API rather than by building). The rejection of the
   27B was written down as four reasons: slower decode, no official FP8
   checkpoint, ~3× KV cache per token, and no concurrency headroom at ~54 GB of
   BF16 weights.

   `Qwen/Qwen3.6-27B-FP8` exists — Qwen's own org, published 2026-04-21, revision
   `e89b16eb`, ungated, safetensors only, **30.9 GB**. So two of the four reasons
   are void: there is an official FP8 checkpoint, and at 30.9 GB it fits one 48 GB
   card with ~12 GB left for KV.

   The decision does not change. ~12 GB of KV at the 27B's ~64 KB/token is ~190k
   tokens — about **3** concurrent 65k streams against the MoE's 6 — and the dense
   model still reads ~9× the parameters per token. Slower per stream and fewer
   streams, for +3.8 SWE-bench.

   The part worth keeping is how the original was written. Four reasons were
   listed as if each were independently sufficient; in fact **one** carried the
   decision (throughput) and the other three were padding around it. Two of the
   three expired within four months, and had the load-bearing reason been among
   them the conclusion would have silently rotted while still reading as
   well-supported.

   Practical consequence: the 27B A/B is now cheap — `MODEL_ID` and
   `MODEL_REVISION` in `scripts/.env`, no hardware change — so if the question
   comes up again, measure it with `bench/tasks/` instead of re-arguing it. The
   2-GPU candidate is no longer the 27B either; see the revisit triggers in
   [architecture.md](architecture.md#revisit-triggers).

8. **2 × RTX 3090 can run this model — the stated reasons it could not were both
   wrong** (found 2026-08-10, while pricing owned hardware). Correction 6
   originally ended by ruling out 2 × 3090 on two grounds: no FP8, and "35 GB/card
   exceeds 24 GB even sharded."

   *Sharded* is what TP=2 means. 37.5 GB across two cards is ~18.8 GB per card,
   and 2 × 24 GB at 0.90 utilisation is 43.2 GB usable — **identical to the single
   L40S**. The capacity argument was arithmetic that forgot to divide.

   "No FP8" is not a wall either. vLLM runs FP8 weights on Ampere through FP8
   Marlin as weight-only W8A16. What actually blocks *this* checkpoint is
   narrower: FP8 Marlin's lack of block-wise and MoE coverage, and Qwen3.6's FP8
   is fine-grained block-128 **and** MoE. So the conclusion survived on a reason
   nobody had written down — the same failure as correction 7, one step worse,
   because here the reasons given were not merely padding but false.

   What is actually true: on 2 × 3090 you serve INT4 (Ampere's native low
   precision), weights drop to 21.5 GB, and you get *more* KV headroom than the
   FP8 path — ~16 concurrent 65k streams against ~6. Bandwidth is not a problem
   either; a 3090 is 936 GB/s against the L40S's 864. The real costs are INT4
   answer quality and a community quant, not capacity or speed.

   Runbook, model id and pinned revision:
   [devops-setup.md §9](devops-setup.md#9-alternative-hardware-2--rtx-3090).

   The reusable lesson, twice over now: when a decision is defended by a list,
   check whether the list is load-bearing or decorative. Both times the true
   reason was real and the reasons stacked around it rotted.

9. **`--pick` meant "only this card", and that was not the intent** (found
   2026-08-10, on a launch that failed while seven usable cards were listed on
   screen). Automatic selection walks the shortlist in price order until one
   *places*, because stock is reported globally while placement is constrained by
   `RUNPOD_DATACENTERS` and the CUDA filter — the cheapest card frequently cannot
   actually be rented. `--pick` set `candidates="$GPU_CHOICE"`, a one-entry list,
   so the interactive path silently gave up the fallback the automatic path is
   built around: picking the cheapest card by hand was *worse* than not picking at
   all.

   `--pick` now means "start here": the chosen card first, then the remaining
   shortlist in price order.

   The misleading part was the error, not the behaviour. It read `widen the
   datacenter list, relax GPU_MAX_PRICE, or wait` — naming a price cap that was
   unset, on a run whose real problem was that exactly one candidate had been
   tried. It now names the candidates actually attempted, and only suggests knobs
   that are in play. A failure message that lists plausible causes it has not
   checked sends the next person to the wrong file; `Tried, in order: …` would
   have made this a ten-second read.

10. **The engine flags encoded assumptions about *one* checkpoint, and swapping
    `MODEL_ID` was documented as if it were free** (found 2026-08-11, adding
    GLM-4.7-Flash as a test model). `scripts/.env.example` said the 27B A/B was
    "`MODEL_ID` and `MODEL_REVISION` in `scripts/.env`, no hardware change" — true
    for that swap, and it generalised badly.

    Three things were baked in beside the model rather than with it. The
    tool-call and reasoning parsers were literals in two files
    (`qwen3_coder` / `qwen3`), so a model swap left them behind — and a wrong
    parser returns prose where agents expect `tool_calls`, silently. `verify.sh`
    asserted those literals, which meant the check would go red on any correct
    swap and green on an incorrect one. And the provenance gate compared the
    publishing org to the string `Qwen`, so the guard against a typo'd or hostile
    `MODEL_ID` was also the guard against ever using a different publisher.

    Now `TOOL_CALL_PARSER` and `REASONING_PARSER` sit next to `MODEL_ID` in
    `scripts/.env` with no defaults — an unset parser aborts `provision.sh` before
    the download rather than serving prose — and `verify.sh` checks the *pairing*
    against a case statement instead of a literal. The provenance allowlist stays
    hardcoded in `gpu/provision.sh` on purpose: widening it should be a reviewed
    change, because "which orgs may put weights on hardware we do not own" is not
    the same kind of decision as "which model".

    The general shape is worth keeping: a config value that is genuinely one
    decision with another belongs *beside* it, and a check that asserts today's
    value rather than today's *invariant* fails in both directions.

11. **The sizing policy in `common.sh` is FP8-shaped, and GLM-4.7-Flash is not**
    (2026-08-11). `GPU_MIN_VRAM_GB=48` and the `GPU_FP8_FAMILIES` allowlist both
    encode the primary checkpoint: ~35 GB of FP8 weights on one Ada card. BF16
    GLM-4.7-Flash is 62.4 GB and fits neither.

    What the arithmetic actually says, at 0.90 utilisation and 54.1 kB/token of
    MLA KV — `(kv_lora_rank 512 + qk_rope 64) × 2 B × 47 layers`, so 3.55 GB per
    65k stream:

    | card | VRAM | $/hr | weights | KV left | 65k streams |
    |---|---|---|---|---|---|
    | RTX PRO 6000 Blackwell | 96 GB | 2.09 | 62.4 GB BF16 | ~21 GB | ~5.9 |
    | H100 80GB HBM3 | 80 GB | 3.29 | 62.4 GB BF16 | ~6.6 GB | ~1.9 |
    | L40S + community AWQ | 48 GB | 0.99 | 19.8 GB | ~20 GB | ~5.7 |

    The 80 GB H100 is the trap: it clears the "80 GB" bar, costs 1.6× the 96 GB
    Blackwell, and delivers a third of the concurrency. VRAM minus weights is the
    number that matters, and a floor expressed as total VRAM hides it.

    The 48 GB path exists but is not free: every quantised GLM-4.7-Flash
    checkpoint is published by an individual repackager, not by zai-org, so
    it trades ~$10/day for trusting someone who did not train the weights.
    That is why the allowlist names original publishers only.

    **Measured 2026-08-11, and the table above is pessimistic.** First live boot
    on an RTX PRO 6000 Blackwell *Workstation* Edition (96 GB, $1.89/hr — the
    Server Edition would not place):

    | | predicted | measured |
    |---|---|---|
    | KV cache | ~390k tokens | **549,712** (34,357 blocks × 16) |
    | 65k streams | ~5.9 | **8.39** |
    | cold start | — | 3m37s, pod create → `/v1/models` 200 |

    The two inputs do not reconcile: 549,712 tokens at 54.1 kB/token is 29.7 GB
    of KV, which leaves ~56.7 GB for weights at 0.90 of 96 GB — about 6 GB less
    than the 62.4 GB the BF16 parameter count predicts. So either the per-token
    MLA cost is lower than the layer arithmetic says, or the checkpoint is not
    uniformly BF16. Not chased, because it errs in our favour and the number that
    governs sizing is the measured one. Worth resolving before trusting the
    80 GB row, where a 6 GB error is the whole margin.

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

## First measured numbers (2026-08-06, 1 × L40S, FP8, 65k ctx, max_num_seqs=64)

Everything before this line in the throughput story was arithmetic. These are
measured through the full developer path (tailnet → serve → LiteLLM → engine),
with `scripts/bench.sh`:

- **Single stream:** TTFT 0.25–0.42 s, decode 65–106 tok/s. The bandwidth
  arithmetic said "MoE should reach 100+"; it does.
- **The design's exit criterion — 5 concurrent ~6k-token prompts:**
  TTFT median 5.1 s, **p95 7.98 s → FAIL** against the <5 s bar. Zero
  preemptions, so KV cache is not the limit — **prefill is**. Per-stream decode
  stayed at 36–60 tok/s.
- **Thinking tier:** on a trivial prompt, `coder-max` produced 2048 tokens of
  pure reasoning in ~20 s without reaching an answer. Clients calling it with
  small `max_tokens` see "empty" responses (`finish_reason: length`).

Caveat before acting on the FAIL: the bench fires all five prompts in the same
instant, the strictest reading of "5 concurrent streams". Five humans behave
more like Poisson arrivals; simultaneous 6k-token prefills are the worst case.
The letter of the criterion says steady state needs the second GPU — but the
honest next step is the measurement week's real-corpus run, plus a view on how
often five developers actually collide.

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

Operational failures found by *running* the system — crash loops, provider
capacity, shell traps — are in [lessons.md](lessons.md) instead. The split is:
this file is what we decided and why; that one is what the system did to us.

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
- **`idle-check.sh`'s DB-failure fail-safe is unexercised.** It needs the spend
  query to fail while a pod runs, which has not happened. (`gpu-down.sh`'s drain
  loop, formerly on this list, was exercised live on 2026-08-06: one request in
  flight, waited ~6 s, drained to zero, destroyed.)

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
