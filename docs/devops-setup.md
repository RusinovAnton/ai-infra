# DevOps — build the infra from zero

**Audience:** whoever stands the system up the first time. Assumes shell access
to the server that will run the gateway, a Tailscale admin login, and — if you
are renting the GPU rather than owning it — authority to spend money.

**Result:** developers get an OpenAI-compatible endpoint at
`https://gateway.<TAILNET>.ts.net/v1`, backed by an open-weight coding model on a
GPU node, reachable from nowhere else.

The gateway runs anywhere Docker runs: an on-prem server, a VPS, or a laptop
while you are wiring it up. The GPU is a separate decision — rented by the hour,
a machine you own, or one you start by hand. Both halves are chosen in
`scripts/.env`, not in code.

Read [design-notes.md](design-notes.md) before changing anything structural —
several things that look missing are missing on purpose.

---

## 0. Order that matters

```
policy applied (tagOwners live)
   ├── then: tailscale up --advertise-tags=tag:gateway
   └── then: mint tag:gpu auth key
              └── then: gpu-up.sh
```

Tags are checked **at registration**. Join a node before `tagOwners` exists and
it registers **untagged** — the `Tags` field is then *absent*, not empty, so
every `tag:gpu` rule matches nothing and the gateway cannot reach the engine.
It presents as a firewall bug. It isn't.

Everything else can be reordered.

---

## 1. Gateway stack (no GPU, no spend)

On the server — any Linux box, VPS, or on-prem machine with Docker:

```bash
./install.sh
```

Checks prerequisites (including whether Docker is enabled at boot, which decides
whether the gateway survives a reboot), then generates every secret into
`gateway/.env` at `0600` and copies the `scripts/.env` template. It never
overwrites an existing `.env`, so it is safe to re-run.

⚠️ It prints `BACKUP_PASSPHRASE`. Put it in the team password manager before you
do anything else — lose it and every encrypted dump is scrap, and the backup
script cannot tell you it is wrong until you attempt a restore.

By hand instead:

```bash
cd gateway && cp .env.example .env && chmod 600 .env
```

Generate every secret. Do not reuse anything, do not pick something memorable:

```bash
for v in LITELLM_MASTER_KEY LITELLM_DB_PASS ENGINE_SECRET UI_PASSWORD BACKUP_PASSPHRASE; do printf '%s=%s\n' "$v" "$(openssl rand -hex 24)"; done
```

Paste those into `gateway/.env`, then **prefix `LITELLM_MASTER_KEY` with `sk-`** —
LiteLLM rejects a master key that doesn't start with it, and the error is not
obvious.

`BACKUP_PASSPHRASE` is the one you must store outside this machine. Lose it and
every encrypted dump is scrap; the backup script cannot tell you it's wrong until
you try to restore. Put it in the team password manager now, not later.

