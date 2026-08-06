# Gateway administration — LiteLLM operations

**Audience:** whoever hands out access, watches spend, and manages which models
exist. Assumes shell access to the office server and `gateway/.env`.

**What you control:** everything above the network layer. Who can reach the
machine at all is [tailnet-admin.md](tailnet-admin.md).

---

## Getting in

Two ways, both over the tailnet only.

### Shell (the real interface)

```bash
ssh gateway.<TAILNET>.ts.net
```

```bash
cd ~/projects/my/ai-infra/gateway && docker compose ps
```

Both containers must read `healthy`. `ai-infra-litellm` unhealthy with
`ai-infra-db` healthy usually means a bad `config.yaml` — see
[logs](#logs-and-health).

Every command in this document is run from `gateway/` unless it starts with
`./scripts/`, which is run from the repo root.

### Web UI

`https://gateway.<TAILNET>.ts.net/ui/` — credentials are `UI_USERNAME` /
`UI_PASSWORD` from `gateway/.env`.

⚠️ **The trailing slash is required.** Without it LiteLLM answers `307` to
`http://gateway.<TAILNET>.ts.net/ui/` — plain HTTP, because it builds the
redirect from the request and cannot know `tailscale serve` terminated TLS in
front of it. `serve` listens on 443 only, so that redirect lands on port 80 and
returns `404`. The app is fine; only the redirect is wrong. Nothing to fix on the
gateway — do not bind another port or add a proxy to work around it, since serve
being the sole ingress is what makes `Tailscale-User-Login` trustworthy.

Convenient for browsing keys and spend. **Not** the source of truth: it can create
keys that exist nowhere in your notes, and the API and psql below are what
scripts and audits use. Treat it as read-mostly.

### The database directly

This is the ground truth for keys and spend, and it answers questions the API
version-churns on:

```bash
docker compose exec -it litellm-db psql -U litellm -d litellm
```

No password prompt — you're inside the compose network, and the DB publishes no
ports. Useful starting points:

```sql
\dt
```

```sql
SELECT token, key_alias, models, spend, rpm_limit, metadata FROM "LiteLLM_VerificationToken" ORDER BY created_at DESC;
```

`token` is a SHA-256 hash. The plaintext key exists exactly once, at creation,
and is never recoverable — lose it and you re-issue.

For a GUI, forward the port over the tailnet rather than publishing it:

```bash
ssh -L 15432:127.0.0.1:15432 gateway.<TAILNET>.ts.net
```

…with `docker compose exec` replaced by a temporary `ports: ["127.0.0.1:15432:5432"]`
override. Remove the override afterwards; a published database port is how the
one thing holding every key hash becomes reachable from the office LAN.

---

## Keys and access

### Decide the `metadata.user` convention first

Revocation, rate limits, spend attribution and audits all act on it. Retrofitting
means re-issuing to everyone. Use email addresses, and never issue a key without
it.

### Issue a key

```bash
curl -s -X POST http://localhost:4000/key/generate -H "Authorization: Bearer $LITELLM_MASTER_KEY" -H 'Content-Type: application/json' -d '{"models":["coder"],"rpm_limit":60,"key_alias":"alice-laptop","metadata":{"user":"alice@example.com"}}'
```

The response contains `key` — the only time you will ever see it. Send it over
your password manager's sharing feature, not chat.

`coder-max` is deliberately absent from `models`. Scope the expensive tier with
key permissions, not with convention. To grant it:

```bash
curl -s -X POST http://localhost:4000/key/generate -H "Authorization: Bearer $LITELLM_MASTER_KEY" -H 'Content-Type: application/json' -d '{"models":["coder","coder-max"],"rpm_limit":60,"key_alias":"alice-laptop","metadata":{"user":"alice@example.com"}}'
```

Useful extra fields:

| Field | Effect |
|---|---|
| `max_budget` | hard spend cap; requests fail once hit |
| `budget_duration` | `"30d"` — resets the cap on a cycle |
| `duration` | `"90d"` — the key itself expires |
| `tpm_limit` | tokens/min, the cap that actually tracks GPU cost |
| `key_alias` | human-readable label; makes the UI and psql legible |

One key per person per machine. Shared keys make revocation an all-or-nothing
event and destroy attribution — which is the only forensic signal this system
keeps, since prompt content is deliberately not logged.

### Inspect a key

```bash
curl -s -X GET "http://localhost:4000/key/info?key=sk-..." -H "Authorization: Bearer $LITELLM_MASTER_KEY"
```

### Change a key without re-issuing

```bash
curl -s -X POST http://localhost:4000/key/update -H "Authorization: Bearer $LITELLM_MASTER_KEY" -H 'Content-Type: application/json' -d '{"key":"sk-...","rpm_limit":10,"models":["coder"]}'
```

Downgrading someone out of `coder-max`, or throttling a runaway client, without
touching their editor config.

### Revoke a key

```bash
curl -s -X POST http://localhost:4000/key/delete -H "Authorization: Bearer $LITELLM_MASTER_KEY" -H 'Content-Type: application/json' -d '{"keys":["sk-..."]}'
```

Takes effect immediately. Combine with the tailnet-side removal in
[tailnet-admin.md](tailnet-admin.md#remove-a-developer) — a revoked key on a
machine that is still on the tailnet is half a removal.

Lost the plaintext and need to revoke it? Find its hash in psql by
`key_alias` or `metadata`, then delete by `key_alias`:

```bash
curl -s -X POST http://localhost:4000/key/delete -H "Authorization: Bearer $LITELLM_MASTER_KEY" -H 'Content-Type: application/json' -d '{"key_aliases":["alice-laptop"]}'
```

This is the practical argument for always setting `key_alias`.

---

## Stats worth looking at

### Spend by person

```bash
curl -s -X GET "http://localhost:4000/global/spend/report?start_date=2026-08-01&end_date=2026-08-31" -H "Authorization: Bearer $LITELLM_MASTER_KEY"
```

The stable version, which does not depend on LiteLLM's endpoint churn:

```sql
SELECT metadata->>'user' AS dev, count(*) AS calls, sum(total_tokens) AS tokens, round(sum(spend)::numeric, 4) AS spend
FROM "LiteLLM_SpendLogs" WHERE "startTime" > now() - interval '7 days'
GROUP BY 1 ORDER BY tokens DESC;
```

`spend` is computed from LiteLLM's price table and is **meaningless here** — the
model is self-hosted and per-token cost is zero. Real cost is GPU-hours. Use
`tokens` and `calls` for attribution, and the RunPod console for money.

### Are we actually paying for something idle

```sql
SELECT max("startTime") AS last_request, now() - max("startTime") AS idle_for FROM "LiteLLM_SpendLogs";
```

This is the exact query `idle-check.sh` runs. If it errors, the idle guard is
dead and only the nightly stop is protecting you.

### Tier split — is `coder-max` being used as a default

```sql
SELECT model, count(*), round(avg(total_tokens)) AS avg_tokens
FROM "LiteLLM_SpendLogs" WHERE "startTime" > now() - interval '7 days'
GROUP BY 1;
```

A team where `coder-max` outnumbers `coder` is a team that set the thinking tier
as its editor default. That's a conversation, not a config change.

### Errors

```sql
SELECT model, count(*) FROM "LiteLLM_SpendLogs"
WHERE "startTime" > now() - interval '1 day' AND status != 'success' GROUP BY 1;
```

### What you deliberately cannot see

`turn_off_message_logging: true` means **no prompt or response content is
stored**, anywhere, on either machine (the engine also runs
`--no-enable-log-requests`). You can see who called what, when, and how many
tokens. You cannot see what they asked.

That is the intended trade and it has a cost: during an incident you cannot
answer "what did the attacker ask the model." Know that before you need the
answer. Reversing it means storing every developer's source code in a Postgres on
the office server — a much larger target than the one you removed.

---

## Logs and health

```bash
docker compose logs -f --tail=100 litellm
```

```bash
curl -s http://localhost:4000/health/liveliness
```

Answers from the gateway alone, says nothing about the engine. That's what a
liveness check should do.

```bash
curl -s http://localhost:4000/health -H "Authorization: Bearer $LITELLM_MASTER_KEY"
```

Includes the engine. `background_health_checks` with a 60 s interval means this is
cheap to poll; `health_check_details: false` keeps engine URLs and raw upstream
errors out of the response for key holders.

### The 503 a developer sees when the GPU is down

`error_hook.py` converts an unreachable engine into a `503` naming the cause and
the fix, instead of a bare `500` that reads like a gateway bug. Two things to know
about it:

- ⚠️ A **wrong port** in `ENGINE_API_BASE` produces the same message — "the
  gateway is healthy, the GPU is not, run `gpu-up.sh`" — while the node is
  actually up. If that 503 appears while `tailscale status` shows the node
  online, suspect the URL before the pod.
- The response's top-level `error.type` is the literal string `"None"`;
  `engine_unavailable` is nested in `provider_specific_fields`. A client checking
  `error.type` gets nothing useful. Tell developers to match on the status code.

---

## Managing models

### What exists and why

Two aliases, one engine, same weights — so switching tiers costs nothing and
needs no reload. The only difference is the thinking toggle and the output cap.

| Alias | `enable_thinking` | `max_tokens` | For |
|---|---|---|---|
| `coder` | false | 8192 | default agentic coding |
| `coder-max` | true | 32768 | architecture, hard debugging, tricky refactors |

`coder-max`'s cap is generous on purpose: a cap that cuts mid-reasoning returns
`finish_reason: length` with **empty content** — a request that burned GPU time
and produced nothing, presenting to the user as a broken model.

`coder-max` falls back to `coder` on failure. `coder` has no fallback — it is the
floor, and with one engine there is nowhere else to go. If the node is down both
aliases are down; `error_hook.py` handles that, not a fallback. Adding a hosted
API as a fallback would send prompts to a third-party model provider, which is the
thing this architecture exists to avoid.

### Change a model's settings

Edit `gateway/config.yaml`, then:

```bash
docker compose up -d --force-recreate litellm
```

Use `--force-recreate`, not `restart`. `config.yaml` is a read-only bind mount so a
plain restart *does* re-read it — but `restart` reuses the old **environment**, so
if you changed anything in `.env` in the same sitting it silently won't apply.
One command that always works beats two that mostly do.

Then confirm from outside:

```bash
curl -s https://gateway.<TAILNET>.ts.net/v1/models -H "Authorization: Bearer sk-..."
```

### Add an alias

Copy a `model_list` block, change `model_name` and the `extra_body` /
`max_tokens`. Both existing entries point at the same `openai/coder` deployment —
that name is vLLM's `--served-model-name`, not a model identifier, so a new alias
on the same engine costs nothing.

A new alias is invisible to existing keys until you add it to their `models`
list — `/key/update`, above. That's a feature: roll out a tier to one person
first.

### Change the actual model

That's a GPU-node change: `MODEL_ID` and `MODEL_REVISION` in `scripts/.env`, then
destroy and recreate the pod. Expect a fresh ~35 GB download on first launch, and
re-verify the tool-call parser — `--tool-call-parser` is model-family-specific and
a wrong one returns prose where agents expect `tool_calls`, silently. Details in
[devops-setup.md](devops-setup.md#4-gpu-node).

---

## Secret rotation

### `ENGINE_SECRET`

Automatic. `gpu-up.sh` rotates it on every launch, rewrites `gateway/.env` and
recreates the litellm container. Nothing to do.

### `LITELLM_MASTER_KEY`

Edit `gateway/.env`, then:

```bash
docker compose up -d --force-recreate litellm
```

Existing virtual keys keep working — they're stored hashed in Postgres and are not
derived from the master key. Only your own admin tooling needs updating.

### `LITELLM_DB_PASS`

Two places: the Postgres role and `gateway/.env`. Change the role first, in psql,
then the file, then recreate both services. Doing it in the other order leaves
LiteLLM unable to connect and looking like a boot crash.

### `BACKUP_PASSPHRASE`

⚠️ **Rotating this makes every existing artifact unrecoverable.** They were
encrypted with the old one. Either re-encrypt the retained dumps or accept losing
your restore window — then confirm which world you're in:

```bash
./scripts/pg-backup.sh --audit
```

---

## Backups and restore

Losing this database means losing every virtual key and all spend attribution,
and re-issuing keys to every developer.

### The daily and weekly jobs

Installed in [devops-setup.md](devops-setup.md#5-cost-guards-and-backups).
`pg-backup.sh` dumps in custom format, encrypts with AES-256-CTR + PBKDF2, keeps
14 days.

### Verify — weekly, automatic

```bash
./scripts/pg-backup.sh --verify
```

Issues a canary key **before** the dump, so it lands inside the artifact; dumps;
encrypts; decrypts **the artifact on disk**; asserts the plaintext begins with
`PGDMP`; restores into a scratch database; checks the canary's hash survived.

The `PGDMP` assertion is not decoration. AES-256-CTR has no MAC and no padding, so
**a wrong passphrase decrypts to garbage and openssl still exits 0** — verified.
Without the header check, a wrong `BACKUP_PASSPHRASE` is discovered at recovery
time, which is the worst possible moment.

### Audit — monthly, by hand

```bash
./scripts/pg-backup.sh --audit
```

`--verify` only ever checks the artifact it just wrote with the passphrase it just
used — self-consistent by construction, so it cannot notice that **older**
artifacts stopped decrypting. Rotate the passphrase and 14 days of retention
silently become rubbish with no warning. This mode is the only thing that catches
it. It found 1 unrecoverable artifact of 12 on its first run.

### Restore for real

```bash
openssl enc -d -aes-256-ctr -pbkdf2 -iter 600000 -pass env:BACKUP_PASSPHRASE -in backups/litellm-<stamp>.dump.enc -out /tmp/restore.dump
```

```bash
head -c 5 /tmp/restore.dump
```

Must print `PGDMP`. If it doesn't, stop — that file is not recoverable and you
need a different one.

```bash
docker compose exec -T litellm-db pg_restore -U litellm -d litellm --clean --if-exists < /tmp/restore.dump
```

```bash
rm -f /tmp/restore.dump
```

⚠️ The backups live on the machine they protect. **A backup that only exists on
the machine it protects is not one.** An offsite copy is still an open item;
until it exists, a dead office server means re-issuing every key.

---

## Gotchas

- ⚠️ **`gateway/.env` overrides your shell environment** in the `scripts/`
  helpers, the opposite of how Docker Compose behaves.
  `BACKUP_PASSPHRASE=x ./scripts/pg-backup.sh` is silently ignored because
  `load_env` re-sources the file afterwards. Edit the file.
- `docker compose restart` reuses the old environment. Always
  `up -d --force-recreate`.
- `turn_off_message_logging` and `disable_spend_logs` sound similar and do
  opposite things. The first redacts content and is on; the second would delete
  the rows `idle-check.sh` needs and must stay off.
- The UI can create keys that exist in no runbook. Prefer the API.

## Troubleshooting

**litellm unhealthy, db healthy.** Bad `config.yaml` or a missing `.env`
variable. `docker compose logs litellm` — LiteLLM names the key it couldn't
resolve.

**Every request returns 503.** The engine. `tailscale status | grep gpu`, then
`./scripts/gpu-up.sh`. If the node is online, check `ENGINE_API_BASE`'s port
before anything else.

**A developer gets 401 but the tailnet works.** Their key is wrong or revoked.
`/key/info`.

**A developer gets 400 `model not found`.** Their key doesn't include that alias.
`/key/update`.

**Requests hang for ten minutes then fail.** `timeout: 600` in `router_settings`
is intentional — a thinking alias on a long task is slow, not hung. If it's the
`coder` alias, look at the engine.

**Empty responses with `finish_reason: length`.** `max_tokens` cut it
mid-reasoning. That's the `coder-max` failure the generous cap exists to prevent;
if it's happening, the client is overriding `max_tokens` downward.
