#!/usr/bin/env bash
# Measure what a developer actually feels: time-to-first-token and decode speed,
# through the gateway — the full path (tailnet -> serve -> LiteLLM -> engine),
# not the engine in isolation. Engine-only numbers flatter the system by hiding
# the hops developers cannot avoid.
#
#   ./scripts/bench.sh                     both aliases, 3 runs, 1 stream
#   RUNS=5 ./scripts/bench.sh coder        one alias, more runs
#   STREAMS=5 FILE_PROMPT=1 ./scripts/bench.sh coder
#       the design's exit criterion: on ONE GPU, TTFT p95 < ~5 s at 5
#       concurrent file-sized streams with zero sustained preemptions
#       -> steady state stays 1 GPU
#   TASKS=1 ./scripts/bench.sh coder coder-max
#       run the committed task corpus (bench/tasks/*.md) instead of the
#       synthetic prompt; full outputs land in bench/results/<ts>/ for
#       scoring against each task's rubric. TASK=<name> runs one fixture.
#
# Streaming, because agents stream. TTFT is to the first CONTENT token — on the
# thinking tier that includes the whole reasoning pass, because the user waits
# through it. Preemptions are read from the engine's own metrics as a delta.
set -euo pipefail
. "$(dirname "$0")/common.sh"
load_env

