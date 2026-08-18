# synth-refined

> Open a new TextEdit document and record the monthly revenue figure.

Compiled 2026-08-09T14:00:00Z · 4 steps · refinement: anthropic/claude-opus-5

## Inputs

| name | ask | default |
|---|---|---|
| `revenue_figure` | What is this month's revenue figure? | 4200 |

## Steps

### 1. Switch to TextEdit

- action: `app.activate`
- target: TextEdit
- verify: frontmost app is TextEdit
- narration: *Opening TextEdit to write the monthly note.*

### 2. Create a new document

- action: `ui.key` — `cmd+n`
- target: TextEdit
- verify: —
- narration: *New document for the monthly note.*

### 3. Click into the document's text area

- action: `ui.click`
- target: TextEdit › window "Untitled" › AXTextArea › fallback (700, 400)
- verify: —
- evidence: [shots/00001.png](../evals/sessions/synthetic-textedit/shots/00001.png)

### 4. Type the monthly revenue line

- action: `ui.type` — `Revenue this month: {{revenue_figure}}`
- target: TextEdit › window "Untitled" › AXTextArea › fallback (700, 400)
- verify: value contains "Revenue this month: {{revenue_figure}}"
- narration: *The revenue figure changes every month; this month it was 4200.*

---
Review this file, fix anything mis-mapped in the .pb.json, then `pb run` it.
