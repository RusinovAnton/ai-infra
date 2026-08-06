# Lessons from running this

Things that were only learnable by doing it, kept because they cost time or
money the first time. Distinct from [design-notes.md](design-notes.md), which
records decisions and the beliefs the build corrected; this file records what
*operating* the system taught us.

Every entry follows the same shape, because the shape is the value:

> **What it looked like** — the symptom you actually see, which is usually not
> the problem.
> **What was true** — the cause.
> **What changed** — the fix, and whether anything now catches it.

Add an entry whenever something takes more than ten minutes to diagnose, or
costs money. If the fix was a one-liner but the diagnosis was an hour, it
belongs here — the diagnosis is the expensive part.

---

## Renting GPUs

### A retired engine flag looks exactly like a slow cold start

**What it looked like.** Pod `RUNNING`, node online and correctly tagged on the
tailnet, `gpu-up.sh` politely printing dots for ten minutes. Console showed 0%
CPU and 0 memory. Every visible signal said "loading a large model".

**What was true.** vLLM had renamed `--disable-log-requests` to
`--no-enable-log-requests`. argparse treats an unknown flag as fatal, so the
engine exited 1 within a second. vLLM is PID 1, so the provider's restart policy
restarted the container, and the cycle repeated ~20 times in ten minutes. Nothing
in this repo retried; the loop belonged to the platform. Billing continued
throughout at $0.84/hr.

**What changed.** Flag renamed in both files that pass engine arguments;
`verify.sh` now **fails** on the retired spelling rather than accepting either,
because passing it does not degrade the engine, it prevents the engine from ever
starting.

**The general lesson.** A crash-looping container is externally
indistinguishable from a slow boot: same pod status, same tailnet presence, same
silence on the engine port. Pinning the image does not pin the flags the image
accepts. Read the pod's own logs before assuming patience is the answer.

### Destroying a failed pod destroys the only evidence

Twice the engine failed, and both times the diagnosis lived solely in the pod's
console log. Delete the pod — the obvious thing to do when it is billing and
broken — and the log goes with it. The second time, the root cause was gone
before it was read, leaving a choice between guessing at a fix and paying for
another attempt to reproduce it.

The provider offers no log API either: every REST path for pod logs 400s.

**What changed.** `gpu/provision.sh` no longer `exec`s vLLM. It keeps the exit
code, tees the output, and if the engine dies it serves the failure as a `503`
with `X-Engine-Failed` on `:8000` — the one port the gateway is allowed to reach.
`gpu-up.sh` polls for that and aborts in seconds with the root cause, instead of
waiting out a 30-minute timeout at roughly a dollar an hour.

It surfaces the **first** matching error rather than the last, because vLLM's
final line is the wrapper — `Engine core initialization failed. See root cause
above.` The line you need is above, which is exactly the part a tail loses.

**The general lesson.** On rented hardware the diagnosis has a shorter lifetime
than the fix. Anything that can only be read from a live machine must be pushed
somewhere durable *before* the machine is destroyed — and shutting down to stop
the bleeding is the moment you are most likely to lose it.

### The weights volume made the launch impossible, not faster

**What it looked like.** `create pod: get attached volume: network volume not
found`, then — once that was fixed — no capacity anywhere.

**What was true.** Two compounding facts. Only ~17 datacenters support network
volumes at all, and a volume pins the pod to exactly one of them forever. On the
day we checked, **not one storage-capable region had stock of any 48 GB Ada
card**, while RTX 6000 Ada and L40S both had stock globally. The volume was not
slowing placement down; it was removing every viable placement.

**What changed.** `RUNPOD_VOLUME_ID` is optional and empty by default. Weights
go to container disk, billed only while the pod exists and constraining nothing.

