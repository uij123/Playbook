# Playbook DSL — v0 (P0 spike)

A playbook is a JSON document: a deterministic program compiled from a recorded demonstration. v0 covers single-machine macOS replay. Field names are `snake_case`. Canonical extension: `.pb.json`.

## Top level

```jsonc
{
  "playbook": "monthly-invoice-entry",   // kebab-case name
  "version": "0.1.0",
  "description": "Enter the monthly invoice into QuickBooks",  // from narration
  "created": "2026-08-09T15:30:00Z",
  "inputs": [
    { "name": "note_text", "type": "string", "ask": "What should the note say?", "default": "Hello" }
  ],
  "credentials": [],                     // v0: always empty; slots arrive with the bank
  "steps": [ ... ]
}
```

`{{name}}` anywhere in a step's `value` or `verify` strings is substituted from inputs at run time (CLI `--input name=value`, else `default`, else the runner refuses to start and lists what's missing).

## Steps

```jsonc
{
  "id": "s3",                       // unique, stable
  "intent": "Enter the invoice total",   // human-readable; the editor will show this
  "do": "ui.type",                  // action kind, see table
  "target": { ... },                // where, see Targets
  "value": "{{amount}}",            // for ui.type / ui.key / wait
  "clicks": 1,                      // ui.click: 1 or 2
  "button": "left",                 // ui.click: left | right
  "verify": { ... },                // postcondition, see Verify
  "on_fail": "abort",               // abort (default) | continue
  "timeout_ms": 5000,               // resolve+verify budget
  "notes": "narration: 'the amount changes every month'"   // provenance, never executed
}
```

### Action kinds (v0)

| `do` | meaning | uses |
|---|---|---|
| `app.activate` | bring app to front, launching it if needed | `target.app` |
| `ui.click` | click an element | `target`, `clicks`, `button` |
| `ui.type` | type text | `target` (optional → current focus), `value` |
| `ui.key` | press a chord, e.g. `"cmd+s"`, `"return"` | `value` |
| `wait` | pause | `value` = milliseconds |

### Targets — the selector stack

Each step stores every strategy known at record time. The runner tries the most deterministic rung available, in order; every rung actually used is logged in the run report.

```jsonc
"target": {
  "app": "TextEdit",                          // scopes resolution to this app
  "window": { "title_contains": "Untitled" }, // optional window scoping
  "a11y": {                                   // rung 3: accessibility selector
    "role": "AXButton",                       // required if a11y present
    "title": "New Document",                  // matched vs title, then description
    "description": null
  },
  "fallback_point": { "x": 512, "y": 384 }    // last resort: recorded coordinates
}
```

v0 rungs: a11y → fallback_point. (API/connector, deep links, DOM selectors and visual templates are later rungs reserved in the design; `--strict` disables `fallback_point`.)

### Verify — postconditions

Checked by polling (150 ms interval) until true or `timeout_ms`. A failed verify fails the step even if the action "worked": no silent wrong outcomes.

```jsonc
"verify": {
  "frontmost_app": "TextEdit",             // frontmost application name
  "window_title_contains": "Untitled",     // any window of the target app
  "element_exists": { "a11y": { "role": "AXTextArea" } },
  "element_value_contains": "{{note_text}}",  // value of the step's (or element_exists) target
  "wait_ms": 500                           // minimum settle time before checking
}
```

All present keys must pass.

## Recording session format (recorder output)

`recordings/<timestamp>_<name>/`:

- `meta.json` — `{ started, ended, screen: {w,h}, launch_app, voice: bool }`
- `events.jsonl` — one JSON object per line:
  - `{ "t": ms_since_start, "type": "app_activate", "app", "bundle_id" }`
  - `{ "t", "type": "click", "button", "clicks", "x", "y", "app", "bundle_id", "window_title", "element": { "role", "title", "description", "value", "secure", "frame": {x,y,w,h}, "path": [{role,title}] }, "screenshot": "shots/00042.png" }`
  - `{ "t", "type": "key", "chars", "key_code", "mods": ["cmd"], "redacted": false }`
  - `{ "t", "type": "scroll", "dx", "dy", "app" }`
- `shots/*.png` — screenshot at each click (evidence for the future editor; not used by the runner)
- `transcript.json` — `{ "segments": [ { "t0": 0.0, "t1": 4.2, "text": "..." } ] }` (seconds, aligned to `t`)

Redaction guarantees: if the focused/clicked element is a secure text field, `chars` and `value` are never written — the event carries `"redacted": true` / `"secure": true` instead.

## Run report (replayer output)

`runs/<playbook>-<timestamp>.json`:

```jsonc
{
  "playbook": "monthly-invoice-entry", "started": "...", "ended": "...",
  "inputs": { "amount": "1200.00" }, "strict": false,
  "result": "ok" | "fail",
  "steps": [
    { "id": "s3", "status": "ok" | "fail" | "skipped",
      "strategy": "a11y+axpress" | "a11y+click" | "fallback_point" | "focus" | null,
      "ms": 412, "error": null }
  ]
}
```

