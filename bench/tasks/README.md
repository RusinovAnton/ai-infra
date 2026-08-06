# Task corpus fixtures

A fixed, committed set of coding tasks, so performance and quality numbers are
comparable across hardware and models: the same corpus runs against 1 × L40S,
2 ×, the Qwen3.6-27B A/B, or anything future. Real developer traffic is a
better *quality* signal but is not reproducible — these are the controlled half
of the measurement week; replay of real prompts is the other half.

## Format

One file per task. Everything above the `## Rubric` line is the prompt, sent
verbatim. The rubric is for the human scorer and is never sent to the model.

## Running

```bash
TASKS=1 ./scripts/bench.sh coder            # every fixture, metrics + saved output
TASKS=1 ./scripts/bench.sh coder coder-max  # both tiers for comparison
TASK=03-implement-function TASKS=1 ./scripts/bench.sh coder
```

Outputs land in `bench/results/<UTC timestamp>/` — one file per task × model,
containing the metrics line and the full model output. `bench/results/` is
gitignored; a measurement day's results worth keeping get copied into the
report, not committed raw.

## Scoring

Manual, against each task's rubric, 0–3 per criterion. Score blind if two
models are being compared: shuffle the output files before reading. The point
is a defensible relative judgement (35B-MoE vs 27B-dense on OUR kind of work),
not a leaderboard number.

## Adding tasks

Add tasks that resemble the team's real work — the corpus earns authority from
that, not from difficulty. Keep prompts self-contained (no repo access is
assumed), and size them like reality: agents send whole files, so several
fixtures deliberately carry a few thousand tokens of context.