Leave `ENGINE_API_BASE` at its placeholder for the moment — [§4](#4-gpu-node)
fills it in. A placeholder is the correct Phase A state: `error_hook.py` turns an
unreachable engine into a 503 that names the fix.

```bash
cd gateway && docker compose up -d
```

```bash
./verify.sh --disruptive
```

Expect **0 failed**. Skips are GPU- and tailnet-dependent and clear as you work
through this document. A failure here is a real problem — do not proceed past it.

If anything else on this box already serves models — Ollama, LM Studio, another
vLLM — stop it. Two model servers on one host is how a developer ends up talking
to the wrong one for a week:

```bash
sudo systemctl stop ollama    # macOS: brew services stop ollama
```

## 2. Tailnet policy

Full detail in [tailnet-admin.md](tailnet-admin.md). The minimum to get moving:

1. Admin console → **DNS** → read the tailnet name (looks like `tail9a2b1.ts.net`),
   enable **MagicDNS**, enable **HTTPS Certificates**.

   This value is `<TAILNET>` throughout these docs. It is **not** a variable
   anywhere in the repo — substitute it by hand. It lands in real configuration in
   exactly one place, `ENGINE_API_BASE` in `gateway/.env` ([§4](#4-gpu-node)); every
   other occurrence is a URL you type into `curl` or an editor's settings. No need
   to write it down — from any joined machine:

   ```bash
   tailscale status --json | jq -r .MagicDNSSuffix
   ```

   Use the **full** name in URLs. MagicDNS makes the bare hostname `gateway`
   resolve, but the HTTPS certificate is issued for the FQDN, so
   `https://gateway/...` fails certificate validation while
   `https://gateway.<TAILNET>.ts.net/...` succeeds.

   ⚠️ **Name the node before it ever gets a certificate.** Enabling **HTTPS
   Certificates** publishes nothing on its own — Tailscale issues a cert only when
   `tailscale serve` or `tailscale cert` first runs on a node, and *that* is what
   writes the node's exact FQDN into a public Certificate Transparency log,
   permanently and unremovably. Serve from a machine still called
   `someones-laptop` and that name is public forever; renaming afterwards does not
   retract it. Set `--hostname` first ([§3](#3-gateway-node-on-the-tailnet)), then
   serve. The tailnet suffix itself is already an obfuscated string rather than
   your organisation's name, so a generic node name leaks nothing useful — and a
   node name is not access: the tailnet stays default-deny with no public ingress.
2. `policy/tailnet-policy.hujson` needs **no editing** — it contains no logins and
   is not meant to. The dev grant is `autogroup:member`, so tailnet membership is
   the roster. Two consequences worth understanding before you rely on it:

   - Inviting somebody grants them reachability to the gateway's `:443`, and
     nothing more. Reachability is not authorization — they get a `401` until you
     issue a virtual key, and that key is the per-person control you revoke.
   - `autogroup:member` excludes tagged devices, so the rented GPU node can never
     match a developer rule, and a *tagged* developer laptop silently stops
     matching one. That last case looks exactly like a firewall bug.

   ⚠️ **Do not add your own login to `tests`.** If you are a tailnet owner or
   admin you also match `autogroup:admin`, which legitimately grants you
   `tag:gateway:22` and `tag:gpu:8000` — so a test asserting you are denied them
   fails validation while the policy is entirely correct. A `tests` entry needs a
   concrete src, so there is no way to assert the dev path without committing
   somebody's identity; verify it interactively instead, from a non-admin account
   ([tailnet-admin.md](tailnet-admin.md#verifying-the-policy-honestly)).
3. Invite teammates (**Users → Invite**). No policy change accompanies this.
4. Paste the file into **Access Controls** → Save. Both `tests` must pass.
5. Wire GitOps so the console stops being the source of truth — see
   [tailnet-admin.md](tailnet-admin.md#policy-as-code).

## 3. Gateway node on the tailnet

On the office server:

```bash
sudo tailscale up --advertise-tags=tag:gateway --hostname=gateway
```

Two side effects, both correct for a server, both awkward to undo: the device
leaves your personal device list (it belongs to `tag:gateway` now) and **key
expiry switches off** on it.

If device approval is enabled on the tailnet, this node sits unapproved and
unreachable while looking joined. Approve it under **Machines**.

Expose the gateway. LiteLLM binds `127.0.0.1:4000`; `serve` is the only ingress:

```bash
tailscale serve --bg http://127.0.0.1:4000
```

```bash
tailscale serve status
```

`--bg` survives reboots. Do **not** add a reverse proxy and do **not** bind
`:4000` beyond loopback — the `Tailscale-User-Login` header is trustworthy only
because serve is the sole path in and strips client-supplied copies.

Confirm from another machine on the tailnet:

```bash
curl -s https://gateway.<TAILNET>.ts.net/health/liveliness
```

## 4. GPU node

**Before any launch, validate the engine flags for free:**

```bash
./scripts/engine-preflight.sh
```

It extracts the accepted flag list from the *pinned* engine image (no GPU
needed) and checks every flag we pass. A renamed vLLM flag otherwise costs a
GPU-hour: the engine exits 1, the platform restarts it forever, and the pod
reads RUNNING throughout. Run it after any change to the engine flags or the
image digest. First run pulls the image (~10 GB, once).

**Pick a provider first.** `GPU_PROVIDER` in `scripts/.env` decides which
hardware everything below talks to; nothing else in the setup changes.

| `GPU_PROVIDER` | What it is | `gpu-down.sh` does |
|---|---|---|
| `runpod` | Rented on-demand pods, billed hourly | **destroys** the pod — a stopped one still bills |
| `ssh` | A GPU box you own, or a VPS with a GPU + Docker | **stops the engine**; the machine is never touched |
| `manual` | You start the engine yourself | tells you to stop it; drains first |

The sections below are written for `runpod`, because that path has the most
moving parts — capacity, datacenters, network volumes, none of which exist when
the hardware is yours. On `ssh` you skip §4.1–§4.3 entirely: the machine already
exists, weights live on its own disk, and there is nothing billing while idle.

Full contract, and how to add a fourth provider, in
[scripts/providers/README.md](../scripts/providers/README.md).

### 4.1 RunPod account

- Sign up, add a payment method, load credit. RunPod is **prepaid** — a zero
  balance terminates pods and, after a grace period, **deletes network volumes**.
  Your 35 GB of weights lives on one.
- Set a **spend alert** in billing. This is the backstop for the cron cost guards
  themselves dying, which is the failure that actually produces a surprise bill.
- Console → **Deploy** → filter **Secure Cloud**, GPU **L40S**. Note which of
  `EU-SE-1`, `EU-NL-1`, `EU-RO-1` actually have capacity and put that one
  **first** in `RUNPOD_DATACENTERS`. The volume is created in the first entry and
  **a network volume is pinned to one datacenter**; getting this wrong costs a
  second 200 GB volume billing continuously or a 35 GB re-download.
- **Secure Cloud only.** The Community Cloud toggle is one click away and the
  trust model is inverted — the host has root on your box.

### 4.2 Credentials

```bash
cd scripts && cp .env.example .env && chmod 600 .env
```

Fill in:

| Variable | Where from |
|---|---|
| `RUNPOD_API_KEY` | RunPod → Settings → API Keys, pod create/terminate rights |
| `TS_AUTHKEY` | Tailscale → Settings → Keys, **reusable + ephemeral + pre-approved, tag `tag:gpu`** |
| `RUNPOD_DATACENTERS` | reordered per §4.1 |
| `RUNPOD_VOLUME_ID` | §4.3 prints it |

`scripts/.env` is deliberately separate from `gateway/.env`: the office server
runs the gateway without holding a credential that can create billable
instances. Keep it that way — see
[tailnet-admin.md](tailnet-admin.md#who-holds-which-credential).

### 4.3 Weights volume — first real spend

```bash
./scripts/gpu-up.sh --create-volume
```

Put the returned id in `scripts/.env` as `RUNPOD_VOLUME_ID`.

**This bills 24/7 from now on, pod or no pod** — 200 GB at RunPod's per-GB-month
rate, roughly $14/mo; confirm the current figure. Include it whenever you report
spend, so "we only pay when we use it" is not stated more strongly than it's
true.

#### The volume buys startup latency, not money

Worth being exact about, because the intuition runs the other way. The volume
exists so weights survive pod destruction — but re-downloading them is *cheap*:

| | Cost |
|---|---|
| Volume, idle | ~$0.47/day, forever, whether or not a pod exists |
| Re-downloading ~35 GB | a few minutes of GPU time — **cents per launch** |

So the volume does not pay for itself on launch frequency. What it buys is cold
start: **~1–2 min with the volume, ~5+ min without**, and a developer is waiting
through that.

That gives a clear rule:

- **Wiring, testing, anything bursty** — delete the volume between sessions and
  accept the re-download. Cheaper than the storage by a wide margin.
- **Measurement week, or once developers depend on cold starts** — keep it.
  $14/mo to halve the wait is obviously worth it then.

Deleting an **empty** volume costs nothing at all. Create it the day you need
fast cold starts; delete it when the phase ends.

⚠️ There is no volume-less mode. `gpu-up.sh` requires `RUNPOD_VOLUME_ID`
(`${RUNPOD_VOLUME_ID:?}`) and will abort if it is empty, so "delete between
phases" means running `--create-volume` again and pasting the **new** id into
`scripts/.env` before the next launch. Deleting the volume and forgetting that
step is a failed launch, not a slow one.

⚠️ Deleting a volume that holds weights is irreversible — the next launch
re-downloads. That is fine here, since the weights are pinned by revision and
byte-identical on refetch. It would not be fine for anything you generated.

### 4.4 Point the gateway at the node

`gateway/.env`:

```
ENGINE_API_BASE=http://gpu.<TAILNET>.ts.net:8000/v1
```

MagicDNS name, never `localhost`, never an IP. `gpu` is the hostname
`provision.sh` registers. Then:

```bash
cd gateway && docker compose up -d --force-recreate litellm
```

`docker compose restart` reuses the old environment and will not pick this up.

### 4.5 Dry run

```bash
./scripts/gpu-up.sh --dry-run
```

Read the JSON before spending. Confirm all five:

- `"cloudType": "SECURE"`
- `"ports": []`
- `"supportPublicIp": false`
- `"gpuTypeIds": ["NVIDIA L40S"]`
- your chosen datacenter first in `dataCenterIds`

Secrets should print as `<redacted N chars>`. If they print in the clear, stop —
that output ends up in terminal scrollback and CI logs.

### 4.6 First pod

```bash
./scripts/gpu-up.sh
```

In order: rotates `ENGINE_SECRET` and recreates the litellm container → creates
the pod with `provision.sh` base64'd into its env → node joins the tailnet as
`tag:gpu` **before** vLLM starts → checks Hugging Face provenance (org must be
`Qwen`, sha must equal the pin, no pickle files) → downloads ~35 GB to the volume
→ execs vLLM → polls `/v1/models` through the tailnet until 200.

**First launch is 20–40 min**, almost all download. Later launches skip it. The
built-in 30-minute timeout can fire on the very first run; that's the download,
not a fault — re-run.

While it waits, open the pod's logs in the RunPod console and read three things:

1. `no /dev/net/tun — userspace-networking mode` — expected on RunPod. vLLM binds
   `127.0.0.1` and tailscaled forwards inbound tailnet connections to it.
   Correct, not a downgrade.
2. **KV cache ≈ 20 KB/token.** If it says ~262 KB/token, vLLM took the generic
   attention path instead of the hybrid one and the entire 64k-context sizing is
   void — the hybrid attention path is the entire reason this model class was
   chosen. Stop and debug it rather than serving a config whose context sizing no
   longer holds; Gated DeltaNet is a young code path in vLLM.
3. Peak VRAM on load — decides whether vLLM's multimodal profiling reservation is
   eating KV cache, i.e. whether `--limit-mm-per-prompt` (written out and
   commented in `gpu/docker-compose.yml`) is worth setting.

### 4.7 Confirm the path is direct

```bash
tailscale status | grep -i gpu
```

Must read `direct`. `relay` means UDP 41641 and 3478 are blocked outbound on the
office network, and **every prompt and every generated token takes a DERP hop**.
This failure announces itself nowhere else.

### 4.8 Prove the model actually works

This is the only moment the two checks a stub cannot make are possible — about
$1.60 of GPU time:

- **Tool calling, via opencode.** Not aider: aider uses text diffs and will not
  surface a wrong `--tool-call-parser`, which returns prose where agents expect
  `tool_calls`.
- **The thinking split** between `coder` and `coder-max`.

Client setup is in [developer-guide.md](developer-guide.md).

### 4.9 Shut it down

```bash
./scripts/gpu-down.sh
```

Drains in-flight requests on `vllm:num_requests_running` (120 s hard timeout),
then **deletes** the pod. Not stops — a stopped pod keeps billing container disk
and holds the GPU reservation.

## 5. Cost guards and backups

Two ways to run them. Pick by whether the gateway host is always on.

### 5a. In the stack (recommended, and required if the host ever sleeps)

```bash
cd gateway && TZ=Europe/Berlin docker compose --profile scheduler up -d
```

Adds one container running `scripts/scheduler.sh`. No host cron, no launchd, no
separate service to remember. It is behind a **profile**, so a plain
`docker compose up -d` still starts the gateway alone — phase A keeps working
with no provider credentials present.

**Set `TZ`.** It defaults to UTC, and the nightly stop is a wall-clock time: left
unset it fires at the wrong local hour and looks like it works.

Why a loop rather than cron inside the container: cron does not fire while the
host sleeps and never catches up, so a window that passes during sleep is lost
silently — precisely the failure the nightly stop exists to bound. The loop
compares wall-clock against a state file, so a job whose window passed while the
machine was asleep runs once, late, on wake.

⚠️ **This does not keep anything running while the host is asleep.** A closed
laptop runs no guard of any kind. The provider-side spend alert is the only
backstop that survives that, which is why §4.1 asks for one.

Check it:

```bash
docker compose --profile scheduler logs -f scheduler
```

The state lives in a named volume, so restarting the container does not re-fire
jobs already done today.

### 5b. Host cron (always-on Linux only)

```bash
crontab -e
```

```
*/10 * * * * /path/to/ai-infra/scripts/idle-check.sh           >> /tmp/idle-check.log 2>&1
0 22  * * *  /path/to/ai-infra/scripts/idle-check.sh --nightly >> /tmp/idle-check.log 2>&1
30 3  * * *  /path/to/ai-infra/scripts/pg-backup.sh            >> /tmp/pg-backup.log 2>&1
30 4  * * 0  /path/to/ai-infra/scripts/pg-backup.sh --verify   >> /tmp/pg-backup.log 2>&1
```

Use absolute paths — cron's `PATH` is not your shell's.

The nightly stop matters **more** than the 45-minute idle threshold. The failure
that produces a surprise bill is not a threshold tuned slightly wrong; it is the
idle check silently not running — dead cron, an erroring query, a provider API
change. The nightly stop bounds the worst case to one day regardless of whether
anything above it works. Do not tune the threshold in place of it.

Check `/tmp/idle-check.log` the next morning. A cron that never ran leaves an
empty file, indistinguishable from a cron with nothing to do. Force the issue:

```bash
./scripts/idle-check.sh --dry-run
```

Then prove the backup is real, once, by hand:

```bash
./scripts/pg-backup.sh --verify
```

It issues a canary key, dumps, encrypts, decrypts **the artifact on disk**,
asserts the `PGDMP` header, restores into a scratch database and checks the
canary survived. Anything less is not a backup. Details and the restore procedure
are in [gateway-admin.md](gateway-admin.md#backups-and-restore).

## 6. Onboarding developers without a GPU running

Configuring opencode, Continue, aider and Claude Code for a team, handing out
keys and checking the `metadata.user` convention reads right in the spend log
takes hours. Every one of those hours against a live pod bills a GPU doing
nothing.

```bash
cd gateway && docker compose -f docker-compose.yml -f docker-compose.mock-engine.yml up -d
```

`gateway/mock_engine.py` stands in with **no change to `config.yaml`** —
`ENGINE_API_BASE` was already an environment variable, so clients get configured
against exactly what the office server will run. `verify.sh` detects it, prints a
banner, and grades only what a stub can honestly establish: that LiteLLM forwards
`extra_body` upstream (real signal — the stub echoes what arrived), that the
engine secret is enforced, and that streaming works.

Model behaviour stays **skipped** under the mock, deliberately. A stub returns
well-formed `tool_calls` by construction, so it cannot fail the way a wrong
`--tool-call-parser` does, and a check that can only pass is worse than no check.

Drop the `-f docker-compose.mock-engine.yml` to go back to the real engine.

## 7. Still blocked on a human

- **Verify the ACL from a genuinely separate identity.** Your own devices match
  the `autogroup:admin` grant and pass for the wrong reason. This trap has
  already cost time once. Procedure:
  [tailnet-admin.md](tailnet-admin.md#verifying-the-policy-honestly).
- **Evaluate alternative providers, if you have candidates.** The bar a provider
  has to clear before it is worth migrating to: hourly or per-minute billing, a
  scriptable provisioning API, and a **dedicated physical GPU** — passthrough,
  sole occupancy. A vGPU slice means a shared physical card and is disqualifying.
  Also ask for a persistent volume that survives instance destruction, priced
  separately, and whether operator access to the instance is logged. A provider
  offering only monthly terms isn't a variant of this design — delete the
  on-demand lifecycle scripts rather than adapting them.
- **Decide who may run `gpu-up.sh`.** It spends money. Either the whole team gets
  `scripts/.env` (any dev can start a pod) or only operators do (devs wait).
  The 503 message currently tells developers to run it, which implies the former
  — pick one and say so in the onboarding message.

## 8. When something breaks

Per-role troubleshooting lives in
[gateway-admin.md](gateway-admin.md#troubleshooting) and
[tailnet-admin.md](tailnet-admin.md#troubleshooting). The two failures that hide
rather than announce themselves:

- **A wrong tool-call parser** returns prose where agents expect `tool_calls`.
  aider will not surface it. Test with opencode.
- **Tailscale falling back to DERP relays** puts every prompt and token through a
  relay hop. `tailscale status` must read `direct`.

---

## 9. Alternative hardware: 2 × RTX 3090

The default path assumes one Ada-or-newer 48 GB card, because FP8 needs Ada. Two
3090s are the cheapest way to 48 GB, and they do work — but with a different
model file, three config changes, and one billing trap that can cost real money.

Sizes and revisions below were read from the Hugging Face API on 2026-08-10.

### 9.1 Do the cheap experiment first

**The purchase decision is a quantization question, not a hardware question, and
you can answer it on the L40S you already rent.** INT4 runs fine on Ada. Point
`MODEL_ID` at the INT4 checkpoint below, run `TASKS=1 ./scripts/bench.sh coder
coder-max` against `bench/tasks/`, and compare to your FP8 baseline. About a
dollar of GPU time.

If INT4 holds up on your real tasks, the 3090s are a reasonable buy. If it does
not, no hardware fixes it — you need FP8, which means Ada or newer. Do not buy
first.

### 9.2 Why the model has to change

A 3090 is Ampere: **no FP8 tensor cores**. vLLM can run FP8 weights on Ampere via
FP8 Marlin as weight-only W8A16, but that path historically did not cover
block-wise FP8 or MoE — and `Qwen3.6-35B-A3B-FP8` is both (fine-grained FP8,
block size 128, MoE). Assume the FP8 checkpoint will not load until you have
watched it load.

Ampere's native low-precision strength is INT4/INT8, so that is what to serve.
The checkpoint stays the same model:

```
MODEL_ID=Intel/Qwen3.6-35B-A3B-int4-mixed-AutoRound
MODEL_REVISION=65f69c73f17488236c85c85211f6ba28d7106157
```

21.5 GB, ungated, safetensors only, `Qwen3_5MoeForConditionalGeneration`,
`quant_method: auto-round`. Intel's AutoRound is the best-provenance community
quant available — a real org with a published quantization line — but it is
**not** an official Qwen checkpoint, which is a deliberate step down from the
principle in [architecture.md](architecture.md#primary-qwen36-35b-a3b-fp8).

The memory picture is better than the FP8 path, because INT4 halves the weights:

```
2 × 24 GB, TP=2, 0.90 utilisation  →  43.2 GB usable
  weights 21.5 GB  →  ~21.7 GB KV  →  ~1.08M tokens aggregate
                                       @ 65k ctx ≈ 16 concurrent streams
```

Against ~6 on the single L40S. Bandwidth is fine too — a 3090 is 936 GB/s
against the L40S's 864, and NVLink is reported to add ~48% to tensor-parallel
throughput over PCIe. **The cost is answer quality, not speed or capacity.**

Alternatives that also fit, if you want to compare: `cyankiwi/Qwen3.6-35B-A3B-AWQ-4bit`
(25.0 GB) and `Avesed/Qwen3.6-35B-A3B-INT4-W4A16` (25.6 GB).
`Qwen3-Coder-Next` does **not** fit — the smallest INT4 build is 43.5 GB against
43.2 GB usable, and raising `--gpu-memory-utilization` to buy the difference
leaves no KV cache and risks OOM on consumer cards.

### 9.3 Three config changes

**1. Tensor parallelism.** In `scripts/.env`:

```
GPU_COUNT=2
TP=2
```

**2. Shared memory.** Uncomment `ipc: host` in `gpu/docker-compose.yml` **in the
same change**. Without it, multi-GPU startup fails with a cryptic NCCL error
rather than a clear one. `verify.sh` asserts these two move together, so it will
catch you if you forget.

**3. The provenance gate.** `gpu/provision.sh` hard-codes the publishing org:

```bash
[ "$author" = "Qwen" ] || die "publishing org is '${author}' ..."
```

Any community quant is refused by design. Widen it to a **named allowlist** —
`Qwen` and `Intel`, not "anything" — so the check still does its job. This is a
security control, not boilerplate: it is what stops a typo'd or squatted repo id
from silently fetching someone else's weights.

The tool-call and reasoning parsers do **not** change. Same model family, so
`--tool-call-parser qwen3_coder` and `--reasoning-parser qwen3` stay as they are,
and the `coder` / `coder-max` thinking split keeps working.

### 9.4 vast.ai bills while the engine is stopped

vast.ai has no driver in `scripts/providers/`. It gives you SSH and Docker, so
`GPU_PROVIDER=ssh` works today with no new code:

```
GPU_PROVIDER=ssh
GPU_SSH_HOST=<vast instance>
GPU_SSH_USER=root
GPU_SSH_KEY=~/.ssh/id_ed25519
```

**Read this before leaving it running.** The `ssh` driver is `PROVIDER_KIND=persistent`,
which means `gpu-down.sh` and the idle check **stop the engine and never destroy
the machine**. That is correct for hardware you own. On vast.ai, which bills by
the hour, it means the instance keeps charging after every automatic shutdown —
the idle guard frees VRAM and power, and saves you nothing at all.

So on vast.ai, with the `ssh` driver, **destroying the instance is a manual step
in the vast.ai console.** Nothing in this repo will do it for you, and nothing
will warn you daily. Treat every test session as something you end by hand.

If 3090s become the real plan rather than a test, write
`scripts/providers/vastai.sh` as `ephemeral` — six functions, copy `manual.sh`,
see [providers/README.md](../scripts/providers/README.md). Then destroy-when-idle
works the way it does on RunPod and the trap goes away.

### 9.5 Verify

```bash
./verify.sh --disruptive
```

Must be 0 failed. Then the two checks a stub cannot make, per
[§4.8](#48-prove-the-model-actually-works): tool calling through opencode, and
the thinking split between `coder` and `coder-max`.

One extra check that only matters here — confirm vLLM actually loaded INT4 and
did not silently fall back:

```bash
docker logs ai-infra-vllm 2>&1 | grep -i "auto-round\|awq\|quantization"
```

### 9.6 What you are accepting

- **INT4 answer quality**, below FP8 by an amount you should measure rather than
  assume — hence §9.1.
- **A community quant**, against the provenance principle the FP8 checkpoint was
  chosen to satisfy.
- **~700 W** from the GPUs alone. Air cooling two 3090s for 24/7 inference is
  not practical; budget for water cooling on owned hardware.
- **Used, out-of-warranty Ampere** — the generation `gpu-up.sh` excludes by
  allowlist on the rented path.
