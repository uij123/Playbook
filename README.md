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

### Choosing the model (any model)

The compiler's refinement stage is model-agnostic — a 3-method provider interface with two adapters:

- **Anthropic** — set `ANTHROPIC_API_KEY` (default model `claude-opus-5`, override with `PLAYBOOKS_MODEL`).
- **OpenAI-compatible** — any server speaking the OpenAI chat-completions API: OpenAI, or a **fully local** model via Ollama / LM Studio / vLLM / llama.cpp so nothing leaves the machine:

  ```bash
  PLAYBOOKS_OPENAI_BASE_URL=http://localhost:11434/v1 PLAYBOOKS_MODEL=llama3.1 ./pb compile <session>
  ```

`PLAYBOOKS_PROVIDER=anthropic|openai|none` forces the choice; otherwise it's auto-detected from the environment. `--no-llm` skips refinement entirely (pure heuristic compile — no network, no key).

## Voice narration on macOS (and grant-once permissions)

Recording input and screenshots work with the permissions your terminal already has. **On-device voice is different:** macOS attributes microphone/speech access to the *responsible app*, and a CLI spawned from a terminal has no identity of its own — so the OS blocks it. `pb record --voice` detects this and keeps recording without narration rather than failing. To capture voice, the recorder must run as its own app.

The catch that used to make this painful: an ad-hoc-signed app gets a new code hash on every rebuild (and a bundle rebuilt at a transient path reads as new), and macOS ties Accessibility grants to the app's hash + path — so every `make bundle` reset your permissions. The fix is a **stable signing identity** plus a **permanent install path**, set up once:

```bash
make signing-setup   # once per machine: creates a self-signed code-signing identity
make bundle          # → ~/Applications/Playbooks/pb-record.app, signed + updated in place
```

Now grant the **app** (not your terminal) its four permissions, once, in System Settings → Privacy & Security — Accessibility, Screen Recording, Microphone, Speech Recognition. Trigger the prompts with:

```bash
open ~/Applications/Playbooks/pb-record.app --args --out /tmp/pb-grant-check --voice
```

Because the app's identity and path are both stable, **those grants survive every future rebuild** — no more re-granting. (Verified end to end: after granting once, a rebuild with a genuinely different code hash — same Designated Requirement — passed all four gates with zero re-granting and transcribed narration on-device.)

Wiring `pb record` to drive the bundle automatically is the next packaging step. For distribution to other machines, swap the self-signed identity for an Apple **Developer ID** and notarize — one line in `scripts/build-app.sh` — which also clears Gatekeeper warnings.

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
