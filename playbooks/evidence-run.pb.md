# evidence-run

> Opens a new TextEdit document, approves the system permission prompt that appears, and types a short evidence note into the document.

Compiled 2026-08-10T05:54:41Z · 8 steps · refinement: anthropic/claude-opus-5

## Steps

### 1. Bring TextEdit to the front

- action: `app.activate`
- target: TextEdit
- verify: frontmost app is TextEdit

### 2. Open a new document

- action: `ui.key` — `cmd+n`
- target: TextEdit
- verify: —

### 3. Click into the document body

- action: `ui.click`
- target: TextEdit › window "Untitled" › AXTextArea › fallback (645, 529)
- verify: —
- evidence: [shots/00001.png](../recordings/live-voice-1/shots/00001.png)

### 4. Go to the system permission prompt

- action: `app.activate`
- target: UserNotificationCenter
- verify: frontmost app is UserNotificationCenter

### 5. Grant the requested permission

- action: `ui.click`
- target: UserNotificationCenter › AXButton "Allow" › fallback (691, 458)
- verify: —
- evidence: [shots/00002.png](../recordings/live-voice-1/shots/00002.png)

### 6. Return to TextEdit

- action: `app.activate`
- target: TextEdit
- verify: frontmost app is TextEdit

### 7. Click back into the document body

- action: `ui.click`
- target: TextEdit › window "Untitled" › AXTextArea › fallback (645, 529)
- verify: —
- evidence: [shots/00003.png](../recordings/live-voice-1/shots/00003.png)

### 8. Type the evidence note into the document

- action: `ui.type` — `Screenshot evidence run.`
- target: TextEdit › window "Untitled" › AXTextArea › fallback (645, 529)
- verify: value contains "Screenshot evidence run."

---
Review this file, fix anything mis-mapped in the .pb.json, then `pb run` it.
