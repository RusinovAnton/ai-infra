# Architecture

What this system is, why it is shaped this way, and where it currently stands.

Open-weight coding model on a rented GPU, reachable only through a LiteLLM
gateway on office hardware, reachable only over Tailscale. Developers get an
OpenAI-compatible endpoint; no prompt leaves the tailnet for a third-party model
provider.

This is the whole-system view. The other documents go deeper on their own slice:
[devops-setup.md](devops-setup.md) builds it, [design-notes.md](design-notes.md)
records what is deliberately absent, [lessons.md](lessons.md) records what
operating it taught us, and [developer-guide.md](developer-guide.md) is what a
user of the endpoint reads.

---

## Status

| | |
|---|---|
| **Gateway stack** | Running. Both aliases served, keys issued/scoped/revoked against Postgres, engine-down path returning an actionable 503, mock engine for onboarding without a GPU. Stood up at **$0**. |
| **GPU node** | Rented, provisioned, benchmarked and destroyed repeatedly. Tailnet join, provenance check, tool calling, drain and destroy all exercised live. |
| **Performance** | First real numbers taken 2026-08-06 — see [Measured performance](#measured-performance). Single-stream matches the arithmetic; the concurrency criterion does not. |
| **Not yet done** | The 27B A/B — `Qwen3.8-27B-FP8` is the prepared candidate, `scripts/.env` still points at the MoE primary. The TP=1-vs-TP=2 comparison (needs a second card). Offsite backups. Key-naming convention and developer onboarding. |

`./verify.sh --disruptive` → **69 passed / 0 failed / 18 skipped** with provider
credentials present, **65 / 0 / 20** on a fresh clone. Every skip is GPU- or
tailnet-dependent.

---

## Trust model — read this first

**Any rented GPU means the host operator can, in principle, read your prompts.**
Inference decrypts data in RAM and VRAM. Disk encryption does not help while the
machine is running. This is not a configuration flaw to fix; it is the nature of
renting compute.

Ranked by how much that matters:

| Option | Host-operator risk | On-demand billing |
|---|---|---|
| Confidential computing (H100 CC mode + attestation, Azure NCC / GCP A3) | Genuinely mitigated — memory encrypted from the hypervisor | Hourly |
| Dedicated bare metal (Hetzner, OVHcloud, Latitude.sh, Scaleway) | Single-tenant hardware, you own the OS; physical access remains theirs | **Monthly — cannot stop to save cost** |
| Managed GPU cloud (Lambda Labs, CoreWeave, RunPod *Secure* Cloud) | Provider hypervisor; contractual trust, datacenter-operated | Hourly |
| Marketplace (Vast.ai, RunPod *Community*) | **Host has root on your machine.** Ruled out. | Hourly |

**We run on managed GPU cloud, hourly** — the only row satisfying "most secure"
*and* "start/stop on demand" simultaneously. Marketplace is excluded outright: no
amount of hardening survives a root-level host. Bare metal is excluded because
monthly billing turns "on demand" into "keep the rental, stop the container",
which is no saving.

The accepted consequence: **the host operator can read prompts.** Prompts here
are internal source code, not regulated data, so contractual trust in a
datacenter-operated provider is the trade. Developers are told this in
[developer-guide.md](developer-guide.md#rules-of-use) rather than it living only
in an operator document. If that stops being acceptable, the answer is the
confidential-computing row, not more firewall rules.

Two consequences of hourly-managed that the rest of the system absorbs:

- **On-demand capacity is not contractual**, and it fails in bursts rather than
  occasionally. See [Capacity](#capacity-is-a-snapshot-not-a-property).
- **Anything billed by the hour keeps billing when you forget it.** The cost
  guards in [Lifecycle](#lifecycle) exist for that, and they are the part of this
  system most likely to fail silently.

---

## Target architecture

```
Teammates' devices  (Tailscale, own identities, tag-less)
        │  https://gateway.<tailnet>.ts.net    (tailscale serve, real cert)
        ▼
┌─────────────────────────────────────────────┐
│ OFFICE MACHINE            tag:gateway       │
│  LiteLLM  :4000  → bound 127.0.0.1 only     │
│  Postgres        → no published ports       │
│  scheduler       → idle stop, nightly stop, │
│                    encrypted backups        │
│  tailscaled (always on)                     │
└─────────────────────────────────────────────┘
        │  tailnet only, ACL: tag:gateway → tag:gpu:8000
        ▼
┌─────────────────────────────────────────────┐
│ RENTED GPU NODE           tag:gpu           │
│  vLLM  :8000  → tailnet address only        │
│  tailscaled (ephemeral, tagged auth key)    │
│  Cloud firewall: ALL inbound denied         │
└─────────────────────────────────────────────┘
```

What this buys:

- **vLLM has no public exposure and no published port.** Only the gateway's
  tailnet identity can reach it.
- **The GPU node accepts zero inbound public traffic** — not even SSH.
  Administration is destroy-and-recreate plus the provider console; Tailscale SSH
  is off (`--ssh=false`).
- **Users never touch the GPU node.** They hold LiteLLM keys, which grant models,
  not machines.
- **Two independent controls.** A leaked API key is useless without tailnet
  membership; tailnet membership is useless without a key.

### The bind address depends on the provider

vLLM binds `127.0.0.1` on RunPod and the node's **tailnet address** on a VM, and
the difference is not cosmetic:

- **Without `/dev/net/tun`** (the RunPod case) tailscaled runs userspace
  networking and forwards inbound tailnet connections to `127.0.0.1`. Loopback is
  correct there, and still unreachable publicly.
- **With TUN** (a rented VM, or a box you own) nothing forwards anything, so vLLM
  must bind `100.x.y.z` directly. `network_mode: host` is what makes that
  possible without publishing a port.

`gpu/provision.sh` detects the mode and picks. What must never appear on either
path is a `ports:` stanza — that would put `:8000` on the machine's public
interface, leaving the cloud firewall as the only thing between the engine and
the internet.

### Why Tailscale, given LiteLLM already has API keys

LiteLLM protects LiteLLM. It knows nothing about the network, and five jobs fall
outside it:

1. **The GPU node can have zero public exposure.** The alternative is a public IP
   with `:8000` open, protected by vLLM's `--api-key` — one static bearer token,
   no per-user scoping, no revocation granularity, no rate limits — plus TLS
   certs on a host that is destroyed nightly.
2. **Neither end needs an inbound port.** The office is behind NAT without a
   static IP; the alternative is port-forwarding plus dynamic DNS, which means an
   inference endpoint punched into the office LAN. Tailscale needs only outbound
   443 at both ends.
3. **Ephemeral IPs stop mattering.** A rented instance gets a new public address
   on every launch; with a tagged ephemeral auth key it rejoins under a stable
   name, and the ACL binds at registration — before vLLM finishes loading.
4. **The office↔GPU hop crosses the public internet.** WireGuard encrypts every
   prompt and completion end to end at no cost.
5. **Machine identity, not just a shared secret.** An engine key extracted from
   the gateway config is useless without a device carrying `tag:gateway`.

Raw WireGuard would cover 1–4, at the cost of hand-managing key distribution and
node churn on every rebuild, and losing MagicDNS and the ACL layer. Provider VPC
networking does not apply, because the gateway is on-premise.

Two costs to name when presenting this: Tailscale's coordination service is a
dependency for establishing *new* connections (existing sessions survive an
outage), and it is a third party in the trust chain — it distributes public keys
and cannot read traffic, but it controls who may join.

The converse matters too: Tailscale is no substitute for LiteLLM. On the tailnet
without keys, every teammate shares one unmetered pool with no rate limits, no
spend attribution, and no way to cut off one person.

One useful non-obvious property: **containers on the gateway host reach the
tailnet through the host** — they resolve MagicDNS names and connect to tailnet
addresses with no special networking. That is what lets the scheduler container
poll the engine's `/metrics`.

---

## Tailnet policy

`policy/tailnet-policy.hujson` is the source of truth, applied by the GitOps
action in `.github/workflows/`. The admin console is editable by any network
admin with no trail in the repo, so console edits are not how this changes — and
until the action runs, editing the file changes nothing.

The whole policy lives in `grants`:

- Members reach `tag:gateway:443`, and nothing else.
- `tag:gateway` reaches `tag:gpu:8000`. Nothing else does.
- Admins reach 22/443 on the gateway and 22/8000 on the GPU node — ports that
  something actually listens on, so the policy reads truthfully.
- Members reach their own devices (`autogroup:self`) and no one else's.

**There is no `acls` block.** A default allow-all `grants` entry silently
overrides `acls` restrictions with no warning, and new tailnets ship exactly
that.

**There is no `groups` block, and no personal identity anywhere in the file.**
Tailnet membership *is* the developer roster — you become a member by invitation
— and `autogroup:member` excludes tagged nodes, so the rented GPU box can never
match a developer rule. Reachability is not authorization anyway: reaching `:443`
gets you a 401, and the LiteLLM virtual key is what grants use. Adding a login
here would duplicate that roster in git, forever.

The cost of that choice is real: **the developer-facing path cannot be asserted
statically**, because a `tests` entry needs a concrete identity. The two
tag-based tests carry the load-bearing claims; the developer path is verified
interactively against a real non-admin account
([tailnet-admin.md](tailnet-admin.md#verifying-the-policy-honestly)). Never with
your own admin login — it matches `autogroup:admin` and passes for the wrong
reason.

### Why `tag:gpu` egress matters

The GPU node is rented, untrusted hardware, and it is a tailnet member. That is a
deliberate trade — the alternative is a public `:8000` — but it means a
compromised engine host sits inside the perimeter.

`grants` is default-deny, so the **absence** of any `src: ["tag:gpu"]` rule is
what confines it. Absence is easy to erase by accident, so it is asserted twice:
by the policy's own `tests` block, and by a `verify.sh` grep.

The node never advertises routes or an exit node — either would turn the rented
box into a path into or out of the tailnet. And `--shields-up` is deliberately
not used: it blocks *incoming* tailnet connections, and the gateway reaching vLLM
is an incoming connection. Egress confinement comes from the ACL, not shields.

---

## Models and task routing

### Primary: Qwen3.6-35B-A3B-FP8

MoE with 3B activated parameters, pinned by revision. Decode cost tracks
activated parameters rather than total, which is what makes several concurrent
agentic users viable on a single 48 GB card — and the official FP8 checkpoint at
~35 GB is what makes the one-GPU deployment possible at all. Being official also
avoids community-quant provenance risk on a brand-new architecture.

The alternative considered seriously is **Qwen3.6-27B**, which is the stronger
model on paper (SWE-bench 77.2 vs 73.4, Terminal-Bench 2.0 59.3 vs 51.5). It
loses on throughput, and the reasoning is worth keeping.

**`Qwen3.8-27B-FP8` supersedes it as the prepared candidate** — geometrically
identical text tower, same 30.9 GB, same parsers — so the throughput argument
below applies to it unchanged and was not re-derived. What is *not* carried over
is the chat template: 3.8 inverts the `preserve_thinking` default, which
`gateway/config.yaml` now pins explicitly on both aliases *before* the swap,
because the value is a no-op on the current primary and load-bearing on 3.8. See
[lessons.md](lessons.md#a-checkpoints-chat-template-is-several-contracts-not-one).

A dense 27B reads all 27B parameters per token; the MoE reads ~3B. A single
opencode or Claude Code task spans many turns and tens of thousands of output
tokens — at 20 tok/s a 20k-token task takes ~17 minutes, at 100 tok/s it takes
~3. The first is not an interactive tool. And **throughput converts into quality
while quality does not convert back**: the MoE's headroom buys a 32k reasoning
budget, retries, multi-attempt agentic loops. The dense model's benchmark
advantage cannot be spent on being faster.

This section used to list three further points, each claimed to be individually
sufficient: no official FP8 checkpoint (~54 GB BF16), a KV cache ~3× larger per
token, and no concurrency headroom at 54 GB of weights. **Two of the three are no
longer true.** `Qwen/Qwen3.6-27B-FP8` is an official Qwen checkpoint (published
2026-04-21, revision `e89b16eb`, ungated, safetensors only) and it is **30.9 GB**,
not 54 — so it fits one card, and the headroom argument built on 54 GB goes with
it.

What survives is the KV cache, and it decides the question on its own:

```
Qwen3.6-27B-FP8   weights 30.9 GB  →  ~12 GB KV  →  ~190k tokens aggregate
                                       @ 65k ctx   ≈ 3 concurrent full-context streams
```

Half the concurrency of the MoE, on top of reading ~9× the parameters per token.
Slower per stream *and* fewer streams, for +3.8 SWE-bench. The throughput
argument above is now the whole case, and it still holds.

The 27B remains the A/B candidate, and it is now a **same-card** A/B — a
`MODEL_ID` / `MODEL_REVISION` swap in `scripts/.env`, no hardware change, which is
not what this section used to say. Switch only on a *task-class* failure that the
reasoning budget cannot close — not on a benchmark delta.

### These are vision-language models

`Qwen3.6-35B-A3B`, its FP8 checkpoint, and the `Qwen3.6-27B` A/B candidate are
all `...ForConditionalGeneration` with a `vision_config`, `image_token_id` and
`video_token_id`. **There is no text-only variant in this family**, so this is
not a reason to go looking for a swap.

The text tower is what the sizing rests on and is unaffected: 40 layers, 2 KV
heads, `head_dim` 256, 1-in-4 full attention. The vision tower is ~0.4B params,
~0.9 GB unquantized — noise against a 43.2 GB budget. The part worth watching is
vLLM's **multimodal profiling reservation**: it profiles with a dummy image at
maximum resolution, which can reserve more than the tower weights and lands
directly against KV cache. `--limit-mm-per-prompt={"image":0,"video":0}` is
written out and commented in `gpu/docker-compose.yml`; if you set it, verify the
chat template still applies cleanly.

### Hybrid attention is why one card is enough

Qwen3.5 and 3.6 are Gated DeltaNet + sparse attention hybrids, not classic
transformers. Roughly one layer in four is full attention; the rest carry a
constant-size recurrent state that does not grow with sequence length. KV cache
per token, BF16:

| Model | Full-attn layers | KV per token |
|---|---|---|
| Qwen2.5-Coder-32B | 64 / 64 | **262 KB** |
| Qwen3.6-27B | 16 / 64 | ~64 KB |
| Qwen3.6-35B-A3B | ~10 / 40 | **~20 KB** |
| Qwen3.5-122B-A10B | 12 / 48 | ~24 KB |

The 122B row is the useful one for intuition: 3.5× the parameters of the 35B for
20% more KV per token, because KV tracks full-attention layers and KV heads, not
model size. What the column does *not* carry is the recurrent state, which is per
*sequence* rather than per token: ~151 MB per sequence on the 122B, enough that
`--max-num-seqs` stops being a ceiling and becomes a sizing decision. See
[devops-setup.md §10.2](devops-setup.md#102-max_num_seqs-is-a-sizing-decision-not-a-ceiling).

A 13× reduction against a classic-attention model of similar size. This is the
whole reason a single card is viable, which is why the KV-profiling check in
`verify.sh` is load-bearing: if vLLM ever takes a generic-attention path, the
sizing below is void.

VRAM budget, 1 × 48 GB card at 0.90 utilisation → 43.2 GB usable:

```
Qwen3.6-35B-A3B-FP8   weights ~35 GB  →  ~8.2 GB KV  →  ~410k tokens aggregate
                                          @ 65k ctx   ≈ 6 concurrent full-context streams
```

A second card (TP=2, 86.4 GB usable) would lift that to ~51 GB KV → 131k context
at ~19 streams. A config change and an hourly line item, not a redesign.

### The GPU generation is constrained by FP8

**FP8 needs Ada Lovelace or newer.** L40S and RTX 6000 Ada have native FP8 tensor
cores. A6000, A40 and A100 are Ampere and do not — serving the FP8 checkpoint on
them is emulation or an upcast at load: a silent performance loss, not an error
you would see. `gpu-up.sh`'s capacity fallback excludes Ampere by allowlist and
prints what it rejected.

This is not a cost argument, and the intuitive cost argument is backwards. Live
pricing at the time of writing: A6000 **$0.33/hr**, L40S **$0.79/hr** — so
2 × A6000 is *cheaper* than one L40S. The decision stands on FP8 and on ~70 GB of
BF16 weights not fitting one 48 GB card, not on price. Worth re-examining if a
cheaper Ada-or-newer *pair* appears. (2 × RTX 3090 cannot run this model at all:
no FP8, and 35 GB exceeds 24 GB even sharded.)

If only Ampere is orderable, the contingency is 2 × A6000/A40 on BF16 from day
one. What is not acceptable is ordering Ampere and serving the FP8 checkpoint
anyway.

**The constraint is on the checkpoint, not on the hardware**, which is easy to
read backwards from this section. A checkpoint that does not use FP8 does not care
what the tensor cores can do, and there is now a config that leans on exactly
that: Qwen3.5-122B-A10B GPTQ-Int4 on 2 × A6000, where Ampere costs nothing and
the pair is less than half the price of 2 × L40S
([devops-setup.md §10](devops-setup.md#10-the-big-model-qwen35-122b-a10b-on-2--a6000-or-2--l40s)).
So `GPU_FP8_FAMILIES` is a *model-dependent* allowlist that happens to be pinned
to FP8 today, and widening it to Ampere is correct only while `MODEL_ID` is a
non-FP8 checkpoint. `verify.sh` fails the combination rather than trusting anyone
to remember, because the failure it prevents — Ampere rented to serve FP8 — is
invisible at runtime.

### Big-model candidate: Qwen3.5-122B-A10B (2 cards)

A different axis from the 27B A/B: more total capability at 3× the activated
parameters, on two cards instead of one. Only the GPTQ-Int4 build fits 96 GB
(65.05 GB, against ~127 GB for FP8 and ~250 GB for BF16), so this is an INT4
config — but an INT4 config of an **official Qwen checkpoint**, which is what
separates it from the community-quant route in §9 and keeps the provenance
allowlist in `gpu/provision.sh` untouched.

The case against it is the same case that chose the MoE over the dense 27B, and it
applies with more force: 10B activated against 3B is slower per stream, and a
config that is slower has to lose a real task class to be worth adopting. Treat
it as the answer to "the 35B cannot do this at all", measured with
`scripts/bench.sh`, not to "the 35B could be better".

And it costs a generation. Qwen3.6 exists only as 27B and 35B-A3B — there is no
3.6 large MoE — so this config trades 3.6's coding and agentic gains for parameter
count, on top of the throughput trade. Two things moving at once is why the
decision here is a bench run and not a table.

### Two aliases, one engine

| Alias | Thinking | For |
|---|---|---|
| `coder` | off | default agentic coding — opencode, Claude Code, aider |
| `coder-max` | on | architecture, hard debugging, tricky refactors |

Same weights, so switching tiers costs nothing and needs no reload. Routing is
client-selected by alias; scope the expensive tier with key permissions rather
than trusting convention.

**There is no small "fast" tier.** A dense 9B activates 3× the parameters of the
35B-A3B MoE, so it would be slower per token *and* worse at code. Per-GPU-hour
billing removes the other usual motive: a second engine on an already-rented box
saves nothing and costs VRAM, a second cold start, a second health check and a
second failure mode. Autocomplete is the one workload that would justify
revisiting this, and it wants a 2–4B model on a dedicated endpoint — a separate
product decision, not an alias here.

### Thinking is on by default, and it is a live footgun

Every model in this line thinks by default. Two consequences that reach users:

- **A `max_tokens` cap can truncate mid-reasoning** and return
  `finish_reason: length` with **empty** `content` — a request that burned GPU
  time and produced nothing, presenting as a broken model rather than a cap.
  Measured: on a *trivial* prompt, `coder-max` produced 2048 tokens of pure
  reasoning in ~20 s without reaching an answer.
- **Reasoning tokens are billed GPU-seconds**, so a cap is still wanted — sized
  per alias, generous on `coder-max`.

`--reasoning-parser qwen3` is required even on the non-thinking alias; without it
reasoning text lands inside `content`.

### Context length

Native is 262,144 tokens; we serve **65,536**. KV budget scales linearly with
`--max-model-len`, and 65k is enough for agents working a real repository while
holding ~6 full-context streams. Chasing the full window trades concurrency for
context no coding agent uses, and prefill cost grows with prompt length whether
or not the extra window is filled.

---

## GPU node

`gpu/provision.sh` runs **on the node**: tailnet join, weights provenance,
engine launch, failure reporting. `gpu/docker-compose.yml` carries the same flags
for providers that rent a whole VM.

A RunPod pod is a single container, so there is no nested Docker there and the
compose file cannot run — `provision.sh` detects this and runs vLLM directly.
**The flags are identical on both paths and must not drift**; they exist in two
files, which is the accepted cost of supporting both an owned box and a rented
pod.

- **Ephemeral, tagged, pre-approved auth key.** The tag applies at registration,
  so the ACL binds before vLLM starts. Keys expire in 1–90 days; rotate on that
  cadence, and note revoking a key does not deauthorize connected nodes.
- **No published port, ever.** Bind address per
  [above](#the-bind-address-depends-on-the-provider).
- **Cloud firewall denies all inbound.** Outbound: TCP 443 (Tailscale
  coordination, DERP, Hugging Face), **UDP 41641** and **UDP 3478**.

  The UDP rules are a performance requirement, not a nicety. Tailscale
  establishes *direct* peer connections over UDP 41641, using STUN on 3478 for
  NAT traversal. A firewall allowing only TCP/443 still works — it silently falls
  back to DERP relays — so the failure hides rather than announcing itself, on
  the hottest path in the system. `tailscale status` on the gateway must read
  `direct`, not `relay`.
- **Engine secret injected at boot, never baked into provider metadata.** Passing
  it via cloud-init writes it onto the exact host named as the threat in the
  trust model. Drivers that can deliver a fresh secret at create time set
  `PROVIDER_INJECTS_SECRET=1`; `gpu-up.sh` then rotates on every launch, and
  warns when it cannot. The secret is defence in depth — the ACL is the real
  control — but a long-lived one in metadata is not acceptable.
- **Weights pinned by commit SHA** with `--revision`, provenance checked before
  the first download: official `Qwen` org, `safetensors` not pickle, plausible
  commit history. A rebuilt node fetches byte-identical weights.
- **No prompt logging** (`--no-enable-log-requests`) — prompts are not written to
  disk on hardware we do not own.

**No persistent weights volume.** Weights go to container disk, billed only while
the pod exists. A network volume buys ~34 s of cold start (measured: 35 GB in
34 s cold, ~1 s warm) and costs a 24/7 bill plus a hard pin to one datacenter
forever — and only ~17 datacenters support volumes at all, which in practice can
exclude every region where a suitable GPU currently has stock. `RUNPOD_VOLUME_ID`
is optional and empty by default.

Engine flags:

```
--model=Qwen/Qwen3.6-35B-A3B-FP8
--revision=<pinned-commit-sha>
--served-model-name=coder
--host=<tailnet address>            # never 0.0.0.0
--port=8000
--tensor-parallel-size=1
--max-model-len=65536
--gpu-memory-utilization=0.90
--max-num-seqs=64
--api-key=<engine-secret>           # defence in depth; the ACL is the real control
--no-enable-log-requests
--enable-auto-tool-choice
--tool-call-parser=qwen3_coder
--reasoning-parser=qwen3
```

Image pinned by digest (vLLM v0.26.0). Gated DeltaNet support is recent, so
≥ 0.19.0 is a hard floor rather than a preference.

Details that bite:

- **`--max-num-seqs=64`, not the 256 default.** One Mamba cache block is
  allocated per decode sequence on this architecture, and 256 of them does not
  fit beside a 65k context on 48 GB.
- **The tool-call and reasoning parsers pair with `MODEL_ID`.** Both come from
  `scripts/.env`, set immediately beside the model and its revision, because they
  are one decision with it: `qwen3_coder` / `qwen3` for Qwen3.6, `glm47` / `glm47`
  for GLM-4.7-Flash, never `hermes` for either. A wrong parser returns prose
  where agents expect `tool_calls` and **fails silently** — aider will not
  surface it because it uses text diffs; opencode and Claude Code will. `verify.sh`
  checks the pairing, not just the presence of the flags, because the failure mode
  is a model swap that leaves the old parser behind.
- **`--gpu-memory-utilization` is a fraction of the whole card**, not of what
  remains. 0.90 is safe only because this is the only engine.
- **`ipc: host` the same day a second GPU arrives.** TP=1 does not need it;
  multi-GPU startup without it fails with a cryptic NCCL error. It sits commented
  in the compose file with that note.
- **TP must divide the KV head count.** This model has 2, so TP ∈ {1, 2} — the
  scale-up ceiling is two GPUs; it cannot spread to four.
- **`--enable-prefix-caching` is off deliberately.** High value for agentic
  traffic, which repeats long system prompts and file context, but Mamba-cache
  prefix caching is documented as experimental on this architecture. Enable later
  as a discrete, separately-verified change.

### Failure modes specific to rented hardware

Three things are structurally different when the machine is not yours. All three
are caught by code now; the full accounts are in [lessons.md](lessons.md).

**Pinning the image does not pin the flags the image accepts.** A renamed vLLM
flag makes argparse exit fatally within a second, the platform's restart policy
loops the container, and the result is externally indistinguishable from a slow
cold start — same pod status, same tailnet presence, same silence on the engine
port — while billing continues. `scripts/engine-preflight.sh` validates every
flag against the pinned image before anything is rented.

**The diagnosis has a shorter lifetime than the fix.** Destroying a failed pod —
the obvious thing to do when it is billing and broken — destroys the only copy of
the log, and the provider offers no log API. `provision.sh` therefore does not
`exec` vLLM: it keeps the exit code, tees the output, and if the engine dies it
serves the failure as a `503` with `X-Engine-Failed` on `:8000`, the one port the
gateway is allowed to reach. `gpu-up.sh` polls for that and aborts in seconds
with the root cause instead of waiting out a timeout at a dollar an hour.

**The host's driver is the other half of the contract.** The image's torch is a
CUDA 13.0 build; a rented fleet places you on whatever driver the host has.
`allowedCudaVersions` is sent on every launch, and the floor is read out of the
image rather than guessed.

### Node names are requested, not assigned

MagicDNS does not reuse a name that is in use, and **ephemeral means eventually
reaped, not promptly reaped** — the audit log shows roughly an hour. So a
relaunch inside that window joins as `gpu-1` while the gateway keeps resolving
`gpu` to a machine that no longer exists. Every symptom of that reads as "the
engine never started".

Two layers handle it: `gpu-up.sh` reads the node's **actual** DNS name back from
the tailnet and rewrites `ENGINE_API_BASE` (recreating the gateway) when it
differs, and `provision.sh` traps SIGTERM to run `tailscale logout` before dying,
which removes an ephemeral node immediately so the name is free before any
relaunch. The engine runs backgrounded behind a `wait` specifically so the trap
can fire mid-flight.

---

## Office gateway

`gateway/` — LiteLLM + Postgres, digest-pinned, loopback-bound.

`config.yaml` carries both aliases over one engine, differing only in the
thinking toggle. `api_base` is an environment variable rather than a literal,
because the node-name read-back rewrites it.

`max_tokens` per alias is purely a **cost** guard. The runaway-blocks-everyone
failure mode from Ollama's single slot does not apply — vLLM batches continuously
— but an uncapped client still burns GPU hours, and on the thinking alias an
*under*-sized cap silently produces empty completions.

The alias split depends on LiteLLM forwarding `chat_template_kwargs` through to
vLLM; `verify.sh` checks that `coder` shows no reasoning and `coder-max` shows
both fields populated. If that passthrough ever breaks, the answer is to collapse
to a single thinking alias with a generous cap — **not** a second copy of the
engine. Spending another 35 GB of VRAM to change a chat-template flag is not a
trade worth making.

Settings that carry weight:

- **`drop_params: true`.** Clients that know a model reasons send OpenAI-isms
  like `reasoning_effort`; vLLM's OpenAI surface does not take that parameter,
  and without this LiteLLM rejects the whole request rather than forwarding it.
  Safe here *because this gateway fronts exactly one engine* — nothing dropped is
  load-bearing. `extra_body` passthrough is unaffected, and `verify.sh` asserts
  that.
- **`turn_off_message_logging`, not `disable_spend_logs`.** They sound similar
  and do opposite things: the former redacts prompt and response content while
  keeping spend rows; the latter stops writing spend rows at all. The spend rows
  are what the idle killer queries.
- **`timeout: 600`.** `coder-max` with a 32k reasoning budget legitimately runs
  for minutes; a 30 s default would cancel real work and look like an engine
  fault.
- **`fallbacks: coder-max → coder`** covers a thinking-path failure and nothing
  else. If the node is down, both aliases are down. A fallback that could survive
  a dead node would have to be a hosted API, reintroducing the third-party prompt
  exposure this architecture exists to avoid — a deliberate omission, not an
  oversight.
- **`background_health_checks`** is what makes `/health` cheap enough to poll.

**When the GPU is down**, `error_hook.py` turns an unreachable engine into a 503
that names the cause and the fix, instead of a bare 500 that reads like a gateway
bug. It is a LiteLLM callback, so it needs no proxy in front. Monitor gateway and
engine liveness **separately** — `/health/liveliness` answers from the gateway
alone, so a green gateway with a dead engine looks healthy.

Ingress is `tailscale serve --bg http://127.0.0.1:4000`: a real certificate, TLS,
and `:4000` off the office LAN. Two things to know before doing it — HTTPS
certificates must be enabled for the tailnet first, and the **first `serve` or
`cert` writes the node's exact FQDN into a public Certificate Transparency log,
permanently**. Set the node name before anything requests a certificate.

Postgres publishes no ports and is backed up encrypted by `scripts/pg-backup.sh`
(dump, rehearsed restore, retention audit). **A restore you have not performed is
not a backup** — losing this database means re-issuing keys to every user.

A mock engine ships (`docker-compose.mock-engine.yml`, stdlib only) so developers
can be onboarded and clients configured with no GPU running and nothing spent.
Note what it deliberately cannot do: `verify.sh` grades almost nothing under the
mock, because a stub returns well-formed `tool_calls` by construction and so
cannot fail the way a wrong `--tool-call-parser` does. A check that can only pass
is worse than no check.

### Attribution, and why there is no reverse proxy

Docker's port publishing masquerades the source address, so LiteLLM logs every
request as coming from the bridge. The obvious fix is a reverse proxy setting
`X-Forwarded-For`. Three reasons it is the wrong fix here:

1. **A containerised Caddy does not solve it** — it sees the bridge address
   itself. It only works installed on the host or with host networking, which
   means one more thing outside compose on the machine whose reliability is
   already a listed risk.
2. **`tailscale serve` already provides strictly better identity, for free.** It
   injects `Tailscale-User-Login` and `Tailscale-User-Name`: tailnet-authenticated
   *user* identity, which survives a laptop changing networks and names a person
   rather than a device. Serve also **strips these headers if a client sends
   them**, so they cannot be spoofed.
3. **An IP was never the answer.** Tailnet addresses are per-device; anyone with
   a laptop and a desktop is two, a phone is three.

So attribution is two independent layers: **`metadata.user` on the virtual key**
— per-person by construction, and what revocation and rate limits act on — cross-
checked against **`Tailscale-User-Login`** at the serve hop. A mismatch is a real
signal: a shared key, or a key used from an unexpected identity. Decide the
key-naming convention *before* issuing any keys; retrofitting it means re-issuing
to everyone.

The header is trustworthy **only** because serve is the sole path in. Adding a
proxy would not merely be unnecessary — it would introduce the spoofing risk that
makes the header safe to trust today. Same reason `:4000` stays on loopback, and
the same reason the `/ui` trailing-slash quirk is lived with rather than "fixed"
by opening port 80.

---

## Lifecycle

`scripts/gpu-up.sh` / `gpu-down.sh` call a provider driver:

1. `gpu-up` creates the node, injects the ephemeral tagged auth key, waits for
   `tag:gpu` online, reads back the node's real DNS name, polls the engine
   through the tailnet, then reports ready. `tag:gpu` appearing online is **not**
   readiness — weights still have to load. It aborts early on the
   `X-Engine-Failed` path rather than waiting out a timeout.
2. `gpu-down` **drains, then** destroys (ephemeral) or stops the engine
   (persistent). Draining polls `vllm:num_requests_running` to zero with a hard
   timeout, after which it destroys anyway and logs it — exercised live: one
   request in flight, waited ~6 s, drained, destroyed.

**Nothing may block `gpu-down`.** A validation failure that prevents shutting a
node down turns a config problem into an unbounded bill. Placeholder guards run
only on paths that *create* things, for exactly this reason.

### The provider boundary

The gateway knows one thing about the engine: a URL. That is the whole coupling,
and it is why changing GPU supplier is a line in `scripts/.env` rather than a
migration. `scripts/providers/*.sh` is the only place a provider may be named,
and `verify.sh` asserts that rather than trusting it — coupling leaks back in one
convenient reference at a time.

A driver implements six functions and one constant; three ship (`runpod`
ephemeral, `ssh` and `manual` persistent). The contract is in
[scripts/providers/README.md](../scripts/providers/README.md).

`PROVIDER_KIND` is the distinction carrying real weight. An `ephemeral` node is
**destroyed** when idle, because a stopped rented pod still bills. A `persistent`
one is only ever **stopped**: on hardware you own, a wrong shutdown costs minutes
and a wrong deletion costs a rebuild. `verify.sh` greps persistent drivers for
destructive calls, because that asymmetry is the one bug in this layer you cannot
undo.

### Capacity is a snapshot, not a property

Availability for a *specific* card swings within the hour — one Ada card read
`stock=Low`, then `null` twenty minutes later, then `NONE` globally, while three
other suitable cards had stock all day. Two things follow:

- **Anything that reads availability from config is asserting something the
  provider does not guarantee.** `gpu-up.sh --check-capacity` asks at the moment
  of use.
- **Design for "any card meeting these constraints", not one model number.** On a
  capacity error, `gpu-up.sh` lists the cards that can serve this model and have
  stock right now, with prices. The filter is not just VRAM — Ampere cards are
  excluded deliberately, because they would serve the FP8 checkpoint far slower
  without erroring.

Worth knowing while working against the provider API: **the REST API is not the
whole API.** GPU types, datacenters, availability and pod logs are absent from
RunPod's REST surface and live on GraphQL, which needs its own key scope.

### Cost guards

The top cost failure is not an expensive instance — it is a forgotten `gpu-down`
over a weekend. `max_tokens` caps a request; nothing else caps a month.

**45 minutes idle**, measured from the LiteLLM spend log's last request. Cold
start is a few minutes, so a wrong shutdown costs a developer ~5 minutes while a
wrong *non*-shutdown costs a full GPU-hour every hour. The asymmetry favours
firing early.

**Plus a hard nightly stop at a fixed time, idle or not.** This matters more than
the threshold value. The failure that produces a surprise bill is not a threshold
tuned slightly wrong — it is the idle check silently not running. A fixed nightly
stop bounds the worst case to one day regardless of whether any of that logic
works. Do not tune the threshold in place of the nightly stop.

Both run in `scripts/scheduler.sh`, **in the stack rather than host cron**: cron
does not fire while a machine sleeps and never catches up, so a closed lid
silently skips both guards. The scheduler recovers missed windows on wake. It
still does not run while the host is asleep — **on a laptop, the provider-side
spend alert is the only guard that actually holds.**

The scheduler is also where the credential split deliberately breaks.
`scripts/.env` is kept apart from `gateway/.env` so the gateway host need never
hold a key that can create billable instances — but the idle check needs the
spend log (gateway-only) *and* the provider API, so one host must hold both. The
scheduler container makes that explicit rather than accidental, and mounts no
Docker socket: otherwise a container holding the provider key would also control
the host's Docker daemon. The separation still buys something real — the *engine*
node never holds either.

---

## Verification

```bash
./verify.sh --disruptive
```

~85 checks. It must be **0 failed** before claiming anything works; skips are
GPU- and tailnet-dependent and clear as [devops-setup.md](devops-setup.md) is
worked through.

What it asserts, beyond the obvious happy path:

| Check | Expected |
|---|---|
| From a user device: `tag:gpu:8000` | **must fail** |
| From the GPU node: `tag:gateway` on 443, 22, 4000 | **all must fail** |
| From the public internet: GPU node's IP, any port | all refused |
| No provider named outside `scripts/providers/` | pass |
| Persistent drivers contain no destructive call | pass |
| No `src: ["tag:gpu"]` grant in the policy | pass |
| Retired engine flags (`--disable-log-requests`) | **fail**, not tolerate — it prevents the engine from starting at all |
| KV-cache profiling at startup | per-token KV in the ~20 KB class; a generic-attention fallback voids the sizing |
| Tool calling on **each** alias | structured `tool_calls`, not prose |
| Thinking split | `coder` no reasoning; `coder-max` both fields populated |
| `Tailscale-User-Login` | present via serve, and **stripped** when a client sends its own |
| Scoped key against an unlisted model | 403 |
| Rate limit, then revocation | 429, then 401 |
| Keys survive a gateway rebuild | valid after `compose down && up` |
| `turn_off_message_logging` in force | spend rows present, no prompt text in `LiteLLM_SpendLogs` |
| Postgres restore into a scratch DB | a key issued before the dump still authenticates after |
| `tailscale status` | GPU node reads `direct`, not `relay` |
| Whole node down | actionable 503, not a bare 500; `/v1/models` still served |
| Idle shutdown dry-run | fires after the threshold; does **not** fire mid-session |

Two things verification itself taught: **check ACL enforcement from a genuinely
separate identity** (your own devices match the admin grant and pass for the
wrong reason), and **talk to `127.0.0.1`, never `localhost`** — on a dual-stack
machine `localhost` is two addresses, and whichever process bound the other
family first can silently intercept every check.

---

## Measured performance

2026-08-06, 1 × L40S, FP8, 65k context, `max_num_seqs=64`. Measured with
`scripts/bench.sh` through the full developer path (tailnet → serve → LiteLLM →
engine), against the committed corpus in `bench/tasks/` so future numbers are
comparable.

- **Single stream:** TTFT 0.25–0.42 s, decode **65–106 tok/s**. The bandwidth
  arithmetic predicted "100+" for this MoE; it holds.
- **Five concurrent ~6k-token prompts:** TTFT median 5.1 s, **p95 7.98 s** —
  against a < 5 s bar, a fail. **Zero preemptions**, so KV cache is not the
  limit: **prefill is.** Per-stream decode held at 36–60 tok/s.
- **Thinking tier:** 2048 tokens of pure reasoning in ~20 s on a trivial prompt,
  without reaching an answer.

Read the concurrency result carefully before buying a second card. The bench
fires all five prompts in the same instant, the strictest possible reading of
"five concurrent streams"; five humans behave more like Poisson arrivals, and
simultaneous 6k-token prefills are the worst case rather than the normal one.
The honest next step is a real-corpus run plus a view on how often five
developers actually collide.

Since the bottleneck is prefill rather than KV, `--enable-prefix-caching` is now
the highest-value deferred item — agentic traffic repeats exactly the long
prefixes that are costing us. A second card would also help, by adding prefill
compute and lifting context to 131k, but it buys a worst case that may rarely
happen, at ~$0.79/hr.

---

## Risks accepted

- **Host operator access to RAM/VRAM.** Unfixable at this layer; confidential
  computing is the only real answer.
- **Office uplink is a single point of failure.** Both ends of a tailnet
  connection need internet. A small always-on VPS for the gateway is the escape
  hatch if that becomes unacceptable.
- **Office machine reliability** — UPS, unattended reboots, tested restore.
- **Backups live on the machine they protect.** Offsite is an open item; until it
  exists, a dead office server means re-issuing every key.
- **Nothing guards a sleeping host.** The provider-side spend alert is the only
  guard that holds on a laptop.
- **The rented node is a tailnet member**, confined only by `grants` default-deny
  — enforced by the *absence* of a rule, asserted twice.
- **Tailscale is a third party in the trust chain**, and its coordination service
  is a dependency for establishing new connections.
- **Ephemeral nodes are reaped in ~an hour, not promptly.** Mitigated by
  logout-on-shutdown plus name read-back.
- **On-demand capacity is not contractual**, and it fails in bursts.
- **Single engine, single point of failure.** No meaningful fallback exists that
  does not send prompts to a third party.
- **Gated DeltaNet is a young code path in vLLM.** The KV economics the sizing
  rests on depend on vLLM taking the hybrid path.
- **FP8 requires Ada or newer.** Ordering Ampere and serving FP8 is a silent
  performance loss, not an error.
- **Cold start** on each `gpu-up`: ~34 s to fetch weights, plus load into VRAM.

Rough edges found by verification and left unfixed — a misdiagnosing
`error_hook` on a wrong port, `.env` overriding the caller's environment, the
RunPod API base not being overridable for tests — are listed in
[design-notes.md](design-notes.md#rough-edges-found-by-verification).

---

## Decisions

| Decision | Choice | Deciding argument |
|---|---|---|
| Provider class | Managed GPU cloud, hourly | Only option both datacenter-tier and stoppable. Accepted: the host can read prompts |
| Provider | A driver interface, not a commitment | Coupling is one URL. Six functions in `scripts/providers/`; switching supplier is a config line |
| `PROVIDER_KIND` | `ephemeral` vs `persistent` | A wrong shutdown costs minutes; a wrong deletion costs a rebuild. Grepped for, because it is the one unrecoverable bug here |
| Region | EU, ordered by availability | RTT is TTFT-only noise. The useful question is whether the GPU's region shares a failure mode with the office that depends on it |
| GPU selection | A card *class*, not a model number | Capacity for a specific card swings within the hour; across the suitable class it is steady |
| GPU type | Ada or newer (L40S, RTX 6000 Ada) | FP8 needs Ada. Not a cost argument — 2 × A6000 is *cheaper* than 1 × L40S |
| GPU count | 1 | ~6 full-context streams at 65k. Second card is a config change plus `ipc: host`, not a redesign |
| Primary model | Qwen3.6-35B-A3B-FP8 | ~5× decode over dense 27B; measured 65–106 tok/s. Throughput converts to quality via reasoning budget; quality does not convert back |
| Weights volume | None | Buys ~34 s of cold start; costs a 24/7 bill and a datacenter pin that can exclude every region with stock |
| Tiers | 2 aliases, 1 engine | A dense 9B activates 3× the params of the MoE: slower *and* worse. Per-GPU-hour billing means a second engine saves nothing |
| Context | 65,536 | KV budget on one card; covers real-repo agent work at 6 streams |
| Attribution | Keys + `Tailscale-User-Login` | Better than IP, free, unspoofable *because* serve is the sole ingress |
| Identities in the policy | None | `autogroup:member` is the roster. Cost: the dev path is verified interactively, not statically |
| Cost guards | Scheduler in the stack | Cron does not fire on a sleeping host and never catches up. The nightly stop matters more than the threshold |
| `drop_params` | On | Clients send `reasoning_effort`; vLLM rejects the whole request. Safe *because* one engine sits behind this gateway |
| Colocation / own hardware | Rejected | Makes host memory access structurally impossible, but ~$8–10k capex is a ~3-year payback against a model generation that turns over in months. The `ssh` driver means changing your mind is a config line |
| Serverless GPU / hosted APIs | Rejected | Serverless: minutes-long cold loads do not fit multi-turn agent traffic. Hosted APIs: cheaper and more accountable, but move prompts to a third-party model provider — a different threat model, not a refinement of this one |

### Revisit triggers

Conditions under which a settled decision should be reopened, each naming its
signal.

- **Enable `--enable-prefix-caching`** — the highest-value deferred item, because
  the bottleneck is prefill and agentic traffic repeats long prefixes. Blocked on
  it being experimental for Mamba caches. Verify separately; do not bundle it.
- **Add a second card** when production — not the synthetic worst case — shows
  TTFT p95 > ~5 s, or `vllm:num_preemptions_total` climbing during normal hours,
  or agents routinely truncating at 65k. Try prefix caching first.
- **A task-class failure the reasoning budget cannot close** → reconsider
  `Qwen3.8-27B-FP8`. At 30.9 GB this is now a same-card swap of `MODEL_ID` /
  `MODEL_REVISION`, not the permanent 2-GPU BF16 commitment this line used to
  describe. Expect ~3 concurrent streams instead of ~6, and much slower decode.
  Bench it against `bench/tasks/` before believing the benchmark delta.
- **A second card becomes justified** → the target is `Qwen3-Coder-Next-FP8`
  (80B-A3B, official FP8, 80.4 GB, ~3B activated), not the 27B. Same
  activated-parameter profile as today's model, so the throughput argument that
  rules out the dense 27B does not apply to it. Does not fit one 48 GB card at
  any official precision.
- **Only Ampere orderable anywhere** → 2 × A6000 on BF16. Never FP8 on Ampere.
  For 2 × RTX 3090 specifically the answer is INT4, not BF16, and the runbook is
  [devops-setup.md §9](devops-setup.md#9-alternative-hardware-2--rtx-3090).
- **A vendor with a hypervisor boundary confirms hourly billing, a scriptable
  API and a dedicated physical card** → a new file in `scripts/providers/`, at a
  quiet week. Not a migration.
- **A supplier that is monthly-only but otherwise superior** →
  `PROVIDER_KIND=persistent` already models this: the idle path stops the engine
  instead of destroying the node.
- **User count much past five** → re-run the KV arithmetic. The model's 2-KV-head
  ceiling caps this deployment at two GPUs, so past ~15 heavy users the answer is
  a second *instance*, not a bigger one.
- **Prompts stop being internal source code** → the trust model changes, and the
  answer is confidential computing, not more hardening.
- **Autocomplete becomes a requirement** → a 2–4B model on a dedicated completion
  endpoint, not an alias here.
- **`gpu-up` starts failing on capacity routinely** → widen the card class first,
  then a second region, then pay to reserve.
- **Monthly spend sustained above ~2× the steady-state estimate** → audit the
  cost guards first (they fail silently), then revisit colocation with real
  numbers.
