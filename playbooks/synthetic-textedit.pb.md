# synthetic-textedit

> okay I'm opening TextEdit to write the monthly note new document now I type the revenue figure which changes every month this month it's forty two hundred

Compiled 2026-08-09T14:00:00Z · 4 steps · refinement: heuristic-only

## Steps

### 1. Switch to TextEdit

- action: `app.activate`
- target: TextEdit
- verify: frontmost app is TextEdit
- narration: *okay I'm opening TextEdit to write*

### 2. Press cmd+n

- action: `ui.key` — `cmd+n`
- target: TextEdit
- verify: —
- narration: *write the monthly note new document*

### 3. Click the text area in TextEdit

- action: `ui.click`
- target: TextEdit › window "Untitled" › AXTextArea › fallback (700, 400)
- verify: —
- narration: *new document now I*
- evidence: [shots/00001.png](../evals/sessions/synthetic-textedit/shots/00001.png)

### 4. Type "Revenue this month: 4200"

- action: `ui.type` — `Revenue this month: 4200`
- target: TextEdit › window "Untitled" › AXTextArea › fallback (700, 400)
- verify: value contains "Revenue this month: 4200"
- narration: *document now I type the revenue figure which changes every month this month it's*

---
Review this file, fix anything mis-mapped in the .pb.json, then `pb run` it.