**The general lesson.** We adopted the volume for cold-start latency without
measuring it. The crash-loop logs handed us the number by accident: **35 GB
fetched in 34 s** cold, ~1 s warm. Half a minute, bought with a monthly bill and
a hard constraint on which hardware we could rent. The 200 GB size was likewise
never calculated — a round number. Real need is ~35 GB for the checkpoint.
*Measure the thing the optimisation is supposed to buy, before paying a
recurring cost for it.*

### Capacity is a snapshot, not a property

RTX 6000 Ada read `stock=Low` in US-IL-1 and `null` in the same region twenty
minutes later. Anything that reads availability from config — a datacenter list
written last week — is asserting something the provider does not guarantee.
`./scripts/gpu-up.sh --check-capacity` asks at the moment of use, and
`--create-storage` refuses to place storage where the GPU cannot currently run.

### "No capacity" is the normal case, and the error tells you nothing useful

**What it looked like.** `create pod: There are no instances currently
available` — repeated once per configured region, which reads like eight
different failures.

**What was true.** One failure, reported per region. The GPU we had configured
(RTX 6000 Ada) went from `stock=Low` to `NONE` globally within the hour. Nothing
was wrong with the request.

**What changed.** On a capacity error, `gpu-up.sh` now lists the cards that
*can* serve this model and have stock right now, with prices, so the next step is
visible instead of a guess. The filter is not just VRAM: Ampere cards (A40,
A6000, A100) have 48–80 GB but no FP8 tensor cores, so they would serve the
checkpoint far slower without erroring, and are excluded deliberately.

**The general lesson.** Capacity for any *specific* card is scarce and swings
within the hour, so a GPU pinned in config is a standing bet. Availability
across the *class* of suitable cards is much steadier — on the same day, one Ada
card was unavailable everywhere while L40S, RTX PRO 6000 Blackwell and H100 all
had stock. Design for "any card meeting these constraints", not for one model
number.

### Creating storage was not idempotent, and nothing complained

Running `--create-storage` twice produced two identical 200 GB volumes. No error,
no warning, indistinguishable names — the kind of thing you discover on an
invoice. Every other operation here is safe to repeat, which is exactly why this
one was not noticed. It now lists what exists and refuses.

### The provider's REST API is not the whole API

GPU types, datacenters, availability and pod logs are **absent** from the REST
API — every path 400s with "does not exist in the specification". They live on
the GraphQL endpoint, which needs its own scope on the API key. Do not conclude a
capability is missing because one API surface lacks it.

---

## Tailscale

### A certificate is permanent; the node name it contains is too

Enabling **HTTPS Certificates** publishes nothing by itself. The first
`tailscale serve` or `tailscale cert` on a node writes that node's exact FQDN
into a public Certificate Transparency log, permanently. Serve from a machine
still named after a person and that name is public forever; renaming afterwards
does not retract it. **Set the node name before anything requests a
certificate.**

Also: `--hostname` does not rename an already-registered machine. The console's
machine name wins, and that is what the certificate uses.

### Tagging a device removes its user identity

A tagged node stops matching `autogroup:member`, `autogroup:admin` and
`autogroup:self`. Tag the laptop you were testing from and it loses access to
everything granted to people — and the symptom is a connection timeout, which
reads as a firewall bug.

Corollary that cost the most time: **you cannot honestly test the dev-facing
policy from an admin account.** Your own login matches `autogroup:admin`, so
denials you assert in `tests` fail validation while the policy is correct. A
`tests` entry needs a concrete identity, so proving the developer path requires a
real non-admin account and cannot be done in the policy file at all.

### A stale node silently renames the new one, and the gateway keeps talking to the corpse

**What it looked like.** Pod up, disk 63% (weights clearly downloaded), and the
engine unreachable. `ENGINE_API_BASE` was correct. Nothing in the pod's status
suggested a naming problem.

**What was true.** The previous node was still listed — offline, last seen 49
minutes earlier — and still held the name `gpu`. MagicDNS does not reuse a name
in use, so the new node joined as **`gpu-1`**. The gateway went on resolving
`gpu`, which pointed at a machine that no longer existed. Every symptom read as
"the engine never started".

