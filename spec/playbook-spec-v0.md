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

## v0 limitations (deliberate)

Single display; no drag-and-drop capture; scrolls recorded but not compiled; branching/conditions not yet in the DSL (narration conditions land as `notes` for the future editor); browser steps replay via accessibility rather than the DOM rung.