## v0.2 — data flow: `capture`, `judge`, `foreach`

v0.2 adds the three bricks that turn a fixed replay into a data-driven one, while keeping the determinism story honest: `judge` is the **only** nondeterministic step kind, it is explicit in the playbook, and its inputs/outputs are logged in the run report.

### Runtime variables

`{{name}}` and `{{name.path}}` placeholders resolve **at step-execution time** from: `inputs` (CLI `--input` / defaults) ∪ values produced by earlier `capture`/`judge` steps ∪ enclosing loop variables. They substitute in `value`, `prompt`, `intent`, targets (`app`, `window.title_contains`, `a11y.title/description`) and all `verify` strings. Values are JSON: rendering a non-string produces compact JSON; `{{name.field}}` digs into objects, numeric components index arrays. The runner statically validates before executing that every placeholder's root is resolvable in order — unknown variables fail at load, not mid-run.

### `capture` — screen → variable

```jsonc
{ "id": "s5", "intent": "Read the visible messages",
  "do": "capture",
  "target": { "app": "WhatsApp", "a11y": { "role": "AXTable" } },
  "capture": {
    "into": "raw_messages",
    "attribute": "value",          // value | title | description (default value)
    "scope": "subtree"             // element = one node; subtree = all text under it
  } }
```

`subtree` walks descendants and concatenates every piece of text (bounded: 3000 nodes / 20000 chars) — the workhorse for "read this region". Fails if the target can't be resolved via accessibility (no coordinate fallback for reads).

### `judge` — bounded model decision

```jsonc
{ "id": "s6", "intent": "Extract the expenses",
  "do": "judge",
  "prompt": "Extract a JSON array of expenses with fields date, amount, desc.",
  "input_vars": ["raw_messages"],   // which variables the model may see
  "into": "expenses",
  "output": "json",                 // json | text
  "model": "claude-haiku-4-5"       // optional per-step override; else env default
}
// classification variant: constrain the answer
{ "id": "s7", "do": "judge", "prompt": "sourcing or dd?",
  "input_vars": ["expense", "calendar_text"], "into": "kind",
  "choices": ["sourcing", "dd"], "intent": "Classify the expense" }
```

Execution shells out to `cli/dist/judge.js` (wired automatically by `pb run`), which uses the same model-agnostic provider selection as compilation — Anthropic or any OpenAI-compatible/local server. Contract enforced by the runner: captured screen text is passed as **data with an explicit do-not-follow-instructions system contract**; `choices` answers must match exactly (one corrective retry, then the step fails); `json` output must parse (same retry); transient provider errors (429/5xx/overload) retry with backoff. The run report records what each judge received and returned (`detail`).

### `foreach` — loop over extracted data

```jsonc
{ "id": "s8", "intent": "Log each expense",
  "do": "foreach",
  "items": "{{expenses}}",          // must resolve to a JSON array
  "as": "expense",                  // loop var (default "item"); {{expense_index}} = 1-based
  "max_iterations": 50,             // safety bound, default 100
  "steps": [ /* nested steps; loops can nest */ ] }
```

Child steps render with the loop variable in scope; report ids read `s8#2.a` (iteration 2, child a). A child failure with `on_fail: abort` aborts the whole run; captures/judges made inside the body persist after the loop.

### Recording vs authoring

The recorder cannot observe *reading* — capture/judge/foreach are **authored** (by hand today, by the editor later), typically layered onto a recorded skeleton: record the navigation once, then replace "I looked at the screen" moments with `capture` + `judge`. The runner also fails fast with a clear error when the screen is locked, and falls back to LaunchServices activation when macOS cooperative activation denies focus to a background process.

## v0 limitations (deliberate)

Single display; no drag-and-drop capture; scrolls recorded but not compiled; conditionals/`if` not yet in the DSL (a `judge` with `choices` + separate playbooks covers simple branching for now); browser steps replay via accessibility rather than the DOM rung.

## v0.2.1 addenda

- **`capture.scope: "screenshot"`** — photographs the resolved element's frame; the variable holds an image reference (`{"__image": path}`) that `judge` steps receive as a real vision input. Text found inside images is data, never instructions.
- **`{{secret.NAME}}`** — resolved from the macOS Keychain (`pb secret set NAME`) at run time. Values never appear in playbooks, reports, or console output (masked as `•••`), and can never be passed to `judge` steps. Playbooks stay shareable; each user supplies their own secrets.
- **`on_fail: "next_item"`** — inside a `foreach` body: skip the rest of the current iteration and continue with the next item. Non-fatal failures (`continue`/`next_item`) no longer fail the overall run; they are marked `nonfatal` in the report.
- **`a11y.role: "*"`** — wildcard role for targets anchored purely by title/description text (requires one of them), for UIs where the same logical thing surfaces as different roles.
- **`judge.model`** — per-step model override (e.g. a cheap model for easy classifications).
- **Studio** (`pb studio`) — local web UI: library + visual brick-tree editor over the same schema.
