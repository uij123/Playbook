# Evals — P0 gate

The P0 gate: **3 recorded real flows, 10 replays each, ≥ 8/10 success per flow**, same machine. A replay counts as a success only if the run report says `"result": "ok"` — every step passed its verification. No hand-holding between replays beyond restoring the app's starting state.

## Protocol

1. Pick 3 real flows, each 4–8 steps, at least one crossing two apps, at least one including a browser. Record each with `--voice`, narrating naturally.
2. Compile each (`pb compile`). You may fix the playbook by hand once after reading the `.md` review file — that's the "verify/edit" stage the editor will later own. Note how many edits were needed.
3. Replay each 10×: `pb run playbooks/<name>.pb.json`. Restore starting state between runs. Record the tally below. Run at least 3 of the 10 with `--strict`.

## Tally

| Flow | Steps | Hand edits after compile | Replays OK /10 | of which --strict OK | Notes |
|---|---|---|---|---|---|
| 1. | | | /10 | | |
| 2. | | | /10 | | |
| 3. | | | /10 | | |

**Gate passes:** every row ≥ 8/10. Then P1 (Recorder v1) begins.
**Gate fails:** the run reports say exactly which rung/verification broke — fix the weakest layer and rerun before writing any new product code.

`sessions/` holds synthetic recorded sessions used as compiler fixtures (safe to commit — no real screen data).
