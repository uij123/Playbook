# Playbooks

**Show your screen once, run it forever.**

Playbooks records your whole screen — across all apps, not one browser tab — while you narrate what you're doing. It compiles the demonstration into a *playbook*: a human-readable, editable, deterministic program. Replaying a playbook makes zero model calls on a healthy run; AI is used only to author the playbook and to propose repairs when something drifts.

This repo is the **P0 spike**: prove the loop `record → compile → replay` end-to-end on macOS. No editor, no sharing bank yet — see [the build plan](https://claude.ai/code/artifact/8ccb8fea-d674-4d35-934a-67af16d36bc9) for the full roadmap.

## How it works

```
pb record   →  recordings/<session>/     events.jsonl + shots/*.png + transcript.json
pb compile  →  playbooks/<name>.pb.json  deterministic playbook (+ .md review file)
pb run      →  runs/<report>.json        step-by-step execution with verification
```

- **Recorder** (Swift): global click/key capture via CGEventTap, with the **accessibility tree context** of every interaction (app, window, element role + label) — semantics, not pixels. Per-click screenshots as evidence. Optional on-device voice transcription (Apple Speech, nothing leaves the machine). Password fields are auto-redacted via the accessibility layer's secure-field flag.
- **Compiler** (TypeScript): segments events into steps, coalesces typing, aligns your narration by timestamp, then (optionally) asks a model to name intents, extract parameters from what you *said* ("the amount changes every month" → an input), and add verification checks. Model-agnostic by design: a 3-method provider interface, Anthropic adapter first. Without an API key it falls back to a pure-heuristic compile.
- **Replayer** (Swift): executes steps accessibility-first (`AXPress` > synthetic click at the element's current position > recorded-coordinate fallback), verifies a postcondition after every step, and writes a full run report. `--strict` disables the coordinate fallback.

## Quickstart

```bash
make            # builds native binaries (swift) + compiler (tsc)
make doctor     # checks toolchain + macOS permissions
```

Grant permissions when prompted (System Settings → Privacy & Security):
- **Accessibility** — required to record input and to replay (your terminal app)
- **Screen Recording** — required for per-step screenshots
- **Microphone + Speech Recognition** — only if you use `--voice`

Then:

```bash
./pb record --name my-flow --voice     # do the task while narrating; Ctrl+C to stop
./pb compile recordings/<session-dir>  # → playbooks/my-flow.pb.json + review .md
./pb run playbooks/my-flow.pb.json     # replay it; add --strict for the honest version
```

Set `ANTHROPIC_API_KEY` for model-refined compilation (`PLAYBOOKS_MODEL` overrides the default model). `--no-llm` compiles heuristically.

## The P0 gate

Before building anything else, this spike must pass: **3 recorded real flows, 10 replays each, ≥ 8/10 success per flow** on the same machine. Protocol and tally sheet: [evals/README.md](evals/README.md).

## Principles already enforced in P0

- Recordings never leave `recordings/` and are gitignored; secure text fields are never captured.
- A playbook contains **no credentials** and no raw screen video — only structure, selectors, and screenshot references.
- Replay is deterministic: the same playbook attempts the same steps in the same order with explicit verification. Every fallback the runner takes is logged in the run report.
- Screen content is data, not instructions: the compiler extracts structure from what's on screen; it does not follow text found there.

## Status

P0 spike (macOS + Chrome wedge). Windows and the browser-DOM rung come next; then editor, runner hardening, and the playbook bank per the plan.

## License

[Apache-2.0](LICENSE)
