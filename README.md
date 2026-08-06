# ai-infra — rented GPU inference behind an on-prem LiteLLM gateway

Deployment configuration for a self-hosted coding-model stack.
Open-weight coding model on a rented GPU, reachable only through a LiteLLM gateway
on office hardware, reachable only over Tailscale.

Developers get an OpenAI-compatible endpoint at
`https://gateway.<TAILNET>.ts.net/v1` serving `coder` and `coder-max`. Nothing is
exposed to the internet; no prompt leaves the tailnet for a third-party model
provider.

## Status

**Phase A complete — $0 spent.** Gateway stack runs, both aliases served, keys
issued and revoked against a fresh Postgres, engine-down path returning a clear
503. `./verify.sh --disruptive` → **0 failed** (skips are GPU- and
tailnet-dependent).

Phase B (first 1 × L40S pod) and Phase C (measurement week) are blocked on human
tasks, not on code — see [docs/devops-setup.md](docs/devops-setup.md).

## Documentation, by role

| You are | Read |
|---|---|
| **Standing it up** for the first time | [docs/devops-setup.md](docs/devops-setup.md) — zero to working, in order, including what to check before spending |
| **Running the network** — ACLs, tags, keys, the GPU node's lifecycle | [docs/tailnet-admin.md](docs/tailnet-admin.md) |
| **Running the gateway** — access, keys, spend, models, backups | [docs/gateway-admin.md](docs/gateway-admin.md) |
| **Writing code against it** | [docs/developer-guide.md](docs/developer-guide.md) — agent-agnostic, plus opencode / aider / Claude Code / VS Code / JetBrains |
| **Handling a compromise or a runaway bill** | [docs/incident-response.md](docs/incident-response.md) — kill switch first |
| **About to change something structural** | [docs/design-notes.md](docs/design-notes.md) — deliberate omissions, corrected assumptions, accepted risks |

Beliefs that turned out to be wrong during the build are recorded in
[design-notes.md](docs/design-notes.md#corrections-to-the-original-design)
rather than quietly fixed.

## Layout

```
policy/tailnet-policy.hujson      tailnet ACL — source of truth, applied by GitHub Action
.github/workflows/                test on PR, apply on merge
gateway/  docker-compose.yml      LiteLLM + Postgres, loopback-bound, digest-pinned
          docker-compose.mock-engine.yml  client-onboarding fixture, no GPU needed
          config.yaml             two aliases on one engine, router + privacy settings
          error_hook.py           turns an unreachable engine into an actionable 503
          mock_engine.py          stdlib stub for configuring clients without spending
gpu/      docker-compose.yml      vLLM flags — used on a VM provider
          provision.sh            runs ON the node: tailnet join, provenance, weights, engine
scripts/  gpu-up.sh gpu-down.sh   RunPod REST wrappers; drain before destroy
          scheduler.sh            cost guards + backups on a timer (sleep-safe; no cron)
          idle-check.sh           45 min idle + hard nightly stop
          pg-backup.sh            encrypted dump + rehearsed restore + retention audit
          common.sh               shared helpers, credential loading
verify.sh                         ~85 checks; GPU/tailnet ones skip cleanly
docs/                             per-role documentation (table above)
```

## Quick start

```bash
cd gateway && cp .env.example .env && chmod 600 .env
```

Fill in `.env` — every secret with `openssl rand -hex 24`, and
`LITELLM_MASTER_KEY` must start with `sk-`. Then:

```bash
cd gateway && docker compose up -d
```

```bash
./verify.sh --disruptive
```

That is the whole local stack, identical on a laptop and on the office server. The
rest — tailnet, GPU node, cost guards, backups — is
[docs/devops-setup.md](docs/devops-setup.md).