TAILNET="$(tailscale status --json 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin)["MagicDNSSuffix"])')"
export BENCH_BASE="${BENCH_BASE:-https://gateway.$TAILNET}"
export BENCH_KEY="${BENCH_KEY:-$LITELLM_MASTER_KEY}"
export RUNS="${RUNS:-3}"
export MAXTOK="${MAXTOK:-512}"
export STREAMS="${STREAMS:-1}"
export FILE_PROMPT="${FILE_PROMPT:-0}"
export TASKS="${TASKS:-0}"
export TASK="${TASK:-}"
export TASKS_DIR="$REPO_ROOT/bench/tasks"
export RESULTS_DIR="$REPO_ROOT/bench/results/$(date -u +%Y%m%dT%H%M%SZ)"
ENGINE_METRICS="$(engine_base)/metrics"
export ENGINE_METRICS
export ENGINE_SECRET="${ENGINE_SECRET:-}"
MODELS=("$@"); [ ${#MODELS[@]} -eq 0 ] && MODELS=(coder coder-max)

log "target: $BENCH_BASE  runs=$RUNS streams=$STREAMS file_prompt=$FILE_PROMPT max_tokens=$MAXTOK"

for model in "${MODELS[@]}"; do
  BENCH_MODEL="$model" python3 - <<'PY'
import concurrent.futures as cf
import json, os, statistics, time, urllib.request

BASE    = os.environ["BENCH_BASE"]
KEY     = os.environ["BENCH_KEY"]
MODEL   = os.environ["BENCH_MODEL"]
RUNS    = int(os.environ["RUNS"])
MAXTOK  = int(os.environ["MAXTOK"])
STREAMS = int(os.environ["STREAMS"])

prompt = ("Write a Python function that parses an ISO-8601 timestamp without "
          "using datetime.fromisoformat, with error handling and a short docstring.")
if os.environ.get("FILE_PROMPT") == "1":
    # Agents send files, not one-liners. ~6k tokens of plausible code exercises
    # prefill, which is where TTFT actually lives under concurrency.
    lines = []
    for i in range(400):
        lines += [f"def handler_{i}(request, ctx):",
                  f'    """Process request {i} against the {i%7} backend."""',
                  f"    payload = validate(request.body, schema_{i%13})",
                  f"    return ctx.dispatch(payload, retries=3, timeout={i%30+1})"]
    prompt = ("Review this module and summarise its structure in one paragraph:\n\n"
              "```python\n" + "\n".join(lines) + "\n```\n\nThen: " + prompt)

def preemptions():
    try:
        r = urllib.request.Request(os.environ["ENGINE_METRICS"],
              headers={"Authorization": "Bearer " + os.environ.get("ENGINE_SECRET", "")})
        body = urllib.request.urlopen(r, timeout=10).read().decode()
        return int(sum(float(l.split()[-1]) for l in body.splitlines()
                       if l.startswith("vllm:num_preemptions_total")))
    except Exception:
        return None

def one_stream(_):
    req = urllib.request.Request(BASE + "/v1/chat/completions",
        headers={"Authorization": "Bearer " + KEY, "Content-Type": "application/json"},
        data=json.dumps({"model": MODEL,
                         "messages": [{"role": "user", "content": prompt}],
                         "max_tokens": MAXTOK, "stream": True,
                         "stream_options": {"include_usage": True}}).encode())
    t0 = time.monotonic(); ttft = first_any = None; usage = None
    with urllib.request.urlopen(req, timeout=600) as r:
        for raw in r:
            raw = raw.strip()
            if not raw.startswith(b"data: ") or raw == b"data: [DONE]":
                continue
            d = json.loads(raw[6:])
            if d.get("usage"):
                usage = d["usage"]
            for ch in d.get("choices", []):
                delta = ch.get("delta", {})
                if first_any is None and (delta.get("content") or delta.get("reasoning_content")):
                    first_any = time.monotonic() - t0
                if delta.get("content") and ttft is None:
                    ttft = time.monotonic() - t0
    total = time.monotonic() - t0
    comp = (usage or {}).get("completion_tokens") or 0
    decode = comp / (total - first_any) if first_any and total > first_any else float("nan")
    return ttft, first_any, comp, decode, total

if os.environ.get("TASKS") == "1":
    # Corpus mode: one request per fixture, single stream, full output saved.
    # Metrics still print, but the artefact that matters is the response file —
    # scoring happens against the rubric, by a human, later.
    import glob, pathlib
    outdir = pathlib.Path(os.environ["RESULTS_DIR"]); outdir.mkdir(parents=True, exist_ok=True)
    only = os.environ.get("TASK", "")
    fixtures = sorted(glob.glob(os.environ["TASKS_DIR"] + "/[0-9]*.md"))
    if only:
        fixtures = [f for f in fixtures if only in f]
    print(f"── {MODEL}  corpus: {len(fixtures)} task(s) -> {outdir} ──")
    for fx in fixtures:
        name = pathlib.Path(fx).stem
        text = pathlib.Path(fx).read_text()
        task_prompt = text.split("## Rubric")[0].strip()   # rubric never reaches the model
        req = urllib.request.Request(BASE + "/v1/chat/completions",
            headers={"Authorization": "Bearer " + KEY, "Content-Type": "application/json"},
            data=json.dumps({"model": MODEL,
                             "messages": [{"role": "user", "content": task_prompt}],
                             "max_tokens": 8192}).encode())
        t0 = time.monotonic()
        d = json.load(urllib.request.urlopen(req, timeout=600))
        total = time.monotonic() - t0
        msg = d["choices"][0]["message"]
        usage = d.get("usage", {})
        out = outdir / f"{name}--{MODEL}.md"
        out.write_text(
            f"# {name} — {MODEL}\n\n"
            f"tokens={usage.get('completion_tokens')} total={total:.1f}s "
            f"finish={d['choices'][0].get('finish_reason')}\n\n---\n\n"
            + (msg.get("content") or "(EMPTY)"))
        print(f"  {name}: {usage.get('completion_tokens')} tok in {total:.1f}s -> {out.name}")
    raise SystemExit

print(f"── {MODEL}  streams={STREAMS} ──")
p0 = preemptions()
ttfts = []
for run in range(RUNS):
    with cf.ThreadPoolExecutor(max_workers=STREAMS) as ex:
        results = list(ex.map(one_stream, range(STREAMS)))
    for ttft, first_any, comp, decode, total in results:
        if ttft is None:
            print(f"  NO CONTENT within max_tokens — all {comp} tokens were reasoning "
                  f"(first output {first_any:.2f}s, total {total:.1f}s). Raise MAXTOK.")
        else:
            ttfts.append(ttft)
            print(f"  ttft={ttft:5.2f}s  tokens={comp:4d}  decode={decode:6.1f} tok/s  total={total:5.1f}s")
p1 = preemptions()

if ttfts:
    ttfts.sort()
    p95 = ttfts[max(0, int(len(ttfts) * 0.95) - 1)] if len(ttfts) > 1 else ttfts[0]
    print(f"  TTFT: median={statistics.median(ttfts):.2f}s  p95={p95:.2f}s  (n={len(ttfts)})")
    if STREAMS >= 5:
        verdict = "PASS" if p95 < 5.0 else "FAIL"
        print(f"  exit criterion (TTFT p95 < 5 s at {STREAMS} file-sized streams): {verdict}")
if p0 is not None and p1 is not None:
    d = p1 - p0
    note = "  ⚠ KV pressure — the exit criterion requires zero sustained" if d else ""
    print(f"  preemptions during run: {d}{note}")
PY
done