The node should have removed itself: the auth key is meant to be ephemeral,
which deletes a node when it disconnects. It did not, which is worth checking on
the key rather than assuming.

**What changed.** `gpu-up.sh` now waits for a `tag:gpu` node to appear, reads its
**actual** DNS name from the tailnet, and rewrites `ENGINE_API_BASE` plus
recreates the gateway if it differs. It also warns when more than one online
`tag:gpu` node exists. The logic is generic rather than provider-specific,
because the failure belongs to Tailscale's naming, not to whoever rents the box.

**The general lesson.** We treated a hostname as something we assign. It is
something we *request* — the name authority is elsewhere and may hand back
something else, silently. Anywhere a name is requested rather than assigned,
read back what you actually got.

### The console holds the running policy, the repo holds the intended one

Hours were spent debugging why a phone could not reach the gateway. The policy in
the repo granted it. The policy *applied in the console* was an older one that
only mentioned a different tag. Until the GitOps action runs, editing the file
changes nothing.

### `tailscale serve` terminates TLS, and the app behind it does not know

LiteLLM redirects `/ui` to `/ui/` using the scheme it sees — plain HTTP. `serve`
listens on 443 only, so the redirect lands on port 80 and 404s. The app is fine;
only the redirect is wrong. Use the trailing slash. Do **not** open port 80 or add
a proxy to "fix" it: serve being the sole ingress is what makes
`Tailscale-User-Login` trustworthy, so that trade is a security property for a
slash.

### Containers can reach the tailnet

Useful, and not obvious: a Docker container on the gateway host resolves MagicDNS
names and reaches tailnet addresses through the host. That is what lets the
scheduler container poll the engine's `/metrics` without any special networking.

---

## Shell and scripts

### `grep` in a pipeline under `set -euo pipefail` exits the script

`names="$(grep -E ... | cut -d= -f1 | tr '\n' ' ')"` — grep exits 1 when it
matches nothing, `pipefail` propagates that, and `set -e` kills the script.
Silently, with no output, exit code 1.

The trap is that **"no matches" was the success case**: the guard aborted every
caller precisely when the configuration was correct. `|| true` on the
substitution is load-bearing, not defensive noise.

### Bash brace-expands `{'a':1,'b':2}` inside a command substitution

An inline python dict written with no spaces is a valid brace list, so bash
expanded it into three words before python ever ran. The request body came out
empty and the provider replied about a missing content type — an error pointing
nowhere near the cause.

The same pattern is *safe* a few lines away in a larger request, because that one
contains newlines, which suppress expansion. A construct that works in one place
and silently corrupts data in another is not something anyone spots by reading.
Build JSON with `printf` or a heredoc, never an inline single-line dict literal.

### A placeholder is not an empty value

`${VAR:?}` only fires on unset or empty, so an untouched `CHANGE-ME` passes every
guard and fails much later as a provider error about an id that never existed.
Guard explicitly against the placeholder text.

But guard it **only on paths that create things**. The first version ran the
check on startup, which blocked `--create-storage` — whose entire purpose is to
produce the missing value — and would have blocked `gpu-down.sh`, turning a
cosmetic config problem into an unbounded bill. *Never let a validation failure
prevent shutting something down.*

---

## Cost

### Nothing guards a host that is asleep

cron does not fire while a machine sleeps and never catches up, so a closed lid
silently skips both the idle check and the nightly stop — the two things that
bound a forgotten pod to one day. The scheduler container recovers missed windows
on wake, which cron cannot, but it still does not run while the host is asleep.
On a laptop, the provider-side spend alert is the only guard that actually holds.

### The things that cost money here are the quiet ones

Every unplanned cost so far was silent rather than loud: a crash-looping pod that
reported `RUNNING`, duplicate volumes with identical names, a volume billing for
weights nothing could use. None produced an error. Treat "no error" as weaker
evidence than it feels.
