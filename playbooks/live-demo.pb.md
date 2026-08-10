# live-demo


Compiled 2026-08-09T23:54:57Z · 4 steps · refinement: heuristic-only

## Steps

### 1. Switch to TextEdit

- action: `app.activate`
- target: TextEdit
- verify: frontmost app is TextEdit

### 2. Press cmd+n

- action: `ui.key` — `cmd+n`
- target: TextEdit
- verify: —

### 3. Click the text area in TextEdit

- action: `ui.click`
- target: TextEdit › window "Untitled" › AXTextArea › fallback (474, 386)
- verify: —

### 4. Type "Hello from Playbooks. Recorded once, rep…"

- action: `ui.type` — `Hello from Playbooks. Recorded once, replayed forever.`
- target: TextEdit › window "Untitled" › AXTextArea › fallback (474, 386)
- verify: value contains "Hello from Playbooks. Recorded once, replayed forever."

---
Review this file, fix anything mis-mapped in the .pb.json, then `pb run` it.
