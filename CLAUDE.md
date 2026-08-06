# Working in this repo

## Record lessons as you go

**When something takes more than ~10 minutes to diagnose, or costs money, add an
entry to [docs/lessons.md](docs/lessons.md) before moving on.** Do it in the same
change that fixes the problem — a lesson written later loses the symptom, which
is the part worth keeping.

The bar is **diagnosis time, not fix size.** A one-line fix found after an hour
is exactly what belongs there. A ten-line fix that was obvious immediately does
not.

Use the file's existing shape — what it looked like / what was true / what
changed — and lead with the symptom, because that is what the next person meets
first and it is usually not the problem. Say plainly if the root cause was a
wrong assumption of ours; that is the most useful kind of entry and the easiest
to quietly omit.

Do **not** add an entry for: a bug caught by a test doing its job, a typo, or
anything whose diagnosis was "read the error message". Those are noise, and noise
is what makes the file stop being read.

Where things go:

| | |
|---|---|
| `docs/lessons.md` | what operating the system taught us — incidents, surprises, costs |
| `docs/design-notes.md` | what we decided and why; deliberate omissions; corrected assumptions |
| commit message | why this specific change, in detail |

## Invariants — do not "fix" these

They look like oversights. They are load-bearing, and each is explained where it
lives.

- **No reverse proxy, and `:4000` stays on loopback.** `tailscale serve` being
  the sole ingress is what makes `Tailscale-User-Login` trustworthy.
- **No grant with `src: ["tag:gpu"]`.** The rented node is confined by that
  *absence*; `policy/tailnet-policy.hujson` asserts it and `verify.sh` greps for
  it.
- **No provider named outside `scripts/providers/`.** `verify.sh` enforces it.
  A `persistent` driver must never destroy hardware — only stop the engine.
- **Nothing may block `gpu-down.sh`.** A validation failure that prevents
  shutting a node down turns a config problem into an unbounded bill.
- **No prompt content logged**, on either machine.
- **Every image pinned by digest, the model pinned by revision.**

## Before claiming something works

```bash
./verify.sh --disruptive
```

Must be **0 failed**. Do not commit with a failing check — fix it or say
explicitly that you are leaving it red and why. Skips are GPU- and
tailnet-dependent and are fine.

Secrets live in `gateway/.env` and `scripts/.env`, both `0600` and gitignored.
Never echo them — in particular, do not run `bash -x` on a script that sources
them.
