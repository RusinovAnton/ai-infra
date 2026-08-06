# Incident response

**Audience:** tailnet admins and gateway admins together. Most scenarios need
both, and the order between them matters.

Read [§0](#0-the-kill-switch) now, before you need it. Everything else is
scenario-specific.

---

## 0. The kill switch

When you don't know what's happening and you want it to stop:

```bash
./scripts/gpu-down.sh --force
```

```bash
cd gateway && docker compose stop litellm
```

The first destroys the rented node — the untrusted hardware, the thing billing
money, and the only component you don't physically control. In-flight requests
die; that's the trade. The second stops the gateway, which stops every developer
and every key at once.

Postgres keeps running so nothing is lost. The weights volume survives and keeps
billing. Both actions are fully reversible: `gpu-up.sh` and
`docker compose up -d litellm`.

Do this first if you're unsure. It costs a few minutes of everyone's productivity
and buys you an intact system to investigate.

---

## What evidence exists

Know this before an incident, because you cannot retrofit it during one.

**You have:**

- `LiteLLM_SpendLogs` — every request: which key, which alias, when, token counts,
  status. This is your timeline.
- `LiteLLM_VerificationToken` — every key, hashed, with alias, model scope,
  limits and `metadata.user`.
- Tailscale audit log (**Logs** page) — policy changes, key creation, device joins
  and removals, user changes. Retained per your plan tier.
- Tailscale network flow logs, **if enabled** on your plan. Check now whether they
  are; during an incident is too late to turn them on retroactively.
- `git log policy/` — the intended state of the perimeter, timestamped.
- RunPod console — pod create/destroy history and spend.

**You do not have, by design:**

- **Prompt or response content.** `turn_off_message_logging: true` on the gateway
  and `--no-enable-log-requests` on the engine. You cannot answer "what did they
  ask the model."
- **Shell history on the GPU node.** `--ssh=false`, and the node is destroyed.
- **Anything from a destroyed pod.** `gpu-down.sh` deletes it. If you need the
  logs, read them in the RunPod console **before** destroying — or accept losing
  them, which is usually the right call when containment is the goal.

The content gap is the deliberate trade: keeping prompts would mean a Postgres on
the office server holding every developer's source code — a bigger target than the
one it would help investigate. Don't reverse it mid-incident.

---

## 1. Compromised developer laptop or account

**Assume:** their virtual key and their Tailscale device credentials are in
someone else's hands.

Containment, in this order:

1. **Revoke the virtual key.** This is the fastest single action that stops model
   access:

```bash
curl -s -X POST http://localhost:4000/key/delete -H "Authorization: Bearer $LITELLM_MASTER_KEY" -H 'Content-Type: application/json' -d '{"key_aliases":["alice-laptop"]}'
```

2. **Remove the device from the tailnet.** Admin console → **Machines** → find it
   → **Remove**. That kills network reachability to the gateway.
3. **If the account itself is compromised** (not just the machine): **Users** →
   remove or suspend the user. This deauthorizes all their devices at once. A
   suspended account cannot re-join with a new device.
4. **Check whether they were an admin.** If the account is in
   `autogroup:admin`, it could reach `tag:gpu:8000` and `tag:gateway:22`
   directly — escalate to [§3](#3-compromised-admin-account) as well.

Assessment:

```sql
SELECT "startTime", model, total_tokens, status FROM "LiteLLM_SpendLogs"
WHERE metadata->>'user' = 'alice@example.com' AND "startTime" > now() - interval '7 days'
ORDER BY 1 DESC;
```

Look for: volume out of character, activity at hours they don't work, `coder-max`
from someone who never uses it, a burst of failures (probing). Cross-check the
Tailscale audit log for device joins you can't attribute.

Note the limit honestly: you can see that 400 requests happened at 03:00. You
cannot see what they were. If the concern is exfiltration of source code, the
model was one of several routes and the laptop itself was the bigger one.

Recovery: issue a **new** key with a new alias after the machine is rebuilt. Never
reinstate the old one.

## 2. Leaked virtual key (no compromised machine)

Key pasted in a public channel, committed to a repo, screenshotted.

```bash
curl -s -X POST http://localhost:4000/key/delete -H "Authorization: Bearer $LITELLM_MASTER_KEY" -H 'Content-Type: application/json' -d '{"keys":["sk-..."]}'
```

Then issue a replacement. Low severity by construction: a key is worthless without
tailnet access, and the tailnet requires an approved device belonging to an
invited identity. This is the layer working as designed — treat it as routine
hygiene, not an emergency.

Still revoke it. A key that survives its leak teaches the team the wrong lesson.

## 3. Compromised admin account

The serious one. An admin identity can rewrite the perimeter.

1. **Suspend the account.** Admin console → **Users**. If it's the account that
   owns the tailnet, use a second admin — this is the argument for having one
   before you need it.
2. **Diff the policy against Git.** The console is not the source of truth; Git
   is:

```bash
git log --oneline -- policy/
```

Open **Access Controls** in the console and compare against
`policy/tailnet-policy.hujson` on `main`. Look specifically for **a new grant with
`src: ["tag:gpu"]`** — that single addition would let the rented node initiate
connections into the tailnet, and it is the highest-value change an attacker
could make here. The `tests` block should have blocked it; verify the tests are
still present and unmodified.
3. **Restore the intended policy** by pushing `main` (the GitOps Action reapplies
   it), or paste the file into the console if the Action's credentials are also
   suspect.
4. **Rotate the OAuth client.** Admin console → Settings → OAuth clients → revoke,
   generate new, update repo secrets:

```bash
gh secret set TS_OAUTH_CLIENT_ID
```

```bash
gh secret set TS_OAUTH_CLIENT_SECRET
```

5. **Rotate every auth key.** Settings → Keys → revoke all. Mint a fresh
   `tag:gpu` key. Remember: **revoking a key does not disconnect already-joined
   nodes** — destroy the pod to remove the node it created.
6. **Review Machines** for devices you can't account for, and **Users** for
   invitations you didn't send.
7. If they held `RUNPOD_API_KEY`: [§5](#5-runaway-spend-or-unexpected-pods).
8. If they had shell on the gateway: [§4](#4-compromised-gateway-host).

## 4. Compromised gateway host

The worst case, because `LITELLM_MASTER_KEY` mints and revokes every key and
`BACKUP_PASSPHRASE` decrypts every dump.

```bash
./scripts/gpu-down.sh --force
```

```bash
cd gateway && docker compose stop litellm
```

Then, assuming the host is compromised and everything in `gateway/.env` is known
to the attacker:

1. **Every secret in `gateway/.env` is burned.** Generate new values for
   `LITELLM_MASTER_KEY`, `LITELLM_DB_PASS`, `UI_PASSWORD`, `BACKUP_PASSPHRASE`.
   `ENGINE_SECRET` rotates itself on the next `gpu-up`.
2. **Every virtual key is burned** — the attacker could read the master key and
   mint their own. Delete all of them and re-issue to the whole team. This is
   painful and there is no shortcut; it is the reason the master key's blast
   radius is documented in
   [tailnet-admin.md](tailnet-admin.md#who-holds-which-credential).
3. **Every retained backup is burned** — they had the passphrase. Re-encrypt or
   destroy them, then:

```bash
./scripts/pg-backup.sh --audit
```

4. **Check what the host could reach.** `tag:gateway` grants
   `tag:gpu:8000` — so the attacker could talk to the engine. It grants nothing
   else. That containment is the policy doing its job; confirm the policy wasn't
   also modified ([§3](#3-compromised-admin-account)).
5. **`RUNPOD_API_KEY` is not on this host** if the credential split was respected.
   Verify:

```bash
grep -l RUNPOD_API_KEY gateway/.env
```

No output is the correct answer. Output means the split was violated and the
incident now includes billable-instance control.

6. Rebuild the host. Restore Postgres from a backup taken **before** the
   compromise window, then re-issue keys —
   [gateway-admin.md](gateway-admin.md#restore-for-real).

## 5. Runaway spend or unexpected pods

Either a cost guard failed or someone else is using your RunPod account.

```bash
./scripts/gpu-down.sh --force
```

Then check the RunPod console for pods you didn't create. `gpu-down.sh` only knows
about the one named `ai-infra-gpu` — anything else must be killed by hand in the
console.

If the pods are yours and the guards simply didn't fire:

```bash
./scripts/idle-check.sh --dry-run
```

```bash
tail -50 /tmp/idle-check.log
```

An empty log means cron never ran, which is indistinguishable from cron having
nothing to do — and is the failure that actually produces surprise bills. Check
`crontab -l` and that the paths are absolute.

If the pods are not yours: rotate `RUNPOD_API_KEY` immediately in the RunPod
console, then update `scripts/.env`. Check the console's audit trail for API keys
you didn't create.

Either way, add a provider-side spend alert if one isn't set. It is the only
guard that survives cron dying.

## 6. Suspected compromise of the rented node or its host

You cannot verify this from outside, and the trust model says the host operator
can read prompts out of RAM and VRAM regardless. What you *can* do is bound it:

```bash
./scripts/gpu-down.sh --force
```

The node is destroyed, and being an ephemeral tailnet member it removes itself.
Then:

1. **Revoke `TS_AUTHKEY`** and mint a new one. The old key could re-join a machine
   as `tag:gpu`.
2. **`ENGINE_SECRET` rotates on the next `gpu-up`** — nothing to do.
3. **Confirm the blast radius held.** A `tag:gpu` node can reach nothing on the
   tailnet, enforced by the *absence* of a `src: ["tag:gpu"]` grant. Check that
   absence is still true:

```bash
grep -n 'tag:gpu' policy/tailnet-policy.hujson
```

Every hit should be a `dst`, a `tagOwners` entry, or a `tests` entry. A `src` hit
is the finding.

4. **What was exposed:** the prompts and completions that passed through it while
   it ran, plus the model weights (public). Not the gateway, not Postgres, not any
   virtual key — the engine never sees those.
5. **What you cannot know:** whether the host operator read anything. That is the
   accepted risk in [design-notes.md](design-notes.md#accepted-risks); the answer
   if it becomes unacceptable is confidential computing, not more firewall rules.

## 7. Suspicious usage pattern, no known compromise

Someone's traffic looks wrong but nothing is confirmed. Throttle rather than
revoke — it's reversible and doesn't accuse anyone:

```bash
curl -s -X POST http://localhost:4000/key/update -H "Authorization: Bearer $LITELLM_MASTER_KEY" -H 'Content-Type: application/json' -d '{"key":"sk-...","rpm_limit":5,"max_budget":1}'
```

Then talk to them. The most common cause is an editor plugin pointed at
`coder-max` for autocomplete, which looks exactly like abuse and is a
misconfiguration.

---

## Emergency changes and the GitOps trap

⚠️ **A change you paste into the Tailscale console during an incident will be
silently reverted by the next push to `main`.** That could be hours or weeks
later, by someone who has no idea an incident happened.

If the change should persist, commit it:

```bash
git switch -c incident/lock-down
```

Edit, commit, merge. If you can't — the GitHub credentials are part of the
incident — then either revoke the OAuth client so the Action cannot run, or write
the console change on the incident ticket with a deadline to codify it.

A perimeter change that exists in exactly one place, and that place is a browser
tab, is not a perimeter change.

---

## After the incident

- Write down what happened while you still remember the order of events.
- If a check should have caught it, add it: a `tests` entry in the policy, a
  section in `verify.sh`, a query in this document. The system's checks exist
  because of previous surprises.
- Re-run the full verification:

```bash
./verify.sh --disruptive
```

```bash
./scripts/pg-backup.sh --audit
```

- Verify the ACL from a genuinely separate identity, not your own device —
  [tailnet-admin.md](tailnet-admin.md#verifying-the-policy-honestly). Your own
  machines match `autogroup:admin` and will pass for the wrong reason.
