# Tailnet & node administration

**Audience:** whoever owns the network perimeter — Tailscale ACLs, tags, keys,
device inventory, and the lifecycle of the rented GPU node.

**What you control:** who can reach what, at the network layer. Everything below
the gateway's API is [gateway-admin.md](gateway-admin.md). Compromise handling is
[incident-response.md](incident-response.md).

---

## The model in one paragraph

`policy/tailnet-policy.hujson` is the whole perimeter. Three grants matter: devs
reach `tag:gateway:443` and nothing else; `tag:gateway` reaches `tag:gpu:8000`
and nothing else; admins reach both. The rented GPU node can reach **nothing** —
not because a rule forbids it, but because `grants` is default-deny and **no rule
with `src: ["tag:gpu"]` exists**. That absence is the single most load-bearing
line of configuration in this repo, and it is invisible. It is asserted in the
policy's own `tests` block and grepped for by `verify.sh` precisely because
absence is easy to erase by accident.

There is deliberately **no `acls` block**. A default allow-all `grants` entry
silently overrides `acls` restrictions with no warning, and new tailnets ship
exactly that. Mixing the two is how a policy reads restrictive and behaves open.

---

## Policy as code

The console is not the source of truth. `policy/tailnet-policy.hujson` is, applied
by `.github/workflows/tailscale-policy.yml` — tests on PR, applies on push to
`main`.

**One-time setup:**

1. Admin console → **Settings** → **OAuth clients** → Generate. Scope:
   `policy_file` **write**. No tag is needed for that scope.
2. Add the credentials as repo secrets:

```bash
gh secret set TS_OAUTH_CLIENT_ID
```

```bash
gh secret set TS_OAUTH_CLIENT_SECRET
```

