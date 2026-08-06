# GPU provider drivers

`scripts/common.sh` sources exactly one of these, chosen by `GPU_PROVIDER` in
`scripts/.env`. Everything above the driver — the gateway, the tailnet policy,
draining, readiness polling, idle shutdown, backups — is identical whichever you
pick.

## The contract

A driver defines six functions and one constant. Nothing else in the repo may
reference a provider by name.

| Symbol | Must do |
|---|---|
| `PROVIDER_KIND` | `ephemeral` (rented, billed by the hour, destroy when idle) or `persistent` (hardware you own or rent monthly — **never destroyed**, only stopped) |
| `provider_preflight` | Validate its own env vars. `die` with a message naming the missing one. |
| `provider_find` | Print the node's id, or nothing if it does not exist. Must be cheap; it runs every 10 minutes. |
| `provider_status ID` | Print a one-word status for logs. |
| `provider_create` | Bring up a node running `gpu/provision.sh`, print its id. Honour `MODE=dry` by printing the request and creating nothing. |
| `provider_destroy ID` | `ephemeral`: destroy it. `persistent`: stop the engine only. |
| `provider_storage` | One-time storage setup, or a no-op. |

Two optional flags:

- `PROVIDER_INJECTS_SECRET=1` — the driver can deliver a fresh `ENGINE_SECRET` to
  the node at create time. `gpu-up.sh` rotates the secret on every launch when
  this is set, and skips rotation with a warning when it is not.
- `PROVIDER_BILLS_IDLE` — free text shown in shutdown messages, e.g. what keeps
  costing money after the node is gone.

## Shipped drivers

| `GPU_PROVIDER` | Kind | For |
|---|---|---|
| `runpod` | ephemeral | Rented on-demand pods. The default. |
| `ssh` | persistent | A GPU box you own, or any VPS with a GPU and Docker. Runs `gpu/docker-compose.yml` over SSH. |
| `manual` | persistent | You start the engine yourself. The scripts only observe. Useful as a first step on new hardware, and as the reference for what a driver must produce. |

## Writing a new one

Copy `manual.sh` — it is deliberately the smallest complete example — and fill in
the six functions. The node it produces must satisfy exactly one contract:

1. It joins the tailnet as `tag:gpu`, before the engine starts listening.
2. It serves vLLM on `:8000`, requiring `ENGINE_SECRET` as a bearer token.
3. It is reachable at `ENGINE_API_BASE` and nowhere else — no public IP, no
   published ports.

`gpu/provision.sh` already does all three. If your provider can run a container
with an entrypoint, you can almost certainly reuse it unchanged.