Once this is live, **console edits get silently reverted by the next push to
`main`.** That is the point. It also means an emergency console change is
temporary — see
[incident-response.md](incident-response.md#emergency-changes-and-the-gitops-trap).

Until the branch reaches `main` the Action never runs, and the console holds
whatever you last pasted.

### Changing the policy

```bash
git switch -c policy/add-devs
```

Edit, open a PR, read the Action's test output, merge. The `tests` block is the
review: a change that breaks an assertion fails the PR rather than the tailnet.

Add a test whenever you add a grant. A grant with no corresponding test is a rule
nobody will notice the removal of.

---

## Routine tasks

### Add a developer

1. Admin console → **Users** → **Invite external users**. They accept and appear
   with an exact login string — copy it verbatim. A login Tailscale doesn't
   recognise **fails policy validation**, and the failure mode differs by how the
   tailnet was created: Google SSO gives `alice@example.com`, GitHub gives
   `alice@github`.
2. Add that string to `group:devs` in the policy. PR, merge.
3. They install Tailscale and log in. If **device approval** is on, approve their
   machine under **Machines** — until then it looks joined and reaches nothing.
4. Issue them a gateway key:
   [gateway-admin.md](gateway-admin.md#issue-a-key).
5. Send them [developer-guide.md](developer-guide.md).

### Remove a developer

Do all four, in this order — the first two are the ones that actually stop access:

1. Revoke their **virtual key** on the gateway
   ([gateway-admin.md](gateway-admin.md#revoke-a-key)).
2. Admin console → **Users** → remove the user. This deauthorizes their devices.
3. Remove them from `group:devs` in the policy. PR, merge.
4. Check their key's spend log for anything unexpected in the final days.

Removing them from `group:devs` alone leaves a working key on a machine that is
still on the tailnet until step 2 lands.

### Add an admin machine

Admins match `autogroup:admin`, which grants `tcp:22,443` on `tag:gateway` and
`tcp:22,8000` on `tag:gpu`. Nothing to configure per machine — but note this is
exactly why you cannot test the dev-facing policy from your own laptop.

### Rotate the GPU auth key

`TS_AUTHKEY` maxes out at 90 days. Calendar it.

Admin console → **Settings** → **Keys** → Generate auth key:

| Option | Value | Why |
|---|---|---|
| Reusable | ✅ | `gpu-up.sh` runs many times |
| Ephemeral | ✅ | the node deletes itself from the tailnet when destroyed |
| Pre-approved | ✅ | only shown if device approval is on; without it every pod hangs waiting for you |
| Tags | `tag:gpu` | the tag the ACL binds to |
| Expiry | ≤ 90 days | hard ceiling |

Paste into `scripts/.env`. **Revoking a key does not disconnect already-joined
nodes** — to remove a live one, destroy the pod.

### Tailnet-wide settings that must stay on

| Setting | Page | Breaks if off |
|---|---|---|
| MagicDNS | DNS | `gpu.<TAILNET>.ts.net` stops resolving; the gateway loses the engine |
| HTTPS Certificates | DNS | `tailscale serve` cannot issue a cert; devs get a TLS error |
| Key expiry **disabled** on `tag:gateway` | automatic when tagged | the gateway silently drops off the tailnet on expiry day |

Enabling HTTPS certs publishes node **names** to the public Certificate
Transparency log. Names, not content. Rename nodes first if that matters.

---

## Verifying the policy honestly

**Your own devices match `autogroup:admin` and will pass for the wrong reason.**
This is the trap. Use an invited teammate's machine, or a second personal account
added as a plain member.

From that machine, expect **success**:

```bash
curl -s https://gateway.<TAILNET>.ts.net/health/liveliness
```

Expect **failure** — timeout or no route:

```bash
curl -sv --max-time 5 http://gpu.<TAILNET>.ts.net:8000/v1/models
```

A `401` here is a **failure of the test**: it means the ACL let you through and
only the engine's API key stopped you. The network layer is supposed to refuse
the connection before any HTTP happens.

Re-run this after every policy change that touches `group:devs` or the grants.

---

## The GPU node

### What it is

A single RunPod container, created fresh by `scripts/gpu-up.sh` and destroyed by
`scripts/gpu-down.sh`. It runs `gpu/provision.sh`, which joins the tailnet as
`tag:gpu` **before** starting vLLM, so there is no window in which the engine
listens unprotected.

Deliberate properties, all of which you should preserve:

- **`--ssh=false`.** No Tailscale SSH grant on untrusted hardware. Administration
  is the RunPod console (logs) plus destroy-and-recreate. If you need a shell,
  you're debugging provisioning — use the console's own terminal, and remember
  the host operator sees everything you type there anyway.
- **No `--advertise-routes`, no `--advertise-exit-node`.** Either would turn a
  rented box into a path into or out of the tailnet.
- **Not `--shields-up`.** Shields block *incoming* tailnet connections, and the
  gateway reaching `:8000` is an incoming connection. Egress confinement comes
  from the policy's default-deny, not from shields.
- **`ports: []`, `supportPublicIp: false`.** The engine socket does not exist on
  any public interface.
- **Ephemeral tailnet node.** It removes itself on destroy, so **Machines** does
  not fill with dead `gpu` entries. If it does, the key isn't ephemeral.

### Lifecycle

```bash
./scripts/gpu-up.sh
```

```bash
./scripts/gpu-down.sh
```

```bash
./scripts/gpu-down.sh --force
```

`--force` skips the drain and drops in-flight requests. Use it when cost or
containment beats a developer's interrupted agent turn.

`gpu-up.sh` is idempotent: an existing pod with a live engine is a no-op, and an
existing pod with a dead engine is waited on rather than duplicated.

### Health

```bash
tailscale status | grep -i gpu
```

`direct`, never `relay`. A relayed path routes every prompt and every generated
token through a DERP hop and reports itself nowhere else.

```bash
curl -fsS -H "Authorization: Bearer $ENGINE_SECRET" http://gpu.<TAILNET>.ts.net:8000/v1/models
```

Run that from the gateway machine or an admin machine. From a dev machine it must
fail at the network layer — that's the ACL working.

### Node inventory review — monthly, 10 minutes

- **Machines** page: anything you can't name? Anything tagged that shouldn't be?
  Any `gpu` node still listed with no pod running?
- **Keys** page: expiry dates. Anything reusable-and-non-ephemeral is a finding.
- **Logs** page (audit log): policy changes, key creation, device joins. Compare
  policy changes against `git log policy/`. A change in the audit log with no
  matching commit means someone edited the console.
- **Users** page: anyone who left the company.

---

## Who holds which credential

The split is deliberate. Widening it re-couples blast radii that were separated on
purpose.

| Credential | Lives in | Holder | If leaked |
|---|---|---|---|
| `LITELLM_MASTER_KEY` | `gateway/.env` | gateway admins | **worst case** — mints and revokes every key, reads all spend. Full rotation. |
| `LITELLM_DB_PASS` | `gateway/.env` | gateway admins | DB is not published; needs host access first |
| `BACKUP_PASSPHRASE` | `gateway/.env` + password manager | gateway admins | decrypts every dump = every key hash + all spend history |
| `ENGINE_SECRET` | `gateway/.env`, rotated per launch | automatic | low value by design — the ACL is the real control |
| `RUNPOD_API_KEY` | `scripts/.env` | operators only | can create billable instances and destroy the weights volume |
| `TS_AUTHKEY` | `scripts/.env` | operators only | joins arbitrary machines as `tag:gpu` — which can reach nothing, so contained |
| OAuth client secret | GitHub repo secrets | tailnet admins | **rewrites the perimeter.** Rotate on any suspicion. |
| Virtual keys (`sk-…`) | developer machines | one per person | one developer's access; revoke individually |

The office server never holds `RUNPOD_API_KEY`. That's what keeps a gateway
compromise from becoming an unbounded bill.

---

## Troubleshooting

**A node joined but nothing can reach it.** It registered untagged. Tags apply at
registration, and an untagged device has the `Tags` field *absent* — so
`tag:gpu` rules match nothing. Re-run `tailscale up --advertise-tags=…`, or for
the GPU node, destroy and recreate the pod.

**Policy apply fails validation.** Almost always a login string in `groups` or
`tests` that isn't a real tailnet user. Copy it from the **Users** page.

**A dev gets a TLS error on the gateway URL.** HTTPS Certificates is off, or
`tailscale serve` isn't running on the gateway. `tailscale serve status`.

**A dev gets a connection timeout.** Either they're not on the tailnet, their
device is unapproved, or they're not in `group:devs`. In that order.

**A dev gets `401` from the gateway.** Network is fine, their virtual key is
wrong or revoked → [gateway-admin.md](gateway-admin.md).

**`tailscale status` says `relay`.** UDP 41641 and 3478 are blocked outbound on
the office network. Fix the firewall; do not accept it as normal.

**A console change vanished.** The GitOps Action reapplied `main`. Expected.
Change the file.
